extends GdUnitTestSuite

const CellManagerScript: Script = preload("res://src/core/world/cell_manager.gd")
const DistantLightManagerScript: Script = preload("res://src/core/world/distant_light_manager.gd")
const NativeStreamingManagerScript: Script = preload("res://src/core/world/native_streaming_manager.gd")
const ReferenceInstantiatorScript: Script = preload("res://src/core/world/reference_instantiator.gd")
const LaPalmaDataProviderScript: Script = preload("res://src/core/world/lapalma_data_provider.gd")
const WorldAssetProviderScript: Script = preload("res://src/core/world/world_asset_provider.gd")
const WorldCellManifestScript: Script = preload("res://src/core/world/world_cell_manifest.gd")
const WorldCoordinateMapperScript: Script = preload("res://src/core/world/world_coordinate_mapper.gd")
const WorldDataProviderScript: Script = preload("res://src/core/world/world_data_provider.gd")
const WorldObjectRecordScript: Script = preload("res://src/core/world/world_object_record.gd")


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
	var manifest_requests := 0
	var records_by_id: Dictionary = {}
	var payloads_by_id: Dictionary = {}

	func _init() -> void:
		_add_record(
			&"fake:static:1",
			&"fake_static_record",
			&"static",
			WorldObjectRecord.Category.STATIC,
			WorldObjectRecord.SpawnRoute.NODE,
			WorldObjectRecord.CAP_STATIC_VISUAL | WorldObjectRecord.CAP_COLLISION,
			Transform3D(Basis.IDENTITY, Vector3(4.0, 0.0, -4.0)),
			"fake_static_model",
			{"source_kind": "static_visual", "collision": true}
		)
		_add_record(
			&"fake:container:1",
			&"fake_container_record",
			&"container",
			WorldObjectRecord.Category.CONTAINER,
			WorldObjectRecord.SpawnRoute.NODE,
			WorldObjectRecord.CAP_GAMEPLAY | WorldObjectRecord.CAP_STATIC_VISUAL,
			Transform3D(Basis.IDENTITY, Vector3(5.0, 0.0, -5.0)),
			"fake_container_model",
			{"source_kind": "interactive", "interaction_kind": "inspect"}
		)
		_add_record(
			&"fake:actor:1",
			&"fake_actor_record",
			&"actor",
			WorldObjectRecord.Category.NPC,
			WorldObjectRecord.SpawnRoute.ACTOR,
			WorldObjectRecord.CAP_GAMEPLAY,
			Transform3D(Basis.IDENTITY, Vector3(6.0, 0.0, -6.0)),
			"",
			{"source_kind": "actor", "interaction_kind": "talk"}
		)
		var light: RefCounted = _add_record(
			&"fake:light:1",
			&"fake_light_record",
			&"light",
			WorldObjectRecord.Category.LIGHT,
			WorldObjectRecord.SpawnRoute.LIGHT,
			WorldObjectRecord.CAP_GAMEPLAY | WorldObjectRecord.CAP_DISTANT_LIGHT,
			Transform3D(Basis.IDENTITY, Vector3(8.0, 3.0, -8.0)),
			"",
			{"source_kind": "light"}
		)
		light.light_color = Color(1.0, 0.85, 0.5)
		light.light_radius = 12.0

	func get_cell_manifest(cell_grid: Vector2i) -> WorldCellManifest:
		manifest_requests += 1
		return manifest if cell_grid == Vector2i.ZERO else null

	func get_object_record(object_id: StringName) -> Variant:
		return records_by_id.get(object_id)

	func get_spawn_adapter_payload(adapter_payload_id: StringName) -> Dictionary:
		return payloads_by_id.get(adapter_payload_id, {})

	func _add_record(
		object_id: StringName,
		record_id: StringName,
		source_type: StringName,
		category: int,
		spawn_route: int,
		capability_flags: int,
		transform: Transform3D,
		model_path: String,
		payload: Dictionary,
	) -> RefCounted:
		var record := WorldObjectRecordScript.new()
		record.object_id = object_id
		record.record_id = record_id
		record.source_ref_id = record_id
		record.cell_grid = Vector2i.ZERO
		record.transform = transform
		record.model_path = model_path
		record.model_item_id = str(record_id)
		record.cache_item_id = str(record_id)
		record.source_type = source_type
		record.spawn_route = spawn_route
		record.category = category
		record.capability_flags = capability_flags
		record.adapter_payload_id = object_id
		manifest.add_object(record)
		records_by_id[object_id] = record
		payloads_by_id[object_id] = payload
		return record


class FakeAssetProvider:
	extends "res://src/core/world/world_asset_provider.gd"

	var packed_scene: PackedScene = PackedScene.new()
	var resource_requests := 0

	func _init() -> void:
		source_name = "Fake Asset Provider"
		var root := Node3D.new()
		root.name = "FakeProviderModel"
		packed_scene.pack(root)
		root.free()

	func has_model_resource(model_id: String, _item_id: String = "") -> bool:
		return model_id.begins_with("fake_")

	func get_model_resource(model_id: String, _item_id: String = "") -> Resource:
		resource_requests += 1
		if model_id.begins_with("fake_"):
			return packed_scene
		return null

	func create_model_scene(model_id: String, _item_id: String = "") -> Node3D:
		if not model_id.begins_with("fake_"):
			return null
		var node := Node3D.new()
		node.name = "Created_%s" % model_id
		return node


class FakeTerrainProvider:
	extends "res://src/core/world/world_data_provider.gd"

	func _init() -> void:
		world_name = "Fake Terrain"
		cell_size = 42.0
		region_size = 32
		vertex_spacing = 1.0

	func initialize() -> Error:
		return OK

	func has_terrain_at_region(region_coord: Vector2i) -> bool:
		return region_coord == Vector2i.ZERO

	func get_all_terrain_regions() -> Array[Vector2i]:
		return [Vector2i.ZERO]


class FakeSpawnAdapter:
	extends "res://src/core/world/world_object_spawn_adapter.gd"

	var spawned_count := 0
	var route_counts: Dictionary = {}
	var metadata_attachment_count := 0

	func instantiate_world_object(
		record: RefCounted,
		instantiator: RefCounted,
		_cell_grid: Vector2i = Vector2i.ZERO,
		_cache_item_id: String = "",
	) -> Node3D:
		spawned_count += 1
		var route_name := _route_name(int(record.get("spawn_route")))
		route_counts[route_name] = int(route_counts.get(route_name, 0)) + 1
		var payload := object_source.call("get_spawn_adapter_payload", record.get("adapter_payload_id")) if object_source != null else {}
		var node := Node3D.new()
		node.name = str(record.get("object_id"))
		node.transform = record.get("transform") as Transform3D
		node.set_meta("source_type", str(record.get("source_type")))
		node.set_meta("spawn_route", route_name)
		node.set_meta("collision_capable", (int(record.get("capability_flags")) & WorldObjectRecord.CAP_COLLISION) != 0)
		if payload.has("source_kind"):
			node.set_meta("source_kind", str(payload.get("source_kind")))
		if payload.has("interaction_kind"):
			node.set_meta("interaction_kind", str(payload.get("interaction_kind")))
			metadata_attachment_count += 1
		if int(record.get("category")) == WorldObjectRecord.Category.LIGHT:
			node.set_meta("light_radius", float(record.get("light_radius")))
			node.set_meta("light_color", record.get("light_color"))
		instantiator.set("last_type_name", str(record.get("source_type")))
		instantiator.set("last_inst_route", route_name)
		return node

	func _route_name(spawn_route: int) -> String:
		match spawn_route:
			WorldObjectRecord.SpawnRoute.STATIC_BATCH:
				return "static_visual"
			WorldObjectRecord.SpawnRoute.NODE:
				return "node"
			WorldObjectRecord.SpawnRoute.LIGHT:
				return "light"
			WorldObjectRecord.SpawnRoute.ACTOR:
				return "actor"
			WorldObjectRecord.SpawnRoute.SKIP:
				return "skip"
			_:
				return "unknown"


class FakeWorldSource:
	extends "res://src/core/world/world_source.gd"

	var fake_asset_provider: FakeAssetProvider = FakeAssetProvider.new()

	func _init() -> void:
		source_id = &"fake"
		display_name = "Fake Source"
		coordinate_mapper = WorldCoordinateMapperScript.new()
		coordinate_mapper.cell_size_meters = 42.0
		object_source = FakeObjectSource.new()
		object_spawn_adapter = FakeSpawnAdapter.new()
		object_spawn_adapter.configure(object_source)
		terrain_provider = FakeTerrainProvider.new()
		asset_provider = fake_asset_provider


class FakeTerrainOnlyWorldSource:
	extends "res://src/core/world/world_source.gd"

	func _init() -> void:
		source_id = &"terrain_only"
		display_name = "Terrain Only"
		terrain_provider = FakeTerrainProvider.new()


func test_world_source_contract_exposes_required_providers() -> void:
	var source := FakeWorldSource.new()
	assert_bool(source.is_configured()).is_true()
	assert_bool(source.is_object_streaming_configured()).is_true()
	assert_bool(source.is_terrain_configured()).is_true()
	assert_float(source.get_coordinate_mapper().get_cell_size_meters()).is_equal(42.0)
	assert_object(source.get_object_source().get_cell_manifest(Vector2i.ZERO)).is_not_null()
	assert_object(source.get_object_spawn_adapter()).is_not_null()
	assert_object(source.get_terrain_provider()).is_not_null()
	assert_object(source.get_asset_provider()).is_not_null()


func test_world_source_separates_terrain_and_object_streaming_capabilities() -> void:
	var source := FakeTerrainOnlyWorldSource.new()
	assert_bool(source.is_configured()).is_true()
	assert_bool(source.is_terrain_configured()).is_true()
	assert_bool(source.is_object_streaming_configured()).is_false()
	assert_object(source.get_terrain_provider()).is_not_null()
	assert_object(source.get_object_source()).is_null()
	assert_object(source.get_object_spawn_adapter()).is_null()
	assert_object(source.get_asset_provider()).is_null()


func test_native_streaming_manager_rejects_missing_source() -> void:
	var manager: Variant = NativeStreamingManagerScript.new()
	var err: int = manager.initialize(CellManagerScript.new(), null)
	assert_int(err).is_not_equal(OK)


func test_native_streaming_manager_rejects_terrain_only_source_for_object_streaming() -> void:
	var manager: Variant = NativeStreamingManagerScript.new()
	manager.set_world_source(FakeTerrainOnlyWorldSource.new())
	var err: int = manager.initialize(CellManagerScript.new(), null)
	assert_int(err).is_not_equal(OK)


func test_lapalma_remains_world_data_provider_without_morrowind_object_contracts() -> void:
	var data_path := "user://lapalma_boundary_test"
	var native_dir := ProjectSettings.globalize_path(data_path)
	DirAccess.make_dir_recursive_absolute(native_dir)
	var metadata_path := data_path.path_join("metadata.json")
	var metadata := {
		"world_name": "La Palma Boundary Smoke",
		"vertex_spacing": 7.0,
		"region_size": 6,
		"sea_level": 0.0,
		"world_width_m": 42.0,
		"world_height_m": 84.0,
		"num_regions_x": 1,
		"num_regions_y": 1,
		"regions": [
			{"x": 2, "y": -3, "file": "region_2_-3.raw"},
		],
	}
	var file := FileAccess.open(metadata_path, FileAccess.WRITE)
	assert_object(file).is_not_null()
	file.store_string(JSON.stringify(metadata))
	file.close()

	var provider: WorldDataProvider = LaPalmaDataProviderScript.new(data_path)
	assert_int(provider.initialize()).is_equal(OK)
	assert_str(provider.world_name).is_equal("La Palma Boundary Smoke")
	assert_float(provider.get_cell_size_meters()).is_equal(42.0)
	assert_bool(provider.has_terrain_at_region(Vector2i(2, -3))).is_true()
	assert_bool(provider.has_terrain_at_region(Vector2i.ZERO)).is_false()

	var source := FakeTerrainOnlyWorldSource.new()
	source.terrain_provider = provider
	assert_bool(source.is_configured()).is_true()
	assert_bool(source.is_terrain_configured()).is_true()
	assert_bool(source.is_object_streaming_configured()).is_false()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(metadata_path))


func test_native_streaming_manager_accepts_fake_non_morrowind_source() -> void:
	var manager: Variant = NativeStreamingManagerScript.new()
	var source := FakeWorldSource.new()
	manager.set_world_source(source)
	var err: int = manager.initialize(CellManagerScript.new(), null)
	assert_int(err).is_equal(OK)
	assert_float(manager.get_coordinate_mapper().get_cell_size_meters()).is_equal(42.0)


func test_fake_asset_provider_supplies_source_owned_models() -> void:
	var source := FakeWorldSource.new()
	var manager: Variant = CellManagerScript.new()
	manager.set_world_source(source)

	var node: Node3D = manager._model_loader.get_model("fake_static_model", "fake_static_record")

	assert_object(node).is_not_null()
	assert_str(node.name).is_equal("FakeProviderModel")
	assert_int(source.fake_asset_provider.resource_requests).is_equal(1)
	node.free()


func test_distant_lights_use_provider_coordinate_mapper_for_pages() -> void:
	var mapper: RefCounted = WorldCoordinateMapperScript.new()
	mapper.cell_size_meters = 42.0
	var lights: Variant = DistantLightManagerScript.new()
	lights.set_coordinate_mapper(mapper)

	assert_that(lights._page_key_for_position(Vector3(260.0, 0.0, 90.0))).is_equal(Vector2i(1, -1))
	assert_vector(lights._page_center_for_key(Vector2i(1, -1))).is_equal_approx(Vector3(252.0, 0.0, 84.0), Vector3.ONE * 0.001)
	assert_float(lights._cell_radius_to_distance(3)).is_equal(126.0)
	assert_float(lights._page_visibility_extra_margin()).is_equal(252.0)


func test_native_streaming_manager_rejects_source_without_spawn_adapter() -> void:
	var manager: Variant = NativeStreamingManagerScript.new()
	var source := FakeWorldSource.new()
	source.object_spawn_adapter = null
	manager.set_world_source(source)
	var err: int = manager.initialize(CellManagerScript.new(), null)
	assert_int(err).is_not_equal(OK)


func test_cell_manager_world_cell_async_uses_fake_records_without_legacy_cell() -> void:
	var source := FakeWorldSource.new()
	var object_source: FakeObjectSource = source.get_object_source() as FakeObjectSource
	var manager: Variant = CellManagerScript.new()
	manager.set_world_source(source)
	manager.set_background_processor(FakeBackgroundProcessor.new())

	var request_id: int = manager.request_world_cell_async(Vector2i.ZERO)
	assert_int(request_id).is_greater(0)
	assert_int(object_source.manifest_requests).is_equal(1)

	manager._process_request_classification_queue(100000, 10)
	var payload: Variant = manager.get_async_payload(request_id)
	assert_object(payload).is_not_null()
	assert_int(int(payload.stats.get("interactive_refs", 0))).is_equal(3)
	assert_int(int(payload.stats.get("light_refs", 0))).is_equal(1)
	assert_bool(manager.is_async_visual_playable(request_id)).is_true()


func test_cell_manager_exterior_async_prefers_world_manifest_without_legacy_cell() -> void:
	var source := FakeWorldSource.new()
	var object_source: FakeObjectSource = source.get_object_source() as FakeObjectSource
	var manager: Variant = CellManagerScript.new()
	manager.set_world_source(source)
	manager.set_background_processor(FakeBackgroundProcessor.new())

	var request_id: int = manager.request_exterior_cell_async(0, 0)

	assert_int(request_id).is_greater(0)
	assert_int(object_source.manifest_requests).is_equal(1)
	manager._process_request_classification_queue(100000, 10)
	var payload: Variant = manager.get_async_payload(request_id)
	assert_object(payload).is_not_null()
	assert_int(int(payload.stats.get("interactive_refs", 0))).is_equal(3)
	assert_int(int(payload.stats.get("light_refs", 0))).is_equal(1)


func test_cell_manager_sync_exterior_uses_world_manifest_without_legacy_cell() -> void:
	var source := FakeWorldSource.new()
	var object_source: FakeObjectSource = source.get_object_source() as FakeObjectSource
	var adapter: FakeSpawnAdapter = source.get_object_spawn_adapter() as FakeSpawnAdapter
	var manager: Variant = CellManagerScript.new()
	manager.set_world_source(source)

	var node: Node3D = manager.load_exterior_cell(0, 0)

	assert_object(node).is_not_null()
	assert_int(object_source.manifest_requests).is_equal(1)
	assert_int(adapter.spawned_count).is_equal(4)
	assert_int(node.get_child_count()).is_equal(4)
	assert_int(int(adapter.route_counts.get("node", 0))).is_equal(2)
	assert_int(int(adapter.route_counts.get("actor", 0))).is_equal(1)
	assert_int(int(adapter.route_counts.get("light", 0))).is_equal(1)
	assert_int(adapter.metadata_attachment_count).is_equal(2)
	assert_bool(node.has_meta("world_cell_manifest")).is_true()
	var static_node := _find_child_named(node, "fake:static:1")
	var container_node := _find_child_named(node, "fake:container:1")
	var actor_node := _find_child_named(node, "fake:actor:1")
	var light_node := _find_child_named(node, "fake:light:1")
	assert_object(static_node).is_not_null()
	assert_bool(bool(static_node.get_meta("collision_capable"))).is_true()
	assert_object(container_node).is_not_null()
	assert_str(str(container_node.get_meta("interaction_kind"))).is_equal("inspect")
	assert_object(actor_node).is_not_null()
	assert_str(str(actor_node.get_meta("spawn_route"))).is_equal("actor")
	assert_object(light_node).is_not_null()
	assert_float(float(light_node.get_meta("light_radius"))).is_equal(12.0)
	node.free()


func test_cell_manager_metadata_only_exterior_uses_world_manifest_without_legacy_cell() -> void:
	var source := FakeWorldSource.new()
	var object_source: FakeObjectSource = source.get_object_source() as FakeObjectSource
	var manager: Variant = CellManagerScript.new()
	manager.set_world_source(source)

	var node: Node3D = manager.load_exterior_cell_metadata_only(0, 0)

	assert_object(node).is_not_null()
	assert_int(object_source.manifest_requests).is_equal(1)
	assert_bool(node.has_meta("world_cell_manifest")).is_true()
	assert_bool(bool(node.get_meta("aaa_mode"))).is_true()
	node.free()


func test_fake_non_morrowind_source_instantiates_without_legacy_assets() -> void:
	var source := FakeWorldSource.new()
	var object_source: FakeObjectSource = source.get_object_source() as FakeObjectSource
	var adapter: FakeSpawnAdapter = source.get_object_spawn_adapter() as FakeSpawnAdapter
	var manager: Variant = CellManagerScript.new()
	manager.set_world_source(source)
	manager.set_background_processor(FakeBackgroundProcessor.new())
	manager.set_camera_position(Vector3.ZERO)

	var request_id: int = manager.request_world_cell_async(Vector2i.ZERO)
	assert_int(request_id).is_greater(0)
	manager._process_request_classification_queue(100000, 10)
	assert_int(manager.get_instantiation_queue_size()).is_greater(0)

	var instantiator: Variant = ReferenceInstantiatorScript.new()
	instantiator.set_world_object_source(object_source)
	instantiator.set_world_object_spawn_adapter(adapter)
	var record := object_source.manifest.objects[0] as RefCounted
	var node: Node3D = instantiator.instantiate_world_object_record(record, Vector2i.ZERO, "")

	assert_object(node).is_not_null()
	assert_str(str(node.get_meta("source_type"))).is_equal("static")
	assert_bool(bool(node.get_meta("collision_capable"))).is_true()
	assert_int(adapter.spawned_count).is_equal(1)
	node.free()


func _find_child_named(parent: Node, child_name: String) -> Node:
	for child: Node in parent.get_children():
		if child.name == child_name:
			return child
	return null
