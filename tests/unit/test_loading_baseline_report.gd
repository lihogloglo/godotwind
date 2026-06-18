extends GdUnitTestSuite

const LoadingBaselineReportScript := preload("res://src/tools/loading_baseline_report.gd")
const ReportContract := preload("res://src/tools/performance_report_contract.gd")


func test_build_uses_report_contract_and_loading_summary() -> void:
	var payload: Dictionary = LoadingBaselineReportScript.build({
		"scenario": "cold",
		"cache_state": "cold",
		"reason": "boot",
		"duration_s": 4.5,
		"timed_out": false,
		"timestamps": {
			"process_start_msec": 100,
			"ready_msec": 600,
			"show_loading_msec": 650,
			"init_async_start_msec": 700,
			"first_update_loading_before_await_msec": 705,
			"first_update_loading_after_await_msec": 722,
			"terrain3d_init_start_msec": 1000,
			"terrain3d_init_done_msec": 1030,
			"terrain_import_start_msec": 1040,
			"terrain_import_done_msec": 1090,
			"horizon_maps_start_msec": 1100,
			"horizon_maps_done_msec": 1130,
			"terrain_texture_bridge_start_msec": 1135,
			"terrain_texture_bridge_done_msec": 1210,
			"hide_loading_start_msec": 1850,
			"hide_loading_done_msec": 1870,
			"init_async_done_msec": 1900,
			"teleport_to_cell_start_msec": 1950,
			"teleport_to_cell_done_msec": 2010,
			"subsystem_toggles_start_msec": 2030,
			"subsystem_toggles_done_msec": 2090,
			"streaming_set_camera_start_msec": 2100,
			"streaming_set_camera_done_msec": 2200,
			"first_process_after_tracking_start_msec": 2216,
			"boot_gate_start_msec": 2300,
			"first_playable_msec": 5100,
		},
		"phase_times_ms": {
			"mod registry": 3,
			"BSA archives": 12,
			"ESM load (primary)": 80,
			"Terrain3D init": 7,
			"terrain data load": 11,
			"horizon maps": 5,
			"terrain texture bridge": 13,
			"preload common models": 13,
		},
		"esm_primary_timing": {
			"native_primary_ms": 50,
			"gdscript_populate_ms": 20,
			"gdscript_supplement_ms": 10,
			"gdscript_supplement_populate_ms": 30,
		},
		"loading_gate_phase_totals_ms": {
			"cell_manager_publication": 44,
		},
		"loading_gate_phase_frames": 4,
		"inner_ring": {"ring_loaded": 9, "ring_total": 9},
		"bsa_cache": {"entries": 2},
		"model_loader": {"cached_models": 3},
		"streaming": {
			"benchmark_mode_metadata": {
				"valid_for_performance_baseline": true,
				"invalid_reasons": [],
			},
		},
	}, "user://benchmark_results/loading_baseline_test.json")

	assert_str(payload["schema"]).is_equal(ReportContract.SCHEMA)
	assert_str(payload["scenario"]).is_equal("cold_start")
	assert_str(payload["mode"]).is_equal("loading_baseline")
	assert_bool(payload["valid_for_performance_baseline"]).is_true()
	assert_float(payload["duration_s"]).is_equal(5.0)
	assert_dict(payload["summary"]).contains_key_value("loading_gate_duration_s", 4.5)
	assert_dict(payload["summary"]).contains_key_value("process_start_to_first_playable_s", 5.0)
	assert_dict(payload["summary"]["first_playable_attribution_ms"]).contains_key_value("esm_native_primary_ms", 50.0)
	assert_dict(payload["summary"]["first_playable_attribution_ms"]).contains_key_value("gdscript_supplement_populate_ms", 30.0)
	assert_dict(payload["summary"]["first_playable_attribution_ms"]).contains_key_value("bsa_cache_ms", 12.0)
	assert_dict(payload["summary"]["first_playable_attribution_ms"]).contains_key_value("terrain_ms", 36.0)
	assert_dict(payload["summary"]["first_playable_attribution_ms"]).contains_key_value("model_material_warmup_ms", 13.0)
	assert_dict(payload["summary"]["first_playable_attribution_ms"]).contains_key_value("inner_ring_gate_wait_ms", 4500.0)
	assert_dict(payload["summary"]["first_playable_attribution_ms"]).contains_key_value("source_data_other_ms", 3.0)
	assert_dict(payload["summary"]["first_playable_attribution_ms"]).contains_key_value("engine_scene_ready_ms", 500.0)
	assert_dict(payload["summary"]["first_playable_attribution_ms"]).contains_key_value("ready_to_init_async_start_ms", 100.0)
	assert_dict(payload["summary"]["first_playable_attribution_ms"]).contains_key_value("init_async_other_ms", 1056.0)
	assert_dict(payload["summary"]["first_playable_attribution_ms"]).contains_key_value("post_init_to_boot_gate_ms", 400.0)
	assert_dict(payload["summary"]["loading_gap_breakdown_ms"]).contains_key_value("first_update_loading_await", 17.0)
	assert_dict(payload["summary"]["loading_gap_breakdown_ms"]).contains_key_value("terrain_texture_bridge", 75.0)
	assert_dict(payload["summary"]["loading_gap_breakdown_ms"]).contains_key_value("set_camera_done_to_boot_gate", 100.0)
	assert_dict(payload["loading_gap_breakdown_ms"]).contains_key_value("set_camera_done_to_first_process", 16.0)
	assert_float(payload["summary"]["source_data_total_ms"]).is_equal(95.0)
	assert_float(payload["summary"]["cell_manager_publication_ms"]).is_equal(44.0)
	assert_bool((payload["first_playable_attribution"] as Dictionary).has("cell_manager_publication_note")).is_true()
	assert_dict(payload["bsa_cache"]).contains_key_value("entries", 2)
	assert_dict(payload["model_loader"]).contains_key_value("cached_models", 3)
	assert_bool((payload["raw_outputs"] as Dictionary).has("summary_json")).is_true()
	var parsed: Variant = JSON.parse_string(JSON.stringify(payload))
	assert_bool(parsed is Dictionary).is_true()


func test_timeout_marks_report_invalid() -> void:
	var payload: Dictionary = LoadingBaselineReportScript.build({
		"scenario": "first_playable",
		"timed_out": true,
		"timestamps": {
			"process_start_msec": 100,
			"first_playable_msec": 30100,
		},
	})

	assert_bool(payload["valid_for_performance_baseline"]).is_false()
	assert_array(payload["invalid_reasons"]).contains(["loading_gate_timeout"])
