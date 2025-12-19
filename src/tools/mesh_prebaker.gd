## MeshPrebaker - Tool for pre-merging cell meshes offline
##
## Creates pre-baked merged meshes for distant rendering (MID tier, 500m-2km)
##
## Process:
## 1. Load all static objects in a cell
## 2. Filter: keep buildings/rocks, skip clutter/NPCs
## 3. Apply aggressive mesh simplification (95% reduction)
## 4. Merge into single mesh with baked transforms
## 5. Save to assets/merged_cells/cell_X_Y.res
##
## Usage:
##   var baker := MeshPrebaker.new()
##   baker.bake_all_cells()  # Bake all exterior cells
##   # OR
##   baker.bake_cell(Vector2i(-2, -9))  # Bake single cell (e.g., Seyda Neen)
class_name MeshPrebaker
extends RefCounted

const CS := preload("res://src/core/coordinate_system.gd")
const NIFConverter := preload("res://src/core/nif/nif_converter.gd")
const MeshSimplifier := preload("res://src/core/nif/mesh_simplifier.gd")

## Output directory for merged cell meshes
var output_dir: String = "res://assets/merged_cells"

## Mesh simplification ratio for MID tier (aggressive)
var simplification_ratio: float = 0.05  # 5% of original (95% reduction)

## Minimum object size to include (meters)
var min_object_size: float = 2.0

## Progress tracking
signal progress(current: int, total: int, cell_name: String)
signal cell_baked(cell_grid: Vector2i, success: bool, output_path: String)
signal batch_complete(total: int, success_count: int, failed_count: int)

## Statistics
var _total_baked: int = 0
var _total_failed: int = 0
var _failed_cells: Array[Vector2i] = []


## Initialize the baker
func initialize() -> Error:
	# Create output directory
	if not DirAccess.dir_exists_absolute(output_dir):
		var err := DirAccess.make_dir_recursive_absolute(output_dir)
		if err != OK:
			push_error("MeshPrebaker: Failed to create output directory: %s" % output_dir)
			return err

	print("MeshPrebaker: Initialized - output dir: %s" % output_dir)
	return OK


## Bake all exterior cells from ESM data
func bake_all_cells() -> Dictionary:
	if initialize() != OK:
		return {"success": 0, "failed": 0}

	_total_baked = 0
	_total_failed = 0
	_failed_cells.clear()

	# Get all exterior cells
	var cells := _get_all_exterior_cells()
	print("MeshPrebaker: Found %d exterior cells to bake" % cells.size())

	# Bake each cell
	for i in range(cells.size()):
		var cell_grid := cells[i]
		var cell_name := "Cell_%d_%d" % [cell_grid.x, cell_grid.y]
		progress.emit(i + 1, cells.size(), cell_name)

		var result := bake_cell(cell_grid)
		if result.success:
			_total_baked += 1
		else:
			_total_failed += 1
			_failed_cells.append(cell_grid)

	# Complete
	batch_complete.emit(cells.size(), _total_baked, _total_failed)

	print("MeshPrebaker: Batch complete - %d succeeded, %d failed" % [_total_baked, _total_failed])
	if not _failed_cells.is_empty():
		print("  Failed cells: %s" % str(_failed_cells))

	return {
		"total": cells.size(),
		"success": _total_baked,
		"failed": _total_failed,
		"failed_cells": _failed_cells.duplicate()
	}


## Bake merged mesh for a single cell
## Returns: Dictionary with { success: bool, output_path: String, error: String }
func bake_cell(cell_grid: Vector2i) -> Dictionary:
	print("MeshPrebaker: Baking cell %s..." % str(cell_grid))

	# Get cell from ESM
	var cell: CellRecord = ESMManager.get_exterior_cell(cell_grid.x, cell_grid.y)
	if not cell:
		var error := "Cell not found in ESM"
		push_warning("MeshPrebaker: %s - %s" % [error, cell_grid])
		cell_baked.emit(cell_grid, false, "")
		return {"success": false, "output_path": "", "error": error}

	# Filter static references
	var static_refs := _filter_static_references(cell.references)
	if static_refs.is_empty():
		print("MeshPrebaker: Cell %s has no static objects to merge" % str(cell_grid))
		cell_baked.emit(cell_grid, true, "")
		return {"success": true, "output_path": "", "error": "No objects to merge"}

	print("  Found %d static objects to merge" % static_refs.size())

	# Merge meshes
	var merged_mesh := _merge_cell_meshes(static_refs, cell_grid)
	if not merged_mesh:
		var error := "Failed to merge meshes"
		push_warning("MeshPrebaker: %s - %s" % [error, cell_grid])
		cell_baked.emit(cell_grid, false, "")
		return {"success": false, "output_path": "", "error": error}

	# Save to file
	var output_path := _get_output_path(cell_grid)
	var save_err := ResourceSaver.save(merged_mesh, output_path)
	if save_err != OK:
		var error := "Failed to save mesh: error %d" % save_err
		push_warning("MeshPrebaker: %s - %s" % [error, output_path])
		cell_baked.emit(cell_grid, false, "")
		return {"success": false, "output_path": "", "error": error}

	print("MeshPrebaker: Saved %s" % output_path)
	cell_baked.emit(cell_grid, true, output_path)

	return {
		"success": true,
		"output_path": output_path,
		"error": ""
	}


## Get all exterior cells from ESM
func _get_all_exterior_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var seen: Dictionary = {}

	for key in ESMManager.cells:
		var cell: CellRecord = ESMManager.cells[key]
		if cell and not cell.is_interior():
			var grid := Vector2i(cell.grid_x, cell.grid_y)
			if grid not in seen:
				seen[grid] = true
				cells.append(grid)

	cells.sort_custom(func(a, b): return a.x < b.x or (a.x == b.x and a.y < b.y))
	return cells


## Filter cell references to only include mergeable static objects
func _filter_static_references(references: Array) -> Array:
	var filtered := []

	for ref in references:
		# Get base record
		var record_type: Array = [""]
		var base_record = ESMManager.get_any_record(str(ref.ref_id), record_type)
		if not base_record:
			continue

		var type_name: String = record_type[0] if record_type.size() > 0 else ""

		# Skip dynamic objects
		if type_name in ["npc", "creature", "leveled_creature", "leveled_item", "light"]:
			continue

		# Skip containers (they're interactive)
		if type_name == "container":
			continue

		# Skip activators (doors, switches, etc.)
		if type_name == "activator":
			continue

		# Get model path
		var model_path: String = ""
		if "model" in base_record:
			model_path = base_record.model
		elif "mesh" in base_record:
			model_path = base_record.mesh

		if model_path.is_empty():
			continue

		# Check object size (skip tiny clutter)
		if not _is_object_large_enough(model_path, ref):
			continue

		filtered.append(ref)

	return filtered


## Check if object is large enough to include in merged mesh
func _is_object_large_enough(model_path: String, ref: CellReference) -> bool:
	# Simple heuristic: skip very small objects based on scale
	var scale := ref.scale
	var avg_scale := (abs(scale.x) + abs(scale.y) + abs(scale.z)) / 3.0

	return avg_scale >= min_object_size / 10.0  # Rough estimate


## Merge all static meshes in a cell
func _merge_cell_meshes(references: Array, cell_grid: Vector2i) -> ArrayMesh:
	var surface_tool := SurfaceTool.new()
	var simplifier := MeshSimplifier.new()
	var merged_any := false

	for ref in references:
		# Get model
		var record_type: Array = [""]
		var base_record = ESMManager.get_any_record(str(ref.ref_id), record_type)
		if not base_record:
			continue

		var model_path: String = ""
		if "model" in base_record:
			model_path = base_record.model
		elif "mesh" in base_record:
			model_path = base_record.mesh

		# Load and convert NIF
		var nif_data := _load_nif(model_path)
		if nif_data.is_empty():
			continue

		var converter := NIFConverter.new()
		converter.load_textures = false  # Don't need textures for merged mesh
		converter.load_animations = false
		converter.load_collision = false
		converter.generate_lods = false
		converter.generate_occluders = false

		var model := converter.convert_buffer(nif_data, model_path)
		if not model:
			continue

		# Find first mesh
		var mesh_inst := _find_first_mesh_instance(model)
		if not mesh_inst or not mesh_inst.mesh:
			model.queue_free()
			continue

		# Simplify mesh aggressively
		var simplified := simplifier.simplify_mesh(mesh_inst.mesh, simplification_ratio)
		if not simplified:
			model.queue_free()
			continue

		# Calculate world transform
		var transform := _calculate_transform(ref, cell_grid)

		# Append to merged mesh
		surface_tool.append_from(simplified, 0, transform)
		merged_any = true

		model.queue_free()

	if not merged_any:
		return null

	# Commit and return
	return surface_tool.commit()


## Load NIF from BSA
func _load_nif(model_path: String) -> PackedByteArray:
	var full_path := model_path
	if not model_path.to_lower().begins_with("meshes"):
		full_path = "meshes\\" + model_path

	if BSAManager.has_file(full_path):
		return BSAManager.extract_file(full_path)
	elif BSAManager.has_file(model_path):
		return BSAManager.extract_file(model_path)

	return PackedByteArray()


## Find first MeshInstance3D in node hierarchy
func _find_first_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node as MeshInstance3D

	for child in node.get_children():
		var found := _find_first_mesh_instance(child)
		if found:
			return found

	return null


## Calculate world transform for a cell reference
func _calculate_transform(ref: CellReference, cell_grid: Vector2i) -> Transform3D:
	var pos := CS.vector_to_godot(ref.position)
	var scale := CS.scale_to_godot(ref.scale)
	var euler := CS.euler_to_godot(ref.rotation)
	var basis := Basis.from_euler(euler, EULER_ORDER_XZY)
	basis = basis.scaled(scale)

	return Transform3D(basis, pos)


## Generate output path for merged cell mesh
func _get_output_path(cell_grid: Vector2i) -> String:
	var filename := "cell_%d_%d.res" % [cell_grid.x, cell_grid.y]
	return output_dir.path_join(filename)


## Get statistics
func get_stats() -> Dictionary:
	return {
		"total_baked": _total_baked,
		"total_failed": _total_failed,
		"failed_cells": _failed_cells.duplicate(),
	}
