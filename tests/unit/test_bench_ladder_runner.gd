## Smoke tests for BenchLadderRunner — scenario-independent helpers.
##
## The full rung loop is a Godot _process behaviour driven by SubsystemToggles
## + Performance monitors — exercised only at runtime via --bench-ladder. This
## suite guards the pure functions: rung labeling, cumulative flag derivation,
## sample aggregation, JSON serialisation shape.
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


func test_summarize_empty_samples() -> void:
	var runner := BenchLadderRunnerScript.new()
	var summary: Dictionary = runner._summarize([])
	assert_dict(summary).contains_key_value("samples", 0)
	assert_int(summary.size()).is_equal(1)
	runner.free()


func test_summarize_aggregates_and_maxes() -> void:
	var runner := BenchLadderRunnerScript.new()
	var samples: Array[Dictionary] = [
		{
			"fps": 55.0, "draws": 6000, "objs": 9000, "prims": 1_500_000,
			"vram_mb": 2000.0, "mid_visible": 4000, "registry_slots": 10_000,
			"registry_batches": 300, "hlod_cells": 8, "total_impostors": 40_000,
		},
		{
			"fps": 65.0, "draws": 7000, "objs": 11_000, "prims": 2_500_000,
			"vram_mb": 2100.0, "mid_visible": 5000, "registry_slots": 14_000,
			"registry_batches": 500, "hlod_cells": 12, "total_impostors": 51_000,
		},
	]
	var summary: Dictionary = runner._summarize(samples)
	assert_int(summary["samples"]).is_equal(2)
	assert_float(summary["fps_min"]).is_equal(55.0)
	assert_float(summary["fps_max"]).is_equal(65.0)
	assert_float(summary["fps_avg"]).is_equal_approx(60.0, 0.001)
	assert_float(summary["draws_avg"]).is_equal_approx(6500.0, 0.001)
	assert_float(summary["objs_avg"]).is_equal_approx(10_000.0, 0.001)
	# _max fields pick the highest across samples regardless of ordering.
	assert_float(summary["vram_mb_max"]).is_equal(2100.0)
	assert_int(summary["mid_visible_max"]).is_equal(5000)
	assert_int(summary["registry_slots_max"]).is_equal(14_000)
	assert_int(summary["registry_batches_max"]).is_equal(500)
	assert_int(summary["hlod_cells_max"]).is_equal(12)
	assert_int(summary["impostors_max"]).is_equal(51_000)
	runner.free()


func test_sample_once_per_second_dedup() -> void:
	var runner := BenchLadderRunnerScript.new()
	var out: Array[Dictionary] = []
	runner._sample_once_per_second(0.1, out)
	runner._sample_once_per_second(0.5, out)
	runner._sample_once_per_second(0.9, out)
	assert_int(out.size()).is_equal(1)
	runner._sample_once_per_second(1.0, out)
	runner._sample_once_per_second(1.4, out)
	assert_int(out.size()).is_equal(2)
	runner._sample_once_per_second(14.9, out)
	assert_int(out.size()).is_equal(3)
	runner.free()


func test_ladder_add_order_covers_all_toggle_names() -> void:
	# The ladder must enumerate every flag wired into SubsystemToggles at
	# world_explorer._setup_subsystem_toggles. A missing flag means the final
	# rung wouldn't actually reflect "full world" cost, biasing the delta
	# reading for every subsystem above it.
	var expected_flags: Array[String] = [
		"terrain", "ocean", "sky", "weather", "characters",
		"impostors", "mid_objects", "near_objects", "hlod",
		"shadows", "postfx",
	]
	var ladder: Array[String] = BenchLadderRunnerScript.LADDER_ADD_ORDER
	assert_int(ladder.size()).is_equal(expected_flags.size())
	for f: String in expected_flags:
		assert_bool(ladder.has(f)).override_failure_message(
			"ladder missing toggle flag '%s' — would skew cumulative measurement" % f
		).is_true()


func test_summary_round_trips_through_json() -> void:
	var runner := BenchLadderRunnerScript.new()
	var samples: Array[Dictionary] = [
		{
			"fps": 60.0, "draws": 6500, "objs": 9500, "prims": 2_000_000,
			"vram_mb": 2050.0, "mid_visible": 4500, "registry_slots": 12_000,
			"registry_batches": 400, "hlod_cells": 10, "total_impostors": 45_000,
		},
	]
	var summary: Dictionary = runner._summarize(samples)
	var text: String = JSON.stringify(summary)
	assert_str(text).is_not_empty()
	var parsed: Variant = JSON.parse_string(text)
	assert_bool(parsed is Dictionary).is_true()
	var pd: Dictionary = parsed as Dictionary
	assert_int(int(pd["samples"])).is_equal(1)
	assert_float(float(pd["fps_avg"])).is_equal(60.0)
	runner.free()
