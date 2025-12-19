# Distant Rendering System - Bug Analysis & Fix Report

**Date:** 2025-12-19
**Status:** Critical bugs fixed, system disabled pending redesign

---

## Executive Summary

The distant rendering system (MID/FAR/HORIZON tiers) was causing complete application freezes when enabled. The root cause was an architectural mismatch between the tier system's cell count and the queue-based loading system.

**Immediate fix applied:** Disabled `distant_rendering_enabled` by default.

---

## Bugs Found & Fixed

### Bug #1: Missing `get_object_pool()` Method (CRASH)

**Location:** `src/core/world/cell_manager.gd`

**Symptom:**
```
Invalid call. Nonexistent function 'get_object_pool' in base 'RefCounted (CellManager)'.
```

**Cause:** `world_streaming_manager.gd:732` called `cell_manager.get_object_pool()` but the method didn't exist.

**Fix:** Added getter method at line 68-70:
```gdscript
func get_object_pool() -> RefCounted:
    return _object_pool
```

---

### Bug #2: Massive Cell Count Overflow (FREEZE)

**Location:** `src/core/world/distance_tier_manager.gd` + `world_streaming_manager.gd`

**Symptom:** Application freezes for 1+ minute when Models toggle is enabled.

**Cause:** The tier system calculates visible cells based on distance:

| Tier | Distance | Cell Radius | Cell Count |
|------|----------|-------------|------------|
| NEAR | 0-500m | ~4 cells | ~50 |
| MID | 500m-2km | ~17 cells | ~858 |
| FAR | 2km-5km | ~43 cells | ~4,920 |
| HORIZON | 5km-10km | ~86 cells | ~17,472 |
| **TOTAL** | | | **~23,300** |

The queue size was only 64, causing:
1. 23,000+ attempts to queue cells
2. 23,000+ "Load queue full" debug messages printed
3. Massive dictionary operations freezing the main thread

**Fix:**
1. Set `distant_rendering_enabled = false` by default
2. Increased `max_load_queue_size` to 128
3. Added message throttling (only print every 100th dropped cell)

---

### Bug #3: Debug Message Spam (LOG OVERFLOW)

**Location:** `src/core/world/world_streaming_manager.gd:768-772, 826-831`

**Symptom:** Godot error: `[output overflow, print less text!]`

**Cause:** Every dropped cell printed a debug message, flooding the log with 23,000+ lines.

**Fix:** Added throttling variables and logic:
```gdscript
var _queue_full_message_count: int = 0
var _queue_full_message_throttle: int = 100

# Only prints first drop and every 100th thereafter
if _queue_full_message_count == 1 or _queue_full_message_count % _queue_full_message_throttle == 0:
    _debug("Load queue full, dropped %d cells..." % _queue_full_message_count)
```

---

## Files Modified

1. **`src/core/world/cell_manager.gd`**
   - Added `get_object_pool()` method (lines 68-70)

2. **`src/core/world/world_streaming_manager.gd`**
   - Changed `distant_rendering_enabled` default to `false` (line 55)
   - Increased `max_load_queue_size` to 128 (line 78)
   - Added throttle variables (lines 159-161)
   - Added throttle reset in `_on_camera_cell_changed()` (line 526)
   - Added throttle logic in `_queue_cell_load()` (lines 768-772)
   - Added throttle logic in `_queue_cell_load_tiered()` (lines 826-831)

---

## Architecture Problem

The distant rendering system has a fundamental design flaw: **it uses the same queue-based approach for all tiers**.

The NEAR tier (50 cells) works fine with a queue. But MID/FAR/HORIZON tiers have thousands of cells that should NOT use the queue at all.

### Current (Broken) Flow:
```
Camera moves → get_visible_cells_by_tier() → 23,000 cells
            → _queue_cell_load_tiered() × 23,000 → Queue overflow
```

### Required Flow:
```
Camera moves → NEAR tier: Queue-based loading (50 cells max)
            → MID tier: Direct batch processing with strict limit (100 cells max)
            → FAR tier: Impostor spawning, not cell loading (200 impostors max)
            → HORIZON: Static skybox, no per-cell processing
```

---

## Recommendations for Next Agent

### Priority 1: Fix the Tier Architecture

The `_on_camera_cell_changed_tiered()` function needs to be rewritten to:

1. **NEAR tier only** should use `_queue_cell_load_tiered()`
2. **MID/FAR/HORIZON** should have completely different code paths:
   - Process directly with per-frame budgets
   - Limit total cells per tier (constants, not distances)
   - Skip if pre-baked data doesn't exist

### Priority 2: Limit Tier Cell Counts

In `distance_tier_manager.gd`, add maximum cell limits:

```gdscript
const MAX_CELLS_PER_TIER := {
    Tier.NEAR: 50,      # Full geometry, queue-based
    Tier.MID: 100,      # Merged meshes, direct processing
    Tier.FAR: 200,      # Impostors only
    Tier.HORIZON: 0,    # Skybox, no cells
}
```

Modify `get_visible_cells_by_tier()` to respect these limits.

### Priority 3: Skip Non-Implemented Tiers

Currently, MID/FAR processing calls `ESMManager.get_exterior_cell()` for every cell, even though:
- No pre-merged meshes exist
- No pre-baked impostors exist
- The mesh merger runs synchronously (expensive!)

Add early exits:
```gdscript
func _process_mid_tier_cell(grid: Vector2i) -> void:
    # Skip until offline pre-processing creates merged meshes
    if not _has_prebaked_merged_mesh(grid):
        _loaded_cells_by_tier[Tier.MID][grid] = true  # Mark as "done"
        return
```

### Priority 4: Consider Alternative Architecture

Instead of per-cell processing for distant tiers, consider:

1. **Chunked regions** - Process 4×4 cell chunks instead of individual cells
2. **View frustum culling** - Only process cells in camera view for distant tiers
3. **Offline preprocessing** - Bake merged meshes and impostors during asset import
4. **Progressive loading** - Load distant content over multiple frames, not all at once

---

## Testing After Re-enabling

When distant rendering is re-enabled after fixes:

1. Test at Seyda Neen (low density)
2. Test at Balmora (medium density)
3. Test at Vivec (high density)
4. Monitor FPS, queue size, and memory usage
5. Verify no log spam occurs

---

## Related Files

- `docs/DISTANT_RENDERING_PLAN.md` - Original design document
- `docs/PERFORMANCE_OPTIMIZATION_ROADMAP.md` - Performance targets
- `src/core/world/distance_tier_manager.gd` - Tier distance calculations
- `src/core/world/distant_static_renderer.gd` - MID tier renderer
- `src/core/world/impostor_manager.gd` - FAR tier impostors
- `src/core/world/static_mesh_merger.gd` - Mesh merging logic
