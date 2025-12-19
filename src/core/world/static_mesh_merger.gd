## StaticMeshMerger - Combines multiple static meshes into single draw calls
##
## Merges static objects within a cell into a single mesh for efficient
## distant rendering. Used by MID tier (500m-2km) to reduce draw calls.
##
## Key features:
## - Filters objects suitable for merging (static, non-interactive)
## - Applies aggressive mesh simplification (95% reduction)
## - Bakes transforms into vertices
## - Creates simplified materials (albedo only, no normal maps)
## - Caches merged results for reuse
##
## Usage:
##   var merger := StaticMeshMerger.new()
##   merger.mesh_simplifier = simplifier
##   merger.model_loader = loader
##   var merged := merger.merge_cell(cell_grid, cell_references)
class_name StaticMeshMerger
extends RefCounted

# Preload dependencies
const CS := preload("res://src/core/coordinate_system.gd")

## Reference to MeshSimplifier for aggressive LOD generation
var mesh_simplifier: RefCounted = null  # MeshSimplifier

## Reference to ModelLoader for loading prototype meshes
var model_loader: RefCounted = null  # ModelLoader

## Target simplification ratio for distant meshes (0.05 = 95% reduction)
var simplification_target: float = 0.05

## Minimum object size (meters) to include in merged mesh
## Smaller objects are culled at distance anyway
var min_object_size: float = 2.0

## Maximum vertex count per merged mesh (split if exceeded)
var max_vertices_per_mesh: int = 65535

## Cache for merged cell meshes: "cell_x_y" -> MergedCellData
var _merge_cache: Dictionary = {}

## Stats
var _stats := {
	"cells_merged": 0,
	"objects_merged": 0,
	"objects_skipped": 0,
	"cache_hits": 0,
}


## Data structure for merged cell result
class MergedCellData:
	var cell_grid: Vector2i
	var mesh: ArrayMesh
	var material: Material
	var object_count: int
	var vertex_count: int
	var aabb: AABB


## Object types that should be merged (static, non-interactive)
const MERGEABLE_TYPES := [
	"static",
	"activator",  # Signs, markers
	"container",  # Barrels, crates (visual only at distance)
	"door",       # Door frames (visual)
	"light",      # Light fixtures (model only)
]

## Model path patterns that should NOT be merged
const SKIP_PATTERNS := [
	"\\f\\flora_",     # Flora uses StaticObjectRenderer
	"\\f\\furn_",      # Some furniture is interactive
	"\\n\\",           # NPCs
	"\\c\\",           # Creatures
	"_anim",           # Animated objects
	"_movable",        # Movable objects
]

## Model path patterns for large objects that should be included
const INCLUDE_LARGE_PATTERNS := [
	"\\x\\ex_",        # Exterior buildings
	"\\x\\in_",        # Interior structures visible from outside
	"terrain_rock",    # Large rocks
	"bridge",          # Bridges
	"tower",           # Towers
	"wall",            # Walls
	"gate",            # Gates
	"dock",            # Docks
]


## Merge all suitable static objects in a cell into a single mesh
## Returns MergedCellData with the combined mesh, or null if no objects to merge
func merge_cell(cell_grid: Vector2i, references: Array) -> MergedCellData:
	# Check cache first
	var cache_key := "%d_%d" % [cell_grid.x, cell_grid.y]
	if cache_key in _merge_cache:
		_stats["cache_hits"] += 1
		return _merge_cache[cache_key]

	# Filter references to only mergeable objects
	var mergeable_refs := _filter_mergeable_references(references)

	if mergeable_refs.is_empty():
		return null

	# Merge meshes using SurfaceTool
	var surface_tool := SurfaceTool.new()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)

	var merged_count := 0
	var total_vertices := 0
	var combined_aabb := AABB()
	var first_material: Material = null

	for ref_data in mergeable_refs:
		var ref: CellReference = ref_data.ref
		var mesh_arrays: Array = ref_data.mesh_arrays
		var transform: Transform3D = ref_data.transform

		if mesh_arrays.is_empty():
			continue

		# Check vertex limit
		var vertices: PackedVector3Array = mesh_arrays[Mesh.ARRAY_VERTEX]
		if total_vertices + vertices.size() > max_vertices_per_mesh:
			# Would exceed limit - stop here
			break

		# Add mesh to surface tool with baked transform
		_append_mesh_transformed(surface_tool, mesh_arrays, transform)

		# Update AABB
		for vertex in vertices:
			var world_pos := transform * vertex
			if merged_count == 0:
				combined_aabb = AABB(world_pos, Vector3.ZERO)
			else:
				combined_aabb = combined_aabb.expand(world_pos)

		# Capture first material for the merged mesh
		if first_material == null and ref_data.has("material"):
			first_material = ref_data.material

		total_vertices += vertices.size()
		merged_count += 1

	if merged_count == 0:
		return null

	# Generate merged mesh
	surface_tool.generate_normals()
	var merged_mesh := surface_tool.commit()

	# Create simplified material for distant rendering
	var distant_material := _create_distant_material(first_material)

	# Build result
	var result := MergedCellData.new()
	result.cell_grid = cell_grid
	result.mesh = merged_mesh
	result.material = distant_material
	result.object_count = merged_count
	result.vertex_count = total_vertices
	result.aabb = combined_aabb

	# Cache result
	_merge_cache[cache_key] = result

	# Update stats
	_stats["cells_merged"] += 1
	_stats["objects_merged"] += merged_count

	return result


## Filter references to only those suitable for merging
## Returns array of { ref: CellReference, mesh_arrays: Array, transform: Transform3D }
func _filter_mergeable_references(references: Array) -> Array:
	var result := []

	for ref in references:
		if not ref is CellReference:
			continue

		# Get base record
		var record_type: Array = [""]
		var base_record = ESMManager.get_any_record(str(ref.ref_id), record_type)
		if not base_record:
			_stats["objects_skipped"] += 1
			continue

		var type_name: String = record_type[0] if record_type.size() > 0 else ""

		# Check if type is mergeable
		if type_name not in MERGEABLE_TYPES:
			_stats["objects_skipped"] += 1
			continue

		# Get model path
		var model_path: String = _get_model_path(base_record)
		if model_path.is_empty():
			_stats["objects_skipped"] += 1
			continue

		# Check skip patterns
		var should_skip := false
		var lower_path := model_path.to_lower()
		for pattern in SKIP_PATTERNS:
			if pattern in lower_path:
				should_skip = true
				break

		if should_skip:
			_stats["objects_skipped"] += 1
			continue

		# Check if this is a large object we want to include
		var is_large := false
		for pattern in INCLUDE_LARGE_PATTERNS:
			if pattern in lower_path:
				is_large = true
				break

		# Get mesh from model loader
		var mesh_data := _get_simplified_mesh_arrays(model_path, base_record)
		if mesh_data.is_empty():
			_stats["objects_skipped"] += 1
			continue

		# Check object size
		var aabb := _calculate_mesh_aabb(mesh_data)
		var size := maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))

		# Skip small objects unless they're specifically marked as large
		if size < min_object_size and not is_large:
			_stats["objects_skipped"] += 1
			continue

		# Calculate world transform
		var transform := _calculate_transform(ref)

		result.append({
			"ref": ref,
			"mesh_arrays": mesh_data,
			"transform": transform,
			"material": _get_mesh_material(model_path, base_record),
		})

	return result


## Get simplified mesh arrays for a model
## Applies aggressive simplification if mesh_simplifier is available
func _get_simplified_mesh_arrays(model_path: String, base_record) -> Array:
	if not model_loader:
		return []

	# Get prototype from model loader
	var item_id: String = ""
	if "record_id" in base_record:
		item_id = base_record.record_id

	var prototype: Node3D = model_loader.get_model(model_path, item_id)
	if not prototype:
		return []

	# Find first MeshInstance3D
	var mesh_instance := _find_mesh_instance(prototype)
	if not mesh_instance or not mesh_instance.mesh:
		return []

	var mesh: Mesh = mesh_instance.mesh
	if mesh.get_surface_count() == 0:
		return []

	# Get surface arrays
	var arrays := mesh.surface_get_arrays(0)
	if arrays.is_empty():
		return []

	# Apply aggressive simplification if available
	if mesh_simplifier and mesh_simplifier.has_method("simplify"):
		var simplified: Array = mesh_simplifier.simplify(arrays, simplification_target)
		if not simplified.is_empty():
			return simplified

	return arrays


## Get material from mesh
func _get_mesh_material(model_path: String, base_record) -> Material:
	if not model_loader:
		return null

	var item_id: String = ""
	if "record_id" in base_record:
		item_id = base_record.record_id

	var prototype: Node3D = model_loader.get_model(model_path, item_id)
	if not prototype:
		return null

	var mesh_instance := _find_mesh_instance(prototype)
	if not mesh_instance:
		return null

	if mesh_instance.material_override:
		return mesh_instance.material_override

	if mesh_instance.mesh and mesh_instance.mesh.get_surface_count() > 0:
		return mesh_instance.mesh.surface_get_material(0)

	return null


## Find first MeshInstance3D in node hierarchy
func _find_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node

	for child in node.get_children():
		var found := _find_mesh_instance(child)
		if found:
			return found

	return null


## Append mesh arrays to SurfaceTool with transform baked into vertices
func _append_mesh_transformed(surface_tool: SurfaceTool, arrays: Array, transform: Transform3D) -> void:
	if arrays.size() < Mesh.ARRAY_MAX:
		return

	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] else PackedVector3Array()
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] else PackedVector2Array()
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] else PackedInt32Array()

	if vertices.is_empty():
		return

	# If no indices, create sequential indices
	if indices.is_empty():
		for i in range(vertices.size()):
			indices.append(i)

	# Transform basis for normals (rotation only, no scale/translation)
	var normal_basis := transform.basis.inverse().transposed()

	# Add vertices with baked transform
	for i in range(indices.size()):
		var idx := indices[i]

		# Transform vertex position
		var pos := transform * vertices[idx]

		# Transform normal
		var normal := Vector3.UP
		if idx < normals.size():
			normal = (normal_basis * normals[idx]).normalized()

		# UV (no transform needed)
		var uv := Vector2.ZERO
		if idx < uvs.size():
			uv = uvs[idx]

		surface_tool.set_normal(normal)
		surface_tool.set_uv(uv)
		surface_tool.add_vertex(pos)


## Calculate AABB from mesh arrays
func _calculate_mesh_aabb(arrays: Array) -> AABB:
	if arrays.size() < Mesh.ARRAY_VERTEX:
		return AABB()

	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if vertices.is_empty():
		return AABB()

	var aabb := AABB(vertices[0], Vector3.ZERO)
	for i in range(1, vertices.size()):
		aabb = aabb.expand(vertices[i])

	return aabb


## Calculate world transform for a cell reference
func _calculate_transform(ref: CellReference) -> Transform3D:
	var pos := CS.vector_to_godot(ref.position)
	var scale := CS.scale_to_godot(ref.scale)
	var euler := CS.euler_to_godot(ref.rotation)
	var basis := Basis.from_euler(euler, EULER_ORDER_XZY)
	basis = basis.scaled(scale)
	return Transform3D(basis, pos)


## Create simplified material for distant rendering
## Removes normal maps, specular, and other expensive features
func _create_distant_material(source_material: Material) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()

	# Basic settings for distant objects
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX  # Faster than per-pixel
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mat.metallic = 0.0
	mat.roughness = 1.0

	# Copy albedo from source if available
	if source_material is StandardMaterial3D:
		var src: StandardMaterial3D = source_material
		mat.albedo_color = src.albedo_color
		mat.albedo_texture = src.albedo_texture

		# Copy transparency settings if needed
		if src.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			mat.transparency = src.transparency
			mat.alpha_scissor_threshold = src.alpha_scissor_threshold
	elif source_material is ShaderMaterial:
		# Try to extract albedo from shader parameters
		var shader_mat: ShaderMaterial = source_material
		if shader_mat.get_shader_parameter("albedo"):
			mat.albedo_color = shader_mat.get_shader_parameter("albedo")
		if shader_mat.get_shader_parameter("texture_albedo"):
			mat.albedo_texture = shader_mat.get_shader_parameter("texture_albedo")

	return mat


## Get model path from record
func _get_model_path(record) -> String:
	if "model" in record:
		return record.model
	if "model_path" in record:
		return record.model_path
	return ""


## Clear the merge cache
func clear_cache() -> void:
	_merge_cache.clear()


## Remove a specific cell from cache
func remove_from_cache(cell_grid: Vector2i) -> void:
	var cache_key := "%d_%d" % [cell_grid.x, cell_grid.y]
	_merge_cache.erase(cache_key)


## Get statistics
func get_stats() -> Dictionary:
	var stats := _stats.duplicate()
	stats["cache_size"] = _merge_cache.size()
	return stats
