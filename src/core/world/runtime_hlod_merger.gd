## RuntimeHLODMerger — OpenMW-style distance-adaptive chunk paging
##
## Phase 4b of docs/audit/OBJECT_PAGING_PLAN.md §11: evolves from a single-tier
## HLOD cell merger (phases 1-3) into a multi-tier adaptive pager. Chunks are
## keyed by `Vector3i(center_cell.x, center_cell.y, size_level)` and sized
## adaptively per the plan §4 table:
##
##     size_level 0 (1×1 cells) — band [150, 300)m — near-MID
##     size_level 1 (2×2 cells) — band [300, 600)m — far-MID
##     size_level 2 (4×4 cells) — band [600, 1000)m — HLOD
##
## `update_for_camera` runs the top-down anti-overlap walk from plan §4.3:
## larger tiers claim their cells first; smaller tiers can't sub-divide an
## accepted larger chunk. Strict half-open bands; hysteresis lands in Phase 4c.
##
## Pipeline (per chunk):
##   1. Chunk enters a tier band → main thread iterates the size×size covered
##      cells, collects refs via ESMManager, runs type filter + size filter +
##      SizeCache.
##   2. Background worker: ObjectPagingKernel.merge_refs() transforms verts,
##      runs cost-benefit, groups by material, concatenates, LOD-chains.
##   3. Main thread: creates RS instance at chunk center world position with
##      tier-specific visibility_range; adds to LRU cache.
##
## Thread safety:
##   - Main thread: CellRecord iteration, MeshType lookup/registration, RS create.
##   - Worker thread: ObjectPagingKernel.merge_refs() reads ArrayMesh surfaces
##     read-only, creates isolated ImporterMesh.
##   - SizeCache guarded by mutex (written from main, read from main; mutex is
##     future-proofing for worker reads if that path ever ships).
class_name RuntimeHLODMerger
extends RefCounted

const DU := preload("res://src/core/world/distance_utils.gd")
const CS := preload("res://src/core/coordinate_system.gd")
const StaticObjectRendererScript := preload("res://src/core/world/static_object_renderer.gd")
const Kernel := preload("res://src/core/world/object_paging_kernel.gd")

## LRU cache budget in bytes (default 256 MB)
const CACHE_BUDGET_BYTES: int = 256 * 1024 * 1024

## Minimum refs to justify merging a chunk (OpenMW cost-benefit insight).
## Sparse chunks with fewer refs aren't worth the merge overhead — refs stay
## as individual RS instances through StaticObjectRenderer.
const MIN_REFS_TO_MERGE: int = 15

## Merge-queue stagger budget (main-thread work per frame).
const MERGES_PER_FRAME: int = 2

## visibility_range fade margins (same on both sides of a tier handoff).
const TIER_FADE_MARGIN: float = 20.0


#region Internal Data Classes

## Per-chunk state for an active merged region.
## `key.xy` = aligned center_cell, `key.z` = size_level (0/1/2).
class HLODChunkData:
	var key: Vector3i
	var instance_rid: RID
	var mesh: ArrayMesh  ## Strong ref — prevents GC
	var surface_count: int = 0
	var estimated_bytes: int = 0

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

## Active paging chunks with RS instances. Keyed by Vector3i = (center_cell.x, center_cell.y, size_level).
var _active_chunks: Dictionary = {}  # Vector3i -> HLODChunkData

## Pending merge tasks (submitted to background processor)
var _pending_merges: Dictionary = {}  # Vector3i -> int (task_id)
var _task_to_key: Dictionary = {}  # int (task_id) -> Vector3i

## Merge queue — chunks waiting for main-thread data collection + worker submission.
## Staggered: max MERGES_PER_FRAME processed per frame to avoid main-thread stalls.
var _merge_queue: Array[Vector3i] = []
var _camera_cell_cached: Vector2i = Vector2i.ZERO
var _camera_world_pos_cached: Vector3 = Vector3.ZERO

## Phase 2 — SizeCache for the projected-size filter (OpenMW ObjectPaging §2.2).
## Key = ref_num (int). Value = radius²×scale² at last rejection. Mesh-invariant
## value — re-tested against current dist²×min_size² without re-reading AABB.
var _size_cache: Dictionary = {}  # int (ref_num) -> float
var _size_cache_mutex: Mutex = Mutex.new()

## Completed merge results waiting for main-thread RS instance creation.
var _completed_queue: Array = []  # Array of {key: Vector3i, mesh: ArrayMesh, bytes: int}
var _completed_mutex: Mutex = Mutex.new()

## LRU mesh cache
var _mesh_cache: Dictionary = {}  # Vector3i -> ArrayMesh
var _mesh_sizes: Dictionary = {}  # Vector3i -> int (bytes)
var _lru_order: Array[Vector3i] = []  # Oldest first
var _cache_used_bytes: int = 0

## Stats
var _stats: Dictionary = {
	"active_cells": 0,         # kept name for caller compat; counts all active chunks across tiers
	"pending_merges": 0,
	"cache_entries": 0,
	"cache_bytes": 0,
	"total_merges_completed": 0,
	"total_refs_skipped": 0,
	"refs_size_rejected": 0,   # Phase 2 — below projected-size threshold
	"size_cache_hits": 0,      # Phase 2 — short-circuit AABB lookups
	"size_cache_size": 0,      # Phase 2 — SizeCache entry count
	"refs_type_rejected": 0,   # Phase 3a — rejected by record-type table
	"chunks_tier_0": 0,        # Phase 4 — per-tier active chunk counts
	"chunks_tier_1": 0,
	"chunks_tier_2": 0,
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


## Update active paging chunks based on camera position. Runs the top-down
## anti-overlap walk across tiers (plan §4.3). Returns number of chunks changed.
##
## `camera_world_pos` is the actual camera world position — used by both the
## chunk-center band classification (§4.2) and the per-ref projected-size test
## (§2.2, Phase 2). Legacy callers may pass `Vector3.INF` to approximate from
## `camera_cell`, but new callers should provide the real position.
func update_for_camera(camera_cell: Vector2i, camera_world_pos: Vector3 = Vector3.INF) -> int:
	if not enabled:
		return 0
	_camera_cell_cached = camera_cell
	if camera_world_pos == Vector3.INF:
		# Legacy fallback — approximate with cell center. Phase 2+ callers pass
		# the real camera world position.
		_camera_world_pos_cached = DU.cell_to_world_center(camera_cell)
	else:
		_camera_world_pos_cached = camera_world_pos

	# Plan §4.3 — top-down anti-overlap walk. Larger tiers claim their cells
	# first; smaller tiers skip any chunk whose 1×1 sub-cells are covered.
	var desired_chunks: Dictionary = _compute_desired_chunks(camera_cell, _camera_world_pos_cached)

	var changed := 0

	# Queue new chunks (stagger via process_merge_queue)
	for key: Vector3i in desired_chunks:
		if key in _active_chunks or key in _pending_merges:
			continue
		# Check LRU cache (fast path — previously merged)
		if key in _mesh_cache:
			if _create_rs_instance(key, _mesh_cache[key], _mesh_sizes.get(key, 0)):
				_lru_touch(key)
				changed += 1
		elif key not in _merge_queue:
			_merge_queue.append(key)

	# Sort merge queue by chunk-center distance (closest first)
	if not _merge_queue.is_empty():
		_merge_queue.sort_custom(_sort_by_chunk_distance)

	# Unload chunks that left desired set
	var to_unload: Array[Vector3i] = []
	for key: Vector3i in _active_chunks:
		if key not in desired_chunks:
			to_unload.append(key)
	for key: Vector3i in to_unload:
		_unload_chunk(key)
		changed += 1

	# Cancel pending merges that left desired set
	var to_cancel: Array[Vector3i] = []
	for key: Vector3i in _pending_merges:
		if key not in desired_chunks:
			to_cancel.append(key)
	for key: Vector3i in to_cancel:
		if _bg_processor:
			_bg_processor.cancel_task(_pending_merges[key])
		var tid: int = _pending_merges[key]
		_task_to_key.erase(tid)
		_pending_merges.erase(key)

	# Remove queued chunks that left desired set
	_merge_queue = _merge_queue.filter(func(k: Vector3i) -> bool: return k in desired_chunks)

	_refresh_stats()
	return changed


## Process staggered merge queue — max MERGES_PER_FRAME chunks per call.
## Each call does main-thread data collection + submits to worker.
## Call once per frame from streaming manager (BEFORE process_completions).
func process_merge_queue() -> void:
	if not enabled or _merge_queue.is_empty():
		return

	var budget := MERGES_PER_FRAME
	while budget > 0 and not _merge_queue.is_empty():
		var key: Vector3i = _merge_queue[0]
		_merge_queue.remove_at(0)
		# Skip if already active or pending (could have been cached/loaded since queued)
		if key in _active_chunks or key in _pending_merges:
			continue
		_request_chunk_merge(key, _camera_cell_cached, _camera_world_pos_cached)
		budget -= 1


## Process completed merge results on main thread. Creates RS instances.
## Call once per frame from streaming manager.
## Returns number of chunks completed.
func process_completions() -> int:
	if not enabled or _completed_queue.is_empty():
		return 0

	_completed_mutex.lock()
	var queue := _completed_queue.duplicate()
	_completed_queue.clear()
	_completed_mutex.unlock()

	var count := 0
	for entry: Dictionary in queue:
		var key: Vector3i = entry["key"]
		var mesh: ArrayMesh = entry["mesh"]
		var bytes: int = entry["bytes"]

		# Chunk may have left range while merge was in progress
		if key in _active_chunks:
			continue

		_cache_evict_to_fit(bytes)
		_mesh_cache[key] = mesh
		_mesh_sizes[key] = bytes
		_lru_order.append(key)
		_cache_used_bytes += bytes

		if _create_rs_instance(key, mesh, bytes):
			count += 1

		_stats["total_merges_completed"] += 1

	_refresh_stats()
	return count


## Get stats for debug/profiling
func get_stats() -> Dictionary:
	_refresh_stats()
	return _stats.duplicate()


## Toggle visibility of all active chunk RS instances (benchmark A/B helper).
func set_all_visible(visible: bool) -> void:
	for key: Vector3i in _active_chunks:
		var data: HLODChunkData = _active_chunks[key]
		if data.instance_rid.is_valid():
			RenderingServer.instance_set_visible(data.instance_rid, visible)


func cleanup() -> void:
	# Cancel pending merges
	if _bg_processor:
		for key: Vector3i in _pending_merges:
			_bg_processor.cancel_task(_pending_merges[key])
		_bg_processor.task_completed.disconnect(_on_task_completed)
		_bg_processor.task_failed.disconnect(_on_task_failed)
	_pending_merges.clear()
	_task_to_key.clear()
	_merge_queue.clear()

	# Free RS instances
	for key: Vector3i in _active_chunks:
		var data: HLODChunkData = _active_chunks[key]
		if data.instance_rid.is_valid():
			RenderingServer.free_rid(data.instance_rid)
	_active_chunks.clear()

	# Clear caches
	_mesh_cache.clear()
	_mesh_sizes.clear()
	_lru_order.clear()
	_cache_used_bytes = 0
	_completed_queue.clear()

	# Phase 2 SizeCache
	_size_cache_mutex.lock()
	_size_cache.clear()
	_size_cache_mutex.unlock()

#endregion


#region Phase 4b — Top-down anti-overlap walk (plan §4.3)

## Compute desired chunks across all three tiers using the top-down walk.
## Returns Dictionary[Vector3i -> true] of chunks that should be active.
## Main-thread. Bounded to ~147 chunk candidates per call (plan §4.5).
func _compute_desired_chunks(camera_cell: Vector2i, camera_world_pos: Vector3) -> Dictionary:
	var desired: Dictionary = {}
	var covered_cells: Dictionary = {}  # Vector2i -> true (1×1 cells claimed by larger chunks)
	var camera_xz := Vector2(camera_world_pos.x, camera_world_pos.z)

	# Largest tier first. Smaller tiers can't overlap a larger accepted chunk.
	for size_level in [2, 1, 0]:
		var size: int = 1 << size_level
		var band_start: float = DU.paging_band_start(size_level)
		var band_end: float = DU.paging_band_end(size_level)
		var ring_radius: int = DU.paging_ring_radius(size_level)

		# Align camera to this tier's chunk grid
		var cam_aligned := DU.chunk_key_for_cell(camera_cell, size_level)

		for dy in range(-ring_radius, ring_radius + 1):
			for dx in range(-ring_radius, ring_radius + 1):
				var center_cell := Vector2i(cam_aligned.x + dx * size, cam_aligned.y + dy * size)

				# Band classification by chunk-CENTER distance (plan §4.2)
				var center_world := DU.chunk_center_world(center_cell, size_level)
				var dist: float = camera_xz.distance_to(center_world)
				if dist < band_start or dist >= band_end:
					continue

				# Anti-overlap: skip if any 1×1 sub-cell is already claimed
				if _any_sub_cell_covered(center_cell, size, covered_cells):
					continue

				# Accept chunk + mark its 1×1 sub-cells
				var key := Vector3i(center_cell.x, center_cell.y, size_level)
				desired[key] = true
				_mark_sub_cells(center_cell, size, covered_cells)

	return desired


static func _any_sub_cell_covered(center_cell: Vector2i, size: int, covered: Dictionary) -> bool:
	for sy in range(size):
		for sx in range(size):
			if Vector2i(center_cell.x + sx, center_cell.y + sy) in covered:
				return true
	return false


static func _mark_sub_cells(center_cell: Vector2i, size: int, covered: Dictionary) -> void:
	for sy in range(size):
		for sx in range(size):
			covered[Vector2i(center_cell.x + sx, center_cell.y + sy)] = true


## Sort comparator for the merge queue — closer chunks merge first.
## Uses chunk-center XZ distance (2D plane) for consistency with band class.
func _sort_by_chunk_distance(a: Vector3i, b: Vector3i) -> bool:
	var camera_xz := Vector2(_camera_world_pos_cached.x, _camera_world_pos_cached.z)
	var da := camera_xz.distance_squared_to(DU.chunk_center_world(Vector2i(a.x, a.y), a.z))
	var db := camera_xz.distance_squared_to(DU.chunk_center_world(Vector2i(b.x, b.y), b.z))
	return da < db

#endregion


#region Phase 3a — record-type eligibility (OpenMW ObjectPaging §2.4)

## Contract (matches `inspos/openmw/apps/openmw/mwrender/objectpaging.cpp:55-75`):
##   STAT, DOOR, ACTI            → always eligible
##   CONT                        → eligible only at size_level == 0 (1×1 chunks)
##   LIGH, NPC_, CREA, inventory → never eligible
##
## **TES4 records** (REC_FURN4, REC_TREE4, REC_STAT4, etc.) intentionally
## omitted — Godotwind ships Morrowind (TES3) data only.
##
## Pure static — unit-testable without a merger instance.
static func _type_eligible(type_name: String, size_level: int) -> bool:
	match type_name:
		"static", "door", "activator":
			return true
		"container":
			return size_level == 0
		_:
			return false


## Phase 2 — projected-size test (OpenMW ObjectPaging §2.2).
##
## Contract (matches `inspos/openmw/apps/openmw/mwrender/objectpaging.cpp:793-799`):
##   keep iff  mesh_radius² × scale² >= dist² × min_size²
##
## **Divergence from OpenMW:** `mesh_radius_sq == 0` returns `true` (conservative
## keep). Caller guards this case if strict parity is required.
static func _is_size_worthy(mesh_radius_sq: float, scale_f: float, dist_sq: float, min_size_sq: float) -> bool:
	if mesh_radius_sq <= 0.0 or dist_sq <= 0.0:
		return true
	return mesh_radius_sq * scale_f * scale_f >= dist_sq * min_size_sq

#endregion


#region Merge Request Pipeline

## Collect merge inputs for a chunk and submit to background worker.
## Phase 4b: chunk covers `size × size` cells starting at `(key.x, key.y)`.
## Phase 4 types/size_level threaded through via key.z.
func _request_chunk_merge(key: Vector3i, camera_cell: Vector2i, camera_world_pos: Vector3) -> void:
	if not _static_renderer or not _bg_processor:
		return

	var size_level: int = key.z
	var size: int = 1 << size_level
	var center_cell := Vector2i(key.x, key.y)
	var min_size_sq: float = DU.PAGING_MIN_SIZE_SQ

	var inputs: Array = []
	var refs_skipped := 0
	var refs_size_rejected := 0
	var refs_type_rejected := 0
	var size_cache_hits := 0

	for cy in range(size):
		for cx in range(size):
			var cell_grid := Vector2i(center_cell.x + cx, center_cell.y + cy)
			var cell_record: Variant = ESMManager.get_exterior_cell(cell_grid.x, cell_grid.y)
			if not cell_record:
				continue

			for ref in cell_record.references:
				if ref.is_deleted:
					continue

				var record_type: Array = [""]
				var base_record: Variant = ESMManager.get_any_record(str(ref.ref_id), record_type)
				if not base_record:
					continue

				var type_name: String = record_type[0] if record_type.size() > 0 else ""
				if not _type_eligible(type_name, size_level):
					refs_type_rejected += 1
					continue

				var model_path: String = _get_model_path(base_record)
				if model_path.is_empty():
					continue

				# Compute ref transform once
				var pos: Vector3 = CS.vector_to_godot(ref.position)
				var scale: Vector3 = CS.scale_to_godot(ref.scale)
				var basis: Basis = CS.esm_rotation_to_godot_basis(ref.rotation)
				basis = basis.scaled(scale)
				var ref_transform := Transform3D(basis, pos)

				# Phase 2 projected-size filter with SizeCache short-circuit
				var mesh_type_name := model_path.to_lower().replace("/", "\\")
				var cache_key: int = ref.ref_num
				var scale_f: float = ref.scale
				var dist_sq: float = pos.distance_squared_to(camera_world_pos)
				var size_threshold: float = dist_sq * min_size_sq

				var cached_rs2: float = -1.0
				_size_cache_mutex.lock()
				if cache_key in _size_cache:
					cached_rs2 = _size_cache[cache_key]
				_size_cache_mutex.unlock()

				if cached_rs2 >= 0.0:
					if cached_rs2 < size_threshold:
						refs_size_rejected += 1
						size_cache_hits += 1
						continue
					_size_cache_mutex.lock()
					_size_cache.erase(cache_key)
					_size_cache_mutex.unlock()

				var aabb: AABB = _static_renderer.get_mesh_aabb(mesh_type_name)
				var mesh_radius_sq: float = 0.0
				if aabb.size != Vector3.ZERO:
					mesh_radius_sq = aabb.size.length_squared() * 0.25

				if mesh_radius_sq > 0.0:
					var rs2: float = mesh_radius_sq * scale_f * scale_f
					if rs2 < size_threshold:
						_size_cache_mutex.lock()
						_size_cache[cache_key] = rs2
						_size_cache_mutex.unlock()
						refs_size_rejected += 1
						continue

				var sub_meshes: Array = _static_renderer.get_sub_meshes(mesh_type_name)
				if sub_meshes.is_empty():
					var prototype := _load_prototype_from_cache(model_path)
					if prototype:
						_static_renderer.register_from_prototype(mesh_type_name, prototype)
						prototype.free()
						sub_meshes = _static_renderer.get_sub_meshes(mesh_type_name)
				if sub_meshes.is_empty():
					refs_skipped += 1
					continue

				var ref_input := Kernel.RefInput.new()
				ref_input.ref_transform = ref_transform
				ref_input.sub_meshes = []
				for sub: StaticObjectRendererScript.SubMeshEntry in sub_meshes:
					if not sub.mesh_resource or not sub.mesh_resource is ArrayMesh:
						continue
					var sm := Kernel.SubMeshInput.new()
					sm.mesh = sub.mesh_resource as ArrayMesh
					sm.local_transform = sub.local_transform
					sm.material_override = sub.material_resource
					sm.surface_materials = sub.surface_materials.duplicate()
					ref_input.sub_meshes.append(sm)
				if not ref_input.sub_meshes.is_empty():
					inputs.append(ref_input)

	_stats["total_refs_skipped"] += refs_skipped
	_stats["refs_size_rejected"] += refs_size_rejected
	_stats["refs_type_rejected"] += refs_type_rejected
	_stats["size_cache_hits"] += size_cache_hits

	# Cost-benefit minimum — sparse chunks aren't worth merging
	if inputs.size() < MIN_REFS_TO_MERGE:
		return

	# Priority = chunk-center distance² (closer first)
	var chunk_origin := _chunk_origin_world(key)
	var camera_xz := Vector2(camera_world_pos.x, camera_world_pos.z)
	var center_xz := Vector2(chunk_origin.x, chunk_origin.z)
	var priority_sq := camera_xz.distance_squared_to(center_xz)

	var task_id := _bg_processor.submit_task(
		_merge_chunk_worker.bind(key, inputs, chunk_origin),
		priority_sq
	)
	_pending_merges[key] = task_id
	_task_to_key[task_id] = key


## Worker thread entry point. Runs merge kernel, posts result to completion queue.
## All data pre-collected — no scene tree or ESMManager access here.
## `key.z` is threaded through as `size_level` to the kernel (cost-benefit uses it).
func _merge_chunk_worker(key: Vector3i, inputs: Array, chunk_origin: Vector3) -> Dictionary:
	var mesh := Kernel.merge_refs(inputs, chunk_origin, key.z)
	if not mesh:
		return {"key": key, "mesh": null, "bytes": 0}

	var bytes := Kernel.estimate_mesh_bytes(mesh)

	_completed_mutex.lock()
	_completed_queue.append({"key": key, "mesh": mesh, "bytes": bytes})
	_completed_mutex.unlock()

	return {"key": key, "bytes": bytes}

#endregion


#region RS Instance Management

## World-space center of the chunk. Used to place the RS instance and to
## offset vertex positions during merge (merged mesh is in chunk-local space).
static func _chunk_origin_world(key: Vector3i) -> Vector3:
	var center_xz := DU.chunk_center_world(Vector2i(key.x, key.y), key.z)
	return Vector3(center_xz.x, 0.0, center_xz.y)


## Create RenderingServer instance for a merged chunk mesh.
## Visibility range is tier-specific: [band_start, band_end] with 20m fade.
func _create_rs_instance(key: Vector3i, mesh: ArrayMesh, estimated_bytes: int) -> bool:
	if not _scenario.is_valid() or not mesh:
		return false

	var rs := RenderingServer
	var rid := rs.instance_create()
	rs.instance_set_base(rid, mesh.get_rid())
	rs.instance_set_scenario(rid, _scenario)

	# Place at chunk center (vertices are in chunk-local space)
	rs.instance_set_transform(rid, Transform3D(Basis.IDENTITY, _chunk_origin_world(key)))

	# Tier-specific visibility_range (plan §4/§9)
	var band_start: float = DU.paging_band_start(key.z)
	var band_end: float = DU.paging_band_end(key.z)
	rs.instance_geometry_set_visibility_range(
		rid,
		band_start, band_end,
		TIER_FADE_MARGIN, TIER_FADE_MARGIN,
		RenderingServer.VISIBILITY_RANGE_FADE_SELF
	)
	rs.instance_geometry_set_lod_bias(rid, 1.0)

	var data := HLODChunkData.new()
	data.key = key
	data.instance_rid = rid
	data.mesh = mesh
	data.surface_count = mesh.get_surface_count()
	data.estimated_bytes = estimated_bytes
	_active_chunks[key] = data
	return true


## Unload a single chunk (free RS instance, keep mesh in LRU cache).
func _unload_chunk(key: Vector3i) -> void:
	if key not in _active_chunks:
		return
	var data: HLODChunkData = _active_chunks[key]
	if data.instance_rid.is_valid():
		RenderingServer.free_rid(data.instance_rid)
	_active_chunks.erase(key)

#endregion


#region LRU Cache

func _lru_touch(key: Vector3i) -> void:
	var idx := _lru_order.find(key)
	if idx >= 0:
		_lru_order.remove_at(idx)
	_lru_order.append(key)


func _cache_evict_to_fit(needed_bytes: int) -> void:
	while _cache_used_bytes + needed_bytes > CACHE_BUDGET_BYTES and not _lru_order.is_empty():
		var oldest: Vector3i = _lru_order[0]
		_lru_order.remove_at(0)

		# If chunk is still active, free its RS instance too
		if oldest in _active_chunks:
			var data: HLODChunkData = _active_chunks[oldest]
			if data.instance_rid.is_valid():
				RenderingServer.free_rid(data.instance_rid)
			_active_chunks.erase(oldest)

		var evicted_bytes: int = _mesh_sizes.get(oldest, 0)
		_cache_used_bytes -= evicted_bytes
		_mesh_cache.erase(oldest)
		_mesh_sizes.erase(oldest)

#endregion


#region Background Processor Callbacks

func _on_task_completed(task_id: int, _result: Variant) -> void:
	if task_id in _task_to_key:
		var key: Vector3i = _task_to_key[task_id]
		_pending_merges.erase(key)
		_task_to_key.erase(task_id)


func _on_task_failed(task_id: int, error: String) -> void:
	if task_id in _task_to_key:
		var key: Vector3i = _task_to_key[task_id]
		Log.warn("hlod", "Merge failed for chunk %s: %s" % [str(key), error])
		_pending_merges.erase(key)
		_task_to_key.erase(task_id)

#endregion


#region Stats

## Refresh derived stat fields. Called from get_stats / update_for_camera /
## process_completions so the caller always sees an up-to-date snapshot.
func _refresh_stats() -> void:
	_stats["active_cells"] = _active_chunks.size()
	_stats["pending_merges"] = _pending_merges.size()
	_stats["cache_entries"] = _mesh_cache.size()
	_stats["cache_bytes"] = _cache_used_bytes

	var t0 := 0
	var t1 := 0
	var t2 := 0
	for key: Vector3i in _active_chunks:
		match key.z:
			0: t0 += 1
			1: t1 += 1
			2: t2 += 1
	_stats["chunks_tier_0"] = t0
	_stats["chunks_tier_1"] = t1
	_stats["chunks_tier_2"] = t2

	_size_cache_mutex.lock()
	_stats["size_cache_size"] = _size_cache.size()
	_size_cache_mutex.unlock()

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
## Used for models not yet registered in StaticObjectRenderer (far chunks).
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

#endregion
