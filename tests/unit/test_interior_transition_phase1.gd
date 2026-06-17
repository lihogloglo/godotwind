extends GdUnitTestSuite

const DoorInteractableScript := preload("res://src/core/interaction/morrowind/door_interactable.gd")
const InteriorPocketManagerScript := preload("res://src/core/world/interior_pocket_manager.gd")
const CellManagerScript := preload("res://src/core/world/cell_manager.gd")
const MorrowindTransitionProviderScript := preload("res://src/core/world/morrowind/morrowind_transition_provider.gd")
const WorldSpaceHandleScript := preload("res://src/core/world/transition/world_space_handle.gd")


class FakeCell:
	extends RefCounted
	var name: String = "Fake Interior"
	var references: Array = []
	var interior: bool = false
	var has_ambient: bool = false
	var ambient_color: Color = Color.BLACK
	var fog_color: Color = Color.BLACK
	var fog_density: float = 0.0
	var quasi_exterior: bool = false

	func is_interior() -> bool:
		return interior

	func is_quasi_exterior() -> bool:
		return quasi_exterior


class FakeRef:
	extends RefCounted
	var ref_id: StringName = &""
	var ref_num: int = 0
	var is_teleport: bool = true
	var teleport_cell: String = ""
	var position: Vector3 = Vector3.ZERO
	var rotation: Vector3 = Vector3.ZERO
	var teleport_pos: Vector3 = Vector3.ZERO
	var teleport_rot: Vector3 = Vector3.ZERO


class FakeObjectSource:
	extends RefCounted
	var cells: Dictionary = {}

	func get_source_cell(cell_name: String) -> Variant:
		return cells.get(cell_name, null)

	func get_source_base_record_cached(_ref_id: String, record_type_out: Array = []) -> Variant:
		if not record_type_out.is_empty():
			record_type_out[0] = "static"
		return null


func test_pocket_finalization_preserves_interaction_query_area() -> void:
	var manager: Variant = InteriorPocketManagerScript.new()
	var root := Node3D.new()
	var body := StaticBody3D.new()
	var interaction_area := Area3D.new()
	interaction_area.name = "InteractionArea"
	interaction_area.collision_layer = 1 << 2
	interaction_area.collision_mask = 0
	interaction_area.monitoring = false
	interaction_area.monitorable = false
	root.add_child(body)
	root.add_child(interaction_area)

	manager._finalize_cell_node(root, 0xC, 0x30)

	assert_int(body.collision_layer).is_equal(0x30)
	assert_int(body.collision_mask).is_equal(0x30)
	assert_int(interaction_area.collision_layer).is_equal(1 << 2)
	assert_int(interaction_area.collision_mask).is_equal(0)
	assert_bool(interaction_area.monitoring).is_false()
	assert_bool(interaction_area.monitorable).is_false()

	root.free()
	manager.free()


func test_door_handler_reconnect_is_idempotent() -> void:
	var cell_manager: Variant = CellManagerScript.new()
	var root := Node3D.new()
	var door: DoorInteractable = DoorInteractableScript.new()
	var player := Node3D.new()
	var calls: Array[int] = [0]
	door.door_instance_key = "ext:-2,-9:ex_common_door:42"
	root.add_child(door)
	var handler := func(_key: String, _record: Variant, _player: Node3D) -> void:
		calls[0] += 1

	assert_int(cell_manager.reconnect_door_activated_handlers(root, handler)).is_equal(1)
	assert_int(cell_manager.reconnect_door_activated_handlers(root, handler)).is_equal(0)

	door.interact(player)

	assert_int(calls[0]).is_equal(1)
	root.free()
	player.free()


func test_runtime_pocket_load_has_no_sync_fallback() -> void:
	var source := FileAccess.get_file_as_string("res://src/core/world/interior_pocket_manager.gd")
	assert_bool(source.contains("_cell_manager.load_cell(")).is_false()


func test_visual_transition_scene_uses_production_interaction_wiring() -> void:
	var source := FileAccess.get_file_as_string("res://tests/visual/test_interior_transition.gd")
	assert_bool(source.contains("InteractionRaycasterScript")).is_true()
	assert_bool(source.contains("prompt_changed.connect(_on_interact_prompt_changed)")).is_true()
	assert_bool(source.contains("set_door_activated_handler")).is_true()
	assert_bool(source.contains("reconnect_door_activated_handlers")).is_true()
	assert_bool(source.contains("target.interact(_camera)")).is_true()
	assert_bool(source.contains("process_async_payloads")).is_true()


func test_pocket_load_waits_for_full_async_completion_not_visual_playable() -> void:
	var source := FileAccess.get_file_as_string("res://src/core/world/interior_pocket_manager.gd")
	assert_bool(source.contains("get_async_cell_node(request_id)")).is_false()
	assert_bool(source.contains("if not complete:")).is_true()


func test_async_request_completion_waits_for_pending_child_attaches() -> void:
	var cell_manager: Variant = CellManagerScript.new()
	var cell := CellRecord.new()
	cell.name = "Fake Interior"
	cell.flags = ESMDefs.CELL_INTERIOR

	var request_id: int = cell_manager._start_async_request(
		cell,
		Vector2i.ZERO,
		true,
		CellManagerScript.LoadProfile.interior_pocket()
	)
	var request: Variant = cell_manager._async_requests[request_id]
	request.classification_complete = true

	var child := Node3D.new()
	cell_manager._queue_child_attach(request_id, request.cell_node, child, null, "door")

	assert_bool(cell_manager._is_request_complete(request)).is_false()
	assert_bool(cell_manager.is_async_complete(request_id)).is_false()

	assert_int(cell_manager._drain_pending_child_attaches(10, 1000000.0)).is_equal(1)
	cell_manager._finalize_requests_completed_by_child_attaches()

	assert_bool(cell_manager.is_async_complete(request_id)).is_true()
	var result: Node3D = cell_manager.get_async_result(request_id)
	assert_object(result).is_not_null()
	assert_int(result.get_child_count()).is_equal(1)

	result.free()


func test_morrowind_transition_provider_emits_source_neutral_portal_descriptors() -> void:
	var object_source := FakeObjectSource.new()
	var interior := FakeCell.new()
	interior.interior = true
	object_source.cells["Arrille's Tradehouse"] = interior

	var exterior := FakeCell.new()
	var door_ref := FakeRef.new()
	door_ref.ref_id = &"ex_common_door"
	door_ref.ref_num = 42
	door_ref.teleport_cell = "Arrille's Tradehouse"
	door_ref.position = Vector3(70.0, 0.0, 140.0)
	door_ref.teleport_pos = Vector3(700.0, 0.0, 1400.0)
	door_ref.teleport_rot = Vector3(0.0, 0.0, 1.5)
	exterior.references.append(door_ref)

	var provider: Variant = MorrowindTransitionProviderScript.new()
	provider.configure(object_source)

	var descriptors: Array = provider.get_exterior_transition_portals(exterior, Vector2i(-2, -9))

	assert_int(descriptors.size()).is_equal(1)
	assert_str(str(descriptors[0].portal_key)).is_equal("ext:-2,-9:ex_common_door:42")
	assert_str(descriptors[0].target_space.key).is_equal("Arrille's Tradehouse")
	assert_bool(descriptors[0].target_space.is_interior()).is_true()
	assert_str(str(door_ref.get_meta("transition_portal_key"))).is_equal("ext:-2,-9:ex_common_door:42")


func test_morrowind_transition_provider_returns_source_neutral_space_info() -> void:
	var object_source := FakeObjectSource.new()
	var interior := FakeCell.new()
	interior.name = "Seyda Neen, Arrille's Tradehouse"
	interior.interior = true
	interior.has_ambient = true
	interior.ambient_color = Color(0.02, 0.015, 0.01)
	interior.quasi_exterior = true
	object_source.cells[interior.name] = interior

	var provider: Variant = MorrowindTransitionProviderScript.new()
	provider.configure(object_source)

	var info: RefCounted = provider.get_transition_space_info(
		WorldSpaceHandleScript.interior(interior.name),
		Environment.new()
	)

	assert_object(info).is_not_null()
	assert_str(info.get("display_name")).is_equal(interior.name)
	assert_bool(info.get("is_quasi_exterior")).is_true()
	assert_object(info.get("environment")).is_instanceof(Environment)


func test_pocket_manager_registers_provider_descriptors_by_instance_key() -> void:
	var manager: Variant = InteriorPocketManagerScript.new()
	var object_source := FakeObjectSource.new()
	var interior := FakeCell.new()
	interior.interior = true
	object_source.cells["Arrille's Tradehouse"] = interior

	var exterior := FakeCell.new()
	var door_ref := FakeRef.new()
	door_ref.ref_id = &"ex_common_door"
	door_ref.ref_num = 101
	door_ref.teleport_cell = "Arrille's Tradehouse"
	exterior.references.append(door_ref)

	var provider: Variant = MorrowindTransitionProviderScript.new()
	provider.configure(object_source)
	manager.set_transition_provider(provider)

	assert_int(manager.register_exterior_cell_doors(exterior, Vector2i(-2, -9))).is_equal(1)
	var door: Variant = manager.get_door_info_by_instance_key(&"ext:-2,-9:ex_common_door:101")

	assert_object(door).is_not_null()
	assert_bool(door.has_interior_target()).is_true()
	assert_str(door.get_target_space_key()).is_equal("Arrille's Tradehouse")
	manager.free()


func test_pocket_manager_registers_interior_exit_doors_after_completion() -> void:
	var manager: Variant = InteriorPocketManagerScript.new()
	var object_source := FakeObjectSource.new()
	var provider: Variant = MorrowindTransitionProviderScript.new()
	provider.configure(object_source)
	manager.set_transition_provider(provider)

	var interior := FakeCell.new()
	interior.name = "Seyda Neen, Arrille's Tradehouse"
	interior.interior = true
	object_source.cells[interior.name] = interior
	var exit_ref := FakeRef.new()
	exit_ref.ref_id = &"ex_common_door_01"
	exit_ref.ref_num = 202
	exit_ref.teleport_cell = ""
	exit_ref.position = Vector3(10.0, 0.0, 20.0)
	exit_ref.teleport_pos = Vector3(-2.0 * 8192.0 + 70.0, -9.0 * 8192.0 + 140.0, 0.0)
	interior.references.append(exit_ref)

	var pocket: Variant = InteriorPocketManagerScript.PocketSlot.new()
	pocket.cell_name = interior.name
	pocket.space_handle = preload("res://src/core/world/transition/world_space_handle.gd").interior(interior.name)
	pocket.cell_node = Node3D.new()

	manager._register_interior_doors(pocket)

	assert_int(pocket.doors_inside.size()).is_equal(1)
	assert_str(str(pocket.doors_inside[0].instance_key)).is_equal("int:seyda neen, arrille's tradehouse:ex_common_door_01:202")
	assert_str(str(exit_ref.get_meta("transition_portal_key"))).is_equal("int:seyda neen, arrille's tradehouse:ex_common_door_01:202")
	assert_bool(pocket.doors_inside[0].has_interior_target()).is_false()
	assert_str(pocket.doors_inside[0].get_target_space_key()).is_equal("-2,-9")

	pocket.cell_node.free()
	manager.free()
