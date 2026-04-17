## PrototypeRegistry - World-scoped per-prototype MultiMesh bucket manager.
##
## Holds one PrototypeBatch per unique (mesh_rid, material_rid) hash across all
## loaded cells. An instance of the prototype adds itself to the batch via
## add_instance(); on cell unload it's removed via remove_instance(). Instances
## that span multiple sub-meshes (buildings) land in one slot per sub-mesh,
## keyed by this registry.
##
## Scope (step 1 skeleton, per §13 of
## docs/audit/PHASE_3_MID_MULTIMESH_DESIGN.md):
## - Batch lookup / creation (get_or_create_batch).
## - Multi-slot instance bookkeeping (an instance can claim slots across N
##   batches — one slot per sub-mesh of a multi-mesh prototype).
## - No cull pass yet — registry exposes iter_batches() for the future cull
##   driver (step 4+).
## - No cell/streaming integration yet — wiring into static_object_renderer
##   lands in step 2.
##
## Deliberately NO class_name (parity with prototype_batch.gd — see comment
## there). Consumers preload this script as a Script const.
extends RefCounted


const PrototypeBatchScript := preload("res://src/core/world/prototype_batch.gd")


#region Types

## Entry in _instance_slots — one batch/slot pair that belongs to an instance.
## `batch` is typed as RefCounted because PrototypeBatchScript is the type
## carrier and GDScript inner classes can't use a preloaded Script as a type
## annotation. Cast via `entry.batch as RefCounted` at call sites.
class InstanceSlot:
	var batch: RefCounted
	var slot: int

	func _init(p_batch: RefCounted, p_slot: int) -> void:
		batch = p_batch
		slot = p_slot

#endregion


#region Fields

## World scenario RID — passed to every new batch.
var _scenario: RID

## All batches, keyed by _batch_key(mesh_rid, material_rid). Value is a
## PrototypeBatchScript instance (typed as RefCounted here to sidestep the
## no-class_name constraint).
var _batches: Dictionary[int, RefCounted] = {}

## Per-instance slot ownership. instance_id -> Array[InstanceSlot].
## A single-mesh prototype instance has size 1; a 5-sub-mesh canton has size 5.
var _instance_slots: Dictionary[int, Array] = {}

## Configurable initial capacity for newly-created batches.
var initial_batch_capacity: int = 1024

#endregion


func _init(p_scenario: RID) -> void:
	assert(p_scenario.is_valid(), "PrototypeRegistry: scenario must be valid")
	_scenario = p_scenario


#region Batch lookup

## Compose a stable 64-bit key from two RIDs. RIDs hash to int64; we use a
## 32-bit split (OK because RID IDs in Godot fit in ~24 bits in practice,
## though this is not a hard contract). Collision would require two RIDs with
## the same low-32 bits which is astronomically unlikely for the scales we
## operate on (~1000 prototypes × ~50 materials), but if a collision ever
## matters the fix is a String key or hashing.
static func batch_key(p_mesh_rid: RID, p_material_rid: RID) -> int:
	var mesh_id: int = int(p_mesh_rid.get_id()) if p_mesh_rid.is_valid() else 0
	var material_id: int = int(p_material_rid.get_id()) if p_material_rid.is_valid() else 0
	## Fold both into a 64-bit composite; mesh in high bits, material in low.
	return (mesh_id << 32) | (material_id & 0xFFFFFFFF)


## Get the existing batch for a (mesh, material) pair, or create one on demand.
## Return type is RefCounted (underlying instance is PrototypeBatchScript).
func get_or_create_batch(p_mesh: Mesh, p_material: Material) -> RefCounted:
	assert(p_mesh != null, "PrototypeRegistry.get_or_create_batch: mesh must not be null")
	var mesh_rid: RID = p_mesh.get_rid()
	var material_rid: RID = p_material.get_rid() if p_material != null else RID()
	var key: int = batch_key(mesh_rid, material_rid)

	var existing: RefCounted = _batches.get(key)
	if existing != null:
		return existing

	var created: RefCounted = PrototypeBatchScript.new(p_mesh, p_material, _scenario, initial_batch_capacity)
	_batches[key] = created
	return created


## Look up a batch without creating. Returns null if not present.
func find_batch(p_mesh_rid: RID, p_material_rid: RID) -> RefCounted:
	return _batches.get(batch_key(p_mesh_rid, p_material_rid))

#endregion


#region Instance lifecycle

## Register an instance with one or more (mesh, material, local_transform) tuples.
## For single-mesh prototypes, pass one tuple. For multi-sub-mesh buildings, pass N.
##
## `p_sub_meshes` is an Array of {mesh: Mesh, material: Material, local_transform: Transform3D}
## dictionaries (plain Array[Dictionary] so the call site matches what
## static_object_renderer's MeshType.sub_meshes shape looks like).
##
## `p_world_transform` is the instance's root transform; per-sub-mesh world
## transform is `p_world_transform * local_transform`.
##
## Returns the instance_id for subsequent remove_instance() calls. instance_id
## is the caller's responsibility to assign uniquely; typically this is the
## static_object_renderer's _next_id counter.
func add_instance(
	p_instance_id: int,
	p_sub_meshes: Array,
	p_world_transform: Transform3D,
	p_spawn_time: float,
	p_fade_duration: float
) -> void:
	assert(not _instance_slots.has(p_instance_id),
		"PrototypeRegistry.add_instance: instance_id %d already registered" % p_instance_id)
	assert(not p_sub_meshes.is_empty(),
		"PrototypeRegistry.add_instance: sub_meshes must not be empty")

	var slots: Array[InstanceSlot] = []
	slots.resize(p_sub_meshes.size())

	var custom_data := Color(p_spawn_time, p_fade_duration, 0.0, 0.0)

	for i in range(p_sub_meshes.size()):
		var sm: Dictionary = p_sub_meshes[i]
		var mesh: Mesh = sm.get("mesh")
		var material: Material = sm.get("material")
		var local_xform: Transform3D = sm.get("local_transform", Transform3D.IDENTITY)

		var batch: RefCounted = get_or_create_batch(mesh, material)
		var slot: int = batch.acquire_slot()
		batch.set_slot_transform(slot, p_world_transform * local_xform)
		batch.set_slot_custom_data(slot, custom_data)

		slots[i] = InstanceSlot.new(batch, slot)

	_instance_slots[p_instance_id] = slots


## Release all slots owned by this instance. Idempotent — calling with an
## unknown instance_id is a no-op (returns false).
func remove_instance(p_instance_id: int) -> bool:
	var slots_variant: Variant = _instance_slots.get(p_instance_id)
	if slots_variant == null:
		return false
	var slots: Array = slots_variant
	for entry: InstanceSlot in slots:
		if entry.batch != null:
			entry.batch.release_slot(entry.slot)
	_instance_slots.erase(p_instance_id)
	return true


## Whether an instance_id is currently registered.
func has_instance(p_instance_id: int) -> bool:
	return _instance_slots.has(p_instance_id)


## Return the batch+slot tuples owned by an instance. Returns empty if unknown.
## Exposed for static_object_renderer's promotion path (MID→NEAR handoff needs
## to read the slot's world transform to position the Node3D, then release it).
func get_instance_slots(p_instance_id: int) -> Array:
	return _instance_slots.get(p_instance_id, [] as Array)

#endregion


#region Cull iteration hook (step 4+)

## All batches — consumed by the future cull driver to iterate live slots and
## write packed visible buffers. Returns Array[RefCounted] (underlying type is
## PrototypeBatchScript per §class_name comment).
func iter_batches() -> Array[RefCounted]:
	var out: Array[RefCounted] = []
	out.resize(_batches.size())
	var i := 0
	for key: int in _batches:
		out[i] = _batches[key]
		i += 1
	return out


func get_batch_count() -> int:
	return _batches.size()


func get_total_live_slots() -> int:
	var total := 0
	for key: int in _batches:
		total += (_batches[key] as RefCounted).slot_count_live
	return total

#endregion


#region Cleanup

func cleanup() -> void:
	for key: int in _batches:
		(_batches[key] as RefCounted).cleanup()
	_batches.clear()
	_instance_slots.clear()

#endregion
