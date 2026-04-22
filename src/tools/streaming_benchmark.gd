## StreamingBenchmark — in-session streaming pipeline benchmark.
##
## Attached by world_explorer via console command (`benchmark` / `bench`).
## Runs a scripted camera path around Seyda Neen and logs per-frame metrics
## to user://benchmark_results/ (CSV + JSON summary + events CSV).
class_name StreamingBenchmark
extends Node3D

const DU := preload("res://src/core/world/distance_utils.gd")
const NativeStreamingManagerScript := preload("res://src/core/world/native_streaming_manager.gd")
const CellManagerScript := preload("res://src/core/world/cell_manager.gd")

#region Signals
signal benchmark_complete(results: Dictionary)
#endregion


#region Constants

## Balmora cell coordinates — dense city region with buildings, stairs, clutter.
## Relocated from Seyda Neen 2026-04-21 for Phase 0: coastal spawn's northern
## walk path hits water/coast, undercounting streaming work. Balmora's north is
## the Odai river valley (rocks + bridges), south is the Foyada Mamaea road
## (rocks + tomb clutter). Both directions stress the NEAR pipeline.
const SPAWN_CELL := Vector2i(-3, -2)

## Camera altitudes for the realistic flyby (ground-level village + high overlook)
const VILLAGE_ALTITUDE := 5.0  # eye-level above terrain
const VISTA_ALTITUDE := 80.0   # 80m overlook for FAR-tier/impostor stress

## Segment durations (seconds) — v2 realistic player-speed flyby, 85s total
const SETTLE_DURATION := 10.0  # wait for streaming queue to drain post-launch
const IDLE_DURATION := 15.0    # still at village center, pure render cost
const WALK_DURATION := 25.0    # 7 m/s traverse, 175m straight line north
const VISTA_DURATION := 10.0   # still at altitude, FAR-tier / impostor load
const PAN_DURATION := 10.0     # 360° rotation in place, frustum-culling cost
const RUN_DURATION := 15.0     # 15 m/s traverse, 225m stressed streaming

## Player movement speeds (m/s)
## Phase 0 ablation (2026-04-21): bumped RUN_SPEED 15 → 28 (~100 km/h) per user
## directive — streaming must handle flight-speed traversal, not just foot pace.
## WALK stays at 7 m/s so baseline "steady" pace still profiles realistically.
const WALK_SPEED := 7.0   # realistic walking pace
const RUN_SPEED := 28.0   # flight-speed traversal (~100 km/h) — stress case

## How many sub-waypoints across the 360° pan. Each holds its look-at for
## PAN_DURATION / PAN_SEGMENTS seconds; camera position is fixed at vista.
const PAN_SEGMENTS := 16

## Total scripted flyby duration, reported in logs
const FLYBY_TOTAL_S := SETTLE_DURATION + IDLE_DURATION + WALK_DURATION \
	+ VISTA_DURATION + PAN_DURATION + RUN_DURATION

## Segment names for reporting. Order matches the waypoint segments below
## and the `segment` column index written into the per-frame CSV.
const SEGMENT_NAMES: Array[String] = [
	"settle", "idle", "walk", "vista", "pan", "run"
]

## CSV column headers
const CSV_HEADERS := "frame,time_ms,fps,node_count,draw_calls,rendered_objects,primitives,queue_size,loaded_cells,async_requests,cam_x,cam_y,cam_z,memory_static,segment,mid_instances,mid_mesh_types,vram_mb,texture_mem_mb,promoted_objects,stream_total_ms,phase_unload_us,phase_async_us,phase_inst_us,phase_promo_us,phase_coll_us,phase_defer_us,phase_queue_us,phase_cellupd_us"

#endregion


#region Waypoint

class Waypoint:
	var position: Vector3
	var look_at: Vector3
	var duration: float
	var is_teleport: bool

	func _init(p_pos: Vector3, p_look: Vector3, p_dur: float, p_teleport: bool = false) -> void:
		position = p_pos
		look_at = p_look
		duration = p_dur
		is_teleport = p_teleport

#endregion


#region State

var _camera: Camera3D = null
var _streaming_manager: NativeStreamingManagerScript = null
var _cell_manager: CellManagerScript = null

## Waypoints defining the camera path
var _waypoints: Array[Waypoint] = []
var _current_waypoint_index: int = 0
var _waypoint_elapsed: float = 0.0
var _waypoint_start_pos: Vector3 = Vector3.ZERO
## Start look-at for the current waypoint — paired with _waypoint_start_pos so
## _advance_camera can linearly interpolate both position and look target
## (smooth rotation during the 360° pan).
var _waypoint_start_look: Vector3 = Vector3.ZERO
var _current_segment_index: int = 0

## Frame log: array of PackedFloat64Array (one per frame)
var _frame_log: Array[PackedFloat64Array] = []
var _last_frame_time_ms: float = 0.0

## Running state
var _running: bool = false
var _finished: bool = false

## Manual mode (bench_start / bench_stop) — no scripted flyby, no UI overlay,
## user drives the camera and we just record per-frame metrics between the
## start / stop calls. Plan §4.3.
var _manual_mode: bool = false
var _manual_label: String = ""
var _manual_start_ms: int = 0

## Tracks the currently-active manual benchmark so bench_start refuses to
## create a second one while one is already running. Cleared in stop_manual().
## Static so the two console-command lambdas share it without capturing by
## reference (GDScript lambda capture semantics get awkward for shared mut state).
static var _active_manual_bench: StreamingBenchmark = null

## UI references
var _stats_panel: VBoxContainer = null
var _fps_label: Label = null
var _frame_time_label: Label = null
var _object_count_label: Label = null
var _draw_call_label: Label = null
var _queue_size_label: Label = null
var _phase_label: Label = null
var _progress_bar: ProgressBar = null

## Console reference (for printing results when run as console command)
var _console: Node = null

## Segment boundaries: waypoint index where each segment starts
var _segment_starts: PackedInt32Array = PackedInt32Array()

## Streaming event log for per-model diagnostics
## Each entry: {frame: int, event: String, detail: String}
var _event_log: Array[Dictionary] = []

## Track visible objects per frame to detect appear/disappear patterns
var _prev_visible_count: int = -1
var _visibility_change_count: int = 0

#endregion


#region Initialization

## Initialize for console command mode (uses existing systems in world_explorer)
func init_console_mode(
	streaming_manager: NativeStreamingManagerScript,
	cell_manager: CellManagerScript,
	camera: Camera3D,
	console: Node = null
) -> void:
	_streaming_manager = streaming_manager
	_cell_manager = cell_manager
	_camera = camera
	_console = console

	_setup_ui()
	_build_waypoints()
	_start_benchmark()


## Initialize for manual measurement mode (bench_start command).
## No scripted camera path, no on-screen UI overlay — user flies the camera
## themselves and stop_manual() is called later (bench_stop command) to finalize
## the capture. The label is embedded into the output filenames so multiple
## A/B blocks in one session don't overwrite each other.
func init_manual_mode(
	streaming_manager: NativeStreamingManagerScript,
	cell_manager: CellManagerScript,
	camera: Camera3D,
	console: Node,
	label: String
) -> void:
	_streaming_manager = streaming_manager
	_cell_manager = cell_manager
	_camera = camera
	_console = console
	_manual_mode = true
	_manual_label = label
	_manual_start_ms = Time.get_ticks_msec()
	_current_segment_index = 0
	_frame_log.clear()
	_event_log.clear()
	_running = true
	_finished = false

	# Connect streaming signals for event log (matches _start_benchmark)
	if _streaming_manager:
		if _streaming_manager.has_signal("cell_loading"):
			_streaming_manager.cell_loading.connect(_on_cell_loading)
		if _streaming_manager.has_signal("cell_loaded"):
			_streaming_manager.cell_loaded.connect(_on_cell_loaded)
		if _streaming_manager.has_signal("cell_unloaded"):
			_streaming_manager.cell_unloaded.connect(_on_cell_unloaded)

	Log.info("tools", "StreamingBenchmark: manual recording started (label: '%s')" % label)

#endregion


#region UI Setup

func _setup_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "BenchmarkUI"
	add_child(canvas)

	# Stats panel (top-left)
	_stats_panel = VBoxContainer.new()
	_stats_panel.position = Vector2(10, 10)
	canvas.add_child(_stats_panel)

	var panel_bg := PanelContainer.new()
	panel_bg.add_theme_stylebox_override("panel", _create_panel_style())
	_stats_panel.add_child(panel_bg)

	var vbox := VBoxContainer.new()
	panel_bg.add_child(vbox)

	var title := Label.new()
	title.text = "Streaming Benchmark"
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)

	_fps_label = _add_stat_label(vbox, "FPS: --")
	_frame_time_label = _add_stat_label(vbox, "Frame: -- ms")
	_object_count_label = _add_stat_label(vbox, "Nodes: --")
	_draw_call_label = _add_stat_label(vbox, "Draw calls: --")
	_queue_size_label = _add_stat_label(vbox, "Queue: --")
	_phase_label = _add_stat_label(vbox, "Phase: --")

	# Progress bar (bottom)
	_progress_bar = ProgressBar.new()
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = 100.0
	_progress_bar.custom_minimum_size = Vector2(400, 24)
	_progress_bar.anchors_preset = Control.PRESET_BOTTOM_WIDE
	_progress_bar.offset_top = -34
	_progress_bar.offset_bottom = -10
	_progress_bar.offset_left = 10
	_progress_bar.offset_right = -10
	canvas.add_child(_progress_bar)


func _add_stat_label(parent: Control, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 14)
	parent.add_child(label)
	return label


func _create_panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.7)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	return style

#endregion


#region Waypoint Construction

func _build_waypoints() -> void:
	_waypoints.clear()
	_segment_starts.clear()

	var village_pos := DU.cell_to_world_center(SPAWN_CELL, VILLAGE_ALTITUDE)
	var village_look := village_pos + Vector3(0, 0, -10)  # look north along walk path

	# Segment 1: Settle (10s) — still at village, let streaming queue drain.
	# Teleport to the village first in case the harness-owner positioned the
	# camera elsewhere; otherwise this segment's initial motion would show up
	# as a ballistic jump and skew the settle measurement.
	_segment_starts.append(_waypoints.size())
	_waypoints.append(Waypoint.new(village_pos, village_look, 0.0, true))
	_waypoints.append(Waypoint.new(village_pos, village_look, SETTLE_DURATION))

	# Segment 2: Idle (15s) — still at village center, dense geometry render cost
	_segment_starts.append(_waypoints.size())
	_waypoints.append(Waypoint.new(village_pos, village_look, IDLE_DURATION))

	# Segment 3: Walk (25s) — 7 m/s straight-line north, 175m traverse
	_segment_starts.append(_waypoints.size())
	var walk_end := village_pos + Vector3(0, 0, -WALK_SPEED * WALK_DURATION)
	_waypoints.append(Waypoint.new(walk_end, walk_end + Vector3(0, 0, -10), WALK_DURATION))

	# Segment 4: Vista (10s) — teleport to 80m overlook, still, FAR/impostor load.
	# Vista look target is deliberately aligned with the pan's 0° direction
	# (+Z south, matching the pan's angle-0° sub-waypoint) so the vista→pan
	# handoff is a clean 22.5° step instead of a ~200° re-aim smear that
	# would contaminate pan-segment p95/max numbers.
	_segment_starts.append(_waypoints.size())
	var vista_pos := DU.cell_to_world_center(SPAWN_CELL, VISTA_ALTITUDE)
	var vista_look := vista_pos + Vector3(0, -20, 100)  # down + south
	_waypoints.append(Waypoint.new(vista_pos, vista_look, 0.0, true))
	_waypoints.append(Waypoint.new(vista_pos, vista_look, VISTA_DURATION))

	# Segment 5: Pan (10s) — 360° look_at rotation at vista position. Camera
	# position is fixed; each sub-waypoint shifts the look target by 360/N
	# degrees, and _advance_camera interpolates look_at linearly so the
	# rotation is visually continuous across sub-waypoint boundaries.
	_segment_starts.append(_waypoints.size())
	var pan_duration_per := PAN_DURATION / float(PAN_SEGMENTS)
	for i in range(PAN_SEGMENTS):
		var angle := TAU * float(i + 1) / float(PAN_SEGMENTS)
		var look_offset := Vector3(sin(angle) * 100.0, -20.0, cos(angle) * 100.0)
		_waypoints.append(Waypoint.new(vista_pos, vista_pos + look_offset, pan_duration_per))

	# Segment 6: Run (15s) — teleport back to village then 15 m/s south, 225m
	# traverse. South direction (+Z in Godot, per the MW coord convention the
	# rest of the codebase follows) touches cells not visited by the walk leg,
	# so this stresses fresh streaming rather than measuring warm-cache cost.
	_segment_starts.append(_waypoints.size())
	_waypoints.append(Waypoint.new(village_pos, village_pos + Vector3(0, 0, 10), 0.0, true))
	var run_end := village_pos + Vector3(0, 0, RUN_SPEED * RUN_DURATION)
	_waypoints.append(Waypoint.new(run_end, run_end + Vector3(0, 0, 10), RUN_DURATION))

#endregion


#region Benchmark Control

func _start_benchmark() -> void:
	if _waypoints.is_empty():
		Log.error("tools", "StreamingBenchmark: No waypoints defined")
		return

	_current_waypoint_index = 0
	_current_segment_index = 0
	_waypoint_elapsed = 0.0
	_frame_log.clear()
	_running = true
	_finished = false

	# Position camera at first waypoint
	var wp := _waypoints[0]
	_camera.global_position = wp.position
	_waypoint_start_pos = wp.position
	_waypoint_start_look = wp.look_at
	if wp.look_at != wp.position:
		_camera.look_at(wp.look_at)

	# Connect to streaming manager signals for lifecycle event tracking
	if _streaming_manager:
		if _streaming_manager.has_signal("cell_loading"):
			_streaming_manager.cell_loading.connect(_on_cell_loading)
		if _streaming_manager.has_signal("cell_loaded"):
			_streaming_manager.cell_loaded.connect(_on_cell_loaded)
		if _streaming_manager.has_signal("cell_unloaded"):
			_streaming_manager.cell_unloaded.connect(_on_cell_unloaded)

	Log.info("tools", "StreamingBenchmark: Started (%d waypoints, %.0fs scripted flyby)" % [
		_waypoints.size(), FLYBY_TOTAL_S
	])


func _process(delta: float) -> void:
	if not _running or _finished:
		return

	_last_frame_time_ms = delta * 1000.0

	# Log this frame's metrics (shared across scripted + manual modes)
	_log_frame()

	# Manual mode: just record, no scripted camera, no UI, no auto-completion.
	# User drives the camera and calls stop_manual() via `bench_stop` when done.
	if _manual_mode:
		return

	# Advance camera
	_advance_camera(delta)

	# Update UI
	_update_ui()

	# Check if benchmark is complete
	if _current_waypoint_index >= _waypoints.size():
		_finish_benchmark()


func _advance_camera(delta: float) -> void:
	if _current_waypoint_index >= _waypoints.size():
		return

	var wp := _waypoints[_current_waypoint_index]

	# Handle teleport waypoints
	if wp.is_teleport:
		_camera.global_position = wp.position
		if wp.look_at != wp.position:
			_camera.look_at(wp.look_at)
		_advance_to_next_waypoint()
		return

	# Handle zero-duration waypoints (instant position)
	if wp.duration <= 0.0:
		_camera.global_position = wp.position
		if wp.look_at != wp.position:
			_camera.look_at(wp.look_at)
		_advance_to_next_waypoint()
		return

	_waypoint_elapsed += delta

	# Linear interpolation (no smoothstep) — constant-speed motion gives a
	# physically meaningful measurement of "walk at 7 m/s" and "run at 15 m/s"
	# traversal cost. Smoothstep would ease in/out and misrepresent the
	# streaming pressure the player actually experiences at those speeds.
	var t := clampf(_waypoint_elapsed / wp.duration, 0.0, 1.0)
	_camera.global_position = _waypoint_start_pos.lerp(wp.position, t)

	# Interpolate look_at too — matters for the pan segment, where a series
	# of short sub-waypoints rotates the target around the camera; without
	# interpolation each sub-waypoint boundary would jump-cut the view.
	var look_target := _waypoint_start_look.lerp(wp.look_at, t)
	if look_target.distance_squared_to(_camera.global_position) > 1.0:
		_camera.look_at(look_target)

	# Advance to next waypoint when done
	if _waypoint_elapsed >= wp.duration:
		_camera.global_position = wp.position
		_advance_to_next_waypoint()


func _advance_to_next_waypoint() -> void:
	# The waypoint we're LEAVING owns both the ending position and look-at —
	# these become the starting anchors for the next waypoint's interpolation.
	var leaving_wp := _waypoints[_current_waypoint_index]
	_waypoint_start_pos = _camera.global_position
	_waypoint_start_look = leaving_wp.look_at
	_current_waypoint_index += 1
	_waypoint_elapsed = 0.0
	_update_segment_index()


func _update_segment_index() -> void:
	for i in range(_segment_starts.size() - 1, -1, -1):
		if _current_waypoint_index >= _segment_starts[i]:
			_current_segment_index = i
			return

#endregion


#region Metrics Logging

func _log_frame() -> void:
	var entry := PackedFloat64Array()
	entry.resize(29)
	entry[0] = float(Engine.get_frames_drawn())
	entry[1] = _last_frame_time_ms
	entry[2] = Engine.get_frames_per_second()
	entry[3] = float(_get_node_count())
	entry[4] = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	entry[5] = Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	entry[6] = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	entry[7] = float(_get_queue_size())
	entry[8] = float(_get_loaded_cells())
	entry[9] = float(_get_async_requests())
	entry[10] = _camera.global_position.x
	entry[11] = _camera.global_position.y
	entry[12] = _camera.global_position.z
	entry[13] = Performance.get_monitor(Performance.MEMORY_STATIC)
	entry[14] = float(_current_segment_index)
	# MID-tier StaticObjectRenderer stats
	var mid_stats := _get_mid_tier_stats()
	entry[15] = float(mid_stats.get("total_instances", 0))
	entry[16] = float(mid_stats.get("mesh_types", 0))
	# VRAM and texture memory (MB)
	entry[17] = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
	entry[18] = Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0
	# Promoted objects count
	entry[19] = float(_get_promoted_count())
	# Per-phase streaming timing from NativeStreamingManager
	if _streaming_manager and _streaming_manager.has_method("get_phase_times"):
		entry[20] = _streaming_manager.get_frame_streaming_ms()
		var pt: PackedFloat64Array = _streaming_manager.get_phase_times()
		for i in range(mini(pt.size(), 8)):
			entry[21 + i] = pt[i]
	_frame_log.append(entry)

	# Sample visibility for appear/disappear detection
	_sample_visibility()


func _get_node_count() -> int:
	return Performance.get_monitor(Performance.OBJECT_NODE_COUNT) as int


func _get_queue_size() -> int:
	if _cell_manager:
		return _cell_manager.get_instantiation_queue_size()
	if _streaming_manager:
		var stats: Dictionary = _streaming_manager.get_stats()
		return stats.get("instantiation_queue", 0) as int
	return 0


func _get_loaded_cells() -> int:
	if _streaming_manager:
		var stats: Dictionary = _streaming_manager.get_stats()
		return stats.get("loaded_cells", 0) as int
	return 0


func _get_async_requests() -> int:
	if _streaming_manager:
		var stats: Dictionary = _streaming_manager.get_stats()
		return stats.get("async_requests", 0) as int
	return 0


func _get_mid_tier_stats() -> Dictionary:
	if _streaming_manager and _streaming_manager.has_method("get_static_renderer_stats"):
		return _streaming_manager.get_static_renderer_stats()
	# Fallback: try to find StaticObjectRenderer in streaming manager children
	if _streaming_manager:
		for child in _streaming_manager.get_children():
			if child.has_method("get_stats"):
				return child.get_stats()
	return {}


func _get_promoted_count() -> int:
	if _streaming_manager:
		var stats: Dictionary = _streaming_manager.get_stats()
		return stats.get("mid_to_near_promotions", 0) as int
	return 0


## Count visible MeshInstance3D nodes and rendered objects to detect appear/disappear
func _sample_visibility() -> void:
	var rendered := int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	if _prev_visible_count >= 0:
		var delta_objects := rendered - _prev_visible_count
		# Log drops >5 objects in one frame (lowered from 20 to catch subtle issues)
		if delta_objects < -5:
			var mid_stats := _get_mid_tier_stats()
			var mid_count: int = mid_stats.get("total_instances", 0)
			_log_event("visibility_drop", "rendered %d -> %d (delta %d, mid_instances=%d)" % [_prev_visible_count, rendered, delta_objects, mid_count])
			_visibility_change_count += 1
	_prev_visible_count = rendered


func _on_cell_loading(grid: Vector2i) -> void:
	_log_event("cell_loading", "%s" % grid)

func _on_cell_loaded(grid: Vector2i, object_count: int) -> void:
	_log_event("cell_loaded", "%s (%d objects)" % [grid, object_count])

func _on_cell_unloaded(grid: Vector2i) -> void:
	_log_event("cell_unloaded", "%s" % grid)

func _log_event(event: String, detail: String) -> void:
	_event_log.append({
		"frame": Engine.get_frames_drawn(),
		"time_ms": Time.get_ticks_msec(),
		"event": event,
		"detail": detail,
		"segment": _current_segment_index,
	})

#endregion


#region UI Update

func _update_ui() -> void:
	if not _fps_label:
		return

	var fps := Engine.get_frames_per_second()
	_fps_label.text = "FPS: %d" % fps
	_frame_time_label.text = "Frame: %.1f ms" % _last_frame_time_ms
	_object_count_label.text = "Nodes: %d" % _get_node_count()
	_draw_call_label.text = "Draw calls: %d" % int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_queue_size_label.text = "Queue: %d" % _get_queue_size()

	var seg_name := SEGMENT_NAMES[_current_segment_index] if _current_segment_index < SEGMENT_NAMES.size() else "done"
	_phase_label.text = "Phase: %s (%d/%d)" % [seg_name, _current_segment_index + 1, SEGMENT_NAMES.size()]

	# Progress
	var total_waypoints := _waypoints.size()
	if total_waypoints > 0 and _progress_bar:
		_progress_bar.value = float(_current_waypoint_index) / float(total_waypoints) * 100.0

#endregion


#region Benchmark Completion

func _finish_benchmark() -> void:
	_running = false
	_finished = true

	var results := _calculate_results()
	_save_csv()
	_save_events_csv()
	_print_summary(results)
	_save_json_summary(results)

	benchmark_complete.emit(results)

	# Clean up after a short delay
	get_tree().create_timer(1.0).timeout.connect(queue_free)


## Finalize a manual-mode recording (bench_stop command). Mirrors
## _finish_benchmark but driven externally rather than by waypoint exhaustion.
func stop_manual() -> void:
	if not _manual_mode or not _running:
		return
	_running = false
	_finished = true

	var duration_s := float(Time.get_ticks_msec() - _manual_start_ms) / 1000.0

	# Guard against the empty-frame-log crash path: bench_start + bench_stop in
	# rapid succession (or with the game paused / hung) leaves _frame_log empty.
	# _calculate_results returns {} in that case, but the subsequent label /
	# duration assignments would make is_empty() false downstream and
	# _print_summary would crash dereferencing .total_time_s.
	if _frame_log.is_empty():
		Log.warn("tools", "bench_stop: no frames recorded, nothing to save (label: '%s')" % _manual_label)
		if _active_manual_bench == self:
			_active_manual_bench = null
		get_tree().create_timer(1.0).timeout.connect(queue_free)
		return

	var results := _calculate_results()
	results["label"] = _manual_label
	results["manual_duration_s"] = duration_s

	_save_csv()
	_save_events_csv()
	_print_summary(results)
	_save_json_summary(results)

	benchmark_complete.emit(results)

	# Clear the class-level registry so a subsequent bench_start is allowed
	if _active_manual_bench == self:
		_active_manual_bench = null

	# Clean up after a short delay
	get_tree().create_timer(1.0).timeout.connect(queue_free)


## Build a filename prefix that embeds the manual label (if any) so multiple
## named blocks in one session produce distinguishable output files.
func _file_prefix(base: String) -> String:
	if _manual_mode and not _manual_label.is_empty():
		# Sanitize — labels come from user typing at the console
		var safe_label := _manual_label.validate_filename()
		return "%s_%s" % [base, safe_label]
	return base


func _calculate_results() -> Dictionary:
	if _frame_log.is_empty():
		return {}

	var total_frames := _frame_log.size()
	var frame_times: PackedFloat64Array = PackedFloat64Array()
	frame_times.resize(total_frames)
	for i in range(total_frames):
		frame_times[i] = _frame_log[i][1]

	# Sort frame times for percentile calculation
	var sorted_times: PackedFloat64Array = frame_times.duplicate()
	_sort_float_array(sorted_times)

	var total_time := 0.0
	for t in frame_times:
		total_time += t

	var avg_time := total_time / float(total_frames)
	var p50 := sorted_times[total_frames / 2]
	var p95 := sorted_times[int(total_frames * 0.95)]
	var p99 := sorted_times[int(total_frames * 0.99)]

	var max_time := 0.0
	var max_frame := 0
	var max_segment := 0
	for i in range(total_frames):
		if frame_times[i] > max_time:
			max_time = frame_times[i]
			max_frame = i
			max_segment = int(_frame_log[i][14])

	# Time to stable 60 FPS (30-frame rolling average)
	var time_to_60fps := -1
	if total_frames >= 30:
		var rolling_sum := 0.0
		for i in range(30):
			rolling_sum += 1000.0 / maxf(_frame_log[i][2], 1.0)  # ms per frame
		for i in range(30, total_frames):
			rolling_sum -= 1000.0 / maxf(_frame_log[i - 30][2], 1.0)
			rolling_sum += 1000.0 / maxf(_frame_log[i][2], 1.0)
			var rolling_avg_fps := 30000.0 / maxf(rolling_sum, 0.001)
			if rolling_avg_fps >= 60.0 and time_to_60fps < 0:
				time_to_60fps = i
				break

	# Peak values
	var peak_queue := 0.0
	var peak_cells := 0.0
	var peak_nodes := 0.0
	var peak_draw_calls := 0.0
	var total_draw_calls := 0.0
	var min_mid_instances := 999999.0
	var max_mid_instances := 0.0
	var peak_vram_mb := 0.0
	var peak_texture_mb := 0.0
	for entry in _frame_log:
		peak_queue = maxf(peak_queue, entry[7])
		peak_cells = maxf(peak_cells, entry[8])
		peak_nodes = maxf(peak_nodes, entry[3])
		peak_draw_calls = maxf(peak_draw_calls, entry[4])
		total_draw_calls += entry[4]
		# RS instance range (skip frames before any instances exist)
		if entry[15] > 0:
			min_mid_instances = minf(min_mid_instances, entry[15])
		max_mid_instances = maxf(max_mid_instances, entry[15])
		peak_vram_mb = maxf(peak_vram_mb, entry[17])
		peak_texture_mb = maxf(peak_texture_mb, entry[18])

	# Per-segment breakdown
	var segment_data: Dictionary = {}
	for seg_idx in range(SEGMENT_NAMES.size()):
		var seg_times: Array[float] = []
		for entry in _frame_log:
			if int(entry[14]) == seg_idx:
				seg_times.append(entry[1])
		if seg_times.is_empty():
			continue
		seg_times.sort()
		var seg_avg := 0.0
		for t in seg_times:
			seg_avg += t
		seg_avg /= float(seg_times.size())
		var seg_p99 := seg_times[int(seg_times.size() * 0.99)] if seg_times.size() > 1 else seg_times[0]
		segment_data[SEGMENT_NAMES[seg_idx]] = {"avg": seg_avg, "p99": seg_p99, "frames": seg_times.size()}

	return {
		"total_frames": total_frames,
		"total_time_s": total_time / 1000.0,
		"avg_time_ms": avg_time,
		"avg_fps": 1000.0 / maxf(avg_time, 0.001),
		"p50_ms": p50,
		"p95_ms": p95,
		"p99_ms": p99,
		"max_time_ms": max_time,
		"max_frame": max_frame,
		"max_segment": SEGMENT_NAMES[max_segment] if max_segment < SEGMENT_NAMES.size() else "unknown",
		"time_to_60fps_frames": time_to_60fps,
		"time_to_60fps_s": float(time_to_60fps) * avg_time / 1000.0 if time_to_60fps > 0 else -1.0,
		"peak_queue": int(peak_queue),
		"peak_cells": int(peak_cells),
		"peak_nodes": int(peak_nodes),
		"peak_draw_calls": int(peak_draw_calls),
		"avg_draw_calls": int(total_draw_calls / float(total_frames)),
		"min_mid_instances": int(min_mid_instances) if min_mid_instances < 999999.0 else 0,
		"max_mid_instances": int(max_mid_instances),
		"peak_vram_mb": peak_vram_mb,
		"peak_texture_mb": peak_texture_mb,
		"segments": segment_data,
	}


func _sort_float_array(arr: PackedFloat64Array) -> void:
	# Simple insertion sort — good enough for ~2000 frames
	for i in range(1, arr.size()):
		var key := arr[i]
		var j := i - 1
		while j >= 0 and arr[j] > key:
			arr[j + 1] = arr[j]
			j -= 1
		arr[j + 1] = key

#endregion


#region CSV Output

func _save_csv() -> void:
	var dir_path := "user://benchmark_results"
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var timestamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var file_path := "%s/%s_%s.csv" % [dir_path, _file_prefix("benchmark"), timestamp]

	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if not file:
		Log.error("tools", "StreamingBenchmark: Failed to write CSV to %s" % file_path)
		return

	file.store_line(CSV_HEADERS)
	for entry in _frame_log:
		var line := "%d,%.2f,%.1f,%d,%d,%d,%d,%d,%d,%d,%.1f,%.1f,%.1f,%.0f,%d,%d,%d,%.1f,%.1f,%d,%.2f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f" % [
			int(entry[0]), entry[1], entry[2], int(entry[3]), int(entry[4]),
			int(entry[5]), int(entry[6]), int(entry[7]), int(entry[8]),
			int(entry[9]), entry[10], entry[11], entry[12], entry[13],
			int(entry[14]), int(entry[15]), int(entry[16]),
			entry[17], entry[18], int(entry[19]),
			entry[20], entry[21], entry[22], entry[23], entry[24],
			entry[25], entry[26], entry[27], entry[28]
		]
		file.store_line(line)

	file.close()
	Log.info("tools", "StreamingBenchmark: CSV saved to %s" % file_path)


func _save_events_csv() -> void:
	if _event_log.is_empty():
		return

	var dir_path := "user://benchmark_results"
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var timestamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var file_path := "%s/%s_%s.csv" % [dir_path, _file_prefix("events"), timestamp]

	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if not file:
		return

	file.store_line("frame,time_ms,segment,event,detail")
	for entry: Dictionary in _event_log:
		file.store_line("%d,%d,%d,%s,%s" % [
			entry.frame, entry.time_ms, entry.segment,
			entry.event, entry.detail.replace(",", ";")
		])

	file.close()
	Log.info("tools", "StreamingBenchmark: Events CSV saved to %s (%d events)" % [file_path, _event_log.size()])

#endregion


#region Summary Output

func _print_summary(results: Dictionary) -> void:
	if results.is_empty():
		return

	var lines: PackedStringArray = PackedStringArray()
	lines.append("========== STREAMING BENCHMARK RESULTS ==========")
	lines.append("Duration: %.1fs (%d frames)" % [results.total_time_s, results.total_frames])
	lines.append("")
	lines.append("Frame Time:")
	lines.append("  Average: %.1fms (%.0f FPS)" % [results.avg_time_ms, results.avg_fps])
	lines.append("  P50: %.1fms" % results.p50_ms)
	lines.append("  P95: %.1fms" % results.p95_ms)
	lines.append("  P99: %.1fms" % results.p99_ms)
	lines.append("  Max: %.1fms (frame %d, segment: %s)" % [results.max_time_ms, results.max_frame, results.max_segment])
	lines.append("")

	if results.time_to_60fps_frames > 0:
		lines.append("Time to Stable 60 FPS: %d frames (%.1fs)" % [results.time_to_60fps_frames, results.time_to_60fps_s])
	else:
		lines.append("Time to Stable 60 FPS: N/A (never reached or too few frames)")

	lines.append("")
	lines.append("Loading:")
	lines.append("  Peak instantiation queue: %d" % results.peak_queue)
	lines.append("  Peak loaded cells: %d" % results.peak_cells)
	lines.append("  Peak node count: %d" % results.peak_nodes)
	lines.append("")
	lines.append("Rendering:")
	lines.append("  Average draw calls: %d" % results.avg_draw_calls)
	lines.append("  Peak draw calls: %d" % results.peak_draw_calls)
	lines.append("")
	lines.append("VRAM:")
	lines.append("  Peak VRAM: %.0f MB" % results.peak_vram_mb)
	lines.append("  Peak texture memory: %.0f MB" % results.peak_texture_mb)

	# MID-tier stats — show range over entire run to detect cleanup issues
	var final_mid_stats := _get_mid_tier_stats()
	if not final_mid_stats.is_empty():
		lines.append("")
		lines.append("MID-Tier (StaticObjectRenderer):")
		lines.append("  RS instances (final): %d" % final_mid_stats.get("total_instances", 0))
		lines.append("  RS instances (min/max over run): %d / %d" % [results.min_mid_instances, results.max_mid_instances])
		var delta: int = results.max_mid_instances - int(final_mid_stats.get("total_instances", 0))
		if delta > 0:
			lines.append("  RS instances freed during run: %d (cleanup working)" % delta)
		lines.append("  Visible RS instances: %d" % final_mid_stats.get("visible_instances", 0))
		lines.append("  Registered mesh types: %d" % final_mid_stats.get("mesh_types", 0))

	# Tier transition stats
	if _streaming_manager:
		var sm_stats: Dictionary = _streaming_manager.get_stats()
		var promotions: int = sm_stats.get("mid_to_near_promotions", 0)
		var demotions: int = sm_stats.get("near_to_mid_demotions", 0)
		if promotions > 0 or demotions > 0:
			lines.append("")
			lines.append("Tier Transitions (Phase 5b):")
			lines.append("  MID→NEAR promotions: %d" % promotions)
			lines.append("  NEAR→MID demotions: %d" % demotions)

	# Per-segment breakdown
	var segments: Dictionary = results.get("segments", {})
	if not segments.is_empty():
		lines.append("")
		lines.append("Per-Segment Breakdown:")
		for seg_name: String in SEGMENT_NAMES:
			if seg_name in segments:
				var seg: Dictionary = segments[seg_name]
				lines.append("  %-10s avg %5.1fms  p99 %5.1fms  (%d frames)" % [
					seg_name + ":", seg.avg, seg.p99, seg.frames
				])

	# Streaming events summary
	if not _event_log.is_empty():
		lines.append("")
		lines.append("Streaming Events:")
		var event_counts: Dictionary = {}
		for entry: Dictionary in _event_log:
			var ev: String = entry.event
			event_counts[ev] = event_counts.get(ev, 0) + 1
		for ev: String in event_counts:
			lines.append("  %s: %d" % [ev, event_counts[ev]])
		if _visibility_change_count > 0:
			lines.append("  Visibility drops (>5 objects): %d" % _visibility_change_count)

	# Per-phase streaming timing breakdown (I/O stall profiling)
	if _frame_log.size() > 0 and _frame_log[0].size() >= 29:
		var phase_names: Array[String] = ["unload", "async", "instantiate", "promote", "collision", "deferred", "queue", "cell_update"]
		var phase_avgs: PackedFloat64Array = PackedFloat64Array()
		var phase_maxes: PackedFloat64Array = PackedFloat64Array()
		var stream_total_avg := 0.0
		var stream_total_max := 0.0
		phase_avgs.resize(8)
		phase_maxes.resize(8)
		var count := 0
		for entry: PackedFloat64Array in _frame_log:
			if entry[20] > 0.001:  # Only count frames where streaming actually ran
				stream_total_avg += entry[20]
				stream_total_max = maxf(stream_total_max, entry[20])
				for i in range(8):
					phase_avgs[i] += entry[21 + i]
					phase_maxes[i] = maxf(phase_maxes[i], entry[21 + i])
				count += 1
		if count > 0:
			stream_total_avg /= float(count)
			for i in range(8):
				phase_avgs[i] /= float(count)
			lines.append("")
			lines.append("Streaming Phase Timing (I/O stall analysis):")
			lines.append("  Total streaming work: avg %.2fms, max %.2fms (%d active frames)" % [stream_total_avg, stream_total_max, count])
			for i in range(8):
				var avg_ms := phase_avgs[i] / 1000.0
				var max_ms := phase_maxes[i] / 1000.0
				var pct := (phase_avgs[i] / (stream_total_avg * 1000.0)) * 100.0 if stream_total_avg > 0.001 else 0.0
				lines.append("  %-14s avg %6.2fms  max %6.2fms  (%4.1f%%)" % [phase_names[i] + ":", avg_ms, max_ms, pct])

	lines.append("")

	var timestamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	lines.append("CSV saved to: user://benchmark_results/benchmark_%s.csv" % timestamp)
	lines.append("==================================================")

	var output := "\n".join(lines)
	Log.info("tools", output)

	# Also print to console if available
	if _console and _console.has_method("print_line"):
		for line: String in lines:
			_console.print_line(line)

#endregion


#region JSON Summary

## Save a JSON summary alongside the CSV for historical comparison
func _save_json_summary(results: Dictionary, toggle_state: Dictionary = {}) -> String:
	var dir_path := "user://benchmark_results"
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var timestamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var file_path := "%s/%s_%s.json" % [dir_path, _file_prefix("summary"), timestamp]

	var summary := {
		"timestamp": Time.get_datetime_string_from_system(),
		"label": _manual_label if _manual_mode else "",
		"mode": "manual" if _manual_mode else "scripted",
		# Wall-clock duration in manual mode — diverges from total_time_s
		# (frame-log-derived) when the game hangs / pauses mid-block, so it's
		# useful for post-hoc "did the game freeze during this measurement?"
		# diagnostics. 0.0 for scripted runs.
		"manual_duration_s": results.get("manual_duration_s", 0.0),
		"toggle_state": toggle_state,
		"avg_fps": results.get("avg_fps", 0.0),
		"avg_ms": results.get("avg_time_ms", 0.0),
		"p50_ms": results.get("p50_ms", 0.0),
		"p95_ms": results.get("p95_ms", 0.0),
		"p99_ms": results.get("p99_ms", 0.0),
		"max_ms": results.get("max_time_ms", 0.0),
		"avg_draw_calls": results.get("avg_draw_calls", 0),
		"peak_draw_calls": results.get("peak_draw_calls", 0),
		"peak_vram_mb": results.get("peak_vram_mb", 0.0),
		"total_frames": results.get("total_frames", 0),
		"total_time_s": results.get("total_time_s", 0.0),
	}

	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(summary, "\t"))
		file.close()
		Log.info("tools", "Summary JSON saved to %s" % file_path)
	return file_path

#endregion


#region Console Command Helpers

## Register benchmark console commands on a Console node
## streaming_manager: NativeStreamingManager (Node3D), cell_manager: CellManager (RefCounted)
static func register_console_commands(console: Node, streaming_manager: Variant, cell_manager: Variant, camera: Camera3D) -> void:
	var run_bench := func(args: Dictionary) -> Variant:
		var benchmark := StreamingBenchmark.new()
		benchmark.name = "StreamingBenchmark"
		console.get_tree().root.add_child(benchmark)
		benchmark.init_console_mode(streaming_manager, cell_manager, camera, console)
		return "Streaming benchmark started (~%ds, realistic flyby)..." % int(FLYBY_TOTAL_S)

	console.register_command(
		"benchmark_streaming", run_bench,
		"Run streaming benchmark (~%ds, realistic player-speed flyby)" % int(FLYBY_TOTAL_S),
		"debug",
		PackedStringArray(["bench_stream"]),
	)

	# Shorthand aliases
	console.register_command(
		"benchmark", run_bench,
		"Run streaming benchmark (~%ds). Alias for benchmark_streaming" % int(FLYBY_TOTAL_S),
		"debug",
		PackedStringArray(["bench"]),
	)

	# Manual measurement blocks — user-driven capture of arbitrary gameplay
	# moments. `bench_start <label>` begins recording; `bench_stop` finalizes.
	var run_bench_start := func(args: Dictionary) -> Variant:
		if _active_manual_bench != null and is_instance_valid(_active_manual_bench):
			return "bench_start: already recording '%s' (use bench_stop first)" % (
				_active_manual_bench._manual_label
			)
		var label: String = str(args.get("label", "manual")).strip_edges()
		if label.is_empty():
			label = "manual"
		var benchmark := StreamingBenchmark.new()
		benchmark.name = "StreamingBenchmarkManual"
		console.get_tree().root.add_child(benchmark)
		benchmark.init_manual_mode(streaming_manager, cell_manager, camera, console, label)
		_active_manual_bench = benchmark
		return "bench_start: recording as '%s' — use bench_stop to finalize" % label

	var run_bench_stop := func(_args: Dictionary) -> Variant:
		if _active_manual_bench == null or not is_instance_valid(_active_manual_bench):
			return "bench_stop: no active manual benchmark (use bench_start first)"
		var label := _active_manual_bench._manual_label
		_active_manual_bench.stop_manual()
		# stop_manual clears _active_manual_bench itself
		return "bench_stop: finalized '%s' — CSV + JSON written to user://benchmark_results/" % label

	var start_params: Array[CommandRegistry.ParameterInfo] = [
		CommandRegistry.ParameterInfo.new(
			"label", TYPE_STRING, "optional label embedded in filename", false, "manual"
		),
	]

	console.register_command(
		"bench_start", run_bench_start,
		"Start a manual measurement block (user drives the camera). Use bench_stop to finalize.",
		"debug",
		PackedStringArray([]),
		start_params,
		PackedStringArray(["bench_start village_dense", "bench_start vivec_canton"]),
	)
	console.register_command(
		"bench_stop", run_bench_stop,
		"Finalize the active manual measurement block (see bench_start)",
		"debug",
		PackedStringArray([]),
	)

#endregion
