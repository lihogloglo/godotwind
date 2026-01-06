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
const GPUVisibilityManagerScript := preload("res://src/core/world/gpu_visibility_manager.gd")

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

## **PERFORMANCE OPTIMIZED**: Registered objects for per-object tier tracking
## Maps object_id (int) -> ObjectVisibilityInfo
##
## IMPORTANT: Only NEAR and MID tier objects are registered here.
## FAR tier objects use chunk-based rendering (QuadtreeChunkManager/ImpostorManager)
## to avoid iterating 10,000+ objects per frame.
##
## Typical counts:
## - NEAR tier (0-150m): ~500 objects
## - MID tier (150-500m): ~1000-2000 objects
## - FAR tier (500m-5km): Handled by chunks, NOT individual objects
##
## Objects are registered by ObjectStreamer via register_object()
var _registered_objects: Dictionary = {}

## **SPATIAL INDEX**: Objects grouped by cell for O(nearby_cells) lookup instead of O(all_objects)
## Maps Vector2i (cell_grid) -> Array[int] (object_ids in that cell)
var _objects_by_cell: Dictionary = {}

## **CACHE**: Cached keys for _objects_by_cell to avoid allocation on every cell iteration
## Refreshed only when objects are registered/unregistered (dirty flag)
var _objects_by_cell_keys_cache: Array = []
var _objects_by_cell_keys_dirty: bool = true

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

## **NEW**: Last camera cell used for cell visibility calculation (for cache invalidation)
var _last_camera_cell_for_cells: Vector2i = Vector2i(999999, 999999)

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
## Fixed: Was filtering ALL cells due to insufficient AABB height bounds (-100 to +500)
## Now uses -500 to +1000 (matching quadtree_chunk_manager.gd) for generous coverage
var use_frustum_culling: bool = true


#region GPU Compute Acceleration

## GPU visibility manager for accelerated tier calculations
## Automatically initialized on first use if hardware supports it
var _gpu_visibility_manager: RefCounted = null

## Whether GPU compute is enabled (can be disabled for debugging)
var use_gpu_compute: bool = true

## Whether GPU compute was successfully initialized
var _gpu_compute_available: bool = false

## Threshold for using GPU compute (objects registered)
## Below this threshold, CPU path may be faster due to dispatch overhead
## HYSTERESIS: Enable at 500, disable at 300 to prevent flickering at boundary
## Lowered from 600/400 to enable GPU acceleration sooner for better performance
const GPU_COMPUTE_ENABLE_THRESHOLD: int = 500
const GPU_COMPUTE_DISABLE_THRESHOLD: int = 300

## Legacy constant for compatibility
const GPU_COMPUTE_THRESHOLD: int = 500

## Incremental GPU sync settings
## Sync this many objects per frame instead of all at once
## Increased from 100 to 2000 to complete sync faster (~4 frames for 7500 objects)
## GPU buffer uploads are fast - the incremental approach was overly conservative
const GPU_SYNC_BATCH_SIZE: int = 2000

## Phase 2 GPU-driven mode flag
## When true, this Phase 1 GPU path is disabled in favor of GPUVisibilityRenderer (Phase 2)
## Set by WorldStreamingManager when Phase 2 is successfully initialized
var phase2_gpu_driven_enabled: bool = false

## Initialize GPU compute manager (called lazily on first update)
func _init_gpu_compute() -> void:
	if _gpu_visibility_manager != null:
		return  # Already initialized

	_gpu_visibility_manager = GPUVisibilityManagerScript.new()
	_gpu_compute_available = _gpu_visibility_manager.initialize()

	if _gpu_compute_available:
		# Configure tier distances to match our settings
		var near_end: float = tier_end_distances[Tier.NEAR]
		var mid_end: float = tier_end_distances[Tier.MID]
		var far_end: float = tier_end_distances[Tier.FAR]
		_gpu_visibility_manager.set_tier_distances(near_end, mid_end, far_end)

		# Configure hysteresis
		var near_hyst: float = tier_hysteresis.get(Tier.NEAR, 40.0)
		var mid_hyst: float = tier_hysteresis.get(Tier.MID, 60.0)
		var far_hyst: float = tier_hysteresis.get(Tier.FAR, 150.0)
		_gpu_visibility_manager.set_hysteresis(near_hyst, mid_hyst, far_hyst)

		print("[DistanceTierManager] GPU compute enabled - visibility calculations will be accelerated")
	else:
		print("[DistanceTierManager] GPU compute not available - using CPU fallback")


## Track if we've synced existing objects to GPU after init
var _gpu_objects_synced: bool = false

## Incremental sync state
var _gpu_sync_in_progress: bool = false
var _gpu_sync_batch_start: int = 0
var _gpu_sync_object_keys: Array = []  # Cached keys for iteration

## Whether GPU mode is currently active (with hysteresis)
var _gpu_mode_active: bool = false

## Check if GPU compute should be used for current update
func _should_use_gpu_compute() -> bool:
	# NOTE: Phase 2 GPU-driven mode check removed - Phase 1 GPU compute is now preferred
	# Phase 2 code remains for future use but Phase 1 is simpler and works well

	if not use_gpu_compute:
		return false

	if _gpu_visibility_manager == null:
		_init_gpu_compute()

	if not _gpu_compute_available:
		return false

	var object_count := _registered_objects.size()

	# HYSTERESIS: Prevent flickering at threshold boundary
	if _gpu_mode_active:
		# Currently using GPU - only disable if we drop below lower threshold
		if object_count < GPU_COMPUTE_DISABLE_THRESHOLD:
			_gpu_mode_active = false
			_gpu_objects_synced = false
			print("[DistanceTierManager] GPU mode disabled (objects: %d < %d)" % [object_count, GPU_COMPUTE_DISABLE_THRESHOLD])
	else:
		# Currently using CPU - only enable if we exceed upper threshold
		if object_count >= GPU_COMPUTE_ENABLE_THRESHOLD:
			_gpu_mode_active = true
			print("[DistanceTierManager] GPU mode enabled (objects: %d >= %d)" % [object_count, GPU_COMPUTE_ENABLE_THRESHOLD])

	# If GPU mode is active but not synced, start incremental sync
	if _gpu_mode_active and not _gpu_objects_synced:
		if not _gpu_sync_in_progress:
			# Start incremental sync
			_start_incremental_gpu_sync()
		else:
			# Continue incremental sync
			_continue_incremental_gpu_sync()

		# Don't use GPU path until sync is complete
		return false

	return _gpu_mode_active


## Start incremental GPU sync
func _start_incremental_gpu_sync() -> void:
	print("[DistanceTierManager] Starting incremental GPU sync for %d objects..." % _registered_objects.size())
	_gpu_visibility_manager.clear()
	_gpu_sync_object_keys = _registered_objects.keys()
	_gpu_sync_batch_start = 0
	_gpu_sync_in_progress = true


## Continue incremental GPU sync (call each frame)
func _continue_incremental_gpu_sync() -> void:
	if not _gpu_sync_in_progress:
		return

	var end_idx := mini(_gpu_sync_batch_start + GPU_SYNC_BATCH_SIZE, _gpu_sync_object_keys.size())

	for i in range(_gpu_sync_batch_start, end_idx):
		var obj_id: int = _gpu_sync_object_keys[i]
		if obj_id in _registered_objects:
			var obj_info: ObjectVisibilityInfo = _registered_objects[obj_id]
			_gpu_visibility_manager.register_object(obj_id, obj_info.position)

	_gpu_sync_batch_start = end_idx

	# Check if sync is complete
	if _gpu_sync_batch_start >= _gpu_sync_object_keys.size():
		_gpu_sync_in_progress = false
		_gpu_objects_synced = true
		_gpu_sync_object_keys.clear()
		print("[DistanceTierManager] Incremental GPU sync complete - switching to GPU path")


## Sync all registered objects to GPU visibility manager
## Called when GPU compute is first enabled or after significant changes
func _sync_objects_to_gpu() -> void:
	if not _gpu_visibility_manager:
		return

	# Clear and re-register all objects
	_gpu_visibility_manager.clear()

	for obj_id: int in _registered_objects:
		var obj_info: ObjectVisibilityInfo = _registered_objects[obj_id]
		_gpu_visibility_manager.register_object(obj_id, obj_info.position)


## Get GPU compute statistics
func get_gpu_stats() -> Dictionary:
	if _gpu_visibility_manager and _gpu_compute_available:
		return _gpu_visibility_manager.get_stats()
	return {"gpu_supported": false, "enabled": use_gpu_compute}

#endregion


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
## View frustum culling is applied to MID tier to reduce processing.
##
## IMPORTANT: Uses actual camera position (_camera_position) for distance calculations
## instead of camera cell center. This prevents tier jumping when crossing cell boundaries.
## Call set_camera_position() every frame before calling this function.
##
## OPTIMIZATION: Results are cached based on camera cell. If camera is in the same cell,
## returns cached result (cell visibility changes slowly relative to camera position within cell).
##
## PERFORMANCE FIX (January 2026): Instead of iterating (2*far_radius+1)² cells (7500+),
## we now iterate NEAR+MID with small radii, and for FAR tier we only check cells that
## actually have registered objects. This reduces iteration from ~7500 to ~200 cells.
func get_visible_cells_by_tier(camera_cell: Vector2i) -> Dictionary:
	# OPTIMIZATION: Return cached result if camera is in the same cell
	# Cell visibility only needs recalculating when camera crosses cell boundary
	if camera_cell == _last_camera_cell_for_cells and not _cached_visible_cells_by_tier.is_empty():
		return _cached_visible_cells_by_tier

	_last_camera_cell_for_cells = camera_cell

	var result := {
		Tier.NEAR: [] as Array[Vector2i],
		Tier.MID: [] as Array[Vector2i],
		Tier.FAR: [] as Array[Vector2i],
		Tier.HORIZON: [] as Array[Vector2i],
	}

	# Calculate cell radius for NEAR and MID only (small radii)
	var near_end_dist: float = tier_end_distances[Tier.NEAR]
	var near_radius := ceili((near_end_dist + cell_size_meters) / cell_size_meters)
	var mid_end_dist: float = tier_end_distances[Tier.MID]
	var mid_radius := ceili((mid_end_dist + cell_size_meters) / cell_size_meters) if distant_rendering_enabled else 0
	var far_end_dist: float = tier_end_distances[Tier.FAR]

	# Pre-compute squared tier thresholds for comparison without sqrt
	var near_end_sq := near_end_dist * near_end_dist
	var mid_end_sq := mid_end_dist * mid_end_dist
	var far_end_sq := far_end_dist * far_end_dist

	# Use actual camera position for distance calculation (smooth transitions)
	var use_position_distance := _camera_position != Vector3.ZERO

	# === PART 1: Iterate NEAR and MID tiers with small radius ===
	# MID radius is only ~5 cells, so we iterate at most (11)² = 121 cells
	var near_mid_radius := maxi(near_radius, mid_radius)
	var near_mid_cells: Array[Dictionary] = []

	for dy in range(-near_mid_radius, near_mid_radius + 1):
		for dx in range(-near_mid_radius, near_mid_radius + 1):
			var cell := Vector2i(camera_cell.x + dx, camera_cell.y + dy)

			var distance_sq: float
			if use_position_distance:
				distance_sq = position_to_cell_distance_squared(cell)
			else:
				distance_sq = _cell_distance_squared(camera_cell, cell)

			# Only NEAR and MID in this loop
			var tier: Tier
			if distance_sq < near_end_sq:
				tier = Tier.NEAR
			elif distance_sq < mid_end_sq:
				tier = Tier.MID
			else:
				continue  # Skip - will be handled in FAR loop or is beyond

			# Apply view frustum culling for MID tier only
			if use_frustum_culling and camera and tier == Tier.MID:
				if not _is_cell_in_frustum(cell):
					continue

			near_mid_cells.append({
				"cell": cell,
				"distance_sq": distance_sq,
				"tier": tier
			})

	# === PART 2: FAR tier - only check cells that have registered objects ===
	# Instead of iterating 7500+ cells, we only check cells in _objects_by_cell
	var far_cells: Array[Dictionary] = []

	if distant_rendering_enabled:
		# Refresh cached keys only when dirty (object registered/unregistered)
		if _objects_by_cell_keys_dirty:
			_objects_by_cell_keys_cache = _objects_by_cell.keys()
			_objects_by_cell_keys_dirty = false

		for cell: Vector2i in _objects_by_cell_keys_cache:
			var distance_sq: float
			if use_position_distance:
				distance_sq = position_to_cell_distance_squared(cell)
			else:
				distance_sq = _cell_distance_squared(camera_cell, cell)

			# Only FAR tier (between MID and FAR thresholds)
			if distance_sq >= mid_end_sq and distance_sq < far_end_sq:
				far_cells.append({
					"cell": cell,
					"distance_sq": distance_sq,
					"tier": Tier.FAR
				})

	# === PART 3: Sort and distribute ===
	# Sort NEAR+MID by distance
	near_mid_cells.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.distance_sq < b.distance_sq)

	# Sort FAR by distance separately
	far_cells.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.distance_sq < b.distance_sq)

	# Distribute NEAR and MID
	var near_count := 0
	var mid_count := 0
	var max_near: int = max_cells_per_tier.get(Tier.NEAR, 0)
	var max_mid: int = max_cells_per_tier.get(Tier.MID, 0)

	for entry: Dictionary in near_mid_cells:
		var tier: int = entry.tier
		if tier == Tier.NEAR and near_count < max_near:
			(result[Tier.NEAR] as Array).append(entry.cell)
			near_count += 1
		elif tier == Tier.MID and mid_count < max_mid:
			(result[Tier.MID] as Array).append(entry.cell)
			mid_count += 1

	# Distribute FAR (already sorted by distance)
	var far_count := 0
	var max_far: int = max_cells_per_tier.get(Tier.FAR, 0)

	for entry: Dictionary in far_cells:
		if far_count < max_far:
			(result[Tier.FAR] as Array).append(entry.cell)
			far_count += 1
		else:
			break  # Already sorted, so rest are farther

	# Cache the result for future calls with same camera cell
	_cached_visible_cells_by_tier = result.duplicate(true)
	return result


## Check if a cell is within the camera's view frustum
## Uses a simple AABB check against the frustum planes
## Algorithm: For each plane, find the p-vertex (corner most aligned with plane normal).
## If the p-vertex is behind the plane, the entire AABB is outside the frustum.
func _is_cell_in_frustum(cell: Vector2i) -> bool:
	if not camera:
		return true  # No camera = assume visible

	# Calculate cell origin in world coordinates (min corner, not center)
	# This matches quadtree_chunk_manager.gd:get_chunk_aabb() which works correctly
	var origin_x := cell.x * cell_size_meters
	var origin_z := -cell.y * cell_size_meters  # Z is flipped in Godot

	# Create cell AABB with very generous height bounds to avoid over-culling
	# Use -500 to +1000 (1500m total) to cover:
	# - Deep underwater areas and caves (-500m)
	# - Terrain at any elevation
	# - Tall buildings, mountains, and structures (+1000m)
	# Using generous bounds is better than incorrectly culling visible cells
	var cell_aabb := AABB(
		Vector3(origin_x, -500.0, origin_z - cell_size_meters),  # Min corner
		Vector3(cell_size_meters, 1500.0, cell_size_meters)       # Size
	)

	# Check against camera frustum
	# Godot's frustum planes point inward - positive distance = inside frustum
	var frustum := camera.get_frustum()
	for plane in frustum:
		# Find the p-vertex: the corner most in the direction of the plane normal
		# If this corner is behind the plane, the entire AABB is outside
		var corner := cell_aabb.position
		if plane.normal.x >= 0:
			corner.x += cell_aabb.size.x
		if plane.normal.y >= 0:
			corner.y += cell_aabb.size.y
		if plane.normal.z >= 0:
			corner.z += cell_aabb.size.z

		if plane.distance_to(corner) < 0:
			return false  # AABB is completely outside this plane

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
## 2. Object-level visibility (which objects are in which tier) - GPU accelerated when available
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
		"gpu_accelerated": false,
	}

	# OPTIMIZATION: Early exit if no registered objects - saves time when world is empty
	if _registered_objects.is_empty():
		return stats

	# 1. Update cell-level visibility (uses existing optimized implementation)
	# NOTE: get_visible_cells_by_tier already caches the result internally
	var visible_cells_by_tier := get_visible_cells_by_tier(camera_cell)

	for tier in visible_cells_by_tier:
		var cells_array: Array = visible_cells_by_tier[tier]
		stats.cells_per_tier[tier] = cells_array.size()

	# 2. Update object-level visibility
	# Choose update path based on Phase 2 mode and GPU availability
	if phase2_gpu_driven_enabled:
		# PHASE 2 MODE: GPUVisibilityRenderer handles MID/FAR tiers
		# We only need to track NEAR tier for CPU instantiation decisions
		stats = _update_visibility_near_only(stats, visible_cells_by_tier)
		stats["phase2_active"] = true
	elif _should_use_gpu_compute():
		stats = _update_visibility_gpu(stats, visible_cells_by_tier)
		stats["gpu_accelerated"] = true
	else:
		stats = _update_visibility_cpu(stats, visible_cells_by_tier)

	return stats


## Track frame count for periodic GPU stats logging
var _gpu_log_frame_count: int = 0

## GPU-accelerated visibility update using compute shader
## Processes all objects in parallel on GPU, then reads back tier changes
## Uses SPARSE READBACK: O(changes) instead of O(all_objects) for industry-standard perf
func _update_visibility_gpu(stats: Dictionary, _visible_cells_by_tier: Dictionary) -> Dictionary:
	# Dispatch GPU compute shader and get tier changes
	var gpu_changes: Array[Dictionary] = _gpu_visibility_manager.update_visibility(_camera_position)

	# Log GPU stats periodically (every 300 frames ~5 seconds at 60fps)
	_gpu_log_frame_count += 1
	if _gpu_log_frame_count == 1 or _gpu_log_frame_count % 300 == 0:
		var gpu_stats: Dictionary = _gpu_visibility_manager.get_stats()
		var sparse_changes: int = gpu_stats.get("sparse_readback_changes", -1)
		var sparse_saved: int = gpu_stats.get("sparse_readback_saved_bytes", 0)

		# Show sparse readback stats if available
		if sparse_changes >= 0:
			print("[DistanceTierManager] GPU SPARSE: %d obj, %d changes, saved %dKB, dispatch: %.2f ms, readback: %.2f ms, total: %.2f ms" % [
				gpu_stats.get("objects_registered", 0),
				sparse_changes,
				sparse_saved / 1024,
				gpu_stats.get("last_dispatch_time_us", 0) / 1000.0,
				gpu_stats.get("last_readback_time_us", 0) / 1000.0,
				gpu_stats.get("last_total_time_us", 0) / 1000.0,
			])
		else:
			print("[DistanceTierManager] GPU: %d obj, upload: %.2f ms, dispatch: %.2f ms, readback: %.2f ms, total: %.2f ms" % [
				gpu_stats.get("objects_registered", 0),
				gpu_stats.get("last_upload_time_us", 0) / 1000.0,
				gpu_stats.get("last_dispatch_time_us", 0) / 1000.0,
				gpu_stats.get("last_readback_time_us", 0) / 1000.0,
				gpu_stats.get("last_total_time_us", 0) / 1000.0,
			])

	# Process tier changes and update local state
	for change in gpu_changes:
		var obj_id: int = change["object_id"]
		var old_tier: int = change["old_tier"]
		var new_tier: int = change["new_tier"]

		if obj_id not in _registered_objects:
			continue

		var obj: ObjectVisibilityInfo = _registered_objects[obj_id]

		# Update local state
		obj.current_tier = new_tier as Tier
		_object_tier_map[obj_id] = new_tier as Tier

		# Calculate distance for the change event
		var dx: float = _camera_position.x - obj.position.x
		var dy: float = _camera_position.y - obj.position.y
		var dz: float = _camera_position.z - obj.position.z
		var distance: float = sqrt(dx * dx + dy * dy + dz * dz)
		obj.last_distance = distance
		obj.last_update_frame = _visibility_update_frame

		_tier_changes_this_frame.append({
			"object_id": obj_id,
			"old_tier": old_tier,
			"new_tier": new_tier,
			"distance": distance,
		})

		stats.objects_changed_tier += 1

	# Get tier lists in bulk from GPU manager (single loop instead of N lookups)
	var tier_lists: Dictionary = _gpu_visibility_manager.get_objects_by_tier()

	# Update tier arrays directly
	_visible_objects_by_tier[Tier.NEAR] = tier_lists.get(Tier.NEAR, [])
	_visible_objects_by_tier[Tier.MID] = tier_lists.get(Tier.MID, [])
	_visible_objects_by_tier[Tier.FAR] = tier_lists.get(Tier.FAR, [])

	# Update stats
	stats.objects_checked = _registered_objects.size()
	stats.objects_per_tier[Tier.NEAR] = (_visible_objects_by_tier[Tier.NEAR] as Array).size()
	stats.objects_per_tier[Tier.MID] = (_visible_objects_by_tier[Tier.MID] as Array).size()
	stats.objects_per_tier[Tier.FAR] = (_visible_objects_by_tier[Tier.FAR] as Array).size()

	return stats


## Pre-compute squared hysteresis thresholds for visibility calculations
## Called once per frame before the hot loop to avoid repeated dictionary lookups
## Returns: Dictionary with near_exit_sq, near_enter_sq, mid_exit_sq, mid_enter_sq, far_end_sq
func _precompute_hysteresis_thresholds() -> Dictionary:
	var near_end: float = tier_end_distances[Tier.NEAR]
	var mid_end: float = tier_end_distances[Tier.MID]
	var far_end: float = tier_end_distances[Tier.FAR]
	var near_hyst: float = tier_hysteresis.get(Tier.NEAR, 40.0)
	var mid_hyst: float = tier_hysteresis.get(Tier.MID, 60.0)
	return {
		"near_end_sq": near_end * near_end,
		"mid_end_sq": mid_end * mid_end,
		"far_end_sq": far_end * far_end,
		"near_exit_sq": (near_end + near_hyst) * (near_end + near_hyst),
		"near_enter_sq": (near_end - near_hyst) * (near_end - near_hyst),
		"mid_exit_sq": (mid_end + mid_hyst) * (mid_end + mid_hyst),
		"mid_enter_sq": (mid_end - mid_hyst) * (mid_end - mid_hyst),
	}


## CPU-based visibility update (original implementation)
## Used when GPU compute is not available or object count is below threshold
func _update_visibility_cpu(stats: Dictionary, visible_cells_by_tier: Dictionary) -> Dictionary:
	# Pre-compute squared tier thresholds ONCE (avoid dictionary lookups in hot loop)
	var thresholds := _precompute_hysteresis_thresholds()
	var near_end_sq: float = thresholds.near_end_sq
	var mid_end_sq: float = thresholds.mid_end_sq
	var far_end_sq: float = thresholds.far_end_sq
	var near_exit_sq: float = thresholds.near_exit_sq
	var near_enter_sq: float = thresholds.near_enter_sq
	var mid_exit_sq: float = thresholds.mid_exit_sq
	var mid_enter_sq: float = thresholds.mid_enter_sq

	# OPTIMIZATION: Cache camera position locally to avoid property access in loop
	var cam_x: float = _camera_position.x
	var cam_y: float = _camera_position.y
	var cam_z: float = _camera_position.z

	# Collect cells that need checking:
	# **OPTIMIZATION**: Only check NEAR and MID tier cells for per-object visibility
	# FAR tier objects use chunk-based rendering (ImpostorManager) - no per-object tracking needed
	var cells_to_check: Array[Vector2i] = []

	# Only add NEAR and MID tier cells (skip FAR and HORIZON)
	var near_cells: Array = visible_cells_by_tier.get(Tier.NEAR, [])
	for cell in near_cells:
		cells_to_check.append(cell)

	var mid_cells: Array = visible_cells_by_tier.get(Tier.MID, [])
	for cell in mid_cells:
		cells_to_check.append(cell)

	# OPTIMIZATION: Pre-allocate result arrays to avoid array growth overhead
	var near_objects: Array[int] = []
	var mid_objects: Array[int] = []
	var far_objects: Array[int] = []

	# Check objects only in relevant cells
	for cell_grid: Vector2i in cells_to_check:
		if cell_grid not in _objects_by_cell:
			continue

		var cell_objects: Array = _objects_by_cell[cell_grid]
		for obj_id: int in cell_objects:
			if obj_id not in _registered_objects:
				continue

			var obj: ObjectVisibilityInfo = _registered_objects[obj_id]
			stats.objects_checked += 1

			# OPTIMIZATION: Inline distance calculation (avoid function call overhead)
			var dx: float = cam_x - obj.position.x
			var dy: float = cam_y - obj.position.y
			var dz: float = cam_z - obj.position.z
			var distance_sq: float = dx * dx + dy * dy + dz * dz

			# PER-OBJECT HYSTERESIS: Use object's current tier to determine threshold
			# This prevents tier thrashing for individual objects
			var old_tier: Tier = obj.current_tier
			var new_tier: Tier

			# Apply hysteresis based on current tier
			match old_tier:
				Tier.NEAR:
					# Currently NEAR - need to exceed exit threshold to leave
					if distance_sq < near_exit_sq:
						new_tier = Tier.NEAR
					elif distance_sq < mid_exit_sq:
						new_tier = Tier.MID
					elif distance_sq < far_end_sq:
						new_tier = Tier.FAR
					else:
						new_tier = Tier.NONE
				Tier.MID:
					# Currently MID - use entry threshold for NEAR, exit for FAR
					if distance_sq < near_enter_sq:
						new_tier = Tier.NEAR
					elif distance_sq < mid_exit_sq:
						new_tier = Tier.MID
					elif distance_sq < far_end_sq:
						new_tier = Tier.FAR
					else:
						new_tier = Tier.NONE
				Tier.FAR:
					# Currently FAR - use entry thresholds for closer tiers
					if distance_sq < near_enter_sq:
						new_tier = Tier.NEAR
					elif distance_sq < mid_enter_sq:
						new_tier = Tier.MID
					elif distance_sq < far_end_sq:
						new_tier = Tier.FAR
					else:
						new_tier = Tier.NONE
				_:
					# No previous tier or NONE - use standard thresholds
					if distance_sq < near_end_sq:
						new_tier = Tier.NEAR
					elif distance_sq < mid_end_sq:
						new_tier = Tier.MID
					elif distance_sq < far_end_sq:
						new_tier = Tier.FAR
					else:
						new_tier = Tier.NONE

			# Add to correct tier array AFTER hysteresis is applied
			match new_tier:
				Tier.NEAR:
					near_objects.append(obj_id)
				Tier.MID:
					mid_objects.append(obj_id)
				Tier.FAR:
					far_objects.append(obj_id)

			# Emit tier change event if actually changed
			if new_tier != old_tier:
				obj.current_tier = new_tier
				obj.last_distance = sqrt(distance_sq)
				_object_tier_map[obj_id] = new_tier

				_tier_changes_this_frame.append({
					"object_id": obj_id,
					"old_tier": old_tier,
					"new_tier": new_tier,
					"distance": obj.last_distance,
				})

				stats.objects_changed_tier += 1

			obj.last_update_frame = _visibility_update_frame

	# OPTIMIZATION: Assign arrays directly instead of rebuilding with appends
	_visible_objects_by_tier[Tier.NEAR] = near_objects
	_visible_objects_by_tier[Tier.MID] = mid_objects
	_visible_objects_by_tier[Tier.FAR] = far_objects

	# Update stats
	stats.objects_per_tier[Tier.NEAR] = near_objects.size()
	stats.objects_per_tier[Tier.MID] = mid_objects.size()
	stats.objects_per_tier[Tier.FAR] = far_objects.size()

	return stats


## PHASE 2 MODE: Near-only visibility update
## When GPUVisibilityRenderer handles MID/FAR, we only need to track NEAR tier
## for CPU Node3D instantiation decisions. This is O(near_cells) instead of O(all_objects).
##
## MID/FAR tier visibility is handled entirely by GPUVisibilityRenderer's compute shader.
func _update_visibility_near_only(stats: Dictionary, visible_cells_by_tier: Dictionary) -> Dictionary:
	# Reuse the shared threshold pre-computation (only uses near_exit_sq and near_enter_sq)
	var thresholds := _precompute_hysteresis_thresholds()
	var near_exit_sq: float = thresholds.near_exit_sq
	var near_enter_sq: float = thresholds.near_enter_sq

	# Cache camera position
	var cam_x: float = _camera_position.x
	var cam_y: float = _camera_position.y
	var cam_z: float = _camera_position.z

	# Only check cells that could contain NEAR objects
	# Use NEAR + MID cells since objects could transition between them
	var cells_to_check: Array[Vector2i] = []

	var near_cells: Array = visible_cells_by_tier.get(Tier.NEAR, [])
	for cell in near_cells:
		cells_to_check.append(cell)

	# Also check MID cells adjacent to NEAR (objects might transition in)
	var mid_cells: Array = visible_cells_by_tier.get(Tier.MID, [])
	for cell in mid_cells:
		cells_to_check.append(cell)

	var near_objects: Array[int] = []

	# Check objects only for NEAR tier transitions
	for cell_grid: Vector2i in cells_to_check:
		if cell_grid not in _objects_by_cell:
			continue

		var cell_objects: Array = _objects_by_cell[cell_grid]
		for obj_id: int in cell_objects:
			if obj_id not in _registered_objects:
				continue

			var obj: ObjectVisibilityInfo = _registered_objects[obj_id]
			stats.objects_checked += 1

			# Inline distance calculation
			var dx: float = cam_x - obj.position.x
			var dy: float = cam_y - obj.position.y
			var dz: float = cam_z - obj.position.z
			var distance_sq: float = dx * dx + dy * dy + dz * dz

			var old_tier: Tier = obj.current_tier
			var is_near: bool = false

			# Determine if object should be in NEAR tier (with hysteresis)
			if old_tier == Tier.NEAR:
				# Currently NEAR - need to exceed exit threshold to leave
				is_near = distance_sq < near_exit_sq
			else:
				# Not NEAR - need to be within entry threshold to enter
				is_near = distance_sq < near_enter_sq

			# For Phase 2, we only track NEAR vs NOT_NEAR
			# GPUVisibilityRenderer handles MID/FAR distinction
			var new_tier: Tier = Tier.NEAR if is_near else Tier.MID  # MID = "not near"

			# Track NEAR tier changes
			if new_tier != old_tier:
				obj.current_tier = new_tier
				obj.last_distance = sqrt(distance_sq)
				obj.last_update_frame = _visibility_update_frame
				_object_tier_map[obj_id] = new_tier
				stats.objects_changed_tier += 1

				_tier_changes_this_frame.append({
					"object_id": obj_id,
					"old_tier": old_tier,
					"new_tier": new_tier,
					"distance": obj.last_distance,
				})

			if is_near:
				near_objects.append(obj_id)

	# Update NEAR tier list (MID/FAR handled by GPUVisibilityRenderer)
	_visible_objects_by_tier[Tier.NEAR] = near_objects
	stats.objects_per_tier[Tier.NEAR] = near_objects.size()

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

	# Add to spatial index
	if cell_grid not in _objects_by_cell:
		_objects_by_cell[cell_grid] = []
		_objects_by_cell_keys_dirty = true  # New cell added
	(_objects_by_cell[cell_grid] as Array).append(object_id)

	# Sync to GPU visibility manager if enabled
	if _gpu_visibility_manager and _gpu_compute_available:
		_gpu_visibility_manager.register_object(object_id, position)

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
	var cell_grid: Vector2i = obj_info.cell_grid

	# Remove from tier list
	if tier in _visible_objects_by_tier:
		var tier_list: Array = _visible_objects_by_tier[tier]
		var idx := tier_list.find(object_id)
		if idx >= 0:
			tier_list.remove_at(idx)

	# Remove from spatial index
	if cell_grid in _objects_by_cell:
		var cell_list: Array = _objects_by_cell[cell_grid]
		var cell_idx := cell_list.find(object_id)
		if cell_idx >= 0:
			cell_list.remove_at(cell_idx)
		# Clean up empty cells
		if cell_list.is_empty():
			_objects_by_cell.erase(cell_grid)
			_objects_by_cell_keys_dirty = true  # Cell removed

	_registered_objects.erase(object_id)
	_object_tier_map.erase(object_id)

	# Sync to GPU visibility manager if enabled
	if _gpu_visibility_manager and _gpu_compute_available:
		_gpu_visibility_manager.unregister_object(object_id)

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

	# Sync to GPU visibility manager if enabled
	if _gpu_visibility_manager and _gpu_compute_available:
		_gpu_visibility_manager.update_object_position(object_id, new_position)

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
	_objects_by_cell.clear()  # Clear spatial index
	_objects_by_cell_keys_cache.clear()
	_objects_by_cell_keys_dirty = true
	for tier in _visible_objects_by_tier:
		(_visible_objects_by_tier[tier] as Array).clear()
	_tier_changes_this_frame.clear()

	# Clear GPU visibility manager if enabled
	if _gpu_visibility_manager and _gpu_compute_available:
		_gpu_visibility_manager.clear()

	# Reset GPU sync flag so objects get re-synced after next load
	_gpu_objects_synced = false


## **OPTIMIZATION**: Get cached visible cells from last update_visibility() call
## This avoids expensive recalculation - ImpostorManager and other consumers should use this
## Returns: Dictionary mapping Tier -> Array[Vector2i] (empty if update_visibility not called yet)
func get_cached_visible_cells_by_tier() -> Dictionary:
	return _cached_visible_cells_by_tier


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


## Get statistics for debugging
func get_stats() -> Dictionary:
	var near_cells := 0
	var mid_cells := 0
	var far_cells := 0

	for cell_grid: Vector2i in _cell_tiers:
		var tier: int = _cell_tiers[cell_grid]
		match tier:
			Tier.NEAR: near_cells += 1
			Tier.MID: mid_cells += 1
			Tier.FAR: far_cells += 1

	return {
		"registered_objects": _registered_objects.size(),
		"near_cells": near_cells,
		"mid_cells": mid_cells,
		"far_cells": far_cells,
		"total_cells": _cell_tiers.size(),
	}


#endregion
