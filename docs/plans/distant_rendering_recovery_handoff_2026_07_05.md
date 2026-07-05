# Handoff — Distant Rendering Recovery (written 2026-07-05, end of session 1)

> **SESSION 2 UPDATE (2026-07-05, later the same day):** Wave 4 shipped —
> door/shell classification fixed (memo + spatial hash + per-portal log
> demotion; zero [door-register] warns at spawn now), [inst-atom] and
> [pocket-begin]/[pocket-attach] instrumentation added. Rung 2 verified at
> 127.0 FPS (no regression vs wave 2b's 128.6). **Rung 3 verification is
> BLOCKED: 3/3 ladder runs segfaulted mid-run** — a pre-existing native
> crash class in the streaming-churn window (static publish + pocket load +
> unload) whose reproduction rate scales with FPS; the faster post-wave-4
> frames widened the 600+ FPS regime where it fires. Full evidence, three
> crash signatures, and diagnosis avenues are in the plan doc's
> "BLOCKER" section. **The crash hunt is wave 5, item 1 — the standard
> benchmark cannot complete until it lands.** Everything below this block
> is session-1 state; read the plan doc for current truth.
>
> **SESSION 3b (2026-07-05, same day): wave 6.** Impostor-atlas 525 ms
> one-shot fixed (incremental update_layer commits + capacity-padded
> arrays; smoke-verified 525 → 11.6 ms worst imp frame — note the ladder
> rungs never exercise FAR, only smokes see this). Phase 3 **M.0 shipped**:
> C# `NativeCellManifest` (custom binary, FileAccess-only load, round-trip
> test green) + implementation plan for M.1/M.2 in the plan doc's Phase 3
> section. [inst-atom] now logs the ml= model-load subslice. Wave-7 backlog
> in the plan doc ("Remaining named work").
>
> **SESSION 3 UPDATE (2026-07-05, same day): CRASH RESOLVED.** Root cause =
> Godot ≤4.6 threaded-loader race on contested sub-resources (upstream
> #111202, fixed for 4.7 by PR #118824). Fix: single-flight loading
> (`MAX_CONCURRENT_ASYNC_LOADS` 16→1, impostor texture tasks 2→1). 2/2
> ladders now complete at 600+ FPS settles; **rung 3 = 95.9 / 96.3 FPS —
> best of the arc, zero throughput cost**. Wave-2's owed door check also
> done autonomously via new `--auto-test-walk` / `--auto-test-rush` modes
> on `tests/visual/test_interior_transition.tscn` (walk: assembled 8.9 m
> out, clean enter). Wave-6 backlog with named, data-attributed offenders
> (Furn_rug_02.NIF 102-112 ms atoms; "silver shortsword" 151 ms attach,
> pipeline-compile theory REFUTED; imp 525 ms startup; light 3-15 ms;
> transition-frame 36.6 ms peak) is in the plan doc.

You are picking up a performance recovery arc that is going very well. Read
this, then the plan doc, and you have everything. The user's standing wish:
"fix this entirely" — make the open world stream and render smoothly, no
hitches, honest measurements, no kludges.

## Read these, in this order

1. `docs/plans/distant_rendering_recovery_2026_07.md` — THE plan of record.
   Phases 0-3, every wave's diagnosis, fix, and verified numbers. Your
   backlog is its "Remaining named work (wave 4 candidates)" section.
2. `docs/audit/distant_rendering_perf_audit_2026_07_05.md` — the audit that
   started this. Read the TL;DR and Findings; skim the rest.
3. Project memory `distant-rendering-audit-2026-07-05` (auto-recalled) —
   condensed history if you need a refresher mid-session.

## Where things stand (all verified on the standard benchmark)

Benchmark = 85s Seyda Neen flyby, `--bench-ladder`, uncapped (the ladder
disables max_fps AND vsync itself). Statics-visible rung 3 is the stable
gameplay-representative number; rung 2 runs first and absorbs cold-start
one-shots, so it swings 75-128 FPS between runs — do NOT read rung 2
deltas as regressions.

- Morning baseline: 52.6 FPS avg / p95 25.6 ms
- After waves 1-3 (this session): **94.1 FPS avg / p95 14.1 ms**
- Standing still, full default stack: ~142 FPS, render_cpu ≈ 2.7 ms,
  render_gpu ≈ 3.2 ms. Rendering was never the problem. Traversal churn was.

All of today's work is UNCOMMITTED in the working tree (Phase 0 + waves
1-3 + docs + this file). The user may commit before you start — check
`git status` / `git log` first.

## The method that worked (keep using it)

Instrument BEFORE fixing: warn-gated block timers (>8 ms threshold, house
style like `[ml-request-start]`). Today's additions you can read in logs:
`[we-autopsy]` (world_explorer._process blocks), `[cell-request-start]`
(manifest build vs filter), `[door-register]`, `[pocket-complete]`, plus
the heartbeat now logs `render_cpu=/render_gpu=` and `loading=N (tail=M)`.
Every single offender today was named by data before it was touched, and
every fix was verified by a fresh ladder. Do the same.

Also: every "hot loop" so far was actually file I/O, an O(n²) algorithm, a
redundant tree walk, or an unsliced engine-call atom. Check for those four
before reaching for C# (see the plan's "C# port decision" note — the user
mandated C#-now, we documented why it kept not applying; the standing
honest scope for C# is a C#-owned record/manifest data model, which is
really Phase 3).

## Wave 4 backlog (scoped, with measurements)

1. **Pocket first-attach 158 ms residual.** `[pocket-complete]` warns came
   back ZERO, so `get_async_result` is innocent — the cost is in the attach
   frame of `_begin_pocket_finish_up` / first `_pocket_finish_up_attach_step`
   (interior_pocket_manager.gd). Prime suspect: first-visibility shader
   pipeline compilation. Probe with the existing pipe= counters
   (`pipeline_compile_monitor`, already in the heartbeat) around a pocket
   load. If confirmed, the canonical fix is Godot's pipeline
   precompile / hidden-instance prewarm — check
   `rendering/rendering_device/pipeline_cache` and ubershader settings
   before hand-rolling anything (verify API against 4.6 docs first,
   per project rule).
2. **First-touch door/shell classification, 15-50 ms per dense cell**
   (`[door-register]` data; worst = grid (-3,-2), 41 doors, 50.2 ms).
   Cost is `_build_shell_candidates` in
   `src/core/world/morrowind/morrowind_transition_provider.gd` — one pass
   over all refs × base-record lookup × ~38 substring matches. Options:
   slice it (doors don't need shells until the player is near), fold into
   Phase 3 prebake (it's static data — cook it), or C# it. Prebake is the
   endgame; a cheap slice now is fine.
3. **`instantiate` one-shots up to 119 ms** — single large PackedScene
   instantiates during startup burst (`process_async_instantiation`,
   documented indivisible; completion add_child ≈ 13 ms is already capped
   1/frame). Structural fix is Phase 3 (prebake split of monster NIFs).
   Interim option: identify WHICH models (add a warn with model path around
   the instantiate call in cell_manager), consider capping the startup
   burst budget.

## After wave 4 — the rest of the plan

- **Phase 2 (visual)**: the empty 400-1000 m ring. Impostors-first, GATED
  on the impostor storage fix (normal atlases stored as raw .res ≈ 4 MB
  each; 208 bakes = 905 MB on disk already). User hard constraint: **no
  multi-GB caches**. Then: full 937-candidate rebake, size-based candidacy
  (OpenMW's real min-size default is 0.01 — the 0.14 in old comments was
  wrong, already corrected in distance_utils.gd), lift the 256-layer cap,
  check aerial bake angles.
- **Phase 3 (structural)**: cooked per-cell manifests (~15-20 MB total,
  geometry stays deduped — the naive merged bake was rejected at ≈8 GB).
  Deletes the runtime manifest build, the classification, most
  bucket-configure machinery, and the instantiate atoms.
- **Runtime HLOD (`object_paging.gd`)**: parked by user decision, default
  off, do NOT invest in it; delete it once Phase 2/3 covers the ring. It
  merges without simplification (no LOD chain, 861 ms stalls, a segfault
  class in unload churn).

## Verification protocol (hard rules learned today)

- Ladder command (from repo root):
  `& "D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --path "D:/Gamedev/Godotwind/godotwind" res://scenes/Godotwind.tscn -- --bench-ladder=<stamp> --bench-ladder-start-rung=2 --bench-ladder-max-rungs=4`
  → rungs 2-3, ~4.5 min, auto-quits, writes
  `user://benchmark_results/ladder_<stamp>/bench_ladder.json`.
- **NEVER run a second Godot process (gdUnit included) while a benchmark
  runs** — it rotates godot.log mid-run, contends the GPU, and killed one
  ladder silently today.
- The Windows exe detaches from the launcher: background-launch it, then
  watch for process exit (`tasklist`), and read the NEWEST
  `user://logs/godot*.log` (rotation renames the live file when any new
  Godot instance starts).
- gdUnit runner takes ONE `--test` per invocation. Exit 0 = pass.
- Unit tests are NOT a scene smoke: after touching streaming code, launch
  the main scene and grep the log for SCRIPT ERROR before benchmarking.
- A parked, known at-exit crash prints a C++ backtrace AFTER
  "sequence complete" — that one is noise. A backtrace WITHOUT sequence
  complete is a real crash; one flaky native crash near an interior-pocket
  load at ~600 FPS exists (did not reproduce; watch for it).
- Some cells sit forever in `loading` with a deferred interactive tail —
  heartbeat shows `loading=N (tail=M)`; tail entries are by design, and
  the walk-away leak for them was fixed in Phase 0.

## User-gated items (do not do these unpushed)

- **Owed visual check**: user enters an interior door calmly AND rushing —
  wave 2's progressive pocket attach changed when preloaded interiors
  assemble. Ask for this before declaring the pocket work accepted.
- Committing today's tree is the user's call (offer, don't decide).
- Visual verification is ALWAYS interactive (project rule — no screenshot
  harnesses); the user pilots, you tell them what to look for.

## Style notes for this arc

- One measured offender at a time; verify each wave with a ladder before
  the next. Ship small, attributed, reversible fixes.
- Plain English to the user, no jargon walls; lead with the numbers.
- Update the plan doc + project memory as you land things — this handoff
  practice is why you have context right now.
