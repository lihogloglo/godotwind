## Focused visual validation for teleport interpolation resets.
##
## The scene itself owns the visible board, probes, and overview camera. This
## script only handles InputMap actions and calls the same teleport/reset paths
## used by production code.
@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_property_access", "unsafe_cast")
extends Node3D

const PLAYER_TELEPORT_ACTION: StringName = &"teleport_test_player"
const FLY_TELEPORT_ACTION: StringName = &"teleport_test_fly_camera"
const TRANSITION_WRITE_ACTION: StringName = &"teleport_test_transition_write"
const RESET_ACTION: StringName = &"teleport_test_reset"

const TELEPORT_ACTIONS: Array[StringName] = [
	PLAYER_TELEPORT_ACTION,
	FLY_TELEPORT_ACTION,
	TRANSITION_WRITE_ACTION,
	RESET_ACTION,
]

const VALIDATION_CASES: Array[StringName] = [
	&"player_controller_teleport_to",
	&"fly_camera_teleport_to",
	&"transition_style_body_write",
	&"transition_style_camera_write",
]

const VISUAL_PHYSICS_TICKS_PER_SECOND: int = 10
const PLAYER_A: Vector3 = Vector3(-6.0, 0.5, 3.5)
const PLAYER_B: Vector3 = Vector3(-6.0, 0.5, -4.5)
const FLY_A: Vector3 = Vector3(0.0, 1.7, 3.5)
const FLY_B: Vector3 = Vector3(0.0, 1.7, -4.5)
const TRANSITION_BODY_A: Vector3 = Vector3(6.0, 0.5, 3.5)
const TRANSITION_BODY_B: Vector3 = Vector3(6.0, 0.5, -4.5)
const TRANSITION_CAMERA_A: Vector3 = Vector3(7.0, 1.7, 3.5)
const TRANSITION_CAMERA_B: Vector3 = Vector3(7.0, 1.7, -4.5)
const TRANSITION_LOOK_TARGET: Vector3 = Vector3(6.0, 1.0, -0.5)

@onready var _player: PlayerController = $TeleportRig/PlayerLane/PlayerProbe as PlayerController
@onready var _fly_camera: FlyCamera = $TeleportRig/FlyLane/FlyProbe as FlyCamera
@onready var _transition_body: CharacterBody3D = $TeleportRig/TransitionLane/TransitionBodyProbe as CharacterBody3D
@onready var _transition_camera: Camera3D = $TeleportRig/TransitionLane/TransitionCameraProbe as Camera3D
@onready var _overview_camera: Camera3D = $OverviewCamera as Camera3D
@onready var _status_label: Label = $HUD/StatusLabel as Label
@onready var _event_log_label: Label = $HUD/EventLogLabel as Label

var _player_at_a: bool = true
var _fly_at_a: bool = true
var _transition_at_a: bool = true
var _event_lines: Array[String] = []
var _previous_physics_ticks_per_second: int = 0


func _ready() -> void:
	_previous_physics_ticks_per_second = Engine.physics_ticks_per_second
	Engine.physics_ticks_per_second = VISUAL_PHYSICS_TICKS_PER_SECOND

	_configure_hud()
	_report_input_action_status()
	_reset_all_probes(false)
	_overview_camera.make_current()
	_log_event("Teleport reset scene ready; physics TPS set to %d for visible checks" %
		VISUAL_PHYSICS_TICKS_PER_SECOND)


func _exit_tree() -> void:
	if _previous_physics_ticks_per_second > 0:
		Engine.physics_ticks_per_second = _previous_physics_ticks_per_second


func get_teleport_action_names() -> PackedStringArray:
	var names := PackedStringArray()
	for action_name: StringName in TELEPORT_ACTIONS:
		names.append(String(action_name))
	return names


func get_validation_case_names() -> PackedStringArray:
	var names := PackedStringArray()
	for case_name: StringName in VALIDATION_CASES:
		names.append(String(case_name))
	return names


func get_scene_purpose() -> String:
	return "Phase 2 teleport interpolation reset visual validation"


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(PLAYER_TELEPORT_ACTION):
		_toggle_player_teleport()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(FLY_TELEPORT_ACTION):
		_toggle_fly_camera_teleport()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(TRANSITION_WRITE_ACTION):
		_toggle_transition_write()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(RESET_ACTION):
		_reset_all_probes()
		get_viewport().set_input_as_handled()


func _configure_hud() -> void:
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_event_log_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.text = (
		"Teleport interpolation reset test\n"
		+ "T: player helper   Y: fly-camera helper   U: direct transition write   R: reset\n"
		+ "Expected: probes snap between colored pads with no smear across the lane."
	)
	_event_log_label.text = ""


func _report_input_action_status() -> void:
	var missing: Array[String] = []
	for action_name: StringName in TELEPORT_ACTIONS:
		if not InputMap.has_action(action_name):
			missing.append(String(action_name))
	if missing.is_empty():
		return
	_log_event("Missing InputMap actions: %s" % ", ".join(missing))
	Log.error("input", "Teleport visual scene missing InputMap actions: %s" % str(missing))


func _toggle_player_teleport() -> void:
	if _player == null:
		_log_event("Player probe missing")
		return
	var dest := PLAYER_B if _player_at_a else PLAYER_A
	_player.teleport_to(dest)
	_player_at_a = not _player_at_a
	_log_event("PlayerController.teleport_to -> %s" % _pad_name(_player_at_a))


func _toggle_fly_camera_teleport() -> void:
	if _fly_camera == null:
		_log_event("Fly-camera probe missing")
		return
	var dest := FLY_B if _fly_at_a else FLY_A
	_fly_camera.teleport_to(dest, Vector3(0.0, 1.0, -0.5))
	_fly_camera.current = false
	_fly_camera.enabled = false
	_fly_at_a = not _fly_at_a
	_overview_camera.make_current()
	_log_event("FlyCamera.teleport_to -> %s" % _pad_name(_fly_at_a))


func _toggle_transition_write() -> void:
	var body_dest := TRANSITION_BODY_B if _transition_at_a else TRANSITION_BODY_A
	var camera_dest := TRANSITION_CAMERA_B if _transition_at_a else TRANSITION_CAMERA_A
	_apply_transition_style_write(body_dest, camera_dest)
	_transition_at_a = not _transition_at_a
	_log_event("Direct body/camera write with reset -> %s" % _pad_name(_transition_at_a))


func _reset_all_probes(log_reset: bool = true) -> void:
	if _player != null:
		_player.teleport_to(PLAYER_A)
	_player_at_a = true

	if _fly_camera != null:
		_fly_camera.teleport_to(FLY_A, Vector3(0.0, 1.0, -0.5))
		_fly_camera.current = false
		_fly_camera.enabled = false
	_fly_at_a = true

	_apply_transition_style_write(TRANSITION_BODY_A, TRANSITION_CAMERA_A)
	_transition_at_a = true

	if _overview_camera != null:
		_overview_camera.make_current()
	if log_reset:
		_log_event("Reset all probes to start pads")


func _apply_transition_style_write(body_dest: Vector3, camera_dest: Vector3) -> void:
	if _transition_body != null:
		var yaw := deg_to_rad(180.0) if body_dest.z < 0.0 else 0.0
		_transition_body.global_transform = Transform3D(Basis(Vector3.UP, yaw), body_dest)
		_transition_body.reset_physics_interpolation()
	if _transition_camera != null:
		_transition_camera.global_position = camera_dest
		_transition_camera.look_at(TRANSITION_LOOK_TARGET)
		_transition_camera.current = false
		_transition_camera.reset_physics_interpolation()


func _pad_name(at_a: bool) -> String:
	return "start pad" if at_a else "destination pad"


func _log_event(line: String) -> void:
	_event_lines.append("%s  %s" % [Time.get_time_string_from_system(), line])
	if _event_lines.size() > 8:
		_event_lines.remove_at(0)
	if _status_label != null:
		_status_label.text = (
			line + "\n"
			+ "T: player helper   Y: fly-camera helper   U: direct transition write   R: reset"
		)
	if _event_log_label != null:
		_event_log_label.text = "\n".join(_event_lines)
	Log.info("player", line)
