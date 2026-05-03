## PerfSweep - quick per-subsystem isolation cost sweep.
##
## Tests each active subsystem by disabling it from the current baseline, then
## restores the exact initial toggle state. Console: perf_sweep / sweep.
## CLI wiring can run this unattended and save JSON for post-run comparison.
class_name PerfSweep
extends Node

signal sweep_complete(summary: Dictionary)

const OUTPUT_DIR_BASE := "user://benchmark_results"

## Runtime filters skip flags that were already OFF at sweep start, so launch
## isolation flags such as --no-hlod / --no-impostors remain in force.
const SWEEP_ORDER: Array[String] = [
	"near_objects",
	"mid_objects",
	"distant_lights",
	"shadows",
	"postfx",
	"sky",
	"weather",
	"impostors",
	"hlod",
	"ocean",
	"characters",
	"terrain",
]

const SETTLE_S := 2.0
const RECORD_S := 4.0
const REENABLE_S := 1.5
const READY_STABLE_S := 5.0
const READY_FALLBACK_S := 90.0

enum _State { WAIT_READY, BASELINE_RECORD, SETTLE, RECORD, REENABLE, DONE }

var _state: _State = _State.WAIT_READY
var _timer: float = 0.0
var _ready_elapsed: float = 0.0
var _total_elapsed: float = 0.0
var _sample_sum: float = 0.0
var _sample_count: int = 0

var _baseline_fps: float = 0.0
var _baseline_summary: Dictionary = {}
var _results: Array[Dictionary] = []
var _current_idx: int = 0
var _active_sweep_order: Array[String] = []

var _toggles: RefCounted = null
var _console: Node = null
var _streaming_manager: Variant = null

var _current_name: String = ""
var _initial_state: Dictionary = {}
var _current_samples: Array[Dictionary] = []
var _stamp: String = ""
var _auto_quit: bool = false
var _output_path: String = ""


static func register_console_commands(
	console: Node,
	streaming_manager: Variant,
	_cell_manager: Variant,
	toggles: RefCounted
) -> void:
	var script_ref := load("res://src/tools/perf_sweep.gd")
	var run := func(_args: Dictionary) -> Variant:
		var sweep: Node = script_ref.new()
		sweep.name = "PerfSweep"
		console.get_tree().root.add_child(sweep)
		sweep.init(toggles, console, streaming_manager)
		var total_s := int((SETTLE_S + RECORD_S + REENABLE_S) * SWEEP_ORDER.size() + RECORD_S + 4.0)
		return "perf_sweep: starting ~%ds isolation sweep; results log to console and JSON" % total_s

	console.register_command(
		"perf_sweep",
		run,
		"Quick subsystem isolation sweep; shows per-subsystem FPS cost",
		"benchmark",
		PackedStringArray(["sweep"]),
	)


func init(
	toggles: RefCounted,
	console: Node,
	streaming_manager: Variant = null,
	stamp: String = "",
	auto_quit: bool = false
) -> void:
	_toggles = toggles
	_console = console
	_streaming_manager = streaming_manager
	_stamp = stamp if not stamp.is_empty() else Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	_auto_quit = auto_quit
	_state = _State.WAIT_READY
	_timer = 0.0
	_ready_elapsed = 0.0
	_total_elapsed = 0.0
	_sample_sum = 0.0
	_sample_count = 0
	_current_idx = 0
	_results.clear()
	_baseline_summary.clear()
	_current_samples.clear()
	_initial_state = _toggles.get_state() if _toggles and _toggles.has_method("get_state") else {}
	_active_sweep_order = _build_active_sweep_order()
	Log.info("tools", "PerfSweep: waiting for streaming settle; baseline %.0fs, then %d active subsystems" % [
		RECORD_S, _active_sweep_order.size()])
	_print("perf_sweep: waiting for streaming settle before baseline")


func _process(delta: float) -> void:
	_timer += delta
	_total_elapsed += delta

	match _state:
		_State.WAIT_READY:
			if _is_ready_to_record(delta) or _total_elapsed >= READY_FALLBACK_S:
				if _total_elapsed >= READY_FALLBACK_S:
					_print("settle fallback reached; recording baseline with current state")
				_timer = 0.0
				_sample_sum = 0.0
				_sample_count = 0
				_current_samples.clear()
				_state = _State.BASELINE_RECORD
				_print("perf_sweep: recording baseline %.0fs; keep camera still" % RECORD_S)

		_State.BASELINE_RECORD:
			_accumulate_sample(delta)
			if _timer >= RECORD_S:
				_baseline_fps = _flush_avg()
				_baseline_summary = _summarize_samples(_current_samples)
				_current_samples.clear()
				_print("baseline: %.0f FPS; starting subsystem sweep" % _baseline_fps)
				_advance_sweep()

		_State.SETTLE:
			if _timer >= SETTLE_S:
				_timer = 0.0
				_sample_sum = 0.0
				_sample_count = 0
				_current_samples.clear()
				_state = _State.RECORD

		_State.RECORD:
			_accumulate_sample(delta)
			if _timer >= RECORD_S:
				var fps := _flush_avg()
				var summary := _summarize_samples(_current_samples)
				_current_samples.clear()
				var gain := fps - _baseline_fps
				var frame_ms_baseline := 1000.0 / maxf(_baseline_fps, 0.001)
				var frame_ms_now := 1000.0 / maxf(fps, 0.001)
				var cost_ms := frame_ms_baseline - frame_ms_now
				_results.append({
					"name": _current_name,
					"fps": fps,
					"gain_fps": gain,
					"cost_ms": cost_ms,
					"summary": summary,
				})
				_print("  %s: %.0f FPS (baseline delta %+.0f FPS)" % [_current_name, fps, gain])
				if _toggles:
					_toggles.set_flag(_current_name, bool(_initial_state.get(_current_name, true)))
				_timer = 0.0
				_state = _State.REENABLE

		_State.REENABLE:
			if _timer >= REENABLE_S:
				_current_idx += 1
				_advance_sweep()

		_State.DONE:
			pass


func _is_ready_to_record(delta: float) -> bool:
	var ready := true
	if _streaming_manager != null:
		if _streaming_manager.has_method("is_in_startup_phase") and _streaming_manager.is_in_startup_phase():
			ready = false
		if _streaming_manager.has_method("get_stats"):
			var stats: Dictionary = _streaming_manager.get_stats()
			if int(stats.get("instantiation_queue", 0)) > 0:
				ready = false
	if ready:
		_ready_elapsed += delta
	else:
		_ready_elapsed = 0.0
	return _ready_elapsed >= READY_STABLE_S


func _advance_sweep() -> void:
	if _current_idx >= _active_sweep_order.size():
		_finish()
		_state = _State.DONE
		return

	_current_name = _active_sweep_order[_current_idx]
	_print("  testing: %s (disable %.0fs settle + %.0fs record)" % [
		_current_name, SETTLE_S, RECORD_S])

	if _toggles:
		_toggles.set_flag(_current_name, false)

	_timer = 0.0
	_state = _State.SETTLE


func _build_active_sweep_order() -> Array[String]:
	var names: Array[String] = []
	if not _toggles:
		return names
	var available: Array[String] = _toggles.get_flag_names()
	for name: String in SWEEP_ORDER:
		if name in available and bool(_initial_state.get(name, false)):
			names.append(name)
	return names


func _accumulate_sample(delta: float) -> void:
	_sample_sum += Engine.get_frames_per_second()
	_sample_count += 1
	_current_samples.append(_snapshot_sample(delta))


func _flush_avg() -> float:
	if _sample_count == 0:
		return 0.0
	var avg := _sample_sum / float(_sample_count)
	_sample_sum = 0.0
	_sample_count = 0
	_timer = 0.0
	return avg


func _snapshot_sample(delta: float) -> Dictionary:
	var p := Performance
	var sample := {
		"fps": Engine.get_frames_per_second(),
		"frame_ms": delta * 1000.0,
		"draws_total": int(p.get_monitor(p.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"objs_total": int(p.get_monitor(p.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"prims_total": int(p.get_monitor(p.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"process_ms": p.get_monitor(p.TIME_PROCESS) * 1000.0,
		"physics_ms": p.get_monitor(p.TIME_PHYSICS_PROCESS) * 1000.0,
		"vram_mb": p.get_monitor(p.RENDER_VIDEO_MEM_USED) / 1048576.0,
		"texture_mb": p.get_monitor(p.RENDER_TEXTURE_MEM_USED) / 1048576.0,
	}
	var vp := get_viewport()
	if vp != null:
		sample["draws_visible"] = int(vp.get_render_info(
			Viewport.RENDER_INFO_TYPE_VISIBLE,
			Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME,
		))
		sample["draws_shadow"] = int(vp.get_render_info(
			Viewport.RENDER_INFO_TYPE_SHADOW,
			Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME,
		))
		sample["objs_visible"] = int(vp.get_render_info(
			Viewport.RENDER_INFO_TYPE_VISIBLE,
			Viewport.RENDER_INFO_OBJECTS_IN_FRAME,
		))
		sample["objs_shadow"] = int(vp.get_render_info(
			Viewport.RENDER_INFO_TYPE_SHADOW,
			Viewport.RENDER_INFO_OBJECTS_IN_FRAME,
		))
		sample["prims_visible"] = int(vp.get_render_info(
			Viewport.RENDER_INFO_TYPE_VISIBLE,
			Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME,
		))
		sample["prims_shadow"] = int(vp.get_render_info(
			Viewport.RENDER_INFO_TYPE_SHADOW,
			Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME,
		))
		sample["mesh_lod_threshold"] = vp.mesh_lod_threshold
	if _streaming_manager != null and _streaming_manager.has_method("get_stats"):
		var stats: Dictionary = _streaming_manager.get_stats()
		sample["loaded_cells"] = stats.get("loaded_cells", 0)
		sample["loading_cells"] = stats.get("loading_cells", 0)
		sample["queue"] = stats.get("instantiation_queue", 0)
		sample["stream_total_ms"] = stats.get("frame_total_ms", 0.0)
		sample["load_radius_cells"] = stats.get("load_radius_cells", 0)
		if _streaming_manager.has_method("get_distant_render_end_m"):
			sample["distant_render_end_m"] = _streaming_manager.get_distant_render_end_m()
		sample["mid_instances"] = stats.get("mid_instances", 0)
		sample["mid_visible"] = stats.get("mid_visible", 0)
		sample["mid_cell_buckets"] = stats.get("mid_cell_buckets", 0)
		sample["mid_bucket_draw_groups"] = stats.get("mid_bucket_draw_groups", 0)
		sample["mid_bucket_rs_instances"] = stats.get("mid_bucket_rs_instances", 0)
		sample["mid_bucket_instances"] = stats.get("mid_bucket_instances", 0)
		sample["total_impostors"] = stats.get("total_impostors", 0)
		sample["hlod_cells"] = stats.get("hlod_cells", 0)
	return sample


func _summarize_samples(samples: Array[Dictionary]) -> Dictionary:
	if samples.is_empty():
		return {"samples": 0}
	var sums: Dictionary = {}
	var maxes: Dictionary = {}
	var frame_times := PackedFloat64Array()
	for sample: Dictionary in samples:
		frame_times.append(float(sample.get("frame_ms", 0.0)))
		for key: Variant in sample.keys():
			var name := str(key)
			var value := float(sample[key])
			sums[name] = float(sums.get(name, 0.0)) + value
			maxes[name] = maxf(float(maxes.get(name, value)), value)
	_sort_float_array(frame_times)
	var last_idx := frame_times.size() - 1
	var summary := {
		"samples": samples.size(),
		"frame_ms_p50": frame_times[frame_times.size() / 2],
		"frame_ms_p95": frame_times[int(float(last_idx) * 0.95)],
		"frame_ms_p99": frame_times[int(float(last_idx) * 0.99)],
	}
	var n := float(samples.size())
	for key: Variant in sums.keys():
		var name := str(key)
		summary["%s_avg" % name] = float(sums[name]) / n
		summary["%s_max" % name] = float(maxes[name])
	return summary


func _sort_float_array(values: PackedFloat64Array) -> void:
	for i in range(1, values.size()):
		var key := values[i]
		var j := i - 1
		while j >= 0 and values[j] > key:
			values[j + 1] = values[j]
			j -= 1
		values[j + 1] = key


func _finish() -> void:
	_results.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.gain_fps > b.gain_fps
	)

	var lines: PackedStringArray = PackedStringArray()
	lines.append("")
	lines.append("========== PERF SWEEP RESULTS ==========")
	lines.append("Baseline: %.0f FPS (%.1f ms/frame)" % [
		_baseline_fps, 1000.0 / maxf(_baseline_fps, 0.001)])
	if not _baseline_summary.is_empty():
		lines.append("  draws avg total/visible/shadow: %.0f / %.0f / %.0f" % [
			_baseline_summary.get("draws_total_avg", 0.0),
			_baseline_summary.get("draws_visible_avg", 0.0),
			_baseline_summary.get("draws_shadow_avg", 0.0),
		])
		lines.append("  prims avg visible/shadow: %.0fk / %.0fk" % [
			_baseline_summary.get("prims_visible_avg", 0.0) / 1000.0,
			_baseline_summary.get("prims_shadow_avg", 0.0) / 1000.0,
		])
	lines.append("")
	lines.append("Subsystem costs (sorted, highest first):")
	lines.append("  %-15s %8s %10s %8s %8s %9s %9s" % [
		"subsystem", "FPS w/o", "dFPS", "dms", "%frame", "visDraw", "shadDraw"])

	var frame_ms_base := 1000.0 / maxf(_baseline_fps, 0.001)
	var primary := ""
	var primary_gain := 0.0
	for r: Dictionary in _results:
		var gain: float = r.gain_fps
		var cost_ms: float = r.cost_ms
		var pct := (cost_ms / frame_ms_base) * 100.0 if frame_ms_base > 0.0 else 0.0
		var marker := " <- PRIMARY" if primary.is_empty() and gain > 5.0 else ""
		var summary: Dictionary = r.get("summary", {})
		lines.append("  %-15s %8.0f %+10.0f %+8.1f %7.1f%% %9.0f %9.0f%s" % [
			r.name,
			r.fps,
			gain,
			cost_ms,
			pct,
			summary.get("draws_visible_avg", 0.0),
			summary.get("draws_shadow_avg", 0.0),
			marker,
		])
		if primary.is_empty() and gain > primary_gain:
			primary_gain = gain
			primary = r.name

	lines.append("")
	if not primary.is_empty() and primary_gain > 5.0:
		lines.append("Primary bottleneck: %s (%.0f FPS -> %.0f FPS if fixed)" % [
			primary, _baseline_fps, _baseline_fps + primary_gain])
	elif _baseline_fps >= 60.0:
		lines.append("All measured subsystems OK; baseline already >=60 FPS")
	else:
		lines.append("No single bottleneck dominates; inspect JSON pass metrics")
	lines.append("=========================================")

	var final_summary := _build_final_summary()
	_output_path = _save_json(final_summary)
	final_summary["output_path"] = _output_path

	Log.info("tools", "\n".join(lines))
	if not _output_path.is_empty():
		Log.info("tools", "PerfSweep JSON saved: %s" % _output_path)
	if _console and _console.has_method("print_line"):
		for line: String in lines:
			_console.print_line(line)
		if not _output_path.is_empty():
			_console.print_line("JSON saved: %s" % _output_path)

	_restore_initial_state()
	sweep_complete.emit(final_summary)

	get_tree().create_timer(2.0).timeout.connect(func() -> void:
		if _auto_quit:
			Log.info("shutdown", "PERF_SWEEP_QUIT - perf sweep complete")
			Engine.set_meta("_quitting", true)
			if _streaming_manager != null:
				_streaming_manager.set_process(false)
				if _streaming_manager.has_method("fast_cleanup"):
					_streaming_manager.call("fast_cleanup")
			get_tree().quit()
		else:
			queue_free()
	)


func _restore_initial_state() -> void:
	if not _toggles:
		return
	for name: String in _initial_state:
		_toggles.set_flag(name, bool(_initial_state[name]))


func _build_final_summary() -> Dictionary:
	return {
		"stamp": _stamp,
		"output_path": _output_path,
		"initial_toggle_state": _initial_state,
		"sweep_order": _active_sweep_order,
		"baseline_fps": _baseline_fps,
		"baseline_summary": _baseline_summary,
		"results": _results,
	}


func _save_json(summary: Dictionary) -> String:
	if not DirAccess.dir_exists_absolute(OUTPUT_DIR_BASE):
		DirAccess.make_dir_recursive_absolute(OUTPUT_DIR_BASE)
	var path := "%s/perf_sweep_%s.json" % [OUTPUT_DIR_BASE, _stamp]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		Log.error("tools", "PerfSweep: failed to open %s" % path)
		return ""
	file.store_string(JSON.stringify(summary, "\t"))
	file.close()
	return path


func _print(msg: String) -> void:
	Log.info("tools", "PerfSweep: %s" % msg)
	if _console and _console.has_method("print_line"):
		_console.print_line(msg)
