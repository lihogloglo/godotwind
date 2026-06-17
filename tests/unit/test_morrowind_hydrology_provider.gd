extends GdUnitTestSuite

const MorrowindHydrologyProviderScript := preload("res://src/core/world/morrowind/morrowind_hydrology_provider.gd")
const HydrologyAtlasPrebakerScript := preload("res://src/tools/prebaking/morrowind_hydrology_atlas_prebaker.gd")
const MorrowindNativeBridgeScript := preload("res://src/core/world/morrowind/morrowind_native_bridge.gd")


func test_generated_flowmap_marks_long_narrow_sea_level_channel_as_river() -> void:
	var provider: MorrowindHydrologyProvider = _configured_provider(_heightmap_with_horizontal_channel(32, 32, 24, 27), 2.0)

	assert_int(provider.initialize()).is_equal(OK)
	assert_int(provider.prepare_region(Vector2i.ZERO)).is_equal(OK)

	var velocity := provider.sample_velocity(Vector3(16.0, -0.5, -13.0))
	assert_float(velocity.length()).is_greater(0.1)
	assert_float(provider.sample_coverage(Vector3(16.0, -0.5, -13.0))).is_greater(0.5)
	assert_that(provider.sample_water_body_id(Vector3(16.0, -0.5, -13.0))).is_equal(&"morrowind_generated_river")


func test_hydrology_atlas_prebaker_script_loads() -> void:
	var prebaker: RefCounted = HydrologyAtlasPrebakerScript.new()
	assert_object(prebaker).is_not_null()
	assert_bool(prebaker.has_method("bake_from_terrain3d_directory")).is_true()


func test_native_atlas_marks_cross_region_channel_as_river() -> void:
	var result := _build_native_atlas([
		{"region": Vector2i.ZERO, "heightmap": _heightmap_with_ocean_and_channel_tile(32, 32, true)},
		{"region": Vector2i(1, 0), "heightmap": _heightmap_with_ocean_and_channel_tile(32, 32, false)},
	])
	if result.is_empty():
		return
	var region := _region_result_for(result.get("regions", []), Vector2i(1, 0))
	var image: Image = region.get("image") as Image
	assert_object(image).is_not_null()
	var river := image.get_pixel(12, 15)
	assert_float(river.a).is_greater(0.5)
	assert_float(river.b).is_greater(0.001)


func test_native_atlas_keeps_broad_lake_still() -> void:
	var result := _build_native_atlas([
		{"region": Vector2i.ZERO, "heightmap": _heightmap_with_wide_lake(32, 32)},
	])
	if result.is_empty():
		return
	var region := _region_result_for(result.get("regions", []), Vector2i.ZERO)
	var image: Image = region.get("image") as Image
	assert_object(image).is_not_null()
	var lake := image.get_pixel(16, 16)
	assert_float(lake.a).is_greater(0.5)
	assert_float(lake.b).is_equal_approx(0.0, 0.001)


func test_native_atlas_rejects_short_coastal_inlet() -> void:
	var result := _build_native_atlas([
		{"region": Vector2i.ZERO, "heightmap": _heightmap_with_short_coastal_inlet(48, 32)},
	])
	if result.is_empty():
		return
	var region := _region_result_for(result.get("regions", []), Vector2i.ZERO)
	var image: Image = region.get("image") as Image
	assert_object(image).is_not_null()
	var inlet := image.get_pixel(20, 15)
	assert_float(inlet.a).is_greater(0.5)
	assert_float(inlet.b).is_equal_approx(0.0, 0.001)


func test_full_resolution_region_uses_gpu_cache_version() -> void:
	var provider: MorrowindHydrologyProvider = _configured_provider(_heightmap_with_horizontal_channel(128, 128, 60, 66), 2.0)

	assert_int(provider.initialize()).is_equal(OK)
	assert_int(provider.prepare_region(Vector2i.ZERO)).is_equal(OK)

	var cached: Dictionary = provider._region_cache.get(Vector2i.ZERO, {})
	assert_that(cached.get("algorithm")).is_equal("river_flow_gpu_legacy_v5")
	assert_float(provider.sample_coverage(Vector3(128.0, -0.5, -128.0))).is_greater(0.5)


func test_runtime_global_build_does_not_write_png_slices_by_default() -> void:
	var cache_dir := "user://hydrology_provider_runtime_no_slices"
	_clear_cache_dir(cache_dir)
	var provider: MorrowindHydrologyProvider = _configured_provider(_heightmap_with_horizontal_channel(32, 32, 24, 27), 2.0)
	provider.cache_enabled = false
	provider.cache_directory = cache_dir

	assert_int(provider.initialize()).is_equal(OK)
	assert_int(provider.prepare_region(Vector2i.ZERO)).is_equal(OK)

	var native_dir := ProjectSettings.globalize_path(cache_dir)
	if DirAccess.dir_exists_absolute(native_dir):
		assert_int(DirAccess.get_files_at(native_dir).size()).is_equal(0)
	_clear_cache_dir(cache_dir)


func test_prepare_region_loads_prebaked_hydrology_without_heightmap_request() -> void:
	var cache_dir := "user://hydrology_provider_prebaked_atlas"
	_clear_cache_dir(cache_dir)
	_write_prebaked_hydrology_region(cache_dir, Vector2i.ZERO)
	var terrain := FakeLazyTerrainProvider.new(2.0)
	var provider: MorrowindHydrologyProvider = MorrowindHydrologyProviderScript.new()
	provider.configure(terrain, null)
	provider.cache_enabled = false
	provider.hydrology_atlas_directory = cache_dir
	provider.allow_runtime_hydrology_bake = false

	assert_int(provider.initialize()).is_equal(OK)
	assert_int(provider.prepare_region(Vector2i.ZERO)).is_equal(OK)

	var cached: Dictionary = provider._region_cache.get(Vector2i.ZERO, {})
	assert_bool(bool(cached.get("prebaked", false))).is_true()
	assert_that(cached.get("algorithm")).is_equal("morrowind_hydrology_atlas_v2")
	assert_int(terrain.heightmap_requests).is_equal(0)
	assert_float(provider.sample_coverage(Vector3(16.0, -0.5, -16.0))).is_greater(0.5)
	_clear_cache_dir(cache_dir)


func test_prepare_region_ignores_stale_prebaked_hydrology_version() -> void:
	var cache_dir := "user://hydrology_provider_stale_prebaked_atlas"
	_clear_cache_dir(cache_dir)
	_write_prebaked_hydrology_region(cache_dir, Vector2i.ZERO, "morrowind_gpu_hydrology_region_v1")
	var terrain := FakeLazyTerrainProvider.new(2.0)
	var provider: MorrowindHydrologyProvider = MorrowindHydrologyProviderScript.new()
	provider.configure(terrain, null)
	provider.cache_enabled = false
	provider.hydrology_atlas_directory = cache_dir
	provider.allow_runtime_hydrology_bake = false

	assert_int(provider.initialize()).is_equal(OK)
	assert_int(provider.prepare_region(Vector2i.ZERO)).is_equal(ERR_DOES_NOT_EXIST)
	assert_int(terrain.heightmap_requests).is_equal(0)
	_clear_cache_dir(cache_dir)


func test_generated_flowmap_leaves_wide_water_component_still() -> void:
	var provider: MorrowindHydrologyProvider = _configured_provider(_heightmap_with_wide_lake(32, 32), 2.0)

	assert_int(provider.initialize()).is_equal(OK)
	assert_int(provider.prepare_region(Vector2i.ZERO)).is_equal(OK)

	var velocity := provider.sample_velocity(Vector3(16.0, -0.5, -15.0))
	assert_vector(velocity).is_equal_approx(Vector3.ZERO, Vector3.ONE * 0.001)
	assert_float(provider.sample_coverage(Vector3(16.0, -0.5, -15.0))).is_greater(0.5)
	assert_that(provider.sample_water_body_id(Vector3(16.0, -0.5, -15.0))).is_equal(&"morrowind_sea_level_water")


func test_generated_flowmap_keeps_narrow_river_when_connected_to_broad_basin() -> void:
	var provider: MorrowindHydrologyProvider = _configured_provider(_heightmap_with_channel_feeding_broad_basin(64, 64), 2.0)

	assert_int(provider.initialize()).is_equal(OK)
	assert_int(provider.prepare_region(Vector2i.ZERO)).is_equal(OK)

	var channel_pos := Vector3(32.0, -0.5, -52.0)
	var basin_pos := Vector3(96.0, -0.5, -60.0)
	var land_pos := Vector3(32.0, 2.0, -88.0)
	var channel_velocity := provider.sample_velocity(channel_pos)
	var basin_velocity := provider.sample_velocity(basin_pos)

	assert_float(channel_velocity.length()).is_greater(0.1)
	assert_float(provider.sample_coverage(channel_pos)).is_greater(0.5)
	assert_that(provider.sample_water_body_id(channel_pos)).is_equal(&"morrowind_generated_river")
	assert_vector(basin_velocity).is_equal_approx(Vector3.ZERO, Vector3.ONE * 0.001)
	assert_float(provider.sample_coverage(basin_pos)).is_greater(0.5)
	assert_that(provider.sample_water_body_id(basin_pos)).is_equal(&"morrowind_sea_level_water")
	assert_float(provider.sample_coverage(land_pos)).is_equal_approx(0.0, 0.001)
	assert_that(provider.sample_water_body_id(land_pos)).is_equal(WaterSurfaceState.WATER_BODY_NONE)


func test_generated_flowmap_orients_sloped_valley_channel_toward_broad_basin() -> void:
	var provider: MorrowindHydrologyProvider = _configured_provider(_heightmap_with_sloped_valley_channel_feeding_basin(64, 64), 2.0)

	assert_int(provider.initialize()).is_equal(OK)
	assert_int(provider.prepare_region(Vector2i.ZERO)).is_equal(OK)

	var channel_velocity := provider.sample_velocity(Vector3(32.0, -0.5, -52.0))
	var basin_velocity := provider.sample_velocity(Vector3(96.0, -0.5, -60.0))

	assert_float(channel_velocity.length()).is_greater(0.1)
	assert_float(channel_velocity.x).is_greater(0.1)
	assert_float(absf(channel_velocity.z)).is_less(0.6)
	assert_vector(basin_velocity).is_equal_approx(Vector3.ZERO, Vector3.ONE * 0.001)


func test_generated_flowmap_ignores_land() -> void:
	var provider: MorrowindHydrologyProvider = _configured_provider(_heightmap_with_horizontal_channel(32, 32, 24, 27), 2.0)

	assert_int(provider.initialize()).is_equal(OK)
	assert_int(provider.prepare_region(Vector2i.ZERO)).is_equal(OK)

	assert_float(provider.sample_coverage(Vector3(16.0, 2.0, -4.0))).is_equal_approx(0.0, 0.001)
	assert_that(provider.sample_water_body_id(Vector3(16.0, 2.0, -4.0))).is_equal(WaterSurfaceState.WATER_BODY_NONE)


func test_sampling_does_not_bake_unprepared_regions_from_gameplay_query() -> void:
	var terrain := FakeTerrainProvider.new(_heightmap_with_horizontal_channel(32, 32, 24, 27), 2.0)
	var provider: MorrowindHydrologyProvider = MorrowindHydrologyProviderScript.new()
	provider.configure(terrain, null)
	provider.cache_enabled = false

	assert_int(provider.initialize()).is_equal(OK)

	assert_float(provider.sample_coverage(Vector3(16.0, -0.5, -13.0))).is_equal_approx(0.0, 0.001)
	assert_int(terrain.heightmap_requests).is_equal(0)


func test_descriptor_lookup_does_not_bake_unprepared_region() -> void:
	var terrain := FakeTerrainProvider.new(_heightmap_with_horizontal_channel(32, 32, 24, 27), 2.0)
	var provider: MorrowindHydrologyProvider = MorrowindHydrologyProviderScript.new()
	provider.configure(terrain, null)
	provider.cache_enabled = false

	assert_int(provider.initialize()).is_equal(OK)

	var descriptors := provider.get_water_body_descriptors_for_region(Vector2i.ZERO)
	assert_array(descriptors).is_empty()
	assert_int(terrain.heightmap_requests).is_equal(0)


func test_renderable_river_payloads_are_read_only_for_unprepared_region() -> void:
	var terrain := FakeTerrainProvider.new(_heightmap_with_horizontal_channel(32, 32, 24, 27), 2.0)
	var provider: MorrowindHydrologyProvider = MorrowindHydrologyProviderScript.new()
	provider.configure(terrain, null)
	provider.cache_enabled = false

	assert_int(provider.initialize()).is_equal(OK)

	var payloads := provider.get_renderable_river_descriptors_for_region(Vector2i.ZERO)
	assert_array(payloads).is_empty()
	assert_int(terrain.heightmap_requests).is_equal(0)


func test_renderable_river_payload_uses_generic_godot_space_schema() -> void:
	var provider: MorrowindHydrologyProvider = _configured_provider(_heightmap_with_horizontal_channel(32, 32, 24, 27), 2.0)

	assert_int(provider.initialize()).is_equal(OK)
	assert_int(provider.prepare_region(Vector2i.ZERO)).is_equal(OK)

	var payloads := provider.get_renderable_river_descriptors_for_region(Vector2i.ZERO)
	assert_int(payloads.size()).is_equal(1)
	var payload: Dictionary = payloads[0]
	assert_that(payload.get("body_type")).is_equal(WaterBodyDescriptor.TYPE_RIVER)
	assert_bool(payload.has("centerline_world_points")).is_true()
	assert_bool(payload.has("centerline_pixels")).is_false()
	assert_bool(payload.has("morrowind_cell")).is_false()
	assert_bool(payload.has("mw_region")).is_false()
	assert_float(float(payload.get("mean_width_meters", 0.0))).is_greater(0.0)
	assert_float(float(payload.get("flow_speed_meters_per_second", 0.0))).is_greater(0.1)
	assert_bool(payload.get("bounds") is AABB).is_true()
	assert_bool(payload.get("flowmap_image") is Image).is_true()

	var descriptors := provider.get_water_body_descriptors_for_region(Vector2i.ZERO)
	assert_int(descriptors.size()).is_equal(1)
	var descriptor: RefCounted = descriptors[0]
	var metadata: Dictionary = descriptor.get("metadata")
	assert_int((metadata.get("renderable_rivers", []) as Array).size()).is_equal(1)


func test_renderable_river_centerline_is_ordered_for_straight_channel() -> void:
	var provider: MorrowindHydrologyProvider = _configured_provider(_heightmap_with_horizontal_channel(32, 32, 24, 27), 2.0)

	assert_int(provider.initialize()).is_equal(OK)
	assert_int(provider.prepare_region(Vector2i.ZERO)).is_equal(OK)

	var payloads := provider.get_renderable_river_descriptors_for_region(Vector2i.ZERO)
	assert_int(payloads.size()).is_equal(1)
	var points: PackedVector3Array = payloads[0].get("centerline_world_points", PackedVector3Array())
	assert_int(points.size()).is_greater(8)
	assert_bool(_points_are_monotonic_x(points)).is_true()
	assert_float(_max_consecutive_distance(points)).is_less(5.0)
	assert_float(_average_z(points)).is_greater(-18.0)
	assert_float(_average_z(points)).is_less(-6.0)


func test_renderable_river_centerline_is_ordered_for_branch_like_channel() -> void:
	var provider: MorrowindHydrologyProvider = _configured_provider(_heightmap_with_branch_like_channel(32, 32), 2.0)

	assert_int(provider.initialize()).is_equal(OK)
	assert_int(provider.prepare_region(Vector2i.ZERO)).is_equal(OK)

	var payloads := provider.get_renderable_river_descriptors_for_region(Vector2i.ZERO)
	assert_int(payloads.size()).is_equal(1)
	var points: PackedVector3Array = payloads[0].get("centerline_world_points", PackedVector3Array())
	assert_int(points.size()).is_greater(8)
	assert_float(_max_consecutive_distance(points)).is_less(5.0)
	assert_float(maxf(_span_x(points), _span_z(points))).is_greater(20.0)


func test_cache_metadata_preserves_renderable_river_components() -> void:
	var cache_dir := "user://hydrology_provider_metadata_cache"
	_clear_cache_dir(cache_dir)
	var provider: MorrowindHydrologyProvider = _configured_provider(_heightmap_with_horizontal_channel(32, 32, 24, 27), 2.0)
	provider.cache_enabled = true
	provider.cache_directory = cache_dir

	assert_int(provider.initialize()).is_equal(OK)
	assert_int(provider.prepare_region(Vector2i.ZERO)).is_equal(OK)

	var cached: Dictionary = provider._region_cache.get(Vector2i.ZERO, {})
	var cache_key := String(cached.get("cache_key", ""))
	assert_str(cache_key).is_not_empty()

	var metadata_path := ProjectSettings.globalize_path(cache_dir.path_join(cache_key + ".json"))
	assert_bool(FileAccess.file_exists(metadata_path)).is_true()
	var metadata_file := FileAccess.open(metadata_path, FileAccess.READ)
	assert_object(metadata_file).is_not_null()
	var parsed: Variant = JSON.parse_string(metadata_file.get_as_text())
	metadata_file.close()
	assert_bool(parsed is Dictionary).is_true()
	var metadata: Dictionary = parsed as Dictionary
	var serialized_components: Array = metadata.get("components", [])
	assert_int(serialized_components.size()).is_greater(0)
	var first_component: Dictionary = serialized_components[0]
	assert_bool(first_component.has("bounds")).is_true()
	assert_bool(first_component.has("mean_width_meters")).is_true()
	assert_bool(first_component.has("flow_speed_meters_per_second")).is_true()
	assert_int((first_component.get("centerline_pixels", []) as Array).size()).is_greater(0)

	provider.release_region(Vector2i.ZERO)
	var loaded: Dictionary = provider._load_cached_region(cache_key, Vector2i.ZERO)
	assert_int((loaded.get("components", []) as Array).size()).is_greater(0)
	provider._region_cache[Vector2i.ZERO] = loaded
	var payloads := provider.get_renderable_river_descriptors_for_region(Vector2i.ZERO)
	assert_int(payloads.size()).is_equal(1)
	assert_float(float(payloads[0].get("flow_speed_meters_per_second", 0.0))).is_greater(0.1)
	_clear_cache_dir(cache_dir)


func test_region_descriptors_do_not_report_other_regions() -> void:
	var provider: MorrowindHydrologyProvider = _configured_multi_region_provider(_heightmap_with_horizontal_channel(32, 32, 24, 27), 2.0)

	assert_int(provider.initialize()).is_equal(OK)
	assert_int(provider.prepare_region(Vector2i.ZERO)).is_equal(OK)
	assert_int(provider.prepare_region(Vector2i(1, 0))).is_equal(OK)

	var descriptors := provider.get_water_body_descriptors_for_region(Vector2i.ZERO)
	assert_int(descriptors.size()).is_equal(1)
	var descriptor: RefCounted = descriptors[0]
	assert_float(descriptor.call("sample_coverage", Vector3(16.0, -0.5, -13.0))).is_greater(0.5)
	assert_float(descriptor.call("sample_coverage", Vector3(80.0, -0.5, -13.0))).is_equal_approx(0.0, 0.001)
	assert_float(provider.sample_coverage(Vector3(80.0, -0.5, -13.0))).is_greater(0.5)


func test_release_region_removes_cached_sampling_data() -> void:
	var provider: MorrowindHydrologyProvider = _configured_provider(_heightmap_with_horizontal_channel(32, 32, 24, 27), 2.0)

	assert_int(provider.initialize()).is_equal(OK)
	assert_int(provider.prepare_region(Vector2i.ZERO)).is_equal(OK)
	assert_float(provider.sample_coverage(Vector3(16.0, -0.5, -13.0))).is_greater(0.5)

	provider.release_region(Vector2i.ZERO)
	assert_float(provider.sample_coverage(Vector3(16.0, -0.5, -13.0))).is_equal_approx(0.0, 0.001)


func test_prepare_region_retries_after_missing_heightmap_instead_of_poisoning_cache() -> void:
	var terrain := FakeLazyTerrainProvider.new(2.0)
	var provider: MorrowindHydrologyProvider = MorrowindHydrologyProviderScript.new()
	provider.configure(terrain, null)
	provider.cache_enabled = false

	assert_int(provider.initialize()).is_equal(OK)
	assert_int(provider.prepare_region(Vector2i.ZERO)).is_equal(ERR_DOES_NOT_EXIST)

	terrain.heightmap = _heightmap_with_horizontal_channel(32, 32, 24, 27)
	assert_int(provider.prepare_region(Vector2i.ZERO)).is_equal(OK)
	assert_float(provider.sample_coverage(Vector3(16.0, -0.5, -13.0))).is_greater(0.5)


func test_region_descriptor_samples_only_its_region() -> void:
	var provider: MorrowindHydrologyProvider = _configured_provider(_heightmap_with_horizontal_channel(32, 32, 24, 27), 2.0)

	assert_int(provider.initialize()).is_equal(OK)
	assert_int(provider.prepare_region(Vector2i.ZERO)).is_equal(OK)

	var descriptors := provider.get_water_body_descriptors_for_region(Vector2i.ZERO)
	assert_int(descriptors.size()).is_equal(1)
	var descriptor: RefCounted = descriptors[0]

	assert_float(descriptor.sample_coverage(Vector3(16.0, -0.5, -13.0))).is_greater(0.5)
	assert_float(descriptor.sample_coverage(Vector3(80.0, -0.5, -13.0))).is_equal_approx(0.0, 0.001)


func test_request_prepare_region_publishes_after_worker_poll() -> void:
	var provider: MorrowindHydrologyProvider = _configured_provider(_heightmap_with_horizontal_channel(32, 32, 24, 27), 2.0)

	assert_int(provider.initialize()).is_equal(OK)
	assert_int(provider.request_prepare_region(Vector2i.ZERO)).is_equal(OK)

	for i in range(60):
		provider.process_async_requests()
		if provider.sample_coverage(Vector3(16.0, -0.5, -13.0)) > 0.5:
			break
		await get_tree().process_frame

	assert_float(provider.sample_coverage(Vector3(16.0, -0.5, -13.0))).is_greater(0.5)


func test_request_prepare_region_bakes_copied_height_samples() -> void:
	var terrain := FakeTerrainProvider.new(_heightmap_with_horizontal_channel(32, 32, 24, 27), 2.0)
	var provider: MorrowindHydrologyProvider = MorrowindHydrologyProviderScript.new()
	provider.configure(terrain, null)
	provider.cache_enabled = false

	assert_int(provider.initialize()).is_equal(OK)
	assert_int(provider.request_prepare_region(Vector2i.ZERO)).is_equal(OK)
	_fill_heightmap_land(terrain._heightmap)

	for i in range(60):
		provider.process_async_requests()
		if provider.sample_coverage(Vector3(16.0, -0.5, -13.0)) > 0.5:
			break
		await get_tree().process_frame

	assert_float(provider.sample_velocity(Vector3(16.0, -0.5, -13.0)).length()).is_greater(0.1)


func test_region_cache_trims_unreferenced_regions() -> void:
	var terrain := FakeAnyRegionTerrainProvider.new(_heightmap_with_horizontal_channel(32, 32, 24, 27), 2.0)
	var provider: MorrowindHydrologyProvider = MorrowindHydrologyProviderScript.new()
	provider.configure(terrain, null)
	provider.cache_enabled = false
	provider.max_cached_regions = 1

	assert_int(provider.initialize()).is_equal(OK)
	assert_int(provider.prepare_region(Vector2i.ZERO)).is_equal(OK)
	assert_int(provider.prepare_region(Vector2i(1, 0))).is_equal(OK)

	assert_float(provider.sample_coverage(Vector3(16.0, -0.5, -13.0))).is_equal_approx(0.0, 0.001)
	assert_float(provider.sample_coverage(Vector3(80.0, -0.5, -13.0))).is_greater(0.5)


func _configured_provider(heightmap: Image, vertex_spacing: float) -> MorrowindHydrologyProvider:
	var terrain := FakeTerrainProvider.new(heightmap, vertex_spacing)
	var provider: MorrowindHydrologyProvider = MorrowindHydrologyProviderScript.new()
	provider.configure(terrain, null)
	provider.cache_enabled = false
	return provider


func _configured_multi_region_provider(heightmap: Image, vertex_spacing: float) -> MorrowindHydrologyProvider:
	var terrain := FakeMultiRegionTerrainProvider.new(heightmap, vertex_spacing)
	var provider: MorrowindHydrologyProvider = MorrowindHydrologyProviderScript.new()
	provider.configure(terrain, null)
	provider.cache_enabled = false
	return provider


func _build_native_atlas(tiles: Array) -> Dictionary:
	var bridge: RefCounted = MorrowindNativeBridgeScript.new()
	var builder := bridge.create_hydrology_atlas_builder()
	if builder == null:
		return {}
	var result: Dictionary = builder.call(
		"BuildAtlas",
		tiles,
		2.0,
		0.0,
		0.0,
		1.4,
		6.0
	)
	assert_int(int(result.get("error", FAILED))).is_equal(OK)
	return result


func _region_result_for(regions: Array, region_coord: Vector2i) -> Dictionary:
	for region_v: Variant in regions:
		if not region_v is Dictionary:
			continue
		var region: Dictionary = region_v as Dictionary
		if region.get("region", Vector2i(2147483647, 2147483647)) == region_coord:
			return region
	return {}


func _heightmap_with_ocean_and_channel_tile(width: int, height: int, include_ocean: bool) -> Image:
	var image := Image.create(width, height, false, Image.FORMAT_RF)
	for y in range(height):
		for x in range(width):
			var in_ocean := include_ocean and x <= 5
			var in_channel := y >= 14 and y <= 16
			var channel_slope := -1.0 + float(x) * 0.01
			image.set_pixel(x, y, Color(channel_slope if in_channel or in_ocean else 3.0 + absf(float(y) - 15.0) * 0.08, 0.0, 0.0, 1.0))
	return image


func _heightmap_with_short_coastal_inlet(width: int, height: int) -> Image:
	var image := Image.create(width, height, false, Image.FORMAT_RF)
	for y in range(height):
		for x in range(width):
			var in_ocean := x <= 9
			var in_inlet := x > 9 and x <= 22 and y >= 14 and y <= 16
			image.set_pixel(x, y, Color(-1.0 if in_ocean or in_inlet else 3.0, 0.0, 0.0, 1.0))
	return image


func _heightmap_with_horizontal_channel(width: int, height: int, water_y_min: int, water_y_max: int) -> Image:
	var image := Image.create(width, height, false, Image.FORMAT_RF)
	for y in range(height):
		for x in range(width):
			var h := -1.0 if y >= water_y_min and y <= water_y_max else 2.0
			if x < 2 or x > width - 3:
				h = -1.0 if y >= water_y_min and y <= water_y_max else 2.5
			image.set_pixel(x, y, Color(h, 0.0, 0.0, 1.0))
	return image


func _heightmap_with_wide_lake(width: int, height: int) -> Image:
	var image := Image.create(width, height, false, Image.FORMAT_RF)
	for y in range(height):
		for x in range(width):
			var in_lake := x >= 7 and x <= 24 and y >= 7 and y <= 24
			image.set_pixel(x, y, Color(-1.0 if in_lake else 2.0, 0.0, 0.0, 1.0))
	return image


func _heightmap_with_channel_feeding_broad_basin(width: int, height: int) -> Image:
	var image := Image.create(width, height, false, Image.FORMAT_RF)
	for y in range(height):
		for x in range(width):
			var in_channel := x >= 6 and x <= 31 and y >= 37 and y <= 40
			var in_basin := x >= 30 and x <= width - 3 and y >= 12 and y <= height - 10
			image.set_pixel(x, y, Color(-1.0 if in_channel or in_basin else 3.0, 0.0, 0.0, 1.0))
	return image


func _heightmap_with_sloped_valley_channel_feeding_basin(width: int, height: int) -> Image:
	var image := Image.create(width, height, false, Image.FORMAT_RF)
	for y in range(height):
		for x in range(width):
			var in_channel := x >= 6 and x <= 31 and y >= 37 and y <= 40
			var in_basin := x >= 30 and x <= width - 3 and y >= 12 and y <= height - 10
			var distance_from_channel := absf(float(y) - 38.5)
			var downstream_drop := float(x) / maxf(float(width - 1), 1.0) * 1.6
			var bank_height := 4.0 + distance_from_channel * 0.08 - downstream_drop
			image.set_pixel(x, y, Color(-1.0 if in_channel or in_basin else bank_height, 0.0, 0.0, 1.0))
	return image


func _heightmap_with_branch_like_channel(width: int, height: int) -> Image:
	var image := Image.create(width, height, false, Image.FORMAT_RF)
	for y in range(height):
		for x in range(width):
			var in_main := x >= 3 and x <= width - 4 and y >= 20 and y <= 23
			var in_branch := x >= 15 and x <= 18 and y >= 7 and y <= 23
			image.set_pixel(x, y, Color(-1.0 if in_main or in_branch else 2.0, 0.0, 0.0, 1.0))
	return image


func _fill_heightmap_land(image: Image) -> void:
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			image.set_pixel(x, y, Color(2.0, 0.0, 0.0, 1.0))


func _points_are_monotonic_x(points: PackedVector3Array) -> bool:
	if points.size() < 2:
		return true
	var direction := 1.0
	if points[points.size() - 1].x < points[0].x:
		direction = -1.0
	for i in range(1, points.size()):
		if (points[i].x - points[i - 1].x) * direction < -0.001:
			return false
	return true


func _max_consecutive_distance(points: PackedVector3Array) -> float:
	var max_distance := 0.0
	for i in range(1, points.size()):
		max_distance = maxf(max_distance, points[i - 1].distance_to(points[i]))
	return max_distance


func _average_z(points: PackedVector3Array) -> float:
	var sum := 0.0
	for point: Vector3 in points:
		sum += point.z
	return sum / maxf(float(points.size()), 1.0)


func _span_x(points: PackedVector3Array) -> float:
	if points.is_empty():
		return 0.0
	var min_x := points[0].x
	var max_x := points[0].x
	for point: Vector3 in points:
		min_x = minf(min_x, point.x)
		max_x = maxf(max_x, point.x)
	return max_x - min_x


func _span_z(points: PackedVector3Array) -> float:
	if points.is_empty():
		return 0.0
	var min_z := points[0].z
	var max_z := points[0].z
	for point: Vector3 in points:
		min_z = minf(min_z, point.z)
		max_z = maxf(max_z, point.z)
	return max_z - min_z


func _clear_cache_dir(cache_dir: String) -> void:
	var native_dir := ProjectSettings.globalize_path(cache_dir)
	if not DirAccess.dir_exists_absolute(native_dir):
		return
	for file_name: String in DirAccess.get_files_at(native_dir):
		DirAccess.remove_absolute(native_dir.path_join(file_name))


func _write_prebaked_hydrology_region(cache_dir: String, region_coord: Vector2i, algorithm: String = "morrowind_hydrology_atlas_v2") -> void:
	var native_dir := ProjectSettings.globalize_path(cache_dir)
	DirAccess.make_dir_recursive_absolute(native_dir)
	var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.5, 0.5, 0.0, 1.0))
	var key := MorrowindHydrologyProvider.prebaked_region_key(region_coord)
	assert_int(image.save_png(native_dir.path_join(key + ".png"))).is_equal(OK)
	var manifest := {
		"schema": "godotwind.morrowind.hydrology.region_atlas.v1",
		"algorithm": algorithm,
		"regions": [{"region": [region_coord.x, region_coord.y], "image": key + ".png", "metadata": key + ".json"}],
	}
	var metadata := {
		"schema": "godotwind.morrowind.hydrology.region_atlas.v1",
		"algorithm": algorithm,
		"source": "offline_terrain3d_prebake",
		"river_count": 0,
		"components": [],
	}
	var manifest_file := FileAccess.open(native_dir.path_join("manifest.json"), FileAccess.WRITE)
	assert_object(manifest_file).is_not_null()
	manifest_file.store_string(JSON.stringify(manifest, "\t"))
	manifest_file.close()
	var metadata_file := FileAccess.open(native_dir.path_join(key + ".json"), FileAccess.WRITE)
	assert_object(metadata_file).is_not_null()
	metadata_file.store_string(JSON.stringify(metadata, "\t"))
	metadata_file.close()


class FakeTerrainProvider:
	extends "res://src/core/world/world_data_provider.gd"

	var _heightmap: Image
	var heightmap_requests := 0

	func _init(heightmap: Image, p_vertex_spacing: float) -> void:
		_heightmap = heightmap
		world_name = "Hydrology Test"
		region_size = heightmap.get_width()
		vertex_spacing = p_vertex_spacing
		cell_size = float(region_size) * vertex_spacing
		sea_level = 0.0

	func get_heightmap_for_region(region_coord: Vector2i) -> Image:
		heightmap_requests += 1
		return _heightmap if region_coord == Vector2i.ZERO else null

	func has_terrain_at_region(region_coord: Vector2i) -> bool:
		return region_coord == Vector2i.ZERO

	func get_all_terrain_regions() -> Array[Vector2i]:
		return [Vector2i.ZERO]

	func initialize() -> Error:
		return OK


class FakeMultiRegionTerrainProvider:
	extends FakeTerrainProvider

	func get_heightmap_for_region(_region_coord: Vector2i) -> Image:
		heightmap_requests += 1
		return _heightmap

	func has_terrain_at_region(_region_coord: Vector2i) -> bool:
		return true

	func get_all_terrain_regions() -> Array[Vector2i]:
		return [Vector2i.ZERO, Vector2i(1, 0)]


class FakeLazyTerrainProvider:
	extends "res://src/core/world/world_data_provider.gd"

	var heightmap: Image = null
	var heightmap_requests := 0

	func _init(p_vertex_spacing: float) -> void:
		world_name = "Lazy Hydrology Test"
		region_size = 32
		vertex_spacing = p_vertex_spacing
		cell_size = float(region_size) * vertex_spacing
		sea_level = 0.0

	func get_heightmap_for_region(region_coord: Vector2i) -> Image:
		heightmap_requests += 1
		return heightmap if region_coord == Vector2i.ZERO else null

	func has_terrain_at_region(region_coord: Vector2i) -> bool:
		return region_coord == Vector2i.ZERO

	func get_all_terrain_regions() -> Array[Vector2i]:
		return [Vector2i.ZERO]

	func initialize() -> Error:
		return OK


class FakeAnyRegionTerrainProvider:
	extends FakeTerrainProvider

	func get_heightmap_for_region(_region_coord: Vector2i) -> Image:
		heightmap_requests += 1
		return _heightmap

	func has_terrain_at_region(_region_coord: Vector2i) -> bool:
		return true
