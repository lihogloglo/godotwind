extends GdUnitTestSuite

const WaterInteractionSimScript := preload("res://src/core/water/water_interaction_sim.gd")
const WaterInteractorScript := preload("res://src/core/water/water_interactor.gd")


func test_crossing_detection_emits_one_impact() -> void:
	var interactor: WaterInteractor = auto_free(WaterInteractorScript.new())
	add_child(interactor)
	interactor.radius_m = 0.4
	interactor.global_position = Vector3(0.0, 0.5, 0.0)
	var state := _surface_state(Vector3.ZERO)

	assert_int(interactor.gather_impulses(0.1, state).size()).is_equal(0)
	interactor.global_position = Vector3(0.0, -0.2, 0.0)
	var impact := interactor.gather_impulses(0.1, state)
	assert_int(impact.size()).is_equal(1)
	assert_that(impact[0]["kind"]).is_equal(&"impact")

	var repeated := interactor.gather_impulses(0.1, state)
	assert_int(repeated.size()).is_equal(0)


func test_wake_throttling_emits_while_surface_contact_moves() -> void:
	var interactor: WaterInteractor = auto_free(WaterInteractorScript.new())
	add_child(interactor)
	interactor.radius_m = 0.4
	interactor.wake_interval_m = 0.25
	interactor.wake_interval_s = 0.1
	interactor.global_position = Vector3(0.0, -0.05, 0.0)
	var state := _surface_state(Vector3.ZERO)

	interactor.gather_impulses(0.1, state)
	interactor.global_position = Vector3(0.6, -0.05, 0.0)
	var impulses := interactor.gather_impulses(0.1, state)
	assert_int(impulses.size()).is_greater_equal(1)
	assert_that(impulses[0]["kind"]).is_equal(&"wake")

	var throttled := interactor.gather_impulses(0.02, state)
	assert_int(throttled.size()).is_equal(0)


func test_no_impulses_outside_water_coverage() -> void:
	var interactor: WaterInteractor = auto_free(WaterInteractorScript.new())
	add_child(interactor)
	interactor.global_position = Vector3(200.0, 0.5, 0.0)
	var state := _surface_state(Vector3.ZERO)

	interactor.gather_impulses(0.1, state)
	interactor.global_position = Vector3(200.0, -0.2, 0.0)
	assert_int(interactor.gather_impulses(0.1, state).size()).is_equal(0)


func test_river_relative_velocity_reduces_wake_strength() -> void:
	var still := WaterInteractorScript.new()
	var river := WaterInteractorScript.new()
	auto_free(still)
	auto_free(river)
	add_child(still)
	add_child(river)
	still.global_position = Vector3(0.0, -0.05, 0.0)
	river.global_position = Vector3(0.0, -0.05, 0.0)
	still.gather_impulses(0.1, _surface_state(Vector3.ZERO))
	river.gather_impulses(0.1, _surface_state(Vector3(3.0, 0.0, 0.0)))

	still.global_position = Vector3(0.6, -0.05, 0.0)
	river.global_position = Vector3(0.6, -0.05, 0.0)
	var still_impulses := still.gather_impulses(0.1, _surface_state(Vector3.ZERO))
	var river_impulses := river.gather_impulses(0.1, _surface_state(Vector3(3.0, 0.0, 0.0)))

	assert_int(still_impulses.size()).is_equal(1)
	assert_int(river_impulses.size()).is_equal(1)
	assert_float(float(still_impulses[0]["strength"])).is_greater(float(river_impulses[0]["strength"]))


func test_interactor_emits_flow_obstacle_during_surface_contact() -> void:
	var interactor: WaterInteractor = auto_free(WaterInteractorScript.new())
	add_child(interactor)
	interactor.affects_flow = true
	interactor.radius_m = 0.6
	interactor.flow_block_strength = 0.8
	interactor.flow_wake_strength = 0.5
	interactor.surface_band_m = 0.7
	interactor.global_position = Vector3(0.0, -0.1, 0.0)

	var obstacles := interactor.gather_flow_obstacles(0.1, _surface_state(Vector3(2.0, 0.0, 0.0)))

	assert_int(obstacles.size()).is_equal(1)
	assert_float(float(obstacles[0]["block_strength"])).is_equal_approx(0.8, 0.001)
	assert_float(float(obstacles[0]["wake_strength"])).is_equal_approx(0.5, 0.001)


func test_interactor_does_not_emit_flow_obstacle_without_current() -> void:
	var interactor: WaterInteractor = auto_free(WaterInteractorScript.new())
	add_child(interactor)
	interactor.affects_flow = true
	interactor.global_position = Vector3(0.0, -0.1, 0.0)

	assert_int(interactor.gather_flow_obstacles(0.1, _surface_state(Vector3.ZERO)).size()).is_equal(0)


func test_event_queue_caps_and_keeps_strongest_impulses() -> void:
	var sim: WaterInteractionSim = auto_free(WaterInteractionSimScript.new())
	sim.enabled = true
	sim.max_impulses_per_step = 2
	sim.world_size_m = 32.0

	sim.queue_impulse(Vector3.ZERO, 0.5, 0.1)
	sim.queue_impulse(Vector3.ZERO, 0.5, 0.9)
	sim.queue_impulse(Vector3.ZERO, 0.5, -0.4)

	var strengths := sim.get_pending_impulse_strengths_for_tests()
	assert_int(strengths.size()).is_equal(2)
	assert_float(absf(strengths[0])).is_greater_equal(0.4)
	assert_float(absf(strengths[1])).is_greater_equal(0.4)


func test_stats_expose_performance_contract() -> void:
	var sim: WaterInteractionSim = auto_free(WaterInteractionSimScript.new())
	sim.enabled = true
	sim.max_impulses_per_step = 4
	sim.world_size_m = 32.0
	sim.queue_impulse(Vector3.ZERO, 0.5, 1.0, 0.0, 1.0, true)
	sim.queue_flow_obstacle(Vector3.ZERO, 0.7, Vector3(2.0, 0.0, 0.0), 0.5, 0.4, 0.0, 1.0, true)

	var stats := sim.get_stats()
	assert_bool(stats.has("gpu_ms")).is_true()
	assert_bool(stats.has("cpu_upload_us")).is_true()
	assert_bool(stats.has("culled_impulses_total")).is_true()
	assert_bool(stats.has("culled_flow_obstacles_total")).is_true()
	assert_bool(stats.has("active_dispatch")).is_true()
	assert_bool(stats.has("atlas_scroll_px")).is_true()
	assert_int(int(stats["pending_impulse_count"])).is_equal(1)
	assert_int(int(stats["pending_flow_obstacle_count"])).is_equal(1)


func test_shader_contracts_expose_ripple_bindings() -> void:
	var scroll := FileAccess.get_file_as_string("res://src/core/water/shaders/compute/water_ripple_scroll.glsl")
	var splat := FileAccess.get_file_as_string("res://src/core/water/shaders/compute/water_ripple_splat.glsl")
	var simulate := FileAccess.get_file_as_string("res://src/core/water/shaders/compute/water_ripple_simulate.glsl")
	var flow_splat := FileAccess.get_file_as_string("res://src/core/water/shaders/compute/water_flow_splat.glsl")
	var flow_simulate := FileAccess.get_file_as_string("res://src/core/water/shaders/compute/water_flow_simulate.glsl")
	var ocean_common := FileAccess.get_file_as_string("res://src/core/water/shaders/ocean_surface_common.gdshaderinc")
	var optics_common := FileAccess.get_file_as_string("res://src/core/water/shaders/water_surface_optics_common.gdshaderinc")
	var interaction_common := FileAccess.get_file_as_string("res://src/core/water/shaders/water_interaction_common.gdshaderinc")
	var river := FileAccess.get_file_as_string("res://src/core/water/shaders/river_surface.gdshader")
	var volume_shader := FileAccess.get_file_as_string("res://src/core/water/shaders/water_volume.gdshader")
	var volume_script := FileAccess.get_file_as_string("res://src/core/water/water_volume.gd")

	assert_bool(scroll.contains("scroll_x") and scroll.contains("imageStore")).is_true()
	assert_bool(splat.contains("binding = 1") and splat.contains("atlas_rejects") and splat.contains("rect")).is_true()
	assert_bool(not splat.contains("for (int i = 0; i <")).is_true()
	assert_bool(simulate.contains("layout(rgba16f") and simulate.contains("laplacian")).is_true()
	assert_bool(flow_splat.contains("layout(rgba16f") and flow_splat.contains("base_velocity") and flow_splat.contains("wake_strength")).is_true()
	assert_bool(flow_simulate.contains("layout(rgba16f") and flow_simulate.contains("average") and flow_simulate.contains("velocity damping")).is_true()
	assert_bool(ocean_common.contains("water_interaction_common.gdshaderinc")).is_true()
	assert_bool(interaction_common.contains("water_interaction_map") and interaction_common.contains("water_surface_interaction_height_at")).is_true()
	assert_bool(interaction_common.contains("water_dynamic_flow_map") and interaction_common.contains("water_surface_dynamic_flow_velocity_at")).is_true()
	assert_bool(interaction_common.contains("water_body_atlas_map") and interaction_common.contains("water_interaction_body_filter_mode")).is_true()
	assert_bool(river.contains("water_interaction_common.gdshaderinc") and river.contains("water_surface_interaction_foam_at") and river.contains("water_surface_dynamic_flow_sample_at")).is_true()
	assert_bool(river.contains("world_flow_uv * 0.42 - flow_dir * river_time")).is_true()
	assert_bool(river.contains("water_interaction_debug_enabled") and river.contains("water_surface_interaction_debug_color_at")).is_true()
	assert_bool(optics_common.contains("world_xz - dir * advect")).is_true()
	assert_bool(volume_shader.contains("water_interaction_common.gdshaderinc") and volume_shader.contains("water_surface_interaction_height_at")).is_true()
	assert_bool(volume_script.contains("sync_water_interaction_texture") and volume_script.contains("water_body_atlas_map")).is_true()


func test_buoyancy_body_drag_is_relative_to_sampled_water_velocity_contract() -> void:
	var source := FileAccess.get_file_as_string("res://src/core/water/buoyancy_body.gd")

	assert_bool(source.contains("water_state.sample_base_velocity")).is_true()
	assert_bool(source.contains("relative_velocity := linear_velocity - average_water_velocity")).is_true()
	assert_bool(source.contains("linear_velocity = average_water_velocity + relative_velocity")).is_true()


func _surface_state(river_velocity: Vector3) -> WaterSurfaceState:
	var state := WaterSurfaceState.new()
	state.cpu_query_available = true
	state.coverage_available = true
	state.height_query = func(_pos: Vector3) -> float:
		return 0.0
	state.coverage_query = func(pos: Vector3) -> float:
		return 1.0 if absf(pos.x) < 100.0 else 0.0
	state.velocity_query = func(_pos: Vector3) -> Vector3:
		return river_velocity
	state.water_body_id_query = func(pos: Vector3) -> StringName:
		return &"test_water" if absf(pos.x) < 100.0 else WaterSurfaceState.WATER_BODY_NONE
	return state
