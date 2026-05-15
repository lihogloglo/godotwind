# Review: Player Camera Modes

Date: 2026-05-15
Status: Phase 4 started; runtime visual acceptance pending

## Spec Compliance

- Research used OpenMW as a behavioral reference without treating OpenMW's
  C++/Lua architecture as a Godotwind mandate.
- The plan keeps Morrowind/OpenMW-specific defaults out of generic framework
  code.
- The recommended fix addresses the root coupling between visual camera basis
  and movement basis instead of patching individual movement states.
- Godot camera/SpringArm/InputMap/interpolation docs were re-checked on
  2026-05-12 and did not invalidate the plan.
- Public Godot 4 examples were classified by movement reference. The surveyed
  controllers are mostly camera-relative, so they are useful as warnings and
  component-boundary examples rather than movement-policy sources.
- Human-run gdUnit verification passed in `reports/report_216/results.xml`
  with 54 tests, 0 failures, 0 errors, and 0 skipped.
- Phase 1 now routes `PlayerInputGatherer` through explicit movement
  basis/pitch providers, keeps `camera_basis` only as a compatibility alias,
  and updates movement consumers to read `InputPackage.movement_basis`.
- Phase 1 adds a SpringArm player-RID exclusion during player camera setup.
- The focused visual test scene now disables animation LOD for the local
  playable avatar, matching `world_explorer.gd`. Human/user confirmed this
  fixed the first/third-person animation freeze in
  `tests/visual/test_character_controller.tscn`.
- Phase 2 changes normal first/third-person look yaw ownership: mouse and
  controller yaw now rotate the actor-facing node, and the camera pivot follows
  that facing yaw instead of owning movement truth.
- Phase 2 adds focused unit coverage proving movement basis comes from
  character facing even if camera pivot yaw differs, and proving look yaw turns
  facing while syncing the follow camera.
- A/D spin regression was caught during human visual testing after `report_217`.
  The fix keeps player-facing owned by look by disabling movement-direction
  tracking only on `PlayerController`'s private runtime movement config, leaving
  shared presets intact.
- The strafe/diagonal animation blocker has been corrected. The premise that
  vanilla Morrowind/OpenMW had dedicated diagonal movement clips was wrong.
  Human visual testing confirmed forward, back, crouch forward, crouch back,
  crouch left, crouch right, jump, `WalkLeft`, and `WalkRight` are correct.
- Added focused coverage for the current lateral/diagonal state selection,
  Morrowind directional clip lookup, and diagonal fallback behavior. These
  tests cover Godotwind's cardinal/fallback path and should not be read as
  proof that diagonal vanilla clips exist.
- The OpenMW player/NPC movement-animation audit in
  `spec-driven/features/movement animation/openmw player-npc movement animation analysis.md`
  shows OpenMW selects cardinal movement groups and uses
  turn-to-movement-direction lower-body/root yaw for diagonal-looking movement.
- Phase 3 has started. Keyboard vanity now follows the OpenMW-style held Tab
  contract: short Tab toggles first/fixed-third person, while holding Tab enters
  temporary third-person vanity until release. `camera_vanity` remains a
  required direct gamepad RS-click action and is intentionally unbound on
  keyboard.
- Vanity mode keeps visual orbit yaw/pitch separate from actor-facing movement
  yaw and primary movement/swim pitch, then returns to the last primary
  first/third-person mode on release.
- Focused unit coverage was added for vanity orbit not remapping movement,
  release returning to the primary mode, held Tab from first and third person,
  short Tab toggling, vanity pitch not changing swim movement pitch, and
  `camera_vanity` registration.
- Human-run gdUnit verification passed in `reports/report_220/results.xml`
  with 71 tests, 0 failures, 0 errors, and 0 skipped. This report includes the
  Phase 2 directional animation coverage and the Phase 3 Tab/vanity coverage.
- Human/user visual gameplay testing on 2026-05-15 reported that fixed
  third-person follow and held-Tab vanity work well in game.
- Phase 4 has started with a static audit of first-person, interaction-ray, and
  swim-pitch wiring. The current code uses the explicit movement basis/pitch
  provider path, keeps vanity pitch out of movement/swim pitch, and has unit
  coverage for crouch-driven camera/raycast posture plus vanity swim-pitch
  isolation.

## Residual Risks

- Phase 4 runtime/editor acceptance is still pending. Codex cannot launch Godot
  reliably from this workspace, so human/user visual verification must confirm
  first-person movement, crouch eye height, prompt origin, camera transitions,
  and surface-level swimming before this phase can be called accepted.
- Below-surface swimming is blocked by a missing movement/water feature: the
  player currently cannot intentionally swim below the water surface. Do not
  solve that inside player-camera-modes; track it under
  `spec-driven/features/subsurface-swimming/`, whose research anchors include
  OpenMW's swim/body-pitch and optional swim-upward-correction behavior.
- OpenMW-style turn-to-movement-direction body presentation is a future
  locomotion-animation/profile decision, not part of the player-camera mode
  acceptance gate.
- Interaction in vanity mode needs a deliberate policy: usually the ray should
  follow the active camera view while movement remains actor-relative.
- Keyboard vanity now depends on held Tab timing. Human visual validation should
  confirm short Tab does not accidentally enter vanity and held Tab does not
  accidentally toggle primary mode on release.
- Camera interpolation remains the main implementation watchpoint. If human
  visual verification sees shimmer after the follow change, use the documented
  manual `_process()` camera-follow pattern.
- OpenMW's optional `move360` script is a useful warning sign: it intentionally
  makes movement camera-relative in preview mode. That idea must remain out of
  the default Godotwind vanity mode.

## Reviewer Checkpoints

Recommended reviewer engagement points:

- Plan review before runtime code changes.
- Implementation review after the first working camera-mode slice lands.
