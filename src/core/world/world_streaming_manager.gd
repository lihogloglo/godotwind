## WorldStreamingManager - Cell/Object streaming coordinator
##
## **SIMPLIFIED ARCHITECTURE** - This now handles ONLY cell/object streaming.
## For terrain, use GenericTerrainStreamer separately.
##
## This follows the simplification-cascades principle: "Terrain and objects
## are separate concerns" - they should be independent streaming systems.
##
## Architecture:
##   WorldStreamingManager (objects only)
##   ├── OpenWorldDatabase (handles object streaming via OWDB addon)
##   │   └── [Cell nodes parented here for automatic streaming]
##   ├── OWDBPosition (tracks camera position for streaming)
##   ├── DistanceTierManager (determines NEAR/MID/FAR/HORIZON tiers)
##   ├── DistantStaticRenderer (merged meshes for MID tier, 500m-2km)
##   └── ImpostorManager (impostors for FAR tier, 2km-5km)
##
## For terrain streaming, use:
##   GenericTerrainStreamer (terrain only)
##   ├── Works with any WorldDataProvider (Morrowind, LaPalma, etc.)
##   └── Handles Terrain3D population and streaming
##
## Reference: Simplification-cascades refactoring - Phase 1
## Extended: Distant rendering system (Phases 1-3)
class_name WorldStreamingManager
extends Node3D

# Preload dependencies
const CS := preload("res://src/core/coordinate_system.gd")
const DistanceTierManagerScript := preload("res://src/core/world/distance_tier_manager.gd")

## Emitted when a cell starts loading
signal cell_loading(grid: Vector2i)

## Emitted when a cell finishes loading
signal cell_loaded(grid: Vector2i, node: Node3D)

## Emitted when a cell is unloaded
signal cell_unloaded(grid: Vector2i)

#region Configuration

## View distance in cells (radius around camera) - NEAR tier only
## Extended tiers (MID/FAR/HORIZON) are managed by DistanceTierManager
@export var view_distance_cells: int = 3

## Whether to load objects (can disable for terrain-only view)
@export var load_objects: bool = true

## Enable distant rendering (MID/FAR/HORIZON tiers beyond NEAR)
## When disabled, only NEAR tier is used (original behavior ~351m)
##
## This is now safe to enable - the system has:
## - Hard cell limits per tier (NEAR=50, MID=100, FAR=200)
## - View frustum culling for distant tiers
## - Pre-baked asset loading (graceful fallback if assets missing)
##
## NOTE: Distant content won't appear until you run the prebaking tools:
## - mesh_prebaker.gd for MID tier (merged meshes)
## - impostor_baker.gd for FAR tier (impostors)
@export var distant_rendering_enabled: bool = false

## NOTE: Terrain streaming removed - use GenericTerrainStreamer separately
## This manager now focuses ONLY on cell/object streaming

## OWDB chunk sizes optimized for Morrowind object scales (in Godot units)
## Small: candles, cups, books (~8 units)
## Medium: furniture, doors, containers (~16 units)
## Large: trees, large rocks, buildings (~64 units)
@export var owdb_chunk_sizes: Array[float] = [8.0, 16.0, 64.0]

## OWDB chunk load range (chunks around each position)
@export var owdb_chunk_load_range: int = 3

## OWDB batch processing time limit (ms per frame)
@export var owdb_batch_time_limit_ms: float = 5.0

## Enable debug output
@export var debug_enabled: bool = false

## Time budget for cell loading per frame (ms)
## This is for submitting async requests, should be low as actual parsing is async
@export var cell_load_budget_ms: float = 2.0

## Maximum cells to queue for loading (NEAR tier uses queue, other tiers should NOT use queue)
## If distant_rendering_enabled, this needs to be much larger, but that's experimental
@export var max_load_queue_size: int = 128

## Enable async/time-budgeted cell loading
@export var async_loading_enabled: bool = true

## Maximum cell async requests to submit per frame
## Industry standard: 1-2 per frame to avoid I/O saturation and queue flooding
@export var max_cell_submits_per_frame: int = 2

## Enable occlusion culling (don't render objects behind other objects)
## Significant performance boost in dense cities and interiors
@export var occlusion_culling_enabled: bool = true

#endregion

#region Node References

## Reference to OpenWorldDatabase node (created automatically)
var owdb: Node = null  # OpenWorldDatabase type

## Reference to OWDBPosition node (tracks streaming position)
var owdb_position: Node3D = null  # OWDBPosition type

## Reference to CellManager for loading cell data
var cell_manager: RefCounted = null  # CellManager

## Reference to BackgroundProcessor for async operations
var background_processor: Node = null  # BackgroundProcessor

## Static object renderer for fast flora rendering
var static_renderer: Node3D = null  # StaticObjectRenderer

## Distance tier manager for multi-tier rendering
var tier_manager: RefCounted = null  # DistanceTierManager

## Distant static renderer for MID tier (merged meshes, 500m-2km)
var distant_renderer: Node3D = null  # DistantStaticRenderer

## Impostor manager for FAR tier (impostors, 2km-5km)
var impostor_manager: Node = null  # ImpostorManager

#endregion

#region State

## Currently tracked camera/player node
var _tracked_node: Node3D = null

## Currently loaded exterior cells: Vector2i -> Node3D
var _loaded_cells: Dictionary = {}

## Cells currently being loaded (async)
var _loading_cells: Dictionary = {}

## Async request tracking: request_id -> Vector2i grid
var _async_cell_requests: Dictionary = {}

## Last known camera cell position
var _last_camera_cell: Vector2i = Vector2i(999999, 999999)

## Whether the system is initialized
var _initialized: bool = false

## Priority queue for cells to load (sorted by distance to camera)
## Each entry: { "grid": Vector2i, "priority": float (lower = higher priority), "tier": Tier }
var _load_queue: Array = []

## Loaded cells by tier: Tier -> Dictionary[Vector2i -> variant]
## NEAR tier stores Node3D, MID/FAR tiers store RID or instance data
var _loaded_cells_by_tier: Dictionary = {}

## Cells being loaded by tier: Tier -> Dictionary[Vector2i -> true]
var _loading_cells_by_tier: Dictionary = {}

## Performance stats
var _stats_load_time_ms: float = 0.0
var _stats_cells_loaded_this_frame: int = 0
var _stats_queue_high_water_mark: int = 0

## Stats per tier
var _stats_cells_per_tier: Dictionary = {}

## Throttle for "queue full" debug messages (don't spam the log)
var _queue_full_message_count: int = 0
var _queue_full_message_throttle: int = 100  # Only print every N dropped cells

#endregion


func _ready() -> void:
	# Note: OWDB setup is deferred - call initialize() after setting properties
	_debug("WorldStreamingManager ready - call initialize() to start streaming")


## Initialize the streaming system after configuration
## Must be called after setting cell_manager and other properties
func initialize() -> void:
	if _initialized:
		return
	_setup_owdb()
	_setup_static_renderer()
	_setup_tier_manager()
	_setup_distant_renderers()
	_setup_occlusion_culling()
	_initialized = true
	_debug("WorldStreamingManager initialized (distant rendering: %s)" % ("enabled" if distant_rendering_enabled else "disabled"))


## Time budget for async object instantiation per frame (ms)
## This is the main bottleneck - Node3D.duplicate() is expensive
## Priority over terrain to show objects quickly
@export var instantiation_budget_ms: float = 3.0

func _process(_delta: float) -> void:
	if not _initialized:
		return

	if not _tracked_node:
		return

	# Check if camera moved to a new cell
	var current_cell := _get_cell_from_godot_position(_tracked_node.global_position)
	if current_cell != _last_camera_cell:
		_last_camera_cell = current_cell
		_on_camera_cell_changed(current_cell)

	# Poll for completed async cell requests
	_poll_async_completions()

	# Process async object instantiation with time budget
	# This is CRITICAL - without this, objects parsed in background never get created!
	if cell_manager and cell_manager.has_method("process_async_instantiation"):
		cell_manager.process_async_instantiation(instantiation_budget_ms)

	# Process object load queue with time budget
	if async_loading_enabled and not _load_queue.is_empty():
		_process_load_queue()


#region Public API

## Set the node to track for streaming (usually player or camera)
func set_tracked_node(node: Node3D) -> void:
	_tracked_node = node
	_debug("Tracking node: %s" % node.name if node else "null")

	# Update OWDB position tracker
	if owdb_position and node:
		# Parent OWDBPosition to tracked node so it follows automatically
		if owdb_position.get_parent() != node:
			owdb_position.reparent(node)
		owdb_position.position = Vector3.ZERO

	# Set up camera reference for frustum culling
	if tier_manager and node:
		var camera: Camera3D = null
		if node is Camera3D:
			camera = node
		elif node.has_method("get_camera_3d"):
			camera = node.get_camera_3d()
		else:
			# Try to find camera in viewport
			camera = get_viewport().get_camera_3d()

		if camera:
			tier_manager.set_camera(camera)
			_debug("Camera set for frustum culling: %s" % camera.name)

	# Force immediate update
	if node:
		var cell := _get_cell_from_godot_position(node.global_position)
		_last_camera_cell = cell
		_on_camera_cell_changed(cell)


## Get the currently tracked node
func get_tracked_node() -> Node3D:
	return _tracked_node


## Load a specific exterior cell (can be called manually)
func load_cell(grid_x: int, grid_y: int) -> Node3D:
	var grid := Vector2i(grid_x, grid_y)

	# Already loaded?
	if grid in _loaded_cells:
		return _loaded_cells[grid]

	# Already loading?
	if grid in _loading_cells:
		return null

	return _load_cell_internal(grid)


## Unload a specific cell
func unload_cell(grid_x: int, grid_y: int) -> void:
	var grid := Vector2i(grid_x, grid_y)
	_unload_cell_internal(grid)


## Get a loaded cell by grid coordinates
func get_loaded_cell(grid_x: int, grid_y: int) -> Node3D:
	return _loaded_cells.get(Vector2i(grid_x, grid_y))


## Get all currently loaded cell coordinates
func get_loaded_cell_coordinates() -> Array[Vector2i]:
	var coords: Array[Vector2i] = []
	for key in _loaded_cells.keys():
		coords.append(key)
	return coords


## Force reload all cells around current position
func refresh_cells() -> void:
	if _tracked_node:
		var cell := _get_cell_from_godot_position(_tracked_node.global_position)
		_on_camera_cell_changed(cell)


## Force load all visible cells synchronously (bypasses async queue)
## Use this when toggling objects on to ensure immediate loading
func force_load_visible_cells() -> void:
	if not _tracked_node or not cell_manager:
		return

	var camera_cell := _get_cell_from_godot_position(_tracked_node.global_position)
	var visible_cells := _get_visible_cells(camera_cell)

	_debug("Force loading %d visible cells around %s" % [visible_cells.size(), camera_cell])

	for cell_grid in visible_cells:
		if cell_grid not in _loaded_cells:
			# Remove from loading/queue state if present
			_loading_cells.erase(cell_grid)
			_load_queue = _load_queue.filter(func(entry): return entry.grid != cell_grid)

			# Load synchronously
			_load_cell_internal(cell_grid)


## Set the CellManager instance to use
func set_cell_manager(manager: RefCounted) -> void:
	cell_manager = manager
	_debug("CellManager set")


## Set the BackgroundProcessor for async loading
func set_background_processor(processor: Node) -> void:
	background_processor = processor
	_debug("BackgroundProcessor set")


## Get statistics about loaded content
func get_stats() -> Dictionary:
	var stats := {
		"loaded_cells": _loaded_cells.size(),
		"loading_cells": _loading_cells.size(),
		"tracked_node": _tracked_node.name if _tracked_node else "none",
		"camera_cell": _last_camera_cell,
		"view_distance": view_distance_cells,
		"load_queue_size": _load_queue.size(),
		"load_time_ms": _stats_load_time_ms,
		"cells_loaded_this_frame": _stats_cells_loaded_this_frame,
		"queue_high_water_mark": _stats_queue_high_water_mark,
		"async_pending": _async_cell_requests.size(),
		"distant_rendering_enabled": distant_rendering_enabled,
	}

	# Add tier-specific stats if distant rendering is enabled
	if distant_rendering_enabled and tier_manager:
		stats["cells_by_tier"] = {
			"NEAR": _loaded_cells_by_tier.get(DistanceTierManagerScript.Tier.NEAR, {}).size(),
			"MID": _loaded_cells_by_tier.get(DistanceTierManagerScript.Tier.MID, {}).size(),
			"FAR": _loaded_cells_by_tier.get(DistanceTierManagerScript.Tier.FAR, {}).size(),
			"HORIZON": _loaded_cells_by_tier.get(DistanceTierManagerScript.Tier.HORIZON, {}).size(),
		}
		stats["tier_distances"] = tier_manager.get_debug_info()

	if owdb and owdb.has_method("get_currently_loaded_nodes"):
		stats["owdb_loaded_nodes"] = owdb.get_currently_loaded_nodes()
		stats["owdb_total_nodes"] = owdb.get_total_database_nodes()

	# Add cell manager async stats if available
	if cell_manager and cell_manager.has_method("get_instantiation_queue_size"):
		stats["instantiation_queue"] = cell_manager.get_instantiation_queue_size()

	return stats


## Preload common models to reduce initial loading delays
## Call this after initialize() but before the player starts moving
## sync: If true, blocks until complete. If false, loads in background.
func preload_common_models(sync: bool = false) -> void:
	if not cell_manager:
		push_warning("WorldStreamingManager: No CellManager set - cannot preload models")
		return

	if sync:
		cell_manager.preload_common_models()
	else:
		if cell_manager.has_method("preload_common_models_async"):
			cell_manager.preload_common_models_async()
		else:
			cell_manager.preload_common_models()

#endregion


#region Internal Setup

## Set up OpenWorldDatabase for object streaming
func _setup_owdb() -> void:
	# Check if OWDB addon is available
	var owdb_class = load("res://addons/open-world-database/src/open_world_database.gd")
	if not owdb_class:
		push_warning("WorldStreamingManager: OWDB addon not found - object streaming disabled")
		return

	# Create OWDB node
	owdb = Node.new()
	owdb.set_script(owdb_class)
	owdb.name = "OpenWorldDatabase"

	# Configure OWDB for Morrowind object scales
	owdb.chunk_sizes = owdb_chunk_sizes
	owdb.chunk_load_range = owdb_chunk_load_range
	owdb.batch_time_limit_ms = owdb_batch_time_limit_ms
	owdb.batch_processing_enabled = true
	owdb.debug_enabled = debug_enabled

	add_child(owdb)
	_debug("OWDB created and configured")

	# Create OWDBPosition for tracking camera
	var position_class = load("res://addons/open-world-database/src/OWDBPosition.gd")
	if position_class:
		owdb_position = Node3D.new()
		owdb_position.set_script(position_class)
		owdb_position.name = "StreamingPosition"
		add_child(owdb_position)
		_debug("OWDBPosition created")


## Set up StaticObjectRenderer for fast flora rendering
func _setup_static_renderer() -> void:
	var renderer_class = load("res://src/core/world/static_object_renderer.gd")
	if not renderer_class:
		push_warning("WorldStreamingManager: StaticObjectRenderer not found - flora will use Node3D (slower)")
		return

	static_renderer = Node3D.new()
	static_renderer.set_script(renderer_class)
	static_renderer.name = "StaticObjectRenderer"
	add_child(static_renderer)


## Enable occlusion culling for massive performance boost in cities/interiors
func _setup_occlusion_culling() -> void:
	if not occlusion_culling_enabled:
		return

	# Enable occlusion culling on the viewport
	var viewport := get_viewport()
	if viewport:
		# Use RenderingServer to enable occlusion culling globally
		RenderingServer.viewport_set_use_occlusion_culling(viewport.get_viewport_rid(), true)
		_debug("Occlusion culling enabled - objects behind other objects won't render")
	else:
		push_warning("WorldStreamingManager: No viewport found, occlusion culling not enabled")

	# Connect to cell_manager
	if cell_manager and cell_manager.has_method("set_static_renderer"):
		cell_manager.set_static_renderer(static_renderer)
		_debug("StaticObjectRenderer created and connected to CellManager")
	else:
		_debug("StaticObjectRenderer created (CellManager not available)")


## Set up DistanceTierManager for multi-tier rendering
func _setup_tier_manager() -> void:
	tier_manager = DistanceTierManagerScript.new()
	tier_manager.distant_rendering_enabled = distant_rendering_enabled

	# Initialize tier tracking dictionaries
	for tier in [
		DistanceTierManagerScript.Tier.NEAR,
		DistanceTierManagerScript.Tier.MID,
		DistanceTierManagerScript.Tier.FAR,
		DistanceTierManagerScript.Tier.HORIZON,
	]:
		_loaded_cells_by_tier[tier] = {}
		_loading_cells_by_tier[tier] = {}
		_stats_cells_per_tier[tier] = 0

	_debug("DistanceTierManager created with hard cell limits: NEAR=%d, MID=%d, FAR=%d" % [
		DistanceTierManagerScript.MAX_CELLS_PER_TIER[DistanceTierManagerScript.Tier.NEAR],
		DistanceTierManagerScript.MAX_CELLS_PER_TIER[DistanceTierManagerScript.Tier.MID],
		DistanceTierManagerScript.MAX_CELLS_PER_TIER[DistanceTierManagerScript.Tier.FAR],
	])


## Set up distant renderers for MID/FAR tiers
func _setup_distant_renderers() -> void:
	if not distant_rendering_enabled:
		_debug("Distant rendering disabled - skipping distant renderer setup")
		return

	# Try to load DistantStaticRenderer for MID tier
	var distant_renderer_class = load("res://src/core/world/distant_static_renderer.gd")
	if distant_renderer_class:
		distant_renderer = Node3D.new()
		distant_renderer.set_script(distant_renderer_class)
		distant_renderer.name = "DistantStaticRenderer"
		add_child(distant_renderer)

		# Create and configure StaticMeshMerger
		var merger_class = load("res://src/core/world/static_mesh_merger.gd")
		if merger_class:
			var mesh_merger = merger_class.new()

			# Connect mesh simplifier if available
			var simplifier_class = load("res://src/core/nif/mesh_simplifier.gd")
			if simplifier_class:
				mesh_merger.mesh_simplifier = simplifier_class.new()

			# Connect model loader from cell_manager if available
			if cell_manager and cell_manager.has_method("get_model_loader"):
				mesh_merger.model_loader = cell_manager.get_model_loader()
			elif cell_manager and "_model_loader" in cell_manager:
				mesh_merger.model_loader = cell_manager._model_loader

			distant_renderer.set_mesh_merger(mesh_merger)
			distant_renderer.set_cell_manager(cell_manager)

		_debug("DistantStaticRenderer created for MID tier (500m-2km)")

	# Try to load ImpostorManager for FAR tier
	var impostor_manager_class = load("res://src/core/world/impostor_manager.gd")
	if impostor_manager_class:
		impostor_manager = Node3D.new()
		impostor_manager.set_script(impostor_manager_class)
		impostor_manager.name = "ImpostorManager"
		add_child(impostor_manager)

		# Create and connect ImpostorCandidates
		var candidates_class = load("res://src/core/world/impostor_candidates.gd")
		if candidates_class:
			var candidates = candidates_class.new()
			impostor_manager.set_impostor_candidates(candidates)

		_debug("ImpostorManager created for FAR tier (2km-5km)")


## Configure tier manager for a specific world
## Call this after initialize() if using a custom world data provider
func configure_for_world(world_provider) -> void:
	if tier_manager:
		tier_manager.configure_for_world(world_provider)
		_debug("Tier manager configured for world")

#endregion


#region Cell Loading

## Called when camera moves to a different cell
func _on_camera_cell_changed(new_cell: Vector2i) -> void:
	_debug("Camera cell changed to: %s" % new_cell)

	# Reset dropped cell counter for this update cycle
	_queue_full_message_count = 0

	# Use tiered loading if enabled and tier manager exists
	if distant_rendering_enabled and tier_manager:
		_on_camera_cell_changed_tiered(new_cell)
		return

	# Original behavior: NEAR tier only
	var visible_cells := _get_visible_cells(new_cell)

	# Unload cells that are no longer visible
	var cells_to_unload: Array[Vector2i] = []
	for cell_grid: Vector2i in _loaded_cells.keys():
		if cell_grid not in visible_cells:
			cells_to_unload.append(cell_grid)

	for cell_grid in cells_to_unload:
		_unload_cell_internal(cell_grid)

	# Also remove from load queue if no longer needed
	_load_queue = _load_queue.filter(func(entry): return entry.grid in visible_cells)

	# Cancel async requests for cells no longer in view (prevents wasted work)
	var requests_to_cancel: Array[int] = []
	for request_id: int in _async_cell_requests:
		var grid: Vector2i = _async_cell_requests[request_id]
		if grid not in visible_cells:
			requests_to_cancel.append(request_id)

	for request_id in requests_to_cancel:
		var grid: Vector2i = _async_cell_requests[request_id]
		if cell_manager:
			cell_manager.cancel_async_request(request_id)
		_async_cell_requests.erase(request_id)
		_loading_cells.erase(grid)
		_debug("Cancelled async request for out-of-view cell: %s" % grid)

	# Queue new visible cells for loading
	if load_objects and cell_manager:
		for cell_grid in visible_cells:
			if cell_grid not in _loaded_cells and cell_grid not in _loading_cells:
				if async_loading_enabled:
					_queue_cell_load(cell_grid, new_cell)
				else:
					_load_cell_internal(cell_grid)


## Tiered camera cell change handler
## Manages cells across all tiers (NEAR, MID, FAR, HORIZON)
func _on_camera_cell_changed_tiered(new_cell: Vector2i) -> void:
	# Get cells organized by tier
	var cells_by_tier: Dictionary = tier_manager.get_visible_cells_by_tier(new_cell)

	# Process each tier
	for tier in cells_by_tier:
		var visible_cells: Array = cells_by_tier[tier]
		_update_tier_cells(tier, visible_cells, new_cell)

	# Update stats
	for tier in cells_by_tier:
		_stats_cells_per_tier[tier] = _loaded_cells_by_tier[tier].size()


## Update cells for a specific tier
func _update_tier_cells(tier: int, visible_cells: Array, camera_cell: Vector2i) -> void:
	var loaded_cells: Dictionary = _loaded_cells_by_tier[tier]
	var loading_cells: Dictionary = _loading_cells_by_tier[tier]

	# Build set for fast lookup
	var visible_set := {}
	for cell in visible_cells:
		visible_set[cell] = true

	# Unload cells that are no longer in this tier
	var cells_to_unload: Array[Vector2i] = []
	for cell_grid: Vector2i in loaded_cells.keys():
		if cell_grid not in visible_set:
			cells_to_unload.append(cell_grid)

	for cell_grid in cells_to_unload:
		_unload_cell_for_tier(tier, cell_grid)

	# Remove from load queue if no longer needed in this tier
	_load_queue = _load_queue.filter(func(entry):
		return entry.get("tier", DistanceTierManagerScript.Tier.NEAR) != tier or entry.grid in visible_set
	)

	# Cancel async requests for cells no longer in view (NEAR tier only)
	if tier == DistanceTierManagerScript.Tier.NEAR:
		var requests_to_cancel: Array[int] = []
		for request_id: int in _async_cell_requests:
			var grid: Vector2i = _async_cell_requests[request_id]
			if grid not in visible_set:
				requests_to_cancel.append(request_id)

		for request_id in requests_to_cancel:
			var grid: Vector2i = _async_cell_requests[request_id]
			if cell_manager:
				cell_manager.cancel_async_request(request_id)
			_async_cell_requests.erase(request_id)
			loading_cells.erase(grid)
			_loading_cells.erase(grid)  # Also update legacy tracking
			_debug("Cancelled async request for out-of-tier cell: %s" % grid)

	# Queue new visible cells for loading
	if load_objects:
		for cell_grid in visible_cells:
			if cell_grid not in loaded_cells and cell_grid not in loading_cells:
				_queue_cell_load_tiered(cell_grid, camera_cell, tier)


## Unload a cell from a specific tier
func _unload_cell_for_tier(tier: int, grid: Vector2i) -> void:
	match tier:
		DistanceTierManagerScript.Tier.NEAR:
			_unload_cell_internal(grid)
		DistanceTierManagerScript.Tier.MID:
			_unload_mid_tier_cell(grid)
		DistanceTierManagerScript.Tier.FAR:
			_unload_far_tier_cell(grid)
		DistanceTierManagerScript.Tier.HORIZON:
			_unload_horizon_tier_cell(grid)

	# Remove from tier tracking
	_loaded_cells_by_tier[tier].erase(grid)
	tier_manager.forget_cell(grid)


## Unload MID tier cell (merged mesh)
func _unload_mid_tier_cell(grid: Vector2i) -> void:
	if distant_renderer and distant_renderer.has_method("remove_cell"):
		distant_renderer.remove_cell(grid)
		_debug("Unloaded MID tier cell: %s" % grid)


## Unload FAR tier cell (impostors)
func _unload_far_tier_cell(grid: Vector2i) -> void:
	if impostor_manager and impostor_manager.has_method("remove_impostors_for_cell"):
		impostor_manager.remove_impostors_for_cell(grid)
		_debug("Unloaded FAR tier cell: %s" % grid)


## Unload HORIZON tier cell (skybox layer - usually no-op)
func _unload_horizon_tier_cell(_grid: Vector2i) -> void:
	# HORIZON tier is typically static skybox, no per-cell unloading needed
	pass


## Get list of cells that should be visible around a center cell
func _get_visible_cells(center: Vector2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []

	for dy in range(-view_distance_cells, view_distance_cells + 1):
		for dx in range(-view_distance_cells, view_distance_cells + 1):
			# Circular check for more natural view distance
			if dx * dx + dy * dy <= view_distance_cells * view_distance_cells:
				cells.append(Vector2i(center.x + dx, center.y + dy))

	return cells


## Internal cell loading
func _load_cell_internal(grid: Vector2i) -> Node3D:
	if not cell_manager:
		push_warning("WorldStreamingManager: No CellManager set - cannot load cells")
		return null

	_loading_cells[grid] = true
	cell_loading.emit(grid)
	_debug("Loading cell: %s" % grid)

	# Load cell using CellManager
	var cell_node: Node3D = cell_manager.load_exterior_cell(grid.x, grid.y)

	_loading_cells.erase(grid)

	if not cell_node:
		# Cell doesn't exist (ocean, etc.) - that's OK
		_debug("Cell %s has no data (ocean/empty)" % grid)
		return null

	# Add directly to scene tree (OWDB is for static scenes, not dynamic loading)
	add_child(cell_node)

	# No scaling needed - CellManager now outputs in meters (via CoordinateSystem)
	# Both terrain and objects are in consistent meter units

	# Store grid reference for later lookup
	cell_node.set_meta("cell_grid", grid)

	_loaded_cells[grid] = cell_node
	cell_loaded.emit(grid, cell_node)
	_debug("Cell loaded: %s with %d children" % [grid, cell_node.get_child_count()])

	return cell_node


## Internal cell unloading
func _unload_cell_internal(grid: Vector2i) -> void:
	if grid not in _loaded_cells:
		return

	var cell_node: Node3D = _loaded_cells[grid]
	_loaded_cells.erase(grid)

	if cell_node and is_instance_valid(cell_node):
		# Release pooled objects back to the pool before freeing the cell
		# This dramatically improves performance by reusing Node3D instances
		if cell_manager:
			var pool = cell_manager.get_object_pool()
			if pool and pool.has_method("release_cell_objects"):
				var released: int = pool.release_cell_objects(cell_node)
				if released > 0:
					_debug("Released %d objects to pool from cell %s" % [released, grid])

		cell_node.queue_free()

	# Clean up static renderer instances (flora, small rocks rendered via RenderingServer)
	if cell_manager and cell_manager.has_method("cleanup_cell_static_instances"):
		var static_removed: int = cell_manager.cleanup_cell_static_instances(grid)
		if static_removed > 0:
			_debug("Removed %d static instances from cell %s" % [static_removed, grid])

	cell_unloaded.emit(grid)
	_debug("Cell unloaded: %s" % grid)

#endregion


#region Async Loading Queue

## Enable frustum-based priority for cell loading
## When enabled, cells in front of camera load first, reducing perceived pop-in
@export var frustum_priority_enabled: bool = true

## Add a cell to the priority load queue
## Cells closer to the camera have higher priority (lower priority value)
## When frustum_priority_enabled, cells in front of camera get bonus priority
func _queue_cell_load(grid: Vector2i, camera_cell: Vector2i) -> void:
	# Check if already in queue
	for entry in _load_queue:
		if entry.grid == grid:
			return

	# Check queue size limit - throttle debug messages to prevent log spam
	if _load_queue.size() >= max_load_queue_size:
		_queue_full_message_count += 1
		if _queue_full_message_count == 1 or _queue_full_message_count % _queue_full_message_throttle == 0:
			_debug("Load queue full, dropped %d cells (latest: %s)" % [_queue_full_message_count, grid])
		return

	# Calculate base priority from distance (Manhattan distance)
	var dx := grid.x - camera_cell.x
	var dy := grid.y - camera_cell.y
	var distance := absf(dx) + absf(dy)
	var priority: float = distance  # Lower = higher priority

	# Apply frustum priority: cells in front of camera load first
	if frustum_priority_enabled and _tracked_node:
		var camera_forward := Vector3.FORWARD
		if _tracked_node is Camera3D:
			camera_forward = -(_tracked_node as Camera3D).global_transform.basis.z
		elif _tracked_node.has_method("get_camera_3d"):
			var cam: Camera3D = _tracked_node.get_camera_3d()
			if cam:
				camera_forward = -cam.global_transform.basis.z

		# Direction to cell (in XZ plane, Y is up in Godot)
		# Cell grid: +X is east, +Y is north in Morrowind
		# In Godot: +X is east, -Z is north (after coordinate conversion)
		var cell_dir := Vector3(dx, 0, -dy).normalized()
		var dot := camera_forward.dot(cell_dir)

		# dot = 1 means cell is directly in front, -1 means behind
		# Apply penalty of up to 3 priority levels for cells behind camera
		# This ensures cells in front load first even if slightly further
		priority -= dot * 2.0  # In front gets bonus (lower priority), behind gets penalty

	# Insert in sorted order (priority queue - lower = higher priority)
	var inserted := false
	for i in range(_load_queue.size()):
		if priority < _load_queue[i].priority:
			_load_queue.insert(i, { "grid": grid, "priority": priority })
			inserted = true
			break

	if not inserted:
		_load_queue.append({ "grid": grid, "priority": priority })

	# Track high water mark
	if _load_queue.size() > _stats_queue_high_water_mark:
		_stats_queue_high_water_mark = _load_queue.size()

	_loading_cells[grid] = true
	cell_loading.emit(grid)


## Add a cell to the priority load queue with tier information
## Tier priority is factored in: NEAR loads before MID, MID before FAR
func _queue_cell_load_tiered(grid: Vector2i, camera_cell: Vector2i, tier: int) -> void:
	# Check if already in queue for this tier
	for entry in _load_queue:
		if entry.grid == grid and entry.get("tier", DistanceTierManagerScript.Tier.NEAR) == tier:
			return

	# Check queue size limit - throttle debug messages to prevent log spam
	if _load_queue.size() >= max_load_queue_size:
		_queue_full_message_count += 1
		if _queue_full_message_count == 1 or _queue_full_message_count % _queue_full_message_throttle == 0:
			_debug("Load queue full, dropped %d cells (latest: %s, tier %d)" % [_queue_full_message_count, grid, tier])
		return

	# Calculate base priority from distance (Manhattan distance)
	var dx := grid.x - camera_cell.x
	var dy := grid.y - camera_cell.y
	var distance := absf(dx) + absf(dy)

	# Start with tier priority (NEAR=0, MID=1000, FAR=2000)
	# This ensures NEAR cells always load before MID, MID before FAR
	var tier_priority_offset: int = tier_manager.get_tier_priority(tier)
	tier_priority_offset = 100 - tier_priority_offset  # Invert so NEAR (100) becomes 0, MID (50) becomes 50, etc.
	var priority: float = tier_priority_offset * 100 + distance

	# Apply frustum priority: cells in front of camera load first (NEAR tier only)
	if frustum_priority_enabled and _tracked_node and tier == DistanceTierManagerScript.Tier.NEAR:
		var camera_forward := Vector3.FORWARD
		if _tracked_node is Camera3D:
			camera_forward = -(_tracked_node as Camera3D).global_transform.basis.z
		elif _tracked_node.has_method("get_camera_3d"):
			var cam: Camera3D = _tracked_node.get_camera_3d()
			if cam:
				camera_forward = -cam.global_transform.basis.z

		var cell_dir := Vector3(dx, 0, -dy).normalized()
		var dot := camera_forward.dot(cell_dir)
		priority -= dot * 2.0

	# Insert in sorted order (priority queue - lower = higher priority)
	var entry_dict := { "grid": grid, "priority": priority, "tier": tier }
	var inserted := false
	for i in range(_load_queue.size()):
		if priority < _load_queue[i].priority:
			_load_queue.insert(i, entry_dict)
			inserted = true
			break

	if not inserted:
		_load_queue.append(entry_dict)

	# Track high water mark
	if _load_queue.size() > _stats_queue_high_water_mark:
		_stats_queue_high_water_mark = _load_queue.size()

	# Track in tier-specific loading dictionary
	_loading_cells_by_tier[tier][grid] = true

	# Also track in legacy dict for NEAR tier compatibility
	if tier == DistanceTierManagerScript.Tier.NEAR:
		_loading_cells[grid] = true
		cell_loading.emit(grid)


## Process the load queue with time budgeting
## Called every frame to load cells without causing hitches
## Uses async loading when background processor is available
## Industry standard: Throttle submissions to avoid I/O saturation
func _process_load_queue() -> void:
	if _load_queue.is_empty():
		return

	var start_time := Time.get_ticks_usec()
	var budget_usec := cell_load_budget_ms * 1000.0
	_stats_cells_loaded_this_frame = 0

	# Check if we can use async loading (background processor available)
	var use_async := background_processor != null and cell_manager != null

	# Track submissions this frame for throttling
	var async_submits_this_frame := 0

	while not _load_queue.is_empty():
		# Check time budget
		var elapsed := Time.get_ticks_usec() - start_time
		if elapsed >= budget_usec:
			break

		# Throttle async submissions per frame to avoid queue flooding
		if use_async and async_submits_this_frame >= max_cell_submits_per_frame:
			break

		# Pop highest priority cell (front of queue)
		var entry: Dictionary = _load_queue.pop_front()
		var grid: Vector2i = entry.grid
		var tier: int = entry.get("tier", DistanceTierManagerScript.Tier.NEAR)

		# Route to tier-specific loader
		match tier:
			DistanceTierManagerScript.Tier.NEAR:
				async_submits_this_frame += _process_near_tier_cell(grid, use_async)
			DistanceTierManagerScript.Tier.MID:
				_process_mid_tier_cell(grid)
			DistanceTierManagerScript.Tier.FAR:
				_process_far_tier_cell(grid)
			DistanceTierManagerScript.Tier.HORIZON:
				_process_horizon_tier_cell(grid)

	# Update timing stats
	_stats_load_time_ms = (Time.get_ticks_usec() - start_time) / 1000.0


## Process NEAR tier cell (full geometry)
## Returns 1 if an async request was submitted, 0 otherwise
func _process_near_tier_cell(grid: Vector2i, use_async: bool) -> int:
	# Skip if already loaded (race condition prevention)
	if grid in _loaded_cells:
		_loading_cells.erase(grid)
		_loading_cells_by_tier[DistanceTierManagerScript.Tier.NEAR].erase(grid)
		return 0

	# Skip if already has pending async request
	if grid in _async_cell_requests.values():
		return 0

	if use_async:
		# Submit async request - actual loading happens in background
		var request_id: int = cell_manager.request_exterior_cell_async(grid.x, grid.y)
		if request_id >= 0:
			_async_cell_requests[request_id] = grid

			# PROGRESSIVE LOADING: Add cell node to scene immediately
			# Objects will appear as they're instantiated by process_async_instantiation
			var cell_node: Node3D = cell_manager.get_async_cell_node(request_id)
			if cell_node and not cell_node.is_inside_tree():
				add_child(cell_node)
				cell_node.set_meta("cell_grid", grid)
				_loaded_cells[grid] = cell_node
				_loaded_cells_by_tier[DistanceTierManagerScript.Tier.NEAR][grid] = cell_node
				_debug("Async NEAR cell added for progressive loading: %s (id=%d)" % [grid, request_id])
			return 1
		else:
			# Fallback to sync if async not available (e.g., cell not found)
			_loading_cells.erase(grid)
			_loading_cells_by_tier[DistanceTierManagerScript.Tier.NEAR].erase(grid)
			_debug("NEAR cell %s has no data (async returned -1)" % grid)
	else:
		# Fallback to sync loading (no background processor)
		var cell_node: Node3D = cell_manager.load_exterior_cell(grid.x, grid.y)
		_loading_cells.erase(grid)
		_loading_cells_by_tier[DistanceTierManagerScript.Tier.NEAR].erase(grid)

		if cell_node:
			add_child(cell_node)
			cell_node.set_meta("cell_grid", grid)

			_loaded_cells[grid] = cell_node
			_loaded_cells_by_tier[DistanceTierManagerScript.Tier.NEAR][grid] = cell_node
			cell_loaded.emit(grid, cell_node)
			_stats_cells_loaded_this_frame += 1
			_debug("NEAR cell loaded (sync): %s with %d children" % [grid, cell_node.get_child_count()])
		else:
			_debug("NEAR cell %s has no data (ocean/empty)" % grid)

	return 0


## Path to pre-baked merged cell meshes (generated by mesh_prebaker.gd tool)
const PREBAKED_MERGED_CELLS_PATH := "res://assets/merged_cells/"

## Path to pre-baked impostor textures (generated by impostor_baker.gd tool)
const PREBAKED_IMPOSTORS_PATH := "res://assets/impostors/"

## Whether to fall back to runtime mesh merging if pre-baked not available
## WARNING: Runtime merging is slow (50-100ms per cell) - should be false in production
@export var allow_runtime_mesh_merging: bool = false


## Process MID tier cell (merged static geometry)
## CRITICAL: Uses pre-baked merged meshes, NOT runtime merging
## Runtime merging is 50-100ms per cell which is too slow for 100+ cells
func _process_mid_tier_cell(grid: Vector2i) -> void:
	# Skip if already loaded
	if grid in _loaded_cells_by_tier[DistanceTierManagerScript.Tier.MID]:
		_loading_cells_by_tier[DistanceTierManagerScript.Tier.MID].erase(grid)
		return

	# PHASE 1: Try to load pre-baked merged mesh (fast path)
	var prebaked_path := PREBAKED_MERGED_CELLS_PATH + "cell_%d_%d.res" % [grid.x, grid.y]
	if ResourceLoader.exists(prebaked_path):
		var mesh := load(prebaked_path) as ArrayMesh
		if mesh and distant_renderer and distant_renderer.has_method("add_cell_prebaked"):
			distant_renderer.add_cell_prebaked(grid, mesh)
			_loading_cells_by_tier[DistanceTierManagerScript.Tier.MID].erase(grid)
			_loaded_cells_by_tier[DistanceTierManagerScript.Tier.MID][grid] = true
			_debug("MID tier cell loaded: %s (pre-baked)" % grid)
			return

	# PHASE 2: Fallback to runtime merging if enabled (SLOW - development only)
	if allow_runtime_mesh_merging and distant_renderer and distant_renderer.has_method("add_cell"):
		var cell_record = ESMManager.get_exterior_cell(grid.x, grid.y)
		if cell_record:
			var success: bool = distant_renderer.add_cell(grid, cell_record.references)
			_loading_cells_by_tier[DistanceTierManagerScript.Tier.MID].erase(grid)
			_loaded_cells_by_tier[DistanceTierManagerScript.Tier.MID][grid] = true
			if success:
				_debug("MID tier cell loaded: %s (runtime merge - SLOW)" % grid)
			return

	# PHASE 3: No pre-baked data and runtime disabled - skip gracefully
	_loading_cells_by_tier[DistanceTierManagerScript.Tier.MID].erase(grid)
	_loaded_cells_by_tier[DistanceTierManagerScript.Tier.MID][grid] = true  # Mark as handled


## Process FAR tier cell (impostors)
## CRITICAL: Uses pre-baked impostor textures - if not available, skips gracefully
## Impostors require pre-baked textures in assets/impostors/ directory
func _process_far_tier_cell(grid: Vector2i) -> void:
	# Skip if already loaded
	if grid in _loaded_cells_by_tier[DistanceTierManagerScript.Tier.FAR]:
		_loading_cells_by_tier[DistanceTierManagerScript.Tier.FAR].erase(grid)
		return

	# Check if impostor system is available
	if not impostor_manager or not impostor_manager.has_method("add_cell_impostors"):
		_loading_cells_by_tier[DistanceTierManagerScript.Tier.FAR].erase(grid)
		_loaded_cells_by_tier[DistanceTierManagerScript.Tier.FAR][grid] = true
		return

	# Get cell references
	var cell_record = ESMManager.get_exterior_cell(grid.x, grid.y)
	if not cell_record:
		# Cell doesn't exist - mark as "loaded" (empty)
		_loading_cells_by_tier[DistanceTierManagerScript.Tier.FAR].erase(grid)
		_loaded_cells_by_tier[DistanceTierManagerScript.Tier.FAR][grid] = true
		return

	# Add cell impostors (only works if pre-baked textures exist)
	# If no impostors are added, this is expected until impostor_baker.gd is run
	var count: int = impostor_manager.add_cell_impostors(grid, cell_record.references)
	_loading_cells_by_tier[DistanceTierManagerScript.Tier.FAR].erase(grid)
	_loaded_cells_by_tier[DistanceTierManagerScript.Tier.FAR][grid] = true

	if count > 0:
		_debug("FAR tier cell loaded: %s (%d impostors)" % [grid, count])


## Process HORIZON tier cell (skybox - usually no-op per cell)
func _process_horizon_tier_cell(grid: Vector2i) -> void:
	# HORIZON tier is typically handled by static skybox, not per-cell
	# Just mark as "loaded" to prevent re-queueing
	_loading_cells_by_tier[DistanceTierManagerScript.Tier.HORIZON].erase(grid)
	_loaded_cells_by_tier[DistanceTierManagerScript.Tier.HORIZON][grid] = true


## Poll for completed async cell requests and integrate them
func _poll_async_completions() -> void:
	if _async_cell_requests.is_empty() or not cell_manager:
		return

	var completed_requests: Array[int] = []

	for request_id: int in _async_cell_requests:
		if cell_manager.is_async_complete(request_id):
			completed_requests.append(request_id)

	for request_id in completed_requests:
		var grid: Vector2i = _async_cell_requests[request_id]
		_async_cell_requests.erase(request_id)
		_loading_cells.erase(grid)

		# Check for partial failures (some models failed to parse)
		if cell_manager.has_async_failed(request_id):
			var failed_count: int = cell_manager.get_async_failed_count(request_id)
			_debug("Cell %s had %d models fail to parse (will use placeholders)" % [grid, failed_count])

		# With progressive loading, cell_node was already added to scene in _process_load_queue
		# Just clean up tracking and emit signal
		var cell_node: Node3D = cell_manager.get_async_result(request_id)

		if cell_node:
			# Cell was already added via progressive loading - just emit signal
			if grid in _loaded_cells and _loaded_cells[grid] == cell_node:
				cell_loaded.emit(grid, cell_node)
				_stats_cells_loaded_this_frame += 1
				_debug("Cell async complete: %s with %d children" % [grid, cell_node.get_child_count()])
			elif not cell_node.is_inside_tree():
				# Fallback: add if not already in tree (shouldn't happen normally)
				add_child(cell_node)
				cell_node.set_meta("cell_grid", grid)
				_loaded_cells[grid] = cell_node
				cell_loaded.emit(grid, cell_node)
				_stats_cells_loaded_this_frame += 1
				_debug("Cell loaded (async fallback): %s with %d children" % [grid, cell_node.get_child_count()])
		else:
			_debug("Cell %s has no data (async result null)" % grid)


## Clear the load queue (e.g., when teleporting)
func clear_load_queue() -> void:
	for entry in _load_queue:
		_loading_cells.erase(entry.grid)
	_load_queue.clear()

	# Cancel pending async requests
	if cell_manager:
		for request_id in _async_cell_requests:
			cell_manager.cancel_async_request(request_id)
	_async_cell_requests.clear()

	_debug("Load queue cleared")

#endregion


#region Coordinate Utilities

## Convert Godot world position to Morrowind cell grid coordinates
func _get_cell_from_godot_position(godot_pos: Vector3) -> Vector2i:
	return CS.godot_pos_to_cell_grid(godot_pos)


## Convert cell grid to Godot world position (center of cell)
func _cell_to_godot_position(grid: Vector2i) -> Vector3:
	return CS.cell_grid_to_center_godot(grid)

#endregion


#region Debug

func _debug(msg: String) -> void:
	if debug_enabled:
		print("WorldStreamingManager: %s" % msg)

#endregion
