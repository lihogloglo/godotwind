## MixamoSkeletonTemplate - Creates standard Mixamo-compatible skeletons
##
## Provides a template skeleton that can receive any Mixamo animation.
## The skeleton is in standard T-pose with correct bone hierarchy.
##
## Usage:
##   var skeleton := MixamoSkeletonTemplate.create()
##   # or for simplified version without fingers:
##   var skeleton := MixamoSkeletonTemplate.create_simplified()
class_name MixamoSkeletonTemplate
extends RefCounted


## Skeleton variants
enum SkeletonType {
	FULL,       # All 65 bones including fingers
	SIMPLIFIED, # 25 core bones, no fingers
	BEAST,      # Full + tail bones
}


## Bone definition structure
class BoneDef:
	var name: String
	var parent: String
	var position: Vector3  # Local position relative to parent
	var rotation: Quaternion  # Local rotation

	func _init(p_name: String, p_parent: String, p_pos: Vector3, p_rot: Quaternion = Quaternion.IDENTITY) -> void:
		name = p_name
		parent = p_parent
		position = p_pos
		rotation = p_rot


## Standard Mixamo T-pose bone definitions
## Positions are in meters, relative to parent bone
## These values approximate a 1.8m tall humanoid
## NOTE: Uses "mixamorig1_" prefix to match Godot's FBX import naming
const BONE_DEFS := [
	# Root / Hips (at ~1m height)
	["mixamorig1_Hips", "", Vector3(0, 1.0, 0), Quaternion.IDENTITY],

	# Spine chain
	["mixamorig1_Spine", "mixamorig1_Hips", Vector3(0, 0.1, 0), Quaternion.IDENTITY],
	["mixamorig1_Spine1", "mixamorig1_Spine", Vector3(0, 0.12, 0), Quaternion.IDENTITY],
	["mixamorig1_Spine2", "mixamorig1_Spine1", Vector3(0, 0.12, 0), Quaternion.IDENTITY],

	# Neck / Head
	["mixamorig1_Neck", "mixamorig1_Spine2", Vector3(0, 0.15, 0), Quaternion.IDENTITY],
	["mixamorig1_Head", "mixamorig1_Neck", Vector3(0, 0.08, 0), Quaternion.IDENTITY],
	["mixamorig1_HeadTop_End", "mixamorig1_Head", Vector3(0, 0.2, 0), Quaternion.IDENTITY],

	# Left Arm
	["mixamorig1_LeftShoulder", "mixamorig1_Spine2", Vector3(0.05, 0.12, 0), Quaternion.IDENTITY],
	["mixamorig1_LeftArm", "mixamorig1_LeftShoulder", Vector3(0.12, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_LeftForeArm", "mixamorig1_LeftArm", Vector3(0.28, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_LeftHand", "mixamorig1_LeftForeArm", Vector3(0.25, 0, 0), Quaternion.IDENTITY],

	# Right Arm
	["mixamorig1_RightShoulder", "mixamorig1_Spine2", Vector3(-0.05, 0.12, 0), Quaternion.IDENTITY],
	["mixamorig1_RightArm", "mixamorig1_RightShoulder", Vector3(-0.12, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_RightForeArm", "mixamorig1_RightArm", Vector3(-0.28, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_RightHand", "mixamorig1_RightForeArm", Vector3(-0.25, 0, 0), Quaternion.IDENTITY],

	# Left Leg
	["mixamorig1_LeftUpLeg", "mixamorig1_Hips", Vector3(0.1, -0.05, 0), Quaternion.IDENTITY],
	["mixamorig1_LeftLeg", "mixamorig1_LeftUpLeg", Vector3(0, -0.45, 0), Quaternion.IDENTITY],
	["mixamorig1_LeftFoot", "mixamorig1_LeftLeg", Vector3(0, -0.42, 0), Quaternion.IDENTITY],
	["mixamorig1_LeftToeBase", "mixamorig1_LeftFoot", Vector3(0, -0.08, 0.12), Quaternion.IDENTITY],
	["mixamorig1_LeftToe_End", "mixamorig1_LeftToeBase", Vector3(0, 0, 0.05), Quaternion.IDENTITY],

	# Right Leg
	["mixamorig1_RightUpLeg", "mixamorig1_Hips", Vector3(-0.1, -0.05, 0), Quaternion.IDENTITY],
	["mixamorig1_RightLeg", "mixamorig1_RightUpLeg", Vector3(0, -0.45, 0), Quaternion.IDENTITY],
	["mixamorig1_RightFoot", "mixamorig1_RightLeg", Vector3(0, -0.42, 0), Quaternion.IDENTITY],
	["mixamorig1_RightToeBase", "mixamorig1_RightFoot", Vector3(0, -0.08, 0.12), Quaternion.IDENTITY],
	["mixamorig1_RightToe_End", "mixamorig1_RightToeBase", Vector3(0, 0, 0.05), Quaternion.IDENTITY],
]


## Finger bone definitions (added to BONE_DEFS for full skeleton)
const FINGER_DEFS := [
	# Left Hand Fingers
	["mixamorig1_LeftHandThumb1", "mixamorig1_LeftHand", Vector3(0.02, 0, 0.02), Quaternion.IDENTITY],
	["mixamorig1_LeftHandThumb2", "mixamorig1_LeftHandThumb1", Vector3(0.03, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_LeftHandThumb3", "mixamorig1_LeftHandThumb2", Vector3(0.025, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_LeftHandThumb4", "mixamorig1_LeftHandThumb3", Vector3(0.02, 0, 0), Quaternion.IDENTITY],

	["mixamorig1_LeftHandIndex1", "mixamorig1_LeftHand", Vector3(0.08, 0, 0.015), Quaternion.IDENTITY],
	["mixamorig1_LeftHandIndex2", "mixamorig1_LeftHandIndex1", Vector3(0.035, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_LeftHandIndex3", "mixamorig1_LeftHandIndex2", Vector3(0.025, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_LeftHandIndex4", "mixamorig1_LeftHandIndex3", Vector3(0.02, 0, 0), Quaternion.IDENTITY],

	["mixamorig1_LeftHandMiddle1", "mixamorig1_LeftHand", Vector3(0.08, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_LeftHandMiddle2", "mixamorig1_LeftHandMiddle1", Vector3(0.04, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_LeftHandMiddle3", "mixamorig1_LeftHandMiddle2", Vector3(0.03, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_LeftHandMiddle4", "mixamorig1_LeftHandMiddle3", Vector3(0.02, 0, 0), Quaternion.IDENTITY],

	["mixamorig1_LeftHandRing1", "mixamorig1_LeftHand", Vector3(0.075, 0, -0.015), Quaternion.IDENTITY],
	["mixamorig1_LeftHandRing2", "mixamorig1_LeftHandRing1", Vector3(0.035, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_LeftHandRing3", "mixamorig1_LeftHandRing2", Vector3(0.025, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_LeftHandRing4", "mixamorig1_LeftHandRing3", Vector3(0.02, 0, 0), Quaternion.IDENTITY],

	["mixamorig1_LeftHandPinky1", "mixamorig1_LeftHand", Vector3(0.065, 0, -0.03), Quaternion.IDENTITY],
	["mixamorig1_LeftHandPinky2", "mixamorig1_LeftHandPinky1", Vector3(0.025, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_LeftHandPinky3", "mixamorig1_LeftHandPinky2", Vector3(0.02, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_LeftHandPinky4", "mixamorig1_LeftHandPinky3", Vector3(0.015, 0, 0), Quaternion.IDENTITY],

	# Right Hand Fingers (mirrored X)
	["mixamorig1_RightHandThumb1", "mixamorig1_RightHand", Vector3(-0.02, 0, 0.02), Quaternion.IDENTITY],
	["mixamorig1_RightHandThumb2", "mixamorig1_RightHandThumb1", Vector3(-0.03, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_RightHandThumb3", "mixamorig1_RightHandThumb2", Vector3(-0.025, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_RightHandThumb4", "mixamorig1_RightHandThumb3", Vector3(-0.02, 0, 0), Quaternion.IDENTITY],

	["mixamorig1_RightHandIndex1", "mixamorig1_RightHand", Vector3(-0.08, 0, 0.015), Quaternion.IDENTITY],
	["mixamorig1_RightHandIndex2", "mixamorig1_RightHandIndex1", Vector3(-0.035, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_RightHandIndex3", "mixamorig1_RightHandIndex2", Vector3(-0.025, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_RightHandIndex4", "mixamorig1_RightHandIndex3", Vector3(-0.02, 0, 0), Quaternion.IDENTITY],

	["mixamorig1_RightHandMiddle1", "mixamorig1_RightHand", Vector3(-0.08, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_RightHandMiddle2", "mixamorig1_RightHandMiddle1", Vector3(-0.04, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_RightHandMiddle3", "mixamorig1_RightHandMiddle2", Vector3(-0.03, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_RightHandMiddle4", "mixamorig1_RightHandMiddle3", Vector3(-0.02, 0, 0), Quaternion.IDENTITY],

	["mixamorig1_RightHandRing1", "mixamorig1_RightHand", Vector3(-0.075, 0, -0.015), Quaternion.IDENTITY],
	["mixamorig1_RightHandRing2", "mixamorig1_RightHandRing1", Vector3(-0.035, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_RightHandRing3", "mixamorig1_RightHandRing2", Vector3(-0.025, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_RightHandRing4", "mixamorig1_RightHandRing3", Vector3(-0.02, 0, 0), Quaternion.IDENTITY],

	["mixamorig1_RightHandPinky1", "mixamorig1_RightHand", Vector3(-0.065, 0, -0.03), Quaternion.IDENTITY],
	["mixamorig1_RightHandPinky2", "mixamorig1_RightHandPinky1", Vector3(-0.025, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_RightHandPinky3", "mixamorig1_RightHandPinky2", Vector3(-0.02, 0, 0), Quaternion.IDENTITY],
	["mixamorig1_RightHandPinky4", "mixamorig1_RightHandPinky3", Vector3(-0.015, 0, 0), Quaternion.IDENTITY],
]


## Tail bone definitions (for beast races)
const TAIL_DEFS := [
	["mixamorig1_Tail", "mixamorig1_Hips", Vector3(0, -0.05, -0.1), Quaternion.IDENTITY],
	["mixamorig1_Tail1", "mixamorig1_Tail", Vector3(0, 0, -0.15), Quaternion.IDENTITY],
	["mixamorig1_Tail2", "mixamorig1_Tail1", Vector3(0, 0, -0.15), Quaternion.IDENTITY],
	["mixamorig1_Tail3", "mixamorig1_Tail2", Vector3(0, 0, -0.15), Quaternion.IDENTITY],
	["mixamorig1_Tail_End", "mixamorig1_Tail3", Vector3(0, 0, -0.1), Quaternion.IDENTITY],
]


## Cached skeleton templates
static var _template_full: Skeleton3D = null
static var _template_simplified: Skeleton3D = null
static var _template_beast: Skeleton3D = null


## Create a full Mixamo skeleton with all bones including fingers
static func create(skeleton_type: SkeletonType = SkeletonType.FULL) -> Skeleton3D:
	match skeleton_type:
		SkeletonType.FULL:
			return create_full()
		SkeletonType.SIMPLIFIED:
			return create_simplified()
		SkeletonType.BEAST:
			return create_beast()
		_:
			return create_full()


## Create full skeleton (cached)
static func create_full() -> Skeleton3D:
	if _template_full:
		return _duplicate_skeleton(_template_full)

	var all_defs := []
	all_defs.append_array(BONE_DEFS)
	all_defs.append_array(FINGER_DEFS)

	_template_full = _build_skeleton(all_defs, "Skeleton3D")
	return _duplicate_skeleton(_template_full)


## Create simplified skeleton without fingers (cached)
static func create_simplified() -> Skeleton3D:
	if _template_simplified:
		return _duplicate_skeleton(_template_simplified)

	_template_simplified = _build_skeleton(BONE_DEFS, "Skeleton3D")
	return _duplicate_skeleton(_template_simplified)


## Create beast race skeleton with tail (cached)
static func create_beast() -> Skeleton3D:
	if _template_beast:
		return _duplicate_skeleton(_template_beast)

	var all_defs := []
	all_defs.append_array(BONE_DEFS)
	all_defs.append_array(FINGER_DEFS)
	all_defs.append_array(TAIL_DEFS)

	_template_beast = _build_skeleton(all_defs, "Skeleton3D")
	return _duplicate_skeleton(_template_beast)


## Build a skeleton from bone definitions
static func _build_skeleton(bone_defs: Array, skeleton_name: String) -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	skeleton.name = skeleton_name

	# First pass: add all bones
	var bone_indices := {}
	for def in bone_defs:
		var bone_name: String = def[0]
		var idx := skeleton.add_bone(bone_name)
		bone_indices[bone_name] = idx

	# Second pass: set parents and rest poses
	for def in bone_defs:
		var bone_name: String = def[0]
		var parent_name: String = def[1]
		var position: Vector3 = def[2]
		var rotation: Quaternion = def[3] if def.size() > 3 else Quaternion.IDENTITY

		var idx: int = bone_indices[bone_name]

		# Set parent
		if not parent_name.is_empty() and parent_name in bone_indices:
			skeleton.set_bone_parent(idx, bone_indices[parent_name])

		# Set rest pose
		var rest := Transform3D(Basis(rotation), position)
		skeleton.set_bone_rest(idx, rest)

	skeleton.reset_bone_poses()
	return skeleton


## Duplicate a skeleton template
static func _duplicate_skeleton(source: Skeleton3D) -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	skeleton.name = source.name

	# Copy bones
	for i in source.get_bone_count():
		skeleton.add_bone(source.get_bone_name(i))

	# Copy hierarchy and rest poses
	for i in source.get_bone_count():
		var parent_idx := source.get_bone_parent(i)
		if parent_idx >= 0:
			skeleton.set_bone_parent(i, parent_idx)
		skeleton.set_bone_rest(i, source.get_bone_rest(i))

	skeleton.reset_bone_poses()
	return skeleton


## Clear cached templates (for memory management)
static func clear_cache() -> void:
	_template_full = null
	_template_simplified = null
	_template_beast = null


## Get bone count for a skeleton type
static func get_bone_count(skeleton_type: SkeletonType) -> int:
	match skeleton_type:
		SkeletonType.FULL:
			return BONE_DEFS.size() + FINGER_DEFS.size()
		SkeletonType.SIMPLIFIED:
			return BONE_DEFS.size()
		SkeletonType.BEAST:
			return BONE_DEFS.size() + FINGER_DEFS.size() + TAIL_DEFS.size()
		_:
			return 0


## Print skeleton hierarchy for debugging
static func print_hierarchy(skeleton: Skeleton3D, indent: int = 0) -> void:
	var lines := PackedStringArray()

	# Find root bones
	for i in skeleton.get_bone_count():
		if skeleton.get_bone_parent(i) == -1:
			_collect_bone_recursive(skeleton, i, 0, lines)

	Logger.debug("character", "\n".join(lines))


static func _collect_bone_recursive(skeleton: Skeleton3D, bone_idx: int, depth: int, lines: PackedStringArray) -> void:
	var indent := "  ".repeat(depth)
	var bone_name := skeleton.get_bone_name(bone_idx)
	var rest := skeleton.get_bone_rest(bone_idx)
	lines.append("%s%s [pos: %.3f, %.3f, %.3f]" % [indent, bone_name, rest.origin.x, rest.origin.y, rest.origin.z])

	# Find children
	for i in skeleton.get_bone_count():
		if skeleton.get_bone_parent(i) == bone_idx:
			_collect_bone_recursive(skeleton, i, depth + 1, lines)
