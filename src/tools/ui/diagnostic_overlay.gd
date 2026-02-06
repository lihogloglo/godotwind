## DiagnosticOverlay - Real-time streaming diagnostics for debugging
##
## Shows live information about:
## - FPS and frame time
## - Object streaming queue state
## - Tier counts (NEAR/MID/FAR)
## - Recent model loads
## - Errors and warnings
##
## Usage:
##   var overlay := DiagnosticOverlay.new()
##   add_child(overlay)
##   overlay.connect_to_streaming(world_streaming_manager, object_streamer)
##
## Controls:
##   F9: Toggle overlay visibility
@warning_ignore("untyped_declaration")
class_name DiagnosticOverlay
extends CanvasLayer


## Status levels for color-coding
enum Status { GOOD, WARNING, ERROR }

## Emitted when an issue is auto-detected
signal issue_detected(issue_type: String, message: String, severity: Status)


#region Configuration

## FPS thresholds
@export var fps_warning_threshold: float = 30.0
@export var fps_error_threshold: float = 15.0

## Queue thresholds
@export var queue_warning_threshold: int = 100
@export var queue_error_threshold: int = 500

## Stall detection
@export var stall_threshold_seconds: float = 3.0

## Max items in ring buffers
const MAX_RECENT_MODELS: int = 20
const MAX_RECENT_ERRORS: int = 10

#endregion


#region State

## Ring buffer for recent model loads
var _recent_models: Array[Dictionary] = []  # {path, time, tier}

## Ring buffer for recent errors
var _recent_errors: Array[Dictionary] = []  # {message, time, type}

## Current streaming stats
var _current_stats: Dictionary = {}

## Stall detection
var _last_queue_size: int = 0
var _queue_unchanged_time: float = 0.0

## References
var _world_streaming_manager: Node = null
var _object_streamer: Node = null

## Frame tracking
var _frame_times: Array[float] = []
const FRAME_TIME_SAMPLES: int = 60

#endregion


#region UI Elements

var _panel: PanelContainer
var _main_vbox: VBoxContainer

## Status bar
var _status_bar: Label
var _status_color: Color = Color.GREEN

## Performance section
var _fps_label: Label
var _queue_label: Label
var _load_rate_label: Label

## Tier counts section
var _tier_label: Label

## Loading feed
var _loading_feed: RichTextLabel

## Error feed
var _error_feed: RichTextLabel

#endregion


func _ready() -> void:
	layer = 100  # High layer to be on top
	_setup_ui()


func _process(delta: float) -> void:
	if not visible:
		return

	# Track frame times
	_frame_times.append(delta * 1000.0)
	if _frame_times.size() > FRAME_TIME_SAMPLES:
		_frame_times.pop_front()

	# Update stats from streaming systems
	_update_stats()

	# Check for issues
	_check_for_issues(delta)

	# Update UI
	_update_ui()


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and key_event.keycode == KEY_F9:
			visible = not visible


#region Setup

func _setup_ui() -> void:
	# Main panel - positioned at top-left
	_panel = PanelContainer.new()
	_panel.name = "DiagnosticPanel"

	# Style the panel
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.12, 0.9)
	style.border_color = Color(0.3, 0.3, 0.35)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8)
	_panel.add_theme_stylebox_override("panel", style)

	# Position at top-left
	_panel.position = Vector2(10, 10)
	_panel.custom_minimum_size = Vector2(320, 0)

	add_child(_panel)

	# Main VBox
	_main_vbox = VBoxContainer.new()
	_main_vbox.add_theme_constant_override("separation", 6)
	_panel.add_child(_main_vbox)

	# Title with status indicator
	var title_row := HBoxContainer.new()
	_main_vbox.add_child(title_row)

	var title := Label.new()
	title.text = "STREAMING DIAGNOSTICS"
	title.add_theme_font_size_override("font_size", 12)
	title.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	title_row.add_child(title)

	title_row.add_child(_create_spacer())

	_status_bar = Label.new()
	_status_bar.text = "GOOD"
	_status_bar.add_theme_font_size_override("font_size", 11)
	_status_bar.add_theme_color_override("font_color", Color.GREEN)
	title_row.add_child(_status_bar)

	# Separator
	_main_vbox.add_child(_create_separator())

	# Performance section
	_fps_label = _create_stat_label("FPS: --")
	_main_vbox.add_child(_fps_label)

	_queue_label = _create_stat_label("Queue: --")
	_main_vbox.add_child(_queue_label)

	_load_rate_label = _create_stat_label("Load rate: --")
	_main_vbox.add_child(_load_rate_label)

	# Separator
	_main_vbox.add_child(_create_separator())

	# Tier counts
	_tier_label = _create_stat_label("NEAR: -- | MID: -- | FAR: --")
	_main_vbox.add_child(_tier_label)

	# Separator
	_main_vbox.add_child(_create_separator())

	# Loading feed header
	var loading_header := Label.new()
	loading_header.text = "Loading Feed"
	loading_header.add_theme_font_size_override("font_size", 11)
	loading_header.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	_main_vbox.add_child(loading_header)

	_loading_feed = RichTextLabel.new()
	_loading_feed.bbcode_enabled = true
	_loading_feed.custom_minimum_size = Vector2(300, 100)
	_loading_feed.add_theme_font_size_override("normal_font_size", 10)
	_loading_feed.scroll_following = true
	_main_vbox.add_child(_loading_feed)

	# Separator
	_main_vbox.add_child(_create_separator())

	# Error feed header
	var error_header := Label.new()
	error_header.text = "Errors & Warnings"
	error_header.add_theme_font_size_override("font_size", 11)
	error_header.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	_main_vbox.add_child(error_header)

	_error_feed = RichTextLabel.new()
	_error_feed.bbcode_enabled = true
	_error_feed.custom_minimum_size = Vector2(300, 80)
	_error_feed.add_theme_font_size_override("normal_font_size", 10)
	_error_feed.scroll_following = true
	_main_vbox.add_child(_error_feed)

	# Instructions
	var instructions := Label.new()
	instructions.text = "Press F9 to hide"
	instructions.add_theme_font_size_override("font_size", 9)
	instructions.add_theme_color_override("font_color", Color(0.4, 0.4, 0.45))
	_main_vbox.add_child(instructions)


func _create_stat_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	return label


func _create_separator() -> HSeparator:
	var sep := HSeparator.new()
	sep.add_theme_constant_override("separation", 4)
	return sep


func _create_spacer() -> Control:
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return spacer

#endregion


#region Streaming Connection

## Connect to streaming systems to receive events
func connect_to_streaming(wsm: Node, os: Node = null) -> void:
	_world_streaming_manager = wsm

	# Get ObjectStreamer from WSM if not provided
	if os == null and wsm:
		os = wsm.get_node_or_null("ObjectStreamer")
	_object_streamer = os

	# Connect to ObjectStreamer signals
	if _object_streamer:
		if _object_streamer.has_signal("instantiation_queue_changed"):
			_object_streamer.instantiation_queue_changed.connect(_on_queue_changed)

		if _object_streamer.has_signal("instantiation_requested"):
			_object_streamer.instantiation_requested.connect(_on_instantiation_requested)

	# Connect to WorldStreamingManager signals
	if _world_streaming_manager:
		if _world_streaming_manager.has_signal("cell_loaded"):
			_world_streaming_manager.cell_loaded.connect(_on_cell_loaded)

	Log.info("debug", "DiagnosticOverlay connected to streaming systems")


func _on_queue_changed(queue_size: int) -> void:
	_current_stats["queue_size"] = queue_size


func _on_instantiation_requested(object_id: int, model_path: String, _world_transform: Transform3D, _cell_grid: Vector2i, _ref_id: String, _ref_num: int) -> void:
	_add_recent_model(model_path, "REQUESTED")


func _on_cell_loaded(grid: Vector2i, object_count: int) -> void:
	_add_recent_model("Cell (%d, %d) [%d objects]" % [grid.x, grid.y, object_count], "LOADED")

#endregion


#region Stats Update

func _update_stats() -> void:
	# Get stats from ObjectStreamer
	if _object_streamer and _object_streamer.has_method("get_stats"):
		var os_stats: Dictionary = _object_streamer.get_stats()
		_current_stats["near_visible"] = os_stats.get("near_visible", 0)
		_current_stats["mid_visible"] = os_stats.get("mid_visible", 0)
		_current_stats["far_visible"] = os_stats.get("far_visible", 0)
		_current_stats["queue_size"] = os_stats.get("instantiation_queue_size", 0)
		_current_stats["instantiations_this_frame"] = os_stats.get("instantiations_this_frame", 0)
		_current_stats["total_objects"] = os_stats.get("total_objects", 0)

	# Get stats from WorldStreamingManager
	if _world_streaming_manager and _world_streaming_manager.has_method("get_stats"):
		var wsm_stats: Dictionary = _world_streaming_manager.get_stats()
		_current_stats["loaded_cells"] = wsm_stats.get("loaded_cells", 0)


func _check_for_issues(delta: float) -> void:
	var overall_status := Status.GOOD

	# Check FPS
	var fps := _calculate_fps()
	if fps > 0:
		if fps < fps_error_threshold:
			overall_status = Status.ERROR
			_add_error("FPS Critical: %.1f" % fps, "performance")
		elif fps < fps_warning_threshold:
			if overall_status != Status.ERROR:
				overall_status = Status.WARNING

	# Check queue size
	var queue_size: int = _current_stats.get("queue_size", 0)
	if queue_size > queue_error_threshold:
		overall_status = Status.ERROR
		_add_error("Queue overload: %d objects" % queue_size, "queue")
	elif queue_size > queue_warning_threshold:
		if overall_status != Status.ERROR:
			overall_status = Status.WARNING

	# Check for stall (queue not decreasing)
	if queue_size > 0 and queue_size == _last_queue_size:
		_queue_unchanged_time += delta
		if _queue_unchanged_time > stall_threshold_seconds:
			overall_status = Status.ERROR
			_add_error("Loading stalled: queue stuck at %d for %.1fs" % [queue_size, _queue_unchanged_time], "stall")
	else:
		_queue_unchanged_time = 0.0
	_last_queue_size = queue_size

	# Update status display
	_update_status(overall_status)


func _update_status(status: Status) -> void:
	match status:
		Status.GOOD:
			_status_bar.text = "GOOD"
			_status_bar.add_theme_color_override("font_color", Color.GREEN)
		Status.WARNING:
			_status_bar.text = "WARNING"
			_status_bar.add_theme_color_override("font_color", Color.YELLOW)
		Status.ERROR:
			_status_bar.text = "ERROR"
			_status_bar.add_theme_color_override("font_color", Color.RED)
			issue_detected.emit("status", "System status: ERROR", status)


func _calculate_fps() -> float:
	if _frame_times.is_empty():
		return 0.0

	var sum := 0.0
	for t in _frame_times:
		sum += t
	var avg_ms: float = sum / _frame_times.size()
	return 1000.0 / avg_ms if avg_ms > 0 else 0.0


func _calculate_frame_time() -> float:
	if _frame_times.is_empty():
		return 0.0

	var sum := 0.0
	for t in _frame_times:
		sum += t
	return sum / _frame_times.size()

#endregion


#region UI Update

func _update_ui() -> void:
	# FPS and frame time
	var fps := _calculate_fps()
	var frame_time := _calculate_frame_time()
	var fps_color := "green" if fps >= fps_warning_threshold else ("yellow" if fps >= fps_error_threshold else "red")
	_fps_label.text = "FPS: %.1f (%.1fms)" % [fps, frame_time]

	# Queue
	var queue_size: int = _current_stats.get("queue_size", 0)
	var queue_color := "white"
	if queue_size > queue_error_threshold:
		queue_color = "red"
	elif queue_size > queue_warning_threshold:
		queue_color = "yellow"
	_queue_label.text = "Queue: %d objects" % queue_size

	# Load rate
	var load_rate: int = _current_stats.get("instantiations_this_frame", 0)
	_load_rate_label.text = "Load rate: %d/frame" % load_rate

	# Tier counts
	var near: int = _current_stats.get("near_visible", 0)
	var mid: int = _current_stats.get("mid_visible", 0)
	var far: int = _current_stats.get("far_visible", 0)
	_tier_label.text = "NEAR: %d | MID: %d | FAR: %d" % [near, mid, far]

	# Loading feed
	_update_loading_feed()

	# Error feed
	_update_error_feed()


func _update_loading_feed() -> void:
	var text := ""
	for i in range(_recent_models.size() - 1, -1, -1):
		var entry: Dictionary = _recent_models[i]
		var time_str: String = _format_time(entry.get("time", 0.0))
		var path: String = entry.get("path", "?")
		var action: String = entry.get("action", "?")

		var color := "gray" if action == "REQUESTED" else "cyan"
		text += "[color=%s][%s] %s %s[/color]\n" % [color, time_str, action, path.get_file()]

	if text.is_empty():
		text = "[color=gray]No recent loads[/color]"

	_loading_feed.text = text


func _update_error_feed() -> void:
	var text := ""
	for i in range(_recent_errors.size() - 1, -1, -1):
		var entry: Dictionary = _recent_errors[i]
		var time_str: String = _format_time(entry.get("time", 0.0))
		var msg: String = entry.get("message", "?")
		var err_type: String = entry.get("type", "error")

		var color := "red" if err_type == "error" else "yellow"
		var prefix := "ERR" if err_type == "error" else "WARN"
		text += "[color=%s][%s %s] %s[/color]\n" % [color, prefix, time_str, msg]

	if text.is_empty():
		text = "[color=green]No errors[/color]"

	_error_feed.text = text


func _format_time(timestamp: float) -> String:
	var msec := int(timestamp * 1000) % 1000
	var sec := int(timestamp) % 60
	var min := int(timestamp / 60) % 60
	return "%02d:%02d.%03d" % [min, sec, msec]

#endregion


#region Event Recording

func _add_recent_model(path: String, action: String) -> void:
	var entry := {
		"path": path,
		"action": action,
		"time": Time.get_ticks_msec() / 1000.0
	}
	_recent_models.append(entry)

	# Keep ring buffer size
	while _recent_models.size() > MAX_RECENT_MODELS:
		_recent_models.pop_front()


func _add_error(message: String, error_type: String = "error") -> void:
	# Deduplicate - don't add same message repeatedly
	for entry in _recent_errors:
		if entry.get("message", "") == message:
			return

	var entry := {
		"message": message,
		"type": error_type,
		"time": Time.get_ticks_msec() / 1000.0
	}
	_recent_errors.append(entry)

	# Keep ring buffer size
	while _recent_errors.size() > MAX_RECENT_ERRORS:
		_recent_errors.pop_front()

	# Emit issue signal
	var severity := Status.ERROR if error_type == "error" else Status.WARNING
	issue_detected.emit(error_type, message, severity)


## Manually log an error from external source
func log_error(message: String) -> void:
	_add_error(message, "error")


## Manually log a warning from external source
func log_warning(message: String) -> void:
	_add_error(message, "warning")


## Manually log a model load
func log_model_load(path: String, action: String = "LOADED") -> void:
	_add_recent_model(path, action)


## Clear all recorded data
func clear() -> void:
	_recent_models.clear()
	_recent_errors.clear()
	_frame_times.clear()
	_queue_unchanged_time = 0.0

#endregion


#region State Export

## Get current state as dictionary (for CrashReporter)
func get_state() -> Dictionary:
	return {
		"fps": _calculate_fps(),
		"frame_time_ms": _calculate_frame_time(),
		"queue_size": _current_stats.get("queue_size", 0),
		"near_visible": _current_stats.get("near_visible", 0),
		"mid_visible": _current_stats.get("mid_visible", 0),
		"far_visible": _current_stats.get("far_visible", 0),
		"total_objects": _current_stats.get("total_objects", 0),
		"recent_errors": _recent_errors.duplicate(),
		"recent_models": _recent_models.duplicate(),
	}

#endregion
