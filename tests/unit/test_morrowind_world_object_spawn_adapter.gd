extends GdUnitTestSuite

const CS := preload("res://src/core/coordinate_system.gd")
const MorrowindObjectSpawnAdapterScript := preload("res://src/core/world/morrowind/morrowind_object_spawn_adapter.gd")
const MorrowindWorldObjectSourceScript: Script = preload("res://src/core/world/morrowind/morrowind_world_object_source.gd")
const WorldObjectRecordScript: Script = preload("res://src/core/world/world_object_record.gd")


class FakeStaticRecord:
	extends RefCounted

	var record_id: String = "ex_test_01"
	var model: String = "meshes\\x\\ex_test_01.nif"


class FakeLightRecord:
	extends RefCounted

	var flags: int = 0


class FakeSourceBridge:
	extends RefCounted

	var call_count: int = 0
	var cached_call_count: int = 0
	var base_record := FakeStaticRecord.new()

	func get_source_base_record(ref_id: String, record_type_out: Array = []) -> Variant:
		call_count += 1
		if record_type_out.size() > 0:
			record_type_out[0] = "static"
		return base_record if ref_id == "ex_test_01" else null

	func get_source_base_record_cached(ref_id: String, record_type_out: Array = []) -> Variant:
		cached_call_count += 1
		if record_type_out.size() > 0:
			record_type_out[0] = "static"
		return base_record if ref_id == "ex_test_01" else null


class FakeInstantiator:
	extends RefCounted

	var last_type_name: String = ""
	var last_inst_route: String = ""
	var last_proximity_deferred: bool = false
	var captured_record: RefCounted = null
	var captured_grid: Vector2i = Vector2i.ZERO
	var captured_cache_item_id: String = ""
	var static_route_called: bool = false
	var node_route_called: bool = false
	var camera_position: Vector3 = Vector3.ZERO
	var load_lights: bool = true
	var load_npcs: bool = true
	var load_creatures: bool = true

	func set_source_spawn_diagnostics(type_name: String, route: String, proximity_deferred: bool = false) -> void:
		last_type_name = type_name
		if not route.is_empty():
			last_inst_route = route
		last_proximity_deferred = proximity_deferred

	func is_source_static_renderer_effective() -> bool:
		return true

	func get_source_spawn_camera_position() -> Vector3:
		return camera_position

	func should_source_load_lights() -> bool:
		return load_lights

	func should_source_load_npcs() -> bool:
		return load_npcs

	func should_source_load_creatures() -> bool:
		return load_creatures

	func instantiate_static_world_object_record(
		record: RefCounted,
		cell_grid: Vector2i = Vector2i.ZERO,
	) -> Node3D:
		static_route_called = true
		captured_record = record
		captured_grid = cell_grid
		last_type_name = str(record.get("source_type"))
		last_inst_route = "static_hot"
		return null

	func instantiate_node_world_object_record(
		record: RefCounted,
		cell_grid: Vector2i = Vector2i.ZERO,
		cache_item_id: String = "",
	) -> Node3D:
		node_route_called = true
		captured_record = record
		captured_grid = cell_grid
		captured_cache_item_id = cache_item_id
		last_type_name = str(record.get("source_type"))
		last_inst_route = "node_sync"
		return Node3D.new()

	func apply_source_metadata(_node: Node3D, _ref: Variant, _base_record: Variant, _model_path: String, _type_name: String = "") -> void:
		pass

	func uses_source_visual_proxy(_type_name: String) -> bool:
		return false

	func apply_source_visual_proxy_runtime(_node: Node3D, _ref: Variant, _cell_grid: Vector2i, _type_name: String) -> void:
		pass


func test_morrowind_record_translation_populates_spawn_metadata() -> void:
	var source: Variant = MorrowindWorldObjectSourceScript.new()
	var ref := CellReference.new()
	ref.ref_id = &"ex_test_01"
	ref.ref_num = 7
	ref.position = Vector3(70.0, 140.0, 210.0)
	ref.rotation = Vector3.ZERO
	ref.scale = 1.0
	var base := FakeStaticRecord.new()

	var record: WorldObjectRecord = source._make_record(Vector2i(1, -2), ref, base, "static")

	assert_that(record.object_id).is_equal(WorldObjectRecordScript.make_object_id(Vector2i(1, -2), "ex_test_01", 7))
	assert_that(record.record_id).is_equal(&"ex_test_01")
	assert_that(record.category).is_equal(WorldObjectRecord.Category.STATIC)
	assert_that(record.spawn_route).is_equal(WorldObjectRecord.SpawnRoute.STATIC_BATCH)
	assert_bool(record.static_batch_allowed).is_true()
	assert_that(record.adapter_payload_id).is_equal(record.object_id)
	assert_vector(record.transform.origin).is_equal_approx(CS.vector_to_godot(ref.position), Vector3.ONE * 0.001)


func test_morrowind_spawn_adapter_routes_static_batch_without_core_payload_lookup() -> void:
	var source: Variant = MorrowindWorldObjectSourceScript.new()
	var ref := CellReference.new()
	ref.ref_id = &"ex_test_01"
	ref.ref_num = 7
	var base := FakeStaticRecord.new()
	var record: WorldObjectRecord = source._make_record(Vector2i(1, -2), ref, base, "static")
	source._object_cache[record.object_id] = record

	var adapter: Variant = _new_spawn_adapter()
	adapter.configure(source)
	var instantiator := FakeInstantiator.new()
	var node: Node3D = adapter.instantiate_world_object(record, instantiator, Vector2i(1, -2), record.cache_item_id)

	assert_object(node).is_null()
	assert_bool(instantiator.static_route_called).is_true()
	assert_that(instantiator.captured_record).is_same(record)
	assert_that(instantiator.captured_grid).is_equal(Vector2i(1, -2))


func test_morrowind_spawn_adapter_routes_node_payload() -> void:
	var source: Variant = MorrowindWorldObjectSourceScript.new()
	var ref := CellReference.new()
	ref.ref_id = &"ex_test_01"
	ref.ref_num = 7
	var base := FakeStaticRecord.new()
	var record: WorldObjectRecord = source._make_record(Vector2i(1, -2), ref, base, "misc")
	source._object_cache[record.object_id] = record

	var adapter: Variant = _new_spawn_adapter()
	adapter.configure(source)
	var instantiator := FakeInstantiator.new()
	var node: Node3D = adapter.instantiate_world_object(record, instantiator, Vector2i(1, -2), record.cache_item_id)

	assert_object(node).is_not_null()
	node.queue_free()
	assert_bool(instantiator.node_route_called).is_true()
	assert_that(instantiator.captured_record).is_same(record)
	assert_that(instantiator.captured_grid).is_equal(Vector2i(1, -2))
	assert_str(instantiator.captured_cache_item_id).is_equal(record.cache_item_id)


func test_morrowind_spawn_adapter_resolves_legacy_source_ref_locally() -> void:
	var source := FakeSourceBridge.new()
	var adapter: Variant = _new_spawn_adapter()
	adapter.configure(source)
	var ref := CellReference.new()
	ref.ref_id = &"ex_test_01"
	var record_type: Array = [""]

	var resolved: Variant = adapter.resolve_source_reference_base_record(ref, record_type)

	assert_that(resolved).is_same(source.base_record)
	assert_str(record_type[0]).is_equal("static")
	assert_int(source.call_count).is_equal(1)
	assert_int(source.cached_call_count).is_equal(0)


func test_morrowind_spawn_adapter_resolves_cached_source_ref_locally() -> void:
	var source := FakeSourceBridge.new()
	var adapter: Variant = _new_spawn_adapter()
	adapter.configure(source)
	var ref := CellReference.new()
	ref.ref_id = &"ex_test_01"
	var record_type: Array = [""]

	var resolved: Variant = adapter.resolve_source_reference_base_record(ref, record_type, true)

	assert_that(resolved).is_same(source.base_record)
	assert_str(record_type[0]).is_equal("static")
	assert_int(source.call_count).is_equal(0)
	assert_int(source.cached_call_count).is_equal(1)


func test_morrowind_spawn_adapter_translates_light_animation_flags() -> void:
	var adapter: Variant = _new_spawn_adapter()
	var light := FakeLightRecord.new()

	light.flags = 0x0008
	assert_int(adapter._source_light_animation_for_record(light)).is_equal(WorldObjectRecordScript.LightAnimation.FLICKER)
	light.flags = 0x0040
	assert_int(adapter._source_light_animation_for_record(light)).is_equal(WorldObjectRecordScript.LightAnimation.FLICKER_SLOW)
	light.flags = 0x0080
	assert_int(adapter._source_light_animation_for_record(light)).is_equal(WorldObjectRecordScript.LightAnimation.PULSE)
	light.flags = 0x0100
	assert_int(adapter._source_light_animation_for_record(light)).is_equal(WorldObjectRecordScript.LightAnimation.PULSE_SLOW)
	light.flags = 0
	assert_int(adapter._source_light_animation_for_record(light)).is_equal(WorldObjectRecordScript.LightAnimation.NONE)


func _new_spawn_adapter() -> RefCounted:
	return MorrowindObjectSpawnAdapterScript.new()
