## Player Controller - First-person character with physics
##
## CharacterBody3D-based player controller with:
## - Walking/running movement with collision
## - Jumping
## - First-person camera with mouse look
## - Swimming (future: water Area3D detection)
##
## Controls:
## - WASD/ZQSD/Arrows to move (supports QWERTY, AZERTY, and arrows)
## - Space to jump
## - Shift to run
## - Mouse to look (always captured when active)
class_name PlayerController
extends CharacterBody3D


#region Signals

## Emitted when player lands on ground
signal landed

## Emitted when player enters water
signal entered_water

## Emitted when player exits water
signal exited_water

#endregion


#region Export Variables

## Walking speed in meters per second (Morrowind walk is ~4 m/s)
@export var walk_speed: float = 5.0

## Running speed in meters per second (Morrowind run is ~8 m/s)
@export var run_speed: float = 10.0

## Jump velocity in meters per second (roughly 2m jump height)
@export var jump_velocity: float = 6.0

## Mouse sensitivity
@export var mouse_sensitivity: float = 0.003

## Gravity multiplier (1.0 = Earth gravity)
@export var gravity_multiplier: float = 1.0

## Player height for collision shape
@export var player_height: float = 1.8

## Player radius for collision shape
@export var player_radius: float = 0.35

#endregion


#region Node References

## The camera pivot (for vertical rotation)
var camera_pivot: Node3D

## The actual camera
var camera: Camera3D

## Collision shape
var collision_shape: CollisionShape3D

#endregion


#region State

## Whether player controls are active
var enabled: bool = false

## Whether player is in water
var in_water: bool = false

## Current movement input direction
var _input_direction: Vector2 = Vector2.ZERO

## Was on floor last frame
var _was_on_floor: bool = false

#endregion


#region Constants

## Standard gravity (m/s^2)
const GRAVITY: float = 9.8

#endregion


func _ready() -> void:
	_setup_collision()
	_setup_camera()

	# Ensure processing is enabled (needed when script is attached dynamically)
	set_physics_process(true)
	set_process_input(true)


## Setup collision shape (capsule)
func _setup_collision() -> void:
	collision_shape = CollisionShape3D.new()
	collision_shape.name = "CollisionShape"

	var capsule := CapsuleShape3D.new()
	capsule.radius = player_radius
	capsule.height = player_height
	collision_shape.shape = capsule

	# Position so bottom of capsule is at y=0
	collision_shape.position.y = player_height / 2.0

	add_child(collision_shape)


## Setup first-person camera
func _setup_camera() -> void:
	# Camera pivot at eye level (top of capsule minus some offset)
	camera_pivot = Node3D.new()
	camera_pivot.name = "CameraPivot"
	camera_pivot.position.y = player_height - 0.1  # Eye level
	add_child(camera_pivot)

	camera = Camera3D.new()
	camera.name = "PlayerCamera"
	camera.far = 2000.0
	camera.current = false  # Don't make current until enabled
	camera_pivot.add_child(camera)


func _input(event: InputEvent) -> void:
	if not enabled:
		return

	# Mouse look
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		# Horizontal rotation on player body
		rotate_y(-event.relative.x * mouse_sensitivity)

		# Vertical rotation on camera pivot
		camera_pivot.rotate_x(-event.relative.y * mouse_sensitivity)
		camera_pivot.rotation.x = clampf(camera_pivot.rotation.x, -PI / 2 + 0.1, PI / 2 - 0.1)


func _physics_process(delta: float) -> void:
	if not enabled:
		return

	# Handle gravity
	if not is_on_floor():
		velocity.y -= GRAVITY * gravity_multiplier * delta
	elif not _was_on_floor:
		# Just landed
		landed.emit()

	_was_on_floor = is_on_floor()

	# Get input direction (supports QWERTY, AZERTY, and arrow keys)
	_input_direction = Vector2.ZERO

	# Forward/back (W/S or Z/S or arrows)
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_Z) or Input.is_key_pressed(KEY_UP):
		_input_direction.y -= 1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		_input_direction.y += 1

	# Left/right (A/D or Q/D or arrows)
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_LEFT):
		_input_direction.x -= 1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		_input_direction.x += 1

	_input_direction = _input_direction.normalized()

	# Jump
	if Input.is_key_pressed(KEY_SPACE) and is_on_floor():
		velocity.y = jump_velocity

	# Calculate movement speed
	var speed := run_speed if Input.is_key_pressed(KEY_SHIFT) else walk_speed

	# Get movement direction relative to where player is facing
	var direction := Vector3.ZERO
	if _input_direction != Vector2.ZERO:
		direction = (transform.basis * Vector3(_input_direction.x, 0, _input_direction.y)).normalized()

	# Apply horizontal movement with some acceleration/deceleration
	if direction != Vector3.ZERO:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		# Decelerate
		velocity.x = move_toward(velocity.x, 0, speed * 0.2)
		velocity.z = move_toward(velocity.z, 0, speed * 0.2)

	move_and_slide()


## Enable the player controller and capture mouse
func enable() -> void:
	enabled = true
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	if camera:
		camera.current = true


## Disable the player controller and release mouse
func disable() -> void:
	enabled = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	if camera:
		camera.current = false
	velocity = Vector3.ZERO


## Teleport player to a position
func teleport_to(pos: Vector3) -> void:
	global_position = pos
	velocity = Vector3.ZERO


## Get the camera's global position (useful for streaming systems)
func get_camera_position() -> Vector3:
	if camera:
		return camera.global_position
	return global_position + Vector3(0, player_height - 0.1, 0)


## Get the camera node (for systems that need to track camera)
func get_camera() -> Camera3D:
	return camera
