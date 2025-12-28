## Skin Builder - Creates Godot Skin resources for GPU skinning
## Game-agnostic core component
##
## The Skin resource is the key to correct skinning. It stores:
## - Bone indices (which bones affect the mesh)
## - Inverse bind matrices (transforms from bone space to mesh space at bind time)
##
## At runtime, Godot computes: final_vertex = bone_global × inverse_bind × vertex
class_name SkinBuilder
extends RefCounted


## Build Skin from bone names and inverse bind matrices
## bone_translator: Optional callable to translate bone names (e.g., normalize case, mirror L/R)
static func from_bind_data(
	bone_names: PackedStringArray,
	inv_bind_matrices: Array,
	skeleton: Skeleton3D,
	bone_translator: Callable = Callable()
) -> Skin:
	var skin := Skin.new()

	for i in bone_names.size():
		var source_name: String = bone_names[i]
		var target_name: String = source_name

		# Apply translation if provided
		if bone_translator.is_valid():
			target_name = bone_translator.call(source_name)

		var bone_idx := skeleton.find_bone(target_name)

		if bone_idx < 0:
			push_warning("SkinBuilder: Bone '%s' not found in skeleton (source: '%s')" % [target_name, source_name])
			continue

		var inv_bind: Transform3D = inv_bind_matrices[i] if i < inv_bind_matrices.size() else Transform3D.IDENTITY
		skin.add_bind(bone_idx, inv_bind)

	return skin


## Build Skin from mesh metadata (stored by NIF loader)
static func from_mesh_metadata(
	mesh: ArrayMesh,
	skeleton: Skeleton3D,
	bone_translator: Callable = Callable()
) -> Skin:
	var bone_names: PackedStringArray = mesh.get_meta("bone_names", PackedStringArray())
	var inv_binds: Array = mesh.get_meta("inv_bind_poses", [])

	if bone_names.is_empty():
		push_error("SkinBuilder: Mesh has no bone_names metadata")
		return null

	return from_bind_data(bone_names, inv_binds, skeleton, bone_translator)


## Remap mesh bone indices to match a target skeleton
## Returns a new ArrayMesh with remapped ARRAY_BONES
static func remap_mesh_bones(
	mesh: ArrayMesh,
	skeleton: Skeleton3D,
	bone_translator: Callable = Callable()
) -> ArrayMesh:
	var source_bones: PackedStringArray = mesh.get_meta("bone_names", PackedStringArray())
	if source_bones.is_empty():
		push_error("SkinBuilder: Cannot remap - mesh has no bone_names metadata")
		return mesh

	# Build index mapping: source_idx -> target_idx
	var bone_map: PackedInt32Array
	bone_map.resize(source_bones.size())

	for i in source_bones.size():
		var source_name: String = source_bones[i]
		var target_name: String = source_name

		if bone_translator.is_valid():
			target_name = bone_translator.call(source_name)

		var target_idx := skeleton.find_bone(target_name)
		if target_idx < 0:
			push_warning("SkinBuilder: Bone '%s' not found during remap" % target_name)
			target_idx = 0  # Fallback to root
		bone_map[i] = target_idx

	# Create new mesh with remapped bones
	var new_mesh := ArrayMesh.new()

	for surf_idx in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surf_idx)
		var bone_array = arrays[Mesh.ARRAY_BONES]

		if bone_array != null and bone_array.size() > 0:
			arrays[Mesh.ARRAY_BONES] = _remap_bone_indices(bone_array, bone_map)

		var format := mesh.surface_get_format(surf_idx)
		new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, format)

		# Copy material
		var mat := mesh.surface_get_material(surf_idx)
		if mat:
			new_mesh.surface_set_material(surf_idx, mat)

	# Copy metadata to new mesh
	for key in mesh.get_meta_list():
		new_mesh.set_meta(key, mesh.get_meta(key))

	return new_mesh


## Remap bone index array using the provided mapping
static func _remap_bone_indices(bone_array: PackedInt32Array, bone_map: PackedInt32Array) -> PackedInt32Array:
	var result := PackedInt32Array()
	result.resize(bone_array.size())

	var map_size := bone_map.size()
	for i in bone_array.size():
		var old_idx: int = bone_array[i]
		if old_idx >= 0 and old_idx < map_size:
			result[i] = bone_map[old_idx]
		else:
			result[i] = 0  # Fallback to root

	return result


## Create a simple Skin that directly maps mesh bones to skeleton bones by name
## Useful when inverse bind matrices are identity (static binding)
static func from_bone_names_only(
	bone_names: PackedStringArray,
	skeleton: Skeleton3D,
	bone_translator: Callable = Callable()
) -> Skin:
	var inv_binds: Array = []
	for i in bone_names.size():
		inv_binds.append(Transform3D.IDENTITY)
	return from_bind_data(bone_names, inv_binds, skeleton, bone_translator)


## Check if a mesh has skinning data
static func mesh_has_skin_data(mesh: ArrayMesh) -> bool:
	if mesh == null:
		return false

	for surf_idx in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surf_idx)
		if arrays[Mesh.ARRAY_BONES] != null and arrays[Mesh.ARRAY_BONES].size() > 0:
			return true

	return false


## Extract bone names and inverse bind poses from mesh metadata
## Returns: { "bone_names": PackedStringArray, "inv_binds": Array[Transform3D] }
static func extract_skin_data(mesh: ArrayMesh) -> Dictionary:
	return {
		"bone_names": mesh.get_meta("bone_names", PackedStringArray()),
		"inv_binds": mesh.get_meta("inv_bind_poses", [])
	}
