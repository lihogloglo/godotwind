# LOD and Optimization Systems

## Overview

The LOD (Level of Detail) and optimization systems are critical for maintaining 60 FPS in a massive open world. Godotwind uses a sophisticated 4-level LOD system with RenderingServer billboards, object pooling, material deduplication, and time-budgeted operations to achieve production-quality performance.

---

## Status Audit

### ✅ Completed
- 4-level LOD system (FULL → LOW → BILLBOARD → CULLED)
- RenderingServer billboard rendering (zero scene tree overhead)
- ObjectPool with per-model pools
- Object pool pre-warming
- Material library deduplication
- Time-budgeted cell loading
- Performance profiler with bottleneck detection
- Distance-based culling
- Size-based LOD threshold scaling
- Cache hit rate tracking

### ⚠️ In Progress
- GPU instancing (MultiMeshInstance3D prepared but not active)
- Occlusion culling (Godot supports it but not tuned)
- Terrain LOD tuning (Terrain3D has built-in LOD)

### ❌ Not Started
- Impostor generation (billboards use textures, not rendered impostors)
- Shader LOD (different shader complexity per distance)
- Animation LOD (reduce animation updates for distant NPCs)
- Audio LOD (reduce sound quality/channels for distant sources)

---

## Architecture

### LOD Pipeline

```
ObjectLODManager._process(delta)
         │
         ├─ Update every 100ms (not every frame)
         ├─ Get camera position
         │
         ▼
   For each registered object:
         │
         ├─ Calculate distance from camera
         ├─ Determine LOD level based on distance + size
         │
         ▼
   ┌──────────┬──────────┬──────────┬──────────┐
   │   FULL   │   LOW    │ BILLBOARD│  CULLED  │
   │  0-50m   │ 50-150m  │ 150-500m │  500m+   │
   ├──────────┼──────────┼──────────┼──────────┤
   │ Original │ Simplified│   2D     │ Hidden   │
   │ geometry │  mesh    │ impostor │          │
   │ Shadows  │ No shadow│RenderSrv │          │
   └──────────┴──────────┴──────────┴──────────┘
```

---

## Key Files

| File | Path | Purpose |
|------|------|---------|
| **ObjectLODManager** | [src/core/world/object_lod_manager.gd](../src/core/world/object_lod_manager.gd) | LOD distance management |
| **ObjectPool** | [src/core/world/object_pool.gd](../src/core/world/object_pool.gd) | Node3D instance pooling |
| **StaticObjectRenderer** | [src/core/world/static_object_renderer.gd](../src/core/world/static_object_renderer.gd) | RenderingServer rendering |
| **MaterialLibrary** | [src/core/texture/material_library.gd](../src/core/texture/material_library.gd) | Material deduplication |
| **PerformanceProfiler** | [src/core/world/performance_profiler.gd](../src/core/world/performance_profiler.gd) | Performance tracking |

---

## 4-Level LOD System

### LOD Levels

| Level | Distance | Geometry | Shadows | Physics | Rendering |
|-------|----------|----------|---------|---------|-----------|
| **FULL** | 0-50m | Original NIF | Cast + Receive | Full collision | Scene tree |
| **LOW** | 50-150m | Simplified | None | Simplified | Scene tree |
| **BILLBOARD** | 150-500m | 2D quad | None | None | RenderingServer |
| **CULLED** | 500m+ | None | None | None | Hidden |

### Distance Thresholds

```gdscript
# ObjectLODManager
const DISTANCE_FULL := 50.0       # 0-50m: Full detail
const DISTANCE_LOW := 150.0       # 50-150m: Low detail
const DISTANCE_BILLBOARD := 500.0  # 150-500m: Billboard
# 500m+: Culled

# Size scaling factor
const SIZE_FACTOR := 0.5  # Small objects cull sooner
```

### Size-Based Scaling

Small objects (barrels, bottles) cull sooner than large objects (buildings):

```gdscript
func _calculate_lod_distance(base_distance: float, object_size: float) -> float:
    var size_multiplier := clamp(object_size / 5.0, 0.2, 2.0)
    return base_distance * size_multiplier

# Example:
# Barrel (size 1m): FULL = 50 * 0.2 = 10m, BILLBOARD = 500 * 0.2 = 100m
# Building (size 20m): FULL = 50 * 2.0 = 100m, BILLBOARD = 500 * 2.0 = 1000m
```

---

## ObjectLODManager

### Core Implementation

```gdscript
class_name ObjectLODManager

enum LODLevel { FULL, LOW, BILLBOARD, CULLED }

var _registered_objects: Dictionary = {}  # Node3D -> LODEntry
var _update_timer := 0.0
var _update_interval := 0.1  # 100ms

class LODEntry:
    var object: Node3D
    var current_lod: LODLevel = LODLevel.FULL
    var size: float = 1.0
    var billboard_rid: RID  # For RenderingServer billboards

func _process(delta: float) -> void:
    _update_timer += delta
    if _update_timer < _update_interval:
        return

    _update_timer = 0.0
    _update_all_lods()

func _update_all_lods() -> void:
    var camera_pos := _get_camera_position()

    for entry in _registered_objects.values():
        var distance := camera_pos.distance_to(entry.object.global_position)
        var new_lod := _determine_lod(distance, entry.size)

        if new_lod != entry.current_lod:
            _transition_lod(entry, entry.current_lod, new_lod)
            entry.current_lod = new_lod

func _determine_lod(distance: float, size: float) -> LODLevel:
    var dist_full := _calculate_lod_distance(DISTANCE_FULL, size)
    var dist_low := _calculate_lod_distance(DISTANCE_LOW, size)
    var dist_billboard := _calculate_lod_distance(DISTANCE_BILLBOARD, size)

    if distance < dist_full:
        return LODLevel.FULL
    elif distance < dist_low:
        return LODLevel.LOW
    elif distance < dist_billboard:
        return LODLevel.BILLBOARD
    else:
        return LODLevel.CULLED
```

### LOD Transitions

```gdscript
func _transition_lod(entry: LODEntry, from: LODLevel, to: LODLevel) -> void:
    match to:
        LODLevel.FULL:
            _set_full_detail(entry)
        LODLevel.LOW:
            _set_low_detail(entry)
        LODLevel.BILLBOARD:
            _set_billboard(entry)
        LODLevel.CULLED:
            _set_culled(entry)

func _set_full_detail(entry: LODEntry) -> void:
    entry.object.visible = true
    entry.object.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

    # Enable collision
    for child in entry.object.get_children():
        if child is CollisionShape3D or child is CollisionPolygon3D:
            child.disabled = false

    # Destroy billboard if it exists
    if entry.billboard_rid.is_valid():
        RenderingServer.free_rid(entry.billboard_rid)
        entry.billboard_rid = RID()

func _set_low_detail(entry: LODEntry) -> void:
    entry.object.visible = true
    entry.object.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

    # Disable collision
    for child in entry.object.get_children():
        if child is CollisionShape3D or child is CollisionPolygon3D:
            child.disabled = true

func _set_billboard(entry: LODEntry) -> void:
    # Hide scene tree object
    entry.object.visible = false

    # Create RenderingServer billboard
    entry.billboard_rid = _create_billboard(entry.object)

func _set_culled(entry: LODEntry) -> void:
    entry.object.visible = false

    if entry.billboard_rid.is_valid():
        RenderingServer.free_rid(entry.billboard_rid)
        entry.billboard_rid = RID()
```

---

## RenderingServer Billboards

### Why RenderingServer?

**Scene Tree Approach (Slow):**
```gdscript
var sprite := Sprite3D.new()  # Creates Node, adds to tree
sprite.billboard = true
add_child(sprite)  # Triggers re-parenting, signals, etc.
```

**RenderingServer Approach (Fast):**
```gdscript
var instance := RenderingServer.instance_create()  # Direct GPU command
RenderingServer.instance_set_base(instance, mesh_rid)
RenderingServer.instance_set_scenario(instance, scenario)
# No scene tree overhead!
```

### Billboard Creation

```gdscript
func _create_billboard(object: Node3D) -> RID:
    # Create quad mesh
    var mesh := _create_billboard_mesh(object)
    var mesh_rid := mesh.get_rid()

    # Create material with texture
    var material := _get_billboard_material(object)
    var material_rid := material.get_rid()

    # Create instance
    var instance := RenderingServer.instance_create()
    RenderingServer.instance_set_base(instance, mesh_rid)
    RenderingServer.instance_set_scenario(instance, get_world_3d().scenario)

    # Set transform
    var transform := Transform3D()
    transform.origin = object.global_position
    RenderingServer.instance_set_transform(instance, transform)

    # Enable billboard mode
    RenderingServer.instance_geometry_set_flag(
        instance,
        RenderingServer.INSTANCE_FLAG_USE_BAKED_LIGHT,
        false
    )

    return instance

func _create_billboard_mesh(object: Node3D) -> QuadMesh:
    var size := _estimate_object_size(object)
    var mesh := QuadMesh.new()
    mesh.size = Vector2(size, size)
    return mesh

func _get_billboard_material(object: Node3D) -> StandardMaterial3D:
    # Extract texture from object's material
    var texture := _extract_albedo_texture(object)

    var mat := StandardMaterial3D.new()
    mat.albedo_texture = texture
    mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
    return mat
```

---

## Object Pooling

### Why Pool?

**Without Pooling:**
```gdscript
# Creating 1000 kelp plants
for i in range(1000):
    var kelp := load("res://models/kelp.tscn").instantiate()  # Slow!
    add_child(kelp)
# Result: 1000 allocations, GC pressure, frame hitches
```

**With Pooling:**
```gdscript
# Pre-warm pool
object_pool.pre_warm("res://models/kelp.tscn", 100)

# Acquire from pool (instant!)
for i in range(1000):
    var kelp := object_pool.acquire("res://models/kelp.tscn")  # Fast!
    add_child(kelp)

# When cell unloads, release back to pool
for kelp in cell.get_children():
    object_pool.release(kelp)
# Result: 100 allocations (reused 10x), minimal GC, smooth FPS
```

### ObjectPool Implementation

```gdscript
class_name ObjectPool

var _pools: Dictionary = {}  # model_path -> PoolEntry
var _global_cap := 5000  # Max total instances across all pools

class PoolEntry:
    var prototype: Node3D
    var available: Array[Node3D] = []
    var in_use: int = 0
    var hits: int = 0
    var misses: int = 0
    var max_size: int = 100

func pre_warm(model_path: String, count: int) -> void:
    if not _pools.has(model_path):
        var prototype := _load_model(model_path)
        _pools[model_path] = PoolEntry.new()
        _pools[model_path].prototype = prototype

    var pool: PoolEntry = _pools[model_path]
    for i in range(count):
        var instance := pool.prototype.duplicate()
        pool.available.append(instance)

func acquire(model_path: String) -> Node3D:
    if not _pools.has(model_path):
        pre_warm(model_path, 10)  # Auto-create small pool

    var pool: PoolEntry = _pools[model_path]

    if pool.available.size() > 0:
        pool.hits += 1
        pool.in_use += 1
        return pool.available.pop_back()
    else:
        pool.misses += 1
        pool.in_use += 1
        return pool.prototype.duplicate()  # Fallback

func release(object: Node3D) -> void:
    var model_path := _get_model_path(object)
    if not _pools.has(model_path):
        object.queue_free()
        return

    var pool: PoolEntry = _pools[model_path]
    pool.in_use -= 1

    # Return to pool if under cap
    if pool.available.size() < pool.max_size:
        object.get_parent().remove_child(object)
        pool.available.append(object)
    else:
        object.queue_free()  # Pool full, discard

func release_all(objects: Array[Node3D]) -> void:
    for obj in objects:
        release(obj)

func get_hit_rate(model_path: String) -> float:
    if not _pools.has(model_path):
        return 0.0

    var pool: PoolEntry = _pools[model_path]
    var total := pool.hits + pool.misses
    if total == 0:
        return 0.0

    return float(pool.hits) / float(total)
```

### Common Pooled Objects

Based on frequency analysis of Morrowind data:

```gdscript
# Pre-warm common objects
func _pre_warm_common_objects() -> void:
    object_pool.pre_warm("flora_kelp_01.nif", 100)      # Underwater plant (very common)
    object_pool.pre_warm("flora_kelp_02.nif", 100)
    object_pool.pre_warm("flora_kelp_03.nif", 80)
    object_pool.pre_warm("flora_kelp_04.nif", 80)

    object_pool.pre_warm("flora_bc_grass_01.nif", 100)  # Grass (extremely common)
    object_pool.pre_warm("flora_bc_grass_02.nif", 100)

    object_pool.pre_warm("terrain_rock_rm_01.nif", 80)  # Rocks
    object_pool.pre_warm("terrain_rock_rm_02.nif", 80)
    object_pool.pre_warm("terrain_rock_rm_03.nif", 60)

    object_pool.pre_warm("flora_tree_ai_01.nif", 30)    # Trees
    object_pool.pre_warm("flora_tree_bc_01.nif", 30)

    object_pool.pre_warm("ex_common_plat_01.nif", 40)   # Architecture
    object_pool.pre_warm("ex_common_pillar_01.nif", 40)
```

---

## Material Deduplication

### Problem

Each NIF model creates a new `StandardMaterial3D`, even if textures are identical:

```gdscript
# Without deduplication:
# 1000 kelp plants = 1000 materials (all identical!)
# VRAM waste: 1000 × material overhead
```

### Solution: Material Library

```gdscript
class_name MaterialLibrary

var _materials: Dictionary = {}  # hash -> StandardMaterial3D

func get_or_create_material(albedo_texture: Texture2D, normal_texture: Texture2D = null) -> StandardMaterial3D:
    var hash := _calculate_hash(albedo_texture, normal_texture)

    if _materials.has(hash):
        return _materials[hash]  # Reuse!

    var mat := StandardMaterial3D.new()
    mat.albedo_texture = albedo_texture
    mat.normal_texture = normal_texture
    mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
    # ... other settings ...

    _materials[hash] = mat
    return mat

func _calculate_hash(albedo: Texture2D, normal: Texture2D) -> int:
    var hash := 0
    if albedo:
        hash ^= albedo.get_rid().get_id()
    if normal:
        hash ^= normal.get_rid().get_id() << 16
    return hash
```

**Result:** 1000 kelp plants = 1 material (shared)

---

## Time-Budgeted Loading

### Problem

Loading a cell with 100 objects can take 50-100ms, causing visible frame hitches.

### Solution: Spread Over Multiple Frames

```gdscript
func _process_load_queue(budget_ms: float) -> void:
    var start_time := Time.get_ticks_usec()
    var budget_us := budget_ms * 1000.0

    while _load_queue.size() > 0:
        var elapsed_us := Time.get_ticks_usec() - start_time
        if elapsed_us >= budget_us:
            break  # Out of time, continue next frame

        _load_next_cell()

# Example:
# Cell with 100 objects, budget = 8ms/frame
# Frame 1: Load 15 objects (8ms) → queue 85 remaining
# Frame 2: Load 15 objects (8ms) → queue 70 remaining
# ...
# Frame 7: Load 10 objects (8ms) → queue 0 (done!)
# Result: No frame hitch, smooth 60 FPS
```

---

## Performance Profiler

### Usage

```gdscript
# PerformanceProfiler
var profiler := PerformanceProfiler.new()

func _process(delta: float) -> void:
    profiler.start_section("cell_loading")
    _process_load_queue(8.0)
    profiler.end_section("cell_loading")

    profiler.start_section("lod_update")
    object_lod_manager.update_lods(camera.position)
    profiler.end_section("lod_update")

    profiler.record_frame(delta)

# Print stats
func _on_debug_key_pressed() -> void:
    print("=== Performance Stats ===")
    print("FPS: %.1f" % profiler.get_fps())
    print("Avg Frame: %.2fms" % profiler.get_average_frame_time())
    print("Worst Frame: %.2fms" % profiler.get_worst_frame_time())
    print("Cell Loading: %.2fms" % profiler.get_section_time("cell_loading"))
    print("LOD Update: %.2fms" % profiler.get_section_time("lod_update"))
```

### Bottleneck Detection

```gdscript
func _detect_bottlenecks() -> Array[String]:
    var bottlenecks := []

    for section in profiler.get_sections():
        var time := profiler.get_section_time(section)
        if time > 5.0:  # More than 5ms
            bottlenecks.append("%s: %.2fms" % [section, time])

    return bottlenecks

# Output:
# ["cell_loading: 12.3ms", "nif_conversion: 8.7ms"]
```

---

## GPU Instancing (Future)

### Why Not Active Yet?

GPU instancing requires **identical meshes**, but Morrowind objects have varying positions, rotations, and scales. We need to:
1. Group objects by model type
2. Create MultiMeshInstance3D for each group
3. Upload transforms as instance data

### Planned Implementation

```gdscript
var _multi_meshes: Dictionary = {}  # model_path -> MultiMeshInstance3D

func _create_instanced_objects(cell: CellRecord) -> void:
    # Group by model
    var groups := {}
    for ref in cell.references:
        var model := ESMManager.statics[ref.base_object_id].model
        if not groups.has(model):
            groups[model] = []
        groups[model].append(ref)

    # Create MultiMesh for groups > 10 instances
    for model in groups.keys():
        if groups[model].size() > 10:
            _create_multi_mesh(model, groups[model])

func _create_multi_mesh(model: String, refs: Array) -> void:
    var multi_mesh := MultiMesh.new()
    multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
    multi_mesh.instance_count = refs.size()
    multi_mesh.mesh = _load_mesh(model)

    for i in range(refs.size()):
        var ref: CellReference = refs[i]
        var transform := Transform3D()
        transform.origin = CoordinateSystem.convert_position(ref.position)
        # ... rotation, scale ...
        multi_mesh.set_instance_transform(i, transform)

    var instance := MultiMeshInstance3D.new()
    instance.multimesh = multi_mesh
    add_child(instance)

# Expected performance gain:
# Grass: 5000 instances → 1 draw call (vs 5000 draw calls)
# Rocks: 1000 instances → 1 draw call (vs 1000 draw calls)
```

---

## Best Practices

### 1. Always Use Object Pooling
For any model that appears > 50 times in the world:

```gdscript
if _count_occurrences(model) > 50:
    object_pool.pre_warm(model, 50)
```

### 2. Update LOD Infrequently
100ms (10 FPS) is enough for LOD updates:

```gdscript
@export var lod_update_interval := 0.1  # Not every frame!
```

### 3. Use Size-Based Scaling
Small objects should cull sooner:

```gdscript
var size := _estimate_object_size(obj)
var lod_distance := BASE_DISTANCE * clamp(size / 5.0, 0.2, 2.0)
```

### 4. Profile Before Optimizing
Don't guess bottlenecks, measure them:

```gdscript
profiler.start_section("suspect_code")
# ... code ...
profiler.end_section("suspect_code")
print(profiler.get_section_time("suspect_code"))
```

### 5. Use RenderingServer for Static Objects
Visual-only objects (no interaction) don't need scene tree:

```gdscript
if not object.has_physics and not object.has_script:
    _render_with_rendering_server(object)
```

---

## Debugging

### LOD Stats Overlay

```gdscript
func _draw_lod_stats() -> void:
    var counts := {
        LODLevel.FULL: 0,
        LODLevel.LOW: 0,
        LODLevel.BILLBOARD: 0,
        LODLevel.CULLED: 0
    }

    for entry in _registered_objects.values():
        counts[entry.current_lod] += 1

    print("FULL: %d | LOW: %d | BILLBOARD: %d | CULLED: %d" % [
        counts[LODLevel.FULL],
        counts[LODLevel.LOW],
        counts[LODLevel.BILLBOARD],
        counts[LODLevel.CULLED]
    ])
```

### Pool Hit Rate

```gdscript
func _print_pool_stats() -> void:
    for model_path in object_pool._pools.keys():
        var hit_rate := object_pool.get_hit_rate(model_path)
        if hit_rate < 0.8:  # Less than 80%
            print("Low hit rate for %s: %.1f%%" % [model_path, hit_rate * 100])
```

---

## Common Issues

### Issue: Frame Hitches When Loading Cells
**Solution:** Reduce `load_budget_ms` or increase pool sizes

### Issue: Objects Pop In Suddenly
**Solution:** Increase LOD distances or reduce update interval

### Issue: Memory Usage Climbing
**Solution:** Reduce pool `max_size` or enable `global_cap`

### Issue: Draw Calls Too High
**Solution:** Implement GPU instancing for common objects

---

## Task Tracker

- [x] 4-level LOD system
- [x] RenderingServer billboards
- [x] Object pooling
- [x] Material deduplication
- [x] Time-budgeted loading
- [x] Performance profiler
- [x] Size-based LOD scaling
- [x] Hit rate tracking
- [ ] GPU instancing (MultiMesh)
- [ ] Occlusion culling tuning
- [ ] Impostor generation
- [ ] Shader LOD
- [ ] Animation LOD
- [ ] Audio LOD

---

**See Also:**
- [02_WORLD_STREAMING.md](02_WORLD_STREAMING.md) - Integration with streaming system
- [06_NIF_SYSTEM.md](06_NIF_SYSTEM.md) - Model loading and conversion
- [10_DEVELOPMENT_STATUS.md](10_DEVELOPMENT_STATUS.md) - Overall roadmap
