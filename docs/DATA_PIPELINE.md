# Morrowind Data Pipeline

---

## Coordinate System Conversion

**Morrowind (Z-up):** X=East, Y=North, Z=Up
**Godot (Y-up, Z-back):** X=Right, Y=Up, Z=Back

```gdscript
func morrowind_to_godot(mw_pos: Vector3) -> Vector3:
    return Vector3(mw_pos.x, mw_pos.z, -mw_pos.y)

func morrowind_rotation_to_godot(mw_euler: Vector3) -> Vector3:
    return Vector3(mw_euler.z, mw_euler.x, -mw_euler.y)

const ESM_UNIT_SCALE: float = 1.0 / 128.0  # 1 ESM unit ~ 1/128 meter
```

**Implementation:** `src/core/coordinate_system.gd`

---

## ESM (Elder Scrolls Master) File Format

**Record Types Parsed (47 total):**
CELL, REFR, STAT, LIGH, NPC_, CREA, CONT, DOOR, ACTI, and 38 more.

**Grid-indexed cells:**
```gdscript
var cell := ESMManager.get_cell_by_grid(Vector2i(-2, 3))
var references := cell.references  # Array of object placements
```

**Native C# loader (10-30x faster):**
```csharp
// src/native/ESMLoader.cs
class ESMLoader {
    public Dictionary<string, ESMRecord> LoadRecords(string path) {
        // Fast binary parsing with BinaryReader
        // Pre-allocated buffers, no GC pressure
    }
}
```

See also: `docs/05_ESM_SYSTEM.md` for full ESM record documentation.

---

## NIF (NetImmerse File) Format

**What we extract:**
- Geometry: vertex positions, normals, UVs, vertex colors
- Materials: diffuse, ambient, specular, alpha blending
- Skeletons: bone hierarchy, bind poses
- Animations: keyframe data (from `.kf` files)
- Collision: auto-detect primitives, fallback to trimesh

**Conversion pipeline:**
```
NIF file (binary)
    | (C# NIFReader - 20-50x faster)
NIF scene graph (nodes)
    | (NIFConverter)
Godot resources (Mesh, Material, Skeleton3D)
    | (Cache to disk)
.res files (instant loading)
```

**Native C# reader:**
```csharp
// src/native/NIFReader.cs
public class NIFReader {
    public NIFNode ReadNIFFile(string path) {
        using var fs = File.OpenRead(path);
        using var br = new BinaryReader(fs);
        var header = ReadNIFHeader(br);
        var blocks = ReadBlocks(br, header.BlockCount);
        return BuildSceneGraph(blocks);
    }
}
```

**Collision shape auto-detection:**
```gdscript
func create_collision_shape(nif_node: NIFNode) -> CollisionShape3D:
    if _is_box_shaped(nif_node):
        return _create_box_shape(nif_node)
    elif _is_sphere_shaped(nif_node):
        return _create_sphere_shape(nif_node)
    elif _is_capsule_shaped(nif_node):
        return _create_capsule_shape(nif_node)
    # Fallback to trimesh (expensive)
    return _create_trimesh_shape(nif_node)
```

See also: `docs/06_NIF_SYSTEM.md` for full NIF node documentation.

---

## BSA (Bethesda Archive) Format

- Thread-safe extraction (worker threads)
- LRU cache (256MB hot cache, 1024 max entries)
- Hash-based lookup (fast file access)

```gdscript
var texture_data: PackedByteArray = BSAManager.extract_file("Textures\\tx_door_wood.dds")
var cached := BSAManager.extract_file("Meshes\\x\\door_wood.nif")  # Fast - from cache
```

See also: `docs/07_ASSET_MANAGEMENT.md` for BSA details.

---

## Texture Loading (DDS & TGA)

**DDS:** Native VRAM-compressed (DXT1/3/5), direct GPU upload, mipmap support.
**TGA:** Uncompressed fallback, larger VRAM usage.

```gdscript
func load_texture(texture_path: String) -> Texture2D:
    var dds_path := texture_path.replace(".tga", ".dds")
    if FileAccess.file_exists(dds_path):
        return load_dds_texture(dds_path)
    if FileAccess.file_exists(texture_path):
        return load_tga_texture(texture_path)
    return _placeholder_texture
```
