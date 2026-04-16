## ModelLoader - Handles NIF model loading and caching
##
## Extracted from CellManager for single responsibility.
## Loads models from BSA archives, converts them to Godot scenes,
## and caches them for reuse.
##
## Supports TWO levels of caching:
## 1. Memory cache: Fast, per-session (lost on restart)
## 2. Disk cache: Persistent, saves converted models as .res files
##
## Disk caching dramatically improves loading times after first run:
## - First run: 300ms-6s per complex model (NIF conversion)
## - Subsequent runs: 1-5ms per model (direct resource load)
##
## Usage:
##   var loader = ModelLoader.new()
##   loader.enable_disk_cache = true  # Enable persistent caching
##   var model = loader.get_model("meshes\\x\\ex_door.nif")
##   var model_with_collision = loader.get_model("meshes\\x\\ex_door.nif", "ex_door_01")
class_name ModelLoader
extends RefCounted

const LODResource := preload("res://src/core/world/lod_resource.gd")

## Maximum number of prototypes kept in memory cache
## When exceeded, least-recently-accessed entries are evicted to 80% capacity
const MAX_CACHE_SIZE := 500

## Maximum concurrent ResourceLoader.load_threaded_request calls in flight.
## Godot 4.6's internal resource loader can segfault (c0000005) when hammered
## with hundreds of concurrent threaded load requests during heavy startup.
const MAX_CONCURRENT_ASYNC_LOADS := 16

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

## Cache for loaded LOD resources: model_path (lowercase) -> LODResource
var _lod_cache: Dictionary = {}

## The mod registry for asset resolution
var _mod_registry: ModRegistry = null

## Enable disk caching of converted models (saves as .res files)
## Set to true to persist converted models between game sessions
var enable_disk_cache: bool = true

## RUNTIME MODE: Only load from disk cache, never convert NIFs
## When true (default for world explorer), models not in disk cache return null
## When false (prebaking mode), missing models trigger NIF conversion
var runtime_mode: bool = true

## Directory for disk cache (set from SettingsManager on first use)
## Defaults to Documents/Godotwind/cache/models/
var _disk_cache_dir: String = ""

## Cache for file existence checks to avoid repeated disk I/O
## Maps disk_path -> bool (exists or not)
## This eliminates repeated FileAccess.file_exists() calls which are slow
var _file_exists_cache: Dictionary = {}

## Pending async load requests: disk_path -> {cache_key: String, callbacks: Array[Callable]}
## Multiple requests for the same model share one load operation
var _pending_async_loads: Dictionary = {}

## Deferred async requests waiting for a slot (throttled by MAX_CONCURRENT_ASYNC_LOADS)
## Each entry: {disk_path: String, cache_key: String, callback: Callable, model_path: String, item_id: String}
var _deferred_async_queue: Array[Dictionary] = []

## Deferred instantiate queue. Async pipeline fills this; drain uses sync
## re-load (CACHE_MODE_IGNORE) to bypass the c2 sub-resource race.
## Each entry: {disk_path: String, packed_scene: PackedScene, cache_key: String, callbacks: Array[Dictionary]}
var _pending_instantiate_queue: Array[Dictionary] = []

## Statistics
var _stats: Dictionary = {
	"models_loaded": 0,
	"models_from_cache": 0,
	"models_from_disk": 0,
	"models_from_disk_async": 0,
	"file_exists_cache_hits": 0,
	"models_saved": 0,
}

## Track first saved model for condensed logging
var _first_saved_model: String = ""
var _last_save_report_count: int = 0


## Get or load a model prototype
## Returns cached model if available, loads and converts from BSA if not.
## With disk caching enabled, converted models are saved for instant loading next time.
##
## Parameters:
##   model_path: Path to NIF model (e.g., "meshes\\x\\ex_door.nif")
##   item_id: Optional ESM record ID for collision shape library lookup
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
		return _instantiate_from_scene(cached as PackedScene)

	# 2. Check disk cache if enabled (fast - direct resource load)
	if enable_disk_cache:
		var disk_path := _get_disk_cache_path(cache_key)
		if _cached_file_exists(disk_path):
			var packed_scene := _load_packed_scene_from_disk(disk_path)
			if packed_scene:
				_model_cache[cache_key] = packed_scene
				_last_access[cache_key] = Engine.get_frames_drawn()
				_stats["models_from_disk"] += 1
				_evict_if_over_budget()
				return _instantiate_from_scene(packed_scene)

	# 3. RUNTIME MODE: Return null for uncached models (no NIF conversion at runtime)
	# NIF conversion should ONLY happen during prebaking, never during gameplay
	if runtime_mode:
		# Cache null to avoid repeated disk checks
		_model_cache[cache_key] = null
		return null

	# 4. PREBAKING MODE ONLY: Fall back to BSA extraction + NIF conversion
	# This path is only used by prebaking tools, never during world exploration
	var full_path := model_path
	if not model_path.to_lower().begins_with("meshes"):
		full_path = "meshes\\" + model_path

	# Try to load from BSA - check first to avoid error spam
	var nif_data := PackedByteArray()
	if BSAManager.has_file(full_path):
		nif_data = BSAManager.extract_file(full_path)
	elif BSAManager.has_file(model_path):
		nif_data = BSAManager.extract_file(model_path)

	if nif_data.is_empty():
		# Only warn once per model, don't spam
		if not cache_key in _model_cache:
			push_warning("ModelLoader: Model not found in BSA: '%s' (tried meshes\\ prefix too)" % model_path)
		_model_cache[cache_key] = null
		return null

	# Convert NIF to Godot scene with item_id for collision shape lookup
	# NOTE: This only runs during prebaking, not at runtime
	const NIFConverter := preload("res://src/core/nif/nif_converter.gd")
	var converter := NIFConverter.new()
	converter.generate_lods = true  # LODs embedded in model for MID tier MultiMesh
	converter.generate_occluders = false  # Occluders handled separately
	converter.load_animations = true  # Include NIF keyframe animations in prebaked .res
	if not item_id.is_empty():
		converter.collision_item_id = item_id
	var node := converter.convert_buffer(nif_data, full_path)

	if not node:
		# Only warn once per failed model
		if not cache_key in _model_cache:
			push_warning("ModelLoader: Failed to convert NIF: '%s'" % full_path)
		_model_cache[cache_key] = null
		return null

	# 5. Save to disk cache for next time. _save_to_disk_cache strips occluders and
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
	_model_cache.clear()
	_last_access.clear()
	_file_exists_cache.clear()
	_stats["models_loaded"] = 0
	_stats["models_from_cache"] = 0
	_stats["models_from_disk"] = 0
	_stats["file_exists_cache_hits"] = 0


## Evict least-recently-accessed cache entries if over budget
## Evicts down to 80% of MAX_CACHE_SIZE to avoid evicting every frame
func _evict_if_over_budget() -> void:
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
	for entry: Array in entries:
		if _model_cache.size() <= target_size:
			break
		var key: String = entry[1]
		_model_cache.erase(key)
		_last_access.erase(key)
		evicted += 1

	if evicted > 0:
		if not _stats.has("lru_evictions"):
			_stats["lru_evictions"] = 0
		_stats["lru_evictions"] += evicted
		Log.debug("streaming", "LRU evicted %d prototypes (cache: %d/%d)" % [evicted, _model_cache.size(), MAX_CACHE_SIZE])


## Cached file existence check - avoids repeated disk I/O
## Results are cached for the session lifetime since prebaked files don't change
func _cached_file_exists(path: String) -> bool:
	if path in _file_exists_cache:
		_stats["file_exists_cache_hits"] += 1
		return _file_exists_cache[path]

	var exists := FileAccess.file_exists(path)
	_file_exists_cache[path] = exists
	return exists


## Invalidate file existence cache for a specific path or all paths
## Call after rebaking assets or when disk cache changes
func invalidate_file_cache(path: String = "") -> void:
	if path.is_empty():
		_file_exists_cache.clear()
		Log.info("models", "File existence cache cleared")
	else:
		_file_exists_cache.erase(path)


## Get statistics about model loading
## Returns:
##   Dictionary with keys: models_loaded, models_from_cache, models_from_disk, models_from_disk_async, etc.
func get_stats() -> Dictionary:
	return {
		"models_loaded": _stats["models_loaded"],
		"models_from_cache": _stats["models_from_cache"],
		"models_from_disk": _stats["models_from_disk"],
		"models_from_disk_async": _stats["models_from_disk_async"],
		"models_saved": _stats["models_saved"],
		"pending_async_loads": _pending_async_loads.size(),
		"cached_models": _model_cache.size(),
		"max_cache_size": MAX_CACHE_SIZE,
		"lru_evictions": _stats.get("lru_evictions", 0),
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
##   model_path: Path to NIF model
##   item_id: Optional item ID for collision variations
##   callback: Called when load completes with (model_path: String, item_id: String, model: Node3D)
## Returns:
##   true if load was started or model already cached, false if not in disk cache
func request_model_async(model_path: String, item_id: String = "", callback: Callable = Callable()) -> bool:
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
			var instance: Node3D = _instantiate_from_scene(cached as PackedScene) if cached != null else null
			callback.call(model_path, item_id, instance)
		return true

	# 2. Check if already loading this model
	var disk_path := _get_disk_cache_path(cache_key)
	if disk_path in _pending_async_loads:
		# Already loading - add callback to existing request
		if callback.is_valid():
			_pending_async_loads[disk_path].callbacks.append({
				"callback": callback,
				"model_path": model_path,
				"item_id": item_id
			})
		return true

	# 3. Check disk cache exists
	if not enable_disk_cache or not _cached_file_exists(disk_path):
		# Not in disk cache - in runtime mode this means model isn't prebaked
		if runtime_mode:
			_model_cache[cache_key] = null  # Cache miss
			if callback.is_valid():
				callback.call(model_path, item_id, null)
		return false

	# 4. Throttle: defer if too many concurrent loads in flight
	if _pending_async_loads.size() >= MAX_CONCURRENT_ASYNC_LOADS:
		_deferred_async_queue.append({
			"disk_path": disk_path,
			"cache_key": cache_key,
			"callback": callback,
			"model_path": model_path,
			"item_id": item_id
		})
		return true  # Will be started later by _drain_deferred_queue

	# 5. Start async load
	var err := ResourceLoader.load_threaded_request(disk_path, "PackedScene")
	if err != OK:
		push_warning("ModelLoader: Failed to start async load for %s: %s" % [disk_path, error_string(err)])
		if callback.is_valid():
			callback.call(model_path, item_id, null)
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
			"item_id": item_id
		})

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
	# Phase A: instantiate within budget.
	var effective_budget := budget_usec if budget_usec > 0 else DRAIN_FALLBACK_BUDGET_USEC
	var completed := _drain_pending_instantiate_queue(effective_budget)

	if _pending_async_loads.is_empty() and _deferred_async_queue.is_empty():
		return completed
	if _pending_async_loads.is_empty():
		_drain_deferred_queue()
		return completed

	var to_remove: Array[String] = []

	# Phase B: poll in-flight loads, defer instantiate for next frame.
	for disk_path: String in _pending_async_loads:
		var status := ResourceLoader.load_threaded_get_status(disk_path)

		match status:
			ResourceLoader.THREAD_LOAD_LOADED:
				# Load completed. Runtime never deletes cache files on failure:
				# prebake owns disk-cache ownership (Unreal StreamableManager /
				# Unity Addressables layer split). A failed load here is logged,
				# cached as null, and left for the next prebake pass to repair.
				# See docs/audit/MODEL_LOADER_RACE.md.
				var packed_scene := ResourceLoader.load_threaded_get(disk_path) as PackedScene
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

	# Drain deferred queue into freed slots
	_drain_deferred_queue()

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

		var packed_scene: PackedScene = entry.packed_scene
		var cache_key: String = entry.cache_key
		var callbacks: Array = entry.callbacks

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
		_stats["models_from_disk_async"] += 1
		_evict_if_over_budget()

		# Each callback gets its own fresh instance (distinct Node3D, collision disabled)
		for cb_info: Dictionary in callbacks:
			var cb: Callable = cb_info.callback
			if cb.is_valid():
				var instance := _instantiate_from_scene(packed_scene)
				cb.call(cb_info.model_path, cb_info.item_id, instance)

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
func _drain_deferred_queue() -> void:
	while not _deferred_async_queue.is_empty() and _pending_async_loads.size() < MAX_CONCURRENT_ASYNC_LOADS:
		var entry: Dictionary = _deferred_async_queue.pop_back()
		var disk_path: String = entry.disk_path
		var cache_key: String = entry.cache_key

		# Skip if model was loaded by another path while waiting in the queue
		if cache_key in _model_cache:
			var callback: Callable = entry.callback
			if callback.is_valid():
				var cached: Variant = _model_cache[cache_key]
				var instance: Node3D = _instantiate_from_scene(cached as PackedScene) if cached != null else null
				callback.call(entry.model_path, entry.item_id, instance)
			continue

		# Skip if already in-flight (another request for the same model started)
		if disk_path in _pending_async_loads:
			var callback: Callable = entry.callback
			if callback.is_valid():
				_pending_async_loads[disk_path].callbacks.append({
					"callback": callback,
					"model_path": entry.model_path,
					"item_id": entry.item_id
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
				"item_id": entry.item_id
			})


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
# This allows loading models in 1-5ms instead of 300ms-6s for NIF conversion.
# =============================================================================

## Get the disk cache directory (lazy initialization from SettingsManager)
func _get_disk_cache_dir() -> String:
	if _disk_cache_dir.is_empty():
		_disk_cache_dir = SettingsManager.get_models_path()
	return _disk_cache_dir


## Get the disk cache path for a cache key
## Converts cache_key to a valid filename and returns full path
## NOTE: Strips item_id suffix since prebaked models don't include it
func _get_disk_cache_path(cache_key: String) -> String:
	# Strip item_id suffix if present (e.g., "meshes\x\ex_door.nif:door_01" -> "meshes\x\ex_door.nif")
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
##   model_path: Path to model (e.g., "meshes\\x\\ex_door.nif")
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
