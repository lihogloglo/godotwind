# Spec: Character Controller Productionization

Date: 2026-05-10
Owner: Codex
Status: draft plan package

## Purpose

Turn the current player character controller from a promising validation-scene prototype into a production-ready Godotwind framework system.

Production-ready means:

- movement works without animation being required;
- movement tuning has one data-driven source of truth;
- Morrowind-compatible behavior lives in a preset/adapter layer;
- input, posture, camera, interaction, carry, water, and interior transitions agree on the same state;
- every phase has tests and a human-run scene or checklist, because Codex
  cannot reliably launch Godot in this workspace.

## User Stories

- As a player, I can toggle into player mode in the main scene and move, jump, crouch, swim, interact, and carry without getting stuck in a broken camera/body mode.
- As a developer, I can change movement tuning in one `Resource` and know the actual move nodes use it.
- As a mod creator, I can provide a movement profile or override tuning without editing generic controller code.
- As an animation developer, I can read semantic movement state from the controller instead of needing animation to own movement.
- As a tester, I can run focused unit tests and then visually verify each phase
  in a small scene or the main scene. Codex provides commands/checklists, but
  the human/user performs Godot-side execution.

## Success Criteria

- Known baseline defects from `tests/unit/test_character_controller_phase0_baseline.gd` are either fixed or intentionally reclassified with updated tests.
- `PlayerController` can move a `CharacterBody3D` when no `CharacterAnimationSystem` is present.
- `CharacterMovementConfig` controls speeds, jump, crouch, swim, turn policy, backward movement, step values, explicit coyote time, jump buffering, and Morrowind compatibility toggles.
- Generic files under `src/core/character/controller/` no longer hard-code Morrowind behavior.
- Crouch posture changes collision height, camera eye height, interaction ray origin, and animation posture from the same state.
- Carry collision masks still exclude the player after interior layer rewrites.
- Main-scene player mode has a repeatable manual smoke pass covering streaming, interaction, carry, interiors, and water.

## Functional Requirements

- Movement remains based on Godot `CharacterBody3D` and `move_and_slide()`.
- `MoveContainer` remains the state-machine orchestrator unless implementation proves a smaller standard Godot pattern should replace it.
- `PlayerInputGatherer` receives environment context before it creates the input package.
- `MovementState` or equivalent per-frame snapshot becomes the public read model for animation, camera, gameplay, debug UI, and mod scripts.
- Walk remains unbound by default unless a later spec explicitly changes the input-system contract.
- Player-mode attachment failure must abort the mode switch and explain the failure through `Log`.

## Non-Functional Requirements

- Keep each phase self-contained: after a phase lands, the project should be in a working and testable state without waiting for a later phase.
- Keep changes surgical inside each phase.
- Use GDScript for the near-term controller refactor because this is existing Godot-node orchestration; reconsider C# only for proven hot data-processing paths.
- Avoid new autoloads.
- Preserve strict typing in `src/core/`.
- Do not introduce Morrowind data formats or coordinate conventions into generic controller files.

## Modding Requirements

- Movement tuning must be expressed as resources or data that can be replaced by content packs.
- The Morrowind preset/adapter may read Morrowind/OpenMW-informed settings, but generic move code must depend only on framework names.
- Override behavior must be documented: default config, game preset, character-specific override, temporary gameplay modifiers.

## Out Of Scope

- Combat moves, stagger, hit reactions, climbing, and flying.
- Full input remap UI.
- Full Morrowind movement formula parity from stats, fatigue, encumbrance, race weight, and magic effects.
- Replacing the animation stack itself.
- Replacing the interaction/carry architecture.

## Acceptance Tests

- Unit: human/user runs controller baseline tests updated phase by phase.
- Unit: human/user runs tests proving config values affect move selection and movement speeds.
- Unit: human/user runs tests proving movement can process without animation.
- Unit or integration: human/user runs tests proving water context reaches input gatherer before vertical swim intent is computed.
- Unit or integration: human/user runs checks proving crouch stand-up clearance uses a capsule/shape check.
- Visual: human/user opens `tests/visual/test_character_controller.tscn` and confirms it reflects the current input contract and production collision layers.
- Visual: human/user opens a posture/crouch scene and confirms camera/raycast/capsule alignment.
- Manual main-scene smoke: human/user opens `scenes/Godotwind.tscn` and confirms player mode works with streaming, carry, interiors, and water.

## Open Questions / Resolved Decisions

- Should `CharacterMotor` be a new node, or should `PlayerController` own `MoveContainer` directly in the first ownership phase?
- Should movement config live in `src/core/character/controller/` or a higher-level `src/core/character/` folder?
- Coyote time should be enabled by default at `0.10s`, with `jump_buffer_time`
  enabled at `0.12s`. The Morrowind-informed preset tunes these lower.
- Should the Morrowind movement preset be a plain resource or a small adapter that can compute a resource from actor stats later?
