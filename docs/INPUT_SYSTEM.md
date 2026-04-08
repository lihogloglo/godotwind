# Input System

**Owner:** @keys
**Status:** K.0 shipped 2026-04-07
**Coordination:** Reads `interact` action only — owned by `PlayerController` per `docs/INTERACTION_SYSTEM.md` §3.1.

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
| `interact`        | interaction | E                   | *(see §3.2)*        | **`PlayerController` ONLY**          |
| `debug_console`   | debug       | ² / ` , F1          | —                   | `world_explorer`, console UI         |
| `debug_screenshot`| debug       | F2                  | —                   | tools                                |

**Default rebind flags:**
- **† crouch on JOY_B**: B is press-not-hold on Xbox; works as a tap toggle but not ideal for held crouch. Original SF1 plan was LS click; during impl LS click was assigned to `sprint` instead. Acceptable default, user rebinds in K.1.
- **‡ sprint on LS click**: clicking the stick you're tilting forward is uncomfortable. Conventional Xbox sprint is LB shoulder (button index 9). Rebind in K.1 remap UI. S2 ruling.

### 2.1 Joystick axis sign convention

`InputEventJoypadMotion.axis_value` follows Godot's screen-Y-down convention applied to sticks:

- **LS / RS Y axis:** `−1.0` = up / forward, `+1.0` = down / backward
- **LS / RS X axis:** `−1.0` = left, `+1.0` = right

`move_forward` binds to `axis = JOY_AXIS_LEFT_Y, axis_value = -1.0`. If you bind `axis_value = +1.0` you will get a backward-walking sprint key. K.0 N3 ruling.

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

`interact` is **owned exclusively by `PlayerController`** per `docs/INTERACTION_SYSTEM.md` §3.1. The K.0 plan does NOT redefine, rebind, or add a second listener on this action. The pre-existing definition (`physical_keycode = 69` = E) in `project.godot [input]` is left untouched. `InputActions.verify()` asserts it exists but does not bind it.

K.0 deliberately does NOT add a gamepad binding to `interact`. Adding one requires editing the action definition, which is owned by `PlayerController`. If/when @interactivity wants `interact` on the X button, that change goes through #interactivity coordination first.

### 3.2 Mouse mode

`Input.set_mouse_mode` and `Input.mouse_mode = ...` writes are owned by `PlayerController`. `src/core/input/` MUST NOT touch mouse mode. K.0 does not. Existing non-`PlayerController` mouse mode writes (`fly_camera.gd`, `dialogue_panel.gd`, `lapalma_*.gd`, `world_explorer.gd`) are tracked for cleanup as part of @interactivity's C.2.5+ phases — not in @keys's scope.

### 3.3 The `_ensure_input_actions` runtime safety net

`PlayerController._ensure_input_actions` (`src/core/player/player_controller.gd:381`) is a runtime block that adds `move_forward / move_backward / move_left / move_right / sprint / walk / jump / crouch / toggle_camera / interact` if they are missing from `InputMap`.

After K.0, these actions live in `project.godot [input]`, so the runtime block becomes a redundant safety net. It is **left in place** because:

1. It is idempotent (`InputMap.add_action` is gated on `has_action`, so it does not fight K.0's definitions).
2. Removing it would force a `PlayerController` edit, which K.0 explicitly forbids per the coordination contract above.
3. It defends against the case where a future test scene boots without `project.godot` somehow (e.g. a hand-built `ProjectSettings` override in a fixture).

**Cleanup is queued for a follow-up phase AFTER K.0.5 ships** and we are confident the `project.godot` definitions are load-bearing across all entry points (main scene, every test scene, headless gdunit runs). Cleanup phase ownership is undecided — @keys or @interactivity, decide later.

If you are reading this in a future session and considering deleting `_ensure_input_actions`: don't, until you have audited every entry point. Add a regression test first.

---

## 4. Mouse motion is not bindable to actions

Godot's `InputMap` accepts `InputEventKey`, `InputEventMouseButton`, `InputEventJoypadButton`, and `InputEventJoypadMotion` events. It does **NOT** accept `InputEventMouseMotion`. Calling `Input.get_vector("look_left", "look_right", "look_up", "look_down")` returns `Vector2.ZERO` for mouse-driven look — only the gamepad right-stick portion of the binding produces values.

This is **deliberate Godot behavior**, not a Godotwind bug. Mouse look has to be handled in `_input(InputEventMouseMotion)` directly. `PlayerController._input` and `FlyCamera._input` both already do this.

**If you are a future agent thinking about "unifying mouse look into the action layer" — stop.** It is not possible without writing a custom event-injection autoload, which would defeat the purpose of using `InputMap`. The dead `Input.get_vector("look_*")` call at `player_controller.gd:672` is documented evidence of this gotcha biting a previous agent. K.0 leaves it alone (read-only verification only) and documents the rule here.

---

## 5. AZERTY support

K.0 binds every keyboard event via `physical_keycode`, not `keycode`. The difference matters because:

- `keycode` is the **logical** key — what the OS thinks the key represents after layout translation. On AZERTY, pressing the physical W position produces `KEY_Z`, not `KEY_W`.
- `physical_keycode` is the **hardware** key — the same regardless of layout. On AZERTY, pressing the physical W position produces `KEY_W` for the physical_keycode field.

`Input.is_key_pressed(KEY_W)` checks the **logical** keycode, which is wrong for layout-independent input. `Input.is_action_pressed("move_forward")` reads the action which was bound via `physical_keycode = 87 (KEY_W)`, which is **right**.

The pre-K.0 `fly_camera.gd` worked around this by dual-checking `KEY_W or KEY_Z` (and `KEY_A or KEY_Q`), which was an accidental AZERTY tolerance, not a designed one. K.0 fixes it properly.

### 5.1 The `²` key gotcha

The `debug_console` action is bound to `KEY_QUOTELEFT` (physical_keycode 96). On a US QWERTY keyboard this is the backtick `` ` `` key under Escape. On AZERTY this is the `²` key in the same physical position. Both should fire the action, but Godot's physical_keycode tables are derived from the US-QWERTY layout, so AZERTY `²` may or may not register depending on Godot version and OS.

`debug_console` is therefore **also** bound to `KEY_F1` as a guaranteed fallback. The K.0 acceptance test (`test_input_phase_K0.tscn`) explicitly requires the AZERTY user to confirm `²` works; if it doesn't, F1 is the documented escape hatch.

---

## 6. Test scene contract

Action definitions live in `project.godot [input]`. Godot loads `project.godot` on engine startup, before any scene is instantiated. Every scene — main scene, test scenes, headless gdunit runs — gets the same `InputMap` automatically. **No autoload is needed. No base test scene is needed. No per-scene wiring is needed.**

The single source of truth for the *list* of expected actions is `src/core/input/input_actions.gd::REQUIRED_ACTIONS`. Scene roots may call `InputActions.verify()` in `_ready()` to assert the action set is intact. The verify call uses both `Log.error` (kept in release builds) and `assert` (debug builds only) per K.0 MF3.

`tests/visual/test_input_phase_K0.tscn` is the canonical example.

---

## 7. Stick deadzone

K.0 uses `deadzone = 0.2` on every axis binding, hardcoded into each `InputEventJoypadMotion` entry in `project.godot [input]`. There is no runtime API to adjust this without rewriting the action.

`InputActions.STICK_DEADZONE = 0.2` is a **doc-only constant** mirroring the value. Godot stores deadzone per-binding, not as a runtime-readable global. If you change one, change BOTH. K.1 will expose this via the remap UI.

---

## 8. Roadmap

### K.0 — foundation (shipped 2026-04-07)
- ✅ Action set in `project.godot [input]` (15 required actions)
- ✅ `src/core/input/input_actions.gd` static namespace + `verify()`
- ✅ `fly_camera.gd` swapped from hardcoded `KEY_*` reads to action reads
- ✅ `tests/visual/test_input_phase_K0.tscn` acceptance scene
- ✅ This document

### K.0.5 — test-scene sweep (next)
- One-at-a-time conversion of `lapalma_explorer.gd`, `lapalma_static_explorer.gd`, `ik_animation_showcase.gd`, `ik_visual_test.gd`, `animation_wiring_test.gd` from hardcoded `KEY_*` reads to action reads.
- Each file converted + retested before moving to the next. Reviewer MF2 discipline.

### K.0.5 — test scene sweep (shipped 2026-04-07)
- ✅ `lapalma_explorer.gd` — WASD/ZQSD → action reads, hotkey match block → `physical_keycode`
- ✅ `lapalma_static_explorer.gd` — same pattern
- ✅ `ik_animation_showcase.gd` — forward/backward NPC drive → action reads, hotkey block → `physical_keycode`
- ✅ `ik_visual_test.gd` — WASD → `Input.get_vector`, SHIFT modifier → `sprint` action
- ✅ `animation_wiring_test.gd` — WASD + sprint via actions, KEY_F debug trigger → `physical_keycode`
- ✅ `Input.is_key_pressed` grep over `src/`: zero matches after sweep
- 18 hotkeys remain hardcoded as `physical_keycode` (debug toggles outside K.0 namespace) — flagged inline as K.1 rebind candidates: F3 / K / O / F / C / G (lapalma_explorer); F3 (lapalma_static); 1-4 / M / N / D / B / LEFT / RIGHT / SPACE (ik_animation_showcase); 1-3 / SPACE / R (ik_visual_test); F (animation_wiring_test).

### K.1 — remap UI + persistence (NOT STARTED)
**Status:** plan stalled — see §10 "What's left".
- Build a remap panel that lets the user reassign any action binding live, then persist the changes to `user://`.
- **Implementation path is OPEN**. The original K.0 plan named "GUIDE" as a candidate addon but that name was never verified — see §9.2 honesty note. Realistic options:
  - **(a) Hand-roll** using Godot's native `InputMap` API (`action_erase_events`, `action_add_event`, `action_get_events`). No addon dependency. Estimated ~150-250 LOC for the remap flow + persistence helper. Documented escape hatch.
  - **(b) Survey real Godot 4.6 input remap addons** via WebSearch / Asset Library before picking one. List candidates with confirmed repo URLs and 4.6 compatibility, NOT from memory.
- Sub-deliverables once an option is picked:
  - `src/core/ui/input_remap_panel.gd` + `.tscn` (Pelagiad-themed)
  - `src/core/input/input_bindings_persistence.gd` — load/save `user://input_bindings.cfg`
  - Reset-to-default button
  - Conflict detection (refuse to bind two actions to the same event)
  - Gamepad rebind flow in the same panel
  - Fix SF1/S2 default rebinds (sprint to LB shoulder, crouch to LS click) once the remap UI exists
  - `tests/visual/test_input_phase_K1.tscn`
  - Doc updates: §8 K.1 status flipped to ✅, new §10 implementation notes

### K.2 — controller polish (NOT STARTED)
- Controller prompt icons. **NOT** committing to a specific addon name — needs verified survey first.
- Per-device profiles (different bindings for kbd vs gamepad)
- Gamepad hot-swap detection
- Haptic / rumble API wrapper

### K.3 — context layers (NOT STARTED)
- Input contexts (gameplay / dialogue / inventory / book) — read state from `PlayerController.is_modal_ui_open()` so dialogue suppresses movement.
- **One-way read only** — @keys never registers gates with `PlayerController`.

---

## 9. Decision history (Session 2026-04-07)

### 9.1 Session timeline
1. User brief in #interactivity (id=3930): generic input handling, AZERTY, controller, test scene contract, no reinventing the wheel.
2. @keys plan (id=3933) — codebase audit + (later-retracted) addon survey + K.0/K.1/K.2/K.3 phasing.
3. @reviewer review round 1 (id=3935) — 4 must-fix + 5 should-fix.
4. @keys revised plan (id=3936) — all 9 fixes folded.
5. @reviewer signoff round 2 (id=3937) — accepted, plus SF4 nit on `STICK_DEADZONE`.
6. @interactivity coordination ack (id=3938) — green light + 3 alignment notes (N1/N2/N3).
7. @reviewer ruling on N1/N2/N3 (id=3940) — `move_backward` (not `move_back`), keep `_ensure_input_actions`, doc the joy axis sign convention.
8. K.0 implementation shipped (id=3949).
9. @reviewer K.0 code review (id=3953) — ship signoff, S1 doc honesty + S2 sprint LS click flag fixes requested.
10. K.0 S1+S2 doc fixes shipped (id=3954).
11. @user K.0 AZERTY acceptance pass (id=3955) — keyboard pass full green; gamepad deferred (no controller available at run time).
12. K.0.5 reviewer bar pre-stated (id=3960).
13. K.0.5 implementation shipped (id=3969) — 5 files migrated, ~75 LOC, zero `Input.is_key_pressed` left in `src/`.
14. @user requested K.1 plan (id=3970).
15. @keys K.1 brief posted (id=3971) — listed "GUIDE addon" as a candidate **from memory, unverified**.
16. @user (id=3974) caught the hallucination — "guide addon doesn't exist". K.1 halted. Doc compilation requested.
17. K.1 plan retracted, this §9.2 honesty note added, §10 What's left section added (this commit).

### 9.2 Addon survey — RETRACTED, hallucinated content

The original K.0 plan (chat id=3933) listed an addon survey table naming "GUIDE", "godot-input-remap", "controller-icons", and "InputHelper" as if from memory. **The "GUIDE" name was a hallucination** — caught by @user 2026-04-07 (chat id=3974). The other names were equally unverified. None of these were checked against real GitHub repos or the Godot Asset Library before being written down.

This is documented here as a permanent reminder: **never name an addon as a recommendation without WebSearch / WebFetch verifying the repo URL and Godot 4.6 compatibility first.**

K.0 itself is unaffected — it ships with **plain `InputMap`** (no addon), which is honestly verified Godot 4.6 native API. The K.0 implementation never depended on any addon. K.0.5 also uses only `InputMap` native API. The retraction only affects K.1 planning, which is now flagged as "implementation path open" in §8.

For K.1 the honest path is:
- **(a) Hand-roll** using `InputMap.action_erase_events` / `action_add_event` / `action_get_events`. No survey needed. Native Godot 4.6 API, ~150-250 LOC. Default option.
- **(b) Verified survey** via WebSearch + Asset Library checks. Each candidate must have a real URL, a recent commit, and a tagged Godot 4.6 release before being considered. No more name-from-memory.

### 9.3 Rejected design alternatives

| Proposal                                          | Reason rejected                                       |
|---------------------------------------------------|-------------------------------------------------------|
| Mouse look as `look_*` action                     | Godot does not bind `InputEventMouseMotion` to InputMap. Returns 0 from `get_vector`. Documented in §4. |
| `move_back` action name                           | `player_input_gatherer.gd` and `_ensure_input_actions` already use `move_backward`. Renaming forces downstream churn. N1 ruling. |
| Delete `_ensure_input_actions` in K.0             | Forces a `PlayerController` edit, which K.0 forbids. Idempotent → safe to leave. N2 ruling. |
| `walk` bound to `KEY_ALT` by default              | OS-shortcut soup. Default = unbound. SF2 ruling.      |
| `crouch` bound to `JOY_BUTTON_B` only             | B is press-not-hold on Xbox. SF1 plan was to move to LS click; during impl LS click went to `sprint` instead (see §2 sprint row). Kept B as crouch's joy default + added `KEY_CTRL` kbd as the agreed second binding. Acceptable as a default — user rebinds in K.1 remap UI. SF1 deferred to K.1. |
| `sprint` bound to `JOY_BUTTON_LEFT_STICK` (idx 7) | Suboptimal default — clicking the stick you're tilting forward is uncomfortable in practice. Conventional Xbox sprint is LB shoulder (idx 9). Doc-flagged in §2; rebind in K.1. S2 ruling. |
| New autoload for input verification               | CLAUDE.md anti-pattern. Static class only.            |
| Per-scene base test class for action loading      | Unnecessary — `project.godot [input]` loads at engine startup. §6. |
| `assert(InputMap.has_action(name))` only          | Asserts strip from release builds. Use `Log.error` + `assert` double-belt. MF3 ruling. |

### 9.4 Sequencing lock
K.0 ✅ → K.0.5 (test scene sweep) → K.1 (GUIDE addon + remap UI + persistence) → K.2 (controller polish) → K.3 (context layers).

K.0.5 may run in parallel with @interactivity's I.0a (main scene player wiring) — they touch disjoint files.

### 9.5 Coordination contract with @interactivity

K.0 promises:
- Zero edits to `src/core/player/player_controller.gd`
- Zero edits to `src/core/interaction/interaction_raycaster.gd`
- Zero changes to the `interact` action definition (kbd binding preserved, no new gamepad binding)
- Zero `Input.set_mouse_mode` or `Input.mouse_mode = ...` writes from `src/core/input/`
- Zero second listeners on `interact`

@interactivity confirmed (id=3938). K.0 ships within these bounds.

### 9.6 Files touched in K.0 implementation
- `project.godot` — added 15 actions to `[input]` section (existing `interact` untouched)
- `src/core/input/input_actions.gd` — NEW, namespace + `verify()`
- `src/core/player/fly_camera.gd:107-135` — replaced 7 hardcoded `KEY_*` reads with action reads
- `tests/visual/test_input_phase_K0.gd` — NEW, acceptance scene script
- `tests/visual/test_input_phase_K0.tscn` — NEW, scene wrapper
- `docs/INPUT_SYSTEM.md` — NEW, this file
- `docs/INTERACTION_SYSTEM.md` §3.1 — added cross-ref to this file

### 9.7 Files touched in K.0.5 implementation
- `src/tools/lapalma_explorer.gd` — hotkey block + WASD/ZQSD movement
- `src/tools/lapalma_static_explorer.gd` — hotkey block + WASD/ZQSD movement
- `src/tools/ik_animation_showcase.gd` — forward/backward NPC drive + hotkey block + status display read
- `src/tools/ik_visual_test.gd` — WASD movement + SHIFT modifier + hotkey block
- `src/tools/animation_wiring_test.gd` — WASD movement + sprint + KEY_F debug trigger

### 9.8 Verification done
- `project.godot` parses (no syntax errors)
- `tests/visual/test_input_phase_K0.tscn` headless run: clean startup, `InputActions.verify() OK — 15 required actions present`, `self-test PASS — 15 actions verified`, no script errors
- K.0 manual AZERTY acceptance test: **PASS** (user run, id=3955) — keyboard portion full green
- K.0 manual gamepad acceptance test: **deferred** (no controller available at run time)
- K.0.5 per-file headless launches: 4 of 5 via their own scene files (`scenes/lapalma_explorer.tscn`, `src/tools/ik_animation_showcase.tscn`, `src/tools/ik_visual_test.tscn`, `src/tools/animation_wiring_test.tscn`) all clean. `lapalma_static_explorer.gd` has no scene wired — engine startup parse-check clean.
- Post-K.0.5 grep over `src/`: `Input.is_key_pressed` returns zero matches.

---

## 10. What's left to do

This section is the canonical "where K is parked" pointer. Update it whenever a phase ships or a new task is identified.

### 10.1 Shipped (as of 2026-04-07)

- **K.0** — action namespace, `project.godot [input]`, `InputActions.verify()`, fly_camera migration, K.0 test scene, this doc, INTERACTION_SYSTEM.md cross-ref. Reviewer signoff id=3953. AZERTY acceptance pass id=3955.
- **K.0.5** — five `src/tools/` test scene files migrated from hardcoded `KEY_*` to action reads. Hotkey blocks switched from `keycode` to `physical_keycode`. Reviewer ship message id=3969.

### 10.2 Open work, prioritised

#### P1 — K.1 remap UI + persistence (largest pending block)
- **Implementation path open.** Default option: hand-roll using native `InputMap` API (no addon). Alternative: a verified addon survey via WebSearch / Asset Library — must produce real repo URLs and confirmed Godot 4.6 compatibility, no name-from-memory.
- **Hand-roll outline (estimated ~150-250 LOC):**
  - `src/core/input/input_bindings_persistence.gd` — `save(path: String)` writes one entry per action: `{action_name, [event_dicts]}`. `load(path: String)` reads back and applies via `InputMap.action_erase_events` + `action_add_event`. Format = `ConfigFile`.
  - `src/core/ui/input_remap_panel.gd` + `.tscn` — list of action rows; each row shows action name + current binding(s) + "rebind" button. Rebind button enters listen mode (`set_process_unhandled_input(true)`), captures next `InputEvent`, validates conflict, calls `InputMap.action_add_event`. Pelagiad-themed (matches book viewer / dialogue panel).
  - Reset-to-default button → re-applies the original bindings from `project.godot [input]` snapshot stored at startup.
  - Conflict detection: before adding an event, scan all other actions for an exact event match; refuse the bind and show an error toast.
  - Gamepad rebind flow uses the same listen-mode capture (`InputEventJoypadButton` and `InputEventJoypadMotion` both arrive via `_unhandled_input`).
  - `tests/visual/test_input_phase_K1.tscn` — manual: rebind one action, restart, confirm persistence held; reset-to-default; conflict refusal.
- **Open binding fixes (waits on K.1):**
  - SF1 — move `crouch` joy from B button to LS click (or expose for user remap)
  - S2 — move `sprint` joy from LS click to LB shoulder (button index 9)
  - Add a gamepad binding to `interact` once K.1 ships and @interactivity coordinates the change

#### P2 — K.2 controller polish
- Controller prompt icons. **No addon name committed** until verified survey is done.
- Per-device profiles (separate kbd vs gamepad bindings)
- Gamepad hot-swap detection (`Input.joy_connection_changed` signal)
- Haptic / rumble API wrapper around `Input.start_joy_vibration` / `stop_joy_vibration`

#### P3 — K.3 context layers
- Stack-based input contexts (gameplay / dialogue / inventory / book / menu)
- Read state from `PlayerController.is_modal_ui_open()` — one-way only
- Suppress movement actions when dialogue context active; suppress camera actions when inventory active; never suppress `interact` (owned by I.0)
- API sketch: `InputContext.push("dialogue")` / `InputContext.pop("dialogue")`. Unclear yet whether this lives in `src/core/input/` or in `PlayerController` itself — coordination call needed when K.3 starts.

#### P4 — `_ensure_input_actions` cleanup (deferred indefinitely)
- `PlayerController._ensure_input_actions` (`src/core/player/player_controller.gd:381`) is redundant after K.0. Idempotent → safe but dead.
- Cannot delete in @keys's scope (forces a `PlayerController` edit, K.0 contract forbids).
- Cleanup queued for a phase AFTER K.0.5 ships AND we are confident `project.godot` definitions are load-bearing across all entry points (main scene, every test scene, headless gdunit runs). Owner TBD.
- See §3.3.

#### P5 — Non-PlayerController `Input.set_mouse_mode` cleanup (out of @keys scope)
- Sites still writing `Input.set_mouse_mode` outside `PlayerController`:
  - `src/core/player/fly_camera.gd:70, 73, 149` (mouse capture toggle on right-click)
  - `src/core/ui/dialogue_panel.gd:122, 141`
  - `src/tools/lapalma_explorer.gd:677, 680` (right-click camera capture)
  - `src/tools/lapalma_static_explorer.gd:146, 149`
  - `src/tools/world_explorer.gd:1506-1513`
- These belong to @interactivity's C.2.5+ cleanup wave. **NOT** @keys's scope — flagged here only so future @keys sessions don't accidentally touch them.

#### P6 — gdunit headless test for `InputActions.verify()`
- K.0's verify() runs at scene startup but is not exercised by the gdunit suite.
- Add `tests/unit/test_input_actions.gd` that asserts `InputActions.REQUIRED_ACTIONS.size() == 15`, asserts each is `InputMap.has_action(name)`, asserts deadzone values match the doc constant.
- Estimated: 30-40 LOC, single test file. Low priority but blocks regression detection if `project.godot` is hand-edited and an action gets dropped.

### 10.3 Known design constraints (don't re-litigate)

- **Mouse motion is not bindable to `InputMap` actions.** §4. Settled. Do not propose moving mouse look into the action layer.
- **`_ensure_input_actions` stays in PlayerController.** §3.3 + P4. Settled. Do not delete it under @keys's scope.
- **`interact` action is owned by `PlayerController`.** §3.1 + INTERACTION_SYSTEM.md §3.1. Settled. Do not add a second listener, do not rebind, do not edit the action definition without @interactivity coordination.
- **`physical_keycode` everywhere.** §5. Settled. Never use `keycode` (logical) for new bindings.
- **`walk` is unbound by default.** §9.3 SF2. Settled. Do not bind it without a strong default rationale.
- **K.0 ships zero addons.** All K.0 / K.0.5 work uses native Godot 4.6 `InputMap` API only.

### 10.4 Conventions for future K phases

- One file per commit when migrating; parse-check + headless launch after each (MF2 discipline, applied in K.0.5).
- No new actions added in migration phases — only in spec phases that explicitly justify each addition.
- Reviewer pre-stated bar before each phase (K.0, K.0.5 already had one — K.1 should as well).
- Per-file report format: filename + line range changed + headless result + gotchas, tight bullets.
- Final phase ship message: list of files, total LOC, any leftovers flagged for the next phase.
- **No addon names from memory.** Always WebSearch / WebFetch verify before naming a candidate.
