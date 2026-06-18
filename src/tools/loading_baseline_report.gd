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
	var esm_primary_timing := _as_dict(options.get("esm_primary_timing", {}))
	var loading_gate_phase_totals := _as_dict(options.get("loading_gate_phase_totals_ms", {}))
	var loading_gate_phase_max := _as_dict(options.get("loading_gate_phase_max_ms", {}))
	var inner_ring := _as_dict(options.get("inner_ring", {}))
	var cell_manager := _as_dict(options.get("cell_manager", {}))
	var streaming := _as_dict(options.get("streaming", {}))
	var bsa_cache := _as_dict(options.get("bsa_cache", {}))
	var model_loader := _as_dict(options.get("model_loader", {}))
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
	var attribution := _build_first_playable_attribution(
		timestamps,
		phase_times,
		esm_primary_timing,
		loading_gate_phase_totals,
		gate_duration_s,
		process_to_first_playable_s
	)
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
		"first_playable_attribution_ms": attribution.get("owner_ms", {}),
		"source_data_total_ms": attribution.get("source_data_total_ms", 0.0),
		"cell_manager_publication_ms": attribution.get("cell_manager_publication_ms", 0.0),
		"inner_ring_gate_wait_ms": attribution.get("inner_ring_gate_wait_ms", 0.0),
	}
	var payload := {
		"timestamp": Time.get_datetime_string_from_system(),
		"loading_baseline": {
			"cache_state": cache_state,
			"related_scenarios": ["cold_start", "warm_start", "first_playable"],
		},
		"timings_msec": _json_safe(timestamps),
		"loading_phase_times_ms": _json_safe(phase_times),
		"esm_primary_timing": _json_safe(esm_primary_timing),
		"loading_gate_phase_totals_ms": _json_safe(loading_gate_phase_totals),
		"loading_gate_phase_max_ms": _json_safe(loading_gate_phase_max),
		"loading_gate_phase_frames": int(options.get("loading_gate_phase_frames", 0)),
		"first_playable_attribution": _json_safe(attribution),
		"inner_ring": _json_safe(inner_ring),
		"cell_manager": _json_safe(cell_manager),
		"streaming": _json_safe(streaming),
		"bsa_cache": _json_safe(bsa_cache),
		"model_loader": _json_safe(model_loader),
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


static func _build_first_playable_attribution(
	timestamps: Dictionary,
	phase_times: Dictionary,
	esm_primary_timing: Dictionary,
	loading_gate_phase_totals: Dictionary,
	gate_duration_s: float,
	process_to_first_playable_s: float
) -> Dictionary:
	var source_data_other_ms := _sum_keys(phase_times, ["mod registry", "ESP mods"])
	var esm_native_primary_ms := _number(esm_primary_timing.get(
		"native_primary_ms",
		phase_times.get("ESM load (primary)", 0.0)
	))
	var gdscript_supplement_populate_ms := _number(esm_primary_timing.get("gdscript_supplement_populate_ms", 0.0))
	var bsa_cache_ms := _sum_keys(phase_times, ["BSA archives", "BSA prewarm"])
	var terrain_ms := _sum_keys(phase_times, ["Terrain3D init", "terrain data load", "horizon maps"])
	var model_material_warmup_ms := _sum_keys(phase_times, ["model cache index", "preload common models"])
	var source_data_total_ms := (
		source_data_other_ms
		+ esm_native_primary_ms
		+ gdscript_supplement_populate_ms
		+ bsa_cache_ms
	)
	var init_async_duration_ms := _delta_ms(timestamps, "init_async_start_msec", "init_async_done_msec")
	var init_async_other_ms := maxf(
		0.0,
		init_async_duration_ms - source_data_total_ms - terrain_ms - model_material_warmup_ms
	) if init_async_duration_ms >= 0.0 else 0.0
	var owner_ms := {
		"engine_scene_ready_ms": _positive_delta_ms(timestamps, "process_start_msec", "ready_msec"),
		"ready_to_init_async_start_ms": _positive_delta_ms(timestamps, "ready_msec", "init_async_start_msec"),
		"source_data_other_ms": source_data_other_ms,
		"esm_native_primary_ms": esm_native_primary_ms,
		"gdscript_supplement_populate_ms": gdscript_supplement_populate_ms,
		"bsa_cache_ms": bsa_cache_ms,
		"terrain_ms": terrain_ms,
		"model_material_warmup_ms": model_material_warmup_ms,
		"init_async_other_ms": init_async_other_ms,
		"post_init_to_boot_gate_ms": _positive_delta_ms(timestamps, "init_async_done_msec", "boot_gate_start_msec"),
		"inner_ring_gate_wait_ms": maxf(0.0, gate_duration_s * 1000.0),
	}
	var additive_known_ms := 0.0
	for key: String in owner_ms.keys():
		additive_known_ms += float(owner_ms[key])
	var total_ms := process_to_first_playable_s * 1000.0 if process_to_first_playable_s >= 0.0 else -1.0
	if total_ms >= 0.0:
		owner_ms["unattributed_or_other_init_ms"] = maxf(0.0, total_ms - additive_known_ms)
	var cell_manager_publication_ms := _number(loading_gate_phase_totals.get("cell_manager_publication", 0.0))
	return {
		"owner_ms": owner_ms,
		"source_data_total_ms": source_data_total_ms,
		"cell_manager_publication_ms": cell_manager_publication_ms,
		"inner_ring_gate_wait_ms": owner_ms["inner_ring_gate_wait_ms"],
		"cell_manager_publication_note": "Accumulated streaming publication work inside the inner-ring gate; not additive with inner_ring_gate_wait_ms.",
	}


static func _sum_keys(values: Dictionary, keys: Array[String]) -> float:
	var total := 0.0
	for key: String in keys:
		total += _number(values.get(key, 0.0))
	return total


static func _number(value: Variant) -> float:
	if value is int or value is float:
		return float(value)
	return 0.0


static func _positive_delta_ms(timestamps: Dictionary, from_key: String, to_key: String) -> float:
	var delta := _delta_ms(timestamps, from_key, to_key)
	return delta if delta >= 0.0 else 0.0


static func _delta_ms(timestamps: Dictionary, from_key: String, to_key: String) -> float:
	if not timestamps.has(from_key) or not timestamps.has(to_key):
		return -1.0
	var from_msec := int(timestamps[from_key])
	var to_msec := int(timestamps[to_key])
	if from_msec <= 0 or to_msec <= 0 or to_msec < from_msec:
		return -1.0
	return float(to_msec - from_msec)


static func _delta_s(timestamps: Dictionary, from_key: String, to_key: String) -> float:
	var delta_ms := _delta_ms(timestamps, from_key, to_key)
	if delta_ms < 0.0:
		return -1.0
	return delta_ms / 1000.0


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
