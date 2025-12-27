using Godot;
using System;
using System.Collections.Generic;

namespace Godotwind.Native;

/// <summary>
/// Native ESM record types for high-performance loading.
/// These minimal record classes contain only the data needed for rendering.
/// </summary>

// =============================================================================
// BASE RECORD (with model path)
// =============================================================================

/// <summary>
/// Base class for records that have a model path.
/// </summary>
[GlobalClass]
public partial class NativeModelRecord : RefCounted
{
    public string RecordId { get; set; } = "";
    public string Model { get; set; } = "";
    public bool IsDeleted { get; set; } = false;
}

// =============================================================================
// STATIC RECORD (STAT)
// =============================================================================

/// <summary>
/// Static object record - just an ID and model path.
/// </summary>
[GlobalClass]
public partial class NativeStaticRecord : NativeModelRecord
{
    public override string ToString() => $"Static('{RecordId}', model='{Model}')";
}

// =============================================================================
// DOOR RECORD (DOOR)
// =============================================================================

/// <summary>
/// Door record - model path plus sounds.
/// </summary>
[GlobalClass]
public partial class NativeDoorRecord : NativeModelRecord
{
    public string Name { get; set; } = "";
    public string ScriptId { get; set; } = "";
    public string OpenSound { get; set; } = "";
    public string CloseSound { get; set; } = "";

    public override string ToString() => $"Door('{RecordId}', '{Name}')";
}

// =============================================================================
// ACTIVATOR RECORD (ACTI)
// =============================================================================

/// <summary>
/// Activator record - interactive objects with scripts.
/// </summary>
[GlobalClass]
public partial class NativeActivatorRecord : NativeModelRecord
{
    public string Name { get; set; } = "";
    public string ScriptId { get; set; } = "";

    public override string ToString() => $"Activator('{RecordId}', '{Name}')";
}

// =============================================================================
// CONTAINER RECORD (CONT)
// =============================================================================

/// <summary>
/// Container record - holds items.
/// </summary>
[GlobalClass]
public partial class NativeContainerRecord : NativeModelRecord
{
    public string Name { get; set; } = "";
    public string ScriptId { get; set; } = "";
    public float Weight { get; set; } = 0f;
    public int Flags { get; set; } = 0;

    // Container flags
    public const int FLAG_ORGANIC = 0x0001;
    public const int FLAG_RESPAWNS = 0x0002;

    public bool IsOrganic => (Flags & FLAG_ORGANIC) != 0;
    public bool Respawns => (Flags & FLAG_RESPAWNS) != 0;

    public override string ToString() => $"Container('{RecordId}', '{Name}')";
}

// =============================================================================
// LIGHT RECORD (LIGH)
// =============================================================================

/// <summary>
/// Light record - light sources.
/// </summary>
[GlobalClass]
public partial class NativeLightRecord : NativeModelRecord
{
    public string Name { get; set; } = "";
    public string ScriptId { get; set; } = "";
    public string Icon { get; set; } = "";
    public string Sound { get; set; } = "";

    // LHDT data
    public float Weight { get; set; } = 0f;
    public int Value { get; set; } = 0;
    public int Time { get; set; } = 0;  // Duration in seconds (0 = permanent)
    public int Radius { get; set; } = 0;
    public Color LightColor { get; set; } = Colors.White;
    public int Flags { get; set; } = 0;

    // Light flags
    public const int FLAG_DYNAMIC = 0x0001;
    public const int FLAG_CAN_CARRY = 0x0002;
    public const int FLAG_NEGATIVE = 0x0004;
    public const int FLAG_FLICKER = 0x0008;
    public const int FLAG_FIRE = 0x0010;
    public const int FLAG_OFF_BY_DEFAULT = 0x0020;
    public const int FLAG_FLICKER_SLOW = 0x0040;
    public const int FLAG_PULSE = 0x0080;
    public const int FLAG_PULSE_SLOW = 0x0100;

    public bool IsDynamic => (Flags & FLAG_DYNAMIC) != 0;
    public bool CanCarry => (Flags & FLAG_CAN_CARRY) != 0;
    public bool IsNegative => (Flags & FLAG_NEGATIVE) != 0;

    public override string ToString() => $"Light('{RecordId}', radius={Radius})";
}

// =============================================================================
// CELL REFERENCE
// =============================================================================

/// <summary>
/// Cell reference - an object instance placed in a cell.
/// Contains only the data needed for rendering.
/// </summary>
[GlobalClass]
public partial class NativeCellReference : RefCounted
{
    // Core identity
    public int RefNum { get; set; } = 0;
    public string RefId { get; set; } = "";  // Base object ID (e.g., "barrel_01")
    public bool IsDeleted { get; set; } = false;

    // Transform (required for visualization)
    public Vector3 Position { get; set; } = Vector3.Zero;
    public Vector3 Rotation { get; set; } = Vector3.Zero;  // Euler angles in radians
    public float Scale { get; set; } = 1.0f;

    // Door teleport data (only for doors)
    public Vector3 TeleportPos { get; set; } = Vector3.Zero;
    public Vector3 TeleportRot { get; set; } = Vector3.Zero;
    public string TeleportCell { get; set; } = "";
    public bool IsTeleport { get; set; } = false;

    public override string ToString() =>
        $"CellRef({RefNum}, '{RefId}', pos={Position}, scale={Scale:F2})";
}

// =============================================================================
// CELL RECORD
// =============================================================================

/// <summary>
/// Cell record - contains location data and object references.
/// </summary>
[GlobalClass]
public partial class NativeCellRecord : RefCounted
{
    // Cell flags
    public const int CELL_INTERIOR = 0x01;
    public const int CELL_HAS_WATER = 0x02;
    public const int CELL_NO_SLEEP = 0x04;
    public const int CELL_QUASI_EXTERIOR = 0x80;

    // Cell data
    public string RecordId { get; set; } = "";
    public string Name { get; set; } = "";
    public string RegionId { get; set; } = "";
    public int Flags { get; set; } = 0;
    public int GridX { get; set; } = 0;
    public int GridY { get; set; } = 0;

    // Ambient lighting
    public Color AmbientColor { get; set; } = Colors.White;
    public Color SunlightColor { get; set; } = Colors.White;
    public Color FogColor { get; set; } = Colors.White;
    public float FogDensity { get; set; } = 0f;
    public bool HasAmbient { get; set; } = false;

    // Water
    public float WaterHeight { get; set; } = 0f;
    public bool HasWaterHeight { get; set; } = false;

    // Map color
    public int MapColor { get; set; } = 0;

    // References - objects placed in this cell
    // Using Godot.Collections.Array for GDScript interop
    public Godot.Collections.Array<NativeCellReference> References { get; } = new();

    // Lazy loading support
    public bool ReferencesLoaded { get; set; } = false;
    public long ReferenceFileOffset { get; set; } = -1;

    // Helper properties
    public bool IsInterior => (Flags & CELL_INTERIOR) != 0;
    public bool IsExterior => !IsInterior;
    public bool HasWater => ((Flags & CELL_HAS_WATER) != 0) || IsExterior;
    public bool CanSleep => (Flags & CELL_NO_SLEEP) == 0;
    public bool IsQuasiExterior => (Flags & CELL_QUASI_EXTERIOR) != 0;

    /// <summary>
    /// Get the cell key for dictionary indexing.
    /// Interior cells use name, exterior cells use "x,y" format.
    /// </summary>
    public string GetKey()
    {
        return IsInterior ? Name.ToLowerInvariant() : $"{GridX},{GridY}";
    }

    public override string ToString()
    {
        var type = IsInterior ? "Interior" : "Exterior";
        var desc = IsInterior ? Name : $"{GridX},{GridY}";
        return $"Cell('{desc}', {type}, refs={References.Count})";
    }
}

// =============================================================================
// LAND RECORD (LAND) - Terrain data
// =============================================================================

/// <summary>
/// Land record - terrain heightmap and texture data.
/// </summary>
[GlobalClass]
public partial class NativeLandRecord : RefCounted
{
    public string RecordId { get; set; } = "";
    public int CellX { get; set; } = 0;
    public int CellY { get; set; } = 0;

    // Height data (65x65 vertices)
    public float[] Heights { get; set; } = Array.Empty<float>();
    public byte[] Normals { get; set; } = Array.Empty<byte>();

    // Texture data (16x16 quads)
    public int[] TextureIndices { get; set; } = Array.Empty<int>();

    // Vertex colors (65x65 RGB)
    public byte[] VertexColors { get; set; } = Array.Empty<byte>();

    public bool HasHeights => Heights.Length > 0;
    public bool HasNormals => Normals.Length > 0;
    public bool HasTextures => TextureIndices.Length > 0;
    public bool HasColors => VertexColors.Length > 0;

    public string GetKey() => $"{CellX},{CellY}";

    public override string ToString() =>
        $"Land({CellX},{CellY}, heights={HasHeights}, textures={HasTextures})";
}

// =============================================================================
// LAND TEXTURE RECORD (LTEX)
// =============================================================================

/// <summary>
/// Land texture record - terrain texture definition.
/// </summary>
[GlobalClass]
public partial class NativeLandTextureRecord : RefCounted
{
    public string RecordId { get; set; } = "";
    public int Index { get; set; } = 0;
    public string Texture { get; set; } = "";

    public override string ToString() => $"LandTexture('{RecordId}', idx={Index}, tex='{Texture}')";
}

// =============================================================================
// NPC RECORD (NPC_)
// =============================================================================

/// <summary>
/// NPC record - non-player characters.
/// </summary>
[GlobalClass]
public partial class NativeNPCRecord : NativeModelRecord
{
    public string Name { get; set; } = "";
    public string ScriptId { get; set; } = "";
    public string RaceId { get; set; } = "";
    public string ClassId { get; set; } = "";
    public string FactionId { get; set; } = "";
    public string HeadId { get; set; } = "";
    public string HairId { get; set; } = "";

    // NPC flags
    public int NpcFlags { get; set; } = 0;

    // Stats
    public int Level { get; set; } = 1;
    public int Health { get; set; } = 0;
    public int Mana { get; set; } = 0;
    public int Fatigue { get; set; } = 0;
    public int Disposition { get; set; } = 0;
    public int Reputation { get; set; } = 0;
    public int Rank { get; set; } = 0;
    public int Gold { get; set; } = 0;

    // Flag constants
    public const int FLAG_FEMALE = 0x01;
    public const int FLAG_ESSENTIAL = 0x02;
    public const int FLAG_RESPAWN = 0x04;
    public const int FLAG_AUTOCALC = 0x10;

    public bool IsFemale => (NpcFlags & FLAG_FEMALE) != 0;
    public bool IsEssential => (NpcFlags & FLAG_ESSENTIAL) != 0;
    public bool DoesRespawn => (NpcFlags & FLAG_RESPAWN) != 0;
    public bool IsAutocalc => (NpcFlags & FLAG_AUTOCALC) != 0;

    public override string ToString() => $"NPC('{RecordId}', '{Name}', L{Level})";
}

// =============================================================================
// CREATURE RECORD (CREA)
// =============================================================================

/// <summary>
/// Creature record - monsters, animals, etc.
/// </summary>
[GlobalClass]
public partial class NativeCreatureRecord : NativeModelRecord
{
    public string Name { get; set; } = "";
    public string ScriptId { get; set; } = "";
    public string OriginalId { get; set; } = "";

    // Creature flags
    public int CreatureFlags { get; set; } = 0;
    public float Scale { get; set; } = 1.0f;

    // Stats
    public int CreatureType { get; set; } = 0;
    public int Level { get; set; } = 1;
    public int Health { get; set; } = 0;
    public int Mana { get; set; } = 0;
    public int Fatigue { get; set; } = 0;
    public int Soul { get; set; } = 0;
    public int Combat { get; set; } = 0;
    public int Magic { get; set; } = 0;
    public int Stealth { get; set; } = 0;
    public int Gold { get; set; } = 0;

    // Attack values (3 attacks: min/max pairs)
    public int[] AttackMin { get; set; } = new int[3];
    public int[] AttackMax { get; set; } = new int[3];

    // Flag constants
    public const int FLAG_BIPEDAL = 0x01;
    public const int FLAG_RESPAWN = 0x02;
    public const int FLAG_WEAPON_AND_SHIELD = 0x04;
    public const int FLAG_SWIMS = 0x10;
    public const int FLAG_FLIES = 0x20;
    public const int FLAG_WALKS = 0x40;
    public const int FLAG_ESSENTIAL = 0x80;

    public bool IsBipedal => (CreatureFlags & FLAG_BIPEDAL) != 0;
    public bool DoesRespawn => (CreatureFlags & FLAG_RESPAWN) != 0;
    public bool CanSwim => (CreatureFlags & FLAG_SWIMS) != 0;
    public bool CanFly => (CreatureFlags & FLAG_FLIES) != 0;
    public bool CanWalk => (CreatureFlags & FLAG_WALKS) != 0;
    public bool IsEssential => (CreatureFlags & FLAG_ESSENTIAL) != 0;

    public override string ToString() => $"Creature('{RecordId}', '{Name}', L{Level})";
}

// =============================================================================
// RACE RECORD (RACE)
// =============================================================================

/// <summary>
/// Race record - playable and non-playable races.
/// </summary>
[GlobalClass]
public partial class NativeRaceRecord : RefCounted
{
    public string RecordId { get; set; } = "";
    public string Name { get; set; } = "";
    public string Description { get; set; } = "";
    public bool IsDeleted { get; set; } = false;

    // Height/Weight
    public float MaleHeight { get; set; } = 1.0f;
    public float FemaleHeight { get; set; } = 1.0f;
    public float MaleWeight { get; set; } = 1.0f;
    public float FemaleWeight { get; set; } = 1.0f;

    // Flags
    public int Flags { get; set; } = 0;

    public const int FLAG_PLAYABLE = 0x01;
    public const int FLAG_BEAST = 0x02;

    public bool IsPlayable => (Flags & FLAG_PLAYABLE) != 0;
    public bool IsBeast => (Flags & FLAG_BEAST) != 0;

    public override string ToString() => $"Race('{RecordId}', playable={IsPlayable}, beast={IsBeast})";
}

// =============================================================================
// BODY PART RECORD (BODY)
// =============================================================================

/// <summary>
/// Body part record - body part definitions for NPCs/creatures.
/// </summary>
[GlobalClass]
public partial class NativeBodyPartRecord : NativeModelRecord
{
    // BYDT data
    public int PartType { get; set; } = 0;
    public bool IsVampire { get; set; } = false;
    public int Flags { get; set; } = 0;
    public int MeshType { get; set; } = 0;

    // Flag constants
    public const int FLAG_FEMALE = 0x01;
    public const int FLAG_PLAYABLE = 0x02;

    public bool IsFemale => (Flags & FLAG_FEMALE) != 0;
    public bool IsPlayable => (Flags & FLAG_PLAYABLE) != 0;

    public override string ToString() => $"BodyPart('{RecordId}', type={PartType})";
}

// =============================================================================
// WEAPON RECORD (WEAP)
// =============================================================================

/// <summary>
/// Weapon record - melee weapons, bows, crossbows, ammunition.
/// </summary>
[GlobalClass]
public partial class NativeWeaponRecord : NativeModelRecord
{
    public string Name { get; set; } = "";
    public string ScriptId { get; set; } = "";
    public string Icon { get; set; } = "";
    public string EnchantId { get; set; } = "";

    // WPDT data
    public float Weight { get; set; } = 0f;
    public int Value { get; set; } = 0;
    public int WeaponType { get; set; } = 0;
    public int Health { get; set; } = 0;
    public float Speed { get; set; } = 1.0f;
    public float Reach { get; set; } = 1.0f;
    public int EnchantPoints { get; set; } = 0;
    public int ChopMin { get; set; } = 0;
    public int ChopMax { get; set; } = 0;
    public int SlashMin { get; set; } = 0;
    public int SlashMax { get; set; } = 0;
    public int ThrustMin { get; set; } = 0;
    public int ThrustMax { get; set; } = 0;
    public int Flags { get; set; } = 0;

    // Flag constants
    public const int FLAG_MAGICAL = 0x01;
    public const int FLAG_SILVER = 0x02;

    public bool IsMagical => (Flags & FLAG_MAGICAL) != 0;
    public bool IsSilver => (Flags & FLAG_SILVER) != 0;

    public override string ToString() => $"Weapon('{RecordId}', type={WeaponType})";
}

// =============================================================================
// ARMOR RECORD (ARMO)
// =============================================================================

/// <summary>
/// Armor record - equippable armor pieces.
/// </summary>
[GlobalClass]
public partial class NativeArmorRecord : NativeModelRecord
{
    public string Name { get; set; } = "";
    public string ScriptId { get; set; } = "";
    public string Icon { get; set; } = "";
    public string EnchantId { get; set; } = "";

    // AODT data
    public int ArmorType { get; set; } = 0;
    public float Weight { get; set; } = 0f;
    public int Value { get; set; } = 0;
    public int Health { get; set; } = 0;
    public int EnchantPoints { get; set; } = 0;
    public int ArmorRating { get; set; } = 0;

    public override string ToString() => $"Armor('{RecordId}', type={ArmorType}, AR={ArmorRating})";
}

// =============================================================================
// CLOTHING RECORD (CLOT)
// =============================================================================

/// <summary>
/// Clothing record - non-armor wearable items.
/// </summary>
[GlobalClass]
public partial class NativeClothingRecord : NativeModelRecord
{
    public string Name { get; set; } = "";
    public string ScriptId { get; set; } = "";
    public string Icon { get; set; } = "";
    public string EnchantId { get; set; } = "";

    // CTDT data
    public int ClothingType { get; set; } = 0;
    public float Weight { get; set; } = 0f;
    public int Value { get; set; } = 0;
    public int EnchantPoints { get; set; } = 0;

    public override string ToString() => $"Clothing('{RecordId}', type={ClothingType})";
}
