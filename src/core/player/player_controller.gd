## Player Controller - First/third-person character with physics
##
## CharacterBody3D-based player controller with:
## - Walking/running movement with collision
## - Jumping
## - First-person camera with mouse look
## - Third-person camera with orbiting (when character model attached)
## - Optional character model + animation system integration
## - Swimming (future: water Area3D detection)
##
## Controls:
## - WASD/ZQSD/Arrows to move (supports QWERTY, AZERTY, and arrows)
## - Space to jump
## - Shift to run
## - Mouse to look (always captured when active)
## - V to toggle first/third person (when character attached)
class_name PlayerController
extends CharacterBody3D


#region Signals

## Emitted when player lands on ground
signal landed

## Emitted when player enters water
signal entered_water

## Emitted when player exits water
signal exited_water

## Emitted when camera mode changes
signal camera_mode_changed(mode: int)

#endregion


#region Enums

enum CameraMode {
	FIRST_PERSON,
	THIRD_PERSON,
}

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

@export_group("Third Person Camera")

## Distance behind character in third person
@export var tp_distance: float = 4.0

## Height offset above character pivot in third person
@export var tp_height: float = 1.5

## Minimum pitch angle (looking up)
@export var tp_min_pitch: float = -30.0

## Maximum pitch angle (looking down)
@export var tp_max_pitch: float = 60.0

#endregion


#region Node References

## The camera pivot (for vertical rotation)
var camera_pivot: Node3D

## The actual camera
var camera: Camera3D

## Collision shape
var collision_shape: CollisionShape3D

## Character model root (optional — set via attach_character)
var character_root: Node3D

## Animation system (optional — set via attach_character)
var animation_system: Node

#endregion


#region State

## Whether player controls are active
var enabled: bool = false

## Whether player is in water
var in_water: bool = false

## Current camera mode
var camera_mode: CameraMode = CameraMode.FIRST_PERSON

## Current movement input direction
var _input_direction: Vector2 = Vector2.ZERO

## Was on floor last frame
var _was_on_floor: bool = false

## Third person camera yaw/pitch (radians)
var _tp_yaw: float = 0.0
var _tp_pitch: float = 0.2  # Slight downward angle

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


## Setup camera (works for both first and third person)
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


## Attach a character model and animation system to this controller.
## character: Node3D root from any character factory (MW or Mixamo).
## anim_sys: CharacterAnimationSystem (or subclass) for animation state updates.
func attach_character(character: Node3D, anim_sys: Node = null) -> void:
	character_root = character

	# Add character root as child if not already parented
	if character_root.get_parent() != self:
		if character_root.get_parent():
			character_root.get_parent().remove_child(character_root)
		add_child(character_root)

	animation_system = anim_sys

	# Default to third person when character is attached
	set_camera_mode(CameraMode.THIRD_PERSON)


## Set camera mode (first or third person)
func set_camera_mode(mode: CameraMode) -> void:
	camera_mode = mode
	_update_camera_mode()
	camera_mode_changed.emit(mode)


## Toggle between first and third person
func toggle_camera_mode() -> void:
	if camera_mode == CameraMode.FIRST_PERSON:
		set_camera_mode(CameraMode.THIRD_PERSON)
	else:
		set_camera_mode(CameraMode.FIRST_PERSON)


func _update_camera_mode() -> void:
	if camera_mode == CameraMode.THIRD_PERSON:
		# Position camera behind and above character
		camera_pivot.position.y = tp_height
		camera.position = Vector3(0, 0, tp_distance)
		camera.rotation = Vector3.ZERO

		# Show character mesh in third person
		_set_character_visible(true)
	else:
		# First person: camera at eye level, looking forward
		camera_pivot.position.y = player_height - 0.1
		camera.position = Vector3.ZERO
		camera.rotation = Vector3.ZERO

		# Hide character mesh in first person
		_set_character_visible(false)


func _set_character_visible(visible: bool) -> void:
	if not character_root:
		return
	# Toggle visibility of MeshInstance3D children
	for child in character_root.get_children():
		if child is Skeleton3D:
			for skel_child in child.get_children():
				if skel_child is MeshInstance3D:
					skel_child.visible = visible
		elif child is MeshInstance3D:
			child.visible = visible


func _input(event: InputEvent) -> void:
	if not enabled:
		return

	# Toggle camera mode with V
	if event is InputEventKey and event.pressed and event.keycode == KEY_V:
		if character_root:
			toggle_camera_mode()
		return

	# Mouse look
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		var mm: InputEventMouseMotion = event as InputEventMouseMotion

		if camera_mode == CameraMode.THIRD_PERSON:
			# Third person: orbit camera around character
			_tp_yaw -= mm.relative.x * mouse_sensitivity
			_tp_pitch += mm.relative.y * mouse_sensitivity
			_tp_pitch = clampf(_tp_pitch, deg_to_rad(tp_min_pitch), deg_to_rad(tp_max_pitch))
		else:
			# First person: rotate body horizontally, pivot vertically
			rotate_y(-mm.relative.x * mouse_sensitivity)
			camera_pivot.rotate_x(-mm.relative.y * mouse_sensitivity)
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

	# Get movement direction relative to camera facing
	var direction := Vector3.ZERO
	if _input_direction != Vector2.ZERO:
		if camera_mode == CameraMode.THIRD_PERSON:
			# Movement relative to camera yaw (not body rotation)
			var cam_basis := Basis(Vector3.UP, _tp_yaw)
			direction = (cam_basis * Vector3(_input_direction.x, 0, _input_direction.y)).normalized()
		else:
			# Movement relative to body facing
			direction = (transform.basis * Vector3(_input_direction.x, 0, _input_direction.y)).normalized()

	# Apply horizontal movement with some acceleration/deceleration
	if direction != Vector3.ZERO:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed

		# In third person, rotate character to face movement direction
		if camera_mode == CameraMode.THIRD_PERSON:
			var target_angle := atan2(direction.x, direction.z)
			rotation.y = lerp_angle(rotation.y, target_angle, 10.0 * delta)
	else:
		# Decelerate
		velocity.x = move_toward(velocity.x, 0, speed * 0.2)
		velocity.z = move_toward(velocity.z, 0, speed * 0.2)

	move_and_slide()

	# Update animation system with current movement state
	if animation_system and animation_system.has_method("update_from_movement"):
		animation_system.update_from_movement(velocity, is_on_floor())

	# Update third person camera position
	if camera_mode == CameraMode.THIRD_PERSON:
		_update_third_person_camera()


## Update third person camera orbit
func _update_third_person_camera() -> void:
	# Camera pivot sits at character position + height offset
	camera_pivot.rotation = Vector3.ZERO  # Reset pivot rotation
	camera_pivot.position.y = tp_height

	# Calculate camera position in orbit around pivot
	var offset := Vector3.ZERO
	offset.x = sin(_tp_yaw) * cos(_tp_pitch) * tp_distance
	offset.z = cos(_tp_yaw) * cos(_tp_pitch) * tp_distance
	offset.y = sin(_tp_pitch) * tp_distance

	camera.position = offset
	camera.look_at(camera_pivot.global_position, Vector3.UP)


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
