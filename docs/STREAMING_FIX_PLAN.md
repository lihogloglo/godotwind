# Streaming Pipeline Fix Plan

**Created:** 2026-03-02
**Status:** Implementation Complete — Pending Visual Verification
**Agents:** Claude (implementation), Gemini (review/roast)

---

## Problem Statement

Objects in the Godotwind scene are missing, appearing late, and blinking in/out of existence. The previous MID-tier audit found "0 missing objects" but only checked data structures — not what actually renders on screen.

## Root Causes Identified

### RC1: MultiMesh visibility_range is broken for per-instance LOD (CRITICAL)

**File:** `src/core/world/mid_tier_batch_pool.gd`

The `MidTierBatchPool` creates one `MultiMeshInstance3D` per (mesh_type, lod_level) and sets `visibility_range` on the batch node. Godot's `visibility_range` checks distance from camera to the node's AABB center — NOT to individual instances. All batch nodes are at the world origin.

**Effects:**
- All instances of a mesh type switch LOD levels simultaneously (group blinking)
- LOD selection is wrong: objects 50m away render with LOD meant for 300m and vice versa
- When camera is far enough from AABB center, all instances of a type disappear entirely
- Each object is added to ALL 3 LOD batches simultaneously, causing potential triple-draw

### RC2: MID-to-NEAR promotion creates a 35m visibility gap (HIGH)

**File:** `src/core/world/native_streaming_manager.gd` (lines 718-840)

When an object is promoted from MID to NEAR at 130m:
- NEAR Node3D gets `visibility_range_end = 150m` (+5m margin = invisible beyond 155m)
- Batch pool slot is hidden (zero-scale transform)
- Demotion only happens at 190m
- **Object invisible from 155m to 190m** — neither representation renders

### RC3: No fade-in on async-instantiated objects (MEDIUM)

**File:** `src/core/world/cell_manager.gd` (line 1196, `process_async_instantiation()`)

The async instantiation path does NOT call `_apply_fade_in()`. Objects pop in instantly. Comment at line 768 says "caller must apply after add_child()" but the async caller never does.

### Additional Issues

| Issue | Severity | Location |
|-------|----------|----------|
| Deferred `add_child` for >20 objects/frame delays by 1 frame | Low | cell_manager.gd:1353 |
| Promotion check runs every 4 frames (~67ms gaps) | Low | native_streaming_manager.gd:725 |
| `FADE_DEPENDENCIES` doesn't work across tree branches | Medium | NEAR Node3D vs MID MultiMesh in different trees |
| Deferred NEAR runs every 4 frames, 1ms budget | Low | native_streaming_manager.gd:849 |
| Fade duration mismatch: StreamingConfig=0.3s vs ReferenceInstantiator=0.4s | Trivial | streaming_config.gd:211 vs reference_instantiator.gd |

---

## Consensus Fix: Replace MultiMesh Batching with Per-Instance RS Visibility

### Architecture Change

**Before:** MidTierBatchPool creates MultiMeshInstance3D nodes with visibility_range on the batch node. Broken because visibility_range checks node AABB center, not per-instance.

**After:** Use `RenderingServer.instance_geometry_set_visibility_range()` on individual RS instances. Each object gets 3 RS instances (one per LOD level) with per-instance visibility_range. Godot handles distance checks in C++ and auto-batches identical mesh+material instances.

### Why This Works

- `RenderingServer.instance_geometry_set_visibility_range(instance, min, max, min_margin, max_margin, fade_mode)` sets visibility per-instance
- Godot 4's Forward+ renderer auto-batches identical RS instances into instanced draw calls
- Per-object LOD distance checks happen in C++ (zero GDScript overhead)
- Set once at creation, never touch again

### Per-Object RS Instance Setup

For each MID-worthy object, create 3 RS instances with different meshes and visibility ranges:

```
LOD1 RS instance: mesh=lod1_mesh, visibility_range(150, 250, 5, 10, FADE_SELF)
LOD2 RS instance: mesh=lod2_mesh, visibility_range(250, 375, 10, 15, FADE_SELF)
LOD3 RS instance: mesh=lod3_mesh, visibility_range(375, 500, 15, 20, FADE_SELF)
```

NEAR Node3D (0-150m) continues to use scene tree nodes with per-node `visibility_range` properties.

---

## Implementation Phases

### Phase 1: Add per-instance visibility_range to StaticObjectRenderer — DONE
- [x] Verify `StaticObjectRenderer` extracts LOD meshes from prototypes
- [x] Add LOD mesh extraction (ported from MidTierBatchPool._extract_lod_meshes)
- [x] Add `RenderingServer.instance_geometry_set_visibility_range()` calls for each LOD instance
- [x] Create 3 RS instances per MID object (LOD1/LOD2/LOD3) with correct visibility bands

### Phase 2: Remove MidTierBatchPool — DONE
- [x] Update `NativeStreamingManager` to route MID-tier through StaticObjectRenderer only
- [x] Update `CellManager._instantiate_mid_tier()` to use StaticObjectRenderer with LOD instances
- [x] Remove MidTierBatchPool from initialization and cleanup
- [x] Update promotion/demotion to work with StaticObjectRenderer RS instances
- [x] Update `_unload_cell()` cleanup to handle new RS instance structure
- [x] Update `lod_debug_commands.gd` to use static renderer stats

### Phase 3: Fix promotion/demotion gap — DONE
- [x] Extend promoted NEAR Node3D visibility_range_end to 190m (demotion threshold)
- [x] Added `_extend_promoted_visibility()` helper in cell_manager.gd
- [ ] Test: fly slowly through 130-200m boundary, verify no invisible gap

### Phase 4: Fix async fade-in — DONE
- [x] Add `apply_fade_in_to_object()` call after add_child in `process_async_instantiation()`
- [x] Fix fade duration mismatch (0.4s → 0.3s in reference_instantiator.gd)
- [ ] Test: fly into new cells, verify objects fade in smoothly

### Phase 5: Cleanup and verification — COMPLETE
- [x] Update `mid_tier_debugger.gd` to use static_renderer instead of batch_pool
- [x] Update `batch_debug_hud.gd` to use static_renderer instead of batch_pool
- [x] Delete `mid_tier_batch_pool.gd` (no longer referenced, safe to remove)
- [ ] Update docs/DISTANCE_RENDERING_AUDIT.md with new architecture
- [ ] Update docs/STATUS.md
- [ ] Run streaming benchmark, compare FPS/draw calls before vs after
- [ ] Visual comparison test: fly the same path, screenshot before/after

---

## Verification Checklist

- [ ] Objects no longer blink in groups when camera moves
- [ ] Objects visible at correct distances (not missing at MID range)
- [ ] Smooth LOD transitions at 150m, 250m, 375m, 500m boundaries
- [ ] No objects disappearing at promotion/demotion boundary (130-190m)
- [ ] Objects fade in when new cells load (not instant pop-in)
- [ ] Draw call count comparable to MultiMesh approach (~50-100 for MID tier)
- [ ] FPS >= 60 during normal exploration
- [ ] No RID leaks at exit (check Godot debug output)

---

## Open Questions

1. **Does Godot's RS auto-batching give draw call parity with MultiMesh?** Need to test with profiler. If draw calls are significantly higher, may need to reconsider or use a hybrid approach.
2. **Does StaticObjectRenderer already handle LOD mesh extraction?** If not, port from MidTierBatchPool.
3. **Should we keep promotion/demotion at all?** If RS visibility_range handles NEAR/MID crossfade, promotion is only needed for physics bodies. Could simplify by not promoting until player actually interacts.

---

## Key Files

| File | Role | Changes Needed |
|------|------|----------------|
| `src/core/world/static_object_renderer.gd` | RS instance management | Add per-instance visibility_range, LOD mesh extraction |
| `src/core/world/mid_tier_batch_pool.gd` | MultiMesh batching (REMOVE) | Delete after migration |
| `src/core/world/native_streaming_manager.gd` | Streaming orchestrator | Route MID through StaticObjectRenderer, update promotion |
| `src/core/world/cell_manager.gd` | Cell loading + instantiation | Update `_instantiate_mid_tier()`, add async fade-in |
| `src/core/world/reference_instantiator.gd` | Object creation | Fix fade-in application |
| `src/core/world/lod_configurator.gd` | visibility_range setup | May need updates for promoted NEAR objects |
| `src/core/world/streaming_config.gd` | Budget constants | Fix fade duration mismatch |

---

## Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-03-02 | Replace MultiMesh batch pool with per-instance RS visibility_range | MultiMesh visibility_range checks node AABB center, not per-instance. RS instances support per-instance visibility_range via `instance_geometry_set_visibility_range()`. Godot auto-batches identical instances. |
| 2026-03-02 | Use FADE_SELF (not FADE_DEPENDENCIES) for MID RS instances | FADE_DEPENDENCIES requires parent-child LOD chain. RS instances aren't in a tree hierarchy. FADE_SELF gives independent fade per LOD level with brief crossfade overlap. |
| 2026-03-02 | Keep promotion/demotion for physics | NEAR Node3D needed for collision/physics. RS instances are render-only. Promote at 130m, demote at 190m for physics bodies only. |
