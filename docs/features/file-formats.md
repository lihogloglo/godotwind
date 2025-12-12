# File Format Handlers

Godotwind reads three primary Morrowind file formats: BSA (archives), ESM (database), and NIF (3D models).

## BSA Archive System

### Overview

BSA (Bethesda Softworks Archive) files contain compressed game assets like meshes, textures, and sounds.

### Location

- `src/core/bsa/bsa_manager.gd` - High-level archive management (Singleton)
- `src/core/bsa/bsa_reader.gd` - Low-level BSA parsing
- `src/core/bsa/bsa_defs.gd` - Format constants

### File Structure

```
BSA File:
├── Header (12 bytes)
│   ├── Version (0x100)
│   ├── Hash offset
│   └── File count
├── File Records (size, offset, flags)
├── Name Offsets
├── File Names
└── File Data (optionally compressed)
```

### Usage

```gdscript
# Singleton - loads automatically from data_path
BSAManager.load_archives_from_directory(morrowind_data_path)

# Retrieve a file from any loaded archive
var texture_data = BSAManager.get_file("textures/tx_rock_01.dds")

# Check if file exists
if BSAManager.has_file("meshes/f/flora_tree_01.nif"):
    var nif_data = BSAManager.get_file("meshes/f/flora_tree_01.nif")
```

### Features

- Case-insensitive path lookup
- Path separator normalization (\ and / both work)
- Hash-based fast file lookup
- Automatic decompression
- Multi-archive support (searches all loaded archives)

### Performance

- File lookup: O(log n) via hash table
- Decompression: On-demand (only when file is accessed)
- Memory: Archives kept open, data loaded as needed

## ESM File System

### Overview

ESM (Elder Scrolls Master) files contain the game database: cells, objects, terrain, NPCs, items, and all game data.

### Location

- `src/core/esm/esm_manager.gd` - Data manager (Singleton)
- `src/core/esm/esm_reader.gd` - Binary parser
- `src/core/esm/esm_header.gd` - Header structure
- `src/core/esm/records/*.gd` - Record type definitions

### Record Types

**CELL** - Interior/exterior cell definitions
- Cell metadata (name, region, flags)
- Water level, ambient lighting, fog
- Object references (position, rotation, scale, model ID)

**LAND** - Terrain heightmaps
- 65×65 heightmap grid
- 65×65 vertex colors
- 16×16 texture indices

**STAT** - Static object definitions
- Model path (NIF reference)

**LTEX** - Landscape texture definitions
- Texture path for terrain splatting

**NPC_** - Non-player character data
**CREA** - Creature data
**CONT** - Container definitions
**DOOR** - Door definitions
**LIGH** - Light definitions
**ACTI** - Activator definitions

And many more (weapons, armor, spells, dialogues, etc.)

### Usage

```gdscript
# Singleton - loads on startup
ESMManager.load_file("res://path/to/Morrowind.esm")

# Get interior cell
var cell = ESMManager.get_cell("Seyda Neen, Census and Excise Office")

# Get exterior cell by grid coordinates
var cell = ESMManager.get_exterior_cell(0, -2)  # Seyda Neen area

# Get terrain data
var land = ESMManager.get_land(0, -2)
var height = land.get_height(32, 32)  # Center of cell
var color = land.get_color(32, 32)
var texture_idx = land.get_texture_index(8, 8)

# Get static object definition
var static = ESMManager.get_static("ex_common_door_01")
var model_path = static.model  # "meshes/x/ex_common_door_01.nif"

# Query statistics
var stats = ESMManager.get_stats()
print("Cells: ", stats.cells)
print("Statics: ", stats.statics)
print("NPCs: ", stats.npcs)
```

### Cell Coordinates

- Exterior cells use grid coordinates (x, y)
- Each cell is 8192 Morrowind units (~117m in Godot)
- Origin (0, 0) is near Seyda Neen
- Positive X = East, Positive Y = North

### Performance

- ESM loaded once at startup
- All records cached in dictionaries
- Lookups: O(1) by ID, O(1) by grid coordinates
- Memory: ~50-150MB for Morrowind.esm

## NIF 3D Model System

### Overview

NIF (NetImmerse File) format stores 3D models with geometry, materials, and textures.

### Location

- `src/core/nif/nif_converter.gd` - NIF to Godot conversion
- `src/core/nif/nif_reader.gd` - Binary NIF parser
- `src/core/nif/nif_collision_builder.gd` - Collision generation

### NIF Block Structure

```
NIF File:
├── NiNode (transform node)
│   ├── Transform matrix
│   └── Children (other nodes/shapes)
├── NiTriShape (mesh geometry)
│   ├── Vertex positions
│   ├── Normals
│   ├── UV coordinates
│   └── Triangle indices
├── NiTexturingProperty
│   └── Base texture path
└── NiMaterialProperty
    ├── Ambient/diffuse/specular colors
    └── Shininess
```

### Usage

```gdscript
# Convert NIF to Godot scene
var model = NIFConverter.convert_nif("meshes/f/flora_tree_01.nif")
add_child(model)

# Load from BSA and convert
var model = NIFConverter.load_and_convert("meshes/x/ex_common_door_01.nif")

# Models are automatically cached
# Second call returns cached instance
var model2 = NIFConverter.load_and_convert("meshes/x/ex_common_door_01.nif")  # Fast!
```

### Conversion Process

```
NIF file
    ↓
NIFReader.read_nif() → Parse binary format
    ↓
Extract blocks:
    ├── Scene graph (NiNode hierarchy)
    ├── Geometry (NiTriShape → vertices, normals, UVs, indices)
    ├── Materials (NiMaterialProperty → colors, shininess)
    └── Textures (NiTexturingProperty → paths)
    ↓
NIFConverter.convert_nif() → Build Godot scene
    ├── Create Node3D hierarchy
    ├── Create MeshInstance3D for each NiTriShape
    ├── Create ArrayMesh from vertex data
    ├── Create StandardMaterial3D
    ├── Load textures via TextureLoader
    └── Apply transforms
    ↓
Return Node3D (ready to add to scene tree)
```

### Material Handling

- Each NiTriShape becomes a MeshInstance3D
- Materials created as StandardMaterial3D
- Properties applied:
  - Albedo color (diffuse color)
  - Albedo texture (base texture)
  - Metallic/roughness (derived from specular/shininess)
  - Transparency (if alpha properties present)

### Caching

NIFConverter maintains a cache of converted models:
- Key: NIF file path
- Value: Converted Node3D scene
- Cache hit = instant duplicate() instead of re-parsing
- Critical for performance (common models used 100+ times)

### Collision

For physics objects, use `NIFCollisionBuilder`:

```gdscript
var collision = NIFCollisionBuilder.build_collision(nif_data)
# Returns StaticBody3D with appropriate collision shapes
```

Supports:
- Sphere collision (RootCollisionNode with bounding sphere)
- Box collision (bounding box)
- Mesh collision (triangle mesh from geometry)

### Limitations

- Skeletal animation not yet supported
- Particle systems not converted
- Some advanced material properties ignored
- Assumes static meshes

## Texture Loading

### Overview

Loads DDS and TGA textures from BSA or filesystem.

### Location

- `src/core/texture/texture_loader.gd`

### Usage

```gdscript
var texture = TextureLoader.load_texture("textures/tx_rock_01.dds")
material.albedo_texture = texture
```

### Caching

Two-level cache:

**Runtime Cache**:
- In-memory dictionary of loaded textures
- Fast lookups for already-loaded textures
- Cleared with `TextureLoader.clear_cache()`

**Disk Cache**:
- Converted textures saved to `.godot/imported/`
- Persistent across runs
- Dramatically improves second-run load times

### Pipeline

```
Request texture "textures/tx_rock_01.dds"
    ↓
Check runtime cache → Hit? Return immediately
    ↓
Check disk cache → Hit? Load and cache in runtime
    ↓
Load from BSA or filesystem
    ↓
Convert DDS → Godot Image format
    ↓
Save to disk cache
    ↓
Create ImageTexture
    ↓
Store in runtime cache
    ↓
Return texture
```

### Performance

- First load: 5-20ms (depends on size and compression)
- Runtime cache hit: <0.1ms
- Disk cache hit: 1-3ms
- Typical cell with 50 unique textures: ~50ms first load, ~5ms subsequent

## Integration Example

Complete workflow from file to scene:

```gdscript
# 1. Load archives
BSAManager.load_archives_from_directory(morrowind_data_path)

# 2. Load ESM database
ESMManager.load_file(esm_path)

# 3. Get a cell
var cell = ESMManager.get_exterior_cell(0, -2)

# 4. Instantiate objects
for ref in cell.references:
    var static = ESMManager.get_static(ref.object_id)
    if static:
        # 5. Load and convert NIF (uses BSAManager internally)
        var model = NIFConverter.load_and_convert(static.model)

        # 6. Apply transform
        model.position = CoordinateSystem.mw_to_godot(ref.position)
        model.rotation = ref.rotation
        model.scale = ref.scale

        # 7. Add to scene
        add_child(model)
```

## Summary

- **BSA**: Virtual file system for game assets
- **ESM**: Database of all game data and definitions
- **NIF**: 3D models with materials and textures
- All three formats work together to recreate Morrowind's world in Godot
