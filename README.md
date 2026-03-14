# Godotwind

An open-world RPG framework for Godot 4.6, using Morrowind as its data source.
Not a faithful port — "Morrowind if it was made in 2025."

The long-term goal: a general-purpose open-world RPG framework for Godot, where Morrowind is just one "mod" that implements abstract interfaces for terrain, NPCs, dialogue, inventory, and quests.

**Current state:** World streaming and rendering are production-quality. Gameplay systems (combat, dialogue, quests) are not started. See [STATUS.md](docs/STATUS.md).

## Quick Start

1. **Install Godot 4.6 Mono** (C# support required)
2. **Install Terrain3D addon v1.0.1** — Download from [Terrain3D releases](https://github.com/TokisanGames/Terrain3D/releases/tag/v1.0.1), extract and copy the `addons/terrain_3d/` folder into your project's `addons/` directory. Enable via Project > Project Settings > Plugins.
3. **Configure Morrowind path** — Run `src/tools/settings_tool.tscn`, click Auto-Detect or Browse
4. **Prebake assets** — Run `src/tools/prebaking/prebaking_ui.tscn` to generate terrain, impostors, shore mask
5. **Run** — Open `scenes/Godotwind.tscn`

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

## What Works

- **World streaming** — async cell loading, 2ms/frame budget, priority queues
- **3-tier LOD** — NEAR (0-150m full 3D), MID (150-500m instanced), FAR (500-5km impostors)
- **Terrain** — Terrain3D with multi-region support
- **ESM/NIF/BSA parsing** — 47 record types, thread-safe, C# for performance
- **NPC assembly** — body parts from race data, body part mirroring, animations
- **Developer console** — object picking, selection outline, commands
- **Deformation** — RTT-based ground deformation (snow, mud, ash)

## What Doesn't Work Yet

- Combat, magic, AI, dialogue, quests, inventory, save/load
- Ocean/water (framework exists, not wired into main scene)
- Weather/sky (not started)
- Interior transitions (door detection exists, no seamless loading)

## Tech Stack

- **Engine:** Godot 4.6, Forward+, Jolt Physics, D3D12
- **Languages:** GDScript 95% / C# 5% (binary parsing) / GLSL shaders
- **Terrain:** Terrain3D addon
- **Asset formats:** ESM/ESP, NIF, BSA (Morrowind)

## Documentation

| Doc | Contents |
|-----|---------|
| [STATUS.md](docs/STATUS.md) | What works, what doesn't (ground truth) |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Systems overview, code map, key patterns |
| [MASTERPLAN.md](docs/audit/MASTERPLAN.md) | Roadmap and architecture decisions |
| [FUTURE_STEPS.md](docs/FUTURE_STEPS.md) | What's next, Godot features we're waiting for |

## Contributing

- Read [ARCHITECTURE.md](docs/ARCHITECTURE.md) for the code layout
- GDScript for everything except binary parsing (C#)
- Strict typing in `src/core/`, relaxed in `src/tools/`
- Use `Log.info("category", "message")` instead of `print()`
- Don't create new autoloads — use existing singletons
- Test visually: run `scenes/Godotwind.tscn`, press `` ` `` for console
