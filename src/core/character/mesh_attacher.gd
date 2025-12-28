## Mesh Attacher - Attaches meshes to skeletons
## Game-agnostic core component
##
## Handles two attachment types:
## 1. Skinned meshes - Deformed by skeleton bones via Skin resource
## 2. Static meshes - Attached rigidly to a single bone via BoneAttachment3D
class_name MeshAttacher
extends RefCounted


## Result of mesh attachment
class AttachmentResult:
	var node: Node3D
	var mesh_instance: MeshInstance3D
	var success: bool
	var error: String

	static func ok(p_node: Node3D, p_mesh: MeshInstance3D) -> AttachmentResult:
		var r := AttachmentResult.new()
		r.node = p_node
		r.mesh_instance = p_mesh
		r.success = true
		return r

	static func fail(p_error: String) -> AttachmentResult:
		var r := AttachmentResult.new()
		r.success = false
		r.error = p_error
		return r


## Attach a skinned mesh to a skeleton
## mirror_x: If true, scales X by -1 and flips face culling (for left-side body parts)
static func attach_skinned(
	mesh: ArrayMesh,
	skin: Skin,
	skeleton: Skeleton3D,
	mirror_x: bool = false
) -> AttachmentResult:
	if mesh == null:
		return AttachmentResult.fail("Mesh is null")
	if skin == null:
		return AttachmentResult.fail("Skin is null")
	if skeleton == null:
		return AttachmentResult.fail("Skeleton is null")

	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.skin = skin
	instance.skeleton = NodePath("..")  # Parent is the skeleton

	if mirror_x:
		instance.scale.x = -1.0
		# Override materials to flip face culling
		_apply_mirror_materials(instance)

	skeleton.add_child(instance)
	return AttachmentResult.ok(instance, instance)


## Attach a static mesh to a specific bone
static func attach_static(
	mesh: ArrayMesh,
	skeleton: Skeleton3D,
	bone_name: String,
	offset: Transform3D = Transform3D.IDENTITY,
	mirror_x: bool = false
) -> AttachmentResult:
	if mesh == null:
		return AttachmentResult.fail("Mesh is null")
	if skeleton == null:
		return AttachmentResult.fail("Skeleton is null")

	var bone_idx := skeleton.find_bone(bone_name)
	if bone_idx < 0:
		return AttachmentResult.fail("Bone not found: %s" % bone_name)

	var attachment := BoneAttachment3D.new()
	attachment.bone_name = bone_name
	attachment.bone_idx = bone_idx

	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.transform = offset

	if mirror_x:
		instance.scale.x = -1.0
		_apply_mirror_materials(instance)

	attachment.add_child(instance)
	skeleton.add_child(attachment)

	return AttachmentResult.ok(attachment, instance)


## Apply material overrides to flip face culling for mirrored meshes
static func _apply_mirror_materials(instance: MeshInstance3D) -> void:
	var mesh: ArrayMesh = instance.mesh
	if mesh == null:
		return

	for surf_idx in mesh.get_surface_count():
		var mat := mesh.surface_get_material(surf_idx)
		if mat == null:
			continue

		# Duplicate material and flip cull mode
		var new_mat: Material
		if mat is StandardMaterial3D:
			new_mat = mat.duplicate()
			var std_mat: StandardMaterial3D = new_mat
			match std_mat.cull_mode:
				BaseMaterial3D.CULL_BACK:
					std_mat.cull_mode = BaseMaterial3D.CULL_FRONT
				BaseMaterial3D.CULL_FRONT:
					std_mat.cull_mode = BaseMaterial3D.CULL_BACK
				# CULL_DISABLED stays the same
		elif mat is ShaderMaterial:
			# For shader materials, we'd need to handle this differently
			# For now, just duplicate
			new_mat = mat.duplicate()
		else:
			new_mat = mat.duplicate()

		instance.set_surface_override_material(surf_idx, new_mat)


## Attach multiple meshes from an array
## items: Array of { mesh: ArrayMesh, skin: Skin (optional), bone_name: String (optional), mirror: bool }
static func attach_multiple(
	items: Array,
	skeleton: Skeleton3D
) -> Array[AttachmentResult]:
	var results: Array[AttachmentResult] = []

	for item in items:
		var mesh: ArrayMesh = item.get("mesh")
		var skin: Skin = item.get("skin")
		var bone_name: String = item.get("bone_name", "")
		var mirror: bool = item.get("mirror", false)
		var offset: Transform3D = item.get("offset", Transform3D.IDENTITY)

		var result: AttachmentResult
		if skin != null:
			result = attach_skinned(mesh, skin, skeleton, mirror)
		elif bone_name:
			result = attach_static(mesh, skeleton, bone_name, offset, mirror)
		else:
			result = AttachmentResult.fail("Item has no skin or bone_name")

		results.append(result)

	return results


## Remove all mesh instances from a skeleton
static func clear_skeleton(skeleton: Skeleton3D) -> void:
	if skeleton == null:
		return

	var to_remove: Array[Node] = []
	for child in skeleton.get_children():
		if child is MeshInstance3D or child is BoneAttachment3D:
			to_remove.append(child)

	for node in to_remove:
		node.queue_free()
