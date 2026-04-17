# Autonomous Performance Audit — 2026-04-17

**For the next agent: paste §1 into a fresh Claude Code session on this repo.** Everything else is supporting context that stays in the file.

User will be away. This is an **autonomous** audit — no human in the loop. You drive.

---

## 1. Prompt (copy verbatim)

```
You are running an autonomous performance audit on the Godotwind Godot 4.6 project after a 6-commit distant-rendering refactor (commits 8f7d6f9..574c204 on branch `perf/distant-rendering-2026-04-17`, off `refactor/lod-b-wide`). The user is away. You must run the full audit end-to-end and write up findings. Do not wait for user confirmation.

Read in this order, no skimming:
1. .claude/CLAUDE.md — engineering principles (industry-standard-never-kludge, simplicity-over-over-engineering, reviewer-engagement-scope). The "DON'T use automated screenshot/auto-capture harnesses" anti-pattern applies to VISUAL verification. Performance benchmarks that run scripted camera paths to collect numeric metrics are a DIFFERENT thing and are allowed — they're the whole point of `streaming_benchmark.gd`.
2. docs/audit/DISTANT_RENDERING_AUDIT_2026_04_17.md — the problem map.
3. docs/audit/DISTANT_RENDERING_PLAN_2026_04_17.md §8 status snapshot — all phases DONE (code) pending runtime verification. YOU are that runtime verification.
4. docs/audit/AUTONOMOUS_PERF_AUDIT_HANDOFF_2026_04_17.md §2-6 (this file) — acceptance criteria, tooling, procedure.
5. docs/STATUS.md — what's meant to work.

Ground rules (non-negotiable):
- **Only two sources of truth: the code in `src/` and runtime numbers from a live Godot scene.** Docs can lie. Verify every claim against current code.
- **Headless framerates are NOT trustworthy** (user memory `feedback_headless_framerates.md`). ALL perf numbers must come from a real-renderer launch. Headless is only for parse-check.
- **Auto-capture screenshots / scripted visual harnesses FORBIDDEN** for visual verification. Scripted camera PATHS that collect numeric metrics (FPS, draws, objects, primitives, memory) are fine — that's what `streaming_benchmark.gd` does. Numeric-only autonomous passes are the whole reason this handoff exists.
- **Never delete/nuke in-progress work autonomously.** If measurements look bad, write up findings, don't `git checkout --` / revert. The user will decide.
- **Stop at the first two pre-existing flaky/failure patterns already in the project and work around them, don't patch them:**
  - pre-existing shutdown Signal 11 (fires AFTER WM_CLOSE_REQUEST — NOT a runtime crash, NOT from this refactor)
  - 9 pre-existing test failures in `tests/unit/test_object_paging_kernel.gd` (flagged in Phase 3 handoff)

Your mission (in order):

A. LOG HYGIENE PASS
   1. Launch `scenes/Godotwind.tscn` real-renderer (the `Godot_v4.6-stable_mono_win64.exe --path "D:/Gamedev/Godotwind/godotwind"` command — NOT --headless, NOT --quit-after). Redirect stdout + stderr to a timestamped file under `docs/audit/perf-reports/<stamp>/launch.log`.
   2. Let it run 30 seconds then send WM_CLOSE via taskkill (see §4 of this handoff for the exact command — SIGTERM, not -F, so the shutdown logger fires).
   3. Grep the log for `SCRIPT ERROR`, `Identifier not found`, `Parse Error`, `Invalid call`, `Invalid get index`, `Invalid set index`, `push_error`, stack traces NOT matching the pre-existing whitelist (see §5).
   4. Record anything new under §4.1 of `DISTANT_RENDERING_PLAN_2026_04_17.md` (append, don't overwrite).
   5. Pass if the only remaining errors are on the whitelist.

B. COLD-START SETTLE TIME
   1. Launch + start a stopwatch at process spawn.
   2. Tail `launch.log` for `Startup phase complete after N frames`.
   3. Extract FPS from the first 30 seconds of heartbeat lines (`fps=XX.X` in the log format). Find the first 3-consecutive-seconds window where fps ≥ 55.
   4. Pass criterion: time-to-stable-55 ≤ 20 seconds cold start. User accepts 14 FPS for 1-2 min → ≥ 55 FPS ≤ 20s was the Phase 7 target.
   5. Fail = settle took > 30 seconds OR never reached 55 FPS. In that case: capture the `[audit +Ns]` lines from the log (post-startup audit dumps at 5 s cadence, up to 60 s) — they include the per-phase breakdown. Narrow which phase is the bottleneck (unload / async / inst / promo / coll / defer / queue). Log the hypothesis, do NOT patch.

C. STATIC-CAMERA TIER VALIDATION
   1. Extend `src/tools/streaming_benchmark.gd` with a new `bench_tiers` mode that holds the camera at the default Seyda Neen spawn for 30 seconds and samples:
      - `rendered_objects` + `draw_calls` + `primitives` + FPS
      - `registry_batches` + `registry_slots` (phase 3 occupancy)
      - `hlod_stats.active_cells` + `chunks_tier_1` + `chunks_tier_2` (phase 4 chunks)
      - `_impostors.size()` (FAR tier count)
   2. Run it. Save per-sec log + summary JSON to `docs/audit/perf-reports/<stamp>/bench_tiers.json`.
   3. Pass criteria:
      - MID tier populated: `registry_batches > 0`, `registry_slots > 0`
      - HLOD tier populated: `chunks_tier_1 >= 1` OR `chunks_tier_2 >= 1` (one is enough at coast — inland will have both)
      - FAR tier populated: `impostors > 100` (steady-state — cold may be lower during bake)
      - FPS ≥ 50 at steady state (no churn)
   4. If a tier reads zero occupancy while the others populate, the phase for that tier didn't land correctly — write up with SHA reference.

D. MODERATE-SPEED FLYOVER TIER VALIDATION
   1. Run the EXISTING `bench` command (85 s Seyda Neen flyby — see `src/tools/streaming_benchmark.gd` for the segments). Per-frame CSV + JSON summary land in `user://benchmark_results/<ts>/`. Copy to `docs/audit/perf-reports/<stamp>/bench_flyby/`.
   2. For each of the 6 segments (settle, idle, walk, vista, pan, run), extract:
      - avg FPS, p95 frame ms
      - avg draw_calls, avg rendered_objects, avg primitives
      - tier occupancy (parsed from heartbeat log alongside the run)
   3. Pass criteria per segment:
      - `idle`     FPS ≥ 55   — fully-loaded static view
      - `walk`     FPS ≥ 50   — 7 m/s traverse, some streaming churn
      - `vista`    FPS ≥ 50   — 80m altitude, FAR-tier stress
      - `pan`      FPS ≥ 55   — 360° rotation, frustum stress only
      - `run`      FPS ≥ 45   — 15 m/s traverse, heavy streaming
      - `draw_calls` at `vista` < 8000 (pre-refactor was ~10-15k+ uncontrolled)
      - No segment has a p95 frame > 50 ms
   4. Any segment that fails — log the failing numbers, do NOT patch.

E. TELEPORT BURST VALIDATION (phase 7)
   1. Add a `bench_teleport` mode that jumps the camera > 500 m (say, from (-2,-9) cell-space to (-10,-10)) in a single frame, logs 20 s post-teleport FPS, then checks for a `Teleport detected — re-entering startup burst mode` line in the log.
   2. Pass criteria:
      - `Teleport detected` log line fires
      - post-teleport FPS recovers to ≥ 50 within 15 s
      - no new script errors during burst
   3. Fail = teleport not detected, or recovery > 25 s, or FPS never > 50 post-teleport.

F. HLOD-OFF DEBUG VALIDATION (phase 4)
   1. Add or extend `bench_hlod_off` mode — runs `hlod_disable` console command, waits 5 s, samples 10 s.
   2. Pass criteria:
      - `rendered_objects` within 10s drops to ONLY NEAR-tier refs (typically <500 for a loaded cell ring)
      - `impostors` not visible (either hidden or count=0 visible)
      - `registry_slots` still populated but MID range clamped (distant instances culled out of view)
   3. This is the "only NEAR past 150m" user rule — acceptance is cosmetic (no visible pop, no errors) plus the numeric drop.

G. WRITE-UP
   1. Append a new `§4.N Autonomous audit <stamp>` section to `docs/audit/DISTANT_RENDERING_PLAN_2026_04_17.md` with pass/fail per A-F, numbers, and files under `docs/audit/perf-reports/<stamp>/`.
   2. Flip phase statuses in §8 from "DONE (code) — runtime verify pending user" to "DONE (runtime verified)" for any phase whose acceptance gate passed. Leave FAIL phases alone + document the gap.
   3. Commit one commit per logical change. Final commit: `docs(audit): autonomous perf audit <stamp> results`.

H. If you invented ANY new code (new bench modes, log parser), add a unit test OR a smoke test that runs fast. Don't ship untested extensions.

Commit hygiene: HEREDOC commit messages. Co-Author line. One commit per logical change. Do NOT squash.

Scope creep boundary: this is a VERIFICATION pass, not a new-feature pass. If you find perf regressions, WRITE THEM UP — don't start phase 8. If you need to extend `streaming_benchmark.gd`, fine; if you want to rewrite it, no — escalate in a final write-up for the user to review.

(read AUTONOMOUS_PERF_AUDIT_HANDOFF_2026_04_17.md §2-7 for procedure detail + error whitelist + tooling reference)
```

---

## 2. Acceptance Criteria Reference

Pulled forward from the plan. Use these as the gates, don't re-derive.

| Test | Criterion | Source |
|---|---|---|
| A. Log hygiene | zero SCRIPT ERROR / Identifier not found / Parse Error outside whitelist (§5) | this file |
| B. Cold-start | time-to-stable-55 FPS ≤ 20 s | Phase 7 plan §acceptance |
| C. Static tiers populated | MID: registry_batches > 0; HLOD: tier_1 or tier_2 >= 1; FAR: impostors > 100; steady FPS ≥ 50 | phase 3/4/6 acceptance |
| D. Flyover segments | idle ≥ 55, walk/vista ≥ 50, pan ≥ 55, run ≥ 45; vista draw_calls < 8000; p95 < 50 ms all segs | plan §Phase 3/4/5 |
| E. Teleport | "Teleport detected" log fires; FPS recovers to ≥ 50 within 15 s | Phase 7 plan §acceptance |
| F. HLOD-off | rendered_objects drops past 150m to <500; impostors hidden; no errors | Phase 4 user rule |

**User's pre-session baseline (verbal):** ~14 FPS cold for 1-2 min, ~50 FPS steady, MID dominant. Anything below that = regression, flag loudly.

---

## 3. Tooling Reference

### Console commands (backtick `` ` `` to open)

| Command | What it does | Where the code is |
|---|---|---|
| `hud` | toggle live overlay (frame ms, p95, draws, objects, primitives, phase breakdown) | `benchmark_hud.gd` |
| `bench` | run the 85 s scripted Seyda Neen flyby, write CSV + JSON to `user://benchmark_results/<ts>/` | `streaming_benchmark.gd` |
| `proto_registry` | batch/slot counts for phase 3 registry | `world_explorer.gd:_cmd_proto_registry` |
| `hlod_enable` / `hlod_disable` | master switch for MID + HLOD + FAR past NEAR | `world_explorer.gd:_cmd_hlod_enable/disable` |
| `hlod_stats` | active chunks, pending merges, cache entries, per-tier counts | `world_explorer.gd:_cmd_hlod_stats` |
| `toggle <name>` / `toggle only <name>` / `toggle none` | A/B isolation — flags: `terrain, ocean, sky, weather, characters, impostors, mid_objects, near_objects, hlod, shadows, postfx` | `subsystem_toggles.gd` |
| `lod_info` | viewport mesh_lod_threshold, mesh_types breakdown, LOD chain coverage | `lod_debug_commands.gd:_cmd_lod_info` |
| `lod_bias <f>` | apply lod_bias to all registry batches + legacy instances | `lod_debug_commands.gd:_cmd_lod_bias_global` |

### Launch commands

```bash
# REAL renderer (required for FPS — NEVER headless for perf)
"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --path "D:/Gamedev/Godotwind/godotwind"

# Parse-check only (headless OK for syntax — NOT for FPS)
"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --headless --quit-after 15

# Tests (gdUnit4)
"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --path "D:/Gamedev/Godotwind/godotwind" res://tests/run_tests.tscn
# Expect: 114 total, 9 pre-existing paging failures (WHITELIST — leave them).

# C# rebuild (MUST run if you touch any .cs — user won't do this for you)
cd D:/Gamedev/Godotwind/godotwind && dotnet build Godotwind.sln

# Shader cache clear (MUST run if you touch any .gdshader)
rm -rf "D:/Gamedev/Godotwind/godotwind/.godot/shader_cache"
```

### Clean scene exit (for autonomous runs)

Godot on Windows responds to `taskkill /PID <pid>` as a graceful WM_CLOSE — logger fires `USER_QUIT` + shutdown summary + the (pre-existing, benign) Signal 11. `/F` is SIGKILL — skips the shutdown logger, bypasses the signal 11, but also loses the final debug report + queue-drain logs.

Example: launch in background, tail log, graceful kill after 30 s:

```bash
# Bash example — adjust for your harness
"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --path "D:/Gamedev/Godotwind/godotwind" > /tmp/run.log 2>&1 &
GODOT_PID=$!
sleep 30
taskkill //PID $GODOT_PID   # graceful — WM_CLOSE_REQUEST
wait $GODOT_PID             # let shutdown logger finish
```

### Heartbeat log format

Every 5 s the streaming manager logs:

```
[INFO] [streaming] heartbeat sec=N frame=F fps=XX.X proc=Y.Yms phys=Z.Zms draws=D objs=O prims=Pk loaded=L loading=ℓ reg_batches=RB reg_slots=RS
```

Parse: `reg_batches` and `reg_slots` are Phase 3 registry occupancy (post 0280a28 fix). `draws` is total RENDER_TOTAL_DRAW_CALLS_IN_FRAME. `objs` is RENDER_TOTAL_OBJECTS_IN_FRAME.

### Post-startup audit lines

Every 5 s for 60 s post-startup, the streaming manager also logs:

```
[INFO] [streaming] [audit +Ns] fps=X proc=Y.Yms frame=Z.Zms queue=Q burst=Y|N | unload=... async=... inst=... promo=... coll=... defer=... (ms)
```

Per-phase `_process` breakdown. Useful when a phase of the streaming pipeline is the bottleneck vs rendering.

---

## 4. Launch + Log Collection Procedure

The audit agent runs entirely from `Bash` tool calls. No human prompts.

### 4.1 Launch + capture

```bash
STAMP=$(date +%Y-%m-%d_%H-%M-%S)
REPORT_DIR="docs/audit/perf-reports/$STAMP"
mkdir -p "$REPORT_DIR"

# Real-renderer launch, background, stdout+stderr to launch.log
"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" \
    --path "D:/Gamedev/Godotwind/godotwind" \
    > "$REPORT_DIR/launch.log" 2>&1 &
GODOT_PID=$!

# Let it boot + settle
sleep 40

# Graceful quit
taskkill //PID $GODOT_PID
wait $GODOT_PID 2>/dev/null
```

### 4.2 Extract the numbers

```bash
# FPS evolution
grep "heartbeat sec=" "$REPORT_DIR/launch.log" | sed 's/.*sec=\([0-9]*\).*fps=\([0-9.]*\).*draws=\([0-9]*\).*objs=\([0-9]*\).*reg_batches=\([0-9]*\).*reg_slots=\([0-9]*\).*/\1,\2,\3,\4,\5,\6/' > "$REPORT_DIR/heartbeat.csv"

# Errors
grep -E "(SCRIPT ERROR|Identifier not found|Parse Error|Invalid call|Invalid get index|Invalid set index)" "$REPORT_DIR/launch.log" > "$REPORT_DIR/errors.txt" || true

# Warnings (info only)
grep "WARNING:" "$REPORT_DIR/launch.log" > "$REPORT_DIR/warnings.txt" || true

# Startup milestone
grep "Startup phase complete" "$REPORT_DIR/launch.log" > "$REPORT_DIR/startup_milestone.txt"
```

### 4.3 Drive console commands autonomously

The `bench` command is triggered via console input. The current benchmark harness accepts a command-line argument or a debug-console key. If you need to extend `streaming_benchmark.gd` to add `bench_tiers` / `bench_teleport` / `bench_hlod_off` modes, they should be invokable via:

1. A `--bench <mode>` command-line flag on the main scene, OR
2. A timer-driven autorun that starts 3 s after streaming settles and writes to `user://benchmark_results/<ts>/`.

Option 2 is simpler for an autonomous run — no console-input tooling required. Modify `world_explorer.gd`'s init hook + `streaming_benchmark.gd` to key off an env var or an OS.get_cmdline_args() scan.

---

## 5. Error Whitelist (ignore these — pre-existing, not this refactor)

These appear in a CLEAN launch on master. If they're the ONLY errors, log hygiene passes.

```
# Dummy-renderer (only fires --headless — NEVER in real-renderer launch, ignore if you see it)
ERROR: Parameter "m" is null.
ERROR: Parameter "t" is null.
ERROR: Initializing already initialized RID
ERROR: Parameter "mem" is null.
ERROR: unimplemented base type encountered in renderer scene cull

# Terrain3D addon (Godot 4.6 API deprecation, addon bug, benign)
WARNING: instance_reset_physics_interpolation() is deprecated.
WARNING: Terrain3D#...:_notification:...: free_editor_textures requires `Assets` be saved to a file
WARNING: [WARN] [textures] NN textures won't get slots
WARNING: TerrainTextureLoader: Maximum texture slots reached (32)

# Shutdown crash (pre-existing — fires AFTER USER_QUIT, not during runtime)
CrashHandlerException: Program crashed with signal 11
```

Anything ELSE = investigate. Specifically flag:
- `Invalid call` / `Invalid get index` / `Invalid set index` — scripted path broken
- Stack traces mentioning `native_streaming_manager.gd` / `prototype_registry.gd` / `prototype_batch.gd` / `object_paging.gd` / `native_impostor_renderer.gd` — refactor surface
- C# exceptions (`System.*Exception` / `Godot.*Exception`) — WorldMidCuller.cs surface

---

## 6. Known Results from the Pre-Audit Session

Raw data from `claude`'s own launch of Godotwind.tscn at 20:14-20:20 on 2026-04-17 — treat as preliminary. A better flyby path with numerical rigor is the WHOLE POINT of the autonomous pass. 343-second session:

**Stable steady-state (sec=203-278, static camera near spawn):**
- FPS 55-57
- draws 7644, objs 10838-11100, prims 2.6M
- proc 22-26 ms
- User's pre-session verbal baseline was ~50 FPS steady → ~10% gain, NOT the predicted +20-30 FPS

**Heavy-load bursts (sec=293-348, during teleport / new-area loading):**
- FPS 12-42 oscillating
- proc spikes to 107-765 ms — these are phase-7 burst frames
- draws 460-1937 (lower because camera is in new area, fewer refs loaded)

**Interpretation:**
- MID registry + phase 4 dedup work (draws 7644 not 10-15k+)
- cold-start burst may be working but not measured cleanly
- NO flyby at moderate speed was done — the autonomous run must do this

**A suspicious number:** `objs=10838` with `draws=7644` means ~1.4 objects per draw — VERY low batching. For a world-scoped MultiMesh, we'd expect `objs > draws × 10` at steady state. Either:
- registry is creating many batches with small slot counts (too-fine prototype dedup)
- or there are many non-registry draws (Terrain3D clipmap, NPCs, UI, HLOD chunks, each its own RS instance)

Autonomous audit should break this down via `proto_registry` + `hlod_stats` mid-flyby. If `registry_batches` is >1000 with avg `registry_slots / registry_batches < 5`, that's a batch-fragmentation hypothesis worth flagging.

---

## 7. Branch + Commit State

```
perf/distant-rendering-2026-04-17  (you land here)
  ↑ 8+ commits from the refactor session + handoff adjustments
refactor/lod-b-wide  (parent)
  ↑ N commits
master
```

Commits in order (code-complete phases):
- `89780df` phase 3 step 1 — skeletons + tests
- `d71302c..5dda7a0` phase 3 steps 2-7 — registry wiring, C# cull, fade, legacy delete
- `8f7d6f9` phase 4 — HLOD-on + tier-0 retire
- `0983507` phase 5 — FAR_START 1km
- `387ac49` phase 6 — async impostor texture rebuild
- `134ec06` phase 7 — teleport detection
- `574c204` phase 3 cleanup — debug tool RID iteration
- `0294efd` docs — status snapshot
- `cdc73f4 / 0280a28` — user follow-up fixes (heartbeat registry stats, misc)

**Do NOT touch master.** All commits on `perf/distant-rendering-2026-04-17`. Fully revertable.

---

## 8. If Something Blows Up During Audit

1. **Scene won't launch.** Parse-check first: `"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --headless --quit-after 15 2>&1 | grep -iE "SCRIPT ERROR|Parse"`. Bisect commits if needed (`git bisect` vs c207f1c from before phase 3 ships).
2. **FPS pattern looks fundamentally wrong.** DO NOT patch. Write up the full per-phase breakdown to the report + §4.N of plan. User decides.
3. **A test newly fails.** Check if it's in the 9-pre-existing whitelist (all in `test_object_paging_kernel.gd`). If it's a NEW failure, that IS blocker — write up with stack + commit SHA where it started.
4. **Benchmark harness breaks (`bench` crashes during flyby).** Extend it, don't bypass. The whole point is automated runs.
5. **Shutdown Signal 11.** Pre-existing. Ignore unless it's not on shutdown.

---

## 9. Deliverables

At end of run, `docs/audit/perf-reports/<stamp>/` should contain:

```
launch.log                   raw Godot stdout+stderr
heartbeat.csv                parsed FPS / draws / objs evolution
errors.txt                   non-whitelist errors (should be empty)
warnings.txt                 all warnings (FYI, not a gate)
startup_milestone.txt        "Startup phase complete after N frames"
bench_tiers.json             test C output
bench_flyby/                 test D output (CSV + JSON from bench cmd)
bench_teleport.json          test E output
bench_hlod_off.json          test F output
SUMMARY.md                   your write-up — pass/fail per test A-G
```

And one commit:

```
docs(audit): autonomous perf audit <stamp> results

Pass/fail summary [pass count]/[total]. Key metrics, files in
docs/audit/perf-reports/<stamp>/. Regressions flagged in §4.N of
DISTANT_RENDERING_PLAN.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

That's it. Ship.
