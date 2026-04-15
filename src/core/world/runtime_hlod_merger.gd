## RuntimeHLODMerger — Runtime cell-level HLOD merging (OpenMW-style)
##
## Merges cell geometry on demand using WorkerThreadPool when cells enter
## HLOD range (300-1000m). No disk prebake needed.
##
## Phase 1 of the paging refactor (docs/audit/OBJECT_PAGING_PLAN.md §11):
## the merge math now lives in `object_paging_kernel.gd` as a shared kernel.
## This module is the HLOD-cell caller; the forthcoming ObjectPaging module
## will be the distance-adaptive caller. Both call the same verified kernel.
## Phases 2-6 collapse this module into ObjectPaging — it survives here as
## the rollback point for the refactor.
##
## Pipeline:
##   1. Cell enters HLOD range → main thread collects mesh data from
##      StaticObjectRenderer (fast path) or loads prototype from model cache
##      (slow path for deep HLOD cells).
##   2. Background worker: ObjectPagingKernel.merge_refs() transforms vertices,
##      groups by material, concatenates, generates LODs. Viable on worker.
##   3. Main thread: creates RS instance from merged ArrayMesh, adds to LRU.
##
## Thread safety:
##   - Main thread: CellRecord iteration, MeshType lookup/registration, RS create.
##   - Worker thread: ObjectPagingKernel.merge_refs() reads ArrayMesh surfaces
##     read-only, creates isolated ImporterMesh.
class_name RuntimeHLODMerger
extends RefCounted

const DU := preload("res://src/core/world/distance_utils.gd")
const CS := preload("res://src/core/coordinate_system.gd")
const StaticObjectRendererScript := preload("res://src/core/world/static_object_renderer.gd")
const Kernel := preload("res://src/core/world/object_paging_kernel.gd")
# StreamingPolicy preload deleted in Phase 2 — `is_mid_worthy` keyword gate
# replaced by the projected-size filter (`_is_size_worthy`). StreamingPolicy
# still owns `should_generate_lods` for the prebake pipeline; untouched.

## LRU cache budget in bytes (default 256 MB)
const CACHE_BUDGET_BYTES: int = 256 * 1024 * 1024

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
var _camera_world_pos_cached: Vector3 = Vector3.ZERO
const MERGES_PER_FRAME: int = 2

## Phase 2 — SizeCache for the projected-size filter (OpenMW ObjectPaging §2.2).
## Refs rejected by `mesh_radius² × scale² < dist² × PAGING_MIN_SIZE²` are
## memoized here by ref_num so subsequent cell re-evaluations skip the AABB
## lookup + distance math entirely. Key = ref_num (int). Value = the scaled
## radius² at rejection time (float, informational — not re-used in the check
## because dist changes with camera; the presence of the key alone marks the
## ref as "size-rejected at least once; re-check inexpensive").
##
## Note: unlike OpenMW, we re-evaluate the size test every cell re-request
## rather than trusting the cached value unconditionally — camera can move,
## and a ref that was sub-threshold last frame might be above-threshold now.
## The cache short-circuits the AABB lookup (which requires a dict traversal
## in StaticObjectRenderer), not the whole test.
var _size_cache: Dictionary = {}  # int (ref_num) -> float (radius² × scale² at last check)
var _size_cache_mutex: Mutex = Mutex.new()

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
	"refs_size_rejected": 0,   # Phase 2 — refs below projected-size threshold
	"size_cache_hits": 0,      # Phase 2 — short-circuit AABB lookups
	"size_cache_size": 0,      # Phase 2 — SizeCache entry count
	"refs_type_rejected": 0,   # Phase 3a — refs rejected by record-type table
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
##
## `camera_world_pos` (Phase 2): actual camera position in world space, used by
## the projected-size filter (`radius² × scale² < dSqr × minSize²`). Defaults
## to cell-center if caller hasn't migrated yet — accuracy loss bounded to
## half a cell (~58m), irrelevant at paging distances of 300-1000m.
func update_for_camera(camera_cell: Vector2i, camera_world_pos: Vector3 = Vector3.INF) -> int:
	if not enabled:
		return 0
	_camera_cell_cached = camera_cell
	if camera_world_pos == Vector3.INF:
		# Legacy callers — approximate with cell origin. Phase 2 and later
		# callers should pass the real camera world position.
		_camera_world_pos_cached = DU.cell_to_world_origin(camera_cell)
	else:
		_camera_world_pos_cached = camera_world_pos
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
		_request_merge(grid, _camera_cell_cached, _camera_world_pos_cached)
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
	_size_cache_mutex.lock()
	_stats["size_cache_size"] = _size_cache.size()
	_size_cache_mutex.unlock()
	return _stats.duplicate()


## Phase 3a — record-type eligibility for paging (OpenMW ObjectPaging §2.4).
##
## Contract (matches `inspos/openmw/apps/openmw/mwrender/objectpaging.cpp:55-75`):
##   STAT, DOOR, ACTI            → always eligible (world architecture + interaction markers)
##   CONT                        → eligible only at size_level == 0 (1×1 chunks)
##   LIGH, NPC_, CREA, inventory → never eligible (lights own their tier;
##                                 actors + inventory aren't static cell geometry)
##
## `size_level` matches OpenMW's `far = size >= 2` / `!far` distinction: at
## size_level=0 (near 1×1 chunks in §4), small per-cell clutter like barrels
## and crates is worth the draw-call cost; at size_level >= 1 those types
## project sub-pixel and add overhead without visual gain. Phase 4 wires
## the real `size_level` through; until then all paging work is size_level=0
## so the table is effectively `static/door/acti/cont → keep`.
##
## Pure static — unit-testable without a merger instance.
static func _type_eligible(type_name: String, size_level: int) -> bool:
	match type_name:
		"static", "door", "activator":
			return true
		"container":
			# size_level == 0 → near-chunk tier → keep. Phase 4 enables levels 1/2.
			return size_level == 0
		_:
			# Everything else: light (own tier), npc/creature (dynamic, not paged),
			# weapon/armor/clothing/book/misc (small inventory items).
			return false


## Phase 2 — projected-size test (OpenMW ObjectPaging §2.2).
## Returns true if the ref should be kept (projected screen-size above threshold).
##
## Contract (matches `inspos/openmw/apps/openmw/mwrender/objectpaging.cpp:793-799`):
##   keep iff  mesh_radius² × scale² >= dist² × min_size²
##
## All values squared by caller. Pure static — unit-testable in isolation.
##
## **Divergence from OpenMW:** `mesh_radius_sq == 0` returns `true` (conservative
## keep) instead of OpenMW's implicit skip (`0 < dist²×min²` evaluates true →
## continue). Rationale: Phase 2 callers guard this case at the call site
## (`mesh_radius_sq > 0.0` check before invoking) — this helper stays safe to
## call with degenerate input and lets Phase 3's type filter handle real
## zero-AABB cases. Caller is responsible for the guard if behaviour must
## match OpenMW exactly.
static func _is_size_worthy(mesh_radius_sq: float, scale_f: float, dist_sq: float, min_size_sq: float) -> bool:
	if mesh_radius_sq <= 0.0 or dist_sq <= 0.0:
		return true
	return mesh_radius_sq * scale_f * scale_f >= dist_sq * min_size_sq


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

	# Phase 2 SizeCache
	_size_cache_mutex.lock()
	_size_cache.clear()
	_size_cache_mutex.unlock()

#endregion


#region Merge Request Pipeline

## Collect merge inputs and submit to background worker.
## Single-pass ESM iteration: collects inputs AND counts mid-worthy refs in one loop.
## Fast path: reads mesh data from StaticObjectRenderer's already-registered MeshTypes.
## Slow path: loads prototype from model cache for models not yet registered (deep HLOD cells).
## Called max MERGES_PER_FRAME times per frame via process_merge_queue().
##
## Phase 2: refs are filtered by a projected-size test using mesh bounding radius,
## per-ref scale, and distance to camera — replacing the keyword-substring
## `is_mid_worthy` gate. See `_is_size_worthy()` + `docs/audit/OBJECT_PAGING_PLAN.md` §2.2.
func _request_merge(grid: Vector2i, camera_cell: Vector2i, camera_world_pos: Vector3) -> void:
	if not _static_renderer or not _bg_processor:
		return

	var cell_record: Variant = ESMManager.get_exterior_cell(grid.x, grid.y)
	if not cell_record:
		return

	var min_size_sq: float = DU.PAGING_MIN_SIZE_SQ

	# Single-pass: collect inputs AND count simultaneously
	var inputs: Array = []
	var refs_skipped := 0
	var refs_size_rejected := 0
	var refs_type_rejected := 0
	var size_cache_hits := 0

	# Phase 3 — fixed size_level=0 until Phase 4 ships adaptive chunks.
	# Passed through to `_type_eligible` so the table encodes tier rules
	# once and doesn't need rewiring when chunks grow.
	var size_level: int = 0

	for ref in cell_record.references:
		if ref.is_deleted:
			continue

		var record_type: Array = [""]
		var base_record: Variant = ESMManager.get_any_record(str(ref.ref_id), record_type)
		if not base_record:
			continue

		# Phase 3 — type filter (OpenMW ObjectPaging §2.4, objectpaging.cpp:55-75).
		# Pre-rejects record types that should never page (light, npc, creature,
		# misc items) and size-aware types (container only at size_level=0).
		# Cheap switch before the AABB dict lookup.
		var type_name: String = record_type[0] if record_type.size() > 0 else ""
		if not _type_eligible(type_name, size_level):
			refs_type_rejected += 1
			continue

		var model_path: String = _get_model_path(base_record)
		if model_path.is_empty():
			continue

		# Compute ref transform once — reused below + passed to worker if accepted.
		var pos: Vector3 = CS.vector_to_godot(ref.position)
		var scale: Vector3 = CS.scale_to_godot(ref.scale)
		var basis: Basis = CS.esm_rotation_to_godot_basis(ref.rotation)
		basis = basis.scaled(scale)
		var ref_transform := Transform3D(basis, pos)

		# Phase 2 filter — projected-size test with SizeCache short-circuit.
		#
		# Flow:
		#   1. Check SizeCache for previously-stored `rad² × scale²` under this ref_num.
		#   2. If hit AND still below `dist² × minSize²` at current camera dist → skip
		#      without touching the AABB dict (the actual short-circuit). Cached
		#      `rad² × scale²` is mesh-invariant — only dist changes per-frame.
		#   3. If hit AND now above threshold → evict cache entry, fall through to
		#      full path (camera moved close enough; ref is a merge candidate again).
		#   4. If miss → AABB lookup, test, cache on rejection.
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
				# Still rejected — no AABB lookup, no prototype load.
				refs_size_rejected += 1
				size_cache_hits += 1
				continue
			# Moved into range — evict and fall through to full path.
			_size_cache_mutex.lock()
			_size_cache.erase(cache_key)
			_size_cache_mutex.unlock()

		# Full path: AABB lookup + test. Runs on cold refs and on refs that
		# just moved into projected-size range.
		var aabb: AABB = _static_renderer.get_mesh_aabb(mesh_type_name)
		var mesh_radius_sq: float = 0.0
		if aabb.size != Vector3.ZERO:
			# Bounding radius² = (diagonal/2)² = size.length_squared() * 0.25
			mesh_radius_sq = aabb.size.length_squared() * 0.25

		if mesh_radius_sq > 0.0:
			var rs2: float = mesh_radius_sq * scale_f * scale_f
			if rs2 < size_threshold:
				_size_cache_mutex.lock()
				_size_cache[cache_key] = rs2
				_size_cache_mutex.unlock()
				refs_size_rejected += 1
				continue

		# Look up in static renderer's MeshType registry (fast path)
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

		# Snapshot sub-mesh data for worker thread
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
##
## Phase 3b: passes `size_level = 0` explicitly — current HLOD merger operates
## at fixed 1-cell granularity. Phase 4 adaptive chunks thread the real
## size_level through when they ship.
func _merge_cell_worker(grid: Vector2i, inputs: Array, cell_origin: Vector3) -> Dictionary:
	var mesh := Kernel.merge_refs(inputs, cell_origin, 0)
	if not mesh:
		return {"grid": grid, "mesh": null, "bytes": 0}

	var bytes := Kernel.estimate_mesh_bytes(mesh)

	# Post to completion queue (thread-safe via mutex)
	_completed_mutex.lock()
	_completed_queue.append({"grid": grid, "mesh": mesh, "bytes": bytes})
	_completed_mutex.unlock()

	return {"grid": grid, "bytes": bytes}

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

#endregion
