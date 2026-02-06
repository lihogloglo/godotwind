## StreamingBenchmark — Automated streaming pipeline performance benchmark
##
## Runs a scripted camera path through the world and logs per-frame metrics.
## Two modes of operation:
##   1. Standalone: Open streaming_benchmark.tscn directly (self-initializes)
##   2. Console command: Called from world_explorer via `benchmark_streaming`
##
## Outputs CSV to user://benchmark_results/ and prints summary to console/log.
class_name StreamingBenchmark
extends Node3D

const DU := preload("res://src/core/world/distance_utils.gd")
const NativeStreamingManagerScript := preload("res://src/core/world/native_streaming_manager.gd")
const CellManagerScript := preload("res://src/core/world/cell_manager.gd")

#region Signals
signal benchmark_complete(results: Dictionary)
#endregion


#region Constants

## Seyda Neen cell coordinates — default Morrowind spawn area
const SPAWN_CELL := Vector2i(-2, -9)

## Camera height above terrain (fly camera style)
const CAMERA_HEIGHT := 100.0

## Segment names for reporting
const SEGMENT_NAMES: Array[String] = [
	"idle", "approach", "orbit", "sprint", "teleport", "return"
]

## CSV column headers
const CSV_HEADERS := "frame,time_ms,fps,node_count,draw_calls,rendered_objects,primitives,queue_size,loaded_cells,async_requests,cam_x,cam_y,cam_z,memory_static,segment"

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

## Whether we own the streaming manager (standalone mode) or borrowed it
var _owns_streaming: bool = false

## Waypoints defining the camera path
var _waypoints: Array[Waypoint] = []
var _current_waypoint_index: int = 0
var _waypoint_elapsed: float = 0.0
var _waypoint_start_pos: Vector3 = Vector3.ZERO
var _current_segment_index: int = 0

## Frame log: array of PackedFloat64Array (one per frame)
var _frame_log: Array[PackedFloat64Array] = []
var _last_frame_time_ms: float = 0.0

## Running state
var _running: bool = false
var _finished: bool = false
var _quick_mode: bool = false

## UI references (created in standalone, optional in console mode)
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

#endregion


#region Initialization

func _ready() -> void:
	# If we have no streaming manager, we're in standalone mode — self-initialize
	if not _streaming_manager:
		_init_standalone()


func _init_standalone() -> void:
	Log.info("tools", "StreamingBenchmark: Standalone mode — initializing systems")
	_owns_streaming = true

	# Setup environment
	_setup_environment()

	# Setup camera
	_setup_camera()

	# Setup UI
	_setup_ui()

	# Initialize data (BSA + ESM must be loaded)
	var data_path: String = SettingsManager.get_data_path()
	if data_path.is_empty():
		data_path = SettingsManager.auto_detect_installation()

	if data_path.is_empty():
		Log.error("tools", "StreamingBenchmark: No Morrowind data path found")
		return

	# Load BSA if not already loaded
	if BSAManager.get_archive_count() == 0:
		BSAManager.load_archives_from_directory(data_path)

	# Load ESM if not already loaded
	if ESMManager.cells.is_empty():
		var esm_file: String = SettingsManager.get_esm_file()
		var esm_path := data_path.path_join(esm_file)
		var err := ESMManager.load_file(esm_path)
		if err != OK:
			Log.error("tools", "StreamingBenchmark: Failed to load ESM: %s" % error_string(err))
			return

	# Create cell manager
	_cell_manager = CellManagerScript.new()
	_cell_manager.load_npcs = false
	_cell_manager.load_creatures = false
	var pool_container := Node3D.new()
	pool_container.name = "PoolContainer"
	pool_container.visible = false
	add_child(pool_container)
	_cell_manager.init_object_pool(pool_container)
	_cell_manager.preload_common_models()

	# Create streaming manager
	var nsm := Node3D.new()
	nsm.set_script(NativeStreamingManagerScript)
	nsm.name = "NativeStreamingManager"
	nsm.load_radius_cells = 3
	nsm.debug_enabled = false
	add_child(nsm)
	_streaming_manager = nsm

	_streaming_manager.initialize(_cell_manager, null)

	# Build waypoints and start
	_build_waypoints()
	_start_benchmark()


## Initialize for console command mode (uses existing systems)
func init_console_mode(
	streaming_manager: NativeStreamingManagerScript,
	cell_manager: CellManagerScript,
	camera: Camera3D,
	console: Node = null,
	quick: bool = false
) -> void:
	_streaming_manager = streaming_manager
	_cell_manager = cell_manager
	_camera = camera
	_console = console
	_quick_mode = quick
	_owns_streaming = false

	_setup_ui()
	_build_waypoints()
	_start_benchmark()

#endregion


#region Environment & Camera Setup

func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.4, 0.5, 0.7)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.7)
	env.ambient_light_energy = 0.5

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 30, 0)
	sun.shadow_enabled = true
	sun.light_energy = 1.0
	add_child(sun)


func _setup_camera() -> void:
	var rig := Node3D.new()
	rig.name = "CameraRig"
	add_child(rig)

	_camera = Camera3D.new()
	_camera.fov = 75.0
	_camera.far = 6000.0
	rig.add_child(_camera)
	_camera.current = true

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

	var center := DU.cell_to_world_center(SPAWN_CELL, CAMERA_HEIGHT)

	# Segment 1: Idle (3s) — measure initial loading
	_segment_starts.append(_waypoints.size())
	_waypoints.append(Waypoint.new(center, center + Vector3(0, -50, -100), 3.0))

	# Segment 2: Approach (5s) — from 800m away toward center
	_segment_starts.append(_waypoints.size())
	var approach_start := center + Vector3(0, 50, 800)
	var look_down := Vector3(0, -50, -100)  # slight downward look target offset
	_waypoints.append(Waypoint.new(approach_start, center, 0.0, true))  # teleport to start
	_waypoints.append(Waypoint.new(center, center + look_down, 5.0))  # fly toward center

	# Segment 3: Orbit (10s) — 200m circle, split into 4 quadrants
	_segment_starts.append(_waypoints.size())
	var orbit_radius := 200.0
	var orbit_segments := 8
	var angle_step := TAU / float(orbit_segments)
	for i in range(orbit_segments + 1):
		var angle := float(i) * angle_step
		var orbit_pos := center + Vector3(cos(angle) * orbit_radius, 0, sin(angle) * orbit_radius)
		_waypoints.append(Waypoint.new(orbit_pos, center, 10.0 / float(orbit_segments)))

	if _quick_mode:
		# Quick mode ends after orbit
		_segment_starts.append(_waypoints.size())  # sprint placeholder
		_segment_starts.append(_waypoints.size())  # teleport placeholder
		_segment_starts.append(_waypoints.size())  # return placeholder
		return

	# Segment 4: Sprint (5s) — 600m north
	_segment_starts.append(_waypoints.size())
	var sprint_end := center + Vector3(0, 0, -600)  # north = -Z in Godot
	_waypoints.append(Waypoint.new(sprint_end, sprint_end + look_down, 5.0))

	# Segment 5: Teleport (3s) — 3 jumps, 500m apart, 1s pause between
	_segment_starts.append(_waypoints.size())
	var tp_base := sprint_end
	for i in range(3):
		var tp_target := tp_base + Vector3(500.0 * (i + 1), 0, 0)
		_waypoints.append(Waypoint.new(tp_target, tp_target + look_down, 0.0, true))  # instant teleport
		_waypoints.append(Waypoint.new(tp_target, tp_target + look_down, 1.0))  # hold 1s

	# Segment 6: Return (4s) — back to center
	_segment_starts.append(_waypoints.size())
	_waypoints.append(Waypoint.new(center, center + look_down, 4.0))

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
	if wp.look_at != wp.position:
		_camera.look_at(wp.look_at)

	# Start streaming if in standalone mode
	if _owns_streaming and _streaming_manager:
		_streaming_manager.set_camera(_camera)

	Log.info("tools", "StreamingBenchmark: Started (%d waypoints, %s mode)" % [
		_waypoints.size(), "quick" if _quick_mode else "full"
	])


func _process(delta: float) -> void:
	if not _running or _finished:
		return

	_last_frame_time_ms = delta * 1000.0

	# Log this frame's metrics
	_log_frame()

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

	# Interpolate from start position to waypoint target
	var t := clampf(_waypoint_elapsed / wp.duration, 0.0, 1.0)
	var smoothed_t := t * t * (3.0 - 2.0 * t)  # smoothstep
	_camera.global_position = _waypoint_start_pos.lerp(wp.position, smoothed_t)

	# Look at target
	if wp.look_at.distance_squared_to(_camera.global_position) > 1.0:
		_camera.look_at(wp.look_at)

	# Advance to next waypoint when done
	if _waypoint_elapsed >= wp.duration:
		_camera.global_position = wp.position
		_advance_to_next_waypoint()


func _advance_to_next_waypoint() -> void:
	_waypoint_start_pos = _camera.global_position
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
	entry.resize(15)
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
	_frame_log.append(entry)


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
	_print_summary(results)

	benchmark_complete.emit(results)

	# In console mode, clean up after a short delay
	if not _owns_streaming:
		get_tree().create_timer(1.0).timeout.connect(queue_free)


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
	for entry in _frame_log:
		peak_queue = maxf(peak_queue, entry[7])
		peak_cells = maxf(peak_cells, entry[8])
		peak_nodes = maxf(peak_nodes, entry[3])
		peak_draw_calls = maxf(peak_draw_calls, entry[4])
		total_draw_calls += entry[4]

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
	var file_path := "%s/benchmark_%s.csv" % [dir_path, timestamp]

	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if not file:
		Log.error("tools", "StreamingBenchmark: Failed to write CSV to %s" % file_path)
		return

	file.store_line(CSV_HEADERS)
	for entry in _frame_log:
		var line := "%d,%.2f,%.1f,%d,%d,%d,%d,%d,%d,%d,%.1f,%.1f,%.1f,%.0f,%d" % [
			int(entry[0]), entry[1], entry[2], int(entry[3]), int(entry[4]),
			int(entry[5]), int(entry[6]), int(entry[7]), int(entry[8]),
			int(entry[9]), entry[10], entry[11], entry[12], entry[13],
			int(entry[14])
		]
		file.store_line(line)

	file.close()
	Log.info("tools", "StreamingBenchmark: CSV saved to %s" % file_path)

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


#region Console Command Helpers

## Register benchmark console commands on a Console node
## streaming_manager: NativeStreamingManager (Node3D), cell_manager: CellManager (RefCounted)
static func register_console_commands(console: Node, streaming_manager: Variant, cell_manager: Variant, camera: Camera3D) -> void:
	var run_full := func(args: Dictionary) -> Variant:
		var benchmark := StreamingBenchmark.new()
		benchmark.name = "StreamingBenchmark"
		console.get_tree().root.add_child(benchmark)
		benchmark.init_console_mode(streaming_manager, cell_manager, camera, console, false)
		return "Streaming benchmark started (full, ~30s)..."

	var run_quick := func(args: Dictionary) -> Variant:
		var benchmark := StreamingBenchmark.new()
		benchmark.name = "StreamingBenchmark"
		console.get_tree().root.add_child(benchmark)
		benchmark.init_console_mode(streaming_manager, cell_manager, camera, console, true)
		return "Streaming benchmark started (quick, ~18s)..."

	console.register_command(
		"benchmark_streaming", run_full,
		"Run streaming benchmark (full, ~30s)",
		"debug",
		PackedStringArray(["bench_stream"]),
	)
	console.register_command(
		"benchmark_streaming_quick", run_quick,
		"Quick streaming benchmark (~18s, idle+approach+orbit only)",
		"debug",
		PackedStringArray(["bench_quick"]),
	)

#endregion
