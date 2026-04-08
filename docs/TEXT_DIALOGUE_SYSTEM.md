# Text & Dialogue System

Built 2026-04-02. Phase A (theme + typed Response contract) + Phase B (interaction framework + in-world integration) landed 2026-04-06.

Framework-first architecture — Morrowind is one data source, not the architecture.

---

## Architecture

```
src/core/dialogue/                    Generic framework (no MW references)
    dialogue_context.gd               Player/world state for dialogue evaluation
    dialogue_data.gd                  Value types: DialogueLine, TopicEntry
    dialogue_provider.gd              Abstract provider base + Response envelope + Error enum
    quest_manager.gd                  Quest state tracking, journal entries, signals

src/core/dialogue/morrowind/          MW translation layer (all MW-specific logic)
    mw_condition_parser.gd            SCVR byte format parser
    mw_dialogue_functions.gd          74 built-in MW dialogue functions
    mw_dialogue_filter.gd             4-step INFO matching (OpenMW filter.cpp port)
    mw_dialogue_provider.gd           Greeting/topic/response lookup + topic highlighting
    mw_quest_adapter.gd               Journal DIAL/INFO → QuestManager mapping
    mw_text_formatter.gd              MW-specific HTML → BBCode converter
    npc_interactable.gd               NPC interaction adapter (Phase B) — opens DialogueUI
    book_interactable.gd              Book interaction adapter (Phase B) — opens BookViewer

src/core/interaction/                 Generic interaction framework (Phase B, no MW references)
    interactable.gd                   Base class: get_prompt_text / can_interact / interact
    interaction_raycaster.gd          Camera-mounted raycaster, collision layer 3

src/core/ui/                          Generic UI components
    text_formatter.gd                 Generic HTML markup → BBCode converter with callable hooks
    book_viewer.gd                    Book/scroll display panel (uses default_theme)
    journal_panel.gd                  Quest journal with active/completed tabs (uses default_theme)
    dialogue_panel.gd                 DialogueUI singleton (Phase B) — full conversation flow
    toast.gd                          Transient notification popup (uses default_theme)

assets/ui/
    fonts/pelagiad/Pelagiad.ttf       Pelagiad font (OFL, MW-themed serif)
    fonts/pelagiad/LICENSE.txt        OFL 1.1 license
    themes/default_theme.tres         Shared theme: Pelagiad + 5 StyleBox variations + label/button variations
    themes/BEFORE_STYLE_CATALOG.md    Source StyleBox values captured before Phase A extraction

tests/visual/
    test_book_viewer.tscn             Browse 30 MW books with formatted text + images
    test_dialogue.tscn                Thin harness — NPC selector + DialogueUI singleton
    test_journal.tscn                 Quest progression simulation with journal UI
    test_interaction.tscn             End-to-end Phase B vertical slice: fake NPC + book in a 3D world,
                                      InteractionRaycaster on camera, E to open dialogue/book

tests/tools/
    capture_screenshot.tscn           Utility: launch scene, wait, save PNG, quit.
                                      Sets WINDOW_FLAG_NO_FOCUS + MOUSE_PASSTHROUGH to isolate
                                      scene from desktop input for deterministic captures.
```

**Litmus test:** Someone could write an `OblivionDialogueProvider` without touching any framework file. Add `OblivionInteractable` subclasses under a new `src/core/dialogue/oblivion/` adapter directory; the generic `Interactable` base + `InteractionRaycaster` + `DialogueUI` stay untouched.

---

## What Works

### Book Viewer (Phase 1)
- MW HTML markup (`<BR>`, `<DIV ALIGN>`, `<FONT COLOR>`, `<FONT SIZE>`, `<IMG SRC>`, `<B>`, `<I>`) → Godot BBCode
- Images loaded from BSA via `TextureLoader`, inserted programmatically via `RichTextLabel.add_image()`
- 574 books loaded from ESM, 568 with HTML markup
- Parchment-style panel with scrollable text

### Dialogue Engine (Phase 2)
- **4-step filter** matching OpenMW's `filter.cpp`: testActor → testPlayer → testSelectStructs → testDisposition
- **SCVR condition parser**: type chars ('1'-'C'), comparison operators, function IDs, variable names
- **74 built-in MW functions** implemented: PC stats, attributes, skills, status flags (disease, vampire, werewolf), NPC AI data (fight/flee/alarm/hello), detection state, weather, clothing value, faction comparisons, global variables
- **Context-dependent greetings**: different greetings for naked player, sneaking player, diseased player, etc.
- **Greeting key format**: `"greeting 0"` through `"greeting 9"` (lowercase, space, digit)
- **Topic discovery**: scans response text for topic keywords with word boundary matching. Topics sorted longest-first to prevent partial matches ("little secret" before "little")
- **Pre-filter optimization**: `could_match_npc()` skips 90%+ of topics before running full filter
- 2675 NPCs, 2358 dialogue topics, ~24k INFO records loaded

### Conversation Flow (Phase 3)
- **Topic keyword highlighting**: words in response text matching known topics rendered as clickable `[url]` BBCode links with `meta_clicked` handler
- **Goodbye**: searches MW "goodbye" topic for NPC-specific farewell response
- **Disposition display**: shown next to NPC name
- **Topic cross-referencing**: clicking a highlighted word in response text navigates to that topic (MW's signature mechanic)

### Quest Journal (Phase 4)
- **QuestManager**: generic quest state tracker. States: INACTIVE → ACTIVE → COMPLETED/FAILED. Signals: quest_started, quest_updated, quest_completed, quest_restarted
- **MWQuestAdapter**: reads journal-type DIAL/INFO records. `disposition` field = journal index for journal INFOs (verified against ESM data). QSTN/QSTF/QSTR flags mapped to quest state changes
- **JournalPanel**: parchment-style UI with Active/Completed tabs, quest list, journal entries
- **Toast notifications**: "Your journal has been updated" / "Quest Complete" with fade-out
- 629 MW quests with correctly ordered journal entries

---

## Key Bugs Found & Fixed

| Bug | Impact | Fix |
|-----|--------|-----|
| `speaker_sex`/`speaker_rank`/`player_rank` read as unsigned bytes | ALL dialogue filtering broken — gender filter rejected every NPC | `_byte_to_signed()` converts 0xFF → -1 in `dialogue_info_record.gd` |
| QSTN/QSTF/QSTR subrecords skipped | Quest flags not stored, no journal tracking | Store as `bool` fields on `DialogueInfoRecord` |
| Books/dialogues not loaded by C# native path | 0 books, 0 dialogues after ESM load | Added `REC_BOOK`, `REC_DIAL`, `REC_INFO` to GDScript supplement pass |
| NPCs not populated before dialogue test | `ESMManager.npcs` empty (C# loader populates lazily) | Call `ensure_typed_dicts_populated()` before accessing NPC data |
| New scripts without `.gd.uid` files | `class_name` types not discoverable from command line | Use `preload()` references instead of global class names |
| `DETECTED` function defaulting to 0 | Player always "hidden" — sneaking greetings shown | Default `detected = true` in DialogueContext (normal conversation state) |

---

## ESM Data Summary

| Data | Count | Source |
|------|-------|--------|
| Books | 574 (568 with HTML markup) | GDScript supplement pass |
| Dialogue topics | 1,698 | GDScript supplement pass |
| Journal topics (quests) | 632 | GDScript supplement pass |
| Greeting DIALs | 10 (greeting 0-9) | GDScript supplement pass |
| Dialogue INFO records | ~24,000 | GDScript supplement pass |
| NPCs | 2,675 | C# native loader + `ensure_typed_dicts_populated()` |

The GDScript supplement pass adds ~1.9s to ESM load time (total ~7s with C# cache).

---

## Phase A — Shared theme + typed contract (2026-04-06)

**Shipped:**
- `assets/ui/themes/default_theme.tres` — single source of truth for all dialogue/book/journal/toast styling. Pelagiad font (OFL) as `default_font`, single `default_font_size = 18` controls all body text. Five StyleBoxFlat variations: Parchment (main panels) / ParchmentTight (dialogue response) / Toast (transient messages) / TopicsList (dark dialogue topic list) / ParchmentSeparator (decorative horizontal rule). Label/button variations: TitleLabel (26pt), DispositionLabel, ToastLabel, CloseButton (22pt).
- All 4 UI files (`book_viewer.gd`, `journal_panel.gd`, `toast.gd`, `test_dialogue.gd`) refactored to apply the theme via `theme = DEFAULT_THEME` + `theme_type_variation = "..."`. Inline `StyleBoxFlat.new()`, `add_theme_font_size_override`, `add_theme_color_override` calls **deleted** — no commented-out branches left.
- **`DialogueProvider.Response` envelope.** Replaced silent bare-null returns from provider methods with a typed `Response` class carrying `{error: Error, line, topics, topics_discovered, quest_updated, disposition_change, metadata}`. The `Error` enum distinguishes `OK`, `SPEAKER_NOT_FOUND` (bug), and `NO_INFO_MATCH` (valid state, show fallback UI). See `src/core/dialogue/dialogue_provider.gd` for the field matrix per-method.
- `MWDialogueProvider` all 4 query methods (`get_greeting`, `get_available_topics`, `get_response`, `get_goodbye`) return `Response`. `_resolve_npc == null` → `SPEAKER_NOT_FOUND`. `filter.search == null` → `NO_INFO_MATCH`.
- **Deleted:** `DialogueData.DialogueResult` (dead code after the Response envelope subsumed it).
- `tests/tools/capture_screenshot.gd` — reusable PNG capture tool for visual verification. Sets `WINDOW_FLAG_MOUSE_PASSTHROUGH + WINDOW_FLAG_NO_FOCUS` to isolate the scene from OS input during capture (critical — without this, a random user mouse click over a RichTextLabel url link mid-capture would fire `meta_clicked` and perturb scene state, as we experienced during development).

## Phase B — Interaction framework + in-world integration (2026-04-06)

**Shipped:**
- **`src/core/interaction/` directory** — new top-level subsystem. `Interactable` base class (generic, zero game-specific imports) with `get_prompt_text() / can_interact(player, distance) / interact(player)` virtuals, `enabled` + `max_interaction_distance` exports, `interacted(player)` signal. `InteractionRaycaster` Node3D that sits on the player camera, casts against collision layer 3 each physics frame, walks up from collider to find the first `Interactable` ancestor, and calls `interact()` on the configured InputMap action.
- **Collision layer 3 = "Interactable"** in `project.godot`. Layers 1-3: Environment / Player / Interactable.
- **`interact` InputMap action** in `project.godot`, bound to physical E key.
- `src/core/dialogue/morrowind/npc_interactable.gd` — MW adapter. Holds `speaker_id`, caches the `NPCRecord`, reads `ai_data.hello` → meters via `MW_UNITS_PER_METER = 70`, overrides `can_interact()` to enforce hello_distance on top of the generic range cap, `get_prompt_text()` returns `"Talk to <npc_name>"`, `interact()` opens a shared `DialogueUI` with the speaker_id.
- `src/core/dialogue/morrowind/book_interactable.gd` — MW adapter. Holds `book_id`, caches the `BookRecord`, `get_prompt_text()` returns `"Read <title>"` (or `"Unroll <title>"` for scrolls), `interact()` calls `BookViewer.show_book()`.
- **`DialogueUI` singleton** at `src/core/ui/dialogue_panel.gd`. Extracted from `test_dialogue.gd` (which is now a thin ~150-line harness). Persistent CanvasLayer at layer 90. `open(provider, speaker_id, context)` / `close()` / `is_open()`. Signals: `opened(speaker_id)`, `closed(speaker_id)`, `response_selected(topic_id, response)`. Handles the full conversation flow: greeting, topic discovery + highlighting, topic click, cross-referenced link click, goodbye (with 1.5s farewell display before auto-close). 85% alpha background so the 3D world dims through during conversation.
- **Quest signal wiring.** `MWDialogueProvider.get_response()` now populates `Response.metadata` with MW-specific extras: `{info_id, parent_topic, journal_index, quest_name_flag, quest_finish, quest_restart}`. The generic framework ignores the dict; `MWQuestAdapter.on_response_selected(topic_id, response)` is a signal handler that reads the metadata and calls `update_journal()` without re-running the filter. Wire via `dialogue_ui.response_selected.connect(quest_adapter.on_response_selected)`.
- **`tests/visual/test_interaction.tscn`** — end-to-end vertical slice. Minimal 3D world (floor, sun, WorldEnvironment) + fly camera + `InteractionRaycaster` + a fake NPC cylinder (with `NPCInteractable` as the root + child StaticBody3D on layer 3 + capsule collision) + a fake book cube. Press E to open. Exercises the complete Phase A + B pipeline: generic Interactable → MW adapter → DialogueUI → MWDialogueProvider → quest signal → MWQuestAdapter. Verified visually: walking up to the cylinder shows `[E] Talk to Fargoth (1.7m)` prompt, and E opens the dialogue with Fargoth's greeting + "ring" topic highlighted.

**Gotchas learned:**
- **Interactable must be an ancestor of the collider**, not a sibling. The raycaster walks UP from the hit collider to find the first Interactable. Prefab pattern: `NPCInteractable` (root, Node3D) → child `MeshInstance3D` + child `StaticBody3D` → child `CollisionShape3D`. Sibling layouts don't work because there's no walk-across-siblings step.
- **Input.parse_input_event synthetic keys must set BOTH `keycode` and `physical_keycode`.** InputMap bindings from `project.godot` use `physical_keycode` by default, so setting only `keycode` won't match the action. Fixed in `capture_screenshot.gd`.

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

---

## Technical Notes

### SCVR Condition Format
```
Byte 0: Index ('0'-'9')
Byte 1: Type ('1'=function, '2'=global, '3'=local, '4'=journal, '5'=item,
         '6'=dead, '7'-'C'=NOT filters)
Byte 2-3: Function ID (type '1') or qualifier
Byte 4: Compare op ('0'=eq, '1'=ne, '2'=gt, '3'=ge, '4'=lt, '5'=le)
Byte 5+: Variable name (types '2'-'C')
```

### MW Dialogue Filter Algorithm (4 steps, ALL must pass, first matching INFO wins)
1. **testActor**: actor_id, race, class, faction+rank, gender
2. **testPlayer**: PC faction+rank, current cell (prefix match, case-insensitive)
3. **testSelectStructs**: all SCVR conditions evaluated against context
4. **testDisposition**: NPC disposition >= INFO threshold

### Journal Index Mapping
For journal-type DIAL/INFO records, the `disposition` field on the INFO is overloaded as the journal stage index. Non-contiguous integers (5, 10, 15, 30, 60...). QSTF flag marks quest completion regardless of whether higher indices exist (alternate endings).

### Global Variables
`DialogueContext.globals` dictionary holds game state variables. MW's `CharGenState` must be >= 10 for post-character-creation dialogue. Other important globals: faction-specific quest state, main quest progression flags.
