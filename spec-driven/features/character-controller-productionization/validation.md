# Validation: Character Controller Productionization

## What Must Be Proven

- Each phase leaves the controller in a working state.
- Movement does not depend on animation after the ownership phase.
- Config changes affect real movement.
- Generic controller code remains game-agnostic.
- User-visible behavior is verified in focused scenes and then in the main scene.

## Shared Automated Command

Current Codex limitation: Codex cannot reliably launch the Godot engine from
this desktop workspace. The documented `D:` binary may be absent from Codex's
environment, and the local Godot 4.6.2 Mono console runner has repeatedly
crashed with signal 11 before gdUnit tests can run. Treat Godot launches,
imports/reimports, gdUnit runs, and visual scene checks as human/user-run
validation unless the user explicitly says the environment has changed.

Human/user command for the project test runner:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/run_tests.tscn
```

After a human/user run, check the newest gdUnit report directory:

- `reports/report_<number>/results.xml` — detailed XML summary with total tests,
  failures, errors, skipped tests, and test case names.
- `reports/report_<number>/index.html` — human-readable report.
- `reports/report_<number>/test_suites/*.html` — per-suite report pages. For the
  character-controller harness, the file is named like
  `reports/report_<number>/test_suites/tests.unit.test_character_controller_phase0_baseline.html`.

If C# files are changed in a later phase, the human/user should run first:

```powershell
dotnet build Godotwind.sln
```

## Phase 0 Validation

Automated:

- Human/user runs existing gdUnit tests.
- Expected: current baseline tests pass, including known-defect expectations.

Manual:

- None.

## Phase 1 Validation

Automated:

- Human/user runs gdUnit after `test_character_controller_phase0_baseline.gd`
  is updated so fixed defects become new contracts:
  - push count equals `1`;
  - moving crouch resolves to crouch;
  - swim pitch uses pre-injected water context;
  - walk remains present and unbound unless the input spec changes.

Visual:

- Scene: `tests/visual/test_character_controller.tscn`
- Expected:
  - WASD/default movement runs;
  - sprint works;
  - crouch while moving stays crouched;
  - jump still works;
  - water swim follows camera pitch;
  - help text matches actual actions;
  - dynamic props follow production collision-layer conventions.

Manual main-scene spot:

- If a forced character-attachment failure is available, toggle player mode and confirm it safely stays or returns to fly mode.

## Phase 2 Validation

Automated:

- Human/user runs the gdUnit test that assigns a custom config with unusual
  values and verifies moves use them.
- Codex can do the static check; human/user runs Godot-side test execution.
  Static check confirms generic move scripts no longer contain
  Morrowind-specific constants/comments for backward movement and turn policy.

Visual:

- In `tests/visual/test_character_controller.tscn`, assign a slow config.
- Expected: walk/run/sprint/crouch/swim speeds visibly change according to the resource.

Modding check:

- Create or assign a second resource preset without code edits.
- Expected: the scene picks up the alternate movement profile.

## Phase 3 Validation

Automated:

- Human/user runs the gdUnit suite and confirms a no-animation fixture can
  process movement.
- Human/user runs the gdUnit suite and confirms an animation fixture receives
  `MovementState` and changes animation state.
- The shared controller unit suite includes the Phase 3 ownership contracts in
  `tests/unit/test_character_controller_phase0_baseline.gd`.
- Confirm the newest `reports/report_<number>/results.xml` includes the Phase 3
  test cases and reports zero failures/errors.

Visual:

- Visible character still animates in the controller scene.
- A capsule-only/no-animation variant still moves and collides.

Failure signs:

- Player freezes when animation is missing.
- Animation creates or owns movement state.

## Phase 4 Validation

Latest jump-grace automated result:

- Human/user ran the character-controller gdUnit scene and produced
  `reports/report_205/results.xml`.
- Result: 29 tests, 0 failures, 0 errors.
- The report includes the explicit coyote-time and jump-buffer contracts listed
  below.
- Human/user also tested the jump-grace behavior in game and reported it works.

Automated:

- Human/user runs gdUnit checks confirming move elapsed time advances by
  supplied physics delta.
- For the timing slice, confirm the newest report includes
  `test_move_elapsed_time_uses_supplied_physics_delta` and
  `test_process_runs_one_push_pass_after_movement`.
- For the posture slice, confirm the newest character-controller report
  includes `test_player_controller_camera_pivot_follows_movement_posture`,
  `test_interaction_ray_origin_follows_camera_pivot_posture`, and
  `test_move_container_publishes_crouch_posture`.
- Human/user runs gdUnit checks confirming coyote time and jump buffering obey
  config:
  - `test_movement_config_has_explicit_jump_grace_defaults`
  - `test_coyote_time_keeps_jump_available_after_ground_loss`
  - `test_expired_coyote_time_rejects_late_jump`
  - `test_jump_buffer_fires_on_landing_frame`
  - `test_zero_jump_buffer_keeps_immediate_ground_jump`
- Human/user runs Godot-side checks confirming stand-up clearance detects
  ceiling obstruction near the capsule edge.

Visual:

- Scene: existing controller scene or a new crouch/posture scene.
- Expected:
  - crouch lowers capsule and camera together;
  - prompts/raycast origin follow crouch height;
  - low ceiling near the capsule edge prevents standing;
  - leaving the low ceiling allows standing again.
  - jumping just after stepping off a ledge still works within the configured
    grace window.
  - pressing jump slightly before landing jumps on the landing frame.

Human/user completed these Phase 4 visual checks in game and reported they
work.

## Phase 5 Validation

Latest automated result:

- Human/user ran the character-controller gdUnit scene and produced
  `reports/report_206/results.xml`.
- Result: 32 tests, 0 failures, 0 errors.
- The report includes the Phase 5 layer contracts:
  `test_gameplay_physics_layers_is_not_an_autoload`,
  `test_carry_held_mask_excludes_current_player_collision_bits`, and
  `test_carry_release_restores_exact_previous_collision_mask`.

Automated:

- Human/user runs Godot-side checks confirming held body mask excludes the
  player's current collision bits after a fake player-layer rewrite.
- Human/user runs Godot-side checks confirming release restores the exact saved
  mask.
- Expected character-controller report includes:
  - `test_gameplay_physics_layers_is_not_an_autoload`
  - `test_carry_held_mask_excludes_current_player_collision_bits`
  - `test_carry_release_restores_exact_previous_collision_mask`

Visual/manual:

- Grab a carryable.
- Enter/exit an interior or seamless doorway while carrying.
- Expected: held item never shoves the player capsule and still drops/restores collision normally after release.
- Status: blocked until an integrated playable path has both usable carryable
  items and interiors/seamless doorways available for manual testing.

## Water Visual Regression: Swim Re-entry

Observed by human/user in `tests/visual/test_character_controller.tscn`:

- Jump into the water pool while holding forward.
- After the character falls back into the water, they can continue moving while
  visually standing upright instead of returning to swim animation.

Patch validation:

- Latest automated result: human/user ran the character-controller gdUnit scene
  and produced `reports/report_207/results.xml`: 38 tests, 0 failures, 0
  errors.
- Human/user completed the visual re-test and confirmed swim re-entry returns
  to swimming, stays in water, and held jump behaves as repeated swim strokes
  instead of pinning the character near the top.
- Human/user runs the character-controller gdUnit scene and confirms the report
  includes:
  - `test_midair_reenters_swim_when_water_context_returns`
  - `test_swim_surface_clamp_keeps_player_submerged`
  - `test_swim_jump_is_impulse_intent_not_vertical_axis`
  - `test_held_swim_jump_repeats_as_impulse_after_cooldown`
  - `test_animation_manager_resolves_spaced_swim_animation_names`
  - `test_animation_system_retries_movement_state_after_failed_transition`
- Human/user reopens `tests/visual/test_character_controller.tscn`, jumps into
  the water while holding forward, and confirms:
  - HUD `Move` returns to `swim` after re-entry;
  - HUD `Posture` is `swimming`;
  - HUD `Swimming` is `true`;
  - player feet/capsule stay visibly below the waterline instead of floating
    above it while moving;
  - holding jump produces repeated up-then-down swim strokes instead of holding
    the character at maximum swim height;
  - `Anim State` switches to `SwimForward` or a mapped swim state instead of
    remaining in an upright ground locomotion state.

## Phase 6 Validation

Automated:

- Human/user runs the character-controller gdUnit scene:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/run_character_controller_phase0.tscn
```

- Expected after the Phase 6 visual-scene surface contract: 39 tests, 0
  failures, 0 errors.
- Human/user reported the character-controller gdUnit tests all pass after the
  Phase 6 scene-surface contract and respawn action. Report path was not
  provided in chat.
- Confirm the report includes:
  `test_phase6_step_visual_scene_exposes_required_cases`.
- Scripted fixture follow-up report includes:
  `test_phase6_step_solver_scripted_fixture_categories`.
- Human/user reran the focused suite after the fixture was tightened and
  produced `reports/report_215/results.xml`: 51 tests, 0 failures, 0 errors,
  0 skipped.

Visual:

- Scene: `tests/visual/test_character_controller_steps.tscn`
- Human/user launch command:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_character_controller_steps.tscn
```

- Expected:
  - small step climbs;
  - tall wall blocks;
  - angled wall slides or blocks consistently;
  - ceiling-blocked step does not pop through;
  - down-step without floor does not get treated as a safe stair landing;
    walking past the edge may still fall normally;
  - rigidbody obstacle gets one push pass.
- Safety controls:
  - falling below the lane panels respawns the player at the starting lane;
  - pressing the `step_solver_respawn` action (`R` by default) also respawns
    the player.
- The scene is intentionally a standalone measuring rig: it uses a capsule-only
  `PlayerController`, default movement config, production gameplay physics
  layer constants, and project `InputMap` actions. It does not load Morrowind
  data or animations.
- Human/user completed the visual pass and reported all six lanes pass after
  scene clarity fixes. No step solver tuning was needed.

Performance:

- Confirm step solver casts remain bounded and are not proportional to scene object count.

## Phase 7 Validation

Interactive main-scene smoke:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn
```

Checklist:

- [ ] Toggle from fly camera to player mode.
- [ ] Move, sprint, jump, crouch.
- [ ] Toggle first/third person.
- [ ] Cross streaming cell boundaries.
- [ ] Interact with a door/container/activator.
- [ ] Carry, drop, and throw an item.
- [ ] Enter/exit water and verify swim pitch.
- [ ] Enter/exit an interior or seamless doorway while carrying.
- [ ] Check console/log for controller errors.

Expected:

- Player mode feels stable and no subsystem owns movement through animation.

Recorded result:

- Human/user confirmed fly/player switch, movement, sprint, jump, crouch,
  camera toggle, streaming boundaries, and water all work in
  `scenes/Godotwind.tscn`.
- Interaction/carry/interior checks remain blocked by missing dependent
  main-scene content paths, not failed.
- Updated log review passed for the controller scope. `crash_report.txt` says
  "No errors recorded"; `debug_report.txt` says "Errors captured: 0" and "No
  errors"; `godot.log` has zero `SCRIPT ERROR` / `SCRIPT WARNING` entries and
  zero controller/input/interaction/player/animation/water/swim warnings or
  errors. The log does contain unrelated streaming/autopsy, missing static
  collision shape sidecar, and shutdown resource-leak warnings.
- Closure: this pass is complete for available content. There is no Phase 8 in
  this package; blocked interaction/carry/interior checks should move to a
  future integration spec when those paths are ready.

Codex role:

- Provide this command and checklist to the human/user.
- Do not mark Phase 7 runtime validation complete until the human/user reports
  the result.

## Shader Cache Note

No planned phase edits `.glsl`, `.gdshader`, or `.gdshaderinc` files. Shader cache/import clearing is not required unless a later implementation phase expands scope into shader work.
