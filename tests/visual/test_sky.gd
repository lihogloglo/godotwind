extends Node3D
## Visual test for the GodotwindSky system.
## Run this scene standalone — no weather, no streaming, no ESM data.
##
## Controls:
##   T / Y  — Time backward / forward
##   + / -  — Adjust turbidity
##   M      — Toggle multi-scatter
##   R      — Toggle REALISTIC celestial mode
##   Mouse  — Right-click look, WASD move
##   Scroll — Move speed

var _sky_manager: SkyManager
var _camera: Camera3D
var _label: Label
var _reflective_sphere: MeshInstance3D
var _ground_plane: MeshInstance3D

# Camera fly controls
var _mouse_captured: bool = false
var _yaw: float = 0.0
var _pitch: float = -10.0
var _move_speed: float = 20.0

# Time controls
var _auto_time: bool = true
var _time_speed: float = 600.0  # game-seconds per real-second (full day in ~2.5 min)


func _ready() -> void:
	# --- Sky Manager ---
	_sky_manager = SkyManager.new()
	_sky_manager.name = "SkyManager"
	add_child(_sky_manager)

	# Configure Environment extras — no glow by default (toggle with G key)
	var env: Environment = _sky_manager.get_environment()
	if env:
		env.glow_enabled = false

	# --- Camera ---
	_camera = Camera3D.new()
	_camera.position = Vector3(0, 5, 20)
	_camera.rotation_degrees = Vector3(_pitch, _yaw, 0)
	_camera.current = true
	_camera.far = 10000.0
	add_child(_camera)

	# --- Large ground plane (matches test_weather.gd scale) ---
	_ground_plane = MeshInstance3D.new()
	var plane_mesh := PlaneMesh.new()
	plane_mesh.size = Vector2(2000, 2000)
	_ground_plane.mesh = plane_mesh
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.35, 0.3, 0.25)
	ground_mat.roughness = 0.8
	_ground_plane.material_override = ground_mat
	add_child(_ground_plane)

	# --- Grid of colored boxes (lighting verification) ---
	var colors: Array[Color] = [Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW, Color.WHITE]
	for i: int in colors.size():
		var box := MeshInstance3D.new()
		var box_mesh := BoxMesh.new()
		box_mesh.size = Vector3(1.5, 1.5, 1.5)
		box.mesh = box_mesh
		box.position = Vector3(-6.0 + i * 3.0, 0.75, -5.0)
		var box_mat := StandardMaterial3D.new()
		box_mat.albedo_color = colors[i]
		box_mat.roughness = 0.5
		box.material_override = box_mat
		add_child(box)

	# --- Reflective sphere (IBL verification) ---
	_reflective_sphere = MeshInstance3D.new()
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = 1.5
	sphere_mesh.height = 3.0
	_reflective_sphere.mesh = sphere_mesh
	_reflective_sphere.position = Vector3(0, 2.5, 5.0)
	var mirror_mat := StandardMaterial3D.new()
	mirror_mat.metallic = 1.0
	mirror_mat.roughness = 0.0
	mirror_mat.albedo_color = Color.WHITE
	_reflective_sphere.material_override = mirror_mat
	add_child(_reflective_sphere)

	# --- Rough sphere (diffuse IBL check) ---
	var rough_sphere := MeshInstance3D.new()
	var rough_mesh := SphereMesh.new()
	rough_mesh.radius = 1.5
	rough_mesh.height = 3.0
	rough_sphere.mesh = rough_mesh
	rough_sphere.position = Vector3(5, 2.5, 5.0)
	var rough_mat := StandardMaterial3D.new()
	rough_mat.metallic = 0.0
	rough_mat.roughness = 1.0
	rough_mat.albedo_color = Color(0.8, 0.8, 0.8)
	rough_sphere.material_override = rough_mat
	add_child(rough_sphere)

	# --- Debug label ---
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_label = Label.new()
	_label.position = Vector2(10, 10)
	_label.add_theme_font_size_override("font_size", 14)
	canvas.add_child(_label)

	# Start at noon
	_sky_manager.update(12.0)

	Log.info("sky", "test_sky.gd ready — T/Y=time, +/-=turbidity, M=multiscatter, R=realistic, Space=auto-time")


func _process(delta: float) -> void:
	# Auto-advance time
	if _auto_time:
		_sky_manager.game_hour += delta * _time_speed / 3600.0
		if _sky_manager.game_hour >= 24.0:
			_sky_manager.game_hour -= 24.0

	_sky_manager.update(_sky_manager.game_hour)

	# Camera movement
	if _mouse_captured:
		var input_dir := Vector3.ZERO
		if Input.is_key_pressed(KEY_W): input_dir.z -= 1
		if Input.is_key_pressed(KEY_S): input_dir.z += 1
		if Input.is_key_pressed(KEY_A): input_dir.x -= 1
		if Input.is_key_pressed(KEY_D): input_dir.x += 1
		if Input.is_key_pressed(KEY_Q): input_dir.y -= 1
		if Input.is_key_pressed(KEY_E): input_dir.y += 1

		if input_dir != Vector3.ZERO:
			var move: Vector3 = _camera.global_transform.basis * input_dir.normalized() * _move_speed * delta
			_camera.position += move

	# Update debug HUD
	_update_label()


func _unhandled_input(event: InputEvent) -> void:
	# Mouse capture
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				_mouse_captured = true
			else:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				_mouse_captured = false

		# Scroll for speed
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_move_speed = minf(_move_speed * 1.2, 500.0)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_move_speed = maxf(_move_speed / 1.2, 1.0)

	# Mouse look
	if event is InputEventMouseMotion and _mouse_captured:
		var mm: InputEventMouseMotion = event
		_yaw -= mm.relative.x * 0.2
		_pitch = clampf(_pitch - mm.relative.y * 0.2, -89.0, 89.0)
		_camera.rotation_degrees = Vector3(_pitch, _yaw, 0)

	# Key controls
	if event is InputEventKey and event.pressed:
		var key: InputEventKey = event
		match key.keycode:
			KEY_T:
				_sky_manager.game_hour -= 0.5
				if _sky_manager.game_hour < 0.0:
					_sky_manager.game_hour += 24.0
			KEY_Y:
				_sky_manager.game_hour += 0.5
				if _sky_manager.game_hour >= 24.0:
					_sky_manager.game_hour -= 24.0
			KEY_EQUAL:  # + key
				_sky_manager.atmosphere.turbidity = minf(_sky_manager.atmosphere.turbidity + 0.5, 10.0)
			KEY_MINUS:
				_sky_manager.atmosphere.turbidity = maxf(_sky_manager.atmosphere.turbidity - 0.5, 1.0)
			KEY_M:
				if _sky_manager.atmosphere.multi_scatter_factor > 0.0:
					_sky_manager.atmosphere.multi_scatter_factor = 0.0
				else:
					_sky_manager.atmosphere.multi_scatter_factor = 0.5
			KEY_R:
				if _sky_manager.celestial.mode == CelestialManager.Mode.SIMPLE:
					_sky_manager.celestial.mode = CelestialManager.Mode.REALISTIC
				else:
					_sky_manager.celestial.mode = CelestialManager.Mode.SIMPLE
			KEY_G:
				var glow_env: Environment = _sky_manager.get_environment()
				if glow_env:
					glow_env.glow_enabled = not glow_env.glow_enabled
					if glow_env.glow_enabled:
						glow_env.glow_intensity = 0.6
						glow_env.glow_bloom = 0.05
						glow_env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
			KEY_SPACE:
				_auto_time = not _auto_time
			KEY_BRACKETLEFT:
				_time_speed = maxf(_time_speed * 0.5, 1.0)
			KEY_BRACKETRIGHT:
				_time_speed = minf(_time_speed * 2.0, 3600.0)


func _update_label() -> void:
	var atm: AtmosphereParams = _sky_manager.atmosphere
	var cel: CelestialManager = _sky_manager.celestial
	var sun_alt_deg: float = rad_to_deg(cel.sun_altitude)

	var mode_str: String = "SIMPLE" if cel.mode == CelestialManager.Mode.SIMPLE else "REALISTIC"
	var ms_str: String = "ON (%.2f)" % atm.multi_scatter_factor if atm.multi_scatter_factor > 0.0 else "OFF"
	var auto_str: String = " [AUTO x%.0f]" % _time_speed if _auto_time else ""

	_label.text = (
		"GodotwindSky Test%s\n" % auto_str
		+ "Hour: %.1f | Sun alt: %.1f deg | Moon phase: %.2f\n" % [_sky_manager.game_hour, sun_alt_deg, cel.moon_phase]
		+ "Turbidity: %.1f | Multi-scatter: %s | Mode: %s\n" % [atm.turbidity, ms_str, mode_str]
		+ "FPS: %d | Move: %.0f m/s\n" % [Engine.get_frames_per_second(), _move_speed]
		+ "\n"
		+ "T/Y = time  |  +/- = turbidity  |  M = multiscatter  |  G = glow\n"
		+ "R = realistic mode  |  Space = auto-time  |  [ ] = slower/faster"
	)
