# Next Audit Brief: Character Controller Post-Phase-7 Code Audit

Date: 2026-05-10
Owner: Next Codex session / human reviewer
Status: audit brief for a future read-only review

## Purpose

Run a fresh code audit of the character controller after phases 0-7 of
`character-controller-productionization`.

This audit is not a feature implementation pass. It should review whether the
current controller code is clean, comprehensible, well documented, and aligned
with Godot and industry-standard character-controller patterns after the
productionization work.

The prior audit found ownership and data-flow problems. Phases 0-7 repaired the
major known issues and completed a partial main-scene smoke. The next audit
should answer: did the repair leave behind a controller stack that a senior
Godot/gameplay engineer would be comfortable maintaining?

## Required Reading

Read these first, in order:

1. `AGENTS.md`
2. `spec-driven/README.md`
3. `spec-driven/00-constitution.md`
4. `spec-driven/01-workflow.md`
5. `docs/audit/character_controller_code_audit_2026_05_09_codex.md`
6. `spec-driven/features/character-controller-productionization/research.md`
7. `spec-driven/features/character-controller-productionization/spec.md`
8. `spec-driven/features/character-controller-productionization/plan.md`
9. `spec-driven/features/character-controller-productionization/tasks.md`
10. `spec-driven/features/character-controller-productionization/validation.md`
11. `spec-driven/features/character-controller-productionization/review.md`
12. `docs/systems/character_controller.md`
13. `docs/systems/interaction_system.md`
14. `docs/systems/input_system.md`
15. `docs/STATUS.md`

Use any other relevant spec-driven or system docs discovered during the audit.
If a code path touches streaming, interiors, interaction, input, animation, or
physics layers, read the corresponding live system doc before judging the code.

## Audit Output

Write the audit to:

```text
docs/audit/character_controller_post_phase7_audit_2026_05_10_<agent>.md
```

Use a review-first format:

- Executive summary
- Findings ordered by severity
- Open questions / assumptions
- Positive findings worth preserving
- Suggested next repair plan, if needed
- Validation status and what remains human-only

Findings should include file paths and line references. Separate confirmed bugs
from maintainability concerns, stale docs/comments, blocked dependent systems,
and out-of-scope adjacent-system warnings.

## Audit Scope

Inspect the character-controller stack and the components touched or depended
on during phases 0-7.

### Core Controller

- `src/core/player/player_controller.gd`
- `src/core/character/character_motor.gd`
- `src/core/character/controller/move_container.gd`
- `src/core/character/controller/move.gd`
- `src/core/character/controller/input_package.gd`
- `src/core/character/controller/player_input_gatherer.gd`
- `src/core/character/controller/movement_state.gd`
- `src/core/character/controller/character_movement_config.gd`
- `src/core/character/controller/movement_presets/*.tres`
- `src/core/character/controller/moves/*.gd`

### Animation Boundary

- `src/core/animation/character_animation_system.gd`
- `src/core/animation/animation_manager.gd`
- any character factory code that wires `PlayerController`, `CharacterMotor`,
  animation systems, or movement config.

### Main Scene Integration

- `src/tools/world_explorer.gd`
- `scenes/Godotwind.tscn`
- any player-mode setup, attachment, camera toggle, or failure fallback paths.

### Interaction, Carry, And Physics Layers

- `src/core/interaction/interaction_raycaster.gd`
- `src/core/interaction/carry_controller.gd`
- `src/core/interaction/carryable_body_factory.gd`
- `src/core/physics/gameplay_physics_layers.gd`
- `src/core/world/interior_pocket_manager.gd`
- any player/carry/interior layer handoff touched by Phase 5.

### Input And Test Scenes

- `src/core/input/input_actions.gd`
- `project.godot` input actions
- `tests/unit/test_character_controller_phase0_baseline.gd`
- `tests/visual/test_character_controller.tscn`
- `tests/visual/test_character_controller.gd`
- `tests/visual/test_character_controller_steps.tscn`
- `tests/visual/test_character_controller_steps.gd`
- `tests/run_character_controller_phase0.tscn`

### Documentation

- `docs/systems/character_controller.md`
- `docs/systems/interaction_system.md`
- `docs/systems/input_system.md`
- `docs/STATUS.md`
- all files in
  `spec-driven/features/character-controller-productionization/`

## Review Questions

### Architecture And Ownership

- Does movement still work without animation ownership?
- Is `CharacterMotor` the clear owner of input gathering, `MoveContainer`, and
  `MovementState`?
- Does animation observe movement state without driving movement?
- Are player, motor, move container, animation, interaction, carry, and world
  integration responsibilities easy to explain?
- Are there compatibility bridges, duplicated ownership paths, or stale public
  exports that should now be removed or documented as temporary?

### Godot And Industry Patterns

- Does the controller use `CharacterBody3D` and `move_and_slide()` in a
  Godot-native way?
- Is physics work driven by `_physics_process()` delta instead of wall-clock
  time?
- Are teleports/respawns/interpolation resets used only where Godot expects
  them, and are deprecated APIs avoided in production code?
- Does the step solver follow the canonical up/forward/down probe model without
  unbounded casts or bespoke per-frame scene queries?
- Are RigidBody carry interactions still using the canonical velocity-drive
  pattern, not a reintroduced transform-write bridge?
- Are deferred mutations used where Godot physics lifecycle rules require them?

### Clean Code And Comprehensibility

- Can a new maintainer understand the movement flow from `PlayerController` to
  `CharacterMotor` to `MoveContainer` to `MovementState` without reading every
  move script?
- Are names boring and clear?
- Are functions small enough to reason about?
- Are comments explaining why, not repeating what?
- Are old comments from pre-productionization phases now stale or misleading?
- Are docs and comments still synchronized with the actual code?
- Are there hidden dependencies that should be explicit fields, resources, or
  setup contracts?

### Data-Driven And Modding Boundaries

- Is `CharacterMovementConfig` the real source of movement tuning?
- Are config override rules clear and actually followed?
- Are Morrowind-specific values isolated to presets/adapters rather than
  generic controller code?
- Could another game plug in a different movement preset/adapter without
  editing core movement files?
- Are capability flags, posture values, swim tuning, jump grace, and step values
  moddable where the spec says they should be?
- Do current design decisions leave room for future modding capabilities such
  as custom movement profiles, total-conversion game presets, actor-specific
  movement rules, magic/status-effect modifiers, custom posture types, alternate
  swim/jump tuning, and content-pack overrides without editing generic
  controller code?
- Are extension points documented well enough that a mod author or future game
  adapter can tell what is safe to override, replace, or disable?

### Input Contract

- Do runtime code and visual test scenes use `InputMap` actions rather than raw
  key loops?
- Is `walk` still intentionally unbound unless a later spec changed it?
- Do HUD/help labels match `project.godot` and `docs/systems/input_system.md`?
- Is `PlayerController` still the single raw owner of the `interact` action?

### Movement State And Public API

- Is `MovementState` complete enough for animation, camera, gameplay, debug UI,
  and future mod scripts?
- Are `PlayerController` public movement fields synchronized with
  `MovementState`, or are they stale compatibility mirrors?
- Are crouch/swim/jump/grounded/posture states represented once, or duplicated
  across systems?
- Does posture consistently drive collision height, camera height, interaction
  ray origin, and animation state?

### Water, Jump, And Step Behavior

- Is swim entry/re-entry state understandable and covered by tests?
- Does the swim surface clamp read as a general controller rule rather than a
  one-off patch?
- Are coyote time and jump buffering explicit, deterministic, and configurable?
- Is the ground-to-midair lockout still only a bounce/contact guard?
- Does the step solver remain simple and bounded after Phase 6 validation?

### Interaction, Carry, And Interior Layer Contract

- Is `GameplayPhysicsLayers` small, framework-oriented, and not an autoload?
- Do carry masks exclude the player's current collision-layer bits while held
  and restore the exact saved mask on release?
- Are carry/interior layer rewrites centralized enough that future changes will
  not silently desynchronize player, carryable, interactable, and interior slot
  layers?
- Are blocked carry/interior smoke checks documented as blocked, not failed?

### Tests And Validation

- Do the unit tests describe behavior, not implementation trivia?
- Are tests named clearly enough to act as documentation?
- Do visual scenes use production layer meanings and unified input actions?
- Does Phase 6's step scene remain a measuring rig, not a hidden gameplay
  dependency?
- Are the latest validation results in `review.md` and
  `docs/systems/character_controller.md` consistent?

## Known Current Status To Preserve

- Phase 7 movement/camera/streaming smoke passed in the main scene for:
  fly-camera to player-mode toggle, movement, sprint, jump, crouch,
  first/third-person toggle, and streaming cell boundary crossing.
- The human-provided log for that smoke run showed no controller, player-mode,
  movement, animation, or interaction-wiring errors during the tested path.
- Interaction, carry/drop/throw, water, and carry-through-interior checks are
  blocked or pending because dependent systems/content paths are not yet
  complete enough to exercise them in the main scene.
- Do not classify those blocked checks as controller failures unless code
  inspection finds a controller-side defect.

## Adjacent Warnings Seen In Phase 7 Log

The supplied Phase 7 log included warnings/errors that are real but not
automatically character-controller failures:

- Godot deprecation warning:
  `instance_reset_physics_interpolation() is deprecated`.
- Terrain3D editor-texture warning.
- streaming/profiler frame-overrun warnings.
- repeated `CellStaticCollision` missing-shape sidecar warnings.
- shutdown-time RID/resource leak reports.

Audit these only to determine whether the character-controller work introduced
or depends on them. Otherwise, classify them as adjacent streaming/rendering or
resource-cleanup follow-up.

## Constraints

- This is a read-only audit unless the human explicitly asks for fixes.
- Do not launch Godot from Codex unless the human says the environment has
  changed. The documented Codex limitation still applies.
- Do not use automated screenshots or auto-capture as proof of visual behavior.
- Do not re-tune `_move_with_step_up()` unless new evidence shows the current
  canonical up/forward/down probe architecture is wrong.
- Do not broaden scope into combat, inventory UI, full dialogue services,
  save/load, character creation, or full Morrowind actor-stat movement formulas.
- Do not bake Morrowind-specific data formats, coordinate conventions, or ESM/NIF
  details into generic controller files.
- Prefer design decisions that preserve or improve future modding capability:
  data-driven resources, clear override order, stable extension points, and
  adapter-owned game-specific rules.
- Do not create new autoloads.
- Treat project comments and inherited assumptions as secondary evidence; check
  the actual code and live docs.

## Useful Severity Guide

- **P0:** crash, data corruption, hard freeze, or a controller path that cannot
  be entered/exited.
- **P1:** architecture/ownership violation, movement disabled by missing
  animation, stale public state causing wrong behavior, invalid physics-layer
  contract, or a Godot lifecycle misuse likely to break runtime behavior.
- **P2:** maintainability, stale docs/comments, confusing duplicate state,
  modding boundary weakness, input-contract drift, missing tests for important
  behavior.
- **P3:** polish, naming clarity, optional fixture expansion, comments that
  could be shorter, non-blocking documentation improvements.

## Suggested Extra Things To Look For

- Does config loading fail gracefully if a preset resource is missing?
- Are default values defined in one place, or copied across resources, exports,
  tests, and docs?
- Are there any per-frame allocations in movement hot paths that can be avoided
  without making the code uglier?
- Are move priorities obvious and documented well enough to prevent accidental
  regressions?
- Are `StringName` move names used consistently, or are strings mixed in ways
  that invite typo bugs?
- Are swim/crouch/jump transitions symmetric on entry and exit?
- Are freeze/disable/reset paths resetting `MovementState`, public state,
  camera posture, and interact/carry state coherently?
- Are visual-test-only shortcuts clearly namespaced as visual-test actions?
- Are unit tests too coupled to private implementation details that a clean
  refactor would unnecessarily break?
- Are shutdown/resource warnings plausibly connected to controller-attached
  nodes, or clearly owned by streaming/rendering systems?
- Are docs making a stronger claim than validation supports?

## Completion Criteria

The audit is complete when it:

- covers every scoped component above;
- distinguishes controller findings from blocked dependent systems;
- names any stale or misleading docs/comments;
- identifies any Godot API or industry-pattern deviations;
- calls out whether the post-phase-7 controller is maintainable as-is;
- recommends the smallest next repair plan if issues remain;
- records what runtime validation could not be performed by Codex.
