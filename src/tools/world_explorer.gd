## World Explorer - Morrowind world exploration orchestrator
##
## This is the main scene script. It wires together all subsystems and handles
## initialization, camera switching, input routing, and the frame loop.
## Heavy logic has been extracted into focused RefCounted classes:
##
##   ExplorerPanels      — UI panel construction (src/tools/ui/explorer_panels.gd)
##   CellBrowser         — Interior/exterior cell browser (src/tools/ui/cell_browser.gd)
##   OceanControls       — Ocean/water system (src/tools/ui/ocean_controls.gd)
##   EnvironmentControls — Shader effects + sky (src/tools/ui/environment_controls.gd)
##   StatsCollector      — Performance stats display (src/tools/ui/stats_collector.gd)
##   TerrainPreprocessor — Terrain prebaking (src/tools/ui/terrain_preprocessor.gd)
##   LodDebugCommands    — LOD console commands (src/tools/lod_debug_commands.gd)
##   ProfilingReport     — UI log profiling (src/tools/profiling_report.gd)
##
## Controls:
##   ~     Developer console       P     Toggle camera mode
##   F3    Performance overlay     F4    Profiling report
##   F9    Debug overlay           F11   State dump
##   F12   Auto-test mode          TAB   World/Interior toggle
##   N     NPCs toggle             O     Ocean toggle
##   K     Sky toggle              +/-   View distance
##
## Fly Camera: Hold Right-click to look, WASD to move, Space/Shift for up/down
## Player: WASD to move, Space to jump, Shift to run, mouse to look
extends Node3D

# Preload dependencies
const NativeStreamingManagerScript := preload("res://src/core/world/native_streaming_manager.gd")
const StreamingConfig := preload("res://src/core/world/streaming_config.gd")
const TerrainManagerScript := preload("res://src/core/world/terrain_manager.gd")
const TerrainTextureLoaderScript := preload("res://src/core/world/terrain_texture_loader.gd")
const CellManagerScript := preload("res://src/core/world/cell_manager.gd")
const ObjectPoolScript := preload("res://src/core/world/object_pool.gd")
const CS := preload("res://src/core/coordinate_system.gd")
const PerformanceProfilerScript := preload("res://src/core/world/performance_profiler.gd")
const OceanControlsScript := preload("res://src/tools/ui/ocean_controls.gd")
const EnvironmentControlsScript := preload("res://src/tools/ui/environment_controls.gd")
const StatsCollectorScript := preload("res://src/tools/ui/stats_collector.gd")
const TerrainPreprocessorScript := preload("res://src/tools/ui/terrain_preprocessor.gd")
const BackgroundProcessorScript := preload("res://src/core/streaming/background_processor.gd")
const FlyCameraScript := preload("res://src/core/player/fly_camera.gd")
const PlayerControllerScript := preload("res://src/core/player/player_controller.gd")
const ConsoleScript := preload("res://src/core/console/console.gd")
const AutomatedTestRunnerScript := preload("res://src/tools/automated_test_runner.gd")
const ExplorerPanelsScript := preload("res://src/tools/ui/explorer_panels.gd")
const CellBrowserScript := preload("res://src/tools/ui/cell_browser.gd")
const DebugOverlayScript := preload("res://src/tools/ui/debug_overlay.gd")
const StreamingProfilerScript := preload("res://src/core/world/streaming_profiler.gd")
const DiagnosticOverlayScript := preload("res://src/tools/ui/diagnostic_overlay.gd")
const CrashReporterScript := preload("res://src/tools/crash_reporter.gd")
const DebugSystemScript := preload("res://src/tools/debug_system.gd")
const StreamingBenchmarkScript := preload("res://src/tools/streaming_benchmark.gd")
const LodTransitionTestScript := preload("res://src/tools/lod_transition_test.gd")
# Note: HardwareDetection is accessed via class_name, no preload needed


# Node references
@onready var camera: Camera3D = $FlyCamera
@onready var terrain_3d: Terrain3D = $Terrain3D
@onready var loading_overlay: ColorRect = $UI/LoadingOverlay
@onready var loading_label: Label = $UI/LoadingOverlay/VBox/LoadingLabel
@onready var progress_bar: ProgressBar = $UI/LoadingOverlay/VBox/ProgressBar
@onready var status_label: Label = $UI/LoadingOverlay/VBox/StatusLabel
@onready var stats_panel: Panel = $UI/StatsPanel
@onready var log_text: RichTextLabel = $UI/LogPanel/VBox/LogText

# Quick teleport buttons
@onready var seyda_neen_btn: Button = $UI/StatsPanel/VBox/QuickButtons/SeydaNeenBtn
@onready var balmora_btn: Button = $UI/StatsPanel/VBox/QuickButtons/BalmoraBtn
@onready var vivec_btn: Button = $UI/StatsPanel/VBox/QuickButtons/VivecBtn
@onready var origin_btn: Button = $UI/StatsPanel/VBox/QuickButtons/OriginBtn

# Terrain preprocessing UI
@onready var preprocess_btn: Button = $UI/StatsPanel/VBox/PreprocessBtn
@onready var preprocess_status: Label = $UI/StatsPanel/VBox/PreprocessStatus

# UI panels (constructed by ExplorerPanels)
var _panels: ExplorerPanels = null
# Models are always visible (no toggle needed)
var _show_characters: bool = false  # Default OFF - separate from static models

# Debug overlay for 3D visualizations
var _debug_overlay: Node3D = null
var _show_chunk_debug: bool = false
var _show_tier_debug: bool = false
var _show_cell_debug: bool = false

# Interior cell browser UI (will be added to scene)
@onready var interior_panel: Panel = $UI/InteriorPanel if has_node("UI/InteriorPanel") else null
@onready var cell_search_edit: LineEdit = $UI/InteriorPanel/VBox/SearchEdit if has_node("UI/InteriorPanel/VBox/SearchEdit") else null
@onready var cell_list: ItemList = $UI/InteriorPanel/VBox/CellList if has_node("UI/InteriorPanel/VBox/CellList") else null
@onready var interior_filter_btn: Button = $UI/InteriorPanel/VBox/FilterButtons/InteriorBtn if has_node("UI/InteriorPanel/VBox/FilterButtons/InteriorBtn") else null
@onready var exterior_filter_btn: Button = $UI/InteriorPanel/VBox/FilterButtons/ExteriorBtn if has_node("UI/InteriorPanel/VBox/FilterButtons/ExteriorBtn") else null
@onready var all_filter_btn: Button = $UI/InteriorPanel/VBox/FilterButtons/AllBtn if has_node("UI/InteriorPanel/VBox/FilterButtons/AllBtn") else null
@onready var mode_toggle_btn: Button = $UI/StatsPanel/VBox/ModeToggleBtn if has_node("UI/StatsPanel/VBox/ModeToggleBtn") else null
@onready var interior_container: Node3D = $InteriorContainer if has_node("InteriorContainer") else null

# Managers
var world_streaming_manager: Node3D = null  # NativeStreamingManager (always native now)
var native_streaming_manager: Node3D = null  # NativeStreamingManager reference (same as above)
var terrain_manager: TerrainManager = null  # TerrainManager (for prebaking)
var texture_loader: TerrainTextureLoader = null  # TerrainTextureLoader
var cell_manager: CellManager = null  # CellManager
var profiler: PerformanceProfiler = null  # PerformanceProfiler
var _ocean_controls: OceanControls = null  # OceanControls (ocean/water system)
var _env_controls: EnvironmentControls = null  # EnvironmentControls (shader effects + sky)
var _stats_collector: StatsCollector = null  # StatsCollector (panel label updates)
var _terrain_preprocessor: TerrainPreprocessor = null  # TerrainPreprocessor (terrain baking)
var background_processor: BackgroundProcessor = null  # BackgroundProcessor for async loading
var console: Console = null  # Developer console
var test_runner: Node = null  # Automated test runner (AutomatedTestRunner)
var diagnostic_overlay: Node = null  # Real-time streaming diagnostics (DiagnosticOverlay)
var crash_reporter: Node = null  # State capture for crash analysis (CrashReporter)
var debug_system: Node = null  # Unified debug system (DebugSystem - F4/F9/F11/F12)
var _profiling_report: ProfilingReport = null  # UI log panel profiling report

# State
var _data_path: String = ""
var _initialized: bool = false
var _perf_overlay_visible: bool = true
var _current_view_distance: int = 5  # Must be at least 5 cells (585m) to cover MID tier (500m)

# Interior cell browser (constructed by CellBrowser)
var _cell_browser: CellBrowser = null

# Camera mode state
enum CameraMode { FLY_CAMERA, PLAYER_CONTROLLER }
var _camera_mode: CameraMode = CameraMode.FLY_CAMERA
var fly_camera: FlyCamera = null  # FlyCamera instance (with script)
var player_controller: PlayerController = null  # PlayerController instance


func _ready() -> void:
	# Initialize managers
	terrain_manager = TerrainManagerScript.new()
	texture_loader = TerrainTextureLoaderScript.new()
	cell_manager = CellManagerScript.new()
	# NPCs/creatures controlled by _show_characters toggle (default OFF for testing)
	cell_manager.load_npcs = _show_characters
	cell_manager.load_creatures = _show_characters

	# Initialize object pool for frequently used models
	# Create a hidden container for pooled objects when they're not in use
	var pool_container := Node3D.new()
	pool_container.name = "ObjectPoolContainer"
	pool_container.visible = false  # Hidden container for inactive pooled objects
	add_child(pool_container)
	cell_manager.init_object_pool(pool_container)

	# Initialize profiler
	profiler = PerformanceProfilerScript.new()
	profiler.start_session()

	# Setup camera systems
	_setup_cameras()

	# Setup developer console
	_setup_console()

	# Setup automated test runner
	_setup_test_runner()

	# Setup diagnostic overlay and crash reporter
	_setup_diagnostic_systems()

	# Connect quick teleport buttons
	seyda_neen_btn.pressed.connect(func() -> void: _teleport_to_cell(-2, -9))
	balmora_btn.pressed.connect(func() -> void: _teleport_to_cell(-3, -2))
	vivec_btn.pressed.connect(func() -> void: _teleport_to_cell(5, -6))
	origin_btn.pressed.connect(func() -> void: _teleport_to_cell(0, 0))

	# Connect preprocess button
	preprocess_btn.pressed.connect(_on_preprocess_pressed)

	# Setup interior cell browser
	_setup_interior_browser()

	# Setup visibility toggles
	_setup_visibility_toggles()

	# Get Morrowind data path (try auto-detection if not configured)
	_data_path = SettingsManager.get_data_path()
	if _data_path.is_empty():
		_log("No data path configured, attempting auto-detection...")
		_data_path = SettingsManager.auto_detect_installation()
		if not _data_path.is_empty():
			_log("[color=green]Auto-detected Morrowind at: %s[/color]" % _data_path)
			SettingsManager.set_data_path(_data_path)
		else:
			_hide_loading()
			_log("[color=red]ERROR: Morrowind data path not configured and auto-detection failed.[/color]")
			_log("[color=yellow]Set MORROWIND_DATA_PATH environment variable or use settings UI.[/color]")
			return

	# Start async initialization
	_show_loading("Initializing World Streaming", "Loading game data...")
	call_deferred("_init_async")


func _init_async() -> void:
	# Load BSA archives
	await _update_loading(5, "Loading BSA archives...")
	var bsa_count := BSAManager.load_archives_from_directory(_data_path)
	_log("Loaded %d BSA archives" % bsa_count)

	# Initialize background processor for async loading
	background_processor = BackgroundProcessorScript.new()
	background_processor.name = "BackgroundProcessor"
	add_child(background_processor)
	cell_manager.set_background_processor(background_processor)
	_log("Background processor initialized for async cell loading")

	# Pre-warm BSA cache with common files (improves cell loading performance)
	await _update_loading(10, "Pre-warming file cache...")
	_prewarm_bsa_cache()

	# Load ESM file
	await _update_loading(30, "Loading ESM file...")
	var esm_file: String = SettingsManager.get_esm_file()
	var esm_path := _data_path.path_join(esm_file)
	var error := ESMManager.load_file(esm_path)

	if error != OK:
		_log("[color=red]ERROR: Failed to load ESM: %s[/color]" % error_string(error))
		_hide_loading()
		return

	_log("[color=green]ESM loaded successfully[/color]")
	_log("LAND records: %d, CELL records: %d" % [ESMManager.lands.size(), ESMManager.cells.size()])

	# Initialize Terrain3D
	await _update_loading(50, "Initializing Terrain3D...")
	_init_terrain3d()

	# Load pre-processed terrain (terrain is always prebaked)
	await _update_loading(70, "Loading terrain data...")
	_load_preprocessed_terrain()

	# Ocean system is now lazy-loaded - created on first toggle

	# Pre-warm model cache with common models (improves first-cell loading)
	await _update_loading(80, "Pre-loading common models...")
	var preload_count := cell_manager.preload_common_models()
	_log("Pre-loaded %d common models into cache" % preload_count)

	# Create and setup NativeStreamingManager (but don't start tracking yet)
	await _update_loading(90, "Setting up streaming system...")
	_setup_world_streaming_manager(false)  # Pass false to delay tracking

	# Models load automatically when streaming system starts
	# Visibility is controlled by Godot's native visibility_range system

	# Done
	await _update_loading(100, "Ready!")
	await get_tree().create_timer(0.3).timeout
	_hide_loading()

	_initialized = true
	_log("[color=green]World streaming initialized![/color]")
	_log("Use ZQSD to move, Right-click to look")
	_log("Cells stream automatically based on camera position")

	# Sync sky state with toggle to ensure consistent initial state
	# This ensures the sky visibility matches what the toggle shows
	_env_controls.sync_sky_state()

	# First teleport camera to Seyda Neen BEFORE starting to track
	_teleport_to_cell(-2, -9)

	# NOW start tracking the camera - cells will generate around Seyda Neen
	world_streaming_manager.set_camera(camera)

	# Update debug overlay with references to managers
	_update_debug_overlay_references()

	# Connect diagnostic systems now that WSM is ready
	_connect_diagnostic_systems()


func _init_terrain3d() -> void:
	if not ClassDB.class_exists("Terrain3DData"):
		_log("[color=red]ERROR: Terrain3D addon not loaded[/color]")
		return

	if not terrain_3d:
		_log("[color=red]ERROR: Terrain3D node not found in scene[/color]")
		return

	# Use shared configuration from CoordinateSystem (single source of truth)
	if not CS.configure_terrain3d(terrain_3d):
		_log("[color=red]ERROR: Failed to configure Terrain3D[/color]")
		return

	# Load terrain textures
	var textures_loaded: int = texture_loader.load_terrain_textures(terrain_3d.assets)
	_log("Loaded %d terrain textures" % textures_loaded)

	# Configure terrain manager to use proper texture slot mapping
	terrain_manager.set_texture_slot_mapper(texture_loader)

	_log("Terrain3D configured: region_size=%d, vertex_spacing=%.3f" % [CS.TERRAIN_REGION_SIZE, CS.TERRAIN_VERTEX_SPACING])


func _load_preprocessed_terrain() -> void:
	# Load pre-processed terrain data from cache folder
	if not terrain_3d or not terrain_3d.data:
		_log("[color=yellow]Warning: Terrain3D not ready for loading preprocessed data[/color]")
		return

	var terrain_data_dir := SettingsManager.get_terrain_path()
	if DirAccess.dir_exists_absolute(terrain_data_dir):
		terrain_3d.data.load_directory(terrain_data_dir)
		_log("Loaded preprocessed terrain from %s" % terrain_data_dir)
	else:
		_log("[color=yellow]Preprocessed terrain directory not found[/color]")


# ==================== Camera System ====================

## Setup fly camera and player controller
func _setup_cameras() -> void:
	# Get existing fly camera from scene and attach script
	var fly_camera_node: Camera3D = $FlyCamera
	if fly_camera_node:
		fly_camera_node.set_script(FlyCameraScript)
		fly_camera = fly_camera_node as FlyCamera
		# Manually enable processing since _ready() isn't called when script is attached dynamically
		fly_camera.set_process(true)
		fly_camera.set_process_input(true)
		fly_camera.enabled = true
		fly_camera.current = true
		camera = fly_camera  # Set the camera reference

	# Create player controller (hidden by default)
	var player_node := CharacterBody3D.new()
	player_node.set_script(PlayerControllerScript)
	player_node.name = "PlayerController"
	add_child(player_node)
	player_controller = player_node as PlayerController
	# Ensure processing is enabled (belt and suspenders)
	player_controller.set_physics_process(true)
	player_controller.set_process_input(true)

	# Start in fly camera mode
	_camera_mode = CameraMode.FLY_CAMERA
	player_controller.disable()

	_log("Camera systems initialized (P to toggle)")


## Setup developer console
func _setup_console() -> void:
	console = ConsoleScript.new()
	console.name = "Console"
	add_child(console)

	# Set initial camera for picker
	console.set_camera(fly_camera)

	# Register context - these will be accessible from console commands
	console.register_context("camera", fly_camera)
	console.register_context("profiler", profiler)
	console.register_context("cell_manager", cell_manager)
	console.register_context("esm", ESMManager)
	console.register_context("bsa", BSAManager)

	# Register custom teleport command
	var coc_params: Array[CommandRegistry.ParameterInfo] = [
		CommandRegistry.ParameterInfo.new("cell_name", TYPE_STRING, "Interior cell name")
	]
	console.register_command(
		"coc", _cmd_center_on_cell,
		"Teleport to interior cell by name (Morrowind command)",
		"navigation",
		PackedStringArray(["centeroncell"]),
		coc_params,
		PackedStringArray(["coc \"Seyda Neen, Census and Excise Office\""])
	)

	var coe_params: Array[CommandRegistry.ParameterInfo] = [
		CommandRegistry.ParameterInfo.new("x", TYPE_INT, "Cell X coordinate"),
		CommandRegistry.ParameterInfo.new("y", TYPE_INT, "Cell Y coordinate")
	]
	console.register_command(
		"coe", _cmd_center_on_exterior,
		"Teleport to exterior cell by grid (Morrowind command)",
		"navigation",
		PackedStringArray(["centeronexterior"]),
		coe_params,
		PackedStringArray(["coe -2 -9"])
	)

	_log("Console initialized (~ to toggle)")


## Setup automated test runner
func _setup_test_runner() -> void:
	var runner: Node = AutomatedTestRunnerScript.new()
	runner.name = "AutomatedTestRunner"
	add_child(runner)
	test_runner = runner
	
	# Connect signals using signal objects
	runner.connect("test_completed", _on_test_completed)
	runner.connect("error_captured", _on_test_error_captured)
	
	_log("Test runner initialized (F6=start, F7=stop, F8=report)")


## Setup diagnostic overlay, crash reporter, and unified debug system
func _setup_diagnostic_systems() -> void:
	# Create diagnostic overlay (hidden by default) - legacy, kept for compatibility
	diagnostic_overlay = DiagnosticOverlayScript.new()
	diagnostic_overlay.name = "DiagnosticOverlay"
	diagnostic_overlay.visible = false  # Start hidden, toggle with F9
	add_child(diagnostic_overlay)

	# Create crash reporter - legacy, kept for compatibility
	crash_reporter = CrashReporterScript.new()
	crash_reporter.name = "CrashReporter"
	add_child(crash_reporter)

	# Create unified debug system (merges F4/F9/F11/F12 functionality)
	debug_system = DebugSystemScript.new()
	debug_system.name = "DebugSystem"
	# Enable auto-test on startup if DEBUG_AUTO_TEST environment variable is set
	debug_system.auto_test_on_startup = OS.has_environment("DEBUG_AUTO_TEST")
	add_child(debug_system)

	_log("Debug systems initialized (F4=profile, F9=overlay, F11=dump, F12=auto-test)")


## Connect diagnostic systems to streaming (called after WSM is ready)
func _connect_diagnostic_systems() -> void:
	if not diagnostic_overlay or not crash_reporter:
		return

	# Connect legacy diagnostic systems to streaming
	if world_streaming_manager:
		# Native streaming system doesn't have ObjectStreamer - pass null
		diagnostic_overlay.connect_to_streaming(world_streaming_manager, null)
		crash_reporter.connect_to_systems(self, world_streaming_manager, null, diagnostic_overlay)

	# Initialize unified debug system with all references
	if debug_system and debug_system.has_method("initialize"):
		var streaming_profiler: StreamingProfiler = null
		if world_streaming_manager and world_streaming_manager.has_method("get_streaming_profiler"):
			streaming_profiler = world_streaming_manager.get_streaming_profiler()
		debug_system.call("initialize", self, fly_camera, world_streaming_manager, cell_manager, profiler, streaming_profiler)
		if debug_system.has_signal("auto_test_completed"):
			debug_system.connect("auto_test_completed", _on_debug_auto_test_completed)

	_log("Diagnostic systems connected to streaming")


## Handle test completion
func _on_test_completed(report: Dictionary) -> void:
	var errors: Dictionary = report.get("errors", {})
	var total_count: int = errors.get("total_count", 0)
	_log("[color=green]Test completed with %d errors[/color]" % total_count)


## Handle test error capture
func _on_test_error_captured(error: String) -> void:
	_log("[color=red]TEST ERROR: %s[/color]" % error.substr(0, 100))


## Handle debug system auto-test completion
func _on_debug_auto_test_completed(report: Dictionary) -> void:
	var summary: Dictionary = report.get("summary", {})
	var errors: int = summary.get("errors", 0)
	var duration: float = summary.get("duration_seconds", 0.0)
	_log("[color=cyan]Auto-test completed: %.1fs, %d errors[/color]" % [duration, errors])


## Console command: Center on cell (interior)
func _cmd_center_on_cell(args: Dictionary) -> CommandRegistry.CommandResult:
	var cell_name: String = args.get("cell_name", "")
	if cell_name.is_empty():
		return CommandRegistry.CommandResult.error("Cell name required")

	# Interior cell teleportation requires the interior transition system (not yet implemented)
	return CommandRegistry.CommandResult.ok("Would teleport to: %s" % cell_name)


## Console command: Center on exterior cell
func _cmd_center_on_exterior(args: Dictionary) -> CommandRegistry.CommandResult:
	var x: int = args.get("x", 0)
	var y: int = args.get("y", 0)

	_teleport_to_cell(x, y)
	return CommandRegistry.CommandResult.ok("Teleported to cell (%d, %d)" % [x, y])


## Toggle between fly camera and player controller
func _toggle_camera_mode() -> void:
	if _camera_mode == CameraMode.FLY_CAMERA:
		_switch_to_player_controller()
	else:
		_switch_to_fly_camera()


## Switch to player controller mode
func _switch_to_player_controller() -> void:
	if not player_controller or not fly_camera:
		return

	_camera_mode = CameraMode.PLAYER_CONTROLLER

	# Get current fly camera position for teleport
	var current_pos := fly_camera.global_position

	# Calculate ground position (raycast down to find terrain)
	var ground_y := _get_ground_height(current_pos)
	var player_pos := Vector3(current_pos.x, ground_y, current_pos.z)

	# Disable fly camera
	fly_camera.disable()
	fly_camera.current = false

	# Enable and position player controller
	player_controller.teleport_to(player_pos)
	player_controller.enable()

	# Update camera reference for systems that need it
	camera = player_controller.get_camera()

	# Update tracked node for streaming
	if world_streaming_manager:
		world_streaming_manager.set_camera(camera)

	# Update ocean camera
	if _ocean_controls:
		_ocean_controls.set_camera(camera)

	# Update console camera for object picking
	if console:
		console.set_camera(camera)
		console.register_context("camera", camera)

	_log("[color=cyan]Switched to PLAYER mode[/color]")
	_log("WASD to move, Space to jump, Shift to run")


## Switch to fly camera mode
func _switch_to_fly_camera() -> void:
	if not player_controller or not fly_camera:
		return

	_camera_mode = CameraMode.FLY_CAMERA

	# Get player position
	var player_camera_pos: Vector3 = player_controller.get_camera_position()

	# Disable player controller
	player_controller.disable()

	# Enable fly camera at player's camera position
	fly_camera.position = player_camera_pos
	fly_camera.enable()
	fly_camera.current = true

	# Update camera reference
	camera = fly_camera

	# Update tracked node for streaming
	if world_streaming_manager:
		world_streaming_manager.set_camera(camera)

	# Update ocean camera
	if _ocean_controls:
		_ocean_controls.set_camera(camera)

	# Update console camera for object picking
	if console:
		console.set_camera(camera)
		console.register_context("camera", camera)

	_log("[color=cyan]Switched to FLY CAMERA mode[/color]")
	_log("Hold Right-click to look, WASD to move")


## Get ground height at a position using terrain data
func _get_ground_height(pos: Vector3) -> float:
	var height := 0.0

	# Try to get height from Terrain3D
	if terrain_3d and terrain_3d.data:
		height = terrain_3d.data.get_height(pos)
		if is_nan(height) or height > 10000 or height < -1000:
			height = 0.0

	return height


## Get the currently active camera
func _get_active_camera() -> Camera3D:
	if _camera_mode == CameraMode.PLAYER_CONTROLLER and player_controller:
		return player_controller.get_camera()
	return fly_camera


## Update the preprocess status label
func _update_preprocess_status() -> void:
	if not preprocess_status:
		return

	# Check if terrain data exists
	var terrain_data_dir := SettingsManager.get_terrain_path()
	var has_terrain := DirAccess.dir_exists_absolute(terrain_data_dir)

	if has_terrain:
		preprocess_status.text = "Using pre-processed terrain"
		preprocess_status.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
		preprocess_btn.text = "Re-preprocess Terrain"
	else:
		preprocess_status.text = "No terrain data - click to generate"
		preprocess_status.add_theme_color_override("font_color", Color(1.0, 0.5, 0.3))
		preprocess_btn.text = "Preprocess ALL Terrain"


## Setup visibility toggle checkboxes and foldable panel system
func _setup_visibility_toggles() -> void:
	# Create environment controls (extracted in Session 5)
	var env_callbacks := {
		"log": _log,
		"add_child": add_child,
		"remove_child": remove_child,
		"update_stats": _update_stats,
	}
	_env_controls = EnvironmentControlsScript.new(env_callbacks)
	_env_controls.setup_fallback_environment()

	# Create ocean controls (extracted in Session 4)
	var ocean_callbacks := {
		"log": _log,
		"add_child": add_child,
		"get_active_camera": _get_active_camera,
		"get_terrain": func() -> Terrain3D: return terrain_3d,
		"update_stats": _update_stats,
	}
	_ocean_controls = OceanControlsScript.new(ocean_callbacks)

	# Build foldable panels via ExplorerPanels
	var callbacks := {
		"show_characters_toggled": _on_show_characters_toggled,
		"show_ocean_toggled": _ocean_controls.on_show_ocean_toggled,
		"show_sky_toggled": _env_controls.on_show_sky_toggled,
		"resolution_changed": _on_resolution_changed,
		"water_quality_changed": _ocean_controls.on_water_quality_changed,
		"wind_speed_changed": _ocean_controls.on_wind_speed_changed,
		"wind_dir_changed": _ocean_controls.on_wind_dir_changed,
		"wave_scale_changed": _ocean_controls.on_wave_scale_changed,
		"choppiness_changed": _ocean_controls.on_choppiness_changed,
		"debug_shore_toggled": _ocean_controls.on_debug_shore_toggled,
		"fog_toggled": _env_controls.on_fog_effect_toggled,
		"fog_intensity_changed": _env_controls.on_fog_intensity_changed,
		"clouds_toggled": _env_controls.on_clouds_effect_toggled,
		"cloud_coverage_changed": _env_controls.on_cloud_coverage_changed,
		"color_grading_toggled": _env_controls.on_color_grading_toggled,
		"morrowind_preset": _env_controls.on_morrowind_color_preset,
		"dramatic_preset": _env_controls.on_dramatic_color_preset,
		"reset_color_grading": _env_controls.on_reset_color_grading,
		"show_chunks_toggled": _on_show_chunks_toggled,
		"show_tiers_toggled": _on_show_tiers_toggled,
		"show_cells_toggled": _on_show_cells_toggled,
		"show_lod_levels_toggled": _on_show_lod_levels_toggled,
		"lod_mode_pressed": _on_lod_mode_pressed,
		"dump_profiling": func() -> void:
			if _profiling_report:
				_profiling_report.dump_report(),
		"teleport_to_cell": _teleport_to_cell,
		"adjust_view_distance": _adjust_view_distance,
		"preprocess_pressed": _on_preprocess_pressed,
	}
	var initial_state := {
		"show_characters": _show_characters,
		"show_ocean": _ocean_controls.show_ocean,
		"show_sky": _env_controls.show_sky,
		"view_distance": _current_view_distance,
		"show_chunk_debug": _show_chunk_debug,
		"show_tier_debug": _show_tier_debug,
		"show_cell_debug": _show_cell_debug,
	}
	_panels = ExplorerPanelsScript.new(callbacks, initial_state)
	var vbox: VBoxContainer = stats_panel.get_node_or_null("VBox")
	if vbox:
		_panels.build(vbox)

	# Give panels reference to extracted controls
	_ocean_controls.set_panels(_panels)
	_env_controls.set_panels(_panels)

	# Create stats collector (extracted in Session 6)
	_stats_collector = StatsCollectorScript.new(_panels)
	_stats_collector.set_profiler(profiler)
	_stats_collector.set_terrain(terrain_3d)

	# Create terrain preprocessor (extracted in Session 7)
	var preprocess_callbacks := {
		"log": _log,
		"get_tree": get_tree,
		"update_preprocess_status": _update_preprocess_status,
	}
	_terrain_preprocessor = TerrainPreprocessorScript.new(preprocess_callbacks)

	# Setup debug overlay for 3D visualizations
	_setup_debug_overlay()

	# Apply initial resolution (1920x1080)
	_apply_resolution(2)



## Setup debug overlay for 3D visualizations
func _setup_debug_overlay() -> void:
	_debug_overlay = DebugOverlayScript.new()
	_debug_overlay.name = "DebugOverlay"
	add_child(_debug_overlay)


## Update debug overlay with camera and managers
func _update_debug_overlay_references() -> void:
	if not _debug_overlay:
		return
	_debug_overlay.set_camera(camera)
	if world_streaming_manager:
		_debug_overlay.set_world_streaming_manager(world_streaming_manager)


## Toggle chunk debug visualization
func _on_show_chunks_toggled(enabled: bool) -> void:
	_show_chunk_debug = enabled
	if _debug_overlay:
		_debug_overlay.show_chunks = enabled
	_log("Chunk debug: %s" % ("ON" if enabled else "OFF"))


## Toggle tier debug visualization
func _on_show_tiers_toggled(enabled: bool) -> void:
	_show_tier_debug = enabled
	if _debug_overlay:
		_debug_overlay.show_tiers = enabled
	_log("Tier debug: %s" % ("ON" if enabled else "OFF"))


## Toggle cell grid debug visualization
func _on_show_cells_toggled(enabled: bool) -> void:
	_show_cell_debug = enabled
	if _debug_overlay:
		_debug_overlay.show_cells = enabled
	_log("Cell debug: %s" % ("ON" if enabled else "OFF"))


## Toggle LOD level debug visualization
func _on_show_lod_levels_toggled(enabled: bool) -> void:
	if _debug_overlay:
		_debug_overlay.show_lod_levels = enabled

	# Also enable shader debug coloring on MultiMesh batches
	if world_streaming_manager and world_streaming_manager.object_streamer:
		var batcher = world_streaming_manager.object_streamer.get_batcher()
		if batcher and batcher.has_method("set_debug_lod_colors"):
			batcher.set_debug_lod_colors(enabled)

	_log("LOD levels debug: %s" % ("ON" if enabled else "OFF"))


## Toggle LOD debug mode (actual vs expected)
func _on_lod_mode_pressed() -> void:
	if _debug_overlay and _debug_overlay.has_method("toggle_lod_debug_mode"):
		_debug_overlay.toggle_lod_debug_mode()
		# Update button text
		if _panels and _panels.lod_mode_btn:
			var mode: int = _debug_overlay.lod_debug_mode
			_panels.lod_mode_btn.text = "LOD Mode: " + ("Expected" if mode == 1 else "Actual")
		_log("LOD debug mode: %s" % ("Expected" if _debug_overlay.lod_debug_mode == 1 else "Actual"))


## Toggle characters (NPCs/creatures) visibility
## Separate from models for isolated character/animation testing
func _on_show_characters_toggled(enabled: bool) -> void:
	_show_characters = enabled

	_log("[DIAG] Characters toggle: %s" % ("ON" if enabled else "OFF"))

	# Update cell_manager loading flags
	if cell_manager:
		cell_manager.load_npcs = enabled
		cell_manager.load_creatures = enabled

	# Show/hide existing character nodes in loaded cells
	if world_streaming_manager:
		var loaded_coords: Array[Vector2i] = world_streaming_manager.get_loaded_cell_coordinates()
		var char_count := 0
		var loaded_count := 0

		_log("[DIAG] Found %d loaded cells to process for NPC toggle" % loaded_coords.size())

		for cell_grid: Vector2i in loaded_coords:
			var cell_node: Node3D = world_streaming_manager.get_loaded_cell(cell_grid.x, cell_grid.y)
			if cell_node:
				if enabled:
					# Check if cell has characters already
					var has_chars := false
					for child: Node in cell_node.get_children():
						if child.has_meta("is_character"):
							has_chars = true
							(child as Node3D).visible = true
							char_count += 1

					# If no characters exist, load them now
					if not has_chars and cell_manager:
						_log("[DIAG] Loading characters into cell %s (no existing chars)" % str(cell_grid))
						var new_chars: int = cell_manager.load_characters_into_cell(cell_grid.x, cell_grid.y, cell_node)
						loaded_count += new_chars
						if new_chars > 0:
							_log("[DIAG] Loaded %d characters into cell %s" % [new_chars, str(cell_grid)])
				else:
					# Hide existing characters
					for child: Node in cell_node.get_children():
						if child.has_meta("is_character") and child is Node3D:
							(child as Node3D).visible = false
							char_count += 1

		if enabled and loaded_count > 0:
			_log("[DIAG] Total loaded %d new characters into cells" % loaded_count)
		_log("[DIAG] Toggled visibility for %d characters" % char_count)

	_log("NPCs/Creatures: %s" % ("ON" if enabled else "OFF"))
	_update_stats()


## Handle resolution change
func _on_resolution_changed(index: int) -> void:
	_apply_resolution(index)


## Apply a resolution setting
func _apply_resolution(index: int) -> void:
	var resolutions: Array[Vector2i] = [
		Vector2i(1280, 720),
		Vector2i(1600, 900),
		Vector2i(1920, 1080),
		Vector2i(2560, 1440),
	]

	if index == 4:
		# Fullscreen
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		_log("Resolution: Fullscreen")
	else:
		# Windowed with specific resolution
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		var res: Vector2i = resolutions[index]
		DisplayServer.window_set_size(res)
		# Center the window on screen
		var screen_size: Vector2i = DisplayServer.screen_get_size()
		var window_pos: Vector2i = (screen_size - res) / 2
		DisplayServer.window_set_position(window_pos)
		_log("Resolution: %dx%d" % [res.x, res.y])


## Handle preprocess button press (delegates to TerrainPreprocessor)
func _on_preprocess_pressed() -> void:
	var ui_refs := {"preprocess_btn": preprocess_btn, "preprocess_status": preprocess_status}
	await _terrain_preprocessor.run(terrain_3d, terrain_manager, ui_refs)


func _setup_world_streaming_manager(start_tracking: bool = true) -> void:
	_setup_native_streaming_manager(start_tracking)


## Setup NEW native streaming manager (uses Godot visibility_range)
## ~1,000 lines of code vs ~10,000 in legacy system
func _setup_native_streaming_manager(start_tracking: bool = true) -> void:
	_log("[color=cyan]Using NATIVE streaming system (Godot visibility_range)[/color]")
	
	# Create NativeStreamingManager
	var nsm_node := Node3D.new()
	nsm_node.set_script(NativeStreamingManagerScript)
	nsm_node.name = "NativeStreamingManager"
	native_streaming_manager = nsm_node
	world_streaming_manager = nsm_node  # Assign to common reference
	
	# Configure
	native_streaming_manager.load_radius_cells = _current_view_distance
	native_streaming_manager.debug_enabled = false  # Disabled for performance (enable with toggle_debug command)
	
	add_child(native_streaming_manager)
	
	# Connect signals
	native_streaming_manager.cell_loaded.connect(_on_native_cell_loaded)
	native_streaming_manager.cell_unloaded.connect(_on_native_cell_unloaded)
	native_streaming_manager.startup_progress.connect(_on_streaming_startup_progress)
	native_streaming_manager.startup_complete.connect(_on_streaming_startup_complete)
	
	# Initialize with cell manager and camera
	native_streaming_manager.initialize(cell_manager, camera if start_tracking else null)
	
	_log("NativeStreamingManager created - using Godot's native visibility_range")
	
	# Register with console
	if console:
		console.register_context("world", native_streaming_manager)
		console.register_context("player", player_controller)

		# Add debugging commands
		console.register_command(
			"debug_streaming",
			_cmd_debug_streaming,
			"Print detailed streaming system debug info",
			"debug"
		)

		console.register_command(
			"toggle_debug",
			_cmd_toggle_debug,
			"Toggle debug logging for streaming system",
			"debug"
		)

		# Register LOD/impostor debug commands (extracted to LodDebugCommands)
		var lod_cmds := LodDebugCommands.new(native_streaming_manager)
		lod_cmds.register_commands(console)

		# Register streaming benchmark commands
		StreamingBenchmarkScript.register_console_commands(
			console, native_streaming_manager, cell_manager, camera
		)

		# Register LOD transition test commands
		LodTransitionTestScript.register_console_commands(
			console, native_streaming_manager, cell_manager, camera
		)

	# Initialize profiling report (extracted to ProfilingReport)
	_profiling_report = ProfilingReport.new(
		profiler, cell_manager, world_streaming_manager, _log, self
	)

	# Set streaming manager ref on stats collector (created during _setup_visibility_toggles)
	if _stats_collector:
		_stats_collector.set_world_streaming_manager(world_streaming_manager)


## Console command: debug_streaming
func _cmd_debug_streaming(_args: Dictionary) -> String:
	if native_streaming_manager:
		native_streaming_manager.print_debug_info()
		return "Debug info printed above"
	return "Native streaming manager not available"


## Console command: toggle_debug
func _cmd_toggle_debug(_args: Dictionary) -> String:
	if native_streaming_manager:
		native_streaming_manager.debug_enabled = not native_streaming_manager.debug_enabled
		if native_streaming_manager._impostor_renderer:
			native_streaming_manager._impostor_renderer.debug_enabled = native_streaming_manager.debug_enabled
		return "Debug mode: %s" % ("ON" if native_streaming_manager.debug_enabled else "OFF")
	return "Native streaming manager not available"


## Callback for native streaming manager cell loaded
func _on_native_cell_loaded(grid: Vector2i, object_count: int) -> void:
	_log("Cell loaded: (%d, %d) - %d objects (native)" % [grid.x, grid.y, object_count])
	_update_stats()


## Callback for native streaming manager cell unloaded
func _on_native_cell_unloaded(grid: Vector2i) -> void:
	_log("Cell unloaded: (%d, %d) (native)" % [grid.x, grid.y])
	_update_stats()


func _teleport_to_cell(cell_x: int, cell_y: int) -> void:
	# Clear load queue for faster response when teleporting
	if world_streaming_manager and world_streaming_manager.has_method("clear_load_queue"):
		world_streaming_manager.clear_load_queue()

	# Calculate cell center position in Godot coordinates
	# X: cell origin is west edge, add half to get center
	# Z: cell origin (SW corner) is at (-cell_y * size), which is the SOUTH edge
	#    To get center, we need to move NORTH (decrease Z), so subtract half
	var cell_world_size := CS.CELL_SIZE_GODOT
	var world_x := float(cell_x) * cell_world_size + cell_world_size * 0.5
	var world_z := float(-cell_y) * cell_world_size - cell_world_size * 0.5

	var height := 50.0

	# Get terrain height from single Terrain3D
	if terrain_3d and terrain_3d.data:
		height = terrain_3d.data.get_height(Vector3(world_x, 0, world_z))
		if is_nan(height) or height > 10000:
			height = 50.0

	# Teleport based on current camera mode
	if _camera_mode == CameraMode.PLAYER_CONTROLLER and player_controller:
		# Teleport player to ground level
		player_controller.teleport_to(Vector3(world_x, height + 2.0, world_z))
	elif fly_camera:
		# Teleport fly camera above the cell
		fly_camera.position = Vector3(world_x, height + 100.0, world_z + 50.0)
		fly_camera.look_at(Vector3(world_x, height, world_z))

	_log("Teleported to cell (%d, %d)" % [cell_x, cell_y])


func _update_stats() -> void:
	if _stats_collector:
		var state := {
			"camera_mode_str": "Fly" if _camera_mode == CameraMode.FLY_CAMERA else "Player",
			"view_distance": _current_view_distance,
		}
		_stats_collector.update(state)


# ==================== UI Helpers ====================

func _show_loading(title: String, status: String) -> void:
	loading_overlay.visible = true
	loading_label.text = title
	status_label.text = status
	progress_bar.value = 0


func _hide_loading() -> void:
	loading_overlay.visible = false


func _on_streaming_startup_progress(progress: float, loaded_cells: int, total_cells: int, queued_objects: int) -> void:
	loading_overlay.visible = true
	loading_label.text = "Loading World"
	status_label.text = "Cells: %d/%d | Objects queued: %d" % [loaded_cells, total_cells, queued_objects]
	progress_bar.value = progress


func _on_streaming_startup_complete() -> void:
	_hide_loading()


func _update_loading(progress: float, status: String) -> void:
	progress_bar.value = progress
	status_label.text = status
	await get_tree().process_frame


func _log(message: String) -> void:
	if log_text:
		log_text.append_text(message + "\n")
	Log.info("tools", message.replace("[color=green]", "").replace("[color=red]", "").replace("[color=yellow]", "").replace("[/color]", "").replace("[b]", "").replace("[/b]", ""))


# ==================== Input Handling ====================

func _input(event: InputEvent) -> void:
	# Don't process shortcuts when console is open (let user type in the console)
	if console and console.is_visible():
		return

	# Hotkeys (these work regardless of camera mode)
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if not key_event.pressed:
			return
		match key_event.keycode:
			KEY_P:
				# Toggle between fly camera and player controller
				_toggle_camera_mode()
			KEY_TAB:
				# Toggle between World and Interior modes
				if _cell_browser:
					_cell_browser.toggle_explorer_mode()
			KEY_F3:
				# Toggle performance overlay
				_perf_overlay_visible = not _perf_overlay_visible
				stats_panel.visible = _perf_overlay_visible
				_log("Performance overlay: %s" % ("ON" if _perf_overlay_visible else "OFF"))
			KEY_F4:
				# Handled by DebugSystem; fallback to profiling report
				if not debug_system and _profiling_report:
					_profiling_report.dump_report()
			KEY_EQUAL, KEY_KP_ADD:  # + key
				_adjust_view_distance(1)
			KEY_MINUS, KEY_KP_SUBTRACT:  # - key
				_adjust_view_distance(-1)
			KEY_N:  # Toggle NPCs/characters
				if _panels and _panels.show_characters_toggle:
					_panels.show_characters_toggle.button_pressed = not _panels.show_characters_toggle.button_pressed
			KEY_O:  # Toggle ocean
				if _panels and _panels.show_ocean_toggle:
					_panels.show_ocean_toggle.button_pressed = not _panels.show_ocean_toggle.button_pressed
			KEY_K:  # Toggle sky/day-night cycle
				if _panels and _panels.show_sky_toggle:
					_panels.show_sky_toggle.button_pressed = not _panels.show_sky_toggle.button_pressed
			KEY_F9:  # Handled by DebugSystem; fallback to legacy overlay
				if not debug_system and diagnostic_overlay:
					diagnostic_overlay.visible = not diagnostic_overlay.visible
					_log("Diagnostic overlay: %s" % ("ON" if diagnostic_overlay.visible else "OFF"))
			KEY_F11:  # Handled by DebugSystem; fallback to crash reporter
				if not debug_system and crash_reporter:
					crash_reporter.dump_state_now()
					_log("[color=cyan]State dumped to crash report log[/color]")


func _process(delta: float) -> void:
	if not _initialized:
		return

	# Record frame timing for profiler
	if profiler:
		profiler.record_frame(delta)

	# Process async cell instantiation with dynamic time budget
	# Industry standard: Spend more time when queue is large to drain backlog faster
	if cell_manager:
		var queue_size: int = cell_manager.get_instantiation_queue_size()
		var budget_ms: float = 4.0  # Default budget

		# Adaptive budget based on queue size
		if queue_size > 2000:
			budget_ms = 12.0  # Burst mode - large backlog
		elif queue_size > 500:
			budget_ms = 8.0   # Catch-up mode - moderate backlog
		elif queue_size > 100:
			budget_ms = 6.0   # Slightly elevated

		cell_manager.process_async_instantiation(budget_ms)

	# Update stats periodically
	if Engine.get_frames_drawn() % 30 == 0:
		_update_stats()


## Adjust view distance and update streaming manager
## Max 10 cells (~1.2km) is reasonable for most GPUs; beyond that FPS may drop significantly
func _adjust_view_distance(delta: int) -> void:
	_current_view_distance = clampi(_current_view_distance + delta, 1, 10)
	if world_streaming_manager:
		world_streaming_manager.view_distance_cells = _current_view_distance
		world_streaming_manager.refresh_cells()
	_log("View distance: %d cells (~%dm)" % [_current_view_distance, _current_view_distance * 117])
	_update_stats()


# ==================== Interior Cell Browser ====================

## Setup interior cell browser via CellBrowser (extracted in Session 3)
func _setup_interior_browser() -> void:
	var callbacks := {
		"log": _log,
		"switch_to_interior": _on_browser_switch_to_interior,
		"switch_to_world": _on_browser_switch_to_world,
		"load_cell": func(cell_name: String) -> Node3D: return cell_manager.load_cell(cell_name),
		"load_exterior_cell": func(gx: int, gy: int) -> Node3D: return cell_manager.load_exterior_cell(gx, gy),
		"position_camera": _position_camera_for_interior_cell,
		"get_cell_count": func() -> int: return ESMManager.cells.size(),
	}
	var ui_nodes := {
		"interior_panel": interior_panel,
		"cell_search_edit": cell_search_edit,
		"cell_list": cell_list,
		"interior_filter_btn": interior_filter_btn,
		"exterior_filter_btn": exterior_filter_btn,
		"all_filter_btn": all_filter_btn,
		"mode_toggle_btn": mode_toggle_btn,
		"interior_container": interior_container,
	}
	_cell_browser = CellBrowserScript.new(callbacks, ui_nodes)
	_cell_browser.setup(self)


## Delegate: hide world elements when switching to interior mode
func _on_browser_switch_to_interior() -> void:
	if terrain_3d:
		terrain_3d.visible = false
	if _ocean_controls:
		_ocean_controls.set_enabled(false)
	if world_streaming_manager:
		world_streaming_manager.set_process(false)


## Delegate: restore world elements when switching to world mode
func _on_browser_switch_to_world() -> void:
	if terrain_3d:
		terrain_3d.visible = true
	if _ocean_controls and _ocean_controls.show_ocean:
		_ocean_controls.set_enabled(true)
	if world_streaming_manager:
		world_streaming_manager.set_process(true)


## Position camera to view an interior cell (stays here — accesses camera state)
func _position_camera_for_interior_cell(cell: CellRecord) -> void:
	if not cell:
		return

	# Calculate center of all objects
	var center := Vector3.ZERO
	var count := 0

	for ref: CellReference in cell.references:
		var pos := CS.vector_to_godot(ref.position)
		center += pos
		count += 1

	if count > 0:
		center /= count

	# Position based on camera mode
	if _camera_mode == CameraMode.PLAYER_CONTROLLER and player_controller:
		player_controller.teleport_to(center + Vector3(0, 2, 0))
	elif fly_camera:
		fly_camera.position = center + Vector3(0, 300, 500)
		fly_camera.look_at(center)

	_log("Camera positioned at: %s" % (player_controller.global_position if _camera_mode == CameraMode.PLAYER_CONTROLLER else fly_camera.position))


## Pre-warm the BSA extraction cache with commonly used files
## This dramatically reduces cell loading time by having common models/textures in memory
func _prewarm_bsa_cache() -> void:
	var common_models := ObjectPoolScript.identify_common_models(null)
	var prewarmed := 0

	for model_path: String in common_models:
		# Try both with and without meshes\ prefix
		var full_path: String = "meshes\\" + model_path if not model_path.begins_with("meshes") else model_path
		if BSAManager.has_file(full_path):
			BSAManager.extract_file(full_path)  # This populates the extraction cache
			prewarmed += 1

	# Also pre-warm common textures
	var common_textures := [
		"textures\\tx_ai_clover_01.dds",
		"textures\\tx_ai_clover_02.dds",
		"textures\\tx_ai_grass_01.dds",
		"textures\\tx_ai_grass_02.dds",
		"textures\\tx_bc_fern_01.dds",
		"textures\\tx_bc_fern_02.dds",
		"textures\\tx_rock_ai_01.dds",
		"textures\\tx_rock_bc_01.dds",
		"textures\\tx_wood_brown_01.dds",
		"textures\\tx_wood_brown_02.dds",
	]

	for tex_path: String in common_textures:
		if BSAManager.has_file(tex_path):
			BSAManager.extract_file(tex_path)
			prewarmed += 1

	_log("Pre-warmed %d common files into cache" % prewarmed)

	# Log cache stats
	var cache_stats: Dictionary = BSAManager.get_cache_stats()
	_log("BSA cache: %.1f MB, %d files" % [
		cache_stats.get("cache_size_mb", 0.0),
		cache_stats.get("cached_files", 0)
	])
