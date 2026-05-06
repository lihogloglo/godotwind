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
const WorldObjectRecordScript := preload("res://src/core/world/world_object_record.gd")

## LRU cache budget in bytes (default 256 MB)
const CACHE_BUDGET_BYTES: int = 256 * 1024 * 1024

## Minimum refs to justify merging a chunk.
## Sparse chunks are still valid visual proxies because MID no longer covers
## beyond 300m. Keep this permissive; proxy-material/atlas work can later reduce
## draw cost without creating HLOD coverage holes.
const MIN_REFS_TO_MERGE: int = 1

## Merge-queue stagger budget (main-thread work per frame).
const MERGES_PER_FRAME: int = 1
const MERGE_QUEUE_BUDGET_USEC: int = 1500
const MERGE_QUEUE_SOFT_LIMIT_USEC: int = 1200

## Completion publish budget. Runtime HLOD publication must stay bounded; LOD
## generation for proxy chunks belongs in an offline/precomputed path, not in
## traversal-time publish.
const COMPLETIONS_PER_FRAME: int = 1
const COMPLETION_BUDGET_USEC: int = 1500
const RUNTIME_GENERATE_LODS: bool = false
const MAX_RUNTIME_CHUNK_SURFACES: int = 64

## visibility_range fade margins (same on both sides of a tier handoff).
const TIER_FADE_MARGIN: float = 20.0

## Runtime visibility owner floor. HLOD should render at the canonical
## MID->HLOD handoff (300m). MID is independently capped at the same handoff;
## the coverage manifest is only allowed to shorten buckets that HLOD fully
## covers, never to decide whether accepted HLOD refs render.
const DEFAULT_VISUAL_BEGIN_FLOOR: float = DU.HLOD_START

## Phase 4d — teleport warmup (plan §11 Phase 3 / session log §7).
## A camera translation larger than this threshold between consecutive
## `update_for_camera` calls triggers a warmup pass: the merger pre-loads
## `.res` prototypes for the incoming chunk ring over several frames BEFORE
## submitting any merges, so the merge burst doesn't stall the main thread
## on cold ResourceLoader I/O inside merge preparation.
const TELEPORT_THRESHOLD: float = 500.0

## Max prototype warmup checks per `process_merge_queue` call while warmup is
## active. Warmup starts ModelLoader async requests for cold entries and only
## instantiates/registers prototypes after their PackedScene is already cached.
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

## Predictive paging queues the next HLOD ring in the movement direction so
## normal traversal does not discover cold chunks exactly at the tier boundary.
const PREDICTIVE_STREAMING_ENABLED: bool = true
const PREDICTIVE_LOOKAHEAD_SECONDS: float = 4.0
const PREDICTIVE_MIN_SPEED_MPS: float = 8.0
const PREDICTIVE_MAX_LOOKAHEAD_M: float = 700.0
const PREDICTIVE_SAMPLE_COUNT: int = 3


#region Internal Data Classes

## Per-chunk state for an active merged region.
## `key.xy` = aligned center_cell, `key.z` = size_level (0/1/2).
class PagingChunkData:
	var key: Vector3i
	var instance_rid: RID
	var mesh: ArrayMesh  ## Strong ref — prevents GC
	var surface_count: int = 0
	var material_count: int = 0
	var null_material_surface_count: int = 0
	var default_proxy_surface_count: int = 0
	var source_null_material_surfaces: int = 0
	var overflow_proxy_surfaces: int = 0
	var vertex_count: int = 0
	var index_count: int = 0
	var estimated_bytes: int = 0
	var covered_cells: Array[Vector2i] = []
	var source_ref_nums: Dictionary = {}
	var source_object_ids: Dictionary = {}
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
	var source_object_ids: Dictionary = {}
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
## HLOD-on = MID capped at DU.MID_END, HLOD visible 300-1000m, FAR visible
## from DU.FAR_START onward. HLOD-off parks only merged chunks; it does not
## widen MID or pull FAR inward.
## Toggle at runtime via console: `hlod_enable` / `hlod_disable`.
var enabled: bool = true

## SubsystemToggles "hlod" flag state. Persists across chunk creation so
## chunks merged AFTER a `toggle hlod off` don't pop back as visible.
## Mirrors the same pattern used by StaticObjectRenderer._globally_visible.
var _globally_visible: bool = true
var _visual_begin_floor: float = DEFAULT_VISUAL_BEGIN_FLOOR
var _visual_end_cap: float = DU.HLOD_END
var _visibility_fade_enabled: bool = false

## Scenario RID for creating RS instances
var _scenario: RID = RID()

## Reference to the static object renderer (for MeshType lookups)
var _static_renderer: StaticObjectRendererScript = null

## Reference to background processor (for submitting merge tasks)
var _bg_processor: BackgroundProcessor = null

## Shared model loader. HLOD warmup uses this instead of doing its own
## FileAccess/ResourceLoader probes on the streaming hot path.
var _model_loader: ModelLoader = null
var _world_object_source: RefCounted = null

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
## renderer/cache state. These are HLOD coverage holes to diagnose; MID and FAR
## do not move their tier boundaries to cover them.
var _negative_chunks: Dictionary = {}  # Vector3i -> String reason

## Chunk merge input collection currently being prepared across frames.
var _prep_queue: Array[MergePrepState] = []
var _preparing_chunks: Dictionary = {}  # Vector3i -> MergePrepState

## Merge queue — chunks waiting for main-thread data collection + worker submission.
## Staggered: max MERGES_PER_FRAME processed per frame to avoid main-thread stalls.
var _merge_queue: Array[Vector3i] = []
var _camera_cell_cached: Vector2i = Vector2i.ZERO
var _camera_world_pos_cached: Vector3 = Vector3.ZERO
var _last_desired_chunks: Dictionary = {}
var _last_prefetch_chunks: Dictionary = {}

## Phase 4d — teleport warmup state.
## `_last_camera_world_pos` is the camera position from the previous
## `update_for_camera` call, used to detect a jump > TELEPORT_THRESHOLD.
## `Vector3.INF` sentinel = no prior call (first-ever frame, never triggers).
var _last_camera_world_pos: Vector3 = Vector3.INF
var _last_update_ticks_msec: int = 0
var _camera_velocity_xz: Vector2 = Vector2.ZERO

## Pending prototype-load paths to pre-register. Drained by `process_merge_queue`
## before any merges are submitted. Main-thread only.
var _warmup_queue: Array[String] = []

## Dedup guard — mesh_type_names we've already enqueued in the current warmup
## burst. Cleared when the queue fully drains (or when cleanup() runs).
var _warmup_dispatched: Dictionary = {}

## Mesh types with a ModelLoader async request already started by HLOD warmup.
## ModelLoader's public loading check only covers active threaded requests, not
## throttled deferred entries, so ObjectPaging owns this higher-level dedup.
var _warmup_pending_async: Dictionary = {}

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
var _mesh_stats_cache: Dictionary = {}  # Vector3i -> Dictionary
var _lru_order: Array[Vector3i] = []  # Oldest first
var _cache_used_bytes: int = 0
var _pending_manifests: Dictionary = {}  # Vector3i -> Dictionary
var _cached_publish_queue: Array[Vector3i] = []
var _cached_publish_keys: Dictionary = {}  # Vector3i -> true
var _coverage_revision: int = 0

## Stats
var _stats: Dictionary = {
	"active_cells": 0,         # kept name for caller compat; counts all active chunks across tiers
	"pending_merges": 0,
	"cached_publish_queue_size": 0,
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
	"visible_hlod_draw_calls": 0,
	"null_material_surface_count": 0,
	"default_proxy_surface_count": 0,
	"source_null_material_surfaces": 0,
	"overflow_proxy_surfaces": 0,
	"chunk_surface_histogram": {},
	"chunk_material_histogram": {},
	"total_chunk_vertices": 0,
	"total_chunk_indices": 0,
	"max_chunk_surfaces": 0,
	"max_chunk_materials": 0,
	"max_chunk_vertices": 0,
	"max_chunk_indices": 0,
	"stale_completions_discarded": 0,
	"surface_cap_rejections": 0,
	"surface_cap_over_budget_published": 0,
	"merge_queue_last_usec": 0,
	"completion_last_usec": 0,
	"preparing_chunks": 0,
	"negative_chunks": 0,
	"negative_empty_chunks": 0,
	"negative_sparse_chunks": 0,
	"negative_filtered_chunks": 0,
	"negative_failed_chunks": 0,
	"negative_surface_cap_chunks": 0,
	"desired_chunks": 0,
	"predictive_desired_chunks": 0,
	"runtime_surface_budget_proxy_chunks": 0,
	"desired_chunks_tier_0": 0,
	"desired_chunks_tier_1": 0,
	"desired_chunks_tier_2": 0,
	"merge_queue_size": 0,
	"active_visual_chunks": 0,
	"visual_begin_floor": DEFAULT_VISUAL_BEGIN_FLOOR,
	"visual_end_cap": DU.HLOD_END,
	"visibility_fade_enabled": false,
	"mid_hlod_overlap_chunks": 0,
	"nonvisual_chunks_suppressed": 0,
	"active_covered_refs": 0,
	"active_covered_cells": 0,
	"active_complete_coverage_chunks": 0,
	"active_incomplete_coverage_chunks": 0,
	"coverage_revision": 0,
	"warmup_queue_size": 0,    # Phase 4d — prototype pre-load queue depth
	"warmup_async_requests": 0,
	"warmup_pending_async": 0,
	"warmup_registered": 0,
	"warmup_failed": 0,
	"total_teleports": 0,      # Phase 4d — cumulative teleport events detected
	"runtime_lod_generation_enabled": RUNTIME_GENERATE_LODS,
	"runtime_force_merge_eligible_refs": RUNTIME_FORCE_MERGE_ELIGIBLE_REFS,
}

#endregion


#region Public API

## Initialize with viewport scenario, static renderer (for mesh data), and background processor.
func initialize(scenario: RID, static_renderer: StaticObjectRendererScript,
		bg_processor: BackgroundProcessor, model_loader: ModelLoader = null) -> void:
	_scenario = scenario
	_static_renderer = static_renderer
	_bg_processor = bg_processor
	_model_loader = model_loader
	_models_dir = SettingsManager.get_models_path()

	if _bg_processor:
		_bg_processor.task_completed.connect(_on_task_completed)
		_bg_processor.task_failed.connect(_on_task_failed)


func set_world_object_source(source: RefCounted) -> void:
	_world_object_source = source


## Update active paging chunks based on camera position. Runs the top-down
##
## `camera_world_pos` is the actual camera world position — used by both the
## chunk-center band classification (§4.2) and the per-ref projected-size test
## (§2.2, Phase 2). Legacy callers may pass `Vector3.INF` to approximate from
## `camera_cell`, but new callers should provide the real position.
func update_for_camera(camera_cell: Vector2i, camera_world_pos: Vector3 = Vector3.INF, camera_velocity_xz: Vector2 = Vector2.INF) -> int:
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
	_update_camera_velocity(is_teleport, camera_velocity_xz)
	if is_teleport:
		_stats["total_teleports"] += 1
	_last_camera_world_pos = _camera_world_pos_cached
	_last_update_ticks_msec = Time.get_ticks_msec()

	# Plan §4.3 — top-down anti-overlap walk. Larger tiers claim their cells
	# first; smaller tiers skip any chunk whose 1×1 sub-cells are covered.
	var desired_chunks: Dictionary = _compute_desired_chunks(camera_cell, _camera_world_pos_cached)
	var prefetch_chunks: Dictionary = _compute_predictive_prefetch_chunks(desired_chunks)
	var combined_chunks: Dictionary = desired_chunks.duplicate()
	for key: Vector3i in prefetch_chunks:
		combined_chunks[key] = true
	_last_desired_chunks = desired_chunks.duplicate()
	_last_prefetch_chunks = prefetch_chunks.duplicate()
	_stats["desired_chunks"] = desired_chunks.size()
	_stats["predictive_desired_chunks"] = prefetch_chunks.size()
	Log.debug("streaming", "HLOD update_for_camera: %d desired chunks, %d active, %d pending, %d queued (cell=%s)" % [
		combined_chunks.size(), _active_chunks.size(), _pending_merges.size(), _merge_queue.size(), camera_cell])

	# Phase 4d — on teleport, enqueue unregistered prototypes for the new ring.
	if is_teleport:
		_prime_warmup_queue(desired_chunks)
	elif not prefetch_chunks.is_empty():
		_prime_warmup_queue(prefetch_chunks)

	var changed := 0

	# Queue new chunks (stagger via process_merge_queue)
	for key: Vector3i in combined_chunks:
		if key in _active_chunks or key in _pending_merges or key in _chunk_generations or key in _negative_chunks or key in _preparing_chunks or key in _cached_publish_keys:
			continue
		# Check LRU cache (fast path — previously merged)
		if key in _mesh_cache:
			if key in desired_chunks:
				_queue_cached_publish(key)
		elif key not in _merge_queue:
			_merge_queue.append(key)

	# Sort merge queue by chunk-center distance (closest first)
	if not _merge_queue.is_empty():
		_merge_queue.sort_custom(_sort_by_chunk_priority)

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
		if key not in combined_chunks:
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
		if state.key in combined_chunks:
			return true
		_preparing_chunks.erase(state.key)
		return false
	)

	# Invalidate completed-but-not-yet-published requests that left desired set.
	var generations_to_drop: Array[Vector3i] = []
	for key: Vector3i in _chunk_generations:
		if key not in combined_chunks and key not in _active_chunks:
			generations_to_drop.append(key)
	for key: Vector3i in generations_to_drop:
		_chunk_generations.erase(key)

	# Drop negative cache entries after the chunk leaves the desired ring so a
	# later camera pass can re-evaluate against a changed renderer/cache state.
	var negatives_to_drop: Array[Vector3i] = []
	for key: Vector3i in _negative_chunks:
		if key not in combined_chunks:
			negatives_to_drop.append(key)
	for key: Vector3i in negatives_to_drop:
		_negative_chunks.erase(key)

	# Remove queued chunks that left desired set
	_merge_queue = _merge_queue.filter(func(k: Vector3i) -> bool: return k in combined_chunks)
	_cached_publish_queue = _cached_publish_queue.filter(func(k: Vector3i) -> bool:
		if k in desired_chunks and k in _mesh_cache and k not in _active_chunks:
			return true
		_cached_publish_keys.erase(k)
		return false
	)
	if not _cached_publish_queue.is_empty():
		_cached_publish_queue.sort_custom(_sort_by_chunk_priority)

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
func process_merge_queue(deadline_usec: int = 0) -> void:
	var start_usec := Time.get_ticks_usec()
	if not enabled:
		_stats["merge_queue_last_usec"] = 0
		return
	if _deadline_exhausted(deadline_usec):
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
		_drain_warmup_queue(deadline_usec)
		if Time.get_ticks_usec() - start_usec >= MERGE_QUEUE_SOFT_LIMIT_USEC or _deadline_exhausted(deadline_usec):
			_stats["merge_queue_last_usec"] = Time.get_ticks_usec() - start_usec
			return

	if _merge_queue.is_empty():
		if not _prep_queue.is_empty():
			while not _prep_queue.is_empty():
				var prep_status := _process_merge_prepare(_prep_queue[0], start_usec, deadline_usec)
				if prep_status == "done":
					var done_state: MergePrepState = _prep_queue[0]
					_prep_queue.remove_at(0)
					_preparing_chunks.erase(done_state.key)
					continue
				if prep_status == "warmup" and _prep_queue.size() > 1:
					var waiting_state: MergePrepState = _prep_queue[0]
					_prep_queue.remove_at(0)
					_prep_queue.append(waiting_state)
					continue
				break
			_stats["merge_queue_last_usec"] = Time.get_ticks_usec() - start_usec
			return
		_stats["merge_queue_last_usec"] = 0
		return

	var budget := MERGES_PER_FRAME
	while Time.get_ticks_usec() - start_usec < MERGE_QUEUE_SOFT_LIMIT_USEC and not _deadline_exhausted(deadline_usec):
		while not _prep_queue.is_empty():
			var prep_status := _process_merge_prepare(_prep_queue[0], start_usec, deadline_usec)
			if prep_status == "done":
				var done_state: MergePrepState = _prep_queue[0]
				_prep_queue.remove_at(0)
				_preparing_chunks.erase(done_state.key)
				continue
			if prep_status == "warmup" and _prep_queue.size() > 1:
				var waiting_state: MergePrepState = _prep_queue[0]
				_prep_queue.remove_at(0)
				_prep_queue.append(waiting_state)
				continue
			break
		if not _prep_queue.is_empty() and (Time.get_ticks_usec() - start_usec >= MERGE_QUEUE_SOFT_LIMIT_USEC or _deadline_exhausted(deadline_usec)):
			break
		if budget <= 0 or _merge_queue.is_empty():
			break
		if Time.get_ticks_usec() - start_usec >= MERGE_QUEUE_SOFT_LIMIT_USEC or _deadline_exhausted(deadline_usec):
			break
		var key: Vector3i = _merge_queue[0]
		_merge_queue.remove_at(0)
		# Skip if already active or pending (could have been cached/loaded since queued)
		if key in _active_chunks or key in _pending_merges or key in _chunk_generations or key in _negative_chunks or key in _preparing_chunks:
			continue
		_start_chunk_merge_prepare(key, _camera_world_pos_cached)
		budget -= 1
	_stats["merge_queue_last_usec"] = Time.get_ticks_usec() - start_usec


func _queue_cached_publish(key: Vector3i) -> void:
	if key in _cached_publish_keys:
		return
	if key not in _mesh_cache:
		return
	_cached_publish_keys[key] = true
	_cached_publish_queue.append(key)


func _reject_surface_cap_chunk(key: Vector3i, surface_count: int, source: String) -> void:
	_negative_chunks[key] = "surface_cap"
	_stats["surface_cap_rejections"] = int(_stats.get("surface_cap_rejections", 0)) + 1
	Log.warn("hlod", "Rejecting over-budget runtime HLOD chunk %s from %s with %d surfaces (cap=%d); needs cached proxy asset" % [
		str(key),
		source,
		surface_count,
		MAX_RUNTIME_CHUNK_SURFACES,
	])


## Process completed merge results on main thread. Creates RS instances.
## Call once per frame from streaming manager.
## Returns number of chunks completed.
func process_completions(deadline_usec: int = 0) -> int:
	var start_usec := Time.get_ticks_usec()
	if not enabled:
		_completed_mutex.lock()
		_stats["stale_completions_discarded"] += _completed_queue.size()
		_completed_queue.clear()
		_completed_mutex.unlock()
		_cached_publish_queue.clear()
		_cached_publish_keys.clear()
		_stats["completion_last_usec"] = 0
		return 0

	_completed_mutex.lock()
	if _completed_queue.is_empty() and _cached_publish_queue.is_empty():
		_completed_mutex.unlock()
		_stats["completion_last_usec"] = 0
		return 0

	if not _globally_visible:
		_stats["stale_completions_discarded"] += _completed_queue.size()
		_completed_queue.clear()
		_completed_mutex.unlock()
		_cached_publish_queue.clear()
		_cached_publish_keys.clear()
		_stats["completion_last_usec"] = 0
		return 0

	_completed_mutex.unlock()
	var queue: Array = []
	var budget := COMPLETIONS_PER_FRAME
	var count := 0
	while budget > 0 and not _cached_publish_queue.is_empty():
		if Time.get_ticks_usec() - start_usec >= COMPLETION_BUDGET_USEC or _deadline_exhausted(deadline_usec):
			break
		var cached_key: Vector3i = _cached_publish_queue[0]
		_cached_publish_queue.remove_at(0)
		_cached_publish_keys.erase(cached_key)
		if cached_key not in _last_desired_chunks or cached_key in _active_chunks or cached_key not in _mesh_cache:
			continue
		var cached_stats: Dictionary = _mesh_stats_cache.get(cached_key, {})
		var cached_mesh: ArrayMesh = _mesh_cache[cached_key]
		var cached_surface_count := int(cached_stats.get("surface_count", cached_mesh.get_surface_count()))
		if cached_surface_count > MAX_RUNTIME_CHUNK_SURFACES:
			_reject_surface_cap_chunk(cached_key, cached_surface_count, "cached_publish")
			_evict_cached_mesh(cached_key)
			continue
		if _create_rs_instance(
				cached_key,
				cached_mesh,
				_mesh_sizes.get(cached_key, 0),
				cached_stats
			):
			_lru_touch(cached_key)
			count += 1
			budget -= 1
	_completed_mutex.lock()
	while budget > 0 and not _completed_queue.is_empty():
		if Time.get_ticks_usec() - start_usec >= COMPLETION_BUDGET_USEC or _deadline_exhausted(deadline_usec):
			break
		queue.append(_completed_queue.pop_back())
		budget -= 1
	_completed_mutex.unlock()

	for entry: Dictionary in queue:
		var key: Vector3i = entry["key"]
		var generation: int = entry.get("generation", 0)
		var mesh: ArrayMesh = entry["mesh"]
		var bytes: int = entry["bytes"]
		var mesh_stats: Dictionary = entry.get("mesh_stats", {})

		# Chunk may have left range, been cancelled, or been superseded while
		# the worker was in progress. Reject before LOD generation or RS publish.
		if not _is_current_generation(key, generation) or key in _active_chunks:
			_stats["stale_completions_discarded"] += 1
			_pending_manifests.erase(key)
			continue

		if mesh == null:
			_negative_chunks[key] = "merge_failed"
			_stats["surface_cap_rejections"] = int(_stats.get("surface_cap_rejections", 0)) + 1
			_pending_manifests.erase(key)
			_chunk_generations.erase(key)
			continue
		if mesh.get_surface_count() > MAX_RUNTIME_CHUNK_SURFACES:
			_reject_surface_cap_chunk(key, mesh.get_surface_count(), "merge_completion")
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
		_mesh_stats_cache[key] = mesh_stats.duplicate()
		_pending_manifests.erase(key)
		_lru_order.append(key)
		_cache_used_bytes += bytes

		if key in _last_desired_chunks and _create_rs_instance(key, mesh, bytes, mesh_stats):
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


func get_coverage_revision() -> int:
	return _coverage_revision


func get_active_coverage_manifest() -> Dictionary:
	var source_object_ids: Dictionary = {}
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
		for object_id: Variant in data.source_object_ids.keys():
			source_object_ids[object_id] = true
		for bucket_key: Variant in data.source_bucket_counts.keys():
			var key_string := str(bucket_key)
			source_bucket_counts[key_string] = int(source_bucket_counts.get(key_string, 0)) + int(data.source_bucket_counts[bucket_key])
		for cell: Vector2i in data.covered_cells:
			covered_cells[cell] = true
	return {
		"source_bucket_counts": source_bucket_counts,
		"complete_bucket_counts": source_bucket_counts.duplicate(),
		"covered_cells": covered_cells,
		"source_object_ids": source_object_ids,
		"source_ref_nums": source_object_ids,
		"active_covered_refs": source_object_ids.size(),
		"active_covered_cells": covered_cells.size(),
		"active_complete_coverage_chunks": complete_chunks,
		"active_incomplete_coverage_chunks": incomplete_chunks,
		"coverage_revision": _coverage_revision,
	}


func get_active_chunk_debug_data() -> Array[Dictionary]:
	var by_key: Dictionary = {}
	for key: Vector3i in _last_desired_chunks:
		by_key[key] = _make_chunk_debug_entry(key, "desired")
	for key: Vector3i in _negative_chunks:
		var negative_entry := _make_chunk_debug_entry(key, "negative")
		negative_entry["negative_reason"] = str(_negative_chunks.get(key, "unknown"))
		by_key[key] = negative_entry
	for key: Vector3i in _merge_queue:
		by_key[key] = _make_chunk_debug_entry(key, "queued")
	for key: Vector3i in _preparing_chunks:
		var prep_entry := _make_chunk_debug_entry(key, "preparing")
		var state: MergePrepState = _preparing_chunks[key]
		prep_entry.merge(_make_debug_counts_from_state(state))
		by_key[key] = prep_entry
	for key: Vector3i in _pending_merges:
		var pending_entry := _make_chunk_debug_entry(key, "pending")
		var manifest: Dictionary = _pending_manifests.get(key, {})
		if not manifest.is_empty():
			pending_entry.merge(_make_debug_counts_from_manifest(manifest))
		by_key[key] = pending_entry
	var chunks: Array[Dictionary] = []
	for key: Vector3i in _active_chunks:
		var data: PagingChunkData = _active_chunks[key]
		var entry := _make_chunk_debug_entry(key, "active")
		entry.merge({
			"surface_count": data.surface_count,
			"material_count": data.material_count,
			"null_material_surface_count": data.null_material_surface_count,
			"default_proxy_surface_count": data.default_proxy_surface_count,
			"overflow_proxy_surfaces": data.overflow_proxy_surfaces,
			"vertex_count": data.vertex_count,
			"coverage_complete": data.coverage_complete,
			"refs_accepted": data.refs_accepted,
			"refs_skipped": data.refs_skipped,
			"refs_size_rejected": data.refs_size_rejected,
			"refs_surface_rejected": data.refs_surface_rejected,
			"refs_type_rejected": data.refs_type_rejected,
		})
		by_key[key] = entry
	for key: Vector3i in by_key:
		chunks.append(by_key[key])
	return chunks


func _make_chunk_debug_entry(key: Vector3i, status: String) -> Dictionary:
	var size_cells := 1 << key.z
	var size_m := float(size_cells) * DU.CELL_SIZE_METERS
	var band_start := DU.paging_band_start(key.z)
	var band_end := minf(DU.paging_band_end(key.z), _visual_end_cap)
	var visual_begin := maxf(band_start, _visual_begin_floor)
	return {
		"key": key,
		"status": status,
		"size_level": key.z,
		"size_cells": size_cells,
		"size_m": size_m,
		"origin": _chunk_origin_world(key),
		"visual": status == "active" and _chunk_has_visual_range(key),
		"visibility_begin": visual_begin,
		"visibility_end": band_end,
		"surface_count": 0,
		"material_count": 0,
		"null_material_surface_count": 0,
		"default_proxy_surface_count": 0,
		"overflow_proxy_surfaces": 0,
		"vertex_count": 0,
		"coverage_complete": false,
		"refs_accepted": 0,
		"refs_skipped": 0,
		"refs_size_rejected": 0,
		"refs_surface_rejected": 0,
		"refs_type_rejected": 0,
	}


static func _make_debug_counts_from_manifest(manifest: Dictionary) -> Dictionary:
	return {
		"refs_accepted": int(manifest.get("refs_accepted", 0)),
		"refs_skipped": int(manifest.get("refs_skipped", 0)),
		"refs_size_rejected": int(manifest.get("refs_size_rejected", 0)),
		"refs_surface_rejected": int(manifest.get("refs_surface_rejected", 0)),
		"refs_type_rejected": int(manifest.get("refs_type_rejected", 0)),
		"coverage_complete": bool(manifest.get("coverage_complete", false)),
	}


static func _make_debug_counts_from_state(state: MergePrepState) -> Dictionary:
	return {
		"refs_accepted": state.inputs.size(),
		"refs_skipped": state.refs_skipped,
		"refs_size_rejected": state.refs_size_rejected,
		"refs_surface_rejected": state.refs_surface_rejected,
		"refs_type_rejected": state.refs_type_rejected,
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
		_last_desired_chunks.clear()
		_warmup_queue.clear()
		_warmup_dispatched.clear()
		_warmup_pending_async.clear()
		_warmup_failed.clear()
		_invalidate_all_generations()
		_negative_chunks.clear()
		_prep_queue.clear()
		_preparing_chunks.clear()
		_cached_publish_queue.clear()
		_cached_publish_keys.clear()
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


func set_visual_end_cap(distance_m: float) -> void:
	_visual_end_cap = clampf(distance_m, _visual_begin_floor, DU.HLOD_END)
	for key: Vector3i in _active_chunks.keys():
		_apply_chunk_visibility_range(key)
	_refresh_stats()


func set_visibility_fade_enabled(enabled_value: bool) -> void:
	_visibility_fade_enabled = enabled_value
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
	_last_desired_chunks.clear()

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
	_mesh_stats_cache.clear()
	_lru_order.clear()
	_cached_publish_queue.clear()
	_cached_publish_keys.clear()
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
	_warmup_pending_async.clear()
	_warmup_failed.clear()
	_last_camera_world_pos = Vector3.INF
	_last_update_ticks_msec = 0
	_camera_velocity_xz = Vector2.ZERO
	_last_prefetch_chunks.clear()

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


func _update_camera_velocity(is_teleport: bool, supplied_velocity_xz: Vector2 = Vector2.INF) -> void:
	if is_teleport or _last_camera_world_pos == Vector3.INF or _last_update_ticks_msec <= 0:
		_camera_velocity_xz = Vector2.ZERO
		return
	if supplied_velocity_xz != Vector2.INF:
		_camera_velocity_xz = supplied_velocity_xz
		return
	var dt := float(Time.get_ticks_msec() - _last_update_ticks_msec) / 1000.0
	if dt <= 0.0001:
		return
	var delta := _camera_world_pos_cached - _last_camera_world_pos
	_camera_velocity_xz = Vector2(delta.x, delta.z) / dt


func _compute_predictive_prefetch_chunks(current_desired: Dictionary) -> Dictionary:
	if not PREDICTIVE_STREAMING_ENABLED:
		return {}
	var speed := _camera_velocity_xz.length()
	if speed < PREDICTIVE_MIN_SPEED_MPS:
		return {}
	var lookahead := minf(speed * PREDICTIVE_LOOKAHEAD_SECONDS, PREDICTIVE_MAX_LOOKAHEAD_M)
	if lookahead <= 0.0:
		return {}
	var dir := _camera_velocity_xz / speed
	var prefetch: Dictionary = {}
	for sample in range(1, PREDICTIVE_SAMPLE_COUNT + 1):
		var t := float(sample) / float(PREDICTIVE_SAMPLE_COUNT)
		var future_pos := _camera_world_pos_cached + Vector3(dir.x * lookahead * t, 0.0, dir.y * lookahead * t)
		var future_cell := DU.world_to_cell(future_pos)
		var future_desired := _compute_desired_chunks(future_cell, future_pos)
		for key: Vector3i in future_desired:
			if key not in current_desired:
				prefetch[key] = true
	return prefetch


## Populate the warmup queue with unregistered prototype paths for every
## desired chunk. Skips paths already enqueued in the current burst. Called
## exactly once per teleport event, from `update_for_camera`.
func _prime_warmup_queue(desired_chunks: Dictionary) -> void:
	if not RUNTIME_PROTOTYPE_WARMUP:
		return
	if not _static_renderer or _world_object_source == null:
		return
	for key: Vector3i in desired_chunks:
		var size: int = 1 << key.z
		for cy in range(size):
			for cx in range(size):
				var cell_grid := Vector2i(key.x + cx, key.y + cy)
				var records: Array = _world_object_source.get_objects_in_cell(cell_grid, WorldObjectRecordScript.CAP_HLOD)
				for record: RefCounted in records:
					var model_path: String = record.model_path
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
## Cold entries start a ModelLoader async request and rotate to a later frame;
## ready entries instantiate from the cached PackedScene and register with the renderer.
## When the queue fully drains, `_warmup_dispatched` clears so a future
## teleport gets a fresh dedup set.
func _drain_warmup_queue(deadline_usec: int = 0) -> void:
	if not _static_renderer:
		_warmup_queue.clear()
		_warmup_dispatched.clear()
		_warmup_pending_async.clear()
		return
	var start_usec := Time.get_ticks_usec()
	var budget := WARMUP_LOADS_PER_FRAME
	var initial_count := _warmup_queue.size()
	var scanned := 0
	while budget > 0 and not _warmup_queue.is_empty() and scanned < initial_count:
		if Time.get_ticks_usec() - start_usec >= WARMUP_BUDGET_USEC or _deadline_exhausted(deadline_usec):
			break
		scanned += 1
		# pop_back is O(1); order doesn't matter — we pre-load everything.
		var model_path: String = _warmup_queue.pop_back()
		var mesh_type_name := model_path.to_lower().replace("/", "\\")
		# Re-check registration — another path (e.g. a slow-path merge for an
		# active chunk on a previous frame) may have already registered it.
		if not _static_renderer.get_sub_meshes(mesh_type_name).is_empty():
			_warmup_pending_async.erase(mesh_type_name)
			budget -= 1
			continue
		var register_status := _register_cached_packed_scene(mesh_type_name, model_path)
		if register_status == "ready":
			_warmup_pending_async.erase(mesh_type_name)
			_stats["warmup_registered"] = int(_stats.get("warmup_registered", 0)) + 1
			_clear_temporary_negative_chunks()
		elif register_status == "pending":
			_warmup_queue.push_front(model_path)
		elif _request_prototype_warmup_async(model_path):
			_warmup_queue.push_front(model_path)
		else:
			_warmup_pending_async.erase(mesh_type_name)
			_warmup_failed[mesh_type_name] = true
			_stats["warmup_failed"] = int(_stats.get("warmup_failed", 0)) + 1
		budget -= 1
	if _warmup_queue.is_empty():
		_warmup_dispatched.clear()


func _clear_temporary_negative_chunks() -> void:
	if _negative_chunks.is_empty():
		return
	var cleared := 0
	for key: Vector3i in _negative_chunks.keys():
		var reason := str(_negative_chunks.get(key, ""))
		if reason == "missing_prototype" or reason == "uninitialized":
			_negative_chunks.erase(key)
			cleared += 1
	if cleared > 0:
		Log.debug("hlod", "Cleared %d temporary HLOD negative chunks after prototype warmup" % cleared)


func _register_cached_packed_scene(mesh_type_name: String, model_path: String) -> String:
	if _model_loader == null or not _static_renderer.has_method("request_register_from_packed_scene"):
		return "failed"
	var packed_scene: PackedScene = _model_loader.get_cached_packed_scene(model_path)
	if packed_scene == null:
		return "failed"
	return str(_static_renderer.call("request_register_from_packed_scene", mesh_type_name, packed_scene))

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
		if DU.paging_band_start(active_key.z) >= _visual_end_cap:
			continue
		if camera_xz.distance_to(DU.chunk_center_world(Vector2i(active_key.x, active_key.y), active_key.z)) >= _visual_end_cap:
			continue
		if not _is_within_retention(active_key, camera_xz):
			continue
		desired[active_key] = true
		_mark_sub_cells(Vector2i(active_key.x, active_key.y), 1 << active_key.z, covered_cells)

	var root_level := 2
	var root_size: int = 1 << root_level
	var root_radius: int = DU.paging_ring_radius(root_level)
	var root_aligned := DU.chunk_key_for_cell(camera_cell, root_level)
	for dy in range(-root_radius, root_radius + 1):
		for dx in range(-root_radius, root_radius + 1):
			var root_cell := Vector2i(root_aligned.x + dx * root_size, root_aligned.y + dy * root_size)
			_collect_desired_quadtree(root_cell, root_level, camera_xz, covered_cells, desired)

	return desired






func _collect_desired_quadtree(center_cell: Vector2i, size_level: int, camera_xz: Vector2, covered_cells: Dictionary, desired: Dictionary) -> void:
	if size_level < 0:
		return
	var size: int = 1 << size_level
	if _any_sub_cell_covered(center_cell, size, covered_cells):
		return

	var band_start: float = DU.paging_band_start(size_level)
	var band_end: float = minf(DU.paging_band_end(size_level), _visual_end_cap)
	if band_end <= _visual_begin_floor:
		return

	var bounds := _chunk_distance_bounds(center_cell, size_level, camera_xz)
	var min_dist: float = bounds.x
	var max_dist: float = bounds.y
	if min_dist >= band_end or max_dist < band_start:
		return

	var center_world := DU.chunk_center_world(center_cell, size_level)
	var center_dist: float = camera_xz.distance_to(center_world)
	if center_dist >= band_start and center_dist < band_end:
		var key := Vector3i(center_cell.x, center_cell.y, size_level)
		desired[key] = true
		_mark_sub_cells(center_cell, size, covered_cells)
		return

	if size_level > 0:
		var child_level := size_level - 1
		var child_size: int = 1 << child_level
		for sy in range(2):
			for sx in range(2):
				_collect_desired_quadtree(
					Vector2i(center_cell.x + sx * child_size, center_cell.y + sy * child_size),
					child_level,
					camera_xz,
					covered_cells,
					desired
				)


static func _chunk_distance_bounds(center_cell: Vector2i, size_level: int, camera_xz: Vector2) -> Vector2:
	var size: int = 1 << size_level
	var min_world := DU.cell_to_world_origin(center_cell)
	var max_world := DU.cell_to_world_origin(Vector2i(center_cell.x + size, center_cell.y + size))
	var min_x: float = minf(min_world.x, max_world.x)
	var max_x: float = maxf(min_world.x, max_world.x)
	var min_z: float = minf(min_world.z, max_world.z)
	var max_z: float = maxf(min_world.z, max_world.z)

	var dx := 0.0
	if camera_xz.x < min_x:
		dx = min_x - camera_xz.x
	elif camera_xz.x > max_x:
		dx = camera_xz.x - max_x
	var dz := 0.0
	if camera_xz.y < min_z:
		dz = min_z - camera_xz.y
	elif camera_xz.y > max_z:
		dz = camera_xz.y - max_z
	var min_dist := sqrt(dx * dx + dz * dz)

	var max_dist_sq := 0.0
	for corner: Vector2 in [
		Vector2(min_x, min_z),
		Vector2(min_x, max_z),
		Vector2(max_x, min_z),
		Vector2(max_x, max_z),
	]:
		max_dist_sq = maxf(max_dist_sq, camera_xz.distance_squared_to(corner))
	return Vector2(min_dist, sqrt(max_dist_sq))


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


func _sort_by_chunk_priority(a: Vector3i, b: Vector3i) -> bool:
	var a_desired := a in _last_desired_chunks
	var b_desired := b in _last_desired_chunks
	if a_desired != b_desired:
		return a_desired
	return _sort_by_chunk_distance(a, b)

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


static func _category_eligible(category: int, size_level: int) -> bool:
	match category:
		WorldObjectRecordScript.Category.STATIC, WorldObjectRecordScript.Category.DOOR, WorldObjectRecordScript.Category.ACTIVATOR:
			return true
		WorldObjectRecordScript.Category.CONTAINER:
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


func _process_merge_prepare(state: MergePrepState, start_usec: int, deadline_usec: int = 0) -> String:
	if not _static_renderer or not _bg_processor or _world_object_source == null:
		_negative_chunks[state.key] = "uninitialized"
		return "done"

	var min_size_sq: float = DU.PAGING_MIN_SIZE_SQ
	while state.cy < state.size:
		if Time.get_ticks_usec() - start_usec >= MERGE_QUEUE_SOFT_LIMIT_USEC or _deadline_exhausted(deadline_usec):
			return "pending"

		if not state.refs_loaded:
			var cell_grid := Vector2i(state.center_cell.x + state.cx, state.center_cell.y + state.cy)
			if not state.covered_cells.has(cell_grid):
				state.covered_cells.append(cell_grid)
			state.refs = _world_object_source.get_objects_in_cell(cell_grid, WorldObjectRecordScript.CAP_HLOD)
			state.ref_index = 0
			state.refs_loaded = true

		if state.ref_index >= state.refs.size():
			_advance_prepare_cell(state)
			continue

		var record: RefCounted = state.refs[state.ref_index]
		if not _category_eligible(record.category, state.size_level):
			state.refs_type_rejected += 1
			state.ref_index += 1
			continue

		var model_path: String = record.model_path
		if model_path.is_empty():
			state.ref_index += 1
			continue

		var pos: Vector3 = record.transform.origin
		var ref_transform: Transform3D = record.transform

		var mesh_type_name := model_path.to_lower().replace("/", "\\")
		var payload_key := _make_static_payload_key(model_path)
		var cell_grid := Vector2i(state.center_cell.x + state.cx, state.center_cell.y + state.cy)
		var bucket_key := _make_bucket_key(cell_grid, payload_key)
		state.bucket_total_counts[bucket_key] = int(state.bucket_total_counts.get(bucket_key, 0)) + 1
		var cache_key: StringName = record.object_id
		var scale_f: float = record.scale_scalar
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
		ref_input.source_object_id = record.object_id
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
			ref_input.surface_count = ref_surface_count
			state.inputs.append(ref_input)
			state.source_object_ids[record.object_id] = true
			state.source_bucket_counts[bucket_key] = int(state.source_bucket_counts.get(bucket_key, 0)) + 1
		state.ref_index += 1
		if Time.get_ticks_usec() - start_usec >= MERGE_QUEUE_SOFT_LIMIT_USEC or _deadline_exhausted(deadline_usec):
			return "pending"

	_finish_merge_prepare(state)
	return "done"


func _deadline_exhausted(deadline_usec: int) -> bool:
	return deadline_usec > 0 and Time.get_ticks_usec() >= deadline_usec


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
		"source_object_ids": state.source_object_ids.duplicate(),
		"source_ref_nums": state.source_object_ids.duplicate(),
		"source_bucket_counts": state.source_bucket_counts.duplicate(),
		"complete_bucket_counts": state.source_bucket_counts.duplicate(),
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


## Keep every accepted HLOD render input, but publish only whole MID buckets as
## suppressible. `refs_partial_bucket_rejected` now means "accepted for HLOD
## render, not accepted for MID bucket suppression."
func _update_complete_bucket_counts(state: MergePrepState) -> void:
	if state.inputs.is_empty() or state.bucket_total_counts.is_empty():
		state.source_bucket_counts.clear()
		return

	var complete_bucket_counts: Dictionary = {}
	for bucket_key_value: Variant in state.source_bucket_counts.keys():
		var bucket_key := str(bucket_key_value)
		if bucket_key.is_empty():
			continue
		var accepted_count: int = int(state.source_bucket_counts.get(bucket_key_value, 0))
		var total_count: int = int(state.bucket_total_counts.get(bucket_key, 0))
		if total_count > 0 and accepted_count >= total_count:
			complete_bucket_counts[bucket_key] = accepted_count
		else:
			state.refs_partial_bucket_rejected += accepted_count
			continue

	state.source_bucket_counts = complete_bucket_counts


func _apply_surface_budget(state: MergePrepState) -> void:
	if state.inputs.is_empty() or MAX_RUNTIME_CHUNK_SURFACES <= 0:
		return
	var surface_total := 0
	for input_value: Variant in state.inputs:
		var input: Kernel.RefInput = input_value as Kernel.RefInput
		if input == null:
			continue
		var surface_count := maxi(1, input.surface_count)
		surface_total += surface_count
	state.surface_estimate = surface_total


func _finish_merge_prepare(state: MergePrepState) -> void:
	var key := state.key
	_stats["total_refs_skipped"] += state.refs_skipped
	_stats["refs_type_rejected"] += state.refs_type_rejected
	_stats["size_cache_hits"] += state.size_cache_hits
	_apply_surface_budget(state)
	_stats["refs_size_rejected"] += state.refs_size_rejected
	_stats["refs_surface_rejected"] += state.refs_surface_rejected
	_update_complete_bucket_counts(state)
	_stats["refs_partial_bucket_rejected"] += state.refs_partial_bucket_rejected

	# Cost-benefit minimum — sparse chunks aren't worth merging
	if state.inputs.size() < MIN_REFS_TO_MERGE:
		_negative_chunks[key] = _negative_reason_for_state(state)
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


func _negative_reason_for_state(state: MergePrepState) -> String:
	if state.bucket_total_counts.is_empty():
		return "empty"
	if state.inputs.size() > 0:
		return "sparse"
	if state.refs_surface_rejected > 0:
		return "surface_cap"
	if state.refs_skipped > 0:
		return "missing_prototype"
	if state.refs_partial_bucket_rejected > 0:
		return "partial_bucket"
	if state.refs_size_rejected > 0 or state.refs_type_rejected > 0:
		return "filtered"
	return "empty"


## Worker thread entry point. Runs merge kernel, posts result to completion queue.
## All data pre-collected — no scene tree or ESMManager access here.
## `key.z` is threaded through as `size_level` to the kernel (cost-benefit uses it).
func _merge_chunk_worker(key: Vector3i, generation: int, inputs: Array, chunk_origin: Vector3) -> Dictionary:
	var mesh := Kernel.merge_refs(inputs, chunk_origin, key.z, RUNTIME_FORCE_MERGE_ELIGIBLE_REFS)
	if not mesh:
		return {"key": key, "generation": generation, "mesh": null, "bytes": 0}

	var mesh_stats := Kernel.collect_mesh_stats(mesh)
	var bytes := int(mesh_stats.get("bytes", 0))
	if bytes <= 0:
		bytes = Kernel.estimate_mesh_bytes(mesh)
		mesh_stats["bytes"] = bytes

	_completed_mutex.lock()
	_completed_queue.append({"key": key, "generation": generation, "mesh": mesh, "bytes": bytes, "mesh_stats": mesh_stats})
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
func _create_rs_instance(key: Vector3i, mesh: ArrayMesh, estimated_bytes: int, mesh_stats: Dictionary = {}) -> bool:
	if not _scenario.is_valid() or not mesh:
		return false

	var rs := RenderingServer
	var rid := rs.instance_create()
	rs.instance_set_base(rid, mesh.get_rid())
	rs.instance_set_scenario(rid, _scenario)

	# Place at chunk center (vertices are in chunk-local space)
	rs.instance_set_transform(rid, Transform3D(Basis.IDENTITY, _chunk_origin_world(key)))

	# Tier-specific visibility_range (plan §4/§9), clamped by the runtime
	# visual-owner floor so HLOD begins exactly at the MID handoff.
	_set_chunk_visibility_range(rid, key)
	rs.instance_geometry_set_lod_bias(rid, 1.0)

	if not _globally_visible:
		rs.instance_set_visible(rid, false)

	var data := PagingChunkData.new()
	data.key = key
	data.instance_rid = rid
	data.mesh = mesh
	data.surface_count = int(mesh_stats.get("surface_count", mesh.get_surface_count()))
	data.material_count = int(mesh_stats.get("material_count", data.surface_count))
	data.null_material_surface_count = int(mesh_stats.get("null_material_surface_count", _count_null_material_surfaces(mesh)))
	data.default_proxy_surface_count = int(mesh_stats.get("default_proxy_surface_count", 0))
	data.source_null_material_surfaces = int(mesh_stats.get("source_null_material_surfaces", 0))
	data.overflow_proxy_surfaces = int(mesh_stats.get("overflow_proxy_surfaces", 0))
	data.vertex_count = int(mesh_stats.get("vertex_count", estimated_bytes / 72))
	data.index_count = int(mesh_stats.get("index_count", 0))
	data.estimated_bytes = estimated_bytes
	var manifest: Dictionary = _mesh_manifests.get(key, {})
	if not manifest.is_empty():
		data.covered_cells = (manifest.get("covered_cells", []) as Array).duplicate()
		data.source_object_ids = (manifest.get("source_object_ids", manifest.get("source_ref_nums", {})) as Dictionary).duplicate()
		data.source_ref_nums = data.source_object_ids.duplicate()
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
	var band_end: float = minf(DU.paging_band_end(key.z), _visual_end_cap)
	var visual_begin: float = maxf(band_start, _visual_begin_floor)
	if visual_begin >= band_end:
		RenderingServer.instance_set_visible(rid, false)
		return
	var fade_margin := TIER_FADE_MARGIN if _visibility_fade_enabled else 0.0
	var fade_mode := RenderingServer.VISIBILITY_RANGE_FADE_SELF if _visibility_fade_enabled else RenderingServer.VISIBILITY_RANGE_FADE_DISABLED
	RenderingServer.instance_geometry_set_visibility_range(
		rid,
		visual_begin, band_end,
		fade_margin, fade_margin,
		fade_mode
	)
	RenderingServer.instance_set_visible(rid, _globally_visible)


func _chunk_has_visual_range(key: Vector3i) -> bool:
	var band_start: float = DU.paging_band_start(key.z)
	var band_end: float = minf(DU.paging_band_end(key.z), _visual_end_cap)
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

		if oldest in _active_chunks:
			# Active chunks are visible HLOD ownership, not disposable cache.
			# Touch them to the back and keep looking for inactive cache entries.
			_lru_order.append(oldest)
			var has_inactive := false
			for candidate: Vector3i in _lru_order:
				if candidate not in _active_chunks:
					has_inactive = true
					break
			if not has_inactive:
				break
			continue

		_evict_cached_mesh(oldest)


func _evict_cached_mesh(key: Vector3i) -> void:
	if key not in _mesh_cache:
		_cached_publish_keys.erase(key)
		return
	var evicted_bytes: int = _mesh_sizes.get(key, 0)
	_cache_used_bytes = maxi(0, _cache_used_bytes - evicted_bytes)
	_mesh_cache.erase(key)
	_mesh_sizes.erase(key)
	_mesh_manifests.erase(key)
	_mesh_stats_cache.erase(key)
	_cached_publish_keys.erase(key)

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
	_stats["cached_publish_queue_size"] = _cached_publish_queue.size()
	_stats["cache_entries"] = _mesh_cache.size()
	_stats["cache_bytes"] = _cache_used_bytes
	var dt0 := 0
	var dt1 := 0
	var dt2 := 0
	for key: Vector3i in _last_desired_chunks:
		match key.z:
			0: dt0 += 1
			1: dt1 += 1
			2: dt2 += 1
	_stats["desired_chunks"] = _last_desired_chunks.size()
	_stats["predictive_desired_chunks"] = _last_prefetch_chunks.size()
	_stats["desired_chunks_tier_0"] = dt0
	_stats["desired_chunks_tier_1"] = dt1
	_stats["desired_chunks_tier_2"] = dt2

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
			for object_id: Variant in chunk_data.source_object_ids.keys():
				active_source_refs[object_id] = true
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
	var total_null_material_surfaces := 0
	var total_default_proxy_surfaces := 0
	var total_source_null_material_surfaces := 0
	var total_overflow_proxy_surfaces := 0
	var runtime_surface_budget_chunks := 0
	var total_vertices := 0
	var total_indices := 0
	var max_surfaces := 0
	var max_materials := 0
	var max_vertices := 0
	var max_indices := 0
	var surface_histogram: Dictionary = {}
	var material_histogram: Dictionary = {}
	for key: Vector3i in _active_chunks:
		var data: PagingChunkData = _active_chunks[key]
		total_surfaces += data.surface_count
		total_materials += data.material_count
		total_null_material_surfaces += data.null_material_surface_count
		total_default_proxy_surfaces += data.default_proxy_surface_count
		total_source_null_material_surfaces += data.source_null_material_surfaces
		total_overflow_proxy_surfaces += data.overflow_proxy_surfaces
		if data.overflow_proxy_surfaces > 0:
			runtime_surface_budget_chunks += 1
		total_vertices += data.vertex_count
		total_indices += data.index_count
		max_surfaces = maxi(max_surfaces, data.surface_count)
		max_materials = maxi(max_materials, data.material_count)
		max_vertices = maxi(max_vertices, data.vertex_count)
		max_indices = maxi(max_indices, data.index_count)
		_increment_histogram(surface_histogram, data.surface_count)
		_increment_histogram(material_histogram, data.material_count)
	_stats["total_chunk_surfaces"] = total_surfaces
	_stats["total_chunk_materials"] = total_materials
	_stats["visible_hlod_draw_calls"] = total_surfaces
	_stats["null_material_surface_count"] = total_null_material_surfaces
	_stats["default_proxy_surface_count"] = total_default_proxy_surfaces
	_stats["source_null_material_surfaces"] = total_source_null_material_surfaces
	_stats["overflow_proxy_surfaces"] = total_overflow_proxy_surfaces
	_stats["runtime_surface_budget_proxy_chunks"] = runtime_surface_budget_chunks
	_stats["chunk_surface_histogram"] = surface_histogram
	_stats["chunk_material_histogram"] = material_histogram
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
	_stats["warmup_pending_async"] = _warmup_pending_async.size()
	_stats["preparing_chunks"] = _prep_queue.size()
	_stats["negative_chunks"] = _negative_chunks.size()
	var negative_empty := 0
	var negative_sparse := 0
	var negative_filtered := 0
	var negative_failed := 0
	var negative_surface := 0
	for key: Vector3i in _negative_chunks:
		match str(_negative_chunks.get(key, "unknown")):
			"empty":
				negative_empty += 1
			"sparse":
				negative_sparse += 1
			"filtered", "partial_bucket":
				negative_filtered += 1
			"surface_cap":
				negative_surface += 1
			_:
				negative_failed += 1
	_stats["negative_empty_chunks"] = negative_empty
	_stats["negative_sparse_chunks"] = negative_sparse
	_stats["negative_filtered_chunks"] = negative_filtered
	_stats["negative_failed_chunks"] = negative_failed
	_stats["negative_surface_cap_chunks"] = negative_surface
	_stats["merge_queue_size"] = _merge_queue.size()
	_stats["visual_begin_floor"] = _visual_begin_floor
	_stats["visual_end_cap"] = _visual_end_cap
	_stats["visibility_fade_enabled"] = _visibility_fade_enabled

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


static func _count_null_material_surfaces(mesh: ArrayMesh) -> int:
	if not mesh:
		return 0
	var count := 0
	for surface_idx in range(mesh.get_surface_count()):
		if mesh.surface_get_material(surface_idx) == null:
			count += 1
	return count


static func _increment_histogram(histogram: Dictionary, value: int) -> void:
	var bucket := _histogram_bucket(value)
	histogram[bucket] = int(histogram.get(bucket, 0)) + 1


static func _histogram_bucket(value: int) -> String:
	if value <= 1:
		return "1"
	if value <= 4:
		return "2-4"
	if value <= 8:
		return "5-8"
	if value <= 16:
		return "9-16"
	if value <= 32:
		return "17-32"
	if value <= 64:
		return "33-64"
	if value <= 128:
		return "65-128"
	if value <= 256:
		return "129-256"
	return "257+"


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
	if _model_loader:
		return _model_loader.has_disk_cached(model_path)
	var scene_path := _model_cache_scene_path(model_path)
	return not scene_path.is_empty() and FileAccess.file_exists(scene_path)


## Load a prototype from the already-warmed model cache.
## Production HLOD goes through ModelLoader so disk existence and threaded
## ResourceLoader ownership remain single-sourced. The direct path is retained
## only for isolated tests that construct ObjectPaging without a ModelLoader.
func _load_prototype_from_cache(model_path: String) -> Node3D:
	if _model_loader:
		if _model_loader.get_cached_packed_scene(model_path) == null:
			return null
		return _model_loader.get_cached(model_path)

	var scene_path := _model_cache_scene_path(model_path)
	if scene_path.is_empty() or not FileAccess.file_exists(scene_path):
		return null

	var packed_scene := ResourceLoader.load(scene_path, "PackedScene") as PackedScene
	if not packed_scene:
		return null

	return packed_scene.instantiate() as Node3D


func _request_prototype_warmup_async(model_path: String) -> bool:
	if _model_loader == null:
		return false
	var mesh_type_name := model_path.to_lower().replace("/", "\\")
	if mesh_type_name in _warmup_pending_async:
		return true
	if _model_loader.has_model(model_path) and _model_loader.get_cached_packed_scene(model_path) == null:
		return false
	var was_loading := _model_loader.is_loading_async(model_path)
	var requested := _model_loader.request_model_async(model_path, "", Callable(), false)
	if requested:
		_warmup_pending_async[mesh_type_name] = true
		if not was_loading:
			_stats["warmup_async_requests"] = int(_stats.get("warmup_async_requests", 0)) + 1
	return requested

#endregion
