# Autonomous Perf Audit — 2026-04-17_20-30-38

**Branch:** `perf/distant-rendering-2026-04-17`
**Commits covered:** `8f7d6f9..cdc73f4` (phase 3-7 refactor + handoff commits). Autobench harness itself committed at `392b13d`.
**Driver:** `claude` (via autonomous-perf-audit prompt in `#audit`).
**Rules followed:** real-renderer only (`<godot-executable> --path ...`, NOT `--headless`). No visual auto-capture. No patches — verification only. Pre-existing whitelists (shutdown sig 11, 9 paging-kernel test failures) respected.

## Pass/Fail matrix

| Test | Gate | Result | Key number |
|---|---|---|---|
| A. Log hygiene | zero new SCRIPT ERROR/Invalid/Parse/Identifier outside whitelist | **PASS** | 0 non-whitelist errors across both launches |
| B. Cold-start settle | time-to-stable-55 ≤ 20 s | **FAIL** | 170-180 s (both runs) |
| C. Static tiers populated | MID/HLOD/FAR all > 0 + steady FPS ≥ 50 | **PASS** | reg_batches=535 / t1=9,t2=7,cells=16 / impostors=51208 / fps_avg=50.97 |
| D. 85 s flyby segments | per-seg FPS + vista draws < 8000 + all p95 < 50 ms | **MIXED** | settle/idle/walk FAIL; vista/pan/run PASS; p95 walk=80ms, run=53ms |
| E. Teleport burst (940 m) | log line + fps≥50 in 15 s + no new errors | **PASS** | Teleport detected; fps≥50 at t=3.6s; 0 errors |
| F. HLOD-off debug | hlod_cells=0 + impostors hidden + no errors + rendered_objects < 500 | **PARTIAL** | chunks=0 ✓, imp hidden ✓, 0 errors ✓; rendered_objects=6231 (NEAR ring alone, gate likely obsolete) |

**Overall:** 2 PASS (A, C, E) · 1 PARTIAL (F) · 2 FAIL (B, D).

## Raw data

- `launch.log` — run 1, 215 s cold-cache real-renderer, manual graceful kill. Phase A/B source.
- `heartbeat.csv` — parsed streaming heartbeat every 5 s from run 1 (39 rows).
- `errors.txt` + `errors_all_uniq.txt` — grep of SCRIPT ERROR / Invalid / Parse Error / Identifier not found (empty) and all ERROR: lines (4 whitelisted).
- `warnings_uniq.txt` — unique warnings (whitelisted).
- `startup_milestone.txt` — single line `Startup phase complete after 57 frames`.
- `autorun.log` — run 2, 349 s, `--bench-auto 2026-04-17_20-30-38`. Phase C/D/E/F source.
- `bench_tiers.json` — Phase C sample data + summary.
- `bench_flyby/benchmark_*.csv` — Phase D per-frame CSV (4 600 rows, 29 cols).
- `bench_flyby/summary_*.json` — Phase D summary (avg/p50/p95/p99).
- `bench_flyby/events_*.csv` — cell-load / cell-unload / visibility-drop events.
- `bench_teleport.json` — Phase E sample data + summary (includes `first_fps_ge_50_after_s`).
- `bench_hlod_off.json` — Phase F sample data + summary.

## Headline findings

1. **Cold-start settle is the #1 regression from this refactor's acceptance envelope.** Phase 7 budget raise is correct for the burst window, but `_startup_phase` flips to false at frame 57 (~sec 27) and the subsequent 4 ms post-startup budget throttles the residual 100+ cell queue. FPS stays 7–14 for the next ~150 s. User's earlier "14 FPS for 1-2 min" baseline is actually closer to "10 FPS for ~3 min."

2. **Phase 3 world-scoped MultiMesh is alive but the draw count on the dense cluster is still 7 100.** The batching is real (535 batches / 14 386 slots), tier 3/4/5 occupancy confirmed, but the Phase 3 design target of < 3 000 draws at horizon is not being hit on the Seyda Neen floor. vista/pan/run segments — camera pulled back or traversing — do drop to 1 400–3 700 draws and 70–80 FPS.

3. **Teleport burst detection works cleanly.** 940 m jump triggers the log line, startup_phase re-arms, 23-frame startup phase, FPS recovers to ≥ 50 in 3.6 s. Low-density target area inflates the post-teleport average FPS (200+) but the gate passes regardless.

4. **HLOD-off scenario F has a too-aggressive numeric gate** (`rendered_objects < 500`) — NEAR-ring alone on a loaded 9-cell hex carries ~6 000 objects. The functional gates all pass (chunks=0, impostors hidden, no errors). Recommend the user adjust the gate or rethink what "only NEAR past 150 m" means numerically.

5. **Zero new runtime errors.** Log hygiene is clean — the 6-commit refactor hasn't introduced any SCRIPT ERROR / parse error / bad index path.

## Scope boundaries honoured

- Only two sources of truth used: the code in `src/` and runtime numbers from the live scene. All docs claims cross-checked against current code before relying on them.
- Headless launches used only for parse-check + unit test runs. All FPS data from real-renderer.
- No auto-capture screenshots. Autobench only records numeric metrics from `Performance.get_monitor()` + streaming manager `get_stats()` + HLOD `get_stats()`.
- No `git checkout --` / `git revert` / file deletion. Nothing destructive.
- No patches to the refactor code. Findings flagged to §4.N of plan + this file, user decides.

## Files changed this pass

- `src/tools/auto_bench_runner.gd` (new) — orchestrator.
- `src/tools/world_explorer.gd` — +36 LoC for `--bench-auto [stamp]` cmdline parser + runner wiring.
- `tests/unit/test_auto_bench_runner.gd` (new) — 5 smoke tests (all pass).
- `docs/audit/DISTANT_RENDERING_PLAN_2026_04_17.md` — §4.N autonomous-audit block + §8 status-snapshot flips.
- `docs/audit/perf-reports/2026-04-17_20-30-38/` — this report + raw data.

Commits:
- `392b13d` — AutoBenchRunner harness + smoke tests.
- (pending) — §4.N writeup + this SUMMARY.md.
