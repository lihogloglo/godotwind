using Godot;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace Godotwind.Native;

/// <summary>
/// Binary cache for ESM data.
/// Saves parsed ESM records to a binary file for instant loading on subsequent runs.
///
/// Cache format:
/// - Header (32 bytes): magic, version, ESM hash, record counts
/// - Statics section: id + model pairs
/// - Doors section: id + model pairs
/// - Activators section: id + model pairs
/// - Containers section: id + model pairs
/// - Lights section: id + model pairs
/// - Cells section: header + references
/// - Lands section: grid + heightmap + textures
/// - LandTextures section: id + texture path
///
/// Expected load time: < 50ms (vs ~8 seconds for full ESM + conversion)
/// </summary>
[GlobalClass]
public partial class ESMCache : RefCounted
{
    private const string CACHE_MAGIC = "ESMCACHE";
    private const int CACHE_VERSION = 1;

    // Statistics
    public float LoadTimeMs { get; private set; } = 0f;
    public float SaveTimeMs { get; private set; } = 0f;
    public string LastError { get; private set; } = "";

    /// <summary>
    /// Check if a valid cache exists for the given ESM file.
    /// </summary>
    public static bool CacheExists(string esmPath, string cachePath)
    {
        if (!File.Exists(cachePath))
            return false;

        try
        {
            using var stream = File.OpenRead(cachePath);
            using var reader = new BinaryReader(stream, Encoding.UTF8, leaveOpen: true);

            // Read and verify magic
            var magic = Encoding.ASCII.GetString(reader.ReadBytes(8));
            if (magic != CACHE_MAGIC)
                return false;

            // Read and verify version
            int version = reader.ReadInt32();
            if (version != CACHE_VERSION)
                return false;

            // Read stored hash
            var storedHash = reader.ReadBytes(16);

            // Compute current ESM hash
            var currentHash = ComputeFileHash(esmPath);
            if (currentHash == null)
                return false;

            // Compare hashes
            for (int i = 0; i < 16; i++)
            {
                if (storedHash[i] != currentHash[i])
                    return false;
            }

            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Save ESM data to cache file.
    /// </summary>
    public Error Save(NativeESMLoader loader, string esmPath, string cachePath)
    {
        var sw = Stopwatch.StartNew();

        try
        {
            // Ensure directory exists
            var dir = Path.GetDirectoryName(cachePath);
            if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
                Directory.CreateDirectory(dir);

            // Compute ESM file hash
            var hash = ComputeFileHash(esmPath);
            if (hash == null)
            {
                LastError = "Failed to compute ESM file hash";
                return Error.Failed;
            }

            using var stream = File.Create(cachePath);
            using var writer = new BinaryWriter(stream, Encoding.UTF8, leaveOpen: true);

            // Write header
            writer.Write(Encoding.ASCII.GetBytes(CACHE_MAGIC)); // 8 bytes
            writer.Write(CACHE_VERSION);                         // 4 bytes
            writer.Write(hash);                                  // 16 bytes
            writer.Write(0);                                     // 4 bytes reserved

            // Write record counts
            writer.Write(loader.Statics.Count);
            writer.Write(loader.Doors.Count);
            writer.Write(loader.Activators.Count);
            writer.Write(loader.Containers.Count);
            writer.Write(loader.Lights.Count);
            writer.Write(loader.Cells.Count);
            writer.Write(loader.Lands.Count);
            writer.Write(loader.LandTextures.Count);

            // Write statics
            WriteModelRecords(writer, loader.Statics);

            // Write doors
            WriteDoorRecords(writer, loader.Doors);

            // Write activators
            WriteActivatorRecords(writer, loader.Activators);

            // Write containers
            WriteContainerRecords(writer, loader.Containers);

            // Write lights
            WriteLightRecords(writer, loader.Lights);

            // Write cells
            WriteCells(writer, loader.Cells);

            // Write lands
            WriteLands(writer, loader.Lands);

            // Write land textures
            WriteLandTextures(writer, loader.LandTextures);

            sw.Stop();
            SaveTimeMs = (float)sw.Elapsed.TotalMilliseconds;

            GD.Print($"ESMCache: Saved cache in {SaveTimeMs:F1}ms ({stream.Length / 1024:N0} KB)");
            return Error.Ok;
        }
        catch (Exception e)
        {
            LastError = $"Failed to save cache: {e.Message}";
            GD.PushError($"ESMCache: {LastError}");
            return Error.Failed;
        }
    }

    /// <summary>
    /// Load ESM data from cache file.
    /// </summary>
    public Error Load(NativeESMLoader loader, string cachePath)
    {
        var sw = Stopwatch.StartNew();

        try
        {
            // Load entire file into memory for fast reading
            var buffer = File.ReadAllBytes(cachePath);
            using var stream = new MemoryStream(buffer);
            using var reader = new BinaryReader(stream, Encoding.UTF8, leaveOpen: true);

            // Read and verify header
            var magic = Encoding.ASCII.GetString(reader.ReadBytes(8));
            if (magic != CACHE_MAGIC)
            {
                LastError = "Invalid cache file magic";
                return Error.FileCorrupt;
            }

            int version = reader.ReadInt32();
            if (version != CACHE_VERSION)
            {
                LastError = $"Cache version mismatch: {version} vs {CACHE_VERSION}";
                return Error.FileCorrupt;
            }

            // Skip hash (already validated in CacheExists)
            reader.ReadBytes(16);
            reader.ReadInt32(); // reserved

            // Read record counts
            int staticsCount = reader.ReadInt32();
            int doorsCount = reader.ReadInt32();
            int activatorsCount = reader.ReadInt32();
            int containersCount = reader.ReadInt32();
            int lightsCount = reader.ReadInt32();
            int cellsCount = reader.ReadInt32();
            int landsCount = reader.ReadInt32();
            int landTexturesCount = reader.ReadInt32();

            // Read statics
            ReadStatics(reader, loader.Statics, staticsCount);

            // Read doors
            ReadDoors(reader, loader.Doors, doorsCount);

            // Read activators
            ReadActivators(reader, loader.Activators, activatorsCount);

            // Read containers
            ReadContainers(reader, loader.Containers, containersCount);

            // Read lights
            ReadLights(reader, loader.Lights, lightsCount);

            // Read cells
            ReadCells(reader, loader.Cells, loader.ExteriorCells, cellsCount);

            // Read lands
            ReadLands(reader, loader.Lands, landsCount);

            // Read land textures
            ReadLandTextures(reader, loader.LandTextures, landTexturesCount);

            sw.Stop();
            LoadTimeMs = (float)sw.Elapsed.TotalMilliseconds;

            GD.Print($"ESMCache: Loaded cache in {LoadTimeMs:F1}ms");
            return Error.Ok;
        }
        catch (Exception e)
        {
            LastError = $"Failed to load cache: {e.Message}";
            GD.PushError($"ESMCache: {LastError}");
            return Error.Failed;
        }
    }

    // =========================================================================
    // WRITE HELPERS
    // =========================================================================

    private static void WriteString(BinaryWriter writer, string s)
    {
        var bytes = Encoding.UTF8.GetBytes(s ?? "");
        writer.Write((ushort)bytes.Length);
        writer.Write(bytes);
    }

    private static void WriteModelRecords(BinaryWriter writer, Godot.Collections.Dictionary<string, NativeStaticRecord> records)
    {
        foreach (var kvp in records)
        {
            WriteString(writer, kvp.Key);
            WriteString(writer, kvp.Value.RecordId);
            WriteString(writer, kvp.Value.Model);
            writer.Write(kvp.Value.IsDeleted);
        }
    }

    private static void WriteDoorRecords(BinaryWriter writer, Godot.Collections.Dictionary<string, NativeDoorRecord> records)
    {
        foreach (var kvp in records)
        {
            WriteString(writer, kvp.Key);
            WriteString(writer, kvp.Value.RecordId);
            WriteString(writer, kvp.Value.Model);
            writer.Write(kvp.Value.IsDeleted);
        }
    }

    private static void WriteActivatorRecords(BinaryWriter writer, Godot.Collections.Dictionary<string, NativeActivatorRecord> records)
    {
        foreach (var kvp in records)
        {
            WriteString(writer, kvp.Key);
            WriteString(writer, kvp.Value.RecordId);
            WriteString(writer, kvp.Value.Model);
            writer.Write(kvp.Value.IsDeleted);
        }
    }

    private static void WriteContainerRecords(BinaryWriter writer, Godot.Collections.Dictionary<string, NativeContainerRecord> records)
    {
        foreach (var kvp in records)
        {
            WriteString(writer, kvp.Key);
            WriteString(writer, kvp.Value.RecordId);
            WriteString(writer, kvp.Value.Model);
            writer.Write(kvp.Value.IsDeleted);
        }
    }

    private static void WriteLightRecords(BinaryWriter writer, Godot.Collections.Dictionary<string, NativeLightRecord> records)
    {
        foreach (var kvp in records)
        {
            WriteString(writer, kvp.Key);
            WriteString(writer, kvp.Value.RecordId);
            WriteString(writer, kvp.Value.Model);
            writer.Write(kvp.Value.IsDeleted);
        }
    }

    private static void WriteCells(BinaryWriter writer, Godot.Collections.Dictionary<string, NativeCellRecord> cells)
    {
        foreach (var kvp in cells)
        {
            var cell = kvp.Value;

            // Header
            WriteString(writer, kvp.Key);
            WriteString(writer, cell.RecordId);
            WriteString(writer, cell.Name);
            WriteString(writer, cell.RegionId);
            writer.Write(cell.Flags);
            writer.Write(cell.GridX);
            writer.Write(cell.GridY);

            // Ambient
            writer.Write(cell.HasAmbient);
            if (cell.HasAmbient)
            {
                WriteColor(writer, cell.AmbientColor);
                WriteColor(writer, cell.SunlightColor);
                WriteColor(writer, cell.FogColor);
                writer.Write(cell.FogDensity);
            }

            // Water
            writer.Write(cell.HasWaterHeight);
            if (cell.HasWaterHeight)
                writer.Write(cell.WaterHeight);

            writer.Write(cell.MapColor);

            // References
            writer.Write(cell.References.Count);
            foreach (var refObj in cell.References)
            {
                WriteCellReference(writer, refObj);
            }
        }
    }

    private static void WriteCellReference(BinaryWriter writer, NativeCellReference cellRef)
    {
        writer.Write(cellRef.RefNum);
        WriteString(writer, cellRef.RefId);
        WriteVector3(writer, cellRef.Position);
        WriteVector3(writer, cellRef.Rotation);
        writer.Write(cellRef.Scale);
        writer.Write(cellRef.IsDeleted);
        writer.Write(cellRef.IsTeleport);
        if (cellRef.IsTeleport)
        {
            WriteVector3(writer, cellRef.TeleportPos);
            WriteVector3(writer, cellRef.TeleportRot);
            WriteString(writer, cellRef.TeleportCell);
        }
    }

    private static void WriteLands(BinaryWriter writer, Godot.Collections.Dictionary<string, NativeLandRecord> lands)
    {
        foreach (var kvp in lands)
        {
            var land = kvp.Value;

            WriteString(writer, kvp.Key);
            writer.Write(land.CellX);
            writer.Write(land.CellY);

            // Heights (65x65 floats = 4225 * 4 = 16900 bytes)
            writer.Write(land.Heights.Length);
            foreach (float h in land.Heights)
                writer.Write(h);

            // Normals (65x65x3 bytes = 12675 bytes)
            writer.Write(land.Normals.Length);
            foreach (byte n in land.Normals)
                writer.Write(n);

            // Vertex colors (65x65x3 bytes)
            writer.Write(land.VertexColors.Length);
            foreach (byte c in land.VertexColors)
                writer.Write(c);

            // Texture indices (16x16 ints)
            writer.Write(land.TextureIndices.Length);
            foreach (int t in land.TextureIndices)
                writer.Write(t);
        }
    }

    private static void WriteLandTextures(BinaryWriter writer, Godot.Collections.Dictionary<string, NativeLandTextureRecord> textures)
    {
        foreach (var kvp in textures)
        {
            WriteString(writer, kvp.Key);
            WriteString(writer, kvp.Value.RecordId);
            writer.Write(kvp.Value.Index);
            WriteString(writer, kvp.Value.Texture);
        }
    }

    private static void WriteVector3(BinaryWriter writer, Vector3 v)
    {
        writer.Write(v.X);
        writer.Write(v.Y);
        writer.Write(v.Z);
    }

    private static void WriteColor(BinaryWriter writer, Color c)
    {
        writer.Write(c.R);
        writer.Write(c.G);
        writer.Write(c.B);
        writer.Write(c.A);
    }

    // =========================================================================
    // READ HELPERS
    // =========================================================================

    private static string ReadString(BinaryReader reader)
    {
        ushort len = reader.ReadUInt16();
        if (len == 0) return "";
        return Encoding.UTF8.GetString(reader.ReadBytes(len));
    }

    private static void ReadStatics(BinaryReader reader, Godot.Collections.Dictionary<string, NativeStaticRecord> dict, int count)
    {
        for (int i = 0; i < count; i++)
        {
            string key = ReadString(reader);
            var rec = new NativeStaticRecord
            {
                RecordId = ReadString(reader),
                Model = ReadString(reader),
                IsDeleted = reader.ReadBoolean()
            };
            dict[key] = rec;
        }
    }

    private static void ReadDoors(BinaryReader reader, Godot.Collections.Dictionary<string, NativeDoorRecord> dict, int count)
    {
        for (int i = 0; i < count; i++)
        {
            string key = ReadString(reader);
            var rec = new NativeDoorRecord
            {
                RecordId = ReadString(reader),
                Model = ReadString(reader),
                IsDeleted = reader.ReadBoolean()
            };
            dict[key] = rec;
        }
    }

    private static void ReadActivators(BinaryReader reader, Godot.Collections.Dictionary<string, NativeActivatorRecord> dict, int count)
    {
        for (int i = 0; i < count; i++)
        {
            string key = ReadString(reader);
            var rec = new NativeActivatorRecord
            {
                RecordId = ReadString(reader),
                Model = ReadString(reader),
                IsDeleted = reader.ReadBoolean()
            };
            dict[key] = rec;
        }
    }

    private static void ReadContainers(BinaryReader reader, Godot.Collections.Dictionary<string, NativeContainerRecord> dict, int count)
    {
        for (int i = 0; i < count; i++)
        {
            string key = ReadString(reader);
            var rec = new NativeContainerRecord
            {
                RecordId = ReadString(reader),
                Model = ReadString(reader),
                IsDeleted = reader.ReadBoolean()
            };
            dict[key] = rec;
        }
    }

    private static void ReadLights(BinaryReader reader, Godot.Collections.Dictionary<string, NativeLightRecord> dict, int count)
    {
        for (int i = 0; i < count; i++)
        {
            string key = ReadString(reader);
            var rec = new NativeLightRecord
            {
                RecordId = ReadString(reader),
                Model = ReadString(reader),
                IsDeleted = reader.ReadBoolean()
            };
            dict[key] = rec;
        }
    }

    private static void ReadCells(BinaryReader reader,
        Godot.Collections.Dictionary<string, NativeCellRecord> cells,
        Godot.Collections.Dictionary<string, NativeCellRecord> exteriorCells,
        int count)
    {
        for (int i = 0; i < count; i++)
        {
            string key = ReadString(reader);
            var cell = new NativeCellRecord
            {
                RecordId = ReadString(reader),
                Name = ReadString(reader),
                RegionId = ReadString(reader),
                Flags = reader.ReadInt32(),
                GridX = reader.ReadInt32(),
                GridY = reader.ReadInt32()
            };

            // Ambient
            cell.HasAmbient = reader.ReadBoolean();
            if (cell.HasAmbient)
            {
                cell.AmbientColor = ReadColor(reader);
                cell.SunlightColor = ReadColor(reader);
                cell.FogColor = ReadColor(reader);
                cell.FogDensity = reader.ReadSingle();
            }

            // Water
            cell.HasWaterHeight = reader.ReadBoolean();
            if (cell.HasWaterHeight)
                cell.WaterHeight = reader.ReadSingle();

            cell.MapColor = reader.ReadInt32();

            // References
            int refCount = reader.ReadInt32();
            for (int r = 0; r < refCount; r++)
            {
                cell.References.Add(ReadCellReference(reader));
            }
            cell.ReferencesLoaded = true;

            cells[key] = cell;
            if (cell.IsExterior)
                exteriorCells[key] = cell;
        }
    }

    private static NativeCellReference ReadCellReference(BinaryReader reader)
    {
        var cellRef = new NativeCellReference
        {
            RefNum = reader.ReadInt32(),
            RefId = ReadString(reader),
            Position = ReadVector3(reader),
            Rotation = ReadVector3(reader),
            Scale = reader.ReadSingle(),
            IsDeleted = reader.ReadBoolean(),
            IsTeleport = reader.ReadBoolean()
        };

        if (cellRef.IsTeleport)
        {
            cellRef.TeleportPos = ReadVector3(reader);
            cellRef.TeleportRot = ReadVector3(reader);
            cellRef.TeleportCell = ReadString(reader);
        }

        return cellRef;
    }

    private static void ReadLands(BinaryReader reader, Godot.Collections.Dictionary<string, NativeLandRecord> dict, int count)
    {
        for (int i = 0; i < count; i++)
        {
            string key = ReadString(reader);
            var land = new NativeLandRecord
            {
                CellX = reader.ReadInt32(),
                CellY = reader.ReadInt32()
            };
            land.RecordId = key;

            // Heights
            int heightCount = reader.ReadInt32();
            var heights = new float[heightCount];
            for (int h = 0; h < heightCount; h++)
                heights[h] = reader.ReadSingle();
            land.Heights = heights;

            // Normals
            int normalCount = reader.ReadInt32();
            var normals = new byte[normalCount];
            for (int n = 0; n < normalCount; n++)
                normals[n] = reader.ReadByte();
            land.Normals = normals;

            // Vertex colors
            int colorCount = reader.ReadInt32();
            var colors = new byte[colorCount];
            for (int c = 0; c < colorCount; c++)
                colors[c] = reader.ReadByte();
            land.VertexColors = colors;

            // Texture indices
            int texCount = reader.ReadInt32();
            var textures = new int[texCount];
            for (int t = 0; t < texCount; t++)
                textures[t] = reader.ReadInt32();
            land.TextureIndices = textures;

            dict[key] = land;
        }
    }

    private static void ReadLandTextures(BinaryReader reader, Godot.Collections.Dictionary<string, NativeLandTextureRecord> dict, int count)
    {
        for (int i = 0; i < count; i++)
        {
            string key = ReadString(reader);
            var tex = new NativeLandTextureRecord
            {
                RecordId = ReadString(reader),
                Index = reader.ReadInt32(),
                Texture = ReadString(reader)
            };
            dict[key] = tex;
        }
    }

    private static Vector3 ReadVector3(BinaryReader reader)
    {
        return new Vector3(reader.ReadSingle(), reader.ReadSingle(), reader.ReadSingle());
    }

    private static Color ReadColor(BinaryReader reader)
    {
        return new Color(reader.ReadSingle(), reader.ReadSingle(), reader.ReadSingle(), reader.ReadSingle());
    }

    // =========================================================================
    // UTILITY
    // =========================================================================

    private static byte[]? ComputeFileHash(string path)
    {
        try
        {
            using var stream = File.OpenRead(path);
            using var md5 = MD5.Create();
            return md5.ComputeHash(stream);
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// Get the default cache path for an ESM file.
    /// </summary>
    public static string GetDefaultCachePath(string esmPath)
    {
        var documentsPath = System.Environment.GetFolderPath(System.Environment.SpecialFolder.MyDocuments);
        var fileName = Path.GetFileNameWithoutExtension(esmPath) + ".esmcache";
        return Path.Combine(documentsPath, "Godotwind", "cache", fileName);
    }
}
