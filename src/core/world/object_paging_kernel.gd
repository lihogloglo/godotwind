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


## LOD generation parameters for merged chunks. Aggressive because merged
## chunks only render at 300m+ (HLOD) / 150m+ (paging tiers).
const LOD_NORMAL_MERGE_ANGLE: float = 60.0
const LOD_SCREEN_COVERAGE: float = 25.0


#region Input Structs

## Pre-collected merge input for one object reference.
## Populated on main thread from StaticObjectRenderer / ESM data; handed to
## worker thread for merging. Contains only thread-safe fields.
class RefInput:
	var ref_transform: Transform3D
	var sub_meshes: Array  ## Array[SubMeshInput]


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
static func merge_refs(inputs: Array, chunk_origin: Vector3) -> ArrayMesh:
	var triplets: Array = _flatten_to_triplets(inputs, chunk_origin)
	if triplets.is_empty():
		return null

	var native: RefCounted = _get_native()
	if native == null:
		return null
	var merged: ArrayMesh = native.call("MergeSurfaceTriplets", triplets) as ArrayMesh
	if merged == null or merged.get_surface_count() == 0:
		return null

	# LOD chain generation lives here (Godot API heavy — C# gains nothing).
	var lod_mesh := generate_lods(merged)
	if lod_mesh:
		merged = lod_mesh

	merged.set_meta("has_lod_chain", true)
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

## Flatten `Array[RefInput]` → `Array[[ArrayMesh-surface-arrays, fullXform, Material]]`.
## Precomputes `full_xform = ref_transform * sub.local_transform` minus chunk_origin
## and resolves the material-override/per-surface chain here so the C# side
## doesn't need to unpack the RefInput/SubMeshInput Variant structure.
static func _flatten_to_triplets(inputs: Array, chunk_origin: Vector3) -> Array:
	var triplets: Array = []
	for ref_input: RefInput in inputs:
		for sm: SubMeshInput in ref_input.sub_meshes:
			if sm.mesh == null:
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

				# Resolve material: whole-mesh override → per-surface → mesh default
				var mat: Material = sm.material_override
				if mat == null and si < sm.surface_materials.size():
					mat = sm.surface_materials[si]
				if mat == null:
					mat = sm.mesh.surface_get_material(si)

				triplets.append([arrays, full_xform, mat])
	return triplets

#endregion
