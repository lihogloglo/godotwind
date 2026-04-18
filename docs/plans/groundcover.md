# Groundcover System Plan

**Status:** Proposal — not yet implemented
**Owner:** @groundcover
**Drafted:** 2026-04-09
**Related:** `docs/systems/distance_rendering.md`, `src/core/world/static_object_renderer.gd`, `src/core/world/distance_utils.gd`

---

## Goal

Ship a data-driven groundcover (grass + small foliage) renderer for Godotwind that sources from Morrowind groundcover ESP files (Remiros, Aesthesia, Vurt family) and renders them efficiently in Godot 4.6. Match OpenMW visual density and wind behavior without over-engineering.

**Non-goals:** artist paint tooling, physics on grass, shadow-casting grass, per-instance LOD, custom GPU compute scatter, Terrain3D instancer integration.

---

## Research — What We Looked At

### OpenMW reference implementation

Source paths (in `inspos/openmw/`):

- `apps/openmw/mwrender/groundcover.hpp` / `.cpp` — renderer, quadtree `ChunkManager` integration, instancing, culling callbacks.
- `apps/openmw/mwworld/groundcoverstore.hpp` / `.cpp` — ESM parsing, per-cell ref context map, mesh cache.
- `components/settings/categories/groundcover.hpp` — config knobs.
- `files/shaders/compatibility/groundcover.vert` / `.frag` — wind harmonics, stomp, alpha fade.

Key architectural facts from the OpenMW source:

1. **Separate ESP registration.** Groundcover mods are loaded via `groundcover=` entries in `openmw.cfg`, distinct from `content=`. Parser filters static records whose NIF mesh path begins with `grass/` (`groundcoverstore.cpp:27-42`). Builds `mMeshCache: RefId → mesh path` and `mCellContexts: (cellX,cellY) → vector<ESM_Context>` for lazy per-cell reads.
2. **Placement is deterministic and ref-driven.** No random scatter. Instance transforms come straight from cell refs (`pos`, `rot`, `scale`). A `DensityCalculator` accumulator (`groundcover.cpp:262-288`) deterministically drops instances to hit a density target in `[0,1]`. Reproducible across sessions.
3. **Streaming uses the terrain quadtree.** `MWRender::Groundcover` implements `Terrain::QuadTreeWorld::ChunkManager`. Each chunk = square tile sized by terrain LOD level. Chunks iterate the cells in their bounds, pull the cached ESM contexts, and build per-mesh instance batches. Border clipping via `isInChunkBorders()` avoids double-placing refs that straddle chunk edges.
4. **GPU instancing, one draw call per (mesh, chunk).** Per-instance attributes `aOffset (vec4 = pos.xyz, scale)` and `aRotation (vec3)` bound to attrib slots 6 and 7 with `VertexAttribDivisor(1)` (`groundcover.cpp:251-252, 361-368`).
5. **Dual culling.** (a) Chunk-level: `ViewDistanceCallback` uses `Terrain::distance(box, eyePoint) <= viewDistance` (`groundcover.cpp:290-307`). Default view distance is 6144 MW units ≈ 87 m. (b) Per-instance frustum via `InstancedComputeNearFarCullCallback` in OSG (`groundcover.cpp:48-191`), also handles shadow-pass near/far computation.
6. **Wind is vertex-shader only.** Four-harmonic sum of sin/cos in `groundcover.vert:62-102`, world-position seeded, scaled by blade height so roots stay planted:
   ```glsl
   harmonics += (1.0 - 0.10*v) * sin(1.0*osg_SimulationTime + worldpos.xy / 1100.0);
   harmonics += (1.0 - 0.04*v) * cos(2.0*osg_SimulationTime + worldpos.xy / 750.0);
   harmonics += (1.0 + 0.14*v) * sin(3.0*osg_SimulationTime + worldpos.xy / 500.0);
   harmonics += (1.0 + 0.28*v) * sin(5.0*osg_SimulationTime + worldpos.xy / 200.0);
   ```
   Displacement clamped to `0.02 * vertex.z`. Player stomp is a distance-based falloff on top of that.
7. **Fade via shader macros** `@groundcoverFadeStart` / `@groundcoverFadeEnd`. Alpha test at `128/255` enforced globally (`groundcover.cpp:357`, `groundcover.frag:59`).
8. **Config is tiny.** `enabled`, `density (0..1)`, `rendering distance`, `stomp mode (0-2)`, `stomp intensity (0-2)`. That is the entire public surface.
9. **No physics, no collision, no interaction body.** Pure render subsystem.

### Industry-standard convergent pattern

Cross-checked against Unreal, Unity, CryEngine/Frostbite, Witcher 3 / RDR2:

- **Unreal:** Foliage tool + Hierarchical Instanced Static Mesh (HISM), procedural foliage spawner, Nanite for dense grass. Density from landscape layer weights.
- **Unity HDRP/URP:** Terrain detail prototypes + GPU instancing, recent shift to compute-driven scatter. Density from splat layers.
- **CryEngine / Frostbite:** Vegetation editor, GPU compute scatter, tile-based view-distance management, density from terrain splat layers.
- **Witcher 3 / RDR2:** Chunked tiles around camera, deterministic hash scatter from heightmap + splat, vertex-shader wind, distance fade.

**Convergent pattern across all of them:** chunked instancer tiles around camera + GPU instancing + per-splat (or per-ref) density + vertex-shader wind + distance fade.

OpenMW matches this pattern exactly, with the only difference that density inputs come from authored cell refs rather than a splat map. For Godotwind this is the right shape, because our data source is the same.

### Terrain3D v1.0.1 built-in instancer — evaluated and rejected

`addons/terrain_3d/` ships a foliage system:

- Classes: `Terrain3DInstancer`, `Terrain3DAssets`, `Terrain3DMeshAsset` (max 32 mesh slots).
- README claim: 10 LOD levels + shadow impostor (`addons/terrain_3d/README.md:13`).
- Authoring: editor brush-paint, artist places meshes interactively like terrain texture (`addons/terrain_3d/src/asset_dock.gd:482-542`).
- Storage: baked per-terrain-region inside Terrain3D data files.
- Wind / fade: not exposed in the addon API.

**Verdict: wrong tool for our use case.** Our groundcover data is ref-driven from ESM groundcover ESPs, not artist-authored brush strokes. Using `Terrain3DInstancer` would require a converter step that bakes ESM refs into paint data, which defeats streaming and couples groundcover state to Terrain3D region serialization. We would also inherit whatever limitations its shader pipeline has with no way to drop in the OpenMW wind math. Skip it.

### Existing in-tree code

- `src/core/world/static_object_renderer.gd` — our RenderingServer-based static renderer with `visibility_range` LOD. Already used for flora indirectly via `src/core/world/reference_instantiator.gd`.
- No groundcover-specific system yet.
- `src/core/world/distance_utils.gd` — single source of truth for tier distances. Groundcover distance constants will live here.

---

## Design — Canonical Godot Pattern, No Over-Engineering

Mirror OpenMW architecture using Godot primitives. The Godot engine hands us `MultiMeshInstance3D` + `visibility_range` for free, so the total line count drops by roughly a factor of 10 compared to the OpenMW C++ implementation while preserving the visual behavior.

### 1. Data layer — `GroundcoverStore`

- New autoload-sibling manager (not itself an autoload — owned by world streaming). Parses groundcover ESP files separately from main content, mirroring OpenMW's `groundcover=` distinction.
- Filters statics where NIF mesh path starts with `grass/` (or our equivalent prefix — TBD during implementation after inspecting Remiros/Aesthesia archives).
- Builds:
  - `mesh_cache: Dictionary[StringName, PackedScene]` — RefID to preloaded/prebaked grass mesh.
  - `cell_refs: Dictionary[Vector2i, Array[GroundcoverRef]]` — per-cell-grid-coord list of transforms.
- Leverages existing `ESMManager` grid-indexed lookup. No separate file-I/O threading — groundcover ESPs are small and can be parsed on load.
- `GroundcoverRef` = `{ ref_id: StringName, position: Vector3, rotation: Basis, scale: float }`. Inner class, no file explosion.

### 2. Streaming — piggyback on cell streaming

- One `MultiMeshInstance3D` per `(cell_coord, ref_id)` pair, parented under the existing streamed cell root node.
- Spawn when cell enters the groundcover distance radius, despawn when it leaves, with hysteresis matching existing streaming constants. No new quadtree — the MW cell grid already IS the quadtree.
- Chunk size = 1 MW cell. If profiling shows draw-call pressure, merge to 2x2 cells. Decision deferred until profiling data exists.

### 3. Render — `MultiMeshInstance3D` with engine culling

- `MultiMesh.transform_format = TRANSFORM_3D`, `use_colors = false`, `use_custom_data = false` unless we later need per-instance wind phase.
- Engine `visibility_range_end = GROUNDCOVER_DISTANCE` (constant added to `distance_utils.gd`, initial value 100 m, tunable).
- `visibility_range_end_margin` set for fade-out.
- `cast_shadow = SHADOW_CASTING_SETTING_OFF` by default. Re-evaluate after first visual pass.
- Engine handles frustum culling and distance culling per MMI. No custom cull code. Canonical Godot pattern.

### 4. Shader — port OpenMW wind math

- Custom `ShaderMaterial` extending the standard spatial shader, vertex pass only.
- Implement the four-harmonic wind sum from `groundcover.vert:62-102` in Godot shader syntax, using `TIME` in place of `osg_SimulationTime` and world XZ in place of `worldpos.xy`.
- Height mask via vertex `Y` so the base of the blade stays planted. OpenMW's `0.02 * vertex.z` clamp ports directly (our axis mapping via `coordinate_system.gd`).
- Alpha-to-coverage for foliage edges (Godot's `ALPHA_SCISSOR_THRESHOLD` + MSAA, or `ALPHA_HASH` if MSAA is off).
- Stomp/player-displacement is deferred to Phase 2. MVP ships without it.
- Target: ~40 shader lines total.

### 5. Density knob — port `DensityCalculator`

- Port the accumulator logic from `groundcover.cpp:262-288` verbatim. About 20 lines in GDScript.
- Deterministic: same seed + same density value = same kept instances.
- Exposed via `SettingsManager` as `groundcover_density` in `[0, 1]`, default 1.0.

### 6. Config surface

Mirror OpenMW minus stomp (MVP):

- `groundcover_enabled: bool`
- `groundcover_density: float` in `[0, 1]`
- `groundcover_distance: float` in meters

All three live in `SettingsManager`. Stomp is Phase 2.

---

## What We Explicitly Do NOT Build

Following the "Simplicity Over Over-Engineering" principle in `CLAUDE.md`:

- **No GPU compute scatter.** Our data is already ref-driven; compute scatter would replace a solved problem with an unsolved one.
- **No custom frustum culler.** Godot's `VisibleOnScreenNotifier3D` + `MultiMeshInstance3D` culling is sufficient.
- **No per-instance LOD.** One LOD + distance fade matches OpenMW ship state.
- **No custom quadtree.** The MW cell grid IS the quadtree.
- **No Terrain3D integration.** Wrong authoring model.
- **No editor paint tool.** Data-driven only.
- **No physics, no collision, no Area3D queries on grass.** Pure render.
- **No shadow casting in MVP.** Evaluate only if the visual demands it.
- **No stomp in MVP.** Phase 2 if we want it.

---

## File Plan

New files:

- `src/core/world/groundcover/groundcover_store.gd` — ESP parsing, mesh cache, ref map. ~150 lines.
- `src/core/world/groundcover/groundcover_renderer.gd` — MultiMeshInstance3D spawn/despawn keyed to cell streaming. ~150 lines.
- `src/core/world/groundcover/density_calculator.gd` — deterministic density filter, inner class or standalone. ~30 lines.
- `src/core/world/groundcover/groundcover_ref.gd` — ref data class. ~20 lines.
- `src/core/shaders/groundcover.gdshader` — wind-animated foliage shader. ~40 lines.

Touched files:

- `src/core/world/distance_utils.gd` — add `GROUNDCOVER_DISTANCE` constant.
- `autoload/settings_manager.gd` — add three new settings keys with defaults.
- World streaming owner (TBD during implementation) — wire `GroundcoverRenderer` into cell load/unload signals.

**Total MVP scope: ~400 GDScript lines + 40 shader lines.**

---

## Phases

**Phase 1 — MVP (this plan).**
Data layer + streaming + MultiMesh renderer + wind shader + density knob. Ships with a single grass mod (Remiros or Aesthesia, pick one) to validate end-to-end before multi-mod merge.

**Phase 2 — Polish (after profiling).**
- Player stomp displacement (port `groundcover.vert:78-99`).
- Optional shadow casting, guarded by a setting.
- Multi-mod merging with ref deduplication.
- 2x2 cell chunk merging if draw calls become a bottleneck.

**Phase 3 — Stretch.**
- Wind direction tied to weather system (if one lands).
- Color variation from a noise texture, per-instance.

Phase 2 and 3 are not committed. Phase 1 is the only scope on the table right now.

---

## Open Questions

1. Which grass mod ships as the reference set? Remiros (canonical), Aesthesia (denser), or Vurt (stylized)? Need user decision before Phase 1 starts.
2. What is the NIF mesh-path prefix used by the chosen mod? OpenMW uses `grass/`, but we need to confirm against the actual files in the user's MW install.
3. Does our existing NIF converter handle grass NIFs cleanly? Grass meshes are usually very simple (one or two quads with alpha texture), but the converter path should be sanity-checked against one sample before committing to MultiMesh ingestion.

---

## Acceptance Criteria (Phase 1)

- Groundcover renders within 100 m of the camera on at least two exterior cells of the reference mod.
- Wind animation is visible and runs at 60 FPS on the dev machine with density = 1.0.
- Toggling `groundcover_enabled` and sliding `groundcover_density` works at runtime without restart.
- Streaming correctly spawns/despawns MMIs as the camera crosses cell boundaries — no leaked nodes, no missing grass on reload.
- No frame budget regression in the existing cell streaming path (budget remains 2 ms/frame per `CLAUDE.md`).
