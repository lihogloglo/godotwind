extends Node3D

const RiverWaterBodyScript := preload("res://src/core/water/river_water_body.gd")
const BuoyancyBodyScript := preload("res://src/core/water/buoyancy_body.gd")
const BuoyancyProbeScript := preload("res://src/core/water/buoyancy_probe.gd")
const WaterInteractorScript := preload("res://src/core/water/water_interactor.gd")
const InputActionsScript := preload("res://src/core/input/input_actions.gd")

const GRAB_RANGE_M := 40.0
const GRAB_DISTANCE_M := 5.0
const GRAB_PULL := 12.0
const GRAB_MAX_SPEED := 24.0
const PLAY_BALL_RADIUS := 0.65
const LAB_INTERACTION_CENTER := Vector3(0.0, 8.0, 0.0)

var _camera: Camera3D = null
var _yaw: float = 0.0
var _pitch: float = -0.34
var _hud: Label = null
var _station_options: OptionButton = null
var _debug_options: OptionButton = null
var _capture_button: Button = null
var _freeze_time_button: Button = null
var _river: RiverWaterBody3D = null
var _bend_river: RiverWaterBody3D = null
var _generated_river: RiverWaterBody3D = null
var _play_ball: RigidBody3D = null
var _play_ball_interactor: WaterInteractor = null
var _crate_body: BuoyancyBody3D = null
var _crate_interactor: WaterInteractor = null
var _held_body: RigidBody3D = null
var _grab_marker: MeshInstance3D = null
var _flow_arrow_mesh: MeshInstance3D = null
var _transition_station_index: int = 0
var _debug_mode: int = 0
var _debug_freeze_time: bool = false
var _debug_mode_names: Array[String] = [
	"shaded",
	"flow direction",
	"speed",
	"coverage",
	"bank edge",
	"interaction ripples",
	"dynamic flow delta",
	"flowmap mismatch",
	"mesh UV",
	"flow basis gradient",
	"oriented UV",
	"base flow",
	"flowmap flow",
	"flowmap speed (center only)",
]
var _transition_station_names: Array[String] = [
	"clean bend",
	"flowmap/debug direction",
	"obstacle deformation",
	"buoyancy drift",
	"interaction ripples",
	"land outside registered water",
]
var _transition_station_positions: Array[Vector3] = [
	Vector3(-18.0, 1.8, 34.0),
	Vector3(0.0, 2.2, -28.0),
	Vector3(-18.0, 1.5, -16.0),
	Vector3(-18.0, 1.5, -22.0),
	Vector3(-18.0, -1.2, 34.0),
	Vector3(0.0, 1.8, 34.0),
]


func _ready() -> void:
	InputActionsScript.verify()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_setup_world()
	_setup_water()
	_setup_play_ball()
	_setup_buoyant_body()
	_setup_camera()
	_setup_water_interaction()
	_setup_hud()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * 0.002
		_pitch = clampf(_pitch - event.relative.y * 0.002, -1.35, 1.25)
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_RIGHT and mouse_event.pressed:
			_set_mouse_captured(Input.mouse_mode != Input.MOUSE_MODE_CAPTURED)
	if event.is_action_pressed(&"interact"):
		_toggle_grab()


func _physics_process(delta: float) -> void:
	_update_held_body()
	_emit_ball_interactions(delta)


func _process(delta: float) -> void:
	_update_camera(delta)
	_update_water_interaction_manual(delta)
	_update_grab_marker()
	_update_hud()


func _exit_tree() -> void:
	if OceanManager == null:
		return
	OceanManager.set_process(true)
	OceanManager.set_physics_process(true)
	OceanManager.set_camera(null)


func _setup_world() -> void:
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.33, 0.47, 0.68)
	sky_mat.sky_horizon_color = Color(0.78, 0.86, 0.92)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.8
	env_node.environment = env
	add_child(env_node)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, 34.0, 0.0)
	sun.light_energy = 1.5
	sun.shadow_enabled = true
	add_child(sun)

	var ground := MeshInstance3D.new()
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(90.0, 140.0)
	ground.mesh = ground_mesh
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.18, 0.23, 0.17)
	ground_mat.roughness = 0.85
	ground.material_override = ground_mat
	add_child(ground)

	var ground_body := StaticBody3D.new()
	ground_body.name = "GroundCollision"
	var ground_shape := CollisionShape3D.new()
	var ground_box := BoxShape3D.new()
	ground_box.size = Vector3(90.0, 0.4, 140.0)
	ground_shape.shape = ground_box
	ground_shape.position.y = -0.22
	ground_body.add_child(ground_shape)
	add_child(ground_body)

	for i in range(9):
		var bank := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(8.0, 1.5, 8.0)
		bank.mesh = box
		bank.position = Vector3(-18.0 + float(i % 3) * 18.0, 0.35, -44.0 + float(i / 3) * 32.0)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.25, 0.29, 0.19)
		mat.roughness = 0.9
		bank.material_override = mat
		add_child(bank)


func _setup_water() -> void:
	_river = RiverWaterBodyScript.new()
	_river.name = "AuthoredCurveRiver"
	_river.curve = Curve3D.new()
	_river.curve.add_point(Vector3(-6.0, 0.0, -48.0), Vector3.ZERO, Vector3(7.0, 0.0, 12.0))
	_river.curve.add_point(Vector3(5.0, 0.0, -18.0), Vector3(-6.0, 0.0, -12.0), Vector3(-5.0, 0.0, 12.0))
	_river.curve.add_point(Vector3(-4.0, 0.0, 14.0), Vector3(5.0, 0.0, -12.0), Vector3(4.0, 0.0, 13.0))
	_river.curve.add_point(Vector3(4.0, 0.0, 48.0), Vector3(-4.0, 0.0, -13.0), Vector3.ZERO)
	_river.point_widths = [7.5, 8.5, 7.0, 8.0]
	_river.surface_height = 0.05
	_river.depth = 4.0
	_river.flow_speed = 2.4
	_river.length_step_m = 1.5
	_river.width_subdivisions = 8
	_river.water_color = Color(0.03, 0.24, 0.30, 1.0)
	_river.position = Vector3(-18.0, 0.35, 0.0)
	add_child(_river)

	_bend_river = RiverWaterBodyScript.new()
	_bend_river.name = "BankFollowingBendRiver"
	_bend_river.curve = Curve3D.new()
	_bend_river.curve.add_point(Vector3(-11.0, 0.0, -42.0), Vector3.ZERO, Vector3(11.0, 0.0, 8.0))
	_bend_river.curve.add_point(Vector3(7.0, 0.0, -22.0), Vector3(-11.0, 0.0, -8.0), Vector3(10.0, 0.0, 11.0))
	_bend_river.curve.add_point(Vector3(8.0, 0.0, 8.0), Vector3(-8.0, 0.0, -11.0), Vector3(-10.0, 0.0, 11.0))
	_bend_river.curve.add_point(Vector3(-10.0, 0.0, 38.0), Vector3(10.0, 0.0, -11.0), Vector3.ZERO)
	_bend_river.point_widths = [7.0, 8.5, 7.5, 8.0]
	_bend_river.surface_height = 0.08
	_bend_river.depth = 4.0
	_bend_river.flow_speed = 1.7
	_bend_river.length_step_m = 1.25
	_bend_river.width_subdivisions = 9
	_bend_river.water_color = Color(0.03, 0.14, 0.20, 1.0)
	_bend_river.position = Vector3(18.0, 2.2, 0.0)
	add_child(_bend_river)

	_generated_river = RiverWaterBodyScript.new()
	_generated_river.name = "GeneratedFlowmapRiver"
	_generated_river.curve = Curve3D.new()
	_generated_river.curve.add_point(Vector3(-7.0, 0.0, -50.0), Vector3.ZERO, Vector3(7.0, 0.0, 13.0))
	_generated_river.curve.add_point(Vector3(7.0, 0.0, -24.0), Vector3(-7.0, 0.0, -13.0), Vector3(-6.0, 0.0, 13.0))
	_generated_river.curve.add_point(Vector3(-5.0, 0.0, 4.0), Vector3(6.0, 0.0, -13.0), Vector3(7.0, 0.0, 14.0))
	_generated_river.curve.add_point(Vector3(7.0, 0.0, 38.0), Vector3(-7.0, 0.0, -14.0), Vector3.ZERO)
	_generated_river.point_widths = [6.5, 7.5, 7.0, 7.5]
	_generated_river.surface_height = 0.11
	_generated_river.depth = 4.0
	_generated_river.flow_speed = 2.0
	_generated_river.length_step_m = 1.25
	_generated_river.width_subdivisions = 8
	_generated_river.water_color = Color(0.025, 0.16, 0.22, 1.0)
	_generated_river.position = Vector3(0.0, 4.1, 0.0)
	_generated_river.flowmap_region_bounds = AABB(Vector3(-45.0, -10.0, -70.0), Vector3(90.0, 20.0, 140.0))
	_generated_river.flowmap_image = _make_generated_flowmap_image(_generated_river, 96, 96)
	_generated_river.flowmap_enabled = true
	add_child(_generated_river)

	_flow_arrow_mesh = MeshInstance3D.new()
	_flow_arrow_mesh.name = "FlowDebugArrows"
	add_child(_flow_arrow_mesh)
	_update_flow_arrow_overlay()


func _setup_play_ball() -> void:
	_play_ball = RigidBody3D.new()
	_play_ball.name = "GrabRippleBall"
	_play_ball.mass = 4.0
	_play_ball.gravity_scale = 0.2
	_play_ball.linear_damp = 1.1
	_play_ball.angular_damp = 0.35
	_play_ball.position = Vector3(-18.0, 1.6, -20.0)
	add_child(_play_ball)

	var collision := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = PLAY_BALL_RADIUS
	collision.shape = shape
	_play_ball.add_child(collision)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "BallMesh"
	var mesh := SphereMesh.new()
	mesh.radius = PLAY_BALL_RADIUS
	mesh.height = PLAY_BALL_RADIUS * 2.0
	mesh_instance.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.18, 0.08)
	mat.roughness = 0.42
	mesh_instance.material_override = mat
	_play_ball.add_child(mesh_instance)

	_play_ball_interactor = WaterInteractorScript.new()
	_play_ball_interactor.auto_register = false
	_play_ball_interactor.radius_m = PLAY_BALL_RADIUS
	_play_ball_interactor.impact_strength = 1.35
	_play_ball_interactor.wake_strength = 0.34
	_play_ball_interactor.wake_interval_m = 0.0
	_play_ball_interactor.wake_interval_s = 0.0
	_play_ball_interactor.surface_band_m = PLAY_BALL_RADIUS + 0.38
	_play_ball_interactor.affects_flow = true
	_play_ball_interactor.flow_block_strength = 0.95
	_play_ball_interactor.flow_wake_strength = 0.75
	_play_ball.add_child(_play_ball_interactor)
	_play_ball_interactor.set_physics_process(false)

	_grab_marker = MeshInstance3D.new()
	_grab_marker.name = "GrabTargetMarker"
	var marker_mesh := SphereMesh.new()
	marker_mesh.radius = 0.08
	marker_mesh.height = 0.16
	_grab_marker.mesh = marker_mesh
	var marker_mat := StandardMaterial3D.new()
	marker_mat.albedo_color = Color(0.2, 0.8, 1.0)
	marker_mat.emission_enabled = true
	marker_mat.emission = Color(0.05, 0.45, 0.9)
	_grab_marker.material_override = marker_mat
	_grab_marker.visible = false
	add_child(_grab_marker)


func _setup_buoyant_body() -> void:
	var body: BuoyancyBody3D = BuoyancyBodyScript.new()
	_crate_body = body
	body.name = "UnifiedQueryBuoyancyBody"
	body.mass = 4.0
	body.buoyancy_force = 1.4
	body.probe_submersion_depth = 1.0
	body.drag_linear = 0.18
	body.drag_angular = 0.14
	body.position = Vector3(-18.0, 1.9, -22.0)

	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(1.4, 1.0, 1.4)
	shape.shape = box_shape
	body.add_child(shape)

	var mesh := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(1.4, 1.0, 1.4)
	mesh.mesh = box_mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.33, 0.16)
	mat.roughness = 0.72
	mesh.material_override = mat
	body.add_child(mesh)

	var probe: BuoyancyProbe3D = BuoyancyProbeScript.new()
	probe.position = Vector3(0.0, -0.55, 0.0)
	body.add_child(probe)
	_crate_interactor = WaterInteractorScript.new()
	_crate_interactor.name = "CrateFlowInteractor"
	_crate_interactor.auto_register = false
	_crate_interactor.radius_m = 1.0
	_crate_interactor.impact_strength = 0.8
	_crate_interactor.wake_strength = 0.2
	_crate_interactor.surface_band_m = 1.25
	_crate_interactor.affects_flow = true
	_crate_interactor.flow_block_strength = 0.7
	_crate_interactor.flow_wake_strength = 0.55
	body.add_child(_crate_interactor)
	_crate_interactor.set_physics_process(false)
	add_child(body)


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.current = true
	_camera.position = _transition_station_positions[_transition_station_index]
	add_child(_camera)


func _setup_water_interaction() -> void:
	if OceanManager == null:
		return
	OceanManager.force_initialize()
	OceanManager.set_camera(_camera)
	OceanManager.set_process(false)
	OceanManager.set_physics_process(false)
	OceanManager.set_sea_level(-24.0)
	OceanManager.set_wave_scale(0.08)
	OceanManager.set_water_interaction_debug_enabled(_debug_mode == 5)
	OceanManager.force_update_water_body_atlas(LAB_INTERACTION_CENTER)
	var ocean_mesh := OceanManager.get_ocean_mesh()
	if ocean_mesh != null:
		ocean_mesh.visible = false
	_update_water_interaction_manual(0.0)


func _update_water_interaction_manual(delta: float) -> void:
	if OceanManager == null:
		return
	OceanManager.set_water_interaction_debug_enabled(_debug_mode == 5)
	OceanManager.update_local_water_interactions(delta, LAB_INTERACTION_CENTER)


func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var panel := PanelContainer.new()
	panel.position = Vector2(16.0, 16.0)
	panel.custom_minimum_size = Vector2(380.0, 0.0)
	panel.focus_mode = Control.FOCUS_NONE
	layer.add_child(panel)

	var box := VBoxContainer.new()
	box.focus_mode = Control.FOCUS_NONE
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	var title := Label.new()
	title.focus_mode = Control.FOCUS_NONE
	title.text = "Flowing River Lab"
	title.add_theme_font_size_override("font_size", 18)
	box.add_child(title)

	var station_label := Label.new()
	station_label.focus_mode = Control.FOCUS_NONE
	station_label.text = "View"
	box.add_child(station_label)
	_station_options = OptionButton.new()
	_station_options.focus_mode = Control.FOCUS_NONE
	for station_name: String in _transition_station_names:
		_station_options.add_item(station_name)
	_station_options.selected = _transition_station_index
	_station_options.item_selected.connect(_on_station_selected)
	box.add_child(_station_options)

	var debug_label := Label.new()
	debug_label.focus_mode = Control.FOCUS_NONE
	debug_label.text = "Debug"
	box.add_child(debug_label)
	_debug_options = OptionButton.new()
	_debug_options.focus_mode = Control.FOCUS_NONE
	for debug_name: String in _debug_mode_names:
		_debug_options.add_item(debug_name)
	_debug_options.selected = _debug_mode
	_debug_options.item_selected.connect(_on_debug_selected)
	box.add_child(_debug_options)

	var row := HBoxContainer.new()
	row.focus_mode = Control.FOCUS_NONE
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	var previous_button := Button.new()
	previous_button.focus_mode = Control.FOCUS_NONE
	previous_button.text = "Previous"
	previous_button.pressed.connect(func() -> void: _set_station((_transition_station_index - 1 + _transition_station_positions.size()) % _transition_station_positions.size()))
	row.add_child(previous_button)
	var next_button := Button.new()
	next_button.focus_mode = Control.FOCUS_NONE
	next_button.text = "Next"
	next_button.pressed.connect(func() -> void: _set_station((_transition_station_index + 1) % _transition_station_positions.size()))
	row.add_child(next_button)

	_capture_button = Button.new()
	_capture_button.focus_mode = Control.FOCUS_NONE
	_capture_button.text = "Capture Mouse"
	_capture_button.pressed.connect(func() -> void: _set_mouse_captured(Input.mouse_mode != Input.MOUSE_MODE_CAPTURED))
	box.add_child(_capture_button)

	_freeze_time_button = Button.new()
	_freeze_time_button.focus_mode = Control.FOCUS_NONE
	_freeze_time_button.text = "Freeze River Time"
	_freeze_time_button.pressed.connect(_toggle_debug_freeze_time)
	box.add_child(_freeze_time_button)

	_hud = Label.new()
	_hud.focus_mode = Control.FOCUS_NONE
	_hud.position = Vector2(16.0, 270.0)
	_hud.add_theme_font_size_override("font_size", 16)
	_hud.modulate = Color(0.9, 0.95, 1.0)
	layer.add_child(_hud)


func _update_camera(delta: float) -> void:
	if _camera == null:
		return
	_camera.rotation = Vector3(_pitch, _yaw, 0.0)
	var input_vec := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_backward")
	var basis := _camera.global_transform.basis
	var move := (basis.z * input_vec.y + basis.x * input_vec.x)
	if Input.is_action_pressed(&"jump"):
		move += Vector3.UP
	if Input.is_action_pressed(&"crouch"):
		move += Vector3.DOWN
	var speed := 16.0 if Input.is_action_pressed(&"sprint") else 8.0
	if move.length_squared() > 0.001:
		_camera.global_position += move.normalized() * speed * delta


func _update_hud() -> void:
	if _hud == null or _play_ball == null:
		return
	var pos := _play_ball.global_position
	var state: WaterSurfaceState = OceanManager.get_water_surface_state()
	var probe_query := _query_text(state, pos)
	var camera_query := _query_text(state, _camera.global_position if _camera != null else Vector3.ZERO)
	var crate_query := _query_text(state, _crate_body.global_position) if _crate_body != null else "no crate"
	_hud.text = "camera: %s\nball: %s\ncrate: %s\nE: grab/drop nearest object | arrows: direction, length=speed\nobjects disturb local flow and buoyancy drag follows sampled current\nriver modes: authored vertex flow + generated flowmap river\nmouse: %s | right-click toggles capture" % [
		camera_query,
		probe_query,
		crate_query,
		"captured" if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else "visible for UI",
	]
	if _capture_button != null:
		_capture_button.text = "Release Mouse" if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else "Capture Mouse"
	if _freeze_time_button != null:
		_freeze_time_button.text = "Unfreeze River Time" if _debug_freeze_time else "Freeze River Time"


func _set_station(index: int) -> void:
	_transition_station_index = clampi(index, 0, _transition_station_positions.size() - 1)
	if _camera != null:
		_camera.global_position = _transition_station_positions[_transition_station_index]
	_yaw = 0.0
	_pitch = -0.22
	if _station_options != null:
		_station_options.selected = _transition_station_index


func _set_debug_mode(index: int) -> void:
	_debug_mode = clampi(index, 0, _debug_mode_names.size() - 1)
	for river in [_river, _bend_river, _generated_river]:
		if river != null:
			river.debug_display_mode = _debug_mode
	if OceanManager != null:
		OceanManager.set_water_interaction_debug_enabled(_debug_mode == 5)
	_update_flow_arrow_overlay()
	if _debug_options != null:
		_debug_options.selected = _debug_mode


func _toggle_debug_freeze_time() -> void:
	_debug_freeze_time = not _debug_freeze_time
	for river in [_river, _bend_river, _generated_river]:
		if river != null:
			river.set_debug_freeze_time(_debug_freeze_time)


func _set_mouse_captured(captured: bool) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE


func _on_station_selected(index: int) -> void:
	_set_station(index)


func _on_debug_selected(index: int) -> void:
	_set_debug_mode(index)


func _toggle_grab() -> void:
	if _held_body != null:
		_release_held_body()
		return
	if _camera == null:
		return
	var body := _find_grabbable_body()
	if body == null:
		return
	_held_body = body
	_held_body.sleeping = false
	if _grab_marker != null:
		_grab_marker.visible = true


func _find_grabbable_body() -> RigidBody3D:
	var forward := -_camera.global_transform.basis.z.normalized()
	var best_body: RigidBody3D = null
	var best_score := -INF
	for body in [_play_ball, _crate_body]:
		if body == null:
			continue
		var to_body: Vector3 = body.global_position - _camera.global_position
		var distance := to_body.length()
		if distance > GRAB_RANGE_M or distance <= 0.001:
			continue
		var alignment := forward.dot(to_body / distance)
		if alignment < 0.55:
			continue
		var score := alignment * 4.0 - distance * 0.05
		if score > best_score:
			best_score = score
			best_body = body
	return best_body


func _release_held_body() -> void:
	_held_body = null
	if _grab_marker != null:
		_grab_marker.visible = false


func _update_held_body() -> void:
	if _held_body == null or _camera == null:
		return
	var target := _grab_target()
	var delta := target - _held_body.global_position
	var desired_velocity := delta * GRAB_PULL
	if desired_velocity.length() > GRAB_MAX_SPEED:
		desired_velocity = desired_velocity.normalized() * GRAB_MAX_SPEED
	_held_body.linear_velocity = desired_velocity
	_held_body.angular_velocity *= 0.92


func _emit_ball_interactions(delta: float) -> void:
	if OceanManager == null:
		return
	var state := OceanManager.get_water_surface_state()
	_emit_interactor_events(_play_ball_interactor, delta, state)
	_emit_interactor_events(_crate_interactor, delta, state)


func _emit_interactor_events(interactor: WaterInteractor, delta: float, state: WaterSurfaceState) -> void:
	if interactor == null:
		return
	for impulse: Dictionary in interactor.gather_impulses(delta, state):
		OceanManager.emit_water_impulse(
			impulse["position"],
			float(impulse["radius_m"]),
			float(impulse["strength"]),
			impulse["kind"],
			impulse["body_id"],
			impulse.get("wake_direction", Vector2.ZERO),
			float(impulse.get("wake_length_m", 0.0))
		)
	for obstacle: Dictionary in interactor.gather_flow_obstacles(delta, state):
		OceanManager.emit_water_flow_obstacle(
			obstacle["position"],
			float(obstacle["radius_m"]),
			float(obstacle.get("block_strength", 0.0)),
			float(obstacle.get("wake_strength", 0.0)),
			obstacle.get("body_id", WaterSurfaceState.WATER_BODY_NONE)
		)


func _update_grab_marker() -> void:
	if _grab_marker == null or _held_body == null:
		return
	_grab_marker.global_position = _grab_target()


func _grab_target() -> Vector3:
	if _camera == null:
		return Vector3.ZERO
	return _camera.global_position - _camera.global_transform.basis.z.normalized() * GRAB_DISTANCE_M


func _update_flow_arrow_overlay() -> void:
	if _flow_arrow_mesh == null:
		return
	if _debug_mode != 1 and _debug_mode != 2 and _debug_mode != 13:
		_flow_arrow_mesh.visible = false
		return
	_flow_arrow_mesh.visible = true
	var immediate := ImmediateMesh.new()
	immediate.surface_begin(Mesh.PRIMITIVE_LINES)
	_add_river_flow_arrows(immediate, _river, false)
	_add_river_flow_arrows(immediate, _bend_river, false)
	_add_river_flow_arrows(immediate, _generated_river, true)
	immediate.surface_end()
	_flow_arrow_mesh.mesh = immediate
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.disable_receive_shadows = true
	_flow_arrow_mesh.material_override = mat


func _add_river_flow_arrows(immediate: ImmediateMesh, river: RiverWaterBody3D, use_flowmap: bool) -> void:
	if river == null or river.curve == null:
		return
	var baked_length := river.curve.get_baked_length()
	if baked_length <= 0.1:
		return
	var steps := 16
	for i in range(steps):
		var distance := (float(i) + 0.5) / float(steps) * baked_length
		var local_pos := river.curve.sample_baked(distance)
		var world_pos := river.global_transform * local_pos
		var flow := _sample_debug_flow(river, world_pos, distance / baked_length, use_flowmap)
		var dir: Vector2 = flow.get("dir", Vector2.ZERO)
		var speed := float(flow.get("speed", 0.0))
		var coverage := float(flow.get("coverage", 1.0))
		if coverage <= 0.02 or dir.length_squared() <= 0.0001:
			continue
		dir = dir.normalized()
		var length := 2.2 if _debug_mode == 1 else lerpf(0.7, 4.0, clampf(speed / 4.0, 0.0, 1.0))
		var start := world_pos + Vector3.UP * 0.36
		var end := start + Vector3(dir.x, 0.0, dir.y) * length
		var color := _debug_flow_color(dir, speed, use_flowmap)
		_add_debug_line(immediate, start, end, color)
		var side := Vector2(-dir.y, dir.x)
		var head_a := end - Vector3(dir.x, 0.0, dir.y) * 0.45 + Vector3(side.x, 0.0, side.y) * 0.25
		var head_b := end - Vector3(dir.x, 0.0, dir.y) * 0.45 - Vector3(side.x, 0.0, side.y) * 0.25
		_add_debug_line(immediate, end, head_a, color)
		_add_debug_line(immediate, end, head_b, color)


func _sample_debug_flow(river: RiverWaterBody3D, world_pos: Vector3, normalized_distance: float, use_flowmap: bool) -> Dictionary:
	if use_flowmap and river.flowmap_image != null:
		var sample := _sample_flowmap_debug(river, world_pos)
		if not sample.is_empty():
			return sample
	var ahead_t := clampf(normalized_distance + 0.02, 0.0, 1.0)
	var behind_t := clampf(normalized_distance - 0.02, 0.0, 1.0)
	var length := river.curve.get_baked_length()
	var ahead := river.global_transform * river.curve.sample_baked(ahead_t * length)
	var behind := river.global_transform * river.curve.sample_baked(behind_t * length)
	var tangent := ahead - behind
	var dir := Vector2(tangent.x, tangent.z).normalized()
	return {
		"dir": dir,
		"speed": river.flow_speed,
		"coverage": 1.0,
	}


func _sample_flowmap_debug(river: RiverWaterBody3D, world_pos: Vector3) -> Dictionary:
	var bounds := river.flowmap_region_bounds
	if bounds.size.x <= 0.001 or bounds.size.z <= 0.001:
		return {}
	var uv := Vector2(
		(world_pos.x - bounds.position.x) / bounds.size.x,
		(world_pos.z - bounds.position.z) / bounds.size.z
	)
	if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
		return {}
	var image := river.flowmap_image
	var c := _sample_flowmap_image_bilinear(image, uv)
	if c.a <= 0.015:
		return {}
	var dir := Vector2(c.r * 2.0 - 1.0, c.g * 2.0 - 1.0)
	var speed := c.b * 6.0 * clampf(dir.length(), 0.0, 1.0)
	if speed <= 0.015 or dir.length_squared() <= 0.000001:
		return {}
	return {
		"dir": dir.normalized(),
		"speed": speed,
		"coverage": c.a,
	}


func _debug_flow_color(dir: Vector2, speed: float, use_flowmap: bool = false) -> Color:
	var color: Color
	if _debug_mode == 2 or _debug_mode == 13:
		var t := clampf(speed / 4.0, 0.0, 1.0)
		color = Color(0.05 + t * 0.95, 0.25 + t * 0.55, 1.0 - t * 0.85, 1.0)
	else:
		var angle := atan2(dir.y, dir.x)
		color = Color(
			0.5 + 0.5 * cos(angle),
			0.5 + 0.5 * cos(angle - TAU / 3.0),
			0.5 + 0.5 * cos(angle + TAU / 3.0),
			1.0
		)
	if use_flowmap:
		return color.lerp(Color(0.2, 1.0, 1.0, 1.0), 0.35)
	return color.lerp(Color(1.0, 1.0, 1.0, 1.0), 0.18)


func _add_debug_line(immediate: ImmediateMesh, a: Vector3, b: Vector3, color: Color) -> void:
	immediate.surface_set_color(color)
	immediate.surface_add_vertex(a)
	immediate.surface_set_color(color)
	immediate.surface_add_vertex(b)


func _sample_flowmap_image_bilinear(image: Image, uv: Vector2) -> Color:
	var width := image.get_width()
	var height := image.get_height()
	if width <= 0 or height <= 0:
		return Color(0.5, 0.5, 0.0, 0.0)
	var x := clampf(uv.x, 0.0, 1.0) * float(maxi(width - 1, 0))
	var y := clampf(uv.y, 0.0, 1.0) * float(maxi(height - 1, 0))
	var x0 := clampi(floori(x), 0, width - 1)
	var y0 := clampi(floori(y), 0, height - 1)
	var x1 := clampi(x0 + 1, 0, width - 1)
	var y1 := clampi(y0 + 1, 0, height - 1)
	var tx := x - float(x0)
	var ty := y - float(y0)
	var c00 := image.get_pixel(x0, y0)
	var c10 := image.get_pixel(x1, y0)
	var c01 := image.get_pixel(x0, y1)
	var c11 := image.get_pixel(x1, y1)
	return c00.lerp(c10, tx).lerp(c01.lerp(c11, tx), ty)


func _make_generated_flowmap_image(river: RiverWaterBody3D, width: int, height: int) -> Image:
	var image := Image.create(width, height, false, Image.FORMAT_RGBA8)
	var bounds := river.flowmap_region_bounds
	for y in range(height):
		var v: float = float(y) / maxf(float(height - 1), 1.0)
		var world_z: float = bounds.position.z + v * bounds.size.z
		for x in range(width):
			var u: float = float(x) / maxf(float(width - 1), 1.0)
			var world_x: float = bounds.position.x + u * bounds.size.x
			var local_xz := Vector2(world_x - river.position.x, world_z - river.position.z)
			var sample := _closest_curve_flow_sample(river, local_xz)
			var dir: Vector2 = sample.get("dir", Vector2.UP)
			var half_width := maxf(float(sample.get("width", 1.0)) * 0.5, 0.001)
			var lateral := float(sample.get("lateral", INF))
			var coverage: float = 1.0 - smoothstep(maxf(half_width - 1.2, 0.0), half_width + 1.2, lateral)
			var encoded_speed := clampf(river.flow_speed / 6.0, 0.0, 1.0)
			image.set_pixel(x, y, Color(dir.x * 0.5 + 0.5, dir.y * 0.5 + 0.5, encoded_speed, coverage))
	return image


func _closest_curve_flow_sample(river: RiverWaterBody3D, local_xz: Vector2) -> Dictionary:
	var length := river.curve.get_baked_length()
	if length <= 0.001:
		return {"dir": Vector2.UP, "width": 1.0, "lateral": INF}
	var steps := maxi(8, ceili(length / 0.75))
	var best: Dictionary = {}
	var best_dist_sq := INF
	for i in range(steps):
		var d0 := float(i) / float(steps) * length
		var d1 := float(i + 1) / float(steps) * length
		var p0 := river.curve.sample_baked(d0, true)
		var p1 := river.curve.sample_baked(d1, true)
		var a := Vector2(p0.x, p0.z)
		var b := Vector2(p1.x, p1.z)
		var segment := b - a
		var len_sq := segment.length_squared()
		if len_sq <= 0.000001:
			continue
		var t := clampf((local_xz - a).dot(segment) / len_sq, 0.0, 1.0)
		var closest := a + segment * t
		var dist_sq := local_xz.distance_squared_to(closest)
		if dist_sq >= best_dist_sq:
			continue
		var along_t := clampf((lerpf(d0, d1, t)) / length, 0.0, 1.0)
		best_dist_sq = dist_sq
		best = {
			"dir": segment.normalized(),
			"width": _river_width_at(river, along_t),
			"lateral": sqrt(dist_sq),
		}
	if best.is_empty():
		return {"dir": Vector2.UP, "width": 1.0, "lateral": INF}
	return best


func _river_width_at(river: RiverWaterBody3D, t: float) -> float:
	if river.point_widths.is_empty():
		return 8.0
	if river.point_widths.size() == 1:
		return maxf(river.point_widths[0], 0.1)
	var scaled := clampf(t, 0.0, 1.0) * float(river.point_widths.size() - 1)
	var index := mini(river.point_widths.size() - 2, int(floorf(scaled)))
	var local_t := scaled - float(index)
	return maxf(lerpf(river.point_widths[index], river.point_widths[index + 1], local_t), 0.1)


func _query_text(state: WaterSurfaceState, pos: Vector3) -> String:
	if state == null:
		return "no state"
	var query := state.sample_surface_query(pos)
	var has_body := bool(query.get("has_water_body", false))
	var height := float(query.get("height", state.sea_level))
	var depth := float(query.get("depth", 0.0)) if has_body else 0.0
	var status := "NO LOCAL WATER"
	if has_body:
		status = "UNDERWATER" if depth >= -0.02 else "ABOVE"
	var velocity := state.sample_velocity(pos, Vector3.ZERO)
	return "%s body=%s cov=%.2f gate=%.2f h=%.2f depth=%.2f vel=%s" % [
		status,
		str(query.get("water_body_id", WaterSurfaceState.WATER_BODY_NONE)),
		float(query.get("coverage", 0.0)),
		float(query.get("body_gate", 0.0)),
		height,
		depth,
		str(velocity.snappedf(0.01)),
	]
