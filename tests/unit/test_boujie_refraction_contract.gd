extends GdUnitTestSuite

const BOUJIE_SHADER_PATH := "res://src/core/water/shaders/ocean_boujie_experimental_common.gdshaderinc"
const FFT_SHADER_PATH := "res://src/core/water/shaders/ocean_fft_common.gdshaderinc"


func test_boujie_refraction_is_gated_by_optical_and_weather_visibility() -> void:
	var file := FileAccess.open(BOUJIE_SHADER_PATH, FileAccess.READ)
	assert_object(file).is_not_null()
	var source := file.get_as_text()

	assert_str(source).contains("uniform float refraction_weather_visibility")
	assert_str(source).contains("uniform float refraction_optical_fade_power")
	assert_str(source).contains("float optical_refraction_visibility = pow")
	assert_str(source).contains("r_final *= transmission_visibility * optical_refraction_visibility")
	assert_str(source).contains("final_refraction_opacity *= refracted_refraction_visibility")
	assert_str(source).contains("screen_lod += (1.0 - refracted_refraction_visibility) * refraction_extinction_blur_lod")


## Night-glow contract (2026-07-06): every unlit constant the water writes to
## EMISSION must be scaled by scene_light_color, otherwise the water body
## glows at daytime calibration all night ("exposure circle" around camera).
func test_water_emission_constants_are_scaled_by_scene_light() -> void:
	var boujie_file := FileAccess.open(BOUJIE_SHADER_PATH, FileAccess.READ)
	assert_object(boujie_file).is_not_null()
	var boujie_source := boujie_file.get_as_text()

	assert_str(boujie_source).contains("uniform vec3 scene_light_color = vec3(1.0)")
	assert_str(boujie_source).contains("medium_color * scene_light_color * (vec3(1.0) - transmittance)")
	assert_str(boujie_source).contains("mix(color_deep, medium_color, 0.82) * scene_light_color")
	assert_str(boujie_source).contains("color_sub_surface * scene_light_color * scatter * sss_emission_strength")

	var fft_file := FileAccess.open(FFT_SHADER_PATH, FileAccess.READ)
	assert_object(fft_file).is_not_null()
	var fft_source := fft_file.get_as_text()

	assert_str(fft_source).contains("uniform vec3 scene_light_color = vec3(1.0)")
	assert_str(fft_source).contains("color_sub_surface * scene_light_color * scatter * sss_emission_strength")


## Underwater-texture contract (2026-07-06): the flat shallow tint over the
## refracted scene must be gated by optical depth — an unconditional mix
## erases the textures of everything seen through the water.
func test_boujie_shallow_tint_is_depth_gated() -> void:
	var file := FileAccess.open(BOUJIE_SHADER_PATH, FileAccess.READ)
	assert_object(file).is_not_null()
	var source := file.get_as_text()

	assert_str(source).contains("0.55 * depth_blend")
	assert_str(source).not_contains("color_shallow, 0.55)")
