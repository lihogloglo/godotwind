extends GdUnitTestSuite

const WorldObjectRecordScript := preload("res://src/core/world/world_object_record.gd")
const WorldCellManifestScript := preload("res://src/core/world/world_cell_manifest.gd")
const NativeBridgeScript := preload("res://src/core/native_bridge.gd")


class FakeSource:
	extends WorldObjectSource

	var manifests: Dictionary[Vector2i, WorldCellManifest] = {}

	func add(record: WorldObjectRecord) -> void:
		var manifest: WorldCellManifest = manifests.get(record.cell_grid)
		if manifest == null:
			manifest = WorldCellManifestScript.new(record.cell_grid)
			manifests[record.cell_grid] = manifest
		manifest.add_object(record)

	func get_cell_manifest(cell_grid: Vector2i) -> WorldCellManifest:
		return manifests.get(cell_grid)


func test_fake_source_filters_by_capability() -> void:
	var source := FakeSource.new()
	var static_record := _record("cell0:static", Vector2i.ZERO, WorldObjectRecord.CAP_STATIC_VISUAL | WorldObjectRecord.CAP_HLOD)
	var light_record := _record("cell0:light", Vector2i.ZERO, WorldObjectRecord.CAP_DISTANT_LIGHT)
	source.add(static_record)
	source.add(light_record)

	var hlod_records: Array[WorldObjectRecord] = source.get_objects_in_cell(Vector2i.ZERO, WorldObjectRecord.CAP_HLOD)
	var light_records: Array[WorldObjectRecord] = source.get_objects_in_cell(Vector2i.ZERO, WorldObjectRecord.CAP_DISTANT_LIGHT)

	assert_int(hlod_records.size()).is_equal(1)
	assert_that(hlod_records[0].object_id).is_equal(&"cell0:static")
	assert_int(light_records.size()).is_equal(1)
	assert_that(light_records[0].object_id).is_equal(&"cell0:light")


func test_native_world_object_index_queries_cell_and_radius() -> void:
	var bridge := NativeBridgeScript.new()
	assert_bool(bridge.has_native_factory_method(&"CreateWorldObjectIndex")).is_true()

	var index: RefCounted = bridge.create_native_service(&"CreateWorldObjectIndex")
	index.call("AddObject", &"near_static", Vector3.ZERO, Vector2i.ZERO, WorldObjectRecord.CAP_HLOD)
	index.call("AddObject", &"far_light", Vector3(100.0, 0.0, 0.0), Vector2i(1, 0), WorldObjectRecord.CAP_DISTANT_LIGHT)

	var cell_ids: PackedStringArray = index.call("QueryCell", Vector2i.ZERO, WorldObjectRecord.CAP_HLOD)
	var radius_ids: PackedStringArray = index.call("QueryRadius", Vector3.ZERO, 10.0, WorldObjectRecord.CAP_HLOD)

	assert_int(cell_ids.size()).is_equal(1)
	assert_str(cell_ids[0]).is_equal("near_static")
	assert_int(radius_ids.size()).is_equal(1)
	assert_str(radius_ids[0]).is_equal("near_static")


func _record(id: String, cell_grid: Vector2i, flags: int) -> WorldObjectRecord:
	var record := WorldObjectRecordScript.new()
	record.object_id = StringName(id)
	record.cell_grid = cell_grid
	record.capability_flags = flags
	record.model_path = "meshes\\test.nif"
	return record
