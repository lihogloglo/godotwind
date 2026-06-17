## ModelLoader - Handles source-neutral model loading and caching
##
## Extracted from CellManager for single responsibility.
## Loads provider/native PackedScenes or prebaked scene resources and caches
## them for reuse.
##
## Supports TWO levels of caching:
## 1. Memory cache: Fast, per-session (lost on restart)
## 2. Disk cache: Persistent, saves converted models as .res files
##
## Disk caching dramatically improves loading times after first run:
## - First run: provider conversion/import cost
## - Subsequent runs: 1-5ms per model (direct resource load)
##
## Usage:
##   var loader = ModelLoader.new()
##   loader.set_asset_provider(source.get_asset_provider())
##   loader.enable_disk_cache = true  # Enable persistent caching
##   var model = loader.get_model("source/model/id")
##   var model_with_collision = loader.get_model("source/model/id", "record_01")
class_name ModelLoader
extends RefCounted

const LODResource := preload("res://src/core/world/lod_resource.gd")
const StaticShapePackScript := preload("res://src/core/world/static_shape_pack.gd")
const StreamedResourceHandleScript := preload("res://src/core/streaming/streamed_resource_handle.gd")

## Maximum number of prototypes kept in memory cache
## When exceeded, least-recently-accessed entries are evicted to 80% capacity
const MAX_CACHE_SIZE := 500

## Maximum concurrent ResourceLoader.load_threaded_request calls in flight.
## Godot 4.6's internal resource loader can segfault (c0000005) when hammered
## with hundreds of concurrent threaded load requests during heavy startup.
const MAX_CONCURRENT_ASYNC_LOADS := 16

## Per-frame hard caps for the main-thread side of async ResourceLoader drain.
## These bound status polling, load_threaded_get() result handoff, and new
## deferred load submissions separately from the caller's instantiate budget.
const MAX_ASYNC_STATUS_POLLS_PER_FRAME := 8
const MAX_ASYNC_COMPLETIONS_PER_FRAME := 2
const MAX_DEFERRED_DRAIN_PER_FRAME := 4

## Fallback instantiation budget when no caller-supplied budget is available.
## 8ms matches INSTANTIATION_BUDGET_MS in StreamingConfig — used only if
## process_async_loads() is called without an explicit budget_usec argument.
const DRAIN_FALLBACK_BUDGET_USEC := 8000

## Cache for loaded models: model_path (lowercase) -> PackedScene | null
##
## Each `get_model()` call instantiates a fresh Node3D from the cached PackedScene.
## Callers never need to `.duplicate()` — they always receive a distinct instance.
## Null entries are "not found" markers (runtime-mode miss, model not in disk cache).
## Canonical fix for the shared-instance hazard described in MODEL_LOADER_RACE.md.
var _model_cache: Dictionary = {}

## LRU tracking: cache_key -> last access frame number
var _last_access: Dictionary = {}

## External lifetime pins: cache_key -> owner -> refcount.
## Cell streaming payloads use this to keep resources out of the LRU while
## their publish/collision queues can still reference them.
var _cache_pins: Dictionary = {}

## Canonical resource ownership for streamed prototypes. The cache dictionary is
## only the lookup table; handles keep PackedScene sub-resources alive while
## async publish/collision queues still reference them.
var _resource_handles: Dictionary = {}

## Async promotion should not evict while ResourceLoader callbacks and queued
## PackedScene handoffs are active. It marks this flag and a quiet frame trims.
var _eviction_requested: bool = false

## Cache for loaded LOD resources: model_path (lowercase) -> LODResource
var _lod_cache: Dictionary = {}

## Per-prototype animation flag cache (statics_no_node3d.md T.1 routing).
## Populated on first `_instantiate_from_scene` for a given resource_path:
## if the instantiated Node3D contains an AnimationPlayer, we stamp true here
## and all future routing queries short-circuit. Canonical per-prototype
## cache (one entry per unique model, not per ref) — ~500 prototypes across
## ~316k refs → 600× reduction in animation-check cost.
var _has_animation_cache: Dictionary[String, bool] = {}


## Query whether the prototype at `model_path` contains an AnimationPlayer.
## Used by the statics routing gate to carve out animated statics (flags,
## banners, rotating objects) that can't ride the MultiMesh path.
## Returns the cached value if known; otherwise inspects the PackedScene's
## SceneState metadata (no instantiation) then caches.
##
## Fix C (streaming_stutter_2026_04_25 plan): the previous implementation was
## the central main-thread spike source — `get_model` → ResourceLoader.load
## (recursive sub-resource resolution) + `PackedScene.instantiate` (~30 ms
## cold) + tree-walk + `queue_free`, all on the main thread, all to read a
## boolean. The old main-thread instantiate probe blew hundreds of ms per cell.
##
## The canonical Godot 4 pattern is `PackedScene.get_state().get_node_type(i)`
## — pure metadata lookup against the bundled data, no node creation. Cold
## cost drops from ~30 ms/prototype to ~1 ms/prototype (just the load, which
## is also cache-hit fast after the CellPreloader warm).
func has_animation(model_path: String) -> bool:
	var key := model_path.to_lower()

	_disk_cache_mutex.lock()
	if key in _has_animation_cache:
		var hit: bool = _has_animation_cache[key]
		_disk_cache_mutex.unlock()
		return hit
	_disk_cache_mutex.unlock()

	# Cache miss — inspect SceneState metadata. No instantiation. The slow
	# work (disk probe + ResourceLoader.load + SceneState walk) runs OUTSIDE
	# the mutex so concurrent workers probing different prototypes don't
	# serialize on this lock.
	var disk_path := resolve_disk_path(model_path)
	if disk_path.is_empty():
		_disk_cache_mutex.lock()
		_has_animation_cache[key] = false
		_disk_cache_mutex.unlock()
		return false

	# CACHE_MODE_REUSE: hit the ResourceLoader cache the preloader already
	# warmed. If cold, this loads the PackedScene once — much cheaper than
	# instantiating it because we skip the recursive sub-resource finalize
	# that `_drain_pending_instantiate_queue` does.
	var packed_scene: PackedScene = ResourceLoader.load(
		disk_path, "PackedScene", ResourceLoader.CACHE_MODE_REUSE
	) as PackedScene
	var found := false
	if packed_scene != null:
		var state: SceneState = packed_scene.get_state()
		if state != null:
			var node_count: int = state.get_node_count()
			for i in node_count:
				# get_node_type returns the registered class name as StringName.
				if state.get_node_type(i) == &"AnimationPlayer":
					found = true
					break

	_disk_cache_mutex.lock()
	_has_animation_cache[key] = found
	_disk_cache_mutex.unlock()
	return found

## The mod registry for asset resolution
var _mod_registry: ModRegistry = null

## Source-specific asset provider. Generic ModelLoader owns cache lifetime and
## Godot resource promotion; providers own source/archive/conversion rules.
var _asset_provider: RefCounted = null

## Enable disk caching of converted models (saves as .res files)
## Set to true to persist converted models between game sessions
var enable_disk_cache: bool = true

## RUNTIME MODE: Only load provider/native resources and disk cache.
## When true (default for world explorer), models not in disk cache return null.
## When false (prebaking mode), missing models may ask the provider to convert.
var runtime_mode: bool = true

## Directory for disk cache (set from SettingsManager on first use)
## Defaults to Documents/Godotwind/cache/models/
var _disk_cache_dir: String = ""

## Cache for file existence checks to avoid repeated disk I/O
## Maps disk_path -> bool (exists or not)
## This eliminates repeated FileAccess.file_exists() calls which are slow
var _file_exists_cache: Dictionary = {}

## Fix D (streaming_stutter_2026_04_25 plan): mutex covering both
## `_file_exists_cache` AND `_has_animation_cache`. The off-thread prereg
## paths call `resolve_disk_path` / `resolve_shape_pack_path` /
## `has_animation` from worker threads — we mutex the dict R/W to avoid
## torn writes against main-thread callers (carryable spawn paths,
## proximity routing).
##
## Mutex is held only for dict access — not for the FileAccess.file_exists
## probe or the SceneState parse, which are the slow parts. Workers
## release before doing those.
var _disk_cache_mutex: Mutex = Mutex.new()

## Pending async load requests: disk_path -> {cache_key: String, callbacks: Array[Callable]}
## Multiple requests for the same model share one load operation
var _pending_async_loads: Dictionary = {}

## Deferred async requests waiting for a slot (throttled by MAX_CONCURRENT_ASYNC_LOADS)
## Each entry: {disk_path: String, cache_key: String, callback: Callable, model_path: String, item_id: String}
var _deferred_async_queue: Array[Dictionary] = []

## Deferred instantiate queue. Async pipeline fills this; drain does a sync
## CACHE_MODE_REUSE reload to complete any deferred c2 sub-resource initialization
## before calling instantiate() — avoids SIGSEGV from partially-settled async loads.
## Each entry: {disk_path: String, packed_scene: PackedScene, cache_key: String, callbacks: Array[Dictionary]}
var _pending_instantiate_queue: Array[Dictionary] = []

## Statistics
var _stats: Dictionary = {
	"models_loaded": 0,
	"models_from_cache": 0,
	"models_from_disk": 0,
	"models_from_disk_async": 0,
	"models_from_provider": 0,
	"file_exists_cache_hits": 0,
	"models_saved": 0,
}

## Track first saved model for condensed logging
var _first_saved_model: String = ""
var _last_save_report_count: int = 0


## Get or load a model prototype
## Returns cached model if available, loads provider/native resources or disk
## cache next, and asks the injected provider for conversion only in prebake mode.
## With disk caching enabled, converted models are saved for instant loading next time.
##
## Parameters:
##   model_path: Source model id or resource path
##   item_id: Optional source record ID for collision shape lookup
##
## Returns:
##   Node3D prototype (never modify, use duplicate()), or null if not found
func get_model(model_path: String, item_id: String = "") -> Node3D:
	var normalized := model_path.to_lower().replace("/", "\\")

	# Cache key includes item_id since same model may need different collision for different items
	var cache_key := normalized
	if not item_id.is_empty():
		cache_key = normalized + ":" + item_id.to_lower()

	# 1. Check memory cache first (fastest) — stores PackedScene, returns fresh Node3D
	if cache_key in _model_cache:
		var cached: Variant = _model_cache[cache_key]
		if cached == null:
			return null
		_stats["models_from_cache"] += 1
		_last_access[cache_key] = Engine.get_frames_drawn()
		if cached is PackedScene:
			_get_or_create_resource_handle(cache_key, cached as PackedScene)
		return _instantiate_from_scene(cached as PackedScene)

	# 2. Ask the injected provider for a native PackedScene resource. This is
	# the generic path for provider-native sources and already-imported assets.
	var provider_scene := _get_provider_packed_scene(model_path, item_id)
	if provider_scene != null:
		_model_cache[cache_key] = provider_scene
		_last_access[cache_key] = Engine.get_frames_drawn()
		_get_or_create_resource_handle(cache_key, provider_scene)
		_stats["models_from_provider"] += 1
		_queue_eviction_if_over_budget()
		return _instantiate_from_scene(provider_scene)

	# 3. Check disk cache if enabled (fast - direct resource load)
	if enable_disk_cache:
		var disk_path := _get_disk_cache_path(cache_key)
		if _cached_file_exists(disk_path):
			var packed_scene := _load_packed_scene_from_disk(disk_path)
			if packed_scene:
				_model_cache[cache_key] = packed_scene
				_last_access[cache_key] = Engine.get_frames_drawn()
				_get_or_create_resource_handle(cache_key, packed_scene)
				_stats["models_from_disk"] += 1
				_queue_eviction_if_over_budget()
				return _instantiate_from_scene(packed_scene)

	# 4. RUNTIME MODE: Return null for uncached models. Source-specific
	# conversion should ONLY happen during prebaking, never during gameplay.
	if runtime_mode:
		# Cache null to avoid repeated disk checks
		_model_cache[cache_key] = null
		return null

	# 5. PREBAKING MODE ONLY: ask the source provider to convert source-native
	# model data into a Godot node. Archive parsing and format conversion live
	# behind the provider boundary, not in this framework cache.
	var node := _create_provider_model_scene(model_path, item_id)

	if not node:
		# Only warn once per failed model
		if not cache_key in _model_cache:
			push_warning("ModelLoader: Asset provider could not create model: '%s'" % model_path)
		_model_cache[cache_key] = null
		return null

	# 6. Save to disk cache for next time. _save_to_disk_cache strips occluders and
	# sets owner on the node tree, so we pack AFTER the save call.
	if enable_disk_cache:
		_save_to_disk_cache(node, cache_key)

	# Pack to PackedScene for memory cache (owners already set by _save_to_disk_cache).
	# If disk cache was not used, strip and set owners manually before packing.
	if not enable_disk_cache:
		_strip_occluders(node)
		_set_owner_recursive(node, node)
	var ps := PackedScene.new()
	if ps.pack(node) == OK:
		_model_cache[cache_key] = ps
		_last_access[cache_key] = Engine.get_frames_drawn()
		_get_or_create_resource_handle(cache_key, ps)
		_stats["models_loaded"] += 1
		_evict_if_over_budget()
		return _instantiate_from_scene(ps)
	else:
		push_warning("ModelLoader: Failed to pack prebaked node: %s" % cache_key)
		_model_cache[cache_key] = null
		node.queue_free()
		return null


## Clear the model cache and reset statistics
func clear_cache() -> void:
	for handle_value: Variant in _resource_handles.values():
		var handle: RefCounted = handle_value as RefCounted
		if handle != null:
			handle.release()
	_resource_handles.clear()
	_model_cache.clear()
	_last_access.clear()
	_cache_pins.clear()
	_eviction_requested = false
	_file_exists_cache.clear()
	_stats["models_loaded"] = 0
	_stats["models_from_cache"] = 0
	_stats["models_from_disk"] = 0
	_stats["models_from_provider"] = 0
	_stats["file_exists_cache_hits"] = 0


func _make_cache_key(model_path: String, item_id: String = "") -> String:
	var normalized := model_path.to_lower().replace("/", "\\")
	if not item_id.is_empty():
		return normalized + ":" + item_id.to_lower()
	return normalized


func _get_provider_packed_scene(model_path: String, item_id: String = "") -> PackedScene:
	if _asset_provider == null:
		return null
	var resource: Resource = null
	if _asset_provider.has_method("get_model_resource"):
		resource = _asset_provider.call("get_model_resource", model_path, item_id) as Resource
	if resource == null:
		var provider_path := _get_provider_resource_path(model_path)
		if not provider_path.is_empty():
			resource = ResourceLoader.load(provider_path, "PackedScene") as Resource
	if resource is PackedScene and (resource as PackedScene).can_instantiate():
		return resource as PackedScene
	return null


func _provider_has_model_resource(model_path: String, item_id: String = "") -> bool:
	if _asset_provider == null:
		return false
	if _asset_provider.has_method("has_model_resource"):
		return bool(_asset_provider.call("has_model_resource", model_path, item_id))
	return not _get_provider_resource_path(model_path).is_empty()


func _create_provider_model_scene(model_path: String, item_id: String = "") -> Node3D:
	if _asset_provider == null or not _asset_provider.has_method("create_model_scene"):
		return null
	var produced: Variant = _asset_provider.call("create_model_scene", model_path, item_id)
	if produced is Node3D:
		return produced as Node3D
	if produced is PackedScene and (produced as PackedScene).can_instantiate():
		return (produced as PackedScene).instantiate() as Node3D
	return null


func _get_provider_resource_path(model_path: String) -> String:
	if _asset_provider == null or not _asset_provider.has_method("resolve_model_path"):
		return ""
	var resolved := str(_asset_provider.call("resolve_model_path", model_path))
	if resolved.is_empty():
		return ""
	var resource_path := resolved
	if resource_path.begins_with("res://") or resource_path.begins_with("user://"):
		resource_path = resource_path.replace("\\", "/")
	if ResourceLoader.exists(resource_path):
		return resource_path
	return ""


func _get_or_create_resource_handle(cache_key: String, packed_scene: PackedScene) -> RefCounted:
	if cache_key.is_empty() or packed_scene == null:
		return null
	var handle: RefCounted = _resource_handles.get(cache_key) as RefCounted
	if handle == null:
		handle = StreamedResourceHandleScript.new(cache_key, packed_scene)
		_resource_handles[cache_key] = handle
	elif handle.packed_scene != packed_scene:
		handle.set_packed_scene(packed_scene)
	return handle


func pin_cached_model(model_path: String, item_id: String = "", owner: String = "") -> void:
	var cache_key := _make_cache_key(model_path, item_id)
	if cache_key.is_empty():
		return
	var pin_owner := owner if not owner.is_empty() else "external"
	if not _cache_pins.has(cache_key):
		_cache_pins[cache_key] = {}
	var owners: Dictionary = _cache_pins[cache_key]
	owners[pin_owner] = int(owners.get(pin_owner, 0)) + 1
	if cache_key in _model_cache and _model_cache[cache_key] is PackedScene:
		var handle := _get_or_create_resource_handle(cache_key, _model_cache[cache_key] as PackedScene)
		if handle != null:
			handle.add_owner(pin_owner)


func unpin_cached_model(model_path: String, item_id: String = "", owner: String = "") -> void:
	unpin_cache_key(_make_cache_key(model_path, item_id), owner)


func unpin_cache_key(cache_key: String, owner: String = "") -> void:
	if cache_key.is_empty():
		return
	var pin_owner := owner if not owner.is_empty() else "external"
	if _cache_pins.has(cache_key):
		var owners: Dictionary = _cache_pins[cache_key]
		if owners.has(pin_owner):
			var count := int(owners[pin_owner]) - 1
			if count > 0:
				owners[pin_owner] = count
			else:
				owners.erase(pin_owner)
			if owners.is_empty():
				_cache_pins.erase(cache_key)
	var handle: RefCounted = _resource_handles.get(cache_key) as RefCounted
	if handle != null:
		handle.remove_owner(pin_owner)


func unpin_cache_owner(owner: String) -> void:
	if owner.is_empty():
		return
	var empty_keys: Array[String] = []
	for key: String in _cache_pins:
		var owners: Dictionary = _cache_pins[key]
		if owners.has(owner):
			owners.erase(owner)
		if owners.is_empty():
			empty_keys.append(key)
	for key: String in empty_keys:
		_cache_pins.erase(key)
	for key: String in _resource_handles:
		var handle: RefCounted = _resource_handles[key] as RefCounted
		if handle != null:
			handle.remove_owner(owner)


func _is_cache_key_pinned(cache_key: String) -> bool:
	if cache_key in _cache_pins and not (_cache_pins[cache_key] as Dictionary).is_empty():
		return true
	var handle: RefCounted = _resource_handles.get(cache_key) as RefCounted
	if handle != null and handle.is_owned():
		return true
	for disk_path: String in _pending_async_loads:
		if str(_pending_async_loads[disk_path].cache_key) == cache_key:
			return true
	for entry: Dictionary in _pending_instantiate_queue:
		if str(entry.get("cache_key", "")) == cache_key:
			return true
	for entry: Dictionary in _deferred_async_queue:
		if str(entry.get("cache_key", "")) == cache_key:
			return true
	return false


func _queue_eviction_if_over_budget() -> void:
	if _model_cache.size() > MAX_CACHE_SIZE:
		_eviction_requested = true


func _try_drain_requested_eviction() -> void:
	if not _eviction_requested:
		return
	if not _pending_instantiate_queue.is_empty():
		return
	if not _pending_async_loads.is_empty():
		return
	if not _deferred_async_queue.is_empty():
		return
	_evict_if_over_budget()


## Evict least-recently-accessed cache entries if over budget
## Evicts down to 80% of MAX_CACHE_SIZE to avoid evicting every frame
func _evict_if_over_budget() -> void:
	_eviction_requested = false
	if _model_cache.size() <= MAX_CACHE_SIZE:
		return

	var target_size := int(MAX_CACHE_SIZE * 0.8)

	# Build sortable array of (frame, key) pairs
	# Only evict non-null entries (null entries are cheap "miss" markers)
	var entries: Array[Array] = []
	for key: String in _last_access:
		if key in _model_cache and _model_cache[key] != null:
			entries.append([_last_access[key], key])

	# Sort by frame ascending (oldest first)
	entries.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])

	# Evict oldest until under target
	var evicted := 0
	var skipped_pinned := 0
	for entry: Array in entries:
		if _model_cache.size() <= target_size:
			break
		var key: String = entry[1]
		if _is_cache_key_pinned(key):
			skipped_pinned += 1
			continue
		var handle: RefCounted = _resource_handles.get(key) as RefCounted
		if handle != null and handle.is_owned():
			skipped_pinned += 1
			continue
		_resource_handles.erase(key)
		_model_cache.erase(key)
		_last_access.erase(key)
		evicted += 1

	if _model_cache.size() > MAX_CACHE_SIZE:
		_eviction_requested = true
	if evicted > 0:
		if not _stats.has("lru_evictions"):
			_stats["lru_evictions"] = 0
		_stats["lru_evictions"] += evicted
	if skipped_pinned > 0:
		if not _stats.has("lru_eviction_pinned_skips"):
			_stats["lru_eviction_pinned_skips"] = 0
		_stats["lru_eviction_pinned_skips"] += skipped_pinned
	if evicted > 0 or skipped_pinned > 0:
		Log.debug("streaming", "LRU evict pass: evicted=%d pinned=%d cache=%d/%d pins=%d" % [
			evicted,
			skipped_pinned,
			_model_cache.size(),
			MAX_CACHE_SIZE,
			_cache_pins.size(),
		])


## Cached file existence check - avoids repeated disk I/O.
## Results are cached for the session lifetime since prebaked files don't change.
## Fix D — thread-safe via _disk_cache_mutex. The mutex is dropped before the
## FileAccess.file_exists probe (potentially blocking I/O) so concurrent workers
## probing different paths don't serialize.
func _cached_file_exists(path: String) -> bool:
	_disk_cache_mutex.lock()
	if path in _file_exists_cache:
		var hit: bool = _file_exists_cache[path]
		_stats["file_exists_cache_hits"] += 1
		_disk_cache_mutex.unlock()
		return hit
	_disk_cache_mutex.unlock()

	# Slow path (file system) outside the lock.
	var exists := FileAccess.file_exists(path)

	_disk_cache_mutex.lock()
	# Double-check: another worker may have populated while we probed.
	# Either way, store our result. Multiple identical writes are harmless.
	_file_exists_cache[path] = exists
	_disk_cache_mutex.unlock()
	return exists


## Invalidate file existence cache for a specific path or all paths
## Call after rebaking assets or when disk cache changes
func invalidate_file_cache(path: String = "") -> void:
	if path.is_empty():
		_file_exists_cache.clear()
		Log.info("models", "File existence cache cleared")
	else:
		_file_exists_cache.erase(path)


## Populate the file-existence cache from the prebaked model directory once at
## boot. This keeps streaming classification from doing synchronous per-model
## FileAccess probes on the main thread.
func prewarm_disk_cache_index() -> int:
	var cache_dir := _get_disk_cache_dir()
	var dir := DirAccess.open(cache_dir)
	if dir == null:
		return 0

	var indexed_paths: Array[String] = []
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".res"):
			indexed_paths.append(cache_dir.path_join(file_name))
		file_name = dir.get_next()
	dir.list_dir_end()

	_disk_cache_mutex.lock()
	for path: String in indexed_paths:
		_file_exists_cache[path] = true
	_disk_cache_mutex.unlock()
	return indexed_paths.size()


## Get statistics about model loading
## Returns:
##   Dictionary with keys: models_loaded, models_from_cache, models_from_disk, models_from_disk_async, etc.
func get_stats() -> Dictionary:
	return {
		"models_loaded": _stats["models_loaded"],
		"models_from_cache": _stats["models_from_cache"],
		"models_from_disk": _stats["models_from_disk"],
		"models_from_disk_async": _stats["models_from_disk_async"],
		"models_from_provider": _stats["models_from_provider"],
		"models_saved": _stats["models_saved"],
		"pending_async_loads": _pending_async_loads.size(),
		"cached_models": _model_cache.size(),
		"max_cache_size": MAX_CACHE_SIZE,
		"lru_evictions": _stats.get("lru_evictions", 0),
		"lru_eviction_pinned_skips": _stats.get("lru_eviction_pinned_skips", 0),
		"cache_pinned_keys": _cache_pins.size(),
		"cache_eviction_requested": _eviction_requested,
		"file_exists_cache_hits": _stats["file_exists_cache_hits"],
		"file_exists_cache_size": _file_exists_cache.size(),
	}


## Print final summary of saved models (call when batch save is complete)
func print_save_summary() -> void:
	var saved: int = _stats["models_saved"]
	if saved == 0:
		return

	# Only print if there are unreported saves
	if saved > _last_save_report_count:
		if saved == 1:
			Log.info("models", "Saved %s" % _first_saved_model)
		else:
			Log.info("models", "Saved %d models total (first: %s)" % [saved, _first_saved_model])
		_last_save_report_count = saved


## Get the number of models currently cached
func get_cache_size() -> int:
	return _model_cache.size()


## Check if a model is already cached
## Parameters:
##   model_path: Path to check
##   item_id: Optional item ID (if different collision)
## Returns:
##   true if model is in cache (even if null)
func has_model(model_path: String, item_id: String = "") -> bool:
	var normalized := model_path.to_lower().replace("/", "\\")
	var cache_key := normalized
	if not item_id.is_empty():
		cache_key = normalized + ":" + item_id.to_lower()
	return cache_key in _model_cache


## Return the cached PackedScene for a model without instantiating it.
## Phase A off-thread path: the dispatcher peeks the cache on the main thread,
## then hands the PackedScene to a WorkerThreadPool task that calls
## PackedScene.instantiate(GEN_EDIT_STATE_DISABLED) off-thread.
##
## Returns null on cache miss, null sentinel, or non-PackedScene entry — the
## caller MUST fall back to the existing synchronous get_model() path, which
## handles disk-cache promotion, async request, and the CACHE_MODE_REUSE
## sub-resource finalization dance (plan §8.1).
##
## Updates _last_access for LRU budget correctness (mirrors get_model's
## cache-hit bookkeeping) so the worker path doesn't make entries look cold.
func get_cached_packed_scene(model_path: String, item_id: String = "") -> PackedScene:
	var normalized := model_path.to_lower().replace("/", "\\")
	var cache_key := normalized
	if not item_id.is_empty():
		cache_key = normalized + ":" + item_id.to_lower()
	if not cache_key in _model_cache:
		return null
	var cached: Variant = _model_cache[cache_key]
	if cached == null:
		return null
	if not cached is PackedScene:
		return null
	_last_access[cache_key] = Engine.get_frames_drawn()
	_stats["models_from_cache"] += 1
	_get_or_create_resource_handle(cache_key, cached as PackedScene)
	return cached as PackedScene


func get_cached_resource_handle(model_path: String, item_id: String = "") -> RefCounted:
	var cache_key := _make_cache_key(model_path, item_id)
	if cache_key.is_empty() or not cache_key in _model_cache:
		return null
	var cached: Variant = _model_cache[cache_key]
	if cached == null or not cached is PackedScene:
		return null
	_last_access[cache_key] = Engine.get_frames_drawn()
	return _get_or_create_resource_handle(cache_key, cached as PackedScene)


## Restore a known-good PackedScene into the memory cache without touching disk.
## CellPayload uses this to keep exact publish-key resources hot even if the
## LRU trims the ModelLoader cache before visual publication reaches a ref.
func put_cached_packed_scene(model_path: String, item_id: String, packed_scene: PackedScene) -> bool:
	if packed_scene == null or not packed_scene.can_instantiate():
		return false
	var normalized := model_path.to_lower().replace("/", "\\")
	var cache_key := normalized
	if not item_id.is_empty():
		cache_key = normalized + ":" + item_id.to_lower()
	_model_cache[cache_key] = packed_scene
	_last_access[cache_key] = Engine.get_frames_drawn()
	_get_or_create_resource_handle(cache_key, packed_scene)
	_queue_eviction_if_over_budget()
	return true


# =============================================================================
# ASYNC DISK LOADING API
# =============================================================================
# Uses ResourceLoader.load_threaded_request() to load models without blocking
# the main thread. Call request_model_async() to start loading, then call
# process_async_loads() each frame to check for completions.
# =============================================================================

## Request async loading of a model from disk cache
## Returns immediately. Call process_async_loads() to get results.
## Parameters:
##   model_path: Source model id or resource path
##   item_id: Optional item ID for collision variations
##   callback: Called when load completes with (model_path: String, item_id: String, model: Node3D)
## Returns:
##   true if load was started or model already cached, false if not in disk cache
func request_model_async(
	model_path: String,
	item_id: String = "",
	callback: Callable = Callable(),
	instantiate_for_callback: bool = true
) -> bool:
	var request_start_t0 := Time.get_ticks_usec()
	var normalized := model_path.to_lower().replace("/", "\\")
	var cache_key := normalized
	if not item_id.is_empty():
		cache_key = normalized + ":" + item_id.to_lower()

	# 1. Check memory cache first
	if cache_key in _model_cache:
		var cached: Variant = _model_cache[cache_key]
		_stats["models_from_cache"] += 1
		_last_access[cache_key] = Engine.get_frames_drawn()
		if callback.is_valid():
			var instance: Node3D = null
			if instantiate_for_callback and cached != null:
				instance = _instantiate_from_scene(cached as PackedScene)
			callback.call(model_path, item_id, instance)
		return true

	# 2. Provider-backed PackedScenes are already usable resources, so cache
	# and answer immediately without touching the source-specific disk cache.
	var provider_scene := _get_provider_packed_scene(model_path, item_id)
	if provider_scene != null:
		_model_cache[cache_key] = provider_scene
		_last_access[cache_key] = Engine.get_frames_drawn()
		_get_or_create_resource_handle(cache_key, provider_scene)
		_stats["models_from_provider"] += 1
		_queue_eviction_if_over_budget()
		if callback.is_valid():
			var provider_instance: Node3D = null
			if instantiate_for_callback:
				provider_instance = _instantiate_from_scene(provider_scene)
			callback.call(model_path, item_id, provider_instance)
		return true

	# 3. Check if already loading this model
	var disk_path := _get_disk_cache_path(cache_key)
	if disk_path in _pending_async_loads:
		# Already loading - add callback to existing request
		if callback.is_valid():
			_pending_async_loads[disk_path].callbacks.append({
				"callback": callback,
				"model_path": model_path,
				"item_id": item_id,
				"instantiate_for_callback": instantiate_for_callback,
			})
		return true

	# 4. Check disk cache exists
	var exists_us := 0
	var exists_start := Time.get_ticks_usec()
	var disk_exists := enable_disk_cache and _cached_file_exists(disk_path)
	exists_us = Time.get_ticks_usec() - exists_start
	if not disk_exists:
		# Not in disk cache - in runtime mode this means model isn't prebaked
		if runtime_mode:
			_model_cache[cache_key] = null  # Cache miss
			if callback.is_valid():
				callback.call(model_path, item_id, null)
		var missing_total_us := Time.get_ticks_usec() - request_start_t0
		if missing_total_us > 8_000:
			Log.warn("streaming", "[ml-request-start %.1fms] result=missing exists=%.1f model=%s item=%s" % [
				float(missing_total_us) / 1000.0,
				float(exists_us) / 1000.0,
				model_path,
				item_id,
			])
		return false

	# 5. Throttle: defer if too many concurrent loads in flight
	if _pending_async_loads.size() >= MAX_CONCURRENT_ASYNC_LOADS:
		_deferred_async_queue.append({
			"disk_path": disk_path,
			"cache_key": cache_key,
			"callback": callback,
			"model_path": model_path,
			"item_id": item_id,
			"instantiate_for_callback": instantiate_for_callback,
		})
		var defer_total_us := Time.get_ticks_usec() - request_start_t0
		if defer_total_us > 8_000:
			Log.warn("streaming", "[ml-request-start %.1fms] result=deferred exists=%.1f pending=%d deferred=%d model=%s item=%s" % [
				float(defer_total_us) / 1000.0,
				float(exists_us) / 1000.0,
				_pending_async_loads.size(),
				_deferred_async_queue.size(),
				model_path,
				item_id,
			])
		return true  # Will be started later by _drain_deferred_queue

	# 6. Start async load
	var threaded_request_start := Time.get_ticks_usec()
	var err := ResourceLoader.load_threaded_request(disk_path, "PackedScene")
	var threaded_request_us := Time.get_ticks_usec() - threaded_request_start
	if err != OK:
		push_warning("ModelLoader: Failed to start async load for %s: %s" % [disk_path, error_string(err)])
		if callback.is_valid():
			callback.call(model_path, item_id, null)
		var failed_total_us := Time.get_ticks_usec() - request_start_t0
		if failed_total_us > 8_000 or threaded_request_us > 8_000:
			Log.warn("streaming", "[ml-request-start %.1fms] result=error err=%s exists=%.1f request=%.1f model=%s item=%s" % [
				float(failed_total_us) / 1000.0,
				error_string(err),
				float(exists_us) / 1000.0,
				float(threaded_request_us) / 1000.0,
				model_path,
				item_id,
			])
		return false

	# Track pending load
	_pending_async_loads[disk_path] = {
		"cache_key": cache_key,
		"callbacks": [] as Array[Dictionary]
	}
	if callback.is_valid():
		_pending_async_loads[disk_path].callbacks.append({
			"callback": callback,
			"model_path": model_path,
			"item_id": item_id,
			"instantiate_for_callback": instantiate_for_callback,
		})

	var total_us := Time.get_ticks_usec() - request_start_t0
	if total_us > 8_000 or threaded_request_us > 8_000:
		Log.warn("streaming", "[ml-request-start %.1fms] result=started exists=%.1f request=%.1f pending=%d deferred=%d model=%s item=%s" % [
			float(total_us) / 1000.0,
			float(exists_us) / 1000.0,
			float(threaded_request_us) / 1000.0,
			_pending_async_loads.size(),
			_deferred_async_queue.size(),
			model_path,
			item_id,
		])

	return true


## Check if a model is currently being loaded asynchronously
func is_loading_async(model_path: String, item_id: String = "") -> bool:
	var normalized := model_path.to_lower().replace("/", "\\")
	var cache_key := normalized
	if not item_id.is_empty():
		cache_key = normalized + ":" + item_id.to_lower()
	var disk_path := _get_disk_cache_path(cache_key)
	return disk_path in _pending_async_loads


## Process pending async loads - call this every frame
## Returns number of loads completed this frame
##
## Two-phase pipeline:
##   Phase A: instantiate pending entries up to budget_usec microseconds.
##            Uses the async-loaded PackedScene with can_instantiate() guard;
##            falls back to sync re-load on validation failure.
##   Phase B: poll in-flight async loads. Completed loads move to the pending
##            instantiate queue for Phase A next frame.
## budget_usec: time budget for Phase A; 0 uses DRAIN_FALLBACK_BUDGET_USEC.
func process_async_loads(budget_usec: int = 0) -> int:
	# Fix E (streaming_stutter_2026_04_25 plan §11.4) — sub-bracket the three
	# phases so the inst-spike log can attribute the disk= cost to the actual
	# culprit (Phase A drain / Phase B poll / deferred drain).
	var t0 := Time.get_ticks_usec()
	_try_drain_requested_eviction()

	# Phase A: instantiate within budget.
	var effective_budget := budget_usec if budget_usec > 0 else DRAIN_FALLBACK_BUDGET_USEC
	var completed := _drain_pending_instantiate_queue(effective_budget)

	var t_phase_a := Time.get_ticks_usec()
	var phase_b_budget_left: int = maxi(0, effective_budget - int(t_phase_a - t0))

	if _pending_async_loads.is_empty() and _deferred_async_queue.is_empty():
		_try_drain_requested_eviction()
		return completed
	if _pending_async_loads.is_empty():
		_drain_deferred_queue(phase_b_budget_left, MAX_DEFERRED_DRAIN_PER_FRAME)
		var t_dd := Time.get_ticks_usec()
		var ml_total: int = t_dd - t0
		if ml_total > 8_000:
			Log.warn("streaming", "[ml-spike %.1fms] phaseA=%.1f phaseB=0.0 dd=%.1f items_completed=%d pending_instq=%d pending_async=%d deferred=%d" % [
				ml_total / 1000.0,
				float(t_phase_a - t0) / 1000.0,
				float(t_dd - t_phase_a) / 1000.0,
				completed,
				_pending_instantiate_queue.size(),
				_pending_async_loads.size(),
				_deferred_async_queue.size(),
			])
		_try_drain_requested_eviction()
		return completed

	var to_remove: Array[String] = []
	var phase_b_get_count: int = 0
	var status_polls := 0

	# Phase B: poll in-flight loads, defer instantiate for next frame.
	for disk_path: String in _pending_async_loads:
		if status_polls >= MAX_ASYNC_STATUS_POLLS_PER_FRAME:
			break
		if phase_b_get_count >= MAX_ASYNC_COMPLETIONS_PER_FRAME:
			break
		if Time.get_ticks_usec() - t0 >= effective_budget:
			break
		status_polls += 1

		var status := ResourceLoader.load_threaded_get_status(disk_path)

		match status:
			ResourceLoader.THREAD_LOAD_LOADED:
				# Load completed. Runtime never deletes cache files on failure:
				# prebake owns disk-cache ownership (Unreal StreamableManager /
				# Unity Addressables layer split). A failed load here is logged,
				# cached as null, and left for the next prebake pass to repair.
				# See docs/audit/MODEL_LOADER_RACE.md.
				var packed_scene := ResourceLoader.load_threaded_get(disk_path) as PackedScene
				phase_b_get_count += 1
				var cache_key: String = _pending_async_loads[disk_path].cache_key
				var callbacks: Array = _pending_async_loads[disk_path].callbacks

				if packed_scene == null:
					# Load returned null — cache miss, fire callbacks immediately
					# (no instantiate to defer).
					push_warning("ModelLoader: Async load returned null PackedScene: %s" % disk_path)
					_model_cache[cache_key] = null
					_last_access[cache_key] = Engine.get_frames_drawn()
					for cb_info: Dictionary in callbacks:
						var cb: Callable = cb_info.callback
						if cb.is_valid():
							cb.call(cb_info.model_path, cb_info.item_id, null)
					completed += 1
				else:
					# Defer instantiate to next frame. See _pending_instantiate_queue
					# field comment for the race this avoids.
					_pending_instantiate_queue.append({
						"disk_path": disk_path,
						"packed_scene": packed_scene,
						"cache_key": cache_key,
						"callbacks": callbacks,
					})

				to_remove.append(disk_path)

			ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
				# Load failed
				push_warning("ModelLoader: Async load failed for %s" % disk_path)
				var cache_key: String = _pending_async_loads[disk_path].cache_key
				_model_cache[cache_key] = null

				# Call callbacks with null
				for cb_info: Dictionary in _pending_async_loads[disk_path].callbacks:
					var cb: Callable = cb_info.callback
					if cb.is_valid():
						cb.call(cb_info.model_path, cb_info.item_id, null)

				to_remove.append(disk_path)
				completed += 1

			ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				# Still loading - do nothing
				pass

	# Remove completed loads
	for disk_path: String in to_remove:
		_pending_async_loads.erase(disk_path)

	var t_phase_b := Time.get_ticks_usec()

	# Drain deferred queue into freed slots
	var dd_budget_left: int = maxi(0, effective_budget - int(t_phase_b - t0))
	_drain_deferred_queue(dd_budget_left, MAX_DEFERRED_DRAIN_PER_FRAME)

	var t_dd := Time.get_ticks_usec()
	var ml_total: int = t_dd - t0
	if ml_total > 50_000:
		Log.warn("streaming", "[ml-spike %.1fms] phaseA=%.1f phaseB=%.1f dd=%.1f items_completed=%d phaseB_get=%d pending_instq=%d pending_async=%d deferred=%d" % [
			ml_total / 1000.0,
			float(t_phase_a - t0) / 1000.0,
			float(t_phase_b - t_phase_a) / 1000.0,
			float(t_dd - t_phase_b) / 1000.0,
			completed,
			phase_b_get_count,
			_pending_instantiate_queue.size(),
			_pending_async_loads.size(),
			_deferred_async_queue.size(),
		])

	_try_drain_requested_eviction()
	return completed


## Phase A of process_async_loads: cache the PackedScene and fire callbacks with
## fresh Node3D instances. Time-budgeted: stops when budget_usec is exhausted.
## Time is measured per item so variable-cost items (complex meshes) self-limit.
##
## Each callback receives a distinct Node3D instantiated from the shared PackedScene —
## no shared-instance hazard. PackedScene is cached for future sync get_model() calls.
##
## Returns count of entries processed this frame.
func _drain_pending_instantiate_queue(budget_usec: int) -> int:
	if _pending_instantiate_queue.is_empty():
		return 0

	var start_us := Time.get_ticks_usec()
	var completed := 0
	var i := 0

	while i < _pending_instantiate_queue.size():
		# Check budget before each item — one expensive instantiation can eat
		# the whole budget; we stop cleanly rather than overshooting.
		if Time.get_ticks_usec() - start_us >= budget_usec:
			break

		var entry: Dictionary = _pending_instantiate_queue[i]
		i += 1

		var cache_key: String = entry.cache_key
		var callbacks: Array = entry.callbacks

		# Fix E (streaming_stutter_2026_04_25 plan) — trust the threaded loader.
		# The previous code did a sync ResourceLoader.load(CACHE_MODE_REUSE)
		# here to "flush c2 sub-resource finalization", which produced 90-410 ms
		# disk= spikes per frame. Godot 4.6's load_threaded_get returns a fully
		# finalized resource when status is THREAD_LOAD_LOADED (verified against
		# the engine's resource_loader.cpp ResourceLoaderTaskState::done path —
		# the sub-resources are registered before the status flips to LOADED).
		var packed_scene := entry.packed_scene as PackedScene

		# Validate before caching — if can_instantiate() fails, cache null
		if packed_scene == null or not packed_scene.can_instantiate():
			if packed_scene != null:
				Log.warn("models", "async can_instantiate() false: %s" % (entry.disk_path as String).get_file())
			_model_cache[cache_key] = null
			for cb_info: Dictionary in callbacks:
				var cb: Callable = cb_info.callback
				if cb.is_valid():
					cb.call(cb_info.model_path, cb_info.item_id, null)
			completed += 1
			continue

		# Cache the PackedScene — subsequent get_model() calls instantiate from this
		_model_cache[cache_key] = packed_scene
		_last_access[cache_key] = Engine.get_frames_drawn()
		_get_or_create_resource_handle(cache_key, packed_scene)
		_stats["models_from_disk_async"] += 1
		_queue_eviction_if_over_budget()

		# Fix E (streaming_stutter_2026_04_25 plan) — peel callbacks under
		# the same budget. The previous code processed ALL callbacks of an
		# entry in one go, ignoring the budget. A popular prototype with 50+
		# refs ate 400 ms in a single "item" while the loop's outer budget
		# check still saw items_completed=1. Now we instantiate one ref at
		# a time and bail mid-entry when the budget runs out, preserving
		# unprocessed callbacks for the next frame.
		Log.debug("models", "instantiate %s" % entry.disk_path)
		var processed_callbacks: int = 0
		var entry_completed := true
		for cb_info: Dictionary in callbacks:
			if Time.get_ticks_usec() - start_us >= budget_usec:
				entry_completed = false
				break
			var cb: Callable = cb_info.callback
			if cb.is_valid():
				var instance: Node3D = null
				if bool(cb_info.get("instantiate_for_callback", true)):
					instance = _instantiate_from_scene(packed_scene)
				cb.call(cb_info.model_path, cb_info.item_id, instance)
			processed_callbacks += 1

		if not entry_completed:
			# Mid-entry budget exhaustion — re-park unprocessed callbacks
			# back on the entry so next frame picks them up. We slice off
			# the processed prefix; the entry stays in place at index
			# (i - 1) — i was already incremented past it. Rewind so the
			# loop slice at function exit doesn't drop it.
			entry.callbacks = callbacks.slice(processed_callbacks)
			i -= 1
			break

		completed += 1

	# Remove processed entries in one slice — avoids O(n²) per-item removal.
	if i > 0:
		_pending_instantiate_queue = _pending_instantiate_queue.slice(i)

	return completed


## Instantiate a PackedScene into a fresh Node3D.
## Strips occluders and disables all CollisionShape3D nodes
## (sets "collision_disabled" meta). Collision is re-enabled by the streaming manager
## when the object enters NEAR tier (<150m from camera).
##
## NOTE: _clear_resource_paths is intentionally NOT called here. That function
## mutates shared sub-resources (meshes, materials) which are shared between the
## PackedScene and all its instances. Clearing paths on an instance would corrupt
## the PackedScene's resource references for subsequent instantiate() calls.
## Path clearing was needed for the old .duplicate() approach; PackedScene handles
## resource resolution internally.
func _instantiate_from_scene(packed_scene: PackedScene) -> Node3D:
	if packed_scene == null or not packed_scene.can_instantiate():
		return null
	var instance := packed_scene.instantiate()
	if instance == null:
		return null
	if not instance is Node3D:
		instance.queue_free()
		return null
	_strip_occluders(instance)
	_disable_collision_shapes_in_tree(instance)
	return instance as Node3D


## Disable all CollisionShape3D nodes in a subtree and mark the root with
## "collision_disabled" meta. Mirror of NativeStreamingManager._disable_collision_shapes().
## Jolt bodies are registered with no shapes until NEAR-tier entry — this keeps
## the broadphase budget at zero for MID/FAR objects.
static func _disable_collision_shapes_in_tree(node: Node) -> void:
	if node is CollisionShape3D:
		(node as CollisionShape3D).disabled = true
	for child in node.get_children():
		_disable_collision_shapes_in_tree(child)
	if node is Node3D:
		(node as Node3D).set_meta("collision_disabled", true)


## Get count of pending async loads (in-flight + deferred + pending-instantiate)
func get_pending_async_count() -> int:
	return _pending_async_loads.size() + _deferred_async_queue.size() + _pending_instantiate_queue.size()


## Start deferred requests that were throttled by MAX_CONCURRENT_ASYNC_LOADS.
## Called each frame after completed loads are reaped, so freed slots get reused.
func _drain_deferred_queue(budget_usec: int = DRAIN_FALLBACK_BUDGET_USEC, max_entries: int = MAX_DEFERRED_DRAIN_PER_FRAME) -> int:
	if budget_usec <= 0 or max_entries <= 0:
		return 0
	var start_us := Time.get_ticks_usec()
	var processed := 0
	while not _deferred_async_queue.is_empty() and _pending_async_loads.size() < MAX_CONCURRENT_ASYNC_LOADS:
		if processed >= max_entries:
			break
		if Time.get_ticks_usec() - start_us >= budget_usec:
			break
		var entry: Dictionary = _deferred_async_queue.pop_back()
		processed += 1
		var disk_path: String = entry.disk_path
		var cache_key: String = entry.cache_key

		# Skip if model was loaded by another path while waiting in the queue
		if cache_key in _model_cache:
			var callback: Callable = entry.callback
			if callback.is_valid():
				var cached: Variant = _model_cache[cache_key]
				var instance: Node3D = null
				if bool(entry.get("instantiate_for_callback", true)) and cached != null:
					instance = _instantiate_from_scene(cached as PackedScene)
				callback.call(entry.model_path, entry.item_id, instance)
			continue

		# Skip if already in-flight (another request for the same model started)
		if disk_path in _pending_async_loads:
			var callback: Callable = entry.callback
			if callback.is_valid():
				_pending_async_loads[disk_path].callbacks.append({
					"callback": callback,
					"model_path": entry.model_path,
					"item_id": entry.item_id,
					"instantiate_for_callback": bool(entry.get("instantiate_for_callback", true)),
				})
			continue

		var err := ResourceLoader.load_threaded_request(disk_path, "PackedScene")
		if err != OK:
			var callback: Callable = entry.callback
			if callback.is_valid():
				callback.call(entry.model_path, entry.item_id, null)
			continue

		_pending_async_loads[disk_path] = {
			"cache_key": cache_key,
			"callbacks": [] as Array[Dictionary]
		}
		var callback: Callable = entry.callback
		if callback.is_valid():
			_pending_async_loads[disk_path].callbacks.append({
				"callback": callback,
				"model_path": entry.model_path,
				"item_id": entry.item_id,
				"instantiate_for_callback": bool(entry.get("instantiate_for_callback", true)),
			})
	return processed


## Cache a freshly converted Node3D (prebaking path only).
## Packs to PackedScene for memory cache; saves to disk if enabled.
## Parameters:
##   model_path: Path to cache under
##   model: The Node3D to pack and cache
##   item_id: Optional item ID for collision variations
func add_to_cache(model_path: String, model: Node3D, item_id: String = "") -> void:
	var normalized := model_path.to_lower().replace("/", "\\")
	var cache_key := normalized
	if not item_id.is_empty():
		cache_key = normalized + ":" + item_id.to_lower()

	if not model:
		_model_cache[cache_key] = null
		return

	var mesh_count := _count_meshes(model)

	# Save to disk first — _save_to_disk_cache strips occluders + sets owners
	if enable_disk_cache and mesh_count > 0:
		_save_to_disk_cache(model, cache_key)

	# Pack to PackedScene for memory cache (owners set by _save_to_disk_cache above,
	# or set manually if disk cache was skipped)
	if not enable_disk_cache or mesh_count == 0:
		_strip_occluders(model)
		_set_owner_recursive(model, model)
	var ps := PackedScene.new()
	if ps.pack(model) == OK:
		_model_cache[cache_key] = ps
		_get_or_create_resource_handle(cache_key, ps)
	else:
		_model_cache[cache_key] = null

	_last_access[cache_key] = Engine.get_frames_drawn()
	_stats["models_loaded"] += 1
	_evict_if_over_budget()


## Count MeshInstance3D nodes with valid meshes
func _count_meshes(node: Node) -> int:
	var count := 0
	if node is MeshInstance3D:
		var mesh_inst := node as MeshInstance3D
		if mesh_inst.mesh:
			count += 1
	for child in node.get_children():
		count += _count_meshes(child)
	return count


## Get a fresh Node3D from cache (doesn't load from disk if not cached).
## Returns null if not in cache or if cache entry is null.
## Parameters:
##   model_path: Path to retrieve
##   item_id: Optional item ID for collision variations
## Returns:
##   Fresh Node3D (collision disabled) or null if not cached
func get_cached(model_path: String, item_id: String = "") -> Node3D:
	var normalized := model_path.to_lower().replace("/", "\\")
	var cache_key := normalized
	if not item_id.is_empty():
		cache_key = normalized + ":" + item_id.to_lower()

	if cache_key in _model_cache:
		var cached: Variant = _model_cache[cache_key]
		if cached == null:
			return null
		_stats["models_from_cache"] += 1
		_last_access[cache_key] = Engine.get_frames_drawn()
		return _instantiate_from_scene(cached as PackedScene)
	return null


# =============================================================================
# DISK CACHE IMPLEMENTATION
# =============================================================================
# Saves converted Node3D scenes as PackedScene resources (.res files)
# This allows loading converted/imported models in 1-5ms instead of paying
# provider conversion cost during streaming.
# =============================================================================

## Get the disk cache directory (lazy initialization from SettingsManager)
func _get_disk_cache_dir() -> String:
	if _disk_cache_dir.is_empty():
		_disk_cache_dir = SettingsManager.get_models_path()
	return _disk_cache_dir


## Get the disk cache path for a cache key
## Converts cache_key to a valid filename and returns full path
## NOTE: Strips item_id suffix since prebaked models don't include it
## Public: resolve an ESM model path to its prebaked disk cache .res path.
## Returns empty string if the cache file doesn't exist. Used by Phase F
## static-collision paths without exposing private cache internals.
## Worker-safe: pure path math + FileAccess existence check.
func resolve_disk_path(model_path: String) -> String:
	var provider_path := _get_provider_resource_path(model_path)
	if not provider_path.is_empty():
		return provider_path
	var normalized := model_path.to_lower().replace("/", "\\")
	var disk_path := _get_disk_cache_path(normalized)
	if _cached_file_exists(disk_path):
		return disk_path
	return ""


## Public: resolve an ESM model path to its prebaked shape pack `.shapes.res`
## sidecar path. Returns empty string if the sidecar doesn't exist.
##
## Call from main thread only — mutates `_file_exists_cache`. Mirrors
## `resolve_disk_path` above: Phase F's main-thread dispatcher resolves the
## pack path before `StaticShapeCache.warm_from_path` loads it. The
## sidecar carries extracted CollisionShape3D data for the prototype; loading
## it avoids the 20-50ms PackedScene.instantiate that `StaticShapeCache.
## get_shapes` otherwise incurs on first sight.
func resolve_shape_pack_path(model_path: String) -> String:
	var normalized := model_path.to_lower().replace("/", "\\")
	var scene_path := _get_disk_cache_path(normalized)
	if scene_path.is_empty():
		return ""
	# _get_disk_cache_path always returns paths ending in ".res".
	# Pack sits alongside with ".shapes.res" suffix (see _save_shape_pack_to_disk).
	var pack_path := scene_path.get_basename() + ".shapes.res"
	if _cached_file_exists(pack_path):
		return pack_path
	return ""


func _get_disk_cache_path(cache_key: String) -> String:
	# Strip item_id suffix if present (e.g., "source/model/id:door_01" -> "source/model/id")
	var base_key := cache_key
	var colon_pos := cache_key.rfind(":")
	if colon_pos > 0:
		base_key = cache_key.substr(0, colon_pos)

	var safe_name := base_key.replace("\\", "_").replace("/", "_").replace(":", "_").replace(".", "_")
	var file_name := safe_name + ".res"

	# Priority 1: Check ModRegistry for mod-specific prebaked
	if _mod_registry:
		var mod := _mod_registry.resolve_mod_for_path(base_key)
		if mod and mod.has_prebaked:
			var mod_prebaked_path := mod.path.path_join("prebaked").path_join(file_name)
			if _cached_file_exists(mod_prebaked_path):
				return mod_prebaked_path

	# Priority 2: Standard vanilla prebaked cache
	return _get_disk_cache_dir().path_join(file_name)


## Load a PackedScene from disk. Does NOT instantiate — callers use _instantiate_from_scene().
## Prebake owns disk cache; runtime never deletes cache files on failure.
## See docs/audit/MODEL_LOADER_RACE.md.
func _load_packed_scene_from_disk(disk_path: String) -> PackedScene:
	if not FileAccess.file_exists(disk_path):
		return null
	var packed_scene := ResourceLoader.load(disk_path, "PackedScene") as PackedScene
	if not packed_scene:
		push_warning("ModelLoader: Sync load returned null PackedScene: %s" % disk_path)
		return null
	return packed_scene


## Remove OccluderInstance3D nodes from a loaded model.
## Cached .res files may contain occluders with corrupt BoxOccluder3D data
## that triggers "Parameter 'occluder' is null" errors on instantiate,
## corrupting renderer state and eventually causing signal 11 crashes.
## Occluders are optional performance hints — safe to strip.
func _strip_occluders(node: Node) -> void:
	var to_remove: Array[Node] = []
	for child in node.get_children():
		if child is OccluderInstance3D:
			to_remove.append(child)
		else:
			_strip_occluders(child)
	for child in to_remove:
		child.get_parent().remove_child(child)
		child.queue_free()


## Save a model to disk cache
## Saves each mesh as a separate .mesh file, then the scene structure as .res
func _save_to_disk_cache(node: Node3D, cache_key: String) -> void:
	if not node:
		return

	# Ensure cache directory exists
	var cache_dir := _get_disk_cache_dir()
	if not DirAccess.dir_exists_absolute(cache_dir):
		var err := DirAccess.make_dir_recursive_absolute(cache_dir)
		if err != OK:
			push_warning("ModelLoader: Failed to create cache directory: %s" % error_string(err))
			return

	var base_path := _get_disk_cache_path(cache_key).get_basename()

	# First, save all meshes as separate .mesh files and update references
	var mesh_count := _save_meshes_to_disk(node, base_path, 0)

	if mesh_count == 0:
		return  # Nothing to cache

	# Strip OccluderInstance3D BEFORE packing — cached .res files with corrupt
	# occluder data crash packed_scene.instantiate() at load time (sig 11).
	_strip_occluders(node)

	# CRITICAL: Set owner on all children so PackedScene.pack() includes them
	# Without this, pack() only saves the root node when not in scene tree
	_set_owner_recursive(node, node)

	# Now save the scene (meshes will be referenced by path)
	var scene_path := base_path + ".res"
	var packed_scene := PackedScene.new()
	var pack_result := packed_scene.pack(node)
	if pack_result != OK:
		push_warning("ModelLoader: Failed to pack scene: %s (%s)" % [cache_key, error_string(pack_result)])
		return

	var save_result := ResourceSaver.save(packed_scene, scene_path)
	if save_result != OK:
		push_warning("ModelLoader: Failed to save scene: %s (%s)" % [scene_path, error_string(save_result)])
	else:
		# Update file existence cache so subsequent checks don't hit disk
		_file_exists_cache[scene_path] = true
		_stats["models_saved"] += 1

		# T.6 sidecar — extracted collision shapes as a plain Resource, no scene
		# round-trip at load. Emitted here because the node is still alive with
		# CollisionShape3D descendants; StaticShapeCache then reads this directly
		# on Phase F worker and avoids the 20-50ms PackedScene.instantiate spike
		# during cell transition. See static_shape_pack.gd header.
		_save_shape_pack_to_disk(node, base_path)

		# Track first model for condensed logging
		if _first_saved_model.is_empty():
			_first_saved_model = cache_key.get_file()

		# Print condensed progress every 10 models
		if _stats["models_saved"] % 10 == 0:
			var count: int = _stats["models_saved"]
			if count == 10:
				Log.info("models", "Saved %s and 9 more models..." % _first_saved_model)
			else:
				Log.info("models", "Saved %d models (last: %s)" % [count, cache_key.get_file()])
			_last_save_report_count = count


## T.6 sidecar — write a `StaticShapePack` alongside the scene `.res`.
## Delegates to the static helper on `StaticShapePack` so the sibling
## prebake path in `model_prebaker._save_model_to_cache` can reuse the
## same extraction + save logic.
func _save_shape_pack_to_disk(node: Node3D, base_path: String) -> void:
	var result := StaticShapePackScript.save_from_node(node, base_path)
	if result == OK:
		# Keep the file-existence cache coherent so `resolve_shape_pack_path`
		# sees the new sidecar without a disk stat. Empty-entry prototypes
		# return OK without writing a file, so only cache when the path
		# actually exists.
		var pack_path := base_path + ".shapes.res"
		if FileAccess.file_exists(pack_path):
			_file_exists_cache[pack_path] = true


## Save all meshes in a node tree to disk and update their resource paths
## Returns count of meshes saved
func _save_meshes_to_disk(node: Node, base_path: String, start_idx: int) -> int:
	var count := start_idx

	if node is MeshInstance3D:
		var mesh_inst := node as MeshInstance3D
		if mesh_inst.mesh:
			var mesh_path := "%s_mesh_%d.mesh" % [base_path, count]
			var save_result := ResourceSaver.save(mesh_inst.mesh, mesh_path)
			if save_result == OK:
				# Update the mesh to point to the saved file
				mesh_inst.mesh.take_over_path(mesh_path)
				count += 1

	for child in node.get_children():
		count = _save_meshes_to_disk(child, base_path, count)

	return count


## Recursively set owner on all descendants for PackedScene.pack()
func _set_owner_recursive(node: Node, owner_node: Node) -> void:
	for child in node.get_children():
		child.owner = owner_node
		_set_owner_recursive(child, owner_node)


## Get disk cache statistics
## Returns Dictionary with:
##   cache_dir: Path to cache directory
##   file_count: Number of cached files
##   total_size_mb: Total size in MB
func get_disk_cache_stats() -> Dictionary:
	var cache_dir := _get_disk_cache_dir()
	var stats := {
		"cache_dir": cache_dir,
		"file_count": 0,
		"total_size_bytes": 0,
		"total_size_mb": 0.0
	}

	if not DirAccess.dir_exists_absolute(cache_dir):
		return stats

	var dir := DirAccess.open(cache_dir)
	if not dir:
		return stats

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".res"):
			stats["file_count"] += 1
			var file := FileAccess.open(cache_dir + "/" + file_name, FileAccess.READ)
			if file:
				stats["total_size_bytes"] += file.get_length()
				file.close()
		file_name = dir.get_next()
	dir.list_dir_end()

	stats["total_size_mb"] = stats["total_size_bytes"] / (1024.0 * 1024.0)
	return stats


## Check if a model is cached on disk
## Parameters:
##   model_path: Path to check
##   item_id: Optional item ID for collision variations
## Returns:
##   true if model is in disk cache
func has_disk_cached(model_path: String, item_id: String = "") -> bool:
	if _provider_has_model_resource(model_path, item_id):
		return true
	var normalized := model_path.to_lower().replace("/", "\\")
	var cache_key := normalized
	if not item_id.is_empty():
		cache_key = normalized + ":" + item_id.to_lower()
	var disk_path := _get_disk_cache_path(cache_key)
	return _cached_file_exists(disk_path)


# =============================================================================
# LOD LOADING API (SEPARATE FILES)
# =============================================================================
# LODs are prebaked as separate .lod.res files to enable on-demand loading.
# This reduces memory usage - NEAR tier objects don't load LOD meshes.
# LODs are only loaded when objects enter MID tier.
# =============================================================================

## Get LOD resource for a model (loads from disk if not cached)
## Returns LODResource or null if no LODs exist for this model
## Parameters:
##   model_path: Source model id or resource path
func get_lod_resource(model_path: String) -> LODResource:
	var normalized := model_path.to_lower().replace("/", "\\")

	# Check memory cache
	if normalized in _lod_cache:
		return _lod_cache[normalized]

	# Try to load from disk
	var lod_path := _get_lod_disk_path(normalized)
	if not _cached_file_exists(lod_path):
		# No LOD file exists - cache null to avoid repeated checks
		_lod_cache[normalized] = null
		return null

	var lod_res := ResourceLoader.load(lod_path, "Resource") as LODResource
	if not lod_res:
		# Failed to load - cache null
		_lod_cache[normalized] = null
		return null

	_lod_cache[normalized] = lod_res
	return lod_res


## Request async loading of LOD resource
## Returns immediately. Callback is called when load completes.
## Parameters:
##   model_path: Path to model
##   callback: Called with (model_path: String, lod_res: LODResource) - lod_res may be null
## Returns:
##   true if load was started or already cached
func request_lod_async(model_path: String, callback: Callable) -> bool:
	var normalized := model_path.to_lower().replace("/", "\\")

	# Check memory cache
	if normalized in _lod_cache:
		if callback.is_valid():
			callback.call(model_path, _lod_cache[normalized])
		return true

	# Check if file exists
	var lod_path := _get_lod_disk_path(normalized)
	if not _cached_file_exists(lod_path):
		_lod_cache[normalized] = null
		if callback.is_valid():
			callback.call(model_path, null)
		return false

	# Start async load
	var err := ResourceLoader.load_threaded_request(lod_path, "Resource")
	if err != OK:
		if callback.is_valid():
			callback.call(model_path, null)
		return false

	# Store callback for later (simplified - real impl would track pending)
	# For now, use sync callback in process_async_loads
	_pending_lod_loads[lod_path] = {
		"model_path": model_path,
		"normalized": normalized,
		"callback": callback
	}
	return true


## Pending LOD async loads
var _pending_lod_loads: Dictionary = {}


## Process pending LOD async loads - call every frame alongside process_async_loads()
## Returns number of loads completed
func process_lod_async_loads() -> int:
	if _pending_lod_loads.is_empty():
		return 0

	var completed := 0
	var to_remove: Array[String] = []

	for lod_path: String in _pending_lod_loads:
		var status := ResourceLoader.load_threaded_get_status(lod_path)

		match status:
			ResourceLoader.THREAD_LOAD_LOADED:
				var lod_res := ResourceLoader.load_threaded_get(lod_path) as LODResource
				var info: Dictionary = _pending_lod_loads[lod_path]
				_lod_cache[info.normalized] = lod_res

				if info.callback.is_valid():
					info.callback.call(info.model_path, lod_res)

				to_remove.append(lod_path)
				completed += 1

			ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
				var info: Dictionary = _pending_lod_loads[lod_path]
				_lod_cache[info.normalized] = null

				if info.callback.is_valid():
					info.callback.call(info.model_path, null)

				to_remove.append(lod_path)
				completed += 1

	for lod_path: String in to_remove:
		_pending_lod_loads.erase(lod_path)

	return completed


## Get disk path for LOD resource
func _get_lod_disk_path(normalized_path: String) -> String:
	var safe_name := normalized_path.replace("\\", "_").replace("/", "_").replace(":", "_").replace(".", "_")
	return _get_disk_cache_dir().path_join(safe_name + ".lod.res")


## Check if LOD resource exists on disk
func has_lod_cached(model_path: String) -> bool:
	var normalized := model_path.to_lower().replace("/", "\\")
	var lod_path := _get_lod_disk_path(normalized)
	return _cached_file_exists(lod_path)


## Clear LOD cache
func clear_lod_cache() -> void:
	_lod_cache.clear()
	_pending_lod_loads.clear()


## Set the mod registry for asset resolution
func set_mod_registry(registry: ModRegistry) -> void:
	_mod_registry = registry


func set_asset_provider(provider: RefCounted) -> void:
	_asset_provider = provider


func get_asset_provider() -> RefCounted:
	return _asset_provider
