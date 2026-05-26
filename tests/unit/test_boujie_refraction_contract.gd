extends GdUnitTestSuite

const BOUJIE_SHADER_PATH := "res://src/core/water/shaders/ocean_boujie_experimental_common.gdshaderinc"


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
