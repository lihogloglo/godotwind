# Architecture

Systems overview derived from the actual codebase.

## Language Split

**C# is the default for new work** — significantly more performant per `.claude/CLAUDE.md` Language & Typing Policy. Use C# for binary parsing, math-heavy systems, data structures, anything per-frame on > 100 items, anything on a worker thread, any new subsystem where performance might matter. Existing C# lives in `src/native/`.

**GDScript** — thin orchestration glue where work is dominated by Godot API calls (UI callbacks, simple gameplay triggers, editor `@tool` shims, one-file utilities). Marshalling cost eats the C# raw-compute win there.

**Bridge:** C# can't call GDExtensions (like Terrain3D). Use `src/core/native_bridge.gd` as interop layer.

## Autoloads (Global Singletons)

| Name | File | Purpose |
|------|------|---------|
| Log | `src/core/logging/logger.gd` | Structured logging (NOT `Logger` — name conflict with Godot 4.6 built-in) |
| SettingsManager | `src/core/settings_manager.gd` | User settings, Morrowind path |
| BSAManager | `src/core/bsa/bsa_manager.gd` | Archive access, 256MB LRU cache |
| ESMManager | `src/core/esm/esm_manager.gd` | ESM parsing, grid-indexed cell lookup |
| OceanManager | `src/core/water/ocean_manager.gd` | Water runtime, surface mesh, shore mask, buoyancy, and shared `WaterSurfaceState`; production integration status is tracked in `docs/systems/ocean/architecture.md` |
| ShaderManager | `src/core/shaders/shader_manager.gd` | Shader hot-swap |

## Source Boundary

Godotwind's framework contracts are source-first, not Morrowind-first. Generic
streaming/rendering code is expected to consume `WorldSource`,
`WorldCoordinateMapper`, `WorldObjectSource`, `WorldObjectRecord`,
`WorldObjectSpawnAdapter`, `WorldDataProvider`, and `WorldAssetProvider`.
Morrowind ESM/ESP/BSA/NIF parsing, coordinate conversion, texture/material
translation, dialogue condition semantics, and skeleton quirks belong in
parser/importer folders or `src/core/**/morrowind/**` adapter folders.

Current status: the streaming boot path, model loading, preloading, HLOD/FAR
object discovery, distant-light records, `CellPayload`, and static collision
payloads are provider-fed. Remaining migration work is tracked in
`docs/audit/morrowind_framework_boundary_mega_audit_2026_05_21.md`.

## Core Systems (`src/core/`)

| Directory | What it does |
|-----------|-------------|
| `world/` | Cell streaming, terrain, LOD, object pooling, impostors |
| `esm/` | ESM/ESP record parsing (47 types), caching |
| `nif/` | NIF model → Godot conversion (mesh, materials, skeleton, 5 animation controller types, collision, particles, lights). NIFMaterialInfo unified struct for GDScript/C# sync |
| `bsa/` | BSA archive extraction |
| `character/` | NPC assembly (Morrowind body parts, humanoid GLB), controller |
| `animation/` | Animation loading, state machine, IK (TwoBoneIK3D), retargeting |
| `water/` | Ocean mesh, FFT waves, flat fallback, buoyancy, shore mask, receiver-waterline diagnostics, and wetness coordination |
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
| NEAR gameplay | 0-150m | Sparse `Node3D` for gameplay, interaction, static collision, physics, and scene-tree behavior. |
| Static visuals | 150-400m bridge | Cell-local `CellStaticBucket` draw groups. Groups use local `MultiMesh` buckets under one ownership path; singleton groups use the single-slot transform API instead of a bulk buffer upload. Embedded mesh LOD stays engine-driven. |
| FAR impostors | 400-5km, capped by view distance | Custom octahedral impostors via spatial `MultiMeshInstance3D` pages. Default-on. |
| HLOD | Optional 400-1000m comparison tier | One raw RS instance per ObjectPaging chunk: runtime-merged static geometry from the adaptive 1x1 / 2x2 / 4x4 chunk walker. Default-off in `Godotwind.tscn`; `hlod_enable` keeps it available for cost/coverage comparison while MID and FAR keep the fixed 400m handoff. |

**MID→NEAR promotion at 250m, demotion at 280m** (20m hysteresis, `streaming_config.gd:78-81`) — physics bodies and scene-tree NEAR nodes are pre-created while the MID RS instance stays visible, then the RS instance is hidden and the Node3D becomes the active renderer when the camera enters the 150m band.

See `docs/systems/distance_rendering.md` (and `docs/archive/plans/lod_refactor_b_wide.md` for the B-wide migration history).

## Key Patterns

- **Prebaked assets** — NIF/ESM converted to `.res` at prebake time (1-5ms load vs 50-200ms parse)
- **Frame budgeting** — 2ms/frame for cell loading, keeps 60 FPS
- **Material dedup** — Hash-based, 90% reduction (10k → 1k materials)
- **Object pooling** — Recycled Node3D instances, O(1) release
- **NativeBridge** — GDScript wrapper for C# ↔ GDExtension interop

## Coordinate System

Framework code should ask the active `WorldCoordinateMapper` for grid and cell
metrics. The current Morrowind adapter maps Z-up source data into Godot Y-up
coordinates via `src/core/world/morrowind/morrowind_coordinate_mapper.gd`. The
older `src/core/coordinate_system.gd` helper is still present and is one of the
remaining boundary-cleanup targets.

## Scenes

| Scene | Purpose |
|-------|---------|
| `scenes/Godotwind.tscn` | Main world explorer (production) |
| `scenes/bsa_viewer.tscn` | NIF model browser — loads live from BSA source data |
| `scenes/baked_asset_viewer.tscn` | Prebaked `.res` cache inspector (includes `.crashtest` quarantine) |
| `src/tools/settings_tool.tscn` | Morrowind path config |
| `src/tools/prebaking/prebaking_ui.tscn` | Asset prebaking |
