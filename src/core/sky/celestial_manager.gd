class_name CelestialManager
extends RefCounted
## Computes sun, moon, and star positions from game time.
## Adapted from Sky3D's TimeOfDay.gd (MIT, TokisanGames).
## Stateless calculator — receives game_hour, outputs directions.
## Calendar system for date tracking, day-of-year, and save/load.

enum Mode { SIMPLE, REALISTIC }

const RADIANS_PER_HOUR: float = PI / 12.0
const EARTH_TILT: float = 23.44  # degrees
## Days per month — Gregorian default. Override for game-specific calendars
## (e.g., TES: all months 30 days, no leap years).
var days_per_month: Array[int] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

var mode: Mode = Mode.SIMPLE

## Observer latitude in degrees (-90 to 90). Affects sun arc height.
var latitude: float = 45.0
## Observer longitude in degrees. Affects star rotation in REALISTIC mode.
var longitude: float = 0.0
## Moon offset from anti-sun position (degrees). Allows artistic control.
var moon_offset: Vector2 = Vector2.ZERO

# ---- Calendar ----

## Current game year.
var year: int = 1
## Current game month (1-12).
var month: int = 1
## Current game day (1-31).
var day: int = 1
## Whether to auto-advance the calendar when days_elapsed is provided.
var calendar_enabled: bool = true

# --- Outputs (computed by update()) ---

## Normalized direction TO the sun (from observer).
var sun_direction: Vector3 = Vector3(0.0, 1.0, 0.0)
## Sun altitude angle in radians (-PI/2 to PI/2). For light intensity curves.
var sun_altitude: float = 0.0
## Normalized direction TO the moon.
var moon_direction: Vector3 = Vector3(0.0, -1.0, 0.0)
## Moon phase (0.0=new moon, 0.5=full moon, 1.0=new moon again).
var moon_phase: float = 0.0
## Rotation basis for star panorama.
var star_rotation: Basis = Basis.IDENTITY


## Compute all celestial positions for the given game hour.
## days_elapsed: number of new days since last update (0=same day, 1=next day, etc.).
##   The clock owner (WeatherManager) is responsible for tracking day boundaries.
##   Pass -1 to skip calendar updates.
func update(game_hour: float, days_elapsed: int = 0, day_of_year_override: int = -1) -> void:
	# Advance calendar by elapsed days
	if calendar_enabled and days_elapsed > 0:
		for i: int in days_elapsed:
			advance_day()

	var doy: int = day_of_year_override if day_of_year_override > 0 else get_day_of_year()

	if mode == Mode.SIMPLE:
		_compute_simple(game_hour)
	else:
		_compute_realistic(game_hour, doy)

	# Moon phase from dot product with sun (independent of mode)
	# 0 when moon faces sun (new), 1 when opposite (full)
	var phase_dot: float = -sun_direction.dot(moon_direction)
	moon_phase = (phase_dot + 1.0) * 0.5


#region Calendar

## Whether the given year is a leap year (Gregorian rules).
## Override for game-specific calendars that don't use leap years.
var use_leap_years: bool = true

static func _is_leap_year(y: int) -> bool:
	return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0)


## Days in the given month (1-12) of the given year.
func get_days_in_month(m: int, y: int = -1) -> int:
	if y < 0:
		y = year
	if m < 1 or m > days_per_month.size():
		return 30
	var d: int = days_per_month[m - 1]
	if m == 2 and use_leap_years and _is_leap_year(y):
		d = 29
	return d


## Day of year (1-366) from current date.
func get_day_of_year() -> int:
	var doy: int = 0
	for m: int in range(1, month):
		doy += get_days_in_month(m, year)
	doy += day
	return doy


## Advance one day, rolling over month/year as needed.
func advance_day() -> void:
	day += 1
	if day > get_days_in_month(month, year):
		day = 1
		month += 1
		if month > days_per_month.size():
			month = 1
			year += 1


## Get a readable date string (YYYY-MM-DD).
func get_date_string() -> String:
	return "%04d-%02d-%02d" % [year, month, day]


## Set date from a dictionary: { "year": int, "month": int, "day": int }.
## Useful for save/load and Morrowind calendar integration.
func set_from_date_dict(dict: Dictionary) -> void:
	year = dict.get("year", year) as int
	month = clampi(dict.get("month", month) as int, 1, days_per_month.size())
	day = clampi(dict.get("day", day) as int, 1, get_days_in_month(month, year))


## Get date as dictionary for save/load.
func get_date_dict() -> Dictionary:
	return { "year": year, "month": month, "day": day }


## Set date from day-of-year (1-366) and year.
func set_from_day_of_year(doy: int, y: int = -1) -> void:
	if y > 0:
		year = y
	doy = clampi(doy, 1, 366)
	month = 1
	var remaining: int = doy
	while remaining > get_days_in_month(month, year):
		remaining -= get_days_in_month(month, year)
		month += 1
		if month > days_per_month.size():
			month = 12
			break
	day = remaining

#endregion


#region SIMPLE Mode

func _compute_simple(game_hour: float) -> void:
	# Sun: east-to-west arc with latitude-adjusted elevation
	# At hour 6: sunrise (east). At 12: zenith. At 18: sunset (west).
	var hour_angle: float = (game_hour - 6.0) * RADIANS_PER_HOUR  # 0 at 6AM

	# Elevation: 24h-period sin curve — rises 6:00, peaks 12:00, sets 18:00,
	# nadir at midnight. Continuous across the day wrap (no snap).
	var max_elevation: float = deg_to_rad(90.0 - absf(latitude) * 0.4)
	var elevation: float = sin(hour_angle) * max_elevation

	# Azimuth: east(90) -> south(180) -> west(270)
	var azimuth: float = deg_to_rad(lerpf(90.0, 270.0, hour_angle / PI))

	# Below horizon handling: smooth descent, don't clamp
	sun_altitude = elevation
	sun_direction = _spherical_to_direction(elevation, azimuth)

	# Moon: roughly opposite the sun with artistic offset
	var moon_hour_angle: float = hour_angle + PI
	var moon_elevation: float = sin(moon_hour_angle) * max_elevation
	var moon_azimuth: float = azimuth + PI
	moon_elevation += deg_to_rad(moon_offset.y)
	moon_azimuth += deg_to_rad(moon_offset.x)
	moon_direction = _spherical_to_direction(moon_elevation, moon_azimuth)

	# Star rotation: simple hour-based rotation around polar axis
	var star_angle: float = game_hour * RADIANS_PER_HOUR
	var tilt: float = PI * 0.5 - deg_to_rad(latitude)
	star_rotation = Basis(Vector3.RIGHT, tilt) * Basis(Vector3.UP, -star_angle)

#endregion


#region REALISTIC Mode (adapted from Sky3D's TimeOfDay.gd)

func _compute_realistic(game_hour: float, day_of_year: int) -> void:
	# Julian century from J2000.0 epoch
	# Simplified: use day_of_year + hour fraction
	var d: float = day_of_year + (game_hour / 24.0)
	var T: float = d / 36525.0  # Julian centuries (approximate)

	# --- Sun position ---
	# Mean anomaly (degrees)
	var M: float = 357.5291 + 0.98560028 * d
	M = fmod(M, 360.0)
	var M_rad: float = deg_to_rad(M)

	# Equation of center
	var C: float = 1.9148 * sin(M_rad) + 0.02 * sin(2.0 * M_rad)

	# Ecliptic longitude
	var lambda_sun: float = fmod(M + C + 180.0 + 102.9372, 360.0)
	var lambda_rad: float = deg_to_rad(lambda_sun)

	# Obliquity of ecliptic
	var obliquity: float = deg_to_rad(23.44)

	# Equatorial coordinates
	var sin_lambda: float = sin(lambda_rad)
	var cos_lambda: float = cos(lambda_rad)
	var right_ascension: float = atan2(cos(obliquity) * sin_lambda, cos_lambda)
	var declination: float = asin(sin(obliquity) * sin_lambda)

	# Hour angle
	var lst: float = _local_sidereal_time(game_hour, d)
	var hour_angle: float = lst - right_ascension

	# Horizontal coordinates
	var lat_rad: float = deg_to_rad(latitude)
	var sin_alt: float = sin(lat_rad) * sin(declination) + cos(lat_rad) * cos(declination) * cos(hour_angle)
	sun_altitude = asin(clampf(sin_alt, -1.0, 1.0))

	var cos_az: float = (sin(declination) - sin(lat_rad) * sin_alt) / (cos(lat_rad) * cos(sun_altitude) + 1e-10)
	var azimuth: float = acos(clampf(cos_az, -1.0, 1.0))
	if sin(hour_angle) > 0.0:
		azimuth = TAU - azimuth

	sun_direction = _spherical_to_direction(sun_altitude, azimuth)

	# --- Moon position (simplified) ---
	# Lunar mean anomaly
	var Lm: float = fmod(218.316 + 13.176396 * d, 360.0)
	var Mm: float = fmod(134.963 + 13.064993 * d, 360.0)
	var Fm: float = fmod(93.272 + 13.229350 * d, 360.0)
	var Mm_rad: float = deg_to_rad(Mm)

	var moon_longitude: float = Lm + 6.289 * sin(Mm_rad)
	var moon_latitude: float = 5.128 * sin(deg_to_rad(Fm))

	var moon_lon_rad: float = deg_to_rad(moon_longitude)
	var moon_lat_rad: float = deg_to_rad(moon_latitude)

	# Moon equatorial coords
	var moon_ra: float = atan2(
		cos(obliquity) * sin(moon_lon_rad) * cos(moon_lat_rad) - sin(obliquity) * sin(moon_lat_rad),
		cos(moon_lon_rad) * cos(moon_lat_rad)
	)
	var moon_dec: float = asin(
		sin(obliquity) * sin(moon_lon_rad) * cos(moon_lat_rad) + cos(obliquity) * sin(moon_lat_rad)
	)

	# Moon horizontal coords
	var moon_ha: float = lst - moon_ra
	var moon_sin_alt: float = sin(lat_rad) * sin(moon_dec) + cos(lat_rad) * cos(moon_dec) * cos(moon_ha)
	var moon_alt: float = asin(clampf(moon_sin_alt, -1.0, 1.0))

	var moon_cos_az: float = (sin(moon_dec) - sin(lat_rad) * moon_sin_alt) / (cos(lat_rad) * cos(moon_alt) + 1e-10)
	var moon_az: float = acos(clampf(moon_cos_az, -1.0, 1.0))
	if sin(moon_ha) > 0.0:
		moon_az = TAU - moon_az

	moon_direction = _spherical_to_direction(moon_alt, moon_az)

	# --- Star rotation ---
	star_rotation = Basis(Vector3.RIGHT, PI * 0.5 - deg_to_rad(latitude)) * Basis(Vector3.UP, -lst)


func _local_sidereal_time(game_hour: float, day_number: float) -> float:
	# Approximate Local Sidereal Time
	var gmst: float = fmod(280.46061837 + 360.98564736629 * day_number, 360.0)
	var lst_deg: float = gmst + longitude + game_hour * 15.0
	return deg_to_rad(fmod(lst_deg, 360.0))

#endregion


#region Helpers

## Convert elevation (altitude) + azimuth to a normalized direction vector.
## Elevation: 0=horizon, +PI/2=zenith, -PI/2=nadir.
## Azimuth: 0=north, PI/2=east, PI=south, 3PI/2=west.
static func _spherical_to_direction(elevation: float, azimuth: float) -> Vector3:
	var cos_elev: float = cos(elevation)
	return Vector3(
		-sin(azimuth) * cos_elev,
		sin(elevation),
		-cos(azimuth) * cos_elev
	).normalized()

#endregion
