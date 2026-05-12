## Focused Phase 2 visual validation for teleport interpolation resets.
##
## This scene exposes three manual InputMap-driven teleport paths:
## - PlayerController.teleport_to();
## - FlyCamera.teleport_to();
## - direct transition-style transform writes on a body and camera.
##
## The fixtures are visible from an overview camera so discontinuous movement
## should look like an instant jump between pads, not a smeared interpolation.
@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_property_access", "unsafe_cast")
extends Node3D

const PlayerControllerScript := preload("res://src/core/player/player_controller.gd")
const FlyCameraScript := preload("res://src/core/player/fly_camera.gd")
const GameplayPhysicsLayersScript := preload("res://src/core/physics/gameplay_physics_layers.gd")

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

const PLAYER_A: Vector3 = Vector3(-6.0, 0.5, 3.5)
const PLAYER_B: Vector3 = Vector3(-6.0, 0.5, -4.5)
const FLY_A: Vector3 = Vector3(0.0, 1.7, 3.5)
const FLY_B: Vector3 = Vector3(0.0, 1.7, -4.5)
const TRANSITION_BODY_A: Vector3 = Vector3(6.0, 0.5, 3.5)
const TRANSITION_BODY_B: Vector3 = Vector3(6.0, 0.5, -4.5)
const TRANSITION_CAMERA_A: Vector3 = Vector3(7.0, 1.8, 3.5)
const TRANSITION_CAMERA_B: Vector3 = Vector3(7.0, 1.8, -4.5)

var _player: PlayerController
var _fly_camera: FlyCamera
var _transition_body: CharacterBody3D
var _transition_camera: Camera3D
var _overview_camera: Camera3D
var _player_at_a: bool = true
var _fly_at_a: bool = true
var _transition_at_a: bool = true
var _status_label: Label
var _event_log_label: Label
var _event_lines: Array[String] = []


func _ready() -> void:
	_create_environment()
	_create_teleport_lanes()
	_create_overview_camera()
	_create_hud()
	_log_event("Teleport reset board loaded")

	_ensure_visual_actions()
	_create_player_probe()
	_create_fly_camera_probe()
	_create_transition_probe()
	_hide_fallback_nodes()
	_activate_overview_camera.call_deferred()
	_log_event("Teleport interpolation reset scene ready")


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


func _verify_visual_actions() -> void:
	var missing: Array[StringName] = []
	for action_name: StringName in TELEPORT_ACTIONS:
		if not InputMap.has_action(action_name):
			missing.append(action_name)
	if missing.is_empty():
		return
	Log.error("input", "Teleport visual scene missing InputMap actions: %s" % str(missing))
	assert(missing.is_empty(), "missing teleport visual actions: %s" % str(missing))


func _ensure_visual_actions() -> void:
	_ensure_key_action(PLAYER_TELEPORT_ACTION, KEY_T)
	_ensure_key_action(FLY_TELEPORT_ACTION, KEY_Y)
	_ensure_key_action(TRANSITION_WRITE_ACTION, KEY_U)
	_ensure_key_action(RESET_ACTION, KEY_R)
	_verify_visual_actions()


func _ensure_key_action(action_name: StringName, keycode: int) -> void:
	if InputMap.has_action(action_name):
		return
	InputMap.add_action(action_name)
	var key_event := InputEventKey.new()
	key_event.physical_keycode = keycode
	InputMap.action_add_event(action_name, key_event)
	Log.info("input", "Added missing visual-test action %s for this scene" % String(action_name))


func _create_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation = Vector3(deg_to_rad(-60.0), deg_to_rad(32.0), 0.0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	add_child(sun)

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.28, 0.38, 0.52)
	sky_mat.sky_horizon_color = Color(0.60, 0.68, 0.74)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6
	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	add_child(world_env)


func _create_teleport_lanes() -> void:
	_add_box("MainFloor", Vector3(1.3, -0.08, -0.5), Vector3(18.5, 0.16, 11.0),
		Color(0.28, 0.29, 0.32))

	_add_lane("PlayerTeleport", -6.0, Color(0.20, 0.46, 0.78), Color(0.72, 0.32, 0.24),
		"PlayerController.teleport_to")
	_add_lane("FlyCameraTeleport", 0.0, Color(0.24, 0.56, 0.46), Color(0.76, 0.56, 0.22),
		"FlyCamera.teleport_to")
	_add_lane("TransitionWrite", 6.0, Color(0.46, 0.34, 0.68), Color(0.74, 0.42, 0.68),
		"Direct transition writes")


func _add_lane(prefix: String, x: float, start_color: Color, dest_color: Color,
		label_text: String) -> void:
	_add_box("%sStartPad" % prefix, Vector3(x, 0.06, 3.5), Vector3(2.8, 0.14, 2.2),
		start_color)
	_add_box("%sDestPad" % prefix, Vector3(x, 0.06, -4.5), Vector3(2.8, 0.14, 2.2),
		dest_color)
	_add_box("%sGuide" % prefix, Vector3(x, 0.04, -0.5), Vector3(0.24, 0.10, 6.0),
		Color(0.70, 0.70, 0.74))
	_add_label(Vector3(x, 0.08, 5.0), "%s\nstart" % label_text)
	_add_label(Vector3(x, 0.08, -6.1), "%s\ndestination" % label_text)


func _create_overview_camera() -> void:
	var overview := Camera3D.new()
	_overview_camera = overview
	overview.name = "OverviewCamera"
	overview.position = Vector3(1.5, 12.0, 12.5)
	overview.look_at(Vector3(1.5, 0.4, -0.6))
	overview.fov = 48.0
	overview.far = 100.0
	add_child(overview)
	overview.make_current()


func _activate_overview_camera() -> void:
	if _overview_camera == null or not is_instance_valid(_overview_camera):
		return
	_overview_camera.make_current()


func _hide_fallback_nodes() -> void:
	var fallback_names: Array[StringName] = [
		&"FallbackCamera",
		&"FallbackSun",
		&"FallbackFloor",
		&"FallbackRightStartPad",
		&"FallbackRightDestPad",
		&"FallbackPurpleProbe",
		&"FallbackPinkProbe",
	]
	for fallback_name: StringName in fallback_names:
		var node := get_node_or_null(NodePath(fallback_name))
		if node == null:
			continue
		if node is Node3D:
			(node as Node3D).visible = false
		if node is Camera3D:
			(node as Camera3D).current = false


func _create_player_probe() -> void:
	_player = PlayerControllerScript.new() as PlayerController
	_player.name = "PlayerTeleportProbe"
	add_child(_player)
	_player.global_position = PLAYER_A
	_add_capsule_visual(_player, Color(0.22, 0.52, 0.86), "PlayerBodyVisual")


func _create_fly_camera_probe() -> void:
	_fly_camera = FlyCameraScript.new() as FlyCamera
	_fly_camera.name = "FlyCameraTeleportProbe"
	_fly_camera.enabled = false
	_fly_camera.current = false
	add_child(_fly_camera)
	_fly_camera.teleport_to(FLY_A, Vector3(0.0, 1.0, -1.0))
	_add_camera_marker(_fly_camera, Color(0.28, 0.76, 0.56), "FlyCameraMarker")


func _create_transition_probe() -> void:
	_transition_body = CharacterBody3D.new()
	_transition_body.name = "TransitionBodyProbe"
	_transition_body.collision_layer = GameplayPhysicsLayersScript.PLAYER
	_transition_body.collision_mask = GameplayPhysicsLayersScript.ENVIRONMENT
	add_child(_transition_body)
	_transition_body.global_position = TRANSITION_BODY_A
	_add_capsule_visual(_transition_body, Color(0.62, 0.46, 0.82), "TransitionBodyVisual")

	_transition_camera = Camera3D.new()
	_transition_camera.name = "TransitionCameraProbe"
	_transition_camera.current = false
	add_child(_transition_camera)
	_transition_camera.global_position = TRANSITION_CAMERA_A
	_transition_camera.look_at(Vector3(6.0, 1.0, -0.5))
	_transition_camera.reset_physics_interpolation()
	_add_camera_marker(_transition_camera, Color(0.95, 0.48, 0.70), "TransitionCameraMarker")


func _create_hud() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "TeleportResetHUD"
	canvas.layer = 5
	add_child(canvas)

	_status_label = Label.new()
	_status_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_status_label.offset_left = 16.0
	_status_label.offset_top = 16.0
	_status_label.offset_right = 760.0
	_status_label.offset_bottom = 96.0
	_status_label.add_theme_font_size_override("font_size", 18)
	_status_label.add_theme_color_override("font_color", Color(1.0, 0.96, 0.78))
	_status_label.text = "Press teleport visual-test actions to jump each probe between pads."
	canvas.add_child(_status_label)

	_event_log_label = Label.new()
	_event_log_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_event_log_label.offset_left = 16.0
	_event_log_label.offset_top = 110.0
	_event_log_label.offset_right = 820.0
	_event_log_label.offset_bottom = 380.0
	_event_log_label.add_theme_font_size_override("font_size", 14)
	_event_log_label.add_theme_color_override("font_color", Color(0.86, 0.94, 1.0))
	_event_log_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	canvas.add_child(_event_log_label)

	var help := Label.new()
	help.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	help.offset_left = -440.0
	help.offset_top = 16.0
	help.offset_right = -16.0
	help.offset_bottom = 250.0
	help.add_theme_font_size_override("font_size", 14)
	help.add_theme_color_override("font_color", Color(0.92, 1.0, 0.84))
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.text = (
		"Teleport Reset Checks\n"
		+ "T: PlayerController.teleport_to\n"
		+ "Y: FlyCamera.teleport_to\n"
		+ "U: direct body + camera transition write\n"
		+ "R: reset all probes\n\n"
		+ "Expected: each probe snaps instantly between pads with no interpolation trail.\n"
		+ "Right lane: purple capsule and pink camera marker move together."
	)
	canvas.add_child(help)


func _toggle_player_teleport() -> void:
	var dest := PLAYER_B if _player_at_a else PLAYER_A
	_player.teleport_to(dest)
	_player_at_a = not _player_at_a
	_log_event("PlayerController.teleport_to -> %s; reset owned by helper" % str(dest))


func _toggle_fly_camera_teleport() -> void:
	var dest := FLY_B if _fly_at_a else FLY_A
	var look_z := -1.0 if _fly_at_a else 2.0
	var look_target := Vector3(0.0, 1.0, look_z)
	_fly_camera.teleport_to(dest, look_target)
	_fly_at_a = not _fly_at_a
	_log_event("FlyCamera.teleport_to -> %s; reset owned by helper" % str(dest))


func _toggle_transition_write() -> void:
	var body_dest := TRANSITION_BODY_B if _transition_at_a else TRANSITION_BODY_A
	var camera_dest := TRANSITION_CAMERA_B if _transition_at_a else TRANSITION_CAMERA_A
	_apply_transition_style_write(body_dest, camera_dest)
	_transition_at_a = not _transition_at_a
	_log_event("Direct transition write -> body %s, camera %s; both reset" % [
		str(body_dest),
		str(camera_dest),
	])


func _reset_all_probes() -> void:
	_player.teleport_to(PLAYER_A)
	_player_at_a = true
	_fly_camera.teleport_to(FLY_A, Vector3(0.0, 1.0, -1.0))
	_fly_at_a = true
	_apply_transition_style_write(TRANSITION_BODY_A, TRANSITION_CAMERA_A)
	_transition_at_a = true
	_log_event("Reset all probes to start pads")


func _apply_transition_style_write(body_dest: Vector3, camera_dest: Vector3) -> void:
	_transition_body.global_position = body_dest
	var yaw := deg_to_rad(180.0) if body_dest.z < 0.0 else 0.0
	_transition_body.global_basis = Basis(Vector3.UP, yaw)
	_transition_body.reset_physics_interpolation()

	_transition_camera.global_position = camera_dest
	_transition_camera.look_at(Vector3(6.0, 1.0, -0.5))
	_transition_camera.reset_physics_interpolation()


func _add_capsule_visual(parent: Node3D, color: Color, visual_name: String) -> void:
	var mesh := MeshInstance3D.new()
	mesh.name = visual_name
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	mesh.mesh = capsule
	mesh.position.y = 0.9
	mesh.material_override = _make_material(color)
	parent.add_child(mesh)

	var forward := MeshInstance3D.new()
	forward.name = "%sForward" % visual_name
	var marker := BoxMesh.new()
	marker.size = Vector3(0.12, 0.12, 0.65)
	forward.mesh = marker
	forward.position = Vector3(0.0, 1.0, -0.55)
	forward.material_override = _make_material(Color(0.95, 0.18, 0.12))
	parent.add_child(forward)


func _add_camera_marker(parent: Node3D, color: Color, marker_name: String) -> void:
	var body := MeshInstance3D.new()
	body.name = marker_name
	var box := BoxMesh.new()
	box.size = Vector3(0.80, 0.50, 0.50)
	body.mesh = box
	body.material_override = _make_material(color)
	parent.add_child(body)

	var lens := MeshInstance3D.new()
	lens.name = "%sLens" % marker_name
	var lens_box := BoxMesh.new()
	lens_box.size = Vector3(0.28, 0.28, 0.62)
	lens.mesh = lens_box
	lens.position = Vector3(0.0, 0.0, -0.35)
	lens.material_override = _make_material(Color(0.08, 0.10, 0.12))
	parent.add_child(lens)


func _add_box(box_name: String, pos: Vector3, size: Vector3, color: Color) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "%sBody" % box_name
	body.position = pos
	body.collision_layer = GameplayPhysicsLayersScript.ENVIRONMENT
	body.collision_mask = GameplayPhysicsLayersScript.PLAYER

	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = size
	shape.shape = box_shape
	body.add_child(shape)

	var mesh := MeshInstance3D.new()
	mesh.name = box_name
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	mesh.mesh = box_mesh
	mesh.material_override = _make_material(color)
	body.add_child(mesh)

	add_child(body)
	return body


func _add_label(pos: Vector3, text: String) -> void:
	var label := Label3D.new()
	label.name = "Label_%s" % text.replace("\n", "_")
	label.text = text
	label.position = pos
	label.rotation.x = deg_to_rad(-90.0)
	label.font_size = 26
	label.modulate = Color.WHITE
	add_child(label)


func _make_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return mat


func _log_event(line: String) -> void:
	_event_lines.append("%s  %s" % [Time.get_time_string_from_system(), line])
	if _event_lines.size() > 16:
		_event_lines.remove_at(0)
	if _event_log_label != null:
		_event_log_label.text = "\n".join(_event_lines)
	if _status_label != null:
		_status_label.text = line
	Log.info("player", line)
