## WorldStreamingManager - Cell/Object streaming coordinator
##
## **SIMPLIFIED ARCHITECTURE** - This now handles ONLY cell/object streaming.
## For terrain, use GenericTerrainStreamer separately.
##
## This follows the simplification-cascades principle: "Terrain and objects
## are separate concerns" - they should be independent streaming systems.
##
## Architecture:
##   WorldStreamingManager (objects only)
##   ├── OpenWorldDatabase (handles object streaming via OWDB addon)
##   │   └── [Cell nodes parented here for automatic streaming]
##   ├── OWDBPosition (tracks camera position for streaming)
##   ├── DistanceTierManager (determines NEAR/MID/FAR/HORIZON tiers)
##   ├── ObjectStreamer (per-object LOD with dither crossfade, 0-500m)
##   └── ImpostorManager (impostors for FAR tier, 500m-5km)
##
## For terrain streaming, use:
##   GenericTerrainStreamer (terrain only)
##   ├── Works with any WorldDataProvider (Morrowind, LaPalma, etc.)
##   └── Handles Terrain3D population and streaming
##
## Reference: Simplification-cascades refactoring - Phase 1
## Extended: Distant rendering system (Phases 1-3)
class_name WorldStreamingManager
extends Node3D

# Preload dependencies
const CS := preload("res://src/core/coordinate_system.gd")
const DU := preload("res://src/core/world/distance_utils.gd")
const DistanceTierManagerScript := preload("res://src/core/world/distance_tier_manager.gd")
const QuadtreeChunkManagerScript := preload("res://src/core/world/quadtree_chunk_manager.gd")
const ChunkRendererScript := preload("res://src/core/world/chunk_renderer.gd")
const ObjectStreamerScript := preload("res://src/core/world/object_streamer.gd")
# ObjectDistanceManager is DEPRECATED - merged into ObjectStreamer
const ObjectPositionIndexScript := preload("res://src/core/world/object_position_index.gd")

## Emitted when a cell starts loading
signal cell_loading(grid: Vector2i)

## Emitted when a cell finishes loading
signal cell_loaded(grid: Vector2i, node: Node3D)

## Emitted when a cell is unloaded
signal cell_unloaded(grid: Vector2i)

#region Configuration

## View distance in cells (radius around camera) - NEAR tier only
## Extended tiers (MID/FAR/HORIZON) are managed by DistanceTierManager
## With 117m cells, 2 cells = ~234m (NEAR tier ends at 150m, so this provides buffer)
@export var view_distance_cells: int = 2

## Whether to load objects (can disable for terrain-only view)
@export var load_objects: bool = true:
	set(value):
		load_objects = value
		# Sync with ObjectStreamer if it exists
		if object_streamer:
			object_streamer.enabled = value
			# Clear all objects when disabled
			if not value and object_streamer.has_method("clear"):
				object_streamer.clear()

## Enable distant rendering with AAA streaming
## When enabled:
## - Cells loaded as metadata-only (terrain/water)
## - Objects discovered by ObjectPositionIndex (distance-based)
## - ObjectStreamer handles per-object LOD (NEAR/MID/FAR tiers)
## - Impostors for FAR tier (500m-5km)
##
## When disabled:
## - Legacy NEAR-only mode (~150m view distance)
## - Cells loaded with all objects
## - No LOD system
##
## NOTE: Requires prebaked assets:
## - Run lod_prebaker.gd for LOD meshes (MID tier)
## - Run impostor baker for impostors (FAR tier)
@export var distant_rendering_enabled: bool = true:
	set(value):
		distant_rendering_enabled = value
		if tier_manager:
			tier_manager.distant_rendering_enabled = value

## NOTE: Terrain streaming removed - use GenericTerrainStreamer separately
## This manager now focuses ONLY on cell/object streaming

## OWDB chunk sizes optimized for Morrowind object scales (in Godot units)
## Small: candles, cups, books (~8 units)
## Medium: furniture, doors, containers (~16 units)
## Large: trees, large rocks, buildings (~64 units)
@export var owdb_chunk_sizes: Array[float] = [8.0, 16.0, 64.0]

## OWDB chunk load range (chunks around each position)
@export var owdb_chunk_load_range: int = 3

## OWDB batch processing time limit (ms per frame)
@export var owdb_batch_time_limit_ms: float = 5.0

## Enable debug output
@export var debug_enabled: bool = false

## Enable diagnostic logging for performance tracing
@export var diagnostic_logging: bool = true

## Diagnostic counters
var _diag_last_log_frame: int = 0
var _diag_cells_queued_this_second: int = 0
var _diag_cells_loaded_this_second: int = 0

## Cells waiting for async capacity (prevents infinite re-queue loop)
var _deferred_cells: Dictionary = {}  # grid -> true

## Time budget for cell loading per frame (ms)
## This is for submitting async requests, should be low as actual parsing is async
@export var cell_load_budget_ms: float = 2.0

## Maximum cells to queue for loading (NEAR tier uses queue, other tiers should NOT use queue)
## If distant_rendering_enabled, this needs to be much larger, but that's experimental
@export var max_load_queue_size: int = 128

## Enable async/time-budgeted cell loading
@export var async_loading_enabled: bool = true

## Maximum cell async requests to submit per frame
## Industry standard: 1-2 per frame to avoid I/O saturation and queue flooding
## Increased to 3 for faster initial load when toggling models on
@export var max_cell_submits_per_frame: int = 3

## Adaptive cell submit rate based on queue pressure
## When queue is small, allow more submits; when large, throttle harder
@export var adaptive_submit_rate: bool = true
@export var queue_pressure_threshold: int = 200  # Objects in queue before throttling (reduced from 500)

## Enable occlusion culling (don't render objects behind other objects)
## Significant performance boost in dense cities and interiors
@export var occlusion_culling_enabled: bool = true

## Path to prebaked position index file (for AAA streaming)
## If empty or file doesn't exist, will scan ESM data at startup (~1-2 seconds)
## Once built, saved to cache for instant future startups
@export var position_index_path: String = "user://cache/object_position_index.json"

## Whether to save the position index after building (recommended: true)
@export var save_position_index: bool = true

#endregion

#region Node References

## Reference to OpenWorldDatabase node (created automatically)
var owdb: Node = null  # OpenWorldDatabase type

## Reference to OWDBPosition node (tracks streaming position)
var owdb_position: Node3D = null  # OWDBPosition type

## Reference to CellManager for loading cell data
var cell_manager: CellManager = null

## Reference to BackgroundProcessor for async operations
var background_processor: Node = null  # BackgroundProcessor

## Static object renderer for fast flora rendering
var static_renderer: Node3D = null  # StaticObjectRenderer

## Distance tier manager for multi-tier rendering
var tier_manager: DistanceTierManager = null

## Cached tier distances to avoid repeated dictionary lookups in _process
var _cached_far_min_dist: float = DU.FAR_START
var _cached_far_max_dist: float = DU.FAR_END
var _tier_distances_cached: bool = false

## Impostor manager for FAR tier (impostors, 500m-5km)
var impostor_manager: Node = null  # ImpostorManager

## Quadtree chunk manager for hierarchical chunk organization
var chunk_manager: QuadtreeChunkManager = null

## Chunk renderer for FAR tier chunk-based loading
var chunk_renderer: Node3D = null  # ChunkRenderer

## ENHANCED Object Streamer (Phase 1+ with merged best features)
## Combines ObjectDistanceManager + ObjectStreamer with:
## - Object pooling for memory management
## - Time-budgeted instantiation queue for smooth frame times
## - AAA streaming via ObjectPositionIndex
## - Node recreation tracking
var object_streamer: Node3D = null  # ObjectStreamer

## Object position index for AAA-style streaming (Phase 2B)
## Enables distance-based object discovery without loading cells first
var object_position_index: RefCounted = null  # ObjectPositionIndex

## Legacy aliases for compatibility
@warning_ignore("unused_private_class_variable")
var object_distance_manager: Node3D:
	get: return object_streamer
	set(value): object_streamer = value

@warning_ignore("unused_private_class_variable")
var per_object_lod_manager: Node3D:
	get: return object_streamer
	set(value): object_streamer = value

#endregion

#region State

## Currently tracked camera/player node
var _tracked_node: Node3D = null

## Currently loaded exterior cells: Vector2i -> Node3D
var _loaded_cells: Dictionary = {}

## Cells currently being loaded (async)
var _loading_cells: Dictionary = {}

## Async request tracking: request_id -> Vector2i grid
var _async_cell_requests: Dictionary = {}

## Last known camera cell position
var _last_camera_cell: Vector2i = Vector2i(999999, 999999)

## Player movement prediction for preloading
var _last_player_position: Vector3 = Vector3.ZERO
var _player_velocity_smoothed: Vector3 = Vector3.ZERO  # Smoothed velocity for prediction
var _preload_direction: Vector2 = Vector2.ZERO  # Predicted movement direction in cell coords

## Whether the system is initialized
var _initialized: bool = false

## Priority queue for cells to load (min-heap, lower priority = higher precedence)
## Each entry: { "grid": Vector2i, "priority": float (lower = higher priority), "tier": Tier }
## Uses binary heap for O(log n) insertion instead of O(n) sorted array insertion
var _load_queue: Array = []

## Set of cells currently in the load queue for O(1) existence check
var _load_queue_set: Dictionary = {}  # grid -> true

## Loaded cells by tier: Tier -> Dictionary[Vector2i -> variant]
## NEAR tier stores Node3D, MID/FAR tiers store RID or instance data
var _loaded_cells_by_tier: Dictionary = {}

## Cells being loaded by tier: Tier -> Dictionary[Vector2i -> true]
var _loading_cells_by_tier: Dictionary = {}

## Performance stats
var _stats_load_time_ms: float = 0.0
var _stats_cells_loaded_this_frame: int = 0
var _stats_queue_high_water_mark: int = 0

## Stats per tier
var _stats_cells_per_tier: Dictionary = {}

## Throttle for "queue full" debug messages (don't spam the log)
var _queue_full_message_count: int = 0
var _queue_full_message_throttle: int = 100  # Only print every N dropped cells

#endregion


func _ready() -> void:
	# Note: OWDB setup is deferred - call initialize() after setting properties
	_debug("WorldStreamingManager ready - call initialize() to start streaming")


## Initialize the streaming system after configuration
## Must be called after setting cell_manager and other properties
func initialize() -> void:
	if _initialized:
		return

	# VALIDATE MODE COMBINATIONS (prevent invalid configurations)
	_validate_streaming_modes()

	_setup_owdb()
	_setup_static_renderer()
	_setup_tier_manager()
	_setup_distant_renderers()  # ObjectStreamer + ImpostorManager
	_setup_occlusion_culling()
	_setup_position_index()  # AAA streaming position index
	_verify_taa_enabled()  # Warn if TAA disabled (needed for dithering quality)
	_initialized = true

	# Log diagnostic info
	_log_distant_rendering_status()


## Verify TAA (Temporal Anti-Aliasing) is enabled for best dithering quality
## Dithering crossfade works without TAA but looks noisy/grainy
func _verify_taa_enabled() -> void:
	# Only check if distant rendering is enabled (dithering only used with LOD system)
	if not distant_rendering_enabled:
		return

	# Check if TAA is enabled in project settings
	var use_taa: bool = ProjectSettings.get_setting("rendering/anti_aliasing/quality/use_taa", false)

	if not use_taa:
		push_warning("═══════════════════════════════════════════════════════════")
		push_warning("[WSM] TAA (Temporal Anti-Aliasing) is DISABLED")
		push_warning("[WSM] Dithering crossfade will look noisy without TAA!")
		push_warning("[WSM]")
		push_warning("[WSM] To fix:")
		push_warning("[WSM]   1. Open Project Settings")
		push_warning("[WSM]   2. Navigate to: Rendering > Anti Aliasing > Quality")
		push_warning("[WSM]   3. Enable 'Use TAA' checkbox")
		push_warning("[WSM]   4. Restart the project")
		push_warning("[WSM]")
		push_warning("[WSM] See docs/STREAMING_MODES.md for more details")
		push_warning("═══════════════════════════════════════════════════════════")
	else:
		_debug("TAA enabled ✓ - Dithering crossfade will look smooth")


## Log active streaming mode
func _validate_streaming_modes() -> void:
	var mode_name := "Legacy (NEAR only, ~150m)"
	if distant_rendering_enabled:
		mode_name = "AAA Streaming (position index + LOD tiers, 0-5km)"

	print("[WSM] ═══════════════════════════════════════════")
	print("[WSM] Streaming Mode: %s" % mode_name)
	if distant_rendering_enabled:
		print("[WSM]   • Cells: Metadata-only (terrain/water)")
		print("[WSM]   • Objects: Distance-based via ObjectPositionIndex")
		print("[WSM]   • Tiers: NEAR (0-150m) / MID (150-500m) / FAR (500m-5km)")
		print("[WSM]   • Crossfade: Dithering with TAA")
	else:
		print("[WSM]   • Simple radius-based cell loading")
		print("[WSM]   • No LOD system")
	print("[WSM] ═══════════════════════════════════════════")


## Time budget for object instantiation per frame (ms)
## With prebaked models (no NIF conversion at runtime), this only covers:
## - Loading from disk cache (~1-5ms per model, cached after first load)
## - Node3D.duplicate() (~0.35ms per object)
## - add_child() to scene tree
## Increased to 12ms for faster visible loading (still within 16.6ms frame budget)
@export var instantiation_budget_ms: float = 12.0

func _process(delta: float) -> void:
	if not _initialized:
		return

	if not _tracked_node:
		return

	# Update player movement prediction for preloading
	_update_movement_prediction(delta)

	var camera_pos := _tracked_node.global_position
	var current_cell := _get_cell_from_godot_position(camera_pos)

	# ═══════════════════════════════════════════════════════════════════════
	# **UNIFIED VISIBILITY AUTHORITY** - Single source of truth for all visibility
	# ═══════════════════════════════════════════════════════════════════════
	# 1. Update camera position in tier manager (MUST be before update_visibility)
	if tier_manager:
		tier_manager.set_camera_position(camera_pos)

	# 2. **CALCULATE ALL VISIBILITY** - This is the ONLY place visibility is computed
	var vis_stats: Dictionary = {}
	if tier_manager and distant_rendering_enabled:
		vis_stats = tier_manager.update_visibility(current_cell, delta)

		# Log visibility changes if diagnostic logging enabled
		if diagnostic_logging and vis_stats.get("objects_changed_tier", 0) > 0:
			print("[WSM] Visibility: %d objects changed tier" % vis_stats.objects_changed_tier)

	# ═══════════════════════════════════════════════════════════════════════
	# **CONSUMERS** - Systems react to visibility changes (NO calculations)
	# ═══════════════════════════════════════════════════════════════════════

	# Check if camera moved to a new cell
	if current_cell != _last_camera_cell:
		_last_camera_cell = current_cell
		_on_camera_cell_changed(current_cell)

	# Poll for completed async cell requests
	_poll_async_completions()

	# Process async object instantiation with time budget
	# This is CRITICAL - without this, objects parsed in background never get created!
	# Pass camera position for distance-priority sorting (nearest objects first)
	if cell_manager and cell_manager.has_method("process_async_instantiation"):
		cell_manager.process_async_instantiation(instantiation_budget_ms, camera_pos)

	# Process object load queue with time budget
	if async_loading_enabled and not _load_queue.is_empty():
		_process_load_queue()

	# **UNIFIED VISIBILITY**: Impostor visibility from tier manager
	if distant_rendering_enabled and impostor_manager:
		impostor_manager.call("update_visibility")

	# **UNIFIED VISIBILITY**: Object streamer processes tier changes from authority
	if distant_rendering_enabled and object_streamer:
		object_streamer.update(camera_pos, delta)
		# Note: process_instantiation_queue() is called automatically inside update()

	# Diagnostic logging every ~1 second
	var current_frame := Engine.get_frames_drawn()

	# Periodically clean up ODM tracking for cells that have gone beyond FAR tier
	# This runs every ~60 frames to avoid per-frame overhead
	if distant_rendering_enabled and object_streamer and (current_frame % 60) == 0:
		_cleanup_distant_odm_tracking()

	# Periodically clean up stale cell references (nodes freed externally by OWDB)
	# This runs every ~120 frames to avoid per-frame overhead
	if (current_frame % 120) == 0:
		_cleanup_stale_cell_references()

	if diagnostic_logging and (current_frame - _diag_last_log_frame) >= 60:
		var inst_queue := 0
		var async_reqs := 0
		if cell_manager:
			if cell_manager.has_method("get_instantiation_queue_size"):
				inst_queue = cell_manager.get_instantiation_queue_size()
			if cell_manager.has_method("get_async_pending_count"):
				async_reqs = cell_manager.get_async_pending_count()

		_diag_cells_queued_this_second = 0
		_diag_cells_loaded_this_second = 0
		_diag_last_log_frame = current_frame


## Update player movement prediction for cell preloading
## Uses smoothed velocity to predict which cells the player is moving towards
func _update_movement_prediction(delta: float) -> void:
	if not _tracked_node:
		return

	var current_pos := _tracked_node.global_position

	# Calculate instant velocity
	var instant_velocity := (current_pos - _last_player_position) / maxf(delta, 0.001)
	_last_player_position = current_pos

	# Smooth velocity with exponential moving average (reduces jitter)
	var smoothing := 0.1  # Lower = smoother but slower response
	_player_velocity_smoothed = _player_velocity_smoothed.lerp(instant_velocity, smoothing)

	# Convert to cell direction (XZ plane, ignore vertical)
	var horizontal_velocity := Vector2(_player_velocity_smoothed.x, -_player_velocity_smoothed.z)
	if horizontal_velocity.length_squared() > 1.0:  # Only if moving at >1 m/s
		_preload_direction = horizontal_velocity.normalized()
		# Trigger predictive preloading when moving
		_preload_predicted_cells()
	else:
		_preload_direction = Vector2.ZERO


## Preload cells ahead of player in movement direction
## This prevents loading hiccups by having cells ready before player arrives
func _preload_predicted_cells() -> void:
	if _preload_direction.length_squared() < 0.01:
		return  # Not moving significantly

	if not load_objects or not cell_manager:
		return

	# Look 1-2 cells ahead in movement direction
	var look_ahead_cells := 2
	var predicted_offset := Vector2i(
		roundi(_preload_direction.x * look_ahead_cells),
		roundi(_preload_direction.y * look_ahead_cells)
	)
	var predicted_cell := _last_camera_cell + predicted_offset

	# Skip if already loaded or loading
	if predicted_cell in _loaded_cells:
		return
	if predicted_cell in _loading_cells:
		return
	if predicted_cell in _load_queue_set:
		return
	if predicted_cell in _deferred_cells:
		return

	# Queue predicted cell with low priority (100 = preload priority)
	# This ensures visible cells still load first, but we start preloading ahead
	if async_loading_enabled:
		var entry := { "grid": predicted_cell, "priority": 100.0, "tier": DistanceTierManagerScript.Tier.NEAR }
		_heap_push(entry)
		_load_queue_set[predicted_cell] = true
		_loading_cells[predicted_cell] = true
		_loading_cells_by_tier[DistanceTierManagerScript.Tier.NEAR][predicted_cell] = true

		if debug_enabled:
			_debug("Preloading predicted cell: %s (direction: %.2f, %.2f)" % [
				predicted_cell, _preload_direction.x, _preload_direction.y
			])


## Get preload priority bonus for a cell based on movement direction
## Returns 0-3 priority bonus (lower = higher priority)
func _get_preload_priority_bonus(cell_offset: Vector2i) -> float:
	if _preload_direction.length_squared() < 0.5:
		return 0.0  # Not moving significantly

	var cell_dir := Vector2(cell_offset.x, cell_offset.y).normalized()
	var dot := _preload_direction.dot(cell_dir)

	# dot = 1 means cell is in movement direction, -1 means opposite
	# Return bonus: cells ahead get priority boost (negative = higher priority)
	return -dot * 3.0  # Up to 3 priority levels bonus for cells ahead


#region Public API

## Set the node to track for streaming (usually player or camera)
func set_tracked_node(node: Node3D) -> void:
	_tracked_node = node
	_debug("Tracking node: %s" % node.name if node else "null")

	# Update OWDB position tracker
	if owdb_position and node:
		# Parent OWDBPosition to tracked node so it follows automatically
		if owdb_position.get_parent() != node:
			owdb_position.reparent(node)
		owdb_position.position = Vector3.ZERO

	# Set up camera reference for frustum culling
	if tier_manager and node:
		var camera: Camera3D = null
		if node is Camera3D:
			camera = node
		elif node.has_method("get_camera_3d"):
			camera = node.call("get_camera_3d") as Camera3D
		else:
			camera = get_viewport().get_camera_3d()

		if camera:
			tier_manager.set_camera(camera)
			if chunk_renderer and chunk_renderer.has_method("set_camera"):
				chunk_renderer.call("set_camera", camera)
			_debug("Camera set for frustum culling: %s" % camera.name)

	# Force immediate update
	if node:
		var cell := _get_cell_from_godot_position(node.global_position)
		_last_camera_cell = cell
		_on_camera_cell_changed(cell)


## Get the currently tracked node
func get_tracked_node() -> Node3D:
	return _tracked_node


## Load a specific exterior cell (can be called manually)
func load_cell(grid_x: int, grid_y: int) -> Node3D:
	var grid := Vector2i(grid_x, grid_y)

	# Already loaded? Check with untyped access to handle OWDB-freed nodes
	if grid in _loaded_cells:
		var existing_ref: Variant = _loaded_cells[grid]
		if is_instance_valid(existing_ref):
			return existing_ref as Node3D
		else:
			# Node was freed externally (likely by OWDB) - clean up stale reference
			_loaded_cells.erase(grid)

	# Already loading?
	if grid in _loading_cells:
		return null

	return _load_cell_internal(grid)


## Unload a specific cell
func unload_cell(grid_x: int, grid_y: int) -> void:
	var grid := Vector2i(grid_x, grid_y)
	_unload_cell_internal(grid)


## Get a loaded cell by grid coordinates
func get_loaded_cell(grid_x: int, grid_y: int) -> Node3D:
	return _loaded_cells.get(Vector2i(grid_x, grid_y))


## Get all currently loaded cell coordinates
func get_loaded_cell_coordinates() -> Array[Vector2i]:
	var coords: Array[Vector2i] = []
	# Iterate dictionary directly instead of .keys() to avoid allocation
	for key: Vector2i in _loaded_cells:
		coords.append(key)
	return coords


## Force reload all cells around current position
func refresh_cells() -> void:
	if _tracked_node:
		var cell := _get_cell_from_godot_position(_tracked_node.global_position)
		_on_camera_cell_changed(cell)


## Force load all visible cells using async queue with high priority
## Use this when toggling objects on - uses async to avoid frame freezes
## Set use_async=false for synchronous loading (for testing/debugging only)
func force_load_visible_cells(use_async: bool = true) -> void:
	if not _tracked_node or not cell_manager:
		return

	var camera_cell := _get_cell_from_godot_position(_tracked_node.global_position)
	var visible_cells := _get_visible_cells(camera_cell)

	_debug("Force loading %d visible cells around %s (async=%s)" % [visible_cells.size(), camera_cell, use_async])

	# Clear any stale queue entries for these cells and re-add with highest priority
	var cells_to_queue: Array[Vector2i] = []
	for cell_grid in visible_cells:
		if cell_grid not in _loaded_cells:
			cells_to_queue.append(cell_grid)
			# Remove from queue set so we can re-add with new priority
			if cell_grid in _load_queue_set:
				_load_queue_set.erase(cell_grid)

	# Remove matching entries from queue (O(n) but necessary for priority update)
	if not cells_to_queue.is_empty():
		_load_queue = _load_queue.filter(func(entry: Dictionary) -> bool:
			return entry.grid not in cells_to_queue)

	if use_async:
		# Queue all cells with highest priority (negative = even higher than normal)
		for cell_grid: Vector2i in cells_to_queue:
			var dx := cell_grid.x - camera_cell.x
			var dy := cell_grid.y - camera_cell.y
			var distance := absf(dx) + absf(dy)
			# Use very low (high priority) base: -100 + distance
			# This ensures these cells load before any normal queued cells
			var priority: float = -100.0 + distance

			var entry := { "grid": cell_grid, "priority": priority }
			_heap_push(entry)
			_load_queue_set[cell_grid] = true
			_loading_cells[cell_grid] = true
			cell_loading.emit(cell_grid)
	else:
		# Synchronous fallback (for debugging) - load one per frame to avoid freeze
		for cell_grid: Vector2i in cells_to_queue:
			_loading_cells.erase(cell_grid)
			_load_cell_internal(cell_grid)


## Clear all tier tracking dictionaries to force fresh loading
## Call this when toggling models on to ensure cells are actually loaded
func clear_tier_state() -> void:
	_debug("Clearing tier state for fresh loading")

	# Clear tier tracking (but don't unload - we'll let refresh_cells handle that)
	for tier: int in _loaded_cells_by_tier:
		(_loaded_cells_by_tier[tier] as Dictionary).clear()
	for tier: int in _loading_cells_by_tier:
		(_loading_cells_by_tier[tier] as Dictionary).clear()

	# Also clear the legacy tracking dictionaries
	_loaded_cells.clear()
	_loading_cells.clear()
	_load_queue.clear()
	_load_queue_set.clear()
	_async_cell_requests.clear()
	_deferred_cells.clear()

	# Reset tier manager cell tracking
	if tier_manager and tier_manager.has_method("clear"):
		tier_manager.call("clear")

	# Clear ChunkRenderer state so it reloads MID/FAR chunks
	if chunk_renderer and chunk_renderer.has_method("clear"):
		chunk_renderer.clear()


## Unload all cells and reload them - use when toggling models on
## This ensures objects are properly instantiated with LOD registration
func reload_all_cells() -> void:
	if not _tracked_node:
		return

	_debug("Reloading all cells with objects enabled")

	# First, unload all existing cell nodes
	var cells_to_remove: Array[Node] = []
	for child in get_children():
		if child is Node3D and child.has_meta("cell_grid"):
			cells_to_remove.append(child)

	for cell_node in cells_to_remove:
		var grid: Vector2i = cell_node.get_meta("cell_grid")
		cell_node.queue_free()
		cell_unloaded.emit(grid)

	# Clear all tracking
	clear_tier_state()

	# Give a frame for queue_free to process
	await get_tree().process_frame

	# Now trigger fresh cell loading
	var cell := _get_cell_from_godot_position(_tracked_node.global_position)
	_on_camera_cell_changed(cell)

	_debug("Reload complete - cells will now load with objects")


## Set the CellManager instance to use
func set_cell_manager(manager: CellManager) -> void:
	cell_manager = manager
	_debug("CellManager set")


## Set the BackgroundProcessor for async loading
func set_background_processor(processor: Node) -> void:
	background_processor = processor
	_debug("BackgroundProcessor set")


## Get statistics about loaded content
func get_stats() -> Dictionary:
	var stats := {
		"loaded_cells": _loaded_cells.size(),
		"loading_cells": _loading_cells.size(),
		"tracked_node": _tracked_node.name if _tracked_node else "none",
		"camera_cell": _last_camera_cell,
		"view_distance": view_distance_cells,
		"load_queue_size": _load_queue.size(),
		"load_time_ms": _stats_load_time_ms,
		"cells_loaded_this_frame": _stats_cells_loaded_this_frame,
		"queue_high_water_mark": _stats_queue_high_water_mark,
		"async_pending": _async_cell_requests.size(),
		"distant_rendering_enabled": distant_rendering_enabled,
	}

	# Add tier-specific stats if distant rendering is enabled
	if distant_rendering_enabled and tier_manager:
		var near_dict: Dictionary = _loaded_cells_by_tier.get(DistanceTierManagerScript.Tier.NEAR, {})
		var mid_dict: Dictionary = _loaded_cells_by_tier.get(DistanceTierManagerScript.Tier.MID, {})
		var far_dict: Dictionary = _loaded_cells_by_tier.get(DistanceTierManagerScript.Tier.FAR, {})
		var horizon_dict: Dictionary = _loaded_cells_by_tier.get(DistanceTierManagerScript.Tier.HORIZON, {})
		stats["cells_by_tier"] = {
			"NEAR": near_dict.size(),
			"MID": mid_dict.size(),
			"FAR": far_dict.size(),
			"HORIZON": horizon_dict.size(),
		}
		stats["tier_distances"] = tier_manager.get_debug_info()

	# Add chunk renderer stats if available (used for FAR tier impostors)
	if chunk_renderer and chunk_renderer.has_method("get_stats"):
		stats["chunk_renderer"] = chunk_renderer.call("get_stats")

	if owdb and owdb.has_method("get_currently_loaded_nodes"):
		stats["owdb_loaded_nodes"] = owdb.call("get_currently_loaded_nodes")
		stats["owdb_total_nodes"] = owdb.call("get_total_database_nodes")

	# Add cell manager async stats if available
	if cell_manager and cell_manager.has_method("get_instantiation_queue_size"):
		stats["instantiation_queue"] = cell_manager.get_instantiation_queue_size()

	# Add object streamer stats if enabled
	if object_streamer and object_streamer.has_method("get_stats"):
		stats["object_distance_manager"] = object_streamer.get_stats()
		stats["using_object_streamer"] = true

	return stats


## Get the object distance manager for external registration
## Used by ReferenceInstantiator to register significant objects
## Returns ObjectStreamer (ObjectDistanceManager is deprecated)
func get_object_distance_manager() -> Node3D:
	return object_streamer

## Legacy alias for compatibility
func get_per_object_lod_manager() -> Node3D:
	return object_streamer


## Verify LOD pipeline is properly initialized
## Returns dictionary with status of each component in the chain
## Use this for debugging when LOD system appears broken
func verify_lod_pipeline() -> Dictionary:
	var result := {
		"using_object_streamer": true,
		"wsm_has_object_streamer": object_streamer != null,
		"object_streamer_in_tree": object_streamer.is_inside_tree() if object_streamer else false,
		"cell_manager_set": cell_manager != null,
		"cell_manager_has_odm": false,
		"shaders_loaded": false,
		"batcher_initialized": false,
		"tracked_object_count": 0,
		"batcher_batch_count": 0,
		"distant_rendering_enabled": distant_rendering_enabled,
	}

	if cell_manager:
		var cm_odm: Variant = cell_manager.get_object_distance_manager() if cell_manager.has_method("get_object_distance_manager") else null
		result["cell_manager_has_odm"] = cm_odm != null
		if cell_manager.has_method("get_stats"):
			var cm_stats: Dictionary = cell_manager.get_stats()
			result["cell_manager_stats"] = cm_stats

	if object_streamer:
		# Check shaders
		var mm_shader: Variant = object_streamer.get("_multimesh_shader")
		result["multimesh_shader_ok"] = mm_shader != null
		# ObjectStreamer doesn't have _node3d_shader (not needed for pooling approach)
		result["node3d_shader_ok"] = true
		result["shaders_loaded"] = result["multimesh_shader_ok"] and result["node3d_shader_ok"]

		# Check batcher
		var batcher: Variant = object_streamer.get("_batcher")
		if batcher:
			result["batcher_initialized"] = batcher.get("_scene_root") != null
			result["batcher_batch_count"] = batcher.get_batch_count() if batcher.has_method("get_batch_count") else 0

		# Check tracked objects
		var objects: Variant = object_streamer.get("_objects")
		if objects is Dictionary:
			result["tracked_object_count"] = objects.size()

		# ObjectStreamer pool stats
		var pool: Variant = object_streamer.get("_object_pool")
		var pool_available: Variant = object_streamer.get("_pool_available")
		if pool is Array:
			result["pool_size"] = pool.size()
		if pool_available is Array:
			result["pool_available"] = pool_available.size()

	# Print summary
	print("=== LOD Pipeline Verification ===")
	print("  using_object_streamer: %s" % result["using_object_streamer"])
	print("  distant_rendering_enabled: %s" % result["distant_rendering_enabled"])
	print("  wsm_has_object_streamer: %s" % result["wsm_has_object_streamer"])
	print("  object_streamer_in_tree: %s" % result["object_streamer_in_tree"])
	print("  cell_manager_has_odm: %s" % result["cell_manager_has_odm"])
	print("  shaders_loaded: %s (mm=%s, n3d=%s)" % [
		result["shaders_loaded"],
		result.get("multimesh_shader_ok", false),
		result.get("node3d_shader_ok", false)
	])
	print("  batcher_initialized: %s" % result["batcher_initialized"])
	print("  tracked_object_count: %d" % result["tracked_object_count"])
	print("  batcher_batch_count: %d" % result["batcher_batch_count"])
	print("  pool_size: %d" % result.get("pool_size", 0))
	print("  pool_available: %d" % result.get("pool_available", 0))
	print("=================================")

	return result


## Preload common models to reduce initial loading delays
## Call this after initialize() but before the player starts moving
## sync: If true, blocks until complete. If false, loads in background.
func preload_common_models(sync: bool = false) -> void:
	if not cell_manager:
		push_warning("WorldStreamingManager: No CellManager set - cannot preload models")
		return

	if sync:
		cell_manager.preload_common_models()
	else:
		if cell_manager.has_method("preload_common_models_async"):
			cell_manager.preload_common_models_async()
		else:
			cell_manager.preload_common_models()

#endregion


#region Internal Setup

## Set up OpenWorldDatabase for object streaming
func _setup_owdb() -> void:
	# Check if OWDB addon is available
	var owdb_class := load("res://addons/open-world-database/src/open_world_database.gd")
	if not owdb_class:
		push_warning("WorldStreamingManager: OWDB addon not found - object streaming disabled")
		return

	# Create OWDB node
	owdb = Node.new()
	owdb.set_script(owdb_class)
	owdb.name = "OpenWorldDatabase"

	# Configure OWDB for Morrowind object scales (use set() for dynamic properties)
	owdb.set("chunk_sizes", owdb_chunk_sizes)
	owdb.set("chunk_load_range", owdb_chunk_load_range)
	owdb.set("batch_time_limit_ms", owdb_batch_time_limit_ms)
	owdb.set("batch_processing_enabled", true)
	owdb.set("debug_enabled", debug_enabled)

	add_child(owdb)
	_debug("OWDB created and configured")

	# Create OWDBPosition for tracking camera
	var position_class := load("res://addons/open-world-database/src/OWDBPosition.gd")
	if position_class:
		owdb_position = Node3D.new()
		owdb_position.set_script(position_class)
		owdb_position.name = "StreamingPosition"
		add_child(owdb_position)
		_debug("OWDBPosition created")


## Set up StaticObjectRenderer for fast flora rendering
func _setup_static_renderer() -> void:
	var renderer_class := load("res://src/core/world/static_object_renderer.gd")
	if not renderer_class:
		push_warning("WorldStreamingManager: StaticObjectRenderer not found - flora will use Node3D (slower)")
		return

	static_renderer = Node3D.new()
	static_renderer.set_script(renderer_class)
	static_renderer.name = "StaticObjectRenderer"
	add_child(static_renderer)


## Enable occlusion culling for massive performance boost in cities/interiors
func _setup_occlusion_culling() -> void:
	if not occlusion_culling_enabled:
		return

	# Enable occlusion culling on the viewport
	var viewport := get_viewport()
	if viewport:
		# Use RenderingServer to enable occlusion culling globally
		RenderingServer.viewport_set_use_occlusion_culling(viewport.get_viewport_rid(), true)
		_debug("Occlusion culling enabled - objects behind other objects won't render")
	else:
		push_warning("WorldStreamingManager: No viewport found, occlusion culling not enabled")

	# Connect to cell_manager
	if cell_manager and cell_manager.has_method("set_static_renderer"):
		cell_manager.call("set_static_renderer", static_renderer)
		_debug("StaticObjectRenderer created and connected to CellManager")
	else:
		_debug("StaticObjectRenderer created (CellManager not available)")


## Set up DistanceTierManager for multi-tier rendering
func _setup_tier_manager() -> void:
	tier_manager = DistanceTierManagerScript.new()
	tier_manager.distant_rendering_enabled = distant_rendering_enabled

	# Initialize tier tracking dictionaries
	for tier: int in [
		DistanceTierManagerScript.Tier.NEAR,
		DistanceTierManagerScript.Tier.MID,
		DistanceTierManagerScript.Tier.FAR,
		DistanceTierManagerScript.Tier.HORIZON,
	]:
		_loaded_cells_by_tier[tier] = {}
		_loading_cells_by_tier[tier] = {}
		_stats_cells_per_tier[tier] = 0

	_debug("DistanceTierManager created with hard cell limits: NEAR=%d, MID=%d, FAR=%d" % [
		DistanceTierManagerScript.DEFAULT_MAX_CELLS_PER_TIER[DistanceTierManagerScript.Tier.NEAR],
		DistanceTierManagerScript.DEFAULT_MAX_CELLS_PER_TIER[DistanceTierManagerScript.Tier.MID],
		DistanceTierManagerScript.DEFAULT_MAX_CELLS_PER_TIER[DistanceTierManagerScript.Tier.FAR],
	])


## Set up distant renderers for FAR tier and per-object LOD
## Always creates the renderers (lightweight) so they're ready when toggled on
func _setup_distant_renderers() -> void:
	# Create ImpostorManager for FAR tier (impostors from 500m-5km)
	var impostor_manager_class: Resource = load("res://src/core/world/impostor_manager.gd")
	if impostor_manager_class:
		impostor_manager = Node3D.new()
		impostor_manager.set_script(impostor_manager_class)
		impostor_manager.name = "ImpostorManager"
		# Sync debug mode with WSM
		impostor_manager.set("debug_enabled", debug_enabled)
		add_child(impostor_manager)

		# Create and connect ImpostorCandidates
		var candidates_class: Resource = load("res://src/core/world/impostor_candidates.gd")
		if candidates_class:
			var candidates: RefCounted = (candidates_class as GDScript).new()
			if impostor_manager.has_method("set_impostor_candidates"):
				impostor_manager.call("set_impostor_candidates", candidates)

		# **UNIFIED VISIBILITY**: Connect DistanceTierManager to ImpostorManager
		if tier_manager and impostor_manager.has_method("set_distance_tier_manager"):
			impostor_manager.call("set_distance_tier_manager", tier_manager)
			_debug("ImpostorManager connected to DistanceTierManager for visibility authority")

		_debug("ImpostorManager created for FAR tier (150m-5km)")

	# Set up ObjectStreamer (ObjectDistanceManager is deprecated)
	_setup_object_streamer()


## Set up new unified ObjectStreamer (Phase 1 refactor)
func _setup_object_streamer() -> void:
	object_streamer = Node3D.new()
	object_streamer.set_script(ObjectStreamerScript)
	object_streamer.name = "ObjectStreamer"
	add_child(object_streamer)

	# Set enabled state from load_objects (respects Models toggle)
	object_streamer.enabled = load_objects

	# Connect impostor manager for FAR tier coordination
	if impostor_manager:
		object_streamer.set_impostor_manager(impostor_manager)

	# Share impostor candidates for significance determination
	if impostor_manager and impostor_manager.has_method("get_impostor_candidates"):
		var candidates: Variant = impostor_manager.call("get_impostor_candidates")
		if candidates:
			object_streamer.set_impostor_candidates(candidates)

	# Connect DistanceTierManager for centralized tier calculations
	# This eliminates duplicate tier logic and ensures consistent tier boundaries
	if tier_manager and object_streamer.has_method("set_distance_tier_manager"):
		object_streamer.set_distance_tier_manager(tier_manager)
		_debug("ObjectStreamer connected to DistanceTierManager for tier calculations")

	# Pass to CellManager so ReferenceInstantiator can register objects
	# ObjectStreamer has the same API as ObjectDistanceManager
	if cell_manager and cell_manager.has_method("set_object_distance_manager"):
		cell_manager.set_object_distance_manager(object_streamer)

	# Connect instantiation_requested signal for deferred object loading
	if object_streamer.has_signal("instantiation_requested"):
		object_streamer.connect("instantiation_requested", _on_odm_instantiation_requested)
		_debug("Connected to ObjectStreamer instantiation_requested signal")

	_debug("ObjectStreamer created (unified Phase 1 system)")


## Configure tier manager for a specific world
## Call this after initialize() if using a custom world data provider
func configure_for_world(world_provider: RefCounted) -> void:
	if tier_manager:
		tier_manager.configure_for_world(world_provider)
		_debug("Tier manager configured for world")

	# Reconfigure chunk manager with new tier distances
	if chunk_manager and tier_manager:
		chunk_manager.configure(tier_manager)
		_debug("Chunk manager reconfigured for world")


## Set up chunk-based paging for FAR tier
## NOTE: MID tier removed - per-object LOD handles significant objects
## Always creates chunk infrastructure so it's ready when toggled on
func _setup_chunk_paging() -> void:
	# ChunkRenderer is used for FAR tier impostor organization in AAA mode
	if not distant_rendering_enabled:
		return

	# Create chunk manager
	chunk_manager = QuadtreeChunkManagerScript.new()
	if tier_manager:
		chunk_manager.configure(tier_manager)

	# Create chunk renderer
	chunk_renderer = Node3D.new()
	chunk_renderer.set_script(ChunkRendererScript)
	chunk_renderer.name = "ChunkRenderer"
	add_child(chunk_renderer)

	# Configure chunk renderer with dependencies
	if chunk_renderer.has_method("configure"):
		chunk_renderer.call("configure", chunk_manager, impostor_manager, tier_manager)
	chunk_renderer.set("debug_enabled", debug_enabled)

	_debug("ChunkRenderer initialized for FAR tier impostors")


## Set up object position index for AAA streaming
## Builds spatial index of all object positions for distance-based queries
func _setup_position_index() -> void:
	if not distant_rendering_enabled:
		return

	# Create position index
	object_position_index = ObjectPositionIndexScript.new()

	# Try to load from prebaked file first (faster startup)
	var loaded := false
	if not position_index_path.is_empty():
		var load_error: Error = object_position_index.load_from_file(position_index_path)
		if load_error == OK:
			loaded = true
			_debug("Loaded position index from %s" % position_index_path)

	# If not loaded, build from ESM data
	if not loaded:
		_debug("Building position index from ESM data...")
		object_position_index.build_from_esm()

		# Optionally save for faster future startups
		if save_position_index and not position_index_path.is_empty():
			# Ensure cache directory exists
			var dir_path: String = position_index_path.get_base_dir()
			DirAccess.make_dir_recursive_absolute(dir_path)
			var save_error: Error = object_position_index.save_to_file(position_index_path)
			if save_error == OK:
				_debug("Saved position index to %s" % position_index_path)

	# Wire position index to ObjectStreamer
	if object_streamer and object_streamer.has_method("set_position_index"):
		object_streamer.set_position_index(object_position_index)
		_debug("Connected position index to ObjectStreamer")

	var stats: Dictionary = object_position_index.get_stats()
	_debug("AAA streaming ready: %d objects indexed in %d cells" % [
		stats.get("total_objects", 0),
		stats.get("cells_indexed", 0)
	])

#endregion


#region Cell Loading

## Called when camera moves to a different cell
var _cell_change_log_count: int = 0
func _on_camera_cell_changed(new_cell: Vector2i) -> void:
	_cell_change_log_count += 1
	if _cell_change_log_count <= 5:
		print("[WSM] Camera cell changed to: %s (mode: %s)" % [
			new_cell, "AAA" if distant_rendering_enabled else "Legacy"])
	_debug("Camera cell changed to: %s" % new_cell)

	# Reset dropped cell counter for this update cycle
	_queue_full_message_count = 0

	# AAA STREAMING: Objects discovered via ObjectPositionIndex, cells are metadata-only
	# This is the production mode - always use when distant_rendering_enabled=true
	if distant_rendering_enabled and object_streamer:
		_on_camera_cell_changed_aaa(new_cell)
		return

	# LEGACY MODE: Simple NEAR-only cell loading (~150m)
	# Only used when distant_rendering_enabled=false
	var visible_cells := _get_visible_cells(new_cell)

	# Build visible set for O(1) lookup instead of O(n) array search
	var visible_set: Dictionary = {}
	for cell: Vector2i in visible_cells:
		visible_set[cell] = true

	# Unload cells that are no longer visible
	# Iterate dictionary directly instead of .keys() to avoid allocation
	var cells_to_unload: Array[Vector2i] = []
	for cell_grid: Vector2i in _loaded_cells:
		if cell_grid not in visible_set:
			cells_to_unload.append(cell_grid)

	for cell_grid in cells_to_unload:
		_unload_cell_internal(cell_grid)

	# Also remove from load queue if no longer needed (use visible_set for O(1) lookup)
	_load_queue = _load_queue.filter(func(entry: Dictionary) -> bool: return entry.grid in visible_set)

	# Cancel async requests for cells no longer in view (prevents wasted work)
	var requests_to_cancel: Array[int] = []
	for request_id: int in _async_cell_requests:
		var grid: Vector2i = _async_cell_requests[request_id]
		if grid not in visible_set:
			requests_to_cancel.append(request_id)

	for request_id in requests_to_cancel:
		var grid: Vector2i = _async_cell_requests[request_id]
		if cell_manager:
			cell_manager.cancel_async_request(request_id)
		_async_cell_requests.erase(request_id)
		_loading_cells.erase(grid)
		_debug("Cancelled async request for out-of-view cell: %s" % grid)

	# Queue new visible cells for loading
	if load_objects and cell_manager:
		for cell_grid in visible_cells:
			if cell_grid not in _loaded_cells and cell_grid not in _loading_cells:
				if async_loading_enabled:
					_queue_cell_load(cell_grid, new_cell)
				else:
					_load_cell_internal(cell_grid)


## Hysteresis for cell unloading in AAA mode (meters beyond visible range before unload)
const CELL_UNLOAD_HYSTERESIS: float = 100.0


## AAA streaming camera cell change handler (Phase 2B)
## Objects are streamed by ObjectStreamer via position index - we don't load them here.
## We still load cells for terrain/water/metadata but skip object instantiation.
func _on_camera_cell_changed_aaa(new_cell: Vector2i) -> void:
	# Cells are still needed for terrain/water, but objects are handled by ObjectStreamer
	# Use a simple NEAR-only approach for terrain cells since objects are independent
	var visible_cells := _get_visible_cells(new_cell)

	# Build visible set for O(1) lookup
	var visible_set: Dictionary = {}
	for cell: Vector2i in visible_cells:
		visible_set[cell] = true

	# Unload cells that are no longer visible
	var cells_to_unload: Array[Vector2i] = []
	for cell_grid: Vector2i in _loaded_cells:
		if cell_grid not in visible_set:
			cells_to_unload.append(cell_grid)

	for cell_grid in cells_to_unload:
		# When unloading, DON'T unregister from ObjectStreamer - it manages its own lifecycle
		_unload_cell_internal(cell_grid, true)  # keep_odm_tracking=true

	# Load new cells (terrain/water only - skip object loading)
	if cell_manager:
		for cell_grid in visible_cells:
			if cell_grid not in _loaded_cells and cell_grid not in _loading_cells:
				# Queue cell load but skip object instantiation
				if async_loading_enabled:
					_queue_cell_load_aaa(cell_grid, new_cell)
				else:
					_load_cell_internal_aaa(cell_grid)

	# Update FAR tier chunk rendering (impostors) - independent of object streaming
	if chunk_renderer and chunk_renderer.has_method("update_chunks"):
		chunk_renderer.call("update_chunks", new_cell)


## Queue a cell for AAA streaming (skip object loading)
func _queue_cell_load_aaa(cell_grid: Vector2i, camera_cell: Vector2i) -> void:
	if cell_grid in _load_queue_set:
		return

	# Don't exceed queue limit
	if _load_queue.size() >= max_load_queue_size:
		return

	var priority := (camera_cell - cell_grid).length_squared()

	# Mark as AAA mode in the queue entry
	var entry := {
		"grid": cell_grid,
		"priority": priority,
		"tier": DistanceTierManagerScript.Tier.NEAR,
		"aaa_mode": true  # Skip object loading
	}

	_heap_push(entry)
	_load_queue_set[cell_grid] = true


## Load a cell in AAA mode (skip object instantiation)
func _load_cell_internal_aaa(cell_grid: Vector2i) -> void:
	if cell_grid in _loaded_cells:
		return

	_loading_cells[cell_grid] = true

	if not cell_manager:
		_loading_cells.erase(cell_grid)
		return

	# Load cell WITHOUT object instantiation - uses metadata-only method
	var cell_node: Node3D = cell_manager.load_exterior_cell_metadata_only(cell_grid.x, cell_grid.y)
	if cell_node:
		add_child(cell_node)
		_loaded_cells[cell_grid] = cell_node
		emit_signal("cell_loaded", cell_grid, cell_node)

	_loading_cells.erase(cell_grid)


#endregion


#region Async Loading Queue

## Enable frustum-based priority for cell loading
## When enabled, cells in front of camera load first, reducing perceived pop-in
@export var frustum_priority_enabled: bool = true

## Add a cell to the priority load queue
## Cells closer to the camera have higher priority (lower priority value)
## When frustum_priority_enabled, cells in front of camera get bonus priority
## Movement prediction gives additional bonus to cells in player movement direction
func _queue_cell_load(grid: Vector2i, camera_cell: Vector2i) -> void:
	# O(1) check if already in queue using set
	if grid in _load_queue_set:
		return

	# Check queue size limit - throttle debug messages to prevent log spam
	if _load_queue.size() >= max_load_queue_size:
		_queue_full_message_count += 1
		if _queue_full_message_count == 1 or _queue_full_message_count % _queue_full_message_throttle == 0:
			_debug("Load queue full, dropped %d cells (latest: %s)" % [_queue_full_message_count, grid])
		return

	# Calculate base priority from distance (Manhattan distance)
	var dx := grid.x - camera_cell.x
	var dy := grid.y - camera_cell.y
	var distance := absf(dx) + absf(dy)
	var priority: float = distance  # Lower = higher priority

	# Apply movement prediction priority: cells in player movement direction load first
	# This is MORE important than frustum priority for preloading
	var cell_offset := Vector2i(dx, dy)
	priority += _get_preload_priority_bonus(cell_offset)

	# Apply frustum priority: cells in front of camera load first
	if frustum_priority_enabled and _tracked_node:
		var camera_forward := Vector3.FORWARD
		if _tracked_node is Camera3D:
			camera_forward = -(_tracked_node as Camera3D).global_transform.basis.z
		elif _tracked_node.has_method("get_camera_3d"):
			var cam: Variant = _tracked_node.call("get_camera_3d")
			if cam is Camera3D:
				camera_forward = -(cam as Camera3D).global_transform.basis.z

		# Direction to cell (in XZ plane, Y is up in Godot)
		# Cell grid: +X is east, +Y is north in Morrowind
		# In Godot: +X is east, -Z is north (after coordinate conversion)
		var cell_dir := Vector3(dx, 0, -dy).normalized()
		var dot := camera_forward.dot(cell_dir)

		# dot = 1 means cell is directly in front, -1 means behind
		# Apply penalty of up to 2 priority levels for cells behind camera
		# Movement prediction already handles direction, this is secondary
		priority -= dot * 2.0  # In front gets bonus (lower priority), behind gets penalty

	# Binary heap insertion - O(log n) instead of O(n)
	var entry := { "grid": grid, "priority": priority }
	_heap_push(entry)
	_load_queue_set[grid] = true

	# Track high water mark
	if _load_queue.size() > _stats_queue_high_water_mark:
		_stats_queue_high_water_mark = _load_queue.size()

	_loading_cells[grid] = true
	cell_loading.emit(grid)


## Process the load queue with time budgeting
## Called every frame to load cells without causing hitches
## Uses async loading when background processor is available
## Industry standard: Throttle submissions to avoid I/O saturation
func _process_load_queue() -> void:
	if _load_queue.is_empty():
		return

	var start_time := Time.get_ticks_usec()
	var budget_usec := cell_load_budget_ms * 1000.0
	_stats_cells_loaded_this_frame = 0

	# Check if we can use async loading (background processor available)
	var use_async := background_processor != null and cell_manager != null

	# Adaptive submit rate: reduce submissions when instantiation queue is backed up
	var effective_max_submits := max_cell_submits_per_frame
	if adaptive_submit_rate and cell_manager and cell_manager.has_method("get_instantiation_queue_size"):
		var queue_size: int = cell_manager.get_instantiation_queue_size()
		if queue_size > queue_pressure_threshold:
			# Queue is backed up - reduce to 0 (let it drain)
			effective_max_submits = 0
			if debug_enabled and queue_size % 100 == 0:
				_debug("Queue pressure: %d objects pending, pausing cell submissions" % queue_size)
		elif queue_size > queue_pressure_threshold / 2:
			# Queue is building up - reduce rate
			effective_max_submits = 1

	# Track submissions this frame for throttling
	var async_submits_this_frame := 0

	while not _load_queue.is_empty():
		# Check time budget
		var elapsed := Time.get_ticks_usec() - start_time
		if elapsed >= budget_usec:
			break

		# Throttle async submissions per frame to avoid queue flooding
		if use_async and async_submits_this_frame >= effective_max_submits:
			break

		# Pop highest priority cell using heap pop - O(log n)
		var entry: Dictionary = _heap_pop()
		var grid: Vector2i = entry.grid
		var tier: int = entry.get("tier", DistanceTierManagerScript.Tier.NEAR)

		# Remove from set
		_load_queue_set.erase(grid)

		# Check for AAA mode (skip object loading)
		var aaa_mode: bool = entry.get("aaa_mode", false)

		# Route to tier-specific loader
		# NOTE: MID tier is handled by ObjectDistanceManager (per-object), not queued
		match tier:
			DistanceTierManagerScript.Tier.NEAR:
				if aaa_mode:
					# AAA mode: load terrain/water only, skip objects
					_load_cell_internal_aaa(grid)
				else:
					async_submits_this_frame += _process_near_tier_cell(grid, use_async)
			DistanceTierManagerScript.Tier.FAR:
				_process_far_tier_cell(grid)
			DistanceTierManagerScript.Tier.HORIZON:
				_process_horizon_tier_cell(grid)

	# Update timing stats
	_stats_load_time_ms = (Time.get_ticks_usec() - start_time) / 1000.0


## Process NEAR tier cell (full geometry)
## Returns 1 if an async request was submitted, 0 otherwise
func _process_near_tier_cell(grid: Vector2i, use_async: bool) -> int:
	# Skip if already loaded (race condition prevention)
	if grid in _loaded_cells:
		_loading_cells.erase(grid)
		var near_loading: Dictionary = _loading_cells_by_tier[DistanceTierManagerScript.Tier.NEAR]
		near_loading.erase(grid)
		_deferred_cells.erase(grid)
		return 0

	# Skip if this cell is deferred (waiting for async capacity)
	# It will be retried when an async request completes
	if grid in _deferred_cells:
		return 0

	if use_async:
		# Submit async request - actual loading happens in background
		var request_id: int = cell_manager.request_exterior_cell_async(grid.x, grid.y)
		if request_id >= 0:
			_async_cell_requests[request_id] = grid
			_deferred_cells.erase(grid)  # Successfully started, no longer deferred

			# PROGRESSIVE LOADING: Add cell node to scene immediately
			# Objects will appear as they're instantiated by process_async_instantiation
			var cell_node: Node3D = cell_manager.get_async_cell_node(request_id)
			if cell_node and not cell_node.is_inside_tree():
				add_child(cell_node)
				cell_node.set_meta("cell_grid", grid)
				_loaded_cells[grid] = cell_node
				_loaded_cells_by_tier[DistanceTierManagerScript.Tier.NEAR][grid] = cell_node
				_debug("Async NEAR cell added for progressive loading: %s (id=%d)" % [grid, request_id])
			return 1
		else:
			# -1 can mean either "at capacity" or "cell doesn't exist"
			# Check if cell actually exists before giving up
			var cell_record: CellRecord = ESMManager.get_exterior_cell(grid.x, grid.y)
			if cell_record:
				# Cell exists but we're at capacity - mark as deferred
				# Will be retried when _poll_async_completions frees a slot
				_deferred_cells[grid] = true
				return 0
			else:
				# Cell truly doesn't exist (ocean, etc.)
				_loading_cells.erase(grid)
				var near_loading2: Dictionary = _loading_cells_by_tier[DistanceTierManagerScript.Tier.NEAR]
				near_loading2.erase(grid)
				_debug("NEAR cell %s has no data (empty/ocean)" % grid)
	else:
		# Fallback to sync loading (no background processor)
		var cell_node: Node3D = cell_manager.load_exterior_cell(grid.x, grid.y)
		_loading_cells.erase(grid)
		var near_loading3: Dictionary = _loading_cells_by_tier[DistanceTierManagerScript.Tier.NEAR]
		near_loading3.erase(grid)

		if cell_node:
			add_child(cell_node)
			cell_node.set_meta("cell_grid", grid)

			_loaded_cells[grid] = cell_node
			_loaded_cells_by_tier[DistanceTierManagerScript.Tier.NEAR][grid] = cell_node
			cell_loaded.emit(grid, cell_node)
			_stats_cells_loaded_this_frame += 1
			_debug("NEAR cell loaded (sync): %s with %d children" % [grid, cell_node.get_child_count()])
		else:
			_debug("NEAR cell %s has no data (ocean/empty)" % grid)

	return 0


## Get pre-baked merged cells path from SettingsManager
func _get_merged_cells_path() -> String:
	return SettingsManager.get_merged_cells_path()


## Get pre-baked impostors path from SettingsManager
func _get_impostors_path() -> String:
	return SettingsManager.get_impostors_path()

## Unload MID tier cell (deferred objects)
## Only cleans up ODM tracking if beyond FAR range (checked by _cleanup_distant_odm_tracking)
## Otherwise just marks as unloaded - objects remain in ODM for tier transitions
func _unload_mid_tier_cell(grid: Vector2i) -> void:
	var mid_loading := _loading_cells_by_tier[DistanceTierManagerScript.Tier.MID] as Dictionary
	mid_loading.erase(grid)

	# Note: We DON'T clean up ODM tracking here because objects may be
	# transitioning to FAR tier or may return to MID tier if player moves back.
	# ODM tracking is cleaned up periodically by _cleanup_distant_odm_tracking()
	# when cells are beyond FAR range.
	_debug("MID tier cell unloaded: %s (ODM tracking preserved)" % grid)


## Process MID tier cell with deferred loading
## Registers objects with ObjectDistanceManager for LOD-based rendering
## No Node3D created - objects instantiate when entering NEAR range
func _process_mid_tier_cell_deferred(grid: Vector2i) -> void:
	var mid_loading := _loading_cells_by_tier[DistanceTierManagerScript.Tier.MID] as Dictionary
	var mid_loaded := _loaded_cells_by_tier[DistanceTierManagerScript.Tier.MID] as Dictionary

	if grid in mid_loaded:
		mid_loading.erase(grid)
		return

	if not cell_manager or not cell_manager.has_method("load_cell_deferred"):
		# Fallback: just mark as loaded (no deferred support)
		mid_loading.erase(grid)
		mid_loaded[grid] = true
		return

	# Load cell data and register with ODM as deferred
	var count: int = cell_manager.load_cell_deferred(grid.x, grid.y)
	mid_loading.erase(grid)
	mid_loaded[grid] = true

	if count > 0:
		_debug("MID tier cell loaded (deferred): %s (%d objects registered with ODM)" % [grid, count])


## Process FAR tier cell (impostors + deferred registration)
## Loads impostors AND registers objects with ODM for tier transitions
func _process_far_tier_cell(grid: Vector2i) -> void:
	var far_loading := _loading_cells_by_tier[DistanceTierManagerScript.Tier.FAR] as Dictionary
	var far_loaded := _loaded_cells_by_tier[DistanceTierManagerScript.Tier.FAR] as Dictionary

	if grid in far_loaded:
		far_loading.erase(grid)
		return

	var cell_record := ESMManager.get_exterior_cell(grid.x, grid.y)
	if not cell_record:
		far_loading.erase(grid)
		far_loaded[grid] = true
		return

	var impostor_count := 0
	var deferred_count := 0

	# Add impostors for visual representation in FAR tier
	if impostor_manager and impostor_manager.has_method("add_cell_impostors"):
		impostor_count = impostor_manager.call("add_cell_impostors", grid, cell_record.references)

	# Also register with ODM for tier transitions (FAR→MID→NEAR)
	# This allows objects to transition smoothly when approaching
	if cell_manager and cell_manager.has_method("load_cell_deferred"):
		deferred_count = cell_manager.load_cell_deferred(grid.x, grid.y)

	far_loading.erase(grid)
	far_loaded[grid] = true

	if impostor_count > 0 or deferred_count > 0:
		_debug("FAR tier cell loaded: %s (%d impostors, %d deferred)" % [grid, impostor_count, deferred_count])


## Process HORIZON tier cell (skybox - usually no-op per cell)
func _process_horizon_tier_cell(grid: Vector2i) -> void:
	# Just mark as "loaded" to prevent re-queueing
	(_loading_cells_by_tier[DistanceTierManagerScript.Tier.HORIZON] as Dictionary).erase(grid)
	_loaded_cells_by_tier[DistanceTierManagerScript.Tier.HORIZON][grid] = true


## Poll for completed async cell requests and integrate them
func _poll_async_completions() -> void:
	if _async_cell_requests.is_empty() or not cell_manager:
		# Even if no active requests, try to start deferred cells
		_retry_deferred_cells()
		return

	var completed_requests: Array[int] = []

	for request_id: int in _async_cell_requests:
		if cell_manager.is_async_complete(request_id):
			completed_requests.append(request_id)

	for request_id in completed_requests:
		var grid: Vector2i = _async_cell_requests[request_id]
		_async_cell_requests.erase(request_id)
		_loading_cells.erase(grid)

		# Check for partial failures (some models failed to parse)
		if cell_manager.has_async_failed(request_id):
			var failed_count: int = cell_manager.get_async_failed_count(request_id)
			_debug("Cell %s had %d models fail to parse (will use placeholders)" % [grid, failed_count])

		# With progressive loading, cell_node was already added to scene in _process_load_queue
		# Just clean up tracking and emit signal
		var cell_node: Node3D = cell_manager.get_async_result(request_id)

		if cell_node:
			# Cell was already added via progressive loading - just emit signal
			# Use untyped access to handle OWDB-freed nodes safely
			var loaded_ref: Variant = _loaded_cells.get(grid)
			var loaded_valid: bool = is_instance_valid(loaded_ref) and loaded_ref == cell_node
			if loaded_valid:
				cell_loaded.emit(grid, cell_node)
				_stats_cells_loaded_this_frame += 1
				_debug("Cell async complete: %s with %d children" % [grid, cell_node.get_child_count()])
			elif not cell_node.is_inside_tree():
				# Fallback: add if not already in tree (shouldn't happen normally)
				add_child(cell_node)
				cell_node.set_meta("cell_grid", grid)
				_loaded_cells[grid] = cell_node
				cell_loaded.emit(grid, cell_node)
				_stats_cells_loaded_this_frame += 1
				_debug("Cell loaded (async fallback): %s with %d children" % [grid, cell_node.get_child_count()])
		else:
			_debug("Cell %s has no data (async result null)" % grid)

	# After completions free up slots, try to start deferred cells
	if not completed_requests.is_empty():
		_retry_deferred_cells()


## Retry cells that were deferred due to async capacity limits
func _retry_deferred_cells() -> void:
	if _deferred_cells.is_empty():
		return

	# Get cells to retry (copy keys since we modify during iteration)
	var cells_to_retry: Array = _deferred_cells.keys()

	# Sort by distance to camera for priority
	cells_to_retry.sort_custom(func(a: Variant, b: Variant) -> bool:
		var grid_a: Vector2i = a
		var grid_b: Vector2i = b
		var dist_a := (Vector2(grid_a) - Vector2(_last_camera_cell)).length_squared()
		var dist_b := (Vector2(grid_b) - Vector2(_last_camera_cell)).length_squared()
		return dist_a < dist_b
	)

	# Try to start up to 2 deferred cells per call
	var started := 0
	for grid_var: Variant in cells_to_retry:
		var grid: Vector2i = grid_var
		if started >= 2:
			break

		# Check if cell is still in view (Chebyshev distance)
		var dist := maxi(absi(grid.x - _last_camera_cell.x), absi(grid.y - _last_camera_cell.y))
		if dist > view_distance_cells:
			# Cell is now out of view - remove from deferred
			_deferred_cells.erase(grid)
			_loading_cells.erase(grid)
			continue

		# Remove from deferred BEFORE trying (prevents re-defer in same frame)
		_deferred_cells.erase(grid)

		# Try to start the async request
		var request_id: int = cell_manager.request_exterior_cell_async(grid.x, grid.y)
		if request_id >= 0:
			_async_cell_requests[request_id] = grid
			var cell_node: Node3D = cell_manager.get_async_cell_node(request_id)
			if cell_node and not cell_node.is_inside_tree():
				add_child(cell_node)
				cell_node.set_meta("cell_grid", grid)
				_loaded_cells[grid] = cell_node
				_loaded_cells_by_tier[DistanceTierManagerScript.Tier.NEAR][grid] = cell_node
			started += 1
			_debug("Deferred cell started: %s (id=%d)" % [grid, request_id])
		else:
			# Still at capacity - put back in deferred
			_deferred_cells[grid] = true


## Clear the load queue (e.g., when teleporting)
func clear_load_queue() -> void:
	for entry: Dictionary in _load_queue:
		_loading_cells.erase(entry.grid)
	_load_queue.clear()
	_load_queue_set.clear()

	# Cancel pending async requests
	if cell_manager:
		for request_id: int in _async_cell_requests:
			cell_manager.cancel_async_request(request_id)
	_async_cell_requests.clear()

	# Clear deferred cells too
	_deferred_cells.clear()

	_debug("Load queue cleared")

#endregion


#region Binary Heap Operations

## Push an entry onto the min-heap - O(log n)
func _heap_push(entry: Dictionary) -> void:
	_load_queue.append(entry)
	_heap_sift_up(_load_queue.size() - 1)


## Pop the minimum entry from the heap - O(log n)
func _heap_pop() -> Dictionary:
	if _load_queue.is_empty():
		return {}

	var result: Dictionary = _load_queue[0]

	# Move last element to root and sift down
	var last_idx := _load_queue.size() - 1
	if last_idx > 0:
		_load_queue[0] = _load_queue[last_idx]
	_load_queue.pop_back()

	if not _load_queue.is_empty():
		_heap_sift_down(0)

	return result


## Sift element up to maintain heap property
func _heap_sift_up(idx: int) -> void:
	while idx > 0:
		var parent_idx := (idx - 1) >> 1  # Integer division by 2
		if _load_queue[idx].priority < _load_queue[parent_idx].priority:
			# Swap with parent
			var tmp: Dictionary = _load_queue[idx]
			_load_queue[idx] = _load_queue[parent_idx]
			_load_queue[parent_idx] = tmp
			idx = parent_idx
		else:
			break


## Sift element down to maintain heap property
func _heap_sift_down(idx: int) -> void:
	var size := _load_queue.size()
	while true:
		var smallest := idx
		var left := (idx << 1) + 1  # 2*idx + 1
		var right := left + 1

		if left < size and _load_queue[left].priority < _load_queue[smallest].priority:
			smallest = left
		if right < size and _load_queue[right].priority < _load_queue[smallest].priority:
			smallest = right

		if smallest != idx:
			# Swap and continue
			var tmp: Dictionary = _load_queue[idx]
			_load_queue[idx] = _load_queue[smallest]
			_load_queue[smallest] = tmp
			idx = smallest
		else:
			break

#endregion


#region Coordinate Utilities

## Convert Godot world position to Morrowind cell grid coordinates
func _get_cell_from_godot_position(godot_pos: Vector3) -> Vector2i:
	return CS.godot_pos_to_cell_grid(godot_pos)


## Convert cell grid to Godot world position (center of cell)
func _cell_to_godot_position(grid: Vector2i) -> Vector3:
	return CS.cell_grid_to_center_godot(grid)

#endregion


#region Debug

func _debug(msg: String) -> void:
	if debug_enabled:
		print("WorldStreamingManager: %s" % msg)


## Log diagnostic info about distant rendering setup
func _log_distant_rendering_status() -> void:
	pass  # Debug function - call manually if needed


## Cache tier distances to avoid dictionary lookups every frame
func _cache_tier_distances() -> void:
	if tier_manager:
		_cached_far_min_dist = tier_manager.tier_distances.get(DistanceTierManagerScript.Tier.FAR, DU.FAR_START)
		_cached_far_max_dist = tier_manager.tier_end_distances.get(DistanceTierManagerScript.Tier.FAR, DU.FAR_END)
	_tier_distances_cached = true


## Invalidate tier distance cache (call when tier config changes)
func invalidate_tier_cache() -> void:
	_tier_distances_cached = false

#endregion
