# Distant Rendering Performance Audit — 2026-07-05

Autonomous audit session. Every claim below is backed by a repo benchmark
artifact (`user://benchmark_results/`), the live heartbeat log, a fresh HEAD
ladder run executed during this audit, or a cited primary source.

## TL;DR

1. **Rendering the distant world is cheap. Building and tearing it down while
   the camera moves is what's slow.** At HEAD, standing in Seyda Neen with the
   full default stack (NEAR + static visuals + FAR impostors, HLOD off):
   **~142 FPS, render_cpu ≈ 2.7 ms, render_gpu ≈ 3.2 ms**, 1,206 draw calls,
   50 cells loaded (measured this session via
   `viewport_get_measured_render_time_*`, newly added to the heartbeat).
   The same stack during the 85 s moving flyby: **56.7 FPS avg, p95 23.8 ms**.
2. The tier plan (NEAR/MID/HLOD/FAR) is a reasonable industry shape. The two
   real defects are (a) streaming work per camera movement is too expensive
   and its frame budgets don't actually hold, and (b) HLOD as implemented is
   batching-without-simplification — it makes frames worse *and* crashes.
3. FAR impostors are healthy — measurably cheap (~0.1 ms/frame lane cost,
   included in the 142 FPS standing result).
4. LODs are not the problem: prims in the flyby hover at ~0.35 M — the
   embedded mesh LOD cascade is doing its job.

## Fresh evidence (this session, HEAD = 14a16d9)

### Ladder flyby (85 s scripted Seyda Neen path, 144 FPS user cap)

| Rung | Stack | avg FPS | p95 | draws |
|---|---|---|---|---|
| 0–1 | empty / +terrain | 143.6 | 6.9 ms | 87 |
| 2 | +near_gameplay | 139.2 | 7.8 ms | 227 |
| 3 | +static_visuals | **56.7** | **23.8 ms** | 713 |
| 4 | +hlod | ~44 (heartbeats) | — | ~640 |

Rung 4 ended in a **native segfault** during unload churn (crash breadcrumb
`nsm::unload_tick_done`, 2 cells in pending RS cleanup, one 861 ms
`hlod_merger` frame observed earlier in the rung). No `bench_ladder.json` was
written. This crash class reproduces under the standard benchmark with no
user input.

### Standing still, default stack (NEAR + MID + FAR, HLOD off)

`--quit-after-ready=120` run, heartbeats after queue drain:
**139–142 FPS, render_cpu 2.2–3.1 ms, render_gpu 2.5–3.7 ms**, draws 1,206
(shadow draws 0), objs 1,830, prims 299 k, 50 cells loaded.

→ The renderer disposes of the entire distant stack in ~3 ms CPU + ~3 ms GPU.
The 56.7 FPS flyby average is **motion cost**: per-frame streaming work plus
overruns, not a fixed render tax.

Side observation: `loading=9` stayed constant for 60+ s — nine cells never
leave the "loading" state. Worth a look; at minimum it pollutes stats.

### Budget overruns during motion (autopsy lines, this session's run)

Configured: `UNLOAD_BUDGET_MS = 4`, post-startup instantiation 4 ms, static
prepare 2 ms, shared frame budget 8 ms. Observed single-frame sections:

- `unload` 9–75 ms (repeatedly)
- `pending_loads_async` 253 ms (once)
- `instantiate` 38 ms (once)
- `cell_preloader_update` 53–60 ms — **in the EMPTY rung** (everything off)
- `hlod_merger` 8–10 ms sustained, 861 ms worst

The deadline system checks time *between* work items; individual items are
tens of ms, so budgets are advisory, not real. At a 140 FPS target the whole
frame is 7 ms — an 8 ms streaming budget plus overruns guarantees ~55–60 FPS
whenever the camera moves.

## Historical evidence (mined from benchmark_results/)

- June 19–22 ladder series (commit 8356d8c + dirty worktrees): rung 3
  (+static_visuals) went 34 → 60 FPS across ~15 tuning runs
  (detail cutoffs, AABB fixes, census work). Same-commit variance was huge
  (31.7 vs 75.6 FPS), i.e. measurement hygiene was poor (dirty worktrees, FPS
  cap, thermal, single runs).
- **Draw calls are not the bottleneck**: June 20 experiment halved draws
  (649 → 328); FPS moved 34.2 → 34.4. Prims stayed ~0.35 M throughout.
- MID bucket census (June 22): 47 cells → 1,733 buckets, 6,822 instances,
  2,978 RS instances. **Avg 2.3 instances per draw group** — the MultiMesh
  batching premise fails on Morrowind content (605 unique mesh types, little
  per-cell repetition). MID is effectively one-RS-instance-per-object with
  extra bookkeeping.
- Performance Observatory (deleted at HEAD; recovered from git —
  `git show 8356d8c:docs/audit/performance_observatory_state.md`): traversal
  scenarios showed `phase_inst` ≈ 7.6 ms avg and the near_gameplay
  publication lane ≈ 7.4–7.5 ms — the streaming pipeline occupies half a
  60 FPS frame during movement, by design.
- Fast travel: min FPS 17, first FPS ≥ 50 after 4.4 s (June 18).
- First playable ≈ 24.6 s warm start (June 22).

## Findings

### F1 — The bottleneck is world assembly/teardown on the main thread, not rendering

All the per-ref work on cell crossings — classification, model request
starts, instantiation, bucket configure (cluster transforms, MultiMesh
set_buffer), collision publish, unload/free — runs in GDScript on the main
thread, time-sliced under budgets that overrun 2–30× because the atoms are
too coarse. Standing-still FPS (142) vs moving FPS (57) is the measurement of
exactly this cost.

### F2 — HLOD is batching, not HLOD

`object_paging.gd` + `NativeObjectPagingKernel.cs` merge full-res geometry by
material hash into ≤64-surface chunks, with `RUNTIME_GENERATE_LODS = false`
(merged chunks have **no LOD chain**) and no material atlasing. So the
400–1000 m ring renders LOD0 vertex data with full materials. OpenMW's object
paging pays off because draw calls are the OSG bottleneck (the cost/benefit
formula literally trades vertex cost against saved draw calls — see the
OpenMW MR !209 rationale); our own data shows draw calls are not Godot's
bottleneck. UE-style HLOD is an **offline** pipeline: simplify + atlas + bake
proxies. Runtime merge-without-simplify is neither. It also carries a live
crash class (segfault during unload churn, reproduced this session) and an
861 ms merge stall.

### F3 — Budgets are advisory

See overruns above. Any fix that "tunes budgets" without making work items
preemptible (or moving them off-thread / to C#) cannot hold the line.

### F4 — Wrong constants imported from OpenMW

`distance_utils.gd` claims OpenMW's `object paging min size` is 0.14 and
"corrects" it to 0.003. OpenMW's actual default is **0.01**
(openmw.readthedocs.io, Terrain Settings; the ratio is unit-free, so no
meters conversion applies). 0.003 is ~3× more permissive than OpenMW —
smaller objects survive into distant tiers than OpenMW would ever draw.
Similarly `SCREEN_SIZE_CUTOFF_RATIO = 200` (= ratio 0.005) is 2× more
permissive than OpenMW's cutoff.

### F5 — MID's MultiMesh architecture doesn't fit the content

2.3 instances per draw group means the clustering/bucketing machinery
(~3,000 lines across static_object_renderer + cell_static_bucket) buys almost
no batching. It's not *hurting* rendering (render_cpu is 2.7 ms), but it is a
lot of build/teardown work per cell crossing for near-zero draw savings —
the cost shows up in F1.

### F6 — Diagnostics: enormous surface, missing the two standard measurements

Six benchmark harnesses (streaming_benchmark, progressive_benchmark,
bench_ladder_runner, auto_bench_runner, streaming_stress_runner, perf_sweep)
plus HUD, censuses, autopsies, publication lanes, breadcrumbs, pipeline
compile monitor. Yet until this session nothing captured the render CPU/GPU
split (`viewport_set_measure_render_time` — one call), and no engine-profiler
session of a hot scene is recorded anywhere. Dead artifacts: 4 all-zero
ladder JSONs (Apr 18, May 3 ×2, Jun 18), an empty autobench dir (May 2), and
today's crashed ladder. progressive_benchmark and bench_ladder_runner are
duplicate implementations of the same additive sweep.

## What is actually fine

- Terrain: free (143.6 FPS with terrain on).
- NEAR gameplay tier at rest: ~0.3 ms.
- FAR impostors: ~0.1 ms lane cost, included in the 142 FPS standing result.
- Embedded mesh LOD (engine-driven): prims stay ~0.3–0.4 M; working as
  designed. "LODs are stupid for our distances" is not supported by data.
- The tier *shape* (near gameplay / static visuals / far impostors) matches
  UE World Partition + HLOD-ish layering and OpenMW's distant statics.

## Recommendations (ranked)

1. **Attack traversal cost, not render cost.** Target: streaming ≤ 1–2 ms per
   frame during movement (the stated 1 ms north star is right). Two canonical
   levers: (a) make work items preemptible at fine grain (per-ref, per-N-refs)
   so budgets actually hold; (b) move per-ref hot loops (classification,
   transform math, bucket packing, unload bookkeeping) to C# — the project's
   own hot-path evidence doc already ranked cell_manager /
   native_streaming_manager first.
2. **Shrink the work volume per crossing: prebake per-cell static payloads.**
   Instead of assembling 100–300 refs per cell at runtime (parse → classify →
   cluster → pack MultiMesh → upload), bake each exterior cell's static
   visuals offline into a ready-to-publish asset (merged-by-material ArrayMesh
   per ~58 m cluster WITH `generate_lods()` run at bake time, or a MultiMesh
   set). Runtime then does: load .res → create N RS instances. This is the
   industry pattern (UE HLOD/World Partition bakes offline; user rule "no
   runtime generation" agrees). It also deletes most of the bucket-configure
   machinery.
3. **Delete or rebuild HLOD.** As-is it costs FPS (57 → 44), stalls (861 ms),
   and crashes. If the 400 m+ ring ever needs more than impostors, the
   canonical answer is offline-baked simplified proxies (meshoptimizer
   simplify + texture atlas at bake time), published as 1 instance / few
   surfaces per chunk. Runtime merge-without-simplify should not return.
   Note FAR impostors already cover 400 m+ well — measure whether HLOD adds
   any visual value before rebuilding it at all.
4. **Fix the crash class** (unload churn / pending RS cleanup with HLOD
   active) if HLOD stays available even as an experiment — it reproduces
   under the standard benchmark with no user input.
5. **Restore honest constants**: PAGING_MIN_SIZE comment/value (OpenMW default
   is 0.01, ratio is unit-free), SCREEN_SIZE_CUTOFF_RATIO rationale. Anything
   tuned "because 0.14 rejected everything" was tuned against a
   misremembered baseline.
6. **Diagnostics diet + the two missing tools**: keep bench_ladder + HUD +
   one autobench runner; fold/retire progressive_benchmark and perf_sweep;
   keep the new `render_cpu/render_gpu` heartbeat fields (added this session
   in native_streaming_manager.gd); add a documented "attach Godot profiler /
   capture with RenderDoc" workflow for the next unexplained cost. Benchmark
   hygiene: clean worktree, note the 144 FPS cap (or disable it for
   benches), repeat runs, report variance.
7. **Investigate the stuck `loading=9` cells** — cheap to check, might be
   leaking payload state or blocking the drain telemetry.

## Cross-references

- Ladder + heartbeat evidence: `user://benchmark_results/ladder_*`, log
  2026-07-05 (this session).
- MID census: `ladder_fastospeedo_mid_static_offender_attribution_2026_06_22`.
- Recovered observatory state: `git show 8356d8c:docs/audit/performance_observatory_state.md`.
- OpenMW defaults: openmw.readthedocs.io Terrain Settings ("object paging min
  size" default 0.01); OpenMW GitLab MR !209 (paging rationale: draw-call
  economics).
- Godot: MultiMesh = one LOD level for the whole block, no per-instance
  frustum culling (docs.godotengine.org Mesh LOD; godot-proposals #10669);
  `RenderingServer.viewport_set_measure_render_time` +
  `viewport_get_measured_render_time_cpu/gpu` (works on Vulkan).
