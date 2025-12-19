## DistanceTierManager - Manages multi-tier distance rendering
##
## Determines which rendering tier a cell belongs to based on distance:
## - NEAR: Full 3D meshes with existing LOD system (0-500m)
## - MID: Simplified merged meshes (500m-2km)
## - FAR: Octahedral impostors (2km-5km)
## - HORIZON: Skybox integration (5km+)
##
## Provides loading strategy for each tier and coordinates between
## CellManager (NEAR) and distant renderers (MID/FAR).
##
## Key features:
## - Hysteresis to prevent tier flickering at boundaries
## - Per-world configurable distances
## - Priority-based loading (NEAR > MID > FAR)
##
## Usage:
##   var tier_manager := DistanceTierManager.new()
##   tier_manager.configure_for_world(data_provider)
##   var tier := tier_manager.get_tier_for_cell(camera_cell, target_cell)
class_name DistanceTierManager
extends RefCounted


## Distance tiers for rendering detail levels
enum Tier {
	NEAR,      ## Full 3D meshes with LOD (0-500m)
	MID,       ## Simplified merged geometry (500m-2km)
	FAR,       ## Octahedral impostors (2km-5km)
	HORIZON,   ## Skybox/billboard only (5km+)
	NONE,      ## Beyond all tiers (don't load)
}


## Load priority for each tier (higher = load sooner)
const TIER_PRIORITY := {
	Tier.NEAR: 100,
	Tier.MID: 50,
	Tier.FAR: 25,
	Tier.HORIZON: 0,
	Tier.NONE: -1,
}


## DEFAULT maximum cells per tier to prevent queue overflow
## These are fallback values - worlds can override via get_tier_unit_counts()
## These are HARD LIMITS - never exceed regardless of distance calculation
## Without these limits, enabling distant rendering queues ~23,000 cells and freezes
const DEFAULT_MAX_CELLS_PER_TIER := {
	Tier.NEAR: 50,       # Full 3D geometry - expensive, keep low
	Tier.MID: 100,       # Pre-merged meshes only - medium cost
	Tier.FAR: 200,       # Impostors only - cheap but still limited
	Tier.HORIZON: 0,     # Skybox only - no per-cell processing
}

## Actual maximum cells per tier (configured per-world or using defaults)
var max_cells_per_tier: Dictionary = DEFAULT_MAX_CELLS_PER_TIER.duplicate()


## Default distance thresholds (in meters)
## These can be overridden per-world via configure_for_world()
var tier_distances := {
	Tier.NEAR: 0.0,        # 0m start
	Tier.MID: 500.0,       # 500m start
	Tier.FAR: 2000.0,      # 2km start
	Tier.HORIZON: 5000.0,  # 5km start
}


## Default tier end distances (in meters)
## MID ends where FAR starts, etc.
var tier_end_distances := {
	Tier.NEAR: 500.0,      # NEAR ends at 500m
	Tier.MID: 2000.0,      # MID ends at 2km
	Tier.FAR: 5000.0,      # FAR ends at 5km
	Tier.HORIZON: 10000.0, # HORIZON ends at 10km
}


## Hysteresis margins to prevent flickering at tier boundaries
## When transitioning from tier A to B, require distance to be
## threshold ± margin depending on direction
var tier_hysteresis := {
	Tier.NEAR: 50.0,       # ±50m at NEAR/MID boundary
	Tier.MID: 100.0,       # ±100m at MID/FAR boundary
	Tier.FAR: 200.0,       # ±200m at FAR/HORIZON boundary
	Tier.HORIZON: 0.0,     # No hysteresis at edge of world
}


## Cell size in meters (Morrowind default: ~117m)
## Used to convert cell counts to distances
var cell_size_meters: float = 117.0


## Currently tracked tiers for cells (for hysteresis)
## Maps Vector2i -> Tier
var _cell_tiers: Dictionary = {}


## Whether distant rendering is enabled
var distant_rendering_enabled: bool = true


## Maximum view distance in meters
var max_view_distance: float = 5000.0


## Camera reference for view frustum culling (set by WorldStreamingManager)
var camera: Camera3D = null


## Whether to use view frustum culling for MID/FAR tiers
## Significantly reduces cell count by only processing visible cells
var use_frustum_culling: bool = true


#region Configuration


## Configure tier distances for a specific world
## world_provider: Should implement get_max_view_distance() and tier overrides
func configure_for_world(world_provider) -> void:
	if not world_provider:
		return

	# Get max view distance from provider
	if world_provider.has_method("get_max_view_distance"):
		var world_max_distance := world_provider.get_max_view_distance()
		if world_max_distance > 0.0:
			max_view_distance = world_max_distance

	# Check if world supports distant rendering
	if world_provider.has_method("supports_distant_rendering"):
		distant_rendering_enabled = world_provider.supports_distant_rendering()

	# Get cell size if available
	if world_provider.has_method("get_cell_size_meters"):
		var world_cell_size := world_provider.get_cell_size_meters()
		if world_cell_size > 0.0:
			cell_size_meters = world_cell_size

	# Get per-world tier unit counts (CRITICAL for different region sizes)
	if world_provider.has_method("get_tier_unit_counts"):
		var world_tier_counts: Dictionary = world_provider.get_tier_unit_counts()
		if not world_tier_counts.is_empty():
			# Override defaults with world-specific counts
			for tier in world_tier_counts:
				max_cells_per_tier[tier] = world_tier_counts[tier]
			print("DistanceTierManager: Using world-specific tier counts - NEAR: %d, MID: %d, FAR: %d" % [
				max_cells_per_tier.get(Tier.NEAR, 0),
				max_cells_per_tier.get(Tier.MID, 0),
				max_cells_per_tier.get(Tier.FAR, 0)
			])

	# Allow world-specific tier distance overrides
	if world_provider.has_method("get_tier_distances"):
		var overrides: Dictionary = world_provider.get_tier_distances()
		for tier in overrides:
			if tier in tier_distances:
				tier_distances[tier] = overrides[tier]

	# Recalculate end distances from start distances
	_recalculate_end_distances()

	print("DistanceTierManager: Configured for world - cell size: %.0fm, max distance: %.0fm, distant rendering: %s" % [
		cell_size_meters, max_view_distance, "enabled" if distant_rendering_enabled else "disabled"
	])


## Manually set tier distances (for testing or custom configuration)
func set_tier_distances(near: float, mid: float, far: float, horizon: float) -> void:
	tier_distances[Tier.NEAR] = 0.0
	tier_distances[Tier.MID] = near
	tier_distances[Tier.FAR] = mid
	tier_distances[Tier.HORIZON] = far
	max_view_distance = horizon
	_recalculate_end_distances()


## Recalculate end distances from start distances
func _recalculate_end_distances() -> void:
	tier_end_distances[Tier.NEAR] = tier_distances[Tier.MID]
	tier_end_distances[Tier.MID] = tier_distances[Tier.FAR]
	tier_end_distances[Tier.FAR] = tier_distances[Tier.HORIZON]
	tier_end_distances[Tier.HORIZON] = max_view_distance


#endregion


#region Tier Queries


## Get the appropriate tier for a cell based on distance from camera
## camera_cell: The cell the camera is currently in
## target_cell: The cell to determine tier for
## Returns: The rendering tier for this cell
func get_tier_for_cell(camera_cell: Vector2i, target_cell: Vector2i) -> Tier:
	if not distant_rendering_enabled:
		# When disabled, only NEAR tier is used (original behavior)
		var distance := _cell_distance_meters(camera_cell, target_cell)
		if distance <= tier_end_distances[Tier.NEAR]:
			return Tier.NEAR
		return Tier.NONE

	var distance := _cell_distance_meters(camera_cell, target_cell)
	return get_tier_for_distance(distance, target_cell)


## Get tier for a given distance in meters
## Applies hysteresis if cell has a previous tier tracked
func get_tier_for_distance(distance: float, cell: Vector2i = Vector2i.ZERO) -> Tier:
	# Check if beyond max view distance
	if distance > max_view_distance:
		return Tier.NONE

	# Get previous tier for hysteresis (if tracked)
	var previous_tier: Tier = _cell_tiers.get(cell, Tier.NONE)

	# Determine base tier from distance
	var base_tier := _get_tier_from_distance_raw(distance)

	# Apply hysteresis if we have a previous tier
	if previous_tier != Tier.NONE and previous_tier != base_tier:
		var hysteresis: float = tier_hysteresis.get(mini(int(previous_tier), int(base_tier)), 0.0)

		if previous_tier < base_tier:
			# Moving away (lower detail) - require distance > threshold + hysteresis
			var threshold: float = tier_end_distances.get(previous_tier, 0.0)
			if distance < threshold + hysteresis:
				base_tier = previous_tier
		else:
			# Moving closer (higher detail) - require distance < threshold - hysteresis
			var threshold: float = tier_distances.get(previous_tier, 0.0)
			if distance > threshold - hysteresis:
				base_tier = previous_tier

	# Update tracked tier
	if cell != Vector2i.ZERO:
		_cell_tiers[cell] = base_tier

	return base_tier


## Get tier without hysteresis (raw distance check)
func _get_tier_from_distance_raw(distance: float) -> Tier:
	if distance < tier_distances[Tier.MID]:
		return Tier.NEAR
	elif distance < tier_distances[Tier.FAR]:
		return Tier.MID
	elif distance < tier_distances[Tier.HORIZON]:
		return Tier.FAR
	elif distance <= max_view_distance:
		return Tier.HORIZON
	return Tier.NONE


## Get loading priority for a tier
func get_tier_priority(tier: Tier) -> int:
	return TIER_PRIORITY.get(tier, -1)


## Check if full geometry should be loaded for a tier
func should_load_full_geometry(tier: Tier) -> bool:
	return tier == Tier.NEAR


## Check if merged meshes should be used for a tier
func should_load_merged_mesh(tier: Tier) -> bool:
	return tier == Tier.MID


## Check if impostors should be used for a tier
func should_load_impostors(tier: Tier) -> bool:
	return tier == Tier.FAR


## Check if only skybox/horizon is needed for a tier
func is_horizon_only(tier: Tier) -> bool:
	return tier == Tier.HORIZON


#endregion


#region Cell Visibility


## Get all visible cells organized by tier
## camera_cell: The cell the camera is in
## Returns: Dictionary mapping Tier -> Array[Vector2i]
##
## CRITICAL: This function now enforces hard cell limits per tier to prevent
## queue overflow. Cells are sorted by distance so closest are prioritized.
## View frustum culling is applied to MID/FAR tiers to reduce processing.
func get_visible_cells_by_tier(camera_cell: Vector2i) -> Dictionary:
	var result := {
		Tier.NEAR: [] as Array[Vector2i],
		Tier.MID: [] as Array[Vector2i],
		Tier.FAR: [] as Array[Vector2i],
		Tier.HORIZON: [] as Array[Vector2i],
	}

	# Calculate cell radius for each tier
	var near_radius := ceili(tier_end_distances[Tier.NEAR] / cell_size_meters)
	var mid_radius := ceili(tier_end_distances[Tier.MID] / cell_size_meters) if distant_rendering_enabled else 0
	var far_radius := ceili(tier_end_distances[Tier.FAR] / cell_size_meters) if distant_rendering_enabled else 0
	# HORIZON tier doesn't need per-cell processing - skip it entirely
	var horizon_radius := 0  # Was: ceili(max_view_distance / cell_size_meters)

	var max_radius := maxi(near_radius, maxi(mid_radius, far_radius))

	# Collect cells with their distances for sorting
	var cells_with_distance: Array[Dictionary] = []

	# Iterate over all cells within max radius
	for dy in range(-max_radius, max_radius + 1):
		for dx in range(-max_radius, max_radius + 1):
			var cell := Vector2i(camera_cell.x + dx, camera_cell.y + dy)
			var distance := _cell_distance_meters(camera_cell, cell)
			var tier := _get_tier_from_distance_raw(distance)

			if tier == Tier.NONE or tier == Tier.HORIZON:
				continue

			# Apply view frustum culling for MID/FAR tiers
			if use_frustum_culling and camera and tier != Tier.NEAR:
				if not _is_cell_in_frustum(cell):
					continue

			cells_with_distance.append({
				"cell": cell,
				"distance": distance,
				"tier": tier
			})

	# Sort by distance (closest first)
	cells_with_distance.sort_custom(func(a, b): return a.distance < b.distance)

	# Distribute to tiers respecting hard limits
	var tier_counts := {
		Tier.NEAR: 0,
		Tier.MID: 0,
		Tier.FAR: 0,
	}

	for entry in cells_with_distance:
		var tier: int = entry.tier
		var max_for_tier: int = max_cells_per_tier.get(tier, 0)

		if tier_counts[tier] < max_for_tier:
			result[tier].append(entry.cell)
			tier_counts[tier] += 1

	return result


## Check if a cell is within the camera's view frustum
## Uses a simple AABB check against the frustum planes
func _is_cell_in_frustum(cell: Vector2i) -> bool:
	if not camera:
		return true  # No camera = assume visible

	# Calculate cell center in world coordinates
	var cell_center := Vector3(
		cell.x * cell_size_meters + cell_size_meters * 0.5,
		0.0,  # Y will be terrain height, use 0 for simplicity
		-cell.y * cell_size_meters - cell_size_meters * 0.5  # Z is flipped in Godot
	)

	# Create cell AABB (assuming ~100m height for buildings)
	var half_size := cell_size_meters * 0.5
	var cell_aabb := AABB(
		cell_center - Vector3(half_size, 0, half_size),
		Vector3(cell_size_meters, 100.0, cell_size_meters)
	)

	# Check against camera frustum
	var frustum := camera.get_frustum()
	for plane in frustum:
		# Check if AABB is completely behind this plane
		var corner := cell_aabb.position
		if plane.normal.x >= 0:
			corner.x += cell_aabb.size.x
		if plane.normal.y >= 0:
			corner.y += cell_aabb.size.y
		if plane.normal.z >= 0:
			corner.z += cell_aabb.size.z

		if plane.distance_to(corner) < 0:
			return false  # Completely outside this plane

	return true


## Get cells that should be loaded at a specific tier
## Uses circular distance check for natural view distance
func get_cells_for_tier(camera_cell: Vector2i, tier: Tier) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []

	if tier == Tier.NONE:
		return cells

	var min_distance: float = tier_distances.get(tier, 0.0)
	var max_distance: float = tier_end_distances.get(tier, 0.0)

	var min_radius := floori(min_distance / cell_size_meters)
	var max_radius := ceili(max_distance / cell_size_meters)

	for dy in range(-max_radius, max_radius + 1):
		for dx in range(-max_radius, max_radius + 1):
			var cell := Vector2i(camera_cell.x + dx, camera_cell.y + dy)
			var distance := _cell_distance_meters(camera_cell, cell)

			if distance >= min_distance and distance < max_distance:
				cells.append(cell)

	return cells


## Get cell count for each tier (for budgeting)
func get_tier_cell_counts(camera_cell: Vector2i) -> Dictionary:
	var counts := {}
	var by_tier := get_visible_cells_by_tier(camera_cell)

	for tier in by_tier:
		counts[tier] = by_tier[tier].size()

	return counts


#endregion


#region Distance Utilities


## Calculate distance in meters between two cells (center to center)
func _cell_distance_meters(from_cell: Vector2i, to_cell: Vector2i) -> float:
	var dx := (to_cell.x - from_cell.x) * cell_size_meters
	var dy := (to_cell.y - from_cell.y) * cell_size_meters
	return sqrt(dx * dx + dy * dy)


## Convert cell count to approximate distance in meters
func cells_to_meters(cell_count: int) -> float:
	return cell_count * cell_size_meters


## Convert distance in meters to approximate cell count
func meters_to_cells(meters: float) -> int:
	return ceili(meters / cell_size_meters)


## Get distance range for a tier (min, max) in meters
func get_tier_distance_range(tier: Tier) -> Vector2:
	return Vector2(
		tier_distances.get(tier, 0.0),
		tier_end_distances.get(tier, 0.0)
	)


#endregion


#region State Management


## Clear tracked cell tiers (call when teleporting or changing world)
func clear_cell_tiers() -> void:
	_cell_tiers.clear()


## Remove tracking for a specific cell
func forget_cell(cell: Vector2i) -> void:
	_cell_tiers.erase(cell)


## Get the current tracked tier for a cell (or NONE if not tracked)
func get_tracked_tier(cell: Vector2i) -> Tier:
	return _cell_tiers.get(cell, Tier.NONE)


## Get count of tracked cells
func get_tracked_count() -> int:
	return _cell_tiers.size()


#endregion


#region Debug


## Get tier name as string
static func tier_to_string(tier: Tier) -> String:
	match tier:
		Tier.NEAR: return "NEAR"
		Tier.MID: return "MID"
		Tier.FAR: return "FAR"
		Tier.HORIZON: return "HORIZON"
		Tier.NONE: return "NONE"
		_: return "UNKNOWN"


## Get debug info
func get_debug_info() -> Dictionary:
	return {
		"enabled": distant_rendering_enabled,
		"max_view_distance": max_view_distance,
		"cell_size_meters": cell_size_meters,
		"tracked_cells": _cell_tiers.size(),
		"tier_distances": tier_distances.duplicate(),
		"tier_end_distances": tier_end_distances.duplicate(),
		"tier_hysteresis": tier_hysteresis.duplicate(),
		"max_cells_per_tier": max_cells_per_tier.duplicate(),
		"frustum_culling": use_frustum_culling,
		"has_camera": camera != null,
	}


## Set the camera for frustum culling
func set_camera(cam: Camera3D) -> void:
	camera = cam


#endregion
