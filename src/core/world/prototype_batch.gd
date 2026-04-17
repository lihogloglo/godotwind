## PrototypeBatch - One MultiMesh bucket for a single (mesh, material) prototype.
##
## Owns a single MultiMesh + RenderingServer instance anchored at world origin.
## All active instances of the prototype (across all loaded cells) occupy a slot
## in this batch's MultiMesh. Visibility/culling is driven externally by the
## owning PrototypeRegistry (Phase 3 of
## docs/audit/PHASE_3_MID_MULTIMESH_DESIGN.md).
##
## Scope (step 1 skeleton):
## - Slot lifecycle only (acquire / release / transform / custom_data writes).
## - No per-frame cull pass — that is the registry's job (step 4+ of §13).
## - No C# integration — lands in step 5.
##
## Usage:
##   var batch := PrototypeBatch.new(mesh_resource, material_resource, scenario, 1024)
##   var slot := batch.acquire_slot()
##   batch.set_slot_transform(slot, xform)
##   batch.set_slot_custom_data(slot, Color(spawn_time, fade_duration, 0, 0))
##   ...
##   batch.release_slot(slot)
##   batch.cleanup()
##
## Deliberately NO class_name — prototype_registry.gd preloads this script as a
## Script const and uses it for typing. Class-name-free avoids the gdUnit4
## test-scan ordering issue where the test file can't see the class_name before
## the source files are fully loaded.
extends RefCounted

## Stride for packed transform rows in multimesh_set_buffer (floats).
## 12 = 3x4 row-major affine transform (Godot's MULTIMESH 3D layout).
## Confirmed against native_impostor_renderer.gd:1757-1826 known-good path.
const TRANSFORM_STRIDE: int = 12

## Stride for custom_data rows (floats).
const CUSTOM_DATA_STRIDE: int = 4

## Default grow factor for capacity.
const GROW_FACTOR: int = 2


#region Fields

## Strong ref to the prototype's mesh. Keeps the RID valid through the
## batch's lifetime even if the ModelLoader LRU-evicts the prototype.
var mesh_resource: Mesh

## Strong ref to the whole-mesh material override (may be null — some MW
## STATs use mesh-baked per-surface materials).
var material_resource: Material

var mesh_rid: RID                    ## Cached = mesh_resource.get_rid()
var material_rid: RID                ## Cached = material_resource.get_rid() or invalid

var multimesh: MultiMesh             ## Strong ref
var multimesh_rid: RID               ## Cached = multimesh.get_rid()
var rs_instance: RID                 ## Single world-origin RS instance
var scenario: RID

var slot_capacity: int = 0
var slot_count_live: int = 0

## Freelist of released slot indices available for reuse.
var slot_freelist: PackedInt32Array = PackedInt32Array()

## Per-slot aliveness byte. 1 = live (part of the render set), 0 = free.
## Indexed by slot id. Used by the cull pass (step 4+) to iterate only live slots.
var slot_live: PackedByteArray = PackedByteArray()

#endregion


## Create a new prototype batch. Caller passes the Mesh (strong ref required
## for MultiMesh.mesh) and an optional material override.
func _init(
	p_mesh: Mesh,
	p_material: Material,
	p_scenario: RID,
	p_initial_capacity: int = 1024
) -> void:
	assert(p_mesh != null, "PrototypeBatch: mesh must not be null")
	assert(p_scenario.is_valid(), "PrototypeBatch: scenario must be valid")
	assert(p_initial_capacity > 0, "PrototypeBatch: initial_capacity must be > 0")

	mesh_resource = p_mesh
	material_resource = p_material
	mesh_rid = p_mesh.get_rid()
	material_rid = p_material.get_rid() if p_material != null else RID()
	scenario = p_scenario

	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_custom_data = true
	multimesh.mesh = mesh_resource
	multimesh.instance_count = p_initial_capacity
	multimesh_rid = multimesh.get_rid()

	var rs := RenderingServer
	rs_instance = rs.instance_create()
	rs.instance_set_base(rs_instance, multimesh_rid)
	rs.instance_set_scenario(rs_instance, scenario)
	rs.instance_set_transform(rs_instance, Transform3D.IDENTITY)  ## World-origin anchor.

	if material_rid.is_valid():
		rs.instance_geometry_set_material_override(rs_instance, material_rid)

	## Start with nothing visible — visible_instance_count = 0 until a cull pass
	## fills in. Prevents zero-transformed slots from leaking into the render
	## set before any instance is added.
	rs.multimesh_set_visible_instances(multimesh_rid, 0)

	_resize_capacity_internal(p_initial_capacity)


#region Slot lifecycle

## Acquire the next free slot. Grows capacity on demand.
##
## Returns the slot index. Caller is expected to follow up with set_slot_transform
## and (optionally) set_slot_custom_data before the next cull pass runs.
func acquire_slot() -> int:
	if slot_freelist.is_empty():
		_grow()

	var slot: int = slot_freelist[slot_freelist.size() - 1]
	slot_freelist.resize(slot_freelist.size() - 1)

	slot_live[slot] = 1
	slot_count_live += 1
	return slot


## Release a previously-acquired slot back to the freelist.
## The slot's transform is collapsed to zero-scale so pre-cull state is safe
## (degenerate triangles cost effectively nothing on GPU if they somehow leak
## into the render set before the next cull tick clears visible_instance_count).
func release_slot(slot: int) -> void:
	if slot < 0 or slot >= slot_capacity:
		push_warning("PrototypeBatch.release_slot: out-of-range slot %d (cap=%d)" % [slot, slot_capacity])
		return
	if slot_live[slot] == 0:
		push_warning("PrototypeBatch.release_slot: slot %d already free (double-release)" % slot)
		return

	slot_live[slot] = 0
	slot_count_live -= 1
	slot_freelist.append(slot)

	## Zero-scale the transform defensively. The cull pass would normally
	## overwrite this on the next tick, but if a cell unload triggers a
	## release without an immediate cull tick we don't want the stale
	## transform to be rendered.
	multimesh.set_instance_transform(slot, _ZERO_SCALE_XFORM)


## Write a world transform into a slot.
func set_slot_transform(slot: int, xform: Transform3D) -> void:
	if slot < 0 or slot >= slot_capacity:
		push_error("PrototypeBatch.set_slot_transform: out-of-range slot %d (cap=%d)" % [slot, slot_capacity])
		return
	multimesh.set_instance_transform(slot, xform)


## Write a 4-float custom data payload into a slot. Layout documented in
## PHASE_3_MID_MULTIMESH_DESIGN.md §6 (R=spawn_time, G=fade_duration,
## B=reserved, A=reserved).
func set_slot_custom_data(slot: int, data: Color) -> void:
	if slot < 0 or slot >= slot_capacity:
		push_error("PrototypeBatch.set_slot_custom_data: out-of-range slot %d (cap=%d)" % [slot, slot_capacity])
		return
	multimesh.set_instance_custom_data(slot, data)

#endregion


#region Capacity growth

func _grow() -> void:
	var new_capacity: int = maxi(slot_capacity * GROW_FACTOR, slot_capacity + 1)
	_resize_capacity_internal(new_capacity)


func _resize_capacity_internal(new_capacity: int) -> void:
	assert(new_capacity >= slot_capacity, "_resize_capacity_internal: cannot shrink")

	var old_capacity := slot_capacity
	slot_live.resize(new_capacity)
	for i in range(old_capacity, new_capacity):
		slot_live[i] = 0

	## Push newly-available slots onto the freelist in descending order so
	## acquire_slot (pop_back) hands back ascending indices — better spatial
	## coherency in the packed buffer and in the MultiMesh internal layout.
	for i in range(new_capacity - 1, old_capacity - 1, -1):
		slot_freelist.append(i)

	if multimesh != null:
		multimesh.instance_count = new_capacity
	slot_capacity = new_capacity

#endregion


#region Introspection (mostly for tests / debug HUD)

func get_stats() -> Dictionary:
	return {
		"capacity": slot_capacity,
		"live": slot_count_live,
		"free": slot_freelist.size(),
	}

#endregion


#region Cleanup

func cleanup() -> void:
	var rs := RenderingServer
	if rs_instance.is_valid():
		rs.free_rid(rs_instance)
		rs_instance = RID()
	## multimesh + its RID are owned by the strong ref — Godot frees when
	## this RefCounted's refcount drops to 0. Null the strong refs so
	## lingering references to the batch don't keep the MM alive.
	multimesh = null
	multimesh_rid = RID()
	mesh_resource = null
	material_resource = null
	slot_live = PackedByteArray()
	slot_freelist = PackedInt32Array()
	slot_capacity = 0
	slot_count_live = 0

#endregion


#region Helpers

## Cached zero-scale transform for released slots — degenerate triangles at the
## origin, effectively free on GPU.
const _ZERO_SCALE_XFORM: Transform3D = Transform3D(
	Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3.ZERO
)

#endregion
