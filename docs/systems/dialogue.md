# Text & Dialogue System

Built 2026-04-02. Phase A (theme + typed Response contract) + Phase B (interaction framework + in-world integration) landed 2026-04-06.

Framework-first architecture — Morrowind is one data source, not the architecture.

---

## Current state (2026-04-18)

- Phase A (theme + typed Response envelope) + Phase B (interaction framework + in-world demo) shipped 2026-04-06.
- Phase C.0 (MWDialogueContext split out of generic DialogueContext), C.1 (dead `process_dialogue_result` path deleted), and C.2 (DialogueSession singleton + interactable shrink + DialogueUI topic-click bug fix) shipped 2026-04-07.
- Phase C.2.5 (PlayerController-owned input routing, deletes the C.2 stopgap cross-imports) — **unblocked, in progress.** The click bug that originally parked it was fixed via the separate I.0 interactivity refactor (BookViewer overlay leak + orphaned `_build_ui` indent in `dialogue_panel.gd`).
- Main-scene integration (Phase C.3–C.7: spawn singletons under `scenes/Godotwind.tscn`, attach `InteractionRaycaster` to the player camera, `reference_spawned` decorator for NPC/book interactables, journal key binding) is **still pending.** Only `tests/visual/test_interaction.tscn` demonstrates the end-to-end vertical slice.
- Forensic session log for the C.2 click-bug hunt + C.2.5 sequencing is archived at `docs/archive/sessions/dialogue_phase_c_bughunt_2026_04_07.md`.

---

## Architecture

```
src/core/dialogue/                    Generic framework (no MW references)
    dialogue_context.gd               Player/world state for dialogue evaluation
    dialogue_data.gd                  Value types: DialogueLine, TopicEntry
    dialogue_provider.gd              Abstract provider base + Response envelope + Error enum
    dialogue_session.gd               RefCounted singleton — shared provider/context/UI refs (C.2)
    quest_manager.gd                  Quest state tracking, journal entries, signals

src/core/dialogue/morrowind/          MW translation layer (all MW-specific logic)
    mw_condition_parser.gd            SCVR byte format parser
    mw_dialogue_context.gd            MWDialogueContext — MW-specific PC fields (C.0 split)
    mw_dialogue_functions.gd          74 built-in MW dialogue function IDs
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
- 2675 NPCs, 1698 dialogue topics + 632 journal topics + 10 greetings, ~24k INFO records loaded (see ESM Data Summary table below for canonical counts)

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
