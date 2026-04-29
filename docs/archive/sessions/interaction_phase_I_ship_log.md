# Interaction Phase I.0–I.7 Ship Log (2026-04-07 → 2026-04-09)

Historical session narrative for the carry/pickup stack. Live truth lives in `docs/systems/interaction_system.md`. This file preserves the architecture iteration history and the carry-vibration saga lessons that motivated the "Simplicity Over Over-Engineering" principle in `.claude/CLAUDE.md`.

---

## What shipped (I.0 → I.7)

- **I.0 (2026-04-07)** — `PlayerController` is single owner of `interact` action. Three signals (`interact_tap` / `interact_hold_begin` / `interact_release`) + modal-gate registry. Raycaster purified to pure-state (no input handling).
- **I.1** — `CarryableRegistry` (framework) + `MWCarryableRegistry` (adapter, 12 MW types + LIGH `FLAG_CAN_CARRY` filter) + `CarryableBodyFactory` (in-place StaticBody3D → RigidBody3D swap, frozen KINEMATIC, layers Environment+Interactable, mass clamped). Wraps body in `PickupInteractable` parent so raycaster walk-up finds it.
- **I.2** — `InventoryService` framework base + `MWInventoryService` adapter stub. `PickupInteractable.interact()` routes through `current().store_item()`. On `OK`, despawn via deferred atomic helper that quiesces the RB before queue_free.
- **I.3** — `CarryController` with **direct global_transform writes** (kinematic reparent failed — see Architecture history below). Hold pose captured per-grab in camera-local space; marker rides the camera; body lerps toward marker via manual physics interpolation. Roll-locked to camera yaw + pitch. Mask flip clears `LAYER_PLAYER` bit during hold.
- **I.4** — Throw + weight cap + wall pushback. Camera angular velocity ring buffer (50 ms time-keyed window). Weight cap refusal at grab time (`MAX_GRAB_MASS_KG = 50`). Throw vs drop dispatch in unified `_do_release`, lever-arm cross product impulse + tumble.
- **I.5 (2026-04-08)** — Auto-buoyancy. `BuoyancyBody3D` substituted into `CarryableBodyFactory` when `OceanManager.is_initialized()`. AABB-derived 5-probe layout auto-generated at spawn time, no per-item authoring. Frozen-body tick guard verified mandatory (Godot 4.6 ticks frozen RBs every physics frame — `tests/diagnostic/frozen_rb_tick_check.tscn`).
- **I.6 plumbing (2026-04-08)** — Streaming-safe orphan registry. `NativeStreamingManager` gains `register_persistent_node` / `unregister_persistent_node` / `find_grid_for_node` API plus an `OrphanedCarriedItems` `Node3D` child container. The cell unload path calls `_evacuate_persistent_nodes_from_cell` BEFORE the cell goes into the budgeted teardown queue.
- **I.6 carry-side wiring (2026-04-08)** — `CarryController` gains `set_streaming_manager(node)` setter (type-erased to `Node` so the framework class doesn't import the streaming script). Coupling by inversion; duck-typed via `has_method` so test scenes without a streaming pipeline skip cleanly.
- **I.6 Phase 2 (2026-04-09)** — Re-home on cell load + bound policy + walk-back. `_rehome_persistent_nodes_for_cell` called from sync + async cell-load paths. `PersistentNodeEntry` inner class carries `{original_grid, created_ms, last_known_player_grid}`. Bound policy: `ORPHAN_EXPIRY_MS = 5 min` OR Chebyshev > `ORPHAN_EXPIRY_CELL_DISTANCE = 8` cells. Walk-back ground snap raycasts down 3m / up to 50m and corrects placements off the ground by > 0.25 m.
- **I.7 (2026-04-08)** — Door / container / activator adapters. Three adapters in `src/core/interaction/morrowind/`. `door_interactable.gd` emits `door_activated`. `container_interactable.gd` emits `container_opened` / `container_refused`. `activator_interactable.gd` emits `activator_triggered` for the future BNAM script interpreter. Sig 11 shutdown crash FIXED via `CarryController._exit_tree`.
- **CarryController velocity-drive rewrite (2026-04-09)** — see Architecture history.
- **Main-scene integration (2026-04-09)** — `InteractionRaycaster` + `CarryController` wired into `world_explorer.gd` under the player rig. `cell_manager.set_door_activated_handler` plumbs a `Callable` through `CellManager` → `ReferenceInstantiator` so every spawned `DoorInteractable` connects its `door_activated` signal at creation time.

---

## Architecture history — three iterations to the canonical answer

### Iteration 1 (spec §6.2 original) — kinematic reparent

Parent the held body's wrapper to a Marker3D under the camera, lerp the wrapper's local position, body inherits via scene-tree transform inheritance.

**Did not work.** `RigidBody3D` is physics-server-owned. Its global transform is written by Jolt each tick. Reparenting the wrapper updates the scene-tree parent but NOT the physics-server transform. The wrapper followed the camera; the inner RB and its mesh stayed put.

### Iteration 2 (id=4041 fix) — kinematic direct-transform-write

`freeze = true, freeze_mode = KINEMATIC`, drive the body via `_held_body.global_transform = ...` from `_process` at render rate.

**Worked but vibrated.** Render-rate transform writes on a physics body fight Godot's physics-interpolation system. The engine's renderer reads an interpolated position between prev/current snapshots; our writes overwrite the cache mid-frame; result is a beat-frequency visual wobble at physics-tick-vs-render-rate LCM. Three sessions of patching followed (manual snapshots, project-wide `physics_interpolation = true`, per-node `PHYSICS_INTERPOLATION_MODE_OFF` carve-outs, `get_global_transform_interpolated` swaps, MSAA 4×). Each reduced the vibration but none eliminated it.

### Iteration 3 (2026-04-09) — HL2 physics-gun velocity-drive (canonical)

Stop kinematic-writing. Keep the body DYNAMIC (`freeze = false`). Each `_physics_process` tick:
- `linear_velocity = clamp((target - body_pos) * PULL_STRENGTH, MAX_SPEED)`
- `angular_velocity` via shortest-path quaternion chase toward target basis
- `gravity_scale = 0` while held; `linear_damp` / `angular_damp` bumped for stability

Jolt integrates the velocity over the tick; engine physics interpolation smooths the rendered position between ticks (same mechanism `CharacterBody3D` uses). No carve-outs, no manual composition, no wall pushback hack, no throw ring buffer, no lever-arm cross product. Zero vibration. Released body's chase velocity at the moment of release becomes the throw impulse for free.

**Net deletion ~360 lines:** manual chain composition (`player_xf_interp * camera_pivot.transform * spring_arm.transform * ...`), wall pushback raycast + `_hold_capture_local` immutable cache, camera-basis ring buffer + `CameraSample` class, throw lever-arm cross product, exponential lerp rate constants, throw threshold constants, per-node interpolation carve-outs on the held body, `reset_physics_interpolation()` calls, force-drop pullback timer.

**Why we went through 1 and 2 before getting to 3:** the `@reviewer` agent initially recommended iteration 2 in response to iteration 1's failure. Iteration 2 *almost* worked, which made each subsequent patch look promising. Took three sessions + the user pasting the HL2 snippet in chat for the agent to recognize the canonical pattern. The lesson is locked in `.claude/CLAUDE.md` "Engineering Principle — Simplicity Over Over-Engineering" rules 1-6.

**Updated deferred-mutation rule:** the rule applies to RB STATE MUTATIONS at TRANSITION events (grab / release / despawn) — those go through `call_deferred` atomic helpers. Per-tick `linear_velocity` / `angular_velocity` writes from `_physics_process` are EXEMPT because they're the canonical Godot physics-body control path.

---

## Carry-forward bug fixes (2026-04-08)

### Wall pushback non-restore (I.4)

**Symptom:** "trying to grab an object and moving to a wall: brings the object closer to the camera. Moving back: object doesn't move back to its original place."

**Root cause:** `_apply_wall_pushback` was reading `_hold_target_marker.position` as the "ideal_local" — but the marker had already been mutated by previous frames' pushback. `ideal_local` was the *currently pulled-back* position, not the original captured position.

**Fix:** added `_hold_capture_local: Vector3` field on `CarryController`, set in `_do_grab` from the original camera-local capture, used as the immutable ideal in `_apply_wall_pushback`.

**Obsolete after velocity-drive rewrite:** the wall-pushback raycast was deleted entirely in iteration 3. Jolt collisions handle walls natively now.

### Sig 11 shutdown crash

Throughout I.3 + I.4 development the test scene exit consistently crashed with `signal 11 / no GDScript backtrace` when the user closed the window while holding an item. Root cause: Jolt body cleanup ordering when the scene tree tears down with a frozen kinematic body under direct-transform-write control — `CarryController._process` was still hammering `_held_body.global_transform` while Jolt was releasing the body's RID.

**Fix:** `CarryController._exit_tree` explicitly restores any held body to canonical Jolt state (unfrozen, INHERIT interp, zero velocities, restored mask) and nulls out the marker reference before the scene tree continues unwinding.

---

## I.6 Phase 2 details (2026-04-09)

The streaming manager:

1. **Re-homes orphans on cell reload.** `_rehome_persistent_nodes_for_cell(cell_node, grid)` called from both sync + async load paths, immediately after `_loaded_cells[grid] = cell_node`. Walks `_persistent_nodes`, filters to entries whose `original_grid == grid` AND whose current parent is `_orphan_container` (NOT held items still under the player camera). Reparents back into the reloaded cell with `keep_global_transform = true`.

2. **Bound policy (5 min OR 8 cells).** `PersistentNodeEntry` carries `{original_grid, created_ms, last_known_player_grid}`. Every second (`ORPHAN_PRUNE_INTERVAL_S = 1.0`), `_prune_expired_orphans` walks the registry. Held items (parent is the camera Marker3D) are skipped — their `last_known_player_grid` is updated in the same walk so the Chebyshev check stays current after any future re-home.

3. **Walk-back ground snap.** Raycasts downward from `pos.y + 3m` to `pos.y - 50m` against layer 1 (Environment), excluding the node itself. Snaps to `hit_pos.y + 0.05` IF the current position is more than 0.25 m off the ground or below it.

**Constraint enforcement:** the streaming manager still doesn't import the carry controller. Coupling is still by inversion.

**Self-tests:** `tests/visual/test_interaction_phase_I6.gd` covers 7 cases. All pass headless.

---

## Project-wide physics interpolation enabled (2026-04-08, retained even after velocity-drive)

`project.godot` sets `physics/common/physics_interpolation = true` and `rendering/anti_aliasing/quality/msaa_3d = 2` (4× MSAA). Both prompted by carry vibration debugging. Interpolation flip turned on **per-node carve-outs**:

- `player_controller.gd::_setup_camera` — `camera_pivot.physics_interpolation_mode = PHYSICS_INTERPOLATION_MODE_OFF` so mouse-driven rotation in `_unhandled_input` stays render-rate fresh.
- `fly_camera.gd::_ready` — same carve-out for FlyCamera test scenes.

**Held body no longer needs a carve-out** after velocity-drive (it's a regular dynamic body now, INHERIT is correct). The carry_controller carve-out + `reset_physics_interpolation()` calls were deleted in iteration 3.

**Per-node carve-out rule:** direct-write transforms whose source signal is **stepped at physics tick rate** MUST be left INHERIT so the engine can smooth them. Direct-write nodes whose source is itself render-rate (mouse rotation) MUST be carved OUT so the engine doesn't smooth fresh writes into stale ones. The discriminator is the source signal's update frequency, not whether the node has direct writes. Carve-out + `reset_physics_interpolation()` is correct ONLY for **discontinuous** writes (teleports, respawns, scene loads).
