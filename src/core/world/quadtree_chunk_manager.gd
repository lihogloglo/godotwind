## QuadtreeChunkManager - Hierarchical chunk management for distant rendering
##
## Organizes cells into hierarchical chunks for efficient MID/FAR tier management:
## - MID tier: 4x4 cell chunks (~468m each)
## - FAR tier: 8x8 cell chunks (~936m each)
## - NEAR tier: Uses per-cell (not managed here)
##
## This dramatically reduces the number of visibility calculations and dictionary
## lookups compared to per-cell tracking (~35x improvement).
##
## Reference patterns from DigitallyTailored/godot4-quadtree (MIT license).
##
## Usage:
##   var chunk_manager := QuadtreeChunkManager.new()
##   chunk_manager.configure(tier_manager)
##   var visible_chunks := chunk_manager.get_visible_chunks(camera_cell, Tier.MID)
class_name QuadtreeChunkManager
extends RefCounted

const DistanceTierManagerScript := preload("res://src/core/world/distance_tier_manager.gd")
const DU := preload("res://src/core/world/distance_utils.gd")

## Chunk size in cells for MID tier (4x4 = 16 cells per chunk)
const MID_CHUNK_SIZE := 4

## Chunk size in cells for FAR tier (8x8 = 64 cells per chunk)
const FAR_CHUNK_SIZE := 8

## Cell size in meters (from DistanceUtils - single source of truth)
const CELL_SIZE_METERS := DU.CELL_SIZE_METERS

## MID chunk size in meters (4 * 117 = 468m)
const MID_CHUNK_SIZE_METERS := MID_CHUNK_SIZE * CELL_SIZE_METERS

## FAR chunk size in meters (8 * 117 = 936m)
const FAR_CHUNK_SIZE_METERS := FAR_CHUNK_SIZE * CELL_SIZE_METERS

## Maximum chunks to track per tier (prevents runaway)
const MAX_MID_CHUNKS := 50
const MAX_FAR_CHUNKS := 60

## Reference to tier manager for distance thresholds
var tier_manager: RefCounted = null

## Tier distance cache (updated on configure)
var _tier_distances: Dictionary = {}
var _tier_end_distances: Dictionary = {}


#region Configuration

## Configure the chunk manager with tier distance information
## tier_manager is REQUIRED - distances come from DistanceTierManager (single source of truth)
func configure(p_tier_manager: RefCounted) -> void:
	tier_manager = p_tier_manager
	if tier_manager:
		var tier_distances_dict: Dictionary = tier_manager.get("tier_distances")
		var tier_end_distances_dict: Dictionary = tier_manager.get("tier_end_distances")
		_tier_distances = tier_distances_dict.duplicate()
		_tier_end_distances = tier_end_distances_dict.duplicate()
		print("[QuadtreeChunkManager] Configured with tier_distances: %s, tier_end_distances: %s" % [_tier_distances, _tier_end_distances])
	else:
		push_warning("QuadtreeChunkManager: tier_manager is required - using empty distances")
		_tier_distances = {}
		_tier_end_distances = {}

#endregion


#region Chunk Grid Calculations

## Convert a cell grid coordinate to its containing chunk grid coordinate
## cell: The cell position (e.g., Vector2i(5, 7))
## chunk_size: The chunk size in cells (e.g., 4 for MID tier)
## Returns: The chunk grid coordinate (e.g., Vector2i(1, 1) for 4x4 chunks)
func cell_to_chunk_grid(cell: Vector2i, chunk_size: int) -> Vector2i:
	# Use floor division to handle negative coordinates correctly
	var chunk_x := floori(float(cell.x) / chunk_size)
	var chunk_y := floori(float(cell.y) / chunk_size)
	return Vector2i(chunk_x, chunk_y)


## Get all cell grid coordinates within a chunk
## chunk_grid: The chunk position (e.g., Vector2i(1, 1))
## chunk_size: The chunk size in cells (e.g., 4 for MID tier)
## Returns: Array of cell positions within the chunk
func get_cells_in_chunk(chunk_grid: Vector2i, chunk_size: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var origin_x := chunk_grid.x * chunk_size
	var origin_y := chunk_grid.y * chunk_size

	for dy in range(chunk_size):
		for dx in range(chunk_size):
			cells.append(Vector2i(origin_x + dx, origin_y + dy))

	return cells


## Get the center cell of a chunk (used for distance calculations)
func get_chunk_center_cell(chunk_grid: Vector2i, chunk_size: int) -> Vector2i:
	var origin_x := chunk_grid.x * chunk_size
	var origin_y := chunk_grid.y * chunk_size
	return Vector2i(origin_x + chunk_size / 2, origin_y + chunk_size / 2)


## Get chunk size for a given tier
func get_chunk_size_for_tier(tier: int) -> int:
	match tier:
		DistanceTierManagerScript.Tier.MID:
			return MID_CHUNK_SIZE
		DistanceTierManagerScript.Tier.FAR:
			return FAR_CHUNK_SIZE
		_:
			return 1  # NEAR tier uses per-cell


## Generate a unique identifier string for a chunk
## Used as dictionary key for tracking loaded chunks
## Note: For performance, prefer get_chunk_key() which returns an int
func get_chunk_identifier(chunk_grid: Vector2i, tier: int) -> String:
	var tier_prefix := "M" if tier == DistanceTierManagerScript.Tier.MID else "F"
	return "%s_%d_%d" % [tier_prefix, chunk_grid.x, chunk_grid.y]


## Generate a unique integer key for a chunk (faster than string identifier)
## Packs tier (2 bits) + x (15 bits, signed) + y (15 bits, signed) into int
## Supports chunk coordinates from -16384 to +16383
func get_chunk_key(chunk_grid: Vector2i, tier: int) -> int:
	# Offset coordinates to make them positive (add 16384)
	var offset_x := (chunk_grid.x + 16384) & 0x7FFF  # 15 bits
	var offset_y := (chunk_grid.y + 16384) & 0x7FFF  # 15 bits
	var tier_bits := tier & 0x3  # 2 bits
	return (tier_bits << 30) | (offset_x << 15) | offset_y


## Decode a chunk key back to grid and tier (for debugging)
func decode_chunk_key(key: int) -> Dictionary:
	var tier := (key >> 30) & 0x3
	var offset_x := (key >> 15) & 0x7FFF
	var offset_y := key & 0x7FFF
	return {
		"tier": tier,
		"grid": Vector2i(offset_x - 16384, offset_y - 16384)
	}

#endregion


#region Chunk Visibility

## Get all visible chunks for a specific tier
## camera_cell: The cell the camera is currently in
## tier: The tier to get chunks for (MID or FAR)
## Returns: Array of chunk grid coordinates that should be loaded
var _get_visible_call_count: int = 0
func get_visible_chunks(camera_cell: Vector2i, tier: int) -> Array[Vector2i]:
	_get_visible_call_count += 1
	if _get_visible_call_count <= 4:
		print("[QuadtreeChunkManager] get_visible_chunks CALLED #%d - tier=%d, camera=%s" % [_get_visible_call_count, tier, camera_cell])

	var visible_chunks: Array[Vector2i] = []

	# Only MID and FAR tiers use chunks
	if tier != DistanceTierManagerScript.Tier.MID and tier != DistanceTierManagerScript.Tier.FAR:
		if _get_visible_call_count <= 4:
			print("[QuadtreeChunkManager]   SKIP - tier %d not MID(1) or FAR(2)" % tier)
		return visible_chunks

	var chunk_size := get_chunk_size_for_tier(tier)
	var min_dist: float = _tier_distances.get(tier, 0.0)
	var max_dist: float = _tier_end_distances.get(tier, 0.0)

	if _get_visible_call_count <= 4:
		print("[QuadtreeChunkManager]   Processing tier=%d, min_dist=%.1f, max_dist=%.1f, chunk_size=%d" % [tier, min_dist, max_dist, chunk_size])

	# Calculate chunk radius from distance
	# Add 1 to ensure we cover edge cases
	var max_cell_radius := ceili(max_dist / CELL_SIZE_METERS)
	var max_chunk_radius := ceili(float(max_cell_radius) / chunk_size) + 1

	# Get camera's chunk
	var camera_chunk := cell_to_chunk_grid(camera_cell, chunk_size)

	# Collect chunks with distances for sorting
	var chunks_with_distance: Array[Dictionary] = []

	# Iterate over chunk grid (much smaller than cell grid!)
	for dy in range(-max_chunk_radius, max_chunk_radius + 1):
		for dx in range(-max_chunk_radius, max_chunk_radius + 1):
			var chunk := Vector2i(camera_chunk.x + dx, camera_chunk.y + dy)

			# Check if chunk intersects the tier's distance range
			if _chunk_intersects_tier_range(chunk, camera_cell, chunk_size, min_dist, max_dist):
				var distance := _chunk_distance_to_cell(chunk, camera_cell, chunk_size)
				chunks_with_distance.append({
					"chunk": chunk,
					"distance": distance
				})

	# Sort by distance (closest first)
	chunks_with_distance.sort_custom(func(a: Variant, b: Variant) -> bool: return a.distance < b.distance)

	# Apply hard limit
	var max_chunks := MAX_MID_CHUNKS if tier == DistanceTierManagerScript.Tier.MID else MAX_FAR_CHUNKS
	var count := 0

	for entry in chunks_with_distance:
		if count >= max_chunks:
			break
		visible_chunks.append(entry.chunk)
		count += 1

	return visible_chunks


## Check if a chunk intersects a tier's distance range
func _chunk_intersects_tier_range(chunk: Vector2i, camera_cell: Vector2i,
								   chunk_size: int, min_dist: float, max_dist: float) -> bool:
	# Get chunk center for distance calculation
	var chunk_center := get_chunk_center_cell(chunk, chunk_size)

	# Calculate distance to chunk center using centralized utility
	var distance := DU.cell_distance(chunk_center, camera_cell)

	# Add margin for chunk's diagonal extent
	# sqrt(2)/2 * chunk_size * cell_size = half-diagonal
	var chunk_half_diagonal := chunk_size * CELL_SIZE_METERS * 0.707

	# Chunk intersects tier if any part of it falls within [min_dist, max_dist]
	return distance - chunk_half_diagonal < max_dist and \
		   distance + chunk_half_diagonal > min_dist


## Calculate distance from chunk center to a cell (in meters)
func _chunk_distance_to_cell(chunk: Vector2i, cell: Vector2i, chunk_size: int) -> float:
	var chunk_center := get_chunk_center_cell(chunk, chunk_size)
	return DU.cell_distance(chunk_center, cell)


## Get visible chunks for both MID and FAR tiers at once
## Returns: Dictionary mapping tier -> Array[Vector2i] of chunk grids
func get_visible_chunks_by_tier(camera_cell: Vector2i) -> Dictionary:
	return {
		DistanceTierManagerScript.Tier.MID: get_visible_chunks(camera_cell, DistanceTierManagerScript.Tier.MID),
		DistanceTierManagerScript.Tier.FAR: get_visible_chunks(camera_cell, DistanceTierManagerScript.Tier.FAR),
	}

#endregion


#region Chunk AABB

## Get the world-space AABB for a chunk
## Used for frustum culling and spatial queries
func get_chunk_aabb(chunk_grid: Vector2i, chunk_size: int) -> AABB:
	var origin_x := chunk_grid.x * chunk_size * CELL_SIZE_METERS
	var origin_z := -chunk_grid.y * chunk_size * CELL_SIZE_METERS  # Z is flipped in Godot
	var size := chunk_size * CELL_SIZE_METERS

	# Create AABB with conservative height bounds to avoid over-culling
	# -500m to +1000m covers underwater, terrain, buildings, and mountains
	# Using generous bounds is better than culling valid chunks
	return AABB(
		Vector3(origin_x, -500.0, origin_z - size),  # Position (generous min Y)
		Vector3(size, 1500.0, size)  # Size (1500m total height for any structure)
	)


## Check if a chunk's AABB is visible in the camera frustum
func is_chunk_in_frustum(chunk_grid: Vector2i, chunk_size: int, camera: Camera3D) -> bool:
	if not camera:
		return true  # No camera = assume visible

	var aabb := get_chunk_aabb(chunk_grid, chunk_size)
	var frustum := camera.get_frustum()

	# Check against each frustum plane
	for plane in frustum:
		# Find the corner most in the direction of the plane normal
		var corner := aabb.position
		if plane.normal.x >= 0:
			corner.x += aabb.size.x
		if plane.normal.y >= 0:
			corner.y += aabb.size.y
		if plane.normal.z >= 0:
			corner.z += aabb.size.z

		# If this corner is behind the plane, the AABB is outside the frustum
		if plane.distance_to(corner) < 0:
			return false

	return true

#endregion


#region Debug

## Get debug information about chunk calculations
func get_debug_info(camera_cell: Vector2i) -> Dictionary:
	var mid_chunks := get_visible_chunks(camera_cell, DistanceTierManagerScript.Tier.MID)
	var far_chunks := get_visible_chunks(camera_cell, DistanceTierManagerScript.Tier.FAR)

	return {
		"camera_cell": camera_cell,
		"mid_chunk_size": MID_CHUNK_SIZE,
		"far_chunk_size": FAR_CHUNK_SIZE,
		"visible_mid_chunks": mid_chunks.size(),
		"visible_far_chunks": far_chunks.size(),
		"mid_cells_covered": mid_chunks.size() * MID_CHUNK_SIZE * MID_CHUNK_SIZE,
		"far_cells_covered": far_chunks.size() * FAR_CHUNK_SIZE * FAR_CHUNK_SIZE,
		"tier_distances": _tier_distances.duplicate(),
	}

#endregion
