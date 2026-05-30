extends Node3D

const InputActionsScript := preload("res://src/core/input/input_actions.gd")
const PolygonWaterVolumeScript := preload("res://src/core/water/polygon_water_volume.gd")
const WaterVolumeScript := preload("res://src/core/water/water_volume.gd")
const BuoyancyBodyScript := preload("res://src/core/water/buoyancy_body.gd")
const BuoyancyProbeScript := preload("res://src/core/water/buoyancy_probe.gd")

var _camera: Camera3D = null
var _hud: Label = null
var _station_options: OptionButton = null
var _debug_options: OptionButton = null
var _capture_button: Button = null
var _yaw: float = -0.18
var _pitch: float = -0.28
var _station_index: int = 0
var _debug_mode: int = 0
var _water_nodes: Array[WaterVolume] = []
var _station_names: Array[String] = [
	"lake edge fade",
	"puddle shallows",
	"pool ripples",
	"slow inlet current",
]
var _station_positions: Array[Vector3] = [
	Vector3(-18.0, 4.0, 18.0),
	Vector3(18.0, 2.3, 14.0),
	Vector3(18.0, 2.2, -20.0),
	Vector3(-20.0, 2.7, -18.0),
]
var _debug_names: Array[String] = [
	"shaded",
	"flow direction",
	"speed",
	"depth edge",
	"coverage",
	"interaction ripples",
]


func _ready() -> void:
	InputActionsScript.verify()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_setup_world()
	_setup_water()
	_setup_collision_test_objects()
	_setup_camera()
	_setup_hud()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * 0.002
		_pitch = clampf(_pitch - event.relative.y * 0.002, -1.35, 1.25)
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_RIGHT and mouse_event.pressed:
			_set_mouse_captured(Input.mouse_mode != Input.MOUSE_MODE_CAPTURED)


func _process(delta: float) -> void:
	_update_camera(delta)
	_update_hud()


func _setup_world() -> void:
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.34, 0.48, 0.64)
	sky_mat.sky_horizon_color = Color(0.76, 0.84, 0.88)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.85
	env_node.environment = env
	add_child(env_node)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48.0, 25.0, 0.0)
	sun.light_energy = 1.45
	sun.shadow_enabled = true
	add_child(sun)

	var ground := MeshInstance3D.new()
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(78.0, 68.0)
	ground.mesh = ground_mesh
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.20, 0.25, 0.18)
	ground_mat.roughness = 0.9
	ground.material_override = ground_mat
	add_child(ground)

	var ground_body := StaticBody3D.new()
	ground_body.name = "GroundCollision"
	var ground_shape := CollisionShape3D.new()
	var ground_box := BoxShape3D.new()
	ground_box.size = Vector3(78.0, 0.4, 68.0)
	ground_shape.shape = ground_box
	ground_shape.position.y = -0.22
	ground_body.add_child(ground_shape)
	add_child(ground_body)

	for marker_pos: Vector3 in [Vector3(-27.0, 0.25, 19.0), Vector3(12.0, 0.18, 14.0), Vector3(22.0, 0.2, -25.0), Vector3(-24.0, 0.2, -23.0)]:
		var rock := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(2.4, 0.55, 2.0)
		rock.mesh = mesh
		rock.position = marker_pos
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.29, 0.31, 0.25)
		mat.roughness = 0.95
		rock.material_override = mat
		add_child(rock)


func _setup_water() -> void:
	var lake: PolygonWaterVolume = PolygonWaterVolumeScript.new()
	lake.name = "IrregularLake"
	lake.position = Vector3(-18.0, 0.0, 15.0)
	lake.polygon_points = PackedVector2Array([
		Vector2(-15.0, -9.0),
		Vector2(-4.0, -14.0),
		Vector2(13.0, -8.0),
		Vector2(16.0, 5.0),
		Vector2(4.0, 13.0),
		Vector2(-13.0, 9.0),
	])
	lake.size = Vector3(32.0, 3.2, 28.0)
	lake.water_surface_height = 0.06
	lake.water_type = WaterVolume.WaterType.LAKE
	lake.wave_scale = 0.07
	lake.wave_speed = 0.28
	lake.roughness = 0.20
	lake.clarity = 0.68
	lake.water_color = Color(0.025, 0.15, 0.18, 1.0)
	add_child(lake)
	_water_nodes.append(lake)

	var puddle: PolygonWaterVolume = PolygonWaterVolumeScript.new()
	puddle.name = "ShallowPuddle"
	puddle.position = Vector3(18.0, 0.0, 14.0)
	puddle.polygon_points = PackedVector2Array([
		Vector2(-5.0, -2.5),
		Vector2(1.5, -4.0),
		Vector2(6.0, -1.0),
		Vector2(4.5, 2.8),
		Vector2(-1.0, 4.0),
		Vector2(-6.2, 1.2),
	])
	puddle.size = Vector3(13.0, 0.45, 8.5)
	puddle.water_surface_height = 0.025
	puddle.water_type = WaterVolume.WaterType.POOL
	puddle.wave_scale = 0.02
	puddle.roughness = 0.05
	puddle.clarity = 0.78
	puddle.water_color = Color(0.04, 0.18, 0.17, 1.0)
	add_child(puddle)
	_water_nodes.append(puddle)

	var pool: WaterVolume = WaterVolumeScript.new()
	pool.name = "RoundPool"
	pool.position = Vector3(19.0, 0.0, -18.0)
	pool.size = Vector3(12.0, 2.2, 12.0)
	pool.water_surface_height = 0.04
	pool.water_type = WaterVolume.WaterType.POOL
	pool.wave_scale = 0.04
	pool.wave_speed = 0.42
	pool.roughness = 0.12
	pool.clarity = 0.72
	pool.water_color = Color(0.02, 0.13, 0.20, 1.0)
	add_child(pool)
	_water_nodes.append(pool)

	var inlet: WaterVolume = WaterVolumeScript.new()
	inlet.name = "SlowInletCurrent"
	inlet.position = Vector3(-20.0, 0.0, -18.0)
	inlet.size = Vector3(22.0, 1.8, 7.0)
	inlet.water_surface_height = 0.05
	inlet.water_type = WaterVolume.WaterType.RIVER
	inlet.flow_direction = Vector2(1.0, 0.12)
	inlet.flow_speed = 0.75
	inlet.current_strength = 0.6
	inlet.wave_scale = 0.05
	inlet.roughness = 0.16
	inlet.clarity = 0.64
	inlet.water_color = Color(0.025, 0.16, 0.21, 1.0)
	add_child(inlet)
	_water_nodes.append(inlet)


func _setup_collision_test_objects() -> void:
	_add_buoyant_box("LakeBuoyancyCrate", Vector3(-18.0, 2.4, 15.0), Color(0.62, 0.38, 0.18), 5.0, 1.35)
	_add_buoyant_box("PuddleLightBlock", Vector3(18.0, 0.85, 14.0), Color(0.55, 0.46, 0.24), 1.6, 1.05)
	_add_buoyant_box("InletCurrentCrate", Vector3(-25.0, 1.6, -18.0), Color(0.42, 0.28, 0.18), 3.0, 1.25)


func _add_buoyant_box(body_name: String, pos: Vector3, color: Color, mass_kg: float, buoyancy: float) -> void:
	var body: BuoyancyBody3D = BuoyancyBodyScript.new()
	body.name = body_name
	body.mass = mass_kg
	body.buoyancy_force = buoyancy
	body.probe_submersion_depth = 0.9
	body.drag_linear = 0.06
	body.drag_angular = 0.12
	body.position = pos

	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(1.35, 0.85, 1.35)
	shape.shape = box_shape
	body.add_child(shape)

	var mesh := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = box_shape.size
	mesh.mesh = box_mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.72
	mesh.material_override = mat
	body.add_child(mesh)

	for offset: Vector3 in [
		Vector3(-0.45, -0.48, -0.45),
		Vector3(0.45, -0.48, -0.45),
		Vector3(-0.45, -0.48, 0.45),
		Vector3(0.45, -0.48, 0.45),
	]:
		var probe: BuoyancyProbe3D = BuoyancyProbeScript.new()
		probe.position = offset
		body.add_child(probe)
	add_child(body)


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.current = true
	_camera.global_position = _station_positions[_station_index]
	add_child(_camera)


func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var panel := PanelContainer.new()
	panel.position = Vector2(16.0, 16.0)
	panel.custom_minimum_size = Vector2(360.0, 0.0)
	panel.focus_mode = Control.FOCUS_NONE
	layer.add_child(panel)

	var box := VBoxContainer.new()
	box.focus_mode = Control.FOCUS_NONE
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	var title := Label.new()
	title.focus_mode = Control.FOCUS_NONE
	title.text = "Inland Water Lab"
	title.add_theme_font_size_override("font_size", 18)
	box.add_child(title)

	var station_label := Label.new()
	station_label.focus_mode = Control.FOCUS_NONE
	station_label.text = "View"
	box.add_child(station_label)
	_station_options = OptionButton.new()
	_station_options.focus_mode = Control.FOCUS_NONE
	for station_name: String in _station_names:
		_station_options.add_item(station_name)
	_station_options.selected = _station_index
	_station_options.item_selected.connect(_on_station_selected)
	box.add_child(_station_options)

	var debug_label := Label.new()
	debug_label.focus_mode = Control.FOCUS_NONE
	debug_label.text = "Debug"
	box.add_child(debug_label)
	_debug_options = OptionButton.new()
	_debug_options.focus_mode = Control.FOCUS_NONE
	for debug_name: String in _debug_names:
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
	previous_button.pressed.connect(func() -> void: _set_station((_station_index - 1 + _station_positions.size()) % _station_positions.size()))
	row.add_child(previous_button)
	var next_button := Button.new()
	next_button.focus_mode = Control.FOCUS_NONE
	next_button.text = "Next"
	next_button.pressed.connect(func() -> void: _set_station((_station_index + 1) % _station_positions.size()))
	row.add_child(next_button)

	_capture_button = Button.new()
	_capture_button.focus_mode = Control.FOCUS_NONE
	_capture_button.text = "Capture Mouse"
	_capture_button.pressed.connect(func() -> void: _set_mouse_captured(Input.mouse_mode != Input.MOUSE_MODE_CAPTURED))
	box.add_child(_capture_button)

	_hud = Label.new()
	_hud.focus_mode = Control.FOCUS_NONE
	_hud.position = Vector2(16.0, 250.0)
	_hud.add_theme_font_size_override("font_size", 16)
	_hud.modulate = Color(0.9, 0.96, 1.0)
	layer.add_child(_hud)


func _update_camera(delta: float) -> void:
	if _camera == null:
		return
	_camera.rotation = Vector3(_pitch, _yaw, 0.0)
	var input_vec := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_backward")
	var basis := _camera.global_transform.basis
	var move := basis.z * input_vec.y + basis.x * input_vec.x
	if Input.is_action_pressed(&"jump"):
		move += Vector3.UP
	if Input.is_action_pressed(&"crouch"):
		move += Vector3.DOWN
	var speed := 14.0 if Input.is_action_pressed(&"sprint") else 7.0
	if move.length_squared() > 0.001:
		_camera.global_position += move.normalized() * speed * delta


func _update_hud() -> void:
	if _hud == null or _camera == null:
		return
	var state: WaterSurfaceState = WaterSystem.get_water_surface_state()
	var query := state.sample_surface_query(_camera.global_position) if state != null else {}
	_hud.text = "camera water: body=%s coverage=%.2f depth=%.2f\nobjects: 3 BuoyancyBody3D crates with CollisionShape3D + 4 probes each\nwater volumes: Area3D detection + registry queries + ripple renderer sync\nmouse: %s | right-click toggles capture" % [
		str(query.get("water_body_id", WaterSurfaceState.WATER_BODY_NONE)),
		float(query.get("coverage", 0.0)),
		float(query.get("depth", 0.0)),
		"captured" if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else "visible for UI",
	]
	if _capture_button != null:
		_capture_button.text = "Release Mouse" if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else "Capture Mouse"


func _set_station(index: int) -> void:
	_station_index = clampi(index, 0, _station_positions.size() - 1)
	if _camera != null:
		_camera.global_position = _station_positions[_station_index]
	if _station_options != null:
		_station_options.selected = _station_index


func _set_debug_mode(index: int) -> void:
	_debug_mode = clampi(index, 0, _debug_names.size() - 1)
	for water: WaterVolume in _water_nodes:
		water.debug_display_mode = _debug_mode
	if _debug_options != null:
		_debug_options.selected = _debug_mode


func _set_mouse_captured(captured: bool) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE


func _on_station_selected(index: int) -> void:
	_set_station(index)


func _on_debug_selected(index: int) -> void:
	_set_debug_mode(index)
