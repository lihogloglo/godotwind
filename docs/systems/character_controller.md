# Character Controller

## Status (2026-04-18)

Working in `tests/visual/test_character_controller.tscn`: ground locomotion (idle/walk/run/sprint/crouch), jump/midair with air control, and swimming (buoyancy + 3D camera-relative motion). **NOT yet wired into the main scene** — integration with `scenes/Godotwind.tscn` is pending. Planned next: stagger/interrupt (Phase 4), basic climbing (Phase 5), flying toggle (Phase 6).

---

Move-as-Node state machine pattern (adapted from Gab-ani's Universal Controller).

## Architecture

```
PlayerController (CharacterBody3D, 624 lines)
 └─ MoveContainer (state machine orchestrator)
     ├─ IdleMove (priority 0)
     ├─ WalkMove (priority 1)
     ├─ RunMove (priority 2, default ground locomotion)
     ├─ SprintMove (priority 3)
     ├─ CrouchMove (priority 4)
     ├─ JumpMove (priority 5, → MidairMove after 0.1s)
     ├─ MidairMove (priority 5, gravity + air control)
     ├─ SwimIdleMove (priority 6, buoyancy)
     └─ SwimMove (priority 7, 3D camera-relative)
```

Each Move is a Node that owns its movement physics, animation transitions, and transition logic.
`InputPackage` carries per-frame input data (direction, actions, water state, camera basis).

## Key Parameters

| Parameter | Value |
|-----------|-------|
| Run speed | 5.0 m/s |
| Walk speed | 2.5 m/s |
| Sprint speed | 8.0 m/s |
| Swim speed | 3.5 m/s |
| Jump velocity | 4.5 |
| Gravity | 9.8 (ProjectSettings) |
| Player height | 1.8m (CapsuleShape3D) |
| Player radius | 0.35m |
| Floor max angle | 50° (steep MW terrain) |
| Floor snap length | 0.3m |
| Camera distance | 3.5m (SpringArm3D, third-person) |

## Movement Physics

- **CharacterBody3D** with Jolt Physics backend
- `move_and_slide()` centralized in MoveContainer (not per-Move)
- Y velocity preserved across Move transitions (jump while running works)
- Backward movement at 70% speed when input >120° from facing direction
- Playback speed scales with velocity ratio to reduce foot sliding

## Move Transitions

Priority-based: each Move implements `check_relevance(input) → StringName`.
- Returns move name to transition to, or `&"okay"` to stay
- `best_input_that_can_be_paid(input)` picks highest-priority affordable move
- Combat overrides via `try_force_move()` (stagger, hit reactions)
- 0.1s lockout after landing prevents Jolt bounce-induced re-jumps

## Water Detection

Two sources:
1. **Ocean** — `GerstnerMath.get_height(position, time)` sampled every frame
2. **Static water volumes** — Area3D colliders trigger `enter_water_volume()` / `exit_water_volume()`

Flags injected into InputPackage: `is_in_water`, `water_surface_y`.
SwimMove uses buoyancy (strength 4.0, drag 2.0, submersion depth 1.2m).

## Camera

First/third-person toggle (Tab):
- **Third-person:** SpringArm3D at 3.5m, character visible, LookAt IK targets POIs
- **First-person:** SpringArm at 0.0m, character hidden, mouselook only

## Animation Wiring

- PlayerController holds `animation_system` reference
- Each Move calls `animator.transition_to(state_name)` on enter
- MoveContainer calls `animation_system.process_moves(input, delta)` per frame
- Speed scale set via `animator.set_speed_scale(velocity_ratio)`

## Test Scene

`tests/visual/test_character_controller.tscn` — flat terrain with ramp, climbing wall, water pool, 6 NPC presets (keys 1-5), debug HUD (F1).

## Key Files

- `src/core/player/player_controller.gd` — Main controller
- `src/core/character/controller/move.gd` — Move base class
- `src/core/character/controller/input_package.gd` — Input data
- `src/core/character/controller/moves/*.gd` — 9 concrete moves
