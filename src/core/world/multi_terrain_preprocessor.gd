## Multi-Terrain Preprocessor - Generates chunk-based terrain data for infinite worlds
##
## This preprocessor divides the world into chunks, each stored in its own directory.
## Compatible with MultiTerrainManager for runtime streaming.
##
## Directory structure:
##   terrain_chunks/
##   ├── chunk_0_0/
##   │   ├── region_-16_-16.res
##   │   ├── region_-16_-15.res
##   │   └── ...
##   ├── chunk_0_1/
##   │   └── ...
##   └── chunk_-1_0/
##       └── ...
##
## Each chunk contains up to 32x32 cells (1024 regions).
## The chunk coordinate system is independent of MW cell coordinates.
class_name MultiTerrainPreprocessor
extends Node

const MWCoords := preload("res://src/core/morrowind_coords.gd")
const TerrainManagerScript := preload("res://src/core/world/terrain_manager.gd")

## Output base directory
const OUTPUT_BASE_DIR := "user://terrain_chunks/"

## Cells per chunk (max 32 due to Terrain3D's region limit)
const CELLS_PER_CHUNK := 32

## Terrain3D region size
const REGION_SIZE := 64

## Progress signals
signal progress_updated(percent: float, message: String)
signal chunk_complete(chunk_coord: Vector2i, cell_count: int)
signal processing_complete(stats: Dictionary)

var terrain_manager: RefCounted

var _stats: Dictionary = {
	"total_cells": 0,
	"processed_cells": 0,
	"skipped_cells": 0,
	"chunks_created": 0,
	"elapsed_ms": 0,
}


func _init() -> void:
	terrain_manager = TerrainManagerScript.new()


## Preprocess all terrain, organizing into chunks
## Returns OK on success
func preprocess_all_terrain(data_path: String) -> Error:
	var start_time := Time.get_ticks_msec()

	# Ensure base directory exists
	_ensure_directory(OUTPUT_BASE_DIR)

	# Load BSA and ESM if not already loaded
	progress_updated.emit(0.0, "Loading game data...")

	if BSAManager.get_archive_count() == 0:
		BSAManager.load_archives_from_directory(data_path)

	if ESMManager.lands.is_empty():
		var esm_path := data_path.path_join("Morrowind.esm")
		var err := ESMManager.load_file(esm_path)
		if err != OK:
			push_error("Failed to load ESM: %s" % error_string(err))
			return err

	_stats["total_cells"] = ESMManager.lands.size()

	# Group cells by chunk
	progress_updated.emit(5.0, "Organizing cells into chunks...")
	var chunks := _group_cells_by_chunk()

	print("Found %d LAND records organized into %d chunks" % [_stats["total_cells"], chunks.size()])

	# Process each chunk
	var chunks_processed := 0
	var total_chunks := chunks.size()

	for chunk_coord in chunks:
		var cells: Array = chunks[chunk_coord]

		var percent := 5.0 + (float(chunks_processed) / float(total_chunks)) * 90.0
		progress_updated.emit(percent, "Processing chunk (%d, %d) with %d cells..." % [
			chunk_coord.x, chunk_coord.y, cells.size()
		])

		var processed := await _process_chunk(chunk_coord, cells)
		if processed > 0:
			_stats["chunks_created"] += 1
			chunk_complete.emit(chunk_coord, processed)

		chunks_processed += 1

	_stats["elapsed_ms"] = Time.get_ticks_msec() - start_time

	progress_updated.emit(100.0, "Complete!")
	processing_complete.emit(_stats)

	print("\nMulti-terrain pre-processing complete:")
	print("  Chunks created: %d" % _stats["chunks_created"])
	print("  Cells processed: %d" % _stats["processed_cells"])
	print("  Cells skipped: %d" % _stats["skipped_cells"])
	print("  Time: %.2f seconds" % (_stats["elapsed_ms"] / 1000.0))
	print("  Output: %s" % ProjectSettings.globalize_path(OUTPUT_BASE_DIR))

	return OK


## Group all LAND records by their chunk coordinate
func _group_cells_by_chunk() -> Dictionary:
	var chunks: Dictionary = {}  # Vector2i -> Array[LandRecord]

	for key in ESMManager.lands:
		var land: LandRecord = ESMManager.lands[key]
		if not land or not land.has_heights():
			_stats["skipped_cells"] += 1
			continue

		var chunk_coord := _cell_to_chunk(land.cell_x, land.cell_y)

		if chunk_coord not in chunks:
			chunks[chunk_coord] = []
		chunks[chunk_coord].append(land)

	return chunks


## Convert MW cell coordinate to chunk coordinate
func _cell_to_chunk(cell_x: int, cell_y: int) -> Vector2i:
	# Use floor division to handle negative coordinates correctly
	var chunk_x := floori(float(cell_x + CELLS_PER_CHUNK / 2) / CELLS_PER_CHUNK)
	var chunk_y := floori(float(cell_y + CELLS_PER_CHUNK / 2) / CELLS_PER_CHUNK)
	return Vector2i(chunk_x, chunk_y)


## Convert MW cell coordinate to local coordinate within chunk (-16 to +15)
func _cell_to_local(cell_x: int, cell_y: int, chunk_coord: Vector2i) -> Vector2i:
	var base_x := chunk_coord.x * CELLS_PER_CHUNK - CELLS_PER_CHUNK / 2
	var base_y := chunk_coord.y * CELLS_PER_CHUNK - CELLS_PER_CHUNK / 2
	return Vector2i(cell_x - base_x, cell_y - base_y)


## Process a single chunk, creating its Terrain3D data
func _process_chunk(chunk_coord: Vector2i, cells: Array) -> int:
	# Create chunk directory
	var chunk_dir := OUTPUT_BASE_DIR.path_join("chunk_%d_%d" % [chunk_coord.x, chunk_coord.y])
	_ensure_directory(chunk_dir)

	# Create temporary Terrain3D for this chunk
	# IMPORTANT: Terrain3D MUST be added to scene tree for proper initialization
	# Its internal Terrain3DData requires a valid rendering context
	var terrain := Terrain3D.new()
	terrain.name = "TempTerrain_%d_%d" % [chunk_coord.x, chunk_coord.y]

	# Add to scene tree BEFORE configuring - required for Terrain3DData initialization
	add_child(terrain)

	# Wait a frame for Terrain3D to fully initialize its internal resources
	await get_tree().process_frame

	terrain.set_material(Terrain3DMaterial.new())
	terrain.set_assets(Terrain3DAssets.new())

	# Configure terrain
	var cell_size_godot := MWCoords.CELL_SIZE_GODOT
	terrain.change_region_size(REGION_SIZE)
	terrain.vertex_spacing = cell_size_godot / 64.0

	var processed := 0
	var batch_count := 0

	for land in cells:
		var local_coord := _cell_to_local(land.cell_x, land.cell_y, chunk_coord)

		# Validate local coordinate is within chunk bounds
		if local_coord.x < -16 or local_coord.x > 15 or local_coord.y < -16 or local_coord.y > 15:
			_stats["skipped_cells"] += 1
			continue

		_import_cell(terrain, land, local_coord)
		processed += 1
		_stats["processed_cells"] += 1
		batch_count += 1

		# Yield every 10 cells to prevent resource exhaustion and allow UI updates
		if batch_count >= 10:
			batch_count = 0
			await get_tree().process_frame

	# Save chunk data if we processed any cells
	if processed > 0:
		# Wait a frame to ensure all terrain operations complete
		await get_tree().process_frame
		var save_path := ProjectSettings.globalize_path(chunk_dir)
		terrain.data.save_directory(save_path)

	# Remove from scene tree and free immediately
	# Using remove_child + free() instead of queue_free() for immediate cleanup
	remove_child(terrain)
	terrain.free()

	return processed


## Import a single cell into the terrain at the given local coordinate
## Uses TerrainManager.import_cell_to_terrain() for unified logic
func _import_cell(terrain: Terrain3D, land: LandRecord, local_coord: Vector2i) -> void:
	# Use local_coord for positioning within the chunk (-16 to +15 range)
	terrain_manager.import_cell_to_terrain(terrain, land, local_coord, true)


## Ensure a directory exists
func _ensure_directory(path: String) -> void:
	var global_path := ProjectSettings.globalize_path(path)
	if not DirAccess.dir_exists_absolute(global_path):
		DirAccess.make_dir_recursive_absolute(global_path)


## Get output path
static func get_output_path() -> String:
	return ProjectSettings.globalize_path(OUTPUT_BASE_DIR)


## Check if preprocessed chunk data exists
static func has_preprocessed_data() -> bool:
	var dir := DirAccess.open(OUTPUT_BASE_DIR)
	if not dir:
		return false

	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if dir.current_is_dir() and name.begins_with("chunk_"):
			dir.list_dir_end()
			return true
		name = dir.get_next()
	dir.list_dir_end()
	return false


## Get list of available chunks
static func get_available_chunks() -> Array[Vector2i]:
	var chunks: Array[Vector2i] = []

	var dir := DirAccess.open(OUTPUT_BASE_DIR)
	if not dir:
		return chunks

	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if dir.current_is_dir() and name.begins_with("chunk_"):
			# Parse chunk coordinate from directory name
			var parts := name.replace("chunk_", "").split("_")
			if parts.size() == 2:
				chunks.append(Vector2i(int(parts[0]), int(parts[1])))
		name = dir.get_next()
	dir.list_dir_end()

	return chunks
