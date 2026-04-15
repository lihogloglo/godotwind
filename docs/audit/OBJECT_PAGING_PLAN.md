# Object Paging Plan — OpenMW-Style Distance-Adaptive Merging

**Owner:** @coder · **Reviewer:** @roaster · **Status:** draft (awaiting plan review) · **Date:** 2026-04-14

## 1. Problem

`bench_progressive` shows `mid_objects` is the single largest marginal rendering cost in the additive sweep. Each MID-tier static is one RS instance (150-500m band), and at typical flyby density that is thousands of draw calls. The individual-RS-per-object model was the right answer for NEAR (where physics + picking matter) and FAR (where impostors collapse everything to one MultiMesh), but it leaves MID paying full CPU draw-call cost for geometry that is visually indistinguishable from a merged block.

We already ship `runtime_hlod_merger.gd` (839 lines) as an HLOD-band (300-1000m) merger. It works but is:
- Cell-scoped only (one chunk = one 117m MW cell), so it inherits MW's grid resolution instead of adapting chunk size to distance.
- Gated behind `is_mid_worthy` — a **keyword-substring filter** on model paths ("ex_", "in_", "flora_tree", …). This is fragile (new mod content misses), coarse (a tiny `ex_lamp_01` passes, a huge mesh without a magic prefix fails), and unrelated to the actual visual contribution of the mesh at its render distance.
- Disabled by default (`enabled = false`) — never validated on real workloads, per the `hlod` omission in `PROGRESSIVE_ORDER` (`progressive_benchmark.gd:20-34`).
- Not applied to the MID band itself; MID pays full draw-call cost in 150-500m where most of the visible geometry lives.

The user directive: **the cell merger took too much disk when prebaked, and the previous runtime merger was not performant enough. Look at how OpenMW does it, use a quadtree, filter to big statics, skip everything else.**

## 2. Canonical Pattern

**OpenMW `ObjectPaging`** — `inspos/openmw/apps/openmw/mwrender/objectpaging.{cpp,hpp}`. This is the shipping reference: 1145-line implementation backing OpenMW's open-world streaming since 0.47. Tied to `QuadTreeWorld` in `inspos/openmw/components/terrain/quadtreeworld.cpp`. The pattern is named, battle-tested, and documented in OpenMW's terrain settings (`object paging min size`, `object paging merge factor`, `object paging min size cost multiplier`, `object paging min size merge factor`).

The pattern has six load-bearing pieces. Godotwind will adopt all six.

### 2.1 Distance-adaptive quadtree chunks
Chunks are not 1-cell fixed. `createChunk(size, center, ...)` (`objectpaging.cpp:651`) accepts `size` in MW cells — 1, 2, 4, 8 — driven by the terrain quadtree LOD walk. Close to camera: many small (size=1) chunks. Far from camera: few large (size=4, 8) chunks. Each `ChunkId = (center, size, activeGrid)` is cached independently in a generic LRU (`GenericResourceManager<ChunkId>`). The win: small chunks near camera stay granular for culling / promotion; large chunks far from camera stay cheap because CPU cost is per-chunk, not per-ref.

### 2.2 Projected-size filter (replacing keyword match)
`objectpaging.cpp:793-799`:
```cpp
const float radius2 = cnode->getBound().radius2() * ref.mScale * ref.mScale;
if (radius2 < dSqr * minSize * minSize && !activeGrid) {
    mSizeCache[refNum] = radius2;
    continue;
}
```
A ref is skipped when its bounding radius² × scale² is smaller than `dist² × minSize²`. That is a **screen-space-projected-size test**: below one pixel (scaled by `minSize`) at this distance, don't bother. This is exactly the filter the user asked for ("only big statics") — but done right. It's tied to actual mesh geometry, not path substrings, so it works uniformly for every mod and every content pack. Failed refs are memoized in `SizeCache` keyed by refnum so subsequent chunks don't re-test them.

### 2.3 Per-mesh-type cost-benefit merge decision
`objectpaging.cpp:829-834`:
```cpp
const float mergeCost = analyzeResult.mNumVerts * size;
const float mergeBenefit = analyzeVisitor.getMergeBenefit(analyzeResult) * mMergeFactor;
const bool merge = mergeBenefit > mergeCost;
```
For each unique mesh type in the chunk, OpenMW asks: is the merge worth the vertex duplication? `mergeBenefit` is the average StateSet reuse count across the whole chunk — a mesh that shares materials with many others benefits heavily from merging (fewer material switches, one draw call). `mergeCost` is `numVerts × chunkSize` — large chunks pay more for high-vertex meshes because every instance gets its geometry deep-copied into the merged blob. Meshes that fail cost-benefit stay as individual transforms with their original cached geometry (osg-native instancing); meshes that pass get flattened + concatenated. **Two output groups per chunk** (`mergeGroup` + `group`), both parented to the chunk root. **This is the crucial insight**: you do not merge everything blindly. Unique meshes stay instanced, repeating meshes merge.

**Our specification of `mergeBenefit_type` for the Godotwind port:**
```
mergeBenefit_type = ref_count_in_chunk × shared_material_count
```
where `shared_material_count` = number of material RIDs used by ≥2 mesh types in this chunk. This is the Godotwind proxy for OpenMW's `AnalyzeVisitor::getMergeBenefit` (which averages `mGlobalStateSetCounter` over `mStateSetCounter.size()`). The intuition is preserved: a mesh type that shares materials with other types benefits from merging (one draw call covers multiple types' materials after flatten); a mesh type whose materials appear nowhere else has nothing to gain from the vertex-duplication tax. `mergeCost = numVerts × size_level_cells` matches OpenMW's `numVerts × size` exactly (both in "MW cell width" units). Both values are computed in the worker-side analyze pass before any copy-and-merge work begins.

### 2.4 Per-type fast-reject before size work
`objectpaging.cpp:55-75` — `typeFilter(type, far)`. REC_STAT, REC_DOOR, REC_ACTI always eligible. REC_CONT, REC_ACTI4, REC_CONT4, REC_FURN4 **only for size=1 chunks** (`!far`). So containers and furniture stay as individual small-chunk draws near camera, disappear entirely from large/far chunks. Cheap pre-filter before the expensive mesh-bound test.

### 2.5 Second-pass `minSizeMergeFactor` re-filter
`objectpaging.cpp:835-846`. After the cost-benefit decision per mesh type, merged refs face a **second** size filter at `minSize × minSizeMergeFactor2`, which scales with how merge-beneficial the type turned out to be. Types with high mergeBenefit use a smaller effective min-size (more refs merged); types with barely-positive mergeBenefit use a tighter min-size (keeps marginal small instances out of the merge). Tightens the cost-benefit loop without hand-tuning per mesh.

### 2.6 Merge primitive = `SceneUtil::Optimizer` + deep-copied drawables
`objectpaging.cpp:930-940`. OpenMW hands `mergeGroup` to osg's `Optimizer` with `FLATTEN_STATIC_TRANSFORMS | REMOVE_REDUNDANT_NODES | MERGE_GEOMETRY`. Each ref was `DEEP_COPY_DRAWABLES` cloned with its transform pushed onto a `MatrixTransform`, so the optimizer can safely merge geometry across refs that share a StateSet. Our current `runtime_hlod_merger.gd` already does the equivalent manually (`_merge_cell_sync` + `_concatenate_surface_arrays`) — we keep that kernel; the architecture change is how we select what to feed it.

## 3. Mapping OpenMW → Godotwind

| OpenMW | Godotwind equivalent |
|---|---|
| `ChunkId = (center, size, activeGrid)` | `ChunkId = (center_cell: Vector2i, size_level: int)` — size_level ∈ {0,1,2} for 1×1, 2×2, 4×4 cells |
| `QuadTreeWorld::ChunkManager` callback | Active-grid walk in `update_for_camera()` computes desired chunks per tier, prunes/creates |
| `GenericResourceManager<ChunkId>` LRU | Existing LRU in `runtime_hlod_merger.gd` — extend keying from `Vector2i` to `ChunkKey` |
| `osg::ref_ptr<osg::Node>` cached chunk | `ArrayMesh + RID` tuple (already in `HLODCellData`) |
| `SceneManager::getTemplate(model)` | `StaticObjectRenderer.get_sub_meshes()` fast path + `.res` model cache slow path (already implemented in `_load_prototype_from_cache`) |
| `osgUtil::Optimizer::MERGE_GEOMETRY` | `_merge_cell_sync` + `_concatenate_surface_arrays` (keep as-is) |
| `ImporterMesh.generate_lods()` equivalent | Already present (`_generate_lods`) — keep |
| `SizeCache : map<RefNum, float>` | New: `Dictionary[int, float]` keyed by `ref.ref_num`, mutex-guarded for worker access |
| `typeFilter(type, size >= 2)` | New: `_type_eligible(object_type, size_level) -> bool` |
| `AnalyzeVisitor` + `getMergeBenefit()` | New: `_analyze_mesh_type(mesh, instance_count, global_stateset_count)` on worker |
| Flat `ESMReader` walk per chunk (`collectESM3References`) | **Replaced** by `ObjectPositionIndex` — prebuilt at startup, O(chunk_cells × avg_refs) query, no ESM re-parsing |

Key Godotwind-specific simplifications:
- **No active-grid concept.** OpenMW's `activeGrid` flag gates things like KF animation binding, disabled refs, and refnum tracking for play-state persistence. Our active cells are already handled by `CellManager` (NEAR tier). Paging only feeds MID+HLOD — passive, no interaction, no animation bindings. Drop the whole `RefTracker` / `RefnumSet` path; our paging output is 100% static.
- **Per-chunk source-LOD pick, not `osg::LOD` graph copy.** OpenMW uses `osg::LOD` with distance ranges in every prototype and intersects them against the chunk's `(smallestDistanceToChunk, higherDistanceToChunk)` range during copy. Our prototypes carry LODs **inside the ArrayMesh** via `surface_lod_indices`. We pick the source LOD level **once per chunk at merge-kernel entry** and feed only that vertex/index set to the merger. Simpler, and it composes cleanly with the post-merge LOD chain (below).

**Two-layer LOD preservation** (answering reviewer + user question on 2026-04-14):

```
Layer 1 — source-LOD pick (per chunk, per mesh-type, before merge):
    size_level = 0 (1×1 chunks, 150-300m)   → source_lod = 0  (full detail)
    size_level = 1 (2×2 chunks, 300-600m)   → source_lod = 1
    size_level = 2 (4×4 chunks, 600-1000m)  → source_lod = 2  (or highest available if LOD chain < 3)

    For each mesh-type candidate:
        arrays = prototype.surface_get_arrays(surface_idx, source_lod)
        # Feed 'arrays' (not arrays[LOD0]) into the concat/flatten kernel

Layer 2 — post-merge LOD chain (per chunk, after merge):
    merged_mesh = concat_and_flatten(all_chunk_refs_using_source_lod)
    ImporterMesh.generate_lods(merged_mesh)   # further decimation inside the merged blob
    # chunk RS instance gets mesh_lod_threshold + lod_bias — Godot's engine selector
    # picks the sub-level per frame from screen-space coverage
```

Net effect for a 900m 4×4 chunk: (a) source geometry is already LOD2 (3-6× decimated from LOD0 at prebake time), (b) merged result gets its own LOD chain from `ImporterMesh.generate_lods()` (another 2-4× at the lowest engine-picked sub-level), (c) screen-space selector picks the active sub-level per frame. Far-chunk face count cannot balloon — it's decimated at prebake, decimated again at merge, and picked down at runtime.

Fallback when a prototype's LOD chain is shorter than `source_lod`: use `min(source_lod, lod_count - 1)`. This preserves correctness for small clutter meshes that prebake at 1-2 LOD levels instead of 4.
- **One merger module**, not two. Today we have `runtime_hlod_merger.gd` (HLOD 300-1000m only) and individual MID RS instances via `StaticObjectRenderer` (150-500m). Post-refactor the pager owns **all** merged chunks across MID + HLOD. `StaticObjectRenderer` continues to own individual-instance draws for: promoted NEAR objects, unmerged types (cost-benefit loses), and refs too small for paging at any level. Hard hand-off (`visibility_range` on both sides).

## 4. Chunk Geometry

Tiers and adaptive chunk sizing:

| Tier | Distance band | Chunk size (MW cells) | Chunk world extent | Typical live count |
|---|---|---|---|---|
| MID-near | 150-300m | 1×1 | 117m | 8-12 chunks around camera |
| MID-far | 300-600m | 2×2 | 234m | 8-12 chunks |
| HLOD | 600-1000m | 4×4 | 468m | 4-8 chunks |
| FAR | 1000-5000m | (impostors unchanged) | — | — |

Hysteresis between bands: 20m margin at each handoff, matching the existing NEAR↔MID 250m/280m scheme in `cell_manager.gd`. Chunk at tier N+1 demotes when camera moves inward past N+1→N start minus margin.

`ChunkKey = (center_cell: Vector2i, size_level: int)`. `center_cell` is the lower-left MW cell of the chunk (aligned to size — a 2×2 chunk at size_level=1 has `center_cell.x % 2 == 0`, same for y). This keeps neighbors non-overlapping and lets the cache survive small camera movements (same chunk stays valid if camera jiggles within a tier band).

## 5. Data Flow

```
[ObjectPositionIndex] ──(query by chunk AABB)─→ [refs in chunk]
                                                      ↓
                                          [type_eligible filter] (2.4)
                                                      ↓
                                          [size_cache lookup] (2.2)
                                                      ↓
                                          [size filter: r²×s² < d²×m²] (2.2)
                                                      ↓
                                          [group by mesh_type]
                                                      ↓
                                          [AnalyzeVisitor per type] (2.3)
                                                      ↓
                              ┌───────────────────────┴───────────────────────┐
                              ↓                                               ↓
                     [merge-eligible types]                         [unmerged types]
                              ↓                                               ↓
                  [minSizeMergeFactor re-filter] (2.5)                  [skip]
                              ↓
                     [concat arrays by material hash]
                              ↓
                     [ImporterMesh.generate_lods()]
                              ↓
                     [merged ArrayMesh, cached by ChunkKey]
                              ↓
                     [RS instance at chunk origin + visibility_range]
```

All per-chunk work from `[group by mesh_type]` down runs on `BackgroundProcessor` worker threads. Main thread only: the ObjectPositionIndex query (fast, already hashed), chunk bookkeeping, RS instance creation.

## 6. Spatial Index Extension

`ObjectPositionIndex` is already built from ESM at startup (`object_position_index.gd:87`). It stores `position`, `model_path`, `scale`, `rotation`, `ref_num`, `object_type`, `is_significant` in a flat spatial hash keyed by `Vector2i(cell_grid)`. **No quadtree rebuild needed** — the flat hash answers chunk queries at the same cost as a quadtree of this depth (3 levels, at most 64 cells per chunk), because each chunk query is bounded by `size² × avg_refs_per_cell` ≤ `16 × ~30 = ~480 refs` for a 4×4 chunk. The `SizeCache` handles per-ref rejection; the `ChunkKey` LRU handles per-chunk rebuild avoidance. A tree structure would save microseconds on query and cost a weekend of implementation + serialization. We ship the flat hash.

**New on `ObjectPositionIndex`:**
- `get_refs_in_chunk(center_cell: Vector2i, size: int) -> Array[ObjectPosition]` — walks `size × size` MW cells, returns all refs. No radius math.
- **`is_significant` is a hint only.** The index stores every ref, including tiny flora/kelp/clutter. The projected-size test on the worker is the only authoritative rejection. The flag remains on the struct for debug-draw / UI filtering use, but paging does not read it. Rationale: an index-time gate breaks MID-near density for tiny clutter at close range — a `flora_kelp` in front of the camera at 20m is visible even if it's size-rejected at 300m, so we must not drop it at index build. Let projected-size handle it per-chunk.

## 7. Module Layout

```
src/core/world/
    object_paging.gd           (new, ~800 lines — replaces runtime_hlod_merger.gd)
    object_paging_kernel.gd    (new, ~300 lines — static worker methods, extracted from merger for clarity)
    object_position_index.gd   (extend — add get_refs_in_chunk, size_cache_query)
    distance_utils.gd          (extend — add PAGING_* constants, size_level_for_distance)
    cell_manager.gd            (small touch — call paging.update_for_camera instead of runtime_hlod_merger)
    static_object_renderer.gd  (small touch — accept "hide if covered by paging chunk" signal)
    streaming_policy.gd        (deprecate is_mid_worthy keyword filter; keep significance hint only for index build)
```

`runtime_hlod_merger.gd` is **deleted**. Its merge kernel lives on in `object_paging_kernel.gd::merge_chunk_sync`; everything else is replaced. This is a load-bearing delete — the file's bespoke cell-scoped assumptions and keyword gating do not generalize, and the Simplicity Over Over-Engineering principle (`.claude/CLAUDE.md`) forbids patching bespoke architecture into a better one.

## 8. Constants (tunable, baseline from OpenMW defaults)

```gdscript
const PAGING_MIN_SIZE: float = 0.14           # projected-size threshold (OpenMW canonical default)
const PAGING_MERGE_FACTOR: float = 256.0      # mergeBenefit scale
const PAGING_MIN_SIZE_MERGE_FACTOR: float = 0.5    # second-pass loosening factor
const PAGING_MIN_SIZE_COST_MULTIPLIER: float = 1.0 # cost vs benefit trade
const PAGING_CHUNKS_PER_FRAME: int = 2        # stagger new builds, same as current MERGES_PER_FRAME
const PAGING_CACHE_BUDGET_BYTES: int = 384 * 1024 * 1024   # +128MB over current HLOD LRU (more tiers to hold)
```

Defaults come straight from `inspos/openmw/components/settings/categories/terrain.hpp:32-39`. **`PAGING_MIN_SIZE = 0.14` is OpenMW's tuned default for Morrowind** and matches the user directive to merge only "big statics, buildings, big trees/rocks". Starting looser (e.g. 0.02) would understate the benchmark win and reintroduce the same clutter-dominates-draw-call problem we're deleting the keyword filter to solve. Loosen only if pop-in is visible under interactive test.

## 9. Interaction With Existing Tiers

**Pre-refactor state** (for clarity on the transition):
- MID individual = 150-500m band for every ref that passes `is_mid_worthy`. Hard `visibility_range` end at 500m.
- HLOD runtime merger = 300-1000m, disabled by default, 1×1 cell chunks.

**Post-refactor state:**
- **NEAR (0-150m):** unchanged. Individual Node3D + physics.
- **MID individual (post 150-250m):** for **refs not contained in any active paging chunk AABB** — i.e. refs that failed the projected-size filter at every tier, OR refs of mesh types that lost cost-benefit at every tier and therefore render as individual RS instances at chunk-origin space (see §2.3). These continue to draw through `StaticObjectRenderer` as individual RS instances with `visibility_range` end at 250m (was 500m). For refs **inside** an active paging chunk, `StaticObjectRenderer.set_instance_visible(false)` is called on chunk activation; no double-draw at any distance.
- **Paging MID-near (150-300m):** 1×1 merged chunks. Covers the 150-300m band for all size/type-eligible refs. Source LOD 0.
- **Paging MID-far (300-600m):** 2×2 merged chunks. Source LOD 1.
- **Paging HLOD (600-1000m):** 4×4 merged chunks. Source LOD 2. Replaces current HLOD merger scope.
- **FAR (1000-5000m):** impostors. **`FAR_START` moves from 500m → 1000m**, so impostors pick up exactly at the HLOD chunk handoff. This closes the full 150m-1km merged band requested by the user on 2026-04-14 (chat id 1023). No gap, no overlap. Previously `FAR_START = MID_END = 500m`; post-refactor `FAR_START = HLOD_END = 1000m`.

Per-tier hand-off is a single-point `visibility_range` swap on each side. No manual fading, no overlap window — engine handles sub-LOD inside each chunk's ArrayMesh LOD chain.

**Constant changes in `distance_utils.gd`:**
```
FAR_START:   500.0  → 1000.0        # impostors start at HLOD end, not MID end
MID_END:     500.0  → 250.0         # individual-MID cutoff for non-paged refs
# HLOD_START/HLOD_END currently 300/1000 — superseded by per-tier paging sizes, deleted.
# PAGING_TIER_0_END = 300.0, PAGING_TIER_1_END = 600.0, PAGING_TIER_2_END = 1000.0 added.
```

## 10. Thread Safety

Same model as current merger:
- **Main thread only:** `ObjectPositionIndex` writes (startup), chunk LRU mutation, RS instance create/free, `StaticObjectRenderer` visibility calls.
- **Worker thread (read):** `ObjectPosition` struct fields (immutable after build), `ArrayMesh.surface_get_arrays()` on prototype meshes (immutable), `Material.get_instance_id()` (immutable). `ImporterMesh` is constructed fresh per chunk — no sharing.
- **Worker thread (read+write, mutex-guarded):** `SizeCache` writes on filter-miss. One mutex per index instance.
- **Completion queue:** existing `_completed_queue` + `_completed_mutex` pattern from current merger. Keep verbatim.

## 11. Build Phases

**Phase 1 — spike (1 day).** Extract merge kernel to `object_paging_kernel.gd` unchanged. Rename `runtime_hlod_merger.gd` behaviourally to "paging with fixed size=1 at old HLOD band." Verify behavioural parity on `bench_progressive` with `hlod_enable`. **This is the rollback point**: if later phases miss budget, we revert to this.

**Phase 2 — projected-size filter + SizeCache.** Replace `StreamingPolicy.is_mid_worthy` call site with the size-based test on worker. `SizeCache` added to the paging module. Measure: cells-per-second merged, bytes/cell, refs-rejected. Expected: 30-50% of refs filtered vs current keyword gate (most `ex_` prefixed clutter under ~1m wide gets culled correctly at distance now).

**Phase 3 — type-filter + cost-benefit + prototype warmup.** `_type_eligible` + `AnalyzeVisitor` equivalent on worker computing `mergeBenefit_type = ref_count_in_chunk × shared_material_count` (see §2.3). Split into `merged_group` / `unmerged_group`. Unmerged refs get a single cached RS instance per unique mesh (share the prototype's mesh_rid, one instance per ref). **Prototype warmup ships in this phase**: on first `update_for_camera` after a camera teleport (`camera.global_position.distance_to(previous) > 500m`), pre-stage prototype `.res` loads for the incoming chunk ring over 2-3 frames instead of hitting them inside `_request_merge`. Prevents the teleport-spike regression. Expected: 2-3× draw call reduction on repeating architecture; no teleport-spike regression; no unique-mesh regression.

**Phase 4 — adaptive chunk sizing (quadtree levels 0/1/2).** `ChunkKey` struct. `update_for_camera` walks three tiers. Hook `StaticObjectRenderer` tier hand-off. Expected: 40-60% reduction in `mid_objects` render cost per `bench_progressive`, target delete of ≥1ms/frame.

**Phase 4.5 (conditional) — MultiMesh per unmerged-type per chunk.** Triggered only if Phase 4 `bench_progressive` shows `mid_objects` still dominating AND per-mesh-type profiling shows the unmerged-group RS-instance count dominating (roaster watchlist: 50-100 unmerged refs × 8-12 chunks = 600-1200 RS instances). Replaces individual RS instances for unmerged types with one MultiMeshInstance3D per (mesh_type, chunk). Loses per-ref visibility_range (MultiMesh cuts whole-group) — accepted because the chunk itself has tier-scoped visibility. Ships only if bench decides; not pre-committed.

**Phase 5 — second-pass `minSizeMergeFactor`.** Last polish; ships with Phase 4 if cost budget is already met. Expected: trims merged vertex count 10-20% without visual change.

**Phase 6 — delete `runtime_hlod_merger.gd`, update `STATUS.md` + `DISTANCE_RENDERING.md`, regenerate baseline CSV.** Final sweep of `is_mid_worthy` call sites; deprecate and delete. **Exported-build smoke test gate:** spin up an export preset build and run a 30-second flyby with paging enabled; verify chunks are materializing (`paging.get_stats().cache_entries > 0` after 10 s of motion) AND `ImporterMesh.generate_lods()` produces LOD chains on worker threads in the exported runtime, not just editor. If `generate_lods` turns out to be editor-only in release, Phase 2 must re-plan: either feed prebake-time LOD chains through the paging kernel (bypass runtime LOD gen), or move LOD gen to main-thread `process_completions` on the exported build only. Gate lives here, not in Phase 1, because earlier phases don't hit the worker-LOD-gen path heavily.

## 12. Budget

Per `docs/audit/STREAMING.md`, the async/streaming budget is 2ms/frame. Paging merges run on `BackgroundProcessor` workers (off-budget). Main-thread work per frame is bounded by:
- 1 `update_for_camera` call per cell change (~once per 50m walk): scans `≤ 3 tiers × (2×chunk_radius+1)² ≤ ~81 ChunkKeys`, all dictionary lookups. Bound: **< 100µs**.
- Up to `PAGING_CHUNKS_PER_FRAME = 2` chunk submissions per frame: each fetches ObjectPositionIndex refs (`≤ ~500 struct reads`), packs input arrays (`≤ ~1000 transform copies`), submits to worker. Bound: **< 0.5ms/frame** under worst-case queue pressure.
- `process_completions`: up to 2 RS instance creates + LRU updates per frame. Bound: **< 0.2ms/frame**.

Total main-thread paging cost: **< 1ms/frame** under continuous motion, zero at rest. Well under the 2ms budget. Worker time per chunk: 20-200ms depending on size_level, absorbed async.

**Worker pool assumption.** `BackgroundProcessor` wraps `WorkerThreadPool`, which sizes itself to `OS.get_processor_count() - 1` capped at engine defaults. On a ≥4-thread machine (baseline target), 200ms × 2 chunks/frame = 400ms wall-time parallelizes to ≤2 simultaneous chunks in flight, leaving ≥2 threads free for other streaming work (NIF loads, texture decode). On a 2-thread machine, paging serializes and chunk latency grows but never blocks main thread. If `BackgroundProcessor` ships a fixed thread count instead of detecting processor count, document the value and test on the low end; do not ship paging with a thread count that starves NIF loads. Re-verify at Phase 3 merge.

## 13. Validation

- **`bench_progressive` with `mid_objects` pass:** primary acceptance. Delta vs baseline must be negative and ≥ 1ms/frame on the scripted flyby. Baseline regenerated before Phase 1.
- **Unit tests (`tests/unit/`):** new `test_object_paging.gd` covering `ChunkKey` alignment, `SizeCache` memoization, type filter table, cost-benefit boundary, `get_refs_in_chunk` coverage vs brute-force ESM walk.
- **Visual test scene:** `tests/visual/test_object_paging.tscn` with console toggles per tier and a `visualize_chunks` debug draw (colored AABB per live chunk, per tier). Interactive only — no auto-capture (`.claude/CLAUDE.md` anti-pattern list).
- **Regression guard:** current NEAR cell fidelity must not change. `test_near_promotion.gd` (if exists, else add) to lock promotion handoff at 250m.

## 14. Known Risks

1. **Material-hash dedup false positives.** Two materials that should share a surface but came from different NIF paths will have different `Material.get_instance_id()` and won't merge. Mitigation: the existing `MaterialDeduplicator` in the NIF pipeline already collapses duplicates by texture+parameters hash before the ArrayMesh is built, so identical-looking materials already share instance ID in practice. Pre-existing behaviour, not a paging regression.
2. **`ImporterMesh.generate_lods()` in exported build.** Used off-main in the current merger and stable in editor. **Unverified in exported release build.** `ImporterMesh` is technically a tool-class in Godot's class hierarchy; some `@tool`-flagged APIs compile out or change behaviour in release. If `generate_lods` is editor-only, paging breaks on the exported runtime even though editor-mode benchmarks pass. **Mitigation: Phase 6 gate runs an exported-build smoke test** (see §11 Phase 6). If the API is editor-only, Phase 2 re-plans: either route prebake-time LOD chains through the paging kernel (bypass runtime gen — `surface_lod_indices` already carries them for the prototypes), or move LOD gen to main-thread `process_completions` only in the exported build (editor keeps worker-side for dev speed). This risk is the only one that can force a re-plan, so it sits behind a hard gate.
3. **Prototype load on cold chunks.** First-ever chunk at a distance may hit `_load_prototype_from_cache` for models not yet registered in `StaticObjectRenderer`. This is a main-thread file load (`ResourceLoader.load` of `.res`). Bounded by `PAGING_CHUNKS_PER_FRAME = 2`. Mitigation: warm-queue prototypes for the chunk ring on first `update_for_camera` call, stagger over 2-3 frames.
4. **LRU oscillation at tier boundaries.** Camera moving around a 600m-radius ring could thrash 4×4 chunks in and out of cache. Mitigation: 20m hysteresis at each tier boundary + `PAGING_CACHE_BUDGET_BYTES = 384MB` keeps ~40-60 4×4 chunks resident.

## 14b. Future Hook — User-Facing Cell Distance Slider

**Not implemented in this plan.** Surfaced by user on 2026-04-14 (chat id 1030) as a low-end-hardware setting: a `cell_distance` slider that shrinks the visible world radius, impacting both individual-MID and paging-HLOD pipelines uniformly.

**Plan-layer preparation (no code, just discipline):** all paging distances in §8 + §9 are declared as `const` in a single file (`distance_utils.gd`). Do **not** hardcode distances inside paging modules — always reference the constant. Do not introduce mid-computation distance expressions that can't be scaled by a single multiplier.

**When the slider ships later**, it becomes a `quality_scale: float ∈ [0.25, 1.0]` multiplier applied to every tier end distance: `effective_tier_end = base_tier_end × quality_scale`. The projected-size filter (`PAGING_MIN_SIZE`) also scales inversely so lower settings match the tighter visibility band (`effective_min_size = PAGING_MIN_SIZE / quality_scale`). One setting, two knobs, whole pipeline scales. Estimated slider implementation: ~half a day, no architectural change — which is exactly the cost target if we avoid baking distances into call sites now.

Settings surface:
```
SettingsManager.get_setting("graphics/cell_distance")  → float ∈ [0.25, 1.0]
```
Default: 1.0 (full range). Low preset: 0.5 (150-500m merged band, impostors @ 500m). Lowest: 0.25 (150-250m merged, impostors @ 250m, closer to vanilla Morrowind view distance).

## 15. What We Are Not Doing (And Why)

- **Prebaked chunks on disk.** The previous attempt. Disk cost dominates. Runtime merge + RAM LRU is OpenMW's answer; we follow it. If VRAM pressure forces paging to disk later, we can add a `.res` sink on top — but not as a default.
- **True loose octree / BVH.** Godot has no native loose octree. The `ObjectPositionIndex` flat hash + `ChunkKey` keying gives us quadtree cache behaviour without a tree. Implementing a full tree is a weekend of serialization work for sub-millisecond query wins. Violates Simplicity principle (`.claude/CLAUDE.md` §2).
- **GPU-side instanced merging (MultiMesh within chunks).** Plausible future work. Today's bottleneck is CPU draw-call count, not GPU instance count. MultiMesh is our FAR tier solution and is already shipping. Revisiting MID/HLOD MultiMesh is a separate thread.
- **Shadow-only chunk pass.** OpenMW doesn't ship one and neither do we. If shadow draw count shows up as a benchmark hotspot post-Phase-4, that's a follow-up, not this plan.

## 16. Rollback

Each phase is independently revertible:
- Phase 1 → Phase 0: restore `runtime_hlod_merger.gd` from git; trivial.
- Phase 2-5 → Phase 1: `git revert` the phase commit; merge kernel unchanged.
- Phase 6 cannot roll back standalone (deletes the old module); gated behind `bench_progressive` ≥ 1ms/frame win.

## 17. Review Resolutions (closed)

Reviewer pass 2026-04-14 (roaster, chat id 1020) — all six must-fixes applied, three open questions resolved:

1. **`PAGING_MIN_SIZE = 0.14`** (OpenMW canonical default), not 0.02. Rationale: matches user directive "only big statics"; 0.02 understates benchmark win and reintroduces the clutter-dominates-draw-call problem we're deleting the keyword filter to eliminate. Loosen only if pop-in visible under interactive test. Applied §8.
2. **Prototype warmup ships with Phase 3**, not Phase 4. Applied §11.
3. **`mergeBenefit_type` formula specified**: `ref_count_in_chunk × shared_material_count`, where `shared_material_count` = material RIDs used by ≥2 mesh types in the chunk. Applied §2.3.
4. **`is_significant` is hint-only** (not an indexing-time gate). Index everything; projected-size test is the only authoritative rejection. Applied §6.
5. **§9 MID-individual band consistency**: pre 150-500m → post 150-250m **for refs outside every active paging chunk AABB**. Applied §9.
6. **`ImporterMesh` exported-build verification** moved to Phase 6 hard gate with re-plan branch for Phase 2. Applied §14 / §11.
7. **(nice-to-have)** Worker-pool thread-count assumption documented. Applied §12.
8. **(nice-to-have)** Phase 4.5 (MultiMesh-per-unmerged-type-per-chunk) added as conditional, bench-decided. Applied §11.

Reviewer re-engages at implementation draft.
