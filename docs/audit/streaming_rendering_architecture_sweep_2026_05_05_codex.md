# Godotwind Streaming and Distance Rendering Architecture Sweep

Date: 2026-05-05
Author: Codex
Scope: current workspace architecture, compared against `251825ce19888ef3a82bcebf9f6900a768f60517` and the local reference docs.

This document is a broad audit of Godotwind's current open-world object streaming and distance-rendering stack. It focuses on the path that matters for the stated target: a smooth 100+ FPS experience with NEAR, MID, HLOD, FAR impostors, and distant lights active together.

No runtime code was changed for this audit. This was a static/read-only architecture pass, assisted by focused subagent audits. Because the only output is documentation, the Godot scene was not launched as a gameplay/rendering verification step.

## References Read

- `docs/STATUS.md`
- `docs/systems/distance_rendering.md`
- `docs/systems/object_paging.md`
- `docs/systems/impostor_streaming_rendering.md`
- `docs/reference/streaming_rendering_bible.md`
- `docs/reference/godot_46_near_streaming_aaa_audit_2026_04_29_codex.md`
- `docs/reference/hlod_mid_streaming_research_2026_05_02_hlod.md`
- Godot 4.6 official docs for visibility ranges/HLOD, `MultiMesh`, and thread-safe APIs:
  - https://docs.godotengine.org/en/4.6/tutorials/3d/visibility_ranges.html
  - https://docs.godotengine.org/en/4.6/classes/class_multimesh.html
  - https://docs.godotengine.org/en/4.6/tutorials/performance/thread_safe_apis.html

## Executive Verdict

The current stack contains a strong, canonical core:

- NEAR gameplay objects stay sparse.
- ordinary static visuals are routed out of the scene tree.
- MID uses `RenderingServer`/`MultiMesh` cell buckets, not thousands of `Node3D`s.
- expensive work is mostly sliced into frame-budgeted lanes.
- worker threads prepare data, while scene tree and `RenderingServer` publication stay on the main thread.

That is the same broad pattern that made commit `251825ce19888ef3a82bcebf9f6900a768f60517` feel fast.

The regression risk is the distant stack layered on top of it. Since that commit, the default workload changed from a compact NEAR/MID path with HLOD and impostors parked to a full distant rendering path:

- MID fixed to roughly 150-300m.
- HLOD default-on through `world_explorer.gd`, intended for 300-1000m.
- FAR impostors default-on from 1000m to the view cap.
- distant lights default-on.
- view distance defaults to 5000m.

The largest architecture concerns are:

1. HLOD can plausibly omit important models in the 300-1000m band.
2. HLOD's current filtering/coverage rules mix two separate concepts: "what should render as HLOD" and "what is complete enough to let MID turn off."
3. FAR impostors are not a reliable fallback for HLOD omissions because FAR starts at 1000m and depends on prebuilt impostor candidates/assets.
4. The total main-thread publication budget is fragmented across multiple subsystems, so each subsystem can be "budgeted" and still collectively blow the frame.
5. Distant rendering is still tightly coupled to Morrowind ESM/ref data inside `src/core/world`, which violates the framework/adapter boundary.
6. Several comments and docs disagree with the current runtime defaults, which makes tuning dangerous.

The minimal clean target is not "more patches on top of HLOD." It is to preserve the NEAR/MID core, simplify HLOD ownership, and make coverage/fallback explicit.

## What The Fast Commit Actually Proved

Commit `251825ce19888ef3a82bcebf9f6900a768f60517` was described as efficient NEAR object streaming and rendering. The important detail is that it was not the current full distant-rendering stack running cheaply.

At that commit:

- `world_explorer.gd` defaulted to a small active view/cell footprint.
- `NativeStreamingManager.load_radius_cells` defaulted to `1`, giving a roughly 3x3 loaded-cell scene footprint.
- HLOD was opt-in.
- FAR impostors were opt-in.
- static clutter was already renderer-owned instead of scene-tree-owned.
- old per-frame script LOD/distance managers were not the active loop.

The main win was architectural: ordinary static references did not become gameplay nodes. `ReferenceInstantiator` routed non-interactive, non-carryable, non-animated statics to `StaticObjectRenderer`. `StaticObjectRenderer` and `CellStaticBucket` owned the visual RIDs and `MultiMesh` instances. Gameplay nodes were reserved for actors, interactives, carryables, animated objects, doors/containers/activators, and nearby gameplay-relevant lights.

That commit is a useful performance baseline, but it should not be read as proof that the present 5km distant stack can be cheap without additional discipline. The workload is materially different now.

## Current Runtime Defaults

`src/tools/world_explorer.gd` currently sets these subsystem defaults:

- `near_objects`: true
- `mid_objects`: true
- `hlod`: true
- `impostors`: true
- `distant_lights`: true
- `shadows`: false
- `postfx`: false

The streaming manager itself initializes some distant systems dark until `world_explorer.gd` syncs the defaults. The effective main scene behavior is full distant tiers enabled unless command-line flags disable them:

- `--near-only`: disables HLOD, impostors, distant lights, and other expensive subsystems.
- `--no-hlod`: disables HLOD only.
- `--no-impostors`: disables FAR impostors.
- `--hlod-only`: isolates HLOD plus terrain.

This is an important docs drift point. Some older reference docs still describe HLOD as opt-in or FAR as starting at 500m. The current main-scene default is HLOD/FAR/distant-lights on, with FAR starting at 1000m.

## Current Tier Contract

The intended live contract is:

| Tier | Range | Primary owner | Representation |
| --- | --- | --- | --- |
| NEAR | 0-150m | `NativeStreamingManager`, `CellManager`, `ReferenceInstantiator` | sparse gameplay `Node3D`s plus renderer-owned statics |
| MID | 150-300m | `StaticObjectRenderer`, `CellStaticBucket` | cell-local RS instances and `MultiMesh` buckets |
| HLOD | 300-1000m | `ObjectPaging`, `ObjectPagingKernel`, C# merge kernel | merged chunk proxy meshes, one RS instance per chunk |
| FAR | 1000m-view cap | `NativeImpostorRenderer` | paged baked impostor `MultiMesh` instances |
| Distant lights | distant ring | `DistantLightManager` | light proxies/pages |

There is some intentional overlap at boundaries. For example, `CellStaticBucket` pads MID visibility by bucket radius so large objects do not disappear when their origin crosses a range boundary. That is probably correct, but it means the docs should stop claiming perfectly non-overlapping tiers. The real contract is "handoff with padding and hysteresis."

## Current Data Flow

### Main scene boot

`world_explorer.gd` creates/configures the world, console, UI toggles, streaming manager, cell manager, terrain, environment controls, and benchmark tooling. It then syncs subsystem defaults into `NativeStreamingManager`:

- `set_impostors_visible(true)`
- `set_hlod_visible(true)`
- `set_distant_lights_visible(true)`
- `set_view_distance_meters(...)`

### Per-frame streaming loop

`NativeStreamingManager._process()` is the central frame driver. It:

- updates camera/cell position.
- detects cell changes and teleports.
- updates loaded NEAR/MID scene cells.
- processes HLOD warmup/merge queues and completions.
- syncs HLOD coverage into MID and FAR.
- updates distant lights.
- updates cell preloading.
- processes budgeted unload/hide/free work.
- drains async cell completions.
- publishes cell payload work and static renderer preparation.
- submits new pending cell loads.
- emits profiler dumps for long frames.

This is a sensible single conductor, but the budgets underneath it are not yet a true global frame budget. HLOD, FAR, distant lights, static publishing, cell instantiation, unload, texture-array commits, and page rebuilds each have local caps. Local caps do not guarantee the combined cost stays below a 100 FPS frame target.

### NEAR cell lifecycle

`NativeStreamingManager` decides which cells should be loaded from camera cell position, `load_radius_cells`, scene-load distance, and unload hysteresis.

`CellManager` owns async cell requests and payload publishing. It classifies references into:

- gameplay scene nodes.
- static renderer entries.
- collision work.
- deferred/proximity objects.
- model load callbacks.

`ReferenceInstantiator` is the gameplay object gate. It keeps actors, doors, containers, activators, carryables, animated statics, and gameplay lights in the scene tree when needed. It routes ordinary static visuals to the renderer path.

This is the right direction. The risks are lifecycle details:

- proximity-deferred gameplay objects appear to be rechecked from cell-update flow, not an independent throttled proximity service.
- NEAR visibility toggles and unload start hide nodes with `visible = false`, but hidden physics bodies can remain active until free.
- object pooling appears acquire-heavy but not clearly released on the active unload path.
- static collision ownership may not be part of the same lifecycle completion contract as visual payload completion.

### MID renderer lifecycle

`StaticObjectRenderer` is the active MID/static visual owner. The older world-scoped prototype registry path is parked behind `USE_PROTOTYPE_REGISTRY = false`.

The current active route is:

1. `CellManager` classifies static refs and waits for model/prototype availability.
2. `StaticObjectRenderer.request_register_from_packed_scene()` builds immutable prototype descriptors from packed scenes under a small descriptor budget.
3. `StaticObjectRenderer.create_cell_bucket_budgeted()` creates a `CellStaticBucket`.
4. `CellStaticBucket.configure_step()` groups transforms into cell-local draw groups.
5. repeated transforms use `MultiMesh`; singleton groups use direct RS instances.
6. `CellStaticBucket` owns RIDs and pins the resource handle for its lifetime.

This is a solid canonical shape for Godot:

- no scene tree cost for ordinary statics.
- spatial buckets avoid world-scale `MultiMesh` culling problems.
- resource handles prevent mesh/material eviction while RIDs are alive.
- visibility ranges are native engine culling, not script polling.

Concerns:

- bucket hiding is advertised as budgeted by RS instance count, but `CellStaticBucket.set_visible(false)` loops all draw groups immediately. A large bucket can still burst many RS calls.
- legacy direct-instance methods remain in `StaticObjectRenderer`, mostly for proxies/tests. They add cognitive load and should be clearly quarantined or removed when possible.
- comments still describe older "one raw RS instance per object" or older range behavior in places.

### HLOD lifecycle

`ObjectPaging` owns runtime HLOD chunks. The current intended path is:

1. camera movement asks `ObjectPaging.update_for_camera()` for desired chunks.
2. desired chunk keys are generated by size tiers and chunk-center distance.
3. chunk 1 covers roughly 300-600m with 2x2 cells.
4. chunk 2 covers roughly 600-1000m with 4x4 cells.
5. chunk 0 exists for 150-300m but is below the current visual floor and is effectively skipped in normal HLOD rendering.
6. `_process_merge_prepare()` scans cells/refs on the main thread under a soft budget.
7. prototype submeshes are taken from `StaticObjectRenderer`.
8. a merge task is submitted to the background processor.
9. `ObjectPagingKernel`/C# merges surfaces into an `ArrayMesh`.
10. `process_completions()` publishes one chunk per frame to `RenderingServer`.
11. HLOD coverage manifest data is sent back to MID and FAR.

The broad worker/main-thread split is canonical for Godot. The weak spots are filtering, coverage, and cache ownership.

### FAR impostor lifecycle

`NativeImpostorRenderer` now uses spatial pages instead of one world-scale `MultiMesh`, which is a major improvement over broad/global culling.

The path is:

1. `NativeStreamingManager` requests an impostor radius and FAR begin distance.
2. `NativeImpostorRenderer.update_impostor_area()` adds/removes desired cells.
3. impostor records are loaded from source cells.
4. baked octahedral impostor assets are resolved.
5. texture-array buckets/slabs are built.
6. spatial pages are rebuilt into local `MultiMesh` buffers.
7. HLOD coverage can push page begin distance from FAR start to HLOD end when a page is fully covered by HLOD.

This is structurally much better than a single global impostor draw. The risks are:

- texture-array commits still happen on the main thread/GPU upload path.
- `TEXTURE_ARRAY_SLAB_LAYERS = 4` can create many texture buckets/materials/pages, trading smaller uploads for more draw calls and page objects.
- page-level HLOD suppression is conservative: one uncovered impostor keeps the whole page visible at FAR start.
- FAR starts at 1000m, so it does not cover HLOD holes in the 300-1000m band.
- FAR depends on prebuilt candidate metadata/assets and fails closed when an asset is missing.

## High-Risk Findings

### 1. HLOD can drop important objects in the 300-1000m band

This matches the user's visual suspicion.

The type filter is probably not the main problem. `ObjectPaging._type_eligible()` accepts `static`, `door`, and `activator`, and the current `PAGING_MIN_SIZE` is permissive enough for normal buildings.

The likely loss paths are:

- missing prototype data from `StaticObjectRenderer`.
- size/projected-size rejection.
- input surface budget rejection.
- final chunk surface-count rejection in `process_completions()`.
- partial-bucket rejection.
- negative chunk caching after a temporary miss.

The partial-bucket path is the most suspicious architecture issue. `_filter_partial_bucket_inputs()` keeps an accepted HLOD input only when the accepted count for its `cell:model` bucket equals the total source count for that bucket. That means one rejected same-model reference can remove all accepted references in that cell/model bucket.

This rule seems to exist to avoid telling MID, "HLOD covers this bucket completely," when HLOD only covers part of it. That goal is good. The implementation mixes up two questions:

- should this accepted object render in HLOD?
- is this whole MID bucket fully covered so MID can cap/hide it?

Those must be separate. Rendering a partial HLOD chunk is useful. Claiming full MID coverage from a partial HLOD chunk is unsafe.

Minimal clean fix direction:

- Keep accepted HLOD inputs even when their bucket is partial.
- Publish two manifests:
  - `rendered_ref_nums`: exact refs rendered by HLOD.
  - `complete_bucket_counts`: buckets safe to cap in MID.
- Only use complete buckets to shorten MID visibility.
- Use rendered ref nums for FAR suppression.
- Never remove a large accepted landmark just because a sibling ref in the same model bucket failed.

### 2. FAR is not a fallback for HLOD omissions

FAR currently begins at `DistanceUtils.FAR_START`, which is `1000m` through the current distance contract. If HLOD fails to render a house at 350m, FAR will not fill that hole.

Even beyond 1000m, FAR depends on impostor candidacy and baked v6 assets. Missing metadata, missing albedo, missing normal, or a non-candidate pattern means no impostor.

Therefore, HLOD must be visual-coverage-first in 300-1000m. It cannot assume FAR will cover failures.

### 3. HLOD cache eviction can free active chunks

`ObjectPaging._cache_evict_to_fit()` walks `_lru_order`; if the oldest key is active, it frees that active chunk's RS instance and erases it from `_active_chunks`.

That makes cache pressure capable of deleting visible HLOD chunks. For a runtime distance renderer, active chunks should be pinned. Cache eviction should only evict inactive cached meshes, or it should refuse publication until enough inactive memory is available.

Minimal clean fix direction:

- Treat active HLOD chunks as resident/pinned.
- Maintain separate inactive mesh cache and active visual set.
- Evict only inactive cache entries.
- If memory is over budget due to active chunks, report pressure and degrade future publication, not current visible coverage.

### 4. HLOD surface/material reduction is not strong enough yet

The current kernel merges into chunk meshes, but output surfaces are still driven by material identity. If source material identity is fragmented, a chunk can still publish many surfaces or fail the surface cap.

`RUNTIME_FORCE_MERGE_ELIGIBLE_REFS = true` also bypasses cost-benefit filtering, which favors visual coverage but can increase output surface/material pressure.

Canonical HLOD is not just "merge geometry." It is "merge geometry and aggressively reduce material/draw-call complexity." The current runtime HLOD is closer to a dynamic mesh aggregator than a full HLOD proxy system.

Minimal clean fix direction:

- prioritize keeping landmarks/large statics visible.
- reduce material count through proxy materials, atlasing, or material-class bucketing.
- if a chunk exceeds a surface cap, split it or degrade materials; do not drop the whole chunk.
- measure HLOD by visible chunk count, surface count, material count, draw calls, and rejected landmark count.

### 5. Main-thread budget is fragmented across systems

The architecture has many local budgets:

- cell queue/classification.
- async completion.
- scene instantiation.
- static descriptor preparation.
- static bucket publication.
- HLOD merge queue.
- HLOD completion publication.
- HLOD model warmup.
- FAR pending cell load.
- FAR texture-array commit.
- FAR page rebuild.
- distant light update/page rebuild.
- unload hide/free.
- static collision publish.

Each subsystem can respect its local budget while the combined frame still misses 10ms or 6.67ms. This is especially risky because some "budgeted" operations are only checked between coarse units, not inside a dense page, bucket, texture upload, or collision slice.

Minimal clean fix direction:

- one top-level streaming/render-publication budget for main-thread work.
- lanes request budget from the conductor.
- coarse atomic units report actual elapsed time.
- if the budget is exhausted, nonessential lanes skip the frame.
- startup/teleport can use a temporary larger budget, but steady-state should be strict.

### 6. Distant rendering is Morrowind-bound inside core world systems

`src/core/world` is supposed to be generic open-world framework code. Current object streaming/rendering still calls Morrowind-specific data directly:

- `ESMManager`
- `CellReference`
- record type strings.
- Morrowind model path conventions.
- Morrowind coordinate/reference assumptions.

This appears in `CellManager`, `ObjectPaging`, `NativeImpostorRenderer`, `DistantLightManager`, and impostor candidate logic.

This is not just architectural purity. It also hurts performance work because generic systems cannot consume a prebuilt, optimized, adapter-fed object manifest. They repeatedly rediscover source refs through ESM-oriented paths.

Minimal clean fix direction:

- introduce an object/ref streaming adapter boundary.
- core world systems consume a generic `WorldObjectRecord`/chunk manifest shape.
- Morrowind adapter owns ESM lookup, record type mapping, model path resolution, coordinate conversion, and candidate rules.
- HLOD/FAR/MID all consume the same source manifest instead of each scanning ESM in its own way.

## Medium-Risk Findings

### Proximity-deferred gameplay needs an independent service tick

Doors, containers, activators, carryables, and small lights can be parked until the player is close enough. That is the right idea. The recheck path appears tied to cell update flow, which means walking toward an object inside the same already-loaded cell may not spawn it promptly.

Minimal clean fix direction:

- a throttled proximity service tick, independent of cell-boundary changes.
- process a small number of deferred entries per frame or per interval.
- use distance bands/hysteresis so objects do not flap.

### NEAR hide is not physics deactivation

`visible = false` hides visuals, but it does not deactivate physics bodies or areas. During unload or benchmark toggles, invisible bodies can still exist until queue-free completes.

Minimal clean fix direction:

- separate visibility state from activation state.
- deactivate collision/process groups immediately on unload/tier-off.
- keep queue-free budgeted separately.

### Static collision lifecycle is not clearly part of request completion

The static collision builder uses worker tasks and server-direct physics bodies, which is the right broad pattern. But request completion appears primarily gated on visual/model/instantiation work. If static collision state remains attached only to the outgoing request payload, there is risk of missing collision or leaked PhysicsServer RIDs when the request is erased.

Minimal clean fix direction:

- collision body ownership transfers to a resident cell-owned record before request cleanup, or
- request completion includes collision completion/cancellation.

### Object pool appears acquire-heavy and release-light

The object pool is used for acquisition, but the active unload path appears to queue-free children rather than return them through `ObjectPool.release_cell_objects()`.

If that is correct, the pool has become misleading complexity. Either wire release into the active lifecycle or delete the pool from this path.

### Distant light pages still use per-instance setters

`DistantLightManager._rebuild_page()` uses per-instance `set_instance_transform`, `set_instance_color`, and `set_instance_custom_data` loops. The rest of the renderer has moved toward bulk `set_buffer()` uploads for dense MultiMesh pages.

Minimal clean fix direction:

- pack a page buffer and use bulk `set_buffer()`.
- check budget inside dense page rebuilds or make pages small enough that a page is a safe atomic unit.

### Bespoke thread pool remains in FAR texture IO

`BackgroundJobSystem` owns raw `Thread` workers. Project guidance explicitly favors Godot `WorkerThreadPool` over naked threads. The current custom thread pool also has stop/wait behavior that can block during toggles or cleanup.

Minimal clean fix direction:

- migrate FAR background IO/processing jobs to `WorkerThreadPool` or the existing `BackgroundProcessor` wrapper if it is WorkerThreadPool-backed.
- make cancellation/generation ownership explicit.

### MID/HLOD overlap is safer than docs say, but should be documented

MID buckets extend visibility by bucket radius to prevent large object origin culling. This is good, but the docs should describe "padded handoff" rather than strict non-overlap.

### Negative HLOD chunks can preserve temporary absence

`ObjectPaging` keeps `_negative_chunks` so failed/empty chunks are not constantly retried. That is useful. But if a chunk is negative because prototypes were missing and those prototypes later warm up while the chunk remains in the desired ring, the negative entry can keep the hole until the player leaves/re-enters the ring.

Minimal clean fix direction:

- separate permanent negatives from temporary negatives.
- expire temporary negatives quickly or clear them when prototype warmup completes.

## Low-Risk But Important Drift

Comments/docs still disagree on:

- HLOD opt-in vs default-on.
- FAR 500m fallback vs FAR 1000m.
- `PAGING_MIN_SIZE` tuning comments vs current value.
- MID described as one raw RS instance per object vs current cell buckets.
- promotion/demotion constants that look vestigial after per-actor promotion loops were removed.
- strict non-overlap vs radius-padded visibility.

This drift matters because performance tuning depends on knowing which tier owns each meter of space.

## Things That Look Good And Should Be Preserved

- Ordinary statics stay out of the scene tree.
- static renderer resources are pinned while RIDs exist.
- MID is spatially bucketed, not one world-scale `MultiMesh`.
- `CellStaticBucket` owns cleanup and RID lifetime.
- HLOD merge work does not touch scene tree/ESM on worker threads.
- HLOD completion append was checked directly and is outside the `bytes <= 0` branch in the current workspace; the suspected "successful merges never publish" issue was not confirmed.
- FAR is spatially paged now, which fixes the old global-MultiMesh culling issue.
- `RenderingServer.instance_geometry_set_visibility_range()` is used instead of script-side per-frame distance hiding.
- runtime LOD generation for HLOD is disabled in the hot path, avoiding a known main-thread cost.

## Minimal Clean Architecture Target

The clean target is not a large rewrite for its own sake. It is a smaller set of stronger contracts.

### 1. Keep the NEAR/MID fast core

Do not undo the good part:

- scene tree only for gameplay.
- statics in renderer-owned buckets.
- spatial buckets, not global instances.
- Godot visibility range for culling.
- resource handles pinned while RIDs live.
- worker preparation and main-thread publication.

### 2. Make tier ownership explicit

Use one source of truth:

- NEAR gameplay: 0-150m.
- MID static buckets: 0/150-300m plus radius padding and hysteresis.
- HLOD visual proxies: 300-1000m, coverage-first.
- FAR impostors: 1000m-view cap.
- distant lights: own separately measured tier.

Document overlap honestly.

### 3. Split HLOD render coverage from MID suppression

HLOD should render every accepted important object it can. MID should only turn off buckets that HLOD covers completely.

Required manifests:

- `rendered_ref_nums`: refs actually present in HLOD.
- `complete_bucket_counts`: only buckets where accepted count equals source bucket count.
- `chunk_quality`: counts for skipped, size rejected, prototype missing, surface rejected, partial bucket, type rejected.

MID consumes complete buckets. FAR consumes rendered refs/pages. Debug HUD exposes holes.

### 4. Prefer degradation over disappearance

In the HLOD band, dropping a building is worse than rendering it with a simplified material.

If surface/material limits are exceeded:

- split the chunk.
- simplify material assignment.
- use proxy material classes.
- reduce small clutter first.
- keep landmarks/large statics.

Do not reject the entire chunk as the normal response to high material complexity.

### 5. Use a shared frame budget conductor

At 100 FPS the whole frame is 10ms. At 144 FPS it is 6.94ms. Streaming publication cannot casually spend several independent 2-4ms budgets.

The conductor should own a steady-state main-thread budget, for example:

- high priority: unload activation/hide, visible hole repair, active chunk publication.
- medium priority: nearby cell payload publish, MID bucket publish.
- low priority: FAR page rebuild, texture-array compaction, distant light rebuild, stats.

Every lane reports actual elapsed usec. Coarse atomic units are measured and either reduced or moved offline if they spike.

### 6. Move source object discovery behind an adapter

Core world systems should not know ESM details. Add or extend a data-provider layer so MID/HLOD/FAR/distant lights consume the same generic object manifests.

This makes the architecture both cleaner and faster:

- no repeated ESM scans per subsystem.
- no format-specific code in generic world systems.
- easier prebake/cache path later.
- one place for type/candidate rules.

### 7. Quarantine or delete parked paths

Parked systems are not free. They make each future bug hunt harder.

Candidates to quarantine behind clear comments or remove after replacement:

- `StaticObjectRenderer` prototype registry path if it is permanently disabled.
- legacy direct instance APIs only used by tests/proxies.
- old promotion/demotion constants if per-actor promotion is gone.
- old docs/comments about FAR 500m and HLOD opt-in.
- object pool if active unload never releases to it.

## Suggested Next Verification Pass

The next pass should be runtime, not another static audit. It should use either interactive launch or an automated benchmark/crash smoke, per project rule.

Suggested command:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn
```

Suggested measurements:

- FPS, frame time p95/p99, draw calls, object count.
- visible static RS instances, visible MID buckets, visible HLOD chunks, visible FAR pages.
- HLOD active chunks, negative chunks by reason, rejected refs by reason.
- HLOD output surfaces/materials/vertices per chunk.
- FAR texture bucket count, slab count, visible page count, page rebuild time, texture commit time.
- distant light page count and rebuild time.
- total main-thread streaming time per frame, not just per-lane local budgets.
- visual inspection around house-heavy exterior areas with HLOD enabled and MID capped.

Useful A/B matrix:

| Run | NEAR | MID | HLOD | FAR | distant lights | Goal |
| --- | --- | --- | --- | --- | --- | --- |
| baseline old shape | on | on | off | off | off | compare to fast commit feel |
| HLOD isolation | off | off | on | off | off | find HLOD holes/draw cost |
| FAR isolation | off | off | off | on | off | measure pages/slabs/uploads |
| distant lights isolation | off | off | off | off | on | measure light page cost |
| full stack | on | on | on | on | on | target runtime |
| no HLOD | on | on | off | on | on | detect HLOD-specific holes/spikes |
| no FAR | on | on | on | off | on | detect impostor-specific spikes |

## Highest-Value Next Fixes

1. Fix HLOD partial-bucket logic so partial accepted inputs still render, while only complete buckets suppress MID.
2. Pin active HLOD chunks so cache eviction cannot remove visible chunks.
3. Add HLOD hole telemetry: accepted/rejected large refs, negative chunks, per-chunk surface/material counts, and visible coverage by band.
4. Add a top-level streaming publication budget report that sums all lanes.
5. Migrate FAR custom thread jobs to `WorkerThreadPool` or a canonical WorkerThreadPool-backed wrapper.
6. Decide whether object pooling is real; wire release or remove the pool from the active path.
7. Move object/ref discovery behind a generic adapter manifest so HLOD/FAR/MID stop scanning Morrowind data directly.

## Final Assessment

The architecture is not hopeless. The old fast path is still visible inside the current system: sparse gameplay nodes, renderer-owned statics, cell buckets, native visibility ranges, and resource pinning are all good.

The current FPS and HLOD doubts are likely coming from the added distant tiers and the coordination rules around them, not from the core NEAR idea failing. The biggest conceptual cleanup is to make HLOD coverage-first, make MID suppression exact, and put all publication work under one real frame budget. That is the shortest path back to "buttery" without papering over the wrong layer.
