## CharacterMovementController - Handles character physics and movement
##
## Provides basic AI movement for NPCs and creatures
## Uses CharacterBody3D for physics-based collision and movement
##
## Phase 1 enhancements: Slope adaptation, NavMesh pathfinding, IK integration
class_name CharacterMovementController
extends CharacterBody3D

# Movement parameters
@export var walk_speed: float = 1.5  # m/s
@export var run_speed: float = 4.0   # m/s
@export var swim_speed: float = 2.0  # m/s
@export var jump_velocity: float = 4.5
@export var gravity: float = 9.8

# AI parameters
@export var wander_enabled: bool = false
@export var wander_radius: float = 5.0
@export var wander_interval: float = 3.0

# Slope adaptation parameters (Phase 1)
@export var enable_slope_adaptation: bool = true
@export var slope_tilt_strength: float = 0.5  # How much to tilt character on slopes (0-1)
@export var slope_speed_modifier: bool = true  # Adjust speed on slopes

# NavMesh parameters (Phase 1)
@export var use_navmesh: bool = false
@export var navmesh_path_update_interval: float = 0.5

# References
var animation_controller: CharacterAnimationController
var character_root: Node3D
var foot_ik_controller: FootIKController  # Phase 1: IK integration
var animation_lod_manager: AnimationLODManager  # Phase 1: LOD optimization

# State
var is_swimming: bool = false
var movement_target: Vector3 = Vector3.ZERO
var has_movement_target: bool = false

# Wander state
var wander_timer: float = 0.0
var wander_point: Vector3 = Vector3.ZERO

# Collision
var collision_radius: float = 0.4
var collision_height: float = 1.8

# Slope state (Phase 1)
var current_slope_angle: float = 0.0
var current_floor_normal: Vector3 = Vector3.UP

# NavMesh state (Phase 1)
var navigation_agent: NavigationAgent3D
var navmesh_path_timer: float = 0.0
var using_navmesh_path: bool = false


func _ready() -> void:
	# Set up collision layers
	collision_layer = 2  # Actor layer
	collision_mask = 1   # World collision

	# Motion mode
	motion_mode = MOTION_MODE_GROUNDED

	# Setup NavMesh agent (Phase 1)
	if use_navmesh:
		_setup_navigation_agent()


## Initialize with character data
func setup(char_root: Node3D, anim_ctrl: CharacterAnimationController) -> void:
	character_root = char_root
	animation_controller = anim_ctrl

	# Add character root as child
	if character_root and not character_root.get_parent():
		add_child(character_root)

	# Setup Phase 1 features
	_setup_phase1_features()


## Set movement target
func move_to(target: Vector3) -> void:
	movement_target = target
	has_movement_target = true


## Stop movement
func stop_movement() -> void:
	has_movement_target = false
	velocity = Vector3.ZERO


func _physics_process(delta: float) -> void:
	# Handle swimming
	_update_swimming_state()

	# Apply gravity if not swimming
	if not is_on_floor() and not is_swimming:
		velocity.y -= gravity * delta

	# Update NavMesh pathfinding (Phase 1)
	if use_navmesh and navigation_agent:
		_update_navmesh_pathfinding(delta)

	# Update wander behavior
	if wander_enabled and not has_movement_target and not using_navmesh_path:
		_update_wander(delta)

	# Calculate movement
	var target_velocity := Vector3.ZERO

	if using_navmesh_path and navigation_agent:
		target_velocity = _calculate_navmesh_movement(delta)
	elif has_movement_target:
		target_velocity = _calculate_movement_to_target(delta)
	elif wander_enabled:
		target_velocity = _calculate_wander_movement(delta)

	# Apply movement
	velocity.x = target_velocity.x
	velocity.z = target_velocity.z

	if is_swimming:
		velocity.y = target_velocity.y

	# Move character
	move_and_slide()

	# Phase 1: Update slope adaptation
	if enable_slope_adaptation and is_on_floor():
		_update_slope_adaptation(delta)

	# Update animation
	if animation_controller:
		animation_controller.update_animation(delta, velocity, is_on_floor())
		animation_controller.set_swimming_mode(is_swimming)


## Calculate movement towards target
func _calculate_movement_to_target(delta: float) -> Vector3:
	var direction := (movement_target - global_position).normalized()
	var distance := global_position.distance_to(movement_target)

	# Stop if close enough
	if distance < 0.5:
		has_movement_target = false
		return Vector3.ZERO

	# Determine speed (walk by default, run if far away)
	var speed := walk_speed
	if distance > 10.0:
		speed = run_speed

	# Calculate velocity
	var target_velocity := direction * speed

	# Look at target
	if direction.length() > 0.01:
		var look_target := global_position + Vector3(direction.x, 0, direction.z)
		look_at(look_target, Vector3.UP)

	return target_velocity


## Calculate wander movement
func _calculate_wander_movement(_delta: float) -> Vector3:
	var direction := (wander_point - global_position).normalized()
	var distance := global_position.distance_to(wander_point)

	# Stop if close enough
	if distance < 0.5:
		return Vector3.ZERO

	var target_velocity := direction * walk_speed

	# Look at wander point
	if direction.length() > 0.01:
		var look_target := global_position + Vector3(direction.x, 0, direction.z)
		look_at(look_target, Vector3.UP)

	return target_velocity


## Update wander behavior
func _update_wander(delta: float) -> void:
	wander_timer -= delta

	if wander_timer <= 0:
		# Pick new wander point
		var angle := randf() * TAU
		var dist := randf() * wander_radius
		wander_point = global_position + Vector3(
			cos(angle) * dist,
			0,
			sin(angle) * dist
		)
		wander_timer = wander_interval


## Update swimming state based on water detection
func _update_swimming_state() -> void:
	# TODO: Implement proper water detection using cell water level
	# For now, swimming is disabled
	is_swimming = false


## Set collision shape dimensions
func set_collision_shape(radius: float, height: float) -> void:
	collision_radius = radius
	collision_height = height

	# Find or create collision shape
	var shape_node: CollisionShape3D = null
	for child in get_children():
		if child is CollisionShape3D:
			shape_node = child as CollisionShape3D
			break

	if not shape_node:
		shape_node = CollisionShape3D.new()
		shape_node.name = "CollisionShape3D"
		add_child(shape_node)

	# Create capsule shape
	var capsule := CapsuleShape3D.new()
	capsule.radius = radius
	capsule.height = height
	shape_node.shape = capsule

	# Position at center of height
	shape_node.position = Vector3(0, height / 2.0, 0)


# ============================================================================
# PHASE 1 IMPLEMENTATIONS
# ============================================================================

## Setup Phase 1 features (IK, LOD, etc.)
func _setup_phase1_features() -> void:
	# Setup Foot IK Controller
	if enable_slope_adaptation and character_root:
		var skeleton := _find_skeleton(character_root)
		if skeleton:
			foot_ik_controller = FootIKController.new()
			foot_ik_controller.name = "FootIKController"
			add_child(foot_ik_controller)
			foot_ik_controller.setup(skeleton, self)

	# Setup Animation LOD Manager
	if animation_controller:
		animation_lod_manager = AnimationLODManager.new()
		animation_lod_manager.name = "AnimationLODManager"
		add_child(animation_lod_manager)
		animation_lod_manager.setup(animation_controller, self)


## Find skeleton in character hierarchy
func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D

	for child in node.get_children():
		var result := _find_skeleton(child)
		if result:
			return result

	return null


## Setup navigation agent for NavMesh pathfinding
func _setup_navigation_agent() -> void:
	navigation_agent = NavigationAgent3D.new()
	navigation_agent.name = "NavigationAgent3D"
	navigation_agent.path_desired_distance = 0.5
	navigation_agent.target_desired_distance = 0.5
	navigation_agent.radius = collision_radius
	navigation_agent.height = collision_height
	add_child(navigation_agent)


## Update slope adaptation (body tilt and speed modifier)
func _update_slope_adaptation(delta: float) -> void:
	if not character_root:
		return

	# Get floor normal
	current_floor_normal = get_floor_normal()
	current_slope_angle = current_floor_normal.angle_to(Vector3.UP)

	# Apply body tilt to match slope
	if current_slope_angle > 0.01:  # Small threshold to avoid jitter on flat ground
		# Calculate rotation to align with slope
		var target_basis := _calculate_slope_aligned_basis(current_floor_normal)

		# Smoothly interpolate to target rotation
		var smoothing := 10.0 * delta
		character_root.global_transform.basis = character_root.global_transform.basis.slerp(
			target_basis,
			smoothing * slope_tilt_strength
		)


## Calculate basis aligned with slope
func _calculate_slope_aligned_basis(floor_normal: Vector3) -> Basis:
	# Get current forward direction (ignore Y component)
	var forward := -character_root.global_transform.basis.z
	forward.y = 0
	forward = forward.normalized()

	if forward.length() < 0.01:
		forward = Vector3.FORWARD

	# Create basis aligned with floor
	var right := forward.cross(floor_normal).normalized()
	var aligned_forward := floor_normal.cross(right).normalized()

	return Basis(right, floor_normal, -aligned_forward)


## Get modified speed based on slope
func get_slope_modified_speed(base_speed: float) -> float:
	if not slope_speed_modifier or current_slope_angle < 0.1:
		return base_speed

	# Calculate speed modifier based on slope angle
	# Uphill: slower, Downhill: faster
	var movement_dir := velocity.normalized()
	var slope_dir := Vector3.UP.cross(current_floor_normal.cross(Vector3.UP)).normalized()

	# Dot product tells us if moving uphill (negative) or downhill (positive)
	var slope_factor := movement_dir.dot(slope_dir)

	# Adjust speed: -30% uphill, +20% downhill
	var speed_multiplier := 1.0 - (slope_factor * 0.3)

	return base_speed * clamp(speed_multiplier, 0.7, 1.2)


## Update NavMesh pathfinding
func _update_navmesh_pathfinding(delta: float) -> void:
	if not navigation_agent or not has_movement_target:
		using_navmesh_path = false
		return

	# Update path periodically
	navmesh_path_timer += delta
	if navmesh_path_timer >= navmesh_path_update_interval:
		navmesh_path_timer = 0.0
		navigation_agent.target_position = movement_target
		using_navmesh_path = true

	# Check if reached target
	if navigation_agent.is_navigation_finished():
		using_navmesh_path = false
		has_movement_target = false


## Calculate movement using NavMesh path
func _calculate_navmesh_movement(delta: float) -> Vector3:
	if not navigation_agent or navigation_agent.is_navigation_finished():
		return Vector3.ZERO

	# Get next position on path
	var next_position := navigation_agent.get_next_path_position()
	var direction := (next_position - global_position).normalized()

	# Determine speed
	var distance_to_target := global_position.distance_to(movement_target)
	var speed := walk_speed
	if distance_to_target > 10.0:
		speed = run_speed

	# Apply slope speed modification
	speed = get_slope_modified_speed(speed)

	# Calculate velocity
	var target_velocity := direction * speed

	# Look at movement direction
	if direction.length() > 0.01:
		var look_target := global_position + Vector3(direction.x, 0, direction.z)
		look_at(look_target, Vector3.UP)

	return target_velocity


## Set NavMesh target (alternative to move_to when using NavMesh)
func navigate_to(target: Vector3) -> void:
	movement_target = target
	has_movement_target = true

	if use_navmesh and navigation_agent:
		navigation_agent.target_position = target
		using_navmesh_path = true
		navmesh_path_timer = navmesh_path_update_interval  # Force immediate update


## Enable or disable IK at runtime
func set_ik_enabled(enabled: bool) -> void:
	if foot_ik_controller:
		foot_ik_controller.set_ik_enabled(enabled)


## Get current LOD level (for debugging)
func get_animation_lod_level() -> String:
	if animation_lod_manager:
		return animation_lod_manager.get_lod_level_name()
	return "NONE"
