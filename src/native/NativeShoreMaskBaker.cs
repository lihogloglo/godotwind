using Godot;
using System;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;

namespace Godotwind.Native;

/// <summary>
/// High-performance shore distance mask baker using Jump Flooding Algorithm (JFA).
/// Replaces the GDScript ShoreMaskBaker inner loops with parallelized C# code.
///
/// Output: RGBA8 image where:
///   R = shore factor (smoothstepped, 0 = at shore/land, 1 = deep ocean)
///   G = gradient direction X (encoded as 0.5 + 0.5 * dir.x)
///   B = gradient direction Y (encoded as 0.5 + 0.5 * dir.y)
///   A = water membership + raw normalized water-side distance
///       (land = 0, water = 0.5 + 0.5 * raw_norm)
///
/// Performance: ~40-100x faster than GDScript (Parallel.For on classification
/// + gradient computation, sequential JFA passes with parallel row processing).
/// </summary>
[GlobalClass]
public partial class NativeShoreMaskBaker : RefCounted
{
    public int Resolution { get; set; } = 4096;
    public float SeaLevel { get; set; } = 0.0f;
    public float FadeDistance { get; set; } = 50.0f;

    // World bounds: (posX, posY, sizeX, sizeY)
    public float BoundsX { get; set; } = -8000.0f;
    public float BoundsY { get; set; } = -8000.0f;
    public float BoundsW { get; set; } = 16000.0f;
    public float BoundsH { get; set; } = 16000.0f;

    /// <summary>
    /// Bake shore mask from a terrain heightmap sampled at the given resolution.
    /// Accepts a pre-sampled height array (row-major, resolution×resolution floats)
    /// to avoid Godot API calls from C# threads.
    ///
    /// The GDScript caller samples terrain heights on the main thread, then passes
    /// the flat float array here for the heavy JFA + gradient computation.
    /// </summary>
    public Image BakeFromHeights(float[] heights)
    {
        int res = Resolution;
        float fadeDist = FadeDistance;
        float texelSize = BoundsW / (float)res;

        // Step 1: Classify water/land + find shore seeds (parallel)
        var isWater = new bool[res * res];
        var seeds = new int[res * res];
        Array.Fill(seeds, -1);

        Parallel.For(0, res, y =>
        {
            for (int x = 0; x < res; x++)
            {
                int idx = y * res + x;
                isWater[idx] = heights[idx] < SeaLevel;
            }
        });

        // Find shore pixels (water adjacent to land, 8-connected) — parallel per row
        Parallel.For(0, res, y =>
        {
            for (int x = 0; x < res; x++)
            {
                int idx = y * res + x;
                if (!isWater[idx]) continue;

                bool adjacentToLand = false;
                for (int dy = -1; dy <= 1 && !adjacentToLand; dy++)
                {
                    for (int dx = -1; dx <= 1 && !adjacentToLand; dx++)
                    {
                        if (dx == 0 && dy == 0) continue;
                        int nx = x + dx, ny = y + dy;
                        if (nx >= 0 && nx < res && ny >= 0 && ny < res)
                        {
                            if (!isWater[ny * res + nx])
                                adjacentToLand = true;
                        }
                    }
                }
                if (adjacentToLand)
                    seeds[idx] = idx;
            }
        });

        // Step 2: JFA passes (log2(res) passes, each parallelized by row)
        int step = res / 2;
        while (step >= 1)
        {
            var newSeeds = new int[res * res];
            Array.Copy(seeds, newSeeds, seeds.Length);

            Parallel.For(0, res, y =>
            {
                JfaRow(seeds, newSeeds, isWater, y, res, step);
            });

            seeds = newSeeds;
            step /= 2;
        }

        // Step 3: Compute RGBA8 output (parallel)
        var output = new byte[res * res * 4];

        Parallel.For(0, res, y =>
        {
            ComputeOutputRow(seeds, isWater, output, y, res, texelSize, fadeDist);
        });

        return Image.CreateFromData(res, res, false, Image.Format.Rgba8, output);
    }

    [MethodImpl(MethodImplOptions.AggressiveOptimization)]
    private static void JfaRow(int[] seeds, int[] newSeeds, bool[] isWater, int y, int res, int step)
    {
        ReadOnlySpan<int> offX = stackalloc int[] { -step, 0, step, -step, step, -step, 0, step };
        ReadOnlySpan<int> offY = stackalloc int[] { -step, -step, -step, 0, 0, step, step, step };

        for (int x = 0; x < res; x++)
        {
            int idx = y * res + x;
            if (!isWater[idx]) continue;

            int bestSeed = seeds[idx];
            float bestDist = DistSq(x, y, bestSeed, res);

            for (int d = 0; d < 8; d++)
            {
                int nx = x + offX[d], ny = y + offY[d];
                if (nx < 0 || nx >= res || ny < 0 || ny >= res) continue;

                int neighborSeed = seeds[ny * res + nx];
                if (neighborSeed < 0) continue;

                float dist = DistSq(x, y, neighborSeed, res);
                if (dist < bestDist)
                {
                    bestDist = dist;
                    bestSeed = neighborSeed;
                }
            }
            newSeeds[idx] = bestSeed;
        }
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static float DistSq(int x, int y, int seedIdx, int res)
    {
        if (seedIdx < 0) return float.MaxValue;
        int sx = seedIdx % res, sy = seedIdx / res;
        float dx = x - sx, dy = y - sy;
        return dx * dx + dy * dy;
    }

    [MethodImpl(MethodImplOptions.AggressiveOptimization)]
    private static void ComputeOutputRow(int[] seeds, bool[] isWater, byte[] output, int y, int res, float texelSize, float fadeDist)
    {
        for (int x = 0; x < res; x++)
        {
            int idx = y * res + x;
            int outIdx = idx * 4;

            if (!isWater[idx])
            {
                // Land: R=0, G=0.5 (neutral dir), B=0.5, A=0.
                // Water starts at A=0.5, so consumers can distinguish land
                // from a water shoreline pixel whose dampening factor is also 0.
                output[outIdx] = 0;
                output[outIdx + 1] = 128;
                output[outIdx + 2] = 128;
                output[outIdx + 3] = 0;
                continue;
            }

            int seedIdx = seeds[idx];
            float shoreFactor, rawNorm, gradX, gradY;

            if (seedIdx < 0)
            {
                // Deep ocean — no shore found
                shoreFactor = 1.0f;
                rawNorm = 1.0f;
                gradX = 0.0f;
                gradY = 0.0f;
            }
            else if (seedIdx == idx)
            {
                // At shore pixel itself
                shoreFactor = 0.0f;
                rawNorm = 0.0f;
                gradX = 0.0f;
                gradY = 0.0f;
            }
            else
            {
                int sx = seedIdx % res, sy = seedIdx / res;
                float fdx = x - sx, fdy = y - sy;
                float pixelDist = MathF.Sqrt(fdx * fdx + fdy * fdy);
                float worldDist = pixelDist * texelSize;

                shoreFactor = Smoothstep(0.0f, fadeDist, worldDist);
                rawNorm = Math.Clamp(worldDist / fadeDist, 0.0f, 1.0f);

                if (pixelDist > 0.001f)
                {
                    gradX = fdx / pixelDist;
                    gradY = fdy / pixelDist;
                }
                else
                {
                    gradX = 0.0f;
                    gradY = 0.0f;
                }
            }

            float encodedWaterDistance = 0.5f + 0.5f * rawNorm;

            // Encode: R=shore_factor, G=grad_x (0.5+0.5*dir), B=grad_y,
            // A=water membership + water-side raw_norm.
            output[outIdx] = (byte)(Math.Clamp(shoreFactor, 0.0f, 1.0f) * 255.0f + 0.5f);
            output[outIdx + 1] = (byte)(Math.Clamp(gradX * 0.5f + 0.5f, 0.0f, 1.0f) * 255.0f + 0.5f);
            output[outIdx + 2] = (byte)(Math.Clamp(gradY * 0.5f + 0.5f, 0.0f, 1.0f) * 255.0f + 0.5f);
            output[outIdx + 3] = (byte)(Math.Clamp(encodedWaterDistance, 0.0f, 1.0f) * 255.0f + 0.5f);
        }
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static float Smoothstep(float edge0, float edge1, float x)
    {
        float t = Math.Clamp((x - edge0) / (edge1 - edge0), 0.0f, 1.0f);
        return t * t * (3.0f - 2.0f * t);
    }
}
