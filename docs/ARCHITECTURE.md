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

## 4-Tier Distance Rendering

Constants in `src/core/world/distance_utils.gd`.

| Tier | Range | Technique |
|------|-------|-----------|
| NEAR | 0-150m | Full Node3D + physics in the scene tree. Root `visibility_range` band on each Node3D. |
| MID | 0-300m (HLOD on) / 0-500m (HLOD off) | Single raw `RenderingServer` instance per object with embedded `ImporterMesh.generate_lods()` chain. Engine C++ `RendererSceneCull` picks the LOD level from screen-space coverage. No per-band visibility cascades. |
| HLOD | 300-1000m | One RS instance per paged chunk — runtime-merged static geometry with its own LOD chain. OpenMW-style distance-adaptive walker (1×1 / 2×2 / 4×4 cells at [150,300) / [300,600) / [600,1000)m bands) in `src/core/world/object_paging.gd`. Enabled by default via `hlod_enable` console command. |
| FAR | 1000-5km | Custom octahedral impostors via a single `MultiMeshInstance3D` draw call. |

**MID→NEAR promotion at 250m, demotion at 280m** (20m hysteresis, `streaming_config.gd:78-81`) — physics bodies and scene-tree NEAR nodes are pre-created while the MID RS instance stays visible, then the RS instance is hidden and the Node3D becomes the active renderer when the camera enters the 150m band.

See `docs/systems/distance_rendering.md` (and `docs/audit/LOD_REFACTOR_B_WIDE.md` for the B-wide migration history).

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
