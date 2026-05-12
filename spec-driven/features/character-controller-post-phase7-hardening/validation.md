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
  `InputActions.VISUAL_TEST`.
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

Controls:

- `teleport_test_player` (`T` by default): toggle the player probe.
- `teleport_test_fly_camera` (`Y` by default): toggle the fly-camera probe.
- `teleport_test_transition_write` (`U` by default): toggle the direct-write
  transition probes. In the right lane, the purple capsule and pink camera
  marker should move together between the start and destination depths.
- `teleport_test_reset` (`R` by default): reset all probes to the start pads.

Checklist:

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
- [ ] Tap/hold `interact` in fly mode against available interactable content.
- [ ] Switch to player mode.
- [ ] Move, sprint, jump, crouch, and toggle camera.
- [ ] Tap/hold `interact` in player mode against available interactable
      content.
- [ ] Carry an item if content exists.
- [ ] Confirm prompts hide while carrying and return after release.
- [ ] Teleport to a cell or switch modes in a way that calls
      `PlayerController.teleport_to()`.
- [ ] Use an interior/seamless transition if content exists.
- [ ] Cross streaming cell boundaries.
- [ ] Check console/log for controller, input, interaction, or interpolation
      errors.

Expected result:

- The active mode alone handles interaction.
- Teleports do not visibly streak.
- Carry release/drop restores collision behavior.
- No new controller/interaction errors appear.

## Performance Check

Scenario:

- Main scene in fly mode and player mode with normal interaction raycast active.

Budget or target:

- No new unbounded per-frame physics queries.
- Prompt suppression should be a boolean/callable check and should not add
  casts beyond the existing raycaster.

How to measure:

- Static review for new loops/queries.
- Human/user watches frame-time/log warnings during the main scene smoke.

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
