extends GdUnitTestSuite

const CellManagerScript: Script = preload("res://src/core/world/cell_manager.gd")
const ModelLoaderScript: Script = preload("res://src/core/world/model_loader.gd")
const WorldAssetProviderScript: Script = preload("res://src/core/world/world_asset_provider.gd")
const WorldSourceScript: Script = preload("res://src/core/world/world_source.gd")


class FakeAssetProvider:
	extends "res://src/core/world/world_asset_provider.gd"

	var packed_scene: PackedScene = PackedScene.new()
	var resource_requests := 0
	var conversion_requests := 0
	var parse_task_requests := 0
	var last_parse_processor: Variant = null
	var last_parse_model_id := ""
	var last_parse_item_id := ""

	func _init() -> void:
		source_name = "Fake Assets"
		var root := Node3D.new()
		root.name = "ProviderPackedScene"
		packed_scene.pack(root)
		root.free()

	func get_model_resource(model_id: String, _item_id: String = "") -> Resource:
		resource_requests += 1
		if model_id == "provider_scene":
			return packed_scene
		return null

	func has_model_resource(model_id: String, _item_id: String = "") -> bool:
		return model_id == "provider_scene"

	func create_model_scene(model_id: String, item_id: String = "") -> Node3D:
		conversion_requests += 1
		if model_id != "source_native":
			return null
		var node := Node3D.new()
		node.name = "Converted_%s_%s" % [model_id, item_id]
		return node

	func submit_model_parse_task(background_processor: Variant, model_id: String, item_id: String = "") -> int:
		parse_task_requests += 1
		last_parse_processor = background_processor
		last_parse_model_id = model_id
		last_parse_item_id = item_id
		return 77

	func is_model_parse_result_valid(parse_result: Variant) -> bool:
		return parse_result is Dictionary and bool(parse_result.get("valid", false))

	func get_model_parse_result_item_id(parse_result: Variant) -> String:
		return str(parse_result.get("item_id", ""))

	func create_model_scene_from_parse_result(parse_result: Variant) -> Node3D:
		if not is_model_parse_result_valid(parse_result):
			return null
		var node := Node3D.new()
		node.name = "Parsed_%s" % str(parse_result.get("item_id", ""))
		return node


class FakeWorldSource:
	extends "res://src/core/world/world_source.gd"

	var fake_asset_provider: FakeAssetProvider = FakeAssetProvider.new()

	func _init() -> void:
		asset_provider = fake_asset_provider


func test_model_loader_uses_provider_packed_scene_before_disk_or_source_conversion() -> void:
	var provider := FakeAssetProvider.new()
	var loader: Variant = ModelLoaderScript.new()
	loader.set_asset_provider(provider)

	var node: Node3D = loader.get_model("provider_scene")
	assert_object(node).is_not_null()
	assert_str(node.name).is_equal("ProviderPackedScene")
	assert_bool(loader.has_disk_cached("provider_scene")).is_true()
	assert_int(provider.resource_requests).is_equal(1)
	assert_int(provider.conversion_requests).is_equal(0)
	assert_int(int(loader.get_stats().get("models_from_provider", 0))).is_equal(1)
	node.free()


func test_model_loader_prebake_conversion_is_provider_owned() -> void:
	var provider := FakeAssetProvider.new()
	var loader: Variant = ModelLoaderScript.new()
	loader.enable_disk_cache = false
	loader.runtime_mode = false
	loader.set_asset_provider(provider)

	var node: Node3D = loader.get_model("source_native", "item_01")
	assert_object(node).is_not_null()
	assert_str(node.name).is_equal("Converted_source_native_item_01")
	assert_int(provider.conversion_requests).is_equal(1)
	node.free()


func test_model_loader_async_request_can_complete_from_provider_resource() -> void:
	var provider := FakeAssetProvider.new()
	var loader: Variant = ModelLoaderScript.new()
	loader.set_asset_provider(provider)
	var loaded_nodes: Array[Node3D] = []
	var callback := func(_model_path: String, _item_id: String, node: Node3D) -> void:
		loaded_nodes.append(node)

	var queued: bool = loader.request_model_async(
		"provider_scene",
		"",
		callback,
		true
	)

	assert_bool(queued).is_true()
	assert_int(loaded_nodes.size()).is_equal(1)
	assert_object(loaded_nodes[0]).is_not_null()
	assert_str(loaded_nodes[0].name).is_equal("ProviderPackedScene")
	loaded_nodes[0].free()


func test_cell_manager_world_source_wires_asset_provider_into_model_loader() -> void:
	var source := FakeWorldSource.new()
	var manager: Variant = CellManagerScript.new()

	manager.set_world_source(source)

	assert_object(manager._model_loader.get_asset_provider()).is_same(source.fake_asset_provider)


func test_cell_manager_source_parse_tasks_are_asset_provider_owned() -> void:
	var provider := FakeAssetProvider.new()
	var manager: Variant = CellManagerScript.new()
	var processor := Node.new()
	manager.set_asset_provider(provider)
	manager._background_processor = processor

	var task_id: int = manager.call("_submit_parse_task", "source_native", "item_02", 42)

	assert_int(task_id).is_equal(77)
	assert_int(provider.parse_task_requests).is_equal(1)
	assert_object(provider.last_parse_processor).is_same(processor)
	assert_str(provider.last_parse_model_id).is_equal("source_native")
	assert_str(provider.last_parse_item_id).is_equal("item_02")
	processor.free()


func test_cell_manager_source_parse_results_are_asset_provider_owned() -> void:
	var provider := FakeAssetProvider.new()
	var manager: Variant = CellManagerScript.new()
	manager.set_asset_provider(provider)
	var parse_result := {"valid": true, "item_id": "item_03"}

	assert_bool(manager.call("_is_provider_parse_result_valid", parse_result)).is_true()
	assert_str(manager.call("_get_provider_parse_result_item_id", parse_result)).is_equal("item_03")
	var node: Node3D = manager.call("_create_provider_model_scene_from_parse_result", parse_result)
	assert_object(node).is_not_null()
	assert_str(node.name).is_equal("Parsed_item_03")
	node.free()
