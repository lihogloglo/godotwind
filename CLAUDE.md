# Godotwind Project Guidelines - Godot 4.5 Edition

**Last Updated:** 2026-01-08
**Godot Version:** 4.5 (released September 2025)
**Project:** Next-gen Morrowind framework showcasing Godot 4.5's best capabilities

---

## Philosophy

This is **not a faithful Morrowind port** - this is "Morrowind if it was made in 2025 with modern Godot." We leverage:

- ✅ Godot 4.5's rendering advances (Forward+, Mobile renderer improvements)
- ✅ Native distance rendering (`visibility_range`, occlusion culling)
- ✅ Modern animation systems (AnimationTree, state machines, retargeting)
- ✅ C# for performance bottlenecks (20-50x faster parsing)
- ✅ Custom shaders for next-gen effects (ocean FFT, deformation, impostors)
- ✅ Async streaming architecture with worker threads

**Goal:** Best-in-class open-world rendering in Godot, using Morrowind as the data source.

---

## Table of Contents

1. [Godot 4.5 Features We Use](#godot-45-features-we-use)
2. [Language & Typing Policy](#language--typing-policy)
3. [Project Architecture](#project-architecture)
4. [Distance Rendering System](#distance-rendering-system)
5. [Performance Best Practices](#performance-best-practices)
6. [Morrowind Data Pipeline](#morrowind-data-pipeline)
7. [Async Loading & Streaming](#async-loading--streaming)
8. [Rendering & Shaders](#rendering--shaders)
9. [Animation System](#animation-system)
10. [Code Style & Standards](#code-style--standards)
11. [Known Issues & Workarounds](#known-issues--workarounds)
12. [Resources & Documentation](#resources--documentation)

---

## Godot 4.5 Features We Use

### Rendering Enhancements (New in 4.5)

**Forward+ and Mobile Renderer Improvements:**
- ✅ **Specular occlusion** rework (ambient-based, cheaper option available)
- ✅ **Motion vectors in Mobile renderer** (previously Forward+ only)
- ✅ **Explicit FP16 usage** for Mobile renderer optimization
- ✅ **Stencil buffer support** (all backends) - useful for portals/selections
- ✅ **SMAA support** and **bent normal maps**
- ✅ **Fragment density maps** for Mobile renderer

**LOD & Culling:**
- ✅ **Mesh LOD system** with `visibility_range_begin/end/fade_mode`
- ✅ **Automatic LOD crossfading** (FADE_SELF, FADE_DEPENDENCIES)
- ✅ **Occlusion culling** (best for interiors, limited benefit outdoors)
- ⚠️ **Note:** Godot 4.5.dev3 has an [open issue](https://github.com/godotengine/godot/issues/106184) with occlusion culling behavior from certain angles

**What Godot 4.5 Does NOT Have (We Implement Ourselves):**
- ❌ No automatic mesh simplification API - we use preprocessed LODs or C# libraries
- ❌ No built-in impostor system - we use custom octahedral impostors
- ❌ No automatic texture atlasing - we manage this manually

### Animation System

**AnimationTree Features:**
- ✅ **State machines** (`AnimationNodeStateMachine`)
- ✅ **BlendSpace1D/2D** with automatic triangulation
- ✅ **Animation retargeting** via `SkeletonProfileHumanoid`
- ✅ **BoneMap auto-mapping** for common skeleton names

### Threading & Performance

**Worker Thread API:**
- ✅ `WorkerThreadPool.add_task()` for async operations
- ✅ `ResourceLoader.load_threaded_request()` for async resource loading
- ✅ `Mutex` for cross-thread synchronization

### Shader & Compute

**Shader Capabilities:**
- ✅ **Shader baker** pre-compiles shaders during export (reduces stutter)
- ✅ **Compute shaders** for ocean FFT, terrain generation
- ✅ **Custom material properties** for FPS-style first-person objects
- ✅ **`sampler2DArray`** for texture atlasing (impostor batching)

### Accessibility (New in 4.5)

- ✅ **Screen reader support** via AccessKit (Control nodes, Project Manager)
- ℹ️ Not currently used in this project (world explorer tool, not end-user game)

---

## Language & Typing Policy

### Language Distribution

| Language | Usage | Where |
|----------|-------|-------|
| **GDScript** | 95% | Core systems, UI, tools, gameplay |
| **C#** | 5% | Performance bottlenecks (NIF parsing, ESM loading, binary I/O) |
| **GLSL/GDSHADER** | Shaders | Ocean FFT, deformation, impostors, selection |

### When to Use C# vs GDScript

**Use C#** when:
- ✅ Parsing binary formats (20-50x faster)
- ✅ Heavy computation (terrain generation, mesh simplification)
- ✅ Data structures with many small objects (cache systems)
- ⚠️ **BUT:** Note that C# cannot call GDExtensions directly - workaround via GDScript bridge

**Use GDScript** when:
- ✅ Godot API-heavy code (scene tree, signals, nodes)
- ✅ Rapid prototyping and iteration
- ✅ UI/tool scripts
- ✅ Gameplay logic

**C# Performance Caveat:**
- C# has higher overhead for **Godot API calls** (Variant marshalling)
- C# excels at **pure computation** and **data processing**
- **Pattern:** Use C# for heavy lifting, GDScript for orchestration

### GDScript Typing Policy

**Project uses warnings (not errors)** - code compiles even without types.

**Strict typing required:**
```gdscript
# Core data structures
class_name ESMRecord extends RefCounted

var record_type: String = ""
var flags: int = 0
var data: PackedByteArray = []

func parse_cell(reader: Reader) -> CellRecord:
    var cell := CellRecord.new()
    cell.name = reader.read_string()
    return cell
```

**Strict typing locations:**
- ✅ Core data structures: `ESMRecord`, `NIFNode`, `BSAEntry`
- ✅ Performance-critical: streaming, terrain, chunk management
- ✅ Public APIs: autoloads (`ESMManager`, `BSAManager`, etc.)
- ✅ Anything in `src/core/`

**Relaxed typing allowed:**
```gdscript
# Tool scripts, tests, one-off utilities
@warning_ignore("untyped_declaration", "unsafe_method_access")
extends Node

var result = some_variant.call_method()  # OK for tools
```

**Relaxed typing locations:**
- ✅ UI/Tool scripts: `prebaking_ui.gd`, `world_explorer.gd`, `nif_viewer.gd`
- ✅ Test scripts: `tests/` folder
- ✅ One-off utilities: baker scripts, debug tools

**Per-line warning suppression:**
```gdscript
@warning_ignore("unsafe_method_access")
var texture = material.get("albedo_texture")
```

---

## Project Architecture

### Directory Structure

```
godotwind/
├── src/
│   ├── core/              # Core engine systems (strict typing)
│   │   ├── world/         # Streaming, LOD, cell management
│   │   ├── nif/           # NIF model parsing & conversion
│   │   ├── esm/           # Elder Scrolls Master file parsing
│   │   ├── bsa/           # Bethesda Archive reading
│   │   ├── texture/       # DDS/TGA loading, material deduplication
│   │   ├── water/         # Ocean simulation, FFT waves, buoyancy
│   │   ├── animation/     # Character animation system (V2 with IK)
│   │   ├── character/     # NPC assembly, body part slotting
│   │   ├── deformation/   # RTT-based terrain deformation
│   │   ├── streaming/     # Background task processing
│   │   └── player/        # Camera controls, movement
│   ├── native/            # C# performance implementations
│   └── tools/             # Editor tools, prebaking utilities
├── addons/                # Third-party and custom plugins
│   └── terrain_3d/        # Heightmap rendering
├── tests/                 # Test scripts (relaxed typing)
└── docs/                  # Documentation and audits
```

### Autoloads (Global Singletons)

**Core Systems:**
```gdscript
# Access via SettingsManager.get_cache_dir()
SettingsManager    # User settings and paths
BSAManager         # Bethesda archive file access (256MB LRU cache)
ESMManager         # Elder Scrolls Master file parsing, grid indexing
OceanManager       # Water system coordinator
```

**Usage Pattern:**
```gdscript
# Good - use autoloads for global state
var morrowind_path := SettingsManager.get_morrowind_install_path()
var cell_record := ESMManager.get_cell_by_grid(Vector2i(0, 0))

# Bad - don't create duplicate managers
var my_bsa = BSAManager.new()  # ❌ Use the autoload instead
```

### Key Design Patterns

**1. NativeBridge Pattern (GDScript ↔ C# Interop)**
```gdscript
# GDScript calls into C# for performance
class_name NativeFactory

static func create_esm_loader() -> Object:
    if ClassDB.class_exists("ESMLoader"):
        return ClassDB.instantiate("ESMLoader")
    else:
        push_warning("Native ESM loader not available, using fallback")
        return ESMLoaderGD.new()
```

**2. Async Loading with BackgroundProcessor**
```gdscript
# Non-blocking cell loading
func load_cell_async(grid: Vector2i) -> void:
    var job_id := background_processor.submit_job(func() -> Node3D:
        return _cell_manager.load_exterior_cell(grid.x, grid.y)
    )
    _pending_jobs[job_id] = grid
```

**3. Frame Time Budgeting**
```gdscript
func _process(delta: float) -> void:
    var start_time := Time.get_ticks_msec()

    while not _load_queue.is_empty():
        var item = _load_queue.pop_front()
        _instantiate_object(item)

        var elapsed := Time.get_ticks_msec() - start_time
        if elapsed >= FRAME_BUDGET_MS:
            break  # Continue next frame
```

**4. Object Pooling**
```gdscript
# Reusable nodes for common models
var pool: Array[Node3D] = []

func get_instance(prototype: Node3D) -> Node3D:
    if pool.is_empty():
        return prototype.duplicate()
    return pool.pop_back()

func return_instance(instance: Node3D) -> void:
    instance.get_parent().remove_child(instance)
    pool.push_back(instance)
```

**5. MultiMesh Batching**
```gdscript
# Single draw call for 10+ identical objects
if identical_refs.size() >= MULTIMESH_THRESHOLD:
    var multimesh := MultiMeshInstance3D.new()
    multimesh.multimesh = MultiMesh.new()
    multimesh.multimesh.mesh = base_mesh
    multimesh.multimesh.instance_count = identical_refs.size()

    for i in identical_refs.size():
        multimesh.multimesh.set_instance_transform(i, transforms[i])
```

---

## Distance Rendering System

**⚠️ CRITICAL:** See [`docs/DISTANCE_RENDERING_AUDIT.md`](docs/DISTANCE_RENDERING_AUDIT.md) for implementation status.

### Three-Tier System (0-5km)

| Tier | Distance | Technique | Godot Feature | Status |
|------|----------|-----------|---------------|--------|
| **NEAR** | 0-150m | Full 3D meshes + physics | Native nodes + collision | ✅ **Working** |
| **MID** | 150-500m | Per-object LOD meshes (3 levels) | `visibility_range` + MultiMesh | ⚠️ **Partially Working** |
| **FAR** | 500-5km | Octahedral impostors | Single batched MultiMesh | ⚠️ **In Progress** |

### Distance Constants (Single Source of Truth)

**Location:** [`src/core/world/distance_utils.gd`](src/core/world/distance_utils.gd)

```gdscript
const CELL_SIZE_METERS: float = 117.0  # Morrowind cell size

# Tier boundaries
const NEAR_END: float = 150.0          # 0-150m: Full meshes
const MID_END: float = 500.0           # 150-500m: LOD meshes
const FAR_END: float = 5000.0          # 500-5000m: Impostors
const FADE_MARGIN: float = 50.0        # Crossfade zone size

# MID tier LOD levels
const MID_LOD1_END: float = 250.0      # 50% triangles
const MID_LOD2_END: float = 375.0      # 25% triangles
const MID_LOD3_END: float = 500.0      # 10% triangles
```

### LOD Configuration with visibility_range

**NEAR tier (0-150m):**
```gdscript
func configure_near_object(geo: GeometryInstance3D) -> void:
    geo.visibility_range_begin = 0.0
    geo.visibility_range_end = NEAR_END
    geo.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
    geo.visibility_range_end_margin = FADE_MARGIN  # Hysteresis prevents flicker
```

**MID tier LODs (150-500m):**
```gdscript
# LOD1 (150-250m, 50% poly reduction)
func configure_mid_lod1(geo: GeometryInstance3D) -> void:
    geo.visibility_range_begin = NEAR_END
    geo.visibility_range_end = MID_LOD1_END
    geo.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES

# LOD2, LOD3 similarly...
```

**FAR tier (500-5000m):**
```gdscript
# Impostors use custom shader, not visibility_range on individual objects
# Single MultiMeshInstance3D renders all impostors in one draw call
```

### Impostor Rendering (Custom Implementation)

**Why custom impostors?**
- Godot 4.5 has no built-in impostor system
- Community plugin [Godot-Octahedral-Impostors](https://github.com/wojtekpil/Godot-Octahedral-Impostors) exists but we use simplified version

**Technique: Octahedral Billboard**
- 8 views of each model (octahedral projection)
- Baked to single texture (512x512 per model)
- Custom shader selects view based on camera angle
- All impostors rendered in **single draw call** via `sampler2DArray`

**Implementation:** [`src/core/world/native_impostor_renderer.gd`](src/core/world/native_impostor_renderer.gd)

**Shader snippet:**
```glsl
uniform sampler2DArray impostor_textures;

void fragment() {
    // Calculate view direction (octahedral)
    vec3 view_dir = normalize(CAMERA_POSITION_WORLD - VERTEX);
    int layer_index = calculate_octahedral_layer(view_dir);

    // Sample from texture array
    vec4 color = texture(impostor_textures, vec3(UV, float(layer_index)));
    ALBEDO = color.rgb;
    ALPHA = color.a;
}
```

### LOD Generation Approach

**Current Implementation:** Preprocessed LOD meshes

**Why preprocessed?**
- ❌ Godot 4.5 has no built-in mesh simplification API
- ⚠️ [Issue #3861](https://github.com/godotengine/godot-proposals/issues/3861) tracks LOD generation improvements
- ✅ Preprocessed meshes are faster (no runtime cost)
- ✅ Artist-controlled quality (can tweak reduction ratios)

**LOD Reduction Ratios:**
```gdscript
# Defined in prebaking scripts
const LOD1_RATIO: float = 0.75  # 75% of original triangles (250m)
const LOD2_RATIO: float = 0.50  # 50% of original triangles (375m)
const LOD3_RATIO: float = 0.25  # 25% of original triangles (500m)
```

**Alternative (Not Currently Used):**
- Runtime mesh simplification using external libraries
- [godot-mesh-simplify proposal](https://github.com/godotengine/godot-proposals/discussions/3630)
- Requires C++ GDExtension or C# wrapper

---

## Performance Best Practices

### Measured Performance Targets

**Current Performance:**
- NIF parsing: **20-50x faster** with C# native code
- ESM loading: **10-30x faster** with native cache
- Cell loading time budget: **2ms/frame**
- Terrain generation budget: **8ms/frame**
- Async instantiation: **50 objects/frame** (0.35ms each)

**Target FPS:**
- Desktop (Forward+): **60 FPS** (16.67ms/frame)
- Mobile: **30 FPS** (33.33ms/frame)

### Frame Time Budgeting

**Pattern:**
```gdscript
@export var frame_budget_ms: float = 8.0  # Adjust based on target FPS

func _process(delta: float) -> void:
    var start_time := Time.get_ticks_msec()

    # Load objects with budget limiting
    while not _load_queue.is_empty():
        var obj = _load_queue.pop_front()
        _instantiate_object(obj)

        var elapsed := Time.get_ticks_msec() - start_time
        if elapsed >= frame_budget_ms:
            break  # Continue next frame
```

**Budget Allocation:**
```
Total frame: 16.67ms (60 FPS)
├── Godot engine: ~5ms (physics, rendering, input)
├── Gameplay logic: ~3ms (scripts, AI, etc.)
├── Streaming: 8ms (cell loading, object instantiation)
└── Reserve: 0.67ms (buffer for spikes)
```

### Async Loading Architecture

**Use ResourceLoader for threaded loading:**
```gdscript
# Start async load
ResourceLoader.load_threaded_request(path)

# Poll in _process()
var status := ResourceLoader.load_threaded_get_status(path)
if status == ResourceLoader.THREAD_LOAD_LOADED:
    var resource := ResourceLoader.load_threaded_get(path)
```

**Use WorkerThreadPool for heavy operations:**
```gdscript
# Offload duplicate() to worker thread
WorkerThreadPool.add_task(func():
    var instance := prototype.duplicate()
    call_deferred("_on_instance_ready", instance)
)
```

**Frame-based async pipeline:**
```
Frame 1: Request cell data from ESM
Frame 2: Parse NIF files (worker thread)
Frame 3: Convert to mesh (worker thread)
Frame 4-10: Instantiate objects (50/frame, time-budgeted)
Frame 11: Signal cell_loaded
```

### Material Deduplication

**Problem:** Morrowind has 10,000+ material instances, many identical

**Solution: Global material library**
```gdscript
class_name MaterialLibrary

# Hash material properties for deduplication
static func get_material_hash(properties: Dictionary) -> int:
    var hash_str := "%s_%s_%s_%s" % [
        properties.get("albedo_texture", ""),
        properties.get("metallic", 0.0),
        properties.get("roughness", 1.0),
        properties.get("transparency", 0.0)
    ]
    return hash_str.hash()

static func get_or_create_material(properties: Dictionary) -> Material:
    var hash := get_material_hash(properties)
    if _material_cache.has(hash):
        return _material_cache[hash]

    var mat := _create_material(properties)
    _material_cache[hash] = mat
    return mat
```

**Result:** ~90% reduction in unique materials (10,000 → 1,000)

### MultiMesh Batching

**When to batch:**
```gdscript
const MULTIMESH_THRESHOLD: int = 10  # Batch if 10+ identical objects

func should_batch(model_path: String, count: int) -> bool:
    return count >= MULTIMESH_THRESHOLD
```

**Single draw call for batched objects:**
```gdscript
var multimesh := MultiMesh.new()
multimesh.transform_format = MultiMesh.TRANSFORM_3D
multimesh.instance_count = instances.size()
multimesh.mesh = base_mesh

# Set per-instance transforms
for i in instances.size():
    multimesh.set_instance_transform(i, instances[i].transform)

    # Optional: per-instance custom data (texture index, etc.)
    if use_custom_data:
        multimesh.set_instance_custom_data(i, custom_data[i])
```

**Impostor rendering uses this for entire FAR tier** (single draw call for 1000+ objects)

### Memory Management

**RefCounted for temporary objects:**
```gdscript
# Automatically freed when no references remain
class_name TemporaryData extends RefCounted

var buffer: PackedByteArray
var metadata: Dictionary
```

**Object pooling for frequently allocated nodes:**
```gdscript
# Reuse instead of instantiate/free
var pool: Array[Node3D] = []

func pre_warm_pool(prototype: Node3D, count: int) -> void:
    for i in count:
        pool.push_back(prototype.duplicate())
```

**Static caches for parsed data:**
```gdscript
# Shared across all instances
static var skeleton_cache: Dictionary = {}
static var animation_library_cache: Dictionary = {}

func get_skeleton(nif_path: String) -> Skeleton3D:
    if skeleton_cache.has(nif_path):
        return skeleton_cache[nif_path]

    var skeleton := _parse_skeleton(nif_path)
    skeleton_cache[nif_path] = skeleton
    return skeleton
```

---

## Morrowind Data Pipeline

### Coordinate System Conversion

**Morrowind (Z-up):**
- X: East
- Y: North
- Z: Up

**Godot (Y-up, Z-back):**
- X: Right
- Y: Up
- Z: Back (mirrored from forward)

**Conversion:**
```gdscript
func morrowind_to_godot(mw_pos: Vector3) -> Vector3:
    # Morrowind: (X, Y, Z) -> Godot: (X, Z, -Y)
    return Vector3(mw_pos.x, mw_pos.z, -mw_pos.y)

func morrowind_rotation_to_godot(mw_euler: Vector3) -> Vector3:
    # Morrowind uses radians, Godot uses radians (but different axes)
    return Vector3(mw_euler.z, mw_euler.x, -mw_euler.y)
```

**Scale factor:**
```gdscript
const ESM_UNIT_SCALE: float = 1.0 / 128.0  # 1 ESM unit ≈ 1/128 meter
```

### ESM (Elder Scrolls Master) File Format

**Record Types Parsed (44 total):**
- `CELL` - Exterior/interior cells
- `REFR` - Object references (placed objects)
- `STAT` - Static meshes
- `LIGH` - Lights
- `NPC_` - NPCs
- `CREA` - Creatures
- `CONT` - Containers
- `DOOR` - Doors
- `ACTI` - Activators
- ...and 35 more

**Grid-indexed cells:**
```gdscript
# ESMManager provides fast spatial lookup
var cell := ESMManager.get_cell_by_grid(Vector2i(-2, 3))
var references := cell.references  # Array of object placements
```

**Native C# loader (10-30x faster):**
```gdscript
# src/native/ESMLoader.cs
class ESMLoader {
    public Dictionary<string, ESMRecord> LoadRecords(string path) {
        // Fast binary parsing with BinaryReader
        // Pre-allocated buffers, no GC pressure
    }
}
```

### NIF (NetImmerse File) Format

**What we extract:**
- ✅ Geometry: vertex positions, normals, UVs, vertex colors
- ✅ Materials: diffuse, ambient, specular, alpha blending
- ✅ Skeletons: bone hierarchy, bind poses
- ✅ Animations: keyframe data (from `.kf` files)
- ✅ Collision: auto-detect primitives, fallback to trimesh

**Conversion pipeline:**
```
NIF file (binary)
    ↓ (C# NIFReader - 20-50x faster)
NIF scene graph (nodes)
    ↓ (NIFConverter)
Godot resources (Mesh, Material, Skeleton3D)
    ↓ (Cache to disk)
.res files (instant loading)
```

**Native C# reader:**
```csharp
// src/native/NIFReader.cs
public class NIFReader {
    public NIFNode ReadNIFFile(string path) {
        using var fs = File.OpenRead(path);
        using var br = new BinaryReader(fs);

        // Fast binary parsing
        var header = ReadNIFHeader(br);
        var blocks = ReadBlocks(br, header.BlockCount);

        return BuildSceneGraph(blocks);
    }
}
```

**Collision shape auto-detection:**
```gdscript
func create_collision_shape(nif_node: NIFNode) -> CollisionShape3D:
    # Try primitive shapes first (cheaper)
    if _is_box_shaped(nif_node):
        return _create_box_shape(nif_node)
    elif _is_sphere_shaped(nif_node):
        return _create_sphere_shape(nif_node)
    elif _is_capsule_shaped(nif_node):
        return _create_capsule_shape(nif_node)

    # Fallback to trimesh (expensive)
    return _create_trimesh_shape(nif_node)
```

### BSA (Bethesda Archive) Format

**Features:**
- ✅ Thread-safe extraction (worker threads)
- ✅ LRU cache (256MB hot cache)
- ✅ Hash-based lookup (fast file access)

**Usage pattern:**
```gdscript
# Extract file from archive
var texture_data: PackedByteArray = BSAManager.extract_file("Textures\\tx_door_wood.dds")

# Automatic caching
var cached := BSAManager.extract_file("Meshes\\x\\door_wood.nif")  # Fast - from cache
```

**Cache eviction:**
```gdscript
const MAX_CACHE_SIZE_MB: int = 256
const MAX_CACHE_ENTRIES: int = 1024

func _evict_lru_entry() -> void:
    var oldest_key: String = ""
    var oldest_time: int = Time.get_ticks_msec()

    for key in _cache:
        if _cache_access_time[key] < oldest_time:
            oldest_time = _cache_access_time[key]
            oldest_key = key

    _cache.erase(oldest_key)
```

### Texture Loading (DDS & TGA)

**DDS support:**
- ✅ Native VRAM-compressed formats (DXT1, DXT3, DXT5)
- ✅ Direct upload to GPU (no CPU decompression)
- ✅ Mipmap support

**TGA fallback:**
- ⚠️ Uncompressed format (larger VRAM usage)
- ✅ Used when DDS not available

**Loading pattern:**
```gdscript
func load_texture(texture_path: String) -> Texture2D:
    # Try DDS first (faster, smaller VRAM)
    var dds_path := texture_path.replace(".tga", ".dds")
    if FileAccess.file_exists(dds_path):
        return load_dds_texture(dds_path)

    # Fallback to TGA
    if FileAccess.file_exists(texture_path):
        return load_tga_texture(texture_path)

    # Return placeholder if missing
    return _placeholder_texture
```

---

## Async Loading & Streaming

### BackgroundProcessor Pattern

**Core system:** [`src/core/streaming/background_processor.gd`](src/core/streaming/background_processor.gd)

**Submit job:**
```gdscript
var job_id := background_processor.submit_job(func() -> Variant:
    # This runs on worker thread
    var heavy_data = parse_large_file()
    return heavy_data
)

# Store job ID for later polling
_pending_jobs[job_id] = metadata
```

**Poll for completion:**
```gdscript
func _process(delta: float) -> void:
    for job_id in _pending_jobs.keys():
        if background_processor.is_job_complete(job_id):
            var result = background_processor.get_job_result(job_id)
            _on_job_complete(job_id, result)
            _pending_jobs.erase(job_id)
```

**Thread safety:**
```gdscript
# Use Mutex for shared data
var _mutex := Mutex.new()
var _shared_cache: Dictionary = {}

func add_to_cache_threadsafe(key: String, value: Variant) -> void:
    _mutex.lock()
    _shared_cache[key] = value
    _mutex.unlock()
```

### Cell Streaming Architecture

**NativeStreamingManager:** [`src/core/world/native_streaming_manager.gd`](src/core/world/native_streaming_manager.gd)

**Load radius system:**
```gdscript
@export var load_radius_cells: int = 3      # Load 3x3 grid around camera
@export var unload_radius_cells: int = 5    # Unload beyond 5 cells

func _update_loaded_cells() -> void:
    var cells_to_load := _get_cells_in_radius(_camera_cell, load_radius_cells)
    var cells_to_unload := _get_cells_beyond_radius(_camera_cell, unload_radius_cells)

    # Sort by distance (nearest first)
    cells_to_load.sort_custom(_distance_sort)

    # Load with frame budget
    for grid in cells_to_load:
        if grid not in _loaded_cells:
            _load_cell(grid)

            if _frame_budget_exceeded():
                break  # Continue next frame
```

**Distance-sorted priority:**
```gdscript
func _distance_sort(a: Vector2i, b: Vector2i) -> bool:
    var dist_a := a.distance_to(_camera_cell)
    var dist_b := b.distance_to(_camera_cell)
    return dist_a < dist_b  # Closest first
```

### Progressive Loading Pattern

**Load geometry first, details later:**
```gdscript
func _load_object_progressive(ref: CellReference) -> void:
    # Frame 1: Load base mesh (blocking)
    var base_mesh := _load_mesh_sync(ref.model_path)
    var instance := MeshInstance3D.new()
    instance.mesh = base_mesh
    _cell_root.add_child(instance)

    # Frame 2+: Load materials async (non-blocking)
    _load_materials_async(instance, ref.model_path)

    # Frame 3+: Load collision async (non-blocking)
    _load_collision_async(instance, ref.model_path)
```

---

## Rendering & Shaders

### Ocean System (FFT-based)

**Implementation:** [`src/core/water/`](src/core/water/)

**Features:**
- ✅ Compute shader FFT for realistic wave simulation
- ✅ Gerstner waves for surface displacement
- ✅ Buoyancy simulation for objects
- ✅ Underwater rendering (fog, caustics)

**Compute shader (FFT):**
```glsl
// src/core/water/shaders/compute/fft_pass.glsl
#version 450

layout(local_size_x = 16, local_size_y = 16) in;

layout(set = 0, binding = 0, rgba32f) uniform image2D displacement_map;

void main() {
    ivec2 pixel_coords = ivec2(gl_GlobalInvocationID.xy);

    // Perform FFT butterfly operation
    vec4 wave_data = perform_fft_step(pixel_coords);

    imageStore(displacement_map, pixel_coords, wave_data);
}
```

**Surface shader:**
```gdshader
shader_type spatial;

uniform sampler2D displacement_map;
uniform sampler2D normal_map;
uniform float wave_amplitude = 1.0;

void vertex() {
    // Displace vertices based on FFT output
    vec4 displacement = texture(displacement_map, UV);
    VERTEX.y += displacement.y * wave_amplitude;
}

void fragment() {
    // Water material properties
    ALBEDO = vec3(0.02, 0.05, 0.1);  // Deep ocean color
    ROUGHNESS = 0.1;
    METALLIC = 0.0;

    // Normal mapping for wave details
    NORMAL_MAP = texture(normal_map, UV).rgb;
}
```

### Terrain Deformation (RTT-based)

**Implementation:** [`src/core/deformation/`](src/core/deformation/)

**Technique: Render-to-Texture (RTT) stamping**
- Render deformation "stamps" to heightmap texture
- Use texture in terrain shader for displacement
- Supports dynamic recovery (deformation fades over time)

**Deformation shader:**
```gdshader
shader_type spatial;

uniform sampler2D deformation_map;
uniform float deformation_strength = 1.0;

void vertex() {
    // Sample deformation map at vertex position
    vec2 world_uv = (VERTEX.xz - world_origin) / world_size;
    float deformation = texture(deformation_map, world_uv).r;

    // Displace vertex
    VERTEX.y -= deformation * deformation_strength;
}
```

### Selection Outline Shader

**Usage:** Console command selection in world explorer

```gdshader
shader_type spatial;
render_mode unshaded;

uniform vec4 outline_color : source_color = vec4(1.0, 0.5, 0.0, 1.0);
uniform float outline_width = 0.05;

void vertex() {
    // Expand mesh along normals
    VERTEX += NORMAL * outline_width;
}

void fragment() {
    ALBEDO = outline_color.rgb;
}
```

### Impostor Billboard Shader

**Octahedral projection:**
```gdshader
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;

uniform sampler2DArray impostor_textures;
uniform int texture_layer = 0;

void vertex() {
    // Billboard effect - always face camera
    mat4 billboard_mat = mat4(1.0);
    billboard_mat[0].xyz = normalize(CAMERA_MATRIX[0].xyz);
    billboard_mat[1].xyz = normalize(CAMERA_MATRIX[1].xyz);
    billboard_mat[2].xyz = normalize(CAMERA_MATRIX[2].xyz);

    MODELVIEW_MATRIX = CAMERA_MATRIX * billboard_mat;
}

void fragment() {
    // Calculate view direction
    vec3 view_dir = normalize(CAMERA_POSITION_WORLD - VERTEX);

    // Select octahedral layer based on view angle
    int layer = calculate_octahedral_layer(view_dir);

    // Sample from texture array
    vec4 color = texture(impostor_textures, vec3(UV, float(layer)));

    ALBEDO = color.rgb;
    ALPHA = color.a;
}

int calculate_octahedral_layer(vec3 view_dir) {
    // 8 views: +X, -X, +Y, -Y, +Z, -Z, +XZ, -XZ
    vec3 abs_dir = abs(view_dir);

    if (abs_dir.x > abs_dir.y && abs_dir.x > abs_dir.z) {
        return view_dir.x > 0.0 ? 0 : 1;  // +X / -X
    } else if (abs_dir.y > abs_dir.z) {
        return view_dir.y > 0.0 ? 2 : 3;  // +Y / -Y
    } else {
        return view_dir.z > 0.0 ? 4 : 5;  // +Z / -Z
    }
}
```

---

## Animation System

### Architecture (V2 System)

**Modular components:**
- `MorrowindCharacterSystem` - NPC animation
- `CreatureAnimationSystem` - Creature animation
- `AnimationLibrary` - Shared animation storage
- `Skeleton3D` templates - Cached skeletons

**Features:**
- ✅ IK (Inverse Kinematics) for realistic foot placement
- ✅ Procedural animation blending
- ✅ Animation LOD (simplified animations at distance)
- ✅ Retargeting support (share animations between similar skeletons)

### Animation Retargeting (Godot 4.5)

**Setup:**
```gdscript
# Import with retargeting profile
var skeleton := preload("res://characters/nif_skeleton.tscn").instantiate()
var bone_map := BoneMap.new()
bone_map.profile = SkeletonProfileHumanoid.new()

# Auto-mapping for common names
bone_map.auto_map(skeleton)

# Manual mapping for non-standard bones
bone_map.set_skeleton_bone_name("Bip01 Head", "Head")
bone_map.set_skeleton_bone_name("Bip01 L Hand", "LeftHand")
```

**Share animations:**
```gdscript
# Animation from one skeleton works on another with same profile
var shared_anim := animation_library.get_animation("walk")
animation_player.add_animation_library("shared", animation_library)
animation_player.play("shared/walk")
```

### AnimationTree with State Machine

**State machine setup:**
```gdscript
var anim_tree := AnimationTree.new()
var state_machine := AnimationNodeStateMachine.new()

# Add states
var idle_state := AnimationNodeAnimation.new()
idle_state.animation = "idle"
state_machine.add_node("idle", idle_state)

var walk_state := AnimationNodeAnimation.new()
walk_state.animation = "walk"
state_machine.add_node("walk", walk_state)

# Add transitions
state_machine.add_transition("idle", "walk", auto_advance = false)
state_machine.add_transition("walk", "idle", auto_advance = false)

# Set transition conditions
var idle_to_walk := state_machine.get_transition("idle", "walk")
idle_to_walk.xfade_time = 0.2
idle_to_walk.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END

anim_tree.tree_root = state_machine
```

**BlendSpace2D for locomotion:**
```gdscript
# 2D blend space for movement (speed, direction)
var blend_space := AnimationNodeBlendSpace2D.new()

# Add animations at positions
blend_space.add_blend_point(idle_anim, Vector2(0, 0))
blend_space.add_blend_point(walk_forward, Vector2(1, 0))
blend_space.add_blend_point(run_forward, Vector2(2, 0))
blend_space.add_blend_point(walk_left, Vector2(1, -1))
blend_space.add_blend_point(walk_right, Vector2(1, 1))

# Control with velocity
anim_tree.set("parameters/locomotion/blend_position", Vector2(speed, direction))
```

### Animation Caching

**Pattern for shared animations:**
```gdscript
class_name AnimationCache

static var _skeleton_templates: Dictionary = {}
static var _animation_libraries: Dictionary = {}

static func get_skeleton_template(nif_path: String) -> Skeleton3D:
    if _skeleton_templates.has(nif_path):
        return _skeleton_templates[nif_path]

    var skeleton := _parse_skeleton_from_nif(nif_path)
    _skeleton_templates[nif_path] = skeleton
    return skeleton

static func get_animation_library(kf_path: String) -> AnimationLibrary:
    if _animation_libraries.has(kf_path):
        return _animation_libraries[kf_path]

    var library := _parse_animations_from_kf(kf_path)
    _animation_libraries[kf_path] = library
    return library
```

---

## Code Style & Standards

### Naming Conventions

**Classes:**
```gdscript
class_name ESMRecord       # PascalCase
class_name CellManager     # Descriptive nouns
class_name NIFConverter    # Acronyms uppercase
```

**Variables and functions:**
```gdscript
var cell_name: String              # snake_case
var _private_cache: Dictionary     # Leading underscore for private
const MAX_LOAD_DISTANCE: float     # SCREAMING_SNAKE_CASE for constants

func load_cell(grid: Vector2i) -> Node3D:  # snake_case
func _internal_helper() -> void:           # Leading underscore for private
```

**Signals:**
```gdscript
signal cell_loading(grid: Vector2i)
signal cell_loaded(grid: Vector2i, object_count: int)
signal stats_updated(stats: Dictionary)
```

### File Headers

**Every significant class includes:**
```gdscript
## Brief description of what this class does.
##
## Longer description explaining the purpose, architecture, and key concepts.
## Include performance notes for critical systems.
##
## Example usage:
## [codeblock]
## var manager := CellManager.new()
## manager.load_exterior_cell(0, 0)
## [/codeblock]

class_name ClassName extends BaseClass
```

### Error Handling

**Use Godot error reporting:**
```gdscript
# Errors - critical issues that prevent operation
if not FileAccess.file_exists(path):
    push_error("File not found: %s" % path)
    return ERR_FILE_NOT_FOUND

# Warnings - recoverable issues
if cache_size > MAX_CACHE_SIZE:
    push_warning("Cache size exceeded, evicting entries")
    _evict_cache_entries()

# Asserts - debug checks (stripped in release)
assert(instance != null, "Instance should not be null after instantiation")
```

### Comments

**Use comments sparingly - prefer self-documenting code:**

```gdscript
# Good - self-documenting
func calculate_distance_to_camera(object_position: Vector3) -> float:
    return object_position.distance_to(_camera.global_position)

# Bad - unnecessary comment
# Calculate the distance to camera
func calc_dist(pos: Vector3) -> float:
    return pos.distance_to(_camera.global_position)  # Get distance
```

**When to comment:**
- ✅ Explain WHY, not WHAT
- ✅ Non-obvious algorithms or optimizations
- ✅ Workarounds for engine bugs
- ✅ Complex mathematical formulas
- ❌ Don't state the obvious

**Example:**
```gdscript
# GOOD:
# Use hysteresis to prevent LOD flickering when camera is at boundary
geo.visibility_range_end_margin = FADE_MARGIN

# BAD:
# Set visibility range end margin
geo.visibility_range_end_margin = FADE_MARGIN
```

### Signal Connection

**Prefer type-safe connections:**
```gdscript
# Good - typed, autocomplete works
cell_manager.cell_loaded.connect(_on_cell_loaded)

func _on_cell_loaded(grid: Vector2i, object_count: int) -> void:
    print("Cell %v loaded with %d objects" % [grid, object_count])
```

**Avoid string-based connections:**
```gdscript
# Bad - typo-prone, no autocomplete
cell_manager.connect("cell_loaded", _on_cell_loaded)
```

---

## Known Issues & Workarounds

### 1. Claude Code File Modification Bug

**Issue:** File operations fail without absolute Windows paths

**Workaround:**
```gdscript
# Bad - relative paths may fail
var file = FileAccess.open("cache/models/door.res", FileAccess.READ)

# Good - use absolute paths with drive letter
var cache_dir := "d:\\Gamedev\\Godotwind\\godotwind\\cache"
var file = FileAccess.open(cache_dir + "\\models\\door.res", FileAccess.READ)

# Better - use SettingsManager for paths
var cache_dir := SettingsManager.get_cache_dir()  # Returns absolute path
var file = FileAccess.open(cache_dir.path_join("models/door.res"), FileAccess.READ)
```

### 2. C# Cannot Call GDExtensions

**Issue:** [Godot limitation](https://github.com/godotengine/godot-proposals/issues/7895) - C# can't call GDExtension classes directly

**Workaround: GDScript bridge**
```gdscript
# bridge.gd (GDScript)
class_name GDExtensionBridge

static func call_gdextension_method(param: Variant) -> Variant:
    var gdext_obj = GDExtensionClass.new()
    return gdext_obj.method(param)
```

```csharp
// C# code calls bridge
var bridge = GD.Load<GDScript>("res://bridge.gd");
var result = bridge.Call("call_gdextension_method", param);
```

**Performance:** Small overhead (~5-10% slower than direct call)

### 3. Occlusion Culling Angle Bug (Godot 4.5.dev3)

**Issue:** [GitHub #106184](https://github.com/godotengine/godot/issues/106184) - Occlusion culling only works from certain angles

**Workaround:** Disable occlusion culling for outdoor scenes, enable for interiors only

```gdscript
func setup_occlusion(is_interior: bool) -> void:
    if is_interior:
        get_viewport().use_occlusion_culling = true
    else:
        get_viewport().use_occlusion_culling = false  # Outdoor scenes buggy
```

### 4. Automatic LOD Quality Issues

**Issue:** [GitHub proposal #3861](https://github.com/godotengine/godot-proposals/issues/3861) - Godot's automatic LOD generation degrades quality at high simplification

**Workaround:** Use preprocessed LOD meshes (current approach)

```gdscript
# Preprocessed LODs in cache
var lod0 = load("res://cache/models/door_LOD0.res")  # 100% quality
var lod1 = load("res://cache/models/door_LOD1.res")  # 75% triangles
var lod2 = load("res://cache/models/door_LOD2.res")  # 50% triangles
var lod3 = load("res://cache/models/door_LOD3.res")  # 25% triangles
```

### 5. Impostor Texture Path Resolution (Current Bug)

**Issue:** See [`docs/DISTANCE_RENDERING_AUDIT.md`](docs/DISTANCE_RENDERING_AUDIT.md#problem-1-impostors-not-rendering)

**Fix in progress:**
```gdscript
# Use SettingsManager for full path
var impostor_path := SettingsManager.get_cache_dir().path_join("impostors/%s.png" % model_hash)
if FileAccess.file_exists(impostor_path):
    var texture := load(impostor_path)
```

---

## Resources & Documentation

### Official Godot 4.5 Docs

**Rendering:**
- [Mesh LOD](https://docs.godotengine.org/en/stable/tutorials/3d/mesh_lod.html) - Official LOD documentation
- [Occlusion Culling](https://docs.godotengine.org/en/stable/tutorials/3d/occlusion_culling.html) - Occlusion system
- [Renderers Overview](https://docs.godotengine.org/en/stable/tutorials/rendering/renderers.html) - Forward+, Mobile, Compatibility

**Animation:**
- [Animation Retargeting](https://godotengine.org/article/animation-retargeting-in-godot-4-0/) - Official retargeting guide
- [Retargeting 3D Skeletons](https://docs.godotengine.org/en/stable/tutorials/assets_pipeline/retargeting_3d_skeletons.html) - Setup tutorial
- [AnimationTree](https://godotengine.org/article/godot-gets-new-animation-tree-state-machine/) - State machine guide

**Threading:**
- [GDExtension System](https://docs.godotengine.org/en/stable/tutorials/scripting/gdextension/index.html) - Native extensions

### Godot 4.5 Release Info

- [Godot 4.5 Release](https://news.itsfoss.com/godot-4-5-release/) - Feature overview
- [What's New in Godot 4.5](https://www.creativebloq.com/3d/video-game-design/whats-new-in-godot-4-5-everything-you-need-to-know) - Comprehensive changelog
- [Interactive Changelog](https://godotengine.github.io/godot-interactive-changelog/) - Official interactive changelog

### Community Resources

**Impostors:**
- [Godot-Octahedral-Impostors](https://github.com/wojtekpil/Godot-Octahedral-Impostors) - Community impostor plugin
- [Grass Rendering LOD Tricks](https://hexaquo.at/pages/grass-rendering-series-part-4-level-of-detail-tricks-for-infinite-plains-of-grass-in-godot/) - Advanced LOD techniques

**C# vs GDScript:**
- [GDScript vs C# in Godot 4](https://chickensoft.games/blog/gdscript-vs-csharp) - Performance comparison

**Proposals & Issues:**
- [Mesh LOD Issues Tracker](https://github.com/godotengine/godot/issues/57416) - Known LOD bugs
- [Custom LOD Meshes Proposal](https://github.com/godotengine/godot-proposals/issues/5174) - Feature request
- [C# GDExtension Roadmap](https://github.com/godotengine/godot-proposals/issues/7895) - Future C#/GDExtension integration

### Project-Specific Docs

- [`docs/DISTANCE_RENDERING_AUDIT.md`](docs/DISTANCE_RENDERING_AUDIT.md) - Current implementation status
- [`docs/IMPLEMENTATION_SUMMARY.md`](docs/IMPLEMENTATION_SUMMARY.md) - Feature completion tracking

---

## Quick Reference

### Distance Tier Cheat Sheet

```gdscript
# Import for all distance constants
const DistanceUtils = preload("res://src/core/world/distance_utils.gd")

# Tier boundaries
0-150m:   NEAR tier  (full meshes)
150-500m: MID tier   (LOD1: 150-250m, LOD2: 250-375m, LOD3: 375-500m)
500-5km:  FAR tier   (impostors)
```

### Common Godot 4.5 API Patterns

**visibility_range:**
```gdscript
geo.visibility_range_begin = 0.0
geo.visibility_range_end = 150.0
geo.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
geo.visibility_range_end_margin = 50.0  # Hysteresis
```

**Async resource loading:**
```gdscript
ResourceLoader.load_threaded_request(path)
# Poll until ready
if ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_LOADED:
    var resource = ResourceLoader.load_threaded_get(path)
```

**Worker threads:**
```gdscript
WorkerThreadPool.add_task(func():
    var result = heavy_computation()
    call_deferred("_on_result_ready", result)
)
```

**MultiMesh batching:**
```gdscript
var multimesh := MultiMesh.new()
multimesh.mesh = base_mesh
multimesh.instance_count = count
for i in count:
    multimesh.set_instance_transform(i, transforms[i])
```

---

## Final Notes

**This is a living document.** Update as:
- ✅ New Godot 4.x features are released
- ✅ Implementation status changes (track in `docs/`)
- ✅ New patterns or optimizations are discovered
- ✅ Known issues are resolved

**For new agents working on this project:**
1. Read [`docs/DISTANCE_RENDERING_AUDIT.md`](docs/DISTANCE_RENDERING_AUDIT.md) for current status
2. Check git history for recent changes
3. Run `world_explorer.gd` to see the system in action
4. Profile before optimizing (use Godot's built-in profiler)

**Key Principle:** Use Godot's native features whenever possible (visibility_range, MultiMesh, WorkerThreadPool) before implementing custom systems. Godot 4.5 is highly capable - leverage it.

---

**Last Updated:** 2026-01-08
**Maintained By:** Development team
**Questions?** See project documentation in `docs/`
