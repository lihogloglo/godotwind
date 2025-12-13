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
const MWCoords := preload("res://src/core/morrowind_coords.gd")
const PerformanceProfilerScript := preload("res://src/core/world/performance_profiler.gd")
const MultiTerrainManagerScript := preload("res://src/core/world/multi_terrain_manager.gd")
const TerrainPreprocessorScript := preload("res://src/tools/terrain_preprocessor.gd")

# Pre-processed terrain data directories
const TERRAIN_DATA_DIR := "user://terrain_data/"          # Single-terrain mode
const TERRAIN_CHUNKS_DIR := "user://terrain_chunks/"      # Multi-terrain mode

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
var multi_terrain_manager: Node3D = null    # MultiTerrainManager (for infinite worlds)
var terrain_manager: RefCounted = null  # TerrainManager
var texture_loader: RefCounted = null  # TerrainTextureLoader
var cell_manager: RefCounted = null  # CellManager
var profiler: RefCounted = null  # PerformanceProfiler

# Camera controls
var camera_speed: float = 200.0
var mouse_sensitivity: float = 0.003
var mouse_captured: bool = false

# State
var _data_path: String = ""
var _initialized: bool = false
var _using_preprocessed: bool = false
var _using_multi_terrain: bool = false  # True = multi-terrain chunked mode
var _perf_overlay_visible: bool = true
var _current_view_distance: int = 5

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
		_log("[color=cyan]Using infinite terrain with on-the-fly generation.[/color]")
		_log("(For better performance, click 'Preprocess ALL Terrain')")
		await _update_loading(70, "Initializing infinite terrain...")
		_init_multi_terrain_on_the_fly()

	# Create and setup WorldStreamingManager
	await _update_loading(85, "Setting up streaming system...")
	_setup_world_streaming_manager()

	# Done
	await _update_loading(100, "Ready!")
	await get_tree().create_timer(0.3).timeout
	_hide_loading()

	_initialized = true
	_log("[color=green]World streaming initialized![/color]")
	_log("Use ZQSD to move, Right-click to look")
	_log("Cells stream automatically based on camera position")

	# Start at Seyda Neen
	_teleport_to_cell(-2, -9)


func _check_preprocessed_terrain() -> void:
	# First check for multi-terrain (chunked) data - preferred for large worlds
	var chunks_dir := DirAccess.open(TERRAIN_CHUNKS_DIR)
	if chunks_dir:
		var chunk_count := 0
		chunks_dir.list_dir_begin()
		var dir_name := chunks_dir.get_next()
		while dir_name != "":
			if chunks_dir.current_is_dir() and dir_name.begins_with("chunk_"):
				chunk_count += 1
			dir_name = chunks_dir.get_next()
		chunks_dir.list_dir_end()

		if chunk_count > 0:
			_using_preprocessed = true
			_using_multi_terrain = true
			_log("Found %d terrain chunks (multi-terrain mode)" % chunk_count)
			_update_preprocess_status()
			return

	# Fall back to single-terrain data
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
			_using_multi_terrain = false
			_log("Found %d pre-processed terrain regions (single-terrain mode)" % count)

	_update_preprocess_status()


func _init_terrain3d() -> void:
	if not ClassDB.class_exists("Terrain3DData"):
		_log("[color=red]ERROR: Terrain3D addon not loaded[/color]")
		return

	if _using_multi_terrain:
		# Multi-terrain mode: use MultiTerrainManager instead of single Terrain3D
		_init_multi_terrain()
		return

	# Single-terrain mode: configure the scene's Terrain3D node
	if not terrain_3d:
		_log("[color=red]ERROR: Terrain3D node not found[/color]")
		return

	# Terrain3DData is read-only and created automatically by Terrain3D
	# Create material/assets if needed
	if not terrain_3d.material:
		terrain_3d.set_material(Terrain3DMaterial.new())

	if not terrain_3d.assets:
		terrain_3d.set_assets(Terrain3DAssets.new())

	# Configure for Morrowind - must match terrain_preprocessor settings
	# Terrain3D has a 32x32 region limit (-16 to +15 indices)
	# With region_size=64, each region = one MW cell, range -16 to +15
	# This covers most of Vvardenfell but clips edges (Solstheim at Y>15 won't appear)
	var mw_cell_size_godot := MWCoords.CELL_SIZE_GODOT
	@warning_ignore("int_as_enum_without_cast", "int_as_enum_without_match")
	terrain_3d.change_region_size(64)
	var vertex_spacing := mw_cell_size_godot / 64.0
	terrain_3d.vertex_spacing = vertex_spacing

	_log("Terrain3D configured: region_size=64, vertex_spacing=%.4f" % vertex_spacing)


func _init_multi_terrain() -> void:
	# Hide the single Terrain3D node - we'll use MultiTerrainManager instead
	if terrain_3d:
		terrain_3d.visible = false

	# Create MultiTerrainManager
	multi_terrain_manager = Node3D.new()
	multi_terrain_manager.set_script(MultiTerrainManagerScript)
	multi_terrain_manager.name = "MultiTerrainManager"

	# Configure for Morrowind
	multi_terrain_manager.chunk_size_cells = 32
	multi_terrain_manager.load_radius = 1  # 3x3 chunks loaded
	multi_terrain_manager.terrain_data_base_path = TERRAIN_CHUNKS_DIR
	multi_terrain_manager.region_size = 64
	multi_terrain_manager.lod_enabled = true

	add_child(multi_terrain_manager)

	# Connect signals
	multi_terrain_manager.chunk_loaded.connect(_on_terrain_chunk_loaded)
	multi_terrain_manager.chunk_unloaded.connect(_on_terrain_chunk_unloaded)
	multi_terrain_manager.player_chunk_changed.connect(_on_player_chunk_changed)

	_log("MultiTerrainManager configured: 32x32 cells per chunk, load_radius=1")


func _load_preprocessed_terrain() -> void:
	if _using_multi_terrain:
		_load_multi_terrain()
		return

	if not terrain_3d or not terrain_3d.data:
		return

	# Load textures first
	var textures_loaded: int = texture_loader.load_terrain_textures(terrain_3d.assets)
	_log("Loaded %d terrain textures" % textures_loaded)
	terrain_manager.set_texture_slot_mapper(texture_loader)

	# Load terrain data
	var path := ProjectSettings.globalize_path(TERRAIN_DATA_DIR)
	terrain_3d.data.load_directory(path)
	var region_count := terrain_3d.data.get_region_count()
	_log("Loaded %d terrain regions" % region_count)


func _load_multi_terrain() -> void:
	if not multi_terrain_manager:
		return

	# Load terrain textures into shared assets
	var shared_assets := Terrain3DAssets.new()
	var textures_loaded: int = texture_loader.load_terrain_textures(shared_assets)
	_log("Loaded %d terrain textures for multi-terrain" % textures_loaded)
	terrain_manager.set_texture_slot_mapper(texture_loader)

	# Apply shared assets to all chunks
	multi_terrain_manager.set_shared_assets(shared_assets)

	# Initialize the manager (it will start loading chunks when tracked node is set)
	multi_terrain_manager.initialize()

	_log("MultiTerrainManager initialized and ready")


## Initialize multi-terrain manager for on-the-fly terrain generation
## This enables infinite terrain without pre-processed data
func _init_multi_terrain_on_the_fly() -> void:
	# Hide the single Terrain3D node - we'll use MultiTerrainManager instead
	if terrain_3d:
		terrain_3d.visible = false

	# Create MultiTerrainManager
	multi_terrain_manager = Node3D.new()
	multi_terrain_manager.set_script(MultiTerrainManagerScript)
	multi_terrain_manager.name = "MultiTerrainManager"

	# Configure for Morrowind
	multi_terrain_manager.chunk_size_cells = 32
	multi_terrain_manager.load_radius = 1  # 3x3 chunks loaded
	multi_terrain_manager.terrain_data_base_path = TERRAIN_CHUNKS_DIR
	multi_terrain_manager.region_size = 64
	multi_terrain_manager.lod_enabled = true

	# Enable on-the-fly generation
	multi_terrain_manager.generate_on_fly = true
	multi_terrain_manager.terrain_manager = terrain_manager

	add_child(multi_terrain_manager)

	# Load terrain textures into shared assets
	var shared_assets := Terrain3DAssets.new()
	var textures_loaded: int = texture_loader.load_terrain_textures(shared_assets)
	_log("Loaded %d terrain textures for infinite terrain" % textures_loaded)
	terrain_manager.set_texture_slot_mapper(texture_loader)

	# Apply shared assets to all chunks
	multi_terrain_manager.set_shared_assets(shared_assets)

	# Connect signals
	multi_terrain_manager.chunk_loaded.connect(_on_terrain_chunk_loaded)
	multi_terrain_manager.chunk_unloaded.connect(_on_terrain_chunk_unloaded)
	multi_terrain_manager.player_chunk_changed.connect(_on_player_chunk_changed)
	multi_terrain_manager.terrain_generated.connect(_on_terrain_generated)

	# Initialize the manager (it will start loading chunks when tracked node is set)
	multi_terrain_manager.initialize()

	_using_multi_terrain = true
	_log("Infinite terrain (on-the-fly generation) initialized")
	_log("  Chunk size: 32x32 cells, Load radius: 1 (3x3 = 9 chunks)")


func _on_terrain_generated(chunk_coord: Vector2i, cells_generated: int) -> void:
	_log("Generated terrain chunk (%d, %d): %d cells" % [chunk_coord.x, chunk_coord.y, cells_generated])


## Load terrain textures for on-the-fly terrain generation (no pre-processed data)
func _load_terrain_textures_for_generation() -> void:
	if not terrain_3d:
		return

	# Ensure Terrain3D has assets for textures
	if not terrain_3d.assets:
		terrain_3d.set_assets(Terrain3DAssets.new())

	# Load LTEX textures into Terrain3D assets
	var textures_loaded: int = texture_loader.load_terrain_textures(terrain_3d.assets)
	_log("Loaded %d terrain textures for on-the-fly generation" % textures_loaded)

	# Configure terrain manager to use proper texture slot mapping
	terrain_manager.set_texture_slot_mapper(texture_loader)


## Update the preprocess status label
func _update_preprocess_status() -> void:
	if not preprocess_status:
		return

	if _using_preprocessed:
		if _using_multi_terrain:
			preprocess_status.text = "Using multi-terrain chunks"
			preprocess_status.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
		else:
			preprocess_status.text = "Using pre-processed terrain"
			preprocess_status.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
		preprocess_btn.text = "Re-preprocess Terrain"
	else:
		preprocess_status.text = "On-the-fly generation (slower)"
		preprocess_status.add_theme_color_override("font_color", Color(1.0, 0.8, 0.3))
		preprocess_btn.text = "Preprocess ALL Terrain"


## Handle preprocess button press
func _on_preprocess_pressed() -> void:
	_log("[color=cyan]Starting terrain preprocessing...[/color]")
	preprocess_btn.disabled = true
	preprocess_status.text = "Preprocessing..."

	# Use TerrainPreprocessor to preprocess all terrain
	# TerrainPreprocessor extends Node, so we need to add it to the scene tree
	var preprocessor := TerrainPreprocessorScript.new()
	add_child(preprocessor)

	# The preprocessor creates its own terrain_manager internally
	# But we can provide texture_loader if it supports it
	if "texture_loader" in preprocessor:
		preprocessor.texture_loader = texture_loader

	# Connect progress signal
	preprocessor.progress_updated.connect(_on_preprocess_progress)

	# Run preprocessing with data path
	var result: int = await preprocessor.preprocess_all_terrain(_data_path)

	# Cleanup preprocessor
	preprocessor.queue_free()

	if result == OK:
		_log("[color=green]Terrain preprocessing complete![/color]")
		_using_preprocessed = true
		_using_multi_terrain = false

		# Reload the terrain data
		if terrain_3d and terrain_3d.data:
			var save_path := ProjectSettings.globalize_path(TERRAIN_DATA_DIR)
			terrain_3d.data.load_directory(save_path)
			var region_count: int = terrain_3d.data.get_region_count()
			_log("Loaded %d terrain regions" % region_count)

		# Disable on-the-fly generation since we now have pre-processed data
		if world_streaming_manager:
			world_streaming_manager.generate_terrain_on_fly = false
	else:
		_log("[color=red]Terrain preprocessing failed![/color]")

	preprocess_btn.disabled = false
	_update_preprocess_status()


func _on_preprocess_progress(percent: float, message: String) -> void:
	preprocess_status.text = "%s (%.0f%%)" % [message, percent]


## Signal handlers for multi-terrain mode
func _on_terrain_chunk_loaded(chunk_coord: Vector2i, _terrain: Node) -> void:
	_log("Terrain chunk loaded: (%d, %d)" % [chunk_coord.x, chunk_coord.y])
	_update_stats()


func _on_terrain_chunk_unloaded(chunk_coord: Vector2i) -> void:
	_log("Terrain chunk unloaded: (%d, %d)" % [chunk_coord.x, chunk_coord.y])
	_update_stats()


func _on_player_chunk_changed(old_chunk: Vector2i, new_chunk: Vector2i) -> void:
	_log("Player moved from chunk (%d,%d) to (%d,%d)" % [
		old_chunk.x, old_chunk.y, new_chunk.x, new_chunk.y
	])


func _setup_world_streaming_manager() -> void:
	# Create WorldStreamingManager
	world_streaming_manager = Node3D.new()
	world_streaming_manager.set_script(WorldStreamingManagerScript)
	world_streaming_manager.name = "WorldStreamingManager"

	# Configure
	world_streaming_manager.view_distance_cells = _current_view_distance
	world_streaming_manager.load_objects = true
	world_streaming_manager.debug_enabled = true

	# When using multi-terrain manager, let it handle terrain
	# Otherwise, WorldStreamingManager handles terrain with single Terrain3D
	if _using_multi_terrain:
		world_streaming_manager.load_terrain = false
		world_streaming_manager.generate_terrain_on_fly = false
	else:
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

	# Track camera
	world_streaming_manager.set_tracked_node(camera)

	# Also set tracked node on multi-terrain manager if active
	if multi_terrain_manager:
		multi_terrain_manager.set_tracked_node(camera)

	# Initialize after all configuration is set
	world_streaming_manager.initialize()

	_log("WorldStreamingManager created and configured")
	if _using_multi_terrain:
		if _using_preprocessed:
			_log("Multi-terrain streaming active (pre-processed)")
		else:
			_log("[color=cyan]Infinite terrain active (on-the-fly generation)[/color]")


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
	var cell_world_size := MWCoords.CELL_SIZE_GODOT
	var world_x := float(cell_x) * cell_world_size + cell_world_size * 0.5
	var world_z := float(-cell_y) * cell_world_size - cell_world_size * 0.5

	var height := 50.0

	# Get terrain height - works for both single and multi-terrain modes
	if _using_multi_terrain and multi_terrain_manager:
		# In multi-terrain mode, we need to find the active chunk's terrain
		# For now, use a default height since chunks may not be loaded yet
		# The multi_terrain_manager.teleport_to() handles chunk loading
		await multi_terrain_manager.teleport_to(Vector3(world_x, 0, world_z))
	elif terrain_3d and terrain_3d.data:
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

	# Get LOD stats
	var lod_full: int = stats.get("lod_objects_full", 0)
	var lod_low: int = stats.get("lod_objects_low", 0)
	var lod_culled: int = stats.get("lod_objects_culled", 0)
	var lod_total: int = stats.get("lod_total_tracked", 0)

	# Get multi-terrain stats if active
	var terrain_mode := "Single"
	var active_chunks := 0
	var total_regions := 0

	if _using_multi_terrain and multi_terrain_manager:
		terrain_mode = "Multi"
		var mt_stats: Dictionary = multi_terrain_manager.get_stats()
		active_chunks = mt_stats.get("active_chunks", 0)
		total_regions = mt_stats.get("total_regions", 0)
	elif terrain_3d and terrain_3d.data:
		total_regions = terrain_3d.data.get_region_count()

	stats_text.text = """[b]Performance[/b]
FPS: %.1f (%.2f ms)
P95: %.2f ms
Draw calls: %d
Primitives: %dk
Memory: %.1f MB

[b]Streaming[/b]
Loaded cells: %d
Queue: %d (peak: %d)
View dist: %d cells [+/-]

[b]Terrain (%s)[/b]
Chunks: %d | Regions: %d

[b]LOD[/b]
Full/Low/Culled: %d/%d/%d
Total tracked: %d

[b]Camera[/b]
Cell: (%d, %d)

[color=gray]F3: Overlay | F4: Report[/color]""" % [
		fps, frame_ms,
		p95_ms,
		draw_calls,
		primitives / 1000.0,
		mem_mb,
		stats.get("loaded_cells", 0),
		stats.get("load_queue_size", 0),
		stats.get("queue_high_water_mark", 0),
		_current_view_distance,
		terrain_mode,
		active_chunks, total_regions,
		lod_full, lod_low, lod_culled,
		lod_total,
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


func _process(delta: float) -> void:
	if not _initialized:
		return

	# Record frame timing for profiler
	if profiler:
		profiler.record_frame(delta)

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
	if multi_terrain_manager:
		multi_terrain_manager.visible = false

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
	if terrain_3d and not _using_multi_terrain:
		terrain_3d.visible = true
	if multi_terrain_manager:
		multi_terrain_manager.visible = true

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
		var pos := MWCoords.position_to_godot(ref.position)
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
