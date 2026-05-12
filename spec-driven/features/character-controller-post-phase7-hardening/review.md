# Review: Character Controller Post-Phase 7 Hardening

## Review Date

2026-05-10

## Scope Reviewed

Initial plan package plus Phase 1 and Phase 2 implementation:

- `docs/audit/character_controller_post_phase7_audit_2026_05_10_codex.md`
- `spec-driven/README.md`
- `spec-driven/00-constitution.md`
- `spec-driven/01-workflow.md`
- `spec-driven/features/character-controller-productionization/*`
- this feature folder
- `src/core/interaction/interaction_intent.gd`
- `src/core/player/player_controller.gd`
- `src/tools/world_explorer.gd`
- `src/core/input/input_actions.gd`
- `src/core/interaction/interaction_raycaster.gd`
- `src/core/interaction/carry_controller.gd`
- `src/core/player/fly_camera.gd`
- `src/core/world/interior_pocket_manager.gd`
- `tests/unit/test_player_controller_interaction.gd`
- `tests/unit/test_character_controller_phase0_baseline.gd`
- `tests/visual/test_carry_prompt_suppression.tscn`
- `tests/visual/test_carry_prompt_suppression.gd`
- `tests/visual/test_teleport_interpolation_reset.tscn`
- `tests/visual/test_teleport_interpolation_reset.gd`
- `docs/systems/input_system.md`
- `docs/systems/interaction_system.md`
- `docs/systems/character_controller.md`

Phase 1 and Phase 2 have been implemented. Godot-side validation for Phase 2
is still pending because Codex cannot reliably launch the engine in this
workspace. Two focused Phase 2 visual validation scenes now exist so the
human/user can check prompt suppression and teleport interpolation directly.

## Findings

### Blocking

- Runtime/editor validation is pending. Codex cannot reliably launch Godot in
  this workspace, so human/user Godot-side checks are required before any
  implementation phase is called verified.

### Important

- The highest-risk implementation decision is the active input-context repair.
  The plan selects explicit player/fly contexts over a broader Source-style
  noclip rewrite because it fits current architecture and avoids a speculative
  refactor.
- Movement config field repairs need field-by-field decisions before code
  changes. Do not invent behavior for ambiguous fields merely to avoid saying
  "reserved."
- Prompt suppression should avoid coupling `InteractionRaycaster` to a concrete
  `CarryController` type.

### Minor

- The local workspace path did not present as a Git checkout to the shell, so
  Git status could not be used as a guardrail during this planning pass.

## Spec Compliance

| Acceptance Criterion | Status | Notes |
| --- | --- | --- |
| Feature folder exists | Pass | Plan package created under `spec-driven/features/character-controller-post-phase7-hardening/`. |
| Audit migrated into workable chunks | Pass | Plan phases map to P1/P2/P3 findings and docs cleanup. |
| Runtime code changed | Pass | Phase 1 added `InteractionIntent`; Phase 2 added teleport resets, body-driven carry release, and prompt suppression. |
| Active input contexts documented | Pass | `PlayerGameplayContext` and `FlyCameraContext` are documented in input/interaction docs. |
| Human/user runtime validation | Pending | Required after implementation phases. |

## Architecture Compliance

- Generic framework boundary preserved: Yes; `InteractionIntent` is a generic
  helper with no Morrowind imports, scene-tree dependency, or autoload.
- Game-specific adapter boundary preserved: Yes.
- OpenMW-informed behavior isolated to adapter/configuration layers where
  appropriate: Yes; OpenMW is used only as camera/input reference.
- Modding and content-extension boundaries preserved: Yes; config truthfulness
  is a core requirement.
- Godot-native features preferred where practical: Yes; plan keeps Godot
  `InputMap`, `Node3D.reset_physics_interpolation()`, and existing nodes.
- Bespoke systems justified: Yes; the interaction-intent helper is intentionally
  small and exists to prevent duplicated tap/hold logic between active contexts.
- Comments explain non-obvious intent without restating obvious code: Yes for
  Phase 1 active-context and shared-intent boundaries.
- Feature and architecture docs updated for behavior, data flow, and boundary
  changes: Yes for Phase 1 and Phase 2; later phases still pending.

## Validation Results

- Automated: human/user ran gdUnit and produced
  `reports/report_208/results.xml`. The focused Phase 1 suite
  `test_player_controller_interaction` passed: 18 tests, 0 failures, 0 errors.
  The suite includes coverage for tap, threshold hold-begin, hold release,
  missing press, cancel, and long-release fallback.
- Full-run note: `report_208` contains 241 total tests with 6 failures in
  unrelated rendering/object-paging suites (`test_material_audit`,
  `test_object_paging_kernel`, and `test_static_object_renderer_bwide`).
  These match the known non-controller failure area from earlier reports and
  are not attributed to Phase 1 interaction changes.
- Static: Codex checked that duplicate player/fly press timestamp and hold flag
  state were removed, and fly interaction remains gated on
  `_camera_mode == CameraMode.FLY_CAMERA`.
- Phase 2 static: Codex checked direct Phase 2 teleport sites now call
  `reset_physics_interpolation()` through `PlayerController.teleport_to()`,
  `FlyCamera.teleport_to()`, or direct transition resets in
  `InteriorPocketManager`.
- Phase 2 targeted automated validation: human/user ran the character
  controller gdUnit scene and produced `reports/report_210/results.xml`.
  `test_character_controller_phase0_baseline` passed: 42 tests, 0 failures,
  0 errors. The report includes the new player teleport reset, fly-camera
  teleport reset, and missing-wrapper/valid-body carry release contracts.
- Phase 2 prompt suppression coverage was added to
  `test_player_controller_interaction`; it still needs a human/user run of
  that focused suite or the full test runner.
- Phase 2 visual surfaces added:
  - `tests/visual/test_carry_prompt_suppression.tscn`
  - `tests/visual/test_teleport_interpolation_reset.tscn`
- Phase 2 scene-surface contracts were added to
  `tests/unit/test_character_controller_phase0_baseline.gd`; they still need
  a human/user gdUnit run.
- Phase 2 scene-surface automated validation: human/user ran the character
  controller gdUnit scene and produced `reports/report_211/results.xml`.
  `test_character_controller_phase0_baseline` passed: 44 tests, 0 failures,
  0 errors. The two new scene-surface contracts passed:
  `test_phase2_carry_prompt_visual_scene_exposes_required_cases` and
  `test_phase2_teleport_visual_scene_exposes_required_cases_and_actions`.
- Phase 2 carry prompt visual validation: human/user ran
  `tests/visual/test_carry_prompt_suppression.tscn` and reported the
  suppression test works. The two carryable cubes can be held, prompts hide
  while carrying, and the non-carry activator remains a tap-only target.
- Phase 2 teleport visual fixture note: human/user reported the right-lane
  direct-write probes read as appearing/disappearing instead of jumping back
  and forth. Codex adjusted the fixture by switching the overview camera to
  orthographic framing and moving the pink camera marker onto the right lane
  beside the purple capsule. Re-run visual validation is pending.
- Follow-up fixture correction: human/user then reported the pads and probes
  were no longer visible. Codex reverted to an angled perspective overview,
  enlarged/raised the pads, enlarged the camera markers, and made the scene
  materials unshaded so the validation objects should remain visible in the
  test lighting.
- Follow-up startup correction: if Godot was already open before the
  `project.godot` input-action edit, the live editor `InputMap` could be
  missing the new optional teleport visual-test actions. The scene now creates
  those optional actions locally before verifying them, while still reading
  input through `InputMap` actions.
- Follow-up blank-scene correction: human/user still reported a blank scene.
  Codex reordered startup so the world, camera, and HUD are created before
  optional probe setup, and removed the root `InputActions.verify()` assertion
  from this visual-only scene so a stale editor `InputMap` cannot pause the
  scene before the validation board is visible. Teleport controls still use
  `InputMap` actions.
- Follow-up camera correction: human/user still reported nothing visible after
  a full Godot restart. Codex made the overview camera explicitly
  `make_current()` after creation and again deferred after all probe cameras
  are added, so helper/probe cameras cannot leave the viewport without the
  validation camera.
- Follow-up fallback correction: user correctly questioned whether the camera
  was aimed at the pads. Codex added a static fallback camera, floor, right-lane
  pads, and right-lane probe markers directly to the `.tscn`. If the script
  starts successfully it hides the fallback board and uses the scripted moving
  probes; if startup fails, the fallback board should still be visible and prove
  the scene/camera itself is rendering.
- Visual: teleport interpolation-reset scene not yet reported.
- User visual spot checks after Phase 1:
  - `tests/visual/test_interaction_phase_I1.tscn`: reported working.
  - `tests/visual/test_interaction_phase_I2.tscn`: reported working.
  - `tests/visual/test_interaction.tscn`: reported working.
  - `tests/visual/test_interaction_phase_I7.tscn`: user reported taps logged
    "no target"; Codex found and patched a scene-fixture issue where the
    Door/Container/Activator adapter was a sibling of the collider instead of
    an ancestor. User reran I7 after the patch and reported it now works.
- Performance: no new physics queries or unbounded loops added.
- Manual: not run.

## Follow-Up Tasks

- [x] Implement Phase 1 active input context and interaction-intent helper.
- [x] Run human/user gdUnit validation after Phase 1.
- [x] Implement Phase 2 teleport reset, carry cleanup, and prompt suppression.
- [x] Run human/user targeted character-controller gdUnit validation after Phase 2.
- [ ] Run human/user interaction prompt-suppression gdUnit validation after Phase 2.
- [x] Run human/user scene-surface gdUnit validation after Phase 2 visual scenes.
- [x] Run human/user carry prompt-suppression visual validation after Phase 2.
- [ ] Run human/user teleport interpolation-reset visual validation after Phase 2.
- [ ] Continue phases in `tasks.md` order.
- [ ] Record actual validation reports in this review file as each phase lands.

## Decision Updates

- 2026-05-10: Selected explicit active input contexts as the implementation
  direction for fly-camera interaction ownership.
- 2026-05-10: Implemented Phase 1 with a small `InteractionIntent` helper
  rather than a broad input-context stack or Source-style noclip rewrite.
- 2026-05-11: Implemented Phase 2 with Godot-native
  `reset_physics_interpolation()` calls after teleports, body-driven carry
  release cleanup, and generic raycaster prompt suppression driven by carry
  signals.
- 2026-05-11: Added two focused Phase 2 visual validation scenes before
  continuing to Phase 3.
