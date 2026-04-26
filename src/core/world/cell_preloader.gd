## CellPreloader — velocity-extrapolated two-phase cell cache.
##
## Research doc §8. Fixes cell-cross pop-in at flight speeds by warming the
## ResourceLoader PackedScene cache + dispatching Phase F prototype
## pre-registration for cells the camera is ABOUT to enter, one or more grid
## squares ahead of the current load radius.
##
## Two-phase model (§8.2):
##   DATA phase        — this class. Off-thread ResourceLoader.load() +
##                       preregister_cell_statics for cells in the predicted
##                       set. No Node3Ds created; no scene tree modification.
##   INSTANTIATION     — native_streaming_manager / cell_manager. Runs when
##                       the cell actually enters active load radius. Because
##                       DATA is already warm, instantiation is cache-hit
##                       fast-path.
##
## Replaces `native_streaming_manager._predict_and_prequeue_cells` (naive
## 1-cell-ahead predictor). OpenMW's `CellPreloader` is the canonical
## reference: speed-scaled lookahead, LRU cache, teleport abort.
##
## Ownership: owned by NativeStreamingManager. No autoload. `_process` calls
## `update(camera_cell, camera_pos, velocity_xz)` each frame; `teleport_happened`
## signal wires to `abort_all` + `reset`; `cell_loaded` wires to `notify_activated`.
class_name CellPreloader
extends RefCounted


const SC := preload("res://src/core/world/streaming_config.gd")
const DU := preload("res://src/core/world/distance_utils.gd")
const PipelineCompileMonitorScript := preload("res://src/core/diagnostics/pipeline_compile_monitor.gd")


## One cached entry per unique cell grid. Transitions: loading → ready →
## activated. Evicted (dropped from _cache) on LRU expiry unless activated.
class PreloadEntry:
	extends RefCounted
	var cell: Vector2i
	var state: String = "loading"  # "loading" | "ready" | "activated"
	var last_touched_msec: int = 0
	## WorkerThreadPool task IDs dispatched by this entry. The eviction path
	## previously called wait_for_task_completion on each — that blocked the
	## main thread for 100-750ms when many cells evicted simultaneously
	## (autopsy 2026-04-25, plan §12). New pattern: cooperative cancellation.
	## Workers check `cancelled` and self-bail; main thread never blocks.
	## RefCounted lifetime guarantees no leak — bound `entry` keeps the
	## RefCount > 0 while any worker is still executing.
	var task_ids: Array[int] = []
	## Cooperative-cancellation flag. Set true by main thread when the entry
	## is evicted / aborted. Workers check this BEFORE doing the load and
	## early-return if true. GDScript bool reads/writes are atomic on the
	## platforms we target (x86_64 / arm64) — no mutex needed.
	var cancelled: bool = false
	## Debug / stat: model paths touched by this preload. Not used for logic.
	var model_paths: Array[String] = []


var _cache: Dictionary = {}  # Vector2i -> PreloadEntry

# Injected dependencies — WeakRefs so teardown cleans itself if the streaming
# manager is freed before the preloader.
var _instantiator_ref: WeakRef = null  # ReferenceInstantiator
var _model_loader_ref: WeakRef = null  # ModelLoader

var _current_anchor_cell: Vector2i = Vector2i.ZERO
var _debug_enabled: bool = false

## Phase 2 stutter diag — pipeline compile delta monitor injected by
## NativeStreamingManager. Logs MESH/SURFACE/DRAW deltas at LOADING→READY
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
func configure(instantiator: RefCounted, model_loader: RefCounted) -> void:
	_instantiator_ref = weakref(instantiator) if instantiator != null else null
	_model_loader_ref = weakref(model_loader) if model_loader != null else null


func set_debug(enabled: bool) -> void:
	_debug_enabled = enabled


## Phase 2 stutter diag — wire a per-preload pipeline compile delta tracker.
## Called from NativeStreamingManager.configure(). null = no logging.
func set_pipeline_compile_monitor(monitor: PipelineCompileMonitorScript) -> void:
	_pipeline_compile_monitor = monitor


## Main per-frame tick. Called from `native_streaming_manager._process` after
## startup completes. Walks the predicted cell set, kicks preloads for new
## entries, polls in-flight tasks for promotion, evicts expired entries.
##
## camera_cell   — current grid position (Vector2i)
## camera_pos    — world position (only used for Z-up alignment if needed)
## velocity_xz   — planar velocity, Vector2(x, z) m/s (Godot convention)
func update(camera_cell: Vector2i, camera_pos: Vector3, velocity_xz: Vector2) -> void:
	_current_anchor_cell = camera_cell
	var now_msec: int = Time.get_ticks_msec()

	# 1. Compute predicted cells from velocity (§8.3 speed-scaled lookahead).
	var predicted: Array[Vector2i] = _compute_predicted_cells(camera_cell, velocity_xz)

	# 2. Kick preloads for cells not already in cache; touch existing entries.
	for cell: Vector2i in predicted:
		if cell in _cache:
			(_cache[cell] as PreloadEntry).last_touched_msec = now_msec
		else:
			_begin_preload(cell, now_msec)

	# 3. Promote LOADING → READY for entries with all tasks done.
	_poll_completions()

	# 4. Evict entries older than EXPIRY_DELAY_MS, subject to MIN_CACHE_CELLS.
	_evict_expired(now_msec)


## Mark a cell as activated — streaming manager owns it now. Preloader stops
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
## `teleport_happened` handler in native_streaming_manager — an in-flight
## preload for a cell the camera just jumped away from is wasted work and
## blocks the worker pool from serving the actual destination's preloads.
##
## Research §8.8 — mirrors OpenMW's `abortTerrainPreloadExcept`.
##
## Cooperative-cancellation: each entry's `cancelled` flag is set, workers
## self-bail on next ResourceLoader.load entry. No `wait_for_task_completion`
## (autopsy 2026-04-25 showed eviction blocked main thread up to 750 ms;
## plan §12.6 / Fix C.1 replaces with coop-cancel). Memory safety guaranteed
## by the bound `entry` arg keeping RefCount > 0 until each worker exits.
func abort_all() -> void:
	for cell: Vector2i in _cache:
		_drain_entry(_cache[cell] as PreloadEntry)
	_cache.clear()


## Post-teleport re-anchor. Call AFTER abort_all().
func reset(new_anchor: Vector2i) -> void:
	_current_anchor_cell = new_anchor


## Shutdown hook — drain + clear. Called from native_streaming_manager
## fast_cleanup (WM_CLOSE_REQUEST) BEFORE worker-pool teardown to prevent the
## shutdown-race sig 11 class (same pattern as Phase F's drain_prereg_tasks).
func drain_all() -> void:
	abort_all()


# ----------------------------------------------------------------------------
# Internals
# ----------------------------------------------------------------------------


## Compute which cells to preload given current velocity. §8.3 formula:
##   t_predict  = clamp(t_cache_warm / max(speed, 1.0), 0.3, 4.0)
##   depth      = clamp(int(speed / CELL_SIZE_METERS * t_cache_warm) + 1, 1, 4)
## Below 2 m/s return empty — no velocity means no prediction signal.
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
		int(speed / DU.CELL_SIZE_METERS * t_cache_warm) + 1,
		1,
		4,
	)

	var vel_dir: Vector2 = velocity_xz.normalized()
	# Velocity XZ → grid (x, y): Godot +Z is grid -Y (ESM coordinate flip).
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


## Kick the DATA phase for a cell: look up the ESM record, dispatch Phase F
## prereg for STAT refs, dispatch ResourceLoader.load workers for every
## unique model_path in the cell. All off-thread; main thread only schedules.
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

	# ESMManager is an autoload — main-thread safe. An empty / out-of-bounds
	# grid returns null; mark as ready immediately (no work to do).
	var cell_record: Variant = null
	if ESMManager != null:
		cell_record = ESMManager.call("get_exterior_cell", cell.x, cell.y)
	if cell_record == null:
		entry.state = "ready"
		stats["preloads_ready"] += 1
		return

	# Fix A (streaming_stutter_2026_04_25 plan): the previous prereg call here
	# was a 832 ms main-thread spike. preregister_cell_statics → has_animation
	# → get_model is sync ResourceLoader.load + PackedScene.instantiate per
	# unique prototype. The preloader's contract is ResourceLoader cache
	# warming only; pre-registration belongs to the active loader, which calls
	# preregister_cell_statics from cell_manager.request_exterior_cell_async.
	# Speculative prereg duplicated that work on every cell the camera might
	# enter. Deleted.

	# Warm ResourceLoader cache for every unique model_path in the cell — one
	# worker task per unique disk_path. Main-thread cost: one ESM lookup per
	# ref (bounded, ~50–150/cell). Worker cost: ResourceLoader.load (thread-
	# safe per research §2.1).
	var model_loader: Object = _model_loader_ref.get_ref() if _model_loader_ref != null else null
	if model_loader == null or not model_loader.has_method("resolve_disk_path"):
		return

	var seen: Dictionary = {}  # normalized_path -> true
	for ref: CellReference in cell_record.references:
		var rec_type: Array = [""]
		var base: Variant = ESMManager.get_any_record(str(ref.ref_id), rec_type)
		if base == null or not "model" in base:
			continue
		var mp: String = base.model
		if mp.is_empty():
			continue
		var key: String = mp.to_lower()
		if key in seen:
			continue
		seen[key] = true
		entry.model_paths.append(mp)

		var disk_path: String = model_loader.call("resolve_disk_path", mp)
		if disk_path.is_empty():
			continue

		# LOW priority — we're ahead of the instantiation queue. Don't starve
		# Phase A/E/F tasks racing to feed the actual load.
		# Bind `entry` so workers can check `entry.cancelled` and self-bail
		# when main thread evicts. The bind also keeps entry RefCount > 0
		# until every worker exits, guaranteeing cancelled-flag validity
		# without any explicit wait. Plan §12.6 / Fix C.1.
		var task_id: int = WorkerThreadPool.add_task(
			_worker_warm_resource.bind(disk_path, entry),
			false,  # high_priority = false
			"cell_preloader:warm",
		)
		entry.task_ids.append(task_id)

	if _debug_enabled:
		print("[CellPreloader] preload kick cell=", cell, " tasks=", entry.task_ids.size(), " paths=", entry.model_paths.size())


## Worker body — off-thread PackedScene load. ResourceLoader.load is
## thread-safe per research §2.1; cached entries are shared across threads.
##
## Cooperative cancellation (plan §12.6 / Fix C.1): main thread sets
## `entry.cancelled = true` when evicting; we check before doing the IO and
## bail. ResourceLoader.load itself can't be interrupted mid-IO, so once we
## START loading we run to completion — but the result then sits in the
## ResourceLoader cache (harmless: identical to a normal preload-hit on a
## future re-visit) and we drop our reference. Net cost on cancellation: at
## most ONE extra load for any in-flight worker, vs the previous up-to-750ms
## main-thread block on n_evicted × n_tasks.
# PHASE_G:WORKER_SAFE — zero autoload / signal / scene-tree access. The
# `entry` arg is a RefCounted; we read entry.cancelled (atomic bool read)
# but never write to entry from the worker.
static func _worker_warm_resource(disk_path: String, entry: PreloadEntry) -> void:
	if entry.cancelled:
		return
	ResourceLoader.load(disk_path, "PackedScene")


## Promote LOADING → READY when all worker tasks are complete.
func _poll_completions() -> void:
	for cell: Vector2i in _cache:
		var entry: PreloadEntry = _cache[cell]
		if entry.state != "loading":
			continue
		var all_done: bool = true
		for tid: int in entry.task_ids:
			if not WorkerThreadPool.is_task_completed(tid):
				all_done = false
				break
		if all_done:
			entry.state = "ready"
			stats["preloads_ready"] += 1
			if _debug_enabled:
				print("[CellPreloader] cell=", cell, " READY (tasks=", entry.task_ids.size(), ")")
			# Phase 2 stutter diag — pipeline compile delta over the preload
			# window. If MESH/SURFACE > 0 here → ResourceLoader.load triggered
			# engine pre-compile (good, we're done). If 0 here BUT non-zero on
			# the matching cell_loaded log line → pre-compile fires only at
			# instantiate, and we need hidden-instance pre-warm. Plan §2.2.
			if _pipeline_compile_monitor != null:
				var d: PackedInt64Array = _pipeline_compile_monitor.delta_and_update()
				if PipelineCompileMonitorScript.has_activity(d):
					Log.info("streaming", "[pipe-preload %s] tasks=%d paths=%d %s" % [
						cell, entry.task_ids.size(), entry.model_paths.size(),
						PipelineCompileMonitorScript.format_delta(d),
					])


## Evict stale entries. Never drops below MIN_CACHE_CELLS even if all are
## stale. `activated` entries are permanently skipped — the streaming manager
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


## Remove + drain a single cell. Marks workers as cancelled (cooperative)
## and erases from cache immediately — no main-thread blocking.
func _drain_and_erase(cell: Vector2i) -> void:
	if cell not in _cache:
		return
	_drain_entry(_cache[cell] as PreloadEntry)
	_cache.erase(cell)
	stats["evictions"] += 1


## Shared drain helper — cooperative cancellation only. Sets the entry's
## cancelled flag so workers self-bail; clears the task_ids list so the
## entry's RefCount drops to whatever the workers still hold; returns
## immediately without blocking. The previous implementation called
## `WorkerThreadPool.wait_for_task_completion` for every task, which
## blocked the main thread for 100-750ms when many cells evicted at once
## (autopsy 2026-04-25 — see plan §12.3 Class B).
##
## Why no leak: the worker's bound `entry` argument keeps RefCount > 0
## until the worker function returns. Worker reads cancelled, returns,
## drops its bind ref, RC reaches 0, entry frees normally.
##
## Why safe: `entry.cancelled` writes from main thread + reads from
## worker thread on a single bool. GDScript bool reads/writes are
## word-atomic on x86_64 / arm64. No torn read possible.
##
## Plan: docs/plans/distant_rendering_2026_04/cell_transition_stutter_phase2.md §12.6 / Fix C.1.
func _drain_entry(entry: PreloadEntry) -> void:
	entry.cancelled = true
	entry.task_ids.clear()
