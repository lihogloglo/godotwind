# Spring Cleanup Pillar 3 Charter: Systematic Optimization

Date: 2026-06-18

## Purpose

Turn the Pillar 3.0 observability foundation into a repeatable optimization
program. The goal is faster loading, higher FPS, fewer frame spikes, lower
memory growth, and less main-thread work, without guessing and without broad
rewrites.

This charter is the durable handoff for future agents. When the user says
"Spring cleanup, optimize", "Pillar 3 optimization", "make it faster", or
"optimization pass", use this file plus:

- `.agents/skills/spring-cleanup/SKILL.md`
- `.agents/skills/performance-observatory/SKILL.md`
- `docs/audit/performance_observatory_state.md`
- `docs/audit/performance_observatory_hot_path_gdscript_evidence_2026_06_18.md`
- `docs/systems/benchmarking.md`
- `docs/systems/loading.md`
- `docs/systems/streaming_rendering_bible.md`
- `tests/benchmark/benchmark_thresholds.gd`

## Canonical Rule

Optimize only a measured bottleneck, and prefer the engine-native pattern
before a custom or C# rewrite.

The current Godot 4.6 official guidance backs the operating model:

- Measure first with timers, the Godot profiler, and external CPU/GPU profilers
  when needed:
  https://docs.godotengine.org/en/stable/tutorials/performance/general_optimization.html
- CPU optimization starts by identifying the bottleneck before spending effort:
  https://docs.godotengine.org/en/stable/tutorials/performance/cpu_optimization.html
- Server APIs can be faster than scene nodes because they skip high-level node
  overhead:
  https://docs.godotengine.org/en/stable/tutorials/performance/using_servers.html
- Use Godot's 3D optimization surfaces before bespoke distance/render systems:
  MultiMesh, mesh LOD, visibility ranges, occlusion, resolution scaling, and
  pipeline precompilation:
  https://docs.godotengine.org/en/stable/tutorials/performance/index.html
- Reuse materials and shaders because render state changes are expensive:
  https://docs.godotengine.org/en/stable/tutorials/performance/gpu_optimization.html
- C# can help data-heavy code, but GodotObject/Node property access crosses the
  Godot native interop boundary; cache repeated values and do not move
  scene-tree orchestration blindly:
  https://docs.godotengine.org/en/stable/tutorials/scripting/c_sharp/c_sharp_basics.html

## Non-Goals

- No whole-file GDScript-to-C# ports.
- No budget tuning without before/after reports from the same scenario.
- No new benchmark framework while the existing report contract can be extended.
- No headless/null-renderer FPS as rendering acceptance evidence.
- No "turn features off" as the optimization unless the feature is optional by
  design and the report labels the mode as such.
- No custom culling, paging, or scheduler layer if Godot already has the
  relevant native feature and project constraints do not rule it out.

## Optimization Loop

Every feature or subsystem gets the same loop:

1. Pick one target from the ranked backlog.
2. State the user-visible problem in one line: startup time, frame time,
   p95/p99 spike, draw calls, memory growth, cache miss, or stutter.
3. Collect a before report using a named scenario from Pillar 3.0.
4. Identify the bottleneck owner and the canonical Godot/industry pattern.
5. Choose the smallest intervention:
   - delete dead work,
   - replace custom work with native Godot,
   - move a pure data kernel to C#,
   - reduce allocations or copies,
   - change cache/prebake policy,
   - split or cap main-thread publication.
6. Implement one slice.
7. Run the changed-path correctness check.
8. Run the same scenario again with the same renderer and validity mode.
9. Record before/after numbers, regressions, verification, and next action in
   this charter or a linked dated optimization note.

If step 3 cannot produce valid evidence, stop and add the missing metric or
scenario first.

Use the narrowest harness that exercises the lane under work. Specific
test scenes, report tools, or focused gdUnit checks are the normal inner loop;
the full `scenes/Godotwind.tscn` launch is the integrated acceptance check for
boot/world-streaming behavior, not the default way to iterate on every lane.

## Required Per-Slice Record

Copy this block for each optimization slice:

```text
### Slice N: <subsystem / feature>

Status: planned | measuring | implementing | accepted | rejected | parked
Owner files:
Scenario:
Before report:
After report:
User-visible target:
Bottleneck evidence:
Canonical pattern:
Chosen intervention:
Correctness verification:
Performance result:
Regressions / caveats:
Next action:
```

## Feature Test Matrix

Use the narrowest scenario that exercises the feature. Prefer existing reports;
add instrumentation only when the current report cannot answer the question.

| Feature / subsystem | Primary scenario | Required evidence before editing | Likely intervention lane |
|---|---|---|---|
| Boot / first playable | `cold_start`, `warm_start`, `first_playable` | phase timings, ESM/BSA/model/terrain splits, validity flags | cache/prebake policy, native parser gap, load ordering |
| Cell streaming | `flythrough_streaming`, `fast_travel_streaming` | queue depth, phase timings, frame p95/p99, sync fallback count | lane budget split, C# pure kernels, less main-thread publication |
| NEAR scene publication | `near_only`, `first_exterior_cell` | instantiation queue, node count, promotion/deferred counts | fewer nodes, pooling, native data prep, publication caps |
| MID static visuals | `flythrough_streaming`, `stress_dense_exterior` | draw groups, instances, draw calls, static cull time | MultiMesh/RS path cleanup, material batching, LOD tuning |
| HLOD | `hlod_enabled`, `stress_dense_exterior` | merge queue, chunk count, draw calls, frame spikes | chunk/material reduction, worker merge boundary, publish throttling |
| FAR impostors | `flythrough_streaming`, `asset_cache_hit` | page update time, atlas upload time, draw calls, VRAM | differential updates, texture upload smoothing, C# packing kernels |
| Model loading | `asset_cache_miss`, `asset_cache_hit` | cache hit/miss counts, load callbacks, load durations | cache policy, preload ordering, ResourceLoader usage |
| NIF fallback / prebake | `asset_cache_miss` | proof fallback happens during gameplay or is offline-only | native conversion gap, prebake-only fix, fallback deletion |
| ESM/source loading | `cold_start`, `first_playable` | native primary load vs supplement/populate split | native loader closure, GDScript supplement shrink |
| Interior transitions | `interior_transition` | transition latency, cleanup, memory/object deltas | preload timing, pocket reuse, cleanup leak fix |
| Memory lifetime | `fast_travel_streaming` with lifetime probe | object/resource/node/orphan deltas, RID leak logs | ownership cleanup, delayed free drain, cache eviction policy |
| Rendering quality cost | `bench_progressive`, manual A/B | per-subsystem delta ms, draw calls, pipeline compile deltas | native settings, shader/material reuse, quality tier defaults |

## First Optimization Backlog

Start here unless newer evidence supersedes it:

1. Loading-speed attribution for current first-playable runs. Loading latency
   compounds every later benchmark, and 2026-06-18 reports showed a valid
   42.8 s first-playable run and an invalid 57.3 s timeout run.
2. Current `flythrough_streaming` and `fast_travel_streaming` reports for
   `CellManager` / `NativeStreamingManager` lane timing. Evidence exists from
   `spring_pillar3_lane_timing_2026_06_18`; use it as the runtime-streaming
   before baseline after the loading slice.
3. Split the shared 8ms streaming budget into real per-lane targets aligned
   with the 140 FPS goal, only after current reports identify the worst lane.
4. Reduce first-playable latency by splitting ESM native primary load,
   GDScript supplement/populate work, terrain, BSA, model, and publication
   phases in the loading report.
5. Run `hlod_enabled` evidence before touching `ObjectPaging`; HLOD is
   default-off, so no current runtime report proves its active cost.
6. Run paired `asset_cache_miss` / `asset_cache_hit` evidence before touching
   `ModelLoader`, `ReferenceInstantiator`, or NIF fallback paths.
7. Use the lifetime probe to classify object/resource growth before optimizing
   cache eviction or RID cleanup.

## Slice Records

### Slice 1: Streaming Lane Timing Evidence

Status: measured
Owner files: `src/tools/auto_bench_runner.gd`
Scenario: `flythrough_streaming`, `fast_travel_streaming`
Before report: `user://benchmark_results/summary_2026-06-18_12-26-41.json`, `user://benchmark_results/benchmark_2026-06-18_12-26-41.csv`, `user://benchmark_results/autobench_spring_pillar3_lane_timing_2026_06_18/bench_teleport.json`
After report: n/a, instrumentation/evidence slice only
User-visible target: reduce streaming stutter and post-teleport queue drain without hiding regressions behind average FPS
Bottleneck evidence: flythrough active streaming averaged 8.49 ms/frame with `phase_inst` averaging 7.63 ms; fast travel sampled `stream_total_ms` at 9.40 ms average with `phase_inst` averaging 7.60 ms and instantiation queue reaching 1748 after 20 seconds
Canonical pattern: measure first, then cap/split main-thread publication or move pure data kernels only where reports prove heat; no shared-budget tuning without A/B
Chosen intervention: persisted existing lane timings into autobench JSON samples/summaries; no runtime optimization yet
Correctness verification: focused `test_auto_bench_runner.gd` and `test_performance_report_contract.gd` exited 0; real-renderer autobench completed
Performance result: reports identify `CellManager` instantiation/publication as first steady target; flythrough also has a one-off `phase_queue` spike at 100.93 ms that should be inspected but is not the steady bottleneck
Regressions / caveats: route buckets explain only a small part of `phase_inst`, so inspect the broader CellManager publication path before changing runtime behavior
Next action: implement the smallest measured `CellManager` instantiation/publication optimization and compare the same scenario before/after

### Slice 2: Loading-Speed Attribution

Status: measured
Owner files: `src/tools/loading_baseline_report.gd`, `src/tools/world_explorer.gd`, `src/core/esm/esm_manager.gd`
Scenario: `warm_start`
Before report: `user://benchmark_results/loading_baseline_warm_start_2026-06-18_13-13-10.json`
After report: n/a, attribution/evidence slice only
User-visible target: reduce first-playable startup time before spending more sessions on runtime streaming benchmarks
Bottleneck evidence: valid warm-start first playable took 36.359 s. Named owners: source-data total 8.364 s, ESM native primary 2.422 s, GDScript ESM populate/supplement 4.820 s, BSA/cache 1.119 s, terrain 5.143 s, model/material warmup 0.226 s, inner-ring gate wait 6.675 s, and accumulated CellManager publication inside that gate 2.566 s. `unattributed_or_other_init_ms` remains 15.951 s and needs one more report-label split before treating it as an optimization target.
Canonical pattern: measure startup phases with the existing loading report and Godotwind owner metrics first; optimize only one measured owner with the same warm-start before/after report
Chosen intervention: extended the existing loading baseline report and ESM timing surface; no runtime optimization, budget tuning, cache policy change, or C# migration
Correctness verification: focused `test_loading_baseline_report.gd` exited 0; integrated real-renderer warm-start launch exited 0 and wrote the report
Performance result: attribution identifies ESM GDScript populate/supplement, terrain/horizon startup, and boot-gate wait/publication as first named loading targets; broad runtime `CellManager` tuning remains deferred
Regressions / caveats: `cell_manager_publication_ms` is accumulated work inside `inner_ring_gate_wait_ms`, not additive wall-clock time. Shader cache/import artifacts were not cleared because no shader files changed.
Next action: split the remaining `unattributed_or_other_init_ms` bucket into existing startup owner labels, then choose one named loading owner for a same-scenario warm-start optimization.

### Slice 3: Startup Attribution Split + Common Model Preload Delete

Status: accepted
Owner files: `src/tools/world_explorer.gd`, `src/tools/loading_baseline_report.gd`, `tests/unit/test_loading_baseline_report.gd`
Scenario: `warm_start`
Before report: `user://benchmark_results/loading_baseline_warm_start_2026-06-18_13-48-41.json`
After report: `user://benchmark_results/loading_baseline_warm_start_2026-06-18_13-51-59.json`
User-visible target: reduce first-playable startup latency and identify the next real loading owner without guessing
Bottleneck evidence: the new split reduced the previous `unattributed_or_other_init_ms` from 15.951 s to near-zero attribution noise. The final accepted after-report reached first playable in 33.788 s, with `ready_to_init_async_start_ms=8.139 s`, `post_init_to_boot_gate_ms=6.273 s`, `inner_ring_gate_wait_ms=6.658 s`, `terrain_ms=4.166 s`, and `gdscript_supplement_populate_ms=4.358 s`.
Canonical pattern: use Godot's existing `ResourceLoader.load_threaded_request()` model path for first-cell loads instead of speculative synchronous boot preloads; keep startup changes report-driven and same-scenario measured
Chosen intervention: kept `prewarm_model_cache_index()` but deleted the synchronous `preload_common_models()` boot call. Added first-playable attribution keys for engine scene ready, ready-to-init delay, init misc, and post-init-to-boot-gate handoff.
Correctness verification: focused gdUnit `test_loading_baseline_report.gd` exited 0 after the final code state. Integrated real-renderer warm-start launch exited and wrote the after report.
Performance result: first playable changed from 33.826 s to 33.788 s in the comparable final-code run, effectively flat but slightly lower. The old speculative model preload bucket was replaced by cache indexing (`model_material_warmup_ms` 158 ms to 133 ms). A direct `_init_async()` scheduling probe was rejected because it worsened first playable to 35.040 s.
Regressions / caveats: the accepted runtime optimization is intentionally small; the useful win is mostly attribution clarity, not a large startup reduction. Shader cache/import artifacts were not cleared because no shader files changed.
Next action: split `post_init_to_boot_gate_ms` inside `world_explorer`/`NativeStreamingManager.set_camera()` and then target the largest proven owner: either the 8.1 s ready-to-init delay, the 6.3 s camera/streaming handoff, terrain startup, or GDScript ESM supplement/populate.

## Acceptance Bar

A slice is accepted only when all of these are true:

- before and after reports use the same scenario, renderer, and validity mode,
- correctness verification passes for the changed path,
- C# changes pass `dotnet build Godotwind.sln`,
- visual/rendering/shader changes follow the project launch and shader-cache
  rules from `AGENTS.md`,
- the report shows a real improvement in the target metric or the slice is
  explicitly rejected/parked with evidence,
- no worse p95/p99/max-frame, memory, loading, or visual regression is hidden by
  an average-FPS improvement,
- the state file records the practical effect in plain English.

## Do Not Touch Without Fresh Evidence

- Do not migrate `world_explorer.gd` wholesale; it is mostly orchestration.
- Do not port benchmark/report tools for runtime speed.
- Do not optimize HLOD while it is default-off without an `hlod_enabled` report.
- Do not change cache eviction from leak symptoms alone; capture object/resource
  ownership evidence first.
- Do not treat archived April/May flybys as current acceptance numbers. They
  are historical heat evidence only.

## Recommended Prompt

```text
Spring cleanup, start Pillar 3 optimization.

Read the optimization charter, Spring cleanup state, and performance
observatory state. Run the static scan. Start with loading-speed attribution,
not runtime streaming optimization: use or build the narrowest loading
harness/report that splits first-playable time into source-data, ESM native
primary, GDScript supplement/populate, BSA/cache, terrain, model/material
warmup, CellManager publication, and inner-ring gate wait. Use
`scenes/Godotwind.tscn --loading-baseline=warm_start` only as the integrated
before/after acceptance run. Do not tune shared streaming budgets or migrate
broad files to C# until a same-scenario report identifies the bottleneck.
```
