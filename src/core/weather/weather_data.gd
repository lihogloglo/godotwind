## Weather Data — Default Morrowind weather parameters
##
## All values ported from OpenMW openmw.cfg fallback defaults, which match
## the original Morrowind.ini. Colors are RGB 0-255 for 4 time-of-day phases:
## [sunrise, day, sunset, night].
##
## This is a static data class — no instances needed.
## Usage: var params := WeatherData.get_weather_params(WeatherTypes.Type.CLEAR)
class_name WeatherData
extends RefCounted


## Global timing constants (game hours)
const SUNRISE_TIME: float = 6.0
const SUNSET_TIME: float = 18.0
const SUNRISE_DURATION: float = 2.0
const SUNSET_DURATION: float = 2.0

## Per-category transition windows (hours before/after sunrise/sunset)
## Format: [pre_sunrise, post_sunrise, pre_sunset, post_sunset]
const SKY_TRANSITION: Array[float] = [0.5, 1.0, 1.5, 0.5]
const AMBIENT_TRANSITION: Array[float] = [0.5, 2.0, 1.0, 1.25]
const FOG_TRANSITION: Array[float] = [0.5, 1.0, 2.0, 1.0]
const SUN_TRANSITION: Array[float] = [0.0, 0.0, 1.0, 1.25]

## Weather change interval (game hours between weather rolls)
const WEATHER_UPDATE_HOURS: float = 20.0

## Global precipitation gravity (fall speed)
const PRECIP_GRAVITY: float = 575.0

## Storm wind speed threshold (MW: fStromWindSpeed)
const STORM_WIND_THRESHOLD: float = 0.5

## Red Mountain position for storm direction (MW coordinates)
## Converted to Godot: Vector3(mw.x, mw.z, -mw.y) / 128
const RED_MOUNTAIN_GODOT: Vector3 = Vector3(195.3, 0.0, -546.9)


## Build all 10 weather type parameter sets
static func get_all_weather_params() -> Array:
	var params: Array = []
	params.resize(WeatherTypes.Type.COUNT)
	for i: int in WeatherTypes.Type.COUNT:
		params[i] = get_weather_params(i)
	return params


## Get parameters for a specific weather type
static func get_weather_params(type: int) -> WeatherTypes.WeatherParams:
	match type:
		WeatherTypes.Type.CLEAR: return _clear()
		WeatherTypes.Type.CLOUDY: return _cloudy()
		WeatherTypes.Type.FOGGY: return _foggy()
		WeatherTypes.Type.OVERCAST: return _overcast()
		WeatherTypes.Type.RAIN: return _rain()
		WeatherTypes.Type.THUNDERSTORM: return _thunderstorm()
		WeatherTypes.Type.ASHSTORM: return _ashstorm()
		WeatherTypes.Type.BLIGHT: return _blight()
		WeatherTypes.Type.SNOW: return _snow()
		WeatherTypes.Type.BLIZZARD: return _blizzard()
		_:
			Log.warn("weather", "Unknown weather type %d, falling back to Clear" % type)
			return _clear()


## Extract weather probabilities from a RegionRecord as an array[10]
static func get_region_probabilities(region: RegionRecord) -> Array[int]:
	return [
		region.weather_clear, region.weather_cloudy, region.weather_foggy,
		region.weather_overcast, region.weather_rain, region.weather_thunder,
		region.weather_ash, region.weather_blight, region.weather_snow,
		region.weather_blizzard,
	]


#region Weather Definitions

static func _clear() -> WeatherTypes.WeatherParams:
	var p := WeatherTypes.WeatherParams.new()
	p.sky_color = WeatherTypes.TimeOfDayColor.from_rgb([117,141,164], [95,135,203], [56,89,129], [9,10,11])
	p.fog_color = WeatherTypes.TimeOfDayColor.from_rgb([255,189,157], [206,227,255], [255,189,157], [9,10,11])
	p.ambient_color = WeatherTypes.TimeOfDayColor.from_rgb([47,66,96], [137,140,160], [68,75,96], [32,35,42])
	p.sun_color = WeatherTypes.TimeOfDayColor.from_rgb([242,159,119], [255,252,238], [255,114,79], [59,97,176])
	p.sun_disc_sunset_color = Color(1.0, 0.74, 0.62)
	p.fog_depth_day = 0.69
	p.fog_depth_night = 0.69
	# Height fog — subtle mist at sea level
	p.fog_height = 0.0
	p.fog_height_density_day = 0.0012
	p.fog_height_density_night = 0.003
	# Depth fog — light haze, good sun scatter for warm feel
	p.depth_fog_density_day = 0.00006
	p.depth_fog_density_night = 0.00012
	p.fog_sun_scatter = 0.4
	p.fog_aerial_perspective = 0.7
	p.fog_sky_affect = 0.15
	# Volumetric — light, visible god rays
	p.volumetric_density_day = 0.0012
	p.volumetric_density_night = 0.002
	p.volumetric_albedo = Color(0.92, 0.92, 0.97)
	p.volumetric_anisotropy = 0.75
	p.volumetric_length = 700.0
	p.volumetric_sky_affect = 0.15
	p.sun_volumetric_energy = 6.0
	p.wind_speed = 0.1
	p.cloud_speed = 1.25
	p.cloud_coverage = 0.2  # Some clouds even on clear days
	p.glare_view = 1.0
	p.cloud_texture = "Tx_Sky_Clear.dds"
	p.transition_delta = 0.015
	p.clouds_max_percent = 1.0
	return p

static func _cloudy() -> WeatherTypes.WeatherParams:
	var p := WeatherTypes.WeatherParams.new()
	p.sky_color = WeatherTypes.TimeOfDayColor.from_rgb([117,141,164], [95,135,203], [56,89,129], [9,10,11])
	p.fog_color = WeatherTypes.TimeOfDayColor.from_rgb([255,189,157], [206,227,255], [255,189,157], [9,10,11])
	p.ambient_color = WeatherTypes.TimeOfDayColor.from_rgb([47,66,96], [137,140,160], [68,75,96], [32,35,42])
	p.sun_color = WeatherTypes.TimeOfDayColor.from_rgb([242,159,119], [255,252,238], [255,114,79], [59,97,176])
	p.sun_disc_sunset_color = Color(1.0, 0.74, 0.62)
	p.fog_depth_day = 0.72
	p.fog_depth_night = 0.72
	# Height fog — slightly more than clear
	p.fog_height = 0.0
	p.fog_height_density_day = 0.0015
	p.fog_height_density_night = 0.0036
	# Depth fog — mild haze, reduced sun scatter (clouds diffuse it)
	p.depth_fog_density_day = 0.00009
	p.depth_fog_density_night = 0.00015
	p.fog_sun_scatter = 0.3
	p.fog_aerial_perspective = 0.65
	p.fog_sky_affect = 0.18
	# Volumetric — slightly denser, still god rays through cloud breaks
	p.volumetric_density_day = 0.0015
	p.volumetric_density_night = 0.0024
	p.volumetric_albedo = Color(0.88, 0.88, 0.93)
	p.volumetric_anisotropy = 0.7
	p.volumetric_length = 650.0
	p.volumetric_sky_affect = 0.18
	p.sun_volumetric_energy = 5.0
	p.wind_speed = 0.2
	p.cloud_speed = 2.0
	p.cloud_coverage = 0.3
	p.glare_view = 1.0
	p.cloud_texture = "Tx_Sky_Cloudy.dds"
	p.transition_delta = 0.015
	p.clouds_max_percent = 1.0
	return p

static func _foggy() -> WeatherTypes.WeatherParams:
	var p := WeatherTypes.WeatherParams.new()
	p.sky_color = WeatherTypes.TimeOfDayColor.from_rgb([117,141,164], [95,135,203], [56,89,129], [9,10,11])
	p.fog_color = WeatherTypes.TimeOfDayColor.from_rgb([255,189,157], [206,227,255], [255,189,157], [9,10,11])
	p.ambient_color = WeatherTypes.TimeOfDayColor.from_rgb([47,66,96], [137,140,160], [68,75,96], [32,35,42])
	p.sun_color = WeatherTypes.TimeOfDayColor.from_rgb([242,159,119], [255,252,238], [255,114,79], [59,97,176])
	p.sun_disc_sunset_color = Color(1.0, 0.74, 0.62)
	p.fog_depth_day = 1.0
	p.fog_depth_night = 1.1
	# Height fog — HEAVY valley fog, pools strongly at sea level
	p.fog_height = 5.0
	p.fog_height_density_day = 0.009
	p.fog_height_density_night = 0.015
	# Depth fog — dense, reduced visibility
	p.depth_fog_density_day = 0.00036
	p.depth_fog_density_night = 0.0006
	p.fog_sun_scatter = 0.15
	p.fog_aerial_perspective = 0.4
	p.fog_sky_affect = 0.25
	# Volumetric — dense but diffuse, NO distinct god rays
	p.volumetric_density_day = 0.0036
	p.volumetric_density_night = 0.0054
	p.volumetric_albedo = Color(0.85, 0.87, 0.9)
	p.volumetric_anisotropy = 0.3
	p.volumetric_length = 400.0
	p.volumetric_sky_affect = 0.25
	p.sun_volumetric_energy = 2.0
	p.wind_speed = 0.0
	p.cloud_speed = 1.25
	p.cloud_coverage = 0.7
	p.glare_view = 0.25
	p.cloud_texture = "Tx_Sky_Foggy.dds"
	p.transition_delta = 0.015
	p.clouds_max_percent = 1.0
	return p

static func _overcast() -> WeatherTypes.WeatherParams:
	var p := WeatherTypes.WeatherParams.new()
	p.sky_color = WeatherTypes.TimeOfDayColor.from_rgb([117,141,164], [95,135,203], [56,89,129], [9,10,11])
	p.fog_color = WeatherTypes.TimeOfDayColor.from_rgb([255,189,157], [206,227,255], [255,189,157], [9,10,11])
	p.ambient_color = WeatherTypes.TimeOfDayColor.from_rgb([47,66,96], [137,140,160], [68,75,96], [32,35,42])
	p.sun_color = WeatherTypes.TimeOfDayColor.from_rgb([242,159,119], [255,252,238], [255,114,79], [59,97,176])
	p.sun_disc_sunset_color = Color(1.0, 0.74, 0.62)
	p.fog_depth_day = 0.7
	p.fog_depth_night = 0.7
	# Height fog — moderate
	p.fog_height = 0.0
	p.fog_height_density_day = 0.0024
	p.fog_height_density_night = 0.0045
	# Depth fog — flat grey haze
	p.depth_fog_density_day = 0.00015
	p.depth_fog_density_night = 0.00021
	p.fog_sun_scatter = 0.1
	p.fog_aerial_perspective = 0.55
	p.fog_sky_affect = 0.2
	# Volumetric — moderate, flat lighting means no god rays
	p.volumetric_density_day = 0.0021
	p.volumetric_density_night = 0.003
	p.volumetric_albedo = Color(0.82, 0.83, 0.87)
	p.volumetric_anisotropy = 0.4
	p.volumetric_length = 500.0
	p.volumetric_sky_affect = 0.2
	p.sun_volumetric_energy = 2.0
	p.wind_speed = 0.2
	p.cloud_speed = 1.5
	p.cloud_coverage = 0.9
	p.glare_view = 0.0
	p.cloud_texture = "Tx_Sky_Overcast.dds"
	p.transition_delta = 0.015
	p.clouds_max_percent = 0.66
	return p

static func _rain() -> WeatherTypes.WeatherParams:
	var p := WeatherTypes.WeatherParams.new()
	p.sky_color = WeatherTypes.TimeOfDayColor.from_rgb([71,74,75], [116,120,122], [73,73,73], [9,10,11])
	p.fog_color = WeatherTypes.TimeOfDayColor.from_rgb([71,74,75], [116,120,122], [73,73,73], [9,10,11])
	p.ambient_color = WeatherTypes.TimeOfDayColor.from_rgb([47,66,96], [105,110,129], [68,75,96], [32,35,42])
	p.sun_color = WeatherTypes.TimeOfDayColor.from_rgb([242,159,119], [220,220,220], [255,114,79], [59,97,176])
	p.sun_disc_sunset_color = Color(1.0, 0.74, 0.62)
	p.fog_depth_day = 0.72
	p.fog_depth_night = 0.72
	# Height fog — rain makes valleys misty
	p.fog_height = 2.0
	p.fog_height_density_day = 0.0036
	p.fog_height_density_night = 0.006
	# Depth fog — grey curtain of rain
	p.depth_fog_density_day = 0.00018
	p.depth_fog_density_night = 0.0003
	p.fog_sun_scatter = 0.1
	p.fog_aerial_perspective = 0.5
	p.fog_sky_affect = 0.2
	# Volumetric — moderate, grey-blue tint
	p.volumetric_density_day = 0.0024
	p.volumetric_density_night = 0.0036
	p.volumetric_albedo = Color(0.75, 0.78, 0.83)
	p.volumetric_anisotropy = 0.5
	p.volumetric_length = 500.0
	p.volumetric_sky_affect = 0.2
	p.sun_volumetric_energy = 3.0
	p.wind_speed = 0.3
	p.cloud_speed = 2.0
	p.cloud_coverage = 1.0
	p.glare_view = 0.0
	p.cloud_texture = "Tx_Sky_Rainy.dds"
	p.transition_delta = 0.015
	p.clouds_max_percent = 0.66
	p.has_precipitation = true
	p.max_particles = 450
	p.particle_size = 600.0
	p.particle_speed = PRECIP_GRAVITY
	p.precip_threshold = 0.6
	p.rain_sound = "Rain"
	return p

static func _thunderstorm() -> WeatherTypes.WeatherParams:
	var p := WeatherTypes.WeatherParams.new()
	p.sky_color = WeatherTypes.TimeOfDayColor.from_rgb([35,36,39], [97,104,115], [35,36,39], [9,10,11])
	p.fog_color = WeatherTypes.TimeOfDayColor.from_rgb([35,36,39], [97,104,115], [35,36,39], [9,10,11])
	p.ambient_color = WeatherTypes.TimeOfDayColor.from_rgb([47,66,96], [100,105,124], [68,75,96], [32,35,42])
	p.sun_color = WeatherTypes.TimeOfDayColor.from_rgb([242,159,119], [200,200,200], [255,114,79], [59,97,176])
	p.sun_disc_sunset_color = Color(1.0, 0.74, 0.62)
	p.fog_depth_day = 0.72
	p.fog_depth_night = 0.72
	# Height fog — thick in valleys
	p.fog_height = 3.0
	p.fog_height_density_day = 0.0045
	p.fog_height_density_night = 0.0075
	# Depth fog — dark, oppressive atmosphere
	p.depth_fog_density_day = 0.0003
	p.depth_fog_density_night = 0.00045
	p.fog_sun_scatter = 0.05
	p.fog_aerial_perspective = 0.4
	p.fog_sky_affect = 0.22
	# Volumetric — dark, thunder flash illuminates the volume
	p.volumetric_density_day = 0.003
	p.volumetric_density_night = 0.0045
	p.volumetric_albedo = Color(0.6, 0.62, 0.68)
	p.volumetric_anisotropy = 0.5
	p.volumetric_length = 450.0
	p.volumetric_sky_affect = 0.22
	p.sun_volumetric_energy = 2.0
	p.wind_speed = 0.5
	p.cloud_speed = 3.0
	p.cloud_coverage = 1.0
	p.glare_view = 0.0
	p.cloud_texture = "Tx_Sky_Thunderstorm.dds"
	p.transition_delta = 0.030
	p.clouds_max_percent = 0.66
	p.has_precipitation = true
	p.max_particles = 650
	p.particle_size = 600.0
	p.particle_speed = PRECIP_GRAVITY
	p.precip_threshold = 0.6
	p.rain_sound = "rain heavy"
	p.thunder_frequency = 0.4
	p.thunder_threshold = 0.6
	p.flash_decrement = 4.0
	return p

static func _ashstorm() -> WeatherTypes.WeatherParams:
	var p := WeatherTypes.WeatherParams.new()
	p.sky_color = WeatherTypes.TimeOfDayColor.from_rgb([91,56,36], [124,82,48], [91,56,36], [9,10,11])
	p.fog_color = WeatherTypes.TimeOfDayColor.from_rgb([91,56,36], [124,82,48], [91,56,36], [9,10,11])
	p.ambient_color = WeatherTypes.TimeOfDayColor.from_rgb([50,45,40], [92,84,76], [50,45,40], [32,35,42])
	p.sun_color = WeatherTypes.TimeOfDayColor.from_rgb([184,115,76], [214,170,130], [184,115,76], [59,97,176])
	p.sun_disc_sunset_color = Color(1.0, 0.74, 0.62)
	p.fog_depth_day = 1.1
	p.fog_depth_night = 1.2
	# Height fog — ash settles in low areas
	p.fog_height = 10.0
	p.fog_height_density_day = 0.006
	p.fog_height_density_night = 0.009
	# Depth fog — thick orange-brown curtain
	p.depth_fog_density_day = 0.0006
	p.depth_fog_density_night = 0.0009
	p.fog_sun_scatter = 0.05
	p.fog_aerial_perspective = 0.25
	p.fog_sky_affect = 0.3
	# Volumetric — warm ash, no god rays
	p.volumetric_density_day = 0.0054
	p.volumetric_density_night = 0.0075
	p.volumetric_albedo = Color(0.55, 0.38, 0.25)
	p.volumetric_anisotropy = 0.2
	p.volumetric_length = 300.0
	p.volumetric_sky_affect = 0.3
	p.sun_volumetric_energy = 1.0
	p.wind_speed = 0.8
	p.cloud_speed = 5.0
	p.cloud_coverage = 1.0
	p.glare_view = 0.0
	p.cloud_texture = "Tx_Sky_Ashstorm.dds"
	p.transition_delta = 0.015
	p.clouds_max_percent = 1.0
	p.is_storm = true
	p.storm_direction = RED_MOUNTAIN_GODOT.normalized()
	p.storm_fog_multiplier = 3.0
	p.ambient_sound = "ashstorm"
	return p

static func _blight() -> WeatherTypes.WeatherParams:
	var p := WeatherTypes.WeatherParams.new()
	p.sky_color = WeatherTypes.TimeOfDayColor.from_rgb([90,35,35], [124,48,48], [90,35,35], [9,10,11])
	p.fog_color = WeatherTypes.TimeOfDayColor.from_rgb([90,35,35], [124,48,48], [90,35,35], [9,10,11])
	p.ambient_color = WeatherTypes.TimeOfDayColor.from_rgb([50,40,40], [92,76,76], [50,40,40], [32,35,42])
	p.sun_color = WeatherTypes.TimeOfDayColor.from_rgb([184,76,76], [214,130,130], [184,76,76], [59,97,176])
	p.sun_disc_sunset_color = Color(1.0, 0.74, 0.62)
	p.fog_depth_day = 1.3
	p.fog_depth_night = 1.4
	# Height fog — diseased red mist fills everything
	p.fog_height = 15.0
	p.fog_height_density_day = 0.0075
	p.fog_height_density_night = 0.012
	# Depth fog — sickly red
	p.depth_fog_density_day = 0.00075
	p.depth_fog_density_night = 0.00105
	p.fog_sun_scatter = 0.03
	p.fog_aerial_perspective = 0.2
	p.fog_sky_affect = 0.32
	# Volumetric — bloody red atmosphere
	p.volumetric_density_day = 0.006
	p.volumetric_density_night = 0.009
	p.volumetric_albedo = Color(0.5, 0.22, 0.22)
	p.volumetric_anisotropy = 0.15
	p.volumetric_length = 250.0
	p.volumetric_sky_affect = 0.32
	p.sun_volumetric_energy = 0.5
	p.wind_speed = 0.9
	p.cloud_speed = 6.0
	p.cloud_coverage = 1.0
	p.glare_view = 0.0
	p.cloud_texture = "Tx_Sky_Blight.dds"
	p.transition_delta = 0.015
	p.clouds_max_percent = 1.0
	p.is_storm = true
	p.storm_direction = RED_MOUNTAIN_GODOT.normalized()
	p.storm_fog_multiplier = 4.0
	p.ambient_sound = "blight"
	return p

static func _snow() -> WeatherTypes.WeatherParams:
	var p := WeatherTypes.WeatherParams.new()
	p.sky_color = WeatherTypes.TimeOfDayColor.from_rgb([117,141,164], [145,160,180], [56,89,129], [9,10,11])
	p.fog_color = WeatherTypes.TimeOfDayColor.from_rgb([210,210,220], [230,233,240], [210,210,220], [9,10,11])
	p.ambient_color = WeatherTypes.TimeOfDayColor.from_rgb([60,70,85], [140,145,155], [70,78,90], [32,35,42])
	p.sun_color = WeatherTypes.TimeOfDayColor.from_rgb([220,180,160], [230,230,230], [220,180,160], [59,97,176])
	p.sun_disc_sunset_color = Color(1.0, 0.74, 0.62)
	p.fog_depth_day = 1.5
	p.fog_depth_night = 1.8
	# Height fog — gentle snow-mist
	p.fog_height = 0.0
	p.fog_height_density_day = 0.003
	p.fog_height_density_night = 0.0054
	# Depth fog — bright white haze
	p.depth_fog_density_day = 0.00024
	p.depth_fog_density_night = 0.00036
	p.fog_sun_scatter = 0.15
	p.fog_aerial_perspective = 0.5
	p.fog_sky_affect = 0.2
	# Volumetric — cool white, gentle
	p.volumetric_density_day = 0.0024
	p.volumetric_density_night = 0.0036
	p.volumetric_albedo = Color(0.9, 0.91, 0.95)
	p.volumetric_anisotropy = 0.4
	p.volumetric_length = 450.0
	p.volumetric_sky_affect = 0.2
	p.sun_volumetric_energy = 2.5
	p.wind_speed = 0.3
	p.cloud_speed = 1.5
	p.cloud_coverage = 1.0
	p.glare_view = 0.0
	p.cloud_texture = "Tx_Sky_Snow.dds"
	p.transition_delta = 0.015
	p.clouds_max_percent = 1.0
	p.has_precipitation = true
	p.max_particles = 750
	p.particle_size = 800.0
	p.particle_speed = 100.0  # Snow falls slowly
	p.precip_threshold = 0.5
	p.ambient_sound = "BM Blizzard"
	return p

static func _blizzard() -> WeatherTypes.WeatherParams:
	var p := WeatherTypes.WeatherParams.new()
	p.sky_color = WeatherTypes.TimeOfDayColor.from_rgb([91,95,100], [130,138,150], [91,95,100], [9,10,11])
	p.fog_color = WeatherTypes.TimeOfDayColor.from_rgb([180,185,195], [200,205,215], [180,185,195], [9,10,11])
	p.ambient_color = WeatherTypes.TimeOfDayColor.from_rgb([55,60,70], [120,125,135], [60,65,75], [32,35,42])
	p.sun_color = WeatherTypes.TimeOfDayColor.from_rgb([200,175,160], [210,210,210], [200,175,160], [59,97,176])
	p.sun_disc_sunset_color = Color(1.0, 0.74, 0.62)
	p.fog_depth_day = 3.0
	p.fog_depth_night = 3.5
	# Height fog — whiteout, snow fills all low terrain
	p.fog_height = 20.0
	p.fog_height_density_day = 0.012
	p.fog_height_density_night = 0.018
	# Depth fog — near-total whiteout
	p.depth_fog_density_day = 0.0012
	p.depth_fog_density_night = 0.0015
	p.fog_sun_scatter = 0.02
	p.fog_aerial_perspective = 0.15
	p.fog_sky_affect = 0.32
	# Volumetric — bright white wall of snow
	p.volumetric_density_day = 0.0075
	p.volumetric_density_night = 0.0105
	p.volumetric_albedo = Color(0.88, 0.9, 0.95)
	p.volumetric_anisotropy = 0.15
	p.volumetric_length = 200.0
	p.volumetric_sky_affect = 0.32
	p.sun_volumetric_energy = 0.5
	p.wind_speed = 0.9
	p.cloud_speed = 7.5
	p.cloud_coverage = 1.0
	p.glare_view = 0.0
	p.cloud_texture = "Tx_Sky_Blizzard.dds"
	p.transition_delta = 0.030
	p.clouds_max_percent = 1.0
	p.is_storm = true
	p.storm_direction = Vector3(0, 0, -1)  # North wind
	p.storm_fog_multiplier = 5.0
	p.ambient_sound = "BM Blizzard"
	return p

#endregion
