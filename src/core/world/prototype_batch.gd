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
##     MultiMesh.set_buffer during cull_and_upload — never via
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

## Phase 3 fade shader — same spawn-time/fade-duration formula as Phase 2's
## lod_crossfade.gdshader, rewritten to read per-slot timing from
## INSTANCE_CUSTOM (see lod_crossfade_multimesh.gdshader comment header).
## Loaded once and shared as the `shader` of every per-batch fade ShaderMaterial.
const FADE_SHADER := preload("res://src/core/world/shaders/lod_crossfade_multimesh.gdshader")

## Shared distance constants (SCREEN_SIZE_* for per-prototype visibility_range,
## FADE_MARGIN_RENDER_FAR for the fade-out band). See distance_utils.gd.
const DU := preload("res://src/core/world/distance_utils.gd")


#region Fields

## Strong ref to the prototype's mesh. Keeps the RID valid through the
## batch's lifetime even if the ModelLoader LRU-evicts the prototype.
var mesh_resource: Mesh

## Strong ref to the whole-mesh material override (may be null — some MW
## STATs use mesh-baked per-surface materials).
var material_resource: Material

var mesh_rid: RID                    ## Cached = mesh_resource.get_rid()
var material_rid: RID                ## Cached = material_resource.get_rid() or invalid

## Per-batch fade ShaderMaterial. Built lazily in _init when the prototype
## material is a StandardMaterial3D: we create a ShaderMaterial wrapping
## FADE_SHADER, copy the albedo/roughness/metallic/alpha_cutout uniforms
## from the StandardMaterial3D, and use it as the RS instance's
## material_override. Per-slot fade timing is driven by INSTANCE_CUSTOM,
## so the single shared ShaderMaterial handles the whole batch.
## Null when the prototype uses per-surface baked materials or a custom
## shader — those batches render without the fade (mesh surface materials
## render normally).
var fade_material: ShaderMaterial

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

## Per-batch shadow distance cutoff (squared). Computed in _init from
## prototype AABB: nearer → smaller cutoff. The cull pass sets cast_shadow
## OFF when the nearest live slot is past this distance. 0 = never toggle
## (uninitialized fallback; _init always overwrites).
var shadow_cutoff_dist_sq: float = 0.0

## Hysteresis upper band — squared (cutoff + hysteresis). Used only when
## shadow is currently ON; shadow flips off only when nearest slot is past
## THIS distance, preventing per-frame thrash at the cutoff boundary.
var _shadow_cutoff_hyst_sq: float = 0.0

## Current cast_shadow state of the batch RS instance. Cached so the
## per-frame RS call only fires on transitions. Starts true — batches
## spawn with shadows on until the first cull pass evaluates distance.
var _shadow_on: bool = true

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

	## Per-batch shadow cutoff. Godot's `visibility_range` uses distance to
	## AABB CENTER, which breaks for world-spanning MultiMesh batches whose
	## centers are far from nearby slots. Instead we do a DYNAMIC per-cull
	## toggle: compute the nearest-slot distance in cull_and_upload (for
	## free — the visible cull already walks every slot computing dist_sq),
	## and flip cast_shadow on/off based on whether any slot is closer than
	## `shadow_cutoff_dist_sq`. This is the canonical per-batch "screen-size
	## shadow cull" pattern — preserves close-up shadows while dropping
	## shadow-pass cost for batches whose cluster has moved out of range.
	##
	## Cutoff scales with prototype AABB size, clamped [MIN_CUTOFF, 200m].
	## 200m is the current directional_shadow_max_distance (sky_manager.gd);
	## cutoff beyond that has no shadow-cost effect.
	var proto_aabb := p_mesh.get_aabb()
	var max_dim: float = maxf(proto_aabb.size.x, maxf(proto_aabb.size.y, proto_aabb.size.z))
	var shadow_cutoff: float = clampf(
		max_dim * DU.SCREEN_SIZE_CUTOFF_RATIO,
		DU.SCREEN_SIZE_MIN_CUTOFF,
		DU.SHADOW_CUTOFF_MAX
	)
	shadow_cutoff_dist_sq = shadow_cutoff * shadow_cutoff
	## Hysteresis band: squared (cutoff + HYST) vs squared cutoff to avoid
	## per-frame toggle thrash at the cutoff boundary.
	var hyst_edge: float = shadow_cutoff + DU.SHADOW_CUTOFF_HYSTERESIS
	_shadow_cutoff_hyst_sq = hyst_edge * hyst_edge

	## Prefer a fade ShaderMaterial wrapping FADE_SHADER when the prototype's
	## material is a StandardMaterial3D — this gives per-slot spawn-time
	## crossfade via INSTANCE_CUSTOM. For per-surface baked materials
	## (material_resource == null) or custom shaders, keep whatever the
	## original material was so we don't replace authored shading.
	if material_resource is StandardMaterial3D:
		fade_material = _build_fade_material(material_resource as StandardMaterial3D)
		rs.instance_geometry_set_material_override(rs_instance, fade_material.get_rid())
	elif material_rid.is_valid():
		rs.instance_geometry_set_material_override(rs_instance, material_rid)

	## Nothing renders until cull_and_upload runs.
	multimesh.visible_instance_count = 0

	_resize_capacity_internal(p_initial_capacity)


#region Fade material

## Build a ShaderMaterial wrapping FADE_SHADER, with texture/color/PBR
## uniforms copied from the source StandardMaterial3D. Mirrors
## reference_instantiator.gd's Phase 2 pattern (pool + per-instance
## ShaderMaterial), except Phase 3 has ONE per batch, driven per-slot by
## INSTANCE_CUSTOM instead of per-frame by Tween.
func _build_fade_material(std_mat: StandardMaterial3D) -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	sm.shader = FADE_SHADER
	if std_mat.albedo_texture:
		sm.set_shader_parameter("albedo_texture", std_mat.albedo_texture)
	sm.set_shader_parameter("albedo_color", std_mat.albedo_color)
	sm.set_shader_parameter("roughness", std_mat.roughness)
	sm.set_shader_parameter("metallic", std_mat.metallic)
	sm.set_shader_parameter("specular", std_mat.metallic_specular)
	## Vegetation / fence cutout — preserve alpha scissor behaviour.
	if std_mat.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
		sm.set_shader_parameter("use_alpha_cutout", true)
		sm.set_shader_parameter("alpha_cutout", std_mat.alpha_scissor_threshold)
	return sm

#endregion


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
##
## `native_culler` is an optional WorldMidCuller C# instance (from
## NativeBridge.create_world_mid_culler). When non-null the hot cull loop
## runs in C# — 20-50× faster than GDScript on ~30k slots per the
## NativeBridge benchmark note. When null, falls back to the GDScript loop
## below.
func cull_and_upload(cam_pos: Vector3, max_dist_sq: float, native_culler: RefCounted = null) -> int:
	if multimesh == null or not multimesh_rid.is_valid():
		return 0

	if slot_count_live == 0:
		if multimesh != null:
			multimesh.visible_instance_count = 0
		return 0

	if native_culler != null:
		return _cull_native(cam_pos, max_dist_sq, native_culler)

	var visible: int = 0
	var out_off: int = 0
	## Track nearest-slot distance for the per-batch shadow toggle. Computed
	## over ALL live slots (not just visible ones) — shadow decision needs
	## to survive slots that are past max_dist_sq but still close enough to
	## matter for shadow-caster distance. INF = no live slots seen.
	var nearest_dist_sq: float = INF
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
		if dist_sq < nearest_dist_sq:
			nearest_dist_sq = dist_sq
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

	_ensure_multimesh_capacity()
	multimesh.set_buffer(_cull_buffer)
	multimesh.visible_instance_count = visible
	_update_shadow_state(nearest_dist_sq)
	return visible


## Native C# cull path. Keeps the whole hot loop in managed code; GDScript
## just reads the returned {visible, buffer} dict and uploads.
##
## On marshalling — per @roaster review:
##   - slot_live / slot_transforms / slot_custom_data cross as byte[] /
##     float[] (Godot auto-marshals PackedByteArray / PackedFloat32Array).
##     The marshal is O(1) when the backing storage is shared; worst case
##     is a single copy per array per frame. Cheaper than the GDScript
##     hot loop regardless.
##   - Camera position passes as Vector3 (Variant).
##   - Return is a Godot.Collections.Dictionary: { "visible": int,
##     "buffer": PackedFloat32Array }. GDScript reads both fields, pushes
##     buffer to multimesh_set_buffer, sets visible_instance_count.
@warning_ignore("unsafe_method_access")
func _cull_native(cam_pos: Vector3, max_dist_sq: float, native_culler: RefCounted) -> int:
	var result: Dictionary = native_culler.call(
		"CullAndPack",
		slot_live,
		slot_transforms,
		slot_custom_data,
		cam_pos,
		max_dist_sq,
		slot_capacity,
	)
	var visible: int = result.get("visible", 0)
	var buffer_variant: Variant = result.get("buffer")
	if not (buffer_variant is PackedFloat32Array):
		push_warning("PrototypeBatch._cull_native: CullAndPack returned no buffer, falling back to GDScript")
		return cull_and_upload(cam_pos, max_dist_sq, null)
	var buffer: PackedFloat32Array = buffer_variant
	## Nearest-slot distance for the shadow toggle. C# initializes to
	## float.PositiveInfinity when no live slots; GDScript's Variant
	## unmarshals that cleanly to INF.
	var nearest_dist_sq: float = result.get("nearest_dist_sq", INF)

	if multimesh == null:
		return 0
	_ensure_multimesh_capacity()
	multimesh.set_buffer(buffer)
	multimesh.visible_instance_count = visible
	_update_shadow_state(nearest_dist_sq)
	return visible


func _ensure_multimesh_capacity() -> void:
	if multimesh == null:
		return
	if multimesh.instance_count != slot_capacity:
		multimesh.instance_count = slot_capacity

## Flip cast_shadow on the batch RS instance based on the nearest live
## slot's distance from the camera. Called from both cull paths (GDScript
## fallback + C# native) with the nearest_dist_sq computed during the cull
## walk. Hysteresis prevents toggle thrash at the cutoff boundary — once
## OFF, shadow stays off until nearest drops below cutoff; once ON, stays
## on until nearest passes cutoff + HYSTERESIS.
##
## No-op when shadow_cutoff_dist_sq is 0 (uninitialized — shouldn't happen
## post-_init but defensive) or when the state matches (avoid redundant
## RS calls — each one triggers engine-side shadow cache invalidation).
func _update_shadow_state(nearest_dist_sq: float) -> void:
	if shadow_cutoff_dist_sq <= 0.0:
		return
	if not rs_instance.is_valid():
		return
	var want_on: bool
	if _shadow_on:
		## Currently on — stay on until past (cutoff + hysteresis).
		want_on = nearest_dist_sq < _shadow_cutoff_hyst_sq
	else:
		## Currently off — turn back on when inside the cutoff.
		want_on = nearest_dist_sq < shadow_cutoff_dist_sq
	if want_on == _shadow_on:
		return
	_shadow_on = want_on
	var setting := RenderingServer.SHADOW_CASTING_SETTING_ON if want_on \
		else RenderingServer.SHADOW_CASTING_SETTING_OFF
	RenderingServer.instance_geometry_set_cast_shadows_setting(rs_instance, setting)

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
	fade_material = null
	slot_live = PackedByteArray()
	slot_freelist = PackedInt32Array()
	slot_transforms = PackedFloat32Array()
	slot_custom_data = PackedFloat32Array()
	_cull_buffer = PackedFloat32Array()
	slot_capacity = 0
	slot_count_live = 0
	shadow_cutoff_dist_sq = 0.0
	_shadow_cutoff_hyst_sq = 0.0
	_shadow_on = true

#endregion
