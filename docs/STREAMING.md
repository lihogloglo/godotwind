# World Streaming & Terrain System

## Overview

Godotwind uses a unified streaming architecture that loads terrain and objects dynamically around the camera with no loading screens. The system supports multiple data sources (Morrowind, La Palma GeoTIFF, etc.) through a provider interface.

## Architecture

```
Camera Position
      │
      ▼
┌─────────────────────────────────────────────────────┐
│           WorldStreamingManager                      │
│  - Tracks camera, manages load/unload queues        │
│  - Time-budgeted processing (no frame hitches)      │
│  - Coordinates terrain + objects                     │
└──────────────┬────────────────────┬─────────────────┘
               │                    │
               ▼                    ▼
┌──────────────────────┐  ┌──────────────────────────┐
│   TerrainManager     │  │      CellManager         │
│  - LAND → Terrain3D  │  │  - Cell refs → Node3D    │
│  - Heightmaps        │  │  - NIF loading           │
│  - Texture splatting │  │  - Object placement      │
└──────────┬───────────┘  └───────────┬──────────────┘
           │                          │
           ▼                          ▼
┌──────────────────────┐  ┌──────────────────────────┐
│  GenericTerrainStr.  │  │   BackgroundProcessor    │
│  - Multi-world       │  │  - WorkerThreadPool      │
│  - Async generation  │  │  - Thread-safe parsing   │
│  - Region unloading  │  │  - Priority queue        │
└──────────┬───────────┘  └──────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────────────────┐
│              WorldDataProvider (interface)            │
│  ┌─────────────────────┐  ┌────────────────────────┐ │
│  │ MorrowindDataProv.  │  │  LaPalmaDataProvider   │ │
│  │ - ESM/BSA data      │  │  - GeoTIFF heightmaps  │ │
│  └─────────────────────┘  └────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

## Key Files

| File | Purpose |
|------|---------|
| `src/core/world/world_streaming_manager.gd` | Main orchestrator - priority queues, time budgeting |
| `src/core/world/cell_manager.gd` | Loads cells, instantiates objects from NIF |
| `src/core/world/terrain_manager.gd` | LAND record → Terrain3D conversion |
| `src/core/world/generic_terrain_streamer.gd` | Multi-world terrain streaming |
| `src/core/world/world_data_provider.gd` | Base interface for world data |
| `src/core/world/morrowind_data_provider.gd` | Morrowind ESM/BSA implementation |
| `src/core/world/lapalma_data_provider.gd` | La Palma GeoTIFF implementation |
| `src/core/streaming/background_processor.gd` | Async task management |

## Streaming Flow

### Terrain Loading
1. Camera moves → WorldStreamingManager detects new visible regions
2. Regions prioritized by distance (closer = higher) and frustum (in-view = higher)
3. BackgroundProcessor generates heightmap/splatmap on worker thread
4. Main thread imports to Terrain3D (time-budgeted, max 2ms/frame)
5. Distant regions unloaded to free memory

### Object/Cell Loading
1. Cell enters view distance → added to load queue
2. CellManager.request_exterior_cell_async() starts background parse
3. NIF files parsed on worker thread (thread-safe via NIFParseResult)
4. Main thread instantiates objects progressively (time-budgeted)
5. Objects use native Godot VisibilityRange for LOD

## Configuration

```gdscript
# WorldStreamingManager defaults
var cell_load_budget_ms: float = 2.0      # Max ms/frame for loading
var view_distance_cells: int = 3          # Cells loaded around camera
var max_queue_size: int = 16              # Max pending loads
var unload_hysteresis: int = 2            # Extra cells before unload

# Terrain3D settings (in scene)
mesh_lods = 7          # LOD levels for distance
mesh_size = 48         # Vertices per mesh chunk
```

## Terrain3D Integration

- **Single-terrain mode**: 32x32 Morrowind cells max (~3.7km)
- **Multi-terrain mode**: Unlimited via GenericTerrainStreamer
- **Region size**: 256x256 pixels = 4x4 Morrowind cells
- **Vertex spacing**: ~1.83m (117m cell / 64 vertices)

Terrain3D handles its own LOD via clipmap. We generate:
- Heightmap (from LAND vertex heights)
- Control map (texture indices + blend weights)
- Color map (vertex colors, optional)

## Async System

The `BackgroundProcessor` wraps Godot's WorkerThreadPool:

```gdscript
# Submit work to background thread
var task_id = background_processor.submit_task(callable, priority)

# Results delivered via signal
background_processor.task_completed.connect(_on_task_done)
```

Thread-safe operations:
- NIF parsing (`nif_converter.parse_buffer_only()`)
- Heightmap generation (`terrain_manager.generate_region_data()`)
- BSA extraction (mutex-protected cache)

Main-thread only:
- Scene tree modifications
- Terrain3D imports
- Node instantiation

## Performance

| Metric | Target | Achieved |
|--------|--------|----------|
| FPS during streaming | 60 | 60+ |
| Cell load budget | 2ms/frame | 2ms |
| View distance | 3-5 cells | 585m+ |
| Frame hitches | None | None |

## Object LOD

Uses native Godot `VisibilityRange` (not custom ObjectLODManager - that was removed):

```gdscript
# Set on MeshInstance3D
mesh.visibility_range_begin = 0.0
mesh.visibility_range_end = 500.0
mesh.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
```

Distance-based culling handled automatically by Godot's renderer.
