# Character Controller

## Status (2026-05-15)

Working in `tests/visual/test_character_controller.tscn`: ground locomotion
(idle/walk/run/sprint/crouch), jump/midair with air control, and surface-level
swimming (buoyancy + 3D movement-reference motion). Intentional diving /
below-surface swimming is not implemented yet; track that missing feature under
`spec-driven/features/subsurface-swimming/`.

`scenes/Godotwind.tscn` has partial player-mode wiring through
`src/tools/world_explorer.gd`, including `PlayerController`,
`InteractionRaycaster`, and `CarryController`. Human/user Phase 7 smoke testing
confirmed the core player path works for fly-camera to player-mode toggle,
movement, sprint, jump, crouch, first/third-person camera toggle, and streaming
cell boundary crossing. A follow-up Phase 7 smoke also confirmed the main-scene
water path works. Updated Godot log/error review found no script errors and no
controller, input, interaction, player, animation, water, or swim
warnings/errors during the tested path. Productionization is complete for
available content. Interaction, carry/drop/throw, and interiors are blocked
future integration gates because those dependent systems/content paths are not
yet complete enough to exercise in the main scene.

Codex runtime limitation: Codex cannot reliably launch the Godot engine from
this desktop workspace. The human/user must run Godot editor/runtime checks and
gdUnit; Codex should provide exact commands and checklists and record the
reported results.

Phase 1 of `spec-driven/features/character-controller-productionization/` fixed
the small current-architecture defects from the audit:

- rigidbody push now runs once per movement frame;
- water context reaches input gathering before swim pitch is computed;
- moving crouch wins over run/sprint;
- `walk` remains intentionally unbound by default;
- visual-test help text matches the actual Tab camera toggle;
- player-mode switch aborts safely when character attachment fails.

Phase 2 added `CharacterMovementConfig` as the single source for movement
tuning. Phase 3 moved movement ownership into `CharacterMotor`: the player /
character stack now owns input gathering, `MoveContainer`, and `MovementState`,
while animation observes the published state.

Phase 4 has implemented deterministic timing, posture coherence, and explicit
jump grace. Move elapsed time now accumulates from the physics delta supplied by
`CharacterMotor` / `MoveContainer`, and the movement helpers use that same
delta source. Crouch posture now drives the public movement snapshot and camera
eye height from `MovementState.posture`; the main-scene interaction ray origin
follows because it is attached to `PlayerController.camera_pivot`. Coyote time
and jump buffering are now named config fields instead of accidental side
effects of the ground-to-midair lockout.

Phase 5 has started centralizing gameplay physics layer contracts. Layer role
bits now live in `src/core/physics/gameplay_physics_layers.gd` as a small
preloaded helper, not an autoload. `CarryController` no longer assumes the
player is always only on physics layer 2: while an item is held, its saved
collision mask is rewritten to exclude the player's current `collision_layer`,
then restored exactly on release. Human-run gdUnit validation passed in
`reports/report_206/results.xml`; carry-through-interior manual validation is
blocked until an integrated playable path has both usable carryable items and
interiors/seamless doorways available.

Post-Phase 7 hardening through Phase 6 is implemented and human-validated for
the focused controller path. `reports/report_215/results.xml` passed the
character-controller baseline suite with 51 tests, 0 failures, 0 errors, and
0 skipped, including the scripted Phase 6 step-solver fixture. Human/user also
confirmed `tests/visual/test_character_controller.tscn` and
`tests/visual/test_teleport_interpolation_reset.tscn` work. Available-content
main-scene smoke passed for fly/player switching, movement, sprint, jump,
crouch, camera toggle, streaming boundary crossing, water, and controller-scope
log review. Main-scene interact/carry/prompt and teleport/interior checks are
blocked future integration gates until those paths are implemented in the
scene. There is no Phase 8 in the character-controller productionization
package.

---

Move-as-Node state machine pattern (adapted from Gab-ani's Universal
Controller).

## Architecture

```text
PlayerController (CharacterBody3D)
  -> CharacterMotor
      -> PlayerInputGatherer
      -> MoveContainer (state machine orchestrator)
          -> IdleMove (priority 0)
          -> WalkMove (priority 1)
          -> RunMove (priority 2, default ground locomotion)
          -> SprintMove (priority 3)
          -> CrouchMove (priority 4)
          -> JumpMove (priority 5, to MidairMove after 0.1s)
          -> MidairMove (priority 5, gravity + air control)
          -> SwimIdleMove (priority 6, buoyancy)
          -> SwimMove (priority 7, 3D movement-reference)
```

Each Move is a Node that owns its movement physics and transition logic.
`InputPackage` carries per-frame input data: direction, actions, water state,
movement basis, and movement pitch. `MoveContainer` publishes a
`MovementState` snapshot after processing. Animation reads that snapshot and
chooses animation transitions; it no longer creates or owns the movement state
machine.

## Movement State Semantics

`MovementState` is the public read model for animation, camera, interaction,
debug UI, and future gameplay code. Its jump-family fields are intentionally
split:

- `is_jump_move`: true only during the actual jump launch move.
- `is_airborne`: true during either jump launch or normal midair/falling.
- `is_jumping`: legacy compatibility alias for jump-family airborne state;
  do not treat it as "upward velocity."

## Key Parameters

The source of truth is `CharacterMovementConfig`.

| Parameter | Value |
|-----------|-------|
| Run speed | 5.0 m/s |
| Walk speed | 2.5 m/s |
| Sprint speed | 8.0 m/s |
| Swim speed | 3.5 m/s |
| Swim minimum feet submersion | 0.35m |
| Swim jump velocity | 2.4 m/s |
| Swim jump repeat time | 0.45s |
| Jump velocity | 4.5 |
| Coyote time | 0.10s default, 0.06s Morrowind preset |
| Jump buffer time | 0.12s default, 0.08s Morrowind preset |
| Ground-to-midair lockout | 0.10s bounce/contact guard |
| Gravity | 9.8 (ProjectSettings) |
| Player height | 1.8m (CapsuleShape3D) |
| Player radius | 0.35m |
| Standing eye height | 1.7m |
| Crouch eye height | 1.58m |
| Floor max angle | 50 degrees (steep MW terrain) |
| Floor snap length | 0.3m |
| Camera distance | 3.5m (SpringArm3D, third-person) |

Default preset:

```text
src/core/character/controller/movement_presets/default_movement_config.tres
```

Morrowind-informed preset:

```text
src/core/character/controller/movement_presets/morrowind_movement_config.tres
```

Override order for current Phase 3 runtime:

1. `PlayerController.movement_config`
2. `CharacterMotor.movement_config`
3. `MoveContainer.movement_config`
4. framework default preset

The old `PlayerController` speed exports are compatibility mirrors populated
from `movement_config` in `_ready()`. They are no longer the movement source of
truth.

### Movement Config Field Status

Every exported `CharacterMovementConfig` field is classified in
`CharacterMovementConfig.get_exported_field_statuses()` as either `active` or
`reserved`. Active fields are read by runtime movement, controller setup, or
tests. Reserved fields stay exported for resource compatibility but are not
runtime behavior yet; presets should not set them as if they are live tuning.

Active fields:

```text
walk_speed, run_speed, sprint_speed, crouch_speed,
walk_turn_speed, run_turn_speed, sprint_turn_speed,
walk_tracking_angular_speed, ground_tracking_angular_speed,
swim_tracking_angular_speed, turn_to_movement_direction,
backward_angle_degrees, backward_speed_multiplier,
jump_velocity, jump_min_time, ground_to_midair_lockout, coyote_time,
jump_buffer_time, air_control, air_speed,
standing_height, crouch_height, player_radius, standing_eye_height,
crouch_eye_height, stand_up_clearance_margin,
swim_speed, swim_acceleration, swim_buoyancy_strength, swim_drag,
swim_idle_drag, swim_submersion_depth, swim_min_feet_submersion,
swim_jump_velocity, swim_jump_repeat_time,
max_floor_angle_degrees, floor_snap_length, step_up_height,
step_down_height, min_step_height,
can_walk, can_sprint, can_crouch, can_jump, can_swim
```

Reserved fields:

```text
smooth_movement, smooth_player_turning_delay,
swim_upward_correction_enabled, swim_upward_coef
```

`turn_to_movement_direction = false` keeps input relative to the supplied
movement reference but prevents the model/player facing from auto-rotating
toward that movement direction. `PlayerController` uses a private runtime copy
of its movement config with this disabled, because player facing is owned by
mouse/controller look in first-person and fixed third-person follow. This makes
A/D strafe or side-step instead of spinning the actor toward the lateral input.
Animation selection still reads the same actor-relative `InputPackage` vector:
lateral input publishes `WalkLeft`/`RunLeft` or `WalkRight`/`RunRight`, crouch
publishes `Sneak*` states, swimming publishes `SwimWalk*`/`SwimRun*` states,
and diagonal input publishes explicit diagonal intent such as `RunForwardLeft`.
If a modded animation library does not provide diagonal clips, the animation
manager falls back to the nearest available cardinal state.
`step_down_height` now controls the down probe distance after a candidate
step-up, and `min_step_height` rejects tiny upward snaps that should remain
normal slide/floor-snap behavior. Godot's own `floor_max_angle` and
`floor_snap_length` remain the native slope/floor-stick controls; the step
solver only handles obstacle step-up candidates around that `move_and_slide()`
path.

The reserved smoothing fields need a future movement-feel spec before they
become active because acceleration smoothing, turn delay, animation blending,
and camera response should be tuned together. The reserved swim-upward
correction fields are legacy compatibility hooks; current swimming uses
explicit movement pitch, buoyancy, surface clamping, and repeated swim-stroke
impulses instead.

## Movement Physics

- `CharacterBody3D` with Jolt Physics backend.
- `move_and_slide()` centralized in `MoveContainer`, not per Move.
- `PlayerController.teleport_to()` moves the body, resets Godot physics interpolation, and clears velocity so player-mode teleports do not render a one-frame streak.
- RigidBody push is a single pass after movement.
- Move elapsed time and movement helper timing come from the supplied physics
  delta, not wall-clock time.
- `MoveContainer` owns jump-grace timers from physics delta: coyote time tracks
  how recently the body was grounded, and jump buffering stores slightly early
  jump input until a valid grounded/coyote frame consumes it.
- Crouch collision height is still owned by `CrouchMove`, while camera/raycast
  eye height is driven from `MovementState.posture`.
- Swim movement keeps the player's feet below the water surface by at least
  `swim_min_feet_submersion`, preventing forward/up swim input from lifting the
  capsule out of water and flickering back to upright locomotion.
- Current swim movement is therefore surface-biased. The player cannot
  intentionally dive and continue swimming below the water surface yet. That is
  a separate planned feature, not part of the player-camera mode split.
- In water, the jump key is a repeated swim stroke, not a continuous upward
  axis. Holding jump applies `swim_jump_velocity` at
  `swim_jump_repeat_time` intervals, then buoyancy pulls the player back toward
  swim depth.
- Stand-up clearance uses a standing capsule shape overlap, not a single center
  ray, so edge-of-capsule ceiling blockers are represented.
- Y velocity is preserved across Move transitions.
- Backward movement threshold and multiplier come from
  `CharacterMovementConfig`.
- Playback speed scales with velocity ratio to reduce foot sliding.

## Move Transitions

Priority-based: each Move implements `check_relevance(input) -> StringName`.

- Returns move name to transition to, or `&"okay"` to stay.
- `best_input_that_can_be_paid(input)` picks the highest-priority affordable
  move.
- Combat overrides use `try_force_move()`.
- `ground_to_midair_lockout` remains a bounce/contact guard. It no longer acts
  as accidental coyote time; eligible coyote/buffered jump input can still win
  before ground moves transition to `MidairMove`.

## Water Detection

Two sources:

1. Ocean: `OceanManager.get_wave_height(position)` sampled every frame, matching
   the same water-height contract used by buoyant objects.
2. Static water volumes: `Area3D` colliders trigger `enter_water_volume()` /
   `exit_water_volume()`.

`PlayerController` passes `is_in_water` and `water_surface_y` into
`PlayerInputGatherer.gather_input(is_in_water, water_surface_y)` before vertical
swim intent is computed. `SwimMove` uses buoyancy (strength 4.0, drag 2.0,
submersion depth 1.2m).

## Camera

First/third-person toggle (Tab):

- Third-person: `SpringArm3D` at 3.5m, character visible, LookAt IK targets POIs.
- First-person: SpringArm at 0.0m, character hidden.
- Vanity/orbit: hold Tab to temporarily switch into third-person vanity/orbit.
  A short Tab press still toggles first/fixed-third person. Gamepad can enter
  vanity directly with RS click.

Player camera modes are being split under
`spec-driven/features/player-camera-modes/`. `PlayerInputGatherer` receives
explicit movement basis/pitch providers from `PlayerController` through
`CharacterMotor`. Movement consumers read `InputPackage.movement_basis`;
`camera_basis` remains only as a synced compatibility alias during the
transition. Normal `THIRD_PERSON` now routes mouse/controller yaw into the
actor-facing node (`character_root` when attached, otherwise the player body)
and keeps `camera_pivot` yaw aligned behind that facing. Phase 3 adds
`THIRD_PERSON_VANITY`: it stores separate visual orbit yaw/pitch, returns to
the last primary camera mode on release, and keeps swim/movement pitch on the
primary look pitch so vanity tilt cannot create vertical swim intent. Keyboard
entry uses the OpenMW-style held Tab behavior, including holding Tab from first
person to enter third-person vanity temporarily. Human-run gdUnit verification
passed in `reports/report_220/results.xml` with 71 tests, 0 failures, 0 errors,
and 0 skipped. Human/user visual gameplay testing on 2026-05-15 reported that
the fixed-follow camera and held-Tab vanity behavior work well in game. The
next player-camera mode step is Phase 4: first-person cleanup and swim-pitch
visual acceptance.

## Animation Wiring

- `PlayerController` holds an `animation_system` reference.
- `CharacterMotor` publishes `MovementState` after movement processing.
- `PlayerController` calls `animation_system.update_from_movement_state(state)`
  when animation exists.
- `CharacterAnimationSystem` no longer creates a `MoveContainer` and movement
  still works when no animation system is attached.
- Directional locomotion states are selected from actor-relative input, not
  from auto-turning the actor. Side-step clips are `WalkLeft`/`WalkRight` and
  `RunLeft`/`RunRight`; diagonal states preserve intent for modded clips and
  fall back to cardinal Morrowind groups when only vanilla-style clips exist.

## Test Scene

`tests/visual/test_character_controller.tscn` is a flat terrain scene with a
ramp, climbing wall, water pool, NPC presets, pushable physics objects, and
debug HUD. Scene-specific controls use InputMap actions:
`character_controller_preset_1..5`,
`character_controller_toggle_debug_hud`, and
`character_controller_dump_kf_bones`.

`tests/visual/test_character_controller_steps.tscn` is the focused Phase 6
step-solver measuring rig. It avoids Morrowind data and animations, uses a
capsule-only `PlayerController`, and labels six obstacle lanes: small step,
tall wall, angled wall, ceiling-blocked step, edge lip/no landing, and
rigidbody obstacle. The edge-lip lane should not create an artificial stair
snap across empty space, but normal falling off the edge is allowed. Falling
below the panels respawns the player at the start, and the
`step_solver_respawn` InputMap action (`R` by default) can be pressed for a
manual reset.

Controls:

- WASD: move
- Shift: sprint
- Space: jump
- C/Ctrl: crouch
- Tab: tap first/third-person camera, hold vanity
- 1-5: spawn preset NPCs
- F1: debug HUD
- F2: dump KF comparison

`walk` exists in `project.godot` but is intentionally unbound by default per
`docs/systems/input_system.md`.

## Phase 0-3 Verification Harness

`tests/unit/test_character_controller_phase0_baseline.gd` is the lightweight
unit-test harness for the controller cleanup plan. It intentionally avoids
Morrowind data, meshes, scenes, and animation libraries so failures point at
movement-input logic rather than asset setup.

The harness started as a baseline around audit findings. Phase 1 updated the
fixed defects into new contracts:

- one rigidbody push pass;
- moving crouch resolves to crouch;
- water-aware swim pitch is computed during input gathering;
- `walk` is intentionally present but unbound by default.
- config values drive run speed, jump velocity, backward speed multiplier,
  sprint capability, and step height.
- Phase 3 ownership: `CharacterMotor` can process movement without animation,
  `PlayerController` attaches a motor when animation is null, and animation can
  observe `MovementState`.
- Phase 4 jump grace: coyote time accepts a jump shortly after ground loss,
  expired coyote time rejects late jump, and jump buffering fires on a landing
  frame.
- Water visual regression coverage: midair re-entry into water selects swim
  state again, Morrowind-style spaced swim animation names resolve, and failed
  animation transitions are retried instead of being cached as handled.
- Swim jump coverage: in-water jump input is treated as repeated swim-stroke
  impulse intent rather than continuous vertical input.
- Post-Phase 7 hardening: player/fly teleport helpers reset interpolation, and
  public carry release restores a valid body even if the pickup wrapper is
  missing.

For editor-side validation, human/user runs:

```text
tests/run_character_controller_phase0.tscn
```

After the run, check the newest gdUnit report:

```text
reports/report_<number>/results.xml
reports/report_<number>/index.html
reports/report_<number>/test_suites/tests.unit.test_character_controller_phase0_baseline.html
```

Latest known player camera mode report: `reports/report_220/results.xml`
passed with 71 tests, 0 failures, 0 errors, and 0 skipped. This includes the
Phase 2 fixed-follow/directional-animation contracts and the Phase 3 held
Tab/vanity contracts.

Latest known Phase 4 posture-slice report: `reports/report_204/results.xml`.
The character-controller suite passed with 24 tests, 0 failures, and 0 errors,
including camera posture, interaction ray-origin posture, crouch posture
publication, and the physics-delta elapsed-time contract. The prior full unit
report still had unrelated rendering/object-paging failures outside the
character controller.

Latest known Phase 4 jump-grace report: `reports/report_205/results.xml`.
The character-controller suite passed with 29 tests, 0 failures, and 0 errors,
including coyote-time defaults, coyote acceptance, expired-coyote rejection,
jump buffering on landing, and immediate grounded jump when buffering is set to
zero. Human/user also tested the jump-grace behavior in game and reported it
works.

Human/user visually tuned crouch first-person eye height to `1.58m` and
reported that value feels correct. Human/user also completed the posture visual
checks: interaction prompt/raycast origin lowers with crouch, standing restores
it, and low ceilings near the capsule edge block standing.
Phase 4 jump-grace automated and in-game validation are complete.

Latest known Phase 5 layer-contract report: `reports/report_206/results.xml`.
The character-controller suite passed with 32 tests, 0 failures, and 0 errors,
including no-autoload layer helper usage, held-mask exclusion for fake player
layer rewrites, and exact release mask restoration.

Latest known water regression report: `reports/report_207/results.xml`.
The character-controller suite passed with 38 tests, 0 failures, and 0 errors,
including swim re-entry state recovery, swim surface clamping, in-water
jump-as-impulse input, held swim-jump repeat behavior, spaced swim animation
name resolution, and retry after failed animation transitions. Human/user also
completed the visual re-test and confirmed held jump while swimming now bobs
upward, falls back down, and repeats instead of pinning the character near the
top.

Phase 6 adds a visual-scene surface contract:
`test_phase6_step_visual_scene_exposes_required_cases`. Human/user reported the
character-controller tests pass after the Phase 6 scene-surface contract and
respawn action; expected result is 39 tests, 0 failures, and 0 errors. Human/user
also completed the six-lane step visual pass after scene clarity fixes. No step
solver tuning or architecture changes were needed.

## Key Files

- `src/core/player/player_controller.gd`: main player controller
- `src/core/character/character_motor.gd`: movement owner
- `src/core/character/controller/movement_state.gd`: public movement snapshot
- `src/core/character/controller/move.gd`: Move base class
- `src/core/character/controller/input_package.gd`: input data
- `src/core/character/controller/character_movement_config.gd`: movement tuning resource
- `src/core/physics/gameplay_physics_layers.gd`: shared gameplay physics layer roles
- `src/core/character/controller/player_input_gatherer.gd`: InputMap reader
- `src/core/character/controller/move_container.gd`: move orchestration
- `src/core/character/controller/moves/*.gd`: concrete moves
