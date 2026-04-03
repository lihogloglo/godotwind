# Text & Dialogue System

Built 2026-04-02. Framework-first architecture — Morrowind is one data source, not the architecture.

---

## Architecture

```
src/core/dialogue/                    Generic framework (no MW references)
    dialogue_context.gd               Player/world state for dialogue evaluation
    dialogue_data.gd                  Data types: DialogueLine, TopicEntry, DialogueResult
    quest_manager.gd                  Quest state tracking, journal entries, signals

src/core/dialogue/morrowind/          MW translation layer (all MW-specific logic)
    mw_condition_parser.gd            SCVR byte format parser
    mw_dialogue_functions.gd          74 built-in MW dialogue functions
    mw_dialogue_filter.gd             4-step INFO matching (OpenMW filter.cpp port)
    mw_dialogue_provider.gd           Greeting/topic/response lookup + topic highlighting
    mw_quest_adapter.gd               Journal DIAL/INFO → QuestManager mapping

src/core/ui/                          Generic UI components
    text_formatter.gd                 MW HTML markup → BBCode converter
    book_viewer.gd                    Book/scroll display panel
    journal_panel.gd                  Quest journal with active/completed tabs
    toast.gd                          Transient notification popup

tests/visual/
    test_book_viewer.tscn             Browse 30 MW books with formatted text + images
    test_dialogue.tscn                NPC dialogue with greeting, topics, clickable links
    test_journal.tscn                 Quest progression simulation with journal UI
```

**Litmus test:** Someone could write an `OblivionDialogueProvider` without touching any framework file.

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

## What's Next

### Phase 5: In-World Integration
- Click/interact with NPC in streaming world → open dialogue panel
- NPC interaction range check using `hello_distance` from AI data
- Camera focus on NPC during dialogue
- Click book object in world → open book viewer
- Wire quest updates into dialogue response flow (auto-update journal when NPC response has QSTN flag)

### Phase 6: UI Polish
- **Pelagiad font** ([github.com/Isaskar/Pelagiad](https://github.com/Isaskar/Pelagiad)) — MW-themed font for all UI
- Proper `default_theme.tres` with font slots and parchment styling
- Book viewer: two-page spread for books, single column for scrolls
- Book viewer: pagination with page turn
- Journal: quest display names extracted from first journal entry (not raw IDs)
- Journal: search/filter

### Phase 7: Advanced Dialogue
- **Persuasion mechanics**: admire/intimidate/taunt/bribe wheel with disposition delta formula
- **Choice branching**: result scripts set `Choice` variable, filter matches against it
- **INFO chaining**: verify prev_id/next_id semantics (may be mod load-order, not conversation flow)
- **Result script execution**: basic MW script interpreter for BNAM scripts (give item, set journal, set global)
- **Service UIs**: merchant, trainer, spellmaker, enchanter (accessed via dialogue)

### Phase 8: Advanced Features
- MW script VM (interpret compiled SCPT bytecode)
- Voice line playback (SNAM references in INFO records)
- NPC lip sync / animation during dialogue
- Save/load quest state and dialogue history
- Tooltip system for items, spells, ingredients

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
