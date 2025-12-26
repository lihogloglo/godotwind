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
@export var move_speed: float = 200.0

## Mouse sensitivity
@export var mouse_sensitivity: float = 0.003

## Speed multiplier when holding Ctrl
@export var boost_multiplier: float = 3.0

## Speed adjustment factor for scroll wheel
@export var speed_scale: float = 1.17

## Minimum speed
@export var min_speed: float = 10.0

## Maximum speed
@export var max_speed: float = 1000.0

## Whether camera controls are active
var enabled: bool = true

## Whether mouse is captured
var _mouse_captured: bool = false


func _ready() -> void:
	# Ensure far plane is adequate for world exploration (20km for distant impostors)
	if far < 20000.0:
		far = 20000.0

	# Ensure processing is enabled (needed when script is attached dynamically)
	set_process(true)
	set_process_input(true)


func _input(event: InputEvent) -> void:
	if not enabled or not current:
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
			move_speed = clampf(move_speed * speed_scale, min_speed, max_speed)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			move_speed = clampf(move_speed / speed_scale, min_speed, max_speed)

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

	# Movement only when mouse is captured (right-click held)
	if not _mouse_captured:
		return

	# Get input direction (supports QWERTY, AZERTY, and arrow keys)
	var input_dir := Vector3.ZERO

	# Forward/back (W/S or Z/S or arrows)
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_Z) or Input.is_key_pressed(KEY_UP):
		input_dir.z -= 1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		input_dir.z += 1

	# Left/right (A/D or Q/D or arrows)
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_LEFT):
		input_dir.x -= 1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		input_dir.x += 1

	# Up/down
	if Input.is_key_pressed(KEY_SPACE):
		input_dir.y += 1
	if Input.is_key_pressed(KEY_SHIFT):
		input_dir.y -= 1

	# Apply movement
	if input_dir != Vector3.ZERO:
		var speed := move_speed
		if Input.is_key_pressed(KEY_CTRL):
			speed *= boost_multiplier

		var move_dir := global_transform.basis * input_dir.normalized()
		global_position += move_dir * speed * delta


## Teleport the camera to a position, looking at a target
func teleport_to(pos: Vector3, look_target: Vector3 = Vector3.ZERO) -> void:
	position = pos
	if look_target != Vector3.ZERO:
		look_at(look_target)


## Release mouse capture when disabling
func disable() -> void:
	enabled = false
	if _mouse_captured:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		_mouse_captured = false


## Enable the camera
func enable() -> void:
	enabled = true
