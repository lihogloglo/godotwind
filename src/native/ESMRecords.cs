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
