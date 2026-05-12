# Tasks: Character Controller Productionization

Complete phases in order. Each phase should leave the project working without depending on a later phase.

## Phase 0: Spec Package and Baseline Confirmation

- [x] Read the audit and spec-driven docs.
- [x] Create the feature folder.
- [x] Write `research.md`, `spec.md`, `plan.md`, `tasks.md`, `validation.md`, and `review.md`.
- [x] Ask the human/user to run the existing character controller baseline tests.
  - Validate: current known-defect tests still represent the code.

## Phase 1: Stabilize Current Behavior

- [x] Make `MoveContainer` push rigid bodies once after movement.
  - Validate: duplicate-push baseline expects `1`.
- [x] Pass environment/water context into `PlayerInputGatherer` before it computes vertical swim input.
  - Validate: swim pitch test expects non-zero vertical intent when pitched and in water.
- [x] Make moving crouch resolve to crouch behavior.
  - Validate: moving+crouch test expects crouch.
- [x] Keep `walk` intentionally unbound and align visual/help text with that contract.
  - Validate: walk action has zero events and visual text no longer claims Ctrl walks.
- [x] Make failed player-character attachment abort player mode.
  - Validate: test or manual forced failure leaves fly camera active and logs the reason.
- [x] Align character-controller visual test collision layers with production conventions.
  - Validate: props use environment/interactable/player meanings from interaction docs.
- [x] Update `docs/systems/character_controller.md`.
  - Validate: docs match current integration state and Phase 1 behavior.

## Phase 2: CharacterMovementConfig

- [x] Add `CharacterMovementConfig` resource with current movement fields.
  - Validate: resource loads and exported fields appear in the inspector.
- [x] Add default and Morrowind preset resources.
  - Validate: presets can be assigned without code edits.
- [x] Wire moves to read config values instead of hard-coded local tuning.
  - Validate: unit test changes config speeds and moves use the changed values.
- [x] Move turn/backward/swim/step settings into config.
  - Validate: generic move files have no Morrowind-specific comments or constants.
- [x] Document override order.
  - Validate: docs describe default, game preset, character override, runtime modifiers.

## Phase 3: Movement Ownership

- [x] Add `CharacterMotor` or decide explicitly that `PlayerController` directly owns `MoveContainer`.
  - Validate: ownership is documented in `plan.md` if the choice changes.
- [x] Move `MoveContainer` creation/wiring out of `CharacterAnimationSystem`.
  - Validate: movement works with no animation system.
- [x] Add `MovementState`.
  - Validate: tests can read active move, posture, grounded/water flags, velocity, and input state.
- [x] Make animation consume `MovementState`.
  - Validate: visual scene still animates when animation exists.
- [x] Remove or time-box any compatibility bridge.
  - Validate: no permanent bridge remains without a dated removal task.

## Phase 4: Posture, Camera, Raycast, and Timing

Timing slice: completed first because it is deterministic, self-contained, and
does not alter visual posture behavior.

- [x] Update or remove stale public movement fields on `PlayerController`.
  - Validate: public state matches actual movement.
- [x] Make crouch posture drive capsule, camera, ray origin, and animation from one state.
  - Validate: visual crouch test shows camera and prompt origin lower together.
- [x] Replace single-ray stand-up test with capsule/shape clearance.
  - Validate: low ceiling at capsule edge blocks stand-up.
- [x] Decide and implement explicit coyote time and jump buffering.
  - Validate: configured coyote window and jump-buffer behavior have tests.
- [x] Replace wall-clock move timing with physics-delta accumulation.
  - Validate: deterministic unit test advances elapsed move time by supplied delta.
- [x] Pass one delta source through step movement.
  - Validate: no recomputed physics delta inside the step solver.

Phase 4 coyote-time behavior is implemented. Phase 5 carry/interior physics
layer validation should use the posture-aware crouch eye/raycast origin, not
the old standing-only ray origin.

## Phase 5: Gameplay Physics Layers

- [x] Add a small gameplay physics layer helper/resource.
  - Validate: added `GameplayPhysicsLayers` as a preloaded helper, not an autoload.
- [x] Make carry clear the player's current collision bits while held.
  - Validate: fake layer rewrite test passed in `reports/report_206/results.xml`.
- [x] Preserve grab/release mask symmetry.
  - Validate: release exact-mask restore test passed in `reports/report_206/results.xml`.
- [ ] Add carry/interior smoke coverage.
  - Validate: blocked until an integrated playable path has both usable carryable items and interiors/seamless doorways available for manual testing.

## Water Visual Regression: Swim Re-entry

- [x] Patch swim animation lookup and retry behavior after failed transitions.
  - Validate: spaced swim animation name and transition retry tests passed in `reports/report_207/results.xml`.
- [x] Keep the visual water detector active above the water surface while the player jumps.
  - Validate: human visual re-test passed in `tests/visual/test_character_controller.tscn`.
- [x] Clamp swim movement so upward input cannot lift the player capsule above the waterline.
  - Validate: `test_swim_surface_clamp_keeps_player_submerged` passed in `reports/report_207/results.xml`.
- [x] Make held jump in water behave as repeated swim strokes instead of continuous ascent.
  - Validate: swim-jump impulse/repeat tests passed in `reports/report_207/results.xml`; human visual re-test passed.
- [x] Add HUD fields for posture/swimming state.
  - Validate: visual re-test distinguished movement-state and animation-state recovery.

## Phase 6: Step Solver Contract

- [x] Add visual step solver scene.
  - Validate: `tests/visual/test_character_controller_steps.tscn` exposes small step, tall wall, angled wall, ceiling-blocked step, down-step/no-floor, and rigidbody obstacle lanes.
- [x] Complete human visual pass for the step solver scene.
  - Validate: human/user reported all six lanes pass after scene clarity fixes; no solver tuning was needed.
- [ ] Add automated checks where practical.
  - Validate: first lightweight scene-surface contract added; scripted physics fixtures that assert pass/fail movement categories are still pending.
- [ ] Tune step values only through config.
  - Validate: no tuning has been needed yet; no new hard-coded step constants were added to the solver.

## Phase 7: Main Scene Production Smoke

- [x] Provide the interactive main-scene smoke checklist for the human/user to run.
  - Validate: human/user confirmed player-mode toggle, movement, sprint, jump,
    crouch, first/third-person toggle, and streaming boundary crossing.
- [ ] Fix blockers found by the smoke pass.
  - Validate: no blocker reported yet in the tested movement/streaming subset.
    Interaction/carry/drop/throw/interior checklist items are blocked by
    dependent systems/content availability, not failed controller checks.
- [x] Update `docs/STATUS.md` and `docs/systems/character_controller.md`.
  - Validate: docs state that main-scene player movement and streaming smoke
    passed, while full production readiness remains pending dependent systems
    and broader interaction/carry/interior coverage.
- [x] Record partial Phase 7 results in `review.md`.
  - Validate: open risks and follow-ups are explicit.
