extends GdUnitTestSuite

const WaterOpticalProfileScript := preload("res://src/core/water/water_optical_profile.gd")


func test_visibility_distance_sets_clear_water_extinction() -> void:
	var profile: WaterOpticalProfile = WaterOpticalProfileScript.new()
	profile.visibility_distance_m = 20.0
	profile.scattering_strength = 0.0
	profile.extinction_color_bias = Vector3.ONE

	var sigma := profile.get_extinction_sigma()
	var transmittance_at_visibility := exp(-sigma.x * profile.visibility_distance_m)

	assert_float(transmittance_at_visibility).is_equal_approx(
		WaterOpticalProfile.TARGET_TRANSMITTANCE,
		0.0001
	)


func test_turbidity_increases_underwater_fog_extinction() -> void:
	var clear_profile: WaterOpticalProfile = WaterOpticalProfileScript.new()
	clear_profile.visibility_distance_m = 20.0
	clear_profile.scattering_strength = 0.0
	clear_profile.extinction_color_bias = Vector3.ONE

	var turbid_profile: WaterOpticalProfile = WaterOpticalProfileScript.new()
	turbid_profile.visibility_distance_m = clear_profile.visibility_distance_m
	turbid_profile.scattering_strength = 1.0
	turbid_profile.extinction_color_bias = clear_profile.extinction_color_bias

	var clear_sigma := clear_profile.get_extinction_sigma()
	var turbid_sigma := turbid_profile.get_extinction_sigma()

	assert_float(turbid_sigma.x).is_equal_approx(
		clear_sigma.x * WaterOpticalProfile.MAX_TURBIDITY_EXTINCTION_MULTIPLIER,
		0.0001
	)
	assert_float(turbid_sigma.y).is_equal_approx(
		clear_sigma.y * WaterOpticalProfile.MAX_TURBIDITY_EXTINCTION_MULTIPLIER,
		0.0001
	)
	assert_float(turbid_sigma.z).is_equal_approx(
		clear_sigma.z * WaterOpticalProfile.MAX_TURBIDITY_EXTINCTION_MULTIPLIER,
		0.0001
	)
