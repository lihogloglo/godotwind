## DebugSystem - Unified debugging and profiling system for Godotwind
##
## Merges F4 profiling dump, F9 diagnostic overlay, and F11 crash reporter into
## a single cohesive system with auto-test capabilities.
##
## Features:
## - F4: Dump full profiling report to console and log file
## - F9: Toggle real-time diagnostic overlay
## - F11: Manual state dump for crash analysis
## - F12: Toggle auto-test mode (automated camera movement for streaming tests)
##
## Auto-test mode:
## - Automatically moves camera through the world
## - No user input required - can be triggered programmatically
## - Captures errors, warnings, and performance metrics
## - Generates comprehensive test report
##
## Usage:
##   var debug_system := DebugSystemScript.new()
##   add_child(debug_system)
##   debug_system.initialize(world_explorer, fly_camera, world_streaming_manager)
##
##   # Start auto-test programmatically
##   debug_system.start_auto_test()
class_name DebugSystem
extends Node


## Emitted when auto-test completes
signal auto_test_completed(report: Dictionary)
## Emitted when an issue is detected
signal issue_detected(severity: String, message: String)


#region Configuration

## Auto-test configuration
@export_group("Auto-Test")
## Enable auto-test on startup (for headless/automated testing)
@export var auto_test_on_startup: bool = false
## Delay before starting auto-test on startup (seconds)
@export var auto_test_startup_delay: float = 5.0
## Camera movement speed during auto-test (m/s)
@export var auto_test_speed: float = 80.0
## Time to wait at each waypoint (seconds)
@export var waypoint_wait_time: float = 3.0
## Maximum auto-test duration (seconds, 0 = unlimited)
@export var max_test_duration: float = 300.0

## Debug overlay configuration
@export_group("Overlay")
## FPS warning threshold
@export var fps_warning: float = 30.0
## FPS error threshold
@export var fps_error: float = 15.0
## Queue warning threshold
@export var queue_warning: int = 100
## Queue error threshold
@export var queue_error: int = 500

## Logging configuration
@export_group("Logging")
## Path for crash/debug logs
@export var log_path: String = "user://logs/debug_report.txt"
## Write interval in frames
@export var write_interval_frames: int = 60

#endregion


#region State

## Test state
enum TestState { IDLE, RUNNING, PAUSED, COMPLETED }
var _test_state: TestState = TestState.IDLE

## Overlay visibility
var _overlay_visible: bool = false

## References
var _world_explorer: Node3D = null
var _fly_camera: Camera3D = null
var _world_streaming_manager: Node = null
var _cell_manager: RefCounted = null
var _profiler: PerformanceProfiler = null
var _streaming_profiler: StreamingProfiler = null

## UI elements
var _overlay_canvas: CanvasLayer = null
var _overlay_panel: PanelContainer = null
var _fps_label: Label = null
var _queue_label: Label = null
var _tier_label: Label = null
var _status_label: Label = null
var _log_feed: RichTextLabel = null
var _error_feed: RichTextLabel = null

## Frame tracking
var _frame_times: Array[float] = []
const FRAME_SAMPLES: int = 120

## Error/warning capture
var _recent_errors: Array[Dictionary] = []
var _recent_logs: Array[Dictionary] = []
const MAX_ERRORS: int = 50
const MAX_LOGS: int = 30

## Operation log for crash reports
var _operation_log: Array[String] = []
const MAX_OPERATIONS: int = 100

## Auto-test state
var _test_start_time: float = 0.0
var _waypoints: Array[Dictionary] = []
var _current_waypoint_idx: int = 0
var _is_moving: bool = false
var _target_position: Vector3 = Vector3.ZERO
var _wait_timer: float = 0.0

## Test metrics
var _test_metrics: Dictionary = {
	"waypoints_visited": 0,
	"errors_captured": 0,
	"warnings_captured": 0,
	"avg_fps": 0.0,
	"min_fps": 999.0,
	"max_frame_time_ms": 0.0,
	"cells_loaded": 0,
	"objects_loaded": 0,
}

## Session info
var _session_start_time: float = 0.0
var _frame_count: int = 0

#endregion


func _ready() -> void:
	_session_start_time = Time.get_ticks_msec() / 1000.0

	# Ensure logs directory exists
	var dir := DirAccess.open("user://")
	if dir and not dir.dir_exists("logs"):
		dir.make_dir("logs")

	_log_operation("DEBUG_SYSTEM_READY")

	# Auto-start test if configured
	if auto_test_on_startup:
		Logger.info("debug", "Auto-test scheduled to start in %.1f seconds" % auto_test_startup_delay)
		get_tree().create_timer(auto_test_startup_delay).timeout.connect(_on_auto_test_startup)


func _process(delta: float) -> void:
	_frame_count += 1

	# Track frame times
	var frame_ms := delta * 1000.0
	_frame_times.append(frame_ms)
	if _frame_times.size() > FRAME_SAMPLES:
		_frame_times.pop_front()

	# Update test metrics
	if frame_ms > _test_metrics.max_frame_time_ms:
		_test_metrics.max_frame_time_ms = frame_ms
	var current_fps := 1.0 / delta if delta > 0 else 0.0
	if current_fps < _test_metrics.min_fps and current_fps > 0:
		_test_metrics.min_fps = current_fps

	# Process auto-test
	if _test_state == TestState.RUNNING:
		_process_auto_test(delta)

		# Check max duration
		if max_test_duration > 0:
			var elapsed := (Time.get_ticks_msec() / 1000.0) - _test_start_time
			if elapsed >= max_test_duration:
				_complete_auto_test()

	# Update overlay if visible
	if _overlay_visible and _overlay_panel:
		_update_overlay()

	# Periodic state write
	if _frame_count % write_interval_frames == 0:
		_write_state_to_file()


func _input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return

	var key_event := event as InputEventKey
	if not key_event.pressed:
		return

	match key_event.keycode:
		KEY_F4:
			dump_profiling_report()
		KEY_F9:
			toggle_overlay()
		KEY_F11:
			dump_state_now()
		KEY_F12:
			toggle_auto_test()


#region Initialization

## Initialize the debug system with references to key components
func initialize(world_explorer: Node3D, fly_camera: Camera3D = null,
				wsm: Node = null, cell_mgr: RefCounted = null,
				profiler: PerformanceProfiler = null, streaming_profiler: StreamingProfiler = null) -> void:
	_world_explorer = world_explorer
	_fly_camera = fly_camera
	_world_streaming_manager = wsm
	_cell_manager = cell_mgr
	_profiler = profiler
	_streaming_profiler = streaming_profiler

	# Try to get references from world_explorer if not provided
	if not _fly_camera and _world_explorer:
		_fly_camera = _world_explorer.get("fly_camera")
		if not _fly_camera:
			_fly_camera = _world_explorer.get_node_or_null("FlyCamera")

	if not _world_streaming_manager and _world_explorer:
		_world_streaming_manager = _world_explorer.get("world_streaming_manager")

	if not _cell_manager and _world_explorer:
		_cell_manager = _world_explorer.get("cell_manager")

	if not _profiler and _world_explorer:
		_profiler = _world_explorer.get("profiler")

	# Connect to streaming signals
	_connect_streaming_signals()

	# Setup default waypoints
	_setup_default_waypoints()

	# Setup overlay UI
	_setup_overlay()

	_log_operation("DEBUG_SYSTEM_INITIALIZED")
	Logger.info("debug", "Initialized - F4: Profile, F9: Overlay, F11: Dump, F12: Auto-test")


func _connect_streaming_signals() -> void:
	if not _world_streaming_manager:
		return

	# Connect to cell load signals
	if _world_streaming_manager.has_signal("cell_loaded"):
		if not _world_streaming_manager.cell_loaded.is_connected(_on_cell_loaded):
			_world_streaming_manager.cell_loaded.connect(_on_cell_loaded)

	if _world_streaming_manager.has_signal("cell_unloaded"):
		if not _world_streaming_manager.cell_unloaded.is_connected(_on_cell_unloaded):
			_world_streaming_manager.cell_unloaded.connect(_on_cell_unloaded)


func _on_cell_loaded(grid: Vector2i, object_count: int) -> void:
	_log_operation("CELL_LOADED: (%d, %d) with %d objects" % [grid.x, grid.y, object_count])
	_test_metrics.cells_loaded += 1
	_test_metrics.objects_loaded += object_count
	_add_log("Cell (%d,%d) loaded: %d objects" % [grid.x, grid.y, object_count], "info")


func _on_cell_unloaded(grid: Vector2i) -> void:
	_log_operation("CELL_UNLOADED: (%d, %d)" % [grid.x, grid.y])

#endregion


#region Overlay UI

func _setup_overlay() -> void:
	_overlay_canvas = CanvasLayer.new()
	_overlay_canvas.name = "DebugOverlay"
	_overlay_canvas.layer = 100
	add_child(_overlay_canvas)

	# Main panel
	_overlay_panel = PanelContainer.new()
	_overlay_panel.name = "DebugPanel"
	_overlay_panel.visible = false

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.1, 0.92)
	style.border_color = Color(0.3, 0.5, 0.7, 0.8)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(12)
	_overlay_panel.add_theme_stylebox_override("panel", style)

	_overlay_panel.position = Vector2(10, 10)
	_overlay_panel.custom_minimum_size = Vector2(360, 0)
	_overlay_canvas.add_child(_overlay_panel)

	# Content VBox
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	_overlay_panel.add_child(vbox)

	# Title row
	var title_row := HBoxContainer.new()
	vbox.add_child(title_row)

	var title := Label.new()
	title.text = "DEBUG SYSTEM"
	title.add_theme_font_size_override("font_size", 14)
	title.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	title_row.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(spacer)

	_status_label = Label.new()
	_status_label.text = "IDLE"
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.add_theme_color_override("font_color", Color.GREEN)
	title_row.add_child(_status_label)

	# Separator
	vbox.add_child(_create_separator())

	# Performance section
	var perf_header := Label.new()
	perf_header.text = "Performance"
	perf_header.add_theme_font_size_override("font_size", 11)
	perf_header.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	vbox.add_child(perf_header)

	_fps_label = _create_stat_label("FPS: --")
	vbox.add_child(_fps_label)

	_queue_label = _create_stat_label("Queue: --")
	vbox.add_child(_queue_label)

	_tier_label = _create_stat_label("NEAR: -- | MID: -- | FAR: --")
	vbox.add_child(_tier_label)

	# Separator
	vbox.add_child(_create_separator())

	# Auto-test section
	var test_header := Label.new()
	test_header.text = "Auto-Test Status"
	test_header.add_theme_font_size_override("font_size", 11)
	test_header.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	vbox.add_child(test_header)

	# Log feed
	_log_feed = RichTextLabel.new()
	_log_feed.bbcode_enabled = true
	_log_feed.custom_minimum_size = Vector2(340, 120)
	_log_feed.add_theme_font_size_override("normal_font_size", 10)
	_log_feed.scroll_following = true
	vbox.add_child(_log_feed)

	# Separator
	vbox.add_child(_create_separator())

	# Error feed
	var err_header := Label.new()
	err_header.text = "Errors & Warnings"
	err_header.add_theme_font_size_override("font_size", 11)
	err_header.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	vbox.add_child(err_header)

	_error_feed = RichTextLabel.new()
	_error_feed.bbcode_enabled = true
	_error_feed.custom_minimum_size = Vector2(340, 80)
	_error_feed.add_theme_font_size_override("normal_font_size", 10)
	_error_feed.scroll_following = true
	vbox.add_child(_error_feed)

	# Instructions
	var instructions := Label.new()
	instructions.text = "F4: Profile | F9: Hide | F11: Dump | F12: Test"
	instructions.add_theme_font_size_override("font_size", 9)
	instructions.add_theme_color_override("font_color", Color(0.4, 0.4, 0.5))
	vbox.add_child(instructions)


func _create_stat_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.95))
	return label


func _create_separator() -> HSeparator:
	var sep := HSeparator.new()
	sep.add_theme_constant_override("separation", 6)
	return sep


func _update_overlay() -> void:
	if not _overlay_panel or not _overlay_panel.visible:
		return

	# FPS calculation
	var fps := _calculate_fps()
	var frame_time := _calculate_frame_time()
	var fps_color := "green" if fps >= fps_warning else ("yellow" if fps >= fps_error else "red")
	_fps_label.text = "FPS: %.1f (%.1fms)" % [fps, frame_time]
	_fps_label.add_theme_color_override("font_color", Color.GREEN if fps >= fps_warning else (Color.YELLOW if fps >= fps_error else Color.RED))

	# Queue info
	var queue_size := _get_queue_size()
	var queue_color := Color.WHITE
	if queue_size > queue_error:
		queue_color = Color.RED
	elif queue_size > queue_warning:
		queue_color = Color.YELLOW
	_queue_label.text = "Queue: %d objects" % queue_size
	_queue_label.add_theme_color_override("font_color", queue_color)

	# Tier counts
	var tiers := _get_tier_counts()
	_tier_label.text = "NEAR: %d | MID: %d | FAR: %d" % [tiers.near, tiers.mid, tiers.far]

	# Status
	match _test_state:
		TestState.IDLE:
			_status_label.text = "IDLE"
			_status_label.add_theme_color_override("font_color", Color.GRAY)
		TestState.RUNNING:
			var elapsed := (Time.get_ticks_msec() / 1000.0) - _test_start_time
			_status_label.text = "TESTING %.0fs" % elapsed
			_status_label.add_theme_color_override("font_color", Color.CYAN)
		TestState.COMPLETED:
			_status_label.text = "COMPLETED"
			_status_label.add_theme_color_override("font_color", Color.GREEN)

	# Log feed
	_update_log_feed()

	# Error feed
	_update_error_feed()


func _update_log_feed() -> void:
	var text := ""
	for i in range(mini(_recent_logs.size(), 15)):
		var idx := _recent_logs.size() - 1 - i
		if idx < 0:
			break
		var entry: Dictionary = _recent_logs[idx]
		var time_str := "%.1fs" % entry.get("time", 0.0)
		var msg: String = entry.get("message", "")
		var level: String = entry.get("level", "info")

		var color := "white"
		match level:
			"info": color = "gray"
			"success": color = "green"
			"warning": color = "yellow"
			"error": color = "red"

		text = "[color=%s][%s] %s[/color]\n" % [color, time_str, msg] + text

	if text.is_empty():
		text = "[color=gray]No activity[/color]"

	_log_feed.text = text


func _update_error_feed() -> void:
	var text := ""
	for i in range(mini(_recent_errors.size(), 8)):
		var idx := _recent_errors.size() - 1 - i
		if idx < 0:
			break
		var entry: Dictionary = _recent_errors[idx]
		var time_str := "%.1fs" % entry.get("time", 0.0)
		var msg: String = entry.get("message", "")
		var level: String = entry.get("type", "error")

		var color := "red" if level == "error" else "yellow"
		var prefix := "ERR" if level == "error" else "WARN"

		text = "[color=%s][%s %s] %s[/color]\n" % [color, prefix, time_str, msg] + text

	if text.is_empty():
		text = "[color=green]No errors[/color]"

	_error_feed.text = text


func toggle_overlay() -> void:
	_overlay_visible = not _overlay_visible
	if _overlay_panel:
		_overlay_panel.visible = _overlay_visible
	Logger.info("debug", "Overlay: %s" % ("ON" if _overlay_visible else "OFF"))

#endregion


#region Auto-Test

func _setup_default_waypoints() -> void:
	_waypoints.clear()

	# Cell size in Godot units
	var cell_size: float = 8192.0

	# Key locations for comprehensive streaming test
	_waypoints = [
		# Start overview
		{"name": "Overview", "cell": Vector2i(0, 0), "height": 400.0, "wait": 2.0},

		# Seyda Neen area
		{"name": "Seyda Neen North", "cell": Vector2i(-2, -8), "height": 80.0, "wait": 3.0},
		{"name": "Seyda Neen", "cell": Vector2i(-2, -9), "height": 50.0, "wait": 4.0},
		{"name": "Seyda Neen South", "cell": Vector2i(-2, -10), "height": 60.0, "wait": 3.0},

		# West coast
		{"name": "West Coast 1", "cell": Vector2i(-4, -8), "height": 40.0, "wait": 3.0},
		{"name": "West Coast 2", "cell": Vector2i(-5, -7), "height": 40.0, "wait": 3.0},

		# Balmora
		{"name": "Balmora Approach", "cell": Vector2i(-3, -3), "height": 100.0, "wait": 3.0},
		{"name": "Balmora", "cell": Vector2i(-3, -2), "height": 60.0, "wait": 4.0},

		# Central Vvardenfell
		{"name": "Ascadian Isles", "cell": Vector2i(0, -5), "height": 80.0, "wait": 3.0},

		# Vivec
		{"name": "Vivec Approach", "cell": Vector2i(4, -7), "height": 120.0, "wait": 3.0},
		{"name": "Vivec", "cell": Vector2i(5, -6), "height": 80.0, "wait": 4.0},

		# Eastern area
		{"name": "Azura's Coast", "cell": Vector2i(8, -3), "height": 60.0, "wait": 3.0},
		{"name": "Sadrith Mora", "cell": Vector2i(11, 4), "height": 80.0, "wait": 4.0},

		# Red Mountain
		{"name": "Red Mountain", "cell": Vector2i(3, 6), "height": 300.0, "wait": 4.0},

		# Return to start
		{"name": "Final Overview", "cell": Vector2i(0, 0), "height": 500.0, "wait": 3.0},
	]


func _on_auto_test_startup() -> void:
	start_auto_test()


## Start the auto-test (can be called programmatically)
func start_auto_test() -> void:
	if _test_state == TestState.RUNNING:
		Logger.warn("debug", "Auto-test already running")
		return

	if not _fly_camera:
		push_error("[DebugSystem] Cannot start auto-test: fly_camera not set")
		return

	# Reset metrics
	_test_metrics = {
		"waypoints_visited": 0,
		"errors_captured": 0,
		"warnings_captured": 0,
		"avg_fps": 0.0,
		"min_fps": 999.0,
		"max_frame_time_ms": 0.0,
		"cells_loaded": 0,
		"objects_loaded": 0,
	}
	_recent_errors.clear()
	_recent_logs.clear()

	_test_start_time = Time.get_ticks_msec() / 1000.0
	_test_state = TestState.RUNNING
	_current_waypoint_idx = 0
	_is_moving = true
	_wait_timer = 0.0

	# Disable fly camera user input
	if _fly_camera.has_method("set"):
		_fly_camera.set("enabled", false)

	# Start first waypoint
	_set_waypoint_target(0)

	_log_operation("AUTO_TEST_STARTED")
	_add_log("Auto-test started with %d waypoints" % _waypoints.size(), "success")
	Logger.info("debug", "Auto-test started - %d waypoints" % _waypoints.size())

	# Show overlay automatically
	if not _overlay_visible:
		toggle_overlay()


func stop_auto_test() -> void:
	if _test_state != TestState.RUNNING:
		return

	_complete_auto_test()


func toggle_auto_test() -> void:
	if _test_state == TestState.RUNNING:
		stop_auto_test()
	else:
		start_auto_test()


func _process_auto_test(delta: float) -> void:
	if _is_moving:
		_update_camera_movement(delta)
	else:
		_wait_timer += delta
		var current_wp := _waypoints[_current_waypoint_idx] as Dictionary
		if _wait_timer >= current_wp.get("wait", waypoint_wait_time):
			# Move to next waypoint
			_current_waypoint_idx += 1
			if _current_waypoint_idx >= _waypoints.size():
				_complete_auto_test()
			else:
				_set_waypoint_target(_current_waypoint_idx)


func _set_waypoint_target(idx: int) -> void:
	if idx >= _waypoints.size():
		return

	var wp := _waypoints[idx] as Dictionary
	var cell: Vector2i = wp.get("cell", Vector2i.ZERO)
	var height: float = wp.get("height", 100.0)

	# Convert cell to world position
	var cell_size: float = 8192.0
	_target_position = Vector3(
		float(cell.x) * cell_size + cell_size * 0.5,
		height,
		float(-cell.y) * cell_size - cell_size * 0.5
	)

	_is_moving = true
	_wait_timer = 0.0

	_add_log("Moving to: %s (%d,%d)" % [wp.get("name", "?"), cell.x, cell.y], "info")


func _update_camera_movement(delta: float) -> void:
	if not _fly_camera:
		return

	var current_pos: Vector3 = _fly_camera.global_position
	var to_target: Vector3 = _target_position - current_pos
	var distance: float = to_target.length()

	if distance < 20.0:
		# Arrived at waypoint
		_fly_camera.global_position = _target_position
		_is_moving = false
		_test_metrics.waypoints_visited += 1

		var wp := _waypoints[_current_waypoint_idx] as Dictionary
		_add_log("Arrived at: %s" % wp.get("name", "waypoint"), "success")

		# Check for issues at this location
		_check_for_issues()
	else:
		# Move towards target
		var direction := to_target.normalized()
		var move_amount := auto_test_speed * delta
		if move_amount > distance:
			move_amount = distance
		_fly_camera.global_position += direction * move_amount

		# Look towards target
		var look_target := _target_position + Vector3(0, -20, 0)
		var look_dir := look_target - _fly_camera.global_position
		if look_dir.length() > 0.001:
			var target_basis := Basis.looking_at(look_dir, Vector3.UP)
			_fly_camera.basis = _fly_camera.basis.slerp(target_basis, delta * 2.0)


func _check_for_issues() -> void:
	var fps := _calculate_fps()
	if fps < fps_error:
		_add_error("Critical FPS: %.1f" % fps, "error")
	elif fps < fps_warning:
		_add_error("Low FPS warning: %.1f" % fps, "warning")

	var queue_size := _get_queue_size()
	if queue_size > queue_error:
		_add_error("Queue overload: %d objects" % queue_size, "error")
	elif queue_size > queue_warning:
		_add_error("High queue: %d objects" % queue_size, "warning")


func _complete_auto_test() -> void:
	_test_state = TestState.COMPLETED

	# Re-enable fly camera
	if _fly_camera and _fly_camera.has_method("set"):
		_fly_camera.set("enabled", true)

	# Calculate final metrics
	_test_metrics.avg_fps = _calculate_fps()

	var elapsed := (Time.get_ticks_msec() / 1000.0) - _test_start_time

	_log_operation("AUTO_TEST_COMPLETED duration=%.1fs waypoints=%d errors=%d" % [
		elapsed, _test_metrics.waypoints_visited, _test_metrics.errors_captured
	])

	_add_log("Test completed in %.1fs" % elapsed, "success")
	Logger.info("debug", "Auto-test completed - Duration: %.1fs, Errors: %d" % [
		elapsed, _test_metrics.errors_captured
	])

	# Generate and emit report
	var report := _generate_test_report()
	auto_test_completed.emit(report)

	# Print report to console
	_print_test_report(report)

#endregion


#region Profiling Report (F4)

## Dump comprehensive profiling report (F4 functionality)
func dump_profiling_report() -> void:
	Logger.info("debug", "")
	Logger.info("debug", "=" .repeat(70))
	Logger.info("debug", "                    GODOTWIND DEBUG REPORT")
	Logger.info("debug", "=" .repeat(70))
	Logger.info("debug", "Generated: %s" % Time.get_datetime_string_from_system())
	Logger.info("debug", "")

	# Session info
	var elapsed := (Time.get_ticks_msec() / 1000.0) - _session_start_time
	Logger.info("debug", "[SESSION]")
	Logger.info("debug", "  Duration: %.1f seconds" % elapsed)
	Logger.info("debug", "  Frames: %d" % _frame_count)
	Logger.info("debug", "")

	# Frame timing
	Logger.info("debug", "[FRAME TIMING]")
	var fps := _calculate_fps()
	var frame_time := _calculate_frame_time()
	var percs := _get_frame_percentiles()
	Logger.info("debug", "  FPS: %.1f (%.2f ms avg)" % [fps, frame_time])
	Logger.info("debug", "  P50: %.2f ms | P95: %.2f ms | P99: %.2f ms | Max: %.2f ms" % [
		percs.p50, percs.p95, percs.p99, percs.max
	])
	Logger.info("debug", "")

	# Rendering stats
	Logger.info("debug", "[RENDERING]")
	Logger.info("debug", "  Draw calls: %d" % Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	Logger.info("debug", "  Primitives: %d" % Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	Logger.info("debug", "  Objects visible: %d" % Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	Logger.info("debug", "")

	# Memory stats
	Logger.info("debug", "[MEMORY]")
	Logger.info("debug", "  Static: %.1f MB" % (Performance.get_monitor(Performance.MEMORY_STATIC) / (1024.0 * 1024.0)))
	Logger.info("debug", "  Nodes: %d | Resources: %d" % [
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)
	])
	Logger.info("debug", "")

	# Streaming stats
	if _world_streaming_manager:
		Logger.info("debug", "[STREAMING]")
		if _world_streaming_manager.has_method("get_stats"):
			var wsm_stats: Dictionary = _world_streaming_manager.get_stats()
			Logger.info("debug", "  Loaded cells: %d" % wsm_stats.get("loaded_cells", 0))

		var object_streamer := _world_streaming_manager.get_node_or_null("ObjectStreamer")
		if object_streamer and object_streamer.has_method("get_stats"):
			var os_stats: Dictionary = object_streamer.get_stats()
			Logger.info("debug", "  Queue size: %d" % os_stats.get("instantiation_queue_size", 0))
			Logger.info("debug", "  Total objects: %d" % os_stats.get("total_objects", 0))
			Logger.info("debug", "  NEAR: %d | MID: %d | FAR: %d" % [
				os_stats.get("near_visible", 0),
				os_stats.get("mid_visible", 0),
				os_stats.get("far_visible", 0)
			])
		Logger.info("debug", "")

	# Cell manager stats
	if _cell_manager and _cell_manager.has_method("get_stats"):
		Logger.info("debug", "[CELL MANAGER]")
		var cm_stats: Dictionary = _cell_manager.get_stats()
		Logger.info("debug", "  Pool available: %d | In use: %d" % [
			cm_stats.get("pool_available", 0),
			cm_stats.get("pool_in_use", 0)
		])
		Logger.info("debug", "  Pool hit rate: %.1f%%" % (cm_stats.get("pool_hit_rate", 0.0) * 100.0))
		Logger.info("debug", "")

	# Profiler data
	if _profiler:
		Logger.info("debug", "[PROFILER DATA]")
		var report: Dictionary = _profiler.get_report()
		Logger.info("debug", "  Cells loaded: %d" % report.get("session", {}).get("total_cells_loaded", 0))
		Logger.info("debug", "  Objects loaded: %d" % report.get("session", {}).get("total_objects_loaded", 0))
		Logger.info("debug", "  Avg cell load time: %.1f ms" % report.get("cell_loading", {}).get("avg_load_time_ms", 0.0))

		var slowest: Array = report.get("slowest_models", [])
		if not slowest.is_empty():
			Logger.info("debug", "  Slowest models:")
			for model: Dictionary in slowest.slice(0, 5):
				Logger.info("debug", "    %.2f ms - %s" % [model.get("avg_ms", 0.0), model.get("path", "?").get_file()])
		Logger.info("debug", "")

	# Streaming profiler data
	if _streaming_profiler:
		Logger.info("debug", "[STREAMING PROFILER]")
		var sections: Dictionary = _streaming_profiler.get_all_sections()
		for name: String in sections:
			var data: Dictionary = sections[name]
			var slow_flag := " <-- SLOW" if data.last_ms > 16.0 else ""
			Logger.info("debug", "  %s: %.2f ms (avg %.2f, max %.2f)%s" % [
				name, data.last_ms, data.avg_ms, data.max_ms, slow_flag
			])
		Logger.info("debug", "")

	# Material library stats
	Logger.info("debug", "[MATERIALS]")
	var mat_stats: Dictionary = MaterialLibrary.get_stats()
	Logger.info("debug", "  Cached: %d | Hits: %d | Rate: %.1f%%" % [
		mat_stats.get("cached_materials", 0),
		mat_stats.get("cache_hits", 0),
		mat_stats.get("hit_rate", 0.0) * 100.0
	])
	Logger.info("debug", "")

	# Texture loader stats
	Logger.info("debug", "[TEXTURES]")
	var tex_stats: Dictionary = TextureLoader.get_stats()
	Logger.info("debug", "  Loaded: %d | Cached: %d | Hits: %d" % [
		tex_stats.get("loaded", 0),
		tex_stats.get("cached", 0),
		tex_stats.get("cache_hits", 0)
	])
	Logger.info("debug", "")

	# BSA cache stats
	Logger.info("debug", "[BSA CACHE]")
	var bsa_stats: Dictionary = BSAManager.get_cache_stats()
	Logger.info("debug", "  Size: %.1f MB (%d files)" % [
		bsa_stats.get("cache_size_mb", 0.0),
		bsa_stats.get("cached_files", 0)
	])
	Logger.info("debug", "  Hits: %d | Misses: %d | Rate: %.1f%%" % [
		bsa_stats.get("cache_hits", 0),
		bsa_stats.get("cache_misses", 0),
		bsa_stats.get("hit_rate", 0.0) * 100.0
	])
	Logger.info("debug", "")

	# Recent errors
	if not _recent_errors.is_empty():
		Logger.info("debug", "[RECENT ERRORS]")
		for err: Dictionary in _recent_errors.slice(-10):
			Logger.info("debug", "  [%.1fs] %s" % [err.get("time", 0.0), err.get("message", "?")])
		Logger.info("debug", "")

	Logger.info("debug", "=" .repeat(70))
	Logger.info("debug", "")

	_add_log("Profiling report dumped to console", "success")

#endregion


#region State Dump (F11)

## Dump current state to file (F11 functionality)
func dump_state_now() -> void:
	_log_operation("MANUAL_STATE_DUMP")
	_write_state_to_file()

	var global_path := ProjectSettings.globalize_path(log_path)
	Logger.info("debug", "State dumped to: %s" % global_path)
	_add_log("State dumped to log file", "success")


func _write_state_to_file() -> void:
	var lines: Array[String] = []

	# Header
	lines.append("=== GODOTWIND DEBUG STATE DUMP ===")
	lines.append("Generated: %s" % Time.get_datetime_string_from_system())
	var elapsed := (Time.get_ticks_msec() / 1000.0) - _session_start_time
	lines.append("Session duration: %.1f seconds" % elapsed)
	lines.append("")

	# Camera state
	lines.append("=== CAMERA STATE ===")
	if _fly_camera:
		var pos := _fly_camera.global_position
		lines.append("Position: (%.1f, %.1f, %.1f)" % [pos.x, pos.y, pos.z])
		var cell_x := int(floor(pos.x / 8192.0))
		var cell_y := int(floor(-pos.z / 8192.0))
		lines.append("Cell: (%d, %d)" % [cell_x, cell_y])
	else:
		lines.append("Camera: Not available")
	lines.append("")

	# Test state
	lines.append("=== AUTO-TEST STATE ===")
	lines.append("State: %s" % TestState.keys()[_test_state])
	if _test_state == TestState.RUNNING:
		lines.append("Current waypoint: %d/%d" % [_current_waypoint_idx + 1, _waypoints.size()])
		if _current_waypoint_idx < _waypoints.size():
			var wp: Dictionary = _waypoints[_current_waypoint_idx]
			lines.append("Waypoint name: %s" % wp.get("name", "?"))
	lines.append("Waypoints visited: %d" % _test_metrics.waypoints_visited)
	lines.append("Errors captured: %d" % _test_metrics.errors_captured)
	lines.append("")

	# Performance
	lines.append("=== PERFORMANCE ===")
	lines.append("FPS: %.1f" % _calculate_fps())
	lines.append("Frame time: %.1f ms" % _calculate_frame_time())
	lines.append("Min FPS: %.1f" % _test_metrics.min_fps)
	lines.append("Max frame time: %.1f ms" % _test_metrics.max_frame_time_ms)
	lines.append("")

	# Streaming state
	lines.append("=== STREAMING STATE ===")
	if _world_streaming_manager and _world_streaming_manager.has_method("get_stats"):
		var wsm_stats: Dictionary = _world_streaming_manager.get_stats()
		lines.append("Loaded cells: %d" % wsm_stats.get("loaded_cells", 0))

	var tiers := _get_tier_counts()
	lines.append("NEAR: %d | MID: %d | FAR: %d" % [tiers.near, tiers.mid, tiers.far])
	lines.append("Queue: %d" % _get_queue_size())
	lines.append("")

	# Recent operations
	lines.append("=== LAST %d OPERATIONS ===" % mini(_operation_log.size(), 30))
	var start_idx := maxi(0, _operation_log.size() - 30)
	for i in range(start_idx, _operation_log.size()):
		lines.append(_operation_log[i])
	lines.append("")

	# Errors
	lines.append("=== RECENT ERRORS ===")
	if _recent_errors.is_empty():
		lines.append("No errors")
	else:
		for err: Dictionary in _recent_errors.slice(-20):
			lines.append("[%.1fs] %s: %s" % [
				err.get("time", 0.0),
				err.get("type", "?").to_upper(),
				err.get("message", "?")
			])
	lines.append("")

	lines.append("=== COPY THIS TO CLAUDE FOR ANALYSIS ===")

	# Write to file
	var file := FileAccess.open(log_path, FileAccess.WRITE)
	if file:
		file.store_string("\n".join(lines))
		file.close()

#endregion


#region Test Report

func _generate_test_report() -> Dictionary:
	var elapsed := (Time.get_ticks_msec() / 1000.0) - _test_start_time
	var percs := _get_frame_percentiles()

	return {
		"summary": {
			"duration_seconds": elapsed,
			"waypoints_total": _waypoints.size(),
			"waypoints_visited": _test_metrics.waypoints_visited,
			"errors": _test_metrics.errors_captured,
			"warnings": _test_metrics.warnings_captured,
		},
		"performance": {
			"avg_fps": _test_metrics.avg_fps,
			"min_fps": _test_metrics.min_fps if _test_metrics.min_fps < 999.0 else 0.0,
			"p50_ms": percs.p50,
			"p95_ms": percs.p95,
			"p99_ms": percs.p99,
			"max_ms": percs.max,
		},
		"streaming": {
			"cells_loaded": _test_metrics.cells_loaded,
			"objects_loaded": _test_metrics.objects_loaded,
		},
		"errors": _recent_errors.duplicate(),
	}


func _print_test_report(report: Dictionary) -> void:
	Logger.info("debug", "")
	Logger.info("debug", "=" .repeat(60))
	Logger.info("debug", "              AUTO-TEST REPORT")
	Logger.info("debug", "=" .repeat(60))

	var summary: Dictionary = report.get("summary", {})
	Logger.info("debug", "Duration: %.1f seconds" % summary.get("duration_seconds", 0.0))
	Logger.info("debug", "Waypoints: %d/%d" % [summary.get("waypoints_visited", 0), summary.get("waypoints_total", 0)])
	Logger.info("debug", "Errors: %d | Warnings: %d" % [summary.get("errors", 0), summary.get("warnings", 0)])
	Logger.info("debug", "")

	var perf: Dictionary = report.get("performance", {})
	Logger.info("debug", "Performance:")
	Logger.info("debug", "  Avg FPS: %.1f | Min FPS: %.1f" % [perf.get("avg_fps", 0.0), perf.get("min_fps", 0.0)])
	Logger.info("debug", "  Frame times: P50=%.1fms P95=%.1fms Max=%.1fms" % [
		perf.get("p50_ms", 0.0), perf.get("p95_ms", 0.0), perf.get("max_ms", 0.0)
	])
	Logger.info("debug", "")

	var streaming: Dictionary = report.get("streaming", {})
	Logger.info("debug", "Streaming:")
	Logger.info("debug", "  Cells loaded: %d" % streaming.get("cells_loaded", 0))
	Logger.info("debug", "  Objects loaded: %d" % streaming.get("objects_loaded", 0))

	Logger.info("debug", "=" .repeat(60))
	Logger.info("debug", "")

#endregion


#region Utility Functions

func _calculate_fps() -> float:
	if _frame_times.is_empty():
		return 0.0
	var sum := 0.0
	for t in _frame_times:
		sum += t
	var avg_ms := sum / _frame_times.size()
	return 1000.0 / avg_ms if avg_ms > 0 else 0.0


func _calculate_frame_time() -> float:
	if _frame_times.is_empty():
		return 0.0
	var sum := 0.0
	for t in _frame_times:
		sum += t
	return sum / _frame_times.size()


func _get_frame_percentiles() -> Dictionary:
	if _frame_times.is_empty():
		return {"p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0}

	var sorted := _frame_times.duplicate()
	sorted.sort()

	var p50_idx := int(sorted.size() * 0.50)
	var p95_idx := int(sorted.size() * 0.95)
	var p99_idx := int(sorted.size() * 0.99)

	return {
		"p50": sorted[p50_idx],
		"p95": sorted[mini(p95_idx, sorted.size() - 1)],
		"p99": sorted[mini(p99_idx, sorted.size() - 1)],
		"max": sorted[-1]
	}


func _get_queue_size() -> int:
	if not _world_streaming_manager:
		return 0
	var object_streamer := _world_streaming_manager.get_node_or_null("ObjectStreamer")
	if object_streamer and object_streamer.has_method("get_stats"):
		var stats: Dictionary = object_streamer.get_stats()
		return stats.get("instantiation_queue_size", 0)
	return 0


func _get_tier_counts() -> Dictionary:
	var result := {"near": 0, "mid": 0, "far": 0}
	if not _world_streaming_manager:
		return result
	var object_streamer := _world_streaming_manager.get_node_or_null("ObjectStreamer")
	if object_streamer and object_streamer.has_method("get_stats"):
		var stats: Dictionary = object_streamer.get_stats()
		result.near = stats.get("near_visible", 0)
		result.mid = stats.get("mid_visible", 0)
		result.far = stats.get("far_visible", 0)
	return result


func _log_operation(operation: String) -> void:
	var elapsed := (Time.get_ticks_msec() / 1000.0) - _session_start_time
	var entry := "[+%.3fs] %s" % [elapsed, operation]
	_operation_log.append(entry)
	while _operation_log.size() > MAX_OPERATIONS:
		_operation_log.pop_front()


func _add_log(message: String, level: String = "info") -> void:
	var elapsed := (Time.get_ticks_msec() / 1000.0) - _session_start_time
	_recent_logs.append({
		"time": elapsed,
		"message": message,
		"level": level
	})
	while _recent_logs.size() > MAX_LOGS:
		_recent_logs.pop_front()


func _add_error(message: String, error_type: String = "error") -> void:
	# Deduplicate
	for existing: Dictionary in _recent_errors:
		if existing.get("message", "") == message:
			return

	var elapsed := (Time.get_ticks_msec() / 1000.0) - _session_start_time
	_recent_errors.append({
		"time": elapsed,
		"message": message,
		"type": error_type
	})

	if error_type == "error":
		_test_metrics.errors_captured += 1
	else:
		_test_metrics.warnings_captured += 1

	while _recent_errors.size() > MAX_ERRORS:
		_recent_errors.pop_front()

	issue_detected.emit(error_type, message)

#endregion


#region Public API

## Check if auto-test is running
func is_testing() -> bool:
	return _test_state == TestState.RUNNING


## Get current test state
func get_test_state() -> TestState:
	return _test_state


## Get test metrics
func get_test_metrics() -> Dictionary:
	return _test_metrics.duplicate()


## Add custom waypoint for testing
func add_waypoint(wp_name: String, cell: Vector2i, height: float = 100.0, wait: float = 3.0) -> void:
	_waypoints.append({
		"name": wp_name,
		"cell": cell,
		"height": height,
		"wait": wait
	})


## Clear all waypoints and use default set
func reset_waypoints() -> void:
	_setup_default_waypoints()


## Manually capture an error during testing
func capture_error(message: String) -> void:
	_add_error(message, "error")
	_log_operation("ERROR: %s" % message)


## Manually capture a warning during testing
func capture_warning(message: String) -> void:
	_add_error(message, "warning")
	_log_operation("WARNING: %s" % message)


## Get overlay visibility state
func is_overlay_visible() -> bool:
	return _overlay_visible

#endregion