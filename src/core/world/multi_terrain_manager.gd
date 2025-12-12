## Multi-Terrain Manager - Infinite world support via multiple Terrain3D instances
##
## Terrain3D has a 32x32 region limit (~65km max with region_size=2048).
## For larger worlds, we use multiple Terrain3D instances arranged in a grid,
## streaming them in/out as the player moves.
##
## Architecture:
##   - World is divided into "terrain chunks", each handled by one Terrain3D
##   - Each chunk covers CHUNK_SIZE × CHUNK_SIZE cells (default 32x32)
##   - Active chunks around the player are loaded, distant ones unloaded
##   - Seamless transitions - adjacent chunks share edge vertices
##
## Memory Management:
##   - Only LOAD_RADIUS chunks are active at once (e.g., 3x3 = 9 chunks max)
##   - Terrain data is streamed from disk, not kept in memory
##   - Each chunk's .res files are in separate directories
##
## Example world sizes:
##   - 1 chunk (32x32 cells): ~3.7km × 3.7km (Morrowind main island)
##   - 3x3 chunks: ~11km × 11km
##   - 10x10 chunks: ~37km × 37km (larger than GTA V)
##   - 100x100 chunks: ~370km × 370km (Daggerfall scale possible)
##
## Usage:
##   var multi_terrain = MultiTerrainManager.new()
##   add_child(multi_terrain)
##   multi_terrain.initialize(terrain_data_base_path)
##   multi_terrain.set_tracked_node(player)
class_name MultiTerrainManager
extends Node3D

const MWCoords := preload("res://src/core/morrowind_coords.gd")

## Size of each terrain chunk in MW cells
## With region_size=64, max is 32 cells per Terrain3D (-16 to +15)
## Use 32 for maximum coverage per chunk, or smaller for faster streaming
@export var chunk_size_cells: int = 32

## How many chunks to keep loaded around the player (radius)
## 1 = 3x3 grid (9 chunks), 2 = 5x5 grid (25 chunks)
@export var load_radius: int = 1

## Base directory for terrain chunk data
## Each chunk stored in: {base_path}/chunk_{x}_{y}/
@export var terrain_data_base_path: String = "user://terrain_chunks/"

## Terrain3D settings (applied to each chunk)
@export var region_size: int = 64
@export var vertex_spacing: float = 0.0  # 0 = auto-calculate from cell size

#region LOD Settings
## Enable LOD scaling for distant chunks (reduces detail for performance)
@export var lod_enabled: bool = true

## Distance thresholds for LOD levels (in chunk units, not meters)
## Chunks at distance 0 (player's chunk) get full detail
## Chunks at distance >= lod_medium_distance get medium LOD
## Chunks at distance >= lod_low_distance get low LOD
@export var lod_medium_distance: int = 1
@export var lod_low_distance: int = 2

## Mesh LOD bias applied to distant chunks (higher = lower detail)
## Terrain3D uses this to select coarser mesh levels
@export var lod_bias_medium: float = 1.0
@export var lod_bias_low: float = 2.0

## Render distance multiplier for distant chunks
## 1.0 = full render distance, 0.5 = half render distance
@export var render_distance_medium: float = 0.75
@export var render_distance_low: float = 0.5
#endregion

#region On-the-fly Generation Settings
## Enable on-the-fly terrain generation when no pre-processed data exists
@export var generate_on_fly: bool = true

## TerrainManager for on-the-fly generation (must be set externally)
var terrain_manager: RefCounted = null

## Signal for terrain generation progress
signal terrain_generated(chunk_coord: Vector2i, cells_generated: int)
#endregion

## Signals
signal chunk_loading(chunk_coord: Vector2i)
signal chunk_loaded(chunk_coord: Vector2i, terrain: Node)
signal chunk_unloaded(chunk_coord: Vector2i)
signal player_chunk_changed(old_chunk: Vector2i, new_chunk: Vector2i)

## Active terrain chunks: chunk_coord -> Terrain3D node
var _active_chunks: Dictionary = {}

## Currently loading chunks (to prevent double-loading)
var _loading_chunks: Dictionary = {}

## The node we're tracking for position (player/camera)
var _tracked_node: Node3D = null

## Current chunk the tracked node is in
var _current_chunk: Vector2i = Vector2i(0, 0)

## Calculated values
var _cell_world_size: float = 0.0
var _chunk_world_size: float = 0.0

## Shared Terrain3D resources (material, assets) for consistency
var _shared_material: Resource = null  # Terrain3DMaterial
var _shared_assets: Resource = null    # Terrain3DAssets


func _ready() -> void:
	# Calculate world sizes
	_cell_world_size = MWCoords.CELL_SIZE_GODOT
	_chunk_world_size = _cell_world_size * chunk_size_cells

	if vertex_spacing <= 0:
		vertex_spacing = _cell_world_size / 64.0


## Initialize the multi-terrain system
func initialize(data_path: String = "") -> void:
	if not data_path.is_empty():
		terrain_data_base_path = data_path

	# Create shared resources for visual consistency across chunks
	_shared_material = _create_shared_material()
	_shared_assets = _create_shared_assets()

	print("MultiTerrainManager initialized:")
	print("  Chunk size: %d cells (%.1fm)" % [chunk_size_cells, _chunk_world_size])
	print("  Load radius: %d (up to %d chunks)" % [load_radius, (2 * load_radius + 1) ** 2])
	print("  Data path: %s" % terrain_data_base_path)


## Set the node to track for chunk streaming
func set_tracked_node(node: Node3D) -> void:
	_tracked_node = node
	if node:
		_update_current_chunk()


func _process(_delta: float) -> void:
	if not _tracked_node:
		return

	# Check if player moved to a new chunk
	var new_chunk := _world_pos_to_chunk(_tracked_node.global_position)
	if new_chunk != _current_chunk:
		var old_chunk := _current_chunk
		_current_chunk = new_chunk
		player_chunk_changed.emit(old_chunk, new_chunk)
		_update_loaded_chunks()

		# Update LOD for all chunks when player changes chunk
		if lod_enabled:
			_update_all_chunk_lods()


## Convert world position to chunk coordinate
func _world_pos_to_chunk(world_pos: Vector3) -> Vector2i:
	# World X maps directly, world Z is negated (Godot Z- = North)
	var chunk_x := floori(world_pos.x / _chunk_world_size)
	var chunk_y := floori(-world_pos.z / _chunk_world_size)
	return Vector2i(chunk_x, chunk_y)


## Convert chunk coordinate to world position (chunk center)
func _chunk_to_world_pos(chunk: Vector2i) -> Vector3:
	var world_x := (chunk.x + 0.5) * _chunk_world_size
	var world_z := -(chunk.y + 0.5) * _chunk_world_size
	return Vector3(world_x, 0, world_z)


## Update which chunks should be loaded based on player position
func _update_loaded_chunks() -> void:
	var needed_chunks: Array[Vector2i] = []

	# Determine which chunks should be loaded
	for dx in range(-load_radius, load_radius + 1):
		for dy in range(-load_radius, load_radius + 1):
			needed_chunks.append(Vector2i(_current_chunk.x + dx, _current_chunk.y + dy))

	# Unload chunks that are no longer needed
	var chunks_to_unload: Array[Vector2i] = []
	for chunk_coord in _active_chunks:
		if chunk_coord not in needed_chunks:
			chunks_to_unload.append(chunk_coord)

	for chunk_coord in chunks_to_unload:
		_unload_chunk(chunk_coord)

	# Load chunks that are needed but not loaded
	for chunk_coord in needed_chunks:
		if chunk_coord not in _active_chunks and chunk_coord not in _loading_chunks:
			_load_chunk_async(chunk_coord)


## Update current chunk from tracked node position
func _update_current_chunk() -> void:
	if _tracked_node:
		_current_chunk = _world_pos_to_chunk(_tracked_node.global_position)
		_update_loaded_chunks()


## Load a terrain chunk asynchronously
func _load_chunk_async(chunk_coord: Vector2i) -> void:
	if chunk_coord in _loading_chunks:
		return

	_loading_chunks[chunk_coord] = true
	chunk_loading.emit(chunk_coord)

	# Check if chunk data exists
	var chunk_path := _get_chunk_data_path(chunk_coord)
	var has_preprocess_data := _chunk_data_exists(chunk_path)

	# If no pre-processed data and on-the-fly generation is disabled, skip
	if not has_preprocess_data and not generate_on_fly:
		_loading_chunks.erase(chunk_coord)
		return

	# Create Terrain3D for this chunk
	# IMPORTANT: Must add to scene tree BEFORE configuring due to Terrain3D requirements
	var terrain := _create_terrain_for_chunk(chunk_coord)
	if not terrain:
		_loading_chunks.erase(chunk_coord)
		return

	# Add to scene tree BEFORE any configuration - Terrain3D requires this
	add_child(terrain)

	# Wait a frame for Terrain3D to fully initialize its internal resources
	await get_tree().process_frame

	# Now configure the terrain (after it's in the scene tree)
	_configure_terrain_for_chunk(terrain)

	var data_loaded := false

	if has_preprocess_data:
		# Load pre-processed terrain data
		data_loaded = await _load_chunk_data(terrain, chunk_path)
	elif generate_on_fly and terrain_manager:
		# Generate terrain on-the-fly
		data_loaded = await _generate_chunk_terrain(terrain, chunk_coord)

	if data_loaded:
		# Position the terrain chunk in world space
		terrain.position = _chunk_to_world_pos(chunk_coord) - Vector3(_chunk_world_size / 2.0, 0, -_chunk_world_size / 2.0)

		_active_chunks[chunk_coord] = terrain
		chunk_loaded.emit(chunk_coord, terrain)
	else:
		remove_child(terrain)
		terrain.free()

	_loading_chunks.erase(chunk_coord)


## Unload a terrain chunk
func _unload_chunk(chunk_coord: Vector2i) -> void:
	if chunk_coord not in _active_chunks:
		return

	var terrain: Node = _active_chunks[chunk_coord]
	_active_chunks.erase(chunk_coord)

	# Could save modifications here if terrain editing is supported
	terrain.queue_free()

	chunk_unloaded.emit(chunk_coord)


## Create a Terrain3D instance for a chunk (without configuration)
## IMPORTANT: The terrain must be added to scene tree before calling _configure_terrain_for_chunk
func _create_terrain_for_chunk(chunk_coord: Vector2i) -> Node:
	if not ClassDB.class_exists("Terrain3D"):
		push_error("Terrain3D addon not available")
		return null

	var terrain = ClassDB.instantiate("Terrain3D")
	terrain.name = "TerrainChunk_%d_%d" % [chunk_coord.x, chunk_coord.y]

	# DO NOT configure here - must be done after adding to scene tree
	# Terrain3D's internal Terrain3DData requires a valid rendering context

	return terrain


## Configure a Terrain3D instance after it's been added to the scene tree
## This must be called AFTER add_child(terrain) and await process_frame
func _configure_terrain_for_chunk(terrain: Node) -> void:
	# Terrain3DData is read-only and created automatically by Terrain3D
	# Share material and assets across all chunks for consistency
	terrain.set_material(_shared_material)
	terrain.set_assets(_shared_assets)

	# Configure to match our settings
	terrain.change_region_size(region_size)
	terrain.vertex_spacing = vertex_spacing


## Get the data directory path for a chunk
func _get_chunk_data_path(chunk_coord: Vector2i) -> String:
	return terrain_data_base_path.path_join("chunk_%d_%d" % [chunk_coord.x, chunk_coord.y])


## Check if chunk data exists on disk
func _chunk_data_exists(chunk_path: String) -> bool:
	var global_path := ProjectSettings.globalize_path(chunk_path)
	return DirAccess.dir_exists_absolute(global_path)


## Load chunk data from disk
func _load_chunk_data(terrain: Node, chunk_path: String) -> bool:
	var global_path := ProjectSettings.globalize_path(chunk_path)

	# Terrain3DData.load_directory() loads all .res files in the directory
	if terrain.data and terrain.data.has_method("load_directory"):
		terrain.data.load_directory(global_path)
		return terrain.data.get_region_count() > 0

	return false


## Generate terrain on-the-fly for a chunk
## This generates terrain from LAND records without pre-processing
func _generate_chunk_terrain(terrain: Node, chunk_coord: Vector2i) -> bool:
	if not terrain_manager:
		push_warning("MultiTerrainManager: No terrain_manager set for on-the-fly generation")
		return false

	# Calculate the cell range for this chunk
	# Each chunk covers chunk_size_cells x chunk_size_cells cells
	# Chunk (0,0) covers cells (0,0) to (chunk_size-1, chunk_size-1)
	var base_cell_x := chunk_coord.x * chunk_size_cells
	var base_cell_y := chunk_coord.y * chunk_size_cells

	var cells_generated := 0

	# Generate terrain for each cell in the chunk
	for local_y in range(chunk_size_cells):
		for local_x in range(chunk_size_cells):
			var cell_x := base_cell_x + local_x
			var cell_y := base_cell_y + local_y

			# Get LAND record for this cell
			var land: LandRecord = ESMManager.get_land(cell_x, cell_y)
			if not land or not land.has_heights():
				continue

			# Calculate local coordinate within this chunk's Terrain3D (-16 to +15 range)
			# Since chunk_size_cells is typically 32, we map 0-31 to -16 to +15
			var local_coord := Vector2i(local_x - 16, local_y - 16)

			# Use TerrainManager's unified import method
			if terrain_manager.import_cell_to_terrain(terrain, land, local_coord, true):
				cells_generated += 1

		# Yield occasionally to prevent freezing
		if local_y % 8 == 0:
			await get_tree().process_frame

	if cells_generated > 0:
		terrain_generated.emit(chunk_coord, cells_generated)

	return cells_generated > 0


## Create shared material for all chunks
func _create_shared_material() -> Resource:
	if ClassDB.class_exists("Terrain3DMaterial"):
		return ClassDB.instantiate("Terrain3DMaterial")
	return null


## Create shared assets for all chunks
func _create_shared_assets() -> Resource:
	if ClassDB.class_exists("Terrain3DAssets"):
		return ClassDB.instantiate("Terrain3DAssets")
	return null


## Get the currently active chunks
func get_active_chunks() -> Array[Vector2i]:
	var chunks: Array[Vector2i] = []
	for coord in _active_chunks:
		chunks.append(coord)
	return chunks


## Get the Terrain3D node for a specific chunk (if loaded)
func get_chunk_terrain(chunk_coord: Vector2i) -> Node:
	return _active_chunks.get(chunk_coord)


## Force load a specific chunk (useful for teleporting)
func ensure_chunk_loaded(chunk_coord: Vector2i) -> void:
	if chunk_coord not in _active_chunks and chunk_coord not in _loading_chunks:
		await _load_chunk_async(chunk_coord)


## Teleport to a specific world position, ensuring chunks are loaded
func teleport_to(world_pos: Vector3) -> void:
	var target_chunk := _world_pos_to_chunk(world_pos)
	_current_chunk = target_chunk
	_update_loaded_chunks()

	# Wait for center chunk to load
	while target_chunk in _loading_chunks:
		await get_tree().process_frame


## Get statistics about current state
func get_stats() -> Dictionary:
	return {
		"active_chunks": _active_chunks.size(),
		"loading_chunks": _loading_chunks.size(),
		"current_chunk": _current_chunk,
		"chunk_size_cells": chunk_size_cells,
		"chunk_world_size": _chunk_world_size,
		"total_regions": _count_total_regions(),
	}


func _count_total_regions() -> int:
	var total := 0
	for chunk_coord in _active_chunks:
		var terrain: Node = _active_chunks[chunk_coord]
		if terrain.data:
			total += terrain.data.get_region_count()
	return total


#region LOD Management

## Update LOD settings for all active chunks based on distance from player
func _update_all_chunk_lods() -> void:
	for chunk_coord in _active_chunks:
		var terrain: Node = _active_chunks[chunk_coord]
		_apply_chunk_lod(terrain, chunk_coord)


## Apply LOD settings to a specific chunk based on its distance from player
func _apply_chunk_lod(terrain: Node, chunk_coord: Vector2i) -> void:
	if not terrain or not lod_enabled:
		return

	# Calculate Chebyshev distance (max of x and y distance)
	var distance := maxi(
		absi(chunk_coord.x - _current_chunk.x),
		absi(chunk_coord.y - _current_chunk.y)
	)

	# Determine LOD level based on distance
	var lod_bias: float = 0.0
	var render_scale: float = 1.0

	if distance >= lod_low_distance:
		lod_bias = lod_bias_low
		render_scale = render_distance_low
	elif distance >= lod_medium_distance:
		lod_bias = lod_bias_medium
		render_scale = render_distance_medium

	# Apply LOD bias to Terrain3D material if available
	# Terrain3D uses mesh_lod_offset to adjust LOD selection
	if terrain.material and terrain.material.has_method("set_mesh_lod_offset"):
		terrain.material.set_mesh_lod_offset(lod_bias)

	# Store LOD info as metadata for debugging
	terrain.set_meta("lod_distance", distance)
	terrain.set_meta("lod_bias", lod_bias)
	terrain.set_meta("render_scale", render_scale)

	# Apply render distance scaling via material if supported
	# This affects how far terrain detail extends
	if terrain.material:
		# Terrain3D material properties for LOD control
		if "mesh_vertex_density" in terrain.material:
			# Lower density for distant chunks
			var base_density: float = terrain.material.get("mesh_vertex_density")
			if base_density > 0:
				terrain.material.set("mesh_vertex_density", base_density * render_scale)


## Get the LOD level for a chunk (0=full, 1=medium, 2=low)
func get_chunk_lod_level(chunk_coord: Vector2i) -> int:
	var distance := maxi(
		absi(chunk_coord.x - _current_chunk.x),
		absi(chunk_coord.y - _current_chunk.y)
	)

	if distance >= lod_low_distance:
		return 2
	elif distance >= lod_medium_distance:
		return 1
	return 0


## Manually set LOD level for a specific chunk (for testing/debugging)
func set_chunk_lod_override(chunk_coord: Vector2i, lod_level: int) -> void:
	if chunk_coord not in _active_chunks:
		return

	var terrain: Node = _active_chunks[chunk_coord]
	var lod_bias: float = 0.0

	match lod_level:
		0:
			lod_bias = 0.0
		1:
			lod_bias = lod_bias_medium
		2:
			lod_bias = lod_bias_low
		_:
			lod_bias = float(lod_level)

	if terrain.material and terrain.material.has_method("set_mesh_lod_offset"):
		terrain.material.set_mesh_lod_offset(lod_bias)

	terrain.set_meta("lod_override", lod_level)

#endregion


#region Texture Loading Support

## Set shared assets (textures) for all chunks
## Call this after loading terrain textures to apply to all chunks
func set_shared_assets(assets: Resource) -> void:
	_shared_assets = assets

	# Apply to all active chunks
	for chunk_coord in _active_chunks:
		var terrain: Node = _active_chunks[chunk_coord]
		if terrain:
			terrain.set_assets(assets)


## Set shared material for all chunks
func set_shared_material(material: Resource) -> void:
	_shared_material = material

	# Apply to all active chunks
	for chunk_coord in _active_chunks:
		var terrain: Node = _active_chunks[chunk_coord]
		if terrain:
			terrain.set_material(material)

#endregion
