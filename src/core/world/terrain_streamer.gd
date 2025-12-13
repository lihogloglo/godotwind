## TerrainStreamer - Unified terrain system for infinite Morrowind-scale worlds
##
## Replaces 5 separate systems with one unified abstraction:
##   - MultiTerrainPreprocessor (broken coordinate mapping)
##   - MultiTerrainManager (material race conditions)
##   - TerrainPreprocessor (limited coverage)
##   - WorldTerrain (destroys edge stitching)
##   - (keeps) TerrainManager (proven core, unchanged)
##
## Three modes, one system:
##   PREPROCESS: ESM → disk (run once for faster loading)
##   RUNTIME: disk → GPU (streaming with LOD)
##   ON_THE_FLY: ESM → GPU (live generation, optional caching)
##
## Architecture:
##   - Multiple Terrain3D instances (one per 32×32 cell chunk)
##   - Unified coordinate mapping (cell → chunk → local)
##   - Shared materials/assets across all chunks
##   - Delegates to TerrainManager for all data conversion
class_name TerrainStreamer
extends Node3D

# Preload dependencies
const MWCoords := preload("res://src/core/morrowind_coords.gd")
const TerrainManagerScript := preload("res://src/core/world/terrain_manager.gd")

# ==================== CONSTANTS ====================

## Chunk size in cells (32×32 = max for Terrain3D's region limit)
const CHUNK_SIZE_CELLS := 32

## Terrain3D region size in vertices
const REGION_SIZE := 64

## Default terrain data directory
const TERRAIN_DATA_BASE_DIR := "user://terrain_chunks/"

# ==================== ENUMS ====================

## Operating mode
enum Mode {
	PREPROCESS,   ## ESM → disk (preprocessing)
	RUNTIME,      ## disk → GPU (streaming)
	ON_THE_FLY    ## ESM → GPU (live generation)
}

# ==================== SIGNALS ====================

## Emitted when a chunk is loaded (preprocessing or runtime)
signal chunk_loaded(chunk_coord: Vector2i, terrain: Terrain3D)

## Emitted when a chunk is unloaded (runtime mode only)
signal chunk_unloaded(chunk_coord: Vector2i)

## Emitted when player moves to a different chunk
signal player_chunk_changed(old_chunk: Vector2i, new_chunk: Vector2i)

## Emitted during preprocessing progress
signal progress_updated(percent: float, message: String)

## Emitted when preprocessing completes
signal processing_complete(stats: Dictionary)

## Emitted when on-the-fly generation completes for a chunk
signal terrain_generated(chunk_coord: Vector2i, cells_generated: int)

# ==================== CONFIGURATION ====================

## Current operating mode
var mode: Mode = Mode.RUNTIME

## Base directory for terrain data chunks
var terrain_data_base_path: String = TERRAIN_DATA_BASE_DIR

## Load radius in chunks (for RUNTIME and ON_THE_FLY modes)
## load_radius=1 → 3×3 chunks, load_radius=2 → 5×5 chunks
var load_radius: int = 2

## Enable LOD scaling based on chunk distance
var lod_enabled: bool = true

## Terrain3D region size (should match preprocessing)
var region_size: int = REGION_SIZE

## Vertex spacing (0 = auto-calculate from cell size)
var vertex_spacing: float = 0.0

## Enable on-the-fly chunk generation (ON_THE_FLY mode)
## If false in RUNTIME mode, chunks that don't exist on disk are skipped
var generate_on_fly: bool = false

## Cache generated chunks to disk (ON_THE_FLY mode only)
var cache_generated_chunks: bool = true

# ==================== DEPENDENCIES ====================

## TerrainManager for data conversion (set externally)
var terrain_manager: RefCounted = null

## TerrainTextureLoader for texture mapping (optional, improves quality)
var texture_loader: RefCounted = null

# ==================== RUNTIME STATE ====================

## Active terrain chunks: chunk_coord → Terrain3D
var active_chunks: Dictionary = {}

## Node to track for streaming (usually camera)
var tracked_node: Node3D = null

## Last tracked chunk coordinate
var _last_tracked_chunk: Vector2i = Vector2i(999999, 999999)

## Shared material (created once, used by all chunks)
var _shared_material: Terrain3DMaterial = null

## Shared assets (created once, used by all chunks)
var _shared_assets: Terrain3DAssets = null

## Chunk world size in Godot units
var _chunk_world_size: float = 0.0

## Vertex spacing (calculated or set)
var _vertex_spacing: float = 0.0

## Processing paused flag
var _paused: bool = false

## Statistics
var _stats: Dictionary = {
	"chunks_loaded": 0,
	"chunks_unloaded": 0,
	"chunks_generated": 0,
	"cells_processed": 0,
	"cells_skipped": 0,
}

# ==================== INITIALIZATION ====================

func _ready() -> void:
	# Auto-create terrain manager if not provided
	if not terrain_manager:
		terrain_manager = TerrainManagerScript.new()
		print("[TerrainStreamer] Created default TerrainManager")


## Initialize the streamer
## Must be called after configuration is set
func initialize() -> void:
	# Calculate vertex spacing
	_vertex_spacing = vertex_spacing if vertex_spacing > 0.0 else MWCoords.CELL_SIZE_GODOT / float(region_size)
	_chunk_world_size = float(CHUNK_SIZE_CELLS) * MWCoords.CELL_SIZE_GODOT

	# Create shared material/assets for all chunks
	_create_shared_resources()

	print("[TerrainStreamer] Initialized:")
	print("  Mode: %s" % ["PREPROCESS", "RUNTIME", "ON_THE_FLY"][mode])
	print("  Chunk size: %d×%d cells" % [CHUNK_SIZE_CELLS, CHUNK_SIZE_CELLS])
	print("  Load radius: %d chunks" % load_radius)
	print("  Vertex spacing: %.4f" % _vertex_spacing)
	print("  LOD enabled: %s" % lod_enabled)

	if mode == Mode.RUNTIME or mode == Mode.ON_THE_FLY:
		print("  Coverage: ~%d×%d cells visible" % [
			CHUNK_SIZE_CELLS * (load_radius * 2 + 1),
			CHUNK_SIZE_CELLS * (load_radius * 2 + 1)
		])


## Create shared material and assets (used by all chunks)
func _create_shared_resources() -> void:
	# Create material
	_shared_material = Terrain3DMaterial.new()
	_shared_material.show_checkered = false  # Disable checkered pattern

	# Create assets
	_shared_assets = Terrain3DAssets.new()

	# Load textures if texture_loader is provided
	if texture_loader:
		var textures_loaded: int = texture_loader.load_terrain_textures(_shared_assets)
		print("[TerrainStreamer] Loaded %d terrain textures" % textures_loaded)
		terrain_manager.set_texture_slot_mapper(texture_loader)
	else:
		print("[TerrainStreamer] WARNING: No texture_loader set, using fallback texture mapping")


## Set the node to track for streaming (usually camera)
func set_tracked_node(node: Node3D) -> void:
	tracked_node = node


# ==================== COORDINATE MAPPING (UNIFIED) ====================

## Convert MW cell coordinates to chunk coordinates
## This is the SINGLE SOURCE OF TRUTH for cell→chunk mapping
static func cell_to_chunk(cell_x: int, cell_y: int) -> Vector2i:
	# Pure floor division - no offset math that caused bugs in old systems
	return Vector2i(
		floori(float(cell_x) / CHUNK_SIZE_CELLS),
		floori(float(cell_y) / CHUNK_SIZE_CELLS)
	)


## Convert MW cell coordinates to local coordinates within chunk
## Returns coordinates in range [-16, +15] for Terrain3D
static func cell_to_local(cell_x: int, cell_y: int, chunk_coord: Vector2i) -> Vector2i:
	var base_x := chunk_coord.x * CHUNK_SIZE_CELLS
	var base_y := chunk_coord.y * CHUNK_SIZE_CELLS
	# Offset by -16 to map [0, 31] → [-16, +15]
	return Vector2i(cell_x - base_x - 16, cell_y - base_y - 16)


## Get world position for a chunk (southwest corner)
func chunk_to_world_pos(chunk_coord: Vector2i) -> Vector3:
	return Vector3(
		float(chunk_coord.x) * _chunk_world_size,
		0.0,
		float(-chunk_coord.y) * _chunk_world_size
	)


## Get chunk offsets for a given load radius (returns array of Vector2i)
static func get_chunk_offsets(radius: int) -> Array[Vector2i]:
	var offsets: Array[Vector2i] = []
	for y in range(-radius, radius + 1):
		for x in range(-radius, radius + 1):
			offsets.append(Vector2i(x, y))
	return offsets


# ==================== MODE: PREPROCESS ====================

## Preprocess all terrain data (ESM → disk)
## Groups all cells by chunk, generates terrain for each chunk, saves to disk
func preprocess_all() -> int:
	if mode != Mode.PREPROCESS:
		push_error("[TerrainStreamer] preprocess_all() called but mode is not PREPROCESS")
		return ERR_INVALID_PARAMETER

	progress_updated.emit(0.0, "Organizing cells into chunks...")

	# Ensure base directory exists
	_ensure_directory(terrain_data_base_path)

	# Group all cells by chunk
	var chunks := _group_cells_by_chunk()
	print("[TerrainStreamer] Found %d LAND records in %d chunks" % [
		_stats["cells_processed"] + _stats["cells_skipped"], chunks.size()
	])

	# Process each chunk
	var chunks_processed := 0
	var total_chunks := chunks.size()

	for chunk_coord in chunks:
		var cells: Array = chunks[chunk_coord]

		var percent := 10.0 + (float(chunks_processed) / float(total_chunks)) * 85.0
		progress_updated.emit(percent, "Processing chunk (%d, %d) with %d cells..." % [
			chunk_coord.x, chunk_coord.y, cells.size()
		])

		var processed := await _preprocess_chunk(chunk_coord, cells)
		if processed > 0:
			_stats["chunks_loaded"] += 1

		chunks_processed += 1

	progress_updated.emit(100.0, "Preprocessing complete!")
	processing_complete.emit(_stats)

	print("[TerrainStreamer] Preprocessing complete:")
	print("  Chunks created: %d" % _stats["chunks_loaded"])
	print("  Cells processed: %d" % _stats["cells_processed"])
	print("  Cells skipped: %d" % _stats["cells_skipped"])
	print("  Output: %s" % ProjectSettings.globalize_path(terrain_data_base_path))

	return OK


## Group all LAND records by chunk
func _group_cells_by_chunk() -> Dictionary:
	var chunks: Dictionary = {}  # Vector2i → Array[LandRecord]

	for key in ESMManager.lands:
		var land: LandRecord = ESMManager.lands[key]
		if not land or not land.has_heights():
			_stats["cells_skipped"] += 1
			continue

		var chunk_coord := cell_to_chunk(land.cell_x, land.cell_y)

		if chunk_coord not in chunks:
			chunks[chunk_coord] = []
		chunks[chunk_coord].append(land)
		_stats["cells_processed"] += 1

	return chunks


## Preprocess a single chunk (create terrain, import cells, save to disk)
func _preprocess_chunk(chunk_coord: Vector2i, cells: Array) -> int:
	# Create chunk directory
	var chunk_dir := terrain_data_base_path.path_join("chunk_%d_%d" % [chunk_coord.x, chunk_coord.y])
	_ensure_directory(chunk_dir)

	# Create terrain for this chunk
	var terrain := await _create_chunk_terrain(chunk_coord)
	if not terrain:
		return 0

	# Import all cells in this chunk
	var processed := 0
	var batch_count := 0

	for land in cells:
		var local_coord := cell_to_local(land.cell_x, land.cell_y, chunk_coord)

		# Validate bounds
		if local_coord.x < -16 or local_coord.x > 15 or local_coord.y < -16 or local_coord.y > 15:
			print("[TerrainStreamer] WARNING: Cell (%d, %d) has out-of-bounds local coord (%d, %d) in chunk (%d, %d)" % [
				land.cell_x, land.cell_y, local_coord.x, local_coord.y, chunk_coord.x, chunk_coord.y
			])
			continue

		# Import using proven TerrainManager
		if terrain_manager.import_cell_to_terrain(terrain, land, local_coord, true):
			processed += 1

		batch_count += 1
		if batch_count >= 10:
			batch_count = 0
			await get_tree().process_frame  # Yield to keep responsive

	# Save chunk to disk
	if processed > 0:
		await get_tree().process_frame
		var save_path := ProjectSettings.globalize_path(chunk_dir)
		terrain.data.save_directory(save_path)
		print("[TerrainStreamer] Saved chunk (%d, %d): %d cells → %s" % [
			chunk_coord.x, chunk_coord.y, processed, chunk_dir
		])

	# Cleanup
	remove_child(terrain)
	terrain.free()

	return processed


# ==================== MODE: RUNTIME STREAMING ====================

func _process(_delta: float) -> void:
	if _paused or not tracked_node:
		return

	if mode != Mode.RUNTIME and mode != Mode.ON_THE_FLY:
		return

	# Calculate current chunk from tracked node position
	var pos := tracked_node.global_position
	var cell_x := int(floor(pos.x / MWCoords.CELL_SIZE_GODOT))
	var cell_y := int(floor(-pos.z / MWCoords.CELL_SIZE_GODOT))
	var current_chunk := cell_to_chunk(cell_x, cell_y)

	# Update streaming when chunk changes
	if current_chunk != _last_tracked_chunk:
		_update_chunk_streaming(current_chunk)

		if _last_tracked_chunk != Vector2i(999999, 999999):
			player_chunk_changed.emit(_last_tracked_chunk, current_chunk)

		_last_tracked_chunk = current_chunk


## Update chunk streaming based on current position
func _update_chunk_streaming(center_chunk: Vector2i) -> void:
	var offsets := get_chunk_offsets(load_radius)
	var chunks_to_keep: Dictionary = {}

	# Load nearby chunks
	for offset in offsets:
		var chunk := center_chunk + offset
		chunks_to_keep[chunk] = true

		if chunk not in active_chunks:
			# Load or generate chunk
			if mode == Mode.RUNTIME:
				_load_chunk_async(chunk)
			elif mode == Mode.ON_THE_FLY:
				_generate_chunk_async(chunk)

	# Unload distant chunks
	var chunks_to_unload: Array[Vector2i] = []
	for chunk: Vector2i in active_chunks:
		if chunk not in chunks_to_keep:
			chunks_to_unload.append(chunk)

	for chunk in chunks_to_unload:
		_unload_chunk(chunk)

	# Update LOD if enabled
	if lod_enabled:
		_update_chunk_lod(center_chunk)


## Load a chunk from disk (RUNTIME mode)
func _load_chunk_async(chunk_coord: Vector2i) -> void:
	var chunk_dir := terrain_data_base_path.path_join("chunk_%d_%d" % [chunk_coord.x, chunk_coord.y])
	var chunk_path := ProjectSettings.globalize_path(chunk_dir)

	# Check if chunk exists on disk
	if not DirAccess.dir_exists_absolute(chunk_path):
		if generate_on_fly:
			# Fall back to on-the-fly generation
			_generate_chunk_async(chunk_coord)
		return

	# Create terrain
	var terrain := await _create_chunk_terrain(chunk_coord)
	if not terrain:
		return

	# Load data from disk
	terrain.data.load_directory(chunk_path)
	active_chunks[chunk_coord] = terrain
	_stats["chunks_loaded"] += 1

	chunk_loaded.emit(chunk_coord, terrain)


## Generate a chunk on-the-fly (ON_THE_FLY mode)
func _generate_chunk_async(chunk_coord: Vector2i) -> void:
	# Create terrain
	var terrain := await _create_chunk_terrain(chunk_coord)
	if not terrain:
		return

	# Generate all cells in this chunk
	var cells_generated := 0
	var batch_count := 0

	for local_y in range(CHUNK_SIZE_CELLS):
		for local_x in range(CHUNK_SIZE_CELLS):
			var cell_x := chunk_coord.x * CHUNK_SIZE_CELLS + local_x
			var cell_y := chunk_coord.y * CHUNK_SIZE_CELLS + local_y
			var land: LandRecord = ESMManager.get_land(cell_x, cell_y)

			if land and land.has_heights():
				var local := Vector2i(local_x - 16, local_y - 16)
				if terrain_manager.import_cell_to_terrain(terrain, land, local, true):
					cells_generated += 1

			batch_count += 1
			if batch_count >= 16:
				batch_count = 0
				await get_tree().process_frame  # Yield to keep responsive

	# Save to cache if enabled
	if cache_generated_chunks and cells_generated > 0:
		var chunk_dir := terrain_data_base_path.path_join("chunk_%d_%d" % [chunk_coord.x, chunk_coord.y])
		_ensure_directory(chunk_dir)
		var save_path := ProjectSettings.globalize_path(chunk_dir)
		terrain.data.save_directory(save_path)

	active_chunks[chunk_coord] = terrain
	_stats["chunks_generated"] += 1

	terrain_generated.emit(chunk_coord, cells_generated)
	chunk_loaded.emit(chunk_coord, terrain)


## Unload a chunk (free terrain and remove from active set)
func _unload_chunk(chunk_coord: Vector2i) -> void:
	if chunk_coord not in active_chunks:
		return

	var terrain: Terrain3D = active_chunks[chunk_coord]
	active_chunks.erase(chunk_coord)

	# Remove and free terrain
	if terrain and is_instance_valid(terrain):
		remove_child(terrain)
		terrain.queue_free()

	_stats["chunks_unloaded"] += 1
	chunk_unloaded.emit(chunk_coord)


## Update LOD based on distance from center chunk
func _update_chunk_lod(center_chunk: Vector2i) -> void:
	# Terrain3D handles LOD automatically based on camera distance
	# No manual LOD adjustment needed per chunk
	pass


# ==================== CHUNK LIFECYCLE ====================

## Create a Terrain3D node for a chunk
func _create_chunk_terrain(chunk_coord: Vector2i) -> Terrain3D:
	var terrain := Terrain3D.new()
	terrain.name = "Chunk_%d_%d" % [chunk_coord.x, chunk_coord.y]

	# CRITICAL: Add to scene tree BEFORE configuring
	# Terrain3D requires scene tree presence for Terrain3DData initialization
	add_child(terrain)

	# Wait for full initialization
	await get_tree().process_frame
	await get_tree().process_frame

	# NOW set material/assets (after Terrain3DData exists)
	if _shared_material:
		terrain.set_material(_shared_material)
	if _shared_assets:
		terrain.set_assets(_shared_assets)

	# Configure terrain
	@warning_ignore("int_as_enum_without_cast", "int_as_enum_without_match")
	terrain.change_region_size(region_size)
	terrain.vertex_spacing = _vertex_spacing

	# Position chunk in world grid
	terrain.global_position = chunk_to_world_pos(chunk_coord)

	return terrain


## Ensure directory exists
func _ensure_directory(path: String) -> void:
	var global_path := ProjectSettings.globalize_path(path)
	if not DirAccess.dir_exists_absolute(global_path):
		DirAccess.make_dir_recursive_absolute(global_path)


# ==================== PUBLIC API ====================

## Teleport to a position and load surrounding chunks
func teleport_to(world_pos: Vector3) -> void:
	var cell_x := int(floor(world_pos.x / MWCoords.CELL_SIZE_GODOT))
	var cell_y := int(floor(-world_pos.z / MWCoords.CELL_SIZE_GODOT))
	var target_chunk := cell_to_chunk(cell_x, cell_y)

	# Force immediate update
	_update_chunk_streaming(target_chunk)
	_last_tracked_chunk = target_chunk

	# Wait for chunks to load
	await get_tree().process_frame


## Get streaming statistics
func get_stats() -> Dictionary:
	var stats := _stats.duplicate()
	stats["active_chunks"] = active_chunks.size()
	stats["total_regions"] = 0

	for terrain: Terrain3D in active_chunks.values():
		if terrain and terrain.data:
			stats["total_regions"] += terrain.data.get_region_count()

	return stats


## Pause/resume streaming
func set_paused(paused: bool) -> void:
	_paused = paused


## Check if chunk data exists on disk
static func has_chunk_data(chunk_coord: Vector2i, base_path: String = TERRAIN_DATA_BASE_DIR) -> bool:
	var chunk_dir := base_path.path_join("chunk_%d_%d" % [chunk_coord.x, chunk_coord.y])
	var chunk_path := ProjectSettings.globalize_path(chunk_dir)
	return DirAccess.dir_exists_absolute(chunk_path)


## Get list of available chunks on disk
static func get_available_chunks(base_path: String = TERRAIN_DATA_BASE_DIR) -> Array[Vector2i]:
	var chunks: Array[Vector2i] = []
	var dir := DirAccess.open(base_path)
	if not dir:
		return chunks

	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if dir.current_is_dir() and name.begins_with("chunk_"):
			var parts := name.replace("chunk_", "").split("_")
			if parts.size() == 2:
				chunks.append(Vector2i(int(parts[0]), int(parts[1])))
		name = dir.get_next()
	dir.list_dir_end()

	return chunks
