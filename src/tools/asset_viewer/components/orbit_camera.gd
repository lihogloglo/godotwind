## Orbit Camera Controller - Reusable camera for 3D asset preview
##
## Features:
## - Spherical coordinate orbit around target
## - Mouse drag to rotate (left/right click)
## - Middle mouse to pan
## - Scroll wheel to zoom
## - Auto-orbit mode
## - Frame object by AABB
class_name OrbitCamera
extends Camera3D

signal camera_changed

# Orbit parameters
var orbit_yaw: float = 0.0
var orbit_pitch: float = 0.3
var orbit_distance: float = 5.0
var orbit_target: Vector3 = Vector3.ZERO

# Configuration
@export var orbit_speed: float = 0.5
@export var auto_orbit: bool = true
@export var min_distance: float = 0.5
@export var max_distance: float = 100.0
@export var pitch_limit: float = PI * 0.49
@export var mouse_sensitivity: float = 0.005
@export var pan_sensitivity: float = 0.01
@export var zoom_factor: float = 0.1

# State
var _is_active: bool = true


func _ready() -> void:
	_update_position()


func _process(delta: float) -> void:
	if _is_active and auto_orbit:
		orbit_yaw += delta * orbit_speed
		_update_position()


func _unhandled_input(event: InputEvent) -> void:
	if not _is_active:
		return

	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP:
			orbit_distance = max(min_distance, orbit_distance * (1.0 - zoom_factor))
			_update_position()
			get_viewport().set_input_as_handled()
		elif mouse_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			orbit_distance = min(max_distance, orbit_distance * (1.0 + zoom_factor))
			_update_position()
			get_viewport().set_input_as_handled()

	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion

		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			# Orbit rotation
			auto_orbit = false
			orbit_yaw -= motion.relative.x * mouse_sensitivity
			orbit_pitch -= motion.relative.y * mouse_sensitivity
			orbit_pitch = clamp(orbit_pitch, -pitch_limit, pitch_limit)
			_update_position()
			get_viewport().set_input_as_handled()

		elif Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
			# Pan
			auto_orbit = false
			var right := global_transform.basis.x
			var up := global_transform.basis.y
			orbit_target -= right * motion.relative.x * pan_sensitivity * orbit_distance * 0.1
			orbit_target += up * motion.relative.y * pan_sensitivity * orbit_distance * 0.1
			_update_position()
			get_viewport().set_input_as_handled()


func _update_position() -> void:
	# Spherical to Cartesian
	var x := cos(orbit_pitch) * sin(orbit_yaw) * orbit_distance
	var y := sin(orbit_pitch) * orbit_distance
	var z := cos(orbit_pitch) * cos(orbit_yaw) * orbit_distance
	position = orbit_target + Vector3(x, y, z)
	look_at(orbit_target, Vector3.UP)
	camera_changed.emit()


## Reset camera to default view
func reset() -> void:
	orbit_yaw = 0.0
	orbit_pitch = 0.3
	orbit_distance = 5.0
	orbit_target = Vector3.ZERO
	auto_orbit = true
	_update_position()


## Frame an object by its AABB
func frame_aabb(aabb: AABB, padding: float = 1.5) -> void:
	if aabb.size.length() <= 0:
		return

	orbit_target = aabb.get_center()
	orbit_distance = aabb.size.length() * padding
	orbit_pitch = 0.3
	orbit_yaw = 0.0
	auto_orbit = true
	_update_position()


## Set active state (enables/disables input handling)
func set_active(active: bool) -> void:
	_is_active = active


## Get current state as Dictionary (for save/restore)
func get_state() -> Dictionary:
	return {
		"yaw": orbit_yaw,
		"pitch": orbit_pitch,
		"distance": orbit_distance,
		"target": orbit_target,
		"auto_orbit": auto_orbit
	}


## Restore state from Dictionary
func set_state(state: Dictionary) -> void:
	orbit_yaw = state.get("yaw", 0.0)
	orbit_pitch = state.get("pitch", 0.3)
	orbit_distance = state.get("distance", 5.0)
	orbit_target = state.get("target", Vector3.ZERO)
	auto_orbit = state.get("auto_orbit", true)
	_update_position()
