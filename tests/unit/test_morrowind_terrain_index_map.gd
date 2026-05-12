extends GdUnitTestSuite

const BridgeScript := preload("res://src/core/world/morrowind/morrowind_terrain_texture_bridge.gd")
const NativeBridgeScript := preload("res://src/core/native_bridge.gd")
const INDEX_MAP_SIZE := 65
const MW_TEXTURE_SIZE := 16
const CELLS_PER_REGION := 4
const NEIGHBORHOOD_SIZE := CELLS_PER_REGION + 1


func test_region_index_map_samples_north_and_east_borders() -> void:
	var generator := _make_terrain_generator_or_fail()
	if generator == null:
		return

	var cells := _make_cells()
	cells[0] = _filled_cell(11)
	cells[4] = _filled_cell(44)
	cells[20] = _filled_cell(77)
	cells[24] = _filled_cell(123)

	var mapping := {
		11: 11,
		44: 44,
		77: 77,
		123: 123,
	}
	var image: Image = generator.call("GenerateMorrowindRegionIndexMap", cells, mapping)

	assert_int(image.get_width()).is_equal(INDEX_MAP_SIZE)
	assert_int(image.get_height()).is_equal(INDEX_MAP_SIZE)
	assert_int(_read_layer(image, 0, 64)).is_equal(11)
	assert_int(_read_layer(image, 64, 64)).is_equal(44)
	assert_int(_read_layer(image, 0, 0)).is_equal(77)
	assert_int(_read_layer(image, 64, 0)).is_equal(123)


func test_region_index_map_missing_neighbor_uses_default_layer() -> void:
	var generator := _make_terrain_generator_or_fail()
	if generator == null:
		return

	var cells := _make_cells()
	cells[0] = _filled_cell(12)
	var image: Image = generator.call("GenerateMorrowindRegionIndexMap", cells, {12: 12})

	assert_int(_read_layer(image, 64, 64)).is_equal(0)
	assert_int(_read_layer(image, 0, 0)).is_equal(0)


func test_region_index_map_preserves_layers_above_terrain3d_slot_limit() -> void:
	var generator := _make_terrain_generator_or_fail()
	if generator == null:
		return

	var cells := _make_cells()
	cells[0] = _filled_cell(80)
	var image: Image = generator.call("GenerateMorrowindRegionIndexMap", cells, {80: 80})

	assert_int(_read_layer(image, 0, 64)).is_equal(80)


func test_terrain3d_location_y_converts_to_mw_region_y() -> void:
	assert_vector(BridgeScript.terrain3d_location_to_mw_region(Vector2i(-1, 3))).is_equal(Vector2i(-1, -3))


func _make_terrain_generator_or_fail() -> RefCounted:
	var bridge := NativeBridgeScript.new()
	var factory: RefCounted = bridge.get("_factory")
	if factory == null:
		fail("NativeFactory is unavailable. Run dotnet build Godotwind.sln before the full gdUnit suite so the C# assembly loads.")
		return null
	var generator: RefCounted = factory.call("CreateTerrainGenerator")
	if generator == null:
		fail("TerrainGenerator native class is unavailable. Run dotnet build Godotwind.sln before the full gdUnit suite so the C# assembly loads.")
	return generator


func _make_cells() -> Array:
	var cells := []
	cells.resize(NEIGHBORHOOD_SIZE * NEIGHBORHOOD_SIZE)
	for i in range(cells.size()):
		cells[i] = PackedInt32Array()
	return cells


func _filled_cell(mw_index: int) -> PackedInt32Array:
	var indices := PackedInt32Array()
	indices.resize(MW_TEXTURE_SIZE * MW_TEXTURE_SIZE)
	for i in range(indices.size()):
		indices[i] = mw_index
	return indices


func _read_layer(image: Image, x: int, y: int) -> int:
	return roundi(image.get_pixel(x, y).r * 255.0)
