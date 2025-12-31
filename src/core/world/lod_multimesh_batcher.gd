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
## This follows the same pattern as ImpostorManager's MultiMesh usage.
class_name LODMultiMeshBatcher
extends RefCounted

## Preload distance utilities
const DU := preload("res://src/core/world/distance_utils.gd")

## Initial capacity for new batches (will grow as needed)
const INITIAL_BATCH_CAPACITY := 32

## Maximum instances per batch before logging warning
const MAX_INSTANCES_PER_BATCH := 512

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

## Statistics
var _stats: Dictionary = {
	"total_batches": 0,
	"total_instances": 0,
	"active_instances": 0,
	"draw_calls": 0,
}


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
			_grow_batch(batch)

	# Set transform and custom data
	batch.multimesh.set_instance_transform(instance_idx, transform)
	batch.multimesh.set_instance_custom_data(instance_idx, Color(fade_amount, 0.0, 0.0, 1.0))

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

	# Create new batch (pass materials for shader creation)
	var batch := _create_batch(mesh, lod_level, materials)
	if not batch:
		return null

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

	# Create MultiMesh
	batch.multimesh = MultiMesh.new()
	batch.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	batch.multimesh.use_custom_data = true
	batch.multimesh.mesh = mesh
	batch.multimesh.instance_count = INITIAL_BATCH_CAPACITY

	# Initialize all instances as hidden (zero scale, zero fade)
	var hidden_transform := Transform3D.IDENTITY.scaled(Vector3.ZERO)
	var hidden_data := Color(0.0, 0.0, 0.0, 1.0)
	for i in range(INITIAL_BATCH_CAPACITY):
		batch.multimesh.set_instance_transform(i, hidden_transform)
		batch.multimesh.set_instance_custom_data(i, hidden_data)

	# Create MultiMeshInstance3D
	batch.multimesh_instance = MultiMeshInstance3D.new()
	batch.multimesh_instance.multimesh = batch.multimesh
	batch.multimesh_instance.name = "LODBatch_%d_L%d" % [batch.batch_key, lod_level]

	# Create crossfade material (pass external materials as fallback)
	batch.material = _create_crossfade_material(mesh, materials)
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
func _create_crossfade_material(mesh: ArrayMesh, materials: Array[Material] = []) -> ShaderMaterial:
	if not _crossfade_shader:
		return null

	var shader_mat := ShaderMaterial.new()
	shader_mat.shader = _crossfade_shader

	# Try to get source material:
	# 1. First check mesh's embedded surface material
	# 2. Fall back to externally provided materials array
	var source_mat: Material = null
	if mesh.get_surface_count() > 0:
		source_mat = mesh.surface_get_material(0)
	if source_mat == null and not materials.is_empty():
		source_mat = materials[0]

	# Apply material properties to shader
	if source_mat is StandardMaterial3D:
		var std_mat := source_mat as StandardMaterial3D

		if std_mat.albedo_texture:
			shader_mat.set_shader_parameter("albedo_texture", std_mat.albedo_texture)
		shader_mat.set_shader_parameter("albedo_color", std_mat.albedo_color)

		if std_mat.normal_texture:
			shader_mat.set_shader_parameter("normal_texture", std_mat.normal_texture)
		shader_mat.set_shader_parameter("normal_scale", std_mat.normal_scale)

		shader_mat.set_shader_parameter("roughness", std_mat.roughness)
		shader_mat.set_shader_parameter("metallic", std_mat.metallic)
		shader_mat.set_shader_parameter("specular", std_mat.metallic_specular)

		# Alpha cutout support
		if std_mat.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
			shader_mat.set_shader_parameter("use_alpha_cutout", true)
			shader_mat.set_shader_parameter("alpha_cutout", std_mat.alpha_scissor_threshold)

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

#endregion
