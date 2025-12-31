## ObjectStreamer - Unified distance-based object streaming (ENHANCED)
##
## Consolidates DistanceTierManager + ObjectDistanceManager into a single system.
## This is the result of Phase 1 refactoring with best features merged.
##
## Key features (merged from ObjectDistanceManager):
## - Object pooling for efficient memory management
## - Time-budgeted instantiation queue for smooth frame times
## - AAA streaming via ObjectPositionIndex (Phase 2B)
## - Detailed statistics and node recreation tracking
## - Configurable pool size
##
## Tier System:
## - NEAR (0-150m): Full Node3D with physics/collision
## - MID (150-500m): LOD meshes via MultiMesh (visual only)
## - FAR (500m-5km): Octahedral impostors
## - HIDDEN (5km+): Not rendered
##
## Usage:
##   var streamer := ObjectStreamer.new()
##   add_child(streamer)
##   streamer.set_impostor_manager(impostor_mgr)
##   # Register objects...
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

## MID tier sub-LOD thresholds
const MID_LOD1_END: float = 250.0
const MID_LOD2_END: float = 375.0

## Object pool configuration (configurable via exports)
@export_group("Pool Configuration")
@export var pool_max_size: int = 2048            ## Maximum tracked objects before eviction
@export var near_keepalive_time: float = 5.0    ## Seconds before freeing hidden Node3D

## Instantiation queue configuration (merged from ObjectDistanceManager)
@export_group("Instantiation Queue")
@export var instantiation_budget_ms: float = 8.0      ## Time budget per frame (ms)
@export var max_instantiations_per_frame: int = 20    ## Hard cap on instantiations

## Spatial hash cell size for efficient lookups
const SPATIAL_HASH_CELL_SIZE: float = 50.0

## Update staggering
const UPDATE_GROUP_COUNT: int = 4

#endregion


#region Tracked Object

## StreamedObject - represents a single object across all tiers
## Replaces ObjectDistanceManager.TrackedObject
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

	# FAR tier (impostor)
	var impostor_id: int = -1
	var far_visible: bool = false
	var far_fade: float = 0.0

	# State
	var current_tier: int = Tier.HIDDEN
	var distance_sq: float = 0.0
	var last_update_frame: int = 0

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

## External ID to pool ID mapping
var _external_to_pool: Dictionary = {}  # external_id -> pool_id

## External references
var _batcher: RefCounted = null  # LODMultiMeshBatcher
var _impostor_manager: Node = null
var _impostor_candidates: RefCounted = null
var _position_index: RefCounted = null  # ObjectPositionIndex for AAA streaming
var _distance_tier_manager: RefCounted = null  # DistanceTierManager for centralized tier logic

## AAA streaming state
var _aaa_streaming_enabled: bool = false
var _aaa_registered_objects: Dictionary = {}  # "cell_x,cell_y,ref_num" -> external_id
var _aaa_last_query_radius: float = 0.0
var _aaa_query_interval_frames: int = 30  # Query position index every N frames
var _aaa_last_query_frame: int = 0

## Instantiation queue (merged from ObjectDistanceManager)
## Objects waiting for Node3D creation - sorted by distance (closest first)
var _instantiation_queue: Array[int] = []  # external_ids waiting for instantiation

## Node recreation tracking (merged from ObjectDistanceManager)
## Objects that had Node3D freed and need recreation when returning to NEAR
var _pending_recreations: Dictionary = {}  # external_id -> true

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
		# When enabling, visibility will be restored on next update()
		if not enabled:
			_hide_all_objects()

## Debug mode
var debug_enabled: bool = false

## Statistics (enhanced with ObjectDistanceManager metrics)
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
}

#endregion


#region Signals

## Emitted when an object needs Node3D instantiation
signal instantiation_requested(object_id: int, model_path: String, world_transform: Transform3D, cell_grid: Vector2i, ref_id: String, ref_num: int)

## Emitted when an object's Node3D should be recreated
signal node_recreation_requested(object_id: int, cell_grid: Vector2i, ref_num: int)

## Emitted when instantiation queue changes (for UI/debugging)
signal instantiation_queue_changed(queue_size: int)

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


## Check if AAA streaming is active
func is_aaa_streaming_enabled() -> bool:
	return _aaa_streaming_enabled

#endregion


#region Public API

## Check if a model is significant (gets full LOD chain + impostor)
func is_significant(model_path: String) -> bool:
	if _impostor_candidates:
		return _impostor_candidates.should_have_impostor(model_path)
	return false


## Register an object with an existing Node3D (NEAR tier entry)
## Returns external object_id for tracking
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

	obj.position = node3d.global_position
	obj.transform = node3d.global_transform
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

	# **UNIFIED VISIBILITY**: Register with DistanceTierManager
	if _distance_tier_manager:
		_distance_tier_manager.register_object(external_id, world_position, cell_grid)
		# Get initial tier from authority
		var initial_tier: int = _distance_tier_manager.get_object_tier(external_id)
		obj.current_tier = initial_tier

		# If already in NEAR, request instantiation
		if initial_tier == Tier.NEAR:
			_request_instantiation(obj, external_id)
	else:
		# Fallback if tier manager not available
		var distance := world_position.distance_to(_camera_pos)
		obj.current_tier = _get_tier_for_distance(distance)
		obj.distance_sq = distance * distance

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

	_remove_from_spatial_hash(obj)
	_objects.erase(pool_id)
	_external_to_pool.erase(external_id)

	# Remove from instantiation queue if present
	var queue_idx := _instantiation_queue.find(external_id)
	if queue_idx >= 0:
		_instantiation_queue.remove_at(queue_idx)
		_stats["instantiation_queue_size"] = _instantiation_queue.size()

	# Remove from pending recreations
	_pending_recreations.erase(external_id)

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

	var camera_moved_sq := camera_pos.distance_squared_to(_camera_pos)
	var camera_moved := camera_moved_sq > _camera_moved_threshold_sq
	if camera_moved:
		_camera_pos = camera_pos

	# AAA streaming: Query position index for nearby objects (Phase 2B)
	if _aaa_streaming_enabled:
		_update_aaa_streaming(camera_pos)

	# Process instantiation queue (merged from ObjectDistanceManager)
	# This must run before tier transitions to instantiate objects that just entered NEAR
	process_instantiation_queue(camera_pos)

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
	# Note: DistanceTierManager is always set up by WorldStreamingManager
	_process_tier_changes_from_authority(delta)

	# AAA streaming: Unload objects beyond FAR tier
	if _aaa_streaming_enabled:
		_unload_distant_objects(camera_pos)

	_stats["update_time_ms"] = (Time.get_ticks_usec() - start_time) / 1000.0


## Called when a deferred object has been instantiated
## Also aliased as on_deferred_object_instantiated for ObjectDistanceManager compatibility
func on_object_instantiated(external_id: int, node3d: Node3D) -> void:
	if external_id not in _external_to_pool:
		return

	var pool_id: int = _external_to_pool[external_id]
	if pool_id not in _objects:
		return

	var obj: StreamedObject = _objects[pool_id]
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


## Alias for ObjectDistanceManager compatibility
func on_deferred_object_instantiated(object_id: int, node3d: Node3D) -> void:
	on_object_instantiated(object_id, node3d)


## Get statistics
func get_stats() -> Dictionary:
	return _stats.duplicate()


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


## Clear all objects
func clear() -> void:
	for pool_id: int in _objects.keys():
		var obj: StreamedObject = _objects[pool_id]
		_cleanup_object(obj)

	_objects.clear()
	_external_to_pool.clear()
	_spatial_hash.clear()
	_aaa_registered_objects.clear()  # Clear AAA tracking
	_instantiation_queue.clear()     # Clear instantiation queue
	_pending_recreations.clear()     # Clear recreation tracking
	_active_near_crossfades.clear()  # Clear crossfade tracking

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
func _update_aaa_streaming(camera_pos: Vector3) -> void:
	if not _position_index:
		return

	# Only query periodically to avoid per-frame overhead
	if (_frame_count - _aaa_last_query_frame) < _aaa_query_interval_frames:
		return

	_aaa_last_query_frame = _frame_count

	# Query objects within FAR range (the maximum streaming distance)
	var query_radius := FAR_END + FADE_MARGIN

	# Get objects from position index
	if not _position_index.has_method("get_objects_within_radius"):
		return

	# DON'T SORT - we only register 50 objects per frame anyway, and most are already tracked
	# Sorting 10k+ objects every 30 frames causes massive stuttering
	var nearby_objects: Array = _position_index.get_objects_within_radius(camera_pos, query_radius, false)

	# Register new objects that aren't tracked yet
	var registered_count := 0
	var max_register_per_update := 50  # Limit to avoid frame spikes

	for obj_pos in nearby_objects:
		if registered_count >= max_register_per_update:
			break

		# Check if already registered
		var obj_key := _make_aaa_object_key(obj_pos.cell_grid, obj_pos.ref_num)
		if obj_key in _aaa_registered_objects:
			continue

		# Register as deferred object
		var external_id := _register_from_position_index(obj_pos)
		if external_id >= 0:
			_aaa_registered_objects[obj_key] = external_id
			registered_count += 1


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
func _unload_distant_objects(camera_pos: Vector3) -> void:
	# Only run occasionally to avoid per-frame overhead
	if (_frame_count % 60) != 0:
		return

	var unload_radius_sq := (FAR_END + FADE_MARGIN * 2.0) * (FAR_END + FADE_MARGIN * 2.0)
	var to_unload: Array[String] = []

	for obj_key: String in _aaa_registered_objects:
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
		var dist_sq := camera_pos.distance_squared_to(obj.position)

		if dist_sq > unload_radius_sq:
			unregister_object(external_id)
			to_unload.append(obj_key)

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

## **NEW - UNIFIED VISIBILITY**: Process tier changes from DistanceTierManager
## This replaces the O(n) update loop with O(changes) processing
func _process_tier_changes_from_authority(delta: float) -> void:
	# Get tier changes from the authority
	var tier_changes: Array[Dictionary] = _distance_tier_manager.get_tier_changes_this_frame()

	_stats["tier_changes_this_frame"] = tier_changes.size()

	# Process each tier change
	for change in tier_changes:
		var obj_id: int = change.object_id
		if obj_id not in _external_to_pool:
			continue

		var pool_id: int = _external_to_pool[obj_id]
		if pool_id not in _objects:
			continue

		var obj: StreamedObject = _objects[pool_id]
		var old_tier: int = change.old_tier
		var new_tier: int = change.new_tier
		var distance: float = change.distance

		# Update object's cached tier and distance
		obj.current_tier = new_tier
		obj.distance_sq = distance * distance

		# Apply tier transition with crossfade
		_handle_tier_transition(obj, new_tier, distance, delta)

		if debug_enabled:
			print("[ObjectStreamer] Object #%d tier: %s → %s (%.1fm)" % [
				obj_id,
				_tier_name(old_tier),
				_tier_name(new_tier),
				distance
			])

	# Update stats for all objects (count tiers)
	# This is much faster than updating each object
	for pool_id: int in _objects:
		var obj: StreamedObject = _objects[pool_id]
		_count_tier_stat(obj)

	# Update NEAR keepalive timers (only for objects with Node3D)
	for pool_id: int in _objects:
		var obj: StreamedObject = _objects[pool_id]
		if obj.node3d:
			_update_near_keepalive(obj, delta)


## Helper to get tier name for debug logging
func _tier_name(tier: int) -> String:
	match tier:
		Tier.NEAR: return "NEAR"
		Tier.MID: return "MID"
		Tier.FAR: return "FAR"
		Tier.HIDDEN: return "HIDDEN"
		_: return "UNKNOWN"


func _update_object(obj: StreamedObject, camera_pos: Vector3, delta: float) -> void:
	# Safety check for externally freed nodes
	if obj.node3d and not is_instance_valid(obj.node3d):
		obj.node3d = null

	# Calculate distance
	obj.distance_sq = camera_pos.distance_squared_to(obj.position)
	var distance := sqrt(obj.distance_sq)

	# Determine target tier
	var target_tier := _get_tier_for_distance(distance)

	# Handle tier transitions
	if target_tier != obj.current_tier:
		_handle_tier_transition(obj, target_tier, distance, delta)

	# Update NEAR keepalive
	_update_near_keepalive(obj, delta)


func _get_tier_for_distance(distance: float) -> int:
	# Use centralized tier calculation from DistanceTierManager if available
	# This provides hysteresis and consistent tier boundaries across the system
	if _distance_tier_manager and _distance_tier_manager.has_method("get_tier_for_distance"):
		var tier: int = _distance_tier_manager.call("get_tier_for_distance", distance, Vector2i.ZERO)
		# Map DistanceTierManager.Tier enum to ObjectStreamer.Tier enum
		# They should be compatible but this makes it explicit
		return tier

	# Fallback to local calculation if DistanceTierManager not available
	if distance < NEAR_END:
		return Tier.NEAR
	elif distance < MID_END:
		return Tier.MID
	elif distance < FAR_END:
		return Tier.FAR
	else:
		return Tier.HIDDEN


func _handle_tier_transition(obj: StreamedObject, target_tier: int, distance: float, _delta: float) -> void:
	var from_tier := obj.current_tier
	var fade_progress := _calculate_fade_progress(distance, from_tier, target_tier)

	match target_tier:
		Tier.NEAR:
			_transition_to_near(obj, fade_progress)
		Tier.MID:
			_transition_to_mid(obj, fade_progress, from_tier)
		Tier.FAR:
			_transition_to_far(obj, fade_progress)
		Tier.HIDDEN:
			_transition_to_hidden(obj)

	# Track transitions for statistics (merged from ObjectDistanceManager)
	if fade_progress >= 1.0:
		obj.current_tier = target_tier
		_stats["transitioning"] = maxi(0, _stats.get("transitioning", 0) - 1)
	elif from_tier == obj.current_tier:
		# Just started transitioning
		_stats["transitioning"] = _stats.get("transitioning", 0) + 1


func _calculate_fade_progress(distance: float, from_tier: int, to_tier: int) -> float:
	var boundary: float

	if (from_tier == Tier.NEAR and to_tier == Tier.MID) or (from_tier == Tier.MID and to_tier == Tier.NEAR):
		boundary = NEAR_END
	elif (from_tier == Tier.MID and to_tier == Tier.FAR) or (from_tier == Tier.FAR and to_tier == Tier.MID):
		boundary = MID_END
	else:
		return 1.0

	var fade_start := boundary - FADE_MARGIN
	var fade_end := boundary + FADE_MARGIN

	if distance <= fade_start:
		return 0.0 if to_tier > from_tier else 1.0
	elif distance >= fade_end:
		return 1.0 if to_tier > from_tier else 0.0
	else:
		var progress := (distance - fade_start) / (2.0 * FADE_MARGIN)
		return progress if to_tier > from_tier else 1.0 - progress


func _transition_to_near(obj: StreamedObject, fade_progress: float) -> void:
	if near_tier_visible:
		if obj.node3d and is_instance_valid(obj.node3d):
			obj.node3d.visible = true
			obj.near_visible = true
			obj.near_hidden_time = 0.0

			# Apply crossfade shader during transition
			if fade_progress < 1.0:
				_apply_near_crossfade_shader(obj, fade_progress)
			else:
				# Transition complete - remove crossfade shader
				_remove_near_crossfade_shader(obj)
		elif obj.node3d == null:
			# Need instantiation
			var external_id := _get_external_id(obj)
			if external_id >= 0:
				# Check if this is a recreation (was previously freed) or first instantiation
				if external_id in _pending_recreations:
					# Node was freed - need to recreate from cell data
					if debug_enabled:
						print("[ObjectStreamer] Requesting recreation for #%d from cell %s" % [
							external_id, obj.cell_grid
						])
					node_recreation_requested.emit(external_id, obj.cell_grid, obj.ref_num)
				else:
					# Normal instantiation (deferred object entering NEAR)
					_request_instantiation(obj, external_id)
	else:
		if obj.node3d and is_instance_valid(obj.node3d):
			obj.node3d.visible = false
		obj.near_visible = false
		# Remove crossfade if tier not visible
		_remove_near_crossfade_shader(obj)

	# Hide MID tier
	if obj.mid_visible:
		_set_mid_fade(obj, 1.0 - fade_progress)
		if fade_progress >= 1.0:
			_hide_mid_tier(obj)


func _transition_to_mid(obj: StreamedObject, fade_progress: float, from_tier: int) -> void:
	if not obj.is_significant:
		if obj.node3d and is_instance_valid(obj.node3d):
			obj.node3d.visible = false
		_remove_near_crossfade_shader(obj)
		return

	var effective_fade := fade_progress if from_tier == Tier.NEAR else 1.0 - fade_progress
	if not mid_tier_visible:
		effective_fade = 0.0
		if obj.mid_visible:
			_hide_mid_tier(obj)
	else:
		if not obj.mid_visible:
			_show_mid_tier(obj)
		_set_mid_fade(obj, effective_fade)

	# Handle NEAR tier fade-out when transitioning from NEAR to MID
	if from_tier == Tier.NEAR:
		if obj.node3d and is_instance_valid(obj.node3d):
			# Apply crossfade shader to fade out NEAR tier
			if fade_progress < 1.0:
				_apply_near_crossfade_shader(obj, 1.0 - fade_progress)
			else:
				# Fully transitioned to MID - hide NEAR and remove shader
				obj.node3d.visible = false
				obj.near_visible = false
				_remove_near_crossfade_shader(obj)

	if from_tier == Tier.FAR:
		_set_far_fade(obj, 1.0 - fade_progress)
		if fade_progress >= 1.0:
			_hide_far_tier(obj)


func _transition_to_far(obj: StreamedObject, fade_progress: float) -> void:
	if not obj.is_significant:
		if obj.node3d and is_instance_valid(obj.node3d):
			obj.node3d.visible = false
		_hide_mid_tier(obj)
		return

	var effective_fade := fade_progress if far_tier_visible else 0.0
	if not far_tier_visible:
		if obj.far_visible:
			_hide_far_tier(obj)
	else:
		if not obj.far_visible:
			_show_far_tier(obj)
		_set_far_fade(obj, effective_fade)

	_set_mid_fade(obj, 1.0 - fade_progress)
	if fade_progress >= 1.0:
		_hide_mid_tier(obj)


func _transition_to_hidden(obj: StreamedObject) -> void:
	if obj.node3d and is_instance_valid(obj.node3d):
		obj.node3d.visible = false
	_remove_near_crossfade_shader(obj)
	_hide_mid_tier(obj)
	_hide_far_tier(obj)


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


func _count_tier_stat(obj: StreamedObject) -> void:
	match obj.current_tier:
		Tier.NEAR: _stats["near_visible"] += 1
		Tier.MID: _stats["mid_visible"] += 1
		Tier.FAR: _stats["far_visible"] += 1
		Tier.HIDDEN: _stats["hidden"] += 1

#endregion


#region MID Tier

func _load_lod_meshes(obj: StreamedObject) -> void:
	if obj.lod_meshes_loaded:
		return

	obj.lod_meshes_loaded = true

	for lod_level in [1, 2, 3]:
		var lod_mesh: ArrayMesh = LODPrebakerScript.load_lod_mesh(obj.model_path, lod_level)
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
	obj.mid_visible = true


func _hide_mid_tier(obj: StreamedObject) -> void:
	if not obj.mid_visible:
		return

	for batch_key: int in obj.multimesh_keys:
		_batcher.remove_instance(obj.id, batch_key)
	obj.multimesh_keys.clear()

	obj.mid_visible = false
	obj.mid_fade = 0.0


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

	obj.impostor_id = _impostor_manager.call(
		"add_impostor",
		obj.model_path,
		obj.position,
		rotation,
		scale,
		obj.cell_grid
	)

	if obj.impostor_id >= 0:
		obj.far_visible = true
		if _impostor_manager.has_method("register_lod_managed_impostor"):
			_impostor_manager.call("register_lod_managed_impostor", obj.id, obj.impostor_id)


func _hide_far_tier(obj: StreamedObject) -> void:
	if not obj.far_visible or not _impostor_manager:
		return

	if _impostor_manager.has_method("unregister_lod_managed_impostor"):
		_impostor_manager.call("unregister_lod_managed_impostor", obj.id)

	if obj.impostor_id >= 0 and _impostor_manager.has_method("remove_impostor"):
		_impostor_manager.call("remove_impostor", obj.impostor_id)

	obj.impostor_id = -1
	obj.far_visible = false
	obj.far_fade = 0.0


func _set_far_fade(obj: StreamedObject, fade: float) -> void:
	obj.far_fade = clampf(fade, 0.0, 1.0)
	if obj.impostor_id >= 0 and _impostor_manager:
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
					# Convert to external ID
					for ext_id: int in _external_to_pool:
						if _external_to_pool[ext_id] == pool_id:
							result.append(ext_id)
							break

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
	for ext_id: int in _external_to_pool:
		if _external_to_pool[ext_id] == obj.id:
			return ext_id
	return -1


## Queue an object for instantiation (merged from ObjectDistanceManager)
## Uses time-budgeted queue instead of immediate emission for smooth frame times
func _request_instantiation(obj: StreamedObject, external_id: int) -> void:
	# Add to queue if not already queued
	if external_id in _instantiation_queue:
		return

	_instantiation_queue.append(external_id)
	_stats["instantiation_queue_size"] = _instantiation_queue.size()

	if debug_enabled:
		print("[ObjectStreamer] Queued #%d for instantiation (queue size: %d)" % [
			external_id, _instantiation_queue.size()
		])


## Process instantiation queue with time budget (merged from ObjectDistanceManager)
## Call this from update() - returns number of objects instantiated
func process_instantiation_queue(camera_pos: Vector3) -> int:
	if _instantiation_queue.is_empty():
		return 0

	var start_time := Time.get_ticks_usec()
	var instantiated := 0

	# Sort queue by distance (closest first)
	_sort_instantiation_queue_by_distance(camera_pos)

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

		if debug_enabled:
			print("[ObjectStreamer] Instantiated %d objects, %d remaining in queue" % [
				instantiated, _instantiation_queue.size()
			])

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


## Check if an object is pending recreation (merged from ObjectDistanceManager)
func is_pending_recreation(external_id: int) -> bool:
	return external_id in _pending_recreations


## Get objects pending recreation for a specific cell (merged from ObjectDistanceManager)
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


## Set object's Node3D after recreation (merged from ObjectDistanceManager)
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

	# Count deferred vs instantiated objects
	var deferred_count := 0
	var instantiated_count := 0
	for pool_id: int in _objects:
		var obj: StreamedObject = _objects[pool_id]
		if obj.node3d == null:
			deferred_count += 1
		else:
			instantiated_count += 1

	_stats["deferred_objects"] = deferred_count
	_stats["instantiated_objects"] = instantiated_count


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
