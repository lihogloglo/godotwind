## DistantStaticRenderer - RenderingServer-based renderer for merged distant meshes
##
## Manages merged static meshes for MID tier rendering (500m-2km).
## Uses RenderingServer directly for maximum performance.
##
## Key features:
## - Renders merged cell meshes with minimal draw calls
## - Uses RenderingServer RIDs for efficiency (no Node3D overhead)
## - Manages visibility based on camera distance
## - Supports LOD transitions with cross-fade
##
## Usage:
##   var renderer := DistantStaticRenderer.new()
##   add_child(renderer)
##   renderer.set_mesh_merger(merger)
##   renderer.add_cell(grid, cell_references)
##   renderer.remove_cell(grid)
class_name DistantStaticRenderer
extends Node3D

# Preload dependencies
const StaticMeshMergerScript := preload("res://src/core/world/static_mesh_merger.gd")

## Reference to StaticMeshMerger for creating merged meshes
var mesh_merger: RefCounted = null  # StaticMeshMerger

## Reference to CellManager for loading cell data
var cell_manager: RefCounted = null  # CellManager

## World scenario RID (set when entering tree)
var _scenario: RID = RID()

## Loaded cells: Vector2i -> CellInstance
var _cells: Dictionary = {}

## Stats
var _stats := {
	"loaded_cells": 0,
	"total_vertices": 0,
	"total_objects": 0,
	"visible_cells": 0,
}


## Cell instance data
class CellInstance:
	var grid: Vector2i
	var instance_rid: RID      ## RenderingServer instance
	var mesh_rid: RID          ## RenderingServer mesh
	var material_rid: RID      ## RenderingServer material
	var aabb: AABB
	var vertex_count: int
	var object_count: int
	var visible: bool = true
	var owns_mesh: bool = true  ## Whether we created the mesh RID


func _enter_tree() -> void:
	_scenario = get_viewport().get_world_3d().scenario


func _exit_tree() -> void:
	# Clean up all RenderingServer resources
	clear()


## Set the mesh merger to use
func set_mesh_merger(merger: RefCounted) -> void:
	mesh_merger = merger


## Set the cell manager for loading cell data
func set_cell_manager(manager: RefCounted) -> void:
	cell_manager = manager


## Add a cell from a pre-baked merged mesh (fast path)
## This is the preferred method - uses pre-generated meshes from mesh_prebaker.gd
## cell_grid: The cell grid coordinates
## mesh: Pre-baked ArrayMesh from res://assets/merged_cells/
## Returns true if cell was successfully added
func add_cell_prebaked(cell_grid: Vector2i, mesh: ArrayMesh) -> bool:
	# Skip if already loaded
	if cell_grid in _cells:
		return true

	if not _scenario.is_valid():
		push_warning("DistantStaticRenderer: Not in scene tree, cannot add cells")
		return false

	if not mesh:
		return false

	# Create RenderingServer resources
	var cell_instance := CellInstance.new()
	cell_instance.grid = cell_grid
	cell_instance.mesh_rid = mesh.get_rid()
	cell_instance.owns_mesh = false  # Mesh is owned by resource

	# Create instance
	cell_instance.instance_rid = RenderingServer.instance_create()
	RenderingServer.instance_set_base(cell_instance.instance_rid, cell_instance.mesh_rid)
	RenderingServer.instance_set_scenario(cell_instance.instance_rid, _scenario)

	# Get mesh info for stats
	cell_instance.aabb = mesh.get_aabb() if mesh.get_surface_count() > 0 else AABB()
	cell_instance.vertex_count = 0
	cell_instance.object_count = 1
	for i in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(i)
		if arrays.size() > 0 and arrays[Mesh.ARRAY_VERTEX]:
			cell_instance.vertex_count += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	cell_instance.visible = true

	# Store cell
	_cells[cell_grid] = cell_instance

	# Update stats
	_stats["loaded_cells"] += 1
	_stats["total_vertices"] += cell_instance.vertex_count
	_stats["total_objects"] += cell_instance.object_count
	_stats["visible_cells"] += 1

	return true


## Add a cell with merged distant geometry (runtime merging - SLOW)
## WARNING: Runtime merging takes 50-100ms per cell. Use add_cell_prebaked instead.
## cell_grid: The cell grid coordinates
## references: Array of CellReference objects in this cell
## Returns true if cell was successfully added
func add_cell(cell_grid: Vector2i, references: Array = []) -> bool:
	# Skip if already loaded
	if cell_grid in _cells:
		return true

	if not _scenario.is_valid():
		push_warning("DistantStaticRenderer: Not in scene tree, cannot add cells")
		return false

	# Get references if not provided
	if references.is_empty() and cell_manager:
		var cell_record = ESMManager.get_exterior_cell(cell_grid.x, cell_grid.y)
		if cell_record:
			references = cell_record.references

	if references.is_empty():
		# No references - cell is empty or ocean
		return false

	# Create merged mesh
	if not mesh_merger:
		push_warning("DistantStaticRenderer: No mesh merger set")
		return false

	var merged_data = mesh_merger.merge_cell(cell_grid, references)
	if not merged_data:
		# No mergeable objects in this cell
		return false

	# Create RenderingServer resources
	var cell_instance := CellInstance.new()
	cell_instance.grid = cell_grid

	# Get mesh RID from ArrayMesh
	var mesh: ArrayMesh = merged_data.mesh
	if not mesh:
		return false

	cell_instance.mesh_rid = mesh.get_rid()
	cell_instance.owns_mesh = false  # Mesh is owned by ArrayMesh resource

	# Create instance
	cell_instance.instance_rid = RenderingServer.instance_create()
	RenderingServer.instance_set_base(cell_instance.instance_rid, cell_instance.mesh_rid)
	RenderingServer.instance_set_scenario(cell_instance.instance_rid, _scenario)

	# Apply material if available
	if merged_data.material:
		cell_instance.material_rid = merged_data.material.get_rid()
		RenderingServer.instance_geometry_set_material_override(
			cell_instance.instance_rid, cell_instance.material_rid
		)

	# Store metadata
	cell_instance.aabb = merged_data.aabb
	cell_instance.vertex_count = merged_data.vertex_count
	cell_instance.object_count = merged_data.object_count
	cell_instance.visible = true

	# Store cell
	_cells[cell_grid] = cell_instance

	# Update stats
	_stats["loaded_cells"] += 1
	_stats["total_vertices"] += cell_instance.vertex_count
	_stats["total_objects"] += cell_instance.object_count
	_stats["visible_cells"] += 1

	return true


## Remove a cell's distant representation
func remove_cell(cell_grid: Vector2i) -> void:
	if cell_grid not in _cells:
		return

	var cell_instance: CellInstance = _cells[cell_grid]

	# Free RenderingServer resources
	if cell_instance.instance_rid.is_valid():
		RenderingServer.free_rid(cell_instance.instance_rid)

	# Only free mesh if we own it
	if cell_instance.owns_mesh and cell_instance.mesh_rid.is_valid():
		RenderingServer.free_rid(cell_instance.mesh_rid)

	# Update stats
	_stats["loaded_cells"] -= 1
	_stats["total_vertices"] -= cell_instance.vertex_count
	_stats["total_objects"] -= cell_instance.object_count
	if cell_instance.visible:
		_stats["visible_cells"] -= 1

	_cells.erase(cell_grid)

	# Also remove from merger cache
	if mesh_merger:
		mesh_merger.remove_from_cache(cell_grid)


## Set cell visibility
func set_cell_visible(cell_grid: Vector2i, visible: bool) -> void:
	if cell_grid not in _cells:
		return

	var cell_instance: CellInstance = _cells[cell_grid]
	if cell_instance.visible == visible:
		return

	cell_instance.visible = visible
	RenderingServer.instance_set_visible(cell_instance.instance_rid, visible)

	if visible:
		_stats["visible_cells"] += 1
	else:
		_stats["visible_cells"] -= 1


## Update visibility for all cells based on camera position
## max_distance: Maximum distance for MID tier visibility
## Returns number of visibility changes made
func update_visibility(camera_pos: Vector3, max_distance: float) -> int:
	var changes := 0
	var max_dist_sq := max_distance * max_distance

	for grid in _cells:
		var cell_instance: CellInstance = _cells[grid]

		# Calculate distance to cell center
		var cell_center := cell_instance.aabb.get_center()
		var dist_sq := camera_pos.distance_squared_to(cell_center)

		var should_be_visible := dist_sq <= max_dist_sq

		if cell_instance.visible != should_be_visible:
			set_cell_visible(grid, should_be_visible)
			changes += 1

	return changes


## Check if a cell is loaded
func has_cell(cell_grid: Vector2i) -> bool:
	return cell_grid in _cells


## Get loaded cell count
func get_cell_count() -> int:
	return _cells.size()


## Clear all cells
func clear() -> void:
	for grid in _cells.keys():
		remove_cell(grid)

	_cells.clear()

	_stats["loaded_cells"] = 0
	_stats["total_vertices"] = 0
	_stats["total_objects"] = 0
	_stats["visible_cells"] = 0


## Get statistics
func get_stats() -> Dictionary:
	return _stats.duplicate()


## Get all loaded cell coordinates
func get_loaded_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for grid in _cells.keys():
		cells.append(grid)
	return cells


## Get cell info
func get_cell_info(cell_grid: Vector2i) -> Dictionary:
	if cell_grid not in _cells:
		return {}

	var cell_instance: CellInstance = _cells[cell_grid]
	return {
		"grid": cell_instance.grid,
		"vertex_count": cell_instance.vertex_count,
		"object_count": cell_instance.object_count,
		"aabb": cell_instance.aabb,
		"visible": cell_instance.visible,
	}
