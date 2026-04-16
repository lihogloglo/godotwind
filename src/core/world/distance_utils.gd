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

## HLOD tier: Cell-level merged meshes (HLOD_START to HLOD_END)
## Bridges individual MID instances and impostor billboards
const HLOD_START: float = 300.0
const HLOD_END: float = 1000.0

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

## Object-paging projected-size threshold.
## A ref is paged when `mesh_radius² × scale² >= dist² × PAGING_MIN_SIZE²`.
## Smaller meshes at distance project below a screen-space threshold and
## don't contribute visually — they're skipped.
##
## OpenMW uses 0.14 in Morrowind (MW) units. Godotwind works in meters
## (1 MW unit = 1/70 m), so 0.14 in MW-unit space is effectively the same
## angular-size formula but with meter-scale distances. In practice, 0.14
## requires mesh_radius ≥ 28m at 200m distance — which rejects all Morrowind
## buildings and vegetation. Lowered to 0.02 so objects with radius ≥ ~4m
## (typical Morrowind tree/building) pass at 200m. Tune upward to reduce
## paging draw calls if performance requires it.
## Source: inspos/openmw/components/settings/categories/terrain.hpp:34
const PAGING_MIN_SIZE: float = 0.02
const PAGING_MIN_SIZE_SQ: float = PAGING_MIN_SIZE * PAGING_MIN_SIZE

## Cost-benefit merge decision multiplier (OpenMW `mObjectPagingMergeFactor`).
## A mesh-type is merged when `mergeBenefit × PAGING_MERGE_FACTOR > mergeCost`,
## where mergeBenefit = ref_count × shared_material_count and
## mergeCost = total_verts × (size_level + 1). 256.0 is OpenMW's canonical
## default for Morrowind content (inspos/openmw/components/settings/
## categories/terrain.hpp:32). Raise → merge more aggressively; lower →
## leave more types as individual RS instances.
const PAGING_MERGE_FACTOR: float = 256.0

## Phase 4 — adaptive chunk tier band ends (strict half-open intervals).
## Plan §4.2. Band classification uses chunk-CENTER distance from camera.
##   size_level 0 (1×1 chunks) = [150, 300)
##   size_level 1 (2×2 chunks) = [300, 600)
##   size_level 2 (4×4 chunks) = [600, 1000)
## FAR tier (impostors) picks up at PAGING_TIER_2_END.
const PAGING_TIER_0_START: float = 150.0
const PAGING_TIER_0_END: float = 300.0
const PAGING_TIER_1_END: float = 600.0
const PAGING_TIER_2_END: float = 1000.0

## Phase 4 — hysteresis margin for chunk tier transitions (plan §4.4).
## Active chunks retain their current tier until the camera moves this far
## past the demote threshold. Matches the 20m margin used by cell_manager's
## NEAR↔MID promotion at 250m/270m.
const PAGING_HYSTERESIS: float = 20.0

## Phase 5 — second-pass `minSizeMergeFactor` (OpenMW canonical defaults).
## After the cost-benefit decision accepts a mesh type, its refs face a
## second size filter whose threshold scales with how merge-beneficial the
## type turned out to be. Formula (matches `objectpaging.cpp:833-836`):
##     factor2               = clamp(mergeCost × cost_multiplier / mergeBenefit, 0, 1)  [or 1 if benefit == 0]
##     minSizeMergeFactor2   = (1 − factor2) × MIN_SIZE_MERGE_FACTOR + factor2
##     minSizeMerged         = MIN_SIZE × minSizeMergeFactor2
## Source: `inspos/openmw/components/settings/categories/terrain.hpp:35-39`.
const PAGING_MIN_SIZE_MERGE_FACTOR: float = 0.5
const PAGING_MIN_SIZE_COST_MULTIPLIER: float = 1.0

#endregion

#region Phase 4 — ChunkKey helpers (plan §4.1-4.2)

## Convert a 1×1 cell coordinate to the aligned center_cell of the chunk
## at the given size_level. Plan §4.1.
##
## Chunk width in cells: `size = 1 << size_level` (1, 2, 4 for levels 0/1/2).
## Alignment: bitwise AND with `~(size - 1)` — gives correct floor-toward-
## negative-infinity behaviour in GDScript's two's-complement ints.
## Naive `(cell.x / size) * size` truncates toward zero and mis-aligns
## negative cells (e.g. cell.x=-5 with size=4 would give -4 instead of -8).
##
## Boundaries verified:
##   cell=0,  size=4 → 0
##   cell=3,  size=4 → 0
##   cell=4,  size=4 → 4
##   cell=-1, size=4 → -4
##   cell=-5, size=4 → -8
##   cell=-8, size=4 → -8
static func chunk_key_for_cell(cell: Vector2i, size_level: int) -> Vector2i:
	var size: int = 1 << size_level
	var mask: int = ~(size - 1)
	return Vector2i(cell.x & mask, cell.y & mask)


## World-space (XZ-plane) center of a chunk. Plan §4.2.
## `center_cell` must be aligned — pass the output of `chunk_key_for_cell`.
## Returns Vector2(x, z) in Godot world coordinates — the Z axis is flipped
## from ESM-space to match `cell_to_world_center`/`cell_to_world_origin`
## conventions (Morrowind Y → Godot -Z).
##
## Used by band classification: build `camera_xz = Vector2(cam.x, cam.z)`
## and compare `camera_xz.distance_to(chunk_center_world(...))`.
static func chunk_center_world(center_cell: Vector2i, size_level: int) -> Vector2:
	var size: int = 1 << size_level
	var half_extent: float = float(size) * CELL_SIZE_METERS * 0.5
	return Vector2(
		float(center_cell.x) * CELL_SIZE_METERS + half_extent,
		-float(center_cell.y) * CELL_SIZE_METERS - half_extent
	)


## Band-end distance for a given chunk size_level. Plan §4.2.
## Returns the outer (exclusive) distance at which a chunk of this size_level
## stops being active. The complementary band START is the previous tier's
## END (or `PAGING_TIER_0_START` for size_level 0).
static func paging_band_end(size_level: int) -> float:
	match size_level:
		0: return PAGING_TIER_0_END
		1: return PAGING_TIER_1_END
		2: return PAGING_TIER_2_END
		_: return 0.0


## Band-start distance for a given chunk size_level (plan §4.2).
static func paging_band_start(size_level: int) -> float:
	match size_level:
		0: return PAGING_TIER_0_START
		1: return PAGING_TIER_0_END
		2: return PAGING_TIER_1_END
		_: return 0.0


## Ring radius (in chunks) for the given size_level, per plan §4.5.
## `ceil(band_end / (size × cell_size))`. Worst case at size_level=2:
## ceil(1000 / (4 × 117)) = 3.
static func paging_ring_radius(size_level: int) -> int:
	var size: int = 1 << size_level
	var chunk_extent: float = float(size) * CELL_SIZE_METERS
	return int(ceil(paging_band_end(size_level) / chunk_extent))

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
