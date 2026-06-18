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
    private const int CACHE_VERSION = 4;  // Bumped for native startup supplement records

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
            // New actor/item counts (v2)
            writer.Write(loader.NPCs.Count);
            writer.Write(loader.Creatures.Count);
            writer.Write(loader.Races.Count);
            writer.Write(loader.BodyParts.Count);
            writer.Write(loader.Weapons.Count);
            writer.Write(loader.Armors.Count);
            writer.Write(loader.Clothing.Count);
            writer.Write(loader.Books.Count);
            writer.Write(loader.Classes.Count);
            writer.Write(loader.Factions.Count);
            writer.Write(loader.Skills.Count);
            writer.Write(loader.Birthsigns.Count);
            writer.Write(loader.Dialogues.Count);
            writer.Write(loader.DialogueInfos.Count);
            writer.Write(loader.LeveledCreatures.Count);

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

            // Write actor/item records (v2)
            WriteNPCs(writer, loader.NPCs);
            WriteCreatures(writer, loader.Creatures);
            WriteRaces(writer, loader.Races);
            WriteBodyParts(writer, loader.BodyParts);
            WriteWeapons(writer, loader.Weapons);
            WriteArmors(writer, loader.Armors);
            WriteClothing(writer, loader.Clothing);
            WriteBooks(writer, loader.Books);
            WriteClasses(writer, loader.Classes);
            WriteFactions(writer, loader.Factions);
            WriteSkills(writer, loader.Skills);
            WriteBirthsigns(writer, loader.Birthsigns);
            WriteDialogues(writer, loader.Dialogues);
            WriteDialogueInfos(writer, loader.DialogueInfos);
            WriteLeveledCreatures(writer, loader.LeveledCreatures);

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
            // New actor/item counts (v2)
            int npcsCount = reader.ReadInt32();
            int creaturesCount = reader.ReadInt32();
            int racesCount = reader.ReadInt32();
            int bodyPartsCount = reader.ReadInt32();
            int weaponsCount = reader.ReadInt32();
            int armorsCount = reader.ReadInt32();
            int clothingCount = reader.ReadInt32();
            int booksCount = reader.ReadInt32();
            int classesCount = reader.ReadInt32();
            int factionsCount = reader.ReadInt32();
            int skillsCount = reader.ReadInt32();
            int birthsignsCount = reader.ReadInt32();
            int dialoguesCount = reader.ReadInt32();
            int dialogueInfoTopicsCount = reader.ReadInt32();
            int leveledCreaturesCount = reader.ReadInt32();

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

            // Read actor/item records (v2)
            ReadNPCs(reader, loader.NPCs, npcsCount);
            ReadCreatures(reader, loader.Creatures, creaturesCount);
            ReadRaces(reader, loader.Races, racesCount);
            ReadBodyParts(reader, loader.BodyParts, bodyPartsCount);
            ReadWeapons(reader, loader.Weapons, weaponsCount);
            ReadArmors(reader, loader.Armors, armorsCount);
            ReadClothing(reader, loader.Clothing, clothingCount);
            ReadBooks(reader, loader.Books, booksCount);
            ReadClasses(reader, loader.Classes, classesCount);
            ReadFactions(reader, loader.Factions, factionsCount);
            ReadSkills(reader, loader.Skills, skillsCount);
            ReadBirthsigns(reader, loader.Birthsigns, birthsignsCount);
            ReadDialogues(reader, loader.Dialogues, dialoguesCount);
            ReadDialogueInfos(reader, loader.DialogueInfos, dialogueInfoTopicsCount);
            ReadLeveledCreatures(reader, loader.LeveledCreatures, leveledCreaturesCount);

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
            // LHDT data
            WriteString(writer, kvp.Value.Name);
            WriteString(writer, kvp.Value.ScriptId);
            WriteString(writer, kvp.Value.Icon);
            WriteString(writer, kvp.Value.Sound);
            writer.Write(kvp.Value.Weight);
            writer.Write(kvp.Value.Value);
            writer.Write(kvp.Value.Time);
            writer.Write(kvp.Value.Radius);
            WriteColor(writer, kvp.Value.LightColor);
            writer.Write(kvp.Value.Flags);
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

    private static void WriteNPCs(BinaryWriter writer, Godot.Collections.Dictionary<string, NativeNPCRecord> records)
    {
        foreach (var kvp in records)
        {
            var r = kvp.Value;
            WriteString(writer, kvp.Key);
            WriteString(writer, r.RecordId);
            WriteString(writer, r.Model);
            writer.Write(r.IsDeleted);
            WriteString(writer, r.Name);
            WriteString(writer, r.ScriptId);
            WriteString(writer, r.RaceId);
            WriteString(writer, r.ClassId);
            WriteString(writer, r.FactionId);
            WriteString(writer, r.HeadId);
            WriteString(writer, r.HairId);
            writer.Write(r.NpcFlags);
            writer.Write(r.Level);
            writer.Write(r.Health);
            writer.Write(r.Mana);
            writer.Write(r.Fatigue);
            writer.Write(r.Disposition);
            writer.Write(r.Reputation);
            writer.Write(r.Rank);
            writer.Write(r.Gold);
        }
    }

    private static void WriteCreatures(BinaryWriter writer, Godot.Collections.Dictionary<string, NativeCreatureRecord> records)
    {
        foreach (var kvp in records)
        {
            var r = kvp.Value;
            WriteString(writer, kvp.Key);
            WriteString(writer, r.RecordId);
            WriteString(writer, r.Model);
            writer.Write(r.IsDeleted);
            WriteString(writer, r.Name);
            WriteString(writer, r.ScriptId);
            WriteString(writer, r.OriginalId);
            writer.Write(r.CreatureFlags);
            writer.Write(r.Scale);
            writer.Write(r.CreatureType);
            writer.Write(r.Level);
            writer.Write(r.Health);
            writer.Write(r.Mana);
            writer.Write(r.Fatigue);
            writer.Write(r.Soul);
            writer.Write(r.Combat);
            writer.Write(r.Magic);
            writer.Write(r.Stealth);
            writer.Write(r.Gold);
            // Attack values
            for (int i = 0; i < 3; i++)
            {
                writer.Write(r.AttackMin[i]);
                writer.Write(r.AttackMax[i]);
            }
        }
    }

    private static void WriteRaces(BinaryWriter writer, Godot.Collections.Dictionary<string, NativeRaceRecord> records)
    {
        foreach (var kvp in records)
        {
            var r = kvp.Value;
            WriteString(writer, kvp.Key);
            WriteString(writer, r.RecordId);
            writer.Write(r.IsDeleted);
            WriteString(writer, r.Name);
            WriteString(writer, r.Description);
            writer.Write(r.MaleHeight);
            writer.Write(r.FemaleHeight);
            writer.Write(r.MaleWeight);
            writer.Write(r.FemaleWeight);
            writer.Write(r.Flags);
        }
    }

    private static void WriteBodyParts(BinaryWriter writer, Godot.Collections.Dictionary<string, NativeBodyPartRecord> records)
    {
        foreach (var kvp in records)
        {
            var r = kvp.Value;
            WriteString(writer, kvp.Key);
            WriteString(writer, r.RecordId);
            WriteString(writer, r.Model);
            writer.Write(r.IsDeleted);
            writer.Write(r.PartType);
            writer.Write(r.IsVampire);
            writer.Write(r.Flags);
            writer.Write(r.MeshType);
        }
    }

    private static void WriteWeapons(BinaryWriter writer, Godot.Collections.Dictionary<string, NativeWeaponRecord> records)
    {
        foreach (var kvp in records)
        {
            var r = kvp.Value;
            WriteString(writer, kvp.Key);
            WriteString(writer, r.RecordId);
            WriteString(writer, r.Model);
            writer.Write(r.IsDeleted);
            WriteString(writer, r.Name);
            WriteString(writer, r.ScriptId);
            WriteString(writer, r.Icon);
            WriteString(writer, r.EnchantId);
            writer.Write(r.Weight);
            writer.Write(r.Value);
            writer.Write(r.WeaponType);
            writer.Write(r.Health);
            writer.Write(r.Speed);
            writer.Write(r.Reach);
            writer.Write(r.EnchantPoints);
            writer.Write(r.ChopMin);
            writer.Write(r.ChopMax);
            writer.Write(r.SlashMin);
            writer.Write(r.SlashMax);
            writer.Write(r.ThrustMin);
            writer.Write(r.ThrustMax);
            writer.Write(r.Flags);
        }
    }

    private static void WriteArmors(BinaryWriter writer, Godot.Collections.Dictionary<string, NativeArmorRecord> records)
    {
        foreach (var kvp in records)
        {
            var r = kvp.Value;
            WriteString(writer, kvp.Key);
            WriteString(writer, r.RecordId);
            WriteString(writer, r.Model);
            writer.Write(r.IsDeleted);
            WriteString(writer, r.Name);
            WriteString(writer, r.ScriptId);
            WriteString(writer, r.Icon);
            WriteString(writer, r.EnchantId);
            writer.Write(r.ArmorType);
            writer.Write(r.Weight);
            writer.Write(r.Value);
            writer.Write(r.Health);
            writer.Write(r.EnchantPoints);
            writer.Write(r.ArmorRating);
        }
    }

    private static void WriteClothing(BinaryWriter writer, Godot.Collections.Dictionary<string, NativeClothingRecord> records)
    {
        foreach (var kvp in records)
        {
            var r = kvp.Value;
            WriteString(writer, kvp.Key);
            WriteString(writer, r.RecordId);
            WriteString(writer, r.Model);
            writer.Write(r.IsDeleted);
            WriteString(writer, r.Name);
            WriteString(writer, r.ScriptId);
            WriteString(writer, r.Icon);
            WriteString(writer, r.EnchantId);
            writer.Write(r.ClothingType);
            writer.Write(r.Weight);
            writer.Write(r.Value);
            writer.Write(r.EnchantPoints);
        }
    }

    private static void WriteBooks(BinaryWriter writer, Godot.Collections.Dictionary<string, NativeBookRecord> records)
    {
        foreach (var kvp in records)
        {
            var r = kvp.Value;
            WriteString(writer, kvp.Key);
            WriteString(writer, r.RecordId);
            WriteString(writer, r.Model);
            writer.Write(r.IsDeleted);
            WriteString(writer, r.Name);
            WriteString(writer, r.Icon);
            WriteString(writer, r.ScriptId);
            WriteString(writer, r.EnchantId);
            WriteString(writer, r.Text);
            writer.Write(r.Weight);
            writer.Write(r.Value);
            writer.Write(r.IsScroll);
            writer.Write(r.SkillId);
            writer.Write(r.EnchantPoints);
        }
    }

    private static void WriteClasses(BinaryWriter writer, Godot.Collections.Dictionary<string, NativeClassRecord> records)
    {
        foreach (var kvp in records)
        {
            var r = kvp.Value;
            WriteString(writer, kvp.Key);
            WriteString(writer, r.RecordId);
            writer.Write(r.IsDeleted);
            WriteString(writer, r.Name);
            WriteString(writer, r.Description);
            WriteIntArray(writer, r.PrimaryAttributes);
            writer.Write(r.Specialization);
            WriteIntArray(writer, r.MajorSkills);
            WriteIntArray(writer, r.MinorSkills);
            writer.Write(r.IsPlayable);
            writer.Write(r.Services);
        }
    }

    private static void WriteFactions(BinaryWriter writer, Godot.Collections.Dictionary<string, NativeFactionRecord> records)
    {
        foreach (var kvp in records)
        {
            var r = kvp.Value;
            WriteString(writer, kvp.Key);
            WriteString(writer, r.RecordId);
            writer.Write(r.IsDeleted);
            WriteString(writer, r.Name);
            WriteStringArray(writer, r.RankNames);
            WriteIntArray(writer, r.FavoriteAttributes);
            WriteDictionaryArray(writer, r.RankData);
            WriteIntArray(writer, r.FavoriteSkills);
            writer.Write(r.IsHidden);
            writer.Write(r.Reactions.Count);
            foreach (var reaction in r.Reactions)
            {
                WriteString(writer, reaction.Key);
                writer.Write(reaction.Value);
            }
        }
    }

    private static void WriteSkills(BinaryWriter writer, Godot.Collections.Dictionary<string, NativeSkillRecord> records)
    {
        foreach (var kvp in records)
        {
            var r = kvp.Value;
            WriteString(writer, kvp.Key);
            WriteString(writer, r.RecordId);
            writer.Write(r.IsDeleted);
            WriteString(writer, r.Description);
            writer.Write(r.Attribute);
            writer.Write(r.Specialization);
            WriteFloatArray(writer, r.UseValues);
        }
    }

    private static void WriteBirthsigns(BinaryWriter writer, Godot.Collections.Dictionary<string, NativeBirthsignRecord> records)
    {
        foreach (var kvp in records)
        {
            var r = kvp.Value;
            WriteString(writer, kvp.Key);
            WriteString(writer, r.RecordId);
            writer.Write(r.IsDeleted);
            WriteString(writer, r.Name);
            WriteString(writer, r.Description);
            WriteString(writer, r.Texture);
            WriteStringArray(writer, r.Powers);
        }
    }

    private static void WriteDialogues(BinaryWriter writer, Godot.Collections.Dictionary<string, NativeDialogueRecord> records)
    {
        foreach (var kvp in records)
        {
            var r = kvp.Value;
            WriteString(writer, kvp.Key);
            WriteString(writer, r.RecordId);
            writer.Write(r.IsDeleted);
            writer.Write(r.DialogueType);
        }
    }

    private static void WriteDialogueInfos(BinaryWriter writer, Godot.Collections.Dictionary<string, Godot.Collections.Array<NativeDialogueInfoRecord>> topics)
    {
        foreach (var kvp in topics)
        {
            WriteString(writer, kvp.Key);
            writer.Write(kvp.Value.Count);
            foreach (var r in kvp.Value)
            {
                WriteString(writer, r.RecordId);
                writer.Write(r.IsDeleted);
                WriteString(writer, r.ParentTopic);
                WriteString(writer, r.PrevId);
                WriteString(writer, r.NextId);
                writer.Write(r.Disposition);
                writer.Write(r.SpeakerRank);
                writer.Write(r.SpeakerSex);
                writer.Write(r.PlayerRank);
                WriteString(writer, r.ActorId);
                WriteString(writer, r.ActorRace);
                WriteString(writer, r.ActorClass);
                WriteString(writer, r.ActorFaction);
                WriteString(writer, r.ActorCell);
                WriteString(writer, r.PcFaction);
                WriteString(writer, r.SoundFile);
                WriteString(writer, r.Response);
                WriteString(writer, r.ResultScript);
                writer.Write(r.QuestName);
                writer.Write(r.QuestFinish);
                writer.Write(r.QuestRestart);
                WriteDictionaryArray(writer, r.Conditions);
            }
        }
    }

    private static void WriteLeveledCreatures(BinaryWriter writer, Godot.Collections.Dictionary<string, NativeLeveledCreatureRecord> records)
    {
        foreach (var kvp in records)
        {
            var r = kvp.Value;
            WriteString(writer, kvp.Key);
            WriteString(writer, r.RecordId);
            writer.Write(r.IsDeleted);
            writer.Write(r.Flags);
            writer.Write(r.ChanceNone);
            WriteDictionaryArray(writer, r.Creatures);
        }
    }

    private static void WriteIntArray(BinaryWriter writer, int[] values)
    {
        writer.Write(values.Length);
        foreach (int value in values)
            writer.Write(value);
    }

    private static void WriteFloatArray(BinaryWriter writer, float[] values)
    {
        writer.Write(values.Length);
        foreach (float value in values)
            writer.Write(value);
    }

    private static void WriteStringArray(BinaryWriter writer, Godot.Collections.Array<string> values)
    {
        writer.Write(values.Count);
        foreach (string value in values)
            WriteString(writer, value);
    }

    private static void WriteDictionaryArray(BinaryWriter writer, Godot.Collections.Array<Godot.Collections.Dictionary> values)
    {
        writer.Write(values.Count);
        foreach (var dict in values)
        {
            writer.Write(dict.Count);
            foreach (var keyVariant in dict.Keys)
            {
                string key = keyVariant.AsString();
                WriteString(writer, key);
                var value = dict[key];
                if (value.VariantType == Variant.Type.Float)
                {
                    writer.Write((byte)Variant.Type.Float);
                    writer.Write(value.AsSingle());
                }
                else if (value.VariantType == Variant.Type.String || value.VariantType == Variant.Type.StringName)
                {
                    writer.Write((byte)Variant.Type.String);
                    WriteString(writer, value.AsString());
                }
                else
                {
                    writer.Write((byte)Variant.Type.Int);
                    writer.Write(value.AsInt32());
                }
            }
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
                IsDeleted = reader.ReadBoolean(),
                // LHDT data
                Name = ReadString(reader),
                ScriptId = ReadString(reader),
                Icon = ReadString(reader),
                Sound = ReadString(reader),
                Weight = reader.ReadSingle(),
                Value = reader.ReadInt32(),
                Time = reader.ReadInt32(),
                Radius = reader.ReadInt32(),
                LightColor = ReadColor(reader),
                Flags = reader.ReadInt32()
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

    private static void ReadNPCs(BinaryReader reader, Godot.Collections.Dictionary<string, NativeNPCRecord> dict, int count)
    {
        for (int i = 0; i < count; i++)
        {
            string key = ReadString(reader);
            var rec = new NativeNPCRecord
            {
                RecordId = ReadString(reader),
                Model = ReadString(reader),
                IsDeleted = reader.ReadBoolean(),
                Name = ReadString(reader),
                ScriptId = ReadString(reader),
                RaceId = ReadString(reader),
                ClassId = ReadString(reader),
                FactionId = ReadString(reader),
                HeadId = ReadString(reader),
                HairId = ReadString(reader),
                NpcFlags = reader.ReadInt32(),
                Level = reader.ReadInt32(),
                Health = reader.ReadInt32(),
                Mana = reader.ReadInt32(),
                Fatigue = reader.ReadInt32(),
                Disposition = reader.ReadInt32(),
                Reputation = reader.ReadInt32(),
                Rank = reader.ReadInt32(),
                Gold = reader.ReadInt32()
            };
            dict[key] = rec;
        }
    }

    private static void ReadCreatures(BinaryReader reader, Godot.Collections.Dictionary<string, NativeCreatureRecord> dict, int count)
    {
        for (int i = 0; i < count; i++)
        {
            string key = ReadString(reader);
            var rec = new NativeCreatureRecord
            {
                RecordId = ReadString(reader),
                Model = ReadString(reader),
                IsDeleted = reader.ReadBoolean(),
                Name = ReadString(reader),
                ScriptId = ReadString(reader),
                OriginalId = ReadString(reader),
                CreatureFlags = reader.ReadInt32(),
                Scale = reader.ReadSingle(),
                CreatureType = reader.ReadInt32(),
                Level = reader.ReadInt32(),
                Health = reader.ReadInt32(),
                Mana = reader.ReadInt32(),
                Fatigue = reader.ReadInt32(),
                Soul = reader.ReadInt32(),
                Combat = reader.ReadInt32(),
                Magic = reader.ReadInt32(),
                Stealth = reader.ReadInt32(),
                Gold = reader.ReadInt32()
            };
            // Attack values
            for (int a = 0; a < 3; a++)
            {
                rec.AttackMin[a] = reader.ReadInt32();
                rec.AttackMax[a] = reader.ReadInt32();
            }
            dict[key] = rec;
        }
    }

    private static void ReadRaces(BinaryReader reader, Godot.Collections.Dictionary<string, NativeRaceRecord> dict, int count)
    {
        for (int i = 0; i < count; i++)
        {
            string key = ReadString(reader);
            var rec = new NativeRaceRecord
            {
                RecordId = ReadString(reader),
                IsDeleted = reader.ReadBoolean(),
                Name = ReadString(reader),
                Description = ReadString(reader),
                MaleHeight = reader.ReadSingle(),
                FemaleHeight = reader.ReadSingle(),
                MaleWeight = reader.ReadSingle(),
                FemaleWeight = reader.ReadSingle(),
                Flags = reader.ReadInt32()
            };
            dict[key] = rec;
        }
    }

    private static void ReadBodyParts(BinaryReader reader, Godot.Collections.Dictionary<string, NativeBodyPartRecord> dict, int count)
    {
        for (int i = 0; i < count; i++)
        {
            string key = ReadString(reader);
            var rec = new NativeBodyPartRecord
            {
                RecordId = ReadString(reader),
                Model = ReadString(reader),
                IsDeleted = reader.ReadBoolean(),
                PartType = reader.ReadInt32(),
                IsVampire = reader.ReadBoolean(),
                Flags = reader.ReadInt32(),
                MeshType = reader.ReadInt32()
            };
            dict[key] = rec;
        }
    }

    private static void ReadWeapons(BinaryReader reader, Godot.Collections.Dictionary<string, NativeWeaponRecord> dict, int count)
    {
        for (int i = 0; i < count; i++)
        {
            string key = ReadString(reader);
            var rec = new NativeWeaponRecord
            {
                RecordId = ReadString(reader),
                Model = ReadString(reader),
                IsDeleted = reader.ReadBoolean(),
                Name = ReadString(reader),
                ScriptId = ReadString(reader),
                Icon = ReadString(reader),
                EnchantId = ReadString(reader),
                Weight = reader.ReadSingle(),
                Value = reader.ReadInt32(),
                WeaponType = reader.ReadInt32(),
                Health = reader.ReadInt32(),
                Speed = reader.ReadSingle(),
                Reach = reader.ReadSingle(),
                EnchantPoints = reader.ReadInt32(),
                ChopMin = reader.ReadInt32(),
                ChopMax = reader.ReadInt32(),
                SlashMin = reader.ReadInt32(),
                SlashMax = reader.ReadInt32(),
                ThrustMin = reader.ReadInt32(),
                ThrustMax = reader.ReadInt32(),
                Flags = reader.ReadInt32()
            };
            dict[key] = rec;
        }
    }

    private static void ReadArmors(BinaryReader reader, Godot.Collections.Dictionary<string, NativeArmorRecord> dict, int count)
    {
        for (int i = 0; i < count; i++)
        {
            string key = ReadString(reader);
            var rec = new NativeArmorRecord
            {
                RecordId = ReadString(reader),
                Model = ReadString(reader),
                IsDeleted = reader.ReadBoolean(),
                Name = ReadString(reader),
                ScriptId = ReadString(reader),
                Icon = ReadString(reader),
                EnchantId = ReadString(reader),
                ArmorType = reader.ReadInt32(),
                Weight = reader.ReadSingle(),
                Value = reader.ReadInt32(),
                Health = reader.ReadInt32(),
                EnchantPoints = reader.ReadInt32(),
                ArmorRating = reader.ReadInt32()
            };
            dict[key] = rec;
        }
    }

    private static void ReadClothing(BinaryReader reader, Godot.Collections.Dictionary<string, NativeClothingRecord> dict, int count)
    {
        for (int i = 0; i < count; i++)
        {
            string key = ReadString(reader);
            var rec = new NativeClothingRecord
            {
                RecordId = ReadString(reader),
                Model = ReadString(reader),
                IsDeleted = reader.ReadBoolean(),
                Name = ReadString(reader),
                ScriptId = ReadString(reader),
                Icon = ReadString(reader),
                EnchantId = ReadString(reader),
                ClothingType = reader.ReadInt32(),
                Weight = reader.ReadSingle(),
                Value = reader.ReadInt32(),
                EnchantPoints = reader.ReadInt32()
            };
            dict[key] = rec;
        }
    }

    private static void ReadBooks(BinaryReader reader, Godot.Collections.Dictionary<string, NativeBookRecord> dict, int count)
    {
        for (int i = 0; i < count; i++)
        {
            string key = ReadString(reader);
            dict[key] = new NativeBookRecord
            {
                RecordId = ReadString(reader),
                Model = ReadString(reader),
                IsDeleted = reader.ReadBoolean(),
                Name = ReadString(reader),
                Icon = ReadString(reader),
                ScriptId = ReadString(reader),
                EnchantId = ReadString(reader),
                Text = ReadString(reader),
                Weight = reader.ReadSingle(),
                Value = reader.ReadInt32(),
                IsScroll = reader.ReadBoolean(),
                SkillId = reader.ReadInt32(),
                EnchantPoints = reader.ReadInt32()
            };
        }
    }

    private static void ReadClasses(BinaryReader reader, Godot.Collections.Dictionary<string, NativeClassRecord> dict, int count)
    {
        for (int i = 0; i < count; i++)
        {
            string key = ReadString(reader);
            dict[key] = new NativeClassRecord
            {
                RecordId = ReadString(reader),
                IsDeleted = reader.ReadBoolean(),
                Name = ReadString(reader),
                Description = ReadString(reader),
                PrimaryAttributes = ReadIntArray(reader),
                Specialization = reader.ReadInt32(),
                MajorSkills = ReadIntArray(reader),
                MinorSkills = ReadIntArray(reader),
                IsPlayable = reader.ReadBoolean(),
                Services = reader.ReadInt32()
            };
        }
    }

    private static void ReadFactions(BinaryReader reader, Godot.Collections.Dictionary<string, NativeFactionRecord> dict, int count)
    {
        for (int i = 0; i < count; i++)
        {
            string key = ReadString(reader);
            var rec = new NativeFactionRecord
            {
                RecordId = ReadString(reader),
                IsDeleted = reader.ReadBoolean(),
                Name = ReadString(reader),
                RankNames = ReadStringArray(reader),
                FavoriteAttributes = ReadIntArray(reader),
                RankData = ReadDictionaryArray(reader),
                FavoriteSkills = ReadIntArray(reader),
                IsHidden = reader.ReadBoolean()
            };
            int reactionCount = reader.ReadInt32();
            for (int r = 0; r < reactionCount; r++)
                rec.Reactions[ReadString(reader)] = reader.ReadInt32();
            dict[key] = rec;
        }
    }

    private static void ReadSkills(BinaryReader reader, Godot.Collections.Dictionary<string, NativeSkillRecord> dict, int count)
    {
        for (int i = 0; i < count; i++)
        {
            string key = ReadString(reader);
            dict[key] = new NativeSkillRecord
            {
                RecordId = ReadString(reader),
                IsDeleted = reader.ReadBoolean(),
                Description = ReadString(reader),
                Attribute = reader.ReadInt32(),
                Specialization = reader.ReadInt32(),
                UseValues = ReadFloatArray(reader)
            };
        }
    }

    private static void ReadBirthsigns(BinaryReader reader, Godot.Collections.Dictionary<string, NativeBirthsignRecord> dict, int count)
    {
        for (int i = 0; i < count; i++)
        {
            string key = ReadString(reader);
            dict[key] = new NativeBirthsignRecord
            {
                RecordId = ReadString(reader),
                IsDeleted = reader.ReadBoolean(),
                Name = ReadString(reader),
                Description = ReadString(reader),
                Texture = ReadString(reader),
                Powers = ReadStringArray(reader)
            };
        }
    }

    private static void ReadDialogues(BinaryReader reader, Godot.Collections.Dictionary<string, NativeDialogueRecord> dict, int count)
    {
        for (int i = 0; i < count; i++)
        {
            string key = ReadString(reader);
            dict[key] = new NativeDialogueRecord
            {
                RecordId = ReadString(reader),
                IsDeleted = reader.ReadBoolean(),
                DialogueType = reader.ReadInt32()
            };
        }
    }

    private static void ReadDialogueInfos(BinaryReader reader, Godot.Collections.Dictionary<string, Godot.Collections.Array<NativeDialogueInfoRecord>> dict, int topicCount)
    {
        for (int i = 0; i < topicCount; i++)
        {
            string topicKey = ReadString(reader);
            int infoCount = reader.ReadInt32();
            var infos = new Godot.Collections.Array<NativeDialogueInfoRecord>();
            for (int j = 0; j < infoCount; j++)
            {
                infos.Add(new NativeDialogueInfoRecord
                {
                    RecordId = ReadString(reader),
                    IsDeleted = reader.ReadBoolean(),
                    ParentTopic = ReadString(reader),
                    PrevId = ReadString(reader),
                    NextId = ReadString(reader),
                    Disposition = reader.ReadInt32(),
                    SpeakerRank = reader.ReadInt32(),
                    SpeakerSex = reader.ReadInt32(),
                    PlayerRank = reader.ReadInt32(),
                    ActorId = ReadString(reader),
                    ActorRace = ReadString(reader),
                    ActorClass = ReadString(reader),
                    ActorFaction = ReadString(reader),
                    ActorCell = ReadString(reader),
                    PcFaction = ReadString(reader),
                    SoundFile = ReadString(reader),
                    Response = ReadString(reader),
                    ResultScript = ReadString(reader),
                    QuestName = reader.ReadBoolean(),
                    QuestFinish = reader.ReadBoolean(),
                    QuestRestart = reader.ReadBoolean(),
                    Conditions = ReadDictionaryArray(reader)
                });
            }
            dict[topicKey] = infos;
        }
    }

    private static void ReadLeveledCreatures(BinaryReader reader, Godot.Collections.Dictionary<string, NativeLeveledCreatureRecord> dict, int count)
    {
        for (int i = 0; i < count; i++)
        {
            string key = ReadString(reader);
            dict[key] = new NativeLeveledCreatureRecord
            {
                RecordId = ReadString(reader),
                IsDeleted = reader.ReadBoolean(),
                Flags = reader.ReadInt32(),
                ChanceNone = reader.ReadInt32(),
                Creatures = ReadDictionaryArray(reader)
            };
        }
    }

    private static int[] ReadIntArray(BinaryReader reader)
    {
        int count = reader.ReadInt32();
        var values = new int[count];
        for (int i = 0; i < count; i++)
            values[i] = reader.ReadInt32();
        return values;
    }

    private static float[] ReadFloatArray(BinaryReader reader)
    {
        int count = reader.ReadInt32();
        var values = new float[count];
        for (int i = 0; i < count; i++)
            values[i] = reader.ReadSingle();
        return values;
    }

    private static Godot.Collections.Array<string> ReadStringArray(BinaryReader reader)
    {
        int count = reader.ReadInt32();
        var values = new Godot.Collections.Array<string>();
        for (int i = 0; i < count; i++)
            values.Add(ReadString(reader));
        return values;
    }

    private static Godot.Collections.Array<Godot.Collections.Dictionary> ReadDictionaryArray(BinaryReader reader)
    {
        int count = reader.ReadInt32();
        var values = new Godot.Collections.Array<Godot.Collections.Dictionary>();
        for (int i = 0; i < count; i++)
        {
            int entryCount = reader.ReadInt32();
            var dict = new Godot.Collections.Dictionary();
            for (int e = 0; e < entryCount; e++)
            {
                string key = ReadString(reader);
                var type = (Variant.Type)reader.ReadByte();
                dict[key] = type switch
                {
                    Variant.Type.Float => reader.ReadSingle(),
                    Variant.Type.String => ReadString(reader),
                    _ => reader.ReadInt32()
                };
            }
            values.Add(dict);
        }
        return values;
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
