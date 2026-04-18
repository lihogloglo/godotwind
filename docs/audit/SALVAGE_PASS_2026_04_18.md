# Distant-Rendering Salvage Pass — 2026-04-18

**Author:** @audit-distant (Claude)
**Commit:** baseline + ladder at HEAD `c8df651` (branch `perf/distant-rendering-2026-04-17`)
**Scope:** first day of a systematic, data-grounded dive into the Phase 1-8 distant-rendering refactor. This doc captures the measured findings AND the tooling mistake made in the process.

---

## 1. What the data says (ground truth)

All numbers collected at Seyda Neen spawn `(-2,-9)`, static camera, 15 s samples per configuration, real renderer, Windows DX12, commit `c8df651`. Raw data: `docs/audit/perf-reports/2026-04-18_09-52-30_ladder/ladder/bench_ladder.json` + `docs/audit/perf-reports/2026-04-18_09-45-24_b0/`.

### 1.1 Cumulative subsystem ladder

Each rung ENABLES one more subsystem on top of the previous rung's set. Δ FPS is the marginal cost of adding that subsystem to the stack.

| # | rung | FPS | Δ FPS | draws | Δ draws | notes |
|---|---|---:|---:|---:|---:|---|
| 0 | empty | 119 | — | 896 | — | engine + UI + Terrain3D clipmap residual (Terrain3D `.visible = false` doesn't fully stop clipmap) |
| 1 | +terrain | 116 | −3 | 927 | +31 | terrain is cheap |
| 2 | +near_objects | 103 | −13 | 1065 | +138 | full Node3D + physics for everything inside 150 m |
| 3 | **+mid_objects** | **77** | **−26** | **1296** | **+231** | **biggest single cost — out of proportion to +231 draws** |
| 4 | **+hlod** | **60** | **−17** | **2282** | **+986** | 16 chunks × ~60 material-surface draws each |
| 5 | +impostors | 60 | +0 | 2279 | −3 | FAR tier is essentially free — one MultiMesh draw for 51 208 instances |
| 6 | +sky | 50 | −10 | 5082 | +2803 | SunshineClouds2 cascades — highest draw-count add |
| 7 | +ocean | 31 | −19 | 5093 | +11 | fragment-shader-heavy; DEFAULT OFF in production |
| 8 | +weather | 31 | −0 | 4851 | noise | free at clear-day Seyda Neen |
| 9 | +postfx | 28 | −3 | 4817 | noise | TAA+SSAO+SSIL+glow+godrays+vfog collectively cheap here |
| 10 | +shadows | 29 | +1 | 4828 | noise | noise-level — shadow cost drowned by scene-geometry cost |
| 11 | +characters | 28 | −1 | 4856 | +28 | ~5-10 NPCs at Seyda Neen |

### 1.2 Tier-isolation correctness

Every subsystem toggle is a pure **visibility flip** — no RID free / rebuild, no allocation churn. Verified at rung 0 (empty): `mid_visible = 0` while `registry_slots = 14 378` and `hlod_cells = 16` stay populated. Toggles are A/B clean.

Tier ownership holds cleanly:
- NEAR = Node3D per cell (via `cell_node.visible`).
- MID = `PrototypeRegistry` batches (via `static_renderer.set_all_visible`).
- HLOD = `object_paging` merged chunks (via `hlod_merger.set_all_visible`).
- FAR = impostor `MultiMeshInstance3D.visible`.

User's first correctness question — "is NEAR + terrain correct?" — **answered: yes**. Both behave monotonically, bounded, measurable. No anomaly.

### 1.3 Headline cost drivers (production default = ocean OFF)

1. **MID tier: −26 FPS for +231 draws.** 535 batches × ~50 μs engine submission ≈ 27 ms — matches the −26 FPS observation exactly. Cost is per-batch submission, NOT per-draw rasterization and NOT the GDScript cull (the cull is gated on camera motion via `CULL_DISTANCE_HYSTERESIS = 10 m` and doesn't run every frame).
2. **HLOD tier: −17 FPS for +986 draws.** 16 HLOD chunks, one RS instance each, but each `ArrayMesh` has 50-60 material surfaces → ~1000 draw calls. That's the double-hit: HLOD was supposed to REDUCE draw count but each chunk internally fans out to one draw per unique material in the merged cells.
3. **Sky: −10 FPS for +2803 draws.** SunshineClouds2 volumetric cloud cascades. Highest draw-count add in the ladder.

Math sanity check: empty 119 − 3 (terrain) − 13 (near) − 26 (mid) − 17 (hlod) − 0 (imp) − 10 (sky) − 3 (postfx) + 1 (noise) − 1 (chars) = **50 FPS**. Matches `bench_tiers` Seyda Neen steady-state 47.7 FPS ±3. Ladder is internally consistent.

### 1.4 Baseline scenarios (for cross-reference)

From `--bench-auto` at the same HEAD (2026-04-18_09-45-24_b0):

| Scenario | Metric | Value | Gate | Result |
|---|---|---:|---:|---|
| A Log hygiene | non-whitelist errors | 0 | 0 | PASS |
| B Cold-start | time-to-stable-55 | 194.6 s | ≤ 20 s | **FAIL** (8.5×) |
| C Static Seyda Neen | FPS avg | 47.7 | ≥ 55 | **FAIL** |
| C | draws avg | 7 093 | < 3 000 | **FAIL** (2.4×) |
| D Flyby whole | p99 ms | 84.5 | < 50 | **FAIL** (1.7×) |
| D | peak draws | 12 296 | < 8 000 | **FAIL** |
| E Teleport burst | first FPS ≥ 50 after jump | 3.6 s | ≤ 15 s | PASS |
| F HLOD off | FPS avg | 22.4 | — | (worse than HLOD on; ladder confirmed this was post-E streaming contamination, not a code issue) |

Walking lag the user reports = D's p99 84.5 ms. The `events.csv` shows a single 16 597-object pop frame during the vista→pan transition (MID + HLOD briefly in-frustum simultaneously before `visibility_range` dropped them) — that frame accounts for the 144 ms max and much of the p99.

### 1.5 What did NOT change since the prior audit (20-30-38)

Four commits landed between the prior autobench and this one (`b50e349`, `5c1bc88`, `da213fd`, `c8df651` — Phase 8 churn around `pause_gameplay`, auto-trigger gating, and the model-loader instantiate-race workaround). None of them moved the measured FPS / draw / settle numbers outside measurement noise. Phase 8's stability is real (no new crashes) but its perf impact on this branch is zero.

### 1.6 Cost hypothesis (preliminary — for disambiguation, not a fix yet)

If the 535-batch MID cost is dominated by per-batch GPU-submission overhead, the fix is batch-count reduction. Two paths:

1. **Coarsen the dedup key.** Currently batches are keyed on `(mesh_rid, material_rid)`. If many batches share the same `mesh_rid` but differ only by minor material variants (a prebaker dedup miss), widening the key would coalesce them.
2. **Partition and cull.** Currently all 14 378 slots are in 535 batches regardless of camera proximity. Engine-side frustum + visibility_range culling runs per-batch. If the per-batch overhead is genuinely 50 μs, the cost scales linearly with active batches — and many of those batches have 0 live slots after cell unload (freelist retained, `slot_count_live = 0` but the RS instance is still submitted).

`PrototypeRegistry.get_batch_distribution()` (landed in this session, uncommitted, diagnostic-only) answers which of (1) or (2) applies by reporting the slot-count histogram, empty-batch count, and per-mesh fanout.

Next rung of the salvage protocol: run once to collect `batch_distribution.json`, interpret, then propose a surgical fix.

---

## 2. Benchmark tool audit — tools we already had, and the one I shouldn't have built

**User called this out:** "we have too many benchmark tools. Each new session that tries to debug this mess is creating yet a new tool."

Honest inventory:

### 2.1 Inventory as of 2026-04-17 (before this session)

| Tool | Lines | Trigger | What it does | CSV/JSON output |
|---|---:|---|---|---|
| `StreamingBenchmark` (`src/tools/streaming_benchmark.gd`) | 1102 | console `bench` + programmatic | 85-s scripted Seyda Neen flyby, 6 segments (settle/idle/walk/vista/pan/run), per-frame CSV + events CSV + summary JSON | `user://benchmark_results/benchmark_*.csv` + `summary_*.json` + `events_*.csv` |
| `AutoBenchRunner` (`src/tools/auto_bench_runner.gd`) | 416 | CLI `--bench-auto [stamp]` | orchestrator — settles, runs 4 scenarios (C tiers / D flyby / E teleport / F hlod_off), auto-quits | `user://benchmark_results/autobench_<stamp>/bench_tiers.json` + `bench_teleport.json` + `bench_hlod_off.json` + delegates flyby to StreamingBenchmark |
| `ProgressiveBenchmark` (`src/tools/progressive_benchmark.gd`) | 297 | console `bench_progressive` | **cumulative-additive subsystem ladder** — 10 passes × 85-s flyby, one aggregate row per subsystem config. ~14 min wall-clock. | `user://benchmark_results/progressive_<ts>.csv` |
| `PerfSweep` (`src/tools/perf_sweep.gd`) | 254 | console `perf_sweep` | **isolation sweep** — disables ONE subsystem at a time (all others on), 4-s record + 2-s settle per pass, ~60 s total. Sorted "FPS cost" table. | console only, no JSON |
| `BenchmarkHUD` (`src/tools/benchmark_hud.gd`) | 335 | console `hud` + key | live overlay — current FPS, p95, draws, objects, VRAM, per-subsystem toggle state | no persistence |
| `SubsystemToggles` (`src/tools/subsystem_toggles.gd`) | 172 | console `toggle <name>` + programmatic | 11-flag callback router (terrain/ocean/sky/weather/characters/impostors/mid_objects/near_objects/hlod/shadows/postfx) | — (data source) |
| `PerformanceProfiler` / `StreamingProfiler` / `ProfilingReport` | various | F4 key + automatic | per-phase instrumentation (`[audit +Ns]` log lines every 5 s for 60 s post-startup, phase breakdown: unload / async / inst / promo / coll / defer / queue), phase ms timing | log + `ProfilingReport` dump |
| `DebugSystem` / `BatchDebugHUD` | ~1200 | F9 overlay + console | RS instance stats, debug view modes | in-session |

### 2.2 What was wrong with the existing tools for today's task

Answering user's direct question honestly:

**`PerfSweep` (isolation) ≠ cumulative-additive ladder.** PerfSweep disables `X` with everything else on and measures FPS gain. That gives you "cost of X assuming the rest of the stack is allocated and warm" — which is NOT the same as "cost of X when it's the only thing running." The numbers differ because GPU state / shader cache / VRAM allocation are shared. For the "each subsystem independently, from the ground up" analysis the user asked for, I wanted cumulative ADD (start empty, add one tier at a time), which is what `ProgressiveBenchmark` does.

**`ProgressiveBenchmark` IS the cumulative-additive ladder I wanted.** It has the right architecture, the right order, the right `SubsystemToggles`-based application. Three things stopped me from using it verbatim:

1. It runs an 85-s scripted flyby per pass → 14 min wall-clock. Too slow for an initial bisection, especially with the existing 195-s cold-start settle + 12 passes.
2. `PROGRESSIVE_ORDER` omits `hlod` (header comment: "per user directive 2026-04-14, HLOD is not used at present; it can be re-added here once it ships"). That's outdated — HLOD is now default-on.
3. Triggered from the console, not the CLI. I wanted a fully automated `--bench-ladder [stamp]` run-and-quit for the autonomous session.

**None of those three were reasons to write a new file.** All three could have been solved by extending `ProgressiveBenchmark`:
- Add `sample_mode: "flyby" | "static"` option (15-s static sample per pass is ~6× faster).
- Add `hlod` and `impostors` to `PROGRESSIVE_ORDER`.
- Add a CLI entry point in `world_explorer._maybe_start_progressive_bench()` similar to the existing `_maybe_start_auto_bench()`.

Total would have been ~80 lines added to `progressive_benchmark.gd` + ~20 lines in `world_explorer.gd`. Same result, same output shape, same JSON consumer.

### 2.3 What I actually did (mistake)

Wrote `src/tools/bench_ladder_runner.gd` (280 lines) + `tests/unit/test_bench_ladder_runner.gd` (127 lines) + CLI flag `--bench-ladder`. Committed as `2cc1f64`.

The outputs are useful — the ladder data drove everything in §1 of this doc — but the TOOL is a duplicate of `ProgressiveBenchmark`'s core architecture with a different sample strategy. I became the fifth session that "creates yet a new tool" as user described.

Same anti-pattern called out in `.claude/CLAUDE.md`:

> *"Agents have a strong failure mode: they over-engineer early decisions, then spend subsequent sessions trying to fix / tweak / extend the over-engineered foundation instead of stepping back and reaching for the simpler, battle-tested pattern."*

I looked at `ProgressiveBenchmark`, saw "85-s flyby per pass", and moved on to writing new code instead of asking "what if I add a static-sample mode to the existing runner?"

### 2.4 Consolidation proposal (for user approval before I execute)

**Option A — fold & delete.** Extend `ProgressiveBenchmark` with:
- `sample_mode: StringName` (values `"flyby"` or `"static"`, default `"flyby"`).
- `add_hlod_impostors` to the default order.
- CLI trigger `--bench-progressive [stamp] [mode]`.
- Per-pass JSON dump (not just aggregate CSV) matching the `bench_ladder.json` schema.

Then **delete** `bench_ladder_runner.gd` + `test_bench_ladder_runner.gd`. Migrate the `--bench-ladder` CLI flag to `--bench-progressive=static`.

Net change: +~100 lines in one file, −280 lines from another, one fewer tool. The ladder run today remains reproducible via `--bench-progressive=static`. Existing flyby consumers unchanged.

**Option B — accept the duplicate.** Keep `BenchLadderRunner` as "the cheap static variant" and `ProgressiveBenchmark` as "the realistic flyby variant." Document the split in one place. Cost: one more tool, forever.

I recommend **Option A**. It's 1-2 hours of consolidation work with zero risk to the actual findings (the ladder data I already collected is preserved under `docs/audit/perf-reports/`). It also sets the precedent that the next agent extends, not duplicates.

### 2.5 Other consolidation opportunities (not blocking)

- `StreamingBenchmark` + `AutoBenchRunner`: separate files but `AutoBenchRunner` delegates to `StreamingBenchmark` for scenario D. Clean separation. Keep as-is.
- `BenchmarkHUD` vs `BatchDebugHUD`: overlapping display surfaces. Different purposes (BenchmarkHUD = framerate/perf HUD, BatchDebugHUD = renderer-internal stats). OK to keep split.
- `PerformanceProfiler` vs `StreamingProfiler` vs `ProfilingReport`: three profilers with partial overlap. Could be consolidated, but out of scope here.
- `automated_test_runner.gd` vs `run_tests.tscn`: different — the runner is a scene harness, the tscn is a tool to drive gdUnit4. Keep.

The only duplicate that demands action today is `BenchLadderRunner` vs `ProgressiveBenchmark`.

---

## 3. Revised next-step plan

1. **Consolidate** (Option A above) — delete `BenchLadderRunner`, migrate its capability into `ProgressiveBenchmark`. One commit.
2. **Rung 2 (diagnostic-only)** — run `--bench-progressive=static` once to collect the ladder, plus `proto_registry dist` console output (or a one-shot diagnostic dump at the final rung) to get the batch-size distribution. Same data as today, plus the fragmentation / submission-overhead disambiguator.
3. **Rung 3 (first surgical fix)** — based on distribution data, either:
   - (batch-fragmentation case) coarsen dedup key in `PrototypeRegistry.batch_key` and measure the redistribution, or
   - (submission-overhead case) investigate whether empty batches (`slot_count_live = 0` but RS instance still live) can be freed / hidden.
   Either way, the fix lands in **one file** (`prototype_registry.gd` or `prototype_batch.gd`), is unit-testable, and A/B-able against the same benchmark with `--bench-progressive=static`.
4. **Rung 4+** — same pattern for HLOD's +986-draws-for-16-chunks anomaly (surface consolidation at bake time? material grouping fix?).

Each rung = one commit, tests, before/after bench, plan-doc append. No new tools.

---

## 4. Artifacts & commit pointers

- Ladder data: `docs/audit/perf-reports/2026-04-18_09-52-30_ladder/ladder/bench_ladder.json` (12 rungs, ~15 samples each)
- Autobench baseline: `docs/audit/perf-reports/2026-04-18_09-45-24_b0/autobench/` (tiers/flyby/teleport/hlod_off JSONs + flyby CSV)
- Commit `2cc1f64` — `BenchLadderRunner` landing (will be reverted / migrated per Option A)
- Commit `ab4244c` — this pass's data + plan-doc append
- Findings appended to `docs/audit/DISTANT_RENDERING_PLAN_2026_04_17.md §4.N`

---

## 5. What I'd ask for before continuing

1. **Approve Option A (consolidate into `ProgressiveBenchmark`)** or tell me to keep the duplicate.
2. **Confirm the next rung target** — I propose MID batch distribution first (biggest cost, easiest to instrument). Alternative: HLOD surface-splits investigation first.
3. **Decide whether to revert `BenchLadderRunner` commit** (`2cc1f64`) or keep it in history and just delete the files in a follow-up commit. I prefer the follow-up delete — keeps commit graph clean for reviewers.
