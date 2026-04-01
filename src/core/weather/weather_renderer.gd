## Weather Renderer — Drives Sky3D and SunshineClouds2 from WeatherResult
##
## Primary path: drives Sky3D's SkyDome parameters (fog, clouds, wind, atmosphere tints).
## Fallback path: when Sky3D is off, drives Godot Environment fog + DirectionalLight.
## Does NOT reimplement sun position, ambient light, or sky colors — Sky3D owns those.
##
## Callbacks:
##   get_sky3d: -> Node (Sky3D instance or null)
##   get_environment: -> Environment
##   get_light: -> DirectionalLight3D (fallback only)
##   get_sunshine_driver: -> Node (SunshineCloudsDriverGD or null)
##   get_env_controls: -> EnvironmentControls
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

	var sky3d: Node = _get_sky3d()
	if sky3d and sky3d.get("sky3d_enabled"):
		_apply_sky3d(sky3d, result)
	else:
		_apply_fallback(result)

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


#region Sky3D Path — Primary

func _apply_sky3d(sky3d: Node, result: WeatherTypes.WeatherResult) -> void:
	var sky_dome: Node = sky3d.get("sky")
	if sky_dome == null:
		return

	# Fog — drive Sky3D's atmospheric fog parameters
	# fog_density: base atmospheric density, scaled by weather type
	# fog_rayleigh_depth: Rayleigh scattering depth (higher = more atmospheric color in fog)
	var base_fog: float = result.fog_depth * 0.0004 * result.storm_fog_multiplier
	sky_dome.set("fog_density", clampf(base_fog, 0.0001, 0.01))
	sky_dome.set("fog_rayleigh_depth", lerpf(0.05, 0.5, clampf(result.fog_depth / 3.5, 0.0, 1.0)))

	# 2D Clouds — drive Sky3D's cumulus coverage (0-1)
	sky_dome.set("cumulus_coverage", clampf(result.cloud_coverage * 0.7 + 0.1, 0.0, 1.0))

	# Wind — drive Sky3D's wind system
	sky3d.set("wind_speed", result.wind_speed * 20.0)

	# Thunder flash — briefly spike ambient energy
	if result.thunder_flash > 0.0:
		sky3d.set("ambient_energy", 1.0 + result.thunder_flash * 3.0)
	else:
		# Don't fight Sky3D's own ambient — only override during thunder
		pass

#endregion


#region Fallback Path — When Sky3D is off

func _apply_fallback(result: WeatherTypes.WeatherResult) -> void:
	var env: Environment = _get_environment()
	if env:
		# Fog — only drive density/color when depth fog is already enabled
		if env.fog_enabled:
			var base_density: float = result.fog_depth * 0.003
			env.fog_density = base_density * result.storm_fog_multiplier
			env.fog_light_color = result.fog_color

		# Thunder flash — set absolute value to avoid per-frame accumulation
		if result.thunder_flash > 0.0:
			env.ambient_light_energy = 1.0 + result.thunder_flash * 2.0
		else:
			env.ambient_light_energy = 1.0

	# Fallback light (sun position + energy) — only when Sky3D is off
	var light: DirectionalLight3D = _get_light()
	if light:
		_apply_fallback_light(light, result)


func _apply_fallback_light(light: DirectionalLight3D, result: WeatherTypes.WeatherResult) -> void:
	light.light_color = result.sun_color
	light.light_energy = _get_fallback_sun_energy(result)

	# Thunder flash
	if result.thunder_flash > 0.0:
		light.light_energy += result.thunder_flash * 3.0

	# Simple sun arc (east to west) — only for fallback, Sky3D does this properly
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

func _get_sky3d() -> Node:
	if _cb.has("get_sky3d"):
		return _cb["get_sky3d"].call()
	return null


func _get_environment() -> Environment:
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
