# NEAR-Tier Streaming — Industry Pattern Survey + Godotwind Recommendation

**Status:** Research pass, 2026-04-20. Authored by @researcher on branch `perf/distant-rendering-2026-04-17`.
**Scope:** NEAR tier only (0-150 m). MID / HLOD / FAR are parked per `docs/plans/distant_rendering_2026_04/near_tier_refactor.md` §1.
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

- `D:/Gamedev/Godotwind/godotwind/src/core/world/reference_instantiator.gd` — the main-thread instantiate bottleneck
- `D:/Gamedev/Godotwind/godotwind/src/core/world/native_streaming_manager.gd` — the streaming loop
- `D:/Gamedev/Godotwind/godotwind/src/core/world/cell_manager.gd` — the per-cell FSM + add_child loop
- `D:/Gamedev/Godotwind/godotwind/src/core/world/static_object_renderer.gd` — the RS-direct fast path (canonical pattern today)
- `D:/Gamedev/Godotwind/godotwind/src/core/world/prototype_registry.gd` — world-scoped MultiMesh batching
- `D:/Gamedev/Godotwind/godotwind/src/core/world/object_paging.gd` — HLOD runtime merger (not NEAR)
- `D:/Gamedev/Godotwind/godotwind/src/core/world/distance_utils.gd` — NEAR_END / MID_END constants
- `D:/Gamedev/Godotwind/godotwind/docs/plans/distant_rendering_2026_04/near_tier_refactor.md` — the active plan this research informs
- `D:/Gamedev/Godotwind/godotwind/inspos/openmw/apps/openmw/mwworld/cellpreloader.cpp` — canonical OpenMW preload pipeline
- `D:/Gamedev/Godotwind/godotwind/inspos/openmw/apps/openmw/mwworld/scene.cpp` — `preloadCells`, `changeCellGrid`, `loadCell`
- `D:/Gamedev/Godotwind/godotwind/inspos/openmw/apps/openmw/mwrender/objectpaging.cpp` — OpenMW chunk merge (HLOD, not NEAR)

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
