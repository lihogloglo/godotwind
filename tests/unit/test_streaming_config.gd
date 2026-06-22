extends GdUnitTestSuite

const StreamingConfig := preload("res://src/core/world/streaming_config.gd")


func test_view_distance_default_is_within_slider_limits() -> void:
	assert_int(StreamingConfig.DEFAULT_VIEW_DISTANCE_METERS).is_greater_equal(StreamingConfig.MIN_VIEW_DISTANCE_METERS)
	assert_int(StreamingConfig.DEFAULT_VIEW_DISTANCE_METERS).is_less_equal(StreamingConfig.MAX_VIEW_DISTANCE_METERS)


func test_clamp_load_radius_cells() -> void:
	assert_int(StreamingConfig.clamp_load_radius_cells(StreamingConfig.MIN_LOAD_RADIUS_CELLS - 1)).is_equal(StreamingConfig.MIN_LOAD_RADIUS_CELLS)
	assert_int(StreamingConfig.clamp_load_radius_cells(StreamingConfig.MAX_LOAD_RADIUS_CELLS + 1)).is_equal(StreamingConfig.MAX_LOAD_RADIUS_CELLS)
	assert_int(StreamingConfig.clamp_load_radius_cells(StreamingConfig.DEFAULT_LOAD_RADIUS_CELLS)).is_equal(StreamingConfig.DEFAULT_LOAD_RADIUS_CELLS)


func test_view_distance_clamps_in_meters() -> void:
	assert_int(StreamingConfig.clamp_view_distance_meters(1)).is_equal(StreamingConfig.MIN_VIEW_DISTANCE_METERS)
	assert_int(StreamingConfig.clamp_view_distance_meters(999999)).is_equal(StreamingConfig.MAX_VIEW_DISTANCE_METERS)
	assert_int(StreamingConfig.clamp_view_distance_meters(StreamingConfig.DEFAULT_VIEW_DISTANCE_METERS)).is_equal(StreamingConfig.DEFAULT_VIEW_DISTANCE_METERS)


func test_scene_load_radius_is_capped_at_mid_bridge() -> void:
	assert_int(StreamingConfig.scene_load_radius_cells_for_view_distance_meters(250)).is_less_equal(StreamingConfig.MAX_SCENE_LOAD_RADIUS_CELLS)
	assert_int(StreamingConfig.scene_load_radius_cells_for_view_distance_meters(5000)).is_equal(StreamingConfig.MAX_SCENE_LOAD_RADIUS_CELLS)
	var cap := StreamingConfig.scene_load_distance_cap_for_view_distance_meters(5000)
	assert_float(cap).is_equal(StreamingConfig.DU.HLOD_START)


func test_distant_stream_radius_tracks_view_cap() -> void:
	var low_radius := StreamingConfig.distant_stream_radius_cells_for_view_distance_meters(1200, 45)
	var high_radius := StreamingConfig.distant_stream_radius_cells_for_view_distance_meters(5000, 45)
	assert_int(low_radius).is_less(high_radius)
	assert_int(high_radius).is_equal(45)
