# Spec: Player Camera Modes

Date: 2026-05-15
Owner: Codex
Status: Phase 4 started; runtime visual acceptance pending

## Summary

Godotwind needs distinct player camera modes so camera orbit does not silently
change movement controls. The target behavior is OpenMW-inspired but generic:
camera mode decides how view input affects the camera and player facing, while
movement input uses an explicit movement reference chosen by that mode.

## Goals

- Add three player camera modes:
  - first person;
  - third-person fixed follow;
  - third-person vanity/orbit.
- Make fixed follow the normal third-person mode.
- Make vanity/orbit camera movement independent from movement controls.
- Keep movement, camera, interaction ray origin, and swim pitch readable from
  explicit mode state rather than hidden camera-pivot coupling.
- Preserve the existing `CharacterMotor`, `MoveContainer`, and Move-as-Node
  architecture.
- Keep the feature generic. Morrowind/OpenMW informs defaults and behavior, but
  shared code must not depend on Morrowind data formats.

## Non-Goals

- Do not implement OpenMW's optional 360 movement by default.
- Do not rewrite the whole input system or add an autoload.
- Do not replace `SpringArm3D` collision avoidance unless implementation proves
  it cannot satisfy the spec.
- Do not add combat-camera lock-on, shoulder swap, photo mode, or cutscene/static
  camera in this feature.
- Do not change fly-camera debug mode.

## User Stories

As a player in fixed third-person follow, I can press forward and always move
in the direction my character is facing, with the camera fixed behind that
facing direction.

As a player in vanity/orbit mode, I can rotate the camera around the character
for inspection without changing what forward/back/left/right mean.

As a player in first person, I can look around from the character's eye position,
and forward movement follows the character's yaw rather than any detached orbit
camera state.

As a developer or modder, I can understand which camera mode is active and which
movement reference it uses without reading hidden `camera_pivot` assumptions.

## Functional Requirements

- The active camera mode is explicit and queryable.
- `FIRST_PERSON`:
  - camera sits at posture-aware eye height;
  - third-person mesh is hidden as today;
  - yaw input rotates player/character facing;
  - pitch input affects view pitch and first-person aim/swim pitch.
- `THIRD_PERSON` or `THIRD_PERSON_FOLLOW`:
  - camera uses the third-person distance and collision arm;
  - camera stays behind the player-facing direction;
  - yaw input rotates player/character facing, not a free orbit pivot;
  - movement input uses player/character facing.
- `THIRD_PERSON_VANITY`:
  - camera may orbit around the player;
  - yaw/pitch input changes only the camera orbit;
  - movement input uses player/character facing, not the vanity orbit yaw;
  - vanity pitch does not create swim vertical intent;
  - default OpenMW-style auto-vanity exits back to the primary mode when input
    resumes.
- Existing `toggle_camera` behavior remains usable as a tap/hold action:
  short-press Tab toggles first/fixed-third person, while holding Tab enters
  temporary vanity until release. A separate direct `camera_vanity` action may
  remain for gamepad/direct input, but keyboard vanity should follow the held
  Tab contract.
- Mode transitions reset or realign interpolation where a discontinuous camera
  jump is introduced.
- Interaction ray origin continues to follow the active view origin used for
  gameplay interaction.
- Third-person camera collision continues to use Godot's `SpringArm3D`; player
  collider exclusion is required unless a collision-layer audit proves the arm
  cannot hit the player.

## Non-Functional Requirements

- Maintainability: the fix should remove the hidden camera-as-movement-basis
  coupling instead of adding conditionals in every Move.
- Research discipline: the 2026-05-12 research pass has re-verified Godot's
  current camera, `SpringArm3D`, input, and physics interpolation docs and
  surveyed public Godot 4 examples. Future implementation should re-open docs
  only if engine version or camera-rig approach changes.
- Performance: no per-object or per-frame world queries beyond the existing
  camera collision path.
- Modding: camera settings should eventually be resource/config driven, with
  Morrowind-style values provided as one preset.
- Input portability: all new controls use the project `InputMap` contract.
- Runtime validation: human/user visual verification remains required before
  this can be considered shipped.

## Framework Boundary

Generic framework:

- camera mode enum/state;
- mode transition logic;
- visual camera transform and movement-reference transform selection;
- movement input package fields;
- validation scene and docs.

Morrowind/OpenMW adapter or preset:

- OpenMW-like default distances, idle vanity delay, and optional Morrowind
  camera settings if/when exposed to content packs.

Shared framework code must not reference:

- ESM/GMST records directly;
- OpenMW class names;
- Morrowind coordinate conventions.

## Acceptance Criteria

- Rotating the vanity camera 180 degrees around the player and pressing forward
  still moves the character forward relative to character facing.
- In fixed third-person follow, moving mouse/controller yaw rotates the player
  facing and camera together; the camera does not remain in front of the player.
- In first person, forward movement follows player yaw and pitch does not rotate
  the body around world X.
- Entering and exiting crouch still lowers/restores camera eye height and
  interaction ray origin.
- Swimming in vanity mode does not use vanity camera pitch as vertical swim
  intent.
- Existing ground movement, sprint, jump, crouch, first/third-person toggle,
  and water movement still work in the focused character-controller visual
  scene.
- `PlayerInputGatherer` no longer reads `camera_pivot.rotation.y` as movement
  truth. It receives an explicit movement basis or provider.
- The implementation uses or deliberately rejects Godot's documented camera
  interpolation pattern after a focused visual check. Phase 1 may keep the
  existing interpolation-off pivot; visual shimmer requires the manual
  `_process()` camera-follow pattern from the plan.
- The implementation plan records that Godot's current SpringArm/camera docs
  and public Godot camera examples were reviewed before code lands.

## Open Questions

- Should explicit vanity be a toggle, a hold action, or only the OpenMW-style
  idle auto-vanity? Decision update: keyboard uses OpenMW-style held Tab.
  Short Tab toggles first/fixed-third person, held Tab enters temporary
  third-person vanity, and release returns to the primary mode. Keep idle
  auto-vanity as later policy, and do not turn Tab into a three-way cycle.
- Should the enum keep the current `THIRD_PERSON` name as fixed follow, or add
  `THIRD_PERSON_FOLLOW` and preserve `THIRD_PERSON` as a compatibility alias?
  Recommendation: keep `THIRD_PERSON` as fixed follow in code for compatibility,
  document it as fixed follow, and add `THIRD_PERSON_VANITY`.
- Should actor facing live on `PlayerController` or continue to live on
  `character_root`? Recommendation: do the smallest safe implementation first:
  derive movement basis from the current facing node, then consider moving yaw
  ownership to `PlayerController` in a later movement-feel cleanup.
- Which public Godot third-person camera systems are close enough to learn from?
  Answer from 2026-05-12 research: GDQuest and Selgesel are useful warnings
  because they intentionally use camera-relative movement; JeanKouss is useful
  as a camera-component boundary example. None should be copied wholesale.
- Should interaction rays follow the active camera in vanity while movement
  remains actor-relative? Recommendation: yes by default, but write this down
  before implementation because it is a deliberate split, not an accident.

## Decision Log

| Date | Decision | Reason |
| --- | --- | --- |
| 2026-05-12 | Use OpenMW as behavioral reference, not architecture mandate. | Godotwind is generic; OpenMW's source proves the movement/camera split but not the exact Godot implementation. |
| 2026-05-12 | Split visual camera basis from movement basis. | This directly fixes the reported control inversion without patching individual moves. |
| 2026-05-12 | Do not copy OpenMW `move360` as default. | The user explicitly wants vanity camera position not to affect movement controls. |
| 2026-05-12 | Prefer a hold-to-orbit vanity action over a three-way camera toggle. | Holding is easier to reason about and avoids sticky accidental vanity state during movement. |
| 2026-05-13 | Use OpenMW-style held Tab for keyboard vanity. | Short Tab still toggles first/fixed-third person, while held Tab temporarily enters third-person vanity and returns on release. |
| 2026-05-13 | Do not block Phase 2 on diagonal animation clips. | The local OpenMW movement-animation audit shows OpenMW selects cardinal movement groups and uses turn-to-movement-direction body/root yaw for diagonal-looking travel. |
| 2026-05-15 | Treat `reports/report_220/results.xml` as the current automated baseline. | Human-run gdUnit passed 71 tests with 0 failures, 0 errors, and 0 skipped, including the Phase 2 directional animation coverage and Phase 3 held-Tab/vanity coverage. |
| 2026-05-15 | Accept Phase 2/3 and begin Phase 4 next. | Human/user visual gameplay testing reported fixed third-person follow and held-Tab vanity work well in game. |
| 2026-05-15 | Begin Phase 4 with a static first-person/swim audit, then require human visual acceptance. | Existing code already preserves the explicit movement basis/pitch split for first-person, crouch ray-origin posture, and vanity swim-pitch isolation; Codex cannot run the required Godot visual pass. |
| 2026-05-15 | Scope Phase 4 swim acceptance to surface-level behavior. | The current player cannot intentionally swim below the water surface; below-surface swimming is tracked separately in `spec-driven/features/subsurface-swimming/` with OpenMW swim research anchors. |
