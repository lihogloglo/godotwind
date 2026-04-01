# Distance Rendering

3-tier LOD system rendering Morrowind's open world at 60+ FPS across 5km view distance.

## Tier Overview

| Tier | Range | Technique | Key File |
|------|-------|-----------|----------|
| NEAR | 0-150m | Full Node3D + physics | `cell_manager.gd` |
| MID | 150-500m | RenderingServer instances, 3 LOD sub-bands | `static_object_renderer.gd` |
| FAR | 500-5km | Octahedral impostors, single MultiMesh draw call | `native_impostor_renderer.gd` |

Constants defined in `src/core/world/distance_utils.gd`.

## NEAR Tier (0-150m)

Full scene tree instantiation from ESM cell records. NIF models parsed (C#) and cached as `.res`.
- Object pooling (50 per type, 20% pre-warm)
- Characters get animated skeletons + state machines
- Flora routed to MID renderer instead (massive FPS win)
- Lights created as OmniLight3D (MW radius scaled 1/70)

## MID Tier (150-500m)

Bypasses the scene tree entirely. Uses `RenderingServer.instance_create()` with per-instance visibility ranges.

3 LOD sub-bands with fade margins:
| Sub-band | Range | Fade Margin |
|----------|-------|-------------|
| LOD1 | 150-250m | 5m |
| LOD2 | 250-375m | 10m |
| LOD3 | 375-500m | 15m |

Key details:
- `instance_geometry_set_visibility_range()` with `VISIBILITY_RANGE_FADE_SELF` for smooth transitions
- Godot auto-batches identical mesh+material RS instances in C++ — zero GDScript overhead
- If LOD1/2/3 share the same mesh RID, range collapses to single band (avoids redundant instances)
- **Must hold strong refs** to Mesh/Material resources — LRU cache eviction frees resources, invalidating RIDs silently

## FAR Tier (500-5km)

Custom octahedral impostor system (Godot has no built-in equivalent).
- Single MultiMeshInstance3D renders all FAR objects in one draw call
- Albedo + normal maps packed into parallel Texture2DArray
- Per-impostor transforms stored in MultiMesh custom data
- Visibility range: begin=480m, end=5km (set on the MultiMeshInstance3D)
- Texture array rebuild debounced (0.2s after last add, 0.5s min between rebuilds)
- **MultiMesh rebuild uses `set_buffer(PackedFloat32Array)`** — single bulk upload instead of N×2 RS calls
- **Differential impostor area update** — on cell crossing, only scans border strip (~242 cells) instead of full 14K grid. Cost: ~1ms per crossing (was 14-158ms)
- ~63K impostors across ~497 texture layers at full load. ~40% are ≤2px on screen (filtering candidate)

## Streaming Orchestration

`native_streaming_manager.gd` coordinates all tiers:
- Camera cell tracked, 3-cell radius loaded async
- **Shared 8ms/frame budget** across all streaming phases (was independent budgets per phase)
- Cells queued by frustum priority (4x penalty for behind-camera)
- Budgeted unloading: RS instances immediately hidden (`instance_set_visible(false)`), then `free_rid()` deferred across frames
- Promoted object cleanup uses spatial index (`_promoted_by_cell` dict, O(1) per cell)
- Per-phase timing instrumentation with overrun logging: `[unload:X async:X inst:X promo:X coll:X defer:X queue:X]`
- 20-frame startup stagger prevents initial spike

## Tier Transitions

All LOD switching handled by Godot's C++ visibility_range checks — no GDScript per-frame polling.
Hysteresis via fade margins prevents oscillation at tier boundaries.

## Anti-Patterns

- Don't set `visibility_range_end_margin` without `_begin_margin` — causes flicker
- Don't call RS functions that return values every frame — stalls async pipeline
- Don't skip `wait_for_task_completion()` on WorkerThreadPool — memory leaks
- Don't let LRU cache evict prototypes while RS instances reference their RIDs
