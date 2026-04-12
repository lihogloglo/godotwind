# Distance Rendering

2-band render pipeline + octahedral impostor tier rendering Morrowind's open world at 60+ FPS across 5km view distance. Post-B-wide refactor (2026-04-10): LOD selection is fully engine-driven via `ImporterMesh.generate_lods()` + `ArrayMesh.surface_lod_indices` + screen-space coverage. See `docs/audit/LOD_REFACTOR_B_WIDE.md` for the migration story.

## Tier Overview

| Tier | Range | Technique | Key File |
|------|-------|-----------|----------|
| NEAR | 0-150m | Full Node3D + physics | `cell_manager.gd` |
| MID | 0-300m* | Single raw RS instance per object with embedded LOD chain, engine picks level from screen-space coverage | `static_object_renderer.gd` |
| HLOD | 300-1000m | One RS instance per cell — merged static geometry with LOD chain | `hlod_loader.gd` |
| FAR | 1000-5km | Octahedral impostors, single MultiMesh draw call | `native_impostor_renderer.gd` |

\* MID range is 0-500m when HLOD cache is not available (graceful fallback).

Constants defined in `src/core/world/distance_utils.gd`. Post-refactor, NEAR and MID share **one** visibility_range band (0-500m) on a single MeshInstance3D / RS instance, and Godot's C++ LOD selector picks which level of the embedded cascade to draw per frame. The NEAR/MID split is a *streaming-layer* concept (NEAR adds physics + scene-tree nodes), not a rendering-layer distinction.

## NEAR Tier (0-150m)

Full scene tree instantiation from ESM cell records. NIF models parsed (C#) and cached as `.res`.
- Object pooling (50 per type, 20% pre-warm)
- Characters get animated skeletons + state machines
- Flora routed to MID renderer instead (massive FPS win)
- Lights created as OmniLight3D (MW radius scaled 1/70)

MID→NEAR promotion pre-creates Node3Ds at 250m while they are invisible, then enables them + their collision shapes once the camera enters the 155m visibility band. Demotion frees them again at 280m (20m hysteresis). Post-B-wide: promotion simply hides the single MID RS instance — there is no per-LOD RID fan-out to walk.

## MID Tier (150-500m)

Bypasses the scene tree. Uses `RenderingServer.instance_create() + instance_set_base()` — **one** RS instance per object, holding the embedded LOD chain.

Key details:
- **Prebake merge:** `model_prebaker.gd` merges all visible MeshInstance3D children of a prototype into a single ArrayMesh at prebake time (vertices/normals transformed into root space, inverse-transpose for normals). Multi-material buildings (3-8 child meshes for walls/roof/door) become one mesh with N surfaces. Character models are excluded (skeleton hierarchy preserved).
- `ImporterMesh.generate_lods(60.0, 25.0, [])` runs on the merged mesh, producing a 4-5 level LOD cascade covering the entire building in one embedded chain.
- `ArrayMesh.set_meta("has_lod_chain", true)` stamped at bake time so cache-scan tooling can tell whether a `.res` file is new-format.
- Single visibility_range band on the RS instance: `0 → DU.MID_END (500m)`, `end_margin=20m`, `VISIBILITY_RANGE_FADE_SELF`. The 20m margin provides the dither crossfade into the impostor tier.
- `instance_geometry_set_lod_bias(rid, 1.0)` — per-instance LOD bias (tunable later via a per-type registry in `streaming_config.gd`).
- Sub-LOD selection is driven by Godot's C++ `RendererSceneCull` from the projected screen-space size of the object's bounding volume, resolution- and FOV-aware. Threshold controlled by `viewport.mesh_lod_threshold` (default 1.0 px, quality presets override to 0.5-4.0 px).
- Godot auto-batches identical mesh+material RS instances in C++ — zero GDScript overhead.
- **Must hold strong refs** to Mesh/Material resources — LRU cache eviction frees resources, invalidating RIDs silently.
- **Fallback multi-RID path:** if a cached prototype still has multiple MeshInstance3D children (character models, edge cases), `static_object_renderer.gd` creates one RS instance per child via `SubMeshEntry`, each preserving its own LOD chain. All tracked under a single instance ID.

**RS instance count impact:** pre-refactor each MID object had up to 4 RS instances (LOD0/LOD1/LOD2/LOD3 with per-band visibility_range). Post-refactor each object has 1 RS instance (prebake-merged) or N RS instances (multi-mesh fallback, N = child count, typically 1-8). At ~63k MID-tier objects, the prebake merge path eliminates ~189k RIDs and ~189k per-frame culling tests.

## HLOD Tier (300-1000m)

Cell-level merged geometry. At prebake time, all mid-worthy static objects in each cell are merged into a single ArrayMesh with LOD chain. At runtime, one RS instance per cell replaces ~100+ individual RS instances.

Key details:
- **Prebake:** `model_prebaker.gd::bake_cell_hlod()` merges all mid-worthy refs (STAT, DOOR, CONT, ACTI) per cell. Vertices transformed into cell-local space. Surfaces grouped by material for dedup. `ImporterMesh.generate_lods(60.0, 25.0, [])` generates LOD chain.
- **Cache:** `Documents/Godotwind/cache/hlod/cell_{x}_{y}.res` — one ArrayMesh per cell.
- **Runtime:** `hlod_loader.gd` loads/unloads HLOD meshes as camera crosses cells. RS instance positioned at cell origin with `visibility_range(300, 1000, 20m, 20m, FADE_SELF)`.
- **Transition:** At 300m, individual MID RS instances fade out (visibility_range_end=300m), HLOD mesh fades in. At 1000m, HLOD fades out, impostors take over.
- **Fallback:** When HLOD cache does not exist, MID instances keep their 0-500m range and impostors start at 500m. System degrades gracefully.
- **Bake trigger:** Console command `bake_hlod` in world explorer. Takes several minutes for ~2500 cells.
- **Based on:** OpenMW `objectpaging.cpp` (FLATTEN_STATIC_TRANSFORMS + MERGE_GEOMETRY), adapted for Godot RS API.

Constants in `distance_utils.gd`: `HLOD_START=300m`, `HLOD_END=1000m`.

## FAR Tier (1000-5km)

Custom octahedral impostor system (Godot has no built-in equivalent).
- Single MultiMeshInstance3D renders all FAR objects in one draw call
- Albedo + normal maps packed into parallel Texture2DArray
- Per-impostor transforms stored in MultiMesh custom data (INSTANCE_CUSTOM: .x=albedo layer, .y=yaw rad, .z=normal layer, .w=variant)
- Two shader variants via INSTANCE_CUSTOM.w: v4 (legacy azimuthal 16-frame 4x4) and v5 (octahedral tri-sample 8x8, Brucks barycentric blending, yaw-rotated normals)
- Visibility range: begin=980m (with HLOD) or 480m (without HLOD), end=5km, begin_margin=20m, end_margin=20m, FADE_SELF (set on the MultiMeshInstance3D)
- Shadow receive YES, shadow cast NO (avoids billboard shadow artifacts at distance)
- Texture array rebuild debounced (0.2s after last add, 0.5s min between rebuilds)
- **MultiMesh rebuild uses `set_buffer(PackedFloat32Array)`** — single bulk upload instead of N×2 RS calls
- **Differential impostor area update** — on cell crossing, only scans border strip (~242 cells) instead of full 14K grid. Cost: ~1ms per crossing (was 14-158ms)
- ~63K impostors across ~497 texture layers at full load. ~40% are ≤2px on screen (filtering candidate)
- Inline shader in `native_impostor_renderer.gd::_get_octahedral_shader_code()` (~240 lines). Standalone `octahedral_impostor.gdshader` deleted (was dead code).
- Baker: `impostor_baker_v3.gd` (v5 octahedral). Legacy `impostor_baker_v2.gd` (v4 azimuthal) still present for reference.
- Design doc: `docs/audit/IMPOSTOR_REBUILD.md`

## Streaming Orchestration

`native_streaming_manager.gd` coordinates all tiers:
- Camera cell tracked, 3-cell radius loaded async
- **Shared 8ms/frame budget** across all streaming phases (was independent budgets per phase)
- Cells queued by frustum priority (4x penalty for behind-camera)
- Predictive preload from EMA-smoothed camera velocity
- Budgeted unloading: RS instances immediately hidden (`instance_set_visible(false)`), then `free_rid()` deferred across frames
- Promoted object cleanup uses spatial index (`_promoted_by_cell` dict, O(1) per cell)
- Per-phase timing instrumentation with overrun logging: `[unload:X async:X inst:X promo:X coll:X defer:X queue:X]`
- 20-frame startup stagger prevents initial spike

## LOD tuning (runtime console commands)

`src/tools/lod_debug_commands.gd` registers:
- `lod_threshold <value>` — get or set `viewport.mesh_lod_threshold` (pixels). Lower = higher quality.
- `lod_bias_global <bias>` — sweep `RenderingServer.instance_geometry_set_lod_bias` on every currently-loaded MID-tier RS instance.
- `lod_info` — dump viewport threshold + mesh type count + instance count + how many mesh types carry an embedded LOD chain.

Quality presets in `streaming_config.gd::get_quality_preset_config` drive `mesh_lod_threshold`: LOW=4.0, MEDIUM=2.0, HIGH=1.0, ULTRA=0.5 px.

## Tier Transitions

All LOD switching + tier hard-cull handled by Godot's C++ visibility_range checks — no GDScript per-frame polling. Hysteresis via `visibility_range_*_margin` (20m at the render→impostor boundary) prevents oscillation.

## Anti-Patterns

- Don't set `visibility_range_end_margin` without `_begin_margin` — causes flicker
- Don't call RS functions that return values every frame — stalls async pipeline
- Don't skip `wait_for_task_completion()` on WorkerThreadPool — memory leaks
- Don't let LRU cache evict prototypes while RS instances reference their RIDs
- **Don't write per-LOD visibility_range sub-bands.** Post-B-wide refactor, every MID object is a single RS instance with the embedded cascade; manual per-band cascades fight the engine's screen-space selector. If you need more aggressive LOD switching for a type, set its `lod_bias < 1.0` via `instance_geometry_set_lod_bias`.
- **Don't expect `ArrayMesh.surface_get_lod_count()` to work in 4.6.** The scripting API doesn't expose it — use `mesh.has_meta("has_lod_chain")` (set at bake time by `nif_converter::_generate_lod_chain`) as the detection heuristic.
