# Lazy Jolt Activation — Godotwind 2026-04-19

**Status:** SUPERSEDED 2026-04-19 by `statics_no_node3d.md`. User locked terminal architecture over this middle-step. Kept for historical context — DO NOT IMPLEMENT. See `statics_no_node3d.md` §9.

**Prior status:** DRAFT v3 — 2026-04-19. Authored after the state-reversal fix (`cell_manager.finalize_unloaded_cell`, commit TBD) resolved the `cellupd:70-76ms` hitch + missing-objects-on-return bug. Remaining problem: `inst:13-60ms` overruns during cell-load bursts.
**v2 patch:** per @roaster plan review, reframed as explicit stepping stone toward the terminal "no Node3D for static geometry" pattern; see §9.
**v3 patch:** per @roaster v2 review — (a) §3.4 replaced AABB-fallback kludge with stored-shape resource variant; (b) added phase J.-0.5 (Jolt broadphase toggle verification) — don't lock §3.3 X-vs-Y on inference; (c) §3.2 cost breakdown clarified (walk vs toggle); (d) added Jolt broadphase active body count to §5 metrics; (e) J.0 now specifies dedicated `test_lazy_jolt_activation.tscn` for interactive verification.
**v4 patch:** per @user directive 2026-04-19 ("no over-engineering, minimum code, 240 FPS target"): reframed as SIMPLEST-FIRST. Phase J.-0.5 gates everything. If measurement shows `CollisionShape3D.disabled = true` (or `collision_layer = 0`) already evicts from Jolt broadphase, the entire fix collapses to **~50 LOC**: change the spawn-time gate from 150m to 50m + add a cell-crossing activation sweep. §3 design questions pruned to that single decision. See §10 (new) for the minimum-code path.
**Parent:** `near_tier_refactor.md` §S.6 (NEAR baseline acceptance gate)
**Bucket:** S.7+ pre-work — must land before MID / HLOD / IMPOSTORS re-enable so per-cell tier transitions don't re-amplify Jolt broadphase churn.

**Scope honesty (v2 patch):** this plan is a **stepping stone**, not the final architecture. Lazy Jolt + skip-spawn-when-distant is ~70% of the win that OpenMW / UE5 extract from distant statics. The remaining 30% requires eliminating the Node3D itself for static geometry (rocks, arches, clutter) and moving them to `RS.instance_create2` + per-cell merged trimesh bodies — the `static_object_renderer` + HLOD path we already have for flora. See §9 for the terminal state.

---

## 0. Session Resume Pointer

Read: §1 Problem → §2 Canonical Pattern → §3 Design Questions (user locks in §3.x). Skip §4 until design is locked.

**User directive, 2026-04-19 chat:** *"I think we ought to make Jolt activate only in a circle around 50m of the player."*

This plan is the implementation of that directive, framed as the canonical pattern OpenMW and UE5 already use.

---

## 1. Problem

After the state-reversal fix, frame overruns during cell-load bursts look like:

```
Frame overrun: 60.8ms [cellupd:0.0 unload:8.7 inst:60.8 ...]
Frame overrun: 35.0ms [cellupd:0.0 unload:0.0 inst:34.9 ...]
```

`cellupd` is 0 (fix worked). `inst:` is still the dominant cost. Breakdown per-object in `process_async_instantiation`:

1. `PackedScene.instantiate()` — engine C++ deserialization. **MAIN-THREAD-ONLY** per Godot docs (see CLAUDE.md anti-pattern #12). Cannot be shifted to worker threads. ~0.5-2 ms/object depending on tree size.
2. `add_child()` — scene-tree ancestor notifications. Main-thread. ~50-200 µs/object.
3. **Jolt broadphase insert** — every `StaticBody3D + CollisionShape3D` in the instantiated subtree registers with Jolt's BVH. ~100-500 µs/object for 1-3 shapes.
4. `_enable_collision_shapes_in_tree` recursion (if within 150m) — toggles `CollisionShape3D.disabled`. ~10 µs/shape.
5. Fade-in material setup — pooled, ~20 µs/object.

At 50 objects/frame, steps 1-3 give 30-75 ms — matches observed `inst:60.8ms`. Step 3 alone is 5-25 ms/frame for zero gameplay value when the object is 200m+ away (player can't touch it, no physics interaction possible).

**Current mitigation (inadequate):** `reference_instantiator._enable_collision_shapes_in_tree` gates collision enable to within `DU.NEAR_END = 150m` at spawn time. But this only sets `CollisionShape3D.disabled = true`; the `StaticBody3D + CollisionShape3D` nodes ARE still constructed and STILL registered with Jolt broadphase. Only active collision queries are cheaper. The spawn cost is paid regardless.

**Root cause:** we pay full Jolt broadphase insert for every static body regardless of distance. OpenMW and UE5 both defer body creation until an actor-relevance radius is breached.

---

## 2. Canonical Pattern

### 2.1 OpenMW

`PhysicsSystem::addObject()` is called per cell-ref at cell-activation time, but `btRigidBody` construction is gated by `OMWPhysicsActive` radius (~exterior cell size). Refs beyond that radius stay purely visual (osg::Geode draw). On camera approach, `addObject` is called; on departure, `removeObject` tears down the bullet body.

See: `apps/openmw/mwphysics/physicssystem.cpp::addObject`, `updateObject`.

### 2.2 UE5

`FBodyInstance::InitBody` gates physics creation behind distance + `UPhysicsSettings::bEnableEnhancedDeterminism` + `EBodyActivationPolicy`. World Partition HLOD meshes have no physics at all — only the FULL-tier cells get `UPhysicsSettings::MaxPhysicsDeltaTime` updates.

Engine docs: "Physics Body State Swap" under World Partition → HLOD streaming.

### 2.3 Bevy / avian3d

Similar: `Collider` component is added at spawn, but `RigidBody` activation gated by camera-relative zone. Distant statics register as colliders only (for raycast) and skip broadphase integration.

### 2.4 What they share

1. **Physics body lifecycle is decoupled from scene-graph lifecycle.** Object exists visually. Body exists only when physics interaction is plausible.
2. **Activation transitions are event-driven**, not per-frame-per-object. OpenMW fires on cell-crossing. UE5 fires on HLOD tier transition. Per-frame distance checks per-object are forbidden (O(N²)).
3. **Activation radius is tunable**, typically 2-5× player interaction range. OpenMW uses the cell size (~117m for MW). UE5 default is 100m.
4. **Held / active bodies are exceptions** — player-carried items, thrown items, doors mid-animation, ragdolls: body stays regardless of distance.

---

## 3. Design Questions (USER LOCK REQUIRED BEFORE §4)

### 3.1 Activation radius — **50m locked** per user chat 2026-04-19

Matches UE5 default. Below the visible NEAR footprint (~150m) so the activation ring is always inside the rendered ring. Future tuning: raise during combat / lower during dialogue.

### 3.2 Activation granularity

**Option A: per-cell.** Each cell has a `physics_tier: Tier` (OFF / ON). Transition fires on cell-boundary crossing. Simple, coarse. Activates a whole cell's worth of bodies (~150-250 objects) in one event.
- Pros: matches OpenMW exactly. Event rate = cell crossings (sparse).
- Cons: a cell can straddle the 50m radius; inner objects should activate but outer shouldn't. Over-activates by ~2×.

**Option B: per-object hysteresis, event-driven.** On cell-boundary crossing, walk all resident cell contents, enable collision for objects whose distance <50m, disable for >60m (10m hysteresis). No per-frame tick.
- Pros: precise, matches UE5 body-state-swap timing.
- Cons per cell-crossing event, broken down: 3×3 active cells × ~200 objects = 1800 distance checks. Pure Vector3 `distance_squared_to` on contiguous data ≈ 50 ns/check → **walk cost ≈ 90 µs steady-state**. Threshold crossings happen on ~5% of objects per event on normal walking speeds (hysteresis prevents thrash) → ~90 toggles × 100 µs each = **toggle cost ≈ 9 ms at the worst event, <1 ms typical**. So the "~1 ms" quoted earlier is the typical-case toggle cost; the walk itself is <100 µs. Worst-case (sprint across a dense cell) is bounded by the per-event work.

**Option C: per-object hysteresis, per-frame.** Each object tracks distance vs camera every frame; on crossing threshold, toggle body state.
- Pros: always correct.
- Cons: O(N) per frame on thousands of objects. Forbidden.

**Recommendation: B.** OpenMW's event-driven, UE5-aligned, precise, cheap. Locks the `inst:` overrun bounded to the activation ring (50m radius = ~1 cell). Worst-case 9 ms event is acceptable — happens only when sprinting through dense content and only on cell-crossing ticks.

**Question for user:** A or B? (C is rejected.)

### 3.3 Deactivation strategy

When an object exits the 50m+hysteresis ring, do we:

**Option X: disable CollisionShape3D but keep StaticBody3D.** Cheap toggle, body stays... *broadphase behavior UNVERIFIED*.
- Pros: trivial implementation. Current `_enable_collision_shapes_in_tree` pattern.
- Cons (IF Jolt keeps broadphase entry): 80% of intended savings lost.
- **Open:** does Godot 4.6 + Jolt's `CollisionShape3D.disabled = true` still register the parent body with broadphase? Or does setting `CollisionObject3D.collision_layer = 0` evict from broadphase (per @roaster v2 review)? Answer locks X vs Y. See J.-0.5 in §4.

**Option Y: free CollisionShape3D + StaticBody3D, keep mesh node.** Full teardown; body is re-created on re-activation.
- Pros: guaranteed broadphase eviction. Matches `Y` = maximum savings regardless of engine's `disabled`/`collision_layer` semantics.
- Cons: re-creation cost on activation. Need the shape resource retrievable — see §3.4.

**Recommendation: LOCK AFTER J.-0.5 MEASUREMENT.** If a single-flag toggle (collision_layer=0 or disabled=true) evicts from Jolt broadphase: X wins (simpler, same savings). If not: Y wins (full teardown). Do not lock on inference — this is a canonical-pattern verification step, not a nitpick.

**Question for user:** agree to gate X-vs-Y on J.-0.5 measurement? (If you want to pick without measurement, Y is the safe default — worst case it's identical to X, best case it's the only working option.)

### 3.4 Spawn-time defer

At `_instantiate_model_object`, should we:

**Option P: always build StaticBody3D, then immediately strip if >50m.** Current pattern inverted.
- Pros: simple, same code path.
- Cons: still pays StaticBody3D construction + immediate teardown cost. No Jolt savings at spawn.

**Option Q: skip StaticBody3D construction entirely if >50m. Store shape for re-creation.**
1. `_instantiate_model_object` runs the PackedScene instantiate normally (pays the ONE-TIME deserialize cost — unavoidable, this is engine C++ + we need the shape resource anyway).
2. If object position >50m from camera: walk the instantiated subtree, **extract every `CollisionShape3D.shape` resource** into `meta.stored_shapes` on the mesh root (array of `{shape: Shape3D, local_xf: Transform3D}`), then `queue_free` the `StaticBody3D` subtree. Mesh + LOD chain survives.
3. On activation event (§3.2 B): `new StaticBody3D` + one `CollisionShape3D.new` per meta-stored shape. ~150 µs/object total.

- Pros: eliminates Jolt broadphase register at spawn. Preserves **full collision shape fidelity** — exact NIF-baked shape re-materializes on approach. Matches the deferred-body pattern without the "phantom box" kludge.
- Cons: spawn-time deserialize cost is NOT eliminated (we still instantiate + inspect the shape). The savings are purely on the Jolt side (~60-80% of the `inst:` overrun by our estimate — validated in J.0).

**AABB fallback is NOT the primary path.** Use only for refs that land in the <50m ring but genuinely lack baked collision in their PackedScene — log-and-skip the defer, current `_generate_static_collision` already handles this case. Don't synthesize a phantom-collision box for distant spawns.

**Recommendation: Q with stored-shape.** This is the canonical deferred-body pattern. AABB was the original draft's shortcut; @roaster v2 review correctly flagged it as the "invisible wall around a rock" bug that would fail senior-engineer review. Rejected.

**Question for user:** P (simple, partial savings) or Q-with-stored-shape (canonical, max savings, no collision regression)?

### 3.5 Actor / carryable / door exceptions

Actors (NPCs, creatures) already skip via `max_actor_distance` gate at spawn. Keep as-is — they're humanoid CharacterBody3D, a different path.

Carryables (items in world) need collision always (player needs to pick them up on approach). **Force enable within 50m only; below 50m no different from any other static.** If player is >50m, they can't reach to pick up anyway.

Doors (teleport type): need collision for interaction raycast ALWAYS (door interaction is raycast-based, not body-based). **Doors stay enabled regardless of distance** — force-flag via `door_interactable` meta.

Held bodies (carried item at camera): already live under `_held_body_attachment` in the camera rig, outside cell lifecycle. Untouched.

**No user lock needed — these are invariants.**

### 3.6 Where does the activation event fire?

**Option M: in `_update_loaded_cells`.** Already fires on cell-boundary crossing. Add a physics-tier pass after the load/unload dispatch.

**Option N: new `_update_physics_activation` as a peer phase.** Separate budgeted phase.

**Recommendation: M.** Already on the cell-crossing event path. No new phase overhead.

**No user lock needed.**

---

## 4. Implementation Phases (blocked on §3 locks)

### Phase J.-0.5 — Jolt broadphase toggle verification (blocks §3.3 lock)

15-minute spike. Build a minimal test: spawn 1000 StaticBody3D+CollisionShape3D nodes in a flat grid. Measure `PhysicsServer3D` active body count / broadphase body count via:
- `Engine.get_physics_frames()` + monitor callback
- `PhysicsServer3D.get_process_info(PhysicsServer3D.INFO_ACTIVE_OBJECTS)` if available in 4.6
- Jolt debug draw (`ProjectSettings.set("physics/jolt_physics_3d/debug/draw_bodies", true)`)

Toggle strategies to measure:
1. `CollisionShape3D.disabled = true` (set individually)
2. `CollisionObject3D.collision_layer = 0` (set individually)
3. `queue_free` the StaticBody3D entirely

**Acceptance gate for §3.3:**
- If (1) or (2) evicts from broadphase (body count drops to near-zero for toggled bodies): **X wins** — simpler, no re-creation needed, same payoff.
- If neither evicts (body count stays at 1000): **Y wins** — must tear down + recreate.
- Document result in §5 metrics table with the measurement method.

If Godot's Jolt integration doesn't expose per-body broadphase state, fall back to measuring `_physics_process` cost delta with 1000 disabled vs 1000 freed bodies — same signal, proxy measurement.

### Phase J.0 — Measurement baseline + test scene

Two deliverables:

**1. Instrumentation.** Instrument `process_async_instantiation` to break down `inst:` time into:
- deserialize (`PackedScene.instantiate()` alone)
- scene-tree attach (`add_child`)
- Jolt register (measured via body count delta × measured avg insert time — can't wrap Jolt directly)
- fade-in / metadata / misc

Log per-cell averages.

**2. Dedicated test scene: `tests/visual/test_lazy_jolt_activation.tscn`** — matches the `test_NEAR_*.tscn` family. Interactive scene with:
- Dense grid of StaticBody3Ds (~1500 across a 200m square)
- Debug draw overlay: body count, activation-ring visualization (cyan ring at 50m), physics-active markers (green = body present, red = deferred)
- Free-fly camera so the user can fly in/out of the activation ring and watch the transition visually
- F-key to dump body count per ring band

Without this scene, @user can't visually verify activation correctness, only log-read.

**Acceptance:** instrumentation emits structured per-phase numbers to log. Test scene exists and boots. Before-number captured in §5.

### Phase J.1 — Spawn-time skip (locks §3.4)

If user locks Q: modify `_instantiate_model_object` to skip StaticBody3D construction when `distance_sq > 50m² + hysteresis`. Add ref to `_physics_pending` set. Update `_disable_collision_shapes_in_tree` at model_loader to SKIP building StaticBody3D entirely (alternate spawn path).

If user locks P: revert to current behavior, skip to J.2.

**Acceptance:** spawn `inst:` overrun drops by expected 30-60% (measure against J.0 baseline).

### Phase J.2 — Activation event (locks §3.2)

If user locks B: new function `_activate_physics_in_range(camera_cell, radius_m)` in `native_streaming_manager`. Called from `_update_loaded_cells` AFTER load/unload pass. Walks resident cell contents, toggles physics per-object based on distance hysteresis.

If user locks A: simpler — per-cell `physics_tier` transition at cell-boundary crossing. Whole-cell enable/disable.

**Acceptance:** approaching an object with the camera causes its physics body to appear / collision to work. Leaving causes it to disappear. Verified interactively by user.

### Phase J.3 — Deactivation (locks §3.3)

If user locks Y: at deactivation event, call `_tear_down_physics_body(obj)` — `queue_free` the StaticBody3D, store shape in meta if not already there. Mesh stays live.

If user locks X: just toggle `CollisionShape3D.disabled = true`. Fast but leaves broadphase entries.

**Acceptance:** Jolt active body count drops after walking away from a dense area. Measured via Godot's debugging monitors.

### Phase J.4 — Actor / carryable / door invariants

Stamp meta `physics_always_on = true` on:
- Doors with `is_teleport` (done in `_attach_door_interactable`)
- Carryable RigidBody3D (done in `CarryableBodyFactory`)
- NPCs / creatures (natural — they're CharacterBody3D, separate path)

The activation event pass skips any object with `physics_always_on`. **No behavior change for these paths.**

### Phase J.5 — Measurement + acceptance

Re-run benchmark. `inst:` overrun must drop by ≥50% (target: <15ms sustained during cell-load bursts). No regression in collision behavior (user walks into rocks, doors work, items picked up, actors block).

---

## 5. Measurement Metrics (populate after implementation)

| Phase | Metric | Before | After | Notes |
|---|---|---|---|---|
| J.0 | `inst:` P95 during cell-load burst | 60.8ms | — | from 2026-04-19 state-reversal run |
| J.0 | Jolt active body count, Seyda Neen dock | TBD | — | use `Engine.get_physics_frames` + Godot monitor |
| J.0 | Per-object `PackedScene.instantiate()` avg | TBD | — | microbenchmark |
| J.1 | `inst:` spawn cost, new cell | TBD | TBD | |
| J.2 | `_activate_physics_in_range` cost per event | — | TBD | target < 2 ms/cell-crossing |
| J.3 | Jolt active body count, camera >100m from Seyda | TBD | TBD | target: <500 bodies |
| J.5 | Steady-state FPS mid-movement | 30-47 | TBD | target: >100 |

---

## 6. Ground Rules (inherited)

From parent plan:
1. Canonical pattern wins. CLAUDE.md "Industry Standard, Never Kludge."
2. Before/after numbers in §5 for every phase. Phase not done without numbers.
3. Interactive user verification (no auto-capture).
4. Reviewer engages at plan-draft + implementation-draft boundaries only.

---

## 7. Open Questions for User

Ordered by what blocks what.

1. **§3.2** Per-cell (A) or per-object-event (B) activation granularity?
2. **§3.3** Full teardown (Y) or disabled-flag (X) deactivation?
3. **§3.4** Skip StaticBody3D at spawn (Q) or build-then-strip (P)?

Defaults if user says "just go": **B + Y + Q.** Canonical AAA pattern, maximum savings, lands the full UE5-equivalent shape. This requires the most implementation work (~4-6h) and the biggest payoff.

---

## 8. Non-Goals

- Not implementing per-actor-tier physics systems (actors stay on CharacterBody3D).
- Not implementing signed-distance-field broadphase replacement (Godot doesn't expose Jolt internals that deep).
- Not redesigning the NIF collision pipeline — reuse AABB fallback from `_generate_static_collision` where NIF shape not available.
- Not touching interior-pocket physics (interiors are bounded, already <50m, always on).
- Not changing held-body / carryable-body lifecycle (already correct).

---

## 9. Stepping Stone → Terminal State (v2 patch)

**Per @roaster plan review 2026-04-19.** This plan gets ~70% of the payoff. The terminal architecture — what OpenMW ships and what UE5 World Partition converges to — requires a deeper cut that is explicitly OUT OF SCOPE here.

### 9.1 What this plan delivers

A canonical lazy-Jolt activation layer on top of the existing per-object Node3D spawn path. Statics keep their `Node3D + StaticBody3D + CollisionShape3D` tree; we just defer or elide the StaticBody3D when >50m. Interactive refs (doors, carryables, actors, lights) unchanged.

Effort: ~4-6h. Payoff: `inst:` overrun drops ~50-70%. Jolt body count drops 80%+.

### 9.2 What the terminal state looks like

**Eliminate Node3D entirely for non-interactive static geometry.** OpenMW and UE5 both converge here:

| Ref type | Render path (terminal) | Collision path (terminal) |
|---|---|---|
| Static geometry (rocks, arches, clutter, flora) | `RS.instance_create2` via `PrototypeRegistry` MultiMesh — **no Node3D, no scene-tree entry** | Per-cell merged trimesh `StaticBody3D` + single `ConcavePolygonShape3D` that covers all statics in the cell, OR near-player spatial-hash collision grid that only activates bodies within ~10m |
| Interactive refs (doors, carryables, actors, lights) | `Node3D` subtree with physics body | Per-object bodies as today |

**Why it's better than lazy Jolt:**
1. Eliminates `PackedScene.instantiate()` main-thread cost for static geometry entirely. Statics get a single `RS.instance_set_transform` call, not a tree of nodes.
2. Eliminates `add_child` notification cascade for thousands of statics per cell.
3. One `StaticBody3D` per cell instead of hundreds — Jolt broadphase sees ~9 bodies for a 9-cell active grid instead of ~1800.
4. HLOD path unchanged — we already merge meshes per cell via `object_paging.gd` for MultiMesh. The terminal state extends the same merge pattern to NEAR.

**Why we're NOT doing it in this plan:**
1. Requires prebake-side shape library that exposes per-ref collision geometry separately from the render mesh. Currently baked into the `.res` PackedScene.
2. Requires per-cell trimesh merge at cell-load time — a non-trivial offline or background-thread step.
3. Breaks the existing `reference_instantiator` → `Node3D` contract that carryable conversion, door attach, interior pockets, and NIF animations all depend on. Every one of those paths needs a migration story.
4. Effort: ~2-3 sessions. Too big for a single session coming off the state-reversal fix + NEAR-tier refactor.

### 9.3 Migration plan outline (future work, NOT this plan)

A future doc `statics_no_node3d.md` would cover:
- J.6: prebake pipeline split — `.res` emits both the scene and a sibling `.shapes.res` with a `Shape3D` + local transform per collidable
- J.7: `static_object_renderer` extension — accept any non-interactive static as a registered prototype; spawn via MultiMesh + per-cell RS instance instead of Node3D
- J.8: per-cell collision merger — at cell activation, merge all static shapes into one `ConcavePolygonShape3D` on a single cell-root `StaticBody3D`
- J.9: interactive-ref delta — door / carryable / NIF-anim spawn paths stay Node3D, explicitly filtered at spawn time
- J.10: pool invariants — object_pool only pools interactive Node3Ds, not statics

### 9.4 Why lazy-Jolt is still worth shipping

If the terminal state is 2-3 sessions away:
- Current `inst:60ms` overruns make the game unpleasant to drive RIGHT NOW
- Lazy-Jolt is ~4-6h and buys us smooth playable streaming while the deeper cut is designed
- Lazy-Jolt's invariants (distance-based activation, hysteresis, event-driven transitions) ARE the same invariants the terminal state will need — work carries forward, not thrown away
- Measurement data from lazy-Jolt (J.0 breakdown) directly informs where the terminal cut has to go

**Framing:** lazy-Jolt is a canonical pattern AND a stepping stone. Shipping it is not embarrassing to a senior engineer — it's literally how UE5 World Partition manages bodies for instanced static mesh actors, and it's the first half of OpenMW's physics system. The terminal state adds the Node3D-elision layer on top; lazy-Jolt makes that layer easier to build, not harder.
