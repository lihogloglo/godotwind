## WorldStreamingManager - Unified world streaming coordinator
## Coordinates terrain (Terrain3D) and object (OWDB) streaming together
##
## This is the central controller for world content loading in Godotwind.
## It provides a single point of control for both terrain and cell objects,
## ensuring they load/unload together based on camera position.
##
## Architecture:
##   WorldStreamingManager
##   ├── Terrain3D (handles terrain LOD/streaming natively)
##   ├── OpenWorldDatabase (handles object streaming via OWDB addon)
##   │   └── [Cell nodes parented here for automatic streaming]
##   └── OWDBPosition (tracks camera position for streaming)
##
## Reference: ARCHITECTURE_SIMPLIFICATION_AUDIT.md Phase 2-3
class_name WorldStreamingManager
extends Node3D

# Preload dependencies
const CS := preload("res://src/core/coordinate_system.gd")
const ObjectLODManagerScript := preload("res://src/core/world/object_lod_manager.gd")

## Emitted when a cell starts loading
signal cell_loading(grid: Vector2i)

## Emitted when a cell finishes loading
signal cell_loaded(grid: Vector2i, node: Node3D)

## Emitted when a cell is unloaded
signal cell_unloaded(grid: Vector2i)

## Emitted when terrain region is loaded
signal terrain_region_loaded(region: Vector2i)

#region Configuration

## View distance in cells (radius around camera)
@export var view_distance_cells: int = 3

## Whether to load objects (can disable for terrain-only view)
@export var load_objects: bool = true

## Whether to load terrain
@export var load_terrain: bool = true

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
## Higher = faster loading but more frame hitches
@export var cell_load_budget_ms: float = 8.0

## Maximum cells to queue for loading
@export var max_load_queue_size: int = 16

## Enable async/time-budgeted cell loading
@export var async_loading_enabled: bool = true

## Enable object LOD for distance-based detail levels
@export var object_lod_enabled: bool = true

## LOD distance thresholds (meters)
@export var lod_full_distance: float = 50.0
@export var lod_low_distance: float = 150.0
@export var lod_cull_distance: float = 500.0

#endregion

#region Node References

## Reference to Terrain3D node (optional - can work without terrain)
var terrain_3d: Node = null  # Terrain3D type

## Reference to OpenWorldDatabase node (created automatically)
var owdb: Node = null  # OpenWorldDatabase type

## Reference to OWDBPosition node (tracks streaming position)
var owdb_position: Node3D = null  # OWDBPosition type

## Reference to CellManager for loading cell data
var cell_manager: RefCounted = null  # CellManager

## Reference to TerrainManager for terrain data
var terrain_manager: RefCounted = null  # TerrainManager

## LOD manager for distance-based detail levels
var _lod_manager: Node = null  # ObjectLODManager

#endregion

#region State

## Currently tracked camera/player node
var _tracked_node: Node3D = null

## Currently loaded exterior cells: Vector2i -> Node3D
var _loaded_cells: Dictionary = {}

## Cells currently being loaded (async)
var _loading_cells: Dictionary = {}

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
	_find_terrain3d()
	_debug("WorldStreamingManager ready - call initialize() to start streaming")


## Initialize the streaming system after configuration
## Must be called after setting cell_manager and other properties
func initialize() -> void:
	if _initialized:
		return
	_setup_owdb()
	_setup_lod_manager()
	_initialized = true
	_debug("WorldStreamingManager initialized")


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

	# Process load queue with time budget
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

	# Update LOD manager camera reference
	if _lod_manager and node:
		# If tracked node is a Camera3D, use it directly
		# Otherwise try to find a camera in the viewport
		var cam: Camera3D = null
		if node is Camera3D:
			cam = node
		elif node.get_viewport():
			cam = node.get_viewport().get_camera_3d()
		if cam:
			_lod_manager.set_camera(cam)

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


## Set the CellManager instance to use
func set_cell_manager(manager: RefCounted) -> void:
	cell_manager = manager
	_debug("CellManager set")


## Set the TerrainManager instance to use
func set_terrain_manager(manager: RefCounted) -> void:
	terrain_manager = manager
	_debug("TerrainManager set")


## Set the Terrain3D node reference
func set_terrain_3d(terrain: Node) -> void:
	terrain_3d = terrain
	_debug("Terrain3D set: %s" % terrain.name if terrain else "null")


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
	}

	if owdb and owdb.has_method("get_currently_loaded_nodes"):
		stats["owdb_loaded_nodes"] = owdb.get_currently_loaded_nodes()
		stats["owdb_total_nodes"] = owdb.get_total_database_nodes()

	# Add LOD stats
	if _lod_manager and _lod_manager.has_method("get_stats"):
		var lod_stats: Dictionary = _lod_manager.get_stats()
		stats["lod_objects_full"] = lod_stats.get("objects_full", 0)
		stats["lod_objects_low"] = lod_stats.get("objects_low", 0)
		stats["lod_objects_billboard"] = lod_stats.get("objects_billboard", 0)
		stats["lod_objects_culled"] = lod_stats.get("objects_culled", 0)
		stats["lod_total_tracked"] = lod_stats.get("objects_tracked", 0)

	return stats

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


## Find Terrain3D in the scene tree
func _find_terrain3d() -> void:
	# Look for Terrain3D as a sibling or child
	var parent := get_parent()
	if parent:
		for child in parent.get_children():
			if child.get_class() == "Terrain3D" or child.name == "Terrain3D":
				terrain_3d = child
				_debug("Found Terrain3D: %s" % child.name)
				return

	# Also check children
	for child in get_children():
		if child.get_class() == "Terrain3D" or child.name == "Terrain3D":
			terrain_3d = child
			_debug("Found Terrain3D (child): %s" % child.name)
			return

## Set up LOD manager for object distance-based detail levels
func _setup_lod_manager() -> void:
	if not object_lod_enabled:
		return

	_lod_manager = Node3D.new()
	_lod_manager.set_script(ObjectLODManagerScript)
	_lod_manager.name = "ObjectLODManager"

	# Configure LOD distances
	_lod_manager.lod_full_distance = lod_full_distance
	_lod_manager.lod_low_distance = lod_low_distance
	_lod_manager.lod_cull_distance = lod_cull_distance

	add_child(_lod_manager)
	_debug("LOD manager created (full=%dm, low=%dm, cull=%dm)" % [
		int(lod_full_distance), int(lod_low_distance), int(lod_cull_distance)
	])

#endregion


#region Cell Loading

## Called when camera moves to a different cell
func _on_camera_cell_changed(new_cell: Vector2i) -> void:
	_debug("Camera cell changed to: %s" % new_cell)

	var visible_cells := _get_visible_cells(new_cell)

	# Load terrain for visible cells (either from pre-processed data or generate on-the-fly)
	if load_terrain:
		_load_terrain_for_cells(visible_cells)

	# Unload cells that are no longer visible
	var cells_to_unload: Array[Vector2i] = []
	for cell_grid: Vector2i in _loaded_cells.keys():
		if cell_grid not in visible_cells:
			cells_to_unload.append(cell_grid)

	for cell_grid in cells_to_unload:
		_unload_cell_internal(cell_grid)

	# Also remove from load queue if no longer needed
	_load_queue = _load_queue.filter(func(entry): return entry.grid in visible_cells)

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

	# Register objects with LOD manager for distance-based detail
	if _lod_manager and object_lod_enabled:
		_lod_manager.register_cell_objects(cell_node)

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

		# Unregister from LOD manager before freeing
		if _lod_manager and _lod_manager.has_method("unregister_cell_objects"):
			_lod_manager.unregister_cell_objects(cell_node)

		cell_node.queue_free()

	cell_unloaded.emit(grid)
	_debug("Cell unloaded: %s" % grid)

#endregion


#region Async Loading Queue

## Add a cell to the priority load queue
## Cells closer to the camera have higher priority (lower priority value)
func _queue_cell_load(grid: Vector2i, camera_cell: Vector2i) -> void:
	# Check if already in queue
	for entry in _load_queue:
		if entry.grid == grid:
			return

	# Check queue size limit
	if _load_queue.size() >= max_load_queue_size:
		_debug("Load queue full, dropping cell: %s" % grid)
		return

	# Calculate priority based on distance to camera (Manhattan distance)
	var dx := absi(grid.x - camera_cell.x)
	var dy := absi(grid.y - camera_cell.y)
	var priority := dx + dy  # Lower = higher priority

	# Insert in sorted order (priority queue)
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
func _process_load_queue() -> void:
	if _load_queue.is_empty():
		return

	var start_time := Time.get_ticks_usec()
	var budget_usec := cell_load_budget_ms * 1000.0
	_stats_cells_loaded_this_frame = 0

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

		# Actually load the cell
		var cell_node: Node3D = cell_manager.load_exterior_cell(grid.x, grid.y)
		_loading_cells.erase(grid)

		if cell_node:
			add_child(cell_node)
			cell_node.set_meta("cell_grid", grid)

			# Register objects with LOD manager for distance-based detail
			if _lod_manager and object_lod_enabled:
				_lod_manager.register_cell_objects(cell_node)

			_loaded_cells[grid] = cell_node
			cell_loaded.emit(grid, cell_node)
			_stats_cells_loaded_this_frame += 1
			_debug("Cell loaded (queued): %s with %d children" % [grid, cell_node.get_child_count()])
		else:
			_debug("Cell %s has no data (ocean/empty)" % grid)

	# Update timing stats
	_stats_load_time_ms = (Time.get_ticks_usec() - start_time) / 1000.0


## Clear the load queue (e.g., when teleporting)
func clear_load_queue() -> void:
	for entry in _load_queue:
		_loading_cells.erase(entry.grid)
	_load_queue.clear()
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


#region Terrain Integration

## Whether to generate terrain on-the-fly if no preprocessed data exists
@export var generate_terrain_on_fly: bool = true

## Track which cells have had terrain generated
var _terrain_generated_cells: Dictionary = {}

## Load terrain regions for visible cells
## Called automatically when terrain_manager is set and load_terrain is true
func _load_terrain_for_cells(cells: Array[Vector2i]) -> void:
	if not terrain_manager or not terrain_3d or not load_terrain:
		return

	if not generate_terrain_on_fly:
		return

	# Generate terrain on-the-fly for cells that don't have pre-processed data
	for cell_grid in cells:
		if cell_grid in _terrain_generated_cells:
			continue

		# Check if terrain region already exists at this cell location
		if _terrain_region_exists(cell_grid):
			_terrain_generated_cells[cell_grid] = true
			continue

		# Generate terrain for this cell
		_generate_terrain_cell(cell_grid)


## Check if a terrain region exists for the given cell
func _terrain_region_exists(cell_grid: Vector2i) -> bool:
	if not terrain_3d or not terrain_3d.data:
		return false

	# Calculate world position for this cell
	var region_world_size: float = 64.0 * float(terrain_3d.get_vertex_spacing())
	var world_x: float = float(cell_grid.x) * region_world_size + region_world_size * 0.5
	var world_z: float = float(-cell_grid.y) * region_world_size - region_world_size * 0.5

	# Check if a region exists at this position
	var pos := Vector3(world_x, 0, world_z)
	return terrain_3d.data.has_region(pos)


## Generate terrain for a single cell on-the-fly
func _generate_terrain_cell(cell_grid: Vector2i) -> bool:
	if not terrain_manager or not terrain_3d:
		return false

	# Get LAND record for this cell
	var land: LandRecord = ESMManager.get_land(cell_grid.x, cell_grid.y)
	if not land or not land.has_heights():
		_terrain_generated_cells[cell_grid] = true  # Mark as processed (even if no data)
		return false

	# Use the unified import method from TerrainManager
	var success: bool = terrain_manager.import_cell_to_terrain(terrain_3d, land)
	if success:
		_terrain_generated_cells[cell_grid] = true
		terrain_region_loaded.emit(cell_grid)
		_debug("Generated terrain for cell: %s" % cell_grid)

	return success


## Clear terrain generation cache (e.g., when switching areas)
func clear_terrain_cache() -> void:
	_terrain_generated_cells.clear()
	_debug("Terrain generation cache cleared")

#endregion


#region Debug

func _debug(msg: String) -> void:
	if debug_enabled:
		print("WorldStreamingManager: %s" % msg)

#endregion
