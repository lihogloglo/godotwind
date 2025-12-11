## Terrain Viewer - Test tool for visualizing Morrowind terrain with Terrain3D
##
## Supports two modes:
## 1. Live conversion: Load individual cells from ESM on demand
## 2. Pre-processed: Use native Terrain3D region files for LOD/streaming
##
## The pre-processed mode enables next-gen features:
## - Geometric clipmap LOD (detail reduces with distance)
## - Native region streaming (load/unload automatically)
## - Distant lands (see terrain to the horizon)
extends Node3D

# Preload dependencies
const MWCoords := preload("res://src/core/morrowind_coords.gd")
const TerrainManagerScript := preload("res://src/core/world/terrain_manager.gd")
const TerrainTextureLoaderScript := preload("res://src/core/world/terrain_texture_loader.gd")

# Pre-processed terrain data directory
const TERRAIN_DATA_DIR := "user://terrain_data/"

# UI references - Main panel
@onready var cell_x_spin: SpinBox = $UI/Panel/VBox/CoordsContainer/CellXSpin
@onready var cell_y_spin: SpinBox = $UI/Panel/VBox/CoordsContainer/CellYSpin
@onready var radius_spin: SpinBox = $UI/Panel/VBox/RadiusContainer/RadiusSpin
@onready var load_terrain_button: Button = $UI/Panel/VBox/LoadTerrainButton
@onready var stats_text: RichTextLabel = $UI/Panel/VBox/StatsText
@onready var log_text: RichTextLabel = $UI/Panel/VBox/LogText

# Pre-processing UI
@onready var preprocess_btn: Button = $UI/Panel/VBox/PreprocessBtn
@onready var preprocess_status: Label = $UI/Panel/VBox/PreprocessStatus

# Quick load buttons
@onready var seyda_neen_btn: Button = $UI/Panel/VBox/QuickButtons/SeydaNeenBtn
@onready var balmora_btn: Button = $UI/Panel/VBox/QuickButtons/BalmoraBtn
@onready var vivec_btn: Button = $UI/Panel/VBox/QuickButtons/VivecBtn
@onready var origin_btn: Button = $UI/Panel/VBox/QuickButtons/OriginBtn

# Loading overlay UI
@onready var loading_overlay: ColorRect = $UI/LoadingOverlay
@onready var loading_label: Label = $UI/LoadingOverlay/VBox/LoadingLabel
@onready var progress_bar: ProgressBar = $UI/LoadingOverlay/VBox/ProgressBar
@onready var status_label: Label = $UI/LoadingOverlay/VBox/StatusLabel

# Terrain3D node reference
@onready var terrain_3d: Terrain3D = $Terrain3D
@onready var camera: Camera3D = $FlyCamera

# Camera movement
var camera_speed: float = 200.0  # Meters per second
var mouse_sensitivity: float = 0.003
var mouse_captured: bool = false

# Terrain manager instance
var terrain_manager: RefCounted  # TerrainManager
var texture_loader: RefCounted  # TerrainTextureLoader

# Track loaded cells
var _loaded_cells: Array[Vector2i] = []

# Mode tracking
var _using_preprocessed := false
var _data_path: String = ""


func _ready() -> void:
	# Initialize terrain manager and texture loader
	terrain_manager = TerrainManagerScript.new()
	texture_loader = TerrainTextureLoaderScript.new()

	# Connect UI signals
	load_terrain_button.pressed.connect(_on_load_terrain_pressed)
	preprocess_btn.pressed.connect(_on_preprocess_pressed)

	# Connect quick load buttons - teleport in preprocessed mode, load area in live mode
	seyda_neen_btn.pressed.connect(func(): _quick_load_or_teleport(-2, -9, 2))
	balmora_btn.pressed.connect(func(): _quick_load_or_teleport(-3, -2, 2))
	vivec_btn.pressed.connect(func(): _quick_load_or_teleport(5, -6, 2))
	origin_btn.pressed.connect(func(): _quick_load_or_teleport(0, 0, 1))

	# Get Morrowind data path from project settings
	_data_path = ProjectSettings.get_setting("morrowind/data_path", "")
	if _data_path.is_empty():
		_hide_loading()
		_log("[color=red]ERROR: Morrowind data path not configured in project.godot[/color]")
		return

	_log("Morrowind data path: " + _data_path)

	# Load ESM and BSA files with progress updates
	_show_loading("Loading Game Data", "Initializing...")
	call_deferred("_load_game_data_async")


## Show the loading overlay with a title and status
func _show_loading(title: String, status: String) -> void:
	loading_overlay.visible = true
	loading_label.text = title
	status_label.text = status
	progress_bar.value = 0


## Hide the loading overlay
func _hide_loading() -> void:
	loading_overlay.visible = false


## Update loading progress
func _update_loading(progress: float, status: String) -> void:
	progress_bar.value = progress
	status_label.text = status
	# Force UI update
	await get_tree().process_frame


## Async version of game data loading with progress updates
func _load_game_data_async() -> void:
	_log("Loading BSA archives...")
	await _update_loading(10, "Loading BSA archives...")

	# Load BSA files
	var bsa_count := BSAManager.load_archives_from_directory(_data_path)
	_log("Loaded %d BSA archives" % bsa_count)

	if bsa_count == 0:
		_log("[color=yellow]Warning: No BSA archives found.[/color]")

	await _update_loading(40, "Loading ESM file...")

	# Load ESM file
	var esm_file: String = ProjectSettings.get_setting("morrowind/esm_file", "Morrowind.esm")
	var esm_path := _data_path.path_join(esm_file)

	_log("Loading ESM: " + esm_path)
	var error := ESMManager.load_file(esm_path)

	if error != OK:
		_log("[color=red]ERROR: Failed to load ESM file: %s[/color]" % error_string(error))
		_hide_loading()
		return

	_log("[color=green]ESM loaded successfully![/color]")
	_log("LAND records: %d" % ESMManager.lands.size())
	_log("LTEX records: %d" % ESMManager.land_textures.size())

	await _update_loading(70, "Checking for pre-processed terrain...")
	_check_preprocessed_status()

	await _update_loading(90, "Initializing Terrain3D...")

	# Initialize Terrain3D if needed
	_init_terrain3d()

	# Load pre-processed terrain if available
	if _using_preprocessed:
		await _update_loading(95, "Loading pre-processed terrain...")
		_load_preprocessed_terrain()

	await _update_loading(100, "Done!")

	# Hide loading overlay after a brief delay
	await get_tree().create_timer(0.3).timeout
	_hide_loading()

	_log("[color=green]Ready![/color]")
	if _using_preprocessed:
		_log("[color=cyan]Using pre-processed terrain (Next-Gen mode)[/color]")
		_log("Terrain3D handles LOD and streaming automatically.")
		_log("Use quick buttons to teleport around the world.")
	else:
		_log("Use controls to load terrain, or 'Preprocess ALL' for next-gen mode.")


## Check if pre-processed terrain data exists and update status
func _check_preprocessed_status() -> void:
	var dir := DirAccess.open(TERRAIN_DATA_DIR)
	if dir:
		var count := 0
		var total_size := 0
		dir.list_dir_begin()
		var file_name := dir.get_next()
		while file_name != "":
			if file_name.ends_with(".res"):
				count += 1
				var f := FileAccess.open(TERRAIN_DATA_DIR.path_join(file_name), FileAccess.READ)
				if f:
					total_size += f.get_length()
					f.close()
			file_name = dir.get_next()
		dir.list_dir_end()

		if count > 0:
			_using_preprocessed = true
			var size_mb := total_size / (1024.0 * 1024.0)
			preprocess_status.text = "Ready: %d regions (%.1f MB)" % [count, size_mb]
			preprocess_status.add_theme_color_override("font_color", Color.GREEN)
			_log("Found %d pre-processed terrain regions (%.1f MB)" % [count, size_mb])
			return

	preprocess_status.text = "No pre-processed data"
	preprocess_status.add_theme_color_override("font_color", Color.YELLOW)


## Load pre-processed terrain data from disk
func _load_preprocessed_terrain() -> void:
	if not terrain_3d or not terrain_3d.data:
		return

	var path := ProjectSettings.globalize_path(TERRAIN_DATA_DIR)
	terrain_3d.data.load_directory(path)

	var region_count := terrain_3d.data.get_region_count()
	_log("Loaded %d terrain regions from pre-processed data" % region_count)
	_update_stats_preprocessed()


## Initialize Terrain3D with required resources
## Configures region size and vertex spacing to match Morrowind cell dimensions
func _init_terrain3d() -> void:
	if not terrain_3d:
		_log("[color=red]ERROR: Terrain3D node not found![/color]")
		return

	# Check if Terrain3D classes are available (GDExtension loaded)
	if not ClassDB.class_exists("Terrain3DData"):
		_log("[color=red]ERROR: Terrain3D GDExtension not loaded! Make sure the plugin is enabled.[/color]")
		return

	# Create Terrain3DData if not present
	if not terrain_3d.data:
		terrain_3d.set_data(Terrain3DData.new())
		_log("Created new Terrain3DData")

	# Create Terrain3DMaterial if not present
	if not terrain_3d.material:
		terrain_3d.set_material(Terrain3DMaterial.new())
		# Don't enable show_colormap - it overrides textures!
		# Textures will display automatically when control map has valid texture indices
		_log("Created new Terrain3DMaterial")

	# Create Terrain3DAssets if not present
	if not terrain_3d.assets:
		terrain_3d.set_assets(Terrain3DAssets.new())
		_log("Created new Terrain3DAssets")

	# Configure Terrain3D to match Morrowind cell dimensions
	# MW cell = 8192 game units = ~117 meters (8192/70)
	#
	# Terrain3D limits: 32 regions on each axis (-16 to +15)
	# Morrowind cells: roughly -30 to +30 on each axis (60x60 cells)
	#
	# Strategy: Use region_size=256 so each region holds 4 MW cells (2x2)
	# This gives us 32 * 4 = 128 MW cells coverage, enough for all of Vvardenfell
	#
	# With 256 vertices per region at vertex_spacing = 117.03/64 = 1.828:
	#   Region world size = 256 * 1.828 ≈ 468m = 4 MW cells
	#
	# But we import 1 cell at a time, so we use region_size=64 but center the world
	# at Vvardenfell's center (around cell 0,0) to fit within Terrain3D's bounds

	var mw_cell_size_godot := MWCoords.CELL_SIZE_GODOT  # ~117.03m

	# Use region_size = 64, closest to MW's 65x65 grid
	# Terrain3D RegionSize enum: SIZE_64 = 0, SIZE_128 = 1, SIZE_256 = 2, etc.
	terrain_3d.change_region_size(64)  # 64x64 vertices per region

	# Set vertex_spacing so that a 64-vertex region spans exactly one MW cell
	var vertex_spacing := mw_cell_size_godot / 64.0  # ≈ 1.828m between vertices
	terrain_3d.vertex_spacing = vertex_spacing

	# World bounds: 32 regions * 117m = 3744m total, or ±1872m from center
	# This covers MW cells roughly -16 to +15 on each axis
	# Vvardenfell is roughly centered around (0,0) so this should be fine

	_log("Terrain3D configured:")
	_log("  Region size: 64 vertices")
	_log("  Vertex spacing: %.4f m" % vertex_spacing)
	_log("  Region world size: %.2f m (MW cell)" % (64.0 * vertex_spacing))
	_log("  Max world bounds: ±%.0f m (cells -16 to +15)" % (16.0 * 64.0 * vertex_spacing))

	_log("[color=green]Terrain3D initialized successfully[/color]")


## Quick load or teleport depending on mode
func _quick_load_or_teleport(center_x: int, center_y: int, radius: int) -> void:
	cell_x_spin.value = center_x
	cell_y_spin.value = center_y
	radius_spin.value = radius

	if _using_preprocessed:
		_teleport_to_cell(center_x, center_y)
	else:
		_on_load_terrain_pressed()


## Teleport camera to a specific cell
func _teleport_to_cell(cell_x: int, cell_y: int) -> void:
	var region_world_size := 64.0 * terrain_3d.get_vertex_spacing()
	var world_x := float(cell_x) * region_world_size + region_world_size * 0.5
	var world_z := float(-cell_y) * region_world_size + region_world_size * 0.5

	var height := terrain_3d.data.get_height(Vector3(world_x, 0, world_z)) if terrain_3d.data else 50.0
	if is_nan(height) or height > 10000:
		height = 50.0

	camera.position = Vector3(world_x, height + 100.0, world_z + 50.0)
	camera.look_at(Vector3(world_x, height, world_z))
	_log("Teleported to cell (%d, %d)" % [cell_x, cell_y])
	_update_stats_preprocessed()


## Handle preprocess button press
func _on_preprocess_pressed() -> void:
	_log("\n[b]Starting terrain pre-processing...[/b]")
	_log("Converting ALL Morrowind terrain to Terrain3D format.")
	_log("This enables: LOD, streaming, distant lands.")

	_show_loading("Pre-Processing Terrain", "Preparing...")
	await get_tree().process_frame

	await _preprocess_all_terrain()

	_hide_loading()
	_check_preprocessed_status()

	if _using_preprocessed:
		_load_preprocessed_terrain()


## Pre-process all Morrowind terrain to Terrain3D region files
func _preprocess_all_terrain() -> void:
	var start_time := Time.get_ticks_msec()

	# Ensure output directory exists
	var dir := DirAccess.open("user://")
	if not dir.dir_exists("terrain_data"):
		dir.make_dir("terrain_data")

	# Clear existing terrain data
	await _update_loading(5, "Clearing existing data...")
	for region in terrain_3d.data.get_regions_active():
		terrain_3d.data.remove_region(region, false)
	terrain_3d.data.update_maps(Terrain3DRegion.TYPE_MAX, true, false)

	# Load LTEX textures into Terrain3D
	await _update_loading(8, "Loading terrain textures...")
	var textures_loaded: int = texture_loader.load_terrain_textures(terrain_3d.assets)
	_log("Loaded %d terrain textures" % textures_loaded)

	# Configure terrain manager to use proper texture slot mapping
	terrain_manager.set_texture_slot_mapper(texture_loader)

	var total_cells := ESMManager.lands.size()
	var processed := 0
	var skipped := 0

	_log("Processing %d LAND records..." % total_cells)

	# Process all LAND records
	var out_of_bounds := 0
	var cell_keys := ESMManager.lands.keys()
	for key in cell_keys:
		var land: LandRecord = ESMManager.lands[key]

		if not land or not land.has_heights():
			skipped += 1
			continue

		var percent := 5.0 + (85.0 * float(processed) / float(total_cells))
		await _update_loading(percent, "Processing (%d, %d)..." % [land.cell_x, land.cell_y])

		if _import_cell_to_terrain3d(land):
			processed += 1
		else:
			out_of_bounds += 1

		if processed % 100 == 0:
			await get_tree().process_frame

	# Calculate height range
	await _update_loading(92, "Calculating height range...")
	terrain_3d.data.calc_height_range(true)

	# Save to disk
	await _update_loading(95, "Saving terrain data...")
	var save_path := ProjectSettings.globalize_path(TERRAIN_DATA_DIR)
	terrain_3d.data.save_directory(save_path)

	var elapsed := Time.get_ticks_msec() - start_time
	var region_count := terrain_3d.data.get_region_count()

	_log("[color=green]Pre-processing complete![/color]")
	_log("  Processed: %d cells" % processed)
	_log("  Out of bounds: %d cells" % out_of_bounds)
	_log("  Skipped (no data): %d cells" % skipped)
	_log("  Regions: %d" % region_count)
	_log("  Time: %.2f seconds" % (elapsed / 1000.0))

	_using_preprocessed = true


## Handle load terrain button press
func _on_load_terrain_pressed() -> void:
	var center_x := int(cell_x_spin.value)
	var center_y := int(cell_y_spin.value)
	var radius := int(radius_spin.value)

	_log("\n[b]Loading terrain around (%d, %d) with radius %d[/b]" % [center_x, center_y, radius])

	# Get cells to load
	var cells_to_load := TerrainManagerScript.get_cells_in_radius(center_x, center_y, radius)
	_log("Cells to load: %d" % cells_to_load.size())

	# Show loading overlay
	_show_loading("Loading Terrain", "Preparing...")
	await get_tree().process_frame

	# Load terrain asynchronously
	await _load_terrain_async(cells_to_load)

	_hide_loading()


## Load terrain cells asynchronously
## First pre-loads all LAND records, stitches edges for seamless terrain,
## then imports each cell into Terrain3D
func _load_terrain_async(cells: Array[Vector2i]) -> void:
	var start_time := Time.get_ticks_msec()
	var total_cells := cells.size()
	var loaded_count := 0
	var skipped_count := 0

	# Clear existing terrain data
	_update_loading(5, "Clearing existing terrain...")
	await get_tree().process_frame

	# Reset Terrain3D data
	if terrain_3d.data:
		# Remove all existing regions
		for region in terrain_3d.data.get_regions_active():
			terrain_3d.data.remove_region(region, false)
		terrain_3d.data.update_maps(Terrain3DRegion.TYPE_MAX, true, false)

	_loaded_cells.clear()

	# Phase 0: Load LTEX textures if not already loaded
	if terrain_3d.assets and terrain_3d.assets.get_texture_count() == 0:
		_update_loading(8, "Loading terrain textures...")
		await get_tree().process_frame
		var textures_loaded: int = texture_loader.load_terrain_textures(terrain_3d.assets)
		_log("Loaded %d terrain textures" % textures_loaded)
		terrain_manager.set_texture_slot_mapper(texture_loader)

	# Phase 1: Pre-load all LAND records
	_update_loading(10, "Loading LAND records...")
	await get_tree().process_frame

	# Sort cells for proper grid ordering (row-major, Y ascending then X ascending)
	var sorted_cells := cells.duplicate()
	sorted_cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x
	)

	# Find grid bounds
	var min_x: int = sorted_cells[0].x
	var max_x: int = sorted_cells[0].x
	var min_y: int = sorted_cells[0].y
	var max_y: int = sorted_cells[0].y
	for cell in sorted_cells:
		min_x = mini(min_x, cell.x)
		max_x = maxi(max_x, cell.x)
		min_y = mini(min_y, cell.y)
		max_y = maxi(max_y, cell.y)
	var grid_width: int = max_x - min_x + 1
	var grid_height: int = max_y - min_y + 1

	# Load all LAND records into grid array
	var lands: Array = []
	lands.resize(grid_width * grid_height)
	for cell: Vector2i in sorted_cells:
		var gx: int = cell.x - min_x
		var gy: int = cell.y - min_y
		var idx: int = gy * grid_width + gx
		var land: LandRecord = ESMManager.get_land(cell.x, cell.y)
		if land and land.has_heights():
			lands[idx] = land

	# Phase 2: Debug - compare edge heights BEFORE stitching
	_update_loading(25, "Analyzing edge heights...")
	await get_tree().process_frame
	_debug_edge_heights(lands, grid_width, grid_height, min_x, min_y)

	# Phase 2b: Stitch adjacent cell edges for seamless terrain
	_update_loading(30, "Stitching terrain edges...")
	await get_tree().process_frame

	if terrain_manager.stitch_cell_edges(lands, grid_width):
		_log("Applied edge stitching to %d x %d cell grid" % [grid_width, grid_height])

	# Phase 3: Import each cell into Terrain3D
	for i in range(sorted_cells.size()):
		var cell_coord: Vector2i = sorted_cells[i]
		var progress := 35.0 + (55.0 * float(i) / float(total_cells))
		_update_loading(progress, "Importing cell (%d, %d)..." % [cell_coord.x, cell_coord.y])
		await get_tree().process_frame

		var gx: int = cell_coord.x - min_x
		var gy: int = cell_coord.y - min_y
		var idx: int = gy * grid_width + gx
		var land: LandRecord = lands[idx]

		if not land:
			_log("[color=yellow]No LAND data for cell (%d, %d)[/color]" % [cell_coord.x, cell_coord.y])
			skipped_count += 1
			continue

		# Import this cell into Terrain3D
		if _import_cell_to_terrain3d(land):
			_loaded_cells.append(cell_coord)
			loaded_count += 1
		else:
			_log("[color=yellow]Cell (%d, %d) out of Terrain3D bounds[/color]" % [cell_coord.x, cell_coord.y])
			skipped_count += 1

	# Update height range
	_update_loading(95, "Finalizing terrain...")
	await get_tree().process_frame

	if terrain_3d.data:
		terrain_3d.data.calc_height_range(true)

	var elapsed := Time.get_ticks_msec() - start_time

	# Update stats
	_update_stats(loaded_count, skipped_count, elapsed)

	_log("[color=green]Terrain loaded in %d ms[/color]" % elapsed)
	_log("Loaded: %d cells, Skipped: %d cells" % [loaded_count, skipped_count])

	# Position camera
	if not _loaded_cells.is_empty():
		_position_camera_for_terrain()


## Import a single LAND record into Terrain3D
## The heightmap is cropped from 65x65 to 64x64 to match Terrain3D's region size
##
## IMPORTANT: MW cells have 65x65 vertices (64 quads) where adjacent cells share
## edge vertices. We crop rather than resize to preserve the exact edge values.
## With Y-axis flipped: we keep image rows [0-63] which are MW rows [1-64].
## The cell to the SOUTH provides the missing row 0 (south edge).
## The cell to the EAST provides the missing column 64 (east edge).
##
## Coordinate mapping after Y-flip:
##   - Image row 0 = MW row 64 (north edge of cell)
##   - Image row 63 = MW row 1 (one row north of south edge)
##   - Image row 64 = MW row 0 (south edge) - DISCARDED by crop
##
## Returns true if import succeeded, false if cell is out of bounds
func _import_cell_to_terrain3d(land: LandRecord) -> bool:
	if not terrain_3d or not terrain_3d.data:
		return false

	# Terrain3D region bounds with region_size=64 and vertex_spacing=1.828:
	#   - Each region spans 64 * 1.828 ≈ 117 meters (1 MW cell)
	#   - Valid region indices: -16 to +15 (32 regions per axis)
	#   - World range: ±16 * 117 ≈ ±1872 meters
	#
	# Morrowind world extends roughly from cells (-30, -30) to (+30, +30)
	# This exceeds our bounds, so we only support the core area around (0,0)
	#
	# TODO: To support full world, use region_size=256 (4 cells per region)
	#       or offset the world center to Vvardenfell's geographic center
	if land.cell_x < -16 or land.cell_x > 15 or land.cell_y < -16 or land.cell_y > 15:
		return false

	# Generate maps from LAND record (65x65)
	var heightmap: Image = terrain_manager.generate_heightmap(land)
	var colormap: Image = terrain_manager.generate_color_map(land)
	var controlmap: Image = terrain_manager.generate_control_map(land)

	# Crop from 65x65 to 64x64 by keeping pixels [0-63] and discarding pixel 64
	# This preserves exact edge values - the east/north edges we discard will be
	# provided by the adjacent cell's west/south edges (which are their pixel 0)
	var cropped_heightmap := Image.create(64, 64, false, Image.FORMAT_RF)
	var cropped_colormap := Image.create(64, 64, false, Image.FORMAT_RGB8)
	var cropped_controlmap := Image.create(64, 64, false, Image.FORMAT_RF)

	cropped_heightmap.blit_rect(heightmap, Rect2i(0, 0, 64, 64), Vector2i(0, 0))
	cropped_colormap.blit_rect(colormap, Rect2i(0, 0, 64, 64), Vector2i(0, 0))
	cropped_controlmap.blit_rect(controlmap, Rect2i(0, 0, 64, 64), Vector2i(0, 0))

	# Calculate world position for this cell
	# With vertex_spacing configured, each region represents one MW cell
	# The region grid is aligned so that cell (x, y) maps to region (x, -y)
	#
	# Important: Terrain3D rounds positions to nearest region boundary
	# With region_size=64 and vertex_spacing=1.828, region world size = 117.03m
	# So we position each cell at its grid position * region_world_size
	var region_world_size := 64.0 * terrain_3d.get_vertex_spacing()

	# MW Y axis is North, Godot Z axis is South, so negate Y
	# Position at the center of the region for proper snapping
	var world_x := float(land.cell_x) * region_world_size + region_world_size * 0.5
	var world_z := float(-land.cell_y) * region_world_size + region_world_size * 0.5

	# Create import array [heightmap, controlmap, colormap]
	var imported_images: Array[Image] = []
	imported_images.resize(Terrain3DRegion.TYPE_MAX)
	imported_images[Terrain3DRegion.TYPE_HEIGHT] = cropped_heightmap
	imported_images[Terrain3DRegion.TYPE_CONTROL] = cropped_controlmap
	imported_images[Terrain3DRegion.TYPE_COLOR] = cropped_colormap

	# Import into Terrain3D at the calculated position
	# import_images will snap to the nearest region boundary
	var import_pos := Vector3(world_x, 0, world_z)
	terrain_3d.data.import_images(imported_images, import_pos, 0.0, 1.0)
	return true


## Update statistics display (live mode)
func _update_stats(loaded: int, skipped: int, elapsed: int) -> void:
	var terrain_stats: Dictionary = terrain_manager.get_stats()
	stats_text.text = """[b]Live Mode Stats:[/b]
Cells loaded: %d
Cells skipped: %d
Heightmaps generated: %d
Load time: %d ms

[b]Camera:[/b]
%.1f, %.1f, %.1f""" % [
		loaded,
		skipped,
		terrain_stats.get("heightmaps_generated", 0),
		elapsed,
		camera.position.x, camera.position.y, camera.position.z
	]


## Update statistics display (pre-processed mode)
func _update_stats_preprocessed() -> void:
	var region_count := terrain_3d.data.get_region_count() if terrain_3d.data else 0
	stats_text.text = """[b]Next-Gen Mode[/b]
Regions: %d
LOD: Automatic (clipmap)
Streaming: Native

[b]Camera:[/b]
%.1f, %.1f, %.1f

[color=cyan]Terrain3D handles
LOD/streaming![/color]""" % [
		region_count,
		camera.position.x, camera.position.y, camera.position.z
	]


## Position camera to view loaded terrain
func _position_camera_for_terrain() -> void:
	if _loaded_cells.is_empty():
		return

	# Calculate center of loaded cells
	var center := Vector2.ZERO
	for cell in _loaded_cells:
		center += Vector2(cell.x, cell.y)
	center /= _loaded_cells.size()

	# Convert to Godot world position using the configured region size
	var region_world_size := 64.0 * terrain_3d.get_vertex_spacing()
	var world_x := center.x * region_world_size + region_world_size * 0.5
	var world_z := -center.y * region_world_size - region_world_size * 0.5  # Negate Y

	# Get approximate terrain height at center
	var terrain_height := 0.0
	if terrain_3d and terrain_3d.data:
		terrain_height = terrain_3d.data.get_height(Vector3(world_x, 0, world_z))
		if is_nan(terrain_height) or terrain_height > 10000:
			terrain_height = 50.0  # Fallback height

	# Position camera above center, looking down at terrain
	var view_distance := region_world_size * (_loaded_cells.size() ** 0.5) * 0.8
	camera.position = Vector3(world_x, terrain_height + view_distance * 0.5, world_z + view_distance * 0.3)
	camera.look_at(Vector3(world_x, terrain_height, world_z))

	_log("Camera positioned at: (%.1f, %.1f, %.1f)" % [camera.position.x, camera.position.y, camera.position.z])


# ==================== Camera Controls ====================

func _input(event: InputEvent) -> void:
	# Toggle mouse capture with right click
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
				mouse_captured = true
			else:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
				mouse_captured = false

	# Mouse look when captured
	if event is InputEventMouseMotion and mouse_captured:
		camera.rotate_y(-event.relative.x * mouse_sensitivity)
		camera.rotate_object_local(Vector3.RIGHT, -event.relative.y * mouse_sensitivity)


func _process(delta: float) -> void:
	if not mouse_captured:
		return

	# WASD movement
	var input_dir := Vector3.ZERO

	if Input.is_key_pressed(KEY_W):
		input_dir.z -= 1
	if Input.is_key_pressed(KEY_S):
		input_dir.z += 1
	if Input.is_key_pressed(KEY_A):
		input_dir.x -= 1
	if Input.is_key_pressed(KEY_D):
		input_dir.x += 1
	if Input.is_key_pressed(KEY_SPACE):
		input_dir.y += 1
	if Input.is_key_pressed(KEY_SHIFT):
		input_dir.y -= 1

	# Speed boost with Ctrl
	var speed := camera_speed
	if Input.is_key_pressed(KEY_CTRL):
		speed *= 3.0

	# Move camera
	if input_dir != Vector3.ZERO:
		var move_dir := camera.global_transform.basis * input_dir.normalized()
		camera.position += move_dir * speed * delta

	# Update stats with camera position
	if stats_text and stats_text.text.find("Camera Position") >= 0:
		var lines := stats_text.text.split("\n")
		if lines.size() > 0:
			lines[-1] = "%.1f, %.1f, %.1f" % [camera.position.x, camera.position.y, camera.position.z]
			stats_text.text = "\n".join(lines)


func _log(message: String) -> void:
	if log_text:
		log_text.append_text(message + "\n")
	print(message.replace("[b]", "").replace("[/b]", "").replace("[color=green]", "").replace("[color=red]", "").replace("[color=yellow]", "").replace("[color=cyan]", "").replace("[/color]", ""))


## Debug: Compare edge heights between adjacent cells to find discontinuities
func _debug_edge_heights(lands: Array, grid_width: int, grid_height: int, min_x: int, min_y: int) -> void:
	_log("[b]Edge Height Analysis:[/b]")

	var total_horizontal := 0
	var total_vertical := 0
	var max_h_diff := 0.0
	var max_v_diff := 0.0

	for gy in range(grid_height):
		for gx in range(grid_width):
			var idx := gy * grid_width + gx
			var land: LandRecord = lands[idx]
			if not land:
				continue

			# Check horizontal edge (current cell's east edge vs next cell's west edge)
			if gx < grid_width - 1:
				var right_idx := idx + 1
				var right_land: LandRecord = lands[right_idx]
				if right_land:
					var result := TerrainManagerScript.debug_compare_cell_edges(land, right_land, "horizontal")
					if result.get("mismatches", 0) > 0:
						total_horizontal += result["mismatches"]
						max_h_diff = maxf(max_h_diff, result["max_diff"])
						if result["max_diff"] > 100:  # Log significant differences
							_log("[color=yellow]  H-Edge (%d,%d)->(%d,%d): %d mismatches, max_diff=%.1f[/color]" % [
								land.cell_x, land.cell_y, right_land.cell_x, right_land.cell_y,
								result["mismatches"], result["max_diff"]
							])
							for sample in result["samples"]:
								if sample["diff"] > 10:
									_log("    y=%d: h_a=%.1f, h_b=%.1f, diff=%.1f" % [
										sample["idx"], sample["h_a"], sample["h_b"], sample["diff"]
									])

			# Check vertical edge (current cell's north edge vs cell above's south edge)
			if gy < grid_height - 1:
				var above_idx := idx + grid_width
				var above_land: LandRecord = lands[above_idx]
				if above_land:
					var result := TerrainManagerScript.debug_compare_cell_edges(land, above_land, "vertical")
					if result.get("mismatches", 0) > 0:
						total_vertical += result["mismatches"]
						max_v_diff = maxf(max_v_diff, result["max_diff"])
						if result["max_diff"] > 100:  # Log significant differences
							_log("[color=yellow]  V-Edge (%d,%d)->(%d,%d): %d mismatches, max_diff=%.1f[/color]" % [
								land.cell_x, land.cell_y, above_land.cell_x, above_land.cell_y,
								result["mismatches"], result["max_diff"]
							])
							for sample in result["samples"]:
								if sample["diff"] > 10:
									_log("    x=%d: h_a=%.1f, h_b=%.1f, diff=%.1f" % [
										sample["idx"], sample["h_a"], sample["h_b"], sample["diff"]
									])

	if total_horizontal == 0 and total_vertical == 0:
		_log("[color=green]  All edge heights match perfectly![/color]")
	else:
		_log("  Horizontal mismatches: %d (max diff: %.1f)" % [total_horizontal, max_h_diff])
		_log("  Vertical mismatches: %d (max diff: %.1f)" % [total_vertical, max_v_diff])
