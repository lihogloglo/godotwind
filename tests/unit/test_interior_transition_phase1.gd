extends GdUnitTestSuite

const DoorInteractableScript := preload("res://src/core/interaction/morrowind/door_interactable.gd")
const InteriorPocketManagerScript := preload("res://src/core/world/interior_pocket_manager.gd")
const CellManagerScript := preload("res://src/core/world/cell_manager.gd")


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
