# Streaming Architecture Debug Audit

**Date:** January 2026
**Status:** PHASE 5 COMPLETE - Ready for Testing
**FPS Before:** 9.3 (target: 150+)

## Changes Applied (January 2026)

### Phase 1: Critical Bug Fixes

1. **FAR tier visibility fixed** (`distance_tier_manager.gd:691-697`)
   - Removed frustum culling for FAR tier cells
   - FAR cells are now included in visibility output
   - ImpostorManager should now receive FAR cells

2. **GPU compute enabled** (`distance_tier_manager.gd:239-241, 292-296`)
   - Lowered threshold from 600→500 objects
   - Removed Phase 2 block that disabled GPU path
   - Should reduce 60ms→<1ms for visibility

3. **White model fix improved** (`mesh_visibility_utils.gd:45-84`)
   - Added near-white detection (>0.95 threshold)
   - ShaderMaterial texture check added
   - More aggressive materialless mesh hiding

### Phase 2: Code Simplification (ObjectStreamer)

4. **AAA streaming frequency reduced** (`object_streamer.gd`)
   - Query interval: 3→10 frames
   - Max register per query: 2000/200→500/100
   - Should reduce per-frame overhead

5. **Removed legacy tier change processing** (~200 lines removed)
   - Removed `use_event_driven_fades` toggle (always event-driven now)
   - Removed `_transitioning_objects` dictionary (uses `_active_fades` instead)
   - Removed `_process_tier_changes_from_authority()` function
   - Removed `_update_object_state()` and related helper functions:
     - `_update_near_state()`
     - `_update_mid_state()`
     - `_update_far_state()`
     - `_update_hidden_state()`
     - `_is_object_transitioning()`
   - Now exclusively uses event-driven `_process_tier_changes_event_driven()`
   - Reduces O(transitioning) per-frame to O(changes + active_fades)

6. **GPU sync batch size increased** (`distance_tier_manager.gd:248-250`)
   - Increased from 100→2000 objects per frame
   - GPU compute now activates in ~4 frames instead of ~75 frames
   - Eliminates long CPU fallback period during startup

7. **Unload key caching** (`object_streamer.gd:1581-1605`)
   - Cached `_aaa_registered_objects.keys()` to avoid O(n) allocation per frame
   - Keys only regenerated when objects are added/removed
   - Reduces GC pressure and allocation overhead

8. **Cell iteration bottleneck fixed** (`distance_tier_manager.gd:634-760`)
   - `get_visible_cells_by_tier()` was iterating (2*far_radius+1)² cells
   - With 5km FAR range and 117m cells: (87)² = 7,569 cells per frame!
   - **FIX**: Split iteration into two parts:
     - NEAR+MID: Small radius (~5 cells), iterate normally (~121 cells max)
     - FAR: Only iterate cells that have registered objects (from `_objects_by_cell`)
   - Added key caching for `_objects_by_cell.keys()` with dirty flag
   - Reduces cell iteration from ~7500 to ~200-500 cells

9. **ImpostorManager FAR visibility fix** (`impostor_manager.gd:1000-1100`)
   - ImpostorManager was using DTM's FAR cell list, which only tracked significant objects
   - DTM tracks 10K objects, but ImpostorManager has 23K impostors in 1023 cells
   - **FIX**: ImpostorManager now computes its own FAR visibility by iterating `_impostors_by_cell`
   - Checks each impostor cell's distance (500m-5000m) directly
   - More efficient: O(impostor_cells) ~1000 instead of O(far_radius²) ~7500
   - Ensures all impostor cells are considered for visibility

10. **ImpostorManager cell-based caching** (`impostor_manager.gd:1032-1044`)
    - ImpostorManager was iterating 1023 cells **every frame** (5.88ms avg)
    - **FIX**: Added cell-based caching - only recalculate when camera crosses cell boundary
    - Added `_last_camera_cell` and `_impostors_by_cell_keys_cache` with dirty flag
    - Reduces per-frame time from ~6ms to <0.1ms (when camera stationary within cell)

11. **Object unload radius mismatch fixed** (`object_streamer.gd:1596-1601`)
    - **BUG**: Registration radius was 530m, but unload radius was 5060m!
    - Objects registered at 530m would never unload until 5060m away
    - Caused unbounded object growth: 4400 → 8600+ objects over time
    - **FIX**: Changed unload radius from `FAR_END + FADE_MARGIN*2` (5060m) to `MID_END + FADE_MARGIN*3` (590m)
    - Also increased `UNLOAD_CHECK_BATCH_SIZE` from 500 to 2000 for faster cleanup
    - Objects now unload ~60m past registration boundary (590m vs 530m hysteresis)

### Phase 3: ImpostorManager Cleanup

12. **Removed dead code** (`impostor_manager.gd`)
    - Removed unused `_first_texture_logged`, `_first_cell_logged` variables
    - Removed unused `_first_array_rebuild_logged`, `_first_multimesh_rebuild_logged` variables
    - Removed unused `_format_name()` helper function (18 lines)
    - Removed stale comment about `_warned_no_tier_manager`
    - **Reduction**: ~30 lines of dead code removed

### Phase 4: Shader Consolidation

13. **Created shared dither include** (`shaders/dither_include.gdshaderinc`)
    - Consolidated Bayer 4x4 dithering matrix used across all LOD crossfade shaders
    - Single source of truth for dithering constants
    - Updated `lod_crossfade.gdshader`, `lod_crossfade_multimesh.gdshader`, `lod_crossfade_node3d.gdshader`
    - Note: ImpostorManager inline shader cannot use includes, but uses identical pattern

### Phase 5: DTM Leak Fix

14. **Stale objects leaked in DTM** (`object_streamer.gd:1672-1683`)
    - **BUG**: When objects were removed from `_external_to_pool` or `_objects`, they were
      removed from `_aaa_registered_objects` but NOT from DistanceTierManager
    - DTM kept tracking these stale objects forever, causing:
      - Unbounded object count growth in DTM (12,550+ when should be ~4000-5000)
      - 4096 tier changes per frame (GPU checking stale objects)
      - 43ms+ in DTM due to processing all stale objects
    - **FIX**: Track stale external_ids during unload check and call `_distance_tier_manager.unregister_object()` for each

---

---

## 1. Executive Summary

The streaming architecture has **severe performance problems** caused by:

1. **Overlapping visibility systems** - 4+ different systems managing object visibility
2. **O(n) per-frame iterations** - 60ms spent in DistanceTierManager.update_visibility
3. **Broken impostor visibility** - 0 visible impostors despite 23,757 registered
4. **LOD material issues** - White models appearing (materialless LOD meshes)
5. **Excessive complexity** - 2700+ lines in object_streamer.gd alone

### Root Cause Analysis

The diagnostic output reveals the **visibility chain is broken**:

```
FAR tier cells: 0          <- DTM reports no FAR cells
Cached visible cells: 0    <- ImpostorManager has no visible cells
Cells with impostors: 1023 <- Impostors exist but aren't visible
```

**Translation:** DistanceTierManager is not marking FAR cells as visible, so ImpostorManager never shows them.

---

## 2. Architecture Overview (Current State)

### 2.1 Component Hierarchy

```
WorldStreamingManager._process()
├── 1. DistanceTierManager.update_visibility()     ⚠️ 59.6ms SLOW
│   ├── get_visible_cells_by_tier()                ✓ Cell-level culling
│   └── _update_visibility_cpu()                   ⚠️ O(n) object iteration
│
├── 2. ImpostorManager.update_visibility()         ✓ 0.44ms fast
│   └── BUT: Gets empty cell list from DTM!        ❌ BROKEN
│
├── 3. ObjectStreamer.update()                     ⚠️ 53.8ms SLOW
│   ├── _update_aaa_streaming()                    ⚠️ Queries 134K objects
│   ├── process_instantiation_queue()              ✓ Batched
│   └── _process_tier_changes_event_driven()       ⚠️ Double-checking tiers
│
└── 4. CellManager.on_cell_changed()               ⚠️ 40ms SLOW
    └── _instantiate_cell()                        ⚠️ Synchronous
```

### 2.2 The Problem: Visibility Authority Confusion

**Who decides what's visible?**

| Component | Claims to be Authority | Actually Does |
|-----------|----------------------|---------------|
| DistanceTierManager | "UNIFIED VISIBILITY AUTHORITY" | Cell + object tier calculation |
| ObjectStreamer | Uses DTM as authority | But ALSO queries PositionIndex independently |
| ImpostorManager | Gets cells from DTM | But DTM returns 0 FAR cells! |
| LODMultiMeshBatcher | None (passive) | Renders what ObjectStreamer tells it |

**The confusion:**
- DTM.update_visibility() calculates NEAR/MID cells but **skips FAR** (see line 1004-1014 in DTM)
- ObjectStreamer._update_aaa_streaming() queries PositionIndex for objects up to MID_END (500m)
- FAR tier (500-5000m) objects are registered with DTM but **never queried for visibility**
- ImpostorManager expects FAR cell list from DTM but gets empty array

### 2.3 Code Duplication

**LOD hiding is implemented in 4+ places:**

1. `MeshVisibilityUtils.hide_lod_and_materialless()` - centralized (new)
2. `ReferenceInstantiator._hide_lod_nodes()` - delegates to MeshVisibilityUtils
3. `CellManager._hide_lod_nodes()` - delegates to instantiator
4. `ObjectStreamer._hide_lod_siblings()` - **still has own implementation**
5. `StaticObjectRenderer` - checks LOD names inline

**Visibility control is implemented in 3+ places:**

1. `DistanceTierManager._update_visibility_cpu()` - 150 lines
2. `ObjectStreamer._process_tier_changes_event_driven()` - 100+ lines
3. `ObjectStreamer._apply_tier_change_immediate()` - 50+ lines

---

## 3. Bug Analysis

### 3.1 BUG: Models Slow to Load (FPS drop to 9)

**Evidence from profiler:**
```
DistanceTierManager.update_visibility: 59.60 ms avg, 182.19 ms max
ObjectStreamer.update: 53.81 ms avg, 213.13 ms max
CellManager.on_cell_changed: 40.02 ms avg
```

**Root cause:** O(n) iterations over 8,520+ registered objects every frame.

**Code path:**
```gdscript
# distance_tier_manager.gd:1022-1037
for cell_grid: Vector2i in cells_to_check:
    var cell_objects: Array = _objects_by_cell[cell_grid]
    for obj_id: int in cell_objects:           # <-- O(n) iteration
        var obj = _registered_objects[obj_id]
        # Distance calculation per object...
```

**Fix:** Use GPU compute path (already implemented but disabled) OR batch updates.

### 3.2 BUG: White Models Appearing in NEAR Tier

**Evidence:** "white models appear in the NEAR tier, overlapping with full textured models"

**Root cause:** LOD meshes with materialless geometry becoming visible.

**How it happens:**
1. Model is prebaked with LOD1/LOD2/LOD3 meshes
2. Some LOD meshes have `StandardMaterial3D` with no albedo_texture (white)
3. `_hide_lod_nodes()` is supposed to hide these
4. BUT: Pool reuse or duplicate() creates new instances without hiding LODs
5. White LOD mesh renders alongside the main mesh

**Evidence from `MeshVisibilityUtils.has_valid_material()`:**
```gdscript
# A white material with no texture is marked invalid
if std_mat.albedo_color != Color.WHITE:
    return true
# White material with no texture - likely collision geometry
return false
```

**Fix locations:**
- `ReferenceInstantiator._instantiate_model_object()` line 213 calls `_hide_lod_nodes()`
- But `object_pool.acquire()` at line 189 may return objects without re-hiding
- Line 192 does call `_hide_lod_nodes(pooled)` but **after** visibility check

### 3.3 BUG: No Visible Impostors (0 of 23,757)

**Evidence from diagnostics:**
```
Total impostors: 23757
Visible impostors: 0 ❌
MultiMeshInstance3D visible: false ❌
Cached visible cells: 0 ❌
FAR tier cells: 0 ❌ (from DTM)
```

**Root cause:** DistanceTierManager.update_visibility() only checks NEAR+MID cells.

**Code evidence in distance_tier_manager.gd:1004-1014:**
```gdscript
# Only add NEAR and MID tier cells (skip FAR and HORIZON)
var near_cells: Array = visible_cells_by_tier.get(Tier.NEAR, [])
for cell in near_cells:
    cells_to_check.append(cell)

var mid_cells: Array = visible_cells_by_tier.get(Tier.MID, [])
for cell in mid_cells:
    cells_to_check.append(cell)
# FAR cells are NEVER added to cells_to_check!
```

**Why FAR is skipped:** Comment says "FAR tier objects use chunk-based rendering"

**But ImpostorManager.update_visibility() line 1014 expects FAR cells:**
```gdscript
# Get FAR tier cells from authority
var far_cells: Array = visible_cells.get(DistanceTierManager.Tier.FAR, [])
```

**The disconnect:** DTM doesn't populate FAR tier visibility, ImpostorManager expects it.

---

## 4. System Overlap Map

### 4.1 What Each System Actually Does

| System | NEAR Tier | MID Tier | FAR Tier | Redundant? |
|--------|-----------|----------|----------|------------|
| **DistanceTierManager** | ✓ Objects | ✓ Objects | ✗ Skipped! | Incomplete |
| **ObjectStreamer** | ✓ Node3D | ✓ LODMultiMesh | ✓ Impostors | Overlaps with DTM |
| **ImpostorManager** | - | - | ✓ MultiMesh | Waits for DTM FAR |
| **LODMultiMeshBatcher** | - | ✓ Passive | - | Just renders |
| **CellManager** | ✓ Loading | ✓ Loading | - | Loading only |
| **StaticObjectRenderer** | ✓ Flora | - | - | Parallel to ObjectStreamer |

### 4.2 Data Flow Issues

```
Objects registered with DTM: 8,520
Objects in PositionIndex: 134,938
Objects in ObjectStreamer: 8,520 (same as DTM)
Impostors in ImpostorManager: 23,757 (different!)
```

**Why different counts?**
- DTM/ObjectStreamer track "significant" objects only
- ImpostorManager tracks ALL objects that should have impostors
- PositionIndex tracks ALL world objects (not filtered)

---

## 5. Performance Bottlenecks

### 5.1 Frame Time Breakdown (Target: 6.67ms for 150 FPS)

| Operation | Current | Target | Issue |
|-----------|---------|--------|-------|
| DTM.update_visibility | 59.6ms | <1ms | O(n) CPU loop |
| ObjectStreamer.update | 53.8ms | <2ms | Redundant checks |
| CellManager.on_cell_changed | 40.0ms | <5ms | Sync instantiation |
| ImpostorManager.update | 0.44ms | <1ms | OK |
| **Total streaming** | 153ms+ | <10ms | **15x over budget** |

### 5.2 Why GPU Path Isn't Used

```gdscript
# distance_tier_manager.gd:865-874
if phase2_gpu_driven_enabled:        # FALSE by default
    stats = _update_visibility_near_only(...)
elif _should_use_gpu_compute():      # Checks threshold
    stats = _update_visibility_gpu(...)
else:
    stats = _update_visibility_cpu(...)  # <-- This path taken
```

**_should_use_gpu_compute() returns false because:**
- GPU feature check may be failing
- Object count threshold not met
- Or GPU path explicitly disabled

---

## 6. Recommended Fixes (Priority Order)

### P0: Critical - Fix Impostor Visibility (< 1 hour)

**Problem:** FAR cells never passed to ImpostorManager
**Fix:** In `distance_tier_manager.gd`, include FAR cells in visible_cells_by_tier output

```gdscript
# In get_visible_cells_by_tier(), ensure FAR cells are included
# Currently only returns NEAR and MID
```

### P1: Critical - Enable GPU Visibility (< 2 hours)

**Problem:** 60ms CPU iteration vs <1ms GPU compute
**Fix:** Enable GPU compute path for 8K+ objects

```gdscript
# In distance_tier_manager.gd
func _should_use_gpu_compute() -> bool:
    return _registered_objects.size() > 500  # Lower threshold
```

### P2: High - Consolidate Visibility Control (4-8 hours)

**Problem:** 3 systems managing visibility
**Fix:** Single visibility authority pattern

1. DTM calculates tiers (keep)
2. ObjectStreamer receives tier changes via signal (simplify)
3. Remove redundant distance checks in ObjectStreamer

### P3: Medium - Fix White Model Bug (2-4 hours)

**Problem:** Materialless LOD meshes visible
**Fix:**
1. Ensure `_hide_lod_nodes()` called on ALL code paths
2. Add validation in object pool release/acquire
3. Consider stripping materialless meshes at prebake time

### P4: Medium - Remove Code Duplication (4-8 hours)

**Files to consolidate:**
- Merge LOD hiding to single `MeshVisibilityUtils` call
- Remove duplicate tier calculation code
- Consolidate visibility flags (3+ boolean flags controlling same thing)

---

## 7. Quick Test Commands

**Test impostor visibility fix:**
```gdscript
# In ImpostorManager, force visibility for debugging
func _debug_force_all_visible():
    for id in _impostors:
        _impostors[id].visible = true
    _full_rebuild_needed = true
```

**Test GPU path:**
```gdscript
# In DistanceTierManager
phase2_gpu_driven_enabled = false  # Ensure false
gpu_compute_threshold = 100        # Lower threshold to force GPU
```

---

## 8. Files to Review

1. **distance_tier_manager.gd:838-1040** - update_visibility() loop
2. **object_streamer.gd:1688-1900** - _process_tier_changes duplicate logic
3. **impostor_manager.gd:1000-1100** - update_visibility() cell check
4. **reference_instantiator.gd:160-240** - instantiation + LOD hiding
5. **mesh_visibility_utils.gd** - centralized hiding (use everywhere)

---

## 9. Architecture Simplification Goals

Per code-simplifier.md principles:

1. **Single responsibility:** Each system does ONE thing
2. **Single source of truth:** One visibility authority (DTM)
3. **Event-driven updates:** No per-frame O(n) iterations
4. **GPU-first:** CPU only as fallback
5. **Delete dead code:** Remove unused GPU features or enable them

Target: Reduce streaming code from 5000+ lines to ~2000 lines.
