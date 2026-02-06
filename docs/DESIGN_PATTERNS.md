# Design Patterns — Godotwind

---

## 1. NativeBridge Pattern (GDScript <-> C# Interop)

C# cannot call GDExtensions directly (Godot limitation). We use a GDScript bridge.

**Implementation:** `src/core/native_bridge.gd`

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

**Rule:** C# for heavy computation, GDScript for Godot API orchestration. Bridge connects them.

---

## 2. Async Loading with BackgroundProcessor

**Implementation:** `src/core/streaming/background_processor.gd`

```gdscript
# Non-blocking cell loading
func load_cell_async(grid: Vector2i) -> void:
    var job_id := background_processor.submit_job(func() -> Node3D:
        return _cell_manager.load_exterior_cell(grid.x, grid.y)
    )
    _pending_jobs[job_id] = grid
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
var _mutex := Mutex.new()
var _shared_cache: Dictionary = {}

func add_to_cache_threadsafe(key: String, value: Variant) -> void:
    _mutex.lock()
    _shared_cache[key] = value
    _mutex.unlock()
```

---

## 3. Frame Time Budgeting

Keep instantiation work within a per-frame budget to maintain 60 FPS.

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

**Budget Allocation:**
```
Total frame: 16.67ms (60 FPS)
|- Godot engine: ~5ms (physics, rendering, input)
|- Gameplay logic: ~3ms
|- Streaming: 8ms (cell loading, object instantiation)
|- Reserve: 0.67ms
```

---

## 4. Object Pooling

**Implementation:** `src/core/world/object_pool.gd`

```gdscript
var pool: Array[Node3D] = []

func get_instance(prototype: Node3D) -> Node3D:
    if pool.is_empty():
        return prototype.duplicate()
    return pool.pop_back()

func return_instance(instance: Node3D) -> void:
    instance.get_parent().remove_child(instance)
    pool.push_back(instance)
```

---

## 5. MultiMesh Batching

Single draw call for 10+ identical objects.

```gdscript
const MULTIMESH_THRESHOLD: int = 10

if identical_refs.size() >= MULTIMESH_THRESHOLD:
    var multimesh := MultiMeshInstance3D.new()
    multimesh.multimesh = MultiMesh.new()
    multimesh.multimesh.mesh = base_mesh
    multimesh.multimesh.instance_count = identical_refs.size()

    for i in identical_refs.size():
        multimesh.multimesh.set_instance_transform(i, transforms[i])
```

---

## 6. Material Deduplication

**Implementation:** `src/core/texture/material_library.gd`

Hash material properties to deduplicate. Result: ~90% reduction (10,000 -> 1,000 unique materials).

```gdscript
class_name MaterialLibrary

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

---

## 7. Inner Classes

Used for encapsulating data structures within their parent class.

```gdscript
# BackgroundProcessor uses inner class for task metadata
class TaskEntry:
    var callable: Callable
    var priority: int
    var task_id: int
```

---

## 8. Autoload Singletons

```gdscript
# Access via global name — never instantiate these yourself
SettingsManager    # User settings and paths
BSAManager         # Bethesda archive file access (256MB LRU cache)
ESMManager         # Elder Scrolls Master file parsing, grid indexing
OceanManager       # Water system coordinator
ShaderManager      # Shader hot-swap management

# Usage:
var morrowind_path := SettingsManager.get_morrowind_install_path()
var cell_record := ESMManager.get_cell_by_grid(Vector2i(0, 0))
```

---

## 9. Memory Management Patterns

**RefCounted for temporary objects:**
```gdscript
class_name TemporaryData extends RefCounted
var buffer: PackedByteArray
var metadata: Dictionary
```

**Static caches for parsed data:**
```gdscript
static var skeleton_cache: Dictionary = {}

func get_skeleton(nif_path: String) -> Skeleton3D:
    if skeleton_cache.has(nif_path):
        return skeleton_cache[nif_path]
    var skeleton := _parse_skeleton(nif_path)
    skeleton_cache[nif_path] = skeleton
    return skeleton
```

**Avoid circular references** between RefCounted objects (causes memory leaks).
