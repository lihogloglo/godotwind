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

## Streaming event log for per-model diagnostics
## Each entry: {frame: int, event: String, detail: String}
var _event_log: Array[Dictionary] = []

## Track visible objects per frame to detect appear/disappear patterns
var _prev_visible_count: int = -1
var _visibility_change_count: int = 0

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

	# Connect to streaming manager signals for lifecycle event tracking
	if _streaming_manager:
		if _streaming_manager.has_signal("cell_loading"):
			_streaming_manager.cell_loading.connect(_on_cell_loading)
		if _streaming_manager.has_signal("cell_loaded"):
			_streaming_manager.cell_loaded.connect(_on_cell_loaded)
		if _streaming_manager.has_signal("cell_unloaded"):
			_streaming_manager.cell_unloaded.connect(_on_cell_unloaded)

	Log.info("tools", "StreamingBenchmark: Started (%d waypoints, %s mode)" % [
		_waypoints.size(), "quick" if _quick_mode else "full"
	])


func _process(delta: float) -> void:
	# Isolation mode: settle timer before starting measurement
	if _isolate_mode and _settling:
		_process_isolate_settle(delta)
		return

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

	# In sweep mode, feed results to sweep handler instead of printing individual summary
	if _sweep_mode:
		_on_sweep_pass_complete(results)
		return

	# In isolate mode, feed results to isolate handler
	if _isolate_mode:
		_on_isolate_pass_complete(results)
		return

	_print_summary(results)
	_save_json_summary(results)

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
	var file_path := "%s/benchmark_%s.csv" % [dir_path, timestamp]

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
	var file_path := "%s/events_%s.csv" % [dir_path, timestamp]

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

	var run_lod_sweep := func(args: Dictionary) -> Variant:
		var benchmark := StreamingBenchmark.new()
		benchmark.name = "StreamingBenchmarkLODSweep"
		console.get_tree().root.add_child(benchmark)
		benchmark.init_lod_sweep(streaming_manager, cell_manager, camera, console)
		return "LOD threshold sweep started (6 passes)..."

	console.register_command(
		"benchmark_lod_sweep", run_lod_sweep,
		"Sweep mesh_lod_threshold (0.25/0.5/1/2/4/8) and compare FPS",
		"debug",
		PackedStringArray(["lod_sweep"]),
	)

	# Shorthand aliases
	console.register_command(
		"benchmark", run_quick,
		"Run quick streaming benchmark (~18s). Alias for benchmark_streaming_quick",
		"debug",
		PackedStringArray(["bench"]),
	)


#endregion


## Register isolation benchmark command separately (needs SubsystemToggles, which initializes after streaming manager)
static func register_isolate_command(console: Node, streaming_manager: Variant, cell_manager: Variant, camera: Camera3D, toggles: RefCounted) -> void:
	var run_isolate := func(args: Dictionary) -> Variant:
		var benchmark := StreamingBenchmark.new()
		benchmark.name = "StreamingBenchmarkIsolate"
		console.get_tree().root.add_child(benchmark)
		benchmark.init_isolate_mode(streaming_manager, cell_manager, camera, console, toggles)
		return "Isolation benchmark started — baseline + one pass per subsystem..."

	console.register_command(
		"benchmark_isolate", run_isolate,
		"Run per-subsystem cost isolation (baseline + disable each, ~4min)",
		"debug",
		PackedStringArray(["bench_isolate", "isolate"]),
	)


#region LOD Threshold Sweep

const LOD_SWEEP_THRESHOLDS: Array[float] = [0.25, 0.5, 1.0, 2.0, 4.0, 8.0]

var _sweep_mode: bool = false
var _sweep_index: int = 0
var _sweep_results: Array[Dictionary] = []
var _sweep_console: Node = null
var _sweep_camera: Camera3D = null
var _sweep_streaming_manager: NativeStreamingManagerScript = null
var _sweep_cell_manager: CellManagerScript = null


func init_lod_sweep(sm: NativeStreamingManagerScript, cm: CellManagerScript,
		cam: Camera3D, console: Node = null) -> void:
	_sweep_mode = true
	_sweep_index = 0
	_sweep_results.clear()
	_sweep_console = console
	_sweep_camera = cam
	_sweep_streaming_manager = sm
	_sweep_cell_manager = cm
	_start_sweep_pass()


func _start_sweep_pass() -> void:
	if _sweep_index >= LOD_SWEEP_THRESHOLDS.size():
		_finish_sweep()
		return

	var threshold := LOD_SWEEP_THRESHOLDS[_sweep_index]
	var vp := get_viewport()
	if vp:
		vp.mesh_lod_threshold = threshold
	Log.info("tools", "LOD sweep: pass %d/%d — threshold=%.2f px" % [
		_sweep_index + 1, LOD_SWEEP_THRESHOLDS.size(), threshold])

	# Run quick benchmark (orbit only)
	_streaming_manager = _sweep_streaming_manager
	_cell_manager = _sweep_cell_manager
	_camera = _sweep_camera
	_console = _sweep_console
	_owns_streaming = false
	_quick_mode = true
	_setup_ui()
	_build_waypoints()
	_start_benchmark()


func _on_sweep_pass_complete(results: Dictionary) -> void:
	var threshold := LOD_SWEEP_THRESHOLDS[_sweep_index]
	results["mesh_lod_threshold"] = threshold
	_sweep_results.append(results)

	_sweep_index += 1
	if _sweep_index < LOD_SWEEP_THRESHOLDS.size():
		# Reset and run next pass
		_frame_log.clear()
		_event_log.clear()
		_running = false
		_finished = false
		_start_sweep_pass()
	else:
		_finish_sweep()


func _finish_sweep() -> void:
	# Restore default threshold
	var vp := get_viewport()
	if vp:
		vp.mesh_lod_threshold = 1.0

	var lines: PackedStringArray = PackedStringArray()
	lines.append("========== LOD THRESHOLD SWEEP RESULTS ==========")
	lines.append("%-12s %8s %8s %8s %8s %10s" % ["threshold", "avg_fps", "p50_ms", "p95_ms", "p99_ms", "draw_calls"])
	lines.append("------------------------------------------------------------")
	for r: Dictionary in _sweep_results:
		lines.append("%-12.2f %8.1f %8.1f %8.1f %8.1f %10d" % [
			r.get("mesh_lod_threshold", 0.0),
			r.get("avg_fps", 0.0),
			r.get("p50_ms", 0.0),
			r.get("p95_ms", 0.0),
			r.get("p99_ms", 0.0),
			r.get("avg_draw_calls", 0),
		])
	lines.append("==================================================")

	var output := "\n".join(lines)
	Log.info("tools", output)
	if _sweep_console and _sweep_console.has_method("print_line"):
		for line: String in lines:
			_sweep_console.print_line(line)

	# Save sweep CSV
	_save_sweep_csv()
	queue_free()


func _save_sweep_csv() -> void:
	var dir_path := "user://benchmark_results"
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var timestamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var file_path := "%s/lod_sweep_%s.csv" % [dir_path, timestamp]
	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if not file:
		return

	file.store_line("threshold,avg_fps,avg_ms,p50_ms,p95_ms,p99_ms,max_ms,avg_draw_calls,peak_draw_calls,peak_vram_mb")
	for r: Dictionary in _sweep_results:
		file.store_line("%.2f,%.1f,%.2f,%.2f,%.2f,%.2f,%.2f,%d,%d,%.0f" % [
			r.get("mesh_lod_threshold", 0.0),
			r.get("avg_fps", 0.0),
			r.get("avg_time_ms", 0.0),
			r.get("p50_ms", 0.0),
			r.get("p95_ms", 0.0),
			r.get("p99_ms", 0.0),
			r.get("max_time_ms", 0.0),
			r.get("avg_draw_calls", 0),
			r.get("peak_draw_calls", 0),
			r.get("peak_vram_mb", 0.0),
		])
	file.close()
	Log.info("tools", "LOD sweep CSV saved to %s" % file_path)

#endregion


#region JSON Summary

## Save a JSON summary alongside the CSV for historical comparison
func _save_json_summary(results: Dictionary, toggle_state: Dictionary = {}) -> String:
	var dir_path := "user://benchmark_results"
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var timestamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var file_path := "%s/summary_%s.json" % [dir_path, timestamp]

	var summary := {
		"timestamp": Time.get_datetime_string_from_system(),
		"mode": "quick" if _quick_mode else "full",
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


#region Subsystem Isolation Benchmark

## Isolation mode: runs baseline + one pass per subsystem with that subsystem disabled.
## Reports per-subsystem cost ranking sorted by FPS impact.
var _isolate_mode: bool = false
var _isolate_index: int = -1  # -1 = baseline, 0..N = each subsystem
var _isolate_subsystem_names: Array[String] = []
var _isolate_results: Array[Dictionary] = []
var _isolate_toggles: RefCounted = null  # SubsystemToggles reference
var _isolate_console: Node = null
var _isolate_camera: Camera3D = null
var _isolate_streaming_manager: NativeStreamingManagerScript = null
var _isolate_cell_manager: CellManagerScript = null

## Settle timer — 2s pause between toggle change and measurement start
var _settle_timer: float = 0.0
var _settling: bool = false


func init_isolate_mode(
	sm: NativeStreamingManagerScript, cm: CellManagerScript,
	cam: Camera3D, console: Node, toggles: RefCounted
) -> void:
	_isolate_mode = true
	_isolate_index = -1  # Start with baseline
	_isolate_results.clear()
	_isolate_console = console
	_isolate_camera = cam
	_isolate_streaming_manager = sm
	_isolate_cell_manager = cm
	_isolate_toggles = toggles
	_isolate_subsystem_names = toggles.get_flag_names()

	var pass_count := _isolate_subsystem_names.size() + 1  # baseline + each subsystem
	var est_time := pass_count * 20  # ~20s per quick pass
	Log.info("tools", "Isolation benchmark: %d passes (~%ds). Baseline first, then disable one subsystem per pass." % [pass_count, est_time])
	if _isolate_console and _isolate_console.has_method("print_line"):
		_isolate_console.print_line("Isolation benchmark: %d passes (~%ds estimated)" % [pass_count, est_time])

	# Ensure all subsystems are ON for baseline
	toggles.enable_all()
	_start_isolate_pass()


func _start_isolate_pass() -> void:
	if _isolate_index >= _isolate_subsystem_names.size():
		_finish_isolate()
		return

	# Apply toggle for this pass
	if _isolate_index == -1:
		# Baseline: all ON
		_isolate_toggles.enable_all()
		Log.info("tools", "Isolation pass: BASELINE (all ON)")
	else:
		# Disable one subsystem
		var name: String = _isolate_subsystem_names[_isolate_index]
		_isolate_toggles.enable_all()
		_isolate_toggles.set_flag(name, false)
		Log.info("tools", "Isolation pass: %s OFF" % name)

	# Settle for 2s before starting measurement
	_settling = true
	_settle_timer = 2.0


func _process_isolate_settle(delta: float) -> void:
	if not _settling:
		return
	_settle_timer -= delta
	if _settle_timer <= 0.0:
		_settling = false
		# Now start the actual benchmark pass
		_streaming_manager = _isolate_streaming_manager
		_cell_manager = _isolate_cell_manager
		_camera = _isolate_camera
		_console = _isolate_console
		_owns_streaming = false
		_quick_mode = true
		_sweep_mode = false
		_frame_log.clear()
		_event_log.clear()
		_running = false
		_finished = false
		_setup_ui()
		_build_waypoints()
		_start_benchmark()


func _on_isolate_pass_complete(results: Dictionary) -> void:
	if _isolate_index == -1:
		results["subsystem"] = "BASELINE"
	else:
		results["subsystem"] = _isolate_subsystem_names[_isolate_index]
	_isolate_results.append(results)

	_isolate_index += 1
	if _isolate_index < _isolate_subsystem_names.size():
		_frame_log.clear()
		_event_log.clear()
		_running = false
		_finished = false
		_start_isolate_pass()
	else:
		_finish_isolate()


func _finish_isolate() -> void:
	# Restore all subsystems
	if _isolate_toggles:
		_isolate_toggles.reset()

	if _isolate_results.is_empty():
		queue_free()
		return

	# Extract baseline
	var baseline_fps: float = _isolate_results[0].get("avg_fps", 1.0)
	var baseline_ms: float = _isolate_results[0].get("avg_time_ms", 999.0)

	# Calculate per-subsystem cost and sort by impact
	var costs: Array[Dictionary] = []
	for i in range(1, _isolate_results.size()):
		var r: Dictionary = _isolate_results[i]
		var fps_without: float = r.get("avg_fps", 0.0)
		var ms_without: float = r.get("avg_time_ms", 0.0)
		var fps_delta: float = fps_without - baseline_fps
		var ms_saved: float = baseline_ms - ms_without
		costs.append({
			"subsystem": r.get("subsystem", "?"),
			"fps_with_disabled": fps_without,
			"fps_delta": fps_delta,
			"ms_saved": ms_saved,
		})
	costs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.ms_saved > b.ms_saved)

	# Print report
	var lines: PackedStringArray = PackedStringArray()
	lines.append("========== SUBSYSTEM ISOLATION RESULTS ==========")
	lines.append("Baseline: %.1f FPS (%.1f ms)" % [baseline_fps, baseline_ms])
	lines.append("")
	lines.append("%-16s %10s %10s %10s" % ["subsystem", "fps_delta", "ms_saved", "fps_without"])
	lines.append("--------------------------------------------------")
	for c: Dictionary in costs:
		var sign: String = "+" if c.fps_delta >= 0 else ""
		lines.append("%-16s %s%9.1f %9.1fms %10.1f" % [
			c.subsystem, sign, c.fps_delta, c.ms_saved, c.fps_with_disabled
		])
	lines.append("==================================================")
	lines.append("Positive fps_delta = disabling HELPS (subsystem costs performance)")

	var output := "\n".join(lines)
	Log.info("tools", output)
	if _isolate_console and _isolate_console.has_method("print_line"):
		for line: String in lines:
			_isolate_console.print_line(line)

	# Save CSV
	_save_isolate_csv()
	queue_free()


func _save_isolate_csv() -> void:
	var dir_path := "user://benchmark_results"
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var timestamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var file_path := "%s/isolate_%s.csv" % [dir_path, timestamp]
	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if not file:
		return

	file.store_line("subsystem,avg_fps,avg_ms,p50_ms,p95_ms,p99_ms,max_ms,avg_draw_calls,peak_vram_mb")
	for r: Dictionary in _isolate_results:
		file.store_line("%s,%.1f,%.2f,%.2f,%.2f,%.2f,%.2f,%d,%.0f" % [
			r.get("subsystem", "?"),
			r.get("avg_fps", 0.0),
			r.get("avg_time_ms", 0.0),
			r.get("p50_ms", 0.0),
			r.get("p95_ms", 0.0),
			r.get("p99_ms", 0.0),
			r.get("max_time_ms", 0.0),
			r.get("avg_draw_calls", 0),
			r.get("peak_vram_mb", 0.0),
		])
	file.close()
	Log.info("tools", "Isolation CSV saved to %s" % file_path)

#endregion
