# Development Tools

Godotwind includes development tools for exploring Morrowind data, testing systems, and pre-processing assets.

## Terrain Viewer

### Overview

Terrain viewer is a development tool for visualizing terrain conversion and pre-processing the entire Morrowind world for optimal runtime performance.

### Location

`src/tools/terrain_viewer.tscn` and `src/tools/terrain_viewer.gd` (909 lines)

### Features

**Terrain Loading**:
- Load individual cells by coordinates
- Load radius of cells around a point
- Real-time terrain generation
- Pre-processed terrain loading

**Pre-Processing**:
- Convert entire Morrowind world to Terrain3D format
- Single terrain mode (whole world in one Terrain3D)
- Multi-terrain chunked mode (8×8 cell chunks)
- Save to disk for fast runtime loading

**Quick Teleport**:
- Buttons for common locations:
  - Seyda Neen (starting town)
  - Balmora (major city)
  - Vivec City
  - Ald'ruhn
  - Sadrith Mora
  - Molag Mar

**Object Loading**:
- Toggle object loading on/off
- Useful for testing terrain separately

**Statistics**:
- Load time tracking
- Cell count
- Performance metrics

**Fly Camera**:
- WASD movement
- Mouse look
- Ctrl to boost speed
- Free exploration of loaded areas

### Usage

#### Basic Cell Loading

```gdscript
1. Run terrain_viewer.tscn (F6)
2. Enter cell coordinates (X, Y)
3. Click "Load Cell" or "Load Range"
4. Use WASD + mouse to explore
```

#### Pre-Processing Terrain

**Why Pre-Process?**
- Real-time conversion: 5-10ms per cell
- Pre-processed loading: 1-2ms per cell
- 5× faster for smooth streaming

**How to Pre-Process**:

```gdscript
1. Run terrain_viewer.tscn
2. Click "Pre-process All Terrain"
3. Wait for completion (10-30 minutes for full world)
4. Terrain saved to disk (.res files)
5. WorldStreamingManager automatically uses pre-processed data
```

**Single vs Multi-Terrain**:

**Single Terrain Mode**:
- Entire world in one Terrain3D instance
- Simpler setup
- Higher memory usage
- Best for: Testing, small areas

**Multi-Terrain Chunked Mode**:
- World split into 8×8 cell chunks (936m × 936m each)
- Each chunk is separate .tres file
- Lower memory usage
- Enables true infinite worlds
- Best for: Production, full world exploration

#### Quick Teleport

```gdscript
# Click location button to instantly load that area
- "Seyda Neen" → Load cell (0, -2)
- "Balmora" → Load cell (-3, -2)
- "Vivec City" → Load cell (3, -9)
# Camera positioned at cell center
```

### UI Overview

```
Terrain Viewer
├── Cell Loading Section
│   ├── Grid X/Y input fields
│   ├── Load Cell button
│   ├── Load Range button (with radius slider)
│   └── Clear Terrain button
├── Pre-processing Section
│   ├── Pre-process All Terrain button
│   ├── Pre-process Chunked button
│   └── Progress bar
├── Quick Teleport Section
│   └── Location buttons
├── Options
│   ├── Load Objects checkbox
│   └── Use Pre-processed Terrain checkbox
└── Statistics Panel
    ├── Cells loaded
    ├── Load time
    └── FPS
```

### Configuration

```gdscript
# In terrain_viewer.gd
const CELL_LOAD_RADIUS = 2        # Default load radius
const CHUNK_SIZE = 8              # Cells per chunk (multi-terrain)
const FLY_SPEED = 10.0            # Camera movement speed
const FLY_SPEED_BOOST = 3.0       # Speed multiplier with Ctrl
```

### Saved Files

**Single Terrain Mode**:
```
user://terrain_storage.res         # Full world terrain data
```

**Multi-Terrain Mode**:
```
user://terrain_chunks/
├── chunk_-8_-16.tres
├── chunk_-8_-8.tres
├── chunk_0_-16.tres
├── chunk_0_-8.tres
└── ...
```

## Cell Viewer

### Overview

Cell viewer is a development tool for browsing and inspecting individual cells with detailed statistics.

### Location

`src/tools/cell_viewer.tscn` and `src/tools/cell_viewer.gd` (467 lines)

### Features

**Cell Browser**:
- Searchable list of all cells
- Filter by type (interior/exterior/all)
- Shows reference count for each cell
- Click to load

**Cell Inspection**:
- View all objects in a cell
- Detailed load statistics
- Object success/failure tracking

**Statistics Display**:
- References in ESM (total objects defined)
- Objects loaded successfully
- Objects failed to load
- Models loaded (first-time conversions)
- Models from cache (reused)
- Load time in milliseconds

**Quick Load Buttons**:
- Common test locations
- Interior and exterior examples

**Fly Camera**:
- Explore loaded cells
- Inspect object placement

### Usage

#### Browsing Cells

```gdscript
1. Run cell_viewer.tscn (F6)
2. Wait for cell list to populate (~2 seconds)
3. Use search box to filter cells
   - Type "Seyda Neen" to find Seyda Neen locations
   - Type "Balmora" for Balmora cells
4. Click cell to load
5. Explore with WASD + mouse
```

#### Filtering

```
Filter Buttons:
- "Interior" → Show only interior cells (named locations)
- "Exterior" → Show only exterior cells (grid coordinates)
- "All" → Show all cells
```

#### Statistics Interpretation

```
Cell: Seyda Neen, Arrille's Tradehouse
─────────────────────────────────────
References in ESM: 247        # Objects defined in ESM file
Objects loaded: 242           # Successfully created in scene
Objects failed: 5             # Failed to load (missing models, errors)
Models loaded: 198            # First-time NIF conversions
Models from cache: 44         # Reused cached models
Load time: 1523 ms            # Total loading duration
```

**Analysis**:
- 5 objects failed → Check console for errors (may be missing NIFs)
- 44 cache hits → 18% cache hit rate (good for first load)
- 1523ms → Reasonable for interior cell with 247 objects

#### Quick Load Buttons

```gdscript
Interior Cells:
- "Census and Excise Office" → Tutorial location
- "Arrille's Tradehouse" → Shop example
- "Caius Cosades' House" → Quest location

Exterior Cells:
- "Seyda Neen (0, -2)" → Starting area
- "Balmora (-3, -2)" → Major city
- "Vivec (3, -9)" → Large city
```

### UI Overview

```
Cell Viewer
├── Header
│   └── Title + cell count
├── Search & Filters
│   ├── Search box (filter by name)
│   └── Filter buttons (Interior/Exterior/All)
├── Cell List
│   ├── Scrollable list of cells
│   ├── Cell names (or "Exterior (X, Y)")
│   └── Reference counts "(123)"
├── Statistics Panel
│   ├── Cell name
│   ├── References in ESM
│   ├── Objects loaded/failed
│   ├── Models loaded/cached
│   └── Load time
└── Quick Load Section
    └── Common location buttons
```

### Debugging with Cell Viewer

**Use Case: Verify Coordinate Conversion**

```gdscript
1. Load a known cell (e.g., "Seyda Neen, Census and Excise Office")
2. Check if objects appear in correct positions
3. If objects are misplaced:
   - Check CoordinateSystem conversion
   - Verify cell origin is correct
   - Look for rotation issues
```

**Use Case: Test NIF Conversion**

```gdscript
1. Load a cell with specific objects
2. Check statistics for failed objects
3. Look at console output for NIF errors
4. Use failed model paths to debug NIFConverter
```

**Use Case: Measure Performance**

```gdscript
1. Load various cell types
2. Compare load times:
   - Small interior: 200-500ms
   - Large interior: 1000-2000ms
   - Exterior: 800-1500ms (without optimizations)
3. Identify performance bottlenecks
4. Test optimization impact
```

## Other Tools

### NIF Viewer

**Location**: `src/tools/nif_viewer.gd`

Simple tool for testing NIF model loading in isolation:

```gdscript
# Load and view a single NIF file
# Useful for debugging model conversion issues
# Test materials, textures, transforms
```

### Streaming Demo

**Location**: `src/tools/streaming_demo.gd`

Demonstrates WorldStreamingManager in action:

```gdscript
# Full world streaming setup
# Player movement
# Real-time cell loading/unloading
# Performance monitoring
```

### Terrain Pre-processor

**Location**: `src/tools/terrain_preprocessor.gd`

Standalone terrain pre-processing script:

```gdscript
# Command-line style terrain processing
# Batch conversion
# Progress tracking
```

## Tool Development Tips

### Creating New Tools

```gdscript
# Tools should extend Node and live in src/tools/
extends Node

func _ready():
    # Load ESM/BSA if needed
    if not ESMManager.is_loaded():
        ESMManager.load_file(morrowind_esm_path)

    if BSAManager.get_archive_count() == 0:
        BSAManager.load_archives_from_directory(morrowind_data_path)

    # Setup your tool UI/logic
    setup_tool()
```

### Best Practices

1. **Make tools scene-based**: `.tscn` files are easier to iterate on
2. **Include UI**: Control panels for parameters
3. **Show statistics**: Help developers understand what's happening
4. **Add fly camera**: Essential for 3D exploration
5. **Handle errors gracefully**: Check if ESM loaded, BSA available, etc.
6. **Profile performance**: Track and display timing information

### Fly Camera Pattern

```gdscript
# Common pattern used in terrain_viewer and cell_viewer
var fly_speed = 10.0
var mouse_sensitivity = 0.1

func _process(delta):
    # WASD movement
    var input = Input.get_vector("left", "right", "forward", "back")
    var movement = Vector3(input.x, 0, input.y) * fly_speed * delta

    # Q/E for up/down
    if Input.is_key_pressed(KEY_Q):
        movement.y -= fly_speed * delta
    if Input.is_key_pressed(KEY_E):
        movement.y += fly_speed * delta

    # Ctrl to boost speed
    if Input.is_key_pressed(KEY_CTRL):
        movement *= 3.0

    camera.position += camera.transform.basis * movement

func _input(event):
    if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
        # Mouse look
        rotate_y(-event.relative.x * mouse_sensitivity * 0.01)
        camera.rotate_x(-event.relative.y * mouse_sensitivity * 0.01)
```

## Summary

- **Terrain Viewer**: Pre-process terrain, visualize world, quick teleport
- **Cell Viewer**: Browse cells, inspect objects, debugging statistics
- Both tools essential for development and testing
- Use terrain viewer to pre-process before deployment
- Use cell viewer to debug specific cell issues
- Tools demonstrate proper usage of core systems
