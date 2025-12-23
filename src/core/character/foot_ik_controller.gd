## FootIKController - Handles foot placement IK for terrain adaptation
##
## Uses Godot's SkeletonIK3D to adjust foot positions based on ground height
## Prevents feet from clipping through terrain or floating above slopes
##
## Phase 1 implementation for production-ready animation system
class_name FootIKController
extends Node

# IK Configuration
@export var enable_ik: bool = true
@export var foot_raycast_length: float = 1.5  # How far to raycast down from feet
@export var foot_offset: float = 0.1  # Offset to prevent clipping
@export var ik_smoothing: float = 5.0  # How smoothly IK adjusts (lower = smoother)
@export var max_foot_adjust: float = 0.5  # Maximum distance foot can move

# References
var skeleton: Skeleton3D
var character_body: CharacterBody3D

# IK Nodes
var left_foot_ik: SkeletonIK3D
var right_foot_ik: SkeletonIK3D

# Bone indices
var left_foot_bone_idx: int = -1
var right_foot_bone_idx: int = -1
var left_upper_leg_bone_idx: int = -1
var right_upper_leg_bone_idx: int = -1

# Raycast targets for foot placement
var left_foot_target: Node3D
var right_foot_target: Node3D

# State
var is_setup: bool = false


func _ready() -> void:
	set_physics_process(false)  # Only enable after setup


## Setup IK system with character skeleton
func setup(char_skeleton: Skeleton3D, char_body: CharacterBody3D) -> void:
	skeleton = char_skeleton
	character_body = char_body

	if not skeleton or not character_body:
		push_warning("FootIKController: Invalid skeleton or character body")
		return

	# Find bone indices
	_find_bone_indices()

	if left_foot_bone_idx < 0 or right_foot_bone_idx < 0:
		push_warning("FootIKController: Could not find foot bones - IK disabled")
		enable_ik = false
		return

	# Create IK nodes
	_setup_ik_chains()

	# Create target nodes
	_setup_targets()

	is_setup = true
	set_physics_process(enable_ik)


## Find foot and leg bone indices
## Supports multiple naming conventions:
## - Standard: "Left Foot", "Right Foot"
## - Morrowind/Bip01: "Bip01 L Foot", "Bip01 R Foot"
## - Blender: "foot.L", "foot.R"
func _find_bone_indices() -> void:
	if not skeleton:
		return

	var bone_count := skeleton.get_bone_count()
	for i in bone_count:
		var bone_name := skeleton.get_bone_name(i).to_lower()

		# Left foot - check multiple naming patterns
		if _is_left_foot_bone(bone_name):
			left_foot_bone_idx = i

		# Right foot
		if _is_right_foot_bone(bone_name):
			right_foot_bone_idx = i

		# Left upper leg (for IK chain root)
		if _is_left_upper_leg_bone(bone_name):
			left_upper_leg_bone_idx = i

		# Right upper leg
		if _is_right_upper_leg_bone(bone_name):
			right_upper_leg_bone_idx = i


## Check if bone name matches left foot patterns
func _is_left_foot_bone(bone_name: String) -> bool:
	# Standard: "left foot", "leftfoot"
	if "left" in bone_name and "foot" in bone_name:
		return true
	# Bip01 style: "bip01 l foot", "l foot"
	if ("l foot" in bone_name or "l_foot" in bone_name) and "l calf" not in bone_name:
		return true
	# Blender style: "foot.l"
	if bone_name.ends_with(".l") and "foot" in bone_name:
		return true
	return false


## Check if bone name matches right foot patterns
func _is_right_foot_bone(bone_name: String) -> bool:
	# Standard: "right foot", "rightfoot"
	if "right" in bone_name and "foot" in bone_name:
		return true
	# Bip01 style: "bip01 r foot", "r foot"
	if ("r foot" in bone_name or "r_foot" in bone_name) and "r calf" not in bone_name:
		return true
	# Blender style: "foot.r"
	if bone_name.ends_with(".r") and "foot" in bone_name:
		return true
	return false


## Check if bone name matches left upper leg patterns
func _is_left_upper_leg_bone(bone_name: String) -> bool:
	# Standard: "left upper leg", "left thigh"
	if "left" in bone_name and ("upper" in bone_name or "thigh" in bone_name) and "leg" in bone_name:
		return true
	# Bip01 style: "bip01 l thigh"
	if ("l thigh" in bone_name or "l_thigh" in bone_name):
		return true
	# Blender style: "thigh.l"
	if bone_name.ends_with(".l") and "thigh" in bone_name:
		return true
	return false


## Check if bone name matches right upper leg patterns
func _is_right_upper_leg_bone(bone_name: String) -> bool:
	# Standard: "right upper leg", "right thigh"
	if "right" in bone_name and ("upper" in bone_name or "thigh" in bone_name) and "leg" in bone_name:
		return true
	# Bip01 style: "bip01 r thigh"
	if ("r thigh" in bone_name or "r_thigh" in bone_name):
		return true
	# Blender style: "thigh.r"
	if bone_name.ends_with(".r") and "thigh" in bone_name:
		return true
	return false


## Setup SkeletonIK3D chains for both feet
func _setup_ik_chains() -> void:
	# Left foot IK
	left_foot_ik = SkeletonIK3D.new()
	left_foot_ik.name = "LeftFootIK"

	if left_upper_leg_bone_idx >= 0:
		left_foot_ik.root_bone = skeleton.get_bone_name(left_upper_leg_bone_idx)

	left_foot_ik.tip_bone = skeleton.get_bone_name(left_foot_bone_idx)
	left_foot_ik.interpolation = ik_smoothing
	left_foot_ik.use_magnet = false
	left_foot_ik.override_tip_basis = false

	skeleton.add_child(left_foot_ik)

	# Right foot IK
	right_foot_ik = SkeletonIK3D.new()
	right_foot_ik.name = "RightFootIK"

	if right_upper_leg_bone_idx >= 0:
		right_foot_ik.root_bone = skeleton.get_bone_name(right_upper_leg_bone_idx)

	right_foot_ik.tip_bone = skeleton.get_bone_name(right_foot_bone_idx)
	right_foot_ik.interpolation = ik_smoothing
	right_foot_ik.use_magnet = false
	right_foot_ik.override_tip_basis = false

	skeleton.add_child(right_foot_ik)


## Setup target nodes for IK
## NOTE: Target nodes are added as siblings to IK nodes (children of skeleton)
## to ensure get_path_to() works correctly in Godot 4.5
func _setup_targets() -> void:
	# Add targets as children of skeleton (same parent as IK nodes)
	# This ensures they share a common ancestor for get_path_to()

	# Left foot target
	left_foot_target = Node3D.new()
	left_foot_target.name = "LeftFootTarget"
	skeleton.add_child(left_foot_target)
	left_foot_ik.target_node = left_foot_ik.get_path_to(left_foot_target)

	# Right foot target
	right_foot_target = Node3D.new()
	right_foot_target.name = "RightFootTarget"
	skeleton.add_child(right_foot_target)
	right_foot_ik.target_node = right_foot_ik.get_path_to(right_foot_target)


func _physics_process(delta: float) -> void:
	if not is_setup or not enable_ik:
		return

	# Update foot target positions based on ground
	_update_foot_targets()

	# Apply IK
	if left_foot_ik:
		left_foot_ik.start()
	if right_foot_ik:
		right_foot_ik.start()


## Update foot target positions using raycasts
func _update_foot_targets() -> void:
	if not skeleton or not character_body:
		return

	# Get current foot positions in world space
	var left_foot_global := skeleton.global_transform * skeleton.get_bone_global_pose(left_foot_bone_idx).origin
	var right_foot_global := skeleton.global_transform * skeleton.get_bone_global_pose(right_foot_bone_idx).origin

	# Raycast down from each foot
	var space_state := character_body.get_world_3d().direct_space_state

	# Left foot raycast
	var left_hit := _raycast_from_foot(space_state, left_foot_global)
	if left_hit:
		var target_pos: Vector3 = left_hit.position + Vector3.UP * foot_offset
		left_foot_target.global_position = _clamp_foot_position(left_foot_global, target_pos)
	else:
		left_foot_target.global_position = left_foot_global

	# Right foot raycast
	var right_hit := _raycast_from_foot(space_state, right_foot_global)
	if right_hit:
		var target_pos: Vector3 = right_hit.position + Vector3.UP * foot_offset
		right_foot_target.global_position = _clamp_foot_position(right_foot_global, target_pos)
	else:
		right_foot_target.global_position = right_foot_global


## Perform raycast from foot position downward
func _raycast_from_foot(space_state: PhysicsDirectSpaceState3D, foot_pos: Vector3) -> Dictionary:
	var ray_start := foot_pos
	var ray_end := foot_pos + Vector3.DOWN * foot_raycast_length

	var query := PhysicsRayQueryParameters3D.create(ray_start, ray_end)
	query.collision_mask = 1  # World geometry layer
	query.exclude = [character_body]  # Don't hit self

	return space_state.intersect_ray(query)


## Clamp foot position to prevent extreme adjustments
func _clamp_foot_position(original: Vector3, target: Vector3) -> Vector3:
	var offset := target - original
	if offset.length() > max_foot_adjust:
		offset = offset.normalized() * max_foot_adjust
	return original + offset


## Enable or disable IK at runtime
func set_ik_enabled(enabled: bool) -> void:
	enable_ik = enabled
	set_physics_process(enabled and is_setup)

	# Stop IK if disabled
	if not enabled:
		if left_foot_ik:
			left_foot_ik.stop()
		if right_foot_ik:
			right_foot_ik.stop()


## Get whether IK is active
func is_ik_active() -> bool:
	return is_setup and enable_ik
