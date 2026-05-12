# Plan: Character Controller Productionization

## Spec Link

`spec.md`

## Architecture Summary

The target architecture is a Godot-native character motor owned by the character/player stack, not by animation.

`PlayerController` remains the player-facing owner for input, camera, interaction, water context, and main-scene integration. It delegates movement to a generic motor that owns `MoveContainer`, `PlayerInputGatherer`, `CharacterMovementConfig`, and the per-frame `MovementState`. Animation becomes an observer: it receives movement state and chooses animation transitions, but movement keeps working when animation is missing or swapped.

The plan deliberately starts with small correctness fixes. The larger ownership refactor happens only after the existing path has a clean baseline and a data-driven config.

## Layers

Framework layer:

- `CharacterMovementConfig`: resource containing generic movement tuning.
- `CharacterMotor`: proposed node that owns input package creation, move container processing, and movement state publication.
- `MoveContainer` and `Move` scripts: generic state-machine movement.
- `MovementState`: public per-frame read model for animation, camera, debug UI, and future gameplay.

Game-specific layer:

- Morrowind movement preset/adapter that maps Morrowind/OpenMW-informed settings onto `CharacterMovementConfig`.
- Future actor-stat adapter for race, fatigue, encumbrance, magic effects, and content-pack overrides.

Reference-compatibility layer:

- OpenMW settings and MWPhysics constants inform preset defaults only.
- No SCVR, ESM, NIF, Morrowind coordinate flips, or OpenMW names in generic move files.

Validation layer:

- Human/user-run gdUnit tests for logic and ownership seams. Codex cannot
  reliably launch Godot from this workspace because the documented binary may
  be absent and the local Godot 4.6.2 Mono console runner crashes with signal
  11 before tests run.
- `tests/visual/test_character_controller.tscn` as the focused manual test
  scene, launched and checked by the human/user.
- Additional visual scenes/checklists for crouch posture, step solver, carry/interior mask behavior, and main-scene smoke.

## Godot Components

- Nodes: `CharacterBody3D`, `CollisionShape3D`, `SpringArm3D`, `Camera3D`, optional `ShapeCast3D`, `MoveContainer`, `CharacterMotor`.
- Resources: `CharacterMovementConfig`, default preset, Morrowind preset.
- Autoloads: none added.
- Scenes: focused visual controller scenes and `scenes/Godotwind.tscn`.
- Shaders: none.
- Editor tools/importers: none in the productionization plan.

## Data Model

`CharacterMovementConfig` should include:

- Ground speeds: walk, run, sprint, crouch.
- Air/swim: jump velocity, gravity scale if needed, air control, swim speed, buoyancy, swim upward correction flag and coefficient.
- Posture: standing height, crouch height, radius, eye heights, raycast origin offsets, stand-up clearance margin.
- Turning: turn-to-movement flag, smooth movement flag, smooth turn delay, backward threshold, backward speed multiplier.
- Step/slope: max floor angle, step up height, step down height, min step, wall probe distance.
- Timing: jump lockout, explicit coyote time, jump buffering, movement state elapsed time source.
- Capability flags: can walk, can sprint, can crouch, can jump, can swim.

`MovementState` should include:

- active move name;
- posture;
- grounded/water flags;
- input direction and strength;
- desired world direction;
- current velocity;
- sprint/walk/crouch/jump/swim booleans;
- elapsed time in active move;
- last transition reason, optional debug-only.

Config override order:

1. Framework default config.
2. Game preset such as Morrowind.
3. Character-specific resource override.
4. Temporary runtime modifiers, later owned by gameplay effects.

## Runtime Flow

1. `PlayerController._physics_process(delta)` updates environment context, interaction input, and camera-mode gates.
2. `CharacterMotor.process(delta, context)` asks `PlayerInputGatherer` to build an `InputPackage` with environment context already present.
3. `MoveContainer.process(input, delta)` selects and runs the active move, then calls `move_and_slide()` through its centralized movement path.
4. `MoveContainer` publishes `MovementState`.
5. `PlayerController` reads `MovementState` for public fields, camera posture, interaction ray origin, and debug output.
6. `CharacterAnimationSystem` reads `MovementState` and transitions animation, but does not own movement.

## Phases

### Phase 0: Spec Package and Baseline Confirmation

Goal: leave a durable plan and confirm the current baseline tests represent the audit.

Scope:

- Add this feature folder.
- Keep runtime code unchanged.
- Run the existing character-controller baseline tests.
- Record whether the current expected defects still reproduce.

Validation:

- Automated: human/user runs the gdUnit test scene, or the narrow controller
  suite if gdUnit supports filtering in this project.
- Manual: no visual scene required for Phase 0.

Done when:

- Plan, tasks, and validation docs exist.
- Baseline test results are recorded before implementation begins.

### Phase 1: Stabilize Current Behavior Without Moving Ownership

Goal: fix the known defects that can be corrected inside the current architecture.

Scope:

- Make rigidbody push happen exactly once after movement.
- Feed water/environment context into `PlayerInputGatherer` before swim vertical input is computed.
- Make moving crouch resolve to crouch behavior instead of default run.
- Keep `walk` unbound and update visual/help text to match the input-system contract.
- Make `world_explorer._attach_player_character()` return `bool`; abort player-mode switch on failure.
- Align the visual test's dynamic object/carryable layers with production layer conventions.

Files likely touched:

- `src/core/character/controller/move_container.gd`
- `src/core/character/controller/player_input_gatherer.gd`
- `src/core/character/controller/input_package.gd`
- `src/core/character/controller/moves/crouch_move.gd`
- `src/tools/world_explorer.gd`
- `tests/unit/test_character_controller_phase0_baseline.gd`
- `tests/visual/test_character_controller.gd`
- `docs/systems/character_controller.md`

Validation:

- Automated: human/user runs baseline tests updated so duplicate push expects
  `1`, swim pitch is non-zero when water context is passed, moving crouch
  expects crouch, and walk remains intentionally unbound.
- Manual: human/user launches `tests/visual/test_character_controller.tscn`;
  verify run, sprint, crouch movement, jump, swim pitch, and help text.
- Manual main-scene spot check: toggle player mode with missing/failed character data if easy to reproduce; verify it falls back instead of trapping the user.

Done when:

- The current controller is cleaner and still works even though animation still owns the move container.

### Phase 2: Add CharacterMovementConfig as the Single Tuning Source

Goal: remove tuning drift between `PlayerController` exports and concrete move values.

Scope:

- Add `CharacterMovementConfig` resource.
- Add default and Morrowind preset resources.
- Wire `MoveContainer`/moves to read from config.
- Keep `PlayerController` exports only as compatibility/proxy values during migration, or mark them as deprecated in docs if direct proxying would increase complexity.
- Move backward movement multiplier, backward threshold, turn policy, swim upward correction, and step/slope values into config.

Files likely touched:

- `src/core/character/controller/character_movement_config.gd`
- `src/core/character/controller/movement_presets/*.tres`
- `src/core/character/controller/move_container.gd`
- `src/core/character/controller/move.gd`
- `src/core/character/controller/moves/*.gd`
- `src/core/player/player_controller.gd`
- `docs/systems/character_controller.md`

Validation:

- Automated: human/user runs unit tests that instantiate a config with unusual
  speeds and verify moves read those values.
- Automated/static: Codex can statically check that generic move scripts no
  longer contain hard-coded "MW-style" movement comments or constants;
  human/user runs Godot-side tests.
- Manual: human/user opens the visual controller scene, swaps to a deliberately
  slow config, and verifies all locomotion tiers visibly slow down.

Done when:

- One resource controls movement tuning for the current controller path.

### Phase 3: Move Movement Ownership Out of Animation

Goal: make movement a character/controller responsibility and animation an observer.

Scope:

- Introduce `CharacterMotor` or equivalent ownership node.
- Move `MoveContainer` construction/wiring out of `CharacterAnimationSystem`.
- Let `PlayerController` own or receive the motor.
- Keep a short compatibility bridge from `CharacterAnimationSystem.process_moves()` only long enough to avoid breaking callers, then remove it in the same phase if all callers are migrated.
- Add `MovementState` publication.
- Animation reads `MovementState` and transitions animation.

Files likely touched:

- `src/core/character/character_motor.gd`
- `src/core/character/controller/movement_state.gd`
- `src/core/player/player_controller.gd`
- `src/core/animation/character_animation_system.gd`
- `src/core/animation/animation_manager.gd`
- `src/tools/world_explorer.gd`
- `src/core/character/humanoid/humanoid_character_factory.gd`
- tests around controller ownership

Validation:

- Automated: human/user runs tests proving a `PlayerController` plus
  `CharacterMotor` can process movement without an animation system.
- Automated: human/user runs tests proving animation state updates from
  `MovementState` when animation exists.
- Manual: human/user verifies the visual controller scene still moves with a
  visible character, then a no-animation test fixture still moves a capsule.

Done when:

- Disabling or replacing animation no longer disables movement.

### Phase 4: Posture, Camera, Raycast, and Timing Coherence

Goal: make public movement state and posture coherent across camera, collision, interaction, and animation.

Implementation note:

- Phase 4 is intentionally split into two slices, not a new phase. The timing
  slice is self-contained and can land first because it touches deterministic
  simulation state only. The posture slice remains in Phase 4 because it is the
  visible crouch/camera/raycast/collision coherence work promised by this
  phase.
- Do not start Phase 5 gameplay physics layers until Phase 4 posture coherence
  is implemented or explicitly deferred by the user. Phase 5 depends on
  interaction/carry behavior being evaluated against the correct player
  posture and ray origin.

Scope:

- Use `MovementState` to update `PlayerController` public movement fields or remove stale public fields.
- Make crouch posture drive capsule height, collision-shape offset, camera eye height, interaction ray origin, and animation posture together.
- Replace single-ray stand-up clearance with capsule/shape clearance.
- Keep `ground_to_midair_lockout` as a bounce/contact guard, and encode
  explicit coyote time plus jump buffering in config.
- Accumulate move elapsed time from physics `delta`, not wall-clock time.
- Pass the same `delta` through step movement instead of recomputing it.

Timing slice status:

- Implemented in `src/core/character/controller/move.gd` and
  `src/core/character/controller/move_container.gd`.
- Human/user report `reports/report_202/results.xml` confirmed the
  character-controller suite passed with 21 tests, 0 failures, 0 errors.
- Human/user also tested the character controller in game and reported it is
  working as expected.

Posture slice status:

- Keep `MovementState.posture` as the shared read model.
- Implemented: `PlayerController.camera_pivot` height follows
  standing/crouching posture
  from `CharacterMovementConfig.standing_eye_height` and
  `crouch_eye_height`.
- Implemented: `InteractionRaycaster.ray_origin_node` remains tied to the
  posture-aware eye
  origin so prompts/reach follow the crouched camera height.
- Kept: `CrouchMove` remains responsible for collision capsule height during this
  incremental phase, unless implementation reveals a smaller shared posture
  helper is needed.
- Implemented: `_can_stand_up()` uses a capsule/shape clearance
  check so low ceiling geometry near the capsule edge blocks standing.
- Implemented: stale `PlayerController` public movement fields are synced
  after posture is driven from `MovementState`.

Phase 4 coyote-time decision:

- `ground_to_midair_lockout` remains a bounce guard that prevents noisy
  ground-to-midair transitions after tiny Jolt/contact separations.
- `coyote_time` is explicit player forgiveness after leaving ground.
- `jump_buffer_time` stores slightly early jump input and consumes it on the
  first valid grounded/coyote frame.
- Crouch/stand does not get a separate input buffer in this slice because
  crouch is a held posture and stand-up is retried every frame until capsule
  clearance succeeds.

Files likely touched:

- `src/core/player/player_controller.gd`
- `src/core/interaction/interaction_raycaster.gd`
- `src/core/character/controller/move.gd`
- `src/core/character/controller/move_container.gd`
- `src/core/character/controller/moves/crouch_move.gd`
- `src/core/character/controller/moves/jump_move.gd`
- ground moves with airborne lockout/grace handling
- new or updated posture visual test

Validation:

- Automated: human/user runs tests proving move elapsed time advances by
  supplied physics delta.
- Automated: human/user runs tests proving coyote time is accepted within the
  configured window, expired coyote time rejects late jump, and jump buffering
  fires on a landing frame.
- Automated or scene test: human/user verifies stand-up is blocked by ceiling
  geometry at the capsule edge, not just the center.
- Manual: human/user verifies crouching visibly lowers the camera and
  interaction origin; standing under a low ceiling stays crouched.

Done when:

- Camera, raycast, collision, and animation agree on whether the player is standing or crouched.

### Phase 5: Centralize Gameplay Physics Layer Contracts

Goal: stop carry, player, interaction, and interior transitions from each hard-coding incompatible layer assumptions.

Status:

- Implemented: `GameplayPhysicsLayers` helper in `src/core/physics/`.
- Implemented: carry held masks exclude the player's current collision-layer
  bits and restore the exact saved mask on release.
- Pending: human gdUnit validation and manual held-object interior transition
  smoke pass.

Scope:

- Add a small layer helper or resource, not an autoload, for gameplay roles.
- Make `CarryController` clear the current player's actual collision bits while held, not only a fixed layer-2 bit.
- Preserve exact grab/release mask symmetry.
- Update visual tests to use production layer meanings.
- Add carry/interior regression coverage.

Files likely touched:

- `src/core/physics/gameplay_physics_layers.gd` or similar helper
- `src/core/interaction/carry_controller.gd`
- `src/core/interaction/carryable_body_factory.gd`
- `src/core/world/interior_pocket_manager.gd`
- `src/core/player/player_controller.gd`
- interaction and controller visual tests

Validation:

- Automated: human/user runs tests proving fake player layer/mask changes are
  excluded from held body masks and restored on release.
- Manual: human/user grabs an item, crosses an interior transition or seamless
  doorway, and verifies the held item never pushes the player capsule.

Done when:

- Held-object no-player-collision behavior survives player layer rewrites.

### Phase 6: Step Solver Contract Tests and Tuning

Goal: protect the step-up/down solver with scenario tests before broad main-scene claims.

Status:

- Started with validation surface only: added a focused visual scene with six
  labeled obstacle lanes and a lightweight gdUnit scene-surface contract.
- No step solver tuning or architecture changes have been made in Phase 6 yet.

Scope:

- Add focused test geometry for small step, tall wall, angled wall, ceiling-blocked step, down-step with no floor, and rigidbody obstacle.
- Keep the current HL2/OpenMW/UE-style probing if tests pass.
- Tune only through config.
- Avoid new per-frame bespoke distance checks outside the solver.

Files likely touched:

- `src/core/character/controller/move_container.gd`
- `tests/visual/test_character_controller_steps.tscn`
- `tests/visual/test_character_controller_steps.gd`
- possible gdUnit scenario tests if stable enough

Validation:

- Automated where practical: human/user runs scripted physics fixtures asserting
  final height/position categories.
- Manual: human/user uses the step visual scene and walks into each labeled
  obstacle.
- Performance: ensure the solver remains bounded and does not add unbounded casts per frame.

Done when:

- Step behavior is documented by tests, not just comments.

### Phase 7: Main Scene Player-Mode Production Smoke

Goal: validate `scenes/Godotwind.tscn` as one integrated path.

Scope:

- Update stale status docs from "not wired" to the accurate integration state.
- Add a manual smoke checklist for main-scene player mode.
- Fix only defects discovered in the smoke pass that block production readiness; anything larger goes back through this spec.

Manual smoke checklist:

- Human/user launches `scenes/Godotwind.tscn` interactively.
- Toggle from fly camera to player mode.
- Move, sprint, jump, crouch, and toggle first/third person.
- Walk across streaming cell boundaries.
- Interact with a door/container/activator.
- Carry, drop, and throw an item.
- Enter and exit water; verify swim pitch.
- Enter and exit an interior or seamless doorway while carrying an item.
- Confirm console/log has no controller errors.

Validation:

- Human/user interactive launch with the documented Godot binary.
- Human/user automated crash smoke if a specific visual pass cannot be run.

Done when:

- The human/user has completed the smoke pass, Codex has recorded the reported
  result, and docs describe the shipped state honestly.

## Files To Change By Phase

- Phase 0: spec-driven docs only.
- Phase 1: current GDScript controller and test files.
- Phase 2: config resource, move scripts, docs.
- Phase 3: ownership boundary between player, character, and animation.
- Phase 4: posture/timing state and interaction-ray origin.
- Phase 5: physics layer helper and carry/interior integration.
- Phase 6: step validation scenes/tests.
- Phase 7: docs/status and main-scene smoke notes.

## Documentation Plan

- Update `docs/systems/character_controller.md` after each behavior-affecting phase.
- Update `docs/STATUS.md` only when main-scene integration status actually changes.
- Add notes to validation scenes where expected behavior is not obvious.
- Keep Morrowind compatibility notes in preset/adapter docs, not generic move scripts.

## Risk Register

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Moving ownership breaks animation wiring | Player moves but appears frozen or wrong | Stabilize first, add movement-state tests, keep compatibility bridge during Phase 3 |
| Config resource becomes too broad | Hard to understand and mod | Start with fields already used by current moves; add future fields only with tests |
| Crouch camera changes affect interaction reach | Prompts feel wrong | Drive camera and ray origin from one posture state; visual posture test |
| ShapeCast clearance is overused | Physics cost rises | Use on posture transition or when attempting stand-up, not blindly every frame |
| Carry/interior layer changes regress interaction | Items not targetable or collide incorrectly | Centralize layer roles and add carry/interior smoke |
| Main scene has content-dependent failures | Hard to reproduce without user environment | Keep focused visual scenes for logic and treat main scene as final integration smoke |

## Migration and Compatibility

- Preserve current visual controller scene throughout all phases.
- Avoid changing `walk` bindings without an input-system spec update.
- Keep old `PlayerController` exports until `CharacterMovementConfig` is proven in scenes.
- If a compatibility bridge is added in Phase 3, it must have a removal task in the same phase or the next immediate phase.
- No shader/import cache rules apply unless a later phase unexpectedly edits shader files.
