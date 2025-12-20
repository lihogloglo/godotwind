# Godotwind - Project Overview

## What Is This?

A modern open-world framework for Godot 4.5+ using Morrowind as a reference implementation. Not a faithful recreation (that's OpenMW) - this is a next-gen framework that happens to use Morrowind assets.

## What Works

- **Continuous world streaming** - No loading screens, time-budgeted async loading
- **Terrain rendering** - Terrain3D integration, unlimited world size
- **Object streaming** - NIFs converted on-the-fly, object pooling
- **Full ESM parsing** - 47 record types, all game data accessible
- **Performance** - 60 FPS with 500m+ view distance

## What Doesn't Work Yet

- Combat, magic, AI, dialogue, quests, inventory
- Weather and day/night cycle (Sky3D ready)
- Water rendering (OceanManager exists, not integrated)

## Quick Start

1. Set Morrowind data path in `project.godot` or via Settings Tool
2. Open `scenes/world_explorer.tscn`
3. Run - terrain and objects stream around the fly camera

**Controls:**
- ZQSD/WASD - Move
- Mouse - Look (Right-click to capture)
- Shift/Space - Down/Up
- Ctrl - Speed boost
- P - Toggle player/fly camera
- TAB - Switch to Interior mode
- F3 - Stats overlay

## Project Structure

```
src/core/
├── bsa/        # BSA archive reading
├── esm/        # ESM/ESP parsing (47 record types)
├── nif/        # NIF model conversion
├── texture/    # DDS/TGA loading
├── streaming/  # Async background processing
├── water/      # Ocean system (framework ready)
├── deformation/# RTT deformation system
├── player/     # Fly camera + FPS controller
├── console/    # Developer console
└── world/      # Streaming, terrain, cells

src/tools/
├── world_explorer.gd    # Main Morrowind demo
├── lapalma_explorer.gd  # La Palma terrain demo
├── nif_viewer.gd        # Model browser
└── settings_tool.gd     # Config utility
```

## Key Systems

| System | Entry Point |
|--------|-------------|
| World Streaming | `world_streaming_manager.gd` |
| Terrain | `terrain_manager.gd`, `generic_terrain_streamer.gd` |
| Cells/Objects | `cell_manager.gd` |
| NIF Models | `nif_converter.gd` |
| ESM Data | `esm_manager.gd` (autoload) |
| BSA Archives | `bsa_manager.gd` (autoload) |
| Async Work | `background_processor.gd` |

## Documentation

| Doc | Content |
|-----|---------|
| [STATUS.md](STATUS.md) | What's implemented, what's not |
| [TODO.md](TODO.md) | Prioritized next steps |
| [STREAMING.md](STREAMING.md) | World streaming architecture |
| [05_ESM_SYSTEM.md](05_ESM_SYSTEM.md) | ESM/ESP file parsing |
| [06_NIF_SYSTEM.md](06_NIF_SYSTEM.md) | NIF model conversion |
| [07_ASSET_MANAGEMENT.md](07_ASSET_MANAGEMENT.md) | BSA, textures, materials |

## Design Philosophy

- **Morrowind as test case** - Use its complex data to stress-test the framework
- **Modern techniques** - Seamless streaming, no loading screens, async everything
- **Iterate fast** - Get things working, polish later
- **Framework first** - Build reusable systems, not just a Morrowind port
