## NIF Converter - Converts NIF models to Godot scenes/meshes
## Creates Node3D hierarchy with MeshInstance3D nodes
## Supports skinned meshes with Skeleton3D, animations, and collision shapes
class_name NIFConverter
extends RefCounted

# Preload dependencies
const Defs := preload("res://src/core/nif/nif_defs.gd")
const Reader := preload("res://src/core/nif/nif_reader.gd")
const TexLoader := preload("res://src/core/texture/texture_loader.gd")
const SkeletonBuilder := preload("res://src/core/nif/nif_skeleton_builder.gd")
const AnimationConverter := preload("res://src/core/nif/nif_animation_converter.gd")
const CollisionBuilder := preload("res://src/core/nif/nif_collision_builder.gd")

# The NIFReader instance
var _reader: Reader = null

# Skeleton builder for skinned meshes
var _skeleton_builder: SkeletonBuilder = null

# Animation converter for keyframe data
var _animation_converter: AnimationConverter = null

# Collision builder for physics shapes
var _collision_builder: CollisionBuilder = null

# Whether to load textures during conversion
var load_textures: bool = true

# Whether to extract animations during conversion
var load_animations: bool = true

# Whether to generate collision shapes during conversion
var load_collision: bool = true

## Collision mode for geometry-based collision
## See CollisionBuilder.CollisionMode for options:
## - TRIMESH: Full triangle mesh (accurate but slow) - best for architecture
## - CONVEX: Convex hull (fast, good for most objects)
## - AUTO_PRIMITIVE: Auto-detect best primitive shape (sphere, cylinder, box, capsule)
## - PRIMITIVE_ONLY: Only use primitives, skip if can't detect (fastest)
var collision_mode: int = CollisionBuilder.CollisionMode.AUTO_PRIMITIVE

## Whether to auto-select collision mode based on NIF path
## When true, architecture uses TRIMESH, items use AUTO_PRIMITIVE, etc.
var auto_collision_mode: bool = true

## Tolerance for primitive shape detection (0.0 = strict, 1.0 = loose)
var collision_detection_tolerance: float = 0.15

# Debug mode for skeleton/skinning output
var debug_skinning: bool = false

# Debug mode for animation output
var debug_animations: bool = false

# Debug mode for collision output
var debug_collision: bool = false

# Source path for auto collision mode detection
var _source_path: String = ""

# Cache for converted resources
var _mesh_cache: Dictionary = {}  # record_index -> ArrayMesh
var _material_cache: Dictionary = {}  # hash -> StandardMaterial3D

# Skeleton cache for this conversion (skin_instance_index -> Skeleton3D)
var _skeleton_cache: Dictionary = {}

## Convert a NIF file to a Godot Node3D scene
## Returns the root Node3D or null on failure
func convert_file(path: String) -> Node3D:
	_source_path = path
	_reader = Reader.new()
	var result := _reader.load_file(path)
	if result != OK:
		return null
	return _convert()

## Convert a NIF buffer to a Godot Node3D scene
## path_hint is optional but helps auto-detect collision mode
func convert_buffer(data: PackedByteArray, path_hint: String = "") -> Node3D:
	_source_path = path_hint
	_reader = Reader.new()
	var result := _reader.load_buffer(data)
	if result != OK:
		return null
	return _convert()

## Internal conversion after parsing
func _convert() -> Node3D:
	_mesh_cache.clear()
	_material_cache.clear()
	_skeleton_cache.clear()

	# Initialize skeleton builder
	_skeleton_builder = SkeletonBuilder.new()
	_skeleton_builder.init(_reader)
	_skeleton_builder.debug_mode = debug_skinning

	# Initialize collision builder
	_collision_builder = CollisionBuilder.new()
	_collision_builder.init(_reader)
	_collision_builder.debug_mode = debug_collision
	_collision_builder.detection_tolerance = collision_detection_tolerance

	# Set collision mode - auto-detect from path or use configured mode
	if auto_collision_mode and not _source_path.is_empty():
		_collision_builder.collision_mode = CollisionBuilder.get_recommended_mode(_source_path)
		if debug_collision:
			print("NIFConverter: Auto-selected collision mode %d for %s" % [
				_collision_builder.collision_mode, _source_path.get_file()
			])
	else:
		_collision_builder.collision_mode = collision_mode

	if _reader.roots.is_empty():
		push_error("NIFConverter: No root nodes")
		return null

	# Check if this NIF has skinning - if so, we need to create skeleton first
	var has_skinning := _has_skinning_data()

	# Create root node
	# All transforms, vertices, and normals are converted from NIF coordinates
	# (Z-up, Y-forward) to Godot coordinates (Y-up, Z-back) during conversion.
	var root := Node3D.new()
	root.name = "NIFRoot"

	# If we have skinning, create the skeleton and add it to root first
	var skeleton: Skeleton3D = null
	if has_skinning:
		skeleton = _create_skeleton_for_nif()
		if skeleton:
			root.add_child(skeleton)
			if debug_skinning:
				print("NIFConverter: Created skeleton with %d bones" % skeleton.get_bone_count())

	# Convert each root
	for root_idx in _reader.roots:
		var record := _reader.get_record(root_idx)
		if record == null:
			continue

		var node := _convert_record(record, skeleton)
		if node:
			# If we have a skeleton, skinned meshes should be children of it
			if skeleton and _is_skinned_subtree(record):
				skeleton.add_child(node)
			else:
				root.add_child(node)

	# Post-process: Link skinned meshes to skeleton
	if skeleton:
		_link_skinned_meshes_to_skeleton(root, skeleton)

	# Extract and add animations if enabled
	if load_animations and _has_animation_data():
		var anim_player := _create_animation_player(skeleton)
		if anim_player:
			root.add_child(anim_player)
			if debug_animations:
				print("NIFConverter: Created AnimationPlayer with %d animations" % anim_player.get_animation_library("").get_animation_list().size())

	# Build and add collision shapes if enabled
	if load_collision:
		var collision_result := _collision_builder.build_collision()
		if collision_result.has_collision:
			var static_body := _collision_builder.create_static_body(collision_result)
			if static_body:
				root.add_child(static_body)
				if debug_collision:
					print("NIFConverter: Created StaticBody3D with %d collision shapes" % collision_result.collision_shapes.size())

			# Store actor collision info as metadata for later use
			if collision_result.has_actor_collision_box:
				root.set_meta("actor_collision_center", collision_result.bounding_box_center)
				root.set_meta("actor_collision_extents", collision_result.bounding_box_extents)

	return root


## Recursively find skinned meshes and link them to the skeleton
func _link_skinned_meshes_to_skeleton(node: Node, skeleton: Skeleton3D) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.has_meta("_has_skeleton"):
			# Set the skeleton path - need to compute relative path from mesh to skeleton
			mesh_instance.skeleton = mesh_instance.get_path_to(skeleton)
			mesh_instance.remove_meta("_has_skeleton")

			if debug_skinning:
				print("NIFConverter: Linked '%s' to skeleton (path=%s)" % [
					mesh_instance.name, mesh_instance.skeleton
				])

	# Recurse into children
	for child in node.get_children():
		_link_skinned_meshes_to_skeleton(child, skeleton)


## Check if this NIF has any skinning data
func _has_skinning_data() -> bool:
	for record in _reader.records:
		if record is Defs.NiSkinInstance:
			return true
	return false


## Check if a record or its children contain skinned geometry
func _is_skinned_subtree(record: Defs.NIFRecord) -> bool:
	if record is Defs.NiGeometry:
		var geom := record as Defs.NiGeometry
		return geom.skin_index >= 0

	if record is Defs.NiNode:
		var node := record as Defs.NiNode
		for child_idx in node.children_indices:
			if child_idx < 0:
				continue
			var child := _reader.get_record(child_idx)
			if child and _is_skinned_subtree(child):
				return true

	return false


## Create the skeleton for this NIF (finds first skin instance)
func _create_skeleton_for_nif() -> Skeleton3D:
	# Find the first NiSkinInstance
	for record in _reader.records:
		if record is Defs.NiSkinInstance:
			var skin_instance := record as Defs.NiSkinInstance
			var skeleton := _skeleton_builder.build_skeleton(skin_instance)
			if skeleton:
				_skeleton_cache[record.record_index] = skeleton
				return skeleton

	return null


## Convert a record to a Godot node
func _convert_record(record: Defs.NIFRecord, skeleton: Skeleton3D = null) -> Node3D:
	if record == null:
		return null

	if record is Defs.NiNode:
		return _convert_ni_node(record as Defs.NiNode, skeleton)
	elif record is Defs.NiTriShape:
		return _convert_ni_tri_shape(record as Defs.NiTriShape, skeleton)
	elif record is Defs.NiTriStrips:
		return _convert_ni_tri_strips(record as Defs.NiTriStrips, skeleton)
	else:
		return null

## Convert a Transform3D from NIF coordinates to Godot coordinates
static func _convert_nif_transform(transform: Transform3D) -> Transform3D:
	# Convert origin
	var converted_origin := _convert_nif_vector3(transform.origin)

	# Convert basis using C * R * C^T where C is the coordinate conversion
	var basis := transform.basis
	var converted_basis := Basis(
		Vector3(basis.x.x, basis.x.z, -basis.x.y),   # First column
		Vector3(basis.z.x, basis.z.z, -basis.z.y),   # Second column (was Z)
		Vector3(-basis.y.x, -basis.y.z, basis.y.y)   # Third column (was -Y)
	)

	return Transform3D(converted_basis, converted_origin)


## Convert NiNode to Node3D
func _convert_ni_node(ni_node: Defs.NiNode, skeleton: Skeleton3D = null) -> Node3D:
	var node := Node3D.new()
	node.name = ni_node.name if ni_node.name else "Node_%d" % ni_node.record_index

	# Apply transform - convert from NIF to Godot coordinates
	node.transform = _convert_nif_transform(ni_node.transform.to_transform3d())

	# Hide if flagged
	if ni_node.is_hidden():
		node.visible = false

	# Convert children
	for child_idx in ni_node.children_indices:
		if child_idx < 0:
			continue
		var child_record := _reader.get_record(child_idx)
		var child_node := _convert_record(child_record, skeleton)
		if child_node:
			node.add_child(child_node)

	return node

## Convert NiTriShape to MeshInstance3D
func _convert_ni_tri_shape(shape: Defs.NiTriShape, skeleton: Skeleton3D = null) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = shape.name if shape.name else "Mesh_%d" % shape.record_index

	# Apply transform - convert from NIF to Godot coordinates
	# (for skinned meshes, this is typically identity)
	mesh_instance.transform = _convert_nif_transform(shape.transform.to_transform3d())

	# Hide if flagged
	if shape.is_hidden():
		mesh_instance.visible = false

	# Get geometry data
	if shape.data_index < 0:
		return mesh_instance

	var data_record := _reader.get_record(shape.data_index)
	if data_record == null or not (data_record is Defs.NiTriShapeData):
		return mesh_instance

	var data := data_record as Defs.NiTriShapeData

	# Check if this is a skinned mesh
	var is_skinned := shape.skin_index >= 0 and skeleton != null
	var skin_instance: Defs.NiSkinInstance = null
	var skin_data: Defs.NiSkinData = null

	if is_skinned:
		skin_instance = _reader.get_record(shape.skin_index) as Defs.NiSkinInstance
		if skin_instance and skin_instance.data_index >= 0:
			skin_data = _reader.get_record(skin_instance.data_index) as Defs.NiSkinData

		if debug_skinning:
			print("NIFConverter: Converting skinned mesh '%s'" % mesh_instance.name)

	# Create mesh (with or without skinning data)
	var mesh: ArrayMesh
	if is_skinned and skin_instance and skin_data:
		mesh = _create_skinned_tri_shape_mesh(data, skin_instance, skin_data)
	else:
		mesh = _create_tri_shape_mesh(data)

	if mesh:
		mesh_instance.mesh = mesh

		# Apply material from properties
		var material := _get_material_for_shape(shape)
		if material:
			mesh_instance.material_override = material

		# Link to skeleton for skinned meshes
		if is_skinned and skeleton:
			# The skeleton path is relative from the mesh to the skeleton
			# Since both are children of NIFRoot (or skeleton contains mesh),
			# we need to set this after the scene tree is built
			mesh_instance.set_meta("_has_skeleton", true)

	return mesh_instance

## Convert NiTriStrips to MeshInstance3D
func _convert_ni_tri_strips(strips: Defs.NiTriStrips, skeleton: Skeleton3D = null) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = strips.name if strips.name else "Mesh_%d" % strips.record_index

	# Apply transform - convert from NIF to Godot coordinates
	mesh_instance.transform = _convert_nif_transform(strips.transform.to_transform3d())

	# Hide if flagged
	if strips.is_hidden():
		mesh_instance.visible = false

	# Get geometry data
	if strips.data_index < 0:
		return mesh_instance

	var data_record := _reader.get_record(strips.data_index)
	if data_record == null or not (data_record is Defs.NiTriStripsData):
		return mesh_instance

	var data := data_record as Defs.NiTriStripsData

	# Check if this is a skinned mesh
	var is_skinned := strips.skin_index >= 0 and skeleton != null
	var skin_instance: Defs.NiSkinInstance = null
	var skin_data: Defs.NiSkinData = null

	if is_skinned:
		skin_instance = _reader.get_record(strips.skin_index) as Defs.NiSkinInstance
		if skin_instance and skin_instance.data_index >= 0:
			skin_data = _reader.get_record(skin_instance.data_index) as Defs.NiSkinData

		if debug_skinning:
			print("NIFConverter: Converting skinned strip mesh '%s'" % mesh_instance.name)

	# Create mesh (with or without skinning data)
	var mesh: ArrayMesh
	if is_skinned and skin_instance and skin_data:
		mesh = _create_skinned_tri_strips_mesh(data, skin_instance, skin_data)
	else:
		mesh = _create_tri_strips_mesh(data)

	if mesh:
		mesh_instance.mesh = mesh

		# Apply material from properties
		var material := _get_material_for_shape(strips)
		if material:
			mesh_instance.material_override = material

		# Link to skeleton for skinned meshes
		if is_skinned and skeleton:
			mesh_instance.set_meta("_has_skeleton", true)

	return mesh_instance

## Convert a Vector3 from NIF coordinates (Z-up) to Godot coordinates (Y-up)
static func _convert_nif_vector3(v: Vector3) -> Vector3:
	# NIF: X-right, Y-forward, Z-up
	# Godot: X-right, Y-up, Z-back
	# Transform: x' = x, y' = z, z' = -y
	return Vector3(v.x, v.z, -v.y)


## Convert a PackedVector3Array from NIF to Godot coordinates
static func _convert_nif_vertices(vertices: PackedVector3Array) -> PackedVector3Array:
	var result := PackedVector3Array()
	result.resize(vertices.size())
	for i in range(vertices.size()):
		result[i] = _convert_nif_vector3(vertices[i])
	return result


## Create ArrayMesh from NiTriShapeData
func _create_tri_shape_mesh(data: Defs.NiTriShapeData) -> ArrayMesh:
	if data.vertices.is_empty() or data.triangles.is_empty():
		return null

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	# Vertices - convert from NIF to Godot coordinates
	arrays[Mesh.ARRAY_VERTEX] = _convert_nif_vertices(data.vertices)

	# Normals - convert from NIF to Godot coordinates
	if not data.normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = _convert_nif_vertices(data.normals)

	# UVs (use first UV set)
	if not data.uv_sets.is_empty() and not data.uv_sets[0].is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = data.uv_sets[0]

	# Vertex colors
	if not data.colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = data.colors

	# Indices - flip winding order (NIF uses opposite winding to Godot)
	var flipped_triangles := PackedInt32Array()
	flipped_triangles.resize(data.triangles.size())
	for i in range(0, data.triangles.size(), 3):
		flipped_triangles[i] = data.triangles[i]
		flipped_triangles[i + 1] = data.triangles[i + 2]
		flipped_triangles[i + 2] = data.triangles[i + 1]
	arrays[Mesh.ARRAY_INDEX] = flipped_triangles

	# Create mesh
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	return mesh

## Create ArrayMesh from NiTriStripsData
func _create_tri_strips_mesh(data: Defs.NiTriStripsData) -> ArrayMesh:
	if data.vertices.is_empty() or data.strips.is_empty():
		return null

	# Convert triangle strips to triangle list with flipped winding order
	var triangles := PackedInt32Array()
	for strip in data.strips:
		if strip.size() < 3:
			continue
		# Convert strip to triangles (with flipped winding for Godot)
		for i in range(strip.size() - 2):
			if i % 2 == 0:
				# Even triangles: flip winding (swap indices 1 and 2)
				triangles.append(strip[i])
				triangles.append(strip[i + 2])
				triangles.append(strip[i + 1])
			else:
				# Odd triangles: original strip alternation + flip = normal order
				triangles.append(strip[i])
				triangles.append(strip[i + 1])
				triangles.append(strip[i + 2])

	if triangles.is_empty():
		return null

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	# Convert vertices and normals from NIF to Godot coordinates
	arrays[Mesh.ARRAY_VERTEX] = _convert_nif_vertices(data.vertices)

	if not data.normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = _convert_nif_vertices(data.normals)

	if not data.uv_sets.is_empty() and not data.uv_sets[0].is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = data.uv_sets[0]

	if not data.colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = data.colors

	arrays[Mesh.ARRAY_INDEX] = triangles

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	return mesh


## Create skinned ArrayMesh from NiTriShapeData with bone weights
func _create_skinned_tri_shape_mesh(data: Defs.NiTriShapeData, skin_instance: Defs.NiSkinInstance, skin_data: Defs.NiSkinData) -> ArrayMesh:
	if data.vertices.is_empty() or data.triangles.is_empty():
		return null

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	# Vertices - convert from NIF to Godot coordinates
	arrays[Mesh.ARRAY_VERTEX] = _convert_nif_vertices(data.vertices)

	# Normals - convert from NIF to Godot coordinates
	if not data.normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = _convert_nif_vertices(data.normals)

	# UVs (use first UV set)
	if not data.uv_sets.is_empty() and not data.uv_sets[0].is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = data.uv_sets[0]

	# Vertex colors
	if not data.colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = data.colors

	# Indices - flip winding order (NIF uses opposite winding to Godot)
	var flipped_triangles := PackedInt32Array()
	flipped_triangles.resize(data.triangles.size())
	for i in range(0, data.triangles.size(), 3):
		flipped_triangles[i] = data.triangles[i]
		flipped_triangles[i + 1] = data.triangles[i + 2]
		flipped_triangles[i + 2] = data.triangles[i + 1]
	arrays[Mesh.ARRAY_INDEX] = flipped_triangles

	# Build bone indices and weights
	var skin_arrays := _skeleton_builder.build_skin_arrays(data, skin_instance, skin_data)
	if not skin_arrays.is_empty():
		arrays[Mesh.ARRAY_BONES] = skin_arrays["indices"]
		arrays[Mesh.ARRAY_WEIGHTS] = skin_arrays["weights"]

		if debug_skinning:
			print("  Added bone weights: %d vertices, %d indices, %d weights" % [
				data.num_vertices,
				skin_arrays["indices"].size(),
				skin_arrays["weights"].size()
			])

	# Create mesh
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	return mesh


## Create skinned ArrayMesh from NiTriStripsData with bone weights
func _create_skinned_tri_strips_mesh(data: Defs.NiTriStripsData, skin_instance: Defs.NiSkinInstance, skin_data: Defs.NiSkinData) -> ArrayMesh:
	if data.vertices.is_empty() or data.strips.is_empty():
		return null

	# Convert triangle strips to triangle list with flipped winding order
	var triangles := PackedInt32Array()
	for strip in data.strips:
		if strip.size() < 3:
			continue
		# Convert strip to triangles (with flipped winding for Godot)
		for i in range(strip.size() - 2):
			if i % 2 == 0:
				# Even triangles: flip winding (swap indices 1 and 2)
				triangles.append(strip[i])
				triangles.append(strip[i + 2])
				triangles.append(strip[i + 1])
			else:
				# Odd triangles: original strip alternation + flip = normal order
				triangles.append(strip[i])
				triangles.append(strip[i + 1])
				triangles.append(strip[i + 2])

	if triangles.is_empty():
		return null

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	# Convert vertices and normals from NIF to Godot coordinates
	arrays[Mesh.ARRAY_VERTEX] = _convert_nif_vertices(data.vertices)

	if not data.normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = _convert_nif_vertices(data.normals)

	if not data.uv_sets.is_empty() and not data.uv_sets[0].is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = data.uv_sets[0]

	if not data.colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = data.colors

	arrays[Mesh.ARRAY_INDEX] = triangles

	# Build bone indices and weights
	var skin_arrays := _skeleton_builder.build_skin_arrays(data, skin_instance, skin_data)
	if not skin_arrays.is_empty():
		arrays[Mesh.ARRAY_BONES] = skin_arrays["indices"]
		arrays[Mesh.ARRAY_WEIGHTS] = skin_arrays["weights"]

		if debug_skinning:
			print("  Added bone weights: %d vertices, %d indices, %d weights" % [
				data.num_vertices,
				skin_arrays["indices"].size(),
				skin_arrays["weights"].size()
			])

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	return mesh


## Get material for a geometry shape
func _get_material_for_shape(geom: Defs.NiGeometry) -> StandardMaterial3D:
	var mat_prop: Defs.NiMaterialProperty = null
	var tex_prop: Defs.NiTexturingProperty = null
	var alpha_prop: Defs.NiAlphaProperty = null
	var vc_prop: Defs.NiVertexColorProperty = null

	# Collect properties
	for prop_idx in geom.property_indices:
		if prop_idx < 0:
			continue
		var prop := _reader.get_record(prop_idx)
		if prop is Defs.NiMaterialProperty:
			mat_prop = prop
		elif prop is Defs.NiTexturingProperty:
			tex_prop = prop
		elif prop is Defs.NiAlphaProperty:
			alpha_prop = prop
		elif prop is Defs.NiVertexColorProperty:
			vc_prop = prop

	# Check if we have any properties
	if mat_prop == null and tex_prop == null:
		return null

	# Create material
	var material := StandardMaterial3D.new()

	# Apply material properties
	if mat_prop:
		material.albedo_color = mat_prop.diffuse
		material.emission = mat_prop.emissive
		material.emission_enabled = mat_prop.emissive.r > 0 or mat_prop.emissive.g > 0 or mat_prop.emissive.b > 0
		material.metallic_specular = mat_prop.glossiness / 128.0  # Normalize

	# Apply alpha property
	if alpha_prop:
		if alpha_prop.blend_enabled():
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		if alpha_prop.test_enabled():
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			material.alpha_scissor_threshold = alpha_prop.threshold / 255.0

	# Apply vertex colors
	if vc_prop:
		material.vertex_color_use_as_albedo = true

	# Texture loading
	if tex_prop and not tex_prop.textures.is_empty():
		var base_tex := tex_prop.textures[0] if tex_prop.textures.size() > 0 else null
		if base_tex and base_tex.has_texture and base_tex.source_index >= 0:
			var tex_source := _reader.get_record(base_tex.source_index)
			if tex_source is Defs.NiSourceTexture:
				var source := tex_source as Defs.NiSourceTexture
				if load_textures and not source.filename.is_empty():
					# Load texture from BSA
					var texture := TexLoader.load_texture(source.filename)
					if texture:
						material.albedo_texture = texture
				else:
					# Store texture path in metadata for later loading
					material.set_meta("texture_path", source.filename)

	return material

## Get texture paths referenced by this NIF
func get_texture_paths() -> Array[String]:
	var paths: Array[String] = []

	for record in _reader.records:
		if record is Defs.NiSourceTexture:
			var tex := record as Defs.NiSourceTexture
			if tex.is_external and not tex.filename.is_empty():
				# Normalize path
				var path := tex.filename.replace("\\", "/").to_lower()
				if path not in paths:
					paths.append(path)

	return paths

## Get basic mesh info without full conversion
func get_mesh_info() -> Dictionary:
	var info := {
		"version": _reader.get_version_string(),
		"num_records": _reader.get_num_records(),
		"num_roots": _reader.roots.size(),
		"nodes": 0,
		"meshes": 0,
		"total_vertices": 0,
		"total_triangles": 0,
		"textures": [],
		"has_animations": _has_animation_data(),
		"has_skinning": _has_skinning_data()
	}

	for record in _reader.records:
		if record is Defs.NiNode:
			info["nodes"] += 1
		elif record is Defs.NiTriShape or record is Defs.NiTriStrips:
			info["meshes"] += 1
		elif record is Defs.NiTriShapeData:
			var data := record as Defs.NiTriShapeData
			info["total_vertices"] += data.num_vertices
			info["total_triangles"] += data.num_triangles
		elif record is Defs.NiTriStripsData:
			var data := record as Defs.NiTriStripsData
			info["total_vertices"] += data.num_vertices
			info["total_triangles"] += data.num_triangles
		elif record is Defs.NiSourceTexture:
			var tex := record as Defs.NiSourceTexture
			if tex.is_external and tex.filename:
				info["textures"].append(tex.filename)

	return info


## Check if this NIF has any animation data (keyframe controllers)
func _has_animation_data() -> bool:
	for record in _reader.records:
		if record is Defs.NiKeyframeController:
			return true
	return false


## Create AnimationPlayer with animations extracted from NIF
func _create_animation_player(skeleton: Skeleton3D) -> AnimationPlayer:
	# Initialize animation converter
	_animation_converter = AnimationConverter.new()
	_animation_converter.init(_reader, skeleton)
	_animation_converter.debug_mode = debug_animations

	# Try to extract animations by text keys first (named animations)
	var animations := _animation_converter.convert_to_animations_by_text_keys()

	if animations.is_empty():
		# No text keys or animations found
		return null

	# Create AnimationPlayer and AnimationLibrary
	var anim_player := AnimationPlayer.new()
	anim_player.name = "AnimationPlayer"

	var library := AnimationLibrary.new()

	for anim_name in animations:
		var anim: Animation = animations[anim_name]
		if anim:
			var err := library.add_animation(anim_name, anim)
			if err != OK:
				push_warning("NIFConverter: Failed to add animation '%s': %s" % [anim_name, error_string(err)])
			elif debug_animations:
				print("  Added animation '%s' (%.2fs, %d tracks)" % [
					anim_name, anim.length, anim.get_track_count()
				])

	# Add library to player (empty string for default library)
	var lib_err := anim_player.add_animation_library("", library)
	if lib_err != OK:
		push_warning("NIFConverter: Failed to add animation library: %s" % error_string(lib_err))
		return null

	return anim_player


## Get animation info without full conversion
func get_animation_info() -> Dictionary:
	var info := {
		"has_animations": false,
		"controller_count": 0,
		"text_keys": [],
		"animation_names": []
	}

	for record in _reader.records:
		if record is Defs.NiKeyframeController:
			info["has_animations"] = true
			info["controller_count"] += 1
		elif record is Defs.NiTextKeyExtraData:
			var text_key := record as Defs.NiTextKeyExtraData
			for key in text_key.keys:
				info["text_keys"].append({
					"time": key["time"],
					"name": key["value"]
				})

	# Parse animation names from text keys
	var seen_names := {}
	for key in info["text_keys"]:
		var parts: PackedStringArray = key["name"].split(":")
		if parts.size() >= 2:
			var anim_name := parts[0].strip_edges()
			if anim_name not in seen_names:
				seen_names[anim_name] = true
				info["animation_names"].append(anim_name)

	return info


## Get collision info without full conversion
func get_collision_info() -> Dictionary:
	var info := {
		"has_collision": false,
		"has_root_collision_node": false,
		"has_actor_collision_box": false,
		"collision_shape_count": 0,
		"collision_mode": "auto_primitive",
		"detected_shapes": [],
		"shape_types": [],
		"bounding_volumes": [],
		"visual_collision_type": "default"  # "default", "camera", "none"
	}

	if _reader == null:
		return info

	# Initialize collision builder if needed
	if _collision_builder == null:
		_collision_builder = CollisionBuilder.new()
		_collision_builder.init(_reader)
		_collision_builder.detection_tolerance = collision_detection_tolerance
		if auto_collision_mode and not _source_path.is_empty():
			_collision_builder.collision_mode = CollisionBuilder.get_recommended_mode(_source_path)
		else:
			_collision_builder.collision_mode = collision_mode

	var result := _collision_builder.build_collision()

	info["has_collision"] = result.has_collision
	info["has_root_collision_node"] = result.root_collision_node_index >= 0
	info["has_actor_collision_box"] = result.has_actor_collision_box
	info["collision_shape_count"] = result.collision_shapes.size()
	info["detected_shapes"] = result.detected_shapes

	# Report collision mode used
	match _collision_builder.collision_mode:
		CollisionBuilder.CollisionMode.TRIMESH:
			info["collision_mode"] = "trimesh"
		CollisionBuilder.CollisionMode.CONVEX:
			info["collision_mode"] = "convex"
		CollisionBuilder.CollisionMode.AUTO_PRIMITIVE:
			info["collision_mode"] = "auto_primitive"
		CollisionBuilder.CollisionMode.PRIMITIVE_ONLY:
			info["collision_mode"] = "primitive_only"

	# Collect shape types from result
	for shape_data in result.collision_shapes:
		if shape_data.has("type"):
			info["shape_types"].append(shape_data["type"])

	if result.has_actor_collision_box:
		info["actor_collision"] = {
			"center": result.bounding_box_center,
			"extents": result.bounding_box_extents
		}

	match result.visual_collision_type:
		0:
			info["visual_collision_type"] = "default"
		1:
			info["visual_collision_type"] = "camera"

	# Collect bounding volume types from the NIF
	for record in _reader.records:
		if record is Defs.NiAVObject:
			var av_obj := record as Defs.NiAVObject
			if av_obj.has_bounding_volume and av_obj.bounding_volume != null:
				var bv_info := {
					"node_name": av_obj.name,
					"type": _bv_type_to_string(av_obj.bounding_volume.type)
				}
				info["bounding_volumes"].append(bv_info)

	return info


## Convert bounding volume type to string
func _bv_type_to_string(bv_type: int) -> String:
	match bv_type:
		Defs.BV_BASE:
			return "base"
		Defs.BV_SPHERE:
			return "sphere"
		Defs.BV_BOX:
			return "box"
		Defs.BV_CAPSULE:
			return "capsule"
		Defs.BV_LOZENGE:
			return "lozenge"
		Defs.BV_UNION:
			return "union"
		Defs.BV_HALFSPACE:
			return "halfspace"
		_:
			return "unknown"
