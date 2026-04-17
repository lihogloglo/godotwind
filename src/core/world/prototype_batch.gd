## PrototypeBatch - One MultiMesh bucket for a single (mesh, material) prototype.
##
## Owns a single MultiMesh + RenderingServer instance anchored at world origin.
## All active instances of the prototype (across all loaded cells) occupy a slot
## in this batch's MultiMesh. Visibility/culling is driven externally by the
## owning PrototypeRegistry (Phase 3 of
## docs/audit/PHASE_3_MID_MULTIMESH_DESIGN.md).
##
## Ownership model (post-step-4 refactor):
##   - Per-slot transforms + custom_data live in PrototypeBatch's own
##     PackedFloat32Array fields (slot_transforms, slot_custom_data).
##   - The MultiMesh's internal buffer is only ever written via
##     RenderingServer.multimesh_set_buffer during cull_and_upload — never via
##     per-slot set_instance_transform. This keeps slot indexing coherent
##     with visible_instance_count (engine renders the first N slots in the
##     packed buffer; our packing decides which live slots go in first).
##   - Pre-cull state: visible_instance_count = 0, nothing renders. Caller
##     MUST tick cull_and_upload after adds for the instances to appear.
##
## Usage:
##   var batch := PrototypeBatch.new(mesh_resource, material_resource, scenario, 1024)
##   var slot := batch.acquire_slot()
##   batch.set_slot_transform(slot, xform)
##   batch.set_slot_custom_data(slot, Color(spawn_time, fade_duration, 0, 0))
##   ...
##   batch.cull_and_upload(cam_pos, max_dist_sq)
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

## Total packed stride per slot in the cull output buffer.
const PACKED_STRIDE: int = TRANSFORM_STRIDE + CUSTOM_DATA_STRIDE  # 16

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
## Indexed by slot id. cull_and_upload iterates this.
var slot_live: PackedByteArray = PackedByteArray()

## Per-slot world transform, row-major 3x4 (12 floats per slot).
## Total size = slot_capacity * TRANSFORM_STRIDE.
var slot_transforms: PackedFloat32Array = PackedFloat32Array()

## Per-slot custom data (4 floats per slot). Maps to INSTANCE_CUSTOM in the
## shader — (spawn_time, fade_duration, reserved, reserved) per §6 of the
## design doc.
## Total size = slot_capacity * CUSTOM_DATA_STRIDE.
var slot_custom_data: PackedFloat32Array = PackedFloat32Array()

## Reusable packed buffer consumed by multimesh_set_buffer. Sized
## slot_capacity * PACKED_STRIDE. Grown on capacity grow, never shrunk.
var _cull_buffer: PackedFloat32Array = PackedFloat32Array()

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

	## Nothing renders until cull_and_upload runs.
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


## Release a previously-acquired slot back to the freelist. Leaves its
## slot_transforms / slot_custom_data entries in place — cull skips them via
## slot_live anyway; overwriting would waste cycles for the common case.
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


## Write a world transform into a slot's storage. NOT pushed to the GPU
## until the next cull_and_upload.
func set_slot_transform(slot: int, xform: Transform3D) -> void:
	if slot < 0 or slot >= slot_capacity:
		push_error("PrototypeBatch.set_slot_transform: out-of-range slot %d (cap=%d)" % [slot, slot_capacity])
		return
	var off := slot * TRANSFORM_STRIDE
	var b := xform.basis
	var o := xform.origin
	## Row-major 3x4 — matches native_impostor_renderer.gd:1794-1808
	## (the known-good multimesh_set_buffer layout for TRANSFORM_3D).
	slot_transforms[off +  0] = b.x.x
	slot_transforms[off +  1] = b.y.x
	slot_transforms[off +  2] = b.z.x
	slot_transforms[off +  3] = o.x
	slot_transforms[off +  4] = b.x.y
	slot_transforms[off +  5] = b.y.y
	slot_transforms[off +  6] = b.z.y
	slot_transforms[off +  7] = o.y
	slot_transforms[off +  8] = b.x.z
	slot_transforms[off +  9] = b.y.z
	slot_transforms[off + 10] = b.z.z
	slot_transforms[off + 11] = o.z


## Write a 4-float custom data payload into a slot. Layout documented in
## PHASE_3_MID_MULTIMESH_DESIGN.md §6 (R=spawn_time, G=fade_duration,
## B=reserved, A=reserved).
func set_slot_custom_data(slot: int, data: Color) -> void:
	if slot < 0 or slot >= slot_capacity:
		push_error("PrototypeBatch.set_slot_custom_data: out-of-range slot %d (cap=%d)" % [slot, slot_capacity])
		return
	var off := slot * CUSTOM_DATA_STRIDE
	slot_custom_data[off + 0] = data.r
	slot_custom_data[off + 1] = data.g
	slot_custom_data[off + 2] = data.b
	slot_custom_data[off + 3] = data.a

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

	## PackedFloat32Array.resize zero-fills the new tail — exactly what we
	## want for newly-allocated slots (they should be degenerate transforms
	## until a real acquire + set_slot_transform).
	slot_transforms.resize(new_capacity * TRANSFORM_STRIDE)
	slot_custom_data.resize(new_capacity * CUSTOM_DATA_STRIDE)
	_cull_buffer.resize(new_capacity * PACKED_STRIDE)

	## Push newly-available slots onto the freelist in descending order so
	## acquire_slot (pop_back) hands back ascending indices — better spatial
	## coherency in the packed buffer.
	for i in range(new_capacity - 1, old_capacity - 1, -1):
		slot_freelist.append(i)

	if multimesh != null:
		multimesh.instance_count = new_capacity
	slot_capacity = new_capacity

#endregion


#region Cull pass (step 4 — GDScript naive; step 5 ports to C#)

## Distance-cull live slots against the camera, pack survivors into the
## MultiMesh buffer, upload, set visible_instance_count.
##
## O(slot_capacity) GDScript per batch. Step 5 replaces this body with a
## C# kernel via NativeBridge.
##
## Frustum culling is NOT applied per-slot: (a) the RS instance's
## engine-computed AABB already frustum-culls the whole batch when the
## camera faces away from all slots' world coverage; (b) per-slot frustum
## in GDScript doesn't pay off vs. the engine's vectorized AABB check.
## The C# port can add it if profiling says it's worth it.
##
## Returns the number of visible slots post-cull.
func cull_and_upload(cam_pos: Vector3, max_dist_sq: float) -> int:
	if not multimesh_rid.is_valid():
		return 0

	var rs := RenderingServer
	if slot_count_live == 0:
		rs.multimesh_set_visible_instances(multimesh_rid, 0)
		return 0

	var visible: int = 0
	var out_off: int = 0
	for slot in range(slot_capacity):
		if slot_live[slot] == 0:
			continue
		var trs_off := slot * TRANSFORM_STRIDE
		var ox: float = slot_transforms[trs_off +  3]
		var oy: float = slot_transforms[trs_off +  7]
		var oz: float = slot_transforms[trs_off + 11]
		var dx: float = ox - cam_pos.x
		var dy: float = oy - cam_pos.y
		var dz: float = oz - cam_pos.z
		var dist_sq: float = dx * dx + dy * dy + dz * dz
		if dist_sq > max_dist_sq:
			continue

		## Copy 12-float transform row then 4-float custom_data row into the
		## output buffer at position `out_off`.
		for k in range(TRANSFORM_STRIDE):
			_cull_buffer[out_off + k] = slot_transforms[trs_off + k]
		var cd_off := slot * CUSTOM_DATA_STRIDE
		for k in range(CUSTOM_DATA_STRIDE):
			_cull_buffer[out_off + TRANSFORM_STRIDE + k] = slot_custom_data[cd_off + k]

		out_off += PACKED_STRIDE
		visible += 1

	## Zero-fill the remainder so the previous cull's stale data doesn't
	## leak through. PackedFloat32Array has no memset — loop is required.
	for i in range(out_off, _cull_buffer.size()):
		_cull_buffer[i] = 0.0

	rs.multimesh_set_buffer(multimesh_rid, _cull_buffer)
	rs.multimesh_set_visible_instances(multimesh_rid, visible)
	return visible

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
	slot_transforms = PackedFloat32Array()
	slot_custom_data = PackedFloat32Array()
	_cull_buffer = PackedFloat32Array()
	slot_capacity = 0
	slot_count_live = 0

#endregion
