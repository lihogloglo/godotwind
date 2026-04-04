## Visual test for fog systems on terrain.
##
## Loads terrain from cache and provides weather-driven fog testing.
## Height fog pools in valleys, volumetric fog creates god rays,
## depth fog provides aerial perspective.
##
## Controls:
##   1-9, 0  = Weather presets (Clear, Cloudy, ..., Blizzard)
##   T/Y     = Time backward/forward (+/- 1 hour)
##   F       = Toggle depth fog
##   V       = Toggle volumetric fog
##   G       = Toggle weather system
##   K       = Toggle Sky3D
##   ZQSD    = Fly camera (AZERTY), right-click to look
##   Space/Ctrl = Up/Down
##   Shift   = Fast
extends Node3D

const CS := preload("res://src/core/coordinate_system.gd")

var _terrain: Terrain3D = null
var _sun: DirectionalLight3D = null
var _camera: Camera3D = null
var _world_env: WorldEnvironment = null
var _sky3d: Node = null
var _sky3d_enabled: bool = false
var _renderer: WeatherRenderer = null
var _particles: WeatherParticles = null

# Fog state
var _depth_fog_enabled: bool = true
var _volumetric_fog_enabled: bool = true
var _weather_enabled: bool = false
var _mouse_captured: bool = false
var _fly_speed: float = 80.0

# UI
var _debug_label: RichTextLabel


func _ready() -> void:
	Log.info("testing", "=== FOG TEST ON TERRAIN ===")

	_setup_environment()
	_setup_camera()
	_setup_sun()
	_setup_terrain()
	_setup_sky3d()
	_setup_weather()
	_setup_ui()

	Log.info("testing", "Fog test ready. Press G=weather, F=depth fog, V=volumetric, 1-0=weather types")


func _setup_environment() -> void:
	_world_env = WorldEnvironment.new()
	_world_env.name = "FogTestEnv"

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY

	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.385, 0.454, 0.55)
	sky_mat.sky_horizon_color = Color(0.646, 0.656, 0.67)
	sky_mat.ground_bottom_color = Color(0.2, 0.169, 0.133)
	sky_mat.ground_horizon_color = Color(0.646, 0.656, 0.67)
	sky.sky_material = sky_mat
	env.sky = sky

	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = 1.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	# Depth fog — subtle aerial perspective only, the LIGHTEST layer
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_density = 0.00008
	env.fog_light_color = Color(0.7, 0.75, 0.82)
	env.fog_light_energy = 1.0
	env.fog_sun_scatter = 0.5
	env.fog_aerial_perspective = 0.8
	env.fog_sky_affect = 0.15
	env.fog_height = 0.0  # Sea level
	env.fog_height_density = 0.003

	# Volumetric fog — very sparse, ONLY for god ray shafts
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.0015
	env.volumetric_fog_albedo = Color(0.95, 0.95, 0.98)
	env.volumetric_fog_emission = Color.BLACK
	env.volumetric_fog_anisotropy = 0.55
	env.volumetric_fog_length = 800.0
	env.volumetric_fog_detail_spread = 2.0
	env.volumetric_fog_gi_inject = 0.5
	env.volumetric_fog_sky_affect = 0.15
	env.volumetric_fog_temporal_reprojection_enabled = true
	env.volumetric_fog_temporal_reprojection_amount = 0.7

	_world_env.environment = env
	add_child(_world_env)


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "FogTestCamera"
	_camera.current = true
	_camera.far = 10000.0
	add_child(_camera)

	# Position above terrain looking across a valley — good for seeing height fog
	var vs: float = CS.TERRAIN_VERTEX_SPACING
	_camera.position = Vector3(0.0 * 256.0 * vs + 128.0 * vs, 120.0, -3.0 * 256.0 * vs + 128.0 * vs)
	_camera.rotation_degrees = Vector3(-15, 30, 0)


func _setup_sun() -> void:
	_sun = DirectionalLight3D.new()
	_sun.name = "FogTestSun"
	_sun.shadow_enabled = true
	_sun.light_energy = 1.2
	_sun.light_color = Color(1.0, 0.98, 0.95)
	_sun.light_volumetric_fog_energy = 6.0
	_sun.directional_shadow_max_distance = 500.0
	# Low angle for visible god rays through terrain features
	_sun.rotation_degrees = Vector3(-25, -45, 0)
	add_child(_sun)


func _setup_terrain() -> void:
	await get_tree().process_frame

	_terrain = Terrain3D.new()
	_terrain.name = "FogTestTerrain"
	CS.configure_terrain3d_pre_tree(_terrain)
	add_child(_terrain)
	_terrain.set_physics_process(false)
	_terrain.set_process(false)

	await get_tree().process_frame

	if _terrain.has_method("set_camera"):
		_terrain.set_camera(_camera)

	if not CS.configure_terrain3d(_terrain):
		Log.error("testing", "Failed to configure Terrain3D")
		return

	# Load terrain data from cache
	var terrain_path: String = SettingsManager.get_terrain_path()
	if DirAccess.dir_exists_absolute(terrain_path):
		_terrain.data.load_directory(terrain_path)
		var region_count: int = _terrain.data.get_region_count()
		Log.info("testing", "Loaded %d terrain regions" % region_count)
	else:
		Log.error("testing", "No terrain cache at %s — run prebaking first" % terrain_path)
		return

	# Try to load terrain textures
	var texture_loader := preload("res://src/core/world/terrain_texture_loader.gd").new()
	var textures_loaded: int = texture_loader.load_terrain_textures(_terrain.assets)
	Log.info("testing", "Loaded %d terrain textures" % textures_loaded)

	if textures_loaded == 0:
		var mat_rid: RID = _terrain.material.get_material_rid()
		RenderingServer.material_set_param(mat_rid, "enable_texturing", false)


func _setup_sky3d() -> void:
	# Sky3D created but not enabled by default — press K to toggle
	pass


func _setup_weather() -> void:
	# Create renderer with callbacks into our scene
	var callbacks := {
		"get_sky3d": func() -> Node: return _sky3d if _sky3d_enabled else null,
		"get_environment": func() -> Environment: return _get_active_environment(),
		"get_light": func() -> DirectionalLight3D: return _sun,
		"get_sunshine_driver": func() -> Node: return null,
		"log": func(msg: String) -> void: Log.info("testing", msg),
	}
	_renderer = WeatherRenderer.new(callbacks)

	# Create particles
	_particles = WeatherParticles.new()
	_particles.name = "FogTestParticles"
	_particles.set_camera(_camera)
	add_child(_particles)


func _process(delta: float) -> void:
	_handle_fly_camera(delta)

	if _weather_enabled:
		var result: WeatherTypes.WeatherResult = WeatherManager.get_weather_result()
		if _renderer and _renderer.is_active():
			_renderer.apply(result)
		if _particles:
			_particles.update(result)

	_update_debug_overlay()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key: InputEventKey = event as InputEventKey
		match key.keycode:
			KEY_1: _set_weather(WeatherTypes.Type.CLEAR)
			KEY_2: _set_weather(WeatherTypes.Type.CLOUDY)
			KEY_3: _set_weather(WeatherTypes.Type.FOGGY)
			KEY_4: _set_weather(WeatherTypes.Type.OVERCAST)
			KEY_5: _set_weather(WeatherTypes.Type.RAIN)
			KEY_6: _set_weather(WeatherTypes.Type.THUNDERSTORM)
			KEY_7: _set_weather(WeatherTypes.Type.ASHSTORM)
			KEY_8: _set_weather(WeatherTypes.Type.BLIGHT)
			KEY_9: _set_weather(WeatherTypes.Type.SNOW)
			KEY_0: _set_weather(WeatherTypes.Type.BLIZZARD)
			KEY_T: WeatherManager.set_game_hour(WeatherManager.game_hour - 1.0)
			KEY_Y: WeatherManager.set_game_hour(WeatherManager.game_hour + 1.0)
			KEY_G: _toggle_weather()
			KEY_F: _toggle_depth_fog()
			KEY_V: _toggle_volumetric_fog()
			KEY_K: _toggle_sky3d()

	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_mouse_captured = mb.pressed
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _mouse_captured else Input.MOUSE_MODE_VISIBLE

	if event is InputEventMouseMotion and _mouse_captured:
		var mm: InputEventMouseMotion = event as InputEventMouseMotion
		_camera.rotation_degrees.y -= mm.relative.x * 0.2
		_camera.rotation_degrees.x -= mm.relative.y * 0.2
		_camera.rotation_degrees.x = clampf(_camera.rotation_degrees.x, -89, 89)


#region Fly Camera

func _handle_fly_camera(delta: float) -> void:
	if not _mouse_captured:
		return
	var speed: float = _fly_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= 3.0
	var direction := Vector3.ZERO
	if Input.is_key_pressed(KEY_Z): direction -= _camera.global_basis.z
	if Input.is_key_pressed(KEY_S): direction += _camera.global_basis.z
	if Input.is_key_pressed(KEY_Q): direction -= _camera.global_basis.x
	if Input.is_key_pressed(KEY_D): direction += _camera.global_basis.x
	if Input.is_key_pressed(KEY_SPACE): direction.y += 1.0
	if Input.is_key_pressed(KEY_CTRL): direction.y -= 1.0
	if direction.length_squared() > 0.001:
		_camera.position += direction.normalized() * speed * delta

#endregion


#region Toggles

func _set_weather(type: int) -> void:
	if not _weather_enabled:
		_toggle_weather()
	WeatherManager.auto_weather = false
	WeatherManager.set_weather(type)
	Log.info("testing", "Weather: %s" % WeatherTypes.type_name(type))


## Get the currently active Environment (Sky3D or fallback)
func _get_active_environment() -> Environment:
	if _sky3d_enabled and _sky3d and _sky3d.environment:
		return _sky3d.environment
	if _world_env and _world_env.environment:
		return _world_env.environment
	return null


func _toggle_weather() -> void:
	_weather_enabled = not _weather_enabled
	WeatherManager.enabled = _weather_enabled
	_renderer.set_active(_weather_enabled)
	_particles.visible = _weather_enabled
	Log.info("testing", "Weather: %s" % ("ON" if _weather_enabled else "OFF"))


func _toggle_depth_fog() -> void:
	_depth_fog_enabled = not _depth_fog_enabled
	var env: Environment = _get_active_environment()
	if env:
		env.fog_enabled = _depth_fog_enabled
	Log.info("testing", "Depth fog: %s" % ("ON" if _depth_fog_enabled else "OFF"))


func _toggle_volumetric_fog() -> void:
	_volumetric_fog_enabled = not _volumetric_fog_enabled
	var env: Environment = _get_active_environment()
	if env:
		env.volumetric_fog_enabled = _volumetric_fog_enabled
	Log.info("testing", "Volumetric fog: %s" % ("ON" if _volumetric_fog_enabled else "OFF"))


func _toggle_sky3d() -> void:
	_sky3d_enabled = not _sky3d_enabled
	if _sky3d_enabled and _sky3d == null:
		_sky3d = Sky3D.new()
		_sky3d.name = "FogTestSky3D"
		if _world_env.is_inside_tree():
			remove_child(_world_env)
		add_child(_sky3d)
		_sky3d.sky3d_enabled = true
		_sky3d.current_time = WeatherManager.game_hour
		# CRITICAL: disable Sky3D's AtmFog — it's a full-screen blend_mix quad
		# that fights with Godot native depth fog
		_sky3d.fog_enabled = false
		_apply_fog_to_environment(_sky3d.environment)
		WeatherManager.set_sky3d(_sky3d)
		_sun.visible = false
	elif _sky3d_enabled:
		if not _sky3d.is_inside_tree():
			if _world_env.is_inside_tree():
				remove_child(_world_env)
			add_child(_sky3d)
		_sky3d.sky3d_enabled = true
		_sky3d.fog_enabled = false
		_apply_fog_to_environment(_sky3d.environment)
		_sun.visible = false
	else:
		if _sky3d and _sky3d.is_inside_tree():
			remove_child(_sky3d)
		if not _world_env.is_inside_tree():
			add_child(_world_env)
		WeatherManager.set_sky3d(null)
		_sun.visible = true
	Log.info("testing", "Sky3D: %s" % ("ON" if _sky3d_enabled else "OFF"))


## Apply current fog settings to any Environment (used when swapping Sky3D <-> fallback)
func _apply_fog_to_environment(env: Environment) -> void:
	if not env:
		return
	# Depth fog
	env.fog_enabled = _depth_fog_enabled
	if _depth_fog_enabled:
		env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
		env.fog_density = 0.00008
		env.fog_light_color = Color(0.7, 0.75, 0.82)
		env.fog_light_energy = 1.0
		env.fog_sun_scatter = 0.5
		env.fog_aerial_perspective = 0.8
		env.fog_sky_affect = 0.15
		env.fog_height = 0.0
		env.fog_height_density = 0.003
	# Volumetric fog
	env.volumetric_fog_enabled = _volumetric_fog_enabled
	if _volumetric_fog_enabled:
		env.volumetric_fog_density = 0.0015
		env.volumetric_fog_albedo = Color(0.95, 0.95, 0.98)
		env.volumetric_fog_emission = Color.BLACK
		env.volumetric_fog_anisotropy = 0.55
		env.volumetric_fog_length = 800.0
		env.volumetric_fog_detail_spread = 2.0
		env.volumetric_fog_gi_inject = 0.5
		env.volumetric_fog_sky_affect = 0.15
		env.volumetric_fog_temporal_reprojection_enabled = true
		env.volumetric_fog_temporal_reprojection_amount = 0.7
	# Tonemapping
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC

#endregion


#region Debug Overlay

func _setup_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)

	_debug_label = RichTextLabel.new()
	_debug_label.bbcode_enabled = true
	_debug_label.scroll_active = false
	_debug_label.fit_content = true
	_debug_label.position = Vector2(10, 10)
	_debug_label.size = Vector2(500, 400)
	_debug_label.add_theme_font_size_override("normal_font_size", 14)
	canvas.add_child(_debug_label)


func _update_debug_overlay() -> void:
	if not _debug_label:
		return

	var env: Environment = _get_active_environment()

	var lines: PackedStringArray = PackedStringArray()
	lines.append("[b]FOG TEST ON TERRAIN[/b]")
	lines.append("G=weather  F=depth  V=volumetric  K=sky3d")
	lines.append("1-0=weather types  T/Y=time  ZQSD+mouse=fly")
	lines.append("")

	# Weather status
	if _weather_enabled:
		lines.append("[color=lime]Weather: ON[/color] — %s" % WeatherManager.get_status_string())
	else:
		lines.append("[color=red]Weather: OFF[/color]")

	# Camera altitude (for height fog reference)
	lines.append("Camera Y: %.1f m (sea level = 0)" % _camera.position.y)

	if env:
		lines.append("")
		# Depth fog
		if env.fog_enabled:
			lines.append("[color=cyan]Depth Fog: ON[/color]")
			lines.append("  density=%.4f  height=%.1f  height_density=%.3f" % [env.fog_density, env.fog_height, env.fog_height_density])
			lines.append("  sun_scatter=%.2f  aerial_persp=%.2f  sky_affect=%.2f" % [env.fog_sun_scatter, env.fog_aerial_perspective, env.fog_sky_affect])
		else:
			lines.append("[color=red]Depth Fog: OFF[/color]")

		# Volumetric fog
		if env.volumetric_fog_enabled:
			lines.append("[color=cyan]Volumetric Fog: ON[/color]")
			lines.append("  density=%.4f  anisotropy=%.2f  length=%.0fm" % [env.volumetric_fog_density, env.volumetric_fog_anisotropy, env.volumetric_fog_length])
			lines.append("  albedo=%s  sky_affect=%.2f" % [env.volumetric_fog_albedo, env.volumetric_fog_sky_affect])
		else:
			lines.append("[color=red]Volumetric Fog: OFF[/color]")

		# Sun energy
		var sun_energy: float = _sun.light_volumetric_fog_energy if _sun.visible else 0.0
		if _sky3d_enabled and _sky3d:
			var sky_sun: DirectionalLight3D = _sky3d.get_node_or_null("SunLight")
			if sky_sun:
				sun_energy = sky_sun.light_volumetric_fog_energy
		lines.append("Sun volumetric energy: %.1f" % sun_energy)

	_debug_label.text = "\n".join(lines)

#endregion
