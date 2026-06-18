extends GdUnitTestSuite

const CellManagerScript := preload("res://src/core/world/cell_manager.gd")
const NativeStreamingManagerScript := preload("res://src/core/world/native_streaming_manager.gd")


class FakeImpostorRenderer:
	extends Node3D

	func get_pending_cell_count() -> int:
		return 0

	func get_initial_pending_count() -> int:
		return 1

	func set_load_budget_usec(_budget_usec: float) -> void:
		pass


func _make_manager(queue_size: int) -> Node3D:
	var manager := Node3D.new()
	manager.set_script(NativeStreamingManagerScript)
	manager._startup_phase = true
	manager._startup_frames = 60
	manager.load_radius_cells = 3
	manager._cell_manager = CellManagerScript.new()
	manager._impostor_renderer = FakeImpostorRenderer.new()
	for i in range(7):
		manager._loaded_cells[Vector2i(i, 0)] = Node3D.new()
	for i in range(queue_size):
		manager._cell_manager._pending_child_attaches.append({})
	return manager


func test_startup_phase_waits_for_first_playable_queue_cap() -> void:
	var manager := _make_manager(9)

	manager._check_startup_complete()

	assert_bool(manager.is_in_startup_phase()).is_true()


func test_startup_phase_completes_at_first_playable_queue_cap() -> void:
	var manager := _make_manager(8)

	manager._check_startup_complete()

	assert_bool(manager.is_in_startup_phase()).is_false()
