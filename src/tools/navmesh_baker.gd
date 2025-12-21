## NavMeshBaker - Tool for pre-baking navigation meshes per cell
##
## Creates pre-baked NavigationMesh resources for runtime loading (similar to OpenMW's approach)
##
## Process:
## 1. Parse cell geometry (terrain LAND/Terrain3D, static objects, buildings)
## 2. Convert to NavigationMeshSourceGeometryData3D
## 3. Bake using NavigationServer3D.bake_from_source_geometry_data()
## 4. Save to assets/navmeshes/[cell_id].res
##
## Terrain3D Integration:
## - If terrain_3d is set, uses Terrain3D's optimized generate_nav_mesh_source_geometry()
## - Otherwise, falls back to manual LAND heightmap processing
## - Terrain3D method matches RuntimeNavigationBaker for consistency
##
## Usage (Offline Prebaking):
##   var baker := NavMeshBaker.new()
##   baker.output_dir = "res://assets/navmeshes"
##   baker.bake_all_cells()  # Uses LAND heightmap (no Terrain3D needed)
##
## Usage (Runtime/Editor with Terrain3D):
##   var baker := NavMeshBaker.new()
##   baker.terrain_3d = get_node("Terrain3D")  # Use Terrain3D's optimized method
##   baker.simplify_terrain = true  # Reduce polygon count
##   baker.bake_all_cells()
class_name NavMeshBaker
extends RefCounted

const NavMeshConfig := preload("res://src/core/navigation/navmesh_config.gd")
const CS := preload("res://src/core/coordinate_system.gd")
const NIFConverter := preload("res://src/core/nif/nif_converter.gd")

## Output directory for navmesh assets
var output_dir: String = "res://assets/navmeshes"

## Optional Terrain3D instance for runtime baking (when available)
## If set, uses Terrain3D's optimized generate_nav_mesh_source_geometry()
## If null, falls back to manual LAND heightmap processing (for offline prebaking)
var terrain_3d: Node = null

## Filter settings
var bake_exterior_cells: bool = true
var bake_interior_cells: bool = false  # Interior cells off by default (can be large)
var skip_existing: bool = true         # Skip cells that already have baked navmesh

## Simplify terrain mesh for navmesh (reduces polygon count)
## Only used when terrain_3d is available, ignored for LAND-based generation
var simplify_terrain: bool = true

## Progress tracking
signal progress(current: int, total: int, cell_id: String)
signal cell_baked(cell_id: String, success: bool, output_path: String, polygon_count: int)
signal batch_complete(total: int, success_count: int, failed_count: int)

## Statistics
var _total_baked: int = 0
var _total_failed: int = 0
var _total_skipped: int = 0
var _failed_cells: Array[String] = []
var _bake_times: Array[float] = []  # Track baking time per cell


## Set Terrain3D instance from scene tree (helper method)
## Searches for Terrain3D node in the main scene
func set_terrain3d_from_scene(root: Node) -> bool:
	var terrain := _find_terrain3d_recursive(root)
	if terrain:
		terrain_3d = terrain
		print("NavMeshBaker: Found Terrain3D instance, will use optimized navmesh generation")
		return true
	else:
		print("NavMeshBaker: No Terrain3D found, will use LAND heightmap fallback")
		return false


## Recursively search for Terrain3D node
func _find_terrain3d_recursive(node: Node) -> Node:
	# Check if this node is Terrain3D
	if node.get_class() == "Terrain3D":
		return node

	# Search children
	for child in node.get_children():
		var result := _find_terrain3d_recursive(child)
		if result:
			return result

	return null


## Initialize the baker
func initialize() -> Error:
	# Validate NavMeshConfig
	var validation := NavMeshConfig.validate_config()
	if not validation.valid:
		push_error("NavMeshBaker: Invalid NavMeshConfig: %s" % ", ".join(validation.errors))
		return ERR_INVALID_PARAMETER

	if not validation.warnings.is_empty():
		push_warning("NavMeshBaker: Config warnings: %s" % ", ".join(validation.warnings))

	# Create output directory
	if not DirAccess.dir_exists_absolute(output_dir):
		var err := DirAccess.make_dir_recursive_absolute(output_dir)
		if err != OK:
			push_error("NavMeshBaker: Failed to create output directory: %s" % output_dir)
			return err

	print("NavMeshBaker: Initialized")
	print(NavMeshConfig.get_config_summary())
	print("  Output: %s" % output_dir)
	return OK


## Bake all cells from ESMManager
func bake_all_cells() -> Dictionary:
	if initialize() != OK:
		return {"total": 0, "success": 0, "failed": 0, "skipped": 0}

	_total_baked = 0
	_total_failed = 0
	_total_skipped = 0
	_failed_cells.clear()
	_bake_times.clear()

	# Get all cells from ESMManager
	var cells_to_bake: Array[CellRecord] = []
	for cell_id in ESMManager.cells:
		var cell: CellRecord = ESMManager.cells[cell_id]
		if not cell:
			continue

		# Filter by interior/exterior
		if cell.is_interior() and not bake_interior_cells:
			continue
		if not cell.is_interior() and not bake_exterior_cells:
			continue

		cells_to_bake.append(cell)

	print("NavMeshBaker: Found %d cells to bake" % cells_to_bake.size())

	# Bake each cell
	for i in range(cells_to_bake.size()):
		var cell := cells_to_bake[i]
		var cell_id := _get_cell_id(cell)

		progress.emit(i + 1, cells_to_bake.size(), cell_id)

		# Check if already exists
		if skip_existing and _navmesh_exists(cell_id):
			print("  [%d/%d] %s - SKIPPED (already exists)" % [i + 1, cells_to_bake.size(), cell_id])
			_total_skipped += 1
			continue

		var result := bake_cell(cell)
		if result.success:
			_total_baked += 1
			_bake_times.append(result.bake_time)
		else:
			_total_failed += 1
			_failed_cells.append(cell_id)

	# Complete
	var total := cells_to_bake.size()
	batch_complete.emit(total, _total_baked, _total_failed)

	# Statistics
	var avg_time := 0.0
	if not _bake_times.is_empty():
		avg_time = _bake_times.reduce(func(sum, t): return sum + t, 0.0) / _bake_times.size()

	print("\nNavMeshBaker: Batch complete")
	print("  Total: %d" % total)
	print("  Baked: %d" % _total_baked)
	print("  Skipped: %d" % _total_skipped)
	print("  Failed: %d" % _total_failed)
	if _total_baked > 0:
		print("  Avg bake time: %.2fs" % avg_time)

	if not _failed_cells.is_empty():
		print("  Failed cells: %s" % ", ".join(_failed_cells))

	return {
		"total": total,
		"success": _total_baked,
		"failed": _total_failed,
		"skipped": _total_skipped,
		"failed_cells": _failed_cells.duplicate(),
		"avg_bake_time": avg_time
	}


## Bake navmesh for a single cell
## Returns: Dictionary with { success: bool, output_path: String, polygon_count: int, bake_time: float }
func bake_cell(cell: CellRecord) -> Dictionary:
	var cell_id := _get_cell_id(cell)
	var start_time := Time.get_ticks_msec()

	print("NavMeshBaker: Baking %s..." % cell_id)

	# Create NavigationMesh
	var nav_mesh := NavMeshConfig.create_navmesh()

	# Parse cell geometry
	var source_geometry := NavigationMeshSourceGeometryData3D.new()
	var parse_result := _parse_cell_geometry(cell, source_geometry)

	if not parse_result.success:
		var error := parse_result.error
		push_warning("NavMeshBaker: Failed to parse geometry - %s: %s" % [cell_id, error])
		cell_baked.emit(cell_id, false, "", 0)
		return {"success": false, "output_path": "", "polygon_count": 0, "error": error, "bake_time": 0.0}

	# Check if we have any geometry
	if source_geometry.get_vertices().size() == 0:
		var error := "No walkable geometry found"
		push_warning("NavMeshBaker: %s - %s" % [cell_id, error])
		cell_baked.emit(cell_id, false, "", 0)
		return {"success": false, "output_path": "", "polygon_count": 0, "error": error, "bake_time": 0.0}

	# Bake navmesh using NavigationServer3D
	# Note: Using synchronous bake for preprocessing (headless mode doesn't need async)
	NavigationServer3D.bake_from_source_geometry_data(nav_mesh, source_geometry)

	# Check result
	var polygon_count := nav_mesh.get_polygon_count()
	if polygon_count == 0:
		var error := "Baking produced empty navmesh"
		push_warning("NavMeshBaker: %s - %s" % [cell_id, error])
		cell_baked.emit(cell_id, false, "", 0)
		return {"success": false, "output_path": "", "polygon_count": 0, "error": error, "bake_time": 0.0}

	# Save to disk
	var output_path := _get_output_path(cell_id)
	var save_err := ResourceSaver.save(nav_mesh, output_path)
	if save_err != OK:
		var error := "Failed to save navmesh: error %d" % save_err
		push_warning("NavMeshBaker: %s - %s" % [cell_id, error])
		cell_baked.emit(cell_id, false, "", polygon_count)
		return {"success": false, "output_path": "", "polygon_count": polygon_count, "error": error, "bake_time": 0.0}

	var bake_time := (Time.get_ticks_msec() - start_time) / 1000.0
	print("  Success: %d polygons, %.2fs" % [polygon_count, bake_time])

	cell_baked.emit(cell_id, true, output_path, polygon_count)
	return {
		"success": true,
		"output_path": output_path,
		"polygon_count": polygon_count,
		"bake_time": bake_time
	}


## Parse cell geometry into NavigationMeshSourceGeometryData3D
func _parse_cell_geometry(cell: CellRecord, source_geometry: NavigationMeshSourceGeometryData3D) -> Dictionary:
	var mesh_count := 0

	# Get cell origin position in Godot coordinates
	var cell_origin := _get_cell_origin(cell)

	# 1. Add terrain (LAND record)
	if not cell.is_interior():
		var land_result := _add_terrain_geometry(cell, cell_origin, source_geometry)
		if land_result.success:
			mesh_count += 1

	# 2. Add static objects from cell references
	var objects_result := _add_object_geometry(cell, cell_origin, source_geometry)
	mesh_count += objects_result.mesh_count

	print("    Parsed %d meshes for cell" % mesh_count)

	return {
		"success": true,
		"mesh_count": mesh_count
	}


## Add terrain geometry from LAND record or Terrain3D
func _add_terrain_geometry(cell: CellRecord, cell_origin: Vector3, source_geometry: NavigationMeshSourceGeometryData3D) -> Dictionary:
	# Use Terrain3D's optimized method if available
	if terrain_3d and _has_terrain3d_method():
		return _add_terrain3d_geometry(cell, cell_origin, source_geometry)
	else:
		# Fallback to LAND heightmap processing (for offline prebaking)
		return _add_land_heightmap_geometry(cell, cell_origin, source_geometry)


## Add terrain geometry using Terrain3D's optimized method
func _add_terrain3d_geometry(cell: CellRecord, cell_origin: Vector3, source_geometry: NavigationMeshSourceGeometryData3D) -> Dictionary:
	if not terrain_3d:
		return {"success": false}

	# Calculate AABB for this cell (117m × 117m cell)
	var cell_aabb := AABB(
		cell_origin,
		Vector3(CS.CELL_SIZE_GODOT, 1000.0, CS.CELL_SIZE_GODOT)  # Height generous for mountains
	)

	# Use Terrain3D's optimized navmesh source geometry generation
	# This is the same method used by RuntimeNavigationBaker
	var faces: PackedVector3Array = terrain_3d.generate_nav_mesh_source_geometry(cell_aabb, simplify_terrain)

	if faces.is_empty():
		# No terrain in this cell, or all non-navigable
		return {"success": false}

	# Add faces to source geometry
	source_geometry.add_faces(faces, Transform3D.IDENTITY)

	print("    Using Terrain3D optimized geometry: %d triangles" % (faces.size() / 9))
	return {"success": true}


## Add terrain geometry from LAND heightmap (offline prebaking fallback)
func _add_land_heightmap_geometry(cell: CellRecord, cell_origin: Vector3, source_geometry: NavigationMeshSourceGeometryData3D) -> Dictionary:
	var land: LandRecord = ESMManager.get_land(cell.grid_x, cell.grid_y)
	if not land or not land.has_heights():
		return {"success": false}

	# Generate terrain mesh from heightmap
	var terrain_mesh := _create_terrain_mesh_from_land(land, cell_origin)
	if not terrain_mesh:
		return {"success": false}

	# Add to source geometry
	var transform := Transform3D.IDENTITY
	source_geometry.add_mesh(terrain_mesh, transform)

	return {"success": true}


## Check if Terrain3D has the navmesh generation method
func _has_terrain3d_method() -> bool:
	if not terrain_3d:
		return false
	return terrain_3d.has_method("generate_nav_mesh_source_geometry")


## Create mesh from LAND record heightmap
func _create_terrain_mesh_from_land(land: LandRecord, cell_origin: Vector3) -> ArrayMesh:
	const GRID_SIZE := 65  # Morrowind heightmap is 65x65 vertices
	const SPACING := CS.CELL_SIZE_GODOT / 64.0  # ~1.83m per vertex

	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()

	# Generate vertices from heightmap
	for y in range(GRID_SIZE):
		for x in range(GRID_SIZE):
			var height_mw := land.get_height(x, y)
			var height_godot := height_mw / CS.UNITS_PER_METER

			var vertex := Vector3(
				x * SPACING,
				height_godot,
				-y * SPACING  # Flip Z (Godot uses -Z forward)
			)
			vertices.append(vertex)

	# Generate triangle indices
	for y in range(GRID_SIZE - 1):
		for x in range(GRID_SIZE - 1):
			var i0 := y * GRID_SIZE + x
			var i1 := y * GRID_SIZE + (x + 1)
			var i2 := (y + 1) * GRID_SIZE + x
			var i3 := (y + 1) * GRID_SIZE + (x + 1)

			# Two triangles per quad
			indices.append(i0)
			indices.append(i2)
			indices.append(i1)

			indices.append(i1)
			indices.append(i2)
			indices.append(i3)

	# Create mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	return mesh


## Add object geometry from cell references
func _add_object_geometry(cell: CellRecord, cell_origin: Vector3, source_geometry: NavigationMeshSourceGeometryData3D) -> Dictionary:
	var mesh_count := 0

	# Load cell references if needed
	if cell.references.is_empty():
		ESMManager.load_cell_references(cell)

	# Process each reference
	for ref in cell.references:
		# Skip disabled/deleted references
		if ref.deleted:
			continue

		# Get object type (NIF path or base object)
		var nif_path := _get_reference_nif_path(ref)
		if nif_path.is_empty():
			continue

		# Skip non-static objects (activators, containers, doors may not be walkable)
		# For now, only include static objects and buildings
		# TODO: Add more sophisticated filtering based on object flags
		if not _is_walkable_object(ref):
			continue

		# Load NIF mesh
		var mesh := _load_nif_collision_mesh(nif_path)
		if not mesh:
			continue

		# Get reference transform
		var transform := _get_reference_transform(ref, cell_origin)

		# Add to source geometry
		source_geometry.add_mesh(mesh, transform)
		mesh_count += 1

	return {"mesh_count": mesh_count}


## Get NIF path from cell reference
func _get_reference_nif_path(ref) -> String:
	# Try to get base object
	var base_obj = ESMManager.get_object(ref.ref_id)
	if not base_obj:
		return ""

	# Get model path from base object
	if base_obj.has("model") and not base_obj.model.is_empty():
		return base_obj.model

	return ""


## Check if object should be included in navmesh
func _is_walkable_object(ref) -> bool:
	# Get base object
	var base_obj = ESMManager.get_object(ref.ref_id)
	if not base_obj:
		return false

	# Get record type
	var rec_type := base_obj.get_record_type() if base_obj.has_method("get_record_type") else -1

	# Include static objects, buildings, misc items
	const ESMDefs := preload("res://src/core/esm/esm_defs.gd")
	return rec_type in [
		ESMDefs.RecordType.REC_STAT,  # Static objects (rocks, trees, buildings)
		# Add more types as needed
	]


## Load collision mesh from NIF file
func _load_nif_collision_mesh(nif_path: String) -> ArrayMesh:
	# Load NIF file from BSA/filesystem
	var bsa_data := BSAManager.load_file(nif_path)
	if bsa_data.is_empty():
		return null

	# Convert NIF to Godot scene
	var converter := NIFConverter.new()
	converter.load_textures = false  # Don't need textures for collision
	converter.load_animations = false  # Don't need animations
	converter.load_collision = false  # We'll extract visual geometry directly
	converter.collision_mode = NIFConverter.CollisionBuilder.CollisionMode.TRIMESH

	var scene := converter.convert_buffer(bsa_data, nif_path)
	if not scene:
		return null

	# Extract meshes from scene
	var combined_mesh := _extract_and_combine_meshes(scene)

	# Clean up
	scene.queue_free()

	return combined_mesh


## Extract all MeshInstance3D nodes and combine into single mesh
func _extract_and_combine_meshes(node: Node) -> ArrayMesh:
	var all_vertices := PackedVector3Array()
	var all_indices := PackedInt32Array()
	var vertex_offset := 0

	_recursively_extract_meshes(node, Transform3D.IDENTITY, all_vertices, all_indices, vertex_offset)

	if all_vertices.is_empty():
		return null

	# Create combined mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = all_vertices
	arrays[Mesh.ARRAY_INDEX] = all_indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	return mesh


## Recursively extract meshes from node hierarchy
func _recursively_extract_meshes(node: Node, parent_transform: Transform3D, vertices: PackedVector3Array, indices: PackedInt32Array, vertex_offset: int) -> int:
	var current_transform := parent_transform

	if node is Node3D:
		current_transform = parent_transform * node.transform

	# Extract mesh if this is a MeshInstance3D
	if node is MeshInstance3D:
		var mesh_inst := node as MeshInstance3D
		var mesh := mesh_inst.mesh
		if mesh:
			for surf_idx in range(mesh.get_surface_count()):
				var surf_arrays := mesh.surface_get_arrays(surf_idx)
				if surf_arrays[Mesh.ARRAY_VERTEX]:
					var surf_verts: PackedVector3Array = surf_arrays[Mesh.ARRAY_VERTEX]
					var surf_indices: PackedInt32Array = surf_arrays[Mesh.ARRAY_INDEX] if surf_arrays[Mesh.ARRAY_INDEX] else PackedInt32Array()

					# Transform vertices
					for v in surf_verts:
						vertices.append(current_transform * v)

					# Add indices with offset
					if not surf_indices.is_empty():
						for idx in surf_indices:
							indices.append(idx + vertex_offset)
					else:
						# Generate indices if none (non-indexed mesh)
						for i in range(surf_verts.size()):
							indices.append(i + vertex_offset)

					vertex_offset += surf_verts.size()

	# Recurse to children
	for child in node.get_children():
		vertex_offset = _recursively_extract_meshes(child, current_transform, vertices, indices, vertex_offset)

	return vertex_offset


## Get reference transform in world space
func _get_reference_transform(ref, cell_origin: Vector3) -> Transform3D:
	var transform := Transform3D.IDENTITY

	# Position
	if ref.has("position"):
		var pos := ref.position
		transform.origin = Vector3(
			pos.x / CS.UNITS_PER_METER,
			pos.z / CS.UNITS_PER_METER,  # Z-up in MW, Y-up in Godot
			-pos.y / CS.UNITS_PER_METER  # Y in MW = -Z in Godot
		) + cell_origin

	# Rotation (Euler angles in radians)
	if ref.has("rotation"):
		var rot := ref.rotation
		# Convert MW rotation (XYZ Euler) to Godot
		var basis := Basis.from_euler(Vector3(rot.x, rot.y, rot.z))
		transform.basis = basis

	# Scale
	if ref.has("scale"):
		transform = transform.scaled(Vector3.ONE * ref.scale)

	return transform


## Get cell origin in Godot world coordinates
func _get_cell_origin(cell: CellRecord) -> Vector3:
	if cell.is_interior():
		return Vector3.ZERO

	# Exterior cells use grid coordinates
	return Vector3(
		cell.grid_x * CS.CELL_SIZE_GODOT,
		0.0,
		-cell.grid_y * CS.CELL_SIZE_GODOT  # Flip Y -> -Z
	)


## Get cell identifier string
func _get_cell_id(cell: CellRecord) -> String:
	if cell.is_interior():
		# Interior cells use name
		return cell.name.replace(" ", "_").replace(",", "").to_lower()
	else:
		# Exterior cells use grid coordinates
		return "%d_%d" % [cell.grid_x, cell.grid_y]


## Get output path for navmesh resource
func _get_output_path(cell_id: String) -> String:
	return output_dir.path_join("%s.res" % cell_id)


## Check if navmesh already exists
func _navmesh_exists(cell_id: String) -> bool:
	var path := _get_output_path(cell_id)
	return FileAccess.file_exists(path)
