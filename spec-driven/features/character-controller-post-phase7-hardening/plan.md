# Plan: Character Controller Post-Phase 7 Hardening

## Spec Link

`spec.md`

## Architecture Summary

This plan preserves the Phase 7 controller architecture and hardens the
contracts around it.

The central input decision is an explicit active-context model. Godotwind keeps
its single `InputMap` action namespace, but the active mode chooses which owner
may interpret `interact`:

- `PlayerGameplayContext`: `PlayerController` owns raw `interact`.
- `FlyCameraContext`: `world_explorer.gd` owns fly/debug interaction.

Both contexts should use one shared interaction-intent splitter for
tap/hold/release semantics, so the fly path is not a hand-copied version of the
player path.

The rest of the work is split into small slices: teleport interpolation resets,
body-driven carry release cleanup, carry prompt suppression, movement config
truthfulness, visual-test input actions, jump-state naming/docs, and status-doc
reconciliation.

## Layers

Framework layer:

- `PlayerController`: player-mode input owner and teleport helper.
- `InteractionIntent` helper or equivalent small RefCounted script: shared
  tap/hold/release state.
- `InteractionRaycaster`: target and prompt signal owner, with generic prompt
  suppression support.
- `CarryController`: body-driven held-body cleanup.
- `CharacterMovementConfig`: honest movement tuning surface.
- `MovementState`: public state read model for animation/gameplay/debug.

Game-specific layer:

- Morrowind interaction adapters and movement preset resources.
- No Morrowind-specific changes are required unless a preset currently sets a
  field that becomes reserved.

Reference-compatibility layer:

- OpenMW is a camera/input reference only here.
- No OpenMW or Morrowind formulas should enter generic controller code.

Validation layer:

- Human/user-run gdUnit tests through the existing project runner.
- Human/user interactive launches for `tests/visual/test_character_controller.tscn`
  and `scenes/Godotwind.tscn`.
- Codex-side static inspection for raw keycode cleanup and docs consistency.

## Godot Components

- Nodes: `CharacterBody3D`, `Camera3D`, `InteractionRaycaster`,
  `CarryController`, `PlayerController`, fly camera node in `world_explorer.gd`.
- Resources: `CharacterMovementConfig`, default movement preset, Morrowind
  movement preset.
- Shaders: none.
- Editor tools: none.
- Importers: none.
- Autoloads: none added.
- Scenes: `scenes/Godotwind.tscn`,
  `tests/visual/test_character_controller.tscn`, existing step scene only for
  regression context.

## Data Model

### Active Input Contexts

Use names in docs and code comments even if the first implementation is just an
enum/mode gate in `world_explorer.gd`:

- `PlayerGameplayContext`
  - active when `_camera_mode == PLAYER_CONTROLLER`;
  - owner: `PlayerController`;
  - raw `interact` becomes semantic `interact_tap`,
    `interact_hold_begin`, `interact_release`.
- `FlyCameraContext`
  - active when `_camera_mode == FLY_CAMERA`;
  - owner: `world_explorer.gd` fly interaction adapter;
  - raw `interact` becomes the same semantic outcomes, routed to the fly
    raycaster/carry controller.

The helper should track:

- press time;
- whether hold already emitted;
- hold threshold;
- methods for `press(now)`, `release(now)`, and `poll(now)`.

### Movement Config Field States

Each exported field should have one status:

- `active`: covered by runtime behavior and tests.
- `reserved`: kept visible only with explicit docs stating it is not active yet.
- `removed/deprecated`: removed from active presets or replaced by a clearer
  field.

Phase 3 field decisions:

- Active:
  - `turn_to_movement_direction`;
  - `step_down_height`;
  - `min_step_height`.
- Reserved:
  - `smooth_movement`;
  - `smooth_player_turning_delay`;
  - `swim_upward_correction_enabled`;
  - `swim_upward_coef`.

Do not leave a field in a production preset with a value that suggests active
behavior unless it has a test proving the behavior.

## Modding and Override Model

- Moddable resources, configs, or assets:
  - `CharacterMovementConfig` and movement preset `.tres` files.
- Extension points:
  - future movement presets;
  - future interaction adapters;
  - active input contexts documented in the input system.
- Override/load-order behavior:
  - unchanged from the character-controller productionization feature.
- Validation fixtures for custom content:
  - a custom movement config with unusual field values for enforced fields.
- Boundaries:
  - generic movement and interaction code should consume framework concepts,
    not Morrowind record names or file formats.

## Runtime Flow

1. Main scene sets `_camera_mode` to fly or player.
2. The active mode names the current input context.
3. Only the active context processes raw `interact`.
4. The active context feeds press/release/poll events into the shared
   interaction-intent helper.
5. Player mode emits `PlayerController` interaction signals and routes through
   the player raycaster/carry controller.
6. Fly mode routes the same semantic outcomes through the fly raycaster/fly
   carry controller.
7. While carry is active, tap interaction remains ignored and prompt output is
   suppressed for that active context.
8. Teleport paths write transforms, clear velocity where appropriate, then call
   `reset_physics_interpolation()` on moved visible/physics nodes.
9. Movement config changes affect runtime behavior only for fields marked
   active.

## Phases

### Phase 0: Spec Package

Goal: land this feature folder and convert the audit into implementation-ready
work.

Scope:

- Create `research.md`, `spec.md`, `plan.md`, `tasks.md`, `validation.md`, and
  `review.md`.
- No runtime code changes.

Validation:

- Static: files exist and reference the audit.
- No Godot launch required.

### Phase 1: Active Input Context and Shared Interaction Intent

Goal: resolve the P1 input ownership drift without rewriting fly camera into
noclip.

Scope:

- Add a small interaction-intent helper, probably under
  `src/core/interaction/` or `src/core/input/`.
- Route `PlayerController` tap/hold/release timing through the helper.
- Route `world_explorer.gd` fly interaction timing through the helper.
- Name `PlayerGameplayContext` and `FlyCameraContext` in docs.
- Update `docs/systems/input_system.md` and
  `docs/systems/interaction_system.md` so the contract becomes "one active
  context owns `interact`" instead of "PlayerController owns it forever."
- Avoid a new autoload or broad input stack.

Files likely touched:

- `src/core/player/player_controller.gd`
- `src/tools/world_explorer.gd`
- `src/core/interaction/interaction_intent.gd` or
  `src/core/input/interaction_intent.gd`
- `src/core/input/input_actions.gd`
- `docs/systems/input_system.md`
- `docs/systems/interaction_system.md`
- `tests/unit/test_character_controller_phase0_baseline.gd` or a focused input
  unit test

Validation:

- Human/user runs gdUnit for interaction-intent tap/hold/release contracts.
- Static inspection confirms only the active context path processes fly/player
  interaction in its mode.
- Human/user opens `scenes/Godotwind.tscn`, tests fly-mode tap/hold and
  player-mode tap/hold if content exists, and confirms no double activation.

### Phase 2: Teleport, Carry Cleanup, and Prompt Suppression

Goal: fix small correctness defects with high visible impact.

Scope:

- Add `reset_physics_interpolation()` to `PlayerController.teleport_to()` after
  the discontinuous position write.
- Add interpolation resets to direct transition writes in
  `InteriorPocketManager` that bypass `PlayerController.teleport_to()`.
- Consider `FlyCamera.teleport_to()` or direct fly-camera cell teleport writes
  if they are visible discontinuous camera moves.
- Change `CarryController.release()` so `_do_release` is scheduled whenever the
  captured `RigidBody3D` is valid, even if the pickup wrapper is invalid.
- Add a public `release()` regression test for the invalid-wrapper/valid-body
  case.
- Suppress prompts while the active carry controller is carrying. Prefer a
  generic callable/boolean on `InteractionRaycaster` or prompt callback logic
  over importing `CarryController` into the raycaster.

Files likely touched:

- `src/core/player/player_controller.gd`
- `src/core/world/interior_pocket_manager.gd`
- `src/core/player/fly_camera.gd`
- `src/core/interaction/carry_controller.gd`
- `src/core/interaction/interaction_raycaster.gd`
- `src/tools/world_explorer.gd`
- `tests/unit/test_character_controller_phase0_baseline.gd` or focused
  interaction tests
- `docs/systems/interaction_system.md`
- `docs/systems/character_controller.md`

Validation:

- Human/user runs gdUnit tests for teleport reset, body-driven carry release,
  and carry prompt suppression.
- Human/user launches `tests/visual/test_character_controller.tscn` or the main
  scene, performs a player/fly teleport path, and watches for interpolation
  streaking.
- Human/user grabs an object and confirms prompts hide while held.

### Phase 3: Movement Config Truthfulness

Goal: restore modding trust in exported movement config fields.

Scope:

- Audit every `CharacterMovementConfig` exported field.
- Implement active behavior for fields selected as shipping in this milestone.
- Move ambiguous/no-op fields to a documented reserved/future-only section or
  remove them from active presets.
- Add tests for active fields.
- Update movement docs and preset comments/values where possible.

Files likely touched:

- `src/core/character/controller/character_movement_config.gd`
- `src/core/character/controller/movement_presets/*.tres`
- `src/core/character/controller/move_container.gd`
- `src/core/character/controller/move.gd`
- `src/core/character/controller/moves/*.gd`
- `docs/systems/character_controller.md`
- unit tests for movement config

Validation:

- Human/user runs gdUnit with unusual config values proving active fields affect
  movement/turning/step behavior.
- Static inspection confirms no production preset sets a reserved field as if
  it is active.
- Human/user visually checks the controller scene if turn/step/swim behavior
  changes.

### Phase 4: Visual Test Input Actions and State/Docs Cleanup

Goal: remove stale handoff traps and bring the main visual controller test into
the unified input contract.

Scope:

- Add namespaced visual-test actions for:
  - preset NPC 1-5;
  - debug HUD toggle;
  - KF/bone comparison dump.
- Route `tests/visual/test_character_controller.gd` through `InputMap`
  actions instead of raw keycode checks for those scene-specific controls.
- Clarify or split `MovementState`/`PlayerController.is_jumping` semantics so
  falling is not accidentally named "jumping."
- Update stale comments that reference old doc paths or obsolete ownership.
- Reconcile `docs/STATUS.md` with current interaction/carry/main-scene wiring.

Files likely touched:

- `project.godot`
- `src/core/input/input_actions.gd`
- `tests/visual/test_character_controller.gd`
- `src/core/character/controller/movement_state.gd`
- `src/core/character/controller/move_container.gd`
- `src/core/player/player_controller.gd`
- `src/core/interaction/interaction_raycaster.gd`
- `src/core/interaction/carry_controller.gd`
- `src/tools/world_explorer.gd`
- `docs/STATUS.md`
- `docs/systems/input_system.md`
- `docs/systems/interaction_system.md`
- `docs/systems/character_controller.md`

Validation:

- Static inspection finds no raw `KEY_1..KEY_5`, `KEY_F1`, or `KEY_F2` branch in
  `tests/visual/test_character_controller.gd`.
- Human/user launches the visual controller scene and confirms preset switching,
  HUD toggle, and debug dump still work through actions.
- Docs no longer claim carry is kinematic or unwired in the main scene.

### Phase 5: Integrated Verification and Review

Goal: prove the hardening pass did not regress the tested Phase 7 path.

Scope:

- Human/user runs the targeted gdUnit scene.
- Human/user launches the visual controller scene.
- Human/user launches `scenes/Godotwind.tscn` and runs the main-scene checklist.
- Record results in this feature's `review.md`.

Validation:

- Automated: newest gdUnit report has zero failures in the targeted controller
  and interaction contracts.
- Visual: controller scene input actions, carry prompt behavior, and any
  movement-config behavior changes look correct.
- Main scene: fly/player switching, movement, streaming boundary crossing, and
  available interaction/carry paths remain stable.

Status:

- Complete for currently available main-scene content.
- Deferred until implemented in the main scene:
  - available interact/carry paths behave;
  - prompts hide while carrying and return after release;
  - teleport/interior paths do not visibly streak.

### Phase 6: Next Implementation Slice

Goal: move forward from the completed hardening baseline without reopening
Phases 1-5.

Scope:

- Start the next planned implementation package from the Phase 5 verified
  baseline.
- Do not redo active input contexts, teleport reset helpers, movement config
  truthfulness, visual-test actions, or Phase 5 smoke unless new evidence
  appears.
- Treat the deferred main-scene interaction/carry/interior smoke checks as
  future validation gates for the feature that implements those missing
  main-scene elements.

Validation:

- Use the latest hardening validation as baseline:
  - `reports/report_213/results.xml`: 50 tests, 0 failures, 0 errors,
    0 skipped.
  - `tests/visual/test_character_controller.tscn`: human/user confirmed
    working.
  - `tests/visual/test_teleport_interpolation_reset.tscn`: human/user
    confirmed working.
  - `scenes/Godotwind.tscn`: fly/player switching, movement, sprint, jump,
    crouch, camera toggle, streaming boundary crossing, and controller/input/
    interaction log review passed for available content.

## Files to Change

- `src/core/player/player_controller.gd`: active context contract, shared
  interaction intent, teleport reset, possible jump-state naming/docs.
- `src/tools/world_explorer.gd`: fly context ownership, shared fly interaction
  intent, prompt suppression, stale comments, possible fly-camera reset calls.
- `src/core/interaction/interaction_intent.gd`: new small helper if selected.
- `src/core/interaction/interaction_raycaster.gd`: generic prompt suppression
  if selected.
- `src/core/interaction/carry_controller.gd`: release cleanup and stale
  comment path.
- `src/core/world/interior_pocket_manager.gd`: interpolation reset after direct
  transition writes.
- `src/core/player/fly_camera.gd`: optional teleport interpolation reset.
- `src/core/character/controller/character_movement_config.gd`: active/reserved
  field clarity.
- `src/core/character/controller/move_container.gd`: step/config enforcement
  and movement-state semantic cleanup.
- `src/core/character/controller/moves/*.gd`: turn/swim/config enforcement.
- `src/core/input/input_actions.gd`: doc paths and visual-test action list.
- `project.godot`: new visual-test actions.
- `tests/visual/test_character_controller.gd`: InputMap-based visual controls.
- `tests/unit/*`: focused contracts.
- `docs/STATUS.md`: current state reconciliation.
- `docs/systems/input_system.md`: active input context contract.
- `docs/systems/interaction_system.md`: active input context and carry prompt
  behavior.
- `docs/systems/character_controller.md`: teleport/config/state updates.

## Documentation Plan

- Code comments needed:
  - active input context boundary in `world_explorer.gd` and
    `PlayerController`;
  - why teleport helpers call `reset_physics_interpolation()`;
  - reserved movement config fields, if any remain exported.
- Feature docs to update:
  - this feature's `tasks.md`, `validation.md`, and `review.md` as phases land.
- Architecture or data-flow docs to update:
  - `docs/systems/input_system.md`;
  - `docs/systems/interaction_system.md`;
  - `docs/systems/character_controller.md`;
  - `docs/STATUS.md`.
- Validation docs to update:
  - `validation.md` with actual human/user run reports.

## Validation Strategy

- Automated:
  - human/user-run gdUnit for helper behavior, carry release, config fields,
    and prompt suppression.
- Visual:
  - `tests/visual/test_character_controller.tscn`;
  - `scenes/Godotwind.tscn`.
- Performance:
  - no dedicated benchmark expected; ensure no new unbounded per-frame queries.
- Manual:
  - fly/player mode switching;
  - teleport visual check;
  - carry prompt hide/show;
  - visual-test action controls.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Input context repair becomes a broad input framework rewrite | Scope creep and regressions | Use current camera mode as the context selector; no autoload. |
| Shared interaction helper changes player tap/hold timing | Interaction regressions | Add unit contracts before routing both paths through it. |
| Prompt suppression hides prompts after release | Confusing UI | Emit a null prompt on suppression and force refresh after carry release. |
| Config field semantics are underspecified | More silent no-ops | Mark ambiguous fields reserved rather than inventing behavior. |
| Teleport reset tests overfit implementation | Brittle tests | Prefer observable flags/helpers or focused scene checks where direct spying is awkward. |
| Docs update claims full production readiness too early | Bad handoff | Keep runtime verification pending until human/user reports it. |

## Migration and Compatibility

- No C# files are planned.
- No shader files are planned; shader cache clearing should not be needed.
- Existing `project.godot` input actions must be extended carefully without
  breaking existing action names.
- `interact` keeps its physical binding; only the owner contract changes.
- Existing fly-mode functionality should remain available.
- Movement config resources may need a compatibility note if fields are moved
  to reserved/future-only status.
