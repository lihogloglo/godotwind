## Automated Test Runner - Semi-automated testing system for world exploration
##
## This system moves the camera along predefined paths while automatically
## enabling various systems (models, sky, ocean) to test loading performance
## and capture errors/warnings.
##
## Usage:
##   1. Add this script to the world explorer scene
##   2. Press F6 to start automated test
##   3. Press F7 to stop test
##   4. Press F8 to show test report
##
## The test will:
##   - Move camera through key locations in the world
##   - Enable models, sky, and ocean progressively
##   - Record loading times, errors, and performance metrics
##   - Generate a detailed report at the end
class_name AutomatedTestRunner
extends Node


## Emitted when test run starts
signal test_started
## Emitted when test run completes
signal test_completed(report: Dictionary)
## Emitted when an error is captured
signal error_captured(error: String)
## Emitted when arriving at a waypoint
signal waypoint_reached(waypoint_name: String)


## Test configuration
@export_group("Test Configuration")
## Camera movement speed during test (m/s)
@export var test_speed: float = 100.0
## Time to wait at each waypoint (seconds)
@export var waypoint_wait_time: float = 3.0
## Whether to enable models during test
@export var test_models: bool = true
## Whether to enable sky during test
@export var test_sky: bool = true
## Whether to enable ocean during test
@export var test_ocean: bool = true
## Whether to enable characters during test
@export var test_characters: bool = false


## Test state
enum TestState { IDLE, INITIALIZING, RUNNING, PAUSED, COMPLETED }
var _state: TestState = TestState.IDLE

## Waypoint definition
class Waypoint:
	var name: String
	var position: Vector3
	var look_target: Vector3
	var wait_time: float
	var enable_models: bool
	var enable_sky: bool
	var enable_ocean: bool

	func _init(p_name: String, p_pos: Vector3, p_target: Vector3 = Vector3.ZERO,
			   p_wait: float = 3.0, p_models: bool = false, p_sky: bool = false, p_ocean: bool = false) -> void:
		name = p_name
		position = p_pos
		look_target = p_target if p_target != Vector3.ZERO else p_pos + Vector3(0, -10, -50)
		wait_time = p_wait
		enable_models = p_models
		enable_sky = p_sky
		enable_ocean = p_ocean


## Current waypoint index
var _current_waypoint_idx: int = 0
## List of waypoints to visit
var _waypoints: Array[Waypoint] = []
## Reference to world explorer
var _world_explorer: Node3D = null
## Reference to fly camera
var _fly_camera: Camera3D = null
## Whether camera is currently moving
var _is_moving: bool = false
## Target position for camera movement
var _target_position: Vector3 = Vector3.ZERO
## Target look direction
var _target_look: Vector3 = Vector3.ZERO
## Time spent at current waypoint
var _wait_timer: float = 0.0

## Error/warning capture
var _captured_errors: Array[Dictionary] = []
var _captured_warnings: Array[Dictionary] = []
var _test_start_time: float = 0.0
var _waypoint_start_time: float = 0.0

## Performance tracking
var _frame_times: Array[float] = []
var _loading_times: Dictionary = {}  # waypoint_name -> loading_time
var _cell_load_counts: Dictionary = {}  # waypoint_name -> cells_loaded


func _ready() -> void:
	# Find world explorer
	_world_explorer = get_parent() as Node3D
	if not _world_explorer:
		push_error("AutomatedTestRunner: Must be a child of world_explorer")
		return

	# Get fly camera reference
	_fly_camera = _world_explorer.get_node_or_null("FlyCamera") as Camera3D

	# Setup default waypoints
	_setup_default_waypoints()


func _process(delta: float) -> void:
	if _state != TestState.RUNNING:
		return

	# Record frame time
	_frame_times.append(delta * 1000.0)  # Convert to ms

	if _is_moving:
		_update_camera_movement(delta)
	else:
		_update_waypoint_wait(delta)


func _input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var key_event: InputEventKey = event as InputEventKey
	if not key_event.pressed:
		return

	match key_event.keycode:
		KEY_F6:
			if _state == TestState.IDLE or _state == TestState.COMPLETED:
				start_test()
		KEY_F7:
			if _state == TestState.RUNNING:
				stop_test()
		KEY_F8:
			print_report()


## Setup default test waypoints covering key areas
func _setup_default_waypoints() -> void:
	_waypoints.clear()

	# Helper to convert cell coordinates to world position
	# Cell size is 8192 units, center at (0,0)
	var cell_size: float = 8192.0

	# Starting point - high altitude overview
	_waypoints.append(Waypoint.new(
		"Overview Start",
		Vector3(0, 500, 0),
		Vector3(0, 0, -100),
		2.0, false, false, false
	))

	# Seyda Neen area - enable models first
	_waypoints.append(Waypoint.new(
		"Seyda Neen Approach",
		Vector3(-2 * cell_size, 200, -9 * cell_size),
		Vector3(-2 * cell_size, 0, -9 * cell_size - 200),
		3.0, true, false, false  # Enable models
	))

	_waypoints.append(Waypoint.new(
		"Seyda Neen Harbor",
		Vector3(-2 * cell_size - 1000, 50, -9 * cell_size + 500),
		Vector3(-2 * cell_size, 0, -9 * cell_size),
		4.0, true, true, false  # Enable sky
	))

	_waypoints.append(Waypoint.new(
		"Seyda Neen Coast",
		Vector3(-2 * cell_size - 2000, 30, -9 * cell_size),
		Vector3(-2 * cell_size, 0, -9 * cell_size),
		4.0, true, true, true  # Enable ocean
	))

	# Move along coast
	_waypoints.append(Waypoint.new(
		"Western Coast",
		Vector3(-4 * cell_size, 50, -8 * cell_size),
		Vector3(-3 * cell_size, 0, -7 * cell_size),
		3.0, true, true, true
	))

	# Balmora area
	_waypoints.append(Waypoint.new(
		"Balmora Approach",
		Vector3(-3 * cell_size, 150, -2 * cell_size),
		Vector3(-3 * cell_size, 0, -2 * cell_size - 200),
		3.0, true, true, true
	))

	_waypoints.append(Waypoint.new(
		"Balmora City",
		Vector3(-3 * cell_size + 500, 80, -2 * cell_size + 500),
		Vector3(-3 * cell_size, 0, -2 * cell_size),
		4.0, true, true, true
	))

	# Vivec approach
	_waypoints.append(Waypoint.new(
		"Vivec Approach",
		Vector3(5 * cell_size, 200, -6 * cell_size - 2000),
		Vector3(5 * cell_size, 0, -6 * cell_size),
		3.0, true, true, true
	))

	_waypoints.append(Waypoint.new(
		"Vivec Canton",
		Vector3(5 * cell_size + 1000, 100, -6 * cell_size + 1000),
		Vector3(5 * cell_size, 50, -6 * cell_size),
		4.0, true, true, true
	))

	# Sadrith Mora / Eastern area
	_waypoints.append(Waypoint.new(
		"Eastern Islands",
		Vector3(10 * cell_size, 150, 5 * cell_size),
		Vector3(10 * cell_size + 500, 0, 5 * cell_size + 500),
		3.0, true, true, true
	))

	# Red Mountain area
	_waypoints.append(Waypoint.new(
		"Red Mountain Vista",
		Vector3(3 * cell_size, 500, 6 * cell_size),
		Vector3(0, 300, 3 * cell_size),
		4.0, true, true, false
	))

	# Final overview
	_waypoints.append(Waypoint.new(
		"Final Overview",
		Vector3(0, 800, 0),
		Vector3(0, 0, -500),
		3.0, true, true, true
	))


## Add a custom waypoint to the test path
func add_waypoint(wp_name: String, wp_position: Vector3, look_target: Vector3 = Vector3.ZERO,
				  wait_time: float = 3.0, models: bool = true, sky: bool = true, ocean: bool = true) -> void:
	_waypoints.append(Waypoint.new(wp_name, wp_position, look_target, wait_time, models, sky, ocean))


## Clear all waypoints
func clear_waypoints() -> void:
	_waypoints.clear()


## Start the automated test
func start_test() -> void:
	if _waypoints.is_empty():
		push_error("AutomatedTestRunner: No waypoints defined")
		return

	if not _fly_camera:
		_fly_camera = _world_explorer.get_node_or_null("FlyCamera") as Camera3D
		if not _fly_camera:
			push_error("AutomatedTestRunner: FlyCamera not found")
			return

	# Reset state
	_state = TestState.INITIALIZING
	_current_waypoint_idx = 0
	_captured_errors.clear()
	_captured_warnings.clear()
	_frame_times.clear()
	_loading_times.clear()
	_cell_load_counts.clear()
	_test_start_time = Time.get_ticks_msec() / 1000.0

	# Ensure fly camera is active and enabled
	if _world_explorer.has_method("_switch_to_fly_camera"):
		_world_explorer.call("_switch_to_fly_camera")

	# Disable user input on fly camera during test
	if _fly_camera.has_method("set"):
		_fly_camera.set("enabled", false)

	_log("[color=cyan]========================================[/color]")
	_log("[color=cyan]AUTOMATED TEST STARTED[/color]")
	_log("[color=cyan]Waypoints: %d[/color]" % _waypoints.size())
	_log("[color=cyan]Press F7 to stop, F8 for report[/color]")
	_log("[color=cyan]========================================[/color]")

	# Start first waypoint
	_state = TestState.RUNNING
	_start_waypoint(0)

	test_started.emit()


## Stop the automated test
func stop_test() -> void:
	if _state != TestState.RUNNING:
		return

	_state = TestState.COMPLETED

	# Re-enable fly camera
	if _fly_camera:
		_fly_camera.set("enabled", true)

	var duration: float = (Time.get_ticks_msec() / 1000.0) - _test_start_time

	_log("[color=yellow]========================================[/color]")
	_log("[color=yellow]TEST STOPPED[/color]")
	_log("[color=yellow]Duration: %.1f seconds[/color]" % duration)
	_log("[color=yellow]Waypoints visited: %d/%d[/color]" % [_current_waypoint_idx, _waypoints.size()])
	_log("[color=yellow]========================================[/color]")

	var report: Dictionary = _generate_report()
	test_completed.emit(report)


## Start moving to a waypoint
func _start_waypoint(idx: int) -> void:
	if idx >= _waypoints.size():
		_complete_test()
		return

	_current_waypoint_idx = idx
	var waypoint: Waypoint = _waypoints[idx]
	_waypoint_start_time = Time.get_ticks_msec() / 1000.0

	_log("[color=green]>> Waypoint %d/%d: %s[/color]" % [idx + 1, _waypoints.size(), waypoint.name])

	# Record cell count before moving
	var wsm: Node = _world_explorer.get_node_or_null("WorldStreamingManager")
	if wsm and wsm.has_method("get_stats"):
		var stats: Dictionary = wsm.call("get_stats")
		_cell_load_counts[waypoint.name + "_start"] = stats.get("loaded_cells", 0)

	# Enable systems based on waypoint config
	_apply_waypoint_systems(waypoint)

	# Start moving to waypoint
	_target_position = waypoint.position
	_target_look = waypoint.look_target
	_is_moving = true


## Apply system toggles for a waypoint
func _apply_waypoint_systems(waypoint: Waypoint) -> void:
	# Models toggle
	if waypoint.enable_models and test_models:
		var show_models: bool = _world_explorer.get("_show_models") as bool
		if not show_models:
			var toggle: CheckBox = _world_explorer.get("_show_models_toggle") as CheckBox
			if toggle:
				toggle.button_pressed = true
			if _world_explorer.has_method("_on_show_models_toggled"):
				_world_explorer.call("_on_show_models_toggled", true)
			_log("  [Models: ON]")

	# Sky toggle
	if waypoint.enable_sky and test_sky:
		var show_sky: bool = _world_explorer.get("_show_sky") as bool
		if not show_sky:
			var toggle: CheckBox = _world_explorer.get("_show_sky_toggle") as CheckBox
			if toggle:
				toggle.button_pressed = true
			if _world_explorer.has_method("_on_show_sky_toggled"):
				_world_explorer.call("_on_show_sky_toggled", true)
			_log("  [Sky: ON]")

	# Ocean toggle
	if waypoint.enable_ocean and test_ocean:
		var show_ocean: bool = _world_explorer.get("_show_ocean") as bool
		if not show_ocean:
			var toggle: CheckBox = _world_explorer.get("_show_ocean_toggle") as CheckBox
			if toggle:
				toggle.button_pressed = true
			if _world_explorer.has_method("_on_show_ocean_toggled"):
				_world_explorer.call("_on_show_ocean_toggled", true)
			_log("  [Ocean: ON]")


## Update camera movement towards target
func _update_camera_movement(delta: float) -> void:
	if not _fly_camera:
		return

	var current_pos: Vector3 = _fly_camera.global_position
	var direction: Vector3 = (_target_position - current_pos).normalized()
	var distance: float = current_pos.distance_to(_target_position)

	if distance < 10.0:
		# Arrived at waypoint
		_fly_camera.global_position = _target_position
		_fly_camera.look_at(_target_look, Vector3.UP)
		_is_moving = false
		_wait_timer = 0.0

		# Record loading time
		var load_time: float = (Time.get_ticks_msec() / 1000.0) - _waypoint_start_time
		_loading_times[_waypoints[_current_waypoint_idx].name] = load_time

		# Record cell count after arriving
		var wsm: Node = _world_explorer.get_node_or_null("WorldStreamingManager")
		if wsm and wsm.has_method("get_stats"):
			var stats: Dictionary = wsm.call("get_stats")
			_cell_load_counts[_waypoints[_current_waypoint_idx].name + "_end"] = stats.get("loaded_cells", 0)

		_log("  Arrived (%.1fs)" % load_time)
		waypoint_reached.emit(_waypoints[_current_waypoint_idx].name)
	else:
		# Move towards target
		var move_amount: float = test_speed * delta
		if move_amount > distance:
			move_amount = distance
		_fly_camera.global_position += direction * move_amount

		# Smoothly rotate towards target
		var look_dir: Vector3 = _target_look - _fly_camera.global_position
		if look_dir.length() > 0.001:
			var target_basis: Basis = Basis.looking_at(look_dir, Vector3.UP)
			_fly_camera.basis = _fly_camera.basis.slerp(target_basis, delta * 2.0)


## Update wait time at current waypoint
func _update_waypoint_wait(delta: float) -> void:
	_wait_timer += delta

	var wait_time: float = _waypoints[_current_waypoint_idx].wait_time
	if _wait_timer >= wait_time:
		_start_waypoint(_current_waypoint_idx + 1)


## Complete the test run
func _complete_test() -> void:
	_state = TestState.COMPLETED

	# Re-enable fly camera
	if _fly_camera:
		_fly_camera.set("enabled", true)

	var duration: float = (Time.get_ticks_msec() / 1000.0) - _test_start_time

	_log("[color=green]========================================[/color]")
	_log("[color=green]TEST COMPLETED[/color]")
	_log("[color=green]Duration: %.1f seconds[/color]" % duration)
	_log("[color=green]Errors: %d, Warnings: %d[/color]" % [_captured_errors.size(), _captured_warnings.size()])
	_log("[color=green]========================================[/color]")

	var report: Dictionary = _generate_report()
	test_completed.emit(report)

	# Auto-print report
	print_report()


## Generate test report
func _generate_report() -> Dictionary:
	var duration: float = (Time.get_ticks_msec() / 1000.0) - _test_start_time

	# Calculate frame time statistics
	var avg_frame_time: float = 0.0
	var max_frame_time: float = 0.0
	var min_frame_time: float = 999999.0
	var p95_frame_time: float = 0.0

	if not _frame_times.is_empty():
		var sorted_times: Array[float] = _frame_times.duplicate()
		sorted_times.sort()

		var sum: float = 0.0
		for t: float in sorted_times:
			sum += t
			if t > max_frame_time:
				max_frame_time = t
			if t < min_frame_time:
				min_frame_time = t

		avg_frame_time = sum / float(sorted_times.size())
		var p95_idx: int = int(sorted_times.size() * 0.95)
		p95_frame_time = sorted_times[p95_idx]

	# Group errors by type
	var error_groups: Dictionary = {}
	for err: Dictionary in _captured_errors:
		var msg: String = str(err.get("message", "Unknown"))
		# Extract first line or first 100 chars as key
		var newline_pos: int = msg.find("\n")
		var key_len: int = 100
		if newline_pos > 0 and newline_pos < key_len:
			key_len = newline_pos
		var key: String = msg.substr(0, key_len)
		if not error_groups.has(key):
			error_groups[key] = {"count": 0, "first_time": err.get("time", 0.0), "samples": []}
		var group: Dictionary = error_groups[key]
		var count_val: Variant = group["count"]
		group["count"] = (count_val as int) + 1
		var samples: Array = group["samples"] as Array
		if samples.size() < 3:
			samples.append(msg)

	var warning_groups: Dictionary = {}
	for warn: Dictionary in _captured_warnings:
		var warn_msg: String = str(warn.get("message", "Unknown"))
		var warn_newline_pos: int = warn_msg.find("\n")
		var warn_key_len: int = 100
		if warn_newline_pos > 0 and warn_newline_pos < warn_key_len:
			warn_key_len = warn_newline_pos
		var warn_key: String = warn_msg.substr(0, warn_key_len)
		if not warning_groups.has(warn_key):
			warning_groups[warn_key] = {"count": 0, "first_time": warn.get("time", 0.0), "samples": []}
		var warn_group: Dictionary = warning_groups[warn_key]
		var warn_count_val: Variant = warn_group["count"]
		warn_group["count"] = (warn_count_val as int) + 1
		var warn_samples: Array = warn_group["samples"] as Array
		if warn_samples.size() < 3:
			warn_samples.append(warn_msg)

	return {
		"test_info": {
			"duration_seconds": duration,
			"waypoints_total": _waypoints.size(),
			"waypoints_completed": _current_waypoint_idx,
			"test_speed": test_speed,
		},
		"performance": {
			"avg_fps": 1000.0 / avg_frame_time if avg_frame_time > 0 else 0.0,
			"avg_frame_time_ms": avg_frame_time,
			"min_frame_time_ms": min_frame_time if min_frame_time < 999999.0 else 0.0,
			"max_frame_time_ms": max_frame_time,
			"p95_frame_time_ms": p95_frame_time,
			"frame_samples": _frame_times.size(),
		},
		"loading": {
			"waypoint_times": _loading_times.duplicate(),
			"cell_counts": _cell_load_counts.duplicate(),
		},
		"errors": {
			"total_count": _captured_errors.size(),
			"unique_count": error_groups.size(),
			"groups": error_groups,
		},
		"warnings": {
			"total_count": _captured_warnings.size(),
			"unique_count": warning_groups.size(),
			"groups": warning_groups,
		},
	}


## Print formatted report to console
func print_report() -> void:
	var report: Dictionary = _generate_report()

	print("\n")
	print("╔════════════════════════════════════════════════════════════════╗")
	print("║               AUTOMATED TEST REPORT                            ║")
	print("╠════════════════════════════════════════════════════════════════╣")

	# Test info
	var info: Dictionary = report.get("test_info", {})
	var duration_val: float = info.get("duration_seconds", 0.0) as float
	var wp_completed: int = info.get("waypoints_completed", 0) as int
	var wp_total: int = info.get("waypoints_total", 0) as int
	print("║ Duration: %.1f seconds" % duration_val)
	print("║ Waypoints: %d/%d completed" % [wp_completed, wp_total])

	# Performance
	var perf: Dictionary = report.get("performance", {})
	print("╠════════════════════════════════════════════════════════════════╣")
	print("║ PERFORMANCE")
	var avg_fps: float = perf.get("avg_fps", 0.0) as float
	var avg_ft: float = perf.get("avg_frame_time_ms", 0.0) as float
	var p95_ft: float = perf.get("p95_frame_time_ms", 0.0) as float
	var max_ft: float = perf.get("max_frame_time_ms", 0.0) as float
	print("║   Avg FPS: %.1f" % avg_fps)
	print("║   Frame time: %.2fms avg, %.2fms P95, %.2fms max" % [avg_ft, p95_ft, max_ft])

	# Loading times
	var loading: Dictionary = report.get("loading", {})
	var times: Dictionary = loading.get("waypoint_times", {})
	if not times.is_empty():
		print("╠════════════════════════════════════════════════════════════════╣")
		print("║ LOADING TIMES (by waypoint)")
		for wp_name: String in times.keys():
			var time_val: float = times[wp_name] as float
			print("║   %s: %.2fs" % [wp_name, time_val])

	# Errors
	var errors: Dictionary = report.get("errors", {})
	print("╠════════════════════════════════════════════════════════════════╣")
	var err_total: int = errors.get("total_count", 0) as int
	var err_unique: int = errors.get("unique_count", 0) as int
	print("║ ERRORS: %d total (%d unique)" % [err_total, err_unique])
	var error_groups_dict: Dictionary = errors.get("groups", {})
	for key: String in error_groups_dict.keys():
		var group: Dictionary = error_groups_dict[key]
		var cnt: int = group.get("count", 0) as int
		print("║   [x%d] %s" % [cnt, key.substr(0, 60)])

	# Warnings
	var warnings: Dictionary = report.get("warnings", {})
	print("╠════════════════════════════════════════════════════════════════╣")
	var warn_total: int = warnings.get("total_count", 0) as int
	var warn_unique: int = warnings.get("unique_count", 0) as int
	print("║ WARNINGS: %d total (%d unique)" % [warn_total, warn_unique])
	var warning_groups_dict: Dictionary = warnings.get("groups", {})
	var shown: int = 0
	for key: String in warning_groups_dict.keys():
		if shown >= 10:
			print("║   ... and %d more warning types" % (warning_groups_dict.size() - shown))
			break
		var group: Dictionary = warning_groups_dict[key]
		var cnt: int = group.get("count", 0) as int
		print("║   [x%d] %s" % [cnt, key.substr(0, 60)])
		shown += 1

	print("╚════════════════════════════════════════════════════════════════╝")
	print("\n")


## Capture an error during the test
func capture_error(message: String) -> void:
	var time_offset: float = (Time.get_ticks_msec() / 1000.0) - _test_start_time
	var wp_name: String = "unknown"
	if _current_waypoint_idx < _waypoints.size():
		wp_name = _waypoints[_current_waypoint_idx].name
	_captured_errors.append({
		"time": time_offset,
		"message": message,
		"waypoint": wp_name
	})
	error_captured.emit(message)


## Capture a warning during the test
func capture_warning(message: String) -> void:
	var time_offset: float = (Time.get_ticks_msec() / 1000.0) - _test_start_time
	var wp_name: String = "unknown"
	if _current_waypoint_idx < _waypoints.size():
		wp_name = _waypoints[_current_waypoint_idx].name
	_captured_warnings.append({
		"time": time_offset,
		"message": message,
		"waypoint": wp_name
	})


## Get current test state
func get_state() -> TestState:
	return _state


## Get current waypoint index
func get_current_waypoint() -> int:
	return _current_waypoint_idx


## Get total waypoint count
func get_waypoint_count() -> int:
	return _waypoints.size()


## Log to world explorer's log panel
func _log(message: String) -> void:
	if _world_explorer and _world_explorer.has_method("_log"):
		_world_explorer.call("_log", message)
	else:
		# Strip BBCode for console
		var clean: String = message
		clean = clean.replace("[color=green]", "").replace("[color=cyan]", "")
		clean = clean.replace("[color=yellow]", "").replace("[color=red]", "")
		clean = clean.replace("[/color]", "")
		print(clean)
