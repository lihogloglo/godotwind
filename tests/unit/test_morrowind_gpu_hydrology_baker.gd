extends GdUnitTestSuite

const GpuHydrologyBakerScript := preload("res://src/core/world/morrowind/morrowind_gpu_hydrology_baker.gd")


func test_offline_global_hydrology_artifact_contract_is_runtime_readable() -> void:
	var artifact := _global_hydrology_artifact_fixture()

	assert_bool(_is_valid_global_hydrology_artifact(artifact)).is_true()

	var region_data := _runtime_region_view_from_global_artifact(artifact, Vector2i(1, -1))
	assert_bool(region_data.is_empty()).is_false()
	assert_bool(region_data.has("flow_image")).is_true()
	assert_bool(region_data.has("heightmap")).is_false()
	assert_bool(region_data.has("baker")).is_false()
	assert_that(region_data.get("algorithm")).is_equal("morrowind_gpu_hydrology_region_v1")
	assert_that(region_data.get("source")).is_equal("offline_global_prebake")

	var flow_image: Image = region_data["flow_image"]
	assert_int(flow_image.get_width()).is_equal(4)
	assert_int(flow_image.get_height()).is_equal(4)
	assert_float(flow_image.get_pixel(0, 0).a).is_greater(0.5)


func test_offline_global_hydrology_artifact_rejects_region_scoped_cache_shape() -> void:
	var region_scoped_cache := {
		"schema": "godotwind.morrowind.hydrology.region_cache.v1",
		"cache_key": "river_flow_gpu_v3_1_-1_128_128_0_2_123",
		"flow_image": Image.create(4, 4, false, Image.FORMAT_RGBA8),
		"region_coord": Vector2i(1, -1),
	}

	assert_bool(_is_valid_global_hydrology_artifact(region_scoped_cache)).is_false()


func test_gpu_baker_rejects_enclosed_narrow_channel_as_still() -> void:
	var baker := _configured_baker()
	if not baker.is_available():
		return
	var result := baker.bake_from_heightmap(_heightmap_with_center_river_inside_halo(128, 96), 2.0)
	assert_bool(result.is_empty()).is_false()
	var image: Image = result["image"]
	var channel := image.get_pixel(64, 48)
	var land := image.get_pixel(64, 18)
	assert_float(channel.a).is_greater(0.5)
	assert_float(channel.b).is_equal_approx(0.0, 0.001)
	assert_float(land.a).is_equal_approx(0.0, 0.001)
	assert_int(int(result.get("river_count", 0))).is_equal(0)
	baker.shutdown()


func test_gpu_baker_keeps_broad_basin_still_and_accepts_narrow_upstream_corridor() -> void:
	var baker := _configured_baker()
	if not baker.is_available():
		return
	var result := baker.bake_from_heightmap(_heightmap_with_channel_feeding_broad_basin(64, 64), 2.0)
	assert_bool(result.is_empty()).is_false()
	var image: Image = result["image"]
	var channel := image.get_pixel(18, 39)
	var basin := image.get_pixel(50, 30)
	assert_float(channel.a).is_greater(0.5)
	assert_float(channel.b).is_greater(0.001)
	assert_float(basin.a).is_greater(0.5)
	assert_float(basin.b).is_equal_approx(0.0, 0.001)
	baker.shutdown()


func test_gpu_baker_rejects_broad_lake_as_river() -> void:
	var baker := _configured_baker()
	if not baker.is_available():
		return
	var result := baker.bake_from_heightmap(_heightmap_with_wide_lake(64, 64), 2.0)
	assert_bool(result.is_empty()).is_false()
	var image: Image = result["image"]
	var center := image.get_pixel(32, 32)
	assert_float(center.a).is_greater(0.5)
	assert_float(center.b).is_equal_approx(0.0, 0.001)
	baker.shutdown()


func test_gpu_baker_rejects_one_sided_coastal_inlet_fringe() -> void:
	var baker := _configured_baker()
	if not baker.is_available():
		return
	var result := baker.bake_from_heightmap(_heightmap_with_coastal_inlet(64, 64), 2.0)
	assert_bool(result.is_empty()).is_false()
	var image: Image = result["image"]
	var ocean_edge := image.get_pixel(5, 32)
	var inlet := image.get_pixel(26, 32)
	assert_float(ocean_edge.a).is_greater(0.5)
	assert_float(ocean_edge.b).is_equal_approx(0.0, 0.001)
	assert_float(inlet.a).is_greater(0.5)
	assert_float(inlet.b).is_equal_approx(0.0, 0.001)
	baker.shutdown()


func test_gpu_baker_rejects_archipelago_ocean_channels() -> void:
	var baker := _configured_baker()
	if not baker.is_available():
		return
	var result := baker.bake_from_heightmap(_heightmap_with_archipelago_ocean_channel(128, 96), 2.0)
	assert_bool(result.is_empty()).is_false()
	var image: Image = result["image"]
	var channel := image.get_pixel(64, 48)
	assert_float(channel.a).is_greater(0.5)
	assert_float(channel.b).is_equal_approx(0.0, 0.001)
	baker.shutdown()


func test_gpu_baker_preserves_true_river_mouth_with_inland_run() -> void:
	var baker := _configured_baker()
	if not baker.is_available():
		return
	var result := baker.bake_from_heightmap(_heightmap_with_river_mouth(128, 96), 2.0)
	assert_bool(result.is_empty()).is_false()
	var image: Image = result["image"]
	var ocean := image.get_pixel(7, 48)
	var inland := image.get_pixel(74, 48)
	assert_float(ocean.a).is_greater(0.5)
	assert_float(ocean.b).is_equal_approx(0.0, 0.001)
	assert_float(inland.a).is_greater(0.5)
	assert_float(inland.b).is_greater(0.001)
	assert_float(inland.r).is_less(0.48)
	assert_int(int(result.get("river_count", 0))).is_equal(1)
	baker.shutdown()


func test_gpu_baker_rejects_shoreline_fringe_parallel_to_ocean() -> void:
	var baker := _configured_baker()
	if not baker.is_available():
		return
	var result := baker.bake_from_heightmap(_heightmap_with_shoreline_fringe(128, 80), 2.0)
	assert_bool(result.is_empty()).is_false()
	var image: Image = result["image"]
	var fringe := image.get_pixel(60, 36)
	assert_float(fringe.a).is_greater(0.5)
	assert_float(fringe.b).is_equal_approx(0.0, 0.001)
	baker.shutdown()


func test_gpu_baker_accepts_lake_connected_river_but_keeps_lake_still() -> void:
	var baker := _configured_baker()
	if not baker.is_available():
		return
	var result := baker.bake_from_heightmap(_heightmap_with_lake_connected_river(128, 80), 2.0)
	assert_bool(result.is_empty()).is_false()
	var image: Image = result["image"]
	var river := image.get_pixel(54, 39)
	var lake := image.get_pixel(102, 39)
	assert_float(river.a).is_greater(0.5)
	assert_float(river.b).is_greater(0.001)
	assert_float(lake.a).is_greater(0.5)
	assert_float(lake.b).is_equal_approx(0.0, 0.001)
	baker.shutdown()


func test_gpu_baker_accepts_flat_long_channel_with_topology_fallback() -> void:
	var baker := _configured_baker()
	if not baker.is_available():
		return
	var result := baker.bake_from_heightmap(_heightmap_with_flat_long_channel(128, 80), 2.0)
	assert_bool(result.is_empty()).is_false()
	var image: Image = result["image"]
	var inland := image.get_pixel(96, 39)
	assert_float(inland.a).is_greater(0.5)
	assert_float(inland.b).is_greater(0.001)
	assert_float(inland.r).is_less(0.48)
	baker.shutdown()


func test_gpu_baker_accepts_noisy_bed_slope_and_points_to_outlet() -> void:
	var baker := _configured_baker()
	if not baker.is_available():
		return
	var result := baker.bake_from_heightmap(_heightmap_with_noisy_river_bed(128, 80), 2.0)
	assert_bool(result.is_empty()).is_false()
	var image: Image = result["image"]
	var inland := image.get_pixel(96, 39)
	assert_float(inland.a).is_greater(0.5)
	assert_float(inland.b).is_greater(0.001)
	assert_float(inland.r).is_less(0.48)
	baker.shutdown()


func test_gpu_baker_crop_preserves_river_mouth_inland_run() -> void:
	var baker := _configured_baker()
	if not baker.is_available():
		return
	var crop_rect := Rect2i(32, 16, 64, 64)
	var result := baker.bake_from_heightmap(_heightmap_with_river_mouth(128, 96), 2.0, crop_rect)
	assert_bool(result.is_empty()).is_false()
	var image: Image = result["image"]
	assert_int(image.get_width()).is_equal(64)
	assert_int(image.get_height()).is_equal(64)
	var center := image.get_pixel(32, 32)
	assert_float(center.a).is_greater(0.5)
	assert_float(center.b).is_greater(0.001)
	baker.shutdown()


func _configured_baker() -> MorrowindGpuHydrologyBaker:
	var baker: MorrowindGpuHydrologyBaker = GpuHydrologyBakerScript.new()
	baker.sea_level = 0.0
	baker.wet_tolerance_m = 0.12
	baker.max_river_width_m = 40.0
	baker.min_river_width_m = 5.0
	baker.coast_band_pixels = 8
	baker.min_inland_run_m = 40.0
	baker.max_candidate_coast_fraction = 0.60
	baker.max_candidate_ocean_contact_fraction = 0.30
	return baker


func _global_builder_tiles_with_ocean_connected_cross_region_river() -> Array[Dictionary]:
	var atlas := Image.create(32, 16, false, Image.FORMAT_RGBA8)
	atlas.fill(Color.TRANSPARENT)
	for y in range(16):
		for x in range(0, 4):
			_set_still(atlas, x, y)
	for y in range(7, 10):
		for x in range(4, 32):
			_set_river_candidate(atlas, x, y)
	return _split_global_flow_atlas(atlas, 16)


func _global_builder_tiles_with_cross_region_lake() -> Array[Dictionary]:
	var atlas := Image.create(32, 16, false, Image.FORMAT_RGBA8)
	atlas.fill(Color.TRANSPARENT)
	for y in range(4, 13):
		for x in range(5, 28):
			_set_river_candidate(atlas, x, y)
	return _split_global_flow_atlas(atlas, 16)


func _global_builder_tiles_with_short_ocean_inlet() -> Array[Dictionary]:
	var atlas := Image.create(32, 16, false, Image.FORMAT_RGBA8)
	atlas.fill(Color.TRANSPARENT)
	for y in range(16):
		for x in range(0, 7):
			_set_still(atlas, x, y)
	for y in range(7, 10):
		for x in range(7, 14):
			_set_river_candidate(atlas, x, y)
	return _split_global_flow_atlas(atlas, 16)


func _global_builder_tiles_with_enclosed_candidate() -> Array[Dictionary]:
	var atlas := Image.create(32, 16, false, Image.FORMAT_RGBA8)
	atlas.fill(Color.TRANSPARENT)
	for y in range(7, 10):
		for x in range(4, 20):
			_set_river_candidate(atlas, x, y)
	return _split_global_flow_atlas(atlas, 16)


func _dry_height_atlas(width: int, height: int) -> PackedFloat32Array:
	var heights := PackedFloat32Array()
	heights.resize(width * height)
	for i in range(width * height):
		heights[i] = 5.0
	return heights


func _height_tiles_from_atlas(atlas: PackedFloat32Array, width: int, height: int, region_size: int) -> Array[Dictionary]:
	var tiles: Array[Dictionary] = []
	var columns := int(width / region_size)
	var rows := int(height / region_size)
	for ry in range(rows):
		for rx in range(columns):
			var tile_heights := PackedFloat32Array()
			tile_heights.resize(region_size * region_size)
			for y in range(region_size):
				for x in range(region_size):
					tile_heights[y * region_size + x] = atlas[(ry * region_size + y) * width + rx * region_size + x]
			tiles.append({
				"region": Vector2i(rx, -ry),
				"width": region_size,
				"height": region_size,
				"heights": tile_heights,
			})
	return tiles


func _set_still(image: Image, x: int, y: int) -> void:
	image.set_pixel(x, y, Color8(128, 128, 0, 255))


func _set_river_candidate(image: Image, x: int, y: int) -> void:
	image.set_pixel(x, y, Color8(255, 128, 64, 255))


func _split_global_flow_atlas(atlas: Image, region_size: int) -> Array[Dictionary]:
	var tiles: Array[Dictionary] = []
	for region_x in range(2):
		var tile := Image.create(region_size, region_size, false, Image.FORMAT_RGBA8)
		tile.blit_rect(atlas, Rect2i(region_x * region_size, 0, region_size, region_size), Vector2i.ZERO)
		tiles.append({
			"region": Vector2i(region_x, 0),
			"image": tile,
		})
	return tiles


func _region_result_for(regions: Array, region_coord: Vector2i) -> Dictionary:
	for region_v: Variant in regions:
		if region_v is Dictionary:
			var region: Dictionary = region_v as Dictionary
			if region.get("region", Vector2i(999, 999)) == region_coord:
				return region
	return {}


func _heightmap_with_horizontal_channel(width: int, height: int, min_y: int, max_y: int) -> Image:
	var image := Image.create(width, height, false, Image.FORMAT_RF)
	for y in range(height):
		for x in range(width):
			var in_channel := y >= min_y and y <= max_y
			var bank_slope := absf(float(y) - float(min_y + max_y) * 0.5) * 0.05
			image.set_pixel(x, y, Color(-1.0 if in_channel else 3.0 + bank_slope, 0.0, 0.0, 1.0))
	return image


func _heightmap_with_inland_horizontal_channel(width: int, height: int, min_x: int, max_x: int, min_y: int, max_y: int) -> Image:
	var image := Image.create(width, height, false, Image.FORMAT_RF)
	for y in range(height):
		for x in range(width):
			var in_channel := x >= min_x and x <= max_x and y >= min_y and y <= max_y
			var bank_slope := absf(float(y) - float(min_y + max_y) * 0.5) * 0.05
			image.set_pixel(x, y, Color(-1.0 if in_channel else 3.0 + bank_slope, 0.0, 0.0, 1.0))
	return image


func _heightmap_with_wide_lake(width: int, height: int) -> Image:
	var image := Image.create(width, height, false, Image.FORMAT_RF)
	for y in range(height):
		for x in range(width):
			var in_lake := x >= 10 and x <= width - 11 and y >= 10 and y <= height - 11
			image.set_pixel(x, y, Color(-1.0 if in_lake else 4.0, 0.0, 0.0, 1.0))
	return image


func _heightmap_with_channel_feeding_broad_basin(width: int, height: int) -> Image:
	var image := Image.create(width, height, false, Image.FORMAT_RF)
	for y in range(height):
		for x in range(width):
			var in_channel := x >= 4 and x <= 34 and y >= 37 and y <= 41
			var in_basin := x >= 31 and x <= width - 4 and y >= 15 and y <= height - 9
			var bank_height := 4.0 - float(x) / maxf(float(width - 1), 1.0)
			image.set_pixel(x, y, Color(-1.0 if in_channel or in_basin else bank_height, 0.0, 0.0, 1.0))
	return image


func _heightmap_with_coastal_inlet(width: int, height: int) -> Image:
	var image := Image.create(width, height, false, Image.FORMAT_RF)
	for y in range(height):
		for x in range(width):
			var ocean := x < 18
			var inlet := x >= 18 and x <= 34 and y >= 29 and y <= 35
			image.set_pixel(x, y, Color(-1.0 if ocean or inlet else 4.0, 0.0, 0.0, 1.0))
	return image


func _heightmap_with_archipelago_ocean_channel(width: int, height: int) -> Image:
	var image := Image.create(width, height, false, Image.FORMAT_RF)
	image.fill(Color(-1.0, 0.0, 0.0, 1.0))
	for y in range(14, height - 14):
		for x in range(40, 57):
			image.set_pixel(x, y, Color(5.0, 0.0, 0.0, 1.0))
		for x in range(72, 89):
			image.set_pixel(x, y, Color(5.0, 0.0, 0.0, 1.0))
	for y in range(22, 38):
		for x in range(91, 106):
			image.set_pixel(x, y, Color(5.0, 0.0, 0.0, 1.0))
	for y in range(58, 76):
		for x in range(20, 35):
			image.set_pixel(x, y, Color(5.0, 0.0, 0.0, 1.0))
	return image


func _heightmap_with_river_mouth(width: int, height: int) -> Image:
	var image := Image.create(width, height, false, Image.FORMAT_RF)
	for y in range(height):
		for x in range(width):
			var ocean := x < 16
			var channel := x >= 16 and x <= width - 12 and y >= 45 and y <= 50
			var bank_height := 5.0 - float(x) / maxf(float(width - 1), 1.0)
			image.set_pixel(x, y, Color(-1.0 if ocean or channel else bank_height, 0.0, 0.0, 1.0))
	return image


func _heightmap_with_shoreline_fringe(width: int, height: int) -> Image:
	var image := Image.create(width, height, false, Image.FORMAT_RF)
	for y in range(height):
		for x in range(width):
			var ocean := y < 32
			var shore_fringe := y >= 32 and y <= 39 and x >= 12 and x <= width - 10
			image.set_pixel(x, y, Color(-1.0 if ocean or shore_fringe else 4.0, 0.0, 0.0, 1.0))
	return image


func _heightmap_with_lake_connected_river(width: int, height: int) -> Image:
	var image := Image.create(width, height, false, Image.FORMAT_RF)
	for y in range(height):
		for x in range(width):
			var channel := x >= 10 and x <= 86 and y >= 37 and y <= 42
			var lake := x >= 84 and x <= width - 10 and y >= 24 and y <= 55
			var bank_height := 5.0 - float(x) / maxf(float(width - 1), 1.0)
			image.set_pixel(x, y, Color(-1.0 if channel or lake else bank_height, 0.0, 0.0, 1.0))
	return image


func _heightmap_with_flat_long_channel(width: int, height: int) -> Image:
	var image := Image.create(width, height, false, Image.FORMAT_RF)
	for y in range(height):
		for x in range(width):
			var ocean := x < 16
			var channel := x >= 16 and x <= width - 10 and y >= 37 and y <= 42
			image.set_pixel(x, y, Color(-1.0 if ocean or channel else 4.0, 0.0, 0.0, 1.0))
	return image


func _heightmap_with_noisy_river_bed(width: int, height: int) -> Image:
	var image := Image.create(width, height, false, Image.FORMAT_RF)
	for y in range(height):
		for x in range(width):
			var ocean := x < 16
			var channel := x >= 16 and x <= width - 10 and y >= 37 and y <= 42
			var noise := float(((x * 17 + y * 31) % 9) - 4) * 0.015
			var bed := -0.35 - float(width - x) * 0.002 + noise
			var bank_height := 4.0 + absf(float(y) - 39.5) * 0.03
			image.set_pixel(x, y, Color(bed if ocean or channel else bank_height, 0.0, 0.0, 1.0))
	return image


func _heightmap_with_center_river_inside_halo(width: int, height: int) -> Image:
	var image := Image.create(width, height, false, Image.FORMAT_RF)
	for y in range(height):
		for x in range(width):
			var channel := x >= 18 and x <= width - 19 and y >= 45 and y <= 50
			image.set_pixel(x, y, Color(-1.0 if channel else 4.0, 0.0, 0.0, 1.0))
	return image


func _global_hydrology_artifact_fixture() -> Dictionary:
	var region_size_px := 4
	var atlas := Image.create(region_size_px * 2, region_size_px, false, Image.FORMAT_RGBA8)
	atlas.fill(Color(0.5, 0.5, 0.0, 0.0))
	for y in range(region_size_px):
		for x in range(region_size_px, region_size_px * 2):
			atlas.set_pixel(x, y, Color(0.5, 0.75, 0.35, 1.0))
	var regions: Dictionary[Vector2i, Dictionary] = {
		Vector2i(0, -1): {
			"atlas_rect": Rect2i(0, 0, region_size_px, region_size_px),
			"neighbor_edges": {"west": false, "east": true, "north": false, "south": false},
			"river_count": 0,
			"components": [],
		},
		Vector2i(1, -1): {
			"atlas_rect": Rect2i(region_size_px, 0, region_size_px, region_size_px),
			"neighbor_edges": {"west": true, "east": false, "north": false, "south": false},
			"river_count": 1,
			"components": [
				{
					"body_type": &"river",
					"bounds": AABB(Vector3(4.0, 0.0, -4.0), Vector3(4.0, 0.0, 4.0)),
					"mean_width_meters": 8.0,
					"flow_speed_meters_per_second": 1.4,
					"centerline_world_points": PackedVector3Array([
						Vector3(4.0, 0.0, -1.0),
						Vector3(7.0, 0.0, -1.0),
					]),
				},
			],
		},
	}
	return {
		"schema": "godotwind.morrowind.hydrology.global_flow_atlas.v1",
		"algorithm": "morrowind_gpu_hydrology_region_v1",
		"source": "offline_global_prebake",
		"flow_format": "RGBA8 flowmap: RG=direction, B=speed, A=coverage",
		"world_region_origin": Vector2i(0, -1),
		"region_size_pixels": region_size_px,
		"vertex_spacing_meters": 2.0,
		"sea_level_meters": 0.0,
		"flow_atlas_image": atlas,
		"regions": regions,
	}


func _is_valid_global_hydrology_artifact(artifact: Dictionary) -> bool:
	if artifact.get("schema") != "godotwind.morrowind.hydrology.global_flow_atlas.v1":
		return false
	if artifact.get("source") != "offline_global_prebake":
		return false
	if not artifact.get("flow_atlas_image") is Image:
		return false
	if not artifact.get("regions") is Dictionary:
		return false
	for metadata_v: Variant in (artifact.get("regions") as Dictionary).values():
		if not metadata_v is Dictionary:
			return false
		if not _has_neighbor_edge_metadata(metadata_v as Dictionary):
			return false
	if int(artifact.get("region_size_pixels", 0)) <= 0:
		return false
	if float(artifact.get("vertex_spacing_meters", 0.0)) <= 0.0:
		return false
	return true


func _has_neighbor_edge_metadata(metadata: Dictionary) -> bool:
	if not metadata.get("neighbor_edges") is Dictionary:
		return false
	var edges: Dictionary = metadata.get("neighbor_edges")
	return edges.has("west") and edges.has("east") and edges.has("north") and edges.has("south")


func _runtime_region_view_from_global_artifact(artifact: Dictionary, region_coord: Vector2i) -> Dictionary:
	if not _is_valid_global_hydrology_artifact(artifact):
		return {}
	var regions: Dictionary = artifact.get("regions", {})
	if not regions.has(region_coord):
		return {}
	var metadata: Dictionary = regions[region_coord]
	var atlas_rect: Rect2i = metadata.get("atlas_rect", Rect2i())
	if atlas_rect.size.x <= 0 or atlas_rect.size.y <= 0:
		return {}
	var atlas: Image = artifact["flow_atlas_image"]
	var flow_image := Image.create(atlas_rect.size.x, atlas_rect.size.y, false, atlas.get_format())
	flow_image.blit_rect(atlas, atlas_rect, Vector2i.ZERO)
	return {
		"flow_image": flow_image,
		"components": metadata.get("components", []),
		"river_count": int(metadata.get("river_count", 0)),
		"algorithm": String(artifact.get("algorithm", "")),
		"source": String(artifact.get("source", "")),
	}
