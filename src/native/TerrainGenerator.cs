using Godot;
using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Godotwind.Native;

/// <summary>
/// High-performance terrain generation for Morrowind LAND data.
/// Replaces the GDScript terrain_manager.gd pixel loops with optimized C# code.
///
/// Performance gains:
/// - Direct buffer manipulation (no set_pixel overhead)
/// - Native float math without boxing
/// - Better cache locality in tight loops
/// - ~50-100x faster than GDScript for heightmap generation
/// </summary>
[GlobalClass]
public partial class TerrainGenerator : RefCounted
{
    // Morrowind terrain constants
    public const int MW_LAND_SIZE = 65;      // Vertices per cell side
    public const int MW_TEXTURE_SIZE = 16;   // Texture tiles per cell side
    public const int CELLS_PER_REGION = 4;   // 4x4 cells per Terrain3D region
    public const int CELL_CROP_SIZE = 64;    // Cropped cell size for Terrain3D

    // Height scale for MW -> Godot conversion
    // MW units to meters: 1 / 70 (same as CoordinateSystem.UNITS_PER_METER)
    private const float HEIGHT_SCALE = 1.0f / 70.0f;

    /// <summary>
    /// Generate a heightmap image from raw height data.
    /// Input: float[] heights - 65x65 height values in MW units (row-major, south to north)
    /// Output: Image in FORMAT_RF (32-bit float per pixel)
    /// </summary>
    public static Image GenerateHeightmap(float[] heights)
    {
        if (heights == null || heights.Length != MW_LAND_SIZE * MW_LAND_SIZE)
        {
            GD.PushWarning($"TerrainGenerator: Invalid heights array (expected {MW_LAND_SIZE * MW_LAND_SIZE}, got {heights?.Length ?? 0})");
            return CreateFlatHeightmap();
        }

        var img = Image.CreateEmpty(MW_LAND_SIZE, MW_LAND_SIZE, false, Image.Format.Rf);
        var buffer = new byte[MW_LAND_SIZE * MW_LAND_SIZE * 4]; // 4 bytes per float

        unsafe
        {
            fixed (byte* bufPtr = buffer)
            fixed (float* heightPtr = heights)
            {
                float* outPtr = (float*)bufPtr;

                for (int y = 0; y < MW_LAND_SIZE; y++)
                {
                    // FLIP Y axis: MW y=0 (south) -> image y=64 (bottom)
                    int imgY = MW_LAND_SIZE - 1 - y;
                    int srcRowOffset = y * MW_LAND_SIZE;
                    int dstRowOffset = imgY * MW_LAND_SIZE;

                    for (int x = 0; x < MW_LAND_SIZE; x++)
                    {
                        float mwHeight = heightPtr[srcRowOffset + x];
                        outPtr[dstRowOffset + x] = mwHeight * HEIGHT_SCALE;
                    }
                }
            }
        }

        img.SetData(MW_LAND_SIZE, MW_LAND_SIZE, false, Image.Format.Rf, buffer);
        return img;
    }

    /// <summary>
    /// Generate a color map image from raw vertex color data.
    /// Input: byte[] colors - 65x65x3 RGB values (row-major, south to north)
    /// Output: Image in FORMAT_RGB8
    /// </summary>
    public static Image GenerateColorMap(byte[]? colors)
    {
        var img = Image.CreateEmpty(MW_LAND_SIZE, MW_LAND_SIZE, false, Image.Format.Rgb8);

        if (colors == null || colors.Length != MW_LAND_SIZE * MW_LAND_SIZE * 3)
        {
            // Fill with white if no colors
            img.Fill(Colors.White);
            return img;
        }

        var buffer = new byte[MW_LAND_SIZE * MW_LAND_SIZE * 3];

        unsafe
        {
            fixed (byte* bufPtr = buffer)
            fixed (byte* colorPtr = colors)
            {
                for (int y = 0; y < MW_LAND_SIZE; y++)
                {
                    // FLIP Y axis to match heightmap orientation
                    int imgY = MW_LAND_SIZE - 1 - y;
                    int srcRowOffset = y * MW_LAND_SIZE * 3;
                    int dstRowOffset = imgY * MW_LAND_SIZE * 3;

                    // Copy entire row (faster than per-pixel)
                    Buffer.MemoryCopy(
                        colorPtr + srcRowOffset,
                        bufPtr + dstRowOffset,
                        MW_LAND_SIZE * 3,
                        MW_LAND_SIZE * 3);
                }
            }
        }

        img.SetData(MW_LAND_SIZE, MW_LAND_SIZE, false, Image.Format.Rgb8, buffer);
        return img;
    }

    /// <summary>
    /// Generate a control map image from texture indices.
    /// Input: int[] textureIndices - 16x16 texture slot indices
    ///        int[] slotMapping - MW texture index -> Terrain3D slot mapping
    /// Output: Image in FORMAT_RF (Terrain3D control map format)
    /// </summary>
    public static Image GenerateControlMap(int[] textureIndices, Func<int, int>? slotMapper = null)
    {
        var img = Image.CreateEmpty(MW_LAND_SIZE, MW_LAND_SIZE, false, Image.Format.Rf);
        var buffer = new byte[MW_LAND_SIZE * MW_LAND_SIZE * 4];

        // Default mapper: identity with slot 0 for default
        slotMapper ??= mwIdx => mwIdx == 0 ? 0 : ((mwIdx - 1) % 31) + 1;

        float verticesPerTex = (MW_LAND_SIZE - 1) / (float)MW_TEXTURE_SIZE; // ~4.0

        unsafe
        {
            fixed (byte* bufPtr = buffer)
            fixed (int* texPtr = textureIndices)
            {
                float* outPtr = (float*)bufPtr;

                for (int y = 0; y < MW_LAND_SIZE; y++)
                {
                    // FLIP Y axis
                    int imgY = MW_LAND_SIZE - 1 - y;
                    int dstRowOffset = imgY * MW_LAND_SIZE;

                    for (int x = 0; x < MW_LAND_SIZE; x++)
                    {
                        // Calculate texture cell coordinates
                        int texX = Math.Min((int)(x / verticesPerTex), MW_TEXTURE_SIZE - 1);
                        int texY = Math.Min((int)(y / verticesPerTex), MW_TEXTURE_SIZE - 1);

                        int mwTexIdx = texPtr != null && textureIndices != null
                            ? textureIndices[texY * MW_TEXTURE_SIZE + texX]
                            : 0;

                        int slot = slotMapper(mwTexIdx);
                        float control = EncodeControlValue(slot, 0, 0);
                        outPtr[dstRowOffset + x] = control;
                    }
                }
            }
        }

        img.SetData(MW_LAND_SIZE, MW_LAND_SIZE, false, Image.Format.Rf, buffer);
        return img;
    }

    /// <summary>
    /// Generate a combined region heightmap (CELLS_PER_REGION x CELLS_PER_REGION cells = 256x256).
    /// Input: float[][] cellHeights - Array of 16 cell height arrays (null for empty cells)
    /// Output: Image in FORMAT_RF (256x256 pixels)
    /// </summary>
    public static Image GenerateCombinedHeightmap(float[]?[] cellHeights)
    {
        const int regionSize = CELLS_PER_REGION * CELL_CROP_SIZE; // 256
        var img = Image.CreateEmpty(regionSize, regionSize, false, Image.Format.Rf);
        var buffer = new byte[regionSize * regionSize * 4];

        // Fill with zero height
        Array.Clear(buffer, 0, buffer.Length);

        if (cellHeights == null)
        {
            img.SetData(regionSize, regionSize, false, Image.Format.Rf, buffer);
            return img;
        }

        unsafe
        {
            fixed (byte* bufPtr = buffer)
            {
                float* outPtr = (float*)bufPtr;

                for (int localY = 0; localY < CELLS_PER_REGION; localY++)
                {
                    for (int localX = 0; localX < CELLS_PER_REGION; localX++)
                    {
                        int cellIdx = localY * CELLS_PER_REGION + localX;
                        if (cellIdx >= cellHeights.Length || cellHeights[cellIdx] == null)
                            continue;

                        float[]? cellData = cellHeights[cellIdx];
                        if (cellData == null || cellData.Length != MW_LAND_SIZE * MW_LAND_SIZE)
                            continue;

                        // Calculate pixel offset within combined image
                        // local_y=0 (south) -> img_y = highest (because we flip Y)
                        int imgOffsetX = localX * CELL_CROP_SIZE;
                        int imgOffsetY = (CELLS_PER_REGION - 1 - localY) * CELL_CROP_SIZE;

                        fixed (float* cellPtr = cellData)
                        {
                            // Blit cropped 64x64 cell data
                            for (int cy = 0; cy < CELL_CROP_SIZE; cy++)
                            {
                                // Source: flip Y within cell
                                int srcY = MW_LAND_SIZE - 1 - cy;
                                int srcRowOffset = srcY * MW_LAND_SIZE;

                                // Destination
                                int dstY = imgOffsetY + cy;
                                int dstRowOffset = dstY * regionSize + imgOffsetX;

                                for (int cx = 0; cx < CELL_CROP_SIZE; cx++)
                                {
                                    float mwHeight = cellPtr[srcRowOffset + cx];
                                    outPtr[dstRowOffset + cx] = mwHeight * HEIGHT_SCALE;
                                }
                            }
                        }
                    }
                }
            }
        }

        img.SetData(regionSize, regionSize, false, Image.Format.Rf, buffer);
        return img;
    }

    /// <summary>
    /// Generate a combined region control map (256x256).
    /// </summary>
    public static Image GenerateCombinedControlMap(int[]?[] cellTextures, Func<int, int>? slotMapper = null)
    {
        const int regionSize = CELLS_PER_REGION * CELL_CROP_SIZE; // 256
        var img = Image.CreateEmpty(regionSize, regionSize, false, Image.Format.Rf);
        var buffer = new byte[regionSize * regionSize * 4];

        slotMapper ??= mwIdx => mwIdx == 0 ? 0 : ((mwIdx - 1) % 31) + 1;
        float defaultControl = EncodeControlValue(0, 0, 0);

        // Fill with default texture
        unsafe
        {
            fixed (byte* bufPtr = buffer)
            {
                float* outPtr = (float*)bufPtr;
                for (int i = 0; i < regionSize * regionSize; i++)
                    outPtr[i] = defaultControl;
            }
        }

        if (cellTextures == null)
        {
            img.SetData(regionSize, regionSize, false, Image.Format.Rf, buffer);
            return img;
        }

        float verticesPerTex = (MW_LAND_SIZE - 1) / (float)MW_TEXTURE_SIZE;

        unsafe
        {
            fixed (byte* bufPtr = buffer)
            {
                float* outPtr = (float*)bufPtr;

                for (int localY = 0; localY < CELLS_PER_REGION; localY++)
                {
                    for (int localX = 0; localX < CELLS_PER_REGION; localX++)
                    {
                        int cellIdx = localY * CELLS_PER_REGION + localX;
                        if (cellIdx >= cellTextures.Length || cellTextures[cellIdx] == null)
                            continue;

                        int[]? cellData = cellTextures[cellIdx];
                        if (cellData == null || cellData.Length != MW_TEXTURE_SIZE * MW_TEXTURE_SIZE)
                            continue;

                        int imgOffsetX = localX * CELL_CROP_SIZE;
                        int imgOffsetY = (CELLS_PER_REGION - 1 - localY) * CELL_CROP_SIZE;

                        fixed (int* texPtr = cellData)
                        {
                            for (int cy = 0; cy < CELL_CROP_SIZE; cy++)
                            {
                                // Source Y (flip within cell)
                                int srcY = MW_LAND_SIZE - 1 - cy - 1; // -1 because we're cropping
                                if (srcY < 0) srcY = 0;

                                int texY = Math.Min((int)(srcY / verticesPerTex), MW_TEXTURE_SIZE - 1);
                                int dstY = imgOffsetY + cy;
                                int dstRowOffset = dstY * regionSize + imgOffsetX;

                                for (int cx = 0; cx < CELL_CROP_SIZE; cx++)
                                {
                                    int texX = Math.Min((int)(cx / verticesPerTex), MW_TEXTURE_SIZE - 1);
                                    int mwTexIdx = texPtr[texY * MW_TEXTURE_SIZE + texX];
                                    int slot = slotMapper(mwTexIdx);
                                    outPtr[dstRowOffset + cx] = EncodeControlValue(slot, 0, 0);
                                }
                            }
                        }
                    }
                }
            }
        }

        img.SetData(regionSize, regionSize, false, Image.Format.Rf, buffer);
        return img;
    }

    /// <summary>
    /// Generate a combined region color map (256x256).
    /// </summary>
    public static Image GenerateCombinedColorMap(byte[]?[] cellColors)
    {
        const int regionSize = CELLS_PER_REGION * CELL_CROP_SIZE; // 256
        var img = Image.CreateEmpty(regionSize, regionSize, false, Image.Format.Rgb8);
        var buffer = new byte[regionSize * regionSize * 3];

        // Fill with white
        for (int i = 0; i < buffer.Length; i++)
            buffer[i] = 255;

        if (cellColors == null)
        {
            img.SetData(regionSize, regionSize, false, Image.Format.Rgb8, buffer);
            return img;
        }

        unsafe
        {
            fixed (byte* bufPtr = buffer)
            {
                for (int localY = 0; localY < CELLS_PER_REGION; localY++)
                {
                    for (int localX = 0; localX < CELLS_PER_REGION; localX++)
                    {
                        int cellIdx = localY * CELLS_PER_REGION + localX;
                        if (cellIdx >= cellColors.Length || cellColors[cellIdx] == null)
                            continue;

                        byte[]? cellData = cellColors[cellIdx];
                        if (cellData == null || cellData.Length != MW_LAND_SIZE * MW_LAND_SIZE * 3)
                            continue;

                        int imgOffsetX = localX * CELL_CROP_SIZE;
                        int imgOffsetY = (CELLS_PER_REGION - 1 - localY) * CELL_CROP_SIZE;

                        fixed (byte* colorPtr = cellData)
                        {
                            for (int cy = 0; cy < CELL_CROP_SIZE; cy++)
                            {
                                // Source Y (flip within cell)
                                int srcY = MW_LAND_SIZE - 1 - cy - 1;
                                if (srcY < 0) srcY = 0;
                                int srcRowOffset = srcY * MW_LAND_SIZE * 3;

                                int dstY = imgOffsetY + cy;
                                int dstRowOffset = (dstY * regionSize + imgOffsetX) * 3;

                                // Copy row
                                Buffer.MemoryCopy(
                                    colorPtr + srcRowOffset,
                                    bufPtr + dstRowOffset,
                                    CELL_CROP_SIZE * 3,
                                    CELL_CROP_SIZE * 3);
                            }
                        }
                    }
                }
            }
        }

        img.SetData(regionSize, regionSize, false, Image.Format.Rgb8, buffer);
        return img;
    }

    /// <summary>
    /// Create a flat (zero height) heightmap.
    /// </summary>
    public static Image CreateFlatHeightmap()
    {
        var img = Image.CreateEmpty(MW_LAND_SIZE, MW_LAND_SIZE, false, Image.Format.Rf);
        var buffer = new byte[MW_LAND_SIZE * MW_LAND_SIZE * 4];
        Array.Clear(buffer, 0, buffer.Length);
        img.SetData(MW_LAND_SIZE, MW_LAND_SIZE, false, Image.Format.Rf, buffer);
        return img;
    }

    /// <summary>
    /// Encode a Terrain3D control map value.
    /// Format matches Terrain3D documentation:
    /// - Base texture ID (bits 27-31): 5 bits, 0-31
    /// - Overlay texture ID (bits 22-26): 5 bits, 0-31
    /// - Texture blend (bits 14-21): 8 bits, 0-255
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static float EncodeControlValue(int baseTex, int overlayTex, int blend)
    {
        uint value = 0;
        value |= ((uint)(baseTex & 0x1F)) << 27;      // Bits 27-31
        value |= ((uint)(overlayTex & 0x1F)) << 22;   // Bits 22-26
        value |= ((uint)(blend & 0xFF)) << 14;        // Bits 14-21

        // Reinterpret bits as float
        return BitConverter.UInt32BitsToSingle(value);
    }

    /// <summary>
    /// Decode a Terrain3D control map value.
    /// </summary>
    public static (int baseTex, int overlayTex, int blend) DecodeControlValue(float control)
    {
        uint bits = BitConverter.SingleToUInt32Bits(control);
        int baseTex = (int)((bits >> 27) & 0x1F);
        int overlayTex = (int)((bits >> 22) & 0x1F);
        int blend = (int)((bits >> 14) & 0xFF);
        return (baseTex, overlayTex, blend);
    }
}
