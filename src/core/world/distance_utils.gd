## DistanceUtils - Unified distance calculation utilities
##
## Single source of truth for cell/chunk distance calculations across
## the distant rendering pipeline. Eliminates duplicated distance math
## in DistanceTierManager, QuadtreeChunkManager, and ImpostorManager.
##
## Usage:
##   var dist := DistanceUtils.cell_distance(cell_a, cell_b)
##   var dist_sq := DistanceUtils.cell_distance_squared(cell_a, cell_b)
class_name DistanceUtils
extends RefCounted

const CS := preload("res://src/core/coordinate_system.gd")

## Morrowind cell size in meters (standard across all ESM data)
const CELL_SIZE_METERS: float = CS.CELL_SIZE_GODOT

## Half cell size (used for center calculations)
const HALF_CELL_SIZE: float = CELL_SIZE_METERS * 0.5

#region Tier Distance Constants (Single Source of Truth)

## NEAR tier: Full 3D meshes with physics/collision (0 to NEAR_END)
const NEAR_END: float = 150.0

## MID tier: Per-object LOD meshes (NEAR_END to MID_END)
const MID_END: float = 500.0

## FAR tier: Impostors/billboards (MID_END to FAR_END)
const FAR_END: float = 5000.0

## LEGACY: sub-LOD boundaries from the pre-B-wide 3-band MID scheme.
## Post-refactor the engine picks LOD levels from screen-space coverage +
## `mesh_lod_threshold`, so these no longer gate anything. Kept here ONLY so
## the few remaining consumers (debug_overlay distance classifier, HUD labels)
## compile during the transition. Delete after Phase F debug-overlay rewrite.
const LOD1_END: float = 250.0
const LOD2_END: float = 375.0
const LOD3_END: float = 500.0

## Tier start distances (for convenience)
const NEAR_START: float = 0.0
const MID_START: float = NEAR_END
const FAR_START: float = MID_END

## Crossfade zone size (meters) - both tiers visible during transition
## Tiered: smaller at close range (geometry mismatch visible), larger at distance
const FADE_MARGIN: float = 10.0  ## Default / legacy (used by FAR tier impostor renderer)

## Post-B-wide canonical fade margin: single render→impostor tier handoff at 500m.
const FADE_MARGIN_RENDER_FAR: float = 20.0

## LEGACY per-boundary fade margins from the pre-B-wide 3-band MID scheme.
## Kept as aliases so the impostor renderer + collision-enable hysteresis still
## have a margin to reference. Collapse these at the same time as LOD{1,2,3}_END.
const FADE_MARGIN_NEAR_LOD1: float = 5.0
const FADE_MARGIN_LOD1_LOD2: float = 10.0
const FADE_MARGIN_LOD2_LOD3: float = 15.0
const FADE_MARGIN_LOD3_FAR: float = FADE_MARGIN_RENDER_FAR

#endregion


## Calculate squared distance between two cells (in meters)
## Use this when comparing distances to avoid sqrt overhead
static func cell_distance_squared(cell_a: Vector2i, cell_b: Vector2i) -> float:
	var dx: float = (cell_b.x - cell_a.x) * CELL_SIZE_METERS
	var dy: float = (cell_b.y - cell_a.y) * CELL_SIZE_METERS
	return dx * dx + dy * dy


## Calculate distance between two cells (in meters)
static func cell_distance(cell_a: Vector2i, cell_b: Vector2i) -> float:
	return sqrt(cell_distance_squared(cell_a, cell_b))


## Calculate distance from a world position to a cell center (in meters)
static func position_to_cell_distance(pos: Vector3, cell: Vector2i) -> float:
	var cell_center := cell_to_world_center(cell, pos.y)
	return pos.distance_to(cell_center)


## Calculate squared distance from world position to cell center
static func position_to_cell_distance_squared(pos: Vector3, cell: Vector2i) -> float:
	var cell_center := cell_to_world_center(cell, pos.y)
	return pos.distance_squared_to(cell_center)


## Convert cell grid coordinates to world-space center position
## Uses Godot coordinate system (Z is flipped from ESM)
static func cell_to_world_center(cell: Vector2i, y: float = 0.0) -> Vector3:
	return Vector3(
		cell.x * CELL_SIZE_METERS + HALF_CELL_SIZE,
		y,
		-cell.y * CELL_SIZE_METERS - HALF_CELL_SIZE  # Z flipped in Godot
	)


## Convert cell grid coordinates to world-space origin (corner, not center)
static func cell_to_world_origin(cell: Vector2i, y: float = 0.0) -> Vector3:
	return Vector3(
		cell.x * CELL_SIZE_METERS,
		y,
		-cell.y * CELL_SIZE_METERS  # Z flipped in Godot
	)


## Convert world position to cell grid coordinates
static func world_to_cell(pos: Vector3) -> Vector2i:
	return Vector2i(
		floori(pos.x / CELL_SIZE_METERS),
		floori(-pos.z / CELL_SIZE_METERS)  # Z flipped in Godot
	)


## Calculate cell radius needed to cover a given distance
static func distance_to_cell_radius(distance_meters: float) -> int:
	return ceili(distance_meters / CELL_SIZE_METERS)


## Calculate distance covered by a cell radius
static func cell_radius_to_distance(cell_radius: int) -> float:
	return float(cell_radius) * CELL_SIZE_METERS


## Check if a cell is within a distance range from camera cell
static func is_cell_in_range(cell: Vector2i, camera_cell: Vector2i,
							  min_dist: float, max_dist: float) -> bool:
	var dist_sq := cell_distance_squared(cell, camera_cell)
	return dist_sq >= min_dist * min_dist and dist_sq <= max_dist * max_dist


## Get cells in a ring pattern (between min and max distance)
## Returns array of Vector2i sorted by distance
static func get_cells_in_ring(center: Vector2i, min_dist: float, max_dist: float,
							   max_cells: int = 100) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var max_radius := distance_to_cell_radius(max_dist)
	var min_dist_sq := min_dist * min_dist
	var max_dist_sq := max_dist * max_dist

	# Collect cells with distances for sorting
	var cells_with_dist: Array[Dictionary] = []

	for dy in range(-max_radius, max_radius + 1):
		for dx in range(-max_radius, max_radius + 1):
			var cell := Vector2i(center.x + dx, center.y + dy)
			var dist_sq := cell_distance_squared(cell, center)

			if dist_sq >= min_dist_sq and dist_sq <= max_dist_sq:
				cells_with_dist.append({"cell": cell, "dist": dist_sq})

	# Sort by distance
	cells_with_dist.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["dist"] < b["dist"]
	)

	# Extract cells up to limit
	for i in range(mini(cells_with_dist.size(), max_cells)):
		cells.append(cells_with_dist[i]["cell"])

	return cells
