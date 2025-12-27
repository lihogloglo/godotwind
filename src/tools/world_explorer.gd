## World Explorer - Complete Morrowind world exploration tool
##
## Features:
## - WORLD MODE: Infinite terrain streaming with multi-region support
##   - Terrain3D for terrain LOD and streaming
##   - OWDB for object streaming (statics, lights, NPCs, etc.)
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
## - Press TAB to toggle between World and Interior modes
## - Use +/- to adjust view distance
##
## Fly Camera: Hold Right-click to look, WASD to move, Space/Shift for up/down
## Player: WASD to move, Space to jump, Shift to run, mouse to look
extends Node3D

# Preload dependencies
const WorldStreamingManagerScript := preload("res://src/core/world/world_streaming_manager.gd")
const GenericTerrainStreamerScript := preload("res://src/core/world/generic_terrain_streamer.gd")
const MorrowindDataProviderScript := preload("res://src/core/world/morrowind_data_provider.gd")
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

# Visibility toggles (will be created dynamically)
var _show_models_toggle: CheckBox = null
var _show_characters_toggle: CheckBox = null
var _show_ocean_toggle: CheckBox = null
var _show_sky_toggle: CheckBox = null
var _water_quality_btn: OptionButton = null
var _resolution_btn: OptionButton = null
# Ocean parameter sliders
var _wind_speed_slider: HSlider = null
var _wind_dir_slider: HSlider = null
var _wave_scale_slider: HSlider = null
var _choppiness_slider: HSlider = null
var _debug_shore_toggle: CheckBox = null
var _ocean_controls_container: VBoxContainer = null
var _show_models: bool = false  # Default OFF for performance
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
var world_streaming_manager: WorldStreamingManager = null  # WorldStreamingManager (objects only)
var terrain_streamer: GenericTerrainStreamer = null  # GenericTerrainStreamer (terrain only)
var terrain_data_provider: MorrowindDataProvider = null  # MorrowindDataProvider
var terrain_manager: TerrainManager = null  # TerrainManager (kept for legacy compatibility)
var texture_loader: TerrainTextureLoader = null  # TerrainTextureLoader
var cell_manager: CellManager = null  # CellManager
var profiler: PerformanceProfiler = null  # PerformanceProfiler
var ocean_manager: OceanManagerClass = null  # OceanManager
var background_processor: BackgroundProcessor = null  # BackgroundProcessor for async loading
var console: Console = null  # Developer console
var test_runner: Node = null  # Automated test runner (AutomatedTestRunner)

# State
var _data_path: String = ""
var _initialized: bool = false
var _using_preprocessed: bool = false
var _perf_overlay_visible: bool = true
var _current_view_distance: int = 2  # Start with smaller view distance for faster initial load

# Interior cell browser state
enum ExplorerMode { WORLD, INTERIOR }
var _current_mode: ExplorerMode = ExplorerMode.WORLD
var _all_cells: Array[Dictionary] = []  # {name, is_interior, record, ref_count, grid_x, grid_y}
var _filtered_cells: Array[Dictionary] = []
var _current_filter: String = "interior"  # "interior", "exterior", "all"
var _search_timer: Timer = null
var _max_display_items: int = 500
var _loaded_interior_cell: Node3D = null

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
	cell_manager.init_object_pool()

	# Initialize profiler
	profiler = PerformanceProfilerScript.new()
	profiler.start_session()

	# Setup camera systems
	_setup_cameras()

	# Setup developer console
	_setup_console()

	# Setup automated test runner
	_setup_test_runner()

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

	# Check for pre-processed terrain
	await _update_loading(50, "Checking terrain data...")
	_check_preprocessed_terrain()

	# Initialize Terrain3D
	await _update_loading(60, "Initializing Terrain3D...")
	_init_terrain3d()

	# Load pre-processed terrain if available, or enable on-the-fly generation
	if _using_preprocessed:
		await _update_loading(70, "Loading terrain data...")
		_load_preprocessed_terrain()
	else:
		_log("[color=yellow]No pre-processed terrain found.[/color]")
		_log("[color=cyan]Using on-the-fly terrain generation.[/color]")
		_log("(For better performance, click 'Preprocess ALL Terrain')")
		await _update_loading(70, "Configuring terrain...")

	# Ocean system is now lazy-loaded - created on first toggle

	# Create and setup WorldStreamingManager (but don't start tracking yet)
	await _update_loading(85, "Setting up streaming system...")
	_setup_world_streaming_manager(false)  # Pass false to delay tracking

	# Preload common models in background for faster initial cell loading
	# This starts async loading of ~100 common models (flora, rocks, containers, etc.)
	# Models will be ready when user first loads cells, reducing visible pop-in
	await _update_loading(90, "Preloading common models...")
	if world_streaming_manager:
		world_streaming_manager.preload_common_models(false)  # false = async
		_log("Started async preload of common models")

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

	# NOW start tracking the camera - terrain/cells will generate around Seyda Neen
	world_streaming_manager.set_tracked_node(camera)
	if terrain_streamer:
		terrain_streamer.set_tracked_node(camera)


func _check_preprocessed_terrain() -> void:
	# Check for pre-processed terrain data in cache folder
	var terrain_data_dir := SettingsManager.get_terrain_path()
	var dir := DirAccess.open(terrain_data_dir)
	if dir:
		var count := 0
		dir.list_dir_begin()
		var file_name := dir.get_next()
		while file_name != "":
			if file_name.ends_with(".res"):
				count += 1
			file_name = dir.get_next()
		dir.list_dir_end()

		if count > 0:
			_using_preprocessed = true
			_log("Found %d pre-processed terrain regions" % count)

	_update_preprocess_status()


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

	# Register cloud control commands
	var cloud_scale_params: Array[CommandRegistry.ParameterInfo] = [
		CommandRegistry.ParameterInfo.new("scale", TYPE_FLOAT, "Cloud scale (0.1-5.0, smaller = larger clouds)")
	]
	console.register_command(
		"cloudscale", _cmd_cloud_scale,
		"Set volumetric cloud scale (smaller values = larger clouds)",
		"sky",
		PackedStringArray(["cs"]),
		cloud_scale_params,
		PackedStringArray(["cloudscale 0.3", "cs 1.0"])
	)

	var cloud_coverage_params: Array[CommandRegistry.ParameterInfo] = [
		CommandRegistry.ParameterInfo.new("coverage", TYPE_FLOAT, "Cloud coverage (0.0-1.0)")
	]
	console.register_command(
		"cloudcoverage", _cmd_cloud_coverage,
		"Set cloud coverage (0 = clear, 1 = overcast)",
		"sky",
		PackedStringArray(["cc"]),
		cloud_coverage_params,
		PackedStringArray(["cloudcoverage 0.5", "cc 0.8"])
	)

	var cloud_height_params: Array[CommandRegistry.ParameterInfo] = [
		CommandRegistry.ParameterInfo.new("height", TYPE_FLOAT, "Cloud base height (1.0-20.0)")
	]
	console.register_command(
		"cloudheight", _cmd_cloud_height,
		"Set cloud base height",
		"sky",
		PackedStringArray(["ch"]),
		cloud_height_params,
		PackedStringArray(["cloudheight 5.0", "ch 10.0"])
	)

	var cloud_density_params: Array[CommandRegistry.ParameterInfo] = [
		CommandRegistry.ParameterInfo.new("density", TYPE_FLOAT, "Cloud density multiplier (0.1-3.0)")
	]
	console.register_command(
		"clouddensity", _cmd_cloud_density,
		"Set cloud density multiplier",
		"sky",
		PackedStringArray(["cd"]),
		cloud_density_params,
		PackedStringArray(["clouddensity 1.5", "cd 2.0"])
	)

	var cloud_thickness_params: Array[CommandRegistry.ParameterInfo] = [
		CommandRegistry.ParameterInfo.new("thickness", TYPE_FLOAT, "Cloud layer thickness (1.0-20.0)")
	]
	console.register_command(
		"cloudthickness", _cmd_cloud_thickness,
		"Set cloud layer vertical thickness",
		"sky",
		PackedStringArray(["ct"]),
		cloud_thickness_params,
		PackedStringArray(["cloudthickness 8.0", "ct 12.0"])
	)

	var cloud_speed_params: Array[CommandRegistry.ParameterInfo] = [
		CommandRegistry.ParameterInfo.new("speed", TYPE_FLOAT, "Wind speed in m/s (0-120)")
	]
	console.register_command(
		"cloudspeed", _cmd_cloud_speed,
		"Set cloud wind speed",
		"sky",
		PackedStringArray(["cspd"]),
		cloud_speed_params,
		PackedStringArray(["cloudspeed 1.0", "cspd 0.5"])
	)

	var cloud_detail_params: Array[CommandRegistry.ParameterInfo] = [
		CommandRegistry.ParameterInfo.new("strength", TYPE_FLOAT, "Detail erosion strength (0.0-1.0)")
	]
	console.register_command(
		"clouddetail", _cmd_cloud_detail,
		"Set cloud detail erosion strength (makes clouds wispier)",
		"sky",
		PackedStringArray(["cdet"]),
		cloud_detail_params,
		PackedStringArray(["clouddetail 0.2", "cdet 0.5"])
	)

	var cloud_info_params: Array[CommandRegistry.ParameterInfo] = []
	console.register_command(
		"cloudinfo", _cmd_cloud_info,
		"Show current cloud parameters",
		"sky",
		PackedStringArray(["ci"]),
		cloud_info_params,
		PackedStringArray(["cloudinfo"])
	)

	var cloud_color_params: Array[CommandRegistry.ParameterInfo] = [
		CommandRegistry.ParameterInfo.new("color", TYPE_STRING, "Color name: red, green, blue, pink, white")
	]
	console.register_command(
		"cloudcolor", _cmd_cloud_color,
		"Set cloud color for debugging (red, green, blue, pink, white)",
		"sky",
		PackedStringArray(["ccol"]),
		cloud_color_params,
		PackedStringArray(["cloudcolor red", "ccol pink"])
	)

	var cloud_procedural_params: Array[CommandRegistry.ParameterInfo] = []
	console.register_command(
		"cloudprocedural", _cmd_cloud_procedural,
		"Toggle procedural noise (bypasses 3D textures for debugging)",
		"sky",
		PackedStringArray(["cproc"]),
		cloud_procedural_params,
		PackedStringArray(["cloudprocedural", "cproc"])
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


## Handle test completion
func _on_test_completed(report: Dictionary) -> void:
	var errors: Dictionary = report.get("errors", {})
	var total_count: int = errors.get("total_count", 0)
	_log("[color=green]Test completed with %d errors[/color]" % total_count)


## Handle test error capture
func _on_test_error_captured(error: String) -> void:
	_log("[color=red]TEST ERROR: %s[/color]" % error.substr(0, 100))


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


## Console command: Set cloud scale
func _cmd_cloud_scale(args: Dictionary) -> CommandRegistry.CommandResult:
	if not sky_3d or not sky_3d.sky:
		return CommandRegistry.CommandResult.error("Sky3D not initialized. Toggle sky on first.")
	var dome := sky_3d.sky as SkyDomeVolumetric
	if not dome:
		return CommandRegistry.CommandResult.error("SkyDomeVolumetric not available.")
	var scale: float = args.get("scale", 1.0)
	scale = clampf(scale, 0.1, 5.0)
	dome.vol_cloud_scale = scale
	return CommandRegistry.CommandResult.ok("Cloud scale set to %.2f" % scale)


## Console command: Set cloud coverage
func _cmd_cloud_coverage(args: Dictionary) -> CommandRegistry.CommandResult:
	if not sky_3d or not sky_3d.sky:
		return CommandRegistry.CommandResult.error("Sky3D not initialized. Toggle sky on first.")
	var dome := sky_3d.sky as SkyDomeVolumetric
	if not dome:
		return CommandRegistry.CommandResult.error("SkyDomeVolumetric not available.")
	var coverage: float = args.get("coverage", 0.5)
	coverage = clampf(coverage, 0.0, 1.0)
	dome.vol_cloud_coverage = coverage
	return CommandRegistry.CommandResult.ok("Cloud coverage set to %.2f" % coverage)


## Console command: Set cloud height
func _cmd_cloud_height(args: Dictionary) -> CommandRegistry.CommandResult:
	if not sky_3d or not sky_3d.sky:
		return CommandRegistry.CommandResult.error("Sky3D not initialized. Toggle sky on first.")
	var dome := sky_3d.sky as SkyDomeVolumetric
	if not dome:
		return CommandRegistry.CommandResult.error("SkyDomeVolumetric not available.")
	var height: float = args.get("height", 3.0)
	height = clampf(height, 1.0, 20.0)
	dome.vol_cloud_base_height = height
	return CommandRegistry.CommandResult.ok("Cloud base height set to %.2f" % height)


## Console command: Set cloud density
func _cmd_cloud_density(args: Dictionary) -> CommandRegistry.CommandResult:
	if not sky_3d or not sky_3d.sky:
		return CommandRegistry.CommandResult.error("Sky3D not initialized. Toggle sky on first.")
	var dome := sky_3d.sky as SkyDomeVolumetric
	if not dome:
		return CommandRegistry.CommandResult.error("SkyDomeVolumetric not available.")
	var density: float = args.get("density", 1.0)
	density = clampf(density, 0.1, 3.0)
	dome.vol_cloud_density = density
	return CommandRegistry.CommandResult.ok("Cloud density set to %.2f" % density)


## Console command: Set cloud thickness
func _cmd_cloud_thickness(args: Dictionary) -> CommandRegistry.CommandResult:
	if not sky_3d or not sky_3d.sky:
		return CommandRegistry.CommandResult.error("Sky3D not initialized. Toggle sky on first.")
	var dome := sky_3d.sky as SkyDomeVolumetric
	if not dome:
		return CommandRegistry.CommandResult.error("SkyDomeVolumetric not available.")
	var thickness: float = args.get("thickness", 5.0)
	thickness = clampf(thickness, 1.0, 20.0)
	dome.vol_cloud_thickness = thickness
	return CommandRegistry.CommandResult.ok("Cloud thickness set to %.2f" % thickness)


## Console command: Set cloud wind speed
func _cmd_cloud_speed(args: Dictionary) -> CommandRegistry.CommandResult:
	if not sky_3d or not sky_3d.sky:
		return CommandRegistry.CommandResult.error("Sky3D not initialized. Toggle sky on first.")
	var dome := sky_3d.sky as SkyDomeVolumetric
	if not dome:
		return CommandRegistry.CommandResult.error("SkyDomeVolumetric not available.")
	var speed: float = args.get("speed", 1.0)
	speed = clampf(speed, 0.0, 120.0)
	dome.wind_speed = speed
	return CommandRegistry.CommandResult.ok("Cloud wind speed set to %.2f m/s" % speed)


## Console command: Set cloud detail erosion
func _cmd_cloud_detail(args: Dictionary) -> CommandRegistry.CommandResult:
	if not sky_3d or not sky_3d.sky:
		return CommandRegistry.CommandResult.error("Sky3D not initialized. Toggle sky on first.")
	var dome := sky_3d.sky as SkyDomeVolumetric
	if not dome:
		return CommandRegistry.CommandResult.error("SkyDomeVolumetric not available.")
	var strength: float = args.get("strength", 0.4)
	strength = clampf(strength, 0.0, 1.0)
	dome.vol_cloud_detail_strength = strength
	return CommandRegistry.CommandResult.ok("Cloud detail strength set to %.2f" % strength)


## Console command: Show cloud info
func _cmd_cloud_info(_args: Dictionary) -> CommandRegistry.CommandResult:
	if not sky_3d:
		return CommandRegistry.CommandResult.error("Sky3D not initialized. Toggle sky on first.")
	if not sky_3d.sky:
		return CommandRegistry.CommandResult.error("SkyDome not available.")

	var dome := sky_3d.sky as SkyDomeVolumetric
	if not dome:
		return CommandRegistry.CommandResult.error("SkyDomeVolumetric not available.")
	var info := "Volumetric Cloud Parameters:\n"
	info += "  Enabled: %s\n" % str(dome.volumetric_clouds_enabled)
	info += "  Scale: %.2f (smaller = larger clouds)\n" % dome.vol_cloud_scale
	info += "  Coverage: %.2f\n" % dome.vol_cloud_coverage
	info += "  Density: %.2f\n" % dome.vol_cloud_density
	info += "  Base Height: %.2f\n" % dome.vol_cloud_base_height
	info += "  Thickness: %.2f\n" % dome.vol_cloud_thickness
	info += "  Detail Strength: %.2f\n" % dome.vol_cloud_detail_strength
	info += "  Wind Speed: %.2f m/s\n" % dome.wind_speed
	info += "  March Steps: %d\n" % dome.vol_cloud_march_steps
	info += "  Procedural Noise: %s\n" % str(dome.vol_use_procedural_noise)
	info += "  Shape Texture: %s\n" % ("loaded" if dome.vol_cloud_shape_texture else "MISSING")
	info += "  Detail Texture: %s\n" % ("loaded" if dome.vol_cloud_detail_texture else "MISSING")
	info += "\nCommands: cloudscale (cs), cloudcoverage (cc), cloudheight (ch),"
	info += "\n          clouddensity (cd), cloudthickness (ct), cloudspeed (cspd),"
	info += "\n          clouddetail (cdet), cloudcolor (ccol), cloudprocedural (cproc)"
	return CommandRegistry.CommandResult.ok(info)


## Console command: Set cloud debug color (for visibility testing)
func _cmd_cloud_color(args: Dictionary) -> CommandRegistry.CommandResult:
	if not sky_3d or not sky_3d.sky:
		return CommandRegistry.CommandResult.error("Sky3D not initialized. Toggle sky on first.")
	var dome := sky_3d.sky as SkyDomeVolumetric
	if not dome:
		return CommandRegistry.CommandResult.error("SkyDomeVolumetric not available.")

	var color_name: String = args.get("color", "white")
	var base_color: Color
	var shadow_color: Color

	match color_name.to_lower():
		"red":
			base_color = Color(1.0, 0.2, 0.2)
			shadow_color = Color(0.5, 0.1, 0.1)
		"green":
			base_color = Color(0.2, 1.0, 0.2)
			shadow_color = Color(0.1, 0.5, 0.1)
		"blue":
			base_color = Color(0.2, 0.2, 1.0)
			shadow_color = Color(0.1, 0.1, 0.5)
		"pink":
			base_color = Color(1.0, 0.4, 0.8)
			shadow_color = Color(0.5, 0.2, 0.4)
		"white", _:
			base_color = Color(0.95, 0.95, 1.0)
			shadow_color = Color(0.4, 0.45, 0.55)

	dome.vol_cloud_base_color = base_color
	dome.vol_cloud_shadow_color = shadow_color
	return CommandRegistry.CommandResult.ok("Cloud color set to: %s" % color_name)


## Console command: Toggle procedural noise (for debugging texture issues)
func _cmd_cloud_procedural(args: Dictionary) -> CommandRegistry.CommandResult:
	if not sky_3d or not sky_3d.sky:
		return CommandRegistry.CommandResult.error("Sky3D not initialized. Toggle sky on first.")
	var dome := sky_3d.sky as SkyDomeVolumetric
	if not dome:
		return CommandRegistry.CommandResult.error("SkyDomeVolumetric not available.")

	dome.vol_use_procedural_noise = not dome.vol_use_procedural_noise
	var status: String = "ON (slow but works without textures)" if dome.vol_use_procedural_noise else "OFF (uses 3D textures)"
	return CommandRegistry.CommandResult.ok("Procedural noise: %s" % status)


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
		world_streaming_manager.set_tracked_node(player_controller)
	if terrain_streamer:
		terrain_streamer.set_tracked_node(player_controller)

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
		world_streaming_manager.set_tracked_node(fly_camera)
	if terrain_streamer:
		terrain_streamer.set_tracked_node(fly_camera)

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

	if _using_preprocessed:
		preprocess_status.text = "Using pre-processed terrain"
		preprocess_status.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
		preprocess_btn.text = "Re-preprocess Terrain"
	else:
		preprocess_status.text = "On-the-fly generation"
		preprocess_status.add_theme_color_override("font_color", Color(1.0, 0.8, 0.3))
		preprocess_btn.text = "Preprocess ALL Terrain"


## Setup visibility toggle checkboxes
func _setup_visibility_toggles() -> void:
	# Find the VBox container in stats panel
	var vbox: VBoxContainer = stats_panel.get_node_or_null("VBox")
	if not vbox:
		return

	# Row 1: Basic visibility toggles (Models, NPCs, Ocean, Sky)
	var toggle_row1 := HBoxContainer.new()
	toggle_row1.name = "VisibilityToggles"

	_show_models_toggle = CheckBox.new()
	_show_models_toggle.text = "Models"
	_show_models_toggle.button_pressed = _show_models
	_show_models_toggle.toggled.connect(_on_show_models_toggled)
	_show_models_toggle.tooltip_text = "Toggle static models"
	toggle_row1.add_child(_show_models_toggle)

	_show_characters_toggle = CheckBox.new()
	_show_characters_toggle.text = "NPCs"
	_show_characters_toggle.button_pressed = _show_characters
	_show_characters_toggle.toggled.connect(_on_show_characters_toggled)
	_show_characters_toggle.tooltip_text = "Toggle NPCs and creatures"
	toggle_row1.add_child(_show_characters_toggle)

	_show_ocean_toggle = CheckBox.new()
	_show_ocean_toggle.text = "Ocean"
	_show_ocean_toggle.button_pressed = _show_ocean
	_show_ocean_toggle.toggled.connect(_on_show_ocean_toggled)
	toggle_row1.add_child(_show_ocean_toggle)

	_show_sky_toggle = CheckBox.new()
	_show_sky_toggle.text = "Sky"
	_show_sky_toggle.button_pressed = _show_sky
	_show_sky_toggle.toggled.connect(_on_show_sky_toggled)
	toggle_row1.add_child(_show_sky_toggle)

	# Create fallback environment and light for when Sky3D is disabled
	_setup_fallback_environment()

	# Row 2: Resolution and Water Quality dropdowns
	var settings_row := HBoxContainer.new()
	settings_row.name = "SettingsRow"

	var res_label := Label.new()
	res_label.text = "Res:"
	res_label.custom_minimum_size.x = 30
	settings_row.add_child(res_label)

	_resolution_btn = OptionButton.new()
	_resolution_btn.add_item("720p", 0)
	_resolution_btn.add_item("900p", 1)
	_resolution_btn.add_item("1080p", 2)
	_resolution_btn.add_item("1440p", 3)
	_resolution_btn.add_item("Full", 4)
	_resolution_btn.selected = 2
	_resolution_btn.item_selected.connect(_on_resolution_changed)
	_resolution_btn.tooltip_text = "Window resolution"
	_resolution_btn.custom_minimum_size.x = 70
	settings_row.add_child(_resolution_btn)

	var water_label := Label.new()
	water_label.text = "Water:"
	water_label.custom_minimum_size.x = 45
	settings_row.add_child(water_label)

	_water_quality_btn = OptionButton.new()
	_water_quality_btn.add_item("Auto", -1)
	_water_quality_btn.add_item("Flat", 0)
	_water_quality_btn.add_item("FFT", 1)
	_water_quality_btn.selected = 0
	_water_quality_btn.item_selected.connect(_on_water_quality_changed)
	_water_quality_btn.tooltip_text = "Water quality: Flat (simple) or FFT (GPU waves)"
	_water_quality_btn.custom_minimum_size.x = 65
	settings_row.add_child(_water_quality_btn)

	# Ocean controls container (shown/hidden with ocean toggle)
	_ocean_controls_container = VBoxContainer.new()
	_ocean_controls_container.name = "OceanControls"
	_ocean_controls_container.visible = false  # Hidden until ocean is enabled

	var ocean_label := Label.new()
	ocean_label.text = "Ocean Settings:"
	ocean_label.add_theme_font_size_override("font_size", 12)
	_ocean_controls_container.add_child(ocean_label)

	# Wind Speed slider
	_wind_speed_slider = _create_slider_row(_ocean_controls_container, "Wind:", 0.0, 40.0, 10.0, _on_wind_speed_changed)
	_wind_speed_slider.tooltip_text = "Wind speed (m/s) - affects wave steepness"

	# Wind Direction slider
	_wind_dir_slider = _create_slider_row(_ocean_controls_container, "Dir:", -180.0, 180.0, 0.0, _on_wind_dir_changed)
	_wind_dir_slider.tooltip_text = "Wind direction (degrees)"

	# Wave Scale slider
	_wave_scale_slider = _create_slider_row(_ocean_controls_container, "Scale:", 0.0, 3.0, 1.0, _on_wave_scale_changed)
	_wave_scale_slider.step = 0.1
	_wave_scale_slider.tooltip_text = "Wave height multiplier"

	# Choppiness slider
	_choppiness_slider = _create_slider_row(_ocean_controls_container, "Chop:", 0.0, 2.0, 1.0, _on_choppiness_changed)
	_choppiness_slider.step = 0.1
	_choppiness_slider.tooltip_text = "Wave choppiness/sharpness"

	# Debug shore mask toggle
	_debug_shore_toggle = CheckBox.new()
	_debug_shore_toggle.text = "Debug Shore Mask"
	_debug_shore_toggle.button_pressed = false
	_debug_shore_toggle.toggled.connect(_on_debug_shore_toggled)
	_debug_shore_toggle.tooltip_text = "Visualize shore damping: Magenta=shore, Cyan=deep water"
	_ocean_controls_container.add_child(_debug_shore_toggle)

	# Insert controls into the panel
	var preprocess_idx := preprocess_btn.get_index() if preprocess_btn else vbox.get_child_count()
	vbox.add_child(toggle_row1)
	vbox.move_child(toggle_row1, preprocess_idx)
	vbox.add_child(settings_row)
	vbox.move_child(settings_row, preprocess_idx + 1)
	vbox.add_child(_ocean_controls_container)
	vbox.move_child(_ocean_controls_container, preprocess_idx + 2)

	# Apply initial resolution (1920x1080)
	_apply_resolution(2)


## Helper to create a labeled slider row
func _create_slider_row(parent: Control, label_text: String, min_val: float, max_val: float, default_val: float, callback: Callable) -> HSlider:
	var row := HBoxContainer.new()

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 40
	label.add_theme_font_size_override("font_size", 11)
	row.add_child(label)

	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.value = default_val
	slider.step = 1.0
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size.x = 120
	slider.value_changed.connect(callback)
	row.add_child(slider)

	var value_label := Label.new()
	value_label.name = "Value"
	value_label.text = "%.1f" % default_val
	value_label.custom_minimum_size.x = 35
	value_label.add_theme_font_size_override("font_size", 11)
	row.add_child(value_label)

	parent.add_child(row)
	return slider


## Update value label next to slider
func _update_slider_label(slider: HSlider, value: float) -> void:
	var row: HBoxContainer = slider.get_parent()
	var value_label: Label = row.get_node_or_null("Value")
	if value_label:
		value_label.text = "%.1f" % value


## Ocean parameter callbacks
func _on_wind_speed_changed(value: float) -> void:
	_update_slider_label(_wind_speed_slider, value)
	if ocean_manager:
		ocean_manager.wind_speed = value
		_update_ocean_wave_params()

func _on_wind_dir_changed(value: float) -> void:
	_update_slider_label(_wind_dir_slider, value)
	if ocean_manager:
		ocean_manager.wind_direction = deg_to_rad(value)
		_update_ocean_wave_params()

func _on_wave_scale_changed(value: float) -> void:
	_update_slider_label(_wave_scale_slider, value)
	if ocean_manager:
		ocean_manager.wave_scale = value
		if ocean_manager.has_method("_update_shader_parameters"):
			ocean_manager._update_shader_parameters()

func _on_choppiness_changed(value: float) -> void:
	_update_slider_label(_choppiness_slider, value)
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


## Toggle models visibility
## Industry standard: Toggle should only change visibility, not trigger mass loading
## New cells will load naturally via _process() streaming - no need to force refresh
func _on_show_models_toggled(enabled: bool) -> void:
	_show_models = enabled

	_log("[DIAG] Models toggle: %s" % ("ON" if enabled else "OFF"))

	# Toggle object loading in WorldStreamingManager
	if world_streaming_manager:
		world_streaming_manager.load_objects = enabled
		# Also control distant rendering (impostors) with the Models toggle
		world_streaming_manager.distant_rendering_enabled = enabled

		var loaded_coords: Array[Vector2i] = world_streaming_manager.get_loaded_cell_coordinates()
		_log("[DIAG] Currently loaded cells: %d" % loaded_coords.size())

		# Show/hide existing loaded cell objects
		var visible_count := 0
		for cell_grid: Vector2i in loaded_coords:
			var cell_node: Node3D = world_streaming_manager.get_loaded_cell(cell_grid.x, cell_grid.y)
			if cell_node:
				cell_node.visible = enabled
				visible_count += 1

		_log("[DIAG] Set visibility for %d cell nodes" % visible_count)

		# Toggle impostor visibility
		var impostor_mgr: Node = world_streaming_manager.get_node_or_null("ImpostorManager")
		if impostor_mgr and impostor_mgr.has_method("set_all_visible"):
			impostor_mgr.call("set_all_visible", enabled)
			_log("[DIAG] Impostors visibility: %s" % ("ON" if enabled else "OFF"))

		# When enabling, clear tier state and trigger fresh loading
		if enabled:
			# Clear stale tier tracking that may have accumulated
			if world_streaming_manager.has_method("clear_tier_state"):
				world_streaming_manager.clear_tier_state()
			world_streaming_manager.refresh_cells()

		# Log current queue states
		if cell_manager:
			var inst_queue: int = cell_manager.get_instantiation_queue_size() if cell_manager.has_method("get_instantiation_queue_size") else 0
			var async_pending: int = cell_manager.get_async_pending_count() if cell_manager.has_method("get_async_pending_count") else 0
			_log("[DIAG] After toggle: inst_queue=%d, async_pending=%d" % [inst_queue, async_pending])

	_log("Models: %s" % ("ON" if enabled else "OFF"))
	_update_stats()


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
	if _ocean_controls_container:
		_ocean_controls_container.visible = enabled

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
	if not ocean_manager:
		return
	if _wind_speed_slider:
		_wind_speed_slider.value = ocean_manager.wind_speed
		_update_slider_label(_wind_speed_slider, ocean_manager.wind_speed)
	if _wind_dir_slider:
		_wind_dir_slider.value = rad_to_deg(ocean_manager.wind_direction)
		_update_slider_label(_wind_dir_slider, rad_to_deg(ocean_manager.wind_direction))
	if _wave_scale_slider:
		_wave_scale_slider.value = ocean_manager.wave_scale
		_update_slider_label(_wave_scale_slider, ocean_manager.wave_scale)
	if _choppiness_slider:
		_choppiness_slider.value = ocean_manager.choppiness
		_update_slider_label(_choppiness_slider, ocean_manager.choppiness)


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
	_log("Ocean system initialized (quality: %s)" % ocean_manager.get_water_quality_name())


## Handle water quality change
func _on_water_quality_changed(index: int) -> void:
	if not ocean_manager:
		return

	# Get the quality value from item ID (-1 = auto, 0-3 = specific quality)
	var quality: int = _water_quality_btn.get_item_id(index)
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

	_log("Initializing Sky3D with volumetric clouds...")

	# Remove fallback environment BEFORE adding Sky3D (only one WorldEnvironment can be active)
	if _fallback_world_env and _fallback_world_env.is_inside_tree():
		remove_child(_fallback_world_env)
	if _fallback_light:
		_fallback_light.visible = false

	# Instantiate Sky3DVolumetric for raymarched volumetric clouds
	sky_3d = Sky3DVolumetric.new()
	sky_3d.name = "Sky3D"

	# Add to scene tree FIRST - this triggers Sky3D's _initialize() which creates the environment
	add_child(sky_3d)

	# Configure AFTER adding to tree so _initialize() has run and environment exists
	sky_3d.current_time = 12.0
	sky_3d.ambient_energy = 0.5

	# Start enabled
	sky_3d.sky3d_enabled = true

	_sky3d_initialized = true
	_log("Sky3D initialized with volumetric clouds")


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

	# Tonemapping (ACES for better contrast)
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	env.tonemap_white = 6.0

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

	# First, collect all unique regions that have terrain data
	var regions_with_data: Dictionary = {}  # region_coord -> true

	for key: String in ESMManager.lands:
		var land: LandRecord = ESMManager.lands[key]
		if not land or not land.has_heights():
			continue

		# Get the region this cell belongs to
		var region_coord: Vector2i = terrain_manager.cell_to_region(Vector2i(land.cell_x, land.cell_y))
		regions_with_data[region_coord] = true

	_log("Found %d combined regions to process (from %d cells)" % [regions_with_data.size(), ESMManager.lands.size()])

	# Process each combined region
	var total_regions := regions_with_data.size()
	var processed := 0
	var skipped := 0

	# Create callable for getting LAND records
	var get_land_func := func(cell_x: int, cell_y: int) -> LandRecord:
		return ESMManager.get_land(cell_x, cell_y)

	for region_coord: Vector2i in regions_with_data.keys():
		# Import combined region (4x4 cells at once)
		if terrain_manager.import_combined_region(terrain_3d, region_coord, get_land_func):
			processed += 1
		else:
			skipped += 1

		# Update progress
		var percent := float(processed + skipped) / float(total_regions) * 100.0
		preprocess_status.text = "Processing... %.0f%% (%d/%d regions)" % [percent, processed + skipped, total_regions]

		# Yield periodically to keep UI responsive
		if (processed + skipped) % 10 == 0:
			await get_tree().process_frame

	# Save to disk (cache folder)
	var terrain_data_dir := SettingsManager.get_terrain_path()
	DirAccess.make_dir_recursive_absolute(terrain_data_dir)
	terrain_3d.data.save_directory(terrain_data_dir)

	_log("[color=green]Terrain preprocessing complete![/color]")
	_log("  Processed: %d combined regions (4x4 cells each)" % processed)
	_log("  Skipped: %d regions (no height data)" % skipped)
	_log("  Saved to: %s" % terrain_data_dir)

	_using_preprocessed = true
	preprocess_btn.disabled = false
	_update_preprocess_status()


func _setup_world_streaming_manager(start_tracking: bool = true) -> void:
	# ========== NEW SIMPLIFIED ARCHITECTURE ==========
	# WorldStreamingManager: Objects ONLY
	# GenericTerrainStreamer: Terrain ONLY
	# =================================================

	# Create WorldStreamingManager (objects only)
	var wsm_node := Node3D.new()
	wsm_node.set_script(WorldStreamingManagerScript)
	wsm_node.name = "WorldStreamingManager"
	world_streaming_manager = wsm_node as WorldStreamingManager

	# Configure
	world_streaming_manager.view_distance_cells = _current_view_distance
	world_streaming_manager.load_objects = _show_models  # Respect default setting
	world_streaming_manager.distant_rendering_enabled = _show_models  # Impostors follow Models toggle
	world_streaming_manager.debug_enabled = true

	# OWDB configuration for Morrowind objects
	var chunk_sizes: Array[float] = [8.0, 16.0, 64.0]
	world_streaming_manager.owdb_chunk_sizes = chunk_sizes
	world_streaming_manager.owdb_chunk_load_range = 3
	world_streaming_manager.owdb_batch_time_limit_ms = 5.0

	add_child(world_streaming_manager)

	# Connect signals
	world_streaming_manager.cell_loaded.connect(_on_cell_loaded)
	world_streaming_manager.cell_unloaded.connect(_on_cell_unloaded)

	# Provide managers
	world_streaming_manager.set_cell_manager(cell_manager)
	if background_processor:
		world_streaming_manager.set_background_processor(background_processor)

	# Initialize after all configuration is set
	world_streaming_manager.initialize()

	# Preload common models in background
	world_streaming_manager.preload_common_models(false)

	# ========== TERRAIN STREAMING (SEPARATE) ==========
	# Create terrain data provider
	terrain_data_provider = MorrowindDataProviderScript.new()
	var init_error: Error = terrain_data_provider.initialize()
	if init_error != OK:
		push_warning("Failed to initialize MorrowindDataProvider: %s" % error_string(init_error))
	else:
		# Set terrain assets for texture mapping
		if terrain_3d and terrain_3d.assets:
			terrain_data_provider.set_terrain_assets(terrain_3d.assets)

	# Create GenericTerrainStreamer (terrain only)
	terrain_streamer = GenericTerrainStreamerScript.new()
	terrain_streamer.name = "GenericTerrainStreamer"
	terrain_streamer.view_distance_regions = 3  # Reduced for performance
	terrain_streamer.debug_enabled = true
	terrain_streamer.set_provider(terrain_data_provider)
	terrain_streamer.set_terrain_3d(terrain_3d)
	if background_processor:
		terrain_streamer.set_background_processor(background_processor)

	add_child(terrain_streamer)
	terrain_streamer.terrain_region_loaded.connect(_on_terrain_region_loaded)

	_log("[color=green]Simplified architecture: WorldStreamingManager (objects) + GenericTerrainStreamer (terrain)[/color]")

	# Only start tracking if requested (allows teleporting BEFORE streaming starts)
	if start_tracking:
		world_streaming_manager.set_tracked_node(camera)
		terrain_streamer.set_tracked_node(camera)

	_log("WorldStreamingManager created and configured")
	if _using_preprocessed:
		_log("Using pre-processed terrain data")
	else:
		_log("[color=cyan]Using on-the-fly terrain generation[/color]")

	# Register world streaming manager with console
	if console:
		console.register_context("world", world_streaming_manager)
		console.register_context("player", player_controller)


func _on_terrain_region_loaded(region: Vector2i) -> void:
	_log("Terrain generated: (%d, %d)" % [region.x, region.y])
	_update_stats()


func _on_cell_loaded(grid: Vector2i, node: Node3D) -> void:
	var obj_count := node.get_child_count()
	_log("Cell loaded: (%d, %d) - %d objects" % [grid.x, grid.y, obj_count])

	# Record cell load in profiler
	if profiler and world_streaming_manager:
		var stats: Dictionary = world_streaming_manager.get_stats()
		var load_time: float = stats.get("load_time_ms", 0.0)
		profiler.record_cell_load(load_time, obj_count)

	_update_stats()


func _on_cell_unloaded(grid: Vector2i) -> void:
	_log("Cell unloaded: (%d, %d)" % [grid.x, grid.y])
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
	if not world_streaming_manager:
		return

	var stats: Dictionary = world_streaming_manager.get_stats()

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
		"ON" if _show_models else "OFF",
		"ON" if _show_characters else "OFF",
		"ON" if _show_ocean else "OFF",
		"ON" if _show_sky else "OFF",
		ocean_manager.get_water_quality_name() if ocean_manager else "N/A",
		camera_mode_str,
		stats.get("camera_cell", Vector2i(0, 0)).x,
		stats.get("camera_cell", Vector2i(0, 0)).y,
	]


# ==================== UI Helpers ====================

func _show_loading(title: String, status: String) -> void:
	loading_overlay.visible = true
	loading_label.text = title
	status_label.text = status
	progress_bar.value = 0


func _hide_loading() -> void:
	loading_overlay.visible = false


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
				_toggle_explorer_mode()
			KEY_F3:
				# Toggle performance overlay
				_perf_overlay_visible = not _perf_overlay_visible
				stats_panel.visible = _perf_overlay_visible
				_log("Performance overlay: %s" % ("ON" if _perf_overlay_visible else "OFF"))
			KEY_F4:
				# Dump detailed profiling report
				_dump_profiling_report()
			KEY_EQUAL, KEY_KP_ADD:  # + key
				_adjust_view_distance(1)
			KEY_MINUS, KEY_KP_SUBTRACT:  # - key
				_adjust_view_distance(-1)
			KEY_M:  # Toggle models
				if _show_models_toggle:
					_show_models_toggle.button_pressed = not _show_models_toggle.button_pressed
			KEY_N:  # Toggle NPCs/characters
				if _show_characters_toggle:
					_show_characters_toggle.button_pressed = not _show_characters_toggle.button_pressed
			KEY_O:  # Toggle ocean
				if _show_ocean_toggle:
					_show_ocean_toggle.button_pressed = not _show_ocean_toggle.button_pressed
			KEY_K:  # Toggle sky/day-night cycle
				if _show_sky_toggle:
					_show_sky_toggle.button_pressed = not _show_sky_toggle.button_pressed


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
func _adjust_view_distance(delta: int) -> void:
	_current_view_distance = clampi(_current_view_distance + delta, 1, 8)
	if world_streaming_manager:
		world_streaming_manager.view_distance_cells = _current_view_distance
		world_streaming_manager.refresh_cells()
	_log("View distance: %d cells (~%dm)" % [_current_view_distance, _current_view_distance * 117])
	_update_stats()


# ==================== Interior Cell Browser ====================

## Setup interior cell browser UI and signals
func _setup_interior_browser() -> void:
	# Create search debounce timer
	_search_timer = Timer.new()
	_search_timer.one_shot = true
	_search_timer.wait_time = 0.2
	_search_timer.timeout.connect(_apply_cell_filter)
	add_child(_search_timer)

	# Create interior container if it doesn't exist
	if not interior_container:
		interior_container = Node3D.new()
		interior_container.name = "InteriorContainer"
		add_child(interior_container)

	# Connect UI signals if elements exist
	if mode_toggle_btn:
		mode_toggle_btn.pressed.connect(_toggle_explorer_mode)

	if cell_search_edit:
		cell_search_edit.text_changed.connect(_on_cell_search_changed)

	if cell_list:
		cell_list.item_selected.connect(_on_cell_list_selected)
		cell_list.item_activated.connect(_on_cell_list_activated)

	if interior_filter_btn:
		interior_filter_btn.pressed.connect(func() -> void: _set_cell_filter("interior"))

	if exterior_filter_btn:
		exterior_filter_btn.pressed.connect(func() -> void: _set_cell_filter("exterior"))

	if all_filter_btn:
		all_filter_btn.pressed.connect(func() -> void: _set_cell_filter("all"))

	# Hide interior panel by default
	if interior_panel:
		interior_panel.visible = false


## Toggle between World and Interior modes
func _toggle_explorer_mode() -> void:
	if _current_mode == ExplorerMode.WORLD:
		_switch_to_interior_mode()
	else:
		_switch_to_world_mode()


## Switch to interior cell browsing mode
func _switch_to_interior_mode() -> void:
	_current_mode = ExplorerMode.INTERIOR
	_log("[color=cyan]Switched to INTERIOR mode[/color]")

	# Hide world streaming elements
	if terrain_3d:
		terrain_3d.visible = false

	# Hide ocean
	if ocean_manager and ocean_manager.has_method("set_enabled"):
		ocean_manager.set_enabled(false)

	# Pause world streaming
	if world_streaming_manager:
		world_streaming_manager.set_process(false)

	# Show interior panel
	if interior_panel:
		interior_panel.visible = true

	# Update mode button text
	if mode_toggle_btn:
		mode_toggle_btn.text = "Switch to World Mode"

	# Build cell list if not already built
	if _all_cells.is_empty() and ESMManager.cells.size() > 0:
		_build_cell_list()
		_apply_cell_filter()


## Switch back to world streaming mode
func _switch_to_world_mode() -> void:
	_current_mode = ExplorerMode.WORLD
	_log("[color=cyan]Switched to WORLD mode[/color]")

	# Clear loaded interior cell
	if _loaded_interior_cell:
		_loaded_interior_cell.queue_free()
		_loaded_interior_cell = null

	# Show world streaming elements
	if terrain_3d:
		terrain_3d.visible = true

	# Show ocean (if toggle is enabled)
	if ocean_manager and ocean_manager.has_method("set_enabled") and _show_ocean:
		ocean_manager.set_enabled(true)

	# Resume world streaming
	if world_streaming_manager:
		world_streaming_manager.set_process(true)

	# Hide interior panel
	if interior_panel:
		interior_panel.visible = false

	# Update mode button text
	if mode_toggle_btn:
		mode_toggle_btn.text = "Switch to Interior Mode"


## Build list of all cells for browser
func _build_cell_list() -> void:
	_all_cells.clear()

	for cell_id: String in ESMManager.cells:
		var cell: CellRecord = ESMManager.cells[cell_id]
		var cell_info := {
			"name": cell.name if cell.is_interior() else "Exterior (%d, %d)" % [cell.grid_x, cell.grid_y],
			"is_interior": cell.is_interior(),
			"record": cell,
			"ref_count": cell.references.size(),
			"grid_x": cell.grid_x,
			"grid_y": cell.grid_y,
		}
		_all_cells.append(cell_info)

	# Sort: interiors by name, exteriors by grid
	_all_cells.sort_custom(func(a: Dictionary, b: Dictionary) -> int:
		if a["is_interior"] != b["is_interior"]:
			return -1 if a["is_interior"] else 1  # Interiors first
		if a["is_interior"]:
			var name_a: String = a["name"]
			var name_b: String = b["name"]
			return name_a.naturalnocasecmp_to(name_b)
		else:
			var grid_x_a: int = a["grid_x"]
			var grid_x_b: int = b["grid_x"]
			if grid_x_a != grid_x_b:
				return grid_x_a - grid_x_b
			var grid_y_a: int = a["grid_y"]
			var grid_y_b: int = b["grid_y"]
			return grid_y_a - grid_y_b
	)

	_log("Built cell list: %d cells (%d interior, %d exterior)" % [
		_all_cells.size(),
		_all_cells.filter(func(c: Dictionary) -> bool: return c["is_interior"]).size(),
		_all_cells.filter(func(c: Dictionary) -> bool: return not c["is_interior"]).size()
	])


## Handle cell search text changed
func _on_cell_search_changed(_new_text: String) -> void:
	if _search_timer:
		_search_timer.start()


## Set cell filter type (interior/exterior/all)
func _set_cell_filter(filter: String) -> void:
	_current_filter = filter

	# Update button states
	if interior_filter_btn:
		interior_filter_btn.button_pressed = filter == "interior"
	if exterior_filter_btn:
		exterior_filter_btn.button_pressed = filter == "exterior"
	if all_filter_btn:
		all_filter_btn.button_pressed = filter == "all"

	_apply_cell_filter()


## Apply search and filter to cell list
func _apply_cell_filter() -> void:
	if not cell_list or _all_cells.is_empty():
		return

	_filtered_cells.clear()

	var search_text := ""
	if cell_search_edit:
		search_text = cell_search_edit.text.strip_edges().to_lower()

	for cell_info: Dictionary in _all_cells:
		# Apply type filter
		if _current_filter == "interior" and not cell_info["is_interior"]:
			continue
		if _current_filter == "exterior" and cell_info["is_interior"]:
			continue

		# Apply search filter
		if not search_text.is_empty():
			var cell_name: String = cell_info["name"]
			var name_lower: String = cell_name.to_lower()
			if name_lower.find(search_text) < 0:
				continue

		_filtered_cells.append(cell_info)

	_populate_cell_list()


## Populate the cell list UI with filtered cells
func _populate_cell_list() -> void:
	if not cell_list:
		return

	cell_list.clear()

	var display_count := mini(_filtered_cells.size(), _max_display_items)
	for i in display_count:
		var cell_info: Dictionary = _filtered_cells[i]
		var display_name: String = cell_info["name"]
		if cell_info["ref_count"] > 0:
			display_name += " (%d objects)" % cell_info["ref_count"]

		cell_list.add_item(display_name)
		cell_list.set_item_metadata(i, cell_info)

		# Color code: interiors white, exteriors light blue
		if not cell_info["is_interior"]:
			cell_list.set_item_custom_fg_color(i, Color(0.7, 0.85, 1.0))


## Handle cell list item selected
func _on_cell_list_selected(_index: int) -> void:
	pass  # Could show preview or details


## Handle cell list item activated (double-clicked)
func _on_cell_list_activated(index: int) -> void:
	if not cell_list:
		return

	var cell_info: Dictionary = cell_list.get_item_metadata(index)
	_load_interior_cell(cell_info)


## Load an interior cell for viewing
func _load_interior_cell(cell_info: Dictionary) -> void:
	var cell_record: CellRecord = cell_info["record"]

	_log("\n[b]Loading cell: '%s'[/b]" % cell_info["name"])

	# Clear existing interior cell
	if _loaded_interior_cell:
		_loaded_interior_cell.queue_free()
		_loaded_interior_cell = null

	if not interior_container:
		return

	# Clear interior container
	for child in interior_container.get_children():
		child.queue_free()

	var start_time := Time.get_ticks_msec()
	var cell_node: Node3D = null

	# Load the cell
	if cell_info["is_interior"]:
		cell_node = cell_manager.load_cell(cell_record.name)
	else:
		var grid_x: int = cell_info["grid_x"]
		var grid_y: int = cell_info["grid_y"]
		cell_node = cell_manager.load_exterior_cell(grid_x, grid_y)

	if not cell_node:
		_log("[color=red]Failed to load cell[/color]")
		return

	var elapsed := Time.get_ticks_msec() - start_time
	interior_container.add_child(cell_node)
	_loaded_interior_cell = cell_node

	_log("[color=green]Cell loaded in %d ms[/color]" % elapsed)
	_log("Objects: %d" % cell_node.get_child_count())

	# Position camera for cell
	_position_camera_for_interior_cell(cell_record)


## Position camera to view an interior cell
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


## Dump detailed profiling report to console and log
func _dump_profiling_report() -> void:
	if not profiler:
		_log("[color=red]Profiler not initialized[/color]")
		return

	# Count lights in scene
	profiler.count_lights(self)

	var report: Dictionary = profiler.get_report()

	# Log summary
	_log("\n[b]====== PROFILING REPORT ======[/b]")
	_log("Session duration: %.1f seconds" % report.session.duration_sec)
	_log("")
	_log("[b]Frame Timing[/b]")
	_log("  FPS: %.1f (%.2f ms avg)" % [report.frame_timing.fps, report.frame_timing.avg_ms])
	_log("  P50: %.2f ms | P95: %.2f ms | P99: %.2f ms" % [
		report.frame_timing.p50_ms, report.frame_timing.p95_ms, report.frame_timing.p99_ms
	])
	_log("  Max frame: %.2f ms" % report.frame_timing.max_ms)
	_log("")
	_log("[b]Rendering[/b]")
	_log("  Draw calls: %d (peak: %d)" % [report.rendering.draw_calls, report.rendering.peak_draw_calls])
	_log("  Primitives: %d (peak: %d)" % [report.rendering.primitives, report.rendering.peak_primitives])
	_log("  Objects visible: %d" % report.rendering.objects_visible)
	_log("")
	_log("[b]Memory[/b]")
	_log("  Static: %.1f MB" % report.memory.static_memory_mb)
	_log("  Nodes: %d | Resources: %d" % [report.memory.nodes_in_tree, report.memory.resources_in_use])
	_log("")
	_log("[b]Cell Loading[/b]")
	_log("  Cells loaded: %d" % report.session.total_cells_loaded)
	_log("  Objects loaded: %d" % report.session.total_objects_loaded)
	_log("  Avg load time: %.1f ms" % report.cell_loading.avg_load_time_ms)
	_log("")
	_log("[b]Lights[/b]")
	_log("  Total: %d | With shadows: %d" % [report.lights.total, report.lights.with_shadows])

	var materials_data: Dictionary = report.get("materials", {})
	if not materials_data.is_empty():
		_log("")
		_log("[b]Materials[/b]")
		_log("  Unique materials: %d" % materials_data.get("cached_materials", 0))
		_log("  Cache hits: %d" % materials_data.get("cache_hits", 0))
		var mat_hit_rate: float = materials_data.get("hit_rate", 0.0)
		_log("  Hit rate: %.1f%%" % (mat_hit_rate * 100.0))

	var textures_data: Dictionary = report.get("textures", {})
	if not textures_data.is_empty():
		_log("")
		_log("[b]Textures[/b]")
		_log("  Loaded: %d" % textures_data.get("textures_loaded", 0))
		_log("  Cache hits: %d" % textures_data.get("cache_hits", 0))

	# Add object pool stats
	var cell_stats: Dictionary = {}
	if cell_manager.has_method("get_stats"):
		cell_stats = cell_manager.call("get_stats")
	var pool_available: int = cell_stats.get("pool_available", 0)
	var pool_in_use: int = cell_stats.get("pool_in_use", 0)
	if pool_available > 0 or pool_in_use > 0:
			_log("")
			_log("[b]Object Pool[/b]")
			_log("  Available: %d | In use: %d" % [
				cell_stats.get("pool_available", 0),
				cell_stats.get("pool_in_use", 0)
			])
			_log("  From pool: %d" % cell_stats.get("objects_from_pool", 0))
			_log("  Hit rate: %.1f%%" % (cell_stats.get("pool_hit_rate", 0.0) * 100.0))

	# Add BSA cache stats
	var bsa_cache_stats: Dictionary = BSAManager.get_cache_stats()
	_log("")
	_log("[b]BSA Extraction Cache[/b]")
	_log("  Size: %.1f MB (%d files)" % [
		bsa_cache_stats.get("cache_size_mb", 0.0),
		bsa_cache_stats.get("cached_files", 0)
	])
	_log("  Hits: %d | Misses: %d | Rate: %.1f%%" % [
		bsa_cache_stats.get("cache_hits", 0),
		bsa_cache_stats.get("cache_misses", 0),
		bsa_cache_stats.get("hit_rate", 0.0) * 100.0
	])

	var slowest_models: Array = report.get("slowest_models", [])
	if not slowest_models.is_empty():
		_log("")
		_log("[b]Slowest Models[/b]")
		for model: Dictionary in slowest_models:
			var avg_ms: float = model.get("avg_ms", 0.0)
			var model_path: String = model.get("path", "")
			var model_count: int = model.get("count", 0)
			_log("  %.2f ms - %s (x%d)" % [avg_ms, model_path.get_file(), model_count])

	_log("[b]==============================[/b]")

	# Also print full report to console for easy copying
	print("\n" + JSON.stringify(report, "  "))


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
