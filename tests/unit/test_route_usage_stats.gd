extends GdUnitTestSuite

const CellManagerScript: Script = preload("res://src/core/world/cell_manager.gd")
const ReferenceInstantiatorScript: Script = preload("res://src/core/world/reference_instantiator.gd")
const WorldCellManifestScript: Script = preload("res://src/core/world/world_cell_manifest.gd")
const WorldObjectRecordScript: Script = preload("res://src/core/world/world_object_record.gd")
const WorldSpaceHandleScript: Script = preload("res://src/core/world/transition/world_space_handle.gd")


class FakeBackgroundProcessor:
	extends Node

	signal task_completed(task_id: int, result: Variant)

	var next_task_id := 1

	func submit_task(_task: Callable) -> int:
		var id := next_task_id
		next_task_id += 1
		return id


class FakeObjectSource:
	extends "res://src/core/world/world_object_source.gd"

	var manifest: WorldCellManifest = WorldCellManifestScript.new(Vector2i.ZERO)
	var interior_manifest: WorldCellManifest = WorldCellManifestScript.new(Vector2i.ZERO)
	var space_manifest_requests := 0
	var last_space_handle: RefCounted = null

	func _init() -> void:
		var record: RefCounted = WorldObjectRecordScript.new()
		record.object_id = &"route:node:1"
		record.record_id = &"route_node"
		record.source_ref_id = &"route_node"
		record.cell_grid = Vector2i.ZERO
		record.transform = Transform3D(Basis.IDENTITY, Vector3(1.0, 0.0, -1.0))
		record.source_type = &"static"
		record.spawn_route = WorldObjectRecord.SpawnRoute.NODE
		record.category = WorldObjectRecord.Category.STATIC
		record.capability_flags = WorldObjectRecord.CAP_STATIC_VISUAL
		manifest.add_object(record)
		var interior_record: RefCounted = WorldObjectRecordScript.new()
		interior_record.object_id = &"route:interior:light:1"
		interior_record.record_id = &"route_light"
		interior_record.source_ref_id = &"route_light"
		interior_record.cell_grid = Vector2i.ZERO
		interior_record.transform = Transform3D(Basis.IDENTITY, Vector3.ZERO)
		interior_record.source_type = &"light"
		interior_record.spawn_route = WorldObjectRecord.SpawnRoute.LIGHT
		interior_record.category = WorldObjectRecord.Category.LIGHT
		interior_record.capability_flags = WorldObjectRecord.CAP_GAMEPLAY
		interior_manifest.cell_name = "Route Stats Interior"
		interior_manifest.add_object(interior_record)

	func get_cell_manifest(cell_grid: Vector2i) -> WorldCellManifest:
		return manifest if cell_grid == Vector2i.ZERO else null

	func get_interior_cell_manifest(cell_name: String) -> WorldCellManifest:
		return interior_manifest if cell_name.begins_with("Route Stats") else null

	func get_space_manifest(space_handle: RefCounted) -> Variant:
		space_manifest_requests += 1
		last_space_handle = space_handle
		if space_handle != null and space_handle.has_method("is_interior") and space_handle.call("is_interior"):
			return interior_manifest if str(space_handle.get("key")).begins_with("Route Stats") else null
		return null

	func get_object_record(object_id: StringName) -> Variant:
		for cell_manifest: WorldCellManifest in [manifest, interior_manifest]:
			for record: RefCounted in cell_manifest.objects:
				if record.get("object_id") == object_id:
					return record
		return null


class FakeSpawnAdapter:
	extends "res://src/core/world/world_object_spawn_adapter.gd"

	func instantiate_world_object(
		record: RefCounted,
		instantiator: RefCounted,
		_cell_grid: Vector2i = Vector2i.ZERO,
		_cache_item_id: String = "",
	) -> Node3D:
		var node := Node3D.new()
		node.name = str(record.get("object_id"))
		if instantiator.has_method("set_source_spawn_diagnostics"):
			instantiator.call("set_source_spawn_diagnostics", str(record.get("source_type")), "node_sync")
		return node


class FakeWorldSource:
	extends "res://src/core/world/world_source.gd"

	var fake_object_source: FakeObjectSource = FakeObjectSource.new()
	var fake_spawn_adapter: FakeSpawnAdapter = FakeSpawnAdapter.new()

	func _init() -> void:
		object_source = fake_object_source
		object_spawn_adapter = fake_spawn_adapter
		fake_spawn_adapter.configure(fake_object_source)


class FakeSourceReferenceSpawnAdapter:
	extends "res://src/core/world/world_object_spawn_adapter.gd"

	var light_record := LightRecord.new()
	var payloads_by_id: Dictionary = {}
	var payload_seen := false

	func _init() -> void:
		light_record.record_id = "route_light"
		light_record.radius = 64
		light_record.color = Color(1.0, 0.75, 0.45)
		light_record.flags = 0

	func resolve_source_reference_base_record(
		source_ref: Variant,
		record_type_out: Array = [],
		_cached: bool = false,
	) -> Variant:
		var ref_id := str(source_ref.get("ref_id")) if source_ref != null else ""
		if record_type_out.size() > 0:
			record_type_out[0] = "light"
		return light_record if ref_id == "route_light" else null

	func make_world_object_record_from_source_reference(
		source_ref: Variant,
		base_record: Variant,
		type_name: String,
		model_path: String,
		item_id: String,
		cache_item_id: String,
		_static_route: bool,
		cell_grid: Vector2i,
	) -> RefCounted:
		var record: RefCounted = WorldObjectRecordScript.new()
		record.object_id = WorldObjectRecord.make_object_id(cell_grid, str(source_ref.get("ref_id")), int(source_ref.get("ref_num")))
		record.record_id = StringName(item_id if not item_id.is_empty() else str(base_record.record_id))
		record.source_ref_id = source_ref.get("ref_id")
		record.cell_grid = cell_grid
		record.transform = Transform3D(Basis.IDENTITY, Vector3.ZERO)
		record.model_path = model_path
		record.model_item_id = item_id
		record.cache_item_id = cache_item_id
		record.source_type = StringName(type_name)
		record.category = WorldObjectRecord.Category.LIGHT
		record.spawn_route = WorldObjectRecord.SpawnRoute.LIGHT
		record.capability_flags = WorldObjectRecord.CAP_GAMEPLAY
		record.adapter_payload_id = record.object_id
		payloads_by_id[record.adapter_payload_id] = {
			"ref": source_ref,
			"base_record": base_record,
			"type_name": type_name,
		}
		return record

	func instantiate_world_object(
		record: RefCounted,
		instantiator: RefCounted,
		_cell_grid: Vector2i = Vector2i.ZERO,
		_cache_item_id: String = "",
	) -> Node3D:
		payload_seen = payloads_by_id.has(record.get("adapter_payload_id"))
		instantiator.call("set_source_spawn_diagnostics", str(record.get("source_type")), "light")
		var node := Node3D.new()
		node.name = str(record.get("object_id"))
		return node


func test_cell_manager_route_stats_expose_world_manifest_async_and_sync() -> void:
	var source := FakeWorldSource.new()
	var manager: Variant = CellManagerScript.new()
	manager.set_world_source(source)
	manager.set_background_processor(FakeBackgroundProcessor.new())

	var request_id: int = manager.request_exterior_cell_async(0, 0)
	assert_int(request_id).is_greater(0)

	var async_stats: Dictionary = manager.get_loading_stats()
	var async_routes: Dictionary = async_stats.get("route_usage", {})
	assert_int(int(async_routes.get("world_manifest_hits", 0))).is_equal(1)
	assert_int(int(async_routes.get("async_world_manifest_requests", 0))).is_equal(1)

	var node: Node3D = manager.load_exterior_cell(0, 0)
	assert_object(node).is_not_null()

	var sync_stats: Dictionary = manager.get_loading_stats()
	var sync_routes: Dictionary = sync_stats.get("route_usage", {})
	var instantiator_routes: Dictionary = sync_stats.get("instantiator_route_usage", {})
	assert_int(int(sync_routes.get("sync_world_manifest_exterior_cells", 0))).is_equal(1)
	assert_int(int(instantiator_routes.get("world_object_record_calls", 0))).is_equal(1)
	assert_bool(instantiator_routes.has("source_reference_calls")).is_false()
	node.free()


func test_cell_manager_route_stats_expose_interior_manifest_async_route() -> void:
	var source := FakeWorldSource.new()
	var manager: Variant = CellManagerScript.new()
	manager.set_world_source(source)
	manager.set_background_processor(FakeBackgroundProcessor.new())

	var request_id: int = manager.request_cell_async("Route Stats Interior")
	assert_int(request_id).is_greater(0)

	var stats: Dictionary = manager.get_loading_stats()
	var routes: Dictionary = stats.get("route_usage", {})
	assert_int(int(routes.get("world_manifest_hits", 0))).is_equal(1)
	assert_int(int(routes.get("async_world_manifest_interior_requests", 0))).is_equal(1)


func test_cell_manager_named_interior_world_space_async_uses_manifest_records_without_cell_record() -> void:
	var source := FakeWorldSource.new()
	var object_source: FakeObjectSource = source.fake_object_source
	var manager: Variant = CellManagerScript.new()
	manager.set_world_object_source(object_source)
	manager.set_world_object_spawn_adapter(source.fake_spawn_adapter)
	manager.set_background_processor(FakeBackgroundProcessor.new())
	var space_handle: RefCounted = WorldSpaceHandleScript.interior("Route Stats Interior")

	assert_bool(manager.has_method("request_world_space_async")).is_true()
	if not manager.has_method("request_world_space_async"):
		return
	var request_id: int = int(manager.call("request_world_space_async", space_handle, null))
	assert_int(request_id).is_greater(0)
	assert_int(object_source.space_manifest_requests).is_equal(1)
	assert_object(object_source.last_space_handle).is_same(space_handle)

	var request: Variant = manager._async_requests[request_id]
	assert_bool(request.uses_world_manifest).is_true()
	assert_object(request.cell_record).is_null()
	assert_int(request.world_objects_to_classify.size()).is_equal(1)

	assert_int(int(manager._process_request_classification_queue(100000, 10))).is_equal(1)
	var spawned := int(manager.process_async_instantiation(100.0, Vector3.ZERO, Vector3.FORWARD, false))
	assert_int(spawned).is_equal(1)

	var stats: Dictionary = manager.get_loading_stats()
	var routes: Dictionary = stats.get("route_usage", {})
	var instantiator_routes: Dictionary = stats.get("instantiator_route_usage", {})
	assert_int(int(routes.get("async_world_manifest_interior_requests", 0))).is_equal(1)
	assert_int(int(instantiator_routes.get("world_object_record_calls", 0))).is_equal(1)
	assert_bool(instantiator_routes.has("source_reference_calls")).is_false()


func test_cell_manager_route_stats_expose_interior_manifest_sync_route() -> void:
	var source := FakeWorldSource.new()
	var manager: Variant = CellManagerScript.new()
	manager.set_world_source(source)

	var node: Node3D = manager.load_cell("Route Stats Interior Sync")
	assert_object(node).is_not_null()

	var stats: Dictionary = manager.get_loading_stats()
	var routes: Dictionary = stats.get("route_usage", {})
	assert_int(int(routes.get("world_manifest_hits", 0))).is_equal(1)
	assert_int(int(routes.get("sync_world_manifest_interior_cells", 0))).is_equal(1)
	node.free()


func test_cell_manager_sync_interior_manifest_instantiates_world_object_records() -> void:
	var source := FakeWorldSource.new()
	var manager: Variant = CellManagerScript.new()
	manager.set_world_source(source)

	var node: Node3D = manager.load_cell("Route Stats Sync Light Interior")
	assert_object(node).is_not_null()
	assert_int(node.get_child_count()).is_equal(1)

	var stats: Dictionary = manager.get_loading_stats()
	var routes: Dictionary = stats.get("route_usage", {})
	var instantiator_routes: Dictionary = stats.get("instantiator_route_usage", {})
	assert_int(int(routes.get("sync_world_manifest_interior_cells", 0))).is_equal(1)
	assert_int(int(instantiator_routes.get("world_object_record_calls", 0))).is_equal(1)
	assert_bool(instantiator_routes.has("source_reference_calls")).is_false()
	node.free()


func test_cell_manager_interior_manifest_no_model_record_instantiates() -> void:
	var source := FakeWorldSource.new()
	var manager: Variant = CellManagerScript.new()
	manager.set_world_source(source)
	manager.set_background_processor(FakeBackgroundProcessor.new())

	var request_id: int = manager.request_cell_async("Route Stats Light Interior")
	assert_int(request_id).is_greater(0)

	var spawned := int(manager.process_async_instantiation(100.0, Vector3.ZERO, Vector3.FORWARD, false))
	assert_int(spawned).is_equal(1)

	var stats: Dictionary = manager.get_loading_stats()
	var instantiator_routes: Dictionary = stats.get("instantiator_route_usage", {})
	assert_int(int(instantiator_routes.get("world_object_record_calls", 0))).is_equal(1)
	assert_bool(instantiator_routes.has("source_reference_calls")).is_false()


func test_cell_manager_model_backed_source_ref_callback_queues_world_object_record_with_adapter_payload() -> void:
	var source := FakeWorldSource.new()
	var record: RefCounted = source.fake_object_source.interior_manifest.objects[0]
	record.model_path = "models\\route_light.nif"
	record.model_item_id = "route_light"
	record.cache_item_id = "route_light"
	var manager: Variant = CellManagerScript.new()
	manager.set_world_source(source)
	manager.set_background_processor(FakeBackgroundProcessor.new())
	manager._model_loader.runtime_mode = false

	var request_id: int = manager.request_cell_async("Route Stats Model Light Interior")
	assert_int(request_id).is_greater(0)
	var request: Variant = manager._async_requests[request_id]
	assert_int(int(manager._process_request_classification_queue(100000, 10))).is_equal(1)
	assert_int(request.references_to_process.size()).is_equal(1)

	manager._queue_references_for_model(request, str(record.get("model_path")))
	assert_int(request.references_to_process.size()).is_equal(0)

	var spawned := int(manager.process_async_instantiation(100.0, Vector3.ZERO, Vector3.FORWARD, false))
	assert_int(spawned).is_equal(1)

	var stats: Dictionary = manager.get_loading_stats()
	var instantiator_routes: Dictionary = stats.get("instantiator_route_usage", {})
	assert_int(int(instantiator_routes.get("world_object_record_calls", 0))).is_equal(1)
	assert_bool(instantiator_routes.has("source_reference_calls")).is_false()


func test_cell_manager_async_queue_fallback_wraps_legacy_ref_before_instantiating() -> void:
	var adapter := FakeSourceReferenceSpawnAdapter.new()
	var source := FakeWorldSource.new()
	var manager: Variant = CellManagerScript.new()
	manager.set_world_source(source)
	manager.set_world_object_spawn_adapter(adapter)
	manager.set_background_processor(FakeBackgroundProcessor.new())

	var request_id: int = manager.request_cell_async("Route Stats Queue Fallback")
	assert_int(request_id).is_greater(0)

	var ref := CellReference.new()
	ref.ref_id = &"route_light"
	ref.ref_num = 77
	ref.position = Vector3.ZERO
	var queued := bool(manager._queue_instantiation(request_id, ref, "", "", "", "light"))
	assert_bool(queued).is_true()

	var spawned := int(manager.process_async_instantiation(100.0, Vector3.ZERO, Vector3.FORWARD, false))
	assert_int(spawned).is_equal(2)
	assert_bool(adapter.payload_seen).is_true()

	var stats: Dictionary = manager.get_loading_stats()
	var instantiator_routes: Dictionary = stats.get("instantiator_route_usage", {})
	assert_int(int(instantiator_routes.get("world_object_record_calls", 0))).is_equal(2)
	assert_bool(instantiator_routes.has("source_reference_calls")).is_false()


func test_reference_instantiator_world_object_record_result_envelopes_diagnostics() -> void:
	var source := FakeWorldSource.new()
	var instantiator: Variant = ReferenceInstantiatorScript.new()
	instantiator.set_world_object_source(source.fake_object_source)
	instantiator.set_world_object_spawn_adapter(source.fake_spawn_adapter)

	var record: RefCounted = source.fake_object_source.manifest.objects[0]
	var result: Variant = instantiator.instantiate_world_object_record_result(record)
	var node: Node3D = result.get("node") as Node3D

	assert_object(node).is_not_null()
	assert_str(str(result.get("type_name"))).is_equal("static")
	assert_str(str(result.get("route"))).is_equal("node_sync")
	assert_bool(bool(result.get("proximity_deferred"))).is_false()

	var routes: Dictionary = instantiator.get_route_usage_stats()
	assert_int(int(routes.get("world_object_record_calls", 0))).is_equal(1)
	node.free()


func test_reference_instantiator_legacy_source_reference_api_stays_deleted() -> void:
	var instantiator: Variant = ReferenceInstantiatorScript.new()

	assert_bool(instantiator.has_method("instantiate_reference")).is_false()
	assert_bool(instantiator.has_method("instantiate_source_reference_result")).is_false()
	var routes: Dictionary = instantiator.get_route_usage_stats()
	assert_bool(routes.has("source_reference_calls")).is_false()
