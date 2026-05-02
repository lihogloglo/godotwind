extends GdUnitTestSuite

const StreamingConfig := preload("res://src/core/world/streaming_config.gd")


func test_load_radius_default_is_within_slider_limits() -> void:
	assert_int(StreamingConfig.DEFAULT_LOAD_RADIUS_CELLS).is_greater_equal(StreamingConfig.MIN_LOAD_RADIUS_CELLS)
	assert_int(StreamingConfig.DEFAULT_LOAD_RADIUS_CELLS).is_less_equal(StreamingConfig.MAX_LOAD_RADIUS_CELLS)


func test_clamp_load_radius_cells() -> void:
	assert_int(StreamingConfig.clamp_load_radius_cells(StreamingConfig.MIN_LOAD_RADIUS_CELLS - 1)).is_equal(StreamingConfig.MIN_LOAD_RADIUS_CELLS)
	assert_int(StreamingConfig.clamp_load_radius_cells(StreamingConfig.MAX_LOAD_RADIUS_CELLS + 1)).is_equal(StreamingConfig.MAX_LOAD_RADIUS_CELLS)
	assert_int(StreamingConfig.clamp_load_radius_cells(StreamingConfig.DEFAULT_LOAD_RADIUS_CELLS)).is_equal(StreamingConfig.DEFAULT_LOAD_RADIUS_CELLS)
