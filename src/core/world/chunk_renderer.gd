## ChunkRenderer - Coordinates chunk-level rendering for MID/FAR tiers
##
## Manages loading and unloading of chunks (groups of cells) for distant rendering.
## Works with existing DistantStaticRenderer (MID) and ImpostorManager (FAR).
##
## Key features:
## - Loads all per-cell meshes within a chunk as a batch
## - Tracks loaded/unloaded chunks (not individual cells)
## - Computes chunk diffs on camera move (stale vs current pattern)
## - Maintains backwards compatibility with per-cell pre-baked assets
##
## Architecture follows DigitallyTailored/godot4-quadtree patterns:
## - chunks_list / chunks_list_current dictionary diffing
## - Deferred cleanup via queue_free equivalent
##
## Usage:
##   var renderer := ChunkRenderer.new()
##   renderer.configure(chunk_manager, distant_renderer, impostor_manager)
##   renderer.update_chunks(camera_cell)
class_name ChunkRenderer
extends Node3D

const QuadtreeChunkManagerScript := preload("res://src/core/world/quadtree_chunk_manager.gd")
const DistanceTierManagerScript := preload("res://src/core/world/distance_tier_manager.gd")


## Get pre-baked merged cells directory from SettingsManager
func _get_merged_cells_path() -> String:
	return SettingsManager.get_merged_cells_path()

## Reference to QuadtreeChunkManager for chunk calculations
var chunk_manager: RefCounted = null

## Reference to DistantStaticRenderer for MID tier meshes
var distant_renderer: Node3D = null

## Reference to ImpostorManager for FAR tier impostors
var impostor_manager: Node = null

## Reference to tier manager for distance info
var tier_manager: RefCounted = null

## Camera reference for frustum culling
var camera: Camera3D = null

## Enable frustum culling for chunks
var use_frustum_culling: bool = true

## Enable debug output
var debug_enabled: bool = false

## Loaded MID tier chunks: chunk_identifier -> LoadedChunkData
var _loaded_mid_chunks: Dictionary = {}

## Loaded FAR tier chunks: chunk_identifier -> LoadedChunkData
var _loaded_far_chunks: Dictionary = {}

## Current frame's visible chunks (for diffing)
var _current_mid_chunks: Dictionary = {}
var _current_far_chunks: Dictionary = {}

## Stats
var _stats := {
	"mid_chunks_loaded": 0,
	"far_chunks_loaded": 0,
	"mid_cells_loaded": 0,
	"far_cells_loaded": 0,
	"last_update_ms": 0.0,
}


## Chunk tracking data
class LoadedChunkData:
	var chunk_grid: Vector2i
	var tier: int
	var cells_loaded: Array[Vector2i] = []
	var load_time_ms: float = 0.0


#region Configuration

## Configure the renderer with required dependencies
func configure(
	p_chunk_manager: RefCounted,
	p_distant_renderer: Node3D,
	p_impostor_manager: Node,
	p_tier_manager: RefCounted = null
) -> void:
	chunk_manager = p_chunk_manager
	distant_renderer = p_distant_renderer
	impostor_manager = p_impostor_manager
	tier_manager = p_tier_manager

	if chunk_manager and tier_manager:
		chunk_manager.call("configure", tier_manager)

	_debug("ChunkRenderer configured")


## Set camera for frustum culling
func set_camera(cam: Camera3D) -> void:
	camera = cam

#endregion


#region Main Update

## Main update function - call when camera cell changes
## Calculates visible chunks and loads/unloads as needed
func update_chunks(camera_cell: Vector2i) -> void:
	if not chunk_manager:
		push_warning("ChunkRenderer: No chunk manager configured")
		return

	var start_time := Time.get_ticks_usec()

	# Clear current frame tracking
	_current_mid_chunks.clear()
	_current_far_chunks.clear()

	# Get visible chunks for each tier
	var visible_by_tier: Dictionary = chunk_manager.call("get_visible_chunks_by_tier", camera_cell)

	# DEBUG: Log chunk manager distances (guarded to avoid string formatting overhead)
	if debug_enabled:
		var debug_info: Dictionary = chunk_manager.call("get_debug_info", camera_cell)
		if debug_info.get("visible_far_chunks", 0) > 0 or debug_info.get("visible_mid_chunks", 0) > 0:
			print("ChunkRenderer: update_chunks at %s - MID chunks: %d, FAR chunks: %d" % [
				camera_cell,
				debug_info.get("visible_mid_chunks", 0),
				debug_info.get("visible_far_chunks", 0)
			])
			print("  Tier distances: %s" % debug_info.get("tier_distances", {}))

	# Process MID tier chunks
	_update_tier_chunks(
		DistanceTierManagerScript.Tier.MID,
		visible_by_tier.get(DistanceTierManagerScript.Tier.MID, []) as Array,
		camera_cell
	)

	# Process FAR tier chunks
	_update_tier_chunks(
		DistanceTierManagerScript.Tier.FAR,
		visible_by_tier.get(DistanceTierManagerScript.Tier.FAR, []) as Array,
		camera_cell
	)

	# Remove stale chunks (loaded but not in current set)
	_remove_stale_chunks()

	# Update stats
	_stats["last_update_ms"] = (Time.get_ticks_usec() - start_time) / 1000.0
	_stats["mid_chunks_loaded"] = _loaded_mid_chunks.size()
	_stats["far_chunks_loaded"] = _loaded_far_chunks.size()

#endregion


#region Tier Processing

## Update chunks for a specific tier
func _update_tier_chunks(tier: int, visible_chunks: Array, camera_cell: Vector2i) -> void:
	# Guard debug logging to avoid string formatting overhead
	if debug_enabled and visible_chunks.size() > 0:
		var tier_name := "MID" if tier == DistanceTierManagerScript.Tier.MID else "FAR"
		print("ChunkRenderer: _update_tier_chunks %s - %d visible chunks around %s (frustum_culling=%s, camera=%s)" % [
			tier_name, visible_chunks.size(), camera_cell, use_frustum_culling, camera != null
		])

	var chunk_size: int = chunk_manager.call("get_chunk_size_for_tier", tier)
	var current_dict: Dictionary = _current_mid_chunks if tier == DistanceTierManagerScript.Tier.MID else _current_far_chunks
	var loaded_dict: Dictionary = _loaded_mid_chunks if tier == DistanceTierManagerScript.Tier.MID else _loaded_far_chunks

	var culled_count := 0
	var loaded_count := 0
	var already_loaded_count := 0

	for chunk_grid: Vector2i in visible_chunks:
		var identifier: String = chunk_manager.call("get_chunk_identifier", chunk_grid, tier)

		# Apply frustum culling if enabled
		# TESTING: Disable frustum culling for FAR tier - it's culling everything incorrectly
		if use_frustum_culling and camera and tier != DistanceTierManagerScript.Tier.FAR:
			if not chunk_manager.call("is_chunk_in_frustum", chunk_grid, chunk_size, camera):
				culled_count += 1
				continue

		# Mark as current (for stale detection)
		current_dict[identifier] = chunk_grid

		# Skip if already loaded
		if identifier in loaded_dict:
			already_loaded_count += 1
			continue

		loaded_count += 1

		# Load new chunk
		match tier:
			DistanceTierManagerScript.Tier.MID:
				_load_mid_chunk(chunk_grid as Vector2i, identifier)
			DistanceTierManagerScript.Tier.FAR:
				_load_far_chunk(chunk_grid as Vector2i, identifier)

	# Guard debug logging
	if debug_enabled and visible_chunks.size() > 0:
		var tier_name := "MID" if tier == DistanceTierManagerScript.Tier.MID else "FAR"
		print("ChunkRenderer: %s result - culled=%d, already_loaded=%d, new_loaded=%d" % [
			tier_name, culled_count, already_loaded_count, loaded_count
		])


## Remove chunks that are no longer visible
func _remove_stale_chunks() -> void:
	# Check MID chunks
	var stale_mid: Array[String] = []
	for identifier: String in _loaded_mid_chunks:
		if identifier not in _current_mid_chunks:
			stale_mid.append(identifier)

	for identifier: String in stale_mid:
		_unload_mid_chunk(identifier)

	# Check FAR chunks
	var stale_far: Array[String] = []
	for identifier: String in _loaded_far_chunks:
		if identifier not in _current_far_chunks:
			stale_far.append(identifier)

	for identifier: String in stale_far:
		_unload_far_chunk(identifier)

#endregion


#region MID Tier Loading

## Load a MID tier chunk (aggregates per-cell pre-baked meshes)
func _load_mid_chunk(chunk_grid: Vector2i, identifier: String) -> void:
	if not distant_renderer:
		return

	var start_time := Time.get_ticks_usec()
	var chunk_data := LoadedChunkData.new()
	chunk_data.chunk_grid = chunk_grid
	chunk_data.tier = DistanceTierManagerScript.Tier.MID

	# Get all cells in this chunk
	var cells: Array[Vector2i] = chunk_manager.call("get_cells_in_chunk", chunk_grid, QuadtreeChunkManagerScript.MID_CHUNK_SIZE)

	# Load pre-baked mesh for each cell
	for cell_grid in cells:
		var prebaked_path := _get_merged_cells_path().path_join("cell_%d_%d.res" % [cell_grid.x, cell_grid.y])

		if ResourceLoader.exists(prebaked_path):
			var mesh := load(prebaked_path) as ArrayMesh
			if mesh:
				if distant_renderer.has_method("add_cell_prebaked"):
					distant_renderer.call("add_cell_prebaked", cell_grid, mesh)
					chunk_data.cells_loaded.append(cell_grid)

	chunk_data.load_time_ms = (Time.get_ticks_usec() - start_time) / 1000.0
	_loaded_mid_chunks[identifier] = chunk_data

	# Update stats
	_stats["mid_cells_loaded"] += chunk_data.cells_loaded.size()

	_debug("Loaded MID chunk %s: %d cells in %.1fms" % [
		chunk_grid, chunk_data.cells_loaded.size(), chunk_data.load_time_ms
	])


## Unload a MID tier chunk
func _unload_mid_chunk(identifier: String) -> void:
	if identifier not in _loaded_mid_chunks:
		return

	var chunk_data: LoadedChunkData = _loaded_mid_chunks[identifier]

	# Remove each cell from distant renderer
	if distant_renderer:
		for cell_grid in chunk_data.cells_loaded:
			if distant_renderer.has_method("remove_cell"):
				distant_renderer.call("remove_cell", cell_grid)

	# Update stats
	_stats["mid_cells_loaded"] -= chunk_data.cells_loaded.size()

	_loaded_mid_chunks.erase(identifier)

	_debug("Unloaded MID chunk %s: %d cells" % [chunk_data.chunk_grid, chunk_data.cells_loaded.size()])

#endregion


#region FAR Tier Loading

## Load a FAR tier chunk (aggregates impostors per cell)
func _load_far_chunk(chunk_grid: Vector2i, identifier: String) -> void:
	if debug_enabled:
		print("ChunkRenderer: _load_far_chunk called for chunk %s" % chunk_grid)

	if not impostor_manager:
		if debug_enabled:
			print("ChunkRenderer: ERROR - impostor_manager is null!")
		return

	var start_time := Time.get_ticks_usec()
	var chunk_data := LoadedChunkData.new()
	chunk_data.chunk_grid = chunk_grid
	chunk_data.tier = DistanceTierManagerScript.Tier.FAR

	# Get all cells in this chunk
	var cells: Array[Vector2i] = chunk_manager.call("get_cells_in_chunk", chunk_grid, QuadtreeChunkManagerScript.FAR_CHUNK_SIZE)
	if debug_enabled:
		print("ChunkRenderer: FAR chunk %s contains %d cells" % [chunk_grid, cells.size()])

	# Load impostors for each cell
	for cell_grid in cells:
		var cell_record: Variant = ESMManager.get_exterior_cell(cell_grid.x, cell_grid.y)
		if cell_record:
			if impostor_manager.has_method("add_cell_impostors"):
				var count: int = impostor_manager.call("add_cell_impostors", cell_grid, cell_record.references)
				if count > 0:
					chunk_data.cells_loaded.append(cell_grid)

	chunk_data.load_time_ms = (Time.get_ticks_usec() - start_time) / 1000.0
	_loaded_far_chunks[identifier] = chunk_data

	# Update stats
	_stats["far_cells_loaded"] += chunk_data.cells_loaded.size()

	_debug("Loaded FAR chunk %s: %d cells with impostors in %.1fms" % [
		chunk_grid, chunk_data.cells_loaded.size(), chunk_data.load_time_ms
	])


## Unload a FAR tier chunk
func _unload_far_chunk(identifier: String) -> void:
	if identifier not in _loaded_far_chunks:
		return

	var chunk_data: LoadedChunkData = _loaded_far_chunks[identifier]

	# Remove impostors for each cell
	if impostor_manager:
		for cell_grid in chunk_data.cells_loaded:
			if impostor_manager.has_method("remove_impostors_for_cell"):
				impostor_manager.call("remove_impostors_for_cell", cell_grid)

	# Update stats
	_stats["far_cells_loaded"] -= chunk_data.cells_loaded.size()

	_loaded_far_chunks.erase(identifier)

	_debug("Unloaded FAR chunk %s: %d cells" % [chunk_data.chunk_grid, chunk_data.cells_loaded.size()])

#endregion


#region Public API

## Check if a chunk is loaded
func is_chunk_loaded(chunk_grid: Vector2i, tier: int) -> bool:
	var identifier: String = chunk_manager.call("get_chunk_identifier", chunk_grid, tier) if chunk_manager else ""
	match tier:
		DistanceTierManagerScript.Tier.MID:
			return identifier in _loaded_mid_chunks
		DistanceTierManagerScript.Tier.FAR:
			return identifier in _loaded_far_chunks
	return false


## Get list of loaded chunk grids for a tier
func get_loaded_chunks(tier: int) -> Array[Vector2i]:
	var chunks: Array[Vector2i] = []
	var loaded_dict: Dictionary

	match tier:
		DistanceTierManagerScript.Tier.MID:
			loaded_dict = _loaded_mid_chunks
		DistanceTierManagerScript.Tier.FAR:
			loaded_dict = _loaded_far_chunks
		_:
			return chunks

	for identifier: String in loaded_dict:
		var data: LoadedChunkData = loaded_dict[identifier]
		chunks.append(data.chunk_grid)

	return chunks


## Clear all loaded chunks
func clear() -> void:
	# Unload all MID chunks
	for identifier: String in _loaded_mid_chunks.keys():
		_unload_mid_chunk(identifier as String)

	# Unload all FAR chunks
	for identifier: String in _loaded_far_chunks.keys():
		_unload_far_chunk(identifier as String)

	_loaded_mid_chunks.clear()
	_loaded_far_chunks.clear()
	_current_mid_chunks.clear()
	_current_far_chunks.clear()

	_stats["mid_chunks_loaded"] = 0
	_stats["far_chunks_loaded"] = 0
	_stats["mid_cells_loaded"] = 0
	_stats["far_cells_loaded"] = 0


## Get statistics
func get_stats() -> Dictionary:
	return _stats.duplicate()


## Force reload all chunks (e.g., after teleport)
func refresh(camera_cell: Vector2i) -> void:
	clear()
	update_chunks(camera_cell)

#endregion


#region Debug

func _debug(msg: String) -> void:
	if debug_enabled:
		print("ChunkRenderer: %s" % msg)


## Get debug info about chunk state
func get_debug_info() -> Dictionary:
	return {
		"mid_chunks_loaded": _loaded_mid_chunks.size(),
		"far_chunks_loaded": _loaded_far_chunks.size(),
		"mid_cells_loaded": _stats["mid_cells_loaded"],
		"far_cells_loaded": _stats["far_cells_loaded"],
		"last_update_ms": _stats["last_update_ms"],
		"frustum_culling": use_frustum_culling,
		"has_camera": camera != null,
	}

#endregion
