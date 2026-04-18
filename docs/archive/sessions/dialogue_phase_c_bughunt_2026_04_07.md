Archived session log. Preserved verbatim from the pre-cleanup `docs/TEXT_DIALOGUE_SYSTEM.md`. Current dialogue state lives in `docs/systems/dialogue.md`. This file is kept for forensic context on the DialogueUI topic-click bug hunt and the C.2.5 input-owner refactor sequencing.

---

## Session 2026-04-07 Progress

Cross-session tracking doc for the dialogue / book / journal / interaction system. State at end-of-session captured here so the next agent can pick up without re-deriving from chat.

### Phase C.0 — Framework cleanup ✅ SHIPPED

Reviewer found `DialogueContext` was lying about being game-agnostic — it held MW-shaped fields (`pc_attributes[8]`, `pc_skills[27]`, `pc_clothing_value`, disease/vampire/werewolf flags). Split fix:

- **`src/core/dialogue/morrowind/mw_dialogue_context.gd`** (new) — `MWDialogueContext extends DialogueContext`. Holds the 13 stripped MW fields + `get_attribute()` / `get_skill()` helpers.
- **`src/core/dialogue/dialogue_context.gd`** — stripped of MW fields, docstring corrected to point at adapter subclasses for game-specific extensions.
- **`src/core/dialogue/morrowind/mw_dialogue_functions.gd`** — `evaluate(... context: MWDialogueContext)` retyped from `RefCounted`. Removed all `var ctx_X: Type = context.field` unwrap workarounds. 74 functions read fields directly via the typed param now.
- **`src/core/dialogue/morrowind/mw_dialogue_filter.gd`** — all 9 methods (`search`, `search_with_refusal`, `search_relaxed`, `debug_search`, `_test_actor`, `_test_player`, `_test_select_structs`, `_test_disposition`, `_evaluate_condition`) retyped from `RefCounted` → `MWDialogueContext`. Filter chain is now end-to-end typed.
- **`src/core/dialogue/morrowind/mw_dialogue_provider.gd`** — new private `_require_mw_context(context)` cast helper. All 4 query methods (`get_greeting`, `get_available_topics`, `get_response`, `get_goodbye`) call it at entry, null-check, return `NO_INFO_MATCH` on cast failure. Base class signature stays `DialogueContext` for LSP compatibility, override casts internally.
- **`src/core/dialogue/dialogue_provider.gd`** — `get_speaker_name(_speaker_id)` returns `""` (was: returned `speaker_id` masquerading as found). `MWDialogueProvider.get_speaker_name()` returns `""` on failed `_resolve_npc()`. `DialogueUI._show_greeting()` falls back to `"<" + speaker_id + ">"` with `Log.warn` so missing speakers are visible instead of silent.
- **`tests/visual/test_dialogue.gd` + `tests/visual/test_interaction.gd`** — both construct `MWDialogueContext` instead of `DialogueContext`.

Verified interactively in `test_dialogue.tscn` — Fargoth + Ajira conversations open and close cleanly, zero `SCRIPT ERROR`. Roaster + reviewer both spot-checked. Closed.

### Phase C.1 — Dead path delete ✅ SHIPPED

Deleted `MWQuestAdapter.process_dialogue_result(info, parent_topic_id)` in `src/core/dialogue/morrowind/mw_quest_adapter.gd`. Was the pre-signal path; superseded by `on_response_selected(topic_id, response)` which reads `Response.metadata`. Grep confirmed zero external refs before delete.

### Phase C.2 — DialogueSession + interactable shrink ✅ SHIPPED

**Shipped:**
- **`src/core/dialogue/dialogue_session.gd`** (new) — plain `RefCounted`, framework layer. Holds `provider`/`context`/`dialogue_ui`/`book_viewer` shared refs. Static `set_current()` / `current()` so the main scene constructs once at boot and interactables read globally without per-instance fields. NOT an autoload (consistent with Godotwind's "autoloads = services, scene state = scene-owned" pattern).
- **`src/core/dialogue/morrowind/npc_interactable.gd`** — stripped 3 fields (`dialogue_ui`, `dialogue_provider`, `dialogue_context`). `interact()` now reads via `DialogueSession.current()`. Each NPC stamped onto a streaming cell is now just `Node3D` + `speaker_id` + null-checks; no per-instance ref bloat for the cell-streaming path.
- **`src/core/dialogue/morrowind/book_interactable.gd`** — same shrink, dropped `book_viewer` field. Reads via `DialogueSession.current()`.
- **`src/core/ui/book_viewer.gd`** — added `is_open() -> bool` helper (matches `DialogueUI.is_open()` pattern).
- **`src/core/dialogue/dialogue_session.gd`** — `is_any_panel_open()` method, queries both panels.
- **`src/core/interaction/interaction_raycaster.gd`** — `_unhandled_input` early-outs if `DialogueSession.current().is_any_panel_open()`. **Stopgap for C.2.5** — without this gate, pressing E to close a panel re-fires `interact()` on the ancestor Interactable under the crosshair, re-opens the same panel, and destroys any in-flight click the player aimed at a topic button. Cross-system import (`src/core/interaction/` → `src/core/dialogue/`) is the deletion target for C.2.5.
- **`src/core/ui/dialogue_panel.gd`** — `_unhandled_input` accepts BOTH `ui_cancel` (Escape) and `interact` (E) as close triggers. Symmetric toggle. Same change in `book_viewer.gd`.
- **`src/core/ui/dialogue_panel.gd`** — `_bg` ColorRect set to `MOUSE_FILTER_IGNORE` (was default STOP, swallowing whiff clicks). `open()` forces `Input.set_mouse_mode(MOUSE_MODE_VISIBLE)` so accidentally-captured-cursor doesn't kill button input.
- **`src/core/player/fly_camera.gd`** — `_input` AND `_process` gate on `DialogueSession.current().is_any_panel_open()`. Without this, accidentally right-clicking inside a dialogue would re-capture the mouse and make topic buttons unclickable. Same C.2.5 deletion target.
- **`tests/visual/test_interaction.gd`** — constructs `DialogueSession`, populates fields, calls `set_current()` BEFORE spawning interactables. Removed the per-instance re-bind loop. Swapped plain `Camera3D` for `FlyCamera` (which supports AZERTY ZQSD by default).
- **`MWQuestAdapter.process_dialogue_result()`** dead path deleted (technically C.1).

**RESOLVED 2026-04-07** — root cause was `BookViewer._build_ui()` adding a full-screen `ColorRect` overlay with `MOUSE_FILTER_STOP` as a sibling of `_panel`, then `hide_book()` only hiding `_panel`. BookViewer is `CanvasLayer layer=90` — same layer as `DialogueUI`. The orphaned overlay was hit-tested before any DialogueUI Control could see the click, eating every mouse button event before GUI routing. Fix in `book_viewer.gd`: store overlay as `_overlay` member, toggle it with `_panel.visible` in `show_book` / `hide_book`. Patched by @interactivity in id=3975 while debugging unrelated I.0 mouse-look issue, accepted by @dialogue in id=3984. Verified end-to-end via `test_interaction_phase_I0.tscn`: dialogue opens, topic links highlight on hover, click → response, goodbye → close, no crash. Diagnostic state below preserved as a record of how the bug presented.

The same review pass uncovered + fixed a second bug: `dialogue_panel.gd._build_ui()` had ~half its body indented inside an orphaned `_dump_control_tree()` diagnostic, leaving `_npc_name_label`/`_response_text`/`_topics_container`/`_info_label` null at runtime → crash on `_show_greeting`. Fix moved the orphaned block back into `_build_ui` and deleted the dead diagnostic. Same patch (id=3975).

**Original bug report — preserved for forensic reference:**

Clicking topic buttons in `DialogueUI` does not work. Reproduced in `tests/visual/test_interaction.tscn`:
1. Walk up to the brown cylinder Fargoth, press E → dialogue opens correctly
2. Click any topic button on the right side → nothing happens, click is silently dropped
3. Click any inline `[url]` topic keyword in the response text → nothing happens
4. E or Escape close the dialogue cleanly

**Diagnostic state at end-of-session** (instrumentation in `dialogue_panel.gd`):
- `DialogueUI.open(...)` log line fires correctly with `mouse_mode=0 (VISIBLE)`
- `DialogueUI._input` (Node-level mouse tracer) **DOES** catch the clicks: log shows `mouse button=1 pressed pos=(1311,94)` etc. at sensible positions inside the panel, mouse_mode=0
- `_on_root_gui_input` (Control-level mouse fallback on `_root_control`) **DOES NOT** fire for any click
- `_on_topic_clicked` (Button.pressed handler) **DOES NOT** fire
- `_on_topic_link_clicked` (RichTextLabel meta_clicked handler) **DOES NOT** fire
- `_on_meta_hover_started` (RichTextLabel meta_hover_started handler) **DOES NOT** fire

**Interpretation:** mouse events arrive at the Node tree (proven by `_input` catching them), but die before the GUI hit-test phase routes them to any child Control. Either an upstream `_input` handler is calling `set_input_as_handled()` and skipping GUI hit-testing, or some Control rect/filter combo is making every child unreachable.

**Already ruled out:**
- Mouse-mode capture (verified VISIBLE at click time via `_process` poll + open() log)
- `_root_control` zero-rect from missing parent rect (verified `get_rect() = [(0,0), (1920,1061)]` after explicit anchor-zeroing + `set_size`. Note: this DID change the rect from a previous broken state, but the click behavior is unchanged — fix landed but didn't help)
- ColorRect `_bg` blocking children (set to IGNORE)
- Container default `MOUSE_FILTER_STOP` blocking bubble-up (root_vbox / content_hbox / response_panel / topics_panel / _topics_container all explicitly set to PASS)
- FlyCamera right-click recapture (gated on session)
- InteractionRaycaster re-firing E during open dialogue (gated on session)

**Suspect — has NOT been investigated yet:**
- Some other `_input` handler in the project calls `set_input_as_handled()` on mouse events. Files with that call: `src/tools/world_explorer.gd:1598/1606` (NOT loaded in test_interaction), `src/core/console/console_ui.gd` (multiple), `src/core/console/object_picker.gd` (multiple), `src/tools/asset_viewer/components/orbit_camera.gd` (multiple). Should grep autoloads + scene tree at runtime to see if any of them are active in test_interaction.
- ScrollContainer wrapping the topic VBox might be clipping the buttons to a 0-rect. ScrollContainer has its own internal layout and may interact with `size_flags` differently than expected. Try replacing it with a plain VBoxContainer to confirm.
- The buttons themselves might be 0-rect because the `_topics_container` (VBoxContainer) inside `topics_scroll` (ScrollContainer) inside `topics_panel` (PanelContainer) chain has a sizing bug. Add a `_dump_control_tree()` log right after `_show_greeting()` to see every Control's rect post-layout.
- A `_dump_control_tree()` helper has been added to `dialogue_panel.gd` but is **not yet called from anywhere** — next agent should hook it into `open()` after `_show_greeting()` to dump the full Control tree to the log.

**Reviewer/roaster context:** roaster diagnosed candidate (a) — raycaster re-firing — and the C.2 stopgap fix landed for that. Both reviewer + roaster verified the C.2 commit. The remaining click bug (this one) was NOT caught by their spot-checks; they relied on user visual verification, which surfaced the bug after they'd signed off.

**Per-user instructions logged 2026-04-07:**
- All dialogue work stays in `#text` channel only. NO crossposting to `#interactivity`.
- @roaster reviews dialogue work (in `#text`).
- @reviewer reviews interactivity work (in `#interactivity`).
- @interactivity owns `PlayerController` + I.0 input architecture rebuild.

### Phase C.2.5 — Input Owner refactor 🟢 UNBLOCKED, READY TO START

@interactivity shipped I.0 first half (PlayerController + signals + modal gates + raycaster purification) on 2026-04-07 (id=3976 acceptance). The locked API contract below is built and verified in `tests/visual/test_interaction_phase_I0.tscn`. C.2.5 dialogue-side wiring can now begin.

@interactivity also pre-landed half of C.2.5 while debugging I.0: `PlayerController._poll_modal_mouse_mode()` (id=3979) edge-detects `is_modal_ui_open()` transitions and applies the canonical mouse mode. That makes the per-panel `Input.set_mouse_mode(VISIBLE)` write at `dialogue_panel.gd:122` redundant — it stays in place for now (idempotent, sets the same value), and gets deleted as the last item in C.2.5.

**Original spec, kept verbatim for sequencing reference:**

**Spec:** delete the C.2 stopgap (`DialogueSession.is_any_panel_open()` + raycaster early-out + FlyCamera gate + cross-system `src/core/interaction/` → `src/core/dialogue/` import) and replace with `PlayerController` (built by @interactivity in I.0) owning input routing.

**Locked API contract** (per reviewer post #text id=3881 + interactivity post #interactivity id=3873/3920):
```gdscript
# src/core/player/player_controller.gd (built in @interactivity I.0)
signal interact_tap()
signal interact_hold_begin()
signal interact_release()

func register_modal_gate(gate: Node) -> void  # gate must implement is_open() -> bool
func unregister_modal_gate(gate: Node) -> void
func is_modal_ui_open() -> bool
```

**C.2.5 dialogue-side work** (~30 lines across 5 files when I.0 lands):
- `DialogueUI.open()` calls `PlayerController.register_modal_gate(self)` (already has `is_open()`)
- `DialogueUI.close()` calls `PlayerController.unregister_modal_gate(self)`
- Same for `BookViewer.show_book()` / `hide_book()` (already added `is_open()` in C.2)
- Same for `JournalPanel.open()` / `close()` (needs 1-line `is_open()` addition)
- Delete `DialogueSession.is_any_panel_open()` method
- Delete `InteractionRaycaster._unhandled_input` session early-out
- Delete `FlyCamera._input/_process` session gate
- Delete `DialogueUI.open()` direct `Input.set_mouse_mode(VISIBLE)` call (PlayerController owns mouse mode)
- Delete `src/core/interaction/` import of `dialogue_session.gd`

C.2.5 cannot start until @interactivity ships I.0. Sequencing per reviewer #text id=3872: **C.2 ✅ → @interactivity I.0 → C.2.5 → C.5 (parallel with @interactivity I.1+)**.

### Phase C.3-C.7 — Main scene integration

Locked sequence per reviewer:

- **C.3** — Spawn `DialogueUI` + `BookViewer` + `JournalPanel` + `DialogueSession` as persistent children of `scenes/Godotwind.tscn`. Init `DialogueSession.set_current(...)` at boot.
- **C.4** — Attach `InteractionRaycaster` to the player camera in the FPS controller used by the main scene.
- **C.5** — `reference_spawned` signal on `src/core/world/reference_instantiator.gd`. New MW glue file (`src/core/dialogue/morrowind/mw_reference_decorator.gd` or similar) listens to that signal, attaches `NPCInteractable`/`BookInteractable` to spawned nodes by ESM record type, AND guarantees an Interactable-layer-3 collider exists (adding a dedicated `StaticBody3D` child if the existing physics body is on a layer we don't want to disturb — NPCs already have a character body on layer 2). `reference_instantiator` itself stays MW-free; the decorator file is the only place that imports MW adapters.
- **C.6** — `DialogueUI.response_selected.connect(MWQuestAdapter.on_response_selected)` once at startup.
- **C.7** — Journal toggle key binding (J?).

**C.5 is gated on C.2.5** because C.5 introduces more `Interactable` adapters via the decorator and the polling-soup input model would get worse with each new adapter.

### Active carry-forwards beyond Phase C
- Quest display names from first QSTN entry text (currently raw IDs)
- Two-page book spread (use `BookRecord.is_scroll` for layout switching — flag already wired through `BookInteractable.get_prompt_text()`)
- Book pagination with page turn animations
- Journal search/filter

### Phase D — Advanced dialogue (real gameplay content)
- **Result script (BNAM) interpreter.** Currently parsed but not executed. Handlers for `Journal`, `AddItem`, `SetDisposition`, `SetGlobal`, `Choice`. Biggest gameplay-unblocking feature left — without this dialogue can't actually modify game state.
- **Choice branching:** result scripts set `Choice` variable, filter matches against it
- **Persuasion mechanics:** admire/intimidate/taunt/bribe wheel with disposition delta formula
- **Derived disposition formula.** `NPCInteractable.interact()` currently copies raw `NPCRecord.disposition` into context. Port OpenMW's `getDerivedDisposition()` (base + faction reaction + race reaction + personality attribute + reputation + per-NPC persuasion modifiers) into `mw_dialogue_provider.gd` or `npc_interactable.gd`. Affects filter accuracy.
- **INFO chaining:** verify `prev_id/next_id` semantics (may be mod load-order, not conversation flow)
- **Service UIs:** merchant, trainer, spellmaker, enchanter (all accessed via dialogue)

### Phase E — Deep
- MW SCPT bytecode VM
- Voice line playback (SNAM references in INFO records)
- NPC lip sync / animation during dialogue
- Save/load quest state and dialogue history
- Tooltip system for items, spells, ingredients
- **`DialogueProvider.get_speaker_name()` silent fallback cleanup** (returns `speaker_id` on failure instead of typed error — flagged in review)
