# Distance Rendering

2-band render pipeline + octahedral impostor tier rendering Morrowind's open world at 60+ FPS across 5km view distance. Post-B-wide refactor (2026-04-10): LOD selection is fully engine-driven via `ImporterMesh.generate_lods()` + `ArrayMesh.surface_lod_indices` + screen-space coverage.

## Why engine-driven LOD

Pre-B-wide, every MID object held up to **4 RenderingServer instances** — one per authored LOD band (`_LOD0`/`_LOD1`/`_LOD2`/`_LOD3` sibling `MeshInstance3D`s), each with a hand-rolled `visibility_range` slice. Post-B-wide each object is **one** RS instance carrying the embedded LOD cascade, and Godot's C++ `RendererSceneCull` picks the level per frame from projected screen-space coverage. The canonical pattern is `ImporterMesh.generate_lods()` + `ArrayMesh.surface_lod_indices` + screen-space coverage driven by `mesh_lod_threshold` + `lod_bias` — the same pipeline glTF/FBX/OBJ importers use under the hood. The bespoke 4-RID cascade was reinventing (and fighting) the engine selector. See `docs/archive/plans/lod_refactor_b_wide.md` for the full migration plan.

## Tier Overview

| Tier | Range | Technique | Key File |
|------|-------|-----------|----------|
| NEAR | 0-150m | Full Node3D + physics in the scene tree | `cell_manager.gd` |
| MID | 0-300m (HLOD on) / 0-500m (HLOD off, fallback) | Single raw RS instance per object with embedded LOD chain, engine picks level from screen-space coverage | `static_object_renderer.gd` |
| HLOD | 300-1000m | One RS instance per paged chunk — runtime-merged static geometry with LOD chain. OpenMW-style adaptive chunk sizes (1×1 / 2×2 / 4×4 cells) per band | `object_paging.gd` |
| FAR | 1000-5km | Octahedral impostors, single MultiMesh draw call | `native_impostor_renderer.gd` |

**Source of truth:** `src/core/world/distance_utils.gd` — `NEAR_END=150`, `HLOD_START=300`, `HLOD_END=1000`, `FAR_START=HLOD_END=1000`, `FAR_END=5000`. MID's runtime cap is set on `static_object_renderer.visibility_range_end` (`static_object_renderer.gd:57-59`): defaults to `MID_END` (500m) and is lowered to `HLOD_START` (300m) when HLOD is active.

Constants defined in `src/core/world/distance_utils.gd`. Post-refactor, NEAR and MID share **one** visibility_range band (0-500m) on a single MeshInstance3D / RS instance, and Godot's C++ LOD selector picks which level of the embedded cascade to draw per frame. The NEAR/MID split is a *streaming-layer* concept (NEAR adds physics + scene-tree nodes), not a rendering-layer distinction.

## NEAR Tier (0-150m)

Full scene tree instantiation from ESM cell records. NIF models parsed (C#) and cached as `.res`.
- Object pooling (50 per type, 20% pre-warm)
- Characters get animated skeletons + state machines
- Flora routed to MID renderer instead (massive FPS win)
- Lights: animated (flicker/pulse) stay as `OmniLight3D` Node3D so `LightAnimator`'s scene-tree walker drives the per-frame energy modulation; static lights go server-direct via `RS.omni_light_create` + `RS.instance_create` (Win 4b 2026-04-25). Lazy-spawn at 60m for small lights, always-spawn for big lights (radius ≥ 700 MW units ≈ 10m Godot range) so braziers stay visible. RID lifetime managed by a `LightRids` RefCounted attached as `rs_light_rids` metadata on the light's container Node3D — its `NOTIFICATION_PREDELETE` handler frees both RIDs when cell teardown queue_frees the container. See `reference_instantiator.gd::_attach_server_direct_light` + `_attach_animated_omni_light`.
- Cell static collision: per-cell merged trimesh body via `PhysicsServer3D.body_create()` + `body_add_shape` (Win 2 2026-04-25, server-direct — replaced the previous `StaticBody3D` Node3D). Triangle assembly + transform math runs on a `WorkerThreadPool` task off-thread (Win 1); main thread only does the `ConcavePolygonShape3D.set_faces` BVH build + body register. Closest-cell-first drain order (Win 3). Body lifetime tracked on `AsyncCellRequest.collision_body` (a `FinalizedBody` RefCounted holding `body_rid` + Shape3D strong-ref); freed in `_drain_collision_worker_for_request` from cancel/unload/shutdown paths. See `cell_static_collision.gd` + `cell_manager.gd::_tick_static_collision_build`. Caveat: server-direct bodies do NOT show up in Godot's "Visible Collision Shapes" overlay — counts surface via the dev console.

MID→NEAR promotion pre-creates Node3Ds at 250m while they are invisible, then enables them + their collision shapes once the camera enters the 155m visibility band. Demotion frees them again at 280m (20m hysteresis). Post-B-wide: promotion simply hides the single MID RS instance — there is no per-LOD RID fan-out to walk.

## MID Tier (0-300m with HLOD on, 0-500m fallback)

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

### MultiMesh batching vs HLOD

These two draw-call reduction strategies operate on **different distance bands and are complementary, not alternatives**:

- **MultiMesh batching** — "same mesh type batched for one draw call inside the MID band." Groups all MID-tier RS instances of the *same mesh* into a single `MultiMesh` resource so the GPU draws them via one `DrawIndexedInstanced` call. Each instance keeps its own transform; no geometry merging. Targets the 150-300m slice (when HLOD is on).
- **HLOD chunk merging** — "a chunk merged into one composite mesh for the far band." Merges the static geometry of multiple objects within a chunk into a *single combined ArrayMesh* with its own LOD chain, then one RS instance per chunk. Unreal's HISM / Unity's StaticBatchingUtility pattern. Targets 300-1000m.

They stack: MultiMesh collapses the near-distance draw-call cost without touching geometry, HLOD collapses the far-distance draw-call cost by combining geometry. Together: ~500 (MultiMesh) + ~50 (HLOD chunks) + 200 (NEAR) + 1 (impostors) ≈ 750 draw calls total at full world load.

## HLOD Tier (300-1000m)

Cell-level merged geometry. At prebake time, all mid-worthy static objects in each cell are merged into a single ArrayMesh with LOD chain. At runtime, one RS instance per cell replaces ~100+ individual RS instances.

Key details:
- **Prebake:** `model_prebaker.gd::bake_cell_hlod()` merges all mid-worthy refs (STAT, DOOR, CONT, ACTI) per cell. Vertices transformed into cell-local space. Surfaces grouped by material for dedup. `ImporterMesh.generate_lods(60.0, 25.0, [])` generates LOD chain.
- **Cache:** `Documents/Godotwind/cache/hlod/cell_{x}_{y}.res` — one ArrayMesh per cell.
- **Runtime:** `object_paging.gd` loads/unloads HLOD meshes as camera crosses cells. RS instance positioned at cell origin with `visibility_range(300, 1000, 20m, 20m, FADE_SELF)`.
- **Transition:** At 300m, individual MID RS instances fade out (visibility_range_end=300m), HLOD mesh fades in. At 1000m, HLOD fades out, impostors take over.
- **Fallback:** When HLOD cache does not exist, MID instances keep their 0-500m range and impostors start at 500m. System degrades gracefully.
- **Bake trigger:** Console command `bake_hlod` in world explorer. Takes several minutes for ~2500 cells.
- **Based on:** OpenMW `objectpaging.cpp` (FLATTEN_STATIC_TRANSFORMS + MERGE_GEOMETRY), adapted for Godot RS API.

Constants in `distance_utils.gd`: `HLOD_START=300m`, `HLOD_END=1000m`.

### Runtime ObjectPaging

`src/core/world/object_paging.gd` — distance-adaptive OpenMW-style chunk pager. Three-tier adaptive walker:

| size_level | chunk footprint | band | source LOD |
|------------|-----------------|------|------------|
| 0 | 1×1 cell | [150, 300)m | LOD 0 |
| 1 | 2×2 cells | [300, 600)m | LOD 1 |
| 2 | 4×4 cells | [600, 1000)m | LOD 2 |

Replaces `is_mid_worthy` keyword filter with a projected-size test (`radius² × scale² < dist² × PAGING_MIN_SIZE²`, OpenMW canonical `PAGING_MIN_SIZE = 0.14`). Adds per-mesh-type cost-benefit merge decision, tier-hysteresis retention (20m), teleport warmup (prototype preload on camera jumps >500m), and a second-pass `minSizeMergeFactor` filter that trims tiny refs from merged types based on merge-benefit. Merge kernel lives in `src/native/NativeObjectPagingKernel.cs` (C# hot path).

**Status 2026-04-16:** Confirmed working; enabled by default via `hlod_enable`. See `docs/systems/object_paging.md` for the current design and `docs/archive/sessions/object_paging_*` for historical bug-fix context.

Console: `hlod_enable` / `hlod_disable`.

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
- Design doc: `docs/plans/impostor_rebuild.md`

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
