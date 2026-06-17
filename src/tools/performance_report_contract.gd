class_name PerformanceReportContract
extends RefCounted

const SCHEMA := "godotwind_performance_report_v1"


static func apply(payload: Dictionary, options: Dictionary = {}) -> Dictionary:
	var out := payload.duplicate(true)
	var meta: Dictionary = _as_dict(options.get("meta", out.get("meta", {})))
	var mode_meta: Dictionary = _as_dict(options.get("benchmark_mode_metadata", out.get("benchmark_mode_metadata", meta.get("benchmark_mode_metadata", {}))))
	var summary: Dictionary = _as_dict(options.get("summary", out.get("summary", {})))

	out["schema"] = SCHEMA
	out["scenario"] = str(options.get("scenario", out.get("scenario", meta.get("scenario", "unknown"))))
	out["mode"] = str(options.get("mode", out.get("mode", "unknown")))
	out["started_at"] = str(options.get("started_at", out.get("timestamp", Time.get_datetime_string_from_system())))
	out["duration_s"] = float(options.get("duration_s", summary.get("total_time_s", out.get("total_time_s", meta.get("duration_s", 0.0)))))
	out["summary"] = summary
	out["benchmark_mode_metadata"] = mode_meta
	out["valid_for_performance_baseline"] = bool(mode_meta.get("valid_for_performance_baseline", true))
	out["invalid_reasons"] = _dedup_strings(mode_meta.get("invalid_reasons", []) as Array, options.get("invalid_reasons", []) as Array)
	out["threshold_failures"] = _dedup_strings(out.get("threshold_failures", []) as Array, options.get("threshold_failures", []) as Array)
	out["raw_outputs"] = _as_dict(options.get("raw_outputs", out.get("raw_outputs", {})))
	out["baseline"] = _as_dict(options.get("baseline", out.get("baseline", {})))
	out["comparison"] = _as_dict(options.get("comparison", out.get("comparison", {})))
	var renderer := _renderer_info()
	out["renderer"] = renderer
	out["headless"] = bool(OS.has_feature("headless") or str(renderer.get("display_server", "")).to_lower() == "headless")
	out["git_commit"] = _git_output(["rev-parse", "HEAD"])
	out["worktree_dirty"] = _git_dirty()
	return out


static func _as_dict(value: Variant) -> Dictionary:
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	return {}


static func _dedup_strings(a: Array, b: Array = []) -> Array[String]:
	var out: Array[String] = []
	for list in [a, b]:
		for value in list:
			var text := str(value)
			if not text.is_empty() and not out.has(text):
				out.append(text)
	return out


static func _renderer_info() -> Dictionary:
	return {
		"method": str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "unknown")),
		"display_server": DisplayServer.get_name(),
	}


static func _git_output(args: Array[String]) -> String:
	var root := ProjectSettings.globalize_path("res://")
	var packed := PackedStringArray(["-C", root])
	for arg in args:
		packed.append(arg)
	var output: Array = []
	var code := OS.execute("git", packed, output, true, false)
	if code != 0 or output.is_empty():
		return ""
	return str(output[0]).strip_edges()


static func _git_dirty() -> Variant:
	var status := _git_output(["status", "--porcelain"])
	if status.is_empty():
		var head := _git_output(["rev-parse", "HEAD"])
		return null if head.is_empty() else false
	return true
