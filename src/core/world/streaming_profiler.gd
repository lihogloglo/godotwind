## StreamingProfiler - Per-subsystem timing for world streaming pipeline
##
## Tracks frame-by-frame performance of each streaming component to identify bottlenecks.
## Minimal overhead design - uses simple start/end timing pairs.
##
## Usage:
##   var profiler := StreamingProfiler.new()
##   profiler.begin_frame()
##
##   profiler.begin_section("NativeStreamingManager.update")
##   native_streaming_manager.update(camera_pos, delta)
##   profiler.end_section("NativeStreamingManager.update")
##
##   profiler.end_frame()
##   print(profiler.get_formatted_report())
class_name StreamingProfiler
extends RefCounted

## Section timing data
class SectionTiming extends RefCounted:
	var name: String
	var current_start_usec: int = 0
	var last_duration_usec: int = 0
	var total_duration_usec: int = 0
	var call_count: int = 0
	var max_duration_usec: int = 0
	var min_duration_usec: int = 999999999
	## Frame number at which last_duration_usec was last updated. Used by
	## dump_overrun_breakdown to filter sections that fired in the current
	## frame vs sections whose last value is stale from an earlier frame.
	var last_fired_frame: int = -1

	## Rolling average over last N frames
	var history: Array[int] = []
	var history_size: int = 60

## All tracked sections
var _sections: Dictionary = {}  # name -> SectionTiming

## Frame timing
var _frame_start_usec: int = 0
var _frame_duration_usec: int = 0
var _frame_count: int = 0

## Frame history for percentiles
var _frame_history: Array[int] = []
var _frame_history_size: int = 120

## Custom metrics (for object counts, etc.)
var _metrics: Dictionary = {}  # name -> value

## Enable/disable profiling (minimal overhead when disabled)
var enabled: bool = true


## Begin timing a new frame
func begin_frame() -> void:
	if not enabled:
		return
	_frame_start_usec = Time.get_ticks_usec()


## End frame timing
func end_frame() -> void:
	if not enabled:
		return

	_frame_duration_usec = Time.get_ticks_usec() - _frame_start_usec
	_frame_count += 1

	# Add to history
	_frame_history.append(_frame_duration_usec)
	if _frame_history.size() > _frame_history_size:
		_frame_history.pop_front()


## Begin timing a section
func begin_section(section_name: String) -> void:
	if not enabled:
		return

	var section: SectionTiming
	if section_name in _sections:
		section = _sections[section_name]
	else:
		section = SectionTiming.new()
		section.name = section_name
		_sections[section_name] = section

	section.current_start_usec = Time.get_ticks_usec()


## End timing a section
func end_section(section_name: String) -> void:
	if not enabled:
		return

	if section_name not in _sections:
		push_warning("[StreamingProfiler] end_section called without begin_section: %s" % section_name)
		return

	var section: SectionTiming = _sections[section_name]
	var duration := Time.get_ticks_usec() - section.current_start_usec

	section.last_duration_usec = duration
	section.total_duration_usec += duration
	section.call_count += 1
	section.last_fired_frame = _frame_count

	if duration > section.max_duration_usec:
		section.max_duration_usec = duration
	if duration < section.min_duration_usec:
		section.min_duration_usec = duration

	# Rolling history
	section.history.append(duration)
	if section.history.size() > section.history_size:
		section.history.pop_front()


## Record a custom metric (object count, queue size, etc.)
func record_metric(name: String, value: float) -> void:
	_metrics[name] = value


## Get last frame duration in milliseconds
func get_frame_time_ms() -> float:
	return _frame_duration_usec / 1000.0


## Get section timing in milliseconds
func get_section_time_ms(section_name: String) -> float:
	if section_name not in _sections:
		return 0.0
	var section: SectionTiming = _sections[section_name]
	return section.last_duration_usec / 1000.0


## Get average section time over history
func get_section_avg_ms(section_name: String) -> float:
	if section_name not in _sections:
		return 0.0
	var section: SectionTiming = _sections[section_name]
	if section.history.is_empty():
		return 0.0

	var sum := 0
	for t in section.history:
		sum += t
	return (sum / section.history.size()) / 1000.0


## Get frame time percentiles
func get_frame_percentiles() -> Dictionary:
	if _frame_history.is_empty():
		return {"p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0}

	var sorted := _frame_history.duplicate()
	sorted.sort()

	var p50_idx := int(sorted.size() * 0.50)
	var p95_idx := int(sorted.size() * 0.95)
	var p99_idx := int(sorted.size() * 0.99)

	return {
		"p50": sorted[p50_idx] / 1000.0,
		"p95": sorted[mini(p95_idx, sorted.size() - 1)] / 1000.0,
		"p99": sorted[mini(p99_idx, sorted.size() - 1)] / 1000.0,
		"max": sorted[-1] / 1000.0
	}


## Get all section data as dictionary
func get_all_sections() -> Dictionary:
	var result := {}
	for name: String in _sections:
		var section: SectionTiming = _sections[name]
		result[name] = {
			"last_ms": section.last_duration_usec / 1000.0,
			"avg_ms": get_section_avg_ms(name),
			"max_ms": section.max_duration_usec / 1000.0,
			"min_ms": section.min_duration_usec / 1000.0,
			"calls": section.call_count,
		}
	return result


## Get formatted report for display
func get_formatted_report() -> String:
	var lines: Array[String] = []
	lines.append("[b]Streaming Profiler[/b] (frame %d)" % _frame_count)
	lines.append("")

	# Frame timing
	var percs := get_frame_percentiles()
	var fps := 1000.0 / maxf(percs.p50, 0.001)
	lines.append("[b]Frame:[/b] %.1f FPS (%.2f ms p50, %.2f ms p95, %.2f ms max)" % [
		fps, percs.p50, percs.p95, percs.max
	])
	lines.append("")

	# Section breakdown - sorted by last time descending
	var section_list: Array = []
	for name: String in _sections:
		var section: SectionTiming = _sections[name]
		section_list.append({
			"name": name,
			"last_ms": section.last_duration_usec / 1000.0,
			"avg_ms": get_section_avg_ms(name),
			"max_ms": section.max_duration_usec / 1000.0,
		})

	section_list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.last_ms > b.last_ms
	)

	lines.append("[b]Sections:[/b]")
	for s: Dictionary in section_list:
		var bar := _make_bar(s.last_ms, 50.0)  # 50ms = full bar
		var flag := " [color=red]◀[/color]" if s.last_ms > 16.0 else ""
		lines.append("  %s %5.1f ms (avg %.1f, max %.1f)%s" % [
			bar, s.last_ms, s.avg_ms, s.max_ms, flag
		])
		lines.append("    %s" % s.name)

	# Custom metrics
	if not _metrics.is_empty():
		lines.append("")
		lines.append("[b]Metrics:[/b]")
		for name: String in _metrics:
			lines.append("  %s: %s" % [name, str(_metrics[name])])

	return "\n".join(lines)


## Get compact one-line summary
func get_compact_summary() -> String:
	var percs := get_frame_percentiles()
	var fps := 1000.0 / maxf(percs.p50, 0.001)

	# Find slowest section
	var slowest_name := ""
	var slowest_ms := 0.0
	for name: String in _sections:
		var section: SectionTiming = _sections[name]
		var ms := section.last_duration_usec / 1000.0
		if ms > slowest_ms:
			slowest_ms = ms
			slowest_name = name

	return "%.0f FPS | slowest: %s (%.1fms)" % [fps, slowest_name, slowest_ms]


## Create a visual bar for timing
func _make_bar(value_ms: float, max_ms: float) -> String:
	var width := 10
	var filled := int(clampf(value_ms / max_ms, 0.0, 1.0) * width)
	var empty := width - filled

	var bar := ""
	for i in range(filled):
		bar += "█"
	for i in range(empty):
		bar += "░"

	return "[" + bar + "]"


## Reset all timing data
func reset() -> void:
	_sections.clear()
	_frame_history.clear()
	_metrics.clear()
	_frame_count = 0


## Get raw data for external analysis
func get_raw_data() -> Dictionary:
	return {
		"frame_count": _frame_count,
		"frame_duration_usec": _frame_duration_usec,
		"frame_history": _frame_history.duplicate(),
		"sections": get_all_sections(),
		"metrics": _metrics.duplicate(),
	}


## Slow-frame autopsy. When the LAST frame exceeded `threshold_ms`, dump a
## per-section breakdown of THAT frame (not aggregated) to the log.
##
## Designed to answer "where did the 1100 ms spike actually go?" without
## requiring a hypothesis up front. Sections sorted by last-frame duration
## descending; top 8 emitted with attributed/unattributed totals.
##
## Caller is expected to invoke this AFTER end_frame() at the bottom of
## the per-frame loop. Cheap when the threshold is not hit (one float compare).
##
## `source` is appended to the log line so caller can identify the call site
## (e.g. "stream_proc"). Empty string skips it.
##
## Plan: docs/plans/distant_rendering_2026_04/cell_transition_stutter_phase2.md §11.4.
func dump_overrun_breakdown(threshold_ms: float, source: String = "") -> void:
	if not enabled:
		return
	var frame_ms: float = _frame_duration_usec / 1000.0
	if frame_ms < threshold_ms:
		return

	# Collect sections that FIRED THIS FRAME (last_fired_frame == current).
	# Sections that didn't run this frame stay quiet — they aren't suspects.
	# end_frame() incremented _frame_count first, so "this frame" is _frame_count - 1.
	var current_frame: int = _frame_count - 1
	var fired: Array = []
	for section_name: String in _sections:
		var s: SectionTiming = _sections[section_name]
		if s.last_fired_frame == current_frame:
			fired.append([section_name, s.last_duration_usec])

	# Sort by duration desc.
	fired.sort_custom(func(a: Array, b: Array) -> bool:
		return (a[1] as int) > (b[1] as int))

	var top: Array = fired.slice(0, 8)
	var parts: PackedStringArray = PackedStringArray()
	for entry: Array in top:
		var name_str: String = entry[0]
		var dur_usec: int = entry[1]
		parts.append("%s=%.1f" % [name_str, dur_usec / 1000.0])
	# Sum ALL fired sections (not just top 8) for accurate unattributed.
	var total_attributed_usec: int = 0
	for entry: Array in fired:
		total_attributed_usec += int(entry[1])
	var unattributed_ms: float = frame_ms - (total_attributed_usec / 1000.0)

	var src_tag: String = (" " + source) if not source.is_empty() else ""
	Log.warn("autopsy", "[autopsy %.1fms%s] top: %s | sections_fired=%d unattributed=%.1fms" % [
		frame_ms, src_tag, ", ".join(parts), fired.size(), unattributed_ms,
	])
