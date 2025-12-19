# Godotwind

OpenMW port to Godot Engine - Exploring the world of Morrowind in Godot 4.

## Quick Start

1. **Configure Morrowind Data Path**
   - Run the Settings Tool: `scenes/settings_tool.tscn`
   - Click "Auto-Detect" or browse to your Morrowind installation
   - See [SETTINGS.md](SETTINGS.md) for detailed configuration options

2. **Run the Project**
   - Main scene: `scenes/world_explorer.tscn`
   - The World Explorer will launch automatically

## Tools

Godotwind provides two main tools for exploring Morrowind content:

### 1. World Explorer (`scenes/world_explorer.tscn`)

The primary tool for navigating the Morrowind world. Features both world exploration and interior cell viewing.

**World Mode (Default)**
- Infinite terrain streaming with multi-region support
- Automatic object loading (statics, lights, NPCs, creatures)
- Free-fly camera navigation
- LOD system for performance
- Performance profiling and monitoring

**Interior Mode (Press TAB)**
- Browse all interior and exterior cells
- Search by cell name
- Filter by interior/exterior type
- Double-click to load and explore any cell

**Controls:**
- `Right Mouse` - Capture/release mouse for camera control
- `ZQSD` - Move camera (AZERTY layout)
- `Space/Shift` - Move up/down
- `Ctrl` - Speed boost
- `TAB` - Toggle between World and Interior modes
- `F3` - Toggle performance overlay
- `F4` - Dump detailed profiling report
- `+/-` - Adjust view distance

### 2. NIF Viewer (`scenes/nif_viewer.tscn`)

Tool for viewing individual 3D models and assets from BSA archives.

**Features:**
- Browse all NIF models in BSA archives
- Category filtering (flora, architecture, furniture, etc.)
- Search by model name
- Animation playback
- Collision shape visualization
- Orbit camera with auto-rotate

**Controls:**
- `Left Mouse Drag` - Orbit camera
- `Right Mouse Drag` - Alternative orbit
- `Middle Mouse Drag` - Pan camera
- `Mouse Wheel` - Zoom in/out
- `C` - Toggle collision visualization

## Project Structure

```
godotwind/
├── scenes/              # Main tool scenes
│   ├── world_explorer.tscn   # World exploration tool
│   ├── nif_viewer.tscn        # Model viewer
│   └── settings_tool.tscn     # Settings configuration
├── src/
│   ├── core/           # Core systems
│   │   ├── esm/       # ESM file reading
│   │   ├── bsa/       # BSA archive handling
│   │   ├── nif/       # NIF model loading
│   │   ├── world/     # World streaming, terrain, cells
│   │   └── settings_manager.gd
│   └── tools/          # Tool scripts
│       ├── world_explorer.gd
│       ├── nif_viewer.gd
│       └── settings_tool.gd
└── tests/              # Integration tests
```

## Configuration

See [SETTINGS.md](SETTINGS.md) for detailed configuration options.

**Priority order:**
1. Environment variable: `MORROWIND_DATA_PATH`
2. User config: `user://settings.cfg`
3. Project settings: `project.godot`

## Features

- ✅ ESM file parsing (complete)
- ✅ BSA archive extraction
- ✅ NIF model loading with animations
- ✅ Terrain generation with Terrain3D
- ✅ Infinite terrain streaming
- ✅ Multi-region terrain support
- ✅ Object streaming (statics, lights, containers, etc.)
- ✅ NPCs and creatures
- ✅ Interior cell viewing
- ✅ LOD system
- ✅ Object pooling for performance
- ✅ Texture loading
- ⏳ Collision (basic support)
- ⏳ Character controller
- ⏳ Game mechanics

## Development

Built with:
- Godot 4.5
- Terrain3D addon for terrain rendering
- Custom ESM/BSA readers
- Custom NIF importer

## License

See LICENSE file for details.

## Recent Changes

**v2.0 - Simplification Update**
- Consolidated into 2 main tools (World Explorer, NIF Viewer)
- Added interior cell browsing to World Explorer
- Removed redundant tools (cell_viewer, terrain_viewer, main)
- Improved project structure and clarity
- See [SIMPLIFICATION_AUDIT.md](SIMPLIFICATION_AUDIT.md) for details
