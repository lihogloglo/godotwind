## CharacterMovementController - Handles character physics and movement
##
## Provides basic AI movement for NPCs and creatures
## Uses CharacterBody3D for physics-based collision and movement
##
## Can be extended with AI behavior trees (Beehave) for complex behaviors
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

# References
var animation_controller: CharacterAnimationController
var character_root: Node3D

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


func _ready() -> void:
	# Set up collision layers
	collision_layer = 2  # Actor layer
	collision_mask = 1   # World collision

	# Motion mode
	motion_mode = MOTION_MODE_GROUNDED


## Initialize with character data
func setup(char_root: Node3D, anim_ctrl: CharacterAnimationController) -> void:
	character_root = char_root
	animation_controller = anim_ctrl

	# Add character root as child
	if character_root and not character_root.get_parent():
		add_child(character_root)


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

	# Update wander behavior
	if wander_enabled and not has_movement_target:
		_update_wander(delta)

	# Calculate movement
	var target_velocity := Vector3.ZERO

	if has_movement_target:
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
