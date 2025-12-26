## IKController - Unified IK system for character animation
##
## Manages multiple IK chains:
## - Foot IK (terrain adaptation)
## - Look-at IK (head/spine tracking)
## - Hand IK (weapon grips, interactions)
##
## Uses SkeletonIK3D internally (compatible with SkeletonModifier3D when available)
class_name IKController
extends Node

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

# IK nodes
var _left_foot_ik: SkeletonIK3D = null
var _right_foot_ik: SkeletonIK3D = null
var _look_at_modifier: Node = null  # Custom look-at (not SkeletonIK3D)

# IK targets
var _left_foot_target: Node3D = null
var _right_foot_target: Node3D = null
var _look_target: Node3D = null
var _look_target_position: Vector3 = Vector3.ZERO
var _left_hand_target: Node3D = null
var _right_hand_target: Node3D = null

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
		_update_foot_ik(delta)

	if enable_look_at and _has_look_target:
		_update_look_at(delta)


# =============================================================================
# FOOT IK
# =============================================================================

## Setup foot IK chains
func _setup_foot_ik() -> void:
	var left_foot_idx: int = _bone_indices.get(&"left_foot", -1)
	var right_foot_idx: int = _bone_indices.get(&"right_foot", -1)
	var left_upper_leg_idx: int = _bone_indices.get(&"left_upper_leg", -1)
	var right_upper_leg_idx: int = _bone_indices.get(&"right_upper_leg", -1)

	if left_foot_idx < 0 or right_foot_idx < 0:
		push_warning("IKController: Foot bones not found, disabling foot IK")
		enable_foot_ik = false
		return

	# Create left foot IK
	_left_foot_ik = SkeletonIK3D.new()
	_left_foot_ik.name = "LeftFootIK"
	if left_upper_leg_idx >= 0:
		_left_foot_ik.root_bone = skeleton.get_bone_name(left_upper_leg_idx)
	_left_foot_ik.tip_bone = skeleton.get_bone_name(left_foot_idx)
	_left_foot_ik.use_magnet = false
	_left_foot_ik.override_tip_basis = false
	skeleton.add_child(_left_foot_ik)

	# Create left foot target
	_left_foot_target = Node3D.new()
	_left_foot_target.name = "LeftFootTarget"
	skeleton.add_child(_left_foot_target)
	_left_foot_ik.target_node = _left_foot_ik.get_path_to(_left_foot_target)

	# Create right foot IK
	_right_foot_ik = SkeletonIK3D.new()
	_right_foot_ik.name = "RightFootIK"
	if right_upper_leg_idx >= 0:
		_right_foot_ik.root_bone = skeleton.get_bone_name(right_upper_leg_idx)
	_right_foot_ik.tip_bone = skeleton.get_bone_name(right_foot_idx)
	_right_foot_ik.use_magnet = false
	_right_foot_ik.override_tip_basis = false
	skeleton.add_child(_right_foot_ik)

	# Create right foot target
	_right_foot_target = Node3D.new()
	_right_foot_target.name = "RightFootTarget"
	skeleton.add_child(_right_foot_target)
	_right_foot_ik.target_node = _right_foot_ik.get_path_to(_right_foot_target)


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

	# Adjust pelvis height
	var target_pelvis_offset: float = minf(left_offset, right_offset)
	_current_pelvis_offset = lerpf(_current_pelvis_offset, target_pelvis_offset, foot_ik_smoothing * delta)
	_apply_pelvis_offset(_current_pelvis_offset)

	# Start IK solving
	_left_foot_ik.start()
	_right_foot_ik.start()


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
	_look_target.remove_meta("tracked_node")


## Update look-at each frame
func _update_look_at(delta: float) -> void:
	var head_idx: int = _bone_indices.get(&"head", -1)
	if head_idx < 0:
		return

	# Get target position
	var target_pos: Vector3
	var tracked_node: Node3D = _look_target.get_meta("tracked_node", null)
	if tracked_node:
		target_pos = tracked_node.global_position
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

	# Get current bone pose
	var current_pose := skeleton.get_bone_global_pose(bone_idx)

	# Calculate target rotation (look at direction)
	var up := Vector3.UP
	var forward := target_dir
	var right := up.cross(forward).normalized()
	if right.length() < 0.01:
		right = Vector3.RIGHT
	up = forward.cross(right).normalized()

	var target_basis := Basis(right, up, -forward)

	# Blend with current rotation
	var blended := current_pose.basis.slerp(target_basis, weight * look_smoothing * delta)

	# Apply to bone
	skeleton.set_bone_global_pose_override(bone_idx, Transform3D(blended, current_pose.origin), weight)


# =============================================================================
# HAND IK
# =============================================================================

## Setup hand IK
func _setup_hand_ik() -> void:
	# Create target nodes
	_left_hand_target = Node3D.new()
	_left_hand_target.name = "LeftHandTarget"
	add_child(_left_hand_target)

	_right_hand_target = Node3D.new()
	_right_hand_target.name = "RightHandTarget"
	add_child(_right_hand_target)


## Set hand IK target
func set_hand_target(hand: StringName, target: Node3D, weight: float = 1.0) -> void:
	if hand == &"left":
		_left_hand_target.set_meta("tracked_node", target)
		_left_hand_weight = weight
	elif hand == &"right":
		_right_hand_target.set_meta("tracked_node", target)
		_right_hand_weight = weight


## Clear hand IK target
func clear_hand_target(hand: StringName) -> void:
	if hand == &"left":
		_left_hand_target.remove_meta("tracked_node")
		_left_hand_weight = 0.0
	elif hand == &"right":
		_right_hand_target.remove_meta("tracked_node")
		_right_hand_weight = 0.0


# =============================================================================
# CONTROL API
# =============================================================================

## Enable/disable foot IK
func set_foot_ik_enabled(enabled: bool) -> void:
	enable_foot_ik = enabled
	if _left_foot_ik:
		if enabled:
			_left_foot_ik.start()
		else:
			_left_foot_ik.stop()
	if _right_foot_ik:
		if enabled:
			_right_foot_ik.start()
		else:
			_right_foot_ik.stop()

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
	ik_enabled_changed.emit(&"hand", enabled)


## Enable/disable all IK
func set_all_enabled(enabled: bool) -> void:
	set_foot_ik_enabled(enabled)
	set_look_at_enabled(enabled)
	set_hand_ik_enabled(enabled)


# =============================================================================
# BONE DETECTION
# =============================================================================

## Find all relevant bone indices
func _find_bone_indices() -> void:
	if not skeleton:
		return

	var bone_count := skeleton.get_bone_count()

	for i in bone_count:
		var name_lower := skeleton.get_bone_name(i).to_lower()

		# Hips/Pelvis
		if "hip" in name_lower or "pelvis" in name_lower or name_lower == "bip01":
			_bone_indices[&"hips"] = i

		# Spine
		if "spine" in name_lower:
			if "2" in name_lower or "upper" in name_lower:
				_bone_indices[&"spine2"] = i
			elif "1" in name_lower:
				_bone_indices[&"spine1"] = i
			else:
				_bone_indices[&"spine"] = i

		# Head/Neck
		if "head" in name_lower and "neckhead" not in name_lower:
			_bone_indices[&"head"] = i
		if "neck" in name_lower:
			_bone_indices[&"neck"] = i

		# Left leg
		if _is_left_bone(name_lower):
			if "thigh" in name_lower or ("upper" in name_lower and "leg" in name_lower):
				_bone_indices[&"left_upper_leg"] = i
			elif "calf" in name_lower or ("lower" in name_lower and "leg" in name_lower):
				_bone_indices[&"left_lower_leg"] = i
			elif "foot" in name_lower and "toe" not in name_lower:
				_bone_indices[&"left_foot"] = i

		# Right leg
		if _is_right_bone(name_lower):
			if "thigh" in name_lower or ("upper" in name_lower and "leg" in name_lower):
				_bone_indices[&"right_upper_leg"] = i
			elif "calf" in name_lower or ("lower" in name_lower and "leg" in name_lower):
				_bone_indices[&"right_lower_leg"] = i
			elif "foot" in name_lower and "toe" not in name_lower:
				_bone_indices[&"right_foot"] = i

		# Left arm
		if _is_left_bone(name_lower):
			if "upperarm" in name_lower or ("upper" in name_lower and "arm" in name_lower):
				_bone_indices[&"left_upper_arm"] = i
			elif "forearm" in name_lower or ("lower" in name_lower and "arm" in name_lower):
				_bone_indices[&"left_forearm"] = i
			elif "hand" in name_lower and "finger" not in name_lower:
				_bone_indices[&"left_hand"] = i

		# Right arm
		if _is_right_bone(name_lower):
			if "upperarm" in name_lower or ("upper" in name_lower and "arm" in name_lower):
				_bone_indices[&"right_upper_arm"] = i
			elif "forearm" in name_lower or ("lower" in name_lower and "arm" in name_lower):
				_bone_indices[&"right_forearm"] = i
			elif "hand" in name_lower and "finger" not in name_lower:
				_bone_indices[&"right_hand"] = i


## Check if bone name indicates left side
func _is_left_bone(name: String) -> bool:
	return "left" in name or " l " in name or name.ends_with(" l") or \
		   "l " in name.substr(0, 10) or ".l" in name or "_l" in name


## Check if bone name indicates right side
func _is_right_bone(name: String) -> bool:
	return "right" in name or " r " in name or name.ends_with(" r") or \
		   "r " in name.substr(0, 10) or ".r" in name or "_r" in name
