## DistanceTierManager - UNIFIED VISIBILITY AUTHORITY for multi-tier rendering
##
## **SINGLE SOURCE OF TRUTH** for all visibility and tier calculations.
## All other systems (ObjectStreamer, ImpostorManager, CellManager) consume
## visibility data from this manager - they NEVER calculate visibility themselves.
##
## Tier System:
## - NEAR: Full 3D meshes (0-150m)
## - MID: Per-object LOD meshes via ObjectStreamer (150-500m)
## - FAR: Octahedral impostors via ImpostorManager (500m-5km)
## - HORIZON: Skybox integration (5km+)
##
## Distance thresholds are defined in DistanceUtils (single source of truth).
##
## Architecture:
## 1. WorldStreamingManager calls update_visibility() once per frame
## 2. DistanceTierManager calculates all visibility (cells + objects)
## 3. Consumers query results via get_visible_cells_by_tier() / get_visible_objects_by_tier()
## 4. Tier changes are tracked and can be queried via get_tier_changes_since_last_update()
##
## Key features:
## - Unified authority: NO OTHER SYSTEM calculates visibility
## - Frame-perfect synchronization across all rendering systems
## - Hysteresis to prevent tier flickering at boundaries
## - Frustum culling for MID/FAR tiers
## - Per-world configurable distances
## - Tracks both cell-level and object-level visibility
##
## Usage:
##   var tier_manager := DistanceTierManager.new()
##   tier_manager.configure_for_world(data_provider)
##
##   # In _process():
##   tier_manager.set_camera_position(camera.global_position)
##   tier_manager.update_visibility(camera_cell, delta)
##
##   # Consumers query results:
##   var visible_cells = tier_manager.get_visible_cells_by_tier()
##   var tier_changes = tier_manager.get_tier_changes_since_last_update()
class_name DistanceTierManager
extends RefCounted

## Use centralized distance utilities
const DU := preload("res://src/core/world/distance_utils.gd")

## Distance tiers for rendering detail levels
enum Tier {
	NEAR,      ## Full 3D meshes with per-object LOD (0-150m)
	MID,       ## Merged/simplified meshes (150-500m)
	FAR,       ## Octahedral impostors (500m-5km)
	HORIZON,   ## Skybox/billboard only (5km+)
	NONE,      ## Beyond all tiers (don't load)
}


## Load priority for each tier (higher = load sooner)
const TIER_PRIORITY := {
	Tier.NEAR: 100,
	Tier.MID: 50,    # Medium priority for merged meshes
	Tier.FAR: 25,
	Tier.HORIZON: 0,
	Tier.NONE: -1,
}


## DEFAULT maximum cells per tier to prevent queue overflow
## These are fallback values - worlds can override via get_tier_unit_counts()
## These are HARD LIMITS - never exceed regardless of distance calculation
## Without these limits, enabling distant rendering queues ~23,000 cells and freezes
##
## With 117m cells:
## - NEAR 150m = ~1.3 cells radius → ~9 cells in circle (use 13 for buffer)
## - MID 150-500m = ~4.3 cells radius → ~60 cells in ring (use 80 for buffer)
## - FAR 500-5000m = ~43 cells radius → thousands of cells (cap at 250)
const DEFAULT_MAX_CELLS_PER_TIER := {
	Tier.NEAR: 13,       # Full 3D geometry - expensive (~150m radius)
	Tier.MID: 80,        # Merged meshes - medium cost (150-500m)
	Tier.FAR: 250,       # Impostors only - cheap but still limited
	Tier.HORIZON: 0,     # Skybox only - no per-cell processing
}

## Chunk sizes for quadtree paging (when enabled)
## FAR tier uses 8x8 cell chunks (~936m each)
const FAR_CHUNK_SIZE := 8

## Maximum chunks per tier (for chunk-based paging)
## These limits apply when use_chunk_paging is enabled
const DEFAULT_MAX_CHUNKS_PER_TIER := {
	Tier.FAR: 80,        # 8x8 chunks = up to 5120 cells worth
}

## Actual maximum cells per tier (configured per-world or using defaults)
var max_cells_per_tier: Dictionary = DEFAULT_MAX_CELLS_PER_TIER.duplicate()


## Default distance thresholds (in meters) from DistanceUtils
## These can be overridden per-world via configure_for_world()
var tier_distances := {
	Tier.NEAR: DU.NEAR_START,   # 0m start - full 3D geometry
	Tier.MID: DU.MID_START,     # 150m start - per-object LODs
	Tier.FAR: DU.FAR_START,     # 500m start - impostors
	Tier.HORIZON: DU.FAR_END,   # 5km start - skybox only
}


## Default tier end distances (in meters) from DistanceUtils
var tier_end_distances := {
	Tier.NEAR: DU.NEAR_END,     # NEAR ends at 150m
	Tier.MID: DU.MID_END,       # MID ends at 500m
	Tier.FAR: DU.FAR_END,       # FAR ends at 5km
	Tier.HORIZON: 10000.0,      # HORIZON ends at 10km
}


## Hysteresis margins to prevent flickering at tier boundaries
## When transitioning from tier A to B, require distance to be
## threshold ± margin depending on direction
## Increased from original values for smoother cell tier transitions
var tier_hysteresis := {
	Tier.NEAR: 40.0,       # ±40m at NEAR/MID boundary (150m) - was 20m
	Tier.MID: 60.0,        # ±60m at MID/FAR boundary (500m) - was 30m
	Tier.FAR: 150.0,       # ±150m at FAR/HORIZON boundary (5km) - was 100m
	Tier.HORIZON: 0.0,     # No hysteresis at edge of world
}


## Cell size in meters (from DistanceUtils - single source of truth)
var cell_size_meters: float = DU.CELL_SIZE_METERS


## Currently tracked tiers for cells (for hysteresis)
## Maps Vector2i -> Tier
var _cell_tiers: Dictionary = {}


## Whether distant rendering is enabled
var distant_rendering_enabled: bool = true


## Maximum view distance in meters
var max_view_distance: float = DU.FAR_END


## Camera reference for view frustum culling (set by WorldStreamingManager)
var camera: Camera3D = null


## Last known camera position (for position-based distance calculations)
## Updated every frame via set_camera_position() for smooth tier transitions
var _camera_position: Vector3 = Vector3.ZERO


#region UNIFIED VISIBILITY AUTHORITY - Object Tracking

## **NEW**: Registered objects for per-object tier tracking
## Maps object_id (int) -> ObjectVisibilityInfo
## Objects are registered by ObjectStreamer via register_object()
var _registered_objects: Dictionary = {}

## **NEW**: Current tier for each object
## Maps object_id (int) -> Tier
## Updated every frame by update_visibility()
var _object_tier_map: Dictionary = {}

## **NEW**: Objects grouped by current tier (for fast queries)
## Maps Tier -> Array[int] (object_ids)
## Rebuilt every frame when object tiers change
var _visible_objects_by_tier: Dictionary = {
	Tier.NEAR: [] as Array[int],
	Tier.MID: [] as Array[int],
	Tier.FAR: [] as Array[int],
	Tier.HORIZON: [] as Array[int],
}

## **NEW**: Tier changes detected in last update_visibility() call
## Array of {object_id: int, old_tier: Tier, new_tier: Tier, distance: float}
## Cleared at start of each update_visibility() call
## Consumers can query this to get tier transitions for the current frame
var _tier_changes_this_frame: Array[Dictionary] = []

## **NEW**: Cached visible cells from last update (for change detection)
var _cached_visible_cells_by_tier: Dictionary = {}

## **NEW**: Frame counter for visibility updates (for debugging/stats)
var _visibility_update_frame: int = 0

## **NEW**: Object visibility info
class ObjectVisibilityInfo extends RefCounted:
	var id: int = -1
	var position: Vector3 = Vector3.ZERO
	var cell_grid: Vector2i = Vector2i.ZERO
	var current_tier: Tier = Tier.NONE
	var last_distance: float = 0.0
	var last_update_frame: int = 0

#endregion


## Whether to use view frustum culling for MID/FAR tiers
## Significantly reduces cell count by only processing visible cells
var use_frustum_culling: bool = true


#region Configuration


## Configure tier distances for a specific world
## world_provider: Should implement get_max_view_distance() and tier overrides
func configure_for_world(world_provider: Object) -> void:
	if not world_provider:
		return

	# Get max view distance from provider
	if world_provider.has_method("get_max_view_distance"):
		var world_max_distance: float = world_provider.call("get_max_view_distance")
		if world_max_distance > 0.0:
			max_view_distance = world_max_distance

	# Check if world supports distant rendering
	if world_provider.has_method("supports_distant_rendering"):
		distant_rendering_enabled = world_provider.call("supports_distant_rendering")

	# Get cell size if available
	if world_provider.has_method("get_cell_size_meters"):
		var world_cell_size: float = world_provider.call("get_cell_size_meters")
		if world_cell_size > 0.0:
			cell_size_meters = world_cell_size

	# Get per-world tier unit counts (CRITICAL for different region sizes)
	if world_provider.has_method("get_tier_unit_counts"):
		var world_tier_counts: Dictionary = world_provider.call("get_tier_unit_counts")
		if not world_tier_counts.is_empty():
			# Override defaults with world-specific counts
			for tier: Variant in world_tier_counts:
				max_cells_per_tier[tier] = world_tier_counts[tier]
			print("DistanceTierManager: Using world-specific tier counts - NEAR: %d, MID: %d, FAR: %d" % [
				max_cells_per_tier.get(Tier.NEAR, 0),
				max_cells_per_tier.get(Tier.MID, 0),
				max_cells_per_tier.get(Tier.FAR, 0)
			])

	# Allow world-specific tier distance overrides
	if world_provider.has_method("get_tier_distances"):
		var overrides: Dictionary = world_provider.call("get_tier_distances")
		for tier: Variant in overrides:
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


## Get ALL cells within a given radius (in meters) without tier assignment
## Used for radius-based loading where ObjectStreamer handles all visibility
## camera_cell: The cell the camera is in
## radius_meters: Maximum distance in meters (defaults to FAR_END)
## Returns: Array[Vector2i] of all cells within radius, sorted by distance (closest first)
##
## IMPORTANT: Uses actual camera position (_camera_position) for distance calculations
## instead of camera cell center. This prevents jumping when crossing cell boundaries.
## Call set_camera_position() every frame before calling this function.
func get_all_cells_in_radius(camera_cell: Vector2i, radius_meters: float = -1.0) -> Array[Vector2i]:
	if radius_meters < 0.0:
		radius_meters = tier_end_distances[Tier.FAR]

	# Add buffer to cell radius since camera might be at edge of cell
	var cell_radius := ceili((radius_meters + cell_size_meters) / cell_size_meters)
	var radius_sq := radius_meters * radius_meters

	# Use actual camera position for distance calculation (smooth transitions)
	var use_position_distance := _camera_position != Vector3.ZERO

	# Collect cells with distance for sorting
	var cells_with_distance: Array[Dictionary] = []

	for dy in range(-cell_radius, cell_radius + 1):
		for dx in range(-cell_radius, cell_radius + 1):
			var cell := Vector2i(camera_cell.x + dx, camera_cell.y + dy)

			# Use position-based distance for smooth transitions
			var distance_sq: float
			if use_position_distance:
				distance_sq = position_to_cell_distance_squared(cell)
			else:
				distance_sq = _cell_distance_squared(camera_cell, cell)

			if distance_sq <= radius_sq:
				cells_with_distance.append({
					"cell": cell,
					"distance_sq": distance_sq
				})

	# Sort by distance (closest first)
	cells_with_distance.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.distance_sq < b.distance_sq)

	# Extract just the cells
	var result: Array[Vector2i] = []
	for entry: Dictionary in cells_with_distance:
		result.append(entry.cell)

	return result


## Get all visible cells organized by tier
## camera_cell: The cell the camera is in
## Returns: Dictionary mapping Tier -> Array[Vector2i]
##
## CRITICAL: This function now enforces hard cell limits per tier to prevent
## queue overflow. Cells are sorted by distance so closest are prioritized.
## View frustum culling is applied to MID and FAR tiers to reduce processing.
##
## IMPORTANT: Uses actual camera position (_camera_position) for distance calculations
## instead of camera cell center. This prevents tier jumping when crossing cell boundaries.
## Call set_camera_position() every frame before calling this function.
func get_visible_cells_by_tier(camera_cell: Vector2i) -> Dictionary:
	var result := {
		Tier.NEAR: [] as Array[Vector2i],
		Tier.MID: [] as Array[Vector2i],
		Tier.FAR: [] as Array[Vector2i],
		Tier.HORIZON: [] as Array[Vector2i],
	}

	# Calculate cell radius for each tier (add buffer for position-based calculation)
	# We need a slightly larger search radius since camera might be at edge of cell
	var near_end_dist: float = tier_end_distances[Tier.NEAR]
	var near_radius := ceili((near_end_dist + cell_size_meters) / cell_size_meters)
	var mid_end_dist: float = tier_end_distances[Tier.MID]
	var mid_radius := ceili((mid_end_dist + cell_size_meters) / cell_size_meters) if distant_rendering_enabled else 0
	var far_end_dist: float = tier_end_distances[Tier.FAR]
	var far_radius := ceili((far_end_dist + cell_size_meters) / cell_size_meters) if distant_rendering_enabled else 0
	# HORIZON tier doesn't need per-cell processing - skip it entirely

	var max_radius := maxi(near_radius, maxi(mid_radius, far_radius))

	# Collect cells with their squared distances for sorting (avoid sqrt)
	var cells_with_distance: Array[Dictionary] = []

	# Pre-compute squared tier thresholds for comparison without sqrt
	var near_end_sq := near_end_dist * near_end_dist
	var mid_end_sq := mid_end_dist * mid_end_dist
	var far_end_sq := far_end_dist * far_end_dist

	# Use actual camera position for distance calculation (smooth transitions)
	# Falls back to cell-center if position not set
	var use_position_distance := _camera_position != Vector3.ZERO

	# Iterate over all cells within max radius
	for dy in range(-max_radius, max_radius + 1):
		for dx in range(-max_radius, max_radius + 1):
			var cell := Vector2i(camera_cell.x + dx, camera_cell.y + dy)

			# Use position-based distance for smooth tier transitions
			var distance_sq: float
			if use_position_distance:
				distance_sq = position_to_cell_distance_squared(cell)
			else:
				distance_sq = _cell_distance_squared(camera_cell, cell)

			# Determine tier using squared distance thresholds
			var tier: Tier
			if distance_sq < near_end_sq:
				tier = Tier.NEAR
			elif distance_sq < mid_end_sq:
				tier = Tier.MID
			elif distance_sq < far_end_sq:
				tier = Tier.FAR
			else:
				continue  # Skip HORIZON and beyond

			# Apply view frustum culling for MID and FAR tiers
			if use_frustum_culling and camera and (tier == Tier.MID or tier == Tier.FAR):
				if not _is_cell_in_frustum(cell):
					continue

			cells_with_distance.append({
				"cell": cell,
				"distance_sq": distance_sq,  # Store squared distance
				"tier": tier
			})

	# Sort by squared distance (closest first) - same ordering, no sqrt needed
	cells_with_distance.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.distance_sq < b.distance_sq)

	# Distribute to tiers respecting hard limits
	var tier_counts := {
		Tier.NEAR: 0,
		Tier.MID: 0,
		Tier.FAR: 0,
	}

	for entry: Dictionary in cells_with_distance:
		var tier: int = entry.tier
		var max_for_tier: int = max_cells_per_tier.get(tier, 0)

		if tier_counts[tier] < max_for_tier:
			var cells_array: Array = result[tier]
			cells_array.append(entry.cell)
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
##
## IMPORTANT: Uses actual camera position (_camera_position) for distance calculations
## instead of camera cell center. This prevents jumping when crossing cell boundaries.
## Call set_camera_position() every frame before calling this function.
func get_cells_for_tier(camera_cell: Vector2i, tier: Tier) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []

	if tier == Tier.NONE:
		return cells

	var min_distance: float = tier_distances.get(tier, 0.0)
	var max_distance: float = tier_end_distances.get(tier, 0.0)

	# Add buffer to radius since camera might be at edge of cell
	var min_radius := floori(min_distance / cell_size_meters)
	var max_radius := ceili((max_distance + cell_size_meters) / cell_size_meters)

	# Use actual camera position for distance calculation (smooth transitions)
	var use_position_distance := _camera_position != Vector3.ZERO

	for dy in range(-max_radius, max_radius + 1):
		for dx in range(-max_radius, max_radius + 1):
			var cell := Vector2i(camera_cell.x + dx, camera_cell.y + dy)

			# Use position-based distance for smooth transitions
			var distance: float
			if use_position_distance:
				distance = position_to_cell_distance(cell)
			else:
				distance = _cell_distance_meters(camera_cell, cell)

			if distance >= min_distance and distance < max_distance:
				cells.append(cell)

	return cells


## Get cell count for each tier (for budgeting)
func get_tier_cell_counts(camera_cell: Vector2i) -> Dictionary:
	var counts := {}
	var by_tier := get_visible_cells_by_tier(camera_cell)

	for tier: Variant in by_tier:
		var tier_array: Array = by_tier[tier]
		counts[tier] = tier_array.size()

	return counts


#endregion


#region UNIFIED VISIBILITY AUTHORITY - Main API

## **NEW - MAIN ENTRY POINT**: Update all visibility calculations for the current frame
## This is the ONLY method that calculates visibility - called once per frame by WorldStreamingManager
##
## Performs:
## 1. Cell-level visibility (which cells are in which tier)
## 2. Object-level visibility (which objects are in which tier)
## 3. Tier change detection (objects that changed tiers this frame)
##
## camera_cell: The cell the camera is currently in
## delta: Frame delta time (for future temporal smoothing)
##
## Returns: Summary dictionary with change counts for diagnostics
func update_visibility(camera_cell: Vector2i, delta: float = 0.0) -> Dictionary:
	_visibility_update_frame += 1
	_tier_changes_this_frame.clear()

	var stats := {
		"frame": _visibility_update_frame,
		"objects_checked": 0,
		"objects_changed_tier": 0,
		"cells_per_tier": {},
		"objects_per_tier": {},
	}

	# 1. Update cell-level visibility (uses existing optimized implementation)
	var visible_cells_by_tier := get_visible_cells_by_tier(camera_cell)
	_cached_visible_cells_by_tier = visible_cells_by_tier.duplicate(true)

	for tier in visible_cells_by_tier:
		var cells_array: Array = visible_cells_by_tier[tier]
		stats.cells_per_tier[tier] = cells_array.size()

	# 2. Update object-level visibility
	# Clear per-tier object lists
	for tier in _visible_objects_by_tier:
		(_visible_objects_by_tier[tier] as Array).clear()

	# Update each registered object's tier
	for obj_id: int in _registered_objects:
		var obj: ObjectVisibilityInfo = _registered_objects[obj_id]
		stats.objects_checked += 1

		# Calculate distance from camera to object
		var distance := _camera_position.distance_to(obj.position)
		obj.last_distance = distance

		# Determine new tier using centralized tier calculation with hysteresis
		var old_tier: Tier = obj.current_tier
		var new_tier: Tier = get_tier_for_distance(distance, obj.cell_grid)

		# Detect tier changes
		if new_tier != old_tier:
			obj.current_tier = new_tier
			_object_tier_map[obj_id] = new_tier

			_tier_changes_this_frame.append({
				"object_id": obj_id,
				"old_tier": old_tier,
				"new_tier": new_tier,
				"distance": distance,
			})

			stats.objects_changed_tier += 1

		# Add to appropriate tier list (even if tier didn't change)
		if new_tier != Tier.NONE:
			var tier_list: Array = _visible_objects_by_tier[new_tier]
			tier_list.append(obj_id)

		obj.last_update_frame = _visibility_update_frame

	# Update stats
	for tier in _visible_objects_by_tier:
		var objects_array: Array = _visible_objects_by_tier[tier]
		stats.objects_per_tier[tier] = objects_array.size()

	return stats


## **NEW**: Register an object for visibility tracking
## Called by ObjectStreamer when objects are created
##
## object_id: Unique identifier for this object
## position: World position of the object
## cell_grid: Cell grid coordinates the object belongs to
##
## Returns: true if registered, false if already registered
func register_object(object_id: int, position: Vector3, cell_grid: Vector2i) -> bool:
	if object_id in _registered_objects:
		push_warning("[DistanceTierManager] Object %d already registered" % object_id)
		return false

	var obj_info := ObjectVisibilityInfo.new()
	obj_info.id = object_id
	obj_info.position = position
	obj_info.cell_grid = cell_grid
	obj_info.current_tier = Tier.NONE  # Will be calculated on first update
	obj_info.last_distance = 0.0
	obj_info.last_update_frame = 0

	_registered_objects[object_id] = obj_info
	_object_tier_map[object_id] = Tier.NONE

	return true


## **NEW**: Unregister an object from visibility tracking
## Called by ObjectStreamer when objects are destroyed
##
## object_id: Unique identifier for the object to remove
##
## Returns: true if unregistered, false if not found
func unregister_object(object_id: int) -> bool:
	if object_id not in _registered_objects:
		return false

	var obj_info: ObjectVisibilityInfo = _registered_objects[object_id]
	var tier: Tier = obj_info.current_tier

	# Remove from tier list
	if tier in _visible_objects_by_tier:
		var tier_list: Array = _visible_objects_by_tier[tier]
		var idx := tier_list.find(object_id)
		if idx >= 0:
			tier_list.remove_at(idx)

	_registered_objects.erase(object_id)
	_object_tier_map.erase(object_id)

	return true


## **NEW**: Update an object's position (for moving objects)
## Called by ObjectStreamer when objects move
##
## object_id: Unique identifier for the object
## new_position: New world position
##
## Returns: true if updated, false if object not found
func update_object_position(object_id: int, new_position: Vector3) -> bool:
	if object_id not in _registered_objects:
		return false

	var obj_info: ObjectVisibilityInfo = _registered_objects[object_id]
	obj_info.position = new_position

	return true


## **NEW**: Get all objects in a specific tier
## Consumers (ObjectStreamer, ImpostorManager) use this to get their target objects
##
## tier: The tier to query
##
## Returns: Array[int] of object_ids in this tier
func get_visible_objects_for_tier(tier: Tier) -> Array[int]:
	if tier in _visible_objects_by_tier:
		return (_visible_objects_by_tier[tier] as Array).duplicate()
	return []


## **NEW**: Get all visible objects grouped by tier
## Returns: Dictionary mapping Tier -> Array[int]
func get_visible_objects_by_tier() -> Dictionary:
	var result := {}
	for tier in _visible_objects_by_tier:
		result[tier] = (_visible_objects_by_tier[tier] as Array).duplicate()
	return result


## **NEW**: Get tier changes that occurred in the last update_visibility() call
## Consumers use this to react to tier transitions (crossfades, instantiation, etc.)
##
## Returns: Array of {object_id: int, old_tier: Tier, new_tier: Tier, distance: float}
func get_tier_changes_this_frame() -> Array[Dictionary]:
	return _tier_changes_this_frame.duplicate()


## **NEW**: Get current tier for a specific object
## Returns: Tier enum, or Tier.NONE if object not registered
func get_object_tier(object_id: int) -> Tier:
	return _object_tier_map.get(object_id, Tier.NONE)


## **NEW**: Get object info for debugging
## Returns: ObjectVisibilityInfo or null if not found
func get_object_info(object_id: int) -> ObjectVisibilityInfo:
	return _registered_objects.get(object_id, null)


## **NEW**: Get count of registered objects
func get_registered_object_count() -> int:
	return _registered_objects.size()


## **NEW**: Clear all registered objects (on world unload)
func clear_registered_objects() -> void:
	_registered_objects.clear()
	_object_tier_map.clear()
	for tier in _visible_objects_by_tier:
		(_visible_objects_by_tier[tier] as Array).clear()
	_tier_changes_this_frame.clear()


#endregion


#region Distance Utilities


## Calculate distance in meters between two cells (center to center)
## Uses DistanceUtils for centralized distance calculations
func _cell_distance_meters(from_cell: Vector2i, to_cell: Vector2i) -> float:
	return DU.cell_distance(from_cell, to_cell)


## Calculate squared distance in meters (faster - no sqrt)
## Uses DistanceUtils for centralized distance calculations
func _cell_distance_squared(from_cell: Vector2i, to_cell: Vector2i) -> float:
	return DU.cell_distance_squared(from_cell, to_cell)


## Calculate distance from actual camera position to cell center (in meters)
## This is more accurate than cell-to-cell distance for smooth tier transitions
func position_to_cell_distance(cell: Vector2i) -> float:
	return DU.position_to_cell_distance(_camera_position, cell)


## Calculate squared distance from camera position to cell center
func position_to_cell_distance_squared(cell: Vector2i) -> float:
	return DU.position_to_cell_distance_squared(_camera_position, cell)


## Convert cell count to approximate distance in meters
func cells_to_meters(cell_count: int) -> float:
	return DU.cell_radius_to_distance(cell_count)


## Convert distance in meters to approximate cell count
func meters_to_cells(meters: float) -> int:
	return DU.distance_to_cell_radius(meters)


## Get distance range for a tier (min, max) in meters
func get_tier_distance_range(tier: Tier) -> Vector2:
	var min_dist: float = tier_distances.get(tier, 0.0)
	var max_dist: float = tier_end_distances.get(tier, 0.0)
	return Vector2(min_dist, max_dist)


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


## Update camera position for smooth position-based tier calculations
## Call this every frame from WorldStreamingManager._process()
func set_camera_position(pos: Vector3) -> void:
	_camera_position = pos


## Get camera position
func get_camera_position() -> Vector3:
	return _camera_position


#endregion
