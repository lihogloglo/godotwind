## NativeStreamingManager - Simplified World Streaming using Godot Native Features
##
## This replaces the complex WorldStreamingManager + DistanceTierManager + ObjectStreamer
## architecture with a clean implementation using Godot's native visibility_range.
##
## PHILOSOPHY:
## The engine is the visibility authority. We set visibility_range properties once per
## object and let Godot handle LOD transitions, culling, and crossfades in C++.
##
## WHAT THIS CLASS DOES:
## - Coordinates cell loading via CellManager
## - Spawns objects with native visibility_range properties
## - Manages impostor rendering for FAR tier
## - Provides simple public API for world streaming
##
## WHAT THE ENGINE DOES (zero GDScript overhead):
## - Distance culling via visibility_range_begin/end
## - LOD transitions via visibility_range_fade_mode
## - Frustum culling (automatic)
## - Hysteresis via visibility_range_*_margin
##
## Lines of code: ~1,200 (vs ~2,235 in old WorldStreamingManager)
class_name NativeStreamingManager
extends Node3D

## Static singleton instance for easy access without Autoload
static var instance: NativeStreamingManager = null

const DU := preload("res://src/core/world/distance_utils.gd")
const SC := preload("res://src/core/world/streaming_config.gd")
const StreamingProfilerScript := preload("res://src/core/world/streaming_profiler.gd")
const CellManagerScript := preload("res://src/core/world/cell_manager.gd")
const ModelLoaderScript := preload("res://src/core/world/model_loader.gd")
const CrashBreadcrumb := preload("res://src/core/logging/crash_breadcrumb.gd")
const NativeImpostorRendererScript := preload("res://src/core/world/native_impostor_renderer.gd")
const ImpostorCandidatesScript := preload("res://src/core/world/impostor_candidates.gd")
const MeshVisibilityUtils := preload("res://src/core/world/mesh_visibility_utils.gd")
const CS := preload("res://src/core/coordinate_system.gd")
const BackgroundProcessorScript := preload("res://src/core/streaming/background_processor.gd")
const StaticObjectRendererScript := preload("res://src/core/world/static_object_renderer.gd")
const DistantLightManagerScript := preload("res://src/core/world/distant_light_manager.gd")
const ObjectPagingScript := preload("res://src/core/world/object_paging.gd")
const CellPreloaderScript := preload("res://src/core/world/cell_preloader.gd")
const PipelineCompileMonitorScript := preload("res://src/core/diagnostics/pipeline_compile_monitor.gd")
# MidTierBatchPool removed — per-instance RS visibility_range in StaticObjectRenderer
# replaces the broken MultiMesh approach (see docs/STREAMING_FIX_PLAN.md)

#region Signals

## Emitted when a cell starts loading
signal cell_loading(grid: Vector2i)

## Emitted when a cell finishes loading
signal cell_loaded(grid: Vector2i, object_count: int)

## Emitted when a cell is unloaded
signal cell_unloaded(grid: Vector2i)

## Emitted when streaming stats are updated
signal stats_updated(stats: Dictionary)

## Emitted during startup phase with loading progress (0-100)
## Allows parent (e.g., world_explorer) to show loading UI
signal startup_progress(progress: float, loaded_cells: int, total_cells: int, queued_objects: int)

## Emitted when startup phase completes
signal startup_complete()

## Phase 8 — fires on the same frame `_teleport_detected` becomes true
## (camera jumped > TELEPORT_DETECT_THRESHOLD = 500 m between two
## frames). Arguments describe the jump so consumers can classify it
## (e.g. fast-travel vs respawn vs debug teleport). Paired with
## LoadingStateMachine to show the fade-to-black overlay during the
## post-teleport streaming burst.
signal teleport_happened(from_position: Vector3, to_position: Vector3, distance: float)

#endregion


#region Configuration

## Radius (in cells) to keep loaded around camera.
## 1 = 3×3 grid = 9 cells (OpenMW `exterior cell load distance=1` default,
## matches NEAR-tier visible footprint of ~150 m at CELL=117 m).
## See docs/plans/distant_rendering_2026_04/near_tier_refactor.md §8.1 #1.
@export var load_radius_cells: int = 1

## Maximum distance at which to load cells (in meters)
## Cells beyond this are never loaded, even if within radius
## 800m is reasonable default; increase for powerful GPUs (up to ~2000m)
@export var max_load_distance: float = 800.0

## Whether to use native visibility_range (should always be true)
@export var use_native_visibility: bool = true

## Enable debug logging
@export var debug_enabled: bool = false

## Time budget per frame for loading (ms)
## Uses StreamingConfig.INSTANTIATION_BUDGET_MS as the single source of truth
@export var frame_budget_ms: float = SC.INSTANTIATION_BUDGET_MS

## Enable async loading (uses CellManager's async API)
## When disabled, falls back to synchronous loading
@export var async_loading_enabled: bool = true

## Radius for impostors (cells) - radius around camera where impostors are generated
## 60 cells * 117m ~= 7km default; increase to 100 for whole-island (may impact FPS)
@export var impostor_radius_cells: int = 60

## View distance in cells (alias for load_radius_cells, backwards compatibility)
@export var view_distance_cells: int = 1:
	set(value):
		view_distance_cells = value
		load_radius_cells = value

## Enable/disable distant rendering (backwards compatibility)
## Controls impostor rendering
@export var distant_rendering_enabled: bool = true:
	set(value):
		distant_rendering_enabled = value
		if _impostor_renderer:
			_impostor_renderer.set_process(value)

#endregion


#region Internal State

## Static object renderer for MID-tier + flora (RenderingServer direct, no Node3D)
## Now with per-instance LOD visibility_range (replaces broken MultiMesh batch pool)
var _static_renderer: StaticObjectRendererScript = null


## Native Impostor Renderer
var _impostor_renderer: Node3D = null

## Impostor candidates manager
var _impostor_candidates: RefCounted = null

## Loaded cells: grid -> Node3D container
var _loaded_cells: Dictionary = {}

## Cells currently being loaded (async)
var _loading_cells: Dictionary = {}

## Async request tracking: grid -> request_id
var _async_requests: Dictionary[Vector2i, int] = {}

## Pending cells to load (priority queue, sorted farthest-first so pop_back gets nearest)
var _pending_load_queue: Array[Vector2i] = []
## O(1) membership check for pending queue (mirrors _pending_load_queue contents)
var _pending_load_set: Dictionary[Vector2i, bool] = {}

## Cells being gradually unloaded: grid -> Node3D (hidden, children being removed over frames)
var _unloading_cells: Dictionary[Vector2i, Node3D] = {}
var _unloading_hold_frames: Dictionary[Vector2i, int] = {}
## Per-bible 2026-05-01 §"Cleanup Order" + auditor2 finding (chat msg 40):
## reclaim is valid only BEFORE destructive cleanup begins. This flag flips to
## true the first frame `_process_budgeted_unloading` does any destructive work
## on the grid (first child queue_free OR first RS instance hide). Once frozen,
## reclaim is rejected and the cell drains to completion; a fresh load runs
## after the cell exits `_unloading_cells`. Cleared when the cell finalizes.
var _unloading_frozen: Dictionary[Vector2i, bool] = {}
const MAX_LIFECYCLE_EVENTS := 256
var debug_lifecycle_capture_enabled: bool = false
var _lifecycle_events: Array[Dictionary] = []
var _lifecycle_event_write_index: int = 0

## Verification-only hook for stress tests that need a deterministic
## unload-limbo reclaim window. Default 0 keeps production behavior.
var debug_unload_limbo_hold_frames: int = 0

## Verification-only hook for stress tests that need to deterministically
## widen the destructive-cleanup window so the boomerang route can actually
## attempt reclaim before destruction begins. When > 0, the budgeted unloader
## holds off on child queue_free + RS hide for that many frames per grid
## after the grid enters `_unloading_cells`. Default 0 keeps production
## behavior. Counter decrements once per `_process_budgeted_unloading` frame.
var debug_unload_destructive_hold_frames: int = 0
## Per-grid remaining destructive hold (frames). Initialized from
## `debug_unload_destructive_hold_frames` at `_unload_cell` time.
var _unloading_destructive_holds: Dictionary[Vector2i, int] = {}

## Request IDs of cells currently in unload-container limbo. Canonical
## state-reversal pattern (UE5 World Partition, OpenMW UnrefQueue): keep the
## async request alive while the cell sits in limbo so reclaim can reverse
## the transition without losing in-flight instantiation work. Moved out of
## `_async_requests` at `_unload_cell` time; moved BACK to `_async_requests`
## at reclaim time; finalized via `cell_manager.finalize_unloaded_cell()`
## when the cell drains to empty in `_process_budgeted_unloading`.
## Fix landed 2026-04-19 for the missing-objects-on-return bug.
var _unloading_request_ids: Dictionary[Vector2i, int] = {}

## Hidden container for cells being unloaded (keeps them out of rendering)
var _unload_container: Node3D = null

## I.6 — orphan registry for nodes that must survive cell unload
## (held / carried items, future: dropped items, NPC corpses, etc.).
## Persistent across cell unloads. Keyed by registered node → entry
## struct holding origin grid + timestamps so Phase 2 can re-home on
## cell reload and expire stale orphans per the §13 Q7 bound policy.
## Per `docs/INTERACTION_SYSTEM.md` §9 ownership note: this is a child
## of NativeStreamingManager, NOT a fourth singleton. Registration API
## is `register_persistent_node()` / `unregister_persistent_node()`.
var _orphan_container: Node3D = null
# Untyped Dictionary intentional — typed `Dictionary[Node3D, ...]` crashes
# the iterator if a key has been freed (Godot 4.6 strict typed dict
# validation). Lazy pruning via `is_instance_valid` requires us to iterate
# past possibly-freed keys, which only the untyped dict allows.
var _persistent_nodes: Dictionary = {}

# I.6 Phase 2 — bound policy tuning. Spec §13 Q7: orphans expire after
# 5 min OR once the player has walked 8 cells away (whichever first).
# Both limits are applied conservatively — the first to trip wins, so
# a long session doesn't leak memory and a quick walk-away doesn't
# trap the item if the player teleports across the map.
const ORPHAN_EXPIRY_MS: int = 5 * 60 * 1000        # 5 minutes wall time
const ORPHAN_EXPIRY_CELL_DISTANCE: int = 8          # Chebyshev cells
# Prune tick rate — we don't need per-frame checks. 1 Hz is plenty
# because neither expiry condition is latency-sensitive.
const ORPHAN_PRUNE_INTERVAL_S: float = 1.0
var _orphan_prune_accum: float = 0.0

## Phase 2 persistent-node entry. Holds the origin grid (re-home key
## on cell reload), creation timestamp (wall-clock expiry), and last-
## known player grid at registration (walk-away expiry). Inner class so
## it's trivially constructable and type-checked.
class PersistentNodeEntry:
	var original_grid: Vector2i
	var created_ms: int
	var last_known_player_grid: Vector2i

## Background processor for async NIF parsing
var _background_processor: BackgroundProcessorScript = null

## Container node for all cell content
var _world_container: Node3D = null

## Cell manager for loading cells
var _cell_manager: CellManagerScript = null

## Phase 3 (2026-04-22) — velocity-extrapolated cell preloader. Warms the
## ResourceLoader PackedScene cache + dispatches Phase F prototype prereg for
## cells the camera is heading toward. Owned here; wired to `teleport_happened`
## (abort_all + reset) and `cell_loaded` / `cell_unloaded` signals.
var _cell_preloader: CellPreloaderScript = null

## Phase 2 stutter diag (2026-04-25) — RenderingServer pipeline compile counter
## delta tracker. Three usage sites: (a) heartbeat for steady-state rate, (b)
## per-cell-load delta on cell_loaded.emit, (c) per-preload-completion delta in
## CellPreloader._poll_completions. The (b) vs (c) split tells us whether
## ResourceLoader.load alone triggers MESH/SURFACE pre-compile or whether
## explicit instantiation is required (§2.2/§2.3 of phase 2 plan).
var _pipeline_compile_monitor: PipelineCompileMonitorScript = null
## Per-cell-load delta tracker — independent baseline from heartbeat so the
## delta on cell_loaded reflects only the cell-load window, not the 5s slice.
var _pipeline_compile_per_cell: PipelineCompileMonitorScript = null

## Current camera position
var _camera_position: Vector3 = Vector3.ZERO

## Current camera cell
var _camera_cell: Vector2i = Vector2i.ZERO

## Tracked camera node
var _camera: Camera3D = null

## Statistics
var _stats: Dictionary = {
	"loaded_cells": 0,
	"total_objects": 0,
	"load_time_ms": 0.0,
	"mid_to_near_promotions": 0,
	"near_to_mid_demotions": 0,
}

## Whether the manager has been initialized
var _initialized: bool = false

## Frame budget overrun tracking
var _frame_overrun_count: int = 0
var _last_overrun_log_frame: int = 0

## Per-frame phase timing (usec) — set every frame, readable by benchmark/profiler.
## Indices: 0=unload, 1=async_complete, 2=instantiate, 3=promote,
## 4=collision, 5=deferred, 6=queue, 7=cell_update, 8=static_cull
var _last_phase_times: PackedFloat64Array = PackedFloat64Array()
var _last_frame_total_ms: float = 0.0

## Startup phase state - controls staggered loading during initial population
var _startup_phase: bool = true
var _startup_frames: int = 0
const STARTUP_PHASE_FRAMES: int = 20  # ~0.33 seconds at 60 FPS — matches exit condition

## Phase 7 finish (2026-04-17) — teleport detection.
## A camera translation between consecutive _process frames larger than
## TELEPORT_DETECT_THRESHOLD re-enters the startup burst mode (aggressive
## 25ms instantiation budget, higher HLOD merge throughput) so the post-
## teleport ring loads without the ~50 FPS steady-state budget caps.
## Threshold = 500m matches ObjectPaging.TELEPORT_THRESHOLD so both
## systems enter warmup in lockstep.
const TELEPORT_DETECT_THRESHOLD: float = 500.0
var _teleport_detected: bool = false  ## Consumed by _process to re-arm startup mode

## Deferred impostor update — set when camera cell changes, processed next frame
## Prevents impostor scan (170ms+ on first call) from stacking with cell load/unload
var _impostor_update_pending: bool = false

## Distant light manager — billboard sprites for lights beyond NEAR tier (150m–5km)
var _distant_light_manager: DistantLightManager = null

## Runtime HLOD merger — cell-level merged meshes for 300-1000m range (OpenMW-style)
var _hlod_merger: ObjectPagingScript = null

## Sun elevation in radians (set externally by world_explorer via set_sun_elevation)
var _sun_elevation_rad: float = 0.5  # Default: daytime

## Predictive loading — pre-queue cells in the camera's movement direction
var _prev_camera_position: Vector3 = Vector3.ZERO
var _camera_velocity_xz: Vector2 = Vector2.ZERO  # EMA-smoothed, XZ plane only

## HLOD needs initial population on first frame after startup
var _hlod_needs_initial_update: bool = true

## Queue drain tracker: time when loading screen hid (startup_complete), 0 = not yet fired
var _post_startup_start_ms: int = 0
## Whether we've logged the queue-empty event post startup (one-shot)
var _queue_drain_logged: bool = false
## Accumulator for post-startup audit logging (seconds since last log)
var _post_startup_audit_accum: float = 0.0
## Tracks whether camera crossed a cell boundary this frame
var _cell_changed_this_frame: bool = false

## DIAGNOSTIC (2026-04-15, silent-crash pin): heartbeat emitter. Log tail
## distinguishes silent native death from clean shutdown: if the last line of
## the log is recent-ish and has no `heartbeat` suffix, the main thread froze
## or the process was killed between heartbeats. Interval is coarse (5 s) —
## crash resolution still relies on per-instantiate sentinels.
var _last_heartbeat_sec: int = -1
var _last_heartbeat_frame: int = -1

## Per-phase profiler. Created lazily on first access when SC.ENABLE_PROFILING is true.
## External consumers (benchmark, debug overlay) read via get_profiler().
var _profiler: StreamingProfilerScript = null

#endregion


#region Initialization

## Fast cleanup for quit — frees only RS resources, skips slow node tree ops
## Called from world_explorer's _do_fast_quit() before get_tree().quit()
func fast_cleanup() -> void:
	# Stop and drain background work before dropping task-bound state.
	if _background_processor:
		_background_processor.drain_all()

	# Phase 3 — drain CellPreloader BEFORE the cell_manager drain. The preloader
	# owns its own WorkerThreadPool warm tasks (ResourceLoader.load); they must
	# finish before static_renderer.clear() runs and before the WTP itself is
	# torn down. Same shutdown-race shape as Phase F; same remedy.
	if _cell_preloader:
		_cell_preloader.drain_all()

	# Phase F — drain in-flight prototype pre-registration workers BEFORE
	# clearing the static renderer. Without this, workers mid-`register_from_
	# prototype` hold pointers into `_mesh_types` that `_static_renderer.clear()`
	# frees, producing the shutdown sig 11 cluster flagged by @builder in the
	# Phase F review. Bounded: < 50 pending tasks × ~20ms worst case = < 1s.
	if _cell_manager:
		_cell_manager.fast_cleanup()

	# Free GPU resources (RS RIDs)
	if _static_renderer:
		_static_renderer.clear()
	if _impostor_renderer and _impostor_renderer.has_method("fast_cleanup"):
		_impostor_renderer.fast_cleanup()
	elif _impostor_renderer and _impostor_renderer.has_method("clear"):
		_impostor_renderer.clear()
	if _distant_light_manager:
		_distant_light_manager.cleanup()
		_distant_light_manager = null
	if _hlod_merger:
		_hlod_merger.cleanup()
		_hlod_merger = null


func _exit_tree() -> void:
	if instance == self:
		instance = null

	# If quitting, fast_cleanup() already freed everything — bail immediately
	if Engine.has_meta("_quitting"):
		return

	# Force-clear RS instances first (before cell tree cleanup)
	# StaticObjectRenderer holds thousands of RenderingServer RIDs that must be freed
	if _static_renderer:
		_static_renderer.clear()

	# Clear tracking dictionaries — let Godot's tree cleanup handle the Node3D children
	# Manually freeing thousands of nodes in _exit_tree causes a long freeze
	# and Godot produces misleading "leaked dependency" warnings from ordering issues
	_unloading_cells.clear()
	_unloading_hold_frames.clear()
	_unloading_frozen.clear()
	_unloading_destructive_holds.clear()
	_pending_rs_hide_cells.clear()
	_pending_rs_hide_set.clear()
	_pending_rs_cleanup_cells.clear()
	_pending_rs_cleanup_set.clear()
	_lifecycle_events.clear()
	_lifecycle_event_write_index = 0
	_loaded_cells.clear()


func _ready() -> void:
	instance = self

	# Phase 8 — LoadingStateMachine pauses SceneTree during boot and big
	# teleports, but the streaming pipeline HAS TO keep loading cells
	# during that pause (otherwise the ring never completes and the
	# predicate never returns true). PROCESS_MODE_ALWAYS keeps this
	# node's _process firing regardless of tree.paused state. Gameplay
	# nodes (player controller, NPCs, physics bodies) stay on the
	# default PAUSABLE so they freeze as expected.
	process_mode = Node.PROCESS_MODE_ALWAYS

	# Create world container
	_world_container = Node3D.new()
	_world_container.name = "WorldContainer"
	add_child(_world_container)

	# Create hidden container for cells being gradually unloaded
	_unload_container = Node3D.new()
	_unload_container.name = "UnloadContainer"
	_unload_container.visible = false
	add_child(_unload_container)

	# I.6 — orphan registry container. Persistent across cell unloads.
	# Visible (held items rendered through this parent when cell unloads
	# mid-hold). Per `docs/INTERACTION_SYSTEM.md` §9 — owned by streaming
	# manager, NOT a separate autoload.
	_orphan_container = Node3D.new()
	_orphan_container.name = "OrphanedCarriedItems"
	add_child(_orphan_container)

	# Create static object renderer for MID-tier objects and flora
	# Uses RenderingServer directly — no Node3D overhead for distant objects
	_static_renderer = StaticObjectRendererScript.new()
	_static_renderer.name = "StaticRenderer"
	add_child(_static_renderer)

	# NOTE: MidTierBatchPool removed — StaticObjectRenderer now handles MID-tier
	# with per-instance RS visibility_range (see STREAMING_FIX_PLAN.md)

	# Create impostor renderer (renamed to match old API)
	_impostor_renderer = NativeImpostorRendererScript.new()
	_impostor_renderer.name = "ImpostorManager"  # Use old name for backwards compatibility
	add_child(_impostor_renderer)

	# Create impostor candidates helper
	_impostor_candidates = ImpostorCandidatesScript.new()
	_impostor_renderer.set_impostor_candidates(_impostor_candidates)

	# Create background processor for async loading
	_background_processor = BackgroundProcessorScript.new()
	_background_processor.name = "BackgroundProcessor"
	add_child(_background_processor)

	# Create distant light manager for billboard lights beyond NEAR tier
	_distant_light_manager = DistantLightManagerScript.new()
	_distant_light_manager.setup(_world_container)

	# Create runtime HLOD merger for cell-level merged meshes (300-1000m)
	_hlod_merger = ObjectPagingScript.new()


## Initialize the streaming manager
## cell_manager: CellManager instance for loading cell data
## camera: Camera3D to track for streaming
func initialize(cell_manager: CellManagerScript, camera: Camera3D = null) -> Error:
	if _initialized:
		return OK

	if not cell_manager:
		push_error("[NativeStreamingManager] cell_manager is required")
		return ERR_INVALID_PARAMETER

	_cell_manager = cell_manager
	_cell_manager._static_renderer = _static_renderer
	_cell_manager._sync_instantiator_config()
	_camera = camera

	# Phase 3 (2026-04-22) — CellPreloader. Depends on the instantiator (for
	# preregister_cell_statics) + model_loader (for resolve_disk_path). Both
	# are owned by cell_manager.
	_cell_preloader = CellPreloaderScript.new()
	_cell_preloader.configure(_cell_manager._instantiator, _cell_manager._model_loader)
	_cell_preloader.set_debug(debug_enabled)

	# Phase 2 stutter diag — see field declarations above.
	_pipeline_compile_monitor = PipelineCompileMonitorScript.new()
	_pipeline_compile_per_cell = PipelineCompileMonitorScript.new()
	# Hand the per-cell tracker to CellPreloader so its LOADING→READY transition
	# can log its own delta on the same baseline. The heartbeat tracker stays here.
	if _cell_preloader.has_method("set_pipeline_compile_monitor"):
		_cell_preloader.set_pipeline_compile_monitor(PipelineCompileMonitorScript.new())

	# Phase 2 stutter diag — force-create the StreamingProfiler so the
	# slow-frame autopsy actually has data to dump. Previously _profiler was
	# lazily created by `get_profiler()`, called only by the benchmark HUD or
	# debug overlay; in normal interactive play the profiler stayed null and
	# every `if prof:` bracket no-op'd. The autopsy needs the profiler from
	# frame 0. Plan §11.4.
	if _profiler == null:
		_profiler = StreamingProfilerScript.new()
		_profiler.enabled = SC.ENABLE_PROFILING

	# Wire up background processor for async loading
	if _background_processor and async_loading_enabled:
		_cell_manager.set_background_processor(_background_processor)
		_debug("Async loading enabled with BackgroundProcessor")
	else:
		_debug("Async loading disabled, using synchronous loading")

	# Sync debug flag
	if _impostor_renderer:
		_impostor_renderer.set("debug_enabled", debug_enabled)
		# Startup burst: 15ms impostor budget while loading screen is visible
		# Normal budget (4ms) is restored when startup phase completes
		_impostor_renderer.set_load_budget_usec(15000.0)

	# Initialize runtime HLOD merger with viewport scenario + static renderer.
	# Phase 4 (2026-04-17): HLOD is the production pipeline when enabled —
	# MID registry (150-300m) → HLOD merged chunks (300-1000m) → impostors
	# (1000m+). HLOD-off parks merged chunks; MID falls back to DU.MID_END.
	# Toggle: `hlod_enable` / `hlod_disable`.
	if _hlod_merger:
		var scenario := get_viewport().get_world_3d().scenario
		_hlod_merger.initialize(scenario, _static_renderer, _background_processor)
		if _hlod_merger.enabled:
			set_hlod_visible(true)
			# Impostors pick up where HLOD ends — 1km+. Keeps tier bands
			# strictly non-overlapping (DISTANT_RENDERING_AUDIT §5.1 dedup).
			Log.info("streaming", "Runtime HLOD merger active — MID 0-%dm, HLOD %d-%dm, impostors %dm+" % [
				int(DU.HLOD_START), int(DU.HLOD_START), int(DU.HLOD_END), int(DU.HLOD_END)])
		else:
			set_hlod_visible(false)
			Log.info("streaming", "Runtime HLOD merger initialized but DISABLED - MID fallback 0-%dm (enable via console: hlod_enable)" % int(DU.MID_END))

	_initialized = true
	Log.info("streaming", "Initialized with native visibility_range streaming")

	# Only start tracking if camera was explicitly provided
	# If camera is null, wait for set_camera() to be called later
	# This allows caller to control when streaming actually starts
	if _camera:
		_camera_position = _camera.global_position
		_camera_cell = DU.world_to_cell(_camera_position)
		Log.info("streaming", "Initial camera cell: %s (position: %s)" % [_camera_cell, _camera_position])
		_update_loaded_cells()
	else:
		Log.info("streaming", "No camera provided - streaming will start when set_camera() is called")

	return OK


## Set the camera to track
func set_camera(camera: Camera3D) -> void:
	_camera = camera
	# Trigger initial update if system is initialized and camera is set
	if _initialized and _camera:
		_camera_position = _camera.global_position
		_camera_cell = DU.world_to_cell(_camera_position)
		_debug("Camera set, initial cell: %s" % _camera_cell)
		_update_loaded_cells()


## Set sun elevation for distant light time-of-day visibility.
## Called by world_explorer from sky_manager.celestial.sun_altitude.
func set_sun_elevation(elevation_rad: float) -> void:
	_sun_elevation_rad = elevation_rad


## Set cell manager
func set_cell_manager(cell_manager: CellManagerScript) -> void:
	_cell_manager = cell_manager

#endregion


#region Main Update Loop

func _process(delta: float) -> void:
	if not _initialized:
		if debug_enabled and Engine.get_frames_drawn() % 60 == 0:
			Log.debug("streaming", "_process skipped: not initialized")
		return

	if not _camera:
		_camera = get_viewport().get_camera_3d()
		if not _camera:
			if debug_enabled and Engine.get_frames_drawn() % 60 == 0:
				Log.debug("streaming", "_process skipped: no camera")
			return

	# DIAGNOSTIC heartbeat (2026-04-15, silent-crash pin). 5 s cadence, main-thread only.
	# Crash triage: last heartbeat line marks the frame range where the main
	# thread was alive; the last `instantiate_attempt`/`instantiate_done` pair
	# in model_loader pins the PackedScene at the instant of the crash.
	var now_sec: int = int(Time.get_ticks_msec() / 1000)
	if now_sec >= _last_heartbeat_sec + 5:
		var elapsed := now_sec - _last_heartbeat_sec if _last_heartbeat_sec >= 0 else 0
		var frames_since := Engine.get_frames_drawn() - _last_heartbeat_frame if _last_heartbeat_frame >= 0 else 0
		var fps_est := float(frames_since) / float(elapsed) if elapsed > 0 else 0.0
		_last_heartbeat_sec = now_sec
		_last_heartbeat_frame = Engine.get_frames_drawn()
		var p := Performance
		var process_ms := p.get_monitor(p.TIME_PROCESS) * 1000.0
		var physics_ms := p.get_monitor(p.TIME_PHYSICS_PROCESS) * 1000.0
		var draws := int(p.get_monitor(p.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		var objects := int(p.get_monitor(p.RENDER_TOTAL_OBJECTS_IN_FRAME))
		var prims := int(p.get_monitor(p.RENDER_TOTAL_PRIMITIVES_IN_FRAME))

		# Draw-call audit (2026-04-22) — split totals into VISIBLE vs SHADOW
		# passes. The total monitor above is sum-over-all-passes, which
		# conflates main-camera draws with shadow-cascade re-draws. Splitting
		# reveals the true shadow-pass multiplier.
		var draws_visible: int = 0
		var draws_shadow: int = 0
		var objs_visible: int = 0
		var objs_shadow: int = 0
		var vp := get_viewport()
		if vp != null:
			draws_visible = int(vp.get_render_info(
				Viewport.RENDER_INFO_TYPE_VISIBLE,
				Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME,
			))
			draws_shadow = int(vp.get_render_info(
				Viewport.RENDER_INFO_TYPE_SHADOW,
				Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME,
			))
			objs_visible = int(vp.get_render_info(
				Viewport.RENDER_INFO_TYPE_VISIBLE,
				Viewport.RENDER_INFO_OBJECTS_IN_FRAME,
			))
			objs_shadow = int(vp.get_render_info(
				Viewport.RENDER_INFO_TYPE_SHADOW,
				Viewport.RENDER_INFO_OBJECTS_IN_FRAME,
			))
		# Phase 3 registry batch stats from StaticObjectRenderer (0 if absent).
		# Legacy mm_batches/mm_slots fields kept at 0 post-step-7; registry
		# fields are the ground truth for MID-tier occupancy.
		var reg_batches := 0
		var reg_slots := 0
		if _static_renderer and _static_renderer.has_method("get_stats"):
			var srs: Dictionary = _static_renderer.get_stats()
			reg_batches = int(srs.get("registry_batches", 0))
			reg_slots = int(srs.get("registry_slots", 0))
		# T.0 baseline instrumentation — Jolt broadphase workload proxies.
		# `active` = dynamic RigidBody3Ds being simulated (carryables, NPCs).
		# `pairs` = collision pairs broadphase is tracking — this is the
		# direct proxy for per-object StaticBody3D cost. Before-number target
		# per §6: pairs should drop ~100× post-T.2 (merged cell trimesh).
		var phys_active := int(p.get_monitor(p.PHYSICS_3D_ACTIVE_OBJECTS))
		var phys_pairs := int(p.get_monitor(p.PHYSICS_3D_COLLISION_PAIRS))
		# Phase 2 stutter diag — pipeline compile delta over the 5s heartbeat
		# window. DRAW > 0 = first-visibility shader stutter source. MESH/SURFACE
		# spread between heartbeats vs cell-load events tells us where in the
		# load pipeline the engine pre-compiles. Plan §2.2.
		var pcd_str: String = ""
		if _pipeline_compile_monitor != null:
			var pcd: PackedInt64Array = _pipeline_compile_monitor.delta_and_update()
			pcd_str = " pipe=" + PipelineCompileMonitorScript.format_delta(pcd)
		Log.info("streaming", "heartbeat sec=%d frame=%d fps=%.1f proc=%.1fms phys=%.1fms draws=%d (vis=%d shad=%d) objs=%d (vis=%d shad=%d) prims=%dk loaded=%d loading=%d reg_batches=%d reg_slots=%d phys_active=%d phys_pairs=%d%s" % [
			now_sec,
			Engine.get_frames_drawn(),
			fps_est,
			process_ms,
			physics_ms,
			draws,
			draws_visible,
			draws_shadow,
			objects,
			objs_visible,
			objs_shadow,
			prims / 1000,
			_loaded_cells.size(),
			_loading_cells.size(),
			reg_batches,
			reg_slots,
			phys_active,
			phys_pairs,
			pcd_str,
		])

	# Start timing for frame budget telemetry
	var frame_start_usec := Time.get_ticks_usec()
	var phase_times: PackedFloat64Array = PackedFloat64Array()  # usec per phase
	phase_times.resize(9)  # 0:unload, 1:async_complete, 2:instantiate, 3:promote, 4:collision, 5:deferred, 6:queue, 7:cell_update, 8:static_cull
	var budget_usec := frame_budget_ms * 1000.0

	# Per-phase profiler — lightweight begin/end section pairs.
	# Gated by SC.ENABLE_PROFILING; zero overhead when disabled.
	var prof: StreamingProfilerScript = _profiler
	if prof:
		prof.begin_frame()

	# Update camera position and velocity. Fix B (streaming_stutter_2026_04_25
	# §11.4) — bracket cell_manager.set_camera_position; cheap in theory but
	# walks the proximity-deferred list internally on some paths.
	_camera_position = _camera.global_position
	if _cell_manager:
		if prof: prof.begin_section("cm_set_camera_position")
		_cell_manager.set_camera_position(_camera_position)
		if prof: prof.end_section("cm_set_camera_position")
	var new_cell := DU.world_to_cell(_camera_position)

	# Phase 7 finish (2026-04-17) — teleport detection. A single-frame camera
	# jump beyond TELEPORT_DETECT_THRESHOLD re-enters startup_phase so the
	# post-teleport ring loads at the aggressive 25ms budget instead of
	# post-startup 4ms. Must run BEFORE the _camera_velocity_xz update so
	# the teleport jump doesn't poison the EMA-smoothed velocity.
	if _prev_camera_position != Vector3.ZERO \
			and _camera_position.distance_to(_prev_camera_position) > TELEPORT_DETECT_THRESHOLD:
		_teleport_detected = true
		# Phase 2 stutter diag — bracket the teleport handler so the slow-frame
		# autopsy attributes the 1+ second teleport hitch to its actual sources
		# (signal-emit subscribers + CellPreloader.abort_all blocking wait).
		# Plan §11.4. Sub-brackets isolate signal vs preloader-drain.
		if prof: prof.begin_section("teleport:total")
		# Phase 8 — emit BEFORE the startup_phase re-arm below so a
		# LoadingStateMachine consumer can fade to black and pause the
		# tree on the same frame the jump happens. NativeStreamingManager
		# is PROCESS_MODE_ALWAYS so the post-teleport streaming burst
		# will keep running while the tree is paused.
		if prof: prof.begin_section("teleport:emit_signal")
		teleport_happened.emit(
			_prev_camera_position,
			_camera_position,
			_camera_position.distance_to(_prev_camera_position)
		)
		if prof: prof.end_section("teleport:emit_signal")

		# Phase 3 (§8.8) — abort in-flight preloads for cells the camera just
		# jumped away from; re-anchor at the new grid so the next update()
		# tick re-warms around the destination. Post Fix C.1 (plan §12.6),
		# `abort_all` is non-blocking: cooperative cancellation flag, no
		# `wait_for_task_completion`. Was up to 1 sec block; now O(N entries)
		# bookkeeping (~µs).
		if _cell_preloader != null:
			if prof: prof.begin_section("teleport:preloader_abort")
			_cell_preloader.abort_all()
			_cell_preloader.reset(DU.world_to_cell(_camera_position))
			if prof: prof.end_section("teleport:preloader_abort")
		if prof: prof.end_section("teleport:total")

	# EMA-smoothed velocity on XZ plane (for predictive cell loading).
	# Teleport frames skip the EMA so the huge jump doesn't throw predictive
	# pre-queue into a nonsense direction for the following seconds.
	if delta > 0.0 and _prev_camera_position != Vector3.ZERO and not _teleport_detected:
		var raw_vel := Vector2(
			(_camera_position.x - _prev_camera_position.x) / delta,
			(_camera_position.z - _prev_camera_position.z) / delta
		)
		_camera_velocity_xz = _camera_velocity_xz.lerp(raw_vel, 0.3)
	_prev_camera_position = _camera_position

	# On teleport, re-arm startup_phase so the instantiation/merge budget
	# switches back to burst mode. ObjectPaging has its own TELEPORT_THRESHOLD
	# (500m, identical) which primes the HLOD warmup queue — the two systems
	# enter burst mode on the same frame.
	if _teleport_detected:
		_teleport_detected = false
		if not _startup_phase:
			Log.info("streaming", "Teleport detected — re-entering startup burst mode")
			_startup_phase = true
			_startup_frames = 0
			_post_startup_start_ms = 0
			_queue_drain_logged = false
			_post_startup_audit_accum = 0.0
			if _impostor_renderer:
				_impostor_renderer.set_load_budget_usec(15000.0)

# Track startup frames for staggered loading.
	# Fix B — bracket the startup tick so the unattributed teleport autopsy
	# (2326 ms / 1941 ms unattributed in baseline) stops being mysterious.
	# After teleport, _startup_phase is re-armed and _check_startup_complete
	# can call into cell_manager which is the suspected source of the gap.
	if _startup_phase:
		if prof: prof.begin_section("startup_tick")
		_startup_frames += 1
		_emit_startup_progress()
		_check_startup_complete()
		if prof: prof.end_section("startup_tick")

	# Check if we moved to a new cell
	var cell_update_usec: float = 0.0
	_cell_changed_this_frame = (new_cell != _camera_cell)
	if _cell_changed_this_frame:
		_debug("Camera moved to new cell: %s (was %s)" % [new_cell, _camera_cell])
		_camera_cell = new_cell
		if prof:
			prof.begin_section("cell_update")
		var cu_start := Time.get_ticks_usec()
		_update_loaded_cells()
		cell_update_usec = float(Time.get_ticks_usec() - cu_start)
		if prof:
			prof.end_section("cell_update")
	elif _impostor_update_pending:
		# Deferred impostor update — runs on the frame AFTER cell change
		# Prevents impostor scan (170ms+ initial) from stacking with cell load/unload
		_impostor_update_pending = false
		if prof:
			prof.begin_section("impostor_update")
		var imp_start := Time.get_ticks_usec()
		if _impostor_renderer:
			_impostor_renderer.update_impostor_area(_camera_cell, impostor_radius_cells)
		var imp_ms := float(Time.get_ticks_usec() - imp_start) / 1000.0
		if prof:
			prof.end_section("impostor_update")
		if imp_ms > 2.0:
			Log.info("streaming", "Deferred impostor update: %.1fms" % imp_ms)

	# Runtime HLOD merger: process completed merges every frame, update on cell change
	# Phase 2 stutter diag — bracket each unbracketed _process subsystem so the
	# autopsy can attribute the BIG unattributed spikes (1.7s+) to whichever
	# of these is actually responsible. Plan §11.4.
	if _hlod_merger and not _startup_phase:
		if prof: prof.begin_section("hlod_merger")
		_hlod_merger.process_merge_queue()  # Staggered: max 2 cells/frame
		_hlod_merger.process_completions()
		if _cell_changed_this_frame or _hlod_needs_initial_update:
			_hlod_merger.update_for_camera(_camera_cell, _camera_position)
			_hlod_needs_initial_update = false
		if prof: prof.end_section("hlod_merger")

	# Update distant light manager (camera pos + time-of-day)
	if _distant_light_manager:
		if prof: prof.begin_section("distant_light_manager")
		_distant_light_manager.update(_camera_position, _sun_elevation_rad)
		if prof: prof.end_section("distant_light_manager")

	# I.6 Phase 2 — orphan expiry tick. Off the frame-budget hot path
	# because it runs at 1 Hz max, and the walk is bounded by the tiny
	# size of `_persistent_nodes` (a handful of held items, if that).
	_orphan_prune_accum += delta
	if _orphan_prune_accum >= ORPHAN_PRUNE_INTERVAL_S:
		if prof: prof.begin_section("orphan_prune")
		_orphan_prune_accum = 0.0
		_prune_expired_orphans()
		if prof: prof.end_section("orphan_prune")

	# Predictive loading — velocity-extrapolated two-phase CellPreloader (§8).
	# Warms ResourceLoader + dispatches Phase F prereg for cells the camera is
	# heading toward. Skipped during startup burst so the initial ring finishes
	# with its own aggressive budget first.
	if not _startup_phase and _cell_preloader != null:
		if prof: prof.begin_section("cell_preloader_update")
		_cell_preloader.update(_camera_cell, _camera_position, _camera_velocity_xz)
		if prof: prof.end_section("cell_preloader_update")

	# Phase 0: Budgeted unloading — free children of departing cells gradually
	# Runs BEFORE loading so freed memory is available for new cells
	var phase_start := Time.get_ticks_usec()
	if prof:
		prof.begin_section("unload")
	if not _unloading_cells.is_empty() or not _pending_rs_hide_cells.is_empty() or not _pending_rs_cleanup_cells.is_empty():
		CrashBreadcrumb.write("nsm::unload_tick_begin", "cells=%d hide=%d clean=%d" % [
			_unloading_cells.size(), _pending_rs_hide_cells.size(), _pending_rs_cleanup_cells.size()
		])
		_process_budgeted_unloading()
		CrashBreadcrumb.write("nsm::unload_tick_done", "cells=%d hide=%d clean=%d" % [
			_unloading_cells.size(), _pending_rs_hide_cells.size(), _pending_rs_cleanup_cells.size()
		])
	if prof:
		prof.end_section("unload")
	phase_times[0] = float(Time.get_ticks_usec() - phase_start)

	# Process async loading.
	# Architecture: Phase 1 (completions) always runs — finalizes in-flight BG
	# requests and keeps _async_requests from stalling. Phases 2-4 are gated on
	# _near_tier_visible as a single block: no scattered per-function checks.
	# When near is off ALL per-frame near work stops: no instantiation, no
	# promotions, no collision re-enable, no new load submissions.
	if async_loading_enabled:
		# Phase 1: completions — always runs (even when near is off)
		phase_start = Time.get_ticks_usec()
		if prof:
			prof.begin_section("async_complete")
		_process_async_completions()
		if prof:
			prof.end_section("async_complete")
		phase_times[1] = float(Time.get_ticks_usec() - phase_start)

		if _near_tier_visible:
			# Phase 2: instantiation
			# During startup / burst drain: 25ms budget.
			# Post-startup normal: 4ms — prevents 48%-of-frame death spiral.
			phase_start = Time.get_ticks_usec()
			var instantiation_budget_ms: float
			if _startup_phase or _near_burst_drain:
				instantiation_budget_ms = 25.0
			else:
				instantiation_budget_ms = SC.POST_STARTUP_INSTANTIATION_BUDGET_MS
			var camera_fwd := -_camera.global_transform.basis.z if _camera else Vector3.FORWARD
			var allow_collision_finalize := _unloading_cells.is_empty() \
				and _pending_rs_hide_cells.is_empty() \
				and _pending_rs_cleanup_cells.is_empty()
			var payload_publish_budget_us := int(SC.STATIC_PREPARE_BUDGET_MS * 1000.0)
			var payload_publish_start_us := Time.get_ticks_usec()
			var payload_published := _process_payload_publish_steps(payload_publish_budget_us)
			var payload_publish_us := Time.get_ticks_usec() - payload_publish_start_us
			# Phase 2 stutter diag — bracket the instantiate call into the profiler
			# so the slow-frame autopsy can attribute spike time. Plan §11.4.
			if prof: prof.begin_section("instantiate")
			var instantiated := _cell_manager.process_async_instantiation(
				maxf(0.1, instantiation_budget_ms - (float(payload_publish_us) / 1000.0)),
				_camera_position,
				camera_fwd,
				allow_collision_finalize,
			)
			if prof: prof.end_section("instantiate")
			phase_times[2] = float(Time.get_ticks_usec() - phase_start)
			if payload_published > 0 and debug_enabled:
				_debug("Published %d payload items this frame" % payload_published)
			if instantiated > 0 and debug_enabled:
				_debug("Instantiated %d objects this frame" % instantiated)

			# Burst drain: clear when queue is empty
			if _near_burst_drain and _cell_manager:
				if _cell_manager.get_instantiation_queue_size() == 0 and _async_requests.is_empty():
					_near_burst_drain = false
					Log.info("streaming", "NEAR burst drain complete")

			# Post-startup queue drain telemetry
			if not _startup_phase and not _queue_drain_logged and _post_startup_start_ms > 0 and _cell_manager:
				var q := _cell_manager.get_instantiation_queue_size()
				if q == 0:
					var elapsed_ms := Time.get_ticks_msec() - _post_startup_start_ms
					Log.info("streaming", "Post-startup queue drained in %.1fs (%d frames since loading screen)" % [
						elapsed_ms / 1000.0, Engine.get_frames_drawn()])
					_queue_drain_logged = true

			# Skip remaining phases if budget already exceeded
			# S.1: Phase 3 (MID→NEAR promote) / 3a (collision enable) / 3b
			# (deferred NEAR instantiate) deleted — per-cell tier FSM in S.7+
			# replaces the per-actor promotion dance. phase_times[3..5] stay
			# zero; the HUD still reads the slots but values will be 0.
			var total_elapsed_usec := Time.get_ticks_usec() - frame_start_usec
			if total_elapsed_usec < budget_usec:
				# Phase 4: Queue new cell requests (non-blocking).
				# Fix B (streaming_stutter_2026_04_25 plan §11.4) — bracket so the
				# autopsy attributes the suspected 800 ms spike. _request_cell_async
				# calls cell_manager.request_exterior_cell_async which still calls
				# preregister_cell_statics on the main thread (active-loader path
				# Fix A left intact). If this section spikes, that's the smoking
				# gun for the next fix.
				phase_start = Time.get_ticks_usec()
				if prof: prof.begin_section("pending_loads_async")
				_process_pending_loads_async()
				if prof: prof.end_section("pending_loads_async")
				phase_times[6] = float(Time.get_ticks_usec() - phase_start)

	else:
		# Fallback: synchronous loading (blocks frame)
		if _near_tier_visible:
			if prof: prof.begin_section("pending_loads_sync")
			_process_pending_loads_sync(delta)
			if prof: prof.end_section("pending_loads_sync")

	# Phase 3 world-scoped MultiMesh cull tick. tick_prototype_cull no-ops
	# internally when the registry hasn't been instantiated yet (cold
	# boot, empty world). Runs after all add/remove/transform work this
	# frame so the packed buffer reflects the latest state.
	if _static_renderer:
		phase_start = Time.get_ticks_usec()
		if prof: prof.begin_section("static_renderer_cull")
		var vr_end: float = _static_renderer.visibility_range_end
		_static_renderer.tick_prototype_cull(
			_camera_position,
			vr_end * vr_end,
			SC.STATIC_CULL_BATCH_BUDGET_PER_FRAME
		)
		if prof: prof.end_section("static_renderer_cull")
		phase_times[8] = float(Time.get_ticks_usec() - phase_start)

	# Store per-phase timing for external consumers (benchmark, profiler)
	phase_times[7] = cell_update_usec
	_last_phase_times = phase_times

	# Frame budget telemetry — detect when combined streaming work exceeds budget
	var total_ms := float(Time.get_ticks_usec() - frame_start_usec) / 1000.0
	_last_frame_total_ms = total_ms
	if total_ms > frame_budget_ms * 1.5:
		_frame_overrun_count += 1
		# Log with per-phase breakdown (at most once per 60 frames)
		if Engine.get_frames_drawn() - _last_overrun_log_frame > 60:
			Log.warn("streaming", "Frame overrun: %.1fms [cellupd:%.1f unload:%.1f async:%.1f inst:%.1f promo:%.1f coll:%.1f defer:%.1f queue:%.1f static:%.1f] (budget:%.1fms, overruns:%d)" % [
				total_ms,
				cell_update_usec / 1000.0,
				phase_times[0] / 1000.0, phase_times[1] / 1000.0, phase_times[2] / 1000.0,
				phase_times[3] / 1000.0, phase_times[4] / 1000.0, phase_times[5] / 1000.0,
				phase_times[6] / 1000.0,
				phase_times[8] / 1000.0,
				frame_budget_ms, _frame_overrun_count])
			_last_overrun_log_frame = Engine.get_frames_drawn()

	# Phase 2 stutter diag — close the per-frame profiler window and
	# auto-dump a sorted per-section breakdown for any frame > 16 ms.
	# Dropped from 100 ms (2026-04-26) so the autopsy fires on the routine
	# 12-25 ms overruns visible during walking traversal, not just catastrophic
	# stalls. 16 ms = one 60 fps frame. Plan §11.4.
	if prof:
		prof.end_frame()
		prof.dump_overrun_breakdown(16.0, "stream_proc")

	# Post-startup audit — auto-logs every 5s for 60s so FPS/queue/phase breakdown
	# is captured during the slow loading period without requiring user interaction.
	# Key output: proc_ms vs frame_ms tells GPU vs GDScript; inst vs frame tells budget violation.
	if not _startup_phase and _post_startup_start_ms > 0:
		_post_startup_audit_accum += delta
		if _post_startup_audit_accum >= 5.0:
			_post_startup_audit_accum = 0.0
			var elapsed_s := float(Time.get_ticks_msec() - _post_startup_start_ms) / 1000.0
			if elapsed_s < 60.0 and _cell_manager:
				var q := _cell_manager.get_instantiation_queue_size()
				var fps := Engine.get_frames_per_second()
				var proc_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
				var burst := _cell_manager.is_burst_loading()
				var pt := _last_phase_times
				var n := pt.size()
				Log.info("streaming", "[audit +%.0fs] fps=%d proc=%.1fms frame=%.1fms queue=%d burst=%s | unload=%.1f async=%.1f inst=%.1f promo=%.1f coll=%.1f defer=%.1f static=%.1f (ms)" % [
					elapsed_s, fps, proc_ms, total_ms, q, "Y" if burst else "N",
					pt[0]/1000.0 if n > 0 else 0.0,
					pt[1]/1000.0 if n > 1 else 0.0,
					pt[2]/1000.0 if n > 2 else 0.0,
					pt[3]/1000.0 if n > 3 else 0.0,
					pt[4]/1000.0 if n > 4 else 0.0,
					pt[5]/1000.0 if n > 5 else 0.0,
					pt[8]/1000.0 if n > 8 else 0.0
				])


## Returns true when any cell-lifecycle path still occupies the grid: live,
## currently loading, in unload limbo, mid-hide, or with pending RS free work.
## Load gates use this so a fresh load can't publish under a grid whose old
## buckets are still scheduled for hide/free — auditor2 finding 2026-05-01.
func _is_cell_occupied(grid: Vector2i) -> bool:
	if grid in _loaded_cells:
		return true
	if grid in _loading_cells:
		return true
	if grid in _unloading_cells:
		return true
	if grid in _pending_rs_hide_set:
		return true
	if grid in _pending_rs_cleanup_set:
		return true
	return false


## Update which cells should be loaded based on camera position
func _update_loaded_cells() -> void:
	# Dual-purpose SubsystemToggles gate: freeze the cell set entirely when
	# `near_objects` is off. Both loads AND unloads pause. Prevents the
	# asymmetric-drain bug where `_loaded_cells` shrinks during the off period
	# (unloads run) but can't be refilled (loads gated). On toggle back to ON,
	# `set_near_tier_visible` forces a single catch-up call.
	if not _near_tier_visible:
		return
	var ulc_start := Time.get_ticks_usec()

	# Calculate which cells should be loaded
	var cells_to_load := _get_cells_in_radius(_camera_cell, load_radius_cells)
	var t_grid := Time.get_ticks_usec()

	# Reclaim cells that re-entered radius while still being unloaded.
	# State-reversal window closes here: move the async request back out of
	# `_unloading_request_ids` limbo into `_async_requests` so pending queue
	# entries resume draining into the (now-active) cell_node.
	#
	# Reclaim is valid ONLY before destructive cleanup begins. Once the
	# budgeted unloader has freed any child or hidden any RS instance for the
	# grid, `_unloading_frozen[grid]` is true and reclaim is rejected — the
	# cell drains to completion and gets a fresh load on the next pass.
	# Without this gate, a reclaimed cell would lose its static RS instances
	# (still queued in `_pending_rs_hide_cells` / `_pending_rs_cleanup_cells`)
	# a few frames after "rescue", which the user perceives as parts of the
	# rescued cell disappearing. (Auditor2 finding, chat msg 40, 2026-05-01.)
	var reclaimed: Array[Vector2i] = []
	for grid: Vector2i in _unloading_cells:
		if grid in cells_to_load:
			if _unloading_frozen.get(grid, false):
				_record_lifecycle_event("reclaim_rejected", grid, "reason=frozen")
				continue
			var cell_ref: Variant = _unloading_cells[grid]
			if not is_instance_valid(cell_ref):
				continue
			var cell_node: Node3D = cell_ref as Node3D
			if cell_node.get_child_count() > 0 or grid in _unloading_request_ids:
				# Cell_node never left _world_container (see _unload_cell note);
				# re-activate by flipping visible. No reparent.
				cell_node.visible = _near_tier_visible
				_loaded_cells[grid] = cell_node
				reclaimed.append(grid)
				# Restore the async request from limbo so in-flight queue
				# entries continue landing in the now-live cell.
				if grid in _unloading_request_ids:
					_async_requests[grid] = _unloading_request_ids[grid]
					if _cell_manager != null and _cell_manager.has_method("resume_request_publish"):
						_cell_manager.resume_request_publish(_unloading_request_ids[grid])
					_unloading_request_ids.erase(grid)
				# Drop the grid from the pending RS hide/cleanup queues so the
				# budgeted unloader doesn't fire `hide_cell_instances_budgeted`
				# / `remove_cell_instances` on a now-live cell. Frozen gate above
				# guarantees no hide/cleanup work has run yet.
				if grid in _pending_rs_hide_set:
					var idx := _pending_rs_hide_cells.find(grid)
					if idx >= 0:
						_pending_rs_hide_cells[idx] = _pending_rs_hide_cells.back()
						_pending_rs_hide_cells.pop_back()
					_pending_rs_hide_set.erase(grid)
				var cleanup_idx := _pending_rs_cleanup_cells.find(grid)
				if cleanup_idx >= 0:
					_pending_rs_cleanup_cells[cleanup_idx] = _pending_rs_cleanup_cells.back()
					_pending_rs_cleanup_cells.pop_back()
				_pending_rs_cleanup_set.erase(grid)
				_unloading_destructive_holds.erase(grid)
				_record_lifecycle_event("reclaim_cell", grid, "children=%d request_restored=%s" % [
					cell_node.get_child_count(),
					"Y" if grid in _async_requests else "N",
				])
				_debug("Reclaimed unloading cell %s (%d children remaining, request restored)" % [grid, cell_node.get_child_count()])
	for grid in reclaimed:
		_unloading_cells.erase(grid)
		_unloading_hold_frames.erase(grid)
		_unloading_frozen.erase(grid)
	var t_reclaim := Time.get_ticks_usec()

	# Unload cells that are too far (with hysteresis)
	# Load uses Chebyshev grid (square), so max Euclidean distance is the diagonal:
	# sqrt(2) * radius * cell_size. Unload threshold must exceed this to prevent
	# corner cells from oscillating between load/unload on each camera cell change.
	var cells_to_unload: Array[Vector2i] = []
	var max_load_euclidean := float(load_radius_cells) * DU.CELL_SIZE_METERS * sqrt(2.0)
	var unload_threshold_sq := (max_load_euclidean + SC.HYSTERESIS_MID) * (max_load_euclidean + SC.HYSTERESIS_MID)

	for grid: Vector2i in _loaded_cells:
		if grid not in cells_to_load:
			# Only unload if beyond hysteresis distance
			if DU.cell_distance_squared(_camera_cell, grid) > unload_threshold_sq:
				cells_to_unload.append(grid)

	if debug_enabled and not cells_to_unload.is_empty():
		_debug("Unloading %d cells" % cells_to_unload.size())

	for grid: Vector2i in cells_to_unload:
		_unload_cell(grid)
	var t_unload := Time.get_ticks_usec()

	# Queue new cells for loading (sorted farthest-first so pop_back gets nearest)
	_pending_load_queue.clear()
	_pending_load_set.clear()
	for grid: Vector2i in cells_to_load:
		if not _is_cell_occupied(grid):
			_pending_load_queue.append(grid)
			_pending_load_set[grid] = true

	if debug_enabled and not _pending_load_queue.is_empty():
		_debug("Queueing %d cells for loading (camera at cell %s)" % [_pending_load_queue.size(), _camera_cell])

	# Sort farthest first — pop_back() returns nearest cell (O(1) instead of O(n))
	_pending_load_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return DU.cell_distance_squared(_camera_cell, a) > DU.cell_distance_squared(_camera_cell, b)
	)
	var t_queue := Time.get_ticks_usec()

	# Defer impostor update to next frame to avoid stacking with cell load/unload.
	# During startup phase, defer further — impostor scan (11K+ cells) overwhelms
	# the resource pipeline when combined with cell model loading. The startup_complete
	# signal handler below triggers the impostor scan once initial cells are done.
	if not _startup_phase:
		_impostor_update_pending = true

	# Scan for distant lights in a wider radius than loaded cells
	# Uses impostor_radius since distant lights should be visible as far as impostors
	if _distant_light_manager:
		_distant_light_manager.scan_cells_around(_camera_cell, impostor_radius_cells)
	var t_lights := Time.get_ticks_usec()

	# Lazy-spawn re-queue (statics_no_node3d follow-up 2026-04-19): walk the
	# proximity-deferred list, re-queue any interactive refs that are now
	# within INTERACTIVE_PROXIMITY_THRESHOLD_M of the camera. Throttled
	# internally to ~4 checks/sec.
	if _cell_manager:
		_cell_manager.tick_proximity_deferred(_camera_position)
	var t_proximity := Time.get_ticks_usec()

	# Log breakdown if total exceeds 2ms
	var total_ulc_ms := float(Time.get_ticks_usec() - ulc_start) / 1000.0
	if total_ulc_ms > 2.0:
		Log.info("streaming", "_update_loaded_cells: %.1fms [grid:%.1f reclaim:%.1f unload:%.1f queue:%.1f lights:%.1f prox:%.1f] cells_loaded=%d cells_unload_q=%d" % [
			total_ulc_ms,
			float(t_grid - ulc_start) / 1000.0,
			float(t_reclaim - t_grid) / 1000.0,
			float(t_unload - t_reclaim) / 1000.0,
			float(t_queue - t_unload) / 1000.0,
			float(t_lights - t_queue) / 1000.0,
			float(t_proximity - t_lights) / 1000.0,
			_loaded_cells.size(),
			cells_to_unload.size()])


## Get all cells within a radius of the center cell
func _get_cells_in_radius(center: Vector2i, radius: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var max_dist_sq := max_load_distance * max_load_distance
	
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var grid := Vector2i(center.x + dx, center.y + dy)
			
			# Check distance
			var dist_sq := DU.cell_distance_squared(center, grid)
			if dist_sq <= max_dist_sq:
				cells.append(grid)
	
	# Sort by distance (closest first)
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return DU.cell_distance_squared(center, a) < DU.cell_distance_squared(center, b)
	)
	
	return cells

#endregion


#region Cell Loading

## Request async loading of a cell (non-blocking)
## Returns true if request was submitted, false if already loading or at capacity
func _request_cell_async(grid: Vector2i) -> bool:
	if _is_cell_occupied(grid):
		return false

	# Submit async request
	var request_id := _cell_manager.request_exterior_cell_async(grid.x, grid.y)

	if request_id < 0:
		# Async not available (no background processor) or at capacity
		# Don't fall back to sync - let the cell stay in queue for next frame
		# This prevents frame stalls from sync loading when async is just busy
		if debug_enabled:
			_debug("Async request rejected for cell %s (will retry)" % grid)
		return false

	# Track the request
	_async_requests[grid] = request_id
	_loading_cells[grid] = true

	# Get the in-progress cell node and add it to scene immediately
	# Objects will appear progressively as they are instantiated
	var cell_node := _cell_manager.get_async_cell_node(request_id)
	if cell_node:
		cell_node.visible = _near_tier_visible
		_world_container.add_child(cell_node)
		_loaded_cells[grid] = cell_node

	cell_loading.emit(grid)
	_debug("Async request %d submitted for cell %s" % [request_id, grid])
	return true


## Load a cell synchronously (blocking - used as fallback)
func _load_cell_sync(grid: Vector2i) -> void:
	if grid in _loaded_cells or grid in _loading_cells:
		return

	cell_loading.emit(grid)
	_loading_cells[grid] = true

	var cell_node := _cell_manager.load_exterior_cell(grid.x, grid.y)

	if cell_node:
		_configure_cell_visibility(cell_node)
		cell_node.visible = _near_tier_visible
		_world_container.add_child(cell_node)
		_loaded_cells[grid] = cell_node

		# I.6 Phase 2 — re-home any orphans whose origin grid matches.
		_rehome_persistent_nodes_for_cell(cell_node, grid)

		var object_count := _count_mesh_instances(cell_node)
		_stats["loaded_cells"] = _loaded_cells.size()
		_stats["total_objects"] += object_count

		_log_pipeline_compile_for_cell_load(grid, object_count, "sync")
		cell_loaded.emit(grid, object_count)
		if _cell_preloader != null:
			_cell_preloader.notify_activated(grid)
		_debug("Sync loaded cell %s with %d objects" % [grid, object_count])
	else:
		_debug("Failed to load cell %s" % [grid])

	_loading_cells.erase(grid)
	stats_updated.emit(_stats)


## Unload a cell at the given grid position (budgeted — gradual over multiple frames)
##
## State-reversal pattern: the cell_node enters unload-container LIMBO, where
## it remains fully valid (queue entries keep draining into it, reclaim can
## pull it back to `_loaded_cells` without any state rebuild). The async
## request is NOT cancelled here — canceling the queue during unload would
## discard 100-300 pending refs per cell and leave reclaim with a half-
## populated cell_node. Instead the request_id parks in `_unloading_request_ids`
## until the cell truly dies in `_process_budgeted_unloading`, where
## `finalize_unloaded_cell` does the soft cleanup.
func _unload_cell(grid: Vector2i) -> void:
	# NOTE 2026-04-20: prior `CrashBreadcrumb.write("unload_cell_begin/end", ...)`
	# calls at entry/exit were each doing FileAccess open/write/close. Per-cell
	# overhead compounded to 4-8ms/cell on slower disks and masked the real
	# per-step cost (0.9-2.7ms). Removed — 2 months of crashes never pointed
	# at `unload_cell_*`, breadcrumbs served their diagnostic purpose. The
	# budgeted unloader still writes `bu::cell_qfree_*` breadcrumbs which
	# cover the destructor path if a crash moves there.
	# Phase 2 stutter diag — bracket each sub-step into the StreamingProfiler so
	# the slow-frame autopsy (§11.4) can attribute spike time to specific
	# sub-steps, not just the cell_update parent. The existing text-only
	# breakdown log at the end of this function stays as a redundant signal.
	var prof: StreamingProfilerScript = _profiler
	if prof: prof.begin_section("unload_cell:total")
	var t0 := Time.get_ticks_usec()
	# Park any pending async request for this cell in the limbo registry.
	# Do NOT call cell_manager.cancel_async_request — that filters the queue
	# and frees the cell_node, which defeats state reversal on reclaim.
	if grid in _async_requests:
		var request_id: int = _async_requests[grid]
		_async_requests.erase(grid)
		_loading_cells.erase(grid)
		_unloading_request_ids[grid] = request_id
		# Win 2 — drain any in-flight collision worker + free the server-direct
		# body NOW. The unload-container limbo can hold the request for many
		# frames; without this, a worker that completes mid-limbo would insert
		# a body into the broadphase that gets immediately freed by
		# finalize_unloaded_cell. Also handles the rarer case where the body
		# was already finalized before unload — better to free it at unload-
		# start (matches old StaticBody3D-as-cell-node-child semantics, where
		# physics died with the cell visibility change).
		if _cell_manager != null:
			if _cell_manager.has_method("pause_request_publish"):
				_cell_manager.pause_request_publish(request_id)
			_cell_manager.cancel_collision_build_for_request(request_id)
		_record_lifecycle_event("park_request", grid, "request=%d" % request_id)
		_debug("Parked async request %d for cell %s (state-reversal limbo)" % [request_id, grid])

	if grid not in _loaded_cells:
		if prof: prof.end_section("unload_cell:total")
		return

	var cell_node: Node3D = _loaded_cells[grid]
	_loaded_cells.erase(grid)
	_stats["loaded_cells"] = _loaded_cells.size()
	var t_req := Time.get_ticks_usec()

	# S.1: promoted-object tracking deleted. MID re-enable in S.7 will hide
	# MID RS instances via per-cell tier transition (request_cell_tier), not
	# per-actor promote clear.

	# Queue MID-tier RS instances for BUDGETED hiding across frames.
	# Previously this called hide_cell_instances() synchronously (1000+ RS calls, 10-32ms).
	# Now we hide progressively via hide_cell_instances_budgeted() in _process_budgeted_unloading().
	if _static_renderer:
		_pending_rs_hide_cells.append(grid)
		_pending_rs_hide_set[grid] = true
		_pending_rs_cleanup_cells.append(grid)
		_pending_rs_cleanup_set[grid] = true
		if _static_renderer.has_method("defer_prototype_uploads"):
			_static_renderer.call("defer_prototype_uploads", SC.STATIC_CULL_UPLOAD_DEFER_FRAMES_AFTER_UNLOAD)

	# I.6 — evacuate any persistent nodes (held items, etc.) from this
	# cell BEFORE putting it in the unloading set. Otherwise the
	# budgeted unload pass would free the held body along with the
	# rest of the cell. Per `docs/INTERACTION_SYSTEM.md` §10.
	if prof: prof.begin_section("unload_cell:evac_persistents")
	_evacuate_persistent_nodes_from_cell(cell_node, grid)
	if prof: prof.end_section("unload_cell:evac_persistents")
	var t_evac := Time.get_ticks_usec()

	# No reparent. Cell_node stays in _world_container; hide via visible=false
	# (propagates to subtree rendering). The budgeted unloader walks
	# `_unloading_cells` by grid key and frees children in place — tree
	# parent is irrelevant to that loop. process_mode stays INHERIT so
	# in-flight physics bodies / scripts complete cleanly on their own
	# frame — matching original behavior, which never touched process_mode.
	# Phase 2 stutter diag — bracket separately to catch the suspected
	# NOTIFICATION_VISIBILITY_CHANGED propagation cost on large subtrees.
	if prof: prof.begin_section("unload_cell:visibility_propagate")
	cell_node.visible = false
	if prof: prof.end_section("unload_cell:visibility_propagate")
	_unloading_cells[grid] = cell_node
	if debug_unload_limbo_hold_frames > 0:
		_unloading_hold_frames[grid] = debug_unload_limbo_hold_frames
	if debug_unload_destructive_hold_frames > 0:
		_unloading_destructive_holds[grid] = debug_unload_destructive_hold_frames
	var t_hide := Time.get_ticks_usec()

	_debug("Queued cell %s for budgeted unloading (%d children)" % [grid, cell_node.get_child_count()])
	if prof: prof.begin_section("unload_cell:emit_unloaded")
	cell_unloaded.emit(grid)
	if prof: prof.end_section("unload_cell:emit_unloaded")
	# Phase 2 stutter diag — explicit bracket: notify_unloaded → _drain_and_erase
	# → _drain_entry → wait_for_task_completion. Suspected blocking call when
	# a cell with many in-flight preload tasks unloads mid-transition.
	if prof: prof.begin_section("unload_cell:preloader_drain")
	if _cell_preloader != null:
		_cell_preloader.notify_unloaded(grid)
	if prof: prof.end_section("unload_cell:preloader_drain")
	var t_emit1 := Time.get_ticks_usec()
	if prof: prof.begin_section("unload_cell:emit_stats")
	stats_updated.emit(_stats)
	if prof: prof.end_section("unload_cell:emit_stats")
	var t_emit2 := Time.get_ticks_usec()
	var total_ms := float(t_emit2 - t0) / 1000.0
	# Always log — threshold gating was masking the 8ms/call slice (sub-3ms per sub-step).
	Log.info("streaming", "[_unload_cell %s] %.2fms [req:%.2f evac:%.2f hide:%.2f emit_unload:%.2f emit_stats:%.2f] children=%d" % [
		grid, total_ms,
		float(t_req - t0) / 1000.0,
		float(t_evac - t_req) / 1000.0,
		float(t_hide - t_evac) / 1000.0,
		float(t_emit1 - t_hide) / 1000.0,
		float(t_emit2 - t_emit1) / 1000.0,
		cell_node.get_child_count()])
	if prof: prof.end_section("unload_cell:total")


## Process gradual unloading of departing cells within time budget
## Removes children in batches to avoid frame spikes from mass queue_free()
func _process_budgeted_unloading() -> void:
	var start_time := Time.get_ticks_usec()
	var budget_usec := SC.UNLOAD_BUDGET_MS * 1000.0
	var total_freed := 0

	# Verification-only: tick the per-grid destructive hold once per frame.
	# When the hold is > 0 for a grid, both the queue_free pass and the RS
	# hide pass below skip that grid, keeping the cell in pure limbo so the
	# reclaim window stays open. Default-empty in production.
	if not _unloading_destructive_holds.is_empty():
		for grid: Vector2i in _unloading_destructive_holds.keys():
			var rem := int(_unloading_destructive_holds[grid])
			if rem > 0:
				_unloading_destructive_holds[grid] = rem - 1

	# Process each unloading cell
	var completed_grids: Array[Vector2i] = []

	for grid: Vector2i in _unloading_cells:
		var cell_ref: Variant = _unloading_cells[grid]
		if not is_instance_valid(cell_ref):
			# Cell_node was freed externally — finalize the parked request
			# so its queue entries don't leak past the cell's death.
			if grid in _unloading_request_ids:
				_cell_manager.finalize_unloaded_cell(_unloading_request_ids[grid])
				_unloading_request_ids.erase(grid)
			completed_grids.append(grid)
			continue
		var cell_node: Node3D = cell_ref as Node3D

		# Verification hook: skip destruction for this grid while its hold
		# counter is positive. Reclaim can still succeed during this window.
		if _unloading_destructive_holds.get(grid, 0) > 0:
			continue

		var children_count := cell_node.get_child_count()
		if children_count == 0:
			var hold_frames := int(_unloading_hold_frames.get(grid, 0))
			if hold_frames > 0:
				_unloading_hold_frames[grid] = hold_frames - 1
				continue
			# Cell is empty, free the container. State-reversal window closes
			# here — cell is truly dying, finalize the parked async request.
			CrashBreadcrumb.write("bu::cell_qfree_empty", str(grid))
			if grid in _unloading_request_ids:
				_record_lifecycle_event("finalize_unloaded", grid, "request=%d reason=empty" % _unloading_request_ids[grid])
				_cell_manager.finalize_unloaded_cell(_unloading_request_ids[grid])
				_unloading_request_ids.erase(grid)
			cell_node.queue_free()
			completed_grids.append(grid)
			continue

		# Queue up to UNLOAD_BATCH_SIZE children from this cell for deletion.
		# Avoid remove_child() here: it synchronously runs tree-exit/physics
		# notifications in the streaming tick and has crashed inside Terrain3D
		# during cell transitions. queue_free() detaches at Godot's safe point.
		var batch := 0
		var child_index := cell_node.get_child_count() - 1
		while batch < SC.UNLOAD_BATCH_SIZE and child_index >= 0:
			# Check time budget
			if Time.get_ticks_usec() - start_time >= budget_usec:
				# Out of time — stop and continue next frame
				if debug_enabled and total_freed > 0:
					_debug("Unload budget hit: freed %d objects, %d cells still unloading" % [total_freed, _unloading_cells.size() - completed_grids.size()])
				# Clean up completed cells before returning
				for g in completed_grids:
					_unloading_cells.erase(g)
					_unloading_hold_frames.erase(g)
					_unloading_frozen.erase(g)
					_unloading_destructive_holds.erase(g)
				return

			# NOTE 2026-04-20: prior `CrashBreadcrumb.write("unload_child", ...)`
			# fired per-child — with UNLOAD_BATCH_SIZE=30 it was the dominant
			# cost inside `_process_budgeted_unloading` (each write is a
			# FileAccess.open+store+close cycle). Removed; crashes never
			# landed on `unload_child`, the cell-level `bu::cell_qfree_*`
			# breadcrumbs still cover the destructor path.
			var child := cell_node.get_child(child_index)
			child_index -= 1
			if child == null or not is_instance_valid(child) or child.is_queued_for_deletion():
				continue
			# Freeze the unload state-reversal window NOW — about to actually
			# destroy a child. Flipping before this point (top of grid loop)
			# would freeze cells that lost the time-budget race without any
			# child being freed, shrinking the reclaim window. Idempotent.
			if not _unloading_frozen.get(grid, false):
				_unloading_frozen[grid] = true
				_record_lifecycle_event("freeze_unload", grid, "reason=child_qfree children=%d" % cell_node.get_child_count())
			child.queue_free()

			batch += 1
			total_freed += 1

		# Check if cell is now empty — state-reversal window closes, finalize.
		if cell_node.get_child_count() == 0:
			CrashBreadcrumb.write("bu::cell_qfree_drained", str(grid))
			if grid in _unloading_request_ids:
				_record_lifecycle_event("finalize_unloaded", grid, "request=%d reason=drained" % _unloading_request_ids[grid])
				_cell_manager.finalize_unloaded_cell(_unloading_request_ids[grid])
				_unloading_request_ids.erase(grid)
			cell_node.queue_free()
			completed_grids.append(grid)

	# Remove completed cells from tracking
	for g in completed_grids:
		_unloading_cells.erase(g)
		_unloading_hold_frames.erase(g)
		_unloading_frozen.erase(g)
		_unloading_destructive_holds.erase(g)

	if debug_enabled and total_freed > 0:
		_debug("Budgeted unload: freed %d objects, %d cells remaining" % [total_freed, _unloading_cells.size()])

	# Phase A: Budgeted RS instance HIDING — hide ~200 instances per frame
	# Replaces the old synchronous hide_cell_instances() that caused 10-32ms spikes
	if _static_renderer and not _pending_rs_hide_cells.is_empty():
		if _static_renderer.has_method("defer_prototype_uploads"):
			_static_renderer.call("defer_prototype_uploads", SC.STATIC_CULL_UPLOAD_DEFER_FRAMES_AFTER_UNLOAD)
		var hide_budget := 200  # Max RS calls per frame for hiding
		var total_hidden := 0
		var completed_hide: Array[int] = []  # indices to remove (collected, then batch-removed)
		for hi in _pending_rs_hide_cells.size():
			if total_hidden >= hide_budget or Time.get_ticks_usec() - start_time >= budget_usec:
				break
			var hide_grid: Vector2i = _pending_rs_hide_cells[hi]
			# Verification hook: skip RS hide for this grid while its hold
			# counter is positive. The grid stays in `_pending_rs_hide_cells`
			# (and `_pending_rs_hide_set`), so `_is_cell_occupied` still gates
			# fresh loads correctly during the wait.
			if _unloading_destructive_holds.get(hide_grid, 0) > 0:
				continue
			var result: Array = _static_renderer.hide_cell_instances_budgeted(hide_grid, hide_budget - total_hidden)
			var hidden_this_call := result[0] as int
			total_hidden += hidden_this_call
			# Freeze only after actual hide work happened. A no-op call (cell
			# had no instances registered, e.g. interior pocket profile) must
			# not shrink the reclaim window. Idempotent.
			if hidden_this_call > 0 and not _unloading_frozen.get(hide_grid, false):
				_unloading_frozen[hide_grid] = true
				_record_lifecycle_event("freeze_unload", hide_grid, "reason=rs_hide hidden=%d" % hidden_this_call)
			if result[1] as bool:  # is_complete
				completed_hide.append(hi)
				_pending_rs_hide_set.erase(hide_grid)
		# Remove completed cells back-to-front to preserve indices
		for ri in range(completed_hide.size() - 1, -1, -1):
			var idx: int = completed_hide[ri]
			_pending_rs_hide_cells[idx] = _pending_rs_hide_cells.back()
			_pending_rs_hide_cells.pop_back()
		if total_hidden > 0 and debug_enabled:
			_debug("Budgeted RS hide: %d instances, %d cells remaining" % [total_hidden, _pending_rs_hide_cells.size()])

	# Phase B: Deferred RS instance cleanup (free_rid) within remaining budget
	# Only process cells that have been fully hidden
	if _static_renderer and not _pending_rs_cleanup_cells.is_empty():
		if _static_renderer.has_method("defer_prototype_uploads"):
			_static_renderer.call("defer_prototype_uploads", SC.STATIC_CULL_UPLOAD_DEFER_FRAMES_AFTER_UNLOAD)
		var rs_freed := 0
		while not _pending_rs_cleanup_cells.is_empty():
			if Time.get_ticks_usec() - start_time >= budget_usec:
				break
			var cleanup_grid: Vector2i = _pending_rs_cleanup_cells[-1]
			# Don't free RIDs for cells still being hidden — O(1) set check
			if cleanup_grid in _pending_rs_hide_set:
				break
			_pending_rs_cleanup_cells.resize(_pending_rs_cleanup_cells.size() - 1)
			_pending_rs_cleanup_set.erase(cleanup_grid)
			rs_freed += _static_renderer.remove_cell_instances(cleanup_grid)
		if rs_freed > 0 and debug_enabled:
			_debug("Budgeted RS cleanup: freed %d instances, %d cells remaining" % [rs_freed, _pending_rs_cleanup_cells.size()])


## Cells with RS instances that need budgeted visibility hiding
## Hides ~200 RS instances per frame to avoid 10-32ms synchronous spikes
var _pending_rs_hide_cells: Array[Vector2i] = []
## O(1) lookup for cells still being hidden (mirrors _pending_rs_hide_cells)
var _pending_rs_hide_set: Dictionary[Vector2i, bool] = {}

## Cells with RS instances that need deferred free_rid() cleanup (after hiding)
var _pending_rs_cleanup_cells: Array[Vector2i] = []
## O(1) lookup mirroring _pending_rs_cleanup_cells. A grid in this set still has
## pending RS instance free work; load gates must treat it as occupied so a fresh
## load can't publish buckets under a grid whose old buckets are about to be freed.
var _pending_rs_cleanup_set: Dictionary[Vector2i, bool] = {}


# S.1 refactor (near_tier_refactor.md 2026-04-19): MID↔NEAR promotion / demotion
# loops deleted. Per-cell tier is the axis of variation; MID re-enable in S.7
# will run through request_cell_tier, not per-actor promote. Git restores
# the deleted functions (previous commit touching this file) if reference is
# needed for the future re-add. Removed:
#   _promoted_objects / _promoted_by_cell fields
#   _process_mid_to_near_promotions
#   _process_promoted_collision_enable
#   _disable_collision_shapes / _enable_collision_shapes (local; model_loader +
#     reference_instantiator keep their own copies for the Node3D spawn path)
#   _demote_all_promoted
#   _process_deferred_near_instantiation


## Configure visibility_range on mesh nodes for cells loaded from non-prebaked
## sources (editor scenes, test scenes). Post-B-wide refactor: prebaked NIFs
## carry `visibility_prebaked` meta AND the embedded LOD chain + 0-500m range
## is set at bake time, so this path is a no-op safety net for edge cases.
func _configure_cell_visibility(cell_node: Node3D) -> void:
	if not use_native_visibility:
		return

	# Skip if visibility_range was already baked into the prebaked models
	var all_prebaked := true
	for child in cell_node.get_children():
		if not child.has_meta("visibility_prebaked"):
			all_prebaked = false
			break

	if all_prebaked and cell_node.get_child_count() > 0:
		return

	# Safety fallback: apply the render-tier visibility_range to any
	# non-prebaked GeometryInstance3D so FAR-tier culling still fires.
	var count := 0
	count = _apply_fallback_visibility_recursive(cell_node, count)
	if debug_enabled and count > 0:
		_debug("Fallback visibility applied to %d nodes in cell %s" % [count, cell_node.name])


func _apply_fallback_visibility_recursive(node: Node, count: int) -> int:
	if node is GeometryInstance3D:
		var geo := node as GeometryInstance3D
		geo.visibility_range_begin = 0.0
		geo.visibility_range_end = DU.MID_END
		geo.visibility_range_begin_margin = 0.0
		geo.visibility_range_end_margin = DU.FADE_MARGIN_LOD3_FAR
		geo.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		count += 1
	for child in node.get_children():
		count = _apply_fallback_visibility_recursive(child, count)
	return count


## Count MeshInstance3D nodes in a tree
func _count_mesh_instances(node: Node) -> int:
	var count := 0
	if node is MeshInstance3D:
		count += 1
	for child in node.get_children():
		count += _count_mesh_instances(child)
	return count


## Process pending cell loads asynchronously (non-blocking)
## Submits async requests for cells in the queue
## Uses staggered loading during startup to prevent freeze
func _process_pending_loads_async() -> void:
	# Dual-purpose SubsystemToggles gate: when `near_objects` is off, stop
	# submitting new cell-load async requests. This kills both NEAR ingress
	# AND the MID flora adds that piggyback on ReferenceInstantiator during
	# the cell load. HLOD + impostors are independent (they read ESM direct).
	if not _near_tier_visible:
		return
	if _pending_load_queue.is_empty():
		return

	var requests_submitted := 0

	var max_requests_per_frame: int = 2

	# Check if there's async capacity before trying to submit
	# This prevents unnecessary fallback to sync loading and reduces warning spam
	var available_slots := _cell_manager.get_async_slots_available() if _cell_manager else 0

	# Don't try to submit if there's no capacity - cells will stay in queue
	if available_slots <= 0 and not _pending_load_queue.is_empty():
		if debug_enabled:
			_debug("Async capacity exhausted, %d cells waiting in queue" % _pending_load_queue.size())
	else:
		while not _pending_load_queue.is_empty() and requests_submitted < max_requests_per_frame and available_slots > 0:
			var grid: Vector2i = _pending_load_queue[-1]
			_pending_load_queue.resize(_pending_load_queue.size() - 1)
			_pending_load_set.erase(grid)

			# Skip if already loaded, loading, mid-unload, or mid-cleanup.
			# Same gate as _request_cell_async; checked here too so a frozen-
			# rejected grid doesn't slip through when the queue submits.
			if _is_cell_occupied(grid):
				continue

			# Submit async request
			if _request_cell_async(grid):
				requests_submitted += 1
				available_slots -= 1

		if requests_submitted > 0 and debug_enabled:
			_debug("Submitted %d async cell requests, %d remaining in queue (startup=%s, frame=%d)" % [
				requests_submitted, _pending_load_queue.size(), _startup_phase, _startup_frames
			])


func _process_payload_publish_steps(budget_usec: int) -> int:
	if _cell_manager == null or budget_usec <= 0 or _async_requests.is_empty():
		return 0
	var start_us := Time.get_ticks_usec()
	var published := 0
	for grid: Vector2i in _async_requests:
		var elapsed := Time.get_ticks_usec() - start_us
		if elapsed >= budget_usec:
			break
		var request_id: int = _async_requests[grid]
		if not _cell_manager.has_method("get_async_payload"):
			break
		var payload: RefCounted = _cell_manager.call("get_async_payload", request_id) as RefCounted
		if payload == null or not payload.has_method("publish_step"):
			continue
		var remaining_usec: int = budget_usec - elapsed
		published += int(payload.call("publish_step", remaining_usec))
	return published


## Process completed async requests
## Checks for finished cell loads and finalizes them
## Cell completion is atomic (add_child + scene-tree emit can't be time-sliced),
## so we cap at 1 per frame. Empirical: each completion ≈ 13ms at 60 FPS load;
## 2 in one frame = 26ms overrun. A time budget wouldn't help here — the work
## is indivisible. The right lever is throughput (cells/s), not latency (ms/cell).
func _process_async_completions() -> void:
	var completed_grids: Array[Vector2i] = []
	var max_completions_per_frame := 1

	for grid: Vector2i in _async_requests:
		if completed_grids.size() >= max_completions_per_frame:
			break
		var request_id: int = _async_requests[grid]

		if _cell_manager.is_async_complete(request_id):
			# Request is complete - finalize
			var cell_node := _cell_manager.get_async_result(request_id)

			if cell_node:
				_configure_cell_visibility(cell_node)
				cell_node.visible = _near_tier_visible

				if cell_node.get_parent() != _world_container:
					_world_container.add_child(cell_node)

				_loaded_cells[grid] = cell_node

				# I.6 Phase 2 — re-home any orphans whose origin grid
				# matches this one. Must run AFTER the cell_node is
				# parented under _world_container so reparent(..., true)
				# resolves the orphan's global transform correctly.
				_rehome_persistent_nodes_for_cell(cell_node, grid)

				var object_count := _count_mesh_instances(cell_node)
				_stats["loaded_cells"] = _loaded_cells.size()
				_stats["total_objects"] += object_count

				# Check for failed models
				if _cell_manager.has_async_failed(request_id):
					var failed_count := _cell_manager.get_async_failed_count(request_id)
					_debug("Cell %s completed with %d failed models" % [grid, failed_count])

				_log_pipeline_compile_for_cell_load(grid, object_count, "async")
				cell_loaded.emit(grid, object_count)
				if _cell_preloader != null:
					_cell_preloader.notify_activated(grid)
				_debug("Async cell %s completed with %d objects" % [grid, object_count])
			else:
				_debug("Async cell %s returned null" % grid)

			completed_grids.append(grid)

	# Clean up completed requests
	for grid in completed_grids:
		_async_requests.erase(grid)
		_loading_cells.erase(grid)

	if not completed_grids.is_empty():
		stats_updated.emit(_stats)


## Process pending cell loads synchronously (blocking fallback)
## DEPRECATED: This sync path can cause significant frame stuttering
## Use async_loading_enabled = true (the default) instead
## This fallback exists only for debugging edge cases
func _process_pending_loads_sync(_delta: float) -> void:
	# Warn about sync loading usage - it causes stuttering
	if Engine.get_frames_drawn() == 1:
		push_warning("[NativeStreamingManager] Using synchronous cell loading - this can cause stuttering. Set async_loading_enabled = true for better performance.")

	# Dual-purpose SubsystemToggles gate — mirror of async path.
	if not _near_tier_visible:
		return

	if _pending_load_queue.is_empty():
		return

	var start_time := Time.get_ticks_msec()
	var cells_loaded_this_frame := 0

	while not _pending_load_queue.is_empty():
		# FIX: Check budget BEFORE starting a new cell load, not after
		var elapsed := Time.get_ticks_msec() - start_time
		if cells_loaded_this_frame > 0 and elapsed >= frame_budget_ms:
			if debug_enabled or _pending_load_queue.size() > 5:
				_debug("Frame budget reached (%.1fms), loaded %d cells, %d remaining" % [elapsed, cells_loaded_this_frame, _pending_load_queue.size()])
			break

		var grid: Vector2i = _pending_load_queue[-1]
		_pending_load_queue.resize(_pending_load_queue.size() - 1)
		_pending_load_set.erase(grid)

		# Same occupancy gate as the async path: a grid mid-unload or with
		# pending RS cleanup must not get a fresh load until the old cleanup
		# clears (auditor2 finding 2026-05-01).
		if _is_cell_occupied(grid):
			continue

		_load_cell_sync(grid)
		cells_loaded_this_frame += 1
		_stats["load_time_ms"] = Time.get_ticks_msec() - start_time

	if debug_enabled and cells_loaded_this_frame > 0 and _pending_load_queue.is_empty():
		var elapsed := Time.get_ticks_msec() - start_time
		_debug("Sync loaded %d cells in %.1fms" % [cells_loaded_this_frame, elapsed])

#endregion


#region Public API

## Get current streaming statistics
func get_stats() -> Dictionary:
	var s := _stats.duplicate()

	# Add load queue stats and telemetry
	s["frame_overrun_count"] = _frame_overrun_count
	s["load_queue_size"] = _pending_load_queue.size()
	s["async_requests"] = _async_requests.size()
	s["async_loading_enabled"] = async_loading_enabled
	s["camera_cell"] = _camera_cell
	s["camera_position"] = _camera_position
	s["frame_budget_ms"] = frame_budget_ms
	s["frame_total_ms"] = _last_frame_total_ms
	s["startup_phase"] = _startup_phase

	# Add CellManager async stats if available
	if _cell_manager and _cell_manager.has_method("get_loading_stats"):
		var cm_stats: Dictionary = _cell_manager.get_loading_stats()
		s["instantiation_queue"] = cm_stats.get("instantiation_queue_size", 0)
		s["pending_conversions"] = cm_stats.get("pending_conversions", 0)
		s["pending_disk_loads"] = cm_stats.get("pending_disk_loads", 0)
		s["burst_loading"] = cm_stats.get("burst_loading_active", false)

	# Merge impostor stats if available
	if _impostor_renderer and _impostor_renderer.has_method("get_stats"):
		s.merge(_impostor_renderer.call("get_stats"))

	# Merge MID-tier static renderer stats
	if _static_renderer:
		var sr_stats: Dictionary = _static_renderer.get_stats()
		s["mid_instances"] = sr_stats.get("total_instances", 0)
		s["mid_visible"] = sr_stats.get("visible_instances", 0)
		s["mid_mesh_types"] = sr_stats.get("mesh_types", 0)

	# Merge HLOD stats
	if _hlod_merger:
		var hlod_stats: Dictionary = _hlod_merger.get_stats()
		s["hlod_cells"] = hlod_stats.get("active_cells", 0)
		s["hlod_pending"] = hlod_stats.get("pending_merges", 0)
		s["hlod_cache_mb"] = hlod_stats.get("cache_bytes", 0) / (1024.0 * 1024.0)

	return s


## Get last frame's per-phase timing breakdown (usec).
## Indices: 0=unload, 1=async_complete, 2=instantiate, 3=promote, 4=collision,
##          5=deferred, 6=queue, 7=cell_update, 8=static_cull
## Returns empty array if not yet initialized.
func get_phase_times() -> PackedFloat64Array:
	return _last_phase_times


## Get last frame's total streaming work in ms.
func get_frame_streaming_ms() -> float:
	return _last_frame_total_ms


func consume_lifecycle_events() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _lifecycle_events.size() < MAX_LIFECYCLE_EVENTS:
		out.append_array(_lifecycle_events)
	else:
		var start := _lifecycle_event_write_index % MAX_LIFECYCLE_EVENTS
		for i in range(MAX_LIFECYCLE_EVENTS):
			out.append(_lifecycle_events[(start + i) % MAX_LIFECYCLE_EVENTS])
	_lifecycle_events.clear()
	_lifecycle_event_write_index = 0
	return out


func set_lifecycle_capture_enabled(enabled: bool) -> void:
	debug_lifecycle_capture_enabled = enabled
	_lifecycle_events.clear()
	_lifecycle_event_write_index = 0


func _record_lifecycle_event(event_name: String, grid: Vector2i, detail: String = "") -> void:
	if not debug_lifecycle_capture_enabled:
		return
	var entry := {
		"frame": Engine.get_frames_drawn(),
		"elapsed_s": Time.get_ticks_msec() / 1000.0,
		"event": event_name,
		"detail": "%s %s" % [str(grid), detail],
	}
	if _lifecycle_events.size() < MAX_LIFECYCLE_EVENTS:
		_lifecycle_events.append(entry)
	else:
		_lifecycle_events[_lifecycle_event_write_index % MAX_LIFECYCLE_EVENTS] = entry
	_lifecycle_event_write_index += 1
	Log.info("streaming", "[P0.4-LIFECYCLE] %s %s" % [event_name, entry["detail"]])


## Get or create the per-phase StreamingProfiler.
## Benchmark / debug overlay reads this to display per-phase timing.
func get_profiler() -> StreamingProfilerScript:
	if not _profiler:
		_profiler = StreamingProfilerScript.new()
		_profiler.enabled = SC.ENABLE_PROFILING
	return _profiler


## Get StaticObjectRenderer stats (for benchmark diagnostics)
func get_static_renderer_stats() -> Dictionary:
	if _static_renderer:
		return _static_renderer.get_stats()
	return {}


## Print detailed debug information to console (for troubleshooting)
func print_debug_info() -> void:
	var lines: Array[String] = []
	lines.append("========== NATIVE STREAMING DEBUG INFO ==========")
	lines.append("Initialized: %s" % _initialized)
	lines.append("Camera: %s" % _camera)
	lines.append("Camera Cell: %s" % _camera_cell)
	lines.append("Camera Position: %s" % _camera_position)
	lines.append("Settings:")
	lines.append("  load_radius_cells: %s" % load_radius_cells)
	lines.append("  impostor_radius_cells: %s" % impostor_radius_cells)
	lines.append("  frame_budget_ms: %s" % frame_budget_ms)
	lines.append("  use_native_visibility: %s" % use_native_visibility)
	lines.append("  async_loading_enabled: %s" % async_loading_enabled)
	lines.append("  debug_enabled: %s" % debug_enabled)
	lines.append("Async Loading:")
	lines.append("  BackgroundProcessor: %s" % (_background_processor != null))
	lines.append("  Pending async requests: %s" % _async_requests.size())
	lines.append("  Load queue size: %s" % _pending_load_queue.size())
	if _cell_manager and _cell_manager.has_method("get_loading_stats"):
		var cm_stats: Dictionary = _cell_manager.get_loading_stats()
		lines.append("  Instantiation queue: %s" % cm_stats.get("instantiation_queue_size", 0))
		lines.append("  Pending conversions: %s" % cm_stats.get("pending_conversions", 0))
	lines.append("Stats:")
	var stats = get_stats()
	for key in stats:
		lines.append("  %s: %s" % [key, stats[key]])
	lines.append("Impostor Renderer:")
	if _impostor_renderer:
		lines.append("  Exists: true")
		lines.append("  ImpostorCandidates: %s" % (_impostor_renderer.impostor_candidates != null))
		lines.append("  Debug enabled: %s" % _impostor_renderer.debug_enabled)
	else:
		lines.append("  Exists: false")
	lines.append("=================================================")
	Log.info("streaming", "\n".join(lines))


## Force reload all cells (after configuration change)
func reload_all_cells() -> void:
	# Unload all current cells
	for grid: Vector2i in _loaded_cells.keys():
		_unload_cell(grid)
	
	# Trigger reload
	_update_loaded_cells()


## Get loaded cell at grid position (overload for backwards compatibility)
func get_loaded_cell(x: Variant, y: Variant = null) -> Node3D:
	if y == null:
		# Called with Vector2i
		var grid: Vector2i = x
		return _loaded_cells.get(grid, null)
	else:
		# Called with x, y integers
		var grid := Vector2i(int(x), int(y))
		return _loaded_cells.get(grid, null)


## Check if a cell is loaded
func is_cell_loaded(grid: Vector2i) -> bool:
	return grid in _loaded_cells


# ----------------------------------------------------------------------------
# Subsystem visibility toggles (for benchmark A/B testing)
# ----------------------------------------------------------------------------
# Each method delegates to the owning subsystem — no internal reach-around.

## Toggle MID-tier RS instances (StaticObjectRenderer)
func set_mid_tier_visible(visible: bool) -> void:
	if _static_renderer:
		_static_renderer.set_all_visible(visible)

## Toggle FAR-tier impostors (NativeImpostorRenderer) — hides + stops streaming.
func set_impostors_visible(visible: bool) -> void:
	if _impostor_renderer:
		_impostor_renderer.set_enabled(visible)

## Toggle NEAR-tier Node3D cells (loaded cell containers).
## Remembers state so cells loaded after the toggle respect it.
var _near_tier_visible: bool = true
## Set when near tier is thawed after being off — forces 25ms instantiation budget
## until the queue drains, without touching _startup_phase (which has broader effects).
var _near_burst_drain: bool = false

func set_near_tier_visible(visible: bool) -> void:
	var was_visible := _near_tier_visible
	_near_tier_visible = visible
	for grid: Vector2i in _loaded_cells:
		var cell_node: Node3D = _loaded_cells[grid]
		if cell_node:
			cell_node.visible = visible
	# On thaw: arm burst drain + force catch-up cell scan.
	if visible and not was_visible:
		_near_burst_drain = true
		Log.info("streaming", "NEAR thaw — burst drain armed")
		_update_loaded_cells()

## Toggle HLOD merged geometry (ObjectPaging)
func set_hlod_visible(visible: bool) -> void:
	if _hlod_merger:
		_hlod_merger.set_all_visible(visible)
	if _static_renderer:
		_static_renderer.visibility_range_end = DU.HLOD_START if visible else DU.MID_END
	if _impostor_renderer and _impostor_renderer.has_method("set_visibility_range_begin"):
		_impostor_renderer.set_visibility_range_begin(DU.HLOD_END if visible else DU.MID_END)
	if visible:
		_hlod_needs_initial_update = true

## Toggle distant-light billboard MultiMesh (DistantLightManager) — hides + stops streaming.
func set_distant_lights_visible(visible: bool) -> void:
	if _distant_light_manager:
		_distant_light_manager.set_enabled(visible)


# ----------------------------------------------------------------------------
# I.6 — Persistent node registry (held / carried items)
# ----------------------------------------------------------------------------
#
# Public API for systems that need to keep a node alive across cell
# unloads (currently `CarryController` for held bodies; future
# consumers: dropped items, NPC corpses, save-system anchors).
#
# Per `docs/INTERACTION_SYSTEM.md` §10:
# - On grab: caller invokes `register_persistent_node(body, grid)`
# - On cell unload: streaming manager reparents matching nodes to
#   `_orphan_container` so they survive the cell teardown
# - On cell reload: streaming manager re-homes orphans keyed to that
#   grid back into the loaded cell node (Phase 2 — not implemented yet)
# - On release: caller invokes `unregister_persistent_node(body)`
#
# Per spec §9: orphan registry is a child of `NativeStreamingManager`,
# NOT an autoload. Hard rule.

## Register a node as persistent. The node will be reparented to the
## orphan registry when its origin cell unloads instead of being freed
## with the cell. Caller MUST call `unregister_persistent_node` when
## the node no longer needs the protection (e.g. on release for a held
## item) — the registry does not auto-clean on free, because Godot's
## `tree_exiting` signal also fires on `reparent()` which is exactly
## what the evacuation path does. Stale entries are pruned lazily via
## `is_instance_valid` checks in the evacuation walk.
##
## The `original_grid` is the grid coordinate of the cell that contains
## the node at registration time. Used as the re-home key when the cell
## reloads. Pass `find_grid_for_node(node)` if you don't track it
## yourself. Timestamp + last-known-player grid are captured for the
## Phase 2 bound policy (5 min / 8 cell expiry).
func register_persistent_node(node: Node3D, original_grid: Vector2i) -> void:
	if node == null:
		return
	var entry := PersistentNodeEntry.new()
	entry.original_grid = original_grid
	entry.created_ms = Time.get_ticks_msec()
	entry.last_known_player_grid = _camera_cell
	_persistent_nodes[node] = entry


## Unregister a previously-registered persistent node. Idempotent.
## Does NOT reparent the node — caller decides where it goes after
## release (back into a loaded cell, into the orphan registry, etc.).
func unregister_persistent_node(node: Node3D) -> void:
	if node == null:
		return
	_persistent_nodes.erase(node)


## Walk the node's ancestor chain looking for a loaded cell. Returns
## the cell's grid coordinate if found, or `Vector2i(INT_MIN, INT_MIN)`
## as a sentinel if no ancestor is in the loaded set. Used by callers
## who need to capture the origin grid at registration time.
func find_grid_for_node(node: Node3D) -> Vector2i:
	if node == null:
		return Vector2i(-2147483648, -2147483648)
	var current: Node = node.get_parent()
	while current != null:
		# Build a reverse lookup once per call — fine for low-frequency
		# grab events, not on hot path.
		for grid: Vector2i in _loaded_cells:
			if _loaded_cells[grid] == current:
				return grid
		current = current.get_parent()
	return Vector2i(-2147483648, -2147483648)


## Internal — called from `_unload_cell` BEFORE the cell goes into the
## unload container. Walks `_persistent_nodes`, finds any whose ancestor
## chain leads to `cell_node`, reparents them to `_orphan_container`
## with global transform preserved.
func _evacuate_persistent_nodes_from_cell(cell_node: Node3D, grid: Vector2i) -> void:
	if _persistent_nodes.is_empty() or _orphan_container == null:
		return
	# Snapshot keys to a plain Array — `_persistent_nodes` is untyped
	# but iterating it directly while pruning dead entries can still
	# trip the engine's safety checks. Snapshot, walk, prune at the end.
	var keys: Array = _persistent_nodes.keys()
	var to_evacuate: Array[Node3D] = []
	var dead_keys: Array = []
	for key in keys:
		if not is_instance_valid(key):
			dead_keys.append(key)
			continue
		var node: Node3D = key as Node3D
		if node == null:
			dead_keys.append(key)
			continue
		# Walk ancestors — is `cell_node` in the chain?
		var ancestor: Node = node.get_parent()
		while ancestor != null:
			if ancestor == cell_node:
				to_evacuate.append(node)
				# Re-key to the actual current grid (which is the same
				# as the unload grid; explicit re-record for clarity).
				var entry: PersistentNodeEntry = _persistent_nodes[node]
				if entry == null:
					entry = PersistentNodeEntry.new()
					entry.created_ms = Time.get_ticks_msec()
				entry.original_grid = grid
				entry.last_known_player_grid = _camera_cell
				_persistent_nodes[node] = entry
				break
			ancestor = ancestor.get_parent()
	# Lazy prune dead entries discovered during the walk.
	for k in dead_keys:
		_persistent_nodes.erase(k)
	for node in to_evacuate:
		# `reparent` preserves global transform — held bodies' world
		# pos shouldn't jump on unload.
		node.reparent(_orphan_container, true)
		_debug("Evacuated persistent node '%s' from cell %s to orphan registry" % [node.name, grid])


## I.6 Phase 2 — called from `_load_cell_sync` and the async loader
## after a cell_node enters `_world_container`. Walks the orphan
## registry, finds entries whose `original_grid` matches the loading
## cell, and reparents the node back into the newly loaded cell with
## global transform preserved. If the re-home position is off the
## cell's terrain / inside a wall / otherwise invalid, the walk-back
## fallback raycasts downward against layer 1 (Environment) and drops
## the body to the first hit — prevents items from vanishing through
## deformed terrain between unload and reload.
func _rehome_persistent_nodes_for_cell(cell_node: Node3D, grid: Vector2i) -> void:
	if _persistent_nodes.is_empty() or cell_node == null:
		return
	var keys: Array = _persistent_nodes.keys()
	var dead_keys: Array = []
	var rehomed_count := 0
	for key in keys:
		if not is_instance_valid(key):
			dead_keys.append(key)
			continue
		var node: Node3D = key as Node3D
		if node == null:
			dead_keys.append(key)
			continue
		var entry: PersistentNodeEntry = _persistent_nodes[key]
		if entry == null:
			dead_keys.append(key)
			continue
		if entry.original_grid != grid:
			continue
		# Only re-home nodes that were actually evacuated to the orphan
		# container. A held item's _held_body is still under the player
		# camera Marker3D — we don't touch those. Evacuated nodes live
		# directly under `_orphan_container` (reparent is not deep).
		if node.get_parent() != _orphan_container:
			continue
		node.reparent(cell_node, true)
		_apply_walkback_ground_snap(node, cell_node)
		rehomed_count += 1
		_debug("Re-homed persistent node '%s' back into cell %s" % [node.name, grid])
	for k in dead_keys:
		_persistent_nodes.erase(k)
	if rehomed_count > 0 and debug_enabled:
		_debug("Cell %s reload re-homed %d orphan(s)" % [grid, rehomed_count])


## Walk-back ground-snap safety net. After a re-home `reparent` the
## node's global_position is whatever it was at evacuation. If that
## point is (a) below the reloaded cell's terrain (terrain tile was
## deformed or regenerated while the cell was gone) or (b) inside a
## collider, a short downward raycast from a safe offset above the
## original position picks the nearest layer 1 (Environment) contact
## and drops the body there. Cheap, bounded, and avoids the
## "item falls through the world on cell reload" edge case.
func _apply_walkback_ground_snap(node: Node3D, _cell_node: Node3D) -> void:
	const WALKBACK_PROBE_UP: float = 3.0
	const WALKBACK_PROBE_DOWN: float = 50.0
	const ENV_LAYER_BIT: int = 1 << 0  # Layer 1 = Environment
	var space := node.get_world_3d().direct_space_state if node.is_inside_tree() else null
	if space == null:
		return
	var pos := node.global_position
	var from := Vector3(pos.x, pos.y + WALKBACK_PROBE_UP, pos.z)
	var to := Vector3(pos.x, pos.y - WALKBACK_PROBE_DOWN, pos.z)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = ENV_LAYER_BIT
	query.collide_with_areas = false
	query.collide_with_bodies = true
	# Exclude the node itself so a held body doesn't self-hit.
	if node is CollisionObject3D:
		query.exclude = [(node as CollisionObject3D).get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return
	var hit_pos: Vector3 = hit.get("position", pos)
	# If the current position is within 0.25m of the ground hit, leave
	# it alone — we don't want to snap a stable resting item. Only
	# correct genuinely invalid placements.
	if absf(pos.y - hit_pos.y) < 0.25 and pos.y >= hit_pos.y:
		return
	node.global_position = Vector3(pos.x, hit_pos.y + 0.05, pos.z)


## I.6 Phase 2 — periodic orphan expiry pass. Walks `_persistent_nodes`
## filtering to entries whose current parent is `_orphan_container`
## (i.e. actually orphaned right now, not held). Nodes that exceed the
## 5-minute wall-clock budget OR whose `original_grid` is more than
## ORPHAN_EXPIRY_CELL_DISTANCE Chebyshev cells from the current player
## grid get deferred-queue-freed and their entries erased. Held items
## (parent is camera Marker3D) are never touched — the player still
## owns them.
##
## Called at ORPHAN_PRUNE_INTERVAL_S from `_process`.
func _prune_expired_orphans() -> void:
	if _persistent_nodes.is_empty() or _orphan_container == null:
		return
	var keys: Array = _persistent_nodes.keys()
	var dead_keys: Array = []
	var now_ms: int = Time.get_ticks_msec()
	var expired_count := 0
	for key in keys:
		if not is_instance_valid(key):
			dead_keys.append(key)
			continue
		var node: Node3D = key as Node3D
		if node == null:
			dead_keys.append(key)
			continue
		var entry: PersistentNodeEntry = _persistent_nodes[key]
		if entry == null:
			dead_keys.append(key)
			continue
		# Only expire actually-orphaned nodes. Held items live under
		# the player camera and must stay alive until released.
		if node.get_parent() != _orphan_container:
			# Update the last-known-player grid while we're here so the
			# Chebyshev check stays current after re-home.
			entry.last_known_player_grid = _camera_cell
			continue
		var age_ms: int = now_ms - entry.created_ms
		var dx: int = absi(entry.original_grid.x - _camera_cell.x)
		var dy: int = absi(entry.original_grid.y - _camera_cell.y)
		var chebyshev: int = maxi(dx, dy)
		if age_ms > ORPHAN_EXPIRY_MS or chebyshev > ORPHAN_EXPIRY_CELL_DISTANCE:
			dead_keys.append(key)
			if is_instance_valid(node) and not node.is_queued_for_deletion():
				node.queue_free()
			expired_count += 1
	for k in dead_keys:
		_persistent_nodes.erase(k)
	if expired_count > 0:
		_debug("Expired %d orphan(s) (age>5min or chebyshev>%d cells)" % [
			expired_count, ORPHAN_EXPIRY_CELL_DISTANCE])


## Get the impostor renderer (for console commands and diagnostics)
func get_impostor_manager() -> Node3D:
	return _impostor_renderer


## Teleport to a new location (forces immediate cell reload)
func teleport_to(position: Vector3) -> void:
	_camera_position = position
	_camera_cell = DU.world_to_cell(position)

	# S.1: promotion tracking deleted — no promoted objects to batch-free.

	# Unload all cells
	for grid: Vector2i in _loaded_cells.keys():
		_unload_cell(grid)

	# Load cells around new position
	_update_loaded_cells()


## Get the camera's current cell grid coordinate
func get_camera_cell() -> Vector2i:
	return _camera_cell


## Get all loaded cell coordinates
func get_loaded_cell_coordinates() -> Array[Vector2i]:
	var coords: Array[Vector2i] = []
	for grid: Vector2i in _loaded_cells:
		coords.append(grid)
	return coords


## Get all loaded cell Node3D containers (for object picking)
func get_loaded_cell_nodes() -> Array:
	var nodes: Array = []
	for grid: Vector2i in _loaded_cells:
		var cell: Variant = _loaded_cells[grid]
		if is_instance_valid(cell):
			nodes.append(cell)
	return nodes


## Refresh cells around camera
## Forces a check of which cells should be loaded
func refresh_cells() -> void:
	if _initialized:
		_update_loaded_cells()

#endregion


#region Utilities

## Calculate dynamic frame budget based on actual FPS
## At 60 FPS: ~8ms (same as static INSTANTIATION_BUDGET_MS)
## At 30 FPS: ~16ms (more time per frame available)
## At 120 FPS: ~4ms (less time to stay within frame budget)
func _get_dynamic_budget(delta: float) -> float:
	var frame_time_ms := delta * 1000.0
	var budget := frame_time_ms * SC.INSTANTIATION_BUDGET_FRACTION
	return clampf(budget, SC.INSTANTIATION_BUDGET_MIN_MS, SC.INSTANTIATION_BUDGET_MAX_MS)

#endregion


#region Debug

func _debug(msg: String) -> void:
	if debug_enabled:
		Log.debug("streaming", msg)


## Phase 2 stutter diag — log pipeline compile delta at cell-load completion.
## Companion to the per-5s heartbeat: heartbeat shows TOTAL deltas over a slice,
## this shows the delta attributable specifically to one cell's add_child window.
##
## Decision tree for the resulting log line (plan §2.2):
##   Δ:m+sf>0, dr=0  → engine pre-compiled at instantiation; expected. If preload
##                     delta was ALSO 0 then ResourceLoader.load alone isn't
##                     sufficient — we need hidden-instance pre-warm in CellPreloader.
##   Δ:dr>0          → first-visibility shader stutter. Missed pre-warm window.
##                     Almost always means the asset entered the scene without
##                     the engine having seen its mesh+material combo before.
##   Δ:sp>0          → ubershader background optimization fired. Non-stuttering.
func _log_pipeline_compile_for_cell_load(grid: Vector2i, object_count: int, mode: String) -> void:
	if _pipeline_compile_per_cell == null:
		return
	var d: PackedInt64Array = _pipeline_compile_per_cell.delta_and_update()
	if not PipelineCompileMonitorScript.has_activity(d):
		return  # silent — nothing happened during this cell-load window
	var level := "warn" if PipelineCompileMonitorScript.has_draw_compile(d) else "info"
	var msg := "[pipe-cell %s %s] objs=%d %s" % [
		mode, grid, object_count, PipelineCompileMonitorScript.format_delta(d),
	]
	if level == "warn":
		Log.warn("streaming", msg)
	else:
		Log.info("streaming", msg)

#endregion


#region Startup Progress

## Emit startup progress signal for parent UI to handle
func _emit_startup_progress() -> void:
	var target_cells := (2 * load_radius_cells + 1) * (2 * load_radius_cells + 1)  # (2r+1)² grid
	var loaded := _loaded_cells.size()
	var loading := _loading_cells.size()
	var queue_size := _cell_manager.get_instantiation_queue_size() if _cell_manager else 0

	# Combined progress: cells (0-40%) + impostors (40-100%)
	var cell_progress := 0.0
	if target_cells > 0:
		cell_progress = float(loaded + loading * 0.5) / float(target_cells)
		cell_progress = clampf(cell_progress, 0.0, 1.0)

	var impostor_progress := 0.0
	if _impostor_renderer:
		var initial: int = _impostor_renderer.get_initial_pending_count()
		var pending: int = _impostor_renderer.get_pending_cell_count()
		var processed: int = initial - pending
		# Progress is based on inner ring completion, not the full 11K+ cell ring
		var inner_ring_radius: int = load_radius_cells + 2
		var inner_ring_count: int = int(PI * inner_ring_radius * inner_ring_radius)
		if inner_ring_count > 0:
			impostor_progress = float(processed) / float(inner_ring_count)
			impostor_progress = clampf(impostor_progress, 0.0, 1.0)

	var progress := (cell_progress * 40.0) + (impostor_progress * 60.0)
	progress = clampf(progress, 0.0, 100.0)

	startup_progress.emit(progress, loaded, target_cells, queue_size)

## Check if startup phase should end
func _check_startup_complete() -> void:
	if not _startup_phase or _startup_frames < 20:
		return
	# Safety timeout: don't block loading screen longer than 10 seconds (~600 frames)
	if _startup_frames > 600:
		Log.warn("streaming", "Startup timeout after %d frames — forcing completion" % _startup_frames)
		_startup_phase = false
		if _impostor_renderer:
			_impostor_renderer.set_load_budget_usec(4000.0)
		# Deferred impostor scan — was blocked during startup to reduce load pressure
		_impostor_update_pending = true
		startup_complete.emit()
		return
	var queue_size := _cell_manager.get_instantiation_queue_size() if _cell_manager else 0
	var impostor_pending: int = _impostor_renderer.get_pending_cell_count() if _impostor_renderer else 0
	var impostor_initial: int = _impostor_renderer.get_initial_pending_count() if _impostor_renderer else 1
	# Inner ring = just beyond the load radius — enough for visual horizon
	var inner_ring_radius: int = load_radius_cells + 2
	var inner_ring_count: int = int(PI * inner_ring_radius * inner_ring_radius)
	var impostor_processed: int = impostor_initial - impostor_pending
	var impostor_inner_ring_done: bool = impostor_processed >= inner_ring_count or impostor_pending == 0
	# Wait for nearby cells loaded + instantiation queue manageable + inner ring impostors
	# Don't be too strict — player shouldn't wait 30s for every impostor
	var nearby_cells_loaded := _loaded_cells.size() >= mini(load_radius_cells * 2 + 1, 7)
	# Diagnostic: log startup progress every 60 frames
	if _startup_frames % 60 == 0:
		Log.info("streaming", "Startup check: cells=%d/%d queue=%d imp_processed=%d/%d imp_pending=%d" % [
			_loaded_cells.size(), mini(load_radius_cells * 2 + 1, 7),
			queue_size, impostor_processed, inner_ring_count,
			impostor_pending])
	if nearby_cells_loaded and queue_size < 50 and impostor_inner_ring_done:
		_startup_phase = false
		_post_startup_start_ms = Time.get_ticks_msec()
		# Restore normal impostor budget
		if _impostor_renderer:
			_impostor_renderer.set_load_budget_usec(4000.0)
		# Deferred impostor scan — was blocked during startup to reduce load pressure
		_impostor_update_pending = true
		startup_complete.emit()
		Log.info("streaming", "Startup phase complete after %d frames, %d cells loaded, %d impostor cells remaining (inner ring: %d/%d processed)" % [
			_startup_frames, _loaded_cells.size(), impostor_pending, impostor_processed, inner_ring_count])


## Check if currently in startup phase
func is_in_startup_phase() -> bool:
	return _startup_phase


# -----------------------------------------------------------------------------
# Inner-ring readiness API (Phase 8 — LoadingStateMachine consumer)
# -----------------------------------------------------------------------------

## Size of the inner ring in "cell radius". Inner ring = (2r+1)² cells
## centred on the camera cell. INNER_RING_RADIUS=1 means the 3×3 block
## right under the player. Matches the post-v4 `load_radius_cells = 1`
## default (the loading gate and the streaming radius are now identical —
## "playable at arm's reach" is the initial cell-streaming readiness gate).
const INNER_RING_RADIUS: int = 1

## Soft cap on the instantiation queue for the "ready" gate. The queue
## trickles down steady-state; we don't require 0, just low enough that
## the next 2–3 s of gameplay won't stall. 8 picked empirically — matches
## the 2 cells/frame HLOD merge rate × ~4 frames of tolerable post-unpause
## trickling.
const FIRST_PLAYABLE_MAX_QUEUE: int = 8


## Return a snapshot of inner-ring load state. Read by LoadingStateMachine's
## predicate + progress callables; also surfaced to the perf-audit
## autobench JSON for post-hoc analysis.
##
## Fields:
##   ring_loaded       — how many of the (2r+1)² cells in the inner ring
##                       are playable: present in _loaded_cells and either
##                       fully completed or past the cell data/resource gate.
##   ring_total        — (2 * INNER_RING_RADIUS + 1) ** 2 — constant, for
##                       convenience.
##   ring_pending_async — cells in the ring still waiting on the worker
##                        thread (in _async_requests or _loading_cells).
##   instantiation_queue — CellManager's queued instantiation batches.
##                         Drains ~2 per frame; treated as a soft cap.
##   camera_cell       — the cell the ring is centred on.
func get_inner_ring_status() -> Dictionary:
	var center: Vector2i = _camera_cell
	# Count the scheduler-visible ring, not the theoretical grid. Coastal or
	# sparse data sources may never queue every coordinate in the 3x3 block.
	var ring_total: int = 0
	var ring_loaded: int = 0
	var ring_pending_async: int = 0
	for dx in range(-INNER_RING_RADIUS, INNER_RING_RADIUS + 1):
		for dy in range(-INNER_RING_RADIUS, INNER_RING_RADIUS + 1):
			var grid := Vector2i(center.x + dx, center.y + dy)
			var tracked := (
				grid in _loaded_cells
				or grid in _loading_cells
				or grid in _async_requests
				or grid in _pending_load_set
			)
			if not tracked:
				continue
			ring_total += 1
			if grid in _loaded_cells:
				if grid not in _async_requests:
					ring_loaded += 1
				elif _cell_manager and _cell_manager.has_method("is_async_visual_playable"):
					var request_id: int = int(_async_requests[grid])
					if bool(_cell_manager.call("is_async_visual_playable", request_id)):
						ring_loaded += 1
					else:
						ring_pending_async += 1
				else:
					ring_pending_async += 1
			elif grid in _loading_cells or grid in _async_requests:
				ring_pending_async += 1
	var inst_queue: int = 0
	if _cell_manager and _cell_manager.has_method("get_instantiation_queue_size"):
		inst_queue = _cell_manager.get_instantiation_queue_size()
	return {
		"ring_loaded": ring_loaded,
		"ring_total": ring_total,
		"ring_pending_async": ring_pending_async,
		"instantiation_queue": inst_queue,
		"first_playable_queue_cap": FIRST_PLAYABLE_MAX_QUEUE,
		"camera_cell": center,
	}


## Option-A acceptance gate (see docs/audit/LOADING_STATE_MACHINE_DESIGN.md):
## every cell in the (2r+1)² inner ring is loaded, no ring cell is still
## async-pending, and the global instantiation queue is below
## INNER_RING_MAX_QUEUE so the next few seconds of gameplay won't stall.
func is_inner_ring_ready() -> bool:
	var s := get_inner_ring_status()
	if not _startup_phase:
		return (
			int(s["ring_pending_async"]) == 0
			and int(s["instantiation_queue"]) <= FIRST_PLAYABLE_MAX_QUEUE
		)
	return (
		int(s["ring_total"]) > 0
		and int(s["ring_loaded"]) >= int(s["ring_total"])
		and int(s["ring_pending_async"]) == 0
		and int(s["instantiation_queue"]) <= FIRST_PLAYABLE_MAX_QUEUE
	)


## Called by the loading gate when the first playable frame has been reached
## or the gate times out. It ends the high-budget startup phase so leftover
## queue work drains under the normal runtime budget after the overlay hides.
func mark_first_playable(reason: String = "loading_gate") -> void:
	if not _startup_phase:
		return
	_startup_phase = false
	_post_startup_start_ms = Time.get_ticks_msec()
	if _impostor_renderer:
		_impostor_renderer.set_load_budget_usec(4000.0)
	_impostor_update_pending = true
	startup_complete.emit()
	var queue_size := _cell_manager.get_instantiation_queue_size() if _cell_manager else 0
	Log.info("streaming", "[first-playable] reason=%s frames=%d loaded_cells=%d queue=%d" % [
		reason,
		_startup_frames,
		_loaded_cells.size(),
		queue_size,
	])

#endregion
