extends GdUnitTestSuite

const LifetimeProbeReportScript := preload("res://src/tools/lifetime_probe_report.gd")
const ReportContract := preload("res://src/tools/performance_report_contract.gd")


func test_build_uses_report_contract_and_lifetime_deltas() -> void:
	var payload: Dictionary = LifetimeProbeReportScript.build({
		"loop_count": 1,
		"samples": [
			{
				"label": "baseline",
				"timestamp_msec": 100,
				"object_count": 10,
				"resource_count": 4,
				"node_count": 3,
				"orphan_node_count": 0,
				"static_memory_mb": 20.0,
			},
			{
				"label": "after_teleport_1",
				"timestamp_msec": 2100,
				"object_count": 12,
				"resource_count": 5,
				"node_count": 4,
				"orphan_node_count": 1,
				"static_memory_mb": 22.5,
			},
		],
	}, "user://benchmark_results/lifetime_probe_test.json")

	assert_str(payload["schema"]).is_equal(ReportContract.SCHEMA)
	assert_str(payload["scenario"]).is_equal("fast_travel_streaming")
	assert_str(payload["mode"]).is_equal("object_lifetime_probe")
	assert_float(payload["duration_s"]).is_equal(2.0)
	assert_bool(payload["valid_for_performance_baseline"]).is_true()
	assert_dict(payload["summary"]).contains_key_value("object_delta", 2)
	assert_dict(payload["summary"]).contains_key_value("resource_delta", 1)
	assert_dict(payload["summary"]).contains_key_value("node_delta", 1)
	assert_dict(payload["summary"]).contains_key_value("orphan_node_delta", 1)
	assert_dict(payload["raw_outputs"]).contains_key("summary_json")
	var parsed: Variant = JSON.parse_string(JSON.stringify(payload))
	assert_bool(parsed is Dictionary).is_true()


func test_too_few_samples_marks_probe_invalid() -> void:
	var payload: Dictionary = LifetimeProbeReportScript.build({"samples": []})

	assert_bool(payload["valid_for_performance_baseline"]).is_false()
	assert_array(payload["invalid_reasons"]).contains(["too_few_lifetime_samples"])
