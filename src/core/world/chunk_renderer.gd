## ChunkRenderer - Coordinates chunk-level rendering for FAR tier
##
## Manages loading and unloading of chunks (groups of cells) for distant rendering.
## Works with ImpostorManager for FAR tier (impostors 500m-5km).
##
## Key features:
## - Loads all per-cell impostors within a chunk as a batch
## - Tracks loaded/unloaded chunks (not individual cells)
## - Computes chunk diffs on camera move (stale vs current pattern)
##
## Architecture follows DigitallyTailored/godot4-quadtree patterns:
## - chunks_list / chunks_list_current dictionary diffing
## - Deferred cleanup via queue_free equivalent
##
## Usage:
##   var renderer := ChunkRenderer.new()
##   renderer.configure(chunk_manager, impostor_manager)
##   renderer.update_chunks(camera_cell)
class_name ChunkRenderer
extends Node3D

const QuadtreeChunkManagerScript := preload("res://src/core/world/quadtree_chunk_manager.gd")
const DistanceTierManagerScript := preload("res://src/core/world/distance_tier_manager.gd")


## Reference to QuadtreeChunkManager for chunk calculations
var chunk_manager: RefCounted = null

## Reference to ImpostorManager for FAR tier impostors
var impostor_manager: Node = null

## Reference to tier manager for distance info
var tier_manager: RefCounted = null

## Camera reference for frustum culling
var camera: Camera3D = null

## Enable frustum culling for chunks
## NOTE: Disabled by default - the camera reference is often not set correctly,
## and the AABB-based culling can be overly aggressive. Enable only after testing.
var use_frustum_culling: bool = false

## Enable debug output
var debug_enabled: bool = false

## Loaded FAR tier chunks: chunk_key (int) -> LoadedChunkData
var _loaded_far_chunks: Dictionary = {}

## Current frame's visible chunks (for diffing): chunk_key (int) -> chunk_grid
var _current_far_chunks: Dictionary = {}

## Stats
var _stats := {
	"far_chunks_loaded": 0,
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
	p_impostor_manager: Node,
	p_tier_manager: RefCounted = null
) -> void:
	chunk_manager = p_chunk_manager
	impostor_manager = p_impostor_manager
	tier_manager = p_tier_manager

	if chunk_manager and tier_manager:
		chunk_manager.call("configure", tier_manager)

	_debug("ChunkRenderer configured for FAR tier impostors")


## Set camera for frustum culling
func set_camera(cam: Camera3D) -> void:
	camera = cam

#endregion


#region Main Update

## Main update function - call when camera cell changes
## Calculates visible FAR chunks and loads/unloads as needed
func update_chunks(camera_cell: Vector2i) -> void:
	if not chunk_manager:
		push_warning("ChunkRenderer: No chunk manager configured")
		return

	var start_time := Time.get_ticks_usec()

	# Clear current frame tracking
	_current_far_chunks.clear()

	# Get visible chunks for FAR tier only
	var visible_by_tier: Dictionary = chunk_manager.call("get_visible_chunks_by_tier", camera_cell)

	# DEBUG: Log chunk manager distances (guarded to avoid string formatting overhead)
	if debug_enabled:
		var debug_info: Dictionary = chunk_manager.call("get_debug_info", camera_cell)
		if debug_info.get("visible_far_chunks", 0) > 0:
			print("ChunkRenderer: update_chunks at %s - FAR chunks: %d" % [
				camera_cell,
				debug_info.get("visible_far_chunks", 0)
			])
			print("  Tier distances: %s" % debug_info.get("tier_distances", {}))

	# Process FAR tier chunks
	@warning_ignore("unsafe_cast")
	var far_chunks_to_process: Array = visible_by_tier.get(DistanceTierManagerScript.Tier.FAR, []) as Array
	_update_tier_chunks(
		DistanceTierManagerScript.Tier.FAR,
		far_chunks_to_process,
		camera_cell
	)

	# Remove stale chunks (loaded but not in current set)
	_remove_stale_chunks()

	# Update stats
	_stats["last_update_ms"] = (Time.get_ticks_usec() - start_time) / 1000.0
	_stats["far_chunks_loaded"] = _loaded_far_chunks.size()

#endregion


#region Tier Processing

## Update chunks for FAR tier
func _update_tier_chunks(tier: int, visible_chunks: Array, camera_cell: Vector2i) -> void:
	if tier != DistanceTierManagerScript.Tier.FAR:
		return

	# Guard debug logging to avoid string formatting overhead
	if debug_enabled and visible_chunks.size() > 0:
		print("ChunkRenderer: _update_tier_chunks FAR - %d visible chunks around %s (frustum_culling=%s, camera=%s)" % [
			visible_chunks.size(), camera_cell, use_frustum_culling, camera != null
		])

	var chunk_size: int = chunk_manager.call("get_chunk_size_for_tier", tier)

	var culled_count := 0
	var loaded_count := 0
	var already_loaded_count := 0

	for chunk_grid: Vector2i in visible_chunks:
		# Use integer key for faster dictionary operations
		var chunk_key: int = chunk_manager.call("get_chunk_key", chunk_grid, tier)

		# Frustum culling - skip chunks outside camera view
		# AABB uses conservative height bounds (-500 to +1000m) to avoid over-culling
		if use_frustum_culling and camera:
			if not chunk_manager.call("is_chunk_in_frustum", chunk_grid, chunk_size, camera):
				culled_count += 1
				continue

		# Mark as current (for stale detection)
		_current_far_chunks[chunk_key] = chunk_grid

		# Skip if already loaded
		if chunk_key in _loaded_far_chunks:
			already_loaded_count += 1
			continue

		loaded_count += 1

		# Load new FAR chunk
		_load_far_chunk(chunk_grid as Vector2i, chunk_key)

	# Guard debug logging
	if debug_enabled and visible_chunks.size() > 0:
		print("ChunkRenderer: FAR result - culled=%d, already_loaded=%d, new_loaded=%d" % [
			culled_count, already_loaded_count, loaded_count
		])


## Remove chunks that are no longer visible
func _remove_stale_chunks() -> void:
	var stale_far: Array[int] = []
	for chunk_key: int in _loaded_far_chunks:
		if chunk_key not in _current_far_chunks:
			stale_far.append(chunk_key)

	for chunk_key: int in stale_far:
		_unload_far_chunk(chunk_key)

#endregion


#region FAR Tier Loading

## Load a FAR tier chunk (aggregates impostors per cell)
func _load_far_chunk(chunk_grid: Vector2i, chunk_key: int) -> void:
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
	_loaded_far_chunks[chunk_key] = chunk_data

	# Update stats
	_stats["far_cells_loaded"] += chunk_data.cells_loaded.size()

	_debug("Loaded FAR chunk %s: %d cells with impostors in %.1fms" % [
		chunk_grid, chunk_data.cells_loaded.size(), chunk_data.load_time_ms
	])


## Unload a FAR tier chunk
func _unload_far_chunk(chunk_key: int) -> void:
	if chunk_key not in _loaded_far_chunks:
		return

	var chunk_data: LoadedChunkData = _loaded_far_chunks[chunk_key]

	# Remove impostors for each cell
	if impostor_manager:
		for cell_grid in chunk_data.cells_loaded:
			if impostor_manager.has_method("remove_impostors_for_cell"):
				impostor_manager.call("remove_impostors_for_cell", cell_grid)

	# Update stats
	_stats["far_cells_loaded"] -= chunk_data.cells_loaded.size()

	_loaded_far_chunks.erase(chunk_key)

	_debug("Unloaded FAR chunk %s: %d cells" % [chunk_data.chunk_grid, chunk_data.cells_loaded.size()])

#endregion


#region Public API


## Clear all loaded chunks
func clear() -> void:
	var far_keys: Array = _loaded_far_chunks.keys()
	for chunk_key: int in far_keys:
		_unload_far_chunk(chunk_key)

	_loaded_far_chunks.clear()
	_current_far_chunks.clear()

	_stats["far_chunks_loaded"] = 0
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
		"far_chunks_loaded": _loaded_far_chunks.size(),
		"far_cells_loaded": _stats["far_cells_loaded"],
		"last_update_ms": _stats["last_update_ms"],
		"frustum_culling": use_frustum_culling,
		"has_camera": camera != null,
	}

#endregion
