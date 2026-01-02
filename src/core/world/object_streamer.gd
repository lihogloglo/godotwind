## ObjectStreamer - Per-Object LOD Coordinator
##
## ARCHITECTURE OVERVIEW:
## ObjectStreamer manages the lifecycle of objects across 3 rendering tiers:
##
##   NEAR (0-150m):   Full Node3D with physics and collision
##   MID (150-500m):  MultiMesh LOD instances (3 detail levels: LOD1/LOD2/LOD3)
##   FAR (500-5000m): Octahedral impostor billboards
##
## VISIBILITY AUTHORITY:
## ObjectStreamer receives tier assignments from DistanceTierManager (unified visibility authority)
## and applies the appropriate rendering method. It does NOT calculate visibility itself.
##
## PERFORMANCE OPTIMIZATION:
## Only NEAR (0-150m) and MID (150-500m) objects are registered with DistanceTierManager.
## FAR tier (500m-5km) uses chunk-based rendering via QuadtreeChunkManager/ImpostorManager
## to avoid per-frame iteration of 10,000+ distant objects.
##
## CROSSFADE COORDINATION:
## Dithered screen-door transparency during tier transitions:
##   - NEAR→MID: Both visible for 30m overlap, crossfade via shader
##   - MID→FAR: Both visible for 30m overlap, crossfade via shader
##   - Uses 4x4 Bayer matrix for temporal anti-aliasing (TAA required)
##
## RENDERING DELEGATION:
##   - NEAR tier: Direct Node3D children (managed by ObjectStreamer)
##   - MID tier: Delegated to LODMultiMeshBatcher (batches by mesh+LOD level)
##   - FAR tier: Delegated to ImpostorManager (texture array batching)
##
## PERFORMANCE FEATURES:
##   - Object pooling (2048 Node3D instances recycled)
##   - Time-budgeted instantiation (12ms/frame max)
##   - Spatial hash for fast nearby queries (50m cell size)
##   - Detailed statistics and recreation tracking
##
## Usage:
##   var streamer := ObjectStreamer.new()
##   add_child(streamer)
##   streamer.set_impostor_manager(impostor_mgr)
##   streamer.register_object(id, pos, model_path, lod_paths, impostor_idx)
##   streamer.update(camera_pos, delta)
class_name ObjectStreamer
extends Node3D

# Dependencies
const LODMultiMeshBatcherScript := preload("res://src/core/world/lod_multimesh_batcher.gd")
const LODPrebakerScript := preload("res://src/tools/prebaking/lod_prebaker.gd")
const ImpostorCandidatesScript := preload("res://src/core/world/impostor_candidates.gd")
const DU := preload("res://src/core/world/distance_utils.gd")
const CS := preload("res://src/core/coordinate_system.gd")

#region Constants

## Distance tiers
enum Tier {
	NEAR = 0,    # 0-150m: Full Node3D
	MID = 1,     # 150-500m: LOD meshes
	FAR = 2,     # 500m-5km: Impostors
	HIDDEN = 3   # Beyond FAR
}

## Distance thresholds (from DistanceUtils - single source of truth)
const NEAR_END: float = DU.NEAR_END      # 150m
const MID_END: float = DU.MID_END        # 500m
const FAR_END: float = DU.FAR_END        # 5000m
const FADE_MARGIN: float = DU.FADE_MARGIN # 30m

## Pre-warm distance - emit prewarm signal for objects closer than this
## Slightly beyond NEAR_END so pools are ready before objects enter NEAR tier
## Note: SC constant is defined below in Event-Driven Fade System region
const POOL_PREWARM_DISTANCE: float = 250.0  # From StreamingConfig.POOL_PREWARM_DISTANCE

## MID tier sub-LOD thresholds
const MID_LOD1_END: float = 250.0
const MID_LOD2_END: float = 375.0

## Object pool configuration (configurable via exports)
@export_group("Pool Configuration")
@export var pool_max_size: int = 2048            ## Maximum tracked objects before eviction
@export var near_keepalive_time: float = 5.0    ## Seconds before freeing hidden Node3D

## Instantiation queue configuration
@export_group("Instantiation Queue")
@export var instantiation_budget_ms: float = 12.0  ## Time budget per frame (ms), from StreamingConfig.INSTANTIATION_BUDGET_MS
@export var max_instantiations_per_frame: int = 50    ## Hard cap on instantiations (increased for faster loading)

## Spatial hash cell size for efficient lookups
const SPATIAL_HASH_CELL_SIZE: float = 50.0

## Update staggering
const UPDATE_GROUP_COUNT: int = 4

#endregion


#region Tracked Object

## StreamedObject - represents a single object across all tiers
## Tracked object data structure
class StreamedObject extends RefCounted:
	var id: int
	var position: Vector3
	var transform: Transform3D
	var model_path: String
	var cell_grid: Vector2i
	var ref_num: int
	var ref_id: String
	var is_significant: bool  # Gets LOD chain + impostor

	# NEAR tier
	var node3d: Node3D = null
	var node3d_parent: Node = null
	var near_hidden_time: float = 0.0
	var near_visible: bool = false

	# MID tier (LOD meshes)
	var lod_meshes: Array[ArrayMesh] = []
	var lod_materials: Array[Array] = []
	var multimesh_keys: Array[int] = []
	var mid_visible: bool = false
	var mid_fade: float = 0.0
	var lod_meshes_loaded: bool = false
	var current_mid_lod_idx: int = -1  # Track current LOD level to avoid unnecessary updates

	# FAR tier (impostor)
	var impostor_id: int = -1
	var far_visible: bool = false
	var far_fade: float = 0.0

	# State
	var current_tier: int = Tier.HIDDEN
	var distance_sq: float = 0.0
	var last_update_frame: int = 0
	var is_transitioning: bool = false  # True when crossfading between tiers

	# Pool state
	var in_pool: bool = false  # True if returned to pool (available for reuse)

#endregion


#region Object Pool

## Pool of reusable StreamedObject instances
## Eliminates allocation overhead and queue complexity
var _object_pool: Array[StreamedObject] = []
var _pool_available: Array[int] = []  # Indices of available objects in pool

## Acquire an object from the pool (or create new if needed)
func _pool_acquire() -> StreamedObject:
	if not _pool_available.is_empty():
		var idx: int = _pool_available.pop_back()
		var obj: StreamedObject = _object_pool[idx]
		obj.in_pool = false
		return obj

	# Pool exhausted - create new if under limit
	if _object_pool.size() < pool_max_size:
		var obj := StreamedObject.new()
		obj.id = _object_pool.size()
		_object_pool.append(obj)
		return obj

	# Pool full - evict farthest object
	_stats["evictions"] = _stats.get("evictions", 0) + 1
	return _pool_evict_farthest()


## Release an object back to the pool
func _pool_release(obj: StreamedObject) -> void:
	if obj.in_pool:
		return  # Already in pool

	# Cleanup object state
	_cleanup_object(obj)

	# Mark as available
	obj.in_pool = true
	_pool_available.append(obj.id)


## Evict the farthest object to make room
func _pool_evict_farthest() -> StreamedObject:
	var farthest_obj: StreamedObject = null
	var farthest_dist_sq: float = -1.0

	for obj in _object_pool:
		if obj.in_pool:
			continue
		if obj.distance_sq > farthest_dist_sq:
			farthest_dist_sq = obj.distance_sq
			farthest_obj = obj

	if farthest_obj:
		_pool_release(farthest_obj)
		_objects.erase(farthest_obj.id)
		_remove_from_spatial_hash(farthest_obj)
		farthest_obj.in_pool = false
		return farthest_obj

	# Shouldn't happen, but create new as fallback
	push_warning("[ObjectStreamer] Pool eviction failed, creating overflow object")
	var obj := StreamedObject.new()
	obj.id = _object_pool.size()
	_object_pool.append(obj)
	return obj

#endregion


#region State

## Active objects by ID: id -> StreamedObject
var _objects: Dictionary = {}

## Spatial hash for efficient nearby lookups
var _spatial_hash: Dictionary = {}  # Vector2i -> Array[int]

## Next object ID (for external references)
var _next_external_id: int = 1

## External ID to pool ID mapping (bidirectional for O(1) lookups)
var _external_to_pool: Dictionary = {}  # external_id -> pool_id
var _pool_to_external: Dictionary = {}  # pool_id -> external_id (reverse mapping)

## External references
var _batcher: RefCounted = null  # LODMultiMeshBatcher
var _impostor_manager: Node = null
var _impostor_candidates: RefCounted = null
var _position_index: RefCounted = null  # ObjectPositionIndex for AAA streaming
var _distance_tier_manager: RefCounted = null  # DistanceTierManager for centralized tier logic
var _gpu_visibility_renderer: RefCounted = null  # GPUVisibilityRenderer for Phase 2 GPU-driven visibility

## Whether GPU-driven visibility is enabled (Phase 2)
var _gpu_driven_enabled: bool = false

## AAA streaming state
var _aaa_streaming_enabled: bool = false
var _aaa_registered_objects: Dictionary = {}  # "cell_x,cell_y,ref_num" -> external_id
var _aaa_last_query_radius: float = 0.0
var _aaa_query_interval_frames: int = 3  # Query position index every N frames (aggressive for fast initial load)
var _aaa_last_query_frame: int = 0
var _aaa_initial_load_complete: bool = false  # Track if initial MID tier is populated

## LOD mesh cache - shared across all objects with same model
## model_path -> { lod_level -> ArrayMesh }
var _lod_mesh_cache: Dictionary = {}

## Pending async LOD loads - tracks objects waiting for LOD meshes
## model_path -> { "loading": bool, "objects": Array[int] (external_ids) }
var _pending_lod_loads: Dictionary = {}

## Cached tier counts to avoid expensive O(n) iteration every query
## Updated incrementally when objects are registered/unregistered
var _cached_tier_counts: Dictionary = {
	"near": 0,  # Objects within NEAR_END
	"mid": 0,   # Objects within MID_END (includes near)
	"far": 0    # Objects within FAR_END (includes near + mid)
}

## Instantiation queue for NEAR tier objects
## Objects waiting for Node3D creation - sorted by distance (closest first)
var _instantiation_queue: Array[int] = []  # external_ids waiting for instantiation

## Node recreation tracking - objects pending Node3D creation
## Objects that had Node3D freed and need recreation when returning to NEAR
var _pending_recreations: Dictionary = {}  # external_id -> true

## Transitioning objects tracking - objects currently crossfading between tiers
## DEPRECATED: Use _active_fades instead for event-driven system
## Kept for backward compatibility during migration
var _transitioning_objects: Dictionary = {}  # external_id -> true

#region Event-Driven Fade System (Industry-Standard)

## Configuration from StreamingConfig
const SC := preload("res://src/core/world/streaming_config.gd")

## FadeAnimation - Tracks a single time-based fade between tiers
## Uses time-based interpolation instead of distance-based for consistent visual quality
class FadeAnimation extends RefCounted:
	var external_id: int = -1
	var pool_id: int = -1
	var start_time: float = 0.0      # Time.get_ticks_msec() / 1000.0
	var duration: float = 0.3         # From StreamingConfig.FADE_DURATION
	var from_tier: int = -1
	var to_tier: int = -1
	var fade_direction: float = 1.0   # 1.0 = fading in, -1.0 = fading out

## Active fade animations: external_id -> FadeAnimation
## Only objects in this dictionary are updated each frame - O(fading) not O(all)
var _active_fades: Dictionary = {}

## Material pool for crossfade materials (zero allocation at runtime)
var _fade_material_pool: Array[ShaderMaterial] = []
var _fade_material_available: Array[int] = []
var _fade_materials_initialized: bool = false

## Previous camera position for teleport detection
var _prev_camera_pos: Vector3 = Vector3.ZERO

## Whether to use event-driven fades (can be toggled for A/B testing)
var use_event_driven_fades: bool = true

#endregion

## Crossfade shaders
var _multimesh_shader: Shader = null
var _node3d_crossfade_shader: Shader = null

## Active NEAR tier crossfades: external_id -> {material: ShaderMaterial, originals: Array[Material]}
var _active_near_crossfades: Dictionary = {}

## World scenario
var _scenario: RID = RID()

## Update staggering
var _current_update_group: int = 0
var _frame_count: int = 0

## Camera tracking
var _camera_pos: Vector3 = Vector3.ZERO
var _camera_moved_threshold_sq: float = 1.0

## Tier visibility toggles (debug)
var near_tier_visible: bool = true
var mid_tier_visible: bool = true
var far_tier_visible: bool = true

## Enable/disable object streaming (controlled by Models toggle)
## Using setter to handle immediate visibility changes
var enabled: bool = true:
	set(value):
		if enabled == value:
			return
		enabled = value
		# When disabling, hide all objects immediately for instant response
		if not enabled:
			_hide_all_objects()
		else:
			# When enabling, force immediate AAA query on next update
			# Reset last query frame so _update_aaa_streaming will run immediately
			_aaa_last_query_frame = 0

## Debug mode
var debug_enabled: bool = false

## Incremental counters for O(1) stats (avoid O(n) iteration in _update_stats)
var _deferred_count: int = 0      # Objects without Node3D
var _instantiated_count: int = 0  # Objects with Node3D

## Statistics tracking
var _stats: Dictionary = {
	"total_objects": 0,
	"deferred_objects": 0,           # Objects without Node3D (waiting for NEAR)
	"instantiated_objects": 0,       # Objects with active Node3D
	"pool_size": 0,
	"pool_available": 0,
	"near_visible": 0,
	"mid_visible": 0,
	"far_visible": 0,
	"hidden": 0,
	"transitioning": 0,              # Objects currently fading between tiers
	"evictions": 0,
	"nodes_recreated": 0,            # Count of Node3D recreations
	"instantiation_queue_size": 0,   # Objects waiting for instantiation
	"instantiations_this_frame": 0,  # Per-frame instantiation count
	"update_time_ms": 0.0,
	"lod_cache_size": 0,             # Number of models in LOD cache
	"lod_cache_hits": 0,             # LOD meshes served from cache
	"lod_pending_loads": 0,          # Models currently loading async
}

## Batched logging - accumulate tier changes and print summary periodically
var _tier_change_counts: Dictionary = {}  # "FROM→TO" -> count
var _tier_change_log_timer: float = 0.0
const TIER_CHANGE_LOG_INTERVAL: float = 2.0  # Print summary every 2 seconds

#endregion


#region Signals

## Emitted when an object needs Node3D instantiation
signal instantiation_requested(object_id: int, model_path: String, world_transform: Transform3D, cell_grid: Vector2i, ref_id: String, ref_num: int)

## Emitted when an object's Node3D should be recreated
signal node_recreation_requested(object_id: int, cell_grid: Vector2i, ref_num: int)

## Emitted when instantiation queue changes (for UI/debugging)
signal instantiation_queue_changed(queue_size: int)

## Emitted when a model should be pre-warmed in the object pool
## This is triggered for objects within POOL_PREWARM_DISTANCE
signal prewarm_requested(model_path: String, count: int)

#endregion


#region Lifecycle

func _enter_tree() -> void:
	var world_3d := get_viewport().get_world_3d()
	if world_3d:
		_scenario = world_3d.scenario

	# Load crossfade shaders
	_multimesh_shader = load("res://src/core/world/shaders/lod_crossfade_multimesh.gdshader")
	_node3d_crossfade_shader = load("res://src/core/world/shaders/lod_crossfade_node3d.gdshader")

	# Create MultiMesh batcher
	_batcher = LODMultiMeshBatcherScript.new()
	if _multimesh_shader:
		_batcher.initialize(self, _multimesh_shader)

	# Create impostor candidates checker
	_impostor_candidates = ImpostorCandidatesScript.new()


func _exit_tree() -> void:
	clear()
	if _batcher:
		_batcher.cleanup()


func _process(_delta: float) -> void:
	_frame_count += 1
	_current_update_group = _frame_count % UPDATE_GROUP_COUNT

#endregion


#region Configuration

## Set the ImpostorManager reference
func set_impostor_manager(manager: Node) -> void:
	_impostor_manager = manager


## Set the ImpostorCandidates reference
func set_impostor_candidates(candidates: RefCounted) -> void:
	_impostor_candidates = candidates


## Set the DistanceTierManager reference for centralized tier calculations
func set_distance_tier_manager(manager: RefCounted) -> void:
	_distance_tier_manager = manager
	if debug_enabled:
		print("[ObjectStreamer] DistanceTierManager reference set - will use centralized tier logic")


## Set the ObjectPositionIndex for AAA-style streaming (Phase 2B)
## When set, ObjectStreamer will query the index to discover objects by distance
## instead of waiting for CellManager to register them
func set_position_index(index: RefCounted) -> void:
	_position_index = index
	_aaa_streaming_enabled = index != null

	if _aaa_streaming_enabled:
		print("[ObjectStreamer] AAA streaming enabled - will query position index for objects")


## Set initial camera position before any object registration
## CRITICAL: Must be called before registering objects to ensure correct tier assignment
func set_initial_camera_position(pos: Vector3) -> void:
	_camera_pos = pos
	if debug_enabled:
		print("[ObjectStreamer] Initial camera position set: %s" % pos)


## Check if AAA streaming is active
func is_aaa_streaming_enabled() -> bool:
	return _aaa_streaming_enabled


## Set the GPUVisibilityRenderer for Phase 2 GPU-driven visibility
## When set, MID/FAR tier visibility is controlled by GPU compute shader
## instead of per-object CPU iteration
func set_gpu_visibility_renderer(renderer: RefCounted) -> void:
	_gpu_visibility_renderer = renderer
	_gpu_driven_enabled = renderer != null and renderer.is_initialized()

	if _gpu_driven_enabled:
		print("[ObjectStreamer] GPU-driven visibility enabled (Phase 2)")
		# Register existing objects with GPU renderer
		_sync_objects_to_gpu_renderer()
	else:
		print("[ObjectStreamer] GPU-driven visibility not available")


## Check if GPU-driven visibility is active
func is_gpu_driven_enabled() -> bool:
	return _gpu_driven_enabled


## Sync all registered objects to GPU visibility renderer
## Called when GPU renderer is first connected or after bulk operations
func _sync_objects_to_gpu_renderer() -> void:
	if not _gpu_visibility_renderer or not _gpu_driven_enabled:
		return

	var synced_count := 0

	# First, register all batches from the batcher
	if _batcher:
		var all_batches: Dictionary = _batcher.get_all_batches()
		for batch_key: int in all_batches:
			var batch = all_batches[batch_key]
			if not batch or not batch.multimesh:
				continue

			# Register batch with GPU renderer (MID tier for LOD batches)
			var tier := 1  # GPUVisibilityRenderer.Tier.MID
			if _gpu_visibility_renderer.register_batch(batch_key, batch.multimesh, tier):
				# Register each object in the batch
				var instances: Dictionary = batch.instances  # object_id -> local_index
				for object_id: int in instances:
					var local_idx: int = instances[object_id]
					# Find the object's position
					if object_id in _external_to_pool:
						var pool_id: int = _external_to_pool[object_id]
						if pool_id in _objects:
							var obj: StreamedObject = _objects[pool_id]
							# Get original transform from batcher
							var original_transform: Transform3D = _batcher.get_original_transform(batch_key, local_idx)
							_gpu_visibility_renderer.add_object_to_batch_with_transform(
								batch_key, object_id, local_idx, obj.position, original_transform)
							synced_count += 1

	if synced_count > 0:
		print("[ObjectStreamer] Synced %d objects to GPU visibility renderer" % synced_count)

#endregion


#region Public API

## Check if a model is significant (gets full LOD chain + impostor)
func is_significant(model_path: String) -> bool:
	if _impostor_candidates:
		return _impostor_candidates.should_have_impostor(model_path)
	return false


## Register an object with an existing Node3D (NEAR tier entry)
## Returns external object_id for tracking
## NOTE: Object may not be in scene tree yet - use local position/transform
func register_object(
	node3d: Node3D,
	model_path: String,
	cell_grid: Vector2i,
	ref_num: int = -1
) -> int:
	if not node3d:
		return -1

	var obj := _pool_acquire()
	var external_id := _next_external_id
	_next_external_id += 1

	_external_to_pool[external_id] = obj.id
	_pool_to_external[obj.id] = external_id

	# Use local position/transform - object may not be in tree yet
	# ReferenceInstantiator sets these before adding to scene tree
	obj.position = node3d.position
	obj.transform = node3d.transform
	obj.model_path = model_path
	obj.cell_grid = cell_grid
	obj.ref_num = ref_num
	obj.ref_id = ""
	obj.is_significant = is_significant(model_path)

	obj.node3d = node3d
	obj.node3d_parent = node3d.get_parent()
	obj.current_tier = Tier.NEAR
	obj.near_visible = near_tier_visible
	obj.near_hidden_time = 0.0

	if not near_tier_visible:
		node3d.visible = false

	# Load LODs for significant objects
	if obj.is_significant:
		_load_lod_meshes(obj)
	else:
		obj.lod_meshes_loaded = true

	_objects[obj.id] = obj
	_add_to_spatial_hash(obj)

	# Incremental stats: object has Node3D, so it's instantiated
	_instantiated_count += 1

	# **UNIFIED VISIBILITY**: Register with DistanceTierManager
	if _distance_tier_manager:
		_distance_tier_manager.register_object(external_id, obj.position, cell_grid)

	_update_stats()
	return external_id


## Register a deferred object (no Node3D yet - for MID/FAR distance)
## Returns external object_id for tracking
func register_deferred_object(
	model_path: String,
	world_position: Vector3,
	rotation: Vector3,
	scale_factor: Vector3,
	cell_grid: Vector2i,
	ref_id: String,
	ref_num: int
) -> int:
	if model_path.is_empty():
		return -1

	var obj := _pool_acquire()
	var external_id := _next_external_id
	_next_external_id += 1

	_external_to_pool[external_id] = obj.id
	_pool_to_external[obj.id] = external_id

	obj.position = world_position
	obj.model_path = model_path
	obj.cell_grid = cell_grid
	obj.ref_num = ref_num
	obj.ref_id = ref_id
	obj.is_significant = is_significant(model_path)

	# Build transform
	var basis := CS.esm_rotation_to_godot_basis(rotation)
	basis = basis.scaled(scale_factor)
	obj.transform = Transform3D(basis, world_position)

	obj.node3d = null
	obj.near_visible = false

	# **UNIFIED VISIBILITY**: Tier will be calculated by DistanceTierManager
	# Set initial tier to HIDDEN - will be updated on first visibility update
	obj.current_tier = Tier.HIDDEN
	obj.distance_sq = 0.0

	obj.lod_meshes_loaded = false

	_objects[obj.id] = obj
	_add_to_spatial_hash(obj)

	# Incremental stats: deferred object has no Node3D yet
	_deferred_count += 1

	# **UNIFIED VISIBILITY**: Register with DistanceTierManager
	# Register ALL objects so they can transition between tiers as camera moves
	if _distance_tier_manager:
		# Calculate initial distance to determine initial tier
		var distance := world_position.distance_to(_camera_pos)
		obj.distance_sq = distance * distance

		# Determine initial tier
		var initial_tier: int
		if distance < NEAR_END:
			initial_tier = Tier.NEAR
		elif distance < MID_END:
			initial_tier = Tier.MID
		elif distance < FAR_END:
			initial_tier = Tier.FAR
		else:
			initial_tier = Tier.HIDDEN

		obj.current_tier = initial_tier

		# Register ALL objects with tier manager so they can transition
		# between tiers as the camera moves (previously only NEAR/MID were registered,
		# causing FAR objects to never transition to closer tiers)
		_distance_tier_manager.register_object(external_id, world_position, cell_grid)

		# Update cached tier counts for AAA streaming optimization
		_update_tier_counts_for_new_object(distance)

		# If already in NEAR, request instantiation
		if initial_tier == Tier.NEAR:
			_request_instantiation(obj, external_id)

		# Pre-warm pool for objects approaching NEAR tier
		# Emit signal for objects within POOL_PREWARM_DISTANCE so pools are ready
		if distance < POOL_PREWARM_DISTANCE and distance >= NEAR_END:
			prewarm_requested.emit(model_path, 1)
	else:
		# Fallback if tier manager not available (should never happen in production)
		# Use simple distance-based tier assignment
		var distance := world_position.distance_to(_camera_pos)
		obj.distance_sq = distance * distance

		if distance < NEAR_END:
			obj.current_tier = Tier.NEAR
		elif distance < MID_END:
			obj.current_tier = Tier.MID
		elif distance < FAR_END:
			obj.current_tier = Tier.FAR
		else:
			obj.current_tier = Tier.HIDDEN

		# Update cached tier counts even in fallback path
		_update_tier_counts_for_new_object(distance)

		if obj.current_tier == Tier.NEAR:
			_request_instantiation(obj, external_id)

	_update_stats()
	return external_id


## Unregister an object by external ID
func unregister_object(external_id: int) -> void:
	if external_id not in _external_to_pool:
		return

	var pool_id: int = _external_to_pool[external_id]
	if pool_id not in _objects:
		_external_to_pool.erase(external_id)
		return

	var obj: StreamedObject = _objects[pool_id]

	# Incremental stats: decrement appropriate counter
	if obj.node3d == null:
		_deferred_count -= 1
	else:
		_instantiated_count -= 1

	# Update cached tier counts before removing
	var distance := sqrt(obj.distance_sq) if obj.distance_sq > 0 else obj.position.distance_to(_camera_pos)
	_update_tier_counts_for_removed_object(distance)

	_remove_from_spatial_hash(obj)
	_objects.erase(pool_id)
	_external_to_pool.erase(external_id)
	_pool_to_external.erase(pool_id)

	# Remove from instantiation queue if present
	var queue_idx := _instantiation_queue.find(external_id)
	if queue_idx >= 0:
		_instantiation_queue.remove_at(queue_idx)
		_stats["instantiation_queue_size"] = _instantiation_queue.size()

	# Remove from pending recreations
	_pending_recreations.erase(external_id)

	# Remove from transitioning tracking
	_transitioning_objects.erase(external_id)

	# **UNIFIED VISIBILITY**: Unregister from DistanceTierManager
	if _distance_tier_manager:
		_distance_tier_manager.unregister_object(external_id)

	_pool_release(obj)

	_update_stats()


## Unregister all objects in a cell
func unregister_cell(cell_grid: Vector2i) -> int:
	var to_remove: Array[int] = []

	for external_id: int in _external_to_pool:
		var pool_id: int = _external_to_pool[external_id]
		if pool_id in _objects:
			var obj: StreamedObject = _objects[pool_id]
			if obj.cell_grid == cell_grid:
				to_remove.append(external_id)

	for external_id in to_remove:
		unregister_object(external_id)

	return to_remove.size()


## Main update - call every frame with camera position
## **UNIFIED VISIBILITY**: Now processes tier changes from DistanceTierManager instead of calculating tiers
func update(camera_pos: Vector3, delta: float) -> void:
	# Early exit if disabled (Models toggle is OFF)
	if not enabled:
		return

	var start_time := Time.get_ticks_usec()

	# Teleport detection - skip fades if camera moved too far in one frame
	var camera_moved_sq := camera_pos.distance_squared_to(_camera_pos)
	var teleported := camera_moved_sq > SC.TELEPORT_THRESHOLD_SQ
	if teleported and use_event_driven_fades:
		_on_teleport_detected()

	var camera_moved := camera_moved_sq > _camera_moved_threshold_sq
	if camera_moved:
		_prev_camera_pos = _camera_pos
		_camera_pos = camera_pos

	# AAA streaming: Query position index for nearby objects (Phase 2B)
	if _aaa_streaming_enabled:
		_update_aaa_streaming(camera_pos)

	# Process instantiation queue for NEAR tier objects
	# This must run before tier transitions to instantiate objects that just entered NEAR
	process_instantiation_queue(camera_pos)

	# Poll for completed async LOD mesh loads
	_poll_pending_lod_loads()

	if _objects.is_empty():
		_stats["update_time_ms"] = (Time.get_ticks_usec() - start_time) / 1000.0
		return

	# Reset visibility counts
	_stats["near_visible"] = 0
	_stats["mid_visible"] = 0
	_stats["far_visible"] = 0
	_stats["hidden"] = 0
	_stats["transitioning"] = 0

	# **UNIFIED VISIBILITY**: Process tier changes from authority
	# Use event-driven system for better performance
	if use_event_driven_fades:
		_process_tier_changes_event_driven(delta)
	else:
		_process_tier_changes_from_authority(delta)

	# AAA streaming: Unload objects beyond FAR tier
	if _aaa_streaming_enabled:
		_unload_distant_objects(camera_pos)

	_stats["update_time_ms"] = (Time.get_ticks_usec() - start_time) / 1000.0

	# Batched tier change logging - print summary periodically instead of per-object
	if debug_enabled:
		_tier_change_log_timer += delta
		if _tier_change_log_timer >= TIER_CHANGE_LOG_INTERVAL:
			if not _tier_change_counts.is_empty():
				_print_tier_change_summary()
			# Log LOD cache stats
			if _stats["lod_cache_size"] > 0 or _stats["lod_pending_loads"] > 0:
				print("[LOD Cache] size: %d, hits: %d, pending: %d" % [
					_stats["lod_cache_size"],
					_stats["lod_cache_hits"],
					_stats["lod_pending_loads"]
				])
			_tier_change_log_timer = 0.0


## Called when a deferred object has been instantiated
func on_object_instantiated(external_id: int, node3d: Node3D) -> void:
	if external_id not in _external_to_pool:
		return

	var pool_id: int = _external_to_pool[external_id]
	if pool_id not in _objects:
		return

	var obj: StreamedObject = _objects[pool_id]

	# Incremental stats: transition from deferred to instantiated
	# Only count if this was actually deferred (node3d was null)
	if obj.node3d == null and node3d != null:
		_deferred_count -= 1
		_instantiated_count += 1

	obj.node3d = node3d
	obj.node3d_parent = node3d.get_parent() if node3d else null
	obj.near_hidden_time = 0.0
	obj.near_visible = near_tier_visible

	if not near_tier_visible and node3d:
		node3d.visible = false

	# Clear recreation flag if this was a recreation
	if external_id in _pending_recreations:
		_pending_recreations.erase(external_id)
		_stats["nodes_recreated"] = _stats.get("nodes_recreated", 0) + 1

		if debug_enabled:
			print("[ObjectStreamer] Node3D recreated for #%d: %s" % [external_id, node3d])


## Legacy alias
func on_deferred_object_instantiated(object_id: int, node3d: Node3D) -> void:
	on_object_instantiated(object_id, node3d)


## Get statistics
func get_stats() -> Dictionary:
	return _stats.duplicate()


## Get detailed debug info for diagnostics
func get_debug_info() -> Dictionary:
	var significant_count := 0
	var lods_loaded_count := 0
	var sample_objects: Array[Dictionary] = []

	for pool_id: int in _objects:
		var obj: StreamedObject = _objects[pool_id]
		if obj.is_significant:
			significant_count += 1
			if not obj.lod_meshes.is_empty():
				lods_loaded_count += 1

		# Sample first few objects for debugging
		if sample_objects.size() < 5:
			sample_objects.append({
				"model": obj.model_path.get_file() if obj.model_path else "?",
				"significant": obj.is_significant,
				"tier": obj.current_tier,
				"lod_count": obj.lod_meshes.size(),
				"near_visible": obj.near_visible,
				"mid_visible": obj.mid_visible,
				"far_visible": obj.far_visible,
				"distance": sqrt(obj.distance_sq) if obj.distance_sq > 0 else 0.0,
			})

	# Get position index info
	var pos_index_info := {}
	if _position_index:
		pos_index_info["set"] = true
		if _position_index.has_method("is_built"):
			pos_index_info["is_built"] = _position_index.is_built()
		if _position_index.has_method("get_total_objects"):
			pos_index_info["total_objects"] = _position_index.get_total_objects()
	else:
		pos_index_info["set"] = false

	return {
		"significant_objects": significant_count,
		"lods_loaded": lods_loaded_count,
		"sample_objects": sample_objects,
		"impostor_candidates_set": _impostor_candidates != null,
		"distance_tier_manager_set": _distance_tier_manager != null,
		"batcher_set": _batcher != null,
		"position_index": pos_index_info,
		"aaa_registered_objects": _aaa_registered_objects.size(),
		"camera_pos": _camera_pos,
	}


## Get all tracked cell grids
func get_tracked_cells() -> Array[Vector2i]:
	var cells: Dictionary = {}
	for pool_id: int in _objects:
		var obj: StreamedObject = _objects[pool_id]
		cells[obj.cell_grid] = true

	var result: Array[Vector2i] = []
	for cell: Vector2i in cells:
		result.append(cell)
	return result


#region GPU Visibility Support (Phase 2)

## Process tier changes from GPU visibility renderer
## This is called when objects change to/from NEAR tier and need CPU handling
## GPU handles MID/FAR visibility directly, but NEAR needs CPU for Node3D management
## changes: Array of {object_id, old_tier, new_tier}
func process_gpu_tier_changes(changes: Array[Dictionary]) -> void:
	for change in changes:
		var object_id: int = change.get("object_id", -1)
		var old_tier: int = change.get("old_tier", Tier.HIDDEN)
		var new_tier: int = change.get("new_tier", Tier.HIDDEN)

		if object_id < 0:
			continue

		# Find the object by external ID
		if object_id not in _external_to_pool:
			continue

		var pool_id: int = _external_to_pool[object_id]
		if pool_id not in _objects:
			continue

		var obj: StreamedObject = _objects[pool_id]

		# Use existing tier change infrastructure
		_apply_tier_change_immediate(obj, object_id, old_tier, new_tier)

		# Start fade animation for smooth transitions
		if use_event_driven_fades:
			_start_fade_animation(obj, object_id, old_tier, new_tier)

		# Update object state
		obj.current_tier = new_tier

	if debug_enabled and not changes.is_empty():
		print("[ObjectStreamer] Processed %d GPU tier changes" % changes.size())


## Get LODMultiMeshBatcher for GPU registration
func get_batcher() -> RefCounted:
	return _batcher


## Get all registered objects with their positions for GPU registration
## Returns: Array of {object_id, position, model_path}
func get_all_objects_for_gpu() -> Array[Dictionary]:
	var result: Array[Dictionary] = []

	for pool_id: int in _objects:
		var obj: StreamedObject = _objects[pool_id]
		if pool_id not in _pool_to_external:
			continue

		var external_id: int = _pool_to_external[pool_id]
		result.append({
			"object_id": external_id,
			"position": obj.position,
			"model_path": obj.model_path,
			"cell_grid": obj.cell_grid,
		})

	return result


## Register an object with a GPU visibility batch
## Called when objects are added to LODMultiMeshBatcher
## external_id: External object ID
## obj: The StreamedObject
## batch_key: The batch the object was added to
func _register_object_with_gpu_batch(external_id: int, obj: StreamedObject, batch_key: int) -> void:
	if not _gpu_visibility_renderer:
		return

	# Get the MultiMesh from the batch
	var multimesh: MultiMesh = _batcher.get_multimesh(batch_key) if _batcher else null
	if not multimesh:
		return

	# Ensure batch is registered with GPU renderer (will return false if already registered - that's OK)
	var tier := 1  # MID tier for LOD batches
	_gpu_visibility_renderer.register_batch(batch_key, multimesh, tier)

	# Get the local index from the batcher
	var batch_mapping: Dictionary = _batcher.get_batch_object_mapping(batch_key)
	var local_idx: int = batch_mapping.get(obj.id, -1)
	if local_idx < 0:
		return

	# Get original transform from batcher (includes rotation/scale, not just position)
	var original_transform: Transform3D = _batcher.get_original_transform(batch_key, local_idx)

	# Register object with GPU visibility renderer (with full transform)
	_gpu_visibility_renderer.add_object_to_batch_with_transform(
		batch_key, external_id, local_idx, obj.position, original_transform)


## Unregister an object from GPU visibility when removed from batch
func _unregister_object_from_gpu_batch(external_id: int, batch_key: int) -> void:
	if not _gpu_visibility_renderer:
		return

	_gpu_visibility_renderer.remove_object_from_batch(batch_key, external_id)

#endregion


## Clear all objects
func clear() -> void:
	for pool_id: int in _objects.keys():
		var obj: StreamedObject = _objects[pool_id]
		_cleanup_object(obj)

	_objects.clear()
	_external_to_pool.clear()
	_pool_to_external.clear()
	_spatial_hash.clear()
	_aaa_registered_objects.clear()  # Clear AAA tracking
	_aaa_initial_load_complete = false  # Reset initial load flag
	_aaa_last_query_frame = 0  # Force immediate query on next update
	_instantiation_queue.clear()     # Clear instantiation queue
	_pending_recreations.clear()     # Clear recreation tracking
	_active_near_crossfades.clear()  # Clear crossfade tracking
	_transitioning_objects.clear()   # Clear transitioning tracking

	# Reset cached tier counts
	_cached_tier_counts["near"] = 0
	_cached_tier_counts["mid"] = 0
	_cached_tier_counts["far"] = 0

	# Reset incremental stats counters
	_deferred_count = 0
	_instantiated_count = 0

	# **UNIFIED VISIBILITY**: Clear all registered objects from DistanceTierManager
	if _distance_tier_manager:
		_distance_tier_manager.clear_registered_objects()

	# Reset pool
	for obj in _object_pool:
		obj.in_pool = true
	_pool_available.clear()
	for i in range(_object_pool.size()):
		_pool_available.append(i)

	_update_stats()


## Set tier visibility (debug toggles)
func set_near_visible(visible: bool) -> void:
	near_tier_visible = visible
	_apply_tier_visibility()


func set_mid_visible(visible: bool) -> void:
	mid_tier_visible = visible
	_apply_tier_visibility()


func set_far_visible(visible: bool) -> void:
	far_tier_visible = visible
	_apply_tier_visibility()
	if _impostor_manager and _impostor_manager.has_method("set_all_visible"):
		_impostor_manager.call("set_all_visible", visible)

#endregion


#region AAA Streaming (Phase 2B)

## Query position index and register nearby objects
## This is the core of AAA streaming - objects are discovered by distance, not by cell
## OPTIMIZED: Query MID tier immediately for fast initial load, FAR tier progressively
func _update_aaa_streaming(camera_pos: Vector3) -> void:
	if not _position_index:
		if debug_enabled and (_frame_count % 60) == 0:
			print("[ObjectStreamer] AAA: No position index set!")
		return

	# During initial load, query every frame for fast population
	# After initial load is complete, reduce to periodic queries
	var query_interval := 1 if not _aaa_initial_load_complete else _aaa_query_interval_frames
	if (_frame_count - _aaa_last_query_frame) < query_interval:
		return

	_aaa_last_query_frame = _frame_count

	# Get objects from position index
	if not _position_index.has_method("get_objects_within_radius"):
		if debug_enabled:
			print("[ObjectStreamer] AAA: Position index has no get_objects_within_radius method!")
		return

	# Check if position index is built
	if _position_index.has_method("is_built") and not _position_index.is_built():
		if debug_enabled:
			print("[ObjectStreamer] AAA: Position index not built yet!")
		return

	# SIMPLIFIED STRATEGY: Query MID tier immediately (covers 0-500m = the visible area)
	# FAR tier (500m-5km) uses impostors managed by ImpostorManager, not per-object tracking
	# This drastically reduces complexity and ensures all nearby objects are registered quickly
	var query_radius: float
	var total_registered := _aaa_registered_objects.size()

	if total_registered < 100:
		# Initial load - start with NEAR tier for fastest visible objects
		query_radius = NEAR_END + FADE_MARGIN  # 180m
	elif not _aaa_initial_load_complete:
		# Expand to full MID tier for complete nearby coverage
		query_radius = MID_END + FADE_MARGIN  # 530m
		# Check if we've populated MID tier well enough
		if total_registered > 500:
			_aaa_initial_load_complete = true
			print("[ObjectStreamer] AAA initial load complete: %d objects registered" % total_registered)
	else:
		# Maintenance mode - only query MID tier periodically for camera movement
		# FAR tier is handled by ImpostorManager with chunk-based rendering
		query_radius = MID_END + FADE_MARGIN

	# Query without sorting for faster results (position index already groups by cell)
	# Sorting is only useful if we need to process in strict distance order
	var nearby_objects: Array = _position_index.get_objects_within_radius(camera_pos, query_radius, false)

	# Debug: Log query result periodically (less frequently)
	if debug_enabled and (_frame_count % 180) == 0:
		print("[ObjectStreamer] AAA: radius=%.0fm found=%d registered=%d initial_done=%s" % [
			query_radius, nearby_objects.size(), total_registered, _aaa_initial_load_complete
		])

	# Register new objects that aren't tracked yet
	# During initial load, register more aggressively (up to 2000/update)
	# After initial load, register fewer (maintenance mode)
	var max_register := 2000 if not _aaa_initial_load_complete else 200
	var registered_count := 0

	for obj_pos in nearby_objects:
		if registered_count >= max_register:
			break

		# Check if already registered (O(1) dictionary lookup)
		var obj_key := _make_aaa_object_key(obj_pos.cell_grid, obj_pos.ref_num)
		if obj_key in _aaa_registered_objects:
			continue

		# Register as deferred object
		var external_id := _register_from_position_index(obj_pos)
		if external_id >= 0:
			_aaa_registered_objects[obj_key] = external_id
			registered_count += 1

	if debug_enabled and registered_count > 0:
		print("[ObjectStreamer] AAA: Registered %d new objects (total: %d)" % [
			registered_count, _aaa_registered_objects.size()
		])


## Count how many registered objects are within a given distance from camera
## Uses cached counts updated incrementally by _update_tier_counts_for_object()
## Falls back to expensive iteration only when cache is stale (e.g., after teleport)
func _count_registered_in_tier(_camera_pos: Vector3, max_distance: float) -> int:
	# Use cached counts - much faster than O(n) iteration every query
	if max_distance <= NEAR_END:
		return _cached_tier_counts["near"]
	elif max_distance <= MID_END:
		return _cached_tier_counts["mid"]
	else:
		return _cached_tier_counts["far"]


## Update cached tier counts when an object is registered
## Called from register_deferred_object() with the object's initial distance
func _update_tier_counts_for_new_object(distance: float) -> void:
	if distance <= NEAR_END:
		_cached_tier_counts["near"] += 1
		_cached_tier_counts["mid"] += 1
		_cached_tier_counts["far"] += 1
	elif distance <= MID_END:
		_cached_tier_counts["mid"] += 1
		_cached_tier_counts["far"] += 1
	elif distance <= FAR_END:
		_cached_tier_counts["far"] += 1


## Decrement cached tier counts when an object is unregistered
func _update_tier_counts_for_removed_object(distance: float) -> void:
	if distance <= NEAR_END:
		_cached_tier_counts["near"] = maxi(0, _cached_tier_counts["near"] - 1)
		_cached_tier_counts["mid"] = maxi(0, _cached_tier_counts["mid"] - 1)
		_cached_tier_counts["far"] = maxi(0, _cached_tier_counts["far"] - 1)
	elif distance <= MID_END:
		_cached_tier_counts["mid"] = maxi(0, _cached_tier_counts["mid"] - 1)
		_cached_tier_counts["far"] = maxi(0, _cached_tier_counts["far"] - 1)
	elif distance <= FAR_END:
		_cached_tier_counts["far"] = maxi(0, _cached_tier_counts["far"] - 1)


## Create a unique key for AAA object tracking
func _make_aaa_object_key(cell_grid: Vector2i, ref_num: int) -> String:
	return "%d,%d,%d" % [cell_grid.x, cell_grid.y, ref_num]


## Register an object from position index data
func _register_from_position_index(obj_pos: RefCounted) -> int:
	# Skip if no model path (except NPCs which are assembled differently)
	if obj_pos.model_path.is_empty() and obj_pos.object_type != 5:  # 5 = NPC
		return -1

	# Calculate scale vector from uniform scale
	var scale_vec: Vector3 = Vector3.ONE * obj_pos.scale

	# Register as deferred object
	return register_deferred_object(
		obj_pos.model_path,
		obj_pos.position,
		obj_pos.rotation,
		scale_vec,
		obj_pos.cell_grid,
		String(obj_pos.ref_id),
		obj_pos.ref_num
	)


## Unload objects that are too far away
## Batched unload tracking to spread work across frames
var _unload_check_batch_start: int = 0
const UNLOAD_CHECK_BATCH_SIZE: int = 500  # Objects to check per frame


func _unload_distant_objects(camera_pos: Vector3) -> void:
	# OPTIMIZATION: Spread unload checking across multiple frames
	# Instead of checking all objects every 60 frames, check a batch every frame
	if _aaa_registered_objects.is_empty():
		return

	# Unload objects beyond FAR tier (with hysteresis margin)
	var unload_radius_sq := (FAR_END + FADE_MARGIN * 2.0) * (FAR_END + FADE_MARGIN * 2.0)
	var to_unload: Array[String] = []

	# Cache camera position for faster inline distance calculation
	var cam_x: float = camera_pos.x
	var cam_y: float = camera_pos.y
	var cam_z: float = camera_pos.z

	# Get keys to iterate (need snapshot since we may modify during iteration)
	var all_keys: Array = _aaa_registered_objects.keys()
	var total_count := all_keys.size()

	# Wrap around if we've checked all objects
	if _unload_check_batch_start >= total_count:
		_unload_check_batch_start = 0

	# Check a batch of objects
	var end_idx := mini(_unload_check_batch_start + UNLOAD_CHECK_BATCH_SIZE, total_count)
	for i in range(_unload_check_batch_start, end_idx):
		var obj_key: String = all_keys[i]
		var external_id: int = _aaa_registered_objects[obj_key]

		# Get object position
		if external_id not in _external_to_pool:
			to_unload.append(obj_key)
			continue

		var pool_id: int = _external_to_pool[external_id]
		if pool_id not in _objects:
			to_unload.append(obj_key)
			continue

		var obj: StreamedObject = _objects[pool_id]

		# OPTIMIZATION: Inline distance calculation
		var dx: float = cam_x - obj.position.x
		var dy: float = cam_y - obj.position.y
		var dz: float = cam_z - obj.position.z
		var dist_sq: float = dx * dx + dy * dy + dz * dz

		if dist_sq > unload_radius_sq:
			unregister_object(external_id)
			to_unload.append(obj_key)

	# Move batch window for next frame
	_unload_check_batch_start = end_idx

	# Clean up tracking
	for obj_key in to_unload:
		_aaa_registered_objects.erase(obj_key)


## Get AAA streaming statistics
func get_aaa_stats() -> Dictionary:
	return {
		"enabled": _aaa_streaming_enabled,
		"tracked_objects": _aaa_registered_objects.size(),
		"query_interval_frames": _aaa_query_interval_frames,
		"last_query_frame": _aaa_last_query_frame,
	}

#endregion


#region Object Updates

## **UNIFIED VISIBILITY**: Process tier updates from DistanceTierManager
## OPTIMIZED: Only processes objects that need updates (tier changed or transitioning)
## Objects in stable tiers are skipped for massive FPS improvement (O(transitioning) vs O(all))
func _process_tier_changes_from_authority(delta: float) -> void:
	# Get tier changes for stats tracking
	var tier_changes: Array[Dictionary] = _distance_tier_manager.get_tier_changes_this_frame()
	_stats["tier_changes_this_frame"] = tier_changes.size()

	# Reset tier stats (will be recalculated for processed objects)
	# For unprocessed stable objects, we estimate based on registered counts
	_stats["near_visible"] = 0
	_stats["mid_visible"] = 0
	_stats["far_visible"] = 0
	_stats["hidden"] = 0

	# Track objects that need processing this frame:
	# 1. Objects with tier changes (from authority)
	# 2. Objects currently transitioning (crossfading) - tracked via is_transitioning flag
	var objects_to_process: Array[int] = []
	var transitioning_to_check: Array[int] = []

	# Add objects with tier changes (these always need processing)
	for change: Dictionary in tier_changes:
		var obj_id: int = change.get("object_id", -1)
		if obj_id >= 0 and obj_id in _external_to_pool:
			objects_to_process.append(obj_id)

	# Add transitioning objects from our tracking set
	# Use a separate tracking set instead of scanning all objects
	for external_id: int in _transitioning_objects:
		if external_id in objects_to_process:
			continue  # Already added
		if external_id in _external_to_pool:
			objects_to_process.append(external_id)

	# Process only the objects that need it
	var processed_count := 0
	for external_id: int in objects_to_process:
		var pool_id: int = _external_to_pool.get(external_id, -1)
		if pool_id < 0 or pool_id not in _objects:
			continue

		var obj: StreamedObject = _objects[pool_id]

		# Get current tier from authority
		var current_tier: int = _distance_tier_manager.get_object_tier(external_id)
		var distance: float = _camera_pos.distance_to(obj.position)

		# Update object state
		var old_tier: int = obj.current_tier
		obj.current_tier = current_tier
		obj.distance_sq = distance * distance

		# Update visibility and transitions based on tier and distance
		_update_object_state(obj, external_id, current_tier, distance, delta)

		# Update tier stats
		_increment_tier_stat(current_tier)

		# Batched logging for tier changes (accumulate, print summary periodically)
		if debug_enabled and old_tier != current_tier:
			var key := "%s→%s" % [_tier_name(old_tier), _tier_name(current_tier)]
			_tier_change_counts[key] = _tier_change_counts.get(key, 0) + 1

		# Update NEAR keepalive timer
		if obj.node3d:
			_update_near_keepalive(obj, delta)

		processed_count += 1

	_stats["objects_processed"] = processed_count
	_stats["objects_total"] = _objects.size()
	_stats["transitioning_objects"] = _transitioning_objects.size()


#region Event-Driven Fade Processing (Industry-Standard)

## EVENT-DRIVEN: Process tier changes without iterating all transitioning objects
## Complexity: O(changes + active_fades) instead of O(all_transitioning)
## This matches RDR2/Horizon Zero Dawn patterns for AAA streaming performance
func _process_tier_changes_event_driven(delta: float) -> void:
	# Step 1: Get tier changes from authority (sparse from GPU)
	var tier_changes: Array[Dictionary] = _distance_tier_manager.get_tier_changes_this_frame()
	_stats["tier_changes_this_frame"] = tier_changes.size()

	# Step 2: Process tier changes - start/update fade animations
	for change: Dictionary in tier_changes:
		var obj_id: int = change.get("object_id", -1)
		var old_tier: int = change.get("old_tier", -1)
		var new_tier: int = change.get("new_tier", -1)

		if obj_id < 0 or obj_id not in _external_to_pool:
			continue

		var pool_id: int = _external_to_pool[obj_id]
		if pool_id not in _objects:
			continue

		var obj: StreamedObject = _objects[pool_id]

		# Update object state for new tier
		obj.current_tier = new_tier

		# Apply immediate tier change (show/hide appropriate representation)
		_apply_tier_change_immediate(obj, obj_id, old_tier, new_tier)

		# Start or update fade animation
		_start_fade_animation(obj, obj_id, old_tier, new_tier)

		# Batched logging for tier changes
		if debug_enabled:
			var key := "%s→%s" % [_tier_name(old_tier), _tier_name(new_tier)]
			_tier_change_counts[key] = _tier_change_counts.get(key, 0) + 1

	# Step 3: Update active fade animations (time-based, not distance-based)
	_update_active_fades(delta)

	# Step 4: Update stats
	_stats["objects_processed"] = tier_changes.size() + _active_fades.size()
	_stats["objects_total"] = _objects.size()
	_stats["active_fades"] = _active_fades.size()


## Apply immediate tier state change (show/hide representations)
## This is separate from fade animation - it sets up the visual state
func _apply_tier_change_immediate(obj: StreamedObject, external_id: int, old_tier: int, new_tier: int) -> void:
	# Entering NEAR tier
	if new_tier == Tier.NEAR and old_tier != Tier.NEAR:
		# Queue for Node3D instantiation if not already present
		if obj.node3d == null and external_id not in _instantiation_queue:
			_instantiation_queue.append(external_id)

	# Entering MID tier
	if new_tier == Tier.MID:
		# Ensure LOD meshes are loaded
		if not obj.lod_meshes_loaded:
			_load_lod_meshes(obj)
		# Show MID representation
		if obj.lod_meshes_loaded and mid_tier_visible:
			_show_mid_tier(obj)

	# Entering FAR tier
	if new_tier == Tier.FAR:
		# Show FAR representation
		if far_tier_visible and obj.impostor_id >= 0 and _impostor_manager:
			_impostor_manager.set_lod_impostor_visible(obj.impostor_id, true)

	# Leaving NEAR tier
	if old_tier == Tier.NEAR and new_tier != Tier.NEAR:
		# Start hiding Node3D (will be handled by fade)
		pass

	# Leaving MID tier
	if old_tier == Tier.MID and new_tier != Tier.MID:
		# Hide will be handled by fade completion
		pass

	# Leaving FAR tier
	if old_tier == Tier.FAR and new_tier != Tier.FAR:
		# Hide will be handled by fade completion
		pass

	# Entering HIDDEN tier
	if new_tier == Tier.HIDDEN:
		# Immediately hide everything (no fade for HIDDEN)
		_hide_all_tiers(obj)


## Start a fade animation for a tier transition
func _start_fade_animation(obj: StreamedObject, external_id: int, old_tier: int, new_tier: int) -> void:
	# Don't animate HIDDEN transitions
	if new_tier == Tier.HIDDEN or old_tier == Tier.HIDDEN:
		return

	# Don't exceed max concurrent fades
	if _active_fades.size() >= SC.MAX_CONCURRENT_FADES:
		# Skip fade, instant transition
		_finalize_tier_transition(obj, external_id, new_tier)
		return

	# Create or update fade animation
	var fade: FadeAnimation
	if external_id in _active_fades:
		fade = _active_fades[external_id]
		# Update existing fade
		fade.from_tier = old_tier
		fade.to_tier = new_tier
		fade.start_time = Time.get_ticks_msec() / 1000.0
	else:
		fade = FadeAnimation.new()
		fade.external_id = external_id
		fade.pool_id = _external_to_pool.get(external_id, -1)
		fade.from_tier = old_tier
		fade.to_tier = new_tier
		fade.start_time = Time.get_ticks_msec() / 1000.0
		fade.duration = SC.FADE_DURATION
		_active_fades[external_id] = fade


## Update all active fade animations (time-based)
## Complexity: O(active_fades) - typically 50-200, not thousands
func _update_active_fades(delta: float) -> void:
	var current_time := Time.get_ticks_msec() / 1000.0
	var completed: Array[int] = []

	for external_id: int in _active_fades:
		var fade: FadeAnimation = _active_fades[external_id]

		# Calculate progress (0.0 to 1.0)
		var elapsed := current_time - fade.start_time
		var t := clampf(elapsed / fade.duration, 0.0, 1.0)

		# Get object
		var pool_id: int = fade.pool_id
		if pool_id < 0 or pool_id not in _objects:
			completed.append(external_id)
			continue

		var obj: StreamedObject = _objects[pool_id]

		# Apply fade to appropriate tier representation
		_apply_fade_to_object(obj, external_id, fade, t)

		# Check for completion
		if t >= 1.0:
			completed.append(external_id)

	# Finalize completed fades
	for external_id in completed:
		var fade: FadeAnimation = _active_fades[external_id]
		var pool_id: int = fade.pool_id
		if pool_id >= 0 and pool_id in _objects:
			var obj: StreamedObject = _objects[pool_id]
			_finalize_tier_transition(obj, external_id, fade.to_tier)
		_active_fades.erase(external_id)


## Apply current fade progress to object's visual representation
func _apply_fade_to_object(obj: StreamedObject, external_id: int, fade: FadeAnimation, t: float) -> void:
	var from_tier: int = fade.from_tier
	var to_tier: int = fade.to_tier

	# NEAR→MID transition
	if from_tier == Tier.NEAR and to_tier == Tier.MID:
		# Fade out NEAR (t goes 0→1, so NEAR opacity goes 1→0)
		if obj.node3d and is_instance_valid(obj.node3d):
			_apply_near_crossfade_shader(obj, 1.0 - t)
		# Fade in MID
		obj.mid_fade = t
		if mid_tier_visible:
			_update_mid_fade(obj, t)

	# MID→NEAR transition
	elif from_tier == Tier.MID and to_tier == Tier.NEAR:
		# Fade out MID (t goes 0→1, so MID opacity goes 1→0)
		obj.mid_fade = 1.0 - t
		if mid_tier_visible:
			_update_mid_fade(obj, 1.0 - t)
		# Fade in NEAR
		if obj.node3d and is_instance_valid(obj.node3d):
			_apply_near_crossfade_shader(obj, t)

	# MID→FAR transition
	elif from_tier == Tier.MID and to_tier == Tier.FAR:
		# Fade out MID
		obj.mid_fade = 1.0 - t
		if mid_tier_visible:
			_update_mid_fade(obj, 1.0 - t)
		# Fade in FAR
		obj.far_fade = t
		if far_tier_visible and obj.impostor_id >= 0 and _impostor_manager:
			_impostor_manager.set_lod_impostor_fade(obj.impostor_id, t)

	# FAR→MID transition
	elif from_tier == Tier.FAR and to_tier == Tier.MID:
		# Fade out FAR
		obj.far_fade = 1.0 - t
		if far_tier_visible and obj.impostor_id >= 0 and _impostor_manager:
			_impostor_manager.set_lod_impostor_fade(obj.impostor_id, 1.0 - t)
		# Fade in MID
		obj.mid_fade = t
		if mid_tier_visible:
			_update_mid_fade(obj, t)


## Update MID tier fade value in the batcher
func _update_mid_fade(obj: StreamedObject, fade: float) -> void:
	if not obj.multimesh_keys.is_empty() and _batcher:
		for batch_key in obj.multimesh_keys:
			_batcher.update_fade(obj.id, batch_key, fade)


## Finalize a tier transition after fade completes
func _finalize_tier_transition(obj: StreamedObject, external_id: int, final_tier: int) -> void:
	match final_tier:
		Tier.NEAR:
			# Remove crossfade shader, show NEAR fully
			_remove_near_crossfade_shader(obj)
			if obj.node3d and is_instance_valid(obj.node3d):
				obj.node3d.visible = near_tier_visible
			# Hide MID and FAR
			_hide_mid_tier(obj)
			_hide_far_tier(obj)

		Tier.MID:
			# Show MID fully, hide NEAR and FAR
			obj.mid_fade = 1.0
			_update_mid_fade(obj, 1.0)
			if obj.node3d and is_instance_valid(obj.node3d):
				obj.node3d.visible = false
			_remove_near_crossfade_shader(obj)
			_hide_far_tier(obj)

		Tier.FAR:
			# Show FAR fully, hide NEAR and MID
			obj.far_fade = 1.0
			if obj.impostor_id >= 0 and _impostor_manager:
				_impostor_manager.set_lod_impostor_fade(obj.impostor_id, 1.0)
			_hide_near_tier(obj)
			_hide_mid_tier(obj)

		Tier.HIDDEN:
			_hide_all_tiers(obj)


## Handle teleport - cancel all fades and pop instantly
func _on_teleport_detected() -> void:
	if debug_enabled:
		print("[ObjectStreamer] Teleport detected, clearing %d active fades" % _active_fades.size())

	# Clear all active fades
	_active_fades.clear()

	# The next tier update will set objects to their correct tier instantly


## Hide NEAR tier representation
func _hide_near_tier(obj: StreamedObject) -> void:
	if obj.node3d and is_instance_valid(obj.node3d):
		obj.node3d.visible = false
	obj.near_visible = false
	_remove_near_crossfade_shader(obj)


## Hide all tiers
func _hide_all_tiers(obj: StreamedObject) -> void:
	_hide_near_tier(obj)
	_hide_mid_tier(obj)
	_hide_far_tier(obj)

#endregion


## Helper to get tier name for debug logging
func _tier_name(tier: int) -> String:
	match tier:
		Tier.NEAR: return "NEAR"
		Tier.MID: return "MID"
		Tier.FAR: return "FAR"
		Tier.HIDDEN: return "HIDDEN"
		4: return "NONE"  # DistanceTierManager.Tier.NONE (not registered)
		_: return "T%d" % tier


## Print batched tier change summary (called periodically instead of per-object logging)
func _print_tier_change_summary() -> void:
	if _tier_change_counts.is_empty():
		return

	var parts: Array[String] = []
	for key: String in _tier_change_counts:
		parts.append("%s: %d" % [key, _tier_change_counts[key]])

	print("[ObjectStreamer] Tier changes: %s" % ", ".join(parts))
	_tier_change_counts.clear()


## Update object visibility, fade, and LOD state based on current tier and distance
## Called only for objects that need updates (tier changes or transitioning)
func _update_object_state(obj: StreamedObject, external_id: int, tier: int, distance: float, delta: float) -> void:
	match tier:
		Tier.NEAR:
			_update_near_state(obj, external_id, distance, delta)
		Tier.MID:
			_update_mid_state(obj, distance, delta)
		Tier.FAR:
			_update_far_state(obj, external_id, distance, delta)
		Tier.HIDDEN:
			_update_hidden_state(obj)

	# Update transitioning flag based on fade states
	# Object is transitioning if any fade value is between 0 and 1 (exclusive)
	var now_transitioning := _is_object_transitioning(obj, distance)
	obj.is_transitioning = now_transitioning

	# Update transitioning tracking set
	if now_transitioning:
		_transitioning_objects[external_id] = true
	elif external_id in _transitioning_objects:
		_transitioning_objects.erase(external_id)


## Update NEAR tier state (full Node3D with crossfade at boundaries)
func _update_near_state(obj: StreamedObject, external_id: int, distance: float, _delta: float) -> void:
	# Calculate fade at NEAR/MID boundary
	var fade_amount := 1.0
	if distance > NEAR_END - FADE_MARGIN:
		fade_amount = clampf((NEAR_END + FADE_MARGIN - distance) / (2.0 * FADE_MARGIN), 0.0, 1.0)

	if near_tier_visible:
		if obj.node3d and is_instance_valid(obj.node3d):
			obj.node3d.visible = true
			obj.near_visible = true
			obj.near_hidden_time = 0.0

			# Apply crossfade shader at boundary
			if fade_amount < 1.0:
				_apply_near_crossfade_shader(obj, fade_amount)
			else:
				_remove_near_crossfade_shader(obj)
		elif obj.node3d == null:
			# Request instantiation if not already queued
			if external_id not in _instantiation_queue:
				if external_id in _pending_recreations:
					node_recreation_requested.emit(external_id, obj.cell_grid, obj.ref_num)
				else:
					_request_instantiation(obj, external_id)
	else:
		if obj.node3d and is_instance_valid(obj.node3d):
			obj.node3d.visible = false
		obj.near_visible = false
		_remove_near_crossfade_shader(obj)

	# Hide MID tier when in NEAR
	if obj.mid_visible:
		_set_mid_fade(obj, 1.0 - fade_amount)
		if fade_amount >= 1.0:
			_hide_mid_tier(obj)


## Update MID tier state (LOD meshes with dynamic LOD level switching)
func _update_mid_state(obj: StreamedObject, distance: float, _delta: float) -> void:
	if not obj.is_significant:
		# Non-significant objects: Fade out and hide aggressively to save draw calls
		# They don't have LODs, so we cull them early (by 250m instead of 500m)
		# This is a major performance optimization - reduces primitive count significantly
		const NON_SIG_FADEOUT_END: float = 250.0  # Fully hidden by 250m
		if obj.node3d and is_instance_valid(obj.node3d):
			if near_tier_visible and distance < NON_SIG_FADEOUT_END:
				obj.node3d.visible = true
				obj.near_visible = true
				# Fade from full at NEAR_END (150m) to invisible at 250m
				var fade := clampf((NON_SIG_FADEOUT_END - distance) / (NON_SIG_FADEOUT_END - NEAR_END), 0.0, 1.0)
				_apply_near_crossfade_shader(obj, fade)
			else:
				# Beyond fadeout distance - hide completely
				obj.node3d.visible = false
				obj.near_visible = false
				_remove_near_crossfade_shader(obj)
		return

	# Calculate fade at boundaries
	var fade_near := 0.0
	var fade_far := 1.0

	# Fade from NEAR
	if distance < NEAR_END + FADE_MARGIN:
		fade_near = clampf((distance - (NEAR_END - FADE_MARGIN)) / (2.0 * FADE_MARGIN), 0.0, 1.0)

	# Fade to FAR
	if distance > MID_END - FADE_MARGIN:
		fade_far = clampf((MID_END + FADE_MARGIN - distance) / (2.0 * FADE_MARGIN), 0.0, 1.0)

	var effective_fade := minf(fade_near, fade_far)

	if not mid_tier_visible:
		effective_fade = 0.0
		if obj.mid_visible:
			_hide_mid_tier(obj)
	else:
		if not obj.mid_visible:
			_show_mid_tier(obj)

		# Dynamic LOD level switching based on distance
		_update_mid_lod_level(obj, distance)

		_set_mid_fade(obj, effective_fade)

	# Hide NEAR tier when in MID
	if obj.node3d and is_instance_valid(obj.node3d):
		if fade_near < 1.0:
			_apply_near_crossfade_shader(obj, 1.0 - fade_near)
		else:
			obj.node3d.visible = false
			obj.near_visible = false
			_remove_near_crossfade_shader(obj)

	# Update FAR tier fade
	if distance > MID_END - FADE_MARGIN:
		_set_far_fade(obj, 1.0 - fade_far)
		if fade_far <= 0.0:
			_hide_far_tier(obj)


## Update FAR tier state (impostors with crossfade)
func _update_far_state(obj: StreamedObject, external_id: int, distance: float, _delta: float) -> void:
	if not obj.is_significant:
		# Non-significant objects: They've faded out through MID tier
		# At FAR distance, hide completely (no impostor available)
		if obj.node3d and is_instance_valid(obj.node3d):
			obj.node3d.visible = false
			obj.near_visible = false
		_remove_near_crossfade_shader(obj)
		_hide_mid_tier(obj)
		return

	# Calculate fade at MID/FAR boundary (fade in from MID)
	var fade_in := 1.0
	if distance < MID_END + FADE_MARGIN:
		fade_in = clampf((distance - (MID_END - FADE_MARGIN)) / (2.0 * FADE_MARGIN), 0.0, 1.0)

	# Calculate fade at FAR/HIDDEN boundary (fade out to HIDDEN)
	var fade_out := 1.0
	if distance > FAR_END - FADE_MARGIN:
		fade_out = clampf((FAR_END + FADE_MARGIN - distance) / (2.0 * FADE_MARGIN), 0.0, 1.0)

	# Combined fade amount (whichever is limiting)
	var fade_amount := minf(fade_in, fade_out)

	if not far_tier_visible:
		if obj.far_visible:
			_hide_far_tier(obj)
	else:
		if not obj.far_visible:
			_show_far_tier(obj)
		_set_far_fade(obj, fade_amount)

	# Hide MID tier
	_set_mid_fade(obj, 1.0 - fade_in)
	if fade_in >= 1.0:
		_hide_mid_tier(obj)


## Update HIDDEN state (everything hidden)
func _update_hidden_state(obj: StreamedObject) -> void:
	if obj.node3d and is_instance_valid(obj.node3d):
		obj.node3d.visible = false
	_remove_near_crossfade_shader(obj)
	_hide_mid_tier(obj)
	_hide_far_tier(obj)


## Check if object is in a transitional state (crossfading between tiers)
## Objects in transition need per-frame updates for smooth fading
func _is_object_transitioning(obj: StreamedObject, distance: float) -> bool:
	# Check NEAR boundary transition
	if distance > NEAR_END - FADE_MARGIN and distance < NEAR_END + FADE_MARGIN:
		return true
	# Check MID/FAR boundary transition
	if distance > MID_END - FADE_MARGIN and distance < MID_END + FADE_MARGIN:
		return true
	# Check FAR/HIDDEN boundary transition
	if distance > FAR_END - FADE_MARGIN and distance < FAR_END + FADE_MARGIN:
		return true
	# Check if MID/FAR fade values are in transition
	if obj.mid_fade > 0.0 and obj.mid_fade < 1.0:
		return true
	if obj.far_fade > 0.0 and obj.far_fade < 1.0:
		return true
	return false


func _update_near_keepalive(obj: StreamedObject, delta: float) -> void:
	if not obj.near_visible and obj.node3d and is_instance_valid(obj.node3d):
		obj.near_hidden_time += delta

		if obj.near_hidden_time >= near_keepalive_time:
			# Mark for recreation if it returns to NEAR
			var external_id := _get_external_id(obj)
			if external_id >= 0:
				_pending_recreations[external_id] = true

			if debug_enabled:
				print("[ObjectStreamer] Freeing Node3D for #%d after %.1fs (will recreate if returns to NEAR)" % [
					external_id, obj.near_hidden_time
				])

			obj.node3d.queue_free()
			obj.node3d = null


## Increment tier stat
func _increment_tier_stat(tier: int) -> void:
	match tier:
		Tier.NEAR: _stats["near_visible"] += 1
		Tier.MID: _stats["mid_visible"] += 1
		Tier.FAR: _stats["far_visible"] += 1
		Tier.HIDDEN: _stats["hidden"] += 1

#endregion


#region MID Tier

## Request async loading of LOD meshes for an object
## Uses cache if available, otherwise starts async load
func _load_lod_meshes(obj: StreamedObject) -> void:
	if obj.lod_meshes_loaded:
		return

	var model_path := obj.model_path

	# Check cache first - instant if already loaded
	if model_path in _lod_mesh_cache:
		_apply_cached_lod_meshes(obj)
		_stats["lod_cache_hits"] += 1
		return

	# Check if already loading for this model
	if model_path in _pending_lod_loads:
		# Add this object to waiting list
		var pending: Dictionary = _pending_lod_loads[model_path]
		if obj.id not in pending["objects"]:
			(pending["objects"] as Array).append(obj.id)
		return

	# Start async load for all 3 LOD levels
	_start_async_lod_load(obj)


## Start async loading for LOD meshes
func _start_async_lod_load(obj: StreamedObject) -> void:
	var model_path := obj.model_path

	# Initialize pending entry
	_pending_lod_loads[model_path] = {
		"loading": true,
		"objects": [obj.id],
		"levels_pending": 3,
		"meshes": {}  # lod_level -> ArrayMesh (filled as loads complete)
	}
	_stats["lod_pending_loads"] = _pending_lod_loads.size()

	# Submit async load requests for each LOD level
	for lod_level in [1, 2, 3]:
		var lod_path := LODPrebakerScript.get_lod_path(model_path, lod_level)
		if ResourceLoader.exists(lod_path):
			var err := ResourceLoader.load_threaded_request(lod_path, "ArrayMesh")
			if err != OK:
				# Fallback to sync if async fails
				_handle_lod_load_error(model_path, lod_level)
		else:
			# No LOD file exists - mark as complete with null
			_on_lod_level_loaded(model_path, lod_level, null)


## Poll for completed async LOD loads - called from update()
func _poll_pending_lod_loads() -> void:
	if _pending_lod_loads.is_empty():
		return

	var completed_models: Array[String] = []

	for model_path: String in _pending_lod_loads:
		var pending: Dictionary = _pending_lod_loads[model_path]

		# Check each pending LOD level
		for lod_level in [1, 2, 3]:
			if lod_level in pending["meshes"]:
				continue  # Already loaded

			var lod_path := LODPrebakerScript.get_lod_path(model_path, lod_level)
			var status := ResourceLoader.load_threaded_get_status(lod_path)

			match status:
				ResourceLoader.THREAD_LOAD_LOADED:
					var mesh: ArrayMesh = ResourceLoader.load_threaded_get(lod_path) as ArrayMesh
					_on_lod_level_loaded(model_path, lod_level, mesh)
				ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
					_on_lod_level_loaded(model_path, lod_level, null)
				# THREAD_LOAD_IN_PROGRESS - still loading, continue

		# Check if all levels complete
		if pending["meshes"].size() >= 3:
			completed_models.append(model_path)

	# Process completed models
	for model_path: String in completed_models:
		_finalize_lod_load(model_path)


## Called when a single LOD level finishes loading
func _on_lod_level_loaded(model_path: String, lod_level: int, mesh: ArrayMesh) -> void:
	if model_path not in _pending_lod_loads:
		return

	var pending: Dictionary = _pending_lod_loads[model_path]
	pending["meshes"][lod_level] = mesh  # May be null if load failed


## Handle LOD load error - sync fallback
func _handle_lod_load_error(model_path: String, lod_level: int) -> void:
	# Try sync load as fallback
	var mesh: ArrayMesh = LODPrebakerScript.load_lod_mesh(model_path, lod_level)
	_on_lod_level_loaded(model_path, lod_level, mesh)


## Called when all LOD levels for a model are loaded
func _finalize_lod_load(model_path: String) -> void:
	if model_path not in _pending_lod_loads:
		return

	var pending: Dictionary = _pending_lod_loads[model_path]

	# Build cache entry
	var cache_entry: Dictionary = {}
	for lod_level in [1, 2, 3]:
		var mesh: ArrayMesh = pending["meshes"].get(lod_level)
		if mesh:
			cache_entry[lod_level] = mesh

	# Only cache if we got at least one LOD
	if not cache_entry.is_empty():
		_lod_mesh_cache[model_path] = cache_entry
		_stats["lod_cache_size"] = _lod_mesh_cache.size()

	# Apply to all waiting objects
	var waiting_objects: Array = pending["objects"]
	for external_id: int in waiting_objects:
		var pool_id: Variant = _external_to_pool.get(external_id)
		if pool_id == null:
			continue
		var obj: StreamedObject = _objects.get(pool_id)
		if obj and not obj.lod_meshes_loaded:
			_apply_cached_lod_meshes(obj)

	# Cleanup
	_pending_lod_loads.erase(model_path)
	_stats["lod_pending_loads"] = _pending_lod_loads.size()


## Apply cached LOD meshes to an object
func _apply_cached_lod_meshes(obj: StreamedObject) -> void:
	if obj.lod_meshes_loaded:
		return

	var cache_entry: Variant = _lod_mesh_cache.get(obj.model_path)
	if cache_entry == null:
		obj.lod_meshes_loaded = true  # Mark as loaded even if empty
		return

	obj.lod_meshes_loaded = true

	# Apply in order: LOD1, LOD2, LOD3
	for lod_level in [1, 2, 3]:
		var lod_mesh: ArrayMesh = (cache_entry as Dictionary).get(lod_level)
		if lod_mesh:
			obj.lod_meshes.append(lod_mesh)

			var materials: Array[Material] = []
			for surf_idx in range(lod_mesh.get_surface_count()):
				var mat := lod_mesh.surface_get_material(surf_idx)
				if mat:
					materials.append(mat)
			obj.lod_materials.append(materials)


func _get_mid_lod_level(distance: float) -> int:
	if distance < MID_LOD1_END:
		return 0
	elif distance < MID_LOD2_END:
		return 1
	else:
		return 2


## Update LOD level within MID tier based on distance
## This enables dynamic LOD switching (LOD1 → LOD2 → LOD3) as distance changes
func _update_mid_lod_level(obj: StreamedObject, distance: float) -> void:
	if not obj.mid_visible or obj.lod_meshes.is_empty():
		return

	var target_lod_idx := _get_mid_lod_level(distance)
	target_lod_idx = mini(target_lod_idx, obj.lod_meshes.size() - 1)

	# Only switch if LOD level changed
	if target_lod_idx == obj.current_mid_lod_idx:
		return

	# Remove old LOD instance
	for batch_key in obj.multimesh_keys:
		_batcher.remove_instance(obj.id, batch_key)
	obj.multimesh_keys.clear()

	# Add new LOD instance
	var lod_mesh: ArrayMesh = obj.lod_meshes[target_lod_idx]
	var lod_materials: Array = obj.lod_materials[target_lod_idx] if target_lod_idx < obj.lod_materials.size() else []
	var lod_level := target_lod_idx + 1

	var typed_materials: Array[Material] = []
	for mat in lod_materials:
		if mat is Material:
			typed_materials.append(mat)

	var batch_key: int = _batcher.add_instance(
		lod_mesh,
		lod_level,
		obj.transform,
		obj.id,
		obj.mid_fade,
		typed_materials
	)
	obj.multimesh_keys.append(batch_key)
	obj.current_mid_lod_idx = target_lod_idx

	# Phase 2: Register with GPU visibility renderer
	if _gpu_driven_enabled and _gpu_visibility_renderer:
		var external_id: int = _pool_to_external.get(obj.id, -1)
		if external_id >= 0:
			_register_object_with_gpu_batch(external_id, obj, batch_key)


func _show_mid_tier(obj: StreamedObject) -> void:
	if obj.mid_visible:
		return

	if not obj.lod_meshes_loaded and obj.is_significant:
		_load_lod_meshes(obj)

	if obj.lod_meshes.is_empty():
		return

	var distance := sqrt(obj.distance_sq)
	var lod_idx := _get_mid_lod_level(distance)
	lod_idx = mini(lod_idx, obj.lod_meshes.size() - 1)

	if lod_idx < 0:
		return

	var lod_mesh: ArrayMesh = obj.lod_meshes[lod_idx]
	var lod_materials: Array = obj.lod_materials[lod_idx] if lod_idx < obj.lod_materials.size() else []
	var lod_level := lod_idx + 1

	var typed_materials: Array[Material] = []
	for mat: Variant in lod_materials:
		if mat is Material:
			typed_materials.append(mat)

	var batch_key: int = _batcher.add_instance(
		lod_mesh,
		lod_level,
		obj.transform,
		obj.id,
		0.0,
		typed_materials
	)
	obj.multimesh_keys.append(batch_key)
	obj.current_mid_lod_idx = lod_idx
	obj.mid_visible = true

	# Phase 2: Register with GPU visibility renderer
	if _gpu_driven_enabled and _gpu_visibility_renderer:
		var external_id: int = _pool_to_external.get(obj.id, -1)
		if external_id >= 0:
			_register_object_with_gpu_batch(external_id, obj, batch_key)


func _hide_mid_tier(obj: StreamedObject) -> void:
	if not obj.mid_visible:
		return

	# Phase 2: Unregister from GPU visibility renderer before removing from batcher
	if _gpu_driven_enabled and _gpu_visibility_renderer:
		var external_id: int = _pool_to_external.get(obj.id, -1)
		if external_id >= 0:
			for batch_key: int in obj.multimesh_keys:
				_unregister_object_from_gpu_batch(external_id, batch_key)

	for batch_key: int in obj.multimesh_keys:
		_batcher.remove_instance(obj.id, batch_key)
	obj.multimesh_keys.clear()

	obj.mid_visible = false
	obj.mid_fade = 0.0
	obj.current_mid_lod_idx = -1


func _set_mid_fade(obj: StreamedObject, fade: float) -> void:
	obj.mid_fade = clampf(fade, 0.0, 1.0)
	for batch_key: int in obj.multimesh_keys:
		_batcher.update_fade(obj.id, batch_key, obj.mid_fade)

#endregion


#region FAR Tier

func _show_far_tier(obj: StreamedObject) -> void:
	if obj.far_visible or not _impostor_manager:
		return

	if not _impostor_manager.has_method("add_impostor"):
		return

	var rotation: Vector3 = obj.transform.basis.get_euler()
	var scale: Vector3 = obj.transform.basis.get_scale()

	# Pass object pool ID so ImpostorManager can register when texture loads async
	# This fixes the race condition where add_impostor returns -1 (texture loading)
	# but the impostor is never linked back to the object when ready
	obj.impostor_id = _impostor_manager.call(
		"add_impostor",
		obj.model_path,
		obj.position,
		rotation,
		scale,
		obj.cell_grid,
		obj.id  # lod_object_id for deferred registration
	)

	if obj.impostor_id >= 0:
		obj.far_visible = true
		obj.far_fade = 1.0  # Fully visible immediately when texture was cached
		# Note: register_lod_managed_impostor is now called by ImpostorManager.add_impostor
		# when texture is already loaded, or by _on_texture_loaded when it finishes async
	elif obj.impostor_id == -1:
		# Impostor is pending (texture loading) - mark as far_visible so we don't re-request
		# The ImpostorManager will auto-register via lod_object_id when texture loads
		# Start with full visibility - will be set properly when texture loads
		obj.far_visible = true
		obj.far_fade = 1.0


func _hide_far_tier(obj: StreamedObject) -> void:
	if not obj.far_visible or not _impostor_manager:
		return

	# Always unregister from LOD tracking (handles both created and pending impostors)
	if _impostor_manager.has_method("unregister_lod_managed_impostor"):
		_impostor_manager.call("unregister_lod_managed_impostor", obj.id)

	# Remove actual impostor if it was created
	if obj.impostor_id >= 0 and _impostor_manager.has_method("remove_impostor"):
		_impostor_manager.call("remove_impostor", obj.impostor_id)

	# Cancel pending impostor if still waiting for texture
	if obj.impostor_id == -1 and _impostor_manager.has_method("cancel_pending_for_lod_object"):
		_impostor_manager.call("cancel_pending_for_lod_object", obj.id)

	obj.impostor_id = -1
	obj.far_visible = false
	obj.far_fade = 0.0


func _set_far_fade(obj: StreamedObject, fade: float) -> void:
	obj.far_fade = clampf(fade, 0.0, 1.0)
	if not _impostor_manager:
		return

	# If impostor_id is -1 but far_visible is true, the texture may have loaded async
	# Try to get the impostor_id from ImpostorManager's LOD tracking
	if obj.impostor_id == -1 and obj.far_visible:
		if _impostor_manager.has_method("get_lod_impostor_id"):
			var fetched_id: int = _impostor_manager.call("get_lod_impostor_id", obj.id)
			if fetched_id >= 0:
				obj.impostor_id = fetched_id

	# Now set the fade if we have a valid impostor
	if obj.impostor_id >= 0 or obj.far_visible:
		if _impostor_manager.has_method("set_lod_impostor_fade"):
			_impostor_manager.call("set_lod_impostor_fade", obj.id, obj.far_fade)

#endregion


#region NEAR Tier Crossfade

## Apply crossfade shader to Node3D during NEAR tier transitions
## This creates a material_override with dithering shader for smooth fade-in/out
func _apply_near_crossfade_shader(obj: StreamedObject, fade: float) -> void:
	if not obj.node3d or not is_instance_valid(obj.node3d):
		return

	if not _node3d_crossfade_shader:
		return

	var external_id := _get_external_id(obj)
	if external_id < 0:
		return

	# Check if we already have a crossfade active for this object
	if external_id in _active_near_crossfades:
		# Just update the fade amount
		var crossfade_data: Dictionary = _active_near_crossfades[external_id]
		var mat: ShaderMaterial = crossfade_data.get("material")
		if mat:
			mat.set_shader_parameter("fade_amount", clampf(fade, 0.0, 1.0))
		return

	# First time applying crossfade - need to create material override
	var mesh_instance: MeshInstance3D = null

	# Find MeshInstance3D child (most common case)
	for child in obj.node3d.get_children():
		if child is MeshInstance3D:
			mesh_instance = child
			break

	if not mesh_instance:
		# Check if the node itself is a MeshInstance3D
		if obj.node3d is MeshInstance3D:
			mesh_instance = obj.node3d

	if not mesh_instance:
		return  # No mesh to apply shader to

	# Store original materials so we can restore them later
	var original_materials: Array[Material] = []
	var mesh := mesh_instance.mesh
	if mesh:
		for surf_idx in range(mesh.get_surface_count()):
			var mat := mesh_instance.get_surface_override_material(surf_idx)
			if not mat:
				mat = mesh.surface_get_material(surf_idx)
			original_materials.append(mat)

	# Create crossfade material based on first surface material
	var crossfade_mat := ShaderMaterial.new()
	crossfade_mat.shader = _node3d_crossfade_shader
	crossfade_mat.set_shader_parameter("fade_amount", clampf(fade, 0.0, 1.0))

	# Copy properties from original material if it's a StandardMaterial3D
	if not original_materials.is_empty() and original_materials[0]:
		var src_mat := original_materials[0]
		if src_mat is StandardMaterial3D:
			var std_mat: StandardMaterial3D = src_mat

			# Copy textures and colors
			if std_mat.albedo_texture:
				crossfade_mat.set_shader_parameter("albedo_texture", std_mat.albedo_texture)
			crossfade_mat.set_shader_parameter("albedo_color", std_mat.albedo_color)

			if std_mat.normal_texture:
				crossfade_mat.set_shader_parameter("normal_texture", std_mat.normal_texture)
				crossfade_mat.set_shader_parameter("normal_scale", std_mat.normal_scale)

			crossfade_mat.set_shader_parameter("roughness", std_mat.roughness)
			crossfade_mat.set_shader_parameter("metallic", std_mat.metallic)
			crossfade_mat.set_shader_parameter("specular", std_mat.specular)

			# Alpha cutout support
			if std_mat.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
				crossfade_mat.set_shader_parameter("use_alpha_cutout", true)
				crossfade_mat.set_shader_parameter("alpha_cutout", std_mat.alpha_scissor_threshold)

	# Apply material_override (affects all surfaces)
	mesh_instance.material_override = crossfade_mat

	# Track this crossfade so we can update fade and remove later
	_active_near_crossfades[external_id] = {
		"material": crossfade_mat,
		"originals": original_materials,
		"mesh_instance": mesh_instance
	}


## Remove crossfade shader from Node3D and restore original materials
func _remove_near_crossfade_shader(obj: StreamedObject) -> void:
	var external_id := _get_external_id(obj)
	if external_id < 0:
		return

	if external_id not in _active_near_crossfades:
		return  # No crossfade active

	var crossfade_data: Dictionary = _active_near_crossfades[external_id]
	var mesh_instance: MeshInstance3D = crossfade_data.get("mesh_instance")

	if mesh_instance and is_instance_valid(mesh_instance):
		# Remove material override to restore originals
		mesh_instance.material_override = null

	# Clean up tracking
	_active_near_crossfades.erase(external_id)

#endregion


#region Spatial Hash

func _add_to_spatial_hash(obj: StreamedObject) -> void:
	var cell := _get_spatial_cell(obj.position)
	if cell not in _spatial_hash:
		_spatial_hash[cell] = []
	(_spatial_hash[cell] as Array).append(obj.id)


func _remove_from_spatial_hash(obj: StreamedObject) -> void:
	var cell := _get_spatial_cell(obj.position)
	if cell in _spatial_hash:
		(_spatial_hash[cell] as Array).erase(obj.id)
		if (_spatial_hash[cell] as Array).is_empty():
			_spatial_hash.erase(cell)


func _get_spatial_cell(pos: Vector3) -> Vector2i:
	return Vector2i(
		int(floor(pos.x / SPATIAL_HASH_CELL_SIZE)),
		int(floor(pos.z / SPATIAL_HASH_CELL_SIZE))
	)


func get_objects_near(pos: Vector3, radius: float) -> Array[int]:
	var result: Array[int] = []
	var radius_cells := int(ceil(radius / SPATIAL_HASH_CELL_SIZE))
	var center_cell := _get_spatial_cell(pos)

	for dx in range(-radius_cells, radius_cells + 1):
		for dz in range(-radius_cells, radius_cells + 1):
			var cell := Vector2i(center_cell.x + dx, center_cell.y + dz)
			if cell in _spatial_hash:
				for pool_id: int in _spatial_hash[cell]:
					# Convert to external ID using O(1) reverse mapping
					var ext_id: int = _pool_to_external.get(pool_id, -1)
					if ext_id >= 0:
						result.append(ext_id)

	return result

#endregion


#region Helpers

func _cleanup_object(obj: StreamedObject) -> void:
	_remove_near_crossfade_shader(obj)
	_hide_mid_tier(obj)
	_hide_far_tier(obj)

	obj.lod_meshes.clear()
	obj.lod_materials.clear()
	obj.node3d = null
	obj.node3d_parent = null
	obj.near_visible = false
	obj.mid_visible = false
	obj.far_visible = false
	obj.lod_meshes_loaded = false


func _get_external_id(obj: StreamedObject) -> int:
	return _pool_to_external.get(obj.id, -1)


## Queue an object for instantiation
## Uses time-budgeted queue instead of immediate emission for smooth frame times
func _request_instantiation(obj: StreamedObject, external_id: int) -> void:
	# Add to queue if not already queued
	if external_id in _instantiation_queue:
		return

	_instantiation_queue.append(external_id)
	_stats["instantiation_queue_size"] = _instantiation_queue.size()
	# Note: Per-object queue logging removed - use get_stats() for queue size


## Track when queue was last sorted to avoid re-sorting every frame
var _queue_last_sort_frame: int = -100
const QUEUE_SORT_INTERVAL: int = 30  # Only sort every 30 frames (0.5s at 60fps)


## Process instantiation queue with time budget
## Call this from update() - returns number of objects instantiated
func process_instantiation_queue(camera_pos: Vector3) -> int:
	if _instantiation_queue.is_empty():
		return 0

	var start_time := Time.get_ticks_usec()
	var instantiated := 0

	# OPTIMIZATION: Only sort periodically or when queue changed significantly
	# Sorting is O(n log n) and was causing major frame spikes with large queues
	if _frame_count - _queue_last_sort_frame > QUEUE_SORT_INTERVAL:
		_sort_instantiation_queue_by_distance(camera_pos)
		_queue_last_sort_frame = _frame_count

	# Process queue within budget
	while not _instantiation_queue.is_empty() and instantiated < max_instantiations_per_frame:
		# Check time budget
		var elapsed_ms := (Time.get_ticks_usec() - start_time) / 1000.0
		if elapsed_ms >= instantiation_budget_ms:
			break

		var external_id: int = _instantiation_queue.pop_front()

		# Get object
		if external_id not in _external_to_pool:
			continue

		var pool_id: int = _external_to_pool[external_id]
		if pool_id not in _objects:
			continue

		var obj: StreamedObject = _objects[pool_id]

		# Double-check still needs instantiation
		if obj.node3d != null:
			continue

		# Check if still in NEAR range
		var distance := camera_pos.distance_to(obj.position)
		if distance >= NEAR_END:
			continue

		# Emit signal for WorldStreamingManager/CellManager to handle actual instantiation
		instantiation_requested.emit(
			external_id,
			obj.model_path,
			obj.transform,
			obj.cell_grid,
			obj.ref_id,
			obj.ref_num
		)

		instantiated += 1

	_stats["instantiation_queue_size"] = _instantiation_queue.size()
	_stats["instantiations_this_frame"] = instantiated

	if instantiated > 0:
		instantiation_queue_changed.emit(_instantiation_queue.size())
		# Note: Per-frame instantiation logging removed - use get_stats() instead

	return instantiated


## Sort instantiation queue by distance to camera (closest first)
func _sort_instantiation_queue_by_distance(camera_pos: Vector3) -> void:
	# Create array of [distance_sq, external_id] for sorting
	var sortable: Array = []
	for external_id: int in _instantiation_queue:
		if external_id not in _external_to_pool:
			continue

		var pool_id: int = _external_to_pool[external_id]
		if pool_id not in _objects:
			continue

		var obj: StreamedObject = _objects[pool_id]
		var dist_sq := camera_pos.distance_squared_to(obj.position)
		sortable.append([dist_sq, external_id])

	# Sort by distance (ascending)
	sortable.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])

	# Rebuild queue
	_instantiation_queue.clear()
	for entry: Array in sortable:
		_instantiation_queue.append(entry[1] as int)


## Get number of objects waiting for instantiation
func get_instantiation_queue_size() -> int:
	return _instantiation_queue.size()


## Check if an object is pending recreation
func is_pending_recreation(external_id: int) -> bool:
	return external_id in _pending_recreations


## Get objects pending recreation for a specific cell
func get_pending_recreations_for_cell(cell_grid: Vector2i) -> Array[int]:
	var result: Array[int] = []
	for external_id: int in _pending_recreations:
		if external_id not in _external_to_pool:
			continue

		var pool_id: int = _external_to_pool[external_id]
		if pool_id not in _objects:
			continue

		var obj: StreamedObject = _objects[pool_id]
		if obj.cell_grid == cell_grid:
			result.append(external_id)

	return result


## Set object's Node3D after recreation
## Used by WorldStreamingManager when it recreates a node
func set_object_node3d(external_id: int, node3d: Node3D) -> void:
	on_object_instantiated(external_id, node3d)


func _apply_tier_visibility() -> void:
	for pool_id: int in _objects:
		var obj: StreamedObject = _objects[pool_id]
		_apply_object_visibility(obj)


func _apply_object_visibility(obj: StreamedObject) -> void:
	# NEAR
	if obj.node3d and is_instance_valid(obj.node3d):
		var should_show := near_tier_visible and obj.current_tier == Tier.NEAR
		obj.node3d.visible = should_show
		obj.near_visible = should_show

	# MID
	if obj.current_tier == Tier.MID and obj.is_significant:
		if mid_tier_visible:
			if not obj.mid_visible:
				_show_mid_tier(obj)
				obj.mid_fade = 1.0
				_set_mid_fade(obj, 1.0)
		else:
			if obj.mid_visible:
				_hide_mid_tier(obj)
	elif obj.mid_visible:
		_hide_mid_tier(obj)

	# FAR
	if obj.current_tier == Tier.FAR and obj.is_significant:
		if far_tier_visible:
			if not obj.far_visible:
				_show_far_tier(obj)
				obj.far_fade = 1.0
				_set_far_fade(obj, 1.0)
		else:
			if obj.far_visible:
				_hide_far_tier(obj)
	elif obj.far_visible:
		_hide_far_tier(obj)


func _update_stats() -> void:
	_stats["total_objects"] = _objects.size()
	_stats["pool_size"] = _object_pool.size()
	_stats["pool_available"] = _pool_available.size()

	# Use incremental counters instead of O(n) iteration
	# These are updated in register_object(), register_deferred_object(),
	# on_object_instantiated(), and unregister_object()
	_stats["deferred_objects"] = _deferred_count
	_stats["instantiated_objects"] = _instantiated_count


## Hide all objects immediately (called when disabling streaming)
func _hide_all_objects() -> void:
	for pool_id: int in _objects:
		var obj: StreamedObject = _objects[pool_id]

		# Hide NEAR tier
		if obj.node3d and is_instance_valid(obj.node3d):
			obj.node3d.visible = false

		# Hide MID tier
		if obj.mid_visible:
			_hide_mid_tier(obj)

		# Hide FAR tier
		if obj.far_visible:
			_hide_far_tier(obj)

#endregion
