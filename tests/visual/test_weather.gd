## Visual test for weather system.
##
## Standalone scene — no ESM loading, no asset streaming.
## Tests: Sky3D + SunshineClouds2 clouds + weather driving Sky3D params.
## Includes fog debug overlay showing fog sources and clock status.
##
## Controls:
##   1-9, 0  = Weather presets (Clear, Cloudy, ..., Blizzard)
##   T/Y     = Time backward/forward (+/- 1 hour)
##   +/-     = Time scale up/down
##   F       = Toggle depth fog
##   V       = Toggle volumetric fog
##   W       = Toggle weather system
##   K       = Toggle Sky3D
##   C       = Toggle SunshineClouds2 (isolate compositor artifact)
##   P       = Toggle ProceduralSkyMaterial sun (set sun_angle_max to 0)
##   Mouse   = Hold right-click to look, WASD to move, Space/Shift up/down
extends Node3D

# --- Nodes ---
var _camera: Camera3D
var _light: DirectionalLight3D
var _world_env: WorldEnvironment
var _sky3d: Node = null
var _sky3d_enabled: bool = false
var _sunshine_driver: Node = null
var _clouds_resource: Resource = null
var _particles: WeatherParticles = null
var _renderer: WeatherRenderer = null

# --- State ---
var _depth_fog_enabled: bool = true
var _volumetric_fog_enabled: bool = false
var _weather_enabled: bool = false
var _sunshine_enabled: bool = true
var _mouse_captured: bool = false
var _fly_speed: float = 20.0

# --- UI ---
var _debug_label: RichTextLabel


func _ready() -> void:
	_setup_environment()
	_setup_camera()
	_setup_sky3d()
	_setup_sunshine_clouds()
	_setup_weather()
	_setup_ui()

	_camera.position = Vector3(-200, 60, 400)
	_camera.rotation_degrees = Vector3(-10, -30, 0)

	Log.info("weather", "Weather test scene ready. Keys: 1-0=weather, T/Y=time, W=toggle, K=Sky3D, F=fog, V=vol.fog")


func _setup_environment() -> void:
	_world_env = WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY

	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.385, 0.454, 0.55)
	mat.sky_horizon_color = Color(0.646, 0.656, 0.67)
	mat.ground_bottom_color = Color(0.2, 0.169, 0.133)
	mat.ground_horizon_color = Color(0.646, 0.656, 0.67)
	mat.sun_angle_max = 1.0
	sky.sky_material = mat
	env.sky = sky

	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = 1.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	env.ssr_enabled = true
	env.ssr_max_steps = 64
	env.ssr_fade_in = 0.15
	env.ssr_fade_out = 2.0
	env.ssr_depth_tolerance = 0.2

	env.fog_enabled = true
	env.fog_density = 0.002
	env.fog_light_color = Color(0.8, 0.85, 0.9)

	_world_env.environment = env
	add_child(_world_env)

	_light = DirectionalLight3D.new()
	_light.name = "SunLight"
	_light.rotation_degrees = Vector3(-45, -30, 0)
	_light.shadow_enabled = true
	_light.light_energy = 1.2
	_light.light_color = Color(1.0, 0.98, 0.95)
	_light.directional_shadow_max_distance = 500.0
	add_child(_light)

	# Ground plane
	var ground := MeshInstance3D.new()
	var plane_mesh := PlaneMesh.new()
	plane_mesh.size = Vector2(2000, 2000)
	ground.mesh = plane_mesh
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.35, 0.3, 0.25)
	ground.material_override = ground_mat
	add_child(ground)


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "FlyCamera"
	_camera.current = true
	_camera.far = 10000.0
	add_child(_camera)


func _setup_sky3d() -> void:
	var sky3d_script_path := "res://addons/sky_3d/src/Sky3D.gd"
	if not ResourceLoader.exists(sky3d_script_path):
		Log.info("weather", "Sky3D plugin not available")
		return

	var sky3d_script: GDScript = load(sky3d_script_path) as GDScript
	if sky3d_script == null:
		Log.warn("weather", "Sky3D script failed to load")
		return

	_sky3d = sky3d_script.new()
	_sky3d.name = "Sky3D"


func _setup_sunshine_clouds() -> void:
	var driver_script_path := "res://addons/SunshineClouds2/SunshineCloudsDriver.gd"
	if not ResourceLoader.exists(driver_script_path):
		Log.info("weather", "SunshineClouds2 not available — no volumetric clouds")
		return

	var driver_script: GDScript = load(driver_script_path) as GDScript
	if driver_script == null:
		return

	_sunshine_driver = driver_script.new()
	_sunshine_driver.name = "SunshineCloudsDriver"
	_sunshine_driver.update_continuously = true

	# Add to tree FIRST (compositor registration needs is_inside_tree)
	add_child(_sunshine_driver)

	# Track fallback sun initially
	var lights: Array[DirectionalLight3D] = [_light]
	_sunshine_driver.tracked_directional_lights = lights
	var shadow_steps: Array[int] = [4]
	_sunshine_driver.tracked_directional_light_shadow_steps = shadow_steps

	# Create clouds resource with ALL required textures
	var clouds_script: GDScript = load("res://addons/SunshineClouds2/SunshineClouds.gd") as GDScript
	if clouds_script:
		_clouds_resource = clouds_script.new()
		var noise_dir := "res://addons/SunshineClouds2/NoiseTextures/"
		if ResourceLoader.exists(noise_dir + "curl_noise_varied.tga"):
			_clouds_resource.set("curl_noise", load(noise_dir + "curl_noise_varied.tga"))
		if ResourceLoader.exists(noise_dir + "bluenoise_Dither.png"):
			_clouds_resource.set("dither_noise", load(noise_dir + "bluenoise_Dither.png"))
		if ResourceLoader.exists(noise_dir + "HeightGradient.tres"):
			_clouds_resource.set("height_gradient", load(noise_dir + "HeightGradient.tres"))
		if ResourceLoader.exists(noise_dir + "ExtraLargeScaleNoise.tres"):
			_clouds_resource.set("extra_large_noise_patterns", load(noise_dir + "ExtraLargeScaleNoise.tres"))
		if ResourceLoader.exists(noise_dir + "LargeScaleNoise.tres"):
			_clouds_resource.set("large_scale_noise", load(noise_dir + "LargeScaleNoise.tres"))
		if ResourceLoader.exists(noise_dir + "MediumScaleNoise.tres"):
			_clouds_resource.set("medium_scale_noise", load(noise_dir + "MediumScaleNoise.tres"))
		if ResourceLoader.exists(noise_dir + "SmallScaleNoise.tres"):
			_clouds_resource.set("small_scale_noise", load(noise_dir + "SmallScaleNoise.tres"))
		var shader_dir := "res://addons/SunshineClouds2/"
		if ResourceLoader.exists(shader_dir + "SunshineCloudsCompute.glsl"):
			_clouds_resource.set("compute_shader", load(shader_dir + "SunshineCloudsCompute.glsl"))
		if ResourceLoader.exists(shader_dir + "SunshineCloudsPreCompute.glsl"):
			_clouds_resource.set("pre_pass_compute_shader", load(shader_dir + "SunshineCloudsPreCompute.glsl"))
		if ResourceLoader.exists(shader_dir + "SunshineCloudsPostCompute.glsl"):
			_clouds_resource.set("post_pass_compute_shader", load(shader_dir + "SunshineCloudsPostCompute.glsl"))
		# Lower cloud altitude for Morrowind scale
		_clouds_resource.set("cloud_floor", 800.0)
		_clouds_resource.set("cloud_ceiling", 12000.0)
		_clouds_resource.set("clouds_coverage", 0.4)
		_sunshine_driver.clouds_resource = _clouds_resource
		Log.info("weather", "SunshineClouds2 clouds initialized (compositor registered)")


func _setup_weather() -> void:
	# Renderer with Sky3D callback — matches refactored architecture
	var renderer_callbacks := {
		"get_sky3d": func() -> Node: return _sky3d if _sky3d_enabled else null,
		"get_environment": func() -> Environment: return _get_active_env(),
		"get_light": func() -> DirectionalLight3D: return _light,
		"get_sunshine_driver": func() -> Node: return _sunshine_driver,
		"log": func(msg: String) -> void: Log.info("weather", msg),
	}
	_renderer = WeatherRenderer.new(renderer_callbacks)

	_particles = WeatherParticles.new()
	_particles.name = "WeatherParticles"
	_particles.set_camera(_camera)
	add_child(_particles)


func _setup_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "UI"
	add_child(canvas)

	_debug_label = RichTextLabel.new()
	_debug_label.name = "FogDebug"
	_debug_label.bbcode_enabled = true
	_debug_label.fit_content = true
	_debug_label.scroll_active = false
	_debug_label.position = Vector2(10, 10)
	_debug_label.size = Vector2(500, 400)
	_debug_label.add_theme_font_size_override("normal_font_size", 14)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.6)
	style.set_content_margin_all(8)
	_debug_label.add_theme_stylebox_override("normal", style)
	canvas.add_child(_debug_label)

	var help := Label.new()
	help.text = "1-0: Weather | T/Y: Time | +/-: Speed | W: Weather | K: Sky3D | C: Clouds | P: Sun | F: Fog | V: Vol.Fog"
	help.add_theme_font_size_override("font_size", 12)
	help.anchors_preset = Control.PRESET_BOTTOM_WIDE
	help.position.y = -30
	canvas.add_child(help)


func _process(delta: float) -> void:
	_handle_fly_camera(delta)
	_update_cloud_coverage()

	if _weather_enabled:
		var result: WeatherTypes.WeatherResult = WeatherManager.get_weather_result()
		if _renderer:
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
			KEY_EQUAL: WeatherManager.set_time_scale(WeatherManager.time_scale * 2.0)
			KEY_MINUS: WeatherManager.set_time_scale(maxf(0.0, WeatherManager.time_scale * 0.5))
			KEY_W: _toggle_weather()
			KEY_K: _toggle_sky3d()
			KEY_C: _toggle_sunshine_clouds()
			KEY_P: _toggle_procedural_sun()
			KEY_F: _toggle_depth_fog()
			KEY_V: _toggle_volumetric_fog()

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
	if Input.is_key_pressed(KEY_A): direction -= _camera.global_basis.x
	if Input.is_key_pressed(KEY_D): direction += _camera.global_basis.x
	if Input.is_key_pressed(KEY_S): direction += _camera.global_basis.z
	direction -= _camera.global_basis.z * (1.0 if Input.is_key_pressed(KEY_UP) or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) else 0.0)
	if Input.is_key_pressed(KEY_SPACE): direction.y += 1.0
	if Input.is_key_pressed(KEY_CTRL): direction.y -= 1.0
	if direction.length_squared() > 0.001:
		_camera.position += direction.normalized() * speed * delta

#endregion


#region Weather Controls

func _set_weather(type: int) -> void:
	if not _weather_enabled:
		_toggle_weather()
	WeatherManager.auto_weather = false
	WeatherManager.set_weather(type)


func _toggle_weather() -> void:
	_weather_enabled = not _weather_enabled
	WeatherManager.enabled = _weather_enabled
	if _renderer:
		_renderer.set_active(_weather_enabled)
	if _particles:
		_particles.visible = _weather_enabled
	Log.info("weather", "Weather: %s" % ("ON" if _weather_enabled else "OFF"))


func _toggle_sky3d() -> void:
	if _sky3d == null:
		Log.warn("weather", "Sky3D not available")
		return

	_sky3d_enabled = not _sky3d_enabled
	if _sky3d_enabled:
		if _world_env.is_inside_tree():
			remove_child(_world_env)
		if not _sky3d.is_inside_tree():
			add_child(_sky3d)
		_sky3d.set("sky3d_enabled", true)
		_light.visible = false
	else:
		if _sky3d.is_inside_tree():
			remove_child(_sky3d)
		_sky3d.set("sky3d_enabled", false)
		if not _world_env.is_inside_tree():
			add_child(_world_env)
		_light.visible = true

	# Sync Sky3D to weather system
	_sync_sky3d()
	Log.info("weather", "Sky3D: %s" % ("ON" if _sky3d_enabled else "OFF"))


func _sync_sky3d() -> void:
	# Sync clock ownership
	if _sky3d_enabled and _sky3d:
		WeatherManager.set_sky3d(_sky3d)
	else:
		WeatherManager.set_sky3d(null)

	# Sync SunshineClouds2 tracked light
	if _sunshine_driver:
		if _sky3d_enabled and _sky3d and _sky3d.get("sun"):
			var lights: Array[DirectionalLight3D] = [_sky3d.get("sun")]
			_sunshine_driver.tracked_directional_lights = lights
		else:
			var lights: Array[DirectionalLight3D] = [_light]
			_sunshine_driver.tracked_directional_lights = lights


func _toggle_sunshine_clouds() -> void:
	if _sunshine_driver == null:
		Log.warn("weather", "SunshineClouds2 not available")
		return
	_sunshine_enabled = not _sunshine_enabled
	# Toggle by setting/clearing the clouds_resource (controls compositor effect)
	if not _sunshine_enabled:
		_sunshine_driver.set("clouds_resource", null)
	elif _clouds_resource:
		_sunshine_driver.set("clouds_resource", _clouds_resource)
	Log.info("weather", "SunshineClouds2: %s" % ("ON" if _sunshine_enabled else "OFF"))


func _toggle_procedural_sun() -> void:
	if _world_env and _world_env.environment and _world_env.environment.sky:
		var mat: ProceduralSkyMaterial = _world_env.environment.sky.sky_material as ProceduralSkyMaterial
		if mat:
			if mat.sun_angle_max > 0.1:
				mat.sun_angle_max = 0.0
				Log.info("weather", "ProceduralSky sun disc: OFF")
			else:
				mat.sun_angle_max = 1.0
				Log.info("weather", "ProceduralSky sun disc: ON")


func _toggle_depth_fog() -> void:
	_depth_fog_enabled = not _depth_fog_enabled
	var env: Environment = _get_active_env()
	if env:
		env.fog_enabled = _depth_fog_enabled
	Log.info("weather", "Depth fog: %s" % ("ON" if _depth_fog_enabled else "OFF"))


func _toggle_volumetric_fog() -> void:
	_volumetric_fog_enabled = not _volumetric_fog_enabled
	var env: Environment = _get_active_env()
	if env:
		env.volumetric_fog_enabled = _volumetric_fog_enabled
		if _volumetric_fog_enabled:
			env.volumetric_fog_density = 0.015
			env.volumetric_fog_albedo = Color(0.9, 0.9, 0.95)
			env.volumetric_fog_length = 300.0
			env.volumetric_fog_anisotropy = 0.7
	Log.info("weather", "Volumetric fog: %s" % ("ON" if _volumetric_fog_enabled else "OFF"))

#endregion


#region Cloud Coverage

func _update_cloud_coverage() -> void:
	if _clouds_resource == null:
		return
	if _weather_enabled:
		var result: WeatherTypes.WeatherResult = WeatherManager.get_weather_result()
		_clouds_resource.set("clouds_coverage", result.cloud_coverage)
	else:
		_clouds_resource.set("clouds_coverage", 0.4)

#endregion


#region Debug Overlay

func _get_active_env() -> Environment:
	if _sky3d_enabled and _sky3d and _sky3d.get("environment") != null:
		return _sky3d.get("environment")
	if _world_env and _world_env.environment:
		return _world_env.environment
	return null


func _update_debug_overlay() -> void:
	if _debug_label == null:
		return

	var env: Environment = _get_active_env()
	var lines: PackedStringArray = PackedStringArray()

	lines.append("[b]WEATHER TEST SCENE[/b]")
	lines.append("")

	# Clock source
	var sky3d_clock: bool = _sky3d_enabled and _sky3d != null
	lines.append("[b]Clock:[/b] %s" % ("Sky3D" if sky3d_clock else "Internal"))
	lines.append("  Time: %.1f | Scale: %.0f" % [WeatherManager.game_hour, WeatherManager.time_scale])
	lines.append("")

	# Weather state
	lines.append("[b]Weather:[/b] %s" % ("ON" if _weather_enabled else "OFF"))
	if _weather_enabled:
		lines.append("  Type: %s" % WeatherTypes.type_name(WeatherManager.get_current_weather()))
		if WeatherManager.is_transitioning():
			lines.append("  Transitioning...")
		var result: WeatherTypes.WeatherResult = WeatherManager.get_weather_result()
		lines.append("  Cloud coverage: %.2f" % result.cloud_coverage)
		lines.append("  Fog depth (MW): %.2f" % result.fog_depth)
		lines.append("  Wind speed: %.2f" % result.wind_speed)
	lines.append("")

	# Sky3D state
	lines.append("[b]Sky3D:[/b] %s" % ("ON" if _sky3d_enabled else "OFF"))
	if _sky3d_enabled and _sky3d:
		var sky_dome: Node = _sky3d.get("sky")
		if sky_dome:
			var fog_d: float = sky_dome.get("fog_density") if sky_dome.get("fog_density") != null else -1.0
			var cum_cov: float = sky_dome.get("cumulus_coverage") if sky_dome.get("cumulus_coverage") != null else -1.0
			lines.append("  SkyDome fog_density: %.4f" % fog_d)
			lines.append("  SkyDome cumulus_coverage: %.2f" % cum_cov)
	lines.append("")

	# Fog sources
	lines.append("[b]=== FOG ===[/b]")
	if env:
		lines.append("[color=yellow]Depth Fog:[/color] %s (density: %.4f)" % [
			"ON" if env.fog_enabled else "OFF", env.fog_density if env.fog_enabled else 0.0])
		lines.append("[color=cyan]Volumetric:[/color] %s" % ("ON" if env.volumetric_fog_enabled else "OFF"))
		if _sky3d_enabled and _sky3d:
			var atm_on: bool = _sky3d.get("fog_enabled") if _sky3d.get("fog_enabled") != null else false
			lines.append("[color=green]Sky3D AtmFog:[/color] %s" % ("ON" if atm_on else "OFF"))
	lines.append("")

	# Clouds
	lines.append("[b]Clouds:[/b] %s" % ("ON" if _sunshine_enabled else "[color=red]OFF[/color]"))
	if _clouds_resource and _sunshine_enabled:
		var cov: float = _clouds_resource.get("clouds_coverage") if _clouds_resource.get("clouds_coverage") != null else -1.0
		lines.append("  SC2 coverage: %.2f" % cov)
		lines.append("  compositor: %s" % ("registered" if _sunshine_driver and _sunshine_driver.is_inside_tree() else "NOT registered"))
	elif not _sunshine_enabled:
		lines.append("  [color=yellow]Disabled (press C to enable)[/color]")
	else:
		lines.append("  [color=red]No clouds resource[/color]")

	_debug_label.text = "\n".join(lines)

#endregion
