# Input System

**Owner:** @keys
**Status:** K.0 + K.0.5 shipped 2026-04-07
**Coordination:** Reads `interact` action only — owned by `PlayerController` per `docs/systems/interaction_system.md` §3.1.

---

## 1. Overview

Godotwind defines all input via Godot's native `InputMap`, with action definitions stored in `project.godot [input]`. The action namespace is documented as code constants in `src/core/input/input_actions.gd`. Test scenes inherit the action map automatically — no autoload, no base scene, no per-scene wiring needed.

**Three design pillars:**

1. **Layout-independent.** Every keyboard binding uses `physical_keycode`, not `keycode`. AZERTY, QWERTY, and Dvorak users press the same physical key positions and get the same actions.
2. **Controller parity from day 1.** Every gameplay action has both a keyboard binding and a gamepad binding in K.0 — not deferred to a later phase.
3. **One owner per action.** No two systems read the same action via `Input.is_action_*`. Coordination contracts are documented inline.

---

## 2. Action table

| Action            | Category    | Keyboard (physical) | Gamepad             | Owner / reader                       |
|-------------------|-------------|---------------------|---------------------|--------------------------------------|
| `move_forward`    | movement    | W, ↑                | LS Y −1.0           | `PlayerInputGatherer`, `FlyCamera`   |
| `move_backward`   | movement    | S, ↓                | LS Y +1.0           | `PlayerInputGatherer`, `FlyCamera`   |
| `move_left`       | movement    | A, ←                | LS X −1.0           | `PlayerInputGatherer`, `FlyCamera`   |
| `move_right`      | movement    | D, →                | LS X +1.0           | `PlayerInputGatherer`, `FlyCamera`   |
| `jump`            | movement    | SPACE               | A button (idx 0)    | `PlayerInputGatherer`, `FlyCamera`   |
| `crouch`          | movement    | C, CTRL             | B button (idx 1) †  | `PlayerInputGatherer`, `FlyCamera`   |
| `sprint`          | movement    | SHIFT               | LS click (idx 7) ‡  | `PlayerInputGatherer`, `FlyCamera`   |
| `walk`            | movement    | *(unbound)*         | *(unbound)*         | `PlayerInputGatherer`                |
| `look_left`       | camera      | *(mouse, see §4)*   | RS X −1.0           | `PlayerController`, `FlyCamera`      |
| `look_right`      | camera      | *(mouse, see §4)*   | RS X +1.0           | `PlayerController`, `FlyCamera`      |
| `look_up`         | camera      | *(mouse, see §4)*   | RS Y −1.0           | `PlayerController`, `FlyCamera`      |
| `look_down`       | camera      | *(mouse, see §4)*   | RS Y +1.0           | `PlayerController`, `FlyCamera`      |
| `toggle_camera`   | camera      | TAB                 | Back/Select (idx 4) | `PlayerController`                   |
| `interact`        | interaction | E                   | *(see §3.1)*        | **`PlayerController` ONLY**          |
| `debug_console`   | debug       | ² / ` , F1          | —                   | `world_explorer`, console UI         |
| `debug_screenshot`| debug       | F2                  | —                   | tools                                |

**Default rebind flags:**
- **† crouch on JOY_B**: B is press-not-hold on Xbox; works as a tap toggle but not ideal for held crouch. Acceptable default, user rebinds in K.1.
- **‡ sprint on LS click**: clicking the stick you're tilting forward is uncomfortable. Conventional Xbox sprint is LB shoulder (idx 9). Rebind in K.1.

### 2.1 Joystick axis sign convention

`InputEventJoypadMotion.axis_value` follows Godot's screen-Y-down convention applied to sticks:

- **LS / RS Y axis:** `−1.0` = up / forward, `+1.0` = down / backward
- **LS / RS X axis:** `−1.0` = left, `+1.0` = right

`move_forward` binds to `axis = JOY_AXIS_LEFT_Y, axis_value = -1.0`. If you bind `axis_value = +1.0` you will get a backward-walking sprint key.

### 2.2 Gamepad button index reference

| Index | Xbox name      | Common use                |
|-------|----------------|---------------------------|
| 0     | A              | jump / accept             |
| 1     | B              | crouch / cancel           |
| 2     | X              | (reserved — interact?)    |
| 3     | Y              | (reserved)                |
| 4     | Back / View    | toggle_camera / menu      |
| 7     | LS click       | sprint                    |
| 8     | RS click       | (reserved)                |

---

## 3. Coordination contracts

### 3.1 The `interact` action

`interact` is **owned exclusively by `PlayerController`** per `docs/systems/interaction_system.md` §3.1. Input code does NOT redefine, rebind, or add a second listener on this action. The pre-existing definition (`physical_keycode = 69` = E) in `project.godot [input]` is left untouched. `InputActions.verify()` asserts it exists but does not bind it.

K.0 deliberately does NOT add a gamepad binding to `interact`. Adding one requires editing the action definition, which is owned by `PlayerController`. If/when @interactivity wants `interact` on the X button, that change goes through #interactivity coordination first.

### 3.2 Mouse mode

`Input.set_mouse_mode` and `Input.mouse_mode = ...` writes are owned by `PlayerController`. `src/core/input/` MUST NOT touch mouse mode. Existing non-`PlayerController` mouse mode writes (`fly_camera.gd`, `dialogue_panel.gd`, `lapalma_*.gd`, `world_explorer.gd`) are tracked for cleanup as part of @interactivity's C.2.5+ phases — not in @keys's scope.

### 3.3 The `_ensure_input_actions` runtime safety net

`PlayerController._ensure_input_actions` (`src/core/player/player_controller.gd:381`) is a runtime block that adds `move_forward / move_backward / move_left / move_right / sprint / walk / jump / crouch / toggle_camera / interact` if they are missing from `InputMap`.

After K.0 these actions live in `project.godot [input]`, so the runtime block is a redundant safety net. It is **left in place** because:

1. It is idempotent (`InputMap.add_action` is gated on `has_action`).
2. Removing it would force a `PlayerController` edit, which K.0 explicitly forbids per the coordination contract above.
3. It defends against the case where a future test scene boots without `project.godot` somehow.

Cleanup is queued for a phase AFTER K.0.5 ships, owner TBD. If you are considering deleting it: don't, until you have audited every entry point and added a regression test first.

---

## 4. Mouse motion is not bindable to actions

Godot's `InputMap` accepts `InputEventKey`, `InputEventMouseButton`, `InputEventJoypadButton`, and `InputEventJoypadMotion` events. It does **NOT** accept `InputEventMouseMotion`. Calling `Input.get_vector("look_left", "look_right", "look_up", "look_down")` returns `Vector2.ZERO` for mouse-driven look — only the gamepad right-stick portion of the binding produces values.

This is **deliberate Godot behavior**, not a Godotwind bug. Mouse look has to be handled in `_input(InputEventMouseMotion)` directly. `PlayerController._input` and `FlyCamera._input` both already do this.

**If you are a future agent thinking about "unifying mouse look into the action layer" — stop.** It is not possible without writing a custom event-injection autoload, which would defeat the purpose of using `InputMap`. The dead `Input.get_vector("look_*")` call at `player_controller.gd:672` is documented evidence of this gotcha biting a previous agent.

---

## 5. AZERTY support

K.0 binds every keyboard event via `physical_keycode`, not `keycode`. The difference matters because:

- `keycode` is the **logical** key — what the OS thinks the key represents after layout translation. On AZERTY, pressing the physical W position produces `KEY_Z`, not `KEY_W`.
- `physical_keycode` is the **hardware** key — the same regardless of layout.

`Input.is_key_pressed(KEY_W)` checks the **logical** keycode, which is wrong for layout-independent input. `Input.is_action_pressed("move_forward")` reads the action bound via `physical_keycode = 87 (KEY_W)`, which is **right**.

### 5.1 The `²` key gotcha

The `debug_console` action is bound to `KEY_QUOTELEFT` (physical_keycode 96). On a US QWERTY keyboard this is the backtick `` ` `` key under Escape. On AZERTY this is the `²` key in the same physical position. Both should fire the action, but Godot's physical_keycode tables are derived from the US-QWERTY layout, so AZERTY `²` may or may not register depending on Godot version and OS.

`debug_console` is therefore **also** bound to `KEY_F1` as a guaranteed fallback. If `²` doesn't work on your AZERTY keyboard, F1 is the documented escape hatch.

---

## 6. Test scene contract

Action definitions live in `project.godot [input]`. Godot loads `project.godot` on engine startup, before any scene is instantiated. Every scene — main scene, test scenes, headless gdunit runs — gets the same `InputMap` automatically. **No autoload is needed. No base test scene is needed. No per-scene wiring is needed.**

The single source of truth for the *list* of expected actions is `src/core/input/input_actions.gd::REQUIRED_ACTIONS`. Scene roots may call `InputActions.verify()` in `_ready()` to assert the action set is intact. The verify call uses both `Log.error` (kept in release builds) and `assert` (debug builds only).

`tests/visual/test_input_phase_K0.tscn` is the canonical example.

---

## 7. Stick deadzone

K.0 uses `deadzone = 0.2` on every axis binding, hardcoded into each `InputEventJoypadMotion` entry in `project.godot [input]`. There is no runtime API to adjust this without rewriting the action.

`InputActions.STICK_DEADZONE = 0.2` is a **doc-only constant** mirroring the value. Godot stores deadzone per-binding, not as a runtime-readable global. If you change one, change BOTH. K.1 will expose this via the remap UI.

---

## 8. Roadmap

### K.0 — foundation (shipped 2026-04-07)
Action set in `project.godot [input]` (15 required actions); `src/core/input/input_actions.gd` static namespace + `verify()`; `fly_camera.gd` swapped from hardcoded `KEY_*` reads to action reads; `tests/visual/test_input_phase_K0.tscn` acceptance scene; this document. AZERTY keyboard pass green; gamepad pass deferred (no controller available at run time).

### K.0.5 — test scene sweep (shipped 2026-04-07)
Migrated `lapalma_explorer.gd`, `lapalma_static_explorer.gd`, `ik_animation_showcase.gd`, `ik_visual_test.gd`, `animation_wiring_test.gd` from hardcoded `KEY_*` reads to action reads. Hotkey match blocks switched from `keycode` to `physical_keycode`. Post-sweep grep over `src/`: zero `Input.is_key_pressed` matches. 18 debug-only hotkeys (F3 / K / O / 1-4 / M / N / etc.) remain hardcoded as `physical_keycode`, flagged inline as K.1 rebind candidates.

### K.1 — remap UI + persistence (NOT STARTED)
Remap panel that lets the user reassign any action binding live and persist changes to `user://`. **Implementation path is OPEN.**
- **(a) Hand-roll** using native `InputMap` API (`action_erase_events`, `action_add_event`, `action_get_events`). No addon. Estimated ~150-250 LOC. Default option.
- **(b) Verified addon survey** via WebSearch / Asset Library — each candidate must have a real URL, recent commit, tagged Godot 4.6 release. No name-from-memory.

Sub-deliverables: `src/core/ui/input_remap_panel.gd` + `.tscn` (Pelagiad-themed); `src/core/input/input_bindings_persistence.gd` (load/save `user://input_bindings.cfg`); reset-to-default button; conflict detection (refuse two actions on same event); gamepad rebind flow in same panel; fix SF1/S2 default rebinds (sprint to LB shoulder, crouch to LS click); `tests/visual/test_input_phase_K1.tscn`.

### K.2 — controller polish (NOT STARTED)
Controller prompt icons (no addon name committed until verified survey); per-device profiles (different bindings kbd vs gamepad); gamepad hot-swap detection (`Input.joy_connection_changed`); haptic / rumble API wrapper around `Input.start_joy_vibration` / `stop_joy_vibration`.

### K.3 — context layers (NOT STARTED)
Stack-based input contexts (gameplay / dialogue / inventory / book / menu). Read state from `PlayerController.is_modal_ui_open()` — **one-way read only**, @keys never registers gates with `PlayerController`. Suppress movement actions in dialogue; suppress camera actions in inventory; never suppress `interact`.

### P6 — gdunit headless test (low priority)
Add `tests/unit/test_input_actions.gd` asserting `InputActions.REQUIRED_ACTIONS.size() == 15`, each action is `InputMap.has_action(name)`, deadzone values match doc constant. ~30-40 LOC. Blocks regression detection if `project.godot` is hand-edited and an action gets dropped.

---

## 9. Known design constraints (don't re-litigate)

- **Mouse motion is not bindable to `InputMap` actions.** §4. Settled.
- **`_ensure_input_actions` stays in PlayerController.** §3.3. Settled.
- **`interact` action is owned by `PlayerController`.** §3.1 + INTERACTION_SYSTEM.md §3.1. Settled.
- **`physical_keycode` everywhere.** §5. Settled. Never use `keycode` (logical) for new bindings.
- **`walk` is unbound by default.** Settled. Do not bind it without a strong default rationale.
- **K.0 / K.0.5 ship zero addons.** All work uses native Godot 4.6 `InputMap` API only.
- **No addon names from memory.** Always WebSearch / WebFetch verify before naming a candidate.
