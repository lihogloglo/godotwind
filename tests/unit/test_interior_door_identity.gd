extends GdUnitTestSuite

const DoorInteractableScript := preload("res://src/core/interaction/morrowind/door_interactable.gd")
const InteriorPocketManagerScript := preload("res://src/core/world/interior_pocket_manager.gd")


func test_door_interactable_emits_instance_key() -> void:
	var door: DoorInteractable = DoorInteractableScript.new()
	var player := Node3D.new()
	var emitted_key := ""
	door.record_id = "ex_common_door"
	door.door_instance_key = "ext:-2,-9:ex_common_door:42"
	door.door_activated.connect(func(key: String, _record: Variant, _player: Node3D) -> void:
		emitted_key = key
	)

	door.interact(player)

	assert_bool(emitted_key == "ext:-2,-9:ex_common_door:42").is_true()
	door.free()
	player.free()


func test_instance_keys_distinguish_duplicate_base_ref_ids() -> void:
	var first_key: StringName = InteriorPocketManagerScript.make_exterior_door_instance_key(
		Vector2i(-2, -9),
		&"ex_common_door",
		101
	)
	var second_key: StringName = InteriorPocketManagerScript.make_exterior_door_instance_key(
		Vector2i(-2, -9),
		&"ex_common_door",
		102
	)

	assert_that(first_key).is_not_equal(second_key)
	assert_str(str(first_key)).is_equal("ext:-2,-9:ex_common_door:101")
	assert_str(str(second_key)).is_equal("ext:-2,-9:ex_common_door:102")


func test_get_door_info_by_instance_key_resolves_exterior_and_active_interior() -> void:
	var manager: Variant = InteriorPocketManagerScript.new()
	var exterior_door: Variant = InteriorPocketManagerScript.DoorInfo.new()
	exterior_door.ref_id = &"ex_common_door"
	exterior_door.base_ref_id = &"ex_common_door"
	exterior_door.ref_num = 101
	exterior_door.instance_key = InteriorPocketManagerScript.make_exterior_door_instance_key(Vector2i(-2, -9), exterior_door.base_ref_id, exterior_door.ref_num)
	manager._exterior_doors.append(exterior_door)

	var interior_slot: Variant = InteriorPocketManagerScript.PocketSlot.new()
	interior_slot.is_occupied = true
	interior_slot.cell_name = "Arrille's Tradehouse"
	var interior_door: Variant = InteriorPocketManagerScript.DoorInfo.new()
	interior_door.ref_id = &"ex_common_door"
	interior_door.base_ref_id = &"ex_common_door"
	interior_door.ref_num = 202
	interior_door.instance_key = InteriorPocketManagerScript.make_interior_door_instance_key(interior_slot.cell_name, interior_door.base_ref_id, interior_door.ref_num)
	interior_slot.doors_inside.append(interior_door)
	manager._active_pocket = interior_slot

	assert_that(manager.get_door_info_by_instance_key(exterior_door.instance_key)).is_same(exterior_door)
	assert_that(manager.get_door_info_by_instance_key(interior_door.instance_key)).is_same(interior_door)
	assert_object(manager.get_door_info_by_instance_key(&"ext:-2,-9:ex_common_door:999")).is_null()
	manager.free()
