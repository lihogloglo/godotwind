# Plan: Player Camera Modes

## Spec Link

`spec.md`

## Architecture Summary

The core change is to stop treating `camera_pivot.rotation.y` as the movement
truth. `PlayerController` should own a camera mode state and provide
`PlayerInputGatherer` with an explicit movement reference for the current mode.

The pre-code research gate in `research.md` is complete as of 2026-05-12.
Godot docs and public examples did not change the core plan. They did add two
implementation notes:

- keep `SpringArm3D`, but exclude the player RID explicitly during setup;
- if camera shimmer appears after mode/facing changes, use Godot's manual
  camera-follow pattern: interpolation-off camera in `_process()`, following an
  interpolated target via `Node3D.get_global_transform_interpolated()`.

Recommended mode model:

```text
PlayerController
  -> CameraMode state
  -> CameraPivot / SpringArm3D / Camera3D visual rig
  -> CharacterMotor
      -> PlayerInputGatherer
          -> InputPackage.movement_basis
          -> InputPackage.movement_pitch
      -> MoveContainer
```

The existing `SpringArm3D` remains the right Godot feature for third-person
camera distance and collision. The fix belongs at the input/camera ownership
boundary, not inside every movement state.

Public Godot 4 controllers surveyed during research mostly use camera-relative
movement. They are useful as examples of camera component boundaries and
SpringArm setup, but they are non-fits for Godotwind's vanity-mode movement
contract.

Additional local sample review:

- The local JeanKouss third-person camera project is useful as a camera-only
  component example: it keeps a distinct rotation pivot, offset pivot,
  `SpringArm3D`, marker, and `Camera3D`, and exposes camera/SpringArm settings
  without owning host locomotion.
- Do not import the addon wholesale. Godotwind already has the necessary rig,
  and the feature needs a movement-reference contract more than a new camera
  package.
- Do not copy the sample rolling-ball movement helpers
  (`get_front_direction()`, `get_left_direction()`, etc.) into player movement;
  they intentionally make locomotion camera-relative, which is the bug class
  vanity mode is meant to remove.
- Treat the sample's top-level camera and pivot/offset hierarchy as optional
  inspiration only if Godotwind later needs the manual interpolated camera-follow
  refinement. The first implementation slice should still stay on the existing
  `camera_pivot` / `SpringArm3D` path.

## Mode Semantics

### First Person

- `spring_arm.spring_length = 0`.
- Character mesh hidden as today.
- Mouse/controller yaw rotates the facing node.
- Mouse/controller pitch changes camera/look pitch.
- Movement basis is facing yaw.
- Swim vertical pitch uses the active look pitch.

### Third-Person Fixed Follow

- Existing `THIRD_PERSON` should become fixed follow.
- `spring_arm.spring_length = camera_distance`.
- Character mesh visible.
- Mouse/controller yaw rotates the facing node.
- Camera yaw is aligned behind that facing node.
- Movement basis is facing yaw.
- Pitch is camera pitch, clamped as today.

### Third-Person Vanity

- Add `THIRD_PERSON_VANITY`.
- `spring_arm.spring_length = camera_distance`.
- Character mesh visible.
- Mouse/controller yaw/pitch rotates only the camera orbit.
- Movement basis remains facing yaw.
- Movement pitch for swim remains the primary/facing look pitch, not orbit
  pitch.
- OpenMW-style idle auto-vanity may be added as a mode transition policy, but it
  should return to the primary mode on movement/activity.

## Data and API Changes

Recommended minimum data changes:

- Rename or supersede `InputPackage.camera_basis` with `movement_basis`.
  Compatibility path: keep `camera_basis` for one phase but set it from the
  chosen movement basis, then rename in a cleanup.
- Add `InputPackage.movement_pitch` or `look_pitch_for_movement`.
- Add a `PlayerController` helper:

```text
func _get_movement_basis() -> Basis
func _get_movement_pitch() -> float
func _apply_look_delta(yaw_delta: float, pitch_delta: float) -> void
```

- `PlayerInputGatherer` should receive a callable or small provider reference
  for movement basis/pitch instead of reading `camera_pivot` directly. Prefer a
  callable first because it is the smallest local change and avoids adding a new
  framework interface before repeated use proves one is needed.
- Keep camera ray/interaction targeting tied to the active view camera. Do not
  use that view ray as movement truth.

Avoid adding a new autoload. This is local player-controller state.

## OpenMW-Inspired Coding Sketches

### Central look routing

OpenMW's important idea is a single look-input gate: Vanity/Preview applies look
to the camera; normal First/Third applies look to the player. Godotwind should
avoid scattering that decision into movement states.

```gdscript
func _apply_look_delta(yaw_delta: float, pitch_delta: float) -> void:
	match camera_mode:
		CameraMode.THIRD_PERSON_VANITY:
			_orbit_yaw += yaw_delta
			_orbit_pitch = clampf(_orbit_pitch + pitch_delta, -_tilt_limit_rad, _tilt_limit_rad)
		_:
			_turn_facing(yaw_delta)
			_look_pitch = clampf(_look_pitch + pitch_delta, -_tilt_limit_rad, _tilt_limit_rad)
```

### Movement provider instead of camera pivot read

`PlayerInputGatherer` should stop owning camera semantics. Its job should be
reading physical input and asking the player/controller mode owner what movement
frame to use.

```gdscript
var movement_basis_provider: Callable
var movement_pitch_provider: Callable

func gather_input(is_in_water: bool = false, water_surface_y: float = -INF) -> InputPackage:
	var pkg := InputPackage.new()
	pkg.input_direction = Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_backward")
	pkg.movement_basis = movement_basis_provider.call()
	pkg.movement_pitch = movement_pitch_provider.call()
	pkg.camera_basis = pkg.movement_basis
	return pkg
```

Compatibility note: `pkg.camera_basis` can be kept during the first slice to
avoid renaming every consumer at once, but the value should come from the
movement provider, not the visual camera pivot.

### Visual rig update

The camera visual yaw and movement yaw must be different values in vanity mode.

```gdscript
func _apply_camera_visual_transform() -> void:
	var yaw := _orbit_yaw if camera_mode == CameraMode.THIRD_PERSON_VANITY else _get_facing_yaw()
	var pitch := _orbit_pitch if camera_mode == CameraMode.THIRD_PERSON_VANITY else _look_pitch
	camera_pivot.rotation = Vector3(pitch, yaw, 0.0)
```

Implementation must confirm whether `camera_pivot` should remain a child of the
player body or whether a small rig node should hold orbit state. Prefer the
smallest scene-tree change that preserves interpolation behavior.

### SpringArm collision setup

Godot's SpringArm docs explicitly support excluding the player collider. During
implementation, add the player's RID to the spring arm's excluded objects after
the player body exists:

```gdscript
spring_arm.add_excluded_object(get_rid())
```

Keep the existing collision mask/margin shape unless validation shows a
specific near-wall clipping problem. Do not replace `SpringArm3D` with a custom
camera collision solver in this feature.

### Interpolation policy

First implementation should keep the current interpolation-off camera pivot.
If the fixed-follow or vanity work makes the camera visually shimmer, promote
camera follow to Godot's manual interpolation pattern:

- camera or camera rig is independent/global (`top_level` or separate branch);
- target position comes from `get_global_transform_interpolated()` in `_process()`;
- mouse/gamepad yaw and pitch stay render-rate fresh;
- discontinuous mode changes call `reset_physics_interpolation()` after applying
  the new transform.

Do not introduce a manual interpolation rewrite in Phase 1 unless the basis
split itself reveals a visual problem. The first slice should stay surgical.

## Files Likely Touched In Implementation

- `src/core/player/player_controller.gd`
- `src/core/character/controller/player_input_gatherer.gd`
- `src/core/character/controller/input_package.gd`
- `src/core/character/controller/move.gd`
- `src/core/character/controller/move_container.gd`
- `src/core/character/controller/moves/swim_move.gd`
- `src/core/character/character_motor.gd`
- `docs/systems/character_controller.md`
- `docs/systems/input_system.md` if a new vanity action is added
- `tests/unit/test_character_controller_phase0_baseline.gd`
- `tests/visual/test_character_controller.gd` or a new focused camera-mode
  visual scene

## Implementation Phases

### Phase 0: Planning Package

Status: complete for the 2026-05-12 research revision. Phase 1, Phase 2, and
Phase 3 have landed. Phase 3 vanity automated verification passed in
`reports/report_220/results.xml`, and human/user visual gameplay testing on
2026-05-15 reported fixed third-person follow and held-Tab vanity work well in
game. Phase 4 has started with a static first-person/swim audit; runtime visual
acceptance is pending.

Scope:

- Record OpenMW findings.
- Define Godotwind behavior and acceptance criteria.
- Do not change runtime code.

### Phase 1: Split Movement Basis From Visual Camera

Goal: remove the root coupling without changing visible camera behavior yet.

Scope:

- Use the completed 2026-05-12 research notes in `research.md`.
- Add player RID exclusion to the spring arm if local verification confirms it
  is not already excluded by collision-layer setup.
- Add explicit movement basis/pitch fields or provider.
- Make all movement consumers use the movement basis.
- Keep current third-person visual behavior temporarily, but prove movement can
  be supplied independently from camera yaw.

Validation:

- Unit: forward input with camera yaw 180 and facing yaw 0 resolves to facing
  forward when the provider says actor-relative.
- Unit: existing camera-relative expectations are either removed or marked as a
  future optional mode.

### Phase 2: Fixed Third-Person Follow

Goal: make normal third-person camera fixed behind player facing.

Scope:

- Change `THIRD_PERSON` look handling so yaw input rotates player/character
  facing.
- Align camera yaw to the facing node in follow mode.
- Preserve pitch clamp and spring-arm collision.
- Preserve existing first/third toggle.
- Do not treat diagonal-looking movement as a missing animation-clip problem.
  The 2026-05-13 movement-animation audit shows OpenMW selects cardinal movement
  groups and uses turn-to-movement-direction body/root yaw for diagonal
  presentation. That belongs to a future locomotion-animation/profile feature,
  not the camera-mode split.

Validation:

- Visual: rotate view left/right in third person; character turns and camera
  stays behind.
- Unit/fixture: after look yaw, movement basis and camera follow yaw agree.

### Phase 3: Vanity Camera Mode

Goal: add orbit/vanity as a separate mode where camera yaw/pitch does not remap
movement.

Scope:

- Add `THIRD_PERSON_VANITY`.
- Make `toggle_camera` a keyboard tap/hold action: short Tab toggles
  first/fixed-third person, while holding Tab enters temporary third-person
  vanity until release. Keep a separate `camera_vanity` `InputMap` action for
  direct gamepad vanity, but do not turn Tab into a three-way cycle.
- Orbit camera yaw/pitch independently from facing.
- Return to primary mode on movement if implementing OpenMW-style idle vanity.

Validation:

- Visual: turn camera to face the character from the front, press forward, and
  confirm the character moves in their own forward direction.
- Visual: begin moving from auto-vanity and confirm camera returns to primary
  follow mode.

### Phase 4: First-Person Cleanup And Swim Pitch

Goal: make first-person and swim pitch semantics honest after basis split.

Current phase. The unit-level vanity swim-pitch contract already passed in
`reports/report_220/results.xml`, so continue with visual acceptance of
first-person movement, crouch eye height, interaction ray origin, camera
transitions, and surface-level swimming before adding code. Full below-surface
swimming is blocked by the separate movement/water feature tracked in
`spec-driven/features/subsurface-swimming/`.

Scope:

- Ensure first-person yaw/facing, pitch, crouch eye height, and interaction ray
  origin remain coherent.
- Move swim vertical intent to the explicit movement/look pitch field.
- Ensure vanity orbit pitch does not affect swim vertical intent.
- Do not implement diving/below-surface swimming in this phase. That belongs to
  `spec-driven/features/subsurface-swimming/`.

Validation:

- Unit: vanity pitch does not produce swim vertical intent.
- Visual: first-person movement, crouch, interaction prompts, and surface-level
  swimming still behave as expected.

### Phase 5: Docs And Main-Scene Smoke

Goal: update truth docs and run human validation.

Scope:

- Update `docs/systems/character_controller.md`.
- Update `docs/STATUS.md` only after human/user runtime validation.
- Add or update validation checklist.

Validation:

- Human/user launches `tests/visual/test_character_controller.tscn`.
- Human/user launches `scenes/Godotwind.tscn`.
- Check logs for camera/controller/input errors.

## Risk Register

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Facing is currently owned by `character_root`, not the player body. | Camera follow may need careful transform math. | Start by deriving basis from the facing node; move yaw ownership only if needed. |
| Existing tests assume camera-relative movement. | Tests may fail for the intended behavior change. | Update tests to the new spec; do not preserve the broken coupling. |
| Swim uses camera pitch today. | Vanity pitch could still affect vertical swim. | Add explicit movement pitch and a regression test. |
| Interaction ray uses camera pivot. | Vanity could make prompts target what the camera sees, while movement remains actor-relative. | Decide per mode: interaction should usually use the active view camera; movement should not. Document this split. |
| Mode toggles become confusing. | User may not know whether Tab toggles first/follow/vanity. | Keep Tab as tap/hold, not a cycle: short press toggles first/follow, hold enters vanity only while held. |
| Public Godot examples are camera-relative by default. | They could reintroduce the reported bug if copied uncritically. | Borrow only component boundaries and SpringArm setup; keep Godotwind's explicit movement-reference contract. |
| Camera interpolation docs may alter the best node ownership. | A correct control split could still shimmer visually. | Keep Phase 1 surgical; if shimmer appears, switch to a small manual `_process()` camera rig using interpolated follow targets. |
| SpringArm still checks the player body. | The camera can push inward when it should not. | Exclude the player RID from SpringArm collision after setup, then validate near walls. |

## Documentation Plan

- This feature folder records research/spec/plan/tasks/validation.
- `docs/systems/character_controller.md` should gain a camera-mode subsection
  once code changes land.
- `docs/systems/input_system.md` should be updated only if a new action is
  added.
- `docs/STATUS.md` should change only after the human/user confirms runtime
  behavior.

## Runtime Verification Notes

Codex cannot reliably launch Godot in this workspace. Future implementation
must include human-run runtime/editor validation before calling the feature
done.
