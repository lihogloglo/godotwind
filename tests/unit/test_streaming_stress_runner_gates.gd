## Smoke tests for StreamingStressRunner gate collection.
##
## These stay scene-independent: the full stress run needs Godotwind.tscn, but
## gate decisions are pure dictionary logic and should not regress silently.
extends GdUnitTestSuite

const StreamingStressRunnerScript := preload("res://src/tools/streaming_stress_runner.gd")
const BenchmarkThresholdsScript := preload("res://tests/benchmark/benchmark_thresholds.gd")


func test_static_prepare_log_token_fails_gate() -> void:
	var runner := StreamingStressRunnerScript.new()
	var reasons: Array[String] = runner._collect_gate_failure_reasons(
		_base_summary(),
		{"reasons": ["[static-prepare-spike"], "unverified": false}
	)
	assert_bool(reasons.has("[static-prepare-spike")).is_true()
	runner.free()


func test_max_frame_over_blocking_threshold_fails_gate() -> void:
	var runner := StreamingStressRunnerScript.new()
	var summary := _base_summary()
	summary["max_ms"] = BenchmarkThresholdsScript.BLOCKING_FRAME_MS + 0.25
	var reasons: Array[String] = runner._collect_gate_failure_reasons(
		summary,
		{"reasons": [], "unverified": false}
	)
	assert_bool(_has_reason_prefix(reasons, "max_frame_ms:")).is_true()
	runner.free()


func test_stream_total_over_blocking_threshold_fails_gate() -> void:
	var runner := StreamingStressRunnerScript.new()
	var summary := _base_summary()
	summary["max_stream_total_ms"] = BenchmarkThresholdsScript.STREAMING_PUBLISH_BLOCKING_MS + 0.25
	var reasons: Array[String] = runner._collect_gate_failure_reasons(
		summary,
		{"reasons": [], "unverified": false}
	)
	assert_bool(_has_reason_prefix(reasons, "max_stream_total_ms:")).is_true()
	runner.free()


func test_static_publish_spike_field_fails_gate() -> void:
	var runner := StreamingStressRunnerScript.new()
	var summary := _base_summary()
	summary["max_inst_static_ms"] = BenchmarkThresholdsScript.STATIC_PUBLISH_SPIKE_MS + 0.25
	var reasons: Array[String] = runner._collect_gate_failure_reasons(
		summary,
		{"reasons": [], "unverified": false}
	)
	assert_bool(_has_reason_prefix(reasons, "max_static_publish_ms:")).is_true()
	runner.free()


func test_far_cell_scan_spike_field_fails_gate() -> void:
	var runner := StreamingStressRunnerScript.new()
	var summary := _base_summary()
	summary["max_far_cell_scan_ms"] = BenchmarkThresholdsScript.SPIKE_FRAME_MS + 0.25
	var reasons: Array[String] = runner._collect_gate_failure_reasons(
		summary,
		{"reasons": [], "unverified": false}
	)
	assert_bool(_has_reason_prefix(reasons, "max_far_cell_scan_ms:")).is_true()
	runner.free()


func test_absent_optional_spike_fields_do_not_fail_gate() -> void:
	var runner := StreamingStressRunnerScript.new()
	var reasons: Array[String] = runner._collect_gate_failure_reasons(
		_base_summary(),
		{"reasons": [], "unverified": false}
	)
	assert_int(reasons.size()).is_equal(0)
	runner.free()


func test_invalid_benchmark_mode_fails_gate() -> void:
	var runner := StreamingStressRunnerScript.new()
	var summary := _base_summary()
	summary["benchmark_mode_metadata"] = {
		"valid_for_performance_baseline": false,
		"invalid_reasons": ["sync_loading_mode"],
	}
	var reasons: Array[String] = runner._collect_gate_failure_reasons(
		summary,
		{"reasons": [], "unverified": false}
	)
	assert_bool(reasons.has("benchmark_invalid:sync_loading_mode")).is_true()
	runner.free()


func test_thresholds_keep_legacy_symbols_with_bible_values() -> void:
	assert_float(BenchmarkThresholdsScript.FRAME_BUDGET_MS).is_equal_approx(6.67, 0.001)
	assert_float(BenchmarkThresholdsScript.LEGACY_SHARED_STREAMING_BUDGET_MS).is_equal_approx(8.0, 0.001)
	assert_float(BenchmarkThresholdsScript.STREAMING_PUBLISH_BUDGET_MS).is_equal_approx(1.0, 0.001)
	assert_float(BenchmarkThresholdsScript.RENDER_BUDGET_MS).is_equal_approx(3.5, 0.001)
	assert_float(BenchmarkThresholdsScript.BLOCKING_FRAME_MS).is_equal_approx(50.0, 0.001)


func test_landscape_spiral_offsets_cover_square_without_duplicates() -> void:
	var runner := StreamingStressRunnerScript.new()
	var offsets: Array[Vector2i] = runner._build_spiral_offsets(2)
	var seen := {}
	for offset: Vector2i in offsets:
		seen[offset] = true
	assert_bool(offsets[0] == Vector2i.ZERO).is_true()
	assert_int(offsets.size()).is_equal(25)
	assert_int(seen.size()).is_equal(25)
	assert_bool(seen.has(Vector2i(2, 2))).is_true()
	assert_bool(seen.has(Vector2i(-2, -2))).is_true()
	runner.free()


func _base_summary() -> Dictionary:
	return {
		"route_setup_failures": [],
		"lifecycle_event_counts": {},
		"frames_over_50": 0,
	}


func _has_reason_prefix(reasons: Array[String], prefix: String) -> bool:
	for reason: String in reasons:
		if reason.begins_with(prefix):
			return true
	return false
