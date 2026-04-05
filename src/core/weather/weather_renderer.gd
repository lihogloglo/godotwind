## Weather Renderer — Drives fog, sky, and clouds from WeatherResult
##
## Applies interpolated weather state to all visual systems:
##   - Depth fog (density, color, height, sun scatter, aerial perspective)
##   - Volumetric fog (density, albedo, anisotropy, length — god rays)
##   - Height fog (pools at sea level / valleys)
##   - Sun volumetric energy (god ray brightness)
##   - SkyManager atmosphere (turbidity, Mie, cloud coverage)
##   - SunshineClouds2 (wind speed/direction at 4 detail scales)
##   - Fallback Environment + DirectionalLight when sky is off
##
## Callbacks:
##   get_sky_manager: -> SkyManager (custom sky system)
##   get_environment: -> Environment
##   get_light: -> DirectionalLight3D (fallback only)
##   get_sunshine_driver: -> Node (SunshineCloudsDriverGD or null)
##   log: (String) -> void
class_name WeatherRenderer
extends RefCounted


var _cb: Dictionary = {}
var _active: bool = false

## User-adjustable fog density multiplier (1.0 = Morrowind default)
var fog_density_multiplier: float = 1.0


func _init(callbacks: Dictionary) -> void:
	_cb = callbacks


## Apply a WeatherResult to the scene
func apply(result: WeatherTypes.WeatherResult) -> void:
	if not _active:
		return

	var sky_mgr: Node = _get_sky_manager()
	var env: Environment = _get_environment()

	# SkyManager path — drives atmosphere params directly
	if sky_mgr:
		_apply_sky(sky_mgr, result)
	else:
		# Fallback path — drive DirectionalLight for sun position/color
		_apply_fallback_light(result)

	# Fog systems — always drive via Environment regardless of sky state
	if env:
		_apply_depth_fog(env, result)
		_apply_volumetric_fog(env, result)

	# Sun volumetric energy — drives god ray brightness on active sun
	_apply_sun_volumetric_energy(result)

	# SunshineClouds2 wind — always drive when active
	var driver: Node = _get_sunshine_driver()
	if driver:
		_apply_sunshine_clouds(driver, result)


## Enable/disable weather rendering
func set_active(active: bool) -> void:
	_active = active
	_log("Weather rendering %s" % ("enabled" if active else "disabled"))


func is_active() -> bool:
	return _active


#region Depth Fog — Exponential distance fog + height fog + sun scatter

func _apply_depth_fog(env: Environment, result: WeatherTypes.WeatherResult) -> void:
	if not env.fog_enabled:
		return

	# Base density from weather, multiplied by storm_fog_multiplier and user slider
	var density: float = result.depth_fog_density * result.storm_fog_multiplier * fog_density_multiplier
	env.fog_density = density
	env.fog_light_color = result.fog_color

	# Height fog — pools at sea level and in valleys
	env.fog_height = result.fog_height
	env.fog_height_density = result.fog_height_density * fog_density_multiplier

	# Sun inscattering and aerial perspective
	env.fog_sun_scatter = result.fog_sun_scatter
	env.fog_aerial_perspective = result.fog_aerial_perspective
	env.fog_sky_affect = result.fog_sky_affect

#endregion


#region Volumetric Fog — Froxel-based scattering (god rays)

func _apply_volumetric_fog(env: Environment, result: WeatherTypes.WeatherResult) -> void:
	if not env.volumetric_fog_enabled:
		return

	# Density from weather, scaled by storm multiplier and user slider
	var density: float = result.volumetric_density * result.storm_fog_multiplier * fog_density_multiplier
	env.volumetric_fog_density = density

	# Color tint (ash=brown, blight=red, blizzard=white, clear=neutral)
	env.volumetric_fog_albedo = result.volumetric_albedo

	# Anisotropy — high for clear (sharp god rays), low for storms (diffuse)
	env.volumetric_fog_anisotropy = result.volumetric_anisotropy

	# Ray march distance — shorter in storms (nothing beyond), longer on clear days
	env.volumetric_fog_length = result.volumetric_length

	# Sky tinting
	env.volumetric_fog_sky_affect = result.volumetric_sky_affect

	# Thunder flash — briefly spike volumetric emission for lightning illumination
	if result.thunder_flash > 0.0:
		var flash_color: Color = Color(0.8, 0.85, 1.0) * result.thunder_flash * 0.5
		env.volumetric_fog_emission = flash_color
	else:
		env.volumetric_fog_emission = Color.BLACK

#endregion


#region Sun Volumetric Energy — God ray brightness

func _apply_sun_volumetric_energy(result: WeatherTypes.WeatherResult) -> void:
	var energy: float = result.sun_volumetric_energy

	# Thunder flash adds temporary burst of volumetric light
	if result.thunder_flash > 0.0:
		energy += result.thunder_flash * 8.0

	# Try SkyManager's sun first
	var sky_mgr: Node = _get_sky_manager()
	if sky_mgr and sky_mgr.has_method("get_sun_light"):
		var sun: DirectionalLight3D = sky_mgr.get_sun_light()
		if sun:
			sun.light_volumetric_fog_energy = energy
			return

	# Fallback light
	var light: DirectionalLight3D = _get_light()
	if light:
		light.light_volumetric_fog_energy = energy

#endregion


#region SkyManager Path — Typed atmosphere parameters

func _apply_sky(sky_mgr: Node, result: WeatherTypes.WeatherResult) -> void:
	# Turbidity: clear=2, hazy=5, storm=8-10
	var storm_t: float = clampf(result.storm_fog_multiplier - 1.0, 0.0, 1.0)
	sky_mgr.atmosphere.turbidity = lerpf(2.0, 10.0, storm_t)

	# Mie coefficient: higher in storms (more aerosols)
	sky_mgr.atmosphere.mie_coefficient = lerpf(21e-6, 50e-6, storm_t)

	# Cloud coverage for sky darkening
	sky_mgr.cloud_coverage = result.cloud_coverage

	# Wind
	sky_mgr.wind_speed = result.wind_speed
	if result.storm_direction.length_squared() > 0.01:
		sky_mgr.wind_direction = rad_to_deg(atan2(result.storm_direction.x, result.storm_direction.z))


	# Thunder flash — spike ambient energy, smooth decay back to 1.0
	var env: Environment = sky_mgr.get_environment()
	if env:
		if result.thunder_flash > 0.0:
			env.ambient_light_energy = 1.0 + result.thunder_flash * 3.0
		elif env.ambient_light_energy > 1.01:
			env.ambient_light_energy = lerpf(env.ambient_light_energy, 1.0, 0.15)

#endregion


#region Fallback Path — DirectionalLight when sky is off

func _apply_fallback_light(result: WeatherTypes.WeatherResult) -> void:
	var env: Environment = _get_environment()
	if env:
		# Thunder flash — set absolute value to avoid per-frame accumulation
		if result.thunder_flash > 0.0:
			env.ambient_light_energy = 1.0 + result.thunder_flash * 2.0
		else:
			env.ambient_light_energy = 1.0

	var light: DirectionalLight3D = _get_light()
	if not light:
		return

	light.light_color = result.sun_color
	light.light_energy = _get_fallback_sun_energy(result)

	# Thunder flash
	if result.thunder_flash > 0.0:
		light.light_energy += result.thunder_flash * 3.0

	# Simple sun arc (east to west) — only for fallback, SkyManager does this properly
	var hour: float = result.game_hour
	var sun_progress: float = (hour - WeatherData.SUNRISE_TIME) / (WeatherData.SUNSET_TIME - WeatherData.SUNRISE_TIME)
	var elevation: float = sin(sun_progress * PI) * 60.0
	if hour < WeatherData.SUNRISE_TIME or hour > WeatherData.SUNSET_TIME:
		elevation = -10.0
	var azimuth: float = lerpf(90.0, 270.0, sun_progress)
	light.rotation_degrees = Vector3(-elevation, -azimuth, 0.0)


func _get_fallback_sun_energy(result: WeatherTypes.WeatherResult) -> float:
	var hour: float = result.game_hour
	if hour < WeatherData.SUNRISE_TIME or hour > WeatherData.SUNSET_TIME:
		return 0.05
	var noon: float = (WeatherData.SUNRISE_TIME + WeatherData.SUNSET_TIME) * 0.5
	var dist_from_noon: float = absf(hour - noon)
	var half_day: float = noon - WeatherData.SUNRISE_TIME
	var t: float = 1.0 - clampf(dist_from_noon / half_day, 0.0, 1.0)
	var base_energy: float = lerpf(0.3, 1.2, t)
	var cloud_atten: float = 1.0 - result.cloud_coverage * 0.6
	return base_energy * cloud_atten

#endregion


#region SunshineClouds2

func _apply_sunshine_clouds(driver: Node, result: WeatherTypes.WeatherResult) -> void:
	# Cloud coverage driven by WeatherControls._update_cloud_coverage() — not here.
	# Wind direction on the driver
	if result.wind_speed > 0.01:
		var wind_dir: Vector3 = result.storm_direction if result.storm_direction.length_squared() > 0.01 else Vector3(1.0, 0.0, 1.0).normalized()
		driver.wind_direction = wind_dir
		driver.small_structures_wind_speed = result.wind_speed * 30.0
		driver.medium_structures_wind_speed = result.wind_speed * 100.0
		driver.large_structures_wind_speed = result.wind_speed * 250.0
		driver.extra_large_structures_wind_speed = result.wind_speed * 350.0

#endregion


#region Callbacks

func _get_sky_manager() -> Node:
	if _cb.has("get_sky_manager"):
		return _cb["get_sky_manager"].call()
	return null


func _get_environment() -> Environment:
	# Prefer SkyManager's environment if available
	var sky_mgr: Node = _get_sky_manager()
	if sky_mgr and sky_mgr.has_method("get_environment"):
		var env: Environment = sky_mgr.get_environment()
		if env:
			return env
	if _cb.has("get_environment"):
		return _cb["get_environment"].call()
	return null


func _get_light() -> DirectionalLight3D:
	if _cb.has("get_light"):
		return _cb["get_light"].call()
	return null


func _get_sunshine_driver() -> Node:
	if _cb.has("get_sunshine_driver"):
		return _cb["get_sunshine_driver"].call()
	return null


func _log(msg: String) -> void:
	if _cb.has("log"):
		_cb["log"].call(msg)
	else:
		Log.info("weather", msg)

#endregion
