# ESM Parsing System

## Overview

The ESM (Elder Scrolls Master file) parsing system reads Morrowind's `.esm` and `.esp` files, extracting all game data: world geometry, NPCs, items, quests, dialogue, scripts, and more. It supports **47 different record types** and provides fast, case-insensitive lookups.

---

## Status Audit

### ✅ Completed
- Binary ESM/ESP file parser
- 47 record type parsers (comprehensive coverage)
- Header parsing (author, description, master files)
- Exterior cell grid indexing (x,y lookups)
- Interior cell name lookups
- Deleted record handling
- Case-insensitive record IDs
- Statistics reporting (record counts)
- Progress callbacks for loading
- Master file dependency tracking

### ⚠️ In Progress
- Dialogue system integration (records parsed but not connected to Dialogue Manager plugin)
- Script compilation (records parsed but scripts not executable)
- Quest integration (records parsed but not connected to Questify plugin)

### ❌ Not Started
- ESP mod loading (framework supports it but not tested)
- Record conflict resolution (when multiple ESPs modify same record)
- Localization (Morrowind has minimal localization support)
- Savegame loading (different file format `.ess`)

---

## Architecture

### File Structure

```
Morrowind.esm (binary file)
├─ Header (TES3)
│  ├─ Version
│  ├─ File flags
│  ├─ Author
│  ├─ Description
│  └─ Master files (dependencies)
│
└─ Records (47 types)
   ├─ GMST (Game Settings)
   ├─ GLOB (Global Variables)
   ├─ CLAS (Classes)
   ├─ FACT (Factions)
   ├─ RACE (Races)
   ├─ SOUN (Sounds)
   ├─ REGN (Regions)
   ├─ BSGN (Birthsigns)
   ├─ LTEX (Land Textures)
   ├─ STAT (Statics)
   ├─ DOOR (Doors)
   ├─ MISC (Misc Items)
   ├─ WEAP (Weapons)
   ├─ CONT (Containers)
   ├─ SPEL (Spells)
   ├─ CREA (Creatures)
   ├─ BODY (Body Parts)
   ├─ LIGH (Lights)
   ├─ ENCH (Enchantments)
   ├─ NPC_ (NPCs)
   ├─ ARMO (Armor)
   ├─ CLOT (Clothing)
   ├─ REPA (Repair Items)
   ├─ ACTI (Activators)
   ├─ APPA (Apparatus)
   ├─ LOCK (Lockpicks)
   ├─ PROB (Probes)
   ├─ INGR (Ingredients)
   ├─ BOOK (Books)
   ├─ ALCH (Potions)
   ├─ LEVI (Leveled Items)
   ├─ LEVC (Leveled Creatures)
   ├─ CELL (Cells)
   ├─ LAND (Landscape)
   ├─ PGRD (Pathgrid)
   ├─ SNDG (Sound Generators)
   ├─ DIAL (Dialogue Topics)
   ├─ INFO (Dialogue Entries)
   ├─ SCPT (Scripts)
   ├─ SKIL (Skills)
   ├─ MGEF (Magic Effects)
   ├─ SSCR (Start Scripts)
   └─ ... (47 total)
```

---

## Key Files

| File | Path | Purpose |
|------|------|---------|
| **ESMManager** | [src/core/esm/esm_manager.gd](../src/core/esm/esm_manager.gd) | Autoload singleton, main API |
| **ESMReader** | [src/core/esm/esm_reader.gd](../src/core/esm/esm_reader.gd) | Binary file parser |
| **ESMDefs** | [src/core/esm/esm_defs.gd](../src/core/esm/esm_defs.gd) | Record type constants |
| **ESMHeader** | [src/core/esm/esm_header.gd](../src/core/esm/esm_header.gd) | TES3 header parser |
| **records/** | [src/core/esm/records/](../src/core/esm/records/) | 47 record type parsers |

---

## ESMManager (Autoload)

### Core API

```gdscript
# Autoload: ESMManager (globally accessible)
class_name ESMManager

# Main data dictionaries (all case-insensitive)
var statics: Dictionary = {}           # record_id -> StaticRecord
var cells: Dictionary = {}             # cell_name -> CellRecord
var exterior_cells: Dictionary = {}   # "x,y" -> CellRecord
var interior_cells: Dictionary = {}   # cell_name -> CellRecord
var lands: Dictionary = {}             # "x,y" -> LandRecord
var land_textures: Dictionary = {}    # index -> LandTextureRecord

var npcs: Dictionary = {}              # record_id -> NPCRecord
var creatures: Dictionary = {}         # record_id -> CreatureRecord
var weapons: Dictionary = {}           # record_id -> WeaponRecord
var armor: Dictionary = {}             # record_id -> ArmorRecord
var clothing: Dictionary = {}          # record_id -> ClothingRecord
var misc_items: Dictionary = {}        # record_id -> MiscItemRecord
var books: Dictionary = {}             # record_id -> BookRecord
var potions: Dictionary = {}           # record_id -> PotionRecord
var ingredients: Dictionary = {}       # record_id -> IngredientRecord

var spells: Dictionary = {}            # record_id -> SpellRecord
var enchantments: Dictionary = {}      # record_id -> EnchantmentRecord
var magic_effects: Dictionary = {}     # record_id -> MagicEffectRecord

var classes: Dictionary = {}           # record_id -> ClassRecord
var races: Dictionary = {}             # record_id -> RaceRecord
var factions: Dictionary = {}          # record_id -> FactionRecord
var birthsigns: Dictionary = {}        # record_id -> BirthsignRecord

var dialogues: Dictionary = {}         # topic -> DialogueRecord
var scripts: Dictionary = {}           # record_id -> ScriptRecord
var game_settings: Dictionary = {}     # setting_name -> GameSettingRecord
var globals: Dictionary = {}           # var_name -> GlobalRecord

var regions: Dictionary = {}           # record_id -> RegionRecord
var sounds: Dictionary = {}            # record_id -> SoundRecord
var sound_generators: Dictionary = {}  # record_id -> SoundGenRecord

var start_scripts: Array[String] = []

# Loading
func load_esm_file(path: String) -> bool:
    var reader := ESMReader.new()
    reader.progress_callback = func(progress: float):
        print("Loading ESM: %.1f%%" % (progress * 100))

    return reader.load_file(path, self)

func get_cell(x: int, y: int) -> CellRecord:
    return exterior_cells.get("%d,%d" % [x, y])

func get_land(x: int, y: int) -> LandRecord:
    return lands.get("%d,%d" % [x, y])

func get_interior_cell(name: String) -> CellRecord:
    return interior_cells.get(name.to_lower())

func print_statistics() -> void:
    print("=== ESM Statistics ===")
    print("Statics: %d" % statics.size())
    print("Cells: %d (%d exterior, %d interior)" % [
        cells.size(),
        exterior_cells.size(),
        interior_cells.size()
    ])
    print("Land: %d" % lands.size())
    print("NPCs: %d" % npcs.size())
    print("Creatures: %d" % creatures.size())
    print("Items: %d" % (weapons.size() + armor.size() + misc_items.size()))
    print("Dialogues: %d" % dialogues.size())
    print("Scripts: %d" % scripts.size())
```

---

## Binary File Parsing

### ESMReader

```gdscript
class_name ESMReader

var _file: FileAccess
var _buffer: PackedByteArray
var _pos: int = 0

func load_file(path: String, manager: ESMManager) -> bool:
    _file = FileAccess.open(path, FileAccess.READ)
    if not _file:
        push_error("Failed to open ESM: %s" % path)
        return false

    # Read entire file into buffer (faster than random access)
    _buffer = _file.get_buffer(_file.get_length())
    _file.close()

    # Parse header
    var header := _read_header()
    if not header:
        return false

    # Parse records
    while _pos < _buffer.size():
        var record := _read_record()
        if record:
            _add_record_to_manager(record, manager)

        if progress_callback and _pos % 100000 == 0:
            progress_callback.call(float(_pos) / float(_buffer.size()))

    return true

func _read_record() -> ESMRecord:
    var type := _read_string(4)  # e.g., "STAT", "NPC_", "CELL"
    var size := _read_u32()
    var header1 := _read_u32()
    var flags := _read_u32()

    var record_data := _read_bytes(size)

    # Deleted record?
    if flags & 0x00000020:
        return null  # Skip deleted records

    # Dispatch to appropriate parser
    match type:
        "STAT": return StaticRecord.parse(record_data)
        "CELL": return CellRecord.parse(record_data)
        "LAND": return LandRecord.parse(record_data)
        "NPC_": return NPCRecord.parse(record_data)
        "WEAP": return WeaponRecord.parse(record_data)
        # ... 47 total types ...

    return null  # Unknown type

func _read_string(length: int) -> String:
    var s := _buffer.slice(_pos, _pos + length).get_string_from_ascii()
    _pos += length
    return s

func _read_u32() -> int:
    var value := _buffer.decode_u32(_pos)
    _pos += 4
    return value

func _read_i32() -> int:
    var value := _buffer.decode_s32(_pos)
    _pos += 4
    return value

func _read_float() -> float:
    var value := _buffer.decode_float(_pos)
    _pos += 4
    return value

func _read_bytes(count: int) -> PackedByteArray:
    var bytes := _buffer.slice(_pos, _pos + count)
    _pos += count
    return bytes
```

---

## Record Structure

### Base Record Class

All records inherit from `ESMRecord`:

```gdscript
class_name ESMRecord

var record_id: String = ""
var flags: int = 0
var is_deleted: bool = false

static func parse(data: PackedByteArray) -> ESMRecord:
    push_error("parse() must be overridden!")
    return null
```

### Example: StaticRecord

```gdscript
class_name StaticRecord
extends ESMRecord

var model: String = ""  # NIF file path (e.g., "meshes\\f\\flora_kelp_01.nif")

static func parse(data: PackedByteArray) -> StaticRecord:
    var record := StaticRecord.new()
    var pos := 0

    while pos < data.size():
        var subrecord_type := _read_string(data, pos, 4)
        pos += 4
        var subrecord_size := data.decode_u32(pos)
        pos += 4
        var subrecord_data := data.slice(pos, pos + subrecord_size)
        pos += subrecord_size

        match subrecord_type:
            "NAME":  # Record ID
                record.record_id = subrecord_data.get_string_from_ascii()
            "MODL":  # Model file path
                record.model = subrecord_data.get_string_from_ascii()

    return record
```

### Example: CellRecord (Complex)

```gdscript
class_name CellRecord
extends ESMRecord

var name: String = ""
var region: String = ""
var grid_x: int = 0
var grid_y: int = 0
var is_interior: bool = false
var has_water: bool = false
var water_height: float = 0.0
var ambient_color: Color = Color.WHITE
var sunlight_color: Color = Color.WHITE
var fog_color: Color = Color.WHITE
var fog_density: float = 0.0

var references: Array[CellReference] = []  # Objects in cell

static func parse(data: PackedByteArray) -> CellRecord:
    var record := CellRecord.new()
    var pos := 0
    var reading_references := false

    while pos < data.size():
        var subrecord_type := _read_string(data, pos, 4)
        pos += 4
        var subrecord_size := data.decode_u32(pos)
        pos += 4
        var subrecord_data := data.slice(pos, pos + subrecord_size)
        pos += subrecord_size

        match subrecord_type:
            "NAME":
                record.name = subrecord_data.get_string_from_ascii()
                record.record_id = record.name
            "RGNN":
                record.region = subrecord_data.get_string_from_ascii()
            "DATA":
                var flags := subrecord_data.decode_u32(0)
                record.is_interior = (flags & 0x01) == 0
                record.has_water = (flags & 0x02) != 0
                record.grid_x = subrecord_data.decode_s32(4)
                record.grid_y = subrecord_data.decode_s32(8)
            "WHGT":
                record.water_height = subrecord_data.decode_float(0)
            "AMBI":  # Ambient lighting
                record.ambient_color = _read_color(subrecord_data, 0)
                record.sunlight_color = _read_color(subrecord_data, 4)
                record.fog_color = _read_color(subrecord_data, 8)
                record.fog_density = subrecord_data.decode_float(12)
            "FRMR":  # Object reference (start)
                reading_references = true
                var ref := CellReference.new()
                ref.refnum = subrecord_data.decode_u32(0)
                record.references.append(ref)
            "NAME":  # Object base ID
                if reading_references:
                    record.references[-1].base_object_id = subrecord_data.get_string_from_ascii()
            "DATA":  # Object position/rotation
                if reading_references:
                    var ref := record.references[-1]
                    ref.position = Vector3(
                        subrecord_data.decode_float(0),
                        subrecord_data.decode_float(4),
                        subrecord_data.decode_float(8)
                    )
                    ref.rotation = Vector3(
                        subrecord_data.decode_float(12),
                        subrecord_data.decode_float(16),
                        subrecord_data.decode_float(20)
                    )

    return record
```

---

## Coordinate Indexing

### Exterior Cells

Morrowind uses grid coordinates for exterior cells:

```gdscript
# Cell at (0, 0) near Seyda Neen
# Cell at (3, -2) northeast
# Cell at (-5, 10) southwest

# Indexing:
var cell_key := "%d,%d" % [x, y]
ESMManager.exterior_cells[cell_key] = cell_record

# Lookup:
var cell := ESMManager.get_cell(3, -2)
```

### Interior Cells

Interior cells use names (case-insensitive):

```gdscript
# "Arrille's Tradehouse"
# "Balmora, Council Club"
# "Vivec, Hlaalu Canton"

# Indexing (lowercase for case-insensitive):
var cell_key := cell.name.to_lower()
ESMManager.interior_cells[cell_key] = cell_record

# Lookup:
var cell := ESMManager.get_interior_cell("Arrille's Tradehouse")
```

---

## LAND Records (Terrain Data)

### Structure

```gdscript
class_name LandRecord
extends ESMRecord

var grid_x: int = 0
var grid_y: int = 0
var flags: int = 0

# Heightmap (65x65 vertices)
var height_data: PackedInt32Array = []
var base_height: int = 0

# Textures (16x16 texture indices)
var texture_indices: PackedInt32Array = []

# Vertex colors (65x65 RGB)
var vertex_colors: Array[Color] = []

# Vertex normals (65x65)
var normals: Array[Vector3] = []

# Vertex tangents (optional)
var tangents: Array[Vector3] = []

# World map data (optional)
var world_map_data: PackedByteArray = []
```

### Heightmap Encoding

Morrowind uses **delta encoding** for compression:

```gdscript
func _parse_height_data(data: PackedByteArray) -> PackedInt32Array:
    var heights := PackedInt32Array()
    heights.resize(65 * 65)

    var pos := 0
    var current_height := 0  # Accumulator

    for i in range(65 * 65):
        var delta := data.decode_s8(pos)  # Signed byte offset
        pos += 1
        current_height += delta
        heights[i] = current_height

    return heights
```

---

## Dialogue System

### DIAL + INFO Records

```gdscript
# DIAL: Dialogue topic
class_name DialogueRecord
extends ESMRecord

var topic: String = ""  # "Background", "little advice", "Orders"
var type: int = 0       # 0=Topic, 1=Voice, 2=Greeting, 3=Persuasion, 4=Journal

var infos: Array[DialogueInfoRecord] = []

# INFO: Individual dialogue entry
class_name DialogueInfoRecord
extends ESMRecord

var dialogue_id: String = ""  # Unique ID
var disposition: int = 0       # NPC disposition requirement (0-100)
var rank: int = -1            # Faction rank requirement
var sex: int = -1             # 0=Male, 1=Female, -1=Any
var pc_rank: int = -1         # Player faction rank requirement
var npc_id: String = ""       # Specific NPC (empty = any)
var race: String = ""         # Race requirement
var class_name: String = ""   # Class requirement
var faction: String = ""      # Faction requirement
var cell: String = ""         # Location requirement
var pc_faction: String = ""   # Player faction requirement

var conditions: Array[String] = []  # Script conditions

var text: String = ""         # Dialogue text
var speaker_name: String = "" # Display name override
var sound: String = ""        # Audio file
var result_script: String = "" # Script to run when chosen

# Example:
# Topic: "Background"
# NPC: Fargoth
# Conditions: Player not in Mages Guild, disposition > 30
# Text: "I'm just a simple commoner. I live here in Seyda Neen."
```

---

## Script System

### SCPT Records

```gdscript
class_name ScriptRecord
extends ESMRecord

var script_name: String = ""
var script_text: String = ""  # MWScript source code
var local_vars: Array[String] = []
var short_count: int = 0
var long_count: int = 0
var float_count: int = 0

# Example script:
"""
begin fargothRing

short OnPCDrop

if ( OnPCDrop == 1 )
    set OnPCDrop to 0
    addtopic "Fargoth's Ring"
endif

if ( menumode == 1 )
    return
endif

if ( OnPCDrop == 0 )
    if ( OnPCDropped "ring_fargoth" == 1 )
        set OnPCDrop to 1
    endif
endif

end
"""
```

**Note:** Scripts are **parsed but not compiled**. Implementing a full MWScript interpreter is a large undertaking.

---

## Data Statistics (Morrowind.esm)

Typical record counts:

```
Game Settings: 1,324
Globals: 407
Classes: 30
Factions: 46
Races: 10
Skills: 27
Magic Effects: 143
Sounds: 2,478
Dialogues: 2,836
Dialogue Infos: 46,923 (!!)
Scripts: 1,173
Regions: 37
Birthsigns: 13
Start Scripts: 12
Statics: 2,841
Doors: 109
Misc Items: 681
Weapons: 513
Armor: 563
Clothing: 325
Books: 296
Potions: 117
Ingredients: 87
Apparatus: 12
Lockpicks: 5
Probes: 5
Repair Items: 4
Containers: 84
Activators: 339
Lights: 196
Enchantments: 2,058
Spells: 1,184
Creatures: 240
NPCs: 2,834
Body Parts: 1,967
Land Textures: 1,024
Cells: 1,138 (exterior + interior)
Lands: 719 (terrain cells)
Pathgrids: 512
Sound Generators: 53
Leveled Items: 244
Leveled Creatures: 86
```

**Total:** ~100,000+ subrecords parsed!

---

## Best Practices

### 1. Always Use Case-Insensitive Lookups

Morrowind record IDs are case-insensitive:

```gdscript
# ❌ Wrong: Case-sensitive
var npc := ESMManager.npcs["fargoth"]  # Fails if stored as "Fargoth"

# ✅ Correct: Use .to_lower()
var npc := ESMManager.npcs["fargoth".to_lower()]
```

### 2. Cache Frequently Accessed Records

```gdscript
# ❌ Bad: Lookup every frame
func _process(delta):
    var static := ESMManager.statics["flora_kelp_01"]

# ✅ Good: Cache on init
@onready var _kelp_static: StaticRecord = ESMManager.statics["flora_kelp_01"]
```

### 3. Handle Missing Records Gracefully

```gdscript
var static := ESMManager.statics.get(record_id)
if not static:
    push_warning("Missing static: %s" % record_id)
    return _create_placeholder()
```

### 4. Validate Data After Parsing

```gdscript
func _validate_cell(cell: CellRecord) -> bool:
    if cell.references.size() == 0:
        push_warning("Empty cell: %s" % cell.name)

    for ref in cell.references:
        if not ESMManager.statics.has(ref.base_object_id):
            push_error("Invalid reference: %s" % ref.base_object_id)
            return false

    return true
```

---

## Common Issues

### Issue: "Record not found" Errors
**Cause:** Case-sensitive lookup
**Solution:** Always use `.to_lower()` on record IDs

### Issue: Slow ESM Loading
**Cause:** File I/O overhead
**Solution:** ESMReader loads entire file into memory (already optimized)

### Issue: Missing Dialogue
**Cause:** Dialogue conditions not evaluated
**Solution:** Implement dialogue condition checking (see Gameplay Systems doc)

---

## Future Improvements

### ⚠️ ESP Mod Loading
Load multiple ESP files with conflict resolution:

```gdscript
func load_mod(path: String) -> void:
    var reader := ESMReader.new()
    reader.load_file(path, self)
    _resolve_conflicts()  # Last-loaded wins

func _resolve_conflicts() -> void:
    # If multiple mods modify same record, use last one
    pass
```

### ⚠️ Savegame Loading
ESS files use different format:

```gdscript
func load_savegame(path: String) -> bool:
    var reader := ESSReader.new()
    return reader.load_file(path, self)
```

### ❌ Script Compilation
Implement MWScript interpreter:

```gdscript
var vm := MWScriptVM.new()
vm.compile(script.script_text)
vm.execute()
```

---

## Task Tracker

- [x] Binary file parser
- [x] 47 record type parsers
- [x] Exterior cell grid indexing
- [x] Interior cell name indexing
- [x] Case-insensitive lookups
- [x] Deleted record handling
- [x] Progress callbacks
- [x] Statistics reporting
- [ ] ESP mod loading
- [ ] Record conflict resolution
- [ ] Dialogue condition evaluation
- [ ] Script compilation/execution
- [ ] Savegame loading
- [ ] Localization support

---

**See Also:**
- [06_NIF_SYSTEM.md](06_NIF_SYSTEM.md) - 3D model conversion (references STAT records)
- [09_GAMEPLAY_SYSTEMS.md](09_GAMEPLAY_SYSTEMS.md) - Dialogue, quests, AI (uses ESM data)
- [10_DEVELOPMENT_STATUS.md](10_DEVELOPMENT_STATUS.md) - Overall roadmap
