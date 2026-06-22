extends GdUnitTestSuite

const NativeStreamingManagerScript: Script = preload("res://src/core/world/native_streaming_manager.gd")
const CellManagerScript: Script = preload("res://src/core/world/cell_manager.gd")
const StreamingConfig := preload("res://src/core/world/streaming_config.gd")


func test_default_benchmark_mode_is_valid_async_metadata() -> void:
	var manager: Node = NativeStreamingManagerScript.new()
	var meta: Dictionary = manager.call("get_benchmark_mode_metadata")
	var flags: Dictionary = meta.get("flags", {})

	assert_str(meta.get("schema", "")).is_equal("godotwind_benchmark_mode_v1")
	assert_bool(meta.get("valid_for_performance_baseline", false)).is_true()
	assert_bool(flags.get("async_loading_enabled", false)).is_true()
	assert_bool(flags.get("sync_loading_mode", true)).is_false()
	assert_bool(flags.has("phase_f_prereg_enabled")).is_false()
	assert_bool(flags.has("phase_f_prereg_status")).is_false()
	manager.free()


func test_sync_loading_mode_marks_benchmark_invalid() -> void:
	var manager: Node = NativeStreamingManagerScript.new()
	manager.set("async_loading_enabled", false)
	var meta: Dictionary = manager.call("get_benchmark_mode_metadata")
	var invalid: Array = meta.get("invalid_reasons", [])
	var stats: Dictionary = manager.call("get_stats")

	assert_bool(meta.get("valid_for_performance_baseline", true)).is_false()
	assert_bool(invalid.has("sync_loading_mode")).is_true()
	assert_bool(stats.has("benchmark_mode_metadata")).is_true()
	manager.free()


func test_near_only_mode_is_explicitly_classified() -> void:
	var manager: Node = NativeStreamingManagerScript.new()
	manager.call("set_mid_tier_visible", false)
	manager.call("set_impostors_visible", false)
	manager.call("set_hlod_visible", false)
	manager.call("set_distant_lights_visible", false)
	var meta: Dictionary = manager.call("get_benchmark_mode_metadata")
	var flags: Dictionary = meta.get("flags", {})

	assert_str(meta.get("mode_name", "")).is_equal("near_only")
	assert_bool(flags.get("near_only", false)).is_true()
	assert_bool(meta.get("valid_for_performance_baseline", false)).is_true()
	manager.free()


func test_dev_mid_object_paging_is_experimental_near_mid_mode() -> void:
	var manager: Node = NativeStreamingManagerScript.new()
	manager.call("set_impostors_visible", false)
	manager.call("set_hlod_visible", false)
	manager.call("set_distant_lights_visible", false)
	manager.call("set_dev_mid_object_paging_visible", true)
	var meta: Dictionary = manager.call("get_benchmark_mode_metadata")
	var flags: Dictionary = meta.get("flags", {})
	var invalid: Array = meta.get("invalid_reasons", [])

	assert_str(meta.get("mode_name", "")).is_equal("near_mid_dev_object_paging")
	assert_bool(meta.get("valid_for_performance_baseline", true)).is_false()
	assert_bool(invalid.has("dev_mid_object_paging_experiment")).is_true()
	assert_bool(flags.get("near_mid_dev_object_paging", false)).is_true()
	assert_bool(flags.get("near_mid_only", true)).is_false()
	manager.free()


func test_mid_cells_use_static_visual_profile_until_near() -> void:
	var manager: Node = NativeStreamingManagerScript.new()
	manager.set("_camera_cell", Vector2i.ZERO)
	manager.set("_camera_position", StreamingConfig.DU.cell_to_world_center(Vector2i.ZERO, 0.0))

	var near_profile: Variant = manager.call("_load_profile_for_cell", Vector2i.ZERO)
	var diagonal_near_profile: Variant = manager.call("_load_profile_for_cell", Vector2i(1, 1))
	var mid_profile: Variant = manager.call("_load_profile_for_cell", Vector2i(4, 0))

	assert_bool(bool(near_profile.get("include_gameplay"))).is_true()
	assert_bool(bool(near_profile.get("include_static_visuals"))).is_true()
	assert_bool(bool(diagonal_near_profile.get("include_gameplay"))).is_true()
	assert_bool(bool(diagonal_near_profile.get("include_static_visuals"))).is_true()
	assert_bool(bool(mid_profile.get("include_gameplay"))).is_false()
	assert_bool(bool(mid_profile.get("include_static_visuals"))).is_true()
	manager.free()


func test_gameplay_upgrade_does_not_overwrite_active_cell_request() -> void:
	var manager: Node = NativeStreamingManagerScript.new()
	var cell_node := Node3D.new()
	var async_requests: Dictionary[Vector2i, int] = {}
	var has_gameplay: Dictionary[Vector2i, bool] = {}
	async_requests[Vector2i.ZERO] = 42
	has_gameplay[Vector2i.ZERO] = false
	manager.set("_loaded_cells", {Vector2i.ZERO: cell_node})
	manager.set("_loaded_cell_has_gameplay", has_gameplay)
	manager.set("_async_requests", async_requests)

	assert_bool(manager.call("_request_cell_gameplay_upgrade_async", Vector2i.ZERO)).is_false()
	assert_int(int((manager.get("_async_requests") as Dictionary).get(Vector2i.ZERO, -1))).is_equal(42)
	assert_int((manager.get("_gameplay_upgrade_requests") as Dictionary).size()).is_equal(0)

	cell_node.free()
	manager.free()


func test_gameplay_upgrade_merge_is_budgeted() -> void:
	var manager: Node = NativeStreamingManagerScript.new()
	var grid := Vector2i.ZERO
	var target := Node3D.new()
	var upgrade := Node3D.new()
	var child_a := Node3D.new()
	var child_b := Node3D.new()
	upgrade.add_child(child_a)
	upgrade.add_child(child_b)
	manager.set("_loaded_cells", {grid: target})
	manager.call("_queue_gameplay_upgrade_merge", grid, upgrade)

	assert_bool(bool((manager.get("_pending_gameplay_upgrade_merge_cells") as Dictionary).get(grid, false))).is_true()
	assert_int(manager.call("_drain_pending_gameplay_upgrade_merges", 1)).is_equal(1)
	assert_int(target.get_child_count()).is_equal(1)
	assert_bool(bool((manager.get("_loaded_cell_has_gameplay") as Dictionary).get(grid, false))).is_false()
	assert_int(manager.call("_drain_pending_gameplay_upgrade_merges", 1)).is_equal(1)
	assert_int(target.get_child_count()).is_equal(2)
	assert_bool(bool((manager.get("_loaded_cell_has_gameplay") as Dictionary).get(grid, false))).is_true()

	target.free()
	manager.free()


func test_static_visual_only_completion_does_not_emit_cell_loaded() -> void:
	var manager: Node = NativeStreamingManagerScript.new()
	var cell_manager: Variant = CellManagerScript.new()
	var world_container := Node3D.new()
	var grid := Vector2i(4, 0)
	var profile: Variant = CellManagerScript.LoadProfile.exterior_static_visuals_only()
	var request_id: int = cell_manager._start_async_request(null, grid, false, profile, [], true)
	var request: Variant = cell_manager._async_requests[request_id]
	cell_manager._finish_request_classification(request)
	cell_manager._finalize_request(request)
	var async_requests: Dictionary[Vector2i, int] = {}
	var has_gameplay: Dictionary[Vector2i, bool] = {}
	async_requests[grid] = request_id
	has_gameplay[grid] = false
	manager.set("_cell_manager", cell_manager)
	manager.set("_world_container", world_container)
	manager.set("_async_requests", async_requests)
	manager.set("_loaded_cell_has_gameplay", has_gameplay)
	@warning_ignore("inferred_declaration")
	var monitor := monitor_signals(manager)

	manager.call("_process_async_completions")

	await assert_signal(monitor).wait_until(50).is_not_emitted("cell_loaded")
	assert_bool((manager.get("_loaded_cells") as Dictionary).has(grid)).is_true()
	assert_bool((manager.get("_async_requests") as Dictionary).has(grid)).is_false()
	world_container.free()
	manager.free()


func test_scene_cell_selection_uses_cell_bounds_cap() -> void:
	var manager: Node = NativeStreamingManagerScript.new()
	manager.set("_camera_cell", Vector2i.ZERO)
	manager.set("_camera_position", StreamingConfig.DU.cell_to_world_center(Vector2i.ZERO, 0.0))
	manager.set("load_radius_cells", 4)
	manager.set("max_load_distance", StreamingConfig.DU.MID_END)

	var cells: Array = manager.call("_get_cells_in_radius", Vector2i.ZERO, 4)

	assert_bool(cells.has(Vector2i(3, 0))).is_true()
	assert_bool(cells.has(Vector2i(4, 0))).is_false()
	assert_bool(cells.has(Vector2i(3, 3))).is_false()
	manager.free()
