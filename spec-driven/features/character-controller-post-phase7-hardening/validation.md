# Validation: Character Controller Post-Phase 7 Hardening

## What Must Be Proven

- Player and fly modes have explicit active input ownership.
- Player and fly interaction use the same tap/hold/release semantics.
- Teleport and transition paths reset physics interpolation after
  discontinuous movement.
- Carry release restores physics state based on a valid body, not on wrapper
  validity.
- Prompt UI is hidden while carrying if tap interaction would be ignored.
- Movement config fields are not silent no-ops.
- The main character-controller visual scene uses `InputMap` actions for its
  debug/preset controls.
- Docs and comments describe the current architecture.

## Recorded Results

- Phase 4 targeted gdUnit: human/user ran
  `res://tests/run_character_controller_phase0.tscn` on 2026-05-12 and
  produced `reports/report_213/results.xml`.
  `test_character_controller_phase0_baseline` passed: 50 tests, 0 failures,
  0 errors, 0 skipped.
- Phase 4 visual controller scene: human/user ran
  `tests/visual/test_character_controller.tscn` on 2026-05-12 and confirmed it
  works after the InputMap action migration.
- Phase 2 teleport interpolation visual scene: human/user ran
  `tests/visual/test_teleport_interpolation_reset.tscn` on 2026-05-12 and
  confirmed it works.
- Phase 5 static cleanup: Codex rechecked `reports/report_213/results.xml`
  and the hardening-scope diff. The targeted suite remains green at 50 tests,
  0 failures, 0 errors, 0 skipped. No shader files changed, no new autoload was
  added, and shader cache/import clearing is not required for this package.
- Phase 5 main-scene visual smoke: human/user launched
  `scenes/Godotwind.tscn` and reported fly/player switching, movement, sprint,
  jump, crouch, camera toggle, and streaming boundary crossing all work.
- Phase 5 main-scene deferred checks: available interact/carry paths, prompt
  hide/return while carrying, and teleport/interior streak checks are deferred
  until those main-scene elements or content paths are implemented.
- Phase 5 console/log review: human/user copied `crash_breadcrumb.txt`,
  `crash_report.txt`, `debug_report.txt`, and `godot.log` from the Godot user
  data logs to `C:\Users\pc\Desktop\godot logs\`. Codex read them on
  2026-05-12. `crash_report.txt` says "No errors recorded";
  `debug_report.txt` says "Errors captured: 0" and "No errors"; `godot.log`
  has no `SCRIPT ERROR`, no `SCRIPT WARNING`, and zero `[WARN]` / `[ERROR]`
  entries for `controller`, `input`, or `interaction`.
- Phase 6 start: Codex began the next implementation slice by adding a
  scripted step-solver gdUnit fixture on top of the completed hardening
  baseline. Human/user Godot validation is pending; expected focused
  character-controller suite count is now 51 tests if no other tests are added
  before the run.
- Phase 6 first run: human/user ran the focused suite and produced
  `reports/report_214/results.xml`: 51 tests, 1 failure, 0 errors. The one
  failure was the new step-solver scripted fixture overasserting that a tall
  wall should have zero forward contact travel. The solver did not climb the
  tall wall; Codex tightened the fixture to assert the no-climb contract.
- Phase 6 rerun: human/user reran the focused suite and produced
  `reports/report_215/results.xml`: 51 tests, 0 failures, 0 errors, 0 skipped.
  The report includes `test_phase6_step_solver_scripted_fixture_categories`.
- Phase 7 main-scene smoke follow-up: human/user confirmed fly/player switch,
  movement, sprint, jump, crouch, camera toggle, streaming boundaries, and
  water all work. Interaction/carry/interior checks remain blocked by missing
  dependent main-scene content paths, not failed.
- Phase 7 updated log review: `crash_report.txt` says "No errors recorded";
  `debug_report.txt` says "Errors captured: 0" and "No errors"; `godot.log`
  has zero `SCRIPT ERROR` / `SCRIPT WARNING` entries and zero
  controller/input/interaction/player/animation/water/swim warnings or errors.
  Unrelated streaming/autopsy, missing static collision shape sidecar, and
  shutdown resource-leak warnings remain outside this controller scope.
- Closure: the hardening package is complete for available content. There is no
  Phase 8; interaction/carry/interior checks remain blocked future integration
  gates.

## Shared Godot Limitation

Current Codex limitation: Codex cannot reliably launch the Godot engine from
this desktop workspace. The documented `D:` binary may be absent from Codex's
environment, and the local Godot 4.6.2 Mono console runner has repeatedly
crashed with signal 11 before gdUnit tests can run.

Treat Godot launches, imports/reimports, gdUnit runs, and visual scene checks
as human/user-run validation unless the user explicitly says the environment has
changed and asks Codex to try again.

Human/user command for the project test runner:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/run_tests.tscn
```

If a narrower character-controller runner is still preferred and available:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/run_character_controller_phase0.tscn
```

After a human/user run, inspect the newest report:

- `reports/report_<number>/results.xml`
- `reports/report_<number>/index.html`
- `reports/report_<number>/test_suites/*.html`

If C# files change unexpectedly, the human/user must run first:

```powershell
dotnet build Godotwind.sln
```

No planned phase edits `.glsl`, `.gdshader`, or `.gdshaderinc` files. Shader
cache/import clearing is not required unless implementation scope changes.

## Automated Checks

### Phase 1

Command or procedure:

- Human/user runs gdUnit after the interaction-intent helper and context gates
  are implemented.
  - Focused interaction suite:
    `res://tests/unit/test_player_controller_interaction.gd`

Expected result:

- Tap emits tap on press/release inside threshold.
- Hold emits hold begin after threshold.
- Release after hold emits release, not tap.
- Player-mode and fly-mode interaction paths are mode-gated.
- No duplicate hand-rolled fly tap/hold state remains outside the shared helper
  instance.

### Phase 2

Command or procedure:

- Human/user runs gdUnit after teleport/carry/prompt changes.

Expected result:

- `PlayerController.teleport_to()` reset behavior is covered.
- Direct transition path reset behavior is covered or manually checked.
- `CarryController.release()` restores valid rigid body state even when the
  pickup wrapper is invalid.
- Prompt suppression hides prompt output while carrying and refreshes after
  release.
- Scene-surface contracts expose the two Phase 2 visual scenes and their
  validation cases.

### Phase 3

Command or procedure:

- Human/user runs gdUnit after movement config field classification and
  implementation.

Expected result:

- Every active field changed in this feature has a behavior test.
- Reserved fields are documented and not used by production presets as active
  behavior.
- No movement config field flagged in the audit remains a silent no-op.

### Phase 4

Command or procedure:

- Human/user runs gdUnit or focused input action tests.
- Codex/static inspection checks the visual test file.

Expected result:

- New visual-test action names exist in `project.godot` and
  `InputActions.VISUAL_TEST`:
  `character_controller_preset_1..5`,
  `character_controller_toggle_debug_hud`, and
  `character_controller_dump_kf_bones`.
- `tests/visual/test_character_controller.gd` no longer branches on raw
  `KEY_1..KEY_5`, `KEY_F1`, or `KEY_F2` for its scene-specific controls.
- Jump/airborne semantics are named or documented accurately.
- Stale docs and comments are reconciled.

## Visual Test Scene

Scene path:

- `tests/visual/test_character_controller.tscn`

Purpose:

- Verify the main focused character-controller scene still works after input,
  movement config, prompt, and state-contract changes.

Expected visual result:

- Movement, sprint, jump, crouch, swim, and camera behavior match the existing
  Phase 7 baseline.
- Preset NPC selection works through new visual-test actions.
- HUD toggle and KF/bone dump controls work through visual-test actions.
- While holding a carryable object, prompts hide if tap interaction would be
  ignored.
- After release, prompts reappear when targeting an interactable.

Failure signs:

- Both fly and player contexts respond to one `interact` press.
- Tapping while carrying activates a door/container/pickup.
- Prompt remains visible while carry mode ignores tap.
- Teleports show a one-frame streak or smear.
- Visual-test controls stop working after raw keycodes are removed.

Suggested controls or debug views:

- Existing movement actions through `InputMap`.
- New visual-test actions for preset selection/HUD/debug dump.
- Existing raycast debug toggle if available.

## Focused Phase 2 Visual Scenes

### Carry Prompt Suppression

Scene path:

- `tests/visual/test_carry_prompt_suppression.tscn`

Launch command:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_carry_prompt_suppression.tscn
```

Purpose:

- Verify the real `PlayerController`, `InteractionRaycaster`, and
  `CarryController` prompt-suppression path.
- Verify tap interaction remains gated while carry mode owns the action.

Checklist:

- [ ] Aim at the carryable props and confirm the prompt appears.
- [ ] Hold `interact` on a carryable and confirm the prop is held.
- [ ] While still holding, aim at the second item or activator and confirm the
      prompt line stays hidden.
- [ ] Tap `interact` while still carrying and confirm the log does not show a
      pickup or activator action firing.
- [ ] Release `interact` and confirm prompts return when aiming at a target.

Expected result:

- Carry mode is visually exclusive: prompt output hides while held, tap actions
  are ignored, and prompt output resumes after release.

### Teleport Interpolation Reset

Scene path:

- `tests/visual/test_teleport_interpolation_reset.tscn`

Launch command:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_teleport_interpolation_reset.tscn
```

Purpose:

- Verify discontinuous teleport paths look like instant jumps rather than
  physics-interpolation streaks.
- Exercise `PlayerController.teleport_to()`, `FlyCamera.teleport_to()`, and
  direct transition-style body/camera transform writes.
- The rebuilt scene uses an editor-authored board, fixed overview camera, and
  preauthored visible probes so the board remains visible even if the movement
  script does not behave as expected.
- The scene temporarily sets `Engine.physics_ticks_per_second` to 10 while it
  runs, then restores the previous value on exit. This follows Godot's
  interpolation debugging advice and makes any missing reset easier to see.

Controls:

- `teleport_test_player` (`T` by default): toggle the player probe.
- `teleport_test_fly_camera` (`Y` by default): toggle the fly-camera probe.
- `teleport_test_transition_write` (`U` by default): toggle the direct-write
  transition probes. In the right lane, the purple capsule and pink camera
  marker should move together between the start and destination depths.
- `teleport_test_reset` (`R` by default): reset all probes to the start pads.

Checklist:

- [ ] Confirm the board is visible immediately: three lanes, colored start and
      destination pads, and HUD text.
- [ ] Trigger the player probe several times and watch for an instant jump
      between its pads.
- [ ] Trigger the fly-camera probe several times and watch for an instant jump
      between its pads.
- [ ] Trigger the transition write several times and confirm the purple body
      marker and pink camera marker snap together between the right-lane start
      and destination pads.
- [ ] Reset all probes and confirm the scene remains responsive.

Expected result:

- No probe visually smears across the gap after a discontinuous move.
- The event log records the helper or direct-write path used for each action.

## Main Scene Manual Check

Scene path:

- `scenes/Godotwind.tscn`

Launch command:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn
```

Checklist:

- [ ] Start in fly camera mode.
- [ ] Switch to player mode.
- [ ] Move, sprint, jump, crouch, and toggle camera.
- [ ] Cross streaming cell boundaries.
- [ ] Check console/log for controller, input, interaction, or interpolation
      errors.

Expected result:

- Fly/player mode switching, movement, camera toggle, and streaming remain
  stable.
- No new controller/interaction errors appear.

Deferred until the required main-scene elements are implemented:

- Available interact/carry paths behave.
- Prompts hide while carrying and return after release.
- Teleport/interior paths do not visibly streak.

## Performance Check

Scenario:

- Main scene in fly mode and player mode with normal interaction raycast active.

Budget or target:

- No new unbounded per-frame physics queries.
- Prompt suppression should be a boolean/callable check and should not add
  casts beyond the existing raycaster.

How to measure:

- Static review for new loops/queries.
- Human/user watches frame-time during the main scene smoke.

## Modding Check

Custom content scenario:

- Assign or construct a `CharacterMovementConfig` with unusual values for every
  active field changed in Phase 3.

Expected result:

- Active fields visibly or testably affect movement behavior.
- Reserved fields are clearly documented as not active yet.

Failure signs:

- A field appears in a production preset but changing it has no behavior change
  and no reserved/future-only warning.
- Generic movement code hard-codes Morrowind-specific assumptions.

## Manual Review Checklist

- [ ] Acceptance criteria are satisfied.
- [ ] Generic framework code has no game-specific assumptions.
- [ ] Moddable movement config behavior is honest.
- [ ] Visual output matches the spec.
- [ ] Performance-sensitive paths have been checked.
- [ ] Known limitations are documented.
- [ ] Runtime verification status is recorded in `review.md`.
