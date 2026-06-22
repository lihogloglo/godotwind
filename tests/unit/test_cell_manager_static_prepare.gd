extends GdUnitTestSuite

const CellManagerScript := preload("res://src/core/world/cell_manager.gd")
const WorldObjectRecordScript := preload("res://src/core/world/world_object_record.gd")


class FakeStaticRenderer:
	extends Node

	var registered := false

	func has_type(_type_name: String) -> bool:
		return registered


func test_static_world_records_use_bucket_prepare_even_when_small() -> void:
	var manager: Variant = CellManagerScript.new()
	var renderer := FakeStaticRenderer.new()
	auto_free(renderer)
	manager.set_static_renderer(renderer)

	var record: RefCounted = WorldObjectRecordScript.new()
	record.model_path = "meshes\\f\\flora_grass_01.nif"
	record.source_type = &"static"
	record.static_batch_allowed = true
	record.transform = Transform3D.IDENTITY

	assert_bool(manager._should_prepare_static_record(
		record,
		str(record.get("model_path")),
		CellManagerScript.LoadProfile.exterior_default(),
		"tiny_clutter"
	)).is_true()


func test_static_world_records_use_bucket_prepare_even_when_not_flora() -> void:
	var manager: Variant = CellManagerScript.new()
	var renderer := FakeStaticRenderer.new()
	auto_free(renderer)
	manager.set_static_renderer(renderer)

	var record: RefCounted = WorldObjectRecordScript.new()
	record.model_path = "meshes\\x\\ex_hlaalu_bldg_01.nif"
	record.source_type = &"static"
	record.spawn_route = WorldObjectRecordScript.SpawnRoute.STATIC_BATCH
	record.static_batch_allowed = true
	record.transform = Transform3D.IDENTITY

	assert_bool(manager._should_prepare_static_record(
		record,
		str(record.get("model_path")),
		CellManagerScript.LoadProfile.exterior_static_visuals_only(),
		""
	)).is_true()


func test_non_static_records_keep_existing_size_gate() -> void:
	var manager: Variant = CellManagerScript.new()
	var renderer := FakeStaticRenderer.new()
	auto_free(renderer)
	manager.set_static_renderer(renderer)

	var record: RefCounted = WorldObjectRecordScript.new()
	record.model_path = "meshes\\f\\flora_grass_01.nif"
	record.source_type = &"misc"
	record.static_batch_allowed = true
	record.transform = Transform3D.IDENTITY

	assert_bool(manager._should_prepare_static_record(
		record,
		str(record.get("model_path")),
		CellManagerScript.LoadProfile.exterior_default(),
		"tiny_clutter"
	)).is_false()


func test_static_batch_entry_without_cached_key_waits_for_prepare() -> void:
	var manager: Variant = CellManagerScript.new()
	var renderer := FakeStaticRenderer.new()
	auto_free(renderer)
	manager.set_static_renderer(renderer)

	var request_id: int = manager._start_async_request(
		null,
		Vector2i.ZERO,
		false,
		CellManagerScript.LoadProfile.exterior_default(),
		[],
		true
	)
	assert_int(request_id).is_greater(0)

	var record: RefCounted = WorldObjectRecordScript.new()
	record.model_path = "meshes\\x\\cold_static.nif"
	record.source_type = &"static"
	record.spawn_route = WorldObjectRecordScript.SpawnRoute.STATIC_BATCH
	record.static_batch_allowed = false
	record.transform = Transform3D.IDENTITY

	var entry: Variant = CellManagerScript.InstantiationEntry.new()
	entry.request_id = request_id
	entry.world_object_record = record
	entry.model_path = str(record.get("model_path"))
	entry.cache_item_id = ""
	entry.type_name = "static"

	assert_bool(manager._static_entry_waiting_for_prepare(entry)).is_true()
	assert_str(str(entry.static_prepare_key)).is_equal("meshes\\x\\cold_static.nif")
	var request: Variant = manager._async_requests[request_id]
	assert_int(request.payload.get_static_prepare_queue_size()).is_equal(1)


func test_registered_static_batch_entry_still_waits_for_cell_bucket() -> void:
	var manager: Variant = CellManagerScript.new()
	var renderer := FakeStaticRenderer.new()
	renderer.registered = true
	auto_free(renderer)
	manager.set_static_renderer(renderer)

	var request_id: int = manager._start_async_request(
		null,
		Vector2i.ZERO,
		false,
		CellManagerScript.LoadProfile.exterior_default(),
		[],
		true
	)
	assert_int(request_id).is_greater(0)

	var record: RefCounted = WorldObjectRecordScript.new()
	record.model_path = "meshes\\x\\registered_static.nif"
	record.source_type = &"static"
	record.spawn_route = WorldObjectRecordScript.SpawnRoute.STATIC_BATCH
	record.static_batch_allowed = true
	record.transform = Transform3D.IDENTITY

	var request: Variant = manager._async_requests[request_id]
	request.payload.add_static_record(str(record.get("model_path")), "", record)

	var entry: Variant = CellManagerScript.InstantiationEntry.new()
	entry.request_id = request_id
	entry.world_object_record = record
	entry.model_path = str(record.get("model_path"))
	entry.cache_item_id = ""
	entry.type_name = "static"
	entry.load_profile = CellManagerScript.LoadProfile.exterior_default()

	assert_bool(manager._static_entry_waiting_for_prepare(entry)).is_true()
	assert_int(request.payload.get_static_prepare_queue_size()).is_equal(1)


func test_static_batch_entry_is_ready_when_cell_bucket_exists() -> void:
	var manager: Variant = CellManagerScript.new()
	var renderer := FakeStaticRenderer.new()
	renderer.registered = true
	auto_free(renderer)
	manager.set_static_renderer(renderer)

	var request_id: int = manager._start_async_request(
		null,
		Vector2i.ZERO,
		false,
		CellManagerScript.LoadProfile.exterior_default(),
		[],
		true
	)
	assert_int(request_id).is_greater(0)

	var record: RefCounted = WorldObjectRecordScript.new()
	record.model_path = "meshes\\x\\registered_static.nif"
	record.source_type = &"static"
	record.spawn_route = WorldObjectRecordScript.SpawnRoute.STATIC_BATCH
	record.static_batch_allowed = true
	record.transform = Transform3D.IDENTITY

	var request: Variant = manager._async_requests[request_id]
	var payload_key := "meshes\\x\\registered_static.nif"
	request.payload.add_static_bucket(payload_key, RefCounted.new())

	var entry: Variant = CellManagerScript.InstantiationEntry.new()
	entry.request_id = request_id
	entry.world_object_record = record
	entry.model_path = str(record.get("model_path"))
	entry.cache_item_id = ""
	entry.type_name = "static"
	entry.load_profile = CellManagerScript.LoadProfile.exterior_default()

	assert_bool(manager._static_entry_bucket_ready(entry, request)).is_true()
