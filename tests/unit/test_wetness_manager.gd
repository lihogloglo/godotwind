extends GdUnitTestSuite

const WetnessManagerScript := preload("res://src/core/water/wetness_manager.gd")
const WaterSurfaceStateScript := preload("res://src/core/water/water_surface_state.gd")


func _state_with_height(height: float) -> WaterSurfaceState:
	var state: WaterSurfaceState = WaterSurfaceStateScript.new()
	state.water_body_id = WaterSurfaceState.WATER_BODY_OCEAN
	state.coverage_available = true
	state.cpu_query_available = true
	state.sea_level = height
	state.height_query = func(_pos: Vector3) -> float:
		return height
	return state


func test_memory_holder_soaks_to_contact_waterline() -> void:
	var manager: WetnessManagerClass = WetnessManagerScript.new()
	var root := Node3D.new()
	root.global_position = Vector3.ZERO
	manager.register_memory_holder(root, [] as Array[RID], -0.5, 0.5)

	manager._update_memory_holders(0.016, _state_with_height(0.25))

	assert_float(manager.get_memory_holder_wet_line(root)).is_equal_approx(0.25, 0.001)
	root.free()


func test_memory_holder_decays_after_leaving_water() -> void:
	var manager: WetnessManagerClass = WetnessManagerScript.new()
	manager.wet_dry_rate = 0.1
	var root := Node3D.new()
	root.global_position = Vector3.ZERO
	manager.register_memory_holder(root, [] as Array[RID], -0.5, 0.5)

	manager._update_memory_holders(0.016, _state_with_height(0.25))
	manager._update_memory_holders(1.0, _state_with_height(-2.0))

	assert_float(manager.get_memory_holder_wet_line(root)).is_equal_approx(0.15, 0.001)
	root.free()


func test_unregister_memory_holder_removes_state() -> void:
	var manager: WetnessManagerClass = WetnessManagerScript.new()
	var root := Node3D.new()
	root.global_position = Vector3.ZERO
	manager.register_memory_holder(root, [] as Array[RID], -0.5, 0.5)

	manager.unregister_memory_holder(root)

	assert_float(manager.get_memory_holder_wet_line(root)).is_less(-1.0e20)
	root.free()
