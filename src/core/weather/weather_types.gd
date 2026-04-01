## Weather Types — Enum, parameter containers, and interpolated result
##
## Generic weather system types. Morrowind weather is the default data source
## but the system is agnostic — any game can define custom weather types.
##
## WeatherParams holds per-type visual parameters with 4-phase time-of-day
## values (sunrise, day, sunset, night). WeatherResult is the fully interpolated
## output for a single frame, ready to be applied to the scene.
class_name WeatherTypes
extends RefCounted

## Weather type indices matching Morrowind's 10 types (0-9).
## Custom types can use indices >= 10.
enum Type {
	CLEAR = 0,
	CLOUDY = 1,
	FOGGY = 2,
	OVERCAST = 3,
	RAIN = 4,
	THUNDERSTORM = 5,
	ASHSTORM = 6,
	BLIGHT = 7,
	SNOW = 8,
	BLIZZARD = 9,
	COUNT = 10,
}

## Names for logging and UI
const TYPE_NAMES: Array[String] = [
	"Clear", "Cloudy", "Foggy", "Overcast", "Rain",
	"Thunderstorm", "Ashstorm", "Blight", "Snow", "Blizzard",
]

static func type_name(type: int) -> String:
	if type >= 0 and type < TYPE_NAMES.size():
		return TYPE_NAMES[type]
	return "Unknown(%d)" % type


## 4-phase time-of-day color value. Interpolated based on game hour.
class TimeOfDayColor:
	var sunrise: Color
	var day: Color
	var sunset: Color
	var night: Color

	func _init(p_sunrise: Color = Color.WHITE, p_day: Color = Color.WHITE,
			p_sunset: Color = Color.WHITE, p_night: Color = Color.WHITE) -> void:
		sunrise = p_sunrise
		day = p_day
		sunset = p_sunset
		night = p_night

	## Create from 4 RGB arrays (MW INI format: R,G,B as 0-255 integers)
	static func from_rgb(sr: Array, d: Array, ss: Array, n: Array) -> TimeOfDayColor:
		return TimeOfDayColor.new(
			Color(sr[0] / 255.0, sr[1] / 255.0, sr[2] / 255.0),
			Color(d[0] / 255.0, d[1] / 255.0, d[2] / 255.0),
			Color(ss[0] / 255.0, ss[1] / 255.0, ss[2] / 255.0),
			Color(n[0] / 255.0, n[1] / 255.0, n[2] / 255.0),
		)


## Per-weather-type visual parameters.
## Each weather type has one of these defining its full visual appearance.
class WeatherParams:
	## Sky/atmosphere colors (4-phase)
	var sky_color: TimeOfDayColor = TimeOfDayColor.new()
	var fog_color: TimeOfDayColor = TimeOfDayColor.new()
	var ambient_color: TimeOfDayColor = TimeOfDayColor.new()
	var sun_color: TimeOfDayColor = TimeOfDayColor.new()

	## Sun disc sunset tint (single color, not 4-phase)
	var sun_disc_sunset_color: Color = Color(1.0, 0.74, 0.62)

	## Fog density (MW: Land_Fog_Day_Depth / Land_Fog_Night_Depth)
	var fog_depth_day: float = 0.69
	var fog_depth_night: float = 0.69

	## Wind and cloud movement
	var wind_speed: float = 0.1
	var cloud_speed: float = 1.25

	## Cloud coverage (0 = clear sky, 1 = fully overcast)
	var cloud_coverage: float = 0.0

	## Sun glare intensity (0 = none, 1 = full)
	var glare_view: float = 1.0

	## Cloud texture name (MW: Tx_Sky_*.dds)
	var cloud_texture: String = "Tx_Sky_Clear.dds"

	## Transition speed — how fast to transition TO this weather (Hz real-time)
	## 0.015 = ~67 seconds, 0.030 = ~33 seconds
	var transition_delta: float = 0.015

	## Maximum cloud blend percent during transition (controls crossfade rate)
	var clouds_max_percent: float = 1.0

	## Precipitation
	var has_precipitation: bool = false
	var max_particles: int = 0  # Max raindrops/snowflakes
	var particle_size: float = 600.0  # Diameter of precipitation area
	var particle_speed: float = 575.0  # Fall speed (MW: Weather_Precip_Gravity)
	var precip_threshold: float = 0.6  # Transition ratio where particles begin

	## Whether this is a "storm" type (particles come from a direction, not straight down)
	var is_storm: bool = false
	## Storm origin direction (MW: Red Mountain for ash/blight)
	var storm_direction: Vector3 = Vector3.ZERO

	## Storm fog density multiplier (ash/blight reduce visibility)
	var storm_fog_multiplier: float = 1.0

	## Thunder (only for THUNDERSTORM type)
	var thunder_frequency: float = 0.0  # Probability per second
	var thunder_threshold: float = 0.0  # Min transition ratio for thunder
	var flash_decrement: float = 4.0  # Flash brightness decay per second

	## Ambient loop sound ID
	var ambient_sound: String = ""
	## Rain loop sound ID
	var rain_sound: String = ""


## Fully interpolated weather state for a single frame.
## Both weather-to-weather AND time-of-day interpolation baked in.
## WeatherRenderer consumes this to drive the scene.
class WeatherResult:
	## Final interpolated colors
	var sky_color: Color = Color(0.37, 0.53, 0.8)
	var fog_color: Color = Color(0.8, 0.85, 0.9)
	var ambient_color: Color = Color(0.54, 0.55, 0.63)
	var sun_color: Color = Color(1.0, 0.99, 0.93)
	var sun_disc_sunset_color: Color = Color(1.0, 0.74, 0.62)

	## Fog
	var fog_depth: float = 0.69

	## Wind and clouds
	var wind_speed: float = 0.1
	var cloud_speed: float = 1.25
	var cloud_coverage: float = 0.0

	## Sun
	var glare_view: float = 1.0

	## Precipitation
	var rain_intensity: float = 0.0  # 0-1, drives particle emission
	var snow_intensity: float = 0.0
	var storm_intensity: float = 0.0  # Ash/blight/blizzard particle intensity
	var storm_direction: Vector3 = Vector3.ZERO

	## Storm fog (additional fog from ash/blight)
	var storm_fog_multiplier: float = 1.0

	## Thunder flash brightness (additive, decays per frame)
	var thunder_flash: float = 0.0

	## Cloud texture crossfade (0-1, for blending between weather cloud textures)
	var cloud_blend_factor: float = 0.0
	var cloud_texture_current: String = ""
	var cloud_texture_next: String = ""

	## Sound volumes
	var rain_sound_volume: float = 0.0
	var ambient_sound_volume: float = 0.0
	var ambient_sound_id: String = ""
	var rain_sound_id: String = ""

	## Current game hour (for renderer, avoids direct autoload access)
	var game_hour: float = 8.0

	## Current weather type (for UI display / logic)
	var current_type: int = Type.CLEAR
	var next_type: int = Type.CLEAR
	var transition_factor: float = 0.0  # 0 = fully transitioned, 1 = just started
