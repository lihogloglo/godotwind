# NEAR Streaming Smoothness Handoff

Date: 2026-04-28

Purpose: make NEAR-only streaming/rendering smooth during fast cell-boundary
traversal in Godot 4.6. This is a living implementation handoff, intentionally
compressed. Older benchmark archaeology was trimmed; keep this file focused on
current facts, constraints, and next work.

## Current Goal

Build a NEAR runtime where crossing a cell boundary schedules small prepared
publish jobs instead of synchronously loading, classifying, instantiating,
allocating batches, finalizing collision, unloading, and uploading buffers in
one frame.

Design direction:

- Bulk static visuals: `RenderingServer` / `MultiMesh`.
- Sparse gameplay objects: `Node3D` only for true interactives.
- Data/model preparation before visual publish.
- Collision on its own lane.
- Benchmarks must classify the worst frames without manual guessing.

## Godot 4.6 Rules

- Use `RenderingServer` / `MultiMesh` for bulk statics. Do not create thousands
  of `Node3D` / `MeshInstance3D` objects for static clutter and architecture.
- Main-thread publish can call server/resource APIs, but every expensive class
  needs its own budget and telemetry column.
- Worker threads may prepare plain data: sort refs, compute transforms, collect
  triangle data, build payloads, and request resources. Avoid normalizing the
  runtime around mass off-thread rendering-node scene creation.
- Avoid asking servers for data every frame. Runtime server calls should mostly
  be one-way create/update/free operations.
- Keep `STATIC_CULL_NATIVE_ENABLED=false` until the C# buffer packing handoff is
  reworked and proven stable.
- Keep `DEBUG_DISABLE_PHASE_F_PREREG=true` by default. The off-thread
  `PackedScene.instantiate()` / static registration path is still crash-risky.
- `MultiMesh.set_buffer()` remains sensitive. Do not call it for newly-created
  empty batches or as a hidden side effect of batch reserve.

Relevant Godot docs:

- Thread-safe APIs:
  `https://docs.godotengine.org/en/4.6/tutorials/performance/thread_safe_apis.html`
- MultiMeshes:
  `https://docs.godotengine.org/en/4.6/tutorials/performance/using_multimesh.html`
- RenderingServer:
  `https://docs.godotengine.org/en/4.6/classes/class_renderingserver.html`
- PhysicsServer3D:
  `https://docs.godotengine.org/en/4.6/classes/class_physicsserver3d.html`

## AAA / Open-World Pattern

Use a data-first streaming pipeline:

- Cell refs / ESM records are source data.
- Prebaked `.res`, `.lod.res`, and `.shapes.res` files are resource data.
- `CellPayload` is prepared data.
- Active scene/server state receives only small budgeted publish operations.
- Visual statics are server/MultiMesh data, not scene-tree forests.
- Interactives are promoted lazily and sparsely.
- Collision can lag visual activation briefly, but it must not hitch visual
  streaming.
- Boundary crossing should enqueue desired-state changes only. Scans, loads,
  publish, collision, and unload should drain from explicit queues.

## Current Architecture

Key files:

- `src/core/world/native_streaming_manager.gd`: per-frame streaming driver.
- `src/core/world/cell_manager.gd`: async cell requests, payloads, model loads,
  instantiation queue, collision build.
- `src/core/world/cell_payload.gd`: request-scoped prepared cell payload.
- `src/core/world/model_loader.gd`: prebaked `PackedScene` cache and threaded
  ResourceLoader path.
- `src/core/world/reference_instantiator.gd`: routing and object creation.
- `src/core/world/static_object_renderer.gd`: server-direct static renderer.
- `src/core/world/prototype_registry.gd`: world-scoped per-prototype batches.
- `src/core/world/prototype_batch.gd`: `MultiMesh` batch buffer ownership.
- `src/core/world/cell_static_collision.gd`: per-cell static collision lane.
- `src/core/world/streaming_config.gd`: budgets and safety flags.
- `src/tools/streaming_benchmark.gd`, `src/tools/benchmark_hud.gd`: telemetry.

Useful diagnostics:

- `[inst-spike ...]`
- `[ml-spike ...]`
- `[inst-breakdown ...]`
- `Frame overrun`
- `stream_proc`
- `heartbeat sec=`
- `phase_static_cull_us`
- CSV route columns: `inst_door_us`, `inst_light_us`,
  `inst_light_modelload_us`, `inst_container_us`, `inst_activator_us`,
  `inst_static_us`

## Current Status

Completed:

- Stabilized static `MultiMesh` upload by using `MultiMesh.set_buffer()`.
- Disabled native C# static cull packing by default.
- Added clearer `[inst-spike]` route buckets for `light` and `actor`.
- Fixed light model-load timing attribution.
- Tightened attach/static-cull budgets:
  - `CHILD_ATTACH_MAX_PER_FRAME = 4`
  - `STATIC_CULL_BATCH_BUDGET_PER_FRAME = 8`
- Added request-scoped `CellPayload`.
- Payload V0 contains:
  - grid
  - state
  - static refs grouped by exact model/cache key
  - precomputed static world transforms
  - expected static counts by key
  - interactive refs
  - light refs
  - pinned `PackedScene` refs
  - stats
- Added cell/request states:
  `QueuedData`, `PreparingPayload`, `PayloadReady`, `VisualPublishing`,
  `VisualReady`, `PhysicsPublishing`, `Active`, `Unloading`.
- Added `InstantiationEntry.cache_item_id` so queued refs remember the exact
  cache key used by their publish path.
- Changed request `pending_disk_loads` from `model_path -> refs` to exact
  `cache_key -> refs`.
- Added `ModelLoader.put_cached_packed_scene()` so payload-pinned scenes can be
  re-promoted if LRU evicts them before visual publish.
- Added a zero-visible guard in `PrototypeBatch.cull_and_upload()` so empty
  prepared batches do not call `MultiMesh.set_buffer()`.
- Added safe static reserve APIs:
  - `PrototypeBatch.reserve_capacity(min_capacity)`
  - `PrototypeRegistry.reserve_batches(sub_meshes, expected_count)`
  - `StaticObjectRenderer.reserve_batches_for_type(type_name, expected_count)`
- Static prepare now feeds reserve from `CellPayload.static_expected_counts`.
- Cold reserve uses the expected count for initial batch capacity instead of
  blindly creating the default-size batch.
- Added boot-time static renderer warmup hooks:
  - `StaticObjectRenderer.warmup_static_batch_pipeline()`
  - `NativeStreamingManager.warmup_static_renderer_boot()`
  - `CellManager.warmup_static_batches_for_cell_ring()`
- `_init_async()` now runs static warmup before camera tracking starts, while
  the first loading UI is still visible.

Important current flags:

- `StreamingConfig.STATIC_CULL_NATIVE_ENABLED = false`
- `StreamingConfig.DEBUG_DISABLE_PHASE_F_PREREG = true`
- `StreamingConfig.STATIC_PREPARE_CREATE_BATCHES = false`

## Best Known Benchmark Facts

Best completed Phase 1 no-collision run:

```powershell
& 'D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe' --path . -- --bench-auto=near_streaming_phase1_budget_no_collision_2026_04_28 --start-cell=-3,-2 --near-only --disable-cell-static-collision
```

Results:

- avg FPS: `209.2`
- avg frame: `4.78 ms`
- p95: `6.14 ms`
- p99: `8.06 ms`
- p99.9: `29.64 ms`
- max: `62.45 ms`
- frames over `16.67 ms`: `35 / 17801`
- frames over `33.33 ms`: `14 / 17801`
- `phase_static_cull_us` max: `4114 us`

Best completed Phase 1 collision-enabled run:

```powershell
& 'D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe' --path . -- --bench-auto=near_streaming_phase1_budget_baseline_2026_04_28 --start-cell=-3,-2 --near-only
```

Results:

- avg FPS: `194.6`
- avg frame: `5.14 ms`
- p95: `6.70 ms`
- p99: `9.23 ms`
- p99.9: `36.27 ms`
- max: `70.15 ms`
- frames over `16.67 ms`: `66 / 16560`
- frames over `33.33 ms`: `24 / 16560`
- `phase_static_cull_us` max: `3946 us`

After the payload slice:

- Parser smoke passed.
- .NET build passed.
- No-collision AutoBench did not reach flyby summary output.
- Turning on `STATIC_PREPARE_CREATE_BATCHES=true` reproduced the
  `PrototypeBatch.cull_and_upload()` / `MultiMesh.set_buffer()` crash class, so
  it was restored to `false`.
- Latest useful log signal:
  `[inst-spike 118.4ms] ... static=113.1/1 ... sadd=113.1`

After Phase 3 reserve patch:

```powershell
& 'D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe' --path . -- --bench-auto=near_streaming_sadd_reserve_small_no_collision_2026_04_28_codex --start-cell=-3,-2 --near-only --disable-cell-static-collision
```

Results:

- avg FPS: `239.4`
- avg frame: `4.18 ms`
- p95: `5.37 ms`
- p99: `9.20 ms`
- p99.9: `26.71 ms`
- max: `77.04 ms`
- frames over `16.67 ms`: `39 / 20369`
- max `sadd` in `[inst-spike]`: `3.8 ms`
- Important new owner:
  `[static-prepare-spike 114.3ms] ... batch=114.0/1 type=terrain_rock_rm_17.nif`

After boot static warmup experiment:

```powershell
& 'D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe' --path . -- --bench-auto=near_streaming_boot_ring_static_warmup_no_collision_2026_04_28_codex --start-cell=-3,-2 --near-only --disable-cell-static-collision
```

Notes:

- User had another game running during this benchmark, so FPS/p99 are not a
  clean comparison point. Use the timing attribution, not aggregate FPS.
- Dummy `MultiMesh`/RS warmup was cheap and did not solve the real spike:
  `[static-warmup] boot batch pipeline create=0.3ms total=0.4ms`.
- Real startup-ring prototype prewarm moved some cold costs into loading:
  `[static-boot-prewarm-spike 151.1ms] type=ex_hlaalu_b_23.nif count=1`,
  `[static-boot-prewarm-spike 145.9ms] type=terrain_rock_ai_12.nif count=1`,
  `[static-boot-prewarm-spike 144.3ms] type=flora_bush_01.nif count=7`.
- The first scan-order implementation only processed `20/160` candidates and
  still missed an expensive runtime type:
  `[static-prepare-spike 163.7ms] ... type=terrain_rocks_wg_02.nif`.
- After that run, candidate ordering was changed to prioritize
  `terrain_rock*`, `terrain_rocks*`, `flora_*`, then `ex_*`, with count as a
  secondary weight. This passed parser smoke and .NET build.

After prioritized boot static prewarm verification:

```powershell
& 'D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe' --path . -- --bench-auto=near_streaming_boot_ring_static_warmup_verify --start-cell=-3,-2 --near-only --disable-cell-static-collision
```

Results:

- avg FPS: `225.4`
- avg frame: `4.44 ms`
- p95: `6.13 ms`
- p99: `10.13 ms`
- p99.9: `25.89 ms`
- max: `70.04 ms`
- frames over `16.67 ms`: `40 / 19178`
- frames over `33.33 ms`: `9 / 19178`
- boot prewarm:
  `[static-boot-prewarm] center=(-3, -2) radius=1 processed=20/160 registered=20 reserved=20 failed=0 total=15625.6ms`
- largest boot prewarm spike:
  `[static-boot-prewarm-spike 236.4ms] type=terrain_rock_wg_14.nif count=49`
- runtime `[static-prepare-spike]`: none observed
- max runtime `sprep`: `0.6 ms`
- max runtime `sadd`: `3.6 ms`
- `phase_static_cull_us` max: `5083 us`
- `inst_static_us` max: `6509 us`
- Godot crashed with signal 11 after AutoBench flushed
  `bench_tiers.json`, flyby CSV/summary, `bench_teleport.json`, and
  `bench_hlod_off.json`; data appears usable, but shutdown crash remains.

High-altitude sustained-speed stress probe:

```powershell
& 'D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe' --path . -- --bench-stress=stress_100m_100mps_no_collision_2026_04_28 --start-cell=-3,-2 --near-only --disable-cell-static-collision --stress-altitude=100 --stress-speed=100 --stress-duration=60 --stress-direction=east
```

Notes:

- Added `src/tools/streaming_stress_runner.gd` and `--bench-stress=<stamp>`
  CLI wiring for direct sustained traversal tests.
- This route flies east from Balmora at `100 m/s` (`360 km/h`) and `100m`
  altitude for `60s`.
- It crossed `51` cell boundaries.
- Summary:
  - avg FPS: `243.8`
  - avg frame: `4.10 ms`
  - p95: `8.72 ms`
  - p99: `10.31 ms`
  - p99.9: `39.06 ms`
  - max: `97.25 ms`
  - frames over `16.67 ms`: `48 / 14626`
  - frames over `33.33 ms`: `21 / 14626`
  - frames over `50 ms`: `9 / 14626`
  - rendered objects stayed nonzero: min `883`, max `1837`
- Cell-transition stutter:
  - `12 / 51` transitions had at least one post-transition frame over
    `33.33ms`.
  - The first populated half is the real signal: `11 / 26` early transitions
    had post-transition `>33.33ms`; only `1 / 25` late transitions did.
  - Worst transition window: `(12, -2) -> (13, -2)`, post-transition max
    `90.62ms`, post-window avg `102.7 FPS`.
  - Other bad early transitions: `(-2, -2) -> (-1, -2)` max `88.13ms`,
    `(9, -2) -> (10, -2)` max `83.01ms`.
- Route caveat: after roughly the midpoint, the eastward path appears to leave
  dense loaded-cell coverage (`loaded_cells=0` in later top frames) while still
  rendering terrain/static remnants. Treat this as a valid high-speed smoke
  test, not the final populated-world stress route.
- Top stutter frames were not static `sprep`/`sadd` cliffs. They were mixed
  streaming/queue/instantiate and likely renderer/terrain stalls; some worst
  frame times had little measured streaming work, so the next stress pass needs
  better GPU/terrain/visibility attribution.

Stress rerun caveat:

- A follow-up watch run was attempted, but it was not a trustworthy route:
  the camera started near the terrain edge and moved outward. The process did
  not flush stress summary files.
- The last captured log showed `USER_QUIT` followed by signal 11 during
  shutdown, so that instance appears to be teardown crash after window close,
  not a proven in-flight traversal crash.
- The same run also showed the loading problem clearly:
  boot static prewarm took `13551.0ms`, the loading gate timed out at `30.0s`,
  and the crash report still had `Queue: 455 pending`.
- Loading time is now a P0. Do not keep blindly moving runtime cliffs into boot;
  the startup path needs a hard time budget and better prioritization.

Interpretation:

- Payload/resource pinning has started attacking `ml`.
- Phase 3 reserve moved first static batch/slot allocation out of visual
  publish. The old `sadd=113-136 ms` visual-publish cliff is gone.
- Prioritized startup-ring prewarm removed the runtime static-prepare cliff in
  the clean no-collision verification run: no `[static-prepare-spike]`,
  max `sprep=0.6 ms`, max `sadd=3.6 ms`.
- Boot warmup must use real prototypes. A dummy MultiMesh does not warm the
  expensive path. Prioritized startup-ring static prototype prewarm is now
  effective enough for the current start cell, but it costs about `15.6s` of
  loading time for `20/160` candidates.
- Collision remains a contributor in collision-enabled runs, but no-collision
  still has a long tail. In the clean verification run, frames over `33.33ms`
  were dominated by interactive `ml`, `node`, `light`, attach/add-child work,
  and general loop time, not static `sprep`/`sadd`.
- The first high-altitude `100 m/s` stress route proves there are still visible
  stutter-class frames during aggressive cell transitions. It also shows the
  stress route itself must be chosen carefully; a straight east Balmora route
  becomes sparse/empty after the first populated stretch.
- Startup is now too slow: real prototype prewarm can cost `13-16s`, the boot
  loading gate can still hit its `30s` timeout, and queued work may remain. The
  next work should reduce startup wall time, not simply add more warmup.

## Active Plan

### Phase 2 - CellPayload V0

Status: partially complete.

Done:

- Request-scoped payload exists.
- Payload pins exact `PackedScene` resources.
- Static, light, and interactive refs are split.
- Static transforms and expected counts exist.
- Missing resources remain incremental; no whole-cell hidden gate was added.

Still needed:

- Add shape-pack paths or collision prep handles to payload.
- Validate static counts and visible object counts against old path.
- Move more static publish work to payload-fed queues so visual publish no
  longer performs broad rediscovery/classification.

### Phase 3 - Static Batch Reserve / Preallocation

Status: partially complete.

Goal: remove first `sadd` allocation spikes from visual publish.

Done:

- Added explicit batch reserve/grow API:
  - `StaticObjectRenderer.reserve_batches_for_type(type_name, expected_count)`
  - `PrototypeRegistry.reserve_batches(sub_meshes, expected_count)`
  - `PrototypeBatch.reserve_capacity(min_capacity)`
- Fed it from `CellPayload.static_expected_counts`.
- Do not call `MultiMesh.set_buffer()` during reserve.
- Visual publish no longer owns the 100 ms `sadd` cliff.
- Added first-loading-screen warmup for the static batch path.
- Added startup-cell-ring static prototype prewarm, currently prioritized toward
  terrain rocks, flora, and exterior architecture.
- Clean no-collision verification after priority ordering had no runtime
  `[static-prepare-spike]`; max `sprep=0.6 ms`, max `sadd=3.6 ms`.

Still needed:

- Decide if loading-time cost is acceptable. The clean prioritized run spent
  `15625.6ms` to prewarm `20/160` startup-ring candidates.
- Consider whether `BATCH_PREWARM_COUNT=20` is route-specific enough or whether
  additional starts need a slightly larger cap/route-specific candidate policy.
- Add static prepare telemetry that separates:
  registration,
  `MultiMesh.new` / `instance_count`,
  RS instance create/base/scenario,
  array reserve,
  and reserve grow.
- Run reserve under `STATIC_PREPARE_BUDGET_MS`, one/few types per frame.
- Do not force first upload on the same frame as batch creation/reserve.
- Keep `STATIC_PREPARE_CREATE_BATCHES=false` until this is proven stable.

Acceptance:

- Top-frame logs no longer contain first-batch `sadd` spikes. Done for the
  no-collision runs; max observed `sadd` is now `3.6-3.8 ms`.
- Static prepare can spend small time over multiple frames. Done for the clean
  prioritized no-collision run; max observed runtime `sprep` was `0.6 ms`.
- Visual publish remains bounded. Mostly true for the `sadd` class; remaining
  publish spikes are mostly `ml`, `node`, `light`, attach, and small `sadd`.
- No `MultiMesh.set_buffer()` crash during flyby startup.

### Phase 4 - Budgeted Static Visual Publish

Status: pending.

Goal: static publication becomes a small server-side operation fed by
`CellPayload`, not discovery/load/register work.

Tasks:

- Add static visual publish queue fed by `CellPayload`.
- Publish static instances under count/time budget independent of interactive
  spawn and collision.
- Treat dirty `MultiMesh.set_buffer()` upload as a separate budgeted
  continuation.
- Ensure unload does not immediately force a huge cull/upload rebuild.

### Phase 5 - Collision Lane

Status: pending.

Goal: collision may lag visual activation briefly, but must not hitch visuals.

Tasks:

- Verify `.shapes.res` sidecars are complete for benchmark-area statics.
- Measure `ConcavePolygonShape3D.set_faces()` per cell.
- Finalize/publish collision only when visual/static queues are idle and within
  a collision-specific budget.
- Consider prebaked cell-level collision resources.
- Keep `--disable-cell-static-collision` as an ablation flag.

### Phase 6 - Sparse Interactive Node Lane

Status: pending.

Goal: interactives use scene nodes only when needed and under explicit budgets.

Tasks:

- Split interactive create and attach telemetry/budgets further.
- Keep bounded attach queue; do not reintroduce bulk `call_deferred("add_child")`.
- Spawn containers, activators, and doors by priority/proximity where possible.
- Keep lights server-direct when behavior allows.

### Phase 7 - Boundary / Unload Amortization

Status: pending.

Goal: boundary crossing changes desired state only.

Tasks:

- Split `_update_loaded_cells()` into cheap desired-state calculation plus
  budgeted queues.
- Budget old-cell unload/free work separately.
- Amortize distant-light scans, proximity scans, and preload bookkeeping.

### Phase 8 - Verification

Status: pending.

Routes to add/run later:

- Standard NEAR-only route from `--start-cell=-3,-2`.
- No-collision ablation.
- Collision-enabled comparison.
- High-altitude fast traversal.
- Diagonal cell-boundary traversal.
- Teleport scenario.

## Verification Commands

Parser/startup smoke:

```powershell
& 'D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe' --headless --path . --quit
```

.NET build:

```powershell
dotnet build Godotwind.sln --configfile NuGet.Config
```

Primary no-collision benchmark:

```powershell
& 'D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe' --path . -- --bench-auto=near_streaming_<stamp> --start-cell=-3,-2 --near-only --disable-cell-static-collision
```

Primary collision-enabled benchmark:

```powershell
& 'D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe' --path . -- --bench-auto=near_streaming_<stamp> --start-cell=-3,-2 --near-only
```

## Success Gates

- No visible object starvation or late whole-cell pop-in.
- No normal flyby frames above `33.33 ms`.
- Stretch: no normal flyby frames above `16.67 ms`.
- `p99.9 <= 16.67 ms`, or a clear measured culprit and next task.
- Teleport scenario no longer reports single-digit `fps_min`.
- Top-20 worst frames are classifiable from CSV/logs.
- Disabling cell static collision affects correctness/physics, not visual
  smoothness.
- No crash before benchmark data flush.

## What Not To Do Next

- Do not re-enable native C# static cull packing by default.
- Do not re-enable Phase F off-thread prototype prereg by default.
- Do not turn on `STATIC_PREPARE_CREATE_BATCHES` as-is.
- Do not solve `sadd` by hiding whole cells behind a `DataReady` gate.
- Do not move mass static rendering back to scene-tree `Node3D`s.
- Do not add more broad budget tweaks before splitting reserve, publish, upload,
  collision, and interactive attach lanes.

## Short Next Step

Next: attack the remaining no-collision tail now that prioritized boot static
prewarm has removed the runtime `sprep` cliff for the current start cell.

Target shape:

1. Add finer telemetry inside `PrototypeBatch._init()` /
   `PrototypeRegistry.get_or_create_batch()` for `MultiMesh` creation,
   `instance_count`, RS instance setup, material override, and storage resize.
2. Keep reserve/upload separate: no `MultiMesh.set_buffer()` during reserve.
3. Split and budget the remaining interactive runtime spikes, currently
   dominated by `ml`, `node`, `light`, attach/add-child, and loop time.
4. Investigate the post-AutoBench signal 11 shutdown crash; benchmark data
   flushed successfully, but clean exit is still a success-gate risk.
5. Reduce loading time as a P0:
   keep real prewarm targeted, cap boot work by wall-clock, skip low-impact
   candidates, and let noncritical static/interactives continue after first
   playable frame under runtime budgets.
6. Add a populated high-speed route variant for `--bench-stress` (loop, diagonal,
   or waypoint chain) so the full duration stays over dense cells instead of
   flying out into sparse/empty coverage.
7. Re-run no-collision and collision-enabled comparisons after the interactive
   lane changes.
