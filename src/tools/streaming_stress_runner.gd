## StreamingStressRunner - sustained high-altitude traversal stress test.
##
## CLI-owned runner for answering "does streaming survive fast cell transitions?"
## without the slow canonical AutoBench sequence.
class_name StreamingStressRunner
extends Node

const DU := preload("res://src/core/world/distance_utils.gd")
const ObjectPaging := preload("res://src/core/world/object_paging.gd")
const BT := preload("res://tests/benchmark/benchmark_thresholds.gd")

const OUTPUT_DIR_BASE := "user://benchmark_results"
const CSV_HEADERS := "frame,time_ms,fps,cam_x,cam_y,cam_z,cell_x,cell_y,cell_changed,queue_size,loaded_cells,async_requests,rendered_objects,draw_calls,primitives,stream_total_ms,phase_unload_us,phase_async_us,phase_inst_us,phase_promo_us,phase_coll_us,phase_defer_us,phase_queue_us,phase_cellupd_us,phase_static_cull_us,inst_door_us,inst_light_us,inst_light_modelload_us,inst_container_us,inst_activator_us,inst_static_us,total_impostors,far_pending_cells,far_texture_layers,far_texture_upload_us,far_normal_upload_us,far_multimesh_pack_us,far_multimesh_upload_us,far_cell_scan_us,far_page_count,far_dirty_page_count,far_pages_rebuilt,far_uploaded_instances,mid_instances,mid_visible,mid_buckets,mid_draw_groups,hlod_cells,hlod_pending,hlod_chunk_surfaces,hlod_chunk_materials,hlod_stale_completions,hlod_merge_queue_us,hlod_completion_us,hlod_desired_chunks,hlod_merge_queue_chunks,hlod_preparing_chunks,hlod_negative_chunks,hlod_active_visual_chunks,hlod_visual_begin_m,handoff_mid_hlod_overlap_chunks,hlod_nonvisual_suppressed,far_visibility_begin_m,handoff_far_hlod_overlap_chunks,handoff_hole_risk_chunks,far_hlod_covered_pages,far_hlod_uncovered_pages,far_hlod_covered_impostors,far_hlod_page_overrides,hlod_active_covered_refs,hlod_active_covered_cells,hlod_complete_coverage_chunks,hlod_incomplete_coverage_chunks,mid_mesh_types,hlod_enabled,hlod_initialized,hlod_cache_mb,hlod_chunks_tier_0,hlod_chunks_tier_1,hlod_chunks_tier_2"

const SETTLE_SEC := 8.0
const TRANSITION_PRE_FRAMES := 30
const TRANSITION_POST_FRAMES := 120
const BOOMERANG_DISTANCE_M := 360.0
const BLOCKING_FRAME_MS := BT.BLOCKING_FRAME_MS
const STREAMING_PUBLISH_BLOCKING_MS := BT.STREAMING_PUBLISH_BLOCKING_MS
const STATIC_PUBLISH_SPIKE_MS := BT.STATIC_PUBLISH_SPIKE_MS
const FAR_CELL_SCAN_SPIKE_MS := BT.SPIKE_FRAME_MS

## Step 2a: known-bad tokens scanned in the Godot user log at finish time.
## Hits flip the run status to "failed" and produce a non-zero process exit
## intent (Windows quit-time crashes can mask the OS exit code; the JSON
## summary is the authoritative pass/fail signal for harnesses).
## Per docs/systems/streaming_rendering_bible.md "Parked vs Blocking Failures".
##
## Tokens are anchored to the actual error pattern (`ERROR:` or `SCRIPT ERROR`
## prefix) so headless stack-trace `at:` lines and the runner's own echoed
## summary do not register as failures.
const FAILURE_TOKENS: Array[String] = [
	"SCRIPT ERROR",
	"Parse Error",
	"Compile Error",
	"ERROR: material_set_shader",
	"stale bucket",
	"Failed to load script",
	"ERROR: CellStaticCollision.finalize_body",
	"[static-prepare-spike",
]
## Cap how much of the log we scan. The log can grow large during long
## sessions; we only care about lines written during this stress run.
const LOG_SCAN_MAX_BYTES: int = 8 * 1024 * 1024  # 8 MiB

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
const ROUTE_BOOMERANG_NAMES := {
	"boomerang": true,
	"reclaim-boomerang": true,
	"p04-reclaim": true,
}
const ROUTE_DENSE_LOOP_NAMES := {
	"dense": true,
	"dense-loop": true,
	"loop": true,
}
const ROUTE_LANDSCAPE_NAMES := {
	"landscape": true,
	"landscape-broad": true,
	"broad-landscape": true,
	"hlod-landscape": true,
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
const LANDSCAPE_ROUTE_RADIUS_CELLS := 8
const LANDSCAPE_ROUTE_MIN_POINTS := 12
const LANDSCAPE_ROUTE_MAX_POINTS := 96

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
var _route_setup_failures: Array[String] = []
var _route_total_length := 0.0
var _route_min := Vector3.ZERO
var _route_max := Vector3.ZERO
var _expect_reclaim_cell_event := false
var _expect_reclaim_rejected_event := false
var _route_forced_hlod := false

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
	direction_name: String,
	limbo_hold_frames: int = 0,
	destructive_hold_frames: int = 0
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
	var route_key := _route_name.to_lower().strip_edges()
	_expect_reclaim_cell_event = ROUTE_BOOMERANG_NAMES.has(route_key) and limbo_hold_frames > 0
	_expect_reclaim_rejected_event = ROUTE_BOOMERANG_NAMES.has(route_key) and destructive_hold_frames > 0

	_configure_route(_route_name)
	if ROUTE_LANDSCAPE_NAMES.has(route_key) and _streaming_manager and _streaming_manager.has_method("set_hlod_visible"):
		_streaming_manager.call("set_hlod_visible", true)
		_route_forced_hlod = true
		Log.info("tools", "[STRESS] landscape route enabling HLOD via public API")
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
	_route_setup_failures.clear()
	_route_cell_ref_counts.clear()
	if ROUTE_BOOMERANG_NAMES.has(n):
		_route_mode = "path"
		_direction = Vector3(1, 0, 0)
		var start := DU.cell_to_world_center(_start_cell, _altitude_m)
		var turn := start + _direction * BOOMERANG_DISTANCE_M
		_route_points = [start, turn, start]
		_route_cells = [_start_cell, DU.world_to_cell(turn), _start_cell]
		_route_cell_ref_counts[str(_start_cell)] = _get_cell_ref_count(_start_cell)
		_route_cell_ref_counts[str(DU.world_to_cell(turn))] = _get_cell_ref_count(DU.world_to_cell(turn))
		_recompute_route_bounds_and_length()
		return
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
	if ROUTE_LANDSCAPE_NAMES.has(n):
		_configure_landscape_route()
		return
	if not ROUTE_DENSE_LOOP_NAMES.has(n):
		_route_setup_failures.append("unknown_route:%s" % name)

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
		_route_setup_failures.append("dense_loop_insufficient_points:%d" % _route_points.size())
		Log.warn("tools", "[STRESS] dense-loop had only %d valid points near %s; marking route invalid and falling back to east straight route" % [
			_route_points.size(), str(_start_cell)
		])
		_route_mode = "straight"
		_direction = Vector3(1, 0, 0)
		_route_points = [DU.cell_to_world_center(_start_cell, _altitude_m)]
		_route_cells = [_start_cell]

	_recompute_route_bounds_and_length()


func _configure_landscape_route() -> void:
	_route_mode = "path"
	_route_points.clear()
	_route_cells.clear()
	_route_cell_ref_counts.clear()
	for offset: Vector2i in _build_spiral_offsets(LANDSCAPE_ROUTE_RADIUS_CELLS):
		var cell := _start_cell + offset
		if not _cell_has_world_data(cell):
			continue
		_route_cells.append(cell)
		_route_points.append(DU.cell_to_world_center(cell, _altitude_m))
		_route_cell_ref_counts[str(cell)] = _get_cell_ref_count(cell)
		if _route_points.size() >= LANDSCAPE_ROUTE_MAX_POINTS:
			break

	if _route_points.size() < LANDSCAPE_ROUTE_MIN_POINTS:
		_route_setup_failures.append("landscape_insufficient_points:%d" % _route_points.size())
		Log.warn("tools", "[STRESS] landscape route had only %d valid points near %s; falling back to dense-loop shape" % [
			_route_points.size(), str(_start_cell)
		])
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

	_recompute_route_bounds_and_length()


func _build_spiral_offsets(radius: int) -> Array[Vector2i]:
	var offsets: Array[Vector2i] = [Vector2i.ZERO]
	var x := 0
	var y := 0
	var step_len := 1
	var directions: Array[Vector2i] = [
		Vector2i(1, 0),
		Vector2i(0, 1),
		Vector2i(-1, 0),
		Vector2i(0, -1),
	]
	while step_len <= radius * 2:
		for dir_idx in range(directions.size()):
			var dir := directions[dir_idx]
			for _i in range(step_len):
				x += dir.x
				y += dir.y
				if absi(x) <= radius and absi(y) <= radius:
					offsets.append(Vector2i(x, y))
			if dir_idx % 2 == 1:
				step_len += 1
	for yy in range(-radius, radius + 1):
		for xx in range(-radius, radius + 1):
			var offset := Vector2i(xx, yy)
			if not offsets.has(offset):
				offsets.append(offset)
	return offsets


func _sample_route(distance_m: float) -> Dictionary:
	if _route_mode == "straight" or _route_points.size() < 2:
		return {
			"position": _start_pos + _direction * distance_m,
			"direction": _direction,
		}
	if _route_mode == "path":
		var remaining := clampf(distance_m, 0.0, maxf(_route_total_length, 0.001))
		for i in range(_route_points.size() - 1):
			var a := _route_points[i]
			var b := _route_points[i + 1]
			var seg := b - a
			var seg_len := seg.length()
			if seg_len <= 0.001:
				continue
			if remaining <= seg_len:
				var t := remaining / seg_len
				return {
					"position": a.lerp(b, t),
					"direction": seg / seg_len,
				}
			remaining -= seg_len
		var last_dir := (_route_points[-1] - _route_points[-2]).normalized()
		return {
			"position": _route_points[-1],
			"direction": last_dir if last_dir.length_squared() > 0.0 else Vector3(1, 0, 0),
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
		elif _route_mode == "path" and i + 1 < _route_points.size():
			_route_total_length += p.distance_to(_route_points[i + 1])
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
	_drain_lifecycle_events()
	var row := PackedFloat64Array()
	row.resize(80)
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
		if _streaming_manager.has_method("get_stats"):
			var stats: Dictionary = _streaming_manager.call("get_stats")
			row[31] = float(stats.get("total_impostors", 0))
			row[32] = float(stats.get("pending_loads", 0))
			row[33] = float(stats.get("texture_array_layers", 0))
			row[34] = float(stats.get("far_texture_upload_us", 0))
			row[35] = float(stats.get("far_normal_upload_us", 0))
			row[36] = float(stats.get("far_multimesh_pack_us", 0))
			row[37] = float(stats.get("far_multimesh_upload_us", 0))
			row[38] = float(stats.get("far_cell_scan_us", 0))
			row[39] = float(stats.get("far_page_count", 0))
			row[40] = float(stats.get("far_dirty_page_count", 0))
			row[41] = float(stats.get("far_pages_rebuilt", 0))
			row[42] = float(stats.get("far_uploaded_instances", 0))
			row[43] = float(stats.get("mid_instances", 0))
			row[44] = float(stats.get("mid_visible", 0))
			row[73] = float(stats.get("mid_mesh_types", 0))
			row[75] = 1.0 if bool(stats.get("hlod_initialized", false)) else 0.0
			row[76] = float(stats.get("hlod_cache_mb", 0.0))
		if _streaming_manager.has_method("get_static_renderer_stats"):
			var sr_stats: Dictionary = _streaming_manager.call("get_static_renderer_stats")
			row[45] = float(sr_stats.get("cell_buckets", 0))
			row[46] = float(sr_stats.get("bucket_draw_groups", 0))
		if _streaming_manager.has_method("get_hlod_stats"):
			var hlod_stats: Dictionary = _streaming_manager.call("get_hlod_stats")
			row[47] = float(hlod_stats.get("active_cells", 0))
			row[48] = float(hlod_stats.get("pending_merges", 0))
			row[49] = float(hlod_stats.get("total_chunk_surfaces", 0))
			row[50] = float(hlod_stats.get("total_chunk_materials", 0))
			row[51] = float(hlod_stats.get("stale_completions_discarded", 0))
			row[52] = float(hlod_stats.get("merge_queue_last_usec", 0))
			row[53] = float(hlod_stats.get("completion_last_usec", 0))
			row[54] = float(hlod_stats.get("desired_chunks", 0))
			row[55] = float(hlod_stats.get("merge_queue_size", 0))
			row[56] = float(hlod_stats.get("preparing_chunks", 0))
			row[57] = float(hlod_stats.get("negative_chunks", 0))
			row[58] = float(hlod_stats.get("active_visual_chunks", 0))
			row[59] = float(hlod_stats.get("visual_begin_floor", 0.0))
			row[60] = float(hlod_stats.get("mid_hlod_overlap_chunks", 0))
			row[61] = float(hlod_stats.get("nonvisual_chunks_suppressed", 0))
			row[62] = float(hlod_stats.get("far_visibility_begin_m", 0.0))
			row[63] = float(hlod_stats.get("handoff_far_hlod_overlap_chunks", 0))
			row[64] = float(hlod_stats.get("handoff_hole_risk_chunks", 0))
			row[65] = float(hlod_stats.get("far_hlod_covered_pages", 0))
			row[66] = float(hlod_stats.get("far_hlod_uncovered_pages", 0))
			row[67] = float(hlod_stats.get("far_hlod_covered_impostors", 0))
			row[68] = float(hlod_stats.get("far_hlod_page_overrides", 0))
			row[69] = float(hlod_stats.get("active_covered_refs", 0))
			row[70] = float(hlod_stats.get("active_covered_cells", 0))
			row[71] = float(hlod_stats.get("active_complete_coverage_chunks", 0))
			row[72] = float(hlod_stats.get("active_incomplete_coverage_chunks", 0))
			row[74] = 1.0 if bool(hlod_stats.get("enabled", false)) else 0.0
			row[77] = float(hlod_stats.get("chunks_tier_0", 0))
			row[78] = float(hlod_stats.get("chunks_tier_1", 0))
			row[79] = float(hlod_stats.get("chunks_tier_2", 0))
	if _cell_manager and _cell_manager.has_method("get_frame_inst_route_times"):
		var rt: Dictionary = _cell_manager.call("get_frame_inst_route_times")
		row[25] = float(rt.get("door", 0))
		row[26] = float(rt.get("light", 0))
		row[27] = float(rt.get("light_modelload", 0))
		row[28] = float(rt.get("container", 0))
		row[29] = float(rt.get("activator", 0))
		row[30] = float(rt.get("static", 0))
	_rows.append(row)


func _drain_lifecycle_events() -> void:
	if _streaming_manager and _streaming_manager.has_method("consume_lifecycle_events"):
		var manager_events: Array = _streaming_manager.call("consume_lifecycle_events")
		for event: Dictionary in manager_events:
			_events.append(event)
	if _cell_manager and _cell_manager.has_method("consume_lifecycle_events"):
		var cell_events: Array = _cell_manager.call("consume_lifecycle_events")
		for event: Dictionary in cell_events:
			_events.append(event)


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
	_drain_lifecycle_events()
	var summary := _build_summary()
	# Step 2a: scan the user log for known-bad tokens. Hits flip the run
	# status to "failed" and propagate to the process exit code, so
	# automated harnesses can no longer mistake "wrote a CSV" for "passed".
	var failure_scan := _scan_log_for_failure_tokens()
	var failure_reasons := _collect_gate_failure_reasons(summary, failure_scan)
	summary["status"] = "passed" if failure_reasons.is_empty() else "failed"
	summary["failure_reasons"] = failure_reasons
	summary["log_scan_unverified"] = bool(failure_scan["unverified"])
	var csv_path := _write_csv()
	var events_path := _write_events_csv()
	var json_path := _write_summary_json(summary, csv_path, events_path)
	Log.info("tools", "[STRESS] complete summary=%s csv=%s json=%s" % [
		JSON.stringify(summary), csv_path, json_path
	])
	if summary["status"] == "failed":
		Log.error("tools", "[STRESS] FAILED — failure_reasons=%s" % JSON.stringify(summary["failure_reasons"]))
	var exit_code: int = 0 if summary["status"] == "passed" else 1
	get_tree().create_timer(1.0).timeout.connect(func() -> void:
		_quit_cleanly(exit_code)
	)


func _quit_cleanly(exit_code: int = 0) -> void:
	Log.info("shutdown", "BENCH_QUIT - stress runner complete, graceful tree quit (exit=%d)" % exit_code)
	Engine.set_meta("_quitting", true)
	if _streaming_manager != null:
		_streaming_manager.set_process(false)
		if _streaming_manager.has_method("fast_cleanup"):
			_streaming_manager.call("fast_cleanup")
	call_deferred("_finish_quit", exit_code)


func _finish_quit(exit_code: int) -> void:
	get_tree().quit(exit_code)


func _collect_gate_failure_reasons(summary: Dictionary, failure_scan: Dictionary) -> Array[String]:
	var reasons: Array[String] = []
	var scanned_reasons: Array = failure_scan.get("reasons", [])
	for reason_value in scanned_reasons:
		var reason := str(reason_value)
		if not reasons.has(reason):
			reasons.append(reason)
	if bool(failure_scan["unverified"]) and not reasons.has("log_scan_unverified"):
		reasons.append("log_scan_unverified")
	for route_failure: String in _route_setup_failures:
		var reason := "route_invalid:%s" % route_failure
		if not reasons.has(reason):
			reasons.append(reason)

	var lifecycle_counts: Dictionary = summary.get("lifecycle_event_counts", {})
	if _expect_reclaim_cell_event and int(lifecycle_counts.get("reclaim_cell", 0)) <= 0:
		reasons.append("reclaim_cell_missing")
	if _expect_reclaim_rejected_event:
		if int(lifecycle_counts.get("freeze_unload", 0)) <= 0:
			reasons.append("freeze_unload_missing")
		if int(lifecycle_counts.get("reclaim_rejected", 0)) <= 0:
			reasons.append("reclaim_rejected_missing")
		if int(lifecycle_counts.get("finalize_unloaded", 0)) <= 0:
			reasons.append("finalize_unloaded_missing")
	var frames_over_blocking := int(summary.get("frames_over_50", 0))
	if frames_over_blocking > 0:
		reasons.append("frames_over_50:%d" % frames_over_blocking)
	if summary.has("max_ms"):
		var max_frame_ms := float(summary.get("max_ms", 0.0))
		if max_frame_ms >= BLOCKING_FRAME_MS:
			reasons.append("max_frame_ms:%.1f" % max_frame_ms)
	if summary.has("max_stream_total_ms"):
		var max_stream_ms := float(summary.get("max_stream_total_ms", 0.0))
		if max_stream_ms >= STREAMING_PUBLISH_BLOCKING_MS:
			reasons.append("max_stream_total_ms:%.1f" % max_stream_ms)
	if summary.has("max_inst_static_ms"):
		var max_static_publish_ms := float(summary.get("max_inst_static_ms", 0.0))
		if max_static_publish_ms >= STATIC_PUBLISH_SPIKE_MS:
			reasons.append("max_static_publish_ms:%.1f" % max_static_publish_ms)
	if summary.has("max_far_cell_scan_ms"):
		var max_far_cell_scan_ms := float(summary.get("max_far_cell_scan_ms", 0.0))
		if max_far_cell_scan_ms >= FAR_CELL_SCAN_SPIKE_MS:
			reasons.append("max_far_cell_scan_ms:%.1f" % max_far_cell_scan_ms)
	if summary.has("handoff_max_hole_risk_chunks"):
		var hole_risk_chunks := int(summary.get("handoff_max_hole_risk_chunks", 0))
		if hole_risk_chunks > 0:
			reasons.append("handoff_hole_risk_chunks:%d" % hole_risk_chunks)
	if summary.has("max_hlod_merge_queue_ms"):
		var max_hlod_merge_ms := float(summary.get("max_hlod_merge_queue_ms", 0.0))
		if max_hlod_merge_ms > float(ObjectPaging.MERGE_QUEUE_BUDGET_USEC) / 1000.0:
			reasons.append("max_hlod_merge_queue_ms:%.1f" % max_hlod_merge_ms)
	if summary.has("max_hlod_completion_ms"):
		var max_hlod_completion_ms := float(summary.get("max_hlod_completion_ms", 0.0))
		if max_hlod_completion_ms > float(ObjectPaging.COMPLETION_BUDGET_USEC) / 1000.0:
			reasons.append("max_hlod_completion_ms:%.1f" % max_hlod_completion_ms)
	return reasons


## Step 2a: scan the Godot user log file for blocking-failure tokens written
## during this run. The user log is the canonical sink for `push_error` /
## `push_warning` / native engine errors that Log alone can't capture
## (SCRIPT ERROR, Compile Error, material_set_shader, etc.).
##
## Returns:
##   { "reasons": Array[String]  — token names that fired (deduped),
##     "unverified": bool        — true when the log file could not be read
##                                 (e.g. headless run with stdout redirected
##                                 elsewhere) — caller can decide to treat
##                                 unverified as a soft failure }
func _scan_log_for_failure_tokens() -> Dictionary:
	var result := {
		"reasons": [] as Array[String],
		"unverified": false,
	}
	var log_path := OS.get_user_data_dir() + "/logs/godot.log"
	if not FileAccess.file_exists(log_path):
		result["unverified"] = true
		return result
	var file := FileAccess.open(log_path, FileAccess.READ)
	if file == null:
		result["unverified"] = true
		return result
	var size := file.get_length()
	# Tail the last LOG_SCAN_MAX_BYTES so we focus on this run, not session
	# accumulation.
	if size > LOG_SCAN_MAX_BYTES:
		file.seek(size - LOG_SCAN_MAX_BYTES)
	var content := file.get_as_text()
	file.close()
	# Anchor scan to this run only — the log file is multi-run, so without an
	# anchor we'd flag tokens from prior sessions. Our stamp is unique per run
	# and appears in the `[STRESS] configured stamp=...` line emitted at start.
	if not _stamp.is_empty():
		var anchor := "[STRESS] configured stamp=" + _stamp
		var anchor_idx := content.find(anchor)
		if anchor_idx >= 0:
			content = content.substr(anchor_idx)
		else:
			# Stamp not found in tail — scan window may have rolled past this
			# run's start. Treat as unverified rather than flagging old tokens.
			result["unverified"] = true
			return result
	var hit_set := {}
	# Line-by-line so we can skip the runner's own echoed summary / FAILED log,
	# which would otherwise self-trigger (the summary line embeds failure_reasons
	# verbatim, and the FAILED line repeats the matched tokens).
	for line: String in content.split("\n"):
		if "[STRESS] complete summary=" in line:
			continue
		if "[STRESS] FAILED" in line:
			continue
		for token: String in FAILURE_TOKENS:
			if token in line:
				hit_set[token] = true
				break
	var reasons: Array[String] = []
	for token: String in hit_set.keys():
		reasons.append(token)
	result["reasons"] = reasons
	return result


func _build_summary() -> Dictionary:
	var total := _rows.size()
	if total == 0:
		return {
			"stamp": _stamp,
			"route": _route_name,
			"route_mode": _route_mode,
			"route_valid": _route_setup_failures.is_empty(),
			"route_setup_failures": _route_setup_failures.duplicate(),
			"route_forced_hlod": _route_forced_hlod,
			"blocking_frame_ms": BLOCKING_FRAME_MS,
			"frames": 0,
			"lifecycle_event_counts": _build_event_counts(),
		}

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
	var max_inst_static_ms := 0.0
	var max_total_impostors := 0.0
	var max_far_pending_cells := 0.0
	var max_far_texture_upload_ms := 0.0
	var max_far_normal_upload_ms := 0.0
	var max_far_multimesh_pack_ms := 0.0
	var max_far_multimesh_upload_ms := 0.0
	var max_far_cell_scan_ms := 0.0
	var max_far_page_count := 0.0
	var max_far_dirty_page_count := 0.0
	var max_far_pages_rebuilt := 0.0
	var max_far_uploaded_instances := 0.0
	var min_mid_visible := INF
	var max_mid_visible := 0.0
	var min_mid_instances := INF
	var max_mid_instances := 0.0
	var max_mid_buckets := 0.0
	var max_mid_draw_groups := 0.0
	var min_hlod_cells := INF
	var max_hlod_cells := 0.0
	var max_hlod_pending := 0.0
	var max_hlod_surfaces := 0.0
	var max_hlod_materials := 0.0
	var max_hlod_stale := 0.0
	var max_hlod_merge_queue_ms := 0.0
	var max_hlod_completion_ms := 0.0
	var max_hlod_desired := 0.0
	var max_hlod_merge_queue_chunks := 0.0
	var max_hlod_preparing := 0.0
	var max_hlod_negative := 0.0
	var min_hlod_active_visual := INF
	var max_hlod_active_visual := 0.0
	var max_handoff_mid_hlod_overlap := 0.0
	var max_hlod_nonvisual_suppressed := 0.0
	var min_far_visibility_begin := INF
	var max_far_visibility_begin := 0.0
	var max_handoff_far_hlod_overlap := 0.0
	var max_handoff_hole_risk := 0.0
	var max_far_hlod_covered_pages := 0.0
	var max_far_hlod_uncovered_pages := 0.0
	var max_far_hlod_covered_impostors := 0.0
	var max_far_hlod_page_overrides := 0.0
	var max_hlod_active_covered_refs := 0.0
	var max_hlod_active_covered_cells := 0.0
	var max_hlod_complete_coverage_chunks := 0.0
	var max_hlod_incomplete_coverage_chunks := 0.0
	var max_mid_mesh_types := 0.0
	var hlod_enabled_samples := 0
	var max_hlod_cache_mb := 0.0
	var max_hlod_tier_0 := 0.0
	var max_hlod_tier_1 := 0.0
	var max_hlod_tier_2 := 0.0
	for row in _rows:
		var ms := row[1]
		frame_times.append(ms)
		total_ms += ms
		max_ms = maxf(max_ms, ms)
		if ms > 16.67:
			frames_over_16 += 1
		if ms > 33.33:
			frames_over_33 += 1
		if ms > BLOCKING_FRAME_MS:
			frames_over_50 += 1
		min_rendered = minf(min_rendered, row[12])
		max_rendered = maxf(max_rendered, row[12])
		min_loaded = minf(min_loaded, row[10])
		max_loaded = maxf(max_loaded, row[10])
		max_queue = maxf(max_queue, row[9])
		max_stream = maxf(max_stream, row[15])
		max_inst_ms = maxf(max_inst_ms, row[18] / 1000.0)
		max_static_cull_ms = maxf(max_static_cull_ms, row[24] / 1000.0)
		max_inst_static_ms = maxf(max_inst_static_ms, row[30] / 1000.0)
		max_total_impostors = maxf(max_total_impostors, row[31])
		max_far_pending_cells = maxf(max_far_pending_cells, row[32])
		max_far_texture_upload_ms = maxf(max_far_texture_upload_ms, row[34] / 1000.0)
		max_far_normal_upload_ms = maxf(max_far_normal_upload_ms, row[35] / 1000.0)
		max_far_multimesh_pack_ms = maxf(max_far_multimesh_pack_ms, row[36] / 1000.0)
		max_far_multimesh_upload_ms = maxf(max_far_multimesh_upload_ms, row[37] / 1000.0)
		max_far_cell_scan_ms = maxf(max_far_cell_scan_ms, row[38] / 1000.0)
		max_far_page_count = maxf(max_far_page_count, row[39])
		max_far_dirty_page_count = maxf(max_far_dirty_page_count, row[40])
		max_far_pages_rebuilt = maxf(max_far_pages_rebuilt, row[41])
		max_far_uploaded_instances = maxf(max_far_uploaded_instances, row[42])
		min_mid_instances = minf(min_mid_instances, row[43])
		max_mid_instances = maxf(max_mid_instances, row[43])
		min_mid_visible = minf(min_mid_visible, row[44])
		max_mid_visible = maxf(max_mid_visible, row[44])
		max_mid_buckets = maxf(max_mid_buckets, row[45])
		max_mid_draw_groups = maxf(max_mid_draw_groups, row[46])
		min_hlod_cells = minf(min_hlod_cells, row[47])
		max_hlod_cells = maxf(max_hlod_cells, row[47])
		max_hlod_pending = maxf(max_hlod_pending, row[48])
		max_hlod_surfaces = maxf(max_hlod_surfaces, row[49])
		max_hlod_materials = maxf(max_hlod_materials, row[50])
		max_hlod_stale = maxf(max_hlod_stale, row[51])
		max_hlod_merge_queue_ms = maxf(max_hlod_merge_queue_ms, row[52] / 1000.0)
		max_hlod_completion_ms = maxf(max_hlod_completion_ms, row[53] / 1000.0)
		max_hlod_desired = maxf(max_hlod_desired, row[54])
		max_hlod_merge_queue_chunks = maxf(max_hlod_merge_queue_chunks, row[55])
		max_hlod_preparing = maxf(max_hlod_preparing, row[56])
		max_hlod_negative = maxf(max_hlod_negative, row[57])
		min_hlod_active_visual = minf(min_hlod_active_visual, row[58])
		max_hlod_active_visual = maxf(max_hlod_active_visual, row[58])
		max_handoff_mid_hlod_overlap = maxf(max_handoff_mid_hlod_overlap, row[60])
		max_hlod_nonvisual_suppressed = maxf(max_hlod_nonvisual_suppressed, row[61])
		min_far_visibility_begin = minf(min_far_visibility_begin, row[62])
		max_far_visibility_begin = maxf(max_far_visibility_begin, row[62])
		max_handoff_far_hlod_overlap = maxf(max_handoff_far_hlod_overlap, row[63])
		max_handoff_hole_risk = maxf(max_handoff_hole_risk, row[64])
		max_far_hlod_covered_pages = maxf(max_far_hlod_covered_pages, row[65])
		max_far_hlod_uncovered_pages = maxf(max_far_hlod_uncovered_pages, row[66])
		max_far_hlod_covered_impostors = maxf(max_far_hlod_covered_impostors, row[67])
		max_far_hlod_page_overrides = maxf(max_far_hlod_page_overrides, row[68])
		max_hlod_active_covered_refs = maxf(max_hlod_active_covered_refs, row[69])
		max_hlod_active_covered_cells = maxf(max_hlod_active_covered_cells, row[70])
		max_hlod_complete_coverage_chunks = maxf(max_hlod_complete_coverage_chunks, row[71])
		max_hlod_incomplete_coverage_chunks = maxf(max_hlod_incomplete_coverage_chunks, row[72])
		max_mid_mesh_types = maxf(max_mid_mesh_types, row[73])
		if row[74] > 0.0:
			hlod_enabled_samples += 1
		max_hlod_cache_mb = maxf(max_hlod_cache_mb, row[76])
		max_hlod_tier_0 = maxf(max_hlod_tier_0, row[77])
		max_hlod_tier_1 = maxf(max_hlod_tier_1, row[78])
		max_hlod_tier_2 = maxf(max_hlod_tier_2, row[79])
	frame_times.sort()

	var transitions := _build_transition_summaries()
	var lifecycle_counts := _build_event_counts()
	var worst_transition_ms := 0.0
	var worst_drop_fps := 0.0
	for t in transitions:
		worst_transition_ms = maxf(worst_transition_ms, float(t.get("post_max_ms", 0.0)))
		worst_drop_fps = maxf(worst_drop_fps, float(t.get("drop_fps", 0.0)))

	return {
		"stamp": _stamp,
		"route": _route_name,
		"route_mode": _route_mode,
		"route_valid": _route_setup_failures.is_empty(),
		"route_setup_failures": _route_setup_failures.duplicate(),
		"route_forced_hlod": _route_forced_hlod,
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
		"blocking_frame_ms": BLOCKING_FRAME_MS,
		"streaming_publish_budget_ms": BT.STREAMING_PUBLISH_BUDGET_MS,
		"streaming_publish_blocking_ms": STREAMING_PUBLISH_BLOCKING_MS,
		"static_publish_spike_ms": STATIC_PUBLISH_SPIKE_MS,
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
		"max_inst_static_ms": max_inst_static_ms,
		"max_total_impostors": int(max_total_impostors),
		"max_far_pending_cells": int(max_far_pending_cells),
		"max_far_texture_upload_ms": max_far_texture_upload_ms,
		"max_far_normal_upload_ms": max_far_normal_upload_ms,
		"max_far_multimesh_pack_ms": max_far_multimesh_pack_ms,
		"max_far_multimesh_upload_ms": max_far_multimesh_upload_ms,
		"max_far_cell_scan_ms": max_far_cell_scan_ms,
		"max_far_page_count": int(max_far_page_count),
		"max_far_dirty_page_count": int(max_far_dirty_page_count),
		"max_far_pages_rebuilt": int(max_far_pages_rebuilt),
		"max_far_uploaded_instances": int(max_far_uploaded_instances),
		"min_mid_instances": int(min_mid_instances),
		"max_mid_instances": int(max_mid_instances),
		"min_mid_visible": int(min_mid_visible),
		"max_mid_visible": int(max_mid_visible),
		"max_mid_buckets": int(max_mid_buckets),
		"max_mid_draw_groups": int(max_mid_draw_groups),
		"min_hlod_cells": int(min_hlod_cells),
		"max_hlod_cells": int(max_hlod_cells),
		"max_hlod_pending": int(max_hlod_pending),
		"max_hlod_chunk_surfaces": int(max_hlod_surfaces),
		"max_hlod_chunk_materials": int(max_hlod_materials),
		"max_hlod_stale_completions": int(max_hlod_stale),
		"max_hlod_merge_queue_ms": max_hlod_merge_queue_ms,
		"max_hlod_completion_ms": max_hlod_completion_ms,
		"max_hlod_desired_chunks": int(max_hlod_desired),
		"max_hlod_merge_queue_chunks": int(max_hlod_merge_queue_chunks),
		"max_hlod_preparing_chunks": int(max_hlod_preparing),
		"max_hlod_negative_chunks": int(max_hlod_negative),
		"min_hlod_active_visual_chunks": int(min_hlod_active_visual),
		"max_hlod_active_visual_chunks": int(max_hlod_active_visual),
		"handoff_max_mid_hlod_overlap_chunks": int(max_handoff_mid_hlod_overlap),
		"max_hlod_nonvisual_suppressed": int(max_hlod_nonvisual_suppressed),
		"min_far_visibility_begin_m": min_far_visibility_begin,
		"max_far_visibility_begin_m": max_far_visibility_begin,
		"handoff_max_far_hlod_overlap_chunks": int(max_handoff_far_hlod_overlap),
		"handoff_max_hole_risk_chunks": int(max_handoff_hole_risk),
		"max_far_hlod_covered_pages": int(max_far_hlod_covered_pages),
		"max_far_hlod_uncovered_pages": int(max_far_hlod_uncovered_pages),
		"max_far_hlod_covered_impostors": int(max_far_hlod_covered_impostors),
		"max_far_hlod_page_overrides": int(max_far_hlod_page_overrides),
		"max_hlod_active_covered_refs": int(max_hlod_active_covered_refs),
		"max_hlod_active_covered_cells": int(max_hlod_active_covered_cells),
		"max_hlod_complete_coverage_chunks": int(max_hlod_complete_coverage_chunks),
		"max_hlod_incomplete_coverage_chunks": int(max_hlod_incomplete_coverage_chunks),
		"max_mid_mesh_types": int(max_mid_mesh_types),
		"hlod_enabled_samples": hlod_enabled_samples,
		"max_hlod_cache_mb": max_hlod_cache_mb,
		"max_hlod_chunks_tier_0": int(max_hlod_tier_0),
		"max_hlod_chunks_tier_1": int(max_hlod_tier_1),
		"max_hlod_chunks_tier_2": int(max_hlod_tier_2),
		"transitions": transitions,
		"lifecycle_event_counts": lifecycle_counts,
	}


func _build_event_counts() -> Dictionary:
	var counts: Dictionary = {}
	for event: Dictionary in _events:
		var name := str(event.get("event", ""))
		if name.is_empty():
			continue
		counts[name] = int(counts.get(name, 0)) + 1
	return counts


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
		var post_min_mid_visible := _min_value(idx, post_end, 44)
		var post_min_hlod_cells := _min_value(idx, post_end, 47)
		var post_max_hlod_pending := _max_value(idx, post_end, 48)
		var post_max_hlod_overlap := _max_value(idx, post_end, 60)
		var post_min_hlod_active_visual := _min_value(idx, post_end, 58)
		var post_max_far_hlod_overlap := _max_value(idx, post_end, 63)
		var post_max_hole_risk := _max_value(idx, post_end, 64)
		var post_max_far_hlod_page_overrides := _max_value(idx, post_end, 68)
		var post_max_hlod_covered_refs := _max_value(idx, post_end, 69)
		var pre_fps := 1000.0 / maxf(pre_avg_ms, 0.001)
		var post_fps := 1000.0 / maxf(post_avg_ms, 0.001)
		var post_min_fps := 1000.0 / maxf(post_max_ms, 0.001)
		var stutter_frames_16 := _count_over_ms(idx, post_end, 16.67)
		var stutter_frames := _count_over_ms(idx, post_end, 33.33)
		var stutter_frames_50 := _count_over_ms(idx, post_end, BLOCKING_FRAME_MS)
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
		copy["post_min_mid_visible"] = int(post_min_mid_visible)
		copy["post_min_hlod_cells"] = int(post_min_hlod_cells)
		copy["post_max_hlod_pending"] = int(post_max_hlod_pending)
		copy["post_max_handoff_mid_hlod_overlap_chunks"] = int(post_max_hlod_overlap)
		copy["post_min_hlod_active_visual_chunks"] = int(post_min_hlod_active_visual)
		copy["post_max_handoff_far_hlod_overlap_chunks"] = int(post_max_far_hlod_overlap)
		copy["post_max_handoff_hole_risk_chunks"] = int(post_max_hole_risk)
		copy["post_max_far_hlod_page_overrides"] = int(post_max_far_hlod_page_overrides)
		copy["post_max_hlod_active_covered_refs"] = int(post_max_hlod_covered_refs)
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
