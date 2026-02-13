## LookAtIKModifier - SkeletonModifier3D for head/neck/spine look-at
##
## Runs in the skeleton modifier pipeline AFTER AnimationTree, ensuring it
## modifies animated poses rather than being overwritten by the animation system.
##
## The previous approach (set_bone_pose_rotation in _physics_process) was
## overwritten by AnimationTree and also mixed world-space and skeleton-space
## coordinates. This modifier fixes both issues.
class_name LookAtIKModifier
extends SkeletonModifier3D

## Target node to look at (position is read each modifier frame)
var target: Node3D = null

## Maximum look angle in degrees (bones won't rotate beyond this)
var max_look_angle: float = 90.0

## Current blend weight (0 = off, 1 = full). Controlled externally by IKController.
var blend_weight: float = 0.0

## Bone entries: [{bone_idx: int, weight: float}]
## Order matters: process parent bones first (spine → neck → head)
## so child bones see the updated parent rotation.
var _bone_entries: Array[Dictionary] = []


## Add a bone to the look-at chain with a base weight.
## Call in parent-to-child order (spine first, head last).
func add_bone(bone_idx: int, weight: float) -> void:
	_bone_entries.append({"bone_idx": bone_idx, "weight": weight})


## Called by the skeleton modifier pipeline, AFTER AnimationTree.
func _process_modification() -> void:
	if blend_weight <= 0.001 or not target or _bone_entries.is_empty():
		return

	var skel := get_skeleton()
	if not skel:
		return

	# Convert target position to skeleton space (fixes the world/skeleton space mismatch)
	var target_skel: Vector3 = skel.global_transform.affine_inverse() * target.global_position

	for entry in _bone_entries:
		var bone_idx: int = entry.bone_idx
		var weight: float = entry.weight * blend_weight
		_rotate_bone_toward(skel, bone_idx, weight, target_skel)


## Rotate a single bone partially toward the target direction.
func _rotate_bone_toward(skel: Skeleton3D, bone_idx: int, weight: float, target_skel: Vector3) -> void:
	if weight <= 0.001:
		return

	# Get current animated global pose (skeleton space, reflects AnimationTree output)
	var bone_global := skel.get_bone_global_pose(bone_idx)
	var to_target := target_skel - bone_global.origin
	if to_target.length_squared() < 0.01:
		return
	to_target = to_target.normalized()

	# Bone's current forward direction in skeleton space
	# -Z is forward in Godot convention; MW bones preserve this after coord conversion
	var bone_forward := (-bone_global.basis.z).normalized()

	# Angle between current forward and target direction
	var angle := bone_forward.angle_to(to_target)
	if angle < 0.001:
		return

	# Hard cutoff beyond max angle (with 30° soft falloff zone)
	var angle_deg := rad_to_deg(angle)
	if angle_deg > max_look_angle:
		var over := angle_deg - max_look_angle
		weight *= maxf(0.0, 1.0 - over / 30.0)
		if weight <= 0.001:
			return

	# Rotation axis from current forward to target direction
	var axis := bone_forward.cross(to_target)
	if axis.length_squared() < 0.0001:
		return
	axis = axis.normalized()

	# Apply weighted fraction of the full rotation
	var delta_quat := Quaternion(axis, angle * weight)
	var current_rot := bone_global.basis.get_rotation_quaternion()
	var new_global_rot := (delta_quat * current_rot).normalized()

	# Convert new global rotation back to local bone pose
	# Godot: bone_global = parent_global * rest * pose
	# Therefore: pose = rest⁻¹ * parent_global⁻¹ * new_global
	var parent_idx := skel.get_bone_parent(bone_idx)
	var parent_rot := Quaternion.IDENTITY
	if parent_idx >= 0:
		parent_rot = skel.get_bone_global_pose(parent_idx).basis.get_rotation_quaternion()
	var rest_rot := skel.get_bone_rest(bone_idx).basis.get_rotation_quaternion()

	var new_pose := (rest_rot.inverse() * parent_rot.inverse() * new_global_rot).normalized()
	skel.set_bone_pose_rotation(bone_idx, new_pose)
