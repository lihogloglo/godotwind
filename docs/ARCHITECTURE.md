# Architecture Overview

## System Layers

Godotwind follows a layered architecture that cleanly separates concerns:

```
┌─────────────────────────────────────────┐
│        Tools Layer                      │
│  (terrain_viewer, cell_viewer)          │
└─────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────┐
│    World Management Layer               │
│  (WorldStreamingManager, CellManager,   │
│   TerrainManager, ObjectPool, LOD)      │
└─────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────┐
│     Conversion Layer                    │
│  (CoordinateSystem, NIFConverter,       │
│   TextureLoader)                        │
└─────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────┐
│    File Format Layer                    │
│  (BSA, ESM, NIF Readers)                │
└─────────────────────────────────────────┘
```

## Core Components

### File Format Layer

**Purpose**: Read and parse Morrowind's proprietary file formats

- **BSAManager** (`src/core/bsa/`) - Bethesda archive reader
  - Loads compressed game assets
  - Provides virtual file system interface
  - Handles multiple archive files

- **ESMManager** (`src/core/esm/`) - Elder Scrolls Master file parser
  - Parses game database (cells, objects, terrain, NPCs, items)
  - Singleton providing record lookup by ID or coordinates
  - Loads CELL, LAND, STAT, NPC, and other record types

- **NIFReader** (`src/core/nif/`) - NetImmerse file reader
  - Parses 3D model binary format
  - Extracts vertex data, normals, UVs, materials

### Conversion Layer

**Purpose**: Transform Morrowind data into Godot-compatible formats

- **CoordinateSystem** (`src/core/coordinate_system.gd`)
  - Converts Morrowind's Z-up coordinates to Godot's Y-up
  - Handles scaling and cell grid positioning
  - Used by all spatial systems

- **NIFConverter** (`src/core/nif/nif_converter.gd`)
  - Converts NIF models to MeshInstance3D nodes
  - Applies materials and textures
  - Caches converted models for reuse

- **TextureLoader** (`src/core/texture/texture_loader.gd`)
  - Loads DDS/TGA textures from BSA
  - Two-level caching (runtime + disk)
  - Converts to Godot ImageTexture format

### World Management Layer

**Purpose**: Manage runtime world state and streaming

- **WorldStreamingManager** (`src/core/world/world_streaming_manager.gd`)
  - Tracks camera position
  - Loads/unloads cells based on view distance
  - Time-budgeted loading (5ms per frame)
  - Coordinates all world systems

- **CellManager** (`src/core/world/cell_manager.gd`)
  - Loads cells from ESM data
  - Instantiates all objects with proper transforms
  - Handles interior and exterior cells

- **TerrainManager** (`src/core/world/terrain_manager.gd`)
  - Converts Morrowind LAND records to Terrain3D format
  - Generates heightmaps, control maps, color maps
  - Supports pre-processing for performance

- **ObjectPool** (`src/core/world/object_pool.gd`)
  - Reuses Node3D instances for common models
  - Reduces allocation overhead
  - Dramatically improves load times

- **ObjectLODManager** (`src/core/world/object_lod_manager.gd`)
  - Distance-based detail levels
  - Four LOD stages: full → low → billboard → culled
  - Maintains 60 FPS with thousands of objects

### Tools Layer

**Purpose**: Development and testing utilities

- **Terrain Viewer** (`src/tools/terrain_viewer.gd`)
  - Visualizes terrain conversion
  - Pre-processes entire world to disk
  - Quick teleport to locations

- **Cell Viewer** (`src/tools/cell_viewer.gd`)
  - Browses all cells in ESM
  - Inspects individual cell contents
  - Statistics and debugging info

## Data Flow

### Loading an Exterior Cell

```
User moves to new area
    ↓
WorldStreamingManager detects new cell (3, -2)
    ↓
    ├─→ TerrainManager.import_cell_to_terrain()
    │       ├─→ ESMManager.get_land(3, -2)
    │       ├─→ Generate heightmap/control/color maps
    │       └─→ Import to Terrain3D instance
    │
    └─→ CellManager.load_exterior_cell(3, -2)
            ├─→ ESMManager.get_exterior_cell(3, -2)
            ├─→ For each object:
            │       ├─→ ObjectPool.acquire(model_path)
            │       │       └─→ NIFConverter.load_and_convert()
            │       │               ├─→ BSAManager.get_file()
            │       │               ├─→ NIFReader.read_nif()
            │       │               └─→ TextureLoader.load_texture()
            │       ├─→ CoordinateSystem.mw_to_godot()
            │       └─→ Apply transform, add to scene
            └─→ ObjectLODManager.register_cell_objects()
```

## System Dependencies

```
WorldStreamingManager
    ├── CellManager
    ├── TerrainManager
    ├── ObjectPool
    └── ObjectLODManager

CellManager
    ├── ESMManager
    ├── NIFConverter
    ├── CoordinateSystem
    └── ObjectPool

TerrainManager
    ├── ESMManager
    └── CoordinateSystem

NIFConverter
    ├── NIFReader
    ├── TextureLoader
    └── BSAManager

TextureLoader
    └── BSAManager

ESMManager
    └── ESMReader

BSAManager
    └── BSAReader
```

## Design Principles

### Separation of Concerns

Each system has a single, well-defined responsibility. File readers don't know about Godot's scene tree; world managers don't know about file formats.

### Caching and Reuse

Three levels of caching:
1. **Object pooling** - Reuse Node3D instances
2. **Model caching** - NIFConverter caches converted models
3. **Texture caching** - Runtime + disk caching for textures

### Performance-First Design

- Time-budgeted loading prevents frame hitches
- LOD system maintains performance at scale
- Pre-processing moves expensive work offline
- Pooling reduces allocation overhead

### Modular Architecture

Systems communicate through well-defined interfaces. This enables:
- Easy testing of individual components
- Future swapping of implementations (e.g., different terrain backends)
- Clear mental model of system boundaries

## Performance Characteristics

### Cell Loading (typical exterior cell)

- **Without optimizations**: 800-1500ms
- **With all optimizations**: 150-300ms

### Memory Usage

- Per cell (with pooling): ~3MB
- Terrain (pre-processed): ~2MB per cell
- Total for 5x5 view: ~125MB

### Recommended Settings

- View distance: 2 cells (5x5 grid = ~585m × 585m)
- Load budget: 5ms per frame
- Object pool size: 50-100 per common model
- LOD distances: 50m / 150m / 500m
