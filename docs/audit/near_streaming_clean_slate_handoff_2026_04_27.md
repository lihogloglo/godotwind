# NEAR Streaming Clean Slate Handoff

Date: 2026-04-27

## Session Update - 2026-04-28 Route Diagnostics / Static Renderer Follow-up

Added route-level diagnostics inside `process_async_instantiation` and
`ReferenceInstantiator` so `[inst-spike]` now splits the broad instantiate
bucket into:

- `static`, `node`, `wstatic`, `wnode`, `defer`, `skip`, `other`
- `ml` = model-loader / prototype instantiate time
- `sreg` = static renderer `register_from_prototype`
- `sadd` = static renderer `add_instance` / registry publish
- `wp` = worker tasks still pending

Short route probes with cell static collision disabled showed:

- Remaining early startup hitches are overwhelmingly static-renderer work, not
  interactive Node3D creation.
- The biggest first-batch spikes are in `sadd`, e.g. one static add taking
  roughly `100-129 ms`. This points at first `PrototypeBatch` / `MultiMesh`
  creation/allocation, not Jolt.
- Repeated post-first-batch hitches are mostly `ml`, usually `9-40 ms`, which
  is synchronous cold prototype load/instantiate for static registration.
- `sreg` itself is tiny (`~0.1-0.3 ms`), so the subtree walk / type registration
  is not the expensive part.

Code change kept:

- `PrototypeRegistry.initial_batch_capacity` now uses
  `StreamingConfig.INITIAL_BATCH_CAPACITY` instead of a stale hard-coded `1024`
  default. The config value is currently `256`.

Code change tried and reverted:

- A main-thread-safe replacement for Phase F was tested: request cold static
  prototypes through `ModelLoader.request_model_async(..., false)`, requeue the
  ref, then register later from memory cache, with a one-cold-register-per-slice
  cap.
- Full AutoBench with that experiment completed and wrote data, then crashed on
  quit:
  - `user://benchmark_results/autobench_near_streaming_after_static_warm_2026_04_28/`
  - `user://benchmark_results/benchmark_2026-04-28_09-16-40.csv`
  - `user://benchmark_results/summary_2026-04-28_09-16-40.json`
- Flyby summary for the experiment:
  - avg FPS: `202.3`
  - avg frame: `4.94 ms`
  - p95: `6.21 ms`
  - p99: `13.47 ms`
  - p99.9: `46.60 ms`
  - max: `84.09 ms`
  - frames over 16.67 ms: `153 / 17208`
- This was worse than the Phase-F-disabled baseline (`p99.9 38.94 ms`, avg
  `211.5 FPS`), so the async/requeue behavior was removed. Do not revive that
  exact approach without a better queue design.

Current interpretation:

- The pre-data crash is Phase F off-thread prototype prereg. Keep it disabled by
  default.
- The remaining startup/runtime hitch is not simply Jolt. Jolt/cell collision is
  a contributor, but static renderer cold prototype load and first MultiMesh
  batch allocation remain significant.
- Next productive fix is probably a real static-prototype prepare phase or
  prebuilt static payloads, not ad-hoc requeueing from inside the instantiate
  drain.

## Session Update - 2026-04-28 Fresh Benchmark / Crash Triage

Current git HEAD at test time: `7b23780` before the local stability patch.

The plain fresh run:

```powershell
& 'D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe' --path . -- --bench-auto=near_streaming_current_2026_04_28_fresh --start-cell=-3,-2 --near-only
```

crashed before writing benchmark data. Windows reported native access violation
`0xc0000005`; Godot log showed AutoBench had started, and the crash breadcrumb
ended at:

```text
instantiate_return :: C:/Users/metzo/Documents/Godotwind/cache/models/f_terrain_rock_bc_17_nif.res
```

A crash ablation with Phase F prototype pre-registration disabled completed the
full AutoBench sequence and wrote data:

```powershell
& 'D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe' --path . -- --bench-auto=near_streaming_crash_ablate_no_phase_f --start-cell=-3,-2 --near-only --disable-phase-f-prereg
```

Output:

- `user://benchmark_results/autobench_near_streaming_crash_ablate_no_phase_f/`
- `user://benchmark_results/benchmark_2026-04-28_08-26-16.csv`
- `user://benchmark_results/summary_2026-04-28_08-26-17.json`

Flyby summary:

- avg FPS: `211.5`
- avg frame: `4.73 ms`
- p95: `6.00 ms`
- p99: `10.95 ms`
- p99.9: `38.94 ms`
- max: `92.30 ms`
- frames over 16.67 ms: `146 / 17997`

AutoBench scenario summaries:

- `bench_tiers`: avg `222.1 FPS`, min `195 FPS`, max `234 FPS`
- `bench_teleport`: avg `206.9 FPS`, min `8 FPS`, max `240 FPS`
- `bench_hlod_off`: avg `214.5 FPS`, min `194 FPS`, max `223 FPS`

Important nuance: the ablated AutoBench run still crashed on quit after all
JSON/CSV data was flushed. Treat that as a shutdown crash separate from the
pre-benchmark crash.

Code change made after this measurement:

- `StreamingConfig.DEBUG_DISABLE_PHASE_F_PREREG` now defaults to `true`.
- New opt-in flag: `--enable-phase-f-prereg`.

Reason: the current Phase F path instantiates PackedScenes and registers
prototypes off-thread. In this Godot 4.6 setup it is crash-prone enough to block
normal benchmark collection. The stable default should be no Phase F prereg
until a safer payload/prebake-based replacement exists.

Verification after the patch:

- Godot parser/startup smoke passed:
  `D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe --headless --path . --quit`
- `.NET` build passed:
  `dotnet build Godotwind.sln --configfile NuGet.Config`
  Existing nullable warnings remain.
- `git diff --check` passed, with only line-ending warnings.

## Session Update - 2026-04-28 Collision Ablation

Run after Phase F was default-disabled:

```powershell
& 'D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe' --path . -- --bench-auto=near_streaming_no_cell_collision_2026_04_28 --start-cell=-3,-2 --near-only --disable-cell-static-collision
```

Output:

- `user://benchmark_results/autobench_near_streaming_no_cell_collision_2026_04_28/`
- `user://benchmark_results/benchmark_2026-04-28_08-34-53.csv`
- `user://benchmark_results/summary_2026-04-28_08-34-53.json`

Flyby summary:

- avg FPS: `219.9`
- avg frame: `4.55 ms`
- p95: `5.90 ms`
- p99: `10.69 ms`
- p99.9: `33.37 ms`
- max: `80.24 ms`
- frames over 16.67 ms: `140 / 18709`

Compared to the preceding Phase-F-disabled baseline:

- avg FPS improved `211.5 -> 219.9`
- p99.9 improved `38.94 ms -> 33.37 ms`
- max improved `92.30 ms -> 80.24 ms`
- frames over 16.67 ms changed only slightly: `146 -> 140`

Interpretation:

- Collision/Jolt-side cell BVH publish is a real contributor, but not the sole
  hitch source.
- With cell static collision disabled, `[inst-spike] coll=...` disappears, but
  significant `[inst-spike] loop=...` samples remain.
- The current `phase_inst_us` / `instantiate` bucket includes static renderer
  publish / cold prototype work / queue processing, not just visible Node3D
  creation. Since Phase F prereg is disabled for stability, this bucket is now
  the next dominant tail-latency target.
- Next investigation should split `process_async_instantiation` timing further:
  static renderer publish/register vs interactive Node3D creation vs queue scan /
  deferred entries. Do not spend the next pass solely on Jolt.

## Session Update - 2026-04-27 Architecture Pass 1

Implemented after this handoff was created:

- Added a runtime cell-static-collision ablation flag:
  `--disable-cell-static-collision`.
  - Config: `StreamingConfig.DEBUG_DISABLE_CELL_STATIC_COLLISION`.
  - Runtime site: `CellManager._tick_static_collision_build()`.
  - Purpose: quickly prove/disprove whether per-cell
    `ConcavePolygonShape3D.set_faces()` is the dominant boundary spike source.
- Split static renderer cull/upload timing into its own benchmark phase:
  `phase_static_cull_us`.
  - Runtime phase slot: `NativeStreamingManager._last_phase_times[8]`.
  - Benchmark CSV now has 30 columns, with `phase_static_cull_us` appended.
  - HUD now shows `static=...ms` instead of the stale `promo` slot.
- Budgeted world-scoped static MultiMesh cull/upload:
  `StreamingConfig.STATIC_CULL_BATCH_BUDGET_PER_FRAME = 64`.
  - `StaticObjectRenderer.tick_prototype_cull()` now forwards a batch budget.
  - `PrototypeRegistry.tick_cull_if_needed()` can process a dirty pass across
    multiple frames instead of uploading every batch in one frame.
  - Generation tracking was added so new churn during an in-progress cull pass
    does not accidentally mark the registry clean.
- Benchmark summary now records and prints:
  - `p99_9_ms`
  - `frames_over_16_67`
  These are also written to summary JSON.
- Fixed CLI runtime argument parsing in `world_explorer.gd` so flags after
  Godot's `--` separator are seen by the scene:
  `--bench-auto`, `--start-cell`, `--near-only`, `--no-lights`, and ablation
  flags now read from `OS.get_cmdline_args() + OS.get_cmdline_user_args()`.

Verification after the pass:

- Godot parser/startup smoke passed:
  `D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe --headless --path . --quit`
- `.NET` build passed:
  `dotnet build Godotwind.sln --configfile NuGet.Config`
  Existing nullable warnings remain.
- `git diff --check` passed, with only line-ending warnings.

Recommended immediate benchmark launch for this pass:

```powershell
& 'D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe' --path . -- --bench-auto=near_streaming_arch_p1 --start-cell=-3,-2 --near-only
```

For the collision ablation follow-up, run the same command with
`--disable-cell-static-collision` appended and compare `p99_9_ms`,
`frames_over_16_67`, `phase_inst_us`, `[inst-spike] coll=...`, and visible
cell-boundary hitching.

Measured result from the battery run:

- Stamp: `near_streaming_arch_p1_battery`
- Output:
  - `user://benchmark_results/autobench_near_streaming_arch_p1_battery/`
  - `user://benchmark_results/benchmark_2026-04-28_00-03-11.csv`
  - `user://benchmark_results/summary_2026-04-28_00-03-11.json`
- Scripted flyby summary:
  - avg FPS: `174.6`
  - avg frame: `5.73 ms`
  - p95: `7.50 ms`
  - p99: `10.83 ms`
  - p99.9: `47.10 ms`
  - max: `93.53 ms`
  - frames over 16.67 ms: `86 / 14854`
- Per-segment p99 from log:
  - settle `8.7 ms`
  - idle `7.8 ms`
  - walk `9.7 ms`
  - vista `7.7 ms`
  - pan `8.7 ms`
  - run `32.3 ms`
- Streaming phase timing from log:
  - total streaming work avg `0.33 ms`, max `264.50 ms`
  - `static_cull` avg `0.07 ms`, max `13.03 ms`
- AutoBench scenario summaries:
  - `bench_tiers`: avg `416.2 FPS`, min `142 FPS`, max `519 FPS`
  - `bench_teleport`: avg `134.5 FPS`, min `2 FPS`, max `162 FPS`
  - `bench_hlod_off`: avg `176.9 FPS`, min `155 FPS`, max `185 FPS`

Interpretation: performance is much better than the reported 250 -> 25 FPS
cell-boundary collapse. The remaining issue is now tail latency, not average
throughput. The worst run-segment frames still need a top-frames CSV autopsy.
Static cull is improved but still visible in the max. Collision is still
suspect because startup logs show `[inst-spike] coll=...` samples in the
20-40 ms range, though the flyby p99 is now good.

Purpose: give a fresh agent enough context to continue the NEAR streaming
performance investigation without relying on stale plans or memory. The user
wants a fully smooth, fast NEAR-only streaming and rendering path: no spikes at
cell boundaries while flying above terrain at sustained speed. HLOD, LOD,
impostors, and other distant systems are intentionally out of scope for this
phase and are currently disabled when launching the Godotwind scene.

Important: do not trust older docs over code. This repository has been
refactored many times. Treat this document as a current map, but verify every
claim against source before editing.

## User Context

- Target experience: smooth NEAR model streaming and rendering, no cell-boundary
  hitches. Current reported behavior: FPS can drop from about 250 to 25 or lower
  when crossing cell boundaries at sustained flight speed.
- The current scene has HLOD, LODs, impostors, and distant streaming disabled.
  A normal Godotwind launch is intended to show NEAR objects only for this
  investigation.
- The project already has benchmark tooling with a stereotyped camera path.
  Do not spend time inventing a benchmark suite. Use and extend the existing
  tools if needed.
- The project already has a prebaking pipeline that imports Morrowind NIFs to
  Godot `.res` files. It also appears to emit collision shape sidecars
  (`.shapes.res`) to avoid expensive runtime collision extraction. If runtime
  still builds collision data, the first question is why the prebaked data is
  not enough.

## Existing Benchmark Tools

Primary docs:

- `docs/systems/benchmarking.md`
- `docs/plans/benchmark_v2.md`

Relevant source:

- `src/tools/streaming_benchmark.gd`
- `src/tools/benchmark_hud.gd`
- `src/tools/progressive_benchmark.gd`
- `src/tools/auto_bench_runner.gd`
- `src/tools/bench_ladder_runner.gd`
- `tests/benchmark/benchmark_thresholds.gd`

Known benchmark surface from `docs/systems/benchmarking.md`:

- Console command `benchmark` / `bench`: scripted 85s flyby around Seyda Neen.
- Console command `bench_start [label]` and `bench_stop`: manual measurement
  blocks.
- Console command `bench_progressive`: additive subsystem sweep.
- Console command `hud`: live benchmark HUD.
- Output path: `user://benchmark_results/`.
- CSV columns include:
  `frame, time_ms, fps, node_count, draw_calls, rendered_objects, primitives,
  queue_size, loaded_cells, async_requests, cam_x, cam_y, cam_z, memory_static,
  segment, mid_instances, mid_mesh_types, vram_mb, texture_mem_mb,
  promoted_objects, stream_total_ms, phase_unload_us, phase_async_us,
  phase_inst_us, phase_promo_us, phase_coll_us, phase_defer_us,
  phase_queue_us, phase_cellupd_us, phase_static_cull_us`.

For this NEAR-only pass, benchmark success should be judged by frame-time
spikes and percentiles, not average FPS. Averages can hide the exact problem the
user is reporting.

Suggested gate:

- Use the existing flyby/stereotyped route.
- Run with NEAR-only systems active.
- Capture `summary_*.json`, `benchmark_*.csv`, and streaming logs.
- Track max frame time, p99, p99.9 if available, count of frames above 16.67 ms,
  and the worst cell-boundary frames.
- Correlate bad frames with `phase_*_us`, `[inst-spike]`, `[ml-spike]`,
  `_update_loaded_cells`, `stream_proc` profiler dumps, and heartbeat lines.

## Prebake And Collision Context

Relevant source:

- `src/tools/prebaking/model_prebaker.gd`
- `src/tools/prebaking/prebaking_manager.gd`
- `src/tools/prebaking/full_rebake_headless.gd`
- `src/core/world/model_loader.gd`
- `src/core/world/static_shape_pack.gd`
- `src/core/world/static_shape_cache.gd`
- `src/core/world/cell_static_collision.gd`
- `src/core/nif/nif_collision_builder.gd`
- `src/core/nif/collision_shape_library.gd`

Observed code facts:

- `ModelPrebaker` converts unique NIF models to cached Godot resources.
- `model_prebaker.gd` calls `StaticShapePackScript.save_from_node(node,
  base_path)` near its save path. That writes a sidecar at
  `base_path + ".shapes.res"`.
- `model_loader.gd` also has `_save_shape_pack_to_disk(node, base_path)`, which
  delegates to `StaticShapePack.save_from_node`.
- `model_loader.gd::resolve_shape_pack_path(model_path)` derives the sidecar
  path from the prebaked scene path by replacing the scene suffix with
  `.shapes.res`.
- `StaticShapeCache` first checks memory, then tries a prebaked
  `StaticShapePack` sidecar, then has a legacy walker fallback.
- `CellStaticCollision` currently builds one merged cell collision body by
  classifying refs, loading/warming sidecar shapes, transforming triangles in a
  worker, then calling `ConcavePolygonShape3D.set_faces()` on the main thread.

Key implication:

The project already prebakes per-prototype collision shape packs. However, the
runtime still builds a per-cell merged trimesh body, and the final BVH build
still happens on the main thread. This is likely a major remaining source of
cell-boundary spikes.

Current hot line:

```gdscript
# src/core/world/cell_static_collision.gd
var trimesh: ConcavePolygonShape3D = ConcavePolygonShape3D.new()
trimesh.set_faces(payload.vertices)  # the BVH build - main-thread only
```

The clean-slate question is not "can we move more triangle collection to a
worker?" It is: can NEAR visual activation avoid building any new physics BVH at
cell boundary time?

## Godot 4.6 Constraints And Quirks

Primary sources:

- Godot thread-safe APIs:
  https://docs.godotengine.org/en/4.6/tutorials/performance/thread_safe_apis.html
- Godot ResourceLoader:
  https://docs.godotengine.org/en/4.6/classes/class_resourceloader.html
- Godot servers optimization:
  https://docs.godotengine.org/en/4.6/tutorials/performance/using_servers.html
- Godot MultiMesh optimization:
  https://docs.godotengine.org/en/4.6/tutorials/optimization/using_multimesh.html

Important Godot rules summarized:

- The active scene tree is not thread-safe. Do not add/remove children or touch
  active-tree state from workers.
- Creating detached scene chunks off-thread can be acceptable, but multiple
  threads instantiating scenes that share resources can be risky.
- Rendering nodes such as `MeshInstance3D` are not thread-safe to instantiate by
  default. Godot docs say rendering driver thread model must be set to
  `Separate` for rendering-server thread safety, and that mode has known bugs.
- Physics servers are not thread-safe by default unless physics is configured to
  run on a separate thread.
- Server APIs are the intended lower-level route for very large numbers of
  objects, but they shift responsibility to the application.
- `ResourceLoader.load_threaded_request()` is useful, but
  `ResourceLoader.load_threaded_get()` blocks if called before the load status is
  `THREAD_LOAD_LOADED`.
- `load_threaded_request(..., use_sub_threads=true)` can load faster, but Godot
  warns it may affect the main thread and cause slowdowns.
- MultiMesh is the right concept for many identical/similar instances, but
  buffer uploads are still work. A single global batch upload after a large
  amount of churn can still be a frame spike.

Audit note:

No explicit `rendering/driver/thread_model` or physics separate-thread setting
was found in `project.godot` during this pass. Verify again before relying on
off-thread rendering-node instantiation or physics-server calls.

## AAA Streaming Pattern

Useful public references:

- Unreal World Partition:
  https://dev.epicgames.com/documentation/en-us/unreal-engine/world-partition-in-unreal-engine
- Unreal World Partition HLOD:
  https://dev.epicgames.com/documentation/en-us/unreal-engine/world-partition---hierarchical-level-of-detail-in-unreal-engine
- Umbra / Witcher 3 GDC coverage:
  https://www.gamewatcher.com/news/2014-10-04-the-witcher-3-s-use-of-umbra-3-engine-explained-in-gdc-presentation

Pattern to borrow, not copy blindly:

- Worlds are partitioned into cells/sectors/tiles.
- Streaming has states. A cell can be known, loaded, prepared, visible, and
  activated as gameplay. These are not the same state.
- Data is streamed before it is needed, based on player position and velocity.
- Visual statics are not full gameplay actors. They are render payloads,
  batches, or server-side instances.
- Gameplay actors are sparse. Doors, carryables, NPCs, creatures, scripted
  activators, and physics objects become full objects only when needed.
- Heavy render and physics artifacts are prebaked or prepared ahead of
  activation.
- HLOD/impostor/proxy systems replace distant actors, but this project is
  currently focusing on NEAR only.

For this project, the equivalent should be:

- `CellRecord` / ESM refs are source data.
- Prebaked `.res` and `.shapes.res` are resource data.
- A future `CellPayload` should be prepared data.
- The active scene should receive only tiny, budgeted publish operations.
- Visual NEAR statics should be server/MultiMesh data, not thousands of
  `Node3D`s.
- Interactive NEAR objects should be lazy, sparse `Node3D`s.

## Current Runtime Architecture, As Observed

Do not assume this is all correct. It is what the source currently appears to
do.

Main entry:

- `src/core/world/native_streaming_manager.gd` drives streaming per frame.
- `src/core/world/cell_manager.gd` owns cell requests, model loads,
  instantiation queue, and static collision build.
- `src/core/world/reference_instantiator.gd` classifies and instantiates refs.
- `src/core/world/model_loader.gd` owns prebaked model cache and threaded
  ResourceLoader calls.
- `src/core/world/static_object_renderer.gd` owns server-direct statics.
- `src/core/world/prototype_registry.gd` and `prototype_batch.gd` own
  world-scoped MultiMesh batches.
- `src/core/world/cell_preloader.gd` predicts/warm-loads cells ahead of travel.

Per-frame streaming driver:

- `NativeStreamingManager._process()` updates camera state and cell state.
- On cell change, `_update_loaded_cells()` computes desired cells, unloads old
  cells, queues new cells, scans distant lights, and requeues proximity-deferred
  interactives.
- Every frame while NEAR is visible, it calls:
  `_cell_manager.process_async_instantiation(...)`.
- After instantiation, it calls `_static_renderer.tick_prototype_cull(...)`.

Relevant code sites:

- `native_streaming_manager.gd::_process`, around the phase timers and call to
  `process_async_instantiation`.
- `native_streaming_manager.gd::_update_loaded_cells`, around cell diff/unload/
  queue/light/proximity work.
- `cell_manager.gd::process_async_instantiation`.
- `static_object_renderer.gd::tick_prototype_cull`.
- `prototype_registry.gd::tick_cull_if_needed`.
- `prototype_batch.gd::cull_and_upload`.

## Current Positive Architecture

The code is not hopeless. Several correct pieces already exist:

- Prebaked model cache exists. Runtime mode skips conversion and expects models
  to be prebaked.
- Async ResourceLoader pipeline exists in `ModelLoader`.
- `CellPreloader` predicts future cells from camera velocity and warms
  ResourceLoader cache.
- Static rendering can route through `StaticObjectRenderer` instead of creating
  `Node3D` trees for every static ref.
- `PrototypeRegistry` uses one MultiMesh batch per prototype/material grouping
  across loaded cells rather than per-cell batches.
- Static prototype pre-registration exists in `ReferenceInstantiator` and uses
  `WorkerThreadPool`.
- Off-thread precompute exists for static instance transforms.
- Off-thread `PackedScene.instantiate` exists for some non-static Node3D cases.
- Per-cell static collision uses worker-side triangle collection and
  server-direct `PhysicsServer3D` body registration.
- Budgeted unload exists for scene children and server-renderer instances.
- Diagnostics exist: `[inst-spike]`, `[ml-spike]`, `stream_proc`, heartbeat,
  per-type instantiate breakdown, benchmark CSV phase columns.

## Current Negative Architecture

The code is currently a mixture of several streaming eras:

- Old synchronous cell load path still exists in `CellManager._instantiate_cell`.
- Old per-cell MultiMesh helper path still exists near the top of
  `cell_manager.gd`.
- New server-direct statics coexist with old node-heavy and sync fallbacks.
- `process_async_instantiation` handles disk loads, conversions, pool prewarm,
  collision build, worker dispatch/drain, static publish, interactive publish,
  request finalization, and child attach in one call.
- Cell-boundary `_update_loaded_cells()` still stacks many operations on the
  boundary frame.
- Some comments say "NEAR only" while `streaming_config.gd` still contains
  comments about FULL_AAA. Treat comments as history unless code proves them.

This makes it difficult to answer "what happens when I cross a cell boundary?"
without tracing the live path.

## Important Bug Found In This Pass

This pass found and fixed/observed a serious bug in the async disk-load
callback path:

- `ModelLoader.request_model_async()` used to instantiate a fresh `Node3D` per
  waiting callback when an async load completed.
- The `CellManager` callback ignores the `model: Node3D` argument and only uses
  the notification to queue refs for later instantiation.
- Therefore the loader was creating throwaway scene instances on the main thread
  before the real instantiation queue ran.

Current code now supports:

```gdscript
func request_model_async(
	model_path: String,
	item_id: String = "",
	callback: Callable = Callable(),
	instantiate_for_callback: bool = true
) -> bool:
```

And `CellManager` calls it like:

```gdscript
_model_loader.request_model_async(model_path, item_id, callback, false)
```

This preserves old API behavior by default but lets `CellManager` request a
pure notification without creating a throwaway instance.

This was a real spike source, but it is almost certainly not the only problem.

## Primary Remaining Spike Suspects

### P0: Runtime per-cell collision BVH build

Source:

- `cell_manager.gd::process_async_instantiation` calls
  `_tick_static_collision_build()` before the budget clock.
- `cell_static_collision.gd::finalize_body()` calls
  `ConcavePolygonShape3D.set_faces(payload.vertices)` on the main thread.

Risk:

- Even if triangle gathering is worker-side, `set_faces()` can build heavy
  acceleration data synchronously.
- This can land exactly when a cell becomes relevant.
- The code comments already describe this as the BVH build.

Hypothesis:

- If `[inst-spike] coll=...` is non-trivial on boundary frames, this is a main
  offender.

Clean-slate direction:

- Do not build visual-cell collision on visual-cell activation.
- Prefer prebaked cell collision resources, or a smaller physics bubble around
  the player, or delayed/budgeted collision activation independent of visual
  streaming.

### P0: Off-thread rendering-node instantiation safety

Source:

- `reference_instantiator.gd::_worker_instantiate()`

Risk:

- It calls `packed_scene.instantiate(...)` off-thread and mutates a detached
  `Node3D` tree.
- Godot docs allow detached scene creation in limited cases, but warn about
  rendering nodes and shared resources unless rendering thread model is set
  appropriately.
- No explicit `rendering/driver/thread_model=Separate` was found in
  `project.godot`.

Hypothesis:

- This may improve average throughput but risk stalls, synchronization, or
  instability depending on resources.

Clean-slate direction:

- For true statics, do not instantiate render scenes at runtime. Extract static
  render payloads during prebake.
- For interactives, limit `Node3D` instantiation to a tiny budget and consider
  object pools or main-thread-only creation with fewer objects.

### P1: Boundary frame does too much management work

Source:

- `native_streaming_manager.gd::_update_loaded_cells()`

Work currently stacked there:

- Desired-cell calculation.
- Reclaim unloading cells.
- Unload too-far cells.
- Clear/rebuild pending load queue.
- Distant light scan.
- Proximity-deferred interactive scan.
- Impostor update scheduling, even if distant systems are disabled elsewhere.

Risk:

- A cell boundary should mostly enqueue state changes. This function still does
  several O(cells/refs) tasks on the boundary frame.

Clean-slate direction:

- Split boundary detection from work execution.
- Boundary frame should enqueue cell-state transitions only.
- All scanning should be budgeted or amortized.

### P1: Static MultiMesh cull/upload after churn

Source:

- `native_streaming_manager.gd` calls `_static_renderer.tick_prototype_cull`
  every frame.
- `PrototypeRegistry.tick_cull_if_needed()` runs if dirty or camera moved past a
  hysteresis distance.
- `PrototypeBatch.cull_and_upload()` can walk slots and upload buffers.

Risk:

- Adding/removing lots of static instances marks registry dirty.
- The next cull pass can do a large amount of CPU work and a large
  `RenderingServer.multimesh_set_buffer` upload.
- Even if C# culling is fast, buffer upload is still main/render-thread work.

Clean-slate direction:

- Budget dirty batch uploads.
- Track changed batches and process a limited number per frame.
- Pre-size batches to avoid capacity growth during flight.
- Treat upload cost as part of streaming budget, not an unbudgeted afterthought.

### P1: `add_child` deferral can move spikes, not remove them

Source:

- `cell_manager.gd::process_async_instantiation`, `pending_children` batch.

Current behavior:

- If more than 20 children are pending, it calls `parent.call_deferred("add_child",
  child)` for all of them.

Risk:

- Deferring all children can push a burst to idle/deferred processing rather than
  budget it.
- If many interactives become visible at once, the scene tree still receives a
  burst.

Clean-slate direction:

- Interactive `Node3D` attach should have an explicit per-frame count/time
  budget and should not be tied to full cell activation.

### P1: Sync fallback paths still exist

Source:

- `cell_manager.gd::_instantiate_cell()`
- `native_streaming_manager.gd::_load_cell_sync()`

Risk:

- Even if not used in normal flight, sync paths are dangerous fallbacks.
- They also confuse future agents and make it easy to reintroduce blocking
  behavior.

Clean-slate direction:

- Quarantine sync cell loading as editor/debug only.
- Runtime NEAR streaming should have one path.

## Architecture Target For NEAR V1

The clean target is a small state machine with hard budgets.

### Cell States

Use distinct states. Names are suggestions:

- `Unknown`: no work done.
- `QueuedData`: cell selected for future loading.
- `DataLoading`: resource loads/metadata payload creation in progress.
- `DataReady`: all data needed for visual activation is in memory.
- `VisualPublishing`: render payloads are being published under a budget.
- `VisualReady`: cell is visible/rendered.
- `PhysicsPublishing`: collision/interactives are being activated under a
  separate budget.
- `Active`: visual plus local gameplay pieces ready.
- `Unloading`: hide/free work is budgeted.

Cell boundary crossing should only change desired states. It should not perform
heavy work.

### CellPayload

Create a prepared payload type, probably a `RefCounted`, built before activation:

```gdscript
class CellPayload:
	extends RefCounted
	var grid: Vector2i
	var static_instances: Array        # precomputed renderer add payloads
	var interactive_refs: Array        # sparse refs for Node3D activation
	var light_payloads: Array
	var collision_payload: Resource    # ideally prebaked, not built on boundary
	var resource_refs: Array[Resource] # keeps meshes/materials/scenes alive
	var stats: Dictionary
```

The exact schema should follow existing code, but the key principle is that the
main thread should not rediscover or reclassify the cell during activation.

### Runtime Budget Domains

Do not use one giant "instantiate" budget for everything. Split budgets:

- Data completion/polling.
- Static renderer publish.
- MultiMesh buffer upload.
- Interactive `Node3D` create/attach.
- Collision/physics publish.
- Unload/hide/free.

Each budget should be visible in benchmark CSV or streaming logs.

### Static Objects

Most NEAR visual objects should be statics:

- Render through `StaticObjectRenderer` / `PrototypeRegistry`.
- No `Node3D`.
- No per-object `StaticBody3D`.
- No per-object `CollisionShape3D`.
- Per-object metadata only if needed for promotion/interaction.

### Interactive Objects

Only these should become `Node3D`s:

- Doors with teleport/interact behavior.
- Carryables and pick-ups.
- NPCs and creatures.
- Activators and scripted objects.
- Animated objects that cannot be batched.
- Lights, unless moved to server-direct light payloads.

They should spawn by proximity/visibility need, not by cell membership alone.

### Collision

Preferred clean solution:

- Use prebaked collision sidecars as the source of truth.
- Move any remaining expensive cell-level collision assembly to prebake if
  possible.
- Runtime activation should attach an already-built resource or a small set of
  prepared shapes.

Fallback if cell-level runtime collision remains:

- Make collision activation lag visual activation.
- Build/attach under its own budget.
- Do not block visual cell entry on collision.
- Add benchmark flags to disable collision publish and compare.

## Concrete Next Investigation Steps

1. Run the existing benchmark in the current NEAR-only scene.
2. Collect CSV, JSON summary, and log.
3. Identify worst 20 frames.
4. For each worst frame, classify cost:
   - `phase_cellupd_us`
   - `phase_unload_us`
   - `phase_async_us`
   - `phase_inst_us`
   - `phase_queue_us`
   - `phase_static_cull_us`
   - `static_renderer_cull`
   - `[inst-spike] coll/disk/conv/prewarm/loop/addc`
   - `[ml-spike] phaseA/phaseB/dd`
5. Add or use ablation toggles:
   - disable static collision build/finalize
   - disable interactive Node3D spawn
   - disable static renderer publish
   - disable static renderer cull/upload
   - disable cell preloader
   - disable lights
6. Re-run the same path after each ablation. Do not compare average FPS only.
7. If collision ablation removes spikes, redesign collision first.
8. If static renderer cull/upload ablation removes spikes, budget dirty uploads.
9. If interactive spawn ablation removes spikes, make interactives more sparse
   and explicitly attach-budgeted.
10. If cell update dominates, split `_update_loaded_cells()` into budgeted jobs.

## Suggested First Code Changes

### 1. Add a collision activation kill switch

Status: done in Architecture Pass 1 as `--disable-cell-static-collision`.

Reason: validate whether `set_faces()` is causing boundary spikes.

Possible site:

- `StreamingConfig`, similar to `DEBUG_DISABLE_JOLT_ATTACH`.
- `CellManager.process_async_instantiation()` before `_tick_static_collision_build()`.

Expected diagnostic:

- If spikes vanish or `[inst-spike] coll=...` disappears, collision publish is
  the first redesign target.

### 2. Add static renderer cull/upload timing to benchmark data

Status: done in Architecture Pass 1 as `phase_static_cull_us`.

Reason: current benchmark phase columns do not clearly separate static renderer
cull/upload from instantiation and cell update.

Possible site:

- `NativeStreamingManager._process()` already brackets `static_renderer_cull`
  with `StreamingProfiler`; expose that timing in `_last_phase_times` or add a
  new metric read by `StreamingBenchmark`.

### 3. Quarantine sync runtime paths

Reason: reduce cognitive load and accidental fallback.

Possible approach:

- Add comments and assert/log warnings when sync path is used in runtime.
- Avoid deleting first if tests still rely on it.

### 4. Create `CellPayload` behind a flag

Reason: start moving classification out of activation.

Do not refactor everything at once. First payload can wrap existing derived data:

- cell grid
- unique model paths
- static-routed refs
- interactive refs
- shape pack paths

Then gradually move worker precompute into the payload path.

## Existing Diagnostics To Watch

Search strings:

- `[inst-spike`
- `[ml-spike`
- `[inst-breakdown`
- `Frame overrun`
- `stream_proc`
- `_update_loaded_cells:`
- `heartbeat sec=`
- `Deferred impostor update`
- `[T.2-W1+W2]`
- `CellStaticCollision`
- `PipelineCompileMonitor`

Important interpretation:

- `proc_ms` vs frame time helps distinguish script/main processing from GPU.
- `phase_inst_us` includes more than object instantiation; it includes collision
  build prework and loader draining in `process_async_instantiation`.
- `addc` in `[inst-spike]` measures child attach loop only, not deferred work
  that might execute later.
- Static renderer cull/upload currently happens after instantiation and should
  be treated as part of streaming cost even if it is not named "instantiation."

## Verification Commands

Godot executable observed:

```powershell
D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe
```

Parser/startup smoke check:

```powershell
& 'D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe' --headless --path . --quit
```

.NET build:

```powershell
dotnet build Godotwind.sln --configfile NuGet.Config
```

Previously observed:

- `dotnet build Godotwind.sln --configfile NuGet.Config` passed with existing
  nullable warnings.
- Godot headless `--quit` passed.

## Files Most Likely To Matter

Streaming driver:

- `src/core/world/native_streaming_manager.gd`

Cell request and instantiate pipeline:

- `src/core/world/cell_manager.gd`

Model loading and prebaked cache:

- `src/core/world/model_loader.gd`

Ref classification and object creation:

- `src/core/world/reference_instantiator.gd`

Static renderer:

- `src/core/world/static_object_renderer.gd`
- `src/core/world/prototype_registry.gd`
- `src/core/world/prototype_batch.gd`

Static collision:

- `src/core/world/cell_static_collision.gd`
- `src/core/world/static_shape_cache.gd`
- `src/core/world/static_shape_pack.gd`

Prebake:

- `src/tools/prebaking/model_prebaker.gd`
- `src/tools/prebaking/prebaking_manager.gd`

Benchmark:

- `src/tools/streaming_benchmark.gd`
- `src/tools/benchmark_hud.gd`
- `docs/systems/benchmarking.md`

Config:

- `src/core/world/streaming_config.gd`
- `project.godot`

## Open Questions For The Next Agent

1. Are `.shapes.res` sidecars present and complete for all statics in the
   benchmark area?
2. Does any runtime path still fall back to walking a PackedScene for collision
   shapes?
3. How expensive is `ConcavePolygonShape3D.set_faces()` per cell in the
   benchmark route?
4. Is static renderer cull/upload a top-20-frame contributor?
5. Is off-thread `PackedScene.instantiate()` safe and stable in this exact
   Godot 4.6 setup, given project thread settings?
6. Are interactives too numerous or too eagerly spawned?
7. Does `_update_loaded_cells()` dominate boundary frames even with collision
   disabled?
8. Is `CellPreloader` warming enough cells for sustained flight speeds, or is
   the active loader still doing cold work?
9. Are all distant systems truly disabled in the launched scene, or are some
   managers still doing per-frame bookkeeping even if their visuals are hidden?
10. What are the exact pass/fail thresholds the user wants: 60 FPS, 120 FPS, or
    "no individual frame above X ms"?

## Bottom Line

The current code has several strong ingredients, but it is not yet a clean
buttery NEAR streaming architecture. The next session should avoid another
small blind tweak. Use the benchmark, identify the dominant spike class, and
then simplify the runtime path so cell boundaries enqueue state changes instead
of doing heavy work.

The most suspicious remaining issue is runtime per-cell collision finalization:
prebaked shape packs exist, yet visual activation can still trigger a main-thread
trimesh BVH build. Prove or disprove that first.
