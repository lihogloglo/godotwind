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
			"init_async_start_msec": 700,
			"init_async_done_msec": 1900,
			"first_playable_msec": 5100,
		},
		"phase_times_ms": {"BSA archives": 12},
		"inner_ring": {"ring_loaded": 9, "ring_total": 9},
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
	assert_dict(payload["raw_outputs"]).contains_key("summary_json")
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
