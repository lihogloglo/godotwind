# Distant Rendering Audit — 2026-04-17

**Auditor:** claude (via #audit channel)
**Scope:** full map of the distant-rendering pipeline in `src/core/world/`, compared against AAA canonical approaches, judged against a 140 FPS horizon-range target on Godot 4.6 Forward+ (D3D12, no bindless, no GPU-driven).
**Method:** read every file in `src/core/world/` plus direct consumers in `src/core/streaming/` and `src/core/gpu_driven/`. External research covered RDR2 SLOD, UE5 non-Nanite HLOD, Frostbite static batching, Decima tile instancing, CryEngine `CMergedMeshRenderNode`, OpenMW Object Paging.
**Ground truth:** code only. `docs/` treated as aspirational. CLAUDE.md claims were verified line-by-line.

---

## 0. Executive Summary

Godotwind has **four physical tiers** (NEAR / MID / HLOD / FAR) plus **two parallel meta-systems** (Terrain3D clipmap, DistantLightManager billboard) plus **three orphan/abandoned features** (GPUSceneDatabase SSBO, HorizonMapManager, MidTierBatchPool — the last one removed, the first two built but unconsumed). The architecture is broadly aligned with the canonical non-Nanite AAA answer (per-cell merging + impostors at range), but there are **three structural gaps** blocking the 50 → 140 FPS jump:

1. **MID-tier draw-call density.** MID renders one RS instance per object by default. Per-cell MultiMesh batching (`batch_cell_into_multimesh`) exists, but it's gated at ≥4 same-type instances and excludes multi-sub-mesh prototypes (buildings). Most architecture flies as individual draws. AAA canonical is one MultiMesh per (mesh, material) hash across the whole loaded set — not per-cell-per-type with a floor.
2. **HLOD / MID double-render hazard.** `object_paging.gd` and `static_object_renderer.gd` both iterate ESMManager refs to populate their own instance arrays. There is **no dedup handoff** — when HLOD is enabled (`hlod_enable` console cmd), a ref within an active HLOD chunk may also be rendered as a live MID instance. The code says HLOD flips `StaticObjectRenderer.visibility_range_end` to 300m, which range-culls MID past the HLOD start, but it does NOT remove the already-created MID instances from the scenario; they stay registered, frustum-culled per frame, and count toward the instance budget. Verify against `native_streaming_manager.gd:429-431`, `object_paging.gd:641-735`.
3. **Main-thread stalls in two places.** (a) `native_impostor_renderer._rebuild_texture_array` (line 1729) does a blocking `Texture2DArray.create_from_images` — 6-8 ms stall per rebuild, fires up to 4× per second. (b) `reference_instantiator` creates one fade-in Tween per object (line 1226); burst-loading cells can emit 100+ tweens in one frame, each with its own lifecycle.

None of these is individually catastrophic. Compounded they explain the ~50 FPS floor. A structural fix to (1) is the biggest single lever. (2) and (3) are mechanical cleanups once the MID draw-count is in range.

**Hardware baseline assumption:** Godot 4.6 Forward+ opaque statics cost roughly 3-15 µs CPU-side per unique draw in a non-bindless pipeline (GDC 2019 "Advanced API Performance", confirmed by Baldur Karlsson's DX12 writeups). At 140 FPS the full CPU command-submission budget is ~7.1 ms/frame; realistic static-draw budget after player + UI + streaming work is ~2-3 ms. That's **3,000-8,000 unique draws max**, and you want most of them to be `MultiMesh`-instanced (one draw, N instances). Godotwind's reported `RENDER_TOTAL_DRAW_CALLS_IN_FRAME` (see `native_streaming_manager.gd:507`) is the key performance number — I'd expect it to exceed this budget substantially at horizon range, which is the primary 50-FPS driver.

---

## 1. System Map

```
                              CAMERA POSITION
                                    │
                                    ▼
                    ┌───────────────────────────────┐
                    │  NativeStreamingManager       │  ( Node3D, _process every frame )
                    │  - reads camera pos           │
                    │  - tracks _camera_cell        │
                    │  - runs 8 phases per frame    │
                    └───────────┬───────────────────┘
                                │ dispatches via cell events + per-frame budgets
        ┌───────────────────────┼────────────────────────────┬──────────────────────┐
        ▼                       ▼                            ▼                      ▼
┌───────────────┐   ┌────────────────────┐   ┌──────────────────┐   ┌──────────────────────┐
│ CellManager   │   │ StaticObjectRend.  │   │ ObjectPaging     │   │ NativeImpostorRend.  │
│ (RefCounted)  │   │ (Node3D)           │   │ (Node3D)         │   │ (Node3D)             │
│ -------------- │   │ MID tier           │   │ HLOD tier        │   │ FAR tier             │
│ ESM → Node3D │   │ 150-500m          │   │ 300-1000m        │   │ 500m-5km             │
│ NEAR build    │   │ ONE RS / object  │   │ merged ArrayMesh │   │ MultiMesh billboard  │
│ (0-150m)      │   │ + optional       │   │ per chunk        │   │ octahedral tri-sample│
│               │   │ per-cell MM batch │   │ 1x1 / 2x2 / 4x4  │   │ 256-slot TexArray    │
└──────┬────────┘   └────────────────────┘   └──────────────────┘   └──────────────────────┘
       │
       │ spawns
       ▼
┌───────────────────────────────────────────────┐
│ ReferenceInstantiator                          │
│ - PackedScene → Node3D                         │
│ - ObjectPool (pooled common models)            │
│ - fade-in Tween per object  ← HOTSPOT         │
│ - ModelLoader async via ResourceLoader         │
│ - CharacterFactoryV2 for NPCs                  │
└───────────────────────────────────────────────┘

         PARALLEL META-SYSTEMS (separate ownership, also camera-driven)
         ─────────────────────────────────────────────────────────────
                    ▲                                    ▲
                    │                                    │
        ┌───────────┴────────────┐           ┌───────────┴────────────┐
        │ Terrain3D (v1.0.1)      │           │ DistantLightManager    │
        │ internal clipmap LOD    │           │ 150-5000m billboard    │
        │ region=256 vertices,    │           │ MultiMesh, max 4096    │
        │ 4x4 MW cells per region │           │ + LightShadowBudget    │
        │ 3 regions live (~4.6km) │           │   0-8m CUBE / 8-30m DP │
        │ streamed by             │           │ + LightAnimator @15fps │
        │ GenericTerrainStreamer  │           │ scans ESM cells,       │
        │ + MorrowindDataProvider │           │ not loaded tree        │
        └─────────────────────────┘           └────────────────────────┘

         ORPHANS / PARKED (built, not consumed, not blocking)
         ────────────────────────────────────────────────────
         - GPUSceneDatabase: SSBO for 100k objects, populated on cell load,
           no consumer shader (gpu_scene_database.gd). Dead allocation path.
         - HorizonMapManager: infrastructure kept, all uniforms removed.
         - MidTierBatchPool: removed; replaced by per-cell MM inside
           StaticObjectRenderer. Only referenced in comments now.
         - terrain_horizon.gdshader: now a wet-map-only extension of the
           Terrain3D internal shader. Horizon-angle code was removed.
         - impostor_candidates 9-category filter set: selects ~50k refs as
           FAR-eligible. Works, but the MultiMesh rebuild pipeline behind it
           is a 6-8ms main-thread stall on every rebuild tick.
```

---

## 2. Subsystem Inventory

### 2.1 NativeStreamingManager — orchestrator
- `src/core/world/native_streaming_manager.gd` (2,162 lines), `Node3D` class.
- `_process(delta)` runs 8 phases every frame, each gated by a per-phase time budget (default 8 ms `INSTANTIATION_BUDGET_MS`, 4 ms post-startup):
  1. heartbeat log every 5 s (lines 497-530)
  2. camera cell-change detect + `_update_loaded_cells` (line 567-575)
  3. HLOD `process_merge_queue` + `process_completions` + `update_for_camera` on cell change (lines 593-599)
  4. DistantLightManager update (line 602)
  5. budgeted unloading (line 622)
  6. async completions + progressive instantiation (lines 634, 648)
  7. MID→NEAR promotion scan + demotion (line 667)
  8. pending cell load dispatch (line 688)
- Owns `_loaded_cells`, `_loading_cells`, `_unloading_cells`, `_pending_load_queue`, `_pending_rs_hide_cells`, and the `_promoted_by_cell` spatial index.
- Sets per-instance `visibility_range` ONLY as a non-prebaked fallback in `_apply_fallback_visibility_recursive` (line 1419-1430). Prebaked NIFs carry `visibility_prebaked` meta and are skipped (line 1404).
- Velocity-predicted pre-queue for cells in movement direction (lines 833-878). EMA-smoothed camera XZ velocity.

### 2.2 CellManager — ESM → Node3D container
- `src/core/world/cell_manager.gd` (2,366 lines), `RefCounted` class.
- Three load paths: `load_cell` (interior), `load_exterior_cell` (full sync), `load_exterior_cell_metadata_only` (AAA mode, container node + meta flags only, no objects).
- Async path: `request_exterior_cell_async` → `BackgroundProcessor` (WorkerThreadPool wrapper) parses NIFs, results consumed via `process_async_instantiation` budget (line 648 of the streaming manager).
- Owns `ReferenceInstantiator` + `ObjectPool` + `CharacterFactoryV2` + `StaticObjectRenderer` reference.
- Routes `immediate_promotions` back to the streaming manager for same-frame RS→Node3D promotion when the camera is already near on cell load.
- Also forwards objects to `GPUSceneDatabase` via `set_gpu_scene_db` (line 1005) — currently a write-only dead-end.

### 2.3 StaticObjectRenderer — MID tier (150-500m)
- `src/core/world/static_object_renderer.gd` (1,064 lines), `Node3D` class.
- **Default mode: one `RenderingServer.instance_create` per object**, per mesh child. Single-mesh flora → 1 RID. Multi-sub-mesh buildings (cantons, Hlaalu huts) → N RIDs under one logical `InstanceData.id`. Verified at lines 355-357, 409-410.
- Per-instance engine LOD:
  - `instance_geometry_set_visibility_range(rid, 0, visibility_range_end, 0, FADE_MARGIN_LOD3_FAR=20m, VISIBILITY_RANGE_FADE_SELF)` (line 425-430).
  - `instance_geometry_set_lod_bias(rid, 1.0)` (line 433).
  - Sub-LOD selection entirely engine-driven via `ArrayMesh.surface_lod_indices` stamped by `nif_converter.gd` at bake time.
  - `visibility_range_end` = 500 m default, flips to 300 m when HLOD is enabled (streaming manager line 431).
- **Per-cell MultiMesh batching** in `batch_cell_into_multimesh` (line 589-650):
  - Fires at `cell_manager._finalize_request` after all instances in a cell are added.
  - Groups cell instances by `type_name`, collapses any group with `size >= MM_BATCH_MIN_COUNT (4)` into one `MultiMesh` anchored at the cell centroid (line 685-701).
  - The per-instance `sub_rids` are freed (line 739-742), the instance is re-addressed via `mm_slot + batch`.
  - **Skips multi-sub-mesh prototypes** (line 620-621): buildings never batch. Comment claims "per-instance frustum culling beats batching for high-vertex-count objects" — but this blocks the single biggest draw-call win for horizon rendering (Vivec cantons, Hlaalu towns).
- Zero per-frame work inside this class. All updates are cell-event-driven. Distance queries in `get_promotable_instances` are invoked by the streaming manager's promotion phase, which itself is gated by `PROMOTION_FRAME_INTERVAL = 2` (every other frame).

### 2.4 ObjectPaging — HLOD tier (300-1000m, adaptive 1x1 / 2x2 / 4x4)
- `src/core/world/object_paging.gd` (953 lines) + `object_paging_kernel.gd` (384 lines).
- Worker thread: cost-benefit analysis, vertex transforms, material grouping, mesh concatenation (`_merge_chunk_worker`, line 770-781). No scene-tree access from workers; all data pre-collected on main thread.
- Main thread: MeshType registration, `RenderingServer.instance_create`, LOD finalization via `ImporterMesh.generate_lods(60° merge_angle, 0.25 screen_coverage)` (kernel line 189).
- One merged `ArrayMesh` per chunk with **N surfaces** (one per material group). One RS instance per chunk at chunk-center world position (line 807). Surface LOD cascade embedded, `instance_geometry_set_lod_bias(rid, 1.0)` (line 818).
- Merge gate is multi-stage: `MIN_REFS_TO_MERGE=5`, type-eligible filter (STAT / DOOR / ACTI, CONTAINER tier-0 only), `mesh_radius² × scale² >= dist² × PAGING_MIN_SIZE_SQ` projected-size test, SizeCache rejection memo, cost-benefit per mesh-type (`mergeBenefit × PAGING_MERGE_FACTOR(256) > mergeCost`), Phase-5 per-ref `minSizeMerged²` second pass. This is a faithful port of OpenMW's algorithm.
- Top-down adaptive classification: 4x4 chunks claim first in `[600, 1000)` and mark 16 sub-cells covered; 2x2 fills `[300, 600)` over uncovered cells; 1x1 fills `[150, 300)` over remaining cells. Hysteresis margin `PAGING_HYSTERESIS = 20m` (line 485-503).
- Staggered 2 merges / frame (`MERGES_PER_FRAME = 2`), 15 warmup loads / frame during teleport cold-start.
- **Known gaps flagged by the explore pass:**
  - No HLOD / MID deduplication handoff — see §5.1.
  - LRU eviction of chunk RS instances logs a warn but does not validate that the chunk is inactive before freeing (line 860).
  - C# kernel is optional; if the native DLL fails to load, merges silently no-op (kernel line 88).
  - `SizeCache` mutation is guarded only on write; concurrent reads under heavy load have a narrow race (line 688-690).

### 2.5 NativeImpostorRenderer — FAR tier (500m-5km)
- `src/core/world/native_impostor_renderer.gd` (1,859 lines) + `impostor_candidates.gd` (718 lines).
- **One global `MultiMeshInstance3D` for all impostors**, camera-facing billboard on a `QuadMesh`. Custom shader embedded in `_get_octahedral_shader_code` (line 355-598).
- Texture strategy: two parallel `Texture2DArray`s (albedo + normal), 256 layers max, 256² RGBA8 uncompressed (BC7 triggers c0000005 on 4.6 Forward+, line 1719). ~128 MB VRAM baseline.
- Octahedral mapping: true octahedral with Brucks tri-sample barycentric blending on an 8×8 grid (V5 path, lines 481-542). Legacy 16-frame azimuthal fallback (V4, lines 545-555).
- Fade: native `visibility_range_begin = 480m`, `visibility_range_end = 5000m`, `VISIBILITY_RANGE_FADE_SELF`. Fragment-shader safety discard inside the fade zone.
- **Rebuild hot path (flagged in §0):**
  - `_rebuild_texture_array` (line 1729) — blocking `Texture2DArray.create_from_images`, 6-8 ms main-thread stall per rebuild. Uncompressed upload, sequential layer-by-layer.
  - `_rebuild_multimesh` (line 1757-1826) — writes 70k-instance buffer via `set_buffer` in one shot, ~5-10 ms at steady state.
  - Rate-limited: `MULTIMESH_REBUILD_INTERVAL = 0.5 s`, `MULTIMESH_REBUILD_DEBOUNCE = 0.2 s`, min 500 impostors to fire.
- Texture bake: async via `BackgroundJobSystem` (2 worker threads) for PNG `Image.load` and `.res` normal `ResourceLoader` calls.
- Selection: `impostor_candidates.gd` has 9 manually curated pattern families (LANDMARK, LARGE_BUILDING, TERRAIN_FEATURE, TREE, VEGETATION, PROP, ARCHITECTURE_DETAIL, RUIN, CAVE). Texture resolution is per-family (1024 for landmarks, 128 for small props).

### 2.6 ReferenceInstantiator — NEAR-tier build path
- `src/core/world/reference_instantiator.gd` (1,301 lines), `RefCounted`.
- Pipeline: ESM record → `ModelLoader.get_model()` → cached PackedScene → `instantiate()` → `Node3D` → optional `ObjectPool` → cell container.
- Prebaked `.res` files live in `Documents/Godotwind/cache/models/`; runtime NIF conversion is disabled (`runtime_mode=true`, line 63).
- **Fade-in Tween per object** (line 1226, `parallel=true`): a burst cell load that emits 100+ objects in a single frame fires 100 Tweens, each with its own lifecycle + script callback. One of the most suspicious hotspots.
- Object pool `.duplicate()` for pool entry creation (line 331) does a full node-tree copy synchronously; LRU eviction sorts the full cache when >500 entries (line 237).
- Mesh-load race (fixed commit `a541dd1`): old code duplicated a single PackedScene root, sharing sub-resource meshes/materials across siblings. Fix: every `_instantiate_from_scene` returns a fresh `instantiate()` result; disabled collision on pool-idle (line 602); `CACHE_MODE_IGNORE` on async re-load to force fresh handles.

### 2.7 ObjectPool
- `src/core/world/object_pool.gd` (556 lines).
- Per-model max 80, global 10,000 (CLAUDE.md says 2,048 — code disagrees). Parent-node stored (line 88-96) so released instances have a parent and don't get GC'd.
- `_reset_instance` walks the full subtree recursively to clear stuck fade ShaderMaterials (lines 372-385). Potential cost at high release rates.

### 2.8 ModelLoader
- `src/core/world/model_loader.gd` (1,096 lines).
- `ResourceLoader.load_threaded_request` for async; `_pending_instantiate_queue` defers PackedScene instantiation to the next frame to side-step the sub-resource race.
- Heartbeat logging at `instantiate_attempt` / `instantiate_done` is used as the crash forensic marker (`native_streaming_manager.gd:496`).

### 2.9 ObjectPositionIndex
- `src/core/world/object_position_index.gd` (489 lines).
- Spatial hash keyed by cell (117 m cell size). Flat array per cell bucket. O(cells_in_radius × objects_per_cell) radius query.
- Built once at startup from all exterior cells (line 87). Supports serialized save/load (lines 383-487) for faster re-launch.

### 2.10 Terrain3D + GenericTerrainStreamer
- `src/core/world/terrain_manager.gd` (849 lines) + `generic_terrain_streamer.gd` (769 lines).
- Terrain3D v1.0.1 addon, region size 256 vertices, 4×4 MW cells per region, 6 m vertex spacing.
- Streamer driver: camera-region detection (`_on_region_changed` line 323-380), frustum-priority queue, 1 region loaded per frame max, 2 unloaded per frame, 8 ms generation budget.
- Live region count: 3-5 (~4.6 km view cone), unload threshold 5 regions.
- Streamer is agnostic to CellManager — it calls the provider directly (`MorrowindDataProvider` / `LapalmaDataProvider`). Heightmap + control map + color map fetched per-region.
- Terrain3D internally does clipmap LOD; Godotwind has no visibility into its per-frame cost.

### 2.11 DistantLightManager + LightShadowBudget + LightAnimator
- `distant_light_manager.gd` (364 lines). 150-5000 m billboard MultiMesh, cap 4096 instances, single draw call. `_scan_cells_around` pulls light refs from ESM without requiring cell instantiation. Near-fade smoothstep at 150 ± 30 m for crossfade with real OmniLight3D.
- `light_shadow_budget.gd` (161 lines). 0-8 m CUBE (6 passes), 8-30 m DUAL_PARABOLOID (2 passes), >30 m no shadows. 0.5 s update interval, hysteresis ±2 m. O(n) sort of tracked OmniLight3D nodes every update tick.
- `light_animator.gd` modulates energy at effective 15 FPS via temporal smoothing (cost O(animated_lights), no frustum check).

### 2.12 HorizonMapBaker + HorizonMapManager + terrain_horizon.gdshader
- `horizon_map_baker.gd` (123 lines) + `horizon_map_manager.gd` (85 lines) + `terrain_horizon.gdshader`.
- Baker: 2 RGBA8 textures per region encoding max elevation angles in 8 compass directions, CPU marching up to 64 texels per direction. Offline.
- Manager: all horizon uniforms removed (line 6-8 note). Currently only pushes `wet_map` uniforms (Lagarde PBR wet-darkening below `sea_level + wet_margin`).
- Shader: wet-map only now, terrain-horizon shading code gone.

### 2.13 GPUSceneDatabase — built, unconsumed
- `src/core/gpu_driven/gpu_scene_database.gd`. 100k × 96-byte SSBO for object transforms + AABBs + mesh IDs. Allocated on cell load via `add_cell_objects` (cell_manager line 2098).
- **No consumer shader exists.** Grep for `_object_buffer` usage: only `add`, `remove`, `cleanup`. The entire data upload path is a dead allocation. This is the most visible "planned but not wired" feature.

---

## 3. AAA Research — how the industry does this in 2025

Full research brief (sourced from GDC talks, Epic docs, Rockstar SIGGRAPH 2019 advances course, Warhorse CryEngine posts, OpenMW PR #2187, Frostbite GDC 2017, etc.) is included verbatim in §8.

Condensed findings relevant to the 140 FPS target on a non-Nanite, non-bindless engine:

1. **Non-Nanite canonical answer is still per-spatial-bucket merging.** RDR2 SLOD, UE5 HLOD fallback, Frostbite static batching, CryEngine `CMergedMeshRenderNode`, Decima tile instances, OpenMW Object Paging — every AAA open-world title that ISN'T Nanite uses "pre-merge statics per spatial bucket, draw the bucket as one instanced call." Godotwind's HLOD tier is architecturally correct. UE5 Nanite is the only pipeline that replaced this, and it requires mesh shaders + hardware indirect + visibility buffer, none of which Godot 4.6 exposes to user code.
2. **Draw-call budget at 140 FPS** in a non-bindless DX12 pipeline is ~3,000-8,000 unique draws, with everything else being instanced (one draw, N instances).
3. **The Frostbite lesson (Wihlidal GDC 2016)**: one instance buffer per material, sort front-to-back for early-Z, merge at stream-in time. In Godot terms: one `MultiMeshInstance3D` per (mesh, material) hash.
4. **Imposters.** Octahedral is correct, Brucks tri-sample is the current state of the art (UE4/5 Impostor Baker plugin), V5 path in `native_impostor_renderer.gd` already implements this. RDR2 SLOD4 is NOT octahedral — it's pre-baked multi-view billboards (unverified as runtime octahedral).
5. **Virtual textures / bindless are OUT of scope** for Godot 4.6. Closest substitute: per-region `Texture2DArray` + `MultiMesh.set_instance_custom_data` as atlas-index per instance. Godotwind does this for impostors but not for MID-tier statics.
6. **Godot 4.6 features we are not using fully:**
   - `MultiMeshInstance3D.multimesh.set_instance_custom_data()` — 4 floats per instance, usable as atlas-index + tint, enabling "one draw per material" even with per-instance variation.
   - `OccluderInstance3D` with baked `Occluder3D` — authored at NIF conversion for buildings >3 m / rocks >4 m (`nif_converter.gd:674-781`), but the baseline CLAUDE.md warns "occlusion culling buggy outdoors, enable for interiors only" — so these per-object occluders may not be active outdoors today.
   - `RenderingServer.multimesh_set_buffer` with `PackedFloat32Array` — used by the impostor renderer, not by HLOD or per-cell batching (both use the per-instance `set_instance_transform` loop).
   - `WorkerThreadPool.add_group_task` — `object_paging` uses single-task submission; parallel chunk merging across cores is free available throughput.
   - `GeometryInstance3D.visibility_range_begin/end` with `FADE_SELF` — used for MID and FAR, but NOT applied to per-cell `MultiMesh` batches at the cluster level; they are anchored at cell centroid and fade as a whole, which is correct but means the per-object distance tuning is lost. Tolerable trade.

---

## 4. Godot 4.6 Capability Map

| AAA technique | Godot 4.6 path | Status in Godotwind |
|---|---|---|
| Hierarchical LOD cluster (RDR2 SLOD / UE5 HLOD / CryEngine CMerged) | Runtime `ArrayMesh` merge + `RS.instance_create` per chunk | **Implemented** (`object_paging.gd`), disabled by default, dedup gap (§5.1) |
| Per-material static batching (Frostbite) | `MultiMeshInstance3D` per (mesh, material) hash | **Partial** — per-cell-per-type only, buildings excluded, threshold 4 |
| Octahedral impostors with tri-sample blend (UE Impostor Baker / Brucks) | `MultiMesh` + `Texture2DArray` + custom shader | **Implemented** (`native_impostor_renderer.gd` V5), main-thread rebuild stall |
| Tile-based foliage (Decima / CryEngine veg) | `MultiMeshInstance3D` per (species, cell) via `MeshLibrary` | **Not present** — foliage goes through MID individually until ≥4 per cell |
| Virtual / sparse textures (RDR2, Frostbite) | Not available | N/A on 4.6 |
| GPU-driven culling (Frostbite, UE5) | Not available to user code | GPUSceneDatabase exists as a dry-run scaffold, no consumer shader |
| Sector / portal culling (id Tech 7, HL2) | `OccluderInstance3D` + baked `Occluder3D` | **Implemented per-building at bake time**, reportedly buggy outdoors |
| Mega-texture atlasing | `Texture2DArray`, offline-baked | **Done for impostors**, not for MID statics |
| Clipmap terrain | Terrain3D addon, built-in clipmap | **In use** (v1.0.1 stable) |
| Distant lights as billboards | `MultiMesh` + custom shader | **Implemented** (`distant_light_manager.gd`), 4096 cap |
| LOD cascade embedded in mesh | `ArrayMesh.surface_lod_indices` + `ImporterMesh.generate_lods` | **In use** at prebake + HLOD merge |

**Gaps vs AAA non-Nanite canonical:**
- No per-species foliage MultiMesh at MID range.
- No per-material static batcher that spans multiple cells.
- No consumer for GPUSceneDatabase.
- No shadow caster distance cap on the directional sun light (found via grep — only `shadow_normal_bias = 1.5` is set at `sky_manager.gd:278`; Godot's `directional_shadow_max_distance` project setting would cut shadow-map rasterisation cost significantly at horizon range).

---

## 5. Structural Issues

### 5.1 HLOD / MID double-render hazard
**Symptom:** when `hlod_enable` is on, a ref contained within an active HLOD chunk will also exist as a MID-tier `StaticObjectRenderer` instance with `visibility_range_end = 300m`. It is range-culled visually, but it is still:
- A live `RS.instance_create` in the scenario (frustum culled per frame).
- Counted toward `_stats.total_instances`.
- Counted toward `RENDER_TOTAL_OBJECTS_IN_FRAME`.
- Subject to per-instance `visibility_range` / `lod_bias` bookkeeping.

**Where the code diverges:** `native_streaming_manager.gd:429-431` sets `_static_renderer.visibility_range_end = DU.HLOD_START` when initializing HLOD. That flips the 500 m cull to 300 m. It does NOT call `StaticObjectRenderer.remove_instance` or `remove_cell_instances` for refs absorbed by an HLOD chunk. `object_paging._compute_desired_chunks` never notifies the static renderer which refs it swallowed.

**Recommendation:** either
- (a) Have `object_paging` publish a "covered-refs-per-chunk" registry and call `StaticObjectRenderer.remove_instance` on chunk creation / restore it on chunk destruction, or
- (b) Reverse the ownership: MID is always 150-300 m only (even without HLOD), HLOD is always the 300-1000 m authority; when HLOD is off, run a degenerate HLOD-of-one-ref-per-chunk. Fewer moving parts.

### 5.2 MID-tier draw-call density
**Symptom:** buildings (multi-sub-mesh prototypes) are explicitly excluded from `batch_cell_into_multimesh` (line 620-621). Each Vivec canton face / Hlaalu wall panel / Redoran pod piece is a unique RS instance, forever. Trees / rocks / clutter collapse to per-cell MultiMesh only when ≥4 of the same type are in the same cell. Shared prototypes across cells (fl_kelp, terrain_rock_01, same tree species everywhere) do NOT collapse, because batching is per-cell.

**Recommendation:** lift the per-cell constraint and run a **world-scoped per-prototype MultiMesh**:
- One `MultiMeshInstance3D` per `(mesh_resource, material_override)` hash, spanning all loaded MID-tier cells.
- Add/remove slots as cells stream in/out (existing `CellBatch.set_instance_transform(slot, ...)` pattern extends naturally).
- Still hit the `visibility_range` hard-cull at 300 m (with HLOD) / 500 m (without), but at the *batch* centroid which becomes a per-prototype world-centroid updated once per cell change.
- Buildings specifically need splitting: each sub-mesh type gets its own batch across all instances of that prototype. Comment's "per-instance frustum culling beats batching" argument loses when the instance count crosses a few hundred; frustum culling is cheap, state changes are expensive.

Worth profiling `RENDER_TOTAL_DRAW_CALLS_IN_FRAME` before vs after. Expected: the single largest FPS delta in the whole system.

### 5.3 Impostor main-thread stall
**Symptom:** `_rebuild_texture_array` is blocking; `_rebuild_multimesh` writes 70k-instance buffer in one shot. Fires up to 4 Hz.

**Recommendation:** double-buffer the texture array — keep the current array live on the GPU, build the new array on a worker thread via `RenderingDevice.texture_create` + `texture_update`, and atomically swap the `MultiMeshInstance3D.material_override.set_shader_parameter("texture_atlas", new_array)` on the main thread. The MultiMesh buffer upload can be moved to `WorkerThreadPool` too — `multimesh_set_buffer` with a `PackedFloat32Array` is thread-safe against RID ops. Pair this with a max-4 Hz tick from the streaming manager to keep the texture-array A/B swap cadence under control.

### 5.4 Fade-Tween spam in ReferenceInstantiator
**Symptom:** `create_tween().tween_property(...)` per instantiated object. With a burst cell load landing 100+ objects in one frame the scheduler eats ~100 Tween lifetimes. Each Tween has a script-level finished callback that re-reads the object.

**Recommendation:** drop per-object Tween. Use either
- (a) `visibility_range_begin_margin` on the root `GeometryInstance3D` with `FADE_SELF` to cross-fade in shader without any script state, or
- (b) one global Tween that drives a shader parameter `time_of_spawn` per instance, read from `MultiMesh.instance_custom_data.w` (a single 4-float custom data slot) and compared to `TIME` in the shader. O(1) on CPU, cost-free on GPU.

### 5.5 GPUSceneDatabase ghost code
**Symptom:** 100k-slot SSBO allocation, fill path on every cell load (`cell_manager.gd:2098`), zero consumer. Every cell load does a packed-buffer fill + a byte-copy for no rendered result. Small waste per cell, steady CPU drip.

**Recommendation:** either wire it into a compute culling pass (probably out of scope for 4.6) or delete it. The fill code is called from the async completion path, so this is a measurable allocation per cell for no return.

### 5.6 LightShadowBudget sort + LightAnimator unscreened ticks
**Symptom:** every 0.5 s the budget sorts all tracked OmniLight3D nodes by distance. Light animator ticks at effective 15 FPS on all animated lights regardless of frustum.

**Recommendation:** keep the sort, but gate the animator on `is_visible_in_tree()` or on a per-camera distance pre-check. With a ~4-km light radius + many cells loaded, animated lights beyond the shadow cutoff can still tick every 66 ms when they don't need to.

### 5.7 Directional sun shadow is not distance-capped
**Symptom:** `sky_manager.gd:278` only sets `shadow_normal_bias = 1.5`. No `directional_shadow_max_distance` / `directional_shadow_split_1/2/3` tuning visible in `src/`. Godot's default is 100 m with 4 splits; on a horizon-range world, shadow map rasterisation past the MID tier is waste.

**Recommendation:** set `directional_shadow_max_distance` to `NEAR_END` (150 m) or `MID_END` (500 m) depending on perf target, and tune `directional_shadow_split_1/2/3` for the smaller tier. Horizon buildings at >1 km don't need the sun shadow to extend; the impostor baked normals already carry shading.

---

## 6. 50 → 140 FPS Feasibility

**Short answer: yes, but it's a structural refactor of §5.2 plus the mechanical fixes in §5.1 / §5.3 / §5.4.** Not a tuning pass.

Decomposition of the gap (rough — based on draw-call-count ceilings from the research + the hotspots flagged):

- **Draw-call density at MID (§5.2)** — biggest lever. Collapsing multi-sub-mesh buildings into per-prototype MultiMesh batches plus world-scoped batching for flora should land the world-total unique-draws-per-frame in the 3-8k range at horizon view. Expected delta: +30-50 FPS.
- **HLOD dedup (§5.1)** — with HLOD enabled, removes up to ~half the MID instance count in the 300-1000 m band. Expected delta: +5-15 FPS when HLOD is on.
- **Impostor stall (§5.3)** — 6-8 ms stall 4×/s is a 24-32 ms/s steady drain at startup settling; it's periodic, not additive, so fixing it removes ~2 FPS average and eliminates a visible hitch. Mostly a smoothness win, not a throughput one.
- **Tween spam (§5.4)** — during cell load bursts, observed tween-wall spikes; shader-driven fade gets rid of it. Expected: removes a specific class of 1-frame hitch, not an average-FPS win.
- **Shadow distance cap (§5.7)** — likely one of the cheaper 5-10 FPS wins and a 1-line project setting change. Worth doing first to de-risk the profiling baseline.

**Floor items that will still block 140 FPS if nothing else is done:**
- Terrain3D clipmap cost is opaque to us; if the addon itself is blowing the shadow map / draw budget on its own splats, there's no Godotwind-side lever. Needs external profiling.
- `RENDER_TOTAL_PRIMITIVES_IN_FRAME` on horizon-rich scenes (tens of millions of tris) will hit GPU vertex-shader saturation regardless of draw count. That's why HLOD's decimation pass and the octahedral impostor exist. If the triangle count-per-frame is the bound, the fix is more aggressive HLOD (lower chunk-level LOD1 target) and earlier impostor handoff — tunable, but in the "ship-it later" bucket.

---

## 7. Ranked Recommendations

| # | Change | Effort | Risk | Expected gain |
|---|---|---|---|---|
| 1 | World-scoped per-prototype MultiMesh for MID (§5.2), including buildings | large | medium — touches hot path | +30-50 FPS |
| 2 | HLOD / MID dedup handoff (§5.1) | medium | medium — lifecycle bookkeeping | +5-15 FPS when HLOD on, removes double-count |
| 3 | Set `directional_shadow_max_distance = 500` + tune splits (§5.7) | trivial | low | +5-10 FPS |
| 4 | Shader-driven fade-in in place of per-object Tween (§5.4) | small | low | removes a load-time hitch class |
| 5 | Double-buffered async impostor texture array + MultiMesh buffer write (§5.3) | medium | low | removes 4 Hz 6-8 ms stall |
| 6 | Delete or wire up GPUSceneDatabase (§5.5) | small | low (deletion path) | ~free |
| 7 | Gate LightAnimator on frustum / is_visible_in_tree (§5.6) | trivial | low | a few FPS in light-dense cells |

Do #3 first to set a clean baseline. Do #1 next — it's the structural change and it unblocks the rest. #2 lands cleanly after #1 because the dedup registry can reuse the new per-prototype index. #4 / #5 / #6 / #7 are independent and can be done in any order once the draw-call floor is fixed.

---

## 8. Appendix — AAA Research Brief (verbatim)

*This is the research agent's output, kept intact for provenance. Sources are inline.*

### Core Question First: 140 FPS with Horizon-Range Static Geometry on a Non-Nanite, Non-Bindless Engine

At 140 FPS you have ~7.1 ms/frame total, of which the CPU command-submission budget for opaque statics is realistically ~2-3 ms. On a modern desktop GPU + DX12 driver, unique-state draw calls cost roughly 3-15 µs CPU-side once you factor descriptor binding and state change cost in a non-bindless pipeline (see Baldur Karlsson's "A trip through the Graphics Pipeline 2015" and NVIDIA's "Advanced API Performance" GDC 2019 talk by Tim Jones). Practical ceiling: ~3,000-8,000 unique draws/frame at 140 FPS, and you want most of them to be *instanced* (one draw, N instances), not unique. The AAA answer in 2025 for non-Nanite pipelines is still the same as 2015: collapse unique draws into instanced batches per material and push geometry density into per-cluster merged meshes + imposters — exactly the shape of your current pipeline. The gap between 50 FPS and 140 FPS is almost never "better LODs", it is "fewer draw calls and fewer state changes."

### Rockstar RDR2 / GTA V

RDR2 uses hierarchical LOD ("LODLights" is specifically the distant light-source system, not geometry imposters — Rockstar's term for distant geometry is "SLOD" / "super-LOD" levels 0-4). Each map tile has pre-authored SLOD meshes that fuse dozens of statics into a single mesh + atlas. Streaming is radius-based per SLOD tier. Terrain uses clipmapping with virtual-texture-backed splat maps. Sources: Rockstar's "Advances in the Rendering of Red Dead Redemption 2," Alex Hadjadj (SIGGRAPH 2019 Advances in Real-Time Rendering course), and the GTA V technical breakdown by Adrian Courrèges ("GTA V — Graphics Study," 2015).

Portable to Godot 4.6: SLOD tiers = Godotwind's HLOD chunk merging exactly. Clipmap terrain is expressible via Terrain3D. Virtual texturing is not — substitute per-region atlases.

### UE5 Non-Nanite Fallback

UE5 ships a non-Nanite fallback path: HLOD actors (Epic docs, "Hierarchical Level of Detail"), proxy LOD via Simplygon-style mesh reduction, and the Impostor Baker plugin (Ryan Brucks / Epic, free plugin since UE4). HLOD clusters nearby static meshes into a single merged actor with a combined texture atlas. Proxy LOD bakes a decimated mesh with baked materials. These do not require Nanite, bindless, or mesh shaders. Refs: Epic's "World Partition HLOD" docs, "Creating a AAA Open World in UE5" (Epic, Unreal Fest 2022).

Portable: Godotwind already has the cluster merger + octahedral impostor baker. Proxy LOD equivalent is already covered by `ImporterMesh.generate_lods()`.

### Frostbite

Static batching via a persistent GPU instance buffer, HISM-equivalent "mesh instancing" per streaming sector. Canonical talks: Yuriy O'Donnell, "FrameGraph: Extensible Rendering Architecture in Frostbite," GDC 2017; Graham Wihlidal, "Optimizing the Graphics Pipeline with Compute," GDC 2016.

Portable: the "one instance buffer per material, merge at stream-in time, sort front-to-back for early-Z" pattern is exactly what `MultiMeshInstance3D` is for. GPU-driven culling via indirect draws is not exposed in Godot 4.6.

### Guerrilla Decima (Horizon)

Tile-based foliage with per-tile instance lists; imposter grids. Talk: Gilbert Sanders, "Between Tech and Art: The Vegetation of Horizon Zero Dawn," GDC 2017.

Portable: per-cell `MultiMeshInstance3D` per species via `MeshLibrary`, populated on the worker thread. Godotwind does not have this layer today — foliage flows through the generic MID pipeline.

### CryEngine / Kingdom Come Deliverance

"StatObj" = their static mesh type with per-LOD material overrides. `CMergedMeshRenderNode` — runtime-merged vegetation clusters per sector. Warhorse's "Kingdom Come: Deliverance — The Making Of" tech posts.

This is direct validation that runtime per-chunk merging (= Godotwind HLOD) is the canonical non-Nanite approach.

### id Tech 7

Billy Khan / Jean Geffroy, "The Rendering of DOOM Eternal," SIGGRAPH 2020 Advances in Real-Time Rendering. Clustered forward+, aggressive portal/scissor culling. Mostly interior; less relevant for horizon outdoor. Godot's Forward+ is the same family — no additional lever here beyond what the stencil portal system already does.

### OpenMW

OpenMW's Object Paging (Azdul, 2019, OpenMW PR #2187) merges statics per exterior cell into a single mesh per material. This is what Godotwind's HLOD is directly ported from.

### Is Mesh Merging Per-Chunk Still Canonical in 2025 AAA?

Yes, outside Nanite. Every non-Nanite AAA title above (RDR2 SLOD, UE5 HLOD fallback, Frostbite static batch, CryEngine merged vegetation, Decima tile instances) uses some variant of "pre-merge statics per spatial bucket, draw the bucket as one instanced call." UE5 Nanite is the only pipeline that replaced this with auto-clustering, and it requires hardware indirect + mesh shaders + visibility buffer. For Godot 4.6: Godotwind's HLOD chunk design is correct.

### Octahedral Impostors — AAA Variants

- Base technique: octahedral parametrization of view directions into a 2D atlas; runtime samples 3 nearest views and blends. The canonical impostor reference is Jonathan Lindquist's "Octahedral Impostors" which ships as the UE4 Impostor Baker plugin.
- Paragon / Fortnite plugin: Ryan Brucks at Epic, 2017 Impostor Baker blog post, 16x16 or 32x32 octahedral frame grid, baked albedo + normal + depth.
- RDR2 multi-view is flagged unconfirmed as octahedral specifically; Rockstar's SLOD4 appears to be pre-baked billboards.

### Texture Atlasing Without Sparse Virtual Textures

Offline-baked per-region atlases. Pack all statics in a cell into 1-4 2048² or 4096² atlases at bake time, hash materials across cells for dedup. Godot 4.6 supports `Texture2DArray` which is the closest you can get to bindless without bindless — bind one array once, index per-instance via custom data on the MultiMesh.

### What Godot 4.6 CAN Do That Godotwind Isn't Fully Using

- `GeometryInstance3D.visibility_range_begin/end` with `FADE_SELF` — smooth LOD crossfade without per-frame script work.
- `MultiMeshInstance3D.multimesh.set_instance_custom_data()` — 4 floats per instance, usable as atlas-index + tint.
- `Texture2DArray` — non-bindless path to binding a whole cell's textures in one slot.
- `RenderingServer.instances_cull_aabb` / `instances_cull_ray` — server-side culling queries for gameplay without touching the render cull.
- `OccluderInstance3D` with baked `Occluder3D` — CPU raster occlusion, works outdoors if authored against large statics.
- `ImporterMesh.generate_lods()` with explicit `normal_merge_angle` + `target_error` tuning.
- `WorkerThreadPool.add_group_task()` — parallel cell merge across cores.
- `MeshLibrary` + `GridMap` — already-optimized instancing path for tile-grid authoring.
- `RenderingServer.multimesh_set_buffer()` with a raw `PackedFloat32Array` — bulk upload path.
- `ProjectSettings.rendering/limits/opengl/max_renderable_elements` and Forward+ equivalents — raise before profiling.

### Bottom Line for the 50 → 140 FPS Gap

The single biggest lever is almost certainly draw call count at MID range. "One RS instance per MID object" at horizon-visible densities is the smell. Canonical fix: promote MID to per-cell `MultiMesh` batches keyed by (mesh, material) hash, exactly as Frostbite / CryEngine / OpenMW do. HLOD then becomes a second merge tier over the MultiMesh tier, not the first merge tier. This is the structural change; impostor tuning and atlas packing are second-order.

---

*End of audit.*
