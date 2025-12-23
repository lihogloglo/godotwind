# Asset Streaming Pipeline - Complete Technical Reference

This document provides a comprehensive overview of how models flow from Morrowind's BSA archives through conversion, caching, and finally onto the terrain in Godotwind.

## Table of Contents

1. [Pipeline Overview](#pipeline-overview)
2. [Phase 1: BSA Extraction](#phase-1-bsa-extraction)
3. [Phase 2: NIF Conversion](#phase-2-nif-conversion)
4. [Phase 3: Coordinate System Transformation](#phase-3-coordinate-system-transformation)
5. [Phase 4: Caching System](#phase-4-caching-system)
6. [Phase 5: Runtime Loading](#phase-5-runtime-loading)
7. [Phase 6: Terrain Placement](#phase-6-terrain-placement)
8. [Distance Tier System](#distance-tier-system)
9. [Prebaking Pipeline](#prebaking-pipeline)
10. [Known Issues](#known-issues)
11. [Performance Characteristics](#performance-characteristics)

---

## Pipeline Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              DATA SOURCES                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│  Morrowind.bsa, Tribunal.bsa, Bloodmoon.bsa    (3D models, textures)       │
│  Morrowind.esm                                  (Object placement data)     │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        PHASE 1: BSA EXTRACTION                               │
│  src/core/bsa/bsa_manager.gd                                                │
│  - Reads Morrowind uncompressed BSA format (0x00000100)                     │
│  - Thread-safe extraction with Mutex protection                              │
│  - 256MB extracted data cache for frequently accessed files                  │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        PHASE 2: NIF CONVERSION                               │
│  src/core/nif/nif_converter.gd                                              │
│  - Parses NIF binary format (Morrowind version 4.0.0.2)                     │
│  - Converts geometry, materials, textures, animations                        │
│  - Generates LOD meshes (75%, 50%, 25% triangle reduction)                  │
│  - Thread-safe parsing via parse_buffer_only()                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                   PHASE 3: COORDINATE TRANSFORMATION                         │
│  src/core/coordinate_system.gd                                              │
│  - MW (X,Y,Z) → Godot (X,Z,-Y) × 1/70 scale                                │
│  - Euler conversion with EULER_ORDER_XZY                                    │
│  - Single source of truth for ALL coordinate conversions                    │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          PHASE 4: CACHING                                    │
│  Documents/Godotwind/cache/                                                  │
│  - /models/     → .res + .mesh files (NEAR tier)                            │
│  - /impostors/  → .png + .json (FAR tier)                                   │
│  - /merged_cells/ → Simplified meshes (MID tier)                            │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        PHASE 5: RUNTIME LOADING                              │
│  src/core/world/cell_manager.gd                                             │
│  - Async loading with BackgroundProcessor                                    │
│  - Object pooling for common models                                          │
│  - MultiMesh batching for 10+ identical objects                             │
│  - Time-budgeted instantiation (30 objects/frame max)                       │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                       PHASE 6: TERRAIN PLACEMENT                             │
│  src/core/world/reference_instantiator.gd                                   │
│  - Applies position, rotation, scale from ESM cell references               │
│  - Creates lights, NPCs, statics based on record type                       │
│  - StaticObjectRenderer for flora (10x faster via RenderingServer)          │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Phase 1: BSA Extraction

### Files
- `src/core/bsa/bsa_manager.gd` - Global singleton managing all BSA archives
- `src/core/bsa/bsa_reader.gd` - Low-level BSA file format parser
- `src/core/bsa/bsa_defs.gd` - BSA format constants

### BSA Format
Morrowind uses uncompressed BSA format with magic number `0x00000100`:
- Header: file count, hash table offset
- File records: size, offset for each file
- Name table: null-terminated strings
- Hash table: for fast lookups

### Caching Strategy
```gdscript
# Two-level cache system:
# 1. _file_cache: Dictionary[path → {archive, entry}] - path lookups
# 2. _extracted_cache: Dictionary[path → PackedByteArray] - raw data

const MAX_EXTRACTED_CACHE_SIZE := 256 * 1024 * 1024  # 256MB
const MAX_CACHEABLE_FILE_SIZE := 2 * 1024 * 1024     # Only cache files < 2MB
```

### Thread Safety
- Mutex-protected `_extracted_cache` for concurrent access
- Persistent file handles avoid repeated open/close overhead

### Key Functions
| Function | Purpose |
|----------|---------|
| `load_archive(path)` | Load and index a BSA file |
| `extract_file(path)` | Get raw file data (cached) |
| `has_file(path)` | Check if file exists in any archive |
| `load_archives_from_directory(dir)` | Load all BSAs from Morrowind Data Files |

---

## Phase 2: NIF Conversion

### Files
- `src/core/nif/nif_converter.gd` - Main conversion engine
- `src/core/nif/nif_reader.gd` - Binary NIF parser
- `src/core/nif/nif_defs.gd` - NIF record type definitions
- `src/core/nif/nif_skeleton_builder.gd` - Skeleton extraction
- `src/core/nif/nif_collision_builder.gd` - Collision shape generation
- `src/core/nif/mesh_simplifier.gd` - QEM mesh decimation

### NIF Record Types Supported
| NIF Type | Godot Type | Notes |
|----------|------------|-------|
| NiNode | Node3D | Scene hierarchy |
| NiTriShape | MeshInstance3D | Triangle meshes |
| NiTriStrips | MeshInstance3D | Triangle strips |
| NiSkinInstance | Skeleton3D | Skinned meshes |
| NiKeyframeController | AnimationPlayer | Animations |
| NiMaterialProperty | StandardMaterial3D | Materials |
| NiTexturingProperty | Texture2D | Textures |
| NiAlphaProperty | Material transparency | Alpha blending |

### Conversion Options
```gdscript
var converter := NIFConverter.new()
converter.load_textures = true      # Load DDS/TGA textures
converter.load_animations = false   # Skip keyframe data
converter.load_collision = true     # Generate collision shapes
converter.generate_lods = true      # Create LOD meshes
converter.generate_occluders = true # Create occlusion culling shapes
```

### LOD Generation
```gdscript
# Default LOD settings (nif_converter.gd)
lod_levels: 3
lod_reduction_ratios: [0.75, 0.5, 0.25]  # Triangle retention
lod_distances: [20, 50, 150, 500]        # Meters
lod_fade_margin: 5.0                      # Smooth transitions
min_triangles_for_lod: 100               # Skip simple meshes
```

### Thread-Safe Parsing
```gdscript
# Can run on WorkerThreadPool:
var parse_result := NIFConverter.parse_buffer_only(nif_data, path, item_id)

# Must run on main thread:
var node := converter.convert_from_parsed(parse_result)
```

---

## Phase 3: Coordinate System Transformation

### The Coordinate Systems

**Morrowind/NIF:**
- X-axis: East (positive)
- Y-axis: North (positive) - **Forward**
- Z-axis: Up (positive)
- Units: ~70 units = 1 meter
- Right-handed

**Godot:**
- X-axis: East (positive)
- Y-axis: Up (positive)
- Z-axis: South (positive) - **Back = -Forward**
- Units: meters
- Right-handed

### Fundamental Conversion
```gdscript
# coordinate_system.gd - Single source of truth

# Vector conversion: MW (x,y,z) → Godot (x,z,-y) × scale
static func vector_to_godot(mw: Vector3, apply_scale: bool = true) -> Vector3:
    var converted := Vector3(mw.x, mw.z, -mw.y)
    return converted * SCALE_FACTOR if apply_scale else converted

const SCALE_FACTOR: float = 1.0 / 70.0  # MW units to meters
```

### Rotation Conversion

**This is the complex part.** OpenMW applies rotations around **negative axes**:

```cpp
// OpenMW components/misc/convert.hpp line 50-53
osg::Quat makeOsgQuat(const float (&rotation)[3]) {
    return osg::Quat(rotation[2], osg::Vec3f(0, 0, -1))   // Z around -Z
         * osg::Quat(rotation[1], osg::Vec3f(0, -1, 0))   // Y around -Y
         * osg::Quat(rotation[0], osg::Vec3f(-1, 0, 0));  // X around -X
}
```

**Godotwind conversion:**
```gdscript
# Euler angles: MW (x,y,z) → Godot (x,z,-y)
static func euler_to_godot(mw: Vector3) -> Vector3:
    return Vector3(mw.x, mw.z, -mw.y)

# CRITICAL: Must use EULER_ORDER_XZY when applying!
var godot_euler := CS.euler_to_godot(ref.rotation)
node.basis = Basis.from_euler(godot_euler, EULER_ORDER_XZY)
```

### Where Transformations Are Applied

| Stage | File | What's Converted |
|-------|------|------------------|
| NIF node transforms | nif_converter.gd:518 | `CS.transform_to_godot()` |
| NIF vertices | nif_converter.gd:656-665 | `CS.vectors_to_godot()` |
| NIF normals | nif_converter.gd:668 | `CS.vectors_to_godot(normals, false)` |
| ESM cell positions | reference_instantiator.gd:462 | `CS.vector_to_godot()` |
| ESM cell rotations | reference_instantiator.gd:472-473 | `CS.euler_to_godot()` + `EULER_ORDER_XZY` |

---

## Phase 4: Caching System

### Cache Directory Structure
```
Documents/Godotwind/cache/
├── models/           # Individual model .res + .mesh files
├── impostors/        # Octahedral impostor .png + .json
├── merged_cells/     # Simplified cell meshes for MID tier
├── terrain/          # Terrain3D heightmap regions
├── navmeshes/        # Navigation mesh data
└── ocean/            # Shore mask for water rendering
```

### Model Cache Format

Each model is saved as:
- `{safe_name}.res` - PackedScene with embedded materials/textures
- `{safe_name}_mesh_0.mesh`, `_mesh_1.mesh`, etc. - Mesh resources

```gdscript
# model_prebaker.gd - Cache key generation
var cache_key := model_path.to_lower().replace("/", "\\")
var safe_name := cache_key.replace("\\", "_").replace("/", "_").replace(":", "_").replace(".", "_")
# Example: "meshes\x\ex_hlaalu_b_01.nif" → "meshes_x_ex_hlaalu_b_01_nif"
```

### Impostor Cache Format

Each impostor consists of:
- `{basename}_{hash}.png` - 2048×1024 atlas (8 frames in 4×2 grid)
- `{basename}_{hash}.json` - Metadata

```json
{
  "version": 2,
  "model_path": "meshes\\x\\ex_dae_azura.nif",
  "bounds": {
    "width": 8.17,
    "height": 14.08,
    "depth": 5.08
  },
  "settings": {
    "texture_size": 512,
    "frames": 8,
    "min_distance": 2000,
    "max_distance": 5000
  },
  "frame_uvs": [...],
  "directions": [...]
}
```

### Cache Lookup Order
```gdscript
# model_loader.gd - get_model()
func get_model(model_path: String, item_id: String = "") -> Node3D:
    # 1. Memory cache (fastest, per-session)
    if _model_cache.has(cache_key):
        return _model_cache[cache_key].duplicate()

    # 2. Disk cache (fast, 1-5ms)
    if enable_disk_cache and has_disk_cached(model_path, item_id):
        return _load_from_disk_cache(model_path, item_id)

    # 3. BSA + NIF conversion (slow, 300ms-6s)
    return _load_and_convert(model_path, item_id)
```

---

## Phase 5: Runtime Loading

### Cell Manager Architecture

```gdscript
# cell_manager.gd - Core components
var _model_loader: ModelLoader       # Model caching and loading
var _instantiator: ReferenceInstantiator  # Object creation
var _character_factory: CharacterFactory   # NPC/creature creation
var _object_pool: ObjectPool         # Reusable model instances
var _static_renderer: StaticObjectRenderer  # Fast flora rendering
```

### Async Loading Pipeline

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│  Cell Request    │────▶│ Background Parse │────▶│ Main Thread      │
│                  │     │ (WorkerThread)   │     │ Conversion       │
└──────────────────┘     └──────────────────┘     └──────────────────┘
                                                          │
                                                          ▼
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│  Scene Tree      │◀────│ Time-Budgeted    │◀────│ Instantiation    │
│  Add             │     │ Processing       │     │ Queue            │
└──────────────────┘     └──────────────────┘     └──────────────────┘
```

### Async Limits
```gdscript
const MAX_ASYNC_REQUESTS := 6           # Concurrent cell requests
const MAX_INSTANTIATION_QUEUE := 8000   # Pending objects
const MAX_INSTANTIATIONS_PER_FRAME := 30  # Objects per frame
const MAX_CONVERSIONS_PER_FRAME := 1    # NIF conversions per frame
```

### Object Pooling
```gdscript
# Common models are pre-pooled for instant acquire()
# Pool warmup creates 33% of max instances at startup
var initial_count: int = maxi(8, pool_size / 3)
_object_pool.register_model(model_path, prototype, initial_count, pool_size)
```

### MultiMesh Batching
Models with 10+ instances in a cell are batched into MultiMesh:
- Small rocks (`terrain_rock_rm_*`)
- Containers (`contain_barrel`, `contain_crate`)
- Common clutter (`misc_com_bottle_*`)

```gdscript
const min_instances_for_multimesh: int = 10
```

---

## Phase 6: Terrain Placement

### Reference Instantiation

```gdscript
# reference_instantiator.gd - instantiate_reference()
func instantiate_reference(ref: CellReference, cell_grid: Vector2i) -> Node3D:
    # 1. Look up base record from ESM
    var base_record = ESMManager.get_any_record(ref.ref_id, record_type)

    # 2. Dispatch by type
    match record_type:
        "light": return _instantiate_light(ref, base_record)
        "npc": return _instantiate_npc(ref, base_record)
        "creature": return _instantiate_creature(ref, base_record)
        _: return _instantiate_model_object(ref, base_record)
```

### Transform Application

```gdscript
func _apply_transform(node: Node3D, ref: CellReference, apply_model_rotation: bool) -> void:
    # Position: MW units → Godot meters
    node.position = CS.vector_to_godot(ref.position)

    # Scale: uniform float → Vector3
    node.scale = CS.scale_to_godot(ref.scale)

    # Rotation: MW Euler → Godot Euler with correct order
    var godot_euler := CS.euler_to_godot(ref.rotation)
    node.basis = Basis.from_euler(godot_euler, EULER_ORDER_XZY)
```

### Static Object Renderer
Flora and small rocks use RenderingServer directly for 10x faster rendering:

```gdscript
# Bypasses Node3D overhead entirely
var instance_rid := RenderingServer.instance_create()
RenderingServer.instance_set_base(instance_rid, mesh_rid)
RenderingServer.instance_set_transform(instance_rid, transform)
```

---

## Distance Tier System

### Tier Definitions

| Tier | Distance | Data Format | Manager |
|------|----------|-------------|---------|
| NEAR | 0-500m | Full 3D + LODs | CellManager |
| MID | 500m-2km | Pre-merged simplified | DistantStaticRenderer |
| FAR | 2km-5km | Octahedral impostors | ImpostorManager |
| HORIZON | 5km+ | Skybox only | - |

### NEAR Tier (Full Detail)
- Per-cell loading via `CellManager`
- Full 3D geometry with 4 LOD levels
- Object pooling and MultiMesh batching
- Load priority: 100 (highest)

### MID Tier (Simplified)
- Pre-merged cell meshes from `mesh_prebaker_v2.gd`
- 95% triangle reduction via QEM simplification
- Quadtree chunks (4×4 cells per chunk)
- Load priority: 50

### FAR Tier (Impostors)
- Octahedral billboard textures from `impostor_baker_v2.gd`
- 8 viewing angles (N, NE, E, SE, S, SW, W, NW)
- 512×512 per frame, packed into 2048×1024 atlas
- Frame selection based on camera angle
- Load priority: 25

---

## Prebaking Pipeline

### Component Order
```gdscript
# prebaking_manager.gd - start_prebaking()
enum Component {
    TERRAIN,       # 1. Heightmaps → Terrain3D regions
    MODELS,        # 2. NIF → .res files (NEAR tier)
    IMPOSTORS,     # 3. Model → octahedral textures (FAR tier)
    MERGED_MESHES, # 4. Cell → simplified mesh (MID tier)
    NAVMESHES,     # 5. Terrain + objects → navigation
    SHORE_MASK,    # 6. Terrain → ocean visibility
}
```

### Model Prebaking
```gdscript
# model_prebaker.gd
# Scans all ESM records for unique models:
var record_sources := [
    ESMManager.statics,
    ESMManager.activators,
    ESMManager.containers,
    ESMManager.doors,
    ESMManager.lights,
    # ... etc
]
# Converts each to .res + .mesh files
```

### Impostor Baking
```gdscript
# impostor_baker_v2.gd
const OCTAHEDRAL_DIRECTIONS := [
    Vector3(0, 0, 1),      # Front (N)
    Vector3(1, 0, 1),      # Front-Right (NE)
    Vector3(1, 0, 0),      # Right (E)
    Vector3(1, 0, -1),     # Back-Right (SE)
    Vector3(0, 0, -1),     # Back (S)
    Vector3(-1, 0, -1),    # Back-Left (SW)
    Vector3(-1, 0, 0),     # Left (W)
    Vector3(-1, 0, 1),     # Front-Left (NW)
]
```

### Merged Mesh Baking
```gdscript
# mesh_prebaker_v2.gd
var simplification_ratio: float = 0.05  # 95% reduction
var min_object_size: float = 2.0        # Skip small objects
var max_vertices_per_mesh: int = 65535  # GPU limit
```

---

## Known Issues

### Rotation Bug (Under Investigation)

Models may face incorrect directions. The issue is in how rotation angles are converted from Morrowind to Godot.

**OpenMW applies rotations around NEGATIVE axes:**
```cpp
// OpenMW uses negative axes, effectively negating angles
Quat(rot[2], Vec3(0, 0, -1)) * Quat(rot[1], Vec3(0, -1, 0)) * Quat(rot[0], Vec3(-1, 0, 0))
```

**Current Godotwind conversion may be missing angle negation.**

See `coordinate_system.gd:euler_to_godot()` for the current implementation.

### Other Known Issues
- Some animated models may have bone orientation issues
- Certain particle effects are not yet implemented
- Door collision shapes may not align perfectly with visual mesh

---

## Performance Characteristics

### Timing Benchmarks

| Operation | Cold (First Run) | Warm (Cached) |
|-----------|-----------------|---------------|
| BSA extraction | 1-10ms | 0.1ms (cache hit) |
| NIF conversion | 300ms-6s | N/A |
| Disk cache load | N/A | 1-5ms |
| Memory cache hit | N/A | 0.01ms |
| Object instantiation | 0.35ms avg | 0.1ms (pooled) |

### Memory Usage

| Component | Typical Size |
|-----------|--------------|
| BSA extracted cache | 0-256MB |
| Model memory cache | 50-200MB |
| Disk cache (models) | 500MB-2GB |
| Disk cache (impostors) | 100-500MB |
| Per-cell objects | 5-50MB |

### Frame Budget

At 60 FPS (16.6ms per frame):
- Object instantiation: ~10.5ms (30 objects × 0.35ms)
- Remaining for rendering: ~6ms
- NIF conversion deferred to 1 per frame to avoid spikes

---

## File Reference

| Component | Primary File |
|-----------|--------------|
| BSA extraction | `src/core/bsa/bsa_manager.gd` |
| NIF conversion | `src/core/nif/nif_converter.gd` |
| Coordinate system | `src/core/coordinate_system.gd` |
| Model loading | `src/core/world/model_loader.gd` |
| Cell management | `src/core/world/cell_manager.gd` |
| Object instantiation | `src/core/world/reference_instantiator.gd` |
| Model prebaking | `src/tools/prebaking/model_prebaker.gd` |
| Impostor baking | `src/tools/prebaking/impostor_baker_v2.gd` |
| Mesh prebaking | `src/tools/prebaking/mesh_prebaker_v2.gd` |
| Prebake orchestration | `src/tools/prebaking/prebaking_manager.gd` |
| Distance tiers | `src/core/world/distance_tier_manager.gd` |
| Object pooling | `src/core/world/object_pool.gd` |
| Static rendering | `src/core/world/static_object_renderer.gd` |
