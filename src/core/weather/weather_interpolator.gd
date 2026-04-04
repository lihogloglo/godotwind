## Weather Interpolator — Pure logic for time-of-day and weather-to-weather blending
##
## Stateless class. All methods are static.
## Takes weather parameters + game hour, outputs interpolated WeatherResult.
##
## Time-of-day interpolation uses Morrowind's 4-phase system:
##   night -> sunrise -> day -> sunset -> night
## Each color category (sky, fog, ambient, sun) has independent transition windows.
class_name WeatherInterpolator
extends RefCounted



## Interpolate a TimeOfDayColor to a single Color based on game hour and transition window.
## transition: [pre_sunrise, post_sunrise, pre_sunset, post_sunset] offsets in hours.
static func interpolate_time_of_day(tod: WeatherTypes.TimeOfDayColor, hour: float, transition: Array[float]) -> Color:
	var blend: Dictionary = _get_time_blend(hour, transition)
	var phase: int = blend["phase"]
	var factor: float = blend["factor"]

	match phase:
		0: # night (full)
			return tod.night
		1: # night -> sunrise
			return tod.night.lerp(tod.sunrise, factor)
		2: # sunrise -> day
			return tod.sunrise.lerp(tod.day, factor)
		3: # day (full)
			return tod.day
		4: # day -> sunset
			return tod.day.lerp(tod.sunset, factor)
		5: # sunset -> night
			return tod.sunset.lerp(tod.night, factor)
		_:
			return tod.day


## Interpolate between two weather types with time-of-day and transition factor.
## factor: 0.0 = fully weather_a, 1.0 = fully weather_b.
static func interpolate_weather(params_a: WeatherTypes.WeatherParams, params_b: WeatherTypes.WeatherParams,
		factor: float, hour: float) -> WeatherTypes.WeatherResult:
	var result := WeatherTypes.WeatherResult.new()

	# Interpolate colors: first apply time-of-day to each weather, then blend between them
	result.sky_color = _blend_tod_color(params_a.sky_color, params_b.sky_color, factor, hour, WeatherData.SKY_TRANSITION)
	result.fog_color = _blend_tod_color(params_a.fog_color, params_b.fog_color, factor, hour, WeatherData.FOG_TRANSITION)
	result.ambient_color = _blend_tod_color(params_a.ambient_color, params_b.ambient_color, factor, hour, WeatherData.AMBIENT_TRANSITION)
	result.sun_color = _blend_tod_color(params_a.sun_color, params_b.sun_color, factor, hour, WeatherData.SUN_TRANSITION)

	# Sun disc sunset color (not time-of-day dependent)
	result.sun_disc_sunset_color = params_a.sun_disc_sunset_color.lerp(params_b.sun_disc_sunset_color, factor)

	# Fog depth: blend day/night based on hour, then lerp between weathers
	var is_night_factor: float = _get_night_factor(hour)
	var fog_a: float = lerpf(params_a.fog_depth_day, params_a.fog_depth_night, is_night_factor)
	var fog_b: float = lerpf(params_b.fog_depth_day, params_b.fog_depth_night, is_night_factor)
	result.fog_depth = lerpf(fog_a, fog_b, factor)

	# Height fog: blend day/night then between weathers
	result.fog_height = lerpf(params_a.fog_height, params_b.fog_height, factor)
	var hd_a: float = lerpf(params_a.fog_height_density_day, params_a.fog_height_density_night, is_night_factor)
	var hd_b: float = lerpf(params_b.fog_height_density_day, params_b.fog_height_density_night, is_night_factor)
	result.fog_height_density = lerpf(hd_a, hd_b, factor)

	# Depth fog parameters
	var dd_a: float = lerpf(params_a.depth_fog_density_day, params_a.depth_fog_density_night, is_night_factor)
	var dd_b: float = lerpf(params_b.depth_fog_density_day, params_b.depth_fog_density_night, is_night_factor)
	result.depth_fog_density = lerpf(dd_a, dd_b, factor)
	result.fog_sun_scatter = lerpf(params_a.fog_sun_scatter, params_b.fog_sun_scatter, factor)
	result.fog_aerial_perspective = lerpf(params_a.fog_aerial_perspective, params_b.fog_aerial_perspective, factor)
	result.fog_sky_affect = lerpf(params_a.fog_sky_affect, params_b.fog_sky_affect, factor)

	# Volumetric fog
	var vd_a: float = lerpf(params_a.volumetric_density_day, params_a.volumetric_density_night, is_night_factor)
	var vd_b: float = lerpf(params_b.volumetric_density_day, params_b.volumetric_density_night, is_night_factor)
	result.volumetric_density = lerpf(vd_a, vd_b, factor)
	result.volumetric_albedo = params_a.volumetric_albedo.lerp(params_b.volumetric_albedo, factor)
	result.volumetric_anisotropy = lerpf(params_a.volumetric_anisotropy, params_b.volumetric_anisotropy, factor)
	result.volumetric_length = lerpf(params_a.volumetric_length, params_b.volumetric_length, factor)
	result.volumetric_sky_affect = lerpf(params_a.volumetric_sky_affect, params_b.volumetric_sky_affect, factor)

	# Sun volumetric energy (god ray brightness)
	result.sun_volumetric_energy = lerpf(params_a.sun_volumetric_energy, params_b.sun_volumetric_energy, factor)

	# Scalar blends
	result.wind_speed = lerpf(params_a.wind_speed, params_b.wind_speed, factor)
	result.cloud_speed = lerpf(params_a.cloud_speed, params_b.cloud_speed, factor)
	result.cloud_coverage = lerpf(params_a.cloud_coverage, params_b.cloud_coverage, factor)
	result.glare_view = lerpf(params_a.glare_view, params_b.glare_view, factor)

	# Storm fog multiplier
	result.storm_fog_multiplier = lerpf(params_a.storm_fog_multiplier, params_b.storm_fog_multiplier, factor)
	result.storm_direction = params_a.storm_direction.lerp(params_b.storm_direction, factor)

	# Precipitation — only active past threshold during transition
	_apply_precipitation(result, params_a, params_b, factor)

	# Cloud texture crossfade
	result.cloud_texture_current = params_a.cloud_texture
	result.cloud_texture_next = params_b.cloud_texture
	result.cloud_blend_factor = clampf(factor / maxf(params_b.clouds_max_percent, 0.01), 0.0, 1.0)

	# Sound volumes
	if params_a.ambient_sound != "":
		result.ambient_sound_id = params_a.ambient_sound
		result.ambient_sound_volume = 1.0 - factor
	if params_b.ambient_sound != "":
		result.ambient_sound_id = params_b.ambient_sound
		result.ambient_sound_volume = factor
	if params_a.rain_sound != "":
		result.rain_sound_id = params_a.rain_sound
		result.rain_sound_volume = result.rain_intensity * (1.0 - factor)
	if params_b.rain_sound != "":
		result.rain_sound_id = params_b.rain_sound
		result.rain_sound_volume = result.rain_intensity * factor

	# Weather type info
	result.transition_factor = factor

	return result


## Get time blend info: which phase we're in and how far through it.
## Returns {phase: int, factor: float} where factor is 0-1 within the phase.
##
## Phases: 0=night, 1=night->sunrise, 2=sunrise->day, 3=day, 4=day->sunset, 5=sunset->night
static func _get_time_blend(hour: float, transition: Array[float]) -> Dictionary:
	var sunrise_start: float = WeatherData.SUNRISE_TIME - transition[0]
	var sunrise_end: float = WeatherData.SUNRISE_TIME + transition[1]
	var sunset_start: float = WeatherData.SUNSET_TIME - transition[2]
	var sunset_end: float = WeatherData.SUNSET_TIME + transition[3]

	if hour < sunrise_start:
		return {"phase": 0, "factor": 0.0}
	elif hour < sunrise_start + (sunrise_end - sunrise_start) * 0.5:
		# night -> sunrise
		var t: float = (hour - sunrise_start) / maxf(sunrise_end - sunrise_start, 0.01) * 2.0
		return {"phase": 1, "factor": clampf(t, 0.0, 1.0)}
	elif hour < sunrise_end:
		# sunrise -> day
		var t: float = (hour - (sunrise_start + sunrise_end) * 0.5) / maxf((sunrise_end - sunrise_start) * 0.5, 0.01)
		return {"phase": 2, "factor": clampf(t, 0.0, 1.0)}
	elif hour < sunset_start:
		return {"phase": 3, "factor": 0.0}
	elif hour < sunset_start + (sunset_end - sunset_start) * 0.5:
		# day -> sunset
		var t: float = (hour - sunset_start) / maxf(sunset_end - sunset_start, 0.01) * 2.0
		return {"phase": 4, "factor": clampf(t, 0.0, 1.0)}
	elif hour < sunset_end:
		# sunset -> night
		var t: float = (hour - (sunset_start + sunset_end) * 0.5) / maxf((sunset_end - sunset_start) * 0.5, 0.01)
		return {"phase": 5, "factor": clampf(t, 0.0, 1.0)}
	else:
		return {"phase": 0, "factor": 0.0}


## Blend a TimeOfDayColor between two weather types.
static func _blend_tod_color(tod_a: WeatherTypes.TimeOfDayColor, tod_b: WeatherTypes.TimeOfDayColor,
		factor: float, hour: float, transition: Array[float]) -> Color:
	var color_a: Color = interpolate_time_of_day(tod_a, hour, transition)
	var color_b: Color = interpolate_time_of_day(tod_b, hour, transition)
	return color_a.lerp(color_b, factor)


## Get night factor (0 = full day, 1 = full night) for fog depth blending.
static func _get_night_factor(hour: float) -> float:
	if hour >= WeatherData.SUNRISE_TIME and hour <= WeatherData.SUNSET_TIME:
		# During day — compute how close to sunrise/sunset edges
		var day_mid: float = (WeatherData.SUNRISE_TIME + WeatherData.SUNSET_TIME) * 0.5
		if hour < day_mid:
			# Morning: fade from night to day
			var t: float = (hour - WeatherData.SUNRISE_TIME) / maxf(WeatherData.SUNRISE_DURATION, 0.01)
			return clampf(1.0 - t, 0.0, 1.0)
		else:
			# Evening: fade from day to night
			var t: float = (WeatherData.SUNSET_TIME - hour) / maxf(WeatherData.SUNSET_DURATION, 0.01)
			return clampf(1.0 - t, 0.0, 1.0)
	return 1.0  # Night


## Apply precipitation intensities based on weather params and transition factor.
static func _apply_precipitation(result: WeatherTypes.WeatherResult, params_a: WeatherTypes.WeatherParams,
		params_b: WeatherTypes.WeatherParams, factor: float) -> void:
	# Outgoing weather precipitation fades out
	if params_a.has_precipitation:
		var a_intensity: float = 1.0 - clampf(factor / maxf(params_a.precip_threshold, 0.01), 0.0, 1.0)
		if not params_a.is_storm:
			if params_a.particle_speed > 200.0:
				result.rain_intensity = a_intensity
			else:
				result.snow_intensity = a_intensity
		else:
			result.storm_intensity = a_intensity

	# Incoming weather precipitation fades in (only past its threshold)
	if params_b.has_precipitation and factor >= params_b.precip_threshold:
		var b_intensity: float = clampf((factor - params_b.precip_threshold) / maxf(1.0 - params_b.precip_threshold, 0.01), 0.0, 1.0)
		if not params_b.is_storm:
			if params_b.particle_speed > 200.0:
				result.rain_intensity = maxf(result.rain_intensity, b_intensity)
			else:
				result.snow_intensity = maxf(result.snow_intensity, b_intensity)
		else:
			result.storm_intensity = maxf(result.storm_intensity, b_intensity)
			result.storm_direction = params_b.storm_direction
