# Benchmark Framework v2 — Plan

**Status:** draft
**Date:** 2026-04-14
**Author:** @docs (reviewer)
**Supersedes:** `docs/audit/BENCHMARK_FRAMEWORK_PLAN.md`

---

## Why v2 (what v1 got wrong)

v1 shipped a cross-session isolation benchmark: N+1 separate game launches, each disabling one subsystem, aggregated into a ranked cost report. Over one session of use three problems surfaced:

1. **Cross-session isolation is a CI pattern, not an interactive perf tool.** Every shipped game engine profiler (Unreal `stat`, Unity Profiler, Source `r_*` cvars, id Tech `r_*`) works in-session: developers toggle features live on a running game and watch the HUD. v1 inverted this — requiring a full process restart per subsystem is a regression-testing pattern we shoehorned into interactive investigation.

2. **The scripted flyby is not representative of player experience.** Current waypoints orbit at ~125 m/s and sprint at ~120 m/s — ~450 km/h. Real Morrowind traversal is 3-8 m/s. The v1 benchmark stress-tests streaming throughput, not steady-state rendering. User feedback (2026-04-14 08:50): *"the flyby is a bit fast, almost never a user will play like that."*

3. **The auto-benchmark CLI coupled benchmark runs to a crash-prone async-load path.** Any instability in streaming (see `MODEL_LOADER_RACE.md`) blocks the entire measurement pipeline. A benchmark tool should not depend on the systems it measures being crash-free.

v2 inverts all three: **in-session, realistic speeds, decoupled from crash-prone systems.**

---

## Goals

- Measure per-subsystem cost in a single game launch via live toggling
- Waypoints reflect actual player movement (walk/run/vista/pan at human speeds)
- Live HUD for interactive exploration — user drives, reads numbers
- Optional scripted progressive run for reproducibility / CI
- Does not depend on async streaming being crash-free (measurement works even if streaming has bugs)

Non-goals:
- No GPU profiler, no memory leak detector, no custom profiler GUI (Godot built-ins suffice)
- No cross-session historical comparison automation (keep manual for now — JSON summaries already exist)

---

## DELETE (v1 code to remove)

| File / symbol | Reason |
|---|---|
| `streaming_benchmark.gd::_init_standalone()` + `_setup_environment()` + `_setup_camera()` | Standalone mode was a parallel init path; v2 always attaches to the running world_explorer. ~80 lines. |
| `streaming_benchmark.gd::init_isolate_mode()` + `_start_isolate_pass()` + `_process_isolate_settle()` + `_on_isolate_pass_complete()` + `_finish_isolate()` + `_save_isolate_csv()` + `register_isolate_command()` + isolation state vars | Cross-session isolation is the wrong methodology. ~200 lines. |
| `streaming_benchmark.gd::init_lod_sweep()` + `_start_sweep_pass()` + `_on_sweep_pass_complete()` + `_finish_sweep()` + `_save_sweep_csv()` + LOD sweep state vars + `LOD_SWEEP_THRESHOLDS` | Single-metric sweep belongs in a one-off dev tool, not the benchmark harness. If we need it again, hand-roll. ~150 lines. |
| `streaming_benchmark.gd::_quick_mode` branch logic in `_build_waypoints()` | v2 has ONE waypoint set (realistic). No quick/full split. |
| `world_explorer.gd::_auto_run_benchmark()` + `_auto_run_isolate()` + the `--benchmark` / `--benchmark-isolate` CLI arg handling at `:454-462` | CLI auto-mode coupled measurement to crash-prone streaming init. v2 is interactive-only. ~50 lines. |
| `console.register_command("benchmark_isolate" ...)` + `benchmark_lod_sweep` + their aliases | Orphaned after the function deletes above. |

**Expected net shrink:** `streaming_benchmark.gd` from 1404 → ~600 lines. `world_explorer.gd` from current → ~50 lines lighter.

---

## KEEP (v1 code that stays)

- `src/tools/subsystem_toggles.gd` — clean RefCounted, 170 lines. No changes needed. The `toggle` console command stays as the primary user-facing control.
- `streaming_benchmark.gd` per-frame metric capture (`_log_frame()`, `_get_mid_tier_stats()`, `_get_promoted_count()`, `_sample_visibility()`, the 29-column CSV format). These are solid — only the orchestration around them changes.
- `_calculate_results()` aggregate stats (min/avg/p50/p95/p99/max FPS + frame time). Move verbatim.
- `_save_csv()` + `_save_events_csv()` + `_save_json_summary()`. Move verbatim.
- CSV output path `user://benchmark_results/`.
- Console command plumbing via `CommandRegistry.ParameterInfo`.

---

## NEW (v2 additions)

### 1. Realistic waypoints

Replace `_build_waypoints()` with player-speed segments at Seyda Neen:

| Segment | Duration | Motion | Purpose |
|---|---|---|---|
| Settle | 10s | still | Wait for streaming queue to drain post-launch |
| Idle (village) | 15s | still, ground-level | Pure render cost in dense geometry |
| Walk | 25s | 7 m/s straight-line traverse through village | Steady streaming at walking pace |
| Vista | 10s | still, 80m altitude overlooking landscape | FAR-tier / impostor render load |
| Pan | 10s | 360° rotation in place | Frustum-culling cost |
| Run | 15s | 15 m/s traverse | Stressed streaming throughput |

Total: 85s per flyby (vs 18s in v1). Fewer samples, more representative.

No `_quick_mode` toggle — this is THE waypoint set. If someone needs 15s for a quick check, they use the live HUD, not a scripted run.

### 2. Live HUD overlay

New `BenchmarkHUD` Control (CanvasLayer, ~200 lines). Always available, toggled by console command or key:

- **Current frame:** instantaneous FPS, frame time, draw calls
- **Rolling 5s window:** avg FPS, p95 frame time
- **Memory:** VRAM used (MB), texture memory (MB), total ObjectDB instance count
- **Streaming state:** loaded cells, queue size, async requests in flight
- **Active toggles:** compact list of currently-disabled subsystems (e.g. `[OFF: ocean, characters]`)

User flies the camera manually, toggles subsystems via `toggle <name>`, reads the HUD. This is the primary workflow.

Console commands:
- `hud` — toggle HUD visibility
- `hud_reset` — clear rolling window, start a fresh measurement

### 3. Manual measurement blocks (user-driven)

For when the user wants to capture a specific gameplay moment (e.g. "stand at village center for 30s and record"):

- `bench_start [label]` — begin a timestamped measurement block, accumulates per-frame metrics to buffer
- `bench_stop` — stop measurement, print aggregate summary to console (avg/p95/max FPS + frame time, draw calls, VRAM), save CSV + JSON

No scripted camera movement — the user drives. The harness only records what the user does. This is the "HUD but persistent" mode.

### 4. Automated progressive run (reproducibility)

`bench_progressive` console command runs the realistic waypoints through N toggle states in one session:

1. `toggle none` + 85s flyby → baseline (empty world)
2. `toggle terrain` + 85s flyby → terrain-only cost
3. `toggle near_objects` + 85s flyby → terrain + NEAR geometry
4. `toggle mid_objects` + 85s flyby → + MID tier
5. `toggle impostors` + 85s flyby → + FAR tier
6. `toggle hlod` + 85s flyby → + HLOD cells
7. `toggle shadows` + 85s flyby → + shadows
8. `toggle postfx` + 85s flyby → + TAA/SSAO/SSIL/glow/godrays/vfog
9. `toggle sky` + 85s flyby → + sky
10. `toggle weather` + 85s flyby → + weather
11. `toggle characters` (if desired) + 85s flyby → + NPCs

Total wall-clock: ~15-16 min. One launch. Additive protocol — each measurement shows the DELTA of adding THAT subsystem to the stack.

Output: `progressive_<timestamp>.csv` with one row per flyby (the aggregate summary) + per-frame CSV under a subdirectory.

**Important nuance for users to understand:** additive-on-a-hot-session is NOT the same as cross-session isolation. VRAM and atlases allocated during earlier toggle states may remain resident when a subsystem is re-disabled later. The RENDERING cost delta is what we measure; the ALLOCATION cost is not captured by this protocol. That trade-off is acceptable because allocation cost matters at launch, rendering cost matters at play-time, and play-time is what we're optimizing.

---

## Protocol for the first v2 measurement (once built)

1. Launch game normally (no CLI args)
2. Wait for streaming to drain (HUD shows queue=0)
3. `hud` — show overlay
4. `bench_progressive` — auto-run the 11-state additive protocol (~16 min)
5. Review `progressive_<timestamp>.csv` — each row is "rendering cost of the stack up to and including this subsystem"
6. Delta between adjacent rows = cost of THAT subsystem in realistic conditions

For ad-hoc investigation:
1. Launch, wait, `hud`
2. `toggle all`, fly around, read HUD
3. `bench_start village_dense` — record a named block
4. Stand at village center 30s
5. `bench_stop` — aggregate saved
6. `toggle ocean` off, repeat `bench_start / bench_stop` with same label suffix `_no_ocean`
7. Compare the two JSONs manually

---

## Implementation order

1. **Rip out v1 dead code first.** Delete isolation/sweep/standalone/auto-CLI modes before adding anything. This is the "clean up" the user asked for. One commit, net negative line count. Easy to review.
2. **New waypoints.** Rewrite `_build_waypoints()` with realistic speeds. Single segment set, no quick-mode branch.
3. **HUD overlay.** Build `benchmark_hud.gd` as a Control scene. Wire to console `hud` / `hud_reset`.
4. **Manual measurement blocks.** `bench_start` / `bench_stop` — reuse existing `_log_frame()` + `_calculate_results()` + `_save_csv()` + `_save_json_summary()`.
5. **Progressive auto-run.** `bench_progressive` orchestrator: drives SubsystemToggles through the 11 states, runs waypoints between each, accumulates results. ~150 lines.
6. **Update `docs/BENCHMARKING.md`** to reflect v2 surface. Remove references to isolation/sweep/auto-CLI.

Steps 1-2 can ship in one commit. Steps 3-4 in a second. Step 5 in a third. Step 6 alongside whichever commit ships first.

---

## Success criteria

- `streaming_benchmark.gd` net line count reduced (v1: 1404 → v2 target: ~600)
- Zero `--benchmark` / `--benchmark-isolate` CLI entries in `world_explorer.gd`
- Live HUD shows updating numbers while user flies; values match Godot's `Performance` singleton
- `bench_progressive` runs 11 toggle states in a single launch without process restart
- `bench_start` / `bench_stop` produces CSV + JSON with user-named labels
- Realistic flyby waypoints measured with a stopwatch match the documented speeds (7 m/s walk, 15 m/s run) within 10%
- No regression in v1's metric capture (29 CSV columns still populated correctly)

---

## What v2 explicitly does NOT do

- No CI automation hook (manual use only for now)
- No historical trend graph (JSON summaries accumulate, reader is the human)
- No per-drawcall / per-shader breakdown (use RenderDoc)
- No memory leak detection (use ObjectDB snapshots)
- No cross-platform config — Windows / laptop hardware only for initial pass
- No re-entrant benchmark (starting one while another is running returns an error)

---

## Open questions for @user before implementation

1. **Toggle order in `bench_progressive`** — proposed additive order above is: terrain → near → mid → impostors → hlod → shadows → postfx → sky → weather → characters. Is this the right build-up order, or do you want a different stack (e.g. characters first because they're the cheapest, or weather before postfx)?
2. **Default HUD visibility** — always-on overlay in normal play, or hidden by default and shown on `hud` command?
3. **Waypoint location** — Seyda Neen is the v1 default. Want v2 to use Balmora or Vivec instead for denser geometry, or keep Seyda Neen?
4. **Flyby duration knobs** — 85s feels right to me for realism, but is that too long per measurement? If you want 45-60s flybys I'll scale the segments proportionally (7 m/s walk stays 7 m/s, distances shrink).

@coder — this is the plan. Review before implementing. Standard checkpoint flow: plan review now, implementation draft review after each commit.

@user — confirm the 4 open questions and give implementation the green light.
