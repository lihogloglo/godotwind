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
const LODConfigurator := preload("res://src/core/world/lod_configurator.gd")
const CellManagerScript := preload("res://src/core/world/cell_manager.gd")
const ModelLoaderScript := preload("res://src/core/world/model_loader.gd")
const NativeImpostorRendererScript := preload("res://src/core/world/native_impostor_renderer.gd")
const ImpostorCandidatesScript := preload("res://src/core/world/impostor_candidates.gd")
const MeshVisibilityUtils := preload("res://src/core/world/mesh_visibility_utils.gd")
const CS := preload("res://src/core/coordinate_system.gd")
const BackgroundProcessorScript := preload("res://src/core/streaming/background_processor.gd")
const StaticObjectRendererScript := preload("res://src/core/world/static_object_renderer.gd")
const GPUSceneDatabaseScript := preload("res://src/core/gpu_driven/gpu_scene_database.gd")

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

## LOD configurator helper
var _lod_configurator: LODConfigurator = LODConfigurator.new()

## Static object renderer for MID-tier + flora (RenderingServer direct, no Node3D)
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

## Cells being gradually unloaded: grid -> Node3D (hidden, children being removed over frames)
var _unloading_cells: Dictionary[Vector2i, Node3D] = {}

## Hidden container for cells being unloaded (keeps them out of rendering)
var _unload_container: Node3D = null

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

## Startup phase state - controls staggered loading during initial population
var _startup_phase: bool = true
var _startup_frames: int = 0
const STARTUP_PHASE_FRAMES: int = 20  # ~0.33 seconds at 60 FPS — matches exit condition

#endregion


#region Initialization

func _exit_tree() -> void:
	if instance == self:
		instance = null
	
	# Clean up GPU Scene Database
	if _gpu_scene_db:
		_gpu_scene_db.cleanup()
		_gpu_scene_db = null

	# Force-clear all remaining RenderingServer instances and pending unloads
	# to prevent RID leaks at exit (budgeted unloading may still be in progress)
	if _static_renderer:
		_static_renderer.clear()
	_promoted_objects.clear()

	# Force-free all cells still in gradual unload container
	for grid: Vector2i in _unloading_cells:
		var cell_ref: Variant = _unloading_cells[grid]
		if is_instance_valid(cell_ref):
			(cell_ref as Node3D).queue_free()
	_unloading_cells.clear()

	# Clear deferred NEAR refs (data only, no RIDs)
	if _cell_manager:
		for grid: Vector2i in _loaded_cells:
			_cell_manager.clear_deferred_for_cell(grid)

	# Force-free all loaded cells
	for grid: Vector2i in _loaded_cells:
		var cell_ref: Variant = _loaded_cells[grid]
		if is_instance_valid(cell_ref):
			(cell_ref as Node3D).queue_free()
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

	# Create static object renderer for MID-tier objects and flora
	# Uses RenderingServer directly — no Node3D overhead for distant objects
	_static_renderer = StaticObjectRendererScript.new()
	_static_renderer.name = "StaticRenderer"
	add_child(_static_renderer)

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
	_cell_manager.set_lod_configurator(_lod_configurator)
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


## Set cell manager
func set_cell_manager(cell_manager: CellManagerScript) -> void:
	_cell_manager = cell_manager
	if _cell_manager and _lod_configurator:
		_cell_manager.set_lod_configurator(_lod_configurator)

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
	var _frame_start_usec := Time.get_ticks_usec()

	# Update camera position
	_camera_position = _camera.global_position
	var new_cell := DU.world_to_cell(_camera_position)

	# Track startup frames for staggered loading
	if _startup_phase:
		_startup_frames += 1
		_emit_startup_progress()

	# Check if we moved to a new cell
	if new_cell != _camera_cell:
		_debug("Camera moved to new cell: %s (was %s)" % [new_cell, _camera_cell])
		_camera_cell = new_cell
		_update_loaded_cells()

	# Phase 0: Budgeted unloading — free children of departing cells gradually
	# Runs BEFORE loading so freed memory is available for new cells
	if not _unloading_cells.is_empty():
		_process_budgeted_unloading()

	# Process async loading (three-phase approach)
	if async_loading_enabled:
		# Phase 1: Check for completed async requests
		_process_async_completions()

		# Phase 2: Process async instantiation (progressive object creation)
		var camera_fwd := -_camera.global_transform.basis.z if _camera else Vector3.FORWARD
		var dynamic_budget := _get_dynamic_budget(delta)
		var instantiated := _cell_manager.process_async_instantiation(dynamic_budget, _camera_position, camera_fwd)
		if instantiated > 0 and debug_enabled:
			_debug("Instantiated %d objects this frame" % instantiated)

		# Phase 3: MID→NEAR promotion for nearby objects (Phase 5b)
		_process_mid_to_near_promotions()

		# Phase 3b: Deferred NEAR instantiation (objects that skipped MID tier)
		_process_deferred_near_instantiation()

		# Phase 4: Queue new cell requests (non-blocking)
		_process_pending_loads_async()
	else:
		# Fallback: synchronous loading (blocks frame)
		_process_pending_loads_sync(delta)

	# Frame budget telemetry — detect when combined streaming work exceeds budget
	var total_ms := (Time.get_ticks_usec() - _frame_start_usec) / 1000.0
	if total_ms > frame_budget_ms * 1.5:
		_frame_overrun_count += 1
		# Log at most once per 60 frames to avoid spam
		if Engine.get_frames_drawn() - _last_overrun_log_frame > 60:
			Log.warn("streaming", "Frame budget overrun: %.1fms (budget: %.1fms, overruns: %d)" % [total_ms, frame_budget_ms, _frame_overrun_count])
			_last_overrun_log_frame = Engine.get_frames_drawn()


## Update which cells should be loaded based on camera position
func _update_loaded_cells() -> void:
	# Calculate which cells should be loaded
	var cells_to_load := _get_cells_in_radius(_camera_cell, load_radius_cells)

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

	# Unload cells that are too far
	var cells_to_unload: Array[Vector2i] = []
	for grid: Vector2i in _loaded_cells:
		if grid not in cells_to_load:
			cells_to_unload.append(grid)

	if debug_enabled and not cells_to_unload.is_empty():
		_debug("Unloading %d cells" % cells_to_unload.size())

	for grid: Vector2i in cells_to_unload:
		_unload_cell(grid)

	# Queue new cells for loading (sorted farthest-first so pop_back gets nearest)
	_pending_load_queue.clear()
	for grid: Vector2i in cells_to_load:
		if grid not in _loaded_cells and grid not in _loading_cells:
			_pending_load_queue.append(grid)

	if debug_enabled and not _pending_load_queue.is_empty():
		_debug("Queueing %d cells for loading (camera at cell %s)" % [_pending_load_queue.size(), _camera_cell])

	# Sort farthest first — pop_back() returns nearest cell (O(1) instead of O(n))
	_pending_load_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return DU.cell_distance_squared(_camera_cell, a) > DU.cell_distance_squared(_camera_cell, b)
	)

	# Update impostors
	if _impostor_renderer:
		if debug_enabled:
			_debug("Updating impostor area: center=%s, radius=%d" % [_camera_cell, impostor_radius_cells])
		_impostor_renderer.update_impostor_area(_camera_cell, impostor_radius_cells)
	elif debug_enabled:
		_debug("WARNING: _impostor_renderer is null!")


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

	# Clean up promoted object tracking for this cell
	# Must happen BEFORE remove_cell_instances so we can match RS IDs
	var promoted_cleanup := 0
	var promoted_remove: Array[int] = []
	for rs_id: int in _promoted_objects:
		var data: Variant = _static_renderer.get_instance_data(rs_id)
		if data and data.cell_grid == grid:
			promoted_remove.append(rs_id)
	for rs_id: int in promoted_remove:
		_promoted_objects.erase(rs_id)
		promoted_cleanup += 1

	# Clean up MID-tier RenderingServer instances for this cell
	if _static_renderer:
		var mid_removed := _static_renderer.remove_cell_instances(grid)
		if mid_removed > 0:
			_debug("Removed %d MID-tier RS instances for cell %s (+ %d promoted)" % [mid_removed, grid, promoted_cleanup])

	# Clean up deferred NEAR refs for this cell
	_cell_manager.clear_deferred_for_cell(grid)

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


## Track promoted objects: RS instance_id -> NEAR Node3D
## Used for demotion when camera moves away
var _promoted_objects: Dictionary = {}  # {rs_id: int -> near_node: Node3D}


## Promote MID-tier RS instances to full NEAR-tier Node3D when camera is close.
## Also demotes NEAR→MID when camera moves away (hysteresis prevents oscillation).
## Budget-controlled: max 2ms per frame total.
## Only checks cells adjacent to the camera cell (at most ~9 cells).
func _process_mid_to_near_promotions() -> void:
	if not _static_renderer or not _cell_manager:
		return

	# Only run every 4 frames (promotion/demotion is not time-critical)
	if Engine.get_frames_drawn() % 4 != 0:
		return

	var start_time := Time.get_ticks_usec()
	var budget_usec := 2000.0  # 2ms total budget for promotion + demotion

	# --- DEMOTION: NEAR objects that are now far enough to go back to MID ---
	# Threshold: NEAR_END + HYSTERESIS_NEAR = 150 + 40 = 190m
	var demote_distance_sq: float = (SC.NEAR_END + SC.HYSTERESIS_NEAR) * (SC.NEAR_END + SC.HYSTERESIS_NEAR)
	var demoted := 0
	var demote_remove: Array[int] = []

	for rs_id: int in _promoted_objects:
		if Time.get_ticks_usec() - start_time >= budget_usec:
			break

		var near_node: Node3D = _promoted_objects[rs_id]
		if not is_instance_valid(near_node):
			# Node was freed (cell unloaded) — clean up tracking
			demote_remove.append(rs_id)
			# Also remove the hidden RS instance since the cell is gone
			_static_renderer.remove_instance(rs_id)
			continue

		var dist_sq := _camera_position.distance_squared_to(near_node.global_position)
		if dist_sq > demote_distance_sq:
			# Demote: unhide RS instance, remove NEAR Node3D
			_static_renderer.set_instance_visible(rs_id, true)
			near_node.queue_free()
			demote_remove.append(rs_id)
			demoted += 1

	for rs_id: int in demote_remove:
		_promoted_objects.erase(rs_id)

	# --- PROMOTION: MID objects that are now close enough to become NEAR ---
	# Promotion distance: 130m (NEAR_END - 20m margin)
	var promote_distance_sq: float = (SC.NEAR_END - 20.0) * (SC.NEAR_END - 20.0)

	# Get cells adjacent to camera (only these can have objects within NEAR range)
	var nearby_cells: Array[Vector2i] = []
	for dx in range(-1, 2):
		for dy in range(-1, 2):
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

			# Skip if already promoted (RS instance is hidden, NEAR Node3D exists)
			if id in _promoted_objects:
				continue

			var data: Variant = _static_renderer.get_instance_data(id)
			if not data:
				continue

			# Find the cell_node for this instance's grid
			var cell_node: Node3D = _loaded_cells.get(data.cell_grid) as Node3D
			if not cell_node or not is_instance_valid(cell_node):
				continue

			# Create NEAR-tier Node3D
			var near_obj: Node3D = _cell_manager.promote_mid_to_near(
				data.model_path, data.item_id, data.transform,
				data.ref_id, data.ref_num
			)
			if not near_obj:
				continue

			# Add Node3D to cell, hide RS instance (don't remove — needed for demotion)
			cell_node.add_child(near_obj)
			_static_renderer.set_instance_visible(id, false)
			_promoted_objects[id] = near_obj
			promoted += 1

	if promoted > 0 or demoted > 0:
		_stats["mid_to_near_promotions"] += promoted
		_stats["near_to_mid_demotions"] += demoted
		_debug("Tier transitions: promoted %d MID→NEAR, demoted %d NEAR→MID (%.1fms, tracking %d)" % [
			promoted, demoted, (Time.get_ticks_usec() - start_time) / 1000.0,
			_promoted_objects.size()
		])


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


## Configure visibility_range on all MeshInstance3D nodes in a cell
## Skips if models were prebaked with visibility_range already set
func _configure_cell_visibility(cell_node: Node3D) -> void:
	if not use_native_visibility:
		return

	# Skip if visibility_range was already baked into the prebaked models
	# Check each child (each child is an instantiated model from prebaked cache)
	var all_prebaked := true
	for child in cell_node.get_children():
		if not child.has_meta("visibility_prebaked"):
			all_prebaked = false
			break

	if all_prebaked and cell_node.get_child_count() > 0:
		_debug("Skipping visibility config for cell %s — all %d children prebaked" % [cell_node.name, cell_node.get_child_count()])
		return

	# Collect stats for compact logging
	var stats := {"near": 0, "lod1": 0, "lod2": 0, "lod3": 0}
	_configure_node_visibility_recursive(cell_node, stats)

	if debug_enabled:
		var parts: Array[String] = []
		if stats["near"] > 0:
			parts.append("NEAR:%d" % stats["near"])
		if stats["lod1"] > 0:
			parts.append("LOD1:%d" % stats["lod1"])
		if stats["lod2"] > 0:
			parts.append("LOD2:%d" % stats["lod2"])
		if stats["lod3"] > 0:
			parts.append("LOD3:%d" % stats["lod3"])
		if not parts.is_empty():
			_debug("Configured visibility: %s (total: %d)" % [", ".join(parts), stats["near"] + stats["lod1"] + stats["lod2"] + stats["lod3"]])


## Recursively configure visibility_range on a node and its children
func _configure_node_visibility_recursive(node: Node, stats: Dictionary) -> void:
	if node is GeometryInstance3D:
		var geo := node as GeometryInstance3D
		var node_name := node.name

		# Determine appropriate visibility based on node name/type
		if MeshVisibilityUtils.is_lod_node_name(node_name):
			# LOD nodes get their specific range based on their level
			var lod_level := _get_lod_level(node_name)
			_lod_configurator.configure_mid_object(geo, lod_level)
			stats["lod%d" % lod_level] += 1
		else:
			# Default: NEAR tier visibility (0-150m)
			_lod_configurator.configure_near_object(geo)
			if node is MeshInstance3D:
				stats["near"] += 1

	# Recurse to children
	for child in node.get_children():
		_configure_node_visibility_recursive(child, stats)


## Get LOD level from node name (1, 2, or 3)
func _get_lod_level(node_name: String) -> int:
	var name := node_name.to_lower()
	if "_lod1" in name:
		return 1
	elif "_lod2" in name:
		return 2
	elif "_lod3" in name:
		return 3
	return 1  # Default to LOD1


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

	# Staggered loading during startup phase to prevent initial freeze
	# Frame 0-5: Load 1 cell per frame (camera's cell first)
	# Frame 6-15: Load 2 cells per frame
	# Frame 16+: Normal loading (2 cells per frame)
	var max_requests_per_frame: int
	if _startup_phase:
		if _startup_frames < 5:
			max_requests_per_frame = 1  # Very slow start
		elif _startup_frames < 15:
			max_requests_per_frame = 2  # Ramping up
		else:
			max_requests_per_frame = 2  # Normal rate
	else:
		max_requests_per_frame = 2

	# Check if startup phase should end:
	# - At least 1 cell fully loaded, AND
	# - Instantiation queue is empty or nearly empty (objects are placed), AND
	# - At least 20 frames have passed (give time for objects to instantiate)
	if _startup_phase and _startup_frames >= 20:
		var queue_size := _cell_manager.get_instantiation_queue_size() if _cell_manager else 0
		if _loaded_cells.size() >= 1 and queue_size < 50:
			_startup_phase = false
			startup_complete.emit()
			_debug("Startup phase complete after %d frames, %d cells loaded" % [_startup_frames, _loaded_cells.size()])

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
func _process_async_completions() -> void:
	var completed_grids: Array[Vector2i] = []

	for grid: Vector2i in _async_requests.keys():
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

	return s


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


## Get the impostor renderer (for console commands and diagnostics)
func get_impostor_manager() -> Node3D:
	return _impostor_renderer


## Teleport to a new location (forces immediate cell reload)
func teleport_to(position: Vector3) -> void:
	_camera_position = position
	_camera_cell = DU.world_to_cell(position)

	# Unload all cells
	for grid: Vector2i in _loaded_cells.keys():
		_unload_cell(grid)

	# Load cells around new position
	_update_loaded_cells()


## Get all loaded cell coordinates
func get_loaded_cell_coordinates() -> Array[Vector2i]:
	var coords: Array[Vector2i] = []
	for grid: Vector2i in _loaded_cells.keys():
		coords.append(grid)
	return coords


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

	# Calculate progress (0-100)
	var progress := 0.0
	if target_cells > 0:
		progress = float(loaded + loading * 0.5) / float(target_cells) * 100.0
		progress = clampf(progress, 0.0, 100.0)

	startup_progress.emit(progress, loaded, target_cells, queue_size)

## Check if currently in startup phase
func is_in_startup_phase() -> bool:
	return _startup_phase

#endregion
