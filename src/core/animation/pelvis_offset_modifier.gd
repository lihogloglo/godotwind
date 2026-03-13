## PelvisOffsetModifier3D — Drops pelvis for slope adaptation
##
## Custom SkeletonModifier3D that adjusts the Hips bone Y position
## AFTER AnimationTree applies bone poses. Must be ordered BEFORE
## foot IK modifiers in the Skeleton3D child list so TwoBoneIK3D
## solves with the adjusted pelvis position.
##
## Without this modifier, pelvis offset set in _physics_process()
## gets overwritten by AnimationTree in _process().
class_name PelvisOffsetModifier3D
extends SkeletonModifier3D


## Current pelvis Y offset (negative = drop down for slopes)
var pelvis_offset: float = 0.0

## Maximum pelvis drop to prevent legs from over-extending
var max_drop: float = 0.4

## Bone index (cached on setup)
var _hips_bone_idx: int = -1


## Call after adding to Skeleton3D to cache the hips bone index
func setup_bone(bone_name: StringName = &"Hips") -> void:
	var skel := get_skeleton()
	if skel:
		_hips_bone_idx = skel.find_bone(bone_name)
		if _hips_bone_idx < 0:
			# Try common alternatives
			for alt: String in ["Hips", "hips", "Bip01 Pelvis"]:
				_hips_bone_idx = skel.find_bone(alt)
				if _hips_bone_idx >= 0:
					break
	if _hips_bone_idx < 0:
		Log.warn("animation", "PelvisOffsetModifier3D: Hips bone not found")


func _process_modification() -> void:
	var skel := get_skeleton()
	if not skel or _hips_bone_idx < 0:
		return

	var clamped_offset := clampf(pelvis_offset, -max_drop, 0.0)
	if absf(clamped_offset) < 0.001:
		return

	var pose_pos := skel.get_bone_pose_position(_hips_bone_idx)
	pose_pos.y += clamped_offset
	skel.set_bone_pose_position(_hips_bone_idx, pose_pos)
