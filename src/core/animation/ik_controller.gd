## IKController - Unified IK system for character animation
##
## Manages multiple IK chains:
## - Foot IK (terrain adaptation)
## - Look-at IK (head/spine tracking)
## - Hand IK (weapon grips, interactions)
##
## Uses TwoBoneIK3D (Godot 4.6 IKModifier3D system) for limb IK
class_name IKController
extends Node

const _SPA := preload("res://src/core/animation/skeleton_profile_adapter.gd")

# Signals
signal target_reached(ik_type: StringName)
signal ik_enabled_changed(ik_type: StringName, enabled: bool)

# IK Types
enum IKType {
	FOOT_LEFT,
	FOOT_RIGHT,
	LOOK_AT,
	HAND_LEFT,
	HAND_RIGHT,
}

# Configuration
@export_group("Foot IK")
@export var enable_foot_ik: bool = true
@export var foot_raycast_length: float = 1.5
@export var foot_offset: float = 0.05
@export var max_foot_adjustment: float = 0.4
@export var foot_ik_smoothing: float = 10.0

@export_group("Look-At IK")
@export var enable_look_at: bool = true
@export var max_look_angle: float = 90.0  # Degrees
@export var head_weight: float = 0.7
@export var neck_weight: float = 0.3
@export var spine_weight: float = 0.1
@export var look_smoothing: float = 5.0

@export_group("Hand IK")
@export var enable_hand_ik: bool = true
@export var hand_ik_smoothing: float = 15.0

# References
var skeleton: Skeleton3D = null
var character_body: CharacterBody3D = null

# Bone indices (populated during setup)
var _bone_indices: Dictionary = {}

# IK nodes (Godot 4.6 TwoBoneIK3D — auto-solves as SkeletonModifier3D)
var _left_foot_ik: TwoBoneIK3D = null
var _right_foot_ik: TwoBoneIK3D = null
var _left_hand_ik: TwoBoneIK3D = null
var _right_hand_ik: TwoBoneIK3D = null
var _look_at_modifier: Node = null  # Custom look-at (not TwoBoneIK3D)

# IK targets and poles (TwoBoneIK3D requires BOTH target + pole Node3D to solve)
var _left_foot_target: Node3D = null
var _right_foot_target: Node3D = null
var _left_foot_pole: Node3D = null
var _right_foot_pole: Node3D = null
var _look_target: Node3D = null
var _look_target_position: Vector3 = Vector3.ZERO
var _left_hand_target: Node3D = null
var _right_hand_target: Node3D = null
var _left_hand_pole: Node3D = null
var _right_hand_pole: Node3D = null

# State
var _is_setup: bool = false
var _has_look_target: bool = false
var _left_hand_weight: float = 0.0
var _right_hand_weight: float = 0.0

# Smoothed values
var _current_pelvis_offset: float = 0.0


func _ready() -> void:
	set_physics_process(false)


## Setup the IK system
func setup(p_skeleton: Skeleton3D, p_character_body: CharacterBody3D = null) -> void:
	skeleton = p_skeleton
	character_body = p_character_body

	if not skeleton:
		push_error("IKController: Skeleton is required")
		return

	# Find bone indices
	_find_bone_indices()

	# Setup IK chains
	if enable_foot_ik:
		_setup_foot_ik()

	if enable_look_at:
		_setup_look_at()

	if enable_hand_ik:
		_setup_hand_ik()

	_is_setup = true
	set_physics_process(true)


## Update IK (called from CharacterAnimationSystem)
func update(delta: float) -> void:
	if not _is_setup:
		return

	if enable_foot_ik:
		if _is_quadruped:
			_update_quadruped_ik(delta)
		else:
			_update_foot_ik(delta)

	if enable_look_at and _has_look_target:
		_update_look_at(delta)

	if enable_hand_ik:
		_update_hand_ik(delta)


# =============================================================================
# FOOT IK
# =============================================================================

## Setup foot IK chains using TwoBoneIK3D (Godot 4.6)
## TwoBoneIK3D requires BOTH a target node AND a pole node to solve.
func _setup_foot_ik() -> void:
	var left_foot_idx: int = _bone_indices.get(&"left_foot", -1)
	var right_foot_idx: int = _bone_indices.get(&"right_foot", -1)
	var left_upper_leg_idx: int = _bone_indices.get(&"left_upper_leg", -1)
	var left_lower_leg_idx: int = _bone_indices.get(&"left_lower_leg", -1)
	var right_upper_leg_idx: int = _bone_indices.get(&"right_upper_leg", -1)
	var right_lower_leg_idx: int = _bone_indices.get(&"right_lower_leg", -1)

	if left_foot_idx < 0 or right_foot_idx < 0:
		push_warning("IKController: Foot bones not found, disabling foot IK")
		enable_foot_ik = false
		return

	# Create left foot IK (TwoBoneIK3D: root=upper_leg, mid=lower_leg, end=foot)
	_left_foot_ik = TwoBoneIK3D.new()
	_left_foot_ik.name = "LeftFootIK"
	_left_foot_ik.set_setting_count(1)
	if left_upper_leg_idx >= 0:
		_left_foot_ik.set_root_bone_name(0, skeleton.get_bone_name(left_upper_leg_idx))
	if left_lower_leg_idx >= 0:
		_left_foot_ik.set_middle_bone_name(0, skeleton.get_bone_name(left_lower_leg_idx))
	_left_foot_ik.set_end_bone_name(0, skeleton.get_bone_name(left_foot_idx))
	_left_foot_ik.set_end_bone_direction(0, SkeletonModifier3D.BONE_DIRECTION_FROM_PARENT)
	_left_foot_ik.set_pole_direction(0, SkeletonModifier3D.SECONDARY_DIRECTION_MINUS_Z)
	skeleton.add_child(_left_foot_ik)

	# Create left foot target
	_left_foot_target = Node3D.new()
	_left_foot_target.name = "LeftFootTarget"
	skeleton.add_child(_left_foot_target)
	_left_foot_ik.set_target_node(0, _left_foot_ik.get_path_to(_left_foot_target))

	# Create left foot pole (knees bend forward)
	_left_foot_pole = Node3D.new()
	_left_foot_pole.name = "LeftFootPole"
	skeleton.add_child(_left_foot_pole)
	_left_foot_ik.set_pole_node(0, _left_foot_ik.get_path_to(_left_foot_pole))

	# Create right foot IK
	_right_foot_ik = TwoBoneIK3D.new()
	_right_foot_ik.name = "RightFootIK"
	_right_foot_ik.set_setting_count(1)
	if right_upper_leg_idx >= 0:
		_right_foot_ik.set_root_bone_name(0, skeleton.get_bone_name(right_upper_leg_idx))
	if right_lower_leg_idx >= 0:
		_right_foot_ik.set_middle_bone_name(0, skeleton.get_bone_name(right_lower_leg_idx))
	_right_foot_ik.set_end_bone_name(0, skeleton.get_bone_name(right_foot_idx))
	_right_foot_ik.set_end_bone_direction(0, SkeletonModifier3D.BONE_DIRECTION_FROM_PARENT)
	_right_foot_ik.set_pole_direction(0, SkeletonModifier3D.SECONDARY_DIRECTION_MINUS_Z)
	skeleton.add_child(_right_foot_ik)

	# Create right foot target
	_right_foot_target = Node3D.new()
	_right_foot_target.name = "RightFootTarget"
	skeleton.add_child(_right_foot_target)
	_right_foot_ik.set_target_node(0, _right_foot_ik.get_path_to(_right_foot_target))

	# Create right foot pole (knees bend forward)
	_right_foot_pole = Node3D.new()
	_right_foot_pole.name = "RightFootPole"
	skeleton.add_child(_right_foot_pole)
	_right_foot_ik.set_pole_node(0, _right_foot_ik.get_path_to(_right_foot_pole))


## Update foot IK each physics frame
func _update_foot_ik(delta: float) -> void:
	if not _left_foot_ik or not _right_foot_ik or not character_body:
		return

	var left_foot_idx: int = _bone_indices.get(&"left_foot", -1)
	var right_foot_idx: int = _bone_indices.get(&"right_foot", -1)

	if left_foot_idx < 0 or right_foot_idx < 0:
		return

	# Get current foot positions
	var left_foot_global := skeleton.global_transform * skeleton.get_bone_global_pose(left_foot_idx).origin
	var right_foot_global := skeleton.global_transform * skeleton.get_bone_global_pose(right_foot_idx).origin

	# Raycast for ground detection
	var space_state := character_body.get_world_3d().direct_space_state

	var left_hit := _raycast_ground(space_state, left_foot_global)
	var right_hit := _raycast_ground(space_state, right_foot_global)

	# Calculate target positions
	var left_target := left_foot_global
	var right_target := right_foot_global
	var left_offset: float = 0.0
	var right_offset: float = 0.0

	if left_hit:
		left_target = left_hit.position + Vector3.UP * foot_offset
		left_target = _clamp_ik_position(left_foot_global, left_target, max_foot_adjustment)
		left_offset = left_target.y - left_foot_global.y

	if right_hit:
		right_target = right_hit.position + Vector3.UP * foot_offset
		right_target = _clamp_ik_position(right_foot_global, right_target, max_foot_adjustment)
		right_offset = right_target.y - right_foot_global.y

	# Smooth interpolation
	_left_foot_target.global_position = _left_foot_target.global_position.lerp(
		left_target, foot_ik_smoothing * delta
	)
	_right_foot_target.global_position = _right_foot_target.global_position.lerp(
		right_target, foot_ik_smoothing * delta
	)

	# Update pole positions (knees bend forward — place poles ahead of character)
	var char_forward := -character_body.global_transform.basis.z
	var knee_height_offset := Vector3.UP * 0.5
	_left_foot_pole.global_position = left_foot_global + char_forward * 0.5 + knee_height_offset
	_right_foot_pole.global_position = right_foot_global + char_forward * 0.5 + knee_height_offset

	# Adjust pelvis height
	var target_pelvis_offset: float = minf(left_offset, right_offset)
	_current_pelvis_offset = lerpf(_current_pelvis_offset, target_pelvis_offset, foot_ik_smoothing * delta)
	_apply_pelvis_offset(_current_pelvis_offset)

	# TwoBoneIK3D solves automatically as SkeletonModifier3D — no start() needed


## Raycast to find ground
func _raycast_ground(space_state: PhysicsDirectSpaceState3D, foot_pos: Vector3) -> Dictionary:
	var ray_start := foot_pos + Vector3.UP * 0.5  # Start slightly above foot
	var ray_end := foot_pos - Vector3.DOWN * foot_raycast_length

	var query := PhysicsRayQueryParameters3D.create(ray_start, ray_end)
	query.collision_mask = 1  # World layer
	if character_body:
		query.exclude = [character_body.get_rid()]

	return space_state.intersect_ray(query)


## Clamp IK position to max adjustment
func _clamp_ik_position(original: Vector3, target: Vector3, max_dist: float) -> Vector3:
	var offset := target - original
	if offset.length() > max_dist:
		offset = offset.normalized() * max_dist
	return original + offset


## Apply pelvis height offset
func _apply_pelvis_offset(offset: float) -> void:
	var hips_idx: int = _bone_indices.get(&"hips", -1)
	if hips_idx < 0:
		return

	# Adjust hips bone position
	var pose := skeleton.get_bone_pose(hips_idx)
	pose.origin.y += offset
	skeleton.set_bone_pose_position(hips_idx, pose.origin)


# =============================================================================
# LOOK-AT IK
# =============================================================================

## Setup look-at system
func _setup_look_at() -> void:
	# Create a target node for look-at
	_look_target = Node3D.new()
	_look_target.name = "LookAtTarget"
	add_child(_look_target)


## Set look-at target node
func set_look_target(target: Node3D) -> void:
	if target:
		_has_look_target = true
		# We'll track the node's position each frame
		_look_target.set_meta("tracked_node", target)
	else:
		clear_look_target()


## Set look-at position
func set_look_position(position: Vector3) -> void:
	_look_target_position = position
	_has_look_target = true
	_look_target.set_meta("tracked_node", null)


## Clear look-at target
func clear_look_target() -> void:
	_has_look_target = false
	if _look_target and _look_target.has_meta("tracked_node"):
		_look_target.remove_meta("tracked_node")


## Update look-at each frame
func _update_look_at(delta: float) -> void:
	var head_idx: int = _bone_indices.get(&"head", -1)
	if head_idx < 0:
		return

	# Get target position
	var target_pos: Vector3
	if _look_target.has_meta("tracked_node"):
		var tracked_node: Node3D = _look_target.get_meta("tracked_node")
		if tracked_node:
			target_pos = tracked_node.global_position
		else:
			target_pos = _look_target_position
	else:
		target_pos = _look_target_position

	# Get head position
	var head_global := skeleton.global_transform * skeleton.get_bone_global_pose(head_idx).origin

	# Calculate direction to target
	var to_target := (target_pos - head_global).normalized()

	# Get character forward direction
	var forward := -skeleton.global_transform.basis.z

	# Check if target is within look cone
	var angle := rad_to_deg(forward.angle_to(to_target))
	if angle > max_look_angle:
		return  # Target outside look range

	# Calculate weight based on angle (smooth falloff)
	var angle_weight := 1.0 - (angle / max_look_angle)
	angle_weight = smoothstep(0.0, 1.0, angle_weight)

	# Apply rotation to head
	_apply_look_rotation(head_idx, to_target, head_weight * angle_weight, delta)

	# Apply to neck if available
	var neck_idx: int = _bone_indices.get(&"neck", -1)
	if neck_idx >= 0:
		_apply_look_rotation(neck_idx, to_target, neck_weight * angle_weight, delta)

	# Apply to upper spine if available
	var spine_idx: int = _bone_indices.get(&"spine2", -1)
	if spine_idx >= 0:
		_apply_look_rotation(spine_idx, to_target, spine_weight * angle_weight, delta)


## Apply look rotation to a bone
func _apply_look_rotation(bone_idx: int, target_dir: Vector3, weight: float, delta: float) -> void:
	if bone_idx < 0 or weight <= 0:
		return

	# Calculate target rotation (look at direction) using Transform3D.looking_at
	var look_xform := Transform3D.IDENTITY.looking_at(target_dir, Vector3.UP)
	var target_quat := look_xform.basis.get_rotation_quaternion()

	# Get current bone rotation as quaternion (via orthonormalized basis to avoid errors)
	var current_quat := skeleton.get_bone_global_pose(bone_idx).basis.orthonormalized().get_rotation_quaternion()

	# Blend in global space using quaternion slerp
	var blend_factor := clampf(weight * look_smoothing * delta, 0.0, 1.0)
	var blended_quat := current_quat.slerp(target_quat, blend_factor)

	# Convert blended global rotation to local pose space
	var parent_idx := skeleton.get_bone_parent(bone_idx)
	var parent_quat := skeleton.get_bone_global_pose(parent_idx).basis.orthonormalized().get_rotation_quaternion() if parent_idx >= 0 else Quaternion.IDENTITY
	var rest_quat := skeleton.get_bone_rest(bone_idx).basis.get_rotation_quaternion()
	var local_rotation := rest_quat.inverse() * parent_quat.inverse() * blended_quat
	skeleton.set_bone_pose_rotation(bone_idx, local_rotation)


# =============================================================================
# HAND IK
# =============================================================================

## Setup hand IK using TwoBoneIK3D (Godot 4.6)
## TwoBoneIK3D requires BOTH a target node AND a pole node to solve.
func _setup_hand_ik() -> void:
	var left_upper_arm_idx: int = _bone_indices.get(&"left_upper_arm", -1)
	var left_forearm_idx: int = _bone_indices.get(&"left_forearm", -1)
	var left_hand_idx: int = _bone_indices.get(&"left_hand", -1)
	var right_upper_arm_idx: int = _bone_indices.get(&"right_upper_arm", -1)
	var right_forearm_idx: int = _bone_indices.get(&"right_forearm", -1)
	var right_hand_idx: int = _bone_indices.get(&"right_hand", -1)

	if left_hand_idx < 0 or right_hand_idx < 0:
		push_warning("IKController: Hand bones not found, disabling hand IK")
		enable_hand_ik = false
		return

	# Create left hand IK (root=upper_arm, mid=forearm, end=hand)
	_left_hand_ik = TwoBoneIK3D.new()
	_left_hand_ik.name = "LeftHandIK"
	_left_hand_ik.active = false  # Disabled until a target is set
	_left_hand_ik.set_setting_count(1)
	if left_upper_arm_idx >= 0:
		_left_hand_ik.set_root_bone_name(0, skeleton.get_bone_name(left_upper_arm_idx))
	if left_forearm_idx >= 0:
		_left_hand_ik.set_middle_bone_name(0, skeleton.get_bone_name(left_forearm_idx))
	_left_hand_ik.set_end_bone_name(0, skeleton.get_bone_name(left_hand_idx))
	_left_hand_ik.set_end_bone_direction(0, SkeletonModifier3D.BONE_DIRECTION_FROM_PARENT)
	_left_hand_ik.set_pole_direction(0, SkeletonModifier3D.SECONDARY_DIRECTION_MINUS_Z)
	skeleton.add_child(_left_hand_ik)

	_left_hand_target = Node3D.new()
	_left_hand_target.name = "LeftHandTarget"
	skeleton.add_child(_left_hand_target)
	_left_hand_ik.set_target_node(0, _left_hand_ik.get_path_to(_left_hand_target))

	_left_hand_pole = Node3D.new()
	_left_hand_pole.name = "LeftHandPole"
	skeleton.add_child(_left_hand_pole)
	_left_hand_ik.set_pole_node(0, _left_hand_ik.get_path_to(_left_hand_pole))

	# Create right hand IK
	_right_hand_ik = TwoBoneIK3D.new()
	_right_hand_ik.name = "RightHandIK"
	_right_hand_ik.active = false  # Disabled until a target is set
	_right_hand_ik.set_setting_count(1)
	if right_upper_arm_idx >= 0:
		_right_hand_ik.set_root_bone_name(0, skeleton.get_bone_name(right_upper_arm_idx))
	if right_forearm_idx >= 0:
		_right_hand_ik.set_middle_bone_name(0, skeleton.get_bone_name(right_forearm_idx))
	_right_hand_ik.set_end_bone_name(0, skeleton.get_bone_name(right_hand_idx))
	_right_hand_ik.set_end_bone_direction(0, SkeletonModifier3D.BONE_DIRECTION_FROM_PARENT)
	_right_hand_ik.set_pole_direction(0, SkeletonModifier3D.SECONDARY_DIRECTION_MINUS_Z)
	skeleton.add_child(_right_hand_ik)

	_right_hand_target = Node3D.new()
	_right_hand_target.name = "RightHandTarget"
	skeleton.add_child(_right_hand_target)
	_right_hand_ik.set_target_node(0, _right_hand_ik.get_path_to(_right_hand_target))

	_right_hand_pole = Node3D.new()
	_right_hand_pole.name = "RightHandPole"
	skeleton.add_child(_right_hand_pole)
	_right_hand_ik.set_pole_node(0, _right_hand_ik.get_path_to(_right_hand_pole))


## Set hand IK target
func set_hand_target(hand: StringName, target: Node3D, weight: float = 1.0) -> void:
	if hand == &"left":
		_left_hand_target.set_meta("tracked_node", target)
		_left_hand_weight = weight
		if _left_hand_ik:
			_left_hand_ik.active = true
	elif hand == &"right":
		_right_hand_target.set_meta("tracked_node", target)
		_right_hand_weight = weight
		if _right_hand_ik:
			_right_hand_ik.active = true


## Update hand IK targets from tracked nodes each frame
func _update_hand_ik(_delta: float) -> void:
	_update_single_hand_ik(_left_hand_target, _left_hand_pole, _left_hand_weight, -1.0)
	_update_single_hand_ik(_right_hand_target, _right_hand_pole, _right_hand_weight, 1.0)


func _update_single_hand_ik(target: Node3D, pole: Node3D, weight: float, side_sign: float) -> void:
	if not target or weight <= 0.0:
		return

	# Copy tracked node position to IK target
	if target.has_meta("tracked_node"):
		var tracked: Node3D = target.get_meta("tracked_node")
		if tracked and is_instance_valid(tracked):
			target.global_position = tracked.global_position

	# Update pole position (elbows bend backward/down relative to character)
	if pole and character_body:
		var char_back := character_body.global_transform.basis.z
		var elbow_pos := character_body.global_position + Vector3(side_sign * 0.3, 1.2, 0)
		pole.global_position = elbow_pos + char_back * 0.5 + Vector3.DOWN * 0.3


## Clear hand IK target
func clear_hand_target(hand: StringName) -> void:
	if hand == &"left":
		if _left_hand_target and _left_hand_target.has_meta("tracked_node"):
			_left_hand_target.remove_meta("tracked_node")
		_left_hand_weight = 0.0
		if _left_hand_ik:
			_left_hand_ik.active = false
	elif hand == &"right":
		if _right_hand_target and _right_hand_target.has_meta("tracked_node"):
			_right_hand_target.remove_meta("tracked_node")
		_right_hand_weight = 0.0
		if _right_hand_ik:
			_right_hand_ik.active = false


# =============================================================================
# CONTROL API
# =============================================================================

## Enable/disable foot IK
func set_foot_ik_enabled(enabled: bool) -> void:
	enable_foot_ik = enabled
	if _left_foot_ik:
		_left_foot_ik.active = enabled
	if _right_foot_ik:
		_right_foot_ik.active = enabled

	ik_enabled_changed.emit(&"foot", enabled)


## Enable/disable look-at IK
func set_look_at_enabled(enabled: bool) -> void:
	enable_look_at = enabled
	if not enabled:
		clear_look_target()
	ik_enabled_changed.emit(&"look_at", enabled)


## Enable/disable hand IK
func set_hand_ik_enabled(enabled: bool) -> void:
	enable_hand_ik = enabled
	if not enabled:
		clear_hand_target(&"left")
		clear_hand_target(&"right")
	if _left_hand_ik:
		_left_hand_ik.active = enabled and _left_hand_weight > 0.0
	if _right_hand_ik:
		_right_hand_ik.active = enabled and _right_hand_weight > 0.0
	ik_enabled_changed.emit(&"hand", enabled)


## Enable/disable all IK
func set_all_enabled(enabled: bool) -> void:
	set_foot_ik_enabled(enabled)
	set_look_at_enabled(enabled)
	set_hand_ik_enabled(enabled)


# =============================================================================
# BONE DETECTION
# =============================================================================

# Maps internal IK keys to SkeletonProfileHumanoid bone names
const _IK_TO_PROFILE := {
	&"hips": &"Hips",
	&"spine": &"Spine",
	&"spine1": &"Chest",
	&"spine2": &"UpperChest",
	&"head": &"Head",
	&"neck": &"Neck",
	&"left_upper_leg": &"LeftUpperLeg",
	&"left_lower_leg": &"LeftLowerLeg",
	&"left_foot": &"LeftFoot",
	&"right_upper_leg": &"RightUpperLeg",
	&"right_lower_leg": &"RightLowerLeg",
	&"right_foot": &"RightFoot",
	&"left_upper_arm": &"LeftUpperArm",
	&"left_forearm": &"LeftLowerArm",
	&"left_hand": &"LeftHand",
	&"right_upper_arm": &"RightUpperArm",
	&"right_forearm": &"RightLowerArm",
	&"right_hand": &"RightHand",
}


## Find all relevant bone indices via _SPA
func _find_bone_indices() -> void:
	if not skeleton:
		return

	_SPA.create_bone_map(skeleton)

	for ik_key: StringName in _IK_TO_PROFILE:
		var profile_bone: StringName = _IK_TO_PROFILE[ik_key]
		var idx := _SPA.get_bone_index(skeleton, profile_bone)
		if idx >= 0:
			_bone_indices[ik_key] = idx


# =============================================================================
# QUADRUPED IK
# =============================================================================

# Quadruped IK state
var _is_quadruped: bool = false
var _front_left_ik: TwoBoneIK3D = null
var _front_right_ik: TwoBoneIK3D = null
var _back_left_ik: TwoBoneIK3D = null
var _back_right_ik: TwoBoneIK3D = null
var _front_left_target: Node3D = null
var _front_right_target: Node3D = null
var _back_left_target: Node3D = null
var _back_right_target: Node3D = null


## Configure IK for quadruped (4-legged) creatures
## Each leg_bones dict should have "upper", "lower", "foot" keys with bone indices
func configure_quadruped_mode(front_left: Dictionary, front_right: Dictionary,
		back_left: Dictionary, back_right: Dictionary) -> void:
	_is_quadruped = true

	# Clear existing humanoid foot IK
	if _left_foot_ik:
		_left_foot_ik.queue_free()
		_left_foot_ik = null
	if _right_foot_ik:
		_right_foot_ik.queue_free()
		_right_foot_ik = null

	# Setup front left leg IK
	if front_left.get("foot", -1) >= 0:
		_front_left_ik = _create_leg_ik("FrontLeftIK", front_left)
		_front_left_target = _create_ik_target("FrontLeftTarget", _front_left_ik)

	# Setup front right leg IK
	if front_right.get("foot", -1) >= 0:
		_front_right_ik = _create_leg_ik("FrontRightIK", front_right)
		_front_right_target = _create_ik_target("FrontRightTarget", _front_right_ik)

	# Setup back left leg IK
	if back_left.get("foot", -1) >= 0:
		_back_left_ik = _create_leg_ik("BackLeftIK", back_left)
		_back_left_target = _create_ik_target("BackLeftTarget", _back_left_ik)

	# Setup back right leg IK
	if back_right.get("foot", -1) >= 0:
		_back_right_ik = _create_leg_ik("BackRightIK", back_right)
		_back_right_target = _create_ik_target("BackRightTarget", _back_right_ik)


## Create a leg IK chain using TwoBoneIK3D (Godot 4.6)
## TwoBoneIK3D requires BOTH a target node AND a pole node to solve.
func _create_leg_ik(ik_name: String, leg_bones: Dictionary) -> TwoBoneIK3D:
	var ik := TwoBoneIK3D.new()
	ik.name = ik_name
	ik.set_setting_count(1)

	var upper_idx: int = leg_bones.get("upper", -1)
	var lower_idx: int = leg_bones.get("lower", -1)
	var foot_idx: int = leg_bones.get("foot", -1)

	if upper_idx >= 0:
		ik.set_root_bone_name(0, skeleton.get_bone_name(upper_idx))
	if lower_idx >= 0:
		ik.set_middle_bone_name(0, skeleton.get_bone_name(lower_idx))
	if foot_idx >= 0:
		ik.set_end_bone_name(0, skeleton.get_bone_name(foot_idx))

	ik.set_end_bone_direction(0, SkeletonModifier3D.BONE_DIRECTION_FROM_PARENT)
	ik.set_pole_direction(0, SkeletonModifier3D.SECONDARY_DIRECTION_MINUS_Z)
	skeleton.add_child(ik)
	return ik


## Create an IK target and pole for a leg
func _create_ik_target(target_name: String, ik: TwoBoneIK3D) -> Node3D:
	var target := Node3D.new()
	target.name = target_name
	skeleton.add_child(target)

	var pole := Node3D.new()
	pole.name = target_name.replace("Target", "Pole")
	skeleton.add_child(pole)

	if ik:
		ik.set_target_node(0, ik.get_path_to(target))
		ik.set_pole_node(0, ik.get_path_to(pole))

	return target


## Update quadruped foot IK each physics frame
func _update_quadruped_ik(delta: float) -> void:
	if not _is_quadruped or not character_body:
		return

	var space_state := character_body.get_world_3d().direct_space_state

	# Update each leg
	if _front_left_ik and _front_left_target:
		_update_leg_ik(_front_left_ik, _front_left_target, space_state, delta)
	if _front_right_ik and _front_right_target:
		_update_leg_ik(_front_right_ik, _front_right_target, space_state, delta)
	if _back_left_ik and _back_left_target:
		_update_leg_ik(_back_left_ik, _back_left_target, space_state, delta)
	if _back_right_ik and _back_right_target:
		_update_leg_ik(_back_right_ik, _back_right_target, space_state, delta)


## Update a single leg's IK
func _update_leg_ik(ik: TwoBoneIK3D, target: Node3D,
		space_state: PhysicsDirectSpaceState3D, delta: float) -> void:
	# Get foot bone index from TwoBoneIK3D end bone
	var foot_idx := skeleton.find_bone(ik.get_end_bone_name(0))
	if foot_idx < 0:
		return

	# Get current foot position
	var foot_global := skeleton.global_transform * skeleton.get_bone_global_pose(foot_idx).origin

	# Raycast for ground
	var hit := _raycast_ground(space_state, foot_global)

	if hit:
		var hit_pos: Vector3 = hit.position
		var target_pos: Vector3 = hit_pos + Vector3.UP * foot_offset
		target_pos = _clamp_ik_position(foot_global, target_pos, max_foot_adjustment)

		# Smooth interpolation
		target.global_position = target.global_position.lerp(target_pos, foot_ik_smoothing * delta)

	# TwoBoneIK3D solves automatically — no start() needed


## Check if configured for quadruped
func is_quadruped() -> bool:
	return _is_quadruped
