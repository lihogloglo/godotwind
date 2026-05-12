# Onboarding: Character Controller Post-Phase 7 Hardening

Use this as the first message or handoff brief for the next Codex session.

## Start Here

You are working in:

`C:\Users\pc\Documents\GitHub\godotwind`

This is Godotwind, a Godot 4.6 open-world RPG framework using Morrowind as one
data source. Keep framework systems generic. Morrowind-specific formats,
coordinates, prompts, and data interpretation belong in adapter/preset layers.

Before editing runtime code, read the project rules and spec-driven workflow:

1. `AGENTS.md`
2. `spec-driven/README.md`
3. `spec-driven/00-constitution.md`
4. `spec-driven/01-workflow.md`

Then read the audit and the feature package for this work:

5. `docs/audit/character_controller_post_phase7_audit_2026_05_10_codex.md`
6. `spec-driven/features/character-controller-post-phase7-hardening/research.md`
7. `spec-driven/features/character-controller-post-phase7-hardening/spec.md`
8. `spec-driven/features/character-controller-post-phase7-hardening/plan.md`
9. `spec-driven/features/character-controller-post-phase7-hardening/tasks.md`
10. `spec-driven/features/character-controller-post-phase7-hardening/validation.md`
11. `spec-driven/features/character-controller-post-phase7-hardening/review.md`

Useful background from the previous productionization pass:

12. `spec-driven/features/character-controller-productionization/spec.md`
13. `spec-driven/features/character-controller-productionization/plan.md`
14. `spec-driven/features/character-controller-productionization/review.md`

## Why This Exists

Phase 7 fixed the largest character-controller architecture problem:

- `PlayerController` drives movement.
- `CharacterMotor` owns movement components and state.
- `CharacterAnimationSystem` observes `MovementState` instead of owning
  movement.
- `CarryController` now uses the HL2/Source-style velocity-drive pattern rather
  than direct transform writes.

The follow-up audit found remaining contract drift and small correctness gaps.
This new feature package turns that audit into an implementation plan.

## Audit Findings Being Implemented

The audit is the source of truth for the problems. The implementation plan
groups them into phases:

1. Active input context and shared interaction intent.
   - Problem: `PlayerController` docs say it is the only raw `interact` owner,
     but `world_explorer.gd` also reads `interact` for fly-camera mode.
   - Direction: keep fly camera as a formal `FlyCameraContext`, keep player
     mode as `PlayerGameplayContext`, and ensure exactly one active context
     owns `interact` at a time.
   - Also share tap/hold/release timing so fly mode does not duplicate
     `PlayerController` semantics.

2. Teleport, carry cleanup, and prompt suppression.
   - Problem: teleport paths skip `reset_physics_interpolation()`.
   - Problem: `CarryController.release()` can skip restoring a valid rigid body
     if the pickup wrapper is invalid.
   - Problem: carry mode ignores tap interaction but prompt UI can still show
     prompts.

3. Movement config truthfulness.
   - Problem: several exported `CharacterMovementConfig` fields appear to be
     no-ops.
   - Direction: either implement each field or mark it reserved/future-only in
     resources, docs, and tests.

4. Visual test input actions and state/docs cleanup.
   - Problem: `tests/visual/test_character_controller.gd` still uses raw
     keycode hotkeys for scene-specific controls.
   - Problem: `is_jumping` semantics are ambiguous.
   - Problem: `docs/STATUS.md` and several comments describe older interaction
     and carry behavior.

5. Integrated verification and review.
   - Human/user must run Godot-side validation because Codex cannot reliably
     launch the engine in this workspace.

## Files Created For This Plan

The new feature folder is:

`spec-driven/features/character-controller-post-phase7-hardening/`

Files:

- `research.md`: canonical-pattern research for active input contexts, fly
  camera ownership, Godot interpolation reset, and framework boundaries.
- `spec.md`: what the hardening pass must accomplish and what is out of scope.
- `plan.md`: implementation architecture and phase breakdown.
- `tasks.md`: ordered checklist. Start here when implementing.
- `validation.md`: human-run commands, visual checklists, and expected results.
- `review.md`: current review state and where to record implementation results.
- `onboarding.md`: this handoff.

## Where To Begin

This hardening/productionization pass is closed as complete for available
content. There is no Phase 8 in this package. Human/user validation is complete
for the targeted character-controller gdUnit scene, the main
character-controller visual scene, the carry prompt-suppression visual scene,
the teleport interpolation-reset visual scene, the Phase 6 step-solver
fixture/visual surface, and the available-content main-scene smoke pass
including water and controller-scope log review.

Do not recreate the Phase 2 scenes, do not revisit Phase 3 movement config
truthfulness, do not redo Phase 4 visual input actions, do not redo Phase 5/7
integrated verification, and do not invent Phase 8 unless new evidence appears.

The main-scene checks below are blocked future integration gates until the
relevant scene elements or content paths are implemented:

- available interact/carry paths behave;
- prompts hide while carrying and return after release;
- teleport/interior paths do not visibly streak.

Important current gap: `res://tests/visual/test_interior_transition.tscn` is
not a useful Phase 2 teleport visual test right now. The human/user opened it
after Phase 2 and reported only a blank flat area with sky and no actual doors
in the scene. Do not rely on it as teleport visual validation without fixing or
replacing the scene.

Phase 1 completed:

- Added `src/core/interaction/interaction_intent.gd` as a small shared
  press/hold/release splitter. It is a `RefCounted`, not an autoload.
- Routed `PlayerController` player-mode interaction through the helper.
- Routed `world_explorer.gd` fly-camera interaction through the same helper.
- Documented `PlayerGameplayContext` and `FlyCameraContext` as the two active
  owners for raw `interact`; exactly one owns the action at a time.
- Updated:
   - `docs/systems/input_system.md`
   - `docs/systems/interaction_system.md`
   - `spec-driven/features/character-controller-post-phase7-hardening/tasks.md`
   - `spec-driven/features/character-controller-post-phase7-hardening/review.md`
- Patched `tests/visual/test_interaction_phase_I7.gd`: its adapters were
  sibling children of the collider instead of ancestors, so the raycaster
  could not find them and logged "no target". The prop roots now receive the
  Door/Container/Activator scripts directly, matching the production pattern.

Phase 1 validation:

- Human/user ran gdUnit and produced `reports/report_208/results.xml`.
- `test_player_controller_interaction` passed: 18 tests, 0 failures, 0 errors.
- The full run still had 6 unrelated rendering/object-paging failures in
  `test_material_audit`, `test_object_paging_kernel`, and
  `test_static_object_renderer_bwide`.
- Human/user reported visual checks passed for:
  - `tests/visual/test_interaction_phase_I1.tscn`
  - `tests/visual/test_interaction_phase_I2.tscn`
  - `tests/visual/test_interaction.tscn`
  - `tests/visual/test_interaction_phase_I7.tscn` after the fixture patch.

Phase 2 completed:

- Added `reset_physics_interpolation()` to
  `src/core/player/player_controller.gd::teleport_to()` after the discontinuous
  position write.
- Added `reset_physics_interpolation()` to
  `src/core/player/fly_camera.gd::teleport_to()`.
- Routed direct fly-camera jumps in `src/tools/world_explorer.gd` through
  `FlyCamera.teleport_to()` instead of writing `position` directly.
- Added interpolation resets after the direct player-body/camera transform
  writes in `src/core/world/interior_pocket_manager.gd::_do_transition()`.
- Fixed `src/core/interaction/carry_controller.gd::release()` so restoration is
  driven by the captured `RigidBody3D`, not by validity of the pickup wrapper.
- Added generic prompt suppression to
  `src/core/interaction/interaction_raycaster.gd` via
  `set_prompt_suppressed()` / `is_prompt_suppressed()`.
- Wired player-mode prompt suppression from `CarryController.grabbed/released`
  in `PlayerController`.
- Wired fly-mode prompt suppression from the fly carry controller in
  `world_explorer.gd`.
- Removed the redundant manual `reset_physics_interpolation()` call in
  `tests/visual/test_character_controller_steps.gd` because
  `PlayerController.teleport_to()` now owns that reset.
- Updated:
  - `docs/systems/interaction_system.md`
  - `docs/systems/character_controller.md`
  - `spec-driven/features/character-controller-post-phase7-hardening/tasks.md`
  - `spec-driven/features/character-controller-post-phase7-hardening/review.md`

Phase 2 validation:

- Human/user ran the character-controller gdUnit scene and produced
  `reports/report_210/results.xml`.
- `test_character_controller_phase0_baseline` passed: 42 tests, 0 failures,
  0 errors.
- The report includes the new player teleport reset, fly-camera teleport reset,
  and missing-wrapper/valid-body carry release contracts.
- Prompt suppression tests were added to
  `tests/unit/test_player_controller_interaction.gd`. A focused run of that
  separate suite is still useful if future interaction changes touch prompt
  gating, but the visual prompt-suppression path passed.
- Focused Phase 2 visual scenes now exist for carry prompt suppression and
  teleport interpolation reset.
- Carry prompt suppression interactive visual validation is complete.
- Teleport interpolation interactive visual validation is complete: on
  2026-05-12 the human/user ran
  `tests/visual/test_teleport_interpolation_reset.tscn` and confirmed it works.

Phase 3 completed:

- Classified every exported `CharacterMovementConfig` field as `active` or
  `reserved` through
  `src/core/character/controller/character_movement_config.gd::get_exported_field_statuses()`.
- Implemented `turn_to_movement_direction` for ground and swim moves. When it
  is false, movement remains camera-relative but the model/player no longer
  auto-rotates toward the input direction.
- Implemented `step_down_height` as the step solver's down-probe distance after
  a candidate step-up.
- Implemented `min_step_height` as a rejection threshold for tiny upward snaps
  that should remain normal slide/floor-snap behavior.
- Marked `smooth_movement` and `smooth_player_turning_delay` reserved. They
  need a future movement-feel spec covering acceleration, turn delay,
  animation blending, and camera response before they become active.
- Marked `swim_upward_correction_enabled` and `swim_upward_coef` reserved.
  Current swimming is governed by camera-relative pitch, buoyancy, surface
  clamp, and repeated swim-stroke impulse fields instead.
- Removed reserved-field overrides from the Morrowind movement preset so it no
  longer implies those knobs are live behavior.
- Updated:
  - `src/core/character/controller/character_movement_config.gd`
  - `src/core/character/controller/move.gd`
  - `src/core/character/controller/move_container.gd`
  - `src/core/character/controller/moves/{run,walk,sprint,crouch,swim}_move.gd`
  - `src/core/character/controller/movement_presets/morrowind_movement_config.tres`
  - `tests/unit/test_character_controller_phase0_baseline.gd`
  - `docs/systems/character_controller.md`
  - `spec-driven/features/character-controller-post-phase7-hardening/{spec,plan,tasks,review}.md`

Phase 3 validation:

- Human/user ran the character-controller gdUnit scene and produced
  `reports/report_212/results.xml`.
- `test_character_controller_phase0_baseline` passed: 47 tests, 0 failures,
  0 errors.
- The report includes the Phase 3 contracts:
  - `test_movement_config_status_table_covers_exported_fields`
  - `test_turn_to_movement_direction_false_prevents_auto_turning`
  - `test_movement_config_controls_step_down_and_min_step_height`
- Human/user had already run around the main game before Phase 3 started and
  reported that things were working. Treat that as useful runtime smoke
  context, not as the specific teleport visual-scene validation.

Phase 4 completed:

- Added `character_controller_preset_1..5`,
  `character_controller_toggle_debug_hud`, and
  `character_controller_dump_kf_bones` to `project.godot` and
  `InputActions.VISUAL_TEST`.
- Routed `tests/visual/test_character_controller.gd` through those InputMap
  actions instead of raw `KEY_1..KEY_5`, `KEY_F1`, `KEY_F2`, or
  `event.keycode` handling.
- Split jump-state semantics:
  - `MovementState.is_jump_move` = actual launch move.
  - `MovementState.is_airborne` = jump launch or midair/falling.
  - `is_jumping` remains a documented compatibility alias for jump-family
    airborne state, not upward velocity.
- Updated stale ownership comments and reconciled `docs/STATUS.md` with the
  current interaction/carry main-scene wiring and velocity-drive carry path.
- Updated:
  - `project.godot`
  - `src/core/input/input_actions.gd`
  - `tests/visual/test_character_controller.gd`
  - `src/core/character/controller/movement_state.gd`
  - `src/core/character/controller/move_container.gd`
  - `src/core/player/player_controller.gd`
  - `src/tools/world_explorer.gd`
  - `tests/unit/test_character_controller_phase0_baseline.gd`
  - `docs/STATUS.md`
  - `docs/systems/input_system.md`
  - `docs/systems/character_controller.md`
  - `spec-driven/features/character-controller-post-phase7-hardening/{tasks,validation,review}.md`

Phase 4 validation:

- Human/user ran `res://tests/run_character_controller_phase0.tscn` and
  produced `reports/report_213/results.xml`.
- `test_character_controller_phase0_baseline` passed: 50 tests, 0 failures,
  0 errors, 0 skipped.
- The report includes the Phase 4 contracts:
  - `test_phase4_character_controller_visual_actions_are_registered`
  - `test_phase4_character_controller_visual_scene_uses_input_actions_for_debug_controls`
  - `test_phase4_movement_state_splits_jump_move_from_airborne_state`
- Human/user ran `tests/visual/test_character_controller.tscn` and confirmed it
  works.

The contract to preserve:

- In player mode, `PlayerGameplayContext` / `PlayerController` owns raw
  `interact`.
- In fly mode, `FlyCameraContext` in `world_explorer.gd` owns raw `interact`.
- Exactly one context processes `interact` at a time.
- The `interact` binding itself remains the existing `InputMap` action.
- Do not add a new autoload.

Recommended next implementation slice:

1. Begin Phase 6 from the completed hardening baseline.
2. Preserve the Phase 5 result: main-scene fly/player switching, movement,
   sprint, jump, crouch, camera toggle, streaming boundary crossing, and
   controller/input/interaction log review passed for available content.
3. Treat main-scene interact/carry/prompt and teleport/interior smoke checks as
   future validation gates for the feature that implements those missing paths.
4. If new evidence contradicts a completed phase, update the relevant spec or
   plan first instead of patching around stale assumptions.

## Current Visual Scene Status

Carry prompt suppression visual scene:

- `tests/visual/test_carry_prompt_suppression.tscn` exists.
- Human/user ran it and reported the suppression behavior works.
- Expected object behavior: the two cube carryables can be held; prompts hide
  while carrying; tap interaction is gated while carrying; the non-carry
  activator remains a tap-only target.

Teleport interpolation visual scene:

- `tests/visual/test_teleport_interpolation_reset.tscn` has been rebuilt from
  scratch as a simpler editor-authored board with a fixed overview camera,
  colored pads, visible probes, and a small script that only handles the
  existing InputMap actions.
- The scene temporarily sets physics ticks per second to 10 while it runs and
  restores the previous value on exit, making missing interpolation resets more
  visible during manual inspection.
- Human/user ran the rebuilt scene on 2026-05-12 and confirmed it works.
  Phase 2 teleport visual validation is complete.

Main character-controller visual scene:

- `tests/visual/test_character_controller.tscn` uses InputMap actions for
  preset switching, debug HUD toggle, and KF/bone diagnostics.
- Human/user ran it on 2026-05-12 after Phase 4 and confirmed it works.

## Verification Rule

Codex should not claim runtime verification complete after static inspection.

For Godot-side validation, ask the human/user to run:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/run_character_controller_phase0.tscn
```

or the full runner:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/run_tests.tscn
```

For interactive main-scene verification, ask the human/user to run:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn
```

If C# files changed, the human/user must run first:

```powershell
dotnet build Godotwind.sln
```

No shader files are planned for this feature. If a shader file unexpectedly
changes, follow the shader cache/import verification rule in `AGENTS.md`.

## Guardrails

- Keep changes small and phase-scoped.
- Prefer Godot-native behavior and simple helpers over a broad custom input
  framework.
- Do not rewrite fly camera into Source-style noclip in this feature.
- Do not add new autoloads.
- Do not move Morrowind-specific behavior into generic framework files.
- Do not leave exported mod-facing config fields silently inert.
- Update the spec-driven task and review docs as each phase lands.
