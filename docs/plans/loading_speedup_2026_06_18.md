# Loading Speedup Plan - 2026-06-18

## Goal

Make Godotwind feel much faster at two distinct boundaries:

1. **Process launch -> main menu.** This should not load the world.
2. **New/load game -> first playable world frame.** This should load only the
   selected starting cell neighborhood, then stream the rest.

This is the OpenMW pattern: load/index game data early enough for menus and
validation, but keep cell refs, scene objects, physics bodies, terrain
activation, and meshes lazy until the world actually needs them.

## Baseline Measured Today

Command:

```powershell
D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe --path D:/Gamedev/Godotwind/godotwind scenes/Godotwind.tscn -- --loading-baseline=first_playable --loading-cache-state=as_is --quit-after-ready=45
```

Output:

`C:/Users/metzo/AppData/Roaming/Godot/app_userdata/Godotwind/benchmark_results/loading_baseline_first_playable_2026-06-18_15-10-28.json`

Result:

| Metric | Time |
|---|---:|
| Process start -> first playable | 30.739s |
| Process start -> `_ready()` | 0.285s |
| Process start -> `_init_async` done | 18.500s |
| `_init_async` duration | 9.909s |
| Boot loading gate | 5.945s |
| Cell-manager publication inside gate | 1.980s accumulated |

Largest attributed costs:

| Owner | Time |
|---|---:|
| Ready -> `_init_async` start gap | 8.306s |
| Post-init -> boot-gate start gap | 6.291s |
| ESM GDScript supplement/populate | 4.437s |
| ESM native cache load | 2.411s |
| Terrain load/init/horizon maps | 1.562s |
| BSA archive indexing | 1.051s |
| Inner-ring streaming gate | 5.945s |

Note: the "horizon maps" phase currently includes terrain texture bridge work.
That label should be split before optimizing it.

The baseline was valid and reached first playable. No shader/import cache was
cleared because no shader changed.

## What OpenMW Does

Local code inspected under `inspos/openmw`:

- Startup enters through `apps/openmw/main.cpp`, then `apps/openmw/engine.cpp`.
- `Engine::prepareEngine()` wires managers, VFS, resources, UI, sound, and
  world systems before main menu.
- `World::loadData(...)` is run through `std::async` while the loading screen
  stays responsive.
- Main menu is pushed after data load and UI setup, but full save files are not
  loaded for the save list.
- Save browser reads only save/profile headers (`REC_SAVE`), not the whole save.
- Selected save load clears runtime state, reads the save records, rebuilds
  dynamic world/player state, then activates the saved cell.
- Cell refs are lazy: `CellStore::preload()` can list ref IDs without fully
  materializing scene objects.
- `CellPreloader` warms terrain, scene templates, keyframes, and collision
  shapes on worker threads with min/max/expiry eviction.
- Predictive preload includes adjacent exterior grid, teleport door
  destinations, and fast-travel destinations.

Copy the shape, not every implementation detail.

## Current Godotwind Shape

`scenes/Godotwind.tscn` uses `src/tools/world_explorer.gd` directly as the first
screen. That means process launch currently pays world-loading cost before the
player can reach any menu-like state.

The runtime already has good pieces:

- Persistent model prebake cache in `ModelLoader` (`.res`, `.mesh`,
  `.shapes.res`).
- `ResourceLoader.load_threaded_request()` path for models.
- `CellPreloader` with OpenMW-style velocity prediction, min/max cache size, and
  expiry.
- `LoadingBaselineReport` JSON attribution.
- Terrain, horizon maps, hydrology, static shapes, and impostors have prebake or
  cache infrastructure.

The obvious waste is source-data expansion:

- `ESMCache.Load()` reads all cached cells and all references into native
  objects, marking `ReferencesLoaded = true`.
- `ESMManager._populate_from_native()` then expands large native data into
  GDScript objects.
- `_supplement_actor_data()` reopens and scans the ESM in GDScript for CLAS,
  FACT, SKIL, BSGN, LEVC, BOOK, DIAL, INFO, and LIGH. This alone measured
  4.437s including populate time.

## Recommendation

### P0 - Split Main Menu From World Boot

Create a small `MainMenu.tscn` or boot shell that loads only:

- settings/data path/mod manifest,
- BSA archive indexes,
- save headers,
- enough ESM metadata to validate content and show menu data.

Do not instantiate `world_explorer.gd`, Terrain3D, streaming manager, cell
manager, horizon maps, or first-cell objects until New Game / Load Game.

Expected effect: process launch can become menu-fast even before world loading
is fully optimized. This is the highest UX win because it removes world work
from the first screen.

### P1 - Stop Rebuilding GDScript ESM State At Runtime

Make the native/C# ESM layer the runtime source of truth for records that do not
need mutable GDScript objects.

Minimal path:

- Move the `_supplement_actor_data()` target record types into the C# cache, or
  add a second native sidecar cache for them.
- Do not scan the ESM in GDScript on every launch.
- Replace eager GDScript dictionaries with native lookup APIs or lazy
  on-demand wrappers for records touched by gameplay/UI.
- Keep eager GDScript conversion only for tiny universal tables needed by the
  first screen.

Expected effect: remove most of the measured 4.437s supplement cost and reduce
the 2.411s native-cache expansion cost over time.

### P2 - Make ESM Cache Lazy Again

The source loader supports lazy refs, but the cache path currently reloads every
cached cell reference eagerly. Fix the cache format or add a startup metadata
cache:

- startup cache: record IDs, type indexes, exterior/interior cell metadata,
  LAND metadata needed for initial terrain decisions;
- lazy cell-ref pages: references loaded by cell key on demand;
- save/gameplay overlay: future mutable deltas layered over immutable source
  data.

Expected effect: startup no longer pays for every placed object in the world.
This matches OpenMW's `CellStore` model and avoids treating "cached" as
"expanded into RAM forever."

### P3 - Skip Terrain Texture Rebuilds When Cache Is Valid

Terrain cache files already exist, including the Morrowind terrain texture
bridge resource. Before rebuilding active regions, compare the source signature
and region/index-map signature. If the cached resource is valid, load it and
skip `rebuild_all_active_regions()`.

Expected effect: reduce the terrain/texture part of `_init_async` without new
infrastructure. Also split the timing label so "horizon maps" and "terrain
texture bridge" stop hiding each other.

### P4 - Prebake The First-Playable Manifest

During prebake, emit a compact manifest for the default/new-game start and any
known save/teleport targets:

- 3x3 starting-cell refs grouped by model path/type,
- static MID bucket descriptors,
- shape-pack paths,
- required terrain region/horizon/water cache keys,
- common player skeleton/anims once character creation exists.

At runtime, load this manifest directly instead of asking multiple systems to
rediscover the same first-cell facts.

Expected effect: reduce the 5.945s boot gate and the 1.980s accumulated
publication work by making the first active neighborhood a cache hit.

### P5 - Keep Preloading Bounded, Not Global

Do **not** add "load all assets once and keep forever." For Morrowind-scale data,
that trades loading time for RAM pressure and worse steady-state behavior.

Use three tiers instead:

- **Permanent session cache:** tiny universal assets and source indexes.
- **Bounded warm cache:** predicted cells, destination cells, and common
  first-playable assets with min/max/expiry policy.
- **Persistent prebake cache:** converted `.res`, `.mesh`, `.shapes.res`,
  terrain/horizon/hydrology outputs that survive across launches.

This aligns with Godot's `ResourceLoader` cache behavior and OpenMW's
preloader: reuse what is needed soon, evict what is not.

### P6 - Attribute The Two Large Gaps

The baseline has two suspicious gaps:

- 8.306s between `_ready()` and `_init_async` start.
- 6.291s between `_init_async` done and boot-gate start.

Before tuning budgets, add timestamps around:

- first `_update_loading()` await,
- loading overlay fade/tween,
- terrain node insertion/import,
- `_teleport_to_cell()`,
- `_setup_subsystem_toggles()`,
- `world_streaming_manager.set_camera(camera)`,
- first `_process` frame after tracking starts.

Expected effect: turns 14.597s of "gap" into named owners. Do this before
changing budgets.

## Godot 4.6 Constraints To Respect

- Use `ResourceLoader.load_threaded_request()` for resource background loading.
  `load_threaded_get()` can block if called before completion, so poll status
  over frames.
- `use_sub_threads=true` can make a load faster but may slow the main thread;
  use it only after measuring.
- `CACHE_MODE_REUSE` is the default and should stay the default for reusable
  immutable resources.
- Large worlds should be broken into smaller dynamically managed pieces; loading
  everything as one static scene is the naive memory-heavy path.
- Keep scene-tree mutation on the main thread; use workers for data/resource
  preparation.

References:

- Godot 4.6 `ResourceLoader`: https://docs.godotengine.org/en/4.6/classes/class_resourceloader.html
- Godot 4.6 background loading: https://docs.godotengine.org/en/4.6/tutorials/io/background_loading.html
- Godot 4.6 thread-safe APIs: https://docs.godotengine.org/en/4.6/tutorials/performance/thread_safe_apis.html
- Godot 4.6 loading/preloading and large-level guidance: https://docs.godotengine.org/en/4.6/tutorials/best_practices/logic_preferences.html

## Acceptance Checks

Track these as separate baselines:

1. Process launch -> main menu visible.
2. Main menu -> first playable new-game cell.
3. Save selection -> first playable saved cell, once save/load exists.
4. Teleport door -> first playable destination.

For each run, keep:

- loading JSON,
- command line,
- cache state,
- git commit,
- top five attributed owners.

Initial target:

- main menu visible under 5s on the current machine;
- first playable under 15s with current assets;
- no regression in streaming stability after the overlay hides.

## Shortest Implementation Order

1. Add a main-menu boot shell and stop launching `world_explorer.gd` as the first
   screen.
2. Add missing timestamps for the two baseline gaps.
3. Move `_supplement_actor_data()` record types out of the per-launch GDScript
   scan.
4. Split the terrain/horizon/texture timing labels and skip terrain texture
   region rebuilds when the cached resource is valid.
5. Split ESM cache into startup metadata and lazy cell-ref pages.
6. Emit first-playable manifests during prebake.
