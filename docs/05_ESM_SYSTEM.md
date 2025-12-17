# ESM Parsing System

## Overview

The ESM (Elder Scrolls Master file) parser reads Morrowind's `.esm` and `.esp` files, extracting all game data: world geometry, NPCs, items, quests, dialogue, scripts, and more. Supports **47 record types** with case-insensitive lookups.

## Key Files

| File | Purpose |
|------|---------|
| `src/core/esm/esm_manager.gd` | Autoload singleton, main API |
| `src/core/esm/esm_reader.gd` | Binary file parser |
| `src/core/esm/esm_defs.gd` | Record type constants |
| `src/core/esm/records/` | 47 record type parsers |

## ESMManager API

```gdscript
# Autoload: ESMManager (globally accessible)

# Main data dictionaries (all case-insensitive keys)
var statics: Dictionary       # record_id -> StaticRecord
var exterior_cells: Dictionary # "x,y" -> CellRecord
var interior_cells: Dictionary # cell_name -> CellRecord
var lands: Dictionary         # "x,y" -> LandRecord
var land_textures: Dictionary # index -> LandTextureRecord
var npcs: Dictionary          # record_id -> NPCRecord
var creatures: Dictionary     # record_id -> CreatureRecord
var dialogues: Dictionary     # topic -> DialogueRecord
var scripts: Dictionary       # record_id -> ScriptRecord
# ... 40+ more dictionaries

# Lookups
func get_cell(x: int, y: int) -> CellRecord
func get_land(x: int, y: int) -> LandRecord
func get_interior_cell(name: String) -> CellRecord
```

## Record Types (47 total)

```
World:     CELL, LAND, REGN, LTEX, PGRD
Objects:   STAT, DOOR, CONT, LIGH, ACTI
Items:     WEAP, ARMO, CLOT, MISC, BOOK, ALCH, INGR, APPA, LOCK, PROB, REPA
Actors:    NPC_, CREA, BODY, LEVI, LEVC
Magic:     SPEL, ENCH, MGEF
Character: CLAS, RACE, FACT, BSGN, SKIL
Dialogue:  DIAL, INFO
Other:     GMST, GLOB, SOUN, SNDG, SCPT, SSCR
```

## Binary Format

ESM files use a record-subrecord structure:

```
ESM File
├─ TES3 Header (version, master files)
└─ Records
   ├─ STAT record
   │  ├─ NAME subrecord (record ID)
   │  └─ MODL subrecord (model path)
   ├─ CELL record
   │  ├─ NAME (cell name)
   │  ├─ DATA (grid coords, flags)
   │  ├─ FRMR (object reference start)
   │  └─ DATA (position, rotation)
   └─ ...
```

## LAND Records (Terrain)

```gdscript
class LandRecord:
    var grid_x: int          # Cell X coordinate
    var grid_y: int          # Cell Y coordinate
    var height_data: PackedInt32Array  # 65x65 delta-encoded heights
    var texture_indices: PackedInt32Array  # 16x16 texture slots
    var vertex_colors: Array[Color]  # 65x65 vertex colors (optional)
```

Heightmap uses **delta encoding**: each vertex stores offset from previous.

## Cell References

Cells contain object placement data:

```gdscript
class CellReference:
    var refnum: int          # Unique reference ID
    var base_object_id: String  # e.g., "flora_kelp_01"
    var position: Vector3    # World position (Morrowind coords)
    var rotation: Vector3    # Euler angles (ZYX order)
    var scale: float         # Usually 1.0
```

## Dialogue System

```gdscript
# DIAL: Topic definition
class DialogueRecord:
    var topic: String        # "Background", "little advice"
    var type: int           # 0=Topic, 1=Voice, 2=Greeting, 3=Persuasion, 4=Journal
    var infos: Array[DialogueInfoRecord]

# INFO: Individual dialogue entry
class DialogueInfoRecord:
    var disposition: int     # Min disposition required (0-100)
    var npc_id: String      # Specific NPC or empty for any
    var faction: String     # Faction requirement
    var conditions: Array   # Script conditions
    var text: String        # Dialogue text
    var result_script: String  # Script to run when selected
```

## Data Statistics (Morrowind.esm)

```
Statics: 2,841       Creatures: 240
Doors: 109           NPCs: 2,834
Cells: 1,138         Dialogues: 2,836
Lands: 719           Dialog Infos: 46,923
Spells: 1,184        Scripts: 1,173
```

## Usage Notes

1. **Always use lowercase for lookups** - Record IDs are case-insensitive
2. **Cache frequently accessed records** - Don't look up every frame
3. **Handle missing records gracefully** - Use `.get()` with defaults

```gdscript
# Correct lookup
var npc = ESMManager.npcs.get("fargoth".to_lower())
if not npc:
    push_warning("NPC not found")
```

## See Also

- [STATUS.md](STATUS.md) - Implementation status
- [06_NIF_SYSTEM.md](06_NIF_SYSTEM.md) - Model conversion (uses STAT records)
