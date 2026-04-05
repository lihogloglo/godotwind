# Architecture

Systems overview derived from the actual codebase.

## Language Split

**GDScript (95%)** — Godot API, gameplay, orchestration. C# has Variant marshalling overhead for Godot calls.
**C# (5%)** — Binary parsing only (20-50x faster). Lives in `src/native/`.
**Bridge:** C# can't call GDExtensions (like Terrain3D). Use `src/core/native_bridge.gd` as interop layer.

## Autoloads (Global Singletons)

| Name | File | Purpose |
|------|------|---------|
| Log | `src/core/logging/logger.gd` | Structured logging (NOT `Logger` — name conflict with Godot 4.6 built-in) |
| SettingsManager | `src/core/settings_manager.gd` | User settings, Morrowind path |
| BSAManager | `src/core/bsa/bsa_manager.gd` | Archive access, 256MB LRU cache |
| ESMManager | `src/core/esm/esm_manager.gd` | ESM parsing, grid-indexed cell lookup |
| OceanManager | `src/core/water/ocean_manager.gd` | Water system (not integrated yet) |
| ShaderManager | `src/core/shaders/shader_manager.gd` | Shader hot-swap |

## Core Systems (`src/core/`)

| Directory | What it does |
|-----------|-------------|
| `world/` | Cell streaming, terrain, LOD, object pooling, impostors |
| `esm/` | ESM/ESP record parsing (47 types), caching |
| `nif/` | NIF model → Godot conversion (mesh, materials, skeleton, 5 animation controller types, collision, particles, lights). NIFMaterialInfo unified struct for GDScript/C# sync |
| `bsa/` | BSA archive extraction |
| `character/` | NPC assembly (Morrowind body parts, humanoid GLB), controller |
| `animation/` | Animation loading, state machine, IK (TwoBoneIK3D), retargeting |
| `water/` | Ocean mesh, Gerstner waves, buoyancy, shore mask |
| `console/` | Developer console, command registry, object picking |
| `deformation/` | RTT-based terrain deformation |
| `texture/` | DDS/TGA loading, material dedup (hash includes 7 texture slots, apply mode, ZBuffer, specular color) |
| `streaming/` | BackgroundProcessor (async task queue) |
| `threading/` | WorkerThreadPool job system |
| `player/` | Fly camera, FPS controller |
| `shaders/` | Shader management, custom shaders |

## C# Layer (`src/native/`)

| File | Purpose |
|------|---------|
| NativeESMLoader/Reader.cs | ESM binary parsing |
| NativeNIFReader/Converter.cs | NIF binary parsing + mesh conversion |
| NativeBSAReader.cs | BSA binary parsing |
| ESMCache.cs | Record caching |
| TerrainGenerator.cs | Terrain mesh generation |
| NativeBinaryReader.cs | Binary I/O utilities |
| NativeFactory.cs | Factory for native parsers |

## 3-Tier Distance Rendering

Constants in `src/core/world/distance_utils.gd`.

| Tier | Range | Technique |
|------|-------|-----------|
| NEAR | 0-150m | Full Node3D + physics. `visibility_range` on nodes. |
| MID | 150-500m | RenderingServer instances, per-instance visibility_range, 3 LOD levels |
| FAR | 500-5km | Octahedral impostors via single MultiMesh draw call |

Promotion at 130m / demotion at 190m (hysteresis prevents oscillation).

## Key Patterns

- **Prebaked assets** — NIF/ESM converted to `.res` at prebake time (1-5ms load vs 50-200ms parse)
- **Frame budgeting** — 2ms/frame for cell loading, keeps 60 FPS
- **Material dedup** — Hash-based, 90% reduction (10k → 1k materials)
- **Object pooling** — Recycled Node3D instances, O(1) release
- **NativeBridge** — GDScript wrapper for C# ↔ GDExtension interop

## Coordinate System

Morrowind is Z-up, Godot is Y-up: `Vector3(mw.x, mw.z, -mw.y)`.
1 ESM unit = 1/128 meter. Cell size = 8192 units = ~64m rendered as 117m.
See `src/core/coordinate_system.gd`.

## Scenes

| Scene | Purpose |
|-------|---------|
| `scenes/Godotwind.tscn` | Main world explorer (production) |
| `scenes/nif_viewer.tscn` | NIF model browser |
| `scenes/asset_viewer.tscn` | Asset inspection |
| `src/tools/settings_tool.tscn` | Morrowind path config |
| `src/tools/prebaking/prebaking_ui.tscn` | Asset prebaking |
