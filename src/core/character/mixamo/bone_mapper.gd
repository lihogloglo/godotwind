## BoneMapper - Maps Morrowind Bip01 bones to Mixamo skeleton
##
## Provides bidirectional mapping between Morrowind's Bip01 naming convention
## and Mixamo's standard humanoid skeleton. Also handles transform corrections
## needed when rebinding meshes from one skeleton to another.
class_name BoneMapper
extends RefCounted


## Morrowind to Mixamo bone name mapping
## Key: lowercase Morrowind bone name
## Value: Mixamo bone name (using "mixamorig1_" prefix to match Godot's FBX import naming)
const MORROWIND_TO_MIXAMO := {
	# Root / Hips
	"bip01": "mixamorig1_Hips",
	"bip01 pelvis": "mixamorig1_Hips",  # Merged - MW separates root/pelvis

	# Spine chain
	"bip01 spine": "mixamorig1_Spine",
	"bip01 spine1": "mixamorig1_Spine1",
	"bip01 spine2": "mixamorig1_Spine2",

	# Head / Neck
	"bip01 neck": "mixamorig1_Neck",
	"bip01 head": "mixamorig1_Head",

	# Left Arm
	"bip01 l clavicle": "mixamorig1_LeftShoulder",
	"bip01 l upperarm": "mixamorig1_LeftArm",
	"bip01 l forearm": "mixamorig1_LeftForeArm",
	"bip01 l hand": "mixamorig1_LeftHand",

	# Left Fingers
	"bip01 l finger0": "mixamorig1_LeftHandThumb1",
	"bip01 l finger01": "mixamorig1_LeftHandThumb2",
	"bip01 l finger02": "mixamorig1_LeftHandThumb3",
	"bip01 l finger1": "mixamorig1_LeftHandIndex1",
	"bip01 l finger11": "mixamorig1_LeftHandIndex2",
	"bip01 l finger12": "mixamorig1_LeftHandIndex3",
	"bip01 l finger2": "mixamorig1_LeftHandMiddle1",
	"bip01 l finger21": "mixamorig1_LeftHandMiddle2",
	"bip01 l finger22": "mixamorig1_LeftHandMiddle3",
	"bip01 l finger3": "mixamorig1_LeftHandRing1",
	"bip01 l finger31": "mixamorig1_LeftHandRing2",
	"bip01 l finger32": "mixamorig1_LeftHandRing3",
	"bip01 l finger4": "mixamorig1_LeftHandPinky1",
	"bip01 l finger41": "mixamorig1_LeftHandPinky2",
	"bip01 l finger42": "mixamorig1_LeftHandPinky3",

	# Right Arm
	"bip01 r clavicle": "mixamorig1_RightShoulder",
	"bip01 r upperarm": "mixamorig1_RightArm",
	"bip01 r forearm": "mixamorig1_RightForeArm",
	"bip01 r hand": "mixamorig1_RightHand",

	# Right Fingers
	"bip01 r finger0": "mixamorig1_RightHandThumb1",
	"bip01 r finger01": "mixamorig1_RightHandThumb2",
	"bip01 r finger02": "mixamorig1_RightHandThumb3",
	"bip01 r finger1": "mixamorig1_RightHandIndex1",
	"bip01 r finger11": "mixamorig1_RightHandIndex2",
	"bip01 r finger12": "mixamorig1_RightHandIndex3",
	"bip01 r finger2": "mixamorig1_RightHandMiddle1",
	"bip01 r finger21": "mixamorig1_RightHandMiddle2",
	"bip01 r finger22": "mixamorig1_RightHandMiddle3",
	"bip01 r finger3": "mixamorig1_RightHandRing1",
	"bip01 r finger31": "mixamorig1_RightHandRing2",
	"bip01 r finger32": "mixamorig1_RightHandRing3",
	"bip01 r finger4": "mixamorig1_RightHandPinky1",
	"bip01 r finger41": "mixamorig1_RightHandPinky2",
	"bip01 r finger42": "mixamorig1_RightHandPinky3",

	# Left Leg
	"bip01 l thigh": "mixamorig1_LeftUpLeg",
	"bip01 l calf": "mixamorig1_LeftLeg",
	"bip01 l foot": "mixamorig1_LeftFoot",
	"bip01 l toe0": "mixamorig1_LeftToeBase",

	# Right Leg
	"bip01 r thigh": "mixamorig1_RightUpLeg",
	"bip01 r calf": "mixamorig1_RightLeg",
	"bip01 r foot": "mixamorig1_RightFoot",
	"bip01 r toe0": "mixamorig1_RightToeBase",

	# Beast race additions
	"bip01 tail": "mixamorig1_Tail",  # Custom addition for beast races
}


## Mixamo to Morrowind reverse mapping (auto-generated)
static var _mixamo_to_morrowind: Dictionary = {}


## Standard Mixamo bone names in hierarchy order (matches Godot FBX import naming)
const MIXAMO_BONE_ORDER := [
	"mixamorig1_Hips",
	"mixamorig1_Spine",
	"mixamorig1_Spine1",
	"mixamorig1_Spine2",
	"mixamorig1_Neck",
	"mixamorig1_Head",
	"mixamorig1_HeadTop_End",
	"mixamorig1_LeftShoulder",
	"mixamorig1_LeftArm",
	"mixamorig1_LeftForeArm",
	"mixamorig1_LeftHand",
	"mixamorig1_LeftHandThumb1",
	"mixamorig1_LeftHandThumb2",
	"mixamorig1_LeftHandThumb3",
	"mixamorig1_LeftHandIndex1",
	"mixamorig1_LeftHandIndex2",
	"mixamorig1_LeftHandIndex3",
	"mixamorig1_LeftHandMiddle1",
	"mixamorig1_LeftHandMiddle2",
	"mixamorig1_LeftHandMiddle3",
	"mixamorig1_LeftHandRing1",
	"mixamorig1_LeftHandRing2",
	"mixamorig1_LeftHandRing3",
	"mixamorig1_LeftHandPinky1",
	"mixamorig1_LeftHandPinky2",
	"mixamorig1_LeftHandPinky3",
	"mixamorig1_RightShoulder",
	"mixamorig1_RightArm",
	"mixamorig1_RightForeArm",
	"mixamorig1_RightHand",
	"mixamorig1_RightHandThumb1",
	"mixamorig1_RightHandThumb2",
	"mixamorig1_RightHandThumb3",
	"mixamorig1_RightHandIndex1",
	"mixamorig1_RightHandIndex2",
	"mixamorig1_RightHandIndex3",
	"mixamorig1_RightHandMiddle1",
	"mixamorig1_RightHandMiddle2",
	"mixamorig1_RightHandMiddle3",
	"mixamorig1_RightHandRing1",
	"mixamorig1_RightHandRing2",
	"mixamorig1_RightHandRing3",
	"mixamorig1_RightHandPinky1",
	"mixamorig1_RightHandPinky2",
	"mixamorig1_RightHandPinky3",
	"mixamorig1_LeftUpLeg",
	"mixamorig1_LeftLeg",
	"mixamorig1_LeftFoot",
	"mixamorig1_LeftToeBase",
	"mixamorig1_LeftToe_End",
	"mixamorig1_RightUpLeg",
	"mixamorig1_RightLeg",
	"mixamorig1_RightFoot",
	"mixamorig1_RightToeBase",
	"mixamorig1_RightToe_End",
]


## Simplified bone list (no fingers, for performance/LOD)
const MIXAMO_CORE_BONES := [
	"mixamorig1_Hips",
	"mixamorig1_Spine",
	"mixamorig1_Spine1",
	"mixamorig1_Spine2",
	"mixamorig1_Neck",
	"mixamorig1_Head",
	"mixamorig1_LeftShoulder",
	"mixamorig1_LeftArm",
	"mixamorig1_LeftForeArm",
	"mixamorig1_LeftHand",
	"mixamorig1_RightShoulder",
	"mixamorig1_RightArm",
	"mixamorig1_RightForeArm",
	"mixamorig1_RightHand",
	"mixamorig1_LeftUpLeg",
	"mixamorig1_LeftLeg",
	"mixamorig1_LeftFoot",
	"mixamorig1_RightUpLeg",
	"mixamorig1_RightLeg",
	"mixamorig1_RightFoot",
]


## Initialize the reverse mapping
static func _static_init() -> void:
	_mixamo_to_morrowind.clear()
	for mw_name: String in MORROWIND_TO_MIXAMO:
		var mixamo_name: String = MORROWIND_TO_MIXAMO[mw_name]
		_mixamo_to_morrowind[mixamo_name] = mw_name


## Get Mixamo bone name from Morrowind bone name
static func to_mixamo(morrowind_name: String) -> String:
	var lower := morrowind_name.to_lower().strip_edges()
	return MORROWIND_TO_MIXAMO.get(lower, "")


## Get Morrowind bone name from Mixamo bone name
static func to_morrowind(mixamo_name: String) -> String:
	if _mixamo_to_morrowind.is_empty():
		_static_init()
	return _mixamo_to_morrowind.get(mixamo_name, "")


## Check if a bone name is a Morrowind bone
static func is_morrowind_bone(name: String) -> bool:
	return name.to_lower().strip_edges() in MORROWIND_TO_MIXAMO


## Check if a bone name is a Mixamo bone
static func is_mixamo_bone(name: String) -> bool:
	return name.begins_with("mixamorig1_") or name.begins_with("mixamorig_")


## Remap an array of bone names from Morrowind to Mixamo
static func remap_bone_names(morrowind_names: PackedStringArray) -> PackedStringArray:
	var result := PackedStringArray()
	for name in morrowind_names:
		var mapped := to_mixamo(name)
		result.append(mapped if not mapped.is_empty() else name)
	return result


## Build a bone index mapping from Morrowind mesh to Mixamo skeleton
## Returns: Dictionary[int, int] where key=morrowind_index, value=mixamo_index
static func build_bone_index_map(
	morrowind_bone_names: PackedStringArray,
	mixamo_skeleton: Skeleton3D
) -> Dictionary:
	var result := {}

	for i in morrowind_bone_names.size():
		var mw_name := morrowind_bone_names[i]
		var mixamo_name := to_mixamo(mw_name)

		if mixamo_name.is_empty():
			push_warning("BoneMapper: No mapping for Morrowind bone '%s'" % mw_name)
			continue

		var mixamo_idx := mixamo_skeleton.find_bone(mixamo_name)
		if mixamo_idx < 0:
			push_warning("BoneMapper: Mixamo bone '%s' not found in skeleton" % mixamo_name)
			continue

		result[i] = mixamo_idx

	return result


## Get transform correction for a bone (Morrowind → Mixamo)
## Some bones have different orientations between the two skeleton standards
static func get_transform_correction(morrowind_bone: String) -> Transform3D:
	var lower := morrowind_bone.to_lower()

	# Morrowind's root is typically facing forward (Y+)
	# Mixamo's root faces forward (Z-)
	# This requires a 180° rotation around Y
	if lower == "bip01" or lower == "bip01 pelvis":
		return Transform3D(Basis.from_euler(Vector3(0, PI, 0)), Vector3.ZERO)

	# Arms in Morrowind are in T-pose with different rotation
	# May need 90° adjustments - test empirically
	# if "upperarm" in lower:
	#     var angle := PI/2 if "l " in lower else -PI/2
	#     return Transform3D(Basis.from_euler(Vector3(0, 0, angle)), Vector3.ZERO)

	return Transform3D.IDENTITY


## Validate that a skeleton has all required Mixamo bones
static func validate_mixamo_skeleton(skeleton: Skeleton3D, require_fingers: bool = false) -> Dictionary:
	var missing := []
	var found := []

	var required := MIXAMO_CORE_BONES if not require_fingers else MIXAMO_BONE_ORDER

	for bone_name in required:
		if skeleton.find_bone(bone_name) >= 0:
			found.append(bone_name)
		else:
			missing.append(bone_name)

	return {
		"valid": missing.is_empty(),
		"found": found,
		"missing": missing,
		"found_count": found.size(),
		"total_required": required.size()
	}


## Print bone mapping for debugging
static func print_mapping() -> void:
	var lines := PackedStringArray()
	lines.append("=== Morrowind -> Mixamo Bone Mapping ===")
	for mw_name: String in MORROWIND_TO_MIXAMO:
		lines.append("  %s -> %s" % [mw_name, MORROWIND_TO_MIXAMO[mw_name]])
	lines.append("Total: %d mappings" % MORROWIND_TO_MIXAMO.size())
	Log.debug("character", "\n".join(lines))
