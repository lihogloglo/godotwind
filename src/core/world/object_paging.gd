## ObjectPaging — OpenMW-style distance-adaptive chunk paging
##
## Phase 4b of docs/audit/OBJECT_PAGING_PLAN.md §11: evolves from a single-tier
## HLOD cell merger (phases 1-3) into a multi-tier adaptive pager. Chunks are
## keyed by `Vector3i(center_cell.x, center_cell.y, size_level)` and sized
## adaptively per the plan §4 table:
##
##     size_level 0 (1×1 cells) — [150, 300)m — reserved below the current
##                                 visual floor; MID statics own this band.
##     size_level 1 (2×2 cells) — band [300, 600)m — far-MID
##     size_level 2 (4×4 cells) — band [600, 1000)m — HLOD
##
## `update_for_camera` runs the top-down anti-overlap walk from plan §4.3:
## larger tiers claim their cells first; smaller tiers can't sub-divide an
## accepted larger chunk. Strict half-open bands for NEW chunk decisions;
## Phase 4c hysteresis (plan §4.4): already-active chunks are pre-populated
## into the desired set — and their sub-cells marked covered — as long as
## their chunk-center distance is within `[band_start - PAGING_HYSTERESIS,
## band_end + PAGING_HYSTERESIS)`. Margin is NOT baked into the walk's
## distance test (fuzzes band edges); it applies only to retention.
##
## Pipeline (per chunk):
##   1. Chunk enters a tier band → main thread iterates the size×size covered
##      cells, collects refs via ESMManager, runs type filter + size filter +
##      SizeCache.
##   2. Background worker: ObjectPagingKernel.merge_refs() transforms verts,
##      runs cost-benefit, groups by material, concatenates raw chunk geometry.
##   3. Main thread: creates RS instance at chunk center world position with
##      tier-specific visibility_range; adds to LRU cache.
##
## Thread safety:
##   - Main thread: CellRecord iteration, MeshType lookup/registration, RS create.
##   - Worker thread: ObjectPagingKernel.merge_refs() reads ArrayMesh surfaces
##     read-only, creates isolated ImporterMesh.
##   - SizeCache guarded by mutex (written from main, read from main; mutex is
##     future-proofing for worker reads if that path ever ships).
class_name ObjectPaging
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
## Lowered from 15 to 5: Morrowind near-coast cells can be sparse; 5 is still
## enough for the cost-benefit analysis to find shared materials.
const MIN_REFS_TO_MERGE: int = 5

## Merge-queue stagger budget (main-thread work per frame).
const MERGES_PER_FRAME: int = 2
const MERGE_QUEUE_BUDGET_USEC: int = 2500
const MERGE_QUEUE_SOFT_LIMIT_USEC: int = 2200

## Completion publish budget. Runtime HLOD publication must stay bounded; LOD
## generation for proxy chunks belongs in an offline/precomputed path, not in
## traversal-time publish.
const COMPLETIONS_PER_FRAME: int = 1
const COMPLETION_BUDGET_USEC: int = 2500
const RUNTIME_GENERATE_LODS: bool = false
const MAX_RUNTIME_CHUNK_SURFACES: int = 16

## visibility_range fade margins (same on both sides of a tier handoff).
const TIER_FADE_MARGIN: float = 20.0

## Runtime visibility owner floor. HLOD should render at the canonical
## MID->HLOD handoff (300m). MID remains the fallback only for buckets that are
## not covered by active HLOD chunks; NativeStreamingManager applies those
## bucket-specific MID caps from this merger's coverage manifest.
const DEFAULT_VISUAL_BEGIN_FLOOR: float = DU.HLOD_START

## Phase 4d — teleport warmup (plan §11 Phase 3 / session log §7).
## A camera translation larger than this threshold between consecutive
## `update_for_camera` calls triggers a warmup pass: the merger pre-loads
## `.res` prototypes for the incoming chunk ring over several frames BEFORE
## submitting any merges, so the merge burst doesn't stall the main thread
## on cold ResourceLoader I/O inside merge preparation.
const TELEPORT_THRESHOLD: float = 500.0

## Max prototype loads per `process_merge_queue` call while warmup is active.
## Tuned so a typical teleport ring (~40-60 unique architectural mesh types)
## drains in 3-4 frames. Each load is `.res` deserialize + register — low
## single-digit ms each.
const WARMUP_LOADS_PER_FRAME: int = 15
const WARMUP_BUDGET_USEC: int = 1500

## Runtime HLOD must own distant model geometry independently of whichever
## prototypes the NEAR/MID path has already touched. Use the existing cache-
## backed, frame-budgeted warmup path so missing submeshes can be registered
## before chunk input collection continues.
const RUNTIME_PROTOTYPE_WARMUP: bool = true

## Visual-owner HLOD chunks cannot reject every eligible ref purely because the
## source mesh is unique. Once refs have passed type, size, surface, and whole-
## bucket filters, include them in the chunk proxy. Proxy splitting/material
## reduction remains the production optimization path after correctness.
const RUNTIME_FORCE_MERGE_ELIGIBLE_REFS: bool = true


#region Internal Data Classes

## Per-chunk state for an active merged region.
## `key.xy` = aligned center_cell, `key.z` = size_level (0/1/2).
class PagingChunkData:
	var key: Vector3i
	var instance_rid: RID
	var mesh: ArrayMesh  ## Strong ref — prevents GC
	var surface_count: int = 0
	var material_count: int = 0
	var vertex_count: int = 0
	var index_count: int = 0
	var estimated_bytes: int = 0
	var covered_cells: Array[Vector2i] = []
	var source_ref_nums: Dictionary = {}
	var source_bucket_counts: Dictionary = {}
	var coverage_complete: bool = false
	var refs_accepted: int = 0
	var refs_skipped: int = 0
	var refs_size_rejected: int = 0
	var refs_surface_rejected: int = 0
	var refs_type_rejected: int = 0


class MergePrepState:
	var key: Vector3i
	var size_level: int = 0
	var size: int = 1
	var center_cell: Vector2i
	var camera_world_pos: Vector3
	var inputs: Array = []
	var covered_cells: Array[Vector2i] = []
	var source_ref_nums: Dictionary = {}
	var source_bucket_counts: Dictionary = {}
	var bucket_total_counts: Dictionary = {}
	var surface_estimate: int = 0
	var refs_skipped: int = 0
	var refs_size_rejected: int = 0
	var refs_surface_rejected: int = 0
	var refs_type_rejected: int = 0
	var refs_partial_bucket_rejected: int = 0
	var size_cache_hits: int = 0
	var cx: int = 0
	var cy: int = 0
	var refs: Array = []
	var ref_index: int = 0
	var refs_loaded: bool = false

#endregion


#region State

## Master toggle.
## Phase 4 (2026-04-17) — implemented as an opt-in runtime path while chunk
## coverage and publish costs are verified:
## HLOD-on = MID fallback 0-500m, covered MID buckets cap at 300m, HLOD visible
## 300-1000m, and FAR remains the 500m fallback until page coverage is exact.
## HLOD-off parks only merged chunks; MID remains at DU.MID_END.
## Toggle at runtime via console: `hlod_enable` / `hlod_disable`.
var enabled: bool = true

## SubsystemToggles "hlod" flag state. Persists across chunk creation so
## chunks merged AFTER a `toggle hlod off` don't pop back as visible.
## Mirrors the same pattern used by StaticObjectRenderer._globally_visible.
var _globally_visible: bool = true
var _visual_begin_floor: float = DEFAULT_VISUAL_BEGIN_FLOOR

## Scenario RID for creating RS instances
var _scenario: RID = RID()

## Reference to the static object renderer (for MeshType lookups)
var _static_renderer: StaticObjectRendererScript = null

## Reference to background processor (for submitting merge tasks)
var _bg_processor: BackgroundProcessor = null

## Model cache directory (for loading prototypes not yet in StaticObjectRenderer)
var _models_dir: String = ""

## Active paging chunks with RS instances. Keyed by Vector3i = (center_cell.x, center_cell.y, size_level).
var _active_chunks: Dictionary = {}  # Vector3i -> PagingChunkData

## Pending merge tasks (submitted to background processor)
var _pending_merges: Dictionary = {}  # Vector3i -> int (task_id)
var _task_to_key: Dictionary = {}  # int (task_id) -> Vector3i
var _task_to_generation: Dictionary = {}  # int (task_id) -> int
var _chunk_generations: Dictionary = {}  # Vector3i -> int
var _next_generation: int = 1

## Desired chunks proven not worth or not possible to merge in the current
## renderer/cache state. MID/FAR fallback owns their pixels; this prevents
## repeated ESM scans for sparse rings.
var _negative_chunks: Dictionary = {}  # Vector3i -> true

## Chunk merge input collection currently being prepared across frames.
var _prep_queue: Array[MergePrepState] = []
var _preparing_chunks: Dictionary = {}  # Vector3i -> MergePrepState

## Merge queue — chunks waiting for main-thread data collection + worker submission.
## Staggered: max MERGES_PER_FRAME processed per frame to avoid main-thread stalls.
var _merge_queue: Array[Vector3i] = []
var _camera_cell_cached: Vector2i = Vector2i.ZERO
var _camera_world_pos_cached: Vector3 = Vector3.ZERO

## Phase 4d — teleport warmup state.
## `_last_camera_world_pos` is the camera position from the previous
## `update_for_camera` call, used to detect a jump > TELEPORT_THRESHOLD.
## `Vector3.INF` sentinel = no prior call (first-ever frame, never triggers).
var _last_camera_world_pos: Vector3 = Vector3.INF

## Pending prototype-load paths to pre-register. Drained by `process_merge_queue`
## before any merges are submitted. Main-thread only.
var _warmup_queue: Array[String] = []

## Dedup guard — mesh_type_names we've already enqueued in the current warmup
## burst. Cleared when the queue fully drains (or when cleanup() runs).
var _warmup_dispatched: Dictionary = {}

## Mesh types whose cache resource could not be staged this session. Prevents
## missing/corrupt cache entries from requeueing the same HLOD chunk forever.
var _warmup_failed: Dictionary = {}

## Phase 2 — SizeCache for the projected-size filter (OpenMW ObjectPaging §2.2).
## Key = ref_num (int). Value = radius²×scale² at last rejection. Mesh-invariant
## value — re-tested against current dist²×min_size² without re-reading AABB.
var _size_cache: Dictionary = {}  # int (ref_num) -> float
var _size_cache_mutex: Mutex = Mutex.new()

## Completed merge results waiting for main-thread RS instance creation.
var _completed_queue: Array = []  # Array of {key: Vector3i, generation: int, mesh: ArrayMesh, bytes: int}
var _completed_mutex: Mutex = Mutex.new()

## LRU mesh cache
var _mesh_cache: Dictionary = {}  # Vector3i -> ArrayMesh
var _mesh_sizes: Dictionary = {}  # Vector3i -> int (bytes)
var _mesh_manifests: Dictionary = {}  # Vector3i -> Dictionary
var _lru_order: Array[Vector3i] = []  # Oldest first
var _cache_used_bytes: int = 0
var _pending_manifests: Dictionary = {}  # Vector3i -> Dictionary
var _coverage_revision: int = 0

## Stats
var _stats: Dictionary = {
	"active_cells": 0,         # kept name for caller compat; counts all active chunks across tiers
	"pending_merges": 0,
	"cache_entries": 0,
	"cache_bytes": 0,
	"total_merges_completed": 0,
	"total_refs_skipped": 0,
	"refs_size_rejected": 0,   # Phase 2 — below projected-size threshold
	"refs_surface_rejected": 0,
	"refs_partial_bucket_rejected": 0,
	"size_cache_hits": 0,      # Phase 2 — short-circuit AABB lookups
	"size_cache_size": 0,      # Phase 2 — SizeCache entry count
	"refs_type_rejected": 0,   # Phase 3a — rejected by record-type table
	"chunks_tier_0": 0,        # Phase 4 — per-tier active chunk counts
	"chunks_tier_1": 0,
	"chunks_tier_2": 0,
	"total_chunk_surfaces": 0,
	"total_chunk_materials": 0,
	"total_chunk_vertices": 0,
	"total_chunk_indices": 0,
	"max_chunk_surfaces": 0,
	"max_chunk_materials": 0,
	"max_chunk_vertices": 0,
	"max_chunk_indices": 0,
	"stale_completions_discarded": 0,
	"surface_cap_rejections": 0,
	"merge_queue_last_usec": 0,
	"completion_last_usec": 0,
	"preparing_chunks": 0,
	"negative_chunks": 0,
	"desired_chunks": 0,
	"merge_queue_size": 0,
	"active_visual_chunks": 0,
	"visual_begin_floor": DEFAULT_VISUAL_BEGIN_FLOOR,
	"mid_hlod_overlap_chunks": 0,
	"nonvisual_chunks_suppressed": 0,
	"active_covered_refs": 0,
	"active_covered_cells": 0,
	"active_complete_coverage_chunks": 0,
	"active_incomplete_coverage_chunks": 0,
	"coverage_revision": 0,
	"warmup_queue_size": 0,    # Phase 4d — prototype pre-load queue depth
	"total_teleports": 0,      # Phase 4d — cumulative teleport events detected
	"runtime_lod_generation_enabled": RUNTIME_GENERATE_LODS,
	"runtime_force_merge_eligible_refs": RUNTIME_FORCE_MERGE_ELIGIBLE_REFS,
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
	# Dual-purpose SubsystemToggles gate: when HLOD is toggled off, stop
	# queuing new chunk merges entirely — not just hide the output. Lets the
	# toggle measure "HLOD streaming + render" vs "HLOD dark" cleanly.
	if not _globally_visible:
		return 0
	_camera_cell_cached = camera_cell
	if camera_world_pos == Vector3.INF:
		# Legacy fallback — approximate with cell center. Phase 2+ callers pass
		# the real camera world position.
		_camera_world_pos_cached = DU.cell_to_world_center(camera_cell)
	else:
		_camera_world_pos_cached = camera_world_pos

	# Phase 4d — teleport detection. A jump beyond TELEPORT_THRESHOLD between
	# consecutive calls means cold prototypes are about to be slammed onto the
	# main thread inside merge preparation. Prime the warmup queue so
	# process_merge_queue pre-loads them over the next few frames instead.
	var is_teleport: bool = _is_teleport(_last_camera_world_pos, _camera_world_pos_cached)
	if is_teleport:
		_stats["total_teleports"] += 1
	_last_camera_world_pos = _camera_world_pos_cached

	# Plan §4.3 — top-down anti-overlap walk. Larger tiers claim their cells
	# first; smaller tiers skip any chunk whose 1×1 sub-cells are covered.
	var desired_chunks: Dictionary = _compute_desired_chunks(camera_cell, _camera_world_pos_cached)
	_stats["desired_chunks"] = desired_chunks.size()
	Log.debug("streaming", "HLOD update_for_camera: %d desired chunks, %d active, %d pending, %d queued (cell=%s)" % [
		desired_chunks.size(), _active_chunks.size(), _pending_merges.size(), _merge_queue.size(), camera_cell])

	# Phase 4d — on teleport, enqueue unregistered prototypes for the new ring.
	if is_teleport:
		_prime_warmup_queue(desired_chunks)

	var changed := 0

	# Queue new chunks (stagger via process_merge_queue)
	for key: Vector3i in desired_chunks:
		if key in _active_chunks or key in _pending_merges or key in _chunk_generations or key in _negative_chunks or key in _preparing_chunks:
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
		_task_to_generation.erase(tid)
		_pending_merges.erase(key)
		_chunk_generations.erase(key)
		_negative_chunks.erase(key)

	# Drop in-progress preparations that left the desired set.
	_prep_queue = _prep_queue.filter(func(state: MergePrepState) -> bool:
		if state.key in desired_chunks:
			return true
		_preparing_chunks.erase(state.key)
		return false
	)

	# Invalidate completed-but-not-yet-published requests that left desired set.
	var generations_to_drop: Array[Vector3i] = []
	for key: Vector3i in _chunk_generations:
		if key not in desired_chunks and key not in _active_chunks:
			generations_to_drop.append(key)
	for key: Vector3i in generations_to_drop:
		_chunk_generations.erase(key)

	# Drop negative cache entries after the chunk leaves the desired ring so a
	# later camera pass can re-evaluate against a changed renderer/cache state.
	var negatives_to_drop: Array[Vector3i] = []
	for key: Vector3i in _negative_chunks:
		if key not in desired_chunks:
			negatives_to_drop.append(key)
	for key: Vector3i in negatives_to_drop:
		_negative_chunks.erase(key)

	# Remove queued chunks that left desired set
	_merge_queue = _merge_queue.filter(func(k: Vector3i) -> bool: return k in desired_chunks)

	_refresh_stats()
	return changed


## Process staggered merge queue — max MERGES_PER_FRAME chunks per call.
## Each call does main-thread data collection + submits to worker.
## Call once per frame from streaming manager (BEFORE process_completions).
##
## Phase 4d — when the warmup queue is non-empty (post-teleport), we drain up
## to WARMUP_LOADS_PER_FRAME prototype loads and then return WITHOUT advancing
## the merge queue. Merges resume on the frame after warmup completes. The
## reason for the hard split: prototype loading + merge submission on the
## same frame was the pre-Phase-4d pathology — warmup is exactly the "don't
## do both at once" budget partitioner.
func process_merge_queue() -> void:
	var start_usec := Time.get_ticks_usec()
	if not enabled:
		_stats["merge_queue_last_usec"] = 0
		return
	# Dual-purpose SubsystemToggles gate: stop draining merge queue when
	# HLOD is toggled off. In-flight merges already dispatched to the BG
	# worker will still complete; their RS instances get hidden by the
	# `_globally_visible` check in `_create_rs_instance`.
	if not _globally_visible:
		_stats["merge_queue_last_usec"] = 0
		return

	# Phase 4d — warmup drain has priority over merges.
	if not _warmup_queue.is_empty():
		_drain_warmup_queue()
		_stats["merge_queue_last_usec"] = Time.get_ticks_usec() - start_usec
		return

	if _merge_queue.is_empty():
		if not _prep_queue.is_empty():
			while not _prep_queue.is_empty():
				var prep_status := _process_merge_prepare(_prep_queue[0], start_usec)
				if prep_status == "done":
					var done_state: MergePrepState = _prep_queue[0]
					_prep_queue.remove_at(0)
					_preparing_chunks.erase(done_state.key)
					continue
				break
			_stats["merge_queue_last_usec"] = Time.get_ticks_usec() - start_usec
			return
		_stats["merge_queue_last_usec"] = 0
		return

	var budget := MERGES_PER_FRAME
	while Time.get_ticks_usec() - start_usec < MERGE_QUEUE_SOFT_LIMIT_USEC:
		while not _prep_queue.is_empty():
			var prep_status := _process_merge_prepare(_prep_queue[0], start_usec)
			if prep_status == "done":
				var done_state: MergePrepState = _prep_queue[0]
				_prep_queue.remove_at(0)
				_preparing_chunks.erase(done_state.key)
				continue
			break
		if not _warmup_queue.is_empty() or (not _prep_queue.is_empty() and Time.get_ticks_usec() - start_usec >= MERGE_QUEUE_SOFT_LIMIT_USEC):
			break
		if budget <= 0 or _merge_queue.is_empty():
			break
		if Time.get_ticks_usec() - start_usec >= MERGE_QUEUE_SOFT_LIMIT_USEC:
			break
		var key: Vector3i = _merge_queue[0]
		_merge_queue.remove_at(0)
		# Skip if already active or pending (could have been cached/loaded since queued)
		if key in _active_chunks or key in _pending_merges or key in _chunk_generations or key in _negative_chunks or key in _preparing_chunks:
			continue
		_start_chunk_merge_prepare(key, _camera_world_pos_cached)
		budget -= 1
		if not _warmup_queue.is_empty():
			break
	_stats["merge_queue_last_usec"] = Time.get_ticks_usec() - start_usec


## Process completed merge results on main thread. Creates RS instances.
## Call once per frame from streaming manager.
## Returns number of chunks completed.
func process_completions() -> int:
	var start_usec := Time.get_ticks_usec()
	if not enabled:
		_completed_mutex.lock()
		_stats["stale_completions_discarded"] += _completed_queue.size()
		_completed_queue.clear()
		_completed_mutex.unlock()
		_stats["completion_last_usec"] = 0
		return 0

	_completed_mutex.lock()
	if _completed_queue.is_empty():
		_completed_mutex.unlock()
		_stats["completion_last_usec"] = 0
		return 0

	if not _globally_visible:
		_stats["stale_completions_discarded"] += _completed_queue.size()
		_completed_queue.clear()
		_completed_mutex.unlock()
		_stats["completion_last_usec"] = 0
		return 0

	var queue: Array = []
	var budget := COMPLETIONS_PER_FRAME
	while budget > 0 and not _completed_queue.is_empty():
		if Time.get_ticks_usec() - start_usec >= COMPLETION_BUDGET_USEC:
			break
		queue.append(_completed_queue.pop_back())
		budget -= 1
	_completed_mutex.unlock()

	var count := 0
	for entry: Dictionary in queue:
		var key: Vector3i = entry["key"]
		var generation: int = entry.get("generation", 0)
		var mesh: ArrayMesh = entry["mesh"]
		var bytes: int = entry["bytes"]

		# Chunk may have left range, been cancelled, or been superseded while
		# the worker was in progress. Reject before LOD generation or RS publish.
		if not _is_current_generation(key, generation) or key in _active_chunks:
			_stats["stale_completions_discarded"] += 1
			_pending_manifests.erase(key)
			continue

		if mesh == null or mesh.get_surface_count() > MAX_RUNTIME_CHUNK_SURFACES:
			_negative_chunks[key] = true
			_stats["surface_cap_rejections"] = int(_stats.get("surface_cap_rejections", 0)) + 1
			_pending_manifests.erase(key)
			_chunk_generations.erase(key)
			continue

		# Optional runtime LOD finalization is disabled in the hot path. If it
		# returns, it must stay on the main thread because ImporterMesh +
		# RenderingServer-backed mesh publication are not worker-safe.
		if RUNTIME_GENERATE_LODS:
			var lod_mesh := Kernel.generate_lods(mesh)
			if lod_mesh:
				mesh = lod_mesh
			mesh.set_meta("has_lod_chain", true)
		else:
			mesh.set_meta("has_lod_chain", false)

		_cache_evict_to_fit(bytes)
		_mesh_cache[key] = mesh
		_mesh_sizes[key] = bytes
		_mesh_manifests[key] = _pending_manifests.get(key, {})
		_pending_manifests.erase(key)
		_lru_order.append(key)
		_cache_used_bytes += bytes

		if _create_rs_instance(key, mesh, bytes):
			count += 1

		_chunk_generations.erase(key)
		_stats["total_merges_completed"] += 1

	_refresh_stats()
	_stats["completion_last_usec"] = Time.get_ticks_usec() - start_usec
	return count


## Get stats for debug/profiling
func get_stats() -> Dictionary:
	_refresh_stats()
	return _stats.duplicate()


func get_active_coverage_manifest() -> Dictionary:
	var source_ref_nums: Dictionary = {}
	var source_bucket_counts: Dictionary = {}
	var covered_cells: Dictionary = {}
	var complete_chunks := 0
	var incomplete_chunks := 0
	for key: Vector3i in _active_chunks:
		var data: PagingChunkData = _active_chunks[key]
		if not _chunk_has_visual_range(key):
			continue
		if data.coverage_complete:
			complete_chunks += 1
		else:
			incomplete_chunks += 1
		for ref_num: Variant in data.source_ref_nums.keys():
			source_ref_nums[int(ref_num)] = true
		for bucket_key: Variant in data.source_bucket_counts.keys():
			var key_string := str(bucket_key)
			source_bucket_counts[key_string] = int(source_bucket_counts.get(key_string, 0)) + int(data.source_bucket_counts[bucket_key])
		for cell: Vector2i in data.covered_cells:
			covered_cells[cell] = true
	return {
		"source_ref_nums": source_ref_nums,
		"source_bucket_counts": source_bucket_counts,
		"covered_cells": covered_cells,
		"active_covered_refs": source_ref_nums.size(),
		"active_covered_cells": covered_cells.size(),
		"active_complete_coverage_chunks": complete_chunks,
		"active_incomplete_coverage_chunks": incomplete_chunks,
		"coverage_revision": _coverage_revision,
	}


## Dual-purpose SubsystemToggles handler: hide output AND stop streaming work.
## Persists via `_globally_visible` so:
##  - chunks merged AFTER this call respect visibility (see `_create_rs_instance`)
##  - `update_for_camera` + `process_merge_queue` early-return while disabled
##  - queued-but-not-yet-dispatched merges are flushed to avoid stale backlog
func set_all_visible(visible: bool) -> void:
	_globally_visible = visible
	for key: Vector3i in _active_chunks:
		var data: PagingChunkData = _active_chunks[key]
		if data.instance_rid.is_valid():
			RenderingServer.instance_set_visible(data.instance_rid, visible)
	if not visible:
		if _bg_processor:
			for key: Vector3i in _pending_merges:
				_bg_processor.cancel_task(_pending_merges[key])
		_merge_queue.clear()
		_warmup_queue.clear()
		_warmup_dispatched.clear()
		_warmup_failed.clear()
		_invalidate_all_generations()
		_negative_chunks.clear()
		_prep_queue.clear()
		_preparing_chunks.clear()
		_pending_merges.clear()
		_pending_manifests.clear()
		_task_to_key.clear()
		_task_to_generation.clear()
		_completed_mutex.lock()
		_stats["stale_completions_discarded"] += _completed_queue.size()
		_completed_queue.clear()
		_completed_mutex.unlock()
		_coverage_revision += 1


func set_visual_begin_floor(distance_m: float) -> void:
	_visual_begin_floor = maxf(0.0, distance_m)
	for key: Vector3i in _active_chunks.keys():
		_apply_chunk_visibility_range(key)
	_refresh_stats()


func cleanup(disconnect_signals: bool = true) -> void:
	# Cancel pending merges
	if _bg_processor:
		for key: Vector3i in _pending_merges:
			_bg_processor.cancel_task(_pending_merges[key])
		if disconnect_signals:
			if _bg_processor.task_completed.is_connected(_on_task_completed):
				_bg_processor.task_completed.disconnect(_on_task_completed)
			if _bg_processor.task_failed.is_connected(_on_task_failed):
				_bg_processor.task_failed.disconnect(_on_task_failed)
	_pending_merges.clear()
	_pending_manifests.clear()
	_task_to_key.clear()
	_task_to_generation.clear()
	_invalidate_all_generations()
	_negative_chunks.clear()
	_prep_queue.clear()
	_preparing_chunks.clear()
	_merge_queue.clear()

	# Free RS instances
	for key: Vector3i in _active_chunks:
		var data: PagingChunkData = _active_chunks[key]
		if data.instance_rid.is_valid():
			RenderingServer.free_rid(data.instance_rid)
	_active_chunks.clear()
	_coverage_revision += 1

	# Clear caches
	_mesh_cache.clear()
	_mesh_sizes.clear()
	_mesh_manifests.clear()
	_lru_order.clear()
	_cache_used_bytes = 0
	_completed_mutex.lock()
	_completed_queue.clear()
	_completed_mutex.unlock()

	# Phase 2 SizeCache
	_size_cache_mutex.lock()
	_size_cache.clear()
	_size_cache_mutex.unlock()

	# Phase 4d warmup state
	_warmup_queue.clear()
	_warmup_dispatched.clear()
	_warmup_failed.clear()
	_last_camera_world_pos = Vector3.INF

#endregion


#region Phase 4d — teleport warmup (plan §11 Phase 3 / session log §7)

## Pure teleport predicate. `Vector3.INF` sentinel (first-ever frame) is
## never a teleport — otherwise the merger would warmup on its initial
## enable even when the camera hasn't moved. Threshold kept at module
## constant scope so bench tuning can override without touching the helper.
static func _is_teleport(prev_pos: Vector3, curr_pos: Vector3) -> bool:
	if prev_pos == Vector3.INF:
		return false
	return prev_pos.distance_to(curr_pos) > TELEPORT_THRESHOLD


## Populate the warmup queue with unregistered prototype paths for every
## desired chunk. Skips paths already enqueued in the current burst. Called
## exactly once per teleport event, from `update_for_camera`.
func _prime_warmup_queue(desired_chunks: Dictionary) -> void:
	if not RUNTIME_PROTOTYPE_WARMUP:
		return
	if not _static_renderer:
		return
	for key: Vector3i in desired_chunks:
		var size: int = 1 << key.z
		for cy in range(size):
			for cx in range(size):
				var cell_grid := Vector2i(key.x + cx, key.y + cy)
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
					if not _type_eligible(type_name, key.z):
						continue
					var model_path: String = _get_model_path(base_record)
					if model_path.is_empty():
						continue
					_queue_warmup_model(model_path)


func _queue_warmup_model(model_path: String) -> bool:
	if not RUNTIME_PROTOTYPE_WARMUP:
		return false
	if model_path.is_empty() or not _static_renderer:
		return false
	var mesh_type_name := model_path.to_lower().replace("/", "\\")
	if mesh_type_name in _warmup_failed:
		return false
	if mesh_type_name in _warmup_dispatched:
		return true
	if not _static_renderer.get_sub_meshes(mesh_type_name).is_empty():
		return false
	if not _model_cache_scene_exists(model_path):
		_warmup_failed[mesh_type_name] = true
		return false
	_warmup_dispatched[mesh_type_name] = true
	_warmup_queue.append(model_path)
	return true


## Drain up to WARMUP_LOADS_PER_FRAME prototypes from the warmup queue.
## Each load = ResourceLoader `.res` fetch + StaticObjectRenderer registration.
## When the queue fully drains, `_warmup_dispatched` clears so a future
## teleport gets a fresh dedup set.
func _drain_warmup_queue() -> void:
	if not _static_renderer:
		_warmup_queue.clear()
		_warmup_dispatched.clear()
		return
	var start_usec := Time.get_ticks_usec()
	var budget := WARMUP_LOADS_PER_FRAME
	while budget > 0 and not _warmup_queue.is_empty():
		if Time.get_ticks_usec() - start_usec >= WARMUP_BUDGET_USEC:
			break
		# pop_back is O(1); order doesn't matter — we pre-load everything.
		var model_path: String = _warmup_queue.pop_back()
		var mesh_type_name := model_path.to_lower().replace("/", "\\")
		# Re-check registration — another path (e.g. a slow-path merge for an
		# active chunk on a previous frame) may have already registered it.
		if not _static_renderer.get_sub_meshes(mesh_type_name).is_empty():
			budget -= 1
			continue
		var prototype := _load_prototype_from_cache(model_path)
		if prototype:
			_static_renderer.register_from_prototype(mesh_type_name, prototype)
			prototype.free()
		else:
			_warmup_failed[mesh_type_name] = true
		budget -= 1
	if _warmup_queue.is_empty():
		_warmup_dispatched.clear()

#endregion


#region Phase 4b — Top-down anti-overlap walk (plan §4.3)

## Compute desired chunks across all three tiers using the top-down walk.
## Returns Dictionary[Vector3i -> true] of chunks that should be active.
## Main-thread. Bounded to ~147 chunk candidates per call (plan §4.5).
##
## Phase 4c — hysteresis (plan §4.4). Active chunks are pre-populated into
## `desired` (and pre-mark `covered_cells`) as long as their chunk-center
## distance lies in the retention window `[band_start - margin, band_end +
## margin)`. This keeps the walk's strict-band arithmetic unambiguous while
## letting chunks "stick" through small camera motions at tier boundaries.
func _compute_desired_chunks(camera_cell: Vector2i, camera_world_pos: Vector3) -> Dictionary:
	var desired: Dictionary = {}
	var covered_cells: Dictionary = {}  # Vector2i -> true (1×1 cells claimed by larger chunks)
	var camera_xz := Vector2(camera_world_pos.x, camera_world_pos.z)

	# Phase 4c — retention pass. Runs BEFORE the strict-band walk so retained
	# chunks block re-tier decisions on their sub-cells. Active chunks whose
	# distance sits outside the expanded window are NOT retained; the walk
	# decides their fate (and the post-walk diff will unload them).
	for active_key: Vector3i in _active_chunks:
		if not _is_within_retention(active_key, camera_xz):
			continue
		desired[active_key] = true
		_mark_sub_cells(Vector2i(active_key.x, active_key.y), 1 << active_key.z, covered_cells)

	# Largest tier first. Smaller tiers can't overlap a larger accepted chunk.
	# Size levels below the visual owner floor are skipped so the pager does
	# not spend worker budget on non-rendering chunks.
	for size_level in [2, 1, 0]:
		var size: int = 1 << size_level
		var band_start: float = DU.paging_band_start(size_level)
		var band_end: float = DU.paging_band_end(size_level)
		if band_end <= _visual_begin_floor:
			continue
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


## Phase 4c — retention test (plan §4.4).
## A chunk is retained at its current tier when its chunk-center distance is
## within `[band_start - PAGING_HYSTERESIS, band_end + PAGING_HYSTERESIS)`.
## Pure function of `key` + camera XZ — no merger state touched, safe to
## call from the strict-band walker's pre-pass. Static (camera_xz passed in)
## so tests can exercise it without driving `update_for_camera`.
static func _is_within_retention_for(key: Vector3i, camera_xz: Vector2) -> bool:
	var center_world: Vector2 = DU.chunk_center_world(Vector2i(key.x, key.y), key.z)
	var dist: float = camera_xz.distance_to(center_world)
	var lo: float = DU.paging_band_start(key.z) - DU.PAGING_HYSTERESIS
	var hi: float = DU.paging_band_end(key.z) + DU.PAGING_HYSTERESIS
	return dist >= lo and dist < hi


## Instance-facing retention check — used by `_compute_desired_chunks`.
## Thin forwarder so the static implementation stays unit-testable.
func _is_within_retention(key: Vector3i, camera_xz: Vector2) -> bool:
	return _is_within_retention_for(key, camera_xz)


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

## Begin budgeted merge-input collection for a chunk. Actual ESM/ref scanning
## happens in `_process_merge_prepare` across frames.
func _start_chunk_merge_prepare(key: Vector3i, camera_world_pos: Vector3) -> void:
	if not _static_renderer or not _bg_processor:
		return
	var state := MergePrepState.new()
	state.key = key
	state.size_level = key.z
	state.size = 1 << state.size_level
	state.center_cell = Vector2i(key.x, key.y)
	state.camera_world_pos = camera_world_pos
	_preparing_chunks[key] = state
	_prep_queue.append(state)


func _process_merge_prepare(state: MergePrepState, start_usec: int) -> String:
	if not _static_renderer or not _bg_processor:
		_negative_chunks[state.key] = true
		return "done"

	var min_size_sq: float = DU.PAGING_MIN_SIZE_SQ
	while state.cy < state.size:
		if Time.get_ticks_usec() - start_usec >= MERGE_QUEUE_SOFT_LIMIT_USEC:
			return "pending"

		if not state.refs_loaded:
			var cell_grid := Vector2i(state.center_cell.x + state.cx, state.center_cell.y + state.cy)
			if not state.covered_cells.has(cell_grid):
				state.covered_cells.append(cell_grid)
			var cell_record: Variant = ESMManager.get_exterior_cell(cell_grid.x, cell_grid.y)
			state.refs = cell_record.references if cell_record else []
			state.ref_index = 0
			state.refs_loaded = true

		if state.ref_index >= state.refs.size():
			_advance_prepare_cell(state)
			continue

		var ref: Variant = state.refs[state.ref_index]
		if ref.is_deleted:
			state.ref_index += 1
			continue

		var record_type: Array = [""]
		var base_record: Variant = ESMManager.get_any_record(str(ref.ref_id), record_type)
		if not base_record:
			state.ref_index += 1
			continue

		var type_name: String = record_type[0] if record_type.size() > 0 else ""
		if not _type_eligible(type_name, state.size_level):
			state.refs_type_rejected += 1
			state.ref_index += 1
			continue

		var model_path: String = _get_model_path(base_record)
		if model_path.is_empty():
			state.ref_index += 1
			continue

		var pos: Vector3 = CS.vector_to_godot(ref.position)
		var scale: Vector3 = CS.scale_to_godot(ref.scale)
		var basis: Basis = CS.esm_rotation_to_godot_basis(ref.rotation)
		basis = basis.scaled(scale)
		var ref_transform := Transform3D(basis, pos)

		var mesh_type_name := model_path.to_lower().replace("/", "\\")
		var payload_key := _make_static_payload_key(model_path)
		var cell_grid := Vector2i(state.center_cell.x + state.cx, state.center_cell.y + state.cy)
		var bucket_key := _make_bucket_key(cell_grid, payload_key)
		state.bucket_total_counts[bucket_key] = int(state.bucket_total_counts.get(bucket_key, 0)) + 1
		var cache_key: int = ref.ref_num
		var scale_f: float = ref.scale
		var dist_sq: float = pos.distance_squared_to(state.camera_world_pos)
		var size_threshold: float = dist_sq * min_size_sq

		var cached_rs2: float = -1.0
		_size_cache_mutex.lock()
		if cache_key in _size_cache:
			cached_rs2 = _size_cache[cache_key]
		_size_cache_mutex.unlock()

		if cached_rs2 >= 0.0:
			if cached_rs2 < size_threshold:
				state.refs_size_rejected += 1
				state.size_cache_hits += 1
				state.ref_index += 1
				continue
			_size_cache_mutex.lock()
			_size_cache.erase(cache_key)
			_size_cache_mutex.unlock()

		var aabb: AABB = _static_renderer.get_mesh_aabb(mesh_type_name)
		var mesh_radius_sq: float = 0.0
		if aabb.size != Vector3.ZERO:
			mesh_radius_sq = aabb.size.length_squared() * 0.25

		var rs2: float = mesh_radius_sq * scale_f * scale_f
		if mesh_radius_sq > 0.0:
			if rs2 < size_threshold:
				_size_cache_mutex.lock()
				_size_cache[cache_key] = rs2
				_size_cache_mutex.unlock()
				state.refs_size_rejected += 1
				state.ref_index += 1
				continue

		var sub_meshes: Array = _static_renderer.get_sub_meshes(mesh_type_name)
		if sub_meshes.is_empty():
			if _queue_warmup_model(model_path):
				return "warmup"
			state.refs_skipped += 1
			state.ref_index += 1
			continue

		var ref_input := Kernel.RefInput.new()
		ref_input.ref_transform = ref_transform
		ref_input.bucket_key = bucket_key
		ref_input.source_ref_num = int(ref.ref_num)
		ref_input.sub_meshes = []
		ref_input.rs2 = rs2
		ref_input.dist_sq = dist_sq
		var ref_surface_count := 0
		for sub: StaticObjectRendererScript.SubMeshEntry in sub_meshes:
			if not sub.mesh_resource or not sub.mesh_resource is ArrayMesh:
				continue
			var sm := Kernel.SubMeshInput.new()
			sm.mesh = sub.mesh_resource as ArrayMesh
			ref_surface_count += sm.mesh.get_surface_count()
			sm.local_transform = sub.local_transform
			sm.material_override = sub.material_resource
			sm.surface_materials = sub.surface_materials.duplicate()
			ref_input.sub_meshes.append(sm)
		if not ref_input.sub_meshes.is_empty():
			if state.surface_estimate + ref_surface_count > MAX_RUNTIME_CHUNK_SURFACES:
				state.refs_surface_rejected += 1
				state.ref_index += 1
				continue
			state.surface_estimate += ref_surface_count
			state.inputs.append(ref_input)
			state.source_ref_nums[int(ref.ref_num)] = true
			state.source_bucket_counts[bucket_key] = int(state.source_bucket_counts.get(bucket_key, 0)) + 1
		state.ref_index += 1
		if Time.get_ticks_usec() - start_usec >= MERGE_QUEUE_SOFT_LIMIT_USEC:
			return "pending"

	_finish_merge_prepare(state)
	return "done"


func _advance_prepare_cell(state: MergePrepState) -> void:
	state.refs = []
	state.ref_index = 0
	state.refs_loaded = false
	state.cx += 1
	if state.cx >= state.size:
		state.cx = 0
		state.cy += 1


static func _make_static_payload_key(model_path: String) -> String:
	return model_path.to_lower().replace("/", "\\")


static func _make_bucket_key(cell_grid: Vector2i, payload_key: String) -> String:
	return "%d,%d:%s" % [cell_grid.x, cell_grid.y, payload_key]


func _build_manifest_for_state(state: MergePrepState) -> Dictionary:
	return {
		"key": state.key,
		"size_level": state.size_level,
		"covered_cells": state.covered_cells.duplicate(),
		"source_ref_nums": state.source_ref_nums.duplicate(),
		"source_bucket_counts": state.source_bucket_counts.duplicate(),
		"coverage_complete": (
			state.refs_skipped == 0
			and state.refs_size_rejected == 0
			and state.refs_surface_rejected == 0
			and state.refs_partial_bucket_rejected == 0
			and state.refs_type_rejected == 0
		),
		"refs_accepted": state.inputs.size(),
		"refs_skipped": state.refs_skipped,
		"refs_size_rejected": state.refs_size_rejected,
		"refs_surface_rejected": state.refs_surface_rejected,
		"refs_partial_bucket_rejected": state.refs_partial_bucket_rejected,
		"refs_type_rejected": state.refs_type_rejected,
	}


func _filter_partial_bucket_inputs(state: MergePrepState) -> void:
	if state.inputs.is_empty() or state.bucket_total_counts.is_empty():
		return

	var filtered_inputs: Array = []
	var filtered_ref_nums: Dictionary = {}
	var filtered_bucket_counts: Dictionary = {}
	for input_value: Variant in state.inputs:
		var input: Kernel.RefInput = input_value as Kernel.RefInput
		if input == null:
			continue
		var bucket_key: String = input.bucket_key
		if bucket_key.is_empty():
			state.refs_partial_bucket_rejected += 1
			continue
		var accepted_count: int = int(state.source_bucket_counts.get(bucket_key, 0))
		var total_count: int = int(state.bucket_total_counts.get(bucket_key, 0))
		if total_count <= 0 or accepted_count < total_count:
			state.refs_partial_bucket_rejected += 1
			continue
		filtered_inputs.append(input)
		filtered_bucket_counts[bucket_key] = int(filtered_bucket_counts.get(bucket_key, 0)) + 1
		if input.source_ref_num >= 0:
			filtered_ref_nums[input.source_ref_num] = true

	state.inputs = filtered_inputs
	state.source_bucket_counts = filtered_bucket_counts
	state.source_ref_nums = filtered_ref_nums


func _finish_merge_prepare(state: MergePrepState) -> void:
	var key := state.key
	_stats["total_refs_skipped"] += state.refs_skipped
	_stats["refs_size_rejected"] += state.refs_size_rejected
	_stats["refs_surface_rejected"] += state.refs_surface_rejected
	_stats["refs_type_rejected"] += state.refs_type_rejected
	_stats["size_cache_hits"] += state.size_cache_hits
	_filter_partial_bucket_inputs(state)
	_stats["refs_partial_bucket_rejected"] += state.refs_partial_bucket_rejected

	# Cost-benefit minimum — sparse chunks aren't worth merging
	if state.inputs.size() < MIN_REFS_TO_MERGE:
		_negative_chunks[key] = true
		if state.refs_skipped > 0 or state.refs_type_rejected > 0 or state.refs_size_rejected > 0 or state.refs_surface_rejected > 0 or state.refs_partial_bucket_rejected > 0:
			Log.debug("streaming", "HLOD chunk %s: %d inputs (below MIN %d). skipped=%d type_rej=%d size_rej=%d surface_rej=%d partial_bucket_rej=%d" % [
				key, state.inputs.size(), MIN_REFS_TO_MERGE, state.refs_skipped, state.refs_type_rejected, state.refs_size_rejected, state.refs_surface_rejected, state.refs_partial_bucket_rejected])
		elif state.inputs.size() == 0:
			Log.debug("streaming", "HLOD chunk %s: no ESM refs (all cells empty or missing)" % key)
		return

	# Priority = chunk-center distance² (closer first)
	var chunk_origin := _chunk_origin_world(key)
	var camera_xz := Vector2(state.camera_world_pos.x, state.camera_world_pos.z)
	var center_xz := Vector2(chunk_origin.x, chunk_origin.z)
	var priority_sq := camera_xz.distance_squared_to(center_xz)

	Log.debug("streaming", "HLOD chunk %s: merging %d inputs (skipped=%d type_rej=%d size_rej=%d surface_rej=%d partial_bucket_rej=%d)" % [
		key, state.inputs.size(), state.refs_skipped, state.refs_type_rejected, state.refs_size_rejected, state.refs_surface_rejected, state.refs_partial_bucket_rejected])
	var generation := _next_generation
	_next_generation += 1
	_chunk_generations[key] = generation
	_pending_manifests[key] = _build_manifest_for_state(state)
	var task_id := _bg_processor.submit_task(
		_merge_chunk_worker.bind(key, generation, state.inputs, chunk_origin),
		priority_sq
	)
	_pending_merges[key] = task_id
	_task_to_key[task_id] = key
	_task_to_generation[task_id] = generation


## Worker thread entry point. Runs merge kernel, posts result to completion queue.
## All data pre-collected — no scene tree or ESMManager access here.
## `key.z` is threaded through as `size_level` to the kernel (cost-benefit uses it).
func _merge_chunk_worker(key: Vector3i, generation: int, inputs: Array, chunk_origin: Vector3) -> Dictionary:
	var mesh := Kernel.merge_refs(inputs, chunk_origin, key.z, RUNTIME_FORCE_MERGE_ELIGIBLE_REFS)
	if not mesh:
		return {"key": key, "generation": generation, "mesh": null, "bytes": 0}

	var bytes := Kernel.estimate_mesh_bytes(mesh)

	_completed_mutex.lock()
	_completed_queue.append({"key": key, "generation": generation, "mesh": mesh, "bytes": bytes})
	_completed_mutex.unlock()

	return {"key": key, "generation": generation, "bytes": bytes}

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

	# Tier-specific visibility_range (plan §4/§9), clamped by the runtime
	# visual-owner floor so HLOD never z-fights MID fallback.
	_set_chunk_visibility_range(rid, key)
	rs.instance_geometry_set_lod_bias(rid, 1.0)

	if not _globally_visible:
		rs.instance_set_visible(rid, false)

	var data := PagingChunkData.new()
	data.key = key
	data.instance_rid = rid
	data.mesh = mesh
	data.surface_count = mesh.get_surface_count()
	data.material_count = _count_distinct_surface_materials(mesh)
	var geometry_counts := _count_mesh_geometry(mesh)
	data.vertex_count = int(geometry_counts.get("vertices", 0))
	data.index_count = int(geometry_counts.get("indices", 0))
	data.estimated_bytes = estimated_bytes
	var manifest: Dictionary = _mesh_manifests.get(key, {})
	if not manifest.is_empty():
		data.covered_cells = (manifest.get("covered_cells", []) as Array).duplicate()
		data.source_ref_nums = (manifest.get("source_ref_nums", {}) as Dictionary).duplicate()
		data.source_bucket_counts = (manifest.get("source_bucket_counts", {}) as Dictionary).duplicate()
		data.coverage_complete = bool(manifest.get("coverage_complete", false))
		data.refs_accepted = int(manifest.get("refs_accepted", 0))
		data.refs_skipped = int(manifest.get("refs_skipped", 0))
		data.refs_size_rejected = int(manifest.get("refs_size_rejected", 0))
		data.refs_surface_rejected = int(manifest.get("refs_surface_rejected", 0))
		data.refs_type_rejected = int(manifest.get("refs_type_rejected", 0))
	_active_chunks[key] = data
	_coverage_revision += 1
	return true


func _apply_chunk_visibility_range(key: Vector3i) -> void:
	if key not in _active_chunks:
		return
	var data: PagingChunkData = _active_chunks[key]
	if data.instance_rid.is_valid():
		_set_chunk_visibility_range(data.instance_rid, key)


func _set_chunk_visibility_range(rid: RID, key: Vector3i) -> void:
	var band_start: float = DU.paging_band_start(key.z)
	var band_end: float = DU.paging_band_end(key.z)
	var visual_begin: float = maxf(band_start, _visual_begin_floor)
	if visual_begin >= band_end:
		RenderingServer.instance_set_visible(rid, false)
		return
	RenderingServer.instance_geometry_set_visibility_range(
		rid,
		visual_begin, band_end,
		TIER_FADE_MARGIN, TIER_FADE_MARGIN,
		RenderingServer.VISIBILITY_RANGE_FADE_SELF
	)
	RenderingServer.instance_set_visible(rid, _globally_visible)


func _chunk_has_visual_range(key: Vector3i) -> bool:
	var band_start: float = DU.paging_band_start(key.z)
	var band_end: float = DU.paging_band_end(key.z)
	return maxf(band_start, _visual_begin_floor) < band_end


## Unload a single chunk (free RS instance, keep mesh in LRU cache).
func _unload_chunk(key: Vector3i) -> void:
	if key not in _active_chunks:
		return
	var data: PagingChunkData = _active_chunks[key]
	if data.instance_rid.is_valid():
		RenderingServer.free_rid(data.instance_rid)
	_active_chunks.erase(key)
	_chunk_generations.erase(key)
	_coverage_revision += 1

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
			var data: PagingChunkData = _active_chunks[oldest]
			if data.instance_rid.is_valid():
				RenderingServer.free_rid(data.instance_rid)
			_active_chunks.erase(oldest)
			_coverage_revision += 1

		var evicted_bytes: int = _mesh_sizes.get(oldest, 0)
		_cache_used_bytes -= evicted_bytes
		_mesh_cache.erase(oldest)
		_mesh_sizes.erase(oldest)
		_mesh_manifests.erase(oldest)

#endregion


#region Merge Generation Guards

func _is_current_generation(key: Vector3i, generation: int) -> bool:
	return generation > 0 and _chunk_generations.get(key, 0) == generation


func _invalidate_all_generations() -> void:
	_chunk_generations.clear()
	_next_generation += 1

#endregion


#region Background Processor Callbacks

func _on_task_completed(task_id: int, _result: Variant) -> void:
	if task_id in _task_to_key:
		var key: Vector3i = _task_to_key[task_id]
		var generation: int = _task_to_generation.get(task_id, 0)
		_pending_merges.erase(key)
		_task_to_key.erase(task_id)
		_task_to_generation.erase(task_id)
		var produced_no_completion: bool = _result is Dictionary and int(_result.get("bytes", 0)) <= 0
		if produced_no_completion and _chunk_generations.get(key, 0) == generation:
			_chunk_generations.erase(key)
			_pending_manifests.erase(key)


func _on_task_failed(task_id: int, error: String) -> void:
	if task_id in _task_to_key:
		var key: Vector3i = _task_to_key[task_id]
		var generation: int = _task_to_generation.get(task_id, 0)
		Log.warn("hlod", "Merge failed for chunk %s: %s" % [str(key), error])
		_pending_merges.erase(key)
		_pending_manifests.erase(key)
		_task_to_key.erase(task_id)
		_task_to_generation.erase(task_id)
		if _chunk_generations.get(key, 0) == generation:
			_chunk_generations.erase(key)

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
	var active_visual_chunks := 0
	var overlap_chunks := 0
	var nonvisual_chunks := 0
	var active_source_refs: Dictionary = {}
	var active_covered_cells: Dictionary = {}
	var complete_coverage_chunks := 0
	var incomplete_coverage_chunks := 0
	for key: Vector3i in _active_chunks:
		match key.z:
			0: t0 += 1
			1: t1 += 1
			2: t2 += 1
		var chunk_data: PagingChunkData = _active_chunks[key]
		if _chunk_has_visual_range(key):
			active_visual_chunks += 1
			if chunk_data.coverage_complete:
				complete_coverage_chunks += 1
			else:
				incomplete_coverage_chunks += 1
			for ref_num: Variant in chunk_data.source_ref_nums.keys():
				active_source_refs[int(ref_num)] = true
			for cell: Vector2i in chunk_data.covered_cells:
				active_covered_cells[cell] = true
		else:
			nonvisual_chunks += 1
		var band_start: float = DU.paging_band_start(key.z)
		var band_end: float = DU.paging_band_end(key.z)
		var visual_begin: float = maxf(band_start, _visual_begin_floor)
		if visual_begin < DU.MID_END and band_end > 0.0:
			overlap_chunks += 1
	_stats["chunks_tier_0"] = t0
	_stats["chunks_tier_1"] = t1
	_stats["chunks_tier_2"] = t2
	_stats["active_visual_chunks"] = active_visual_chunks
	_stats["mid_hlod_overlap_chunks"] = overlap_chunks
	_stats["nonvisual_chunks_suppressed"] = nonvisual_chunks
	_stats["active_covered_refs"] = active_source_refs.size()
	_stats["active_covered_cells"] = active_covered_cells.size()
	_stats["active_complete_coverage_chunks"] = complete_coverage_chunks
	_stats["active_incomplete_coverage_chunks"] = incomplete_coverage_chunks
	_stats["coverage_revision"] = _coverage_revision

	var total_surfaces := 0
	var total_materials := 0
	var total_vertices := 0
	var total_indices := 0
	var max_surfaces := 0
	var max_materials := 0
	var max_vertices := 0
	var max_indices := 0
	for key: Vector3i in _active_chunks:
		var data: PagingChunkData = _active_chunks[key]
		total_surfaces += data.surface_count
		total_materials += data.material_count
		total_vertices += data.vertex_count
		total_indices += data.index_count
		max_surfaces = maxi(max_surfaces, data.surface_count)
		max_materials = maxi(max_materials, data.material_count)
		max_vertices = maxi(max_vertices, data.vertex_count)
		max_indices = maxi(max_indices, data.index_count)
	_stats["total_chunk_surfaces"] = total_surfaces
	_stats["total_chunk_materials"] = total_materials
	_stats["total_chunk_vertices"] = total_vertices
	_stats["total_chunk_indices"] = total_indices
	_stats["max_chunk_surfaces"] = max_surfaces
	_stats["max_chunk_materials"] = max_materials
	_stats["max_chunk_vertices"] = max_vertices
	_stats["max_chunk_indices"] = max_indices

	_size_cache_mutex.lock()
	_stats["size_cache_size"] = _size_cache.size()
	_size_cache_mutex.unlock()

	_stats["warmup_queue_size"] = _warmup_queue.size()
	_stats["preparing_chunks"] = _prep_queue.size()
	_stats["negative_chunks"] = _negative_chunks.size()
	_stats["merge_queue_size"] = _merge_queue.size()
	_stats["visual_begin_floor"] = _visual_begin_floor

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


static func _count_distinct_surface_materials(mesh: ArrayMesh) -> int:
	if not mesh:
		return 0
	var materials: Dictionary = {}
	for surface_idx in range(mesh.get_surface_count()):
		var material := mesh.surface_get_material(surface_idx)
		if material:
			materials[str(material.get_rid())] = true
		else:
			materials["<null>"] = true
	return materials.size()


static func _count_mesh_geometry(mesh: ArrayMesh) -> Dictionary:
	var out := {"vertices": 0, "indices": 0}
	if not mesh:
		return out
	for surface_idx in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(surface_idx)
		if arrays.is_empty():
			continue
		var verts: Variant = arrays[Mesh.ARRAY_VERTEX]
		if verts is PackedVector3Array:
			out["vertices"] = int(out["vertices"]) + (verts as PackedVector3Array).size()
		var indices: Variant = arrays[Mesh.ARRAY_INDEX]
		if indices is PackedInt32Array and not (indices as PackedInt32Array).is_empty():
			out["indices"] = int(out["indices"]) + (indices as PackedInt32Array).size()
		elif verts is PackedVector3Array:
			out["indices"] = int(out["indices"]) + (verts as PackedVector3Array).size()
	return out


func _model_cache_scene_path(model_path: String) -> String:
	if _models_dir.is_empty():
		return ""
	var cache_key := model_path.to_lower().replace("/", "\\")
	var safe_name := cache_key.replace("\\", "_").replace("/", "_").replace(":", "_").replace(".", "_")
	return _models_dir.path_join(safe_name + ".res")


func _model_cache_scene_exists(model_path: String) -> bool:
	var scene_path := _model_cache_scene_path(model_path)
	return not scene_path.is_empty() and FileAccess.file_exists(scene_path)


## Load a prototype from the model cache (.res files).
## Used for models not yet registered in StaticObjectRenderer (far chunks).
## Returns instantiated Node3D (caller must free), or null if not in cache.
func _load_prototype_from_cache(model_path: String) -> Node3D:
	var scene_path := _model_cache_scene_path(model_path)
	if scene_path.is_empty() or not FileAccess.file_exists(scene_path):
		return null

	var packed_scene := ResourceLoader.load(scene_path, "PackedScene") as PackedScene
	if not packed_scene:
		return null

	return packed_scene.instantiate() as Node3D

#endregion
