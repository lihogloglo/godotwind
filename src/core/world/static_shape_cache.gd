## Per-prototype collision-shape cache for statics_no_node3d T.2.
##
## Caches extracted `(shape, local_xf)` tuples per `model_path` (lowercased,
## backslash-normalized). `cell_static_collision.build_for_cell` queries this
## cache once per ref at cell-activation time to feed the per-cell merged
## trimesh build.
##
## Lookup strategy (priority order):
## 1. In-memory `_cache` hit — O(1) dict lookup under Mutex.
## 2. Prebaked `StaticShapePack` sidecar (`.shapes.res`) — ResourceLoader.load.
##    Emitted at conversion time by `model_loader._save_shape_pack_to_disk`.
##    Sub-ms deserialize; worker-safe via `warm_from_path`. This is the T.6
##    fast path — avoids the 20-50ms `PackedScene.instantiate` + tree walk
##    spike that cell transitions otherwise incur.
## 3. Legacy walker — instantiate the prototype scene, walk it for
##    CollisionShape3D nodes. Kept as a fallback for assets whose conversion
##    predates T.6 (no sidecar yet). Self-heals once the cache is rebaked.
##
## MW has ~500 unique static prototypes vs ~10k refs in a 3×3 active grid,
## so this cache delivers ~20× instantiate reduction on the collision ingest
## even before T.6. The sidecar path reduces first-sight cost from ~20ms to
## ~0.2ms, eliminating the cell-transition fps_min dip observed at city loads.
##
## Thread safety: the in-memory dict is Mutex-guarded. `warm_from_path` is
## worker-safe by design — callers resolve the pack path on the main thread
## (via `ModelLoader.resolve_shape_pack_path`) and hand it to a worker for
## the load + publish. `get_shapes` remains main-thread (invoked from the
## cell_manager tick); the Mutex covers the rare case where a worker warms
## in parallel with a main-thread fallback walk.
class_name StaticShapeCache
extends RefCounted


const StaticShapePackScript := preload("res://src/core/world/static_shape_pack.gd")


## One cached entry per unique model_path. Shapes are stored as references to
## Godot's Shape3D resources — ref-counted, shared across all refs that use
## this prototype. Transform is the shape's position/rotation RELATIVE to the
## prototype root (not world-space; world-space is applied at merge time).
class Entry:
	extends RefCounted
	var shapes: Array = []  # [{shape: Shape3D, local_xf: Transform3D}, ...]


var _cache: Dictionary[String, Entry] = {}
var _cache_mutex: Mutex = Mutex.new()
var _pack_load_semaphores: Dictionary[String, Semaphore] = {}
var _pack_load_waiters: Dictionary[String, int] = {}
var _model_loader: RefCounted = null


func set_model_loader(loader: RefCounted) -> void:
	_model_loader = loader


## Query the cache for a model_path. Main-thread only.
##
## Path order: (1) in-memory hit, (2) prebaked shape pack sidecar, (3) legacy
## walker via PackedScene.instantiate. Caller MUST NOT mutate the returned
## array. Returns a shared reference — safe because Entry.shapes is only
## written at publish time under the mutex, and `Shape3D` / `Transform3D`
## sub-entries are immutable after that point.
func get_shapes(model_path: String) -> Array:
	var key := _normalize_key(model_path)

	_cache_mutex.lock()
	var hit: bool = key in _cache
	var existing_shapes: Array = _cache[key].shapes if hit else []
	_cache_mutex.unlock()
	if hit:
		return existing_shapes

	# (2) Try the prebaked sidecar before falling back to the walker. This is
	# the hot path once the cache has been (re)baked — sub-ms resource load
	# instead of 20-50ms scene instantiate + tree walk. Covers the case where
	# Phase F's worker-thread warm didn't land in time (ablation, or the
	# prototype's warm task was still in flight at cell-activation).
	if _model_loader != null:
		var pack_path: String = _model_loader.call("resolve_shape_pack_path", model_path)
		if pack_path != "":
			var packed_shapes := _load_pack_serialized(key, pack_path, false)
			if not packed_shapes.is_empty():
				return packed_shapes

	# (3) Legacy path — instantiate, walk, cache. Also publishes an empty
	# entry on failure so we don't retry every frame for missing prototypes.
	var entry := Entry.new()
	if _model_loader != null:
		var prototype: Node3D = _model_loader.call("get_model", model_path, "")
		if prototype != null:
			_walk_for_shapes(prototype, Transform3D.IDENTITY, entry)
			prototype.queue_free()

	return _publish_entry(key, entry)


## MAIN-THREAD: resolve a model_path's prebaked sidecar (`.shapes.res`) path
## via the configured ModelLoader. Returns "" when the loader is unset or the
## sidecar doesn't exist.
##
## Centralizes the model_loader→resolve_shape_pack_path call so callers
## (Win 1 collision dispatch, Phase F prereg) don't need to import
## ModelLoader directly. Mirror of `ModelLoader.resolve_shape_pack_path`'s
## main-thread contract — that method mutates `_file_exists_cache`.
func resolve_pack_path(model_path: String) -> String:
	if _model_loader == null:
		return ""
	if not _model_loader.has_method("resolve_shape_pack_path"):
		return ""
	return _model_loader.call("resolve_shape_pack_path", model_path)


## WORKER-SAFE: query the cache for a prototype's shapes. Tries the in-memory
## cache first; falls through to the prebaked sidecar via `ResourceLoader.load`
## (thread-safe per Godot docs). Returns empty when neither hits — callers
## should fall back to main-thread `get_shapes` for the legacy walker path.
##
## Path order:
## 1. In-memory `_cache` — Mutex-guarded, O(1) dict lookup.
## 2. Prebaked `StaticShapePack` sidecar — only if `pack_path` is non-empty
##    AND the cache caller pre-warmed via `warm_from_path` (preferred), OR
##    if the sidecar's existence has been resolved upstream.
##
## Does NOT call `_model_loader.resolve_shape_pack_path` (main-thread only)
## or `_model_loader.get_model` (legacy walker, main-thread only). Callers
## that hit empty here should either:
## - pre-warm via `warm_from_path` BEFORE invoking this (Win 1 dispatch
##   resolves pack_paths on main and the worker calls warm_from_path inline)
## - fall back to `get_shapes` on main for prototypes the worker missed
##
## Thread safety: Mutex covers cache read + publish. The returned shapes
## array is a shared reference — caller MUST NOT mutate it.
func get_shapes_for_worker(model_path: String) -> Array:
	var key := _normalize_key(model_path)

	_cache_mutex.lock()
	var hit: bool = key in _cache
	var existing_shapes: Array = _cache[key].shapes if hit else []
	_cache_mutex.unlock()
	return existing_shapes


## Worker-safe warm of a prototype's shape pack. Called by static-collision
## worker paths after the caller resolved `pack_path` on the main thread via
## `ModelLoader.resolve_shape_pack_path`.
##
## No-ops if the key is already cached or the pack fails to load (main-thread
## `get_shapes` will fall back to the walker for the affected prototype).
##
## Thread safety: ResourceLoader.load is documented thread-safe, but loading
## the same `.shapes.res` from two workers at once can duplicate subresource
## paths and make Godot emit cyclic-resource errors. This is a per-key
## single-flight load: one worker loads, same-key waiters block on a semaphore,
## and the cache mutex is held only for state transitions.
func warm_from_path(model_path: String, pack_path: String) -> void:
	if pack_path.is_empty():
		return
	var key := _normalize_key(model_path)
	_load_pack_serialized(key, pack_path)


func _load_pack_serialized(key: String, pack_path: String, wait_for_inflight: bool = true) -> Array:
	_cache_mutex.lock()
	if key in _cache:
		var cached_shapes: Array = _cache[key].shapes
		_cache_mutex.unlock()
		return cached_shapes
	if key in _pack_load_semaphores:
		if not wait_for_inflight:
			_cache_mutex.unlock()
			return []
		var waiter_sem: Semaphore = _pack_load_semaphores[key]
		_pack_load_waiters[key] = int(_pack_load_waiters.get(key, 0)) + 1
		_cache_mutex.unlock()
		waiter_sem.wait()
		_cache_mutex.lock()
		var loaded_shapes: Array = _cache[key].shapes if key in _cache else []
		_cache_mutex.unlock()
		return loaded_shapes
	var owner_sem := Semaphore.new()
	_pack_load_semaphores[key] = owner_sem
	_pack_load_waiters[key] = 0
	_cache_mutex.unlock()

	var pack := ResourceLoader.load(pack_path, "Resource") as StaticShapePackScript
	var entry := Entry.new()
	if pack != null:
		entry.shapes = (pack.shapes as Array).duplicate()

	_cache_mutex.lock()
	if pack != null and not key in _cache:
		_cache[key] = entry
	var shapes: Array = _cache[key].shapes if key in _cache else []
	var waiter_count := int(_pack_load_waiters.get(key, 0))
	_pack_load_semaphores.erase(key)
	_pack_load_waiters.erase(key)
	_cache_mutex.unlock()

	for i in range(waiter_count):
		owner_sem.post()
	return shapes


## Insert `entry` under mutex, re-checking for a concurrent publisher.
## Returns the winning Entry's shapes (whichever insert landed first).
func _publish_entry(key: String, entry: Entry) -> Array:
	_cache_mutex.lock()
	if not key in _cache:
		_cache[key] = entry
	var winning_shapes: Array = _cache[key].shapes
	_cache_mutex.unlock()
	return winning_shapes


## Normalize a model_path to the cache key format: lowercase +
## forward-slashes flipped to backslashes. Matches the disk-cache filename
## scheme in `model_loader._get_disk_cache_path` so warm-from-worker keys
## line up with main-thread get_shapes keys for the same ref.
static func _normalize_key(model_path: String) -> String:
	return model_path.to_lower().replace("/", "\\")


func _walk_for_shapes(node: Node, parent_xf: Transform3D, entry: Entry) -> void:
	var local_xf := parent_xf
	if node is Node3D:
		local_xf = parent_xf * (node as Node3D).transform

	if node is CollisionShape3D:
		var cs := node as CollisionShape3D
		if cs.shape != null:
			entry.shapes.append({
				"shape": cs.shape,
				"local_xf": local_xf,
			})

	for child in node.get_children():
		_walk_for_shapes(child, local_xf, entry)


## For debug / measurement: how many prototypes are cached.
func get_cache_size() -> int:
	_cache_mutex.lock()
	var sz := _cache.size()
	_cache_mutex.unlock()
	return sz


## For debug / measurement: total shapes across all cached prototypes.
func get_total_shapes() -> int:
	var total := 0
	_cache_mutex.lock()
	for entry: Entry in _cache.values():
		total += entry.shapes.size()
	_cache_mutex.unlock()
	return total
