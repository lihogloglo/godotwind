## PrewaterRenderTimingEffect
##
## Lightweight timestamp marker for a PrewaterCaptureRenderer SubViewport.
## A PRE_OPAQUE marker paired with a POST_TRANSPARENT marker measures the
## capture viewport's scene-render window before the copy pass runs.
@tool
class_name PrewaterRenderTimingEffect
extends PostProcessEffect

const TimestampTimingUtilsScript := preload("res://src/core/shaders/timestamp_timing_utils.gd")
const MAX_REASONABLE_TIMESTAMP_MS := 1000.0

var marker_name: String = ""
var pair_begin_name: String = ""
var pair_end_name: String = ""
var timing_marker_scope: String = "global"

var _last_perf_frame: int = -1
var _last_perf_snapshot: Dictionary = {
	"source_render_ms": -1.0,
	"frame": -1,
	"timing_valid": false,
	"timing_available": false,
	"timing_scope": "unavailable",
}


func _init() -> void:
	super._init()
	effect_name = "prewater_render_timing"
	display_name = "Prewater Render Timing"
	description = "Marks the source SubViewport render window for water refraction telemetry."
	category = "Water"
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = false
	access_resolved_depth = false
	needs_depth = false


func configure(
		p_marker_name: String,
		p_callback_type: int,
		p_pair_begin_name: String,
		p_pair_end_name: String,
		p_timing_marker_scope: String = "global"
) -> void:
	marker_name = p_marker_name
	pair_begin_name = p_pair_begin_name
	pair_end_name = p_pair_end_name
	timing_marker_scope = p_timing_marker_scope
	effect_callback_type = p_callback_type


func on_effect_added() -> void:
	rd = RenderingServer.get_rendering_device()


func _render_callback(p_effect_callback_type: int, _render_data: RenderData) -> void:
	if p_effect_callback_type != effect_callback_type:
		return
	if not effect_enabled:
		return
	if rd == null:
		rd = RenderingServer.get_rendering_device()
		if rd == null:
			return
	if marker_name.is_empty():
		return
	rd.capture_timestamp(marker_name)


func get_render_timing_snapshot() -> Dictionary:
	_refresh_timestamp_snapshot()
	return _last_perf_snapshot.duplicate()


func _refresh_timestamp_snapshot() -> void:
	if rd == null:
		rd = RenderingServer.get_rendering_device()
		if rd == null:
			return
	var frame := rd.get_captured_timestamps_frame()
	if frame == _last_perf_frame:
		return
	_last_perf_frame = frame

	var timing_available := rd.get_captured_timestamps_count() > 0
	var render_ms := _timestamp_pair_delta_ms(pair_begin_name, pair_end_name)
	var timing_valid := render_ms >= 0.0
	_last_perf_snapshot = {
		"source_render_ms": maxf(render_ms, 0.0) if timing_valid else -1.0,
		"frame": frame,
		"timing_valid": timing_valid,
		"timing_available": timing_available,
		"timing_scope": "pre_opaque_to_post_transparent",
		"timing_marker_scope": timing_marker_scope,
		"timing_marker_begin": pair_begin_name,
		"timing_marker_end": pair_end_name,
	}


func _timestamp_pair_delta_ms(begin_name: String, end_name: String) -> float:
	if rd == null or begin_name.is_empty() or end_name.is_empty():
		return -1.0
	var begin_times: Array[int] = []
	var end_times: Array[int] = []
	var begin_cpu_times: Array[int] = []
	var end_cpu_times: Array[int] = []
	var last_valid_ms := -1.0
	var count := rd.get_captured_timestamps_count()
	for i: int in count:
		var name := rd.get_captured_timestamp_name(i)
		if name == begin_name:
			begin_times.append(rd.get_captured_timestamp_gpu_time(i))
			begin_cpu_times.append(rd.get_captured_timestamp_cpu_time(i))
		elif name == end_name:
			end_times.append(rd.get_captured_timestamp_gpu_time(i))
			end_cpu_times.append(rd.get_captured_timestamp_cpu_time(i))
	for begin_index: int in begin_times.size():
		for end_index: int in end_times.size():
			var gpu_ms := TimestampTimingUtilsScript.choose_delta_ms(
				begin_times[begin_index],
				end_times[end_index],
				MAX_REASONABLE_TIMESTAMP_MS,
				begin_cpu_times[begin_index],
				end_cpu_times[end_index]
			)
			if _timestamp_delta_is_plausible(gpu_ms):
				last_valid_ms = gpu_ms
	return last_valid_ms


func _timestamp_delta_is_plausible(gpu_ms: float) -> bool:
	return gpu_ms >= 0.0 and gpu_ms <= MAX_REASONABLE_TIMESTAMP_MS

