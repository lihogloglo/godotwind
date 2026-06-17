class_name LoadingBaselineReport
extends RefCounted

const ReportContract := preload("res://src/tools/performance_report_contract.gd")
const OUTPUT_DIR_BASE := "user://benchmark_results"
const DEFAULT_SCENARIO := "first_playable"


static func normalize_scenario(value: String) -> String:
	match value.strip_edges().to_lower():
		"cold", "cold_start":
			return "cold_start"
		"warm", "warm_start":
			return "warm_start"
		"playable", "first_playable", "":
			return "first_playable"
		_:
			return DEFAULT_SCENARIO


static func write(options: Dictionary, output_dir: String = OUTPUT_DIR_BASE, stamp: String = "") -> String:
	var dir_path := output_dir
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)
	var scenario := normalize_scenario(str(options.get("scenario", DEFAULT_SCENARIO)))
	var safe_stamp := stamp if not stamp.is_empty() else Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var path := "%s/loading_baseline_%s_%s.json" % [dir_path, scenario, safe_stamp]
	var payload := build(options.merged({"scenario": scenario}, true), path)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return ""
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()
	return path


static func build(options: Dictionary, output_path: String = "") -> Dictionary:
	var scenario := normalize_scenario(str(options.get("scenario", DEFAULT_SCENARIO)))
	var reason := str(options.get("reason", "boot"))
	var timed_out := bool(options.get("timed_out", false))
	var gate_duration_s := float(options.get("duration_s", 0.0))
	var timestamps := _as_dict(options.get("timestamps", {}))
	var phase_times := _as_dict(options.get("phase_times_ms", options.get("phase_times", {})))
	var inner_ring := _as_dict(options.get("inner_ring", {}))
	var cell_manager := _as_dict(options.get("cell_manager", {}))
	var streaming := _as_dict(options.get("streaming", {}))
	var cache_state := str(options.get("cache_state", "unspecified"))
	var mode_meta := _as_dict(options.get("benchmark_mode_metadata", streaming.get("benchmark_mode_metadata", {})))
	var invalid_reasons := _strings(mode_meta.get("invalid_reasons", []))
	if timed_out:
		_append_unique(invalid_reasons, "loading_gate_timeout")
	if (scenario == "cold_start" or scenario == "warm_start") and cache_state == "unspecified":
		_append_unique(invalid_reasons, "cache_state_unspecified")
	mode_meta["invalid_reasons"] = invalid_reasons
	mode_meta["valid_for_performance_baseline"] = bool(mode_meta.get("valid_for_performance_baseline", true)) and invalid_reasons.is_empty()

	var process_to_first_playable_s := _delta_s(timestamps, "process_start_msec", "first_playable_msec")
	var summary := {
		"loading_reason": reason,
		"loading_gate_duration_s": gate_duration_s,
		"timed_out": timed_out,
		"first_playable_reached": not timed_out,
		"process_start_to_ready_s": _delta_s(timestamps, "process_start_msec", "ready_msec"),
		"process_start_to_init_done_s": _delta_s(timestamps, "process_start_msec", "init_async_done_msec"),
		"process_start_to_first_playable_s": process_to_first_playable_s,
		"init_async_duration_s": _delta_s(timestamps, "init_async_start_msec", "init_async_done_msec"),
		"cache_state": cache_state,
		"phase_count": phase_times.size(),
	}
	var payload := {
		"timestamp": Time.get_datetime_string_from_system(),
		"loading_baseline": {
			"cache_state": cache_state,
			"related_scenarios": ["cold_start", "warm_start", "first_playable"],
		},
		"timings_msec": _json_safe(timestamps),
		"loading_phase_times_ms": _json_safe(phase_times),
		"inner_ring": _json_safe(inner_ring),
		"cell_manager": _json_safe(cell_manager),
		"streaming": _json_safe(streaming),
		"benchmark_mode_metadata": mode_meta,
	}
	return ReportContract.apply(payload, {
		"scenario": scenario,
		"mode": "loading_baseline",
		"summary": summary,
		"duration_s": process_to_first_playable_s if process_to_first_playable_s >= 0.0 else gate_duration_s,
		"benchmark_mode_metadata": mode_meta,
		"invalid_reasons": invalid_reasons,
		"raw_outputs": {"summary_json": output_path} if not output_path.is_empty() else {},
	})


static func _as_dict(value: Variant) -> Dictionary:
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	return {}


static func _strings(value: Variant) -> Array[String]:
	var out: Array[String] = []
	if value is Array:
		for item in value:
			_append_unique(out, str(item))
	return out


static func _append_unique(values: Array[String], value: String) -> void:
	if not value.is_empty() and not values.has(value):
		values.append(value)


static func _delta_s(timestamps: Dictionary, from_key: String, to_key: String) -> float:
	if not timestamps.has(from_key) or not timestamps.has(to_key):
		return -1.0
	var from_msec := int(timestamps[from_key])
	var to_msec := int(timestamps[to_key])
	if from_msec <= 0 or to_msec <= 0:
		return -1.0
	return maxf(0.0, float(to_msec - from_msec) / 1000.0)


static func _json_safe(value: Variant) -> Variant:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return value
		TYPE_STRING_NAME:
			return str(value)
		TYPE_ARRAY:
			var out: Array = []
			for item in value:
				out.append(_json_safe(item))
			return out
		TYPE_DICTIONARY:
			var out := {}
			for key in (value as Dictionary).keys():
				out[str(key)] = _json_safe((value as Dictionary)[key])
			return out
		_:
			return str(value)
