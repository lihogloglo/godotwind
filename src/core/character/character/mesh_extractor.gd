## MeshExtractor - Extracts raw mesh geometry from Morrowind NIF files
##
## This class extracts ONLY the mesh geometry from NIF files, without any
## skeleton or animation data. The geometry is converted to Godot's coordinate
## system and prepared for rebinding to a humanoid skeleton.
##
## Key difference from NIFConverter: We extract geometry in MESH-LOCAL space,
## not skeleton space. This allows clean rebinding to any skeleton.
class_name MeshExtractor
extends RefCounted


const NIFReader := preload("res://src/core/nif/nif_reader.gd")
const NIFDefs := preload("res://src/core/nif/nif_defs.gd")
const CS := preload("res://src/core/coordinate_system.gd")


## Extracted mesh data container
class MeshData:
	## Raw geometry
	var vertices: PackedVector3Array
	var normals: PackedVector3Array
	var uvs: PackedVector2Array
	var indices: PackedInt32Array

	## Skinning data (if present)
	var bone_names: PackedStringArray  # Original Morrowind bone names
	var bone_weights: Array[PackedFloat32Array] = []  # Array[PackedFloat32Array] per vertex
	var bone_indices: Array[PackedInt32Array] = []  # Array[PackedInt32Array] per vertex
	var inv_bind_poses: Array[Transform3D] = []  # Array[Transform3D] per bone
	var skin_transform: Transform3D = Transform3D.IDENTITY  # NiSkinData overall transform (mesh → skeleton space)

	## Transform data
	var node_transform: Transform3D = Transform3D.IDENTITY  # Accumulated NIF hierarchy transform (in Godot space)
	var parent_bone_name: String = ""  # Parent NiNode name (bone to attach static meshes to)

	## BoneOffset (from NIF "BoneOffset" NiNode, per OpenMW convention)
	var bone_offset_position: Vector3 = Vector3.ZERO  # Translation from BoneOffset node
	var has_bone_offset: bool = false

	## Material info
	var texture_path: String = ""
	var material_properties: Dictionary = {}

	## Metadata
	var source_path: String = ""
	var is_skinned: bool = false

	func get_vertex_count() -> int:
		return vertices.size()

	func get_triangle_count() -> int:
		return indices.size() / 3


## Extract mesh data from a NIF file loaded from BSA
## Uses BSAManager autoload if available
static func extract_from_bsa(bsa_path: String) -> Array[MeshData]:
	# Get BSAManager from autoloads (avoids compile-time dependency)
	var bsa_mgr: Node = null
	var main_loop := Engine.get_main_loop() as SceneTree
	if main_loop and main_loop.root:
		bsa_mgr = main_loop.root.get_node_or_null("/root/BSAManager")

	if not bsa_mgr:
		push_error("MeshExtractor: BSAManager not available")
		return []

	var data: PackedByteArray = bsa_mgr.extract_file(bsa_path)
	if data.is_empty():
		push_error("MeshExtractor: Cannot load NIF from BSA: %s" % bsa_path)
		return []

	return extract_from_buffer(data, bsa_path)


## Extract mesh data from a NIF buffer
static func extract_from_buffer(buffer: PackedByteArray, path_hint: String = "") -> Array[MeshData]:
	var reader := NIFReader.new()
	var err := reader.load_buffer(buffer, path_hint)
	if err != OK:
		push_error("MeshExtractor: Failed to parse NIF: %s" % path_hint)
		return []

	return _extract_from_reader(reader, path_hint)


## Extract all meshes from a parsed NIF
static func _extract_from_reader(reader: NIFReader, source_path: String) -> Array[MeshData]:
	var meshes: Array[MeshData] = []

	# Search for BoneOffset node in the NIF (per OpenMW convention)
	# BoneOffset provides a translation offset for non-skinned body parts
	var bone_offset := Vector3.ZERO
	var found_bone_offset := false
	for root_idx in reader.roots:
		var root := reader.get_record(root_idx)
		if root:
			var offset: Variant = _find_bone_offset(reader, root)
			if offset != null:
				bone_offset = offset
				found_bone_offset = true
				break

	# Process all root nodes
	for root_idx in reader.roots:
		var root := reader.get_record(root_idx)
		if root:
			_extract_recursive(reader, root, Transform3D.IDENTITY, "", meshes, source_path)

	# Apply BoneOffset to all extracted meshes
	if found_bone_offset:
		for mesh in meshes:
			mesh.bone_offset_position = bone_offset
			mesh.has_bone_offset = true

	return meshes


## Search for a "BoneOffset" NiNode in the NIF hierarchy (per OpenMW convention)
## Returns the converted translation vector, or null if not found
static func _find_bone_offset(reader: NIFReader, record: NIFDefs.NIFRecord) -> Variant:
	if record is NIFDefs.NiNode:
		var node := record as NIFDefs.NiNode
		if node.name and node.name.to_lower() == "boneoffset":
			# Extract translation only (OpenMW ignores rotation/scale on BoneOffset)
			var transform := _get_node_transform(node)
			return CS.vector_to_godot(transform.origin)

		# Recurse into children
		for child_idx in node.children_indices:
			if child_idx >= 0:
				var child := reader.get_record(child_idx)
				if child:
					var result: Variant = _find_bone_offset(reader, child)
					if result != null:
						return result

	return null


## Recursively extract meshes from NIF node tree
static func _extract_recursive(
	reader: NIFReader,
	record: NIFDefs.NIFRecord,
	parent_transform: Transform3D,
	parent_node_name: String,
	meshes: Array[MeshData],
	source_path: String
) -> void:
	# Get this node's transform and name
	var local_transform := Transform3D.IDENTITY
	var node_name := ""
	if record is NIFDefs.NiNode or record is NIFDefs.NiGeometry:
		local_transform = _get_node_transform(record)
		if "name" in record and record.name:
			node_name = record.name

	var world_transform := parent_transform * local_transform

	# Check if this is geometry — pass parent_node_name as the bone to attach to
	if record is NIFDefs.NiTriShape:
		var mesh := _extract_tri_shape(reader, record as NIFDefs.NiTriShape, world_transform, source_path)
		if mesh:
			mesh.parent_bone_name = parent_node_name
			meshes.append(mesh)
	elif record is NIFDefs.NiTriStrips:
		var mesh := _extract_tri_strips(reader, record as NIFDefs.NiTriStrips, world_transform, source_path)
		if mesh:
			mesh.parent_bone_name = parent_node_name
			meshes.append(mesh)

	# Process children — pass this node's name as parent_node_name for bone tracking
	if record is NIFDefs.NiNode:
		var node := record as NIFDefs.NiNode
		var current_name := node_name if not node_name.is_empty() else parent_node_name
		for child_idx in node.children_indices:
			if child_idx >= 0:
				var child := reader.get_record(child_idx)
				if child:
					_extract_recursive(reader, child, world_transform, current_name, meshes, source_path)


## Extract from NiTriShape
static func _extract_tri_shape(
	reader: NIFReader,
	shape: NIFDefs.NiTriShape,
	world_transform: Transform3D,
	source_path: String
) -> MeshData:
	if shape.data_index < 0:
		return null

	var data := reader.get_record(shape.data_index) as NIFDefs.NiTriShapeData
	if not data or data.vertices.is_empty():
		return null

	var mesh := MeshData.new()
	mesh.source_path = source_path

	# Store accumulated NIF hierarchy transform (converted to Godot space)
	# Used for static (non-skinned) meshes; skinned meshes use skin_transform instead
	mesh.node_transform = CS.transform_to_godot(world_transform)

	# Convert vertices to Godot space
	mesh.vertices = _convert_vertices(data.vertices)
	mesh.normals = _convert_normals(data.normals) if not data.normals.is_empty() else PackedVector3Array()
	# UV sets are stored as an array - get first UV set if available
	if not data.uv_sets.is_empty() and not data.uv_sets[0].is_empty():
		mesh.uvs = data.uv_sets[0].duplicate()
	else:
		mesh.uvs = PackedVector2Array()
	# Flip winding order - NIF uses opposite winding to Godot after coordinate conversion
	mesh.indices = _flip_winding(data.triangles)

	# Extract skinning data if present
	if shape.skin_index >= 0:
		_extract_skin_data(reader, shape.skin_index, mesh)

	# Extract material/texture info
	_extract_material_info(reader, shape, mesh)

	return mesh


## Extract from NiTriStrips
static func _extract_tri_strips(
	reader: NIFReader,
	strips: NIFDefs.NiTriStrips,
	world_transform: Transform3D,
	source_path: String
) -> MeshData:
	if strips.data_index < 0:
		return null

	var data := reader.get_record(strips.data_index) as NIFDefs.NiTriStripsData
	if not data or data.vertices.is_empty():
		return null

	var mesh := MeshData.new()
	mesh.source_path = source_path

	# Store accumulated NIF hierarchy transform (converted to Godot space)
	mesh.node_transform = CS.transform_to_godot(world_transform)

	# Convert vertices to Godot space
	mesh.vertices = _convert_vertices(data.vertices)
	mesh.normals = _convert_normals(data.normals) if not data.normals.is_empty() else PackedVector3Array()
	# UV sets are stored as an array - get first UV set if available
	if not data.uv_sets.is_empty() and not data.uv_sets[0].is_empty():
		mesh.uvs = data.uv_sets[0].duplicate()
	else:
		mesh.uvs = PackedVector2Array()

	# Convert triangle strips to triangle list
	mesh.indices = _strips_to_triangles(data.strips)

	# Extract skinning data if present
	if strips.skin_index >= 0:
		_extract_skin_data(reader, strips.skin_index, mesh)

	# Extract material/texture info
	_extract_material_info(reader, strips, mesh)

	return mesh


## Convert vertex positions from NIF to Godot coordinate system
static func _convert_vertices(nif_verts: PackedVector3Array) -> PackedVector3Array:
	var result := PackedVector3Array()
	result.resize(nif_verts.size())

	for i in nif_verts.size():
		var v := nif_verts[i]
		# NIF→Godot: axis swap (x,y,z) → (x,z,-y) + scale to meters
		result[i] = CS.vector_to_godot(v)

	return result


## Convert normals from NIF to Godot coordinate system
static func _convert_normals(nif_normals: PackedVector3Array) -> PackedVector3Array:
	var result := PackedVector3Array()
	result.resize(nif_normals.size())

	for i in nif_normals.size():
		var n := nif_normals[i]
		# Same axis swap as vertices (no scaling for normals)
		result[i] = Vector3(n.x, n.z, -n.y).normalized()

	return result


## Flip triangle winding order (NIF uses opposite winding to Godot after coordinate conversion)
static func _flip_winding(triangles: PackedInt32Array) -> PackedInt32Array:
	var result := PackedInt32Array()
	result.resize(triangles.size())

	for i in range(0, triangles.size(), 3):
		result[i] = triangles[i]
		result[i + 1] = triangles[i + 2]
		result[i + 2] = triangles[i + 1]

	return result


## Convert triangle strips to triangle list with flipped winding for Godot
static func _strips_to_triangles(strips: Array) -> PackedInt32Array:
	var triangles := PackedInt32Array()

	for strip in strips:
		if strip.size() < 3:
			continue

		for i in range(strip.size() - 2):
			var i0: int = strip[i]
			var i1: int = strip[i + 1]
			var i2: int = strip[i + 2]

			# Skip degenerate triangles
			if i0 == i1 or i1 == i2 or i0 == i2:
				continue

			# Alternate winding with flip for Godot coordinate system
			# Even triangles: flip winding (swap indices 1 and 2)
			# Odd triangles: original strip alternation + flip = normal order
			if i % 2 == 0:
				triangles.append(i0)
				triangles.append(i2)
				triangles.append(i1)
			else:
				triangles.append(i0)
				triangles.append(i1)
				triangles.append(i2)

	return triangles


## Extract skin data from NiSkinInstance
static func _extract_skin_data(reader: NIFReader, skin_index: int, mesh: MeshData) -> void:
	var skin_inst := reader.get_record(skin_index) as NIFDefs.NiSkinInstance
	if not skin_inst:
		return

	var skin_data := reader.get_record(skin_inst.data_index) as NIFDefs.NiSkinData
	if not skin_data:
		return

	mesh.is_skinned = true

	# Extract overall skin transform (mesh space → skeleton root space)
	# This is critical for correct skinning when body parts have non-identity offsets
	mesh.skin_transform = CS.transform_to_godot(skin_data.skin_transform.to_transform3d())

	# Extract bone names
	mesh.bone_names = PackedStringArray()
	for bone_idx in skin_inst.bone_indices:
		var bone_node := reader.get_record(bone_idx) as NIFDefs.NiNode
		if bone_node and bone_node.name:
			mesh.bone_names.append(bone_node.name)
		else:
			mesh.bone_names.append("Bone_%d" % bone_idx)

	# Extract inverse bind poses (convert to Godot space)
	# These are the per-bone offsets from NiSkinData, stored for reference.
	# The native skeleton pipeline uses skeleton rest poses instead (more robust).
	mesh.inv_bind_poses = []
	for bone_info in skin_data.bones:
		var transform: NIFDefs.NIFTransform = bone_info["transform"]
		var inv_bind := transform.to_transform3d()
		# Convert to Godot coordinate system
		mesh.inv_bind_poses.append(CS.transform_to_godot(inv_bind))

	# Initialize per-vertex weight arrays
	var vertex_count := mesh.vertices.size()
	mesh.bone_weights = []
	mesh.bone_indices = []
	mesh.bone_weights.resize(vertex_count)
	mesh.bone_indices.resize(vertex_count)

	for i in vertex_count:
		mesh.bone_weights[i] = PackedFloat32Array([0, 0, 0, 0])
		mesh.bone_indices[i] = PackedInt32Array([0, 0, 0, 0])

	# Populate weights from bone data
	# NIFReader stores weights as: bone["weights"] = [{vertex: int, weight: float}, ...]
	for bone_idx in skin_data.bones.size():
		var bone_info: Dictionary = skin_data.bones[bone_idx]
		var weights: Array = bone_info.get("weights", [])

		for weight_entry in weights:
			var vertex_idx: int = weight_entry["vertex"]
			var weight: float = weight_entry["weight"]

			if vertex_idx >= vertex_count:
				continue

			# Find first empty slot in this vertex's weights
			var vert_weights: PackedFloat32Array = mesh.bone_weights[vertex_idx]
			var vert_indices: PackedInt32Array = mesh.bone_indices[vertex_idx]

			for slot in 4:
				if vert_weights[slot] == 0.0:
					vert_weights[slot] = weight
					vert_indices[slot] = bone_idx
					break

			mesh.bone_weights[vertex_idx] = vert_weights
			mesh.bone_indices[vertex_idx] = vert_indices

	# Normalize weights and fix unused bone index slots.
	# Unused slots have weight 0 but bone_index defaults to 0 (root bone).
	# Set them to the first actually-used bone to prevent any edge-case influence.
	for i in vertex_count:
		var weights: PackedFloat32Array = mesh.bone_weights[i]
		var total: float = weights[0] + weights[1] + weights[2] + weights[3]
		if total > 0.0:
			mesh.bone_weights[i] = PackedFloat32Array([
				weights[0] / total,
				weights[1] / total,
				weights[2] / total,
				weights[3] / total
			])

			# Find first used bone and fill unused slots with it
			var vert_indices: PackedInt32Array = mesh.bone_indices[i]
			var first_bone: int = vert_indices[0]
			for slot in 4:
				if weights[slot] > 0.0:
					first_bone = vert_indices[slot]
					break
			for slot in 4:
				if weights[slot] == 0.0:
					vert_indices[slot] = first_bone
			mesh.bone_indices[i] = vert_indices


## Extract material and texture info
static func _extract_material_info(reader: NIFReader, geom: NIFDefs.NiGeometry, mesh: MeshData) -> void:
	# Look through properties for texturing and material
	for prop_idx in geom.property_indices:
		if prop_idx < 0:
			continue

		var prop := reader.get_record(prop_idx)

		if prop is NIFDefs.NiTexturingProperty:
			var tex_prop := prop as NIFDefs.NiTexturingProperty
			# textures[0] is the base texture (diffuse)
			if not tex_prop.textures.is_empty() and tex_prop.textures[0].has_texture:
				var base_tex: NIFDefs.TextureDesc = tex_prop.textures[0]
				if base_tex.source_index >= 0:
					var tex_src := reader.get_record(base_tex.source_index) as NIFDefs.NiSourceTexture
					if tex_src and not tex_src.filename.is_empty():
						mesh.texture_path = tex_src.filename

		elif prop is NIFDefs.NiMaterialProperty:
			var mat_prop := prop as NIFDefs.NiMaterialProperty
			mesh.material_properties = {
				"ambient": mat_prop.ambient,
				"diffuse": mat_prop.diffuse,
				"specular": mat_prop.specular,
				"emissive": mat_prop.emissive,
				"glossiness": mat_prop.glossiness,
				"alpha": mat_prop.alpha,
			}


## Get transform from a NIF node
static func _get_node_transform(record: NIFDefs.NIFRecord) -> Transform3D:
	# NiAVObject stores transform as a NIFTransform sub-object, not direct properties
	if record is NIFDefs.NiAVObject:
		return record.transform.to_transform3d()
	return Transform3D.IDENTITY


## Create a Godot ArrayMesh from extracted data
static func create_array_mesh(mesh_data: MeshData) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	arrays[Mesh.ARRAY_VERTEX] = mesh_data.vertices
	if not mesh_data.normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = mesh_data.normals
	if not mesh_data.uvs.is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = mesh_data.uvs
	arrays[Mesh.ARRAY_INDEX] = mesh_data.indices

	# Add bone data if skinned
	if mesh_data.is_skinned:
		var bones := PackedInt32Array()
		var weights := PackedFloat32Array()

		for i in mesh_data.vertices.size():
			var bi: PackedInt32Array = mesh_data.bone_indices[i]
			var bw: PackedFloat32Array = mesh_data.bone_weights[i]
			bones.append_array(bi)
			weights.append_array(bw)

		arrays[Mesh.ARRAY_BONES] = bones
		arrays[Mesh.ARRAY_WEIGHTS] = weights

	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	# Store metadata for later use
	array_mesh.set_meta("source_path", mesh_data.source_path)
	array_mesh.set_meta("bone_names", mesh_data.bone_names)
	array_mesh.set_meta("inv_bind_poses", mesh_data.inv_bind_poses)
	array_mesh.set_meta("texture_path", mesh_data.texture_path)

	return array_mesh
