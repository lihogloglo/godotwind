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
## MID tier: MultiMesh LOD instances (3 levels)
const MID_END := DU.MID_END  # 500.0

## Distance where FAR tier ends and HORIZON begins (meters)
## FAR tier: Octahedral impostor billboards
const FAR_END := DU.FAR_END  # 5000.0

# =============================================================================
# LOD LEVELS WITHIN MID TIER
# =============================================================================

## MID tier is subdivided into 3 LOD levels
## LOD1: Highest detail in MID tier
const MID_LOD1_START := NEAR_END
const MID_LOD1_END := 250.0

## LOD2: Medium detail
const MID_LOD2_START := 250.0
const MID_LOD2_END := 375.0

## LOD3: Lowest detail in MID tier (transitions to impostor)
const MID_LOD3_START := 375.0
const MID_LOD3_END := MID_END

# =============================================================================
# CROSSFADE MARGINS
# =============================================================================

## Per-boundary crossfade margins (tiered: smaller at close range where mismatch is visible)
## Total crossfade zone = 2x margin value
const FADE_MARGIN_NEAR := DU.FADE_MARGIN_NEAR_LOD1  # 5.0 — NEAR/LOD1 at 150m
const FADE_MARGIN_MID := DU.FADE_MARGIN_LOD1_LOD2   # 10.0 — LOD1/LOD2 at 250m
const FADE_MARGIN_FAR := DU.FADE_MARGIN_LOD3_FAR    # 20.0 — LOD3/FAR at 500m

## Generic fade margin (legacy default)
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
## GPU hardware limit (most GPUs support 512+ layers)
const MAX_IMPOSTOR_TEXTURES := 512

## Warning threshold (90% of max)
const IMPOSTOR_TEXTURE_WARNING_THRESHOLD := 450

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
## Morrowind standard: 117.12m (8192 Morrowind units)
const CELL_SIZE := 117.12

## Spatial hash cell size for ObjectStreamer (meters)
## Used for fast nearby object queries
const SPATIAL_HASH_CELL_SIZE := 50.0

# =============================================================================
# QUALITY PRESETS
# =============================================================================

enum QualityPreset {
	LOW,      ## Minimum settings for low-end hardware
	MEDIUM,   ## Balanced settings (default)
	HIGH,     ## Higher quality for mid-range hardware
	ULTRA     ## Maximum quality for high-end hardware
}

## Quality preset configurations
## Returns dictionary with distance overrides for the given preset
static func get_quality_preset_config(preset: QualityPreset) -> Dictionary:
	match preset:
		QualityPreset.LOW:
			return {
				"near_end": 100.0,
				"mid_end": 300.0,
				"far_end": 2000.0,
				"max_near_cells": 8,
				"max_mid_cells": 40,
				"max_far_cells": 100
			}
		QualityPreset.MEDIUM:
			return {
				"near_end": NEAR_END,
				"mid_end": MID_END,
				"far_end": FAR_END,
				"max_near_cells": MAX_NEAR_CELLS,
				"max_mid_cells": MAX_MID_CELLS,
				"max_far_cells": MAX_FAR_CELLS
			}
		QualityPreset.HIGH:
			return {
				"near_end": 200.0,
				"mid_end": 750.0,
				"far_end": 7500.0,
				"max_near_cells": 20,
				"max_mid_cells": 120,
				"max_far_cells": 350
			}
		QualityPreset.ULTRA:
			return {
				"near_end": 300.0,
				"mid_end": 1000.0,
				"far_end": 10000.0,
				"max_near_cells": 30,
				"max_mid_cells": 160,
				"max_far_cells": 500
			}

	# Fallback to medium
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
