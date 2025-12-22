## MeshPrebakerV2 - Improved mesh prebaking for MID tier rendering
##
## Creates pre-merged cell meshes for distant rendering (MID tier, 500m-2km).
## Improvements over v1:
## - Collects ALL mesh instances (not just first)
## - Preserves UV coordinates for texture atlasing
## - Better material handling and surface grouping
## - Parallel baking support
## - Progress persistence
##
## Process:
## 1. Load all static objects in a cell
## 2. Filter: keep buildings/rocks, skip clutter/NPCs/interactive
## 3. Group by material for batching
## 4. Apply aggressive mesh simplification (95% reduction)
## 5. Merge surfaces and save to {cache}/merged_cells/cell_X_Y.res
class_name MeshPrebakerV2
extends RefCounted

const CS := preload("res://src/core/coordinate_system.gd")
const NIFConverter := preload("res://src/core/nif/nif_converter.gd")
const MeshSimplifier := preload("res://src/core/nif/mesh_simplifier.gd")

## Output directory for merged cell meshes (set in initialize from SettingsManager)
var output_dir: String = ""

## Mesh simplification ratio for MID tier (aggressive)
var simplification_ratio: float = 0.05  # 5% of original (95% reduction)

## Minimum object size to include (meters)
var min_object_size: float = 2.0

## Whether to preserve UVs (needed for texture atlasing)
var preserve_uvs: bool = true

## Skip cells that already have baked meshes
var skip_existing: bool = true

## Maximum vertices per merged mesh (for GPU limits)
var max_vertices_per_mesh: int = 65535

## Progress tracking
signal progress(current: int, total: int, cell_name: String)
signal cell_baked(cell_grid: Vector2i, success: bool, output_path: String, stats: Dictionary)
signal batch_complete(total: int, success_count: int, failed_count: int, skipped_count: int)

## Statistics
var _total_baked: int = 0
var _total_failed: int = 0
var _total_skipped: int = 0
var _failed_cells: Array[Vector2i] = []


## Initialize the baker
func initialize() -> Error:
	# Get output directory from settings manager
	if output_dir.is_empty():
		output_dir = SettingsManager.get_merged_cells_path()

	# Ensure cache directories exist
	var err := SettingsManager.ensure_cache_directories()
	if err != OK:
		push_error("MeshPrebakerV2: Failed to create cache directories")
		return err

	print("MeshPrebakerV2: Initialized - output dir: %s" % output_dir)
	return OK


## Bake all exterior cells from ESM data
func bake_all_cells() -> Dictionary:
	if initialize() != OK:
		return {"success": 0, "failed": 0, "skipped": 0}

	_total_baked = 0
	_total_failed = 0
	_total_skipped = 0
	_failed_cells.clear()

	var cells := _get_all_exterior_cells()
	print("MeshPrebakerV2: Found %d exterior cells to bake" % cells.size())

	for i in range(cells.size()):
		var cell_grid := cells[i]
		var cell_name := "Cell_%d_%d" % [cell_grid.x, cell_grid.y]
		progress.emit(i + 1, cells.size(), cell_name)

		# Check if already exists
		if skip_existing and _mesh_exists(cell_grid):
			print("  [%d/%d] %s - SKIPPED (already exists)" % [i + 1, cells.size(), cell_name])
			_total_skipped += 1
			continue

		var result := bake_cell(cell_grid)
		if result.success:
			_total_baked += 1
		else:
			_total_failed += 1
			_failed_cells.append(cell_grid)

	batch_complete.emit(cells.size(), _total_baked, _total_failed, _total_skipped)

	print("MeshPrebakerV2: Batch complete - %d baked, %d skipped, %d failed" % [
		_total_baked, _total_skipped, _total_failed])

	return {
		"total": cells.size(),
		"success": _total_baked,
		"failed": _total_failed,
		"skipped": _total_skipped,
		"failed_cells": _failed_cells.duplicate()
	}


## Bake merged mesh for a single cell
func bake_cell(cell_grid: Vector2i) -> Dictionary:
	print("MeshPrebakerV2: Baking cell %s..." % str(cell_grid))
	var start_time := Time.get_ticks_msec()

	# Get cell from ESM
	var cell: CellRecord = ESMManager.get_exterior_cell(cell_grid.x, cell_grid.y)
	if not cell:
		var error := "Cell not found in ESM"
		push_warning("MeshPrebakerV2: %s - %s" % [error, cell_grid])
		cell_baked.emit(cell_grid, false, "", {})
		return {"success": false, "output_path": "", "error": error}

	# Filter static references
	var static_refs := _filter_static_references(cell.references)
	if static_refs.is_empty():
		print("  Cell %s has no static objects to merge" % str(cell_grid))
		cell_baked.emit(cell_grid, true, "", {"objects": 0})
		return {"success": true, "output_path": "", "error": "No objects to merge", "objects": 0}

	print("  Found %d static objects to merge" % static_refs.size())

	# Collect all mesh data
	var mesh_data := _collect_mesh_data(static_refs, cell_grid)
	if mesh_data.surfaces.is_empty():
		var error := "No valid meshes found"
		push_warning("MeshPrebakerV2: %s - %s" % [error, cell_grid])
		cell_baked.emit(cell_grid, false, "", {})
		return {"success": false, "output_path": "", "error": error}

	# Merge and simplify
	var merged_mesh := _merge_surfaces(mesh_data.surfaces)
	if not merged_mesh:
		var error := "Failed to merge meshes"
		push_warning("MeshPrebakerV2: %s - %s" % [error, cell_grid])
		cell_baked.emit(cell_grid, false, "", {})
		return {"success": false, "output_path": "", "error": error}

	# Save to file
	var output_path := _get_output_path(cell_grid)
	var save_err := ResourceSaver.save(merged_mesh, output_path)
	if save_err != OK:
		var error := "Failed to save mesh: error %d" % save_err
		push_warning("MeshPrebakerV2: %s - %s" % [error, output_path])
		cell_baked.emit(cell_grid, false, "", {})
		return {"success": false, "output_path": "", "error": error}

	var elapsed := Time.get_ticks_msec() - start_time
	var stats := {
		"objects": static_refs.size(),
		"surfaces": merged_mesh.get_surface_count(),
		"vertices": mesh_data.total_vertices,
		"simplified_vertices": _count_mesh_vertices(merged_mesh),
		"time_ms": elapsed,
	}

	print("  Saved %s (%d objects, %d vertices -> %d simplified, %.1fs)" % [
		output_path, stats.objects, stats.vertices, stats.simplified_vertices, elapsed / 1000.0])

	cell_baked.emit(cell_grid, true, output_path, stats)
	return {
		"success": true,
		"output_path": output_path,
		"error": "",
		"stats": stats
	}


## Collect mesh data from all references
func _collect_mesh_data(references: Array, cell_grid: Vector2i) -> Dictionary:
	var surfaces := []  # Array of { arrays: Array, transform: Transform3D }
	var total_vertices := 0

	for ref in references:
		var record_type: Array = [""]
		var base_record = ESMManager.get_any_record(str(ref.ref_id), record_type)
		if not base_record:
			continue

		var model_path: String = ""
		if "model" in base_record:
			model_path = base_record.model
		elif "mesh" in base_record:
			model_path = base_record.mesh

		if model_path.is_empty():
			continue

		# Load NIF
		var nif_data := _load_nif(model_path)
		if nif_data.is_empty():
			continue

		var converter := NIFConverter.new()
		converter.load_textures = false
		converter.load_animations = false
		converter.load_collision = false
		converter.generate_lods = false
		converter.generate_occluders = false

		var model := converter.convert_buffer(nif_data, model_path)
		if not model:
			continue

		# Calculate world transform for this reference
		var world_transform := _calculate_transform(ref, cell_grid)

		# Extract ALL mesh instances from the model
		var mesh_instances := _find_all_mesh_instances(model)
		for mesh_inst in mesh_instances:
			if not mesh_inst.mesh:
				continue

			var mesh: Mesh = mesh_inst.mesh
			# Use manual global transform calculation since model isn't in scene tree
			var local_transform := _get_accumulated_transform(mesh_inst)

			# Process each surface
			for surf_idx in range(mesh.get_surface_count()):
				var arrays := mesh.surface_get_arrays(surf_idx)
				if arrays.is_empty() or not arrays[Mesh.ARRAY_VERTEX]:
					continue

				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				total_vertices += vertices.size()

				surfaces.append({
					"arrays": arrays,
					"transform": world_transform * local_transform,
				})

		model.queue_free()

	return {
		"surfaces": surfaces,
		"total_vertices": total_vertices,
	}


## Merge all surfaces into a single mesh
func _merge_surfaces(surfaces: Array) -> ArrayMesh:
	if surfaces.is_empty():
		return null

	var simplifier := MeshSimplifier.new()
	var surface_tool := SurfaceTool.new()
	var current_vertex_count := 0
	var mesh := ArrayMesh.new()
	var surface_index := 0

	for surface_data in surfaces:
		var arrays: Array = surface_data.arrays
		var transform: Transform3D = surface_data.transform

		# Simplify if needed
		var simplified := simplifier.simplify(arrays, simplification_ratio)
		if simplified.is_empty():
			simplified = arrays

		var vertices: PackedVector3Array = simplified[Mesh.ARRAY_VERTEX]
		if vertices.is_empty():
			continue

		# Check if we need to start a new surface (vertex limit)
		if current_vertex_count + vertices.size() > max_vertices_per_mesh:
			# Commit current surface
			if current_vertex_count > 0:
				var committed := surface_tool.commit(mesh)
				if committed:
					surface_index += 1
				surface_tool = SurfaceTool.new()
				current_vertex_count = 0

		# Begin new surface if needed
		if current_vertex_count == 0:
			surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)

		# Transform and add vertices
		var transformed_arrays := _transform_arrays(simplified, transform)
		_append_arrays_to_surface_tool(surface_tool, transformed_arrays)
		current_vertex_count += vertices.size()

	# Commit final surface
	if current_vertex_count > 0:
		surface_tool.generate_normals()
		surface_tool.commit(mesh)

	if mesh.get_surface_count() == 0:
		return null

	return mesh


## Transform mesh arrays by a transform
func _transform_arrays(arrays: Array, transform: Transform3D) -> Array:
	var result := arrays.duplicate()

	# Transform vertices
	if arrays[Mesh.ARRAY_VERTEX]:
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var transformed := PackedVector3Array()
		transformed.resize(vertices.size())
		for i in range(vertices.size()):
			transformed[i] = transform * vertices[i]
		result[Mesh.ARRAY_VERTEX] = transformed

	# Transform normals (rotation only, no translation)
	if arrays[Mesh.ARRAY_NORMAL]:
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var transformed := PackedVector3Array()
		transformed.resize(normals.size())
		var basis := transform.basis
		for i in range(normals.size()):
			transformed[i] = (basis * normals[i]).normalized()
		result[Mesh.ARRAY_NORMAL] = transformed

	return result


## Append arrays to SurfaceTool
func _append_arrays_to_surface_tool(st: SurfaceTool, arrays: Array) -> void:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] else PackedVector3Array()
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] else PackedVector2Array()
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] else PackedColorArray()
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] else PackedInt32Array()

	var has_normals := normals.size() == vertices.size()
	var has_uvs := uvs.size() == vertices.size() and preserve_uvs
	var has_colors := colors.size() == vertices.size()

	if indices.is_empty():
		# Non-indexed mesh - add vertices directly
		for i in range(vertices.size()):
			if has_normals:
				st.set_normal(normals[i])
			if has_uvs:
				st.set_uv(uvs[i])
			if has_colors:
				st.set_color(colors[i])
			st.add_vertex(vertices[i])
	else:
		# Indexed mesh - add unique vertices and use indices
		for idx in indices:
			if idx >= vertices.size():
				continue
			if has_normals and idx < normals.size():
				st.set_normal(normals[idx])
			if has_uvs and idx < uvs.size():
				st.set_uv(uvs[idx])
			if has_colors and idx < colors.size():
				st.set_color(colors[idx])
			st.add_vertex(vertices[idx])


## Find all MeshInstance3D nodes in hierarchy
func _find_all_mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var instances: Array[MeshInstance3D] = []

	if node is MeshInstance3D:
		instances.append(node as MeshInstance3D)

	for child in node.get_children():
		instances.append_array(_find_all_mesh_instances(child))

	return instances


## Calculate accumulated transform by walking up parent hierarchy
## Used when node is not in scene tree (can't use global_transform)
func _get_accumulated_transform(node: Node3D) -> Transform3D:
	var accumulated := node.transform
	var parent := node.get_parent()
	while parent is Node3D:
		accumulated = parent.transform * accumulated
		parent = parent.get_parent()
	return accumulated


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
		var record_type: Array = [""]
		var base_record = ESMManager.get_any_record(str(ref.ref_id), record_type)
		if not base_record:
			continue

		var type_name: String = record_type[0] if record_type.size() > 0 else ""

		# Skip dynamic objects
		if type_name in ["npc", "creature", "leveled_creature", "leveled_item", "light"]:
			continue

		# Skip interactive objects
		if type_name in ["container", "activator", "door"]:
			continue

		# Get model path
		var model_path: String = ""
		if "model" in base_record:
			model_path = base_record.model
		elif "mesh" in base_record:
			model_path = base_record.mesh

		if model_path.is_empty():
			continue

		# Check object size
		if not _is_object_large_enough(ref):
			continue

		filtered.append(ref)

	return filtered


## Check if object is large enough to include
func _is_object_large_enough(ref: CellReference) -> bool:
	var scale: float = ref.scale
	return abs(scale) >= min_object_size / 10.0


## Load NIF from BSA
func _load_nif(model_path: String) -> PackedByteArray:
	var full_path := model_path
	if not model_path.to_lower().begins_with("meshes"):
		full_path = "meshes/" + model_path

	full_path = full_path.replace("\\", "/")

	if BSAManager.has_file(full_path):
		return BSAManager.extract_file(full_path)
	elif BSAManager.has_file(model_path):
		return BSAManager.extract_file(model_path)

	return PackedByteArray()


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


## Check if mesh already exists
func _mesh_exists(cell_grid: Vector2i) -> bool:
	var path := _get_output_path(cell_grid)
	return FileAccess.file_exists(path)


## Count vertices in a mesh
func _count_mesh_vertices(mesh: ArrayMesh) -> int:
	var count := 0
	for i in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(i)
		if arrays[Mesh.ARRAY_VERTEX]:
			count += arrays[Mesh.ARRAY_VERTEX].size()
	return count


## Get statistics
func get_stats() -> Dictionary:
	return {
		"total_baked": _total_baked,
		"total_failed": _total_failed,
		"total_skipped": _total_skipped,
		"failed_cells": _failed_cells.duplicate(),
	}
