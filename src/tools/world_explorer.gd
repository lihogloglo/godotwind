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
##   LodDebugCommands    — LOD console commands (src/tools/lod_debug_commands.gd)
##   ProfilingReport     — UI log profiling (src/tools/profiling_report.gd)
##
## Controls:
##   ~     Developer console       P     Toggle camera mode
##   F3    Performance overlay     F4    Profiling report
##   F9    Debug overlay           F11   State dump
##   F12   Auto-test mode
##   N     NPCs toggle             O     Ocean toggle
##   K     Sky toggle              +/-   View distance
##   ENTER Enter/exit doors (interior transitions)
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
const WeatherControlsScript := preload("res://src/tools/ui/weather_controls.gd")
const StatsCollectorScript := preload("res://src/tools/ui/stats_collector.gd")
const BackgroundProcessorScript := preload("res://src/core/streaming/background_processor.gd")
const FlyCameraScript := preload("res://src/core/player/fly_camera.gd")
const PlayerControllerScript := preload("res://src/core/player/player_controller.gd")
const ConsoleScript := preload("res://src/core/console/console.gd")
const ExplorerPanelsScript := preload("res://src/tools/ui/explorer_panels.gd")
const CellBrowserScript := preload("res://src/tools/ui/cell_browser.gd")
const InteriorPocketManagerScript := preload("res://src/core/world/interior_pocket_manager.gd")
# Debug/diagnostic scripts — lazy-loaded on first use to speed up startup
var _AutomatedTestRunnerScript: GDScript
var _DebugOverlayScript: GDScript
var _DiagnosticOverlayScript: GDScript
var _BatchDebugHUDScript: GDScript
var _CrashReporterScript: GDScript
var _DebugSystemScript: GDScript
var _StreamingBenchmarkScript: GDScript
var _MidTierDebuggerScript: GDScript
const CharacterFactoryV2Script := preload("res://src/core/animation/character_factory_v2.gd")
const ModRegistryScript := preload("res://src/core/modding/mod_registry.gd")
const MWCarryableRegistryScript := preload("res://src/core/interaction/morrowind/mw_carryable_registry.gd")
const InventoryServiceScript := preload("res://src/core/interaction/inventory_service.gd")
const MWInventoryServiceScript := preload("res://src/core/interaction/morrowind/mw_inventory_service.gd")
# Interaction framework main-scene integration (2026-04-09).
const InteractionRaycasterScript := preload("res://src/core/interaction/interaction_raycaster.gd")
const CarryControllerScript := preload("res://src/core/interaction/carry_controller.gd")
const DoorInteractableScript := preload("res://src/core/interaction/morrowind/door_interactable.gd")
# Dialogue system integration (C.3-C.7)
const DialogueUIScript := preload("res://src/core/ui/dialogue_panel.gd")
const BookViewerScript := preload("res://src/core/ui/book_viewer.gd")
const JournalPanelScript := preload("res://src/core/ui/journal_panel.gd")
const DialogueSessionScript := preload("res://src/core/dialogue/dialogue_session.gd")
const QuestManagerScript := preload("res://src/core/dialogue/quest_manager.gd")
const MWDialogueProviderScript := preload("res://src/core/dialogue/morrowind/mw_dialogue_provider.gd")
const MWDialogueContextScript := preload("res://src/core/dialogue/morrowind/mw_dialogue_context.gd")
const MWQuestAdapterScript := preload("res://src/core/dialogue/morrowind/mw_quest_adapter.gd")
const MWResultScriptHandlerScript := preload("res://src/core/dialogue/morrowind/mw_result_script_handler.gd")
const MWTextFormatterScript := preload("res://src/core/dialogue/morrowind/mw_text_formatter.gd")
const SubsystemTogglesScript := preload("res://src/tools/subsystem_toggles.gd")
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


# UI panels (constructed by ExplorerPanels)
var _panels: ExplorerPanels = null
# Models are always visible (no toggle needed)
var _show_characters: bool = false  # Default OFF - separate from static models

# Escape menu
var _escape_menu: ColorRect = null

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
var _weather_controls: WeatherControls = null  # WeatherControls (weather + time-of-day)
var _stats_collector: StatsCollector = null  # StatsCollector (panel label updates)
var background_processor: BackgroundProcessor = null  # BackgroundProcessor for async loading
var mod_registry: ModRegistry = null  # ModRegistry for mod loading
var console: Console = null  # Developer console
var test_runner: Node = null  # Automated test runner (AutomatedTestRunner)
var diagnostic_overlay: Node = null  # Real-time streaming diagnostics (DiagnosticOverlay)
var crash_reporter: Node = null  # State capture for crash analysis (CrashReporter)
var debug_system: Node = null  # Unified debug system (DebugSystem - F4/F9/F11/F12)
var _profiling_report: ProfilingReport = null  # UI log panel profiling report
var _batch_debug_hud: Node = null  # Batch pool debug visualization (BatchDebugHUD)
var _lod_debug_commands: LodDebugCommands = null  # LOD console commands (prevent GC)
var _pocket_manager: Node = null  # InteriorPocketManager
var _door_prompt_label: Label = null  # "Press E to enter" prompt
var _horizon_map_manager: HorizonMapManager = null  # Terrain self-shadowing
var _subsystem_toggles: RefCounted = null  # SubsystemToggles — benchmark A/B feature flags
var _loading_time_ms: int = 0  # Total loading time (for benchmark harness)
var _loading_phase_times: Dictionary = {}  # Per-phase loading times

# State
var _data_path: String = ""
var _initialized: bool = false
var _is_loading: bool = true  # Blocks input until startup complete
var _perf_overlay_visible: bool = true
var _current_view_distance: int = 5  # Must be at least 5 cells (585m) to cover MID tier (500m)
var _character_assets_preloaded: bool = false  # Deferred until characters first enabled
var _player_npc_id: String = "fargoth"  # Default player character NPC ID

# Interior cell browser (constructed by CellBrowser)
var _cell_browser: CellBrowser = null

# Camera mode state
enum CameraMode { FLY_CAMERA, PLAYER_CONTROLLER }
var _camera_mode: CameraMode = CameraMode.FLY_CAMERA
var fly_camera: FlyCamera = null  # FlyCamera instance (with script)
var player_controller: PlayerController = null  # PlayerController instance

# Interaction framework main-scene integration (2026-04-09)
var _interaction_raycaster: InteractionRaycaster = null
var _fly_raycaster: InteractionRaycaster = null  # Separate raycaster for fly camera mode
var _carry_controller: Node = null  # CarryController (no class_name export to avoid preload cycle)

# Dialogue system (C.3-C.7)
var _dialogue_ui: DialogueUI = null
var _book_viewer: BookViewer = null
var _journal_panel: JournalPanel = null
var _dialogue_session: DialogueSession = null
var _quest_manager: QuestManager = null
var _mw_quest_adapter: MWQuestAdapter = null
var _mw_result_handler: MWResultScriptHandler = null
var _mw_dialogue_provider: MWDialogueProvider = null
var _mw_dialogue_context: MWDialogueContext = null


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_do_fast_quit()


## Immediate shutdown: free GPU resources, set quitting flag, skip slow tree teardown.
## Called from both Alt+F4 (NOTIFICATION_WM_CLOSE_REQUEST) and the escape menu Quit button.
func _do_fast_quit() -> void:
	# Global quitting flag — checked by _exit_tree handlers to bail immediately
	Engine.set_meta("_quitting", true)

	# Stop background worker threads from blocking on WTP handles
	if native_streaming_manager:
		native_streaming_manager.fast_cleanup()

	# Disable deformation persistence so shutdown() skips disk I/O
	DeformationConfig.enable_persistence = false

	get_tree().quit()


func _ready() -> void:
	# Intercept window close to do fast cleanup instead of slow tree teardown
	get_tree().set_auto_accept_quit(false)

	var _t0 := Time.get_ticks_msec()
	var _t_step := _t0

	# I.1 — Register MW carryable record types with the framework registry.
	# Must run before cell streaming begins so the reference instantiator
	# sees a populated registry on its first carryable encounter. Idempotent.
	MWCarryableRegistryScript.register_all()

	# I.2 — Register the MW inventory service. PickupInteractable.interact()
	# routes through InventoryService.current() — without this the tap path
	# falls back to a "no service registered" warn and stays in world.
	InventoryServiceScript.set_current(MWInventoryServiceScript.new())

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

	_t_step = _log_timing(_t_step, "managers + object pool")

	# Initialize profiler
	profiler = PerformanceProfilerScript.new()
	profiler.start_session()

	# Setup camera systems
	_setup_cameras()
	_t_step = _log_timing(_t_step, "cameras")

	# Setup dialogue system (must be after cameras — needs PlayerController for modal gates)
	_setup_dialogue()
	_t_step = _log_timing(_t_step, "dialogue")

	# Setup developer console
	_setup_console()
	_t_step = _log_timing(_t_step, "console")

	# Setup automated test runner
	_setup_test_runner()
	_t_step = _log_timing(_t_step, "test runner")

	# Setup diagnostic overlay and crash reporter
	_setup_diagnostic_systems()
	_t_step = _log_timing(_t_step, "diagnostic systems")

	# Connect quick teleport buttons
	seyda_neen_btn.pressed.connect(func() -> void: _teleport_to_cell(-2, -9))
	balmora_btn.pressed.connect(func() -> void: _teleport_to_cell(-3, -2))
	vivec_btn.pressed.connect(func() -> void: _teleport_to_cell(5, -6))
	origin_btn.pressed.connect(func() -> void: _teleport_to_cell(0, 0))


	# Setup interior cell browser
	_setup_interior_browser()
	_t_step = _log_timing(_t_step, "interior browser")

	# Setup visibility toggles
	_setup_visibility_toggles()
	_t_step = _log_timing(_t_step, "visibility toggles + panels")

	# Create escape menu (Esc to toggle)
	_create_escape_menu()

	print("[TIMING] _ready() total: %d ms" % (Time.get_ticks_msec() - _t0))

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
	var _ta0 := Time.get_ticks_msec()
	var _ta := _ta0

	# Initialize ModRegistry
	await _update_loading(2, "Initializing mod registry...")
	mod_registry = ModRegistryScript.new()
	var mod_err := mod_registry.load_manifest()
	if mod_err == OK:
		_log("Mod registry initialized (%d mods)" % mod_registry.total_mods_loaded)
	else:
		_log("[color=yellow]Warning: Mod registry failed to load manifest (error %d)[/color]" % mod_err)
	_ta = _log_timing(_ta, "mod registry")

	# Load BSA archives
	await _update_loading(5, "Loading BSA archives...")
	# 1. Load vanilla BSAs
	var bsa_count := BSAManager.load_archives_from_directory(_data_path)

	# 2. Load mod BSAs
	var mod_bsas := mod_registry.get_bsa_load_order()
	for bsa_path in mod_bsas:
		if BSAManager.load_archive(bsa_path) == OK:
			bsa_count += 1

	_log("Loaded %d BSA archives (vanilla + mods)" % bsa_count)
	_ta = _log_timing(_ta, "BSA archives")

	# Initialize background processor for async loading
	background_processor = BackgroundProcessorScript.new()
	background_processor.name = "BackgroundProcessor"
	add_child(background_processor)
	cell_manager.set_background_processor(background_processor)

	# Register mod registry with loaders that need asset resolution
	if cell_manager.has_method("set_mod_registry"):
		cell_manager.call("set_mod_registry", mod_registry)

	_log("Background processor initialized for async cell loading")

	# Pre-warm BSA cache only when NOT in runtime mode (prebaking needs it, runtime loads from .res)
	if not cell_manager._model_loader.runtime_mode:
		await _update_loading(10, "Pre-warming file cache...")
		_prewarm_bsa_cache()
		_ta = _log_timing(_ta, "BSA prewarm")

	# Load ESM/ESP files
	await _update_loading(30, "Loading game data (ESM/ESPs)...")

	# 1. Load primary ESM
	var esm_file: String = SettingsManager.get_esm_file()
	var esm_path := _data_path.path_join(esm_file)
	var error := ESMManager.load_file(esm_path)

	if error != OK:
		_log("[color=red]ERROR: Failed to load ESM: %s[/color]" % error_string(error))
		_hide_loading()
		return
	_ta = _log_timing(_ta, "ESM load (primary)")

	# 2. Load mod ESPs
	var mod_esps := mod_registry.get_esp_load_order()
	for esp_path in mod_esps:
		var esp_err := ESMManager.load_file(esp_path)
		if esp_err != OK:
			_log("[color=yellow]Warning: Failed to load mod ESP: %s[/color]" % esp_path.get_file())
	_ta = _log_timing(_ta, "ESP mods")

	_log("[color=green]Game data loaded successfully[/color]")
	_log("LAND records: %d, CELL records: %d" % [ESMManager.lands.size(), ESMManager.cells.size()])

	# Initialize Terrain3D
	await _update_loading(50, "Initializing Terrain3D...")
	_init_terrain3d()
	_ta = _log_timing(_ta, "Terrain3D init")

	# Load pre-processed terrain (terrain is always prebaked)
	await _update_loading(70, "Loading terrain data...")
	_load_preprocessed_terrain()
	_ta = _log_timing(_ta, "terrain data load")

	# Load horizon maps for terrain self-shadowing (if prebaked)
	_horizon_map_manager = HorizonMapManager.new()
	var sun: DirectionalLight3D = _find_sun_light()
	if terrain_3d and sun:
		_horizon_map_manager.initialize(terrain_3d, sun)
		# Push wet map uniforms (sea_level from OceanManager or project settings)
		var sea_lvl: float = ProjectSettings.get_setting("ocean/sea_level", 0.0)
		_horizon_map_manager.push_wet_map(sea_lvl)
	_ta = _log_timing(_ta, "horizon maps")

	# Ocean system is now lazy-loaded - created on first toggle

	# Pre-warm model cache with common models (improves first-cell loading)
	await _update_loading(80, "Pre-loading common models...")
	var preload_count := cell_manager.preload_common_models()
	_log("Pre-loaded %d common models into cache" % preload_count)
	_ta = _log_timing(_ta, "preload common models")

	# Auto-prebake character animations if not cached (one-time ~28s, then <1s on future launches)
	await _update_loading(85, "Checking character animations...")
	_auto_prebake_animations()
	_ta = _log_timing(_ta, "animation prebake check")

	# Character asset preloading deferred until characters are first enabled
	# CharacterFactoryV2Script.preload_character_assets() called in _on_show_characters_toggled()

	# Create and setup NativeStreamingManager (but don't start tracking yet)
	await _update_loading(90, "Setting up streaming system...")
	_setup_world_streaming_manager(false)  # Pass false to delay tracking
	_ta = _log_timing(_ta, "streaming manager setup")

	# Models load automatically when streaming system starts
	# Visibility is controlled by Godot's native visibility_range system

	# Initialize interior pocket manager
	_setup_pocket_manager()
	_ta = _log_timing(_ta, "pocket manager")

	# Done
	await _update_loading(100, "Ready!")
	_hide_loading()

	_initialized = true
	_loading_time_ms = Time.get_ticks_msec() - _ta0
	print("[TIMING] _init_async() total: %d ms" % _loading_time_ms)
	_log("[color=green]World streaming initialized![/color]")
	_log("Loading time: %d ms" % _loading_time_ms)
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

	# Setup subsystem toggles (needs all managers initialized)
	_setup_subsystem_toggles()


func _init_terrain3d() -> void:
	if not ClassDB.class_exists("Terrain3DData"):
		_log("[color=red]ERROR: Terrain3D addon not loaded[/color]")
		return

	if not terrain_3d:
		_log("[color=red]ERROR: Terrain3D node not found in scene[/color]")
		return

	# Use shared configuration from CoordinateSystem (single source of truth)
	# This sets vertex_spacing, region_size, material, and assets
	if not CS.configure_terrain3d(terrain_3d):
		_log("[color=red]ERROR: Failed to configure Terrain3D[/color]")
		return

	# Load terrain textures
	var textures_loaded: int = texture_loader.load_terrain_textures(terrain_3d.assets)
	_log("Loaded %d terrain textures" % textures_loaded)

	# Configure terrain manager to use proper texture slot mapping
	terrain_manager.set_texture_slot_mapper(texture_loader)

	_log("Terrain3D configured: region_size=%d, vertex_spacing=%.3f" % [CS.TERRAIN_REGION_SIZE, terrain_3d.get_vertex_spacing()])


func _load_preprocessed_terrain() -> void:
	# Load pre-processed terrain data from cache folder
	if not terrain_3d or not terrain_3d.data:
		_log("[color=yellow]Warning: Terrain3D not ready for loading preprocessed data[/color]")
		return

	var terrain_data_dir := SettingsManager.get_terrain_path()
	if DirAccess.dir_exists_absolute(terrain_data_dir):
		terrain_3d.data.load_directory(terrain_data_dir)
		_log("Loaded preprocessed terrain: %d regions from %s" % [
			terrain_3d.data.get_region_count(), terrain_data_dir])
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

	# Interaction framework wiring (2026-04-09 main-scene integration).
	# PlayerController._ready has already run at this point (it ran on
	# add_child above), so get_camera() returns a valid first-person
	# Camera3D under the SpringArm3D. Raycaster sits as a child of the
	# camera so its forward cast tracks the look direction; CarryController
	# sits as a child of the player rig and uses a Marker3D under the
	# camera as the hold target. Same wiring as
	# tests/visual/test_interaction_phase_I3.gd.
	var player_camera := player_controller.get_camera()
	if player_camera != null:
		_interaction_raycaster = InteractionRaycasterScript.new()
		_interaction_raycaster.name = "InteractionRaycaster"
		_interaction_raycaster.camera = player_camera
		# Cast from the player's eye (camera_pivot = head at 1.7m) in the
		# camera's forward direction. Works in both first- and third-person:
		# in third-person the SpringArm3D pushes the camera ~3m back, but
		# the ray origin stays at the character's head so interaction reach
		# is measured from the player, not from the chase cam. Canonical
		# third-person interaction pattern — matches AC / RDR2 / Skyrim.
		_interaction_raycaster.ray_origin_node = player_controller.camera_pivot
		_interaction_raycaster.max_distance = 5.0
		player_camera.add_child(_interaction_raycaster)
		# Start disabled — scene opens in fly-camera mode. The
		# player-mode switch re-enables physics_process below.
		_interaction_raycaster.set_physics_process(false)
		player_controller.set_interaction_raycaster(_interaction_raycaster)
		_interaction_raycaster.prompt_changed.connect(_on_interact_prompt_changed)

		_carry_controller = CarryControllerScript.new()
		_carry_controller.name = "CarryController"
		player_controller.add_child(_carry_controller)
		_carry_controller.setup(player_camera, player_controller)
		player_controller.set_carry_controller(_carry_controller)
		_log("Interaction framework wired (raycaster + carry controller)")
	else:
		Log.warn("interaction", "PlayerController.get_camera() returned null — interaction framework NOT wired")

	# Fly camera raycaster — same Interactable layer 3, child of fly camera
	# so the cast direction tracks the look direction. Enabled by default
	# since the scene starts in fly camera mode.
	if fly_camera:
		_fly_raycaster = InteractionRaycasterScript.new()
		_fly_raycaster.name = "FlyRaycaster"
		_fly_raycaster.camera = fly_camera
		_fly_raycaster.max_distance = 5.0
		fly_camera.add_child(_fly_raycaster)
		_fly_raycaster.prompt_changed.connect(_on_interact_prompt_changed)

	# Start in fly camera mode
	_camera_mode = CameraMode.FLY_CAMERA
	player_controller.disable()

	_log("Camera systems initialized (P to toggle)")


## Setup dialogue system (C.3-C.7)
## Spawns persistent UI singletons, wires MW adapters, registers modal gates.
## Must run AFTER _setup_cameras() so PlayerController exists for modal gates.
func _setup_dialogue() -> void:
	# MW text formatting callbacks (image loading from BSA, font size mapping)
	MWTextFormatterScript.setup()

	# Framework UI panels — persistent CanvasLayers, opened/closed per conversation.
	_dialogue_ui = DialogueUIScript.new()
	_dialogue_ui.name = "DialogueUI"
	add_child(_dialogue_ui)

	_book_viewer = BookViewerScript.new()
	_book_viewer.name = "BookViewer"
	add_child(_book_viewer)

	_journal_panel = JournalPanelScript.new()
	_journal_panel.name = "JournalPanel"
	add_child(_journal_panel)

	# Quest manager (framework)
	_quest_manager = QuestManagerScript.new()
	_journal_panel.set_quest_manager(_quest_manager)

	# MW adapters
	_mw_dialogue_provider = MWDialogueProviderScript.new()
	_mw_dialogue_context = MWDialogueContextScript.new()
	# Default context values — updated per-conversation in production,
	# but need sane defaults so the first greeting doesn't crash.
	_mw_dialogue_context.detected = true
	_mw_dialogue_context.set_global("chargenstate", 10.0)

	# Quest adapter — advances journal from response metadata (C.6)
	_mw_quest_adapter = MWQuestAdapterScript.new(_quest_manager)
	_dialogue_ui.response_selected.connect(_mw_quest_adapter.on_response_selected)

	# BNAM result script handler — executes dialogue scripts
	_mw_result_handler = MWResultScriptHandlerScript.new(_quest_manager, _mw_dialogue_context)
	_dialogue_ui.response_selected.connect(_mw_result_handler.on_response_selected)
	_dialogue_ui.greeting_shown.connect(_mw_result_handler.on_greeting_shown)
	_mw_result_handler.goodbye_requested.connect(_dialogue_ui.close)

	# DialogueSession — shared reference holder for interactables
	_dialogue_session = DialogueSessionScript.new()
	_dialogue_session.provider = _mw_dialogue_provider
	_dialogue_session.context = _mw_dialogue_context
	_dialogue_session.dialogue_ui = _dialogue_ui
	_dialogue_session.book_viewer = _book_viewer
	DialogueSession.set_current(_dialogue_session)

	# Modal gates — PlayerController suppresses interact_* while any panel is open
	if player_controller:
		player_controller.register_modal_gate(_dialogue_ui)
		player_controller.register_modal_gate(_book_viewer)
		player_controller.register_modal_gate(_journal_panel)

	# FlyCamera modal check — same gate logic via Callable injection
	if fly_camera:
		fly_camera.modal_check = func() -> bool:
			return _dialogue_session.is_any_panel_open()

	_log("Dialogue system initialized (dialogue + books + journal + quest adapter + BNAM handler)")


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

	# Register weather console commands
	if _weather_controls:
		_weather_controls.register_console_commands(console)

	_log("Console initialized (~ to toggle)")


## Setup automated test runner
func _setup_test_runner() -> void:
	if not _AutomatedTestRunnerScript:
		_AutomatedTestRunnerScript = load("res://src/tools/automated_test_runner.gd")
	var runner: Node = _AutomatedTestRunnerScript.new()
	runner.name = "AutomatedTestRunner"
	add_child(runner)
	test_runner = runner
	
	# Connect signals using signal objects
	runner.connect("test_completed", _on_test_completed)
	runner.connect("error_captured", _on_test_error_captured)
	
	_log("Test runner initialized (F6=start, F7=stop, F8=report)")


## Setup diagnostic overlay, crash reporter, and unified debug system
func _setup_diagnostic_systems() -> void:
	if not _DiagnosticOverlayScript:
		_DiagnosticOverlayScript = load("res://src/tools/ui/diagnostic_overlay.gd")
	if not _CrashReporterScript:
		_CrashReporterScript = load("res://src/tools/crash_reporter.gd")
	if not _DebugSystemScript:
		_DebugSystemScript = load("res://src/tools/debug_system.gd")
	if not _BatchDebugHUDScript:
		_BatchDebugHUDScript = load("res://src/tools/ui/batch_debug_hud.gd")

	# Create diagnostic overlay (hidden by default) - legacy, kept for compatibility
	diagnostic_overlay = _DiagnosticOverlayScript.new()
	diagnostic_overlay.name = "DiagnosticOverlay"
	diagnostic_overlay.visible = false  # Start hidden, toggle with F9
	add_child(diagnostic_overlay)

	# Create crash reporter - legacy, kept for compatibility
	crash_reporter = _CrashReporterScript.new()
	crash_reporter.name = "CrashReporter"
	add_child(crash_reporter)

	# Create unified debug system (merges F4/F9/F11/F12 functionality)
	debug_system = _DebugSystemScript.new()
	debug_system.name = "DebugSystem"
	# Enable auto-test on startup if DEBUG_AUTO_TEST environment variable is set
	debug_system.auto_test_on_startup = OS.has_environment("DEBUG_AUTO_TEST")
	add_child(debug_system)

	# Create batch debug HUD (hidden by default, toggle with `mid_debug` command)
	_batch_debug_hud = _BatchDebugHUDScript.new()
	_batch_debug_hud.name = "BatchDebugHUD"
	add_child(_batch_debug_hud)

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

	# Connect batch debug HUD
	if _batch_debug_hud:
		_batch_debug_hud.set_streaming_manager(native_streaming_manager)
		if camera:
			_batch_debug_hud.set_camera(camera)

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

	# Verify cell exists and is interior
	var cell: CellRecord = ESMManager.get_cell(cell_name)
	if not cell:
		return CommandRegistry.CommandResult.error("Cell not found: %s" % cell_name)
	if not cell.is_interior():
		return CommandRegistry.CommandResult.error("Not an interior cell: %s" % cell_name)

	# Use pocket manager to load and enter
	if _pocket_manager:
		# Pause streaming while inside (camera at Y=-500 would unload all cells)
		_set_streaming_paused(true)
		# Create a synthetic door info for direct teleport
		var door := InteriorPocketManagerScript.DoorInfo.new()
		door.ref_id = &"console_coc"
		door.world_position = camera.global_position
		door.target_cell_name = cell_name
		# Default spawn at cell origin
		door.teleport_pos_mw = Vector3.ZERO
		door.teleport_rot_mw = Vector3.ZERO
		var success: bool = await _pocket_manager.enter_interior(door)
		if not success:
			_set_streaming_paused(false)
			return CommandRegistry.CommandResult.error("Failed to enter: %s" % cell_name)
		return CommandRegistry.CommandResult.ok("Teleporting to: %s" % cell_name)

	return CommandRegistry.CommandResult.error("Pocket manager not initialized")


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

	# Attach player character body if not already attached
	if not player_controller.character_root:
		_attach_player_character()

	# Enable and position player controller
	player_controller.teleport_to(player_pos)
	# Third-person is the default. InteractionRaycaster casts from the
	# player's eye (camera_pivot) in the camera's forward direction, so
	# it works at full reach regardless of where the SpringArm3D puts the
	# camera. See world_explorer._setup_cameras where ray_origin_node is
	# wired, and docs/INTERACTION_SYSTEM.md for the third-person pattern.
	# TAB still toggles first/third-person freely.
	player_controller.set_camera_mode(PlayerControllerScript.CameraMode.THIRD_PERSON)
	player_controller.allow_camera_mode_switch = true
	player_controller.enable()

	# Update camera reference for systems that need it
	camera = player_controller.get_camera()

	# Update tracked node for streaming
	if world_streaming_manager:
		world_streaming_manager.set_camera(camera)

	# Update ocean camera
	if _ocean_controls:
		_ocean_controls.set_camera(camera)

	# Update weather particles camera
	if _weather_controls:
		_weather_controls.set_camera(camera)

	# Update console camera for object picking
	if console:
		console.set_camera(camera)
		console.register_context("camera", camera)

	# Update pocket manager with player body and camera for transitions
	if _pocket_manager:
		_pocket_manager.set_player_body(player_controller)
		_pocket_manager.set_camera(camera)

	# Enable the player raycaster, disable the fly raycaster.
	if _interaction_raycaster:
		_interaction_raycaster.set_physics_process(true)
	if _fly_raycaster:
		_fly_raycaster.set_physics_process(false)

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

	# Update weather particles camera
	if _weather_controls:
		_weather_controls.set_camera(camera)

	# Update console camera for object picking
	if console:
		console.set_camera(camera)
		console.register_context("camera", camera)

	# Update pocket manager camera for transitions
	if _pocket_manager:
		_pocket_manager.set_camera(camera)

	# Disable the player raycaster, enable the fly raycaster.
	if _interaction_raycaster:
		_interaction_raycaster.set_physics_process(false)
	if _fly_raycaster:
		_fly_raycaster.set_physics_process(true)

	_log("[color=cyan]Switched to FLY CAMERA mode[/color]")
	_log("Hold Right-click to look, WASD to move")


## Attach a Morrowind NPC body to the player controller
func _attach_player_character() -> void:
	# Ensure character assets are preloaded (KF animations, skeletons, body parts)
	if not _character_assets_preloaded:
		_character_assets_preloaded = true
		_log("Pre-loading character assets...")
		CharacterFactoryV2Script.preload_character_assets()
		_log("Character assets pre-loaded")

	# Look up NPC record
	var npc_record: NPCRecord = ESMManager.get_npc(_player_npc_id)
	if not npc_record:
		_log("Player NPC not found: %s" % _player_npc_id)
		return

	var race: RaceRecord = ESMManager.get_race(npc_record.race_id)
	if not race:
		_log("Race not found: %s" % npc_record.race_id)
		return

	var is_female: bool = npc_record.is_female()
	var is_beast: bool = race.is_beast() if race else false

	# Assemble body parts (skeleton + meshes)
	var MorrowindNPCAssembler := preload("res://src/core/character/morrowind/morrowind_npc_assembler.gd")
	var character_root: Node3D = MorrowindNPCAssembler.assemble(npc_record, race)
	if not character_root:
		_log("Failed to assemble player NPC: %s" % _player_npc_id)
		return

	# Find skeleton and rename bones (Bip01 -> profile names)
	var SkeletonUtils := preload("res://src/core/animation/skeleton_utils.gd")
	var skeleton: Skeleton3D = _find_skeleton(character_root)
	if not skeleton:
		_log("No skeleton found for player NPC: %s" % _player_npc_id)
		character_root.queue_free()
		return

	var factory := CharacterFactoryV2Script.new()
	factory.enable_ik = true
	factory.enable_lod = false  # Player is always at camera — LOD is pointless overhead
	factory.debug_characters = true
	factory.debug_animations = true

	# Build bone remap BEFORE renaming (Bip01 → profile names)
	factory._ensure_bone_remap(skeleton, is_beast)

	# Rename skeleton bones to profile names (for IK, blend masks)
	var rename_map := SkeletonUtils.rename_bones_to_profile(skeleton)
	if not rename_map.is_empty():
		factory._update_bone_attachment_names(skeleton, rename_map)

	# Add character root to player controller BEFORE loading animations
	player_controller.add_child(character_root)

	# Load KF animations (uses cached remap to convert Bip01 → profile names)
	factory._load_character_animations(character_root, skeleton, is_female, is_beast)

	# Wire animation system (MoveContainer, AnimationManager, IK)
	factory.setup_character(player_controller, is_female, is_beast,
		npc_record.race_id, npc_record.record_id)

	# Create input gatherer (reads hardware input into InputPackage for moves)
	player_controller._setup_input_gatherer()

	_log("Player character attached: %s" % _player_npc_id)


## Recursively find a Skeleton3D in a node hierarchy
func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var result := _find_skeleton(child)
		if result:
			return result
	return null


## Get ground height at a position using terrain data
func _get_ground_height(pos: Vector3) -> float:
	var height := 0.0

	# Try to get height from Terrain3D
	if terrain_3d and terrain_3d.data:
		height = CS.get_terrain_height(pos, terrain_3d)
		if is_nan(height) or height > 10000 or height < -1000:
			height = 0.0

	return height


## Get the currently active camera
func _get_active_camera() -> Camera3D:
	if _camera_mode == CameraMode.PLAYER_CONTROLLER and player_controller:
		return player_controller.get_camera()
	return fly_camera


## Setup visibility toggle checkboxes and foldable panel system
func _setup_visibility_toggles() -> void:
	# Create environment controls (extracted in Session 5)
	var env_callbacks := {
		"log": _log,
		"add_child": add_child,
		"remove_child": remove_child,
		"update_stats": _update_stats,
		"get_viewport": get_viewport,
		"sky_visibility_changed": func(visible: bool) -> void:
			if _weather_controls:
				_weather_controls.on_sky_visibility_changed(visible),
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

	# Create weather controls
	var weather_callbacks := {
		"log": _log,
		"add_child": add_child,
		"get_active_camera": _get_active_camera,
	}
	_weather_controls = WeatherControlsScript.new(weather_callbacks)
	_weather_controls.setup_renderer(_env_controls)

	# Build foldable panels via ExplorerPanels
	var callbacks := {
		"show_characters_toggled": _on_show_characters_toggled,
		"show_ocean_toggled": _ocean_controls.on_show_ocean_toggled,
		"show_sky_toggled": _on_show_sky_toggled,
		"cirrus_changed": _env_controls.on_cirrus_changed,
		"cirrus_size_changed": _env_controls.on_cirrus_size_changed,
		"cirrus_thickness_changed": _env_controls.on_cirrus_thickness_changed,
		"weather_toggled": _weather_controls.on_weather_toggled,
		"weather_type_changed": _weather_controls.on_weather_type_changed,
		"time_of_day_changed": _weather_controls.on_time_of_day_changed,
		"time_scale_changed": _weather_controls.on_time_scale_changed,
		"time_pause_toggled": _weather_controls.on_time_pause_toggled,
		"fog_density_changed": _weather_controls.on_fog_density_changed,
		"cloud_coverage_changed": _weather_controls.on_cloud_coverage_changed,
		"cloud_density_changed": _weather_controls.on_cloud_density_changed,
		"cloud_sharpness_changed": _weather_controls.on_cloud_sharpness_changed,
		"cloud_size_changed": _weather_controls.on_cloud_size_changed,
		"wind_strength_changed": _weather_controls.on_wind_strength_changed,
		"resolution_changed": _on_resolution_changed,
		"water_quality_changed": _ocean_controls.on_water_quality_changed,
		"wave_scale_changed": _ocean_controls.on_wave_scale_changed,
		"choppiness_changed": _ocean_controls.on_choppiness_changed,
		"debug_shore_toggled": _ocean_controls.on_debug_shore_toggled,
		"taa_toggled": _env_controls.on_taa_toggled,
		"ssao_toggled": _env_controls.on_ssao_toggled,
		"ssil_toggled": _env_controls.on_ssil_toggled,
		"glow_toggled": _env_controls.on_glow_toggled,
		"godrays_toggled": _env_controls.on_godrays_toggled,
		"native_vfog_toggled": _env_controls.on_native_volumetric_fog_toggled,
		"depth_fog_toggled": _env_controls.on_depth_fog_toggled,
		"tonemapper_changed": _env_controls.on_tonemapper_changed,
		"shadow_cascades_toggled": _env_controls.on_shadow_cascades_toggled,
		"quality_pretty_preset": _on_quality_pretty_preset,
		"quality_balanced_preset": _on_quality_balanced_preset,
		"quality_fast_preset": _on_quality_fast_preset,
		# VAIO fog/clouds removed from UI — redundant with depth/volumetric fog + SunshineClouds2
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
	_weather_controls.set_panels(_panels)
	_weather_controls.setup_sunshine_clouds(self, _env_controls.get_fallback_light())
	_weather_controls.setup_particles(self, _get_active_camera())

	# Create stats collector (extracted in Session 6)
	_stats_collector = StatsCollectorScript.new(_panels)
	_stats_collector.set_profiler(profiler)
	_stats_collector.set_terrain(terrain_3d)

	# Setup debug overlay for 3D visualizations
	_setup_debug_overlay()

	# Apply initial resolution (1920x1080)
	_apply_resolution(2)



## Setup debug overlay for 3D visualizations
func _setup_debug_overlay() -> void:
	if not _DebugOverlayScript:
		_DebugOverlayScript = load("res://src/tools/ui/debug_overlay.gd")
	_debug_overlay = _DebugOverlayScript.new()
	_debug_overlay.name = "DebugOverlay"
	add_child(_debug_overlay)


## Update debug overlay with camera and managers
func _update_debug_overlay_references() -> void:
	if not _debug_overlay:
		return
	_debug_overlay.set_camera(camera)
	if world_streaming_manager:
		_debug_overlay.set_world_streaming_manager(world_streaming_manager)
	if _batch_debug_hud and camera:
		_batch_debug_hud.set_camera(camera)


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
func _on_show_sky_toggled(enabled: bool) -> void:
	_env_controls.on_show_sky_toggled(enabled)
	# Sync sky reference to weather system (SunshineClouds2 sun tracking, compositor)
	if _weather_controls:
		_weather_controls.sync_sky()


func _on_show_characters_toggled(enabled: bool) -> void:
	_show_characters = enabled

	_log("[DIAG] Characters toggle: %s" % ("ON" if enabled else "OFF"))

	# Lazy-load character assets on first enable (deferred from startup to save ~23s)
	if enabled and not _character_assets_preloaded:
		_character_assets_preloaded = true
		var _tc0 := Time.get_ticks_msec()
		_log("Pre-loading character assets (first enable)...")
		CharacterFactoryV2Script.preload_character_assets()
		print("[TIMING] character asset preload: %d ms" % (Time.get_ticks_msec() - _tc0))
		_log("Character assets pre-loaded")

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

		var _tc_cells := Time.get_ticks_msec()
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
						var _tc_cell := Time.get_ticks_msec()
						_log("[DIAG] Loading characters into cell %s (no existing chars)" % str(cell_grid))
						var new_chars: int = cell_manager.load_characters_into_cell(cell_grid.x, cell_grid.y, cell_node)
						loaded_count += new_chars
						if new_chars > 0:
							print("[TIMING] cell %s characters: %d ms (%d chars)" % [str(cell_grid), Time.get_ticks_msec() - _tc_cell, new_chars])
				else:
					# Hide existing characters
					for child: Node in cell_node.get_children():
						if child.has_meta("is_character") and child is Node3D:
							(child as Node3D).visible = false
							char_count += 1

		if enabled and loaded_count > 0:
			print("[TIMING] total cell character loading: %d ms (%d chars across %d cells)" % [Time.get_ticks_msec() - _tc_cells, loaded_count, loaded_coords.size()])
			_log("[DIAG] Total loaded %d new characters into cells" % loaded_count)
		_log("[DIAG] Toggled visibility for %d characters" % char_count)

	_log("NPCs/Creatures: %s" % ("ON" if enabled else "OFF"))
	_update_stats()


## Setup subsystem toggles for benchmark A/B testing.
## Called from _init_async after all managers are initialized.
func _setup_subsystem_toggles() -> void:
	_subsystem_toggles = SubsystemTogglesScript.new()

	# Shadow toggle needs the sun's RID
	var sun: DirectionalLight3D = _find_sun_light()

	var callbacks: Dictionary = {
		"terrain": func(on: bool) -> void:
			if terrain_3d: terrain_3d.visible = on,
		"ocean": func(on: bool) -> void:
			if _ocean_controls: _ocean_controls.on_show_ocean_toggled(on),
		"sky": func(on: bool) -> void:
			_on_show_sky_toggled(on),
		"weather": func(on: bool) -> void:
			if _weather_controls: _weather_controls.on_weather_toggled(on),
		"characters": func(on: bool) -> void:
			_on_show_characters_toggled(on),
		"impostors": func(on: bool) -> void:
			if native_streaming_manager: native_streaming_manager.set_impostors_visible(on),
		"mid_objects": func(on: bool) -> void:
			if native_streaming_manager: native_streaming_manager.set_mid_tier_visible(on),
		"near_objects": func(on: bool) -> void:
			if native_streaming_manager: native_streaming_manager.set_near_tier_visible(on),
		"hlod": func(on: bool) -> void:
			if native_streaming_manager: native_streaming_manager.set_hlod_visible(on),
		"shadows": func(on: bool) -> void:
			if sun: sun.shadow_enabled = on,
		"postfx": func(on: bool) -> void:
			if _env_controls:
				_env_controls.on_taa_toggled(on)
				_env_controls.on_ssao_toggled(on)
				_env_controls.on_ssil_toggled(on)
				_env_controls.on_glow_toggled(on)
				_env_controls.on_godrays_toggled(on)
				_env_controls.on_native_volumetric_fog_toggled(on),
	}

	var defaults: Dictionary = {
		"terrain": true,
		"ocean": false,
		"sky": true,
		"weather": true,
		"characters": _show_characters,
		"impostors": true,
		"mid_objects": true,
		"near_objects": true,
		"hlod": true,
		"shadows": true,
		"postfx": true,
	}

	_subsystem_toggles.setup(callbacks, defaults)

	# Register console commands
	if console:
		_subsystem_toggles.register_commands(console)

	_log("Subsystem toggles initialized (%d flags)" % _subsystem_toggles.get_flag_names().size())


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




## Apply a quality preset by setting UI state without re-triggering signals,
## then calling each handler once. Prevents cascading signal re-entry.
func _apply_quality_preset(settings: Dictionary) -> void:
	if not _panels:
		return
	# Update UI without signals
	_panels.taa_toggle.set_pressed_no_signal(settings.taa)
	_panels.ssao_toggle.set_pressed_no_signal(settings.ssao)
	_panels.ssil_toggle.set_pressed_no_signal(settings.ssil)
	_panels.glow_toggle.set_pressed_no_signal(settings.glow)
	_panels.depth_fog_toggle.set_pressed_no_signal(settings.depth_fog)
	_panels.native_vfog_toggle.set_pressed_no_signal(settings.vfog)
	_panels.shadow_cascade_toggle.set_pressed_no_signal(settings.shadows)
	_panels.tonemapper_btn.selected = settings.tonemap
	# Apply each setting
	_env_controls.on_taa_toggled(settings.taa)
	_env_controls.on_ssao_toggled(settings.ssao)
	_env_controls.on_ssil_toggled(settings.ssil)
	_env_controls.on_glow_toggled(settings.glow)
	_env_controls.on_depth_fog_toggled(settings.depth_fog)
	_env_controls.on_native_volumetric_fog_toggled(settings.vfog)
	_env_controls.on_shadow_cascades_toggled(settings.shadows)
	_env_controls.on_tonemapper_changed(settings.tonemap)


## Quality preset: Pretty — enables most visual features
func _on_quality_pretty_preset() -> void:
	_apply_quality_preset({taa=true, ssao=true, ssil=false, glow=true, depth_fog=true, vfog=true, shadows=true, tonemap=2})
	_log("Quality preset: Pretty")


## Quality preset: Balanced — TAA + SSAO + Glow only
func _on_quality_balanced_preset() -> void:
	_apply_quality_preset({taa=true, ssao=true, ssil=false, glow=true, depth_fog=false, vfog=false, shadows=false, tonemap=0})
	_log("Quality preset: Balanced")


## Quality preset: Fast — disable all quality features
func _on_quality_fast_preset() -> void:
	_apply_quality_preset({taa=false, ssao=false, ssil=false, glow=false, depth_fog=false, vfog=false, shadows=false, tonemap=0})
	_log("Quality preset: Fast")


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
		# Store as member var to prevent GC — RefCounted bound methods become invalid otherwise
		_lod_debug_commands = LodDebugCommands.new(native_streaming_manager)
		_lod_debug_commands.register_commands(console)

		# Register batch pool debug commands (legacy HUD)
		console.register_command(
			"mid_hud",
			_cmd_toggle_batch_debug,
			"Toggle MID-tier batch pool debug HUD + LOD band rings",
			"debug"
		)

		# Register MID-tier debugger commands (autopilot + census + markers)
		if not _MidTierDebuggerScript:
			_MidTierDebuggerScript = load("res://src/tools/mid_tier_debugger.gd")
		if _MidTierDebuggerScript:
			_MidTierDebuggerScript.register_console_commands(
				console, native_streaming_manager, cell_manager, camera
			)
		else:
			push_warning("WorldExplorer: Failed to load mid_tier_debugger.gd")

		# Register door/portal debug command
		console.register_command(
			"dump_doors",
			_cmd_dump_doors,
			"Dump all door pairs with positions and wall normals (portal alignment debug)",
			"debug"
		)

		# Register animation prebake command
		console.register_command(
			"prebake_anims",
			_cmd_prebake_animations,
			"Prebake character animations (.kf → .animlib) for faster loading",
			"tools"
		)

		console.register_command(
			"hlod_enable",
			_cmd_hlod_enable,
			"Enable runtime HLOD merging (300-1000m cell merge)",
			"streaming"
		)

		console.register_command(
			"hlod_disable",
			_cmd_hlod_disable,
			"Disable runtime HLOD merging",
			"streaming"
		)

		console.register_command(
			"hlod_stats",
			_cmd_hlod_stats,
			"Show runtime HLOD merger stats",
			"streaming"
		)

		# Register streaming benchmark commands
		if not _StreamingBenchmarkScript:
			_StreamingBenchmarkScript = load("res://src/tools/streaming_benchmark.gd")
		if _StreamingBenchmarkScript:
			_StreamingBenchmarkScript.register_console_commands(
				console, native_streaming_manager, cell_manager, camera
			)
		else:
			push_warning("WorldExplorer: Failed to load streaming_benchmark.gd")

		# Phase B-wide refactor: lod_transition_test.gd deleted (tested the old
		# sibling-LOD scheme). Replacement screen-space LOD tuning commands live
		# in lod_debug_commands.gd — `lod_threshold`, `lod_bias`, `lod_stats`.

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


func _cmd_toggle_batch_debug(_args: Dictionary) -> String:
	if _batch_debug_hud:
		_batch_debug_hud.toggle()
		return "Batch debug HUD: %s" % ("ON" if _batch_debug_hud.is_active() else "OFF")
	return "Batch debug HUD not initialized"


func _cmd_dump_doors(_args: Dictionary) -> String:
	if _pocket_manager:
		_pocket_manager.debug_dump_doors()
		return "Door dump printed to log (check streaming category)"
	return "Interior pocket manager not available"


func _cmd_prebake_animations(_args: Dictionary) -> String:
	var prebaker := ModelPrebaker.new()
	prebaker.animation_output_dir = SettingsManager.get_models_path()
	prebaker.skip_existing = false  # Force re-prebake
	var t0 := Time.get_ticks_msec()
	var result := prebaker.bake_all_animations()
	var elapsed := Time.get_ticks_msec() - t0
	return "Prebaked %d animations in %d ms (%d failed)" % [
		result.get("success", 0), elapsed, result.get("failed", 0)]


func _cmd_hlod_enable(_args: Dictionary) -> String:
	if not native_streaming_manager or not native_streaming_manager._hlod_merger:
		return "HLOD merger not initialized"
	native_streaming_manager._hlod_merger.enabled = true
	# Narrow MID to 300m so HLOD covers 300-1000m
	if native_streaming_manager._static_renderer:
		var DU := preload("res://src/core/world/distance_utils.gd")
		native_streaming_manager._static_renderer.visibility_range_end = DU.HLOD_START
	return "HLOD merging ENABLED — MID narrowed to 300m, HLOD covers 300-1000m"


func _cmd_hlod_disable(_args: Dictionary) -> String:
	if not native_streaming_manager or not native_streaming_manager._hlod_merger:
		return "HLOD merger not initialized"
	native_streaming_manager._hlod_merger.enabled = false
	native_streaming_manager._hlod_merger.cleanup()
	# Restore MID to 500m (no HLOD coverage)
	if native_streaming_manager._static_renderer:
		var DU := preload("res://src/core/world/distance_utils.gd")
		native_streaming_manager._static_renderer.visibility_range_end = DU.MID_END
	return "HLOD merging DISABLED — MID restored to 500m"


func _cmd_hlod_stats(_args: Dictionary) -> String:
	if not native_streaming_manager or not native_streaming_manager._hlod_merger:
		return "HLOD merger not initialized"
	var stats: Dictionary = native_streaming_manager._hlod_merger.get_stats()
	return "HLOD: enabled=%s, active=%d, pending=%d, cache=%d entries (%.1f MB), total_merged=%d, skipped_refs=%d" % [
		str(native_streaming_manager._hlod_merger.enabled),
		stats.get("active_cells", 0), stats.get("pending_merges", 0),
		stats.get("cache_entries", 0), stats.get("cache_bytes", 0) / (1024.0 * 1024.0),
		stats.get("total_merges_completed", 0), stats.get("total_refs_skipped", 0)]


## Callback for native streaming manager cell loaded
func _on_native_cell_loaded(grid: Vector2i, object_count: int) -> void:
	_log("Cell loaded: (%d, %d) - %d objects (native)" % [grid.x, grid.y, object_count])
	_update_stats()

	# Register doors from newly loaded cell with pocket manager
	if _pocket_manager:
		var cell: CellRecord = ESMManager.get_exterior_cell(grid.x, grid.y)
		if cell:
			_pocket_manager.register_exterior_cell_doors(cell, grid)


## Callback for native streaming manager cell unloaded
func _on_native_cell_unloaded(grid: Vector2i) -> void:
	_log("Cell unloaded: (%d, %d) (native)" % [grid.x, grid.y])
	_update_stats()

	# Unregister doors from unloaded cell
	if _pocket_manager:
		_pocket_manager.unregister_exterior_cell_doors(grid)


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
		height = CS.get_terrain_height(Vector3(world_x, 0, world_z), terrain_3d)
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
		var state: Dictionary[String, Variant] = {
			"camera_mode_str": "Fly" if _camera_mode == CameraMode.FLY_CAMERA else "Player",
			"view_distance": _current_view_distance,
		}
		_stats_collector.update(state)


# ==================== UI Helpers ====================

## Create the escape menu (hidden by default)
func _create_escape_menu() -> void:
	# Dimmed background overlay
	_escape_menu = ColorRect.new()
	_escape_menu.name = "EscapeMenu"
	_escape_menu.color = Color(0, 0, 0, 0.6)
	_escape_menu.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_escape_menu.visible = false
	_escape_menu.mouse_filter = Control.MOUSE_FILTER_STOP

	# Centered container
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_escape_menu.add_child(center)

	# Panel
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(300, 200)
	center.add_child(panel)

	# VBox with buttons
	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 16)
	panel.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "GODOTWIND"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	vbox.add_child(title)

	# Spacer
	var spacer := Control.new()
	spacer.custom_minimum_size.y = 8
	vbox.add_child(spacer)

	# Seamless transitions toggle
	var seamless_check := CheckBox.new()
	seamless_check.text = "Seamless interior transitions"
	seamless_check.button_pressed = false
	seamless_check.toggled.connect(func(enabled: bool) -> void:
		if _pocket_manager:
			_pocket_manager.seamless_enabled = enabled
			Log.info("streaming", "Interior mode: %s" % ("seamless" if enabled else "classic"))
	)
	vbox.add_child(seamless_check)

	# Resume button
	var resume_btn := Button.new()
	resume_btn.text = "Resume"
	resume_btn.custom_minimum_size.y = 40
	resume_btn.pressed.connect(_toggle_escape_menu)
	vbox.add_child(resume_btn)

	# Quit button
	var quit_btn := Button.new()
	quit_btn.text = "Quit"
	quit_btn.custom_minimum_size.y = 40
	quit_btn.pressed.connect(_do_fast_quit)
	vbox.add_child(quit_btn)

	$UI.add_child(_escape_menu)


## Toggle the escape menu
func _toggle_escape_menu() -> void:
	if not _escape_menu:
		return
	_escape_menu.visible = not _escape_menu.visible
	# Pause mouse capture so cursor is free in menu
	if _escape_menu.visible:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		# Restore mouse capture based on camera mode
		if _camera_mode == CameraMode.FLY_CAMERA:
			# Fly camera captures on right-click, so leave visible
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Auto-prebake character animation libraries if not cached
## First run takes ~28s (KF parsing), subsequent runs skip instantly
func _auto_prebake_animations() -> void:
	var prebaker := ModelPrebaker.new()
	prebaker.animation_output_dir = SettingsManager.get_models_path()

	# Check if the 3 core animation files are already cached
	var cache_dir: String = SettingsManager.get_models_path()
	var kf_files := ["meshes/xbase_anim.kf", "meshes/xbase_anim_female.kf", "meshes/xbase_animkna.kf"]
	var all_cached := true
	for kf: String in kf_files:
		var safe := kf.to_lower().replace("/", "\\").replace("\\", "_").replace(":", "_").replace(".", "_")
		if not FileAccess.file_exists(cache_dir.path_join(safe + ".tres")):
			all_cached = false
			break

	if all_cached:
		_log("Character animations already prebaked — skipping")
		return

	_log("[color=yellow]Prebaking character animations (one-time, ~30s)...[/color]")
	var t0 := Time.get_ticks_msec()
	var result := prebaker.bake_all_animations()
	var elapsed := Time.get_ticks_msec() - t0
	_log("[color=green]Animation prebake complete in %d ms — %d baked, %d skipped, %d failed[/color]" % [
		elapsed, result.get("success", 0), result.get("skipped", 0), result.get("failed", 0)])
	print("[TIMING] animation prebake: %d ms" % elapsed)


func _show_loading(title: String, status: String) -> void:
	loading_overlay.visible = true
	loading_label.text = title
	status_label.text = status
	progress_bar.value = 0
	# Suppress 3D rendering during loading — no active camera = no GPU work
	if camera:
		camera.current = false


func _hide_loading() -> void:
	loading_overlay.visible = false
	# Restore camera rendering
	if camera:
		camera.current = true


func _on_streaming_startup_progress(progress: float, loaded_cells: int, total_cells: int, queued_objects: int) -> void:
	loading_overlay.visible = true
	if progress < 40.0:
		loading_label.text = "Loading World"
		status_label.text = "Cells: %d/%d | Objects queued: %d" % [loaded_cells, total_cells, queued_objects]
	else:
		loading_label.text = "Building Horizon"
		var impostor_pct := int((progress - 40.0) / 60.0 * 100.0)
		status_label.text = "Impostors: %d%% | Cells: %d" % [impostor_pct, loaded_cells]
	progress_bar.value = progress


func _on_streaming_startup_complete() -> void:
	_is_loading = false
	_hide_loading()


func _update_loading(progress: float, status: String) -> void:
	progress_bar.value = progress
	status_label.text = status
	await get_tree().process_frame


## Timing helper: prints elapsed ms since last checkpoint, returns new checkpoint
func _log_timing(prev_ticks: int, label: String) -> int:
	var now := Time.get_ticks_msec()
	var elapsed := now - prev_ticks
	_loading_phase_times[label] = elapsed
	print("[TIMING] %s: %d ms" % [label, elapsed])
	return now


func _log(message: String) -> void:
	if log_text:
		log_text.append_text(message + "\n")
	Log.info("tools", message.replace("[color=green]", "").replace("[color=red]", "").replace("[color=yellow]", "").replace("[/color]", "").replace("[b]", "").replace("[/b]", ""))


# ==================== Input Handling ====================

func _input(event: InputEvent) -> void:
	# Block all input during loading — player shouldn't move/look until ready
	if _is_loading:
		get_viewport().set_input_as_handled()
		return

	# Escape menu takes priority
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and key_event.keycode == KEY_ESCAPE:
			_toggle_escape_menu()
			get_viewport().set_input_as_handled()
			return

	# Don't process shortcuts when escape menu or console is open
	if _escape_menu and _escape_menu.visible:
		return
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
			KEY_E:
				# Fly camera interaction — uses its own raycaster to
				# target NPCs, doors, books, etc. Same interact() call
				# path as PlayerController uses for player mode.
				if _camera_mode == CameraMode.FLY_CAMERA:
					_fly_camera_interact()
			KEY_J:
				# C.7 — Toggle quest journal
				if _journal_panel:
					if _journal_panel.is_open():
						_journal_panel.hide_journal()
					else:
						_journal_panel.show_journal()
			# KEY_TAB removed — interior browser mode is accessible via UI button only
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

	# Update interior pocket manager (door detection, eviction)
	if _pocket_manager:
		_pocket_manager.update(camera.global_position, delta)

	# Update weather rendering
	if _weather_controls:
		_weather_controls.process(delta)

	# Update horizon map sun direction
	if _horizon_map_manager:
		_horizon_map_manager.update_sun_direction()

	# Feed sun elevation to distant light manager for time-of-day visibility
	if native_streaming_manager and _env_controls and _env_controls.sky_manager:
		native_streaming_manager.set_sun_elevation(_env_controls.sky_manager.celestial.sun_altitude)

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


# ==================== Interior Transitions ====================

## Setup interior pocket manager for seamless transitions
func _setup_pocket_manager() -> void:
	_pocket_manager = InteriorPocketManagerScript.new()
	_pocket_manager.name = "InteriorPocketManager"
	add_child(_pocket_manager)

	# Find the WorldEnvironment node in scene tree
	var world_env: WorldEnvironment = null
	for child in get_children():
		if child is WorldEnvironment:
			world_env = child
			break

	# Find the sun (DirectionalLight3D) for interior cull mask management
	var sun: DirectionalLight3D = _find_sun_light()

	_pocket_manager.initialize(cell_manager, world_env, camera, sun)

	# Hide Terrain3D during interior transitions — camera at Y=-500 causes
	# Terrain3D GDExtension to crash (clipmap generation at underground position)
	_pocket_manager.transition_started.connect(_on_interior_transition_started)
	_pocket_manager.transition_completed.connect(_on_interior_transition_completed)

	# Set player body for physics layer swapping during transitions
	if player_controller:
		_pocket_manager.set_player_body(player_controller)

	# Create door prompt label
	_create_door_prompt()

	# Register doors from already-loaded cells
	if world_streaming_manager:
		var loaded: Array[Vector2i] = world_streaming_manager.get_loaded_cell_coordinates()
		for grid: Vector2i in loaded:
			var cell: CellRecord = ESMManager.get_exterior_cell(grid.x, grid.y)
			if cell:
				_pocket_manager.register_exterior_cell_doors(cell, grid)

	# Interaction framework: now that the pocket manager + streaming
	# manager both exist, install the DoorInteractable.door_activated
	# callback on the ReferenceInstantiator via CellManager, and hand
	# the streaming manager reference to the carry controller for I.6
	# persistent-node registration during carry.
	if cell_manager:
		cell_manager.set_door_activated_handler(_on_door_interactable_activated)
	if _carry_controller and world_streaming_manager:
		_carry_controller.set_streaming_manager(world_streaming_manager)

	Log.info("streaming", "Interior pocket manager initialized")


## Find the first DirectionalLight3D in the scene tree (sun/moon light)
func _find_sun_light() -> DirectionalLight3D:
	return _find_directional_light_recursive(get_tree().root)


func _find_directional_light_recursive(node: Node) -> DirectionalLight3D:
	if node is DirectionalLight3D:
		return node as DirectionalLight3D
	for child in node.get_children():
		var result: DirectionalLight3D = _find_directional_light_recursive(child)
		if result:
			return result
	return null


## Create the "Press E to enter" prompt overlay
func _create_door_prompt() -> void:
	_door_prompt_label = Label.new()
	_door_prompt_label.name = "DoorPrompt"
	_door_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_door_prompt_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_door_prompt_label.add_theme_font_size_override("font_size", 20)
	_door_prompt_label.add_theme_color_override("font_color", Color.WHITE)
	_door_prompt_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_door_prompt_label.add_theme_constant_override("shadow_offset_x", 2)
	_door_prompt_label.add_theme_constant_override("shadow_offset_y", 2)
	# Position at bottom-center of screen
	_door_prompt_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_door_prompt_label.offset_top = -80
	_door_prompt_label.offset_bottom = -40
	_door_prompt_label.offset_left = -200
	_door_prompt_label.offset_right = 200
	_door_prompt_label.visible = false
	$UI.add_child(_door_prompt_label)


## Update door prompt visibility based on proximity
func _update_door_prompt() -> void:
	if not _pocket_manager or not _door_prompt_label:
		return

	var door: Variant = _pocket_manager.get_closest_door()
	if door:
		if _pocket_manager.is_inside():
			# Check if door leads out or to another interior
			if not door.target_cell_name.is_empty():
				var dest: CellRecord = ESMManager.get_cell(door.target_cell_name)
				if dest and dest.is_interior():
					_door_prompt_label.text = "Press E to enter %s" % door.target_cell_name
				else:
					_door_prompt_label.text = "Press E to exit"
			else:
				_door_prompt_label.text = "Press E to exit"
		else:
			_door_prompt_label.text = "Press E to enter %s" % door.target_cell_name
		_door_prompt_label.visible = true
	else:
		_door_prompt_label.visible = false


## I.7 main-scene integration (2026-04-09) — DoorInteractable callback.
##
## Fires when a ray-cast DoorInteractable's `interact()` method runs
## (triggered by PlayerController routing `interact_tap` to the
## raycaster's current target). We receive the authoritative record_id
## from the adapter, look up the matching DoorInfo in the pocket
## manager, and hand it to the same enter/exit routing the old
## proximity path used. That keeps fade-to-black, streaming pause,
## seamless transition, interior-to-interior all working unchanged.
##
## Why look up via ref_id instead of the adapter's position: the
## DoorInfo owned by the pocket manager is the single source of truth
## for teleport destinations (DODT data) and building metadata. The
## adapter only carries what the interaction framework needs. Looking
## up by ref_id keeps the adapter lean without duplicating authoritative
## data into it.
func _on_door_interactable_activated(record_id: String, _door_record: Variant, _player: Node3D) -> void:
	if not _pocket_manager:
		return
	var door: Variant = _pocket_manager.get_door_info_by_ref_id(StringName(record_id))
	if door == null:
		Log.warn("streaming", "[DOOR_INTERACT] no DoorInfo for ref_id '%s' — ignoring tap" % record_id)
		return
	_activate_door(door)


## Shared prompt callback for both raycasters (fly + player).
## Shows "[E] Talk to Fargoth (2.3m)" at screen bottom.
func _on_interact_prompt_changed(interactable: Interactable, distance: float) -> void:
	if not _door_prompt_label:
		return
	if interactable == null:
		_door_prompt_label.visible = false
		return
	_door_prompt_label.text = "[E] %s  (%.1fm)" % [interactable.get_prompt_text(), distance]
	_door_prompt_label.visible = true


## Fly camera interaction — reads the fly raycaster's current target
## and calls interact(). Replaces the old proximity-based door activation.
## The fly camera acts as the "player" node for interact() calls.
func _fly_camera_interact() -> void:
	if _fly_raycaster == null:
		return
	# Modal gate — don't interact while a panel is open
	if _dialogue_session and _dialogue_session.is_any_panel_open():
		return
	var target: Interactable = _fly_raycaster.get_current_target()
	if target == null:
		return
	target.interact(fly_camera)


## Activate the nearest door (legacy proximity fallback — kept for
## headless/test scenarios where no raycaster is available).
func _activate_nearest_door() -> void:
	if not _pocket_manager:
		return

	var door: Variant = _pocket_manager.get_closest_door()
	if not door:
		return
	await _activate_door(door)


## Shared door transition routing — used by both the ray-cast
## DoorInteractable path (player mode) and the proximity fallback
## (fly-camera mode). Branches on `_pocket_manager.is_inside()` to
## pick enter / exit / interior-to-interior.
func _activate_door(door: Variant) -> void:
	if not _pocket_manager or door == null:
		return

	Log.info("streaming", "[DOOR_ACTIVATE] Door: '%s' -> '%s', inside=%s" % [
		door.ref_id, door.target_cell_name, _pocket_manager.is_inside()])

	if _pocket_manager.is_inside():
		var dest: CellRecord = ESMManager.get_cell(door.target_cell_name)
		if dest and dest.is_interior():
			await _pocket_manager.transition_interior_to_interior(door)
		else:
			# Exit: teleport back to surface, THEN resume streaming.
			# Streaming was paused since enter — cells are still loaded (frozen).
			await _pocket_manager.exit_to_exterior(door)
			_set_streaming_paused(false)
			_log("[color=cyan]Exited to exterior[/color]")
	else:
		# Pause streaming BEFORE enter so cells don't unload when camera goes to Y=-500.
		# Cells stay frozen in place. Fade-to-black covers the visual transition.
		_set_streaming_paused(true)
		var success: bool = await _pocket_manager.enter_interior(door)
		if success:
			_log("[color=cyan]Entered interior: %s[/color]" % door.target_cell_name)
		else:
			# Failed — resume streaming
			_set_streaming_paused(false)
			Log.error("streaming", "[DOOR_ACTIVATE] enter_interior FAILED for '%s'" % door.target_cell_name)


## Pause/resume the streaming manager and its children (BackgroundProcessor).
## CRITICAL: Must be called before interior transitions. Without this, the streaming
## manager detects the camera at Y=-500 (pocket position), computes a wrong grid cell,
## and unloads ALL exterior cells mid-transition → use-after-free → segfault.
func _set_streaming_paused(paused: bool) -> void:
	if world_streaming_manager:
		world_streaming_manager.set_process(not paused)
		# Also pause children (BackgroundProcessor) to prevent async completions
		# from touching cell data during the transition
		for child in world_streaming_manager.get_children():
			child.set_process(not paused)
	Log.info("streaming", "[STREAMING] Paused=%s" % paused)


## Hide Terrain3D when entering interior — camera at Y=-500 causes
## Terrain3D GDExtension to crash (clipmap generation at underground position).
func _on_interior_transition_started(_cell_name: String) -> void:
	if terrain_3d:
		terrain_3d.visible = false
		Log.info("streaming", "[TRANSITION] Terrain3D hidden (entering interior)")


## Restore Terrain3D when exiting to exterior.
func _on_interior_transition_completed(cell_name: String) -> void:
	if not _pocket_manager or not _pocket_manager.is_inside():
		if terrain_3d:
			terrain_3d.visible = true
			Log.info("streaming", "[TRANSITION] Terrain3D restored (exited to exterior)")


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
