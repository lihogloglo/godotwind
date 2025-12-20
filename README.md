# Godotwind

OpenMW-inspired framework for open-world games in Godot 4.5. Uses Morrowind assets as reference implementation.

## Quick Start

1. **Configure Morrowind Path**
   - Run `scenes/settings_tool.tscn` → Auto-Detect or Browse
   - Or set env: `export MORROWIND_DATA_PATH="/path/to/Data Files"`

2. **Run World Explorer**
   - Main scene: `scenes/world_explorer.tscn`
   - Press F5 or run from editor

## Controls

**World Mode:**
- Right Mouse - Capture camera
- ZQSD/WASD - Move
- Space/Shift - Up/Down
- Ctrl - Speed boost
- P - Toggle player/fly camera
- TAB - Switch to Interior browser
- F3 - Performance overlay

**Interior Mode:**
- Browse/search all cells
- Double-click to load

## Tools

| Tool | Scene | Purpose |
|------|-------|---------|
| World Explorer | `scenes/world_explorer.tscn` | Terrain streaming, object loading, cell browsing |
| NIF Viewer | `scenes/nif_viewer.tscn` | 3D model browser with animation playback |
| Settings | `scenes/settings_tool.tscn` | Configure Morrowind data path |

## Architecture

```
src/core/
├── esm/        # ESM/ESP parsing (47 record types)
├── bsa/        # BSA archive extraction
├── nif/        # NIF model conversion (geometry, materials, animations)
├── world/      # Streaming manager, terrain, cells
├── water/      # Ocean system (framework ready)
├── deformation/# RTT deformation (snow, mud, ash)
├── player/     # Fly camera + FPS controller
└── console/    # Developer console
```

## Features

**Working:**
- ✅ Infinite terrain streaming (no loading screens)
- ✅ Multi-region support via Terrain3D
- ✅ Object streaming (NPCs, statics, lights)
- ✅ Interior cell viewing
- ✅ NIF loading (animations, collision, skeletons)
- ✅ ESM/BSA reading (all 47 record types)
- ✅ LOD system, object pooling
- ✅ Developer console with object picking
- ✅ RTT deformation system

**Not Implemented:**
- ❌ Combat, magic, dialogue, quests
- ❌ Weather, day/night (Sky3D ready)
- ❌ Water integration (OceanManager exists)
- ❌ NPC AI (Beehave installed)

## Configuration

Priority order:
1. `MORROWIND_DATA_PATH` env variable
2. `user://settings.cfg`
3. `project.godot` settings

See `docs/SETTINGS.md` for details.

## Documentation

| File | Content |
|------|---------|
| [docs/STATUS.md](docs/STATUS.md) | Implementation status |
| [docs/STREAMING.md](docs/STREAMING.md) | Streaming architecture |
| [docs/TODO.md](docs/TODO.md) | Prioritized tasks |
| [docs/05_ESM_SYSTEM.md](docs/05_ESM_SYSTEM.md) | ESM parsing |
| [docs/06_NIF_SYSTEM.md](docs/06_NIF_SYSTEM.md) | NIF conversion |

## Tech Stack

- Godot 4.5 (Forward+)
- Terrain3D addon
- Jolt Physics 3D
- Custom ESM/BSA/NIF readers

## Performance

- 60+ FPS during streaming
- 585m+ view distance
- 2ms/frame load budget
- Multi-threaded asset loading

## License

See LICENSE file.
