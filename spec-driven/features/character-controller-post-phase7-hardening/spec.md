# Spec: Character Controller Post-Phase 7 Hardening

Date: 2026-05-10
Owner: Codex
Status: draft implementation plan package

## Summary

Harden the character-controller and interaction contracts after Phase 7.

Phase 7 fixed the core ownership problem: movement is now owned by the
controller/motor path and animation observes movement state. This feature turns
the remaining audit findings into a staged repair plan so the controller can
move from "architecturally corrected" to "less likely to drift or surprise the
next implementer."

## Goals

- Make fly-camera interaction a documented active input context instead of an
  undocumented duplicate reader.
- Share tap/hold/release interaction intent semantics between player mode and
  fly/debug mode.
- Make teleport helpers reset physics interpolation after discontinuous writes.
- Make carry release cleanup restore a valid rigid body even if its pickup
  wrapper was freed first.
- Make carry-mode prompt behavior match the interaction-system contract.
- Make exported movement config fields either enforced or explicitly reserved.
- Move the main character-controller visual test off raw keycode hotkeys.
- Reconcile `docs/STATUS.md` and stale comments with the current post-Phase 7
  architecture.
- Clarify movement-state jump semantics before future gameplay relies on them.

## Non-Goals

- Do not replace the Phase 7 ownership model.
- Do not rewrite fly camera into Source-style noclip unless the user explicitly
  chooses that larger architecture later.
- Do not introduce a new autoload or broad runtime input framework.
- Do not add combat, inventory UI, container UI, or complete interior/carry
  content paths.
- Do not change Morrowind formulas or actor-stat movement parity.
- Do not broaden the visual-test raw-keycode cleanup beyond
  `tests/visual/test_character_controller.gd` in this feature.

## Users and Workflows

### User Story: Main-Scene Tester

As a tester, I can switch between fly camera and player mode, use interaction
in the active mode, and trust that only the active mode interprets the
`interact` action.

Acceptance criteria:

- Docs name the active owner for `interact` in player mode and fly mode.
- Player-mode and fly-mode tap/hold/release behavior comes from one shared
  helper or contract.
- Switching modes does not allow both contexts to activate the same target.

### User Story: Mod Creator

As a mod creator, I can inspect `CharacterMovementConfig` and tell which fields
actually change behavior.

Acceptance criteria:

- Each exported config field is enforced by runtime code or marked
  reserved/future-only in resource/docs/tests.
- Presets do not imply that a reserved field is active behavior.

### User Story: Gameplay Developer

As a developer, I can use teleport helpers, carry cleanup, and movement state
without knowing hidden exceptions.

Acceptance criteria:

- `PlayerController.teleport_to()` resets physics interpolation after moving.
- Direct interior transition transform writes also reset interpolation.
- `CarryController.release()` restores valid rigid bodies even if the pickup
  wrapper has already been detached or freed.
- Public jumping/airborne state names and comments mean what the code publishes.

### User Story: UI Tester

As a tester, I do not see an interaction prompt for actions that will be ignored
while carrying.

Acceptance criteria:

- While a carry controller is holding a body, prompt UI hides or suppresses
  prompt updates for that active context.
- Tap interaction remains ignored while carrying.

### User Story: Test Scene Maintainer

As a maintainer, I can run the main character-controller visual scene on
different keyboard layouts because scene-specific hotkeys are `InputMap`
actions, not raw keycodes.

Acceptance criteria:

- NPC preset selection, HUD toggle, and debug dump in
  `tests/visual/test_character_controller.gd` use namespaced visual-test
  actions.
- `InputActions.verify()` or a focused test protects those actions.

## Functional Requirements

- There is exactly one active owner of `interact` at a time.
- `PlayerGameplayContext` means `PlayerController` owns raw `interact`.
- `FlyCameraContext` means `world_explorer.gd` owns fly/debug interaction.
- Tap/hold/release thresholds are centralized or derived from one helper so
  player and fly modes cannot drift.
- Teleport helpers call `Node3D.reset_physics_interpolation()` after position or
  transform discontinuities.
- Carry release cleanup is body-driven, not pickup-wrapper-driven.
- Prompt suppression is implemented without making `InteractionRaycaster`
  depend on a concrete `CarryController` type.
- Movement config fields are reviewed field by field:
  - enforced now,
  - removed from active presets, or
  - documented as reserved/future-only.
- Stale path comments should point to `docs/systems/*` rather than old
  root-level doc names or `.claude` paths.

## Non-Functional Requirements

- Maintainability: prefer small helpers and clear mode/context names over a new
  input framework.
- Performance: no new per-frame expensive queries beyond existing input checks;
  prompt suppression should be a cheap boolean or callable check.
- Compatibility: preserve current player/fly mode switching behavior unless a
  task explicitly changes it.
- Editor usability: visual-test actions should remain obvious and documented in
  `project.godot` / `InputActions`.
- Modding/extensibility: movement config resources must not expose silent
  behavioral no-ops as if they are supported tuning.

## Framework Boundary

Generic framework responsibilities:

- Input context ownership contract.
- Interaction intent tap/hold/release helper.
- Carry release cleanup and prompt-gating contract.
- Movement config field enforcement/reservation.
- Teleport interpolation reset helper behavior.

Game-specific adapter responsibilities:

- Morrowind prompt text, door/container/activator adapters, and any future
  movement preset values derived from Morrowind/OpenMW data.

Shared code must not depend on:

- ESM, NIF, SCVR, Morrowind coordinates, OpenMW naming, or Morrowind-only
  movement formulas.

## Modding and Content Extension

Mods should be able to:

- Replace movement config presets and see supported fields affect behavior.
- Rely on carry/interact semantics independent of Morrowind content adapters.
- Use future content-specific interaction adapters without changing generic
  input or raycast code.

Extension points:

- `CharacterMovementConfig` resources.
- `Interactable` subclasses.
- Carryable registry/factory.
- Existing `InputMap` action definitions.

Override rules:

- Movement config override order remains:
  1. framework default config,
  2. game preset such as Morrowind,
  3. character-specific override,
  4. temporary runtime modifiers in a future gameplay-effects layer.

Shared systems must not hard-code:

- Bundled Morrowind content names.
- Morrowind-only prompt wording in framework files.
- One-off fly-camera exceptions that are not named as an input context.

## Acceptance Tests

- Unit: interaction-intent helper emits tap, hold begin, and hold-release
  outcomes using the configured hold threshold.
- Unit or focused integration: active input context docs/code prevent player
  and fly contexts from both processing `interact` at once.
- Unit: `PlayerController.teleport_to()` calls or results in interpolation
  reset after moving.
- Unit: interior transition path resets interpolation on moved player/camera
  nodes.
- Unit: public `CarryController.release()` restores a valid held body even when
  the pickup wrapper is invalid.
- Unit or integration: prompt suppression hides prompt output while the active
  carry controller is carrying.
- Unit: each shipping movement config field changed in this feature has a
  behavior contract.
- Static or unit: reserved movement config fields are documented and presets do
  not imply they are active behavior.
- Unit/static: `tests/visual/test_character_controller.gd` no longer uses raw
  keycodes for its scene-specific debug/preset controls.
- Docs: `docs/STATUS.md`, `docs/systems/input_system.md`,
  `docs/systems/interaction_system.md`, and stale code comments match current
  architecture.

## Open Questions

- Should `InteractionRaycaster` own prompt suppression through a generic
  callable, or should prompt UI callbacks suppress based on active carry state?
- Should the public movement state split `is_jumping` into `is_airborne` and
  `is_jump_move`, or is a docs/comment clarification enough for this milestone?

## Decision Log

| Date | Decision | Reason |
| --- | --- | --- |
| 2026-05-10 | Use explicit active input contexts over Source-style noclip rewrite. | Fits current fly/player architecture with the smallest canonical repair. |
| 2026-05-10 | Keep this feature scoped to hardening/docs/tests, not a full interaction rewrite. | The Phase 7 ownership model is sound; audit findings are contract drift and small correctness gaps. |
| 2026-05-10 | Runtime/editor validation remains human-run. | Codex cannot reliably launch Godot in this workspace per project rule. |
| 2026-05-12 | Mark `smooth_movement` and `smooth_player_turning_delay` reserved. | Movement smoothing needs a future feel/animation/camera spec; inventing semantics here would make mod-facing behavior misleading. |
| 2026-05-12 | Mark `swim_upward_correction_enabled` and `swim_upward_coef` reserved. | Current swimming already uses camera-relative pitch, buoyancy, surface clamp, and swim-stroke impulse fields; the old upward-correction names no longer describe the active model. |
| 2026-05-12 | Implement `turn_to_movement_direction`, `step_down_height`, and `min_step_height`. | These map cleanly onto existing turn tracking and step-solver decisions without a broader movement rewrite. |
