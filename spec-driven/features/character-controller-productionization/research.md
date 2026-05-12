# Research: Character Controller Productionization

Date: 2026-05-10
Owner: Codex
Status: planning research, no runtime changes

## Inputs

- `docs/audit/character_controller_code_audit_2026_05_09_codex.md`
- `spec-driven/README.md`
- `spec-driven/00-constitution.md`
- `spec-driven/01-workflow.md`
- `docs/systems/character_controller.md`
- `docs/systems/input_system.md`
- `docs/systems/interaction_system.md`
- Official Godot 4.6 documentation for `CharacterBody3D`, physics interpolation, `ShapeCast3D`, and `InputMap`
- OpenMW settings and MWPhysics references for Morrowind-compatible movement behavior

## Current Finding

The controller is not blocked by one mystery bug. It is blocked by mixed ownership:

- `PlayerController` owns the body, camera, input, water injection, interaction, carry handoff, and public movement exports.
- `CharacterAnimationSystem` owns the actual `MoveContainer`.
- Individual move nodes own hard-coded tuning values.
- Generic move files contain Morrowind-style behavior that should be a preset or adapter.

That makes animation required for movement, inspector settings unreliable, and modding boundaries unclear.

## Canonical Pattern

Use Godot's native character-body stack as the foundation:

- Keep the player body as `CharacterBody3D`.
- Drive body motion from `_physics_process()` through `move_and_slide()`.
- Keep physics timestep behavior deterministic by using the delta passed through the physics tick, not wall-clock time.
- Let physics interpolation smooth render frames, with deliberate camera carve-outs only where render-rate look is required.
- Use shape sweeps/overlap checks for capsule-sized stand-up clearance instead of a single ray.

Godot 4.6 docs confirm that `move_and_slide()` is the correct `CharacterBody3D` method for sliding movement and should be called from `_physics_process()` or a method called by it. The physics interpolation quick-start also says moved objects and game logic should run from `_physics_process()`, and teleports should reset interpolation to avoid visual streaking.

## Godot Constraints

- `CharacterBody3D.move_and_slide()` uses the physics-step delta internally, so the controller must call it from physics code.
- `ShapeCast3D` can perform immediate same-frame overlap checks with `target_position = Vector3.ZERO` and `force_shapecast_update()`, which is appropriate for crouch stand-up clearance. It is more expensive than a raycast, so this belongs on posture transitions, not every frame unless needed.
- `InputMap` is the right project-wide action source. `walk` is intentionally present but unbound today; plans should not silently bind it.
- Existing controller code is GDScript and mostly Godot-node orchestration. New code in the first repair phases should stay in GDScript for locality unless a later hot path justifies C#.

## Morrowind Compatibility Reference

OpenMW should inform presets, not generic framework architecture.

Relevant OpenMW settings:

- `turn to movement direction`
- `smooth movement`
- `smooth movement player turning delay`
- `swim upward correction`
- `swim upward coef`
- `normalise race speed`

Relevant OpenMW MWPhysics constants:

- `sMaxSlope = 49.0f`
- `sStepSizeUp = 34.0f`
- `sStepSizeDown = 62.0f`
- `sMinStep = 10.f`

Godotwind should translate these into a Morrowind movement preset/adapter. Generic controller code should speak in framework terms such as turn policy, backward speed multiplier, step height, swim correction, and movement profile.

## Recommended Direction

1. Stabilize the existing movement path first so the known baseline defects stop masking later architecture work.
2. Add `CharacterMovementConfig` as the single source of movement tuning.
3. Move `MoveContainer` ownership out of animation and into a generic motor owned by the player/character stack.
4. Make animation consume movement state instead of driving movement.
5. Make posture, camera, interaction ray origin, collision height, and animation state come from one posture model.
6. Centralize gameplay physics layer roles so carry, player, interaction, and interiors do not each encode their own layer assumptions.
7. Finish with a main-scene player-mode smoke pass before claiming production readiness.

## Phase 4 Jump Grace Research Slice

Date: 2026-05-10

Question: should the current ground-to-midair lockout become explicit coyote
time, remain only a bounce guard, or be replaced by a different jump-feel
contract?

### Modern Controller Standard

Modern forgiving controllers separate two windows:

- **Coyote time**: a short post-grounded grace window where a jump still counts
  after walking off an edge.
- **Jump buffering**: a short pre-grounded input window where an early jump press
  is stored and consumed on landing.

This is not only a platformer convention. Lens Studio's current Character
Controller exposes both as named milliseconds fields, with `0` disabling either
feature. Maddy Thorson's public Celeste notes also frame coyote time and jump
buffering as two examples of "widening timing or positioning windows" in the
player's favor. For Godotwind's target feel, these are better treated as generic
movement-config fields than as an accidental consequence of the active move
state.

Recommended generic defaults:

- `coyote_time = 0.10`
- `jump_buffer_time = 0.12`
- `ground_to_midair_lockout` remains separate as a bounce/contact guard.

The Morrowind-informed preset can tune these lower to preserve a heavier,
less platformer-like feel while still using the same generic controller
contract.

### Godot 4.6 Behavior

Godot's `CharacterBody3D.is_on_floor()` is a result from the last
`move_and_slide()` call. `floor_snap_length` keeps a grounded body attached to
slopes only while the body is moving against `up_direction`; it is not applied
while the body has rising vertical velocity, which is the correct behavior for
jumping. This means brief `is_on_floor()` transitions around slopes, ledges,
steps, and contact recovery should be treated as normal engine behavior, not as
the sole source of player intent.

Godotwind should therefore keep using `move_and_slide()` and floor snap for
physics, but own jump forgiveness in `MoveContainer` as deterministic timers
fed by the physics delta.

### OpenMW Reference

OpenMW's character controller starts jumps when the actor is grounded and has
positive vertical movement input, treats non-grounded actors as in-air, and uses
physics step/slope constants such as `sMaxSlope`, `sStepSizeUp`, and
`sStepSizeDown` for world contact behavior. The useful lesson is not "copy
classic Morrowind jump forgiveness"; it is to keep stepping/grounding and jump
state explicit.

For Godotwind, preserve Morrowind-adjacent feel through a preset:

- keep OpenMW-informed slope/step values;
- keep heavier movement/air-control defaults;
- tune coyote/buffer lower than the modern generic default if desired.

Crouch/stand does not need a separate input buffer in the current contract:
crouch is held state, and release-to-stand is naturally retried every frame
until capsule clearance succeeds. Adding a stand buffer would add hidden state
without solving a real missed-input problem.

## Sources

- Godot 4.6 `CharacterBody3D`: https://docs.godotengine.org/en/4.6/classes/class_characterbody3d.html
- Godot 4.6 physics interpolation quick start: https://docs.godotengine.org/en/4.6/tutorials/physics/interpolation/physics_interpolation_quick_start_guide.html
- Godot 4.6 `ShapeCast3D`: https://docs.godotengine.org/en/4.6/classes/class_shapecast3d.html
- Godot 4.6 `InputMap`: https://docs.godotengine.org/en/4.6/classes/class_inputmap.html
- OpenMW game settings: https://openmw.readthedocs.io/en/stable/reference/modding/settings/game.html
- OpenMW MWPhysics namespace docs: https://openmw.github.io/namespaceMWPhysics.html
- Godot `CharacterBody3D` source: https://raw.githubusercontent.com/godotengine/godot/master/scene/3d/physics/character_body_3d.cpp
- Lens Studio Character Controller: https://developers.snap.com/lens-studio/features/games/character-controller
- Celeste & Forgiveness: https://www.mattmakesgames.com/articles/celeste_and_forgiveness/index.html
- OpenMW `CharacterController` source: https://raw.githubusercontent.com/OpenMW/openmw/master/apps/openmw/mwmechanics/character.cpp
