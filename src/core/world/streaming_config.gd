class_name StreamingConfig
extends RefCounted

## Centralized configuration for the world streaming system
##
## All tunable parameters for LOD, streaming, and performance are defined here.
## Modify these values to adjust streaming behavior globally.
##
## Core tier distance constants are defined in DistanceUtils (single source of truth).
## This file references them directly to avoid duplication.
##
## Usage:
##   var near_distance = StreamingConfig.NEAR_END
##   var fade_margin = StreamingConfig.FADE_MARGIN_NEAR

# Single source of truth for distance constants
const DU := preload("res://src/core/world/distance_utils.gd")

# =============================================================================
# DISTANCE THRESHOLDS (referenced from DistanceUtils - single source of truth)
# =============================================================================

## Distance where NEAR tier ends and MID tier begins (meters)
## NEAR tier: Full Node3D with physics and collision
const NEAR_END := DU.NEAR_END  # 150.0

## Distance where MID tier ends and FAR tier begins (meters)
## MID tier: one RS instance per object, engine-driven sub-LOD from embedded ArrayMesh surface_lod chain
const MID_END := DU.MID_END  # 500.0

## Distance where FAR tier ends and HORIZON begins (meters)
## FAR tier: Octahedral impostor billboards
const FAR_END := DU.FAR_END  # 5000.0

# =============================================================================
# SCREEN-SPACE LOD (post-B-wide refactor)
# =============================================================================

## Viewport `mesh_lod_threshold` — pixel-space size delta at which the engine
## swaps LOD levels. Lower = higher quality, higher = more aggressive LOD.
## 1.0 px is Godot's "perceptually lossless" default. Tuned per-preset below.
const DEFAULT_MESH_LOD_THRESHOLD: float = 1.0

## Default per-instance LOD bias. >1.0 keeps higher detail further out, <1.0
## accelerates LOD drops. Per-type overrides can be added in a registry later.
const DEFAULT_LOD_BIAS: float = 1.0

# =============================================================================
# CROSSFADE MARGINS
# =============================================================================

## Canonical render→impostor tier handoff crossfade margin (500m boundary).
const FADE_MARGIN_RENDER_FAR := DU.FADE_MARGIN_RENDER_FAR  # 20.0

## Generic fade margin (legacy default — FAR-tier impostor renderer uses this)
const FADE_MARGIN := DU.FADE_MARGIN  # 10.0

# =============================================================================
# HYSTERESIS (Anti-Flickering)
# =============================================================================

## Hysteresis at NEAR boundary prevents rapid tier switching
## Objects must move NEAR_END + HYSTERESIS_NEAR before switching back
const HYSTERESIS_NEAR := 40.0

## Hysteresis at MID boundary
const HYSTERESIS_MID := 60.0

## Hysteresis at FAR boundary
const HYSTERESIS_FAR := 150.0

# =============================================================================
# MID→NEAR PROMOTION
# =============================================================================

## Distance at which NEAR Node3Ds are pre-created (invisible until within 155m)
## 100m before the 150m crossfade zone — gives plenty of time to instantiate
const PROMOTION_DISTANCE := 250.0

## Distance at which NEAR Node3Ds are freed (hysteresis prevents oscillation)
const DEMOTION_DISTANCE := 280.0

## Time budget per promotion tick (microseconds)
const PROMOTION_BUDGET_USEC := 3000.0  # 3ms

## Run promotion every N frames (lower = smoother, higher = cheaper)
const PROMOTION_FRAME_INTERVAL := 2

## Cell radius for promotion scan. 3 = 7×7 grid = 351m coverage (>250m diagonal)
const PROMOTION_CELL_RADIUS := 3

## AABB max dimension threshold for runtime MID-worthy upgrade (meters).
## Objects larger than this in any axis get RS instances even if the prefix filter missed them.
## 2.0m catches mushroom trees, shacks, walls — skips small clutter.
const AABB_MID_WORTHY_THRESHOLD := 2.0

# =============================================================================
# TIME BUDGETS (milliseconds per frame)
# =============================================================================

## Maximum time per frame for processing cell loading queue
## Prevents frame drops during heavy streaming
const CELL_QUEUE_BUDGET_MS := 2.0

## Maximum time per frame for instantiating NEAR tier objects (default mode)
## UNIFIED BUDGET: This is the single source of truth for frame budgets
## Set to 8ms to leave headroom for rendering (targeting 60 FPS = 16.67ms total)
const INSTANTIATION_BUDGET_MS := 8.0

## Dynamic budget: fraction of frame time to allocate to instantiation
## Scales with actual FPS — more budget at low FPS, less at high FPS
const INSTANTIATION_BUDGET_FRACTION := 0.48  ## 48% of frame time
const INSTANTIATION_BUDGET_MIN_MS := 2.0     ## Floor: never go below 2ms (even at 240 FPS)
const INSTANTIATION_BUDGET_MAX_MS := 16.0    ## Cap: never exceed 16ms (even at 15 FPS)

## Post-startup instantiation budget (after loading screen hides).
## 48% of frame time (~9.6ms at 50 FPS) causes a death spiral: render + streaming > 16.67ms
## → FPS stays at 50 → budget stays high → queue never drains → FPS stays low.
## Fix: fixed 4ms post-startup gives ~12ms for rendering → 60+ FPS while queue drains.
const POST_STARTUP_INSTANTIATION_BUDGET_MS := 4.0

## Main-thread drain budget for ModelLoader async completions inside the
## interactive publish lane. The threaded load may finish off-thread, but
## load_threaded_get(), PackedScene cache promotion, and callback dispatch still
## happen on the main thread and must not consume the whole publish budget.
const MODEL_LOADER_DRAIN_BUDGET_MS := 1.0
const STARTUP_MODEL_LOADER_DRAIN_BUDGET_MS := 4.0

## Async cell request classification budget. This is the main-thread pass that
## walks CellReferences, resolves ESM records, builds CellPayload buckets, and
## starts/dedupes model disk requests. It used to run all-at-once in
## pending_loads_async when a cell boundary was crossed.
const CELL_REQUEST_CLASSIFY_BUDGET_MS := 1.0
const STARTUP_CELL_REQUEST_CLASSIFY_BUDGET_MS := 3.0
const CELL_REQUEST_CLASSIFY_MAX_REFS := 48
const STARTUP_CELL_REQUEST_CLASSIFY_MAX_REFS := 128

## Per-cell static collision lane budgets. Dispatch is cheap classification +
## WorkerThreadPool submission; finalize is the atomic ConcavePolygonShape3D
## BVH publish and only runs when the visual/attach queues are idle.
const CELL_STATIC_COLLISION_DISPATCH_BUDGET_MS := 0.5
const CELL_STATIC_COLLISION_DISPATCH_MAX_PER_FRAME := 1
const CELL_STATIC_COLLISION_FINALIZE_MIN_REMAINING_MS := 2.0
const CELL_STATIC_COLLISION_FINALIZE_MAX_TRIS_PER_FRAME := 1000

## Main-thread static prototype prepare budget. This lane registers renderer
## prototypes and creates empty PrototypeBatch/MultiMesh buckets before refs
## reach the activation drain, avoiding cold work inside add_instance().
const STATIC_PREPARE_ENABLED := true
const STATIC_PREPARE_BUDGET_MS := 2.0
const STATIC_PREPARE_MAX_PER_FRAME := 1

## Worker dispatch itself is main-thread work: ESM/cache checks plus
## WorkerThreadPool.add_task calls. Keep it bounded now that static prepare can
## make hundreds of queued refs eligible for Phase E in the same frame.
const WORKER_DISPATCH_BUDGET_US := 1000
const WORKER_DISPATCH_MAX_PER_FRAME := 64

## Scene-tree child attach budget for interactive Node3Ds produced by the
## instantiation queue. Keeps add_child() work explicit instead of dumping
## large batches into idle-time call_deferred bursts.
const CHILD_ATTACH_BUDGET_MS := 1.0
## Keep this low: one add_child() can be expensive when the detached subtree
## enters the scene tree, so the time budget can only stop after that call
## returns. A small count cap prevents 20 heavy nodes from stacking.
const CHILD_ATTACH_MAX_PER_FRAME := 1

## NEAR TIER BURST LOADING - Moderate priority for critical cells
## When loading the player's current cell or immediately adjacent cells,
## use these limits to populate objects faster without exceeding frame budget.
## Reduced from 50ms/300 objects to stay within frame budget and prevent stuttering.
const NEAR_BURST_BUDGET_MS := 4.0             ## Stability-first: do not override runtime budget
const NEAR_BURST_MAX_INSTANTIATIONS := 16     ## Keep close-object publish bounded
const NEAR_BURST_DISTANCE := 0.0              ## Disabled until visual stability is restored

## Delay before rebuilding impostor texture array (batching)
## Waits for multiple textures to finish loading before rebuilding
const TEXTURE_REBUILD_DELAY_MS := 300.0

## Maximum number of MultiMesh rebuilds per second
## Prevents per-frame rebuilding during heavy loading
const MAX_MULTIMESH_REBUILDS_PER_SEC := 4.0

## Maximum PrototypeRegistry batches to cull/upload per frame after static
## renderer churn. 0 means full pass. During NEAR stabilization, keep this
## bounded so one unload/add dirty sweep cannot spend 4-15 ms in
## MultiMesh.set_buffer work on the same frame as cell transition work.
const STATIC_CULL_BATCH_BUDGET_PER_FRAME: int = 12

## Godot 4.6 has proven sensitive to replacing a world-scoped MultiMesh buffer
## in the same frame as unload-driven slot hide/release churn. While any
## static renderer unload queue is active, pause PrototypeRegistry uploads; once
## the unload queues go quiet, let this many frames pass before the next upload.
const STATIC_CULL_UPLOAD_DEFER_FRAMES_AFTER_UNLOAD: int = 4

## Native C# packing kernel for world-scoped static MultiMesh culling.
##
## Default-disabled after the 2026-04-28 smooth-baseline run crashed in
## PrototypeBatch._cull_native() while uploading the C#-returned buffer via
## RenderingServer.multimesh_set_buffer. The GDScript fallback still uses the
## same RenderingServer/MultiMesh render path, but keeps the packed buffer owned
## by GDScript until the native handoff is reworked and proven stable.
const STATIC_CULL_NATIVE_ENABLED: bool = false

# =============================================================================
# MEMORY LIMITS
# =============================================================================

## Maximum number of pooled Node3D objects
## Prevents unbounded memory growth
const MAX_POOLED_OBJECTS := 2048

## Maximum number of impostor textures in texture array
## 256 layers × 256×256 RGBA8 = ~64 MB VRAM (vs ~1 GB at 512×512×512)
const MAX_IMPOSTOR_TEXTURES := 256

## Warning threshold (90% of max)
const IMPOSTOR_TEXTURE_WARNING_THRESHOLD := 230

## Maximum number of NEAR tier cells loaded simultaneously
## NEAR tier: ~150m radius = ~13 cells (117m cell size)
const MAX_NEAR_CELLS := 13

## Maximum number of MID tier cells loaded simultaneously
## MID tier: 150-500m ring
const MAX_MID_CELLS := 80

## Maximum number of FAR tier cells loaded simultaneously
## FAR tier: 500-5000m ring
const MAX_FAR_CELLS := 250

# =============================================================================
# CELL DIMENSIONS
# =============================================================================

## Cell size in world units (meters)
## Morrowind standard: ~117.03m (8192 Morrowind units / 70 units per meter)
const CELL_SIZE := DU.CELL_SIZE_METERS

# =============================================================================
# QUALITY PRESETS
# =============================================================================

enum QualityPreset {
	LOW,      ## Minimum settings for low-end hardware
	MEDIUM,   ## Balanced settings (default)
	HIGH,     ## Higher quality for mid-range hardware
	ULTRA     ## Maximum quality for high-end hardware
}

## Quality preset configurations.
##
## Post-B-wide refactor: presets drive `mesh_lod_threshold` (viewport-level
## screen-space LOD bias) + cell counts + FAR tier draw distance. Sub-LOD
## distance overrides are gone — LOD selection is fully automatic.
##
## `mesh_lod_threshold` is in pixels — the engine swaps LOD levels when the
## projected screen-size difference between adjacent LODs exceeds this value.
## Lower = higher quality, higher = more aggressive LOD drops.
static func get_quality_preset_config(preset: QualityPreset) -> Dictionary:
	match preset:
		QualityPreset.LOW:
			return {
				"mesh_lod_threshold": 4.0,
				"near_end": 100.0,
				"mid_end": 300.0,
				"far_end": 2000.0,
				"max_near_cells": 8,
				"max_mid_cells": 40,
				"max_far_cells": 100
			}
		QualityPreset.MEDIUM:
			return {
				"mesh_lod_threshold": 2.0,
				"near_end": NEAR_END,
				"mid_end": MID_END,
				"far_end": FAR_END,
				"max_near_cells": MAX_NEAR_CELLS,
				"max_mid_cells": MAX_MID_CELLS,
				"max_far_cells": MAX_FAR_CELLS
			}
		QualityPreset.HIGH:
			return {
				"mesh_lod_threshold": 1.0,
				"near_end": 200.0,
				"mid_end": 750.0,
				"far_end": 7500.0,
				"max_near_cells": 20,
				"max_mid_cells": 120,
				"max_far_cells": 350
			}
		QualityPreset.ULTRA:
			return {
				"mesh_lod_threshold": 0.5,
				"near_end": 300.0,
				"mid_end": 1000.0,
				"far_end": 10000.0,
				"max_near_cells": 30,
				"max_mid_cells": 160,
				"max_far_cells": 500
			}

	return get_quality_preset_config(QualityPreset.MEDIUM)

# =============================================================================
# EVENT-DRIVEN FADE ANIMATION (Industry-Standard)
# =============================================================================

## Time-based fade animation duration (seconds)
## Industry-standard: 0.3-0.5 seconds for smooth transitions
## This is purely time-based, not distance-based, for consistent visual quality
const FADE_DURATION := 0.3

## Maximum concurrent fade animations
## Prevents runaway processing when moving fast through many objects
const MAX_CONCURRENT_FADES := 200

## Teleport detection threshold (meters)
## If camera moves more than this in one frame, skip fades and pop instantly
## Matches user preference for "instant pop" on fast travel/debug flying
const TELEPORT_THRESHOLD := 100.0
const TELEPORT_THRESHOLD_SQ := TELEPORT_THRESHOLD * TELEPORT_THRESHOLD

# =============================================================================
# BUDGETED UNLOADING
# =============================================================================

## Maximum time per frame for unloading cell children (milliseconds)
## Prevents frame spikes when multiple cells exit the load radius at once
const UNLOAD_BUDGET_MS := 4.0

## Maximum children to remove per unloading cell per frame
## Caps work even if individual queue_free() calls are fast
const UNLOAD_BATCH_SIZE := 30

# =============================================================================
# OBJECT POOL PRE-WARMING
# =============================================================================

## Enable automatic pool pre-warming when cells are discovered
## Pre-creates instances before they're needed for faster instantiation
const POOL_PREWARM_ENABLED := true

## Maximum instances to pre-warm per model type
const POOL_PREWARM_MAX_PER_MODEL := 10

## Maximum total instances to pre-warm per frame
const POOL_PREWARM_MAX_PER_FRAME := 20

## Distance threshold for triggering pre-warm (slightly beyond NEAR_END)
## Objects within this distance get their pools pre-warmed
const POOL_PREWARM_DISTANCE := 250.0

# =============================================================================
# LODMULTIMESHBATCHER OPTIMIZATION
# =============================================================================

## Initial capacity for each MultiMesh batch
## Higher = fewer growth operations, more memory
## 256 is good balance for typical Morrowind object density
const INITIAL_BATCH_CAPACITY := 256

## Maximum batch capacity before splitting into new batch
const MAX_BATCH_CAPACITY := 4096

# =============================================================================
# DIAGNOSTIC FLAGS
# =============================================================================

## Enable debug logging for streaming system
const DEBUG_LOGGING := false

## Enable debug visualization overlays
const DEBUG_VISUALIZATION := false

## Enable performance profiling markers
const ENABLE_PROFILING := true

# =============================================================================
# CELL PRELOADER (velocity-extrapolated cache warm — research doc §8)
# =============================================================================
# Preloaded cells have their ResourceLoader (PackedScene) warmed + prototype
# pre-registration dispatched BEFORE the cell enters active load radius. When
# the cell actually loads, the data phase is a cache hit, instantiation runs
# fast-path. LRU-bounded memory; entries expire after EXPIRY_DELAY_MS.
# OpenMW defaults; see research doc §8.3 + §8.4.

## LRU expiry — cells untouched for this many ms are candidates for eviction
## (if cache size exceeds MIN_CACHE_CELLS). 5 s matches OpenMW default.
const PRELOAD_EXPIRY_DELAY_MS: int = 5000

## Minimum cache size — never evict below this, even if all entries are stale.
## Keeps a baseline warm window around the camera for back-tracking.
const PRELOAD_MIN_CACHE_CELLS: int = 12

## Hard cap on preload cache size. 20 cells × ~79 refs × ~50 KB PackedScene
## ≈ 80 MB peak. Back-pressures new preloads until eviction catches up.
const PRELOAD_MAX_CACHE_CELLS: int = 20

## Base prediction window (seconds). Speed-scaled at runtime per §8.3 formula:
## `t_predict = clamp(PRELOAD_PREDICTION_TIME_S / max(speed, 1.0), 0.3, 4.0)`.
## 1.0 s is the OpenMW baseline; empirically matches the ResourceLoader warm
## time per cell (~0.8–1.0 s) on the current machine.
const PRELOAD_PREDICTION_TIME_S: float = 1.0

# =============================================================================
# PHASE 0 ABLATION FLAGS (runtime-settable via cmdline)
# =============================================================================
# Set by world_explorer._ready() from command-line args:
#   --disable-jolt-attach   → skip per-object StaticBody3D / CollisionShape3D
#                             enable + carryable RigidBody3D conversion +
#                             interior-pocket _generate_static_collision.
#                             Isolates Jolt broadphase cost from streaming pipe.
#   --disable-fade-pool     → reserved ablation flag. The bespoke fade-material
#                             pool was deleted after Phase 0 ablation showed it
#                             cost ~50 FPS at high object counts. Engine-native
#                             VISIBILITY_RANGE_FADE_SELF (cell_manager.gd)
#                             handles the NEAR→MID crossfade. Flag kept as a
#                             false-default hook for future diagnostic work.
## Default false — always compile clean, toggled only by boot flag.
static var DEBUG_DISABLE_JOLT_ATTACH: bool = false
static var DEBUG_DISABLE_FADE_POOL: bool = false
static var DEBUG_DISABLE_CELL_STATIC_COLLISION: bool = false

## Phase F off-thread prototype pre-registration.
##
## Default-disabled after the 2026-04-28 fresh benchmark crashed before writing
## data with Phase F enabled, while the same route completed with
## --disable-phase-f-prereg. The worker path instantiates PackedScenes and
## registers prototypes off-thread; that is too crash-prone on this Godot 4.6
## setup. Keep the flag as an opt-in research switch via --enable-phase-f-prereg.
static var DEBUG_DISABLE_PHASE_F_PREREG: bool = true

# =============================================================================
# STREAMING MODE - FULL_AAA ONLY (Simplified)
# =============================================================================
# NOTE: NEAR_ONLY mode has been removed. All streaming now uses FULL_AAA mode
# with all tiers active: NEAR + MID + FAR with LOD and impostors up to 5km.
# This simplifies the codebase by removing conditional tier activation.
