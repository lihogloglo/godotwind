## WorldTerrain - Next-gen terrain system using Terrain3D's native capabilities
##
## This class manages terrain for the entire Morrowind world using Terrain3D's
## modern features:
## - Geometric clipmap LOD (automatic detail reduction with distance)
## - Per-region file streaming (load/unload regions on demand)
## - Distant lands (low-detail terrain visible to horizon)
## - Dynamic collision (only generate physics near player)
##
## Architecture:
##   Pre-processing: MW LAND records → Terrain3D region files (one-time)
##   Runtime: Terrain3D handles streaming/LOD automatically
##
## Usage:
##   var world_terrain = WorldTerrain.new()
##   add_child(world_terrain)
##   world_terrain.initialize(morrowind_data_path)
##   # Terrain3D handles everything else!
##
class_name WorldTerrain
extends Node3D

const MWCoords := preload("res://src/core/morrowind_coords.gd")
const TerrainManagerScript := preload("res://src/core/world/terrain_manager.gd")
const TerrainTextureLoaderScript := preload("res://src/core/world/terrain_texture_loader.gd")

## Directory for pre-processed terrain data
const TERRAIN_DATA_DIR := "user://terrain_data/"

## Terrain3D configuration
const REGION_SIZE := 64  # Vertices per region (power of 2)

## Signals
signal terrain_ready
signal preprocessing_progress(percent: float, message: String)
signal preprocessing_complete(stats: Dictionary)

## The Terrain3D node - handles all rendering, LOD, and streaming
var terrain_3d: Terrain3D

## Terrain manager for data conversion
var _terrain_manager: RefCounted

## Texture loader for LTEX conversion
var _texture_loader: RefCounted

## Configuration
var _cell_size_godot: float
var _vertex_spacing: float
var _initialized := false

## Statistics
var _stats := {
	"regions_loaded": 0,
	"total_regions": 0,
	"using_preprocessed": false,
}


func _ready() -> void:
	_terrain_manager = TerrainManagerScript.new()
	_texture_loader = TerrainTextureLoaderScript.new()
	_cell_size_godot = MWCoords.CELL_SIZE_GODOT
	_vertex_spacing = _cell_size_godot / float(REGION_SIZE)


## Initialize the world terrain system
## If pre-processed data exists, uses it. Otherwise, offers to generate it.
func initialize(data_path: String = "") -> Error:
	if _initialized:
		return OK

	# Create Terrain3D node
	terrain_3d = Terrain3D.new()
	terrain_3d.name = "Terrain3D"
	add_child(terrain_3d)

	# Create required sub-resources
	terrain_3d.set_data(Terrain3DData.new())
	terrain_3d.set_material(Terrain3DMaterial.new())
	terrain_3d.set_assets(Terrain3DAssets.new())

	# Configure region size and vertex spacing to match MW cells
	terrain_3d.change_region_size(64)
	terrain_3d.vertex_spacing = _vertex_spacing

	# Configure material for best visuals
	_configure_material()

	# Check for pre-processed data
	if _has_preprocessed_data():
		print("WorldTerrain: Loading pre-processed terrain data...")
		var err := _load_preprocessed_data()
		if err == OK:
			_stats["using_preprocessed"] = true
			_initialized = true
			terrain_ready.emit()
			return OK
		else:
			push_warning("Failed to load pre-processed data, falling back to live conversion")

	# No pre-processed data - need to generate or use live mode
	if data_path.is_empty():
		data_path = SettingsManager.get_data_path()

	if data_path.is_empty():
		push_error("WorldTerrain: No data path provided. Set MORROWIND_DATA_PATH environment variable or use settings UI.")
		return ERR_UNCONFIGURED

	print("WorldTerrain: No pre-processed data found. Use preprocess_terrain() to generate.")
	_initialized = true
	terrain_ready.emit()
	return OK


## Configure Terrain3D material for optimal Morrowind visuals
func _configure_material() -> void:
	if not terrain_3d or not terrain_3d.material:
		return

	var mat := terrain_3d.material

	# Show vertex colors (MW uses these for ambient occlusion/shading)
	mat.show_colormap = true

	# Enable auto-shader for texture blending
	mat.auto_shader = true

	# Configure for outdoor terrain
	mat.world_background = Terrain3DMaterial.NONE  # We handle sky separately


## Check if pre-processed terrain data exists
func _has_preprocessed_data() -> bool:
	var dir := DirAccess.open(TERRAIN_DATA_DIR)
	if not dir:
		return false

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.ends_with(".res"):
			dir.list_dir_end()
			return true
		file_name = dir.get_next()
	dir.list_dir_end()
	return false


## Load pre-processed terrain data
func _load_preprocessed_data() -> Error:
	if not terrain_3d or not terrain_3d.data:
		return ERR_UNCONFIGURED

	var path := ProjectSettings.globalize_path(TERRAIN_DATA_DIR)
	terrain_3d.data.load_directory(path)

	_stats["regions_loaded"] = terrain_3d.data.get_region_count()
	_stats["total_regions"] = _stats["regions_loaded"]

	print("WorldTerrain: Loaded %d terrain regions" % _stats["regions_loaded"])
	return OK


## Pre-process all Morrowind terrain into Terrain3D region files
## This is a one-time operation that enables native streaming/LOD
func preprocess_terrain(data_path: String) -> Error:
	var start_time := Time.get_ticks_msec()

	# Ensure output directory exists
	var dir := DirAccess.open("user://")
	if not dir:
		return ERR_CANT_CREATE

	if not dir.dir_exists("terrain_data"):
		dir.make_dir("terrain_data")

	# Load game data if needed
	preprocessing_progress.emit(0.0, "Loading game data...")
	await get_tree().process_frame

	if BSAManager.get_archive_count() == 0:
		BSAManager.load_archives_from_directory(data_path)

	if ESMManager.lands.is_empty():
		var esm_path := data_path.path_join("Morrowind.esm")
		var err := ESMManager.load_file(esm_path)
		if err != OK:
			return err

	var total_cells := ESMManager.lands.size()
	print("WorldTerrain: Pre-processing %d terrain cells..." % total_cells)

	# Ensure Terrain3D is configured
	if not terrain_3d:
		initialize()

	# Load LTEX textures into Terrain3D assets
	preprocessing_progress.emit(2.0, "Loading terrain textures...")
	await get_tree().process_frame
	var textures_loaded: int = _texture_loader.load_terrain_textures(terrain_3d.assets)
	print("WorldTerrain: Loaded %d terrain textures" % textures_loaded)

	# Update terrain manager with texture slot mapping
	_terrain_manager.set_texture_slot_mapper(_texture_loader)

	# Clear existing data
	for region in terrain_3d.data.get_regions_active():
		terrain_3d.data.remove_region(region, false)

	# Process all LAND records
	var processed := 0
	var skipped := 0
	var cell_keys := ESMManager.lands.keys()

	# Sort for consistent ordering
	cell_keys.sort()

	for key in cell_keys:
		var land: LandRecord = ESMManager.lands[key]

		if not land or not land.has_heights():
			skipped += 1
			continue

		# Progress update
		var percent := (float(processed) / float(total_cells)) * 90.0
		preprocessing_progress.emit(percent, "Processing cell (%d, %d)..." % [land.cell_x, land.cell_y])

		# Import cell
		_import_land_record(land)
		processed += 1

		# Yield to prevent freezing
		if processed % 100 == 0:
			await get_tree().process_frame

	# Calculate height range
	preprocessing_progress.emit(92.0, "Calculating height range...")
	await get_tree().process_frame
	terrain_3d.data.calc_height_range(true)

	# Save to disk
	preprocessing_progress.emit(95.0, "Saving terrain data...")
	await get_tree().process_frame

	var save_path := ProjectSettings.globalize_path(TERRAIN_DATA_DIR)
	terrain_3d.data.save_directory(save_path)

	var elapsed := Time.get_ticks_msec() - start_time
	var stats := {
		"processed": processed,
		"skipped": skipped,
		"regions": terrain_3d.data.get_region_count(),
		"elapsed_ms": elapsed,
		"output_path": save_path,
	}

	_stats["total_regions"] = stats["regions"]
	_stats["regions_loaded"] = stats["regions"]
	_stats["using_preprocessed"] = true

	preprocessing_progress.emit(100.0, "Complete!")
	preprocessing_complete.emit(stats)

	print("WorldTerrain: Pre-processing complete!")
	print("  Processed: %d cells" % processed)
	print("  Skipped: %d cells (no height data)" % skipped)
	print("  Regions: %d" % stats["regions"])
	print("  Time: %.2f seconds" % (elapsed / 1000.0))
	print("  Output: %s" % save_path)

	return OK


## Import a single LAND record into Terrain3D
func _import_land_record(land: LandRecord) -> void:
	# Generate maps (65x65)
	var heightmap: Image = _terrain_manager.generate_heightmap(land)
	var colormap: Image = _terrain_manager.generate_color_map(land)
	var controlmap: Image = _terrain_manager.generate_control_map(land)

	# Resize to region size (64x64)
	heightmap.resize(REGION_SIZE, REGION_SIZE, Image.INTERPOLATE_BILINEAR)
	colormap.resize(REGION_SIZE, REGION_SIZE, Image.INTERPOLATE_BILINEAR)
	controlmap.resize(REGION_SIZE, REGION_SIZE, Image.INTERPOLATE_NEAREST)

	# Calculate world position
	var region_world_size := float(REGION_SIZE) * _vertex_spacing
	var world_x := float(land.cell_x) * region_world_size + region_world_size * 0.5
	var world_z := float(-land.cell_y) * region_world_size + region_world_size * 0.5

	# Import
	var images: Array[Image] = []
	images.resize(Terrain3DRegion.TYPE_MAX)
	images[Terrain3DRegion.TYPE_HEIGHT] = heightmap
	images[Terrain3DRegion.TYPE_CONTROL] = controlmap
	images[Terrain3DRegion.TYPE_COLOR] = colormap

	terrain_3d.data.import_images(images, Vector3(world_x, 0, world_z), 0.0, 1.0)


## Convert MW cell coordinates to Godot world position
func cell_to_world(cell_x: int, cell_y: int) -> Vector3:
	var region_world_size := float(REGION_SIZE) * _vertex_spacing
	return Vector3(
		float(cell_x) * region_world_size + region_world_size * 0.5,
		0.0,
		float(-cell_y) * region_world_size + region_world_size * 0.5
	)


## Convert Godot world position to MW cell coordinates
func world_to_cell(world_pos: Vector3) -> Vector2i:
	var region_world_size := float(REGION_SIZE) * _vertex_spacing
	return Vector2i(
		int(floor(world_pos.x / region_world_size)),
		int(floor(-world_pos.z / region_world_size))
	)


## Get terrain height at world position
func get_height_at(world_pos: Vector3) -> float:
	if not terrain_3d or not terrain_3d.data:
		return 0.0
	return terrain_3d.data.get_height(world_pos)


## Get terrain normal at world position
func get_normal_at(world_pos: Vector3) -> Vector3:
	if not terrain_3d or not terrain_3d.data:
		return Vector3.UP
	return terrain_3d.data.get_normal(world_pos)


## Get statistics
func get_stats() -> Dictionary:
	if terrain_3d and terrain_3d.data:
		_stats["regions_loaded"] = terrain_3d.data.get_region_count()
	return _stats.duplicate()


## Move camera/player to a specific cell
func teleport_to_cell(cell_x: int, cell_y: int) -> Vector3:
	var world_pos := cell_to_world(cell_x, cell_y)
	var height := get_height_at(world_pos)
	if is_nan(height):
		height = 0.0
	return Vector3(world_pos.x, height + 10.0, world_pos.z)
