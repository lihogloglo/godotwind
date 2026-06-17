extends GdUnitTestSuite

const ProgressiveBenchmarkScript := preload("res://src/tools/progressive_benchmark.gd")
const ReportContract := preload("res://src/tools/performance_report_contract.gd")


func test_progressive_json_uses_report_contract() -> void:
	var runner := ProgressiveBenchmarkScript.new()
	runner._results = [{
		"label": "baseline",
		"avg_fps": 120.0,
		"avg_time_ms": 8.3,
	}]

	var path: String = runner._save_progressive_json("user://benchmark_results/progressive_contract.csv", 1.5)
	assert_str(path).is_not_empty()

	var file := FileAccess.open(path, FileAccess.READ)
	assert_bool(file != null).is_true()
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()

	assert_bool(parsed is Dictionary).is_true()
	var payload := parsed as Dictionary
	assert_str(payload["schema"]).is_equal(ReportContract.SCHEMA)
	assert_str(payload["scenario"]).is_equal("progressive_subsystem_sweep")
	assert_str(payload["mode"]).is_equal("progressive")
	assert_dict(payload["raw_outputs"]).contains_key("csv")
	assert_dict(payload["summary"]).contains_key_value("passes", 1)
	runner.free()
