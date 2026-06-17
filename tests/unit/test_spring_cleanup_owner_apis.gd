extends GdUnitTestSuite

const CellManagerScript: Script = preload("res://src/core/world/cell_manager.gd")
const NativeStreamingManagerScript: Script = preload("res://src/core/world/native_streaming_manager.gd")
const StaticObjectRendererScript: Script = preload("res://src/core/world/static_object_renderer.gd")


func test_cell_manager_exposes_owned_streaming_dependencies() -> void:
	var manager: Variant = CellManagerScript.new()

	assert_object(manager.get_model_loader()).is_not_null()
	assert_object(manager.get_instantiator()).is_not_null()
	assert_bool(manager.is_model_loader_runtime_mode()).is_true()
	assert_int(manager.prewarm_model_cache_index()).is_greater_equal(0)

	var renderer: Node3D = StaticObjectRendererScript.new()
	manager.set_static_renderer(renderer)
	renderer.free()


func test_streaming_debug_apis_are_null_safe_before_initialization() -> void:
	var manager: Node = NativeStreamingManagerScript.new()

	assert_object(manager.get_static_renderer_debug_target()).is_null()
	manager.set_impostor_debug_enabled(true)
	manager.free()


func test_spring_cleanup_slice_2_private_reachthrough_does_not_regress() -> void:
	_assert_source_lacks(
		"res://src/tools/world_explorer.gd",
		[
			"cell_manager._model_loader",
			"native_streaming_manager._impostor_renderer",
			"native_streaming_manager._static_renderer",
			"native_streaming_manager._loaded_cells",
			"renderer._prototype_registry",
		]
	)
	_assert_source_lacks(
		"res://src/core/world/native_streaming_manager.gd",
		[
			"_cell_manager._static_renderer",
			"_cell_manager._sync_instantiator_config",
			"_cell_manager._instantiator",
			"_cell_manager._model_loader",
		]
	)


func test_spring_cleanup_slice_4_phase_f_prereg_stays_quarantined() -> void:
	_assert_source_lacks(
		"res://src/tools/world_explorer.gd",
		[
			"--enable-phase-f-prereg",
			"--disable-phase-f-prereg",
		]
	)
	_assert_source_lacks(
		"res://src/core/world/reference_instantiator.gd",
		[
			"preregister_cell_statics",
			"preregister_world_cell_statics",
			"drain_prereg_tasks",
			"_worker_dispatch_preregister",
			"_worker_preregister_prototype",
			"phase_f_prereg",
			"world_record_prereg",
			"_prereg_task_ids",
			"_prereg_dispatcher_task_ids",
		]
	)
	_assert_source_lacks(
		"res://src/core/world/cell_manager.gd",
		[
			"preregister_cell_statics",
			"preregister_world_cell_statics",
			"drain_prereg_tasks",
		]
	)
	_assert_source_lacks(
		"res://src/core/world/streaming_config.gd",
		[
			"DEBUG_DISABLE_PHASE_F_PREREG",
		]
	)


func test_spring_cleanup_slice_5_prototype_registry_path_stays_deleted() -> void:
	var renderer: Node3D = StaticObjectRendererScript.new()
	var stats: Dictionary = renderer.get_stats()
	assert_bool(stats.has("registry_" + "batches")).is_false()
	assert_bool(stats.has("registry_" + "slots")).is_false()
	renderer.free()

	assert_bool(FileAccess.file_exists("res://src/core/world/prototype_registry.gd")).is_false()
	assert_bool(FileAccess.file_exists("res://src/core/world/prototype_batch.gd")).is_false()
	assert_bool(FileAccess.file_exists("res://src/core/world/shaders/lod_crossfade_multimesh.gdshader")).is_false()

	_assert_source_lacks(
		"res://src/core/world/static_object_renderer.gd",
		[
			"PrototypeRegistryScript",
			"PrototypeBatchScript",
			"_prototype_registry",
			"USE_PROTOTYPE_REGISTRY",
			"registry_id",
			"registry_" + "batches",
			"registry_" + "slots",
			"tick_prototype_cull",
			"defer_prototype_uploads",
			"get_prototype_registry_distribution",
			"REGISTRY_FADE_DURATION_S",
		]
	)
	_assert_source_lacks(
		"res://src/core/world/native_streaming_manager.gd",
		[
			"tick_prototype_cull",
			"defer_prototype_uploads",
			"STATIC_CULL_BATCH_BUDGET_PER_FRAME",
			"STATIC_CULL_UPLOAD_DEFER_FRAMES_AFTER_UNLOAD",
			"WorldMidCuller",
		]
	)
	_assert_source_lacks(
		"res://src/core/world/streaming_config.gd",
		[
			"STATIC_CULL_BATCH_BUDGET_PER_FRAME",
			"STATIC_CULL_UPLOAD_DEFER_FRAMES_AFTER_UNLOAD",
			"STATIC_CULL_NATIVE_ENABLED",
			"INITIAL_BATCH_CAPACITY",
			"MAX_BATCH_CAPACITY",
		]
	)
	_assert_source_lacks(
		"res://src/core/native_bridge.gd",
		[
			"create_world_mid_culler",
			"CreateWorldMidCuller",
		]
	)
	_assert_source_lacks(
		"res://src/tools/world_explorer.gd",
		[
			"proto_registry",
			"_cmd_proto_registry",
			"_format_proto_registry_distribution",
			"get_prototype_registry_distribution",
		]
	)


func test_spring_cleanup_slice_6_hlod_coverage_uses_object_ids() -> void:
	_assert_source_lacks(
		"res://src/core/world/object_paging.gd",
		[
			"source_ref_nums",
		]
	)
	_assert_source_lacks(
		"res://src/core/world/native_streaming_manager.gd",
		[
			"set_hlod_covered_ref_nums",
			"source_ref_nums",
		]
	)
	_assert_source_lacks(
		"res://src/core/world/native_impostor_renderer.gd",
		[
			"set_hlod_covered_ref_nums",
			"_hlod_covered_ref_nums",
		]
	)


func test_spring_cleanup_slice_7_seamless_interior_controls_stay_out_of_main_scene() -> void:
	_assert_source_lacks(
		"res://src/tools/world_explorer.gd",
		[
			"Seamless interior transitions",
			"seamless_check",
			"_pocket_manager.seamless_enabled =",
		]
	)


func _assert_source_lacks(path: String, forbidden_patterns: Array[String]) -> void:
	var source := FileAccess.get_file_as_string(path)
	assert_str(source).is_not_empty()
	for pattern: String in forbidden_patterns:
		assert_bool(source.find(pattern) == -1) \
			.override_failure_message("%s still contains private reach-through pattern: %s" % [path, pattern]) \
			.is_true()
