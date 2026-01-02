## GPUVisibilityRenderer - GPU-driven rendering for MID/FAR tiers (Godot 4.4+)
##
## Implements Phase 2 of the GPU-driven streaming refactor using Godot 4.4's
## new indirect drawing and buffer access APIs:
##   - RenderingServer.multimesh_get_buffer_rd_rid() for direct GPU buffer access
##   - RenderingServer.multimesh_allocate_data() with use_indirect=true
##
## Architecture:
##   1. Object positions are uploaded once on registration
##   2. GPU compute shader calculates visibility + tier per frame
##   3. For batches with GPU buffer access: compute writes directly to buffer
##   4. For batches without: visibility results are read back and applied via RS
##   5. NEAR tier changes use sparse readback for CPU Node3D management
##
## Key Optimizations:
##   - GPU compute for tier calculation (no O(n) CPU iteration)
##   - Direct buffer writes when indirect drawing is available
##   - Sparse change buffer for NEAR tier CPU processing
##   - Hysteresis to prevent tier flickering
##
## Godot 4.4 Requirements:
##   - multimesh_get_buffer_rd_rid() - PR #98788, merged Nov 2024
##   - multimesh_allocate_data with use_indirect - PR #99455, merged Jan 2025
##
## Usage:
##   var renderer = GPUVisibilityRenderer.new()
##   if renderer.initialize():
##       renderer.register_batch(batch_key, multimesh, tier)
##       renderer.add_object(object_id, batch_key, local_idx, position, transform)
##       var near_changes = renderer.update(camera_position)
##
class_name GPUVisibilityRenderer
extends RefCounted

## Preload dependencies
const DU := preload("res://src/core/world/distance_utils.gd")
const SC := preload("res://src/core/world/streaming_config.gd")

## Maximum objects we can track globally
const MAX_OBJECTS: int = 131072  # 128K objects

## Maximum tier changes per frame for NEAR tier sparse readback
const MAX_NEAR_CHANGES: int = 2048

## Workgroup size for compute shader (must match shader)
const WORKGROUP_SIZE: int = 256

## Tier constants (must match compute shader)
enum Tier { NEAR = 0, MID = 1, FAR = 2, HIDDEN = 3 }

#region State

## Whether renderer is initialized and GPU features are available
var _initialized: bool = false
var _gpu_available: bool = false

## RenderingDevice for compute operations (global RD for buffer sharing)
var _rd: RenderingDevice = null

## Compute shader and pipeline
var _shader: RID = RID()
var _pipeline: RID = RID()

## Registered MultiMesh batches: batch_key -> BatchInfo
var _batches: Dictionary = {}

## Object tracking: object_id -> ObjectInfo
var _objects: Dictionary = {}

## Global position buffer for compute shader
## Layout: [x, y, z, radius] per object (vec4)
var _positions_buffer: RID = RID()
var _positions_data: PackedFloat32Array = PackedFloat32Array()
var _positions_dirty: bool = false

## Output visibility buffer
## Layout: [visibility, fade, tier, prev_tier] per object (vec4)
var _visibility_buffer: RID = RID()

## NEAR tier change buffers (sparse readback)
var _near_change_count_buffer: RID = RID()
var _near_changes_buffer: RID = RID()

## Uniform set for compute shader
var _uniform_set: RID = RID()

## Object count tracking
var _object_count: int = 0
var _next_object_index: int = 0
var _free_indices: Array[int] = []

## Distance thresholds
var _near_end: float = DU.NEAR_END
var _mid_end: float = DU.MID_END
var _far_end: float = DU.FAR_END

## Hysteresis values (prevent rapid tier switching)
var _hysteresis_near: float = SC.HYSTERESIS_NEAR
var _hysteresis_mid: float = SC.HYSTERESIS_MID

## Fade margin for crossfade zones
var _fade_margin: float = SC.FADE_MARGIN

## Statistics
var _stats: Dictionary = {
	"total_objects": 0,
	"total_batches": 0,
	"compute_time_us": 0,
	"apply_time_us": 0,
	"near_changes": 0,
	"gpu_available": false,
	"visible_mid": 0,
	"visible_far": 0,
}

## Debug mode
var debug_enabled: bool = false

## Optional reference to LODMultiMeshBatcher for optimized visibility application
## When set, uses batcher's apply_gpu_visibility() which can leverage GPU buffers
var _batcher: RefCounted = null

## Optional reference to ImpostorManager for FAR tier visibility application
## When set, impostors are updated via GPU visibility results
var _impostor_manager: Node = null

#endregion

#region Batch and Object Info

## Information about a registered MultiMesh batch
class BatchInfo extends RefCounted:
	var batch_key: int = 0
	var multimesh_rid: RID = RID()      # RenderingServer RID
	var buffer_rid: RID = RID()          # RenderingDevice RID (for compute)
	var has_gpu_buffer: bool = false
	var tier: int = Tier.MID

	## Object tracking: object_id -> local_index in MultiMesh
	var object_indices: Dictionary = {}

	## Local index -> global object index in position buffer
	var local_to_global: PackedInt32Array = PackedInt32Array()

	## Cached original transforms (for visibility restore)
	var original_transforms: Array[Transform3D] = []


## Information about a tracked object
class ObjectInfo extends RefCounted:
	var object_id: int = -1
	var batch_key: int = -1
	var local_index: int = -1
	var global_index: int = -1
	var position: Vector3 = Vector3.ZERO
	var radius: float = 1.0  # Bounding radius for culling
	var original_transform: Transform3D = Transform3D.IDENTITY
	var current_tier: int = Tier.HIDDEN
	var prev_tier: int = Tier.HIDDEN

#endregion

#region Initialization

## Initialize the GPU visibility renderer
## Returns true if GPU features are available
func initialize() -> bool:
	if _initialized:
		return _gpu_available

	_initialized = true

	# Check for required Godot 4.4 APIs
	var rs := RenderingServer
	if not rs.has_method("multimesh_get_buffer_rd_rid"):
		push_warning("[GPUVisibilityRenderer] multimesh_get_buffer_rd_rid not available (requires Godot 4.4+)")
		_gpu_available = false
		_stats["gpu_available"] = false
		return false

	# Get global RenderingDevice for buffer sharing with RenderingServer
	_rd = RenderingServer.get_rendering_device()
	if not _rd:
		push_warning("[GPUVisibilityRenderer] No global RenderingDevice available")
		_gpu_available = false
		_stats["gpu_available"] = false
		return false

	# Load and compile compute shader
	var shader_path := "res://src/core/world/shaders/gpu_visibility_compute.glsl"
	if not ResourceLoader.exists(shader_path):
		# Try alternate path
		shader_path = "res://src/core/world/shaders/unified_visibility.glsl"

	if not ResourceLoader.exists(shader_path):
		push_warning("[GPUVisibilityRenderer] No visibility compute shader found")
		_gpu_available = false
		return false

	var shader_file := load(shader_path) as RDShaderFile
	if not shader_file:
		push_warning("[GPUVisibilityRenderer] Failed to load %s" % shader_path)
		_gpu_available = false
		return false

	var shader_spirv := shader_file.get_spirv()
	if shader_spirv.compile_error_compute != "":
		push_error("[GPUVisibilityRenderer] Shader compile error: %s" % shader_spirv.compile_error_compute)
		_gpu_available = false
		return false

	_shader = _rd.shader_create_from_spirv(shader_spirv)
	if not _shader.is_valid():
		push_error("[GPUVisibilityRenderer] Failed to create shader")
		_gpu_available = false
		return false

	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		push_error("[GPUVisibilityRenderer] Failed to create pipeline")
		_cleanup()
		return false

	# Create GPU buffers
	if not _create_buffers():
		push_error("[GPUVisibilityRenderer] Failed to create GPU buffers")
		_cleanup()
		return false

	_gpu_available = true
	_stats["gpu_available"] = true

	if debug_enabled:
		print("[GPUVisibilityRenderer] Initialized - GPU visibility enabled")

	return true


## Create GPU storage buffers
func _create_buffers() -> bool:
	# Position buffer: vec4 per object [x, y, z, radius]
	var positions_size := MAX_OBJECTS * 4 * 4
	_positions_data.resize(MAX_OBJECTS * 4)
	_positions_buffer = _rd.storage_buffer_create(positions_size, _positions_data.to_byte_array())
	if not _positions_buffer.is_valid():
		return false

	# Visibility output buffer: vec4 per object [visibility, fade, tier, prev_tier]
	var visibility_size := MAX_OBJECTS * 4 * 4
	var empty_vis := PackedFloat32Array()
	empty_vis.resize(MAX_OBJECTS * 4)
	# Initialize all as HIDDEN
	for i in range(MAX_OBJECTS):
		empty_vis[i * 4 + 2] = float(Tier.HIDDEN)  # tier
		empty_vis[i * 4 + 3] = float(Tier.HIDDEN)  # prev_tier
	_visibility_buffer = _rd.storage_buffer_create(visibility_size, empty_vis.to_byte_array())
	if not _visibility_buffer.is_valid():
		return false

	# NEAR change count (atomic counter)
	var zero := PackedInt32Array([0])
	_near_change_count_buffer = _rd.storage_buffer_create(4, zero.to_byte_array())
	if not _near_change_count_buffer.is_valid():
		return false

	# NEAR changes buffer: [global_idx, old_tier, new_tier, padding] per change
	var changes_size := MAX_NEAR_CHANGES * 4 * 4
	var empty_changes := PackedInt32Array()
	empty_changes.resize(MAX_NEAR_CHANGES * 4)
	_near_changes_buffer = _rd.storage_buffer_create(changes_size, empty_changes.to_byte_array())
	if not _near_changes_buffer.is_valid():
		return false

	# Create uniform set
	_uniform_set = _create_uniform_set()
	if not _uniform_set.is_valid():
		return false

	return true


## Create uniform set for compute shader
func _create_uniform_set() -> RID:
	var uniforms: Array[RDUniform] = []

	# Binding 0: Positions [x, y, z, radius]
	var u0 := RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u0.binding = 0
	u0.add_id(_positions_buffer)
	uniforms.append(u0)

	# Binding 1: Visibility output [visibility, fade, tier, prev_tier]
	var u1 := RDUniform.new()
	u1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u1.binding = 1
	u1.add_id(_visibility_buffer)
	uniforms.append(u1)

	# Binding 2: NEAR change count
	var u2 := RDUniform.new()
	u2.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u2.binding = 2
	u2.add_id(_near_change_count_buffer)
	uniforms.append(u2)

	# Binding 3: NEAR changes
	var u3 := RDUniform.new()
	u3.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u3.binding = 3
	u3.add_id(_near_changes_buffer)
	uniforms.append(u3)

	return _rd.uniform_set_create(uniforms, _shader, 0)


## Clean up GPU resources
func _cleanup() -> void:
	if _rd:
		if _uniform_set.is_valid():
			_rd.free_rid(_uniform_set)
		if _positions_buffer.is_valid():
			_rd.free_rid(_positions_buffer)
		if _visibility_buffer.is_valid():
			_rd.free_rid(_visibility_buffer)
		if _near_change_count_buffer.is_valid():
			_rd.free_rid(_near_change_count_buffer)
		if _near_changes_buffer.is_valid():
			_rd.free_rid(_near_changes_buffer)
		if _pipeline.is_valid():
			_rd.free_rid(_pipeline)
		if _shader.is_valid():
			_rd.free_rid(_shader)

	_batches.clear()
	_objects.clear()
	_gpu_available = false

#endregion

#region Batch Registration

## Register a MultiMesh batch for GPU-driven visibility
## batch_key: Unique identifier
## multimesh: MultiMesh object or RID
## tier: Which tier this batch represents (MID or FAR)
## Returns: true on success
func register_batch(batch_key: int, multimesh: Variant, tier: int = Tier.MID) -> bool:
	if not _gpu_available:
		return false

	if batch_key in _batches:
		return true  # Already registered

	var rs := RenderingServer

	# Accept either MultiMesh object or RID
	var multimesh_rid: RID
	if multimesh is MultiMesh:
		multimesh_rid = (multimesh as MultiMesh).get_rid()
	elif multimesh is RID:
		multimesh_rid = multimesh
	else:
		push_error("[GPUVisibilityRenderer] register_batch: multimesh must be MultiMesh or RID")
		return false

	var batch := BatchInfo.new()
	batch.batch_key = batch_key
	batch.multimesh_rid = multimesh_rid
	batch.tier = tier

	# Get buffer RID for direct GPU access
	batch.buffer_rid = rs.call("multimesh_get_buffer_rd_rid", multimesh_rid)
	batch.has_gpu_buffer = batch.buffer_rid.is_valid()

	_batches[batch_key] = batch
	_stats["total_batches"] = _batches.size()

	if debug_enabled:
		print("[GPUVisibilityRenderer] Registered batch %d (tier %d, gpu_buffer=%s)" % [
			batch_key, tier, batch.has_gpu_buffer])

	return true


## Add an object to tracking (full parameters)
## Returns: true on success
func add_object(object_id: int, batch_key: int, local_index: int,
				position: Vector3, original_transform: Transform3D,
				radius: float = 1.0) -> bool:
	if not _gpu_available:
		return false

	if batch_key not in _batches:
		return false

	if object_id in _objects:
		return true  # Already tracked

	var batch: BatchInfo = _batches[batch_key]

	# Allocate global index
	var global_index: int
	if not _free_indices.is_empty():
		global_index = _free_indices.pop_back()
	else:
		if _next_object_index >= MAX_OBJECTS:
			push_warning("[GPUVisibilityRenderer] At max capacity (%d)" % MAX_OBJECTS)
			return false
		global_index = _next_object_index
		_next_object_index += 1

	# Store position and radius
	var base := global_index * 4
	_positions_data[base] = position.x
	_positions_data[base + 1] = position.y
	_positions_data[base + 2] = position.z
	_positions_data[base + 3] = radius

	# Create object info
	var obj := ObjectInfo.new()
	obj.object_id = object_id
	obj.batch_key = batch_key
	obj.local_index = local_index
	obj.global_index = global_index
	obj.position = position
	obj.radius = radius
	obj.original_transform = original_transform
	obj.current_tier = Tier.HIDDEN
	obj.prev_tier = Tier.HIDDEN

	_objects[object_id] = obj

	# Update batch tracking
	batch.object_indices[object_id] = local_index
	if local_index >= batch.local_to_global.size():
		batch.local_to_global.resize(local_index + 1)
		batch.original_transforms.resize(local_index + 1)
	batch.local_to_global[local_index] = global_index
	batch.original_transforms[local_index] = original_transform

	_object_count += 1
	_positions_dirty = true
	_stats["total_objects"] = _object_count

	return true


## Remove an object from tracking
func remove_object(object_id: int) -> bool:
	if object_id not in _objects:
		return false

	var obj: ObjectInfo = _objects[object_id]
	var batch: BatchInfo = _batches.get(obj.batch_key, null)

	# Return global index to free list
	_free_indices.append(obj.global_index)

	# Clear position (move to infinity so it's always HIDDEN)
	var base := obj.global_index * 4
	_positions_data[base] = 999999.0
	_positions_data[base + 1] = 999999.0
	_positions_data[base + 2] = 999999.0
	_positions_data[base + 3] = 0.0

	# Update batch tracking
	if batch:
		batch.object_indices.erase(object_id)

	_objects.erase(object_id)
	_object_count -= 1
	_positions_dirty = true
	_stats["total_objects"] = _object_count

	return true


## Unregister a batch
func unregister_batch(batch_key: int) -> void:
	if batch_key not in _batches:
		return

	var batch: BatchInfo = _batches[batch_key]

	# Remove all objects in this batch
	for object_id: int in batch.object_indices.keys():
		remove_object(object_id)

	_batches.erase(batch_key)
	_stats["total_batches"] = _batches.size()


## Compatibility alias: add_object_to_batch (basic version)
## Called by ObjectStreamer - signature: (batch_key, object_id, local_index, position)
## NOTE: Prefer add_object_to_batch_with_transform for correct transforms
func add_object_to_batch(batch_key: int, object_id: int, local_index: int, position: Vector3) -> bool:
	# Use identity transform with position (fallback when transform not available)
	var transform := Transform3D(Basis.IDENTITY, position)
	return add_object(object_id, batch_key, local_index, position, transform, 1.0)


## Add object with full transform - preferred method
## Called by ObjectStreamer when it has access to the batcher's original transforms
func add_object_to_batch_with_transform(batch_key: int, object_id: int, local_index: int,
		position: Vector3, original_transform: Transform3D) -> bool:
	return add_object(object_id, batch_key, local_index, position, original_transform, 1.0)


## Compatibility alias: remove_object_from_batch
## Called by ObjectStreamer
func remove_object_from_batch(batch_key: int, object_id: int) -> bool:
	return remove_object(object_id)

#endregion

#region Update Loop

## Main update function - call every frame
## camera_pos: Current camera world position
## Returns: Array of NEAR tier changes for CPU processing
func update(camera_pos: Vector3) -> Array[Dictionary]:
	if not _gpu_available or _object_count == 0:
		return []

	# Safety check: ensure RenderingDevice is still valid
	if not _rd:
		push_warning("[GPUVisibilityRenderer] RenderingDevice null, disabling GPU visibility")
		_gpu_available = false
		return []

	# Safety check: ensure critical buffers are valid
	if not _positions_buffer.is_valid() or not _visibility_buffer.is_valid():
		push_warning("[GPUVisibilityRenderer] GPU buffers invalid, disabling GPU visibility")
		_gpu_available = false
		return []

	var start_time := Time.get_ticks_usec()

	# Upload positions if dirty (with error handling)
	if _positions_dirty:
		if not _upload_positions_safe():
			push_warning("[GPUVisibilityRenderer] Position upload failed, disabling GPU visibility")
			_gpu_available = false
			return []

	# Dispatch compute shader (with error handling)
	if not _dispatch_compute_safe(camera_pos):
		push_warning("[GPUVisibilityRenderer] Compute dispatch failed, disabling GPU visibility")
		_gpu_available = false
		return []

	var compute_time := Time.get_ticks_usec() - start_time
	_stats["compute_time_us"] = compute_time

	# Apply visibility to MultiMesh batches
	var apply_start := Time.get_ticks_usec()
	_apply_visibility_to_batches()
	_stats["apply_time_us"] = Time.get_ticks_usec() - apply_start

	# Read NEAR tier changes for CPU
	var near_changes := _read_near_changes()
	_stats["near_changes"] = near_changes.size()

	return near_changes


## Upload position data to GPU
func _upload_positions() -> void:
	# Safety check: ensure buffer is valid
	if not _positions_buffer.is_valid():
		push_warning("[GPUVisibilityRenderer] Positions buffer invalid, skipping upload")
		return

	var bytes := _positions_data.to_byte_array()
	var upload_size := mini(bytes.size(), _next_object_index * 4 * 4)
	if upload_size > 0:
		_rd.buffer_update(_positions_buffer, 0, upload_size, bytes.slice(0, upload_size))
	_positions_dirty = false


## Upload position data to GPU (safe version with error handling)
## Returns: true if successful, false if failed
func _upload_positions_safe() -> bool:
	# Safety check: ensure buffer is valid
	if not _positions_buffer.is_valid():
		return false

	var bytes := _positions_data.to_byte_array()
	var upload_size := mini(bytes.size(), _next_object_index * 4 * 4)
	if upload_size > 0:
		# buffer_update can fail if GPU resources are exhausted
		var err := _rd.buffer_update(_positions_buffer, 0, upload_size, bytes.slice(0, upload_size))
		if err != OK:
			return false
	_positions_dirty = false
	return true


## Dispatch compute shader (safe version with error handling)
## Returns: true if successful, false if failed
func _dispatch_compute_safe(camera_pos: Vector3) -> bool:
	# Safety check: ensure all required resources are valid
	if not _pipeline.is_valid() or not _uniform_set.is_valid():
		return false

	if not _near_change_count_buffer.is_valid():
		return false

	# Reset NEAR change counter
	var zero := PackedInt32Array([0])
	var err := _rd.buffer_update(_near_change_count_buffer, 0, 4, zero.to_byte_array())
	if err != OK:
		return false

	# Build push constants (must match shader layout)
	# Layout: camera_pos(vec4) + thresholds(vec4) + params(vec4) + counts(uvec4)
	var push_constants := PackedFloat32Array()

	# Camera position (vec4) - 16 bytes
	push_constants.append(camera_pos.x)
	push_constants.append(camera_pos.y)
	push_constants.append(camera_pos.z)
	push_constants.append(0.0)

	# Tier thresholds - 16 bytes
	push_constants.append(_near_end)
	push_constants.append(_mid_end)
	push_constants.append(_far_end)
	push_constants.append(_fade_margin)

	# Hysteresis params - 16 bytes
	push_constants.append(_hysteresis_near)
	push_constants.append(_hysteresis_mid)
	push_constants.append(0.0)  # reserved
	push_constants.append(0.0)  # reserved

	var push_bytes := push_constants.to_byte_array()

	# Object count + max changes - 16 bytes (uvec4)
	var uint_data := PackedInt32Array([_next_object_index, MAX_NEAR_CHANGES, 0, 0])
	push_bytes.append_array(uint_data.to_byte_array())

	# Calculate workgroups
	var workgroups := ceili(float(_next_object_index) / float(WORKGROUP_SIZE))

	# Dispatch
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
	_rd.compute_list_bind_uniform_set(compute_list, _uniform_set, 0)
	_rd.compute_list_set_push_constant(compute_list, push_bytes, push_bytes.size())
	_rd.compute_list_dispatch(compute_list, workgroups, 1, 1)
	_rd.compute_list_end()
	# Note: Barriers are automatically inserted by RenderingDevice in Godot 4.4+

	return true


## Dispatch compute shader
func _dispatch_compute(camera_pos: Vector3) -> void:
	# Safety check: ensure all required resources are valid
	if not _pipeline.is_valid() or not _uniform_set.is_valid():
		push_warning("[GPUVisibilityRenderer] Pipeline or uniform set invalid, skipping compute")
		return

	if not _near_change_count_buffer.is_valid():
		push_warning("[GPUVisibilityRenderer] NEAR change count buffer invalid, skipping compute")
		return

	# Reset NEAR change counter
	var zero := PackedInt32Array([0])
	_rd.buffer_update(_near_change_count_buffer, 0, 4, zero.to_byte_array())

	# Build push constants (must match shader layout)
	# Layout: camera_pos(vec4) + thresholds(vec4) + params(vec4) + counts(uvec4)
	var push_constants := PackedFloat32Array()

	# Camera position (vec4) - 16 bytes
	push_constants.append(camera_pos.x)
	push_constants.append(camera_pos.y)
	push_constants.append(camera_pos.z)
	push_constants.append(0.0)

	# Tier thresholds - 16 bytes
	push_constants.append(_near_end)
	push_constants.append(_mid_end)
	push_constants.append(_far_end)
	push_constants.append(_fade_margin)

	# Hysteresis params - 16 bytes
	push_constants.append(_hysteresis_near)
	push_constants.append(_hysteresis_mid)
	push_constants.append(0.0)  # reserved
	push_constants.append(0.0)  # reserved

	var push_bytes := push_constants.to_byte_array()

	# Object count + max changes - 16 bytes (uvec4)
	var uint_data := PackedInt32Array([_next_object_index, MAX_NEAR_CHANGES, 0, 0])
	push_bytes.append_array(uint_data.to_byte_array())

	# Calculate workgroups
	var workgroups := ceili(float(_next_object_index) / float(WORKGROUP_SIZE))

	# Dispatch
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
	_rd.compute_list_bind_uniform_set(compute_list, _uniform_set, 0)
	_rd.compute_list_set_push_constant(compute_list, push_bytes, push_bytes.size())
	_rd.compute_list_dispatch(compute_list, workgroups, 1, 1)
	_rd.compute_list_end()
	# Note: Barriers are automatically inserted by RenderingDevice in Godot 4.4+


## Apply visibility results to MultiMesh batches
## Uses optimized path: only updates custom_data (fade), transform stays constant
func _apply_visibility_to_batches() -> void:
	# Read visibility buffer (only the portion we need)
	var read_size := _next_object_index * 4 * 4
	if read_size <= 0:
		return

	# Safety check: ensure visibility buffer is valid before reading
	if not _visibility_buffer.is_valid():
		push_warning("[GPUVisibilityRenderer] Visibility buffer invalid, skipping apply")
		return

	var vis_bytes := _rd.buffer_get_data(_visibility_buffer, 0, read_size)
	if vis_bytes.is_empty():
		push_warning("[GPUVisibilityRenderer] Empty visibility data, skipping apply")
		return
	var vis_data := vis_bytes.to_float32_array()

	var rs := RenderingServer

	# Track visible/hidden counts for stats
	var visible_mid := 0
	var visible_far := 0

	# Collect batches to remove (stale RIDs) - can't modify dict while iterating
	var batches_to_remove: Array[int] = []

	for batch_key: int in _batches:
		var batch: BatchInfo = _batches[batch_key]
		if batch.object_indices.is_empty():
			continue

		# CRITICAL: Validate MultiMesh RID before using it
		# This prevents crashes when the MultiMesh was freed externally
		if not batch.multimesh_rid.is_valid():
			if debug_enabled:
				push_warning("[GPUVisibilityRenderer] Batch %d has invalid multimesh_rid, marking for removal" % batch_key)
			batches_to_remove.append(batch_key)
			continue

		# Get the MultiMesh instance count to validate indices
		var instance_count: int = rs.multimesh_get_instance_count(batch.multimesh_rid)
		if instance_count <= 0:
			# MultiMesh may have been cleared or resized to 0
			continue

		# Batch all custom_data updates (cheaper than transform updates)
		for object_id: int in batch.object_indices:
			var local_idx: int = batch.object_indices[object_id]
			if local_idx >= batch.local_to_global.size():
				continue

			# CRITICAL: Validate local_idx is within MultiMesh bounds
			if local_idx < 0 or local_idx >= instance_count:
				if debug_enabled:
					push_warning("[GPUVisibilityRenderer] local_idx %d out of bounds (count=%d)" % [local_idx, instance_count])
				continue

			var global_idx: int = batch.local_to_global[local_idx]
			if global_idx < 0:
				continue

			# Read visibility from compute output
			var vis_base := global_idx * 4
			if vis_base + 3 >= vis_data.size():
				continue

			var visibility: float = vis_data[vis_base]
			var fade: float = vis_data[vis_base + 1]
			var tier: int = int(vis_data[vis_base + 2])

			# Update object info cache
			if object_id in _objects:
				var obj: ObjectInfo = _objects[object_id]
				obj.prev_tier = obj.current_tier
				obj.current_tier = tier

			# Determine if visible in this batch's tier
			var should_show := false
			if batch.tier == Tier.MID and tier == Tier.MID:
				should_show = visibility > 0.01
				if should_show:
					visible_mid += 1
			elif batch.tier == Tier.FAR and tier == Tier.FAR:
				should_show = visibility > 0.01
				if should_show:
					visible_far += 1

			# OPTIMIZED: Only update custom_data for fade
			# The shader uses custom_data.x as fade amount:
			# - 0.0 = invisible (discard in shader)
			# - 0.0-1.0 = fading (dithered)
			# - 1.0 = fully visible
			# This is much cheaper than updating transforms!
			var final_fade := visibility * fade if should_show else 0.0
			rs.multimesh_instance_set_custom_data(batch.multimesh_rid, local_idx,
				Color(final_fade, fade, float(tier), 1.0))

	# Remove stale batches after iteration
	for batch_key: int in batches_to_remove:
		unregister_batch(batch_key)

	_stats["visible_mid"] = visible_mid
	_stats["visible_far"] = visible_far


## Read NEAR tier changes from sparse buffer
func _read_near_changes() -> Array[Dictionary]:
	var changes: Array[Dictionary] = []

	# Safety check: ensure buffers are valid
	if not _near_change_count_buffer.is_valid() or not _near_changes_buffer.is_valid():
		return changes

	# Read change count
	var count_bytes := _rd.buffer_get_data(_near_change_count_buffer, 0, 4)
	if count_bytes.is_empty():
		return changes
	var change_count: int = count_bytes.to_int32_array()[0]

	if change_count == 0:
		return changes

	# Clamp to buffer size
	var actual_count := mini(change_count, MAX_NEAR_CHANGES)
	if change_count > MAX_NEAR_CHANGES:
		push_warning("[GPUVisibilityRenderer] NEAR change overflow (%d > %d)" % [change_count, MAX_NEAR_CHANGES])

	# Read change data
	var changes_bytes := _rd.buffer_get_data(_near_changes_buffer, 0, actual_count * 4 * 4)
	if changes_bytes.is_empty():
		return changes
	var changes_data := changes_bytes.to_int32_array()

	for i in range(actual_count):
		var base := i * 4
		var global_idx: int = changes_data[base]
		var old_tier: int = changes_data[base + 1]
		var new_tier: int = changes_data[base + 2]

		# Find object_id from global index
		var object_id: int = -1
		for oid: int in _objects:
			var obj: ObjectInfo = _objects[oid]
			if obj.global_index == global_idx:
				object_id = oid
				break

		if object_id >= 0:
			changes.append({
				"object_id": object_id,
				"old_tier": old_tier,
				"new_tier": new_tier,
			})

	return changes

#endregion

#region Queries

## Get current tier for an object
func get_object_tier(object_id: int) -> int:
	if object_id not in _objects:
		return Tier.HIDDEN
	return (_objects[object_id] as ObjectInfo).current_tier


## Get statistics
func get_stats() -> Dictionary:
	return _stats.duplicate()


## Check if GPU features are available
func is_available() -> bool:
	return _gpu_available


## Check if initialized
func is_initialized() -> bool:
	return _initialized


## Set reference to LODMultiMeshBatcher for optimized visibility application
## When set, Phase 2 can use batcher's GPU buffer methods
func set_batcher(batcher: RefCounted) -> void:
	_batcher = batcher
	if debug_enabled and _batcher:
		print("[GPUVisibilityRenderer] Batcher reference set - GPU buffer path available")


## Set reference to ImpostorManager for FAR tier visibility
## When set, GPU visibility is applied to impostors
func set_impostor_manager(manager: Node) -> void:
	_impostor_manager = manager
	if debug_enabled and _impostor_manager:
		print("[GPUVisibilityRenderer] ImpostorManager reference set - FAR tier GPU visibility enabled")


## Get object count
func get_object_count() -> int:
	return _object_count


## Get batch count
func get_batch_count() -> int:
	return _batches.size()

#endregion
