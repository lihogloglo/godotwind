# Performance Observatory Coverage Matrix

Date: 2026-06-17

Scope: first Pillar 3.0 audit slice after Pillar 2 handoff. This is an
observability inventory only; no runtime optimization was performed.

Evidence:

- `reports/performance_observatory_scan.md`
- `reports/performance_observatory_scan.json`
- `docs/systems/benchmarking.md`
- `docs/systems/loading.md`
- `docs/systems/model_loading.md`
- `tests/benchmark/benchmark_thresholds.gd`
- `docs/STATUS.md`

## Scan Summary

All known benchmark/loading diagnostic surfaces are present. The static scan
found:

| Category | Hits |
|---|---:|
| `benchmark_runner` | 643 |
| `hot_path_gdscript_signal` | 4068 |
| `loading_metric` | 665 |
| `memory_or_leak_metric` | 191 |
| `native_or_csharp_surface` | 1730 |
| `performance_builtin_monitor` | 64 |
| `performance_custom_monitor` | 5 |
| `pipeline_compile_metric` | 45 |
| `streaming_metric` | 1815 |
| `structured_report` | 1349 |

Inferred gaps:

- Static GDScript hot-path candidates exist, but C# migration still needs
  benchmark/profiler evidence before any rewrite.

## Scenario Coverage Matrix

Legend:

- `Good`: existing scenario and reports are enough for baseline use.
- `Partial`: useful data exists, but scenario naming, validity, or report shape
  is incomplete.
- `Missing`: no dedicated scenario/report exists yet.

| Scenario | Current coverage | Metric coverage | Report output | Current owner | Gap |
|---|---|---|---|---|---|
| `cold_start` | Partial | `_ready`, `_init_async`, loading gate duration, startup queue logs | Console/log only | `world_explorer.gd`, `loading_state_machine.gd`, `native_streaming_manager.gd` | Needs JSON summary and cold-cache validity marker. |
| `warm_start` | Missing | Same counters as cold start can be reused | None | none | Needs same startup report with warmed cache flag. |
| `first_playable` | Partial | `loading_finished(reason, duration_s, timed_out)`, `mark_first_playable`, queue cap stats | Console/log only | `loading_state_machine.gd`, `world_explorer.gd`, `native_streaming_manager.gd` | Needs persisted summary field and timeout/validity status. |
| `first_exterior_cell` | Partial | loaded cells, visual-ready cells, queue size, async requests | Console/HUD/benchmark CSV when flyby runs | `native_streaming_manager.gd`, `streaming_benchmark.gd` | Needs named scenario separate from flythrough. |
| `fast_travel_streaming` | Partial | post-teleport queue, frame ms, draw/object counts, streaming phases, object/resource/node/memory deltas | `bench_teleport.json`, `lifetime_probe_*.json` | `auto_bench_runner.gd`, `world_explorer.gd`, `lifetime_probe_report.gd` | Has first lifetime probe; still needs broader transition-loop coverage. |
| `flythrough_streaming` | Good | frame ms percentiles, draw calls, objects, primitives, queue, loaded cells, async requests, streaming phase timings, memory/video memory | CSV, events CSV, JSON summary | `streaming_benchmark.gd` | Needs formal scenario name in summary contract. |
| `interior_transition` | Missing | transition latency and cleanup not formalized | None | none | Needs narrow transition benchmark after exterior contract is stable. |
| `asset_cache_miss` | Partial | model/BSA/ESM caches expose stats in code | Logs/ad hoc `get_stats()` only | `model_loader.gd`, `bsa_manager.gd`, `esm_manager.gd` | Needs dedicated cache miss scenario and summary fields. |
| `asset_cache_hit` | Partial | model/BSA/ESM caches expose stats in code | Logs/ad hoc `get_stats()` only | `model_loader.gd`, `bsa_manager.gd`, `esm_manager.gd` | Needs paired hit/miss comparison. |
| `hlod_enabled` | Partial | HLOD counts, chunks, surfaces, materials, handoff coverage in stress CSV | `bench_hlod_off.json`, stress CSV/JSON, HLOD visual tests | `auto_bench_runner.gd`, `streaming_stress_runner.gd`, `test_hlod_benchmark.gd` | Charter wants enabled scenario; current formal autobench names the ablation. |
| `near_only` | Partial | benchmark mode metadata tracks disabled tiers; `--near-only` exists | Benchmark/stress summaries when manually run | `native_streaming_manager.gd`, benchmark runners | Needs a named scenario/report preset. |
| `stress_dense_exterior` | Partial | dense/static workload sampled by `bench_tiers`; stress runner has broad metrics | `bench_tiers.json`, stress CSV/JSON | `auto_bench_runner.gd`, `streaming_stress_runner.gd` | Needs charter-aligned scenario name and density/location metadata. |
| `stress_rapid_cell_crossing` | Good | frame spikes, queue, async, phase timings, FAR/MID/HLOD/distant-light metrics, failure reasons | stress CSV, events CSV, JSON summary | `streaming_stress_runner.gd` | Needs inclusion in one normalized report index. |

## Metric Family Coverage

| Metric family | Current coverage | Main surfaces | Gap |
|---|---|---|---|
| Time/frame | Good | `streaming_benchmark.gd`, `streaming_stress_runner.gd`, `performance_profiler.gd`, `benchmark_hud.gd` | Startup reports need the same persisted shape. |
| Loading/startup | Partial | `loading_state_machine.gd`, `world_explorer.gd`, `native_streaming_manager.gd` | Console/log oriented; missing JSON and cold/warm validity flags. |
| Streaming | Good | `native_streaming_manager.gd`, `streaming_benchmark.gd`, `streaming_stress_runner.gd`, `streaming_profiler.gd` | Not exposed as Godot custom monitors. |
| Rendering | Good | Godot `Performance` monitors, benchmark CSV/JSON, HUD | Pipeline compile deltas are separate, not normalized into benchmark summaries. |
| Memory/lifetime | Partial | `performance_profiler.gd`, benchmark CSV memory fields, stress summary, `lifetime_probe_report.gd` | Has built-in Performance-counter lifetime probe; no ObjectDB snapshot/compare slice yet. |
| Cache/prebake | Partial | `model_loader.gd`, `bsa_manager.gd`, `esm_manager.gd`, interaction shape cache stats | No formal hit/miss benchmark scenario. |
| Validity | Partial | `benchmark_mode_metadata`, stress failure reasons, threshold constants | Report fields differ by runner; no common schema. |
| Hot-path evidence | Partial | static scan hot-path list, benchmark/stress outputs | Needs report-backed C# migration candidates, not rewrites. |

## Report Contract Gap

Existing outputs are useful but not yet normalized:

- `StreamingBenchmark`: CSV, events CSV, JSON summary, per-segment stats,
  benchmark mode metadata.
- `AutoBenchRunner`: per-scenario JSON for tiers, teleport, HLOD ablation, plus
  delegated flyby output.
- `BenchLadderRunner`: one JSON with rung summaries and deltas.
- `StreamingStressRunner`: CSV/events/JSON with pass/fail and failure reasons.
- `ProgressiveBenchmark`: aggregate CSV plus per-pass flyby outputs.

The next report-contract slice should not invent a new runner. It should add a
small shared schema checklist and make each existing runner report these fields
when feasible:

- `schema`
- `scenario`
- `mode`
- `valid_for_performance_baseline`
- `invalid_reasons`
- `git_commit`
- `worktree_dirty`
- `renderer`
- `headless`
- `started_at`
- `duration_s`
- `summary`
- `threshold_failures`
- `raw_outputs`
- `baseline`
- `comparison`

## Next Smallest Evidence Slice

Produce a hot-path GDScript evidence report for future C# migration candidates.
Do not migrate runtime code, change budgets, or optimize behavior in that slice.

Proposed inputs:

- `reports/performance_observatory_scan.json`
- existing benchmark/stress summaries under `user://benchmark_results/`
- profiler/HUD surfaces listed in `docs/systems/benchmarking.md`

Verification for that slice:

- static scan,
- generated Markdown/JSON evidence report,
- updated `docs/audit/performance_observatory_state.md`.
