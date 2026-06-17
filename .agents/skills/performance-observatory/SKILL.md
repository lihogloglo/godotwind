---
name: performance-observatory
description: Build and continue Godotwind Pillar 3.0 Performance Observatory work: benchmark, profiling, debug metrics, loading-time diagnostics, agent-readable reports, baselines, and C#/native Godot hot-path evidence. Use when the user says "Performance Observatory", "Pillar 3.0", "benchmark foundation", "diagnostic suite", "performance pipeline", "loading benchmark", "perf observability", or asks to prepare/continue performance work before optimization.
---

# Performance Observatory

## Purpose

Use this skill before optimizing Godotwind performance. The goal is to make
agents stop guessing: collect trusted benchmark/debug evidence, compare against
baselines, attribute costs by subsystem, and make reports readable by future
agents and the user.

Pillar 3.0 is the foundation for the merged Pillar 3/5 arc:
performance, streaming, loading time, hot-path C# migration, and native Godot
feature adoption.

## Start Here

Always read these files first:

1. `docs/audit/performance_observatory_state.md`
2. `docs/audit/spring_cleanup_pillar_3_0_performance_observatory_charter_2026_06_15.md`
3. `docs/systems/benchmarking.md`
4. `docs/systems/loading.md`
5. `docs/systems/model_loading.md`
6. `tests/benchmark/benchmark_thresholds.gd`
7. `docs/STATUS.md`

Then run the deterministic inventory:

```powershell
python .agents/skills/performance-observatory/scripts/perf_observatory_scan.py --root .
```

If the user says "Performance Observatory, continue" or "Pillar 3.0,
continue", do not ask for a longer prompt. Read the state file, run the scan,
and choose the next unfinished slice.

## Workflow

1. Check `git status --short` and note unrelated dirty worktree changes.
2. Read the state and charter docs listed above.
3. Run `perf_observatory_scan.py`.
4. Classify the current observability surface:
   - scenario benchmark coverage,
   - Godot `Performance` monitor usage,
   - custom monitor coverage,
   - profiler/debug HUD coverage,
   - startup/loading-time metrics,
   - streaming queue/frame-budget metrics,
   - memory/ObjectDB/leak diagnostics,
   - baseline comparison/report shape,
   - hot-path GDScript evidence for possible C# migration,
   - native Godot feature evidence before custom rewrites.
5. Do not optimize runtime code during a Pillar 3.0 audit slice unless the
   state file explicitly authorizes a tiny instrumentation fix.
6. Prefer agent-readable JSON/CSV/Markdown evidence over prose-only findings.
7. Update `docs/audit/performance_observatory_state.md` before finishing.
8. Save a short memory note with completed slice, evidence path, next action,
   and verification status.

## Output Rules

For audit-only work, produce:

- observability inventory,
- benchmark/debug coverage matrix,
- missing metrics and why they matter,
- report-consumption contract for future agents,
- baseline/comparison gaps,
- hot-path evidence needed before C# migration,
- native-Godot feature opportunities that need measurement first,
- next small implementation slice.

For implementation work, keep slices small and verify the changed path:

- instrumentation-only GDScript: focused gdUnit for report shape plus a narrow
  benchmark/smoke if runtime collection changed,
- C# touched: `dotnet build Godotwind.sln` before any Godot launch,
- benchmark runner touched: focused runner tests plus one narrow real-renderer
  launch if feasible,
- shader touched: follow `AGENTS.md` shader cache/import rules.

## Measurement Principles

- Measure before optimizing.
- Separate runtime frame performance from startup/loading latency.
- Separate cold-cache, warm-cache, and hot-session results.
- Treat Godot editor profiler output as a diagnostic aid, not as the only
  benchmark truth; profiling has overhead.
- Use Godot `Performance.get_monitor()` for built-in time, memory, object,
  render, physics, navigation, and pipeline-compilation counters.
- Add custom `Performance.add_custom_monitor()` metrics for Godotwind-specific
  values such as streaming queue depth, loaded cells, async requests, cache hit
  rates, frame-budget consumption, first-playable timing, and loading gates.
- Prefer report summaries that fail loudly on invalid modes, especially sync
  fallback paths that are not valid performance baselines.
- Do not rewrite GDScript to C# by ideology. First prove the GDScript is a hot
  path or data-heavy path, then migrate or replace it with native Godot APIs.

## Scenario Matrix

Use these scenario names unless the charter/state supersedes them:

- `cold_start`
- `warm_start`
- `first_playable`
- `first_exterior_cell`
- `fast_travel_streaming`
- `flythrough_streaming`
- `interior_transition`
- `asset_cache_miss`
- `asset_cache_hit`
- `hlod_enabled`
- `near_only`
- `stress_dense_exterior`
- `stress_rapid_cell_crossing`

## Subagent Pattern

Use subagents only when the user explicitly asks for agent/parallel work or the
current Codex session exposes subagent tooling. Keep assignments bounded:

- Godot expert: verify Performance/custom monitor/profiler usage.
- Open-world expert: verify streaming, LOD, HLOD, and loading scenarios.
- Critic: hunt measurement holes, invalid baselines, and self-perturbing tools.
- Implementation worker: only after the charter names a small instrumentation
  slice.

Synthesize subagent reports into the state doc. Do not treat any subagent
answer as truth without checking key evidence.

## References

Read `references/godot_performance_observability.md` when you need the source
backing for Godot Performance monitors, custom monitors, profiler limits,
startup profiling, ObjectDB snapshots, or server-direct optimization notes.
