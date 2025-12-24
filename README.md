# Godotwind

An open-world framework for Godot 4.5+. Uses Morrowind assets as its reference implementation to demonstrate seamless world streaming, terrain rendering, and game data integration at scale.

So far, 100% vibe coded with Claude Opus 4.5.

The long-term goal is to continue where Skelerealms stopped. ( https://github.com/SlashScreen/skelerealms )

**A world streaming and rendering showcase** - all visual/technical systems are okay-ish. Player interaction systems (combat, dialogue, quests) are not yet implemented.


## Quick Start

1. **Configure Morrowind Path**
   - Run `scenes/settings_tool.tscn` - Auto-Detect or Browse
   - Or set env: `export MORROWIND_DATA_PATH="/path/to/Data Files"`

2. **Prebake the assets**
   - Run `prebaking_ui.tscn` and generate the Terrain (fast), the impostors (kinda fast), the shore mask (kinda fast) and the merged meshes (a bit slow, but it's better thanks to our custom wrapper for meshoptimizer https://github.com/zeux/meshoptimizer )

3. **Run World Explorer**
   - Main scene for Morrowind : `scenes/world_explorer.tscn`
   - La Palma island in 1:1 resolution. Heightmap generated thanks to the data of Centro de descargas https://centrodedescargas.cnig.es/CentroDescargas/ 

## Controls

| Key | Action |
|-----|--------|
| Right Mouse | Capture camera |
| WASD/ZQSD | Move |
| Space/Shift | Up/Down |
| Ctrl | Speed boost |
| Scroll | Adjust speed |
| M | Toggle models |
| N | Toggle NPCs |
| O | Toggle ocean |
| K | Toggle sky/day-night |
| P | Toggle player/fly camera |
| TAB | Interior browser |
| F3 | Performance overlay |
| \` (Backtick) | Developer console |

## Implementation Status

### Complete Systems

| System | Description |
|--------|-------------|
| **World Streaming** | Infinite terrain, time-budgeted async loading, no loading screens |
| **Terrain** | Morrowind LAND to Terrain3D, heightmaps, texture splatting, multi-region |
| **Object Streaming** | Cell references, async NIF parsing, object pooling, MultiMesh batching |
| **ESM/ESP Parsing** | 44 record types with thread-safe global access and grid indexing |
| **NIF Conversion** | Geometry, materials, skeletons (buggy), animations  (buggy), collision, auto-LOD (3 levels) |
| **BSA Management** | Archive reading, 256MB LRU cache, thread-safe extraction |
| **Texture Loading** | DDS/TGA with material library deduplication |
| **Ocean** | FFT waves from this project : https://github.com/2Retr0/GodotOceanWaves/ , shore dampening, choppiness controls, buoyancy queries |
| **Sky/Weather** | Volumetric clouds, day/night cycle, sun/moon, ambient lighting |
| **Character Assembly** | NPC body parts combined from race + head + hair meshes |
| **Character Animation** | Full state machine (idle, walk, run, jump, swim, combat, death, spell cast) |
| **Character Movement** | Slope adaptation, foot IK, wander behavior, speed modulation |
| **Deformation** | RTT-based ground deformation with recovery (snow, mud, ash) |
| **Console** | Command registry, object picking, selection outline |
| **Distant Rendering** | MID tier merged meshes (500m-2km), FAR tier impostors (2km-5km) |

### Not Implemented (Addons Installed But Not Wired)

| System | Addon | Status |
|--------|-------|--------|
| Dialogue UI | dialogue_manager | Data parses, no UI to display conversations |
| Player Inventory | gloot | NPC inventories load, player has no inventory |
| Quest System | questify | No quest tracking or journal |
| AI Behaviors | beehave | Wander works, behavior trees not integrated |
| Combat | - | No attack/defense/damage system |
| Magic/Spells | - | Spell records parsed, no casting |
| Save/Load | save_system | Addon installed, not wired |
| NPC Interaction | - | Can't click NPCs to initiate dialogue |

## Performance Optimizations

All verified in source code:

| Optimization | Location | Effect |
|--------------|----------|--------|
| MultiMesh Batching | cell_manager.gd | 10+ identical objects → single draw call |
| Object Pooling | object_pool.gd | Reuses nodes, reduces allocations |
| Auto-LOD Generation | nif_converter.gd | 3 levels (75%, 50%, 25% reduction) |
| Material Deduplication | material_library.gd | Shared materials reduce VRAM |
| Async NIF Parsing | background_processor.gd | Worker threads prevent frame spikes |
| Time Budgeting | world_streaming_manager.gd | 2ms/frame cell load, 8ms terrain gen |
| Frustum Culling | Native Godot + occlusion | Skips off-screen objects |
| Adaptive Submit Rate | world_streaming_manager.gd | Throttles under queue pressure |


## License

I don't know, I'm just vibing here.