## SkeletonProfileAdapter — Maps any skeleton to Godot's SkeletonProfileHumanoid
##
## Creates a BoneMap for a given Skeleton3D, auto-detecting the naming convention
## (Morrowind Bip01, Mixamo, or generic). This replaces scattered custom bone
## mapping code with a single canonical pipeline using Godot 4.6 native types.
##
## Usage:
##   var bone_map := SkeletonProfileAdapter.create_bone_map(skeleton)
##   var skel_name := bone_map.get_skeleton_bone_name("LeftUpperLeg")
class_name SkeletonProfileAdapter
extends RefCounted


## Skeleton naming conventions
enum SkeletonType {
	UNKNOWN,
	MORROWIND,  # Bip01 convention
	MIXAMO,     # mixamorig1_ prefix
	GENERIC,    # Standard humanoid names or close variants
}


## Cached profile instance (shared across all adapters)
static var _profile: SkeletonProfileHumanoid = null


# =========================================================================
# MORROWIND BIP01 → PROFILE MAPPING
# =========================================================================

## Maps lowercase Morrowind bone names to SkeletonProfileHumanoid bone names
const _MORROWIND_MAP := {
	# Root / Hips
	"bip01": "Hips",

	# Spine chain
	"bip01 spine": "Spine",
	"bip01 spine1": "Chest",
	"bip01 spine2": "UpperChest",

	# Head / Neck
	"bip01 neck": "Neck",
	"bip01 head": "Head",

	# Left Arm
	"bip01 l clavicle": "LeftShoulder",
	"bip01 l upperarm": "LeftUpperArm",
	"bip01 l forearm": "LeftLowerArm",
	"bip01 l hand": "LeftHand",

	# Right Arm
	"bip01 r clavicle": "RightShoulder",
	"bip01 r upperarm": "RightUpperArm",
	"bip01 r forearm": "RightLowerArm",
	"bip01 r hand": "RightHand",

	# Left Leg
	"bip01 l thigh": "LeftUpperLeg",
	"bip01 l calf": "LeftLowerLeg",
	"bip01 l foot": "LeftFoot",
	"bip01 l toe0": "LeftToes",

	# Right Leg
	"bip01 r thigh": "RightUpperLeg",
	"bip01 r calf": "RightLowerLeg",
	"bip01 r foot": "RightFoot",
	"bip01 r toe0": "RightToes",

	# Fingers — Left
	"bip01 l finger0": "LeftThumbMetacarpal",
	"bip01 l finger01": "LeftThumbProximal",
	"bip01 l finger02": "LeftThumbDistal",
	"bip01 l finger1": "LeftIndexProximal",
	"bip01 l finger11": "LeftIndexIntermediate",
	"bip01 l finger12": "LeftIndexDistal",
	"bip01 l finger2": "LeftMiddleProximal",
	"bip01 l finger21": "LeftMiddleIntermediate",
	"bip01 l finger22": "LeftMiddleDistal",
	"bip01 l finger3": "LeftRingProximal",
	"bip01 l finger31": "LeftRingIntermediate",
	"bip01 l finger32": "LeftRingDistal",
	"bip01 l finger4": "LeftLittleProximal",
	"bip01 l finger41": "LeftLittleIntermediate",
	"bip01 l finger42": "LeftLittleDistal",

	# Fingers — Right
	"bip01 r finger0": "RightThumbMetacarpal",
	"bip01 r finger01": "RightThumbProximal",
	"bip01 r finger02": "RightThumbDistal",
	"bip01 r finger1": "RightIndexProximal",
	"bip01 r finger11": "RightIndexIntermediate",
	"bip01 r finger12": "RightIndexDistal",
	"bip01 r finger2": "RightMiddleProximal",
	"bip01 r finger21": "RightMiddleIntermediate",
	"bip01 r finger22": "RightMiddleDistal",
	"bip01 r finger3": "RightRingProximal",
	"bip01 r finger31": "RightRingIntermediate",
	"bip01 r finger32": "RightRingDistal",
	"bip01 r finger4": "RightLittleProximal",
	"bip01 r finger41": "RightLittleIntermediate",
	"bip01 r finger42": "RightLittleDistal",
}


# =========================================================================
# MIXAMO → PROFILE MAPPING
# =========================================================================

## Maps Mixamo bone names (after stripping prefix) to profile bone names
const _MIXAMO_MAP := {
	"hips": "Hips",
	"spine": "Spine",
	"spine1": "Chest",
	"spine2": "UpperChest",
	"neck": "Neck",
	"head": "Head",

	"leftshoulder": "LeftShoulder",
	"leftarm": "LeftUpperArm",
	"leftforearm": "LeftLowerArm",
	"lefthand": "LeftHand",

	"rightshoulder": "RightShoulder",
	"rightarm": "RightUpperArm",
	"rightforearm": "RightLowerArm",
	"righthand": "RightHand",

	"leftupleg": "LeftUpperLeg",
	"leftleg": "LeftLowerLeg",
	"leftfoot": "LeftFoot",
	"lefttoebase": "LeftToes",

	"rightupleg": "RightUpperLeg",
	"rightleg": "RightLowerLeg",
	"rightfoot": "RightFoot",
	"righttoebase": "RightToes",

	# Fingers
	"lefthandthumb1": "LeftThumbMetacarpal",
	"lefthandthumb2": "LeftThumbProximal",
	"lefthandthumb3": "LeftThumbDistal",
	"lefthandindex1": "LeftIndexProximal",
	"lefthandindex2": "LeftIndexIntermediate",
	"lefthandindex3": "LeftIndexDistal",
	"lefthandmiddle1": "LeftMiddleProximal",
	"lefthandmiddle2": "LeftMiddleIntermediate",
	"lefthandmiddle3": "LeftMiddleDistal",
	"lefthandring1": "LeftRingProximal",
	"lefthandring2": "LeftRingIntermediate",
	"lefthandring3": "LeftRingDistal",
	"lefthandpinky1": "LeftLittleProximal",
	"lefthandpinky2": "LeftLittleIntermediate",
	"lefthandpinky3": "LeftLittleDistal",

	"righthandthumb1": "RightThumbMetacarpal",
	"righthandthumb2": "RightThumbProximal",
	"righthandthumb3": "RightThumbDistal",
	"righthandindex1": "RightIndexProximal",
	"righthandindex2": "RightIndexIntermediate",
	"righthandindex3": "RightIndexDistal",
	"righthandmiddle1": "RightMiddleProximal",
	"righthandmiddle2": "RightMiddleIntermediate",
	"righthandmiddle3": "RightMiddleDistal",
	"righthandring1": "RightRingProximal",
	"righthandring2": "RightRingIntermediate",
	"righthandring3": "RightRingDistal",
	"righthandpinky1": "RightLittleProximal",
	"righthandpinky2": "RightLittleIntermediate",
	"righthandpinky3": "RightLittleDistal",
}


# =========================================================================
# PUBLIC API
# =========================================================================

## Create a BoneMap for the given skeleton, auto-detecting naming convention.
## Optionally pass a type hint to skip auto-detection.
static func create_bone_map(skeleton: Skeleton3D, type_hint: SkeletonType = SkeletonType.UNKNOWN) -> BoneMap:
	if not skeleton or skeleton.get_bone_count() == 0:
		push_warning("SkeletonProfileAdapter: Cannot create BoneMap for null/empty skeleton")
		return null

	var bone_map := BoneMap.new()
	bone_map.profile = _get_profile()

	var skel_type := type_hint if type_hint != SkeletonType.UNKNOWN else detect_skeleton_type(skeleton)

	match skel_type:
		SkeletonType.MORROWIND:
			_map_morrowind(skeleton, bone_map)
		SkeletonType.MIXAMO:
			_map_mixamo(skeleton, bone_map)
		_:
			_map_generic(skeleton, bone_map)

	# Store on skeleton metadata for other systems to retrieve
	skeleton.set_meta("bone_map", bone_map)
	skeleton.set_meta("skeleton_type", skel_type)

	return bone_map


## Retrieve a previously created BoneMap from skeleton metadata.
## Returns null if none was created yet.
static func get_bone_map(skeleton: Skeleton3D) -> BoneMap:
	if skeleton and skeleton.has_meta("bone_map"):
		return skeleton.get_meta("bone_map") as BoneMap
	return null


## Get the skeleton bone name for a profile bone name.
## Convenience method that handles null BoneMap gracefully.
static func get_skeleton_bone(skeleton: Skeleton3D, profile_bone: StringName) -> StringName:
	var bone_map := get_bone_map(skeleton)
	if not bone_map or not bone_map.profile:
		return &""
	# Check that the profile bone exists before querying (avoids engine error)
	if bone_map.profile.find_bone(profile_bone) < 0:
		return &""
	return bone_map.get_skeleton_bone_name(profile_bone)


## Get the bone index for a profile bone name. Returns -1 if not found.
static func get_bone_index(skeleton: Skeleton3D, profile_bone: StringName) -> int:
	var skel_name := get_skeleton_bone(skeleton, profile_bone)
	if skel_name.is_empty():
		return -1
	return skeleton.find_bone(skel_name)


## Detect what naming convention a skeleton uses.
static func detect_skeleton_type(skeleton: Skeleton3D) -> SkeletonType:
	var morrowind_score := 0
	var mixamo_score := 0

	for i in skeleton.get_bone_count():
		var name := skeleton.get_bone_name(i)
		var lower := name.to_lower()

		if lower.begins_with("bip01"):
			morrowind_score += 1
		if lower.begins_with("mixamorig"):
			mixamo_score += 1

	if morrowind_score > mixamo_score and morrowind_score >= 3:
		return SkeletonType.MORROWIND
	if mixamo_score > morrowind_score and mixamo_score >= 3:
		return SkeletonType.MIXAMO
	return SkeletonType.GENERIC


## Get the shared SkeletonProfileHumanoid instance.
static func get_profile() -> SkeletonProfileHumanoid:
	return _get_profile()


## Count how many profile bones were successfully mapped.
static func count_mapped_bones(bone_map: BoneMap) -> int:
	if not bone_map or not bone_map.profile:
		return 0
	var count := 0
	for i in bone_map.profile.bone_size:
		var profile_name := bone_map.profile.get_bone_name(i)
		if not bone_map.get_skeleton_bone_name(profile_name).is_empty():
			count += 1
	return count


## Get list of unmapped profile bones (for debugging).
static func get_unmapped_bones(bone_map: BoneMap) -> PackedStringArray:
	var result := PackedStringArray()
	if not bone_map or not bone_map.profile:
		return result
	for i in bone_map.profile.bone_size:
		var profile_name := bone_map.profile.get_bone_name(i)
		if bone_map.get_skeleton_bone_name(profile_name).is_empty():
			result.append(profile_name)
	return result


# =========================================================================
# INTERNAL
# =========================================================================

static func _get_profile() -> SkeletonProfileHumanoid:
	if not _profile:
		_profile = SkeletonProfileHumanoid.new()
	return _profile


static func _map_morrowind(skeleton: Skeleton3D, bone_map: BoneMap) -> void:
	for i in skeleton.get_bone_count():
		var bone_name := skeleton.get_bone_name(i)
		var lower := bone_name.to_lower()

		if lower in _MORROWIND_MAP:
			var profile_name: String = _MORROWIND_MAP[lower]
			bone_map.set_skeleton_bone_name(profile_name, bone_name)


static func _map_mixamo(skeleton: Skeleton3D, bone_map: BoneMap) -> void:
	for i in skeleton.get_bone_count():
		var bone_name := skeleton.get_bone_name(i)

		# Strip Mixamo prefix: "mixamorig1_Hips" → "Hips", then lowercase → "hips"
		var stripped := bone_name
		if stripped.begins_with("mixamorig1_"):
			stripped = stripped.substr(11)
		elif stripped.begins_with("mixamorig_"):
			stripped = stripped.substr(10)

		var lower := stripped.to_lower()
		if lower in _MIXAMO_MAP:
			var profile_name: String = _MIXAMO_MAP[lower]
			bone_map.set_skeleton_bone_name(profile_name, bone_name)


static func _map_generic(skeleton: Skeleton3D, bone_map: BoneMap) -> void:
	## Generic heuristic mapping for unknown skeletons.
	## Tries substring matching on lowercase bone names.
	for i in skeleton.get_bone_count():
		var bone_name := skeleton.get_bone_name(i)
		var lower := bone_name.to_lower()
		var profile_name := _heuristic_match(lower)
		if not profile_name.is_empty():
			# Only set if not already mapped (first match wins)
			if bone_map.get_skeleton_bone_name(profile_name).is_empty():
				bone_map.set_skeleton_bone_name(profile_name, bone_name)


static func _heuristic_match(lower: String) -> StringName:
	# Hips / Root
	if lower == "hips" or lower == "pelvis" or lower == "root":
		return &"Hips"

	# Spine chain (order matters — check specific before general)
	if ("spine2" in lower or "upperchest" in lower) and "spine" in lower:
		return &"UpperChest"
	if ("spine1" in lower or lower == "chest") and "spine" in lower:
		return &"Chest"
	if lower == "chest" or "upperchest" in lower:
		return &"UpperChest"
	if lower == "spine" or (lower.ends_with("spine") and "upper" not in lower):
		return &"Spine"

	# Head / Neck
	if lower == "neck" or lower.ends_with("_neck"):
		return &"Neck"
	if lower == "head" or lower.ends_with("_head"):
		return &"Head"

	# Determine side
	var is_left := "left" in lower or " l " in lower or lower.begins_with("l_") or \
				   "_l_" in lower or lower.ends_with("_l") or lower.begins_with("l ")
	var is_right := "right" in lower or " r " in lower or lower.begins_with("r_") or \
				    "_r_" in lower or lower.ends_with("_r") or lower.begins_with("r ")

	if not is_left and not is_right:
		return &""

	var side := "Left" if is_left else "Right"

	# Arms
	if "shoulder" in lower or "clavicle" in lower:
		return StringName(side + "Shoulder")
	if "upperarm" in lower or ("upper" in lower and "arm" in lower):
		return StringName(side + "UpperArm")
	if "forearm" in lower or "lowerarm" in lower or ("lower" in lower and "arm" in lower):
		return StringName(side + "LowerArm")
	if "hand" in lower and "finger" not in lower and "thumb" not in lower:
		return StringName(side + "Hand")

	# Legs
	if "thigh" in lower or "upperleg" in lower or ("upper" in lower and "leg" in lower) or "upleg" in lower:
		return StringName(side + "UpperLeg")
	if "calf" in lower or "shin" in lower or "lowerleg" in lower or ("lower" in lower and "leg" in lower):
		return StringName(side + "LowerLeg")
	if lower.ends_with("leg") and "upper" not in lower and "lower" not in lower:
		return StringName(side + "LowerLeg")
	if "foot" in lower and "toe" not in lower:
		return StringName(side + "Foot")
	if "toe" in lower:
		return StringName(side + "Toes")

	return &""
