# Interaction System — Design Doc

Status: **DESIGN ONLY** — not implemented. Drafted 2026-04-07. Reviewer: `@reviewer`.

This doc specifies how player-world interaction should be built so that **one input button cleanly handles dialogue, books, doors, containers, pickup, carry, throw, and (later) combat use** without any of those systems stepping on each other.

The framework lives in `src/core/interaction/`; Morrowind-specific verb mappings live in `src/core/interaction/morrowind/` (or piggyback on the existing `src/core/dialogue/morrowind/` adapter directory). Zero MW imports allowed in framework files. Litmus test: an Oblivion or generic-RPG adapter must be droppable next to the MW one without touching framework code.

---

## 1. Goals

1. **One button.** Bound to InputMap action `interact` (default `E`). Same button picks up an apple, opens a dialogue, reads a book, opens a door, opens a container, grabs a sword off a table, throws a barrel.
2. **Tap vs hold disambiguation.** Tap → "primary verb" of the target (Talk / Read / Take / Open / Activate). Hold → "grab and carry" if the target is a physics-carryable item; otherwise the hold gesture is ignored and the tap action fires on release.
3. **No conflicts.** While carrying, other interactions (dialogue, doors) are gated. Combat input (attack/block) is gated separately from interact and never overlaps.
4. **Framework-agnostic.** No game-specific logic in the generic Interactable / Raycaster / Carry stack.
5. **Streaming-friendly.** Carryables must coexist with cell streaming, object pooling, the static-renderer fast path, and Jolt sleeping.
6. **Buoyancy-friendly.** Dropped/thrown items that land on water must float without per-item authoring.

## 2. Non-Goals

- Combat hitbox/hurtbox plumbing — separate doc, separate layers.
- Magic interaction (Telekinesis, Open spell) — handled by spell effects, not interact.
- AI agent interaction with the world — reuses the same `Interactable.interact()` path eventually but is out of scope here.
- Save/load of dropped item positions — separate save-system doc.

---

## 3. Input Model

`interact` has **three discrete events** the player controller emits, all derived from one InputMap action:

| Event              | Trigger                                           | Used by                                |
|--------------------|---------------------------------------------------|----------------------------------------|
| `interact_tap`     | Press + release within `HOLD_THRESHOLD` (0.20s)   | Default verb on the targeted Interactable |
| `interact_hold_begin` | Press, held longer than `HOLD_THRESHOLD`       | Start carry on the targeted Interactable (if carryable) |
| `interact_release` | Release after `interact_hold_begin` already fired | End carry: drop or throw                |

Implementation rule: the player controller is the **only** node in the project that reads the raw `interact` action. It debounces and emits the three semantic events as signals. Every consumer (`InteractionRaycaster`, `CarryController`, dialogue UI close-handlers, etc.) listens to those signals — never `Input.is_action_pressed("interact")` directly. This is the single place where input semantics are decided and prevents two systems from racing on the same press.

### 3.1 Locked API surface (I.0)

Decided 2026-04-07. Signal-based modal gate registry (rejected: counter, enum stack — see §16 Decision History). `PlayerController` is the single input owner; modal UIs register themselves as gates.

> **Cross-ref to `docs/INPUT_SYSTEM.md` (K.0, owned by @keys):** the `interact` action is defined once in `project.godot [input]` (physical_keycode 69 = E). K.0 deliberately did NOT add a gamepad binding to `interact` because the action definition is owned by I.0 — any change goes through #interactivity coordination. K.0's `src/core/input/input_actions.gd` lists `interact` in `REQUIRED_ACTIONS` for verification only, never reads it. The `_ensure_input_actions` runtime safety net at `player_controller.gd:381` is REDUNDANT after K.0 ships, but **deliberately left in place** because removing it would force a `PlayerController` edit which K.0 forbids; cleanup is queued for a follow-up phase after K.0.5. See `docs/INPUT_SYSTEM.md` §3.3.

```gdscript
# src/core/player/player_controller.gd

signal interact_tap()
signal interact_hold_begin()
signal interact_release()

const HOLD_THRESHOLD: float = 0.20  # seconds

var _modal_gates: Array[Node] = []
var _press_time_msec: int = -1
var _hold_emitted: bool = false

## Register a modal UI as an input gate. While ANY registered gate's
## is_open() returns true, PlayerController suppresses interact_*
## signal emission. Gate must implement `is_open() -> bool`.
func register_modal_gate(gate: Node) -> void:
    if gate in _modal_gates:
        return
    assert(gate.has_method("is_open"), "modal gate must implement is_open() -> bool")
    _modal_gates.append(gate)
    if not gate.tree_exiting.is_connected(_on_gate_tree_exiting):
        gate.tree_exiting.connect(_on_gate_tree_exiting.bind(gate), CONNECT_ONE_SHOT)

func unregister_modal_gate(gate: Node) -> void:
    _modal_gates.erase(gate)

func _on_gate_tree_exiting(gate: Node) -> void:
    _modal_gates.erase(gate)

func is_modal_ui_open() -> bool:
    for gate in _modal_gates:
        if is_instance_valid(gate) and gate.is_open():
            return true
    return false

func _unhandled_input(event: InputEvent) -> void:
    if is_modal_ui_open():
        return
    if event.is_action_pressed("interact"):
        _press_time_msec = Time.get_ticks_msec()
        _hold_emitted = false
    elif event.is_action_released("interact"):
        if _press_time_msec < 0:
            return
        var held_msec := Time.get_ticks_msec() - _press_time_msec
        _press_time_msec = -1
        if _hold_emitted:
            interact_release.emit()
        elif held_msec < int(HOLD_THRESHOLD * 1000):
            interact_tap.emit()
        else:
            # Held past threshold but _hold_emitted is false — physics tick
            # didn't fire (extreme rare race). Treat as tap on the fallthrough
            # rather than silently dropping the event.
            interact_tap.emit()

func _physics_process(_delta: float) -> void:
    # Hold detection: input events fire on press/release only,
    # so polling is required for "held past threshold" detection.
    if _press_time_msec < 0 or _hold_emitted:
        return
    if is_modal_ui_open():
        return
    var held_msec := Time.get_ticks_msec() - _press_time_msec
    if held_msec >= int(HOLD_THRESHOLD * 1000):
        _hold_emitted = true
        interact_hold_begin.emit()
```

**Contract for modal UIs (C.2.5 will implement on the dialogue side):**
- Implement `is_open() -> bool` method (`DialogueUI` already has it; `BookViewer` already has it after C.2; `JournalPanel` adds 1-line)
- On `open()` / `show_*()` → call `PlayerController.register_modal_gate(self)` once. Idempotent.
- On `close()` / `hide_*()` → call `PlayerController.unregister_modal_gate(self)`
- Gates that free without unregistering are auto-cleaned via `tree_exiting` connection

**Why `is_open()` and not duck-typed `.visible`:** `DialogueUI` extends `CanvasLayer` with internal `_root_control.visible` state, not a top-level `visible` property. Duck-typing would skip CanvasLayer-rooted UIs. Explicit method = clean contract.

**Why signal-based registration over a counter or enum stack:** counter drifts positive if a panel frees while visible (no final visibility_changed). Enum stack adds semantic state nobody currently needs. Signal-based with `tree_exiting` self-heal is the smallest API that fixes both reported bugs (E doesn't close book, dialog topics unclickable — see §16 Decision History) and unblocks the polling-soup architecture. If a future requirement needs distinguishing DIALOGUE vs MENU vs CARRY for differential input handling, an `InputOwner` enum can be layered on top of the existing gate without breaking consumers. **YAGNI for now.**

**Hold detection lives in `_physics_process`, not the input event,** because input events fire only on press/release. Hold needs continuous time check. Single emission point per press (`_hold_emitted` flag), no double-fire. Modal-gate check inside `_physics_process` too — if a panel opens mid-press, the hold doesn't fire.

## 4. Targeting

`InteractionRaycaster` (already built, `src/core/interaction/interaction_raycaster.gd`) sits on the player camera and casts forward each physics frame against collision layer 3. It maintains `_current_target: Interactable` and emits `prompt_changed` whenever it changes.

The raycaster does NOT call `interact()` itself anymore (current implementation does — change this). Instead, the `PlayerController` listens to the three input events and asks the raycaster for `get_current_target()`. Reason: keeping the raycaster pure-state (just "who am I looking at?") means dialogue UI, carry controller, and future systems can read the same target without each owning their own ray.

```
PlayerController
   ├─ on interact_tap        → if target: target.interact(player)
   ├─ on interact_hold_begin → if target and target.is_carryable(): CarryController.grab(target)
   └─ on interact_release    → if carrying: CarryController.release(throw=is_moving_camera_fast)
```

## 5. Interactable Verb Taxonomy

Every `Interactable` subclass declares its **primary verb** (what `interact()` does on tap) and whether it is **carryable** (can be grabbed on hold). The base class adds:

```gdscript
## Whether this object can be physically carried by the player.
## Override in subclasses. Default = false.
func is_carryable() -> bool:
    return false
```

Verb buckets and which adapters implement them:

| Bucket    | Tap verb         | Carryable | MW adapter                  |
|-----------|------------------|-----------|-----------------------------|
| NPC       | Talk             | No        | `npc_interactable.gd`       |
| Book      | Read / Unroll    | Yes       | `book_interactable.gd`      |
| Pickup    | Take (inventory) | Yes       | `pickup_interactable.gd` *  |
| Door      | Open / Travel    | No        | `door_interactable.gd` *    |
| Container | Open             | No        | `container_interactable.gd` * |
| Activator | Activate         | No        | `activator_interactable.gd` * |

(* = to be written.)

The "carryable yes/no" axis is independent of the tap verb. Books are both readable (tap) AND grabbable (hold) — that's the example the user gave for weapons: tap = take to inventory, hold = lift physically. The base class enforces no contradiction because the two paths are routed by different events.

## 6. Carry Mechanics

### 6.1 Carryable spawn path

`reference_instantiator.gd` currently wraps every NIF in a `StaticBody3D` (via `NIFCollisionBuilder.create_static_body`). For records whose ESM type is in the **carryable set** (WEAP, ARMO, BOOK, CLOT, MISC, INGR, ALCH, REPA, PROB, LOCK, APPA, SCRL, plus LIGH where `FLAG_CAN_CARRY` is set), the instantiator must instead build a `RigidBody3D` containing the same shapes, with:

- `collision_layer = Environment | Interactable` (bits 1 and 3)
- `collision_mask = Environment | Player` (rolling apple bumps player's foot — see §6.5 for the held-state mask change)
- `freeze = true` initially, `freeze_mode = FREEZE_MODE_KINEMATIC` so the body costs zero solver time at rest
- `mass` from ESM weight field, **treated as kg directly** (gameplay-tuned, no lb→kg conversion — MW weight values are already balanced for game feel and the unit label is fictional). Hard-clamped to `[0.1, 200.0]` for solver sanity. The 50 kg grab refusal (§13 Q4) is enforced separately by `CarryController`, not by spawn-time clamping.
- a `PickupInteractable` child carrying the ESM record_id

The static-renderer fast path (`_is_static_render_model`) is excluded — flora and small rocks stay non-Node3D for perf. Carryables are by definition Node3D-bound.

When the cell streams in, all carryables stay frozen. They wake on first contact, on grab, or on a script call (e.g. an explosion or NPC AI eventually). When the cell streams out, they freeze again (or if held by player, reparent to a "carried" pocket so the cell can unload safely — see §10).

### 6.2 Hold mechanism — recommended approach

Two viable options were considered:

| Option            | Pro                                            | Con                                               |
|-------------------|------------------------------------------------|---------------------------------------------------|
| **PinJoint6DOF** to Marker3D in front of camera | Object stays in physics simulation, collides naturally with walls and other items | Floaty, jitter at high framerate, joint can stretch / explode, mass mismatches feel bad |
| **Kinematic reparent** — `freeze = true`, `freeze_mode = KINEMATIC`, parent to camera Marker3D, lerp to hold pose | Crisp, predictable, never explodes, easy to script | Held object can clip into walls; need extra raycast / spring to push player back or spring object out |

**Recommendation: kinematic reparent**, with a "hold spring" — when the held object's hold pose intersects geometry, smoothly pull the camera holder back along its forward axis until the hold pose is clear. If pulled all the way back (object touching player chest), drop it. This is the Oblivion/Skyrim model and it's the one that doesn't fight other systems: while held, the object is functionally part of the player rig, so streaming/buoyancy/AI never have to care about an unparented physics body the player is dragging around.

**Hold pose rotation contract:** the held pose tracks camera **yaw and pitch** but **roll is locked to world up**. Held objects rolling with camera roll looks drunk and breaks immersion. Implementation: build the hold transform from `Basis(camera_basis.y, Vector3.UP, ...)` reconstructed without the roll component, or just snapshot `(yaw, pitch, 0)` Euler.

**Hold spring tuning:** stiffness, damping, max-pullback distance, and how the spring interacts with player walking forward into a wall while holding are all **tunable parameters left open for I.3**. Starting values: stiffness 80 N/m equivalent (lerp factor 0.25/frame at 60Hz), max pullback 0.6 m, force-drop when pullback hits max for > 0.3 s. I.3 reviewer should expect these to change after playtest.

**Carry state machine — grab/release symmetry contract.** The grab path MUST restore the I.1 spawn invariants byte-for-byte regardless of whether the body has been previously released:

```
freeze = true
freeze_mode = FREEZE_MODE_KINEMATIC
linear_velocity = Vector3.ZERO
angular_velocity = Vector3.ZERO
```

If the grab path assumes the body is still in spawn state, the second grab cycle will silently fail (the body falls under gravity instead of attaching to the marker, because release left it `freeze = false`). Symptom from playtest: "first grab works, subsequent grabs leave the item at the player's feet". Root cause is asymmetric state machine — release reverses spawn, grab does not reverse release. Both paths must explicitly assert the invariants they want.

**Deferred-mutation rule (load-bearing — don't violate this).** **All `RigidBody3D` state mutation MUST happen via `call_deferred` atomic helpers, never inline from a physics-tick handler or signal callback.** This includes:

- `collision_mask` writes (mask flip on grab / restore on release)
- `freeze` and `freeze_mode` writes
- `linear_velocity` and `angular_velocity` writes
- Transform writes (`position`, `rotation`, `basis`, `transform`, `global_transform`)
- `reparent()` calls (the original MF2 rule — now generalized)

**Why:** Godot's space state may be processing the body in the same frame your handler runs. Mutating physics state mid-process is a use-after-free hazard inside Jolt, surfacing as `signal 11` segfaults with no GDScript backtrace. The I.* phase ladder hit this failure mode three times before the rule was generalized:

1. Bug A in I.2 — raycaster cached `Interactable` reference dangling after self-despawn (use-after-free at the GDScript layer, manifesting as "Trying to assign invalid previously freed instance" → eventually sig 11)
2. Bug B in I.3 first run — reparenting `Pickup` wrapper while the contained `RigidBody3D` was being processed by the space state
3. The 4-grab-then-crash pattern in I.3 — repeated `freeze` toggles + mask writes inline from `_route_carry_grab` / `_route_carry_release` handlers driven by `_unhandled_input`

**Concrete pattern (CarryController, I.3):**

```gdscript
func try_grab(target: Interactable) -> bool:
    # Validate, snapshot CONTROLLER-side state immediately so is_carrying()
    # is true to consumers, then defer the body-side mutation.
    _saved_collision_mask = rb.collision_mask  # PURE READ — fine inline
    _do_grab.call_deferred(target, rb)
    return true

func _do_grab(target: Interactable, rb: RigidBody3D) -> void:
    # All RB writes happen here — outside any physics callback.
    rb.freeze = true
    rb.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
    rb.linear_velocity = Vector3.ZERO
    rb.angular_velocity = Vector3.ZERO
    rb.collision_mask = rb.collision_mask & ~CarryableBodyFactory.LAYER_PLAYER
    target.reparent(_hold_target_marker, false)
    target.position = Vector3.ZERO
    target.rotation = Vector3.ZERO
```

**Reads are fine inline.** Snapshotting `rb.collision_mask` for restore-later is a read; only mutations are dangerous.

**Future phases:** I.4 throw + impulse, I.5 buoyancy probe writes, I.6 streaming reparent — all must follow the same pattern. Any new code that touches a `RigidBody3D` must do so from a `call_deferred` helper. Reviewer enforces via `grep` on the carry/buoyancy/streaming code paths.

### 6.2.1 ~~KNOWN ISSUE — hold-pose vibration~~ RESOLVED 2026-04-09

**Status:** SOLVED by architectural rewrite. `CarryController` no longer uses kinematic direct-transform writes. See §17.5 for the rewrite notes; the short version is that the entire "kinematic reparent + direct `global_transform` writes from `_process` + manual chain composition + per-node interpolation carve-outs + wall-pushback raycast + camera-basis ring buffer + throw lever-arm cross product" stack was replaced by the canonical HL2 physics-gun pattern: body stays DYNAMIC, `linear_velocity` + `angular_velocity` written each `_physics_process` tick, Jolt integrates, engine interpolation smooths. The vibration was a symptom of fighting Godot's physics-interpolation system with render-rate transform writes; stopping that fight eliminated the entire bug class.

Canonical lesson preserved in `.claude/CLAUDE.md` "Engineering Principle — Simplicity Over Over-Engineering". Do NOT re-introduce a kinematic direct-write carry loop without escalating first.

### 6.3 Throw

On `interact_release`, `CarryController` measures **camera angular velocity over the last 50 ms** (time-windowed, framerate-independent — sample at physics tick into a small ring buffer keyed by `Time.get_ticks_msec()`) and the player's linear velocity. If either exceeds a threshold (default ≈ 1.5 rad/s or 4 m/s), the release is treated as a **throw**:

1. Reparent the rigid body back to the world cell that owns its current position.
2. Set `freeze = false`. Restore `collision_mask` to include the Player layer (see §6.5).
3. `linear_velocity = player_velocity + camera_forward * throw_impulse`. The camera angular contribution is added separately as `linear_velocity += camera_angular_velocity.cross(held_position - camera_position)` — this is the lever-arm contribution (rad/s × m → m/s, dimensionally clean). Earlier draft mistakenly added `camera_angular_motion` directly to a linear velocity; that was a unit error.
4. Apply small `angular_velocity` perpendicular to motion for a natural tumble.

If under threshold, it's a **drop**: same reparent/unfreeze/mask-restore, but velocity = `player_velocity` only. No impulse.

### 6.4 Buoyancy

The `BuoyancyBody3D` class extends `RigidBody3D`. The carryable spawn path can use it directly instead of a plain `RigidBody3D`. When the body is far from any active ocean cell, `_physics_process` early-outs (it already calls `OceanManager.is_initialized()`; we add a cheap world-Y / ocean-cell-AABB pre-check). Probes can be auto-generated from the AABB at spawn time — 4 corners on the bottom face plus the AABB center — no per-item authoring needed.

**Frozen-body tick guard — VERIFIED REQUIRED.** Diagnostic `tests/diagnostic/frozen_rb_tick_check.tscn` confirms Godot 4.6 ticks `_physics_process` on a frozen `RigidBody3D` every physics frame (59 ticks in 60 frames, freeze=true, freeze_mode=KINEMATIC). The early-out guard is **mandatory**, not optional. `BuoyancyBody3D._physics_process` MUST begin with:

```gdscript
func _physics_process(delta: float) -> void:
    if freeze:
        return  # Godot still ticks frozen RBs in 4.6 — verified 2026-04-07
    # ... existing logic
```

Without this guard, every clutter item in a cell pays the full ocean wave-height query each frame even though it's at rest on a table indoors. With the guard, the cost collapses to one branch per frozen body. The vast majority of clutter spends its life frozen, so this is the load-bearing optimization.

### 6.5 Held-state collision mask

`collision_mask` flips between two states:

| State | Mask                          | Reason                                                       |
|-------|-------------------------------|--------------------------------------------------------------|
| Spawned / dropped / thrown | `Environment | Player` | Rolling apple bumps the player's foot; thrown item collides with everyone |
| Held (carried) | `Environment` (Player removed) | Held object must not push the player around or get stuck on the player capsule |

Transitions:

- `CarryController.grab()`: snapshot original mask, set `collision_mask &= ~PLAYER_BIT`.
- `CarryController.release(throw)`: restore original mask **before** unfreezing and applying impulse.

This is the single source of truth for held-vs-free collision behavior. Don't change masks anywhere else.

## 7. Inventory Routing

`PickupInteractable.interact(player)` (the tap path) calls into a generic `InventoryService` (to be written) with the ESM record_id and quantity 1. The service is the only thing that knows how the player inventory is stored. On success, the world body is queued for despawn — `queue_free()` *deferred* so we don't free during a physics callback.

**InventoryService contract** — `store_item(record_id: StringName, qty: int) -> StoreResult` where `StoreResult` is an enum:

| Result | Meaning | World body action |
|--------|---------|-------------------|
| `OK` | Item accepted into inventory | Despawn (queue_free deferred) |
| `INVENTORY_FULL` | Slot count or weight cap exceeded | Stay in world, show prompt "Inventory full" |
| `FORBIDDEN` | Steal flag, faction restriction, etc. | Stay in world, show prompt "You are not allowed to take this" |
| `INVALID_RECORD` | record_id not found in ESM | Stay in world, log error |

**Cap policy:** Inventory enforces its own weight/slot cap independently of the `CarryController` 50 kg grab cap. Tap = "give to inventory", inventory may refuse (returns `INVENTORY_FULL`). Hold = "lift physically", `CarryController` may refuse (mass > 50 kg, prompt "Too heavy"). The two caps are unrelated: a player with a full inventory can still grab and carry a sword in their hands.

This is where the user's "easy" lives: the same Interactable handles both verbs because tap goes through `interact()` → inventory, and hold goes through `CarryController.grab()` → physics. Adapters never need a branch.

## 8. Cross-System Non-Conflict Rules

This is the section that exists specifically because the user said "doesn't fight other systems." The rules:

1. **Carry mode is exclusive.** While `CarryController.is_carrying()`, the raycaster suppresses prompt updates and the player controller ignores `interact_tap`. You can only release. Doors, dialogue, containers cannot be activated while carrying — this matches Oblivion and avoids the "I held the apple while opening a dialogue and now the apple is stuck in the NPC's face" class of bug.
2. **Modal UI gates carry.** When ANY modal UI is visible (`DialoguePanel.visible`, `BookViewer.visible`, `JournalPanel.visible`, future container UI), the player controller stops emitting interact events entirely. The modal UI's own input handlers own the keyboard. This is critical for books: book is both tappable (Read) and carryable (Lift) — without the BookViewer gate, holding E to read would fire `interact_hold_begin` mid-read and lift the book out of the reader's hands. The gate is checked centrally in `PlayerController` via a `is_modal_ui_open()` helper that the UI screens register with.
3. **Combat mode owns its own button.** Attack/block bind to `attack` and `block`, NOT `interact`. There is no overload. The only combat × interact interaction is "while weapon is drawn and a carryable is targeted, hold-to-grab still works" — this lets the player rearrange a swordfight by throwing a chair. Tap (take to inventory) is also allowed.
4. **No double raycast.** Only `InteractionRaycaster` casts on layer 3. If a future system needs to know what the player is looking at (loot tooltips, NPC name badge), it reads `raycaster.get_current_target()` — it does not cast its own ray. This is enforced by code review, not code.
5. **One input owner.** Only `PlayerController._unhandled_input` (or `_input`) reads the raw `interact` action. The raycaster's current `_unhandled_input` listener (lines 89–102 of `interaction_raycaster.gd`) must be **removed** when this design lands.
6. **Cell streaming respects carried objects.** The cell unload path checks `CarryController.get_held_body()` and skips its parent cell from the unload set. When the player walks far enough that the original cell would unload, the held object is reparented to a persistent "carried items" node off the player root. On release/throw, it goes back to whichever cell it lands in. (See §10.)
7. **Interactable layer is layer 3 ONLY.** Don't add interactables to other layers. Don't add non-interactables to layer 3. This keeps the raycast cheap.
8. **No `Area3D.monitoring = true` on items.** Per CLAUDE.md anti-patterns. Detection is pull-based (the raycaster pulls), not push-based (items don't volunteer to be detected).

## 9. Layer Plan

Current `project.godot`:

```
layer_1 = Environment   (terrain, walls, statics)
layer_2 = Player        (the player CharacterBody3D)
layer_3 = Interactable  (NPCs, books, activators, pickups)
```

After this design lands, no layer changes — carryables go on **both** layer 1 and layer 3 (one for env collision, one for raycast targeting). Reserve for the future:

```
layer_4 = Hitbox  (combat — attacker damage volumes)
layer_5 = Hurtbox (combat — receiver damage volumes)
layer_6 = WaterVolume (already used by ocean manager? verify)
```

Don't add 4/5 yet — they belong to the combat doc.

**Ownership note: orphan registry is NOT a new autoload.** §10's `OrphanedCarriedItems` node is a child of the existing streaming manager (`NativeStreamingManager`), not a fourth global singleton. It is scene-tree global state owned by the streaming manager, not a separate Autoload. If implementation pressure ever wants to promote it to an autoload, that's a design change that requires explicit reviewer sign-off.

## 10. Carried-Object Lifetime During Streaming

The hardest cross-system corner. Sequence:

1. Player picks up barrel in cell `(-3, -10)`.
2. `CarryController.grab` reparents the barrel from `Cell(-3,-10)` → `PlayerRig/CarriedItems`. Sets `freeze = KINEMATIC`.
3. Player walks 200m. Streaming wants to unload `Cell(-3,-10)`.
4. Cell unload path calls `queue_free()` on the cell node — this would free the barrel too if we hadn't reparented. We did reparent, so the barrel is safe under `PlayerRig`.
5. Player throws barrel into `Cell(-1,-9)`.
6. `CarryController.release` reparents the barrel back into `Cell(-1,-9)` (the cell it currently occupies, looked up via streaming manager's grid index). If that cell isn't loaded (e.g. throw goes very far), the barrel is reparented to a persistent `WorldRoot/OrphanedCarriedItems` node and registered with the streaming manager so it gets re-homed when its target cell loads.

Edge case: barrel thrown into a cell that never reloads (player goes the other way forever). The orphaned-items node is bounded — items older than N minutes / further than N cells away are despawned. Save system will handle persistence later.

## 11. Combat Compat (forward look)

When combat lands:

- `PlayerController` adds an `equipped_weapon: WeaponData` slot.
- `attack` and `block` actions are added to InputMap. Independent of `interact`.
- `WeaponSwingController` does its own collision query against layers 4/5 (hitbox/hurtbox), unrelated to the interact raycaster.
- A held physics object (carried via `CarryController`) is NOT a weapon — swinging a chair is "physics impact" and uses the body's actual rigidbody collisions to deal contact damage. This is a nice-to-have, can be punted.

The point is: nothing in the combat system reaches into the interaction system. They share zero code paths beyond the Interactable layer assignment.

## 12. Adapter Pattern

```
src/core/interaction/                       Framework (no MW imports)
    interactable.gd                         Already exists; add is_carryable() default
    interaction_raycaster.gd                Already exists; REMOVE _unhandled_input handler
    carry_controller.gd                     NEW — kinematic reparent + throw
    inventory_service.gd                    NEW — abstract base, store_item(record_id, qty)

src/core/interaction/morrowind/             Adapter
    pickup_interactable.gd                  NEW — wraps ESM record, routes tap → inventory
    door_interactable.gd                    NEW — calls existing door_portal logic
    container_interactable.gd               NEW — opens container UI (later)
    activator_interactable.gd               NEW — runs MW activator script (later)
    mw_inventory_service.gd                 NEW — concrete inventory backed by MW item slots

src/core/dialogue/morrowind/                Existing adapters (untouched)
    npc_interactable.gd                     Already non-carryable, no change
    book_interactable.gd                    Add is_carryable() returning true
```

`PlayerController` (in `src/core/player/`) gets the input owner role and a reference to `CarryController`. `CarryController` is a child of the camera or its rig node.

## 13. Open Questions

1. **Throw threshold tuning.** Camera angular velocity vs linear is platform-feel. Needs in-engine playtest.
2. **Hold-to-grab UX feedback.** Does the prompt change from "Take" to "Hold to lift, tap to take" mid-press? Or just two prompts shown side-by-side ("Tap E: Take | Hold E: Lift")? Vote for the side-by-side string when carryable + has tap verb.
3. **Picking up from NPC inventory** (steal). Out of scope for Phase 1, requires container UI first.
4. **Two-handed objects.** Not all carryables fit one-handed (corpses, large barrels). Phase 1 = treat all as one-handed; gate weight-cap on hold (refuse grab if mass > 50 kg, show "too heavy" prompt).
5. **~~Held object collision with player.~~** RESOLVED — see §6.5. Spawn mask includes Player; grab removes it; release restores. Single source of truth in `CarryController`.
6. **~~`BuoyancyBody3D._physics_process` while frozen.~~** RESOLVED — `tests/diagnostic/frozen_rb_tick_check.tscn` confirms Godot 4.6 ticks frozen RBs. Early-out guard is mandatory; spec'd in §6.4.
7. **Per-cell despawn of orphaned thrown items.** Window/budget needs decision. Default proposal: 5 minutes or 8 cells away.

---

## 14. Implementation Phases

| Phase | Scope                                                                                          | Validates                              |
|-------|-----------------------------------------------------------------------------------------------|----------------------------------------|
| **I.0** ✅ | Wire `InteractionRaycaster` into `scenes/Godotwind.tscn`, add input-event split in `PlayerController`, remove raycaster's input handler. | Existing NPC/book adapters work in main scene. No regression. |
| **I.1** ✅ | Carryable spawn path in `reference_instantiator.gd` — record-type gated `RigidBody3D` (still no carry yet). Bodies on layer 1+3, frozen. | Apples, books, weapons collide and can be hit by raycaster prompts. |
| **I.2** ✅ | `PickupInteractable` adapter + minimal `InventoryService` stub (just logs `Take <name>`). Tap path works. | Tap E on a sword → log "Take longsword" + sword despawns. |
| **I.3** ⚠ | `CarryController` with direct-transform-write hold loop. **Architecture deviated from spec** — kinematic reparent failed because Godot's `RigidBody3D` ignores parent-chain transform inheritance; physics-server transform is not recomputed from the scene tree. See @reviewer id=4041 for the diagnosis. Final design uses direct `_held_body.global_transform` writes from `_process` with manual interpolation via `Engine.get_physics_interpolation_fraction()`. | Hold E to lift a barrel, walk around, release = drop. |
| **I.4** ✅ | Throw mechanics, hold-spring wall pushback, weight cap. | Throw a barrel down a hill, watch it bounce. |
| **I.5** | Auto-buoyancy via `BuoyancyBody3D` substitution + AABB-derived probes. | Throw a barrel into Lake Amaya, watch it float. |
| **I.6** | Carried-object streaming safety + orphan registry. | Walk 500m carrying an apple, drop it in a new cell, walk back, apple still there. |
| **I.7** | Door / container / activator adapters. | Tap E on a door → open. Carrying does not break door interaction (just refuses). |

Each phase ships a `tests/visual/test_interaction_phase_IN.tscn` scene that exercises only that phase's surface area.

## 15. Reviewer Sign-off Checklist (for `@reviewer`)

- [ ] Single input owner enforced — only `PlayerController` reads raw `interact`
- [ ] Raycaster's `_unhandled_input` removed
- [ ] Carry-mode exclusivity gate — no dialogue/door interaction while carrying
- [ ] Layer assignments unchanged for layer 3, no spillover
- [ ] No new autoloads
- [ ] No `Area3D.monitoring = true` anywhere in the carryable spawn path
- [ ] `BuoyancyBody3D` early-out verified for frozen bodies
- [ ] Static-renderer fast path NOT used for carryables
- [ ] Object pool keyed by `(model_path, body_type)` if pool reuse is enabled for carryables
- [ ] Cell unload skip-list contains held body's parent cell
- [ ] All new files outside `src/core/interaction/` are inside `morrowind/` adapter dirs
- [ ] No game-specific imports in framework files
- [ ] `tests/visual/test_interaction_phase_IN.tscn` exists for each phase
- [ ] Modal UI gate — `PlayerController.is_modal_ui_open()` helper exists; `DialoguePanel`/`BookViewer`/`JournalPanel` register with it
- [ ] Held-state mask transition — `CarryController.grab()` snapshots mask + clears `PLAYER_BIT`; `release()` restores before unfreeze and impulse
- [ ] Throw uses lever-arm cross product — `camera_angular_velocity.cross(held_position - camera_position)`, not raw angular velocity addition
- [ ] Mass field treated as kg directly — no lb→kg conversion at spawn, 50 kg grab cap enforced in `CarryController` not spawn clamp
- [ ] Hold pose rotation — yaw + pitch from camera, roll locked to world up
- [ ] Signal emission gate is INSIDE `PlayerController._unhandled_input` ONLY. Interactable subclasses MUST NOT check `is_modal_ui_open()` themselves. Centralized gate, decentralized consumers.
- [ ] No site outside `PlayerController._apply_mouse_mode_*` calls `Input.set_mouse_mode` (grep check)
- [ ] Modal gates implement `is_open() -> bool` (assert in `register_modal_gate`)
- [ ] `interact_hold_begin` emitted ONCE per press (single `_hold_emitted` flag, polled from `_physics_process`)

---

## 17. Phase Ladder Ship Status + Carry-forward TODOs (2026-04-09 update)

**I.0 through I.7 shipped. CarryController rewrite shipped 2026-04-09. Main-scene integration + I.6 Phase 2 shipped 2026-04-09.** Vibration is SOLVED (not parked). Remaining Phase 2 followups: I.7 container UI + BNAM script interp + lockpicking (all blocked on other systems). Throw mass weighting (§17.2.3) is OBSOLETE — velocity-drive handles weight naturally through Jolt's mass-weighted integration.

### 17.0a Main-scene integration (2026-04-09)

The `InteractionRaycaster` + `CarryController` are now wired into `world_explorer.gd` under the player rig. Launch `scenes/Godotwind.tscn`, press `P` to switch to player mode (which forces first-person and locks `allow_camera_mode_switch = false` — see below), walk up to any carryable or teleport door, press the unified `interact` action.

**Wiring summary (`world_explorer._setup_cameras`):**
- `InteractionRaycaster` instantiated under `player_controller.get_camera()`, `max_distance = 5.0`, `physics_process` gated on camera mode — disabled in fly mode (the chase camera ≠ player eyes), enabled on player switch.
- `CarryController` instantiated under `player_controller`, `setup(camera, player)` called, `set_carry_controller()` routed through `PlayerController` so the hold/release input path resolves correctly.
- `set_streaming_manager()` deferred to `_setup_pocket_manager` so both the carry controller and the streaming manager exist before the I.6 registration hand-off.
- `cell_manager.set_door_activated_handler(_on_door_interactable_activated)` — plumbs a `Callable` through `CellManager` → `ReferenceInstantiator` so every spawned `DoorInteractable` connects its `door_activated` signal at creation time without any upward dependency.

**Why force first-person on player switch:** the `InteractionRaycaster` casts from the camera, and in third-person the `SpringArm3D` pushes the camera ~3m behind the player. With `max_distance = 5m` the effective reach FROM THE PLAYER was only ~2m and the cast could also angle through the player's head depending on pitch, leaving door targeting broken. The fix is to match the I.3/I.4/I.7 test scenes: call `set_camera_mode(FIRST_PERSON)` in `_switch_to_player_controller` and set `allow_camera_mode_switch = false` so the user can't TAB back to third-person and silently re-introduce the dead-reach bug. This is the canonical pattern — AAA games ship in first-person for reach-limited interactions for exactly this reason.

**DoorInteractable spawn path (`ReferenceInstantiator._instantiate_model_object`):** for every `type_name == "door"` reference whose `ref.is_teleport` is true (DODT subrecord present), the door instance's root `Node3D` is promoted to a `DoorInteractable` via `set_script` (same pattern as `CarryableBodyFactory` wraps the body in a `Pickup` parent — the Interactable has to be on the collider's walk-up path, NOT as a sibling). The helper `_add_interactable_layer_recursive` then ORs the Interactable bit (`1 << 2`, layer 3) onto every `CollisionObject3D` in the door subtree so the raycaster (`collision_mask = 1 << 2`) can hit it. Existing layer 1 (Environment) is preserved so doors still block player movement. Decorative non-teleport doors (no DODT) stay silent — no adapter, no signal, no extra cost.

**Door signal → travel routing (`world_explorer._on_door_interactable_activated`):** the adapter's `door_activated(record_id, door_record, player)` signal carries the authoritative `record_id`. The handler calls `InteriorPocketManager.get_door_info_by_ref_id(ref_id)` (new helper) which scans `_exterior_doors` first (hot path) then `_active_pocket.doors_inside`, returning the pocket manager's canonical `DoorInfo`. That `DoorInfo` is then passed to the new shared `_activate_door(door)` helper, which branches on `_pocket_manager.is_inside()` to pick `enter_interior` / `exit_to_exterior` / `transition_interior_to_interior`. Fade-to-black / streaming pause / seamless transition all unchanged.

**KEY_E fallback:** the hotkey path in `world_explorer._unhandled_input` is now gated on `_camera_mode == FLY_CAMERA`. In fly mode, pressing E still runs the proximity-based `_activate_nearest_door()`. In player mode, the unified `interact` action (also bound to E) drives the raycast path via `PlayerController._emit_interact_tap` → `DoorInteractable.interact()` → signal handler. The gate prevents double-activation.

### 17.0b I.6 Phase 2 — re-home + bound policy + walk-back (2026-04-09)

Shipped the full Phase 2 contract from §10. The streaming manager now:

1. **Re-homes orphans on cell reload.** `_rehome_persistent_nodes_for_cell(cell_node, grid)` is called from both the sync (`_load_cell_sync`) and async (`_process_async_completions`) cell-load paths, immediately after `_loaded_cells[grid] = cell_node`. It walks `_persistent_nodes`, filters to entries whose `original_grid == grid` and whose current parent is `_orphan_container` (NOT held items still under the player camera), and reparents them back into the reloaded cell with `keep_global_transform = true`.

2. **Bound policy (5 min OR 8 cells).** Persistent-node entries now carry `{original_grid, created_ms, last_known_player_grid}` via a `PersistentNodeEntry` inner class instead of a bare `Vector2i`. Every second (`ORPHAN_PRUNE_INTERVAL_S = 1.0`), `_prune_expired_orphans()` walks the registry and expires any orphan whose `age_ms > ORPHAN_EXPIRY_MS` (5 min) or whose `chebyshev(original_grid, _camera_cell) > ORPHAN_EXPIRY_CELL_DISTANCE` (8 cells). Expired orphans get `queue_free()` deferred and their entries are erased. Held items (parent is the camera Marker3D) are skipped — their `last_known_player_grid` is updated in the same walk so the Chebyshev check stays current after any future re-home.

3. **Walk-back ground snap.** `_apply_walkback_ground_snap(node, cell_node)` runs inside `_rehome_persistent_nodes_for_cell` as a safety net. It raycasts downward from `pos.y + 3m` to `pos.y - 50m` against layer 1 (Environment), excluding the node itself, and snaps to `hit_pos.y + 0.05` IF the current position is more than 0.25m off the ground or below it. If the position is stable (resting item already on the cell geometry), it's left alone — we only correct genuinely invalid placements caused by terrain regeneration or deformation between unload and reload.

**Constraint enforcement:** the streaming manager still doesn't import the carry controller. Coupling is still by inversion — `CarryController.set_streaming_manager()` + duck-typed `register_persistent_node` / `unregister_persistent_node` calls. Phase 2 added no new import dependencies; it's purely additive behavior inside the streaming manager.

**Self-tests:** `tests/visual/test_interaction_phase_I6.gd` now covers 7 cases:
- Test 1: orphan container exists
- Test 2: register/unregister API + new `PersistentNodeEntry` struct validation
- Test 3: evacuate persistent node from a fake cell
- Test 4: stale-entry lazy pruning on free
- **Test 5 (NEW):** re-home on cell load — register → evacuate → rehome into a fresh cell node → assert reparent + global transform preserved
- **Test 6 (NEW):** bound policy by Chebyshev distance — register → evacuate → move camera 9 cells away → prune → assert expiry
- **Test 7 (NEW):** bound policy by age — register → evacuate → rewind `created_ms` by 6 minutes → prune → assert expiry

All 7 pass headless (no real cell stream required — the tests drive `_rehome_persistent_nodes_for_cell` and `_prune_expired_orphans` directly with fake cell Node3Ds). Full gdUnit4 suite (33 test cases) green on 2026-04-09.

### 17.0 Architecture rewrite (2026-04-09) — velocity-drive replaces kinematic direct-write

After three sessions of patching vibration in the kinematic direct-write architecture (see the now-deleted §17.2.1 and the retained §17.5 historical note), the user pasted the canonical HL2 physics-gun pattern and asked why we weren't using it. Answer: we were on the wrong architecture. Ripped out and replaced 2026-04-09.

**What the new CarryController does:**
- Body stays `freeze = false` during hold (dynamic, Jolt integrates)
- `gravity_scale = 0` while held (chase target dictates position, no gravity sag)
- `linear_damp` / `angular_damp` bumped to prevent oscillation
- Each `_physics_process` tick: `linear_velocity = clamp((target - body) * PULL_STRENGTH, MAX_SPEED)` + shortest-path quaternion angular velocity toward the target basis
- Release = stop overwriting velocity. Body retains its current chase velocity as the natural throw impulse. Camera-swing release = fast throw, stationary release = soft drop. No threshold, no ring buffer, no cross-product math.

**What the rewrite deleted** (~360 lines net):
- Manual chain composition (`player_xf_interp * camera_pivot.transform * spring_arm.transform * ...`)
- Wall pushback raycast + `_hold_capture_local` immutable cache (Jolt collisions handle walls natively now)
- Camera-basis ring buffer + `CameraSample` class + `_sample_camera_basis` + `_measure_camera_angular_velocity` (throw math is automatic)
- Throw lever-arm cross product + `is_throw` dispatch + tumble application (physics gives it for free)
- Exponential lerp rate constants (`HOLD_LERP_RATE`, `HOLD_ROT_LERP_RATE`, `HOLD_PULLBACK_MAX`, `HOLD_PULLBACK_TIMEOUT`)
- Throw threshold constants (`THROW_THRESHOLD_ANGULAR_RAD_S`, `THROW_THRESHOLD_LINEAR_M_S`, `THROW_IMPULSE_LINEAR`, `THROW_SAMPLE_WINDOW_MS`, `THROW_IMPULSE_ANGULAR_TUMBLE`)
- Per-node `physics_interpolation_mode = PHYSICS_INTERPOLATION_MODE_OFF` on the held body (the body is INHERIT now, engine smooths it like any other physics body)
- `reset_physics_interpolation()` calls on grab/release
- `_pullback_max_time_msec` and force-drop timer

**What the rewrite kept:**
- Public API (`try_grab`, `release`, `is_carrying`, `get_held_body`, `get_held_pickup`, `get_hold_target_marker`, `set_streaming_manager`, signals) — identical, no consumer changes needed.
- Weight cap refusal (`MAX_GRAB_MASS_KG = 50`, `grab_refused` signal)
- Per-grab hold marker capture (camera-local position of body at grab time, clamped to `MIN/MAX_HOLD_DISTANCE`)
- Mask flip (`LAYER_PLAYER` bit cleared during hold, restored on release per §6.5)
- Roll lock (target basis = yaw + pitch, roll zeroed per §6.2)
- Deferred state mutation at grab/release (§6.2 rule — per-tick velocity writes are exempt, they're the canonical safe path)
- I.6 streaming manager integration (`set_streaming_manager` + `register_persistent_node` / `unregister_persistent_node` duck-typed calls)
- `_exit_tree` shutdown safety (simpler because body isn't frozen)
- NaN guard on velocity writes

**Why velocity-drive works when direct-write didn't**: Kinematic direct-transform writes from `_process` fight Godot's physics-interpolation system. The engine interpolates physics body transforms between tick snapshots; when we write `body.global_transform = X` at render rate, Jolt's interpolation state is overwritten mid-frame and the renderer sees a mix of engine-interpolated and directly-written values at different beat frequencies. Velocity-drive sidesteps this: we set the body's velocity in `_physics_process` (the canonical safe path that every physics body uses), Jolt integrates the velocity over the tick, engine interpolation smooths the output between ticks. No fight, no beat frequencies, no vibration.

**Canonical lesson locked in `.claude/CLAUDE.md`** under "Engineering Principle — Simplicity Over Over-Engineering". If a future agent is tempted to add a direct-write path because "the velocity drive lags too much for my use case", escalate first — the answer is almost certainly to tune PULL_STRENGTH + damping, not to bypass Jolt.

**Test scene for the velocity-drive pattern in isolation**: `tests/visual/test_carry_velocity_drive.tscn` — standalone harness with pull-strength tuning (F8), snap mode A/B (F5), auto-wiggle (F7), CSV telemetry (F4). Kept as a reference implementation and tuning sandbox.

---

End-of-session 2026-04-08 snapshot. **I.0 through I.7 shipped.** Vibration residual (§17.2.1) parked. Next deliverables: I.6 Phase 2 (re-home on cell load + bound policy + walk-back), §17.2.3 throw mass weighting (now unparked), main-scene integration of the carry stack into `world_explorer`. Future agents picking up the work should read this section first.

### 17.1 What shipped (I.0 → I.7)

- **I.0** — `PlayerController` is single owner of `interact` action. Three signals (`interact_tap` / `interact_hold_begin` / `interact_release`) + modal-gate registry. Raycaster purified to pure-state (no input handling).
- **I.1** — `CarryableRegistry` (framework) + `MWCarryableRegistry` (adapter, 12 MW types + LIGH `FLAG_CAN_CARRY` filter) + `CarryableBodyFactory` (in-place StaticBody3D → RigidBody3D swap, frozen KINEMATIC, layers Environment+Interactable, mass clamped). Wraps body in `PickupInteractable` parent so raycaster walk-up finds it. **MF4 mesh-follow restructure**: visual children of the prop root are reparented under the new RigidBody3D so they follow when the body moves.
- **I.2** — `InventoryService` framework base + `MWInventoryService` adapter stub. `PickupInteractable.interact()` routes through `current().store_item()`. On `OK`, despawn via deferred atomic helper that quiesces the RB before queue_free. On `INVENTORY_FULL`/`FORBIDDEN`, body stays + `pickup_refused` signal fires.
- **I.3** — `CarryController` with **direct global_transform writes** (NOT kinematic reparent — see §17.5 architecture note). Hold pose captured per-grab in camera-local space; marker rides the camera; body lerps toward marker via manual physics interpolation. Roll-locked to camera yaw + pitch, no roll. Mask flip clears `LAYER_PLAYER` bit during hold, restored on release.
- **I.4** — Throw + weight cap + wall pushback. Camera angular velocity ring buffer (50 ms time-keyed window). Weight cap refusal at grab time (`MAX_GRAB_MASS_KG = 50`, emits `grab_refused` signal). Throw vs drop dispatch in unified `_do_release` deferred helper, lever-arm cross product impulse + tumble. Wall pushback raycast in `_process` (read-only against physics server, marker mutation only).
- **I.5 (2026-04-08)** — Auto-buoyancy. `BuoyancyBody3D` substituted into `CarryableBodyFactory` when `OceanManager.is_initialized()`. AABB-derived 5-probe layout (4 bottom corners + center) auto-generated at spawn time, no per-item authoring. Frozen-body tick guard (`if freeze: return` early-out in `_physics_process`) verified mandatory by `tests/diagnostic/frozen_rb_tick_check.tscn` and shipped. Test scene `tests/visual/test_interaction_phase_I5.tscn` — apple/barrel/crate float on the ocean surface; 3 self-tests PASS.
- **I.6 plumbing (2026-04-08)** — Streaming-safe orphan registry. `NativeStreamingManager` gains `register_persistent_node(node, original_grid)` / `unregister_persistent_node(node)` / `find_grid_for_node(node)` public API plus an `OrphanedCarriedItems` `Node3D` child container (NOT a new autoload). The cell unload path now calls `_evacuate_persistent_nodes_from_cell()` BEFORE the cell goes into the budgeted teardown queue — registered nodes are reparented to the orphan container with `keep_global_transform=true`. The persistent-node dictionary is intentionally untyped because typed `Dictionary[Node3D, Vector2i]` crashes the iterator on freed object keys in Godot 4.6 (lazy pruning needs untyped). 4 self-tests PASS in `tests/visual/test_interaction_phase_I6.tscn`.
- **I.6 carry-side wiring (2026-04-08)** — `CarryController` gains `set_streaming_manager(node)` setter (type-erased to `Node` so the framework class doesn't import the streaming script — coupling by inversion). `_do_grab` calls `register_persistent_node(rb, find_grid_for_node(rb))` after the body's mode flip; `_do_release` calls `unregister_persistent_node(rb)` after the mask restore. Both calls duck-typed via `has_method` so test scenes without a streaming pipeline (`_streaming_manager == null`) skip the calls cleanly. Streaming manager has zero knowledge of `CarryController` — coupling stays one-way. Main-scene integration (`world_explorer` calling `carry.set_streaming_manager(streaming_manager)` at startup) is the next deliverable. Re-home on cell load + bound policy (5 min OR 8 cells away despawn, spec §13 Q7) + walk-back case remain deferred to the I.6 Phase 2 ship.
- **I.7 (2026-04-08)** — Door / container / activator adapters. `door_interactable.gd` wraps DOOR records, emits `door_activated(record_id, door_record, player)` for the future portal driver to consume — prompt switches between "Open <name>" and "Travel to <destination>" based on `has_destination`. `container_interactable.gd` wraps CONT records, emits `container_opened(record_id, container_record, player)` for the future container UI; locked containers refuse with `container_refused(record_id, reason)` and append "(Locked)" to the prompt. `activator_interactable.gd` wraps ACTI records, emits `activator_triggered(record_id, activator_record, script_id, player)` for the future BNAM result-script interpreter (Skyrim Activator pattern, OpenMW lineage). Carry-mode exclusivity gate at the tap path is already enforced in `PlayerController._emit_interact_tap` (returns early if `_carry_controller.is_carrying()`); the hold path defers to `CarryController.try_grab` which internally refuses with "Already carrying". Sig 11 shutdown crash (§17.3) **FIXED** via `CarryController._exit_tree`: explicitly restores any held body to canonical Jolt state (unfrozen, default mask, INHERIT interpolation, zero velocities) and nulls out the marker reference before the scene tree continues unwinding, so Jolt has a clean window to release the body's RID without `_process` writes still hammering its transform. Test scene `tests/visual/test_interaction_phase_I7.tscn` — 4 self-tests PASS (door prompt + signal payload, container locked/unlocked refused/opened, activator script_id payload, sig 11 fix smoke test).

#### Project-wide physics interpolation enabled (2026-04-08)

`project.godot` now sets `physics/common/physics_interpolation = true` and `rendering/anti_aliasing/quality/msaa_3d = 2` (4x MSAA). Both changes are project-wide and were prompted by the carry vibration debugging — see §17.2.1 for the diagnostic trail. The interpolation flip also turned on **per-node carve-outs** that future agents must be aware of:

- `player_controller.gd::_setup_camera` — `camera_pivot.physics_interpolation_mode = PHYSICS_INTERPOLATION_MODE_OFF` so mouse-driven rotation in `_unhandled_input` stays render-rate fresh instead of being smoothed at the physics tick rate.
- `fly_camera.gd::_ready` — same carve-out, covers every test scene that uses `FlyCamera` (world_explorer, lapalma_explorer, test_underwater, test_weather, test_stencil_portal, test_interior_transition, test_interaction).
- `carry_controller.gd::_do_grab` — held body sets `physics_interpolation_mode = PHYSICS_INTERPOLATION_MODE_OFF` + calls `reset_physics_interpolation()`. `_do_release` restores to `INHERIT` + resets again so the body can be smoothed by the engine post-release.

**Per-node carve-out rule** (corrected from the initial migration plan): direct-write transforms whose source signal is **stepped at physics tick rate** (e.g. read via `global_position` from a chain that includes a `CharacterBody3D` ancestor) MUST be left INHERIT so the engine can smooth them. Direct-write nodes whose source is itself render-rate (mouse rotation) MUST be carved OUT so the engine doesn't smooth fresh writes into stale ones. The discriminator is the source signal's update frequency, not whether the node has direct writes. Carve-out + `reset_physics_interpolation()` is correct ONLY for **discontinuous** writes (teleports, respawns, scene loads, grabs). Auditing existing direct-write call sites is queued as Phase B of the migration (`grep "global_transform = " in _process` callsites under `src/core/` and `src/tools/`).

### 17.2 KNOWN ISSUES — carry-forward into next sessions

These are real bugs the user observed in interactive playtest at the end of session 2026-04-07. They are NOT blocking the I.0-I.4 ship state (the framework works) but they degrade the feel and need to be fixed before main-scene integration.

#### 17.2.1 ~~Hold-pose vibration~~ SOLVED 2026-04-09

The entire vibration saga — three sessions of manual snapshot interpolation, project-wide physics interpolation flips, per-node carve-outs, `get_global_transform_interpolated()` swaps, manual chase compositions, SpringArm spring-length suspects, physics-tick-rate speculation — was a symptom of fighting Godot's physics-interpolation system with kinematic direct-transform writes from `_process`. Session 2026-04-09 replaced the entire architecture with the HL2 physics-gun velocity-drive pattern (see §17.0 above). Result: zero vibration, ~360 lines net deleted, no per-node carve-outs on the held body, no manual composition.

Historical chat-trace of what was tried and what the suspects turned out not to matter is preserved in git history (see the commits around 2026-04-07 through 2026-04-09 touching `carry_controller.gd`). The canonical lesson is locked in `.claude/CLAUDE.md` "Engineering Principle — Simplicity Over Over-Engineering" so future agents don't re-derive a bespoke variant of the same wrong answer.

#### 17.2.2 Wall pushback doesn't restore (I.4) — FIXED 2026-04-08

**Symptom (user id=4061):** "trying to grab an object and moving to a wall: brings the object closer to the camera. Moving back: object doesn't move back to its original place. Trying to move front again: can't move, as the object (now closer to the camera) is blocking the character"

**Root cause:** `CarryController._apply_wall_pushback` was reading `_hold_target_marker.position` as the "ideal_local" — but the marker had already been mutated by previous frames' pushback. So `ideal_local` was the *currently pulled-back* position, not the original captured position. When the wall was no longer in the way, the function "restored" to the same mutated value → no-op.

**Fix shipped (2026-04-08):** added `_hold_capture_local: Vector3` field on `CarryController`, set in `_do_grab` from the original camera-local capture, used as the immutable ideal in `_apply_wall_pushback`. The marker's local position remains the *applied* (possibly pulled-back) value, used only as the lerp target. The raycast ideal now always comes from the capture field. Pushback restore works correctly: pull back when wall is in the way, restore to original capture when wall is gone.

**File + line:** `src/core/interaction/carry_controller.gd::_apply_wall_pushback` and `_do_grab` (lines ~336-337 for the field set).

#### 17.2.3 Throw impulse too hot, no mass weighting (I.4)

**Symptom (user id=4061):** "Barrel was thrown. A bit too far and too fast, the swing shouldn't create more energy than the character has (we'll have to link that to the strength ability probably... but later !). I hope that the inertia depends on the object's weight"

**Status:** the lever-arm cross product is correct per spec §6.3 + dimensionally clean per MF1. Two tunings remain:

1. **Strength clamp.** `THROW_IMPULSE_LINEAR` should be derived from a player attribute (Strength ability) when the stat system lands. For now it's a flat constant. TODO: when combat lands, replace with `player.strength * IMPULSE_PER_STRENGTH` and clamp the lever-arm contribution to a reasonable cap.
2. **Mass-aware inertia.** Heavier items should chase the marker more slowly. Current `HOLD_LERP_RATE = 15.0` is fixed. Trivial change: `var rate = HOLD_LERP_RATE / sqrt(rb.mass)` in `_process`. **Don't ship this on top of broken vibration** — confirm vibration fix first, then tune.

**File + line:** `src/core/interaction/carry_controller.gd::_process` (lerp rate) + `_do_release` (throw impulse magnitude).

#### 17.2.4 Crate is tap-takeable (I.2 + I.4 test scene)

**Symptom (user id=4061):** "I could pick up the crate: shouldn't be able to. I understand that this was purely for testing purposes but crates will probably be only activators (containers that we activate to get access to their inventory)"

**Root cause:** the I.4 test scene uses a `MISC` record_id for the heavy crate as a stand-in. The MW `MISC` carryable type (registered by `MWCarryableRegistry`) routes through the standard tap-take inventory path. This is correct framework behavior — the test scene was using the wrong record type.

**Status:** NOT a framework bug. Real MW crates are `CONT` records (containers) which will be handled by I.7's `container_interactable.gd` adapter. The I.4 test scene's crate prop should be relabeled or replaced when I.7 ships and the container adapter exists. Document this as a "test scene needs update" note when I.7 lands.

### 17.3 Crash signature — sig 11 on shutdown — FIXED 2026-04-08

Throughout I.3 + I.4 development the test scene exit consistently crashed with `signal 11 / no GDScript backtrace / no SCRIPT ERROR before the crash` when the user closed the window while holding an item. Root cause: Jolt body cleanup ordering when the scene tree tears down with a frozen kinematic body under direct-transform-write control — `CarryController._process` was still hammering `_held_body.global_transform` while Jolt was releasing the body's RID.

**Fix (shipped 2026-04-08):** `CarryController._exit_tree` explicitly restores any held body to canonical Jolt state before the scene tree continues unwinding:
- `physics_interpolation_mode = INHERIT`
- `freeze = false`
- `linear_velocity = angular_velocity = ZERO`
- `collision_mask = _saved_collision_mask`
- Drop the controller's `_held_body` / `_held_pickup` references so any further `_process` call bails out via the `is_carrying()` guard
- Null out `_hold_target_marker`

Inline mutation is safe in `_exit_tree` because Jolt has stopped integrating the body (project shutdown) and no other system can reference it. This is the one exception to the §6.2 deferred-mutation rule. Smoke-tested in `tests/visual/test_interaction_phase_I7.gd::_test_carry_exit_tree_smoke`.

### 17.4 What's NOT shipped (I.6 Phase 2 + main scene integration)

#### I.5 — Auto-buoyancy — SHIPPED 2026-04-08

See §17.1 entry. `BuoyancyBody3D` substitution in `CarryableBodyFactory` when `OceanManager.is_initialized()`, AABB-derived 5-probe layout auto-generated at spawn time, frozen-body tick guard. Test scene `tests/visual/test_interaction_phase_I5.tscn`, 3 self-tests PASS. **Awaiting user interactive verification** on the floating apple/barrel/crate (window was open at end-of-session 2026-04-08 but user did not pilot before stepping away).

#### I.6 — Carried-object streaming safety + orphan registry

**Plumbing + carry-side wiring SHIPPED 2026-04-08** (see §17.1 entries). Phase 2 (re-home on cell load + bound policy + walk-back) still pending. Spec §10.

**Decision locked (2026-04-08):** Option 2 (conservative path) is the canonical answer. The held body is NOT reparented under the player rig (direct-transform-write architecture). Instead, on cell unload, the streaming manager evacuates registered persistent nodes to `OrphanedCarriedItems` with `keep_global_transform=true`. The direct-transform-write loop in `CarryController._process` continues to drive the body's world position; only the scene-tree parent changes. On release, the carry controller calls `unregister_persistent_node()` and the body is re-homed (Phase 2).

**Constraint enforcement:** the streaming manager does NOT import `CarryController`. Coupling is by inversion — `CarryController` imports the streaming manager and calls `register_persistent_node()` itself. Per-framework boundary rule, this keeps the streaming manager game-agnostic. Alternative considered (streaming queries an `is_held(node) -> bool` interface) was rejected because it pushes the dependency direction the wrong way (streaming would have to know that "carryables" exist as a category).

**Carry-side wiring (SHIPPED 2026-04-08):**
- `CarryController.set_streaming_manager(p_streaming_manager: Node)` setter — type-erased to `Node` so the framework class doesn't import the streaming script. Coupling by inversion enforced.
- `_do_grab` after the body's mode flip: `_streaming_manager.register_persistent_node(rb, find_grid_for_node(rb))`. Duck-typed via `has_method` so test scenes without a streaming pipeline (`_streaming_manager == null`) skip cleanly.
- `_do_release` after mask restore: `_streaming_manager.unregister_persistent_node(rb)`. Same duck-typed pattern.
- **Main-scene integration still pending:** `world_explorer` doesn't yet load the carry rig. When carry is wired into the main scene (separate phase), `world_explorer._ready` should call `carry.set_streaming_manager(streaming_manager)` after both nodes exist.

**Re-home on cell load (Phase 2 spec):** when a cell loads, the streaming manager scans `_persistent_nodes` for entries whose `original_grid` matches the loading cell's grid coord. Matching nodes are reparented from `OrphanedCarriedItems` back into the loaded cell's scene tree with `keep_global_transform=true`.

**Bound policy (Phase 2 spec, §13 Q7):** orphan items expire after 5 minutes OR after the player has been 8 cells away (whichever comes first). Expired items auto-despawn via `queue_free` deferred. Track per-entry timestamp and last-known-grid in `_persistent_nodes` (currently the value is just the original grid; needs upgrade to a small struct with timestamp + walk-away tracking).

**Walk-back case:** player drops in cell A, walks away (A unloads, body orphaned), walks back (A reloads). The reload-path scan finds the orphan and reparents it back into A's tree at the body's current world position. If that position is no longer valid (e.g. fell through deformed terrain), spec is undefined — propose: drop to cell ground via raycast.

**Self-tests for full I.6:** load cell A, grab a body, walk to cell B (cell A unloads), assert body still alive + still being carried + reparent landed in `OrphanedCarriedItems`. Walk back to A (A reloads), assert orphan re-homed back into A's tree.

#### I.7 — Door / container / activator adapters — SHIPPED 2026-04-08

See §17.1 entry. Three adapters in `src/core/interaction/morrowind/`:
- `door_interactable.gd` — emits `door_activated(record_id, door_record, player)`. Prompt switches between "Open <name>" and "Travel to <destination>" based on `has_destination`. Decoupled from the existing `door_portal.gd` portal driver — consumers listen to the signal and call `DoorPortal.activate()` themselves.
- `container_interactable.gd` — emits `container_opened(record_id, container_record, player)` for the future container UI. Locked containers refuse with `container_refused(record_id, reason)` and append "(Locked)" to the prompt. Lock-level / lockpicking integration deferred to when the lockpicking system lands.
- `activator_interactable.gd` — emits `activator_triggered(record_id, activator_record, script_id, player)` for the future BNAM result-script interpreter. Skyrim Activator pattern, OpenMW lineage. Decorative activators with empty `script_id` still fire the signal but consumers ignore them.

**Carry-mode exclusivity gate** is already enforced at the tap path in `PlayerController._emit_interact_tap` (returns early if `_carry_controller.is_carrying()` — added during I.4). The hold path defers to `CarryController.try_grab` which internally refuses with "Already carrying". Both gates are in place; I.7 doesn't need to add anything new.

Test scene `tests/visual/test_interaction_phase_I7.tscn` — 4 self-tests PASS (door prompt + signal payload, container locked refused / unlocked opened, activator script_id payload, sig 11 fix smoke test from §17.3).

**Phase 2 followups:**
- Wire `door_activated` consumers into the actual `DoorPortal.activate()` driver in `world_explorer` integration
- Container UI panel — hooks `container_opened` signal, opens an inventory transfer screen
- BNAM result-script interpreter — hooks `activator_triggered`, runs MW script bytecode (`PlaySound`, `PlaceItemCell`, `Activate`, etc.)
- Lock/trap detection on `ContainerInteractable` — read MW lock data, set `locked` + `lock_level` at spawn, integrate with future lockpicking

### 17.5 Architecture history — 3 dead ends, 1 canonical answer

The carry architecture went through three iterations before landing on velocity-drive. All three are preserved here for historical context — if you're tempted to re-derive one of them, DON'T, read §17.0 instead.

**Iteration 1 (spec §6.2 original) — kinematic reparent**: parent the held body's wrapper to a Marker3D under the camera, lerp the wrapper's local position, body inherits via scene-tree transform inheritance. **Did not work**: `RigidBody3D` is physics-server-owned. Its global transform is written by Jolt each tick. Reparenting the wrapper updates the scene-tree parent but NOT the physics-server transform. The wrapper followed the camera; the inner RB and its mesh stayed put. Symptom: held items appeared stuck at spawn position while the player walked around.

**Iteration 2 (id=4041 fix) — kinematic direct-transform-write**: `freeze = true, freeze_mode = KINEMATIC`, drive the body via `_held_body.global_transform = ...` from `_process` at render rate. **Worked BUT vibrated**: render-rate transform writes on a physics body fight Godot's physics-interpolation system in subtle ways (the engine's renderer reads an interpolated position between prev/current snapshots, our writes overwrite the cache mid-frame, and the result is a beat-frequency visual wobble at physics-tick-vs-render-rate LCM). Three sessions of patching followed (manual snapshots, project-wide interp flip, per-node carve-outs, `get_global_transform_interpolated` swaps, MSAA). Each reduced the vibration but none eliminated it. See the now-deleted §17.2.1 for the diagnostic trail (git history).

**Iteration 3 (2026-04-09) — HL2 velocity-drive, the canonical answer**: stop kinematic-writing. Keep the body DYNAMIC (`freeze = false`). Each `_physics_process` tick, set `linear_velocity = (target - body_pos) * PULL_STRENGTH` and `angular_velocity` via shortest-path quaternion chase. Jolt integrates the velocity over the tick; Godot 4.6's engine physics interpolation smooths the rendered position between ticks using the same mechanism CharacterBody3D uses. No carve-outs, no manual composition, no wall pushback hack, no throw ring buffer, no lever-arm cross product. Zero vibration. The released body's chase velocity at the moment of release becomes the throw impulse for free. Details in §17.0.

**Why we went through iterations 1 and 2 before getting to 3**: the `@reviewer` agent initially recommended iteration 2 in response to iteration 1's failure. Iteration 2 *almost* worked, which made each subsequent patch look promising. It took three sessions + the user pasting the HL2 snippet in chat for the agent to recognize the canonical pattern. The process lesson is locked in `.claude/CLAUDE.md` "Engineering Principle — Simplicity Over Over-Engineering" rules 1-6.

**Per `INTERACTION_SYSTEM.md` §6.2 deferred-mutation rule, updated:** the rule applies to RB STATE MUTATIONS at TRANSITION events (grab / release / despawn) — those go through `call_deferred` atomic helpers. Per-tick `linear_velocity` / `angular_velocity` writes from `_physics_process` are EXEMPT because they're the canonical Godot physics-body control path (same as `CharacterBody3D.move_and_slide` and every other Jolt-compatible dynamic body).

### 17.6 Files of record

| File | Role |
|------|------|
| `src/core/interaction/interactable.gd` | Framework Interactable base. |
| `src/core/interaction/interaction_raycaster.gd` | Pure-state raycaster, tree_exiting cache invalidation, prompt_changed signal. |
| `src/core/interaction/carryable_registry.gd` | Generic carryable type registry. |
| `src/core/interaction/carryable_body_factory.gd` | StaticBody3D → RigidBody3D swap + Pickup wrapper + MF4 mesh-follow restructure. |
| `src/core/interaction/inventory_service.gd` | Generic inventory base + StoreResult enum. |
| `src/core/interaction/carry_controller.gd` | I.3 + I.4 — hold loop, throw, weight cap, wall pushback. **All RB state mutation deferred.** |
| `src/core/interaction/morrowind/mw_carryable_registry.gd` | 12 MW types + LIGH filter. |
| `src/core/interaction/morrowind/mw_inventory_service.gd` | I.2 stub adapter. |
| `src/core/interaction/morrowind/pickup_interactable.gd` | MW pickup adapter — tap → inventory → despawn. |
| `src/core/world/reference_instantiator.gd` | Routes carryables through CarryableRegistry + factory at spawn. |
| `src/core/player/player_controller.gd` | I.0 input owner + I.3 carry routing. |
| `tests/visual/test_interaction_phase_I0.{tscn,gd}` | I.0 acceptance scene. |
| `tests/visual/test_interaction_phase_I1.{tscn,gd}` | I.1 spawn-path scene. Raw KEY_* (grandfathered). |
| `tests/visual/test_interaction_phase_I2.{tscn,gd}` | I.2 inventory-tap scene. Raw KEY_* (grandfathered). |
| `tests/visual/test_interaction_phase_I3.{tscn,gd}` | I.3 hold/release scene. Action API. |
| `tests/visual/test_interaction_phase_I4.{tscn,gd}` | I.4 throw + weight cap + wall scene. Action API. |
| `tests/visual/test_interaction_phase_I5.{tscn,gd}` | I.5 auto-buoyancy scene. Apple/barrel/crate float on ocean. |
| `tests/visual/test_interaction_phase_I6.{tscn,gd}` | I.6 plumbing self-tests. Persistent node registry + evacuate. |
| `tests/visual/test_interaction_phase_I7.{tscn,gd}` | I.7 self-tests + interactive: door + container (locked/unlocked) + activator + sig 11 fix smoke. |
| `tests/diagnostic/frozen_rb_tick_check.{tscn,gd}` | Verified frozen RB ticks `_physics_process` in 4.6. |
| `src/core/water/buoyancy_body.gd` | I.5 — `BuoyancyBody3D` `RigidBody3D` subclass with frozen-tick guard. |
| `src/core/world/native_streaming_manager.gd` | I.6 plumbing — `register_persistent_node` API + `OrphanedCarriedItems` container + evacuation hook in `_unload_cell`. |
| `src/core/interaction/morrowind/door_interactable.gd` | I.7 — DOOR adapter, emits `door_activated`. |
| `src/core/interaction/morrowind/container_interactable.gd` | I.7 — CONT adapter, emits `container_opened` / `container_refused`. |
| `src/core/interaction/morrowind/activator_interactable.gd` | I.7 — ACTI adapter, emits `activator_triggered` for the future BNAM script interpreter. |

---

## 16. Decision History (Session 2026-04-07)

This section is an audit log of what was done and decided during the original drafting session, so future agents picking up I.0+ implementation work can understand the constraints without re-deriving them from chat history.

### 16.1 Session timeline

| Time   | Event | Outcome / Artifact |
|--------|-------|--------------------|
| start  | `@user` requested audit of physics-interaction-pickup stack on `#interactivity` | Posted findings: collision builder fully built, interaction framework wired in test scene only, buoyancy framework standalone, ZERO pickup/carry/throw code anywhere |
| +20min | `@user` requested design doc for "perfect interactivity that doesn't fight other systems" | Drafted `docs/INTERACTION_SYSTEM.md` §1-§15 |
| +5min  | `@reviewer` review pass: 3 must-fix + 7 should-fix | See §16.2 |
| +10min | M1 verification — frozen-RB tick check | Built `tests/diagnostic/frozen_rb_tick_check.tscn`, ran headless, **confirmed Godot 4.6 ticks `_physics_process` on frozen RigidBody3D**: 59 ticks in 60 frames, freeze=true, freeze_mode=KINEMATIC. Early-out guard mandatory. |
| +10min | All 10 review fixes folded into doc | See §16.2 |
| +5min  | `@reviewer` re-pass — green-light + 5 checklist additions | See §16.3 |
| +20min | Cross-thread API shape coordination (got messy) | See §16.4 |
| +5min  | `@user` shut down crossposting, reassigned channels strictly | `@interactivity` → `#interactivity` only, `@dialogue` → `#text` only |
| +10min | Final API shape locked: signal-based modal gate registry on `PlayerController` | See §3.1 |

### 16.2 Reviewer Round 1 — 3 must-fix + 7 should-fix (all addressed)

| # | Issue | Resolution |
|---|-------|------------|
| **M1** | §6.4 frozen-RB `_physics_process` tick was unverified — whole perf argument depended on it | **Verified empirically** — `tests/diagnostic/frozen_rb_tick_check.tscn` confirms Godot 4.6 ticks frozen RBs every frame. Guard `if freeze: return` is now spelled out in §6.4 with the verification date stamped in the code comment. |
| **M2** | §6.1 vs §13 Q5 layer mask contradiction | New §6.5 "Held-state collision mask" section. Spawn = `Environment | Player`. Grab snapshots mask + clears `PLAYER_BIT`. Release restores before unfreeze + impulse. Single source of truth. |
| **M3** | §6.3 throw step 3 dimensional bug — `camera_angular_motion` (rad/s) added to linear velocity | Fixed: `linear_velocity += camera_angular_velocity.cross(held_position - camera_position)` (lever arm, dimensionally clean rad/s × m → m/s). Unit error called out for paper trail. |
| **S1** | §6.1 mass conversion contradiction (50 kg cap vs 200 kg cap, lbs vs kg) | Committed to "ESM weight treated as kg directly, gameplay-tuned, no lb→kg conversion". `[0.1, 200.0]` clamp is solver sanity only. 50 kg grab refusal lives in `CarryController`, not spawn clamp. One cap, one place. |
| **S2** | §10 orphan registry vs "no new autoloads" rule | Explicit ownership note before §10: `OrphanedCarriedItems` is a child of `NativeStreamingManager`, not a fourth singleton. Promotion to autoload requires explicit reviewer sign-off. |
| **S3** | §8 rule 2 only covered `DialoguePanel.visible`, missed `BookViewer.visible` | Rewritten as "Modal UI gates carry" — covers `DialoguePanel`/`BookViewer`/`JournalPanel`/future container UI via central `is_modal_ui_open()` helper. Spelled out the exact bug it prevents (hold E to read → book lifts mid-read). |
| **S4** | §6.2 hold spring lacked tunable parameters | New "Hold spring tuning" paragraph: stiffness ~80 N/m equivalent (lerp 0.25/frame), max pullback 0.6 m, force-drop after 0.3 s at max. Flagged as I.3-tunable. |
| **S5** | §6.3 throw window was frame-based (`~3 frames`), framerate-dependent | Rewritten as "last 50 ms (time-windowed, framerate-independent — ring buffer keyed by `Time.get_ticks_msec()`)". |
| **S6** | §7 InventoryService failure modes undefined | Full contract table added: `OK` / `INVENTORY_FULL` / `FORBIDDEN` / `INVALID_RECORD` with world-body-action column. Cap policy explicit: inventory cap and grab cap independent. |
| **S7** | Roll-locked rotation for held objects missing | New "Hold pose rotation contract" paragraph in §6.2. Yaw + pitch tracked, roll locked to world up. Snapshot `(yaw, pitch, 0)` Euler. |

### 16.3 Reviewer Round 2 — green-light + 5 checklist additions

After all 10 fixes landed, `@reviewer` approved the doc and asked for 5 new items in §15:
- Modal UI gate API surface
- Held-state mask transition
- Throw lever-arm cross product
- Mass field as kg
- Hold pose roll lock

All 5 added (see §15 lines 377-381). Doc was green-lit for I.0 implementation.

### 16.4 API shape negotiation — three rejected proposals before settling on signal-based

The "how do modal UIs gate input?" question went through three shapes before locking. Documenting them so future agents don't re-propose any of the rejected ones.

**Proposal 1 — counter (`push_modal_ui()` / `pop_modal_ui()` / `_modal_count > 0`)** — `@interactivity` initial proposal in #interactivity id=3870. **Rejected** because counter drifts positive if a panel frees while visible (no final symmetric pop event). Hard to debug for long sessions.

**Proposal 2 — Callable predicate (`register_modal_gate(is_open: Callable)`)** — `@interactivity` revision in #interactivity id=3873, after `@dialogue` pointed out the counter coupling problem. Better than counter (self-healing via `Callable.is_valid()`), but introduced a dialect mismatch: a parallel reviewer post in #text proposed an `InputOwner` enum stack instead.

**Proposal 3 — `InputOwner` enum stack (`push_owner(InputOwner.DIALOGUE)` / `pop_owner()`)** — `@reviewer` override in #text id=3872, with members `{ WORLD, DIALOGUE, BOOK, MENU, CARRY }` (later `+ LOADING`). **Considered** because the enum carries semantic state (mouse mode = `func(owner)`) and lets `PlayerController` be sole owner of `Input.set_mouse_mode`. **Rejected** in #interactivity id=3881 in favor of the simpler signal-based registration: enum adds state nobody currently needs, and the mouse-mode-as-func-of-owner benefit can be layered on top of the bool gate later if needed. YAGNI.

**Locked shape — signal-based registration with `is_open()` contract** (Proposal 4, the keeper). See §3.1 for the full code. Key properties:
- Zero coupling to specific UI types
- Self-healing via `tree_exiting` connection (auto-removes freed gates)
- Debuggable (can dump registered gate names)
- `is_open()` method instead of `.visible` duck-typing because `DialogueUI` is a `CanvasLayer` with no top-level `.visible`
- `InputOwner` enum can be added as a layer on top later if differential per-owner input handling becomes a real requirement

### 16.5 Cross-thread coordination outcome (and what NOT to repeat)

The InputOwner architecture spans both `#interactivity` and `#text` (because `@dialogue`'s `DialogueUI` is the primary consumer of whatever API `@interactivity` ships on `PlayerController`). During the negotiation, both threads got cross-posts and conflicting reviewer decisions (one in each channel). `@user` shut it down — no more crossposting. Channel discipline locked:

- `@interactivity` → `#interactivity` only, reviewed by `@reviewer`
- `@dialogue` → `#text` only, reviewed by `@roaster`
- Cross-thread topics: each agent posts in their own channel, reviewers relay if needed

Future I.0+ implementation work follows this rule strictly.

### 16.6 Sequencing locked

1. **C.2** ✅ shipped earlier in session (`@dialogue` side) — temporary `DialogueSession.is_any_panel_open()` bool gate + raycaster early-out + `interact`-action close handler in `BookViewer`/`DialogueUI`. Unblocks `test_interaction.tscn`. Marked as STOPGAP, deletion target for C.2.5.
2. **I.0** (next) — `@interactivity` builds `PlayerController` with the API in §3.1 + wires `InteractionRaycaster` into `scenes/Godotwind.tscn` + removes `interaction_raycaster.gd:89-102` `_unhandled_input` handler + ships `tests/visual/test_interaction_phase_I0.tscn`
3. **C.2.5** (after I.0) — `@dialogue` side consumes `PlayerController.register_modal_gate()` from `DialogueUI`/`BookViewer`/`JournalPanel`, deletes the C.2 stopgap, deletes per-site `Input.set_mouse_mode` calls
4. **I.1** + **C.5** can ship in parallel after C.2.5

### 16.7 Artifacts created in this session

| Path | Purpose |
|------|---------|
| `docs/INTERACTION_SYSTEM.md` | This doc — the design contract for the entire interaction system |
| `tests/diagnostic/frozen_rb_tick_check.gd` | Diagnostic that proves Godot 4.6 ticks `_physics_process` on frozen RigidBody3D |
| `tests/diagnostic/frozen_rb_tick_check.tscn` | Scene wrapper for the diagnostic — kept as a regression check |

### 16.8 Status as of end-of-session 2026-04-07

- Doc: design-only, **green-lit by `@reviewer`**, ready for I.0 implementation
- Code: zero implementation shipped this session (apart from the diagnostic)
- C.2 hotfix on the dialogue side: shipped, **awaiting `@user` interactive verification** of the topic-click bug
- Next action: `@interactivity` starts I.0 implementation, ships `tests/visual/test_interaction_phase_I0.tscn`, pings `@reviewer` in `#interactivity` for the impl review
