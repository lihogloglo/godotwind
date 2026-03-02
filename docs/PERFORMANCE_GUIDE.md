# Performance Guide

---

## Measured Performance

| Metric | Value |
|--------|-------|
| FPS (streaming) | 60+ |
| View distance | 585m+ |
| Cell load budget | 2ms/frame |
| Memory usage | ~2GB |
| Initial load | ~5s |
| NIF parsing (C#) | 20-50x faster than GDScript |
| ESM loading (native) | 10-30x faster with cache |
| Async instantiation | 50 objects/frame (0.35ms each) |

**Target:** Desktop 60 FPS (16.67ms/frame), Mobile 30 FPS (33.33ms/frame)

---

## Frame Time Budget

```
Total frame: 16.67ms (60 FPS)
|- Godot engine: ~5ms (physics, rendering, input)
|- Gameplay logic: ~3ms (scripts, AI, etc.)
|- Streaming: 8ms (cell loading, object instantiation)
|- Reserve: 0.67ms (buffer for spikes)
```

**Pattern:**
```gdscript
@export var frame_budget_ms: float = 8.0

func _process(delta: float) -> void:
    var start_time := Time.get_ticks_msec()
    while not _load_queue.is_empty():
        var obj = _load_queue.pop_back() # Use pop_back() for O(1) performance
        _instantiate_object(obj)
        var elapsed := Time.get_ticks_msec() - start_time
        if elapsed >= frame_budget_ms:
            break
```

---

## Async Loading Architecture

**ResourceLoader for threaded loading:**
```gdscript
ResourceLoader.load_threaded_request(path)

# Poll in _process()
var status := ResourceLoader.load_threaded_get_status(path)
if status == ResourceLoader.THREAD_LOAD_LOADED:
    var resource := ResourceLoader.load_threaded_get(path)
```

**WorkerThreadPool for heavy operations:**
```gdscript
WorkerThreadPool.add_task(func():
    var instance := prototype.duplicate()
    call_deferred("_on_instance_ready", instance)
)
```

**Always call `wait_for_task_completion()`** — failing to do so leaks memory.

**Frame-based async pipeline:**
```
Frame 1: Request cell data from ESM
Frame 2: Parse NIF files (worker thread)
Frame 3: Convert to mesh (worker thread)
Frame 4-10: Instantiate objects (50/frame, time-budgeted)
Frame 11: Signal cell_loaded
```

---

## Cell Streaming Architecture

**Implementation:** `src/core/world/world_streaming_manager.gd`

```gdscript
@export var load_radius_cells: int = 3      # Load 3x3 grid around camera
@export var unload_radius_cells: int = 5    # Unload beyond 5 cells

func _update_loaded_cells() -> void:
    var cells_to_load := _get_cells_in_radius(_camera_cell, load_radius_cells)
    var cells_to_unload := _get_cells_beyond_radius(_camera_cell, unload_radius_cells)

    cells_to_load.sort_custom(_distance_sort)  # Nearest first

    for grid in cells_to_load:
        if grid not in _loaded_cells:
            _load_cell(grid)
            if _frame_budget_exceeded():
                break
```

**Key principles:**
- Distance-sorted priority (nearest cells first)
- Hysteresis between load/unload radii (prevents oscillation)
- Frame-budgeted instantiation

---

## Progressive Loading

Load geometry first, details later:
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

## GDScript Performance Tips

- **Static typing gives ~47% performance improvement** in hot paths (Vector operations, arithmetic)
- Use `for element in array` instead of `for i in array.size()` (~60% faster)
- Use `pop_back()` / `append()` instead of `pop_front()` / `push_front()` (O(1) vs O(n))
- Prefer `PackedArray` variants for large data (contiguous memory)
- Cache node references with `@onready` — don't call `get_node()` every frame
- Disable `_process()` / `_physics_process()` with `set_process(false)` when not needed

---

## Draw Call Reduction

- **MultiMesh**: Batch 10+ identical objects into single draw call
- **Material sharing**: Same Material instance across objects helps draw call sorting
- **HLOD**: Use visibility_range to replace groups of small meshes with a single lower-detail mesh at distance
- **Mesh merging**: Join static geometry ahead of time for interiors

---

## Profiling Tools (Godot 4.6)

- **ObjectDB snapshots**: Capture live object lists, diff to detect memory leaks
- **Tracy/Perfetto**: Native C++ tracing, GDScript function profiling
- **Speed controls**: Slow down/accelerate running games for inspection
- **Pipeline monitors**: Track shader compilation counts and stutter sources
- **Built-in profiler**: Frame time breakdown, script vs physics vs rendering
