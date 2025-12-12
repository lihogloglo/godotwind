# Setup Guide

## Requirements

### Software

- Godot Engine 4.5 or later
- The Elder Scrolls III: Morrowind (required for game data files)

### Hardware

- GPU with Vulkan support (for Forward+ rendering)
- 8GB RAM minimum, 16GB recommended
- SSD recommended for faster asset loading

## Installation

### 1. Clone the Repository

```bash
git clone <repository-url>
cd godotwind
```

### 2. Open in Godot

1. Launch Godot Engine
2. Click "Import" on the project manager
3. Browse to the `godotwind` directory
4. Select `project.godot`
5. Click "Import & Edit"

### 3. Configure Morrowind Data Path

The project needs to know where your Morrowind installation is located.

#### Option A: Via Project Settings (Recommended)

1. Open `Project → Project Settings`
2. Navigate to `Morrowind` section
3. Set `Data Path` to your Morrowind data files directory
   - Windows (Steam): `C:/Program Files (x86)/Steam/steamapps/common/Morrowind/Data Files`
   - Windows (GOG): `C:/GOG Games/Morrowind/Data Files`
4. Set `Esm File` to `Morrowind.esm`

#### Option B: Edit project.godot Directly

Open `project.godot` in a text editor and modify:

```ini
[morrowind]

data_path="C:/Program Files (x86)/Steam/steamapps/common/Morrowind/Data Files"
esm_file="Morrowind.esm"
```

### 4. Verify Setup

Run the main scene. You should see a UI for loading Morrowind data. If the path is correct, you'll be able to browse and load cells.

## Pre-Processing Terrain (Recommended)

For optimal performance, pre-process the terrain data:

### 1. Open Terrain Viewer

1. Navigate to `src/tools/terrain_viewer.tscn`
2. Run the scene (F6)

### 2. Pre-process All Terrain

1. Click "Pre-process All Terrain" button
2. Wait for processing to complete (may take 10-30 minutes)
3. Terrain data will be saved to disk for fast runtime loading

### 3. Enable Pre-processed Mode

In your world streaming setup, ensure `preload_terrain` is enabled to use the pre-processed data.

## Configuration Options

### Project Settings → Morrowind

- `data_path` - Path to Morrowind Data Files directory
- `esm_file` - ESM file to load (usually `Morrowind.esm`)

### WorldStreamingManager

Located in your main scene configuration:

- `view_distance` - Number of cells to load in each direction (default: 2)
- `load_budget_ms` - Max milliseconds per frame for loading (default: 5)
- `update_interval` - How often to check for new cells in seconds (default: 0.5)
- `preload_terrain` - Use pre-processed terrain vs real-time generation

### ObjectPool

- `pool_size` - Initial instances to create per model type
- `max_pool_size` - Maximum instances allowed per model type

### ObjectLODManager

- `DISTANCE_FULL` - Full detail distance in meters (default: 50)
- `DISTANCE_LOW` - Low detail distance (default: 150)
- `DISTANCE_BILLBOARD` - Billboard distance (default: 500)
- Beyond billboard distance: objects are culled

## Troubleshooting

### "File not found" errors

- Verify `data_path` points to the correct directory containing .esm and .bsa files
- Ensure you have read permissions for the Morrowind directory
- Check that BSA files are present: `Morrowind.bsa`, `Tribunal.bsa`, `Bloodmoon.bsa`

### Low FPS / Performance Issues

- Pre-process terrain if you haven't already
- Reduce `view_distance` to 1 (3x3 cell grid instead of 5x5)
- Increase LOD distances to cull objects sooner
- Enable object pooling for common models
- Check GPU is being used (not software rendering)

### Terrain not loading

- Ensure ESM file loaded successfully (check console output)
- Verify LAND records exist for the cell you're trying to load
- Try pre-processing terrain first
- Check Terrain3D plugin is enabled

### Models not appearing

- Verify BSA archives loaded successfully
- Check console for NIF conversion errors
- Some models may be corrupted or unsupported
- Use Cell Viewer tool to inspect individual cells and debug

## Development Tools

### Terrain Viewer (`src/tools/terrain_viewer.tscn`)

Use this tool to:
- Visualize terrain conversion
- Pre-process entire world
- Test different cells
- Quick teleport to locations

### Cell Viewer (`src/tools/cell_viewer.tscn`)

Use this tool to:
- Browse all cells in the ESM
- Inspect object counts and load times
- Debug specific cells
- View statistics

## Next Steps

Once setup is complete:

1. Read [ARCHITECTURE.md](ARCHITECTURE.md) to understand the system design
2. Explore [features/](features/) documentation for in-depth component guides
3. Use the development tools to explore Morrowind's data
4. Start building your own scenes and gameplay systems
