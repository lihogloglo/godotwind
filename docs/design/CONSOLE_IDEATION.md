# In-Game Console System - Ideation Document

## Vision Statement

A professional-grade developer console that serves as both a **debugging powerhouse** and a **creative tool** for Morrowind content creation. Designed to evolve into MWScript compatibility while providing modern scripting capabilities from day one.

---

## Design Decisions (Confirmed)

| Decision | Choice | Notes |
|----------|--------|-------|
| Scripting Language | **GDScript subset** | Variables, loops, functions - familiar to Godot users |
| Console Position | **Overlay, top-left** | Quake/Bethesda style dropdown |
| Selection Visual | **Outline shader** | Highlight selected objects clearly |
| Implementation Priority | **Object picking first** | Foundation for inspection commands |

---

## Reference Analysis: Industry Best-in-Class Consoles (2025)

### Bethesda Console (Skyrim/Fallout 4)
**Strengths:**
- Click-to-select objects in world (sets `player.placeatme` target)
- Direct property manipulation (`setav health 100`)
- Form ID based addressing
- Batch file execution (`.bat` files)
- Command history with arrow keys

**Weaknesses:**
- No autocomplete
- Cryptic error messages
- No syntax highlighting
- Single-line input only

### Source Engine Console (Half-Life 2, CS:GO)
**Strengths:**
- Tab autocomplete with fuzzy matching
- ConVar system (typed variables with validation)
- Real-time filtering as you type
- Persistent command history across sessions
- `find` command to search all commands

**Weaknesses:**
- No object picking
- Limited scripting (config files only)

### Unreal Engine Console
**Strengths:**
- Full C++ reflection for property access
- Exec functions exposable from any class
- Statistical commands (`stat fps`, `stat memory`)
- Blueprint accessible
- Remote console for mobile debugging

### Unity Console / Quantum Console (Asset Store Gold Standard)
**Strengths:**
- Attribute-based command registration (`[Command]`)
- Parameter auto-parsing with type safety
- Suggestion system with descriptions
- Macro recording
- Log filtering by category/severity
- Collapsible stack traces

---

## Core Design Pillars

### 1. **Discoverability First**
Users should be able to explore what's possible without documentation. Every command should be findable, every object inspectable.

### 2. **Progressive Disclosure**
- Level 1: Simple commands (`help`, `tp`, `spawn`)
- Level 2: Property inspection (`inspect player.health`)
- Level 3: Scripting (`for cell in loaded_cells: print(cell.name)`)
- Level 4: MWScript compatibility

### 3. **Context-Aware**
The console knows what you're looking at, where you are, and what you've selected. Commands operate on implicit context when explicit targets aren't provided.

### 4. **Non-Destructive by Default**
Dangerous operations require confirmation or explicit flags. State can be saved/restored.

---

## Feature Specification

### A. Visual Design

```
┌─────────────────────────────────────────────────────────────────────┐
│ [Console]                                              [─] [□] [×] │
├─────────────────────────────────────────────────────────────────────┤
│ ┌─Output Area────────────────────────────────────────────────────┐ │
│ │ > cells                                                        │ │
│ │ Loaded cells (12):                                             │ │
│ │   (-2, -9)  Seyda Neen Region     [EXTERIOR]                  │ │
│ │   (-3, -9)  Seyda Neen Region     [EXTERIOR]                  │ │
│ │   ...                                                          │ │
│ │                                                                 │ │
│ │ > select                                                       │ │
│ │ Click on an object in the world...                            │ │
│ │ [Flora_kelp_02] selected at (-72156, 3241, -118836)           │ │
│ │   Type: STAT (Static)                                         │ │
│ │   Cell: (-2, -9) Seyda Neen Region                           │ │
│ │   Model: meshes/f/flora_kelp_02.nif                          │ │
│ └─────────────────────────────────────────────────────────────────┘ │
│ ┌─Suggestions─────────────────────────────────────────────────────┐ │
│ │ select        Select object by clicking      sel, pick         │ │
│ │ set           Set a property value           =                 │ │
│ │ settings      Open settings panel            config            │ │
│ └─────────────────────────────────────────────────────────────────┘ │
│ ┌─Input──────────────────────────────────────────────────────────┐ │
│ │ > sel█                                                         │ │
│ └─────────────────────────────────────────────────────────────────┘ │
│ [History ▾]  [Filter: All ▾]  [Copy]  [Clear]       Ln 1, Col 4   │
└─────────────────────────────────────────────────────────────────────┘
```

**Key Visual Elements:**
- **Syntax highlighting**: Commands (cyan), arguments (white), strings (green), numbers (yellow), errors (red)
- **Collapsible output groups**: Long outputs collapse to `[+] 847 static objects...`
- **Inline object links**: Click `[Flora_kelp_02]` to select/inspect it
- **Severity indicators**: `[INFO]` `[WARN]` `[ERROR]` with color coding
- **Timestamp toggle**: Optional `[12:34:56.789]` prefix
- **Resizable/dockable**: Drag to resize, dock to edges, pop out to window

### B. Command System Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│                        COMMAND PIPELINE                            │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│  Input → Lexer → Parser → Resolver → Executor → Output Formatter  │
│                     ↓           ↓          ↓                       │
│              AST Nodes    Bound Refs   Results                     │
│                     ↓           ↓          ↓                       │
│              Suggestions  Validation  History                      │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

**Command Registration Pattern:**
```gdscript
# Declarative command registration
@console_command("tp", "Teleport to location or cell")
@console_param("target", TYPE_STRING, "Cell name, coordinates, or landmark")
@console_param("--height", TYPE_FLOAT, "Height offset", default=100.0)
@console_alias("teleport", "goto", "warp")
func cmd_teleport(target: String, height: float = 100.0) -> ConsoleResult:
    # Implementation
    pass
```

**Command Categories:**
| Category | Examples | Description |
|----------|----------|-------------|
| Navigation | `tp`, `goto`, `look` | Movement and camera |
| World | `cells`, `spawn`, `delete`, `weather` | World manipulation |
| Inspect | `select`, `inspect`, `watch` | Object examination |
| Debug | `stats`, `profile`, `log` | Performance & logging |
| System | `help`, `alias`, `bind`, `exec` | Console itself |
| Script | `run`, `eval`, `def` | Scripting commands |
| Morrowind | `player`, `coc`, `coe`, `tcl` | MW-compatible commands |

### C. Object Picking System

**Architecture:**
```
┌─────────────────────────────────────────────────────────────────┐
│                     OBJECT PICKER                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Mouse Click → Screen-to-Ray → Physics Query → Hit Resolution  │
│                                      ↓                          │
│                              Multiple Hits?                     │
│                              ↓           ↓                      │
│                           Single      Picker Popup              │
│                              ↓           ↓                      │
│                         Selection ← User Choice                 │
│                              ↓                                  │
│                      Context Population                         │
│                              ↓                                  │
│                    Console.selected = Object                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Selection Features:**
- **Raycast through transparency**: Don't stop at alpha-tested foliage
- **Multi-select support**: Shift+click to add, Ctrl+click to toggle
- **Selection outline**: Highlight shader on selected objects
- **Info overlay**: Floating label with basic info near selected object
- **Selection history**: Navigate with `[` and `]` keys

**Object Identity Resolution:**
```gdscript
# When an object is picked, resolve its identity chain:
Selection {
    node: Node3D,                    # Godot node reference
    cell_ref: CellReference,         # ESM cell reference record
    base_record: ESMRecord,          # Base STAT/ACTI/NPC_/etc record
    form_id: String,                 # Morrowind Form ID
    instance_id: int,                # Runtime instance ID
    transform: Transform3D,          # World transform
    metadata: Dictionary             # Additional runtime data
}
```

### D. Property System

**Inspectable Properties:**
```
> inspect selected

[Flora_kelp_02] STAT (Static Object)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Form ID:        flora_kelp_02
Instance:       #4821
Position:       (-72156.3, 3241.8, -118836.1)
Rotation:       (0.0, 45.2, 0.0)
Scale:          1.0
Cell:           (-2, -9) "Seyda Neen Region"
Model:          meshes/f/flora_kelp_02.nif

[Runtime Properties]
  visible         true
  collision       true
  layer           STATIC

[Writable ✎]
  > set position.y 3300
  > set visible false
```

**Property Path Syntax:**
```
selected.position.y          # Nested property access
player.stats.health          # Player stat
cell(-2,-9).objects          # Cell contents
npc("fargoth").ai.state      # NPC by name
```

### E. Scripting Language Options

**Option 1: GDScript Subset (Recommended for v1)**
```gdscript
# Inline evaluation
> 2 + 2
4

# Variables persist in console session
> var my_pos = player.position
> print(my_pos)
Vector3(-72156, 3241, -118836)

# Loops and comprehensions
> for obj in selected_objects: obj.visible = false

# Function definitions
> def mark_all_flora():
>     for obj in cell.objects:
>         if obj.type == "STAT" and "flora" in obj.id:
>             obj.selected = true
> mark_all_flora()
Marked 47 objects
```

**Option 2: Custom DSL (Simpler, Safer)**
```
# More restrictive but easier to parse
tp seyda_neen
set player.health 100
spawn npc fargoth at player
for $obj in cell.objects where $obj.type == "FLORA": hide $obj
```

**Option 3: MWScript Compatibility Layer (Future)**
```
; Native MWScript syntax
player->additem gold_001 1000
set health to 100
if ( player->getpos z ) < 0
    player->setpos z 0
endif
```

**Recommendation:** Start with **GDScript subset** for power users, add **MWScript parser** as separate subsystem that transpiles to internal commands.

### F. Autocomplete & Suggestions

**Fuzzy Matching:**
```
> tele         → tp, teleport (exact prefix)
> tlprt        → teleport (fuzzy consonant match)
> seydaneen    → "Seyda Neen", "Seyda Neen, Census and Excise Office"
```

**Context-Aware Suggestions:**
```
> spawn npc [TAB]
  fargoth        NPC, Seyda Neen
  hrisskar       NPC, Seyda Neen
  sellus_gravius NPC, Census Office
  ... (filtered to NPCs near current location)

> tp [TAB]
  seyda_neen     Exterior cell
  balmora        Exterior cell
  (-2, -9)       Current cell
  player         At player position
  selected       At selected object
```

**Documentation Inline:**
```
> help spawn
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SPAWN - Create an object in the world
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Usage:
  spawn <type> <id> [at <location>] [--count N]

Arguments:
  type      Object type: npc, creature, item, static, activator
  id        Form ID or partial match
  location  "player", "selected", "camera", or coordinates

Examples:
  spawn npc fargoth
  spawn item gold_001 at player --count 100
  spawn static flora_tree_ai at (1000, 0, 2000)

Aliases: create, place, add
```

### G. Persistent Features

**Command History:**
- Saved to `user://console_history.txt`
- Searchable with Ctrl+R (reverse search)
- Deduplication of consecutive identical commands

**Aliases & Macros:**
```
> alias ll "cells --verbose"
> alias home "tp -72156 -118836"
> bind F5 "quicksave; print 'Saved!'"
> macro setup_debug
>   stats on
>   wireframe on
>   set player.god true
> end
```

**Session State:**
```
> save_session debug_session_1
Saved: 12 variables, 5 aliases, 3 watched values

> load_session debug_session_1
Restored session state
```

### H. Watch System

```
> watch player.position
> watch Performance.fps
> watch cell_manager.loaded_count

┌─Watches────────────────────────────────┐
│ player.position   (-72156, 3241, ...)  │
│ Performance.fps   59.8 ▼               │
│ loaded_count      12                   │
└────────────────────────────────────────┘
```

---

## Technical Architecture

### Module Structure

```
src/core/console/
├── console.gd                 # Main console controller
├── console_ui.gd              # UI management (CanvasLayer)
├── command_registry.gd        # Command registration & lookup
├── command_parser.gd          # Lexer, parser, AST
├── command_executor.gd        # Execution engine
├── console_context.gd         # Variables, selection, state
├── autocomplete.gd            # Fuzzy matching, suggestions
├── object_picker.gd           # World object selection
├── history_manager.gd         # Command history persistence
├── output_formatter.gd        # Rich text formatting
│
├── commands/                  # Built-in command implementations
│   ├── navigation_commands.gd
│   ├── world_commands.gd
│   ├── inspection_commands.gd
│   ├── debug_commands.gd
│   └── system_commands.gd
│
├── scripting/                 # Scripting subsystem
│   ├── script_evaluator.gd    # GDScript subset eval
│   └── mwscript/              # Future MWScript support
│       ├── mwscript_lexer.gd
│       ├── mwscript_parser.gd
│       └── mwscript_runtime.gd
│
└── ui/                        # UI components
    ├── console_panel.tscn
    ├── suggestion_popup.tscn
    ├── watch_panel.tscn
    └── object_picker_overlay.tscn
```

### Integration Points

```gdscript
# In world_explorer.gd or lapalma_explorer.gd
func _ready():
    # Initialize console
    console = preload("res://src/core/console/console.tscn").instantiate()
    add_child(console)

    # Inject dependencies
    console.register_context("player", player_controller)
    console.register_context("camera", get_active_camera)
    console.register_context("cell_manager", cell_manager)
    console.register_context("world", world_streaming_manager)
    console.register_context("esm", ESMManager)
    console.register_context("profiler", profiler)

    # Register custom commands
    console.register_command("coc", _cmd_center_on_cell)
    console.register_command("coe", _cmd_center_on_exterior)

func _input(event):
    if event.is_action_pressed("toggle_console"):  # Tilde key
        console.toggle()
```

### Performance Considerations

1. **Lazy Autocomplete**: Only compute suggestions after 100ms pause in typing
2. **Virtual Scrolling**: Output area only renders visible lines
3. **Command Throttling**: Rate-limit rapid command execution
4. **Async Execution**: Long commands run via BackgroundProcessor with progress
5. **Output Batching**: Batch multiple prints into single UI update

---

## MWScript Compatibility Roadmap

### Phase 1: Command Parity
Map Morrowind console commands to internal equivalents:
- `player->additem` → `give player <item> <count>`
- `coc <cell>` → `tp <cell>`
- `tcl` → `noclip toggle`
- `tgm` → `god toggle`

### Phase 2: Script Parser
- Implement MWScript lexer/parser
- Support BEGIN/END blocks
- Variable declarations (short, long, float)
- Control flow (if/elseif/else/endif, while)

### Phase 3: Script Runtime
- MessageBox with choices
- Quest stage manipulation
- Faction/disposition system integration
- Journal entries

### Phase 4: Script Editor Integration
- Syntax highlighting for `.mwscript` files
- Live reload of scripts
- Breakpoint debugging

---

## Accessibility & UX

### Keyboard Navigation
| Key | Action |
|-----|--------|
| `` ` `` or `~` | Toggle console |
| `Enter` | Execute command |
| `Tab` | Autocomplete / cycle suggestions |
| `↑` / `↓` | History navigation |
| `Ctrl+R` | Reverse history search |
| `Ctrl+C` | Cancel current input / copy selection |
| `Ctrl+L` | Clear output |
| `Ctrl+U` | Clear input line |
| `Escape` | Close console / cancel selection mode |
| `Page Up/Down` | Scroll output |

### Mouse Interaction
- Click output to select text
- Click object references to select them
- Right-click for context menu (copy, inspect, etc.)
- Drag edges to resize
- Double-click word to select

### Accessibility Features
- High contrast mode option
- Configurable font size (12-24pt)
- Screen reader compatible output
- Colorblind-friendly palette option

---

## Configuration

```gdscript
# user://console_config.tres or project settings
console_config = {
    "ui": {
        "font_size": 14,
        "opacity": 0.95,
        "height_ratio": 0.4,      # 40% of screen when open
        "position": "top",        # top, bottom, or floating
        "theme": "dark",          # dark, light, custom
        "show_timestamps": false,
        "max_history_lines": 10000,
        "max_output_lines": 5000,
    },
    "behavior": {
        "autocomplete_delay_ms": 100,
        "history_file": "user://console_history.txt",
        "max_history_entries": 1000,
        "echo_commands": true,
        "confirm_destructive": true,
    },
    "keybinds": {
        "toggle": "KEY_QUOTELEFT",  # Tilde
        "execute": "KEY_ENTER",
        "autocomplete": "KEY_TAB",
        "history_up": "KEY_UP",
        "history_down": "KEY_DOWN",
    }
}
```

---

## Example Command Session

```
Godotwind Console v0.1.0
Type 'help' for available commands, 'help <command>' for details.

> help
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

NAVIGATION
  tp <target>              Teleport to location
  goto <x> <y> [z]         Go to world coordinates
  look <target>            Point camera at target

WORLD
  cells                    List loaded cells
  spawn <type> <id>        Create object
  delete [target]          Remove object

INSPECT
  select                   Enter selection mode (click object)
  inspect [target]         Show object properties
  watch <expr>             Add expression to watch panel

DEBUG
  stats [on|off]           Toggle performance overlay
  log <level>              Set log verbosity
  profile [start|stop]     CPU profiling

SYSTEM
  help [command]           Show help
  alias <name> <cmd>       Create command alias
  clear                    Clear console output

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

> cells
Loaded cells (12):
  (-3, -9)  Seyda Neen Region     847 objects
  (-2, -9)  Seyda Neen Region     1203 objects
  (-2,-10)  Bitter Coast Region   445 objects
  ...

> select
Selection mode active. Click an object in the world...
[Clicked]
Selected: [furn_de_rope_woven_01] at (-71842.3, 3198.1, -118702.5)

> inspect
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[furn_de_rope_woven_01] STAT (Static Object)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Form ID:      furn_de_rope_woven_01
Model:        meshes/f/furn_de_rope_woven_01.nif
Position:     (-71842.3, 3198.1, -118702.5)
Rotation:     (0.0, 12.5, 0.0)
Scale:        1.0
Cell:         (-2, -9) "Seyda Neen Region"

> set selected.position.y 3500
Property updated: position.y = 3500.0

> tp balmora
Teleporting to Balmora...
Arrived at (-22016.0, 1280.0, 4096.0)

> spawn npc fargoth at player
Created [fargoth] at player position

> stats on
Performance overlay enabled.

> watch player.position
Added watch: player.position

> # This is a comment, ignored

> var test = 42
> print(test * 2)
84

> alias home "tp -72156 -118836 3241"
Alias created: home → "tp -72156 -118836 3241"

> home
Teleporting to (-72156, -118836, 3241)...
```

---

## Open Questions for Discussion

1. **Scripting Language**: GDScript subset vs custom DSL vs both?
2. **Multi-select UX**: Box select? Shift+click? Both?
3. **Console Position**: Overlay (Bethesda-style) vs dockable panel vs both?
4. **Command Confirmation**: Which commands should require confirmation?
5. **Remote Console**: Support for connecting from external tools?
6. **Replay System**: Record and replay command sessions?

---

## Next Steps

1. **Prototype Core**: Basic console UI with input/output
2. **Command Framework**: Registration, parsing, execution
3. **Object Picker**: Raycast selection with identity resolution
4. **Essential Commands**: tp, cells, inspect, help
5. **Autocomplete**: Basic prefix matching
6. **Integration**: Hook into world_explorer and lapalma_explorer
7. **Polish**: History, aliases, watch panel
8. **MWScript**: Parser and runtime (later phase)

---

*Document Version: 0.1.0*
*Created: 2025-12-18*
*Author: Claude (with human direction)*
