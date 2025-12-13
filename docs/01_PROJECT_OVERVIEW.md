# Godotwind Project Overview

## Vision

**Godotwind** is a next-generation open-world game framework for Godot Engine 4.5+ designed for creating large-scale RPG and simulation games. While it includes a functional port of *The Elder Scrolls III: Morrowind*, the primary goal is to create a **cutting-edge, reusable framework** that leverages modern rendering, streaming, and optimization techniques.

### Core Philosophy

> "The Morrowind port is not central and the first priority should always be the next-gen goal, than porting the Morrowind mechanics."

The framework should **modernize** old-school RPG concepts:
- ❌ Interior/exterior separation → ✅ Continuous seamless worlds
- ❌ Single water plane at fixed altitude → ✅ Multiple water bodies with different physics (ocean simulation, pond ripples, rivers)
- ❌ Cell-based teleportation → ✅ Smooth streaming with no loading screens
- ❌ Static lighting → ✅ Dynamic day/night cycles with atmospheric scattering
- ❌ Fixed LOD → ✅ Adaptive LOD with billboards and RenderingServer optimization

---

## Project Status: ~60% Complete

**Engine:** Godot 4.5 (Forward Plus)
**Language:** GDScript (100%)
**Lines of Code:** ~19,127 (core systems)
**Architecture:** Modular, data-driven, streaming-optimized

---

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    PLAYER CONTROLLER                        │
│                   (Camera / Input)                          │
└────────────────────────┬────────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────────┐
│            WORLD STREAMING MANAGER                          │
│  (Unified coordinator for terrain + objects)                │
└─────┬──────────────┬──────────────┬──────────────┬──────────┘
      │              │              │              │
┌─────▼─────┐ ┌─────▼─────┐ ┌──────▼──────┐ ┌────▼─────┐
│  Terrain  │ │   Cell    │ │   Object    │ │  Object  │
│  Manager  │ │  Manager  │ │ LOD Manager │ │   Pool   │
└─────┬─────┘ └─────┬─────┘ └──────┬──────┘ └────┬─────┘
      │             │              │             │
┌─────▼─────────────▼──────────────▼─────────────▼─────┐
│                  RENDERING LAYER                      │
│  (Terrain3D, Scene Tree, RenderingServer)             │
└───────────────────────────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────┐
│                   DATA LAYER                            │
│  ESM Parser | NIF Converter | BSA Archives | Textures  │
└─────────────────────────────────────────────────────────┘
```

---

## Key Features

### ✅ Completed Systems

1. **Continuous World Streaming**
   - Time-budgeted async cell loading (configurable ms/frame)
   - Priority queue based on distance from camera
   - Supports both single-terrain (3.7km²) and multi-terrain (infinite) modes
   - No loading screens between cells

2. **Advanced Terrain**
   - Powered by Terrain3D plugin (v1.0.1)
   - Procedurally generated from Morrowind LAND records
   - 32 texture slots with bilinear blending
   - Heightmap, control map, and color map support
   - Edge stitching for seamless cell boundaries

3. **4-Level LOD System**
   - **FULL** (0-50m): Original geometry + shadows
   - **LOW** (50-150m): Simplified meshes, no shadows
   - **BILLBOARD** (150-500m): 2D impostor quads via RenderingServer
   - **CULLED** (500m+): Hidden

4. **Object Pooling**
   - Reuses Node3D instances for frequent objects (flora, rocks, architecture)
   - Configurable pool sizes per model type
   - Dramatically reduces allocations and GC pressure
   - Hit rate tracking for optimization

5. **Comprehensive Data Parsing**
   - **ESM/ESP Parser:** 47 Morrowind record types (statics, NPCs, items, quests, dialogue, etc.)
   - **NIF Converter:** Full 3D model conversion with skinning, animations, and collision
   - **BSA Manager:** Reads Bethesda archives without extraction
   - **Texture Loader:** DDS, TGA formats with material deduplication

6. **Performance Optimization**
   - RenderingServer direct access (bypass scene tree for billboards)
   - Material library for deduplication
   - Binary file parsing (ESM, NIF, BSA)
   - Time-budgeted loading prevents frame hitches
   - Profiler with bottleneck detection

---

## Repository Structure

```
godotwind/
├── src/
│   ├── core/                    # Core engine systems
│   │   ├── world/              # Streaming, terrain, cells, LOD, pooling
│   │   ├── esm/                # Morrowind data file parser (47 record types)
│   │   ├── nif/                # 3D model converter (geometry, skeleton, collision)
│   │   ├── bsa/                # Archive system
│   │   └── texture/            # Texture loading + material library
│   ├── tools/                   # Developer viewers and editors
│   └── main.gd                  # Main entry point
├── scenes/                      # Demo/viewer scenes
├── addons/                      # Third-party plugins
│   ├── terrain3d/              # High-performance terrain
│   ├── sky3d/                  # Day/night cycle
│   ├── open-world-database/    # Chunk-based object streaming (OWDB)
│   ├── beehave/                # Behavior trees for AI
│   ├── dialogue_manager/       # Nonlinear dialogue
│   ├── gloot/                  # Inventory system
│   ├── pandora/                # Entity/item database
│   ├── questify/               # Graph-based quest editor
│   └── save_system/            # Save/load
├── tests/                       # Integration and unit tests
├── docs/                        # Project documentation (this folder)
├── pandora/                     # Data entity storage
└── collision-shapes.yaml        # Collision shape pattern library
```

---

## Technology Stack

### Godot Engine Features
- **Terrain3D** - Advanced terrain system with streaming regions
- **RenderingServer** - Direct access for billboard LODs and static objects
- **Skeleton3D** - Runtime skeleton construction from NIF bone data
- **AnimationLibrary** - Keyframe animations from NIF/KF files
- **PackedByteArray** - High-performance binary file parsing
- **Basis/Transform3D** - Coordinate system conversions (Z-up → Y-up)
- **MultiMeshInstance3D** - Potential for GPU instancing (future optimization)

### Third-Party Plugins
- **Terrain3D** (1.0.1) - Terrain rendering ✅ Integrated
- **Sky3D** (2.1-dev) - Atmospheric rendering ⚠️ Prepared
- **OWDB** (0.6h) - Object chunk streaming ✅ Integrated
- **Beehave** (2.9.3-dev) - AI behavior trees ⚠️ Prepared
- **Dialogue Manager** (3.9.0) - Dialogue system ⚠️ In progress
- **Questify** (1.8.0) - Quest system ⚠️ Prepared
- **GLoot** (3.0.1) - Inventory ⚠️ Prepared
- **Pandora** (1.0-alpha10) - Item database ⚠️ Prepared
- **SaveSystem** (1.3) - Save/load ⚠️ Prepared
- **GOAP** - AI planning ⚠️ Prepared

---

## Target Use Cases

### Primary: Reusable Open-World Framework
- Large-scale RPGs (Elder Scrolls, Fallout style)
- Simulation games (life sims, sandbox builders)
- Survival games with exploration
- MMO foundations (OWDB supports networking)

### Secondary: Morrowind Port
- Demonstrate framework capabilities
- Attract contributors and attention
- Test all features with real-world data
- Provide reference implementation

### Stretch Goals
- **Daggerfall-scale worlds** (Multi-terrain supports unlimited size)
- **Procedural generation** (Framework supports runtime terrain generation)
- **Multiplayer** (OWDB has networking support)

---

## Design Principles

1. **Performance First**
   - Time-budgeted operations (8ms/frame cell loading)
   - Object pooling for frequent instances
   - LOD with RenderingServer optimization
   - Material deduplication

2. **Modular Architecture**
   - Clear separation of concerns (World, ESM, NIF, BSA, Texture)
   - Domain-driven file organization
   - Autoload singletons for global services (ESMManager, BSAManager)
   - Dependency injection where appropriate

3. **Data-Driven Design**
   - YAML collision shape library
   - ESM records drive world generation
   - Configurable LOD distances
   - Tunable performance budgets

4. **Modern Techniques over Legacy**
   - Continuous world vs cell-based teleportation
   - Multiple water systems vs single plane
   - Dynamic lighting vs baked
   - Seamless streaming vs loading screens

5. **Extensibility**
   - Plugin-based architecture (Terrain3D, Sky3D, etc.)
   - Behavior trees for AI (Beehave)
   - Graph-based quests (Questify)
   - Universal inventory (GLoot)

---

## Coordinate Systems

### Morrowind
- **Up Axis:** Z
- **Forward Axis:** Y
- **Units:** Game units (70 units = 1 meter)
- **Cell Size:** 8192 units (117m)
- **Rotations:** ZYX Euler angles

### Godot
- **Up Axis:** Y
- **Forward Axis:** -Z
- **Units:** Meters
- **Cell Size:** 117m (converted)
- **Rotations:** YZX Euler angles

**Conversion:**
`CoordinateSystem` class handles position, rotation, and scale conversion between the two systems.

---

## Performance Targets

- **Cell Load Budget:** 8ms/frame (configurable)
- **LOD Update Interval:** 100ms (not every frame)
- **View Distance:** 3-5 cells radius (351m - 585m)
- **Max Queue Size:** 16 cells loading simultaneously
- **Object Pool Global Cap:** 5000 instances
- **Billboard Minimum Size:** 2m (smaller objects cull earlier)

**Current Performance:**
- Smooth 60 FPS with 5-cell radius streaming
- ~19k LOC optimized GDScript
- Minimal GC pressure thanks to pooling
- RenderingServer billboards have near-zero overhead

---

## Next-Gen Goals

### 1. Water Systems
- **Ocean:** FFT-based simulation with foam, caustics
- **Rivers:** Flow maps, particle effects
- **Ponds/Lakes:** Simple ripple shaders
- **Different altitudes:** Multiple water planes
- **Physics:** Buoyancy, swimming

### 2. Weather Systems
- Dynamic weather per region (from ESM REGN records)
- Particle systems for rain, snow, ash storms
- Sky3D integration for atmospheric effects
- Sound ambience tied to weather

### 3. Advanced AI
- Beehave behavior trees for NPC schedules
- GOAP for goal-oriented planning
- Pathfinding (Morrowind PGRD records parsed but not used)
- Realistic NPC routines (eating, sleeping, working)

### 4. Dynamic Lighting
- Day/night cycle (Sky3D)
- Torch/lantern dynamic lights
- Interior ambient occlusion
- Light probes for GI

### 5. Procedural Generation
- Terrain noise generation (beyond ESM data)
- Procedural flora placement
- Building interiors
- Dungeon generation

### 6. Multiplayer
- OWDB networking support
- Dedicated server mode
- Player synchronization
- Shared world state

---

## Contributing

### Code Style
- GDScript with type hints
- Clear variable naming
- Inline documentation for complex logic
- Signals for loose coupling
- Autoloads for global services

### File Organization
- One class per file
- Group related classes in directories
- Tools separate from core
- Tests mirror src structure

### Performance Considerations
- Always profile before optimizing
- Use object pooling for frequent allocations
- Prefer RenderingServer for visual-only objects
- Time-budget any expensive operations
- Cache lookups in dictionaries

---

## Documentation Map

This overview is part of a comprehensive documentation set:

1. **[01_PROJECT_OVERVIEW.md](01_PROJECT_OVERVIEW.md)** ← You are here
2. **[02_WORLD_STREAMING.md](02_WORLD_STREAMING.md)** - Streaming, cell management, loading
3. **[03_TERRAIN_SYSTEM.md](03_TERRAIN_SYSTEM.md)** - Terrain generation, Terrain3D
4. **[04_LOD_AND_OPTIMIZATION.md](04_LOD_AND_OPTIMIZATION.md)** - LOD, pooling, performance
5. **[05_ESM_SYSTEM.md](05_ESM_SYSTEM.md)** - ESM parsing, data structures
6. **[06_NIF_SYSTEM.md](06_NIF_SYSTEM.md)** - NIF conversion, collision, animations
7. **[07_ASSET_MANAGEMENT.md](07_ASSET_MANAGEMENT.md)** - BSA, textures, materials
8. **[08_PLUGIN_INTEGRATION.md](08_PLUGIN_INTEGRATION.md)** - Third-party plugins
9. **[09_GAMEPLAY_SYSTEMS.md](09_GAMEPLAY_SYSTEMS.md)** - Dialogue, quests, AI, inventory
10. **[10_DEVELOPMENT_STATUS.md](10_DEVELOPMENT_STATUS.md)** - Task tracker, roadmap
11. **[11_VIBE_CODING_METHODOLOGY.md](11_VIBE_CODING_METHODOLOGY.md)** - Development workflow

---

## Quick Start

### Prerequisites
- Godot 4.5+
- Morrowind data files (Morrowind.esm + BSA archives)
- ~2GB disk space for terrain cache

### Running the Demo
1. Clone repository
2. Copy Morrowind data files to project root
3. Open project in Godot
4. Run `scenes/streaming_demo.tscn`
5. Use WASD + mouse to fly around

### Developer Tools
- **F3:** Toggle stats overlay
- **Terrain Viewer:** Preview terrain generation
- **Cell Viewer:** Inspect individual cells
- **NIF Viewer:** Test model conversions

---

## License

[Add your license here]

---

## Credits

**Core Framework:** Godotwind Team
**Morrowind Data:** Bethesda Softworks
**Plugins:** Terrain3D, Sky3D, OWDB, Beehave, Dialogue Manager, GLoot, Pandora, Questify, SaveSystem, GOAP contributors

---

**Last Updated:** 2025-12-13
**Godot Version:** 4.5
**Project Maturity:** Alpha (60% complete)
