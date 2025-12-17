## World Explorer - Complete Morrowind world exploration tool
##
## Features:
## - WORLD MODE: Infinite terrain streaming with multi-region support
##   - Terrain3D for terrain LOD and streaming
##   - OWDB for object streaming (statics, lights, NPCs, etc.)
##   - Free-fly camera navigation
##
## - INTERIOR MODE: Browse and explore interior cells
##   - Cell browser with search
##   - Interior/exterior filtering
##   - Quick load for common locations
##
## Controls:
## - Press F3 to toggle performance overlay
## - Press F4 to dump detailed profiling report
## - Press TAB to toggle between World and Interior modes
## - Use +/- to adjust view distance
extends Node3D

# Preload dependencies
const WorldStreamingManagerScript := preload("res://src/core/world/world_streaming_manager.gd")
const TerrainManagerScript := preload("res://src/core/world/terrain_manager.gd")
const TerrainTextureLoaderScript := preload("res://src/core/world/terrain_texture_loader.gd")
const CellManagerScript := preload("res://src/core/world/cell_manager.gd")
const ObjectPoolScript := preload("res://src/core/world/object_pool.gd")
const CS := preload("res://src/core/coordinate_system.gd")
const PerformanceProfilerScript := preload("res://src/core/world/performance_profiler.gd")
const OceanManagerScript := preload("res://src/core/water/ocean_manager.gd")
const BackgroundProcessorScript := preload("res://src/core/streaming/background_processor.gd")
# Note: HardwareDetection is accessed via class_name, no preload needed

# Pre-processed terrain data directory
const TERRAIN_DATA_DIR := "user://terrain_data/"

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
var _show_ocean_toggle: CheckBox = null
var _water_quality_btn: OptionButton = null
var _show_models: bool = false  # Default OFF for performance
var _show_ocean: bool = false   # Default OFF for performance

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
var world_streaming_manager: Node3D = null  # WorldStreamingManager
var terrain_manager: RefCounted = null  # TerrainManager
var texture_loader: RefCounted = null  # TerrainTextureLoader
var cell_manager: RefCounted = null  # CellManager
var profiler: RefCounted = null  # PerformanceProfiler
var ocean_manager: Node = null  # OceanManager
var background_processor: Node = null  # BackgroundProcessor for async loading

# Camera controls
var camera_speed: float = 200.0
var mouse_sensitivity: float = 0.003
var mouse_captured: bool = false

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


func _ready() -> void:
	# Initialize managers
	terrain_manager = TerrainManagerScript.new()
	texture_loader = TerrainTextureLoaderScript.new()
	cell_manager = CellManagerScript.new()
	cell_manager.load_npcs = true   # Enable NPCs
	cell_manager.load_creatures = true

	# Initialize object pool for frequently used models
	cell_manager.init_object_pool()

	# Initialize profiler
	profiler = PerformanceProfilerScript.new()
	profiler.start_session()

	# Connect quick teleport buttons
	seyda_neen_btn.pressed.connect(func(): _teleport_to_cell(-2, -9))
	balmora_btn.pressed.connect(func(): _teleport_to_cell(-3, -2))
	vivec_btn.pressed.connect(func(): _teleport_to_cell(5, -6))
	origin_btn.pressed.connect(func(): _teleport_to_cell(0, 0))

	# Connect preprocess button
	preprocess_btn.pressed.connect(_on_preprocess_pressed)

	# Setup interior cell browser
	_setup_interior_browser()

	# Setup visibility toggles
	_setup_visibility_toggles()

	# Get Morrowind data path
	_data_path = SettingsManager.get_data_path()
	if _data_path.is_empty():
		_hide_loading()
		_log("[color=red]ERROR: Morrowind data path not configured. Set MORROWIND_DATA_PATH environment variable or use settings UI.[/color]")
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

	# Setup ocean system
	await _update_loading(80, "Setting up ocean...")
	_setup_ocean()

	# Create and setup WorldStreamingManager (but don't start tracking yet)
	await _update_loading(85, "Setting up streaming system...")
	_setup_world_streaming_manager(false)  # Pass false to delay tracking

	# Done
	await _update_loading(100, "Ready!")
	await get_tree().create_timer(0.3).timeout
	_hide_loading()

	_initialized = true
	_log("[color=green]World streaming initialized![/color]")
	_log("Use ZQSD to move, Right-click to look")
	_log("Cells stream automatically based on camera position")

	# First teleport camera to Seyda Neen BEFORE starting to track
	_teleport_to_cell(-2, -9)

	# NOW start tracking the camera - terrain/cells will generate around Seyda Neen
	world_streaming_manager.set_tracked_node(camera)


func _check_preprocessed_terrain() -> void:
	# Check for pre-processed terrain data
	var dir := DirAccess.open(TERRAIN_DATA_DIR)
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

	# Configure the single Terrain3D node
	# Terrain3D handles up to 1024 regions (32x32 grid), each up to 2048m
	# This gives us 65km x 65km max terrain - far more than Vvardenfell needs
	if not terrain_3d:
		_log("[color=red]ERROR: Terrain3D node not found in scene[/color]")
		return

	# Calculate vertex spacing: MW cell = 117m with 64 vertices = 1.83m per vertex
	var vertex_spacing := CS.CELL_SIZE_GODOT / 64.0
	terrain_3d.vertex_spacing = vertex_spacing

	# Use region_size of 256 to fit 4x4 MW cells per Terrain3D region
	# Each MW cell = 64 vertices (cropped from 65), so 4 cells × 64 = 256 vertices
	# 32 regions × 4 cells × 117m = ~15km coverage per axis
	# This covers cells from -64 to +63 in each direction - enough for all of Vvardenfell!
	@warning_ignore("int_as_enum_without_cast", "int_as_enum_without_match")
	terrain_3d.change_region_size(256)

	# Configure mesh LOD settings for performance
	# mesh_lods: 7 is default, more LODs = smoother distance transitions
	# mesh_size: 48 is default, larger = fewer draw calls but more complex meshes
	terrain_3d.mesh_lods = 7
	terrain_3d.mesh_size = 48

	# Setup material
	if not terrain_3d.material:
		terrain_3d.set_material(Terrain3DMaterial.new())
	terrain_3d.material.show_checkered = false

	# Setup assets and load textures
	if not terrain_3d.assets:
		terrain_3d.set_assets(Terrain3DAssets.new())

	# Load terrain textures
	var textures_loaded: int = texture_loader.load_terrain_textures(terrain_3d.assets)
	_log("Loaded %d terrain textures" % textures_loaded)

	# Configure terrain manager to use proper texture slot mapping
	terrain_manager.set_texture_slot_mapper(texture_loader)

	_log("Terrain3D configured: region_size=256 (4x4 cells/region), vertex_spacing=%.3f" % vertex_spacing)


func _load_preprocessed_terrain() -> void:
	# Load pre-processed terrain data from disk
	if not terrain_3d or not terrain_3d.data:
		_log("[color=yellow]Warning: Terrain3D not ready for loading preprocessed data[/color]")
		return

	var global_path := ProjectSettings.globalize_path(TERRAIN_DATA_DIR)
	if DirAccess.dir_exists_absolute(global_path):
		terrain_3d.data.load_directory(global_path)
		_log("Loaded preprocessed terrain from %s" % TERRAIN_DATA_DIR)
	else:
		_log("[color=yellow]Preprocessed terrain directory not found[/color]")


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

	# Create a container for the toggles
	var toggle_container := HBoxContainer.new()
	toggle_container.name = "VisibilityToggles"

	# Create "Show Models" checkbox
	_show_models_toggle = CheckBox.new()
	_show_models_toggle.text = "Models"
	_show_models_toggle.button_pressed = _show_models
	_show_models_toggle.toggled.connect(_on_show_models_toggled)
	toggle_container.add_child(_show_models_toggle)

	# Create "Show Ocean" checkbox
	_show_ocean_toggle = CheckBox.new()
	_show_ocean_toggle.text = "Ocean"
	_show_ocean_toggle.button_pressed = _show_ocean
	_show_ocean_toggle.toggled.connect(_on_show_ocean_toggled)
	toggle_container.add_child(_show_ocean_toggle)

	# Create water quality dropdown
	_water_quality_btn = OptionButton.new()
	_water_quality_btn.add_item("Auto", -1)
	_water_quality_btn.add_item("Ultra Low", 0)
	_water_quality_btn.add_item("Low", 1)
	_water_quality_btn.add_item("Medium", 2)
	_water_quality_btn.add_item("High", 3)
	_water_quality_btn.selected = 0  # Auto by default
	_water_quality_btn.item_selected.connect(_on_water_quality_changed)
	_water_quality_btn.tooltip_text = "Water quality level (Auto detects GPU)"
	toggle_container.add_child(_water_quality_btn)

	# Insert after the quick buttons (before preprocess button)
	var preprocess_idx := preprocess_btn.get_index() if preprocess_btn else vbox.get_child_count()
	vbox.add_child(toggle_container)
	vbox.move_child(toggle_container, preprocess_idx)


## Toggle models visibility
func _on_show_models_toggled(enabled: bool) -> void:
	_show_models = enabled

	# Toggle object loading in WorldStreamingManager
	if world_streaming_manager:
		world_streaming_manager.load_objects = enabled

		# Hide/show existing loaded cell objects
		for cell_grid in world_streaming_manager.get_loaded_cell_coordinates():
			var cell_node: Node3D = world_streaming_manager.get_loaded_cell(cell_grid.x, cell_grid.y)
			if cell_node:
				cell_node.visible = enabled

	_log("Models: %s" % ("ON" if enabled else "OFF"))
	_update_stats()


## Toggle ocean visibility
func _on_show_ocean_toggled(enabled: bool) -> void:
	_show_ocean = enabled

	# Use local ocean_manager reference
	if ocean_manager and ocean_manager.has_method("set_enabled"):
		ocean_manager.set_enabled(enabled)

	_log("Ocean: %s" % ("ON" if enabled else "OFF"))
	_update_stats()


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

	for key in ESMManager.lands:
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

	# Save to disk
	var global_path := ProjectSettings.globalize_path(TERRAIN_DATA_DIR)
	DirAccess.make_dir_recursive_absolute(global_path)
	terrain_3d.data.save_directory(global_path)

	_log("[color=green]Terrain preprocessing complete![/color]")
	_log("  Processed: %d combined regions (4x4 cells each)" % processed)
	_log("  Skipped: %d regions (no height data)" % skipped)
	_log("  Saved to: %s" % TERRAIN_DATA_DIR)

	_using_preprocessed = true
	preprocess_btn.disabled = false
	_update_preprocess_status()


## Setup the ocean water system
func _setup_ocean() -> void:
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
	if camera:
		ocean_manager.set_camera(camera)

	# Set terrain reference if available (for shore mask)
	if terrain_3d:
		ocean_manager.set_terrain(terrain_3d)

	# Start disabled by default (user can toggle on)
	ocean_manager.set_enabled(_show_ocean)

	_log("Ocean system initialized (default: %s, quality: %s)" % [
		"ON" if _show_ocean else "OFF",
		ocean_manager.get_water_quality_name()
	])


func _setup_world_streaming_manager(start_tracking: bool = true) -> void:
	# Create WorldStreamingManager
	world_streaming_manager = Node3D.new()
	world_streaming_manager.set_script(WorldStreamingManagerScript)
	world_streaming_manager.name = "WorldStreamingManager"

	# Configure
	world_streaming_manager.view_distance_cells = _current_view_distance
	world_streaming_manager.load_objects = _show_models  # Respect default setting
	world_streaming_manager.debug_enabled = true

	# WorldStreamingManager handles terrain with single Terrain3D
	world_streaming_manager.load_terrain = true
	# Enable on-the-fly terrain generation when no pre-processed data exists
	world_streaming_manager.generate_terrain_on_fly = not _using_preprocessed

	# OWDB configuration for Morrowind objects
	# Use typed array to match the @export Array[float] type
	var chunk_sizes: Array[float] = [8.0, 16.0, 64.0]
	world_streaming_manager.owdb_chunk_sizes = chunk_sizes
	world_streaming_manager.owdb_chunk_load_range = 3
	world_streaming_manager.owdb_batch_time_limit_ms = 5.0

	add_child(world_streaming_manager)

	# Connect signals
	world_streaming_manager.cell_loaded.connect(_on_cell_loaded)
	world_streaming_manager.cell_unloaded.connect(_on_cell_unloaded)

	# Connect terrain generation signal for logging
	if world_streaming_manager.has_signal("terrain_region_loaded"):
		world_streaming_manager.terrain_region_loaded.connect(_on_terrain_region_loaded)

	# Provide managers
	world_streaming_manager.set_cell_manager(cell_manager)
	world_streaming_manager.set_terrain_manager(terrain_manager)
	world_streaming_manager.set_terrain_3d(terrain_3d)
	if background_processor:
		world_streaming_manager.set_background_processor(background_processor)

	# Only start tracking if requested (allows teleporting BEFORE streaming starts)
	if start_tracking:
		world_streaming_manager.set_tracked_node(camera)

	# Initialize after all configuration is set
	world_streaming_manager.initialize()

	_log("WorldStreamingManager created and configured")
	if _using_preprocessed:
		_log("Using pre-processed terrain data")
	else:
		_log("[color=cyan]Using on-the-fly terrain generation[/color]")


func _on_terrain_region_loaded(region: Vector2i) -> void:
	_log("Terrain generated: (%d, %d)" % [region.x, region.y])
	_update_stats()


func _on_cell_loaded(grid: Vector2i, node: Node3D) -> void:
	var obj_count := node.get_child_count()
	_log("Cell loaded: (%d, %d) - %d objects" % [grid.x, grid.y, obj_count])

	# Record cell load in profiler
	if profiler and world_streaming_manager:
		var stats: Dictionary = world_streaming_manager.get_stats()
		profiler.record_cell_load(stats.get("load_time_ms", 0.0), obj_count)

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

	camera.position = Vector3(world_x, height + 100.0, world_z + 50.0)
	camera.look_at(Vector3(world_x, height, world_z))
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
		draw_calls = int(render.draw_calls)
		primitives = int(render.primitives)
		var mem: Dictionary = profiler.get_memory_stats()
		mem_mb = float(mem.static_memory_mb)
		var percentiles: Dictionary = profiler.get_frame_time_percentiles()
		p95_ms = float(percentiles.p95)

	# Get terrain stats
	var total_regions := 0
	if terrain_3d and terrain_3d.data:
		total_regions = terrain_3d.data.get_region_count()

	var async_pending: int = stats.get("async_pending", 0)
	var inst_queue: int = stats.get("instantiation_queue", 0)

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
Models [M]: %s | Ocean [O]: %s
Water quality: %s

[b]Camera[/b]
Cell: (%d, %d)

[color=gray]F3: Overlay | F4: Report | M/O: Toggle[/color]""" % [
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
		"ON" if _show_ocean else "OFF",
		ocean_manager.get_water_quality_name() if ocean_manager else "N/A",
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


# ==================== Camera Controls ====================

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
				mouse_captured = true
			else:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
				mouse_captured = false

	if event is InputEventMouseMotion and mouse_captured:
		camera.rotate_y(-event.relative.x * mouse_sensitivity)
		camera.rotate_object_local(Vector3.RIGHT, -event.relative.y * mouse_sensitivity)

	# Hotkeys
	if event is InputEventKey and event.pressed:
		match event.keycode:
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
			KEY_O:  # Toggle ocean
				if _show_ocean_toggle:
					_show_ocean_toggle.button_pressed = not _show_ocean_toggle.button_pressed


func _process(delta: float) -> void:
	if not _initialized:
		return

	# Record frame timing for profiler
	if profiler:
		profiler.record_frame(delta)

	# Process async cell instantiation with time budget (2ms)
	if cell_manager:
		cell_manager.process_async_instantiation(2.0)

	# Update stats periodically
	if Engine.get_frames_drawn() % 30 == 0:
		_update_stats()

	if not mouse_captured:
		return

	# ZQSD movement (AZERTY layout)
	var input_dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_Z):
		input_dir.z -= 1
	if Input.is_key_pressed(KEY_S):
		input_dir.z += 1
	if Input.is_key_pressed(KEY_Q):
		input_dir.x -= 1
	if Input.is_key_pressed(KEY_D):
		input_dir.x += 1
	if Input.is_key_pressed(KEY_SPACE):
		input_dir.y += 1
	if Input.is_key_pressed(KEY_SHIFT):
		input_dir.y -= 1

	var speed := camera_speed
	if Input.is_key_pressed(KEY_CTRL):
		speed *= 3.0

	if input_dir != Vector3.ZERO:
		var move_dir := camera.global_transform.basis * input_dir.normalized()
		camera.position += move_dir * speed * delta


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
		interior_filter_btn.pressed.connect(func(): _set_cell_filter("interior"))

	if exterior_filter_btn:
		exterior_filter_btn.pressed.connect(func(): _set_cell_filter("exterior"))

	if all_filter_btn:
		all_filter_btn.pressed.connect(func(): _set_cell_filter("all"))

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

	for cell_id in ESMManager.cells:
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
	_all_cells.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["is_interior"] != b["is_interior"]:
			return a["is_interior"]  # Interiors first
		if a["is_interior"]:
			return a["name"].naturalnocasecmp_to(b["name"]) < 0
		else:
			if a["grid_x"] != b["grid_x"]:
				return a["grid_x"] < b["grid_x"]
			return a["grid_y"] < b["grid_y"]
	)

	_log("Built cell list: %d cells (%d interior, %d exterior)" % [
		_all_cells.size(),
		_all_cells.filter(func(c: Dictionary): return c["is_interior"]).size(),
		_all_cells.filter(func(c: Dictionary): return not c["is_interior"]).size()
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
			var name_lower: String = cell_info["name"].to_lower()
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
		cell_node = cell_manager.load_exterior_cell(cell_info["grid_x"], cell_info["grid_y"])

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

	for ref in cell.references:
		var pos := CS.vector_to_godot(ref.position)
		center += pos
		count += 1

	if count > 0:
		center /= count

	# Position camera above center, looking down slightly
	camera.position = center + Vector3(0, 300, 500)
	camera.look_at(center)

	_log("Camera positioned at: %s" % camera.position)


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

	if report.materials and not report.materials.is_empty():
		_log("")
		_log("[b]Materials[/b]")
		_log("  Unique materials: %d" % report.materials.get("cached_materials", 0))
		_log("  Cache hits: %d" % report.materials.get("cache_hits", 0))
		_log("  Hit rate: %.1f%%" % (report.materials.get("hit_rate", 0.0) * 100.0))

	if report.textures and not report.textures.is_empty():
		_log("")
		_log("[b]Textures[/b]")
		_log("  Loaded: %d" % report.textures.get("textures_loaded", 0))
		_log("  Cache hits: %d" % report.textures.get("cache_hits", 0))

	# Add object pool stats
	if cell_manager:
		var cell_stats: Dictionary = cell_manager.get_stats()
		if cell_stats.get("pool_available", 0) > 0 or cell_stats.get("pool_in_use", 0) > 0:
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

	if not report.slowest_models.is_empty():
		_log("")
		_log("[b]Slowest Models[/b]")
		for model in report.slowest_models:
			_log("  %.2f ms - %s (x%d)" % [model.avg_ms, model.path.get_file(), model.count])

	_log("[b]==============================[/b]")

	# Also print full report to console for easy copying
	print("\n" + JSON.stringify(report, "  "))


## Pre-warm the BSA extraction cache with commonly used files
## This dramatically reduces cell loading time by having common models/textures in memory
func _prewarm_bsa_cache() -> void:
	var common_models := ObjectPoolScript.identify_common_models(null)
	var prewarmed := 0

	for model_path in common_models:
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

	for tex_path in common_textures:
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
