## Terrain Pre-Processor
## Converts all Morrowind LAND records to Terrain3D region files for native streaming/LOD
##
## This tool pre-processes the entire Morrowind world into Terrain3D's native format,
## enabling modern features like:
## - Geometric clipmap LOD (like The Witcher 3)
## - Per-region file streaming
## - Distant lands rendering
## - Dynamic collision generation
##
## Usage:
##   1. Run this tool once to generate terrain region files
##   2. At runtime, Terrain3D loads regions on-demand
##   3. No ESM parsing needed for terrain at runtime
##
## Output: user://terrain_data/ folder with .res files per region
extends Node

const MWCoords := preload("res://src/core/morrowind_coords.gd")
const TerrainManagerScript := preload("res://src/core/world/terrain_manager.gd")

## Output directory for pre-processed terrain data
const OUTPUT_DIR := "user://terrain_data/"

## Terrain3D configuration
## Terrain3D has a 32x32 region grid limit (-16 to +15 indices)
## With region_size=64, each region = one MW cell, giving range -16 to +15
## Morrowind actual bounds: X: -18 to 23, Y: -19 to 27
## This covers most of Vvardenfell but clips edges and Solstheim (Y > 15)
## TODO: Implement 2x2 cell combining for region_size=128 to cover full map
const REGION_SIZE := 64  # Terrain3D region size (vertices) - one MW cell per region
const MW_LAND_SIZE := 65  # Morrowind heightmap size per cell

## Progress tracking
signal progress_updated(percent: float, message: String)
signal processing_complete(stats: Dictionary)

var terrain_manager: RefCounted
var texture_loader: RefCounted  # Optional TerrainTextureLoader for proper texture mapping
var _stats: Dictionary = {
	"total_cells": 0,
	"processed_cells": 0,
	"skipped_cells": 0,
	"regions_saved": 0,
	"elapsed_ms": 0,
}


func _ready() -> void:
	terrain_manager = TerrainManagerScript.new()


## Pre-process all Morrowind LAND records into Terrain3D region files
## This is a one-time operation that generates native Terrain3D data
func preprocess_all_terrain(data_path: String) -> Error:
	var start_time := Time.get_ticks_msec()

	# Ensure output directory exists
	var dir := DirAccess.open("user://")
	if not dir:
		push_error("Cannot access user:// directory")
		return ERR_CANT_CREATE

	if not dir.dir_exists("terrain_data"):
		var err := dir.make_dir("terrain_data")
		if err != OK:
			push_error("Failed to create terrain_data directory: %s" % error_string(err))
			return err

	# Load BSA and ESM if not already loaded
	emit_signal("progress_updated", 0.0, "Loading game data...")

	if BSAManager.get_archive_count() == 0:
		BSAManager.load_archives_from_directory(data_path)

	if ESMManager.lands.is_empty():
		var esm_path := data_path.path_join("Morrowind.esm")
		var err := ESMManager.load_file(esm_path)
		if err != OK:
			push_error("Failed to load ESM: %s" % error_string(err))
			return err

	_stats["total_cells"] = ESMManager.lands.size()
	print("Found %d LAND records to process" % _stats["total_cells"])

	# Create a temporary Terrain3D for configuration
	# Note: Terrain3D.data is read-only and created automatically
	var terrain := Terrain3D.new()
	terrain.set_material(Terrain3DMaterial.new())
	terrain.set_assets(Terrain3DAssets.new())

	# Configure for full Morrowind map coverage (see REGION_SIZE constant)
	var cell_size_godot := MWCoords.CELL_SIZE_GODOT
	terrain.change_region_size(REGION_SIZE)
	terrain.vertex_spacing = cell_size_godot / 64.0

	# Load terrain textures if texture_loader is available
	if texture_loader and texture_loader.has_method("load_terrain_textures"):
		var textures_loaded: int = texture_loader.load_terrain_textures(terrain.assets)
		print("Loaded %d terrain textures" % textures_loaded)
		terrain_manager.set_texture_slot_mapper(texture_loader)

	# Process all LAND records
	var processed := 0
	var cell_keys := ESMManager.lands.keys()

	for key in cell_keys:
		var land: LandRecord = ESMManager.lands[key]
		if not land or not land.has_heights():
			_stats["skipped_cells"] += 1
			continue

		# Update progress
		var percent := (float(processed) / float(_stats["total_cells"])) * 100.0
		emit_signal("progress_updated", percent, "Processing cell (%d, %d)..." % [land.cell_x, land.cell_y])

		# Generate and import this cell
		_import_cell(terrain, land)

		processed += 1
		_stats["processed_cells"] = processed

		# Yield occasionally to prevent freezing
		if processed % 50 == 0:
			await get_tree().process_frame

	# Save all regions to disk
	emit_signal("progress_updated", 95.0, "Saving terrain data...")
	await get_tree().process_frame

	var save_path := ProjectSettings.globalize_path(OUTPUT_DIR)
	terrain.data.save_directory(save_path)
	_stats["regions_saved"] = terrain.data.get_region_count()

	# Cleanup
	terrain.queue_free()

	_stats["elapsed_ms"] = Time.get_ticks_msec() - start_time

	emit_signal("progress_updated", 100.0, "Complete!")
	emit_signal("processing_complete", _stats)

	print("Terrain pre-processing complete:")
	print("  Processed: %d cells" % _stats["processed_cells"])
	print("  Skipped: %d cells" % _stats["skipped_cells"])
	print("  Regions saved: %d" % _stats["regions_saved"])
	print("  Time: %.2f seconds" % (_stats["elapsed_ms"] / 1000.0))
	print("  Output: %s" % save_path)

	return OK


## Import a single LAND record into the Terrain3D data
## Uses TerrainManager.import_cell_to_terrain() for unified logic
func _import_cell(terrain: Terrain3D, land: LandRecord) -> void:
	if not terrain_manager.import_cell_to_terrain(terrain, land):
		_stats["skipped_cells"] += 1


## Get the output directory path (globalized)
static func get_output_path() -> String:
	return ProjectSettings.globalize_path(OUTPUT_DIR)


## Check if pre-processed terrain data exists
static func has_preprocessed_data() -> bool:
	var dir := DirAccess.open(OUTPUT_DIR)
	if not dir:
		return false

	# Look for .res files
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.ends_with(".res"):
			dir.list_dir_end()
			return true
		file_name = dir.get_next()
	dir.list_dir_end()
	return false


## Get statistics about pre-processed data
static func get_preprocessed_stats() -> Dictionary:
	var stats := {
		"exists": false,
		"region_count": 0,
		"total_size_mb": 0.0,
	}

	var dir := DirAccess.open(OUTPUT_DIR)
	if not dir:
		return stats

	stats["exists"] = true
	var total_size := 0

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.ends_with(".res"):
			stats["region_count"] += 1
			var file_path := OUTPUT_DIR.path_join(file_name)
			var file := FileAccess.open(file_path, FileAccess.READ)
			if file:
				total_size += file.get_length()
				file.close()
		file_name = dir.get_next()
	dir.list_dir_end()

	stats["total_size_mb"] = total_size / (1024.0 * 1024.0)
	return stats
