# MID-Tier MultiMesh Batching

**Last Updated:** 2026-03-02
**Status:** Design — Implementation in Progress (2026-03-02 Audit Consensus)
**Effort:** ~1-2 weeks (vs 8-12 weeks for full GPU-driven)
**Expected FPS Gain:** 15-30% typical, ~40% in dense areas

---

## 2026-03-02 Audit Consensus

During the 2026-03-02 audit, the following critical issues were identified and prioritized:

1. **LOD0 Vertex Leak:** The current `StaticObjectRenderer` (Phase 0) correctly skips `_LOD1/2/3` nodes but incorrectly renders the high-poly **LOD0** mesh at all MID-tier distances (150-500m). This causes a massive unnecessary vertex load.
2. **Missing 500m Hysteresis:** The boundary between MID (StaticRenderer) and FAR (Impostors) at 500m lacks hysteresis, causing rapid oscillation/flicker during the `ORBIT_FAR` test phase.
3. **Crossfade Technicality:** Sibling LODs are using `FADE_DEPENDENCIES` which is technically incorrect for siblings in Godot 4.6 (modeled for parent-child). Consensus is to switch to `FADE_SELF` with symmetric 10-15m margins.

### Agreed Implementation Order:
- **Quick Win 1:** Implement `HYSTERESIS_MID` (60m) at the 500m boundary in `NativeStreamingManager`.
- **Quick Win 2:** Update `StaticObjectRenderer` to extract the correct LOD mesh (LOD1/2/3) based on distance bands.
- **Main Project:** Implement the MultiMesh Batch Pool (Phase 2) to reduce draw calls.

---

## Motivation

The MID tier (150-500m) currently renders each object as a separate RenderingServer instance via `StaticObjectRenderer`. With 200-500 objects loaded, this means 200-500 individual draw calls — a major rendering bottleneck. (Note: RS instances ARE frustum culled by the engine automatically, so off-screen objects don't draw. The issue is that every on-screen MID object is a separate draw call with no batching.) The FAR tier already proves that MultiMesh batching works at scale (70k+ impostors in 1 draw call). Adapting that pattern to MID tier should reduce MID draw calls from ~200-500 to ~30-80 (one per unique mesh_type x LOD).

This captures ~60-70% of the performance benefit of the full GPU-Driven Renderer (`docs/GPU_DRIVEN_RENDERER.md`) at a fraction of the effort. The two approaches are not mutually exclusive — this can be implemented first and later upgraded to GPU-driven culling.

---

## Current State

| Tier | Draw Calls | Batching | Method |
|------|-----------|----------|--------|
| NEAR (0-150m) | ~300-500 | None | Individual Node3D instances |
| MID (150-500m) | **~200-500** | **None** | Individual RS instances |
| FAR (500-5000m) | 1 | Full | Single MultiMesh |
| **Total** | **~500-1000** | | |

---


### Related files

| File | Relevance |
|------|-----------|
| `src/core/world/cell_manager.gd:1248` | MID/NEAR decision point |
| `src/core/world/cell_manager.gd:1749` | `_is_always_near_ref()` — current filter (lights/NPCs only) |
| `src/core/world/cell_manager.gd:1806` | `_queue_instantiation()` — Phase 5c pre-classification |
| `src/core/world/reference_instantiator.gd:628` | `_is_static_render_model()` — flora/small-rock filter (separate path) |
| `src/core/world/streaming_config.gd:80` | Hysteresis constants (NEAR=40m, MID=60m, FAR=150m) |
| `src/core/world/lod_configurator.gd` | LOD distance bands (150/250/375/500m) |
| `src/core/world/object_position_index.gd:143` | Existing `is_significant` heuristic (not used for MID filtering) |
| `src/tools/lod_transition_test.gd` | Test harness — rerun after filter to verify improvement |
| `docs/DISTANCE_RENDERING_AUDIT.md` | Distance rendering status and known issues |

### Other issues found during the LOD transition test

1. ~~**MID↔FAR boundary has no hysteresis**~~ **FIXED (2026-03-02):** Root cause was
   Chebyshev grid load (corner cells at ~496m) vs Euclidean unload threshold (411m).
   Fix: `unload_threshold = sqrt(2) * radius * cell_size + HYSTERESIS_MID` (~556m).

2. **Test hysteresis check is wrong:** `_check_pass_fail()` at
   `lod_transition_test.gd:1081` measures camera-to-center distance at the 150m tier
   boundary, not per-object demotion distance. The actual NEAR↔MID hysteresis (130m
   promote / 190m demote) works correctly — first demotion fired at 212.7m from center.
   Fix the test to compare `demotion` event distances instead of tier crossings.

3. **Exit crash:** Segfault in `cell_manager.gd:1896` (`prototype.duplicate()`) because
   `native_streaming_manager._process()` continues running after the test finishes.
   Fix: call `_streaming_manager.set_process(false)` in `_finish_test()`.

---

## Design

### Phase 1: Add LOD Support to StaticObjectRenderer

**Problem:** `StaticObjectRenderer` registers one mesh per type. MID tier needs 3 LOD levels (150-250m, 250-375m, 375-500m).

**File:** `src/core/world/static_object_renderer.gd` (~450 lines)

**Changes:**
- Extend `MeshType` to hold up to 3 LOD meshes + materials (reuse `LODResource` data)
- New method: `register_mesh_type_with_lods(type_name, lod_meshes: Dictionary)` — accepts `{1: {mesh, material}, 2: {mesh, material}, 3: {mesh, material}}`
- Keep existing `register_mesh_type()` as single-LOD fallback (maps to LOD1)

**Reuse:** `src/core/world/lod_resource.gd` already stores per-level mesh/material pairs.

---

### Phase 2: MultiMesh Batch Pool

**Problem:** Individual RS instances = 1 draw call each. Need to group by (mesh_type, lod_level).

**New file:** `src/core/world/mid_tier_batch_pool.gd` (~250-300 lines)

**Design (adapted from `native_impostor_renderer.gd` pattern):**

```
BatchKey = mesh_type_name + "_lod" + lod_level  (e.g. "flora_kelp_01_lod2")

class BatchData:
    var multimesh: MultiMesh
    var instance_node: MultiMeshInstance3D
    var capacity: int = 64           # Grows in powers of 2
    var slot_map: Dictionary = {}    # object_id -> multimesh_index
    var free_slots: Array[int] = []  # Reuse freed slots
    var dirty: bool = false          # Needs rebuild
```

**Key methods:**
- `add_object(batch_key, object_id, transform, material_id) -> void` — Assign slot, mark dirty
- `remove_object(batch_key, object_id) -> void` — Free slot, mark dirty
- `remove_cell(cell_grid) -> void` — Bulk remove by cell (uses spatial index)
- `rebuild_dirty_batches(budget_ms) -> void` — Rate-limited MultiMesh buffer updates
- `set_object_visible(batch_key, object_id, visible) -> void` — For promotion hiding

**Rebuild strategy (from impostor renderer lessons):**
- Debounce: 0.1s after last change
- Budget: 2ms/frame for rebuilds
- Never shrink `instance_count` — only grow (use `visible_instance_count` to hide excess)
- Grow capacity in powers of 2

**Visibility per LOD level:**
- Each `MultiMeshInstance3D` gets `visibility_range_begin/end` matching its LOD band
- LOD1 batch: 150-250m, LOD2 batch: 250-375m, LOD3 batch: 375-500m
- `visibility_range_end_margin` for hysteresis (prevents flicker)

---

### Phase 3: Wire Into Streaming Pipeline

**File:** `src/core/world/native_streaming_manager.gd` (~1173 lines)

**Changes:**
- On MID-tier object load: instead of `_static_renderer.add_instance()`, call `_batch_pool.add_object()`
- On cell unload: `_batch_pool.remove_cell(cell_grid)` instead of `_static_renderer.remove_cell_instances()`
- Per-frame: call `_batch_pool.rebuild_dirty_batches(2.0)` in the streaming budget loop

**File:** `src/core/world/static_object_renderer.gd`

**Changes:**
- Keep the class but repurpose it: it still manages mesh type registration and metadata
- Instance creation/destruction moves to the batch pool
- Promotion data (model_path, item_id, ref_id, ref_num) stays in a lightweight dictionary indexed by object_id (needed for MID->NEAR promotion)

**File:** `src/core/world/cell_manager.gd` / `src/core/world/reference_instantiator.gd`

**Changes:**
- When loading LOD resources for MID objects, pass all 3 LOD meshes to batch pool registration
- Minimal — the routing logic (`_is_static_render_model`) stays the same

---

### Phase 4: Promotion/Demotion Compatibility

**Problem:** MID->NEAR promotion (at 130m) needs to hide a specific object in the MultiMesh batch and spawn a Node3D. Current system hides individual RS instances.

**Solution:**
- `set_object_visible(batch_key, object_id, false)` marks the slot's transform as `Transform3D()` (zero-scale, effectively invisible) and decrements a counter
- On demotion (>190m): restore the original transform
- The promotion metadata dictionary (model_path, ref_id, etc.) stays in `StaticObjectRenderer` or moves to a lightweight `MidTierMetadata` dictionary

**This is the trickiest part** — must ensure promoted objects don't render in both NEAR (Node3D) and MID (MultiMesh) simultaneously.

---

### Phase 5: Polish & Debug

- Console command `mid_batch_stats` — print batch count, total instances, memory
- Verify visibility_range crossfade works correctly between LOD bands
- Stress test: fly through Balmora, check for pops at LOD boundaries
- Benchmark: compare draw calls before/after with `Performance.get_monitor(Performance.MONITOR_RENDER_TOTAL_DRAW_CALLS_IN_FRAME)`

---

## Expected Results

| Metric | Before | After |
|--------|--------|-------|
| MID tier draw calls | 200-500 | ~30-80 (1 per mesh_type x LOD) |
| Total draw calls | 500-1000 | ~330-580 |
| CPU per MID object | ~0.01ms (RS instance) | ~0 (batched) |
| MID rebuild cost | N/A | ~1-2ms every 0.1-0.5s |
| Memory per MID object | ~200+ bytes (RID + InstanceData) | ~64 bytes (MultiMesh slot) |
| FPS improvement | — | ~15-30% typical, ~40% in dense areas |

---

## Files Summary

| Action | File | Scope |
|--------|------|-------|
| Modify | `src/core/world/static_object_renderer.gd` | Add LOD support, keep as metadata/registration layer |
| Create | `src/core/world/mid_tier_batch_pool.gd` | New MultiMesh batch pool (~250-300 lines) |
| Modify | `src/core/world/native_streaming_manager.gd` | Route to batch pool, call rebuild per frame |
| Modify | `src/core/world/cell_manager.gd` | Pass LOD meshes on registration |
| Modify | `src/core/world/reference_instantiator.gd` | Minor — LOD resource loading for MID objects |
| Reuse | `src/core/world/lod_resource.gd` | LOD mesh storage (no changes) |
| Reuse | `src/core/world/distance_utils.gd` | Distance constants (no changes) |

---

## Relationship to GPU-Driven Renderer

MultiMesh batching is the **primary rendering strategy** for MID tier, not just a stepping stone. The batch pool created here is production infrastructure. It also happens to map to Phase 4 of the GPU-Driven Renderer design:

| This plan | GPU-Driven equivalent |
|-----------|----------------------|
| MultiMesh per (mesh_type, LOD) | `multimesh_batch_pool.gd` (Phase 4) |
| CPU visibility_range culling | GPU compute culling (Phase 2) |
| CPU LOD selection | GPU distance LOD (Phase 2) |
| Debounced rebuild | Async readback (Phase 4) |

**Optional future upgrade — GPU compute culling:** The existing `gpu_visibility_compute.glsl` (176 lines, fully implemented but unused) could be wired up as a CompositorEffect to feed visibility decisions into the batch pool. This replaces CPU visibility_range with GPU-parallel frustum + distance culling. ~2-3 weeks additional effort, uses the proven CompositorEffect compute dispatch pattern (same as volumetric fog).

**Not recommended yet — indirect draw:** `draw_list_draw_indirect()` is exposed since Godot 4.4dev4, but has zero community usage examples, a [Mac Metal bug](https://github.com/godotengine/godot/issues/103488), and no documentation beyond the API reference. Wait until the Godot ecosystem matures around this before investing.

**If/when Godot ships engine-level GPU-driven rendering:** Both this plan and `GPU_DRIVEN_RENDERER.md` become moot. Reduz's [GPU-driven renderer gist](https://gist.github.com/reduz/c5769d0e705d8ab7ac187d63be0099b5) is a 2023 vision document — it is not actively being developed, has no timeline, and is not mentioned in Godot's [official rendering priorities (Sep 2024)](https://godotengine.org/article/rendering-priorities-september-2024/). Don't wait for it.

---

## Godot 4.6 Reality Check (Feb 2026)

What's proven and working in this project:

| Capability | Status | Used by |
|-----------|--------|---------|
| `RenderingServer.instance_create()` | Working | MID tier (`StaticObjectRenderer`) |
| `MultiMesh` + `MultiMeshInstance3D` | Working | FAR tier (70k+ impostors, 1 draw call) |
| `visibility_range_begin/end` | Working | All tiers (engine-level LOD culling) |
| `CompositorEffect` compute dispatch | Working | Volumetric fog, clouds, color grading |
| `RenderingDevice` compute shaders | Working | Ocean FFT, volumetric effects |

What exists but is unused:

| Asset | Status | Notes |
|-------|--------|-------|
| `gpu_visibility_compute.glsl` | 176 lines, fully implemented | Frustum + distance cull shader, never dispatched |
| `use_multimesh_instancing` flag in CellManager | Dead code | Exists but unused — NEAR tier is individual Node3D |

What Godot 4.6 exposes but is unproven:

| API | Availability | Risk |
|-----|-------------|------|
| `draw_list_draw_indirect()` | Since 4.4dev4 | Zero community examples, [Mac Metal bug](https://github.com/godotengine/godot/issues/103488), undocumented |
| Graphics pipelines via `RenderingDevice` | API exists | No GDScript examples in ecosystem |
| SSBO async readback | `buffer_get_data()` exists | No double-buffered patterns documented |

What requires future Godot versions:

| Feature | Version | Source |
|---------|---------|--------|
| RT acceleration structures (`GL_EXT_ray_query`) | 4.7+ | [PR #99119](https://github.com/godotengine/godot/pull/99119) merged to master |
| Engine-level GPU-driven renderer | Unknown (multi-year) | [Reduz gist](https://gist.github.com/reduz/c5769d0e705d8ab7ac187d63be0099b5) (2023 vision, not active) |

---

## Verification

1. Run `world_explorer.tscn`, fly to MID-tier range (200-400m from objects)
2. Check `Performance.MONITOR_RENDER_TOTAL_DRAW_CALLS_IN_FRAME` — should drop 40-60%
3. Console: `mid_batch_stats` — verify batch count matches unique mesh types
4. Fly close (<130m) and back out (>190m) — promotion/demotion should be seamless
5. Check LOD transitions at 250m and 375m — no pops or flicker
6. 10-minute flight through Balmora — no leaks, no pops, stable FPS

---

## 2026-03-02 Joint Audit Notes (Claude + Gemini Consensus)

### Agreed Findings

1. **LOD0 leakage confirmed.** `StaticObjectRenderer._find_mesh_instance()` skips `_LOD1/2/3` nodes — renders full-detail LOD0 at 500m. This is the single largest vertex waste in the MID tier.

2. **MultiMesh batching is the right fix.** Individual RS instances for MID = 200-500 draw calls. Grouping by (mesh_type, lod_level) → ~30-80 draw calls. FAR tier already proves this works (70K impostors, 1 draw call).

3. **500m hysteresis must be fixed first** (prerequisite). `HYSTERESIS_MID=60m` is defined but never used. The orbit test showed 18 oscillations and 70 frame spikes at the 500m boundary. Quick fix: apply hysteresis in cell loading radius logic before starting batching work.

4. **GPU Scene Database is ready but deferred.** The SSBO infrastructure exists (`gpu_scene_database.gd`) but no compute cull shader. The real GPU-driven win is for MID tier culling, not FAR (FAR is already 1 draw call). Deferred until after MultiMesh batching proves out.

### Debated & Resolved

- **FADE_DEPENDENCIES vs FADE_SELF:** Gemini proposed FADE_SELF for sibling LODs. Claude verified margins are symmetric at every boundary, confirming FADE_DEPENDENCIES is correct (crossfades both siblings with complementary alpha). **Consensus: keep FADE_DEPENDENCIES.**

- **NEAR/MID fade margin (5m):** Gemini proposed 10-15m. Claude proposed 8m. **Consensus: test 8m visually** — too long creates ghosting, too short creates popping.

- **`pop_front()` in hot paths:** Gemini verified streaming hot paths already use `pop_back()`. Only doc examples had incorrect patterns. **Consensus: fixed in docs, no runtime changes needed.**

### Implementation Priority

1. Fix 500m hysteresis (DR-02) — prerequisite, quick win
2. MID tier MultiMesh batching (Phases 1-5 above) — biggest FPS gain
3. Fade margin tuning (DR-03) — visual quality, visual test
4. GPU cull shader (DR-04) — future work
