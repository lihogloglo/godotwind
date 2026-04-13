## RuntimeHLODMerger — Runtime cell-level HLOD merging (OpenMW-style)
##
## Replaces the prebake-only HLODLoader. Merges cell geometry on demand using
## WorkerThreadPool when cells enter HLOD range (300-1000m). No disk prebake needed.
##
## Pipeline:
##   1. Cell enters HLOD range → main thread collects mesh data from StaticObjectRenderer
##      (fast path) or loads prototype from model cache (slow path for deep HLOD cells)
##   2. Background worker: transforms vertices, groups by material, concatenates, generates LODs
##      (~100-200ms per cell in GDScript, viable on worker thread)
##   3. Main thread: creates RS instance from merged ArrayMesh, adds to LRU cache
##
## Thread safety:
##   - Main thread: CellRecord iteration, MeshType lookup/registration, RS instance creation
##   - Worker thread: ArrayMesh.surface_get_arrays() (read-only), vertex transforms,
##     ImporterMesh.generate_lods() (isolated instance). Pure CPU after data collection.
class_name RuntimeHLODMerger
extends RefCounted

const DU := preload("res://src/core/world/distance_utils.gd")
const CS := preload("res://src/core/coordinate_system.gd")
const StreamingPolicyScript := preload("res://src/core/world/streaming_policy.gd")
const StaticObjectRendererScript := preload("res://src/core/world/static_object_renderer.gd")

## LRU cache budget in bytes (default 256 MB)
const CACHE_BUDGET_BYTES: int = 256 * 1024 * 1024

## Max surfaces per merged mesh (Godot hard cap 256, leave headroom)
const MAX_SURFACES: int = 250

## LOD generation parameters (aggressive — mesh only visible at 300m+)
const LOD_NORMAL_MERGE_ANGLE: float = 60.0
const LOD_SCREEN_COVERAGE: float = 25.0

## Minimum mid-worthy refs to justify merging a cell (OpenMW cost-benefit insight).
## Sparse cells with fewer refs → individual MID RS instances are cheaper than a merge.
const MIN_REFS_TO_MERGE: int = 15


#region Internal Data Classes

class HLODCellData:
	var grid: Vector2i
	var instance_rid: RID
	var mesh: ArrayMesh  ## Strong ref — prevents GC
	var surface_count: int = 0
	var estimated_bytes: int = 0


## Pre-collected merge input for one object reference (passed to worker thread).
## Contains only thread-safe data: ArrayMesh resources (read-only), transforms, materials.
class MergeRefInput:
	var ref_transform: Transform3D
	var sub_meshes: Array  ## Array of MergeSubMeshInput


class MergeSubMeshInput:
	var mesh: ArrayMesh
	var local_transform: Transform3D
	var material_override: Material  ## Whole-mesh override (may be null)
	var surface_materials: Array[Material]  ## Per-surface materials

#endregion


#region State

## Master toggle — disabled by default until performance is validated.
## Enable via console: `hlod_enable` / disable: `hlod_disable`
var enabled: bool = false

## Scenario RID for creating RS instances
var _scenario: RID = RID()

## Reference to the static object renderer (for MeshType lookups)
var _static_renderer: StaticObjectRendererScript = null

## Reference to background processor (for submitting merge tasks)
var _bg_processor: BackgroundProcessor = null

## Model cache directory (for loading prototypes not yet in StaticObjectRenderer)
var _models_dir: String = ""

## Active HLOD cells with RS instances
var _active_cells: Dictionary = {}  # Vector2i -> HLODCellData

## Pending merge tasks (submitted to background processor)
var _pending_merges: Dictionary = {}  # Vector2i -> int (task_id)
var _task_to_grid: Dictionary = {}  # int (task_id) -> Vector2i (reverse map for O(1) completion lookup)

## Merge queue — cells waiting for main-thread data collection + worker submission.
## Staggered: max MERGES_PER_FRAME processed per frame to avoid main-thread stalls.
var _merge_queue: Array[Vector2i] = []
var _camera_cell_cached: Vector2i = Vector2i.ZERO
const MERGES_PER_FRAME: int = 2

## Completed merge results waiting for main-thread RS instance creation
var _completed_queue: Array = []  # Array of {grid: Vector2i, mesh: ArrayMesh, bytes: int}
var _completed_mutex: Mutex = Mutex.new()

## LRU mesh cache
var _mesh_cache: Dictionary = {}  # Vector2i -> ArrayMesh
var _mesh_sizes: Dictionary = {}  # Vector2i -> int (bytes)
var _lru_order: Array[Vector2i] = []  # Oldest first
var _cache_used_bytes: int = 0

## Stats
var _stats: Dictionary = {
	"active_cells": 0,
	"pending_merges": 0,
	"cache_entries": 0,
	"cache_bytes": 0,
	"total_merges_completed": 0,
	"total_refs_skipped": 0,
}

#endregion


#region Public API

## Initialize with viewport scenario, static renderer (for mesh data), and background processor.
func initialize(scenario: RID, static_renderer: StaticObjectRendererScript,
		bg_processor: BackgroundProcessor) -> void:
	_scenario = scenario
	_static_renderer = static_renderer
	_bg_processor = bg_processor
	_models_dir = SettingsManager.get_models_path()

	if _bg_processor:
		_bg_processor.task_completed.connect(_on_task_completed)
		_bg_processor.task_failed.connect(_on_task_failed)


## Update HLOD cells based on camera position.
## Call on cell change. Populates merge queue for cells entering HLOD range.
## Actual merge requests are staggered via process_merge_queue() (max N per frame).
## Returns number of cells changed.
func update_for_camera(camera_cell: Vector2i) -> int:
	if not enabled:
		return 0
	_camera_cell_cached = camera_cell
	var changed := 0
	var hlod_start_sq := DU.HLOD_START * DU.HLOD_START
	var hlod_end_sq := DU.HLOD_END * DU.HLOD_END
	var hlod_radius := DU.distance_to_cell_radius(DU.HLOD_END)

	# Determine which cells should have HLOD active
	var desired_cells: Dictionary = {}  # Vector2i -> true
	for dy in range(-hlod_radius, hlod_radius + 1):
		for dx in range(-hlod_radius, hlod_radius + 1):
			var grid := Vector2i(camera_cell.x + dx, camera_cell.y + dy)
			var dist_sq := DU.cell_distance_squared(grid, camera_cell)
			if dist_sq >= hlod_start_sq and dist_sq <= hlod_end_sq:
				desired_cells[grid] = true

	# Queue new cells (don't call _request_merge here — stagger via process_merge_queue)
	for grid: Vector2i in desired_cells:
		if grid not in _active_cells and grid not in _pending_merges:
			# Check LRU cache first (fast path — cell was merged before)
			if grid in _mesh_cache:
				if _create_rs_instance(grid, _mesh_cache[grid], _mesh_sizes.get(grid, 0)):
					_lru_touch(grid)
					changed += 1
			elif grid not in _merge_queue:
				_merge_queue.append(grid)

	# Sort merge queue by distance (closer cells first)
	if not _merge_queue.is_empty():
		_merge_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			return DU.cell_distance_squared(a, camera_cell) < DU.cell_distance_squared(b, camera_cell))

	# Unload cells that left range
	var to_unload: Array[Vector2i] = []
	for grid: Vector2i in _active_cells:
		if grid not in desired_cells:
			to_unload.append(grid)

	for grid: Vector2i in to_unload:
		_unload_cell(grid)
		changed += 1

	# Cancel pending merges that left range
	var to_cancel: Array[Vector2i] = []
	for grid: Vector2i in _pending_merges:
		if grid not in desired_cells:
			to_cancel.append(grid)

	for grid: Vector2i in to_cancel:
		if _bg_processor:
			_bg_processor.cancel_task(_pending_merges[grid])
		var tid: int = _pending_merges[grid]
		_task_to_grid.erase(tid)
		_pending_merges.erase(grid)

	# Remove queued cells that left range
	_merge_queue = _merge_queue.filter(func(g: Vector2i) -> bool: return g in desired_cells)

	_stats["active_cells"] = _active_cells.size()
	_stats["pending_merges"] = _pending_merges.size()
	return changed


## Process staggered merge queue — max MERGES_PER_FRAME cells per call.
## Each call does main-thread data collection + submits to worker.
## Call once per frame from streaming manager (BEFORE process_completions).
func process_merge_queue() -> void:
	if not enabled or _merge_queue.is_empty():
		return

	var budget := MERGES_PER_FRAME
	while budget > 0 and not _merge_queue.is_empty():
		var grid: Vector2i = _merge_queue[0]
		_merge_queue.remove_at(0)
		# Skip if already active or pending (could have been cached/loaded since queued)
		if grid in _active_cells or grid in _pending_merges:
			continue
		_request_merge(grid, _camera_cell_cached)
		budget -= 1


## Process completed merge results on main thread. Creates RS instances.
## Call once per frame from streaming manager.
## Returns number of cells completed.
func process_completions() -> int:
	if not enabled or _completed_queue.is_empty():
		return 0

	_completed_mutex.lock()
	var queue := _completed_queue.duplicate()
	_completed_queue.clear()
	_completed_mutex.unlock()

	var count := 0
	for entry: Dictionary in queue:
		var grid: Vector2i = entry["grid"]
		var mesh: ArrayMesh = entry["mesh"]
		var bytes: int = entry["bytes"]

		# Cell may have left range while merge was in progress
		if grid in _active_cells:
			continue

		# Evict LRU entries if over budget
		_cache_evict_to_fit(bytes)

		# Add to LRU cache
		_mesh_cache[grid] = mesh
		_mesh_sizes[grid] = bytes
		_lru_order.append(grid)
		_cache_used_bytes += bytes

		# Create RS instance
		if _create_rs_instance(grid, mesh, bytes):
			count += 1

		_stats["total_merges_completed"] += 1

	_stats["cache_entries"] = _mesh_cache.size()
	_stats["cache_bytes"] = _cache_used_bytes
	return count


## Get stats for debug/profiling
func get_stats() -> Dictionary:
	_stats["active_cells"] = _active_cells.size()
	_stats["pending_merges"] = _pending_merges.size()
	_stats["cache_entries"] = _mesh_cache.size()
	_stats["cache_bytes"] = _cache_used_bytes
	return _stats.duplicate()


## Clear all loaded HLOD cells and cache
## Toggle visibility of all active HLOD RS instances (for benchmark A/B testing)
func set_all_visible(visible: bool) -> void:
	for grid: Vector2i in _active_cells:
		var data: HLODCellData = _active_cells[grid]
		if data.instance_rid.is_valid():
			RenderingServer.instance_set_visible(data.instance_rid, visible)


func cleanup() -> void:
	# Cancel pending merges
	if _bg_processor:
		for grid: Vector2i in _pending_merges:
			_bg_processor.cancel_task(_pending_merges[grid])
		_bg_processor.task_completed.disconnect(_on_task_completed)
		_bg_processor.task_failed.disconnect(_on_task_failed)
	_pending_merges.clear()
	_task_to_grid.clear()
	_merge_queue.clear()

	# Free RS instances
	for grid: Vector2i in _active_cells:
		var data: HLODCellData = _active_cells[grid]
		if data.instance_rid.is_valid():
			RenderingServer.free_rid(data.instance_rid)
	_active_cells.clear()

	# Clear caches
	_mesh_cache.clear()
	_mesh_sizes.clear()
	_lru_order.clear()
	_cache_used_bytes = 0
	_completed_queue.clear()

#endregion


#region Merge Request Pipeline

## Collect merge inputs and submit to background worker.
## Single-pass ESM iteration: collects inputs AND counts mid-worthy refs in one loop.
## Fast path: reads mesh data from StaticObjectRenderer's already-registered MeshTypes.
## Slow path: loads prototype from model cache for models not yet registered (deep HLOD cells).
## Called max MERGES_PER_FRAME times per frame via process_merge_queue().
func _request_merge(grid: Vector2i, camera_cell: Vector2i) -> void:
	if not _static_renderer or not _bg_processor:
		return

	var cell_record: Variant = ESMManager.get_exterior_cell(grid.x, grid.y)
	if not cell_record:
		return

	# Single-pass: collect inputs AND count simultaneously
	var inputs: Array = []
	var refs_skipped := 0

	for ref in cell_record.references:
		if ref.is_deleted:
			continue

		var record_type: Array = [""]
		var base_record: Variant = ESMManager.get_any_record(str(ref.ref_id), record_type)
		if not base_record:
			continue

		var type_name_str: String = record_type[0] if record_type.size() > 0 else ""
		var model_path: String = _get_model_path(base_record)
		if model_path.is_empty():
			continue
		if not StreamingPolicyScript.is_mid_worthy(type_name_str, model_path):
			continue

		# Look up in static renderer's MeshType registry (fast path)
		var mesh_type_name := model_path.to_lower().replace("/", "\\")
		var sub_meshes: Array = _static_renderer.get_sub_meshes(mesh_type_name)

		if sub_meshes.is_empty():
			# Slow path: model not registered yet (deep HLOD cell beyond MID range).
			# Load prototype from model cache and register it.
			var prototype := _load_prototype_from_cache(model_path)
			if prototype:
				_static_renderer.register_from_prototype(mesh_type_name, prototype)
				prototype.free()
				sub_meshes = _static_renderer.get_sub_meshes(mesh_type_name)

		if sub_meshes.is_empty():
			refs_skipped += 1
			continue

		# Compute ref transform (cell-local space computed on worker thread)
		var pos: Vector3 = CS.vector_to_godot(ref.position)
		var scale: Vector3 = CS.scale_to_godot(ref.scale)
		var basis: Basis = CS.esm_rotation_to_godot_basis(ref.rotation)
		basis = basis.scaled(scale)
		var ref_transform := Transform3D(basis, pos)

		# Snapshot sub-mesh data for worker thread
		var ref_input := MergeRefInput.new()
		ref_input.ref_transform = ref_transform
		ref_input.sub_meshes = []

		for sub: StaticObjectRendererScript.SubMeshEntry in sub_meshes:
			if not sub.mesh_resource or not sub.mesh_resource is ArrayMesh:
				continue
			var sm := MergeSubMeshInput.new()
			sm.mesh = sub.mesh_resource as ArrayMesh
			sm.local_transform = sub.local_transform
			sm.material_override = sub.material_resource
			sm.surface_materials = sub.surface_materials.duplicate()
			ref_input.sub_meshes.append(sm)

		if not ref_input.sub_meshes.is_empty():
			inputs.append(ref_input)

	_stats["total_refs_skipped"] += refs_skipped

	# Cost-benefit: sparse cells don't benefit from merging (OpenMW insight)
	if inputs.size() < MIN_REFS_TO_MERGE:
		return

	# Submit merge task — priority = distance (closer cells merge first)
	var cell_origin := DU.cell_to_world_origin(grid)
	var dist_sq := DU.cell_distance_squared(grid, camera_cell)

	var task_id := _bg_processor.submit_task(
		_merge_cell_worker.bind(grid, inputs, cell_origin),
		dist_sq  # Lower = higher priority = closer cells first
	)
	_pending_merges[grid] = task_id
	_task_to_grid[task_id] = grid


## Worker thread entry point. Runs merge kernel, posts result to completion queue.
## Bound via Callable — all data pre-collected, no scene tree or ESMManager access.
func _merge_cell_worker(grid: Vector2i, inputs: Array, cell_origin: Vector3) -> Dictionary:
	var mesh := _merge_cell_sync(inputs, cell_origin)
	if not mesh:
		return {"grid": grid, "mesh": null, "bytes": 0}

	var bytes := _estimate_mesh_bytes(mesh)

	# Post to completion queue (thread-safe via mutex)
	_completed_mutex.lock()
	_completed_queue.append({"grid": grid, "mesh": mesh, "bytes": bytes})
	_completed_mutex.unlock()

	return {"grid": grid, "bytes": bytes}

#endregion


#region Merge Kernel (runs on worker thread — pure CPU, no I/O)

## Merge all inputs for a cell into a single ArrayMesh with LOD chain.
## Thread-safe: reads ArrayMesh surface arrays (immutable), creates new ArrayMesh.
static func _merge_cell_sync(inputs: Array, cell_origin: Vector3) -> ArrayMesh:
	# Material dedup: hash -> {material: Material, arrays_list: Array[Array]}
	var material_groups: Dictionary = {}

	for ref_input: MergeRefInput in inputs:
		for sm: MergeSubMeshInput in ref_input.sub_meshes:
			for si in range(sm.mesh.get_surface_count()):
				var arrays: Array = sm.mesh.surface_get_arrays(si)
				if arrays.is_empty():
					continue
				var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				if verts == null or verts.is_empty():
					continue

				# Compute full transform: ref_world × sub_local, then subtract cell origin
				var full_xform := ref_input.ref_transform * sm.local_transform
				# Move to cell-local space
				full_xform.origin -= cell_origin

				var is_identity := full_xform.is_equal_approx(Transform3D.IDENTITY)

				# Transform vertices into cell-local space
				if not is_identity:
					var xformed_verts := PackedVector3Array()
					xformed_verts.resize(verts.size())
					for vi in range(verts.size()):
						xformed_verts[vi] = full_xform * verts[vi]
					arrays[Mesh.ARRAY_VERTEX] = xformed_verts

					var normals: Variant = arrays[Mesh.ARRAY_NORMAL]
					if normals != null and normals is PackedVector3Array and not normals.is_empty():
						var normal_basis := full_xform.basis.inverse().transposed()
						var xformed_normals := PackedVector3Array()
						xformed_normals.resize(normals.size())
						for ni in range(normals.size()):
							xformed_normals[ni] = (normal_basis * normals[ni]).normalized()
						arrays[Mesh.ARRAY_NORMAL] = xformed_normals

				# Ensure index buffer exists
				var indices: Variant = arrays[Mesh.ARRAY_INDEX]
				if indices == null or (indices is PackedInt32Array and indices.is_empty()):
					var vert_count: int = verts.size()
					var identity_indices := PackedInt32Array()
					identity_indices.resize(vert_count)
					for vi in range(vert_count):
						identity_indices[vi] = vi
					arrays[Mesh.ARRAY_INDEX] = identity_indices

				# Resolve material
				var mat: Material = sm.material_override
				if not mat:
					if si < sm.surface_materials.size():
						mat = sm.surface_materials[si]
				if not mat:
					mat = sm.mesh.surface_get_material(si)

				# Group by material for merging
				var mat_hash: int = mat.get_instance_id() if mat else 0
				if mat_hash not in material_groups:
					material_groups[mat_hash] = {"material": mat, "arrays_list": []}
				material_groups[mat_hash]["arrays_list"].append(arrays)

	if material_groups.is_empty():
		return null

	# Flatten each material group into a single surface
	var flat_surfaces: Array[Dictionary] = []
	for mat_hash: int in material_groups:
		var group: Dictionary = material_groups[mat_hash]
		var arrays_list: Array = group["arrays_list"]
		var mat: Material = group["material"]
		var arrays: Array
		if arrays_list.size() == 1:
			arrays = arrays_list[0]
		else:
			arrays = _concatenate_surface_arrays(arrays_list)
		if arrays.is_empty():
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		flat_surfaces.append({"arrays": arrays, "material": mat, "vert_count": verts.size()})

	if flat_surfaces.is_empty():
		return null

	# Handle overflow (Godot caps at 256 surfaces)
	if flat_surfaces.size() > MAX_SURFACES:
		flat_surfaces.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a["vert_count"] > b["vert_count"]
		)
		var overflow_arrays: Array[Array] = []
		for i in range(MAX_SURFACES - 1, flat_surfaces.size()):
			overflow_arrays.append(flat_surfaces[i]["arrays"])
		flat_surfaces.resize(MAX_SURFACES - 1)
		var combined_overflow := _concatenate_surface_arrays(overflow_arrays)
		if not combined_overflow.is_empty():
			flat_surfaces.append({"arrays": combined_overflow, "material": null, "vert_count": 0})

	# Build merged ArrayMesh
	var merged_mesh := ArrayMesh.new()
	for entry: Dictionary in flat_surfaces:
		merged_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, entry["arrays"])
		if entry["material"]:
			merged_mesh.surface_set_material(merged_mesh.get_surface_count() - 1, entry["material"])

	if merged_mesh.get_surface_count() == 0:
		return null

	# Generate LOD chain (aggressive — only visible at 300m+)
	var lod_mesh := _generate_lods(merged_mesh)
	if lod_mesh:
		merged_mesh = lod_mesh

	merged_mesh.set_meta("has_lod_chain", true)
	return merged_mesh


## Generate LOD chain on merged mesh via ImporterMesh.
static func _generate_lods(mesh: ArrayMesh) -> ArrayMesh:
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


## Concatenate multiple surface arrays with the same material into one surface.
## Offsets index buffers to account for merged vertex base.
static func _concatenate_surface_arrays(arrays_list: Array) -> Array:
	if arrays_list.is_empty():
		return []

	var all_verts := PackedVector3Array()
	var all_normals := PackedVector3Array()
	var all_tangents := PackedFloat32Array()
	var all_colors := PackedColorArray()
	var all_uvs := PackedVector2Array()
	var all_uvs2 := PackedVector2Array()
	var all_indices := PackedInt32Array()
	var has_normals := false
	var has_tangents := false
	var has_colors := false
	var has_uvs := false
	var has_uvs2 := false

	# Probe ALL surfaces for attribute presence (union, not just first)
	for probe: Array in arrays_list:
		if not has_normals and probe.size() > Mesh.ARRAY_NORMAL and probe[Mesh.ARRAY_NORMAL] is PackedVector3Array:
			has_normals = true
		if not has_tangents and probe.size() > Mesh.ARRAY_TANGENT and probe[Mesh.ARRAY_TANGENT] is PackedFloat32Array:
			has_tangents = true
		if not has_colors and probe.size() > Mesh.ARRAY_COLOR and probe[Mesh.ARRAY_COLOR] is PackedColorArray:
			has_colors = true
		if not has_uvs and probe.size() > Mesh.ARRAY_TEX_UV and probe[Mesh.ARRAY_TEX_UV] is PackedVector2Array:
			has_uvs = true
		if not has_uvs2 and probe.size() > Mesh.ARRAY_TEX_UV2 and probe[Mesh.ARRAY_TEX_UV2] is PackedVector2Array:
			has_uvs2 = true

	for arrays: Array in arrays_list:
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var vert_count := verts.size()
		var base_vertex := all_verts.size()
		all_verts.append_array(verts)

		if has_normals:
			var normals: Variant = arrays[Mesh.ARRAY_NORMAL] if arrays.size() > Mesh.ARRAY_NORMAL else null
			if normals is PackedVector3Array and normals.size() == vert_count:
				all_normals.append_array(normals)
			else:
				var pad := PackedVector3Array()
				pad.resize(vert_count)
				pad.fill(Vector3.UP)
				all_normals.append_array(pad)

		if has_tangents:
			var tangents: Variant = arrays[Mesh.ARRAY_TANGENT] if arrays.size() > Mesh.ARRAY_TANGENT else null
			if tangents is PackedFloat32Array and tangents.size() == vert_count * 4:
				all_tangents.append_array(tangents)
			else:
				var pad := PackedFloat32Array()
				pad.resize(vert_count * 4)
				all_tangents.append_array(pad)

		if has_colors:
			var colors: Variant = arrays[Mesh.ARRAY_COLOR] if arrays.size() > Mesh.ARRAY_COLOR else null
			if colors is PackedColorArray and colors.size() == vert_count:
				all_colors.append_array(colors)
			else:
				var pad := PackedColorArray()
				pad.resize(vert_count)
				pad.fill(Color.WHITE)
				all_colors.append_array(pad)

		if has_uvs:
			var uvs: Variant = arrays[Mesh.ARRAY_TEX_UV] if arrays.size() > Mesh.ARRAY_TEX_UV else null
			if uvs is PackedVector2Array and uvs.size() == vert_count:
				all_uvs.append_array(uvs)
			else:
				var pad := PackedVector2Array()
				pad.resize(vert_count)
				all_uvs.append_array(pad)

		if has_uvs2:
			var uvs2: Variant = arrays[Mesh.ARRAY_TEX_UV2] if arrays.size() > Mesh.ARRAY_TEX_UV2 else null
			if uvs2 is PackedVector2Array and uvs2.size() == vert_count:
				all_uvs2.append_array(uvs2)
			else:
				var pad := PackedVector2Array()
				pad.resize(vert_count)
				all_uvs2.append_array(pad)

		# Offset indices by base vertex
		var indices: Variant = arrays[Mesh.ARRAY_INDEX] if arrays.size() > Mesh.ARRAY_INDEX else null
		if indices is PackedInt32Array and not indices.is_empty():
			for idx: int in indices:
				all_indices.append(idx + base_vertex)
		else:
			for vi in range(verts.size()):
				all_indices.append(vi + base_vertex)

	var result := []
	result.resize(Mesh.ARRAY_MAX)
	result[Mesh.ARRAY_VERTEX] = all_verts
	if has_normals and not all_normals.is_empty():
		result[Mesh.ARRAY_NORMAL] = all_normals
	if has_tangents and not all_tangents.is_empty():
		result[Mesh.ARRAY_TANGENT] = all_tangents
	if has_colors and not all_colors.is_empty():
		result[Mesh.ARRAY_COLOR] = all_colors
	if has_uvs and not all_uvs.is_empty():
		result[Mesh.ARRAY_TEX_UV] = all_uvs
	if has_uvs2 and not all_uvs2.is_empty():
		result[Mesh.ARRAY_TEX_UV2] = all_uvs2
	result[Mesh.ARRAY_INDEX] = all_indices
	return result

#endregion


#region RS Instance Management

## Create RenderingServer instance for a merged HLOD cell mesh.
## Returns true on success.
func _create_rs_instance(grid: Vector2i, mesh: ArrayMesh, estimated_bytes: int) -> bool:
	if not _scenario.is_valid() or not mesh:
		return false

	var rs := RenderingServer
	var rid := rs.instance_create()
	rs.instance_set_base(rid, mesh.get_rid())
	rs.instance_set_scenario(rid, _scenario)

	# Position at cell origin (vertices are in cell-local space)
	var cell_origin := DU.cell_to_world_origin(grid)
	rs.instance_set_transform(rid, Transform3D(Basis.IDENTITY, cell_origin))

	# Visibility range: HLOD_START to HLOD_END with fade margins
	rs.instance_geometry_set_visibility_range(
		rid,
		DU.HLOD_START, DU.HLOD_END,
		20.0, 20.0,
		RenderingServer.VISIBILITY_RANGE_FADE_SELF
	)

	rs.instance_geometry_set_lod_bias(rid, 1.0)

	var data := HLODCellData.new()
	data.grid = grid
	data.instance_rid = rid
	data.mesh = mesh
	data.surface_count = mesh.get_surface_count()
	data.estimated_bytes = estimated_bytes
	_active_cells[grid] = data
	return true


## Unload a single HLOD cell (free RS instance, keep mesh in LRU cache)
func _unload_cell(grid: Vector2i) -> void:
	if grid not in _active_cells:
		return

	var data: HLODCellData = _active_cells[grid]
	if data.instance_rid.is_valid():
		RenderingServer.free_rid(data.instance_rid)
	_active_cells.erase(grid)

#endregion


#region LRU Cache

## Touch an entry (move to end of LRU order)
func _lru_touch(grid: Vector2i) -> void:
	var idx := _lru_order.find(grid)
	if idx >= 0:
		_lru_order.remove_at(idx)
	_lru_order.append(grid)


## Evict oldest entries until `needed_bytes` fits within budget
func _cache_evict_to_fit(needed_bytes: int) -> void:
	while _cache_used_bytes + needed_bytes > CACHE_BUDGET_BYTES and not _lru_order.is_empty():
		var oldest: Vector2i = _lru_order[0]
		_lru_order.remove_at(0)

		# If cell is still active, free its RS instance too
		if oldest in _active_cells:
			var data: HLODCellData = _active_cells[oldest]
			if data.instance_rid.is_valid():
				RenderingServer.free_rid(data.instance_rid)
			_active_cells.erase(oldest)

		var evicted_bytes: int = _mesh_sizes.get(oldest, 0)
		_cache_used_bytes -= evicted_bytes
		_mesh_cache.erase(oldest)
		_mesh_sizes.erase(oldest)

#endregion


#region Background Processor Callbacks

func _on_task_completed(task_id: int, _result: Variant) -> void:
	# O(1) lookup via reverse map
	if task_id in _task_to_grid:
		var grid: Vector2i = _task_to_grid[task_id]
		_pending_merges.erase(grid)
		_task_to_grid.erase(task_id)


func _on_task_failed(task_id: int, error: String) -> void:
	if task_id in _task_to_grid:
		var grid: Vector2i = _task_to_grid[task_id]
		Log.warn("hlod", "Merge failed for cell %s: %s" % [str(grid), error])
		_pending_merges.erase(grid)
		_task_to_grid.erase(task_id)

#endregion


#region Helpers

## Extract model path from an ESM record
static func _get_model_path(record: Variant) -> String:
	if record == null:
		return ""
	if "model" in record and record.model is String:
		return record.model
	if "mesh" in record and record.mesh is String:
		return record.mesh
	return ""


## Load a prototype from the model cache (.res files).
## Used for models in deep HLOD cells not yet registered in StaticObjectRenderer.
## Returns instantiated Node3D (caller must free), or null if not in cache.
func _load_prototype_from_cache(model_path: String) -> Node3D:
	if _models_dir.is_empty():
		return null
	var cache_key := model_path.to_lower().replace("/", "\\")
	var safe_name := cache_key.replace("\\", "_").replace("/", "_").replace(":", "_").replace(".", "_")
	var scene_path := _models_dir.path_join(safe_name + ".res")

	if not FileAccess.file_exists(scene_path):
		return null

	var packed_scene := ResourceLoader.load(scene_path, "PackedScene") as PackedScene
	if not packed_scene:
		return null

	return packed_scene.instantiate() as Node3D


## Estimate ArrayMesh memory usage in bytes
static func _estimate_mesh_bytes(mesh: ArrayMesh) -> int:
	var total := 0
	for si in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(si)
		if arrays.is_empty():
			continue
		var verts: Variant = arrays[Mesh.ARRAY_VERTEX]
		if verts is PackedVector3Array:
			# pos(12) + normal(12) + uv(8) + index(4) + overhead ≈ 48 bytes/vert
			# ×1.5 for LOD chain overhead
			total += verts.size() * 72
	return total

#endregion
