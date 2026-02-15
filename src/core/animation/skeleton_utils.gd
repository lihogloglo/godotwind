## SkeletonUtils — Morrowind skeleton bone renaming utilities
##
## Renames native Morrowind skeleton bones (Bip01 format) to SkeletonProfileHumanoid
## names for IK, blend masks, and animation system compatibility.
##
## NO RETARGETING - this is bone renaming only, not animation retargeting.
class_name SkeletonUtils
extends RefCounted


## Morrowind bone name map (Bip01 format → SkeletonProfileHumanoid)
const MW_BONE_MAP := {
	# Root/hips
	"Bip01": "Root",
	"Bip01 Pelvis": "Hips",

	# Spine
	"Bip01 Spine": "Spine",
	"Bip01 Spine1": "Chest",
	"Bip01 Spine2": "UpperChest",
	"Bip01 Neck": "Neck",
	"Bip01 Head": "Head",

	# Left arm
	"Bip01 L Clavicle": "LeftShoulder",
	"Bip01 L UpperArm": "LeftUpperArm",
	"Bip01 L Forearm": "LeftLowerArm",
	"Bip01 L Hand": "LeftHand",

	# Right arm
	"Bip01 R Clavicle": "RightShoulder",
	"Bip01 R UpperArm": "RightUpperArm",
	"Bip01 R Forearm": "RightLowerArm",
	"Bip01 R Hand": "RightHand",

	# Left leg
	"Bip01 L Thigh": "LeftUpperLeg",
	"Bip01 L Calf": "LeftLowerLeg",
	"Bip01 L Foot": "LeftFoot",
	"Bip01 L Toe0": "LeftToes",

	# Right leg
	"Bip01 R Thigh": "RightUpperLeg",
	"Bip01 R Calf": "RightLowerLeg",
	"Bip01 R Foot": "RightFoot",
	"Bip01 R Toe0": "RightToes",

	# Fingers (left hand)
	"Bip01 L Finger0": "LeftThumbMetacarpal",
	"Bip01 L Finger01": "LeftThumbProximal",
	"Bip01 L Finger02": "LeftThumbDistal",
	"Bip01 L Finger1": "LeftIndexProximal",
	"Bip01 L Finger11": "LeftIndexIntermediate",
	"Bip01 L Finger12": "LeftIndexDistal",
	"Bip01 L Finger2": "LeftMiddleProximal",
	"Bip01 L Finger21": "LeftMiddleIntermediate",
	"Bip01 L Finger22": "LeftMiddleDistal",
	"Bip01 L Finger3": "LeftRingProximal",
	"Bip01 L Finger31": "LeftRingIntermediate",
	"Bip01 L Finger32": "LeftRingDistal",
	"Bip01 L Finger4": "LeftLittleProximal",
	"Bip01 L Finger41": "LeftLittleIntermediate",
	"Bip01 L Finger42": "LeftLittleDistal",

	# Fingers (right hand)
	"Bip01 R Finger0": "RightThumbMetacarpal",
	"Bip01 R Finger01": "RightThumbProximal",
	"Bip01 R Finger02": "RightThumbDistal",
	"Bip01 R Finger1": "RightIndexProximal",
	"Bip01 R Finger11": "RightIndexIntermediate",
	"Bip01 R Finger12": "RightIndexDistal",
	"Bip01 R Finger2": "RightMiddleProximal",
	"Bip01 R Finger21": "RightMiddleIntermediate",
	"Bip01 R Finger22": "RightMiddleDistal",
	"Bip01 R Finger3": "RightRingProximal",
	"Bip01 R Finger31": "RightRingIntermediate",
	"Bip01 R Finger32": "RightRingDistal",
	"Bip01 R Finger4": "RightLittleProximal",
	"Bip01 R Finger41": "RightLittleIntermediate",
	"Bip01 R Finger42": "RightLittleDistal",
}


## Build a bone name remap dictionary from a skeleton with Bip01 bone names.
## Returns: { "Bip01 BoneName" -> "ProfileName" }
static func build_remap(skeleton: Skeleton3D) -> Dictionary:
	var remap := {}
	for i in skeleton.get_bone_count():
		var bone_name := skeleton.get_bone_name(i)
		if bone_name in MW_BONE_MAP:
			remap[bone_name] = MW_BONE_MAP[bone_name]
	return remap


## Rename all bones in a skeleton from Bip01 format to SkeletonProfileHumanoid names.
## Returns: rename map { old_name -> new_name } for updating BoneAttachments
static func rename_bones_to_profile(skeleton: Skeleton3D) -> Dictionary:
	var rename_map := {}
	for i in skeleton.get_bone_count():
		var old_name := skeleton.get_bone_name(i)
		if old_name in MW_BONE_MAP:
			var new_name: String = MW_BONE_MAP[old_name]
			skeleton.set_bone_name(i, new_name)
			rename_map[old_name] = new_name
	return rename_map


## Remap animation track paths in a library after bone renaming.
## bone_remap: { old_Bip01_name -> new_profile_name }
## Returns: new AnimationLibrary with remapped track paths
static func remap_library(lib: AnimationLibrary, bone_remap: Dictionary) -> AnimationLibrary:
	var result := AnimationLibrary.new()

	for anim_name: String in lib.get_animation_list():
		var source := lib.get_animation(anim_name)
		var remapped := _remap_animation(source, bone_remap)
		result.add_animation(anim_name, remapped)

	return result


## Remap a single animation's track paths
static func _remap_animation(source: Animation, bone_remap: Dictionary) -> Animation:
	var result := Animation.new()
	result.length = source.length
	result.loop_mode = source.loop_mode

	for track_idx in source.get_track_count():
		var path := source.track_get_path(track_idx)
		var track_type := source.track_get_type(track_idx)

		# Check if this is a bone track
		if path.get_subname_count() > 0:
			var bone_name := String(path.get_subname(0))

			# Remap if bone is in map
			if bone_name in bone_remap:
				var new_name: String = bone_remap[bone_name]
				path = NodePath(".:" + new_name)

		# Copy track with potentially remapped path
		var new_idx := result.add_track(track_type)
		result.track_set_path(new_idx, path)
		result.track_set_interpolation_type(new_idx, source.track_get_interpolation_type(track_idx))

		# Copy all keyframes
		for key_idx in source.track_get_key_count(track_idx):
			var time := source.track_get_key_time(track_idx, key_idx)
			var value: Variant = source.track_get_key_value(track_idx, key_idx)
			var transition := source.track_get_key_transition(track_idx, key_idx)
			result.track_insert_key(new_idx, time, value, transition)

	return result
