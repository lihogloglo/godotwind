## World Explorer - Complete Morrowind world exploration tool
##
## Features:
## - WORLD MODE: Infinite terrain streaming with multi-region support
##   - Terrain3D for terrain LOD and streaming
##   - Object streaming (statics, lights, NPCs, etc.)
##   - Free-fly camera OR player controller with physics
##
## - INTERIOR MODE: Browse and explore interior cells
##   - Cell browser with search
##   - Interior/exterior filtering
##   - Quick load for common locations
##
## - DEVELOPER CONSOLE: Click-to-select objects, commands, scripting
##   - Press ~ (tilde) to toggle console
##   - Click objects to inspect them
##   - Type 'help' for available commands
##
## Controls:
## - Press ~ (tilde) to toggle developer console
## - Press P to toggle between Fly Camera and Player Controller
## - Press F3 to toggle performance overlay
## - Press F4 to dump detailed profiling report
## - Press F9 to toggle debug overlay
## - Press F11 to dump state to file
## - Press F12 to toggle auto-test mode (automated camera for streaming tests)
## - Press TAB to toggle between World and Interior modes
## - Use +/- to adjust view distance
##
## Auto-Test Mode (F12):
## - Automatically moves camera through key locations
## - Captures performance metrics and errors
## - Can be triggered programmatically with DEBUG_AUTO_TEST environment variable
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
const OceanManagerScript := preload("res://src/core/water/ocean_manager.gd")
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
# Note: HardwareDetection is accessed via class_name, no preload needed


# Node references
@onready var camera: Camera3D = $FlyCamera
@onready var terrain_3d: Terrain3D = $Terrain3D
@onready var loading_overlay: ColorRect = $UI/LoadingOverlay
@onready var loading_label: Label = $UI/LoadingOverlay/VBox/LoadingLabel
@onready var progress_bar: ProgressBar = $UI/LoadingOverlay/VBox/ProgressBar
@onready var status_label: Label = $UI/LoadingOverlay/VBox/StatusLabel
@onready var stats_panel: Panel = $UI/StatsPanel
@onready var stats_text: RichTextLabel = $UI/StatsPanel/VBox/StatsText
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
var _show_ocean: bool = false   # Default OFF for performance
var _show_sky: bool = false     # Default OFF - enable for day/night cycle

# Sky3D is created lazily - only on first toggle
var sky_3d: Sky3D = null  # Sky3D node (created on demand)
var _sky3d_initialized: bool = false  # Track if Sky3D has ever been created

# Ocean is created lazily - only on first toggle
var _ocean_initialized: bool = false  # Track if ocean has ever been created

# Fallback environment for when Sky3D is disabled (Godot default-like sky)
var _fallback_world_env: WorldEnvironment = null
var _fallback_light: DirectionalLight3D = null

# Shader manager state
var _shader_manager_attached: bool = false

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
var ocean_manager: OceanManagerClass = null  # OceanManager
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
	_sync_sky_state()

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


# Crash scenario test removed - Models toggle no longer exists


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

	# TODO: Actually teleport to interior cell
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
	if ocean_manager and ocean_manager.has_method("set_camera"):
		ocean_manager.set_camera(camera)

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
	if ocean_manager and ocean_manager.has_method("set_camera"):
		ocean_manager.set_camera(camera)

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
	# Create fallback environment and light for when Sky3D is disabled
	_setup_fallback_environment()

	# Build foldable panels via ExplorerPanels
	var callbacks := {
		"show_characters_toggled": _on_show_characters_toggled,
		"show_ocean_toggled": _on_show_ocean_toggled,
		"show_sky_toggled": _on_show_sky_toggled,
		"resolution_changed": _on_resolution_changed,
		"water_quality_changed": _on_water_quality_changed,
		"wind_speed_changed": _on_wind_speed_changed,
		"wind_dir_changed": _on_wind_dir_changed,
		"wave_scale_changed": _on_wave_scale_changed,
		"choppiness_changed": _on_choppiness_changed,
		"debug_shore_toggled": _on_debug_shore_toggled,
		"fog_toggled": _on_fog_effect_toggled,
		"fog_intensity_changed": _on_fog_intensity_changed,
		"clouds_toggled": _on_clouds_effect_toggled,
		"cloud_coverage_changed": _on_cloud_coverage_changed,
		"color_grading_toggled": _on_color_grading_toggled,
		"morrowind_preset": _apply_morrowind_color_preset,
		"dramatic_preset": _apply_dramatic_color_preset,
		"reset_color_grading": _reset_color_grading,
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
		"show_ocean": _show_ocean,
		"show_sky": _show_sky,
		"view_distance": _current_view_distance,
		"show_chunk_debug": _show_chunk_debug,
		"show_tier_debug": _show_tier_debug,
		"show_cell_debug": _show_cell_debug,
	}
	_panels = ExplorerPanelsScript.new(callbacks, initial_state)
	var vbox: VBoxContainer = stats_panel.get_node_or_null("VBox")
	if vbox:
		_panels.build(vbox)

	# Setup debug overlay for 3D visualizations
	_setup_debug_overlay()

	# Apply initial resolution (1920x1080)
	_apply_resolution(2)


## Ensure ShaderManager is attached to the scene
func _ensure_shader_manager_attached() -> void:
	if _shader_manager_attached:
		return

	# Attach ShaderManager to the fallback environment or Sky3D
	if _fallback_world_env and _fallback_world_env.is_inside_tree():
		ShaderManager.attach_to(_fallback_world_env)
		_shader_manager_attached = true
		_log("ShaderManager attached to fallback environment")
	elif sky_3d and sky_3d.is_inside_tree():
		ShaderManager.attach_to(sky_3d)
		_shader_manager_attached = true
		_log("ShaderManager attached to Sky3D")


func _on_fog_effect_toggled(enabled: bool) -> void:
	_ensure_shader_manager_attached()
	if enabled:
		ShaderManager.enable_effect("volumetric_fog", 0.3)
	else:
		ShaderManager.disable_effect("volumetric_fog", 0.3)
	_log("Volumetric Fog: %s" % ("ON" if enabled else "OFF"))


func _on_fog_intensity_changed(value: float) -> void:
	ShaderManager.set_effect_param("volumetric_fog", "fog_intensity", value)


func _on_clouds_effect_toggled(enabled: bool) -> void:
	_ensure_shader_manager_attached()
	if enabled:
		ShaderManager.enable_effect("volumetric_clouds", 0.3)
	else:
		ShaderManager.disable_effect("volumetric_clouds", 0.3)
	_log("Volumetric Clouds: %s" % ("ON" if enabled else "OFF"))


func _on_cloud_coverage_changed(value: float) -> void:
	ShaderManager.set_effect_param("volumetric_clouds", "cloud_coverage", value)


func _on_color_grading_toggled(enabled: bool) -> void:
	_ensure_shader_manager_attached()
	if enabled:
		ShaderManager.enable_effect("color_grading", 0.3)
	else:
		ShaderManager.disable_effect("color_grading", 0.3)
	_log("Color Grading: %s" % ("ON" if enabled else "OFF"))


func _apply_morrowind_color_preset() -> void:
	var effect := ShaderManager.get_effect("color_grading")
	if effect and effect.has_method("apply_morrowind_preset"):
		effect.apply_morrowind_preset()
		if not _panels.color_grading_toggle.button_pressed:
			_panels.color_grading_toggle.button_pressed = true
		_log("Applied Morrowind color preset")


func _apply_dramatic_color_preset() -> void:
	var effect := ShaderManager.get_effect("color_grading")
	if effect and effect.has_method("apply_dramatic_preset"):
		effect.apply_dramatic_preset()
		if not _panels.color_grading_toggle.button_pressed:
			_panels.color_grading_toggle.button_pressed = true
		_log("Applied Dramatic color preset")


func _reset_color_grading() -> void:
	var effect := ShaderManager.get_effect("color_grading")
	if effect:
		effect.reset_all_params()
		_log("Reset color grading to defaults")


## Setup debug overlay for 3D visualizations
func _setup_debug_overlay() -> void:
	_debug_overlay = DebugOverlayScript.new()
	_debug_overlay.name = "DebugOverlay"
	add_child(_debug_overlay)


## Update debug overlay with camera and managers
func _update_debug_overlay_references() -> void:
	print("[WorldExplorer] Updating debug overlay references...")
	if not _debug_overlay:
		print("[WorldExplorer] No debug overlay!")
		return

	print("[WorldExplorer] Setting camera: %s" % [camera.name if camera else "null"])
	_debug_overlay.set_camera(camera)

	if world_streaming_manager:
		# Set world streaming manager reference for LOD visualization
		_debug_overlay.set_world_streaming_manager(world_streaming_manager)

		# Note: NativeStreamingManager doesn't expose tier_manager/chunk_manager
		# Those were part of the old architecture and are now internal to NativeStreamingManager
		# The debug overlay should work with the streaming manager directly
		print("[WorldExplorer] World streaming manager set (NativeStreamingManager)")
	else:
		print("[WorldExplorer] No world streaming manager")


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


## Ocean parameter callbacks
func _on_wind_speed_changed(value: float) -> void:
	_panels.update_slider_label(_panels.wind_speed_slider, value)
	if ocean_manager:
		ocean_manager.wind_speed = value
		_update_ocean_wave_params()

func _on_wind_dir_changed(value: float) -> void:
	_panels.update_slider_label(_panels.wind_dir_slider, value)
	if ocean_manager:
		ocean_manager.wind_direction = deg_to_rad(value)
		_update_ocean_wave_params()

func _on_wave_scale_changed(value: float) -> void:
	_panels.update_slider_label(_panels.wave_scale_slider, value)
	if ocean_manager:
		ocean_manager.wave_scale = value
		if ocean_manager.has_method("_update_shader_parameters"):
			ocean_manager._update_shader_parameters()

func _on_choppiness_changed(value: float) -> void:
	_panels.update_slider_label(_panels.choppiness_slider, value)
	if ocean_manager:
		ocean_manager.choppiness = value
		_update_ocean_wave_params()


## Toggle debug shore mask visualization
func _on_debug_shore_toggled(enabled: bool) -> void:
	if ocean_manager and ocean_manager._ocean_mesh:
		ocean_manager._ocean_mesh.set_debug_shore_mask(enabled)
		_log("Debug shore mask: %s" % ("ON" if enabled else "OFF"))


## Update wave cascade parameters when ocean settings change
func _update_ocean_wave_params() -> void:
	if not ocean_manager:
		return
	# Update wave parameters in cascades if they exist
	var wave_params: Array[WaveCascadeParameters] = ocean_manager._wave_parameters
	if wave_params.size() > 0:
		for params: WaveCascadeParameters in wave_params:
			params.wind_speed = ocean_manager.wind_speed
			params.wind_direction = ocean_manager.wind_direction


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


## Toggle ocean visibility
func _on_show_ocean_toggled(enabled: bool) -> void:
	_show_ocean = enabled

	# Show/hide ocean controls panel
	if _panels and _panels.ocean_controls_container:
		_panels.ocean_controls_container.visible = enabled

	if enabled:
		# Create ocean lazily on first enable
		if not _ocean_initialized:
			_create_ocean()

		# Enable ocean
		if ocean_manager and ocean_manager.has_method("set_enabled"):
			ocean_manager.set_enabled(true)

		# Sync sliders with ocean manager values
		_sync_ocean_sliders()
	else:
		# Disable ocean (if it exists)
		if ocean_manager and ocean_manager.has_method("set_enabled"):
			ocean_manager.set_enabled(false)

	_log("Ocean: %s" % ("ON" if enabled else "OFF"))
	_update_stats()


## Sync ocean slider values with current ocean manager settings
func _sync_ocean_sliders() -> void:
	if not ocean_manager or not _panels:
		return
	if _panels.wind_speed_slider:
		_panels.wind_speed_slider.value = ocean_manager.wind_speed
		_panels.update_slider_label(_panels.wind_speed_slider, ocean_manager.wind_speed)
	if _panels.wind_dir_slider:
		_panels.wind_dir_slider.value = rad_to_deg(ocean_manager.wind_direction)
		_panels.update_slider_label(_panels.wind_dir_slider, rad_to_deg(ocean_manager.wind_direction))
	if _panels.wave_scale_slider:
		_panels.wave_scale_slider.value = ocean_manager.wave_scale
		_panels.update_slider_label(_panels.wave_scale_slider, ocean_manager.wave_scale)
	if _panels.choppiness_slider:
		_panels.choppiness_slider.value = ocean_manager.choppiness
		_panels.update_slider_label(_panels.choppiness_slider, ocean_manager.choppiness)


## Create ocean system lazily (only called on first toggle)
func _create_ocean() -> void:
	if _ocean_initialized:
		return

	_log("Initializing ocean system...")

	if OceanManagerScript == null:
		_log("[color=yellow]Warning: OceanManager script not found[/color]")
		return

	# Run hardware detection and log GPU info
	HardwareDetection.detect()
	_log("[b]GPU Detection:[/b] %s" % HardwareDetection.get_gpu_name())
	if HardwareDetection.is_integrated_gpu():
		_log("[color=yellow]Integrated GPU detected - using optimized water[/color]")
	_log("Recommended water quality: %s" % HardwareDetection.quality_name(HardwareDetection.get_recommended_quality()))

	# Create ocean manager
	ocean_manager = OceanManagerScript.new()
	ocean_manager.name = "OceanManager"

	# Configure for Morrowind
	ocean_manager.ocean_radius = 8000.0  # 8km radius
	ocean_manager.sea_level = 0.0  # Sea level at Y=0 in Godot coords
	ocean_manager.water_quality = -1  # Auto-detect quality based on hardware

	# Add to scene
	add_child(ocean_manager)

	# Set camera for ocean to follow
	var active_camera := _get_active_camera()
	if active_camera:
		ocean_manager.set_camera(active_camera)

	# Set terrain reference if available (for shore mask)
	if terrain_3d:
		ocean_manager.set_terrain(terrain_3d)

	# Start enabled
	ocean_manager.set_enabled(true)

	_ocean_initialized = true

	# Sync UI dropdown with actual quality
	_sync_water_quality_dropdown()

	_log("Ocean system initialized (quality: %s)" % ocean_manager.get_water_quality_name())


## Sync the water quality dropdown with the current ocean quality
func _sync_water_quality_dropdown() -> void:
	if not _panels or not _panels.water_quality_btn or not ocean_manager:
		return

	var current_quality := ocean_manager.get_water_quality()
	# Map QualityMode enum to dropdown item ID
	# FLAT=0, GERSTNER=1, FFT=2, Auto=-1
	var target_id: int
	match current_quality:
		OceanMesh.QualityMode.FLAT:
			target_id = 0
		OceanMesh.QualityMode.GERSTNER:
			target_id = 1
		OceanMesh.QualityMode.FFT:
			target_id = 2
		_:
			target_id = -1  # Auto

	# Find and select the item with matching ID
	for i in _panels.water_quality_btn.get_item_count():
		if _panels.water_quality_btn.get_item_id(i) == target_id:
			_panels.water_quality_btn.selected = i
			break


## Handle water quality change
func _on_water_quality_changed(index: int) -> void:
	if not ocean_manager:
		return

	# Get the quality value from item ID (-1 = auto, 0-3 = specific quality)
	var quality: int = _panels.water_quality_btn.get_item_id(index)
	ocean_manager.set_water_quality(quality)

	var quality_name: String = ocean_manager.get_water_quality_name()
	_log("Water quality: %s" % quality_name)
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


## Toggle sky/day-night cycle visibility
func _on_show_sky_toggled(enabled: bool) -> void:
	_show_sky = enabled

	if enabled:
		# Create Sky3D lazily on first enable
		if not _sky3d_initialized:
			_create_sky3d()

		# Enable Sky3D - add to tree if not already there
		if sky_3d:
			if not sky_3d.is_inside_tree():
				add_child(sky_3d)
			sky_3d.sky3d_enabled = true
		# Remove fallback from tree (only one WorldEnvironment can be active)
		if _fallback_world_env and _fallback_world_env.is_inside_tree():
			remove_child(_fallback_world_env)
		if _fallback_light:
			_fallback_light.visible = false
	else:
		# Disable and remove Sky3D from tree so fallback can take over
		# (WorldEnvironment nodes only work when in tree, and only one is active)
		if sky_3d:
			# First remove from tree to stop rendering, then disable
			if sky_3d.is_inside_tree():
				remove_child(sky_3d)
			sky_3d.sky3d_enabled = false
		# Add fallback back to tree AFTER Sky3D is removed
		if _fallback_world_env:
			if not _fallback_world_env.is_inside_tree():
				add_child(_fallback_world_env)
			# Force the environment to be current
			_fallback_world_env.environment = _fallback_world_env.environment
		if _fallback_light:
			_fallback_light.visible = true

	_log("Sky/Day-Night: %s" % ("ON" if enabled else "OFF"))
	_update_stats()


## Create Sky3D node lazily (only called on first toggle)
func _create_sky3d() -> void:
	if _sky3d_initialized:
		return

	_log("Initializing Sky3D...")

	# Remove fallback environment BEFORE adding Sky3D (only one WorldEnvironment can be active)
	if _fallback_world_env and _fallback_world_env.is_inside_tree():
		remove_child(_fallback_world_env)
	if _fallback_light:
		_fallback_light.visible = false

	# Instantiate standard Sky3D with 2D texture clouds
	sky_3d = Sky3D.new()
	sky_3d.name = "Sky3D"

	# Add to scene tree FIRST - this triggers Sky3D's _initialize() which creates the environment
	add_child(sky_3d)

	# Configure AFTER adding to tree so _initialize() has run and environment exists
	sky_3d.current_time = 12.0
	sky_3d.ambient_energy = 0.5

	# Use Filmic tonemapping instead of ACES to avoid crushing blacks
	if sky_3d.environment:
		sky_3d.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	# Start enabled
	sky_3d.sky3d_enabled = true

	_sky3d_initialized = true
	_log("Sky3D initialized")


## Setup fallback environment and light for when Sky3D is disabled
## This provides a Godot default-like appearance instead of black sky
func _setup_fallback_environment() -> void:
	# Create fallback WorldEnvironment with procedural sky (like Godot's default)
	_fallback_world_env = WorldEnvironment.new()
	_fallback_world_env.name = "FallbackEnvironment"

	# Create environment with procedural sky material (Godot's default look)
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY

	# Create procedural sky (similar to Godot's default new scene sky)
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()

	# Configure for a pleasant daytime look (similar to Godot's default)
	sky_material.sky_top_color = Color(0.385, 0.454, 0.55)  # Godot default blue
	sky_material.sky_horizon_color = Color(0.646, 0.656, 0.67)
	sky_material.ground_bottom_color = Color(0.2, 0.169, 0.133)
	sky_material.ground_horizon_color = Color(0.646, 0.656, 0.67)
	sky_material.sun_angle_max = 30.0
	sky_material.sun_curve = 0.15

	sky.sky_material = sky_material
	env.sky = sky

	# Ambient lighting from sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = 1.0

	# Reflected light from sky
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	# Screen-Space Reflections for water
	env.ssr_enabled = true
	env.ssr_max_steps = 64
	env.ssr_fade_in = 0.15
	env.ssr_fade_out = 2.0
	env.ssr_depth_tolerance = 0.2

	# Tonemapping (Filmic for good contrast without crushing blacks)
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0
	env.tonemap_white = 1.0

	_fallback_world_env.environment = env
	add_child(_fallback_world_env)

	# Create fallback directional light
	_fallback_light = DirectionalLight3D.new()
	_fallback_light.name = "FallbackLight"

	# Strong daylight settings (brighter than before)
	_fallback_light.light_color = Color(1.0, 0.98, 0.95)  # Slightly warm white
	_fallback_light.light_energy = 1.2  # Stronger light
	_fallback_light.shadow_enabled = true
	_fallback_light.shadow_bias = 0.03
	_fallback_light.directional_shadow_max_distance = 500.0

	# Point downward at an angle (like midday sun)
	_fallback_light.rotation_degrees = Vector3(-45, -30, 0)

	add_child(_fallback_light)


## Sync sky state with toggle on initialization
## Since Sky3D is lazily created, this just ensures fallback is in tree
func _sync_sky_state() -> void:
	# Sky3D is not created yet (lazy init), so fallback should be in tree
	# WorldEnvironment doesn't have visible property - it's controlled by being in tree
	if _fallback_light:
		_fallback_light.visible = not _show_sky


## Handle preprocess button press
func _on_preprocess_pressed() -> void:
	_log("[color=cyan]Starting terrain preprocessing...[/color]")
	preprocess_btn.disabled = true
	preprocess_status.text = "Preprocessing..."

	if not terrain_3d:
		_log("[color=red]ERROR: Terrain3D not initialized[/color]")
		preprocess_btn.disabled = false
		return

	# Use COMBINED REGION approach (4x4 cells per region = 256x256 pixels)
	# This matches the on-the-fly terrain generation and supports larger terrain

	# First, collect all unique regions that have terrain data and find bounds
	var regions_with_data: Dictionary = {}  # region_coord -> true
	var min_region := Vector2i(999, 999)
	var max_region := Vector2i(-999, -999)

	for key: String in ESMManager.lands:
		var land: LandRecord = ESMManager.lands[key]
		if not land or not land.has_heights():
			continue

		# Get the region this cell belongs to
		var region_coord: Vector2i = terrain_manager.cell_to_region(Vector2i(land.cell_x, land.cell_y))
		regions_with_data[region_coord] = true

		# Track bounds
		min_region.x = mini(min_region.x, region_coord.x)
		min_region.y = mini(min_region.y, region_coord.y)
		max_region.x = maxi(max_region.x, region_coord.x)
		max_region.y = maxi(max_region.y, region_coord.y)

	_log("Found %d combined regions with data (from %d cells)" % [regions_with_data.size(), ESMManager.lands.size()])
	_log("Region bounds: (%d,%d) to (%d,%d)" % [min_region.x, min_region.y, max_region.x, max_region.y])

	# Expand bounds by 2 regions on each side for ocean floor
	const OCEAN_PADDING := 2
	min_region.x = maxi(min_region.x - OCEAN_PADDING, -16)
	min_region.y = maxi(min_region.y - OCEAN_PADDING, -16)
	max_region.x = mini(max_region.x + OCEAN_PADDING, 15)
	max_region.y = mini(max_region.y + OCEAN_PADDING, 15)

	# Calculate total regions (including ocean floor)
	var total_x := max_region.x - min_region.x + 1
	var total_y := max_region.y - min_region.y + 1
	var total_regions := total_x * total_y

	_log("Processing %d total regions (including %d ocean floor regions)" % [
		total_regions, total_regions - regions_with_data.size()])

	var processed := 0
	var ocean_floor := 0

	# Create callable for getting LAND records
	var get_land_func := func(cell_x: int, cell_y: int) -> LandRecord:
		return ESMManager.get_land(cell_x, cell_y)

	# Process ALL regions in the expanded bounds
	for ry in range(min_region.y, max_region.y + 1):
		for rx in range(min_region.x, max_region.x + 1):
			var region_coord := Vector2i(rx, ry)

			if regions_with_data.has(region_coord):
				# Region has LAND data - import normally
				if terrain_manager.import_combined_region(terrain_3d, region_coord, get_land_func):
					processed += 1
			else:
				# No LAND data - create ocean floor region
				if terrain_manager.import_ocean_floor_region(terrain_3d, region_coord):
					ocean_floor += 1

			# Update progress
			var done := processed + ocean_floor
			var percent := float(done) / float(total_regions) * 100.0
			preprocess_status.text = "Processing... %.0f%% (%d/%d regions)" % [percent, done, total_regions]

			# Yield periodically to keep UI responsive
			if done % 10 == 0:
				await get_tree().process_frame

	# Save to disk (cache folder)
	var terrain_data_dir := SettingsManager.get_terrain_path()
	DirAccess.make_dir_recursive_absolute(terrain_data_dir)
	terrain_3d.data.save_directory(terrain_data_dir)

	_log("[color=green]Terrain preprocessing complete![/color]")
	_log("  Terrain regions: %d (4x4 cells each)" % processed)
	_log("  Ocean floor regions: %d" % ocean_floor)
	_log("  Saved to: %s" % terrain_data_dir)

	preprocess_btn.disabled = false
	_update_preprocess_status()


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

	# Initialize profiling report (extracted to ProfilingReport)
	_profiling_report = ProfilingReport.new(
		profiler, cell_manager, world_streaming_manager, _log, self
	)


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
	var stats: Dictionary = {}
	if world_streaming_manager:
		stats = world_streaming_manager.get_stats()

	# Get profiler data
	var fps := 0.0
	var frame_ms := 0.0
	var draw_calls := 0
	var primitives := 0
	var mem_mb := 0.0
	var p95_ms := 0.0

	if profiler:
		fps = profiler.get_fps()
		frame_ms = profiler.get_avg_frame_time_ms()
		var render: Dictionary = profiler.get_render_stats()
		var render_draw_calls: int = render.draw_calls
		var render_primitives: int = render.primitives
		draw_calls = render_draw_calls
		primitives = render_primitives
		var mem: Dictionary = profiler.get_memory_stats()
		var static_mem: float = mem.static_memory_mb
		mem_mb = static_mem
		var percentiles: Dictionary = profiler.get_frame_time_percentiles()
		var p95_val: float = percentiles.p95
		p95_ms = p95_val

	# Get terrain stats
	var total_regions := 0
	if terrain_3d and terrain_3d.data:
		total_regions = terrain_3d.data.get_region_count()

	var async_pending: int = stats.get("async_pending", 0)
	var inst_queue: int = stats.get("instantiation_queue", 0)

	var camera_mode_str := "Fly" if _camera_mode == CameraMode.FLY_CAMERA else "Player"
	var camera_cell: Vector2i = stats.get("camera_cell", Vector2i(0, 0))

	# Update foldable panel labels
	_update_panel_labels(fps, frame_ms, p95_ms, draw_calls, primitives, mem_mb,
						  stats, total_regions, camera_mode_str, camera_cell)

	# Also update legacy stats_text if visible (backwards compatibility)
	if stats_text and stats_text.visible:
		stats_text.text = """[b]Performance[/b]
FPS: %.1f (%.2f ms)
P95: %.2f ms
Draw calls: %d
Primitives: %dk
Memory: %.1f MB

[b]Streaming[/b]
Loaded cells: %d
Queue: %d (peak: %d)
Async: %d | Inst: %d
View dist: %d cells [+/-]

[b]Terrain[/b]
Regions: %d

[b]Visibility[/b]
Models [M]: %s | NPCs [N]: %s | Ocean [O]: %s | Sky [K]: %s
Water quality: %s

[b]Camera[/b]
Mode [P]: %s
Cell: (%d, %d)

[color=gray]F3: Overlay | F4: Report | P: Toggle Camera[/color]""" % [
			fps, frame_ms,
			p95_ms,
			draw_calls,
			primitives / 1000.0,
			mem_mb,
			stats.get("loaded_cells", 0),
			stats.get("load_queue_size", 0),
			stats.get("queue_high_water_mark", 0),
			async_pending,
			inst_queue,
			_current_view_distance,
			total_regions,
			"ON",  # Models are always visible (no toggle)
		"ON" if _show_characters else "OFF",
		"ON" if _show_ocean else "OFF",
		"ON" if _show_sky else "OFF",
		ocean_manager.get_water_quality_name() if ocean_manager else "N/A",
			camera_mode_str,
			camera_cell.x,
			camera_cell.y,
		]


## Update labels in foldable panels
func _update_panel_labels(fps: float, frame_ms: float, p95_ms: float, draw_calls: int,
						   primitives: int, mem_mb: float, stats: Dictionary,
						   total_regions: int, camera_mode_str: String, camera_cell: Vector2i) -> void:
	if not _panels:
		return

	# Update performance panel
	if _panels.performance_panel:
		var content := _panels.performance_panel.get_content_container()
		var fps_label: Label = content.get_node_or_null("FPSLabel")
		if fps_label:
			fps_label.text = "FPS: %.1f (%.2f ms avg)" % [fps, frame_ms]
		var timing_label: Label = content.get_node_or_null("TimingLabel")
		if timing_label:
			timing_label.text = "P95: %.2f ms" % p95_ms
		var render_label: Label = content.get_node_or_null("RenderLabel")
		if render_label:
			render_label.text = "Draw: %d | Tris: %.1fk" % [draw_calls, primitives / 1000.0]
		var memory_label: Label = content.get_node_or_null("MemoryLabel")
		if memory_label:
			memory_label.text = "Memory: %.1f MB" % mem_mb

	# Update navigation panel
	if _panels.navigation_panel:
		var content := _panels.navigation_panel.get_content_container()
		var camera_label: Label = content.get_node_or_null("CameraLabel")
		if camera_label:
			camera_label.text = "Cell: (%d, %d) | Mode: %s [P]" % [camera_cell.x, camera_cell.y, camera_mode_str]
		var dist_label: Label = content.get_node_or_null("DistLabel")
		if dist_label:
			dist_label.text = "%d cells" % _current_view_distance

	# Update terrain panel
	if _panels.terrain_panel:
		var content := _panels.terrain_panel.get_content_container()
		var terrain_label: Label = content.get_node_or_null("TerrainLabel")
		if terrain_label:
			terrain_label.text = "Regions loaded: %d" % total_regions
		# Update preprocess status
		var status_label_panel: Label = content.get_node_or_null("PreprocessStatusLabel")
		if status_label_panel:
			var terrain_data_dir := SettingsManager.get_terrain_path()
			var has_terrain := DirAccess.dir_exists_absolute(terrain_data_dir)
			if has_terrain:
				status_label_panel.text = "Status: Preprocessed"
				status_label_panel.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
			else:
				status_label_panel.text = "Status: Not preprocessed"
				status_label_panel.add_theme_color_override("font_color", Color(1.0, 0.5, 0.3))

	# Update debug panel
	if _panels.debug_panel:
		var content := _panels.debug_panel.get_content_container()
		var debug_label: Label = content.get_node_or_null("DebugInfoLabel")
		if debug_label:
			var loaded_cells: int = stats.get("loaded_cells", 0)
			var queue_size: int = stats.get("load_queue_size", 0)
			var async_pending: int = stats.get("async_pending", 0)
			debug_label.text = "Cells: %d | Queue: %d | Async: %d" % [loaded_cells, queue_size, async_pending]

		# Update ODM stats (key changed from "per_object_lod" to "object_distance_manager")
		var odm_label: Label = content.get_node_or_null("ODMLabel")
		if odm_label:
			var odm_stats: Dictionary = stats.get("object_distance_manager", {})
			var total_obj: int = odm_stats.get("total_objects", 0)
			var near_obj: int = odm_stats.get("near_visible", 0)
			var mid_obj: int = odm_stats.get("mid_visible", 0)
			var far_obj: int = odm_stats.get("far_visible", 0)
			odm_label.text = "ODM: %d tracked | NEAR: %d MID: %d FAR: %d" % [total_obj, near_obj, mid_obj, far_obj]

		# Update streaming profiler summary
		var profiler_label_node: Label = content.get_node_or_null("ProfilerLabel")
		if profiler_label_node and world_streaming_manager and world_streaming_manager.has_method("get_streaming_profiler"):
			var sp: StreamingProfiler = world_streaming_manager.get_streaming_profiler()
			if sp:
				profiler_label_node.text = sp.get_compact_summary()
			else:
				profiler_label_node.text = "Profiler: not initialized"


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
	print(message.replace("[color=green]", "").replace("[color=red]", "").replace("[color=yellow]", "").replace("[/color]", "").replace("[b]", "").replace("[/b]", ""))


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
				# Dump detailed profiling report - handled by DebugSystem
				# Legacy fallback if DebugSystem not available
				if debug_system:
					pass  # DebugSystem handles this via its own _input
				elif _profiling_report:
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
			KEY_F9:  # Toggle diagnostic overlay - handled by DebugSystem
				# DebugSystem uses its own overlay; legacy diagnostic_overlay kept for compatibility
				if debug_system:
					pass  # DebugSystem handles this via its own _input
				elif diagnostic_overlay:
					diagnostic_overlay.visible = not diagnostic_overlay.visible
					_log("Diagnostic overlay: %s" % ("ON" if diagnostic_overlay.visible else "OFF"))
			KEY_F11:  # Dump current state to log - handled by DebugSystem
				# DebugSystem handles this; legacy fallback for crash_reporter
				if debug_system:
					pass  # DebugSystem handles this via its own _input
				elif crash_reporter:
					crash_reporter.dump_state_now()
					_log("[color=cyan]State dumped to crash report log[/color]")
			KEY_F12:  # Toggle auto-test - handled by DebugSystem
				# No legacy fallback - this is new functionality
				pass  # DebugSystem handles this via its own _input


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
	if ocean_manager and ocean_manager.has_method("set_enabled"):
		ocean_manager.set_enabled(false)
	if world_streaming_manager:
		world_streaming_manager.set_process(false)


## Delegate: restore world elements when switching to world mode
func _on_browser_switch_to_world() -> void:
	if terrain_3d:
		terrain_3d.visible = true
	if ocean_manager and ocean_manager.has_method("set_enabled") and _show_ocean:
		ocean_manager.set_enabled(true)
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
