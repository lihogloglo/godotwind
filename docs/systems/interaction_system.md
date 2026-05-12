# Interaction System

Player-world interaction: dialogue, books, doors, containers, pickup, carry, throw. One input button (`interact`, default E) cleanly handles all verbs without systems stepping on each other.

The framework lives in `src/core/interaction/`; Morrowind-specific verb mappings live in `src/core/interaction/morrowind/`. Zero MW imports allowed in framework files.

**Status:** I.0–I.7 shipped; main-scene integration shipped 2026-04-09; carry vibration solved by velocity-drive rewrite 2026-04-09. See `docs/archive/sessions/interaction_phase_I_ship_log.md` for the full ship narrative + architecture iteration history.

---

## 1. Goals

1. **One button.** Same `interact` action picks up an apple, opens a dialogue, reads a book, opens a door, opens a container, grabs a sword.
2. **Tap vs hold disambiguation.** Tap → "primary verb" of the target. Hold → "grab and carry" if carryable; otherwise the hold gesture is ignored and tap fires on release.
3. **No conflicts.** While carrying, other interactions are gated. Combat input is gated separately.
4. **Framework-agnostic.** No game-specific logic in the generic Interactable / Raycaster / Carry stack.
5. **Streaming-friendly.** Carryables coexist with cell streaming, object pooling, the static-renderer fast path, and Jolt sleeping.
6. **Buoyancy-friendly.** Dropped/thrown items that land on water float without per-item authoring.

## 2. Non-Goals

- Combat hitbox/hurtbox plumbing — separate doc, separate layers.
- Magic interaction (Telekinesis, Open spell) — handled by spell effects.
- AI agent interaction with the world — out of scope here.
- Save/load of dropped item positions — separate save-system doc.

---

## 3. Input Model

`interact` has three discrete events derived from one InputMap action:

| Event | Trigger | Used by |
|---|---|---|
| `interact_tap` | Press + release within `HOLD_THRESHOLD` (0.20 s) | Default verb on the targeted Interactable |
| `interact_hold_begin` | Press, held longer than `HOLD_THRESHOLD` | Start carry on the targeted Interactable (if carryable) |
| `interact_release` | Release after `interact_hold_begin` already fired | End carry: drop or throw |

The raw `interact` action is owned by exactly one active input context:

- `PlayerGameplayContext`: active in player-controller mode. `PlayerController` reads raw `interact`, feeds the shared `InteractionIntent` helper, and emits/routes the three semantic events as signals.
- `FlyCameraContext`: active in fly-camera/debug mode. `world_explorer.gd` reads raw `interact`, feeds the same `InteractionIntent` helper, and routes equivalent semantic outcomes through the fly raycaster/carry controller.

Every consumer listens to those semantic outcomes or asks the active raycaster for state. No system should add an ungated second `Input.is_action_pressed("interact")` reader.

### 3.1 Modal gate registry

Signal-based registry. `PlayerController` is the player-mode input owner; modal UIs register themselves as gates.

```gdscript
# src/core/player/player_controller.gd
signal interact_tap()
signal interact_hold_begin()
signal interact_release()

const HOLD_THRESHOLD: float = 0.20  # seconds

# src/core/interaction/interaction_intent.gd owns the shared splitter.

func register_modal_gate(gate: Node) -> void   # gate.has_method("is_open")
func unregister_modal_gate(gate: Node) -> void
func is_modal_ui_open() -> bool
```

While ANY registered gate's `is_open()` returns true, `PlayerController` suppresses interact_* signal emission. Gates self-heal via `tree_exiting` on free.

**Contract for modal UIs:**
- Implement `is_open() -> bool` method (`DialogueUI`, `BookViewer`, `JournalPanel` all do).
- On `open()` / `show_*()` → call `PlayerController.register_modal_gate(self)` (idempotent).
- On `close()` / `hide_*()` → call `PlayerController.unregister_modal_gate(self)`.

**Why `is_open()` and not `.visible`:** `DialogueUI` extends `CanvasLayer` with internal `_root_control.visible` state, not a top-level `visible` property. Duck-typing would skip CanvasLayer-rooted UIs.

**Hold detection lives in polling** (player mode uses `_physics_process`; fly mode uses the main-scene process loop) because input events fire only on press/release. `InteractionIntent` ensures a single hold-begin outcome per press. Modal-gate checks remain in the active context too — if a panel opens mid-press, the hold doesn't fire.

The `_ensure_input_actions` runtime safety net at `player_controller.gd:421` is REDUNDANT after K.0 (input system) ships but deliberately left in place — see `docs/systems/input_system.md` §3.3.

## 4. Targeting

`InteractionRaycaster` (`src/core/interaction/interaction_raycaster.gd`) sits on the active camera and casts forward each physics frame against collision layer 3. It maintains `_current_target: Interactable` and emits `prompt_changed` whenever it changes. It does NOT call `interact()` itself — the active input context asks the active raycaster for `get_current_target()`.

Carry mode suppresses prompt output through `InteractionRaycaster.set_prompt_suppressed(true)` while leaving target acquisition intact. `PlayerController` wires this from player carry signals; the main-scene fly context wires the same behavior from the fly carry controller.

```
PlayerController
   ├─ on interact_tap        → if target: target.interact(player)
   ├─ on interact_hold_begin → if target and target.is_carryable(): CarryController.grab(target)
   └─ on interact_release    → if carrying: CarryController.release(throw=is_moving_camera_fast)
```

## 5. Interactable Verb Taxonomy

Every `Interactable` declares its **primary verb** (tap action) and whether it is **carryable** (hold action). Base class:

```gdscript
func is_carryable() -> bool: return false
```

| Bucket | Tap verb | Carryable | MW adapter |
|---|---|---|---|
| NPC | Talk | No | `npc_interactable.gd` |
| Book | Read / Unroll | Yes | `book_interactable.gd` |
| Pickup | Take (inventory) | Yes | `pickup_interactable.gd` |
| Door | Open / Travel | No | `door_interactable.gd` |
| Container | Open | No | `container_interactable.gd` |
| Activator | Activate | No | `activator_interactable.gd` |

Books are both readable (tap) AND grabbable (hold) — same Interactable handles both because tap and hold are routed by different events.

---

## 6. Carry Mechanics

### 6.1 Carryable spawn path

`reference_instantiator.gd` routes records whose ESM type is in the **carryable set** (WEAP, ARMO, BOOK, CLOT, MISC, INGR, ALCH, REPA, PROB, LOCK, APPA, SCRL, plus LIGH where `FLAG_CAN_CARRY`) through `CarryableBodyFactory`, which builds a `RigidBody3D` (substituted for `BuoyancyBody3D` when `OceanManager.is_initialized()`):

- `collision_layer = Environment | Interactable` (bits 1 and 3)
- `collision_mask = Environment | Player`
- `freeze = true`, `freeze_mode = FREEZE_MODE_KINEMATIC` (zero solver cost at rest)
- `mass` from ESM weight, treated as kg directly, hard-clamped to `[0.1, 200.0]`
- A `PickupInteractable` child carries the ESM `record_id`

Carryables are by definition Node3D-bound; the static-renderer fast path is excluded.
The named layer bits live in `src/core/physics/gameplay_physics_layers.gd`;
the helper is preloaded by systems that need the contract and is not an
autoload.

### 6.2 Hold mechanism — HL2 physics-gun velocity drive (canonical)

```
Each _physics_process tick on the held body:
    linear_velocity  = clamp((target_pos - body_pos) * PULL_STRENGTH, MAX_SPEED)
    angular_velocity = shortest_path_quaternion_chase(target_basis, body_basis)
On grab: gravity_scale = 0, linear_damp + angular_damp bumped, body stays DYNAMIC
On release: stop overwriting velocity. Body retains chase velocity → throw impulse for free.
```

Body stays `freeze = false` during hold; Jolt integrates the velocity over the tick; engine physics interpolation smooths the rendered position between ticks (same mechanism `CharacterBody3D` uses). No carve-outs, no manual composition, no wall-pushback raycast, no throw ring buffer. Camera-swing release = fast throw, stationary release = soft drop.

**Roll lock:** target basis built from camera yaw + pitch only, roll zeroed. Held objects rolling with camera roll looks drunk.

**Grab/release symmetry contract:** the grab path explicitly asserts the canonical hold state (`gravity_scale = 0`, damp values, layer mask cleared). The release path explicitly restores defaults. Both paths must reverse each other exactly.

### 6.3 Deferred mutation rule

All `RigidBody3D` STATE MUTATIONS at TRANSITION events (grab / release / despawn / mask flip / freeze toggle / reparent) MUST happen via `call_deferred` atomic helpers. Per-tick `linear_velocity` / `angular_velocity` writes from `_physics_process` are EXEMPT — they're the canonical Godot physics-body control path.

Reads inline are fine. Snapshotting `rb.collision_mask` for restore-later is a read; only mutations are dangerous.

```gdscript
func try_grab(target: Interactable) -> bool:
    _saved_collision_mask = rb.collision_mask  # PURE READ — fine inline
    _do_grab.call_deferred(target, rb)         # mutations deferred
    return true
```

### 6.4 Buoyancy

`BuoyancyBody3D` extends `RigidBody3D`. Substituted into `CarryableBodyFactory` when `OceanManager.is_initialized()`. AABB-derived 5-probe layout (4 bottom corners + center) auto-generated at spawn time, no per-item authoring.

**Frozen-body tick guard — VERIFIED REQUIRED.** Godot 4.6 ticks `_physics_process` on a frozen `RigidBody3D` every physics frame (59 ticks in 60 frames, verified `tests/diagnostic/frozen_rb_tick_check.tscn`). Without the guard, every clutter item pays the full ocean wave-height query each frame even at rest indoors:

```gdscript
func _physics_process(delta: float) -> void:
    if freeze:
        return
    # ... existing logic
```

### 6.5 Held-state collision mask

| State | Mask | Reason |
|---|---|---|
| Spawned / dropped / thrown | `Environment \| Player` | Rolling apple bumps player's foot |
| Held (carried) | saved mask minus the player's current collision-layer bits | Held object must not push player around, including during interior layer rewrites |

Single source of truth in `CarryController`: grab saves the exact pre-hold
mask, hold state excludes `player.collision_layer` via
`GameplayPhysicsLayers`, and release restores the saved mask bit-for-bit before
unfreeze. This is deliberate because `InteriorPocketManager` can temporarily
move the player from the normal player bit onto exterior plus interior-slot
physics layers. Don't change carry masks anywhere else.

---

## 7. Inventory Routing

`PickupInteractable.interact(player)` (the tap path) calls into a generic `InventoryService` with the ESM record_id and qty 1.

`store_item(record_id: StringName, qty: int) -> StoreResult`:

| Result | World body action |
|---|---|
| `OK` | Despawn (queue_free deferred) |
| `INVENTORY_FULL` | Stay in world, prompt "Inventory full" |
| `FORBIDDEN` | Stay in world, prompt "You are not allowed to take this" |
| `INVALID_RECORD` | Stay in world, log error |

**Cap policy:** Inventory enforces its own weight/slot cap independently of `CarryController`'s 50 kg grab cap. Tap = "give to inventory" (inventory may refuse). Hold = "lift physically" (CarryController may refuse if mass > 50 kg). The two caps are unrelated: a player with a full inventory can still grab and carry a sword.

---

## 8. Cross-System Non-Conflict Rules

1. **Carry mode is exclusive.** While `CarryController.is_carrying()`, raycaster suppresses prompt updates and `PlayerController` ignores `interact_tap`. Doors/dialogue/containers cannot be activated while carrying — matches Oblivion.
2. **Modal UI gates carry.** When ANY modal UI is open, `PlayerController` stops emitting interact events entirely. Critical for books (readable + carryable): without the gate, holding E to read would lift the book out of the reader's hands.
3. **Combat owns its own button.** `attack` / `block` are independent of `interact`. The only interaction is "while weapon drawn and carryable targeted, hold-to-grab still works" — lets the player throw a chair mid-fight.
4. **No double raycast.** Only `InteractionRaycaster` casts on layer 3. Other systems read `raycaster.get_current_target()`.
5. **One active input owner.** Only `PlayerGameplayContext` or `FlyCameraContext` reads raw `interact` at a time.
6. **Cell streaming respects carried objects.** See §10.
7. **Interactable layer is layer 3 ONLY.** Don't add interactables to other layers; don't add non-interactables to layer 3.
8. **No `Area3D.monitoring = true` on items.** Detection is pull-based.

---

## 9. Layer Plan

```
layer_1 = Environment   (terrain, walls, statics)
layer_2 = Player        (the player CharacterBody3D)
layer_3 = Interactable  (NPCs, books, activators, pickups)
```

Carryables go on **both** layer 1 and layer 3. Reserved for combat: `layer_4 = Hitbox`, `layer_5 = Hurtbox`, `layer_6 = WaterVolume`.

`OrphanedCarriedItems` is a child of the streaming manager (`NativeStreamingManager`), NOT a new autoload.

---

## 10. Carried-Object Lifetime During Streaming

The streaming manager owns a `OrphanedCarriedItems` Node3D child container. Held bodies are NOT reparented under the player rig; instead, on cell unload, the manager evacuates registered persistent nodes via `_evacuate_persistent_nodes_from_cell` to the orphan container with `keep_global_transform=true`.

`CarryController` calls:
- `register_persistent_node(rb, find_grid_for_node(rb))` after `_do_grab`
- `unregister_persistent_node(rb)` after `_do_release`

Both duck-typed via `has_method` — test scenes without a streaming pipeline skip cleanly. `CarryController` imports the streaming manager (coupling by inversion); the streaming manager has zero knowledge of `CarryController`.

**Re-home on cell load (Phase 2 shipped 2026-04-09):** `_rehome_persistent_nodes_for_cell` is called from sync + async cell-load paths. Walks `_persistent_nodes`, filters by `original_grid` and parent-is-orphan-container, reparents back into the loaded cell with `keep_global_transform = true`.

**Bound policy:** orphans expire after `ORPHAN_EXPIRY_MS = 5 min` OR Chebyshev distance > `ORPHAN_EXPIRY_CELL_DISTANCE = 8` cells. Pruned every `ORPHAN_PRUNE_INTERVAL_S = 1.0` s. Held items skipped (parent is the camera Marker3D).

**Walk-back ground snap:** raycasts down 3 m / up to 50 m against layer 1, snaps to ground if current position is > 0.25 m off. Only corrects genuinely invalid placements; resting items stay where they were.

---

## 11. Combat Compat (forward look)

When combat lands: `attack` and `block` actions independent of `interact`. `WeaponSwingController` does its own collision query against layers 4/5, unrelated to the raycaster. A held physics object is NOT a weapon — swinging a chair uses normal rigidbody contact damage.

Nothing in combat reaches into the interaction system. Zero shared code paths beyond layer 3.

---

## 12. Adapter Pattern

```
src/core/interaction/                       Framework (no MW imports)
    interactable.gd                         Base + is_carryable() default
    interaction_raycaster.gd                Pure-state raycaster
    carry_controller.gd                     HL2 velocity drive
    inventory_service.gd                    Abstract base + StoreResult
    carryable_registry.gd                   Generic registry
    carryable_body_factory.gd               StaticBody3D → RigidBody3D swap

src/core/interaction/morrowind/             MW adapter
    pickup_interactable.gd                  Tap → inventory → despawn
    door_interactable.gd                    Emits door_activated
    container_interactable.gd               Emits container_opened / container_refused
    activator_interactable.gd               Emits activator_triggered (BNAM future)
    mw_carryable_registry.gd                12 MW types + LIGH FLAG_CAN_CARRY
    mw_inventory_service.gd                 Concrete adapter
```

---

## 13. Open Items

- **Throw threshold tuning** — camera angular velocity vs linear is platform-feel; needs in-engine playtest.
- **Hold-to-grab UX feedback** — proposed side-by-side prompt ("Tap E: Take | Hold E: Lift") for carryable-with-tap-verb.
- **Steal from NPC inventory** — out of scope for Phase 1, requires container UI first.
- **Two-handed objects** — Phase 1 treats all as one-handed; weight cap gates hold (refuse > 50 kg, "too heavy").
- **Strength-stat link** — `THROW_IMPULSE_LINEAR` should derive from a player Strength attribute when stats land.
- **Container UI panel** — hooks `container_opened` signal, opens inventory transfer screen.
- **BNAM result-script interpreter** — hooks `activator_triggered`, runs MW script bytecode (`PlaySound`, `PlaceItemCell`, `Activate`, etc.).
- **Lock/trap detection on `ContainerInteractable`** — read MW lock data, integrate with future lockpicking.

---

## 14. Main-scene wiring (2026-04-09)

`world_explorer._setup_cameras` wires:
- `InteractionRaycaster` instantiated under `player_controller.get_camera()`, `max_distance = 5.0`, `physics_process` gated on camera mode (disabled in fly mode, enabled on player switch).
- `CarryController` instantiated under `player_controller`, `setup(camera, player)` called, `set_carry_controller()` routed through `PlayerController`.
- `set_streaming_manager()` deferred to `_setup_pocket_manager` so both nodes exist before the I.6 hand-off.
- `cell_manager.set_door_activated_handler(_on_door_interactable_activated)` plumbs a `Callable` through `CellManager` → `ReferenceInstantiator` so every spawned `DoorInteractable` connects its `door_activated` signal at creation time.

Player mode defaults to third-person (`set_camera_mode(THIRD_PERSON)`, `allow_camera_mode_switch = true`); TAB toggles freely.

**DoorInteractable spawn:** for every `type_name == "door"` reference whose `ref.is_teleport` is true (DODT subrecord present), the door instance's root `Node3D` is promoted to a `DoorInteractable` via `set_script`. `_add_interactable_layer_recursive` ORs the Interactable bit (`1 << 2`) onto every `CollisionObject3D` in the door subtree.

**FlyCameraContext:** `world_explorer._unhandled_input` is gated on `_camera_mode == FLY_CAMERA`. In fly mode, the unified `interact` action uses the fly raycaster and the shared `InteractionIntent` splitter to route tap to the current Interactable and hold/release to the fly carry controller. In player mode, `PlayerController` owns the same action. The camera-mode gate prevents double-activation.

---

## 15. Files of record

| File | Role |
|---|---|
| `src/core/interaction/interactable.gd` | Framework Interactable base |
| `src/core/interaction/interaction_raycaster.gd` | Pure-state raycaster, prompt_changed signal |
| `src/core/interaction/carry_controller.gd` | HL2 velocity-drive hold loop |
| `src/core/interaction/carryable_registry.gd` | Generic carryable type registry |
| `src/core/interaction/carryable_body_factory.gd` | StaticBody3D → RigidBody3D swap |
| `src/core/interaction/inventory_service.gd` | Generic inventory base + StoreResult |
| `src/core/interaction/morrowind/mw_carryable_registry.gd` | 12 MW types + LIGH filter |
| `src/core/interaction/morrowind/mw_inventory_service.gd` | I.2 stub adapter |
| `src/core/interaction/morrowind/pickup_interactable.gd` | Tap → inventory → despawn |
| `src/core/interaction/morrowind/door_interactable.gd` | DOOR adapter, `door_activated` |
| `src/core/interaction/morrowind/container_interactable.gd` | CONT adapter, `container_opened` / `container_refused` |
| `src/core/interaction/morrowind/activator_interactable.gd` | ACTI adapter, `activator_triggered` |
| `src/core/world/reference_instantiator.gd` | Routes carryables through CarryableRegistry + factory |
| `src/core/world/native_streaming_manager.gd` | Persistent-node registry + orphan container + re-home + bound policy |
| `src/core/water/buoyancy_body.gd` | `BuoyancyBody3D` with frozen-tick guard |
| `src/core/player/player_controller.gd` | Single input owner + carry routing |
| `tests/visual/test_interaction_phase_I0..I7.{tscn,gd}` | Per-phase acceptance scenes, all PASS |
| `tests/visual/test_carry_velocity_drive.tscn` | Standalone HL2 pattern reference + tuning sandbox |
| `tests/diagnostic/frozen_rb_tick_check.{tscn,gd}` | Verified frozen RB ticks `_physics_process` in 4.6 |

---

For the architecture iteration history (kinematic reparent → kinematic direct-write → velocity-drive) and the carry-vibration saga, see `docs/archive/sessions/interaction_phase_I_ship_log.md`.
