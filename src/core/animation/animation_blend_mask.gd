## AnimationBlendMask - Defines which bones are affected by an animation layer
##
## Based on OpenMW's BlendMask system (animation.cpp)
## Morrowind uses 4 blend masks:
## - Lower body (legs, pelvis) - for locomotion
## - Torso (spine, chest) - for upper body actions
## - Left arm - for shield/left hand actions
## - Right arm - for weapon/right hand actions
##
## This allows overlapping animations like walking while attacking
class_name AnimationBlendMask
extends RefCounted

# Predefined mask types matching OpenMW
enum MaskType {
	LOWER_BODY = 0,    # Legs and pelvis
	TORSO = 1,         # Spine chain
	LEFT_ARM = 2,      # Left arm chain
	RIGHT_ARM = 3,     # Right arm chain
	FULL_BODY = 4,     # All bones
}

# Mask root bones (OpenMW's sBlendMaskRoots)
# Everything at and below these bones is included in the mask
const BLEND_MASK_ROOTS := {
	MaskType.LOWER_BODY: "",  # Empty = all bones from root
	MaskType.TORSO: "Bip01 Spine1",
	MaskType.LEFT_ARM: "Bip01 L Clavicle",
	MaskType.RIGHT_ARM: "Bip01 R Clavicle",
	MaskType.FULL_BODY: "",  # Empty = all bones
}

# Alternative bone names for different skeleton conventions
const BONE_ALIASES := {
	"Bip01 Spine1": ["Bip01 Spine1", "bip01 spine1", "Spine1", "spine1"],
	"Bip01 L Clavicle": ["Bip01 L Clavicle", "bip01 l clavicle", "LeftShoulder", "Left Clavicle"],
	"Bip01 R Clavicle": ["Bip01 R Clavicle", "bip01 r clavicle", "RightShoulder", "Right Clavicle"],
}

# Cached bone indices for each mask type
var _mask_bones: Dictionary = {}  # MaskType -> Array[int]

# Reference skeleton
var _skeleton: Skeleton3D = null

# Debug mode
var debug_mode: bool = false


## Build blend masks for a skeleton
func build_masks(skeleton: Skeleton3D) -> void:
	_skeleton = skeleton
	_mask_bones.clear()

	if not skeleton:
		push_error("AnimationBlendMask: Skeleton is required")
		return

	# Build each mask type
	for mask_type in MaskType.values():
		_mask_bones[mask_type] = _build_mask(mask_type)

		if debug_mode:
			print("AnimationBlendMask: Built mask %d with %d bones" % [
				mask_type, _mask_bones[mask_type].size()
			])


## Build a single blend mask
func _build_mask(mask_type: int) -> Array[int]:
	var bones: Array[int] = []

	if mask_type == MaskType.FULL_BODY:
		# Full body includes all bones
		for i in _skeleton.get_bone_count():
			bones.append(i)
		return bones

	# Get root bone for this mask
	var root_name: String = BLEND_MASK_ROOTS.get(mask_type, "")

	if root_name.is_empty():
		# Empty root = all bones from skeleton root
		for i in _skeleton.get_bone_count():
			bones.append(i)
		return bones

	# Find the root bone index
	var root_idx := _find_bone(root_name)
	if root_idx < 0:
		if debug_mode:
			push_warning("AnimationBlendMask: Could not find root bone '%s' for mask %d" % [
				root_name, mask_type
			])
		return bones

	# Add root bone and all descendants
	bones.append(root_idx)
	_add_descendants(root_idx, bones)

	return bones


## Find a bone by name, checking aliases
func _find_bone(bone_name: String) -> int:
	# Try direct lookup first
	var idx := _skeleton.find_bone(bone_name)
	if idx >= 0:
		return idx

	# Try aliases
	var aliases: Array = BONE_ALIASES.get(bone_name, [])
	for alias: String in aliases:
		idx = _skeleton.find_bone(alias)
		if idx >= 0:
			return idx

	# Try case-insensitive search
	var lower := bone_name.to_lower()
	for i in _skeleton.get_bone_count():
		if _skeleton.get_bone_name(i).to_lower() == lower:
			return i

	return -1


## Add all descendants of a bone to the mask
func _add_descendants(bone_idx: int, bones: Array[int]) -> void:
	for i in _skeleton.get_bone_count():
		if _skeleton.get_bone_parent(i) == bone_idx:
			bones.append(i)
			_add_descendants(i, bones)


## Get bone indices for a mask type
func get_mask_bones(mask_type: int) -> Array[int]:
	return _mask_bones.get(mask_type, [] as Array[int])


## Check if a bone is included in a mask
func is_bone_in_mask(bone_idx: int, mask_type: int) -> bool:
	var bones: Array[int] = _mask_bones.get(mask_type, [])
	return bone_idx in bones


## Create a filter bitfield for AnimationTree
## Returns a PackedInt32Array with 1 for included bones, 0 for excluded
func create_filter_array(mask_type: int) -> PackedInt32Array:
	if not _skeleton:
		return PackedInt32Array()

	var filter := PackedInt32Array()
	filter.resize(_skeleton.get_bone_count())
	filter.fill(0)

	var mask_bones: Array[int] = get_mask_bones(mask_type)
	for bone_idx: int in mask_bones:
		if bone_idx >= 0 and bone_idx < filter.size():
			filter[bone_idx] = 1

	return filter


## Get bone weights for smooth blending between masks
## Returns weight 0.0-1.0 for each bone based on mask
func get_bone_weights(mask_type: int) -> PackedFloat32Array:
	if not _skeleton:
		return PackedFloat32Array()

	var weights := PackedFloat32Array()
	weights.resize(_skeleton.get_bone_count())
	weights.fill(0.0)

	var mask_bones: Array[int] = get_mask_bones(mask_type)
	for bone_idx: int in mask_bones:
		if bone_idx >= 0 and bone_idx < weights.size():
			weights[bone_idx] = 1.0

	return weights


## Blend two masks together
## Returns combined bone indices
func blend_masks(mask_a: int, mask_b: int) -> Array[int]:
	var bones_a: Array[int] = get_mask_bones(mask_a)
	var bones_b: Array[int] = get_mask_bones(mask_b)

	var combined: Array[int] = bones_a.duplicate()
	for bone: int in bones_b:
		if bone not in combined:
			combined.append(bone)

	return combined


## Subtract one mask from another
## Returns bones in mask_a but not in mask_b
func subtract_masks(mask_a: int, mask_b: int) -> Array[int]:
	var bones_a: Array[int] = get_mask_bones(mask_a)
	var bones_b: Array[int] = get_mask_bones(mask_b)

	var result: Array[int] = []
	for bone: int in bones_a:
		if bone not in bones_b:
			result.append(bone)

	return result


## Get bones that are ONLY in lower body (not in upper body masks)
func get_lower_body_only() -> Array[int]:
	var lower: Array[int] = get_mask_bones(MaskType.LOWER_BODY)
	var torso: Array[int] = get_mask_bones(MaskType.TORSO)
	var left_arm: Array[int] = get_mask_bones(MaskType.LEFT_ARM)
	var right_arm: Array[int] = get_mask_bones(MaskType.RIGHT_ARM)

	var result: Array[int] = []
	for bone: int in lower:
		if bone not in torso and bone not in left_arm and bone not in right_arm:
			result.append(bone)

	return result


## Get upper body bones (torso + both arms)
func get_upper_body() -> Array[int]:
	return blend_masks(MaskType.TORSO, blend_masks(MaskType.LEFT_ARM, MaskType.RIGHT_ARM)[0])


## Check if skeleton is valid for blend masks
func is_valid() -> bool:
	return _skeleton != null and not _mask_bones.is_empty()


## Get debug info about masks
func get_debug_info() -> String:
	if not _skeleton:
		return "No skeleton set"

	var info := "AnimationBlendMask Debug Info:\n"
	info += "Skeleton: %s (%d bones)\n" % [_skeleton.name, _skeleton.get_bone_count()]

	for mask_type: int in _mask_bones:
		var bones: Array[int] = _mask_bones[mask_type]
		var mask_name := _get_mask_name(mask_type)
		info += "  %s: %d bones\n" % [mask_name, bones.size()]

		if debug_mode:
			for bone_idx: int in bones:
				info += "    - %s\n" % _skeleton.get_bone_name(bone_idx)

	return info


## Get mask type name for debugging
func _get_mask_name(mask_type: int) -> String:
	match mask_type:
		MaskType.LOWER_BODY: return "LOWER_BODY"
		MaskType.TORSO: return "TORSO"
		MaskType.LEFT_ARM: return "LEFT_ARM"
		MaskType.RIGHT_ARM: return "RIGHT_ARM"
		MaskType.FULL_BODY: return "FULL_BODY"
		_: return "UNKNOWN"
