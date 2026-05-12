# Review: Character Controller Productionization

Date: 2026-05-10
Status: Complete for available content; no Phase 8. Interaction/carry/interior
main-scene validation is blocked by dependent integration/content paths.

## Plan Review Notes

- The plan follows the audit's core diagnosis: fix ownership and data flow, not isolated symptoms only.
- The first runtime phase is intentionally small and should be safe to review independently.
- Morrowind behavior is planned as a preset/adapter, preserving the framework boundary.
- The final available-content production claim was completed through human-run
  main-scene smoke and log review. Interaction/carry/interior remain blocked
  future integration gates.

## Implementation Review

The character-controller productionization pass is closed as complete for
available content. Human-run gdUnit, focused visual scenes, step-solver
validation, main-scene movement/streaming/water smoke, and controller-scope log
review passed. Manual interaction/carry/interior validation is intentionally
classified as blocked until an integrated playable path has both usable
carryable items and interiors/seamless doorways available.

## Codex Runtime Limitation

Codex cannot reliably launch the Godot engine from this desktop workspace. The
documented `D:` binary is not available to Codex here, and the discovered local
Godot 4.6.2 Mono console runner crashes with signal 11 before gdUnit starts.
Future Godot launches, gdUnit runs, imports/reimports, and visual scene checks
must be performed by the human/user unless the user explicitly says the
environment has changed and asks Codex to try again.

## Validation Results

Phase 0:

- Added and ran `tests/run_character_controller_phase0.tscn` from the Godot editor.
- The runner started `res://tests/unit/test_character_controller_phase0_baseline.gd`.
- The pasted editor output showed the expected `MoveContainer` setup logs and no assertion failure or stack trace.
- The output did not include a final gdUnit pass/fail summary, so the result is recorded as an in-editor baseline smoke pass rather than a formal CI-style report.

Phase 1:

- Implemented the focused stabilization fixes in the existing architecture.
- Updated the baseline test expectations from known defects to contracts.
- Updated `docs/systems/character_controller.md` with current partial main-scene wiring and Phase 1 behavior.
- Editor-run gdUnit report `reports/report_199/results.xml` passed: 8 tests, 0 failures, 0 errors.
- The passing test names confirm the new Phase 1 contracts ran: one push pass, moving crouch resolves to crouch, walk remains intentionally unbound, and swim pitch uses water context during input gathering.
- Command-line Godot verification is still blocked locally by the same Godot 4.6.2 Mono signal-11 crash seen in Phase 0.
- Visual/main-scene checks were completed in later phases; see the Phase 7
  result below.

Phase 2:

- Added `CharacterMovementConfig` and default/Morrowind preset resources.
- Wired `PlayerController`, `CharacterAnimationSystem`, `MoveContainer`, and concrete moves to use the shared config.
- Assigned the Morrowind preset in the main world explorer player path and the character-controller visual test path.
- Added unit contracts for config-driven run speed, jump velocity, backward run multiplier, sprint capability, and step height.
- Updated `docs/systems/character_controller.md` with config source-of-truth and override order.
- Editor-run gdUnit report `reports/report_200/results.xml` passed: 14 tests, 0 failures, 0 errors.
- Visual check is limited because water bodies are not implemented in the current main scene; swim config is covered by unit-level logic only for now.

Phase 3:

- Added `CharacterMotor` as the owner of `PlayerInputGatherer`, `MoveContainer`,
  default move construction, and `MovementState`.
- `PlayerController` now processes movement through `CharacterMotor` and forwards
  the resulting `MovementState` to animation when an animation system exists.
- Removed `MoveContainer` creation and `process_moves()` ownership from
  `CharacterAnimationSystem`; animation now observes `MovementState`.
- Added unit contracts for motor movement without animation, player-controller
  motor attachment without animation, and animation consumption of
  `MovementState`.
- Command-line Godot verification with
  `C:/Users/pc/Desktop/Godot_v4.6.2-stable_mono_win64/Godot_v4.6.2-stable_mono_win64_console.exe --path C:/Users/pc/Desktop/godotwind-master res://tests/run_tests.tscn`
  crashed with signal 11 before tests could run.
- Do not treat Codex-side launch attempts as valid verification. Human/user
  editor/runtime verification is required for Phase 3.
- Human/user ran `test_character_controller_phase0_baseline.gd`; gdUnit wrote
  `reports/report_201/results.xml`.
- `reports/report_201/results.xml` passed with 20 tests, 0 failures, 0 errors.
  The matching HTML report is `reports/report_201/index.html`, with per-suite
  details in
  `reports/report_201/test_suites/tests.unit.test_character_controller_phase0_baseline.html`.

Phase 4 timing slice:

- Replaced `Move` wall-clock progress with physics-delta accumulation from
  `MoveContainer.process(input, delta)`.
- Passed the same supplied delta into `MoveContainer._move_with_step_up(delta)`
  and `_push_rigid_bodies(delta)` instead of recomputing the physics delta
  inside those helpers.
- Added unit contracts that elapsed move time advances by supplied delta and
  the movement/push path receives the same delta passed to `process()`.
- Codex static check found no remaining `Time.get_unix_time_from_system()` or
  `get_physics_process_delta_time()` usage in the character controller move
  stack.
- Human/user reran gdUnit and produced `reports/report_202/results.xml`.
  The character-controller suite passed: 21 tests, 0 failures, 0 errors,
  including `test_move_elapsed_time_uses_supplied_physics_delta`.
- The full report had 217 tests with 6 failures in unrelated rendering/object
  paging suites (`test_material_audit`, `test_object_paging_kernel`, and
  `test_static_object_renderer_bwide`). Those failures are outside this
  character-controller timing slice.
- Human/user tested the character controller in game after the timing slice and
  reported that it is working as expected.
- Timing-slice interactive validation is recorded complete.

Phase 4 posture slice:

- `PlayerController` now copies crouch/swim/posture fields from
  `MovementState` and resets the public movement snapshot on freeze/disable.
- `PlayerController.camera_pivot` now uses
  `CharacterMovementConfig.standing_eye_height` or `crouch_eye_height` based on
  `MovementState.posture`.
- The main-scene interaction ray origin follows this automatically because
  `world_explorer.gd` already assigns
  `InteractionRaycaster.ray_origin_node = player_controller.camera_pivot`.
- `CrouchMove` still owns capsule height for this incremental slice, but
  `_can_stand_up()` now checks a standing capsule overlap with
  `PhysicsDirectSpaceState3D.intersect_shape()` instead of a single center ray.
- Added unit contracts for camera-pivot posture height, ray-origin linkage, and
  crouch posture publication.
- Human/user ran the character-controller gdUnit scene and produced
  `reports/report_204/results.xml`: 24 tests, 0 failures, 0 errors. The report
  includes the posture contracts for camera-pivot height, ray-origin linkage,
  crouch posture publication, and the earlier timing contracts.
- Human/user visually tuned crouch first-person eye height to `1.58m` and
  reported that value feels correct.
- Human/user completed the remaining posture visual checks: interaction
  prompt/raycast origin follows crouch height, standing restores it, and low
  ceilings near the capsule edge block standing.

Phase 4 jump-grace slice:

- Research concluded that Godotwind should use explicit configurable coyote
  time plus optional jump buffering instead of letting the ground-to-midair
  lockout define movement feel accidentally.
- `CharacterMovementConfig` now defaults to `coyote_time = 0.10` and
  `jump_buffer_time = 0.12`.
- The Morrowind-informed preset keeps the same generic fields but tunes them
  lower (`0.06` / `0.08`) for a heavier RPG feel.
- `MoveContainer` owns deterministic physics-delta timers for last grounded
  time and buffered jump input, consumes the jump when `JumpMove` is selected,
  and removes invalid jump actions once coyote time expires.
- Ground moves keep `ground_to_midair_lockout` as a bounce guard, but an
  eligible coyote/buffered jump now wins before transitioning to midair.
- Added unit contracts for explicit defaults, coyote acceptance, expired coyote
  rejection, buffered landing jump, and the `jump_buffer_time = 0` immediate
  jump case.
- Human/user ran the character-controller gdUnit scene and produced
  `reports/report_205/results.xml`: 29 tests, 0 failures, 0 errors. The report
  includes all new jump-grace contracts:
  `test_movement_config_has_explicit_jump_grace_defaults`,
  `test_coyote_time_keeps_jump_available_after_ground_loss`,
  `test_expired_coyote_time_rejects_late_jump`,
  `test_jump_buffer_fires_on_landing_frame`, and
  `test_zero_jump_buffer_keeps_immediate_ground_jump`.
- Human/user also tested the jump-grace behavior in game and reported it works.

Phase 5 gameplay physics layer slice:

- Added `src/core/physics/gameplay_physics_layers.gd` as a small preloaded
  framework helper for named gameplay physics layer roles. It is intentionally
  not an autoload.
- `CarryableBodyFactory`, `PlayerController`, and `InteriorPocketManager` now
  read shared framework layer constants instead of each owning a separate
  partial copy of the layer contract.
- `CarryController` now excludes the player's current `collision_layer` from
  the held body's saved collision mask. The held mask refreshes while carrying,
  so interior/seamless transition layer rewrites are picked up, and release
  still restores the exact saved mask.
- Added unit contracts for no-autoload helper usage, fake player layer rewrites,
  and exact release mask restoration.
- Updated the interaction and character-controller docs with the new carry mask
  contract.
- Human/user ran the character-controller gdUnit scene and produced
  `reports/report_206/results.xml`: 32 tests, 0 failures, 0 errors. The report
  includes all three Phase 5 contracts:
  `test_gameplay_physics_layers_is_not_an_autoload`,
  `test_carry_held_mask_excludes_current_player_collision_bits`, and
  `test_carry_release_restores_exact_previous_collision_mask`.

Water visual regression after Phase 5:

- Human/user reported that in `tests/visual/test_character_controller.tscn`,
  jumping into the water while holding forward could leave the character moving
  upright instead of returning to swim animation after falling back into water.
- Patched animation lookup so Morrowind-style spaced names such as
  `Swim Walk Forward` resolve to compact framework states such as
  `SwimForward`.
- `AnimationManager.transition_to()` now reports whether the transition
  succeeded, and `CharacterAnimationSystem` only records a movement animation
  as handled after a successful transition. This prevents a failed swim
  transition from being cached forever.
- The visual test water detector now uses the shared player layer helper and
  extends above the water surface so the controller keeps water-surface context
  while the player briefly jumps above the surface.
- Added `swim_min_feet_submersion` and a swim surface clamp so upward
  camera/forward swim input cannot lift the player capsule above the waterline
  and cause water-state flicker.
- Changed in-water jump from continuous vertical input to a repeated swim
  stroke controlled by `swim_jump_velocity` and `swim_jump_repeat_time`.
- Added unit contracts for swim re-entry movement state, spaced swim animation
  name resolution, surface clamping, swim-jump impulse/repeat behavior, and
  retrying after failed animation transition.
- Human/user ran the character-controller gdUnit scene and produced
  `reports/report_207/results.xml`: 38 tests, 0 failures, 0 errors. The report
  includes the swim re-entry, swim surface clamp, swim-jump impulse/repeat, and
  animation retry/name-resolution contracts.
- Human/user completed the final visual re-test in
  `tests/visual/test_character_controller.tscn` before the Phase 6 pass and
  confirmed held jump while swimming bobs upward, falls back down, and repeats
  instead of pinning the character near the top.

Phase 6 step solver validation surface:

- Added `tests/visual/test_character_controller_steps.tscn` and
  `tests/visual/test_character_controller_steps.gd` as a standalone step-solver
  measuring rig.
- The scene avoids Morrowind data and animations, uses a capsule-only
  `PlayerController`, shared gameplay physics layer constants, and project
  `InputMap` actions.
- Added the `step_solver_respawn` visual-test InputMap action (`R` by default)
  and automatic respawn below the lane panels so falling into the no-floor test
  does not trap the tester forever.
- Human/user reported the character-controller gdUnit tests all pass after the
  Phase 6 scene-surface contract. Expected count is 39 tests, 0 failures, 0
  errors. Report path was not provided in chat.
- Human/user interactively tested all six step lanes and reported they pass:
  small step climbs, tall wall blocks, angled wall slides/blocks without
  stair-pop, ceiling-blocked step does not pop through, edge lip does not
  create an artificial safe stair landing across empty space while normal
  falling remains allowed, and the rigidbody obstacle is pushable without being
  treated like static terrain.
- No `_move_with_step_up()` tuning or architecture changes were made. The
  Phase 6 pass found and fixed validation-scene clarity issues only: lane floor
  gaps, unclear no-floor wording, invisible/falling rigidbody obstacle, and
  missing respawn.

Phase 7 main-scene production smoke, partial:

- Human/user launched `scenes/Godotwind.tscn` interactively and reported the
  core player path works for:
  - toggling from fly camera to player mode;
  - movement, sprint, jump, and crouch;
  - first/third-person camera toggle;
  - crossing streaming cell boundaries;
  - entering/exiting water and swimming.
- Interaction, carry, drop, throw, and carry-through-interior checklist items
  could not currently be tested because dependent systems/content paths are not
  complete enough to exercise them in the main scene. These are recorded as
  blocked, not failed.
- Human/user provided the Godot output from the smoke run. No
  character-controller, player-mode, movement, animation, or interaction wiring
  errors appeared during the tested path. The log shows
  `Player character attached: fargoth`, `MoveContainer: Accepted 9 moves`, and
  `Switched to PLAYER mode`.
- Log warnings/errors seen in the supplied output are outside the
  character-controller productionization slice: a Godot deprecation warning for
  `instance_reset_physics_interpolation()`, a Terrain3D editor-texture warning,
  streaming/profiler frame-overrun warnings, repeated `CellStaticCollision`
  missing-shape sidecar warnings, and shutdown-time RID/resource leak reports.
  These should be tracked under streaming/rendering/resource-cleanup work, not
  as Phase 7 controller smoke failures.
- Follow-up Phase 7 log review after the water-inclusive smoke passed for the
  controller scope. `crash_report.txt` says "No errors recorded";
  `debug_report.txt` says "Errors captured: 0" and "No errors"; `godot.log`
  has zero `SCRIPT ERROR` / `SCRIPT WARNING` entries and zero warnings or
  errors matching controller, input, interaction, player, animation, water, or
  swim. Positive path lines include `Interaction framework wired`, `IKController.setup`,
  `MoveContainer: Accepted 9 moves`, `Player character attached: fargoth`, and
  `Switched to PLAYER mode`.

## Open Risks

- The Morrowind preset may need a later actor-stat adapter; Phase 2 should not overbuild that before stats/fatigue/encumbrance are ready.
- Main-scene verification depends on the user's local content and visual checks.
- Phase 7 main-scene movement/camera/streaming/water smoke passed for the
  tested subset. Interaction/carry/drop/throw/interior validation remains
  blocked by dependent systems/content availability.
- Phase 7 log/error review for the supplied smoke output found no controller,
  input, interaction, player, animation, water, or swim warnings/errors.
  Unrelated streaming/collision/shutdown warnings remain outside this feature's
  acceptance scope.
- Focused visual verification for Phase 3 still needs a human/user editor-run
  pass because Codex cannot reliably launch Godot here.
- Phase 4 jump-grace automated and in-game validation are complete.
- Phase 5 automated gdUnit validation is complete. Manual carry/interior
  validation is blocked by content/integration availability.
- Water re-entry/swim-jump automated and visual validation are complete.
- Phase 6 visual step-solver validation is complete. Scripted physics fixtures
  for step categories passed in `reports/report_215/results.xml`.

## Next Session Handoff

Read first, in order:

1. `AGENTS.md`
2. `docs/audit/character_controller_code_audit_2026_05_09_codex.md`
3. `spec-driven/README.md`
4. `spec-driven/00-constitution.md`
5. `spec-driven/01-workflow.md`
6. `spec-driven/features/character-controller-productionization/research.md`
7. `spec-driven/features/character-controller-productionization/spec.md`
8. `spec-driven/features/character-controller-productionization/plan.md`
9. `spec-driven/features/character-controller-productionization/tasks.md`
10. `spec-driven/features/character-controller-productionization/validation.md`
11. `spec-driven/features/character-controller-productionization/review.md`
12. `docs/systems/character_controller.md`
13. `docs/systems/interaction_system.md`

Current status:

- Phase 0 complete.
- Phase 1 complete.
- Phase 2 complete.
- Phase 3 complete.
- Phase 4 complete.
- Phase 5 core implementation complete.
- Water visual regression follow-up complete.
- Phase 6 visual step-solver contract complete.
- Phase 7 main-scene production smoke complete for available content.
- Productionization pass closed as complete for available content. There is no
  Phase 8 in this package.

Latest verified reports/results:

- `reports/report_206/results.xml`: Phase 5 gameplay physics layer contracts
  passed, 32 tests, 0 failures, 0 errors.
- `reports/report_207/results.xml`: water re-entry/swim-jump automated
  contracts passed, 38 tests, 0 failures, 0 errors.
- After the Phase 6 scene-surface contract and respawn action, human/user
  reported the character-controller gdUnit tests all pass. Expected result:
  39 tests, 0 failures, 0 errors. Report path was not provided in chat.

Blocked future validation gates:

- Manual carry/interior smoke is blocked, not failed.
- Reason: there is still no confirmed integrated playable path with both usable
  carryable items and interiors/seamless doorways available for manual testing.
- When content/integration exists, test: carry an item through an
  interior/seamless doorway, confirm it does not push the player, release/drop
  it, and confirm normal collision behavior restores.
- Also validate interaction/carry/drop/throw, prompt suppression in main-scene
  content, and real teleport/interior interpolation reset paths.

Water follow-up status:

- Human/user visually retested `tests/visual/test_character_controller.tscn`.
- Swim re-entry animation now returns to swimming and stays in water.
- Holding jump while swimming now behaves as repeated swim strokes: bob upward,
  fall back down, repeat. It no longer pins the character near the top.

Phase 6 completed:

- Added `tests/visual/test_character_controller_steps.tscn` and
  `tests/visual/test_character_controller_steps.gd`.
- Added `step_solver_respawn` in `project.godot` and `InputActions.VISUAL_TEST`;
  `R` manually respawns the player in the step scene.
- Automatic respawn triggers when the step-scene player falls below the lane
  panels.
- Human/user visually tested all six lanes and reported they pass.
- Scene issues fixed during validation: angled-wall floor gap, confusing
  edge-lip/no-floor wording, missing/falling rigidbody obstacle, and missing
  respawn.
- No solver code was tuned or rewritten. `_move_with_step_up()` remains on the
  current canonical up/forward/down probe architecture.
- Phase 6 automated follow-up has started:
  `test_phase6_step_solver_scripted_fixture_categories` adds tiny scripted
  physics fixtures for broad category checks: small step climbs, tall wall
  does not climb, ceiling-blocked step does not climb, no-floor case gains no
  height, and rigidbody obstacle does not get treated as a static step.
  Human/user reran the focused gdUnit scene and produced
  `reports/report_215/results.xml`: 51 tests, 0 failures, 0 errors, 0 skipped.

Recommended next-session instruction:

Do not create Phase 8 in this package. If the blocked interaction/carry/interior
items become actionable, start a new spec package for that integration slice and
use this review as the controller baseline. Keep step-solver tuning through
`CharacterMovementConfig` only and avoid rewriting `_move_with_step_up()` unless
new tests show the canonical up/forward/down probe architecture is wrong.

Codex cannot reliably launch Godot here; human/user must run future gdUnit and
visual checks. No C# or shader changes were made in this pass, so no
`dotnet build` or shader cache clearing is needed.
