using Godot;
using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;

namespace Godotwind.Native;

/// <summary>
/// Bakes a compact river flow map from a height-derived water mask.
///
/// Output RGBA8:
///   R/G = flow direction encoded from [-1, 1] to [0, 1]
///   B   = normalized speed
///   A   = water coverage
///
/// The baker is source-agnostic. Callers provide heights in world units and a
/// sea level; source adapters own any game-specific interpretation.
/// </summary>
[GlobalClass]
public partial class NativeRiverFlowBaker : RefCounted
{
    public int Width { get; set; } = 256;
    public int Height { get; set; } = 256;
    public float SeaLevel { get; set; } = 0.0f;
    public float TexelSizeMeters { get; set; } = 1.0f;
    public float RiverAspectRatio { get; set; } = 2.35f;
    public float MaxStillWaterMeanWidthMeters { get; set; } = 90.0f;
    public int MinRiverAreaPixels { get; set; } = 24;
    public float FlowSpeedMetersPerSecond { get; set; } = 1.4f;
    public float MaxEncodedSpeedMetersPerSecond { get; set; } = 6.0f;

    public Godot.Collections.Dictionary BakeFromHeights(Godot.Collections.Array<float> heights)
    {
        int width = Math.Max(1, Width);
        int height = Math.Max(1, Height);
        int count = width * height;
        if (heights.Count < count)
        {
            return EmptyResult(width, height, $"height array has {heights.Count} samples, expected {count}");
        }

        var isWater = new bool[count];
        for (int i = 0; i < count; i++)
            isWater[i] = heights[i] < SeaLevel;

        var bankDistance = ComputeBankDistances(isWater, width, height);
        var componentIds = new int[count];
        Array.Fill(componentIds, -1);

        var output = new byte[count * 4];
        for (int i = 0; i < count; i++)
        {
            int outIdx = i * 4;
            output[outIdx] = 128;
            output[outIdx + 1] = 128;
            output[outIdx + 2] = 0;
            output[outIdx + 3] = isWater[i] ? (byte)255 : (byte)0;
        }

        var components = new Godot.Collections.Array<Godot.Collections.Dictionary>();
        int nextComponentId = 0;

        for (int start = 0; start < count; start++)
        {
            if (!isWater[start] || componentIds[start] >= 0)
                continue;

            var component = FloodComponent(start, nextComponentId, isWater, componentIds, width, height);
            var analysis = AnalyzeComponent(component, heights, isWater, bankDistance, width, height);
            components.Add(analysis.ToDictionary(nextComponentId));

            if (analysis.IsRiver)
                WriteRiverFlow(output, component, analysis.Direction, width, height);

            nextComponentId++;
        }

        ExpandRiverFlowGutters(output, width, height, 2);

        return new Godot.Collections.Dictionary
        {
            ["image"] = Image.CreateFromData(width, height, false, Image.Format.Rgba8, output),
            ["components"] = components,
            ["river_count"] = CountRivers(components),
            ["error"] = "",
        };
    }

    private Godot.Collections.Dictionary EmptyResult(int width, int height, string error)
    {
        var data = new byte[Math.Max(1, width * height * 4)];
        return new Godot.Collections.Dictionary
        {
            ["image"] = Image.CreateFromData(width, height, false, Image.Format.Rgba8, data),
            ["components"] = new Godot.Collections.Array<Godot.Collections.Dictionary>(),
            ["river_count"] = 0,
            ["error"] = error,
        };
    }

    private static int CountRivers(Godot.Collections.Array<Godot.Collections.Dictionary> components)
    {
        int total = 0;
        foreach (var component in components)
        {
            if (component.TryGetValue("is_river", out Variant value) && value.AsBool())
                total++;
        }
        return total;
    }

    private static int[] ComputeBankDistances(bool[] isWater, int width, int height)
    {
        int count = width * height;
        var dist = new int[count];
        Array.Fill(dist, int.MaxValue);
        var queue = new Queue<int>();

        for (int idx = 0; idx < count; idx++)
        {
            if (!isWater[idx])
                continue;
            int x = idx % width;
            int y = idx / width;
            if (TouchesLand(x, y, isWater, width, height))
            {
                dist[idx] = 0;
                queue.Enqueue(idx);
            }
        }

        ReadOnlySpan<int> dx = stackalloc int[] { 1, -1, 0, 0 };
        ReadOnlySpan<int> dy = stackalloc int[] { 0, 0, 1, -1 };
        while (queue.Count > 0)
        {
            int idx = queue.Dequeue();
            int x = idx % width;
            int y = idx / width;
            int nextDist = dist[idx] + 1;
            for (int d = 0; d < 4; d++)
            {
                int nx = x + dx[d];
                int ny = y + dy[d];
                if ((uint)nx >= (uint)width || (uint)ny >= (uint)height)
                    continue;
                int ni = ny * width + nx;
                if (!isWater[ni] || dist[ni] <= nextDist)
                    continue;
                dist[ni] = nextDist;
                queue.Enqueue(ni);
            }
        }

        return dist;
    }

    private static bool TouchesLand(int x, int y, bool[] isWater, int width, int height)
    {
        for (int oy = -1; oy <= 1; oy++)
        {
            for (int ox = -1; ox <= 1; ox++)
            {
                if (ox == 0 && oy == 0)
                    continue;
                int nx = x + ox;
                int ny = y + oy;
                if ((uint)nx >= (uint)width || (uint)ny >= (uint)height)
                    continue;
                if (!isWater[ny * width + nx])
                    return true;
            }
        }
        return false;
    }

    private static List<int> FloodComponent(int start, int componentId, bool[] isWater, int[] componentIds, int width, int height)
    {
        var pixels = new List<int>(256);
        var queue = new Queue<int>();
        componentIds[start] = componentId;
        queue.Enqueue(start);

        ReadOnlySpan<int> dx = stackalloc int[] { 1, -1, 0, 0, 1, -1, 1, -1 };
        ReadOnlySpan<int> dy = stackalloc int[] { 0, 0, 1, -1, 1, -1, -1, 1 };

        while (queue.Count > 0)
        {
            int idx = queue.Dequeue();
            pixels.Add(idx);
            int x = idx % width;
            int y = idx / width;
            for (int d = 0; d < 8; d++)
            {
                int nx = x + dx[d];
                int ny = y + dy[d];
                if ((uint)nx >= (uint)width || (uint)ny >= (uint)height)
                    continue;
                int ni = ny * width + nx;
                if (!isWater[ni] || componentIds[ni] >= 0)
                    continue;
                componentIds[ni] = componentId;
                queue.Enqueue(ni);
            }
        }

        return pixels;
    }

    private ComponentAnalysis AnalyzeComponent(
        List<int> pixels,
        Godot.Collections.Array<float> heights,
        bool[] isWater,
        int[] bankDistance,
        int width,
        int height)
    {
        int minX = width;
        int minY = height;
        int maxX = 0;
        int maxY = 0;
        double meanX = 0.0;
        double meanY = 0.0;

        foreach (int idx in pixels)
        {
            int x = idx % width;
            int y = idx / width;
            minX = Math.Min(minX, x);
            minY = Math.Min(minY, y);
            maxX = Math.Max(maxX, x);
            maxY = Math.Max(maxY, y);
            meanX += x;
            meanY += y;
        }

        int area = pixels.Count;
        meanX /= Math.Max(1, area);
        meanY /= Math.Max(1, area);

        double covXX = 0.0;
        double covXY = 0.0;
        double covYY = 0.0;
        foreach (int idx in pixels)
        {
            double dx = (idx % width) - meanX;
            double dy = (idx / width) - meanY;
            covXX += dx * dx;
            covXY += dx * dy;
            covYY += dy * dy;
        }

        var axis = PrincipalAxis(covXX, covXY, covYY);
        float minProjection = float.PositiveInfinity;
        float maxProjection = float.NegativeInfinity;
        foreach (int idx in pixels)
        {
            float projection = ((idx % width) - (float)meanX) * axis.X + ((idx / width) - (float)meanY) * axis.Y;
            minProjection = MathF.Min(minProjection, projection);
            maxProjection = MathF.Max(maxProjection, projection);
        }

        float lengthPixels = MathF.Max(1.0f, maxProjection - minProjection + 1.0f);
        float meanWidthPixels = area / lengthPixels;
        float aspect = lengthPixels / MathF.Max(1.0f, meanWidthPixels);
        float meanWidthMeters = meanWidthPixels * TexelSizeMeters;
        bool isRiver = area >= MinRiverAreaPixels
            && aspect >= RiverAspectRatio
            && meanWidthMeters <= MaxStillWaterMeanWidthMeters;

        var orientedAxis = OrientAxis(axis, pixels, heights, isWater, width, height);
        var centerline = ExtractCenterline(pixels, bankDistance, orientedAxis, width, height);

        return new ComponentAnalysis
        {
            Area = area,
            Bounds = new Rect2I(minX, minY, maxX - minX + 1, maxY - minY + 1),
            Aspect = aspect,
            MeanWidthMeters = meanWidthMeters,
            IsRiver = isRiver,
            Direction = isRiver ? orientedAxis.Normalized() : Vector2.Zero,
            FlowSpeedMetersPerSecond = isRiver ? this.FlowSpeedMetersPerSecond : 0.0f,
            CenterlinePixels = centerline,
        };
    }

    private static Vector2 PrincipalAxis(double covXX, double covXY, double covYY)
    {
        double angle = 0.5 * Math.Atan2(2.0 * covXY, covXX - covYY);
        var axis = new Vector2((float)Math.Cos(angle), (float)Math.Sin(angle));
        if (axis.LengthSquared() < 0.0001f)
            axis = Vector2.Right;
        return axis.Normalized();
    }

    private static Vector2 OrientAxis(Vector2 axis, List<int> pixels, Godot.Collections.Array<float> heights, bool[] isWater, int width, int height)
    {
        float minProjection = float.PositiveInfinity;
        float maxProjection = float.NegativeInfinity;
        var minEndpoint = Vector2.Zero;
        var maxEndpoint = Vector2.Zero;

        foreach (int idx in pixels)
        {
            var p = new Vector2(idx % width, idx / width);
            float projection = p.Dot(axis);
            if (projection < minProjection)
            {
                minProjection = projection;
                minEndpoint = p;
            }
            if (projection > maxProjection)
            {
                maxProjection = projection;
                maxEndpoint = p;
            }
        }

        float minBank = SampleBankHeight(minEndpoint, heights, isWater, width, height);
        float maxBank = SampleBankHeight(maxEndpoint, heights, isWater, width, height);
        if (MathF.Abs(minBank - maxBank) > 0.05f)
            return minBank > maxBank ? axis : -axis;

        if (MathF.Abs(axis.X) > MathF.Abs(axis.Y))
            return axis.X >= 0.0f ? axis : -axis;
        return axis.Y >= 0.0f ? axis : -axis;
    }

    private static float SampleBankHeight(Vector2 endpoint, Godot.Collections.Array<float> heights, bool[] isWater, int width, int height)
    {
        int cx = Math.Clamp((int)MathF.Round(endpoint.X), 0, width - 1);
        int cy = Math.Clamp((int)MathF.Round(endpoint.Y), 0, height - 1);
        float sum = 0.0f;
        int count = 0;
        const int radius = 3;

        for (int y = cy - radius; y <= cy + radius; y++)
        {
            for (int x = cx - radius; x <= cx + radius; x++)
            {
                if ((uint)x >= (uint)width || (uint)y >= (uint)height)
                    continue;
                int idx = y * width + x;
                if (isWater[idx])
                    continue;
                sum += heights[idx];
                count++;
            }
        }

        return count > 0 ? sum / count : 0.0f;
    }

    private static Godot.Collections.Array<Vector2> ExtractCenterline(List<int> pixels, int[] bankDistance, Vector2 axis, int width, int height)
    {
        var candidates = new List<int>();
        var perpendicular = new Vector2(-axis.Y, axis.X);
        foreach (int idx in pixels)
        {
            int x = idx % width;
            int y = idx / width;
            int dist = bankDistance[idx];
            if (dist <= 0 || dist == int.MaxValue)
                continue;

            int pxA = Math.Clamp(x + Math.Sign(perpendicular.X), 0, width - 1);
            int pyA = Math.Clamp(y + Math.Sign(perpendicular.Y), 0, height - 1);
            int pxB = Math.Clamp(x - Math.Sign(perpendicular.X), 0, width - 1);
            int pyB = Math.Clamp(y - Math.Sign(perpendicular.Y), 0, height - 1);
            int da = bankDistance[pyA * width + pxA];
            int db = bankDistance[pyB * width + pxB];
            if (dist >= da && dist >= db)
                candidates.Add(idx);
        }

        var ordered = OrderCenterlineCandidates(candidates, axis, width, height);
        var points = new Godot.Collections.Array<Vector2>();
        foreach (int idx in ordered)
            points.Add(new Vector2(idx % width, idx / width));
        return points;
    }

    private static List<int> OrderCenterlineCandidates(List<int> candidates, Vector2 axis, int width, int height)
    {
        SortByProjection(candidates, axis, width);
        var thinnedCandidates = ThinProjectionPlateaus(candidates, axis, width);
        if (thinnedCandidates.Count >= 2)
            candidates = thinnedCandidates;
        if (candidates.Count <= 2)
            return candidates;

        int count = width * height;
        var candidateIndex = new int[count];
        Array.Fill(candidateIndex, -1);
        for (int i = 0; i < candidates.Count; i++)
            candidateIndex[candidates[i]] = i;

        var degrees = new int[candidates.Count];
        var endpoints = new List<int>();
        for (int node = 0; node < candidates.Count; node++)
        {
            degrees[node] = CountCandidateNeighbors(candidates[node], candidateIndex, width, height);
            if (degrees[node] <= 1)
                endpoints.Add(node);
        }

        int startNode = endpoints.Count > 0 ? MinProjectionNode(endpoints, candidates, axis, width) : 0;
        var firstSweep = BreadthFirstFarthest(startNode, candidates, candidateIndex, axis, width, height);
        var secondSweep = BreadthFirstFarthest(firstSweep.FarthestNode, candidates, candidateIndex, axis, width, height);
        var path = ReconstructPath(firstSweep.FarthestNode, secondSweep.FarthestNode, secondSweep.Previous, candidates);

        if (path.Count < 2)
            return candidates;

        float firstProjection = PixelProjection(path[0], axis, width);
        float lastProjection = PixelProjection(path[path.Count - 1], axis, width);
        if (firstProjection > lastProjection)
            path.Reverse();
        return path;
    }

    private static List<int> ThinProjectionPlateaus(List<int> candidates, Vector2 axis, int width)
    {
        var thinned = new List<int>();
        bool hasBin = false;
        int currentBin = 0;
        int bestPixel = 0;
        float bestPerpendicularProjection = 0.0f;
        var perpendicular = new Vector2(-axis.Y, axis.X);

        foreach (int pixel in candidates)
        {
            int bin = (int)MathF.Round(PixelProjection(pixel, axis, width));
            float perpendicularProjection = PixelProjection(pixel, perpendicular, width);
            if (!hasBin || bin != currentBin)
            {
                if (hasBin)
                    thinned.Add(bestPixel);
                hasBin = true;
                currentBin = bin;
                bestPixel = pixel;
                bestPerpendicularProjection = perpendicularProjection;
                continue;
            }

            float absPerpendicular = MathF.Abs(perpendicularProjection);
            float bestAbsPerpendicular = MathF.Abs(bestPerpendicularProjection);
            if (absPerpendicular < bestAbsPerpendicular || (MathF.Abs(absPerpendicular - bestAbsPerpendicular) < 0.0001f && pixel < bestPixel))
            {
                bestPixel = pixel;
                bestPerpendicularProjection = perpendicularProjection;
            }
        }

        if (hasBin)
            thinned.Add(bestPixel);
        return thinned;
    }

    private static int CountCandidateNeighbors(int pixel, int[] candidateIndex, int width, int height)
    {
        int x = pixel % width;
        int y = pixel / width;
        int degree = 0;

        for (int oy = -1; oy <= 1; oy++)
        {
            for (int ox = -1; ox <= 1; ox++)
            {
                if (ox == 0 && oy == 0)
                    continue;
                int nx = x + ox;
                int ny = y + oy;
                if ((uint)nx >= (uint)width || (uint)ny >= (uint)height)
                    continue;
                if (candidateIndex[ny * width + nx] >= 0)
                    degree++;
            }
        }

        return degree;
    }

    private static int MinProjectionNode(List<int> nodes, List<int> candidates, Vector2 axis, int width)
    {
        int bestNode = nodes[0];
        float bestProjection = PixelProjection(candidates[bestNode], axis, width);
        for (int i = 1; i < nodes.Count; i++)
        {
            int node = nodes[i];
            float projection = PixelProjection(candidates[node], axis, width);
            if (projection < bestProjection || (MathF.Abs(projection - bestProjection) < 0.0001f && candidates[node] < candidates[bestNode]))
            {
                bestProjection = projection;
                bestNode = node;
            }
        }
        return bestNode;
    }

    private static BfsResult BreadthFirstFarthest(int startNode, List<int> candidates, int[] candidateIndex, Vector2 axis, int width, int height)
    {
        var previous = new int[candidates.Count];
        var distance = new int[candidates.Count];
        Array.Fill(previous, -1);
        Array.Fill(distance, -1);

        var queue = new Queue<int>();
        distance[startNode] = 0;
        queue.Enqueue(startNode);

        int farthestNode = startNode;
        while (queue.Count > 0)
        {
            int node = queue.Dequeue();
            int pixel = candidates[node];
            if (IsBetterFarthest(node, farthestNode, distance, candidates, axis, width))
                farthestNode = node;

            int x = pixel % width;
            int y = pixel / width;
            for (int oy = -1; oy <= 1; oy++)
            {
                for (int ox = -1; ox <= 1; ox++)
                {
                    if (ox == 0 && oy == 0)
                        continue;
                    int nx = x + ox;
                    int ny = y + oy;
                    if ((uint)nx >= (uint)width || (uint)ny >= (uint)height)
                        continue;
                    int neighborNode = candidateIndex[ny * width + nx];
                    if (neighborNode < 0 || distance[neighborNode] >= 0)
                        continue;
                    distance[neighborNode] = distance[node] + 1;
                    previous[neighborNode] = node;
                    queue.Enqueue(neighborNode);
                }
            }
        }

        return new BfsResult(farthestNode, previous, distance);
    }

    private static bool IsBetterFarthest(int node, int currentBest, int[] distance, List<int> candidates, Vector2 axis, int width)
    {
        if (distance[node] != distance[currentBest])
            return distance[node] > distance[currentBest];
        float projection = PixelProjection(candidates[node], axis, width);
        float bestProjection = PixelProjection(candidates[currentBest], axis, width);
        if (MathF.Abs(projection - bestProjection) > 0.0001f)
            return projection > bestProjection;
        return candidates[node] > candidates[currentBest];
    }

    private static List<int> ReconstructPath(int startNode, int endNode, int[] previous, List<int> candidates)
    {
        var path = new List<int>();
        int node = endNode;
        while (node >= 0)
        {
            path.Add(candidates[node]);
            if (node == startNode)
                break;
            node = previous[node];
        }
        path.Reverse();
        return path;
    }

    private static void SortByProjection(List<int> candidates, Vector2 axis, int width)
    {
        candidates.Sort((a, b) =>
        {
            float pa = PixelProjection(a, axis, width);
            float pb = PixelProjection(b, axis, width);
            if (MathF.Abs(pa - pb) > 0.0001f)
                return pa.CompareTo(pb);
            int ay = a / width;
            int by = b / width;
            if (ay != by)
                return ay.CompareTo(by);
            return (a % width).CompareTo(b % width);
        });
    }

    private static float PixelProjection(int pixel, Vector2 axis, int width)
    {
        return (pixel % width) * axis.X + (pixel / width) * axis.Y;
    }

    private readonly struct BfsResult
    {
        public BfsResult(int farthestNode, int[] previous, int[] distance)
        {
            FarthestNode = farthestNode;
            Previous = previous;
            Distance = distance;
        }

        public int FarthestNode { get; }
        public int[] Previous { get; }
        public int[] Distance { get; }
    }

    private void WriteRiverFlow(byte[] output, List<int> pixels, Vector2 direction, int width, int height)
    {
        byte b = (byte)Math.Clamp(MathF.Round(255.0f * FlowSpeedMetersPerSecond / MathF.Max(0.001f, MaxEncodedSpeedMetersPerSecond)), 1.0f, 255.0f);
        var inComponent = new bool[width * height];
        foreach (int idx in pixels)
            inComponent[idx] = true;

        foreach (int idx in pixels)
        {
            Vector2 localDirection = LocalFlowDirection(idx, inComponent, width, height, direction);
            int outIdx = idx * 4;
            output[outIdx] = EncodeSignedUnit(localDirection.X);
            output[outIdx + 1] = EncodeSignedUnit(localDirection.Y);
            output[outIdx + 2] = b;
            output[outIdx + 3] = 255;
        }
    }

    private static void ExpandRiverFlowGutters(byte[] output, int width, int height, int iterations)
    {
        int count = width * height;
        if (count <= 0 || iterations <= 0)
            return;

        for (int pass = 0; pass < iterations; pass++)
        {
            var next = (byte[])output.Clone();
            for (int idx = 0; idx < count; idx++)
            {
                int outIdx = idx * 4;
                if (output[outIdx + 3] > 0 || output[outIdx + 2] > 0)
                    continue;

                int x = idx % width;
                int y = idx / width;
                int sumR = 0;
                int sumG = 0;
                int sumB = 0;
                int samples = 0;
                for (int oy = -1; oy <= 1; oy++)
                {
                    for (int ox = -1; ox <= 1; ox++)
                    {
                        if (ox == 0 && oy == 0)
                            continue;
                        int nx = x + ox;
                        int ny = y + oy;
                        if ((uint)nx >= (uint)width || (uint)ny >= (uint)height)
                            continue;
                        int ni = (ny * width + nx) * 4;
                        if (output[ni + 2] == 0)
                            continue;
                        sumR += output[ni];
                        sumG += output[ni + 1];
                        sumB += output[ni + 2];
                        samples++;
                    }
                }

                if (samples == 0)
                    continue;
                next[outIdx] = (byte)Math.Clamp(MathF.Round(sumR / (float)samples), 0.0f, 255.0f);
                next[outIdx + 1] = (byte)Math.Clamp(MathF.Round(sumG / (float)samples), 0.0f, 255.0f);
                next[outIdx + 2] = (byte)Math.Clamp(MathF.Round(sumB / (float)samples), 0.0f, 255.0f);
                next[outIdx + 3] = 0;
            }
            Buffer.BlockCopy(next, 0, output, 0, output.Length);
        }
    }

    private static Vector2 LocalFlowDirection(int idx, bool[] inComponent, int width, int height, Vector2 fallback)
    {
        int cx = idx % width;
        int cy = idx / width;
        const int radius = 5;
        double meanX = 0.0;
        double meanY = 0.0;
        int count = 0;

        for (int y = cy - radius; y <= cy + radius; y++)
        {
            for (int x = cx - radius; x <= cx + radius; x++)
            {
                if ((uint)x >= (uint)width || (uint)y >= (uint)height)
                    continue;
                if (!inComponent[y * width + x])
                    continue;
                meanX += x;
                meanY += y;
                count++;
            }
        }

        if (count < 3)
            return fallback.Normalized();

        meanX /= count;
        meanY /= count;
        double covXX = 0.0;
        double covXY = 0.0;
        double covYY = 0.0;

        for (int y = cy - radius; y <= cy + radius; y++)
        {
            for (int x = cx - radius; x <= cx + radius; x++)
            {
                if ((uint)x >= (uint)width || (uint)y >= (uint)height)
                    continue;
                if (!inComponent[y * width + x])
                    continue;
                double dx = x - meanX;
                double dy = y - meanY;
                covXX += dx * dx;
                covXY += dx * dy;
                covYY += dy * dy;
            }
        }

        Vector2 local = PrincipalAxis(covXX, covXY, covYY);
        if (local.Dot(fallback) < 0.0f)
            local = -local;
        return local.Normalized();
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static byte EncodeSignedUnit(float value)
    {
        return (byte)Math.Clamp(MathF.Round((value * 0.5f + 0.5f) * 255.0f), 0.0f, 255.0f);
    }

    private readonly struct ComponentAnalysis
    {
        public int Area { get; init; }
        public Rect2I Bounds { get; init; }
        public float Aspect { get; init; }
        public float MeanWidthMeters { get; init; }
        public bool IsRiver { get; init; }
        public Vector2 Direction { get; init; }
        public float FlowSpeedMetersPerSecond { get; init; }
        public Godot.Collections.Array<Vector2> CenterlinePixels { get; init; }

        public Godot.Collections.Dictionary ToDictionary(int componentId)
        {
            return new Godot.Collections.Dictionary
            {
                ["component_id"] = componentId,
                ["area_pixels"] = Area,
                ["bounds"] = Bounds,
                ["aspect"] = Aspect,
                ["mean_width_meters"] = MeanWidthMeters,
                ["is_river"] = IsRiver,
                ["flow_direction"] = Direction,
                ["flow_speed_meters_per_second"] = FlowSpeedMetersPerSecond,
                ["centerline_pixels"] = CenterlinePixels,
            };
        }
    }
}
