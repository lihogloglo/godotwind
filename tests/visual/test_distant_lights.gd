extends Node3D

## Visual test for distant light billboard system.
## Loads ESM data and displays distant lights at night.
## Much faster than full world_explorer — no terrain, no streaming, no models.
##
## Controls:
##   WASD + mouse — fly around
##   T — toggle time of day (night/day/dusk)
##   +/- — adjust scan radius
##   F — toggle fire-only filter
##   ESC — quit

const CS := preload("res://src/core/coordinate_system.gd")
const DistantLightManagerScript := preload("res://src/core/world/distant_light_manager.gd")

var _camera: Camera3D
var _environment: WorldEnvironment
var _dlm: DistantLightManager
var _label: Label

# Camera movement
var _mouse_captured: bool = false
var _yaw: float = 0.0
var _pitch: float = -15.0
var _move_speed: float = 200.0  # Fast — we're covering km

# Time-of-day simulation
var _sun_elevation: float = -0.3  # Start at night (below horizon)
var _time_mode: int = 0  # 0=night, 1=dusk, 2=day
const TIME_PRESETS: Array = [-0.3, 0.08, 0.8]
const TIME_NAMES: Array = ["Night", "Dusk", "Day"]

# Scan config
var _scan_radius: int = 40  # ~4.7km
var _scan_done: bool = false


func _ready() -> void:
	# Wait for ESM data
	if ESMManager.exterior_cells.is_empty():
		_setup_label()
		_label.text = "Loading ESM data..."
		await get_tree().process_frame
		var data_path: String = SettingsManager.get_data_path()
		if data_path.is_empty():
			data_path = SettingsManager.auto_detect_installation()
		if data_path.is_empty():
			_label.text = "ERROR: No Morrowind data path configured"
			return
		var esm_file: String = SettingsManager.get_esm_file()
		var esm_path: String = data_path.path_join(esm_file)
		Log.info("testing", "Loading ESM: %s" % esm_path)
		ESMManager.load_file(esm_path)
		Log.info("testing", "ESM loaded: %d cells, %d lights" % [ESMManager.exterior_cells.size(), ESMManager.lights.size()])

	print("[TEST] ESM data ready, setting up scene...")
	_setup_environment()
	_setup_camera()
	_setup_label()
	print("[TEST] Environment + camera + label ready")

	# Need to wait a frame so the camera and world_3d are fully initialized
	await get_tree().process_frame

	print("[TEST] Setting up distant lights...")
	_setup_distant_lights()
	print("[TEST] Distant lights ready")

	# Teleport to Seyda Neen area
	_teleport_to_cell(-2, -9)

	_label.text = _get_status_text()
	Log.info("testing", "Distant lights test ready. Press T to toggle time, +/- to adjust radius.")


func _setup_environment() -> void:
	_environment = WorldEnvironment.new()
	var env := Environment.new()

	# Dark sky for night
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.02, 0.02, 0.05)
	mat.sky_horizon_color = Color(0.05, 0.05, 0.08)
	mat.ground_bottom_color = Color(0.01, 0.01, 0.02)
	mat.ground_horizon_color = Color(0.03, 0.03, 0.05)
	sky.sky_material = mat
	env.sky = sky

	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.03, 0.03, 0.06)
	env.ambient_light_energy = 1.0

	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0
	env.tonemap_white = 6.0

	# Glow/bloom to make distant lights pop
	env.glow_enabled = true
	env.glow_intensity = 0.8
	env.glow_bloom = 0.3
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	env.glow_hdr_threshold = 0.5
	env.glow_hdr_scale = 2.0

	# Light fog for atmosphere
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_density = 0.00005
	env.fog_light_color = Color(0.05, 0.05, 0.08)
	env.fog_sky_affect = 0.3

	_environment.environment = env
	add_child(_environment)

	# Dim moonlight
	var moon := DirectionalLight3D.new()
	moon.rotation_degrees = Vector3(-30, 60, 0)
	moon.light_energy = 0.15
	moon.light_color = Color(0.6, 0.65, 0.8)
	moon.shadow_enabled = false
	add_child(moon)


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.far = 6000.0
	_camera.fov = 70.0
	add_child(_camera)


func _setup_label() -> void:
	if _label:
		return
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_label = Label.new()
	_label.position = Vector2(10, 10)
	_label.add_theme_font_size_override("font_size", 16)
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_label.add_theme_constant_override("shadow_offset_x", 1)
	_label.add_theme_constant_override("shadow_offset_y", 1)
	canvas.add_child(_label)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE or what == NOTIFICATION_EXIT_TREE:
		if _dlm:
			_dlm.cleanup()


func _setup_distant_lights() -> void:
	_dlm = DistantLightManagerScript.new()
	_dlm.setup(self)

	# Initial scan
	var start_ms := Time.get_ticks_msec()
	var center := Vector2i(-2, -9)  # Seyda Neen
	_dlm.scan_cells_around(center, _scan_radius)
	var elapsed := Time.get_ticks_msec() - start_ms
	Log.info("testing", "Distant light scan: %d ms (radius %d cells)" % [elapsed, _scan_radius])
	_scan_done = true


func _teleport_to_cell(cell_x: int, cell_y: int) -> void:
	var cell_size := CS.CELL_SIZE_GODOT
	var world_x := float(cell_x) * cell_size + cell_size * 0.5
	var world_z := float(-cell_y) * cell_size - cell_size * 0.5
	_camera.position = Vector3(world_x, 150.0, world_z)
	_camera.rotation_degrees = Vector3(_pitch, _yaw, 0)


func _process(delta: float) -> void:
	if not _scan_done:
		return

	# Update distant lights
	_dlm.update(_camera.global_position, _sun_elevation)

	# Camera movement
	_process_camera(delta)

	# Update HUD every 10 frames
	if Engine.get_frames_drawn() % 10 == 0:
		_label.text = _get_status_text()


func _process_camera(delta: float) -> void:
	if not _mouse_captured:
		return

	var input_dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_Z):
		input_dir.z -= 1.0
	if Input.is_key_pressed(KEY_S):
		input_dir.z += 1.0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_Q):
		input_dir.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		input_dir.x += 1.0
	if Input.is_key_pressed(KEY_SPACE):
		input_dir.y += 1.0
	if Input.is_key_pressed(KEY_SHIFT):
		input_dir.y -= 1.0

	# Speed boost with ctrl
	var speed := _move_speed
	if Input.is_key_pressed(KEY_CTRL):
		speed *= 3.0

	if input_dir != Vector3.ZERO:
		var move := _camera.global_basis * input_dir.normalized() * speed * delta
		_camera.position += move


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_mouse_captured = true
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			else:
				_mouse_captured = false
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	elif event is InputEventMouseMotion and _mouse_captured:
		_yaw -= event.relative.x * 0.2
		_pitch = clampf(_pitch - event.relative.y * 0.2, -89.0, 89.0)
		_camera.rotation_degrees = Vector3(_pitch, _yaw, 0)

	elif event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_T:
				_time_mode = (_time_mode + 1) % 3
				_sun_elevation = TIME_PRESETS[_time_mode]
				Log.info("testing", "Time: %s (sun elevation: %.2f)" % [TIME_NAMES[_time_mode], _sun_elevation])
			KEY_EQUAL, KEY_KP_ADD:
				_scan_radius = mini(_scan_radius + 10, 80)
				_dlm.scan_cells_around(Vector2i(-2, -9), _scan_radius)
				Log.info("testing", "Scan radius: %d cells" % _scan_radius)
			KEY_MINUS, KEY_KP_SUBTRACT:
				_scan_radius = maxi(_scan_radius - 10, 10)
				Log.info("testing", "Scan radius: %d cells (rescan requires restart)" % _scan_radius)
			KEY_ESCAPE:
				get_tree().quit()


func _get_status_text() -> String:
	var pos := _camera.global_position
	var cell_x := int(floor(pos.x / CS.CELL_SIZE_GODOT))
	var cell_y := -int(floor(pos.z / CS.CELL_SIZE_GODOT))
	return "Distant Lights Test | %s | Sun: %.2f\nPos: (%.0f, %.0f, %.0f) | Cell: (%d, %d)\nLights: %d | Radius: %d cells (~%.0fkm)\nT=time +/-=radius RMB+WASD=fly" % [
		TIME_NAMES[_time_mode],
		_sun_elevation,
		pos.x, pos.y, pos.z,
		cell_x, cell_y,
		_dlm._active_count,
		_scan_radius,
		float(_scan_radius) * CS.CELL_SIZE_GODOT / 1000.0
	]
