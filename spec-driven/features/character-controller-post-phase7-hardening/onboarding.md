# Onboarding: Character Controller Post-Phase 7 Hardening

Use this as the first message or handoff brief for the next Codex session.

## Start Here

You are working in:

`C:\Users\pc\Desktop\godotwind-master`

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

Phase 1 and Phase 2 are implemented. Before continuing to Phase 3, create a
proper Phase 2 visual validation surface in:

`spec-driven/features/character-controller-post-phase7-hardening/tasks.md`

Do not start by patching every remaining audit finding at once. The next task
group is a validation-scene follow-up for Phase 2:

1. Create a focused carry visual test scene with carryable items, prompt
   suppression, drop/release behavior, and tap-while-carrying gating.
2. Create a focused teleport visual test scene with an obvious before/after
   teleport path that exercises `PlayerController.teleport_to()`,
   `FlyCamera.teleport_to()`, and direct transition-style transform writes.

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
  `tests/unit/test_player_controller_interaction.gd`, but they still need a
  human/user run of that focused suite or the full runner.
- Interactive visual validation is still pending. Existing scenes are not
  enough: the current interior transition test did not expose usable doors for
  the human/user, and the carry scenes predate the exact Phase 2 prompt
  suppression contract. Build the two focused scenes described above.

The contract to preserve:

- In player mode, `PlayerGameplayContext` / `PlayerController` owns raw
  `interact`.
- In fly mode, `FlyCameraContext` in `world_explorer.gd` owns raw `interact`.
- Exactly one context processes `interact` at a time.
- The `interact` binding itself remains the existing `InputMap` action.
- Do not add a new autoload.

Recommended next implementation slice:

1. Add `tests/visual/test_carry_prompt_suppression.tscn` and matching `.gd`
   script. It should spawn simple carryable items and at least one non-carry
   interactable, then make it obvious that prompts hide while carrying and
   return after release.
2. Add `tests/visual/test_teleport_interpolation_reset.tscn` and matching `.gd`
   script. It should provide manual InputMap-driven teleport controls for a
   player body, fly camera, and transition-style camera/body transform write.
3. Update `validation.md`, `tasks.md`, and `review.md` with those scene paths
   and the human visual checklist.
4. Human/user runs `test_player_controller_interaction` or the full runner to
   validate the prompt-suppression unit tests.
5. Human/user runs the two new visual scenes and reports results.
6. Only then continue to Phase 3 movement config truthfulness.

## Current Visual Scene Status

Carry prompt suppression visual scene:

- `tests/visual/test_carry_prompt_suppression.tscn` exists.
- Human/user ran it and reported the suppression behavior works.
- Expected object behavior: the two cube carryables can be held; prompts hide
  while carrying; tap interaction is gated while carrying; the non-carry
  activator remains a tap-only target.

Teleport interpolation visual scene:

- `tests/visual/test_teleport_interpolation_reset.tscn` exists, but it is NOT
  a trustworthy validation surface.
- Human/user first saw the pads, and key presses made objects appear on pads,
  but the probes did not clearly toggle positions as intended.
- Follow-up fixture edits made the scene blank for the human/user, even after a
  full Godot restart.
- Do not keep patching this scene as-is. Recreate the teleport visual test from
  scratch with a simpler, editor-authored or minimally scripted scene, then
  have the human/user verify it interactively before using it as Phase 2 visual
  evidence.
- Until recreated and verified, Phase 2 teleport visual validation remains
  pending even though the gdUnit scene-surface contracts passed.

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
