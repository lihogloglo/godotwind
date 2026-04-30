## StreamingStressRunner - sustained high-altitude traversal stress test.
##
## CLI-owned runner for answering "does streaming survive fast cell transitions?"
## without the slow canonical AutoBench sequence.
class_name StreamingStressRunner
extends Node

const DU := preload("res://src/core/world/distance_utils.gd")

const OUTPUT_DIR_BASE := "user://benchmark_results"
const CSV_HEADERS := "frame,time_ms,fps,cam_x,cam_y,cam_z,cell_x,cell_y,cell_changed,queue_size,loaded_cells,async_requests,rendered_objects,draw_calls,primitives,stream_total_ms,phase_unload_us,phase_async_us,phase_inst_us,phase_promo_us,phase_coll_us,phase_defer_us,phase_queue_us,phase_cellupd_us,phase_static_cull_us,inst_door_us,inst_light_us,inst_light_modelload_us,inst_container_us,inst_activator_us,inst_static_us"

const SETTLE_SEC := 8.0
const TRANSITION_PRE_FRAMES := 30
const TRANSITION_POST_FRAMES := 120

const ROUTE_STRAIGHT_NAMES := {
	"east": true,
	"+x": true,
	"x": true,
	"west": true,
	"-x": true,
	"south": true,
	"+z": true,
	"z": true,
	"north": true,
	"-z": true,
	"diag": true,
	"diagonal": true,
	"ne": true,
}
const DENSE_LOOP_OFFSETS := [
	Vector2i(0, 0),
	Vector2i(1, 0),
	Vector2i(1, 1),
	Vector2i(0, 1),
	Vector2i(-1, 1),
	Vector2i(-1, 0),
	Vector2i(-1, -1),
	Vector2i(0, -1),
	Vector2i(1, -1),
]

var _streaming_manager: Node = null
var _cell_manager: Variant = null
var _camera: Camera3D = null
var _stamp := ""
var _start_cell := Vector2i.ZERO
var _altitude_m := 100.0
var _speed_mps := 100.0
var _duration_s := 60.0
var _direction := Vector3(1, 0, 0)
var _route_name := "dense-loop"
var _route_mode := "loop"
var _route_points: Array[Vector3] = []
var _route_cells: Array[Vector2i] = []
var _route_cell_ref_counts: Dictionary = {}
var _route_total_length := 0.0
var _route_min := Vector3.ZERO
var _route_max := Vector3.ZERO

var _phase := "settle"
var _elapsed := 0.0
var _started_msec := 0
var _start_pos := Vector3.ZERO
var _last_cell := Vector2i.ZERO

var _rows: Array[PackedFloat64Array] = []
var _events: Array[Dictionary] = []
var _transitions: Array[Dictionary] = []


func configure(
	streaming_manager: Node,
	cell_manager: Variant,
	camera: Camera3D,
	stamp: String,
	start_cell: Vector2i,
	altitude_m: float,
	speed_mps: float,
	duration_s: float,
	direction_name: String
) -> void:
	_streaming_manager = streaming_manager
	_cell_manager = cell_manager
	_camera = camera
	_stamp = stamp if not stamp.is_empty() else Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	_start_cell = start_cell
	_altitude_m = altitude_m
	_speed_mps = speed_mps
	_duration_s = duration_s
	_route_name = direction_name if not direction_name.is_empty() else "dense-loop"
	_started_msec = Time.get_ticks_msec()

	_configure_route(_route_name)
	_start_pos = _route_points[0] if not _route_points.is_empty() else DU.cell_to_world_center(_start_cell, _altitude_m)
	_last_cell = DU.world_to_cell(_start_pos)
	if _camera:
		_camera.global_position = _start_pos
		_camera.look_at(_start_pos + _direction * 100.0 + Vector3(0, -20.0, 0))

	Log.info("tools", "[STRESS] configured stamp=%s route=%s mode=%s start_cell=%s start_world_cell=%s end_cell=%s altitude=%.1fm speed=%.1fm/s duration=%.1fs length=%.1fm bounds=%s..%s refs=%s" % [
		_stamp,
		_route_name,
		_route_mode,
		str(_start_cell),
		str(_last_cell),
		str(_route_cells[-1] if not _route_cells.is_empty() else _last_cell),
		_altitude_m,
		_speed_mps,
		_duration_s,
		_route_total_length,
		str(_route_min),
		str(_route_max),
		JSON.stringify(_route_cell_ref_counts),
	])


func _process(delta: float) -> void:
	if not _camera:
		return

	_elapsed += delta
	var cell_changed := false

	if _phase == "settle":
		_camera.global_position = _start_pos
		_camera.look_at(_start_pos + _direction * 100.0 + Vector3(0, -20.0, 0))
		if _elapsed >= SETTLE_SEC:
			_phase = "fly"
			_elapsed = 0.0
			_rows.clear()
			_events.clear()
			_transitions.clear()
			_start_pos = _camera.global_position
			_last_cell = DU.world_to_cell(_start_pos)
			Log.info("tools", "[STRESS] fly start cell=%s" % str(_last_cell))
	else:
		var route_sample := _sample_route(_speed_mps * _elapsed)
		_camera.global_position = route_sample.get("position", _start_pos)
		_direction = route_sample.get("direction", _direction)
		_camera.look_at(_camera.global_position + _direction * 100.0 + Vector3(0, -20.0, 0))
		var current_cell := DU.world_to_cell(_camera.global_position)
		if current_cell != _last_cell:
			cell_changed = true
			_record_transition(_last_cell, current_cell)
			_last_cell = current_cell
		if _elapsed >= _duration_s:
			_finish()
			return

	_log_frame(delta, cell_changed)


func _direction_from_name(name: String) -> Vector3:
	var n := name.to_lower()
	match n:
		"east", "+x", "x":
			return Vector3(1, 0, 0)
		"west", "-x":
			return Vector3(-1, 0, 0)
		"south", "+z", "z":
			return Vector3(0, 0, 1)
		"north", "-z":
			return Vector3(0, 0, -1)
		"diag", "diagonal", "ne":
			return Vector3(1, 0, -1).normalized()
		_:
			return Vector3(1, 0, 0)


func _configure_route(name: String) -> void:
	var n := name.to_lower().strip_edges()
	if ROUTE_STRAIGHT_NAMES.has(n):
		_route_mode = "straight"
		_direction = _direction_from_name(n)
		_route_points = [DU.cell_to_world_center(_start_cell, _altitude_m)]
		_route_cells = [_start_cell]
		_route_total_length = _speed_mps * _duration_s
		var end_pos := _route_points[0] + _direction * _route_total_length
		_route_min = Vector3(
			minf(_route_points[0].x, end_pos.x),
			minf(_route_points[0].y, end_pos.y),
			minf(_route_points[0].z, end_pos.z)
		)
		_route_max = Vector3(
			maxf(_route_points[0].x, end_pos.x),
			maxf(_route_points[0].y, end_pos.y),
			maxf(_route_points[0].z, end_pos.z)
		)
		_route_cell_ref_counts[str(_start_cell)] = _get_cell_ref_count(_start_cell)
		return

	_route_mode = "loop"
	_route_points.clear()
	_route_cells.clear()
	_route_cell_ref_counts.clear()
	for offset: Vector2i in DENSE_LOOP_OFFSETS:
		var cell := _start_cell + offset
		if not _cell_has_world_data(cell):
			continue
		_route_cells.append(cell)
		_route_points.append(DU.cell_to_world_center(cell, _altitude_m))
		_route_cell_ref_counts[str(cell)] = _get_cell_ref_count(cell)

	if _route_points.size() < 4:
		Log.warn("tools", "[STRESS] dense-loop had only %d valid points near %s; falling back to east straight route" % [
			_route_points.size(), str(_start_cell)
		])
		_route_mode = "straight"
		_direction = Vector3(1, 0, 0)
		_route_points = [DU.cell_to_world_center(_start_cell, _altitude_m)]
		_route_cells = [_start_cell]

	_recompute_route_bounds_and_length()


func _sample_route(distance_m: float) -> Dictionary:
	if _route_mode == "straight" or _route_points.size() < 2:
		return {
			"position": _start_pos + _direction * distance_m,
			"direction": _direction,
		}
	var wrapped := fposmod(distance_m, maxf(_route_total_length, 0.001))
	for i in range(_route_points.size()):
		var a := _route_points[i]
		var b := _route_points[(i + 1) % _route_points.size()]
		var seg := b - a
		var seg_len := seg.length()
		if seg_len <= 0.001:
			continue
		if wrapped <= seg_len:
			var t := wrapped / seg_len
			return {
				"position": a.lerp(b, t),
				"direction": seg / seg_len,
			}
		wrapped -= seg_len
	var last := _route_points[-1]
	var first := _route_points[0]
	var dir := (first - last).normalized()
	return {
		"position": last,
		"direction": dir if dir.length_squared() > 0.0 else Vector3(1, 0, 0),
	}


func _recompute_route_bounds_and_length() -> void:
	if _route_points.is_empty():
		_route_min = Vector3.ZERO
		_route_max = Vector3.ZERO
		_route_total_length = 0.0
		return
	_route_min = _route_points[0]
	_route_max = _route_points[0]
	_route_total_length = 0.0
	for i in range(_route_points.size()):
		var p := _route_points[i]
		_route_min = Vector3(minf(_route_min.x, p.x), minf(_route_min.y, p.y), minf(_route_min.z, p.z))
		_route_max = Vector3(maxf(_route_max.x, p.x), maxf(_route_max.y, p.y), maxf(_route_max.z, p.z))
		if _route_mode == "loop" and _route_points.size() > 1:
			_route_total_length += p.distance_to(_route_points[(i + 1) % _route_points.size()])
	if _route_mode == "straight":
		_route_total_length = _speed_mps * _duration_s
		var end_pos := _route_points[0] + _direction * _route_total_length
		_route_min = Vector3(minf(_route_min.x, end_pos.x), minf(_route_min.y, end_pos.y), minf(_route_min.z, end_pos.z))
		_route_max = Vector3(maxf(_route_max.x, end_pos.x), maxf(_route_max.y, end_pos.y), maxf(_route_max.z, end_pos.z))


func _cell_has_world_data(cell: Vector2i) -> bool:
	return ESMManager.get_exterior_cell(cell.x, cell.y) != null or ESMManager.get_land(cell.x, cell.y) != null


func _get_cell_ref_count(cell: Vector2i) -> int:
	var rec: CellRecord = ESMManager.get_exterior_cell(cell.x, cell.y)
	if rec == null:
		return 0
	return rec.references.size()


func _record_transition(from_cell: Vector2i, to_cell: Vector2i) -> void:
	var idx := _rows.size()
	_transitions.append({
		"row_index": idx,
		"frame": Engine.get_frames_drawn(),
		"elapsed_s": _elapsed,
		"from": "%s" % from_cell,
		"to": "%s" % to_cell,
	})
	_events.append({
		"frame": Engine.get_frames_drawn(),
		"elapsed_s": _elapsed,
		"event": "cell_transition",
		"detail": "%s -> %s" % [from_cell, to_cell],
	})
	Log.info("tools", "[STRESS] cell_transition %.2fs %s -> %s" % [_elapsed, str(from_cell), str(to_cell)])


func _log_frame(delta: float, cell_changed: bool) -> void:
	var row := PackedFloat64Array()
	row.resize(31)
	var cell := DU.world_to_cell(_camera.global_position)
	row[0] = float(Engine.get_frames_drawn())
	row[1] = delta * 1000.0
	row[2] = float(Engine.get_frames_per_second())
	row[3] = _camera.global_position.x
	row[4] = _camera.global_position.y
	row[5] = _camera.global_position.z
	row[6] = float(cell.x)
	row[7] = float(cell.y)
	row[8] = 1.0 if cell_changed else 0.0
	row[9] = float(_get_queue_size())
	row[10] = float(_get_loaded_cells())
	row[11] = float(_get_async_requests())
	row[12] = Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	row[13] = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	row[14] = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	if _streaming_manager:
		if _streaming_manager.has_method("get_frame_streaming_ms"):
			row[15] = float(_streaming_manager.call("get_frame_streaming_ms"))
		if _streaming_manager.has_method("get_phase_times"):
			var pt: PackedFloat64Array = _streaming_manager.call("get_phase_times")
			for i in range(mini(pt.size(), 9)):
				row[16 + i] = pt[i]
	if _cell_manager and _cell_manager.has_method("get_frame_inst_route_times"):
		var rt: Dictionary = _cell_manager.call("get_frame_inst_route_times")
		row[25] = float(rt.get("door", 0))
		row[26] = float(rt.get("light", 0))
		row[27] = float(rt.get("light_modelload", 0))
		row[28] = float(rt.get("container", 0))
		row[29] = float(rt.get("activator", 0))
		row[30] = float(rt.get("static", 0))
	_rows.append(row)


func _get_queue_size() -> int:
	if _cell_manager and _cell_manager.has_method("get_instantiation_queue_size"):
		return int(_cell_manager.call("get_instantiation_queue_size"))
	return 0


func _get_loaded_cells() -> int:
	if _streaming_manager and _streaming_manager.has_method("get_stats"):
		var stats: Dictionary = _streaming_manager.call("get_stats")
		return int(stats.get("loaded_cells", 0))
	return 0


func _get_async_requests() -> int:
	if _streaming_manager and _streaming_manager.has_method("get_stats"):
		var stats: Dictionary = _streaming_manager.call("get_stats")
		return int(stats.get("async_requests", 0))
	return 0


func _finish() -> void:
	set_process(false)
	var summary := _build_summary()
	var csv_path := _write_csv()
	var events_path := _write_events_csv()
	var json_path := _write_summary_json(summary, csv_path, events_path)
	Log.info("tools", "[STRESS] complete summary=%s csv=%s json=%s" % [
		JSON.stringify(summary), csv_path, json_path
	])
	get_tree().create_timer(1.0).timeout.connect(func() -> void:
		_quit_cleanly()
	)


func _quit_cleanly() -> void:
	Log.info("shutdown", "BENCH_QUIT - stress runner complete, graceful tree quit")
	if _streaming_manager != null:
		_streaming_manager.set_process(false)
	get_tree().quit()


func _build_summary() -> Dictionary:
	var total := _rows.size()
	if total == 0:
		return {"frames": 0}

	var frame_times: Array[float] = []
	var total_ms := 0.0
	var max_ms := 0.0
	var frames_over_16 := 0
	var frames_over_33 := 0
	var frames_over_50 := 0
	var min_rendered := INF
	var max_rendered := 0.0
	var min_loaded := INF
	var max_loaded := 0.0
	var max_queue := 0.0
	var max_stream := 0.0
	var max_inst_ms := 0.0
	var max_static_cull_ms := 0.0
	for row in _rows:
		var ms := row[1]
		frame_times.append(ms)
		total_ms += ms
		max_ms = maxf(max_ms, ms)
		if ms > 16.67:
			frames_over_16 += 1
		if ms > 33.33:
			frames_over_33 += 1
		if ms > 50.0:
			frames_over_50 += 1
		min_rendered = minf(min_rendered, row[12])
		max_rendered = maxf(max_rendered, row[12])
		min_loaded = minf(min_loaded, row[10])
		max_loaded = maxf(max_loaded, row[10])
		max_queue = maxf(max_queue, row[9])
		max_stream = maxf(max_stream, row[15])
		max_inst_ms = maxf(max_inst_ms, row[18] / 1000.0)
		max_static_cull_ms = maxf(max_static_cull_ms, row[24] / 1000.0)
	frame_times.sort()

	var transitions := _build_transition_summaries()
	var worst_transition_ms := 0.0
	var worst_drop_fps := 0.0
	for t in transitions:
		worst_transition_ms = maxf(worst_transition_ms, float(t.get("post_max_ms", 0.0)))
		worst_drop_fps = maxf(worst_drop_fps, float(t.get("drop_fps", 0.0)))

	return {
		"stamp": _stamp,
		"route": _route_name,
		"route_mode": _route_mode,
		"route_cells": _route_cells_as_strings(),
		"route_cell_ref_counts": _route_cell_ref_counts,
		"route_length_m": _route_total_length,
		"route_bounds_min": str(_route_min),
		"route_bounds_max": str(_route_max),
		"start_cell": str(_start_cell),
		"altitude_m": _altitude_m,
		"speed_mps": _speed_mps,
		"speed_kmh": _speed_mps * 3.6,
		"duration_s": _duration_s,
		"frames": total,
		"avg_ms": total_ms / float(total),
		"avg_fps": 1000.0 / maxf(total_ms / float(total), 0.001),
		"p95_ms": frame_times[int(float(total) * 0.95)],
		"p99_ms": frame_times[int(float(total) * 0.99)],
		"p99_9_ms": frame_times[mini(total - 1, int(float(total) * 0.999))],
		"max_ms": max_ms,
		"frames_over_16_67": frames_over_16,
		"frames_over_33_33": frames_over_33,
		"frames_over_50": frames_over_50,
		"cell_transitions": transitions.size(),
		"worst_transition_post_max_ms": worst_transition_ms,
		"worst_transition_drop_fps": worst_drop_fps,
		"min_rendered_objects": int(min_rendered),
		"max_rendered_objects": int(max_rendered),
		"min_loaded_cells": int(min_loaded),
		"max_loaded_cells": int(max_loaded),
		"max_queue_size": int(max_queue),
		"max_stream_total_ms": max_stream,
		"max_phase_inst_ms": max_inst_ms,
		"max_phase_static_cull_ms": max_static_cull_ms,
		"transitions": transitions,
	}


func _build_transition_summaries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for t in _transitions:
		var idx := int(t.get("row_index", 0))
		var pre_start := maxi(0, idx - TRANSITION_PRE_FRAMES)
		var pre_end := maxi(pre_start, idx)
		var post_end := mini(_rows.size(), idx + TRANSITION_POST_FRAMES)
		var pre_avg_ms := _avg_ms(pre_start, pre_end)
		var post_avg_ms := _avg_ms(idx, post_end)
		var post_max_ms := _max_ms(idx, post_end)
		var post_max_queue := _max_value(idx, post_end, 9)
		var post_min_loaded := _min_value(idx, post_end, 10)
		var post_min_rendered := _min_value(idx, post_end, 12)
		var pre_fps := 1000.0 / maxf(pre_avg_ms, 0.001)
		var post_fps := 1000.0 / maxf(post_avg_ms, 0.001)
		var post_min_fps := 1000.0 / maxf(post_max_ms, 0.001)
		var stutter_frames_16 := _count_over_ms(idx, post_end, 16.67)
		var stutter_frames := _count_over_ms(idx, post_end, 33.33)
		var stutter_frames_50 := _count_over_ms(idx, post_end, 50.0)
		var copy := t.duplicate()
		copy["pre_avg_fps"] = pre_fps
		copy["post_avg_fps"] = post_fps
		copy["post_min_fps"] = post_min_fps
		copy["drop_fps"] = maxf(0.0, pre_fps - post_min_fps)
		copy["post_max_ms"] = post_max_ms
		copy["post_frames_over_16_67"] = stutter_frames_16
		copy["post_frames_over_33_33"] = stutter_frames
		copy["post_frames_over_50"] = stutter_frames_50
		copy["post_max_queue_size"] = int(post_max_queue)
		copy["post_min_loaded_cells"] = int(post_min_loaded)
		copy["post_min_rendered_objects"] = int(post_min_rendered)
		out.append(copy)
	return out


func _route_cells_as_strings() -> Array[String]:
	var out: Array[String] = []
	for cell: Vector2i in _route_cells:
		out.append(str(cell))
	return out


func _avg_ms(start: int, end: int) -> float:
	if end <= start:
		return 0.0
	var sum := 0.0
	for i in range(start, end):
		sum += _rows[i][1]
	return sum / float(end - start)


func _max_ms(start: int, end: int) -> float:
	var m := 0.0
	for i in range(start, end):
		m = maxf(m, _rows[i][1])
	return m


func _max_value(start: int, end: int, column: int) -> float:
	var m := 0.0
	for i in range(start, end):
		m = maxf(m, _rows[i][column])
	return m


func _min_value(start: int, end: int, column: int) -> float:
	if end <= start:
		return 0.0
	var m := INF
	for i in range(start, end):
		m = minf(m, _rows[i][column])
	return m


func _count_over_ms(start: int, end: int, threshold: float) -> int:
	var count := 0
	for i in range(start, end):
		if _rows[i][1] > threshold:
			count += 1
	return count


func _write_csv() -> String:
	var dir_path := OUTPUT_DIR_BASE
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)
	var path := "%s/stress_%s.csv" % [dir_path, _stamp]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return ""
	file.store_line(CSV_HEADERS)
	for row in _rows:
		var parts: PackedStringArray = PackedStringArray()
		for v in row:
			parts.append("%.3f" % v)
		file.store_line(",".join(parts))
	file.close()
	return path


func _write_events_csv() -> String:
	var dir_path := OUTPUT_DIR_BASE
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)
	var path := "%s/stress_events_%s.csv" % [dir_path, _stamp]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return ""
	file.store_line("frame,elapsed_s,event,detail")
	for event in _events:
		file.store_line("%d,%.3f,%s,%s" % [
			int(event.get("frame", 0)),
			float(event.get("elapsed_s", 0.0)),
			str(event.get("event", "")),
			str(event.get("detail", "")).replace(",", ";"),
		])
	file.close()
	return path


func _write_summary_json(summary: Dictionary, csv_path: String, events_path: String) -> String:
	var dir_path := OUTPUT_DIR_BASE
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)
	var path := "%s/stress_summary_%s.json" % [dir_path, _stamp]
	var out := summary.duplicate()
	out["csv"] = csv_path
	out["events_csv"] = events_path
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return ""
	file.store_string(JSON.stringify(out, "\t"))
	file.close()
	return path
