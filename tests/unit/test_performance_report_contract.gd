extends GdUnitTestSuite

const ReportContract := preload("res://src/tools/performance_report_contract.gd")


func test_apply_adds_required_contract_fields() -> void:
	var mode_meta := {
		"valid_for_performance_baseline": false,
		"invalid_reasons": ["sync_fallback"],
	}
	var payload := ReportContract.apply({
		"timestamp": "2026-06-17T10:00:00",
		"benchmark_mode_metadata": mode_meta,
	}, {
		"scenario": "flythrough_streaming",
		"mode": "scripted",
		"summary": {"total_time_s": 85.0, "avg_fps": 120.0},
		"benchmark_mode_metadata": mode_meta,
		"raw_outputs": {"summary_json": "user://benchmark_results/summary.json"},
	})

	assert_str(payload["schema"]).is_equal(ReportContract.SCHEMA)
	assert_str(payload["scenario"]).is_equal("flythrough_streaming")
	assert_str(payload["mode"]).is_equal("scripted")
	assert_float(payload["duration_s"]).is_equal(85.0)
	assert_bool(payload["valid_for_performance_baseline"]).is_false()
	assert_array(payload["invalid_reasons"]).contains(["sync_fallback"])
	assert_dict(payload["summary"]).contains_key_value("avg_fps", 120.0)
	assert_dict(payload["raw_outputs"]).contains_key("summary_json")
	assert_bool(payload.has("git_commit")).is_true()
	assert_bool(payload.has("worktree_dirty")).is_true()
	assert_bool(payload.has("renderer")).is_true()
	assert_bool(payload.has("headless")).is_true()


func test_apply_deduplicates_invalid_and_threshold_reasons() -> void:
	var payload := ReportContract.apply({}, {
		"scenario": "stress_rapid_cell_crossing",
		"mode": "stress",
		"benchmark_mode_metadata": {
			"valid_for_performance_baseline": false,
			"invalid_reasons": ["near_only", "near_only"],
		},
		"invalid_reasons": ["near_only", "headless"],
		"threshold_failures": ["frames_over_50:2", "frames_over_50:2"],
	})

	assert_array(payload["invalid_reasons"]).contains_exactly(["near_only", "headless"])
	assert_array(payload["threshold_failures"]).contains_exactly(["frames_over_50:2"])


func test_apply_round_trips_through_json() -> void:
	var payload := ReportContract.apply({}, {
		"scenario": "bench_ladder",
		"mode": "ladder",
		"summary": {"rung_count": 2},
	})
	var text := JSON.stringify(payload)
	var parsed: Variant = JSON.parse_string(text)

	assert_bool(parsed is Dictionary).is_true()
	assert_str((parsed as Dictionary)["schema"]).is_equal(ReportContract.SCHEMA)
