# Godotwind

An OpenMW (Morrowind) port to Godot Engine 4.

## Overview

Godotwind loads and renders The Elder Scrolls III: Morrowind game data using the Godot engine. It reads original Morrowind data files (BSA archives, ESM databases, NIF models) and converts them to Godot's runtime format, enabling seamless exploration of Morrowind's world with modern rendering capabilities.

## Features

- **Full Morrowind Data Support**
  - BSA archive reader for game assets
  - ESM file parser for game database
  - NIF model converter with materials and textures
  - DDS/TGA texture loading

- **World Streaming**
  - Dynamic cell loading based on camera position
  - Seamless open world exploration
  - Time-budgeted loading to prevent frame hitches

- **Advanced Terrain System**
  - Terrain3D integration for heightmaps and texture splatting
  - Pre-processing tools for optimal runtime performance
  - Vertex coloring and smooth texture blending

- **Performance Optimizations**
  - Object pooling for frequently instantiated models
  - Distance-based LOD system (full detail → low detail → billboard → culled)
  - Multi-level texture caching (runtime + disk)

- **Development Tools**
  - Terrain viewer for world visualization and pre-processing
  - Cell browser for inspecting individual locations

## Quick Start

### Requirements

- Godot Engine 4.5 or later
- The Elder Scrolls III: Morrowind installation

### Setup

1. Clone this repository
2. Open the project in Godot Engine
3. Configure Morrowind data path in `Project Settings → Morrowind → Data Path`
4. Set ESM file in `Project Settings → Morrowind → Esm File` (usually `Morrowind.esm`)
5. Run the main scene

For detailed setup instructions, see [docs/setup.md](docs/setup.md).

## Documentation

- [Architecture Overview](docs/ARCHITECTURE.md) - High-level system design
- [Setup Guide](docs/setup.md) - Installation and configuration

### Features

- [File Formats](docs/features/file-formats.md) - BSA, ESM, NIF handling
- [Coordinate System](docs/features/coordinate-system.md) - Morrowind ↔ Godot conversion
- [World Management](docs/features/world-management.md) - Cells, terrain, streaming
- [Optimization](docs/features/optimization.md) - Pooling, LOD, caching
- [Development Tools](docs/features/tools.md) - Terrain viewer, cell browser

## Project Structure

```
src/
├── core/                  # Core systems
│   ├── bsa/              # BSA archive reader
│   ├── esm/              # ESM file parser
│   ├── nif/              # NIF model converter
│   ├── texture/          # Texture loader
│   ├── world/            # World management
│   ├── coordinate_system.gd
│   └── morrowind_coords.gd (deprecated)
├── tools/                # Development tools
│   ├── terrain_viewer.gd
│   ├── cell_viewer.gd
│   └── ...
└── main.gd               # Main scene
```

## License

This project is for educational and development purposes. Morrowind is owned by Bethesda Softworks.

## Third-Party Addons

This project uses several Godot addons:
- Terrain3D - Terrain rendering
- Beehave - Behavior trees
- Gloot - Inventory system
- Questify - Quest system
- And others (see addons/ directory)
