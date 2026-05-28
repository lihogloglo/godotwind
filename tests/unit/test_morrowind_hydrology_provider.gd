extends GdUnitTestSuite

const MorrowindHydrologyProviderScript := preload("res://src/core/world/morrowind/morrowind_hydrology_provider.gd")


func test_generated_flowmap_marks_long_narrow_sea_level_channel_as_river() -> void:
	var provider: MorrowindHydrologyProvider = _configured_provider(_heightmap_with_horizontal_channel(32, 32, 24, 27), 2.0)

	assert_int(provider.initialize()).is_equal(OK)
	assert_int(provider.prepare_region(Vector2i.ZERO)).is_equal(OK)

	var velocity := provider.sample_velocity(Vector3(16.0, -0.5, -13.0))
	assert_float(velocity.length()).is_greater(0.1)
	assert_float(provider.sample_coverage(Vector3(16.0, -0.5, -13.0))).is_greater(0.5)
	assert_that(provider.sample_water_body_id(Vector3(16.0, -0.5, -13.0))).is_equal(&"morrowind_generated_river")


func test_generated_flowmap_leaves_wide_water_component_still() -> void:
	var provider: MorrowindHydrologyProvider = _configured_provider(_heightmap_with_wide_lake(32, 32), 2.0)

	assert_int(provider.initialize()).is_equal(OK)
	assert_int(provider.prepare_region(Vector2i.ZERO)).is_equal(OK)

	var velocity := provider.sample_velocity(Vector3(16.0, -0.5, -15.0))
	assert_vector(velocity).is_equal_approx(Vector3.ZERO, Vector3.ONE * 0.001)
	assert_float(provider.sample_coverage(Vector3(16.0, -0.5, -15.0))).is_greater(0.5)
	assert_that(provider.sample_water_body_id(Vector3(16.0, -0.5, -15.0))).is_equal(&"morrowind_sea_level_water")


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
