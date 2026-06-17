# Spring Cleanup Pillar 3.0 Charter: Performance Observatory

Date: 2026-06-15

## Purpose

Create the benchmark, diagnostic, and report foundation required before the
merged performance/loading optimization arc. Pillar 3.0 exists so future agents
do not optimize by intuition.

## Why This Exists

The original Spring cleanup listed performance and loading time as separate
pillars. They should be audited together because the same systems determine
both:

- asset IO and cache layout,
- Morrowind source parsing and prebake state,
- model/material/texture loading,
- startup and first-playable gates,
- streaming queues and frame budgets,
- HLOD/FAR/MID/NEAR publication,
- RenderingServer/MultiMesh/native Godot feature usage,
- C# versus GDScript hot paths,
- memory pressure and object lifetime.

Pillar 3.0 is the prerequisite: observability first, optimization second.

## Non-Goals

- Do not rewrite systems to C# during Pillar 3.0 without measured evidence.
- Do not tune budgets without a baseline and comparable scenario.
- Do not add a parallel benchmark framework if the existing benchmark tools can
  be normalized instead.
- Do not treat a single scripted flyby as complete performance truth.
- Do not treat headless/null-renderer FPS as acceptance evidence for rendering
  performance.

## Canonical Sources

- Godot `Performance` monitors: built-in time, render, memory, object, physics,
  navigation, and pipeline compilation counters.
- Godot custom performance monitors: project-specific live metrics.
- Godot profiler: diagnostic sessions, not always-on benchmark truth.
- Godot 4.6 ObjectDB snapshots: later leak/object-growth diagnostics.
- Godot server APIs: candidate native feature path for high-instance workloads,
  only after measurement identifies a bottleneck.

## Existing Godotwind Surfaces

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

## Required Scenario Coverage

Track these as named scenarios. If a scenario cannot be automated yet, record
the current manual/visual procedure and the missing instrumentation.

| Scenario | Purpose |
|---|---|
| `cold_start` | Fresh process/cache startup and source-data boot. |
| `warm_start` | Process startup with warmed imports/cache. |
| `first_playable` | Time until user can act without hidden critical work. |
| `first_exterior_cell` | First playable exterior cell population. |
| `fast_travel_streaming` | Large position jump / teleport streaming behavior. |
| `flythrough_streaming` | Realistic travel with cell crossings. |
| `interior_transition` | Door/pocket loading latency and cleanup. |
| `asset_cache_miss` | First-time model/material/texture load cost. |
| `asset_cache_hit` | Reuse path after cache is warm. |
| `hlod_enabled` | Optional HLOD cost and warmup behavior. |
| `near_only` | NEAR gameplay/rendering baseline without distant tiers. |
| `stress_dense_exterior` | Dense visible/static workload. |
| `stress_rapid_cell_crossing` | Queue pressure under repeated crossings. |

## Required Metric Families

- Time: frame ms, physics ms, p50/p95/p99/p99.9, blocking frames, spikes.
- Loading: process start, `_ready`, `_init_async`, first playable, loading gate
  duration, queue drain, timeout flags.
- Streaming: queue depth, async requests, loaded cells, phase timings,
  publication budget used, pending worker tasks, sync fallback count.
- Rendering: draw calls, objects in frame, primitives, VRAM, texture memory,
  pipeline compilation deltas.
- Memory/lifetime: static memory, object/resource/node/orphan counts, later
  ObjectDB snapshot diffs.
- Cache/prebake: model/cache hit and miss counts, BSA/ESM relevant counters,
  sidecar hit/miss where available.
- Validity: benchmark mode metadata, sync fallback invalidity, disabled tiers,
  renderer/headless status, scenario name, seed/path/version info.

## Report Contract

Every formal benchmark or diagnostic run should produce:

- machine-readable JSON summary,
- optional CSV timeseries for per-frame analysis,
- short Markdown/plain-English summary,
- scenario name,
- git/worktree context when possible,
- benchmark validity status,
- baseline comparison when a baseline exists,
- top regressions/improvements,
- threshold failures with explicit reasons,
- paths to raw logs/reports.

Future agents should be able to consume this without opening the game or asking
the user to interpret graphs.

## Hot-Path Language Rule

C# is preferred for binary parsing, streaming pipelines, math-heavy systems,
large data structures, worker-thread code, and per-frame work over many items.
GDScript remains appropriate for thin Godot orchestration, UI/debug panels,
console commands, editor shims, and tests.

Migration rule: prove heat first. A GDScript file is a C# candidate only when
benchmark/profiler/static evidence shows per-frame loops, large collection
work, parsing, worker coordination, or repeated allocation cost that matters.

## First Implementation Slices

1. Audit-only inventory and coverage matrix.
2. Report contract normalization: scenario names, validity fields, baseline
   comparison fields, and summary shape.
3. Loading-time baseline: cold/warm/first-playable timestamps and comparison
   output.
4. Custom Performance monitors for live Godotwind streaming/loading metrics.
5. Object/memory lifetime probe for repeated load/unload or transition loops.
6. Hot-path GDScript evidence report for the later C# migration arc.

## Acceptance

Pillar 3.0 is complete when future agents can run one short prompt, collect
current benchmark/diagnostic evidence, compare it with prior baselines, and
explain which subsystem is expensive or which metric is missing before
optimizing.
