## BenchLadderRunner — progressive subsystem-isolation benchmark.
##
## Cumulative-additive A/B over the 11 `SubsystemToggles` flags: each rung
## enables one more subsystem on top of the previous one, samples a static
## window at Seyda Neen, records per-sec metrics, and writes a single
## `bench_ladder.json` with all rungs. Delta between adjacent rung averages
## is that subsystem's marginal render cost in realistic conditions.
##
## Sibling to `AutoBenchRunner` (which runs scenarios C/D/E/F from the
## autonomous perf-audit handoff). Triggered by `--bench-ladder [stamp]` on
## the command line. No scripted camera flight — the camera holds at
## the Seyda Neen spawn for all rungs to keep the sample deterministic.
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
const NativeStreamingManagerScript := preload("res://src/core/world/native_streaming_manager.gd")
const CellManagerScript := preload("res://src/core/world/cell_manager.gd")
const PerformanceReportContract := preload("res://src/tools/performance_report_contract.gd")

const OUTPUT_DIR_BASE: String = "user://benchmark_results"

## Wait for either FPS >= target for SETTLE_WINDOW_S or hit the fallback cap.
## Target is intentionally low (20 FPS) because cold-start can be very slow on
## this branch and the ladder tolerates an unsettled start — the per-rung sample
## windows themselves capture the settle-to-steady-state trace.
const SETTLE_WINDOW_S: float = 3.0
const SETTLE_FPS_TARGET: float = 20.0
const SETTLE_FALLBACK_S: float = 240.0

## Watchdog — clamp total runtime.
## 12 rungs × (3 s settle + 15 s sample) = 216 s, plus boot settle (~30-180 s),
## plus finalization overhead. 20-minute cap is generous but not indefinite.
const WATCHDOG_S: float = 1200.0

## After applying a rung's toggles, wait this long before sampling so RS
## instance show/hide churn quiesces (14 k slots flipping visibility is not
## free even though it's cheaper than recreate).
const TOGGLE_APPLY_DELAY_S: float = 3.0

## Per-rung static sample window.
const SAMPLE_DURATION_S: float = 15.0

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

## State: waiting_settle -> apply_rung -> toggle_settle -> sample -> (next rung) -> done
var _state: String = "waiting_settle"
var _state_elapsed: float = 0.0

## Rung index: 0..LADDER_ADD_ORDER.size() inclusive. 0 = empty baseline,
## 1 = +LADDER_ADD_ORDER[0] cumulative, ..., N = all flags.
var _rung_idx: int = 0

## Per-rung sample buffers. _rungs[i] = {label, enabled, samples[], summary}.
var _rungs: Array[Dictionary] = []
var _current_samples: Array[Dictionary] = []
var _last_sample_sec_bucket: int = -1


func configure(
	streaming_manager: NativeStreamingManagerScript,
	cell_manager: CellManagerScript,
	camera: Camera3D,
	world_explorer: Node,
	toggles: RefCounted,
	stamp: String
) -> void:
	_streaming_manager = streaming_manager
	_cell_manager = cell_manager
	_camera = camera
	_world_explorer = world_explorer
	_toggles = toggles
	_stamp = stamp if not stamp.is_empty() else Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	_output_dir = "%s/ladder_%s" % [OUTPUT_DIR_BASE, _stamp]
	if not DirAccess.dir_exists_absolute(_output_dir):
		DirAccess.make_dir_recursive_absolute(_output_dir)
	_started_msec = Time.get_ticks_msec()
	Log.info("tools", "[LADDER] configured — output dir: %s, rungs: %d" % [
		_output_dir, LADDER_ADD_ORDER.size() + 1])


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
		"sample":
			_tick_sample(delta)
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
		_enter_rung(0)
		return
	if total_elapsed_s >= SETTLE_FALLBACK_S:
		Log.warn("tools", "[LADDER] settle fallback — forcing start at %.1fs (fps=%d)" % [total_elapsed_s, fps])
		_enter_rung(0)


func _enter_rung(idx: int) -> void:
	if idx > LADDER_ADD_ORDER.size():
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

	# Deterministic: disable everything, then enable only the rung's set.
	# This protects against the previous rung having set a flag we don't want
	# in this rung (defensive — additive order means this should be a no-op
	# on the disable pass, but we keep it to guard against a ladder-order
	# reshuffle in the future).
	_toggles.disable_all()
	for flag_name: String in enabled_set:
		_toggles.set_flag(flag_name, true)

	var label := _rung_label(_rung_idx)
	Log.info("tools", "[LADDER] rung %d/%d — label='%s', enabled=%s" % [
		_rung_idx + 1, LADDER_ADD_ORDER.size() + 1, label, str(enabled_set)])

	_state_elapsed = 0.0
	_current_samples.clear()
	_last_sample_sec_bucket = -1
	_state = "toggle_settle"


func _tick_toggle_settle(delta: float) -> void:
	_state_elapsed += delta
	if _state_elapsed >= TOGGLE_APPLY_DELAY_S:
		_state_elapsed = 0.0
		_last_sample_sec_bucket = -1
		_state = "sample"


func _tick_sample(delta: float) -> void:
	_state_elapsed += delta
	_sample_once_per_second(_state_elapsed, _current_samples)
	if _state_elapsed >= SAMPLE_DURATION_S:
		_finalize_current_rung()
		_enter_rung(_rung_idx + 1)


func _finalize_current_rung() -> void:
	var label := _rung_label(_rung_idx)
	var enabled := _enabled_flags_for_rung(_rung_idx)
	var summary := _summarize(_current_samples)
	_rungs.append({
		"rung": _rung_idx,
		"label": label,
		"enabled": enabled,
		"summary": summary,
		"samples": _current_samples.duplicate(true),
	})
	Log.info("tools", "[LADDER] rung %d '%s' done — fps_avg=%.1f, draws_avg=%.0f, objs_avg=%.0f" % [
		_rung_idx, label,
		summary.get("fps_avg", 0.0),
		summary.get("draws_avg", 0.0),
		summary.get("objs_avg", 0.0)])


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
		"vram_mb": float(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)) / (1024.0 * 1024.0),
	}
	if _streaming_manager:
		var stats: Dictionary = _streaming_manager.get_stats()
		sample["loaded_cells"] = stats.get("loaded_cells", 0)
		sample["loading_cells"] = stats.get("loading_cells", 0)
		sample["startup_phase"] = stats.get("startup_phase", false)
		sample["mid_instances"] = stats.get("mid_instances", 0)
		sample["mid_visible"] = stats.get("mid_visible", 0)
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
		sample["far_page_count"] = stats.get("far_page_count", 0)
		sample["far_dirty_page_count"] = stats.get("far_dirty_page_count", 0)
		sample["far_pages_rebuilt"] = stats.get("far_pages_rebuilt", 0)
		sample["far_uploaded_instances"] = stats.get("far_uploaded_instances", 0)
		sample["distant_light_count"] = stats.get("distant_light_count", 0)
		sample["distant_light_page_count"] = stats.get("distant_light_page_count", 0)
		sample["distant_light_scan_us"] = stats.get("distant_light_scan_us", 0)
		sample["distant_light_rebuild_us"] = stats.get("distant_light_rebuild_us", 0)
		if _streaming_manager.has_method("get_hlod_stats"):
			var hls: Dictionary = _streaming_manager.get_hlod_stats()
			sample["chunks_tier_0"] = hls.get("chunks_tier_0", 0)
			sample["chunks_tier_1"] = hls.get("chunks_tier_1", 0)
			sample["chunks_tier_2"] = hls.get("chunks_tier_2", 0)
			sample["hlod_chunk_surfaces"] = hls.get("total_chunk_surfaces", 0)
			sample["hlod_chunk_materials"] = hls.get("total_chunk_materials", 0)
			sample["hlod_stale_completions"] = hls.get("stale_completions_discarded", 0)
			sample["hlod_merge_queue_us"] = hls.get("merge_queue_last_usec", 0)
			sample["hlod_completion_us"] = hls.get("completion_last_usec", 0)
	return sample


func _summarize(samples: Array[Dictionary]) -> Dictionary:
	if samples.is_empty():
		return {"samples": 0}
	var fps_min := 1.0e9
	var fps_max := 0.0
	var fps_sum := 0.0
	var draws_sum := 0.0
	var objs_sum := 0.0
	var prims_sum := 0.0
	var vram_max := 0.0
	var mid_vis_max := 0
	var hlod_cells_max := 0
	var hlod_surfaces_max := 0
	var hlod_materials_max := 0
	var hlod_stale_max := 0
	var hlod_merge_queue_max := 0
	var hlod_completion_max := 0
	var imp_max := 0
	var far_texture_upload_max := 0
	var far_multimesh_upload_max := 0
	var far_cell_scan_max := 0
	var far_page_count_max := 0
	var far_dirty_page_count_max := 0
	var far_pages_rebuilt_max := 0
	var far_uploaded_instances_max := 0
	var distant_light_count_max := 0
	var distant_light_page_count_max := 0
	var distant_light_scan_max := 0
	var distant_light_rebuild_max := 0
	for s: Dictionary in samples:
		var f := float(s.get("fps", 0.0))
		fps_min = minf(fps_min, f)
		fps_max = maxf(fps_max, f)
		fps_sum += f
		draws_sum += float(s.get("draws", 0))
		objs_sum += float(s.get("objs", 0))
		prims_sum += float(s.get("prims", 0))
		vram_max = maxf(vram_max, float(s.get("vram_mb", 0.0)))
		mid_vis_max = maxi(mid_vis_max, int(s.get("mid_visible", 0)))
		hlod_cells_max = maxi(hlod_cells_max, int(s.get("hlod_cells", 0)))
		hlod_surfaces_max = maxi(hlod_surfaces_max, int(s.get("hlod_chunk_surfaces", 0)))
		hlod_materials_max = maxi(hlod_materials_max, int(s.get("hlod_chunk_materials", 0)))
		hlod_stale_max = maxi(hlod_stale_max, int(s.get("hlod_stale_completions", 0)))
		hlod_merge_queue_max = maxi(hlod_merge_queue_max, int(s.get("hlod_merge_queue_us", 0)))
		hlod_completion_max = maxi(hlod_completion_max, int(s.get("hlod_completion_us", 0)))
		imp_max = maxi(imp_max, int(s.get("total_impostors", 0)))
		far_texture_upload_max = maxi(far_texture_upload_max, int(s.get("far_texture_upload_us", 0)))
		far_multimesh_upload_max = maxi(far_multimesh_upload_max, int(s.get("far_multimesh_upload_us", 0)))
		far_cell_scan_max = maxi(far_cell_scan_max, int(s.get("far_cell_scan_us", 0)))
		far_page_count_max = maxi(far_page_count_max, int(s.get("far_page_count", 0)))
		far_dirty_page_count_max = maxi(far_dirty_page_count_max, int(s.get("far_dirty_page_count", 0)))
		far_pages_rebuilt_max = maxi(far_pages_rebuilt_max, int(s.get("far_pages_rebuilt", 0)))
		far_uploaded_instances_max = maxi(far_uploaded_instances_max, int(s.get("far_uploaded_instances", 0)))
		distant_light_count_max = maxi(distant_light_count_max, int(s.get("distant_light_count", 0)))
		distant_light_page_count_max = maxi(distant_light_page_count_max, int(s.get("distant_light_page_count", 0)))
		distant_light_scan_max = maxi(distant_light_scan_max, int(s.get("distant_light_scan_us", 0)))
		distant_light_rebuild_max = maxi(distant_light_rebuild_max, int(s.get("distant_light_rebuild_us", 0)))
	var n := float(samples.size())
	return {
		"samples": samples.size(),
		"fps_min": fps_min,
		"fps_max": fps_max,
		"fps_avg": fps_sum / n,
		"draws_avg": draws_sum / n,
		"objs_avg": objs_sum / n,
		"prims_avg": prims_sum / n,
		"vram_mb_max": vram_max,
		"mid_visible_max": mid_vis_max,
		"hlod_cells_max": hlod_cells_max,
		"hlod_chunk_surfaces_max": hlod_surfaces_max,
		"hlod_chunk_materials_max": hlod_materials_max,
		"hlod_stale_completions_max": hlod_stale_max,
		"hlod_merge_queue_max_us": hlod_merge_queue_max,
		"hlod_completion_max_us": hlod_completion_max,
		"impostors_max": imp_max,
		"far_texture_upload_max_us": far_texture_upload_max,
		"far_multimesh_upload_max_us": far_multimesh_upload_max,
		"far_cell_scan_max_us": far_cell_scan_max,
		"far_page_count_max": far_page_count_max,
		"far_dirty_page_count_max": far_dirty_page_count_max,
		"far_pages_rebuilt_max": far_pages_rebuilt_max,
		"far_uploaded_instances_max": far_uploaded_instances_max,
		"distant_light_count_max": distant_light_count_max,
		"distant_light_page_count_max": distant_light_page_count_max,
		"distant_light_scan_max_us": distant_light_scan_max,
		"distant_light_rebuild_max_us": distant_light_rebuild_max,
	}


func _enabled_flags_for_rung(idx: int) -> Array[String]:
	var out: Array[String] = []
	for i in range(mini(idx, LADDER_ADD_ORDER.size())):
		out.append(LADDER_ADD_ORDER[i])
	return out


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
			"sample_duration_s": SAMPLE_DURATION_S,
			"ladder_add_order": LADDER_ADD_ORDER,
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
		rows.append({
			"rung": r.get("rung", -1),
			"label": r.get("label", "?"),
			"fps_avg": s.get("fps_avg", 0.0),
			"fps_min": s.get("fps_min", 0.0),
			"draws_avg": s.get("draws_avg", 0.0),
			"objs_avg": s.get("objs_avg", 0.0),
			"hlod_cells_max": s.get("hlod_cells_max", 0),
			"impostors_max": s.get("impostors_max", 0),
		})
	return {
		"output_dir": _output_dir,
		"rung_count": _rungs.size(),
		"benchmark_mode_metadata": _get_benchmark_mode_metadata_snapshot(),
		"rows": rows,
	}
