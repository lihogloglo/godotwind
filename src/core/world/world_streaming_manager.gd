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
##   └── OWDBPosition (tracks camera position for streaming)
##
## For terrain streaming, use:
##   GenericTerrainStreamer (terrain only)
##   ├── Works with any WorldDataProvider (Morrowind, LaPalma, etc.)
##   └── Handles Terrain3D population and streaming
##
## Reference: Simplification-cascades refactoring - Phase 1
class_name WorldStreamingManager
extends Node3D

# Preload dependencies
const CS := preload("res://src/core/coordinate_system.gd")

## Emitted when a cell starts loading
signal cell_loading(grid: Vector2i)

## Emitted when a cell finishes loading
signal cell_loaded(grid: Vector2i, node: Node3D)

## Emitted when a cell is unloaded
signal cell_unloaded(grid: Vector2i)

#region Configuration

## View distance in cells (radius around camera)
@export var view_distance_cells: int = 3

## Whether to load objects (can disable for terrain-only view)
@export var load_objects: bool = true

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

## Time budget for cell loading per frame (ms)
## This is for submitting async requests, should be low as actual parsing is async
@export var cell_load_budget_ms: float = 2.0

## Maximum cells to queue for loading
@export var max_load_queue_size: int = 64

## Enable async/time-budgeted cell loading
@export var async_loading_enabled: bool = true

## Enable occlusion culling (don't render objects behind other objects)
## Significant performance boost in dense cities and interiors
@export var occlusion_culling_enabled: bool = true

#endregion

#region Node References

## Reference to OpenWorldDatabase node (created automatically)
var owdb: Node = null  # OpenWorldDatabase type

## Reference to OWDBPosition node (tracks streaming position)
var owdb_position: Node3D = null  # OWDBPosition type

## Reference to CellManager for loading cell data
var cell_manager: RefCounted = null  # CellManager

## Reference to BackgroundProcessor for async operations
var background_processor: Node = null  # BackgroundProcessor

## Static object renderer for fast flora rendering
var static_renderer: Node3D = null  # StaticObjectRenderer

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

## Whether the system is initialized
var _initialized: bool = false

## Priority queue for cells to load (sorted by distance to camera)
## Each entry: { "grid": Vector2i, "priority": float (lower = higher priority) }
var _load_queue: Array = []

## Performance stats
var _stats_load_time_ms: float = 0.0
var _stats_cells_loaded_this_frame: int = 0
var _stats_queue_high_water_mark: int = 0

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
	_setup_occlusion_culling()
	_initialized = true
	_debug("WorldStreamingManager initialized")


## Time budget for async object instantiation per frame (ms)
## This is the main bottleneck - Node3D.duplicate() is expensive
## Priority over terrain to show objects quickly
@export var instantiation_budget_ms: float = 3.0

func _process(_delta: float) -> void:
	if not _initialized:
		return

	if not _tracked_node:
		return

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
	for key in _loaded_cells.keys():
		coords.append(key)
	return coords


## Force reload all cells around current position
func refresh_cells() -> void:
	if _tracked_node:
		var cell := _get_cell_from_godot_position(_tracked_node.global_position)
		_on_camera_cell_changed(cell)


## Force load all visible cells synchronously (bypasses async queue)
## Use this when toggling objects on to ensure immediate loading
func force_load_visible_cells() -> void:
	if not _tracked_node or not cell_manager:
		return

	var camera_cell := _get_cell_from_godot_position(_tracked_node.global_position)
	var visible_cells := _get_visible_cells(camera_cell)

	_debug("Force loading %d visible cells around %s" % [visible_cells.size(), camera_cell])

	for cell_grid in visible_cells:
		if cell_grid not in _loaded_cells:
			# Remove from loading/queue state if present
			_loading_cells.erase(cell_grid)
			_load_queue = _load_queue.filter(func(entry): return entry.grid != cell_grid)

			# Load synchronously
			_load_cell_internal(cell_grid)


## Set the CellManager instance to use
func set_cell_manager(manager: RefCounted) -> void:
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
	}

	if owdb and owdb.has_method("get_currently_loaded_nodes"):
		stats["owdb_loaded_nodes"] = owdb.get_currently_loaded_nodes()
		stats["owdb_total_nodes"] = owdb.get_total_database_nodes()

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
	var owdb_class = load("res://addons/open-world-database/src/open_world_database.gd")
	if not owdb_class:
		push_warning("WorldStreamingManager: OWDB addon not found - object streaming disabled")
		return

	# Create OWDB node
	owdb = Node.new()
	owdb.set_script(owdb_class)
	owdb.name = "OpenWorldDatabase"

	# Configure OWDB for Morrowind object scales
	owdb.chunk_sizes = owdb_chunk_sizes
	owdb.chunk_load_range = owdb_chunk_load_range
	owdb.batch_time_limit_ms = owdb_batch_time_limit_ms
	owdb.batch_processing_enabled = true
	owdb.debug_enabled = debug_enabled

	add_child(owdb)
	_debug("OWDB created and configured")

	# Create OWDBPosition for tracking camera
	var position_class = load("res://addons/open-world-database/src/OWDBPosition.gd")
	if position_class:
		owdb_position = Node3D.new()
		owdb_position.set_script(position_class)
		owdb_position.name = "StreamingPosition"
		add_child(owdb_position)
		_debug("OWDBPosition created")


## Set up StaticObjectRenderer for fast flora rendering
func _setup_static_renderer() -> void:
	var renderer_class = load("res://src/core/world/static_object_renderer.gd")
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
		cell_manager.set_static_renderer(static_renderer)
		_debug("StaticObjectRenderer created and connected to CellManager")
	else:
		_debug("StaticObjectRenderer created (CellManager not available)")

#endregion


#region Cell Loading

## Called when camera moves to a different cell
func _on_camera_cell_changed(new_cell: Vector2i) -> void:
	_debug("Camera cell changed to: %s" % new_cell)

	var visible_cells := _get_visible_cells(new_cell)

	# Unload cells that are no longer visible
	var cells_to_unload: Array[Vector2i] = []
	for cell_grid: Vector2i in _loaded_cells.keys():
		if cell_grid not in visible_cells:
			cells_to_unload.append(cell_grid)

	for cell_grid in cells_to_unload:
		_unload_cell_internal(cell_grid)

	# Also remove from load queue if no longer needed
	_load_queue = _load_queue.filter(func(entry): return entry.grid in visible_cells)

	# Cancel async requests for cells no longer in view (prevents wasted work)
	var requests_to_cancel: Array[int] = []
	for request_id: int in _async_cell_requests:
		var grid: Vector2i = _async_cell_requests[request_id]
		if grid not in visible_cells:
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

	if cell_node and is_instance_valid(cell_node):
		# Release pooled objects back to the pool before freeing the cell
		# This dramatically improves performance by reusing Node3D instances
		if cell_manager:
			var pool = cell_manager.get_object_pool()
			if pool and pool.has_method("release_cell_objects"):
				var released: int = pool.release_cell_objects(cell_node)
				if released > 0:
					_debug("Released %d objects to pool from cell %s" % [released, grid])

		cell_node.queue_free()

	# Clean up static renderer instances (flora, small rocks rendered via RenderingServer)
	if cell_manager and cell_manager.has_method("cleanup_cell_static_instances"):
		var static_removed: int = cell_manager.cleanup_cell_static_instances(grid)
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
func _queue_cell_load(grid: Vector2i, camera_cell: Vector2i) -> void:
	# Check if already in queue
	for entry in _load_queue:
		if entry.grid == grid:
			return

	# Check queue size limit
	if _load_queue.size() >= max_load_queue_size:
		_debug("Load queue full, dropping cell: %s" % grid)
		return

	# Calculate base priority from distance (Manhattan distance)
	var dx := grid.x - camera_cell.x
	var dy := grid.y - camera_cell.y
	var distance := absf(dx) + absf(dy)
	var priority: float = distance  # Lower = higher priority

	# Apply frustum priority: cells in front of camera load first
	if frustum_priority_enabled and _tracked_node:
		var camera_forward := Vector3.FORWARD
		if _tracked_node is Camera3D:
			camera_forward = -(_tracked_node as Camera3D).global_transform.basis.z
		elif _tracked_node.has_method("get_camera_3d"):
			var cam: Camera3D = _tracked_node.get_camera_3d()
			if cam:
				camera_forward = -cam.global_transform.basis.z

		# Direction to cell (in XZ plane, Y is up in Godot)
		# Cell grid: +X is east, +Y is north in Morrowind
		# In Godot: +X is east, -Z is north (after coordinate conversion)
		var cell_dir := Vector3(dx, 0, -dy).normalized()
		var dot := camera_forward.dot(cell_dir)

		# dot = 1 means cell is directly in front, -1 means behind
		# Apply penalty of up to 3 priority levels for cells behind camera
		# This ensures cells in front load first even if slightly further
		priority -= dot * 2.0  # In front gets bonus (lower priority), behind gets penalty

	# Insert in sorted order (priority queue - lower = higher priority)
	var inserted := false
	for i in range(_load_queue.size()):
		if priority < _load_queue[i].priority:
			_load_queue.insert(i, { "grid": grid, "priority": priority })
			inserted = true
			break

	if not inserted:
		_load_queue.append({ "grid": grid, "priority": priority })

	# Track high water mark
	if _load_queue.size() > _stats_queue_high_water_mark:
		_stats_queue_high_water_mark = _load_queue.size()

	_loading_cells[grid] = true
	cell_loading.emit(grid)


## Process the load queue with time budgeting
## Called every frame to load cells without causing hitches
## Uses async loading when background processor is available
func _process_load_queue() -> void:
	if _load_queue.is_empty():
		return

	var start_time := Time.get_ticks_usec()
	var budget_usec := cell_load_budget_ms * 1000.0
	_stats_cells_loaded_this_frame = 0

	# Check if we can use async loading (background processor available)
	var use_async := background_processor != null and cell_manager != null

	while not _load_queue.is_empty():
		# Check time budget
		var elapsed := Time.get_ticks_usec() - start_time
		if elapsed >= budget_usec:
			break

		# Pop highest priority cell (front of queue)
		var entry: Dictionary = _load_queue.pop_front()
		var grid: Vector2i = entry.grid

		# Skip if already loaded (race condition prevention)
		if grid in _loaded_cells:
			_loading_cells.erase(grid)
			continue

		# Skip if already has pending async request
		if grid in _async_cell_requests.values():
			continue

		if use_async:
			# Submit async request - actual loading happens in background
			var request_id: int = cell_manager.request_exterior_cell_async(grid.x, grid.y)
			if request_id >= 0:
				_async_cell_requests[request_id] = grid

				# PROGRESSIVE LOADING: Add cell node to scene immediately
				# Objects will appear as they're instantiated by process_async_instantiation
				var cell_node: Node3D = cell_manager.get_async_cell_node(request_id)
				if cell_node and not cell_node.is_inside_tree():
					add_child(cell_node)
					cell_node.set_meta("cell_grid", grid)
					_loaded_cells[grid] = cell_node
					_debug("Async cell added early for progressive loading: %s (id=%d)" % [grid, request_id])
			else:
				# Fallback to sync if async not available (e.g., cell not found)
				_loading_cells.erase(grid)
				_debug("Cell %s has no data (async returned -1)" % grid)
		else:
			# Fallback to sync loading (no background processor)
			var cell_node: Node3D = cell_manager.load_exterior_cell(grid.x, grid.y)
			_loading_cells.erase(grid)

			if cell_node:
				add_child(cell_node)
				cell_node.set_meta("cell_grid", grid)

				_loaded_cells[grid] = cell_node
				cell_loaded.emit(grid, cell_node)
				_stats_cells_loaded_this_frame += 1
				_debug("Cell loaded (sync): %s with %d children" % [grid, cell_node.get_child_count()])
			else:
				_debug("Cell %s has no data (ocean/empty)" % grid)

	# Update timing stats
	_stats_load_time_ms = (Time.get_ticks_usec() - start_time) / 1000.0


## Poll for completed async cell requests and integrate them
func _poll_async_completions() -> void:
	if _async_cell_requests.is_empty() or not cell_manager:
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


## Clear the load queue (e.g., when teleporting)
func clear_load_queue() -> void:
	for entry in _load_queue:
		_loading_cells.erase(entry.grid)
	_load_queue.clear()

	# Cancel pending async requests
	if cell_manager:
		for request_id in _async_cell_requests:
			cell_manager.cancel_async_request(request_id)
	_async_cell_requests.clear()

	_debug("Load queue cleared")

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

#endregion
