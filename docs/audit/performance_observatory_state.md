# Performance Observatory State

Last updated: 2026-06-18

Purpose: durable state for Godotwind Pillar 3.0, the benchmark/debug/
diagnostic foundation for the merged Pillar 3/5 performance and loading arc.
When the user says "Performance Observatory, continue", "Pillar 3.0,
continue", "benchmark foundation", or similar, use the repo-local skill:

- `.agents/skills/performance-observatory/SKILL.md`

## Current Status

Loading-speed attribution for the first Pillar 3 optimization slice is now
available. This is attribution/instrumentation only; no runtime streaming
budget, cache policy, queue behavior, or broad C# migration changed.

Completed this slice:

- Reran the deterministic static observability scan:
  `python .agents/skills/performance-observatory/scripts/perf_observatory_scan.py --root .`
- Extended the existing loading baseline report with owner attribution for:
  engine scene ready, ready-to-init delay, source-data total/other, ESM native
  primary, GDScript populate/supplement, BSA/cache, terrain, model/cache index,
  init misc, post-init-to-boot-gate handoff, CellManager publication work
  inside the boot gate, and inner-ring gate wait.
- Added `ESMManager.get_last_load_timing_stats()` so the main scene can attach
  primary ESM native/populate/supplement timings without scraping logs.
- Current real-renderer integrated warm-start report:
  `user://benchmark_results/loading_baseline_warm_start_2026-06-18_13-51-59.json`
- Current evidence from that report:
  - valid warm-start first-playable run, no timeout
  - process-to-first-playable: 33.788 s
  - ready-to-init delay: 8.139 s
  - post-init-to-boot-gate handoff: 6.273 s
  - terrain: 4.166 s
  - GDScript ESM populate/supplement: 4.358 s
  - inner-ring gate wait: 6.658 s
  - accumulated CellManager publication work inside that gate: 2.350 s
  - model/cache index: 0.133 s
  - remaining unattributed/other init: near-zero attribution noise
- Conclusion: the next optimization should not start with shared streaming
  budget tuning or broad GDScript-to-C# ports. The first concrete loading
  target is splitting the 6.273 s post-init camera/streaming handoff, then
  choosing between that handoff, ready-to-init delay, terrain/horizon startup,
  ESM GDScript supplement/populate, or boot-gate publication.

Current lane-timing evidence now identifies the first measured Pillar 3 target:
`CellManager` instantiation/publication.

Completed this slice:

- Ran the deterministic static observability scan:
  `python .agents/skills/performance-observatory/scripts/perf_observatory_scan.py --root .`
- Regenerated:
  - `reports/performance_observatory_scan.md`
  - `reports/performance_observatory_scan.json`
- Added lane timing to `src/tools/auto_bench_runner.gd` by persisting existing
  `NativeStreamingManager` phase timing, queue depth, frame-total,
  distant-tier timing, and `CellManager.get_frame_inst_route_times()` values
  into autobench JSON samples/summaries.
- Ran a current real-renderer autobench:
  `--bench-auto=spring_pillar3_lane_timing_2026_06_18 --start-cell=-3,-2`
- Current evidence:
  - `user://benchmark_results/summary_2026-06-18_12-26-41.json`
  - `user://benchmark_results/benchmark_2026-06-18_12-26-41.csv`
  - `user://benchmark_results/autobench_spring_pillar3_lane_timing_2026_06_18/bench_teleport.json`
- Conclusion: current `flythrough_streaming` and `fast_travel_streaming`
  evidence both point to `CellManager` instantiation/publication as the steady
  first bottleneck. Flythrough active streaming averaged 8.49 ms/frame, with
  `phase_inst` averaging 7.63 ms. Fast travel sampled `stream_total_ms` at
  9.40 ms average, with `phase_inst` averaging 7.60 ms and the instantiation
  queue reaching 1748 after 20 seconds. The flythrough run segment also showed
  a one-off `phase_queue` spike at 100.93 ms; inspect it, but do not treat it
  as the steady bottleneck.
- No runtime optimization, C# migration, budget tuning, cache-policy change, or
  queue behavior change was performed.

Hot-path GDScript evidence report complete after the object/memory lifetime,
loading-time baseline, and custom Performance monitor instrumentation slices.

Completed this slice:

- Ran the deterministic static observability scan:
  `python .agents/skills/performance-observatory/scripts/perf_observatory_scan.py --root .`
- Regenerated:
  - `reports/performance_observatory_scan.md`
  - `reports/performance_observatory_scan.json`
- Added:
  `docs/audit/performance_observatory_hot_path_gdscript_evidence_2026_06_18.md`
- Ranked future C# migration candidates using the static hot-path list plus
  existing loading, lifetime, stress, and archived flyby reports.
- Top candidates are `cell_manager.gd`, `native_streaming_manager.gd`,
  `native_impostor_renderer.gd`, `static_object_renderer.gd`,
  `object_paging.gd`, `model_loader.gd` / `reference_instantiator.gd`,
  `esm_manager.gd`, and the NIF fallback/prebake path.
- No runtime optimization, C# migration, budget tuning, cache-policy change,
  benchmark-runner behavior change, C# build, or shader edit was performed.

Completed this slice:

- Added `src/tools/lifetime_probe_report.gd`, a small report builder/writer
  for object/memory lifetime diagnostics normalized to
  `godotwind_performance_report_v1`.
- Wired `src/tools/world_explorer.gd` to run an opt-in repeated teleport
  probe after first playable when launched with `--lifetime-probe`.
- The probe samples existing Godot `Performance` counters only:
  - `OBJECT_COUNT`
  - `OBJECT_RESOURCE_COUNT`
  - `OBJECT_NODE_COUNT`
  - `OBJECT_ORPHAN_NODE_COUNT`
  - `MEMORY_STATIC`
  - `MEMORY_MESSAGE_BUFFER_MAX`
- Added focused gdUnit coverage:
  `tests/unit/test_lifetime_probe_report.gd`
- No loading budgets, streaming policy, cache policy, runtime optimization, or
  C# migration changed.

Runtime evidence from the first real-renderer probe:

- `user://benchmark_results/lifetime_probe_fast_travel_streaming_object_lifetime_probe_2026_06_17.json`
- scenario: `fast_travel_streaming`
- mode: `object_lifetime_probe`
- valid: `true`
- loop count: 2
- object delta: `+31061`
- resource delta: `+794`
- node delta: `-38`
- orphan node delta: `+283`
- static memory delta: `+272.08 MB`
- Godot exit log also reported RID/resource allocations still live at exit.
  This is diagnostic evidence only; no runtime cleanup or optimization was
  attempted in this slice.

Completed this slice:

- Added `src/tools/loading_baseline_report.gd`, a small report builder/writer
  that normalizes loading baseline JSON to
  `godotwind_performance_report_v1`.
- Wired `src/tools/world_explorer.gd` to persist a boot loading baseline report
  when the existing loading gate reaches first playable:
  - scenario labels: `first_playable`, `cold_start`, `warm_start`
  - cache-state labels from `--loading-baseline=cold_start|warm_start`
  - process-to-ready, process-to-init-done, process-to-first-playable, and
    loading-gate duration fields
  - timeout and benchmark validity/invalid-reason fields
  - existing loading phase, inner-ring, CellManager, and streaming stats
- Added focused gdUnit coverage:
  `tests/unit/test_loading_baseline_report.gd`
- No loading budgets, streaming policy, cache policy, runtime optimization, or
  C# migration changed.

Completed previous custom Performance monitor slice:

- Added live Godot custom performance monitors in
  `src/core/world/native_streaming_manager.gd` for existing streaming/loading
  values:
  - `godotwind/streaming/queue_size`
  - `godotwind/streaming/loaded_cells`
  - `godotwind/streaming/visual_ready_cells`
  - `godotwind/streaming/async_requests`
  - `godotwind/streaming/startup_phase`
  - `godotwind/streaming/first_playable_reached`
  - `godotwind/streaming/stream_total_ms`
- Registration is idempotent and cleaned up on `_exit_tree()`.
- The monitor callables read existing streaming manager state only; no budgets,
  queue behavior, loading policy, cache behavior, or optimization logic changed.
- Added focused gdUnit smoke:
  `tests/unit/test_streaming_custom_performance_monitors.gd`

Completed previous report-contract slice:

- Normalized formal benchmark/diagnostic JSON outputs to
  `godotwind_performance_report_v1` via `src/tools/performance_report_contract.gd`.
- Added top-level report fields for scenario, mode, validity, invalid reasons,
  git/worktree context, renderer/headless status, duration, threshold failures,
  raw outputs, baseline, and comparison.
- Wired the contract into:
  - `src/tools/streaming_benchmark.gd`
  - `src/tools/auto_bench_runner.gd`
  - `src/tools/bench_ladder_runner.gd`
  - `src/tools/streaming_stress_runner.gd`
  - `src/tools/progressive_benchmark.gd`
- Added `progressive_<timestamp>.json` beside the existing progressive CSV.
- Added focused tests:
  - `tests/unit/test_performance_report_contract.gd`
  - `tests/unit/test_progressive_benchmark_contract.gd`

Completed previous audit slice:

- Read the state, charter, benchmarking, loading, model-loading, thresholds,
  and status docs.
- Ran the deterministic static observability scan:
  `python .agents/skills/performance-observatory/scripts/perf_observatory_scan.py --root .`
- Regenerated:
  - `reports/performance_observatory_scan.md`
  - `reports/performance_observatory_scan.json`
- Created the first scenario/metric/report coverage matrix:
  `docs/audit/performance_observatory_coverage_matrix_2026_06_17.md`

No runtime optimization was performed.

## Scope

Pillar 3.0 is not optimization. It prepares the evidence machine needed before
optimization:

- benchmark scenario map,
- loading/startup metrics,
- streaming frame-budget and queue metrics,
- memory/object lifetime metrics,
- render/physics/pipeline compilation counters,
- structured JSON/CSV/Markdown summaries,
- baseline-vs-current comparison contract,
- agent-readable failure reasons,
- hot-path GDScript evidence for future C# migration,
- native Godot feature evidence before custom rewrites.

## Existing Evidence Surfaces

- `docs/systems/benchmarking.md`
- `docs/systems/loading.md`
- `docs/systems/model_loading.md`
- `tests/benchmark/benchmark_thresholds.gd`
- `src/tools/streaming_benchmark.gd`
- `src/tools/streaming_stress_runner.gd`
- `src/tools/auto_bench_runner.gd`
- `src/tools/bench_ladder_runner.gd`
- `src/tools/progressive_benchmark.gd`
- `src/tools/benchmark_hud.gd`
- `src/tools/subsystem_toggles.gd`
- `src/core/world/performance_profiler.gd`
- `src/core/world/streaming_profiler.gd`
- `src/core/diagnostics/pipeline_compile_monitor.gd`
- `src/core/world/native_streaming_manager.gd`
- `src/tools/world_explorer.gd`

## Online Method Notes

- Codex skills are the right reusable workflow unit for this because they carry
  instructions, scripts, and references with progressive disclosure.
- `AGENTS.md` is the right always-on project routing surface.
- Godot `Performance.get_monitor()` is the right built-in metric surface.
- Godot custom performance monitors are the right live surface for
  Godotwind-specific streaming/loading values.
- Godot profiler sessions are useful, but profiling itself has overhead and is
  not an always-on truth source.
- Godot 4.6 ObjectDB snapshots are relevant for later streaming leak tests.

## First Slice Backlog

1. [done 2026-06-17] Run the static observability inventory:
   `python .agents/skills/performance-observatory/scripts/perf_observatory_scan.py --root .`
2. [done 2026-06-17] Produce the first coverage matrix:
   scenario x metric x report output x current owner.
3. [done 2026-06-17] Decide the benchmark report contract:
   required fields, validity flags, baseline path, comparison shape, and
   human summary shape.
4. [done 2026-06-17] Identify the smallest instrumentation gap that blocks
   future optimization.
5. [done 2026-06-17] Implement one narrow instrumentation slice:
   live Godot custom Performance monitors for already-computed streaming values.
6. [done 2026-06-17] Formalize loading-time baseline evidence for
   cold/warm/first-playable runs without optimizing runtime code.
7. [done 2026-06-17] Add an object/memory lifetime probe for repeated
   load/unload or transition loops before runtime optimization.
8. [done 2026-06-18] Produce a hot-path GDScript evidence report for future C#
   migration candidates, using scan/profiler/benchmark evidence only.
9. [next evidence] Add targeted current scenario evidence for the top-ranked
   candidates before any C# migration or optimization.

## Latest Scan Result

Regenerated 2026-06-18 local workspace time for the hot-path evidence slice
(scan timestamp 2026-06-17 UTC):

| Category | Hits |
|---|---:|
| `benchmark_runner` | 678 |
| `hot_path_gdscript_signal` | 4081 |
| `loading_metric` | 727 |
| `memory_or_leak_metric` | 193 |
| `native_or_csharp_surface` | 1808 |
| `performance_builtin_monitor` | 64 |
| `performance_custom_monitor` | 5 |
| `pipeline_compile_metric` | 45 |
| `streaming_metric` | 1849 |
| `structured_report` | 1409 |

Static inferred gaps:

- GDScript hot-path candidates exist; Pillar 3/5 should require evidence before
  C# migration.

The previous live custom-monitor gap is closed for first-order streaming
metrics. The scan now finds runtime `Performance.add_custom_monitor()` usage.

The loading baseline gap is closed for first-playable JSON evidence. The
object/memory lifetime gap now has a first repeated-teleport JSON diagnostic.
The real renderer smokes generated:

- `user://benchmark_results/loading_baseline_warm_start_2026-06-17_22-22-19.json`
- `user://benchmark_results/lifetime_probe_fast_travel_streaming_object_lifetime_probe_2026_06_17.json`

Both reports used `schema=godotwind_performance_report_v1`; the lifetime probe
used `scenario=fast_travel_streaming`, `mode=object_lifetime_probe`, and
`valid_for_performance_baseline=true`.

## Report Contract

Formal JSON benchmark/diagnostic reports now share these top-level fields:

- `schema = "godotwind_performance_report_v1"`
- `scenario`
- `mode`
- `started_at`
- `duration_s`
- `summary`
- `benchmark_mode_metadata`
- `valid_for_performance_baseline`
- `invalid_reasons`
- `threshold_failures`
- `raw_outputs`
- `baseline`
- `comparison`
- `renderer`
- `headless`
- `git_commit`
- `worktree_dirty`

Existing runner-specific fields remain in place for compatibility.

## Completed Loading Baseline Slice

Added a first-playable loading baseline JSON report that future agents can read
without scraping console logs. This is instrumentation, not optimization.

Implemented scope:

- `LoadingBaselineReport` builds and writes the shared report-contract payload.
- `world_explorer.gd` records process/ready/init/first-playable timestamps and
  writes the report from the existing boot `LoadingStateMachine` completion
  path.
- `--loading-baseline=cold_start|warm_start|first_playable` labels the run;
  cold/warm labels set the cache-state marker.
- The report includes loading phase timings, inner-ring readiness, CellManager
  stats, streaming stats, timeout state, validity state, and raw output path.
- No budgets, queue behavior, streaming radius, cache policy, or C# runtime
  code changed.

Verification for that instrumentation slice completed:

- focused gdUnit report-shape test exited 0,
- one real-renderer launch of `scenes/Godotwind.tscn` with
  `--quit-after-ready=45 --loading-baseline=warm_start` reached first playable,
  wrote the loading baseline JSON, then exited through ready-quit,
- the smoke log showed `LoadingState 'boot' complete`, `[first-playable]`, and
  `[LOADING_BASELINE] wrote ...`,
- a pre-existing `world_explorer.gd` launch parse blocker was fixed by changing
  the local `texture_loader` field from a class-name annotation to `RefCounted`
  while retaining the existing preloaded constructor,
- C# build was not required because no C# files changed,
- shader cache/import handling was not required because no shader files changed.

## Completed Custom Monitor Slice

Added Godot custom performance monitors for existing, already-computed
streaming/loading values. This is instrumentation, not optimization.

Implemented scope:

- Registered monitors from the main-thread streaming owner,
  `NativeStreamingManager`.
- Read only existing values from streaming manager fields and current per-frame
  phase timing.
- Did not add new budgets, queue behavior, cache behavior, or optimization
  logic.
- Monitor names:
  - `godotwind/streaming/queue_size`
  - `godotwind/streaming/loaded_cells`
  - `godotwind/streaming/visual_ready_cells`
  - `godotwind/streaming/async_requests`
  - `godotwind/streaming/startup_phase`
  - `godotwind/streaming/first_playable_reached`
  - `godotwind/streaming/stream_total_ms`

Verification for that instrumentation slice completed:

- focused gdUnit smoke proved registration can run twice without duplicate
  monitor errors,
- existing NativeStreamingManager metadata test still passed after the
  `get_stats()` helper extraction,
- one real-renderer launch of `scenes/Godotwind.tscn` stayed up for the smoke
  window and closed cleanly,
- C# build was not required because no C# files changed,
- shader cache/import handling was not required because no shader files changed.

## Completed Object/Memory Lifetime Probe Slice

Added a first repeated-teleport lifetime diagnostic that future agents can read
without scraping console logs. This is instrumentation, not optimization.

Implemented scope:

- `LifetimeProbeReport` builds and writes the shared report-contract payload.
- `world_explorer.gd` starts the probe only when `--lifetime-probe` is present
  and only after the boot loading gate reaches first playable.
- The default route samples baseline counters, teleports through known exterior
  cells, waits briefly for streaming to settle, samples again, writes JSON, and
  exits through the existing fast-quit path.
- CLI controls are intentionally narrow:
  `--lifetime-probe`, `--lifetime-probe-loops=N`,
  `--lifetime-probe-settle=S`, and `--lifetime-probe-stamp=NAME`.
- No budgets, queue behavior, streaming radius, cache policy, cleanup policy,
  or C# runtime code changed.

Verification for that instrumentation slice completed:

- focused gdUnit report-shape test exited 0,
- adjacent shared report-contract and loading-baseline tests exited 0,
- one real-renderer launch of `scenes/Godotwind.tscn` with
  `--lifetime-probe --lifetime-probe-loops=2 --lifetime-probe-settle=2`
  reached first playable, ran two teleports, wrote the lifetime probe JSON, and
  exited through `LIFETIME_PROBE_DONE`,
- the smoke log showed `LoadingState 'boot' complete`, `[first-playable]`,
  `[LIFETIME_PROBE] starting`, and `[LIFETIME_PROBE] wrote ...`,
- the smoke log also showed existing exit-time RID/resource live-allocation
  messages; these are now captured as follow-up evidence, not fixed here,
- C# build was not required because no C# files changed,
- shader cache/import handling was not required because no shader files changed.

## Completed Hot-Path GDScript Evidence Slice

Produced the first report-backed C# migration candidate list:

- `docs/audit/performance_observatory_hot_path_gdscript_evidence_2026_06_18.md`

This is still observability, not optimization.

Keep it deliberately narrow:

- Reused the static scan hot-path list and existing benchmark/profiler outputs.
- Ranked candidates by measured or observable per-frame/data-heavy evidence.
- Did not migrate code to C#.
- Did not tune loading budgets, queue behavior, streaming radius, or cache
  policy.

Key conclusion: future C# migration should start with current scenario evidence
around `cell_manager.gd` / `native_streaming_manager.gd` kernels, not broad file
rewrites.

## Next Smallest Evidence Slice

Add targeted current scenario evidence for the top-ranked candidates before
optimization:

- current `flythrough_streaming` and `fast_travel_streaming` reports with lane
  timings normalized into `godotwind_performance_report_v1`,
- `hlod_enabled` evidence before touching `object_paging.gd`,
- `asset_cache_hit` / `asset_cache_miss` reports before touching
  `model_loader.gd`, `reference_instantiator.gd`, or NIF fallback paths,
- ESM loading split for native primary load versus GDScript supplement/populate
  work.

## Proposed Prompt

```text
Performance Observatory, continue.

Read the performance observatory state and charter, run the static scan, then
start loading-speed attribution before runtime streaming optimization. Use or
build the narrowest loading harness/report that splits first-playable time by
owner, then run `scenes/Godotwind.tscn --loading-baseline=warm_start` only as
the integrated acceptance check. Do not tune shared budgets or migrate broad
files to C# until same-scenario evidence identifies the bottleneck.
```

## Verification Expectations

- Audit-only slices: static scan plus updated state/charter docs.
- Instrumentation slices: focused gdUnit tests for report shape/threshold
  behavior, and a narrow real-renderer benchmark or smoke if runtime collection
  changed.
- C# touched: `dotnet build Godotwind.sln` before Godot launch.
- Shader touched: follow the shader cache/import rule in `AGENTS.md`.

## Latest Verification

Commands run 2026-06-18 for the loading attribution slice:

```powershell
python .agents/skills/performance-observatory/scripts/perf_observatory_scan.py --root .
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/run_tests.tscn -- --test res://tests/unit/test_loading_baseline_report.gd
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://scenes/Godotwind.tscn -- --quit-after-ready=60 --loading-baseline=warm_start
python .agents/skills/performance-observatory/scripts/perf_observatory_scan.py --root .
```

Focused gdUnit exited 0 after rerunning with no pre-existing Godot process. The
integrated warm-start scene exited 0 and wrote
`user://benchmark_results/loading_baseline_warm_start_2026-06-18_13-13-10.json`.
No C# files changed, so `dotnet build` was not required. No `.glsl`,
`.gdshader`, or `.gdshaderinc` files changed, so shader cache/import artifacts
were not cleared.

Commands run 2026-06-18 for the hot-path GDScript evidence slice:

```powershell
python .agents/skills/performance-observatory/scripts/perf_observatory_scan.py --root .
```

The scan exited 0 and regenerated
`reports/performance_observatory_scan.md` and
`reports/performance_observatory_scan.json`. No Godot visual launch or gdUnit
run was required because this was an audit/report-only slice and no runtime
code changed. No C# build was required because no C# files changed. Shader
cache/import artifacts were not cleared because no `.glsl`, `.gdshader`, or
`.gdshaderinc` files changed.

Commands run 2026-06-17 for the object/memory lifetime probe slice:

```powershell
python .agents/skills/performance-observatory/scripts/perf_observatory_scan.py --root .
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/run_tests.tscn -- --test res://tests/unit/test_lifetime_probe_report.gd
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/run_tests.tscn -- --test res://tests/unit/test_performance_report_contract.gd
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/run_tests.tscn -- --test res://tests/unit/test_loading_baseline_report.gd
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://scenes/Godotwind.tscn -- --lifetime-probe --lifetime-probe-loops=2 --lifetime-probe-settle=2 --lifetime-probe-stamp=object_lifetime_probe_2026_06_17
python .agents/skills/performance-observatory/scripts/perf_observatory_scan.py --root .
```

All focused gdUnit runs exited 0. The real-renderer scene smoke reached first
playable, wrote
`user://benchmark_results/lifetime_probe_fast_travel_streaming_object_lifetime_probe_2026_06_17.json`,
and exited through `LIFETIME_PROBE_DONE`. No C# build was required because no
C# files changed. Shader cache/import artifacts were not cleared because no
`.glsl`, `.gdshader`, or `.gdshaderinc` files changed.

Commands run 2026-06-17 for the loading baseline evidence slice:

```powershell
python .agents/skills/performance-observatory/scripts/perf_observatory_scan.py --root .
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/run_tests.tscn -- --test res://tests/unit/test_loading_baseline_report.gd
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/run_tests.tscn -- --test res://tests/unit/test_performance_report_contract.gd
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/run_tests.tscn -- --test res://tests/unit/test_progressive_benchmark_contract.gd
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/run_tests.tscn -- --test res://tests/unit/test_streaming_custom_performance_monitors.gd
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://scenes/Godotwind.tscn -- --quit-after-ready=45 --loading-baseline=warm_start
python .agents/skills/performance-observatory/scripts/perf_observatory_scan.py --root .
```

All focused gdUnit runs exited 0. The real-renderer scene smoke reached first
playable, wrote
`user://benchmark_results/loading_baseline_warm_start_2026-06-17_22-22-19.json`,
and exited through ready-quit. No C# build was required because no C# files
changed. Shader cache/import artifacts were not cleared because no `.glsl`,
`.gdshader`, or `.gdshaderinc` files changed.

Commands run 2026-06-17:

```powershell
python .agents/skills/performance-observatory/scripts/perf_observatory_scan.py --root .
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/run_tests.tscn -- --test res://tests/unit/test_performance_report_contract.gd
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/run_tests.tscn -- --test res://tests/unit/test_auto_bench_runner.gd
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/run_tests.tscn -- --test res://tests/unit/test_bench_ladder_runner.gd
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/run_tests.tscn -- --test res://tests/unit/test_streaming_stress_runner_gates.gd
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/run_tests.tscn -- --test res://tests/unit/test_progressive_benchmark_contract.gd
```

All focused gdUnit runs exited 0. Direct `--check-only --script` is not useful
for these scripts because standalone script parsing cannot resolve project
autoloads such as `Log`; gdUnit scene runs load the project context.

Commands run 2026-06-17 for the custom Performance monitor slice:

```powershell
python .agents/skills/performance-observatory/scripts/perf_observatory_scan.py --root .
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/run_tests.tscn -- --test res://tests/unit/test_streaming_custom_performance_monitors.gd
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/run_tests.tscn -- --test res://tests/unit/test_benchmark_mode_metadata.gd
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://scenes/Godotwind.tscn
python .agents/skills/performance-observatory/scripts/perf_observatory_scan.py --root .
```

All focused gdUnit runs exited 0. The real-renderer `scenes/Godotwind.tscn`
smoke stayed open for the 20-second startup window and closed cleanly. No C#
build was required because no C# files changed. Shader cache/import artifacts
were not cleared because no `.glsl`, `.gdshader`, or `.gdshaderinc` files
changed.

## Next Best Action

Use the new warm-start attribution report to pick one loading optimization
target. The cleanest next slice is to split the 6.273 s
`post_init_to_boot_gate_ms` bucket inside `world_explorer` /
`NativeStreamingManager.set_camera()`, then choose between the largest named
loading owners: ready-to-init delay (8.139 s), post-init camera/streaming
handoff (6.273 s), terrain/horizon startup (4.166 s), ESM GDScript
populate/supplement (4.358 s), or boot-gate wait/publication (6.658 s wall
clock with 2.350 s accumulated CellManager publication work). Do not tune
shared streaming budgets or migrate broad files to C# until the same
warm-start report shows the chosen owner improving.
