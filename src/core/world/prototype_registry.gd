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
	var local_transform: Transform3D  ## sub-mesh local — composed with world at show/transform time

	func _init(p_batch: RefCounted, p_slot: int, p_local: Transform3D = Transform3D.IDENTITY) -> void:
		batch = p_batch
		slot = p_slot
		local_transform = p_local

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

## Cull tick gate — set true by any mutation (add/remove/transform/hide/show)
## and consumed on the next tick_cull_if_needed call. Eliminates the no-op
## path when the frame had zero churn and the camera didn't move.
var _cull_dirty: bool = true

## Last camera position we ticked a cull from. Used with _cull_dist_threshold²
## to decide whether movement alone warrants a fresh tick.
var _last_cull_cam_pos: Vector3 = Vector3.INF

## Distance (in world units) the camera must move before we re-cull on a
## "static world" frame. §5 of the design doc calls for 10 m.
const CULL_DISTANCE_HYSTERESIS: float = 10.0

## Native C# cull kernel (WorldMidCuller). Lazily instantiated via
## NativeBridge on the first tick. Null when C# isn't available; batches
## then fall back to the GDScript cull_and_upload path.
var _native_culler: RefCounted = null
var _native_checked: bool = false

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

		slots[i] = InstanceSlot.new(batch, slot, local_xform)

	_instance_slots[p_instance_id] = slots
	_cull_dirty = true


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
	_cull_dirty = true
	return true


## Whether an instance_id is currently registered.
func has_instance(p_instance_id: int) -> bool:
	return _instance_slots.has(p_instance_id)


## Return the batch+slot tuples owned by an instance. Returns empty if unknown.
## Exposed for static_object_renderer's promotion path (MID→NEAR handoff needs
## to read the slot's world transform to position the Node3D, then release it).
func get_instance_slots(p_instance_id: int) -> Array:
	return _instance_slots.get(p_instance_id, [] as Array)


## Rewrite every slot of an instance with a new world transform. Per-slot world
## xform = p_world_transform * slot.local_transform. No-op for unknown ids.
func set_instance_transform(p_instance_id: int, p_world_transform: Transform3D) -> void:
	var slots_variant: Variant = _instance_slots.get(p_instance_id)
	if slots_variant == null:
		return
	var slots: Array = slots_variant
	for entry: InstanceSlot in slots:
		if entry.batch != null:
			entry.batch.set_slot_transform(entry.slot, p_world_transform * entry.local_transform)
	_cull_dirty = true


## Hide all slots of an instance (zero-scale degenerate transform). Slot stays
## allocated — paired with show_instance() / set_instance_transform() to restore.
## Used for promote (MID→NEAR handoff) and cell hide.
func hide_instance(p_instance_id: int) -> void:
	var slots_variant: Variant = _instance_slots.get(p_instance_id)
	if slots_variant == null:
		return
	var slots: Array = slots_variant
	for entry: InstanceSlot in slots:
		if entry.batch != null:
			entry.batch.set_slot_transform(entry.slot, _HIDDEN_XFORM)
	_cull_dirty = true


## Restore a hidden/promoted instance's slots to a live world transform.
func show_instance(p_instance_id: int, p_world_transform: Transform3D) -> void:
	set_instance_transform(p_instance_id, p_world_transform)


## Zero-scale transform at origin — degenerate triangles, free on GPU.
const _HIDDEN_XFORM: Transform3D = Transform3D(
	Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3.ZERO
)

#endregion


#region Cull driver (step 4)

## Per-frame entry point from native_streaming_manager._process. Ticks a
## full cull pass across every batch if the set is dirty OR the camera has
## moved at least CULL_DISTANCE_HYSTERESIS since the previous tick.
##
## Returns the total visible slot count this tick (0 if skipped).
func tick_cull_if_needed(cam_pos: Vector3, max_dist_sq: float) -> int:
	var dx: float = cam_pos.x - _last_cull_cam_pos.x
	var dz: float = cam_pos.z - _last_cull_cam_pos.z
	var moved_sq: float = dx * dx + dz * dz
	var needs_tick: bool = _cull_dirty or moved_sq >= CULL_DISTANCE_HYSTERESIS * CULL_DISTANCE_HYSTERESIS

	if not needs_tick:
		return -1

	## Lazily spin up the C# culler on first real tick.
	if not _native_checked:
		_native_checked = true
		var bridge := NativeBridge.new()
		_native_culler = bridge.create_world_mid_culler()

	var total_visible: int = 0
	for key: int in _batches:
		var batch: RefCounted = _batches[key]
		if batch != null:
			total_visible += batch.cull_and_upload(cam_pos, max_dist_sq, _native_culler)

	_cull_dirty = false
	_last_cull_cam_pos = cam_pos
	return total_visible


## Force the next tick_cull_if_needed to actually run, regardless of camera
## distance / dirty state. Exposed for console diagnostics.
func force_cull_next_tick() -> void:
	_cull_dirty = true

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


## Diagnostic: batch size distribution + mesh/material sharing stats.
##
## Returns a dict with per-batch live-slot histogram, slot distribution summary
## (min/mean/median/p90/p95/max), and the count of mesh_rids that appear across
## multiple batches (keyed by differing material_rid). Material-sharing across
## distinct meshes is the main dedup-candidate signal — if many batches have
## the same mesh_rid but different material_rids, the prebaker's material dedup
## missed them and they'd coalesce if the key widened. Conversely, if the
## distribution is flat with 27 slots/batch everywhere, the 535-batch count is
## intrinsic to the world and the render cost is submission overhead, not
## fragmentation.
##
## Cheap: O(batches) walk, no RS calls, safe to invoke every frame (though
## consumers should gate on a console command or benchmark hook).
##
## Output keys:
##   - batches                 total batch count
##   - total_live_slots        sum of slot_count_live across batches
##   - empty_batches           count of batches with 0 live slots (held but unused)
##   - slots_min/max/mean/median/p90/p95
##   - histogram {1, 2-5, 6-20, 21-100, 100+}
##   - mesh_shared_count       number of mesh_rids present in ≥2 distinct batches
##   - mesh_shared_fanout_max  the highest per-mesh-rid batch count (worst offender)
##   - top_meshes_by_slots     array of {mesh_id, total_slots, batches} for the
##                             top 10 mesh_rids by aggregate slot count
func get_batch_distribution() -> Dictionary:
	var slot_counts: PackedInt32Array = PackedInt32Array()
	var total_live := 0
	var empty := 0
	var hist_1 := 0
	var hist_2_5 := 0
	var hist_6_20 := 0
	var hist_21_100 := 0
	var hist_100p := 0
	var mesh_to_slots: Dictionary[int, int] = {}
	var mesh_to_batches: Dictionary[int, int] = {}

	for key: int in _batches:
		var batch: RefCounted = _batches[key]
		if batch == null:
			continue
		var live: int = batch.slot_count_live
		slot_counts.append(live)
		total_live += live
		if live == 0:
			empty += 1
		if live == 1:
			hist_1 += 1
		elif live <= 5:
			hist_2_5 += 1
		elif live <= 20:
			hist_6_20 += 1
		elif live <= 100:
			hist_21_100 += 1
		else:
			hist_100p += 1
		var mesh_id: int = int(batch.mesh_rid.get_id()) if batch.mesh_rid.is_valid() else 0
		mesh_to_slots[mesh_id] = mesh_to_slots.get(mesh_id, 0) + live
		mesh_to_batches[mesh_id] = mesh_to_batches.get(mesh_id, 0) + 1

	slot_counts.sort()
	var n: int = slot_counts.size()
	var slots_min: int = 0
	var slots_max: int = 0
	var slots_mean: float = 0.0
	var slots_median: int = 0
	var slots_p90: int = 0
	var slots_p95: int = 0
	if n > 0:
		slots_min = slot_counts[0]
		slots_max = slot_counts[n - 1]
		slots_mean = float(total_live) / float(n)
		slots_median = slot_counts[n / 2]
		slots_p90 = slot_counts[mini(n - 1, int(float(n) * 0.90))]
		slots_p95 = slot_counts[mini(n - 1, int(float(n) * 0.95))]

	var mesh_shared_count: int = 0
	var mesh_shared_fanout_max: int = 0
	for mesh_id: int in mesh_to_batches:
		var c: int = mesh_to_batches[mesh_id]
		if c >= 2:
			mesh_shared_count += 1
		if c > mesh_shared_fanout_max:
			mesh_shared_fanout_max = c

	# Top-10 mesh_rids by aggregate slot count — helps narrow where the
	# biggest coalesce wins would land (e.g. "terrain_rock_01 appears in 12
	# batches with 8 000 total slots → biggest lever if its materials dedup").
	var mesh_ids: Array[int] = []
	mesh_ids.assign(mesh_to_slots.keys())
	mesh_ids.sort_custom(func(a: int, b: int) -> bool:
		return mesh_to_slots[a] > mesh_to_slots[b])
	var top: Array[Dictionary] = []
	var top_limit: int = mini(10, mesh_ids.size())
	for i in range(top_limit):
		var mid: int = mesh_ids[i]
		top.append({
			"mesh_id": mid,
			"total_slots": mesh_to_slots[mid],
			"batches": mesh_to_batches[mid],
		})

	return {
		"batches": n,
		"total_live_slots": total_live,
		"empty_batches": empty,
		"slots_min": slots_min,
		"slots_max": slots_max,
		"slots_mean": slots_mean,
		"slots_median": slots_median,
		"slots_p90": slots_p90,
		"slots_p95": slots_p95,
		"histogram": {
			"1": hist_1,
			"2-5": hist_2_5,
			"6-20": hist_6_20,
			"21-100": hist_21_100,
			"100+": hist_100p,
		},
		"mesh_shared_count": mesh_shared_count,
		"mesh_shared_fanout_max": mesh_shared_fanout_max,
		"top_meshes_by_slots": top,
	}

#endregion


#region Cleanup

func cleanup() -> void:
	for key: int in _batches:
		(_batches[key] as RefCounted).cleanup()
	_batches.clear()
	_instance_slots.clear()

#endregion
