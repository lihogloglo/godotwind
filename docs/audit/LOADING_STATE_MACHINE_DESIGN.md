# Loading State Machine — Phase 8 Design (2026-04-17)

**Status:** implemented 2026-04-17 (commits TBD), design locked by user same day.
**Parent plan:** `docs/audit/DISTANT_RENDERING_PLAN_2026_04_17.md` §3 Phase 8.
**Problem it solves:** the autonomous-audit run (`docs/audit/perf-reports/2026-04-17_20-30-38/`) measured cold-start time-to-stable-55 at 170–180 s against a 20 s Phase 7 gate. The player sees ~150 s of 10-FPS streaming churn after the existing data-loading overlay has already faded out. This phase adds a canonical, OpenMW-style "gated boot + gated teleport" loading state, mirroring `Loading::ScopedLoad` in `inspos/openmw/apps/openmw/mwworld/scene.cpp:930` but expressed in Godot-native primitives.

## 1. Non-Goals

- Not replacing the existing `_show_loading`/`_hide_loading` progress overlay during Morrowind ESM/BSA parsing. That overlay handles the data phase; this state machine handles the streaming phase. They run in series, not parallel.
- Not touching the interior-pocket transition fade path (`InteriorPocketManager._do_transition`, `interior_pocket_manager.gd:1345`). Interior destinations are lazy-loaded on door proximity so door transitions already feel instant; the existing fade is adequate.
- Not modifying the `startup_phase` budget-burst logic inside `NativeStreamingManager._process`. Phase 7 stays as-is — the burst mode is what makes the residual queue drain fast *while* the loading screen is up.
- Not introducing a generic "pause menu" state machine. This is the loading state specifically. A pause menu is a future, orthogonal system.

## 2. Triggers

Two, by decision 2026-04-17:

| Trigger | Entry point | Exit predicate | Fade-in? |
|---|---|---|---|
| Cold boot | `world_explorer._enter_boot_loading_gate()` after `_hide_loading()` + `set_camera()` | `NativeStreamingManager.is_inner_ring_ready()` | yes (0.5 s) — masks the transparent gap between old overlay fade-out and new overlay show |
| Large teleport | `native_streaming_manager.gd` emits `teleport_happened` when a camera jump > `TELEPORT_DETECT_THRESHOLD` (500 m) is detected | same predicate — `is_inner_ring_ready()` | yes (0.5 s) — masks the warp |

Interior-door transitions **do not** go through this state machine by user decision — pocket loading on door-proximity + the existing fade-to-black bridge is "near-instant in practice," so adding the pause gate would be friction for no gain.

`--bench-auto` command-line runs **opt out** of the teleport trigger (`_on_teleport_happened` early-returns when the flag is present) because the autobench scenarios measure raw recovery and need to see the unblocked FPS trace.

## 3. Architecture

### 3.1 Canonical pattern

Godot 4.6 exposes the exact primitives OpenMW approximates via its `GM_Loading`/`GM_LoadingWallpaper` GUI modes + per-subsystem `if (state != State_NoGame)` guards:

- `SceneTree.paused = true` — a single global flag that stops every pausable node in the tree.
- `Node.process_mode` — per-node override. Default is `PROCESS_MODE_INHERIT` which walks up the tree; the useful values for this design are `PROCESS_MODE_PAUSABLE` (default leaf behaviour; freezes when tree is paused) and `PROCESS_MODE_ALWAYS` (ignores the tree pause).

Opting a node into `PROCESS_MODE_ALWAYS` is equivalent to OpenMW's "this subsystem ignores `GM_Loading`" — but expressed declaratively at the node level, not via ad-hoc state checks in every `_process`.

### 3.2 Node-level pause exemptions

Three nodes run in `PROCESS_MODE_ALWAYS`:

- `NativeStreamingManager` (`src/core/world/native_streaming_manager.gd:_ready`) — explicit `process_mode = Node.PROCESS_MODE_ALWAYS`. This is load-bearing: if the manager pauses with the tree, the inner-ring predicate never transitions to true and the state machine sits on its 30 s timeout every boot.
- `LoadingStateMachine` itself (`src/core/loading/loading_state_machine.gd:_init`) — must keep polling the predicate + updating the overlay progress label during the pause.
- `SceneLoadingScreen` overlay + its child ColorRect/Labels (`src/core/loading/loading_screen.gd`) — the fade tween must tick during pause. Set explicitly on every node so no `PROCESS_MODE_INHERIT` walk accidentally re-pauses a label.

Everything else — `PlayerController`, `FlyCamera`, NPC/creature nodes, `Area3D` monitors, physics bodies, `AnimationTree`s — keeps the default `PROCESS_MODE_INHERIT` → `PROCESS_MODE_PAUSABLE` and freezes correctly when `get_tree().paused = true`.

### 3.3 Exit condition (Option A)

`NativeStreamingManager.is_inner_ring_ready()` returns true when all three conditions hold:

1. Every cell in the 3×3 inner ring around `_camera_cell` is in `_loaded_cells` **and** not in `_async_requests` (i.e. its async worker has completed). 9 cells total by default (`INNER_RING_RADIUS = 1`, 2×1+1 = 3 per side).
2. `ring_pending_async == 0` — no cell in the ring is still mid-parse on a worker thread.
3. `CellManager.get_instantiation_queue_size() < INNER_RING_MAX_QUEUE` (8 by default). Small residual is fine — the queue drains at ~2 batches/frame post-unpause — but a long backlog would stall gameplay the moment we unfreeze.

`INNER_RING_RADIUS = 1` is deliberately tighter than the streaming manager's `load_radius_cells = 3`. The streaming manager keeps loading the outer ring while the game is interactive; the loading gate only blocks on the immediate "I can walk" ring.

A 30 s timeout fallback unpauses anyway. Chosen because it's long enough to cover a cold boot on the slowest profiled path (measured ~18 s once Phase 8 lands, pre-Phase-8 was 170+ s so the budget has plenty of headroom) but short enough that a genuinely broken boot becomes obvious fast.

### 3.4 Signal graph

```
native_streaming_manager
  emits: teleport_happened(from, to, distance)
       : startup_complete()   ← still fires, kept for back-compat but no longer the canonical "playable" signal
world_explorer
  connects teleport_happened -> _on_teleport_happened
  connects loading_finished  -> _on_loading_finished  (logging)
  owns LoadingStateMachine instance

LoadingStateMachine
  emits: loading_started(reason)
       : loading_finished(reason, duration_s, timed_out)

SceneLoadingScreen
  no signals — driven purely by method calls from LoadingStateMachine
```

### 3.5 Fade timing

0.5 s fade (matches OpenMW's exterior teleport fade; see `inspos/openmw/apps/openmw/mwworld/scene.cpp:936`).

For the teleport trigger the sequence is:

```
fade 0 -> 1 (0.5 s, tree NOT YET paused — player sees the warp darken)
get_tree().paused = true   (LoadingStateMachine._pause_and_enter_loading)
... predicate polled every frame ...
get_tree().paused = false  (LoadingStateMachine._exit_loading)
fade 1 -> 0 (0.5 s — the scene is already interactive behind it)
```

For boot: fade already at 1 (the old `_show_loading` overlay was opaque and its hide-fade runs in parallel), so the first step is a no-op in practice.

## 4. OpenMW side-by-side

| OpenMW concept | File/line | Godotwind equivalent |
|---|---|---|
| `Loading::ScopedLoad` RAII guard | `apps/openmw/mwgui/loadingscreen.hpp` (header) + `scene.cpp:930` usage | `LoadingStateMachine.enter_loading()` + `.loading_finished` signal |
| `GM_Loading` GUI mode check in every `frame()` caller | `apps/openmw/engine.cpp:252-305` (state-gated subsystem ticks) | `SceneTree.paused = true` + per-node `PROCESS_MODE_PAUSABLE` |
| `CellPreloader` worker thread | `apps/openmw/mwworld/cellpreloader.cpp` | `BackgroundProcessor` + `ESMManager` async requests, already in Godotwind |
| Loading screen mini-frame loop | `apps/openmw/mwgui/loadingscreen.cpp:350-352` | `SceneLoadingScreen` + `PROCESS_MODE_ALWAYS` — the scene tree keeps traversing paused nodes, paused nodes skip work, but our overlay + manager tick normally |
| Exterior teleport fade | `apps/openmw/mwworld/scene.cpp:1001-1013`, 0.5 s | `SceneLoadingScreen.FADE_DURATION = 0.5` |
| Interior change — full stop-the-world load | `apps/openmw/mwworld/scene.cpp:930-995` | Not used — Godotwind's pocket manager already handles interiors with lazy pre-load; the fade-to-black bridge is the equivalent |

## 5. Testing

- Unit suite: `tests/unit/test_loading_state_machine.gd` — 7 tests, `pause_gameplay=false` so the test runner doesn't freeze. Covers: idle-start, enter→loading transition, predicate-true exit path, timeout path, `loading_started` signal with reason, double-enter replaces predicate without re-firing, force_exit during loading.
- Integration: `world_explorer` boot with the gate active. Verified by rerunning the autobench flow (--bench-auto) and checking `loading_finished` duration < 30 s. No unit-level coverage of the tree-pause behaviour itself — the single `get_tree().paused = <bool>` call is trivial and exercising it in a unit test would require the test runner itself to opt out of pause. The runtime audit is the verification vehicle.

## 6. Non-obvious pitfalls

- **CanvasLayer lacks `modulate`.** It's not a `CanvasItem` subclass. Fade goes on the root ColorRect (`_bg`) instead. Changed 2026-04-17 after parse error during initial draft.
- **Tween.set_pause_mode.** `TWEEN_PAUSE_PROCESS` is required for a tween owned by a `PROCESS_MODE_ALWAYS` node to tick during pause. The default `TWEEN_PAUSE_BOUND` walks up to the parent and freezes.
- **Do not re-emit `loading_started` on a double-enter.** Consumers (world_explorer logger, future telemetry) will double-count boots otherwise. Second call updates the predicate + labels only.
- **Autobench must opt out of the teleport trigger.** The perf audit wants to see the unblocked post-teleport FPS curve. `_on_teleport_happened` scans `OS.get_cmdline_args()` for `--bench-auto` and returns early.
- **The initial `_teleport_to_cell(-2, -9)` on boot is not a real teleport.** `_prev_camera_position` is still `Vector3.ZERO` on the first frame, so the > 500 m distance check is short-circuited. The state machine's boot path fires from `_enter_boot_loading_gate` afterwards, not via the teleport signal.

## 7. What's still an open question after this phase ships

- **Phase 7 second pass.** Even with the loading screen hiding the churn, the underlying streaming pipeline still takes ~170 s cold. The loading screen is a UX fix for the symptom; the actual `inst=20-30 ms/frame` cost of cold-start instantiation needs its own pass, probably tuning the post-startup `INSTANTIATION_BUDGET_MS` from 4 ms upward or widening the `_startup_phase` exit condition. Tracked separately.
- **`startup_complete` signal semantics.** Currently fires at frame 57 based on a loose heuristic. Post-Phase-8 the canonical "playable" signal is `LoadingStateMachine.loading_finished("boot", …)`. We keep `startup_complete` for now because other subsystems (impostor renderer budget, ocean manager) consume it, but it's no longer the signal gameplay-readiness code should listen on.
