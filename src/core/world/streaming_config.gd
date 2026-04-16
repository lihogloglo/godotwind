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

## NEAR TIER BURST LOADING - Moderate priority for critical cells
## When loading the player's current cell or immediately adjacent cells,
## use these limits to populate objects faster without exceeding frame budget.
## Reduced from 50ms/300 objects to stay within frame budget and prevent stuttering.
const NEAR_BURST_BUDGET_MS := 12.0            ## Stay within frame budget
const NEAR_BURST_MAX_INSTANTIATIONS := 100    ## 2x normal, not 6x (was 300)
const NEAR_BURST_DISTANCE := 100.0            ## Only for very close objects (was 250)

## Delay before rebuilding impostor texture array (batching)
## Waits for multiple textures to finish loading before rebuilding
const TEXTURE_REBUILD_DELAY_MS := 300.0

## Maximum number of MultiMesh rebuilds per second
## Prevents per-frame rebuilding during heavy loading
const MAX_MULTIMESH_REBUILDS_PER_SEC := 4.0

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

## Pre-warm batch count for common mesh types
const BATCH_PREWARM_COUNT := 20

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
# STREAMING MODE - FULL_AAA ONLY (Simplified)
# =============================================================================
# NOTE: NEAR_ONLY mode has been removed. All streaming now uses FULL_AAA mode
# with all tiers active: NEAR + MID + FAR with LOD and impostors up to 5km.
# This simplifies the codebase by removing conditional tier activation.
