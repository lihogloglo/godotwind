# Character Controller Code Audit

Date: 2026-05-09
Owner: Codex
Status: read-only code audit; no runtime code changed

## Scope

Reviewed the current Godotwind character controller stack through the
spec-driven project rules:

- `AGENTS.md`
- `spec-driven/00-constitution.md`
- `spec-driven/01-workflow.md`
- `docs/systems/character_controller.md`
- `docs/systems/input_system.md`
- `docs/systems/interaction_system.md`
- `src/core/player/player_controller.gd`
- `src/core/character/character_movement_controller.gd`
- `src/core/character/controller/*.gd`
- `src/core/character/controller/moves/*.gd`
- `src/core/animation/character_animation_system.gd`
- `src/tools/world_explorer.gd`
- `src/core/world/interior_pocket_manager.gd`
- `src/core/interaction/carry_controller.gd`
- `src/core/interaction/carryable_body_factory.gd`
- `project.godot`
- `tests/unit/test_character_controller_phase0_baseline.gd`
- `tests/visual/test_character_controller.gd`

OpenMW was treated as a compatibility reference, not an architecture mandate.
The useful OpenMW references for this audit were movement-related settings and
physics constants:

- OpenMW game settings: `turn to movement direction`, `smooth movement`,
  `smooth movement player turning delay`, `swim upward correction`, and
  `swim upward coef`.
- OpenMW default settings file: `files/settings-default.cfg`.
- OpenMW generated source docs for `MWPhysics`, including `Stepper`,
  `MovementSolver`, `sMaxSlope`, `sStepSizeUp`, and `sStepSizeDown`.

## Executive Summary

The character controller has the right broad ambition: a Godot-native
`CharacterBody3D`, a Move-as-Node state machine, a visual validation scene, and
baseline tests that honestly document known defects.

The main production risk is ownership. Movement physics currently lives under
`CharacterAnimationSystem`, while `PlayerController` owns the body, camera,
water state, interaction, input gatherer, and public movement exports. That
means animation setup is required for player movement, controller exports do
not reliably configure the actual moves, and modding or game-specific movement
rules do not have a clean data-driven boundary yet.

Follow-up inspection found that the main scene now has partial player-mode
wiring in `src/tools/world_explorer.gd`: it creates `PlayerController`,
`InteractionRaycaster`, and `CarryController`, and toggles from fly camera to
player mode. The status docs saying "not wired" are stale, but the integration
is still not production-ready because it can enable player mode after failed
character attachment and has not been validated against streaming, carry,
interiors, water, and real content as one path.

Before treating this as production-ready, fix the already-documented baseline
defects, split movement configuration from animation ownership, and add a
main-scene smoke pass for player mode.

## Positive Findings

- The controller uses Godot's native `CharacterBody3D` and `move_and_slide()`
  rather than a fully bespoke physics body.
- Camera interpolation is deliberately handled: `camera_pivot` is carved out
  from physics interpolation so mouse look stays render-rate fresh
  (`src/core/player/player_controller.gd:386`).
- The interaction input contract is well documented and mostly centralized:
  `PlayerController` owns the raw `interact` action
  (`src/core/player/player_controller.gd:29`,
  `docs/systems/interaction_system.md:39`).
- `tests/unit/test_character_controller_phase0_baseline.gd` is exactly the
  right kind of audit harness: it locks down known current behavior so future
  fixes can update tests intentionally.
- `tests/visual/test_character_controller.tscn` exists, which satisfies the
  spec-driven rule that visual/controller work needs a runnable scene.
- The 50 degree floor angle in `PlayerController` is close to OpenMW's
  documented `sMaxSlope = 49.0f`, which is a good example of OpenMW as a
  compatibility reference rather than a full architecture import.

## Findings

### P1: Movement Is Owned by the Animation System

`PlayerController` only moves when both `_input_gatherer` and `animation_system`
exist, then delegates movement to `animation_system.process_moves(...)`
(`src/core/player/player_controller.gd:279` to
`src/core/player/player_controller.gd:286`). The `MoveContainer` is created as a
child of `CharacterAnimationSystem`
(`src/core/animation/character_animation_system.gd:364` to
`src/core/animation/character_animation_system.gd:367`) and wired there
(`src/core/animation/character_animation_system.gd:399` to
`src/core/animation/character_animation_system.gd:405`).

That inverts the natural ownership model. Physics/movement should be a core
character system; animation should observe movement state and play the right
animations. As written, disabling or replacing the animation system can disable
player movement, and modders cannot provide a different movement profile without
implicitly participating in animation wiring.

Recommended direction:

- Move `MoveContainer` ownership out of `CharacterAnimationSystem` and into a
  generic character motor/controller layer.
- Let animation consume semantic movement state: idle, walk, run, sprint,
  crouch, jump, midair, swim.
- Keep `CharacterAnimationSystem.process_moves()` only as a compatibility bridge
  during migration, then remove it.

### P1: Public Movement Exports Do Not Configure the Actual Moves

`PlayerController` exposes `run_speed`, `walk_speed`, `sprint_speed`,
`jump_velocity`, and `can_walk`
(`src/core/player/player_controller.gd:61` to
`src/core/player/player_controller.gd:69`). The concrete moves define their own
independent values instead:

- `RunMove.speed = 5.0` (`src/core/character/controller/moves/run_move.gd:5`)
- `WalkMove.speed = 2.5` (`src/core/character/controller/moves/walk_move.gd:5`)
- `SprintMove.speed = 8.0` (`src/core/character/controller/moves/sprint_move.gd:5`)
- `JumpMove.jump_velocity = 4.5` (`src/core/character/controller/moves/jump_move.gd:5`)
- `CrouchMove.crouch_speed = 2.0` (`src/core/character/controller/moves/crouch_move.gd:5`)

There is no visible propagation from `PlayerController` exports into those
move instances. This makes inspector values, future mod settings, and
Morrowind-specific movement formulas unreliable as sources of truth.

Recommended direction:

- Add a `CharacterMovementConfig` Resource as the single source for speeds,
  jump velocity, crouch dimensions, air control, swim settings, turn policy,
  stamina costs, and optional Morrowind compatibility toggles.
- Let generic moves read from the config.
- Let a Morrowind adapter populate that config from game settings, race data,
  stats, encumbrance, fatigue, and OpenMW-informed compatibility options.

### P1: Swimming Pitch Is Evaluated Before Water State Is Injected

`PlayerInputGatherer.gather_input()` only applies camera pitch to
`vertical_input` when `pkg.is_in_water` is already true
(`src/core/character/controller/player_input_gatherer.gd:30` to
`src/core/character/controller/player_input_gatherer.gd:31`). But
`PlayerController` sets `input.is_in_water` only after `gather_input()` returns
(`src/core/player/player_controller.gd:279` to
`src/core/player/player_controller.gd:284`).

The unit baseline captures this as a known defect
(`tests/unit/test_character_controller_phase0_baseline.gd:157` to
`tests/unit/test_character_controller_phase0_baseline.gd:174`).

Impact: swimming does not get the intended 3D camera-relative pitch behavior.
This also blocks clean support for OpenMW-style `swim upward correction` and
`swim upward coef`, which should be configurable game-specific behavior layered
on top of the generic swim system.

Recommended direction:

- Pass environmental state into the gatherer before input packaging, for
  example `gather_input(context)` or `gather_input(is_in_water, water_surface_y)`.
- Keep OpenMW compatibility as config: `swim_upward_correction_enabled` and
  `swim_upward_coef`, not hard-coded math inside the generic gatherer.

### P1: RigidBody Push Runs Twice Per Frame

`MoveContainer.process()` calls `_move_with_step_up()` and then
`_push_rigid_bodies()` (`src/core/character/controller/move_container.gd:94`
to `src/core/character/controller/move_container.gd:95`). But
`_move_with_step_up()` already calls `_push_rigid_bodies()` in each movement
branch and after the final `move_and_slide()` commit
(`src/core/character/controller/move_container.gd:184` to
`src/core/character/controller/move_container.gd:287`).

The baseline test proves the current behavior:
`tests/unit/test_character_controller_phase0_baseline.gd:65` to
`tests/unit/test_character_controller_phase0_baseline.gd:84`.

Impact: pushable objects can receive double impulses, which can produce jitter,
excessive shove strength, and confusing tuning. It also makes performance and
feel harder to reason about.

Recommended direction:

- Make `_move_with_step_up()` only perform movement.
- Call `_push_rigid_bodies()` exactly once from `process()` after movement.
- Update the baseline test so the expected push count becomes `1`.

### P1: Moving Crouch Currently Resolves to Run

`CrouchMove` has priority `1`
(`src/core/character/controller/moves/crouch_move.gd:17`) while `RunMove` has
priority `2` (`src/core/character/controller/moves/run_move.gd:14`).
When input contains both `run` and `crouch`, `best_input_that_can_be_paid()`
chooses run. The baseline test documents this:
`tests/unit/test_character_controller_phase0_baseline.gd:89` to
`tests/unit/test_character_controller_phase0_baseline.gd:98`.

Impact: holding crouch while moving does not reliably enter crouch locomotion,
even though `CrouchMove` has walking behavior and collision resizing.

Recommended direction:

- Treat crouch as a posture or locomotion modifier with higher priority than
  default run.
- Alternatively split posture from locomotion so "crouched + moving" is not
  competing with "run" in the same flat priority list.

### P1: Carry/Interior Physics Layers Break the Player-Mask Assumption

`CarryController` prevents held objects from pushing the player by clearing
`CarryableBodyFactoryScript.LAYER_PLAYER` from the held body's collision mask
(`src/core/interaction/carry_controller.gd:298`). That assumes the player
always occupies physics layer 2. However, `InteriorPocketManager` rewrites the
player body's collision layer and mask during interior transitions:

- entering a loaded interior sets both to `target_slot.physics_layer_mask`
  (`src/core/world/interior_pocket_manager.gd:1394` to
  `src/core/world/interior_pocket_manager.gd:1395`);
- seamless enter expands the player to
  `EXTERIOR_PHYSICS_LAYERS | slot.physics_layer_mask`
  (`src/core/world/interior_pocket_manager.gd:1458` to
  `src/core/world/interior_pocket_manager.gd:1459`);
- `EXTERIOR_PHYSICS_LAYERS` itself includes layers 1-4, not only the documented
  player bit (`src/core/world/interior_pocket_manager.gd:75` to
  `src/core/world/interior_pocket_manager.gd:78`).

Impact: the carry system's "held objects do not collide with the player" rule
can fail in interiors or during seamless transitions because it clears only the
old layer-2 bit, not the player's current collision bits. This is exactly the
kind of cross-system ownership problem the spec-driven docs warn about: layer
semantics are split across interaction, player control, and interior streaming.

Recommended direction:

- Centralize gameplay physics layer roles in one small layer contract/resource
  or helper, instead of hard-coding masks in each subsystem.
- Give `CarryController` a way to query the current player collision bits from
  the `CharacterBody3D` it already receives in `setup(camera, player)`, and
  clear/restore those bits deliberately while held.
- Add an interior/carry smoke test: grab an object, enter/exit an interior or
  seamless doorway, and verify the held object never shoves the player capsule.

### P2: Generic Move Code Contains Hard-Coded Morrowind-Style Behavior

`WalkMove` and `RunMove` encode "MW-style" backward movement directly in the
generic move files (`src/core/character/controller/moves/walk_move.gd:52` to
`src/core/character/controller/moves/walk_move.gd:53`,
`src/core/character/controller/moves/run_move.gd:48` to
`src/core/character/controller/moves/run_move.gd:49`). The threshold is a
hard-coded angle (`2.1` radians) and the backward speed multiplier is also
hard-coded.

OpenMW exposes movement behavior as settings such as `turn to movement
direction`, `smooth movement`, and `smooth movement player turning delay`.
Godotwind should follow that layering principle: Morrowind-compatible movement
is one configuration or adapter on a generic controller, not a baked-in rule in
shared move scripts.

Recommended direction:

- Move turn policy, backward threshold, backward speed multiplier, and smooth
  turning delay into `CharacterMovementConfig`.
- Add a Morrowind preset/adapter that sets those values.
- Keep the generic moves free of game-specific comments and assumptions.

### P2: Walk Is Both Implemented and Intentionally Unbound

The controller and visual test advertise walk:

- `PlayerController.walk_speed` and `can_walk`
  (`src/core/player/player_controller.gd:62` to
  `src/core/player/player_controller.gd:69`)
- `_ensure_input_actions()` would bind `"walk": KEY_CTRL` only if the action
  were missing (`src/core/player/player_controller.gd:421` to
  `src/core/player/player_controller.gd:438`)
- the visual test header says `Ctrl = walk`
  (`tests/visual/test_character_controller.gd:4`)

But `project.godot` already defines `walk` with no events
(`project.godot:109` to `project.godot:111`), and the input-system doc says
walk is intentionally unbound by default. Because `_ensure_input_actions()` is
idempotent, it will not add Ctrl when an empty `walk` action already exists.
The baseline test records the mismatch
(`tests/unit/test_character_controller_phase0_baseline.gd:148` to
`tests/unit/test_character_controller_phase0_baseline.gd:154`).

Recommended direction:

- Decide whether walk is a shipped default control or an optional unbound
  action.
- If shipped: bind it in `project.godot`, `InputActions`, docs, and tests.
- If optional: remove the visual-test claim that Ctrl walks and make
  `PlayerController.can_walk` part of a documented config/remap flow.

### P2: PlayerController Public Movement State Goes Stale

`PlayerController` exposes `input_direction`, `input_strength`, `direction`,
`is_sprinting`, `is_walking`, and `is_jumping`
(`src/core/player/player_controller.gd:141` to
`src/core/player/player_controller.gd:157`). These are reset by freeze/disable
paths, but the active MoveContainer path does not update them each frame.

Impact: downstream systems, debug UI, animation code, mod scripts, or gameplay
rules that consult the public controller state can read stale default values
while the player is actively moving.

Recommended direction:

- Either remove these fields from the public API or update them from the same
  movement snapshot that drives physics.
- Prefer one immutable per-frame movement state object that animation, camera,
  gameplay, and debug UI can all read.

### P2: Validation Scene Uses Collision Layer Semantics That Conflict With Docs

The interaction system defines:

- layer 1: Environment
- layer 2: Player
- layer 3: Interactable

See `docs/systems/interaction_system.md:203` to
`docs/systems/interaction_system.md:208`.

The character-controller visual test creates a rolling sphere on
`collision_layer = 2` and labels that "Dynamic object layer"
(`tests/visual/test_character_controller.gd:637` to
`tests/visual/test_character_controller.gd:638`). That works for the isolated
test, but it trains the validation scene against a layer convention that
contradicts the production interaction docs.

Recommended direction:

- Keep the visual test on production layer conventions.
- Put dynamic props/carryables on the same layers used by the interaction/carry
  system.
- Add a small layer legend to the validation doc or scene comments.

### P2: Player Mode Can Enable After Character Attachment Fails

`world_explorer._switch_to_player_controller()` calls `_attach_player_character()`
when `player_controller.character_root` is missing, but it does not check
whether attachment succeeded before enabling the controller
(`src/tools/world_explorer.gd:1401` to `src/tools/world_explorer.gd:1415`).
`_attach_player_character()` can return early for missing NPC data, missing race
data, failed assembly, or missing skeleton
(`src/tools/world_explorer.gd:1514` to `src/tools/world_explorer.gd:1540`).

Because `PlayerController` only runs movement when both `_input_gatherer` and
`animation_system` exist (`src/core/player/player_controller.gd:279` to
`src/core/player/player_controller.gd:286`), a failed attachment can leave the
user in player camera mode with no active movement stack.

Recommended direction:

- Make `_attach_player_character()` return `bool`.
- Abort the mode switch and restore fly-camera mode when attachment fails.
- Log a clear user-facing reason so missing Morrowind data or broken character
  assembly does not look like a controller bug.

### P2: Crouch Changes Collision Height but Not Camera or Interaction Height

`CrouchMove` shrinks the player's capsule and moves the collision shape center
(`src/core/character/controller/moves/crouch_move.gd:96` to
`src/core/character/controller/moves/crouch_move.gd:105`), but
`PlayerController.camera_pivot` stays fixed at standing eye height
(`src/core/player/player_controller.gd:382`). The player-mode raycaster also
uses `camera_pivot` as its third-person ray origin
(`src/tools/world_explorer.gd:1054` to `src/tools/world_explorer.gd:1061`).

Impact: crouching can make the physical body shorter while first-person view,
third-person interaction reach, and line-of-sight behavior still behave as if
the player were standing. `_can_stand_up()` also uses a single upward ray
(`src/core/character/controller/moves/crouch_move.gd:108` to
`src/core/character/controller/moves/crouch_move.gd:119`), which can miss
ceiling obstructions near the capsule radius.

Recommended direction:

- Treat crouch as posture state that drives collision height, camera eye height,
  raycast origin, animation posture, and stand-up clearance from one config.
- Use a shape/capsule clearance test for stand-up rather than a single center
  ray.

### P2: Jump Has an Implicit Coyote Window

`PlayerInputGatherer` appends `jump` on any just-pressed jump action
(`src/core/character/controller/player_input_gatherer.gd:47` to
`src/core/character/controller/player_input_gatherer.gd:49`). Ground moves keep
choosing best input during their 0.1s airborne lockout before they transition
to `midair` (`src/core/character/controller/moves/run_move.gd:21` to
`src/core/character/controller/moves/run_move.gd:24`, same pattern in idle,
walk, sprint, and crouch).

Impact: pressing jump shortly after leaving the floor can still select
`JumpMove`. That may be desirable as coyote time, but today it is an accidental
consequence of the landing/midair lockout and flat priority system rather than
an explicit movement feature with a named budget.

Recommended direction:

- Decide whether coyote time is intended.
- If yes, move it into `CharacterMovementConfig` with a named duration and
  tests.
- If no, gate `jump` selection on an authoritative grounded/coyote context
  before adding it to the input package or before accepting `JumpMove`.

### P2: Visual Test Still Bypasses the Unified Input Contract

The project rule says visual/manual test scenes must use the unified InputMap
actions and avoid raw keycode loops (`AGENTS.md:279`). The character-controller
visual test still reads raw `event.keycode` for NPC presets and diagnostics
(`tests/visual/test_character_controller.gd:64` to
`tests/visual/test_character_controller.gd:75`). Its file header also says
`Ctrl = walk` while `project.godot` intentionally leaves `walk` unbound, and
the HUD says `V=camera` while the project binding is `toggle_camera` on Tab
(`tests/visual/test_character_controller.gd:4`,
`tests/visual/test_character_controller.gd:748` to
`tests/visual/test_character_controller.gd:751`, `project.godot:133` to
`project.godot:137`).

Impact: the validation scene does not fully validate the input system's
AZERTY/QWERTY/rebind contract and can mislead playtesters about actual controls.

Recommended direction:

- Add test-scene-specific InputMap actions for preset spawning and diagnostics,
  or document them as debug-only actions in `InputActions.VISUAL_TEST`.
- Update the help text to match `project.godot`.
- Keep movement, camera toggle, sprint, crouch, jump, and walk text aligned with
  `docs/systems/input_system.md`.

### P3: The Step-Up Solver Is Promising but Needs Contract Tests

`MoveContainer._move_with_step_up()` is thoughtfully documented and explicitly
references HL2/OpenMW/UE-style step probing
(`src/core/character/controller/move_container.gd:130` to
`src/core/character/controller/move_container.gd:168`). This is a good
canonical-pattern direction.

The risk is that most of its behavior is currently protected by comments rather
than scenario tests. It performs several manual `global_position` warps during
physics (`src/core/character/controller/move_container.gd:235`,
`src/core/character/controller/move_container.gd:252`,
`src/core/character/controller/move_container.gd:286`), which can be correct
for a pre-move probe, but should be guarded by tests because the project has
already had physics-interpolation and carry-vibration regressions.

Recommended direction:

- Add focused visual or automated scenes for: small step, tall wall, angled
  wall, ceiling-blocked step, down-step with no floor, and rigidbody obstacle.
- Record expected behavior in `docs/systems/character_controller.md` or a
  feature validation doc.

### P3: Move Timing Is Wall-Clock Based and Step Movement Ignores Passed Delta

Move duration helpers use `Time.get_unix_time_from_system()`
(`src/core/character/controller/move.gd:179` to
`src/core/character/controller/move.gd:186`). That makes state timing depend on
wall-clock time rather than deterministic simulation time. Separately,
`MoveContainer.process(input, delta)` accepts a frame delta
(`src/core/character/controller/move_container.gd:80`), but
`_move_with_step_up()` recomputes delta with
`get_physics_process_delta_time()` (`src/core/character/controller/move_container.gd:177`).

Impact: lockouts, jump-to-midair timing, combo windows, slow motion, pause
behavior, and deterministic replay/testing will be harder to reason about than
they need to be.

Recommended direction:

- Accumulate move-local elapsed time from the physics `delta` passed into
  `MoveContainer.process()`.
- Pass the same delta through `_move_with_step_up(delta)` so all movement work
  uses one simulation timestep source.

### P3: Main Scene Integration Is Partial and Still a Separate Risk

The status docs say the controller is working in
`tests/visual/test_character_controller.tscn` but is not wired into the main
streaming scene (`docs/systems/character_controller.md:5`,
`docs/STATUS.md:35`). Code inspection shows that this is stale:
`src/tools/world_explorer.gd` now creates a `PlayerController`,
`InteractionRaycaster`, and `CarryController`, and toggles between fly camera
and player mode (`src/tools/world_explorer.gd:1017` to
`src/tools/world_explorer.gd:1104`, `src/tools/world_explorer.gd:1375` to
`src/tools/world_explorer.gd:1448`).

The risk remains because the integration has not been verified as a complete
main-scene path with streaming, interaction, carry, interiors, water, and real
content together. The docs should be updated from "not wired" to "partially
wired; validation pending."

Recommended direction:

- Do not call the controller production-ready until a main-scene smoke pass
  exists.
- The first integration pass should test movement, camera, interaction raycast,
  carry release, water entry/exit, and streaming cell boundaries in one scene.
- Update `docs/STATUS.md` and `docs/systems/character_controller.md` after the
  smoke pass so they reflect the real integration state.

## Spec-Driven Assessment

Generic framework boundary:

- Partial. The Move-as-Node structure is reusable, but Morrowind-style movement
  behavior and hard-coded tuning live in generic move scripts.

Modding and content-extension boundary:

- Partial. Current values are exported in several places, but there is no
  single moddable movement config resource or override model.

Godot-native features:

- Mostly good. `CharacterBody3D`, `move_and_slide()`, `InputMap`, `SpringArm3D`,
  and `Area3D` are the right native pieces.

OpenMW as compatibility reference:

- Good direction for slope/step references, but future implementation work
  should cite exact OpenMW source files or settings when copying formulas or
  constants into a Morrowind adapter.

Documentation:

- Better than average. The system doc and baseline tests are valuable.
  Remaining gap: document the intended ownership split after movement is moved
  out from under animation.

Validation:

- Partial. The visual scene exists and baseline unit tests exist, but the known
  baseline defects are still live and the visual test has layer-convention,
  input-contract, and help-text drift. Main-scene player mode is partially wired
  but lacks an explicit smoke pass that covers streaming, carry, interiors, and
  water together.

## Recommended Repair Plan

1. Create `CharacterMovementConfig`.
   - Own movement speeds, jump, crouch, air control, swim, turn policy, backward
     movement, stamina costs, step height, and Morrowind compatibility toggles.
   - Make it a Resource so presets and mods can override it.

2. Move movement ownership out of animation.
   - Introduce a generic `CharacterMotor` or make `PlayerController` own
     `MoveContainer`.
   - Animation should observe movement state and transition animations.

3. Fix the baseline defects in one small pass.
   - Duplicate rigidbody push becomes one push pass.
   - Moving crouch resolves to crouch locomotion.
   - Swim pitch receives water state before vertical input is calculated.
   - Walk default is either bound or honestly documented as unbound.

4. Convert Morrowind behavior into a preset/adapter.
   - Put OpenMW-informed settings such as turn-to-movement, smooth movement,
     swim upward correction, and slope/step constants in a Morrowind-specific
     config layer.
   - Keep generic moves free of Morrowind-specific assumptions.

5. Strengthen validation before main-scene integration.
   - Update `tests/unit/test_character_controller_phase0_baseline.gd` as each
     known defect is fixed.
   - Align `tests/visual/test_character_controller.gd` with production collision
     layers and unified InputMap actions.
   - Add a main-scene smoke checklist before declaring the controller integrated.
   - Include player-mode attachment failure, carry across interior transitions,
     crouch camera/raycast height, jump/coyote timing, and water entry/exit in
     that checklist.

## Sources

- OpenMW game settings:
  https://openmw.readthedocs.io/en/stable/reference/modding/settings/game.html
- OpenMW default settings:
  https://raw.githubusercontent.com/OpenMW/openmw/master/files/settings-default.cfg
- OpenMW MWPhysics generated source docs:
  https://openmw.github.io/namespaceMWPhysics.html
