extends GdUnitTestSuite

## Round-trip test for the cooked cell manifest codec (Phase 3 M.0).
## Cooks a set of fake WorldObjectRecords to a binary file, loads it back,
## and asserts every field (stored AND derived) survives. No Morrowind data.

@warning_ignore("untyped_declaration", "unsafe_method_access")

const MANIFEST_PATH := "user://test_native_cell_manifest.gwm"
const GRID := Vector2i(-2, -9)


func _make_record(ref_id: String, ref_num: int, type_name: String) -> WorldObjectRecord:
	var r := WorldObjectRecord.new()
	r.object_id = WorldObjectRecord.make_object_id(GRID, ref_id, ref_num)
	r.record_id = StringName(ref_id)
	r.source_ref_id = StringName(ref_id)
	r.source_key = "%s:%s" % [type_name, str(r.object_id)]
	r.cell_grid = GRID
	r.transform = Transform3D(
		Basis(Vector3.UP, 0.7).scaled(Vector3(1.5, 1.5, 1.5)),
		Vector3(12.5, -3.25, 900.125)
	)
	r.model_path = "f\\%s.NIF" % ref_id
	r.model_item_id = ref_id
	r.category = WorldObjectRecord.Category.STATIC
	r.capability_flags = WorldObjectRecord.CAP_STATIC_VISUAL | WorldObjectRecord.CAP_COLLISION
	r.spawn_route = WorldObjectRecord.SpawnRoute.STATIC_BATCH
	r.static_batch_allowed = true
	r.proximity_radius_m = 2.5
	r.adapter_payload_id = r.object_id
	r.source_type = StringName(type_name)
	r.scale_scalar = 1.5
	return r


func _make_light_record() -> WorldObjectRecord:
	var r := _make_record("light_de_lantern_01", 77, "light")
	r.category = WorldObjectRecord.Category.LIGHT
	r.spawn_route = WorldObjectRecord.SpawnRoute.LIGHT
	r.static_batch_allowed = false
	r.cache_item_id = "light_de_lantern_01"
	r.light_color = Color(1.0, 0.72, 0.4, 1.0)
	r.light_radius = 6.75
	r.light_animation = WorldObjectRecord.LightAnimation.FLICKER
	r.light_is_fire = true
	return r


func test_cook_load_round_trip() -> void:
	var factory = load("res://src/native/NativeFactory.cs").new()
	assert_bool(factory.IsAvailable()).is_true()

	var records: Array = [
		_make_record("Barrel_01", 3, "container"),
		_make_record("ex_common_house_01", 12045, "static"),
		_make_light_record(),
	]

	var cooker = factory.CreateCellManifest()
	var cook_err: int = cooker.CookFromRecords(GRID, "", records, MANIFEST_PATH)
	assert_int(cook_err).is_equal(OK)

	var loader = factory.CreateCellManifest()
	var load_err: int = loader.LoadFromFile(MANIFEST_PATH)
	assert_int(load_err).is_equal(OK)

	assert_int(loader.GetRecordCount()).is_equal(records.size())
	assert_that(loader.GetCellGrid()).is_equal(GRID)

	for i in records.size():
		var original: WorldObjectRecord = records[i]
		var fields: Dictionary = loader.GetRecordFields(i)
		assert_str(str(fields["object_id"])).is_equal(str(original.object_id))
		assert_str(str(fields["record_id"])).is_equal(str(original.record_id))
		assert_str(str(fields["source_ref_id"])).is_equal(str(original.source_ref_id))
		assert_str(str(fields["source_key"])).is_equal(original.source_key)
		assert_that(fields["cell_grid"]).is_equal(original.cell_grid)
		assert_bool((fields["transform"] as Transform3D).is_equal_approx(original.transform)).is_true()
		assert_str(str(fields["model_path"])).is_equal(original.model_path)
		assert_str(str(fields["model_item_id"])).is_equal(original.model_item_id)
		assert_str(str(fields["cache_item_id"])).is_equal(original.cache_item_id)
		assert_int(int(fields["category"])).is_equal(original.category)
		assert_int(int(fields["capability_flags"])).is_equal(original.capability_flags)
		assert_int(int(fields["spawn_route"])).is_equal(original.spawn_route)
		assert_bool(bool(fields["static_batch_allowed"])).is_equal(original.static_batch_allowed)
		assert_float(float(fields["proximity_radius_m"])).is_equal_approx(original.proximity_radius_m, 0.0001)
		assert_str(str(fields["adapter_payload_id"])).is_equal(str(original.adapter_payload_id))
		assert_str(str(fields["source_type"])).is_equal(str(original.source_type))
		assert_float(float(fields["scale_scalar"])).is_equal_approx(original.scale_scalar, 0.0001)
		assert_that(fields["light_color"]).is_equal(original.light_color)
		assert_float(float(fields["light_radius"])).is_equal_approx(original.light_radius, 0.0001)
		assert_int(int(fields["light_animation"])).is_equal(original.light_animation)
		assert_bool(bool(fields["light_is_fire"])).is_equal(original.light_is_fire)


func test_load_missing_file_fails() -> void:
	var factory = load("res://src/native/NativeFactory.cs").new()
	var loader = factory.CreateCellManifest()
	var err: int = loader.LoadFromFile("user://does_not_exist.gwm")
	assert_int(err).is_not_equal(OK)


func after() -> void:
	if FileAccess.file_exists(MANIFEST_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(MANIFEST_PATH))
