extends GdUnitTestSuite

const CS := preload("res://src/core/coordinate_system.gd")
const CarryControllerScript := preload("res://src/core/interaction/carry_controller.gd")
const CarryableBodyFactoryScript := preload("res://src/core/interaction/carryable_body_factory.gd")
const CarryableRegistryScript := preload("res://src/core/interaction/carryable_registry.gd")
const InteractionRaycasterScript := preload("res://src/core/interaction/interaction_raycaster.gd")
const MWCarryableRegistryScript := preload("res://src/core/interaction/morrowind/mw_carryable_registry.gd")
const PickupInteractableScript := preload("res://src/core/interaction/morrowind/pickup_interactable.gd")
const MorrowindObjectSpawnAdapterScript := preload("res://src/core/world/morrowind/morrowind_object_spawn_adapter.gd")
const MorrowindWorldObjectSourceScript: Script = preload("res://src/core/world/morrowind/morrowind_world_object_source.gd")
const NativeStreamingManagerScript := preload("res://src/core/world/native_streaming_manager.gd")
const WorldObjectRecordScript: Script = preload("res://src/core/world/world_object_record.gd")


class FakeStaticRecord:
	extends RefCounted

	var record_id: String = "ex_test_01"
	var model: String = "meshes\\x\\ex_test_01.nif"
	var weight: float = 1.0


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
	var static_renderer_effective: bool = true
	var visual_proxy_enabled: bool = false
	var load_lights: bool = true
	var load_npcs: bool = true
	var load_creatures: bool = true
	var next_node: Node3D = null
	var door_calls: int = 0
	var last_door_key: String = ""
	var last_interaction_area: Area3D = null
	var ensured_proxy_record: RefCounted = null
	var ensured_proxy_type_name: String = ""
	var ensured_proxy_cache_item_id: String = ""
	var applied_proxy_record: RefCounted = null
	var applied_proxy_type_name: String = ""

	func set_source_spawn_diagnostics(type_name: String, route: String, proximity_deferred: bool = false) -> void:
		last_type_name = type_name
		if not route.is_empty():
			last_inst_route = route
		last_proximity_deferred = proximity_deferred

	func is_source_static_renderer_effective() -> bool:
		return static_renderer_effective

	func get_source_spawn_camera_position() -> Vector3:
		return camera_position

	func should_source_load_lights() -> bool:
		return load_lights

	func instantiate_source_light_record(_record: RefCounted, _light_record: Variant) -> Node3D:
		last_type_name = "light"
		last_inst_route = "light"
		return Node3D.new()

	func instantiate_source_actor_record(_record: RefCounted, _actor_record: Variant, actor_type: String) -> Node3D:
		last_type_name = actor_type
		last_inst_route = "actor"
		return Node3D.new()

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
		if next_node != null:
			var node := next_node
			next_node = null
			return node
		return Node3D.new()

	func apply_source_metadata(_node: Node3D, _ref: Variant, _base_record: Variant, _model_path: String, _type_name: String = "") -> void:
		pass

	func uses_source_visual_proxy(_type_name: String) -> bool:
		return visual_proxy_enabled

	func ensure_source_visual_proxy_for_record(record: RefCounted, type_name: String, cache_item_id: String = "") -> bool:
		ensured_proxy_record = record
		ensured_proxy_type_name = type_name
		ensured_proxy_cache_item_id = cache_item_id
		return true

	func apply_source_visual_proxy_runtime_for_record(node: Node3D, record: RefCounted, type_name: String) -> void:
		applied_proxy_record = record
		applied_proxy_type_name = type_name
		node.set_meta("source_key", str(record.get("source_key")))

	func generate_source_interaction_area(root: Node3D, _model_path: String = "") -> Area3D:
		var area := Area3D.new()
		area.name = "InteractionArea"
		area.collision_layer = 1 << 2
		area.collision_mask = 0
		area.monitoring = false
		area.monitorable = false
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3.ONE
		shape.shape = box
		area.add_child(shape)
		root.add_child(area)
		last_interaction_area = area
		return area

	func get_source_door_activated_handler() -> Callable:
		return Callable(self, "_on_door_activated")

	func _on_door_activated(door_key: String, _door_record: Variant, _player: Node3D) -> void:
		door_calls += 1
		last_door_key = door_key

	func attach_source_carryable_light_source(_instance: Node3D, _base_record: Variant) -> void:
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


func test_morrowind_record_translation_marks_carryables_as_gameplay_collision_nodes() -> void:
	_reset_carryable_registry()
	var source: Variant = MorrowindWorldObjectSourceScript.new()
	var ref := CellReference.new()
	ref.ref_id = &"misc_test_01"
	ref.ref_num = 11
	ref.position = Vector3.ZERO
	ref.rotation = Vector3.ZERO
	ref.scale = 1.0
	var base := MiscRecord.new()
	base.record_id = "misc_test_01"
	base.name = "Test Item"
	base.model = "meshes\\o\\test_item.nif"
	base.weight = 1.25

	var record: WorldObjectRecord = source._make_record(Vector2i(0, 0), ref, base, "misc")

	assert_int(record.spawn_route).is_equal(WorldObjectRecordScript.SpawnRoute.NODE)
	assert_float(record.proximity_radius_m).is_equal_approx(25.0, 0.001)
	assert_bool(record.has_capability(WorldObjectRecordScript.CAP_GAMEPLAY)).is_true()
	assert_bool(record.has_capability(WorldObjectRecordScript.CAP_STATIC_VISUAL)).is_true()
	assert_bool(record.has_capability(WorldObjectRecordScript.CAP_COLLISION)).is_true()


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


func test_morrowind_spawn_adapter_requests_visual_proxy_from_record_identity() -> void:
	var adapter: Variant = _new_spawn_adapter()
	var instantiator := FakeInstantiator.new()
	instantiator.visual_proxy_enabled = true
	instantiator.camera_position = Vector3(1000.0, 0.0, 1000.0)
	var ref := CellReference.new()
	ref.ref_id = &"misc_test_01"
	ref.ref_num = 17
	ref.position = Vector3.ZERO
	var base := FakeStaticRecord.new()
	var record: RefCounted = adapter.make_world_object_record_from_source_reference(
		ref,
		base,
		"static",
		base.model,
		base.record_id,
		base.record_id,
		false,
		Vector2i(3, 4),
	)
	record.set("proximity_radius_m", 1.0)

	var node: Node3D = adapter.instantiate_world_object(record, instantiator, Vector2i(3, 4), record.get("cache_item_id"))

	assert_object(node).is_null()
	assert_that(instantiator.ensured_proxy_record).is_same(record)
	assert_str(instantiator.ensured_proxy_type_name).is_equal("static")
	assert_str(instantiator.ensured_proxy_cache_item_id).is_equal(base.record_id)
	assert_str(str(record.get("source_key"))).is_equal("static:%s" % str(record.get("object_id")))


func test_morrowind_spawn_adapter_applies_visual_proxy_runtime_from_record_identity() -> void:
	var adapter: Variant = _new_spawn_adapter()
	var instantiator := FakeInstantiator.new()
	instantiator.visual_proxy_enabled = true
	instantiator.camera_position = Vector3.ZERO
	instantiator.next_node = Node3D.new()
	var ref := CellReference.new()
	ref.ref_id = &"misc_test_01"
	ref.ref_num = 19
	ref.position = Vector3.ZERO
	var base := FakeStaticRecord.new()
	var record: RefCounted = adapter.make_world_object_record_from_source_reference(
		ref,
		base,
		"static",
		base.model,
		base.record_id,
		base.record_id,
		false,
		Vector2i(3, 4),
	)

	var node: Node3D = adapter.instantiate_world_object(record, instantiator, Vector2i(3, 4), record.get("cache_item_id"))

	assert_object(node).is_not_null()
	assert_that(instantiator.applied_proxy_record).is_same(record)
	assert_str(instantiator.applied_proxy_type_name).is_equal("static")
	assert_str(str(node.get_meta("source_key"))).is_equal(str(record.get("source_key")))
	node.free()


func test_morrowind_spawn_adapter_does_not_defer_light_when_static_renderer_disabled() -> void:
	var adapter: Variant = _new_spawn_adapter()
	var instantiator := FakeInstantiator.new()
	instantiator.static_renderer_effective = false
	instantiator.camera_position = Vector3(1000.0, 0.0, 1000.0)
	var ref := CellReference.new()
	ref.ref_id = &"light_test_01"
	ref.ref_num = 13
	ref.position = Vector3.ZERO
	var light := LightRecord.new()
	light.record_id = "light_test_01"
	light.radius = 64
	light.color = Color.WHITE
	light.flags = 0
	var record: RefCounted = adapter.make_world_object_record_from_source_reference(
		ref,
		light,
		"light",
		"",
		light.record_id,
		light.record_id,
		false,
		Vector2i.ZERO,
	)

	var node: Node3D = adapter.instantiate_world_object(record, instantiator, Vector2i.ZERO, "")

	assert_object(node).is_not_null()
	assert_str(instantiator.last_inst_route).is_equal("light")
	assert_bool(instantiator.last_proximity_deferred).is_false()
	node.free()


func test_morrowind_spawn_adapter_makes_teleport_door_interactable_and_tappable() -> void:
	var adapter: Variant = _new_spawn_adapter()
	var instantiator := FakeInstantiator.new()
	var root := _make_mesh_root()
	var ref := CellReference.new()
	ref.ref_id = &"ex_common_door_01"
	ref.ref_num = 42
	ref.is_teleport = true
	ref.teleport_cell = "Interior Cell"
	var door_record := DoorRecord.new()
	door_record.record_id = "ex_common_door_01"
	door_record.name = "Common Door"
	door_record.model = "d\\common_door.nif"

	adapter.postprocess_source_model_object(
		root,
		ref,
		door_record,
		"door",
		Vector2i(-2, -9),
		door_record.record_id,
		instantiator,
	)

	assert_bool(root is DoorInteractable).is_true()
	assert_str(root.get("record_id")).is_equal("ex_common_door_01")
	assert_str(root.get("door_instance_key")).is_equal("ext:-2,-9:ex_common_door_01:42")
	assert_bool(root.get("has_destination")).is_true()
	assert_object(instantiator.last_interaction_area).is_not_null()
	assert_int(instantiator.last_interaction_area.collision_layer).is_equal(1 << 2)
	assert_int(instantiator.last_interaction_area.collision_mask).is_equal(0)
	assert_bool(instantiator.last_interaction_area.monitoring).is_false()
	assert_bool(instantiator.last_interaction_area.monitorable).is_false()

	var player := Node3D.new()
	root.interact(player)
	assert_int(instantiator.door_calls).is_equal(1)
	assert_str(instantiator.last_door_key).is_equal("ext:-2,-9:ex_common_door_01:42")
	player.free()
	root.free()


func test_morrowind_spawn_adapter_preserves_premarked_interior_door_key() -> void:
	var adapter: Variant = _new_spawn_adapter()
	var instantiator := FakeInstantiator.new()
	var root := _make_mesh_root()
	var ref := CellReference.new()
	ref.ref_id = &"ex_common_door_01"
	ref.ref_num = 202
	ref.is_teleport = true
	ref.teleport_cell = ""
	ref.set_meta("transition_portal_key", "int:seyda neen, arrille's tradehouse:ex_common_door_01:202")
	var door_record := DoorRecord.new()
	door_record.record_id = "ex_common_door_01"
	door_record.name = "Common Door"
	door_record.model = "d\\common_door.nif"

	adapter.postprocess_source_model_object(
		root,
		ref,
		door_record,
		"door",
		Vector2i.ZERO,
		door_record.record_id,
		instantiator,
	)

	assert_str(root.get("door_instance_key")).is_equal("int:seyda neen, arrille's tradehouse:ex_common_door_01:202")
	root.free()


func test_carryable_factory_makes_mesh_only_item_pickable_and_grabbable() -> void:
	var root := _make_mesh_root()

	var rb: RigidBody3D = CarryableBodyFactoryScript.convert_static_to_rigid(
		root,
		2.5,
		&"misc_test_01",
		"Test Item",
		PickupInteractableScript,
	)

	assert_object(rb).is_not_null()
	assert_bool(root.has_meta("carryable_wrapper")).is_true()
	assert_int(rb.collision_layer).is_equal(CarryableBodyFactoryScript.SPAWN_LAYER)
	assert_int(rb.collision_mask).is_equal(CarryableBodyFactoryScript.SPAWN_MASK)
	assert_bool(rb.freeze).is_true()
	assert_int(rb.freeze_mode).is_equal(RigidBody3D.FREEZE_MODE_KINEMATIC)
	assert_object(_find_pickup(root)).is_not_null()
	assert_object(_find_collision_shape(rb)).is_not_null()
	assert_that(InteractionRaycasterScript._find_interactable_ancestor(rb)).is_same(_find_pickup(root))
	root.free()


func test_morrowind_spawn_adapter_makes_registered_item_pickable_and_grabbable() -> void:
	_reset_carryable_registry()
	var source: Variant = MorrowindWorldObjectSourceScript.new()
	var ref := CellReference.new()
	ref.ref_id = &"misc_test_01"
	ref.ref_num = 7
	ref.position = Vector3.ZERO
	ref.rotation = Vector3.ZERO
	ref.scale = 1.0
	var base := MiscRecord.new()
	base.record_id = "misc_test_01"
	base.name = "Test Item"
	base.model = "meshes\\o\\test_item.nif"
	base.weight = 1.25
	var record: WorldObjectRecord = source._make_record(Vector2i(0, 0), ref, base, "misc")
	source._object_cache[record.object_id] = record
	var adapter: Variant = _new_spawn_adapter()
	adapter.configure(source)
	var instantiator := FakeInstantiator.new()
	instantiator.next_node = _make_mesh_root()

	var node: Node3D = adapter.instantiate_world_object(record, instantiator, Vector2i.ZERO, record.cache_item_id)

	assert_object(node).is_not_null()
	var pickup := _find_pickup(node)
	var rb := _find_rigidbody(node)
	assert_object(pickup).is_not_null()
	assert_object(rb).is_not_null()
	assert_bool(node.has_meta("carryable_wrapper")).is_true()
	assert_str(pickup.record_id).is_equal("misc_test_01")
	assert_str(pickup.display_name).is_equal("Test Item")
	assert_float(pickup.mass_kg).is_equal_approx(1.25, 0.001)
	assert_that(InteractionRaycasterScript._find_interactable_ancestor(rb)).is_same(pickup)
	node.free()


func test_mw_carryable_registry_declares_item_types_and_light_filter() -> void:
	_reset_carryable_registry()
	var generic := MiscRecord.new()
	generic.weight = 1.0
	for type_name: StringName in MWCarryableRegistryScript.CARRYABLE_TYPES:
		assert_bool(CarryableRegistryScript.is_carryable(type_name, generic)).is_true()

	var carried_light := LightRecord.new()
	carried_light.weight = 1.0
	carried_light.flags = LightRecord.FLAG_CAN_CARRY
	assert_bool(CarryableRegistryScript.is_carryable(&"light", carried_light)).is_true()

	var fixture_light := LightRecord.new()
	fixture_light.weight = 1.0
	fixture_light.flags = 0
	assert_bool(CarryableRegistryScript.is_carryable(&"light", fixture_light)).is_false()


func test_carry_release_restores_body_even_if_pickup_wrapper_is_gone() -> void:
	var carry: CarryController = CarryControllerScript.new() as CarryController
	add_child(carry)
	auto_free(carry)
	var rb := RigidBody3D.new()
	add_child(rb)
	auto_free(rb)
	rb.collision_mask = 0
	rb.gravity_scale = 0.0
	rb.linear_damp = 4.0
	rb.angular_damp = 6.0
	carry._held_body = rb
	carry._held_pickup = null
	carry._saved_collision_mask = 3
	carry._saved_gravity_scale = 1.0
	carry._saved_linear_damp = 0.1
	carry._saved_angular_damp = 0.2

	carry.release()
	await get_tree().process_frame

	assert_int(rb.collision_mask).is_equal(3)
	assert_float(rb.gravity_scale).is_equal_approx(1.0, 0.001)
	assert_float(rb.linear_damp).is_equal_approx(0.1, 0.001)
	assert_float(rb.angular_damp).is_equal_approx(0.2, 0.001)


func test_near_gameplay_toggle_preserves_passive_interaction_area() -> void:
	var manager: NativeStreamingManager = NativeStreamingManagerScript.new() as NativeStreamingManager
	var root := Node3D.new()
	var area := Area3D.new()
	area.name = "InteractionArea"
	area.monitoring = false
	area.monitorable = false
	root.add_child(area)

	manager._set_near_gameplay_active(root, true)
	await get_tree().process_frame

	assert_bool(area.monitoring).is_false()
	assert_bool(area.monitorable).is_false()
	root.free()


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


func test_morrowind_spawn_adapter_record_factory_keeps_payload_adapter_owned() -> void:
	var adapter: Variant = _new_spawn_adapter()
	var ref := CellReference.new()
	ref.ref_id = &"ex_test_01"
	ref.ref_num = 77
	ref.position = Vector3(70.0, 140.0, 210.0)
	var base := FakeLightRecord.new()
	var record: RefCounted = adapter.make_world_object_record_from_source_reference(
		ref,
		base,
		"light",
		"",
		"ex_test_01",
		"",
		false,
		Vector2i(2, -3)
	)

	assert_object(record).is_not_null()
	assert_int(int(record.get("spawn_route"))).is_equal(WorldObjectRecord.SpawnRoute.LIGHT)
	assert_str(str(record.get("source_ref_id"))).is_equal("ex_test_01")
	var payload: Dictionary = adapter._get_payload(record)
	assert_that(payload.get("ref")).is_same(ref)
	assert_that(payload.get("base_record")).is_same(base)
	assert_str(str(payload.get("type_name"))).is_equal("light")


func test_morrowind_spawn_adapter_translates_light_animation_flags() -> void:
	var adapter: Variant = _new_spawn_adapter()
	var light := FakeLightRecord.new()

	light.flags = 0x0008
	assert_int(adapter.source_light_animation_for_record(light)).is_equal(WorldObjectRecordScript.LightAnimation.FLICKER)
	light.flags = 0x0040
	assert_int(adapter.source_light_animation_for_record(light)).is_equal(WorldObjectRecordScript.LightAnimation.FLICKER_SLOW)
	light.flags = 0x0080
	assert_int(adapter.source_light_animation_for_record(light)).is_equal(WorldObjectRecordScript.LightAnimation.PULSE)
	light.flags = 0x0100
	assert_int(adapter.source_light_animation_for_record(light)).is_equal(WorldObjectRecordScript.LightAnimation.PULSE_SLOW)
	light.flags = 0
	assert_int(adapter.source_light_animation_for_record(light)).is_equal(WorldObjectRecordScript.LightAnimation.NONE)


func _new_spawn_adapter() -> RefCounted:
	return MorrowindObjectSpawnAdapterScript.new()


func _reset_carryable_registry() -> void:
	CarryableRegistryScript.clear()
	MWCarryableRegistryScript.release_callable_owner()
	MWCarryableRegistryScript.register_all()


func _make_mesh_root() -> Node3D:
	var root := Node3D.new()
	root.name = "TestItemRoot"
	var mesh := MeshInstance3D.new()
	mesh.name = "Visual"
	var box := BoxMesh.new()
	box.size = Vector3(0.4, 0.2, 0.3)
	mesh.mesh = box
	root.add_child(mesh)
	return root


func _find_pickup(node: Node) -> PickupInteractable:
	if node is PickupInteractable:
		return node as PickupInteractable
	for child in node.get_children():
		var found := _find_pickup(child)
		if found != null:
			return found
	return null


func _find_rigidbody(node: Node) -> RigidBody3D:
	if node is RigidBody3D:
		return node as RigidBody3D
	for child in node.get_children():
		var found := _find_rigidbody(child)
		if found != null:
			return found
	return null


func _find_collision_shape(node: Node) -> CollisionShape3D:
	if node is CollisionShape3D:
		return node as CollisionShape3D
	for child in node.get_children():
		var found := _find_collision_shape(child)
		if found != null:
			return found
	return null
