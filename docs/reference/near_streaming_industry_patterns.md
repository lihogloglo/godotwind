# NEAR-Tier Streaming — Industry Pattern Survey + Godotwind Recommendation

**Status:** Research pass, 2026-04-20 (updated 2026-04-22 — §7 streaming granularity, §8 production CellPreloader design). **Recommendation status as of 2026-04-29:** partially shipped — Wins 0-5 (off-thread cell-collision, server-direct cell static body, lazy-spawn lights, server-direct OmniLight3D) landed 2026-04-25. `_apply_fade_in` deleted. `lod_crossfade_multimesh.gdshader` is still referenced from `static_object_renderer.gd` / `prototype_batch.gd` (recommendation half-shipped). `cell_preloader.gd` exists but is not wired into `native_streaming_manager.gd`. Phase A off-thread `PackedScene.instantiate()` was attempted and rolled back (`PHASE_A_OFFTHREAD_INSTANTIATE = false` in `streaming_config.gd`, crashes). For the current authoritative audit see `docs/audit/godot_46_near_streaming_aaa_audit_2026_04_29_codex.md`. Authored by @researcher on branch `perf/distant-rendering-2026-04-17`.
**Scope:** NEAR tier only (0-150 m).
**Trigger:** `ReferenceInstantiator.instantiate_reference` + `CellManager.add_child` on the main thread ceils at ~79 scene instantiates × ~11 ms = ~870 ms wall budgeted across frames, producing visible pop-in and 25 fps dips at cell crosses.

---

## Executive Summary (the recommendation)

1. **Current per-ref `PackedScene.instantiate()` + main-thread `add_child()` for ~79 containers per cell is the ceiling.** It is not the canonical pattern any AAA engine uses for static clutter.
2. **Canonical split (UE5, Decima, OpenMW, id Tech, RAGE):** static clutter is authored once as a prototype, baked into a **per-cell transform buffer**, and surfaced at runtime as **one GPU-instance swap per prototype per cell**. Per-ref Node3D creation is reserved for the tiny subset that is *actually interactive* (doors, containers, activators, NPCs, carryables — typically <20 % of a cell's refs).
3. **We already have ~80 % of this infrastructure** — `StaticObjectRenderer` + `PrototypeRegistry` + `ObjectPaging` merger. `reference_instantiator.gd:_should_route_to_renderer` already routes STAT types to the `RenderingServer`-direct path. **The work is not "build a new pipeline", it is "widen the RS fast path, narrow the Node3D slow path to interactives only, move `PackedScene.instantiate` off the main thread, add velocity prefetch."**
4. **Threading unlock:** as of Godot 4.1, `PackedScene.instantiate()` is thread-safe when paired with `call_deferred("add_child")`. Our current design calls `instantiate()` on the main thread — this is a bug of opportunity, not a platform limit.
5. **Pop-in smoothing:** adopt `VISIBILITY_RANGE_FADE_SELF` with dither mode (Godot 4 engine-native, same mechanism as UE5 Nanite dither + per-instance fade). Delete the bespoke `lod_crossfade.gdshader` material-swap dance in `reference_instantiator._apply_fade_in` (200 lines of pool management + tween + stuck-shader-material recovery).
6. **Flight-speed streaming:** adopt OpenMW's `preload + mPredictionTime` pattern — predict camera position `t` seconds ahead, pre-warm cells in an expiring cache (`CellPreloader.mPreloadCells`). Ship OpenMW has with this exact mechanism for 10+ years — our current `native_streaming_manager` is reactive and lacks velocity lookahead entirely.

**Shortest path:** the NEAR bottleneck is *not solved by tuning the budget*. It is solved by moving 80 % of the work off the main-thread instantiation path entirely and restricting `PackedScene.instantiate()` to interactives. Everything else is engine-native dressing.

---

## 1. AAA Pattern Survey

### 1.1 Unreal Engine 5 — World Partition + HLOD + One-File-Per-Actor

- **I/O unit:** a `UWorldPartitionRuntimeCell` (typically 128 m × 128 m at ground-pass grid level). Cells store a list of actor GUIDs; each actor lives in one `.uasset` (One-File-Per-Actor / OFPA).
- **Streaming pipeline:** `UWorldPartitionStreamingSourceComponent` defines spheres around cameras / AIs / fast-travel points. `UWorldPartitionSubsystem::UpdateStreamingState` walks the active grid, unions source queries, drives cell LoadState transitions (`Unloaded → Loading → Loaded → Activated`).
- **Actor instantiation:** `ULevelStreaming` async-loads the cell's sublevel off the game thread. Actor spawn is budgeted on the main thread (Level Streaming can spread across frames via `s.LevelStreamingActorsUpdateTimeLimit`).
- **HLOD:** a separate `AWorldPartitionHLOD` actor per cluster holds a **pre-baked merged mesh** (Simplygon remesh pipeline at bake-time, NOT runtime merge). HLOD actors are loaded at broader grid levels (e.g. 512 m / 2048 m / 8192 m) and hidden when their source cell is `Activated`. Switch is instant or dithered via material `Dither Temporal AA`.
- **Cost model:** HLOD is "draw-call reduction at distance"; the per-cell cost at activation time is dominated by (a) sublevel async load (disk + parse) and (b) main-thread actor instantiation spread over N frames. Epic publishes `s.LevelStreamingActorsUpdateTimeLimit` as the canonical knob.
- **Key property:** cell activation is I/O + main-thread-budgeted attach. **Epic does NOT do per-actor `instantiate()` off the main thread for general actors** — their solution is the combination of OFPA sublevel bundling (fewer per-actor costs, more batched cell costs) and HLOD keeping far cells unloaded.

Sources:
- [World Partition — UE docs](https://dev.epicgames.com/documentation/en-us/unreal-engine/world-partition-in-unreal-engine)
- [World Partition deep-wiki](https://deepwiki.com/chenyong2github/UnrealEngine/4.1-world-partition)
- [World Partition notes (hzfishy)](https://notes.hzfishy.fr/Unreal-Engine/Engine--and--Editor/Content-Streaming/World-Partition,-Data-Layers--and--HLOD)
- [HLOD remeshing (Simplygon)](https://documentation.simplygon.com/SimplygonSDK_10.3.500.0/ue5/concepts/hlod.html)

### 1.2 Decima (Horizon Zero Dawn / Forbidden West)

- **I/O unit:** tile. StaticTiles split the world into rectangular footprints. Each tile stores an array of `QueryObjects` + `QueryInstances` (per-instance transforms in GPU buffers).
- **Runtime model:** each tile is essentially a pre-built **GPU instance buffer** per prototype. Culling runs on async compute on GPU against the union of all tiles' instances. No per-instance CPU work at steady state.
- **Pop-in:** `activeGrid` promotes higher-quality chunks near the camera; lower tiers stay resident at lower density. No per-instance scene-graph attach for pure statics — they live in tile buffers.
- **Key property:** Decima never instantiates "actors" for static clutter. Statics are arrays of transforms, drawn via MultiDrawIndirect / instance buffers. The CPU-side work per tile transition is "bind this buffer / unbind that buffer", not "spawn N objects".

Sources:
- [Streaming the World of Horizon Zero Dawn (GDC)](https://www.guerrilla-games.com/read/Streaming-the-World-of-Horizon-Zero-Dawn)
- [Decima SIGGRAPH 2017 — Visibility](https://advances.realtimerendering.com/s2017/DecimaSiggraph2017.pdf)
- [GPU-Based Run-Time Procedural Placement (Horizon)](https://www.youtube.com/watch?v=ToCozpl1sYY)

### 1.3 Unity Addressables / Batch Renderer Group (BRG)

- **I/O unit:** addressable group, often scene-based (`Addressables.LoadSceneAsync`).
- **Caveat:** the final activation step of `LoadSceneAsync` must run on the main thread — this is the Unity equivalent of our `add_child` bottleneck.
- **Heavy-static solution:** `BatchRendererGroup` (DOTS / GPU Instancer plugin) — identical rendering model to Decima and UE5 HLOD: a per-chunk transform buffer rendered via instanced draw calls, no GameObjects per instance.
- **Key property:** even in Unity, the answer for "thousands of static clutter items" is NOT per-instance GameObject creation. It is BRG / GPU Instancer (Addressables handles the GameObject-shaped minority — mostly interactives).

Sources:
- [Addressables.LoadSceneAsync](https://docs.unity3d.com/Packages/com.unity.addressables@2.0/manual/LoadingScenes.html)
- [Unity Asset Streaming (Oculus)](https://developers.meta.com/horizon/documentation/unity/po-assetstreaming/)

### 1.4 RAGE (GTA V / RDR2)

- **I/O unit:** sector (world rectangle). Two sector types in RAGE: collision sectors + scene sectors (San Andreas onwards).
- **Streaming:** resource-oriented — textures, drawables, collision are independent resources with priority queues. Player-position intersection against sector bounds kicks requests into the streaming engine's priority queue.
- **Key property:** resource streaming is decoupled from scene-graph activation. The scene has a permanent "shell" of all sector anchors; only the underlying resource bundles stream. Similar to UE5 actor descriptors vs actor hydration split.

Sources:
- [Rockstar Advanced Game Engine (Wikipedia)](https://en.wikipedia.org/wiki/Rockstar_Advanced_Game_Engine)
- [Resource Streaming (GTAMods Wiki)](https://gtamods.com/wiki/Resource_Streaming)

### 1.5 Star Citizen Object Container Streaming (OCS)

- **I/O unit:** object container — hierarchical, nested containers (system → planet → city → building → room).
- **Streaming:** container becomes "frozen" when no streaming source is inside it; state is preserved, memory is released. Container re-hydrates when a source enters.
- **Relevance to Godotwind:** **minimal.** SC's model is built around a single seamless universe with hierarchical containment; our cells are a flat grid. The nested-container pattern doesn't buy us anything here. Noted for completeness — this is NOT the pattern we should adopt.

Sources:
- [OCS — Star Citizen Wiki](https://starcitizen.tools/Object_Container_Streaming)
- [OCS deep-dive (Newsweek interview)](https://www.newsweek.com/star-citizen-devs-explain-socs-space-alpha-3-8-1477149)

### 1.6 Bevy / ECS batched spawn

- **I/O unit:** none canonical — Bevy has no engine-level streaming primitive. Community solutions (bevy_openworld, etc.) all converge on the same pattern: **one `Query<&InstanceBuffer>` per chunk, update chunk presence per-frame**. Instantiation is O(chunks), not O(entities).
- **Key property:** ECS cultures reach the same answer: the streaming unit is *the buffer*, not *the entity*. Individual entities only exist for interactives that need components (colliders, AI, inventory).

### 1.7 id Tech / Source 2 — out of scope but the theme is identical

- **id Tech 6/7 (Doom Eternal):** megatextures + streamed BSP-like clusters. No runtime per-prop instantiation — all static geometry is baked into the compiled map.
- **Source 2 (HL Alyx):** `.vpk` bundles + PVS clusters. Runtime cost dominated by resource decompression, not per-prop main-thread spawn.

### 1.8 Cross-engine summary

| Engine | Cell/Tile unit | Static clutter model | Interactive model | Pop-in handling |
|---|---|---|---|---|
| UE5 World Partition | 128 m grid cell | HLOD mesh (baked) + sublevel actors at NEAR | Full actor spawn, budgeted | Dither Temporal AA, PerInstanceFade |
| Decima | rect tile | GPU QueryInstance buffer | Separate actor hierarchy | Distance fade via LOD chain |
| Unity BRG + Addressables | Addressable group / scene | BRG transform buffer | GameObject (scene load) | Material dither, PerInstanceFade |
| RAGE | sector | Resource bundle (drawable arrays) | Scene entity, bundle-backed | Crossfade + alpha |
| OpenMW ObjectPaging | variable chunk (1×1, 2×2, 4×4) | Merged osg::Geometry per chunk | osg::PositionAttitudeTransform | None (instant) |
| Bevy | community chunk | ECS component on single buffer entity | Full entity | Shader fade |
| **Godotwind target** | **117 m MW cell** | **`StaticObjectRenderer` / `PrototypeRegistry` MultiMesh** | **Node3D + StaticBody3D** | **`VISIBILITY_RANGE_FADE_SELF` dither** |

**All seven engines agree: static clutter is an array of transforms, not an array of scene nodes. The only per-node cost is interactives.**

---

## 2. Godot 4.6 Implementation Options

### 2.1 Thread safety of the relevant APIs

Ground truth from the Godot docs + issue tracker:

| API | Thread-safe? | Notes |
|---|---|---|
| `ResourceLoader.load` / `load_threaded_request` | **Yes** | Designed for background load |
| `PackedScene.instantiate(EDIT_STATE_DISABLED)` | **Yes as of Godot 4.1+** (see issue #79194 resolution) | Must instantiate + load in SAME thread |
| `Node.add_child` | **Main-thread only** | Use `call_deferred("add_child", node)` |
| `RenderingServer.instance_create` / `instance_set_base` / `instance_set_transform` | **Yes via command queue** | Calls buffer into the render-thread queue, no blocking main |
| `MultiMesh.set_instance_transform` | **No — main-thread only**, per forum reports of stuttering from worker threads | Buffer transforms in a thread-local array, apply on main |
| `MultiMesh` buffer bulk-upload via `RenderingServer.multimesh_set_buffer(rid, PackedFloat32Array)` | **Yes via command queue** | This is the fast path — one RS command per chunk |

Sources:
- [Thread-safe APIs (Godot 4 docs)](https://docs.godotengine.org/en/stable/tutorials/performance/thread_safe_apis.html)
- [Issue #79194 — PackedScene thread-guard resolved](https://github.com/godotengine/godot/issues/79194)
- [Forum: background loading pattern 4.3](https://forum.godotengine.org/t/can-we-do-single-thread-background-loading-in-godot-4-3/76473)
- [Using MultiMeshes (Godot docs)](https://docs.godotengine.org/en/stable/tutorials/performance/using_multimesh.html)

### 2.2 RS-direct vs Node3D cost model

| Path | Per-instance cost (ballpark) | Per-frame cost | Physics |
|---|---|---|---|
| `PackedScene.instantiate()` + `add_child()` (our current `_instantiate_model_object`) | 11-20 ms incl. NIF-baked subtree | Zero when cached | StaticBody3D + CollisionShape3D subtree |
| Duplicate-from-cache + `add_child()` (our `ObjectPool.acquire`) | ~2-4 ms (still Node3D tree attach + `_enter_tree` propagation) | Zero when cached | Same |
| `RenderingServer.instance_create` + `instance_set_base` + `instance_set_transform` | ~10-50 µs (per our `StaticObjectRenderer._create_rs_instance`) | Zero | **None by default — must be added separately** |
| `MultiMesh` slot assignment via `PrototypeRegistry` | ~5-20 µs | Zero (one draw call per prototype) | **None by default** |

Ratio: `PackedScene.instantiate` is **200-2000× slower than RS-direct** per instance. This is the empirical reason we already route ~80 % of STAT refs through `StaticObjectRenderer`. The bug is that the other ~20 % (containers, doors, activators, interactives with immediate visible gain) still walk the Node3D path on the main thread.

### 2.3 The main-thread `instantiate()` bottleneck is self-imposed

Our `ReferenceInstantiator.instantiate_reference` is called **from the main thread** by `CellManager._process_instantiation_queue`. `PackedScene.instantiate(EDIT_STATE_DISABLED)` is thread-safe as of 4.1+ (bug #79194 resolved; the pattern is documented in multiple Godot forum threads). The canonical Godot pattern is:

```gdscript
# worker thread (WorkerThreadPool.add_task):
var scene: PackedScene = ResourceLoader.load(path) # or from cache
var node: Node3D = scene.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED)
_apply_transform_and_metadata_offthread(node, ref) # transform is thread-safe
# main thread via call_deferred:
parent.call_deferred("add_child", node)
```

**Cost moved off main thread: ~11 ms × 79 refs = 870 ms wall shifted to worker pool**, main thread now pays only `add_child` (~100-300 µs per node with `_enter_tree` propagation). On an 8-core machine with 4 workers, 79 refs complete in ~220 ms wall, fully hidden behind the cell transition.

### 2.4 Physics attach is also budgeted

`StaticBody3D + CollisionShape3D` registration with Jolt is main-thread-bound (Jolt body-add takes an internal write-lock). But we don't need physics for the ~80 % MultiMesh path — that's handled by the cell-level merged trimesh (`cell_static_collision.gd` per `near_tier_refactor.md` §5.3). The ~20 % Node3D path pays physics attach cost, amortized over the WorkerThreadPool throughput.

---

## 3. OpenMW Findings

Reading `inspos/openmw/apps/openmw/mwworld/cellpreloader.cpp` + `scene.cpp` + `mwrender/objectpaging.cpp`.

### 3.1 What OpenMW does well (adopt these)

**`CellPreloader` with background `WorkItem` + expiring cache** (`cellpreloader.cpp:239-291`):
- `preload(cell, timestamp)` schedules a `PreloadItem` on `WorkQueue`. The work item runs `sceneManager->getTemplate(mesh)` + `bulletShapeManager->cacheInstance(mesh)` off-thread, returning only NIF templates + cached collision shapes — **not Node3D instances**.
- `mPreloadCells: std::map<const CellStore*, PreloadEntry>` — bounded LRU, `mMaxCacheSize` cap. `updateCache` evicts entries older than `mExpiryDelay`.
- **This is exactly what we're missing.** `native_streaming_manager` has `WorkerThreadPool` for `ResourceLoader.load_threaded_request`, but no per-cell batched preload of all meshes, no timestamp-indexed cache, no eviction-by-age.

**Predictive preload via velocity extrapolation** (`scene.cpp:1147-1175`, `preloadCells`):
```cpp
osg::Vec3f predictedPos = playerPos + moved / dt * mPredictionTime;
```
- `mPredictionTime` is user-configurable (default 1 second; higher for slow disks). Cells at `predictedPos` are preloaded, not just cells at `playerPos`.
- **We have zero velocity lookahead.** `native_streaming_manager._update_loaded_cells` walks a radius around the current camera position only. At flight speed (say 50 m/s = ~0.4 cell/s), 1 second of prediction = 0.4 cells ahead, enough to mask async load latency.

**`preloadCellWithSurroundings` for teleports / doors** (`scene.cpp:1177-1213`):
- When a teleport door is within `mPreloadDistance`, the destination cell + its surroundings are pre-warmed. Loading-screen behind doors becomes a rare event instead of the default.
- **Directly applicable to interior pockets.** Our `interior_pocket_manager` loads on demand — adding preload on approach would eliminate the "touch door → freeze" hitch.

**Abort on cell grid change** (`cellpreloader.cpp:abortTerrainPreloadExcept`):
- Fast-travel / teleport invalidates in-flight preloads cleanly via per-work-item `abort()` atomic flag.

### 3.2 What OpenMW does poorly (do NOT adopt)

**`ObjectPaging` runtime scene-graph merge** (`objectpaging.cpp`):
- Builds merged `osg::Geometry` per chunk via `AnalyzeVisitor` + `CopyOp`. Runs on worker thread.
- **Our `object_paging.gd` already implements the equivalent.** It's a HLOD-layer impl, not NEAR. Irrelevant to the NEAR refactor.
- **Downside of OpenMW's version:** no fade between paged and un-paged states — objects pop when entering active grid. We should NOT replicate this.

**No separation of "static" vs "interactive" ref paths** (`objectpaging.cpp:typeFilter`):
- OpenMW pages STAT + ACTI + DOOR + CONT when `size >= 2`. Interactives are merged into the chunk mesh + un-paged to individual scene nodes only when entering the active 1×1 grid. The merge/un-merge dance is fragile (ref-tracker mutex at line 59) and forces *all* statics through the same path regardless of interactivity.
- **Our `_should_route_to_renderer` is cleaner** — static-forever refs go RS-direct + never get a Node3D ever; interactives are Node3D from spawn. This is the correct split. Don't regress toward OpenMW's merge/un-merge for NEAR.

**Synchronous scene-graph attach in `loadCell`** (`scene.cpp:426-530`):
- After preload, `insertCell` walks the ref list and calls `mPhysics->addObject` + `mRendering.addObject` sequentially on the main thread. This is the same bottleneck we have. OpenMW hides it behind the loading screen on cell-grid change; mid-flight it shows up as hitches. Their model validates the limit, not the solution.

### 3.3 Numerical lift from OpenMW settings

User-tunable defaults from `files/settings-default.cfg`:
- `preload cell expiry delay = 5` seconds
- `preload cell cache min = 12` cells
- `preload cell cache max = 20` cells
- `prediction time = 1` second
- `target framerate = 60` (frame budget for graphics preloading)

These are good starting points for `streaming_config.gd`.

Sources:
- [OpenMW cell settings docs](https://openmw.readthedocs.io/en/stable/reference/modding/settings/cells.html)
- [OpenMW CellPreloader API reference](https://openmw.github.io/classMWWorld_1_1CellPreloader.html)
- [OpenMW fix exterior cell preloading MR #4064](https://gitlab.com/OpenMW/openmw/-/merge_requests/4064)

---

## 4. Pop-in Smoothing

### 4.1 Canonical pattern: engine-native dither fade with hysteresis margin

Godot 4 has the exact mechanism:
- `GeometryInstance3D.visibility_range_begin` / `visibility_range_end`
- `visibility_range_fade_mode = VISIBILITY_RANGE_FADE_SELF` (dither-based per-pixel alpha)
- `visibility_range_begin_margin` + `end_margin` — hysteresis to prevent oscillation
- Applies directly to `RenderingServer.instance_geometry_set_visibility_range(rid, begin, end, begin_margin, end_margin, mode)` — works for both Node3D and RS-direct instances.

This is the same mechanism UE5 uses for Nanite (temporal dither) and foliage `PerInstanceFade`. It runs in the fragment shader via stable temporal dither; TAA resolves it to smooth alpha with zero CPU cost.

Sources:
- [Visibility ranges (HLOD) — Godot docs](https://docs.godotengine.org/en/stable/tutorials/3d/visibility_ranges.html)
- [Godot proposals #5240 — dithering for VR LOD](https://github.com/godotengine/godot-proposals/issues/5240)
- [UE Smooth Apparition with Dithering tutorial](https://dev.epicgames.com/community/learning/tutorials/oLqa/unreal-engine-smooth-apparition-of-instances-with-dithering)
- [UE5 Nanite foliage notes (Medium)](https://medium.com/@shinsoj/notes-on-foliage-in-unreal-5-3522b6eb159f)

### 4.2 What we currently do that is NOT canonical

`reference_instantiator.gd:_apply_fade_in` (lines 1213-1395): pool of 200 `ShaderMaterial` with `lod_crossfade.gdshader`, swap `material_override` onto every `MeshInstance3D`, tween `spawn_time` uniform, restore original via `SceneTreeTimer` callback.

Problems:
- ~200 lines of pool / leak / stuck-material-recovery logic (the code explicitly documents a stuck-fade-shader recovery branch at line 1301-1307 — a signal, per CLAUDE.md §Simplicity, that the approach is over-engineered).
- Breaks on multi-surface meshes (ships, buildings) — the "one override for all surfaces" trap the code calls out at line 1289-1307.
- Fade material lookups happen at per-object `add_child` time — adds to main-thread cost.
- Engine already has the mechanism for free via `VISIBILITY_RANGE_FADE_SELF` — zero CPU cost, no pool management, TAA-stable.

### 4.3 Recommendation

- **Delete `lod_crossfade.gdshader` + `_apply_fade_in` + `_restore_fade_data` + `_ensure_fade_pool` + `_acquire_fade_material` + `_release_fade_material`.**
- At object spawn, set `visibility_range_begin = 0`, `visibility_range_end = DU.NEAR_END`, `visibility_range_end_margin = 20.0`, `visibility_range_fade_mode = VISIBILITY_RANGE_FADE_SELF`.
- For RS-direct instances, call `RenderingServer.instance_geometry_set_visibility_range(rid, 0, NEAR_END, 0, 20, FADE_SELF)` (already done in `static_object_renderer._create_rs_instance:484`).
- For the "just-spawned, not yet at steady state" brief window, use a single RS call `instance_geometry_set_transparency(rid, 1.0)` and animate down via a shared `Time.get_ticks_msec`-driven shader uniform — **only if** user reports a visible pop after the engine-native fade; otherwise don't add the complexity.

---

## 5. Flight-Speed Streaming

### 5.1 Canonical pattern: velocity-extrapolated preload + expiring cache

The three-part pattern (OpenMW implements all three, UE5 implements via `StreamingSourceComponent` velocity, Decima via motion vectors):

1. **Predictive position:** `predicted = camera + velocity × prediction_time`. `prediction_time` tuned to mask async load latency (OpenMW: 1 s default).
2. **Union preload query:** cells within `preload_radius` of `predicted` **and** `camera` — union, not intersection. Guards against abrupt direction changes.
3. **Expiring cache:** cells that were preloaded but never activated within `expiry_delay` are evicted. Bounded-size LRU.

### 5.2 What to build

New file `src/core/world/cell_preloader.gd` mirroring `cellpreloader.cpp`:
- `preload(cell_grid, timestamp)` — kicks a `WorkerThreadPool` task to ResourceLoader-load every unique model path in the cell. Caches parsed `PackedScene`s in a `Dictionary[String, PackedScene]` keyed on model path. Does NOT instantiate.
- `notify_loaded(cell_grid)` — called when cell is activated (via `request_cell_tier`). Promotes the preload entry out of the preload cache.
- `update_cache(timestamp)` — evicts entries with `timestamp < now - expiry_delay` and `cache_size > min_cache_size`.
- Max cache: 20 cells (OpenMW default). At ~79 refs/cell × 20 cells = ~1600 PackedScenes cached = well within the 256 MB BSA cache budget.

Activation change in `native_streaming_manager`:
- `_update_loaded_cells` queries `streaming_source_registry` for `get_active_cells(predicted_pos, prediction_time)` — returns cells within active radius of both `pos` and `pos + vel * t`.
- Cells in predicted set but not active set go into preload queue.
- Cells in active set but not loaded check preload cache first; if hit, instantiate is fast (PackedScenes already parsed, live in ResourceLoader cache).

### 5.3 Fallback for "camera outran preload"

If the preload cache misses on cell activation (e.g. the user teleports or spawn-flies at >100 m/s), two canonical fallbacks exist:
- **Impostor stand-in until NEAR is ready** (UE5 HLOD default): the FAR-tier octahedral impostor remains visible for N frames after the NEAR instantiate starts, hidden only when the NEAR Node3Ds are all in the tree. We have impostors; just need to gate the NEAR-vs-impostor handoff on `cell.tier == FULL` not `cell.loaded == true`.
- **Low-detail placeholder mesh** (Decima / UE5 Nanite streaming state): show a single bounding-volume mesh per cell while real geometry streams. Simpler but uglier — only use if impostors aren't an option.

For Godotwind, impostor-stand-in is free once `request_cell_tier` exists (per `near_tier_refactor.md` §3.4) — the impostor cell layer stays `Activated` until the NEAR cell layer reports `Loaded`.

---

## 6. Concrete Recommendation for Godotwind NEAR Tier

### 6.1 The smallest change set that unblocks flight-speed streaming

**Phase A — move `PackedScene.instantiate()` off the main thread** (the ceiling bug):
- `ReferenceInstantiator.instantiate_reference` stays on main thread only for interactives (doors, containers, activators, NPCs, carryables). Renames to `instantiate_interactive`.
- New path `instantiate_static_on_thread(ref, cell_grid) -> Node3D` runs on `WorkerThreadPool`:
  - `var scene := ResourceLoader.load(model_path)` (thread-safe)
  - `var node := scene.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED)` (thread-safe, Godot 4.1+)
  - Apply transform + metadata (thread-safe, Transform3D / Dictionary ops)
  - Return node; caller calls `parent.call_deferred("add_child", node)` on main thread
- The ~80 % STAT refs that already route to `StaticObjectRenderer` stay RS-direct — no change.
- Main-thread budget now pays only `add_child` + physics attach (~300 µs/node instead of ~11 ms).

**Phase B — velocity-extrapolated preload** (the flight-speed fix):
- New `src/core/world/cell_preloader.gd` per §5.2.
- `native_streaming_manager._update_loaded_cells` queries preload-aware active set.
- Wire into existing `WorkerThreadPool` — no new threading primitive.
- `prediction_time` exposed in `streaming_config.gd`. Default 1.0 s.

**Phase C — delete bespoke fade** (simplification, -200 lines):
- Rip `lod_crossfade.gdshader` + `_apply_fade_in` chain per §4.3.
- Use `visibility_range_fade_mode = VISIBILITY_RANGE_FADE_SELF` uniformly.

**Phase D — impostor stand-in for fallback** (flight-speed resilience):
- Gate NEAR→impostor handoff on `cell.tier == FULL` (per existing `near_tier_refactor.md` §3.4 S.3+).
- Already free once the per-cell FSM lands.

### 6.2 Why this is the right split

- It maps 1:1 to the existing `_should_route_to_renderer` decision — we are widening it, not rearchitecting.
- It uses only engine-native primitives that are already validated by `StaticObjectRenderer` (RS-direct) and `PrototypeRegistry` (MultiMesh batching).
- It does NOT touch NIF parsing, ESM parsing, or terrain — work stays scoped.
- It aligns with `near_tier_refactor.md` S.2-S.4 phase boundaries (no architectural conflict).
- It is the exact pattern UE5 (World Partition + background actor load), Decima (tile-as-buffer), Unity (BRG + Addressables), OpenMW (`CellPreloader`), Bevy (per-chunk buffer) all converge on. **Zero invention.**

### 6.3 What this recommendation is NOT

- Not "build a new streaming system." It is "move the existing pipeline's main-thread instantiate to worker threads + add velocity preload."
- Not "adopt UE5 World Partition wholesale." Cell sizing + HLOD grids are already in `near_tier_refactor.md` scope and out of scope for NEAR.
- Not "rewrite `StaticObjectRenderer`." That file is the RS-direct fast path already — it stays.
- Not "add a new autoload." `cell_preloader.gd` is owned by `native_streaming_manager` per CLAUDE.md anti-patterns.

### 6.4 Measurement plan

Acceptance gate per `near_tier_refactor.md` §9:
- Frame time during 4-cell-wide flyover at 50 m/s, before vs after.
- `process_async_instantiation` main-thread time, before vs after.
- Worker-thread occupancy during flyover (should approach 100 % on 4 workers).
- 99th percentile frame time across 60 s flight at 50 m/s (the user's "25 fps dips" metric).

Target:
- Main-thread instantiate time drops from ~11 ms/ref to ~300 µs/ref (add_child only).
- 99p frame time during flyover under 20 ms (50 fps floor).
- Steady-state frame time unchanged — this is a latency fix, not a throughput fix.

---

## Appendix — File Cross-Reference

Files touched or referenced in this research (absolute paths):

- `<project-path>/src/core/world/reference_instantiator.gd` — the main-thread instantiate bottleneck
- `<project-path>/src/core/world/native_streaming_manager.gd` — the streaming loop
- `<project-path>/src/core/world/cell_manager.gd` — the per-cell FSM + add_child loop
- `<project-path>/src/core/world/static_object_renderer.gd` — the RS-direct fast path (canonical pattern today)
- `<project-path>/src/core/world/prototype_registry.gd` — world-scoped MultiMesh batching
- `<project-path>/src/core/world/object_paging.gd` — HLOD runtime merger (not NEAR)
- `<project-path>/src/core/world/distance_utils.gd` — NEAR_END / MID_END constants
- `<project-path>/docs/plans/streaming_stutter_2026_04_25.md` + `<project-path>/docs/audit/godot_46_near_streaming_aaa_audit_2026_04_29_codex.md` — the active plan + audit this research informs
- `<project-path>/inspos/openmw/apps/openmw/mwworld/cellpreloader.cpp` — canonical OpenMW preload pipeline
- `<project-path>/inspos/openmw/apps/openmw/mwworld/scene.cpp` — `preloadCells`, `changeCellGrid`, `loadCell`
- `<project-path>/inspos/openmw/apps/openmw/mwrender/objectpaging.cpp` — OpenMW chunk merge (HLOD, not NEAR)

Sources (external):

- [World Partition — UE docs](https://dev.epicgames.com/documentation/en-us/unreal-engine/world-partition-in-unreal-engine)
- [UE World Partition deep-wiki](https://deepwiki.com/chenyong2github/UnrealEngine/4.1-world-partition)
- [UE HLOD remeshing (Simplygon)](https://documentation.simplygon.com/SimplygonSDK_10.3.500.0/ue5/concepts/hlod.html)
- [Streaming the World of Horizon Zero Dawn (Guerrilla)](https://www.guerrilla-games.com/read/Streaming-the-World-of-Horizon-Zero-Dawn)
- [Decima SIGGRAPH 2017 Visibility](https://advances.realtimerendering.com/s2017/DecimaSiggraph2017.pdf)
- [Unity Addressables LoadSceneAsync](https://docs.unity3d.com/Packages/com.unity.addressables@2.0/manual/LoadingScenes.html)
- [RAGE Engine (Wikipedia)](https://en.wikipedia.org/wiki/Rockstar_Advanced_Game_Engine)
- [GTAMods Resource Streaming](https://gtamods.com/wiki/Resource_Streaming)
- [Star Citizen Object Container Streaming](https://starcitizen.tools/Object_Container_Streaming)
- [Godot Thread-safe APIs](https://docs.godotengine.org/en/stable/tutorials/performance/thread_safe_apis.html)
- [Godot Visibility ranges (HLOD)](https://docs.godotengine.org/en/stable/tutorials/3d/visibility_ranges.html)
- [Godot MultiMesh docs](https://docs.godotengine.org/en/stable/tutorials/performance/using_multimesh.html)
- [Godot issue #79194 — PackedScene threading](https://github.com/godotengine/godot/issues/79194)
- [Godot proposal #5240 — dithering VR LOD](https://github.com/godotengine/godot-proposals/issues/5240)
- [UE Smooth Apparition with Dithering](https://dev.epicgames.com/community/learning/tutorials/oLqa/unreal-engine-smooth-apparition-of-instances-with-dithering)
- [OpenMW Cell Settings docs](https://openmw.readthedocs.io/en/stable/reference/modding/settings/cells.html)
- [OpenMW CellPreloader API](https://openmw.github.io/classMWWorld_1_1CellPreloader.html)

---

## 7. Streaming Granularity — Grid vs Spatial Hierarchy vs Per-Object

### 7.1 The question

Should streaming use a flat grid (current), a spatial hierarchy (octree / quadtree), or per-object distance tracking? The answer differs by what is being asked: the **data unit**, the **loading trigger**, and the **instantiation order** are three separate concerns that can and should use different structures.

### 7.2 Why a flat grid is correct for the data unit

Morrowind's ESM format is a flat grid of `ExteriorCellRecord`s. Each cell record contains:
- a `(grid_x, grid_y)` integer key
- a flat list of `CellReference`s — every object in that cell

This is not an accident. The choice to organize world data into fixed cells (117 m × 117 m = 8192 × 8192 MW units) reflects the original engine's streaming unit. OpenMW, Bethesda's own toolchain, and every MW-compatible engine all treat the cell record as the atomic unit of world data.

**Consequence for Godotwind:** the data unit cannot be smaller than a cell without rebuilding the entire prebake pipeline to emit a per-object spatial index (object position → file offset). Per-object data streaming is possible but requires a separate spatial index layer over the ESM data. The cost is real and the benefit — for ~79 objects per cell — is marginal. This is not the current bottleneck.

**What a quadtree or BVH over objects would enable:**
- Sub-cell load granularity: load the NW quadrant of cell (-3,-2) before the SE quadrant based on approach direction.
- At ~79 refs/cell split into 4 quadrants = ~20 refs per quadrant. Loading granularity drops from 870 ms → ~220 ms per quadrant.
- **This is a valid future enhancement but premature optimization now.** The CellPreloader + Phase A (off-thread instantiate) already drops the 870 ms wall to ~25 ms (worker thread, 4 cores). Sub-cell quadrant loading buys another 4× but on top of an already small number.

### 7.3 Why an octree is wrong here

An octree subdivides 3D space. It is the right structure for:
- 3D point-query acceleration (e.g., finding nearby lights, collision broad-phase queries)
- Worlds with significant vertical variation (underground levels, skyscrapers)
- Frustum cull acceleration over irregular geometry

It is the wrong structure for an **outdoor world streaming trigger** because:
- The Y (vertical) dimension in Morrowind is narrow (~2m of terrain height variation per cell, occasional buildings to ~20 m). Subdividing in Y adds 2× depth levels that buy nothing.
- Morrowind cells are already 2D. The correct projection is a **quadtree**, not an octree.
- A quadtree for the streaming trigger would help only if cells had variable size — i.e., you wanted to stream a 512 m × 512 m "super-cell" at long distance and a 58 m × 58 m quarter-cell at close range. **We already have this**: the HLOD system (1×1, 2×2, 4×4 merged chunks) IS a crude quadtree for the rendered geometry. For the data side, it buys nothing because all data is in 117 m cells.

**Verdict:** octree = not applicable. Quadtree = already implemented at the HLOD rendering level. For the data + streaming trigger, a flat grid is correct and optimal.

### 7.4 What the industry actually uses

| Engine | Data unit | Streaming trigger | Instantiation order |
|---|---|---|---|
| UE5 World Partition | Variable grid (128 / 512 / 2048 m depending on LOD level) | 2D quadtree source query | Per-actor priority (distance + visibility) |
| Decima | Fixed rect tile | Distance ring (camera + AI sources) | Pre-built GPU buffer — no per-instance order |
| RAGE | Sector (fixed, hierarchical) | Player-intersects-sector-bounds | Resource priority queue (distance) |
| OpenMW | Fixed 117 m cell | Camera radius + velocity lookahead | Flat load order (no per-ref priority) |
| Godotwind today | Fixed 117 m cell | Camera radius (no velocity) | Per-ref distance sort (✓ correct) |
| **Godotwind target** | **Fixed 117 m cell + ESM** | **Camera radius + velocity-extrapolated preload ring** | **Per-ref distance sort (keep), Phase F prototype pre-register** |

UE5's variable grid is motivated by the need to stream content at multiple LOD levels — large HLOD meshes (baked) at 2048 m, individual actors at 128 m. Godotwind handles this via the NEAR / MID / HLOD / FAR tier system, not by varying cell size. The streaming unit for each tier already differs in spatial extent; the cell boundary is just the data key.

### 7.5 Per-cell vs per-object for the border-spike problem

**The user concern: "per-cell loading is not granular — bulk loading whenever you get close to a cell border."**

This concern is correct but misattributed. The bulk is not a spike — it is a drip. Here is the actual timeline:

```
t=0    : camera crosses border into cell (-4,-2)
t=0    : cell record parsed from ESM data (~1 ms, already cached)
t=0    : 79 CellReference objects enter _instantiation_queue
t=0    : _instantiation_queue sorted by distance — nearest refs first ✓
t=4ms  : budget tick 1 — nearest 3-4 Node3D refs instantiated
t=8ms  : budget tick 2 — next 3-4 refs
...
t=870ms: last ref instantiated (79 refs × ~11 ms each / 4ms-per-frame budget = ~218 frames)
```

The problem is not a spike at `t=0` — the problem is that the cell is STILL LOADING at `t=870 ms`. At 20 m/s (horse), you've moved 17 m. At 50 m/s (flying), you've moved 43 m — over a third of the cell's width. Objects are still popping in after you've covered most of the cell.

**Per-object streaming does not fix this.** If you stream per-object (trigger: "object within radius R"), you move the load trigger earlier — but each object still costs ~11 ms to instantiate. You get more objects loading simultaneously (wider trigger radius), but the instantiation rate is still bounded by the 4 ms/frame budget. You've swapped "load everything in a cell when you cross the border" for "load everything in a ring when you approach" — the throughput is unchanged, only the timing shifts.

**What actually fixes the border spike:**

| Fix | Effect | Where |
|---|---|---|
| Phase A: off-thread `PackedScene.instantiate()` | 11 ms → 300 µs per object on main thread. 79 objects complete in ~25 ms wall instead of 870 ms. | `reference_instantiator.gd` |
| CellPreloader: pre-load PackedScene resources before border | `ResourceLoader.load()` is a cache-hit when you cross — instantiation starts immediately without async wait. | new `cell_preloader.gd` |
| `find_children` VR cache: per-prototype subtree walk cached | Eliminates the O(subtree) per-instance walk at add_child time. | `cell_manager.gd` |
| Impostor stand-in until NEAR is fully loaded | FAR-tier impostor stays visible, NEAR geometry fades in as it arrives — zero visible pop. | `native_streaming_manager.gd` |

The correct framing: **per-cell is the right data unit; the instantiation cost is the real problem, not the trigger granularity.** A per-object spatial trigger with the same 11 ms/object instantiation cost produces the same perceived pop-in at a higher implementation cost.

### 7.6 When finer granularity DOES matter (the horse/flying case)

At very high speeds, the issue shifts from "objects pop in" to "the cell ahead is not loaded at all." At 50 m/s crossing a 117 m cell in 2.3 s, the preload must start > 2.3 s before the border is reached. At 100 m/s, > 1.15 s.

The fix here is velocity-extrapolated preload — which IS per-cell, but triggered by predicted position rather than current position. See §8 for the full design.

The sub-cell quadrant loading mentioned in §7.2 would additionally help here: even if the preloader triggers for the full cell, instantiation starts from the nearest quadrant. Phase A (off-thread) collapses this concern: once instantiation costs 300 µs instead of 11 ms, an entire 79-object cell loads in 24 ms, well within any movement budget.

---

## 8. Production CellPreloader Design

### 8.1 Design goals

1. Zero visible pop-in at walk and horse speeds with NEAR full-3D (< 20 m/s).
2. Reduced (but potentially nonzero) pop-in at flying speeds (> 50 m/s) — impostor fallback covers any gap.
3. Never spike the main thread. All heavy work off-thread via `WorkerThreadPool`.
4. LRU-bounded memory. Pre-loaded resources are PackedScenes in the ResourceLoader cache — controlled by cache size, not leaked.
5. Abort cleanly on teleport. An in-flight preload for the wrong cell is cancelled, not completed.
6. Integrates with Phase F prototype pre-registration so RS instances are ready before Node3D instantiate begins.

### 8.2 The two-phase model

The key insight from OpenMW's `CellPreloader`: **pre-loading and instantiation are separate phases**. The preloader only runs the DATA phase:

```
DATA phase (off-thread, CellPreloader):
  - ESM cell parse (already done by native_streaming_manager; CellPreloader can reuse the async result)
  - ResourceLoader.load(model_path) for every unique model in the cell → PackedScene
  - WorkerThreadPool: _worker_preregister_prototype() for every model → RS MultiMesh slots ready
  - Result: ResourceLoader cache is warm, PrototypeRegistry has all slots

INSTANTIATION phase (main-thread, CellManager, only when camera enters active radius):
  - For static refs: StaticObjectRenderer.add_instance(rid, xf) — pure RS call, ~10 µs each
  - For interactive refs: PackedScene.instantiate(EDIT_STATE_DISABLED) off-thread (Phase A),
    then call_deferred("add_child") on main → ~300 µs main-thread cost per ref
```

When the DATA phase has run before the INSTANTIATION phase begins, every `ResourceLoader.load()` call is a cache hit (near-zero cost). Every prototype pre-registration is already done. The instantiation wall time drops from ~870 ms to ~25 ms (Phase A cost only).

### 8.3 Speed-scaled lookahead

The prediction window must scale with speed. OpenMW uses a fixed 1s prediction time — sufficient for walk/run but inadequate for flying.

The correct formula:

```
t_load_budget := measured_avg_cell_load_time  # Phase 0 data: ~1.5s for 79 refs at 4ms/frame
t_load_budget_phaseA := ~0.025s              # after Phase A: 79 refs × 300µs = 24ms
speed := _camera_velocity_xz.length()
t_predict := clamp(t_load_budget / max(speed, 1.0), 0.3, 4.0)
predicted_pos := camera_xz + velocity_normalized * speed * t_predict
```

Before Phase A: at 50 m/s, t_predict = 1.5 / 50 = 0.030 s → 1.5 m lookahead. Too short. But the preloader's job is to warm the ResourceLoader cache, which alone saves ~500 ms of the 870 ms wall (resource load is the bottleneck before Phase A). So:

```
t_cache_warm := measured_avg_resource_load_time_per_cell  # estimate ~0.8-1.0s
t_predict := clamp(t_cache_warm / max(speed, 1.0), 0.3, 4.0)
```

This is the lookahead needed to have the CACHE WARM by the time you cross the border. After Phase A, instantiation is so fast that the preloader only needs to fire one cell ahead to avoid any visible pop.

**Multi-cell lookahead for fast movement:**

At > 40 m/s, single-cell lookahead may not be enough if load latency is > 2.3 s. Preload all cells along the movement vector within `preload_depth` cells:

```
preload_depth := clamp(int(speed / CELL_SIZE_METERS * t_cache_warm) + 1, 1, 4)
```

At 50 m/s with 1s cache warm: depth = int(50/117 * 1.0) + 1 = 1. Fine.  
At 100 m/s with 1s cache warm: depth = int(100/117 * 1.0) + 1 = 1. Fine.  
At 200 m/s (creative-mode fly): depth = int(200/117 * 1.0) + 1 = 2. Pre-queue 2 cells ahead.

So preload_depth ≤ 4 in all practical cases. No need for more.

### 8.4 LRU cache design

```gdscript
class PreloadEntry:
    var cell: Vector2i
    var state: String  # "loading" | "ready" | "activated"
    var last_touched_msec: int
    var task_ids: Array[int]  # WorkerThreadPool task IDs, for abort
    var model_paths: Array[String]  # cached for abort / stats

var _preload_cache: Dictionary  # Vector2i -> PreloadEntry
```

**Eviction policy:**
- Max size: 20 cells (OpenMW default). Memory cost: 20 × 79 refs × avg PackedScene ~50KB = ~80 MB. Acceptable.
- Eviction trigger: `update_cache()` called every frame, evicts entries where `last_touched_msec < now - EXPIRY_DELAY_MS` AND `cache_size > MIN_CACHE_SIZE`.
- `EXPIRY_DELAY_MS = 5000` (5 s), `MIN_CACHE_SIZE = 12` cells (keep warm for back-tracking).
- Evicted entries: abort in-flight WorkerThreadPool tasks via `wait_for_task_completion()` (required — skipping is a memory leak per CLAUDE.md anti-patterns).

**Promotion / demotion:**
- `LOADING` → `READY`: all `task_ids` complete (poll with `is_task_complete(id)`).
- `READY` → `ACTIVATED`: `native_streaming_manager` calls `notify_activated(cell)` when the cell enters active radius.
- `ACTIVATED` entries skip eviction (the streaming manager owns them now).

### 8.5 Integration with native_streaming_manager

Replace `_predict_and_prequeue_cells()` (the current naive predictor) with a call to `CellPreloader.update(camera_xz, velocity_xz)`. The preloader returns a `predicted_set: Array[Vector2i]` of cells to pre-queue.

`_update_loaded_cells()` becomes:
1. Query `_preloader.get_predicted_cells()` — cells to pre-warm but not yet load.
2. Query `_get_cells_in_radius()` — cells to actually load (current behavior).
3. Union: cells in predicted_set ∩ not in loaded/loading → preloader.preload(cell).
4. Cells in active radius ∩ in preloader cache as READY → instantiation fast-path (cache-hit load).
5. Cells in active radius ∩ not in preloader cache → instantiation cold-path (current behavior, slower).

### 8.6 Phase F integration (prototype pre-registration)

The existing `_worker_preregister_prototype()` in `reference_instantiator.gd` already pre-registers prototypes in the PrototypeRegistry off-thread. The CellPreloader should call this for every model path in the preloaded cell's ref list. By the time the cell enters active radius:
- ResourceLoader cache: warm (PackedScene parsed)
- PrototypeRegistry: all MultiMesh slots allocated
- RS instances: can be created in O(µs) instead of O(ms) cold-start

This is the "Phase F + CellPreloader" combination that eliminates the cold-registration stall that Phase F alone already fixed for the first-boot case.

### 8.7 Door / teleport preload (free bonus)

The same CellPreloader handles door-approach preloading:
- When the raycaster detects an interactive door ref within `PRELOAD_DOOR_DISTANCE` (e.g. 20 m), call `preloader.preload(door_destination_cell)` and if interior, `preloader.preload_interior(door_destination_cell_ref)`.
- This eliminates the "touch door → freeze" hitch in interior transitions that `interior_pocket_manager` currently has.
- Implementation: ~10 LOC in `world_explorer._process` or the raycaster hook.

### 8.8 Abort on teleport

When `native_streaming_manager` detects a teleport (jump > `TELEPORT_DETECT_THRESHOLD = 500 m`):
1. Call `preloader.abort_all()` — marks all in-flight tasks for cancel, stops all eviction scheduling.
2. Re-initialize preloader at new camera position with `preloader.reset(new_cell)`.
3. Preloader re-warms cells around new position at normal load priority (same path, different trigger).

This replicates OpenMW's `abortTerrainPreloadExcept` pattern.

### 8.9 File layout

```
src/core/world/cell_preloader.gd       # new file, ~250 LOC
```

No new autoload. Owned by `native_streaming_manager` (instantiated in `configure()`, updated in `_process()`). The existing `_predict_and_prequeue_cells` function is deleted and replaced by `_preloader.update()`.

### 8.10 What NOT to build

- **Sub-cell quadrant loading**: not needed once Phase A reduces instantiation cost to 25 ms/cell. Revisit only if Phase A is skipped.
- **Octree spatial index over objects**: adds ~300 LOC of spatial bookkeeping for a problem that Phase A + CellPreloader already solve. Do not build.
- **Per-object distance streaming** (streaming individual refs as camera approaches): replaces the proven data unit (ESM cell) with per-object bookkeeping, adding O(refs) dict lookups per frame. The cost is higher and the benefit is only visible if Phase A is also shipped — at which point the cell-unit approach is already fast enough. Build only if a specific use case (e.g. very large interior pockets > 500 objects) makes per-cell too coarse.
- **Variable-size streaming cells** (UE5 World Partition style): requires a multi-LOD object indexing pipeline. Godotwind handles multi-LOD via the NEAR/MID/HLOD tier system at the rendering level — the streaming unit stays fixed at 117 m. Not applicable here.

### 8.11 Implementation order

Phase A (off-thread `PackedScene.instantiate()`) and CellPreloader are independent but complementary:
- **CellPreloader alone** (without Phase A): reduces pop-in from ~870 ms to ~500 ms at walk speed (resource load phase pre-warmed, instantiation still on main thread). Visible improvement but not complete.
- **Phase A alone** (without CellPreloader): reduces pop-in from ~870 ms to ~25 ms at walk speed. Cell-cross hitches eliminated for walk/run. Horse speed marginal. Flying still pops.
- **Phase A + CellPreloader**: ~25 ms instantiation wall + cache-warm before border cross = pop-in effectively zero at all speeds ≤ 100 m/s. Impostor fallback covers > 100 m/s edge.

**Recommended order:** Phase A first (highest individual gain, no new file), then CellPreloader (seals the fast-movement gap).

---
