## BenchLadderRunner — moving-camera subsystem-isolation benchmark.
##
## Cumulative-additive A/B over the 11 `SubsystemToggles` flags: each rung
## enables one more subsystem on top of the previous one, runs the same
## StreamingBenchmark flyby, and writes a single `bench_ladder.json` with all
## rungs. Delta between adjacent rung averages is that subsystem's marginal
## cost over the same moving camera path.
##
## Sibling to `AutoBenchRunner` (which runs scenarios C/D/E/F from the
## autonomous perf-audit handoff). Triggered by `--bench-ladder [stamp]` on
## the command line.
##
## Metrics sourced from Engine/Performance + `NativeStreamingManager.get_stats()` +
## `get_static_renderer_stats()` + `get_hlod_stats()` — no new
## instrumentation, just the same snapshot AutoBenchRunner uses.
##
## Usage:
##   --bench-ladder [stamp]    (see world_explorer._maybe_start_bench_ladder)
class_name BenchLadderRunner
extends Node

const DU := preload("res://src/core/world/distance_utils.gd")
const StreamingBenchmarkScript := preload("res://src/tools/streaming_benchmark.gd")
const NativeStreamingManagerScript := preload("res://src/core/world/native_streaming_manager.gd")
const CellManagerScript := preload("res://src/core/world/cell_manager.gd")
const PerformanceReportContract := preload("res://src/tools/performance_report_contract.gd")

const OUTPUT_DIR_BASE: String = "user://benchmark_results"
static var PUBLICATION_LANES: Array[String] = [
	"near_gameplay",
	"static_visuals",
	"hlod",
	"far_impostors",
	"distant_lights",
	"unload",
]
static var PUBLICATION_SAMPLE_KEYS: Array[String] = [
	"pub_near_gameplay_claimed_us",
	"pub_near_gameplay_spent_us",
	"pub_near_gameplay_overrun_us",
	"pub_static_visuals_claimed_us",
	"pub_static_visuals_spent_us",
	"pub_static_visuals_overrun_us",
	"pub_hlod_claimed_us",
	"pub_hlod_spent_us",
	"pub_hlod_overrun_us",
	"pub_far_impostors_claimed_us",
	"pub_far_impostors_spent_us",
	"pub_far_impostors_overrun_us",
	"pub_distant_lights_claimed_us",
	"pub_distant_lights_spent_us",
	"pub_distant_lights_overrun_us",
	"pub_unload_claimed_us",
	"pub_unload_spent_us",
	"pub_unload_overrun_us",
]

## Wait for either FPS >= target for SETTLE_WINDOW_S or hit the fallback cap.
## Target is intentionally low (20 FPS) because cold-start can be very slow on
## this branch and the ladder tolerates an unsettled start — the per-rung flyby
## captures the settle-to-steady-state trace.
const SETTLE_WINDOW_S: float = 3.0
const SETTLE_FPS_TARGET: float = 20.0
const SETTLE_FALLBACK_S: float = 240.0

## Watchdog — clamp total runtime. 13 rungs × the 85 s flyby is ~18.5 min before
## boot/toggle settle, so keep the cap generous but finite.
const WATCHDOG_S: float = 1800.0

## After applying a rung's toggles, wait this long before the flyby so RS
## instance show/hide churn quiesces (14 k slots flipping visibility is not
## free even though it's cheaper than recreate).
const TOGGLE_APPLY_DELAY_S: float = 3.0

## Cumulative-additive ladder. Each rung layers one flag on top of the
## previous rung's flag set. The zeroth rung disables everything.
## Order: geometry tiers first (user request "NEAR + terrain first"), then
## rendering-stack additions on top.
static var LADDER_ADD_ORDER: Array[String] = [
	"terrain",
	"near_gameplay",
	"static_visuals",
	"hlod",
	"far_impostors",
	"distant_lights",
	"sky",
	"ocean",
	"weather",
	"postfx",
	"shadows",
	"characters",
]

signal ladder_complete(summary: Dictionary)


var _streaming_manager: NativeStreamingManagerScript = null
var _cell_manager: CellManagerScript = null
var _camera: Camera3D = null
var _world_explorer: Node = null
var _toggles: RefCounted = null  # SubsystemToggles
var _stamp: String = ""
var _output_dir: String = ""
var _started_msec: int = 0
var _settle_elapsed: float = 0.0
var _max_rungs: int = 0
## User FPS cap saved at setup, restored at finish (0 = was uncapped).
var _saved_max_fps: int = 0
## User vsync mode saved at setup, restored at finish.
var _saved_vsync_mode: DisplayServer.VSyncMode = DisplayServer.VSYNC_DISABLED

## State: waiting_settle -> apply_rung -> toggle_settle -> flyby -> (next rung) -> done
var _state: String = "waiting_settle"
var _state_elapsed: float = 0.0

## Rung index: 0..LADDER_ADD_ORDER.size() inclusive. 0 = empty baseline,
## 1 = +LADDER_ADD_ORDER[0] cumulative, ..., N = all flags.
var _rung_idx: int = 0

## Per-rung flyby results. _rungs[i] = {label, enabled, summary}.
var _rungs: Array[Dictionary] = []
var _active_bench: StreamingBenchmarkScript = null
var _current_publication_samples: Array[Dictionary] = []
var _last_publication_sample_sec_bucket: int = -1
var _start_rung: int = 0


func configure(
	streaming_manager: NativeStreamingManagerScript,
	cell_manager: CellManagerScript,
	camera: Camera3D,
	world_explorer: Node,
	toggles: RefCounted,
	stamp: String,
	runtime_args: PackedStringArray = PackedStringArray()
) -> void:
	_streaming_manager = streaming_manager
	_cell_manager = cell_manager
	_camera = camera
	_world_explorer = world_explorer
	_toggles = toggles
	_stamp = stamp if not stamp.is_empty() else Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	_output_dir = "%s/ladder_%s" % [OUTPUT_DIR_BASE, _stamp]
	_max_rungs = _parse_max_rungs(runtime_args)
	_start_rung = _parse_start_rung(runtime_args)
	if not DirAccess.dir_exists_absolute(_output_dir):
		DirAccess.make_dir_recursive_absolute(_output_dir)
	if _toggles:
		_toggles.disable_all()
	# Benchmark hygiene (Phase 0, 2026-07-05): uncap FPS for the run so rung
	# deltas aren't compressed against a user frame cap; restored in _finish().
	# Both cap sources handled: Engine.max_fps AND vsync (user settings
	# default vsync ON — on a 144 Hz panel that pins every fast rung at 144).
	_saved_max_fps = Engine.max_fps
	if _saved_max_fps > 0:
		Engine.max_fps = 0
		Log.info("tools", "[LADDER] Engine.max_fps %d -> 0 for the run (restored at finish)" % _saved_max_fps)
	_saved_vsync_mode = DisplayServer.window_get_vsync_mode()
	if _saved_vsync_mode != DisplayServer.VSYNC_DISABLED:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Log.info("tools", "[LADDER] vsync mode %d -> disabled for the run (restored at finish)" % _saved_vsync_mode)
	_started_msec = Time.get_ticks_msec()
	var rung_count := _effective_rung_count()
	Log.info("tools", "[LADDER] configured — output dir: %s, rungs: %d" % [
		_output_dir, rung_count])


func _process(delta: float) -> void:
	# Watchdog — clamp total runtime so a hang during any rung doesn't stall
	# an autonomous session indefinitely.
	var total_elapsed_s := float(Time.get_ticks_msec() - _started_msec) / 1000.0
	if total_elapsed_s > WATCHDOG_S:
		Log.warn("tools", "[LADDER] watchdog fired at %.0fs — force finish" % total_elapsed_s)
		_finish()
		return

	match _state:
		"waiting_settle":
			_tick_waiting_settle(delta, total_elapsed_s)
		"apply_rung":
			_apply_current_rung()
		"toggle_settle":
			_tick_toggle_settle(delta)
		"flyby":
			_tick_flyby(delta)
		"done":
			pass


func _tick_waiting_settle(delta: float, total_elapsed_s: float) -> void:
	if _streaming_manager and _streaming_manager.is_in_startup_phase():
		_settle_elapsed = 0.0
		return
	var fps := Engine.get_frames_per_second()
	if fps >= SETTLE_FPS_TARGET:
		_settle_elapsed += delta
	else:
		_settle_elapsed = 0.0
	if _settle_elapsed >= SETTLE_WINDOW_S:
		Log.info("tools", "[LADDER] settle reached — fps=%d, elapsed=%.1fs" % [fps, total_elapsed_s])
		_enter_rung(_effective_start_rung())
		return
	if total_elapsed_s >= SETTLE_FALLBACK_S:
		Log.warn("tools", "[LADDER] settle fallback — forcing start at %.1fs (fps=%d)" % [total_elapsed_s, fps])
		_enter_rung(_effective_start_rung())


func _enter_rung(idx: int) -> void:
	if idx >= _effective_rung_count():
		_finish()
		return
	_rung_idx = idx
	_center_camera_on_seyda_neen()
	_state = "apply_rung"


## Apply the cumulative flag set for the current rung.
## Rung 0 = all disabled. Rung i (i >= 1) = first i flags in LADDER_ADD_ORDER enabled.
func _apply_current_rung() -> void:
	if not _toggles:
		Log.error("tools", "[LADDER] toggles missing — cannot run")
		_state = "done"
		_finish()
		return

	var enabled_set: Array[String] = _enabled_flags_for_rung(_rung_idx)

	# Preserve already-enabled cumulative tiers so the ladder does not measure
	# toggle thaw bursts as the next subsystem's cost.
	for flag_name: String in _toggles.get_flag_names():
		_toggles.set_flag(flag_name, enabled_set.has(flag_name))

	var label := _rung_label(_rung_idx)
	Log.info("tools", "[LADDER] rung %d/%d — label='%s', enabled=%s" % [
		_rung_idx + 1, _effective_rung_count(), label, str(enabled_set)])

	_state_elapsed = 0.0
	_state = "toggle_settle"


func _tick_toggle_settle(delta: float) -> void:
	_state_elapsed += delta
	if _state_elapsed >= TOGGLE_APPLY_DELAY_S:
		_state_elapsed = 0.0
		_start_current_flyby()


func _start_current_flyby() -> void:
	if _active_bench != null and is_instance_valid(_active_bench):
		return
	_current_publication_samples.clear()
	_last_publication_sample_sec_bucket = -1
	_state_elapsed = 0.0
	var bench := StreamingBenchmarkScript.new()
	bench.name = "BenchLadderFlyby_%s" % _rung_label(_rung_idx).trim_prefix("+").validate_filename()
	get_tree().root.add_child(bench)
	bench.benchmark_complete.connect(Callable(self, "_on_flyby_complete"), CONNECT_ONE_SHOT)
	_active_bench = bench
	_state = "flyby"
	bench.init_console_mode(_streaming_manager, _cell_manager, _camera, null)


func _tick_flyby(delta: float) -> void:
	_state_elapsed += delta
	_sample_publication_once_per_second(_state_elapsed)


func _on_flyby_complete(results: Dictionary) -> void:
	_finalize_current_rung(results)
	_active_bench = null
	var next_rung := _rung_idx + 1
	get_tree().create_timer(1.1).timeout.connect(func() -> void:
		_enter_rung(next_rung)
	)


func _finalize_current_rung(results: Dictionary) -> void:
	var label := _rung_label(_rung_idx)
	var enabled := _enabled_flags_for_rung(_rung_idx)
	var summary := _summary_from_flyby(results)
	_rungs.append({
		"rung": _rung_idx,
		"label": label,
		"enabled": enabled,
		"toggle_state": _toggle_state_snapshot(),
		"summary": summary,
	})
	Log.info("tools", "[LADDER] rung %d '%s' done — avg_fps=%.1f, p95=%.1fms, draws_avg=%.0f" % [
		_rung_idx, label,
		summary.get("avg_fps", 0.0),
		summary.get("p95_ms", 0.0),
		summary.get("avg_draw_calls", 0.0)])


func _summary_from_flyby(results: Dictionary) -> Dictionary:
	var summary := results.duplicate(true)
	summary["samples"] = int(results.get("total_frames", 0))
	summary["fps_avg"] = float(results.get("avg_fps", 0.0))
	summary["draws_avg"] = float(results.get("avg_draw_calls", 0.0))
	summary.merge(_summarize_publication_samples(_current_publication_samples), true)
	return summary


func _sample_publication_once_per_second(elapsed_s: float) -> void:
	var bucket := int(elapsed_s)
	if bucket == _last_publication_sample_sec_bucket:
		return
	_last_publication_sample_sec_bucket = bucket
	_current_publication_samples.append(_snapshot_publication_sample(elapsed_s))


func _snapshot_publication_sample(elapsed_s: float) -> Dictionary:
	var sample := {"elapsed_s": elapsed_s}
	if not _streaming_manager:
		return sample
	var stats: Dictionary = _streaming_manager.get_stats()
	var publication_lanes: Dictionary = stats.get("publication_lanes", {})
	for lane: String in PUBLICATION_LANES:
		var lane_stats: Dictionary = publication_lanes.get(lane, {})
		var prefix := "pub_%s" % lane
		sample["%s_claimed_us" % prefix] = lane_stats.get("claimed_usec", 0)
		sample["%s_spent_us" % prefix] = lane_stats.get("spent_usec", 0)
		sample["%s_overrun_us" % prefix] = lane_stats.get("overrun_usec", 0)
	return sample


func _summarize_publication_samples(samples: Array[Dictionary]) -> Dictionary:
	if samples.is_empty():
		return {}
	var max_values: Dictionary = {}
	var sum_values: Dictionary = {}
	for sample: Dictionary in samples:
		for key: String in PUBLICATION_SAMPLE_KEYS:
			var value := float(sample.get(key, 0.0))
			max_values[key] = maxf(float(max_values.get(key, 0.0)), value)
			sum_values[key] = float(sum_values.get(key, 0.0)) + value
	var summary: Dictionary = {"publication_samples": samples.size()}
	var count := float(samples.size())
	for key: String in PUBLICATION_SAMPLE_KEYS:
		summary["%s_max" % key] = max_values.get(key, 0.0)
		summary["%s_avg" % key] = float(sum_values.get(key, 0.0)) / count
	return summary


func _toggle_state_snapshot() -> Dictionary:
	if _toggles and _toggles.has_method("get_state"):
		var state: Dictionary = _toggles.call("get_state")
		return state.duplicate(true)
	return {}


func _enabled_flags_for_rung(idx: int) -> Array[String]:
	var out: Array[String] = []
	for i in range(mini(idx, LADDER_ADD_ORDER.size())):
		out.append(LADDER_ADD_ORDER[i])
	return out


func _effective_rung_count() -> int:
	var full_count := LADDER_ADD_ORDER.size() + 1
	if _max_rungs <= 0:
		return full_count
	return clampi(_max_rungs, 1, full_count)


func _parse_max_rungs(args: PackedStringArray) -> int:
	for i in range(args.size()):
		var arg: String = args[i]
		if arg == "--bench-ladder-max-rungs":
			if i + 1 < args.size():
				return int(args[i + 1])
			return 0
		if arg.begins_with("--bench-ladder-max-rungs="):
			return int(arg.substr("--bench-ladder-max-rungs=".length()))
	return 0


func _parse_start_rung(args: PackedStringArray) -> int:
	for i in range(args.size()):
		var arg: String = args[i]
		if arg == "--bench-ladder-start-rung":
			if i + 1 < args.size():
				return int(args[i + 1])
			return 0
		if arg.begins_with("--bench-ladder-start-rung="):
			return int(arg.substr("--bench-ladder-start-rung=".length()))
	return 0


func _effective_start_rung() -> int:
	return clampi(_start_rung, 0, maxi(0, _effective_rung_count() - 1))


func _rung_label(idx: int) -> String:
	if idx == 0:
		return "empty"
	if idx > LADDER_ADD_ORDER.size():
		return "all"
	return "+%s" % LADDER_ADD_ORDER[idx - 1]


func _center_camera_on_seyda_neen() -> void:
	if not _camera:
		return
	var spawn := DU.cell_to_world_center(Vector2i(-2, -9), 5.0)
	_camera.global_position = spawn
	if _camera.has_method("look_at"):
		_camera.look_at(spawn + Vector3(0, 0, -10))


func _finish() -> void:
	_state = "done"
	_write_ladder_json()
	if _toggles:
		_toggles.reset()
	if _saved_max_fps > 0:
		Engine.max_fps = _saved_max_fps
	if _saved_vsync_mode != DisplayServer.VSYNC_DISABLED:
		DisplayServer.window_set_vsync_mode(_saved_vsync_mode)
	Log.info("tools", "[LADDER] sequence complete — output dir: %s — quitting" % _output_dir)
	ladder_complete.emit(_build_final_summary())
	# Deferred quit so the log line flushes to disk.
	get_tree().create_timer(1.0).timeout.connect(func() -> void:
		get_tree().quit()
	)


func _write_ladder_json() -> void:
	var path := "%s/bench_ladder.json" % _output_dir
	var mode_meta := _get_benchmark_mode_metadata_snapshot()
	var summary := _build_final_summary()
	var payload := {
		"meta": {
			"scenario": "bench_ladder",
			"camera_cell": "(-2,-9)",
			"settle_window_s": SETTLE_WINDOW_S,
			"settle_fps_target": SETTLE_FPS_TARGET,
			"toggle_apply_delay_s": TOGGLE_APPLY_DELAY_S,
			"flyby_duration_s": StreamingBenchmarkScript.FLYBY_TOTAL_S,
			"ladder_add_order": LADDER_ADD_ORDER,
			"effective_rung_count": _effective_rung_count(),
			"start_rung": _effective_start_rung(),
			"benchmark_mode_metadata": mode_meta,
		},
		"stamp": _stamp,
		"benchmark_mode_metadata": mode_meta,
		"summary": summary,
		"rungs": _rungs,
	}
	payload = PerformanceReportContract.apply(payload, {
		"scenario": "bench_ladder",
		"mode": "ladder",
		"summary": summary,
		"duration_s": float(Time.get_ticks_msec() - _started_msec) / 1000.0,
		"benchmark_mode_metadata": mode_meta,
		"raw_outputs": {"summary_json": path},
	})
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		Log.error("tools", "[LADDER] failed to open %s" % path)
		return
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()
	Log.info("tools", "[LADDER] wrote %s (rungs=%d)" % [path, _rungs.size()])


func _get_benchmark_mode_metadata_snapshot() -> Dictionary:
	if _streaming_manager and _streaming_manager.has_method("get_benchmark_mode_metadata"):
		return _streaming_manager.call("get_benchmark_mode_metadata")
	if _streaming_manager:
		var stats: Dictionary = _streaming_manager.get_stats()
		return stats.get("benchmark_mode_metadata", {})
	return {}


func _build_final_summary() -> Dictionary:
	var rows: Array[Dictionary] = []
	for r: Dictionary in _rungs:
		var s: Dictionary = r.get("summary", {})
		var final_mid_stats: Dictionary = s.get("final_mid_stats", {})
		var final_mid_census: Dictionary = s.get("final_mid_bucket_census", {})
		var final_streaming_stats: Dictionary = s.get("final_streaming_stats", {})
		var final_hlod_stats: Dictionary = s.get("final_hlod_stats", {})
		rows.append({
			"rung": r.get("rung", -1),
			"label": r.get("label", "?"),
			"enabled": r.get("enabled", []),
			"toggle_state": r.get("toggle_state", {}),
			"fps_avg": s.get("fps_avg", 0.0),
			"p95_ms": s.get("p95_ms", 0.0),
			"p99_ms": s.get("p99_ms", 0.0),
			"frames_over_16_67": s.get("frames_over_16_67", 0),
			"draws_avg": s.get("draws_avg", 0.0),
			"peak_draw_calls": s.get("peak_draw_calls", 0),
			"peak_queue": s.get("peak_queue", 0),
			"peak_vram_mb": s.get("peak_vram_mb", 0.0),
			"mid_cell_buckets": final_mid_stats.get("cell_buckets", 0),
			"mid_bucket_draw_groups": final_mid_stats.get("bucket_draw_groups", 0),
			"mid_bucket_rs_instances": final_mid_stats.get("bucket_rs_instances", 0),
			"mid_singleton_draw_groups": final_mid_census.get("singleton_draw_groups", 0),
			"mid_multimesh_draw_groups": final_mid_census.get("multimesh_draw_groups", 0),
			"mid_direct_rs_instances": final_mid_census.get("direct_rs_instances", 0),
			"mid_top_bucket_contributors_by_draw_groups": final_mid_census.get("top_bucket_contributors_by_draw_groups", []),
			"mid_top_singleton_heavy_bucket_contributors": final_mid_census.get("top_singleton_heavy_bucket_contributors", []),
			"mid_direct_static_duplicate_candidate_count": final_mid_census.get("direct_static_duplicate_candidate_count", 0),
			"mid_direct_static_duplicate_candidate_rs_instances": final_mid_census.get("direct_static_duplicate_candidate_rs_instances", 0),
			"mid_top_direct_static_duplicate_candidates": final_mid_census.get("top_direct_static_duplicate_candidates", []),
			"mid_per_cell_hotspots": final_mid_census.get("per_cell_mid_hotspots", []),
			"hlod_visible_draw_calls": final_hlod_stats.get("visible_hlod_draw_calls", 0),
			"hlod_active_visual_chunks": final_hlod_stats.get("active_visual_chunks", 0),
			"hlod_chunks_tier_0": final_hlod_stats.get("chunks_tier_0", 0),
			"hlod_total_chunk_surfaces": final_hlod_stats.get("total_chunk_surfaces", 0),
			"hlod_completion_last_usec": final_hlod_stats.get("completion_last_usec", 0),
			"mid_object_paging_accepted_chunks": final_hlod_stats.get("mid_object_paging_accepted_chunks", 0),
			"mid_object_paging_rejected_chunks_cost": final_hlod_stats.get("mid_object_paging_rejected_chunks_cost", 0),
			"mid_object_paging_rejected_chunks_partial": final_hlod_stats.get("mid_object_paging_rejected_chunks_partial", 0),
			"mid_object_paging_rejected_chunks_missing_bucket": final_hlod_stats.get("mid_object_paging_rejected_chunks_missing_bucket", 0),
			"mid_object_paging_suppressed_draw_groups": final_hlod_stats.get("mid_object_paging_suppressed_draw_groups", 0),
			"mid_object_paging_proxy_surface_estimate": final_hlod_stats.get("mid_object_paging_proxy_surface_estimate", 0),
			"mid_object_paging_refs_no_bucket_rejected": final_hlod_stats.get("mid_object_paging_refs_no_bucket_rejected", 0),
			"desired_cell_count": final_streaming_stats.get("desired_cell_count", 0),
			"static_visual_only_cells": final_streaming_stats.get("static_visual_only_cells", 0),
			"gameplay_upgrade_requests": final_streaming_stats.get("gameplay_upgrade_requests", 0),
			"pub_near_gameplay_spent_us_avg": s.get("pub_near_gameplay_spent_us_avg", 0.0),
			"pub_near_gameplay_overrun_us_max": s.get("pub_near_gameplay_overrun_us_max", 0.0),
			"pub_static_visuals_spent_us_avg": s.get("pub_static_visuals_spent_us_avg", 0.0),
			"pub_static_visuals_overrun_us_max": s.get("pub_static_visuals_overrun_us_max", 0.0),
			"pub_hlod_spent_us_avg": s.get("pub_hlod_spent_us_avg", 0.0),
			"pub_far_impostors_spent_us_avg": s.get("pub_far_impostors_spent_us_avg", 0.0),
			"pub_distant_lights_spent_us_avg": s.get("pub_distant_lights_spent_us_avg", 0.0),
		})
	return {
		"output_dir": _output_dir,
		"rung_count": _rungs.size(),
		"benchmark_mode_metadata": _get_benchmark_mode_metadata_snapshot(),
		"rows": rows,
	}
