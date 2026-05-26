extends GdUnitTestSuite

const UNDERWATER_SHADER_PATH := "res://src/core/shaders/compute/underwater.glsl"


func test_caustics_are_attenuated_by_underwater_optics() -> void:
	var file := FileAccess.open(UNDERWATER_SHADER_PATH, FileAccess.READ)
	assert_object(file).is_not_null()
	var source := file.get_as_text()

	assert_str(source).contains("vec3 sigma")
	assert_str(source).contains("float view_path_len")
	assert_str(source).contains("vec3 optical_gate = exp(-max(sigma, vec3(0.0)) * max(view_path_len + sun_water_path, 0.0))")
	assert_str(source).contains("caustic * vec3(0.42, 0.78, 1.0) * optical_gate")
	assert_str(source).contains("underwater_caustics(hit_pos, cam_pos, medium, sigma, path_len")
