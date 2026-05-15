# Tasks: Player Camera Modes

- [x] Read the project spec-driven workflow and current character-controller docs.
  - Validate: local docs reviewed before planning.

- [x] Research OpenMW 0.51.0 RC2 camera mode and input behavior.
  - Validate: cite release, camera source, Lua camera scripts, and input/movement source.

- [x] Draft research, spec, and implementation plan.
  - Validate: planning docs exist and contain no runtime-code changes.

- [x] Add onboarding, OpenMW code-shaped ideas, and explicit future research gates.
  - Validate: `onboarding.md`, `research.md`, `spec.md`, and `plan.md` tell the next session what to read and what to verify before coding.

- [x] Re-verify Godot 4.6 camera docs before implementation.
  - Validate: `research.md` records current findings for `SpringArm3D`, camera interpolation, `InputMap`, and any API constraints.

- [x] Survey public Godot 4 third-person camera/controller examples.
  - Validate: `research.md` lists at least two examples, their licenses, whether they are actor-relative or camera-relative, and which ideas are safe to borrow.

- [x] Choose the default keyboard/gamepad vanity binding.
  - Validate: keyboard vanity now follows the OpenMW-style held Tab contract:
    short Tab toggles first/fixed-third person, while held Tab enters temporary
    third-person vanity until release. The direct `camera_vanity` action remains
    specified in `project.godot`/`InputActions` for gamepad RS click (button
    index 8) and is intentionally unbound on keyboard. Human/user should still
    confirm the binding feels usable in the focused visual scene.

- [x] Exclude the player body from SpringArm collision.
  - Validate: `PlayerController._setup_camera()` now calls
    `spring_arm.add_excluded_object(get_rid())`; visual near-wall validation is
    still part of the human runtime pass.

- [x] Split movement basis from visual camera basis.
  - Validate: unit tests prove `PlayerInputGatherer` can use an explicit
    movement basis when visual camera yaw differs, and `MoveContainer` resolves
    desired direction from `InputPackage.movement_basis` rather than the
    compatibility `camera_basis` alias.

- [x] Make normal third-person mode fixed behind player facing.
  - Code: `PlayerController` now routes normal look yaw into actor/facing yaw
    and syncs `camera_pivot` yaw to that facing in primary modes.
  - Code: `PlayerController` now uses a private runtime movement config with
    `turn_to_movement_direction = false` so A/D strafes instead of spinning
    actor facing toward lateral movement input.
  - Validate: unit coverage passed in `reports/report_220/results.xml` for
    facing-owned movement basis, look-yaw camera follow, A/D strafing without
    turning facing, and cardinal/fallback directional animation selection.
    Human/user visual gameplay testing on 2026-05-15 reported that the
    fixed-follow camera works well in game.
  - [x] Add fixed-follow cardinal directional animation selection.
    - Status: the prior diagonal-clip assumption was wrong. Human visual
      testing confirmed forward, back, crouch forward, crouch back, crouch
      left, crouch right, jump, `WalkLeft`, and `WalkRight` are correct.
      Vanilla Morrowind/OpenMW does not provide or require dedicated diagonal
      clips for Phase 2 acceptance.
    - Code currently publishes actor-relative directional animation states for
      lateral, backward, crouch/sneak, swimming, and diagonal input without
      changing movement or facing. Diagonal-intent state names are only a
      modded-content hook/fallback path, not a vanilla requirement.
    - Code currently extends `AnimationManager` and
      `MorrowindCharacterSystem` for cardinal Morrowind movement groups and
      diagonal-intent fallback terms.
    - Previous visual finding: movement is correct after the A/D strafe fix,
      and later human visual testing confirmed `WalkLeft` and `WalkRight`.
    - Research note: vanilla Morrowind/OpenMW references list cardinal movement
      groups, not dedicated diagonal groups. Treat `WalkLeft`/`WalkRight` and
      `RunLeft`/`RunRight` as the side-step clip titles. Diagonal-looking
      movement in OpenMW comes from `turn to movement direction`: lower-body/root
      yaw rotates toward the movement vector while cardinal groups continue to
      play.
    - Clip names to support first: `WalkForward`, `WalkBack`, `WalkLeft`,
      `WalkRight`, `RunForward`, `RunBack`, `RunLeft`, `RunRight`,
      `SneakForward`, `SneakBack`, `SneakLeft`, `SneakRight`.
    - Swimming equivalents: `SwimWalkForward`, `SwimWalkBack`,
      `SwimWalkLeft`, `SwimWalkRight`, `SwimRunForward`, `SwimRunBack`,
      `SwimRunLeft`, `SwimRunRight`.
    - Preik movement group reference: `Jump`; `Runback` / `Runforward` /
      `RunLeft` / `RunRight`; `SneakBack` / `SneakForward` / `SneakLeft` /
      `SneakRight`; `SpellTurnLeft` / `SpellTurnRight`; `TurnLeft` /
      `TurnRight`; `Walkback` / `Walkforward` / `Walkleft` / `WalkRight`.
      These groups use `Start`, `Loop Start`, `Loop Stop`, and `Stop` keys.
    - Weapon/combat suffix meanings from Preik: `1h` = one-handed weapon,
      `2c` = two-handed close grip, `2w` = two-handed wide grip, `hh` =
      hand-to-hand. Preik lists these suffix variants for `Jump`, `Run*`,
      `Sneak*`, `Turn*`, and `Walk*` groups.
    - Treat Preik as a clip inventory reference, not final runtime behavior.
      OpenMW runtime behavior for diagonal-looking movement is documented in
      `spec-driven/features/movement animation/openmw player-npc movement animation analysis.md`.
    - Sources used for the clip-title research:
      https://en.uesp.net/wiki/Morrowind_Mod%3AAnimation_Groups
      https://mwse.github.io/MWSE/references/animation-groups/
      https://www.preik.net/morrowind/animationgroups.html
      https://openmw.readthedocs.io/en/openmw-0.47.0_a/reference/modding/settings/game.html#turn-to-movement-direction
    - Local code references: `src/core/nif/nif_kf_loader.gd` preserves KF
      text-key animation names (`AnimName: Start` / `Loop Start` / `Stop`);
      `src/core/animation/animation_manager.gd` already normalizes compact
      Morrowind names and space-separated names for lookup.
    - Expected behavior: A/D alone should play lateral strafe/side-step
      animation states; W+A, W+D, S+A, and S+D should move correctly with
      cardinal/fallback animation selection. OpenMW-style diagonal body
      presentation is a future turn-to-movement-direction pose feature, not a
      missing animation blocker.
    - Validate: focused coverage passed in `reports/report_220/results.xml`
      for lateral, diagonal, crouch/sneak, swim directional state selection,
      Morrowind directional clip lookup, and diagonal fallback. Human/user
      still needs to visually confirm the focused controller scene preserves
      the fixed-follow movement controls.
  - [x] Review OpenMW movement animation behavior for the diagonal assumption.
    - Findings are recorded in
      `spec-driven/features/movement animation/openmw player-npc movement animation analysis.md`.
    - OpenMW selects cardinal movement groups such as `walkforward`,
      `walkleft`, `runforward`, `sneakright`, `swimrunforward`, and
      `swimwalkleft`.
    - OpenMW's `turn to movement direction` setting is the source of
      diagonal-looking body presentation. It rotates lower-body/root yaw toward
      the local movement vector and layers upper-body compensation; it is not a
      request for `WalkForwardLeft` / `RunBackRight` asset groups.
    - Godotwind should treat that as a future locomotion-animation/profile
      feature if desired, separate from the player-camera mode fix.

- [x] Add third-person vanity/orbit mode.
  - Code: `PlayerController.CameraMode.THIRD_PERSON_VANITY` now exists as a
    temporary hold mode entered by holding `toggle_camera` or by direct
    `camera_vanity` gamepad input. Short `toggle_camera` presses still toggle
    first/follow.
  - Code: vanity stores separate visual orbit yaw/pitch, returns to the last
    primary first/third-person mode on release, and keeps movement basis on
    actor facing.
  - Code: movement/swim pitch now reads the primary look pitch, so vanity
    orbit pitch cannot add vertical swim intent.
  - Validate: focused unit coverage passed in `reports/report_220/results.xml`
    for orbit-without-remap, release-to-primary, held-Tab entry from first and
    third person, short-Tab toggling, swim pitch isolation, and required
    `camera_vanity` registration. Human/user visual gameplay testing on
    2026-05-15 reported that held-Tab vanity works well in game.

- [x] Begin Phase 4 first-person and swim-pitch acceptance audit.
  - Code audit: first-person and fixed-follow yaw both use
    `PlayerController._get_movement_yaw()` / `_get_facing_node()` for movement
    basis; pitch used by movement systems comes from `_movement_look_pitch`;
    vanity orbit pitch writes only `_vanity_orbit_pitch`; and
    `PlayerInputGatherer` reads the explicit movement basis/pitch providers.
  - Code audit: crouch posture already drives `camera_pivot.position.y`, and
    `InteractionRaycaster.ray_origin_node` can be bound to that pivot so prompt
    origin follows the same standing/crouching eye height.
  - Validate: this audit does not replace runtime/editor validation. Human/user
    still needs to run the focused visual scene and main scene checks below.

- [ ] Human/user Phase 4 focused visual acceptance.
  - Validate in `tests/visual/test_character_controller.tscn`: first-person
    movement follows facing yaw, pitch changes view/swim intent without pitching
    the body around world X, crouch lowers/restores eye height and prompt origin,
    Tab camera transitions remain clean, and surface-level swim pitch isolation
    feels honest.
  - Blocked: below-surface swimming cannot be accepted in this feature because
    the player currently cannot intentionally swim below the water surface.
    Track that missing movement/water feature under
    `spec-driven/features/subsurface-swimming/`.
  - Validate in `scenes/Godotwind.tscn`: enter player mode, check first-person
    movement/crouch/interact prompts, verify third-person and held-Tab vanity
    still behave, swim in water, cross a streaming boundary, and check logs for
    camera/controller/input/swim errors.
  - If a real issue appears, fix the smallest controller-side gap while
    preserving the explicit movement-basis/pitch split.

- [x] Move swim vertical intent off raw camera-pivot pitch.
  - Validate: unit test proves `PlayerInputGatherer` can use an explicit
    movement pitch provider for swim vertical intent. A later vanity-mode test
    should prove vanity orbit pitch is not used once that mode exists.

- [x] Decide whether manual camera interpolation is needed after the basis split.
  - Validate: human/user confirmed `tests/visual/test_character_controller.tscn`
    and `scenes/Godotwind.tscn` work after the Phase 1 basis split. The only
    visual-scene regression was animation LOD culling on camera perspective
    switches, fixed by disabling local-player animation LOD in the focused
    scene. No manual camera interpolation rewrite was needed for Phase 1.

- [x] Update docs and validation scenes.
  - Validate: `docs/systems/character_controller.md`,
    `validation.md`, `review.md`, and `onboarding.md` describe the Phase 1
    movement-basis provider and visual-scene animation LOD fix.

- [x] Human/user runtime verification for Phase 1.
  - Validate: human/user ran the focused gdUnit scene, focused visual scene,
    and `scenes/Godotwind.tscn`; all tests passed, the visual-scene animation
    freeze was fixed, and the main scene did not reproduce the freeze.
