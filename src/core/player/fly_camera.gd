## Fly Camera - Free-look camera for world exploration
##
## A detached camera that can fly freely through the world without collision.
## Useful for debugging, exploration, and viewing areas.
##
## Controls:
## - Hold Right Click to look and enable movement
## - WASD/ZQSD/Arrows to move (supports QWERTY, AZERTY, and arrows)
## - Space/Shift for up/down
## - Ctrl for speed boost
## - Scroll wheel to adjust speed
class_name FlyCamera
extends Camera3D


## Movement speed in meters per second
@export var move_speed: float = 20.0

## Mouse sensitivity
@export var mouse_sensitivity: float = 0.003

## Speed multiplier when holding Ctrl
@export var boost_multiplier: float = 3.0

## Speed adjustment factor for scroll wheel
@export var speed_scale: float = 1.17

## Minimum speed
@export var min_speed: float = 1.0

## Maximum speed
@export var max_speed: float = 1000.0

## Whether camera controls are active
var enabled: bool = true

## Whether mouse is captured
var _mouse_captured: bool = false

## Optional modal UI check. When set to a Callable that returns true,
## _input and _process early-out (no mouse capture, no movement).
## Injected by the scene at boot — e.g.:
##   fly_camera.modal_check = player_controller.is_modal_ui_open
## or in test scenes:
##   fly_camera.modal_check = session.is_any_panel_open
var modal_check: Callable


func _ready() -> void:
	# Ensure far plane is adequate for world exploration (20km for distant impostors)
	if far < 20000.0:
		far = 20000.0

	# Ensure processing is enabled (needed when script is attached dynamically)
	set_process(true)
	set_process_input(true)

	# §17.2.1 / R.1 — physics_interpolation is on project-wide. FlyCamera
	# owns mouse-look in `_input` (event-driven, render-rate fresh), so
	# the Camera3D node itself must be carved out of physics interpolation.
	# Otherwise the engine would interpolate the camera transform between
	# physics ticks, dropping the in-tick mouse rotation samples.
	# Per Godot 4.4+ advanced physics interpolation docs.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


func _input(event: InputEvent) -> void:
	if not enabled or not current:
		return

	# Modal UI gate — if a dialogue/book/journal panel is open, don't let
	# mouse capture or input through. Injected via modal_check Callable.
	if modal_check.is_valid() and modal_check.call():
		return

	# Mouse capture for looking
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
				_mouse_captured = true
			else:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
				_mouse_captured = false

		# Scroll wheel speed adjustment
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_adjust_speed(true)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_adjust_speed(false)


	# Mouse look
	if event is InputEventMouseMotion and _mouse_captured:
		var mm: InputEventMouseMotion = event as InputEventMouseMotion
		rotate_y(-mm.relative.x * mouse_sensitivity)
		rotate_object_local(Vector3.RIGHT, -mm.relative.y * mouse_sensitivity)
		# Clamp vertical rotation
		rotation.x = clampf(rotation.x, -PI / 2 + 0.1, PI / 2 - 0.1)


func _process(delta: float) -> void:
	if not enabled or not current:
		return

	# Modal UI gate — freeze while panel is open.
	if modal_check.is_valid() and modal_check.call():
		return

	# Movement only when mouse is captured (right-click held)
	if not _mouse_captured:
		return

	# Read movement via InputMap actions (physical_keycode, layout-independent).
	# AZERTY/QWERTY/Dvorak users press the same physical key positions.
	# See src/core/input/input_actions.gd and docs/systems/input_system.md.
	var input_dir := Vector3.ZERO

	# Horizontal plane — get_vector returns (x: left/right, y: forward/back)
	var move_xz := Input.get_vector(
		&"move_left", &"move_right", &"move_forward", &"move_backward")
	input_dir.x = move_xz.x
	input_dir.z = move_xz.y

	# Vertical (jump = up, crouch = down — crouch is bound to both C and CTRL)
	if Input.is_action_pressed(&"jump"):
		input_dir.y += 1.0
	if Input.is_action_pressed(&"crouch"):
		input_dir.y -= 1.0

	# Apply movement
	if input_dir != Vector3.ZERO:
		var speed := move_speed
		# Sprint (SHIFT) acts as the fly-camera boost modifier
		if Input.is_action_pressed(&"sprint"):
			speed *= boost_multiplier

		var move_dir := global_transform.basis * input_dir.normalized()
		global_position += move_dir * speed * delta


## Teleport the camera to a position, looking at a target
func teleport_to(pos: Vector3, look_target: Vector3 = Vector3.ZERO) -> void:
	position = pos
	if look_target != Vector3.ZERO:
		look_at(look_target)
	reset_physics_interpolation()


## Release mouse capture when disabling
func disable() -> void:
	enabled = false
	if _mouse_captured:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		_mouse_captured = false


## Enable the camera
func enable() -> void:
	enabled = true


## Adjust speed up or down by the speed_scale factor
func _adjust_speed(faster: bool) -> void:
	if faster:
		move_speed = clampf(move_speed * speed_scale, min_speed, max_speed)
	else:
		move_speed = clampf(move_speed / speed_scale, min_speed, max_speed)
