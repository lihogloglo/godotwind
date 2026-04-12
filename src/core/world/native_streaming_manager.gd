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
const NativeImpostorRendererScript := preload("res://src/core/world/native_impostor_renderer.gd")
const ImpostorCandidatesScript := preload("res://src/core/world/impostor_candidates.gd")
const MeshVisibilityUtils := preload("res://src/core/world/mesh_visibility_utils.gd")
const CS := preload("res://src/core/coordinate_system.gd")
const BackgroundProcessorScript := preload("res://src/core/streaming/background_processor.gd")
const StaticObjectRendererScript := preload("res://src/core/world/static_object_renderer.gd")
const GPUSceneDatabaseScript := preload("res://src/core/gpu_driven/gpu_scene_database.gd")
const DistantLightManagerScript := preload("res://src/core/world/distant_light_manager.gd")
const HLODLoaderScript := preload("res://src/core/world/hlod_loader.gd")
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

#endregion


#region Configuration

## Radius (in cells) to keep loaded around camera
@export var load_radius_cells: int = 3

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
@export var view_distance_cells: int = 3:
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

## GPU scene database for SSBO-backed world state (Phase 2)
var _gpu_scene_db: GPUSceneDatabaseScript = null

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
## Indices: 0=unload, 1=async_complete, 2=instantiate, 3=promote, 4=collision, 5=deferred, 6=queue, 7=cell_update
var _last_phase_times: PackedFloat64Array = PackedFloat64Array()
var _last_frame_total_ms: float = 0.0

## Startup phase state - controls staggered loading during initial population
var _startup_phase: bool = true
var _startup_frames: int = 0
const STARTUP_PHASE_FRAMES: int = 20  # ~0.33 seconds at 60 FPS — matches exit condition

## Deferred impostor update — set when camera cell changes, processed next frame
## Prevents impostor scan (170ms+ on first call) from stacking with cell load/unload
var _impostor_update_pending: bool = false

## Distant light manager — billboard sprites for lights beyond NEAR tier (150m–5km)
var _distant_light_manager: DistantLightManager = null

## HLOD loader — cell-level merged meshes for 300-1000m range
var _hlod_loader: HLODLoaderScript = null

## Sun elevation in radians (set externally by world_explorer via set_sun_elevation)
var _sun_elevation_rad: float = 0.5  # Default: daytime

## Predictive loading — pre-queue cells in the camera's movement direction
var _prev_camera_position: Vector3 = Vector3.ZERO
var _camera_velocity_xz: Vector2 = Vector2.ZERO  # EMA-smoothed, XZ plane only

## HLOD needs initial population on first frame after startup
var _hlod_needs_initial_update: bool = true
## Tracks whether camera crossed a cell boundary this frame
var _cell_changed_this_frame: bool = false

## Per-phase profiler. Created lazily on first access when SC.ENABLE_PROFILING is true.
## External consumers (benchmark, debug overlay) read via get_profiler().
var _profiler: StreamingProfilerScript = null

#endregion


#region Initialization

## Fast cleanup for quit — frees only RS resources, skips slow node tree ops
## Called from world_explorer's _do_fast_quit() before get_tree().quit()
func fast_cleanup() -> void:
	# Stop background processor immediately — prevents WTP handle blocking in _exit_tree
	if _background_processor:
		_background_processor._running = false
		_background_processor._active_tasks.clear()
		_background_processor._pending_tasks.clear()
		_background_processor._orphaned_wtp_handles.clear()

	# Free GPU resources (RS RIDs)
	if _static_renderer:
		_static_renderer.clear()
	if _impostor_renderer and _impostor_renderer.has_method("clear"):
		_impostor_renderer.clear()
	if _gpu_scene_db:
		_gpu_scene_db.cleanup()
		_gpu_scene_db = null
	if _distant_light_manager:
		_distant_light_manager.cleanup()
		_distant_light_manager = null
	if _hlod_loader:
		_hlod_loader.cleanup()
		_hlod_loader = null
	_promoted_objects.clear()
	_promoted_by_cell.clear()


func _exit_tree() -> void:
	if instance == self:
		instance = null

	# If quitting, fast_cleanup() already freed everything — bail immediately
	if Engine.has_meta("_quitting"):
		return

	# Clean up GPU Scene Database
	if _gpu_scene_db:
		_gpu_scene_db.cleanup()
		_gpu_scene_db = null

	# Force-clear RS instances first (before cell tree cleanup)
	# StaticObjectRenderer holds thousands of RenderingServer RIDs that must be freed
	if _static_renderer:
		_static_renderer.clear()
	_promoted_objects.clear()
	_promoted_by_cell.clear()

	# Clear deferred NEAR refs (data only, no RIDs)
	if _cell_manager:
		for grid: Vector2i in _loaded_cells:
			_cell_manager.clear_deferred_for_cell(grid)

	# Clear tracking dictionaries — let Godot's tree cleanup handle the Node3D children
	# Manually freeing thousands of nodes in _exit_tree causes a long freeze
	# and Godot produces misleading "leaked dependency" warnings from ordering issues
	_unloading_cells.clear()
	_loaded_cells.clear()


func _ready() -> void:
	instance = self
	
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

	# Create HLOD loader for cell-level merged meshes (300-1000m)
	_hlod_loader = HLODLoaderScript.new()

	# Create GPU scene database for SSBO-backed world state (Phase 2)
	_gpu_scene_db = GPUSceneDatabaseScript.new()


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
	_cell_manager.set_gpu_scene_db(_gpu_scene_db)
	_cell_manager._sync_instantiator_config()
	_camera = camera

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

	# Initialize HLOD loader with viewport scenario.
	# If HLOD cache exists, narrow individual MID instance range to 300m (HLOD takes 300-1000m).
	if _hlod_loader:
		var scenario := get_viewport().get_world_3d().scenario
		_hlod_loader.initialize(scenario)
		# Check if HLOD cache exists (at least one cell file present)
		var hlod_dir: String = SettingsManager.get_cache_base_path().path_join("hlod")
		if DirAccess.dir_exists_absolute(hlod_dir):
			if _static_renderer:
				_static_renderer.visibility_range_end = DU.HLOD_START
				Log.info("streaming", "HLOD cache found — MID instances narrowed to 0-%dm, HLOD covers %d-%dm" % [
					int(DU.HLOD_START), int(DU.HLOD_START), int(DU.HLOD_END)])

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

	# Start timing for frame budget telemetry
	var frame_start_usec := Time.get_ticks_usec()
	var phase_times: PackedFloat64Array = PackedFloat64Array()  # usec per phase
	phase_times.resize(8)  # 0:unload, 1:async_complete, 2:instantiate, 3:promote, 4:collision, 5:deferred, 6:queue, 7:cell_update
	var budget_usec := frame_budget_ms * 1000.0

	# Per-phase profiler — lightweight begin/end section pairs.
	# Gated by SC.ENABLE_PROFILING; zero overhead when disabled.
	var prof: StreamingProfilerScript = _profiler
	if prof:
		prof.begin_frame()

	# Update camera position and velocity
	_camera_position = _camera.global_position
	if _cell_manager:
		_cell_manager.set_camera_position(_camera_position)
	var new_cell := DU.world_to_cell(_camera_position)

	# EMA-smoothed velocity on XZ plane (for predictive cell loading)
	if delta > 0.0 and _prev_camera_position != Vector3.ZERO:
		var raw_vel := Vector2(
			(_camera_position.x - _prev_camera_position.x) / delta,
			(_camera_position.z - _prev_camera_position.z) / delta
		)
		_camera_velocity_xz = _camera_velocity_xz.lerp(raw_vel, 0.3)
	_prev_camera_position = _camera_position

# Track startup frames for staggered loading
	if _startup_phase:
		_startup_frames += 1
		_emit_startup_progress()
		_check_startup_complete()

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

	# Update HLOD cells on camera cell change (runs AFTER impostor deferred update)
	if _hlod_loader and not _startup_phase:
		if _cell_changed_this_frame or _hlod_needs_initial_update:
			_hlod_loader.update_for_camera(_camera_cell, load_radius_cells)
			_hlod_needs_initial_update = false

	# Update distant light manager (camera pos + time-of-day)
	if _distant_light_manager:
		_distant_light_manager.update(_camera_position, _sun_elevation_rad)

	# I.6 Phase 2 — orphan expiry tick. Off the frame-budget hot path
	# because it runs at 1 Hz max, and the walk is bounded by the tiny
	# size of `_persistent_nodes` (a handful of held items, if that).
	_orphan_prune_accum += delta
	if _orphan_prune_accum >= ORPHAN_PRUNE_INTERVAL_S:
		_orphan_prune_accum = 0.0
		_prune_expired_orphans()

	# Predictive loading — pre-queue cells in movement direction
	if not _startup_phase:
		_predict_and_prequeue_cells()

	# Phase 0: Budgeted unloading — free children of departing cells gradually
	# Runs BEFORE loading so freed memory is available for new cells
	var phase_start := Time.get_ticks_usec()
	if prof:
		prof.begin_section("unload")
	if not _unloading_cells.is_empty() or not _pending_rs_hide_cells.is_empty() or not _pending_rs_cleanup_cells.is_empty():
		_process_budgeted_unloading()
	if prof:
		prof.end_section("unload")
	phase_times[0] = float(Time.get_ticks_usec() - phase_start)

	# Process async loading (three-phase approach)
	if async_loading_enabled:
		# Phase 1: Check for completed async requests
		phase_start = Time.get_ticks_usec()
		if prof:
			prof.begin_section("async_complete")
		_process_async_completions()
		if prof:
			prof.end_section("async_complete")
		phase_times[1] = float(Time.get_ticks_usec() - phase_start)

		# Phase 2: Process async instantiation (progressive object creation)
		# During startup: aggressive 15ms budget (player can't see anything behind loading screen)
		# During gameplay: conservative dynamic budget (48% of delta, clamped 2-16ms)
		phase_start = Time.get_ticks_usec()
		var instantiation_budget_ms := 15.0 if _startup_phase else _get_dynamic_budget(delta)
		var camera_fwd := -_camera.global_transform.basis.z if _camera else Vector3.FORWARD
		var instantiated := _cell_manager.process_async_instantiation(instantiation_budget_ms, _camera_position, camera_fwd)
		phase_times[2] = float(Time.get_ticks_usec() - phase_start)
		if instantiated > 0 and debug_enabled:
			_debug("Instantiated %d objects this frame" % instantiated)

		# Skip remaining phases if budget already exceeded
		var total_elapsed_usec := Time.get_ticks_usec() - frame_start_usec
		if total_elapsed_usec < budget_usec:
			# Phase 3: MID→NEAR promotion for nearby objects (Phase 5b)
			phase_start = Time.get_ticks_usec()
			_process_mid_to_near_promotions()
			phase_times[3] = float(Time.get_ticks_usec() - phase_start)

		total_elapsed_usec = Time.get_ticks_usec() - frame_start_usec
		if total_elapsed_usec < budget_usec:
			# Phase 3a: Re-enable collision on promoted NEAR objects entering visibility
			phase_start = Time.get_ticks_usec()
			_process_promoted_collision_enable()
			phase_times[4] = float(Time.get_ticks_usec() - phase_start)

		total_elapsed_usec = Time.get_ticks_usec() - frame_start_usec
		if total_elapsed_usec < budget_usec:
			# Phase 3b: Deferred NEAR instantiation (objects that skipped MID tier)
			phase_start = Time.get_ticks_usec()
			_process_deferred_near_instantiation()
			phase_times[5] = float(Time.get_ticks_usec() - phase_start)

		total_elapsed_usec = Time.get_ticks_usec() - frame_start_usec
		if total_elapsed_usec < budget_usec:
			# Phase 4: Queue new cell requests (non-blocking)
			phase_start = Time.get_ticks_usec()
			_process_pending_loads_async()
			phase_times[6] = float(Time.get_ticks_usec() - phase_start)

	else:
		# Fallback: synchronous loading (blocks frame)
		_process_pending_loads_sync(delta)

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
			Log.warn("streaming", "Frame overrun: %.1fms [cellupd:%.1f unload:%.1f async:%.1f inst:%.1f promo:%.1f coll:%.1f defer:%.1f queue:%.1f] (budget:%.1fms, overruns:%d)" % [
				total_ms,
				cell_update_usec / 1000.0,
				phase_times[0] / 1000.0, phase_times[1] / 1000.0, phase_times[2] / 1000.0,
				phase_times[3] / 1000.0, phase_times[4] / 1000.0, phase_times[5] / 1000.0,
				phase_times[6] / 1000.0,
				frame_budget_ms, _frame_overrun_count])
			_last_overrun_log_frame = Engine.get_frames_drawn()


## Update which cells should be loaded based on camera position
func _update_loaded_cells() -> void:
	var ulc_start := Time.get_ticks_usec()

	# Calculate which cells should be loaded
	var cells_to_load := _get_cells_in_radius(_camera_cell, load_radius_cells)
	var t_grid := Time.get_ticks_usec()

	# Reclaim cells that re-entered radius while still being unloaded
	var reclaimed: Array[Vector2i] = []
	for grid: Vector2i in _unloading_cells:
		if grid in cells_to_load:
			var cell_ref: Variant = _unloading_cells[grid]
			if not is_instance_valid(cell_ref):
				continue
			var cell_node: Node3D = cell_ref as Node3D
			if cell_node.get_child_count() > 0:
				# Move back to world container
				if cell_node.get_parent():
					cell_node.get_parent().remove_child(cell_node)
				cell_node.visible = true
				_world_container.add_child(cell_node)
				_loaded_cells[grid] = cell_node
				reclaimed.append(grid)
				_debug("Reclaimed unloading cell %s (%d children remaining)" % [grid, cell_node.get_child_count()])
	for grid in reclaimed:
		_unloading_cells.erase(grid)
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
		if grid not in _loaded_cells and grid not in _loading_cells:
			_pending_load_queue.append(grid)
			_pending_load_set[grid] = true

	if debug_enabled and not _pending_load_queue.is_empty():
		_debug("Queueing %d cells for loading (camera at cell %s)" % [_pending_load_queue.size(), _camera_cell])

	# Sort farthest first — pop_back() returns nearest cell (O(1) instead of O(n))
	_pending_load_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return DU.cell_distance_squared(_camera_cell, a) > DU.cell_distance_squared(_camera_cell, b)
	)
	var t_queue := Time.get_ticks_usec()

	# Defer impostor update to next frame to avoid stacking with cell load/unload
	# The impostor scan (especially first call with 11K+ cells) is expensive
	_impostor_update_pending = true

	# Scan for distant lights in a wider radius than loaded cells
	# Uses impostor_radius since distant lights should be visible as far as impostors
	if _distant_light_manager:
		_distant_light_manager.scan_cells_around(_camera_cell, impostor_radius_cells)

	# Log breakdown if total exceeds 2ms
	var total_ulc_ms := float(Time.get_ticks_usec() - ulc_start) / 1000.0
	if total_ulc_ms > 2.0:
		Log.info("streaming", "_update_loaded_cells: %.1fms [grid:%.1f reclaim:%.1f unload:%.1f queue:%.1f]" % [
			total_ulc_ms,
			float(t_grid - ulc_start) / 1000.0,
			float(t_reclaim - t_grid) / 1000.0,
			float(t_unload - t_reclaim) / 1000.0,
			float(t_queue - t_unload) / 1000.0])


## Pre-queue cells in the camera's movement direction for smoother transitions
## Uses EMA-smoothed XZ velocity to predict which cells will be needed next
func _predict_and_prequeue_cells() -> void:
	# Need meaningful velocity (>2 m/s on XZ plane) to predict
	var speed_sq := _camera_velocity_xz.length_squared()
	if speed_sq < 4.0:
		return

	# Compute which cell offset the camera is heading toward
	var vel_dir := _camera_velocity_xz.normalized()
	# Map velocity direction to cell grid offset: +X = +grid.x, +Z = -grid.y (Godot Z is flipped)
	var predict_x: int = 0
	var predict_y: int = 0
	if absf(vel_dir.x) > 0.3:
		predict_x = 1 if vel_dir.x > 0 else -1
	if absf(vel_dir.y) > 0.3:
		predict_y = -1 if vel_dir.y > 0 else 1  # Godot +Z = grid -Y

	if predict_x == 0 and predict_y == 0:
		return

	# Check how far across the current cell we are in the movement direction
	var cell_center := DU.cell_to_world_center(_camera_cell)
	var offset_in_cell := Vector2(_camera_position.x - cell_center.x, _camera_position.z - cell_center.z)
	var progress := offset_in_cell.dot(vel_dir) / (DU.CELL_SIZE_METERS * 0.5)  # -1 to +1
	if progress < 0.2:
		return  # Not far enough across the cell to predict

	# Build list of predicted cells (diagonal + axis-aligned neighbors)
	var predicted: Array[Vector2i] = []
	var main_cell := Vector2i(_camera_cell.x + predict_x, _camera_cell.y + predict_y)
	predicted.append(main_cell)
	# Axis-aligned neighbors for diagonal movement
	if predict_x != 0 and predict_y != 0:
		predicted.append(Vector2i(_camera_cell.x + predict_x, _camera_cell.y))
		predicted.append(Vector2i(_camera_cell.x, _camera_cell.y + predict_y))

	# Pre-queue cells that aren't already loaded, loading, or pending
	var queued := 0
	for grid in predicted:
		if grid not in _loaded_cells and grid not in _loading_cells and grid not in _pending_load_set:
			_pending_load_queue.append(grid)
			_pending_load_set[grid] = true
			queued += 1

	if queued > 0 and debug_enabled:
		_debug("Predictive: pre-queued %d cells (vel=%.1f,%.1f dir=%d,%d progress=%.1f)" % [
			queued, _camera_velocity_xz.x, _camera_velocity_xz.y, predict_x, predict_y, progress])


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
	if grid in _loaded_cells or grid in _loading_cells:
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
		_world_container.add_child(cell_node)
		_loaded_cells[grid] = cell_node

		# I.6 Phase 2 — re-home any orphans whose origin grid matches.
		_rehome_persistent_nodes_for_cell(cell_node, grid)

		var object_count := _count_mesh_instances(cell_node)
		_stats["loaded_cells"] = _loaded_cells.size()
		_stats["total_objects"] += object_count

		cell_loaded.emit(grid, object_count)
		_debug("Sync loaded cell %s with %d objects" % [grid, object_count])
	else:
		_debug("Failed to load cell %s" % [grid])

	_loading_cells.erase(grid)
	stats_updated.emit(_stats)


## Unload a cell at the given grid position (budgeted — gradual over multiple frames)
func _unload_cell(grid: Vector2i) -> void:
	# Cancel any pending async request for this cell
	if grid in _async_requests:
		var request_id: int = _async_requests[grid]
		_cell_manager.cancel_async_request(request_id)
		_async_requests.erase(grid)
		_loading_cells.erase(grid)
		_debug("Cancelled async request %d for cell %s" % [request_id, grid])

	if grid not in _loaded_cells:
		return

	var cell_node: Node3D = _loaded_cells[grid]
	_loaded_cells.erase(grid)
	_stats["loaded_cells"] = _loaded_cells.size()

	# Clean up promoted object tracking for this cell using spatial index (O(1) lookup)
	var promoted_cleanup := 0
	if grid in _promoted_by_cell:
		var cell_promoted: Array = _promoted_by_cell[grid]
		for rs_id: int in cell_promoted:
			_static_renderer.set_instance_promoted(rs_id, false)
			_promoted_objects.erase(rs_id)
			promoted_cleanup += 1
		_promoted_by_cell.erase(grid)

	# Queue MID-tier RS instances for BUDGETED hiding across frames.
	# Previously this called hide_cell_instances() synchronously (1000+ RS calls, 10-32ms).
	# Now we hide progressively via hide_cell_instances_budgeted() in _process_budgeted_unloading().
	if _static_renderer:
		_pending_rs_hide_cells.append(grid)
		_pending_rs_hide_set[grid] = true
		_pending_rs_cleanup_cells.append(grid)
		if promoted_cleanup > 0:
			_debug("Queued cell %s for budgeted RS hide (+ %d promoted cleanup)" % [grid, promoted_cleanup])

	# Clean up deferred NEAR refs for this cell
	_cell_manager.clear_deferred_for_cell(grid)

	# I.6 — evacuate any persistent nodes (held items, etc.) from this
	# cell BEFORE moving it to the unload container. Otherwise the
	# budgeted unload pass would free the held body along with the
	# rest of the cell. Per `docs/INTERACTION_SYSTEM.md` §10.
	_evacuate_persistent_nodes_from_cell(cell_node, grid)

	# Move cell to hidden unload container for gradual teardown
	# Reparenting is cheaper than queue_free() on entire subtree
	if cell_node.get_parent():
		cell_node.get_parent().remove_child(cell_node)
	cell_node.visible = false
	_unload_container.add_child(cell_node)
	_unloading_cells[grid] = cell_node

	_debug("Queued cell %s for budgeted unloading (%d children)" % [grid, cell_node.get_child_count()])
	cell_unloaded.emit(grid)
	stats_updated.emit(_stats)


## Process gradual unloading of departing cells within time budget
## Removes children in batches to avoid frame spikes from mass queue_free()
func _process_budgeted_unloading() -> void:
	var start_time := Time.get_ticks_usec()
	var budget_usec := SC.UNLOAD_BUDGET_MS * 1000.0
	var total_freed := 0

	# Get object pool for returning pooled instances
	var object_pool: RefCounted = _cell_manager.get_object_pool() if _cell_manager else null

	# Process each unloading cell
	var completed_grids: Array[Vector2i] = []

	for grid: Vector2i in _unloading_cells:
		var cell_ref: Variant = _unloading_cells[grid]
		if not is_instance_valid(cell_ref):
			completed_grids.append(grid)
			continue
		var cell_node: Node3D = cell_ref as Node3D

		var children_count := cell_node.get_child_count()
		if children_count == 0:
			# Cell is empty, free the container
			cell_node.queue_free()
			completed_grids.append(grid)
			continue

		# Remove up to UNLOAD_BATCH_SIZE children from this cell
		var batch := 0
		while batch < SC.UNLOAD_BATCH_SIZE and cell_node.get_child_count() > 0:
			# Check time budget
			if Time.get_ticks_usec() - start_time >= budget_usec:
				# Out of time — stop and continue next frame
				if debug_enabled and total_freed > 0:
					_debug("Unload budget hit: freed %d objects, %d cells still unloading" % [total_freed, _unloading_cells.size() - completed_grids.size()])
				# Clean up completed cells before returning
				for g in completed_grids:
					_unloading_cells.erase(g)
				return

			# Remove last child (pop from end = O(1))
			var child := cell_node.get_child(cell_node.get_child_count() - 1)
			cell_node.remove_child(child)

			# Try to return to object pool instead of destroying
			var returned_to_pool := false
			if object_pool and child is Node3D and child.has_meta("pool_model_path"):
				var pool_path: String = child.get_meta("pool_model_path")
				if not pool_path.is_empty() and object_pool.has_method("release"):
					object_pool.call("release", child)
					returned_to_pool = true

			if not returned_to_pool:
				child.queue_free()

			batch += 1
			total_freed += 1

		# Check if cell is now empty
		if cell_node.get_child_count() == 0:
			cell_node.queue_free()
			completed_grids.append(grid)

	# Remove completed cells from tracking
	for g in completed_grids:
		_unloading_cells.erase(g)

	if debug_enabled and total_freed > 0:
		_debug("Budgeted unload: freed %d objects, %d cells remaining" % [total_freed, _unloading_cells.size()])

	# Phase A: Budgeted RS instance HIDING — hide ~200 instances per frame
	# Replaces the old synchronous hide_cell_instances() that caused 10-32ms spikes
	if _static_renderer and not _pending_rs_hide_cells.is_empty():
		var hide_budget := 200  # Max RS calls per frame for hiding
		var total_hidden := 0
		var completed_hide: Array[int] = []  # indices to remove (collected, then batch-removed)
		for hi in _pending_rs_hide_cells.size():
			if total_hidden >= hide_budget or Time.get_ticks_usec() - start_time >= budget_usec:
				break
			var hide_grid: Vector2i = _pending_rs_hide_cells[hi]
			var result: Array = _static_renderer.hide_cell_instances_budgeted(hide_grid, hide_budget - total_hidden)
			total_hidden += result[0] as int
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
		var rs_freed := 0
		while not _pending_rs_cleanup_cells.is_empty():
			if Time.get_ticks_usec() - start_time >= budget_usec:
				break
			var cleanup_grid: Vector2i = _pending_rs_cleanup_cells[-1]
			# Don't free RIDs for cells still being hidden — O(1) set check
			if cleanup_grid in _pending_rs_hide_set:
				break
			_pending_rs_cleanup_cells.resize(_pending_rs_cleanup_cells.size() - 1)
			rs_freed += _static_renderer.remove_cell_instances(cleanup_grid)
		if rs_freed > 0 and debug_enabled:
			_debug("Budgeted RS cleanup: freed %d instances, %d cells remaining" % [rs_freed, _pending_rs_cleanup_cells.size()])


## Track promoted objects: object_id (batch pool) or rs_id (legacy) -> NEAR Node3D
## Used for demotion when camera moves away
var _promoted_objects: Dictionary = {}  # {id: int -> near_node: Node3D}

## Spatial index for promoted objects: cell_grid -> Array[int] of promoted rs_ids
## Enables O(1) per-cell lookup instead of scanning all promoted objects
var _promoted_by_cell: Dictionary = {}  # {Vector2i -> Array[int]}

## Cells with RS instances that need budgeted visibility hiding
## Hides ~200 RS instances per frame to avoid 10-32ms synchronous spikes
var _pending_rs_hide_cells: Array[Vector2i] = []
## O(1) lookup for cells still being hidden (mirrors _pending_rs_hide_cells)
var _pending_rs_hide_set: Dictionary[Vector2i, bool] = {}

## Cells with RS instances that need deferred free_rid() cleanup (after hiding)
var _pending_rs_cleanup_cells: Array[Vector2i] = []


## Promote MID-tier objects to full NEAR-tier Node3D when camera approaches.
## On promotion, MID RS instances are HIDDEN (the NEAR Node3D covers 0-500m via
## its own LOD children from configure_for_prebake). This prevents double-rendering.
## On demotion, RS instances are shown again.
## Budget-controlled: max 3ms every 2 frames.
## Scans a 7×7 cell grid around camera (covers 351m > 250m promotion distance).
func _process_mid_to_near_promotions() -> void:
	if not _cell_manager:
		return
	if not _static_renderer:
		return

	# Absorb immediate promotions from cell_manager (created in same frame as RS instances).
	# These are mid-worthy objects that got BOTH RS + Node3D because camera was within NEAR range.
	# Must run every frame to avoid stale entries.
	var imm_promos := _cell_manager.get_and_clear_immediate_promotions()
	for entry: Dictionary in imm_promos:
		var rs_id: int = entry["id"]
		var near_node: Node3D = entry["node"]
		if is_instance_valid(near_node) and rs_id not in _promoted_objects:
			_promoted_objects[rs_id] = near_node
			# Maintain spatial index
			var _promo_data: Variant = _static_renderer.get_instance_data(rs_id)
			if _promo_data:
				var _promo_cell: Vector2i = _promo_data.cell_grid
				if _promo_cell not in _promoted_by_cell:
					_promoted_by_cell[_promo_cell] = []
				(_promoted_by_cell[_promo_cell] as Array).append(rs_id)
			_stats["mid_to_near_promotions"] += 1

	# Run every N frames (configurable)
	if Engine.get_frames_drawn() % SC.PROMOTION_FRAME_INTERVAL != 0:
		return

	var start_time := Time.get_ticks_usec()
	var budget_usec := SC.PROMOTION_BUDGET_USEC

	# --- DEMOTION: NEAR objects that are now far enough to free ---
	var demote_distance_sq: float = SC.DEMOTION_DISTANCE * SC.DEMOTION_DISTANCE
	var demoted := 0
	var demote_remove: Array[int] = []

	for obj_id: int in _promoted_objects:
		if Time.get_ticks_usec() - start_time >= budget_usec:
			break

		var near_node: Node3D = _promoted_objects[obj_id]
		if not is_instance_valid(near_node):
			demote_remove.append(obj_id)
			continue

		# Guard: deferred add_child may not have parented the node yet.
		# global_position is unreliable until the node is inside the tree.
		if not near_node.is_inside_tree():
			continue

		var dist_sq := _camera_position.distance_squared_to(near_node.global_position)
		if dist_sq > demote_distance_sq:
			# Demote: clear promoted flag (shows LOD0 RS instance), free NEAR Node3D
			_static_renderer.set_instance_promoted(obj_id, false)
			near_node.queue_free()
			demote_remove.append(obj_id)
			demoted += 1

	for obj_id: int in demote_remove:
		# Remove from spatial index
		var _dem_data: Variant = _static_renderer.get_instance_data(obj_id)
		if _dem_data and _dem_data.cell_grid in _promoted_by_cell:
			var _dem_arr: Array = _promoted_by_cell[_dem_data.cell_grid]
			var _dem_idx := _dem_arr.find(obj_id)
			if _dem_idx >= 0:
				_dem_arr[_dem_idx] = _dem_arr.back()
				_dem_arr.pop_back()
			if _dem_arr.is_empty():
				_promoted_by_cell.erase(_dem_data.cell_grid)
		_promoted_objects.erase(obj_id)

	# --- PROMOTION: MID objects within promotion distance get a NEAR Node3D ---
	# The NEAR Node3D is invisible at 250m (its visibility_range is 0-155m)
	# but will be ready when the camera reaches the 145-155m crossfade zone.
	var promote_distance_sq: float = SC.PROMOTION_DISTANCE * SC.PROMOTION_DISTANCE

	# Scan cells in radius around camera
	var r: int = SC.PROMOTION_CELL_RADIUS
	var nearby_cells: Array[Vector2i] = []
	for dx in range(-r, r + 1):
		for dy in range(-r, r + 1):
			var g := _camera_cell + Vector2i(dx, dy)
			if g in _loaded_cells:
				nearby_cells.append(g)

	var promoted := 0
	if not nearby_cells.is_empty():
		var promotable := _static_renderer.get_promotable_instances(
			_camera_position, promote_distance_sq, nearby_cells
		)
		for id: int in promotable:
			if Time.get_ticks_usec() - start_time >= budget_usec:
				break
			if id in _promoted_objects:
				continue

			var data: Variant = _static_renderer.get_instance_data(id)
			if not data:
				continue

			var cell_node: Node3D = _loaded_cells.get(data.cell_grid) as Node3D
			if not cell_node or not is_instance_valid(cell_node):
				continue

			var near_obj: Node3D = _cell_manager.promote_mid_to_near(
				data.model_path, data.item_id, data.transform,
				data.ref_id, data.ref_num
			)
			if not near_obj:
				continue

			# Disable collision shapes on the pre-created NEAR Node3D.
			# The object is invisible beyond 155m — active physics on invisible
			# objects wastes broadphase budget and causes raycast hits on nothing.
			_disable_collision_shapes(near_obj)

			cell_node.add_child(near_obj)
			# Post-B-wide refactor: single RS instance per object, no per-LOD
			# RID fan-out, so no LOD-children check needed — promotion just hides
			# the single instance since the NEAR Node3D replaces it 0-500m.
			_static_renderer.set_instance_promoted(id, true)
			_promoted_objects[id] = near_obj
			# Maintain spatial index
			if data.cell_grid not in _promoted_by_cell:
				_promoted_by_cell[data.cell_grid] = []
			(_promoted_by_cell[data.cell_grid] as Array).append(id)
			promoted += 1

	if promoted > 0 or demoted > 0:
		_stats["mid_to_near_promotions"] += promoted
		_stats["near_to_mid_demotions"] += demoted
		_debug("Tier transitions: promoted %d MID→NEAR, demoted %d NEAR→MID (%.1fms, tracking %d)" % [
			promoted, demoted, (Time.get_ticks_usec() - start_time) / 1000.0,
			_promoted_objects.size()
		])


## Re-enable collision shapes on promoted NEAR Node3Ds that have entered visibility range.
## Collision shapes are disabled at promotion time (object is at 150-250m, invisible).
## We re-enable once within NEAR_END + margin so physics are active when visible.
func _process_promoted_collision_enable() -> void:
	if _promoted_objects.is_empty():
		return
	# Run on odd frames, offset from promotion tick
	if Engine.get_frames_drawn() % SC.PROMOTION_FRAME_INTERVAL != 1:
		return
	var enable_dist_sq: float = (DU.NEAR_END + DU.FADE_MARGIN_NEAR_LOD1) * (DU.NEAR_END + DU.FADE_MARGIN_NEAR_LOD1)
	for obj_id: int in _promoted_objects:
		var near_node: Node3D = _promoted_objects[obj_id]
		if not is_instance_valid(near_node):
			continue
		if near_node.has_meta("collision_disabled"):
			var dist_sq := _camera_position.distance_squared_to(near_node.global_position)
			if dist_sq < enable_dist_sq:
				_enable_collision_shapes(near_node)


## Disable all CollisionShape3D nodes in a tree (for pre-created invisible NEAR objects)
static func _disable_collision_shapes(node: Node) -> void:
	if node is CollisionShape3D:
		(node as CollisionShape3D).disabled = true
	for child in node.get_children():
		_disable_collision_shapes(child)
	if node is Node3D:
		node.set_meta("collision_disabled", true)


## Re-enable all CollisionShape3D nodes in a tree
static func _enable_collision_shapes(node: Node) -> void:
	if node is CollisionShape3D:
		(node as CollisionShape3D).disabled = false
	for child in node.get_children():
		_enable_collision_shapes(child)
	if node is Node3D:
		node.remove_meta("collision_disabled")


## Batch-free all promoted objects (used after teleport to avoid stale physics bodies)
func _demote_all_promoted() -> void:
	var count := _promoted_objects.size()
	for obj_id: int in _promoted_objects:
		_static_renderer.set_instance_promoted(obj_id, false)
		var near_node: Node3D = _promoted_objects[obj_id]
		if is_instance_valid(near_node):
			near_node.queue_free()
	_promoted_objects.clear()
	_promoted_by_cell.clear()
	if count > 0:
		_stats["near_to_mid_demotions"] += count
		_debug("Teleport: batch-demoted %d promoted objects" % count)


## Instantiate deferred NEAR objects that skipped MID tier and are now close enough.
## Runs every 4 frames (offset from promotion tick) with a 1ms budget.
func _process_deferred_near_instantiation() -> void:
	if not _cell_manager:
		return

	# Run every 4 frames, offset from promotion tick (which uses % 4 == 0)
	if Engine.get_frames_drawn() % 4 != 2:
		return

	# Get nearby cells (same 3x3 grid as promotion system)
	var nearby_cells: Array[Vector2i] = []
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var g := _camera_cell + Vector2i(dx, dy)
			if g in _loaded_cells:
				nearby_cells.append(g)

	if nearby_cells.is_empty():
		return

	var results := _cell_manager.process_deferred_near(
		_camera_position, nearby_cells, _loaded_cells
	)

	for entry in results:
		var parent: Node3D = entry.parent
		var child: Node3D = entry.child
		if is_instance_valid(parent) and is_instance_valid(child):
			parent.add_child(child)

	if not results.is_empty() and debug_enabled:
		_debug("Deferred NEAR: instantiated %d objects" % results.size())


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


## Get human-readable distance range string for LOD level (debug helper)
func _get_lod_range_str(lod_level: int) -> String:
	match lod_level:
		1: return "150-250m"
		2: return "250-375m"
		3: return "375-500m"
		_: return "unknown"


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

			# Skip if already loaded or loading
			if grid in _loaded_cells or grid in _loading_cells:
				continue

			# Submit async request
			if _request_cell_async(grid):
				requests_submitted += 1
				available_slots -= 1

		if requests_submitted > 0 and debug_enabled:
			_debug("Submitted %d async cell requests, %d remaining in queue (startup=%s, frame=%d)" % [
				requests_submitted, _pending_load_queue.size(), _startup_phase, _startup_frames
			])


## Process completed async requests
## Checks for finished cell loads and finalizes them
## Budget-capped: processes at most 2 completions per frame to prevent spikes
func _process_async_completions() -> void:
	var completed_grids: Array[Vector2i] = []
	var max_completions_per_frame := 2

	for grid: Vector2i in _async_requests:
		if completed_grids.size() >= max_completions_per_frame:
			break
		var request_id: int = _async_requests[grid]

		if _cell_manager.is_async_complete(request_id):
			# Request is complete - finalize
			var cell_node := _cell_manager.get_async_result(request_id)

			if cell_node:
				# Per-object visibility_range is now applied during instantiation
				# (cell_manager.process_async_instantiation sets visibility_prebaked meta)
				# Only run the cell-level pass as a safety net for edge cases
				_configure_cell_visibility(cell_node)

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

				cell_loaded.emit(grid, object_count)
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

		if grid in _loaded_cells or grid in _loading_cells:
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

	# Add CellManager async stats if available
	if _cell_manager and _cell_manager.has_method("get_loading_stats"):
		var cm_stats: Dictionary = _cell_manager.get_loading_stats()
		s["instantiation_queue"] = cm_stats.get("instantiation_queue_size", 0)
		s["pending_conversions"] = cm_stats.get("pending_conversions", 0)
		s["pending_disk_loads"] = cm_stats.get("pending_disk_loads", 0)

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
	if _hlod_loader:
		var hlod_stats: Dictionary = _hlod_loader.get_stats()
		s["hlod_cells"] = hlod_stats.get("loaded_cells", 0)
		s["hlod_surfaces"] = hlod_stats.get("total_surfaces", 0)

	return s


## Get last frame's per-phase timing breakdown (usec).
## Indices: 0=unload, 1=async_complete, 2=instantiate, 3=promote, 4=collision,
##          5=deferred, 6=queue, 7=cell_update
## Returns empty array if not yet initialized.
func get_phase_times() -> PackedFloat64Array:
	return _last_phase_times


## Get last frame's total streaming work in ms.
func get_frame_streaming_ms() -> float:
	return _last_frame_total_ms


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

	# Batch-free all promoted NEAR objects — MID RS instances handle visibility
	_demote_all_promoted()

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

#endregion


#region Startup Progress

## Emit startup progress signal for parent UI to handle
func _emit_startup_progress() -> void:
	var target_cells := load_radius_cells * load_radius_cells  # Approximate
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
		# Restore normal impostor budget
		if _impostor_renderer:
			_impostor_renderer.set_load_budget_usec(4000.0)
		startup_complete.emit()
		Log.info("streaming", "Startup phase complete after %d frames, %d cells loaded, %d impostor cells remaining (inner ring: %d/%d processed)" % [
			_startup_frames, _loaded_cells.size(), impostor_pending, impostor_processed, inner_ring_count])


## Check if currently in startup phase
func is_in_startup_phase() -> bool:
	return _startup_phase

#endregion
