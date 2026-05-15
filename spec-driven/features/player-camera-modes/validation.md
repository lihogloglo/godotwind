# Validation: Player Camera Modes

Status: Phase 4 started; runtime visual acceptance pending.

## Automated Checks

Added in Phase 1:

- `test_input_gatherer_uses_explicit_movement_basis_provider`
- `test_move_container_resolves_direction_from_movement_basis_not_camera_alias`
- `test_swim_pitch_can_use_explicit_movement_pitch_provider`

Added in Phase 2:

- `test_third_person_movement_basis_uses_character_facing_not_camera_pivot`
- `test_third_person_look_yaw_turns_facing_and_syncs_camera_follow`
- `test_player_controller_left_right_input_strafes_without_turning_facing`
- `test_directional_ground_animation_state_uses_lateral_input`
- `test_directional_ground_animation_state_preserves_diagonal_intent`
- `test_directional_crouch_animation_state_uses_sneak_cardinals`
- `test_directional_swim_animation_state_uses_cardinal_groups`
- `test_animation_manager_resolves_directional_morrowind_names`
- `test_animation_manager_directional_diagonal_falls_back_to_cardinal`

Added in Phase 3:

- `test_camera_vanity_orbits_without_changing_movement_basis`
- `test_camera_vanity_release_returns_to_primary_mode`
- `test_camera_vanity_pitch_does_not_change_swim_movement_pitch`
- `test_camera_vanity_action_is_required_input_action`
- `test_camera_tab_tap_toggles_first_and_third_person`
- `test_camera_tab_hold_enters_vanity_then_returns_to_third_person`
- `test_camera_tab_hold_from_first_person_enters_vanity_then_returns_to_first_person`

Latest human-run report:

- `reports/report_220/results.xml`
- `test_character_controller_phase0_baseline`: 71 tests, 0 failures, 0 errors,
  0 skipped.

The directional animation tests above cover cardinal/fallback state selection;
they should not be read as proof that vanilla Morrowind has dedicated diagonal
animation clips. The Phase 3 vanity tests cover the camera/movement contract,
held Tab behavior from first and third person, short Tab toggling, swim pitch
isolation, and input action registration. They do not replace the required
interactive orbit visual check.

Recommended unit or focused integration coverage:

- Movement basis split:
  - facing yaw = 0 degrees;
  - vanity/orbit camera yaw = 180 degrees;
  - forward input resolves to facing-forward world direction.
- Fixed follow:
  - look yaw updates player/character facing;
  - camera follow yaw matches facing yaw after update.
  - A/D strafe uses lateral movement animation states without rotating facing.
  - W+A, W+D, S+A, and S+D preserve movement correctness and use
    cardinal/fallback animation selection. OpenMW-style diagonal-looking body
    presentation is a future turn-to-movement-direction pose feature.
- First person:
  - forward input uses facing yaw;
  - pitch affects view/look pitch but does not rotate the body around world X.
- Swim:
  - vanity camera pitch does not add vertical swim intent;
  - first-person/follow look pitch can still contribute to swim pitch where intended.

## Pre-Code Research Checks

Completed on 2026-05-12 and recorded in `research.md`:

- Current Godot 4.6 `SpringArm3D` guidance, especially collision masks, margin,
  shape/ray behavior, and excluding the player collider.
- Current Godot physics interpolation guidance for cameras, especially whether
  the camera rig should remain interpolation-off and whether manual target
  interpolation is recommended.
- Current Godot `InputMap` implications for any new vanity input action.
- Public Godot third-person camera examples surveyed, including whether each
  example uses actor-relative movement or camera-relative movement.

Future implementation should re-run these checks only if the project moves to a
new Godot version or the camera rig changes to a manual top-level follow rig.

## Focused Visual Scene

Use or extend `tests/visual/test_character_controller.tscn`, or create a focused
camera-mode visual scene if the existing scene becomes too busy.

Required visual checks:

- Start in third-person fixed follow.
- Press forward: character moves forward relative to their facing.
- Move mouse/controller yaw: character turns, camera remains behind.
- Stand near a wall or column: `SpringArm3D` retracts because of the wall, not
  because it collides with the player body.
- Hold the `camera_vanity` action, or use the documented temporary validation
  gamepad action.
- On keyboard, hold Tab to enter vanity. A short Tab press should still toggle
  first/fixed-third person.
- Rotate camera until it is in front of the character.
- Press forward: character still moves in character-forward direction, not
  camera-forward direction.
- Release Tab, or release `camera_vanity` on gamepad: camera returns to the
  primary first/follow mode without changing that primary mode.
- Move from OpenMW-style idle vanity: camera returns to primary follow mode.
- Switch to first person.
- Move, sprint, jump, crouch, interact, and swim if water is available.
- Temporarily lower physics tick rate if camera jitter is hard to see at normal
  settings; if shimmer appears, validate the manual camera-follow path before
  accepting the feature.

## Main Scene Smoke

Human/user launches:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn
```

Checklist:

- Toggle from fly camera to player mode.
- Verify third-person fixed follow.
- Verify vanity/orbit camera does not remap controls.
- Verify first-person camera.
- Cross at least one streaming boundary.
- Check console/log for camera, controller, input, or movement errors.

If C# changes are made in a future implementation pass, run:

```powershell
dotnet build Godotwind.sln
```

before launching Godot.

## Shader Cache

No shader files are part of this planning pass. Shader import/cache clearing is
not applicable unless a future implementation unexpectedly edits `.glsl`,
`.gdshader`, or `.gdshaderinc` files.

## Current Verification State

Phase 4 has started with a static controller audit. Current code already routes
first-person/fixed-follow movement through the explicit movement basis provider,
keeps movement/swim pitch in `_movement_look_pitch`, isolates vanity pitch in
`_vanity_orbit_pitch`, and lets the interaction ray origin follow
`PlayerController.camera_pivot` when scenes bind `ray_origin_node` that way.
This is not runtime acceptance; it only shows there is no obvious code gap that
justifies a pre-visual rewrite.

Phase 4 runtime/editor verification is pending. Human/user should run:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind res://tests/visual/test_character_controller.tscn
```

Focused Phase 4 checklist:

- Switch to first person and verify forward/back/strafe follow the actor-facing
  yaw after mouse/controller look.
- Look up/down and verify pitch affects the view and swimming intent, but the
  body does not pitch around world X during normal first-person look.
- Crouch and stand; confirm eye height and interaction prompt origin lower and
  restore together.
- Tap Tab between first and fixed-third person, then hold Tab for vanity and
  release; confirm the primary mode returns correctly.
- Enter water in first person and third person; verify surface-level swim pitch
  isolation feels honest and vanity orbit pitch does not add vertical swim
  intent.
- Do not fail this camera-mode phase because the player cannot swim below the
  water surface. Below-surface swimming is a missing movement/water feature,
  tracked separately in `spec-driven/features/subsurface-swimming/`.
- Watch for camera shimmer during transitions. If shimmer appears, use the
  documented manual interpolated camera-follow path before accepting Phase 4.

Then run the main scene:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn
```

Main-scene Phase 4 checklist:

- Toggle from fly camera to player mode.
- Repeat first-person movement, crouch, prompt-origin, fixed-third, held-Tab
  vanity, and swimming checks with real streamed content.
- Cross at least one streaming boundary.
- Check the console/log for camera, controller, input, interaction, or swim
  errors/warnings.

Phase 1 has code changes, but Codex still cannot reliably launch Godot from
this workspace. Static checks completed:

- `git diff --check`
- `rg` check for remaining `input.camera_basis` movement consumers

Phase 1 human/user automated gdUnit verification passed in
`reports/report_216/results.xml`: 54 tests, 0 failures, 0 errors, 0 skipped.

Human/user visual finding: `tests/visual/test_character_controller.tscn`
froze character animations after first/third-person perspective switches, while
`scenes/Godotwind.tscn` did not. The visual scene now mirrors main-scene player
setup by disabling animation LOD for the local playable avatar. Retest the
focused visual scene and confirm animations continue after repeated perspective
switches.

Human/user confirmed the animation LOD fix resolved the focused visual-scene
freeze. All tests passed after the fix. `scenes/Godotwind.tscn` remained clean
for camera perspective switching.

Phase 2 automated gdUnit verification passed in `reports/report_217/results.xml`:
57 tests, 0 failures, 0 errors, 0 skipped. The new Phase 2 tests
`test_third_person_movement_basis_uses_character_facing_not_camera_pivot` and
`test_third_person_look_yaw_turns_facing_and_syncs_camera_follow` are included
in that report.

After `report_217`, human visual testing found a Phase 2 regression: A/D
side input spun the player rapidly because older movement-direction tracking
was still active after yaw ownership moved to actor-facing look. The fix gives
`PlayerController` a private runtime movement config with
`turn_to_movement_direction = false`, leaving the source preset intact, and
adds `test_player_controller_left_right_input_strafes_without_turning_facing`.
Human-run gdUnit verification passed in `reports/report_218/results.xml`: 58
tests, 0 failures, 0 errors, 0 skipped. The A/D strafe regression test is
included in that report.

The prior strafe/diagonal animation blocker was based on an incorrect
assumption that vanilla Morrowind/OpenMW had dedicated diagonal clips. Human
visual testing confirmed these cases are correct: forward, back, crouch
forward, crouch back, crouch left, crouch right, jump, `WalkLeft`, and
`WalkRight`. The OpenMW movement-animation audit at
`spec-driven/features/movement animation/openmw player-npc movement animation analysis.md`
shows OpenMW selects cardinal movement groups and uses
turn-to-movement-direction lower-body/root yaw to make diagonal travel look
natural. Phase 2 camera/follow acceptance is therefore not blocked on missing
diagonal animation groups.

Phase 2 code changes route normal first/third-person look yaw into the
actor-facing node and sync `camera_pivot` yaw to that facing. Human/user gdUnit
verification passed in `reports/report_220/results.xml`: 71 tests, 0 failures,
0 errors, 0 skipped. This includes the Phase 2 directional animation coverage
and the Phase 3 Tab/vanity tests.

Phase 3 automated verification has passed. Keyboard vanity now uses the
OpenMW-style held Tab behavior: short Tab toggles first/fixed-third person,
while held Tab enters temporary third-person vanity and returns to the prior
primary mode on release. The direct `camera_vanity` `InputMap` action remains
required for gamepad RS click and is intentionally unbound on keyboard.
`THIRD_PERSON_VANITY` uses separate visual orbit yaw/pitch while movement basis
and swim pitch stay tied to actor-facing primary look state. Automated gdUnit
validation is clean in `report_220`. Human/user visual gameplay testing on
2026-05-15 reported that the fixed-follow camera and held-Tab vanity behavior
work well in game.

Next verification target is Phase 4: first-person cleanup and surface-swim pitch
visual acceptance. Start with first-person movement, crouch eye height,
interaction ray origin/prompt alignment, camera transitions, and surface-level
swimming behavior. The unit-level vanity swim-pitch contract already passed in
`report_220`. Full below-surface swimming is blocked by the separate
subsurface-swimming feature.
