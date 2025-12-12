# World Management

World management encompasses cell loading, terrain generation, and world streaming systems that bring Morrowind's world to life in Godot.

## Cell Management

### Overview

CellManager loads cells from ESM data and instantiates all objects with proper positioning and transforms.

### Location

`src/core/world/cell_manager.gd`

### Cell Types

**Interior Cells**:
- Named locations (e.g., "Seyda Neen, Census and Excise Office")
- Self-contained spaces
- No terrain, only objects
- Load by name

**Exterior Cells**:
- Grid-based outdoor areas
- Identified by (grid_x, grid_y) coordinates
- Include both terrain and objects
- Load by grid position

### Loading Cells

```gdscript
# Load interior cell
var cell_node = CellManager.load_cell("Arrille's Tradehouse")
add_child(cell_node)

# Load exterior cell
var cell_node = CellManager.load_exterior_cell(0, -2)  # Seyda Neen
add_child(cell_node)

# Unload cell
cell_node.queue_free()
```

### Loading Process

```
1. Query ESMManager for cell data
   ↓
2. Create parent Node3D for cell
   ↓
3. For each object reference in cell:
   ├── Get object definition (STAT, CONT, DOOR, etc.)
   ├── Try to acquire from ObjectPool
   │   └── If miss: Load and convert NIF model
   ├── Convert position using CoordinateSystem
   ├── Apply transform (position, rotation, scale)
   └── Add to cell node
   ↓
4. Return cell node with all objects
```

### Object Types Supported

- **STAT** - Static objects (buildings, rocks, trees, furniture)
- **LIGH** - Light sources
- **CONT** - Containers (chests, barrels)
- **DOOR** - Doors and teleports
- **ACTI** - Activators (levers, buttons)
- **NPC_** - Non-player characters
- **CREA** - Creatures

### Statistics

```gdscript
var stats = CellManager.get_stats()
print("Objects loaded: ", stats.objects_loaded)
print("Objects failed: ", stats.objects_failed)
print("Cache hits: ", stats.cache_hits)
print("Load time: ", stats.load_time_ms, " ms")
```

## Terrain Management

### Overview

TerrainManager converts Morrowind LAND records to Terrain3D format with heightmaps, texture splatmaps, and vertex colors.

### Location

`src/core/world/terrain_manager.gd`

### Terrain Data

Morrowind LAND records contain:
- **Heights**: 65×65 grid, 128 units per step
- **Vertex Colors**: 65×65 RGB colors for lighting
- **Texture Indices**: 16×16 grid referencing LTEX records

### Generating Terrain

```gdscript
# Get terrain data for a cell
var land = ESMManager.get_land(grid_x, grid_y)

# Generate heightmap
var heightmap = TerrainManager.generate_heightmap(land)
# Returns: Image (65×65, FORMAT_RF)

# Generate control map (texture splatmap)
var control_map = TerrainManager.generate_control_map(land)
# Returns: Image (65×65, FORMAT_RGBA8)

# Generate color map (vertex colors)
var color_map = TerrainManager.generate_color_map(land)
# Returns: Image (65×65, FORMAT_RGB8)
```

### Importing to Terrain3D

```gdscript
# Import a single cell
TerrainManager.import_cell_to_terrain(terrain3d_instance, grid_x, grid_y)

# The manager handles:
# - Generating all maps (heightmap, control, color)
# - Converting to Terrain3D format
# - Updating terrain region data
```

### Control Map Format

Terrain3D uses 32-bit RGBA encoding:

```gdscript
# R channel: Base texture index (0-31)
# G channel: Overlay texture index (0-31)
# B channel: Blend amount (0-255, 0=base only, 255=overlay only)
# A channel: Hole mask (0=hole, 255=solid)
```

### Heightmap Conversion

```
Morrowind heights (65×65 in game units)
    ↓
Scale by 1/UNITS_PER_METER (convert to meters)
    ↓
Flip Y-axis (Morrowind north → Godot south)
    ↓
Store in Image (FORMAT_RF, R channel = height)
    ↓
Import to Terrain3D
```

### Pre-Processing

For best performance, pre-process terrain to disk:

```gdscript
# Use terrain_viewer tool to pre-process entire world
# Saves .res files for fast runtime loading
```

See [tools.md](tools.md) for details on terrain pre-processing.

## World Streaming

### Overview

WorldStreamingManager dynamically loads and unloads cells based on camera position, enabling seamless exploration of large worlds.

### Location

`src/core/world/world_streaming_manager.gd`

### Configuration

```gdscript
@export var view_distance: int = 2          # Cells in each direction (2 = 5×5 grid)
@export var load_budget_ms: float = 5.0     # Max ms per frame for loading
@export var update_interval: float = 0.5    # Seconds between cell checks
@export var preload_terrain: bool = true    # Use pre-processed terrain
```

### Usage

```gdscript
# Setup
var streaming_manager = WorldStreamingManager.new()
add_child(streaming_manager)

# Set camera to track
streaming_manager.set_camera(camera)

# Streaming happens automatically in _process()
```

### Streaming Algorithm

```
Every update_interval seconds:
    ↓
1. Get camera position
   ↓
2. Convert to cell grid coordinates
   ↓
3. Calculate cells in view_distance
   ↓
4. For each cell in range:
   ├── Not loaded? → Add to load queue (priority by distance)
   └── Beyond view_distance? → Add to unload queue
   ↓
5. Process load queue (respecting time budget)
   ├── Load terrain (TerrainManager)
   ├── Load objects (CellManager)
   ├── Register with ObjectLODManager
   └── Mark as loaded
   ↓
6. Process unload queue
   ├── Release objects to ObjectPool
   ├── Unregister from ObjectLODManager
   ├── Queue_free cell nodes
   └── Mark as unloaded
```

### View Distance Examples

```
view_distance = 1  →  3×3 grid  →  9 cells    (~351m × 351m)
view_distance = 2  →  5×5 grid  →  25 cells   (~585m × 585m)
view_distance = 3  →  7×7 grid  →  49 cells   (~819m × 819m)
```

### Load Budgeting

To prevent frame hitches, loading is time-budgeted:

```gdscript
# Maximum 5ms per frame by default
load_budget_ms = 5.0

# If cell loading takes longer:
# - Loading pauses until next frame
# - Ensures 60 FPS is maintained
# - Gradual streaming instead of sudden freezes
```

### Priority System

Cells are loaded in order of distance from camera:

```
1. Closest cells loaded first
2. Distant cells loaded last
3. Unloading happens after loading (low priority)
```

### Integration Example

```gdscript
# Main scene setup
extends Node3D

@onready var camera = $Camera3D
@onready var terrain = $Terrain3D
@onready var streaming_manager = $WorldStreamingManager

func _ready():
    # Configure streaming
    streaming_manager.view_distance = 2
    streaming_manager.load_budget_ms = 5.0
    streaming_manager.preload_terrain = true

    # Set camera to track
    streaming_manager.set_camera(camera)

    # Terrain reference for terrain loading
    streaming_manager.terrain = terrain

    # Done! Streaming happens automatically
```

## Advanced Topics

### Multi-Terrain Support

For very large worlds, split terrain into chunks:

```gdscript
# Each chunk: 8×8 cells (936m × 936m)
# Reduces memory usage
# Enables true infinite worlds
```

See `src/core/world/multi_terrain_manager.gd` for implementation.

### Performance Profiling

```gdscript
# src/core/world/performance_profiler.gd
# Tracks cell loading times, memory usage, frame times
```

### Static Object Rendering

```gdscript
# src/core/world/static_object_renderer.gd
# Optimized rendering for static objects
# Uses MultiMeshInstance3D for repeated models
```

## Troubleshooting

### Cells Not Loading

1. Check camera is set: `streaming_manager.set_camera(camera)`
2. Verify ESM loaded: `ESMManager.get_stats().cells > 0`
3. Check view_distance: Try increasing to 3
4. Look for errors in console output

### Terrain Not Appearing

1. Ensure LAND records exist for the cell
2. Verify Terrain3D instance is assigned
3. Check if pre-processed terrain files exist (if using preload_terrain)
4. Try loading terrain manually with `TerrainManager.import_cell_to_terrain()`

### Performance Issues

1. Reduce view_distance to 1
2. Increase load_budget_ms to spread loading over more frames
3. Pre-process terrain if not already done
4. Enable object pooling (see [optimization.md](optimization.md))
5. Adjust LOD distances to cull objects sooner

### Objects in Wrong Positions

1. Verify CoordinateSystem is being used
2. Check cell grid coordinates are correct
3. Ensure terrain and objects use same coordinate conversion
4. Test with Cell Viewer tool to isolate issue

## Summary

- **CellManager**: Loads cells and instantiates objects
- **TerrainManager**: Converts LAND records to Terrain3D
- **WorldStreamingManager**: Coordinates dynamic loading/unloading
- Together they enable seamless exploration of Morrowind's world
- Time-budgeted loading maintains smooth FPS
- Pre-processing terrain dramatically improves performance
