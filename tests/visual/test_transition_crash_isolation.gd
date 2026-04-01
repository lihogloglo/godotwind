extends Node3D

## Crash Isolation Test: Interior Transition with Streaming Manager
##
## This test proves the root cause of the indoor transition crash:
## The streaming manager detects camera at Y=-500 (pocket position) and
## unloads ALL exterior cells mid-transition, causing a use-after-free segfault.
##
## Phase 1: Transition WITH streaming pause → should succeed
## Phase 2: Transition WITHOUT streaming pause → should crash or corrupt state
##
## If Phase 1 passes and Phase 2 fails, the root cause is confirmed.

const CS := preload("res://src/core/coordinate_system.gd")
const CellManagerScript := preload("res://src/core/world/cell_manager.gd")
const InteriorPocketManagerScript := preload("res://src/core/world/interior_pocket_manager.gd")
const NativeStreamingManagerScript := preload("res://src/core/world/native_streaming_manager.gd")
const LoadingScreenScript := preload("res://src/core/ui/loading_screen.gd")

var _camera: Camera3D
var _environment: WorldEnvironment
var _sun: DirectionalLight3D
var _cell_manager: CellManagerScript
var _pocket_manager: Node
var _streaming_manager: Node
var _info_label: Label

var _phase1_passed: bool = false
var _phase2_result: String = ""

# Seyda Neen cells
const SEYDA_NEEN_CELLS: Array[Vector2i] = [
	Vector2i(-2, -9), Vector2i(-1, -9), Vector2i(-2, -8), Vector2i(-1, -8),
]


func _ready() -> void:
	_setup_environment()
	_setup_camera()
	_setup_ui()

	# Load game data
	var loading := LoadingScreenScript.new()
	add_child(loading)
	var success := await loading.load_game_data()
	loading.queue_free()
	if not success:
		_log_result("ABORT", "Failed to load game data")
		return

	# === PHASE 1: With streaming pause (should work) ===
	_log_result("START", "Phase 1: Transition WITH streaming pause")
	await _run_phase(true)

	# Reset state for Phase 2
	await _cleanup_and_reset()

	# === PHASE 2: Without streaming pause (tests the crash) ===
	_log_result("START", "Phase 2: Transition WITHOUT streaming pause")
	_log_result("INFO", "If the game crashes here, root cause is CONFIRMED")
	await _run_phase(false)

	# Summary
	_log_result("SUMMARY", "Phase 1 (with pause): %s" % ("PASS" if _phase1_passed else "FAIL"))
	_log_result("SUMMARY", "Phase 2 (no pause): %s" % _phase2_result)

	if _phase1_passed and _phase2_result != "PASS":
		_log_result("CONFIRMED", "Root cause: streaming manager unloads cells during transition when not paused")
		_info_label.text = "ROOT CAUSE CONFIRMED: Streaming manager must be paused during transitions"
	elif _phase1_passed and _phase2_result == "PASS":
		_log_result("INCONCLUSIVE", "Both phases passed — crash may require more load or timing")
		_info_label.text = "INCONCLUSIVE: Both passed. Crash may need heavier load to reproduce."
	else:
		_log_result("UNEXPECTED", "Phase 1 failed — check test setup")
		_info_label.text = "UNEXPECTED: Phase 1 failed. Check logs."

	# Keep window open for inspection
	await get_tree().create_timer(10.0).timeout
	get_tree().quit()


func _run_phase(pause_streaming: bool) -> void:
	# Create fresh cell manager
	_cell_manager = CellManagerScript.new()
	_cell_manager.load_npcs = false
	_cell_manager.load_creatures = false

	# Create streaming manager (the key addition vs the isolated test)
	_streaming_manager = NativeStreamingManagerScript.new()
	_streaming_manager.name = "StreamingManager"
	_streaming_manager.set("debug_enabled", true)
	_streaming_manager.set("async_loading_enabled", true)
	add_child(_streaming_manager)
	await get_tree().process_frame  # Ensure camera is in tree before initialize
	_streaming_manager.initialize(_cell_manager, _camera)

	# Load initial exterior cells via streaming manager
	_log_result("INFO", "Loading %d exterior cells..." % SEYDA_NEEN_CELLS.size())
	for grid: Vector2i in SEYDA_NEEN_CELLS:
		var cell_node: Node3D = _cell_manager.load_exterior_cell(grid.x, grid.y)
		if cell_node:
			_streaming_manager.add_child(cell_node)

	# Let streaming manager process a few frames
	for i in 5:
		await get_tree().process_frame

	var loaded_before: int = _count_loaded_cells()
	_log_result("INFO", "Loaded cells before transition: %d" % loaded_before)

	# Create pocket manager
	_pocket_manager = InteriorPocketManagerScript.new()
	_pocket_manager.name = "PocketManager"
	add_child(_pocket_manager)
	_pocket_manager.initialize(_cell_manager, _environment, _camera, _sun)
	_pocket_manager.seamless_enabled = false

	# Register doors
	for grid: Vector2i in SEYDA_NEEN_CELLS:
		var cell: CellRecord = ESMManager.get_exterior_cell(grid.x, grid.y)
		if cell:
			_pocket_manager.register_exterior_cell_doors(cell, grid)

	await get_tree().process_frame

	# Find door to Arrille's
	@warning_ignore("untyped_declaration")
	var target_door = _find_target_door()
	if not target_door:
		_log_result("FAIL", "No door found")
		if not pause_streaming:
			_phase2_result = "FAIL (no door)"
		return

	# Position camera near door
	_camera.global_position = target_door.world_position + Vector3(0, 3, 5)
	_camera.look_at(target_door.world_position)
	await get_tree().process_frame

	# === THE CRITICAL DIFFERENCE ===
	if pause_streaming:
		_log_result("INFO", "Pausing streaming manager before transition")
		_streaming_manager.set_process(false)
		for child: Node in _streaming_manager.get_children():
			child.set_process(false)
	else:
		_log_result("WARNING", "Streaming manager LEFT RUNNING during transition")

	# Enter interior
	_log_result("INFO", "Entering interior: %s" % target_door.target_cell_name)
	var enter_ok: bool = await _pocket_manager.enter_interior(target_door)
	_log_result("INFO", "enter_interior() returned: %s" % enter_ok)

	# Check state after transition
	var loaded_after: int = _count_loaded_cells()
	var is_inside: bool = _pocket_manager.is_inside()
	var cam_pos: Vector3 = _camera.global_position

	_log_result("INFO", "Post-transition: inside=%s, cam=%s, cells=%d (was %d)" % [
		is_inside, cam_pos, loaded_after, loaded_before])

	# Detect corruption: if cells were unloaded during transition, state is corrupted
	var cells_lost: int = loaded_before - loaded_after
	var state_corrupted: bool = cells_lost > 0 and not pause_streaming

	if enter_ok and is_inside and not state_corrupted:
		_log_result("PASS", "Phase %s: Transition succeeded" % ("1" if pause_streaming else "2"))
		if pause_streaming:
			_phase1_passed = true
		else:
			_phase2_result = "PASS"

		# Exit back to exterior
		await get_tree().create_timer(1.0).timeout
		@warning_ignore("untyped_declaration")
		var exit_door = _pocket_manager.get_closest_door()
		if exit_door:
			var exit_ok: bool = await _pocket_manager.exit_to_exterior(exit_door)
			_log_result("INFO", "Exit: %s" % exit_ok)
	elif state_corrupted:
		_log_result("FAIL", "Phase 2: STATE CORRUPTED — %d cells lost during transition" % cells_lost)
		_phase2_result = "FAIL (cells lost: %d)" % cells_lost
	else:
		_log_result("FAIL", "Phase %s: enter_interior failed" % ("1" if pause_streaming else "2"))
		if not pause_streaming:
			_phase2_result = "FAIL (enter failed)"

	# Resume streaming if paused
	if pause_streaming:
		_streaming_manager.set_process(true)
		for child: Node in _streaming_manager.get_children():
			child.set_process(true)


func _cleanup_and_reset() -> void:
	_log_result("INFO", "Cleaning up for Phase 2...")
	if _pocket_manager:
		_pocket_manager.queue_free()
		_pocket_manager = null
	if _streaming_manager:
		_streaming_manager.queue_free()
		_streaming_manager = null
	_cell_manager = null

	# Wait for cleanup
	for i in 3:
		await get_tree().process_frame

	# Reset camera to surface
	_camera.global_position = Vector3(0, 50, 0)
	_camera.cull_mask = 0x3  # Exterior layers
	_log_result("INFO", "Reset complete")


@warning_ignore("untyped_declaration")
func _find_target_door() -> Variant:
	for door in _pocket_manager._exterior_doors:
		if door.target_cell_name.to_lower().contains("arrille"):
			return door
	if not _pocket_manager._exterior_doors.is_empty():
		return _pocket_manager._exterior_doors[0]
	return null


func _count_loaded_cells() -> int:
	if not _streaming_manager:
		return 0
	var count: int = 0
	for child: Node in _streaming_manager.get_children():
		if child is Node3D and child.name != "StaticRenderer" and child.name != "ImpostorManager" and child.name != "BackgroundProcessor":
			count += 1
	return count


func _log_result(tag: String, msg: String) -> void:
	var line := "[CRASH_ISO][%s] %s" % [tag, msg]
	Log.info("testing", line)
	if _info_label:
		_info_label.text = "[%s] %s" % [tag, msg]


func _setup_environment() -> void:
	_environment = WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.38, 0.45, 0.55)
	mat.sky_horizon_color = Color(0.64, 0.68, 0.74)
	sky.sky_material = mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 0.5
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_environment.environment = env
	add_child(_environment)

	_sun = DirectionalLight3D.new()
	_sun.name = "Sun"
	_sun.rotation_degrees = Vector3(-45, 45, 0)
	_sun.shadow_enabled = true
	_sun.light_energy = 1.2
	add_child(_sun)


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "TestCamera"
	_camera.current = true
	_camera.far = 2000.0
	_camera.cull_mask = 0x3  # Exterior layers
	add_child(_camera)


func _setup_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_info_label = Label.new()
	_info_label.position = Vector2(10, 10)
	_info_label.add_theme_font_size_override("font_size", 18)
	_info_label.add_theme_color_override("font_color", Color.YELLOW)
	_info_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_info_label.add_theme_constant_override("shadow_offset_x", 1)
	_info_label.add_theme_constant_override("shadow_offset_y", 1)
	canvas.add_child(_info_label)
