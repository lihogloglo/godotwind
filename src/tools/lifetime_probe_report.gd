class_name LifetimeProbeReport
extends RefCounted

const ReportContract := preload("res://src/tools/performance_report_contract.gd")
const OUTPUT_DIR_BASE := "user://benchmark_results"
const DEFAULT_SCENARIO := "fast_travel_streaming"
const MODE := "object_lifetime_probe"


static func sample(label: String, loop_index: int = -1, context: Dictionary = {}) -> Dictionary:
	return {
		"label": label,
		"loop_index": loop_index,
		"timestamp_msec": Time.get_ticks_msec(),
		"object_count": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"resource_count": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"node_count": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"orphan_node_count": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"static_memory_mb": _bytes_to_mb(Performance.get_monitor(Performance.MEMORY_STATIC)),
		"message_buffer_max_mb": _bytes_to_mb(Performance.get_monitor(Performance.MEMORY_MESSAGE_BUFFER_MAX)),
		"context": _json_safe(context),
	}


static func write(options: Dictionary, output_dir: String = OUTPUT_DIR_BASE, stamp: String = "") -> String:
	var dir_path := output_dir
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)
	var scenario := str(options.get("scenario", DEFAULT_SCENARIO))
	var safe_stamp := stamp if not stamp.is_empty() else Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var path := "%s/lifetime_probe_%s_%s.json" % [dir_path, scenario, safe_stamp]
	var payload := build(options.merged({"scenario": scenario}, true), path)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return ""
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()
	return path


static func build(options: Dictionary, output_path: String = "") -> Dictionary:
	var samples: Array = _samples(options.get("samples", []))
	var loop_count := int(options.get("loop_count", max(0, samples.size() - 1)))
	var invalid_reasons: Array[String] = []
	if samples.size() < 2:
		invalid_reasons.append("too_few_lifetime_samples")
	var mode_meta := _as_dict(options.get("benchmark_mode_metadata", {}))
	mode_meta["invalid_reasons"] = invalid_reasons
	mode_meta["valid_for_performance_baseline"] = invalid_reasons.is_empty()

	var summary := _summarize(samples)
	summary["loop_count"] = loop_count
	summary["sample_count"] = samples.size()
	summary["probe_kind"] = str(options.get("probe_kind", "teleport_loop"))

	var payload := {
		"timestamp": Time.get_datetime_string_from_system(),
		"probe_kind": summary["probe_kind"],
		"samples": _json_safe(samples),
		"benchmark_mode_metadata": mode_meta,
	}
	return ReportContract.apply(payload, {
		"scenario": str(options.get("scenario", DEFAULT_SCENARIO)),
		"mode": MODE,
		"summary": summary,
		"duration_s": _duration_s(samples),
		"benchmark_mode_metadata": mode_meta,
		"invalid_reasons": invalid_reasons,
		"raw_outputs": {"summary_json": output_path} if not output_path.is_empty() else {},
	})


static func _summarize(samples: Array) -> Dictionary:
	if samples.is_empty():
		return {}
	var first: Dictionary = _as_dict(samples[0])
	var last: Dictionary = _as_dict(samples[samples.size() - 1])
	var summary := {
		"object_delta": _delta(first, last, "object_count"),
		"resource_delta": _delta(first, last, "resource_count"),
		"node_delta": _delta(first, last, "node_count"),
		"orphan_node_delta": _delta(first, last, "orphan_node_count"),
		"static_memory_delta_mb": _delta(first, last, "static_memory_mb"),
		"peak_static_memory_mb": float(first.get("static_memory_mb", 0.0)),
		"peak_object_count": int(first.get("object_count", 0)),
		"peak_resource_count": int(first.get("resource_count", 0)),
		"peak_node_count": int(first.get("node_count", 0)),
	}
	for item in samples:
		var sample_dict := _as_dict(item)
		summary["peak_static_memory_mb"] = maxf(float(summary["peak_static_memory_mb"]), float(sample_dict.get("static_memory_mb", 0.0)))
		summary["peak_object_count"] = maxi(int(summary["peak_object_count"]), int(sample_dict.get("object_count", 0)))
		summary["peak_resource_count"] = maxi(int(summary["peak_resource_count"]), int(sample_dict.get("resource_count", 0)))
		summary["peak_node_count"] = maxi(int(summary["peak_node_count"]), int(sample_dict.get("node_count", 0)))
	return summary


static func _samples(value: Variant) -> Array:
	if value is Array:
		return (value as Array).duplicate(true)
	return []


static func _as_dict(value: Variant) -> Dictionary:
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	return {}


static func _delta(first: Dictionary, last: Dictionary, key: String) -> Variant:
	if key.ends_with("_mb"):
		return float(last.get(key, 0.0)) - float(first.get(key, 0.0))
	return int(last.get(key, 0)) - int(first.get(key, 0))


static func _duration_s(samples: Array) -> float:
	if samples.size() < 2:
		return 0.0
	var first := _as_dict(samples[0])
	var last := _as_dict(samples[samples.size() - 1])
	return maxf(0.0, float(int(last.get("timestamp_msec", 0)) - int(first.get("timestamp_msec", 0))) / 1000.0)


static func _bytes_to_mb(value: float) -> float:
	return value / 1048576.0


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
		TYPE_VECTOR2I:
			return {"x": value.x, "y": value.y}
		_:
			return str(value)
