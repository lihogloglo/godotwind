## NIF Converter - Converts NIF models to Godot scenes/meshes
## Creates Node3D hierarchy with MeshInstance3D nodes
class_name NIFConverter
extends RefCounted

# Preload dependencies
const Defs := preload("res://src/core/nif/nif_defs.gd")
const Reader := preload("res://src/core/nif/nif_reader.gd")
const TexLoader := preload("res://src/core/texture/texture_loader.gd")

# The NIFReader instance
var _reader: Reader = null

# Whether to load textures during conversion
var load_textures: bool = true

# Cache for converted resources
var _mesh_cache: Dictionary = {}  # record_index -> ArrayMesh
var _material_cache: Dictionary = {}  # hash -> StandardMaterial3D

## Convert a NIF file to a Godot Node3D scene
## Returns the root Node3D or null on failure
func convert_file(path: String) -> Node3D:
	_reader = Reader.new()
	var result := _reader.load_file(path)
	if result != OK:
		return null
	return _convert()

## Convert a NIF buffer to a Godot Node3D scene
func convert_buffer(data: PackedByteArray) -> Node3D:
	_reader = Reader.new()
	var result := _reader.load_buffer(data)
	if result != OK:
		return null
	return _convert()

## Internal conversion after parsing
func _convert() -> Node3D:
	_mesh_cache.clear()
	_material_cache.clear()

	if _reader.roots.is_empty():
		push_error("NIFConverter: No root nodes")
		return null

	# Create root node with coordinate system conversion
	# NIF uses Z-up, Godot uses Y-up, so rotate -90 degrees around X
	var root := Node3D.new()
	root.name = "NIFRoot"
	root.rotation.x = -PI / 2.0  # Convert Z-up to Y-up

	# Convert each root
	for root_idx in _reader.roots:
		var record := _reader.get_record(root_idx)
		if record == null:
			continue

		var node := _convert_record(record)
		if node:
			root.add_child(node)

	return root


## Convert a record to a Godot node
func _convert_record(record: Defs.NIFRecord) -> Node3D:
	if record == null:
		return null

	if record is Defs.NiNode:
		return _convert_ni_node(record as Defs.NiNode)
	elif record is Defs.NiTriShape:
		return _convert_ni_tri_shape(record as Defs.NiTriShape)
	elif record is Defs.NiTriStrips:
		return _convert_ni_tri_strips(record as Defs.NiTriStrips)
	else:
		return null

## Convert NiNode to Node3D
func _convert_ni_node(ni_node: Defs.NiNode) -> Node3D:
	var node := Node3D.new()
	node.name = ni_node.name if ni_node.name else "Node_%d" % ni_node.record_index

	# Apply transform
	node.transform = ni_node.transform.to_transform3d()

	# Hide if flagged
	if ni_node.is_hidden():
		node.visible = false

	# Convert children
	for child_idx in ni_node.children_indices:
		if child_idx < 0:
			continue
		var child_record := _reader.get_record(child_idx)
		var child_node := _convert_record(child_record)
		if child_node:
			node.add_child(child_node)

	return node

## Convert NiTriShape to MeshInstance3D
func _convert_ni_tri_shape(shape: Defs.NiTriShape) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = shape.name if shape.name else "Mesh_%d" % shape.record_index

	# Apply transform
	mesh_instance.transform = shape.transform.to_transform3d()

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

	# Create mesh
	var mesh := _create_tri_shape_mesh(data)
	if mesh:
		mesh_instance.mesh = mesh

		# Apply material from properties
		var material := _get_material_for_shape(shape)
		if material:
			mesh_instance.material_override = material

	return mesh_instance

## Convert NiTriStrips to MeshInstance3D
func _convert_ni_tri_strips(strips: Defs.NiTriStrips) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = strips.name if strips.name else "Mesh_%d" % strips.record_index

	# Apply transform
	mesh_instance.transform = strips.transform.to_transform3d()

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

	# Create mesh
	var mesh := _create_tri_strips_mesh(data)
	if mesh:
		mesh_instance.mesh = mesh

		# Apply material from properties
		var material := _get_material_for_shape(strips)
		if material:
			mesh_instance.material_override = material

	return mesh_instance

## Create ArrayMesh from NiTriShapeData
func _create_tri_shape_mesh(data: Defs.NiTriShapeData) -> ArrayMesh:
	if data.vertices.is_empty() or data.triangles.is_empty():
		return null

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	# Vertices
	arrays[Mesh.ARRAY_VERTEX] = data.vertices

	# Normals
	if not data.normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = data.normals

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

	arrays[Mesh.ARRAY_VERTEX] = data.vertices

	if not data.normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = data.normals

	if not data.uv_sets.is_empty() and not data.uv_sets[0].is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = data.uv_sets[0]

	if not data.colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = data.colors

	arrays[Mesh.ARRAY_INDEX] = triangles

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
		"textures": []
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
