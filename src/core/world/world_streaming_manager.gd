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
##   ├── DistantStaticRenderer (merged meshes for MID tier, 500m-2km)
##   └── ImpostorManager (impostors for FAR tier, 2km-5km)
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
const DistanceTierManagerScript := preload("res://src/core/world/distance_tier_manager.gd")
const QuadtreeChunkManagerScript := preload("res://src/core/world/quadtree_chunk_manager.gd")
const ChunkRendererScript := preload("res://src/core/world/chunk_renderer.gd")

## Emitted when a cell starts loading
signal cell_loading(grid: Vector2i)

## Emitted when a cell finishes loading
signal cell_loaded(grid: Vector2i, node: Node3D)

## Emitted when a cell is unloaded
signal cell_unloaded(grid: Vector2i)

#region Configuration

## View distance in cells (radius around camera) - NEAR tier only
## Extended tiers (MID/FAR/HORIZON) are managed by DistanceTierManager
@export var view_distance_cells: int = 3

## Whether to load objects (can disable for terrain-only view)
@export var load_objects: bool = true

## Enable distant rendering (MID/FAR/HORIZON tiers beyond NEAR)
## When disabled, only NEAR tier is used (original behavior ~351m)
##
## This is now safe to enable - the system has:
## - Hard cell limits per tier (NEAR=50, MID=100, FAR=200)
## - View frustum culling for distant tiers
## - Pre-baked asset loading (graceful fallback if assets missing)
##
## NOTE: Distant content won't appear until you run the prebaking tools:
## - mesh_prebaker.gd for MID tier (merged meshes)
## - impostor_baker.gd for FAR tier (impostors)
@export var distant_rendering_enabled: bool = false:
	set(value):
		distant_rendering_enabled = value
		# Sync to tier_manager when changed at runtime
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

## Enable chunk-based paging for MID/FAR tiers (quadtree optimization)
## When enabled, MID/FAR tiers use chunks (4x4 and 8x8 cells) instead of per-cell
## This reduces visibility calculations by ~35x and improves performance
## NEAR tier always uses per-cell regardless of this setting
@export var use_chunk_paging: bool = true

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
var _cached_far_min_dist: float = 500.0
var _cached_far_max_dist: float = 5000.0
var _tier_distances_cached: bool = false

## Distant static renderer for MID tier (merged meshes, 500m-2km)
var distant_renderer: Node3D = null  # DistantStaticRenderer

## Impostor manager for FAR tier (impostors, 2km-5km)
var impostor_manager: Node = null  # ImpostorManager

## Quadtree chunk manager for hierarchical chunk organization
var chunk_manager: QuadtreeChunkManager = null

## Chunk renderer for MID/FAR tier chunk-based loading
var chunk_renderer: Node3D = null  # ChunkRenderer

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
	_setup_owdb()
	_setup_static_renderer()
	_setup_tier_manager()
	_setup_distant_renderers()
	_setup_chunk_paging()
	_setup_occlusion_culling()
	_initialized = true
	_debug("WorldStreamingManager initialized (distant rendering: %s, chunk paging: %s)" % [
		"enabled" if distant_rendering_enabled else "disabled",
		"enabled" if use_chunk_paging else "disabled"
	])


## Time budget for async object instantiation per frame (ms)
## This is the main bottleneck - Node3D.duplicate() is expensive
## Priority over terrain to show objects quickly
## Increased from 3ms to 8ms based on OpenMW research - they use larger budgets
## Combined with object count cap in CellManager for consistent frame times
@export var instantiation_budget_ms: float = 8.0

func _process(delta: float) -> void:
	if not _initialized:
		return

	if not _tracked_node:
		return

	# Update player movement prediction for preloading
	_update_movement_prediction(delta)

	# Check if camera moved to a new cell
	var current_cell := _get_cell_from_godot_position(_tracked_node.global_position)
	if current_cell != _last_camera_cell:
		_last_camera_cell = current_cell
		_on_camera_cell_changed(current_cell)

	# Poll for completed async cell requests
	_poll_async_completions()

	# Process async object instantiation with time budget
	# This is CRITICAL - without this, objects parsed in background never get created!
	if cell_manager and cell_manager.has_method("process_async_instantiation"):
		cell_manager.process_async_instantiation(instantiation_budget_ms)

	# Process object load queue with time budget
	if async_loading_enabled and not _load_queue.is_empty():
		_process_load_queue()

	# Update impostor visibility based on camera distance (only when distant rendering is active)
	if distant_rendering_enabled and impostor_manager and impostor_manager.has_method("update_impostor_visibility"):
		var camera_pos := _tracked_node.global_position
		# Use cached tier distances (updated in _cache_tier_distances)
		if not _tier_distances_cached:
			_cache_tier_distances()
		impostor_manager.call("update_impostor_visibility", camera_pos, _cached_far_min_dist, _cached_far_max_dist)

	# Diagnostic logging every ~1 second
	var current_frame := Engine.get_frames_drawn()
	if diagnostic_logging and (current_frame - _diag_last_log_frame) >= 60:
		var inst_queue := 0
		var async_reqs := 0
		if cell_manager:
			if cell_manager.has_method("get_instantiation_queue_size"):
				inst_queue = cell_manager.get_instantiation_queue_size()
			if cell_manager.has_method("get_async_pending_count"):
				async_reqs = cell_manager.get_async_pending_count()

		if _load_queue.size() > 0 or inst_queue > 0 or async_reqs > 0:
			print("[DIAG] WSM: load_queue=%d, inst_queue=%d, async_reqs=%d, loaded_cells=%d, fps=%.1f" % [
				_load_queue.size(),
				inst_queue,
				async_reqs,
				_loaded_cells.size(),
				Engine.get_frames_per_second()
			])
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
	else:
		_preload_direction = Vector2.ZERO


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

	# Already loaded?
	if grid in _loaded_cells:
		return _loaded_cells[grid]

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

	# Add chunk paging stats if enabled
	if use_chunk_paging and chunk_renderer:
		var chunk_stats: Dictionary = chunk_renderer.call("get_stats") if chunk_renderer.has_method("get_stats") else {}
		stats["chunk_paging"] = {
			"enabled": true,
			"mid_chunks": chunk_stats.get("mid_chunks_loaded", 0),
			"far_chunks": chunk_stats.get("far_chunks_loaded", 0),
			"mid_cells": chunk_stats.get("mid_cells_loaded", 0),
			"far_cells": chunk_stats.get("far_cells_loaded", 0),
			"last_update_ms": chunk_stats.get("last_update_ms", 0.0),
		}
	else:
		stats["chunk_paging"] = {"enabled": false}

	if owdb and owdb.has_method("get_currently_loaded_nodes"):
		stats["owdb_loaded_nodes"] = owdb.call("get_currently_loaded_nodes")
		stats["owdb_total_nodes"] = owdb.call("get_total_database_nodes")

	# Add cell manager async stats if available
	if cell_manager and cell_manager.has_method("get_instantiation_queue_size"):
		stats["instantiation_queue"] = cell_manager.get_instantiation_queue_size()

	return stats


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


## Set up distant renderers for MID/FAR tiers
## Always creates the renderers (lightweight) so they're ready when toggled on
func _setup_distant_renderers() -> void:
	# Always create renderers - they're lightweight until used
	# The distant_rendering_enabled flag controls whether they're updated in _process

	# Try to load DistantStaticRenderer for MID tier
	var distant_renderer_class: Resource = load("res://src/core/world/distant_static_renderer.gd")
	if distant_renderer_class:
		distant_renderer = Node3D.new()
		distant_renderer.set_script(distant_renderer_class)
		distant_renderer.name = "DistantStaticRenderer"
		add_child(distant_renderer)

		# Create and configure StaticMeshMerger
		var merger_class: Resource = load("res://src/core/world/static_mesh_merger.gd")
		if merger_class:
			var mesh_merger: RefCounted = (merger_class as GDScript).new()

			# Connect mesh simplifier if available (use fast native MeshOptimizer)
			var optimizer_class: Resource = load("res://addons/meshoptimizer/mesh_optimizer.gd")
			if optimizer_class:
				mesh_merger.set("mesh_simplifier", (optimizer_class as GDScript).new())

			# Connect model loader from cell_manager if available
			if cell_manager and cell_manager.has_method("get_model_loader"):
				mesh_merger.set("model_loader", cell_manager.call("get_model_loader"))
			elif cell_manager and "_model_loader" in cell_manager:
				mesh_merger.set("model_loader", cell_manager.get("_model_loader"))

			if distant_renderer.has_method("set_mesh_merger"):
				distant_renderer.call("set_mesh_merger", mesh_merger)
			if distant_renderer.has_method("set_cell_manager"):
				distant_renderer.call("set_cell_manager", cell_manager)

		_debug("DistantStaticRenderer created for MID tier (500m-2km)")

	# Try to load ImpostorManager for FAR tier
	var impostor_manager_class: Resource = load("res://src/core/world/impostor_manager.gd")
	if impostor_manager_class:
		impostor_manager = Node3D.new()
		impostor_manager.set_script(impostor_manager_class)
		impostor_manager.name = "ImpostorManager"
		add_child(impostor_manager)

		# Create and connect ImpostorCandidates
		var candidates_class: Resource = load("res://src/core/world/impostor_candidates.gd")
		if candidates_class:
			var candidates: RefCounted = (candidates_class as GDScript).new()
			if impostor_manager.has_method("set_impostor_candidates"):
				impostor_manager.call("set_impostor_candidates", candidates)

		_debug("ImpostorManager created for FAR tier (2km-5km)")


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


## Set up chunk-based paging for MID/FAR tiers
## Always creates chunk infrastructure so it's ready when toggled on
func _setup_chunk_paging() -> void:
	if not use_chunk_paging:
		_debug("Chunk paging disabled by configuration")
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
		chunk_renderer.call("configure", chunk_manager, distant_renderer, impostor_manager, tier_manager)
	chunk_renderer.set("debug_enabled", debug_enabled)

	_debug("Chunk paging enabled - MID: 4x4 cells/chunk, FAR: 8x8 cells/chunk")

#endregion


#region Cell Loading

## Called when camera moves to a different cell
func _on_camera_cell_changed(new_cell: Vector2i) -> void:
	_debug("Camera cell changed to: %s" % new_cell)

	# Reset dropped cell counter for this update cycle
	_queue_full_message_count = 0

	# Use tiered loading if enabled and tier manager exists
	if distant_rendering_enabled and tier_manager:
		_on_camera_cell_changed_tiered(new_cell)
		return

	# Original behavior: NEAR tier only
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


## Tiered camera cell change handler
## Manages cells across all tiers (NEAR, MID, FAR, HORIZON)
func _on_camera_cell_changed_tiered(new_cell: Vector2i) -> void:
	# Use chunk-based paging for MID/FAR if enabled
	if use_chunk_paging and chunk_renderer:
		# NEAR tier: still per-cell (needs physics/interaction)
		var near_cells := tier_manager.get_cells_for_tier(new_cell, DistanceTierManagerScript.Tier.NEAR)
		_update_tier_cells(DistanceTierManagerScript.Tier.NEAR, near_cells, new_cell)

		# MID/FAR tiers: chunk-based (handled by ChunkRenderer)
		if chunk_renderer.has_method("update_chunks"):
			chunk_renderer.call("update_chunks", new_cell)

		# Update stats for NEAR tier only (chunk stats handled by ChunkRenderer)
		var near_loaded: Dictionary = _loaded_cells_by_tier[DistanceTierManagerScript.Tier.NEAR]
		_stats_cells_per_tier[DistanceTierManagerScript.Tier.NEAR] = near_loaded.size()

		# Copy chunk stats for MID/FAR
		if chunk_renderer.has_method("get_stats"):
			var chunk_stats: Dictionary = chunk_renderer.call("get_stats")
			_stats_cells_per_tier[DistanceTierManagerScript.Tier.MID] = chunk_stats.get("mid_cells_loaded", 0)
			_stats_cells_per_tier[DistanceTierManagerScript.Tier.FAR] = chunk_stats.get("far_cells_loaded", 0)
	else:
		# Fallback: original per-cell behavior for all tiers
		var cells_by_tier: Dictionary = tier_manager.get_visible_cells_by_tier(new_cell)

		# Process each tier
		for tier_key: int in cells_by_tier:
			var visible_cells: Array = cells_by_tier[tier_key]
			_update_tier_cells(tier_key, visible_cells, new_cell)

		# Update stats
		for tier_key: int in cells_by_tier:
			var tier_loaded: Dictionary = _loaded_cells_by_tier[tier_key]
			_stats_cells_per_tier[tier_key] = tier_loaded.size()


## Update cells for a specific tier
## CRITICAL: MID/FAR tiers are processed DIRECTLY, not through the queue
## Only NEAR tier uses the async queue system (prevents queue flooding)
func _update_tier_cells(tier: int, visible_cells: Array, camera_cell: Vector2i) -> void:
	var loaded: Dictionary = _loaded_cells_by_tier[tier]
	var loading: Dictionary = _loading_cells_by_tier[tier]

	# Build set for fast lookup
	var visible_set: Dictionary = {}
	for cell: Vector2i in visible_cells:
		visible_set[cell] = true

	# Unload cells that are no longer in this tier
	var cells_to_unload: Array[Vector2i] = []
	for cell_grid: Vector2i in loaded:
		if cell_grid not in visible_set:
			cells_to_unload.append(cell_grid)

	for cell_grid in cells_to_unload:
		_unload_cell_for_tier(tier, cell_grid)

	# Remove from load queue if no longer needed in this tier (NEAR only uses queue)
	if tier == DistanceTierManagerScript.Tier.NEAR:
		_load_queue = _load_queue.filter(func(entry: Dictionary) -> bool:
			return entry.get("tier", DistanceTierManagerScript.Tier.NEAR) != tier or entry.grid in visible_set
		)

		# Cancel async requests for cells no longer in view
		var requests_to_cancel: Array[int] = []
		for request_id: int in _async_cell_requests:
			if _async_cell_requests[request_id] not in visible_set:
				requests_to_cancel.append(request_id)

		for request_id in requests_to_cancel:
			var grid: Vector2i = _async_cell_requests[request_id]
			if cell_manager:
				cell_manager.cancel_async_request(request_id)
			_async_cell_requests.erase(request_id)
			loading.erase(grid)
			_loading_cells.erase(grid)
			_debug("Cancelled async request for out-of-tier cell: %s" % grid)

	# Load new visible cells
	if load_objects:
		for grid: Vector2i in visible_cells:
			if grid not in loaded and grid not in loading:
				match tier:
					DistanceTierManagerScript.Tier.NEAR:
						_queue_cell_load_tiered(grid, camera_cell, tier)
					DistanceTierManagerScript.Tier.MID:
						_process_mid_tier_cell(grid)
					DistanceTierManagerScript.Tier.FAR:
						_process_far_tier_cell(grid)
					DistanceTierManagerScript.Tier.HORIZON:
						_process_horizon_tier_cell(grid)


## Unload a cell from a specific tier
func _unload_cell_for_tier(tier: int, grid: Vector2i) -> void:
	match tier:
		DistanceTierManagerScript.Tier.NEAR:
			_unload_cell_internal(grid)
		DistanceTierManagerScript.Tier.MID:
			_unload_mid_tier_cell(grid)
		DistanceTierManagerScript.Tier.FAR:
			_unload_far_tier_cell(grid)
		DistanceTierManagerScript.Tier.HORIZON:
			_unload_horizon_tier_cell(grid)

	# Remove from tier tracking
	var loaded_dict: Dictionary = _loaded_cells_by_tier[tier]
	loaded_dict.erase(grid)
	tier_manager.forget_cell(grid)


## Unload MID tier cell (merged mesh)
func _unload_mid_tier_cell(grid: Vector2i) -> void:
	if distant_renderer and distant_renderer.has_method("remove_cell"):
		distant_renderer.call("remove_cell", grid)
		_debug("Unloaded MID tier cell: %s" % grid)


## Unload FAR tier cell (impostors)
func _unload_far_tier_cell(grid: Vector2i) -> void:
	if impostor_manager and impostor_manager.has_method("remove_impostors_for_cell"):
		impostor_manager.call("remove_impostors_for_cell", grid)
		_debug("Unloaded FAR tier cell: %s" % grid)


## Unload HORIZON tier cell (skybox layer - usually no-op)
func _unload_horizon_tier_cell(_grid: Vector2i) -> void:
	# HORIZON tier is typically static skybox, no per-cell unloading needed
	pass


## Get list of cells that should be visible around a center cell
func _get_visible_cells(center: Vector2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []

	for dy in range(-view_distance_cells, view_distance_cells + 1):
		for dx in range(-view_distance_cells, view_distance_cells + 1):
			# Circular check for more natural view distance
			if dx * dx + dy * dy <= view_distance_cells * view_distance_cells:
				cells.append(Vector2i(center.x + dx, center.y + dy))

	return cells


## Internal cell loading
func _load_cell_internal(grid: Vector2i) -> Node3D:
	if not cell_manager:
		push_warning("WorldStreamingManager: No CellManager set - cannot load cells")
		return null

	_loading_cells[grid] = true
	cell_loading.emit(grid)
	_debug("Loading cell: %s" % grid)

	# Load cell using CellManager
	var cell_node: Node3D = cell_manager.load_exterior_cell(grid.x, grid.y)

	_loading_cells.erase(grid)

	if not cell_node:
		# Cell doesn't exist (ocean, etc.) - that's OK
		_debug("Cell %s has no data (ocean/empty)" % grid)
		return null

	# Add directly to scene tree (OWDB is for static scenes, not dynamic loading)
	add_child(cell_node)

	# No scaling needed - CellManager now outputs in meters (via CoordinateSystem)
	# Both terrain and objects are in consistent meter units

	# Store grid reference for later lookup
	cell_node.set_meta("cell_grid", grid)

	_loaded_cells[grid] = cell_node
	cell_loaded.emit(grid, cell_node)
	_debug("Cell loaded: %s with %d children" % [grid, cell_node.get_child_count()])

	return cell_node


## Internal cell unloading
func _unload_cell_internal(grid: Vector2i) -> void:
	if grid not in _loaded_cells:
		return

	var cell_node: Node3D = _loaded_cells[grid]
	_loaded_cells.erase(grid)

	# Clean up all loading state to allow re-loading when player returns
	_loading_cells.erase(grid)
	_deferred_cells.erase(grid)
	if _loading_cells_by_tier.has(DistanceTierManagerScript.Tier.NEAR):
		var near_loading: Dictionary = _loading_cells_by_tier[DistanceTierManagerScript.Tier.NEAR]
		near_loading.erase(grid)

	if cell_node and is_instance_valid(cell_node):
		# Release pooled objects back to the pool before freeing the cell
		# This dramatically improves performance by reusing Node3D instances
		if cell_manager:
			var pool: RefCounted = cell_manager.get_object_pool()
			if pool and pool.has_method("release_cell_objects"):
				var released: int = pool.call("release_cell_objects", cell_node)
				if released > 0:
					_debug("Released %d objects to pool from cell %s" % [released, grid])

		cell_node.queue_free()

	# Clean up static renderer instances (flora, small rocks rendered via RenderingServer)
	if cell_manager and cell_manager.has_method("cleanup_cell_static_instances"):
		var static_removed: int = cell_manager.call("cleanup_cell_static_instances", grid)
		if static_removed > 0:
			_debug("Removed %d static instances from cell %s" % [static_removed, grid])

	cell_unloaded.emit(grid)
	_debug("Cell unloaded: %s" % grid)

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


## Add a cell to the priority load queue with tier information
## Tier priority is factored in: NEAR loads before MID, MID before FAR
func _queue_cell_load_tiered(grid: Vector2i, camera_cell: Vector2i, tier: int) -> void:
	# O(1) check if already in queue using set
	if grid in _load_queue_set:
		return

	# Check queue size limit - throttle debug messages to prevent log spam
	if _load_queue.size() >= max_load_queue_size:
		_queue_full_message_count += 1
		if _queue_full_message_count == 1 or _queue_full_message_count % _queue_full_message_throttle == 0:
			_debug("Load queue full, dropped %d cells (latest: %s, tier %d)" % [_queue_full_message_count, grid, tier])
		return

	# Calculate base priority from distance (Manhattan distance)
	var dx := grid.x - camera_cell.x
	var dy := grid.y - camera_cell.y
	var distance := absf(dx) + absf(dy)

	# Start with tier priority (NEAR=0, MID=1000, FAR=2000)
	# This ensures NEAR cells always load before MID, MID before FAR
	var tier_priority_offset: int = tier_manager.get_tier_priority(tier)
	tier_priority_offset = 100 - tier_priority_offset  # Invert so NEAR (100) becomes 0, MID (50) becomes 50, etc.
	var priority: float = tier_priority_offset * 100 + distance

	# Apply frustum priority: cells in front of camera load first (NEAR tier only)
	if frustum_priority_enabled and _tracked_node and tier == DistanceTierManagerScript.Tier.NEAR:
		var camera_forward := Vector3.FORWARD
		if _tracked_node is Camera3D:
			camera_forward = -(_tracked_node as Camera3D).global_transform.basis.z
		elif _tracked_node.has_method("get_camera_3d"):
			var cam: Variant = _tracked_node.call("get_camera_3d")
			if cam is Camera3D:
				camera_forward = -(cam as Camera3D).global_transform.basis.z

		var cell_dir := Vector3(dx, 0, -dy).normalized()
		var dot := camera_forward.dot(cell_dir)
		priority -= dot * 2.0

	# Binary heap insertion - O(log n) instead of O(n)
	var entry_dict := { "grid": grid, "priority": priority, "tier": tier }
	_heap_push(entry_dict)
	_load_queue_set[grid] = true

	# Track high water mark
	if _load_queue.size() > _stats_queue_high_water_mark:
		_stats_queue_high_water_mark = _load_queue.size()

	# Track in tier-specific loading dictionary (for queue management)
	# Note: _loading_cells is NOT updated here - only when async request actually starts
	# This prevents the "already loading" check from blocking queue processing
	_loading_cells_by_tier[tier][grid] = true

	# Emit signal for UI feedback (cell is queued for loading)
	if tier == DistanceTierManagerScript.Tier.NEAR:
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

		# Route to tier-specific loader
		match tier:
			DistanceTierManagerScript.Tier.NEAR:
				async_submits_this_frame += _process_near_tier_cell(grid, use_async)
			DistanceTierManagerScript.Tier.MID:
				_process_mid_tier_cell(grid)
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

## Whether to fall back to runtime mesh merging if pre-baked not available
## WARNING: Runtime merging is slow (50-100ms per cell) - should be false in production
@export var allow_runtime_mesh_merging: bool = false


## Process MID tier cell (merged static geometry)
## CRITICAL: Uses pre-baked merged meshes, NOT runtime merging
func _process_mid_tier_cell(grid: Vector2i) -> void:
	var mid_loading := _loading_cells_by_tier[DistanceTierManagerScript.Tier.MID] as Dictionary
	var mid_loaded := _loaded_cells_by_tier[DistanceTierManagerScript.Tier.MID] as Dictionary

	if grid in mid_loaded:
		mid_loading.erase(grid)
		return

	# Try to load pre-baked merged mesh (fast path)
	var prebaked_path := _get_merged_cells_path().path_join("cell_%d_%d.res" % [grid.x, grid.y])
	if ResourceLoader.exists(prebaked_path):
		var mesh := load(prebaked_path) as ArrayMesh
		if mesh and distant_renderer and distant_renderer.has_method("add_cell_prebaked"):
			distant_renderer.call("add_cell_prebaked", grid, mesh)
			mid_loading.erase(grid)
			mid_loaded[grid] = true
			_debug("MID tier cell loaded: %s (pre-baked)" % grid)
			return

	# Fallback to runtime merging if enabled (SLOW - development only)
	if allow_runtime_mesh_merging and distant_renderer and distant_renderer.has_method("add_cell"):
		var cell_record := ESMManager.get_exterior_cell(grid.x, grid.y)
		if cell_record:
			distant_renderer.call("add_cell", grid, cell_record.references)
			mid_loading.erase(grid)
			mid_loaded[grid] = true
			_debug("MID tier cell loaded: %s (runtime merge - SLOW)" % grid)
			return

	# No pre-baked data and runtime disabled - skip gracefully
	mid_loading.erase(grid)
	mid_loaded[grid] = true


## Process FAR tier cell (impostors)
func _process_far_tier_cell(grid: Vector2i) -> void:
	var far_loading := _loading_cells_by_tier[DistanceTierManagerScript.Tier.FAR] as Dictionary
	var far_loaded := _loaded_cells_by_tier[DistanceTierManagerScript.Tier.FAR] as Dictionary

	if grid in far_loaded:
		far_loading.erase(grid)
		return

	if not impostor_manager or not impostor_manager.has_method("add_cell_impostors"):
		far_loading.erase(grid)
		far_loaded[grid] = true
		return

	var cell_record := ESMManager.get_exterior_cell(grid.x, grid.y)
	if not cell_record:
		far_loading.erase(grid)
		far_loaded[grid] = true
		return

	var count: int = impostor_manager.call("add_cell_impostors", grid, cell_record.references)
	far_loading.erase(grid)
	far_loaded[grid] = true

	if count > 0:
		_debug("FAR tier cell loaded: %s (%d impostors)" % [grid, count])


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
			if grid in _loaded_cells and _loaded_cells[grid] == cell_node:
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


## Cache tier distances to avoid dictionary lookups every frame
func _cache_tier_distances() -> void:
	if tier_manager:
		_cached_far_min_dist = tier_manager.tier_distances.get(DistanceTierManagerScript.Tier.FAR, 500.0)
		_cached_far_max_dist = tier_manager.tier_end_distances.get(DistanceTierManagerScript.Tier.FAR, 5000.0)
	_tier_distances_cached = true


## Invalidate tier distance cache (call when tier config changes)
func invalidate_tier_cache() -> void:
	_tier_distances_cached = false

#endregion
