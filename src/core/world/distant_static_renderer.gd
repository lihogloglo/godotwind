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
var mesh_merger: StaticMeshMerger = null

## Reference to CellManager for loading cell data
var cell_manager: CellManager = null

## World scenario RID (set when entering tree)
var _scenario: RID = RID()

## Default material for distant meshes (simple gray for visibility)
var _default_material: StandardMaterial3D = null

## Loaded cells: Vector2i -> CellInstance
var _cells: Dictionary[Vector2i, CellInstance] = {}

## Stats
var _stats: Dictionary[String, int] = {
	"loaded_cells": 0,
	"total_vertices": 0,
	"total_objects": 0,
	"visible_cells": 0,
}

## Track first cell load for one-time diagnostic
var _first_cell_logged: bool = false


## Cell instance data
class CellInstance:
	var grid: Vector2i
	var instance_rid: RID      ## RenderingServer instance
	var mesh_rid: RID          ## RenderingServer mesh
	var material_rid: RID      ## RenderingServer material
	var mesh_ref: ArrayMesh    ## Keep reference to prevent GC invalidating mesh_rid
	var aabb: AABB
	var vertex_count: int
	var object_count: int
	var visible: bool = true
	var owns_mesh: bool = true  ## Whether we created the mesh RID


func _enter_tree() -> void:
	var world_3d := get_viewport().get_world_3d()
	if world_3d:
		_scenario = world_3d.scenario
	else:
		push_error("[DistantStaticRenderer] No World3D available in viewport!")
	_create_default_material()


func _exit_tree() -> void:
	# Clean up all RenderingServer resources
	clear()


## Create default material for distant meshes
func _create_default_material() -> void:
	if _default_material:
		return
	_default_material = StandardMaterial3D.new()
	# Neutral gray base - vertex colors will override if present
	_default_material.albedo_color = Color(0.6, 0.6, 0.6)
	_default_material.roughness = 0.9
	_default_material.metallic = 0.0
	# Per-vertex shading for performance at distance
	_default_material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	# Use vertex colors if available (baked from original materials)
	_default_material.vertex_color_use_as_albedo = true
	# Normal backface culling
	_default_material.cull_mode = BaseMaterial3D.CULL_BACK


## Set the mesh merger to use
func set_mesh_merger(merger: StaticMeshMerger) -> void:
	mesh_merger = merger


## Set the cell manager for loading cell data
func set_cell_manager(manager: CellManager) -> void:
	cell_manager = manager


## Add a cell from a pre-baked merged mesh (fast path)
## This is the preferred method - uses pre-generated meshes from mesh_prebaker.gd
## cell_grid: The cell grid coordinates
## mesh: Pre-baked ArrayMesh from {cache}/merged_cells/
## Returns true if cell was successfully added
func add_cell_prebaked(cell_grid: Vector2i, mesh: ArrayMesh) -> bool:
	# Log first cell for diagnostics - BEFORE any checks
	if not _first_cell_logged:
		_first_cell_logged = true
		print("[DistantStaticRenderer] First cell diagnostic:")
		print("  cell_grid: %s" % cell_grid)
		print("  mesh: %s" % mesh)
		print("  mesh surfaces: %d" % (mesh.get_surface_count() if mesh else -1))
		print("  mesh AABB: %s" % (mesh.get_aabb() if mesh else "N/A"))
		print("  scenario valid: %s" % _scenario.is_valid())
		print("  in scene tree: %s" % is_inside_tree())
		var viewport_scenario := get_viewport().get_world_3d().scenario if get_viewport() and get_viewport().get_world_3d() else RID()
		print("  current viewport scenario: %s" % viewport_scenario)
		print("  scenarios match: %s" % (_scenario == viewport_scenario))

	# Skip if already loaded
	if cell_grid in _cells:
		return true

	# Validate scenario - critical for rendering
	if not _scenario.is_valid():
		push_error("DistantStaticRenderer: Invalid scenario RID - mesh won't render! Is node in scene tree?")
		return false

	if not mesh:
		push_warning("DistantStaticRenderer: Null mesh for cell %s" % cell_grid)
		return false

	if mesh.get_surface_count() == 0:
		push_warning("DistantStaticRenderer: Empty mesh (0 surfaces) for cell %s" % cell_grid)
		return false

	# Create RenderingServer resources
	var cell_instance: CellInstance = CellInstance.new()
	cell_instance.grid = cell_grid
	cell_instance.mesh_ref = mesh  # CRITICAL: Keep reference to prevent GC
	cell_instance.mesh_rid = mesh.get_rid()
	cell_instance.owns_mesh = false  # Mesh is owned by resource

	# Create instance
	cell_instance.instance_rid = RenderingServer.instance_create()
	RenderingServer.instance_set_base(cell_instance.instance_rid, cell_instance.mesh_rid)
	RenderingServer.instance_set_scenario(cell_instance.instance_rid, _scenario)

	# CRITICAL: Set identity transform explicitly - RenderingServer requires this!
	# Without this, the instance won't render (mesh vertices are already in world space)
	RenderingServer.instance_set_transform(cell_instance.instance_rid, Transform3D.IDENTITY)

	# CRITICAL: Set visibility margin for proper frustum culling at distance
	# Without this, Godot may cull large distant meshes prematurely
	RenderingServer.instance_set_extra_visibility_margin(cell_instance.instance_rid, 500.0)

	# Ensure instance is visible (explicit, not relying on default)
	RenderingServer.instance_set_visible(cell_instance.instance_rid, true)

	# Set layer mask to all layers to ensure visibility with any camera cull mask
	RenderingServer.instance_set_layer_mask(cell_instance.instance_rid, 0xFFFFFFFF)

	# ALWAYS apply default material for prebaked meshes (they have no materials baked in)
	# This ensures meshes are visible with a neutral color
	if _default_material:
		RenderingServer.instance_geometry_set_material_override(
			cell_instance.instance_rid, _default_material.get_rid())

	# DEBUG: Print instance creation details
	if _cells.size() < 3:  # Only for first few cells
		var center := mesh.get_aabb().get_center()
		print("DSR CELL %s CENTER=(%.0f,%.0f,%.0f) INST=%s SCEN=%s" % [
			cell_grid, center.x, center.y, center.z,
			cell_instance.instance_rid.is_valid(),
			_scenario.is_valid()
		])

	# Get mesh info for stats
	cell_instance.aabb = mesh.get_aabb()
	cell_instance.vertex_count = 0
	cell_instance.object_count = 1
	for i: int in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(i)
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

	# Validate scenario - critical for rendering
	if not _scenario.is_valid():
		push_error("DistantStaticRenderer: Invalid scenario RID - mesh won't render! Is node in scene tree?")
		return false

	# Get references if not provided
	if references.is_empty() and cell_manager:
		var cell_record: CellRecord = ESMManager.get_exterior_cell(cell_grid.x, cell_grid.y)
		if cell_record:
			references = cell_record.references

	if references.is_empty():
		# No references - cell is empty or ocean
		return false

	# Create merged mesh
	if not mesh_merger:
		push_warning("DistantStaticRenderer: No mesh merger set")
		return false

	var merged_data: StaticMeshMerger.MergedCellData = mesh_merger.merge_cell(cell_grid, references)
	if not merged_data:
		# No mergeable objects in this cell
		return false

	# Create RenderingServer resources
	var cell_instance: CellInstance = CellInstance.new()
	cell_instance.grid = cell_grid

	# Get mesh RID from ArrayMesh
	var mesh: ArrayMesh = merged_data.mesh
	if not mesh:
		return false

	cell_instance.mesh_ref = mesh  # CRITICAL: Keep reference to prevent GC
	cell_instance.mesh_rid = mesh.get_rid()
	cell_instance.owns_mesh = false  # Mesh is owned by ArrayMesh resource

	# Create instance
	cell_instance.instance_rid = RenderingServer.instance_create()
	RenderingServer.instance_set_base(cell_instance.instance_rid, cell_instance.mesh_rid)
	RenderingServer.instance_set_scenario(cell_instance.instance_rid, _scenario)

	# CRITICAL: Set identity transform explicitly - RenderingServer requires this!
	RenderingServer.instance_set_transform(cell_instance.instance_rid, Transform3D.IDENTITY)

	# CRITICAL: Set visibility margin for proper frustum culling at distance
	RenderingServer.instance_set_extra_visibility_margin(cell_instance.instance_rid, 500.0)

	# Ensure instance is visible (explicit)
	RenderingServer.instance_set_visible(cell_instance.instance_rid, true)

	# Set layer mask to all layers
	RenderingServer.instance_set_layer_mask(cell_instance.instance_rid, 0xFFFFFFFF)

	# Apply material if available, otherwise use default
	if merged_data.material:
		cell_instance.material_rid = merged_data.material.get_rid()
		RenderingServer.instance_geometry_set_material_override(
			cell_instance.instance_rid, cell_instance.material_rid)
	elif _default_material:
		RenderingServer.instance_geometry_set_material_override(
			cell_instance.instance_rid, _default_material.get_rid())

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
func set_cell_visible(cell_grid: Vector2i, is_visible: bool) -> void:
	if cell_grid not in _cells:
		return

	var cell_instance: CellInstance = _cells[cell_grid]
	if cell_instance.visible == is_visible:
		return

	cell_instance.visible = is_visible
	RenderingServer.instance_set_visible(cell_instance.instance_rid, is_visible)

	if is_visible:
		_stats["visible_cells"] += 1
	else:
		_stats["visible_cells"] -= 1


## Update visibility for all cells based on camera position
## max_distance: Maximum distance for MID tier visibility
## Returns number of visibility changes made
func update_visibility(camera_pos: Vector3, max_distance: float) -> int:
	var changes: int = 0
	var max_dist_sq: float = max_distance * max_distance

	for grid: Vector2i in _cells:
		var cell_instance: CellInstance = _cells[grid]

		# Calculate distance to cell center
		var cell_center: Vector3 = cell_instance.aabb.get_center()
		var dist_sq: float = camera_pos.distance_squared_to(cell_center)

		var should_be_visible: bool = dist_sq <= max_dist_sq

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
	var grids: Array[Vector2i] = []
	for grid: Vector2i in _cells:
		grids.append(grid)
	for grid: Vector2i in grids:
		remove_cell(grid)

	_cells.clear()

	_stats["loaded_cells"] = 0
	_stats["total_vertices"] = 0
	_stats["total_objects"] = 0
	_stats["visible_cells"] = 0


## Get statistics
func get_stats() -> Dictionary[String, int]:
	return _stats.duplicate()


## Get all loaded cell coordinates
func get_loaded_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for grid: Vector2i in _cells:
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


## Debug: Print detailed state information
func debug_print_state() -> void:
	print("[DistantStaticRenderer] Loaded cells: %d, Total vertices: %d, Visible cells: %d" % [
		_cells.size(), _stats["total_vertices"], _stats["visible_cells"]])


## Debug: Get extended statistics including rendering info
func get_debug_info() -> Dictionary:
	return {
		"scenario_valid": _scenario.is_valid(),
		"material_valid": _default_material != null,
		"loaded_cells": _stats["loaded_cells"],
		"visible_cells": _stats["visible_cells"],
		"total_vertices": _stats["total_vertices"],
		"total_objects": _stats["total_objects"],
		"in_tree": is_inside_tree(),
	}
