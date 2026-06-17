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
const TerrainManagerScript := preload("res://src/core/world/morrowind/morrowind_terrain_manager.gd")
const MorrowindTerrainTextureLoaderScript := preload("res://src/core/world/morrowind/morrowind_terrain_texture_loader.gd")
const MorrowindTerrainTextureBridgeScript := preload("res://src/core/world/morrowind/morrowind_terrain_texture_bridge.gd")
const CellManagerScript := preload("res://src/core/world/cell_manager.gd")
const MorrowindWorldSourceScript := preload("res://src/core/world/morrowind/morrowind_world_source.gd")
const ObjectPoolScript := preload("res://src/core/world/object_pool.gd")
const CS := preload("res://src/core/coordinate_system.gd")
const PerformanceProfilerScript := preload("res://src/core/world/performance_profiler.gd")
const OceanControlsScript := preload("res://src/tools/ui/ocean_controls.gd")
const EnvironmentControlsScript := preload("res://src/tools/ui/environment_controls.gd")
const WeatherControlsScript := preload("res://src/tools/ui/weather_controls.gd")
const StatsCollectorScript := preload("res://src/tools/ui/stats_collector.gd")
const RiverWaterBodyScript := preload("res://src/core/water/river_water_body.gd")
const PolygonWaterVolumeScript := preload("res://src/core/water/polygon_water_volume.gd")
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
const CarryableRegistryScript := preload("res://src/core/interaction/carryable_registry.gd")
const InventoryServiceScript := preload("res://src/core/interaction/inventory_service.gd")
const MWInventoryServiceScript := preload("res://src/core/interaction/morrowind/mw_inventory_service.gd")
# Interaction framework main-scene integration (2026-04-09).
const InteractionRaycasterScript := preload("res://src/core/interaction/interaction_raycaster.gd")
const CarryControllerScript := preload("res://src/core/interaction/carry_controller.gd")
const DoorInteractableScript := preload("res://src/core/interaction/morrowind/door_interactable.gd")
const DoorUtils := preload("res://src/core/world/door_utils.gd")
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
const BenchmarkHUDScript := preload("res://src/tools/benchmark_hud.gd")
const ProgressiveBenchmarkScript := preload("res://src/tools/progressive_benchmark.gd")
const PerfSweepScript := preload("res://src/tools/perf_sweep.gd")
const AutoBenchRunnerScript := preload("res://src/tools/auto_bench_runner.gd")
const BenchLadderRunnerScript := preload("res://src/tools/bench_ladder_runner.gd")
const StreamingStressRunnerScript := preload("res://src/tools/streaming_stress_runner.gd")
const LoadingStateMachineScript := preload("res://src/core/loading/loading_state_machine.gd")
const LoadingBaselineReportScript := preload("res://src/tools/loading_baseline_report.gd")
const LifetimeProbeReportScript := preload("res://src/tools/lifetime_probe_report.gd")
const WATER_RENDER_PUBLISH_MAX_CELLS_PER_FRAME := 4
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
@warning_ignore("untyped_declaration")
var terrain_manager = null  # Morrowind LAND terrain baking
var texture_loader: RefCounted = null  # MorrowindTerrainTextureLoader
var cell_manager: CellManager = null  # CellManager
var world_source: RefCounted = null
var world_object_source: RefCounted = null
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
var _debug_view_commands: DebugViewCommands = null  # wireframe + collision viz console commands (prevent GC)
var _pocket_manager: Node = null  # InteriorPocketManager
var _door_prompt_label: Label = null  # "Press E to enter" prompt
var _horizon_map_manager: HorizonMapManager = null  # Terrain self-shadowing
var _mw_terrain_texture_bridge: RefCounted = null  # MW LTEX sidecar terrain texturing
var _subsystem_toggles: RefCounted = null  # SubsystemToggles — benchmark A/B feature flags
var _benchmark_hud: CanvasLayer = null  # BenchmarkHUD — live perf overlay, default hidden
var _loading_time_ms: int = 0  # Total loading time (for benchmark harness)
var _world_streaming_disabled: bool = false
var _shutdown_refs_released: bool = false
var _loading_state_machine: LoadingStateMachineScript = null  # Phase 8 — canonical loading gate (boot + teleport)
var _boot_gate_entered: bool = false  # Latches the one-shot boot enter_loading call
var _loading_phase_times: Dictionary = {}  # Per-phase loading times
var _observatory_process_start_msec: int = Time.get_ticks_msec()
var _observatory_ready_msec: int = 0
var _observatory_init_async_start_msec: int = 0
var _observatory_init_async_done_msec: int = 0
var _lifetime_probe_started: bool = false

# State
var _data_path: String = ""
var _initialized: bool = false
var _is_loading: bool = true  # Blocks input until startup complete
var _perf_overlay_visible: bool = true
var _current_view_distance: int = StreamingConfig.DEFAULT_VIEW_DISTANCE_METERS
var _hlod_flyby_mode: bool = false
var _hlod_ui_transition_until_msec: int = 0
var _hlod_ui_last_toggle_msec: int = -100000
const HLOD_UI_COOLDOWN_MSEC := 1500
var _character_assets_preloaded: bool = false  # Deferred until characters first enabled
var _water_render_root: Node3D = null
var _river_render_nodes_by_body_id: Dictionary[StringName, Node3D] = {}
var _river_render_ref_counts: Dictionary[StringName, int] = {}
var _cell_river_body_ids: Dictionary[Vector2i, Array] = {}
var _river_render_publish_queue: Array[Vector2i] = []
var _river_render_publish_queue_set: Dictionary[Vector2i, bool] = {}
var _river_render_publish_last_usec: int = 0
var _river_render_publish_total_usec: int = 0
var _river_render_publish_count: int = 0
var _player_npc_id: String = "fargoth"  # Default player character NPC ID

# Interior cell browser (constructed by CellBrowser)
var _cell_browser: CellBrowser = null


func _runtime_cmdline_args() -> PackedStringArray:
	var args := PackedStringArray()
	args.append_array(OS.get_cmdline_args())
	args.append_array(OS.get_cmdline_user_args())
	return args


func _apply_cmdline_view_distance_override() -> void:
	var runtime_args := _runtime_cmdline_args()
	for i in range(runtime_args.size()):
		var arg := runtime_args[i]
		var value := ""
		if arg == "--view-distance-meters" or arg == "--view-distance":
			if i + 1 < runtime_args.size():
				value = runtime_args[i + 1]
		elif arg.begins_with("--view-distance-meters="):
			value = arg.substr("--view-distance-meters=".length())
		elif arg.begins_with("--view-distance="):
			value = arg.substr("--view-distance=".length())
		if value.is_empty():
			continue
		if not value.is_valid_int():
			Log.warn("streaming", "Ignoring invalid view distance override: %s" % value)
			continue
		_current_view_distance = StreamingConfig.clamp_view_distance_meters(int(value))
		Log.info("streaming", "CLI view distance override: %s" % StreamingConfig.format_view_distance(_current_view_distance))
		return


# Camera mode state
enum CameraMode { FLY_CAMERA, PLAYER_CONTROLLER }
var _camera_mode: CameraMode = CameraMode.FLY_CAMERA
var fly_camera: FlyCamera = null  # FlyCamera instance (with script)
var player_controller: PlayerController = null  # PlayerController instance

# Interaction framework main-scene integration (2026-04-09)
var _interaction_raycaster: InteractionRaycaster = null
var _fly_raycaster: InteractionRaycaster = null  # Separate raycaster for fly camera mode
var _carry_controller: Node = null  # CarryController (no class_name export to avoid preload cycle)
var _fly_carry_controller: Node = null  # CarryController bound to fly_camera (same class, separate instance)

# Fly-camera interact press/release discriminator — mirrors the PlayerController
# pattern so tap vs hold routing works identically in flycam mode. The
# `interact` action is already bound to E in project.godot; we consume press +
# release events when the fly camera is active.
const FLY_INTERACT_HOLD_THRESHOLD_S: float = 0.20
var _fly_interact_press_time_msec: int = -1
var _fly_interact_hold_emitted: bool = false

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
	_request_fast_quit("USER_QUIT — WM_CLOSE_REQUEST received, beginning fast quit")


func _request_fast_quit(reason: String) -> void:
	# Sentinel log marker — lets log readers distinguish a runtime crash
	# from a user/diagnostic quit. Any native fault after this marker is a
	# teardown/finalization failure, not a live streaming traversal failure.
	Log.info("shutdown", reason)

	# Global quitting flag — checked by _exit_tree handlers to bail immediately
	Engine.set_meta("_quitting", true)

	if _ocean_controls:
		_ocean_controls.set_enabled(false)
	_cleanup_water_provider()

	# Stop background worker threads from blocking on WTP handles
	if native_streaming_manager:
		Log.info("shutdown", "WORLD_EXPLORER_FAST_CLEANUP begin")
		native_streaming_manager.set_process(false)
		native_streaming_manager.fast_cleanup()
		Log.info("shutdown", "WORLD_EXPLORER_FAST_CLEANUP done")

	# Disable deformation persistence so shutdown() skips disk I/O
	DeformationConfig.enable_persistence = false
	_release_shutdown_refs()

	Log.info("shutdown", "WORLD_EXPLORER_QUIT call")
	call_deferred("_finish_quit")


func _finish_quit() -> void:
	get_tree().quit()


func _release_shutdown_refs() -> void:
	if _shutdown_refs_released:
		return
	_shutdown_refs_released = true
	CarryableRegistryScript.clear()
	MWCarryableRegistryScript.release_callable_owner()
	InventoryServiceScript.clear_current()
	Log.info("shutdown", "WORLD_EXPLORER_STATIC_REGISTRIES_CLEARED")


func _exit_tree() -> void:
	_cleanup_water_provider()
	if Engine.has_meta("_quitting"):
		_release_shutdown_refs()


func _cleanup_water_provider() -> void:
	if world_source != null and world_source.has_method("get_water_provider"):
		var water_provider: RefCounted = world_source.call("get_water_provider") as RefCounted
		if water_provider != null and water_provider.has_method("drain_async_requests"):
			water_provider.call("drain_async_requests", true)
	if WaterSystem and WaterSystem.has_method("set_world_water_provider"):
		WaterSystem.call("set_world_water_provider", null)


func _ready() -> void:
	_observatory_ready_msec = Time.get_ticks_msec()
	# Intercept window close to do fast cleanup instead of slow tree teardown
	get_tree().set_auto_accept_quit(false)

	# Phase 8 — LoadingStateMachine. Instantiated early so the overlay
	# node exists before _init_async's first await; the actual
	# enter_loading("boot") fires later, once the streaming manager is
	# live and its is_inner_ring_ready predicate is meaningful.
	_loading_state_machine = LoadingStateMachineScript.new()
	_loading_state_machine.name = "LoadingStateMachine"
	add_child(_loading_state_machine)
	_loading_state_machine.loading_finished.connect(_on_loading_finished)

	# Enable wireframe debug-buffer generation BEFORE any mesh loads. The flag
	# affects mesh-creation time only, so toggling `wireframe on` in the
	# console mid-session would otherwise leave pre-existing meshes broken.
	# Cost is the index buffer doubling for affected meshes — fine for a dev
	# tool. Console command lives in DebugViewCommands.
	DebugViewCommands.enable_wireframe_generation()

	_current_view_distance = SettingsManager.get_view_distance_meters()
	_apply_cmdline_view_distance_override()

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
	texture_loader = MorrowindTerrainTextureLoaderScript.new()
	cell_manager = CellManagerScript.new()
	world_source = MorrowindWorldSourceScript.new()
	world_object_source = world_source.get_object_source()
	if world_source.has_method("get_water_provider") and WaterSystem.has_method("set_world_water_provider"):
		var water_provider: RefCounted = world_source.call("get_water_provider") as RefCounted
		if water_provider != null:
			WaterSystem.call("set_world_water_provider", water_provider)
	if cell_manager.has_method("set_world_source"):
		cell_manager.call("set_world_source", world_source)
	else:
		cell_manager.set_world_object_source(world_object_source)
	# NPCs/creatures controlled by _show_characters toggle (default OFF for testing)
	cell_manager.load_npcs = _show_characters
	cell_manager.load_creatures = _show_characters

	# --no-lights: A/B falsification gate for Phase E.3 (light off-thread). When
	# present, ALL light refs are skipped entirely (model + OmniLight3D). Used to
	# validate the hypothesis that light instantiation drives FPS hitches before
	# shipping the off-thread pattern. Remove once E.3 lands and is measured.
	for arg in _runtime_cmdline_args():
		if arg == "--no-lights":
			cell_manager.load_lights = false
			Log.info("streaming", "[--no-lights] light refs disabled — A/B benchmark gate (Phase E.3 falsification)")
			break

	for arg in _runtime_cmdline_args():
		if arg == "--disable-world-streaming":
			_world_streaming_disabled = true
			Log.info("streaming", "[--disable-world-streaming] camera tracking/cell streaming disabled for shutdown control")
			break

	# Phase 0 ablation flags — isolate Jolt-broadphase + bespoke-fade cost from
	# streaming pipeline. Consumers live in reference_instantiator.gd. Always
	# default to false; command-line only. Remove once Phase 0 data is captured.
	for arg in _runtime_cmdline_args():
		if arg == "--disable-jolt-attach":
			StreamingConfig.DEBUG_DISABLE_JOLT_ATTACH = true
			Log.info("streaming", "[--disable-jolt-attach] per-object Jolt body attach disabled — Phase 0 ablation")
		elif arg == "--disable-fade-pool":
			StreamingConfig.DEBUG_DISABLE_FADE_POOL = true
			Log.info("streaming", "[--disable-fade-pool] bespoke fade-material pool disabled — Phase 0 ablation (engine FADE_SELF still active)")
		elif arg == "--disable-cell-static-collision":
			StreamingConfig.DEBUG_DISABLE_CELL_STATIC_COLLISION = true
			Log.info("streaming", "[--disable-cell-static-collision] per-cell static collision BVH publish disabled - NEAR streaming ablation")

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
	_apply_mesh_lod_threshold()
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
	_observatory_init_async_start_msec = _ta0
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
	if not cell_manager.is_model_loader_runtime_mode():
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
		# Push wet map uniforms (sea_level from WaterSystem or project settings)
		var sea_lvl: float = ProjectSettings.get_setting("ocean/sea_level", 0.0)
		_horizon_map_manager.push_wet_map(sea_lvl)
		_init_mw_terrain_textures()
	_ta = _log_timing(_ta, "horizon maps")

	# Ocean system is now lazy-loaded - created on first toggle

	# Pre-warm model cache with common models (improves first-cell loading)
	await _update_loading(80, "Pre-loading common models...")
	var indexed_models: int = cell_manager.prewarm_model_cache_index()
	_log("Indexed %d prebaked model cache files" % indexed_models)
	var preload_count := cell_manager.preload_common_models()
	_log("Pre-loaded %d common models into cache" % preload_count)
	_ta = _log_timing(_ta, "preload common models")

	# Auto-prebake character animations if not cached (one-time ~28s, then <1s on future launches)
	await _update_loading(85, "Checking character animations...")
	_auto_prebake_animations()
	_ta = _log_timing(_ta, "animation prebake check")

	# Character asset preloading deferred until characters are first enabled
	# CharacterFactoryV2Script.preload_character_assets() called in _on_show_characters_toggled()
	var _start_cell := _get_start_cell_arg()

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
	_observatory_init_async_done_msec = Time.get_ticks_msec()
	print("[TIMING] _init_async() total: %d ms" % _loading_time_ms)
	_log("[color=green]World streaming initialized![/color]")
	_log("Loading time: %d ms" % _loading_time_ms)
	_log("Use ZQSD to move, Right-click to look")
	_log("Cells stream automatically based on camera position")

	# Sync sky state with toggle to ensure consistent initial state
	# This ensures the sky visibility matches what the toggle shows
	_env_controls.sync_sky_state()

	# First teleport camera to Seyda Neen BEFORE starting to track.
	# --start-cell=X,Y overrides (Phase 0 ablation; booting at Balmora avoids
	# the mid-session teleport that triggers tracker §12.2 crash).
	_teleport_to_cell(_start_cell.x, _start_cell.y)

	# Setup subsystem toggles (needs all managers initialized)
	_setup_subsystem_toggles()

	# NOW start tracking the camera - cells will generate around Seyda Neen.
	# Apply subsystem CLI isolation before this call so `--near-only` /
	# `--near-mid-only` cannot pay one startup scan for disabled distant paths.
	if _world_streaming_disabled:
		Log.info("streaming", "[--disable-world-streaming] skipping NativeStreamingManager.set_camera()")
	else:
		world_streaming_manager.set_camera(camera)

	# Update debug overlay with references to managers
	_update_debug_overlay_references()

	# Connect diagnostic systems now that WSM is ready
	_connect_diagnostic_systems()

	# Phase 8 — boot gate + teleport hook re-enabled 2026-04-17 after
	# pass-3 diagnostic launch (Phase 8 disabled) reproduced the same
	# sig11 at model_loader.gd:595. Phase 8 is architecturally innocent;
	# the crash is the pre-existing packed_scene.instantiate() race
	# flagged in STATUS.md ("crashes periodically"). Root-cause fix is
	# a separate session. pause_gameplay stays false in _enter_boot_
	# loading_gate / _on_teleport_happened until that lands.
	_enter_boot_loading_gate()
	if native_streaming_manager.has_signal("teleport_happened"):
		native_streaming_manager.teleport_happened.connect(_on_teleport_happened)

	# Autonomous performance audit — wire AutoBenchRunner when invoked with
	# `--bench-auto [stamp]` on the command line. Runs scenarios C-F from
	# docs/audit/AUTONOMOUS_PERF_AUDIT_HANDOFF_2026_04_17.md once streaming has
	# settled, then calls get_tree().quit() on completion. No-op when the flag
	# is absent.
	_maybe_start_auto_bench()

	# Subsystem-isolation ladder — parallel CLI orchestrator for
	# `--bench-ladder [stamp]`. Progressive-additive sweep across the 11
	# SubsystemToggles flags at Seyda Neen, one JSON per run. No-op when
	# the flag is absent. See docs/audit/DISTANT_RENDERING_PLAN_2026_04_17.md
	# §Rung 0 of the 2026-04-18 salvage pass.
	_maybe_start_bench_ladder()

	_maybe_start_perf_sweep()

	# High-altitude sustained traversal stress test. This is separate from the
	# canonical AutoBench because it answers transition stutter directly.
	_maybe_start_stress_bench()
	if not _maybe_start_interior_door_smoke():
		_maybe_start_ready_quit()


func _get_start_cell_arg() -> Vector2i:
	var start_cell := Vector2i(-2, -9)
	for arg in _runtime_cmdline_args():
		if arg.begins_with("--start-cell="):
			var parts := arg.substr("--start-cell=".length()).split(",")
			if parts.size() == 2:
				start_cell = Vector2i(int(parts[0]), int(parts[1]))
				Log.info("streaming", "[--start-cell] booting at cell (%d, %d)" % [start_cell.x, start_cell.y])
	return start_cell


## Phase 8 — Cold-boot handoff into LoadingStateMachine. Called once
## streaming is live + camera is tracking. Idempotent via _boot_gate_entered.
func _enter_boot_loading_gate() -> void:
	if _boot_gate_entered:
		return
	if not _loading_state_machine or not native_streaming_manager:
		return
	_boot_gate_entered = true
	var predicate := Callable(native_streaming_manager, "is_inner_ring_ready")
	var progress_fn := Callable(self, "_format_boot_progress")
	# pause_gameplay=false for the 2026-04-17 first-runtime pass — the
	# tree.paused=true path triggers an intermittent sig11 inside
	# model_loader.gd:595 (PackedScene.instantiate during pause). Root-
	# cause fix is its own phase; overlay-only gate still achieves the
	# "hide the cold-start churn" UX win.
	_loading_state_machine.enter_loading(
		"boot",
		predicate,
		"Loading Morrowind",
		"Streaming cells around Seyda Neen…",
		progress_fn,
		30.0,
		true,   # fade_in
		false,  # pause_gameplay — OFF pending model_loader pause-safety fix
	)


## Consumed by LoadingStateMachine as the overlay's third-line progress
## label. Formats the inner-ring status dict into a single short string.
func _format_boot_progress() -> String:
	if not native_streaming_manager or not native_streaming_manager.has_method("get_inner_ring_status"):
		return ""
	var s: Dictionary = native_streaming_manager.get_inner_ring_status()
	return "cells %d/%d · async %d · queue %d/%d" % [
		int(s.get("ring_loaded", 0)),
		int(s.get("ring_total", 0)),
		int(s.get("ring_pending_async", 0)),
		int(s.get("instantiation_queue", 0)),
		int(s.get("first_playable_queue_cap", 0)),
	]


## Phase 8 — signal handler. LoadingStateMachine emits loading_finished
## when the predicate returns true OR the 30s timeout fires. We log it
## here; `duration_s` becomes the canonical "time-to-playable" number
## going forward, replacing the misleading `startup_complete` frame-count
## metric that currently drops too early.
func _on_loading_finished(reason: String, duration_s: float, timed_out: bool) -> void:
	var suffix := " (TIMEOUT)" if timed_out else ""
	_log("[color=green]LoadingState '%s' complete in %.1fs%s[/color]" % [reason, duration_s, suffix])
	if reason == "boot" and not timed_out and native_streaming_manager and native_streaming_manager.has_method("mark_first_playable"):
		native_streaming_manager.call("mark_first_playable", "boot_ready")
	if reason == "boot":
		var status: Dictionary = {}
		if native_streaming_manager and native_streaming_manager.has_method("get_inner_ring_status"):
			status = native_streaming_manager.get_inner_ring_status()
		var cm_stats: Dictionary = {}
		if cell_manager and cell_manager.has_method("get_loading_stats"):
			cm_stats = cell_manager.get_loading_stats()
		Log.info("loading", "[LOADING_PHASES] phases=%s inner=%s cell_manager=%s" % [
			JSON.stringify(_loading_phase_times),
			JSON.stringify(status),
			JSON.stringify(cm_stats),
		])
		_write_loading_baseline_report(reason, duration_s, timed_out, status, cm_stats)
		if not timed_out:
			_maybe_start_lifetime_probe()


func _write_loading_baseline_report(
	reason: String,
	duration_s: float,
	timed_out: bool,
	inner_status: Dictionary,
	cell_manager_stats: Dictionary
) -> void:
	var args := _get_loading_baseline_report_args()
	var streaming_stats: Dictionary = {}
	if native_streaming_manager and native_streaming_manager.has_method("get_stats"):
		streaming_stats = native_streaming_manager.call("get_stats")
	var path: String = LoadingBaselineReportScript.write({
		"scenario": args.get("scenario", "first_playable"),
		"cache_state": args.get("cache_state", "unspecified"),
		"reason": reason,
		"duration_s": duration_s,
		"timed_out": timed_out,
		"timestamps": {
			"process_start_msec": _observatory_process_start_msec,
			"ready_msec": _observatory_ready_msec,
			"init_async_start_msec": _observatory_init_async_start_msec,
			"init_async_done_msec": _observatory_init_async_done_msec,
			"first_playable_msec": Time.get_ticks_msec(),
		},
		"phase_times_ms": _loading_phase_times,
		"inner_ring": inner_status,
		"cell_manager": cell_manager_stats,
		"streaming": streaming_stats,
		"benchmark_mode_metadata": streaming_stats.get("benchmark_mode_metadata", {}),
	})
	if path.is_empty():
		Log.error("loading", "[LOADING_BASELINE] failed to write loading baseline report")
	else:
		Log.info("loading", "[LOADING_BASELINE] wrote %s" % path)


func _get_loading_baseline_report_args() -> Dictionary:
	var scenario := "first_playable"
	var cache_state := "unspecified"
	for arg in _runtime_cmdline_args():
		if arg.begins_with("--loading-baseline="):
			scenario = LoadingBaselineReportScript.normalize_scenario(arg.substr("--loading-baseline=".length()))
			if scenario == "cold_start":
				cache_state = "cold"
			elif scenario == "warm_start":
				cache_state = "warm"
		elif arg.begins_with("--loading-cache-state="):
			cache_state = arg.substr("--loading-cache-state=".length()).strip_edges().to_lower()
	return {
		"scenario": scenario,
		"cache_state": cache_state,
	}


## Phase 8 — teleport trigger. NativeStreamingManager emits
## `teleport_happened` when the camera jumps > 500 m between two frames;
## we enter LoadingStateMachine with fade_in=true so the warp itself is
## hidden behind the fade-to-black. The `autobench` run doesn't want
## this gate because it's measuring raw teleport recovery — so skip
## when `--bench-auto` was on the command line.
func _on_teleport_happened(_from_pos: Vector3, _to_pos: Vector3, distance: float) -> void:
	if not _loading_state_machine:
		return
	if native_streaming_manager and native_streaming_manager.has_method("is_in_startup_phase") \
			and bool(native_streaming_manager.call("is_in_startup_phase")):
		Log.info("loading", "[LOADING] ignoring startup teleport gate distance=%.1fm" % distance)
		return
	# Autobench opt-out — preserves the measurement contract in the
	# perf-audit runs (we want to see the raw teleport-burst FPS trace,
	# not 30 s of gated black screen).
	for a in _runtime_cmdline_args():
		if a == "--bench-auto" or a.begins_with("--bench-auto="):
			return
	var predicate := Callable(native_streaming_manager, "is_inner_ring_ready")
	var progress_fn := Callable(self, "_format_boot_progress")
	_loading_state_machine.enter_loading(
		"teleport",
		predicate,
		"Traveling…",
		"Streaming new area (%.0f m jump)" % distance,
		progress_fn,
		30.0,
		true,   # fade_in — masks the warp
		false,  # pause_gameplay — see boot-gate comment above
	)


## Parse _runtime_cmdline_args() for --bench-auto [stamp] and instantiate the
## AutoBenchRunner when present. Accepts both `--bench-auto` (next arg is the
## timestamp) and `--bench-auto=<stamp>` forms. Only attaches when we have a
## streaming manager + camera + cell manager (all post-_setup_subsystem_toggles).
func _maybe_start_auto_bench() -> void:
	var args := _runtime_cmdline_args()
	var stamp := ""
	var flag_found := false
	for i in range(args.size()):
		var a: String = args[i]
		if a == "--bench-auto":
			flag_found = true
			if i + 1 < args.size() and not args[i + 1].begins_with("--"):
				stamp = args[i + 1]
			break
		if a.begins_with("--bench-auto="):
			flag_found = true
			stamp = a.substr("--bench-auto=".length())
			break
	if not flag_found:
		return
	if not native_streaming_manager or not cell_manager or not camera:
		push_warning("[AUTOBENCH] --bench-auto flag set but required refs missing — skipping")
		return
	var runner := AutoBenchRunnerScript.new()
	runner.name = "AutoBenchRunner"
	get_tree().root.add_child(runner)
	runner.configure(native_streaming_manager, cell_manager, camera, self, stamp)
	_log("[AUTOBENCH] started with stamp: %s" % (stamp if not stamp.is_empty() else "<auto>"))


## Parse _runtime_cmdline_args() for --bench-ladder [stamp] and instantiate the
## BenchLadderRunner when present. Mirrors _maybe_start_auto_bench but targets
## the progressive-additive subsystem-isolation ladder. No-op when absent.
func _maybe_start_bench_ladder() -> void:
	var args := _runtime_cmdline_args()
	var stamp := ""
	var flag_found := false
	for i in range(args.size()):
		var a: String = args[i]
		if a == "--bench-ladder":
			flag_found = true
			if i + 1 < args.size() and not args[i + 1].begins_with("--"):
				stamp = args[i + 1]
			break
		if a.begins_with("--bench-ladder="):
			flag_found = true
			stamp = a.substr("--bench-ladder=".length())
			break
	if not flag_found:
		return
	if not native_streaming_manager or not cell_manager or not camera or not _subsystem_toggles:
		push_warning("[LADDER] --bench-ladder flag set but required refs missing — skipping")
		return
	var runner := BenchLadderRunnerScript.new()
	runner.name = "BenchLadderRunner"
	get_tree().root.add_child(runner)
	runner.configure(
		native_streaming_manager, cell_manager, camera, self, _subsystem_toggles, stamp
	)
	_log("[LADDER] started with stamp: %s" % (stamp if not stamp.is_empty() else "<auto>"))


func _maybe_start_perf_sweep() -> void:
	var args := _runtime_cmdline_args()
	var stamp := ""
	var flag_found := false
	for i in range(args.size()):
		var a: String = args[i]
		if a == "--perf-sweep":
			flag_found = true
			if i + 1 < args.size() and not args[i + 1].begins_with("--"):
				stamp = args[i + 1]
			break
		if a.begins_with("--perf-sweep="):
			flag_found = true
			stamp = a.substr("--perf-sweep=".length())
			break
	if not flag_found:
		return
	if not native_streaming_manager or not _subsystem_toggles:
		push_warning("[PERF_SWEEP] --perf-sweep flag set but required refs missing - skipping")
		return
	var runner := PerfSweepScript.new()
	runner.name = "PerfSweepCli"
	get_tree().root.add_child(runner)
	runner.init(
		_subsystem_toggles,
		console,
		native_streaming_manager,
		stamp,
		true,
	)
	_log("[PERF_SWEEP] started with stamp: %s" % (stamp if not stamp.is_empty() else "<auto>"))


func _maybe_start_stress_bench() -> void:
	var args := _runtime_cmdline_args()
	var stamp := ""
	var flag_found := false
	var altitude := 100.0
	var speed := 100.0
	var duration := 60.0
	var direction := "dense-loop"
	var limbo_hold_frames := 0
	var destructive_hold_frames := 0
	for i in range(args.size()):
		var a: String = args[i]
		if a == "--bench-stress":
			flag_found = true
			if i + 1 < args.size() and not args[i + 1].begins_with("--"):
				stamp = args[i + 1]
		elif a.begins_with("--bench-stress="):
			flag_found = true
			stamp = a.substr("--bench-stress=".length())
		elif a.begins_with("--stress-altitude="):
			altitude = float(a.substr("--stress-altitude=".length()))
		elif a.begins_with("--stress-speed="):
			speed = float(a.substr("--stress-speed=".length()))
		elif a.begins_with("--stress-duration="):
			duration = float(a.substr("--stress-duration=".length()))
		elif a.begins_with("--stress-direction="):
			direction = a.substr("--stress-direction=".length())
		elif a.begins_with("--stress-route="):
			direction = a.substr("--stress-route=".length())
		elif a.begins_with("--stress-limbo-hold-frames="):
			limbo_hold_frames = maxi(0, int(a.substr("--stress-limbo-hold-frames=".length())))
		elif a.begins_with("--stress-destructive-hold-frames="):
			destructive_hold_frames = maxi(0, int(a.substr("--stress-destructive-hold-frames=".length())))
	if not flag_found:
		return
	if not native_streaming_manager or not cell_manager or not camera:
		push_warning("[STRESS] --bench-stress flag set but required refs missing - skipping")
		return
	if limbo_hold_frames > 0 and native_streaming_manager != null:
		native_streaming_manager.debug_unload_limbo_hold_frames = limbo_hold_frames
		if native_streaming_manager.has_method("set_lifecycle_capture_enabled"):
			native_streaming_manager.set_lifecycle_capture_enabled(true)
		if cell_manager != null and cell_manager.has_method("set_lifecycle_capture_enabled"):
			cell_manager.set_lifecycle_capture_enabled(true)
		Log.info("streaming", "[STRESS] unload limbo hold frames=%d" % limbo_hold_frames)
	if destructive_hold_frames > 0 and native_streaming_manager != null:
		native_streaming_manager.debug_unload_destructive_hold_frames = destructive_hold_frames
		if native_streaming_manager.has_method("set_lifecycle_capture_enabled"):
			native_streaming_manager.set_lifecycle_capture_enabled(true)
		Log.info("streaming", "[STRESS] unload destructive hold frames=%d (verification-only — keeps grids in limbo so reclaim can attempt)" % destructive_hold_frames)
	var runner := StreamingStressRunnerScript.new()
	runner.name = "StreamingStressRunner"
	get_tree().root.add_child(runner)
	runner.configure(
		native_streaming_manager,
		cell_manager,
		camera,
		stamp,
		_get_start_cell_arg(),
		altitude,
		speed,
		duration,
		direction,
		limbo_hold_frames,
		destructive_hold_frames
	)
	_log("[STRESS] started with stamp: %s" % (stamp if not stamp.is_empty() else "<auto>"))


func _maybe_start_ready_quit() -> void:
	if _has_lifetime_probe_arg():
		return
	var delay := -1.0
	for arg in _runtime_cmdline_args():
		if arg == "--quit-after-ready":
			delay = 1.0
		elif arg.begins_with("--quit-after-ready="):
			delay = maxf(0.1, float(arg.substr("--quit-after-ready=".length())))
	if delay < 0.0:
		return
	Log.info("shutdown", "[--quit-after-ready] quitting in %.1fs" % delay)
	get_tree().create_timer(delay).timeout.connect(func() -> void:
		_request_fast_quit("READY_QUIT - diagnostic ready quit")
	)


func _has_lifetime_probe_arg() -> bool:
	for arg in _runtime_cmdline_args():
		if arg == "--lifetime-probe" or arg.begins_with("--lifetime-probe="):
			return true
	return false


func _get_lifetime_probe_args() -> Dictionary:
	var loops := 3
	var settle_s := 4.0
	var stamp := ""
	for arg in _runtime_cmdline_args():
		if arg.begins_with("--lifetime-probe-loops="):
			loops = max(1, int(arg.substr("--lifetime-probe-loops=".length())))
		elif arg.begins_with("--lifetime-probe-settle="):
			settle_s = maxf(0.5, float(arg.substr("--lifetime-probe-settle=".length())))
		elif arg.begins_with("--lifetime-probe-stamp="):
			stamp = arg.substr("--lifetime-probe-stamp=".length()).validate_filename()
	return {
		"loops": loops,
		"settle_s": settle_s,
		"stamp": stamp,
	}


func _maybe_start_lifetime_probe() -> void:
	if _lifetime_probe_started or not _has_lifetime_probe_arg():
		return
	_lifetime_probe_started = true
	call_deferred("_run_lifetime_probe")


func _run_lifetime_probe() -> void:
	var args := _get_lifetime_probe_args()
	var loops := int(args["loops"])
	var settle_s := float(args["settle_s"])
	var samples: Array = []
	var route: Array[Vector2i] = [
		Vector2i(-2, -9),
		Vector2i(-3, -2),
		Vector2i(5, -6),
		Vector2i(0, 0),
	]
	Log.info("tools", "[LIFETIME_PROBE] starting teleport_loop loops=%d settle=%.1fs" % [loops, settle_s])
	samples.append(LifetimeProbeReportScript.sample("baseline", 0, _lifetime_probe_context(Vector2i(-2, -9))))
	for i in range(loops):
		var grid := route[(i + 1) % route.size()]
		_teleport_to_cell(grid.x, grid.y)
		await _wait_for_lifetime_probe_settle(settle_s)
		samples.append(LifetimeProbeReportScript.sample("after_teleport_%d" % [i + 1], i + 1, _lifetime_probe_context(grid)))
	var path: String = LifetimeProbeReportScript.write({
		"scenario": "fast_travel_streaming",
		"probe_kind": "teleport_loop",
		"loop_count": loops,
		"samples": samples,
		"benchmark_mode_metadata": _get_benchmark_mode_metadata_for_probe(),
	}, "user://benchmark_results", str(args["stamp"]))
	if path.is_empty():
		Log.error("tools", "[LIFETIME_PROBE] failed to write report")
	else:
		Log.info("tools", "[LIFETIME_PROBE] wrote %s" % path)
	_request_fast_quit("LIFETIME_PROBE_DONE")


func _wait_for_lifetime_probe_settle(settle_s: float) -> void:
	var deadline_ms := Time.get_ticks_msec() + int(settle_s * 1000.0)
	while Time.get_ticks_msec() < deadline_ms:
		await get_tree().process_frame
		if native_streaming_manager and native_streaming_manager.has_method("is_inner_ring_ready"):
			if bool(native_streaming_manager.call("is_inner_ring_ready")):
				break
	await get_tree().create_timer(settle_s).timeout


func _lifetime_probe_context(grid: Vector2i) -> Dictionary:
	var streaming_stats: Dictionary = {}
	var inner_ring: Dictionary = {}
	var cell_stats: Dictionary = {}
	if native_streaming_manager and native_streaming_manager.has_method("get_stats"):
		streaming_stats = native_streaming_manager.call("get_stats")
	if native_streaming_manager and native_streaming_manager.has_method("get_inner_ring_status"):
		inner_ring = native_streaming_manager.call("get_inner_ring_status")
	if cell_manager and cell_manager.has_method("get_loading_stats"):
		cell_stats = cell_manager.call("get_loading_stats")
	return {
		"target_cell": grid,
		"streaming": streaming_stats,
		"inner_ring": inner_ring,
		"cell_manager": cell_stats,
	}


func _get_benchmark_mode_metadata_for_probe() -> Dictionary:
	if native_streaming_manager and native_streaming_manager.has_method("get_benchmark_mode_metadata"):
		return native_streaming_manager.call("get_benchmark_mode_metadata")
	var stats: Dictionary = {}
	if native_streaming_manager and native_streaming_manager.has_method("get_stats"):
		stats = native_streaming_manager.call("get_stats")
	return stats.get("benchmark_mode_metadata", {})


func _maybe_start_interior_door_smoke() -> bool:
	var args := _runtime_cmdline_args()
	if not args.has("--interior-door-smoke"):
		return false
	var rush := args.has("--interior-door-smoke-rush")
	Log.info("testing", "[INTERIOR_DOOR_SMOKE] starting rush=%s" % rush)
	call_deferred("_run_interior_door_smoke", rush)
	return true


func _run_interior_door_smoke(rush: bool) -> void:
	var deadline_ms := Time.get_ticks_msec() + 45000
	var prefer_ordinary_deadline_ms := Time.get_ticks_msec() + 15000
	var door: Variant = null
	while Time.get_ticks_msec() < deadline_ms:
		if _pocket_manager:
			var fallback_door: Variant = null
			var chargen_fallback: Variant = null
			for candidate: Variant in _pocket_manager._exterior_doors:
				if candidate == null or str(candidate.target_cell_name).is_empty():
					continue
				var dest: CellRecord = ESMManager.get_cell(candidate.target_cell_name)
				if dest and dest.is_interior():
					if fallback_door == null and str(candidate.target_cell_name) != "Imperial Prison Ship":
						fallback_door = candidate
					if chargen_fallback == null:
						chargen_fallback = candidate
					if str(candidate.target_cell_name).begins_with("Seyda Neen,"):
						door = candidate
						break
			if door == null:
				door = fallback_door
			if door == null and Time.get_ticks_msec() >= prefer_ordinary_deadline_ms:
				door = chargen_fallback
		if door != null:
			break
		await get_tree().process_frame

	if door == null:
		Log.error("testing", "[INTERIOR_DOOR_SMOKE] no registered exterior travel door")
		get_tree().quit(1)
		return

	if camera:
		camera.global_position = door.world_position + Vector3(0.0, 1.6, 1.5)
		camera.look_at(door.world_position + Vector3(0.0, 1.0, 0.0), Vector3.UP)
	if cell_manager:
		cell_manager.set_camera_position(door.world_position)

	if not rush:
		var preload_deadline_ms := Time.get_ticks_msec() + 15000
		while Time.get_ticks_msec() < preload_deadline_ms:
			var slot: Variant = _pocket_manager._get_slot_for_cell_any(door.target_cell_name)
			if slot != null and slot.is_occupied:
				break
			await get_tree().process_frame

	var door_node: Node3D = null
	var interactable_deadline_ms := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < interactable_deadline_ms:
		door_node = DoorUtils.find_by_ref_id(self, door.ref_id, door.world_position, 10.0, door.ref_num)
		if door_node != null and door_node.has_method("interact") \
				and str(door_node.get("door_instance_key")) == str(door.instance_key):
			break
		await get_tree().process_frame
	if door_node == null or not door_node.has_method("interact") \
			or str(door_node.get("door_instance_key")) != str(door.instance_key):
		Log.error("testing", "[INTERIOR_DOOR_SMOKE] DoorInteractable not found for key=%s" % door.instance_key)
		get_tree().quit(1)
		return
	Log.info("testing", "[INTERIOR_DOOR_SMOKE] activating DoorInteractable key=%s" % door.instance_key)
	door_node.call("interact", camera)

	var entered: bool = await _wait_for_interior_smoke_state(true, door.target_cell_name, 45000)
	if not entered:
		Log.error("testing", "[INTERIOR_DOOR_SMOKE] failed to enter '%s'" % door.target_cell_name)
		get_tree().quit(1)
		return

	var active_slot: Variant = _pocket_manager._active_pocket
	var exit_door: Variant = null
	for candidate: Variant in active_slot.doors_inside:
		var target_name := str(candidate.target_cell_name)
		var dest: CellRecord = ESMManager.get_cell(target_name) if not target_name.is_empty() else null
		if target_name.is_empty() or dest == null or not dest.is_interior():
			exit_door = candidate
			break

	if exit_door == null:
		Log.error("testing", "[INTERIOR_DOOR_SMOKE] no exterior exit door in '%s'" % active_slot.cell_name)
		get_tree().quit(1)
		return

	Log.info("testing", "[INTERIOR_DOOR_SMOKE] exiting through key=%s" % exit_door.instance_key)
	await _activate_door(exit_door)
	var exited: bool = await _wait_for_interior_smoke_state(false, "", 45000)
	if not exited:
		Log.error("testing", "[INTERIOR_DOOR_SMOKE] failed to return to exterior")
		get_tree().quit(1)
		return

	if world_streaming_manager and world_streaming_manager.has_method("is_world_tracking_frozen"):
		if bool(world_streaming_manager.call("is_world_tracking_frozen")):
			Log.error("testing", "[INTERIOR_DOOR_SMOKE] world tracking still frozen after exit")
			get_tree().quit(1)
			return

	Log.info("testing", "[INTERIOR_DOOR_SMOKE] PASS exterior->interior->exterior")
	get_tree().quit(0)


func _wait_for_interior_smoke_state(inside: bool, cell_name: String, timeout_ms: int) -> bool:
	var deadline_ms := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline_ms:
		if _pocket_manager and _pocket_manager.is_inside() == inside:
			if not inside or cell_name.is_empty() or _pocket_manager.get_active_interior_name() == cell_name:
				return true
		await get_tree().process_frame
	return false


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

	# Enable terrain collision — DYNAMIC_GAME mode builds a tiled StaticBody3D
	# around the camera at runtime, freeing tiles as the camera moves. Matches
	# UE5 Landscape / Unity Terrain "dynamic chunked collision" pattern.
	# collision_mode: 0=Disabled, 1=Dynamic_Game, 2=Dynamic_Editor, 3=Full_Game, 4=Full_Editor.
	terrain_3d.set("collision_mode", 1)  # Dynamic_Game
	terrain_3d.set("collision_shape_size", 16)  # 16m chunks
	terrain_3d.set("collision_radius", 64)  # 64 chunks radius (~1km dynamic collision ring)
	terrain_3d.set("collision_layer", 1)
	terrain_3d.set("collision_mask", 1)
	# CRITICAL (fix 2026-04-20): Terrain3D v1.0.1 does NOT build collision
	# shapes automatically — `set_camera()` + `collision.build()` are required
	# by the API contract. Without them, Dynamic_Game mode silently does
	# nothing: no StaticBody, no shapes, raycasts hit nothing. See
	# https://raw.githubusercontent.com/TokisanGames/Terrain3D/v1.0.1/doc/api/class_terrain3dcollision.rst
	if camera != null:
		terrain_3d.set_camera(camera)
	var terrain_collision: Object = terrain_3d.get("collision")
	if terrain_collision and terrain_collision.has_method("build"):
		terrain_collision.call("build")
		Log.info("tools", "Terrain3D collision.build() called")
	else:
		push_warning("Terrain3D.collision object missing or has no build() — collision will not work")
	var dbg_mode: Variant = terrain_3d.get("collision_mode")
	var dbg_layer: Variant = terrain_3d.get("collision_layer")
	Log.info("tools", "Terrain3D collision: mode=%s layer=%s shape_size=%d radius=%d camera=%s" % [
		str(dbg_mode), str(dbg_layer), 16, 64, camera.name if camera else "null"])

	if texture_loader.call("load_default_terrain_texture", terrain_3d.assets):
		_log("Terrain textures: Terrain3D default slot installed; MW LTEX sidecar array enabled")
	else:
		_log("[color=yellow]Warning: Failed to install Terrain3D default terrain texture[/color]")

	_log("Terrain3D configured: region_size=%d, vertex_spacing=%.3f" % [CS.TERRAIN_REGION_SIZE, terrain_3d.get_vertex_spacing()])


func _init_mw_terrain_textures() -> void:
	if not terrain_3d or not terrain_3d.material:
		return
	_mw_terrain_texture_bridge = MorrowindTerrainTextureBridgeScript.new()
	var err: Error = _mw_terrain_texture_bridge.call("initialize", terrain_3d)
	if err != OK:
		Log.warn("textures", "MW terrain texture bridge failed to initialize: %s" % error_string(err))
		return
	_mw_terrain_texture_bridge.call("rebuild_all_active_regions")
	_log("MW terrain textures: %d array layers" % int(_mw_terrain_texture_bridge.call("get_texture_array_layer_count")))


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
		_fly_raycaster.debug_log = true
		fly_camera.add_child(_fly_raycaster)
		_fly_raycaster.prompt_changed.connect(_on_interact_prompt_changed)

		# Dedicated CarryController for flycam mode. CarryController only uses
		# the `player` arg for nothing currently (see carry_controller.gd:126
		# — `player` is assigned in setup but never read in the hold loop),
		# so passing null is safe. Streaming manager wired later in
		# _initialize_interior_pocket_manager alongside the player-mode one.
		_fly_carry_controller = CarryControllerScript.new()
		_fly_carry_controller.name = "FlyCarryController"
		fly_camera.add_child(_fly_carry_controller)
		_fly_carry_controller.setup(fly_camera, null)

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

	console.register_command(
		"ocean_spray",
		_cmd_ocean_spray,
		"Toggle sea spray for visual/performance A/B. Pass on/off/status or omit to flip.",
		"water",
		PackedStringArray(["spray"]),
		[CommandRegistry.ParameterInfo.new("state", TYPE_STRING, "on/off/status (omit to flip)", false)] as Array[CommandRegistry.ParameterInfo],
		PackedStringArray(["ocean_spray", "ocean_spray off", "ocean_spray status"])
	)

	console.register_command(
		"ocean_mesh",
		_cmd_ocean_mesh,
		"Switch ocean mesh mode for visual diagnosis. Projected is FFT-only.",
		"water",
		PackedStringArray(["water_mesh"]),
		[CommandRegistry.ParameterInfo.new("mode", TYPE_STRING, "status|clipmap|projected", false, "status")] as Array[CommandRegistry.ParameterInfo],
		PackedStringArray(["ocean_mesh status", "ocean_mesh projected", "ocean_mesh clipmap"])
	)

	console.register_command(
		"wet_live",
		_cmd_wet_live,
		"Toggle live screen-space wetness compositor for water artifact diagnosis.",
		"water",
		PackedStringArray(),
		[CommandRegistry.ParameterInfo.new("state", TYPE_STRING, "on|off|status", false, "status")] as Array[CommandRegistry.ParameterInfo],
		PackedStringArray(["wet_live status", "wet_live off", "wet_live on"])
	)

	console.register_command(
		"sdfgi",
		_cmd_sdfgi,
		"Toggle active Environment SDFGI for water artifact diagnosis.",
		"rendering",
		PackedStringArray(),
		[CommandRegistry.ParameterInfo.new("state", TYPE_STRING, "on|off|status", false, "status")] as Array[CommandRegistry.ParameterInfo],
		PackedStringArray(["sdfgi status", "sdfgi off", "sdfgi on"])
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
		# Freeze exterior tracking while inside (camera at Y=-500 would unload all cells)
		_set_world_tracking_frozen(true)
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
			_set_world_tracking_frozen(false)
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

	_release_carry_controller_if_holding(_fly_carry_controller)
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

	_release_carry_controller_if_holding(_carry_controller)
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


func _release_carry_controller_if_holding(controller: Node) -> void:
	if controller == null:
		return
	if not controller.has_method("is_carrying") or not controller.has_method("release"):
		return
	if controller.is_carrying():
		controller.release()


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


func _get_active_world_environment() -> WorldEnvironment:
	if _env_controls and _env_controls.show_sky and _env_controls.sky_manager:
		var sky_world_env: WorldEnvironment = _env_controls.sky_manager.get_world_environment()
		if sky_world_env and sky_world_env.is_inside_tree():
			return sky_world_env
	for child in get_children():
		if child is WorldEnvironment:
			return child as WorldEnvironment
	return null


func _get_active_sun() -> DirectionalLight3D:
	if _env_controls and _env_controls.show_sky and _env_controls.sky_manager:
		var sky_sun: DirectionalLight3D = _env_controls.sky_manager.get_sun_light()
		if sky_sun and sky_sun.is_inside_tree():
			return sky_sun
	if _env_controls:
		var fallback_light: DirectionalLight3D = _env_controls.get_fallback_light()
		if fallback_light and fallback_light.is_inside_tree():
			return fallback_light
	return _find_sun_light()


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
		"get_active_world_environment": _get_active_world_environment,
		"get_active_sun": _get_active_sun,
		"get_terrain": func() -> Terrain3D: return terrain_3d,
		"get_viewport": get_viewport,
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
		"all_water_toggled": _ocean_controls.set_all_water_enabled,
		"show_ocean_toggled": _ocean_controls.on_show_ocean_toggled,
		"rivers_toggled": _ocean_controls.set_rivers_enabled,
		"lakes_pools_toggled": _ocean_controls.set_lakes_pools_enabled,
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
		"underwater_medium_toggled": _ocean_controls.set_underwater_medium_enabled,
		"underwater_absorption_toggled": func(enabled: bool) -> void: _ocean_controls.set_underwater_feature_enabled(&"absorption_fog", enabled),
		"underwater_snell_toggled": func(enabled: bool) -> void: _ocean_controls.set_underwater_feature_enabled(&"snell", enabled),
		"underwater_wobble_toggled": func(enabled: bool) -> void: _ocean_controls.set_underwater_feature_enabled(&"wobble", enabled),
		"underwater_caustics_toggled": func(enabled: bool) -> void: _ocean_controls.set_underwater_feature_enabled(&"caustics", enabled),
		"underwater_particles_toggled": _ocean_controls.set_underwater_particles_enabled,
		"underwater_particle_quality_changed": func(index: int) -> void:
			if _panels and _panels.underwater_particle_quality_btn:
				_ocean_controls.set_underwater_particles_quality(_panels.underwater_particle_quality_btn.get_item_id(index)),
		"underwater_particle_opacity_changed": _ocean_controls.set_underwater_particles_opacity,
		"water_turbidity_changed": _ocean_controls.on_water_turbidity_changed,
		"water_visibility_changed": _ocean_controls.on_water_visibility_changed,
		"water_color_changed": _ocean_controls.set_water_color,
		"surface_ssr_toggled": _ocean_controls.set_surface_ssr_enabled,
		"sea_spray_toggled": _ocean_controls.set_sea_spray_enabled,
		"sea_spray_quality_changed": func(index: int) -> void:
			if _panels and _panels.sea_spray_quality_btn:
				_ocean_controls.set_sea_spray_quality(_panels.sea_spray_quality_btn.get_item_id(index)),
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
		"near_gameplay_toggled": func(enabled: bool) -> void: _set_subsystem_toggle_from_ui("near_gameplay", enabled),
		"static_visuals_toggled": func(enabled: bool) -> void: _set_subsystem_toggle_from_ui("static_visuals", enabled),
		"far_impostors_toggled": func(enabled: bool) -> void: _set_subsystem_toggle_from_ui("far_impostors", enabled),
		"hlod_toggled": _on_hlod_ui_toggled,
		"distant_lights_toggled": func(enabled: bool) -> void: _set_subsystem_toggle_from_ui("distant_lights", enabled),
		"lod_mode_pressed": _on_lod_mode_pressed,
		"dump_profiling": func() -> void:
			if _profiling_report:
				_profiling_report.dump_report(),
		"teleport_to_cell": _teleport_to_cell,
	}
	var initial_state := {
		"show_characters": _show_characters,
		"show_ocean": _ocean_controls.show_ocean,
		"all_water": _ocean_controls.all_water_enabled,
		"rivers": _ocean_controls.rivers_enabled,
		"lakes_pools": _ocean_controls.lakes_pools_enabled,
		"show_sky": _env_controls.show_sky,
		"view_distance": _current_view_distance,
		"show_chunk_debug": _show_chunk_debug,
		"show_tier_debug": _show_tier_debug,
		"show_cell_debug": _show_cell_debug,
		"near_gameplay": true,
		"static_visuals": SettingsManager.get_distant_rendering_enabled(),
		"far_impostors": SettingsManager.get_distant_rendering_enabled(),
		"hlod": false,
		"distant_lights": SettingsManager.get_distant_rendering_enabled(),
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


func _set_subsystem_toggle_from_ui(name: String, enabled: bool) -> void:
	if _subsystem_toggles:
		_subsystem_toggles.set_flag(name, enabled)
		return
	match name:
		"near_gameplay":
			if native_streaming_manager:
				native_streaming_manager.set_near_tier_visible(enabled)
		"static_visuals":
			if native_streaming_manager:
				native_streaming_manager.set_mid_tier_visible(enabled)
		"far_impostors":
			if native_streaming_manager:
				native_streaming_manager.set_impostors_visible(enabled)
		"distant_lights":
			if native_streaming_manager:
				native_streaming_manager.set_distant_lights_visible(enabled)


func _on_hlod_ui_toggled(enabled: bool) -> void:
	var now := Time.get_ticks_msec()
	if now - _hlod_ui_last_toggle_msec < HLOD_UI_COOLDOWN_MSEC:
		if _panels and _panels.hlod_toggle:
			_panels.hlod_toggle.set_pressed_no_signal(not enabled)
		_log("[color=yellow]HLOD toggle cooling down; wait %.1fs[/color]" % [float(HLOD_UI_COOLDOWN_MSEC - (now - _hlod_ui_last_toggle_msec)) / 1000.0])
		return
	_hlod_ui_last_toggle_msec = now
	_hlod_ui_transition_until_msec = now + HLOD_UI_COOLDOWN_MSEC
	_update_hlod_ui_status("Starting" if enabled else "Stopping")
	_set_subsystem_toggle_from_ui("hlod", enabled)


func _sync_distance_toggle_widgets() -> void:
	if not _panels or not _subsystem_toggles:
		return
	if _panels.near_gameplay_toggle:
		_panels.near_gameplay_toggle.set_pressed_no_signal(_subsystem_toggles.get_flag("near_gameplay"))
	if _panels.static_visuals_toggle:
		_panels.static_visuals_toggle.set_pressed_no_signal(_subsystem_toggles.get_flag("static_visuals"))
	if _panels.far_impostors_toggle:
		_panels.far_impostors_toggle.set_pressed_no_signal(_subsystem_toggles.get_flag("far_impostors"))
	if _panels.hlod_toggle:
		_panels.hlod_toggle.set_pressed_no_signal(_subsystem_toggles.get_flag("hlod"))
	if _panels.distant_lights_toggle:
		_panels.distant_lights_toggle.set_pressed_no_signal(_subsystem_toggles.get_flag("distant_lights"))
	_update_hlod_ui_status("On" if _subsystem_toggles.get_flag("hlod") else "Off")


func _on_subsystem_flag_changed(_name: String, _enabled: bool) -> void:
	_sync_distance_toggle_widgets()


func _update_hlod_ui_status(state: String = "") -> void:
	if not _panels or not _panels.hlod_status_label:
		return
	var stats: Dictionary = native_streaming_manager.get_hlod_stats() if native_streaming_manager else {}
	var active := bool(stats.get("enabled", false))
	var pending := int(stats.get("pending_merges", 0)) + int(stats.get("cached_publish_queue_size", 0)) + int(stats.get("merge_queue_size", 0))
	var cells := int(stats.get("active_cells", 0))
	var label_state := state
	if label_state.is_empty():
		if Time.get_ticks_msec() < _hlod_ui_transition_until_msec:
			label_state = "Starting" if active else "Stopping"
		else:
			label_state = "On" if active else "Off"
	_panels.hlod_status_label.text = "HLOD: %s | chunks %d | pending %d" % [label_state, cells, pending]


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
		"far_impostors": func(on: bool) -> void:
			if native_streaming_manager: native_streaming_manager.set_impostors_visible(on),
		"static_visuals": func(on: bool) -> void:
			if native_streaming_manager: native_streaming_manager.set_mid_tier_visible(on),
		"near_gameplay": func(on: bool) -> void:
			if native_streaming_manager: native_streaming_manager.set_near_tier_visible(on),
		"hlod": func(on: bool) -> void:
			if native_streaming_manager: native_streaming_manager.set_hlod_visible(on),
		"distant_lights": func(on: bool) -> void:
			if native_streaming_manager: native_streaming_manager.set_distant_lights_visible(on),
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

	# Distant rendering is on by default through the fixed MID -> FAR
	# architecture. `--near-only` remains the full distant-tier opt-out, and
	# `--hlod` remains the runtime-HLOD experiment path.
	#
	# `static_visuals` controls the MID extension of the shared static renderer.
	# With NEAR gameplay on, disabling it caps static buckets to NEAR range
	# instead of hiding all rocks/arches/clutter.
	var runtime_args := _runtime_cmdline_args()
	var boot_near_only := false
	var boot_near_mid_only := false
	var boot_hlod_only := false
	var boot_far_only := false
	var boot_no_hlod := false
	var boot_no_impostors := false
	var boot_no_distant_lights := false
	for boot_i in range(runtime_args.size()):
		var arg: String = runtime_args[boot_i]
		var boot_next_arg: String = runtime_args[boot_i + 1] if boot_i + 1 < runtime_args.size() else ""
		boot_near_only = boot_near_only or arg == "--near-only"
		boot_near_mid_only = boot_near_mid_only or arg == "--near-mid-only"
		boot_hlod_only = boot_hlod_only or arg == "--hlod-only"
		boot_far_only = boot_far_only or arg == "--far-only"
		boot_no_hlod = boot_no_hlod or arg == "--no-hlod" or arg == "-no-hlod" or ((arg == "-no" or arg == "--no") and boot_next_arg == "hlod")
		boot_no_impostors = boot_no_impostors or arg == "--no-impostors"
		boot_no_distant_lights = boot_no_distant_lights or arg == "--no-distant-lights"
	var distant_default := SettingsManager.get_distant_rendering_enabled() and not boot_near_only and not boot_near_mid_only

	var defaults: Dictionary = {
		"terrain": true,
		"ocean": _ocean_controls.show_ocean and not boot_far_only,
		"sky": _env_controls.show_sky and not boot_far_only,
		"weather": _weather_controls.weather_enabled and not boot_far_only,
		"characters": _show_characters,
		"far_impostors": distant_default and not boot_no_impostors and not boot_hlod_only,
		"static_visuals": distant_default and not boot_hlod_only and not boot_far_only,
		"near_gameplay": not boot_far_only,
		"hlod": boot_hlod_only or (not boot_no_hlod and not boot_far_only and runtime_args.has("--hlod")),
		"distant_lights": distant_default and not boot_no_distant_lights and not boot_hlod_only and not boot_far_only,
		"shadows": false,
		"postfx": false,
	}

	_subsystem_toggles.setup(callbacks, defaults)
	_subsystem_toggles.register_alias("impostors", "far_impostors")
	_subsystem_toggles.register_alias("mid_objects", "static_visuals")
	_subsystem_toggles.register_alias("near_objects", "near_gameplay")
	var flag_changed_cb := Callable(self, "_on_subsystem_flag_changed")
	if _subsystem_toggles.has_signal("flag_changed") and not _subsystem_toggles.is_connected("flag_changed", flag_changed_cb):
		_subsystem_toggles.connect("flag_changed", flag_changed_cb)
	_sync_distance_toggle_widgets()
	if native_streaming_manager != null:
		native_streaming_manager.call("set_impostors_visible", bool(defaults.get("far_impostors", true)))
		native_streaming_manager.call("set_hlod_visible", bool(defaults.get("hlod", false)))
		native_streaming_manager.call("set_distant_lights_visible", bool(defaults.get("distant_lights", true)))
		var tier_stats: Dictionary = native_streaming_manager.call("get_stats")
		Log.info("streaming", "Distant tier defaults synced: HLOD=%s FAR=%s distant_lights=%s" % [
			str(defaults.get("hlod", false)),
			str(defaults.get("far_impostors", true)),
			str(defaults.get("distant_lights", true)),
		])
		Log.info("streaming", "Distant tier state: view=%dm FAR enabled=%s FAR instances=%d HLOD initialized=%s HLOD active=%s HLOD cells=%d" % [
			int(tier_stats.get("view_distance_meters", _current_view_distance)),
			str(tier_stats.get("far_enabled", false)),
			int(tier_stats.get("total_impostors", 0)),
			str(tier_stats.get("hlod_initialized", false)),
			str(tier_stats.get("hlod_active", false)),
			int(tier_stats.get("hlod_cells", 0)),
		])

	# Boot banner: make the active distant tier state explicit in logs.
	_log("[color=green][Distant tiers active][/color] MID fixed 150-%dm; FAR impostors %dm+; HLOD off by default" % [
		int(StreamingConfig.DU.MID_END),
		int(StreamingConfig.DU.FAR_START),
	])
	Log.info("streaming", "[Distant tiers active] MID fixed=150-%d; FAR starts at %d; HLOD off by default; view distance caps tier loading" % [
		int(StreamingConfig.DU.MID_END),
		int(StreamingConfig.DU.FAR_START),
	])

	# CLI controls for focused tier isolation. `--near-only` parks MID and
	# distant render tiers. `--near-mid-only` is the hard benchmark
	# isolation mode: terrain + NEAR + MID only, with environment/post effects
	# disabled too. `--hlod` explicitly enables HLOD on top of the normal
	# stack; `--hlod-only` isolates visible HLOD + terrain while leaving the
	# streaming/prototype bootstrap alive.
	# The shared static renderer remains alive for NEAR; this toggle adjusts
	# its visibility range rather than deleting the owner.
	for i in range(runtime_args.size()):
		var a: String = runtime_args[i]
		var next_arg: String = runtime_args[i + 1] if i + 1 < runtime_args.size() else ""
		if a == "--near-only":
			_subsystem_toggles.set_flag("static_visuals", false)
			_subsystem_toggles.set_flag("hlod", false)
			_subsystem_toggles.set_flag("far_impostors", false)
			_subsystem_toggles.set_flag("distant_lights", false)
			_log("[color=yellow]--near-only: NEAR gameplay/statics only; MID/HLOD/FAR/distant lights OFF[/color]")
		elif a == "--near-mid-only":
			_subsystem_toggles.set_flag("hlod", false)
			_subsystem_toggles.set_flag("far_impostors", false)
			_subsystem_toggles.set_flag("distant_lights", false)
			_subsystem_toggles.set_flag("sky", false)
			_subsystem_toggles.set_flag("weather", false)
			_subsystem_toggles.set_flag("postfx", false)
			_subsystem_toggles.set_flag("shadows", false)
			_subsystem_toggles.set_flag("ocean", false)
			_subsystem_toggles.set_flag("characters", false)
			_log("[color=yellow]--near-mid-only: terrain + NEAR + MID isolation[/color]")
		elif a == "--hlod":
			_subsystem_toggles.set_flag("hlod", true)
			_log("[color=yellow]--hlod: HLOD ON; FAR still starts at %dm[/color]" % int(StreamingConfig.DU.FAR_START))
		elif a == "--hlod-only":
			_hlod_flyby_mode = true
			_subsystem_toggles.set_flag("terrain", true)
			_subsystem_toggles.set_flag("near_gameplay", false)
			_subsystem_toggles.set_flag("static_visuals", false)
			_subsystem_toggles.set_flag("hlod", true)
			_subsystem_toggles.set_flag("far_impostors", false)
			_subsystem_toggles.set_flag("distant_lights", false)
			_subsystem_toggles.set_flag("sky", false)
			_subsystem_toggles.set_flag("weather", false)
			_subsystem_toggles.set_flag("postfx", false)
			_subsystem_toggles.set_flag("shadows", false)
			_subsystem_toggles.set_flag("ocean", false)
			_subsystem_toggles.set_flag("characters", false)
			_log("[color=yellow]--hlod-only: visible HLOD + terrain isolation; FAR/environment OFF[/color]")
		elif a == "--far-only":
			_subsystem_toggles.set_flag("terrain", true)
			_subsystem_toggles.set_flag("near_gameplay", false)
			_subsystem_toggles.set_flag("static_visuals", false)
			_subsystem_toggles.set_flag("hlod", false)
			_subsystem_toggles.set_flag("far_impostors", true)
			_subsystem_toggles.set_flag("distant_lights", false)
			_subsystem_toggles.set_flag("sky", false)
			_subsystem_toggles.set_flag("weather", false)
			_subsystem_toggles.set_flag("postfx", false)
			_subsystem_toggles.set_flag("shadows", false)
			_subsystem_toggles.set_flag("ocean", false)
			_subsystem_toggles.set_flag("characters", false)
			_log("[color=yellow]--far-only: terrain + FAR impostors only; NEAR/MID/HLOD/environment OFF[/color]")
		elif a == "--no-hlod" or a == "-no-hlod" or ((a == "-no" or a == "--no") and next_arg == "hlod"):
			_subsystem_toggles.set_flag("hlod", false)
			_log("[color=yellow]--no-hlod: HLOD OFF; MID fixed at %dm[/color]" % int(StreamingConfig.DU.MID_END))
		elif a == "--no-impostors":
			_subsystem_toggles.set_flag("far_impostors", false)
			_log("[color=yellow]--no-impostors: FAR impostors OFF[/color]")
		elif a == "--no-distant-lights":
			_subsystem_toggles.set_flag("distant_lights", false)
			_log("[color=yellow]--no-distant-lights: distant light billboards OFF[/color]")
		elif a == "--no-sky":
			_subsystem_toggles.set_flag("sky", false)
			_log("[color=yellow]--no-sky: sky renderer OFF[/color]")
		elif a == "--no-weather":
			_subsystem_toggles.set_flag("weather", false)
			_log("[color=yellow]--no-weather: weather renderer OFF[/color]")
		elif a == "--no-postfx":
			_subsystem_toggles.set_flag("postfx", false)
			_log("[color=yellow]--no-postfx: TAA/SSAO/SSIL/glow/godrays/fog OFF[/color]")
		elif a == "--no-shadows":
			_subsystem_toggles.set_flag("shadows", false)
			_log("[color=yellow]--no-shadows: directional shadows OFF[/color]")

	_sync_distance_toggle_widgets()

	# Register console commands
	if console:
		_subsystem_toggles.register_commands(console)

	_log("Subsystem toggles initialized (%d flags)" % _subsystem_toggles.get_flag_names().size())

	# Benchmark HUD overlay — lives at scene tree root so it stays alive across
	# interior pocket transitions and doesn't get torn down with world_explorer.
	# Default hidden per docs/audit/BENCHMARK_V2_PLAN.md; user reveals with `hud`.
	if _benchmark_hud == null:
		_benchmark_hud = BenchmarkHUDScript.new()
		_benchmark_hud.name = "BenchmarkHUD"
		get_tree().root.add_child(_benchmark_hud)
		_benchmark_hud.set_streaming_manager(native_streaming_manager)
		_benchmark_hud.set_subsystem_toggles(_subsystem_toggles)
		if console:
			BenchmarkHUDScript.register_console_commands(console, _benchmark_hud)

	# Progressive auto-run — `bench_progressive` command. Needs toggles, so
	# registered here rather than alongside the other streaming_benchmark
	# commands (which register earlier, before _subsystem_toggles exists).
	if console and native_streaming_manager and cell_manager:
		ProgressiveBenchmarkScript.register_console_commands(
			console, native_streaming_manager, cell_manager, camera, _subsystem_toggles
		)

	# Quick isolation sweep — `perf_sweep` command (~60s, per-subsystem FPS cost table).
	if console and _subsystem_toggles:
		PerfSweepScript.register_console_commands(
			console, native_streaming_manager, cell_manager, _subsystem_toggles
		)

	# On-demand streaming phase dump — instant snapshot of current phase times.
	# Use after `hud` to correlate live overlay data with raw phase breakdown.
	if console and native_streaming_manager and cell_manager:
		var _sm := native_streaming_manager  # capture for closure
		var phases_cmd := func(_args: Dictionary) -> Variant:
			var stats: Dictionary = _sm.get_stats()
			var pt: PackedFloat64Array = _sm.get_phase_times()
			var fps := Engine.get_frames_per_second()
			var proc_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
			var q := int(stats.get("instantiation_queue", -1))
			var burst := bool(stats.get("burst_loading", false))
			var sm_total := float(stats.get("frame_total_ms", 0.0))
			var startup := bool(stats.get("startup_phase", false))
			var n := pt.size()
			var lines := PackedStringArray()
			lines.append("=== streaming_phases snapshot ===")
			lines.append("fps=%d  proc=%.1fms  stream_total=%.1fms  [%s%s]" % [
				fps, proc_ms, sm_total,
				"STARTUP " if startup else "",
				"BURST" if burst else "norm"
			])
			lines.append("queue=%d  cells_ready/resident/desired=%d/%d/%d  async_req=%d" % [
				q,
				int(stats.get("visual_ready_cells", stats.get("loaded_cells", 0))),
				int(stats.get("resident_cell_containers", stats.get("loaded_cells", 0))),
				int(stats.get("desired_cell_count", stats.get("target_cell_count", 0))),
				int(stats.get("async_requests", 0))
			])
			lines.append("view=%dm scene_radius=%d theoretical=%d load_queue=%d active_slots=%d resident_req=%d mid_buckets=%d mid_draws=%d" % [
				int(stats.get("view_distance_meters", _current_view_distance)),
				int(stats.get("load_radius_cells", 0)),
				int(stats.get("target_cell_count", 0)),
				int(stats.get("load_queue_size", 0)),
				int(stats.get("active_async_load_slots", 0)),
				int(stats.get("resident_async_requests", stats.get("async_requests", 0))),
				int(stats.get("mid_cell_buckets", 0)),
				int(stats.get("mid_bucket_draw_groups", 0)),
			])
			lines.append("phases (ms):")
			lines.append("  unload   = %.2f" % (pt[0]/1000.0 if n > 0 else 0.0))
			lines.append("  async    = %.2f" % (pt[1]/1000.0 if n > 1 else 0.0))
			lines.append("  inst     = %.2f  ← instantiation budget" % (pt[2]/1000.0 if n > 2 else 0.0))
			lines.append("  promo    = %.2f" % (pt[3]/1000.0 if n > 3 else 0.0))
			lines.append("  coll     = %.2f" % (pt[4]/1000.0 if n > 4 else 0.0))
			lines.append("  defer    = %.2f" % (pt[5]/1000.0 if n > 5 else 0.0))
			lines.append("  queue_io = %.2f" % (pt[6]/1000.0 if n > 6 else 0.0))
			lines.append("  cell_upd = %.2f" % (pt[7]/1000.0 if n > 7 else 0.0))
			lines.append("distant lanes (ms):")
			lines.append("  impostor = %.2f" % float(stats.get("streaming_impostor_update_ms", 0.0)))
			lines.append("  hlod     = %.2f" % float(stats.get("streaming_hlod_merger_ms", 0.0)))
			lines.append("  lights   = %.2f" % float(stats.get("streaming_distant_light_ms", 0.0)))
			lines.append("  distant_total = %.2f  attributed = %.2f  unattrib = %.2f" % [
				float(stats.get("streaming_distant_tiers_ms", 0.0)),
				float(stats.get("streaming_phase_sum_ms", 0.0)) + float(stats.get("streaming_distant_tiers_ms", 0.0)),
				float(stats.get("streaming_unattributed_ms", 0.0)),
			])
			lines.append("Δ GPU = frame_ms - proc_ms (if proc_ms large → GDScript bound)")
			for line: String in lines:
				console.print_line(line)
			return "streaming_phases: done"
		console.register_command(
			"streaming_phases", phases_cmd,
			"Dump current per-phase streaming timings + FPS/proc breakdown",
			"benchmark",
			PackedStringArray([])
		)


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


func _apply_mesh_lod_threshold() -> void:
	var viewport := get_viewport()
	if viewport:
		viewport.mesh_lod_threshold = StreamingConfig.DEFAULT_MESH_LOD_THRESHOLD
		Log.info("streaming", "Viewport mesh_lod_threshold=%.2f" % StreamingConfig.DEFAULT_MESH_LOD_THRESHOLD)


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
	native_streaming_manager.set_view_distance_meters(_current_view_distance, false)
	native_streaming_manager.debug_enabled = false  # Disabled for performance (enable with toggle_debug command)
	native_streaming_manager.set_world_source(world_source)
	
	add_child(native_streaming_manager)
	
	# Connect signals
	native_streaming_manager.cell_loading.connect(_on_native_cell_loading)
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
			"static_trace_selected",
			_cmd_static_trace_selected,
			"Trace the selected static payload through CellPayload and CellStaticBucket",
			"debug",
			PackedStringArray(["sts"]),
			[CommandRegistry.ParameterInfo.new("action", TYPE_STRING, "''|force_on|force_off", false, "")]
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

		# Register wireframe + collision visualization commands.
		# World root used as the recursion start for collision-shape walking,
		# covering both streamed cells and any in-scene-tree statics.
		_debug_view_commands = DebugViewCommands.new(get_viewport(), self)
		_debug_view_commands.register_commands(console)

		# Register batch pool debug commands (legacy HUD)
		console.register_command(
			"mid_hud",
			_cmd_toggle_batch_debug,
			"Toggle MID-tier batch pool debug HUD + LOD band rings",
			"debug"
		)

		console.register_command(
			"tier_view",
			_cmd_toggle_tier_view,
			"Toggle visual NEAR/MID/HLOD/FAR distance tier rings",
			"debug"
		)

		console.register_command(
			"hlod_chunk_view",
			_cmd_toggle_hlod_chunk_view,
			"Toggle visual HLOD chunk boxes and state labels",
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

		console.register_command(
			"raycast_debug",
			_cmd_raycast_debug,
			"Toggle interaction raycast debug line (GREEN=hit, YELLOW=layer3 no interactable, RED=miss)",
			"debug"
		)

		console.register_command(
			"vel_scan",
			_cmd_vel_scan,
			"Scan all RigidBody3D in scene — list any unfrozen or moving (>0.1 m/s); check for fallen items",
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
			"Enable runtime HLOD merging (optional overlap with FAR)",
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


func _cmd_static_trace_selected(args: Dictionary) -> String:
	if not console:
		return "Console not initialized"
	if not native_streaming_manager or not native_streaming_manager.has_method("static_trace_selection"):
		return "Native streaming manager does not support static tracing"
	var selection: Variant = console.get_selection()
	var action := str(args.get("action", ""))
	return native_streaming_manager.call("static_trace_selection", selection, action)


## Console command: toggle_debug
func _cmd_toggle_debug(_args: Dictionary) -> String:
	if native_streaming_manager:
		native_streaming_manager.debug_enabled = not native_streaming_manager.debug_enabled
		native_streaming_manager.set_impostor_debug_enabled(native_streaming_manager.debug_enabled)
		return "Debug mode: %s" % ("ON" if native_streaming_manager.debug_enabled else "OFF")
	return "Native streaming manager not available"


func _cmd_ocean_spray(args: Dictionary) -> String:
	if WaterSystem == null:
		return "WaterSystem not available"

	var raw := String(args.get("state", "")).to_lower().strip_edges()
	if raw in ["on", "true", "1", "yes"]:
		WaterSystem.set_sea_spray_enabled(true)
	elif raw in ["off", "false", "0", "no"]:
		WaterSystem.set_sea_spray_enabled(false)
	elif raw not in ["", "status"]:
		return "Usage: ocean_spray [on|off|status]"
	elif raw == "":
		WaterSystem.toggle_sea_spray()

	var status: Dictionary = WaterSystem.get_sea_spray_status()
	return "ocean_spray=%s quality=%s emitting=%s candidates=%d energy=%.2f fft=%s" % [
		"ON" if bool(status.get("enabled", false)) else "off",
		String(status.get("quality_name", "Unknown")),
		"yes" if bool(status.get("emitting", false)) else "no",
		int(status.get("particle_candidates", 0)),
		float(status.get("weather_energy", 0.0)),
		"yes" if bool(status.get("has_fft", false)) else "no",
	]


func _cmd_ocean_mesh(args: Dictionary) -> String:
	if WaterSystem == null or not WaterSystem.is_initialized():
		return "WaterSystem not initialized"

	var raw := String(args.get("mode", "status")).to_lower().strip_edges()
	if raw in ["", "status", "info"]:
		return _format_ocean_mesh_status()
	if raw in ["clipmap", "clip", "0"]:
		WaterSystem.rebuild_mesh_with_mode(OceanMesh.MeshMode.CLIPMAP)
		return _format_ocean_mesh_status()
	if raw in ["projected", "project", "proj", "1"]:
		if WaterSystem.get_water_quality() != OceanMesh.QualityMode.HIGH:
			return "Projected mesh is FFT-only. Switch Water quality to High FFT first, then run: ocean_mesh projected"
		WaterSystem.rebuild_mesh_with_mode(OceanMesh.MeshMode.PROJECTED)
		return _format_ocean_mesh_status()
	return "Usage: ocean_mesh [status|clipmap|projected]"


func _format_ocean_mesh_status() -> String:
	var mode := "Unknown"
	if WaterSystem.has_method("get_mesh_mode"):
		mode = "Projected" if WaterSystem.get_mesh_mode() == OceanMesh.MeshMode.PROJECTED else "Clipmap"
	var quality := "Unknown"
	if WaterSystem.has_method("get_water_quality_name"):
		quality = WaterSystem.get_water_quality_name()
	var shader := "Unknown"
	if WaterSystem.has_method("get_surface_shader_mode_name"):
		shader = WaterSystem.get_surface_shader_mode_name()
	return "ocean_mesh=%s quality=%s shader=%s" % [mode, quality, shader]


func _cmd_wet_live(args: Dictionary) -> String:
	if not WetnessManager:
		return "WetnessManager unavailable"

	var raw := String(args.get("state", "status")).to_lower().strip_edges()
	if raw in ["", "status", "info"]:
		return _format_wet_live_status()
	if raw in ["on", "true", "1", "yes"]:
		WetnessManager.set_enabled(true)
		WetnessManager.set_live_compositor_enabled(true)
		return _format_wet_live_status()
	if raw in ["off", "false", "0", "no"]:
		WetnessManager.set_live_compositor_enabled(false)
		return _format_wet_live_status()
	return "Usage: wet_live [on|off|status]"


func _format_wet_live_status() -> String:
	if not WetnessManager:
		return "WetnessManager unavailable"

	var manager_on := false
	if WetnessManager.has_method("is_enabled"):
		manager_on = WetnessManager.is_enabled()
	var live_on := false
	if WetnessManager.has_method("is_live_compositor_enabled"):
		live_on = WetnessManager.is_live_compositor_enabled()
	var effect_on := false
	if ShaderManager and ShaderManager.has_method("is_effect_enabled"):
		effect_on = bool(ShaderManager.call("is_effect_enabled", "wet_compositor"))

	return "wet_live=%s manager=%s wet_compositor_effect=%s" % [
		"ON" if live_on else "off",
		"ON" if manager_on else "off",
		"ON" if effect_on else "off",
	]


func _cmd_sdfgi(args: Dictionary) -> String:
	if not _env_controls:
		return "Environment controls unavailable"

	var raw := String(args.get("state", "status")).to_lower().strip_edges()
	if raw in ["", "status", "info"]:
		return _format_sdfgi_status()
	if raw in ["on", "true", "1", "yes"]:
		_env_controls.on_sdfgi_toggled(true)
		return _format_sdfgi_status()
	if raw in ["off", "false", "0", "no"]:
		_env_controls.on_sdfgi_toggled(false)
		return _format_sdfgi_status()
	return "Usage: sdfgi [on|off|status]"


func _format_sdfgi_status() -> String:
	if not _env_controls:
		return "Environment controls unavailable"

	var env := _env_controls.get_active_environment()
	if not env:
		return "sdfgi=unknown (no active Environment)"

	return "sdfgi=%s cascades=%d occlusion=%s sky_light=%s" % [
		"ON" if env.sdfgi_enabled else "off",
		env.sdfgi_cascades,
		"ON" if env.sdfgi_use_occlusion else "off",
		"ON" if env.sdfgi_read_sky_light else "off",
	]


func _cmd_toggle_batch_debug(_args: Dictionary) -> String:
	if _batch_debug_hud:
		_batch_debug_hud.toggle()
		return "Batch debug HUD: %s" % ("ON" if _batch_debug_hud.is_active() else "OFF")
	return "Batch debug HUD not initialized"


func _cmd_toggle_tier_view(_args: Dictionary) -> String:
	if not _debug_overlay:
		return "Debug overlay not initialized"
	_on_show_tiers_toggled(not _show_tier_debug)
	var state := "ON" if _show_tier_debug else "OFF"
	return "Tier view: %s (NEAR 0-150m, MID 150-%dm, FAR %dm+, HLOD optional)" % [
		state,
		int(StreamingConfig.DU.MID_END),
		int(StreamingConfig.DU.FAR_START),
	]


func _cmd_toggle_hlod_chunk_view(_args: Dictionary) -> String:
	if not _debug_overlay:
		return "Debug overlay not initialized"
	_on_show_chunks_toggled(not _show_chunk_debug)
	var state := "ON" if _show_chunk_debug else "OFF"
	return "HLOD chunk view: %s (cyan=active, yellow=queued, blue=pending, red=rejected)" % state


func _cmd_dump_doors(_args: Dictionary) -> String:
	if _pocket_manager:
		_pocket_manager.debug_dump_doors()
		return "Door dump printed to log (check streaming category)"
	return "Interior pocket manager not available"


func _cmd_raycast_debug(_args: Dictionary) -> String:
	# Toggle debug_draw on both raycasters so the active one always shows.
	var enabled := false
	if _fly_raycaster:
		enabled = not _fly_raycaster.debug_draw
		_fly_raycaster.debug_draw = enabled
	if _interaction_raycaster:
		_interaction_raycaster.debug_draw = enabled
	return "Raycast debug: %s" % ("ON" if enabled else "OFF")


func _cmd_vel_scan(_args: Dictionary) -> String:
	# Walk the full scene tree, collect every RigidBody3D (incl. BuoyancyBody3D
	# subclass), flag any that are unfrozen or have significant velocity.
	# Interior pocket items live at Y ≈ -500; anything < -490 is suspect.
	var bodies: Array[RigidBody3D] = []
	_collect_rigid_bodies_recursive(get_tree().root, bodies)
	if bodies.is_empty():
		return "No RigidBody3D in scene"
	var unfrozen := 0
	var moving := 0
	var fallen := 0
	for rb: RigidBody3D in bodies:
		var vel := rb.linear_velocity.length()
		var pos := rb.global_position
		var is_moving := vel > 0.1
		var is_fallen := pos.y < -490.0 and pos.y > -600.0
		if not rb.freeze:
			unfrozen += 1
		if is_moving:
			moving += 1
		if is_fallen:
			fallen += 1
		if is_moving or not rb.freeze or is_fallen:
			Log.warn("interaction", "[VEL_SCAN] %s pos=(%.1f,%.1f,%.1f) vel=%.2fm/s frozen=%s%s" % [
				rb.name, pos.x, pos.y, pos.z, vel, rb.freeze,
				" FALLEN" if is_fallen else "",
			])
	if unfrozen == 0 and moving == 0 and fallen == 0:
		Log.info("interaction", "[VEL_SCAN] All %d bodies frozen at rest — no flying items" % bodies.size())
	return "vel_scan: %d bodies, %d unfrozen, %d moving, %d fallen — check log" % [
		bodies.size(), unfrozen, moving, fallen
	]


## Depth-first tree walk collecting all RigidBody3D nodes (incl. subclasses).
func _collect_rigid_bodies_recursive(node: Node, out: Array[RigidBody3D]) -> void:
	if node is RigidBody3D:
		out.append(node as RigidBody3D)
	for child: Node in node.get_children():
		_collect_rigid_bodies_recursive(child, out)


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
	if not native_streaming_manager:
		return "Native streaming manager not initialized"
	if _subsystem_toggles and not _subsystem_toggles.get_flag("hlod"):
		_subsystem_toggles.set_flag("hlod", true)
	else:
		native_streaming_manager.set_hlod_visible(true)
	var cap := _get_distant_render_end_m()
	return "HLOD requested - MID bridge 150-%dm, HLOD %s, FAR %s, view cap %dm" % [
		int(StreamingConfig.DU.MID_END),
		"%d-%dm" % [int(StreamingConfig.DU.HLOD_START), int(minf(cap, StreamingConfig.DU.HLOD_END))] if cap > StreamingConfig.DU.HLOD_START else "not loaded",
		"%d-%dm" % [int(StreamingConfig.DU.FAR_START), int(cap)] if cap > StreamingConfig.DU.FAR_START else "not loaded",
		int(cap),
	]


func _cmd_hlod_disable(_args: Dictionary) -> String:
	if not native_streaming_manager:
		return "Native streaming manager not initialized"
	# HLOD-off parks only HLOD. MID stays fixed at 300m; FAR is controlled by
	# the separate impostor toggle and the view cap.
	if _subsystem_toggles and _subsystem_toggles.get_flag("hlod"):
		_subsystem_toggles.set_flag("hlod", false)
	else:
		native_streaming_manager.set_hlod_visible(false)
	return "HLOD DISABLED - MID bridge 150-%dm, HLOD parked" % int(StreamingConfig.DU.MID_END)


func _cmd_hlod_stats(_args: Dictionary) -> String:
	if not native_streaming_manager:
		return "Native streaming manager not initialized"
	var stats: Dictionary = native_streaming_manager.get_hlod_stats()
	return (
		"HLOD: enabled=%s, active=%d, visual=%d, pending=%d, cache=%d entries (%.1f MB), total_merged=%d\n" % [
			str(stats.get("enabled", false)),
			stats.get("active_cells", 0),
			stats.get("active_visual_chunks", 0),
			stats.get("pending_merges", 0),
			stats.get("cache_entries", 0),
			stats.get("cache_bytes", 0) / (1024.0 * 1024.0),
			stats.get("total_merges_completed", 0),
		] +
		"  ranges: visual_floor=%.0fm, FAR_begin=%.0fm, MID_overlap_chunks=%d, FAR_overlap_chunks=%d, hole_risk_chunks=%d\n" % [
			stats.get("visual_begin_floor", 0.0),
			stats.get("far_visibility_begin_m", 0.0),
			stats.get("mid_hlod_overlap_chunks", 0),
			stats.get("handoff_far_hlod_overlap_chunks", 0),
			stats.get("handoff_hole_risk_chunks", 0),
		] +
		"  tiers: t0=%d, t1=%d, t2=%d, nonvisual_suppressed=%d\n" % [
			stats.get("chunks_tier_0", 0),
			stats.get("chunks_tier_1", 0),
			stats.get("chunks_tier_2", 0),
			stats.get("nonvisual_chunks_suppressed", 0),
		] +
		"  queue: desired=%d, queued=%d, preparing=%d, pending=%d, negative=%d, warmup=%d\n" % [
			stats.get("desired_chunks", 0),
			stats.get("merge_queue_size", 0),
			stats.get("preparing_chunks", 0),
			stats.get("pending_merges", 0),
			stats.get("negative_chunks", 0),
			stats.get("warmup_queue_size", 0),
		] +
		"  chunks: surfaces=%d (max=%d), materials=%d (max=%d), verts=%d (max=%d), indices=%d (max=%d)\n" % [
			stats.get("total_chunk_surfaces", 0),
			stats.get("max_chunk_surfaces", 0),
			stats.get("total_chunk_materials", 0),
			stats.get("max_chunk_materials", 0),
			stats.get("total_chunk_vertices", 0),
			stats.get("max_chunk_vertices", 0),
			stats.get("total_chunk_indices", 0),
			stats.get("max_chunk_indices", 0),
		] +
		"  coverage: refs=%d, cells=%d, complete_chunks=%d, incomplete_chunks=%d, revision=%d, FAR_pages=%d/%d, FAR_overrides=%d\n" % [
			stats.get("active_covered_refs", 0),
			stats.get("active_covered_cells", 0),
			stats.get("active_complete_coverage_chunks", 0),
			stats.get("active_incomplete_coverage_chunks", 0),
			stats.get("coverage_revision", 0),
			stats.get("far_hlod_covered_pages", 0),
			stats.get("far_hlod_uncovered_pages", 0),
			stats.get("far_hlod_page_overrides", 0),
		] +
		"  rejects: skipped=%d, type=%d, size=%d, surface=%d, partial_bucket=%d, surface_cap=%d, over_budget_published=%d, stale=%d, size_cache_hits=%d, size_cache=%d\n" % [
			stats.get("total_refs_skipped", 0),
			stats.get("refs_type_rejected", 0),
			stats.get("refs_size_rejected", 0),
			stats.get("refs_surface_rejected", 0),
			stats.get("refs_partial_bucket_rejected", 0),
			stats.get("surface_cap_rejections", 0),
			stats.get("surface_cap_over_budget_published", 0),
			stats.get("stale_completions_discarded", 0),
			stats.get("size_cache_hits", 0),
			stats.get("size_cache_size", 0),
		] +
		"  timing: merge_queue=%dus, completion=%dus, teleports=%d, runtime_lods=%s, force_merge=%s" % [
			stats.get("merge_queue_last_usec", 0),
			stats.get("completion_last_usec", 0),
			stats.get("total_teleports", 0),
			str(stats.get("runtime_lod_generation_enabled", false)),
			str(stats.get("runtime_force_merge_eligible_refs", false)),
		]
	)


func _register_exterior_doors_for_grid(grid: Vector2i) -> void:
	if not _pocket_manager:
		return
	var cell: Variant = null
	if world_object_source != null and world_object_source.has_method("get_source_exterior_cell"):
		cell = world_object_source.call("get_source_exterior_cell", grid)
	if cell:
		_pocket_manager.register_exterior_cell_doors(cell, grid)


## Callback for native streaming manager cell activation/request
func _on_native_cell_loading(grid: Vector2i) -> void:
	_register_exterior_doors_for_grid(grid)


## Callback for native streaming manager cell loaded
func _on_native_cell_loaded(grid: Vector2i, object_count: int) -> void:
	_log("Cell loaded: (%d, %d) - %d objects (native)" % [grid.x, grid.y, object_count])
	_update_stats()
	_prepare_water_for_loaded_cell(grid)

	# Completion can arrive long after interactive doors were proximity-deferred;
	# this is an idempotent backup for cells that did not emit through the async
	# request path.
	_register_exterior_doors_for_grid(grid)

	# Autoregister collision visualizers on the new cell when the toggle is ON.
	# No-op when toggle is off. Cell node lookup defers to NativeStreamingManager.
	if _debug_view_commands and native_streaming_manager:
		var cell_node: Node = native_streaming_manager.get_loaded_cell(grid)
		if cell_node:
			_debug_view_commands.on_cell_loaded(cell_node)


func _prepare_water_for_loaded_cell(grid: Vector2i) -> void:
	if WaterSystem and WaterSystem.has_method("is_water_layer_enabled") and not WaterSystem.is_water_layer_enabled(&"all"):
		return
	if WaterSystem and WaterSystem.has_method("is_water_layer_enabled") \
			and not WaterSystem.is_water_layer_enabled(&"rivers") \
			and not WaterSystem.is_water_layer_enabled(&"lakes_pools"):
		return
	if world_source == null or not world_source.has_method("get_water_provider"):
		return
	var water_provider: RefCounted = world_source.call("get_water_provider") as RefCounted
	if water_provider == null:
		return
	if water_provider.has_method("request_prepare_cell_grid"):
		var err: int = water_provider.call("request_prepare_cell_grid", grid)
		if err != OK and err != ERR_DOES_NOT_EXIST:
			Log.warn("water", "WorldExplorer: failed to request water for cell %s (error %d)" % [grid, err])
	elif water_provider.has_method("prepare_cell_grid"):
		var err: int = water_provider.call("prepare_cell_grid", grid)
		if err != OK and err != ERR_DOES_NOT_EXIST:
			Log.warn("water", "WorldExplorer: failed to prepare water for cell %s (error %d)" % [grid, err])
	_enqueue_river_render_publish(grid)
	_process_river_render_publish_queue(water_provider)


func _process_water_provider_async() -> void:
	if WaterSystem and WaterSystem.has_method("is_water_layer_enabled") and not WaterSystem.is_water_layer_enabled(&"all"):
		return
	if WaterSystem and WaterSystem.has_method("is_water_layer_enabled") \
			and not WaterSystem.is_water_layer_enabled(&"rivers") \
			and not WaterSystem.is_water_layer_enabled(&"lakes_pools"):
		return
	if world_source == null or not world_source.has_method("get_water_provider"):
		return
	var water_provider: RefCounted = world_source.call("get_water_provider") as RefCounted
	if water_provider != null and water_provider.has_method("process_async_requests"):
		water_provider.call("process_async_requests")
	if water_provider != null:
		_process_river_render_publish_queue(water_provider)


func _ensure_water_render_root() -> Node3D:
	if _water_render_root != null and is_instance_valid(_water_render_root):
		return _water_render_root
	if WaterSystem and WaterSystem.has_method("get_generated_water_root"):
		_water_render_root = WaterSystem.call("get_generated_water_root") as Node3D
	if _water_render_root == null:
		_water_render_root = Node3D.new()
		_water_render_root.name = "GeneratedWaterBodies"
		add_child(_water_render_root)
	return _water_render_root


func _enqueue_river_render_publish(grid: Vector2i) -> void:
	if _river_render_publish_queue_set.has(grid):
		return
	_river_render_publish_queue_set[grid] = true
	_river_render_publish_queue.append(grid)


func _process_river_render_publish_queue(water_provider: RefCounted) -> void:
	if water_provider == null or _river_render_publish_queue.is_empty():
		return
	var start_usec := Time.get_ticks_usec()
	var processed := 0
	var remaining: Array[Vector2i] = []
	for grid: Vector2i in _river_render_publish_queue:
		if processed >= WATER_RENDER_PUBLISH_MAX_CELLS_PER_FRAME:
			remaining.append(grid)
			continue
		_river_render_publish_queue_set.erase(grid)
		if _is_cell_loaded_or_tracked_for_river_render(grid):
			var complete := _publish_river_render_payloads_for_cell(grid, water_provider)
			if not complete:
				remaining.append(grid)
				_river_render_publish_queue_set[grid] = true
		processed += 1
	_river_render_publish_queue = remaining
	_river_render_publish_last_usec = Time.get_ticks_usec() - start_usec
	_river_render_publish_total_usec += _river_render_publish_last_usec
	_river_render_publish_count += 1


func _is_cell_loaded_or_tracked_for_river_render(grid: Vector2i) -> bool:
	if _cell_river_body_ids.has(grid):
		return true
	if native_streaming_manager != null:
		return native_streaming_manager.is_cell_loaded(grid)
	return false


func get_generated_water_runtime_status() -> Dictionary:
	var hydrology_status := _get_water_provider_runtime_status()
	return {
		"river_render_node_count": _river_render_nodes_by_body_id.size(),
		"river_render_tracked_cell_count": _cell_river_body_ids.size(),
		"water_publish_queue_size": _river_render_publish_queue.size(),
		"water_publish_last_usec": _river_render_publish_last_usec,
		"water_publish_total_usec": _river_render_publish_total_usec,
		"water_publish_count": _river_render_publish_count,
		"hydrology": hydrology_status,
	}


func _get_water_provider_runtime_status() -> Dictionary:
	if world_source == null or not world_source.has_method("get_water_provider"):
		return {}
	var water_provider: RefCounted = world_source.call("get_water_provider") as RefCounted
	if water_provider == null:
		return {}
	if water_provider.has_method("get_runtime_status"):
		var status_v: Variant = water_provider.call("get_runtime_status")
		if status_v is Dictionary:
			return status_v
	var status := {
		"active_hydrology_tasks": 0,
		"cached_regions": 0,
		"cache_memory_bytes_estimate": 0,
	}
	if "_pending_region_tasks" in water_provider:
		status["active_hydrology_tasks"] = water_provider._pending_region_tasks.size()
	if "_region_cache" in water_provider:
		var cache: Dictionary = water_provider._region_cache
		status["cached_regions"] = cache.size()
		var bytes := 0
		for region_data_v: Variant in cache.values():
			if not region_data_v is Dictionary:
				continue
			var region_data: Dictionary = region_data_v as Dictionary
			var flow_image: Image = region_data.get("flow_image") as Image
			if flow_image == null:
				continue
			bytes += flow_image.get_width() * flow_image.get_height() * 4
		status["cache_memory_bytes_estimate"] = bytes
	return status


func _publish_river_render_payloads_for_cell(grid: Vector2i, water_provider: RefCounted) -> bool:
	if water_provider == null:
		return true
	var payloads: Array = []
	if water_provider.has_method("get_water_render_payloads_for_cell_grid"):
		payloads = water_provider.call("get_water_render_payloads_for_cell_grid", grid)
	elif water_provider.has_method("get_river_render_payloads_for_cell_grid"):
		payloads = water_provider.call("get_river_render_payloads_for_cell_grid", grid)
	else:
		return true
	if payloads.is_empty():
		if _water_provider_cell_ready_for_publish(grid, water_provider):
			_apply_river_render_id_diff(grid, [])
			return true
		return false
	var next_ids: Array = []
	for payload_v: Variant in payloads:
		if not payload_v is Dictionary:
			continue
		var payload: Dictionary = payload_v as Dictionary
		var body_id_v: Variant = payload.get("body_id", &"")
		var body_id: StringName = body_id_v if body_id_v is StringName else StringName(str(body_id_v))
		if body_id == &"":
			continue
		if next_ids.has(body_id):
			continue
		next_ids.append(body_id)
		if not _river_render_nodes_by_body_id.has(body_id):
			var water_node := _create_generated_water_node(payload)
			if water_node == null:
				continue
			_set_generated_water_render_only(water_node)
			if WaterSystem and WaterSystem.has_method("add_generated_water_node"):
				var body_type_v: Variant = payload.get("body_type", &"river")
				var body_type: StringName = body_type_v if body_type_v is StringName else StringName(str(body_type_v))
				WaterSystem.call("add_generated_water_node", water_node, body_type)
				_water_render_root = WaterSystem.call("get_generated_water_root") as Node3D
			else:
				_ensure_water_render_root().add_child(water_node)
			_unregister_generated_water_from_water_registry(water_node)
			_river_render_nodes_by_body_id[body_id] = water_node
			_river_render_ref_counts[body_id] = 0
	_apply_river_render_id_diff(grid, next_ids)
	return true


func _water_provider_cell_ready_for_publish(grid: Vector2i, water_provider: RefCounted) -> bool:
	if water_provider.has_method("is_cell_grid_water_ready"):
		return bool(water_provider.call("is_cell_grid_water_ready", grid))
	if not ("_active_cell_regions" in water_provider):
		return true
	var sentinel := Vector2i(2147483647, 2147483647)
	var region_coord: Vector2i = water_provider._active_cell_regions.get(grid, sentinel)
	if region_coord == sentinel:
		return true
	if "_pending_region_tasks" in water_provider and water_provider._pending_region_tasks.has(region_coord):
		return false
	if "_region_cache" in water_provider:
		if water_provider._region_cache.has(region_coord):
			return true
		if "_pending_region_tasks" in water_provider:
			return not water_provider._pending_region_tasks.has(region_coord)
		return true
	return true


func _apply_river_render_id_diff(grid: Vector2i, next_ids: Array) -> void:
	var current_ids: Array = _cell_river_body_ids.get(grid, [])
	for body_id_v: Variant in current_ids:
		var body_id: StringName = body_id_v if body_id_v is StringName else StringName(str(body_id_v))
		if next_ids.has(body_id):
			continue
		_decrement_river_render_ref(body_id)
	for body_id_v: Variant in next_ids:
		var body_id: StringName = body_id_v if body_id_v is StringName else StringName(str(body_id_v))
		if current_ids.has(body_id):
			continue
		_river_render_ref_counts[body_id] = int(_river_render_ref_counts.get(body_id, 0)) + 1
	if next_ids.is_empty():
		_cell_river_body_ids.erase(grid)
	else:
		_cell_river_body_ids[grid] = next_ids


func _create_generated_water_node(payload: Dictionary) -> Node3D:
	var body_type_v: Variant = payload.get("body_type", &"river")
	var body_type: StringName = body_type_v if body_type_v is StringName else StringName(str(body_type_v))
	if body_type == &"lake" or body_type == &"pool":
		return _create_generated_still_water_node(payload)
	return _create_generated_river_node(payload)


func _create_generated_river_node(payload: Dictionary) -> RiverWaterBody3D:
	var points_v: Variant = payload.get("centerline_world_points", PackedVector3Array())
	var points := PackedVector3Array()
	if points_v is PackedVector3Array:
		points = points_v
	elif points_v is Array:
		for point_v: Variant in points_v:
			if point_v is Vector3:
				points.append(point_v)
	if points.size() < 2:
		return null
	var river: RiverWaterBody3D = RiverWaterBodyScript.new()
	var body_id_v: Variant = payload.get("body_id", &"generated_river")
	river.name = str(body_id_v)
	river.curve = Curve3D.new()
	var origin := points[0]
	for i in points.size():
		river.curve.add_point(points[i] - origin)
	river.point_widths.clear()
	var width := maxf(float(payload.get("mean_width_meters", 8.0)), 1.0)
	for _i in points.size():
		river.point_widths.append(width)
	river.position = origin
	river.surface_height = float(payload.get("surface_height", origin.y)) - origin.y
	river.depth = 3.0
	river.flow_speed = float(payload.get("flow_speed_meters_per_second", 1.4))
	river.length_step_m = 2.0
	river.width_subdivisions = 6
	river.water_color = Color(0.025, 0.13, 0.16, 1.0)
	var flow_image: Image = payload.get("flowmap_image") as Image
	if flow_image != null:
		river.flowmap_image = flow_image
		river.flowmap_enabled = true
	var flowmap_bounds_v: Variant = payload.get("flowmap_region_bounds", AABB())
	if flowmap_bounds_v is AABB:
		river.flowmap_region_bounds = flowmap_bounds_v
	return river


func _create_generated_still_water_node(payload: Dictionary) -> PolygonWaterVolume:
	var points_v: Variant = payload.get("polygon_world_points_xz", PackedVector2Array())
	var points := PackedVector2Array()
	if points_v is PackedVector2Array:
		points = points_v
	elif points_v is Array:
		for point_v: Variant in points_v:
			if point_v is Vector2:
				points.append(point_v)
	if points.size() < 3:
		return null
	var water: PolygonWaterVolume = PolygonWaterVolumeScript.new()
	var body_id_v: Variant = payload.get("body_id", &"generated_lake")
	water.name = str(body_id_v)
	var surface_height := float(payload.get("surface_height", 0.0))
	var origin := Vector3(points[0].x, surface_height, points[0].y)
	var local_points := PackedVector2Array()
	for point: Vector2 in points:
		local_points.append(Vector2(point.x - origin.x, point.y - origin.z))
	water.position = origin
	water.polygon_points = local_points
	water.water_surface_height = 0.0
	var depth := maxf(float(payload.get("depth", 3.0)), 0.25)
	var bounds_v: Variant = payload.get("bounds", AABB())
	if bounds_v is AABB:
		var bounds: AABB = bounds_v
		water.size = Vector3(maxf(bounds.size.x, 0.1), depth, maxf(bounds.size.z, 0.1))
	else:
		water.size.y = depth
	water.water_type = WaterVolume.WaterType.LAKE
	water.enable_waves = true
	water.wave_scale = 0.08
	water.wave_speed = 0.35
	water.roughness = 0.18
	water.clarity = 0.62
	water.flow_speed = 0.0
	water.current_strength = 0.0
	water.water_color = Color(0.03, 0.16, 0.18, 1.0)
	water.register_with_water_registry = false
	water.enable_swimming = false
	water.detection_collision_mask = 0
	return water


func _set_generated_water_render_only(water_node: Node3D) -> void:
	for property: Dictionary in water_node.get_property_list():
		if StringName(property.get("name", "")) == &"register_with_water_registry":
			water_node.set(&"register_with_water_registry", false)
			return
	water_node.set_meta(&"register_with_water_registry", false)


func _unregister_generated_water_from_water_registry(water_node: Node3D) -> void:
	if water_node == null or not is_instance_valid(water_node):
		return
	if not WaterSystem or not WaterSystem.has_method("unregister_water_body"):
		return
	if water_node.has_method("get_water_body_descriptor"):
		var descriptor: RefCounted = water_node.call("get_water_body_descriptor") as RefCounted
		if descriptor != null:
			WaterSystem.call("unregister_water_body", descriptor)


func _decrement_river_render_ref(body_id: StringName) -> void:
	var refs := int(_river_render_ref_counts.get(body_id, 0)) - 1
	if refs > 0:
		_river_render_ref_counts[body_id] = refs
		return
	_river_render_ref_counts.erase(body_id)
	var river: Node3D = _river_render_nodes_by_body_id.get(body_id, null)
	_river_render_nodes_by_body_id.erase(body_id)
	if river != null and is_instance_valid(river):
		river.queue_free()


func _release_river_render_payloads_for_cell(grid: Vector2i) -> void:
	var ids: Array = _cell_river_body_ids.get(grid, [])
	_cell_river_body_ids.erase(grid)
	for body_id_v: Variant in ids:
		var body_id: StringName = body_id_v if body_id_v is StringName else StringName(str(body_id_v))
		_decrement_river_render_ref(body_id)
	_river_render_publish_queue_set.erase(grid)
	_river_render_publish_queue.erase(grid)


## Callback for native streaming manager cell unloaded
func _on_native_cell_unloaded(grid: Vector2i) -> void:
	_log("Cell unloaded: (%d, %d) (native)" % [grid.x, grid.y])
	_release_river_render_payloads_for_cell(grid)
	if world_source != null and world_source.has_method("get_water_provider"):
		var water_provider: RefCounted = world_source.call("get_water_provider") as RefCounted
		if water_provider != null and water_provider.has_method("release_cell_grid"):
			water_provider.call("release_cell_grid", grid)

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
	if _hlod_flyby_mode:
		_log_hlod_flyby_stats.call_deferred()


func _log_hlod_flyby_stats() -> void:
	await get_tree().create_timer(5.0).timeout
	Log.info("streaming", "[HLOD flyby stats +5s]\n%s" % _cmd_hlod_stats({}))
	await get_tree().create_timer(10.0).timeout
	Log.info("streaming", "[HLOD flyby stats +15s]\n%s" % _cmd_hlod_stats({}))


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

	# Fly-camera interact press/release — bound to the `interact` action
	# (default E). Mirrors the PlayerController tap/hold discriminator so
	# the same raycaster target drives tap→interact and hold→carry.grab.
	# Only active in FLY_CAMERA mode; PlayerController handles its own.
	if _camera_mode == CameraMode.FLY_CAMERA:
		if event.is_action_pressed(&"interact"):
			_fly_on_interact_pressed()
			get_viewport().set_input_as_handled()
			return
		if event.is_action_released(&"interact"):
			_fly_on_interact_released()
			get_viewport().set_input_as_handled()
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

	# Debug: hold right-click and press left-click in fly-camera mode to throw
	# a physics ball. Keep plain left-click and Ctrl free for UI/movement.
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed \
				and mb.button_index == MOUSE_BUTTON_LEFT \
				and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) \
				and _camera_mode == CameraMode.FLY_CAMERA \
				and get_viewport().gui_get_hovered_control() == null:
			_spawn_debug_ball()
			get_viewport().set_input_as_handled()


func _spawn_debug_ball() -> void:
	if camera == null:
		return
	var ball := RigidBody3D.new()
	ball.name = "DebugBall"
	ball.mass = 5.0
	ball.collision_layer = 1
	ball.collision_mask = 1
	ball.contact_monitor = true
	ball.max_contacts_reported = 4
	ball.continuous_cd = true
	var shape := SphereShape3D.new()
	shape.radius = 0.25
	var cs := CollisionShape3D.new()
	cs.shape = shape
	ball.add_child(cs)
	var mesh := MeshInstance3D.new()
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = 0.25
	sphere_mesh.height = 0.5
	mesh.mesh = sphere_mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.3, 0.1)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.3, 0.1)
	mat.emission_energy_multiplier = 0.5
	mesh.material_override = mat
	ball.add_child(mesh)
	var spawn_xf := camera.global_transform
	spawn_xf.origin += -spawn_xf.basis.z * 1.5
	ball.global_transform = spawn_xf
	add_child(ball)
	ball.linear_velocity = -spawn_xf.basis.z * 20.0
	# DIAG 2026-04-22: verify CCD + tick rate actually applied
	_log("[color=yellow]Ball diag: continuous_cd=%s physics_ticks_per_second=%d|linvel=%.1fm/s step_dist=%.3fm[/color]" % [
		str(ball.continuous_cd), Engine.physics_ticks_per_second,
		ball.linear_velocity.length(),
		ball.linear_velocity.length() / float(Engine.physics_ticks_per_second),
	])
	# Diagnostic raycast from spawn pos straight down — if terrain collision is
	# working, we'll hit something within 500m. If not, the ball will fall
	# forever. Log result so the user doesn't have to guess.
	var space_state := get_world_3d().direct_space_state
	var ray_params := PhysicsRayQueryParameters3D.create(
		spawn_xf.origin, spawn_xf.origin + Vector3.DOWN * 500.0
	)
	ray_params.collision_mask = 1
	var hit := space_state.intersect_ray(ray_params)
	if hit.is_empty():
		_log("[color=red]Ball raycast DOWN 500m hit NOTHING — collision broken at spawn pos %s[/color]" % spawn_xf.origin)
	else:
		var hit_body: Object = hit.get("collider")
		var hit_name: String = str(hit_body.name) if hit_body and hit_body.has_method("get") else "?"
		var hit_layer: Variant = hit_body.get("collision_layer") if hit_body and hit_body.has_method("get") else "?"
		_log("[color=lime]Ball raycast hit '%s' at %s (%.1fm below, layer=%s)[/color]" % [
			hit_name, hit["position"], spawn_xf.origin.y - float(hit["position"].y), str(hit_layer)])
	# Connect body_entered so we KNOW if the ball actually hits something.
	ball.body_entered.connect(func(body: Node) -> void:
		# DIAG 2026-04-22: log impact velocity so we can tell if CCD is working.
		# Without CCD: ball hits at peak velocity (20+ m/s). With CCD: may hit at
		# sub-step velocity (can be higher or matching). Value alone isn't
		# diagnostic, but a pattern of "ball never collided, appeared below ground"
		# vs "ball collided at 22 m/s then bounced" is.
		_log("[color=lime]Ball collided with '%s' at v=%.1fm/s pos=%s[/color]" % [
			str(body.name), ball.linear_velocity.length(), ball.global_position,
		])
	)
	var timer := Timer.new()
	timer.wait_time = 15.0
	timer.one_shot = true
	timer.timeout.connect(func() -> void:
		if is_instance_valid(ball):
			_log("Ball auto-freed (15s) — final pos %s linvel %s" % [ball.global_position, ball.linear_velocity])
			ball.queue_free()
		timer.queue_free()
	)
	add_child(timer)
	timer.start()
	_log("[color=cyan]Debug ball spawned at %s[/color]" % spawn_xf.origin)


func _process(delta: float) -> void:
	if not _initialized:
		return

	# Fly-camera interact hold-threshold polling. Cheap; safe to run every
	# frame even when the press state is inactive (early-outs immediately).
	_poll_fly_interact_hold()
	_process_water_provider_async()

	# Record frame timing for profiler
	if profiler:
		profiler.record_frame(delta)

	# NOTE: cell_manager.process_async_instantiation is called by
	# native_streaming_manager._process with proper frame-budget-aware timing.
	# Do NOT call it here too — duplicate calls double the CPU cost.

	# Update interior pocket manager (door detection, eviction)
	if _pocket_manager:
		_pocket_manager.update(camera.global_position, delta)

	# Update weather rendering
	if _weather_controls:
		_weather_controls.process(delta)

	# Update ocean controls
	if _ocean_controls:
		_ocean_controls.process(delta)
		if _panels and _panels.water_status_label:
			var water_status := _ocean_controls.get_runtime_status()
			var spray_status: Dictionary = water_status.get("sea_spray", {})
			var optics_status: Dictionary = water_status.get("optics", {})
			_panels.water_status_label.text = "Water: all %s | ocean %s | rivers %s | lakes %s | medium %s | particles %s | spray %s | vis %.0fm | turb %.2f" % [
				"ON" if bool(water_status.get("all_water_enabled", true)) else "OFF",
				"ON" if bool(water_status.get("ocean_enabled", false)) else "OFF",
				"ON" if bool(water_status.get("rivers_enabled", true)) else "OFF",
				"ON" if bool(water_status.get("lakes_pools_enabled", true)) else "OFF",
				"ON" if bool(water_status.get("underwater_medium_enabled", false)) else "OFF",
				"ON" if bool(water_status.get("underwater_particles_enabled", false)) else "OFF",
				"ON" if bool(spray_status.get("enabled", false)) else "OFF",
				float(optics_status.get("visibility_m", 0.0)),
				float(optics_status.get("turbidity", 0.0)),
			]

	# Update horizon map sun direction
	if _horizon_map_manager:
		_horizon_map_manager.update_sun_direction()

	# Feed sun elevation to distant light manager for time-of-day visibility
	if native_streaming_manager and _env_controls and _env_controls.sky_manager:
		native_streaming_manager.set_sun_elevation(_env_controls.sky_manager.celestial.sun_altitude)

	# Update stats periodically
	if Engine.get_frames_drawn() % 30 == 0:
		_update_stats()
		_update_hlod_ui_status()


func _get_distant_render_end_m() -> float:
	if world_streaming_manager and world_streaming_manager.has_method("get_distant_render_end_m"):
		return float(world_streaming_manager.call("get_distant_render_end_m"))
	return float(StreamingConfig.clamp_view_distance_meters(_current_view_distance))


# ==================== Interior Transitions ====================

## Setup interior pocket manager for seamless transitions
func _setup_pocket_manager() -> void:
	_pocket_manager = InteriorPocketManagerScript.new()
	_pocket_manager.name = "InteriorPocketManager"
	add_child(_pocket_manager)

	# Find the WorldEnvironment node in scene tree. INVARIANT: at setup time,
	# `show_sky` defaults off so EnvironmentControls' `_fallback_world_env` is a
	# direct child here. IPM caches this ref for the session — must stay valid.
	# `_on_interior_transition_started` toggles sky off (which re-adds fallback
	# to tree) BEFORE IPM's env swap runs, so the cached ref is always in-tree
	# when IPM writes to `.environment`. If setup order ever changes (sky
	# enabled before pocket-manager init), IPM's ref would point to SkyManager's
	# detached WE after the toggle flip — add a re-capture path if that happens.
	var world_env: WorldEnvironment = null
	for child in get_children():
		if child is WorldEnvironment:
			world_env = child
			break

	# Find the sun (DirectionalLight3D) for interior cull mask management
	var sun: DirectionalLight3D = _find_sun_light()

	var transition_provider: RefCounted = null
	if world_source != null and world_source.has_method("get_transition_provider"):
		transition_provider = world_source.call("get_transition_provider") as RefCounted
	_pocket_manager.initialize(cell_manager, world_env, camera, sun, transition_provider)

	# Hide Terrain3D during interior transitions — camera at Y=-500 causes
	# Terrain3D GDExtension to crash (clipmap generation at underground position)
	_pocket_manager.transition_started.connect(_on_interior_transition_started)
	_pocket_manager.transition_completed.connect(_on_interior_transition_completed)

	# Set player body for physics layer swapping during transitions
	if player_controller:
		_pocket_manager.set_player_body(player_controller)

	# Create door prompt label
	_create_door_prompt()

	# Install the activation handler before registering or reconnecting any
	# placed doors. Existing doors may have spawned before this setup path.
	if cell_manager:
		cell_manager.set_door_activated_handler(_on_door_interactable_activated)

	# Register doors from already-loaded cells
	if world_streaming_manager:
		var loaded: Array[Vector2i] = world_streaming_manager.get_loaded_cell_coordinates()
		for grid: Vector2i in loaded:
			_register_exterior_doors_for_grid(grid)

	# Reconnect any DoorInteractable nodes that were published before the
	# handler existed, then hand the streaming manager reference to carry.
	_reconnect_existing_door_interactables()
	if _carry_controller and world_streaming_manager:
		_carry_controller.set_streaming_manager(world_streaming_manager)
	if _fly_carry_controller and world_streaming_manager:
		_fly_carry_controller.set_streaming_manager(world_streaming_manager)

	Log.info("streaming", "Interior pocket manager initialized")


func _reconnect_existing_door_interactables() -> void:
	if not cell_manager or not cell_manager.has_method("reconnect_door_activated_handlers"):
		return
	var count: int = int(cell_manager.call(
		"reconnect_door_activated_handlers",
		self,
		Callable(self, "_on_door_interactable_activated")
	))
	if count > 0:
		Log.info("streaming", "Reconnected %d existing DoorInteractable handlers" % count)


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
## Fires when a ray-cast DoorInteractable's `interact()` method runs.
## The adapter emits the placed-door instance key so duplicate base DOOR
## records route to the correct transition descriptor.
func _on_door_interactable_activated(door_instance_key: String, _door_record: Variant, _player: Node3D) -> void:
	if not _pocket_manager:
		return
	if _pocket_manager.has_method("is_transitioning") and bool(_pocket_manager.call("is_transitioning")):
		Log.debug("streaming", "[DOOR_INTERACT] ignoring '%s' while transition is active" % door_instance_key)
		return
	var door: Variant = _pocket_manager.get_door_info_by_instance_key(StringName(door_instance_key))
	if door == null:
		Log.warn("streaming", "[DOOR_INTERACT] no DoorInfo for instance key '%s' - ignoring tap" % door_instance_key)
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


## Record the press time; reset hold flag. Poll in _process decides when
## the press crosses the hold threshold and fires the grab path.
func _fly_on_interact_pressed() -> void:
	if _dialogue_session and _dialogue_session.is_any_panel_open():
		return
	_fly_interact_press_time_msec = Time.get_ticks_msec()
	_fly_interact_hold_emitted = false


## Discriminate tap vs post-hold release. Same rules as
## PlayerController._on_interact_released. Tap → interact(); release after
## hold → carry_controller.release().
func _fly_on_interact_released() -> void:
	if _fly_interact_press_time_msec < 0:
		return
	var held_msec := Time.get_ticks_msec() - _fly_interact_press_time_msec
	_fly_interact_press_time_msec = -1
	if _dialogue_session and _dialogue_session.is_any_panel_open():
		_fly_interact_hold_emitted = false
		return
	if _fly_interact_hold_emitted:
		_fly_carry_release()
	elif held_msec < int(FLY_INTERACT_HOLD_THRESHOLD_S * 1000):
		_fly_camera_interact()
	else:
		# Past threshold but poll didn't fire (low fps race). Fallthrough
		# as a tap so the event isn't silently dropped.
		_fly_camera_interact()


## Polled from _process. Fires hold-begin once when the press crosses the
## threshold; that routes to the carry controller to grab whatever the
## fly raycaster is currently targeting.
func _poll_fly_interact_hold() -> void:
	if _camera_mode != CameraMode.FLY_CAMERA:
		return
	if _fly_interact_press_time_msec < 0 or _fly_interact_hold_emitted:
		return
	if _dialogue_session and _dialogue_session.is_any_panel_open():
		return
	var held_msec := Time.get_ticks_msec() - _fly_interact_press_time_msec
	if held_msec >= int(FLY_INTERACT_HOLD_THRESHOLD_S * 1000):
		_fly_interact_hold_emitted = true
		_fly_carry_grab()


## Route the fly raycaster's current target to the CarryController. Refuses
## silently if the target isn't a carryable wrapper (NPC, door, etc.) — the
## controller's own validation handles that.
func _fly_carry_grab() -> void:
	if _fly_carry_controller == null or _fly_raycaster == null:
		return
	var target: Interactable = _fly_raycaster.get_current_target()
	if target == null:
		Log.info("interaction", "[FLY_GRAB] hold fired, no target under crosshair")
		return
	Log.info("interaction", "[FLY_GRAB] try_grab target=%s" % target.name)
	_fly_carry_controller.try_grab(target)


## Tell the fly-mode carry controller to release whatever it's holding.
func _fly_carry_release() -> void:
	if _fly_carry_controller == null:
		return
	if not _fly_carry_controller.has_method("release"):
		return
	_fly_carry_controller.release()


## Fly camera interaction — reads the fly raycaster's current target
## and calls interact(). Replaces the old proximity-based door activation.
## The fly camera acts as the "player" node for interact() calls.
func _fly_camera_interact() -> void:
	if _fly_raycaster == null:
		Log.info("interaction", "[FLY_INTERACT] no raycaster wired")
		return
	# Modal gate — don't interact while a panel is open
	if _dialogue_session and _dialogue_session.is_any_panel_open():
		return
	# Carry gate — don't tap-interact while holding something.
	# Mirrors PlayerController._emit_interact_tap (line 694).
	if _fly_carry_controller != null and _fly_carry_controller.is_carrying():
		return
	var target: Interactable = _fly_raycaster.get_current_target()
	if target == null:
		Log.info("interaction", "[FLY_INTERACT] E pressed, no target under crosshair (cam=%s fwd=%s)" % [
			fly_camera.global_position, -fly_camera.global_transform.basis.z])
		return
	Log.info("interaction", "[FLY_INTERACT] target=%s prompt='%s'" % [target.name, target.get_prompt_text()])
	target.interact(fly_camera)


## Shared door transition routing — used by the ray-cast DoorInteractable
## path. Branches on `_pocket_manager.is_inside()` to pick
## enter / exit / interior-to-interior.
func _activate_door(door: Variant) -> void:
	if not _pocket_manager or door == null:
		return
	if _pocket_manager.has_method("is_transitioning") and bool(_pocket_manager.call("is_transitioning")):
		Log.debug("streaming", "[DOOR_ACTIVATE] ignoring '%s' while transition is active" % door.instance_key)
		return

	Log.info("streaming", "[DOOR_ACTIVATE] Door: '%s' -> '%s', inside=%s" % [
		door.instance_key, door.target_cell_name, _pocket_manager.is_inside()])

	if _pocket_manager.is_inside():
		if door.has_method("has_interior_target") and bool(door.call("has_interior_target")):
			await _pocket_manager.transition_interior_to_interior(door)
		else:
			# Exit: teleport back to surface, then unfreeze exterior tracking.
			await _pocket_manager.exit_to_exterior(door)
			_set_world_tracking_frozen(false)
			_log("[color=cyan]Exited to exterior[/color]")
	else:
		# Freeze exterior tracking before enter so cells do not unload when
		# the camera moves to the pocket. Async work keeps draining.
		_set_world_tracking_frozen(true)
		var success: bool = await _pocket_manager.enter_interior(door)
		if success:
			_log("[color=cyan]Entered interior: %s[/color]" % door.target_cell_name)
		else:
			# Failed — resume exterior tracking.
			_set_world_tracking_frozen(false)
			Log.error("streaming", "[DOOR_ACTIVATE] enter_interior FAILED for '%s'" % door.target_cell_name)


## Freeze/resume exterior tracking while keeping async streaming work alive.
## CRITICAL: Must be called before classic interior transitions. Without this,
## the streaming manager would use the pocket camera position as the outdoor
## anchor and unload the exterior mid-transition.
func _set_world_tracking_frozen(frozen: bool) -> void:
	if not world_streaming_manager:
		return
	var anchor := camera.global_position if camera else Vector3.INF
	if frozen and world_streaming_manager.has_method("set_world_tracking_frozen"):
		world_streaming_manager.call("set_world_tracking_frozen", true, anchor)
	elif not frozen and world_streaming_manager.has_method("commit_streaming_origin") and anchor != Vector3.INF:
		world_streaming_manager.call("commit_streaming_origin", anchor)
	elif world_streaming_manager.has_method("set_world_tracking_frozen"):
		world_streaming_manager.call("set_world_tracking_frozen", false, anchor)
	Log.info("streaming", "[STREAMING] world_tracking_frozen=%s" % frozen)


## Tracks whether we were the ones who disabled sky on interior entry, so we
## only re-enable on exit if we actually toggled it off ourselves.
var _sky_was_on_pre_interior: bool = false

## Tracks fallback directional light visibility before interior entry, so we
## can restore it on exit when sky toggle isn't responsible for it (the case
## where sky was already off when we entered).
var _fallback_light_was_visible_pre_interior: bool = false


## Hide Terrain3D when entering interior — camera at Y=-500 causes
## Terrain3D GDExtension to crash (clipmap generation at underground position).
## Also disable SkyManager in classic mode so the pocket manager's interior
## Environment swap actually applies (SkyManager owns its own WorldEnvironment
## and would otherwise override the interior env, leaking clouds/sun/sky fog
## into the interior and wasting GPU on offscreen cloud rendering).
## And disable the fallback DirectionalLight3D so exterior sun direction
## doesn't leak into the interior as a second fake sun (hard cut-over — the
## interior is lit entirely by its baked point/spot lights).
func _on_interior_transition_started(_cell_name: String) -> void:
	if terrain_3d:
		terrain_3d.visible = false
		Log.info("streaming", "[TRANSITION] Terrain3D hidden (entering interior)")

	# Seamless mode keeps the sky visible (used for windows/portal continuity).
	# Only the classic fade-to-black path wants the sky hard-disabled.
	if _pocket_manager and _pocket_manager.seamless_enabled:
		return
	if _ocean_controls:
		_ocean_controls.set_world_space_ocean_visible(false)
	if _env_controls and _env_controls.show_sky:
		_sky_was_on_pre_interior = true
		_env_controls.on_show_sky_toggled(false)
		Log.info("streaming", "[TRANSITION] Sky disabled (entering interior)")

	# Always kill the fallback directional light on interior entry, regardless
	# of whether sky was on (toggling sky off would have turned it on; sky
	# already off means it was on as the sole exterior light). Interior wants
	# zero directional light — matches OpenMW interior handling.
	if _env_controls:
		var fb_light: DirectionalLight3D = _env_controls.get_fallback_light()
		if fb_light:
			_fallback_light_was_visible_pre_interior = fb_light.visible
			fb_light.visible = false


## Restore Terrain3D and sky when exiting to exterior. `is_inside()` is still
## true on interior->interior hops, so we only restore on a real exit.
func _on_interior_transition_completed(cell_name: String) -> void:
	if not _pocket_manager or not _pocket_manager.is_inside():
		if terrain_3d:
			terrain_3d.visible = true
			Log.info("streaming", "[TRANSITION] Terrain3D restored (exited to exterior)")
		if _ocean_controls:
			_ocean_controls.set_world_space_ocean_visible(true)
		if _sky_was_on_pre_interior:
			# `on_show_sky_toggled(true)` handles fallback_light visibility
			# (sets it false when sky comes back on) — don't double-manage it.
			if _env_controls:
				_env_controls.on_show_sky_toggled(true)
			_sky_was_on_pre_interior = false
			Log.info("streaming", "[TRANSITION] Sky restored (exited to exterior)")
		else:
			# Sky was already off — the sky toggle isn't running, so manually
			# restore the fallback light we disabled on entry.
			if _env_controls:
				var fb_light: DirectionalLight3D = _env_controls.get_fallback_light()
				if fb_light:
					fb_light.visible = _fallback_light_was_visible_pre_interior


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
		_ocean_controls.set_world_space_ocean_visible(false)
	if world_streaming_manager:
		world_streaming_manager.set_process(false)


## Delegate: restore world elements when switching to world mode
func _on_browser_switch_to_world() -> void:
	if terrain_3d:
		terrain_3d.visible = true
	if _ocean_controls:
		_ocean_controls.set_world_space_ocean_visible(true)
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
