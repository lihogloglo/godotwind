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
## Lines of code: ~300 (vs ~2,235 in old WorldStreamingManager)
class_name NativeStreamingManager
extends Node3D

const DU := preload("res://src/core/world/distance_utils.gd")
const LODConfigurator := preload("res://src/core/world/lod_configurator.gd")
const CellManagerScript := preload("res://src/core/world/cell_manager.gd")
const ModelLoaderScript := preload("res://src/core/world/model_loader.gd")
const NativeImpostorRendererScript := preload("res://src/core/world/native_impostor_renderer.gd")
const ImpostorCandidatesScript := preload("res://src/core/world/impostor_candidates.gd")
const MeshVisibilityUtils := preload("res://src/core/world/mesh_visibility_utils.gd")
const CS := preload("res://src/core/coordinate_system.gd")

#region Signals

## Emitted when a cell starts loading
signal cell_loading(grid: Vector2i)

## Emitted when a cell finishes loading
signal cell_loaded(grid: Vector2i, object_count: int)

## Emitted when a cell is unloaded
signal cell_unloaded(grid: Vector2i)

## Emitted when streaming stats are updated
signal stats_updated(stats: Dictionary)

#endregion


#region Configuration

## Radius (in cells) to keep loaded around camera
@export var load_radius_cells: int = 3

## Maximum distance at which to load cells (in meters)
## Cells beyond this are never loaded, even if within radius
@export var max_load_distance: float = 600.0

## Whether to use native visibility_range (should always be true)
@export var use_native_visibility: bool = true

## Enable debug logging
@export var debug_enabled: bool = false

## Time budget per frame for loading (ms)
@export var frame_budget_ms: float = 8.0

## Radius for impostors (cells) - radius around camera where impostors are generated
## 40 cells * 117m ~= 4680m (4.6km)
@export var impostor_radius_cells: int = 40

## Enable/disable object loading (backwards compatibility)
## Setting this to false will hide all loaded objects
@export var load_objects: bool = true:
	set(value):
		load_objects = value
		_update_objects_visibility()

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

## Native Impostor Renderer
var _impostor_renderer: Node3D = null

## Impostor candidates manager
var _impostor_candidates: RefCounted = null

## Loaded cells: grid -> Node3D container
var _loaded_cells: Dictionary = {}

## Cells currently being loaded (async)
var _loading_cells: Dictionary = {}

## Pending cells to load (priority queue, sorted by distance)
var _pending_load_queue: Array[Vector2i] = []

## Container node for all cell content
var _world_container: Node3D = null

## Cell manager for loading cells
var _cell_manager: CellManagerScript = null

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
}

## Whether the manager has been initialized
var _initialized: bool = false

#endregion


#region Initialization

func _ready() -> void:
	# Create world container
	_world_container = Node3D.new()
	_world_container.name = "WorldContainer"
	add_child(_world_container)

	# Create impostor renderer (renamed to match old API)
	_impostor_renderer = NativeImpostorRendererScript.new()
	_impostor_renderer.name = "ImpostorManager"  # Use old name for backwards compatibility
	add_child(_impostor_renderer)

	# Create impostor candidates helper
	_impostor_candidates = ImpostorCandidatesScript.new()
	_impostor_renderer.set_impostor_candidates(_impostor_candidates)


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
	_camera = camera
	
	# Find camera if not provided
	if not _camera:
		_camera = get_viewport().get_camera_3d()
	
	# Sync debug flag
	if _impostor_renderer:
		_impostor_renderer.set("debug_enabled", debug_enabled)

	_initialized = true
	_debug("Initialized with native visibility_range streaming")
	
	return OK


## Set the camera to track
func set_camera(camera: Camera3D) -> void:
	_camera = camera


## Set cell manager
func set_cell_manager(cell_manager: CellManagerScript) -> void:
	_cell_manager = cell_manager

#endregion


#region Main Update Loop

func _process(delta: float) -> void:
	if not _initialized:
		return
	
	if not _camera:
		_camera = get_viewport().get_camera_3d()
		if not _camera:
			return
	
	# Update camera position
	_camera_position = _camera.global_position
	var new_cell := DU.world_to_cell(_camera_position)
	
	# Check if we moved to a new cell
	if new_cell != _camera_cell:
		_camera_cell = new_cell
		_update_loaded_cells()
	
	# Process any pending async loads
	_process_pending_loads(delta)


## Update which cells should be loaded based on camera position
func _update_loaded_cells() -> void:
	# Calculate which cells should be loaded
	var cells_to_load := _get_cells_in_radius(_camera_cell, load_radius_cells)

	# Unload cells that are too far
	var cells_to_unload: Array[Vector2i] = []
	for grid: Vector2i in _loaded_cells:
		if grid not in cells_to_load:
			cells_to_unload.append(grid)

	if debug_enabled and not cells_to_unload.is_empty():
		_debug("Unloading %d cells" % cells_to_unload.size())

	for grid: Vector2i in cells_to_unload:
		_unload_cell(grid)

	# Queue new cells for loading (sorted by distance)
	_pending_load_queue.clear()
	for grid: Vector2i in cells_to_load:
		if grid not in _loaded_cells and grid not in _loading_cells:
			_pending_load_queue.append(grid)

	if debug_enabled and not _pending_load_queue.is_empty():
		_debug("Queueing %d cells for loading (camera at cell %s)" % [_pending_load_queue.size(), _camera_cell])

	# Sort by distance (closest first)
	_pending_load_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return DU.cell_distance_squared(_camera_cell, a) < DU.cell_distance_squared(_camera_cell, b)
	)

	# Update impostors
	if _impostor_renderer:
		_impostor_renderer.update_impostor_area(_camera_cell, impostor_radius_cells)


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

## Load a cell at the given grid position
func _load_cell(grid: Vector2i) -> void:
	if grid in _loaded_cells or grid in _loading_cells:
		return
	
	cell_loading.emit(grid)
	
	# Mark as loading
	_loading_cells[grid] = true
	
	# Load cell synchronously (could be made async later)
	var cell_node := _cell_manager.load_exterior_cell(grid.x, grid.y)
	
	if cell_node:
		# Configure visibility_range on all meshes
		_configure_cell_visibility(cell_node)
		
		# Add to scene
		_world_container.add_child(cell_node)
		_loaded_cells[grid] = cell_node
		
		var object_count := _count_mesh_instances(cell_node)
		_stats["loaded_cells"] = _loaded_cells.size()
		_stats["total_objects"] += object_count
		
		cell_loaded.emit(grid, object_count)
		_debug("Loaded cell %s with %d objects" % [grid, object_count])
	else:
		_debug("Failed to load cell %s" % [grid])
	
	_loading_cells.erase(grid)
	stats_updated.emit(_stats)


## Unload a cell at the given grid position
func _unload_cell(grid: Vector2i) -> void:
	if grid not in _loaded_cells:
		return
	
	var cell_node: Node3D = _loaded_cells[grid]
	var object_count := _count_mesh_instances(cell_node)
	
	# Remove from scene
	cell_node.queue_free()
	_loaded_cells.erase(grid)
	
	_stats["loaded_cells"] = _loaded_cells.size()
	_stats["total_objects"] -= object_count
	
	cell_unloaded.emit(grid)
	stats_updated.emit(_stats)


## Configure visibility_range on all MeshInstance3D nodes in a cell
func _configure_cell_visibility(cell_node: Node3D) -> void:
	if not use_native_visibility:
		return
	
	_configure_node_visibility_recursive(cell_node)


## Recursively configure visibility_range on a node and its children
func _configure_node_visibility_recursive(node: Node) -> void:
	if node is GeometryInstance3D:
		var geo := node as GeometryInstance3D
		var node_name := node.name

		# Determine appropriate visibility based on node name/type
		if MeshVisibilityUtils.is_lod_node_name(node_name):
			# LOD nodes get their specific range based on their level
			var lod_level := _get_lod_level(node_name)
			_lod_configurator.configure_mid_object(geo, lod_level)
			if debug_enabled:
				_debug("Configured LOD%d: %s (range: %s)" % [lod_level, node_name, _get_lod_range_str(lod_level)])
		else:
			# Default: NEAR tier visibility (0-150m)
			_lod_configurator.configure_near_object(geo)
			if debug_enabled and node is MeshInstance3D:
				_debug("Configured NEAR: %s (0-150m)" % node_name)

	# Recurse to children
	for child in node.get_children():
		_configure_node_visibility_recursive(child)


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


## Process pending cell loads with frame budget limiting
## Loads cells from the pending queue respecting the frame_budget_ms limit
func _process_pending_loads(_delta: float) -> void:
	if _pending_load_queue.is_empty():
		return

	var start_time := Time.get_ticks_msec()
	var cells_loaded_this_frame := 0

	# Process cells from the queue until we hit the frame budget
	while not _pending_load_queue.is_empty():
		var grid := _pending_load_queue[0]
		_pending_load_queue.remove_at(0)

		# Skip if already loaded or loading
		if grid in _loaded_cells or grid in _loading_cells:
			continue

		# Load the cell
		_load_cell(grid)
		cells_loaded_this_frame += 1

		# Check frame budget
		var elapsed := Time.get_ticks_msec() - start_time
		_stats["load_time_ms"] = elapsed

		if elapsed >= frame_budget_ms:
			# Budget exceeded - continue next frame
			if debug_enabled or _pending_load_queue.size() > 5:
				_debug("Frame budget exceeded (%.1fms), loaded %d cells, %d remaining" % [elapsed, cells_loaded_this_frame, _pending_load_queue.size()])
			break

	# Log if we loaded cells without hitting budget
	if debug_enabled and cells_loaded_this_frame > 0 and _pending_load_queue.is_empty():
		var elapsed := Time.get_ticks_msec() - start_time
		_debug("Loaded %d cells in %.1fms (under budget)" % [cells_loaded_this_frame, elapsed])

#endregion


#region Public API

## Get current streaming statistics
func get_stats() -> Dictionary:
	var s := _stats.duplicate()

	# Add load queue stats
	s["load_queue_size"] = _pending_load_queue.size()
	s["camera_cell"] = _camera_cell

	# Merge impostor stats if available
	if _impostor_renderer and _impostor_renderer.has_method("get_stats"):
		s.merge(_impostor_renderer.call("get_stats"))

	return s


## Force reload all cells (after configuration change)
func reload_all_cells() -> void:
	# Unload all current cells
	for grid: Vector2i in _loaded_cells.keys():
		_unload_cell(grid)
	
	# Trigger reload
	_update_loaded_cells()


## Get loaded cell at grid position (overload for backwards compatibility)
func get_loaded_cell(x, y = null) -> Node3D:
	if y == null:
		# Called with Vector2i
		return _loaded_cells.get(x, null)
	else:
		# Called with x, y integers
		var grid := Vector2i(x, y)
		return _loaded_cells.get(grid, null)


## Check if a cell is loaded
func is_cell_loaded(grid: Vector2i) -> bool:
	return grid in _loaded_cells


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


## Update objects visibility based on load_objects flag
func _update_objects_visibility() -> void:
	if _world_container:
		_world_container.visible = load_objects

#endregion


#region Debug

func _debug(msg: String) -> void:
	if debug_enabled:
		print("[NativeStreamingManager] %s" % msg)

#endregion
