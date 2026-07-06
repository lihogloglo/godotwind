## Unit tests for CelestialManager SIMPLE mode day/night cycle.
## Regression for the /2.0 elevation bug: the sin curve had a 48h period,
## so the sun peaked at 18:00, stayed up until midnight, then snapped below
## the horizon — night was compressed to ~2 perceived hours.
## Contract (matches WeatherData.SUNRISE_TIME=6 / SUNSET_TIME=18):
## sunrise 6:00, peak 12:00, sunset 18:00, nadir 0:00, continuous across wrap.
extends GdUnitTestSuite

const CelestialManagerScript := preload("res://src/core/sky/celestial_manager.gd")


func _make_celestial() -> CelestialManager:
	var c: CelestialManager = CelestialManagerScript.new()
	c.mode = CelestialManager.Mode.SIMPLE
	return c


func test_sun_on_horizon_at_sunrise_and_sunset() -> void:
	var c := _make_celestial()
	c.update(6.0)
	assert_float(c.sun_altitude).is_equal_approx(0.0, 0.001)
	c.update(18.0)
	assert_float(c.sun_altitude).is_equal_approx(0.0, 0.001)


func test_sun_peaks_at_noon() -> void:
	var c := _make_celestial()
	c.update(12.0)
	var noon_alt: float = c.sun_altitude
	assert_float(noon_alt).is_greater(0.0)
	# Noon must be higher than any other daytime hour
	for hour: float in [7.0, 9.0, 15.0, 17.0]:
		c.update(hour)
		assert_float(c.sun_altitude).is_less(noon_alt)


func test_sun_below_horizon_all_night() -> void:
	var c := _make_celestial()
	for hour: float in [18.5, 20.0, 22.0, 0.0, 2.0, 4.0, 5.5]:
		c.update(hour)
		assert_float(c.sun_altitude).is_less(0.0)


func test_sun_lowest_at_midnight() -> void:
	var c := _make_celestial()
	c.update(0.0)
	var midnight_alt: float = c.sun_altitude
	assert_float(midnight_alt).is_less(0.0)
	for hour: float in [20.0, 22.0, 2.0, 4.0]:
		c.update(hour)
		assert_float(c.sun_altitude).is_greater(midnight_alt)


func test_no_discontinuity_across_midnight_wrap() -> void:
	# The old bug snapped the sun from high in the sky to deep below
	# the horizon when the clock wrapped 24:00 -> 0:00.
	var c := _make_celestial()
	c.update(23.999)
	var before_wrap: Vector3 = c.sun_direction
	c.update(0.001)
	var after_wrap: Vector3 = c.sun_direction
	assert_float(before_wrap.distance_to(after_wrap)).is_less(0.01)


func test_day_and_night_are_equal_halves() -> void:
	# Sample every 15 game-minutes; expect a ~50/50 split of sun up vs down.
	var c := _make_celestial()
	var up_count: int = 0
	var total: int = 0
	var hour: float = 0.0
	while hour < 24.0:
		c.update(hour)
		if c.sun_altitude > 0.0:
			up_count += 1
		total += 1
		hour += 0.25
	var up_fraction: float = float(up_count) / float(total)
	assert_float(up_fraction).is_equal_approx(0.5, 0.02)


func test_moon_opposite_sun() -> void:
	var c := _make_celestial()
	c.update(0.0)
	# Moon should be up at midnight, near its peak
	assert_float(c.moon_direction.y).is_greater(0.5)
	c.update(12.0)
	# And below the horizon at noon
	assert_float(c.moon_direction.y).is_less(0.0)
