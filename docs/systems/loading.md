# Loading State Machine (Phase 8)

**Status:** shipped 2026-04-17 (`85648e9 feat(phase8): canonical loading state machine (cold-boot + teleport gate)`). OpenMW-style `GM_Loading` semantics expressed in Godot-native primitives.

Canonical pause-gated boot using `SceneTree.paused = true` plus `PROCESS_MODE_ALWAYS` on the three nodes that must keep ticking during a pause (streaming manager, state machine, loading overlay). No custom per-node process_mode hacks — every other node inherits `PROCESS_MODE_PAUSABLE` and freezes correctly.

## Files

```
src/core/loading/loading_state_machine.gd  — IDLE / ENTERING / LOADING / EXITING states, predicate-polled exit, 30s timeout
src/core/loading/loading_screen.gd         — CanvasLayer overlay + 0.5s fade tween, driven by state machine method calls
src/core/world/native_streaming_manager.gd — `process_mode = PROCESS_MODE_ALWAYS` (line ~_ready)
                                             `signal teleport_happened(from, to, distance)` (line 72, emitted at line 582)
                                             `is_inner_ring_ready()` exit predicate
src/tools/world_explorer.gd                — owns the LoadingStateMachine instance, calls `_enter_boot_loading_gate()` after _hide_loading()
tests/unit/test_loading_state_machine.gd   — 7 tests, pause_gameplay=false so the runner doesn't freeze
```

## Triggers

| Trigger         | Entry                                          | Exit predicate                | Fade    |
|-----------------|------------------------------------------------|-------------------------------|---------|
| Cold boot       | `world_explorer._enter_boot_loading_gate()`    | `is_inner_ring_ready()`       | 0.5s in, 0.5s out |
| Large teleport  | `NativeStreamingManager.teleport_happened` > 500m | `is_inner_ring_ready()`    | 0.5s in, 0.5s out |

Interior-door transitions do **not** go through this gate — pocket loading on door-proximity + the existing fade-to-black bridge is near-instant in practice. `--bench-auto` opts out of the teleport trigger (autobench needs the unblocked FPS curve).

## Exit predicate

`NativeStreamingManager.is_inner_ring_ready()` returns true when all three hold:

1. Every cell in the 3×3 inner ring (`INNER_RING_RADIUS = 1`) around `_camera_cell` is in `_loaded_cells` and not in `_async_requests`.
2. `ring_pending_async == 0` — no inner-ring cell still parsing on a worker.
3. `CellManager.get_instantiation_queue_size() < INNER_RING_MAX_QUEUE` (8).

30s timeout fallback unpauses regardless. Pre-Phase-8 cold-boot was 170+s; post-Phase-8 cold-boot stabilizes around 18s (measured), so the 30s budget has headroom but still makes a genuinely broken boot obvious fast.

## `pause_gameplay` default (current nuance)

**Default is `false`** pending a follow-up on `model_loader` pause-safety. See `loading_state_machine.gd:111` (`pause_gameplay: bool = true`) — the parameter default inside the state machine is `true`, but every caller in `world_explorer.gd` passes `false` (lines 544, 597) until the model_loader pause-safety pass lands. Unit tests also pass `false` (the test runner can't freeze itself).

Recent commit chatter reflects two flip-flops — `5c1bc88 chore(phase8): disable auto-trigger pending model_loader instantiate-race fix` then `da213fd fix(phase8): re-enable auto-trigger — sig11 is pre-existing, not a Phase 8 regression`. Auto-trigger is currently **enabled**; the sig11 is not a Phase 8 regression.

## Signal graph

```
NativeStreamingManager
  emits: teleport_happened(from, to, distance)   — when camera jump > 500m detected
       : startup_complete()                      — kept for back-compat, no longer the canonical "playable" signal

world_explorer
  connects teleport_happened  -> _on_teleport_happened
  connects loading_finished   -> _on_loading_finished  (logging)
  owns LoadingStateMachine instance

LoadingStateMachine
  emits: loading_started(reason)
       : loading_finished(reason, duration_s, timed_out)

SceneLoadingScreen
  no signals — driven purely by method calls from the state machine
```

## Pause-exempt nodes

Three nodes run `PROCESS_MODE_ALWAYS`:

- `NativeStreamingManager` — must keep draining queues during pause so `is_inner_ring_ready()` ever flips true.
- `LoadingStateMachine` — polls the predicate + updates overlay labels.
- `SceneLoadingScreen` + children — fade tween must tick during pause (also uses `Tween.set_pause_mode(TWEEN_PAUSE_PROCESS)`, since the default `TWEEN_PAUSE_BOUND` walks up to the owning node and freezes).

Everything else — `PlayerController`, `FlyCamera`, NPCs, Area3D monitors, physics bodies, AnimationTrees — keeps default `PROCESS_MODE_INHERIT → PAUSABLE` and freezes on `get_tree().paused = true`.

## Non-obvious pitfalls (from the design doc, still load-bearing)

- `CanvasLayer` is not a `CanvasItem`; no `modulate`. Fade goes on the root `ColorRect` instead.
- Double-enter does not re-emit `loading_started`. Consumers would double-count boots otherwise. Second call updates the predicate + labels only.
- The initial `_teleport_to_cell(-2, -9)` on boot is not a "real" teleport — `_prev_camera_position` is still `Vector3.ZERO`, so the > 500m distance check short-circuits. Boot-path gate fires from `_enter_boot_loading_gate` instead.

## Open question

Phase 7 second pass is still open: even with the loading screen hiding the churn, the underlying streaming pipeline still takes ~170s cold-start to reach 55 FPS. This is a UX fix for the symptom; the `inst=20-30 ms/frame` cost of cold-start instantiation needs its own pass (probably widening post-startup `INSTANTIATION_BUDGET_MS`). Tracked in `docs/plans/distant_rendering_2026_04/plan.md`.

## History

- 2026-04-17 loading-state-machine design (Phase 8) — full design doc + OpenMW side-by-side folded into this doc.
