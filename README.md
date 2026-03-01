# Godotwind

An open-world RPG framework for Godot 4.6. Not a faithful port — a framework that uses Morrowind as its reference implementation.

The long-term goal is to continue where [Skelerealms](https://github.com/SlashScreen/skelerealms) stopped: a general-purpose open-world RPG framework for Godot, with abstract interfaces for inventory, dialogue, AI, and save/load — where addons are optional backends and Morrowind is just one "mod" that implements them.

**Current state:** World streaming and rendering are production-quality. Gameplay systems (combat, dialogue, quests) are not yet implemented. See [MASTERPLAN](docs/audit/MASTERPLAN.md) for the roadmap.

## Quick Start

1. **Configure Morrowind Path**
   - Run `src/tools/settings_tool.tscn` — Auto-Detect or Browse
   - Or set env: `export MORROWIND_DATA_PATH="/path/to/Data Files"`

2. **Prebake Assets**
   - Run `src/tools/prebaking_ui.tscn` — generate terrain, impostors, shore mask, merged meshes

3. **Run World Explorer**
   - Main scene: `src/tools/world_explorer.tscn`

## Controls

| Key | Action |
|-----|--------|
| Right Mouse | Capture camera |
| WASD/ZQSD | Move |
| Space/Shift | Up/Down |
| Ctrl | Speed boost |
| Scroll | Adjust speed |
| P | Toggle player/fly camera |
| TAB | Interior browser |
| F3 | Performance overlay |
| `` ` `` | Developer console |

## Implementation Status

### Core Systems (Complete)

| System | Notes |
|--------|-------|
| **World Streaming** | Time-budgeted async, priority queues, no hitches |
| **Terrain** | Terrain3D integration, multi-region, edge stitching |
| **Object Streaming** | Cell refs, async NIF parsing, object pooling, MultiMesh batching |
| **ESM/ESP Parsing** | 47 record types, thread-safe global access, grid indexing |
| **NIF Conversion** | Geometry, materials, skeletons, animations, collision |
| **BSA Archives** | 256MB LRU cache, thread-safe extraction |
| **Texture Loading** | DDS/TGA, material deduplication |
| **Deformation** | RTT-based ground deformation (snow, mud, ash) |
| **Console** | Command registry, object picking, selection outline |
| **3-Tier LOD** | NEAR (0-150m full 3D), MID (150-500m merged), FAR (500-5km impostors) |

### Framework Ready (Not Integrated)

| System | Status |
|--------|--------|
| **Ocean/Water** | FFT waves, shore dampening, buoyancy — OceanManager exists, not wired into main scene |
| **Sky/Weather** | Sky3D installed, day/night prepared — not integrated |
| **Character Assembly** | NPC body parts from race + head + hair — pipeline complete |
| **Character Animation** | State machine (idle/walk/run/jump) — locomotion working, action layers stubbed |

### Not Started (Addons Installed, Not Wired)

| System | Addon | Notes |
|--------|-------|-------|
| Dialogue | dialogue_manager | Records parsed, no UI |
| Inventory | GLoot | NPC inventories load, player has none |
| Quests | Questify | No tracking or journal |
| AI | Beehave | Behavior trees not integrated |
| Combat | — | No attack/defense/damage |
| Save/Load | — | No persistence layer designed |

## Documentation

| Doc | Content |
|-----|---------|
| [STATUS.md](docs/STATUS.md) | Per-system implementation status (ground truth) |
| [MASTERPLAN.md](docs/audit/MASTERPLAN.md) | Roadmap, architecture decisions, framework-first identity |
| [FINDINGS.md](docs/audit/FINDINGS.md) | Audit issue tracker |
| [DESIGN_PATTERNS.md](docs/DESIGN_PATTERNS.md) | Code patterns: NativeBridge, pooling, batching |
| [DATA_PIPELINE.md](docs/DATA_PIPELINE.md) | ESM/NIF/BSA formats, coordinate conversion |
| [PERFORMANCE_GUIDE.md](docs/PERFORMANCE_GUIDE.md) | Frame budgeting, async loading, profiling |

## Tech Stack

- **Engine:** Godot 4.6, Forward+, Jolt Physics, D3D12
- **Languages:** GDScript 95% / C# 5% / GLSL shaders
- **Terrain:** Terrain3D addon
- **Asset formats:** ESM/ESP, NIF, BSA (Morrowind)
