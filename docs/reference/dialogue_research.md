# Dialogue & Text Systems — Industry Research

Research conducted 2026-04-02. Compares Godotwind's approach against industry patterns, existing tools, and Godot 4.6 capabilities. See `TEXT_DIALOGUE_SYSTEM.md` for implementation details.

---

## 1. Dialogue System Architectures

### 1.1 Three Major Patterns

**Hub-and-spoke (BioWare model)**
Games: Mass Effect, Dragon Age, Fallout 3/4, Cyberpunk 2077, Witcher 3.

Player selects from numbered/summarized options → NPC responds → new options appear. Conversation is a directed graph rooted at a greeting node. Each node has NPC text, optional camera/animation cues, and outgoing edges (player choices). Conditions on edges gate availability.

Strengths: Strong authorial control, easy to voice-act (one NPC line per node), natural for cinematic conversations. Weaknesses: Combinatorial explosion for complex conversations, topic exploration feels constrained.

**Topic-based (Elder Scrolls classic model)**
Games: Morrowind, Daggerfall, Ultima.

Player browses keyword topics. Clicking a topic queries the database for the best matching response given the NPC and game state. Topics mentioned in NPC responses become clickable, creating wiki-like hypertext browsing. No single conversation graph — player explores in any order.

Strengths: Extremely scalable (Morrowind: 2,358 topics, ~24,000 INFO records), every NPC can speak to any topic, feels like organic conversation. Weaknesses: Lacks dramatic pacing, hard to create emotional arcs within a single conversation, topic-discovery heuristic can cause false matches.

**Linear/sequential**
Games: Final Fantasy, Persona, Trails, visual novels.

Scripted sequence with occasional 2-3 option branches that quickly reconverge. Often presented as text boxes with character portraits.

Strengths: Tight dramatic control, easy to localize, works well with voice acting. Weaknesses: No player agency in most exchanges.

### 1.2 Hybrid Approaches (Industry Trend)

Modern games hybridize. Oblivion uses hub-and-spoke for main quests but keeps Morrowind's topic list for miscellaneous dialogue. Witcher 3 uses hub-and-spoke with scripted cinematics but has a "rumor" system that's topic-like. Disco Elysium uses a linear conversation tree with skill checks and an "inner voice" mechanic for thought interjections.

**Key insight for framework design:** All three patterns share the same data primitives — `DialogueLine` (speaker + text + conditions), available options/topics, and a filtering/selection mechanism. The difference is in the **orchestration layer** — how the UI presents options, whether topics auto-discover from text, and whether conversations are persistent (topic-based) or session-scoped (hub-and-spoke).

### 1.3 Conditional Dialogue Across Games

Every RPG's dialogue filtering boils down to:
```
ConditionSet = Array of (provider: String, key: String, op: CompareOp, value: Variant)
```

| Game | Approach | Details |
|------|----------|---------|
| Morrowind | 4-step cascade | testActor → testPlayer → testSelectStructs → testDisposition. 74 built-in functions. First match wins. ESM load order = priority. |
| Oblivion/Skyrim | Condition functions | Hundreds of engine-exposed functions + script-based conditions. Boolean AND combination. |
| Fallout NV | Challenge conditions | Adds speech skill checks displayed as `[Speech 50]` next to choices. Faction reputation + Karma as variables. |
| Disco Elysium | Skill checks | Passive/active checks against 24 skills. Difficulty modifiers visible to player. |

Godotwind's `MWConditionParser.ParsedCondition` with its `type` enum and `variable_name`/`function_id` fields is close to the generic abstraction. The 4-step filter in `mw_dialogue_filter.gd` matches OpenMW's `filter.cpp`.

### 1.4 Data-Driven vs Scripted

**Fully data-driven (Morrowind, Skyrim):** All dialogue content in a database format (ESM records). Engine interprets at runtime. Modders add records. Game logic is a "query engine" — given NPC + state, find best response.

**Script-driven (Yarn Spinner, Ink):** Dialogue authored as markup scripts resembling screenplays. Scripts contain conditionals, jumps, function calls. Runtime yields lines/choices to the game. More expressive for single conversations but harder to query across an entire database.

**Hybrid (Dialogic 2):** Visual timeline editor backed by JSON/resources. Events within timelines can call GDScript functions.

**Godotwind's approach is correct:** Data-driven for the framework, query/filter logic in the provider layer. Framework defines generic types. MW provider does the query. A different game could use Yarn scripts interpreted by its own provider, returning the same framework types.

---

## 2. Existing Tools Assessment

| Tool | License | Strengths | Why it doesn't fit |
|------|---------|-----------|-------------------|
| **Yarn Spinner** | MIT | Markup language for branching dialogue. Godot integration (GDYarn). | Designed for conversation graphs, not database-query topic systems. |
| **Ink (inkle)** | MIT | More expressive branching — weave patterns, threads, tunnels. GDScript runtime available. | Fundamentally linear/branching, not topic-based. |
| **Dialogic 2** | MIT | Native Godot addon. Visual timeline editor, portraits, choices. Extensible subsystems. | Can't handle MW's "query 24k INFOs across 2,358 topics with 74 condition functions" model. |
| **Clyde** | MIT | Simple Godot-native dialogue scripts. Lightweight. | Too lightweight for MW's complexity. |

**Verdict:** None can handle Morrowind's topic-based query model. Custom approach is correct.

### Dialogic 2 Patterns Worth Studying

While Dialogic 2 doesn't fit our needs, its architecture has good patterns:

- **Subsystem registration:** Core subsystems (Text, Portraits, Choices, Audio, Glossary, History, Variables) register at startup. Addons add new subsystems. Each processes events it cares about.
- **Timeline events:** Conversation flow as a sequence of typed "events" (text event, choice event, character join event, signal event). Custom event types extend the base class.
- **Style/layout separation:** Visual presentation completely separate from dialogue logic. A "style" resource controls appearance. Swap styles without changing content.
- **Variable system:** Own variable namespace (`{variable_name}` in text). Variables set from dialogue or GDScript. Analogous to MW's global variables and `DialogueContext`.

---

## 3. Text Rendering in Godot 4.6

### 3.1 RichTextLabel Capabilities

This is the right tool for all text display (books, dialogue, journal). Key features:

- Full BBCode: `[b]`, `[i]`, `[u]`, `[s]`, `[color]`, `[font_size]`, `[center]`, `[right]`, `[url]`, `[img]`, `[table]`, `[cell]`, `[hint]`
- `add_image()` method for in-memory textures (BookViewer already uses this correctly)
- `meta_clicked` signal for clickable text (topic highlighting already uses this correctly)
- Custom `RichTextEffect` classes for text animations
- `fit_content` property for auto-sizing
- `get_content_height()` for measuring rendered text height
- Paragraph and tab support
- BiDi text support
- Font fallback chains via `SystemFont` or `fallbacks` array

### 3.2 Limitations to Plan For

1. **No native two-page layout.** For a book spread, need two `RichTextLabel` instances side by side with manual text splitting.
2. **No page break concept.** Pagination requires measuring text height via `get_content_height()` and splitting content manually.
3. **Limited table support.** Tables work but cell sizing/spacing is basic.
4. **`[img]` BBCode tag doesn't support in-memory textures.** The `add_image()` workaround (which BookViewer already uses) is the correct solution — split text at image positions, call `append_text()` for text and `add_image()` for images.
5. **Custom effects require GDScript classes.** Each custom effect extends `RichTextEffect` with `_process_custom_fx()`. Performance fine for moderate text volumes.
6. **Font fallback chains** supported in 4.6 — useful for Unicode coverage.

### 3.3 Custom BBCode Effects (Future Polish)

For magical books, dream sequences, enchanted text:

```gdscript
class_name WaveEffect extends RichTextEffect
var bbcode = "wave"
func _process_custom_fx(char_fx: CharFXTransform) -> bool:
    char_fx.offset.y = sin(char_fx.elapsed_time * 5.0 + char_fx.range.x * 0.5) * 3.0
    return true
```

Register via `RichTextLabel.install_effect()`. Other possibilities: shake, rainbow, typewriter reveal, glow.

### 3.4 Custom Markup Languages Across Games

| Game | Markup | Notes |
|------|--------|-------|
| Morrowind | HTML subset (`<BR>`, `<DIV ALIGN>`, `<FONT COLOR SIZE>`, `<IMG SRC>`, `<B>`, `<I>`) | Godotwind's TextFormatter handles all of these |
| Oblivion/Skyrim | `<Alias>`, `<Global>` tags | Game-specific text substitution |
| Witcher (Lua) | `{if condition}text{else}other{/if}` | Inline conditional text |
| Generic RPGs | `%player_name%`, `$variable` | String interpolation |

**Framework pattern:** Define a `TextFormatter` interface with `convert(raw_text: String) -> FormattedText`. Each game provides its own implementation. Framework UI only consumes `FormattedText` (BBCode + image references).

---

## 4. Font Management & Theming

### 4.1 Industry Best Practice

Define a small set of semantic font slots (body, heading, tooltip, monospace) and assign fonts via a theme. Games typically use 2-3 font families total.

### 4.2 Godot 4.6 Theme System

- `Theme` resource with type variations per Control type (`Button`, `Label`, `RichTextLabel`, etc.)
- Font slots: `font` (default), custom theme properties per control type
- `FontVariation` for runtime sizing/spacing from a single font file
- Export `@export var theme: Theme` on panels for per-panel theming
- `Theme.set_default_font()` and `Theme.set_default_font_size()` for global defaults
- Supports OTF, TTF, WOFF2, system fonts, bitmap fonts

### 4.3 Recommended Font Setup

```
assets/ui/
    themes/
        default_theme.tres      # Main game theme with Pelagiad font
    fonts/
        pelagiad/
            Pelagiad.ttf        # MW-themed serif font (OFL license)
    textures/
        parchment_bg.png        # Optional: tileable parchment texture
```

Apply theme to root control of each CanvasLayer panel, or globally via Project Settings > GUI > Theme > Default Theme.

### 4.4 Current Duplication Issue

The parchment `StyleBoxFlat` (color `#E8DEC7`, border `#402614`) is created independently in BookViewer, JournalPanel, and test_dialogue.gd. This should be extracted to a shared Theme resource before more panels are built.

---

## 5. Quest/Journal Systems

### 5.1 Quest State Tracking Patterns

| Pattern | Games | How it works | Godotwind support |
|---------|-------|-------------|-------------------|
| **Index-based** | Morrowind | Single integer stage per quest (5, 10, 30, 60...). Flags for complete/restart. | Direct support via `update_journal()` |
| **Flag-based** | Skyrim, Oblivion | Multiple independent stage flags + "active objectives" display | Achievable by treating indices as flags |
| **Graph-based** | Disco Elysium, Unreal frameworks | Quest state as directed graph with transition triggers | Could layer on top via `update_journal()` calls |

Godotwind's `QuestManager` with `INACTIVE → ACTIVE → COMPLETED/FAILED` state machine, integer `current_index`, and sorted `JournalEntry` objects is a solid generic abstraction that covers all three patterns.

### 5.2 Journal UI Patterns

| Pattern | Games | Implementation |
|---------|-------|---------------|
| **Chronological** | Morrowind (original) | Entries in insertion order across all quests. Simple but confusing with many quests. |
| **Quest-grouped with tabs** | MW Tribunal, Oblivion, Skyrim | Active/completed tabs, quest list, per-quest entries. **This is what JournalPanel implements.** |
| **Active objectives** | Skyrim, Witcher 3 | HUD element showing current quest's next objective + map markers. |
| **Recent entries** | — | Third tab showing chronological entries across all quests (matches original MW journal). |

### 5.3 Toast Notification Patterns

| Pattern | Games | Notes |
|---------|-------|-------|
| Top/bottom-center transient | Morrowind, Oblivion | Simple text, 3-second fade. **Current implementation.** |
| Corner notification with icon | Skyrim, Witcher 3 | More visual, supports queuing. |
| Full-width banner slide-in | Many modern games | More dramatic, good for quest completion. |

For production, consider a notification queue — if `show_message()` is called while one is showing, queue the new message. Currently replaces immediately (fine for MW where updates are infrequent).

---

## 6. OpenMW Reference Implementation

### 6.1 Key OpenMW Files

| File | Purpose | Godotwind equivalent |
|------|---------|---------------------|
| `filter.cpp` | 4-step dialogue INFO matching | `mw_dialogue_filter.gd` |
| `dialoguemanagerimp.cpp` | Conversation orchestration | `mw_dialogue_provider.gd` |
| `selectwrapper.cpp` | SCVR condition evaluation wrapper | `mw_dialogue_functions.gd` + `mw_condition_parser.gd` |
| `journalentry.cpp` / `journalimp.cpp` | Journal system | `mw_quest_adapter.gd` + `quest_manager.gd` |

### 6.2 OpenMW Behaviors Worth Noting

- `startDialogue()` sets `mTalkedTo`, gets greeting, discovers topics in greeting text
- `keywordSelected()` looks up topic response, discovers new topics, executes result script
- `goodbye()` runs the "Goodbye" topic filter, ends conversation
- Disposition derived from complex formula: personality, reputation, faction reactions, race relations, per-NPC modifiers via `MWMechanics::getDerivedDisposition()`
- Topic discovery uses word boundary matching on response text — same approach as Godotwind

### 6.3 Disposition Formula (Not Yet Implemented)

OpenMW calculates derived disposition from:
- Base disposition (per-NPC)
- Faction reaction modifier (lookup table between factions)
- Race reaction modifier
- Personality attribute bonus
- Reputation bonus
- Per-NPC temporary modifiers (from persuasion)

Current Godotwind implementation uses a flat integer (default 50). For accurate MW dialogue filtering, the MW adapter needs to calculate this properly.

---

## 7. Architecture Assessment

### 7.1 What Godotwind Gets Right

1. **Framework/adapter separation** — `DialogueData`, `DialogueContext`, `QuestManager` are fully generic. MW logic isolated in `morrowind/` subdirectory. Passes the CLAUDE.md litmus test.
2. **4-step filter** — Faithful OpenMW port. `could_match_npc()` pre-filter is a smart optimization not present in OpenMW's filter.cpp.
3. **Topic discovery** — Word boundary matching, longest-match-first, BBCode-aware. Matches OpenMW's `dialoguemanagerimp.cpp`.
4. **Quest flags** — QSTN/QSTF/QSTR handling correct. `disposition = journal index` confirmed against ESM data.
5. **TextFormatter** — MW HTML → BBCode conversion with image extraction. Clean pipeline.
6. **CanvasLayer layering** — 90 for panels, 95 for toasts, 100 for loading. Proper z-ordering.
7. **Signal-based effects** — `quest_updated` signal keeps dialogue decoupled from game state.

### 7.2 Areas to Improve

| Issue | Impact | Recommendation |
|-------|--------|----------------|
| `TextFormatter` in framework layer has MW-specific logic | Breaks litmus test (BSA image loading, MW font sizes) | Move MW-specific parts to `morrowind/mw_text_formatter.gd` or extract MW-specific methods |
| Provider contract not formalized | New providers must read existing code to know the API | Add a `DialogueProvider` base class with virtual methods |
| `MWDialogueProvider` takes `NPCRecord` (MW type) as speaker | UI needs to know about `NPCRecord` | Providers should accept `speaker_id: String` and do own NPC lookup |
| Parchment style duplicated in 3 files | Inconsistency risk, maintenance burden | Extract to shared `default_theme.tres` with Pelagiad font |
| Result scripts (BNAM) stored but not interpreted | Dialogue can't trigger game effects | Needs basic MW script interpreter or pattern-matched handler for common commands |
| Disposition is simplified (flat int) | Inaccurate dialogue filtering for edge cases | Port OpenMW's derived disposition formula in MW adapter |
| Quest `display_name` defaults to raw ID | Journal shows `a1_6_addhiranirrinformant` | Extract display name from first QSTN entry text |

### 7.3 Common Dialogue Framework Mistakes (Avoided)

1. **Baking UI assumptions into the data layer** — Godotwind stores raw MW markup; TextFormatter converts for display. Correct.
2. **Monolithic dialogue manager** — Decomposed into 7+ files across framework and provider layers. Correct.
3. **Not separating "what can I say" from "what happens when I say it"** — `get_response()` returns metadata about effects but doesn't execute them. Correct.
4. **Hard-coding the conversation flow pattern** — Flow logic lives in the UI/test scene, not the framework. Correct.
5. **Tight coupling between dialogue and game state** — Signal-based approach (`quest_updated`, etc.). Correct.

---

## 8. Recommended Next Steps (Priority Order)

1. **Phase 5: In-world integration** — Click NPC → dialogue, click book → viewer. The "vertical slice" moment.
2. **Pelagiad font + Theme resource** — Extract shared styles to `default_theme.tres`, apply to all panels.
3. **Result script interpreter** (basic) — Handle common BNAM commands: `Journal`, `AddItem`, `SetDisposition`, `SetGlobal`, `Choice`.
4. **Disposition formula** — Port OpenMW's derived disposition calculation into MW adapter.
5. **Persuasion mechanics** — Admire/Intimidate/Taunt/Bribe wheel with disposition delta formula.
6. **Two-page book spread** — Use `BookRecord.is_scroll` flag for layout switching.
7. **Custom BBCode effects** — For magical text, enchanted books, dream sequences.
8. **Quest display names** — Extract from first QSTN journal entry text.
