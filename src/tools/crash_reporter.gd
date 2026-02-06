## CrashReporter - State capture for post-crash analysis
##
## Writes system state to a log file periodically so that if a crash occurs,
## you can review what was happening before the crash.
##
## The output format is designed for copy-pasting to Claude for analysis.
##
## Usage:
##   var reporter := CrashReporter.new()
##   add_child(reporter)
##   reporter.connect_to_systems(world_explorer, wsm, object_streamer, diagnostic_overlay)
##
## Output: user://logs/crash_report.txt
@warning_ignore("untyped_declaration")
class_name CrashReporter
extends Node


#region Configuration

## Path to write crash reports
@export var log_path: String = "user://logs/crash_report.txt"

## How often to write state (in frames)
@export var write_interval_frames: int = 30

## Maximum operations to track
const MAX_OPERATIONS: int = 100

#endregion


#region State

## Ring buffer of recent operations
var _operation_log: Array[String] = []

## Reference to systems
var _world_explorer: Node = null
var _world_streaming_manager: Node = null
var _object_streamer: Node = null
var _diagnostic_overlay: Node = null

## Frame counter
var _frame_count: int = 0

## Start time for relative timestamps
var _start_time: float = 0.0

## Last known camera position
var _last_camera_pos: Vector3 = Vector3.ZERO
var _last_camera_cell: Vector2i = Vector2i.ZERO

## Session stats
var _session_errors: Array[String] = []
var _toggle_history: Array[String] = []

#endregion


func _ready() -> void:
	_start_time = Time.get_ticks_msec() / 1000.0

	# Ensure logs directory exists
	var dir := DirAccess.open("user://")
	if dir and not dir.dir_exists("logs"):
		dir.make_dir("logs")

	_log_operation("SESSION_START")
	Logger.info("tools", "CrashReporter logging to: %s" % ProjectSettings.globalize_path(log_path))


func _process(_delta: float) -> void:
	_frame_count += 1

	# Write state periodically
	if _frame_count % write_interval_frames == 0:
		_write_state()


#region System Connection

## Connect to all relevant systems for monitoring
func connect_to_systems(world_explorer: Node, wsm: Node = null, os: Node = null, diag: Node = null) -> void:
	_world_explorer = world_explorer
	_world_streaming_manager = wsm
	_object_streamer = os
	_diagnostic_overlay = diag

	# Get ObjectStreamer from WSM if not provided
	if _object_streamer == null and _world_streaming_manager:
		_object_streamer = _world_streaming_manager.get_node_or_null("ObjectStreamer")

	# Connect to ObjectStreamer signals
	if _object_streamer:
		if _object_streamer.has_signal("instantiation_requested"):
			_object_streamer.instantiation_requested.connect(_on_instantiation_requested)
		if _object_streamer.has_signal("instantiation_queue_changed"):
			_object_streamer.instantiation_queue_changed.connect(_on_queue_changed)

	# Connect to WorldStreamingManager signals
	if _world_streaming_manager:
		if _world_streaming_manager.has_signal("cell_loaded"):
			_world_streaming_manager.cell_loaded.connect(_on_cell_loaded)
		if _world_streaming_manager.has_signal("cell_unloaded"):
			_world_streaming_manager.cell_unloaded.connect(_on_cell_unloaded)

	# Connect to DiagnosticOverlay for issues
	if _diagnostic_overlay and _diagnostic_overlay.has_signal("issue_detected"):
		_diagnostic_overlay.issue_detected.connect(_on_issue_detected)

	_log_operation("SYSTEMS_CONNECTED")
	Logger.info("tools", "CrashReporter connected to systems")


func _on_instantiation_requested(_object_id: int, model_path: String, world_transform: Transform3D, cell_grid: Vector2i, _ref_id: String, _ref_num: int) -> void:
	var short_path: String = model_path.get_file() if model_path else "?"
	_log_operation("OBJECT_REGISTER: %s at (%.0f, %.0f, %.0f) cell (%d, %d)" % [
		short_path,
		world_transform.origin.x,
		world_transform.origin.y,
		world_transform.origin.z,
		cell_grid.x,
		cell_grid.y
	])


func _on_queue_changed(queue_size: int) -> void:
	# Only log significant changes
	if queue_size > 100 or queue_size == 0:
		_log_operation("QUEUE_SIZE: %d" % queue_size)


func _on_cell_loaded(grid: Vector2i, object_count: int) -> void:
	_log_operation("CELL_LOADED: (%d, %d) with %d objects" % [grid.x, grid.y, object_count])


func _on_cell_unloaded(grid: Vector2i) -> void:
	_log_operation("CELL_UNLOADED: (%d, %d)" % [grid.x, grid.y])


func _on_issue_detected(issue_type: String, message: String, _severity: int) -> void:
	_log_operation("ISSUE: [%s] %s" % [issue_type, message])
	_session_errors.append("[%s] %s" % [issue_type, message])

#endregion


#region Operation Logging

func _log_operation(operation: String) -> void:
	var elapsed := (Time.get_ticks_msec() / 1000.0) - _start_time
	var entry := "[+%.3fs] %s" % [elapsed, operation]

	_operation_log.append(entry)

	# Keep ring buffer size
	while _operation_log.size() > MAX_OPERATIONS:
		_operation_log.pop_front()


## Log a toggle action (called from world_explorer)
func log_toggle(setting: String, value: bool) -> void:
	var action := "TOGGLE: %s = %s" % [setting, "ON" if value else "OFF"]
	_log_operation(action)
	_toggle_history.append(action)


## Log a teleport action
func log_teleport(position: Vector3, cell: Vector2i) -> void:
	_log_operation("TELEPORT: (%.0f, %.0f, %.0f) cell (%d, %d)" % [
		position.x, position.y, position.z, cell.x, cell.y
	])

#endregion


#region State Writing

func _write_state() -> void:
	var report := _generate_report()

	var file := FileAccess.open(log_path, FileAccess.WRITE)
	if file:
		file.store_string(report)
		file.close()


func _generate_report() -> String:
	var lines: Array[String] = []

	# Header
	lines.append("=== GODOTWIND CRASH REPORT ===")
	lines.append("Generated: %s" % Time.get_datetime_string_from_system())
	var elapsed := (Time.get_ticks_msec() / 1000.0) - _start_time
	lines.append("Session duration: %.1f seconds" % elapsed)
	lines.append("")

	# Camera state
	lines.append("=== CAMERA STATE ===")
	_update_camera_info()
	lines.append("Position: (%.1f, %.1f, %.1f)" % [_last_camera_pos.x, _last_camera_pos.y, _last_camera_pos.z])
	lines.append("Cell: (%d, %d)" % [_last_camera_cell.x, _last_camera_cell.y])

	if _world_explorer:
		var mode: String = "FLY_CAMERA"
		if _world_explorer.get("_camera_mode") != null:
			mode = "PLAYER" if _world_explorer.get("_camera_mode") == 1 else "FLY_CAMERA"
		lines.append("Camera mode: %s" % mode)

		# Models are always visible now (no toggle since refactor)
		var show_ocean: bool = _world_explorer.get("_show_ocean") if _world_explorer.get("_show_ocean") != null else false
		var show_sky: bool = _world_explorer.get("_show_sky") if _world_explorer.get("_show_sky") != null else false
		lines.append("Models: ON (always), Ocean: %s, Sky: %s" % [
			"ON" if show_ocean else "OFF",
			"ON" if show_sky else "OFF"
		])
	lines.append("")

	# Streaming state
	lines.append("=== STREAMING STATE ===")
	if _object_streamer and _object_streamer.has_method("get_stats"):
		var stats: Dictionary = _object_streamer.get_stats()
		lines.append("Queue: %d pending" % stats.get("instantiation_queue_size", 0))
		lines.append("NEAR: %d | MID: %d | FAR: %d" % [
			stats.get("near_visible", 0),
			stats.get("mid_visible", 0),
			stats.get("far_visible", 0)
		])
		lines.append("Total objects: %d" % stats.get("total_objects", 0))
		lines.append("Instantiations this frame: %d" % stats.get("instantiations_this_frame", 0))

	if _world_streaming_manager and _world_streaming_manager.has_method("get_stats"):
		var wsm_stats: Dictionary = _world_streaming_manager.get_stats()
		lines.append("Loaded cells: %d" % wsm_stats.get("loaded_cells", 0))
	lines.append("")

	# Toggle history
	if not _toggle_history.is_empty():
		lines.append("=== TOGGLE HISTORY ===")
		for entry in _toggle_history:
			lines.append(entry)
		lines.append("")

	# Last N operations
	lines.append("=== LAST %d OPERATIONS ===" % min(_operation_log.size(), 30))
	var start_idx: int = max(0, _operation_log.size() - 30)
	for i: int in range(start_idx, _operation_log.size()):
		lines.append(_operation_log[i])
	lines.append("")

	# Errors
	lines.append("=== ERRORS (session) ===")
	if _session_errors.is_empty():
		lines.append("No errors recorded")
	else:
		for err in _session_errors:
			lines.append(err)
	lines.append("")

	# Performance from DiagnosticOverlay
	if _diagnostic_overlay and _diagnostic_overlay.has_method("get_state"):
		lines.append("=== PERFORMANCE ===")
		var diag_state: Dictionary = _diagnostic_overlay.get_state()
		lines.append("FPS: %.1f" % diag_state.get("fps", 0.0))
		lines.append("Frame time: %.1fms" % diag_state.get("frame_time_ms", 0.0))
		lines.append("")

	# Footer
	lines.append("=== COPY THIS TO CLAUDE FOR ANALYSIS ===")
	lines.append("")

	return "\n".join(lines)


func _update_camera_info() -> void:
	if not _world_explorer:
		return

	# Try to get camera position
	var camera: Camera3D = null
	if _world_explorer.get("fly_camera"):
		camera = _world_explorer.get("fly_camera")
	elif _world_explorer.get("camera"):
		camera = _world_explorer.get("camera")

	if camera:
		_last_camera_pos = camera.global_position

		# Calculate cell from position (8192 units per cell)
		_last_camera_cell.x = int(floor(_last_camera_pos.x / 8192.0))
		_last_camera_cell.y = int(floor(_last_camera_pos.z / 8192.0))  # Z is the "Y" in cell grid

#endregion


#region Manual Dumps

## Force immediate state dump (F11 shortcut)
func dump_state_now() -> void:
	_log_operation("MANUAL_DUMP_REQUESTED")
	_write_state()
	Logger.info("tools", "CrashReporter state dumped to: %s" % ProjectSettings.globalize_path(log_path))


## Get the current report as string (for display)
func get_report_string() -> String:
	return _generate_report()

#endregion
