## Streaming Stutter — Architectural Plan (2026-04-25)

Author: claude
Status: in-flight
Supersedes: every prior plan in `docs/plans/distant_rendering_2026_04/` and `docs/plans/near_optimization_next_2026_04_22.md`. Those are nuked.

---

## Premise

The branch has 30+ commits chasing the same stutter, each fixing a symptom. The architecture is the bug. This plan replaces all of them with a single ordered list of fixes that target the actual root causes, captured fresh from a `--bench-auto` run on 2026-04-25.

User-visible target: **steady ≥200 FPS during fast traversal, no perceptible cell-cross hitch**.

## What the bench shows

Telemetry pulled from a clean `--bench-auto` run, sorted worst-frame:

| Section | Worst | Cause |
|---|---|---|
| `cell_preloader_update` | 832 ms | Speculative `preregister_cell_statics` on main thread |
| `instantiate` | 542 ms | Same prereg + per-iter unbounded inside `process_async_instantiation` |
| `unattributed` (teleport) | 1941 ms | Bracket coverage gap — pending diag |
| Steady-state idle | 215 FPS | Pipeline is fine when nothing loads |

## Architectural problems (plain-English in chat — short form here)

1. **Preloader does sync I/O on the main thread.** `cell_preloader._begin_preload` calls `instantiator.preregister_cell_statics` synchronously, which calls `model_loader.has_animation` per unique prototype, which **sync-loads + instantiates the PackedScene + walks the tree + frees** to read a boolean.
2. **The same expensive work runs twice.** Preloader speculatively, then `cell_manager.request_exterior_cell_async` for real.
3. **Frame budget is structurally unable to bound spikes.** `process_async_instantiation` checks the budget between iterations only. One iter = 30–100 ms cold. 4 ms budget → 540 ms actual.
4. **NEAR tier creates a Node3D per static reference.** S.0/S.1 refactor (commits `0a35ca6`, `d979373`) — ~200 refs/cell × 6 cells = ~1200 Node3Ds. `add_child` cost is O(refs), unmovable off main thread.

## Fix plan — ordered cheapest-first

Each fix lands as one commit, validated by a `--bench-auto` run before the next.

### Fix A — Delete preregister from CellPreloader  (1 commit, ~5 lines)
`src/core/world/cell_preloader.gd:282-285` — drop the `preregister_cell_statics` call. Preloader's contract is `ResourceLoader.load` warming. Pre-registration belongs to the active loader.

**Acceptance:** `cell_preloader_update` autopsy section drops from 832 ms → <10 ms in --bench-auto.

### Fix B — Hard per-iteration budget in `process_async_instantiation`  (1 commit)
`src/core/world/cell_manager.gd:1598` — move the `if elapsed >= budget_usec: break` check **after** each `instantiate_reference`, not just at loop top. Currently a single 100 ms iter blows the budget. Add a per-iter watchdog that warns when one iter exceeds e.g. 8 ms (flags hot prototypes).

**Acceptance:** `instantiate` autopsy section never exceeds 1.5× budget (e.g. 12 ms cap on 8 ms budget). Hot prototypes get logged for further attention.

### Fix C — Eliminate `has_animation` sync load  (1–2 commits)
**Canonical:** add an `is_animated` bool to the prebake .res header. `model_loader.has_animation` reads the metadata, never instantiates. Touchpoint: prebake pipeline (`src/tools/prebake_*`) writes the flag; `model_loader.gd:69` reads the flag from the cache.

**Bridge (if prebake pipeline touch is too big this session):** dispatch the probe to a `WorkerThreadPool` task on first sight. `has_animation` returns `false` until the task completes, then routes correctly on subsequent visits. One frame of mis-routing per prototype, self-corrects. Ship the canonical fix in the same branch.

**Acceptance:** First-visit cell loads no longer show 700+ ms `instantiate` from prereg. `pipe-cell` log line shows pre-compile happens at preload time, not at activate.

### Fix D — Move `preregister_cell_statics` off the main thread  (1 commit)
After Fix C removes the sync-load landmine inside `_should_route_to_renderer`, the body of `preregister_cell_statics` (lines 662-734) is pure data shuffling: dedupe, classify, dispatch. Wrap the whole function body in a single `WorkerThreadPool.add_task` and dispatch one task per cell. Main-thread cost: bind + dispatch, ~µs.

**Acceptance:** No bracketed section in the autopsy attributable to prereg. Heartbeat shows pre-compile counters increment in worker time, not gameplay frames.

### Fix E — NEAR statics off Node3D path  (multi-commit, biggest win)
Roll back the S.0/S.1 "every NEAR ref is a Node3D" refactor for STAT-routed refs only. Door / Container / Activator / NPC / Creature stay Node3D (they need a scene-tree presence). STATs route to the existing `StaticObjectRenderer` (already used for MID), with the existing per-cell merged trimesh collision (commit `3acd4bd`) covering physics.

Reference patterns: `topic_server_direct_pattern.md`, `topic_static_collision_streaming.md`. The infrastructure already exists; it was disabled for NEAR by the S.0/S.1 refactor.

**Acceptance:** Loaded-cells scene tree drops from ~1200 Node3Ds → ~50 Node3Ds (interactives only). `instantiate` autopsy section disappears entirely from frames over 16 ms. ~200 FPS sustained during fast traversal.

### Fix F — Diagnose the 1941 ms teleport unattributed gap  (diagnostic, then fix)
Bracket the gap behind the autopsy: `_emit_startup_progress`, `_check_startup_complete`, `_cell_manager.set_camera_position`. If it still attributes to `unattributed`, the gap is render-thread blocking on shader compile / GPU upload.

**Likely fix:** black-frame overlay during the teleport burst via the existing `LoadingStateMachine` (`docs/systems/loading.md`).

## Out of scope (this plan)

- HLOD, MID, FAR, impostors, distant lights — not the bottleneck. Re-enable after NEAR is solid.
- Shadow optimization — separate plan, separate spike profile.
- Physics tunneling — separate plan.

## Test methodology

Every fix gets validated by a fresh `--bench-auto` run:

```
"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --path "D:/Gamedev/Godotwind/godotwind" -- --bench-auto stutter-fix-N
```

The `AutoBenchRunner` runs settle (waits FPS ≥ 150 for 10 s) → idle 30 s → walk + run flyby (85 s) → teleport → hlod-off. Output: `user://benchmark_results/stutter-fix-N/`.

Per-fix acceptance: read `godot.log` in `C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/logs/`, grep `autopsy` lines, confirm the targeted spike-source dropped to the acceptance threshold above.

## Done definition

- Steady ≥200 FPS during the WALK + RUN segments of `bench_flyby`.
- No `autopsy` log line above 16 ms during traversal.
- No `pipe-cell ... [c:0 m:0 sf:0 dr:>0 sp:0]` (DRAW = first-visibility shader stutter) — engine pre-compile must fire at preload, not activate.
- No `_unload_cell` line above 5 ms.
