# Physics Tunneling (Fast Bodies Clip Through Collision) — Handoff

**Date:** 2026-04-22
**Branch:** `perf/distant-rendering-2026-04-17`
**Priority:** medium — correctness bug, user-visible during playtesting
**Status:** diagnosis only; no code changes yet

---

## Finding

Interactive pilot, Phase 4 T.2 live (commits `3acd4bd` + `ed61cc5`). Thrown `DebugBall` (RigidBody3D, 0.25m sphere, 5 kg, fired at 20 m/s) **sometimes clips through**:

1. The new per-cell merged trimesh collision (`StaticBody3D` + `ConcavePolygonShape3D`, containing ~27k-31k triangles per dense cell).
2. `Terrain3D`'s built-in heightmap collision.

User observation: "It seems to depend on the angle of the ball or its speed. Same for static objects."

This is the **classic swept-collision tunneling problem** — a fast-moving rigid body skips past a thin collider between discrete physics ticks. Not a bug in T.2 or Terrain3D; a physics-parameterization issue that was already latent for the terrain and is now more visible because T.2 added collider surfaces.

---

## Root cause math

- Ball velocity: 20 m/s (set at spawn in [world_explorer.gd:2578](../../src/core/player/../tools/world_explorer.gd#L2578))
- Ball radius: 0.25 m (diameter 0.5 m)
- Physics tick rate: 60 Hz (Godot default — not overridden in `project.godot`)
- Distance per physics step: `20 / 60 ≈ 0.33 m`

At the default tick rate, the ball moves **0.33m per physics step**. If a wall, rock face, or terrain slope is thinner than ~0.17m (half ball diameter minus half step distance), the body's position discretely jumps from "in front of" to "behind" the collider without ever intersecting it. Jolt's discrete solver doesn't see a penetration → no contact → no reflection.

Many Morrowind geometry primitives (`ConcavePolygonShape3D` walls, single-quad decorative panels, thin fence railings) are effectively zero-thickness triangles in the merged trimesh. Angle dependence is consistent: ball traveling perpendicular to a thin face tunnels more often than ball traveling parallel to it.

---

## Canonical fix — Continuous Collision Detection

Godot's `RigidBody3D` has a per-body CCD toggle:

```gdscript
ball.continuous_cd = true
```

With CCD on, Jolt sweeps the body's collision shape along its motion vector each step instead of just checking the discrete end position. Catches tunneling; costs more per-body physics time. Industry standard for projectiles, bullets, fast vehicles.

**Where to apply:**

1. **Debug ball** ([world_explorer.gd `_spawn_debug_ball`](../../src/tools/world_explorer.gd#L2547)) — trivial add, eliminates the diagnostic symptom immediately. Use this first to confirm CCD is the fix before rolling out broader.
2. **Carryables** (thrown / dropped MW items) — when `carryable_body_factory.convert_static_to_rigid` creates the RigidBody3D, set `continuous_cd = true` on bodies where velocity-at-throw can exceed ~5 m/s (pretty much any pickup). See [src/core/interaction/carryable_body_factory.gd](../../src/core/interaction/carryable_body_factory.gd).
3. **Gameplay projectiles** (future — arrows, spells) — spawn always with CCD on. Arrows typically fire at 50-100 m/s which is guaranteed tunnel territory without it.

**What NOT to do:** don't enable CCD globally on every body. Static environment bodies don't need it (never move), and dynamic bodies that move slowly (furniture pushed by player) don't need the overhead. Per-body opt-in is the Jolt/Godot canonical pattern.

---

## Alternative / complementary options

### 1. Increase the physics tick rate

```
# project.godot [physics]
common/physics_ticks_per_second=120
```

Halves the distance-per-step. Ball at 20 m/s at 120 Hz moves 0.17 m/step → only tunnels through walls thinner than ~0.08m (rare). Costs 2x physics CPU globally; hits EVERY body, not just projectiles.

Trade-off: CCD is targeted (per-body). Tick-rate bump is blanket. Prefer CCD; consider tick-rate bump only if the player also tunnels (character controller is a `CharacterBody3D` with `move_and_slide`, which has its own slide logic and shouldn't tunnel — but verify if complaints emerge).

### 2. Speed clamp at the body level

```gdscript
func _integrate_forces(state):
    var v := state.linear_velocity
    if v.length_squared() > MAX_V_SQ:
        state.linear_velocity = v.normalized() * MAX_V
```

Prevents tunneling by keeping speed under the per-step distance threshold. Useful for AI-controlled bodies but feels bad for player-thrown items (why can't I throw a rock hard?). Use as a safety net, not a primary fix.

### 3. Thicker collision shapes at prebake

For static trimesh content: at prebake time, "thicken" zero-thickness walls by extruding triangles along their normals by a small amount (0.05-0.10m). Hides inside the visible geometry but gives tunneling a bigger target. ~200 LOC delta in `nif_collision_builder.gd` + rebake. Last-resort, heavy, and interacts poorly with the user's existing per-prototype shape cache.

### 4. Jolt-specific: MotionType + CCD

Jolt has a dedicated fast-mover mode — `JPH::EMotionQuality::LinearCast`. Godot's `continuous_cd` property wraps this. No extra knobs needed in Godot; option 4 is just "enable continuous_cd on the body" (same as §1 above). Listed for reference.

---

## Recommended order of attack

1. **Add `ball.continuous_cd = true`** at [world_explorer.gd:2556](../../src/tools/world_explorer.gd#L2556) (one line). Interactive test — throw balls at rocks, walls, terrain slopes. Confirm tunneling rate drops to near-zero. This is the diagnostic pass — proves CCD is the right knob.
2. **Apply to carryables** in `carryable_body_factory.convert_static_to_rigid`. Playtest picking up + throwing MW items (silverware, books, potions) — should now bounce correctly.
3. **Benchmark physics time** with `--bench-auto` comparing pre/post CCD on the ball. Measure `phys=Xms` in the heartbeat. Expected delta: ~1-3ms per active carryable under CCD. Acceptable.
4. **Do NOT** increase physics tick rate until CCD is verified insufficient. The per-body opt-in is simpler, cheaper, and better-scoped than a global doubling.
5. **Thin-wall extrusion** at prebake is a deep rabbit hole — only pursue if CCD + all other options fail for specific content (e.g. a particular NIF that users keep clipping through even with CCD on).

---

## Measurement protocol

Add to each phase of the fix:

1. Interactive launch of `scenes/Godotwind.tscn`.
2. Spawn debug ball repeatedly at Seyda Neen / Balmora near rocks, walls, arches.
3. Count visual tunnel events out of 20 throws. Baseline (pre-CCD) appears to be 5-10/20 (user's "sometimes"). Target (post-CCD): 0-1/20.
4. Heartbeat should show `phys=Xms` jumps modestly under CCD (e.g. 15ms → 18ms with 10 active balls).

---

## Reference

- [Godot `RigidBody3D.continuous_cd`](https://docs.godotengine.org/en/stable/classes/class_rigidbody3d.html#class-rigidbody3d-property-continuous-cd) — one-sentence docs on the property.
- [Godot physics engine docs](https://docs.godotengine.org/en/stable/tutorials/physics/physics_introduction.html) — broad context.
- [Jolt Physics: Continuous Collision](https://jrouwe.github.io/JoltPhysics/#continuous-collision-detection) — the engine-side reference for what CCD actually does under the hood.
- Glenn Fiedler, [Fix Your Timestep](https://gafferongames.com/post/fix_your_timestep/) — canonical reference for physics-step timing. CCD is orthogonal to fixed-step timing but the mental model of "sub-step the physics" overlaps.

---

## Not in scope for this handoff

- Player (`CharacterBody3D`) tunneling — different API (`move_and_slide`) with its own slide/collision logic. If the player clips through walls, that's a separate investigation. No current complaint.
- Network/multiplayer prediction — not applicable, Godotwind is single-player.
- Raycast stuttering / picking inaccuracy — different system.
