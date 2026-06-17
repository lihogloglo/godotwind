## AutoBenchRunner — autonomous performance-audit orchestrator.
##
## Wires in when `--bench-auto` is present on the command line. Waits for the
## streaming pipeline to actually settle (FPS ≥ 50 for 3 consecutive seconds,
## OR absolute 4-minute fallback), then runs the four scenarios required by
## the autonomous-perf-audit handoff (docs/audit/AUTONOMOUS_PERF_AUDIT_HANDOFF_
## 2026_04_17.md §1, missions C-F):
##
##   C. bench_tiers   — 30s static sample at Seyda Neen spawn. Captures per-sec
##                      rendered_objects / draw_calls / primitives / FPS plus
##                      HLOD chunk / impostor counts. Writes `bench_tiers.json`.
##   D. bench_flyby   — delegates to StreamingBenchmark's existing 85s scripted
##                      path via init_console_mode. CSV + JSON land in
##                      user://benchmark_results/ as usual; we pick them up
##                      post-hoc from the stamped output directory.
##   E. bench_teleport — teleports camera (-2,-9) → (-10,-10) in one frame
##                      (~940m, well over TELEPORT_DETECT_THRESHOLD=500m),
##                      samples 20s of post-teleport metrics, writes
##                      `bench_teleport.json`. The log-line assertion
##                      ("Teleport detected — re-entering startup burst mode")
##                      is validated offline by the outer harness.
##   F. bench_hlod_off — calls world_explorer._cmd_hlod_disable, waits 5s,
##                      samples 10s, restores hlod, writes `bench_hlod_off.json`.
##
## On completion the scene quits via `get_tree().quit()`. A 15-minute watchdog
## guards against a hang stalling the autonomous session indefinitely.
class_name AutoBenchRunner
extends Node

const DU := preload("res://src/core/world/distance_utils.gd")
const NativeStreamingManagerScript := preload("res://src/core/world/native_streaming_manager.gd")
const CellManagerScript := preload("res://src/core/world/cell_manager.gd")
const StreamingBenchmarkScript := preload("res://src/tools/streaming_benchmark.gd")

## Seconds of FPS >= SETTLE_FPS_TARGET required to call the pipeline settled.
## Phase 0 ablation (2026-04-21): relaxed threshold to TRUE steady state.
## User reports Balmora eye-level steady = 180-200 FPS. Old 50/3s fired while
## the instantiation queue was still draining (queue=866 with inst:14ms/frame
## chronic overrun = 71 FPS cap), giving misleading "steady" numbers. New
## threshold requires fps>=150 sustained 10s → guarantees queue drained +
## true GPU-bound steady state.
const SETTLE_WINDOW_SEC: float = 10.0
const SETTLE_FPS_TARGET: float = 150.0

## Hard cap — if FPS never recovers, start the bench anyway at this point so
## the report captures a "never settled" run instead of spinning forever.
const SETTLE_FALLBACK_SEC: float = 240.0

## Watchdog — if the full run exceeds this wall-clock, force-quit.
const RUN_WATCHDOG_SEC: float = 900.0

## Post-teleport / hlod-off sample windows (seconds).
const TIERS_SAMPLE_SEC: float = 30.0
const TELEPORT_SAMPLE_SEC: float = 20.0
const HLOD_OFF_PRE_DELAY_SEC: float = 5.0
const HLOD_OFF_SAMPLE_SEC: float = 10.0

## Output directory. Created on demand; all 4 JSON files land here.
const OUTPUT_DIR_BASE: String = "user://benchmark_results"

var _streaming_manager: NativeStreamingManagerScript = null
var _cell_manager: CellManagerScript = null
var _camera: Camera3D = null
var _world_explorer: Node = null
var _stamp: String = ""
var _output_dir: String = ""
var _started_msec: int = 0
var _settle_elapsed: float = 0.0

var _state: String = "waiting_settle"
var _state_elapsed: float = 0.0

## Per-scenario sampled points: Array[Dictionary]
var _tiers_samples: Array[Dictionary] = []
var _teleport_samples: Array[Dictionary] = []
var _hlod_off_samples: Array[Dictionary] = []
var _teleport_t0_sec: int = 0
var _teleport_first_55_after_sec: float = -1.0

var _last_sample_sec_bucket: int = -1
var _flyby_bench: StreamingBenchmarkScript = null


func configure(
	streaming_manager: NativeStreamingManagerScript,
	cell_manager: CellManagerScript,
	camera: Camera3D,
	world_explorer: Node,
	stamp: String
) -> void:
	_streaming_manager = streaming_manager
	_cell_manager = cell_manager
	_camera = camera
	_world_explorer = world_explorer
	_stamp = stamp if not stamp.is_empty() else Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	_output_dir = "%s/autobench_%s" % [OUTPUT_DIR_BASE, _stamp]
	if not DirAccess.dir_exists_absolute(_output_dir):
		DirAccess.make_dir_recursive_absolute(_output_dir)
	_started_msec = Time.get_ticks_msec()
	Log.info("tools", "[AUTOBENCH] configured — output dir: %s" % _output_dir)


func _process(delta: float) -> void:
	# Watchdog — never hang the harness past 15 minutes total.
	var total_elapsed_s := float(Time.get_ticks_msec() - _started_msec) / 1000.0
	if total_elapsed_s > RUN_WATCHDOG_SEC:
		Log.warn("tools", "[AUTOBENCH] watchdog fired at %.0fs — force quit" % total_elapsed_s)
		_finish()
		return

	match _state:
		"waiting_settle":
			_tick_waiting_settle(delta, total_elapsed_s)
		"tiers":
			_tick_tiers(delta)
		"flyby_pending":
			_start_flyby()
		"flyby_running":
			pass  # StreamingBenchmark owns its own timing; we wait on its signal.
		"teleport_pending":
			_start_teleport()
		"teleport":
			_tick_teleport(delta)
		"hlod_off_pending":
			_start_hlod_off()
		"hlod_off_predelay":
			_tick_hlod_off_predelay(delta)
		"hlod_off_sample":
			_tick_hlod_off_sample(delta)
		"done":
			pass


# -----------------------------------------------------------------------------
# Settle detection
# -----------------------------------------------------------------------------

func _tick_waiting_settle(delta: float, total_elapsed_s: float) -> void:
	if _streaming_manager and _streaming_manager.is_in_startup_phase():
		# Still in startup — do not count the FPS window yet.
		_settle_elapsed = 0.0
		return
	var fps := Engine.get_frames_per_second()
	if fps >= SETTLE_FPS_TARGET:
		_settle_elapsed += delta
	else:
		_settle_elapsed = 0.0
	if _settle_elapsed >= SETTLE_WINDOW_SEC:
		Log.info("tools", "[AUTOBENCH] settle reached — fps=%d, total_elapsed=%.1fs" % [fps, total_elapsed_s])
		_enter_tiers()
		return
	if total_elapsed_s >= SETTLE_FALLBACK_SEC:
		Log.warn("tools", "[AUTOBENCH] settle fallback — never reached %ds of FPS>=%d, forcing scenarios at %.1fs (current fps=%d)" % [
			int(SETTLE_WINDOW_SEC), int(SETTLE_FPS_TARGET), total_elapsed_s, fps
		])
		_enter_tiers()


# -----------------------------------------------------------------------------
# Scenario C — bench_tiers
# -----------------------------------------------------------------------------

func _enter_tiers() -> void:
	# Phase 0 ablation (2026-04-21): no mid-session teleport — launch with
	# `--start-cell=-3,-2` to boot at Balmora. Teleport-after-settle triggered
	# tracker §12.2 crash during the 6-cell unload storm. Tiers scenario now
	# samples at wherever the camera already is (Balmora via boot flag).
	_state = "tiers"
	_state_elapsed = 0.0
	_last_sample_sec_bucket = -1
	_tiers_samples.clear()
	Log.info("tools", "[AUTOBENCH] scenario C (bench_tiers) — sampling %.0fs static at current cell" % TIERS_SAMPLE_SEC)


func _tick_tiers(delta: float) -> void:
	_state_elapsed += delta
	_sample_once_per_second(_state_elapsed, _tiers_samples)
	if _state_elapsed >= TIERS_SAMPLE_SEC:
		_write_scenario_json("bench_tiers.json", _tiers_samples, {
			"scenario": "bench_tiers",
			"camera_cell": "(-2,-9)",
			"duration_s": TIERS_SAMPLE_SEC,
		})
		_state = "flyby_pending"


# -----------------------------------------------------------------------------
# Scenario D — bench_flyby (delegate to existing scripted path)
# -----------------------------------------------------------------------------

func _start_flyby() -> void:
	if not _streaming_manager or not _cell_manager or not _camera:
		Log.error("tools", "[AUTOBENCH] flyby skipped — missing streaming_manager / cell_manager / camera")
		_state = "teleport_pending"
		return
	Log.info("tools", "[AUTOBENCH] scenario D (bench_flyby) — delegating to StreamingBenchmark.init_console_mode, ~85s")
	_flyby_bench = StreamingBenchmarkScript.new()
	_flyby_bench.name = "AutoBenchFlyby"
	get_tree().root.add_child(_flyby_bench)
	_flyby_bench.benchmark_complete.connect(_on_flyby_complete)
	_flyby_bench.init_console_mode(_streaming_manager, _cell_manager, _camera)
	_state = "flyby_running"


func _on_flyby_complete(_results: Dictionary) -> void:
	Log.info("tools", "[AUTOBENCH] flyby complete — CSV/JSON written under user://benchmark_results/")
	_state = "teleport_pending"


# -----------------------------------------------------------------------------
# Scenario E — bench_teleport (>500m jump, sample post-teleport recovery)
# -----------------------------------------------------------------------------

func _start_teleport() -> void:
	# Phase 0 (2026-04-21): teleport dest changed from (-10,-10) deep ocean
	# to (0,-5) Pelagiad area — dense forest + town, tests cell-change under
	# load. Balmora → Pelagiad ≈ 3 cells diagonal = well over the 500m
	# TELEPORT_DETECT_THRESHOLD.
	# (-10,-10) is ~8 cells west and ~1 cell south → ~940m XZ, safely > 500m
	# TELEPORT_DETECT_THRESHOLD. Grazes the warmup-burst re-entry logic in
	# native_streaming_manager._process + object_paging teleport handling.
	var target := DU.cell_to_world_center(Vector2i(0, -5), 5.0)
	if _camera:
		_camera.global_position = target
		if _camera.has_method("look_at"):
			_camera.look_at(target + Vector3(0, 0, -10))
	_teleport_t0_sec = int((Time.get_ticks_msec() - _started_msec) / 1000)
	_teleport_samples.clear()
	_teleport_first_55_after_sec = -1.0
	_state = "teleport"
	_state_elapsed = 0.0
	_last_sample_sec_bucket = -1
	Log.info("tools", "[AUTOBENCH] scenario E (bench_teleport) — teleported to (-10,-10), sampling %.0fs" % TELEPORT_SAMPLE_SEC)


func _tick_teleport(delta: float) -> void:
	_state_elapsed += delta
	_sample_once_per_second(_state_elapsed, _teleport_samples)
	if _teleport_first_55_after_sec < 0.0 and Engine.get_frames_per_second() >= SETTLE_FPS_TARGET:
		_teleport_first_55_after_sec = _state_elapsed
	if _state_elapsed >= TELEPORT_SAMPLE_SEC:
		_write_scenario_json("bench_teleport.json", _teleport_samples, {
			"scenario": "bench_teleport",
			"jump_cells": "(-2,-9) -> (-10,-10)",
			"duration_s": TELEPORT_SAMPLE_SEC,
			"first_fps_ge_50_after_s": _teleport_first_55_after_sec,
		})
		_state = "hlod_off_pending"


# -----------------------------------------------------------------------------
# Scenario F — bench_hlod_off (hlod_disable, settle, sample, restore)
# -----------------------------------------------------------------------------

func _start_hlod_off() -> void:
	# Phase 0: after teleport scenario left us at Pelagiad (0,-5), return to
	# Balmora (-3,-2) for F. Using a low-cost cell-jump (teleport to recently-
	# loaded origin cells) avoids the crash-prone unload storm of an ocean
	# teleport — Balmora was already resident from the boot settle phase.
	var spawn := DU.cell_to_world_center(Vector2i(-3, -2), 5.0)
	if _camera:
		_camera.global_position = spawn
		if _camera.has_method("look_at"):
			_camera.look_at(spawn + Vector3(0, 0, -10))
	if _world_explorer and _world_explorer.has_method("_cmd_hlod_disable"):
		var resp = _world_explorer._cmd_hlod_disable({})
		Log.info("tools", "[AUTOBENCH] hlod_disable => %s" % str(resp))
	else:
		Log.warn("tools", "[AUTOBENCH] world_explorer missing _cmd_hlod_disable — scenario F degraded")
	_state = "hlod_off_predelay"
	_state_elapsed = 0.0
	_hlod_off_samples.clear()


func _tick_hlod_off_predelay(delta: float) -> void:
	_state_elapsed += delta
	if _state_elapsed >= HLOD_OFF_PRE_DELAY_SEC:
		_state = "hlod_off_sample"
		_state_elapsed = 0.0
		_last_sample_sec_bucket = -1
		Log.info("tools", "[AUTOBENCH] hlod_off pre-delay done, sampling %.0fs" % HLOD_OFF_SAMPLE_SEC)


func _tick_hlod_off_sample(delta: float) -> void:
	_state_elapsed += delta
	_sample_once_per_second(_state_elapsed, _hlod_off_samples)
	if _state_elapsed >= HLOD_OFF_SAMPLE_SEC:
		# Restore HLOD before we leave so a human inspecting the scene isn't
		# left in degraded debug mode if they re-attach later.
		if _world_explorer and _world_explorer.has_method("_cmd_hlod_enable"):
			_world_explorer._cmd_hlod_enable({})
		_write_scenario_json("bench_hlod_off.json", _hlod_off_samples, {
			"scenario": "bench_hlod_off",
			"pre_delay_s": HLOD_OFF_PRE_DELAY_SEC,
			"duration_s": HLOD_OFF_SAMPLE_SEC,
		})
		_finish()


# -----------------------------------------------------------------------------
# Sampling + JSON output
# -----------------------------------------------------------------------------

## Sample exactly once per integer second of elapsed time. Prevents duplicate
## samples within the same frame and guarantees 1 Hz sampling regardless of
## frame rate.
func _sample_once_per_second(elapsed_s: float, out: Array[Dictionary]) -> void:
	var bucket := int(elapsed_s)
	if bucket == _last_sample_sec_bucket:
		return
	_last_sample_sec_bucket = bucket
	out.append(_snapshot_sample(elapsed_s))


func _snapshot_sample(elapsed_s: float) -> Dictionary:
	var sample := {
		"elapsed_s": elapsed_s,
		"fps": Engine.get_frames_per_second(),
		"draws": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"objs": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"prims": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
	}
	if _streaming_manager:
		var stats: Dictionary = _streaming_manager.get_stats()
		sample["startup_phase"] = stats.get("startup_phase", false)
		sample["loaded_cells"] = stats.get("loaded_cells", 0)
		sample["loading_cells"] = stats.get("loading_cells", 0)
		sample["mid_instances"] = stats.get("mid_instances", 0)
		sample["mid_visible"] = stats.get("mid_visible", 0)
		sample["mid_mesh_types"] = stats.get("mid_mesh_types", 0)
		sample["hlod_mid_bucket_overrides"] = stats.get("hlod_mid_bucket_overrides", 0)
		sample["hlod_mid_bucket_override_refs"] = stats.get("hlod_mid_bucket_override_refs", 0)
		sample["hlod_cells"] = stats.get("hlod_cells", 0)
		sample["total_impostors"] = stats.get("total_impostors", 0)
		sample["far_pending_cells"] = stats.get("pending_loads", 0)
		sample["far_texture_layers"] = stats.get("texture_array_layers", 0)
		sample["far_texture_upload_us"] = stats.get("far_texture_upload_us", 0)
		sample["far_normal_upload_us"] = stats.get("far_normal_upload_us", 0)
		sample["far_multimesh_pack_us"] = stats.get("far_multimesh_pack_us", 0)
		sample["far_multimesh_upload_us"] = stats.get("far_multimesh_upload_us", 0)
		sample["far_cell_scan_us"] = stats.get("far_cell_scan_us", 0)
		sample["far_job_poll_us"] = stats.get("far_job_poll_us", 0)
		sample["far_job_results_handled"] = stats.get("far_job_results_handled", 0)
		sample["far_page_count"] = stats.get("far_page_count", 0)
		sample["far_dirty_page_count"] = stats.get("far_dirty_page_count", 0)
		sample["far_pages_rebuilt"] = stats.get("far_pages_rebuilt", 0)
		sample["far_uploaded_instances"] = stats.get("far_uploaded_instances", 0)
		# HLOD per-tier breakdown
		if _streaming_manager.has_method("get_hlod_stats"):
			var hls: Dictionary = _streaming_manager.get_hlod_stats()
			sample["chunks_tier_0"] = hls.get("chunks_tier_0", 0)
			sample["chunks_tier_1"] = hls.get("chunks_tier_1", 0)
			sample["chunks_tier_2"] = hls.get("chunks_tier_2", 0)
			sample["hlod_pending"] = hls.get("pending_merges", 0)
			sample["hlod_chunk_surfaces"] = hls.get("total_chunk_surfaces", 0)
			sample["hlod_chunk_materials"] = hls.get("total_chunk_materials", 0)
			sample["hlod_chunk_vertices"] = hls.get("total_chunk_vertices", 0)
			sample["hlod_chunk_indices"] = hls.get("total_chunk_indices", 0)
			sample["hlod_max_chunk_surfaces"] = hls.get("max_chunk_surfaces", 0)
			sample["hlod_max_chunk_materials"] = hls.get("max_chunk_materials", 0)
			sample["hlod_max_chunk_vertices"] = hls.get("max_chunk_vertices", 0)
			sample["hlod_max_chunk_indices"] = hls.get("max_chunk_indices", 0)
			sample["hlod_stale_completions"] = hls.get("stale_completions_discarded", 0)
			sample["hlod_merge_queue_us"] = hls.get("merge_queue_last_usec", 0)
			sample["hlod_completion_us"] = hls.get("completion_last_usec", 0)
	return sample


func _write_scenario_json(filename: String, samples: Array[Dictionary], meta: Dictionary) -> void:
	var path := "%s/%s" % [_output_dir, filename]
	var summary: Dictionary = _summarize(samples)
	var mode_meta := _get_benchmark_mode_metadata_snapshot()
	meta["benchmark_mode_metadata"] = mode_meta
	var out := {
		"meta": meta,
		"stamp": _stamp,
		"benchmark_mode_metadata": mode_meta,
		"summary": summary,
		"samples": samples,
	}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		Log.error("tools", "[AUTOBENCH] failed to open %s" % path)
		return
	file.store_string(JSON.stringify(out, "\t"))
	file.close()
	Log.info("tools", "[AUTOBENCH] wrote %s (samples=%d, summary=%s)" % [
		path, samples.size(), JSON.stringify(summary)])


func _get_benchmark_mode_metadata_snapshot() -> Dictionary:
	if _streaming_manager and _streaming_manager.has_method("get_benchmark_mode_metadata"):
		return _streaming_manager.call("get_benchmark_mode_metadata")
	if _streaming_manager:
		var stats: Dictionary = _streaming_manager.get_stats()
		return stats.get("benchmark_mode_metadata", {})
	return {}


func _summarize(samples: Array[Dictionary]) -> Dictionary:
	if samples.is_empty():
		return {"samples": 0}
	var fps_min := 1e9
	var fps_max := 0.0
	var fps_sum := 0.0
	var draws_sum := 0.0
	var objs_sum := 0.0
	var imp_max := 0
	var far_texture_upload_max := 0
	var far_normal_upload_max := 0
	var far_multimesh_pack_max := 0
	var far_multimesh_upload_max := 0
	var far_cell_scan_max := 0
	var far_job_poll_max := 0
	var far_page_count_max := 0
	var far_dirty_page_count_max := 0
	var far_pages_rebuilt_max := 0
	var far_uploaded_instances_max := 0
	var hlod_cells_max := 0
	var t1_max := 0
	var t2_max := 0
	var hlod_surfaces_max := 0
	var hlod_materials_max := 0
	var hlod_vertices_max := 0
	var hlod_indices_max := 0
	var hlod_max_chunk_surfaces := 0
	var hlod_max_chunk_materials := 0
	var hlod_max_chunk_vertices := 0
	var hlod_max_chunk_indices := 0
	var hlod_mid_bucket_overrides_max := 0
	var hlod_mid_bucket_override_refs_max := 0
	var hlod_stale_max := 0
	var hlod_merge_queue_max := 0
	var hlod_completion_max := 0
	for s: Dictionary in samples:
		var f := float(s.get("fps", 0.0))
		fps_min = minf(fps_min, f)
		fps_max = maxf(fps_max, f)
		fps_sum += f
		draws_sum += float(s.get("draws", 0))
		objs_sum += float(s.get("objs", 0))
		imp_max = maxi(imp_max, int(s.get("total_impostors", 0)))
		far_texture_upload_max = maxi(far_texture_upload_max, int(s.get("far_texture_upload_us", 0)))
		far_normal_upload_max = maxi(far_normal_upload_max, int(s.get("far_normal_upload_us", 0)))
		far_multimesh_pack_max = maxi(far_multimesh_pack_max, int(s.get("far_multimesh_pack_us", 0)))
		far_multimesh_upload_max = maxi(far_multimesh_upload_max, int(s.get("far_multimesh_upload_us", 0)))
		far_cell_scan_max = maxi(far_cell_scan_max, int(s.get("far_cell_scan_us", 0)))
		far_job_poll_max = maxi(far_job_poll_max, int(s.get("far_job_poll_us", 0)))
		far_page_count_max = maxi(far_page_count_max, int(s.get("far_page_count", 0)))
		far_dirty_page_count_max = maxi(far_dirty_page_count_max, int(s.get("far_dirty_page_count", 0)))
		far_pages_rebuilt_max = maxi(far_pages_rebuilt_max, int(s.get("far_pages_rebuilt", 0)))
		far_uploaded_instances_max = maxi(far_uploaded_instances_max, int(s.get("far_uploaded_instances", 0)))
		hlod_cells_max = maxi(hlod_cells_max, int(s.get("hlod_cells", 0)))
		t1_max = maxi(t1_max, int(s.get("chunks_tier_1", 0)))
		t2_max = maxi(t2_max, int(s.get("chunks_tier_2", 0)))
		hlod_surfaces_max = maxi(hlod_surfaces_max, int(s.get("hlod_chunk_surfaces", 0)))
		hlod_materials_max = maxi(hlod_materials_max, int(s.get("hlod_chunk_materials", 0)))
		hlod_vertices_max = maxi(hlod_vertices_max, int(s.get("hlod_chunk_vertices", 0)))
		hlod_indices_max = maxi(hlod_indices_max, int(s.get("hlod_chunk_indices", 0)))
		hlod_max_chunk_surfaces = maxi(hlod_max_chunk_surfaces, int(s.get("hlod_max_chunk_surfaces", 0)))
		hlod_max_chunk_materials = maxi(hlod_max_chunk_materials, int(s.get("hlod_max_chunk_materials", 0)))
		hlod_max_chunk_vertices = maxi(hlod_max_chunk_vertices, int(s.get("hlod_max_chunk_vertices", 0)))
		hlod_max_chunk_indices = maxi(hlod_max_chunk_indices, int(s.get("hlod_max_chunk_indices", 0)))
		hlod_mid_bucket_overrides_max = maxi(hlod_mid_bucket_overrides_max, int(s.get("hlod_mid_bucket_overrides", 0)))
		hlod_mid_bucket_override_refs_max = maxi(hlod_mid_bucket_override_refs_max, int(s.get("hlod_mid_bucket_override_refs", 0)))
		hlod_stale_max = maxi(hlod_stale_max, int(s.get("hlod_stale_completions", 0)))
		hlod_merge_queue_max = maxi(hlod_merge_queue_max, int(s.get("hlod_merge_queue_us", 0)))
		hlod_completion_max = maxi(hlod_completion_max, int(s.get("hlod_completion_us", 0)))
	var n := float(samples.size())
	return {
		"samples": samples.size(),
		"fps_min": fps_min,
		"fps_max": fps_max,
		"fps_avg": fps_sum / n,
		"draws_avg": draws_sum / n,
		"objs_avg": objs_sum / n,
		"impostors_max": imp_max,
		"far_texture_upload_max_us": far_texture_upload_max,
		"far_normal_upload_max_us": far_normal_upload_max,
		"far_multimesh_pack_max_us": far_multimesh_pack_max,
		"far_multimesh_upload_max_us": far_multimesh_upload_max,
		"far_cell_scan_max_us": far_cell_scan_max,
		"far_job_poll_max_us": far_job_poll_max,
		"far_page_count_max": far_page_count_max,
		"far_dirty_page_count_max": far_dirty_page_count_max,
		"far_pages_rebuilt_max": far_pages_rebuilt_max,
		"far_uploaded_instances_max": far_uploaded_instances_max,
		"hlod_cells_max": hlod_cells_max,
		"chunks_tier_1_max": t1_max,
		"chunks_tier_2_max": t2_max,
		"hlod_chunk_surfaces_max": hlod_surfaces_max,
		"hlod_chunk_materials_max": hlod_materials_max,
		"hlod_chunk_vertices_max": hlod_vertices_max,
		"hlod_chunk_indices_max": hlod_indices_max,
		"hlod_max_chunk_surfaces": hlod_max_chunk_surfaces,
		"hlod_max_chunk_materials": hlod_max_chunk_materials,
		"hlod_max_chunk_vertices": hlod_max_chunk_vertices,
		"hlod_max_chunk_indices": hlod_max_chunk_indices,
		"hlod_mid_bucket_overrides_max": hlod_mid_bucket_overrides_max,
		"hlod_mid_bucket_override_refs_max": hlod_mid_bucket_override_refs_max,
		"hlod_stale_completions_max": hlod_stale_max,
		"hlod_merge_queue_max_us": hlod_merge_queue_max,
		"hlod_completion_max_us": hlod_completion_max,
	}


# -----------------------------------------------------------------------------
# Finish
# -----------------------------------------------------------------------------

func _finish() -> void:
	_state = "done"
	Log.info("tools", "[AUTOBENCH] sequence complete — output dir: %s — quitting" % _output_dir)
	# Deferred quit so the log line makes it to disk before shutdown flushes.
	get_tree().create_timer(1.0).timeout.connect(func() -> void:
		_quit_cleanly()
	)


func _quit_cleanly() -> void:
	Log.info("shutdown", "BENCH_QUIT - autobench complete, beginning fast cleanup")
	Engine.set_meta("_quitting", true)
	if _streaming_manager != null:
		_streaming_manager.set_process(false)
		if _streaming_manager.has_method("fast_cleanup"):
			_streaming_manager.call("fast_cleanup")
	get_tree().quit()
