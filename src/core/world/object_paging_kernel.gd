## ObjectPagingKernel — merge orchestration layer, C# hot kernel delegate.
##
## Phase 1 of the paging refactor (docs/audit/OBJECT_PAGING_PLAN.md §11).
## The CPU-bound inner math (vertex transform, material grouping,
## PackedArray concat) lives in src/native/NativeObjectPagingKernel.cs.
## This GDScript layer owns:
##   - RefInput / SubMeshInput data shapes used by callers
##   - Pre-flattening of ref × sub_mesh × surface into (arrays, xform, mat) triplets
##   - ImporterMesh LOD-chain generation on the merged ArrayMesh (Godot API, stays GDScript)
##   - Memory-estimate passthrough
##
## Why the split (per .claude/CLAUDE.md Language & Typing Policy):
##   - C#  = heavy compute loops over PackedVector3Array (~10x-50x faster)
##   - GDScript = Godot API orchestration + resource wrangling (Variant
##                marshalling overhead would erase the C# win otherwise)
##
## Thread safety: every method is static + pure. Callers hand over immutable
## ArrayMesh / Material references; the kernel returns a fresh ArrayMesh.
## Safe for WorkerThreadPool tasks.

# Dynamic C# interop — native kernel is resolved via NativeBridge at runtime,
# so GDScript parsing does not require the C# assembly to be loaded.
@warning_ignore("untyped_declaration")
@warning_ignore("unsafe_method_access")
@warning_ignore("unsafe_property_access")
@warning_ignore("unsafe_cast")

class_name ObjectPagingKernel
extends RefCounted

const NativeBridgeScript := preload("res://src/core/native_bridge.gd")
const DU := preload("res://src/core/world/distance_utils.gd")


## LOD generation parameters for merged chunks. Aggressive because merged
## chunks only render at 300m+ (HLOD) / 150m+ (paging tiers).
const LOD_NORMAL_MERGE_ANGLE: float = 60.0
const LOD_SCREEN_COVERAGE: float = 25.0


#region Input Structs

## Pre-collected merge input for one object reference.
## Populated on main thread from StaticObjectRenderer / ESM data; handed to
## worker thread for merging. Contains only thread-safe fields.
##
## Phase 5 — `rs2` and `dist_sq` feed the second-pass `minSizeMergeFactor`
## filter inside `_flatten_to_triplets`. Callers that don't need Phase 5
## filtering leave them at 0.0; the filter is a no-op when either is zero.
class RefInput:
	var ref_transform: Transform3D
	var sub_meshes: Array  ## Array[SubMeshInput]
	var bucket_key: String = ""  ## Source CellStaticBucket key for whole-bucket HLOD ownership.
	var source_ref_num: int = -1  ## ESM ref_num for FAR coverage ownership.
	var rs2: float = 0.0         ## mesh_radius² × scale² (Phase 2 size metric)
	var dist_sq: float = 0.0     ## pos.distance_squared_to(camera) at merge-request time


## One child sub-mesh of a RefInput.
class SubMeshInput:
	var mesh: ArrayMesh
	var local_transform: Transform3D
	var material_override: Material  ## Whole-mesh override (may be null)
	var surface_materials: Array[Material]  ## Per-surface materials

#endregion


#region Native Kernel Lazy Singleton

## Shared native C# kernel. Created once and reused across merges — the kernel
## is stateless so one instance is safe for concurrent worker-thread use.
## RefCounted, so GDScript auto-frees on shutdown.
## Typed as RefCounted (not NativeObjectPagingKernel) so GDScript parses without
## the C# assembly loaded, matching the codebase NativeBridge pattern.
static var _native: RefCounted = null
static var _native_mutex: Mutex = Mutex.new()
static var _native_checked: bool = false


static func _get_native() -> RefCounted:
	_native_mutex.lock()
	if _native == null and not _native_checked:
		_native_checked = true
		var bridge := NativeBridgeScript.new()
		var factory: RefCounted = bridge.get("_factory")
		if factory != null:
			_native = factory.call("CreateObjectPagingKernel") as RefCounted
		if _native == null:
			push_error("ObjectPagingKernel: native C# kernel unavailable — rebuild C# (dotnet build Godotwind.sln)")
	var out: RefCounted = _native
	_native_mutex.unlock()
	return out

#endregion


#region Public API — called from worker threads

## Merge all RefInputs for a chunk into a single ArrayMesh with LOD chain.
## Vertices expressed in chunk-local space (caller passes chunk_origin; we
## subtract it per-ref here so C# sees world-minus-origin transforms directly).
## Returns null if inputs produce no geometry.
##
## `size_level` (Phase 3b, default 0) scales the merge cost in the cost-benefit
## analyze. `size_level=0` = 1×1 cell chunks (near-MID), `size_level=1` = 2×2
## (MID-far), `size_level=2` = 4×4 (HLOD). Larger chunks pay more per-vertex
## cost so only truly shared mesh types survive cost-benefit.
##
## `force_merge_all` (Phase 3b, default false) bypasses the cost-benefit analyze
## and merges every input mesh-type. Primarily for Phase 1 kernel parity tests
## with synthetic single-type / single-material fixtures — real callers leave
## this at the default and trust the analyze to decide.
static func merge_refs(inputs: Array, chunk_origin: Vector3, size_level: int = 0, force_merge_all: bool = false) -> ArrayMesh:
	# Phase 3b — cost-benefit analyze on worker thread, before materialization.
	# Decides per-mesh-type whether merging pays back the vertex-duplication tax.
	var keep_mask: Dictionary = {}
	if not force_merge_all:
		keep_mask = _analyze_chunk(inputs, size_level)

	# Count types accepted vs. rejected by cost-benefit for diagnostics.
	var accepted_types: int = 0
	var rejected_types: int = 0
	for mesh_id: int in keep_mask:
		var entry: Variant = keep_mask[mesh_id]
		if (entry is bool and entry) or (entry is Dictionary and entry.get("merge", false)):
			accepted_types += 1
		else:
			rejected_types += 1

	var triplets: Array = _flatten_to_triplets(inputs, chunk_origin, keep_mask)
	if triplets.is_empty():
		Log.info("streaming", "HLOD merge_refs: 0 triplets (cost_reject=%d types, cost_accept=%d, force=%s)" % [
			rejected_types, accepted_types, force_merge_all])
		return null

	var native: RefCounted = _get_native()
	if native == null:
		Log.warn("streaming", "HLOD merge_refs: C# native unavailable")
		return null
	var merged: ArrayMesh = native.call("MergeSurfaceTriplets", triplets) as ArrayMesh
	if merged == null or merged.get_surface_count() == 0:
		Log.info("streaming", "HLOD merge_refs: C# returned null/0-surface mesh (%d triplets)" % triplets.size())
		return null

	# LOD generation MUST run on the main thread — ImporterMesh.new() +
	# generate_lods() + get_mesh() all touch the RenderingServer, which is
	# not safe from WorkerThreadPool background threads. Caller (process_completions)
	# runs generate_lods() on the main thread after receiving this raw mesh.
	return merged


## Estimate merged ArrayMesh memory usage in bytes.
static func estimate_mesh_bytes(mesh: ArrayMesh) -> int:
	if mesh == null:
		return 0
	var native: RefCounted = _get_native()
	if native == null:
		return 0
	return int(native.call("EstimateMeshBytes", mesh))


## Generate LOD chain on a merged ArrayMesh via ImporterMesh.
## Returns a new ArrayMesh with embedded surface_lod_indices, or null.
## Caller treats null as "mesh unchanged, no LOD chain".
static func generate_lods(mesh: ArrayMesh) -> ArrayMesh:
	if mesh.get_surface_count() == 0:
		return null

	var importer := ImporterMesh.new()
	for si in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(si)
		if arrays.is_empty():
			continue
		var verts: Variant = arrays[Mesh.ARRAY_VERTEX]
		if verts == null or (verts is PackedVector3Array and verts.is_empty()):
			continue
		# Ensure index buffer for LOD generation
		var indices: Variant = arrays[Mesh.ARRAY_INDEX]
		if indices == null or (indices is PackedInt32Array and indices.is_empty()):
			var vert_count: int = verts.size()
			var identity_indices := PackedInt32Array()
			identity_indices.resize(vert_count)
			for vi in range(vert_count):
				identity_indices[vi] = vi
			arrays[Mesh.ARRAY_INDEX] = identity_indices

		var mat: Material = mesh.surface_get_material(si)
		importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, mat, "", 0)

	importer.generate_lods(LOD_NORMAL_MERGE_ANGLE, LOD_SCREEN_COVERAGE, [])
	var result: ArrayMesh = importer.get_mesh()
	if result and result.get_surface_count() > 0:
		result.set_meta("has_lod_chain", true)
		return result
	return null

#endregion


#region Internal — triplet flattening

## Resolve the effective material for a sub-mesh surface.
## Precedence: whole-mesh override → per-surface material → mesh default.
## Used by both `_flatten_to_triplets` and `_analyze_chunk` — central to keep
## material identity consistent across the cost-benefit decision and the
## actual merge output.
static func _resolve_material(sm: SubMeshInput, surface_index: int) -> Material:
	if sm.material_override != null:
		return sm.material_override
	if surface_index < sm.surface_materials.size() and sm.surface_materials[surface_index] != null:
		return sm.surface_materials[surface_index]
	return sm.mesh.surface_get_material(surface_index)


## Flatten `Array[RefInput]` → `Array[[ArrayMesh-surface-arrays, fullXform, Material]]`.
## Precomputes `full_xform = ref_transform * sub.local_transform` minus chunk_origin
## and resolves the material-override/per-surface chain here so the C# side
## doesn't need to unpack the RefInput/SubMeshInput Variant structure.
##
## `keep_mask` (Phase 3b/5, optional): when non-empty, only sub_meshes whose
## `mesh.get_instance_id()` appears in the mask are flattened. Two accepted
## shapes for backward compatibility:
##   • `Dictionary[mesh_id -> bool]` — legacy boolean form from pre-Phase 5.
##   • `Dictionary[mesh_id -> Dictionary{merge: bool, min_size_merged_sq: float}]` —
##     Phase 5 rich form. When `min_size_merged_sq > 0` AND the ref's `rs2`
##     and `dist_sq` are both set, `rs2 < dist_sq × min_size_merged_sq`
##     rejects the ref (second-pass size filter, OpenMW §2.5).
## Empty mask = keep everything (no cost-benefit pass).
static func _flatten_to_triplets(inputs: Array, chunk_origin: Vector3, keep_mask: Dictionary = {}) -> Array:
	var triplets: Array = []
	var filter_enabled: bool = not keep_mask.is_empty()
	for ref_input: RefInput in inputs:
		for sm: SubMeshInput in ref_input.sub_meshes:
			if sm.mesh == null:
				continue
			var mesh_id: int = sm.mesh.get_instance_id()
			if filter_enabled:
				var entry: Variant = keep_mask.get(mesh_id)
				if entry == null:
					continue
				var merge_ok: bool = false
				var min_size_merged_sq: float = 0.0
				if entry is bool:
					merge_ok = entry
				elif entry is Dictionary:
					merge_ok = entry.get("merge", false)
					min_size_merged_sq = entry.get("min_size_merged_sq", 0.0)
				if not merge_ok:
					continue
				# Phase 5 second-pass per-ref size filter — skip refs whose
				# projected size is below the merge-benefit-scaled threshold.
				if min_size_merged_sq > 0.0 and ref_input.rs2 > 0.0 and ref_input.dist_sq > 0.0:
					if ref_input.rs2 < ref_input.dist_sq * min_size_merged_sq:
						continue
			var sub_count: int = sm.mesh.get_surface_count()
			if sub_count == 0:
				continue

			var full_xform := ref_input.ref_transform * sm.local_transform
			full_xform.origin -= chunk_origin

			for si in range(sub_count):
				var arrays: Array = sm.mesh.surface_get_arrays(si)
				if arrays.is_empty():
					continue
				var verts: Variant = arrays[Mesh.ARRAY_VERTEX]
				if verts == null or (verts is PackedVector3Array and verts.is_empty()):
					continue

				var mat: Material = _resolve_material(sm, si)
				triplets.append([arrays, full_xform, mat])
	return triplets


## Phase 3b — cost-benefit analyze (OpenMW ObjectPaging §2.3).
##
## Matches `inspos/openmw/apps/openmw/mwrender/objectpaging.cpp:823-836`:
##     mergeCost    = numVerts × size            (larger chunks pay more)
##     mergeBenefit = avgStateSetReuse × mergeFactor
##     merge        = mergeBenefit > mergeCost
##
## Godotwind port per plan §2.3:
##     mergeBenefit_type = ref_count_in_chunk × shared_material_count
## where `shared_material_count` is the number of distinct materials on this
## mesh-type that are also used by ≥2 distinct mesh-types in the chunk (the
## Godotwind proxy for OpenMW's StateSet reuse average). A mesh-type whose
## materials appear nowhere else has shared_material_count = 0 →
## mergeBenefit = 0 → merge=false → stays as individual RS instances.
##
## Returns `Dictionary[mesh_instance_id: int -> Dictionary{merge: bool,
## min_size_merged_sq: float}]` — the keep-mask consumed by
## `_flatten_to_triplets`. `min_size_merged_sq` is the squared threshold for
## the Phase 5 second-pass filter (OpenMW §2.5 `minSizeMergeFactor`) computed
## from the per-type mergeBenefit / mergeCost ratio. It is `0.0` when merge
## is rejected (filter is a no-op for unmerged types).
##
## Thread-safe: reads input ArrayMesh / Material instance IDs (immutable),
## creates local dicts. Safe for worker-thread execution.
static func _analyze_chunk(inputs: Array, size_level: int) -> Dictionary:
	# Per-mesh-type aggregation
	var groups: Dictionary = {}  # mesh_id -> {"ref_count": int, "verts": int, "mats": Dictionary[mat_id: true]}

	for ref_input: RefInput in inputs:
		for sm: SubMeshInput in ref_input.sub_meshes:
			if sm.mesh == null:
				continue
			var sub_count: int = sm.mesh.get_surface_count()
			if sub_count == 0:
				continue

			var mesh_id: int = sm.mesh.get_instance_id()
			if mesh_id not in groups:
				groups[mesh_id] = {"ref_count": 0, "verts_per_instance": 0, "mats": {}}
			var group: Dictionary = groups[mesh_id]
			group["ref_count"] += 1

			for si in range(sub_count):
				var arrays: Array = sm.mesh.surface_get_arrays(si)
				if arrays.is_empty():
					continue
				var verts: Variant = arrays[Mesh.ARRAY_VERTEX]
				# verts_per_instance: vertex count for ONE prototype copy.
				# Only count on first encounter (all refs share the same ArrayMesh
				# instance, so verts are identical across refs — no need to re-read).
				if group["ref_count"] == 1 and verts is PackedVector3Array and not verts.is_empty():
					group["verts_per_instance"] += verts.size()

				var mat: Material = _resolve_material(sm, si)
				var mat_id: int = mat.get_instance_id() if mat else 0
				group["mats"][mat_id] = true

	# Compute merge decision + Phase 5 per-type min-size threshold.
	#
	# OpenMW formula: mergeBenefit = MERGE_FACTOR × avgStateSetReuse × numRefs
	# `avgStateSetReuse` in OpenMW is INTRA-NIF: nodes within one NIF sharing
	# the same material state. Godotwind's original implementation mis-ported
	# this as CROSS-NIF material sharing (different mesh types sharing a Material
	# instance), which is essentially zero for Morrowind content (each model has
	# unique materials) → cost_accept=0 for all chunks.
	#
	# Fix: use surface_count as a proxy for intra-NIF state reuse. A model with
	# N surfaces that all share materials has high intra-NIF reuse. We clamp to
	# max(1, distinct_mat_count) to avoid zero-benefit when a model has 1 surface.
	# This matches OpenMW's intent: multi-surface models with shared state are
	# worth merging; single-surface unique models are also merged if ref_count
	# is high enough to overcome the vertex cost.
	var result: Dictionary = {}
	var cost_multiplier: float = float(size_level + 1)
	for mesh_id: int in groups:
		var group: Dictionary = groups[mesh_id]
		# OpenMW cost-benefit (objectpaging.cpp §823-836):
		#   mergeCost    = verts_per_instance × (size_level + 1)
		#   mergeBenefit = ref_count × avgStateSetReuse × MERGE_FACTOR
		# `avgStateSetReuse` proxy: distinct material count within this mesh type
		# (clamped to 1). A model with 1 surface has reuse=1; one with many
		# surfaces sharing fewer materials has higher reuse. This matches OpenMW's
		# intra-NIF sharing metric more closely than the old cross-NIF approach.
		var mat_count: int = maxi(1, group["mats"].size())
		var verts_per_instance: int = group["verts_per_instance"]
		var merge_benefit_raw: float = float(group["ref_count"]) * float(mat_count)
		var merge_cost: float = float(verts_per_instance) * cost_multiplier
		var merge_benefit: float = merge_benefit_raw * DU.PAGING_MERGE_FACTOR
		var merge: bool = merge_benefit > merge_cost

		var min_size_merged_sq: float = 0.0
		if merge:
			min_size_merged_sq = _compute_min_size_merged_sq(merge_benefit, merge_cost)

		result[mesh_id] = {"merge": merge, "min_size_merged_sq": min_size_merged_sq}
	return result


## Phase 5 — OpenMW `minSizeMerged` formula (objectpaging.cpp:833-836).
## Returns the SQUARED threshold for direct comparison with `rs2 / dist_sq`.
## Benefit==0 collapses to `MIN_SIZE²` (base filter) — merge is rejected in
## that case anyway, so this branch only trips for caller parity tests.
static func _compute_min_size_merged_sq(merge_benefit: float, merge_cost: float) -> float:
	var factor2: float = 1.0
	if merge_benefit > 0.0:
		factor2 = minf(1.0, merge_cost * DU.PAGING_MIN_SIZE_COST_MULTIPLIER / merge_benefit)
	var min_size_merge_factor_2: float = (1.0 - factor2) * DU.PAGING_MIN_SIZE_MERGE_FACTOR + factor2
	var min_size_merged: float = DU.PAGING_MIN_SIZE * min_size_merge_factor_2
	return min_size_merged * min_size_merged

#endregion
