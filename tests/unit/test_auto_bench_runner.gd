## Smoke tests for AutoBenchRunner helpers — summary math + per-second bucket
## sampling. No scene-tree access, no streaming manager, no GPU. Runs fast.
##
## The three full scenarios (C tiers / D flyby / E teleport / F hlod_off) are
## end-to-end behaviours driven by the Godot _process loop + Performance
## monitors and can only be exercised by a live scene. Those runs are the
## whole reason the autonomous audit launch exists — this suite just guards
## against accidental regressions to the scenario-independent helpers.
extends GdUnitTestSuite

const AutoBenchRunnerScript := preload("res://src/tools/auto_bench_runner.gd")


func test_settle_gate_is_bounded_for_moving_camera_benchmarks() -> void:
	assert_float(AutoBenchRunnerScript.SETTLE_FPS_TARGET).is_equal(50.0)
	assert_float(AutoBenchRunnerScript.SETTLE_WINDOW_SEC).is_equal(3.0)
	assert_float(AutoBenchRunnerScript.SETTLE_FALLBACK_SEC).is_less_equal(60.0)


func test_summarize_empty_samples() -> void:
	var runner := AutoBenchRunnerScript.new()
	var summary: Dictionary = runner._summarize([])
	assert_dict(summary).contains_key_value("samples", 0)
	# No other keys on empty — consumer JSON stays compact.
	assert_int(summary.size()).is_equal(1)
	runner.free()


func test_summarize_single_sample_reports_min_equals_max() -> void:
	var runner := AutoBenchRunnerScript.new()
	var samples: Array[Dictionary] = [{
		"fps": 60.0, "draws": 7000, "objs": 10000,
		"total_impostors": 800, "hlod_cells": 12,
		"chunks_tier_1": 4, "chunks_tier_2": 1,
		"pub_static_visuals_spent_us": 1200,
		"pub_near_gameplay_spent_us": 3400,
		"inst_classify_us": 900,
		"inst_model_loader_phase_a_us": 600,
		"inst_model_loader_phase_b_us": 250,
		"inst_model_loader_get_us": 200,
		"inst_model_loader_completed": 2,
		"inst_loop_us": 1700,
	}]
	var summary: Dictionary = runner._summarize(samples)
	assert_int(summary["samples"]).is_equal(1)
	assert_float(summary["fps_min"]).is_equal(60.0)
	assert_float(summary["fps_max"]).is_equal(60.0)
	assert_float(summary["fps_avg"]).is_equal(60.0)
	assert_float(summary["draws_avg"]).is_equal(7000.0)
	assert_bool(summary.has("registry_" + "batches_max")).is_false()
	assert_bool(summary.has("registry_" + "slots_max")).is_false()
	assert_int(summary["impostors_max"]).is_equal(800)
	assert_int(summary["hlod_cells_max"]).is_equal(12)
	assert_int(summary["chunks_tier_1_max"]).is_equal(4)
	assert_int(summary["chunks_tier_2_max"]).is_equal(1)
	assert_float(summary["pub_static_visuals_spent_us_max"]).is_equal(1200.0)
	assert_float(summary["pub_static_visuals_spent_us_avg"]).is_equal(1200.0)
	assert_float(summary["pub_near_gameplay_spent_us_max"]).is_equal(3400.0)
	assert_float(summary["inst_classify_us_max"]).is_equal(900.0)
	assert_float(summary["inst_model_loader_phase_a_us_avg"]).is_equal(600.0)
	assert_float(summary["inst_model_loader_get_us_max"]).is_equal(200.0)
	assert_float(summary["inst_model_loader_completed_avg"]).is_equal(2.0)
	assert_float(summary["inst_loop_us_avg"]).is_equal(1700.0)
	runner.free()


func test_summarize_multi_sample_aggregates() -> void:
	var runner := AutoBenchRunnerScript.new()
	var samples: Array[Dictionary] = [
		{"fps": 50.0, "draws": 6000, "objs":  9000, "total_impostors": 500, "hlod_cells":  8, "chunks_tier_1": 2, "chunks_tier_2": 0},
		{"fps": 60.0, "draws": 7000, "objs": 10000, "total_impostors": 700, "hlod_cells": 10, "chunks_tier_1": 3, "chunks_tier_2": 1},
		{"fps": 40.0, "draws": 8000, "objs": 11000, "total_impostors": 900, "hlod_cells": 12, "chunks_tier_1": 4, "chunks_tier_2": 1},
	]
	var summary: Dictionary = runner._summarize(samples)
	assert_int(summary["samples"]).is_equal(3)
	assert_float(summary["fps_min"]).is_equal(40.0)
	assert_float(summary["fps_max"]).is_equal(60.0)
	assert_float(summary["fps_avg"]).is_equal_approx(50.0, 0.001)
	assert_float(summary["draws_avg"]).is_equal_approx(7000.0, 0.001)
	assert_float(summary["objs_avg"]).is_equal_approx(10000.0, 0.001)
	# Max fields pick the highest across samples regardless of ordering.
	assert_bool(summary.has("registry_" + "batches_max")).is_false()
	assert_bool(summary.has("registry_" + "slots_max")).is_false()
	assert_int(summary["impostors_max"]).is_equal(900)
	assert_int(summary["hlod_cells_max"]).is_equal(12)
	assert_int(summary["chunks_tier_1_max"]).is_equal(4)
	assert_int(summary["chunks_tier_2_max"]).is_equal(1)
	runner.free()


func test_sample_once_per_second_dedup() -> void:
	var runner := AutoBenchRunnerScript.new()
	var out: Array[Dictionary] = []
	# Multiple frames within the same integer-second bucket must produce at
	# most one sample. _snapshot_sample reads Performance monitors — in an
	# offline test harness those return zero, which is fine for dedup-only.
	runner._sample_once_per_second(0.1, out)
	runner._sample_once_per_second(0.5, out)
	runner._sample_once_per_second(0.9, out)
	assert_int(out.size()).is_equal(1)
	# Crossing into a new second bucket appends another sample.
	runner._sample_once_per_second(1.0, out)
	assert_int(out.size()).is_equal(2)
	runner._sample_once_per_second(1.9, out)
	assert_int(out.size()).is_equal(2)
	runner._sample_once_per_second(2.4, out)
	assert_int(out.size()).is_equal(3)
	runner.free()


func test_summarize_output_is_json_serializable() -> void:
	# Wire-level check: summarize() output round-trips through JSON without
	# loss. Catches accidental Variant → JSON corruption (e.g. if a future
	# patch dumps a RID into a sample).
	var runner := AutoBenchRunnerScript.new()
	var samples: Array[Dictionary] = [
		{"fps": 55.0, "draws": 6500, "objs": 9500, "total_impostors": 500, "hlod_cells": 8, "chunks_tier_1": 2, "chunks_tier_2": 0},
		{"fps": 60.0, "draws": 6700, "objs": 9700, "total_impostors": 600, "hlod_cells": 10, "chunks_tier_1": 3, "chunks_tier_2": 1},
	]
	var summary: Dictionary = runner._summarize(samples)
	var text: String = JSON.stringify(summary)
	assert_str(text).is_not_empty()
	var parsed: Variant = JSON.parse_string(text)
	assert_bool(parsed is Dictionary).is_true()
	var pd: Dictionary = parsed as Dictionary
	assert_int(int(pd["samples"])).is_equal(2)
	assert_float(float(pd["fps_min"])).is_equal(55.0)
	assert_float(float(pd["fps_max"])).is_equal(60.0)
	runner.free()
