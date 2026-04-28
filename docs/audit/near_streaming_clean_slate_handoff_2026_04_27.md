# NEAR Streaming Clean Slate Handoff

Date: 2026-04-27

## Smooth NEAR Streaming Tracker - Started 2026-04-28

Purpose: turn the current diagnosis into an implementation tracker for a
buttery NEAR-only tier in Godot 4.6. The design should make the best use of
Godot's strengths: server-side rendering/physics for bulk static content,
plain-data preparation off the hot path, and sparse scene-tree nodes only for
objects that truly need gameplay behavior.

This tracker replaces the failed whole-cell `DataReady` gate idea. The goal is
not to hold back a cell until everything is perfect. The goal is to prepare the
right payloads early, pin the needed resources, and publish visible work in
small, predictable chunks.

### Godot 4.6 Design Rules

- Bulk NEAR statics should be rendered through `RenderingServer` /
  `MultiMesh`, not thousands of `Node3D` / `MeshInstance3D` objects.
- Scene-tree work must stay sparse and explicitly budgeted. Use `Node3D` for
  doors, actors, activators, containers, scripted objects, animated objects,
  and other genuinely interactive refs.
- Worker threads may prepare plain data, sort refs, compute transforms, collect
  shape triangles, and request resources. They should not be the normal path for
  mass creation of rendering-node scene chunks.
- Main-thread publish may call Godot server/resource APIs, but every expensive
  publish class needs its own visible budget and benchmark column.
- Cell-boundary detection should enqueue state transitions only. It should not
  synchronously load, classify, instantiate, allocate batches, finalize
  collision, rebuild queues, and unload old cells on the same frame.
- Runtime should avoid asking the servers for data every frame. Server calls
  should mostly be one-way creation/update/free operations.

Relevant official Godot docs:

- Thread-safe APIs:
  `https://docs.godotengine.org/en/4.6/tutorials/performance/thread_safe_apis.html`
- Optimization using MultiMeshes:
  `https://docs.godotengine.org/en/4.6/tutorials/performance/using_multimesh.html`
- RenderingServer:
  `https://docs.godotengine.org/en/4.6/classes/class_renderingserver.html`
- PhysicsServer3D:
  `https://docs.godotengine.org/en/4.6/classes/class_physicsserver3d.html`

### Success Gates

Initial pass/fail gates for the standard NEAR-only AutoBench route:

- [ ] No visible object starvation or late whole-cell pop-in.
- [ ] No benchmark frames above `33.33 ms` during normal flyby.
- [ ] Stretch: no benchmark frames above `16.67 ms` during normal flyby.
- [ ] `p99.9 <= 16.67 ms` during normal flyby, or a clear remaining culprit
  with a measured follow-up task.
- [ ] Teleport scenario no longer reports single-digit `fps_min`.
- [ ] Top-20 worst frames are classifiable from CSV/logs without manual guesswork.
- [ ] Disabling cell static collision changes correctness/physics behavior, not
  visual smoothness. In other words, collision is no longer a visual hitch source.
- [ ] No crash before benchmark data flush; no recurring shutdown crash from
  streaming resources.

### Phase 0 - Baseline And Top-Frame Autopsy

Status: completed on 2026-04-28. Baseline collection found and stabilized a
static MultiMesh upload crash first, then completed the baseline and
no-collision flyby runs.

Commands:

```powershell
& 'D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe' --path . -- --bench-auto=near_streaming_smooth_baseline_mmset_2026_04_28 --start-cell=-3,-2 --near-only
& 'D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe' --path . -- --bench-auto=near_streaming_smooth_no_collision_mmset_2026_04_28 --start-cell=-3,-2 --near-only --disable-cell-static-collision
```

Tasks:

- [x] Capture current summary JSON, CSV, and log for a clean baseline.
- [x] Identify worst 20 normal-flyby frames.
- [x] Classify each worst frame by `phase_*_us`, `[inst-spike]`, `[ml-spike]`,
  `stream_proc`, heartbeat, and visible scenario segment.
- [x] Compare with `--disable-cell-static-collision`.
- [x] Record whether the dominant remaining spike class is `ml`, `sadd`,
  `coll`, `cellupd`, `unload`, `static_cull`, interactive spawn, or something
  else.

Acceptance:

- [x] We know which cost class owns the current tail before editing runtime
  architecture again.

Results:

- Pre-fix baseline crashed during `bench_flyby` startup at
  `PrototypeBatch._cull_native()` /
  `RenderingServer.multimesh_set_buffer`.
- Disabling the native C# culler moved the crash to the GDScript path at
  `PrototypeBatch.cull_and_upload()` /
  `RenderingServer.multimesh_set_buffer`.
- Kept the world-scoped `MultiMesh` renderer, but changed upload ownership to
  `MultiMesh.set_buffer()` plus `visible_instance_count`, and added a capacity
  guard before upload.
- Added `StreamingConfig.STATIC_CULL_NATIVE_ENABLED=false` so the C# packing
  handoff stays off until it is reworked and proven stable.
- Post-fix baseline completed and wrote data, then still hit the known shutdown
  crash after AutoBench sequence completion.

Baseline output:

- AutoBench dir:
  `user://benchmark_results/autobench_near_streaming_smooth_baseline_mmset_2026_04_28/`
- CSV:
  `user://benchmark_results/benchmark_2026-04-28_14-14-11.csv`
- Summary:
  `user://benchmark_results/summary_2026-04-28_14-14-12.json`
- Copied log:
  `user://benchmark_results/autobench_near_streaming_smooth_baseline_mmset_2026_04_28/godot_after_run.log`
- avg FPS: `179.9`
- avg frame: `5.56 ms`
- p95: `7.41 ms`
- p99: `13.54 ms`
- p99.9: `38.85 ms`
- max: `85.93 ms`
- frames over 16.67 ms: `92 / 15304`
- frames over 33.33 ms: `33 / 15304`

No-collision output:

- AutoBench dir:
  `user://benchmark_results/autobench_near_streaming_smooth_no_collision_mmset_2026_04_28/`
- CSV:
  `user://benchmark_results/benchmark_2026-04-28_14-18-40.csv`
- Summary:
  `user://benchmark_results/summary_2026-04-28_14-18-40.json`
- Copied log:
  `user://benchmark_results/autobench_near_streaming_smooth_no_collision_mmset_2026_04_28/godot_after_run.log`
- avg FPS: `183.0`
- avg frame: `5.46 ms`
- p95: `7.14 ms`
- p99: `12.98 ms`
- p99.9: `35.46 ms`
- max: `76.50 ms`
- frames over 16.67 ms: `62 / 15572`
- frames over 33.33 ms: `17 / 15572`

Interpretation:

- Collision remains a contributor, but it is not the dominant remaining tail:
  disabling cell static collision improved over-16 frames `92 -> 62` and
  over-33 frames `33 -> 17`, but did not remove the long tail.
- The dominant remaining visual-streaming classes are now:
  instantiate-loop work, static cull/upload, queue work, interactive publish,
  and cold model/prototype publish. Representative no-collision spike lines
  still show `ml=17-20 ms`, `sadd=2.5-4.0 ms`, static publish counts of
  `54-105`, and single-frame light/container costs above `10-26 ms`.
- CSV top frames with no collision still show combinations such as
  `phase_inst_us=20228`, `phase_static_cull_us=8264`,
  `phase_queue_us=33600`, and `inst_light_us=26604`.
- `phase_cellupd_us` was not a top-frame owner in these flyby runs, but
  teleport/unload still needs separate attention because AutoBench still
  exercises unload bursts and the existing handoff already recorded bad
  teleport minima.
- Next implementation target should be Phase 1 plus the start of Phase 2/3:
  make the hot path even more legible, then build the static `CellPayload` /
  static prepare path so `ml`, `sadd`, static publish, and static cull/upload
  stop landing in the same boundary frame.

### Phase 1 - Make The Hot Path Fully Legible

Status: partially completed on 2026-04-28.

Likely files:

- `src/core/world/native_streaming_manager.gd`
- `src/core/world/cell_manager.gd`
- `src/core/world/reference_instantiator.gd`
- `src/tools/streaming_benchmark.gd`
- `src/tools/benchmark_hud.gd`

Tasks:

- [x] Ensure benchmark CSV separates at least the known route-level costs for
  statics, doors, lights, light model loads, containers, and activators.
- [ ] Further split:
  data/model completion, static prepare, static publish, static cull/upload,
  interactive create, interactive attach, collision publish, unload/free, and
  cell-update management.
- [x] Add or extend a top-frame classifier so the log can print the likely
  owner of frames over `16.67 ms` and `33.33 ms`.
- [ ] Keep route-level columns already added:
  `inst_door_us`, `inst_light_us`, `inst_light_modelload_us`,
  `inst_container_us`, `inst_activator_us`, `inst_static_us`.

Acceptance:

- [ ] No broad `phase_inst_us` mystery remains for the top 20 frames.

Changes made:

- `[inst-spike]` now reports explicit `light=...` and `actor=...` buckets.
  Previously lights inherited the default `"sync"` route and were logged as
  `other`, which hid the real owner of repeated 9-28 ms spikes.
- `_instantiate_light()` now records `last_model_load_us`, so
  `inst_light_modelload_us` and the `ml` field include light model load cost.
  Before this, the CSV column was falsely zero for light spikes.
- Light model async/data loading now uses the generic model cache key. The
  active request path was warming light models as `model:item_id`, while
  `_instantiate_light()` loads them as `get_model(light_record.model)` without
  `item_id`, causing a second cold load in the publish path.
- Tightened two budget caps:
  - `CHILD_ATTACH_MAX_PER_FRAME: 20 -> 4`
  - `STATIC_CULL_BATCH_BUDGET_PER_FRAME: 64 -> 8`
- Kept the server-side `MultiMesh` renderer active. The tighter static cull
  budget is a smoother dirty-upload schedule, not a retreat from Godot server
  rendering.

Phase 1 route probe:

```powershell
& 'D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe' --path . -- --bench-auto=near_streaming_phase1_routes_no_collision_2026_04_28 --start-cell=-3,-2 --near-only --disable-cell-static-collision
```

Output:

- AutoBench dir:
  `user://benchmark_results/autobench_near_streaming_phase1_routes_no_collision_2026_04_28/`
- CSV:
  `user://benchmark_results/benchmark_2026-04-28_14-29-27.csv`
- Summary:
  `user://benchmark_results/summary_2026-04-28_14-29-27.json`
- avg FPS: `192.2`
- p95: `6.90 ms`
- p99: `12.21 ms`
- p99.9: `35.99 ms`
- max: `89.04 ms`
- frames over 16.67 ms: `64 / 16355`

Interpretation: route attribution worked. Recent `[inst-spike]` lines showed
`other=0.0`; the old mystery bucket collapsed into named `light`, `node`,
`wstatic`, `wnode`, `sadd`, and `ml` buckets.

Budgeted no-collision verification:

```powershell
& 'D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe' --path . -- --bench-auto=near_streaming_phase1_budget_no_collision_2026_04_28 --start-cell=-3,-2 --near-only --disable-cell-static-collision
```

Output:

- AutoBench dir:
  `user://benchmark_results/autobench_near_streaming_phase1_budget_no_collision_2026_04_28/`
- CSV:
  `user://benchmark_results/benchmark_2026-04-28_14-36-32.csv`
- Summary:
  `user://benchmark_results/summary_2026-04-28_14-36-32.json`
- avg FPS: `209.2`
- avg frame: `4.78 ms`
- p95: `6.14 ms`
- p99: `8.06 ms`
- p99.9: `29.64 ms`
- max: `62.45 ms`
- frames over 16.67 ms: `35 / 17801`
- frames over 33.33 ms: `14 / 17801`
- `phase_static_cull_us` max: `4114 us`

Compared to the prior no-collision run
`near_streaming_smooth_no_collision_mmset_2026_04_28`:

- p99.9 improved `35.46 -> 29.64 ms`
- frames over 16.67 ms improved `62 -> 35`
- frames over 33.33 ms improved `17 -> 14`
- `phase_static_cull_us` max improved `12262 -> 4114 us`

Budgeted collision-enabled verification:

```powershell
& 'D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe' --path . -- --bench-auto=near_streaming_phase1_budget_baseline_2026_04_28 --start-cell=-3,-2 --near-only
```

Output:

- AutoBench dir:
  `user://benchmark_results/autobench_near_streaming_phase1_budget_baseline_2026_04_28/`
- CSV:
  `user://benchmark_results/benchmark_2026-04-28_14-40-23.csv`
- Summary:
  `user://benchmark_results/summary_2026-04-28_14-40-23.json`
- avg FPS: `194.6`
- avg frame: `5.14 ms`
- p95: `6.70 ms`
- p99: `9.23 ms`
- p99.9: `36.27 ms`
- max: `70.15 ms`
- frames over 16.67 ms: `66 / 16560`
- frames over 33.33 ms: `24 / 16560`
- `phase_static_cull_us` max: `3946 us`

Compared to the prior collision-enabled baseline
`near_streaming_smooth_baseline_mmset_2026_04_28`:

- p99 improved `13.54 -> 9.23 ms`
- frames over 33.33 ms improved `33 -> 24`
- `phase_static_cull_us` max improved `11553 -> 3946 us`
- p99.9 stayed high because the remaining tail is now mostly `phase_inst_us`
  plus occasional collision finalization.

Remaining dominant classes after Phase 1:

- Cold light model publish: repeated `light=9-25 ms`, `ml=9-25 ms`.
- Cold node publish: e.g. `node=17-20 ms`, `ml=16-19 ms`.
- Static publish add cost: `sadd` mostly smaller after cull budgeting, but still
  present when static publish and cold node/light work stack.
- Child attach: smaller after the count cap, but still visible as `addc=5-9 ms`
  when several interactive nodes enter the tree.
- Collision: still appears in collision-enabled runs, e.g. `coll=11.6 ms` on a
  40 ms instantiate spike.

Next target:

- Start Phase 2/3 with a minimal static/light payload or prepare lane that pins
  the exact `PackedScene` resources before visual publish. The data path is now
  legible enough to see that model cache readiness, not broad cell update, owns
  much of the remaining NEAR tail.

### Phase 2 - Minimal `CellPayload` V0 For Statics

Status: pending.

Goal: create a prepared, resource-pinning payload before visual activation,
without reintroducing the whole-cell gate regression.

Likely files:

- `src/core/world/cell_manager.gd`
- possible new file: `src/core/world/cell_payload.gd`
- `src/core/world/reference_instantiator.gd`
- `src/core/world/model_loader.gd`

Payload V0 should contain:

- [ ] `grid: Vector2i`
- [ ] static refs grouped by model/prototype key
- [ ] precomputed world transforms for statics
- [ ] expected static batch counts by prototype/material where available
- [ ] interactive refs split out but not necessarily spawned
- [ ] light refs split out
- [ ] shape pack paths or collision preparation handles
- [ ] strong resource references needed to keep meshes/materials/scenes alive
- [ ] small stats dictionary for benchmark/log validation

Tasks:

- [ ] Add cell states for payload preparation without blocking incremental
  visual publish:
  `QueuedData`, `PreparingPayload`, `PayloadReady`, `VisualPublishing`,
  `VisualReady`, `PhysicsPublishing`, `Active`, `Unloading`.
- [ ] Build payload data ahead of activation using existing loaded cell records.
- [ ] Keep missing-resource refs incremental; do not hold the entire cell hidden
  waiting for every optional model.
- [ ] Validate static count and visible object count against the current path.

Acceptance:

- [ ] Static visual publish no longer performs cell-wide classification.
- [ ] The payload pins resources needed by publish.
- [ ] No regression to missing objects / late full-cell appearance.

### Phase 3 - Static Prototype And Batch Preallocation

Status: pending.

Goal: remove `ml` and first `sadd` spikes from visible publish.

Likely files:

- `src/core/world/cell_manager.gd`
- `src/core/world/static_object_renderer.gd`
- `src/core/world/prototype_registry.gd`
- `src/core/world/prototype_batch.gd`
- `src/core/world/streaming_config.gd`

Tasks:

- [ ] Keep `DEBUG_DISABLE_PHASE_F_PREREG=true` by default.
- [ ] Do main-thread static prototype registration from cached resources under
  `STATIC_PREPARE_BUDGET_MS`.
- [ ] Revisit `STATIC_PREPARE_CREATE_BATCHES`; enable only when batch creation
  is proven stable and budgeted.
- [ ] Add an explicit batch-reserve path using payload expected counts.
- [ ] Avoid first `PrototypeBatch` / `MultiMesh` allocation inside static
  instance publish.
- [ ] Track `sreg`, `sadd`, and model-loader `ml` separately during prepare vs
  publish.

Acceptance:

- [ ] Top-20 frames no longer contain cold static prototype loads during visual
  publish.
- [ ] Top-20 frames no longer contain first-batch `sadd` allocation spikes.
- [ ] Static prepare may spend time over multiple frames, but visual publish
  remains bounded.

### Phase 4 - Budgeted Static Visual Publish

Status: pending.

Goal: make visible static publication a small server-side operation fed by the
payload, not a discovery/load/register path.

Likely files:

- `src/core/world/cell_manager.gd`
- `src/core/world/reference_instantiator.gd`
- `src/core/world/static_object_renderer.gd`
- `src/core/world/prototype_registry.gd`

Tasks:

- [ ] Add a static visual publish queue fed by `CellPayload`.
- [ ] Publish static instances under a count/time budget independent of
  interactive spawn and collision.
- [ ] Treat `MultiMesh.set_buffer` / dirty upload as its own
  budgeted continuation, not a hidden aftereffect.
- [ ] Ensure unload does not immediately force a huge cull/upload rebuild.

Acceptance:

- [ ] Static publish work is bounded even when entering a dense cell.
- [ ] `phase_static_cull_us` and static upload costs are no longer top-frame
  surprises after cell churn.

### Phase 5 - Collision Lane Decoupled From Visual Smoothness

Status: pending.

Goal: collision may lag visual activation briefly, but it must not hitch visual
streaming.

Likely files:

- `src/core/world/cell_manager.gd`
- `src/core/world/cell_static_collision.gd`
- `src/core/world/static_shape_cache.gd`
- `src/core/world/static_shape_pack.gd`
- `src/tools/prebaking/model_prebaker.gd`

Tasks:

- [ ] Verify `.shapes.res` sidecars are present and used for benchmark-area
  statics.
- [ ] Measure `ConcavePolygonShape3D.set_faces()` per cell.
- [ ] Keep worker triangle collection separate from main-thread finalization.
- [ ] Finalize/publish collision only when visual/static queues are idle and
  within a collision-specific budget.
- [ ] Investigate prebaked cell-level collision resources so runtime does not
  build large trimesh BVHs on boundary frames.
- [ ] Keep `--disable-cell-static-collision` as an ablation and correctness
  comparison flag.

Acceptance:

- [ ] `[inst-spike] coll=...` is absent from visual-boundary top frames.
- [ ] Collision-enabled and collision-disabled flybys have similar visual
  smoothness percentiles.

### Phase 6 - Sparse Interactive Node Lane

Status: pending.

Goal: interactives use scene nodes, but only when needed and under explicit
budgets.

Likely files:

- `src/core/world/reference_instantiator.gd`
- `src/core/world/cell_manager.gd`
- `src/core/world/interaction_shape_cache.gd`

Tasks:

- [ ] Split interactive create and `add_child` attach budgets.
- [ ] Replace bursty `call_deferred("add_child", ...)` behavior with a bounded
  attach queue.
- [ ] Keep doors high priority, using `InteractionShapeCache`.
- [ ] Spawn containers, activators, and other sparse interactives by priority /
  proximity instead of raw cell membership where possible.
- [ ] Keep lights server-direct where behavior allows; avoid light `Node3D`s for
  static decorative lights.

Acceptance:

- [ ] Interactive spikes are small and attributable.
- [ ] Door/interact behavior is preserved.
- [ ] No deferred child-attach burst appears after the measured budget slice.

### Phase 7 - Boundary And Unload Amortization

Status: pending.

Goal: crossing a cell boundary schedules work; it does not perform work.

Likely files:

- `src/core/world/native_streaming_manager.gd`
- `src/core/world/cell_manager.gd`
- `src/core/world/cell_preloader.gd`
- `src/core/world/static_object_renderer.gd`

Tasks:

- [ ] Split `_update_loaded_cells()` into cheap desired-state calculation and
  budgeted job queues.
- [ ] Budget old-cell unload/free work separately from new-cell publish.
- [ ] Avoid clearing/rebuilding large pending queues on the boundary frame.
- [ ] Ensure distant-system scans remain disabled or no-op during NEAR-only
  runs.
- [ ] Fix teleport path by draining transitions over frames instead of forcing
  all unload/load work immediately.

Acceptance:

- [ ] `phase_cellupd_us` and `phase_unload_us` are not top-frame owners during
  flyby.
- [ ] Teleport benchmark no longer reports single-digit `fps_min`.

### Phase 8 - Verification Battery

Status: pending.

Always run after meaningful runtime changes:

```powershell
& 'D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe' --headless --path . --quit
dotnet build Godotwind.sln --configfile NuGet.Config
git diff --check
```

Benchmark battery:

```powershell
& 'D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe' --path . -- --bench-auto=near_streaming_smooth_verify_YYYY_MM_DD --start-cell=-3,-2 --near-only
& 'D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe' --path . -- --bench-auto=near_streaming_smooth_verify_no_collision_YYYY_MM_DD --start-cell=-3,-2 --near-only --disable-cell-static-collision
```

Benchmark coverage note:

- [ ] Add a high-altitude fast NEAR stress route: camera roughly `100 m` above
  terrain, moving fast enough to cross cell boundaries frequently while keeping
  lots of NEAR statics visible.
- [ ] Add diagonal movement coverage. Diagonal traversal crosses cell corners
  and can force different load/unload/preload overlap than axis-aligned movement.
- [ ] Keep the existing scripted flyby for continuity, but do not treat it as
  the only pass/fail route. A buttery NEAR tier should survive sustained
  high-altitude and diagonal flight too.

Record for each run:

- [ ] Output directory
- [ ] CSV path
- [ ] summary JSON path
- [ ] avg FPS
- [ ] p95 / p99 / p99.9 / max frame time
- [ ] frames over `16.67 ms`
- [ ] frames over `33.33 ms`
- [ ] top-frame classification
- [ ] visible correctness notes
- [ ] crash or shutdown notes

## Session Update - 2026-04-28 Audit / Keep-Ditch Pass

Audited the uncommitted changes after `d6cfc15`.

Kept:

- Per-frame benchmark columns for route-level instantiate cost:
  `inst_door_us`, `inst_light_us`, `inst_light_modelload_us`,
  `inst_container_us`, `inst_activator_us`, `inst_static_us`.
- Door interaction shape caching via `InteractionShapeCache`. This removes the
  repeated mesh-AABB walk and `BoxShape3D` allocation for duplicate door
  prototypes while preserving the per-instance `Area3D` raycast target.
- Worker dispatch order fix: `_phase_a_dispatch_pass()` now scans the
  instantiation queue from the same high-priority end that the drain pops.
  The old forward scan spent the tiny worker-dispatch budget on low-priority
  refs, then high-priority interactives fell through to sync main-thread
  instantiation.
- Collision publish is no longer finalized at the start of the instantiate
  slice. `_tick_static_collision_build(false)` only dispatches worker triangle
  collection before visual publish; `set_faces()` finalization is attempted
  later only when visual publish queues are idle and the slice has budget left.
- Re-enabled the main-thread static prepare lane with batch creation still off:
  `STATIC_PREPARE_ENABLED=true`, `STATIC_PREPARE_CREATE_BATCHES=false`. This is
  not the old crash-prone off-thread Phase F path. It uses cached
  `PackedScene` resources and `register_from_packed_scene()` under a small
  budget so static publish no longer has to perform cold prototype registration
  in the activation drain.

Ditched:

- The whole-cell `DataReady` gate experiment and its plan docs. It improved
  some synthetic percentiles in one run, but it held cells behind all-model
  readiness, ended the benchmark with cells still in `loading`, surfaced
  `dr_miss=5`, and matched the observed visual regression where many objects
  were missing or appeared too late. Do not revive that exact gate without a
  real payload model that pins resources and preserves incremental visual
  publish.

Audit benchmark before ditching the gate:

```powershell
& 'D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe' --path . -- --bench-auto=near_streaming_audit_current_2026_04_28 --start-cell=-3,-2 --near-only
```

Output:

- `user://benchmark_results/autobench_near_streaming_audit_current_2026_04_28/`
- `user://benchmark_results/benchmark_2026-04-28_13-40-10.csv`
- `user://benchmark_results/summary_2026-04-28_13-40-10.json`

Summary:

- avg FPS: `254.9`
- avg frame: `3.92 ms`
- p95: `4.95 ms`
- p99: `6.53 ms`
- p99.9: `42.65 ms`
- max: `91.41 ms`
- frames over 16.67 ms: `137 / 21679`

Interpretation: the route instrumentation was useful, but the gate was not
production-worthy. Remaining visible spikes still include cold static/model
publish (`ml`) and runtime cell collision finalization (`coll`), so the next
productive work is still payload/prewarm/collision redesign, not whole-cell
publish gating.

Verification after ditching the gate and enabling main-thread static prepare:

```powershell
& 'D:\Gamedev\Godot\Godot_v4.6-stable_mono_win64.exe' --path . -- --bench-auto=near_streaming_audit_cleaned_static_prepare_2026_04_28 --start-cell=-3,-2 --near-only
```

Output:

- `user://benchmark_results/autobench_near_streaming_audit_cleaned_static_prepare_2026_04_28/`
- `user://benchmark_results/benchmark_2026-04-28_13-52-05.csv`
- `user://benchmark_results/summary_2026-04-28_13-52-05.json`

Summary:

- avg FPS: `202.1`
- avg frame: `4.95 ms`
- p95: `6.53 ms`
- p99: `9.50 ms`
- p99.9: `33.67 ms`
- max: `67.16 ms`
- frames over 16.67 ms: `68 / 17193`

Compared to the gate run, this keeps the p99.9 improvement while restoring
incremental object publish. Static publish attribution dropped sharply in the
flyby (`static avg` in the 5s breakdown went from multi-ms cold samples to
roughly `39-218 us` windows), but first-batch allocation can still appear
during startup/settle (`sadd=110.5 ms`). Teleport still has a bad `fps_min=2`;
next work should target teleport cell-update/unload bursts, residual interactive
sync loads, and a real safe batch preallocation/payload path.

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
