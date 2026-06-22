## Smoke tests for BenchLadderRunner — scenario-independent helpers.
##
## The full rung loop is a Godot _process behaviour driven by SubsystemToggles
## + StreamingBenchmark — exercised only at runtime via --bench-ladder. This
## suite guards the pure functions: rung labeling, cumulative flag derivation,
## flyby summary normalization, JSON serialisation shape.
extends GdUnitTestSuite

const BenchLadderRunnerScript := preload("res://src/tools/bench_ladder_runner.gd")


func test_rung_zero_is_empty() -> void:
	var runner := BenchLadderRunnerScript.new()
	assert_str(runner._rung_label(0)).is_equal("empty")
	var flags: Array[String] = runner._enabled_flags_for_rung(0)
	assert_int(flags.size()).is_equal(0)
	runner.free()


func test_rung_one_has_first_ladder_flag() -> void:
	var runner := BenchLadderRunnerScript.new()
	var expected_first: String = BenchLadderRunnerScript.LADDER_ADD_ORDER[0]
	assert_str(runner._rung_label(1)).is_equal("+" + expected_first)
	var flags: Array[String] = runner._enabled_flags_for_rung(1)
	assert_int(flags.size()).is_equal(1)
	assert_str(flags[0]).is_equal(expected_first)
	runner.free()


func test_rung_is_cumulative_additive() -> void:
	# The ladder must be strictly cumulative — rung N contains every flag
	# present in rung N-1, plus exactly one new one. Anything else means the
	# delta between adjacent rungs stops being "cost of this subsystem" and
	# starts being "cost of swapping subsystem A for B", which is a different
	# measurement.
	var runner := BenchLadderRunnerScript.new()
	var prev_flags: Array[String] = []
	for i in range(BenchLadderRunnerScript.LADDER_ADD_ORDER.size() + 1):
		var flags: Array[String] = runner._enabled_flags_for_rung(i)
		assert_int(flags.size()).is_equal(i)
		for p: String in prev_flags:
			assert_bool(flags.has(p)).override_failure_message(
				"rung %d lost flag '%s' from rung %d" % [i, p, i - 1]
			).is_true()
		prev_flags = flags
	runner.free()


func test_rung_beyond_ladder_label() -> void:
	var runner := BenchLadderRunnerScript.new()
	var last_rung: int = BenchLadderRunnerScript.LADDER_ADD_ORDER.size()
	assert_str(runner._rung_label(last_rung)).is_equal(
		"+" + BenchLadderRunnerScript.LADDER_ADD_ORDER[last_rung - 1]
	)
	# Beyond the ladder returns "all" (defensive — state machine should never
	# ask for this, but the helper must degrade gracefully).
	assert_str(runner._rung_label(last_rung + 1)).is_equal("all")
	runner.free()


func test_summary_from_empty_flyby() -> void:
	var runner := BenchLadderRunnerScript.new()
	var summary: Dictionary = runner._summary_from_flyby({})
	assert_int(summary["samples"]).is_equal(0)
	assert_float(summary["fps_avg"]).is_equal(0.0)
	assert_float(summary["draws_avg"]).is_equal(0.0)
	runner.free()


func test_summary_from_flyby_preserves_streaming_results() -> void:
	var runner := BenchLadderRunnerScript.new()
	var results := {
		"total_frames": 1234,
		"avg_fps": 72.5,
		"avg_draw_calls": 345,
		"p95_ms": 18.25,
		"pub_static_visuals_spent_us_avg": 1200.0,
		"segments": {"walk": {"avg": 14.0}},
	}
	var summary: Dictionary = runner._summary_from_flyby(results)
	assert_int(summary["samples"]).is_equal(1234)
	assert_float(summary["fps_avg"]).is_equal(72.5)
	assert_float(summary["draws_avg"]).is_equal(345.0)
	assert_float(summary["p95_ms"]).is_equal(18.25)
	assert_float(summary["pub_static_visuals_spent_us_avg"]).is_equal(1200.0)
	assert_bool((summary["segments"] as Dictionary).has("walk")).is_true()
	runner.free()


func test_summarize_publication_samples_reports_avg_and_max() -> void:
	var runner := BenchLadderRunnerScript.new()
	var samples: Array[Dictionary] = [
		{"pub_static_visuals_spent_us": 100.0, "pub_static_visuals_overrun_us": 0.0},
		{"pub_static_visuals_spent_us": 300.0, "pub_static_visuals_overrun_us": 75.0},
	]
	var summary: Dictionary = runner._summarize_publication_samples(samples)
	assert_int(summary["publication_samples"]).is_equal(2)
	assert_float(summary["pub_static_visuals_spent_us_avg"]).is_equal(200.0)
	assert_float(summary["pub_static_visuals_spent_us_max"]).is_equal(300.0)
	assert_float(summary["pub_static_visuals_overrun_us_max"]).is_equal(75.0)
	runner.free()


func test_final_summary_rows_include_toggle_snapshot_and_publication_metrics() -> void:
	var runner := BenchLadderRunnerScript.new()
	runner._rungs = [{
		"rung": 3,
		"label": "+static_visuals",
		"enabled": ["terrain", "near_gameplay", "static_visuals"],
		"toggle_state": {"terrain": true, "near_gameplay": true, "static_visuals": true, "hlod": false},
		"summary": {
			"fps_avg": 34.0,
			"final_mid_stats": {
				"cell_buckets": 80,
				"bucket_draw_groups": 1200,
				"bucket_rs_instances": 1200,
			},
			"final_mid_bucket_census": {
				"singleton_draw_groups": 900,
				"multimesh_draw_groups": 300,
				"direct_rs_instances": 14,
				"top_bucket_contributors_by_draw_groups": [{"bucket_key": "0,0:a", "draw_group_count": 5}],
				"top_singleton_heavy_bucket_contributors": [{"bucket_key": "0,0:b", "singleton_draw_groups": 4}],
				"direct_static_duplicate_candidate_count": 2,
				"direct_static_duplicate_candidate_rs_instances": 3,
				"top_direct_static_duplicate_candidates": [{"cell": "0,0", "type_name": "a", "rs_instances": 3}],
				"per_cell_mid_hotspots": [{"cell": "0,0", "bucket_draw_groups": 5, "direct_rs_instances": 3}],
			},
			"final_streaming_stats": {
				"desired_cell_count": 45,
				"static_visual_only_cells": 32,
				"gameplay_upgrade_requests": 4,
			},
			"pub_static_visuals_spent_us_avg": 2400.0,
			"pub_static_visuals_overrun_us_max": 900.0,
		},
	}]
	var final_summary: Dictionary = runner._build_final_summary()
	var row: Dictionary = final_summary["rows"][0]
	assert_bool((row["enabled"] as Array).has("static_visuals")).is_true()
	assert_dict(row["toggle_state"]).contains_key_value("hlod", false)
	assert_int(int(row["mid_cell_buckets"])).is_equal(80)
	assert_int(int(row["mid_bucket_draw_groups"])).is_equal(1200)
	assert_int(int(row["mid_singleton_draw_groups"])).is_equal(900)
	assert_int(int(row["mid_direct_rs_instances"])).is_equal(14)
	assert_int((row["mid_top_bucket_contributors_by_draw_groups"] as Array).size()).is_equal(1)
	assert_str(str((row["mid_top_bucket_contributors_by_draw_groups"] as Array)[0]["bucket_key"])).is_equal("0,0:a")
	assert_int((row["mid_top_singleton_heavy_bucket_contributors"] as Array).size()).is_equal(1)
	assert_int(int(row["mid_direct_static_duplicate_candidate_count"])).is_equal(2)
	assert_int(int(row["mid_direct_static_duplicate_candidate_rs_instances"])).is_equal(3)
	assert_int((row["mid_top_direct_static_duplicate_candidates"] as Array).size()).is_equal(1)
	assert_int((row["mid_per_cell_hotspots"] as Array).size()).is_equal(1)
	assert_int(int(row["desired_cell_count"])).is_equal(45)
	assert_int(int(row["static_visual_only_cells"])).is_equal(32)
	assert_int(int(row["gameplay_upgrade_requests"])).is_equal(4)
	assert_float(row["pub_static_visuals_spent_us_avg"]).is_equal(2400.0)
	assert_float(row["pub_static_visuals_overrun_us_max"]).is_equal(900.0)
	runner.free()


func test_ladder_add_order_covers_all_toggle_names() -> void:
	# The ladder must enumerate every flag wired into SubsystemToggles at
	# world_explorer._setup_subsystem_toggles. A missing flag means the final
	# rung wouldn't actually reflect "full world" cost, biasing the delta
	# reading for every subsystem above it.
	var expected_flags: Array[String] = [
		"terrain", "ocean", "sky", "weather", "characters",
		"far_impostors", "static_visuals", "near_gameplay", "hlod",
		"distant_lights", "shadows", "postfx",
	]
	var ladder: Array[String] = BenchLadderRunnerScript.LADDER_ADD_ORDER
	assert_int(ladder.size()).is_equal(expected_flags.size())
	for f: String in expected_flags:
		assert_bool(ladder.has(f)).override_failure_message(
			"ladder missing toggle flag '%s' — would skew cumulative measurement" % f
		).is_true()


func test_max_rungs_parser_accepts_equals_form() -> void:
	var runner := BenchLadderRunnerScript.new()
	var max_rungs: int = runner._parse_max_rungs(PackedStringArray([
		"--bench-ladder",
		"stamp",
		"--bench-ladder-max-rungs=4",
	]))
	assert_int(max_rungs).is_equal(4)
	runner.free()


func test_max_rungs_parser_accepts_space_form() -> void:
	var runner := BenchLadderRunnerScript.new()
	var max_rungs: int = runner._parse_max_rungs(PackedStringArray([
		"--bench-ladder-max-rungs",
		"3",
	]))
	assert_int(max_rungs).is_equal(3)
	runner.free()


func test_start_rung_parser_accepts_equals_form() -> void:
	var runner := BenchLadderRunnerScript.new()
	var start_rung: int = runner._parse_start_rung(PackedStringArray([
		"--bench-ladder",
		"stamp",
		"--bench-ladder-start-rung=3",
	]))
	assert_int(start_rung).is_equal(3)
	runner.free()


func test_start_rung_parser_accepts_space_form() -> void:
	var runner := BenchLadderRunnerScript.new()
	var start_rung: int = runner._parse_start_rung(PackedStringArray([
		"--bench-ladder-start-rung",
		"2",
	]))
	assert_int(start_rung).is_equal(2)
	runner.free()


func test_effective_rung_count_clamps_to_ladder_bounds() -> void:
	var runner := BenchLadderRunnerScript.new()
	var full_count: int = BenchLadderRunnerScript.LADDER_ADD_ORDER.size() + 1
	assert_int(runner._effective_rung_count()).is_equal(full_count)
	runner._max_rungs = 4
	assert_int(runner._effective_rung_count()).is_equal(4)
	runner._max_rungs = 999
	assert_int(runner._effective_rung_count()).is_equal(full_count)
	runner.free()


func test_effective_start_rung_clamps_to_effective_rungs() -> void:
	var runner := BenchLadderRunnerScript.new()
	runner._max_rungs = 4
	runner._start_rung = 3
	assert_int(runner._effective_start_rung()).is_equal(3)
	runner._start_rung = 99
	assert_int(runner._effective_start_rung()).is_equal(3)
	runner._start_rung = -2
	assert_int(runner._effective_start_rung()).is_equal(0)
	runner.free()


func test_summary_round_trips_through_json() -> void:
	var runner := BenchLadderRunnerScript.new()
	var summary: Dictionary = runner._summary_from_flyby({
		"total_frames": 900,
		"avg_fps": 60.0,
		"avg_draw_calls": 6500,
	})
	var text: String = JSON.stringify(summary)
	assert_str(text).is_not_empty()
	var parsed: Variant = JSON.parse_string(text)
	assert_bool(parsed is Dictionary).is_true()
	var pd: Dictionary = parsed as Dictionary
	assert_int(int(pd["samples"])).is_equal(900)
	assert_float(float(pd["fps_avg"])).is_equal(60.0)
	runner.free()
