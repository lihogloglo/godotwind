# Performance Observatory State

Last updated: 2026-06-15

Purpose: durable state for Godotwind Pillar 3.0, the benchmark/debug/
diagnostic foundation for the merged Pillar 3/5 performance and loading arc.
When the user says "Performance Observatory, continue", "Pillar 3.0,
continue", "benchmark foundation", or similar, use the repo-local skill:

- `.agents/skills/performance-observatory/SKILL.md`

## Current Status

Not started beyond pipeline setup.

Pillar 3.0 should begin only after the current Pillar 2 boundary work is at a
stable handoff point, unless the user explicitly asks to run an observability
slice in parallel.

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

1. Run the static observability inventory:
   `python .agents/skills/performance-observatory/scripts/perf_observatory_scan.py --root .`
2. Produce the first coverage matrix:
   scenario x metric x report output x current owner.
3. Decide the benchmark report contract:
   required fields, validity flags, baseline path, comparison shape, and
   human summary shape.
4. Identify the smallest instrumentation gap that blocks future optimization.
5. Only then implement one narrow instrumentation slice.

## Proposed Prompt

```text
Performance Observatory, continue.

Do not optimize runtime code yet. Read the performance observatory state and
charter, run the static scan, inventory current benchmark/debug/loading
diagnostic coverage, and propose the next smallest instrumentation slice needed
before Pillar 3/5 optimization.
```

## Verification Expectations

- Audit-only slices: static scan plus updated state/charter docs.
- Instrumentation slices: focused gdUnit tests for report shape/threshold
  behavior, and a narrow real-renderer benchmark or smoke if runtime collection
  changed.
- C# touched: `dotnet build Godotwind.sln` before Godot launch.
- Shader touched: follow the shader cache/import rule in `AGENTS.md`.

## Next Best Action

Wait for Pillar 2 to settle, then run the first audit-only Pillar 3.0 slice:
inventory current observability and produce the scenario/metric/report coverage
matrix. Do not start performance optimization yet.
