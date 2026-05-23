extends GdUnitTestSuite

const CellManagerScript := preload("res://src/core/world/cell_manager.gd")
const CellPreloaderScript := preload("res://src/core/world/cell_preloader.gd")
const ReferenceInstantiatorScript := preload("res://src/core/world/reference_instantiator.gd")
const WorldObjectRecordScript := preload("res://src/core/world/world_object_record.gd")

const GUARDED_FILES: Array[String] = [
	"res://src/core/world/cell_manager.gd",
	"res://src/core/world/cell_preloader.gd",
	"res://src/core/world/reference_instantiator.gd",
	"res://src/core/world/object_paging.gd",
	"res://src/core/world/native_impostor_renderer.gd",
	"res://src/core/world/distant_light_manager.gd",
]


class FakeWorldObjectSource:
	extends RefCounted

	var payload_lookup_count: int = 0

	func get_spawn_adapter_payload(_adapter_payload_id: StringName) -> Dictionary:
		payload_lookup_count += 1
		return {}


class FakeSpawnAdapter:
	extends RefCounted

	var called: bool = false
	var resolved_source_ref: Variant = null
	var resolved_cached: bool = false

	func instantiate_world_object(
		_record: RefCounted,
		_instantiator: RefCounted,
		_cell_grid: Vector2i = Vector2i.ZERO,
		_cache_item_id: String = "",
	) -> Node3D:
		called = true
		return Node3D.new()

	func resolve_source_reference_base_record(
		source_ref: Variant,
		record_type_out: Array = [],
		cached: bool = false,
	) -> Variant:
		resolved_source_ref = source_ref
		resolved_cached = cached
		if record_type_out.size() > 0:
			record_type_out[0] = "static"
		return {"record_id": "fake_static", "model": "fake.nif"}


class FakeModelLoader:
	extends RefCounted

	func request_model_async(
		_model_path: String,
		_item_id: String = "",
		_callback: Callable = Callable(),
		_instantiate_for_callback: bool = true,
	) -> bool:
		return true


func test_core_streaming_modules_do_not_call_esm_manager_directly() -> void:
	for path: String in GUARDED_FILES:
		var code := _read_without_comments(path)
		assert_bool("ESMManager." in code).override_failure_message(
			"%s must use WorldObjectSource/adapter APIs instead of ESMManager directly" % path
		).is_false()


func test_near_streaming_uses_world_object_payload_boundary() -> void:
	var cell_manager_code := _read_without_comments("res://src/core/world/cell_manager.gd")
	var instantiator_code := _read_without_comments("res://src/core/world/reference_instantiator.gd")
	var native_streaming_code := _read_without_comments("res://src/core/world/native_streaming_manager.gd")
	assert_bool("world_objects_to_classify" in cell_manager_code).is_true()
	assert_bool("request_world_cell_async" in cell_manager_code).is_true()
	assert_bool("request_world_cell_async" in native_streaming_code).is_true()
	assert_bool("resolve_gameplay_payload" in cell_manager_code).is_false()
	assert_bool("resolve_gameplay_payload" in instantiator_code).is_false()
	assert_bool("instantiate_world_object_record" in cell_manager_code).is_true()
	assert_bool("get_source_base_record" in cell_manager_code).override_failure_message(
		"CellManager must resolve source-shaped records through the spawn adapter"
	).is_false()
	assert_bool("get_source_base_record" in instantiator_code).override_failure_message(
		"ReferenceInstantiator must resolve source-shaped records through the spawn adapter"
	).is_false()


func test_cell_preloader_without_world_object_source_is_ready_no_legacy_global() -> void:
	var preloader: Variant = CellPreloaderScript.new()
	var model_loader := FakeModelLoader.new()
	preloader.configure(null, model_loader)

	preloader._begin_preload(Vector2i(9, -4), Time.get_ticks_msec())

	assert_bool(preloader.is_ready(Vector2i(9, -4))).is_true()


func test_cell_manager_delegates_source_record_lookup_to_spawn_adapter() -> void:
	var cell_manager := CellManagerScript.new()
	var adapter := FakeSpawnAdapter.new()
	cell_manager.set_world_object_spawn_adapter(adapter)
	var record_type: Array = [""]
	var source_ref := {"ref_id": "fake_ref"}

	var base_record: Variant = cell_manager.call("_resolve_source_reference_base_record", source_ref, record_type)

	assert_that(base_record).is_not_null()
	assert_str(record_type[0]).is_equal("static")
	assert_that(adapter.resolved_source_ref).is_same(source_ref)
	assert_bool(adapter.resolved_cached).is_false()


func test_reference_instantiator_delegates_record_payload_lookup_to_spawn_adapter() -> void:
	var instantiator := ReferenceInstantiatorScript.new()
	var source := FakeWorldObjectSource.new()
	var adapter := FakeSpawnAdapter.new()
	instantiator.set_world_object_source(source)
	instantiator.set_world_object_spawn_adapter(adapter)
	var record := WorldObjectRecordScript.new()
	record.object_id = &"test_object"
	record.source_type = &"static"

	var node := instantiator.instantiate_world_object_record(record, Vector2i.ZERO, "")

	assert_object(node).is_not_null()
	node.queue_free()
	assert_bool(adapter.called).is_true()
	assert_int(source.payload_lookup_count).is_equal(0)


func _read_without_comments(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	assert_object(file).is_not_null()
	var lines: PackedStringArray = PackedStringArray()
	while not file.eof_reached():
		var line := file.get_line()
		if line.strip_edges().begins_with("#"):
			continue
		lines.append(line)
	return "\n".join(lines)
