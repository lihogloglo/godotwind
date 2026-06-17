using Godot;
using System;
using System.Collections.Generic;

namespace Godotwind.Native;

/// <summary>
/// Deterministic Morrowind adapter hydrology builder.
/// It consumes source terrain tiles and emits generic Godotwind water flow maps;
/// no core water system depends on Morrowind-specific data.
/// </summary>
[GlobalClass]
public partial class NativeMorrowindHydrologyAtlasBuilder : RefCounted
{
    private const byte StillDirection = 128;
    private const int TerminalNeighborDegree = 1;
    private static readonly (int X, int Y, float Distance)[] Neighbors =
    {
        (-1, -1, 1.41421356f), (0, -1, 1.0f), (1, -1, 1.41421356f),
        (-1, 0, 1.0f),                         (1, 0, 1.0f),
        (-1, 1, 1.41421356f),  (0, 1, 1.0f),  (1, 1, 1.41421356f),
    };

    public Godot.Collections.Dictionary BuildAtlas(
        Godot.Collections.Array regionTiles,
        float vertexSpacingMeters,
        float seaLevelMeters,
        float wetToleranceMeters,
        float flowSpeedMetersPerSecond,
        float maxEncodedSpeedMetersPerSecond)
    {
        if (regionTiles == null || regionTiles.Count == 0)
            return ErrorResult("no region tiles supplied");

        var tiles = ReadTiles(regionTiles);
        if (tiles.Count == 0)
            return ErrorResult("no valid region tiles supplied");

        int tileWidth = tiles[0].Width;
        int tileHeight = tiles[0].Height;
        foreach (var tile in tiles)
        {
            if (tile.Width != tileWidth || tile.Height != tileHeight)
                return ErrorResult("all hydrology atlas tiles must have the same resolution");
        }

        int minX = int.MaxValue;
        int maxX = int.MinValue;
        int minY = int.MaxValue;
        int maxY = int.MinValue;
        foreach (var tile in tiles)
        {
            minX = Math.Min(minX, tile.Region.X);
            maxX = Math.Max(maxX, tile.Region.X);
            minY = Math.Min(minY, tile.Region.Y);
            maxY = Math.Max(maxY, tile.Region.Y);
        }

        int columns = maxX - minX + 1;
        int rows = maxY - minY + 1;
        int width = columns * tileWidth;
        int height = rows * tileHeight;
        int count = width * height;
        var heights = new float[count];
        var active = new bool[count];
        Array.Fill(heights, seaLevelMeters + 64.0f);

        foreach (var tile in tiles)
        {
            int tileX = tile.Region.X - minX;
            int tileY = maxY - tile.Region.Y;
            for (int y = 0; y < tile.Height; y++)
            {
                int dst = (tileY * tileHeight + y) * width + tileX * tileWidth;
                int src = y * tile.Width;
                Array.Copy(tile.Heights, src, heights, dst, tile.Width);
                for (int x = 0; x < tile.Width; x++)
                    active[dst + x] = true;
            }
        }

        var wet = new bool[count];
        for (int i = 0; i < count; i++)
            wet[i] = active[i] && heights[i] <= seaLevelMeters + wetToleranceMeters;

        var profile = HydrologyClassificationProfile.Default;
        var fields = BuildTerrainHydrologyFields(heights, active, wet, width, height);
        var componentsByPixel = new int[count];
        var wetComponents = BuildWetComponents(fields, componentsByPixel);
        var graph = BuildWaterMedialGraph(fields);
        AnnotateGraphWithDrainage(graph, fields);
        var classification = ClassifyWaterGraph(fields, wetComponents, graph, profile);
        var river = new bool[count];
        var components = RasterizeBodyTypesAndFlow(
            fields,
            wetComponents,
            classification,
            componentsByPixel,
            vertexSpacingMeters,
            flowSpeedMetersPerSecond);

        foreach (var component in components)
        {
            if (!component.IsRiver)
                continue;
            foreach (int idx in component.Pixels)
                river[idx] = true;
        }

        var resultRegions = new Godot.Collections.Array<Godot.Collections.Dictionary>();
        foreach (var tile in tiles)
        {
            int tileX = tile.Region.X - minX;
            int tileY = maxY - tile.Region.Y;
            var imageBytes = new byte[tileWidth * tileHeight * 4];
            for (int y = 0; y < tileHeight; y++)
            {
                for (int x = 0; x < tileWidth; x++)
                {
                    int atlasIdx = (tileY * tileHeight + y) * width + tileX * tileWidth + x;
                    int outIdx = (y * tileWidth + x) * 4;
                    if (!wet[atlasIdx])
                    {
                        imageBytes[outIdx + 3] = 0;
                        continue;
                    }

                    if (!river[atlasIdx])
                    {
                        imageBytes[outIdx] = StillDirection;
                        imageBytes[outIdx + 1] = StillDirection;
                        imageBytes[outIdx + 2] = 0;
                        imageBytes[outIdx + 3] = 255;
                        continue;
                    }

                    var dir = DirectionFor(atlasIdx, fields.Downstream, width);
                    imageBytes[outIdx] = EncodeSigned(dir.X);
                    imageBytes[outIdx + 1] = EncodeSigned(dir.Y);
                    imageBytes[outIdx + 2] = (byte)Math.Clamp(
                        MathF.Round(flowSpeedMetersPerSecond / Math.Max(maxEncodedSpeedMetersPerSecond, 0.001f) * 255.0f),
                        1.0f,
                        255.0f);
                    imageBytes[outIdx + 3] = 255;
                }
            }

            var image = Image.CreateFromData(tileWidth, tileHeight, false, Image.Format.Rgba8, imageBytes);
            var regionComponents = ComponentsForTile(components, tile, tileX, tileY, tileWidth, tileHeight, width, vertexSpacingMeters, flowSpeedMetersPerSecond);
            resultRegions.Add(new Godot.Collections.Dictionary
            {
                ["region"] = tile.Region,
                ["image"] = image,
                ["components"] = regionComponents,
                ["river_count"] = CountRivers(regionComponents),
                ["debug_images"] = DebugImagesForTile(
                    wet,
                    river,
                    classification.Ocean,
                    fields.DistanceToShore,
                    fields.Accumulation,
                    componentsByPixel,
                    graph.LinkIds,
                    graph.StreamRanks,
                    classification.SinkIds,
                    tileX,
                    tileY,
                    tileWidth,
                    tileHeight,
                    width,
                    graph.StreamSupportThreshold),
            });
        }

        return new Godot.Collections.Dictionary
        {
            ["error"] = (int)Error.Ok,
            ["message"] = "",
            ["regions"] = resultRegions,
            ["atlas_width"] = width,
            ["atlas_height"] = height,
            ["stream_support_threshold"] = graph.StreamSupportThreshold,
            ["broad_water_distance"] = graph.BroadWaterDistance,
        };
    }

    private static Godot.Collections.Dictionary ErrorResult(string message)
    {
        return new Godot.Collections.Dictionary
        {
            ["error"] = (int)Error.InvalidParameter,
            ["message"] = message,
            ["regions"] = new Godot.Collections.Array(),
        };
    }

    private sealed class Tile
    {
        public Vector2I Region;
        public int Width;
        public int Height;
        public float[] Heights = Array.Empty<float>();
    }

    private sealed class Component
    {
        public int Id;
        public bool IsRiver;
        public bool OceanContact;
        public List<int> Pixels = new();
        public Rect2I Bounds;
        public Vector2 FlowDirection = Vector2.Right;
        public float MeanWidthMeters;
    }

    private sealed class HydrologyClassificationProfile
    {
        public bool IncludeMinorStreams { get; private init; }
        public bool PreferFalseNegativesNearOcean { get; private init; }
        public string ManualOverrideMaskPath { get; private init; } = string.Empty;

        public static HydrologyClassificationProfile Default => new()
        {
            IncludeMinorStreams = true,
            PreferFalseNegativesNearOcean = true,
            ManualOverrideMaskPath = string.Empty,
        };
    }

    private sealed class TerrainHydrologyFields
    {
        public int Width;
        public int Height;
        public bool[] Active = Array.Empty<bool>();
        public bool[] Wet = Array.Empty<bool>();
        public float[] ConditionedHeights = Array.Empty<float>();
        public int[] Downstream = Array.Empty<int>();
        public int[] Accumulation = Array.Empty<int>();
        public int[] DistanceToShore = Array.Empty<int>();
    }

    private sealed class WetComponent
    {
        public int Id;
        public List<int> Pixels = new();
        public Rect2I Bounds;
        public bool TouchesBoundary;
    }

    private sealed class WaterMedialGraph
    {
        public bool[] Broad = Array.Empty<bool>();
        public bool[] Candidate = Array.Empty<bool>();
        public bool[] StreamSupported = Array.Empty<bool>();
        public int[] LinkIds = Array.Empty<int>();
        public int[] StreamRanks = Array.Empty<int>();
        public int BroadWaterDistance;
        public int StreamSupportThreshold;
    }

    private sealed class WaterGraphClassification
    {
        public bool[] Ocean = Array.Empty<bool>();
        public bool[] River = Array.Empty<bool>();
        public int[] SinkIds = Array.Empty<int>();
    }

    private static List<Tile> ReadTiles(Godot.Collections.Array regionTiles)
    {
        var tiles = new List<Tile>();
        foreach (Variant value in regionTiles)
        {
            if (value.VariantType != Variant.Type.Dictionary)
                continue;
            var dict = value.AsGodotDictionary();
            var tile = new Tile();
            if (dict.TryGetValue("region", out Variant regionValue))
                tile.Region = regionValue.AsVector2I();
            Image? image = null;
            if (dict.TryGetValue("heightmap", out Variant imageValue) && imageValue.AsGodotObject() is Image sourceImage)
                image = sourceImage;
            if (image != null)
            {
                tile.Width = image.GetWidth();
                tile.Height = image.GetHeight();
                tile.Heights = ReadImageHeights(image);
            }
            else
            {
                tile.Width = dict.TryGetValue("width", out Variant w) ? w.AsInt32() : 0;
                tile.Height = dict.TryGetValue("height", out Variant h) ? h.AsInt32() : 0;
                tile.Heights = dict.TryGetValue("heights", out Variant heightsValue)
                    ? heightsValue.AsFloat32Array()
                    : Array.Empty<float>();
            }
            if (tile.Width > 0 && tile.Height > 0 && tile.Heights.Length >= tile.Width * tile.Height)
                tiles.Add(tile);
        }
        return tiles;
    }

    private static float[] ReadImageHeights(Image image)
    {
        Image source = image;
        if (source.GetFormat() != Image.Format.Rf)
        {
            source = (Image)image.Duplicate();
            source.Convert(Image.Format.Rf);
        }
        int width = source.GetWidth();
        int height = source.GetHeight();
        byte[] bytes = source.GetData();
        var heights = new float[width * height];
        for (int i = 0; i < heights.Length; i++)
            heights[i] = BitConverter.ToSingle(bytes, i * 4);
        return heights;
    }

    private static float[] PriorityFloodCondition(float[] heights, bool[] active, int width, int height)
    {
        var conditioned = (float[])heights.Clone();
        var visited = new bool[heights.Length];
        var queue = new PriorityQueue<int, float>();
        void Enqueue(int x, int y)
        {
            if (x < 0 || y < 0 || x >= width || y >= height)
                return;
            int idx = y * width + x;
            if (!active[idx] || visited[idx])
                return;
            visited[idx] = true;
            queue.Enqueue(idx, conditioned[idx]);
        }

        for (int x = 0; x < width; x++)
        {
            Enqueue(x, 0);
            Enqueue(x, height - 1);
        }
        for (int y = 1; y < height - 1; y++)
        {
            Enqueue(0, y);
            Enqueue(width - 1, y);
        }

        const float epsilon = 0.001f;
        while (queue.Count > 0)
        {
            int idx = queue.Dequeue();
            int x = idx % width;
            int y = idx / width;
            foreach (var (dx, dy, _) in Neighbors)
            {
                int nx = x + dx;
                int ny = y + dy;
                if (nx < 0 || ny < 0 || nx >= width || ny >= height)
                    continue;
                int nidx = ny * width + nx;
                if (!active[nidx] || visited[nidx])
                    continue;
                if (conditioned[nidx] <= conditioned[idx])
                    conditioned[nidx] = conditioned[idx] + epsilon;
                visited[nidx] = true;
                queue.Enqueue(nidx, conditioned[nidx]);
            }
        }

        return conditioned;
    }

    private static int[] BuildFlowDirections(float[] heights, bool[] active, int width, int height)
    {
        var downstream = new int[heights.Length];
        Array.Fill(downstream, -1);
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                int idx = y * width + x;
                if (!active[idx])
                    continue;
                float bestSlope = 0.0f;
                int best = -1;
                foreach (var (dx, dy, distance) in Neighbors)
                {
                    int nx = x + dx;
                    int ny = y + dy;
                    if (nx < 0 || ny < 0 || nx >= width || ny >= height)
                        continue;
                    int nidx = ny * width + nx;
                    if (!active[nidx])
                        continue;
                    float slope = (heights[idx] - heights[nidx]) / distance;
                    if (slope > bestSlope)
                    {
                        bestSlope = slope;
                        best = nidx;
                    }
                }
                downstream[idx] = best;
            }
        }
        return downstream;
    }

    private static int[] BuildFlowAccumulation(float[] heights, int[] downstream, bool[] active, int width, int height)
    {
        int count = heights.Length;
        var order = new int[count];
        for (int i = 0; i < count; i++)
            order[i] = i;
        Array.Sort(order, (a, b) => heights[b].CompareTo(heights[a]));
        var accumulation = new int[count];
        for (int i = 0; i < count; i++)
            accumulation[i] = active[i] ? 1 : 0;
        foreach (int idx in order)
        {
            int next = downstream[idx];
            if (active[idx] && next >= 0)
                accumulation[next] += accumulation[idx];
        }
        return accumulation;
    }

    private static TerrainHydrologyFields BuildTerrainHydrologyFields(float[] heights, bool[] active, bool[] wet, int width, int height)
    {
        var conditioned = PriorityFloodCondition(heights, active, width, height);
        var downstream = BuildFlowDirections(conditioned, active, width, height);
        return new TerrainHydrologyFields
        {
            Width = width,
            Height = height,
            Active = active,
            Wet = wet,
            ConditionedHeights = conditioned,
            Downstream = downstream,
            Accumulation = BuildFlowAccumulation(conditioned, downstream, active, width, height),
            DistanceToShore = BuildDistanceToShore(wet, width, height),
        };
    }

    private static int[] BuildDistanceToShore(bool[] wet, int width, int height)
    {
        var distance = new int[wet.Length];
        Array.Fill(distance, int.MaxValue);
        var queue = new Queue<int>();
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                int idx = y * width + x;
                if (!wet[idx] || TouchesDryOrBoundary(idx, wet, width, height))
                {
                    distance[idx] = wet[idx] ? 1 : 0;
                    queue.Enqueue(idx);
                }
            }
        }

        while (queue.Count > 0)
        {
            int idx = queue.Dequeue();
            int x = idx % width;
            int y = idx / width;
            foreach (var (dx, dy, _) in Neighbors)
            {
                int nx = x + dx;
                int ny = y + dy;
                if (nx < 0 || ny < 0 || nx >= width || ny >= height)
                    continue;
                int nidx = ny * width + nx;
                if (!wet[nidx])
                    continue;
                int nextDistance = distance[idx] + 1;
                if (nextDistance < distance[nidx])
                {
                    distance[nidx] = nextDistance;
                    queue.Enqueue(nidx);
                }
            }
        }
        return distance;
    }

    private static bool TouchesDryOrBoundary(int idx, bool[] wet, int width, int height)
    {
        int x = idx % width;
        int y = idx / width;
        if (x == 0 || y == 0 || x == width - 1 || y == height - 1)
            return true;
        foreach (var (dx, dy, _) in Neighbors)
        {
            int nx = x + dx;
            int ny = y + dy;
            if (nx < 0 || ny < 0 || nx >= width || ny >= height)
                return true;
            if (!wet[ny * width + nx])
                return true;
        }
        return false;
    }

    private static List<WetComponent> BuildWetComponents(TerrainHydrologyFields fields, int[] componentsByPixel)
    {
        var visited = new bool[fields.Wet.Length];
        var components = new List<WetComponent>();
        int nextId = 1;
        for (int start = 0; start < fields.Wet.Length; start++)
        {
            if (!fields.Wet[start] || visited[start])
                continue;
            var pixels = FloodWetComponent(start, fields.Wet, visited, fields.Width, fields.Height);
            var component = new WetComponent
            {
                Id = nextId++,
                Pixels = pixels,
                Bounds = BoundsFor(pixels, fields.Width),
            };
            foreach (int idx in pixels)
            {
                componentsByPixel[idx] = component.Id;
                int x = idx % fields.Width;
                int y = idx / fields.Width;
                component.TouchesBoundary |= x == 0 || y == 0 || x == fields.Width - 1 || y == fields.Height - 1;
            }
            components.Add(component);
        }
        return components;
    }

    private static WaterMedialGraph BuildWaterMedialGraph(TerrainHydrologyFields fields)
    {
        var wetDistances = ValuesWhere(fields.DistanceToShore, fields.Wet);
        int broadWaterDistance = SelectOtsuThreshold(wetDistances);
        var broad = new bool[fields.Wet.Length];
        var candidate = new bool[fields.Wet.Length];
        for (int i = 0; i < fields.Wet.Length; i++)
        {
            if (!fields.Wet[i])
                continue;
            broad[i] = fields.DistanceToShore[i] > broadWaterDistance;
            candidate[i] = !broad[i];
        }

        var candidateAccumulation = ValuesWhere(fields.Accumulation, candidate);
        int streamThreshold = SelectOtsuThreshold(candidateAccumulation);
        var supported = new bool[fields.Wet.Length];
        for (int i = 0; i < supported.Length; i++)
            supported[i] = candidate[i] && fields.Accumulation[i] > streamThreshold;

        return new WaterMedialGraph
        {
            Broad = broad,
            Candidate = candidate,
            StreamSupported = supported,
            LinkIds = new int[fields.Wet.Length],
            StreamRanks = new int[fields.Wet.Length],
            BroadWaterDistance = broadWaterDistance,
            StreamSupportThreshold = streamThreshold,
        };
    }

    private static void AnnotateGraphWithDrainage(WaterMedialGraph graph, TerrainHydrologyFields fields)
    {
        var visited = new bool[graph.Candidate.Length];
        var linkMaxAccumulation = new Dictionary<int, int>();
        int nextLink = 1;
        for (int start = 0; start < graph.Candidate.Length; start++)
        {
            if (!graph.Candidate[start] || visited[start])
                continue;
            int linkId = nextLink++;
            int maxAccumulation = 0;
            var queue = new Queue<int>();
            visited[start] = true;
            queue.Enqueue(start);
            while (queue.Count > 0)
            {
                int idx = queue.Dequeue();
                graph.LinkIds[idx] = linkId;
                maxAccumulation = Math.Max(maxAccumulation, fields.Accumulation[idx]);
                int x = idx % fields.Width;
                int y = idx / fields.Width;
                foreach (var (dx, dy, _) in Neighbors)
                {
                    int nx = x + dx;
                    int ny = y + dy;
                    if (nx < 0 || ny < 0 || nx >= fields.Width || ny >= fields.Height)
                        continue;
                    int nidx = ny * fields.Width + nx;
                    if (graph.Candidate[nidx] && !visited[nidx])
                    {
                        visited[nidx] = true;
                        queue.Enqueue(nidx);
                    }
                }
            }
            linkMaxAccumulation[linkId] = maxAccumulation;
        }

        var ordered = new List<KeyValuePair<int, int>>(linkMaxAccumulation);
        ordered.Sort((a, b) => a.Value.CompareTo(b.Value));
        var ranks = new Dictionary<int, int>();
        int rank = 1;
        foreach (var pair in ordered)
            ranks[pair.Key] = rank++;
        for (int i = 0; i < graph.LinkIds.Length; i++)
        {
            if (graph.LinkIds[i] > 0)
                graph.StreamRanks[i] = ranks[graph.LinkIds[i]];
        }
    }

    private static WaterGraphClassification ClassifyWaterGraph(
        TerrainHydrologyFields fields,
        IReadOnlyList<WetComponent> wetComponents,
        WaterMedialGraph graph,
        HydrologyClassificationProfile profile)
    {
        var ocean = BuildBroadOceanMask(fields.Wet, graph.Broad, fields.Width, fields.Height);
        var sinkIds = LabelSinkComponents(fields.Wet, graph.Broad, ocean, fields.Width, fields.Height);
        var river = new bool[fields.Wet.Length];
        var pixelsByLink = new Dictionary<int, List<int>>();
        for (int i = 0; i < graph.LinkIds.Length; i++)
        {
            int linkId = graph.LinkIds[i];
            if (linkId <= 0)
                continue;
            if (!pixelsByLink.TryGetValue(linkId, out var pixels))
            {
                pixels = new List<int>();
                pixelsByLink[linkId] = pixels;
            }
            pixels.Add(i);
        }

        foreach (var pair in pixelsByLink)
        {
            var pixels = pair.Value;
            bool hasStreamSupport = false;
            bool hasSourceTerminal = false;
            bool touchesSink = false;
            bool everyTerminalIsOcean = true;
            bool drainsIntoSink = false;
            var terminalSinkIds = new HashSet<int>();
            foreach (int idx in pixels)
            {
                hasStreamSupport |= graph.StreamSupported[idx];
                touchesSink |= TouchesMask(idx, graph.Broad, fields.Width, fields.Height);
                int next = fields.Downstream[idx];
                if (next >= 0 && next < fields.Wet.Length && !graph.Candidate[next] && graph.Broad[next])
                    drainsIntoSink = true;
                bool terminal = CandidateNeighborDegree(idx, graph.Candidate, fields.Width, fields.Height) <= TerminalNeighborDegree;
                if (!terminal)
                    continue;
                bool terminalTouchesOcean = TouchesMask(idx, ocean, fields.Width, fields.Height);
                everyTerminalIsOcean &= terminalTouchesOcean;
                bool terminalTouchesBroad = TouchesMask(idx, graph.Broad, fields.Width, fields.Height);
                hasSourceTerminal |= !terminalTouchesOcean && !terminalTouchesBroad;
                AddTouchedSinkIds(idx, sinkIds, terminalSinkIds, fields.Width, fields.Height);
            }

            bool oceanStrait = profile.PreferFalseNegativesNearOcean && everyTerminalIsOcean;
            bool continuityFallback = profile.IncludeMinorStreams && terminalSinkIds.Count > 1 && !everyTerminalIsOcean;
            if ((hasStreamSupport || continuityFallback) && touchesSink && drainsIntoSink && (hasSourceTerminal || continuityFallback || !profile.PreferFalseNegativesNearOcean) && !oceanStrait)
            {
                foreach (int idx in pixels)
                    river[idx] = true;
            }
        }

        return new WaterGraphClassification
        {
            Ocean = ocean,
            River = river,
            SinkIds = sinkIds,
        };
    }

    private static List<Component> RasterizeBodyTypesAndFlow(
        TerrainHydrologyFields fields,
        IReadOnlyList<WetComponent> wetComponents,
        WaterGraphClassification classification,
        int[] componentsByPixel,
        float vertexSpacing,
        float flowSpeed)
    {
        var result = new List<Component>();
        int nextId = 1;
        var riverVisited = new bool[fields.Wet.Length];
        for (int start = 0; start < fields.Wet.Length; start++)
        {
            if (!classification.River[start] || riverVisited[start])
                continue;
            var pixels = FloodMaskComponent(start, classification.River, riverVisited, fields.Width, fields.Height);
            result.Add(new Component
            {
                Id = nextId++,
                IsRiver = true,
                OceanContact = TouchesAny(pixels, classification.Ocean, fields.Width, fields.Height),
                Pixels = pixels,
                Bounds = BoundsFor(pixels, fields.Width),
                FlowDirection = MeanFlowDirection(pixels, fields.Downstream, fields.Width),
                MeanWidthMeters = MeanWidthFromDistance(pixels, fields.DistanceToShore) * vertexSpacing,
            });
        }

        foreach (var wetComponent in wetComponents)
        {
            var stillPixels = new List<int>();
            foreach (int idx in wetComponent.Pixels)
            {
                if (!classification.River[idx])
                    stillPixels.Add(idx);
            }
            if (stillPixels.Count == 0)
                continue;
            result.Add(new Component
            {
                Id = nextId++,
                IsRiver = false,
                OceanContact = wetComponent.TouchesBoundary || TouchesAny(stillPixels, classification.Ocean, fields.Width, fields.Height),
                Pixels = stillPixels,
                Bounds = BoundsFor(stillPixels, fields.Width),
                FlowDirection = Vector2.Zero,
                MeanWidthMeters = MeanWidthFromDistance(stillPixels, fields.DistanceToShore) * vertexSpacing,
            });
        }
        return result;
    }

    private static List<int> ValuesWhere(int[] values, bool[] mask)
    {
        var result = new List<int>();
        for (int i = 0; i < values.Length; i++)
        {
            if (mask[i])
                result.Add(values[i]);
        }
        return result;
    }

    private static int SelectOtsuThreshold(IReadOnlyList<int> values)
    {
        if (values.Count == 0)
            return 0;
        var histogram = new SortedDictionary<int, int>();
        long total = 0;
        foreach (int value in values)
        {
            int v = Math.Max(value, 0);
            histogram.TryGetValue(v, out int count);
            histogram[v] = count + 1;
            total += v;
        }
        if (histogram.Count == 1)
            return values[0];

        int sampleCount = values.Count;
        long backgroundCount = 0;
        long backgroundSum = 0;
        double bestVariance = double.NegativeInfinity;
        int bestThreshold = 0;
        foreach (var pair in histogram)
        {
            backgroundCount += pair.Value;
            backgroundSum += (long)pair.Key * pair.Value;
            long foregroundCount = sampleCount - backgroundCount;
            if (backgroundCount == 0 || foregroundCount == 0)
                continue;
            double backgroundMean = backgroundSum / (double)backgroundCount;
            double foregroundMean = (total - backgroundSum) / (double)foregroundCount;
            double betweenClassVariance = backgroundCount * (double)foregroundCount * Math.Pow(backgroundMean - foregroundMean, 2.0);
            if (betweenClassVariance > bestVariance)
            {
                bestVariance = betweenClassVariance;
                bestThreshold = pair.Key;
            }
        }
        return bestThreshold;
    }

    private static int[] LabelSinkComponents(bool[] wet, bool[] broad, bool[] ocean, int width, int height)
    {
        var sinkIds = new int[wet.Length];
        var visited = new bool[wet.Length];
        int nextId = 1;
        for (int start = 0; start < wet.Length; start++)
        {
            if (!wet[start] || !broad[start] || visited[start])
                continue;
            var pixels = FloodMaskComponent(start, broad, visited, width, height);
            int sinkId = ocean[start] ? 1 : ++nextId;
            foreach (int idx in pixels)
                sinkIds[idx] = sinkId;
        }
        return sinkIds;
    }

    private static int CandidateNeighborDegree(int idx, bool[] candidate, int width, int height)
    {
        int degree = 0;
        int x = idx % width;
        int y = idx / width;
        foreach (var (dx, dy, _) in Neighbors)
        {
            int nx = x + dx;
            int ny = y + dy;
            if (nx < 0 || ny < 0 || nx >= width || ny >= height)
                continue;
            if (candidate[ny * width + nx])
                degree++;
        }
        return degree;
    }

    private static List<int> FloodMaskComponent(int start, bool[] mask, bool[] visited, int width, int height)
    {
        var pixels = new List<int>();
        var queue = new Queue<int>();
        visited[start] = true;
        queue.Enqueue(start);
        while (queue.Count > 0)
        {
            int idx = queue.Dequeue();
            pixels.Add(idx);
            int x = idx % width;
            int y = idx / width;
            foreach (var (dx, dy, _) in Neighbors)
            {
                int nx = x + dx;
                int ny = y + dy;
                if (nx < 0 || ny < 0 || nx >= width || ny >= height)
                    continue;
                int nidx = ny * width + nx;
                if (mask[nidx] && !visited[nidx])
                {
                    visited[nidx] = true;
                    queue.Enqueue(nidx);
                }
            }
        }
        return pixels;
    }

    private static bool TouchesAny(IReadOnlyList<int> pixels, bool[] mask, int width, int height)
    {
        foreach (int idx in pixels)
        {
            if (TouchesMask(idx, mask, width, height))
                return true;
        }
        return false;
    }

    private static float MeanWidthFromDistance(IReadOnlyList<int> pixels, int[] distanceToShore)
    {
        float sum = 0.0f;
        foreach (int idx in pixels)
            sum += Math.Max(distanceToShore[idx], 1) * 2.0f;
        return sum / Math.Max(pixels.Count, 1);
    }

    private static bool[] BuildBroadOceanMask(bool[] wet, bool[] broad, int width, int height)
    {
        var ocean = new bool[wet.Length];
        var queue = new Queue<int>();
        void TrySeed(int x, int y)
        {
            int idx = y * width + x;
            if (wet[idx] && broad[idx] && !ocean[idx])
            {
                ocean[idx] = true;
                queue.Enqueue(idx);
            }
        }
        for (int x = 0; x < width; x++)
        {
            TrySeed(x, 0);
            TrySeed(x, height - 1);
        }
        for (int y = 1; y < height - 1; y++)
        {
            TrySeed(0, y);
            TrySeed(width - 1, y);
        }
        while (queue.Count > 0)
        {
            int idx = queue.Dequeue();
            int x = idx % width;
            int y = idx / width;
            foreach (var (dx, dy, _) in Neighbors)
            {
                int nx = x + dx;
                int ny = y + dy;
                if (nx < 0 || ny < 0 || nx >= width || ny >= height)
                    continue;
                int nidx = ny * width + nx;
                if (wet[nidx] && broad[nidx] && !ocean[nidx])
                {
                    ocean[nidx] = true;
                    queue.Enqueue(nidx);
                }
            }
        }
        return ocean;
    }

    private static List<int> FloodWetComponent(int start, bool[] wet, bool[] visited, int width, int height)
    {
        var pixels = new List<int>();
        var queue = new Queue<int>();
        visited[start] = true;
        queue.Enqueue(start);
        while (queue.Count > 0)
        {
            int idx = queue.Dequeue();
            pixels.Add(idx);
            int x = idx % width;
            int y = idx / width;
            foreach (var (dx, dy, _) in Neighbors)
            {
                int nx = x + dx;
                int ny = y + dy;
                if (nx < 0 || ny < 0 || nx >= width || ny >= height)
                    continue;
                int nidx = ny * width + nx;
                if (wet[nidx] && !visited[nidx])
                {
                    visited[nidx] = true;
                    queue.Enqueue(nidx);
                }
            }
        }
        return pixels;
    }

    private static bool TouchesMask(int idx, bool[] mask, int width, int height)
    {
        int x = idx % width;
        int y = idx / width;
        foreach (var (dx, dy, _) in Neighbors)
        {
            int nx = x + dx;
            int ny = y + dy;
            if (nx < 0 || ny < 0 || nx >= width || ny >= height)
                continue;
            if (mask[ny * width + nx])
                return true;
        }
        return false;
    }

    private static void AddTouchedSinkIds(int idx, int[] sinkIds, HashSet<int> result, int width, int height)
    {
        int x = idx % width;
        int y = idx / width;
        foreach (var (dx, dy, _) in Neighbors)
        {
            int nx = x + dx;
            int ny = y + dy;
            if (nx < 0 || ny < 0 || nx >= width || ny >= height)
                continue;
            int sinkId = sinkIds[ny * width + nx];
            if (sinkId > 0)
                result.Add(sinkId);
        }
    }

    private static Rect2I BoundsFor(IReadOnlyList<int> pixels, int width)
    {
        int minX = int.MaxValue;
        int minY = int.MaxValue;
        int maxX = 0;
        int maxY = 0;
        foreach (int idx in pixels)
        {
            int x = idx % width;
            int y = idx / width;
            minX = Math.Min(minX, x);
            minY = Math.Min(minY, y);
            maxX = Math.Max(maxX, x);
            maxY = Math.Max(maxY, y);
        }
        return new Rect2I(minX, minY, maxX - minX + 1, maxY - minY + 1);
    }

    private static Vector2 MeanFlowDirection(IReadOnlyList<int> pixels, int[] downstream, int width)
    {
        var sum = Vector2.Zero;
        foreach (int idx in pixels)
            sum += DirectionFor(idx, downstream, width);
        return sum.LengthSquared() > 0.0001f ? sum.Normalized() : Vector2.Right;
    }

    private static Vector2 DirectionFor(int idx, int[] downstream, int width)
    {
        int next = downstream[idx];
        if (next < 0)
            return Vector2.Right;
        int x = idx % width;
        int y = idx / width;
        int nx = next % width;
        int ny = next / width;
        var dir = new Vector2(nx - x, ny - y);
        return dir.LengthSquared() > 0.0001f ? dir.Normalized() : Vector2.Right;
    }

    private static Godot.Collections.Array<Godot.Collections.Dictionary> ComponentsForTile(
        IReadOnlyList<Component> components,
        Tile tile,
        int tileX,
        int tileY,
        int tileWidth,
        int tileHeight,
        int atlasWidth,
        float vertexSpacing,
        float flowSpeed)
    {
        var result = new Godot.Collections.Array<Godot.Collections.Dictionary>();
        var tileRect = new Rect2I(tileX * tileWidth, tileY * tileHeight, tileWidth, tileHeight);
        foreach (var component in components)
        {
            var clippedPixels = new List<int>();
            foreach (int idx in component.Pixels)
            {
                int x = idx % atlasWidth;
                int y = idx / atlasWidth;
                if (tileRect.HasPoint(new Vector2I(x, y)))
                    clippedPixels.Add(idx);
            }
            if (clippedPixels.Count == 0)
                continue;
            var localBounds = BoundsForLocal(clippedPixels, atlasWidth, tileRect.Position.X, tileRect.Position.Y);
            var centerline = component.IsRiver
                ? OrderedCenterline(clippedPixels, atlasWidth, tileRect.Position.X, tileRect.Position.Y, component.FlowDirection)
                : new Godot.Collections.Array<Vector2>();
            result.Add(new Godot.Collections.Dictionary
            {
                ["component_id"] = component.Id,
                ["source_label"] = component.Id,
                ["area_pixels"] = clippedPixels.Count,
                ["bounds"] = localBounds,
                ["aspect"] = Math.Max(localBounds.Size.X, localBounds.Size.Y) / Math.Max((float)Math.Min(localBounds.Size.X, localBounds.Size.Y), 1.0f),
                ["mean_width_meters"] = Math.Max(component.MeanWidthMeters, vertexSpacing),
                ["is_river"] = component.IsRiver,
                ["body_type"] = component.IsRiver ? "river" : (component.OceanContact ? "ocean" : "lake"),
                ["ocean_contact"] = component.OceanContact,
                ["flow_direction"] = component.FlowDirection,
                ["flow_speed_meters_per_second"] = component.IsRiver ? flowSpeed : 0.0f,
                ["centerline_pixels"] = centerline,
            });
        }
        return result;
    }

    private static Rect2I BoundsForLocal(IReadOnlyList<int> pixels, int atlasWidth, int originX, int originY)
    {
        int minX = int.MaxValue;
        int minY = int.MaxValue;
        int maxX = 0;
        int maxY = 0;
        foreach (int idx in pixels)
        {
            int x = idx % atlasWidth - originX;
            int y = idx / atlasWidth - originY;
            minX = Math.Min(minX, x);
            minY = Math.Min(minY, y);
            maxX = Math.Max(maxX, x);
            maxY = Math.Max(maxY, y);
        }
        return new Rect2I(minX, minY, maxX - minX + 1, maxY - minY + 1);
    }

    private static Godot.Collections.Array<Vector2> OrderedCenterline(IReadOnlyList<int> pixels, int atlasWidth, int originX, int originY, Vector2 flowDirection)
    {
        var points = new List<Vector2>(pixels.Count);
        foreach (int idx in pixels)
            points.Add(new Vector2(idx % atlasWidth - originX, idx / atlasWidth - originY));
        Vector2 axis = flowDirection.LengthSquared() > 0.0001f ? flowDirection.Normalized() : Vector2.Right;
        points.Sort((a, b) => a.Dot(axis).CompareTo(b.Dot(axis)));
        var sampled = new Godot.Collections.Array<Vector2>();
        int stride = Math.Max(1, points.Count / 96);
        for (int i = 0; i < points.Count; i += stride)
            sampled.Add(points[i]);
        if (points.Count > 0 && sampled[^1] != points[^1])
            sampled.Add(points[^1]);
        return sampled;
    }

    private static int CountRivers(Godot.Collections.Array<Godot.Collections.Dictionary> components)
    {
        int count = 0;
        foreach (var component in components)
        {
            if (component.TryGetValue("is_river", out Variant isRiver) && isRiver.AsBool())
                count++;
        }
        return count;
    }

    private static Godot.Collections.Dictionary DebugImagesForTile(
        bool[] wet,
        bool[] river,
        bool[] ocean,
        int[] distanceToShore,
        int[] accumulation,
        int[] componentIds,
        int[] linkIds,
        int[] streamRanks,
        int[] sinkIds,
        int tileX,
        int tileY,
        int tileWidth,
        int tileHeight,
        int atlasWidth,
        int streamSupportThreshold)
    {
        var wetMask = new byte[tileWidth * tileHeight * 4];
        var oceanCore = new byte[tileWidth * tileHeight * 4];
        var candidate = new byte[tileWidth * tileHeight * 4];
        var accepted = new byte[tileWidth * tileHeight * 4];
        var sink = new byte[tileWidth * tileHeight * 4];
        var reason = new byte[tileWidth * tileHeight * 4];
        var body = new byte[tileWidth * tileHeight * 4];
        var accum = new byte[tileWidth * tileHeight * 4];
        var bank = new byte[tileWidth * tileHeight * 4];
        var ids = new byte[tileWidth * tileHeight * 4];
        var links = new byte[tileWidth * tileHeight * 4];
        var ranks = new byte[tileWidth * tileHeight * 4];
        var basins = new byte[tileWidth * tileHeight * 4];
        int maxAccum = Math.Max(streamSupportThreshold, 1);
        int maxDistance = 1;
        int maxRank = 1;
        for (int y = 0; y < tileHeight; y++)
        {
            for (int x = 0; x < tileWidth; x++)
            {
                int idx = (tileY * tileHeight + y) * atlasWidth + tileX * tileWidth + x;
                if (wet[idx])
                {
                    maxAccum = Math.Max(maxAccum, accumulation[idx]);
                    maxDistance = Math.Max(maxDistance, distanceToShore[idx]);
                    maxRank = Math.Max(maxRank, streamRanks[idx]);
                }
            }
        }
        for (int y = 0; y < tileHeight; y++)
        {
            for (int x = 0; x < tileWidth; x++)
            {
                int idx = (tileY * tileHeight + y) * atlasWidth + tileX * tileWidth + x;
                int outIdx = (y * tileWidth + x) * 4;
                if (!wet[idx])
                    continue;
                bool graphPixel = linkIds[idx] > 0;

                wetMask[outIdx] = 30;
                wetMask[outIdx + 1] = 150;
                wetMask[outIdx + 2] = 255;
                wetMask[outIdx + 3] = 160;

                if (ocean[idx])
                {
                    oceanCore[outIdx] = 20;
                    oceanCore[outIdx + 1] = 60;
                    oceanCore[outIdx + 2] = 255;
                    oceanCore[outIdx + 3] = 210;
                }

                if (graphPixel)
                {
                    candidate[outIdx] = 255;
                    candidate[outIdx + 1] = 210;
                    candidate[outIdx + 3] = 210;
                }

                if (river[idx])
                {
                    body[outIdx + 1] = 230;
                    body[outIdx + 2] = 180;
                    accepted[outIdx + 1] = 230;
                    accepted[outIdx + 2] = 180;
                    accepted[outIdx + 3] = 225;
                }
                else if (ocean[idx])
                {
                    body[outIdx + 2] = 255;
                }
                else
                {
                    body[outIdx] = 60;
                    body[outIdx + 1] = 120;
                    body[outIdx + 2] = 255;
                }
                body[outIdx + 3] = 220;

                byte a = (byte)Math.Clamp(MathF.Round(accumulation[idx] / Math.Max((float)maxAccum, 1.0f) * 255.0f), 0.0f, 255.0f);
                accum[outIdx] = a;
                accum[outIdx + 1] = (byte)Math.Min(255, a * 2);
                accum[outIdx + 3] = 220;

                byte w = (byte)Math.Clamp(MathF.Round(distanceToShore[idx] / Math.Max((float)maxDistance, 1.0f) * 255.0f), 0.0f, 255.0f);
                bank[outIdx] = w;
                bank[outIdx + 1] = (byte)(255 - w);
                bank[outIdx + 3] = 200;

                int id = componentIds[idx];
                ids[outIdx] = (byte)((id * 53) & 255);
                ids[outIdx + 1] = (byte)((id * 97) & 255);
                ids[outIdx + 2] = (byte)((id * 193) & 255);
                ids[outIdx + 3] = 210;

                int linkId = linkIds[idx];
                if (linkId > 0)
                {
                    links[outIdx] = (byte)((linkId * 71) & 255);
                    links[outIdx + 1] = (byte)((linkId * 131) & 255);
                    links[outIdx + 2] = (byte)((linkId * 197) & 255);
                    links[outIdx + 3] = 220;
                }

                int streamRank = streamRanks[idx];
                if (streamRank > 0)
                {
                    byte rank = (byte)Math.Clamp(MathF.Round(streamRank / Math.Max((float)maxRank, 1.0f) * 255.0f), 0.0f, 255.0f);
                    ranks[outIdx] = rank;
                    ranks[outIdx + 1] = (byte)(255 - rank);
                    ranks[outIdx + 2] = 80;
                    ranks[outIdx + 3] = 220;
                }

                int sinkId = sinkIds[idx];
                if (sinkId > 0)
                {
                    sink[outIdx] = (byte)((sinkId * 89) & 255);
                    sink[outIdx + 1] = (byte)((sinkId * 149) & 255);
                    sink[outIdx + 2] = (byte)((sinkId * 211) & 255);
                    sink[outIdx + 3] = 220;
                    basins[outIdx] = 80;
                    basins[outIdx + 1] = 170;
                    basins[outIdx + 2] = 255;
                    basins[outIdx + 3] = 190;
                }

                if (river[idx])
                {
                    reason[outIdx + 1] = 230;
                    reason[outIdx + 2] = 180;
                }
                else if (ocean[idx])
                {
                    reason[outIdx + 2] = 255;
                }
                else if (sinkId > 0)
                {
                    reason[outIdx] = 80;
                    reason[outIdx + 1] = 150;
                    reason[outIdx + 2] = 255;
                }
                else if (graphPixel && accumulation[idx] <= streamSupportThreshold)
                {
                    reason[outIdx] = 255;
                    reason[outIdx + 1] = 210;
                }
                else if (graphPixel)
                {
                    reason[outIdx] = 255;
                    reason[outIdx + 2] = 140;
                }
                else
                {
                    reason[outIdx] = 60;
                    reason[outIdx + 1] = 120;
                    reason[outIdx + 2] = 255;
                }
                reason[outIdx + 3] = 205;
            }
        }
        return new Godot.Collections.Dictionary
        {
            ["wet_mask"] = Image.CreateFromData(tileWidth, tileHeight, false, Image.Format.Rgba8, wetMask),
            ["ocean_core"] = Image.CreateFromData(tileWidth, tileHeight, false, Image.Format.Rgba8, oceanCore),
            ["corridor_candidates"] = Image.CreateFromData(tileWidth, tileHeight, false, Image.Format.Rgba8, candidate),
            ["accepted_rivers"] = Image.CreateFromData(tileWidth, tileHeight, false, Image.Format.Rgba8, accepted),
            ["outlet_distance"] = Image.CreateFromData(tileWidth, tileHeight, false, Image.Format.Rgba8, sink),
            ["rejection_reason"] = Image.CreateFromData(tileWidth, tileHeight, false, Image.Format.Rgba8, reason),
            ["local_width"] = Image.CreateFromData(tileWidth, tileHeight, false, Image.Format.Rgba8, bank),
            ["body_type"] = Image.CreateFromData(tileWidth, tileHeight, false, Image.Format.Rgba8, body),
            ["flow_accumulation"] = Image.CreateFromData(tileWidth, tileHeight, false, Image.Format.Rgba8, accum),
            ["bank_distance"] = Image.CreateFromData(tileWidth, tileHeight, false, Image.Format.Rgba8, bank),
            ["component_id"] = Image.CreateFromData(tileWidth, tileHeight, false, Image.Format.Rgba8, ids),
            ["graph_link"] = Image.CreateFromData(tileWidth, tileHeight, false, Image.Format.Rgba8, links),
            ["stream_rank"] = Image.CreateFromData(tileWidth, tileHeight, false, Image.Format.Rgba8, ranks),
            ["sink_id"] = Image.CreateFromData(tileWidth, tileHeight, false, Image.Format.Rgba8, sink),
            ["basin_nodes"] = Image.CreateFromData(tileWidth, tileHeight, false, Image.Format.Rgba8, basins),
        };
    }

    private static byte EncodeSigned(float value)
    {
        return (byte)Math.Clamp(MathF.Round((value * 0.5f + 0.5f) * 255.0f), 0.0f, 255.0f);
    }
}
