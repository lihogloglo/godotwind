# Performance Observatory Hot-Path GDScript Evidence

Date: 2026-06-18

Scope: evidence report only. No runtime optimization, C# migration, budget
tuning, cache-policy change, or benchmark-runner behavior change was performed.

## Evidence Inputs

- `python .agents/skills/performance-observatory/scripts/perf_observatory_scan.py --root .`
- `reports/performance_observatory_scan.md`
- `reports/performance_observatory_scan.json`
- `docs/systems/benchmarking.md`
- `docs/systems/loading.md`
- `docs/systems/model_loading.md`
- `tests/benchmark/benchmark_thresholds.gd`
- `docs/STATUS.md`
- Existing real-renderer reports under `user://benchmark_results/`, especially:
  - `loading_baseline_warm_start_2026-06-17_22-22-19.json`
  - `loading_baseline_first_playable_2026-06-17_22-32-27.json`
  - `lifetime_probe_fast_travel_streaming_object_lifetime_probe_2026_06_17.json`
  - older stress/flyby summaries from May 2026
- Archived flyby CSV/JSON under `docs/archive/audit/perf-reports/`

The scan is static. It identifies likely heat, not proof of user-visible cost by
itself. Candidate rank below uses static signals plus existing runtime evidence.

## Current Runtime Evidence

Recent loading-baseline reports show the first-playable path is still a valid
place to look before any migration:

| Evidence | Value |
|---|---:|
| Warm start process-to-first-playable | 41.263 s |
| First-playable process-to-first-playable | 39.985 s |
| ESM primary load phase | 7.876-8.679 s |
| Horizon maps phase | 3.953-4.068 s |
| Terrain data load phase | 1.044-1.150 s |
| BSA archives phase | 1.034-1.095 s |
| Warm-start publication spent at sample | 7.251 ms of 8.0 ms budget |
| First-playable publication spent at sample | 10.076 ms of 8.0 ms budget |
| Warm-start frame overrun count at sample | 148 |
| First-playable frame overrun count at sample | 180 |
| Lifetime probe static memory delta after 2 teleports | +272.08 MB |
| Lifetime probe object delta after 2 teleports | +31,061 |
| Lifetime probe orphan node delta after 2 teleports | +283 |

Archived 85 s flyby CSVs also show streaming work can matter during play:

| Run | Avg FPS | p95 frame | Max frame | stream_total_ms avg | stream_total_ms p95 | stream_total_ms max |
|---|---:|---:|---:|---:|---:|---:|
| 2026-04-17 flyby | 53.92 | 35.646 ms | 141.334 ms | 6.595 ms | 15.460 ms | 304.190 ms |
| 2026-04-18 flyby | 48.33 | 54.430 ms | 144.931 ms | 7.063 ms | 21.360 ms | 370.630 ms |

Those archived runs predate later refactors, so treat them as historical heat
evidence, not current acceptance numbers.

## Ranked Candidates

| Rank | Candidate | Evidence | Migration read |
|---:|---|---|---|
| 1 | `src/core/world/cell_manager.gd` | 4,630 LOC, 67 `for` loops, 10 `while` loops, 22 `WorkerThreadPool` references. Owns `process_async_instantiation()` and static collision build/publish work. Archived flybys show `phase_inst_us` p95 6.158-8.450 ms and max 39.981-47.803 ms. | Strongest future C# candidate, but only for data transforms / queue kernels / collision payload prep. Scene-tree publication must stay main-thread Godot code. |
| 2 | `src/core/world/native_streaming_manager.gd` | 3,793 LOC, `_process`, 47 loops, 17 `while` loops. Owns streaming publication lanes, budget accounting, custom monitors, distant-tier dispatch, load/unload queues, and first-playable stats. Recent loading reports show publication at 7.251-10.076 ms against an 8 ms transitional budget. | Candidate for extracting pure queue/lane planning kernels. Do not port the whole manager; it is orchestration-heavy and owns Godot lifecycle wiring. |
| 3 | `src/core/world/native_impostor_renderer.gd` | 3,038 LOC, `_process`, 53 loops, 15 `while` loops, 13 `WorkerThreadPool` references. Owns FAR impostor page scans, texture jobs, atlas uploads, and MultiMesh buffer packing. | Candidate when a FAR/impostor-specific benchmark shows CPU-side packing/upload prep is hot. Current first-playable reports have FAR mostly idle, so this needs a targeted scenario first. |
| 4 | `src/core/world/static_object_renderer.gd` | 1,833 LOC, 52 loops, 18 RenderingServer references, 4 worker references. Owns MID static extraction, bucket state, RS visibility, and MultiMesh-style publication. Recent loading reports show ~331-340 MID draw groups and ~3,277-3,330 MID instances at first playable. | Candidate for native bucket/build data preparation. RenderingServer calls and RID lifetime should remain in GDScript owner code unless a measured server-direct redesign says otherwise. |
| 5 | `src/core/world/object_paging.gd` | 2,202 LOC, 61 loops, 13 `while` loops, 10 RenderingServer references. Owns HLOD chunk orchestration and publication; native merge kernel already exists. HLOD is default-off, so current first-playable reports do not prove active cost. | Candidate only after `hlod_enabled` evidence. Likely next work is measuring the existing native merge boundary, not migrating orchestration blindly. |
| 6 | `src/core/world/model_loader.gd` + `src/core/world/reference_instantiator.gd` | Model loader has 29 resource-load signals and async queues; reference instantiator has 22 RenderingServer references and comments tying interactives to 12-20 ms/ref overrun risk. Loading reports still show long first-playable time, pending disk loads, thousands of route calls, and proximity-deferred interactives. | Candidate for cache-hit/miss evidence and pure metadata/resource-index kernels. Node instantiation, callbacks, and main-thread scene publication should not be moved to C#. |
| 7 | `src/core/esm/esm_manager.gd` | Native ESM loading already exists, but loading-baseline reports show ESM primary load at 7.876-8.679 s. `docs/systems/dialogue.md` notes the GDScript supplement pass adds ~1.9 s to ESM load. | Candidate for closing remaining native-loader gaps or reducing C#->GDScript population work. This is startup latency, not per-frame heat. |
| 8 | `src/core/nif/nif_reader.gd` + `src/core/nif/nif_converter.gd` | NIF parse/mesh conversion has native paths, but GDScript fallback/prebake paths still have dense loops and record traversal. `nif_converter.gd` has 68 loop signals and a main-thread conversion tail. | Candidate for asset-cache-miss/prebake scenarios, not default hot runtime until reports show fallback conversion during play. |

## Defer Or Keep In GDScript

These files appeared in the scan but should not be C# migration targets yet:

| File/group | Reason |
|---|---|
| `src/tools/world_explorer.gd` | Large and hot-looking, but mostly scene orchestration, console commands, diagnostics, and feature wiring. Extract only measured kernels from owned subsystems. |
| Benchmark/report tools | `streaming_benchmark.gd`, `streaming_stress_runner.gd`, `debug_system.gd`, `debug_overlay.gd`, and report builders are measurement surfaces. Porting them risks perturbing diagnostics without improving gameplay. |
| `src/core/world/interior_pocket_manager.gd` | Static scan finds loops, but there is no formal `interior_transition` benchmark yet. Measure transition latency/cleanup first. |
| `src/core/water/ocean_fft_provider.gd` | Water/ocean is framework-ready but not the accepted main-world production path. Use a water-specific benchmark before migration. |
| Prebaking/test scripts | `prebaking_manager.gd`, `model_prebaker.gd`, `impostor_baker_v3.gd`, and test drivers are offline/tooling paths unless they block asset-cache-miss acceptance. |
| `shader_manager.gd` | Hot-path heuristic false positive: shader orchestration and hot-swap management, not a current frame/data kernel. |

## Migration Guardrails

- Do not migrate by file size. Migrate only a measured function/kernel.
- Prefer native Godot APIs first when the cost is instance visibility, LOD,
  MultiMesh, worker loading, or server-direct publication.
- Keep scene-tree mutation, RID ownership, ResourceLoader callback handling,
  and main-thread Godot lifecycle code in the existing GDScript owners unless
  a focused benchmark proves that boundary is the problem.
- For candidate extraction, the useful C# shapes are small kernels:
  queue ranking, transform packing, page/bucket diffing, payload filtering,
  record conversion, and cache-index materialization.
- Every migration candidate needs before/after reports using the same scenario,
  renderer, validity flags, and dirty-worktree metadata.

## Next Evidence Needed Before Any C# Work

| Target | Missing evidence |
|---|---|
| CellManager / NativeStreamingManager | Current `flythrough_streaming` and `fast_travel_streaming` reports with lane timings normalized into `godotwind_performance_report_v1`. |
| FAR impostors | A named `asset_cache_hit` or `flythrough_streaming` run that reaches active FAR pages and persists `far_*_us` fields. |
| HLOD/object paging | A valid `hlod_enabled` run with merge queue, publish, draw group, and frame-time data. |
| ModelLoader / ReferenceInstantiator | Paired `asset_cache_miss` and `asset_cache_hit` scenarios with model/cache hit counts, callback counts, and instantiate queue timings. |
| ESM supplement | Loading-baseline split for native primary load vs GDScript supplement/population. |
| NIF fallback/prebake | Asset-cache-miss run showing whether GDScript NIF fallback happens during gameplay, or confirming it is offline-only. |

## Decision

The future C# migration lane should start with `cell_manager.gd` /
`native_streaming_manager.gd` evidence, not with broad rewrites. They have the
best overlap between static heat and existing runtime cost. The next step is a
targeted measurement slice; optimization remains out of scope for this report.
