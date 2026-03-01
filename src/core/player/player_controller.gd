## Player Controller - 3rd-person character controller with SpringArm3D camera
##
## CharacterBody3D-based player controller with:
## - SpringArm3D orbit camera with collision avoidance
## - First/third-person camera toggle with smooth transition
## - Move-as-Node state machine for movement + combat (via MoveContainer)
## - Character model + animation system integration
## - Freeze/unfreeze for dialogue, cutscenes
## - IK wiring (foot, look-at, hand) via CharacterAnimationSystem
class_name PlayerController
extends CharacterBody3D


#region Signals

## Emitted when player lands on ground
signal landed

## Emitted when player enters water (future)
signal entered_water

## Emitted when player exits water (future)
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

@export_group("Movement")
## Normal run speed in meters per second
@export_range(0.1, 20.0, 0.1) var run_speed: float = 5.0
## Walking speed (when walk key held)
@export_range(0.1, 10.0, 0.1) var walk_speed: float = 2.5
## Sprint speed (when sprint key held)
@export_range(0.1, 30.0, 0.1) var sprint_speed: float = 8.0
## Vertical velocity applied when jumping
@export_range(1.0, 20.0, 0.1) var jump_velocity: float = 4.5
## Whether the walk key is enabled
@export var can_walk: bool = true

@export_group("Camera")
## Mouse sensitivity for camera rotation
@export_range(0.0, 1.0, 0.001) var mouse_sensitivity: float = 0.005
## Enable controller stick support for camera look
@export var controller_support: bool = true
## Controller stick sensitivity for camera rotation
@export_range(0.1, 10.0, 0.1) var controller_sensitivity: float = 2.0
## Maximum vertical camera tilt angle in degrees
@export_range(0.0, 89.0, 1.0) var tilt_limit_degrees: float = 75.0
## Speed at which the character mesh rotates to face movement direction
@export_range(0.1, 50.0, 0.1) var rotation_speed: float = 10.0
## Camera mode: FIRST_PERSON or THIRD_PERSON
@export var camera_mode: CameraMode = CameraMode.THIRD_PERSON:
	set(value):
		camera_mode = value
		if is_node_ready():
			_update_camera_mode()
## Camera distance (SpringArm length) for third-person mode
@export_range(0.0, 10.0, 0.1) var camera_distance: float = 3.5
## Speed of smooth camera transitions between modes
@export_range(1.0, 20.0, 0.1) var camera_transition_speed: float = 8.0
## Allow switching between camera modes
@export var allow_camera_mode_switch: bool = true

@export_group("Collision")
## Player capsule height
@export var player_height: float = 1.8
## Player capsule radius
@export var player_radius: float = 0.35

@export_group("Root Motion")
## Use root motion to drive movement (animation drives position)
@export var use_root_motion: bool = false
## Base rotation offset for character facing direction (radians)
@export var character_facing_offset: float = 0.0

#endregion


#region Node References

## Camera pivot node (rotates with mouse)
var camera_pivot: Node3D

## SpringArm3D for collision avoidance
var spring_arm: SpringArm3D

## The actual camera
var camera: Camera3D

## Collision shape
var collision_shape: CollisionShape3D

## Character model root (set via attach_character)
var character_root: Node3D

## Animation system (set via attach_character)
var animation_system: Node

## Input gatherer (creates InputPackage each frame for MoveContainer)
var _input_gatherer: Node = null  # PlayerInputGatherer

#endregion


#region Public State

## Whether player controls are active
var enabled: bool = false

## Movement input direction (exposed for animation driver)
var input_direction: Vector2 = Vector2.ZERO

## Input magnitude (0-1, for analog stick support)
var input_strength: float = 0.0

## Camera-relative movement direction in world space
var direction: Vector3 = Vector3.ZERO

## Whether player is sprinting
var is_sprinting: bool = false

## Whether player is walking (slow)
var is_walking: bool = false

## Whether player is jumping (upward velocity while airborne)
var is_jumping: bool = false

## Freeze all movement (for dialogue, cutscenes)
var frozen: bool = false

## Whether player is in water (future)
var in_water: bool = false

## Current camera mode
## (use set_camera_mode() or camera_mode export setter)

#endregion


#region Private State

## Target SpringArm distance for smooth transitions
var _target_camera_distance: float = 3.5

## Was on floor last frame (for landing detection)
var _was_on_floor: bool = false

## Tilt limit in radians (computed from degrees)
var _tilt_limit_rad: float = deg_to_rad(75.0)

#endregion


# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	_ensure_input_actions()
	_setup_collision()
	_setup_camera()

	_tilt_limit_rad = deg_to_rad(tilt_limit_degrees)
	_target_camera_distance = 0.0 if camera_mode == CameraMode.FIRST_PERSON else camera_distance
	spring_arm.spring_length = _target_camera_distance

	set_physics_process(true)
	set_process_input(true)


func _physics_process(delta: float) -> void:
	if not enabled:
		return

	# Camera (always updated regardless of movement mode)
	_handle_camera_transition(delta)
	_handle_controller_camera(delta)

	if frozen:
		_handle_frozen_movement()
		move_and_slide()
		return

	# Gather input and let MoveContainer handle movement + animation
	if _input_gatherer and animation_system:
		var input: Resource = _input_gatherer.gather_input()
		if animation_system.has_method("process_moves"):
			animation_system.process_moves(input, delta)

	# Landing detection
	if is_on_floor() and not _was_on_floor:
		landed.emit()
	_was_on_floor = is_on_floor()

	# Update look-at IK target
	if camera_mode == CameraMode.THIRD_PERSON:
		_update_look_target()


# =============================================================================
# INPUT
# =============================================================================

func _unhandled_input(event: InputEvent) -> void:
	if not enabled or frozen:
		return

	# ESC releases mouse
	if event is InputEventKey and event.physical_keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# Click captures mouse
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# Mouse look
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		camera_pivot.rotation.x -= event.relative.y * mouse_sensitivity
		camera_pivot.rotation.x = clampf(camera_pivot.rotation.x, -_tilt_limit_rad, _tilt_limit_rad)
		camera_pivot.rotation.y -= event.relative.x * mouse_sensitivity


func _input(event: InputEvent) -> void:
	if not enabled:
		return

	# Camera mode toggle
	if allow_camera_mode_switch and event.is_action_pressed("toggle_camera"):
		if character_root:
			if camera_mode == CameraMode.FIRST_PERSON:
				set_camera_mode(CameraMode.THIRD_PERSON)
			else:
				set_camera_mode(CameraMode.FIRST_PERSON)


# =============================================================================
# SETUP
# =============================================================================

func _setup_collision() -> void:
	collision_shape = CollisionShape3D.new()
	collision_shape.name = "CollisionShape"
	var capsule := CapsuleShape3D.new()
	capsule.radius = player_radius
	capsule.height = player_height
	collision_shape.shape = capsule
	collision_shape.position.y = player_height / 2.0
	add_child(collision_shape)


func _setup_camera() -> void:
	camera_pivot = Node3D.new()
	camera_pivot.name = "CameraPivot"
	camera_pivot.position.y = 1.5  # Eye height
	add_child(camera_pivot)

	spring_arm = SpringArm3D.new()
	spring_arm.name = "SpringArm3D"
	spring_arm.spring_length = camera_distance
	spring_arm.collision_mask = 1  # World collision layer
	spring_arm.margin = 0.2
	camera_pivot.add_child(spring_arm)

	camera = Camera3D.new()
	camera.name = "PlayerCamera"
	camera.far = 2000.0
	camera.current = false
	spring_arm.add_child(camera)


## Create and wire up the PlayerInputGatherer
func _setup_input_gatherer() -> void:
	if _input_gatherer:
		_input_gatherer.queue_free()
	var GathererClass := preload("res://src/core/character/controller/player_input_gatherer.gd")
	_input_gatherer = GathererClass.new()
	_input_gatherer.name = "InputGatherer"
	_input_gatherer.camera_pivot = camera_pivot
	add_child(_input_gatherer)


## Register required input actions if they don't exist
func _ensure_input_actions() -> void:
	var actions: Dictionary = {
		"move_forward": KEY_W,
		"move_backward": KEY_S,
		"move_left": KEY_A,
		"move_right": KEY_D,
		"sprint": KEY_SHIFT,
		"walk": KEY_CTRL,
		"jump": KEY_SPACE,
		"toggle_camera": KEY_V,
	}
	for action_name: String in actions:
		if not InputMap.has_action(action_name):
			InputMap.add_action(action_name)
			var key_event := InputEventKey.new()
			key_event.physical_keycode = actions[action_name]
			InputMap.action_add_event(action_name, key_event)


# =============================================================================
# PUBLIC API
# =============================================================================

## Attach a character model and animation system to this controller.
## character: Node3D root from any character factory (MW or Humanoid).
## anim_sys: CharacterAnimationSystem (or subclass) for animation state updates.
func attach_character(character: Node3D, anim_sys: Node = null) -> void:
	character_root = character

	# Add character root as child if not already parented
	if character_root.get_parent() != self:
		if character_root.get_parent():
			character_root.get_parent().remove_child(character_root)
		add_child(character_root)

	animation_system = anim_sys

	# Wire IK controller to use this CharacterBody3D for raycasts
	if anim_sys and anim_sys.has_method("set_character_body"):
		anim_sys.set_character_body(self)

	# Create input gatherer (reads hardware input into InputPackage)
	_setup_input_gatherer()

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


## Enable the player controller and capture mouse
func enable() -> void:
	enabled = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if camera:
		camera.current = true


## Disable the player controller and release mouse
func disable() -> void:
	enabled = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if camera:
		camera.current = false
	velocity = Vector3.ZERO


## Freeze character (pause movement, e.g. for dialogue)
func freeze() -> void:
	frozen = true
	velocity = Vector3.ZERO
	input_direction = Vector2.ZERO
	is_sprinting = false
	is_walking = false


## Unfreeze character
func unfreeze() -> void:
	frozen = false


## Teleport player to a position
func teleport_to(pos: Vector3) -> void:
	global_position = pos
	velocity = Vector3.ZERO


## Get the camera's global position (useful for streaming systems)
func get_camera_position() -> Vector3:
	if camera:
		return camera.global_position
	return global_position + Vector3(0, 1.5, 0)


## Get the camera node
func get_camera() -> Camera3D:
	return camera


## Enable/disable root motion
func set_root_motion(p_enabled: bool) -> void:
	use_root_motion = p_enabled


# =============================================================================
# MOVEMENT (legacy — kept for fallback when MoveContainer is not active)
# =============================================================================
# Movement is now handled by individual Move nodes (IdleMove, RunMove, etc.)
# via the MoveContainer in CharacterAnimationSystem. These methods are kept
# for backwards compatibility when enable_moves=false.


func _handle_frozen_movement() -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	input_direction = Vector2.ZERO
	is_sprinting = false
	is_walking = false


# =============================================================================
# CAMERA
# =============================================================================

func _update_camera_mode() -> void:
	if camera_mode == CameraMode.FIRST_PERSON:
		_target_camera_distance = 0.0
	else:
		_target_camera_distance = camera_distance


func _handle_camera_transition(delta: float) -> void:
	if not spring_arm:
		return
	spring_arm.spring_length = lerpf(
		spring_arm.spring_length, _target_camera_distance, camera_transition_speed * delta)

	# Show/hide character based on transition progress
	if character_root and camera_distance > 0.0:
		var progress := spring_arm.spring_length / camera_distance
		_set_character_visible(progress > 0.3)
	elif character_root:
		_set_character_visible(camera_mode == CameraMode.THIRD_PERSON)


func _handle_controller_camera(delta: float) -> void:
	if not controller_support or frozen:
		return
	if not InputMap.has_action("look_left") or not InputMap.has_action("look_right"):
		return
	if not InputMap.has_action("look_up") or not InputMap.has_action("look_down"):
		return
	var look_dir := Input.get_vector("look_left", "look_right", "look_up", "look_down")
	if look_dir != Vector2.ZERO:
		camera_pivot.rotation.y -= look_dir.x * controller_sensitivity * delta
		camera_pivot.rotation.x += look_dir.y * controller_sensitivity * delta
		camera_pivot.rotation.x = clampf(camera_pivot.rotation.x, -_tilt_limit_rad, _tilt_limit_rad)


func _set_character_visible(p_visible: bool) -> void:
	if not character_root:
		return
	for child in character_root.get_children():
		if child is Skeleton3D:
			for skel_child in child.get_children():
				if skel_child is MeshInstance3D:
					skel_child.visible = p_visible
		elif child is MeshInstance3D:
			child.visible = p_visible


# =============================================================================
# IK
# =============================================================================

func _update_look_target() -> void:
	if not animation_system or not camera:
		return
	# Project 20m forward from camera
	var look_pos := camera.global_position + (-camera.global_transform.basis.z * 20.0)
	if animation_system.has_method("set_look_position"):
		animation_system.set_look_position(look_pos)


# =============================================================================
# HELPERS
# =============================================================================

func _get_animation_tree() -> AnimationTree:
	if not animation_system:
		return null
	# AnimationTree is on the skeleton, accessible through the animation manager
	if animation_system.has_method("get_animation_tree"):
		return animation_system.get_animation_tree()
	# Fallback: search character hierarchy
	if character_root:
		return _find_node_of_type(character_root, "AnimationTree") as AnimationTree
	return null


func _find_node_of_type(node: Node, type_name: String) -> Node:
	if node.get_class() == type_name:
		return node
	for child in node.get_children():
		var result := _find_node_of_type(child, type_name)
		if result:
			return result
	return null
