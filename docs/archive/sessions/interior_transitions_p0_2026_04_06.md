# P0 Interior Load Fix — Session Log (2026-04-06)

> Archived session log. The 2026-04-06 P0 interior-load hiccup fix session. Preserved for forensic context. Current shipped behavior is summarized in `docs/systems/interior_transitions.md`.

## P0 Interior Load Fix (2026-04-06)

**Problem:** `_load_pocket()` used `CellManager.load_cell()` synchronously on the main thread when the player got within 10 m of a door. A 150-object interior stalled 35–250 ms. Worst case wedged the frame during approach.

**Fix:** Async pipeline with a per-request `LoadProfile` to eliminate shared-flag mutation races between concurrent exterior and interior loads.

**Key pieces:**
- `CellManager.LoadProfile` — inner class with `fade_in`, `use_static_renderer`, `max_actor_distance`, `interior_priority`. Static factories `exterior_default()` / `interior_pocket()`. Stored on `AsyncCellRequest` and mirrored onto each `InstantiationEntry` at queue time.
- `CellManager.request_cell_async(cell_name, profile)` already existed for interiors — IPM now uses it with `LoadProfile.interior_pocket()` (disables RS batching so interior objects render at the pocket offset, not ESM world position).
- `ReferenceInstantiator._current_load_profile` — transient read by `_effective_max_actor_distance()` / `_effective_use_static_renderer()`. `_set_transient_profile` / `_clear_transient_profile` pair wraps each queue drain call with a debug assert catching leaked transients.
- `InstantiationEntry.interior_priority` — priority-lane flag. `_sort_queue_by_priority` stable-sorts on `(interior_priority desc, distance)` so in-flight interior entries jump to the tail of the queue (where `pop_back()` takes from) during a transition. `CellManager.set_request_priority(request_id, bool)` + `force_queue_resort()` are the public APIs.
- `InteriorPocketManager._begin_pocket_finish_up(slot, collapse)` — 2-phase spread:
  - **F0:** place, visible=false, add_child, single-pass `_finalize_cell_node` walk (render layers on all VisualInstance3D, light_cull_mask on Light3D, physics layers on CollisionObject3D, AABB accumulation on MeshInstance3D — one walk replaces three), build environment, register interior doors.
  - **F1 (next frame, OR same frame if `collapse`):** `_add_lightbox_from_aabb` using F0's cached AABB, LightAnimator, LightShadowBudget, `visible=true`, mark occupied, emit `pocket_loaded`.
  - **Fast path:** if the player is within `INTERACT_RADIUS * FAST_PATH_RADIUS_MULT (=2.0)` of the door at completion, F0+F1 run synchronously on the same frame.
- **Fade-to-black bridge** (`enter_interior`): if the slot is still loading when E is pressed:
  1. Set `_is_transitioning=true`, emit `transition_started`
  2. Boost via `set_request_priority(rid, true)` + `force_queue_resort()`
  3. `await _fade(0, 1, FADE_DURATION)` — 300 ms out
  4. Poll completion with a 2.0 s hard timeout (`INTERIOR_LOAD_TIMEOUT`)
  5. On timeout: log error, emit `interior_load_timeout(cell_name, rid)` signal, `cancel_async_request`, clear slot, fade back in, return false
  6. On success: teleport + fade-in via `_do_transition`
- **`_get_slot_for_cell_any(cell_name)`** — relaxed lookup that matches `is_loading OR finish_up_phase >= 0 OR is_occupied`. Required for the bridge — strict `_get_slot_for_cell` only matches occupied and would drop the bridge into the error path.
- **Stuck-load eviction** — `_evict_oldest_pocket` now falls back to cancelling the oldest in-flight load (via `CellManager.cancel_async_request`) if no fully-occupied slot is available. Prevents both pocket slots wedging in `is_loading` if the player rushes past multiple doors.
- **Test scene pump** — `tests/visual/test_interior_transition.gd._process()` calls `CellManager.process_async_instantiation(4.0, camera_pos, camera_fwd)` every frame. Without this, the async pipeline's main-thread drain never runs in the test scene (main scene gets it from NativeStreamingManager).

**Verification:** `tests/visual/test_interior_transition.tscn` has a `[FRAMETIME]` readout per transition showing peak ms + `path=NORMAL|BRIDGE`. Launch with `-- --auto-test` for headless auto-drive (teleports camera to 2 m from Arrille's Tradehouse, loads, enters, reports peak). Real-renderer results on 2026-04-06:

| Cell | Refs | Path | Peak |
|------|------|------|------|
| Arrille's Tradehouse (first visit) | 207 | NORMAL | 9.77 ms (first-visit shader warmup) |
| Census and Excise Office | 268 | NORMAL | 4.76 ms |
| Census and Excise Office (re-entry) | 268 | NORMAL | 5.56 ms |
| Exterior (exit from interior) | — | NORMAL | 4.35–4.93 ms |
| Arrille's Tradehouse (bridge) | 207 | BRIDGE | 12.16 ms |

All normal-path peaks stay under one 60 Hz frame (16.67 ms). First-visit cells peak ~10 ms due to first-time shader compilation. Bridge path (worst case) ~12 ms, bounded.
