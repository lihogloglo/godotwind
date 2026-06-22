---
name: fastospeedo
description: Continue Godotwind FPS and cell-boundary stutter optimization with evidence-first benchmark slices. Use when the user says "fastospeedo", "continue improving performances", "improve FPS", "reduce stuttering", "cell boundary stutter", or asks for measured performance optimization using the diagnostics pass, automated benchmark, bench ladder, or runtime streaming diagnostics.
---

# Fastospeedo

## Purpose

Use this skill to continue Godotwind runtime performance work in independent
slices. The workflow is evidence first: run the existing diagnostics, identify
one measured owner, apply the smallest native-first fix, then rerun the same
scenario before claiming an improvement.

This skill is an optimization layer over `performance-observatory`; use both
when the observatory skill is available.

## Start Here

1. Use `ponytail` first; keep the diff small.
2. Read:
   - `docs/audit/fastospeedo_state.md`
   - `docs/audit/performance_observatory_state.md`
   - `docs/systems/benchmarking.md`
   - `docs/systems/loading.md`
   - `docs/systems/model_loading.md`
   - `docs/systems/distance_rendering.md`
   - `tests/benchmark/benchmark_thresholds.gd`
   - `docs/STATUS.md`
3. Run:

```powershell
git status --short
python .agents/skills/performance-observatory/scripts/perf_observatory_scan.py --root .
```

4. If C# files are already dirty or will be changed, run `dotnet build
   Godotwind.sln` before any Godot launch.

## Evidence Workflow

Use the most specific existing runner. Do not invent a new benchmark unless a
report cannot answer the current question.

- Runtime FPS and cell-boundary stutter: run `--bench-auto <stamp>`.
- Subsystem render cost: run `--bench-ladder <stamp>`.
- Startup or first-playable latency: run `--loading-baseline=warm_start` or the
  scenario named in the state file.
- Object/memory lifetime after transitions: run `--lifetime-probe`.
- Shader or first-visibility stutter: inspect existing pipeline compilation
  counters and logs before changing shader warmup.

Default runtime commands:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://scenes/Godotwind.tscn -- --bench-auto fastospeedo_YYYY_MM_DD
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://scenes/Godotwind.tscn -- --bench-ladder fastospeedo_YYYY_MM_DD
```

Close any previous Godot process before launching another scene/window.

## How To Read The Reports

Start with the structured JSON under:

`%APPDATA%/Godot/app_userdata/Godotwind/benchmark_results/`

Prefer report fields over log impressions:

- frame health: `avg_fps`, `p95_ms`, `p99_ms`, `threshold_failures`
- cell-boundary spikes: `stream_total_ms`, `phase_inst_us`, queue depth,
  frames over `BenchmarkThresholds.SPIKE_FRAME_MS`
- lane ownership: `pub_<lane>_spent_us`, `pub_<lane>_overrun_us`
- render cost: draw calls, rendered objects, primitives, VRAM/texture memory
- shader stutter: pipeline draw/surface/mesh deltas; draw deltas during play are
  the strongest first-visibility stutter signal

Current known runtime lead: latest accepted evidence points at
`pub_near_gameplay_spent_us` inside `CellManager.process_async_instantiation()`,
not static/HLOD/FAR budget tuning. Recheck the state file before acting.

## Optimization Ladder

For every candidate fix, name the canonical pattern before editing:

1. Godot native feature: visibility ranges, automatic mesh LOD, MultiMesh,
   RenderingServer/PhysicsServer APIs, `ResourceLoader.load_threaded_request`,
   WorkerThreadPool, pipeline precompilation/warmup, built-in monitors.
2. Battle-tested engine pattern: World Partition/level streaming, Addressables,
   OpenMW-style bounded cell preloading, data-oriented batching.
3. Existing project system: current streaming lanes, model cache, static buckets,
   cell preloader, report contract.
4. C# migration or native extension only after the report proves GDScript is
   the hot owner.
5. Bespoke code last, and only when the state file explains why the above do
   not fit.

Never tune shared budgets, port broad files, or add new abstraction because a
metric "looks bad" once. Isolate the owner, then make one small change.

## Slice Contract

Each optimization slice must leave:

- before evidence path,
- changed owner and canonical pattern,
- after evidence path from the same scenario,
- practical effect in plain English,
- state update in `docs/audit/fastospeedo_state.md`,
- any needed update to `docs/audit/performance_observatory_state.md`.

If a slice is diagnostic-only, say that no runtime optimization was performed.

## Verification

- GDScript report/instrumentation change: focused gdUnit for report shape plus
  the narrow benchmark/smoke that exercises collection.
- Runtime streaming/rendering change: same-scenario benchmark before and after.
- C# change: `dotnet build Godotwind.sln`, then benchmark/visual launch.
- Shader change: follow `AGENTS.md` shader cache/import clearing before visual
  verification, and report whether cache/import artifacts were cleared.
- If a benchmark cannot run, record the exact blocker in the final response and
  in `docs/audit/fastospeedo_state.md`.

