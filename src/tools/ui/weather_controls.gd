## Weather control logic for WorldExplorer.
##
## Manages weather UI panel interactions and wires WeatherManager + WeatherRenderer
## + WeatherParticles together. Follows the RefCounted + callbacks pattern
## used by OceanControls and EnvironmentControls.
##
## Usage:
## [codeblock]
## var controls := WeatherControls.new(callbacks)
## controls.set_panels(panels)
## [/codeblock]
class_name WeatherControls
extends RefCounted


var _cb: Dictionary = {}
var _panels: ExplorerPanels = null
var _renderer: WeatherRenderer = null
var _particles: WeatherParticles = null
var _sunshine_driver: Node = null  # SunshineCloudsDriverGD instance
var _env_controls: EnvironmentControls = null

## Whether the weather system is wired and active
var weather_enabled: bool = false

## Whether weather drives ocean parameters (wind, foam, color)
var ocean_link_enabled: bool = true


func _init(callbacks: Dictionary) -> void:
	_cb = callbacks


## Set the ExplorerPanels reference
func set_panels(panels: ExplorerPanels) -> void:
	_panels = panels


## Initialize the weather renderer with environment access callbacks
func setup_renderer(env_controls: EnvironmentControls) -> void:
	_env_controls = env_controls
	var renderer_callbacks := {
		"get_sky3d": func() -> Node: return env_controls.sky_3d if env_controls.show_sky else null,
		"get_environment": env_controls.get_active_environment,
		"get_light": env_controls.get_fallback_light,
		"get_sunshine_driver": func() -> Node: return _sunshine_driver,
		"log": func(msg: String) -> void: Log.info("weather", msg),
	}
	_renderer = WeatherRenderer.new(renderer_callbacks)


## Initialize SunshineClouds2 volumetric cloud driver
func setup_sunshine_clouds(parent: Node, light: DirectionalLight3D) -> void:
	# Check if the plugin script exists (GDScript class_name, not in ClassDB)
	var driver_script_path := "res://addons/SunshineClouds2/SunshineCloudsDriver.gd"
	if not ResourceLoader.exists(driver_script_path):
		Log.info("weather", "SunshineClouds2 plugin not available — skipping volumetric clouds")
		return

	var driver_script: GDScript = load(driver_script_path) as GDScript
	if driver_script == null:
		Log.warn("weather", "SunshineClouds2 driver script failed to load")
		return

	_sunshine_driver = driver_script.new()
	_sunshine_driver.name = "SunshineCloudsDriver"
	_sunshine_driver.update_continuously = true

	# Create a clouds resource — the example .tres references files that may not exist
	var clouds_script_path := "res://addons/SunshineClouds2/SunshineClouds.gd"
	var clouds_script: GDScript = load(clouds_script_path) as GDScript
	if clouds_script:
		var clouds_res: Resource = clouds_script.new()
		# Load ALL noise textures required by the render callback — ALL must be non-null
		# or _render_callback silently skips rendering
		var noise_dir := "res://addons/SunshineClouds2/NoiseTextures/"
		if ResourceLoader.exists(noise_dir + "curl_noise_varied.tga"):
			clouds_res.set("curl_noise", load(noise_dir + "curl_noise_varied.tga"))
		if ResourceLoader.exists(noise_dir + "bluenoise_Dither.png"):
			clouds_res.set("dither_noise", load(noise_dir + "bluenoise_Dither.png"))
		if ResourceLoader.exists(noise_dir + "HeightGradient.tres"):
			clouds_res.set("height_gradient", load(noise_dir + "HeightGradient.tres"))
		if ResourceLoader.exists(noise_dir + "ExtraLargeScaleNoise.tres"):
			clouds_res.set("extra_large_noise_patterns", load(noise_dir + "ExtraLargeScaleNoise.tres"))
		if ResourceLoader.exists(noise_dir + "LargeScaleNoise.tres"):
			clouds_res.set("large_scale_noise", load(noise_dir + "LargeScaleNoise.tres"))
		if ResourceLoader.exists(noise_dir + "MediumScaleNoise.tres"):
			clouds_res.set("medium_scale_noise", load(noise_dir + "MediumScaleNoise.tres"))
		if ResourceLoader.exists(noise_dir + "SmallScaleNoise.tres"):
			clouds_res.set("small_scale_noise", load(noise_dir + "SmallScaleNoise.tres"))
		# Load compute shaders
		var shader_dir := "res://addons/SunshineClouds2/"
		if ResourceLoader.exists(shader_dir + "SunshineCloudsCompute.glsl"):
			clouds_res.set("compute_shader", load(shader_dir + "SunshineCloudsCompute.glsl"))
		if ResourceLoader.exists(shader_dir + "SunshineCloudsPreCompute.glsl"):
			clouds_res.set("pre_pass_compute_shader", load(shader_dir + "SunshineCloudsPreCompute.glsl"))
		if ResourceLoader.exists(shader_dir + "SunshineCloudsPostCompute.glsl"):
			clouds_res.set("post_pass_compute_shader", load(shader_dir + "SunshineCloudsPostCompute.glsl"))
		# Lower cloud altitude for Morrowind scale (default 1500m is too high)
		clouds_res.set("cloud_floor", 800.0)
		clouds_res.set("cloud_ceiling", 12000.0)
		# Reduce accumulation decay to mitigate 1-frame camera lag.
		# Default 0.7 causes heavy temporal blending. The SunshineClouds2 shader has
		# reprojection code for Godot 4.6's mat3x4 view matrices (#else branch in
		# SunshineCloudsCompute.glsl:900-914) but the mat3x4→mat4 reconstruction
		# via transpose may be subtly wrong, causing reprojected UVs to drift.
		# Lower decay = less old-frame bleeding = less perceived camera lag.
		clouds_res.set("accumulation_decay", 0.4)
		# Add driver to tree FIRST — clouds_res_added() needs is_inside_tree()=true
		# to register the CompositorEffect on the WorldEnvironment's Compositor
		parent.add_child(_sunshine_driver)

		# Track the directional light for cloud lighting
		if light:
			var lights: Array[DirectionalLight3D] = [light]
			_sunshine_driver.tracked_directional_lights = lights
			var shadow_steps: Array[int] = [4]
			_sunshine_driver.tracked_directional_light_shadow_steps = shadow_steps

		# Set clouds_resource AFTER add_child — the setter calls clouds_res_added()
		# which registers the CompositorEffect on the active WorldEnvironment
		_sunshine_driver.clouds_resource = clouds_res
		Log.info("weather", "SunshineClouds2 driver initialized with compositor effect")
	else:
		Log.warn("weather", "SunshineClouds2 clouds script not found")
		parent.add_child(_sunshine_driver)


## Initialize weather particles (must be called from main thread)
func setup_particles(parent: Node, camera: Camera3D) -> void:
	_particles = WeatherParticles.new()
	_particles.name = "WeatherParticles"
	_particles.set_camera(camera)
	parent.add_child(_particles)


## Set camera on particles
func set_camera(camera: Camera3D) -> void:
	if _particles:
		_particles.set_camera(camera)


## Sync Sky3D reference to WeatherManager and SunshineClouds2 (call when Sky3D is toggled)
func sync_sky3d() -> void:
	if _env_controls and _env_controls.show_sky and _env_controls.sky_3d:
		var sky3d: Node = _env_controls.sky_3d
		WeatherManager.set_sky3d(sky3d)
		# Point SunshineClouds2 at Sky3D's sun instead of fallback light
		if _sunshine_driver and sky3d.get("sun"):
			var lights: Array[DirectionalLight3D] = [sky3d.sun]
			_sunshine_driver.tracked_directional_lights = lights
	else:
		WeatherManager.set_sky3d(null)
		# Revert SunshineClouds2 to fallback light
		if _sunshine_driver and _env_controls:
			var fallback: DirectionalLight3D = _env_controls.get_fallback_light()
			if fallback:
				var lights: Array[DirectionalLight3D] = [fallback]
				_sunshine_driver.tracked_directional_lights = lights

	# Re-register CompositorEffect on the active WorldEnvironment.
	# Sky3D and fallback are different WorldEnvironment nodes — only one is in-tree
	# at a time. The CompositorEffect stays on the old one's compositor after a swap,
	# making the clouds invisible. Re-registering moves it to the active one.
	_reregister_sunshine_compositor()


## Move SunshineClouds2 CompositorEffect to the currently active WorldEnvironment.
func _reregister_sunshine_compositor() -> void:
	if not _sunshine_driver or not is_instance_valid(_sunshine_driver):
		return
	var clouds_res: Resource = _sunshine_driver.get("clouds_resource")
	if not clouds_res:
		return

	# Remove from whichever WorldEnvironment the driver finds in-tree (may be no-op
	# if the effect was on the OLD env that's no longer in-tree)
	_sunshine_driver.clouds_res_removed()

	# Also clean up the out-of-tree WorldEnvironment's compositor to prevent
	# duplicate entries from accumulating over multiple toggles
	if _env_controls:
		_remove_effect_from_compositor(clouds_res, _env_controls.sky_3d)
		_remove_effect_from_compositor(clouds_res, _env_controls._fallback_world_env)

	# Add to the currently active (in-tree) WorldEnvironment
	_sunshine_driver.clouds_res_added()

	# Sync environment fog color sampling to the active environment
	var active_env: Environment = _env_controls.get_active_environment() if _env_controls else null
	if active_env:
		_sunshine_driver.ambience_sample_environment = active_env

	Log.info("weather", "SunshineClouds2 compositor re-registered on active WorldEnvironment")


## Remove a CompositorEffect from a WorldEnvironment's compositor (safe if not present).
static func _remove_effect_from_compositor(effect: Resource, world_env: Node) -> void:
	if not world_env or not is_instance_valid(world_env):
		return
	var compositor: Compositor = world_env.get("compositor") as Compositor
	if not compositor:
		return
	var effects: Array[CompositorEffect] = compositor.compositor_effects
	if effects.has(effect):
		effects.erase(effect)
		compositor.compositor_effects = effects


## Fog density multiplier (user-adjustable, default 1.0)
var fog_density_multiplier: float = 1.0


## Toggle weather system on/off
func on_weather_toggled(enabled: bool) -> void:
	weather_enabled = enabled
	WeatherManager.enabled = enabled

	# Notify environment_controls that weather owns fog/ambient values
	if _env_controls:
		_env_controls.weather_active = enabled
		# Auto-enable depth fog when weather is turned on
		if enabled and not _env_controls._visual_state.get("depth_fog", false):
			_env_controls.on_depth_fog_toggled(true)
			# Sync checkbox without re-triggering signal
			if _panels and _panels.depth_fog_toggle:
				_panels.depth_fog_toggle.set_pressed_no_signal(true)

	if _renderer:
		_renderer.set_active(enabled)
		_renderer.fog_density_multiplier = fog_density_multiplier

	if _particles:
		_particles.visible = enabled

	# Reset ocean to calm defaults when weather is disabled
	if not enabled and OceanManager.is_system_enabled():
		OceanManager.reset_weather()

	Log.info("weather", "Weather system %s" % ("enabled" if enabled else "disabled"))


## Handle fog density slider change
func on_fog_density_changed(value: float) -> void:
	fog_density_multiplier = value
	if _renderer:
		_renderer.fog_density_multiplier = value
	_set_preset_to_custom()


## Handle cloud coverage slider change (manual override)
func on_cloud_coverage_changed(value: float) -> void:
	if _sunshine_driver and is_instance_valid(_sunshine_driver):
		var res: Resource = _sunshine_driver.get("clouds_resource")
		if res:
			res.set("clouds_coverage", value)
	_set_preset_to_custom()


## Weather preset definitions: {weather_type, time, time_scale, paused, auto_weather}
const PRESETS := {
	1: {"name": "Morrowind Default", "auto": true, "time": 8.0, "speed": 30.0, "paused": false, "type": -1},
	2: {"name": "Clear Day", "auto": false, "time": 12.0, "speed": 0.0, "paused": true, "type": WeatherTypes.Type.CLEAR},
	3: {"name": "Foggy Morning", "auto": false, "time": 7.0, "speed": 0.0, "paused": true, "type": WeatherTypes.Type.FOGGY},
	4: {"name": "Stormy Night", "auto": false, "time": 22.0, "speed": 0.0, "paused": true, "type": WeatherTypes.Type.THUNDERSTORM},
	5: {"name": "Ashstorm", "auto": false, "time": 14.0, "speed": 0.0, "paused": true, "type": WeatherTypes.Type.ASHSTORM},
	6: {"name": "Blizzard", "auto": false, "time": 16.0, "speed": 0.0, "paused": true, "type": WeatherTypes.Type.BLIZZARD},
	7: {"name": "Golden Hour", "auto": false, "time": 18.5, "speed": 0.0, "paused": true, "type": WeatherTypes.Type.CLEAR},
}

## Whether we're currently applying a preset (prevents re-entrancy)
var _applying_preset: bool = false


## Handle weather preset selection
func on_weather_preset_changed(index: int) -> void:
	if index == 0 or not PRESETS.has(index):
		return  # "Custom" selected or invalid

	_applying_preset = true
	var preset: Dictionary = PRESETS[index]

	# Enable weather if not already
	if not weather_enabled:
		on_weather_toggled(true)
		if _panels and _panels.weather_enabled_toggle:
			_panels.weather_enabled_toggle.set_pressed_no_signal(true)

	# Set weather type
	if preset.auto:
		WeatherManager.auto_weather = true
		if _panels and _panels.weather_type_btn:
			_panels.weather_type_btn.select(0)  # "Auto"
	else:
		WeatherManager.auto_weather = false
		WeatherManager.set_weather(preset.type)
		if _panels and _panels.weather_type_btn:
			_panels.weather_type_btn.select(preset.type + 1)  # +1 for "Auto" at index 0

	# Set time
	WeatherManager.set_game_hour(preset.time)
	if _panels and _panels.time_of_day_slider:
		_panels.time_of_day_slider.set_value_no_signal(preset.time)
		_update_time_label()

	# Set speed
	WeatherManager.set_time_scale(preset.speed)
	if _panels and _panels.time_scale_slider:
		_panels.time_scale_slider.set_value_no_signal(preset.speed)

	# Set pause
	WeatherManager.time_paused = preset.paused
	if _panels and _panels.time_pause_toggle:
		_panels.time_pause_toggle.set_pressed_no_signal(preset.paused)

	Log.info("weather", "Preset applied: %s" % preset.name)
	_applying_preset = false


## Reset preset dropdown to "Custom" when user manually changes a control
func _set_preset_to_custom() -> void:
	if _applying_preset:
		return
	if _panels and _panels.weather_preset_btn and _panels.weather_preset_btn.selected != 0:
		_panels.weather_preset_btn.select(0)


## Handle time-of-day slider change
func on_time_of_day_changed(value: float) -> void:
	WeatherManager.set_game_hour(value)
	_update_time_label()
	_set_preset_to_custom()


## Handle time scale slider change
func on_time_scale_changed(value: float) -> void:
	WeatherManager.set_time_scale(value)
	_set_preset_to_custom()


## Handle weather type override dropdown
func on_weather_type_changed(index: int) -> void:
	if index <= 0:
		# "Auto" selected — re-enable automatic weather
		WeatherManager.auto_weather = true
		Log.info("weather", "Weather set to auto")
	else:
		# Manual override — index 1 = CLEAR (0), index 2 = CLOUDY (1), etc.
		WeatherManager.auto_weather = false
		WeatherManager.set_weather(index - 1)
	_set_preset_to_custom()


## Handle time pause toggle
func on_time_pause_toggled(paused: bool) -> void:
	WeatherManager.time_paused = paused
	_set_preset_to_custom()


## Base cloud coverage when weather system is disabled
const BASE_CLOUD_COVERAGE: float = 0.4

## Called each frame by world_explorer to drive rendering
func process(delta: float) -> void:
	# Always drive cloud coverage — clouds should be visible regardless of weather toggle
	_update_cloud_coverage()

	if not weather_enabled:
		return

	var result: WeatherTypes.WeatherResult = WeatherManager.get_weather_result()

	if _renderer and _renderer.is_active():
		_renderer.apply(result)

	if _particles:
		_particles.update(result)

	# Drive ocean parameters from weather (wind → waves, color, foam)
	if ocean_link_enabled and OceanManager.is_system_enabled():
		OceanManager.apply_weather(result)

	_update_status_label()


## Drive SunshineClouds2 cloud coverage — always runs, weather or not
func _update_cloud_coverage() -> void:
	if _sunshine_driver == null or not is_instance_valid(_sunshine_driver):
		return
	var res: Resource = _sunshine_driver.get("clouds_resource")
	if res == null:
		return

	var coverage: float
	if weather_enabled:
		var result: WeatherTypes.WeatherResult = WeatherManager.get_weather_result()
		coverage = result.cloud_coverage
	else:
		coverage = BASE_CLOUD_COVERAGE

	res.set("clouds_coverage", coverage)


## Update the weather status info label in the panel
func _update_status_label() -> void:
	if _panels == null:
		return
	if _panels.weather_status_label == null:
		return
	_panels.weather_status_label.text = WeatherManager.get_status_string()


## Update the time label next to the slider
func _update_time_label() -> void:
	if _panels == null:
		return
	if _panels.time_of_day_slider == null:
		return
	var parent: Node = _panels.time_of_day_slider.get_parent()
	if parent:
		var value_label: Label = parent.get_node_or_null("Value")
		if value_label:
			value_label.text = "%.1f" % WeatherManager.game_hour


#region Console Commands

## Register weather console commands
func register_console_commands(console: Node) -> void:
	if console == null or not console.has_method("register_command"):
		return

	var weather_params: Array[CommandRegistry.ParameterInfo] = [
		CommandRegistry.ParameterInfo.new("type", TYPE_STRING, "Weather type name")
	]
	console.register_command("weather", _cmd_weather,
		"Set weather type immediately",
		"weather", PackedStringArray(), weather_params,
		PackedStringArray(["weather rain", "weather clear"]))

	var time_params: Array[CommandRegistry.ParameterInfo] = [
		CommandRegistry.ParameterInfo.new("hour", TYPE_FLOAT, "Game hour (0-24)")
	]
	console.register_command("time", _cmd_time,
		"Set game hour",
		"weather", PackedStringArray(), time_params,
		PackedStringArray(["time 12", "time 6.5"]))

	var ts_params: Array[CommandRegistry.ParameterInfo] = [
		CommandRegistry.ParameterInfo.new("scale", TYPE_FLOAT, "Game-seconds per real-second")
	]
	console.register_command("timescale", _cmd_timescale,
		"Set time scale",
		"weather", PackedStringArray(), ts_params,
		PackedStringArray(["timescale 30", "timescale 0"]))

	console.register_command("weather_info", _cmd_weather_info,
		"Show weather status",
		"weather")


func _cmd_weather(args: Dictionary) -> CommandRegistry.CommandResult:
	var type_str: String = args.get("type", "")
	if type_str.is_empty():
		return CommandRegistry.CommandResult.ok("Types: clear, cloudy, foggy, overcast, rain, thunderstorm, ashstorm, blight, snow, blizzard")

	var type_name: String = type_str.to_lower()
	for i: int in WeatherTypes.TYPE_NAMES.size():
		if WeatherTypes.TYPE_NAMES[i].to_lower() == type_name:
			WeatherManager.auto_weather = false
			WeatherManager.set_weather(i)
			return CommandRegistry.CommandResult.ok("Weather set to: %s" % WeatherTypes.TYPE_NAMES[i])

	return CommandRegistry.CommandResult.error("Unknown weather type: %s" % type_str)


func _cmd_time(args: Dictionary) -> CommandRegistry.CommandResult:
	var hour_str: String = str(args.get("hour", ""))
	if hour_str.is_empty():
		return CommandRegistry.CommandResult.ok("Current time: %.1f" % WeatherManager.game_hour)

	WeatherManager.set_game_hour(float(hour_str))
	return CommandRegistry.CommandResult.ok("Game hour set to: %.1f" % WeatherManager.game_hour)


func _cmd_timescale(args: Dictionary) -> CommandRegistry.CommandResult:
	var scale_str: String = str(args.get("scale", ""))
	if scale_str.is_empty():
		return CommandRegistry.CommandResult.ok("Current timescale: %.1f" % WeatherManager.time_scale)

	WeatherManager.set_time_scale(float(scale_str))
	return CommandRegistry.CommandResult.ok("Timescale set to: %.1f" % WeatherManager.time_scale)


func _cmd_weather_info(_args: Dictionary) -> CommandRegistry.CommandResult:
	return CommandRegistry.CommandResult.ok(WeatherManager.get_status_string())

#endregion
