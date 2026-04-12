## Godray showcase — objects orbit in front of the sun, godrays always on.
## Free-fly camera + moving sun for visual verification.
##   Hold right-click + WASD/ZQSD to fly, mouse to look
##   T/Y = advance/rewind sun, R = toggle godrays
extends Node3D

var _sun: DirectionalLight3D
var _camera: Camera3D
var _world_env: WorldEnvironment
var _orbit_root: Node3D
var _debug_label: RichTextLabel
var _godrays_enabled: bool = true
var _sun_angle: float = -10.0  # elevation in degrees (negative = above horizon)
var _sun_yaw: float = 45.0
var _fly_speed: float = 30.0
var _mouse_captured: bool = false


func _ready() -> void:
	_setup_environment()
	_setup_camera()
	_setup_sun()
	_setup_orbiting_objects()
	_setup_ground()
	_setup_ui()

	# Enable godrays immediately at boosted strength
	await get_tree().process_frame
	await get_tree().process_frame
	_enable_godrays()


func _setup_environment() -> void:
	_world_env = WorldEnvironment.new()
	var env := Environment.new()

	# Dark sky so rays pop
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.08, 0.08, 0.15)
	sky_mat.sky_horizon_color = Color(0.25, 0.2, 0.15)
	sky_mat.ground_bottom_color = Color(0.05, 0.04, 0.03)
	sky_mat.ground_horizon_color = Color(0.2, 0.15, 0.1)
	sky_mat.sun_angle_max = 5.0
	sky_mat.sun_curve = 0.05
	sky.sky_material = sky_mat
	env.sky = sky

	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.05, 0.05, 0.08)
	env.ambient_light_energy = 0.3
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0
	env.tonemap_white = 1.0

	# Subtle glow
	env.glow_enabled = true
	env.glow_intensity = 0.3
	env.glow_strength = 0.5
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 1.2

	# No volumetric or depth fog — isolate godrays only
	env.volumetric_fog_enabled = false
	env.fog_enabled = false
	env.fog_sun_scatter = 0.8

	_world_env.environment = env
	add_child(_world_env)


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "ShowcaseCamera"
	_camera.current = true
	_camera.far = 5000.0
	_camera.fov = 60.0
	# Looking toward the sun — low angle, slightly above horizon
	_camera.position = Vector3(0, 8, 0)
	_camera.rotation_degrees = Vector3(-5, -135, 0)
	add_child(_camera)


func _setup_sun() -> void:
	_sun = DirectionalLight3D.new()
	_sun.name = "ShowcaseSun"
	_sun.shadow_enabled = true
	_sun.light_energy = 0.8
	_sun.light_color = Color(1.0, 0.95, 0.85)
	_sun.light_volumetric_fog_energy = 1.0
	_sun.directional_shadow_max_distance = 200.0
	# Sun IN FRONT of camera: light (-Z) shines toward camera, sun (+Z) is in camera's look direction
	# Camera yaw=-135, so sun yaw=-135+180=45 makes the light point back toward the camera
	_sun.rotation_degrees = Vector3(-10, 45, 0)
	add_child(_sun)


func _setup_orbiting_objects() -> void:
	_orbit_root = Node3D.new()
	_orbit_root.name = "OrbitRoot"
	var forward := -_camera.global_basis.z.normalized()
	_orbit_root.position = _camera.position + forward * 60.0
	add_child(_orbit_root)

	var dark_mat := StandardMaterial3D.new()
	dark_mat.albedo_color = Color(0.05, 0.05, 0.05)
	dark_mat.roughness = 0.9

	# --- Static colonnade: dense row of pillars blocking most of the sky ---
	# Light peeks through the gaps — this is what godrays are designed for
	var colonnade := Node3D.new()
	colonnade.name = "Colonnade"
	colonnade.position = _orbit_root.position
	add_child(colonnade)

	var pillar_count := 15
	var spread := 80.0  # total width of the row
	var gap := spread / float(pillar_count)
	var right := _camera.global_basis.x.normalized()
	var row_center := _orbit_root.position

	for i in pillar_count:
		var pillar := MeshInstance3D.new()
		pillar.name = "Pillar_%d" % i
		var box := BoxMesh.new()
		# Vary widths so gaps aren't uniform — more natural
		var w: float = 2.0 + sin(float(i) * 1.7) * 1.0
		box.size = Vector3(w, 40.0, w)
		pillar.mesh = box
		pillar.material_override = dark_mat
		pillar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		# Space along the camera's right axis, centered
		var offset: float = (float(i) - float(pillar_count) * 0.5) * gap
		pillar.position = row_center + right * offset
		pillar.position.y = 12.0  # raise so they cover the sky above horizon
		colonnade.add_child(pillar)

	# --- A few slow-moving objects crossing the gaps ---
	var movers := [
		{"radius": 8.0, "height": 12.0, "width": 3.0, "phase": 0.0, "speed": 0.06},
		{"radius": 12.0, "height": 8.0, "width": 2.0, "phase": 2.0, "speed": -0.04},
		{"radius": 5.0, "height": 0.0, "width": 4.0, "phase": 4.0, "speed": 0.08, "sphere": true},
	]

	for i in movers.size():
		var cfg: Dictionary = movers[i]
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.name = "Mover_%d" % i

		if cfg.get("sphere", false):
			var sphere := SphereMesh.new()
			sphere.radius = cfg["width"]
			sphere.height = cfg["width"] * 2.0
			mesh_instance.mesh = sphere
		else:
			var box := BoxMesh.new()
			box.size = Vector3(cfg["width"], cfg["height"], cfg["width"])
			mesh_instance.mesh = box

		mesh_instance.material_override = dark_mat
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mesh_instance.set_meta("orbit_radius", cfg["radius"])
		mesh_instance.set_meta("orbit_phase", cfg["phase"])
		mesh_instance.set_meta("orbit_speed", cfg["speed"])
		mesh_instance.set_meta("orbit_y_offset", cfg["height"] * 0.3 if not cfg.get("sphere", false) else 10.0)
		_orbit_root.add_child(mesh_instance)


func _setup_ground() -> void:
	# Dark ground plane
	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	var plane := PlaneMesh.new()
	plane.size = Vector2(500, 500)
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.08, 0.07, 0.06)
	mat.roughness = 1.0
	ground.material_override = mat
	ground.position.y = -2.0
	add_child(ground)


func _setup_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_debug_label = RichTextLabel.new()
	_debug_label.bbcode_enabled = true
	_debug_label.scroll_active = false
	_debug_label.fit_content = true
	_debug_label.position = Vector2(10, 10)
	_debug_label.size = Vector2(500, 100)
	_debug_label.add_theme_font_size_override("normal_font_size", 14)
	_update_label()
	canvas.add_child(_debug_label)


func _update_label() -> void:
	_debug_label.text = "[b]GODRAY SHOWCASE[/b]\nRMB+WASD = fly | T/Y = move sun | R = toggle godrays\nSun elevation: %.1f° | Godrays: %s" % [_sun_angle, "ON" if _godrays_enabled else "OFF"]


func _enable_godrays() -> void:
	ShaderManager.attach_to(_world_env)
	ShaderManager.set_sun(_sun)

	# Use Rafael's original default params (tuned for natural look)
	var godrays_effect := ShaderManager.get_effect("godrays")
	if godrays_effect:
		godrays_effect.set_param("ray_strength", 1.85)     # Rafael default
		godrays_effect.set_param("ray_radius", 0.25)       # Rafael default
		godrays_effect.set_param("iterations", 16.0)       # Rafael default
		godrays_effect.set_param("ray_brightness", 1.0)    # Rafael default
		godrays_effect.set_param("sun_disc_brightness", 1.2)  # Rafael default
		godrays_effect.set_param("ray_falloff", 1.1)       # Rafael default
		godrays_effect.set_param("center_vis", 0.35)       # Rafael default
		godrays_effect.set_param("ray_occlude", 0.75)      # Rafael default

	ShaderManager.enable_effect("godrays", 0.0)  # instant on
	Log.info("testing", "Godrays showcase started — boosted params")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).physical_keycode:
			KEY_R:
				_godrays_enabled = not _godrays_enabled
				if _godrays_enabled:
					ShaderManager.enable_effect("godrays", 0.0)
				else:
					ShaderManager.disable_effect("godrays", 0.0)
				_update_label()
			KEY_T:
				_sun_angle -= 5.0
				_sun.rotation_degrees.x = _sun_angle
				_update_label()
			KEY_Y:
				_sun_angle += 5.0
				_sun.rotation_degrees.x = _sun_angle
				_update_label()

	# Right-click capture for fly camera
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_mouse_captured = mb.pressed
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _mouse_captured else Input.MOUSE_MODE_VISIBLE

	# Mouse look while captured
	if event is InputEventMouseMotion and _mouse_captured:
		var mm := event as InputEventMouseMotion
		_camera.rotation_degrees.y -= mm.relative.x * 0.2
		_camera.rotation_degrees.x -= mm.relative.y * 0.2
		_camera.rotation_degrees.x = clampf(_camera.rotation_degrees.x, -89, 89)


func _process(delta: float) -> void:
	# Fly camera
	if _mouse_captured:
		var move := Vector3.ZERO
		if Input.is_physical_key_pressed(KEY_W): move.z -= 1.0
		if Input.is_physical_key_pressed(KEY_S): move.z += 1.0
		if Input.is_physical_key_pressed(KEY_A): move.x -= 1.0
		if Input.is_physical_key_pressed(KEY_D): move.x += 1.0
		if Input.is_physical_key_pressed(KEY_SPACE): move.y += 1.0
		if Input.is_physical_key_pressed(KEY_SHIFT): move.y -= 1.0
		if move.length_squared() > 0.0:
			_camera.position += _camera.basis * move.normalized() * _fly_speed * delta

	var time: float = Time.get_ticks_msec() / 1000.0

	# Orbit objects around the pivot
	for child in _orbit_root.get_children():
		if child is MeshInstance3D:
			var radius: float = child.get_meta("orbit_radius", 15.0)
			var phase: float = child.get_meta("orbit_phase", 0.0)
			var speed: float = child.get_meta("orbit_speed", 0.05)
			var y_off: float = child.get_meta("orbit_y_offset", 5.0)
			var angle: float = time * speed + phase
			child.position = Vector3(
				cos(angle) * radius,
				y_off + sin(angle * 0.3) * 3.0,
				sin(angle) * radius
			)
