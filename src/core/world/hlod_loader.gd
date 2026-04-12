## HLODLoader — Loads and manages cell-level HLOD merged meshes
##
## At distance (300-1000m), each exterior cell is rendered as a single RS instance
## containing the merged geometry of all mid-worthy objects. This replaces ~100+
## individual RS instances per cell, cutting draw calls and culling overhead.
##
## Lifecycle:
##   1. Camera cell changes → streaming manager calls update_for_camera()
##   2. Cells entering HLOD range → load_cell_hlod() creates RS instance
##   3. Cells leaving HLOD range → unload_cell_hlod() frees RS instance
##   4. Visibility_range handles fade transitions with individual MID instances
##
## Files on disk: cache/hlod/cell_{x}_{y}.res (ArrayMesh with LOD chain)
## Baked by: model_prebaker.gd::bake_cell_hlod()
class_name HLODLoader
extends RefCounted

const DU := preload("res://src/core/world/distance_utils.gd")
const ModelPrebakerScript := preload("res://src/tools/prebaking/model_prebaker.gd")

## Loaded HLOD cells: Vector2i -> HLODCellData
var _loaded_cells: Dictionary[Vector2i, HLODCellData] = {}

## Scenario RID for creating RS instances
var _scenario: RID = RID()

## Cache directory for HLOD meshes
var _hlod_dir: String = ""

## Stats
var _stats: Dictionary = {
	"loaded_cells": 0,
	"total_surfaces": 0,
}

## Mesh resource cache: keeps strong references to prevent GC
var _mesh_cache: Dictionary[Vector2i, ArrayMesh] = {}


class HLODCellData:
	var grid: Vector2i
	var instance_rid: RID
	var mesh: ArrayMesh  ## Strong ref — prevents GC
	var surface_count: int = 0


## Initialize with a scenario RID (from viewport world)
func initialize(scenario: RID) -> void:
	_scenario = scenario
	_hlod_dir = SettingsManager.get_cache_base_path().path_join("hlod")


## Update HLOD cells based on camera position.
## Loads cells entering HLOD range, unloads cells leaving it.
## Returns number of cells changed.
func update_for_camera(camera_cell: Vector2i, load_radius_cells: int) -> int:
	var changed := 0
	var hlod_start_sq := DU.HLOD_START * DU.HLOD_START
	var hlod_end_sq := DU.HLOD_END * DU.HLOD_END
	var hlod_radius := DU.distance_to_cell_radius(DU.HLOD_END)

	# Determine which cells should have HLOD active
	var desired_cells: Dictionary[Vector2i, bool] = {}
	for dy in range(-hlod_radius, hlod_radius + 1):
		for dx in range(-hlod_radius, hlod_radius + 1):
			var grid := Vector2i(camera_cell.x + dx, camera_cell.y + dy)
			var dist_sq := DU.cell_distance_squared(grid, camera_cell)
			# HLOD only for cells between HLOD_START and HLOD_END
			# (cells closer than HLOD_START use individual RS instances)
			if dist_sq >= hlod_start_sq and dist_sq <= hlod_end_sq:
				desired_cells[grid] = true

	# Load new cells
	for grid: Vector2i in desired_cells:
		if grid not in _loaded_cells:
			if load_cell_hlod(grid):
				changed += 1

	# Unload cells that left range
	var to_unload: Array[Vector2i] = []
	for grid: Vector2i in _loaded_cells:
		if grid not in desired_cells:
			to_unload.append(grid)

	for grid: Vector2i in to_unload:
		unload_cell_hlod(grid)
		changed += 1

	return changed


## Load a single HLOD cell mesh and create its RS instance.
## Returns true if successful.
func load_cell_hlod(grid: Vector2i) -> bool:
	if grid in _loaded_cells:
		return true  # Already loaded

	if not _scenario.is_valid():
		return false

	# Load mesh from cache
	var mesh := _load_mesh(grid)
	if not mesh:
		return false

	# Create RS instance
	var rs := RenderingServer
	var rid := rs.instance_create()
	rs.instance_set_base(rid, mesh.get_rid())
	rs.instance_set_scenario(rid, _scenario)

	# Position at cell origin (HLOD vertices are in cell-local space)
	var cell_origin := DU.cell_to_world_origin(grid)
	rs.instance_set_transform(rid, Transform3D(Basis.IDENTITY, cell_origin))

	# Visibility range: HLOD_START to HLOD_END with fade margins
	rs.instance_geometry_set_visibility_range(
		rid,
		DU.HLOD_START, DU.HLOD_END,
		20.0, 20.0,  # 20m fade margins both sides
		RenderingServer.VISIBILITY_RANGE_FADE_SELF
	)

	# LOD bias — default 1.0, tunable later
	rs.instance_geometry_set_lod_bias(rid, 1.0)

	# Store data
	var data := HLODCellData.new()
	data.grid = grid
	data.instance_rid = rid
	data.mesh = mesh
	data.surface_count = mesh.get_surface_count()
	_loaded_cells[grid] = data
	_mesh_cache[grid] = mesh  # Strong ref

	_stats["loaded_cells"] = _loaded_cells.size()
	_stats["total_surfaces"] += data.surface_count

	return true


## Unload a single HLOD cell
func unload_cell_hlod(grid: Vector2i) -> void:
	if grid not in _loaded_cells:
		return

	var data: HLODCellData = _loaded_cells[grid]
	if data.instance_rid.is_valid():
		RenderingServer.free_rid(data.instance_rid)

	_stats["total_surfaces"] -= data.surface_count
	_loaded_cells.erase(grid)
	_mesh_cache.erase(grid)
	_stats["loaded_cells"] = _loaded_cells.size()


## Load mesh from HLOD cache
func _load_mesh(grid: Vector2i) -> ArrayMesh:
	# Check memory cache first
	if grid in _mesh_cache:
		return _mesh_cache[grid]

	var file_path := _hlod_dir.path_join("cell_%d_%d.res" % [grid.x, grid.y])
	if not FileAccess.file_exists(file_path):
		return null

	return ResourceLoader.load(file_path, "ArrayMesh") as ArrayMesh


## Get stats for debug/profiling
func get_stats() -> Dictionary:
	return _stats.duplicate()


## Clear all loaded HLOD cells
func cleanup() -> void:
	for grid: Vector2i in _loaded_cells:
		var data: HLODCellData = _loaded_cells[grid]
		if data.instance_rid.is_valid():
			RenderingServer.free_rid(data.instance_rid)
	_loaded_cells.clear()
	_mesh_cache.clear()
	_stats["loaded_cells"] = 0
	_stats["total_surfaces"] = 0
