# Performance Analysis — 2026-03-04 (Arbiter)

## Scope
Analysis of the distant rendering pipeline after the multi-mesh LOD fix.
Focus: draw call regression, memory pressure, frame budget coordination, resource leaks.

---

## Measured Baseline (perf_snapshot, Seyda Neen spawn, 15s)

| Metric | Value | Target | Status |
|--------|-------|--------|--------|
| FPS | avg 14.1 (min 11, max 17) | 60 | 4.7× below target |
| Frame time | avg 70.7ms | 16.67ms | CRITICAL |
| Draw calls | avg 3,297, peak 4,872 | — | HIGH |
| VRAM | 2,155 MB | — | HIGH |
| Texture mem | 2,018 MB (94% of VRAM) | — | CRITICAL |
| MID RS instances | 14,492 (639 types) | — | CONFIRMED explosion |
| Orphan nodes | 21,079 | 0 | CONFIRMED current |
| RID leaks at exit | 5,855 | 0 | WORSE than session doc |
| Promoted objects | 618 | — | OK |

RS instances grow monotonically (806 → 14,492 over 15s). **INVESTIGATED — NOT A LEAK.** Camera was stationary during perf_snapshot (Seyda Neen spawn, 15s). With `load_radius_cells=3`, 49 cells (7×7) load asynchronously but none unload — the unload threshold requires moving beyond `max_load_euclidean + HYSTERESIS_MID`. The growth curve is simply 49 cells progressively finishing async load. Cleanup code (`remove_cell_instances` → `remove_instance`) verified correct: frees LOD RIDs, updates stats, maintains spatial index. Streaming benchmark enhanced with VRAM + RS min/max tracking to verify cleanup under camera movement.

---

## Post-Fix Measurements (after Issue #9 + #2 fixes)

| Metric | Before | After | Delta |
|--------|--------|-------|-------|
| FPS (avg) | 14.1 | 26.9 | **+91%** |
| FPS (steady-state) | 14-17 | 45-61 | **~3.5× improvement** |
| Frame time (avg) | 70.7ms | 37.2ms | **-47%** |
| Draw calls (avg) | 3,297 | 3,318 | ~same |
| VRAM | 2,155 MB | 2,143 MB | ~same |
| MID RS instances | 14,492 (639 types) | 14,285 (566 types) | -207 instances, -73 types |
| Orphan nodes | 21,079 | 19,210 | -1,869 |

**Primary contributor:** Issue #2 (double-rendering fix) eliminated fragment overdraw at 150-500m. LOD1-3 RS instances hidden when NEAR Node3D has LOD children. Steady-state FPS jumped from 14-17 to 45-61.

**Issue #9 impact was modest:** Only 73 mesh types collapsed (11.4%). Most buildings have genuinely different LOD1-3 meshes from the NIF converter's simplification, so fallback-filled bands are less common than estimated.

**VRAM unchanged** as expected — needs texture compression (Issue #3, P1) for that.

---

## Issue 1: RS Instance Count Explosion (HIGH IMPACT)

**Root cause:** The multi-mesh fix changed `lod_meshes` from `Dict[int → LodMeshEntry]` to `Dict[int → Array[LodMeshEntry]]`. Each material group now gets its own RS instance per LOD level.

**Math:**
- Before fix: 1 mesh × 4 LOD levels = **4 RS instances** per building
- After fix: N materials × 4 LOD levels = **4N RS instances** per building
- Typical Morrowind building: 3-5 material groups (wall, roof, door, window, trim)
- For 5 materials: **20 RS instances** per building (5x increase)
- Scene with 200 buildings in loaded cells: **800 → 4,000 RS instances** just for buildings
- **MEASURED: 14,492 RS instances across 639 types = 22.7 avg per type** (confirms 5×4 prediction)

**Why it matters:** Each RS instance is a potential draw call. Godot auto-batches identical mesh+material pairs, but multi-material buildings have unique combinations — no batching benefit.

**File:** `static_object_renderer.gd:401-448` — the LOD path in `add_instance()`.

**Mitigation options:**
1. **Mesh merging at registration time:** When `register_lod_from_prototype()` finds multiple meshes at one LOD level, merge them into a single ArrayMesh with multi-surface. One RS instance per LOD instead of N. Surfaces keep their materials but share one instance.
2. **Deferred LOD registration:** Only register LOD1-3 for buildings above a size threshold. Small huts with 2-3 materials don't need 4 LOD levels.
3. **LOD level reduction:** Many Morrowind buildings only have LOD0 and LOD1 in the prebaked .res. Levels 2 and 3 are filled via fallback copying (`lod_meshes[level] = lod_meshes[fallback].duplicate()`). This means LOD2 and LOD3 are rendering the same geometry as LOD1 but with separate RS instances. If only 2 genuine LOD levels exist, collapse LOD1-3 into a single band (150-500m).

---

## Issue 2: Double-Rendering at 150-500m (HIGH IMPACT)

**Root cause:** When a NEAR Node3D is promoted via `set_instance_promoted()`, only LOD0 RS instances are hidden (lines 628-633 of `static_object_renderer.gd`). LOD1-3 RS instances stay visible as a "safety net." But the NEAR Node3D has its own LOD children with identical visibility_range, so BOTH render.

**Overlap zones:**
- 150-250m: NEAR Node3D LOD1 children + RS LOD1 instances = 2× draw calls
- 250-375m: NEAR Node3D LOD2 children + RS LOD2 instances = 2× draw calls
- 375-500m: NEAR Node3D LOD3 children + RS LOD3 instances = 2× draw calls

**Cost per promoted building:** 5 materials × 3 overlapping LOD levels = **15 wasted draw calls**.

The code comment says "harmless overdraw" — this was true when lod_meshes was one-mesh-per-level, but post-fix with 5 materials/level it's 15 extra draw calls per building.

**File:** `native_streaming_manager.gd:696-698` (the comment), `static_object_renderer.gd:620-636` (the implementation).

**Fix:** On promotion, hide LOD1-3 RS instances ONLY when the NEAR Node3D has its own LOD children (verified at promotion time). Add a `near_has_lods` flag to the promotion call. If the NEAR Node3D lacks LOD children, keep LOD1-3 RS instances visible as a safety net — otherwise a cell-unload race could leave a 150-500m gap with nothing rendering.

**CORRECTION (from roaster review):** The naive "hide ALL LODs" approach is unsafe. If the NEAR Node3D is freed mid-frame (cell unload race), hiding all RS LODs would leave a 150-500m visibility gap. The safety net is correct in intent — the fix is making it conditional on verified LOD coverage.

---

## Issue 3: VRAM Pressure — 2.5 GB Textures (HIGH IMPACT)

**Root cause:** Prebaked `.res` files embed `ImageTexture` (uncompressed RGBA8). Morrowind textures are typically 256×256 to 1024×1024.

**Math:**
- 1024×1024 RGBA8 = 4 MB per texture
- With BC1 (opaque): ~0.5 MB (8:1). With BC3 (alpha): ~1 MB (4:1).
- Morrowind has a mix of opaque surfaces + alpha-tested foliage (BC1 fringing on 1-bit alpha)
- Estimated real-world average: **~4× compression** (mix of BC1 + BC3), not 8×
- 600+ unique textures: ~2.4 GB uncompressed → ~600 MB compressed. Still massive savings.
- **MEASURED: 2,018 MB texture memory, 94% of 2,155 MB VRAM total**

**Why this happens:** The NIF converter stores textures as `ImageTexture` in the PackedScene. Godot's `ResourceSaver` preserves this format. CompressedTexture2D uses BCn compression (GPU-native, no runtime decode cost).

**File:** Prebake pipeline in `nif_converter.gd` and model_loader disk cache.

**Fix:** During prebake:
1. Call `image.generate_mipmaps()` first — `Image.compress(COMPRESS_S3TC)` requires mipmaps or silently fails
2. Use BC1 for opaque textures, BC3 for textures with alpha channel
3. Save as `.ctex` or embed compressed in `.res`

**CORRECTION (from roaster review):** Original analysis overpromised 8× compression. Real average is ~4× due to BC3 requirement for alpha textures. The `generate_mipmaps()` prerequisite was missing — without it, compression silently returns uncompressed data.

---

## Issue 4: Uncoordinated Frame Budget (MEDIUM IMPACT)

**Root cause:** Multiple streaming phases have independent budgets that stack:

| Phase | Budget | File |
|-------|--------|------|
| Budgeted unloading | 4ms | `streaming_config.gd:254` |
| Async instantiation | 48% of frame (~8ms) | `streaming_config.gd:119` |
| MID→NEAR promotion | 3ms | `streaming_config.gd:91` |
| Collision enable | unbounded (runs per promoted object) | inline |
| Deferred NEAR | 1ms | inline |
| Pending load queuing | unbounded | inline |

**Worst case:** 4 + 8 + 3 + 1 = **16ms** of streaming work in a single frame, leaving ~0.67ms for rendering at 60 FPS. The telemetry at `native_streaming_manager.gd:402` catches overruns at 1.5× budget but doesn't reduce them.

**Fix:** Implement a shared frame budget pool. Each phase draws from the same pool. If unloading uses 4ms, instantiation gets 4ms less. The pool should be 8ms total (per PERFORMANCE_GUIDE.md), not the sum of all individual budgets.

---

## Issue 5: Orphan Node Leak — 20,122 Nodes (MEDIUM IMPACT)

**MEASURED: 21,079 orphan nodes** (confirmed current, not stale — measured via perf_snapshot 2026-03-04).

**Suspected sources (speculative — needs ObjectDB snapshot proof):**

1. **Budgeted unloading race condition:** If a cell is reclaimed (`_update_loaded_cells` moves it back to world container) while its children are partially freed, the remaining children survive but lose their pool metadata. On next unload, they can't be pooled and are queue_free'd — but if they have active physics bodies or area monitors, queue_free may be deferred indefinitely.

2. **Promoted objects with stale references:** `_promoted_objects` maps `rs_id → Node3D`. If the NEAR Node3D is freed externally (e.g., by cell unload) without going through demotion, the dictionary entry persists. The `is_instance_valid()` check catches freed nodes but doesn't erase the entry until the next promotion tick.

3. **GPUSceneDatabase pre-allocation:** The `_free_slots` array is pre-filled with 100,000 entries on init (line 53-54). These are ints, not nodes, but they contribute to memory pressure.

**Diagnostic approach:** First re-measure the count with current code. Then use Godot 4.6 ObjectDB snapshots before and after a load/unload cycle. Diff the snapshots to find leaked node types.

---

## Issue 6: RID Leaks — 3,392 Occluders (MEDIUM IMPACT)

**CORRECTION (from roaster review):** Original analysis had a logic error. When `owns_mesh = false`, the RID belongs to the Mesh resource, and freeing the resource via Godot's system also frees the RID. The `clear()` path in `static_object_renderer.gd` is correct for that case.

**MEASURED: 5,855 leaked instance dependencies at exit** (up from 3,392 in session doc — grew with multi-mesh fix adding more RS instances).

**Revised suspected source:** The leaks come from the `_exit_tree` timing — if the viewport/scenario is destroyed before `clear()` runs, RenderingServer can't properly clean up instance RIDs that reference a dead scenario.

Also: `GPUSceneDatabase._object_buffer` is a `storage_buffer_create()` RID. The `cleanup()` method should `_rd.free_rid(_object_buffer)`, but I didn't verify it does.

**Diagnostic:** Run `lod_stats` console command before and after cell cycling. Check if RS instance counts match. Also check if exit-time leaks appear in Godot's RID leak report.

---

## Issue 7: Streaming Benchmark Gaps (LOW IMPACT, blocks further analysis)

The existing `streaming_benchmark.gd` is solid for CPU-side metrics but missing:

| Missing Metric | Why It Matters |
|----------------|----------------|
| VRAM usage | Texture compression impact |
| RS instance count over time | Draw call regression tracking |
| GPU frame time | CPU metrics hide GPU bottlenecks |
| Per-tier object counts | NEAR/MID/FAR balance |
| Promotion/demotion rate | Tier transition smoothness |
| Material validity stats | Plain-color overlay debugging |

**Fix:** Add these to the CSV output. Godot 4.6 provides `Performance.RENDER_VIDEO_MEM_USED` for VRAM tracking.

---

## Issue 8: GPUSceneDatabase Dead Weight (LOW IMPACT)

The GPU scene database allocates a 9.6 MB SSBO on init (`100,000 × 96 bytes`) and pre-fills 100,000 free slot indices. However:
- It's only referenced from `native_streaming_manager.gd`
- `add_cell_objects()` is called from `cell_manager.set_gpu_scene_db()` path
- No compute shader or culling shader actually reads from this buffer yet

This is Phase 2 groundwork that currently costs ~10 MB for zero benefit. Consider lazy initialization (create buffer on first `add_cell_objects` call).

---

## Issue 9: Fallback LOD Duplication (LOW IMPACT)

In `register_lod_from_prototype()` at lines 228-243, if LOD2 or LOD3 don't exist, they're filled by duplicating LOD1's array. This means:
- LOD1, LOD2, LOD3 all point to the same mesh RIDs
- Three visibility bands render identical geometry
- Each band has its own RS instances

**For a building with 5 materials and only LOD0+LOD1 available:**
- LOD0: 5 RS instances (0-150m)
- LOD1: 5 RS instances (150-250m) — real LOD
- LOD2: 5 RS instances (250-375m) — copy of LOD1
- LOD3: 5 RS instances (375-500m) — copy of LOD1
- Total: 20 RS instances, where only 10 are unique

**Fix:** If LOD1-3 all resolve to the same mesh array, merge them into a single band (150-500m) with one set of RS instances.

---

## Issue 10: LOD Texture Propagation — Unverified (MEDIUM IMPACT, blocks other fixes)

**Missing from original analysis (flagged by roaster).**

The session doc lists "LOD Texture Propagation" as P2: the LOD generation in `nif_converter.gd:1268-1293` copies materials to LOD meshes, but some LOD meshes in cached `.res` files still appear textureless. This was not investigated.

**Why it blocks other fixes:** If LOD1-3 meshes in prebaked `.res` files have LOST their materials during serialization/deserialization, then all the RS instance optimizations (mesh merging, band collapsing) are moot — we'd be optimizing the rendering of materialless meshes.

**Diagnostic:** Load a known multi-material building `.res` from disk cache. Inspect LOD1-3 MeshInstance3D nodes for `material_override` and per-surface materials. Compare against the LOD0 mesh materials.

**File:** `nif_converter.gd:1268-1293` (LOD material copy), `model_loader.gd` (disk cache save/load).

---

## Recommended Priority

| Priority | Issue | Expected Impact | Effort |
|----------|-------|-----------------|--------|
| P0 | #10 LOD texture propagation check | BLOCKS all LOD optimizations — must verify first | Small (inspect .res files) |
| P0 | #9 Collapse duplicate LOD bands | 2-3× fewer RS instances for most buildings | Small (detect at registration time) |
| P0 | #2 Conditional double-rendering fix | 15 draw calls/promoted building saved | Small (add `near_has_lods` flag) |
| P1 | #1 Mesh merging per LOD level | 5× fewer RS instances per multi-mat building | Medium (ArrayMesh multi-surface merge) |
| P1 | #3 Texture compression in prebake | ~4× VRAM reduction (BC1+BC3 mix) | Medium (mipmaps + Image.compress) |
| P1 | #4 Shared frame budget pool | Eliminate 16ms frame spikes | Medium (refactor budget coordination) |
| P2 | #5 Orphan node leak audit | 21,079 orphan nodes (CONFIRMED) | Medium (ObjectDB snapshot diff) |
| P2 | #6 RID leak audit | 5,855 leaked RIDs (CONFIRMED, grew with multi-mesh fix) | Small (check _exit_tree timing) |
| P2 | #7 Benchmark enhancements | Better visibility into regressions | Small (add VRAM/RS metrics) |
| P3 | #8 Lazy GPU scene DB init | Save 10 MB | Trivial |

---

## Benchmark Plan — IMPLEMENTED

The streaming benchmark (`streaming_benchmark.gd`) has been enhanced with:

1. **RS instance count tracking** — min/max/final over entire run, with cleanup detection (**DONE**)
2. **VRAM tracking** — `RENDER_VIDEO_MEM_USED` + `RENDER_TEXTURE_MEM_USED` per frame (**DONE**)
3. **Promoted object count** — `mid_to_near_promotions` per frame (**DONE**)
4. **Draw call delta** — already tracked via visibility drop events (was pre-existing)

New CSV columns: `vram_mb`, `texture_mem_mb`, `promoted_objects`. Summary now shows RS instance min/max range and freed count (confirms cleanup works when camera moves). Run via console: `benchmark_streaming`.
