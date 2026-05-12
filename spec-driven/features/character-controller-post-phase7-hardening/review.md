# Review: Character Controller Post-Phase 7 Hardening

## Review Date

2026-05-12

## Scope Reviewed

Initial plan package plus Phase 1, Phase 2, Phase 3, and Phase 4
implementation:

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
- `src/core/character/controller/character_movement_config.gd`
- `src/core/character/controller/move.gd`
- `src/core/character/controller/move_container.gd`
- `src/core/character/controller/moves/run_move.gd`
- `src/core/character/controller/moves/walk_move.gd`
- `src/core/character/controller/moves/sprint_move.gd`
- `src/core/character/controller/moves/crouch_move.gd`
- `src/core/character/controller/moves/swim_move.gd`
- `src/core/character/controller/movement_presets/morrowind_movement_config.tres`
- `docs/systems/input_system.md`
- `docs/systems/interaction_system.md`
- `docs/systems/character_controller.md`
- `tests/visual/test_character_controller.gd`
- `project.godot`
- `docs/STATUS.md`

Phase 1, Phase 2, Phase 3, and Phase 4 have been implemented. Human/user
validation is complete for the targeted character-controller gdUnit scene, the
main character-controller visual scene, and both focused Phase 2 visual scenes.
The `scenes/Godotwind.tscn` main-scene smoke pass is complete for available
content; interaction/carry/interior items are blocked future integration gates
until their main-scene paths exist.

## Findings

### Blocking

- None for the hardening package's available validation surface.
- Main-scene interaction/carry/prompt and teleport/interior checks remain
  blocked until the required `scenes/Godotwind.tscn` elements or content paths
  are implemented. They are future integration gates, not a Phase 8 for this
  package.

### Important

- The highest-risk implementation decision is the active input-context repair.
  The plan selects explicit player/fly contexts over a broader Source-style
  noclip rewrite because it fits current architecture and avoids a speculative
  refactor.
- Movement config field repairs need field-by-field decisions before code
  changes. Phase 3 classified every exported field; ambiguous smoothing and
  legacy swim-upward-correction fields are reserved rather than invented.
- Prompt suppression should avoid coupling `InteractionRaycaster` to a concrete
  `CarryController` type.

### Minor

- Older generated gdUnit report folders remain deleted in the working tree from
  pre-existing local cleanup. They are unrelated to this hardening pass.

## Spec Compliance

| Acceptance Criterion | Status | Notes |
| --- | --- | --- |
| Feature folder exists | Pass | Plan package created under `spec-driven/features/character-controller-post-phase7-hardening/`. |
| Audit migrated into workable chunks | Pass | Plan phases map to P1/P2/P3 findings and docs cleanup. |
| Runtime code changed | Pass | Phase 1 added `InteractionIntent`; Phase 2 added teleport resets, body-driven carry release, and prompt suppression. |
| Active input contexts documented | Pass | `PlayerGameplayContext` and `FlyCameraContext` are documented in input/interaction docs. |
| Movement config fields are honest | Pass | Phase 3 adds an active/reserved status table, implements `turn_to_movement_direction`, `step_down_height`, and `min_step_height`, and removes reserved-field overrides from the Morrowind preset. |
| Visual controller scene uses InputMap actions | Pass | Phase 4 adds `character_controller_preset_1..5`, `character_controller_toggle_debug_hud`, and `character_controller_dump_kf_bones`, removes raw keycode handling from `tests/visual/test_character_controller.gd`, and human/user confirmed the visual scene works. |
| Jump/airborne semantics are clear | Pass | Phase 4 adds `is_jump_move` and `is_airborne`; `is_jumping` remains a documented compatibility alias for jump-family airborne state. |
| Human/user runtime validation | Pass for available content | Targeted gdUnit and visual scenes are green. Main-scene player/fly/movement/streaming/water smoke passed, copied logs show no controller/input/interaction/player/animation/water/swim warnings or errors, and interaction/carry/interior items are blocked future integration gates until those main-scene paths exist. |

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
  changes: Yes through Phase 4.

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
  `test_player_controller_interaction`; a focused run of that separate suite is
  still useful if future interaction changes touch prompt gating, but the
  visual prompt-suppression path passed.
- Phase 2 visual surfaces added:
  - `tests/visual/test_carry_prompt_suppression.tscn`
  - `tests/visual/test_teleport_interpolation_reset.tscn`
- Phase 2 scene-surface contracts were added to
  `tests/unit/test_character_controller_phase0_baseline.gd` and validated in
  `reports/report_211/results.xml`.
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
- Phase 3 implementation: Codex classified every exported
  `CharacterMovementConfig` field through
  `get_exported_field_statuses()`. Runtime-active fields include the existing
  movement, posture, jump, swim, floor, and capability knobs. Reserved fields
  are `smooth_movement`, `smooth_player_turning_delay`,
  `swim_upward_correction_enabled`, and `swim_upward_coef`.
- Phase 3 behavior changes: `turn_to_movement_direction = false` now prevents
  ground and swim moves from auto-rotating the model/player toward input while
  preserving camera-relative movement. `step_down_height` now controls the
  step solver's down probe after a candidate step-up, and `min_step_height`
  rejects tiny upward snaps that should stay normal slide/floor-snap behavior.
- Phase 3 preset cleanup: the Morrowind movement preset no longer sets reserved
  smoothing or swim-upward-correction fields as if they are active behavior.
- Phase 3 static/tests added: the character-controller suite now has contracts
  for exported-field status coverage, reserved-field status, disabled
  auto-turn behavior, and step-down/min-step config behavior.
- Phase 3 targeted automated validation: human/user ran the character
  controller gdUnit scene and produced `reports/report_212/results.xml`.
  `test_character_controller_phase0_baseline` passed: 47 tests, 0 failures,
  0 errors. The report includes the new Phase 3 contracts:
  `test_movement_config_status_table_covers_exported_fields`,
  `test_turn_to_movement_direction_false_prevents_auto_turning`, and
  `test_movement_config_controls_step_down_and_min_step_height`.
- Human/user reported they had already run around the main game and confirmed
  things were working before Phase 3 started. This is recorded as useful
  runtime smoke context. The specific teleport visual-scene validation was
  completed later on 2026-05-12.
- Phase 4 implementation: Codex added character-controller visual-test
  InputMap actions to `project.godot` and `InputActions.VISUAL_TEST`, routed
  `tests/visual/test_character_controller.gd` through those actions, and
  added scene/action static contracts to the character-controller suite.
- Phase 4 state cleanup: `MovementState` now exposes `is_jump_move` for the
  launch move and `is_airborne` for jump/fall state. `is_jumping` remains as a
  compatibility alias and is documented as not meaning upward velocity.
- Phase 4 docs cleanup: `docs/STATUS.md` now reflects current interaction and
  carry main-scene wiring and the HL2/Source-style velocity-drive carry path.
  Stale comments in audited code paths were updated where they described old
  movement ownership.
- Phase 4 static validation: Codex checked
  `tests/visual/test_character_controller.gd` no longer contains raw
  `KEY_1..KEY_5`, `KEY_F1`, `KEY_F2`, or `event.keycode` handling.
- Phase 4 targeted automated validation: human/user ran the character
  controller gdUnit scene and produced `reports/report_213/results.xml`.
  `test_character_controller_phase0_baseline` passed: 50 tests, 0 failures,
  0 errors, 0 skipped. The report includes the Phase 4 contracts:
  `test_phase4_character_controller_visual_actions_are_registered`,
  `test_phase4_character_controller_visual_scene_uses_input_actions_for_debug_controls`,
  and `test_phase4_movement_state_splits_jump_move_from_airborne_state`.
- Phase 4 visual validation: human/user ran
  `tests/visual/test_character_controller.tscn` and confirmed it works after
  the InputMap visual-control migration.
- Phase 5 static cleanup: Codex rechecked `reports/report_213/results.xml`
  and confirmed the targeted character-controller suite still records 50 tests,
  0 failures, 0 errors, and 0 skipped. Codex also confirmed the main
  character-controller visual scene no longer contains raw `KEY_1..KEY_5`,
  `KEY_F1`, `KEY_F2`, or `event.keycode` handling.
- Phase 5 static cleanup: Codex checked the current diff for shader files and
  found no `.glsl`, `.gdshader`, or `.gdshaderinc` changes, so no shader
  cache/import clearing is required for this hardening package.
- Phase 5 static cleanup: the only `project.godot` change in this package is
  the planned visual-test input actions; no new autoload was added.
- Phase 5 static cleanup: no temporary debug code or new Morrowind-specific
  assumptions were found in the hardening-scope framework files. Existing
  debug tooling in `world_explorer.gd`, visual-test HUD/debug controls, and
  Morrowind adapter files remain intentional existing project surfaces.
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
- 2026-05-12 rebuild: the teleport interpolation scene was recreated from
  scratch instead of patching the broken generated/fallback version. The new
  scene file owns the visible board, fixed overview camera, colored pads, and
  probes directly. The script now only reads the existing InputMap visual-test
  actions and calls the three teleport/reset paths. It also temporarily lowers
  physics TPS to 10 during the scene so missing interpolation resets are easier
  for the human/user to spot, then restores the previous value on exit.
- Phase 2 teleport visual validation: human/user ran
  `tests/visual/test_teleport_interpolation_reset.tscn` and confirmed it
  works. The rebuilt scene now counts as interactively verified.
- User visual spot checks after Phase 1:
  - `tests/visual/test_interaction_phase_I1.tscn`: reported working.
  - `tests/visual/test_interaction_phase_I2.tscn`: reported working.
  - `tests/visual/test_interaction.tscn`: reported working.
  - `tests/visual/test_interaction_phase_I7.tscn`: user reported taps logged
    "no target"; Codex found and patched a scene-fixture issue where the
    Door/Container/Activator adapter was a sibling of the collider instead of
    an ancestor. User reran I7 after the patch and reported it now works.
- Performance: no new physics queries or unbounded loops added.
- Main-scene visual smoke: human/user launched `scenes/Godotwind.tscn` and
  reported fly/player switching, movement, sprint, jump, crouch, camera toggle,
  and streaming boundary crossing all work.
- Main-scene deferred checks: available interact/carry paths, prompt
  hide/return while carrying, and teleport/interior streak checks will be
  revisited once those main-scene elements or content paths are implemented.
- Console/log review: human/user copied `crash_breadcrumb.txt`,
  `crash_report.txt`, `debug_report.txt`, and `godot.log` to
  `C:\Users\pc\Desktop\godot logs\`. Codex read them on 2026-05-12.
  `crash_report.txt` says "No errors recorded"; `debug_report.txt` says
  "Errors captured: 0" and "No errors". `godot.log` contains no
  `SCRIPT ERROR`, no `SCRIPT WARNING`, and zero `[WARN]` / `[ERROR]` entries
  for `controller`, `input`, or `interaction`.
- Console/log positive controller path: `godot.log` records
  `Interaction framework wired (raycaster + carry controller)`,
  `MoveContainer: Accepted 9 moves, starting in 'idle'`,
  `Player character attached: fargoth`, and fly/player mode switches.

## Follow-Up Tasks

- [x] Implement Phase 1 active input context and interaction-intent helper.
- [x] Run human/user gdUnit validation after Phase 1.
- [x] Implement Phase 2 teleport reset, carry cleanup, and prompt suppression.
- [x] Run human/user targeted character-controller gdUnit validation after Phase 2.
- [ ] Run human/user interaction prompt-suppression gdUnit validation after Phase 2 if future interaction changes touch prompt gating.
- [x] Run human/user scene-surface gdUnit validation after Phase 2 visual scenes.
- [x] Run human/user carry prompt-suppression visual validation after Phase 2.
- [x] Run human/user teleport interpolation-reset visual validation after Phase 2.
- [x] Implement Phase 3 movement config truthfulness.
- [x] Run human/user character-controller gdUnit validation after Phase 3.
- [x] Implement Phase 4 visual-test input actions and state/docs cleanup.
- [x] Run human/user character-controller gdUnit validation after Phase 4.
- [x] Run human/user `tests/visual/test_character_controller.tscn` validation after Phase 4.
- [x] Complete `scenes/Godotwind.tscn` main-scene smoke for available content; interaction/carry/interior items are blocked future integration gates until those main-scene paths exist.
- [x] Record actual validation reports in this review file as each phase lands.
- [x] Begin Phase 6 from this verified baseline.
- [x] Close this hardening package as complete for available content; no
  Phase 8 is defined.

Phase 6 start note:

- Started the next implementation slice without reopening Phases 1-5. The
  first change is a practical automated step-solver fixture in
  `tests/unit/test_character_controller_phase0_baseline.gd` that checks broad
  category outcomes for the existing canonical up/forward/down probe solver.
  No solver tuning, active-context rewrite, teleport changes, movement config
  changes, or visual-scene recreation were made.
- Human/user ran the focused suite and produced `reports/report_214/results.xml`:
  51 tests, 1 failure, 0 errors. The failure was in the new Phase 6 scripted
  fixture, where the tall-wall case incorrectly treated forward contact travel
  as a failed block. The solver did not climb; the fixture was corrected to
  assert the no-climb contract.
- Human/user reran the focused suite and produced `reports/report_215/results.xml`:
  51 tests, 0 failures, 0 errors, 0 skipped. The rerun includes the corrected
  `test_phase6_step_solver_scripted_fixture_categories` contract.
- Phase 7 main-scene smoke follow-up is recorded: fly/player switch, movement,
  sprint, jump, crouch, camera toggle, streaming boundaries, and water all
  work. Interaction/carry/interior remain blocked by missing dependent
  main-scene content paths, not failed.
- Updated log review passed for the controller scope: `crash_report.txt` says
  "No errors recorded"; `debug_report.txt` says "Errors captured: 0" and "No
  errors"; `godot.log` has zero `SCRIPT ERROR` / `SCRIPT WARNING` entries and
  zero controller/input/interaction/player/animation/water/swim warnings or
  errors. The remaining warnings are unrelated streaming/autopsy, missing
  static collision sidecar, and shutdown resource-leak warnings.

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
- 2026-05-12: Implemented Phase 3 by making obvious config fields active and
  marking ambiguous fields reserved. `smooth_movement` /
  `smooth_player_turning_delay` need a future movement-feel spec before they
  become runtime behavior. `swim_upward_correction_enabled` / `swim_upward_coef`
  are reserved because current swimming is already governed by camera-relative
  pitch, buoyancy, surface clamp, and swim-stroke impulse fields.
- 2026-05-12: Implemented Phase 4 by moving the main character-controller
  visual scene's debug/preset controls onto `InputMap` actions, splitting
  airborne/jump-move state semantics, and reconciling stale interaction/carry
  status docs.
