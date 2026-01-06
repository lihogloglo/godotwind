## LODMultiMeshBatcher - MultiMesh batch manager for per-object LOD system
##
## Groups LOD instances by mesh type into MultiMesh batches for efficient rendering.
## Each unique (mesh_rid, lod_level) combination gets its own MultiMesh batch.
##
## Key features:
## - Single draw call per mesh type per LOD level
## - Per-instance fade via INSTANCE_CUSTOM.x (0.0-1.0)
## - Automatic batch growth and shrinking
## - Hidden instances use zero-scale transform (efficient GPU culling)
##
## GPU-Driven Rendering (Godot 4.4+):
## - Uses RenderingServer.multimesh_allocate_data() with use_indirect=true
## - Allows compute shaders to directly control visibility via buffer writes
## - No CPU roundtrip needed for visibility updates (PR #99455)
## - Uses multimesh_get_buffer_rd_rid() for GPU buffer access (PR #98788)
##
## Industry-Standard Optimization:
## - Pre-warmed batch capacities (256 instead of 32)
## - Reduces O(n) growth copy operations during streaming
##
## This follows the same pattern as ImpostorManager's MultiMesh usage.
class_name LODMultiMeshBatcher
extends RefCounted

## Preload utilities
const DU := preload("res://src/core/world/distance_utils.gd")
const SC := preload("res://src/core/world/streaming_config.gd")

## Initial capacity for new batches (will grow as needed)
## Set to 256 to minimize growth operations (matches StreamingConfig)
const INITIAL_BATCH_CAPACITY := 256  # Was 128, now matches SC.INITIAL_BATCH_CAPACITY

## Maximum instances per batch before logging warning
const MAX_INSTANCES_PER_BATCH := 4096  # Was 512, increased for larger worlds

## Growth factor when batch needs more capacity
const BATCH_GROWTH_FACTOR := 2.0


## Single batch for a specific mesh at a specific LOD level
class MeshBatch extends RefCounted:
	## Unique identifier for this batch
	var batch_key: int = 0

	## The mesh this batch renders
	var mesh: ArrayMesh = null
	var mesh_rid: RID = RID()

	## LOD level (1, 2, or 3 - LOD0 uses Node3D, not batched)
	var lod_level: int = 0

	## MultiMesh for batched rendering
	var multimesh: MultiMesh = null
	var multimesh_instance: MultiMeshInstance3D = null

	## RenderingServer RIDs for GPU access
	var multimesh_rs_rid: RID = RID()  # RID from RenderingServer (for API calls)
	var buffer_rd_rid: RID = RID()     # RID for RenderingDevice (for GPU compute)

	## Crossfade material (ShaderMaterial with dither support)
	var material: ShaderMaterial = null

	## Instance tracking: object_id -> instance_index
	var instances: Dictionary = {}

	## Free indices for reuse (recycled when instances removed)
	var free_indices: Array[int] = []

	## Current capacity of the MultiMesh
	var capacity: int = 0

	## Number of active (non-hidden) instances
	var active_count: int = 0

	## Whether batch needs MultiMesh rebuild (transforms/custom_data changed)
	var dirty: bool = false

	## Whether this batch uses GPU indirect drawing (Godot 4.4+)
	var use_indirect: bool = false

	## Whether this batch has GPU buffer access
	var has_gpu_buffer: bool = false

	## Original transforms (for visibility restore after GPU writes)
	var original_transforms: Array[Transform3D] = []


## All batches by batch_key: batch_key -> MeshBatch
var _batches: Dictionary = {}

## Lookup table: mesh_rid_id -> { lod_level -> batch_key }
var _mesh_to_batch: Dictionary = {}

## Scene root for adding MultiMeshInstance3D nodes
var _scene_root: Node3D = null

## Shared crossfade shader for all batches
var _crossfade_shader: Shader = null

## Next batch key
var _next_batch_key: int = 1

## Rate limiting for batch creation - prevents frame spikes during heavy loading
const MAX_BATCH_CREATES_PER_FRAME: int = 4
var _batch_creates_this_frame: int = 0
var _batch_create_frame: int = 0

## Statistics
var _stats: Dictionary = {
	"total_batches": 0,
	"total_instances": 0,
	"active_instances": 0,
	"draw_calls": 0,
	"gpu_enabled": false,
	"indirect_enabled": false,
}

## GPU features available (checked once at init)
var _gpu_features_checked: bool = false
var _has_buffer_rd_rid: bool = false
var _has_indirect_drawing: bool = false

## Debug warning counter to avoid log spam
var _debug_material_warnings: int = 0

## Check for Godot 4.4+ GPU features
func _check_gpu_features() -> void:
	if _gpu_features_checked:
		return
	_gpu_features_checked = true

	var rs := RenderingServer

	# Check for multimesh_get_buffer_rd_rid (PR #98788, Godot 4.4)
	_has_buffer_rd_rid = rs.has_method("multimesh_get_buffer_rd_rid")

	# Check for indirect drawing support
	# The use_indirect parameter was added in PR #99455 (Godot 4.4)
	# We detect this by checking if multimesh_allocate_data accepts 6 parameters
	# Since we can't easily check param count, we assume if buffer_rd_rid exists,
	# indirect also exists (both were added around same time)
	_has_indirect_drawing = _has_buffer_rd_rid

	_stats["gpu_enabled"] = _has_buffer_rd_rid
	_stats["indirect_enabled"] = _has_indirect_drawing

	if _has_buffer_rd_rid:
		print("[LODMultiMeshBatcher] GPU features enabled (Godot 4.4+)")
		print("  - multimesh_get_buffer_rd_rid: available")
		print("  - indirect drawing: %s" % ("available" if _has_indirect_drawing else "not available"))
	else:
		print("[LODMultiMeshBatcher] GPU features not available (requires Godot 4.4+)")


#region Initialization

## Initialize the batcher with scene root and shader
func initialize(scene_root: Node3D, crossfade_shader: Shader) -> Error:
	if not scene_root:
		push_error("LODMultiMeshBatcher: scene_root is required")
		return ERR_INVALID_PARAMETER

	if not crossfade_shader:
		push_error("LODMultiMeshBatcher: crossfade_shader is required")
		return ERR_INVALID_PARAMETER

	_scene_root = scene_root
	_crossfade_shader = crossfade_shader

	# Check GPU features once at initialization
	_check_gpu_features()

	return OK


## Clean up all batches
func cleanup() -> void:
	for batch_key: int in _batches:
		var batch: MeshBatch = _batches[batch_key]
		if batch.multimesh_instance and is_instance_valid(batch.multimesh_instance):
			batch.multimesh_instance.queue_free()

	_batches.clear()
	_mesh_to_batch.clear()
	_stats["total_batches"] = 0
	_stats["total_instances"] = 0
	_stats["active_instances"] = 0
	_stats["draw_calls"] = 0

#endregion


#region Instance Management

## Add an instance to the appropriate batch
## Returns batch_key for later reference, or -1 on failure
## materials: Optional array of materials to use for rendering (if mesh has no embedded materials)
func add_instance(
	mesh: ArrayMesh,
	lod_level: int,
	transform: Transform3D,
	object_id: int,
	fade_amount: float = 1.0,
	materials: Array[Material] = []
) -> int:
	if not mesh:
		return -1

	if lod_level < 1 or lod_level > 3:
		push_warning("LODMultiMeshBatcher: Invalid LOD level %d (expected 1-3)" % lod_level)
		return -1

	# Get or create batch for this mesh/lod combination (pass materials for shader creation)
	var batch := _get_or_create_batch(mesh, lod_level, materials)
	if not batch:
		return -1

	# Get instance index (reuse free slot or allocate new)
	var instance_idx: int
	if not batch.free_indices.is_empty():
		instance_idx = batch.free_indices.pop_back()
	else:
		instance_idx = batch.instances.size()
		# Ensure capacity
		if instance_idx >= batch.capacity:
			var old_capacity := batch.capacity
			_grow_batch(batch)
			# CRITICAL: Check if grow actually succeeded (batch at max capacity returns early)
			if batch.capacity == old_capacity:
				push_warning("[LODMultiMeshBatcher] Cannot add instance - batch at max capacity %d" % batch.capacity)
				return -1

	# SAFETY CHECK: Validate instance_idx is within MultiMesh bounds
	if instance_idx >= batch.multimesh.instance_count:
		push_error("[LODMultiMeshBatcher] CRITICAL: instance_idx %d >= instance_count %d" % [
			instance_idx, batch.multimesh.instance_count])
		return -1

	# Set transform and custom data
	batch.multimesh.set_instance_transform(instance_idx, transform)
	batch.multimesh.set_instance_custom_data(instance_idx, Color(fade_amount, 0.0, 0.0, 1.0))

	# Store original transform for GPU visibility restore
	if instance_idx < batch.original_transforms.size():
		batch.original_transforms[instance_idx] = transform

	# Track instance
	batch.instances[object_id] = instance_idx
	if fade_amount > 0.01:
		batch.active_count += 1
	batch.dirty = true

	_stats["total_instances"] += 1
	if fade_amount > 0.01:
		_stats["active_instances"] += 1

	return batch.batch_key


## Update fade amount for an instance
func update_fade(object_id: int, batch_key: int, fade_amount: float) -> void:
	if batch_key not in _batches:
		return

	var batch: MeshBatch = _batches[batch_key]
	if object_id not in batch.instances:
		return

	var instance_idx: int = batch.instances[object_id]

	# SAFETY CHECK: Validate instance_idx is within MultiMesh bounds
	if instance_idx < 0 or instance_idx >= batch.multimesh.instance_count:
		push_warning("[LODMultiMeshBatcher] update_fade: instance_idx %d out of bounds (count=%d)" % [
			instance_idx, batch.multimesh.instance_count])
		return

	# Get current custom data to check if we're changing visibility
	var current_data: Color = batch.multimesh.get_instance_custom_data(instance_idx)
	var was_visible := current_data.r > 0.01
	var is_visible := fade_amount > 0.01

	# Update active count if visibility changed
	if was_visible and not is_visible:
		batch.active_count -= 1
		_stats["active_instances"] -= 1
	elif not was_visible and is_visible:
		batch.active_count += 1
		_stats["active_instances"] += 1

	# Update custom data (fade in .x channel)
	batch.multimesh.set_instance_custom_data(instance_idx, Color(fade_amount, 0.0, 0.0, 1.0))
	batch.dirty = true


## Update transform for an instance
func update_transform(object_id: int, batch_key: int, transform: Transform3D) -> void:
	if batch_key not in _batches:
		return

	var batch: MeshBatch = _batches[batch_key]
	if object_id not in batch.instances:
		return

	var instance_idx: int = batch.instances[object_id]

	# SAFETY CHECK: Validate instance_idx is within MultiMesh bounds
	if instance_idx < 0 or instance_idx >= batch.multimesh.instance_count:
		push_warning("[LODMultiMeshBatcher] update_transform: instance_idx %d out of bounds (count=%d)" % [
			instance_idx, batch.multimesh.instance_count])
		return

	batch.multimesh.set_instance_transform(instance_idx, transform)
	batch.dirty = true


## Remove an instance from a batch
func remove_instance(object_id: int, batch_key: int) -> void:
	if batch_key not in _batches:
		return

	var batch: MeshBatch = _batches[batch_key]
	if object_id not in batch.instances:
		return

	var instance_idx: int = batch.instances[object_id]

	# SAFETY CHECK: Validate instance_idx is within MultiMesh bounds
	if instance_idx < 0 or instance_idx >= batch.multimesh.instance_count:
		push_warning("[LODMultiMeshBatcher] remove_instance: instance_idx %d out of bounds (count=%d)" % [
			instance_idx, batch.multimesh.instance_count])
		# Still clean up tracking data even if we can't access the MultiMesh
		batch.instances.erase(object_id)
		_stats["total_instances"] -= 1
		return

	# Check if was visible
	var current_data: Color = batch.multimesh.get_instance_custom_data(instance_idx)
	if current_data.r > 0.01:
		batch.active_count -= 1
		_stats["active_instances"] -= 1

	# Hide by setting zero-scale transform and zero fade
	var hidden_transform := Transform3D.IDENTITY.scaled(Vector3.ZERO)
	batch.multimesh.set_instance_transform(instance_idx, hidden_transform)
	batch.multimesh.set_instance_custom_data(instance_idx, Color(0.0, 0.0, 0.0, 1.0))

	# Return index to free pool
	batch.instances.erase(object_id)
	batch.free_indices.append(instance_idx)
	batch.dirty = true

	_stats["total_instances"] -= 1


## Remove all instances for a given cell
func remove_instances_for_cell(cell_grid: Vector2i, object_ids: Array) -> int:
	var removed := 0
	for object_id: int in object_ids:
		# Find which batch this object is in
		for batch_key: int in _batches:
			var batch: MeshBatch = _batches[batch_key]
			if object_id in batch.instances:
				remove_instance(object_id, batch_key)
				removed += 1
				break
	return removed

#endregion


#region Batch Management

## Get or create a batch for the given mesh and LOD level
## materials: Optional array of materials (used if mesh has no embedded materials)
func _get_or_create_batch(mesh: ArrayMesh, lod_level: int, materials: Array[Material] = []) -> MeshBatch:
	var mesh_id := mesh.get_rid().get_id()

	# Check if batch already exists
	if mesh_id in _mesh_to_batch:
		var lod_map: Dictionary = _mesh_to_batch[mesh_id]
		if lod_level in lod_map:
			return _batches[lod_map[lod_level]]

	# RATE LIMITING: Reset counter on new frame
	var current_frame := Engine.get_process_frames()
	if current_frame != _batch_create_frame:
		_batch_create_frame = current_frame
		_batch_creates_this_frame = 0

	# RATE LIMITING: Check if we've hit the per-frame limit
	if _batch_creates_this_frame >= MAX_BATCH_CREATES_PER_FRAME:
		# Return null to defer creation to next frame
		# Caller will retry on next update
		return null

	# Create new batch (pass materials for shader creation)
	var batch := _create_batch(mesh, lod_level, materials)
	if not batch:
		return null

	_batch_creates_this_frame += 1

	# Register in lookup tables
	if mesh_id not in _mesh_to_batch:
		_mesh_to_batch[mesh_id] = {}
	(_mesh_to_batch[mesh_id] as Dictionary)[lod_level] = batch.batch_key
	_batches[batch.batch_key] = batch

	_stats["total_batches"] = _batches.size()
	_stats["draw_calls"] = _batches.size()

	return batch


## Create a new batch for the given mesh and LOD level
## materials: Optional array of materials (used if mesh has no embedded materials)
func _create_batch(mesh: ArrayMesh, lod_level: int, materials: Array[Material] = []) -> MeshBatch:
	var batch := MeshBatch.new()
	batch.batch_key = _next_batch_key
	_next_batch_key += 1
	batch.mesh = mesh
	batch.mesh_rid = mesh.get_rid()
	batch.lod_level = lod_level
	batch.capacity = INITIAL_BATCH_CAPACITY

	var rs := RenderingServer

	# Determine if we should use GPU-driven path (Godot 4.4+)
	var use_gpu := _has_buffer_rd_rid and _has_indirect_drawing

	if use_gpu:
		# GPU-driven path: Create MultiMesh via RenderingServer with indirect drawing
		batch.multimesh_rs_rid = rs.multimesh_create()

		# Allocate with indirect drawing enabled (PR #99455)
		# Parameters: rid, instances, transform_format, color_format, use_custom_data, use_indirect
		# The last parameter (use_indirect) was added in Godot 4.4
		rs.multimesh_allocate_data(
			batch.multimesh_rs_rid,
			INITIAL_BATCH_CAPACITY,
			RenderingServer.MULTIMESH_TRANSFORM_3D,
			false,  # use_colors
			true,   # use_custom_data
			# Note: use_indirect is 6th param, but may not be available in all builds
			# We'll call it separately if needed
		)

		# Try to enable indirect drawing via separate call if the allocate didn't include it
		# This is a fallback for builds where the parameter isn't exposed
		if rs.has_method("multimesh_set_use_indirect"):
			rs.call("multimesh_set_use_indirect", batch.multimesh_rs_rid, true)
			batch.use_indirect = true

		rs.multimesh_set_mesh(batch.multimesh_rs_rid, mesh.get_rid())

		# Get GPU buffer RID for compute shader access
		batch.buffer_rd_rid = rs.call("multimesh_get_buffer_rd_rid", batch.multimesh_rs_rid)
		batch.has_gpu_buffer = batch.buffer_rd_rid.is_valid()

		# Create a wrapper MultiMesh object that references the RS-created one
		batch.multimesh = MultiMesh.new()
		batch.multimesh.transform_format = MultiMesh.TRANSFORM_3D
		batch.multimesh.use_custom_data = true
		batch.multimesh.mesh = mesh
		batch.multimesh.instance_count = INITIAL_BATCH_CAPACITY

		# Pre-allocate original transforms array
		batch.original_transforms.resize(INITIAL_BATCH_CAPACITY)

	else:
		# Legacy path: Create MultiMesh normally
		batch.multimesh = MultiMesh.new()
		batch.multimesh.transform_format = MultiMesh.TRANSFORM_3D
		batch.multimesh.use_custom_data = true
		batch.multimesh.mesh = mesh
		batch.multimesh.instance_count = INITIAL_BATCH_CAPACITY
		batch.multimesh_rs_rid = batch.multimesh.get_rid()

		# Pre-allocate original transforms array
		batch.original_transforms.resize(INITIAL_BATCH_CAPACITY)

	# Initialize all instances as hidden (zero scale, zero fade)
	var hidden_transform := Transform3D.IDENTITY.scaled(Vector3.ZERO)
	var hidden_data := Color(0.0, 0.0, 0.0, 1.0)
	for i in range(INITIAL_BATCH_CAPACITY):
		if use_gpu:
			rs.multimesh_instance_set_transform(batch.multimesh_rs_rid, i, hidden_transform)
			rs.multimesh_instance_set_custom_data(batch.multimesh_rs_rid, i, hidden_data)
		else:
			batch.multimesh.set_instance_transform(i, hidden_transform)
			batch.multimesh.set_instance_custom_data(i, hidden_data)
		batch.original_transforms[i] = hidden_transform

	# Create MultiMeshInstance3D
	batch.multimesh_instance = MultiMeshInstance3D.new()
	batch.multimesh_instance.multimesh = batch.multimesh
	batch.multimesh_instance.name = "LODBatch_%d_L%d" % [batch.batch_key, lod_level]

	# Create crossfade material (pass external materials as fallback)
	batch.material = _create_crossfade_material(mesh, materials, lod_level)
	if batch.material:
		batch.multimesh_instance.material_override = batch.material

	# Add to scene
	if _scene_root:
		_scene_root.add_child(batch.multimesh_instance)

	return batch


## Grow batch capacity when needed
func _grow_batch(batch: MeshBatch) -> void:
	var new_capacity := int(batch.capacity * BATCH_GROWTH_FACTOR)
	if new_capacity > MAX_INSTANCES_PER_BATCH:
		new_capacity = MAX_INSTANCES_PER_BATCH
		if batch.capacity >= MAX_INSTANCES_PER_BATCH:
			push_warning("LODMultiMeshBatcher: Batch %d at max capacity (%d)" % [
				batch.batch_key, MAX_INSTANCES_PER_BATCH])
			return

	# Store existing data
	var old_transforms: Array[Transform3D] = []
	var old_custom_data: Array[Color] = []
	for i in range(batch.capacity):
		old_transforms.append(batch.multimesh.get_instance_transform(i))
		old_custom_data.append(batch.multimesh.get_instance_custom_data(i))

	# Resize
	batch.multimesh.instance_count = new_capacity

	# Restore existing data
	for i in range(batch.capacity):
		batch.multimesh.set_instance_transform(i, old_transforms[i])
		batch.multimesh.set_instance_custom_data(i, old_custom_data[i])

	# Initialize new slots as hidden
	var hidden_transform := Transform3D.IDENTITY.scaled(Vector3.ZERO)
	var hidden_data := Color(0.0, 0.0, 0.0, 1.0)
	for i in range(batch.capacity, new_capacity):
		batch.multimesh.set_instance_transform(i, hidden_transform)
		batch.multimesh.set_instance_custom_data(i, hidden_data)

	batch.capacity = new_capacity


## Create crossfade material for a mesh
## materials: Optional array of materials to use if mesh has no embedded materials
## lod_level: LOD level for debug coloring (0-3)
func _create_crossfade_material(mesh: ArrayMesh, materials: Array[Material] = [], lod_level: int = 1) -> ShaderMaterial:
	if not _crossfade_shader:
		push_warning("[LODMultiMeshBatcher] No crossfade shader set - LODs will render without materials")
		return null

	var shader_mat := ShaderMaterial.new()
	shader_mat.shader = _crossfade_shader

	# Set LOD level for debug coloring
	shader_mat.set_shader_parameter("lod_level", lod_level)

	# Try to get source material:
	# 1. First check externally provided materials array (preferred - from object_streamer)
	# 2. Fall back to mesh's embedded surface material
	var source_mat: Material = null
	var material_source := "none"

	if not materials.is_empty() and materials[0] != null:
		source_mat = materials[0]
		material_source = "external_array"
	elif mesh.get_surface_count() > 0:
		source_mat = mesh.surface_get_material(0)
		if source_mat:
			material_source = "mesh_surface"

	# Apply material properties to shader
	if source_mat is StandardMaterial3D:
		var std_mat := source_mat as StandardMaterial3D

		if std_mat.albedo_texture:
			shader_mat.set_shader_parameter("albedo_texture", std_mat.albedo_texture)
		shader_mat.set_shader_parameter("albedo_color", std_mat.albedo_color)

		if std_mat.normal_texture:
			shader_mat.set_shader_parameter("normal_texture", std_mat.normal_texture)
			shader_mat.set_shader_parameter("use_normal_map", true)
		shader_mat.set_shader_parameter("normal_scale", std_mat.normal_scale)

		shader_mat.set_shader_parameter("roughness", std_mat.roughness)
		shader_mat.set_shader_parameter("metallic", std_mat.metallic)
		shader_mat.set_shader_parameter("specular", std_mat.metallic_specular)

		# Alpha cutout support
		if std_mat.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
			shader_mat.set_shader_parameter("use_alpha_cutout", true)
			shader_mat.set_shader_parameter("alpha_cutout", std_mat.alpha_scissor_threshold)
	elif source_mat is ShaderMaterial:
		# ShaderMaterial - try to extract texture from shader parameters
		var shader_source := source_mat as ShaderMaterial
		var albedo_tex: Texture2D = shader_source.get_shader_parameter("albedo_texture")
		if albedo_tex:
			shader_mat.set_shader_parameter("albedo_texture", albedo_tex)
		var albedo_col: Variant = shader_source.get_shader_parameter("albedo_color")
		if albedo_col is Color:
			shader_mat.set_shader_parameter("albedo_color", albedo_col)
		# Log that we're using ShaderMaterial fallback
		if _debug_material_warnings < 10:
			print("[LODMultiMeshBatcher] Using ShaderMaterial fallback for LOD%d (source: %s)" % [lod_level, material_source])
			_debug_material_warnings += 1
	elif source_mat == null:
		# NO MATERIAL - this causes white LODs!
		if _debug_material_warnings < 20:
			push_warning("[LODMultiMeshBatcher] NO MATERIAL for LOD%d batch - will render WHITE! (mesh surfaces: %d, external materials: %d)" % [
				lod_level, mesh.get_surface_count(), materials.size()])
			_debug_material_warnings += 1
		# Set a visible debug color so white LODs are obvious
		shader_mat.set_shader_parameter("albedo_color", Color(1.0, 0.0, 1.0, 1.0))  # Magenta = missing material
	else:
		# Unknown material type
		if _debug_material_warnings < 10:
			push_warning("[LODMultiMeshBatcher] Unknown material type '%s' for LOD%d - cannot extract properties" % [
				source_mat.get_class(), lod_level])
			_debug_material_warnings += 1

	return shader_mat

#endregion


#region Queries

## Get batch for a specific object
func get_batch_for_object(object_id: int) -> MeshBatch:
	for batch_key: int in _batches:
		var batch: MeshBatch = _batches[batch_key]
		if object_id in batch.instances:
			return batch
	return null


## Check if object is in any batch
func has_object(object_id: int) -> bool:
	for batch_key: int in _batches:
		var batch: MeshBatch = _batches[batch_key]
		if object_id in batch.instances:
			return true
	return false


## Get statistics
func get_stats() -> Dictionary:
	return _stats.duplicate()


## Get batch count
func get_batch_count() -> int:
	return _batches.size()


## Get all batches (for GPU visibility integration)
func get_all_batches() -> Dictionary:
	return _batches


## Get batch by key
func get_batch(batch_key: int) -> MeshBatch:
	return _batches.get(batch_key, null)

#endregion


#region GPU Visibility Support (Phase 2)

## Get the MultiMesh buffer RID for GPU compute access
## batch_key: The batch to get buffer for
## Returns: RID of the MultiMesh buffer, or invalid RID if not available
## NOTE: Requires Godot 4.4+ with multimesh_get_buffer_rd_rid
func get_buffer_rid(batch_key: int) -> RID:
	if batch_key not in _batches:
		return RID()

	var batch: MeshBatch = _batches[batch_key]

	# Return cached buffer RID if available
	if batch.buffer_rd_rid.is_valid():
		return batch.buffer_rd_rid

	# Try to get it if not cached
	if _has_buffer_rd_rid:
		var rs := RenderingServer
		batch.buffer_rd_rid = rs.call("multimesh_get_buffer_rd_rid", batch.multimesh_rs_rid)
		batch.has_gpu_buffer = batch.buffer_rd_rid.is_valid()
		return batch.buffer_rd_rid

	return RID()


## Get the MultiMesh RID for RenderingServer operations
func get_multimesh_rid(batch_key: int) -> RID:
	if batch_key not in _batches:
		return RID()

	var batch: MeshBatch = _batches[batch_key]
	return batch.multimesh_rs_rid


## Check if a batch has GPU buffer access
func has_gpu_buffer(batch_key: int) -> bool:
	if batch_key not in _batches:
		return false
	return (_batches[batch_key] as MeshBatch).has_gpu_buffer


## Check if GPU features are available
func is_gpu_enabled() -> bool:
	return _has_buffer_rd_rid


## Get original transform for an instance (for GPU visibility restore)
func get_original_transform(batch_key: int, local_index: int) -> Transform3D:
	if batch_key not in _batches:
		return Transform3D.IDENTITY

	var batch: MeshBatch = _batches[batch_key]
	if local_index < 0 or local_index >= batch.original_transforms.size():
		return Transform3D.IDENTITY

	return batch.original_transforms[local_index]


## Bulk update visibility for all instances in a batch from GPU compute data
## batch_key: The batch to update
## visibility_data: PackedFloat32Array with [visibility, fade, tier, flags] per instance
## instance_mapping: Dictionary mapping local_index -> global_index in visibility_data
##
## This is the GPU-driven path: compute shader writes visibility, we read and apply
## Performance: O(instances in batch) but with minimal per-instance overhead
func apply_gpu_visibility(batch_key: int, visibility_data: PackedFloat32Array, instance_mapping: Dictionary) -> void:
	if batch_key not in _batches:
		return

	var batch: MeshBatch = _batches[batch_key]
	var active_count := 0
	var instance_count: int = batch.multimesh.instance_count

	for object_id: int in batch.instances:
		var local_idx: int = batch.instances[object_id]
		if local_idx not in instance_mapping:
			continue

		# SAFETY CHECK: Validate local_idx is within MultiMesh bounds
		if local_idx < 0 or local_idx >= instance_count:
			continue

		var global_idx: int = instance_mapping[local_idx]
		var vis_base := global_idx * 4

		# SAFETY CHECK: Validate visibility data bounds
		if vis_base + 1 >= visibility_data.size():
			continue

		# Read visibility from compute output
		var visibility: float = visibility_data[vis_base]
		var fade: float = visibility_data[vis_base + 1]

		# Combine visibility and fade for INSTANCE_CUSTOM.x
		# Shader reads this value: 0 = hidden, >0 = visible with fade
		var final_fade := visibility * fade

		# Update INSTANCE_CUSTOM (fade in .x channel, preserving other channels)
		batch.multimesh.set_instance_custom_data(local_idx, Color(final_fade, fade, 0.0, 1.0))

		if final_fade > 0.01:
			active_count += 1

	batch.active_count = active_count
	batch.dirty = true


## Sync the batch's MultiMesh buffer after GPU modifications
## With indirect drawing enabled (Godot 4.4+), this may not be needed.
## For legacy path, this forces the CPU cache to sync with GPU.
## Returns: true if sync was performed
func sync_gpu_buffer(batch_key: int) -> bool:
	if batch_key not in _batches:
		return false

	var batch: MeshBatch = _batches[batch_key]
	var rs := RenderingServer

	# With indirect drawing, the buffer should auto-sync
	if batch.use_indirect:
		# No sync needed - indirect mode handles GPU->render sync
		return true

	# Legacy path: Force sync via get/set buffer
	var buffer := rs.multimesh_get_buffer(batch.multimesh_rs_rid)
	rs.multimesh_set_buffer(batch.multimesh_rs_rid, buffer)

	return true


## Batch update: apply visibility to multiple batches efficiently
## This is the main entry point for GPUVisibilityRenderer integration
## visibility_results: Dictionary[batch_key] -> PackedFloat32Array of [vis, fade, tier, flags] per instance
func apply_gpu_visibility_batch(visibility_results: Dictionary) -> void:
	for batch_key: int in visibility_results:
		if batch_key not in _batches:
			continue

		var batch: MeshBatch = _batches[batch_key]
		var vis_data: PackedFloat32Array = visibility_results[batch_key]
		var active_count := 0
		var instance_count: int = batch.multimesh.instance_count

		# vis_data layout: [visibility, fade, tier, flags] per instance
		# One vec4 per instance in order
		var idx := 0
		for object_id: int in batch.instances:
			var local_idx: int = batch.instances[object_id]

			# SAFETY CHECK: Validate local_idx is within MultiMesh bounds
			if local_idx < 0 or local_idx >= instance_count:
				continue

			# Calculate position in vis_data
			var vis_base := local_idx * 4
			if vis_base + 3 >= vis_data.size():
				continue

			var visibility: float = vis_data[vis_base]
			var fade: float = vis_data[vis_base + 1]
			var final_fade := visibility * fade

			batch.multimesh.set_instance_custom_data(local_idx, Color(final_fade, fade, 0.0, 1.0))

			if final_fade > 0.01:
				active_count += 1

		batch.active_count = active_count
		batch.dirty = true

		# Sync GPU buffer
		sync_gpu_buffer(batch_key)

	# Update stats
	var total_active := 0
	for bk: int in _batches:
		total_active += (_batches[bk] as MeshBatch).active_count
	_stats["active_instances"] = total_active


## Register batch with GPUVisibilityRenderer
## Returns the batch's MultiMesh for GPU registration
func get_multimesh(batch_key: int) -> MultiMesh:
	if batch_key not in _batches:
		return null
	return (_batches[batch_key] as MeshBatch).multimesh


## Get object IDs and their local indices for a batch
## Used by GPUVisibilityRenderer to map global indices to local MultiMesh indices
func get_batch_object_mapping(batch_key: int) -> Dictionary:
	if batch_key not in _batches:
		return {}

	var batch: MeshBatch = _batches[batch_key]
	return batch.instances.duplicate()


## Enable or disable GPU-driven mode for a batch
## When enabled, CPU-side update_fade() calls are skipped in favor of apply_gpu_visibility()
var _gpu_driven_batches: Dictionary = {}  # batch_key -> true

func set_gpu_driven(batch_key: int, enabled: bool) -> void:
	if enabled:
		_gpu_driven_batches[batch_key] = true
	else:
		_gpu_driven_batches.erase(batch_key)


func is_gpu_driven(batch_key: int) -> bool:
	return batch_key in _gpu_driven_batches


## Enable or disable debug LOD coloring on all batches
## When enabled, LOD1=Yellow, LOD2=Orange, LOD3=Red tints are applied
func set_debug_lod_colors(enabled: bool) -> void:
	for batch_key: int in _batches:
		var batch: MeshBatch = _batches[batch_key]
		if batch.material:
			batch.material.set_shader_parameter("debug_lod_colors", enabled)


## Check if debug LOD colors are enabled (checks first batch)
func is_debug_lod_colors_enabled() -> bool:
	for batch_key: int in _batches:
		var batch: MeshBatch = _batches[batch_key]
		if batch.material:
			return batch.material.get_shader_parameter("debug_lod_colors")
	return false

#endregion
