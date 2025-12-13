# World Streaming System

## Overview

The world streaming system is the **heart of Godotwind**, enabling seamless exploration of large open worlds without loading screens. It coordinates terrain generation, object loading/unloading, LOD management, and pooling to maintain smooth 60 FPS even with massive view distances.

---

## Status Audit

### ✅ Completed
- Unified streaming coordinator (WorldStreamingManager)
- Time-budgeted async cell loading
- Priority queue based on distance
- Cell loading/unloading lifecycle
- Integration with Terrain3D and OWDB
- Both single-terrain and multi-terrain modes
- Configurable performance budgets
- Debug stats overlay

### ⚠️ In Progress
- Water streaming (no water rendering yet)
- Interior cell transitions (doors exist but not functional)
- Pre-loading neighboring cells (currently reactive, not predictive)

### ❌ Not Started
- Network synchronization (OWDB supports it but not implemented)
- Procedural content generation (framework ready but not active)
- Save/load integration (SaveSystem plugin not wired up)

---

## Architecture

### Component Hierarchy

```
WorldStreamingManager (Autoload)
├─ TerrainManager / MultiTerrainManager
│  └─ Terrain3D instances (heightmaps, textures)
│
├─ CellManager
│  ├─ ESMManager (data source)
│  ├─ NIFConverter (model loading)
│  ├─ ObjectPool (instance reuse)
│  └─ Cell nodes (container for objects)
│
├─ ObjectLODManager
│  └─ RenderingServer (billboard rendering)
│
└─ PerformanceProfiler
   └─ Frame timing statistics
```

---

## Key Files

| File | Path | Purpose |
|------|------|---------|
| **WorldStreamingManager** | [src/core/world/world_streaming_manager.gd](../src/core/world/world_streaming_manager.gd) | Main coordinator |
| **CellManager** | [src/core/world/cell_manager.gd](../src/core/world/cell_manager.gd) | Cell loading logic |
| **TerrainManager** | [src/core/world/terrain_manager.gd](../src/core/world/terrain_manager.gd) | Single-terrain mode |
| **MultiTerrainManager** | [src/core/world/multi_terrain_manager.gd](../src/core/world/multi_terrain_manager.gd) | Multi-terrain infinite world |
| **PerformanceProfiler** | [src/core/world/performance_profiler.gd](../src/core/world/performance_profiler.gd) | Performance tracking |

---

## WorldStreamingManager

### Responsibilities
1. Track camera position and determine visible cells
2. Maintain priority queue of cells to load
3. Time-budget cell loading operations
4. Unload distant cells
5. Coordinate terrain and object streaming
6. Update LOD system each frame

### Configuration

```gdscript
# View distance in cells (radius around camera)
@export var view_distance: int = 3  # 3 cells = ~351m radius

# Max cells in load queue
@export var max_queue_size: int = 16

# Time budget per frame for loading (milliseconds)
@export var load_budget_ms: float = 8.0

# Update interval for LOD system (seconds)
@export var lod_update_interval: float = 0.1

# Terrain mode
enum TerrainMode { SINGLE, MULTI }
@export var terrain_mode: TerrainMode = TerrainMode.MULTI
```

### Core Loop

```gdscript
func _process(delta: float) -> void:
    if not is_streaming_enabled:
        return

    # Get current camera cell
    var camera_cell := _world_to_cell(camera.global_position)

    # Calculate visible cells
    var visible_cells := _get_cells_in_radius(camera_cell, view_distance)

    # Queue cells that need loading
    for cell in visible_cells:
        if not _is_cell_loaded(cell) and not _is_cell_loading(cell):
            _queue_cell_load(cell)

    # Unload distant cells
    for loaded_cell in _loaded_cells.keys():
        if not visible_cells.has(loaded_cell):
            _unload_cell(loaded_cell)

    # Process load queue (time-budgeted)
    _process_load_queue(load_budget_ms)

    # Update LOD (throttled)
    _lod_timer += delta
    if _lod_timer >= lod_update_interval:
        object_lod_manager.update_lods(camera.global_position)
        _lod_timer = 0.0
```

---

## Cell Loading Pipeline

### 1. Queue Entry

```gdscript
func _queue_cell_load(cell: Vector2i) -> void:
    var priority := _calculate_priority(cell)
    var entry := {
        "cell": cell,
        "priority": priority,
        "timestamp": Time.get_ticks_msec()
    }
    _load_queue.append(entry)
    _load_queue.sort_custom(_sort_by_priority)
    _loading_cells[cell] = true
```

### 2. Priority Calculation

Uses **Manhattan distance** from camera cell (faster than Euclidean):

```gdscript
func _calculate_priority(cell: Vector2i) -> int:
    var camera_cell := _current_camera_cell
    var distance := abs(cell.x - camera_cell.x) + abs(cell.y - camera_cell.y)
    return -distance  # Negative so closer = higher priority
```

### 3. Time-Budgeted Processing

```gdscript
func _process_load_queue(budget_ms: float) -> void:
    var start_time := Time.get_ticks_usec()
    var budget_us := budget_ms * 1000.0

    while _load_queue.size() > 0:
        var elapsed_us := Time.get_ticks_usec() - start_time
        if elapsed_us >= budget_us:
            break  # Out of time, continue next frame

        var entry := _load_queue.pop_front()
        var cell: Vector2i = entry["cell"]

        # Load terrain
        if terrain_mode == TerrainMode.SINGLE:
            terrain_manager.load_cell_terrain(cell)
        else:
            multi_terrain_manager.load_chunk(cell)

        # Load objects
        var cell_node := cell_manager.load_cell(cell)
        _loaded_cells[cell] = cell_node
        _loading_cells.erase(cell)

        # Register objects with LOD manager
        for obj in cell_node.get_children():
            object_lod_manager.register_object(obj)
```

### 4. Cell Unloading

```gdscript
func _unload_cell(cell: Vector2i) -> void:
    if not _loaded_cells.has(cell):
        return

    var cell_node: Node3D = _loaded_cells[cell]

    # Unregister objects from LOD
    for obj in cell_node.get_children():
        object_lod_manager.unregister_object(obj)

    # Return pooled objects
    cell_manager.unload_cell(cell_node)

    # Unload terrain chunk (multi-terrain mode only)
    if terrain_mode == TerrainMode.MULTI:
        multi_terrain_manager.unload_chunk(cell)

    _loaded_cells.erase(cell)
    emit_signal("cell_unloaded", cell)
```

---

## CellManager

### Responsibilities
- Load cell data from ESMManager
- Instantiate objects from NIF models
- Apply transformations (position, rotation, scale)
- Use ObjectPool for frequent models
- Create collision shapes
- Parent objects to cell container node

### Cell Loading

```gdscript
func load_cell(cell: Vector2i) -> Node3D:
    var cell_key := "%d,%d" % [cell.x, cell.y]
    var cell_record: CellRecord = ESMManager.exterior_cells.get(cell_key)

    if not cell_record:
        return _create_empty_cell(cell)

    var cell_node := Node3D.new()
    cell_node.name = "Cell_%d_%d" % [cell.x, cell.y]

    # Load each object reference
    for ref in cell_record.references:
        var obj := _create_object_from_reference(ref)
        if obj:
            cell_node.add_child(obj)

    add_child(cell_node)
    return cell_node

func _create_object_from_reference(ref: CellReference) -> Node3D:
    var static_record := ESMManager.statics.get(ref.base_object_id)
    if not static_record:
        return null

    var model_path := static_record.model
    var obj: Node3D

    # Try to acquire from pool
    if object_pool.has_pool(model_path):
        obj = object_pool.acquire(model_path)
    else:
        obj = _load_model(model_path)  # NIFConverter

    # Apply transformations
    obj.position = CoordinateSystem.convert_position(ref.position)
    obj.rotation = CoordinateSystem.convert_rotation(ref.rotation)
    obj.scale = ref.scale

    return obj
```

### Model Caching

```gdscript
var _model_cache: Dictionary = {}  # model_path -> Node3D prototype

func _load_model(path: String) -> Node3D:
    if _model_cache.has(path):
        return _model_cache[path].duplicate()

    var nif_data := BSAManager.get_file(path)
    if not nif_data:
        return _create_placeholder()

    var converter := NIFConverter.new()
    var model := converter.convert(nif_data, path)
    _model_cache[path] = model
    return model.duplicate()
```

---

## Terrain Integration

### Single-Terrain Mode

Uses one Terrain3D instance for entire world (limited to 32×32 cells = ~3.7km²):

```gdscript
# TerrainManager
func load_cell_terrain(cell: Vector2i) -> void:
    var land_record := ESMManager.lands.get("%d,%d" % [cell.x, cell.y])
    if not land_record:
        return

    var region_index := _cell_to_region(cell)

    # Convert heightmap
    var heights := _convert_heightmap(land_record.height_data)
    terrain.set_region_heights(region_index, heights)

    # Convert textures
    var control := _convert_control_map(land_record.texture_indices)
    terrain.set_region_control(region_index, control)

    # Convert vertex colors
    var colors := _convert_color_map(land_record.vertex_colors)
    terrain.set_region_color(region_index, colors)
```

### Multi-Terrain Mode

Creates Terrain3D instances on-demand for infinite worlds:

```gdscript
# MultiTerrainManager
var _active_chunks: Dictionary = {}  # Vector2i -> Terrain3D

func load_chunk(cell: Vector2i) -> void:
    var chunk_coord := _cell_to_chunk(cell)  # e.g., 8x8 cells per chunk

    if _active_chunks.has(chunk_coord):
        return  # Already loaded

    var terrain := Terrain3D.new()
    terrain.position = _chunk_to_world_position(chunk_coord)
    add_child(terrain)

    # Load all cells in chunk
    for x in range(8):
        for y in range(8):
            var cell := chunk_coord * 8 + Vector2i(x, y)
            _load_cell_into_chunk(cell, terrain)

    _active_chunks[chunk_coord] = terrain

func unload_chunk(cell: Vector2i) -> void:
    var chunk_coord := _cell_to_chunk(cell)
    if not _active_chunks.has(chunk_coord):
        return

    var terrain: Terrain3D = _active_chunks[chunk_coord]
    terrain.queue_free()
    _active_chunks.erase(chunk_coord)
```

---

## Performance Profiling

### PerformanceProfiler

Tracks frame timing to detect bottlenecks:

```gdscript
class_name PerformanceProfiler

var _frame_times: Array[float] = []
var _max_samples: int = 60

func record_frame(delta: float) -> void:
    _frame_times.append(delta * 1000.0)  # Convert to ms
    if _frame_times.size() > _max_samples:
        _frame_times.pop_front()

func get_average_frame_time() -> float:
    return _frame_times.reduce(func(a, b): return a + b, 0.0) / _frame_times.size()

func get_worst_frame_time() -> float:
    return _frame_times.max()

func get_fps() -> float:
    return 1.0 / (get_average_frame_time() / 1000.0)

func is_frame_hitch() -> bool:
    var avg := get_average_frame_time()
    var current := _frame_times[-1]
    return current > avg * 2.0  # Spike detection
```

### Debug Stats Overlay

Press **F3** to toggle:

```
=== GODOTWIND STATS ===
FPS: 60.2
Frame Time: 16.6ms (avg) | 23.4ms (worst)
Loaded Cells: 21 / 25 visible
Load Queue: 4 cells
LOD Distribution:
  FULL: 1203 objects
  LOW: 2456 objects
  BILLBOARD: 4821 objects
  CULLED: 18234 objects
Object Pool: 3421 / 5000 (hit rate: 87%)
```

---

## Configuration Tuning

### For High-End Systems
```gdscript
view_distance = 5          # 585m radius
load_budget_ms = 12.0      # More time per frame
lod_update_interval = 0.05 # More frequent updates
```

### For Low-End Systems
```gdscript
view_distance = 2          # 234m radius
load_budget_ms = 4.0       # Less time per frame
lod_update_interval = 0.2  # Less frequent updates
ObjectLODManager.DISTANCE_FULL = 30.0      # Cull sooner
ObjectLODManager.DISTANCE_BILLBOARD = 100.0
```

### For Daggerfall-Scale Worlds
```gdscript
terrain_mode = TerrainMode.MULTI
view_distance = 3  # Keep low for performance
# Multi-terrain has no size limit
```

---

## Signals

```gdscript
# WorldStreamingManager
signal cell_loaded(cell: Vector2i)
signal cell_unloaded(cell: Vector2i)
signal streaming_started()
signal streaming_stopped()
signal loading_progress(loaded: int, total: int)

# CellManager
signal cell_load_started(cell: Vector2i)
signal cell_load_completed(cell: Vector2i, node: Node3D)
signal cell_unload_completed(cell: Vector2i)
```

---

## Debugging

### Enable Verbose Logging

```gdscript
WorldStreamingManager.debug_mode = true
CellManager.debug_mode = true
```

Output:
```
[WorldStreaming] Camera cell: (0, 0)
[WorldStreaming] Queueing cell (1, 0) with priority -1
[CellManager] Loading cell 1,0 - 47 objects
[CellManager] Pool hit: flora_kelp_01.nif (89% hit rate)
[WorldStreaming] Cell (1, 0) loaded in 6.3ms
```

### Visualize Cell Boundaries

```gdscript
func _draw_cell_grid() -> void:
    for x in range(-view_distance, view_distance + 1):
        for y in range(-view_distance, view_distance + 1):
            var cell := Vector2i(x, y)
            var pos := _cell_to_world_position(cell)
            DebugDraw.draw_box(pos, Vector3(117, 1, 117), Color.GREEN)
```

---

## Best Practices

### 1. Always Use Time Budgets
Never block the main thread for more than a few milliseconds:

```gdscript
# ❌ Bad: Blocks for 200ms
for cell in all_cells:
    load_cell(cell)

# ✅ Good: Spreads over multiple frames
func _process_queue(budget_ms: float):
    var start := Time.get_ticks_usec()
    while queue.size() > 0 and (Time.get_ticks_usec() - start) < budget_ms * 1000:
        load_next_cell()
```

### 2. Prioritize by Distance
Always load closest cells first:

```gdscript
queue.sort_custom(func(a, b): return a.priority > b.priority)
```

### 3. Pool Frequent Objects
Identify high-frequency models and pool them:

```gdscript
# Analyze cell statistics
func _analyze_cell(cell_record: CellRecord) -> Dictionary:
    var counts := {}
    for ref in cell_record.references:
        var model := ESMManager.statics[ref.base_object_id].model
        counts[model] = counts.get(model, 0) + 1
    return counts

# Create pools for models with count > 50
```

### 4. Use Multi-Terrain for Large Worlds
Single-terrain is limited to 32×32 cells. For larger worlds, use multi-terrain:

```gdscript
if world_size > Vector2i(32, 32):
    terrain_mode = TerrainMode.MULTI
```

### 5. Profile Before Optimizing
Use PerformanceProfiler to identify actual bottlenecks:

```gdscript
profiler.start_section("cell_loading")
# ... expensive code ...
profiler.end_section("cell_loading")
print(profiler.get_section_time("cell_loading"))
```

---

## Common Issues

### Issue: Frame Hitches When Loading Cells
**Cause:** Load budget too high
**Solution:** Reduce `load_budget_ms` from 8.0 to 4.0

### Issue: Pop-In (Objects Appear Suddenly)
**Cause:** View distance too low or LOD update interval too high
**Solution:** Increase `view_distance` or decrease `lod_update_interval`

### Issue: Memory Usage Climbing
**Cause:** Cells not unloading, or pool cap too high
**Solution:** Check unload logic, reduce `ObjectPool.global_cap`

### Issue: Terrain Seams Visible
**Cause:** Edge stitching not working
**Solution:** Verify TerrainManager's `_stitch_edges()` function

---

## Future Improvements

### ⚠️ Predictive Loading
Pre-load cells in direction of player movement:

```gdscript
func _predict_next_cells(velocity: Vector3) -> Array[Vector2i]:
    var direction := velocity.normalized()
    var cells_ahead := []
    for i in range(1, 4):  # 3 cells ahead
        var predicted_pos := camera.position + direction * i * 117.0
        cells_ahead.append(_world_to_cell(predicted_pos))
    return cells_ahead
```

### ⚠️ Interior Transitions
Seamlessly switch between exterior and interior cells:

```gdscript
func enter_interior(door_ref: CellReference) -> void:
    var interior_cell := door_ref.destination_cell
    _pause_exterior_streaming()
    _load_interior_cell(interior_cell)
    _transition_camera(door_ref.destination_position)
```

### ❌ Network Synchronization
Use OWDB's networking to sync cell streaming across clients:

```gdscript
func _on_cell_loaded(cell: Vector2i) -> void:
    if multiplayer.is_server():
        rpc("client_load_cell", cell)
```

### ❌ Save/Load Integration
Persist world state (cell modifications, object positions):

```gdscript
func save_world_state() -> Dictionary:
    return {
        "loaded_cells": _loaded_cells.keys(),
        "modified_objects": _get_modified_objects(),
        "terrain_edits": terrain_manager.get_edits()
    }
```

---

## Task Tracker

- [x] WorldStreamingManager implementation
- [x] Time-budgeted cell loading
- [x] Priority queue system
- [x] Cell unloading
- [x] Single-terrain mode
- [x] Multi-terrain mode
- [x] Performance profiler
- [x] Debug stats overlay
- [ ] Predictive cell loading
- [ ] Interior/exterior transitions
- [ ] Water streaming
- [ ] Network synchronization
- [ ] Save/load integration
- [ ] Procedural content generation

---

**See Also:**
- [03_TERRAIN_SYSTEM.md](03_TERRAIN_SYSTEM.md) - Terrain generation details
- [04_LOD_AND_OPTIMIZATION.md](04_LOD_AND_OPTIMIZATION.md) - LOD and pooling systems
- [10_DEVELOPMENT_STATUS.md](10_DEVELOPMENT_STATUS.md) - Overall project roadmap
