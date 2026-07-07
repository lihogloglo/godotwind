## CellPreloader - velocity-extrapolated two-phase cell cache.
##
## Research doc §8. Fixes cell-cross pop-in at flight speeds by warming the
## ResourceLoader PackedScene cache for cells the camera is ABOUT to enter,
## one or more grid squares ahead of the current load radius.
##
## Two-phase model (§8.2):
##   DATA phase        - this class. ModelLoader async requests for cells in
##                       the predicted set. No Node3Ds created; no scene tree
##                       modification.
##   INSTANTIATION     - native_streaming_manager / cell_manager. Runs when
##                       the cell actually enters active load radius. Because
##                       DATA is already warm, instantiation is cache-hit
##                       fast-path.
##
## Replaces `native_streaming_manager._predict_and_prequeue_cells` (naive
## 1-cell-ahead predictor). Uses the canonical streaming-preloader
## pattern: speed-scaled lookahead, LRU cache, teleport abort.
##
## Ownership: owned by NativeStreamingManager. No autoload. `_process` calls
## `update(camera_cell, camera_pos, velocity_xz)` each frame; `teleport_happened`
## signal wires to `abort_all` + `reset`; `cell_loaded` wires to `notify_activated`.
class_name CellPreloader
extends RefCounted


const SC := preload("res://src/core/world/streaming_config.gd")
const DU := preload("res://src/core/world/distance_utils.gd")
const PipelineCompileMonitorScript := preload("res://src/core/diagnostics/pipeline_compile_monitor.gd")

## Per-frame budget when the caller passes no deadline (Phase 1, 2026-07-05).
## Bounds the model-warmup drain — request_model_async is main-thread file
## I/O, and unbudgeted per-cell bursts measured 53-60ms.
const DEFAULT_UPDATE_BUDGET_USEC: int = 1000


## One cached entry per unique cell grid. Transitions: loading -> ready ->
## activated. Evicted (dropped from _cache) on LRU expiry unless activated.
class PreloadEntry:
	extends RefCounted
	var cell: Vector2i
	var state: String = "loading"  # "kicking" | "loading" | "ready" | "activated"
	var last_touched_msec: int = 0
	## Debug / stat: model paths touched by this preload. Not used for logic.
	var model_paths: Array[String] = []
	## Model paths handed to ModelLoader.request_model_async without callback
	## instantiation. Ready once ModelLoader has cached every listed path.
	var pending_model_paths: Array[String] = []
	## Phase 1 slicing (2026-07-05): model paths not yet handed to the
	## ModelLoader. `request_model_async` does main-thread file I/O
	## (file_exists + load_threaded_request), so warming a dense cell's
	## 100+ unique models in one frame cost 50-60ms — the preloader is
	## ahead-of-time by design, so the warmup drains a few paths per frame
	## under the update() deadline instead.
	var unwarmed_paths: Array[String] = []


var _cache: Dictionary = {}  # Vector2i -> PreloadEntry

# Injected dependencies: WeakRefs so teardown cleans itself if the streaming
# manager is freed before the preloader.
var _model_loader_ref: WeakRef = null  # ModelLoader
var _world_object_source: RefCounted = null
var _coordinate_mapper: RefCounted = null
var _warned_missing_world_object_source: bool = false

var _current_anchor_cell: Vector2i = Vector2i.ZERO
var _debug_enabled: bool = false

## Phase 2 stutter diag: pipeline compile delta monitor injected by
## NativeStreamingManager. Logs MESH/SURFACE/DRAW deltas at LOADING -> READY
## transition so we can verify whether ResourceLoader.load triggers
## engine-side pipeline pre-compile (plan §2.2). null = monitor disabled.
var _pipeline_compile_monitor: PipelineCompileMonitorScript = null

# Stats (read by streaming manager for heartbeat)
var stats: Dictionary = {
	"preloads_kicked": 0,
	"preloads_ready": 0,
	"preloads_activated": 0,
	"evictions": 0,
	"cache_hits_on_load": 0,
}


## Wire dependencies. Call once from native_streaming_manager.configure().
func configure(model_loader: RefCounted) -> void:
	_model_loader_ref = weakref(model_loader) if model_loader != null else null


func set_world_object_source(source: RefCounted) -> void:
	_world_object_source = source


func set_coordinate_mapper(mapper: RefCounted) -> void:
	_coordinate_mapper = mapper


func set_debug(enabled: bool) -> void:
	_debug_enabled = enabled


## Phase 2 stutter diag: wire a per-preload pipeline compile delta tracker.
## Called from NativeStreamingManager.configure(). null = no logging.
func set_pipeline_compile_monitor(monitor: PipelineCompileMonitorScript) -> void:
	_pipeline_compile_monitor = monitor


## Main per-frame tick. Called from `native_streaming_manager._process` after
## startup completes. Walks the predicted cell set, kicks preloads for new
## entries, polls in-flight tasks for promotion, evicts expired entries.
##
## camera_cell - current grid position (Vector2i)
## camera_pos - world position (only used for Z-up alignment if needed)
## velocity_xz - planar velocity, Vector2(x, z) m/s (Godot convention)
func update(camera_cell: Vector2i, camera_pos: Vector3, velocity_xz: Vector2, deadline_usec: int = 0) -> void:
	_current_anchor_cell = camera_cell
	var now_msec: int = Time.get_ticks_msec()
	if deadline_usec <= 0:
		deadline_usec = Time.get_ticks_usec() + DEFAULT_UPDATE_BUDGET_USEC

	# 1. Compute predicted cells from velocity (§8.3 speed-scaled lookahead).
	var predicted: Array[Vector2i] = _compute_predicted_cells(camera_cell, velocity_xz)

	# 2. Kick preloads for cells not already in cache; touch existing entries.
	for cell: Vector2i in predicted:
		if cell in _cache:
			(_cache[cell] as PreloadEntry).last_touched_msec = now_msec
		else:
			_begin_preload(cell, now_msec)

	# 2b. Phase 1 slicing: drain a few unwarmed model paths per frame under
	# the deadline. The prediction window is 0.3-4s, so spreading a cell's
	# warmup over many frames costs nothing in effective latency.
	_process_kicking_entries(deadline_usec)

	# 3. Promote LOADING -> READY for entries with all tasks done.
	_poll_completions()

	# 4. Evict entries older than EXPIRY_DELAY_MS, subject to MIN_CACHE_CELLS.
	_evict_expired(now_msec)


## Mark a cell as activated; streaming manager owns it now. Preloader stops
## evicting it. Called from native_streaming_manager when the cell enters
## active radius / `cell_loaded` signal.
func notify_activated(cell: Vector2i) -> void:
	if cell in _cache:
		var entry: PreloadEntry = _cache[cell]
		if entry.state == "ready":
			stats["cache_hits_on_load"] += 1
		entry.state = "activated"
		stats["preloads_activated"] += 1


## Called by streaming manager when a cell is unloaded (cell_unloaded signal).
## Drops the entry so it can be re-preloaded later if the camera returns.
func notify_unloaded(cell: Vector2i) -> void:
	if cell in _cache:
		_drain_and_erase(cell)


## True if the cell's DATA phase has completed (ResourceLoader warm + prereg
## dispatched). Streaming manager can use this to branch on fast vs slow path.
func is_ready(cell: Vector2i) -> bool:
	return cell in _cache and (_cache[cell] as PreloadEntry).state == "ready"


## Snapshot of cache state (read-only, for diagnostics).
func get_stats_snapshot() -> Dictionary:
	var loading: int = 0
	var ready: int = 0
	var activated: int = 0
	for cell: Vector2i in _cache:
		match (_cache[cell] as PreloadEntry).state:
			"loading": loading += 1
			"ready": ready += 1
			"activated": activated += 1
	return {
		"size": _cache.size(),
		"loading": loading,
		"ready": ready,
		"activated": activated,
		"preloads_kicked": stats.preloads_kicked,
		"preloads_ready": stats.preloads_ready,
		"preloads_activated": stats.preloads_activated,
		"evictions": stats.evictions,
		"cache_hits_on_load": stats.cache_hits_on_load,
	}


## Abort every in-flight preload and clear the cache. Called from the
## `teleport_happened` handler in native_streaming_manager; an in-flight
## preload for a cell the camera just jumped away from is wasted work and
## blocks the worker pool from serving the actual destination's preloads.
##
## Research §8.8 mirrors the canonical `abortTerrainPreloadExcept` pattern.
func abort_all() -> void:
	_cache.clear()


## Post-teleport re-anchor. Call AFTER abort_all().
func reset(new_anchor: Vector2i) -> void:
	_current_anchor_cell = new_anchor


## Shutdown hook: clear. Called from native_streaming_manager fast_cleanup.
func drain_all() -> void:
	abort_all()


# ----------------------------------------------------------------------------
# Internals
# ----------------------------------------------------------------------------


## Compute which cells to preload given current velocity. §8.3 formula:
##   t_predict  = clamp(t_cache_warm / max(speed, 1.0), 0.3, 4.0)
##   depth      = clamp(int(speed / CELL_SIZE_METERS * t_cache_warm) + 1, 1, 4)
## Below 2 m/s return empty; no velocity means no prediction signal.
func _compute_predicted_cells(camera_cell: Vector2i, velocity_xz: Vector2) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var speed_sq: float = velocity_xz.length_squared()
	if speed_sq < 4.0:  # < 2 m/s = standing still or drifting
		return result

	var speed: float = sqrt(speed_sq)
	var t_cache_warm: float = SC.PRELOAD_PREDICTION_TIME_S
	# Multi-cell depth for fast movement. At walk (5 m/s): depth=1.
	# At flight (50 m/s): depth=1 (1s window). At creative fly (200 m/s): depth=2.
	var depth: int = clampi(
		int(speed / _cell_size_meters() * t_cache_warm) + 1,
		1,
		4,
	)

	var vel_dir: Vector2 = velocity_xz.normalized()
	# Velocity XZ -> grid (x, y): Godot +Z is grid -Y (ESM coordinate flip).
	for d: int in range(1, depth + 1):
		var off_x: int = int(round(vel_dir.x * d))
		var off_y: int = int(round(-vel_dir.y * d))
		if off_x == 0 and off_y == 0:
			continue
		var target: Vector2i = Vector2i(camera_cell.x + off_x, camera_cell.y + off_y)
		if target not in result and target != camera_cell:
			result.append(target)
		# For multi-cell depth, also include the axis-aligned neighbors of the
		# deepest cell so diagonal movement warms the cells the camera will
		# actually cross (cell corners vs edges).
		if d == depth and off_x != 0 and off_y != 0:
			var axis_x: Vector2i = Vector2i(camera_cell.x + off_x, camera_cell.y)
			var axis_y: Vector2i = Vector2i(camera_cell.x, camera_cell.y + off_y)
			if axis_x not in result and axis_x != camera_cell:
				result.append(axis_x)
			if axis_y not in result and axis_y != camera_cell:
				result.append(axis_y)
	return result


func _cell_size_meters() -> float:
	if _coordinate_mapper != null and _coordinate_mapper.has_method("get_cell_size_meters"):
		return float(_coordinate_mapper.call("get_cell_size_meters"))
	return DU.CELL_SIZE_METERS


## Kick the DATA phase for a cell: ask the injected object source for records,
## then warm every unique model_path in the cell. No Node3Ds are created here;
## the main thread only schedules ModelLoader's bounded async lane.
func _begin_preload(cell: Vector2i, now_msec: int) -> void:
	# Back-pressure: stop preloading when the cache is already at max. Eviction
	# catches up on subsequent frames.
	if _cache.size() >= SC.PRELOAD_MAX_CACHE_CELLS:
		return

	var entry: PreloadEntry = PreloadEntry.new()
	entry.cell = cell
	entry.state = "loading"
	entry.last_touched_msec = now_msec
	_cache[cell] = entry
	stats["preloads_kicked"] += 1

	var model_loader: Object = _model_loader_ref.get_ref() if _model_loader_ref != null else null
	if model_loader == null or not model_loader.has_method("request_model_async"):
		entry.state = "ready"
		stats["preloads_ready"] += 1
		return
	if _world_object_source == null or not _world_object_source.has_method("get_objects_in_cell"):
		if _debug_enabled and not _warned_missing_world_object_source:
			print("[CellPreloader] no WorldObjectSource configured; preload warmup is a no-op")
		_warned_missing_world_object_source = true
		entry.state = "ready"
		stats["preloads_ready"] += 1
		return
	# Collect the unique model paths now (record fetch is manifest-cached and
	# useful work regardless), but hand them to the ModelLoader incrementally —
	# each request_model_async does main-thread file I/O.
	var records: Array = _world_object_source.call("get_objects_in_cell", cell)
	var seen: Dictionary = {}
	for record: RefCounted in records:
		var mp := str(record.get("model_path"))
		if mp.is_empty():
			continue
		var key := mp.to_lower()
		if key in seen:
			continue
		seen[key] = true
		entry.model_paths.append(mp)
		entry.unwarmed_paths.append(mp)
	if _debug_enabled:
		print("[CellPreloader] preload kick cell=", cell, " paths=", entry.model_paths.size())
	if entry.unwarmed_paths.is_empty():
		entry.state = "ready"
		stats["preloads_ready"] += 1
	else:
		entry.state = "kicking"


## Phase 1 slicing: feed unwarmed model paths to the ModelLoader under the
## frame deadline. Processes entries in cache order; each path is one
## request_model_async call (file_exists + load_threaded_request — the
## expensive atoms this slicing exists to spread out).
func _process_kicking_entries(deadline_usec: int) -> void:
	var model_loader: Object = _model_loader_ref.get_ref() if _model_loader_ref != null else null
	if model_loader == null:
		return
	for cell: Vector2i in _cache:
		var entry: PreloadEntry = _cache[cell]
		if entry.state != "kicking":
			continue
		while not entry.unwarmed_paths.is_empty():
			if Time.get_ticks_usec() >= deadline_usec:
				return
			var mp: String = entry.unwarmed_paths.pop_back()
			var queued: bool = bool(model_loader.call("request_model_async", mp, "", Callable(), false))
			if queued:
				entry.pending_model_paths.append(mp)
		entry.state = "loading"
		if entry.pending_model_paths.is_empty():
			entry.state = "ready"
			stats["preloads_ready"] += 1
		if Time.get_ticks_usec() >= deadline_usec:
			return


## Promote LOADING -> READY when all requested models are cached.
func _poll_completions() -> void:
	var model_loader: Object = _model_loader_ref.get_ref() if _model_loader_ref != null else null
	for cell: Vector2i in _cache:
		var entry: PreloadEntry = _cache[cell]
		if entry.state != "loading":
			continue
		var all_done: bool = true
		if model_loader != null and model_loader.has_method("has_model"):
			for mp: String in entry.pending_model_paths:
				if not bool(model_loader.call("has_model", mp, "")):
					all_done = false
					break
		if all_done:
			entry.state = "ready"
			stats["preloads_ready"] += 1
			if _debug_enabled:
				print("[CellPreloader] cell=", cell, " READY (pending=", entry.pending_model_paths.size(), ")")
			# Phase 2 stutter diag: pipeline compile delta over the preload
			# window. If MESH/SURFACE > 0 here, ResourceLoader.load triggered
			# engine pre-compile (good, we're done). If 0 here BUT non-zero on
			# the matching cell_loaded log line, pre-compile fires only at
			# instantiate, and we need hidden-instance pre-warm. Plan §2.2.
			if _pipeline_compile_monitor != null:
				var d: PackedInt64Array = _pipeline_compile_monitor.delta_and_update()
				if PipelineCompileMonitorScript.has_activity(d):
					Log.info("streaming", "[pipe-preload %s] paths=%d %s" % [
						cell, entry.model_paths.size(),
						PipelineCompileMonitorScript.format_delta(d),
					])


## Evict stale entries. Never drops below MIN_CACHE_CELLS even if all are
## stale. `activated` entries are permanently skipped; the streaming manager
## owns them; the preloader releases on `notify_unloaded`.
func _evict_expired(now_msec: int) -> void:
	if _cache.size() <= SC.PRELOAD_MIN_CACHE_CELLS:
		return

	var to_evict: Array[Vector2i] = []
	for cell: Vector2i in _cache:
		var entry: PreloadEntry = _cache[cell]
		if entry.state == "activated":
			continue
		if now_msec - entry.last_touched_msec > SC.PRELOAD_EXPIRY_DELAY_MS:
			to_evict.append(cell)

	for cell: Vector2i in to_evict:
		if _cache.size() <= SC.PRELOAD_MIN_CACHE_CELLS:
			break
		_drain_and_erase(cell)


## Remove a single cell from the preload cache.
func _drain_and_erase(cell: Vector2i) -> void:
	if cell not in _cache:
		return
	_cache.erase(cell)
	stats["evictions"] += 1


## (autopsy 2026-04-25; see plan §12.3 Class B).
## Plan: docs/plans/distant_rendering_2026_04/cell_transition_stutter_phase2.md §12.6 / Fix C.1.
