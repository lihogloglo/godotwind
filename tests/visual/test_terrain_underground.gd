extends Node3D

## Terrain3D Underground Crash Isolation Test
##
## Tests whether Terrain3D crashes when the camera is at Y=-500
## (the pocket interior position). This isolates the root cause of
## the indoor transition crash from all other systems.
##
## Test sequence (fully automated, no interaction needed):
##   Phase 1: Camera at surface (Y=100) — baseline, 3 seconds
##   Phase 2: Camera at Y=-500 WITH Terrain3D visible — crash test, 3 seconds
##   Phase 3: Camera back at surface — recovery test, 2 seconds
##   Phase 4: Camera at Y=-500 with Terrain3D HIDDEN — safe path, 3 seconds
##   Phase 5: Camera at surface, Terrain3D restored — cleanup, 2 seconds
##
## If Phase 2 crashes (segfault), Terrain3D at Y=-500 is confirmed as the
## root cause. If it survives all phases, the crash was caused by something else.
##
## ESC to quit early.

const CS := preload("res://src/core/coordinate_system.gd")

var _camera: Camera3D
var _environment: WorldEnvironment
var _sun: DirectionalLight3D
var _terrain: Terrain3D
var _info_label: Label
var _phase: int = 0
var _phase_timer: float = 0.0
var _test_complete: bool = false

const SURFACE_Y: float = 100.0
const UNDERGROUND_Y: float = -500.0
# Camera position: roughly Seyda Neen area
const TEST_POS_X: float = -190.0
const TEST_POS_Z: float = 1050.0

const PHASE_DURATIONS: Array[float] = [3.0, 3.0, 2.0, 3.0, 2.0]
const PHASE_NAMES: Array[String] = [
	"Surface baseline",
	"Underground WITH Terrain3D visible (CRASH TEST)",
	"Recovery — back at surface",
	"Underground with Terrain3D HIDDEN (safe path)",
	"Surface — Terrain3D restored (cleanup)",
]


func _ready() -> void:
	_setup_environment()
	_setup_camera()
	_setup_ui()
	await _setup_terrain()

	if not _terrain:
		_log_result("ABORT: Could not set up Terrain3D — test cannot run")
		return

	# Start Phase 0
	_start_phase(0)


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
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_environment.environment = env
	add_child(_environment)

	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-45, 45, 0)
	_sun.shadow_enabled = true
	add_child(_sun)


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "TestCamera"
	_camera.current = true
	_camera.far = 5000.0
	_camera.position = Vector3(TEST_POS_X, SURFACE_Y, TEST_POS_Z)
	add_child(_camera)


func _setup_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_info_label = Label.new()
	_info_label.position = Vector2(10, 10)
	_info_label.add_theme_font_size_override("font_size", 20)
	_info_label.add_theme_color_override("font_color", Color.WHITE)
	_info_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_info_label.add_theme_constant_override("shadow_offset_x", 2)
	_info_label.add_theme_constant_override("shadow_offset_y", 2)
	canvas.add_child(_info_label)


func _setup_terrain() -> void:
	if not ClassDB.class_exists("Terrain3DData"):
		_log_result("SKIP: Terrain3D addon not available")
		return

	_terrain = Terrain3D.new()
	_terrain.name = "Terrain3D"
	add_child(_terrain)

	# Re-disable physics — Terrain3D C++ ENTER_TREE re-enables it
	_terrain.set_physics_process(false)
	_terrain.set_process(false)

	# Wait for Terrain3D to initialize (needs to be in tree for .data)
	await get_tree().process_frame

	if not CS.configure_terrain3d(_terrain):
		_log_result("WARN: configure_terrain3d failed — terrain may not have data")

	# Load preprocessed terrain data
	var terrain_data_dir := SettingsManager.get_terrain_path()
	if DirAccess.dir_exists_absolute(terrain_data_dir) and _terrain.data:
		_terrain.data.load_directory(terrain_data_dir)
		_log_result("Terrain loaded from: %s" % terrain_data_dir)
	else:
		_log_result("WARN: No preprocessed terrain data at %s" % terrain_data_dir)


func _start_phase(phase_idx: int) -> void:
	_phase = phase_idx
	_phase_timer = 0.0

	_log_result("=== PHASE %d: %s ===" % [phase_idx, PHASE_NAMES[phase_idx]])

	match phase_idx:
		0:  # Surface baseline
			_camera.position = Vector3(TEST_POS_X, SURFACE_Y, TEST_POS_Z)
			if _terrain:
				_terrain.visible = true
			_log_result("Camera at Y=%.0f, Terrain3D visible=true" % SURFACE_Y)

		1:  # Underground WITH terrain visible (the crash test)
			_camera.position = Vector3(TEST_POS_X, UNDERGROUND_Y, TEST_POS_Z)
			# Terrain stays visible — this is the dangerous state
			_log_result("Camera at Y=%.0f, Terrain3D visible=true — TESTING FOR CRASH" % UNDERGROUND_Y)

		2:  # Recovery
			_camera.position = Vector3(TEST_POS_X, SURFACE_Y, TEST_POS_Z)
			_log_result("Camera back at Y=%.0f — survived Phase 1!" % SURFACE_Y)

		3:  # Underground with terrain hidden (safe path)
			if _terrain:
				_terrain.visible = false
			_camera.position = Vector3(TEST_POS_X, UNDERGROUND_Y, TEST_POS_Z)
			_log_result("Camera at Y=%.0f, Terrain3D visible=false (safe path)" % UNDERGROUND_Y)

		4:  # Cleanup
			_camera.position = Vector3(TEST_POS_X, SURFACE_Y, TEST_POS_Z)
			if _terrain:
				_terrain.visible = true
			_log_result("Camera at Y=%.0f, Terrain3D restored — test complete" % SURFACE_Y)


@warning_ignore("untyped_declaration")
func _process(delta: float) -> void:
	if _test_complete:
		return

	_phase_timer += delta

	# Update UI
	var phase_name: String = PHASE_NAMES[_phase] if _phase < PHASE_NAMES.size() else "Done"
	var remaining: float = PHASE_DURATIONS[_phase] - _phase_timer if _phase < PHASE_DURATIONS.size() else 0.0
	_info_label.text = "Phase %d/%d: %s\nTime: %.1fs / %.1fs\nCamera Y: %.1f\nTerrain3D visible: %s\nFPS: %.0f" % [
		_phase + 1, PHASE_NAMES.size(), phase_name, _phase_timer,
		PHASE_DURATIONS[_phase] if _phase < PHASE_DURATIONS.size() else 0.0,
		_camera.global_position.y,
		str(_terrain.visible) if _terrain else "N/A",
		Engine.get_frames_per_second(),
	]

	# Advance phase when timer expires
	if _phase < PHASE_DURATIONS.size() and _phase_timer >= PHASE_DURATIONS[_phase]:
		var next_phase: int = _phase + 1
		if next_phase < PHASE_NAMES.size():
			_start_phase(next_phase)
		else:
			_test_complete = true
			_log_result("=== ALL PHASES COMPLETE — NO CRASH ===")
			_log_result("CONCLUSION: Terrain3D at Y=-500 does NOT crash by itself.")
			_log_result("The crash must have been caused by interaction with another system.")
			_info_label.text = "TEST COMPLETE — ALL PHASES PASSED\nNo Terrain3D crash at Y=-500\nPress ESC to quit"


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_log_result("Test aborted by user (ESC)")
		get_tree().quit()


func _log_result(msg: String) -> void:
	Log.info("testing", "[TERRAIN_UNDERGROUND] %s" % msg)
	print("[TERRAIN_UNDERGROUND] %s" % msg)
