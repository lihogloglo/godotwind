# NIF Model Conversion System

## Overview

The NIF (NetImmerse File) converter transforms Morrowind's 3D models into Godot Node3D scenes with geometry, materials, skeletons, animations, and collision shapes.

## Key Files

| File | Purpose |
|------|---------|
| `src/core/nif/nif_converter.gd` | Main conversion entry point |
| `src/core/nif/nif_reader.gd` | Binary NIF parser |
| `src/core/nif/nif_skeleton_builder.gd` | Skeleton + skinning |
| `src/core/nif/nif_animation_converter.gd` | Keyframe animations |
| `src/core/nif/nif_collision_builder.gd` | Collision shapes |
| `src/core/nif/nif_parse_result.gd` | Thread-safe parse container |
| `collision-shapes.yaml` | Shape pattern database |

## Conversion Pipeline

```
NIF Binary → NIFReader → NIFConverter → Node3D
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
         MeshInstance3D   Skeleton3D    CollisionShape3D
         (ArrayMesh)      (bones)       (physics)
              │
              ▼
         StandardMaterial3D
         (PBR converted)
```

## API

```gdscript
# Synchronous (main thread)
var model: Node3D = nif_converter.convert(nif_data, file_path, collision_mode)

# Async (for streaming) - NEW
var parse_result = nif_converter.parse_buffer_only(nif_data, file_path)  # Worker thread
var model: Node3D = nif_converter.convert_from_parsed(parse_result, collision_mode)  # Main thread
```

## Collision Modes

```gdscript
enum CollisionMode {
    NONE,           # Visual only
    TRIMESH,        # Exact mesh (architecture)
    CONVEX,         # Convex hull (furniture)
    AUTO_PRIMITIVE, # Auto-detect box/sphere/capsule
    PRIMITIVES      # Use YAML pattern library
}
```

### YAML Collision Library

Pattern-based collision shape assignment:

```yaml
# collision-shapes.yaml
patterns:
  - pattern: "ex_*"           # Exterior architecture
    shape: trimesh
  - pattern: "furn_*_table_*" # Tables
    shape: box
  - pattern: "contain_barrel_*"
    shape: cylinder
    size: [0.3, 0.6]          # radius, height
```

## Coordinate Conversion

NIF uses Z-up, Godot uses Y-up:

```gdscript
# Position: (x, y, z) → (x, z, -y)
func _convert_position(nif_pos: Vector3) -> Vector3:
    return Vector3(nif_pos.x, nif_pos.z, -nif_pos.y) / UNITS_PER_METER

# Rotation: ZYX Euler → YZX Euler (handled via matrix conversion)
```

## Material Conversion

Legacy fixed-function → PBR approximation:

| NIF Property | Godot Property |
|-------------|----------------|
| Diffuse color | albedo_color |
| Emissive color | emission |
| Glossiness | 1.0 - roughness |
| Base texture | albedo_texture |
| Bump map | normal_texture |
| Glow texture | emission_texture |

Materials are deduplicated via `MaterialLibrary`.

## Skinned Meshes

For characters/creatures with skeletons:

1. `NIFSkeletonBuilder` creates `Skeleton3D` from bone hierarchy
2. Skin weights applied to mesh (ARRAY_BONES, ARRAY_WEIGHTS)
3. Mesh linked to skeleton via `skeleton` property

## Animations

**Embedded**: Some NIFs have keyframe data (NiTransformController)
**External**: Character animations in separate `.kf` files

```gdscript
# Load external animation
var anim = nif_kf_loader.load_animation("xbase_anim.kf")
animation_player.add_animation_library("base", anim)
```

## Supported NIF Blocks

| Block Type | Status |
|-----------|--------|
| NiNode | ✅ Hierarchy |
| NiTriShape | ✅ Mesh geometry |
| NiMaterialProperty | ✅ Materials |
| NiTexturingProperty | ✅ Textures |
| NiSkinInstance | ✅ Skinning |
| NiTransformController | ✅ Animations |
| NiVisController | ✅ Visibility |
| NiParticleSystem | ❌ Not converted |
| NiBillboardNode | ❌ Not converted |
| NiLODNode | ❌ Metadata only |

## Usage Example

```gdscript
# In CellManager
var nif_data = BSAManager.extract_file(model_path)
var model = nif_converter.convert(nif_data, model_path, CollisionMode.AUTO_PRIMITIVE)
model.transform = CoordinateSystem.convert_transform(ref.position, ref.rotation)
cell_node.add_child(model)
```

## See Also

- [STATUS.md](STATUS.md) - Implementation status
- [07_ASSET_MANAGEMENT.md](07_ASSET_MANAGEMENT.md) - BSA/texture loading
