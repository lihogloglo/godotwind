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

## Baseline SunshineClouds2 noise scales captured the first time a cloud
## parameter slider fires. The "Cloud Size" slider is a coarse multiplier
## applied on top of these baselines so tweaking it doesn't cumulatively
## scale the plugin defaults further on every slider move.
var _noise_scale_baseline: Dictionary = {}  # name → float (captured once)


func _init(callbacks: Dictionary) -> void:
	_cb = callbacks


## Set the ExplorerPanels reference
func set_panels(panels: ExplorerPanels) -> void:
	_panels = panels


## Initialize the weather renderer with environment access callbacks
func setup_renderer(env_controls: EnvironmentControls) -> void:
	_env_controls = env_controls
	var renderer_callbacks := {
		"get_sky_manager": func() -> Node: return env_controls.sky_manager if env_controls.show_sky else null,
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
	# NOTE: Do NOT set update_continuously here. The driver's _ready() checks
	# clouds_resource — if null, it sets update_continuously=false permanently.
	# We set it AFTER clouds_resource is assigned (see below).

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
		# Temporal accumulation: 0.55 balances shimmer suppression vs camera lag.
		# Default 0.7 causes heavy camera lag; 0.4 was too low (shimmer).
		clouds_res.set("accumulation_decay", 0.55)
		# Enable environment fog color sampling so clouds match the atmosphere
		clouds_res.set("use_environment_fog", 0.5)
		# Set ambient tint to neutral — we drive cloud_ambient_color directly from sky state
		# Default tint (0.133, 0.2, 0.243) is too dark and multiplies with our computed ambient
		clouds_res.set("cloud_ambient_tint", Color(1.0, 1.0, 1.0, 1.0))
		# Neutralize AO color — plugin default is RED (1,0,0,1) which tints all clouds
		# pink/red wherever the ambient occlusion term is non-zero. Alpha=0 disables
		# AO coloring entirely; white+alpha would darken uniformly without color shift.
		clouds_res.set("ambient_occlusion_color", Color(1.0, 1.0, 1.0, 0.0))
		# Moderate post-pass blur to mask dither noise at half-resolution.
		# Defaults (2.0, 1.0) shimmer too much; (4.0, 2.0) costs too much GPU.
		# 2.5/1.0 is a balance — slightly smoother than default, minimal GPU cost.
		clouds_res.set("blur_power", 2.5)
		clouds_res.set("blur_quality", 1.0)
		# Add driver to tree FIRST — clouds_res_added() needs is_inside_tree()=true
		# to register the CompositorEffect on the WorldEnvironment's Compositor
		parent.add_child(_sunshine_driver)

		# Wire ambience_sample_environment so driver can sync fog color per-frame.
		# Without this, sampled_environment_fog_color stays at bright default (0.52,0.55,0.61)
		# and clouds stay white at night even though we darken atmosphere_color.
		if _env_controls:
			var active_env: Environment = _env_controls.get_active_environment()
			if active_env:
				_sunshine_driver.ambience_sample_environment = active_env

		# Track the directional light for cloud lighting
		if light:
			var lights: Array[DirectionalLight3D] = [light]
			_sunshine_driver.tracked_directional_lights = lights
			var shadow_steps: Array[int] = [4]
			_sunshine_driver.tracked_directional_light_shadow_steps = shadow_steps

		# Set clouds_resource AFTER add_child — the setter calls clouds_res_added()
		# which registers the CompositorEffect on the active WorldEnvironment
		_sunshine_driver.clouds_resource = clouds_res

		# Enable continuous updates AFTER clouds_resource is set.
		# Driver._ready() kills update_continuously if clouds_resource is null,
		# so this must come after the resource assignment.
		_sunshine_driver.update_continuously = true

		# Disable clouds until weather or sky is explicitly enabled.
		# CompositorEffect defaults enabled=true, so clouds would render at startup
		# even with sky/weather toggles OFF.
		clouds_res.enabled = false

		# Wire cloud density source into ShaderManager so godrays can read
		# accumulation_textures live for sun disc occlusion behind clouds.
		ShaderManager.set_cloud_source(clouds_res)

		Log.info("weather", "SunshineClouds2 driver initialized (disabled until weather/sky enabled)")
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


## Sync sky reference to SunshineClouds2 (call when sky is toggled)
func sync_sky() -> void:
	if _env_controls and _env_controls.show_sky and _env_controls.sky_manager:
		# Point SunshineClouds2 at SkyManager's sun
		if _sunshine_driver:
			var sun: DirectionalLight3D = _env_controls.sky_manager.get_sun_light()
			if sun:
				var lights: Array[DirectionalLight3D] = [sun]
				_sunshine_driver.tracked_directional_lights = lights
	else:
		# Revert SunshineClouds2 to fallback light
		if _sunshine_driver and _env_controls:
			var fallback: DirectionalLight3D = _env_controls.get_fallback_light()
			if fallback:
				var lights: Array[DirectionalLight3D] = [fallback]
				_sunshine_driver.tracked_directional_lights = lights

	# Re-register CompositorEffect on the active WorldEnvironment.
	# SkyManager and fallback are different WorldEnvironment nodes — only one is in-tree
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
		if not enabled:
			# Synchronous handoff: weather cleans up its writes FIRST,
			# then EnvironmentControls re-asserts defaults. Same call stack,
			# no deferred — avoids one-frame stale emission/ambient.
			_renderer.cleanup_on_deactivate()
		_renderer.set_active(enabled)
		_renderer.fog_density_multiplier = fog_density_multiplier

	# After weather cleanup, re-assert environment defaults so fog
	# returns to neutral colors (replaces the old manual albedo reset)
	if not enabled and _env_controls:
		_env_controls.reassert_fog_defaults()

	# Enable/disable SunshineClouds2 rendering
	_set_clouds_enabled(enabled or (_env_controls and _env_controls.show_sky))

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


## Handle cloud coverage slider change. When weather is active, WeatherRenderer
## overwrites this each frame from the interpolated preset — slider acts as
## manual override only when weather is OFF.
func on_cloud_coverage_changed(value: float) -> void:
	_set_cloud_param("clouds_coverage", value)


## Handle cloud density slider change.
func on_cloud_density_changed(value: float) -> void:
	_set_cloud_param("clouds_density", value)


## Handle cloud sharpness slider change.
func on_cloud_sharpness_changed(value: float) -> void:
	_set_cloud_param("clouds_sharpness", value)


## Handle cloud size slider change. Coarse multiplier applied to the
## SunshineClouds2 noise-scale parameters relative to their captured
## baseline — keeps the plugin defaults as the reference point.
func on_cloud_size_changed(value: float) -> void:
	var res: Resource = _get_clouds_resource()
	if res == null:
		return
	# Capture baselines the first time any cloud-size adjustment fires.
	# Without this, each slider move would compound against the previous
	# scaled value, causing runaway drift.
	if _noise_scale_baseline.is_empty():
		_noise_scale_baseline["extra_large"] = float(res.get("extra_large_noise_scale"))
		_noise_scale_baseline["large"] = float(res.get("large_noise_scale"))
		_noise_scale_baseline["medium"] = float(res.get("medium_noise_scale"))
		_noise_scale_baseline["small"] = float(res.get("small_noise_scale"))
	res.set("extra_large_noise_scale", _noise_scale_baseline["extra_large"] * value)
	res.set("large_noise_scale", _noise_scale_baseline["large"] * value)
	res.set("medium_noise_scale", _noise_scale_baseline["medium"] * value)
	res.set("small_noise_scale", _noise_scale_baseline["small"] * value)


## Handle wind strength slider change. Drives both cloud wind-sweep and
## the ocean wave system (via OceanManager override).
func on_wind_strength_changed(value: float) -> void:
	# Clouds: wind_swept_strength ranges 0-5000. Use a gentle curve so mid
	# slider values produce visible drift without overshooting the default.
	var cloud_sweep: float = lerpf(0.0, 2500.0, value)
	_set_cloud_param("wind_swept_strength", cloud_sweep)
	# Ocean: delegate to OceanManager — it internally maps 0-1 to cascade
	# wind_speed + storm-fog multiplier. See OceanManager.set_wind_strength.
	if OceanManager and OceanManager.is_system_enabled() and OceanManager.has_method("set_wind_strength"):
		OceanManager.set_wind_strength(value)


## Enable/disable SunshineClouds2 rendering (CompositorEffect.enabled).
## Called when weather or sky toggles change.
func _set_clouds_enabled(on: bool) -> void:
	var res: Resource = _get_clouds_resource()
	if res != null:
		res.set("enabled", on)


## Notify weather_controls that sky visibility changed.
## Called by environment_controls so clouds enable/disable tracks sky state.
func on_sky_visibility_changed(sky_visible: bool) -> void:
	_set_clouds_enabled(weather_enabled or sky_visible)


## Write a single SunshineClouds2 resource parameter. Silently no-ops if
## the plugin isn't loaded or the driver hasn't wired a resource yet.
func _set_cloud_param(name: String, value: Variant) -> void:
	var res: Resource = _get_clouds_resource()
	if res != null:
		res.set(name, value)


## Fetch the live SunshineClouds2 clouds_resource, or null if unavailable.
func _get_clouds_resource() -> Resource:
	if _sunshine_driver == null or not is_instance_valid(_sunshine_driver):
		return null
	return _sunshine_driver.get("clouds_resource") as Resource


## Handle time-of-day slider change
func on_time_of_day_changed(value: float) -> void:
	WeatherManager.set_game_hour(value)
	_update_time_label()


## Handle time scale slider change
func on_time_scale_changed(value: float) -> void:
	WeatherManager.set_time_scale(value)


## Handle weather type override dropdown.
## index 0 = "Auto" (region-based), index 1+ = locked weather type.
## Sets the weather AND applies cloud preset values + syncs sliders.
func on_weather_type_changed(index: int) -> void:
	if index <= 0:
		WeatherManager.auto_weather = true
		Log.info("weather", "Weather set to auto")
	else:
		WeatherManager.auto_weather = false
		WeatherManager.set_weather(index - 1)
	# Ensure the weather system is on — a manual pick implies intent to see it.
	if not weather_enabled:
		on_weather_toggled(true)
		if _panels and _panels.weather_enabled_toggle:
			_panels.weather_enabled_toggle.set_pressed_no_signal(true)
	# Apply cloud preset from the new weather type and sync sliders.
	# User can then tweak; re-picking a preset resets to weather defaults.
	_apply_cloud_preset_from_weather()


## Apply cloud preset values from the current weather and sync sliders.
## Called on weather type change. Sets cloud params on the resource AND
## updates slider positions so the user sees what the preset produced.
func _apply_cloud_preset_from_weather() -> void:
	var result: WeatherTypes.WeatherResult = WeatherManager.get_weather_result()
	var preset: Dictionary = WeatherRenderer.get_cloud_preset_for_coverage(result.cloud_coverage)
	# Apply to SunshineClouds2 resource
	_set_cloud_param("clouds_coverage", preset["coverage"])
	_set_cloud_param("clouds_density", preset["density"])
	_set_cloud_param("clouds_sharpness", preset["sharpness"])
	# Sync sliders to reflect preset values (no-signal to avoid re-triggering callbacks)
	if _panels:
		if _panels.cloud_coverage_slider:
			_panels.cloud_coverage_slider.set_value_no_signal(preset["coverage"])
		if _panels.cloud_density_slider:
			_panels.cloud_density_slider.set_value_no_signal(preset["density"])
		if _panels.cloud_sharpness_slider:
			_panels.cloud_sharpness_slider.set_value_no_signal(preset["sharpness"])


## Handle time pause toggle
func on_time_pause_toggled(paused: bool) -> void:
	WeatherManager.time_paused = paused


## Called each frame by world_explorer to drive rendering.
## WeatherRenderer drives wind per-frame. Cloud coverage/density/sharpness are set
## once on weather type change (via _apply_cloud_preset_from_weather), then the user
## tweaks via sliders. Re-picking a preset resets the sliders.
func process(delta: float) -> void:
	# Always update SkyManager with current game hour (even when weather is off)
	if _env_controls and _env_controls.sky_manager and _env_controls.show_sky:
		_env_controls.sky_manager.update(WeatherManager.game_hour)

	# Sync cloud ambient color from SkyManager's sky state (time-of-day
	# driven — not weather-type driven, so runs regardless of toggle).
	_sync_cloud_ambient()

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


## Sync SunshineClouds2 ambient color from time of day.
## Computes cloud tint from sun altitude so clouds darken at night
## and pick up sunset/sunrise color. Works regardless of show_sky toggle.
func _sync_cloud_ambient() -> void:
	if _sunshine_driver == null or not is_instance_valid(_sunshine_driver):
		return
	var res: Resource = _sunshine_driver.get("clouds_resource")
	if res == null:
		return

	# Prefer SkyManager state if available, otherwise compute from game hour
	var sun_alt: float
	var sun_color: Color
	if _env_controls and _env_controls.sky_manager and _env_controls.show_sky:
		var sky_mgr: SkyManager = _env_controls.sky_manager
		if sky_mgr.has_method("get_sky_state"):
			var state: SkyManager.SkyState = sky_mgr.get_sky_state()
			if state:
				sun_alt = state.sun_direction.y
				sun_color = state.sun_color
			else:
				sun_alt = _sun_alt_from_hour(WeatherManager.game_hour)
				sun_color = _sun_color_from_alt(sun_alt)
		else:
			sun_alt = _sun_alt_from_hour(WeatherManager.game_hour)
			sun_color = _sun_color_from_alt(sun_alt)
	else:
		# Sky is off — derive sun position from game hour directly
		sun_alt = _sun_alt_from_hour(WeatherManager.game_hour)
		sun_color = _sun_color_from_alt(sun_alt)

	# Day factor: 1.0 at noon, 0.0 at night, smooth transition at twilight
	var day_factor: float = clampf(sun_alt * 5.0 + 0.5, 0.0, 1.0)
	# Day ambient: warm white tinted by sun color
	var day_color: Color = sun_color.lerp(Color(0.8, 0.85, 0.9), 0.5)
	# Night ambient: matches OpenMW night ambient (32,35,42)/255 ≈ (0.125,0.137,0.165).
	# Previous value (0.04,0.05,0.1) was ~3x too dark — Morrowind nights are dim, not black.
	var night_color := Color(0.12, 0.13, 0.18)
	# Sunset/sunrise boost: warm orange when sun is near horizon
	var sunset_factor: float = clampf(1.0 - absf(sun_alt) * 8.0, 0.0, 1.0) * 0.6
	var sunset_tint := Color(1.0, 0.6, 0.3)
	# Blend
	var ambient: Color = night_color.lerp(day_color, day_factor)
	ambient = ambient.lerp(sunset_tint, sunset_factor)
	res.set("cloud_ambient_color", ambient)
	# Tint stays neutral — color info goes through cloud_ambient_color only
	res.set("cloud_ambient_tint", Color(1.0, 1.0, 1.0, 1.0))

	# Atmosphere color: controls distant cloud fog tint
	var atmo_day := Color(0.9, 0.92, 1.0)
	var atmo_night := Color(0.15, 0.17, 0.25)  # Brightened to match MW night visibility
	var atmo_sunset := Color(1.0, 0.55, 0.25)
	var atmo: Color = atmo_night.lerp(atmo_day, day_factor)
	atmo = atmo.lerp(atmo_sunset, sunset_factor)
	res.set("atmosphere_color", atmo)

	# Sync fog light color with time of day — SunshineClouds2 samples this via
	# sampled_environment_fog_color. If left at the bright default, clouds stay white at night.
	if _env_controls:
		var active_env: Environment = _env_controls.get_active_environment()
		if active_env:
			var fog_day := Color(0.8, 0.85, 0.9)
			var fog_night := Color(0.12, 0.13, 0.2)  # Brightened to match MW night ambient
			var fog_sunset := Color(0.9, 0.6, 0.35)
			active_env.fog_light_color = fog_night.lerp(fog_day, day_factor).lerp(fog_sunset, sunset_factor)

	# Sync fallback directional light when sky is off — otherwise it stays constant
	# white and the compute shader's direct lighting term drowns out the ambient color
	if _env_controls and not _env_controls.show_sky:
		var fallback: DirectionalLight3D = _env_controls.get_fallback_light()
		if fallback:
			fallback.light_color = sun_color
			# Energy: bright at noon, zero below horizon
			fallback.light_energy = clampf(sun_alt * 1.2, 0.05, 1.2)


## Compute sun altitude (Y component of direction) from game hour.
## Approximation: sun rises at 6, peaks at 12, sets at 18. Negative at night.
static func _sun_alt_from_hour(hour: float) -> float:
	# Normalize hour to 0-24 range, then compute altitude as sinusoid:
	# Peak at 12h (noon), trough at 0h (midnight)
	var normalized: float = fmod(hour, 24.0)
	if normalized < 0.0:
		normalized += 24.0
	# Map 0-24h to angle: noon=PI/2, midnight=-PI/2
	var angle: float = (normalized - 6.0) / 12.0 * PI
	return sin(angle)


## Compute approximate sun color from altitude (warm at horizon, white at zenith).
static func _sun_color_from_alt(alt: float) -> Color:
	var t: float = clampf(alt, 0.0, 1.0)
	return Color(1.0, lerpf(0.7, 0.98, t), lerpf(0.4, 0.95, t))


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
