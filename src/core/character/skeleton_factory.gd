## Skeleton Factory - Creates Skeleton3D from bone data
## Game-agnostic core component
class_name SkeletonFactory
extends RefCounted


## Simple bone data container
class BoneData:
	var name: String
	var parent_name: String  # Empty for root bones
	var rest_transform: Transform3D

	func _init(p_name: String = "", p_parent: String = "", p_rest: Transform3D = Transform3D.IDENTITY) -> void:
		name = p_name
		parent_name = p_parent
		rest_transform = p_rest


## Build skeleton from hierarchical bone data
static func from_bone_data(bones: Array) -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton3D"

	# First pass: add all bones
	var bone_indices: Dictionary = {}
	for bone in bones:
		var bd: BoneData = bone
		var idx := skeleton.add_bone(bd.name)
		bone_indices[bd.name] = idx

	# Second pass: set parents and rest poses
	for bone in bones:
		var bd: BoneData = bone
		var idx: int = bone_indices[bd.name]

		if bd.parent_name and bd.parent_name in bone_indices:
			skeleton.set_bone_parent(idx, bone_indices[bd.parent_name])

		skeleton.set_bone_rest(idx, bd.rest_transform)

	skeleton.reset_bone_poses()
	return skeleton


## Build skeleton from NIF node hierarchy
static func from_nif_hierarchy(root_node: Dictionary, normalize_names: bool = true) -> Skeleton3D:
	var bones: Array = []
	_collect_bones_recursive(root_node, "", bones, normalize_names)
	return from_bone_data(bones)


## Recursively collect bones from NIF node tree
static func _collect_bones_recursive(node: Dictionary, parent_name: String, bones: Array, normalize: bool) -> void:
	var node_name: String = node.get("name", "")
	if node_name.is_empty():
		return

	# Check if this is a bone node (Bip01 prefix or bone_ prefix)
	var lower_name := node_name.to_lower()
	var is_bone := lower_name.begins_with("bip01") or lower_name.begins_with("bone_") or lower_name == "root bone"

	if is_bone:
		var bone := BoneData.new()
		bone.name = lower_name if normalize else node_name
		bone.parent_name = parent_name
		bone.rest_transform = _nif_transform_to_godot(node)
		bones.append(bone)
		parent_name = bone.name

	# Process children
	var children: Array = node.get("children", [])
	for child in children:
		if child is Dictionary:
			_collect_bones_recursive(child, parent_name, bones, normalize)


## Convert NIF transform to Godot Transform3D
static func _nif_transform_to_godot(node: Dictionary) -> Transform3D:
	var translation: Vector3 = node.get("translation", Vector3.ZERO)
	var rotation: Basis = node.get("rotation", Basis.IDENTITY)
	var scale_val: float = node.get("scale", 1.0)

	# NIF uses different coordinate system - convert
	# NIF: X-right, Y-forward, Z-up
	# Godot: X-right, Y-up, Z-back
	var basis := rotation
	if scale_val != 1.0:
		basis = basis.scaled(Vector3(scale_val, scale_val, scale_val))

	return Transform3D(basis, translation)


## Duplicate a skeleton (for instancing from cache)
static func duplicate_skeleton(source: Skeleton3D) -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	skeleton.name = source.name

	for i in source.get_bone_count():
		skeleton.add_bone(source.get_bone_name(i))

	for i in source.get_bone_count():
		var parent_idx := source.get_bone_parent(i)
		if parent_idx >= 0:
			skeleton.set_bone_parent(i, parent_idx)
		skeleton.set_bone_rest(i, source.get_bone_rest(i))

	skeleton.reset_bone_poses()
	return skeleton
