# Tasks: Character Controller Post-Phase 7 Hardening

Complete phases in order unless the plan is revised.
Each task should be independently reviewable.

## Phase 0: Spec Package

- [x] Read `spec-driven/README.md`, `00-constitution.md`, and
  `01-workflow.md`.
- [x] Read the post-Phase 7 audit.
- [x] Inspect the existing character-controller productionization feature docs.
- [x] Research canonical active input-context patterns.
- [x] Create this feature folder and draft the spec package.
  - Validate: `research.md`, `spec.md`, `plan.md`, `tasks.md`,
    `validation.md`, and `review.md` exist.

## Phase 1: Active Input Context and Shared Interaction Intent

- [x] Add a small shared interaction-intent helper for press/hold/release
  splitting.
  - Validate: unit tests cover tap, hold begin, release after hold, canceled or
    missing press, and threshold boundary behavior.

- [x] Route `PlayerController` raw `interact` handling through the shared
  helper.
  - Validate: existing player-mode interaction tests still pass; tap/hold
    signal names and timing remain stable.

- [x] Route fly-mode interaction in `world_explorer.gd` through the same
  helper.
  - Validate: no duplicated fly-specific hold-threshold state remains beyond
    the helper instance.

- [x] Document `PlayerGameplayContext` and `FlyCameraContext`.
  - Validate: `docs/systems/input_system.md` and
    `docs/systems/interaction_system.md` state that exactly one active context
    owns `interact` at a time.

- [x] Add an active-context regression check where practical.
  - Validate: test or static assertion confirms player and fly interaction paths
    are mode-gated and cannot both process one `interact` event.

## Phase 2: Teleport, Carry Cleanup, and Prompt Suppression

- [x] Add interpolation reset to `PlayerController.teleport_to()`.
  - Validate: unit/focused test or human visual check confirms the teleport path
    calls/respects `reset_physics_interpolation()`.

- [x] Add interpolation reset to direct interior transition transform writes.
  - Validate: transition smoke checklist includes no visual streak after a
    discontinuous player/camera move.

- [x] Review fly-camera teleport paths and add reset where the camera is moved
  discontinuously.
  - Validate: fly cell teleport/recenter does not visibly streak.

- [x] Fix `CarryController.release()` to restore a valid body even when the
  pickup wrapper is invalid.
  - Validate: public `release()` regression test covers invalid pickup wrapper
    plus valid rigid body.

- [x] Suppress interaction prompts while the active carry controller is
  carrying.
  - Validate: while holding an item, tap interaction is ignored and the prompt
    UI is hidden for the active context; prompt refreshes after release.

## Phase 2 Visual Validation Follow-up

- [x] Add a focused carry prompt-suppression visual scene.
  - Validate: `tests/visual/test_carry_prompt_suppression.tscn` exposes
    carry prompt visibility, suppression while held, tap-while-carrying gating,
    and prompt return after release.

- [x] Add a focused teleport interpolation-reset visual scene.
  - Validate: `tests/visual/test_teleport_interpolation_reset.tscn` exposes
    `PlayerController.teleport_to()`, `FlyCamera.teleport_to()`, and direct
    transition-style body/camera transform writes.

- [x] Add scene-surface contracts for the new visual scenes.
  - Validate: the character-controller baseline suite checks the new scene
    case names and teleport visual-test InputMap actions.

- [ ] Human/user runs the carry prompt-suppression scene interactively.
  - Validate: prompts hide while carrying, tapping while carrying does not
    activate the visible target, and prompts return after release.

- [ ] Human/user runs the teleport interpolation-reset scene interactively.
  - Validate: each probe snaps between pads without a visible interpolation
    streak or smear.

## Phase 3: Movement Config Truthfulness

- [ ] Classify every exported `CharacterMovementConfig` field as active,
  reserved, or deprecated.
  - Validate: docs and comments list the status of every field flagged by the
    audit.

- [ ] Implement `turn_to_movement_direction` or mark it reserved.
  - Validate: if active, a test proves disabling it prevents auto-turning toward
    movement direction.

- [ ] Decide `smooth_movement` and `smooth_player_turning_delay`.
  - Validate: if active, tests prove smoothing behavior; if reserved, presets
    and docs no longer imply active behavior.

- [ ] Implement or reserve `swim_upward_correction_enabled` and
  `swim_upward_coef`.
  - Validate: if active, a swim test proves the configured correction changes
    vertical movement; if reserved, Morrowind preset no longer suggests active
    correction.

- [ ] Implement `step_down_height` and `min_step_height` or mark them reserved.
  - Validate: if active, step-solver tests prove the values affect down-step
    search and minimum step acceptance.

- [ ] Update movement config docs and preset notes.
  - Validate: a future modder can tell which fields affect behavior.

## Phase 4: Visual Test Input Actions and State/Docs Cleanup

- [ ] Add visual-test actions for character-controller preset selection,
  debug-HUD toggle, and KF/bone dump.
  - Validate: `InputActions.verify()` or a focused test protects the new
    action names.

- [ ] Replace raw keycode handling in
  `tests/visual/test_character_controller.gd` for those scene-specific
  controls.
  - Validate: static check finds no `KEY_1..KEY_5`, `KEY_F1`, or `KEY_F2`
    branch in that file.

- [ ] Clarify or split jumping/airborne movement state semantics.
  - Validate: comments/docs/tests no longer imply `is_jumping` means upward
    velocity if the code also sets it while falling.

- [ ] Update stale doc paths and ownership comments.
  - Validate: no comments in the audited files point to
    `docs/INTERACTION_SYSTEM.md`, `docs/INPUT_SYSTEM.md`, or `.claude/CLAUDE.md`
    as current handoff docs.

- [ ] Reconcile `docs/STATUS.md` with current interaction/carry integration.
  - Validate: `STATUS.md` no longer says carry is kinematic direct-transform
    logic or that main-scene wiring is absent.

## Phase 5: Integrated Verification and Review

- [ ] Human/user runs the targeted character-controller/interaction gdUnit
  scene.
  - Validate: newest relevant `reports/report_<number>/results.xml` has zero
    failures/errors for the targeted suite.

- [ ] Human/user opens `tests/visual/test_character_controller.tscn`.
  - Validate: movement, visual-test actions, prompt suppression, and any
    changed config behavior work.

- [ ] Human/user opens `scenes/Godotwind.tscn`.
  - Validate: fly/player switching, streaming movement, available interaction,
    carry, and teleport/interior paths behave according to `validation.md`.

- [ ] Record validation results in `review.md`.
  - Validate: review names completed checks, blocked checks, and any residual
    risk.

## Cleanup

- [ ] Remove temporary debug code that is not part of planned validation.
- [ ] Keep comments limited to non-obvious active-context, interpolation, or
  reserved-config rationale.
- [ ] Confirm no new autoload was added.
- [ ] Confirm no Morrowind-specific assumptions leaked into generic framework
  code.
- [ ] Confirm no shader files changed. If they unexpectedly changed, follow the
  shader cache/import verification rule before visual validation.
