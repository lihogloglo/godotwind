# Onboarding: Player Camera Modes

Date: 2026-05-15
Owner: Codex
Status: Phase 4 started; runtime visual acceptance pending

## Start Here

Read these before touching code:

1. `AGENTS.md`
2. `spec-driven/README.md`
3. `spec-driven/00-constitution.md`
4. `spec-driven/01-workflow.md`
5. `docs/STATUS.md`
6. `docs/systems/character_controller.md`
7. `docs/systems/input_system.md`
8. This feature folder:
   - `spec-driven/features/player-camera-modes/research.md`
   - `spec-driven/features/player-camera-modes/spec.md`
   - `spec-driven/features/player-camera-modes/plan.md`
   - `spec-driven/features/player-camera-modes/tasks.md`
   - `spec-driven/features/player-camera-modes/validation.md`
   - `spec-driven/features/player-camera-modes/review.md`

## Current State

Phase 4 has started with a static audit of first-person, interaction-ray, and
swim-pitch wiring. No pre-visual runtime rewrite is justified yet: the current
code routes movement through explicit movement basis/pitch providers, keeps
vanity pitch out of movement/swim pitch, and has unit coverage for crouch-driven
camera/raycast posture plus vanity swim-pitch isolation. Human/user visual
verification is still pending and must run before Phase 4 can be accepted.
Limit that acceptance to surface-level swimming: the player currently cannot
intentionally swim below the water surface. Below-surface swimming is a missing
movement/water feature tracked under `spec-driven/features/subsurface-swimming/`.

Phase 2/3 code is implemented on top of the Phase 1 basis split. Runtime code
gives `PlayerInputGatherer` explicit movement basis/pitch providers through
`CharacterMotor`, and movement consumers read `InputPackage.movement_basis`.
`InputPackage.camera_basis` remains only as a synced compatibility alias for
the transition.

Keyboard vanity follows the OpenMW-style held Tab
contract: short Tab toggles first/fixed-third person, while holding Tab enters
temporary third-person vanity until release. If the player is in first person,
holding Tab still enters third-person vanity and release returns to first
person. `camera_vanity` remains a required direct action for gamepad RS click
and is intentionally unbound on keyboard. Vanity stores visual orbit yaw/pitch
separately from the actor-facing movement yaw and primary movement/swim pitch,
then returns to the last primary mode on release.

Latest human/user gdUnit verification:

- `tests/run_character_controller_phase0.tscn` passed in
  `reports/report_220/results.xml` with 71 tests, 0 failures, 0 errors, and
  0 skipped.
- That report includes the Phase 2 directional animation contracts and the
  Phase 3 Tab/vanity contracts: short Tab toggles first/fixed-third person,
  held Tab enters vanity from first or third person, release restores the
  prior primary mode, vanity orbit does not remap movement, vanity pitch does
  not affect swim pitch, and `camera_vanity` remains registered.

Normal first/third-person look yaw now rotates actor/facing yaw on
`character_root` when attached, falling back to the player body when no
character is attached. `camera_pivot` keeps owning pitch, but its yaw is synced
to the actor-facing yaw in primary modes so normal `THIRD_PERSON` follows
behind the player instead of freely orbiting.

After the initial Phase 2 follow change, human visual testing found A/D side
input made the actor spin rapidly. The cause was old movement-direction facing
still being active after yaw ownership moved to look input. The fix was to give
`PlayerController` a private runtime movement config with
`turn_to_movement_direction = false`, leaving the shared/source movement preset
unchanged for other character-controller users.

Earlier human/user gdUnit verification after that fix:

- `tests/run_character_controller_phase0.tscn` passed in
  `reports/report_218/results.xml` with 58 tests, 0 failures, 0 errors, and
  0 skipped.
- That report includes coverage for facing-owned movement basis, look-yaw
  camera follow, and A/D strafing without turning actor facing.

Current runtime verification gap:

- Human visual testing confirmed forward, back, crouch forward, crouch back,
  crouch left, crouch right, jump, `WalkLeft`, and `WalkRight` are correct.
- The prior assumption that vanilla Morrowind/OpenMW had dedicated diagonal
  movement clips was wrong. Phase 2 is no longer blocked on missing diagonal
  animation groups.
- The OpenMW movement-animation research in
  `spec-driven/features/movement animation/openmw player-npc movement animation analysis.md`
  shows OpenMW asks for cardinal movement groups and gets diagonal-looking
  movement from `turn to movement direction`: lower-body/root yaw rotates toward
  the local movement vector while the same cardinal walk/run/sneak/swim groups
  continue to play.
- Movement controls are otherwise correct. Do not reintroduce movement-vector
  facing in `PlayerController` to solve this camera feature. If Godotwind wants
  OpenMW-style diagonal body presentation, implement it as a separate
  locomotion-animation/pose feature around turn-to-movement-direction behavior.
- Human/user visual gameplay testing on 2026-05-15 reported that the Phase 2
  fixed-follow camera and Phase 3 held-Tab vanity behavior work well in game.
- Phase 2/3 are accepted for this feature handoff. The next session should
  begin Phase 4 rather than re-running the same camera-mode acceptance pass.

Human/user verification after Phase 1:

- `tests/run_character_controller_phase0.tscn` passed after the Phase 1 basis
  split: latest recorded report was `reports/report_216/results.xml` with 54
  tests, 0 failures, 0 errors, and 0 skipped.
- `tests/visual/test_character_controller.tscn` initially froze animations after
  switching first/third person. Root cause was scene-specific: the visual scene
  left animation LOD enabled for the local playable avatar, so camera/visibility
  transitions could let `AnimationLODController` deactivate the `AnimationTree`.
- The fix was to mirror `src/tools/world_explorer.gd`: set
  `_factory.enable_lod = false` in `tests/visual/test_character_controller.gd`.
  Human/user confirmed that fixed the animation freeze and all tests passed.
- `scenes/Godotwind.tscn` did not reproduce the animation freeze while switching
  camera perspectives.

## Movement Animation Research

The Phase 2 camera work should not chase nonexistent vanilla diagonal clips.
Public Morrowind/OpenMW references list cardinal movement groups, not
`WalkForwardLeft`/`RunBackRight`-style diagonal groups. The local OpenMW source
audit confirms that OpenMW selects cardinal groups and uses
turn-to-movement-direction body/leg rotation to make diagonal travel look
natural.

Primary local reference:

- `spec-driven/features/movement animation/openmw player-npc movement animation analysis.md`

Practical consequence for this feature:

- Fixed third-person follow can be accepted with cardinal directional
  animation states and fallback lookup.
- Diagonal-specific clips should remain optional mod-provided content, not a
  required vanilla asset expectation.
- OpenMW-style lower-body turning for diagonals belongs in a future movement
  animation/profile feature, not in the player-camera mode split.

Clip names to support first:

- `WalkForward`, `WalkBack`, `WalkLeft`, `WalkRight`
- `RunForward`, `RunBack`, `RunLeft`, `RunRight`
- `SneakForward`, `SneakBack`, `SneakLeft`, `SneakRight`

Swimming equivalents:

- `SwimWalkForward`, `SwimWalkBack`, `SwimWalkLeft`, `SwimWalkRight`
- `SwimRunForward`, `SwimRunBack`, `SwimRunLeft`, `SwimRunRight`

Quentin Preik's movement group list records these movement animation groups,
each with `Start`, `Loop Start`, `Loop Stop`, and `Stop` text keys:

- `Jump`
- `Runback`, `Runforward`, `RunLeft`, `RunRight`
- `SneakBack`, `SneakForward`, `SneakLeft`, `SneakRight`
- `SpellTurnLeft`, `SpellTurnRight`
- `TurnLeft`, `TurnRight`
- `Walkback`, `Walkforward`, `Walkleft`, `WalkRight`

Weapon/combat variants use suffixes:

- `1h`: one-handed weapon
- `2c`: two-handed close grip, such as both hands clasping a longsword hilt
- `2w`: two-handed wide grip, such as staff spacing
- `hh`: hand-to-hand

Preik lists the weapon suffix variants for `Jump`, `Run*`, `Sneak*`, `Turn*`,
and `Walk*` groups. Treat this as a clip inventory reference. OpenMW behavior
for diagonal-looking movement is documented in the local movement-animation
audit above: it uses cardinal movement groups plus turn-to-movement-direction
pose rotation.

References used:

- UESP animation groups:
  https://en.uesp.net/wiki/Morrowind_Mod%3AAnimation_Groups
- MWSE animation groups:
  https://mwse.github.io/MWSE/references/animation-groups/
- Quentin Preik's Morrowind animation group notes:
  https://www.preik.net/morrowind/animationgroups.html
- OpenMW `turn to movement direction` setting:
  https://openmw.readthedocs.io/en/openmw-0.47.0_a/reference/modding/settings/game.html#turn-to-movement-direction

Local code references:

- `src/core/nif/nif_kf_loader.gd` preserves KF text-key names from entries like
  `AnimName: Start`, `AnimName: Loop Start`, and `AnimName: Stop`.
- `src/core/animation/animation_manager.gd` already normalizes compact
  Morrowind names and space-separated imported names during lookup.
- `src/core/animation/morrowind_character_system.gd` now maps cardinal
  Morrowind movement groups and diagonal-intent fallback terms for this
  subtask.

## OpenMW Findings To Keep In Mind

- OpenMW has separate `FirstPerson`, `ThirdPerson`, `Vanity`, and `Preview`
  camera modes.
- OpenMW ThirdPerson makes look input turn the player; the camera follows.
- OpenMW Vanity/Preview lets look input rotate the camera without rotating the
  player.
- OpenMW movement data is actor-relative.
- OpenMW optional `move360` rotates movement input relative to camera yaw. That
  is intentionally not the requested default behavior for Godotwind.
- OpenMW does not require vanilla diagonal movement clips. Its
  `turn to movement direction` setting makes diagonal travel look correct by
  rotating the lower body/root toward the local movement vector while selecting
  cardinal movement animation groups.

## Required Research Before Coding

Completed in the 2026-05-12 research revision:

- Official Godot docs re-checked for `SpringArm3D`, `Camera3D`,
  `Node.physics_interpolation_mode`, `Node3D.get_global_transform_interpolated`,
  `reset_physics_interpolation()`, and `InputMap`.
- Public Godot 4 examples surveyed: GDQuest RoboBlast, Selgesel Godot 4 third
  person controller, and JeanKouss third-person camera addon.
- `research.md`, `spec.md`, `plan.md`, `tasks.md`, `validation.md`, and
  `review.md` were revised with the findings.

Before editing runtime files, re-open `research.md` and only repeat external
research if the Godot version changed or the implementation chooses the manual
top-level camera-follow refinement.

Movement-animation source research for the diagonal clip assumption is complete
as of 2026-05-13 and is recorded in
`spec-driven/features/movement animation/openmw player-npc movement animation analysis.md`.

## Implementation Reminder

Do not patch each Move separately. The right fix is to split:

- visual camera yaw/pitch;
- movement yaw/pitch.

The first implementation slice made `PlayerInputGatherer` receive an explicit
movement basis/pitch from `PlayerController`.

Also carry forward the research updates:

- Keep `SpringArm3D`; explicitly exclude the player body if the current layer
  setup does not already make self-collision impossible.
- Keep the existing interpolation-off camera pivot for the first slice.
- If visual verification shows camera shimmer, switch to Godot's manual camera
  follow pattern using `_process()` plus `get_global_transform_interpolated()`.
- Keyboard vanity uses held Tab. `camera_vanity` remains as direct gamepad
  vanity, but Tab must stay a tap/hold split, not a three-way camera cycle.

## Next Session Start

Continue Phase 4 from `plan.md`: first-person cleanup and swim-pitch visual
acceptance. Do not start by searching for missing diagonal clips or re-running
the Phase 2/3 camera-mode acceptance pass unless new code changes require it.

Recommended first steps:

1. Re-open `tasks.md`, `validation.md`, and `review.md` for the accepted
   Phase 2/3 status and the Phase 4 entry point.
2. Use `reports/report_220/results.xml` as the latest automated baseline:
   71 tests, 0 failures, 0 errors, 0 skipped.
3. Use the movement-animation analysis doc as the source for the corrected
   diagonal assumption: OpenMW uses cardinal movement groups and optional
   turn-to-movement-direction body rotation, not vanilla diagonal clips.
4. Continue Phase 4 with visual acceptance of first-person behavior: movement,
   crouch eye height, interaction ray origin/prompt alignment, and camera
   transitions after the Phase 2/3 changes.
5. Validate surface-level swimming behavior in first person and third person.
   The unit-level vanity swim-pitch contract already passed in `report_220`;
   Phase 4 should check that actual in-game swim pitch still feels honest and
   does not inherit vanity orbit pitch. Do not block this camera-mode phase on
   the missing ability to swim below the water surface; that belongs to
   `spec-driven/features/subsurface-swimming/`.
6. If Phase 4 visual checks reveal a real issue, make the smallest controller
   change that preserves the explicit movement-basis/pitch split. If no issue
   appears, update `tasks.md`, `validation.md`, `review.md`, and
   `docs/systems/character_controller.md` to record Phase 4 acceptance.
7. If visual verification reports shimmer, use the documented manual camera
   follow pattern before moving on.

Do not rework camera interpolation yet. Stay on the existing interpolation-off
camera pivot unless human visual verification reports shimmer after the Phase 2
follow-mode change.

## Verification Reminder

Codex cannot reliably launch Godot from this workspace. After runtime code
changes, the human/user must run the focused visual scene and main scene. If C#
files change, ask them to run:

```powershell
dotnet build Godotwind.sln
```

before launching Godot.
