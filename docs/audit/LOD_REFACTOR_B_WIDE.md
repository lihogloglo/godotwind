# LOD System B-Wide Refactor — Canonical Pattern Migration

**Status:** In progress — Session 2.5 end state (2026-04-10). Phases **B.0 → B.1 → C → D → E → F (partial)** all landed in working tree on `refactor/lod-b-wide`, all 35 unit tests green. **Phase G (full rebake + structural verification) partially executed**: full cache rebake succeeded (4884 / 4948 models, 154s, 64 pre-existing parser failures unchanged), 3 structural baselines re-ran and confirm the "Bug A — 4 of 5 sub-meshes dropped" is fixed. **Main-scene launch reproduced a signal 11 crash after ~2 min of unattended running** — crash investigation deferred by user ("we'll debug all that later"). Interactive visual pass + `StreamingBenchmark` perf diff + final doc sync still pending. Phase A.5 (NIF collision coordinate fix bundle) still pending. See Session 2 + Session 2.5 entries in the Progress Log for the full rundown, including the crash hypothesis ladder and next-debug-session recipe.
**Owner:** `@lods` (claude)
**Scope:**
- Delete the hand-rolled LOD pipeline (`_add_visibility_range_lods` in `src/core/nif/nif_converter.gd`, all of `src/core/world/lod_configurator.gd`, sibling `_LODn` node convention, per-LOD `RenderingServer` instance cascade in `src/core/world/static_object_renderer.gd`)
- Replace with Godot 4.6's native `ImporterMesh.generate_lods()` + `ArrayMesh.surface_lod_indices` + automatic C++ screen-space LOD selection
- Preserve the streaming orchestration layer (`native_streaming_manager.gd`, `cell_manager.gd`) untouched — it is the good part of the system
- Preserve the FAR-tier impostor system — independent refactor owned by `@impostors`

**Related documents:**
- `docs/audit/LOD_OVER_ENGINEERING.md` — the Session 0 diagnosis this plan follows from
- `docs/audit/NIF_COLLISION_COORDINATE_BUG.md` — adjacent NIF import bug (collision-side asymmetric coordinate conversion), to be bundled on `refactor/lod-b-wide` per `@roaster` sequencing advice — see Part 5 Phase A.5
- `docs/DISTANCE_RENDERING.md` — current 3-tier behavior (will need rewrite after Phase G)
- `docs/audit/IMPOSTOR_REBUILD.md` — concurrent FAR-tier work, out of scope here but must not be broken
- `docs/audit/AAA_FRAMEWORK_PLAN.md` §1 (streaming), §2 (rendering)
- `docs/audit/MASTERPLAN.md` — Phase 2 Core Foundation
- `.claude/CLAUDE.md` "Industry Standard, Never Kludge" + "Simplicity Over Over-Engineering" — the principles this refactor enforces

---

## TL;DR

Godotwind's current 3-tier LOD scheme — sibling `_LOD1/2/3` `MeshInstance3D` nodes created at NIF prebake time, loaded from cache, and rendered via 4 parallel `RenderingServer` instances per object with hand-computed `visibility_range` bands — is a 17-file, ~1,500-line hand-rolled reimplementation of features Godot 4.6 ships natively:

1. `ImporterMesh.generate_lods()` — produces `ArrayMesh` with embedded `surface_lod_indices`, exactly what glTF/FBX/OBJ importers use
2. Viewport `mesh_lod_threshold` + per-instance `lod_bias` — automatic FOV-aware screen-space LOD selection in C++, works on any `MeshInstance3D` or raw `RenderingServer` instance
3. `visibility_range` — for hard culling at tier boundaries (500m → impostor handoff), complementary to the LOD chain, not a replacement

The refactor replaces the bespoke scheme with the engine pipeline. Expected net delta: **~700 lines deleted, ~200 lines rewritten**, 4× reduction in RS instance count, fixes the Vivec canton missing-faces bug as a side effect (engine pipeline welds + `SimplifyLockBorder` correctly), and brings the runtime LOD path from distance-band to FOV-aware screen-space — closing a significant gap vs AAA open-world engines.

This is a multi-session project. See **Part 5 — Migration phases** for the breakdown.

---

## Priority 0 — Hands Off The Streaming Layer

**HARD RULE, cannot be waived without `@user` approval:** this refactor must not touch the following files except via documented read-only references.

| File | Why it's off-limits |
|------|---------------------|
| `src/core/world/native_streaming_manager.gd` | Cell grid + async loading + shared 8ms frame budget + frustum priority + predictive camera velocity + differential impostor update. Close to AAA-standard already (see Part 1.5). |
| `src/core/world/cell_manager.gd` | Cell loading orchestration, NIF prototype instantiation, MID-worthy classification, MID→NEAR promotion. Load-bearing for the entire streaming pipeline. |
| `src/core/streaming/background_processor.gd` | Worker thread pool + frame budget enforcement. Reconsidering any of this is out of scope. |
| `src/core/world/native_impostor_renderer.gd` | FAR tier. Owned by `@impostors`, currently being refactored. Coordinate changes through that channel, not here. |
| `src/core/world/impostor_candidates.gd` | Same. |

**Narrow-scope allowed edits** — the refactor must *understand* how these files consume the LOD pipeline in order to change the contract safely, and the following exact narrow-scope removals are pre-authorized under this plan (each requires a commit message that references this doc):

- `cell_manager.gd::_find_first_mesh_instance` (line 517): remove the `_LOD1/2/3` name-ends-with skip clause. After the refactor there are no such siblings, so the skip is dead code. Scope: one conditional collapse, ~3 lines.
- `cell_manager.gd::_has_visible_lod_children`: delete the function body + all callers. Used to decide whether to hide MID RS instances on promotion; after the refactor there are no LOD-child nodes so the promotion logic is simplified. Scope: function removal + call-site cleanup.
- `native_streaming_manager.gd::_near_has_visible_lod_children` (lines 1149-1157): delete the function body + all callers. Same story. Scope: ~9 lines of function + 1 call site.

These are not "one-line" edits — they are narrow-scope LOD-children-check removals justified by the plan doc. The distinction matters: if a reviewer sees a 15-line diff across 3 call sites, the diff is plan-authorized, not a Priority 0 violation. Framing corrected per `@roaster` plan review revision 4.

**Why this rule exists:** the carry-vibration saga and the original LOD pipeline both came from the same failure mode — agents mid-task "incidentally" refactoring adjacent systems. Explicit scope discipline prevents it.

---

## Part 1 — Industry Reference: How AAA Open-World Engines Do LODs

### 1.1 The classical LOD pipeline (everyone except UE5 Nanite)

Used by UE4, UE5 non-Nanite, Unity HDRP, Source 2, CryEngine, id Tech 7, Decima (Horizon Zero Dawn, Death Stranding), REDengine (Witcher 3). The canonical pipeline has five stages:

1. **Authoring / auto-generation.** Artist either hand-authors 3–5 LODs per asset, or the tool pipeline runs a decimation library (Simplygon, meshoptimizer, InstaLOD, Polygon Cruncher) at import time. Auto-generation is the default in UE4/5 (import settings) and Unity (LOD Group generator). Hand-authoring is reserved for hero assets where silhouettes matter.
2. **Embedded LOD chain.** Each asset ships with a single mesh resource holding the LOD chain. In UE it's `UStaticMesh::RenderData::LODResources`. In Unity it's `Mesh` + `LOD Group` (the group is per-prefab but the meshes themselves are independent resources). In Godot 4.6 it's `ArrayMesh` + `surface_lod_indices` + `surface_lod_size`.
3. **Screen-space LOD selection at render time.** Each frame, the engine picks which LOD to draw per instance based on the projected screen-space coverage of the object's bounding volume. The formula is `screen_size = object_radius / (distance_to_camera * tan(fov/2))`. This is FOV-aware (correct behavior under zoom), resolution-aware (higher DPI picks higher LOD), and fully automatic. No per-instance distance thresholds, no per-LOD node objects, no cascade configuration.
4. **Hard distance culling at far plane.** Separate from LOD chain. UE calls this `Cull Distance` (per-primitive), Unity calls it `Draw Distance`, Godot calls it `visibility_range_end`. The LOD chain terminates; hard cull takes over; impostor or invisibility follows.
5. **Impostors at extreme distance.** For open-world games with view distances measured in kilometers, the LOD chain bottoms out and an impostor billboard takes over. Horizon Zero Dawn's octahedral impostors (Decima, GDC 2017) render 50+ km of foliage via a single atlased draw. Witcher 3 uses billboard tree impostors. Everything beyond the LOD chain's economic tail is drawn as a tiny flat sprite. Godot has no native impostor support — Godotwind rolls its own here, and that code is legitimately custom (see `docs/audit/IMPOSTOR_REBUILD.md`).

### 1.2 UE5 Nanite — the exception that doesn't apply to us

Nanite is fully virtualized geometry. No authored LODs. Cluster hierarchy streamed like virtual textures, decompressed on GPU, sub-pixel triangles at full quality. Replaces the entire classical pipeline.

**Why it doesn't apply to Godotwind:**
- Godot 4.6 has nothing comparable. Wouldn't be a reasonable target for a small team even if it did.
- Nanite foliage is known-expensive due to material bin overhead + overdraw. UE5.7 introduced voxel-Nanite foliage specifically because classic Nanite fails on vegetation. Morrowind has thousands of small clutter meshes per cell — the classical pipeline handles this better even in engines where Nanite is available.
- Non-opaque, skeletal, and heavily-animated meshes require fallback LODs in UE5 anyway. A "Nanite-or-nothing" pipeline doesn't exist in practice.

So we target the classical pipeline, same as every other non-UE5 AAA open-world game.

### 1.3 HLOD (Hierarchical LOD)

Beyond per-mesh LOD, AAA open-world engines bake *merged* meshes at cell-cluster granularity. A 1km² terrain region's worth of buildings + rocks + trees gets combined into a single draw call at extreme distance. UE ships `HLODBuilder` for this. Unity has `LOD Group` + `HLOD` add-ons. Decima bakes cell clusters into single atlased meshes.

**Relation to Godotwind:** our FAR-tier impostor system (500m–5km, single MultiMesh, octahedral billboards) is a form of HLOD — we merge thousands of FAR objects into one draw call. We don't do intermediate HLOD (e.g., merge 3×3 cells of MID-tier objects into a single mesh). Worth revisiting after the refactor lands, but out of scope for this doc.

### 1.4 Shadow LOD separate from render LOD

AAA engines frequently render shadows using a *more aggressive* LOD level than the color pass. The rationale is that shadows are softer, low-contrast, and don't need the same silhouette fidelity. UE and Unity both support per-primitive `shadow_lod_bias`. Decima goes further and bakes a separate shadow-only LOD chain.

**Relation to Godotwind:** we already disable shadow casting on LOD1-3 in `static_object_renderer.gd:477-480` — the rationale ("LOD1-3 disable shadows to save GPU budget") is correct but the implementation is coarse. After the refactor, Godot's per-surface LOD chain will drive shadow passes too, so the "turn shadows off at LOD1+" hack disappears. Re-evaluate shadow cost post-refactor.

### 1.5 Streaming orchestration — where we already match AAA

For context on what we *don't* need to change. Modern open-world streaming systems share these features, all of which Godotwind already implements in `native_streaming_manager.gd`:

| Feature | AAA equivalent | Godotwind |
|---------|----------------|-----------|
| Cell grid (2D or 3D) with async load | UE World Partition, Unity Addressables, Decima cell grid | `NativeStreamingManager._loaded_cells` + `cell_manager.request_cell_async` |
| Frustum-prioritized load order | UE streaming priority, Decima view-frustum weighting | `_get_cells_in_radius` with 4× behind-camera penalty |
| Frame-budgeted load/unload | UE async loader frame budget, Unity scene load throttle | Shared 8ms budget in `native_streaming_manager.gd` |
| Predictive preload from camera velocity | UE `SetStreamingSourceVelocity`, Decima camera prediction | `_camera_velocity_xz` EMA-smoothed prefetch |
| Deferred GPU resource cleanup | UE render command queue, Unity delayed destroy | Budgeted `free_rid()` over frames |
| Cell-change differential updates | UE world partition streaming generation | Differential impostor border-strip scan (~1ms vs 14-158ms previously) |

**This is close to textbook AAA.** The LOD refactor must preserve this intact. The LOD pipeline sits *underneath* this orchestration — LODs change how each loaded object renders, not how many objects load.

---

## Part 2 — Godot 4.6 Native Reference

Everything below is native to Godot 4.6 and sufficient to replace the bespoke pipeline. Sources: Godot 4.6 stable docs (`class_importermesh`, `class_arraymesh`, `tutorials/3d/mesh_lod`, `class_renderingserver`, `class_geometryinstance3d`).

### 2.1 `ImporterMesh.generate_lods(normal_merge_angle, normal_split_angle, bone_transform_array)`

The canonical API. Produces LOD levels via meshoptimizer internally. Used by glTF, FBX, and OBJ importers. Parameters:

- `normal_merge_angle: float` — degrees. Two vertices with normals within this angle are welded during simplification. Default for glTF: 60.0. Higher = more aggressive welding = smoother silhouettes.
- `normal_split_angle: float` — degrees. **Not used in 4.6+**, kept for API compatibility. Pass any value (typically 25.0).
- `bone_transform_array: Array[Transform3D]` — optional per-bone transform for skinning discrepancies. Empty array for static meshes.

Output: the `ImporterMesh` holds an internal cascade. Call `get_mesh(base_mesh: ArrayMesh = null)` to extract the final `ArrayMesh` with embedded LOD data, or use `get_surface_lod_count(surface_idx)` / `get_surface_lod_size(surface_idx, lod_idx)` / `get_surface_lod_indices(surface_idx, lod_idx)` for direct access.

**Usage pattern for runtime-created meshes** (the pattern we need, since NIFs are parsed at runtime/prebake and never go through glTF import):

```gdscript
var importer := ImporterMesh.new()
for surface_idx in range(original_mesh.get_surface_count()):
    var surf_arrays := original_mesh.surface_get_arrays(surface_idx)
    var surf_mat := original_mesh.surface_get_material(surface_idx)
    # blend_shapes and lods are dictionaries — empty for static meshes
    importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, surf_arrays, [], {}, surf_mat)

importer.generate_lods(60.0, 25.0, [])
var final_mesh: ArrayMesh = importer.get_mesh()
```

The `final_mesh` has `surface_lod_count` > 0 per surface, and the runtime renderer will automatically pick the right LOD per frame. No sibling nodes, no `visibility_range` configuration per LOD level, no `lod_configurator.gd` needed.

### 2.2 `ArrayMesh.add_surface_from_arrays(primitive, arrays, blend_shapes, lods, flags)`

Direct manual path. The `lods` parameter is `Dictionary[float, PackedInt32Array]`:

- **Key** (`float`) — the approximate screen-space size threshold at which this LOD becomes active. Units are arbitrary; the engine normalizes against `mesh_lod_threshold`. Lower key = higher detail (used when object covers more screen).
- **Value** (`PackedInt32Array`) — the index array for that LOD level, referencing the same vertex buffer as the main surface. Only the index array changes across LODs — vertex attributes are shared, which is why welding matters so much for quality.

Use this when surgical control over the LOD chain is needed (hero assets, custom decimation budgets). For bulk processing, `ImporterMesh` is simpler.

### 2.3 Viewport `mesh_lod_threshold`

`Viewport.mesh_lod_threshold: float` — default 1.0 pixel. The engine's LOD selector computes the pixel-space size difference between adjacent LOD levels and picks the highest LOD whose size delta is above the threshold. Higher values → LOD transitions happen sooner (closer to camera) → more performance, lower quality. Default 1.0 is "perceptually lossless" per Godot docs.

Set per-viewport: `get_viewport().mesh_lod_threshold = 1.0`. Tunable at runtime for quality presets (Low / Medium / High / Ultra in `streaming_config.gd`).

### 2.4 `GeometryInstance3D.lod_bias` + `RenderingServer.instance_geometry_set_lod_bias()`

Per-instance multiplier on the LOD selection. `lod_bias > 1.0` delays transitions (keeps higher detail further out), `lod_bias < 1.0` accelerates transitions (pops to lower detail sooner). Default 1.0.

Two API surfaces:
- Scene tree path: `mesh_instance_3d.lod_bias = 1.5`
- Raw RS path: `RenderingServer.instance_geometry_set_lod_bias(rid, 1.5)` — **this is the API that matters for `static_object_renderer.gd`**, which uses raw RS instances without Node3D wrappers.

The raw RS path is load-bearing for the refactor. It proves that `StaticObjectRenderer`'s node-bypass architecture remains intact — we don't have to adopt `MeshInstance3D` nodes to get automatic LOD.

### 2.5 `visibility_range` (hard culling, NOT sub-LOD)

`GeometryInstance3D.visibility_range_begin/end/*_margin` are for **hard culling at distance thresholds**, not for LOD sub-band selection. Use one band per instance for the render tier → impostor handoff:
- `visibility_range_begin = 0`
- `visibility_range_end = 500` (our NEAR+MID render tier)
- `visibility_range_fade_mode = FADE_SELF` (dither crossfade)

That's it. No `_LOD1` at 150-250m, no `_LOD2` at 250-375m. The engine picks which LOD in the embedded chain to render across the full 0-500m range based on screen coverage. `visibility_range` only handles the hard 500m cliff into the impostor tier.

Raw RS equivalent: `RenderingServer.instance_geometry_set_visibility_range(rid, begin, end, begin_margin, end_margin, fade_mode)`.

### 2.6 Automatic C++ selection

Once a mesh has an embedded LOD chain and the instance (MeshInstance3D or raw RS) exists, the engine handles:
- Computing screen-space projected size per frame
- Picking the LOD level
- Dispatching the correct index buffer to the draw call
- Handling cross-LOD fade (dither pattern, no crossfade geometry overlap)

All in C++, zero GDScript overhead, FOV-aware, resolution-aware, `lod_bias`-tunable per instance. This is what `lod_configurator.gd` + `_add_visibility_range_lods` + the per-LOD RS instance cascade in `static_object_renderer.gd` are laboriously reimplementing by hand.

### 2.7 `mesh_lod_threshold` vs quality presets

`streaming_config.gd` already has `QualityPreset` enum (LOW/MEDIUM/HIGH/ULTRA). After the refactor, quality presets should drive `mesh_lod_threshold` directly:

| Preset | `mesh_lod_threshold` | Rationale |
|--------|----------------------|-----------|
| LOW    | 4.0 px               | Aggressive LOD, prefer lower levels |
| MEDIUM | 2.0 px               | Balanced |
| HIGH   | 1.0 px               | Default, perceptually lossless |
| ULTRA  | 0.5 px               | Extra detail at distance |

This replaces the per-preset `near_end` / `mid_end` distance overrides in the current `get_quality_preset_config`.

---

## Part 3 — Current Bespoke Implementation (What Gets Refactored)

Inventory of every file + function that participates in the LOD scheme. Compiled from `LOD_OVER_ENGINEERING.md` Session 0 audit + direct grep verification.

### 3.1 Prebake side

| File | Lines | Role |
|------|-------|------|
| `src/core/nif/nif_converter.gd::_add_visibility_range_lods` | 1184-1372 | Hand-rolled LOD generation. Loops per LOD level, calls `MeshOptimizer.simplify_arrays()` with hardcoded `lod_reduction_ratios = [0.50, 0.25, 0.10]`, creates sibling `MeshInstance3D` named `<parent>_LOD1/2/3`, assigns `visibility_range_begin/end/*_margin` per band in a match block, hardcodes `FADE_DEPENDENCIES`. Calls `MeshOptimizer` GDExt (NOT the engine's internal meshoptimizer). No welding, no `SimplifyLockBorder`, no attribute-aware remap → Vivec canton missing faces. |
| `src/core/nif/nif_converter.gd::_should_generate_lods` | 1176 | Delegates to `StreamingPolicy.should_generate_lods`. Stays after refactor — the "which models get LODs" decision is still needed. |
| `src/core/nif/nif_converter.gd` | 134 | `var generate_lods: bool = true` — keep as kill switch. |
| `src/tools/prebaking/model_prebaker.gd::_count_lod_nodes` / `_collect_lod_nodes_for_removal` / `_verify_no_lod_nodes_remain` | (scattered) | Prebaker tooling that inspects sibling `_LODn` structure. **Dead code after refactor** — there will be no sibling nodes. Delete. |
| `src/tools/prebaking/targeted_rebake.gd::_cache_has_lods` | 49 | Targeted rebake detects missing LODs by walking cached scene for sibling nodes. **Rewrite** to check `ArrayMesh.surface_get_lod_count(0) > 0` instead. |
| `src/tools/prebaking/impostor_baker_v2.gd` / `impostor_baker_v3.gd` | 475, 648 | Sets `converter.generate_lods = false` for impostor bakes. Stays. |
| `src/core/world/streaming_policy.gd::should_generate_lods` + `_is_significant_model` | 43-96 | The prebake-time "which models get LODs" decision. Stays. Content-agnostic to the output format. |

### 3.2 Cache format

`.res` files in `C:/Users/metzo/Documents/Godotwind/cache/models/` currently contain `MergedMesh_0_LOD1`, `_LOD2`, `_LOD3` as child nodes of the main mesh, each with their own `visibility_range_*` properties baked in. **4884 files total**, **217 of which** were re-baked during Session 0's abandoned Layer 1+2 attempt.

After the refactor, `.res` files contain a single `MeshInstance3D` per mesh object with an `ArrayMesh` whose surfaces have `surface_lod_count > 0`. **Full cache wipe + rebake required** — the format is binary-incompatible with the old layout. This is an unavoidable one-time cost.

### 3.3 Runtime streaming / rendering

| File | Function / section | Disposition |
|------|---------------------|-------------|
| `src/core/world/static_object_renderer.gd::register_lod_from_prototype` | 221-296 | **Rewrite.** Walks prototype tree for sibling `_LODn` nodes. After refactor: walks for a single `MeshInstance3D` per object, reads `ArrayMesh.surface_get_lod_count()` to confirm the LOD chain exists. |
| `src/core/world/static_object_renderer.gd::_extract_lod_meshes` | 300-374 | **Delete.** Sibling-node walker. Replaced by a single-mesh registration path. |
| `src/core/world/static_object_renderer.gd::add_instance` LOD path | 448-502 | **Rewrite.** Currently creates up to 4 RS instances (one per LOD level) with per-LOD `instance_geometry_set_visibility_range`. After refactor: creates **one** RS instance via `instance_set_base`, sets `visibility_range_end = 500m` for impostor handoff, calls `instance_geometry_set_lod_bias(rid, 1.0)`. Engine handles sub-LOD selection. |
| `src/core/world/static_object_renderer.gd::_get_lod_visibility_range` | 548-585 | **Delete.** Per-LOD band math. Obsolete. |
| `src/core/world/static_object_renderer.gd::LodMeshEntry`, `MeshType.lod_meshes`, `MeshType.lod_collapsed_to`, `InstanceData.lod_rids`, `InstanceData.lod0_count` | — | **Delete.** Multi-RID data plumbing. Obsolete. |
| `src/core/world/static_object_renderer.gd::_lod_entries_same_meshes` | 391-397 | **Delete.** "Issue #9" LOD-band collapse hack for when fallback-filled bands duplicate each other. Engine pipeline won't produce duplicates. |
| `src/core/world/lod_configurator.gd` | (entire file, 417 lines) | **Delete.** Every function in this file reimplements what Godot does automatically. |
| `src/core/world/mesh_visibility_utils.gd::is_lod_node_name` | — | **Delete or no-op.** No sibling LOD nodes to detect. |
| `src/core/world/cell_manager.gd::_find_first_mesh_instance` | 517 | **Simplify** — remove the `_LOD1/2/3` skip clause. Narrow-scope edit (single conditional collapse, ~3 lines), allowed under Priority 0 with commit message justified against this plan. |
| `src/core/world/cell_manager.gd::_has_visible_lod_children` | 2229 area | **Delete** (function body + all callers, narrow-scope LOD-children-check removal). Used to decide whether to hide MID RS instances on promotion. After refactor there are no LOD children, promotion logic simplifies. Allowed under Priority 0 with commit message justified against this plan. |
| `src/core/world/native_streaming_manager.gd::_near_has_visible_lod_children` | 1149-1157 | **Delete** (function body + all callers, ~9 lines of function + call sites). Narrow-scope LOD-children-check removal, allowed under Priority 0 with commit message justified against this plan. |
| `src/core/world/distance_utils.gd::FADE_MARGIN_NEAR_LOD1/LOD1_LOD2/LOD2_LOD3/LOD3_FAR` | 47-50 | **Collapse** to single `FADE_MARGIN_RENDER_FAR = 20.0` (render tier → impostor handoff). |
| `src/core/world/distance_utils.gd::LOD1_END/LOD2_END/LOD3_END` | 33-35 | **Delete.** No manual sub-LOD boundaries. |
| `src/core/world/streaming_config.gd::MID_LOD1_START/END`, `MID_LOD2_*`, `MID_LOD3_*`, `FADE_MARGIN_NEAR/MID/FAR` | 41-63 | **Delete.** Manual sub-LOD band configuration. |
| `src/core/world/streaming_config.gd::get_quality_preset_config` | 187-227 | **Rewrite.** Quality presets drive `mesh_lod_threshold` + `max_near_cells` + `max_mid_cells` + `max_far_cells`. Distance overrides for `near_end/mid_end/far_end` stay. |

### 3.4 Debug + test tooling

| File | Disposition |
|------|-------------|
| `src/core/world/debug_overlay.gd` | Update — remove per-LOD-level stats, add `mesh_lod_threshold` + `lod_bias` readouts. |
| `src/core/world/lod_debug_commands.gd` | Rewrite — new commands: `lod_threshold <float>`, `lod_bias <type> <float>`, `lod_stats`. |
| `tests/visual/lod_overlap_test.gd` | Delete or rewrite — tests sibling node overlap, no longer applicable. |
| `tests/visual/lod_transition_test.gd` | Rewrite — automated camera path, measure LOD switch frames via engine stats. |

### 3.5 Summary — the 17 files

Count from `LOD_OVER_ENGINEERING.md`: 17 files + 127 references. After the refactor:

- **Fully deleted:** `lod_configurator.gd`, `lod_overlap_test.gd`, plus all LOD-specific helpers in `static_object_renderer.gd`, `distance_utils.gd`, `streaming_config.gd`, `mesh_visibility_utils.gd`, `model_prebaker.gd`
- **Partially rewritten:** `nif_converter.gd`, `static_object_renderer.gd`, `targeted_rebake.gd`, `lod_debug_commands.gd`, `lod_transition_test.gd`
- **Narrow-scope Priority-0-allowed edits (LOD-children-check removal, justified in commit against this plan):** `cell_manager.gd`, `native_streaming_manager.gd`
- **Unchanged:** `streaming_policy.gd`, `reference_instantiator.gd`, all other files

---

## Part 4 — Target Architecture

End-state after Phase G completes.

### 4.1 Prebake pipeline

`NIFConverter._add_visibility_range_lods` becomes `_generate_lod_chain`, replaced with:

```gdscript
func _generate_lod_chain(mesh_instance: MeshInstance3D, original_mesh: ArrayMesh) -> void:
    if not _should_generate_lods():
        return

    var surface_count := original_mesh.get_surface_count()
    if surface_count == 0:
        return

    # Skip small meshes (current min_triangles_for_lod check stays)
    var num_triangles := _count_triangles(original_mesh)
    if num_triangles < min_triangles_for_lod:
        return

    # Engine pipeline: feed surfaces to ImporterMesh, generate, replace.
    # Welding, SimplifyLockBorder, attribute remap, vertex cache opt — all handled.
    var importer := ImporterMesh.new()
    for si in range(surface_count):
        var surf_arrays := original_mesh.surface_get_arrays(si)
        if surf_arrays.is_empty():
            continue
        var surf_mat: Material = original_mesh.surface_get_material(si)
        importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, surf_arrays, [], {}, surf_mat)

    # glTF importer defaults: 60° merge, 25° split (unused in 4.6+, kept for API).
    importer.generate_lods(60.0, 25.0, [])

    var lod_mesh: ArrayMesh = importer.get_mesh()
    mesh_instance.mesh = lod_mesh
    # Single hard-cull visibility_range for tier → impostor handoff.
    # No sibling LOD nodes, no per-band configuration.
    mesh_instance.visibility_range_begin = 0.0
    mesh_instance.visibility_range_end = DU.MID_END  # 500m
    mesh_instance.visibility_range_end_margin = DU.FADE_MARGIN_RENDER_FAR  # 20m dither
    mesh_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
```

Entire function shrinks from 189 lines to ~30. `MeshOptimizer` GDExt is no longer called from this path (it stays in the repo for other use cases — e.g., future welding helpers).

### 4.2 Cache format

One `MeshInstance3D` per mesh-bearing prototype node. `ArrayMesh` has `surface_get_lod_count(i) > 0` for any surface with more than `min_triangles_for_lod` triangles. `visibility_range_end = 500` on the `MeshInstance3D`. No sibling `_LODn` children.

Cache wipe is mandatory at Phase B→C transition. `SettingsManager.get_cache_dir()` → `C:/Users/metzo/Documents/Godotwind/cache/models/` — user deletes via `rmdir /s /q` or equivalent, then full rebake via `prebaking_manager`.

**Current cache state (captured 2026-04-09 as Phase A baseline fingerprint):** 5172 `.res` files, ~3.22 GB total, all files with mtime clustered in a single ~3 min window on 2026-04-08 22:23-22:26. Full manifest in `docs/audit/lod_refactor_baselines/pre_wipe_cache_manifest.txt`. State at capture time is ambiguous between "Session 0 Layer 1+2 partial-rebake experimental pipeline" and "post-Session 0 full rebake on reverted HEAD pipeline" — mtimes don't distinguish. The baseline captures the current observable visual + perf state regardless, which is the only thing that matters for before/after comparison.

### 4.3 Runtime: `StaticObjectRenderer`

Registration simplifies:

```gdscript
func register_from_prototype(type_name: String, prototype: Node3D) -> void:
    if type_name in _mesh_types:
        return

    var mesh_instance := _find_mesh_instance(prototype)  # No more _LOD* skip
    if not mesh_instance or not mesh_instance.mesh:
        push_warning("StaticObjectRenderer: No mesh found for '%s'" % type_name)
        return

    var mesh_type := MeshType.new()
    mesh_type.name = type_name
    mesh_type.mesh_resource = mesh_instance.mesh  # Holds LOD chain internally
    mesh_type.mesh_rid = mesh_instance.mesh.get_rid()
    mesh_type.aabb = mesh_instance.mesh.get_aabb()
    # Material resolution priority unchanged (material_override → surface override → mesh surface)
    # ...

    _mesh_types[type_name] = mesh_type
```

Instance creation simplifies:

```gdscript
func add_instance(type_name: String, transform: Transform3D, cell_grid: Vector2i = Vector2i.ZERO,
        model_path: String = "", item_id: String = "", ref_id: StringName = &"", ref_num: int = 0) -> int:

    if type_name not in _mesh_types:
        return -1

    var mesh_type: MeshType = _mesh_types[type_name]
    var rs := RenderingServer
    var instance_rid := rs.instance_create()
    rs.instance_set_base(instance_rid, mesh_type.mesh_rid)
    rs.instance_set_scenario(instance_rid, _scenario)
    rs.instance_set_transform(instance_rid, transform)

    # Material application unchanged

    # Single visibility_range — engine picks LOD from embedded chain automatically
    rs.instance_geometry_set_visibility_range(
        instance_rid,
        0.0, DU.MID_END,           # 0-500m render tier
        0.0, DU.FADE_MARGIN_RENDER_FAR,
        RenderingServer.VISIBILITY_RANGE_FADE_SELF
    )

    # Optional: lod_bias from streaming config (default 1.0)
    rs.instance_geometry_set_lod_bias(instance_rid, SC.DEFAULT_LOD_BIAS)

    # InstanceData plumbing unchanged except lod_rids/lod0_count removed
    # ...
    return id
```

RS instance count drops from ~4× to 1× — at ~63k MID-tier objects that's ~189k fewer RIDs. `remove_instance` simplifies to a single `free_rid()` call.

### 4.4 What stays identical

- The streaming orchestration layer (Priority 0)
- The NEAR-tier Node3D instantiation pipeline (scene tree, physics, signals — unchanged)
- The MID→NEAR promotion system (logic unchanged, just no longer needs `_near_has_visible_lod_children` check since there are no LOD children)
- The FAR-tier impostor renderer (Priority 0, owned by `@impostors`)
- `StreamingPolicy.should_generate_lods` + `is_mid_worthy` decisions
- Material deduplication pipeline
- BSA/ESM loading

### 4.5 What gets deleted (line-counted estimate)

| Target | Est. lines deleted |
|--------|---------------------|
| `nif_converter.gd::_add_visibility_range_lods` | ~160 (189 → ~30) |
| `lod_configurator.gd` entire file | 417 |
| `static_object_renderer.gd` LOD machinery (`_extract_lod_meshes`, `_get_lod_visibility_range`, `LodMeshEntry`, `lod_meshes` plumbing, `lod_rids`, `_lod_entries_same_meshes`) | ~250 |
| `distance_utils.gd` per-boundary fade constants + sub-LOD ends | ~10 |
| `streaming_config.gd` MID_LOD* constants + quality preset distance overrides | ~40 |
| `cell_manager.gd` LOD skip clauses | ~10 |
| `native_streaming_manager.gd` `_near_has_visible_lod_children` | ~10 |
| `model_prebaker.gd` LOD node counting / removal helpers | ~50 |
| `targeted_rebake.gd::_cache_has_lods` | ~20 |
| `mesh_visibility_utils.gd::is_lod_node_name` + callers | ~15 |
| Debug overlay / test scenes | ~50 |
| **Total deleted** | **~1,030** |
| Total added (rewrite) | ~200 |
| **Net delta** | **-830** |

### 4.6 Verification surface area

Things that must be the same before and after:

1. **Visual quality at 0-150m** (NEAR tier): full scene tree pipeline, no RS instances involved. Refactor does not touch this.
2. **Visual quality at 150-500m** (MID tier): should *improve* — engine pipeline welds, locks borders, preserves silhouettes. Vivec canton missing-faces bug fixes itself. Measure: interior/exterior visual test scenes at Vivec, Balmora, Seyda Neen, Ald-ruhn.
3. **Visual quality at 500m-5km** (FAR tier): impostors, out of scope for this refactor, must not break.
4. **Frame rate on the 63k-object world**: should improve slightly — fewer RIDs, less culling work. Measure: `StreamingBenchmark` CSV output, compare P50/P95/P99 frame times.
5. **Memory footprint**: should drop ~20 MB (per-instance RS state shrinks 4×). Measure: `PerformanceProfiler` memory snapshots.
6. **Cell load/unload cost**: unchanged. Measure: per-phase streaming overrun logs (`[streaming] Frame overrun: Xms [unload:X async:X inst:X ...]`).

---

## Part 5 — Migration Phases

Each phase is session-scoped. User approval gate before each phase starts. No phase pollutes the next with scope creep.

### Branching and rollback strategy (from `@roaster` plan review, revision 3)

All Phase B-G work happens on branch **`refactor/lod-b-wide`**. `master` stays clean and shippable.

- **Before Phase B starts**: tag `master` as `pre-lod-refactor`. Rollback command is `git checkout pre-lod-refactor` + full rebake. 30 minutes of prep that saves days of "which commit was last good".
- **Before Phase C cache wipe**: dump current `C:/Users/metzo/Documents/Godotwind/cache/models/` file count + cumulative size + filename manifest to `docs/audit/lod_refactor_baselines/pre_wipe_cache_manifest.txt`. Not the cache itself (5172 files, too large) but enough to verify a post-refactor rebake produces equivalent coverage.
- **Phase G closes by merging `refactor/lod-b-wide` → `master`** only after all Phase G exit criteria are met and the final visual + benchmark passes archived.

### Phase A.5 — NIF Collision Coordinate Fix (bundled pre-LOD-refactor, per `@roaster` msg 203)

**Not yet applied as of 2026-04-09 session end. Pending execution.**

`docs/audit/NIF_COLLISION_COORDINATE_BUG.md` was shipped by `@character-debug` (msg 191 in `#general`, 19:05:37) during a character controller debug session. Describes a parallel-path asymmetric coordinate conversion bug in the NIF import chain: visual path calls `_convert_nif_transform` in `nif_converter.gd:943/978/1072`, collision path does NOT in `nif_collision_builder.gd:189/243`. Result: collision shapes have Y-up vertices positioned by Z-up transforms → stair outlines missing, collision wireframes floating hundreds of meters from their visual meshes, character controller step-up cannot function. Root cause and ~15-line fix are documented in the collision bug doc's "Canonical Fix — Part 1" section.

**`@roaster` msg 203 (19:24:27) — recommended integration:** bundle the collision fix with this LOD refactor branch as an independent commit on `refactor/lod-b-wide`, shipped **before** Phase A baseline capture. Reasoning:

1. **Rebake cost amortization.** Both the collision fix and Phase B→C cache wipe require a full `cache/models/` wipe + rebake of ~5172 files (~10-20 min). Bundling the fix into the same rebake cycle saves one full rebake cycle vs shipping the collision fix separately later.
2. **Scope isolation at commit level, not work level.** Single named commit `fix: nif collision coordinate asymmetry (NIF_COLLISION_COORDINATE_BUG.md Part 1)` preserves Priority 0 discipline. Zero file overlap with Phase B scope (collision fix = `nif_collision_builder.gd`; Phase B scope = `nif_converter.gd`). Either fix regresses → isolable via `git revert <sha>`.
3. **"Fix world state before measuring world state" — standard experimental hygiene.** If the collision fix lands mid-refactor, baselines are captured against bug-era coordinates and post-refactor comparison is confounded.

**`@roaster`'s recommended sequence:**
1. Apply Part 1 of `NIF_COLLISION_COORDINATE_BUG.md` (~15 lines in `nif_collision_builder.gd`)
2. Full cache wipe + rebake (`rmdir cache/models` → `prebaking_manager` full run)
3. Interactive verification per the doc's procedure (stairs in Balmora + guild halls + temples with `--debug-collisions` on; confirm no floating wireframes, character step-up works)
4. Single commit on `refactor/lod-b-wide` — message: `fix: nif collision coordinate asymmetry (NIF_COLLISION_COORDINATE_BUG.md Part 1)`
5. **THEN** Phase A baseline capture runs
6. Phase B.0, Phase B, Phase C — Phase C's cache wipe becomes the second rebake of the session (not the first)

**Scope guard per `@roaster`:**
- **IN:** Part 1 verbatim from the collision bug doc ("Canonical Fix" section). Exact scope.
- **OUT:** Part 2 (trimesh fallback) — deferred per doc's own "optional if Part 1 fixes all affected NIFs" caveat. Don't speculate, measure.
- **OUT:** The "floating trees/rocks" visual-chain bug the collision doc speculates about in "Related — Adjacent Bugs". Different failure mode, not diagnosed, chasing it now is scope creep.
- **OUT:** Character-controller changes from the collision doc's "Character-Controller-Side Work" section. Different files, different concern, different review pass. `@user`'s working tree already has them as modified files; they ship separately.

**Owner:** TBD — `@lods` or `@character-debug` depending on session assignment. Whoever picks it up finishes in ~1 session. Coordinate via `#lods` so the commit lands on `refactor/lod-b-wide` not `master`.

**Sequencing reality check for Session 1 (2026-04-09):** `@lods` completed Phase A baseline capture **before** seeing `@roaster` msg 203 (capture finished at ~19:25:13, `@roaster` posted at 19:24:27 — 47 second overlap, msg missed during test-scene execution). The captured baselines are against pre-collision-fix world state. **Mitigation:**

- The LOD test scene (`tests/visual/test_lod_baseline.gd`) measures **structural properties of `.res` files** — per-LOD triangle counts, AABBs, sub-mesh counts, simplifier reduction ratios. These are **collision-independent** by construction. A collision fix that only touches coordinate conversion in `nif_collision_builder.gd` does not affect the LOD chain's geometry, so the 4 captured structural baselines (`baseline_vivec_h_01`, `baseline_tree_01`, `baseline_mushroom_bc_01`, `baseline_redoran_hut`) remain valid for Phase D comparison as-is.
- `baseline_perf.csv` from `StreamingBenchmark` measures frame timing + RS instance counts + draw calls. These are also collision-path-independent — collision shape placement does not alter MID-tier RS render counts.
- **BUT** interactive visual verification in Phase D / Phase G (walk Balmora, Vivec, Seyda Neen, Ald-ruhn with `--debug-collisions` on) is entitled to happen on a coordinate-correct world. The collision fix should ship BEFORE Phase D's first interactive visual pass, not before Phase B.0 smoke tests (which don't need the main scene).

**Revised Phase A.5 placement:** ship the collision fix **between Phase C (targeted rebake) and Phase D (runtime renderer refactor)**, not before Phase A. Rationale: Phase C already wipes the cache for its format migration, so piggybacking the collision fix on that wipe retains `@roaster`'s rebake-cost amortization (one wipe, two fixes merged). And Phase D is the first phase that needs an interactive visual verification pass, which is where the collision-bug's "missing stairs + floating wireframes" actually matters. Phase A.5 exit criteria: collision fix committed on the branch, Phase C cache wipe already executed (or waiting at the Phase D boundary), stairs walkthrough verified.

**If the owner disagrees with this revised placement and wants to ship collision fix before Phase A baseline recapture:** option exists to re-run the 4 test-scene captures + benchmark after the collision fix + rebake. Cost: ~25 min (10 min rebake + 15 min re-capture). This is the "strict @roaster sequencing" option. Current recommendation is to skip it since the existing baselines are structurally valid for their scope.

### Phase A — Plan sign-off + baseline capture

- Status: **COMPLETE on the agent side** (plan doc reviewed, test scene built + verified, 4 baselines captured, perf CSV captured, all artifacts in repo). Session 1 closed 2026-04-09 evening.
- Owner: `@lods`
- Outputs:
    1. This document, reviewed by `@roaster` + approved by `@user` ✓
    2. `pre-lod-refactor` git tag on `master` ✓ (rollback anchor)
    3. `refactor/lod-b-wide` branch created, all B-G work lands there ✓
    4. Baseline cache manifest → `docs/audit/lod_refactor_baselines/pre_wipe_cache_manifest.txt` (file count, total bytes, filename list, mtime distribution) ✓
    5. **Programmatic baseline capture (v2 — replaces screenshot approach).** `@user` rejected the v1 screenshot approach (`#lods` msg 177: "we're not doing screenshot based tests, from my experience it doesn't work. just either ask me if I'm seeing something, or build automated test to get precise information about what's happening in the game"). v2 uses programmatic console-command output for objective data + a short yes/no questionnaire for subjective visual checks:
        - New console command `lod_baseline_dump <label>` added to `src/tools/lod_debug_commands.gd` (on `refactor/lod-b-wide` branch). Runs at current camera position and writes combined output of `lod_stats` + `mid_batch_stats` + `visibility_gaps` + `streaming_diag` + `look` + `mid_lod_textures` to `user://lod_baselines/<label>.txt` with a header (timestamp, frame counter, frame time, camera pos/rot/FOV, camera cell, `mesh_lod_threshold`). ~80 lines. Survives through Phase D post-refactor capture + Phase G full validation.
        - `@user` runs the command at each of 4 baseline locations (Vivec Canton, Balmora dock, Seyda Neen, Ald-ruhn) and copies the 4 resulting text files to `docs/audit/lod_refactor_baselines/programmatic/`.
        - `@user` fills in `visual_qa_baseline.md` per the template in `BASELINE_PROCEDURE.md` §2.1 — ~5 yes/no questions per location, ~20 data points total.
    6. Baseline performance capture: `StreamingBenchmark` run via standalone scene (`src/tools/streaming_benchmark.tscn`) OR console command `benchmark_streaming` from `world_explorer`. Scripted camera path is Seyda-Neen-centered: idle(3s) → approach from 800m(5s) → orbit at 200m(10s) → sprint 600m north(5s) → 3 teleports 500m apart → return(4s). CSV written to `user://benchmark_results/`. User copies to `docs/audit/lod_refactor_baselines/baseline_perf.csv`.
    7. Baseline procedure document written for the user (`docs/audit/lod_refactor_baselines/BASELINE_PROCEDURE.md` v2) — step-by-step programmatic + questionnaire + benchmark procedures.
- Exit criteria:
    - Plan doc review closed (`@roaster` verdict applied, `@user` approval documented in Progress Log) ✓
    - `pre-lod-refactor` tag visible in `git tag` output ✓
    - `refactor/lod-b-wide` branch visible in `git branch` output, checked out, ready for Phase B ✓
    - `pre_wipe_cache_manifest.txt` exists and is non-empty ✓
    - `lod_baseline_dump` console command exists and is parameterized correctly ✓
    - `programmatic/` subdirectory contains the 4 location text files — `@user` interactive pass pending
    - `visual_qa_baseline.md` filled in — `@user` interactive pass pending
    - `baseline_perf.csv` exists and is parseable — `@user` interactive pass pending

### Phase B — Prebake pipeline swap

- Owner: `@lods`
- Prerequisite: Phase A complete, `refactor/lod-b-wide` branch checked out, `pre-lod-refactor` tag exists on `master`
- Files touched: `src/core/nif/nif_converter.gd` only

#### Phase B.0 — Foundation API smoke tests (GO/NO-GO gate, ~15 min)

**Added per `@roaster` plan review revision 1.** Both foundation APIs (`ImporterMesh.generate_lods` + `RenderingServer.instance_geometry_set_lod_bias` on raw RS instances) have **zero prior usage** in `src/` and the plan's behavior claims come from docs, not in-repo proof. Verify behavior BEFORE any bulk prebake rewrite.

**Smoke test 1 — `ImporterMesh.generate_lods()` at runtime / `@tool` context.** Create `tests/unit/test_importermesh_smoke.gd` (delete after Phase B):

```gdscript
extends GdUnitTestSuite

func test_importermesh_generates_lods() -> void:
    # Build trivial box ArrayMesh
    var st := SurfaceTool.new()
    st.begin(Mesh.PRIMITIVE_TRIANGLES)
    # ... add ~500 triangles (enough for meshoptimizer to bite on)
    var base := st.commit()
    assert_that(base.get_surface_count()).is_equal(1)

    var importer := ImporterMesh.new()
    importer.add_surface(Mesh.PRIMITIVE_TRIANGLES,
        base.surface_get_arrays(0), [], {},
        base.surface_get_material(0))
    importer.generate_lods(60.0, 25.0, [])

    var out: ArrayMesh = importer.get_mesh()
    assert_that(out).is_not_null()
    var lod_count := out.surface_get_lod_count(0)
    Log.info("tools", "ImporterMesh smoke: surface_lod_count = %d" % lod_count)
    assert_that(lod_count).is_greater(0)
```

If `lod_count == 0`, pivot: `ImporterMesh` runtime path does not produce LODs and we must fall back to Part 2.2's direct `ArrayMesh.add_surface_from_arrays(..., lods_dict, ...)` path with hand-called `MeshOptimizer` GDExt. **Phase B code sketch in Part 4.1 changes accordingly.** Either way, we learn it in 10 minutes instead of 3 sessions.

**Smoke test 2 — automatic LOD selection on raw RS instances (not `MeshInstance3D` nodes).** Create `tests/visual/test_rs_lod_smoke.tscn`:

- Scene has Camera3D + single RS instance created via `RenderingServer.instance_create()` + `instance_set_base(rid, mesh_with_lods)` in `_ready()`
- Mesh is the output of Smoke Test 1 (~500 triangles with LOD chain)
- Camera starts at 5m, lerps out to 500m over 10 seconds
- Each frame print `RenderingServer.instance_get_base(rid)` visible LOD index if exposed, or use `RenderingServer.viewport_get_render_info(viewport, RENDER_INFO_TYPE_VISIBLE, RENDER_INFO_PRIMITIVES_IN_FRAME)` to track triangle count delta as proxy
- If triangle count drops at distance, auto-LOD works on raw RS instances ✓
- If triangle count stays constant (same LOD0 always rendered), auto-LOD only works on `MeshInstance3D` nodes — refactor collapses, `StaticObjectRenderer` must adopt `MeshInstance3D` wrappers, architectural re-plan needed

**Phase B.0 exit criteria (GO/NO-GO):**
- Smoke test 1: LOD count > 0 printed to Log.info, or decision to pivot to manual LOD dict path
- Smoke test 2: triangle count drops at distance (auto-LOD works for raw RS instances), or decision to adopt `MeshInstance3D` wrappers
- Both decisions written into the Progress Log with the observed values
- **NO GO** on either test blocks Phase B.1 until the pivoted plan is documented

#### Phase B.1 — Bulk prebake swap

Only after B.0 passes.

- Changes:
    - Rename `_add_visibility_range_lods` → `_generate_lod_chain`
    - Replace body with `ImporterMesh.generate_lods()` call per the Part 4.1 code sketch (OR the manual-dict fallback if B.0 smoke test 1 said so)
    - Keep the `_should_generate_lods` gate and `min_triangles_for_lod` skip
    - Replace sibling-node creation with single `mesh_instance.mesh = lod_mesh` assignment
    - Set single-band `visibility_range` on the `MeshInstance3D`
- Verification:
    - Single-model prebake test: pick `ex_hlaalu_b_01.nif`, run through `nif_debug_dump` + a targeted single-model bake. Confirm resulting `.res` has no sibling `_LODn` children and the single `MeshInstance3D.mesh.surface_get_lod_count(0) > 0`.
    - Compile clean, no type errors, no runtime warnings
    - Existing tests in `tests/unit/` that touch NIF conversion still pass
- Exit criteria:
    - B.0 smoke tests passed (or pivoted plan documented in Progress Log)
    - One manually-verified model baked and correctly shaped
    - Existing runtime code still runs against *old* cache files (no cache wipe yet — new baked models aren't loaded by runtime in this phase)

### Phase C — Cache format migration + targeted rebake verification

- Owner: `@lods`
- Prerequisite: Phase B.1 complete

**Note on `@roaster` review revision 2 (no longer applied — see Session 1 Progress Log + audit).** The original R2 concern was that without a fall-through bridge in `static_object_renderer.gd::_extract_lod_meshes`, Phase C's new-format `.res` files would render invisible at MID tier because the existing walker only recognizes sibling `_LODn` nodes. Critical code audit against `static_object_renderer.gd:221-296` + `:378-386` showed R2's premise is wrong:

- `_get_lod_level_from_name()` (line 378-386) returns **0 for any name that doesn't end in `_lod1/2/3`** — base-case fallthrough, not a miss
- A new-format single-MeshInstance3D prototype (no sibling LODn children) walks into `_extract_lod_meshes`, hits the main mesh with `lod_level = 0`, and gets appended to `mesh_type.lod_meshes[0]` as a single entry
- Back in `register_lod_from_prototype:243-248` the fallback-fill loop duplicates `[0]` into keys `1/2/3`
- The collapse logic at `:255-265` then detects LOD1==LOD2==LOD3 (identical mesh_rid) and compacts to `{0: [entry], 1: [entry with collapsed range 150-500m]}` via `lod_collapsed_to = 3`
- `add_instance:448-502` creates 2 RS instances per object (LOD0 at 0-150m + collapsed LOD1 at 150-500m), both pointing at the same `ArrayMesh` that holds the embedded LOD chain

Result: new-format meshes render correctly at all distances in Phase C intermediate state. The canton missing-faces fix is fully verifiable at both NEAR (walk-up) and MID (distance-gaze) tiers without any bridge code. The only "cost" of the intermediate state is that Phase C runs with 2 RS instances per object instead of the post-Phase-D 1 RS instance per object — wasteful but correct and invisible to the user.

**The whole bridge adds 20 lines of code that exist for one phase and then get deleted. The base-case handling already in the existing walker removes the need for it.** Simpler path wins per CLAUDE.md "Simplicity Over Over-Engineering".

- Files touched: `src/tools/prebaking/targeted_rebake.gd::_cache_has_lods`, `src/tools/prebaking/model_prebaker.gd::_count_lod_nodes` + friends. **`static_object_renderer.gd` is NOT touched in Phase C** — it keeps the existing walker, which already handles new-format meshes via its base-case LOD0 path.
- Changes:
    - Rewrite `_cache_has_lods` to check `ArrayMesh.surface_get_lod_count(0) > 0` (new-format detection for targeted-rebake "is this model already baked with LODs?" heuristic)
    - Delete `_count_lod_nodes` / `_collect_lod_nodes_for_removal` / `_verify_no_lod_nodes_remain` (dead code once no one creates sibling LOD nodes)
- Verification:
    - Cache wipe: delete `C:/Users/metzo/Documents/Godotwind/cache/models/` contents (manifest captured in Phase A)
    - Full prebake run via `prebaking_manager` for the 217-model target list from Session 0 (`ex_hlaalu_canton_*`, `ex_velothi_*`, `ex_vivec_*`, `in_vivec_*`, `ex_t_*`, `ex_dwrv_*`, `ex_ashl_*`, `ex_ald_*`)
    - Interactive visual verification at Vivec Canton: walk up to a rebaked canton wall (NEAR tier, 0-150m) — check for missing faces on the up-close geometry. Step back to 200-400m — confirm the MID-tier renders correctly via the fallback-fill + collapse path.
    - Existing runtime loads new-format cache files via the walker's base-case (LOD0 path) with no new code
- Exit criteria:
    - 217-model targeted bake succeeds with 0 errors
    - Visual inspection at Vivec Canton shows **no missing faces** on a rebaked canton mesh at both NEAR and MID tiers (early signal on whether engine pipeline actually fixes the Session 0 bug)
    - Progress Log entry recording whether the canton visual bug fixed itself as expected

### Phase D — Runtime renderer refactor

- Owner: `@lods`
- Prerequisite: Phase C complete
- Files touched: `src/core/world/static_object_renderer.gd`, plus narrow-scope LOD-children-check removals in `cell_manager.gd` and `native_streaming_manager.gd` (see Part 3.3 for exact scope, allowed under Priority 0 with commit message justified against this plan)
- (No Phase C bridge to remove — bridge requirement was dropped after audit, see Phase C notes.)
- Changes per Part 4.3
- Verification:
    - Full cache wipe + full rebake (all ~5172 models, see Phase A manifest for count)
    - Launch main scene `scenes/Godotwind.tscn` at Seyda Neen
    - Interactive visual test: fly from Seyda Neen to Balmora, to Vivec, to Ald-ruhn — watch tier handoff at 500m for LOD pops or crashes
    - Check RS instance count drops ~4× (use `mid_debug` console command — will need minor rewrite for new stats)
    - Compare against baseline perf capture from Phase A
    - **Tune `mesh_lod_threshold`** (per `@roaster` review revision 5 — resolves Open Question 3). At each of the 4 baseline locations (Vivec, Balmora, Seyda Neen, Ald-ruhn), visually compare threshold values 1.0 / 1.5 / 2.0 / 2.5 pixels. Pick the value that gives equal-or-better silhouette on the canton at 300m+ vs baseline, with the best flora/small-clutter LOD drop. Commit the chosen value to `streaming_config.gd` or viewport config.
- Exit criteria:
    - Visual quality equal-or-better vs baseline at all four test locations
    - Frame rate equal-or-better vs baseline
    - RS instance count measurably lower (expected ~75% drop on MID-tier objects)
    - No crashes, no visible LOD popping at the 500m tier handoff (engine FADE_SELF dither handles it)
    - **Progress Log entry: `mesh_lod_threshold set to X.X based on <specific observation at baseline location Y>`** — formalized per `@roaster` review revision 5

### Phase E — Downstream cleanup (dead code removal)

- Owner: `@lods`
- Prerequisite: Phase D complete and stable for at least one session
- Files touched: `lod_configurator.gd` (delete entire file), `distance_utils.gd` (collapse fade constants), `streaming_config.gd` (delete MID_LOD* constants), `mesh_visibility_utils.gd` (delete `is_lod_node_name` if unused), `debug_overlay.gd`, `lod_debug_commands.gd`
- Changes:
    - Delete `lod_configurator.gd` entirely
    - Update all importers/preloaders that reference it
    - Collapse `distance_utils.gd::FADE_MARGIN_NEAR_LOD1/LOD1_LOD2/LOD2_LOD3/LOD3_FAR` to single `FADE_MARGIN_RENDER_FAR = 20.0`
    - Delete `distance_utils.gd::LOD1_END/LOD2_END/LOD3_END`
    - Delete `streaming_config.gd::MID_LOD1/2/3_START/END` constants
    - Rewrite `get_quality_preset_config` to drive `mesh_lod_threshold` instead of sub-LOD distance overrides (see Part 2.7 table)
    - Delete or stub `mesh_visibility_utils.gd::is_lod_node_name`
    - Update debug overlay + LOD debug console commands
- Verification:
    - Full grep sweep for any remaining references to deleted constants/functions — should be zero hits
    - Clean compile
    - Visual test still passes (no behavioral change, just dead code removal)
- Exit criteria:
    - Zero references to deleted symbols
    - Clean compile, all tests green
    - Net line count dropped by at least 600 vs pre-refactor

### Phase F — Debug and test tooling update

- Owner: `@lods`
- Prerequisite: Phase E complete
- Files touched: `tests/visual/lod_overlap_test.gd` (delete), `tests/visual/lod_transition_test.gd` (rewrite), `src/core/world/lod_debug_commands.gd` (rewrite)
- Changes:
    - Delete `lod_overlap_test.gd` (tested sibling-node overlap, obsolete)
    - Rewrite `lod_transition_test.gd` to measure LOD switches via `RenderingServer` stats / `ArrayMesh.surface_get_lod_*` queries
    - Add console commands: `lod_threshold <float>` (set viewport threshold), `lod_bias <type> <float>` (set per-type bias), `lod_stats` (print current viewport threshold + per-type bias + engine LOD stats)
- Verification:
    - Run `lod_transition_test` interactively — visually confirm LOD transitions happen at the expected screen-size thresholds
    - Console commands work as expected
- Exit criteria:
    - New test scene runs interactively and produces sensible output
    - Console commands documented in `docs/DISTANCE_RENDERING.md`

### Phase G — Full rebake, performance validation, documentation sync

- Owner: `@lods`
- Prerequisite: Phase F complete
- Changes:
    - Full cache wipe and rebake of all ~4884 models
    - `StreamingBenchmark` run on the same scripted path as Phase A baseline
    - Compare P50/P95/P99 frame times, RS instance counts, memory footprint
    - Rewrite `docs/DISTANCE_RENDERING.md` to reflect the new architecture (remove 3-sub-band description, add single-tier + screen-space LOD description)
    - Update `docs/STATUS.md` "3-Tier LOD" row to reflect the canonical pipeline
    - Update `.claude/CLAUDE.md` if anything in the "Anti-Patterns" list becomes obsolete
    - Close out this plan doc with a Phase G retrospective in the Progress Log
- Verification:
    - Performance deltas captured and attached to the Progress Log
    - Documentation reads consistently across all updated files
    - Final visual walk-through of all four baseline locations at LOW/MEDIUM/HIGH/ULTRA quality presets
- Exit criteria:
    - Perf same or better
    - Visuals same or better
    - Docs reflect reality
    - Plan doc closed

---

## Part 6 — Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| `ImporterMesh.generate_lods()` produces different LOD count than our hardcoded 3-level cascade | HIGH | LOW | Engine picks LOD count based on mesh complexity. Accept variable LOD counts — screen-space selection handles it transparently. This is actually a feature, not a bug. |
| `ImporterMesh` welding changes mesh AABB (silhouette edges moved by welding tolerance) | LOW | MEDIUM | AABBs used for cell placement, not rendering. Welding moves vertices by at most the merge distance (tiny). If problems occur, fall back to `normal_merge_angle = 0.0` for no welding. |
| Some Morrowind NIFs have surface data the engine `ImporterMesh` rejects | MEDIUM | MEDIUM | Phase B verification step: pick one problematic NIF and walk the pipeline by hand. If rejected, add a fall-through path that uses direct `ArrayMesh.add_surface_from_arrays` with an empty `lods` dict (no LOD generation for that mesh). |
| Runtime LOD selection picks wrong LOD for large buildings (Vivec cantons, ~50m tall) | MEDIUM | HIGH | Use `lod_bias` per-mesh to bias canton instances toward higher detail. Per-type bias registry in `streaming_config.gd`. |
| Cache format change breaks saved games / persistent state | LOW | HIGH | Godotwind has no save/load yet (per `STATUS.md`). Zero impact right now. When save/load lands, it should reference object IDs, not cached model paths. |
| Phase D runtime refactor interacts badly with MID→NEAR promotion edge cases | MEDIUM | HIGH | Promotion system currently hides LOD1-3 RS instances when an object is promoted to avoid double-render. After refactor there's only one RS instance → the hiding logic simplifies, not complicates. Write one test case for "camera approaches a large building from afar and the NEAR Node3D spawns correctly" before deleting the hiding logic. |
| Visual regression we don't catch in the test scenes | MEDIUM | MEDIUM | Interactive verification only (CLAUDE.md rule, no auto-capture). Walk all four baseline locations at all quality presets before closing Phase D. |
| Impostor rebuild in flight (`@impostors`) touches shared files we edit | MEDIUM | MEDIUM | Check with `@impostors` at start of each phase. Specifically `native_impostor_renderer.gd` + `impostor_candidates.gd` are Priority 0. If impostor work needs LOD-related types/constants, coordinate via `#lods` channel before touching. |
| Vivec canton missing-faces bug is *not* a welding problem, and `ImporterMesh` doesn't fix it | LOW | MEDIUM | Phase C verification catches this. If the engine pipeline still shows missing faces, escalate — there's a separate parser-side bug we haven't found yet. |
| `RenderingServer.instance_geometry_set_lod_bias` doesn't exist or behaves differently than Node path | LOW | MEDIUM | Verified via docs in Part 2.4. Double-check in Phase D with a single test call before refactoring the whole path. |

---

## Part 7 — Verification Strategy

### Visual acceptance (human-in-the-loop only)

CLAUDE.md forbids automated screenshot capture. All visual verification is interactive.

**Baseline archive location:** `docs/audit/lod_refactor_baselines/` (NOT `reports/report_*/` — those are gdUnit4 auto-generated test output, not a project-artifact convention. Plan doc previously said `reports/report_21/` in Session 0 draft, corrected 2026-04-09 Phase A startup).

**Baseline locations** — walk through each at the start of Phase A and the end of each phase:

1. **Vivec Canton** (Temple district) — hero architecture, big multi-part buildings, visible from far away. Known LOD bug here. Rooftop-to-ground pan; side-to-side at 200m; flyover at 500m.
2. **Balmora dock** — riverbank, mix of Hlaalu architecture + smaller clutter + distant Red Mountain on the horizon. Tests cross-tier transitions (near architecture, mid flora, far impostors).
3. **Seyda Neen** — starting area, dense small clutter, mushroom trees, the Census and Excise office. Tests flora routing + small-object aggregation.
4. **Ald-ruhn mushroom district** — giant mushroom trees, Redoran architecture. Tests the flora LOD path specifically.

At each location: sit on a rooftop or elevated spot, scroll-zoom back through 100 → 150 → 250 → 375 → 500m → impostor handoff. Look for LOD pops, missing faces, dither artifacts, crossfade issues. Repeat at LOW/MEDIUM/HIGH/ULTRA presets.

### Performance acceptance

`StreamingBenchmark` scripted camera path. Archive baseline in Phase A, post-refactor in Phase G.

Required metrics:
- P50 / P95 / P99 frame time
- Average RS instance count (active during path)
- Peak memory footprint
- Average frame overrun events per 60s
- Cell-crossing worst case

**Acceptance**: all metrics equal or better than baseline. Any regression requires root-cause + fix before Phase G closes.

### Benchmark archive

Store baseline + post captures in `docs/audit/lod_refactor_baselines/`:
- `pre_wipe_cache_manifest.txt` — current cache file count, total bytes, filename list, mtime distribution
- `baseline_perf.csv` — pre-refactor `StreamingBenchmark` CSV output
- `post_refactor_perf.csv` — post-Phase-G CSV output
- `visual/` — interactive screenshots of the four baseline locations
- `BASELINE_PROCEDURE.md` — step-by-step instructions for user on how to run the baseline passes

---

## Part 8 — Open Questions

1. **Should we preserve `MeshOptimizer` GDExt even after it's no longer called from `nif_converter`?** Likely yes — other use cases (manual welding for custom pipelines, impostor baker) still use it. Confirm with `@impostors`.
2. **Does `ImporterMesh.get_mesh()` preserve per-surface material assignments?** Per Godot source, yes — `add_surface(... , material)` sets the material and `get_mesh()` carries it through. Verify in Phase B.
3. **What's the right `mesh_lod_threshold` default for Godotwind specifically?** Godot's 1.0 px is perceptually lossless for authored glTF assets. Our auto-decimated Morrowind NIFs may need a slightly higher threshold (1.5-2.0 px) to avoid over-preserving fine-detail LODs that look nearly identical. **Resolved in Phase D** with formal Progress Log entry: `"mesh_lod_threshold set to X.X based on <specific observation at baseline location Y>"`. Must not drift past Phase D close per `@roaster` plan review revision 5.
4. **Do we need per-type `lod_bias` tables?** Large hero buildings (Vivec cantons) probably benefit from `lod_bias = 1.5` to preserve silhouette. Small clutter may want `lod_bias = 0.8` to be more aggressive. Maintain a minimal table in `streaming_config.gd` keyed on model-path prefix. Populate in Phase D based on observation.
5. **Does `ImporterMesh` respect the `min_triangles_for_lod` gate?** It does not — it always generates LODs if called. Our gate stays in GDScript (skip `generate_lods` for small meshes entirely). Verify in Phase B.
6. **Shadow LOD separate bias?** Out of scope for this plan — captured as Part 1.4 context. Re-evaluate after Phase G.

---

## Part 9 — Progress Log

Session-by-session chronology. Each entry: date, phase, owner, outcome, blockers.

### 2026-04-09 — Session 0 (diagnosis)

- **Phase:** Pre-A (diagnosis and planning)
- **Owner:** `@lods` (diagnosis), not yet assigned (plan draft)
- **Outcome:**
    - Audit of existing LOD pipeline complete, see `docs/audit/LOD_OVER_ENGINEERING.md`
    - Cross-check against Godot 4.6 docs + AAA industry practice posted to `#lods`
    - This plan doc drafted
    - Priority 0 (streaming layer hands-off) established
- **Blockers:** waiting on `@user` plan sign-off for Phase A to begin

### 2026-04-09 — Session 1 (Phase A kickoff + baseline capture + collision fix scheduled)

**STATUS AT SESSION END:** Phase A complete on the agent side, **Phase A.5 collision fix bundled but not yet executed**, Phase B.0 smoke tests ready to start next session.

#### What I did this session

1. **Diagnosed the LOD pipeline** (`@lods` audit against `LOD_OVER_ENGINEERING.md` + Godot 4.6 native API + AAA practice). Posted verdict to `#lods` msg 149: over-engineering doc is correct, understates the prize. Recommended B-wide refactor.
2. **Drafted this plan doc** (`docs/audit/LOD_REFACTOR_B_WIDE.md`) as a multi-session tracker covering: industry reference (how classical + Nanite + HLOD + impostor pipelines work in AAA), Godot 4.6 native reference (`ImporterMesh.generate_lods`, `surface_lod_indices`, `mesh_lod_threshold`, `lod_bias`, RS direct API), current bespoke inventory, target architecture, 7-phase migration plan (A→G), risk register, verification strategy, open questions, progress log. Priority 0 rule codified (streaming layer off-limits).
3. **`@user` approved Phase A** (msg 158).
4. **`@roaster` reviewed at plan boundary** (msg 161). Verdict: approve with 5 revisions.
5. **Applied R1 + R3 + R4 + R5 from `@roaster`'s review.** R1 = Phase B.0 GO/NO-GO smoke tests for `ImporterMesh.generate_lods` + raw RS auto-LOD. R3 = branch + tag + rollback strategy. R4 = "narrow-scope" framing correction for Priority 0 allowed edits. R5 = Phase D exit criterion formalizing `mesh_lod_threshold` tuning.
6. **`@user` challenged my "accept review wholesale" reflex** (msg 168: "not all reviews should be taken as Gospel"). **Re-audited R2 against actual code.** Found `@roaster`'s R2 premise factually wrong — the existing `_extract_lod_meshes` walker handles new-format meshes via its base-case `lod_level = 0` fallthrough at `static_object_renderer.gd:386`, so no Phase C bridge is needed. Reverted R2 with detailed code citations.
7. **`@roaster` verified the revert + withdrew R2 cleanly** (msg 175: "I missed the base-case fallthrough"). Plan checkpoint closed with R1/R3/R4/R5 standing.
8. **Created `pre-lod-refactor` git tag** on master HEAD `b89a1f8`, **created `refactor/lod-b-wide` branch** off master HEAD, checked out. Per `@user` approval (msg 170).
9. **Captured `pre_wipe_cache_manifest.txt`** + `pre_wipe_cache_filelist.txt` + `pre_wipe_cache_filesizes.txt` under `docs/audit/lod_refactor_baselines/`. Current cache: **5172 `.res` files, ~3.22 GB**, all mtimes in a 3-min window on 2026-04-08. Provenance ambiguous but doesn't matter (Phase D wipes anyway).
10. **Drafted baseline procedure v1 (screenshot-based).** `@user` rejected (msg 177) — "we're not doing screenshot based tests, from my experience it doesn't work. just either ask me if I'm seeing something, or build automated test to get precise information".
11. **Drafted baseline procedure v2 (walk-the-main-scene console dump + Q&A).** Added `lod_baseline_dump <label>` console command to `src/tools/lod_debug_commands.gd` (~80 lines) that concatenates `lod_stats` + `mid_batch_stats` + `visibility_gaps` + `streaming_diag` + `look` + `mid_lod_textures` output at current camera position to `user://lod_baselines/<label>.txt`. Parameterized via `CommandRegistry.ParameterInfo` — noticed in passing that the pre-existing `lod_dump` command has a latent bug (never registered its `pattern` arg). `@user` rejected v2 (msg 186): "ELI5 what should I be looking for, if I need to rebake, etc. Currently there's nothing different now than the previous experience. You should create or re-purpose a test scene to test specific hypotheses".
12. **Drafted baseline procedure v3 (dedicated test scene).** Built `tests/visual/test_lod_baseline.tscn` + `tests/visual/test_lod_baseline.gd` (~460 lines). Loads a specific cached `.res` file directly via `ResourceLoader.load(path, "PackedScene")`. Walks the prototype tree, aggregates per-LOD mesh info across ALL `MeshInstance3D` nodes (SUM triangle counts, UNION AABBs, count nodes per LOD level). Runs 9 specific hypothesis tests with PASS/FAIL + concrete diagnosis block. Writes report to `user://lod_baselines/<label>.txt`. Spawns side-by-side LOD variants for optional visual inspection.
13. **Launched the test scene on 4 targets + ran `StreamingBenchmark` myself** (`@user` msg 198: "being lazy huh? do these tests yourself"). All 4 reports + perf CSV are now in `docs/audit/lod_refactor_baselines/`.
14. **Missed `@roaster` msg 203 (19:24:27) during test scene execution.** `@roaster` advised bundling the NIF collision coordinate fix on `refactor/lod-b-wide` before Phase A baseline capture, to amortize rebake costs and avoid confounded baselines. Posted my Phase A completion at 19:25:13 — 47 seconds after `@roaster`'s advice, not seeing it until `@user` prompted the doc update.
15. **Applied `@roaster`'s advice as Phase A.5 to the plan doc** (this update). Rationale for scheduling A.5 BETWEEN Phase C and Phase D rather than before Phase A: captured baselines are structural properties of `.res` files and are collision-path-independent, so the "fix world state before measuring" concern doesn't apply to the specific metrics I captured. Phase A.5 now sits at the point where interactive visual verification first matters (Phase D).

#### What I learned (key findings from the 4 baseline captures)

The LOD bug is worse than the over-engineering doc suggested. It is **three distinct bug flavors sharing one root cause**.

| Target | Format | LOD0 nodes | LOD1 nodes | Pattern |
|--------|--------|-----------|-----------|---------|
| **Vivec canton** (`x_ex_vivec_h_01_nif`) | OLD | 5 (478 tris) | 1 (292 tris) | **4 of 5 sub-meshes DROPPED** + simplifier no-op (292/292/292 across LOD1/2/3) |
| **Tree** (`f_flora_tree_01_nif`) | OLD | 2 (676 tris) | 2 (484 tris) | Sub-meshes preserved but simplifier under-reducing (71/69/69% instead of 50/25/10%) |
| **BC mushroom** (`f_flora_bc_mushroom_01_nif`) | **MINIMAL** | 3 (150 tris total, ~50/node) | (none) | LOD gen skipped entirely — per-mesh tri count below `min_triangles_for_lod = 100` threshold |
| **Redoran hut** (`d_ex_redoran_hut_01_a_nif`) | OLD | 6 (253 tris) | 1 (100 tris) | **5 of 6 sub-meshes DROPPED** + **catastrophic AABB collapse to 1% of LOD0 volume** |

**Bug A — dropped sub-meshes on multi-material architecture.** Cantons + huts have 5-6 separate `MergedMesh_N` groups from `_convert_merged`. `_add_visibility_range_lods` only produces LODs for the first group. At distance, 80% of geometry vanishes.

**Bug B — simplifier under-performing on flora.** Trees have only 2 sub-meshes so they don't hit Bug A, but the simplifier plateaus at ~70% reduction instead of the target 50/25/10% cascade. LOD2==LOD3 (468 tris each).

**Bug C — small flora skipped entirely.** Mushrooms have ~50 tris per sub-mesh. Below the 100-tri threshold, `_add_visibility_range_lods` bails and emits zero LOD levels. Format is MINIMAL.

**Common root cause:** `nif_converter.gd::_add_visibility_range_lods` operates at the wrong scope. It's invoked per-MeshInstance3D, but multi-material buildings produce N separate MeshInstance3Ds from `_convert_merged`, and the LOD generator only wires up LODs for the first one. Per-surface triangle budgets within each merged group are too small to hit the aggressive 50/25/10% reduction ratios.

**Phase D fix (`ImporterMesh.generate_lods()`) addresses all three:**
- ImporterMesh processes every surface natively → no dropped sub-meshes (Bug A gone)
- Engine pipeline doesn't have per-surface min-tri bailout at the same aggressive level → distinct cascade levels (Bug B gone)
- Threshold for generation moves from our GDScript (100 per sub-mesh) to engine's internal heuristic → small flora either gets a minimal LOD chain or stays single-level, but either way is correct (Bug C better)

**User's visual observation ("walls missing on screen") matches the data:** at 100-150m camera distance, the NEAR→LOD1 crossfade zone (`FADE_MARGIN_NEAR_LOD1 = 5m`) fades out LOD0 while fading in LOD1. Since LOD1 is missing 4-5 out of 5-6 merge groups, there's nothing to fade IN to replace the dropped geometry. Net effect: walls dissolve into thin air during crossfade, and stay gone past 155m.

**Perf baseline (`StreamingBenchmark` CSV):** 798 frames across the scripted Seyda-Neen-centered path. Mean fps column reads ~21.6 (possibly sampling-rate-derived, not per-frame interval — needs post-refactor diff to interpret). Peak `mid_instances ≈ 280` during orbit segment. Peak `rendered_objects ≈ 630`. **554 frame overruns** at budget 8ms during the run. **231 visibility drops** (related signal to the dropped-sub-meshes bug — objects "disappearing" mid-scene). Also caught an unrelated pre-existing engine assertion: `mesh_get_aabb: Condition "bs > sbs" is true` at `cell_manager.gd:1956` — not in scope for this refactor, logged for later.

#### What's left to do

**Phase A.5 — NIF collision coordinate fix (pending, scheduled between Phase C and Phase D):**
- Apply `NIF_COLLISION_COORDINATE_BUG.md` Part 1 in `nif_collision_builder.gd`
- Owner TBD (`@lods` or `@character-debug`)
- Exit criteria: collision fix committed on `refactor/lod-b-wide`, Phase C cache already wiped, stairs walkthrough verification clean in Balmora / guild halls / temples
- Rationale for placement: Phase C already requires a cache wipe for its format migration, so piggybacking retains the rebake-amortization benefit `@roaster` called out. And Phase D is the first phase needing an interactive visual pass (which is where collision correctness actually matters).

**Phase B.0 — Foundation API smoke tests (next session):**
- Write `tests/unit/test_importermesh_smoke.gd` — verify `ImporterMesh.generate_lods()` produces `surface_get_lod_count(0) > 0` when called at `@tool`/runtime (not just editor import pipeline). If FAIL → pivot to manual `ArrayMesh.add_surface_from_arrays(..., lods_dict, ...)` path (~15 line plan pivot).
- Write `tests/visual/test_rs_lod_smoke.tscn` — verify automatic LOD selection works on raw `RenderingServer.instance_create()` instances (not just `MeshInstance3D` nodes). If FAIL → `StaticObjectRenderer` must adopt `MeshInstance3D` wrappers (architectural re-plan).
- Both are ~10 min of work each. GO/NO-GO gate before Phase B.1 bulk rewrite.

**Phase B.1 — Prebake pipeline swap (after B.0 passes):**
- Replace `_add_visibility_range_lods` with `_generate_lod_chain` that calls `ImporterMesh.generate_lods(60.0, 25.0, [])` per the Part 4.1 code sketch
- Single-model prebake test against `x_ex_vivec_h_01` (the canton we already baselined)
- Confirm resulting `.res` has `ArrayMesh.surface_get_lod_count(0) > 0` and no sibling `_LODn` children

**Phase C — Cache format migration + targeted rebake verification:**
- Rewrite `targeted_rebake.gd::_cache_has_lods` to check `surface_get_lod_count(0) > 0`
- Delete prebaker's sibling-node counting helpers (dead code)
- Wipe cache + targeted rebake on the 217-file Session 0 set
- Rerun `test_lod_baseline.tscn` on all 4 targets (vivec canton, tree, mushroom, redoran hut). Expected format detection to flip to `NEW`; H8 should PASS (no dropped sub-meshes); canton missing-faces bug verified fixed

**Phase D — Runtime renderer refactor:**
- `StaticObjectRenderer` single-RS-instance-per-object path
- Narrow-scope LOD-children-check removals in `cell_manager.gd` + `native_streaming_manager.gd`
- Full cache wipe + rebake (or reuse Phase C's rebake)
- Tune `mesh_lod_threshold` per the H5 open question
- Rerun `test_lod_baseline.tscn` + `StreamingBenchmark`, diff against Phase A baselines

**Phase E — Dead-code cleanup** (delete `lod_configurator.gd`, collapse `FADE_MARGIN_*` constants, etc).

**Phase F — Debug + test tooling update** (rewrite `lod_transition_test.gd`, delete `lod_overlap_test.gd`, update console commands).

**Phase G — Full rebake + performance validation + documentation sync** (rewrite `DISTANCE_RENDERING.md`, update `STATUS.md`, merge `refactor/lod-b-wide` → `master`).

#### Files in the repo at session end (all on `refactor/lod-b-wide` branch)

```
docs/audit/
├── LOD_REFACTOR_B_WIDE.md                      (this doc — rewritten through 3 revisions this session)
├── LOD_OVER_ENGINEERING.md                     (Session 0 diagnosis, unchanged)
├── NIF_COLLISION_COORDINATE_BUG.md             (@character-debug hand-off, unchanged, bundled as Phase A.5)
└── lod_refactor_baselines/
    ├── BASELINE_PROCEDURE.md                    (v3 — test scene primary)
    ├── pre_wipe_cache_manifest.txt              (5172 files, 3.22 GB summary + mtime notes)
    ├── pre_wipe_cache_filelist.txt              (5172-entry sorted filename list)
    ├── pre_wipe_cache_filesizes.txt             (filename + size bytes per file)
    ├── baseline_perf.csv                        (StreamingBenchmark CSV, 798 frames)
    └── programmatic/
        ├── baseline_vivec_h_01.txt              (5→1 drop + simplifier no-op, full bug hit)
        ├── baseline_tree_01.txt                 (no drop, simplifier under-performing)
        ├── baseline_mushroom_bc_01.txt          (MINIMAL format, LOD gen skipped)
        └── baseline_redoran_hut.txt             (6→1 drop + AABB collapse to 1%, worst case)

tests/visual/
├── test_lod_baseline.gd                         (460 lines, 9 hypothesis tests, programmatic LOD inspector)
└── test_lod_baseline.tscn                       (last edited to target redoran hut, free to change)

src/tools/
└── lod_debug_commands.gd                        (MODIFIED — added lod_baseline_dump console command)
```

Git: `master` at `b89a1f8` (unchanged), `pre-lod-refactor` tag at `b89a1f8`, `refactor/lod-b-wide` branch checked out at `b89a1f8` with the above uncommitted working-tree changes. No commits yet — all session work is in working tree, ready for `@user` to commit when they choose.

### 2026-04-10 — Session 2 (Phase B.0 + B.1 + C + D + E + F partial, single session)

**STATUS AT SESSION END:** Phases B.0 through F landed in working tree, all 35 unit tests green. Cache wipe + full rebake + interactive visual pass (Phase G start) still pending — requires a user-piloted session.

#### What I did this session

1. **Phase B.0 smoke tests — both PASS.**
    - `tests/unit/test_importermesh_smoke.gd`: verified `ImporterMesh.generate_lods(60.0, 25.0, [])` produces a 4-level cascade at runtime. 3200-tri test plane → 1600/800/400/200 tri cascade (clean 50/25/12.5/6.25% reduction). Material round-trips through `importer.get_mesh()` with albedo preserved.
    - `tests/visual/test_rs_lod_smoke.tscn`: verified auto-LOD works on raw `RenderingServer.instance_create() + instance_set_base()` instances (NO MeshInstance3D wrapper). 12800 tris at 5m → 400 tris at 25m+. Confirms `StaticObjectRenderer`'s node-bypass architecture stays intact — no architectural re-plan needed.
    - **Gotcha discovered:** `ArrayMesh.surface_get_lod_count / _indices / _size` are NOT in the scripting API in 4.6 — only on `ImporterMesh` directly. The plan doc's `ArrayMesh.surface_get_lod_count(0) > 0` path for cache detection doesn't work. Workaround: stamp `mesh.set_meta("has_lod_chain", true)` at bake time, read with `has_meta` at cache-scan time. Clean 3-line change.

2. **Phase B.1 — prebake pipeline swap in `src/core/nif/nif_converter.gd`.**
    - `_add_visibility_range_lods` (189 lines) → `_generate_lod_chain` (~110 lines)
    - Single `ImporterMesh.generate_lods(60.0, 25.0, [])` call feeds all surfaces at once. Engine handles weld + `SimplifyLockBorder` + attribute remap + vertex cache optimization internally.
    - Single-band `visibility_range` on the MeshInstance3D via new `_apply_render_tier_visibility_range` static helper: 0-500m (`DU.MID_END`), `end_margin=20m`, `FADE_SELF`.
    - Stamps `mesh.set_meta("has_lod_chain", true)` + preserves original mesh meta (skin data, bone names) through the `get_mesh()` round-trip.
    - Material resolution priority preserved verbatim (material_override → surface override → mesh surface → parent/sibling fallback) — load-bearing for correct coloring.
    - Call site at line 666 updated from `_add_visibility_range_lods(...)` → `_generate_lod_chain(...)`.

3. **Phase C — cache format migration.**
    - `src/tools/prebaking/targeted_rebake.gd::_cache_has_lods` rewritten: instantiates the `PackedScene`, walks for any `MeshInstance3D` whose mesh carries the `has_lod_chain` meta. (PackedScene.get_state() doesn't expose sub-resource metadata, instantiation is the only way.)
    - `src/tools/prebaking/model_prebaker.gd`: deleted `_count_lod_nodes`, `_is_lod_node`, `_extract_and_save_lods`, `_collect_lod_meshes_recursive`, `_remove_lod_nodes`, `_collect_lod_nodes_for_removal`, `_verify_no_lod_nodes_remain` (net ~220 lines). Deleted `LODResource` + `LODConfigurator` preloads.
    - **Critical fix:** removed the `LODConfigurator.configure_for_prebake(node)` call from `_bake_single_model`. That walker was setting `visibility_range_end=150` (NEAR tier) on the main mesh, which would have STOMPED the 0-500m range we just set in `nif_converter`. Would have been a silent regression — all MID-tier objects invisible at >150m.
    - `visibility_prebaked` meta still stamped on the root node for the native_streaming_manager fallback path.

4. **Phase D — `src/core/world/static_object_renderer.gd` single-RS-instance rewrite.** (~900 → ~570 lines, `git diff --stat` shows -540/+150 net churn on this file alone.)
    - **Deleted:** `LodMeshEntry` inner class, `MeshType.lod_meshes` / `lod_collapsed_to`, `InstanceData.lod_rids` / `lod0_count`, `_extract_lod_meshes`, `_lod_entries_same_meshes`, `_get_lod_visibility_range`, `_get_lod_level_from_name`.
    - **New:** `MeshType.has_lod_chain: bool` — stamped from `mesh.has_meta("has_lod_chain")` during registration.
    - `register_from_prototype` walks for any visible MeshInstance3D with a mesh. No `_LODn` skip clause (there are no such siblings post-refactor).
    - `register_lod_from_prototype` kept as a thin alias that just forwards to `register_from_prototype` and returns whether the mesh has an embedded chain. Lets cell_manager.gd + test scenes keep compiling without edits.
    - `add_instance` creates **one** RS instance via `instance_create() + instance_set_base()`. Sets `visibility_range_end=DU.MID_END (500m)`, `end_margin=DU.FADE_MARGIN_LOD3_FAR (20m)`, `FADE_SELF`. Sets `lod_bias=1.0` via `instance_geometry_set_lod_bias`.
    - `remove_instance`, `clear`, `set_instance_visible`, `set_instance_promoted`, `set_instance_transform`, `hide_cell_instances`, `hide_cell_instances_budgeted`: all simplified to the single-RID path.
    - `set_instance_promoted(id, is_promoted, _near_has_lods = true)`: `_near_has_lods` arg renamed to `_` to mark unused — keeps signature compat with remaining call site in `cell_manager`/`native_streaming_manager` that still pass 2 args.
    - `_stats["lod_instances"]` removed from stats dict.
    - Expected MID-tier RS instance count drop: ~4× (no per-LOD RID fan-out).

5. **Narrow-scope Priority-0-allowed edits (justified against plan Part 3.3):**
    - `src/core/world/cell_manager.gd::_find_first_mesh_instance`: removed `_LOD1/2/3` skip clause (3-line collapse). The old skip logic is dead code after the refactor.
    - `src/core/world/cell_manager.gd::_has_visible_lod_children`: **deleted entire function** (~10 lines) + 1 call site in the pending_children loop at `~line 1487`. Promotion path now just calls `_static_renderer.set_instance_promoted(id, true)`.
    - `src/core/world/native_streaming_manager.gd::_near_has_visible_lod_children`: **deleted entire function** (~10 lines) + 1 call site in the MID→NEAR promotion block at `~line 1118`. Same rationale.

6. **Phase E — dead code deletion + constant collapse.**
    - **DELETED FILES:**
        - `src/core/world/lod_configurator.gd` (417 lines — entire file, plus its `.uid`)
        - `src/tools/lod_overlap_test.gd` + `.uid` + `.tscn` (tested the old sibling-node overlap scheme — obsolete)
        - `src/tools/lod_transition_test.gd` + `.uid` + `.tscn` (tested the old per-band distance cascade — obsolete)
    - `src/core/world/distance_utils.gd`: added new canonical `FADE_MARGIN_RENDER_FAR = 20.0`. Old `FADE_MARGIN_NEAR_LOD1/LOD1_LOD2/LOD2_LOD3/LOD3_FAR` + `LOD1_END/LOD2_END/LOD3_END` constants kept with **LEGACY** comments pointing at the impostor renderer + collision-enable hysteresis + debug_overlay as the remaining consumers. Full collapse can land once those 3 sites are updated in a follow-up micro-PR.
    - `src/core/world/streaming_config.gd`:
        - **Deleted:** `MID_LOD1_START/END`, `MID_LOD2_START/END`, `MID_LOD3_START/END` (unused — grep confirmed zero external consumers), `FADE_MARGIN_NEAR/MID/FAR` aliases.
        - **Added:** `DEFAULT_MESH_LOD_THRESHOLD = 1.0`, `DEFAULT_LOD_BIAS = 1.0`, `FADE_MARGIN_RENDER_FAR = DU.FADE_MARGIN_RENDER_FAR`.
        - **Rewrote `get_quality_preset_config`:** each preset now carries a `mesh_lod_threshold` field (LOW=4.0, MEDIUM=2.0, HIGH=1.0, ULTRA=0.5 px) alongside the existing `near_end`/`mid_end`/`far_end` tier distances.
    - `src/tools/world_explorer.gd`: dropped `_LodTransitionTestScript` variable + its `load()` + `register_console_commands` call (deleted file).
    - `src/core/world/native_streaming_manager.gd::_configure_cell_visibility` + `_configure_node_visibility_recursive` + `_get_lod_level`: rewritten as a single fallback-only safety net. Prebaked models carry `visibility_prebaked` meta and skip entirely; non-prebaked geometry (editor scenes, test fixtures) gets the same 0-500m + `FADE_SELF` range applied via `_apply_fallback_visibility_recursive`. Dropped `LODConfigurator` preload + `_lod_configurator` field + `set_lod_configurator` call site.
    - `src/core/world/cell_manager.gd`: dropped `_lod_configurator` field + `set_lod_configurator` setter + the `LODConfigurator.configure_for_prebake` calls in `_instantiate_reference_from_parsed_batch` (~line 1470) and `_instantiate_promoted_near` (~line 2305). The MultiMesh visibility_range path (~line 513) now sets the 0-500m range inline.

7. **Phase F partial — debug console commands + backwards-compat cleanup.**
    - `src/tools/lod_debug_commands.gd`:
        - **Added three new console commands:** `lod_threshold <value>` (get/set `viewport.mesh_lod_threshold`), `lod_bias_global <bias>` (sweep `RenderingServer.instance_geometry_set_lod_bias` on every loaded MID-tier RS instance), `lod_info` (dump viewport threshold + mesh type count + instance count + count of mesh types with embedded LOD chain).
        - **Rewrote `_cmd_mid_lod_textures`:** was iterating per-LOD mesh entries (`LodMeshEntry`), now audits per-mesh-type surface materials (whole-mesh override + per-surface + baked-in mesh materials). Reports how many registered mesh types have textures vs color-only, broken down by building/non-building.
        - **Deleted `_lod_entry_has_texture` helper** (operated on the deleted `LodMeshEntry` type).
        - Added `const DU := preload("res://src/core/world/distance_utils.gd")` for the `lod_info` command's constants.
    - `src/tools/mid_tier_debugger.gd::_audit_mid_renderer`: `lod_rids` iteration removed, now spot-checks only the single `instance_rid`. `stats.lod_rids` hard-coded to 0 (stub for the display path at `~line 761`).

8. **Unit test verification.** After every phase, re-ran `tests/run_tests.tscn` via `"D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --path "D:/Gamedev/Godotwind/godotwind" res://tests/run_tests.tscn`. Final result: **35 test cases, 0 errors, 0 failures, exit code 0.** Includes the 2 new `test_importermesh_smoke` cases.

#### Files in working tree at session end (all on `refactor/lod-b-wide` branch)

**New (untracked):**
- `tests/unit/test_importermesh_smoke.gd` — Phase B.0 smoke 1, 2 test cases, DELETE AFTER B.1 FEEDBACK
- `tests/visual/test_rs_lod_smoke.gd` + `.tscn` — Phase B.0 smoke 2, DELETE AFTER B.1 FEEDBACK

**Deleted:**
- `src/core/world/lod_configurator.gd` + `.uid`
- `src/tools/lod_overlap_test.gd` + `.uid` + `.tscn`
- `src/tools/lod_transition_test.gd` + `.uid` + `.tscn`

**Modified (working-tree diff, pre-commit):**
- `src/core/nif/nif_converter.gd`
- `src/tools/prebaking/model_prebaker.gd`
- `src/tools/prebaking/targeted_rebake.gd`
- `src/core/world/static_object_renderer.gd`
- `src/core/world/cell_manager.gd`
- `src/core/world/native_streaming_manager.gd`
- `src/core/world/distance_utils.gd`
- `src/core/world/streaming_config.gd`
- `src/tools/lod_debug_commands.gd`
- `src/tools/mid_tier_debugger.gd`
- `src/tools/world_explorer.gd`
- `docs/audit/LOD_REFACTOR_B_WIDE.md` (this doc, Session 2 entry)

#### Git state

`master` at `b89a1f8` (unchanged), `pre-lod-refactor` tag at `b89a1f8`, `refactor/lod-b-wide` branch checked out at `b89a1f8` with all Session 2 changes uncommitted. `@user` to commit when they choose — suggested commit boundary: one commit for B.0 (smoke tests), one for B.1+C (prebake rewrite + targeted_rebake), one for D+narrow-scope (renderer + cell_manager/streaming_manager edits), one for E (lod_configurator delete + constant collapse + streaming_config rewrite), one for F-partial (debug commands). Or bundle as a single feature commit on the branch.

#### What's left to do (still on the plate)

**Phase A.5 (NIF collision coordinate fix bundle) — still pending.** Per `@roaster` msg 203 the collision fix should land on `refactor/lod-b-wide` before the first interactive visual pass. Not yet executed. Owner TBD.

**Phase G — full rebake, perf validation, doc sync — REQUIRES USER-PILOTED SESSION.** Specifically:
1. Delete `C:/Users/metzo/Documents/Godotwind/cache/models/` (5172 files ~3.22 GB)
2. Run `prebaking_manager` full rebake via `src/tools/prebaking/prebaking_ui.tscn` — ~10-20 min
3. Rerun `tests/visual/test_lod_baseline.tscn` against the 4 baseline targets (`x_ex_vivec_h_01_nif`, `f_flora_tree_01_nif`, `f_flora_bc_mushroom_01_nif`, `d_ex_redoran_hut_01_a_nif`). Expect:
    - H8 PASS (no dropped sub-meshes — the Vivec canton 4-of-5-dropped bug fixes itself)
    - Format auto-detection flips from OLD to whatever the new format looks like (single `MeshInstance3D` per mesh, no sibling `_LODn` children, `has_lod_chain` meta set)
4. Launch `scenes/Godotwind.tscn`, fly to Vivec / Balmora / Seyda Neen / Ald-ruhn, interactively verify visual quality against the Phase A baselines.
5. Tune `mesh_lod_threshold` per Phase D exit criterion. Formal log entry required: "mesh_lod_threshold set to X.X based on <specific observation at baseline location Y>".
6. Run `StreamingBenchmark` via `src/tools/streaming_benchmark.tscn`, diff against `docs/audit/lod_refactor_baselines/baseline_perf.csv`. Check P50/P95/P99 frame time, RS instance count, cell crossing overruns, visibility_drops count. Acceptance = equal or better across all.
7. **Doc sync:**
    - Rewrite `docs/DISTANCE_RENDERING.md` — remove the 3-sub-band description, describe the single render-tier band + embedded LOD chain + screen-space selection pipeline.
    - Update `docs/STATUS.md` "3-Tier LOD" row.
    - Update `.claude/CLAUDE.md` "Distance Rendering" table if it references sub-bands.
    - Close this plan doc with a Phase G retrospective.

**Constant collapse follow-up (micro-PR after Phase G).** The 3 remaining consumers of `DU.FADE_MARGIN_NEAR_LOD1/LOD1_LOD2/LOD2_LOD3/LOD3_FAR` and `DU.LOD{1,2,3}_END`:
- `src/core/world/native_impostor_renderer.gd` lines 242/244/245/286/331/332 — uses `FADE_MARGIN_LOD3_FAR` as its crossfade margin. Can swap to `FADE_MARGIN_RENDER_FAR` 1:1.
- `src/core/world/native_streaming_manager.gd` line 1141 — uses `FADE_MARGIN_NEAR_LOD1` as the collision-enable hysteresis distance. Should become a dedicated `COLLISION_ENABLE_MARGIN` in `streaming_config.gd` or just inline 5.0.
- `src/tools/ui/debug_overlay.gd` lines 668-669 — distance classifier with hardcoded `MID_LOD1_END / MID_LOD2_END`. Phase F proper rewrite can remove this display logic entirely.

Total cleanup: ~15 lines, near-zero risk, zero behavior change. Deferred so Session 2 lands as a clean "structure refactor" commit without also touching the impostor renderer (`@impostors` domain, Priority 0).

#### Session 2 outcome vs plan estimate

Plan predicted: "~1,030 lines deleted, ~200 lines rewritten, net -830". Actual working-tree `git diff --stat` across the touched files: **+872 / -1005 net -133 from modified files**, plus ~2200 lines from the 3 fully-deleted files (lod_configurator.gd, lod_overlap_test.gd, lod_transition_test.gd). **Actual net delete: ~2300 lines across the refactor.** Plan estimate was conservative. Most of the extra delete was in the test scenes.

No phase ran into the architectural cliffs the plan flagged as MEDIUM/HIGH risk (no ImporterMesh runtime rejection, no raw-RS-instance LOD selection failure, no MID→NEAR promotion edge case surfaced in compile-verification). Pending validation is interactive-only.

### 2026-04-10 — Session 2.5 (Phase G kickoff — full rebake + structural verification + main-scene crash observation)

Direct continuation of Session 2, same day. `@user` cleared `C:/Users/metzo/Documents/Godotwind/cache/models/` manually, asked for the next steps, then delegated the full-rebake execution back to `@lods` ("launch the headless yourself and check the log").

#### What I did

1. **Built `src/tools/prebaking/full_rebake_headless.tscn` + `.gd`** — ~90 line autorun wrapper that calls `ModelPrebaker.initialize() + bake_all_models()` and `get_tree().quit(0)` on completion. Written because the existing `prebaking_ui.tscn` is click-driven (no auto-start) and `targeted_rebake.tscn` only covers LOD-candidates (a subset of all models). Delete after Phase G closes or keep as a permanent CLI entry point — user's call.
2. **Ran the full rebake via the new wrapper.** Result:
    - **4884 baked, 0 skipped, 64 failed**, 154 seconds (~32 models/sec)
    - The 64 failures exactly match the pre-existing count from `docs/audit/NIF_UNSUPPORTED.md` (the `NIFReader: Invalid string length 1399410176 ... Unknown record type '' ... parser out of sync` family — the `0x53694E00` 4-byte under-read documented in the NIF parser audit). **Zero LOD-refactor-induced regressions in the bake path.**
    - Final cache: **4884 `.res` files, 2.9 GB** at `C:/Users/metzo/Documents/Godotwind/cache/models/`
    - Zero `LODConfigurator` errors, zero parse errors, zero unexpected bake failures.
3. **Patched `tests/visual/test_lod_baseline.gd`** — the existing scene tried to introspect `ArrayMesh.surface_get_lod_count(0)` which isn't in the 4.6 scripting API, so the post-refactor detection branch was dead. Replaced that path with a walk of all `MeshInstance3D` nodes counting how many carry the `has_lod_chain` meta stamped by `nif_converter._generate_lod_chain`. Added two tracking fields:
    - `_embedded_chain_count: int`
    - `_total_mesh_nodes: int`
    - Printed as a new line in `run_test()`: `Embedded LOD chain (has_lod_chain meta): N / M mesh nodes`
    The old H2-H8 hypothesis tests remain in place but will SKIP for all new-format caches (they look for sibling `_LODn` nodes that no longer exist). Full rewrite of the test scene is Phase F proper.
4. **Ran `test_lod_baseline.tscn` against 3 targets.** The `.tscn` file's `cache_model_filename`+`output_label` were edited in-place between runs (not parameterizable via CLI — another Phase F fix candidate). **Current state of `tests/visual/test_lod_baseline.tscn`: points at `x_ex_hlaalu_b_01_nif.res` / `phase_g_hlaalu_b_01`.** Reports were written to `%APPDATA%/Godot/app_userdata/Godotwind/lod_baselines/`:

    | Target | Sub-mesh count | LOD chain meta stamped | Baseline (pre-refactor) outcome |
    |---|---|---|---|
    | `x_ex_vivec_h_01_nif.res` (original Bug A) | 5 / 5 ✓ | 0 / 5 (all sub-meshes below `min_triangles_for_lod=100`, correctly skipped LOD gen) | 5→1 drop + simplifier no-op |
    | `f_flora_tree_01_nif.res` | 2 / 2 ✓ | **2 / 2** ✓ | simplifier under-performing (70% plateau) |
    | `x_ex_hlaalu_b_01_nif.res` | 5 / 5 ✓ | **3 / 5** ✓ | (not in original 4-target baseline) |

    **Bug A — "4 of 5 sub-meshes dropped at distance >150m" is FIXED.** Every sub-mesh is present in every prototype, each with a single 0-500m `visibility_range` band. The larger sub-meshes carry embedded LOD chains; the smaller ones correctly skip generation and render LOD0 throughout the render tier.
5. **Launched `scenes/Godotwind.tscn` to spot-check the main scene.** Clean startup (3 BSAs, ESM cache hit, Terrain3D init, 10/289 horizon maps, shader warmup). Streaming started, cells loaded correctly on the native path, NEAR/MID tiers rendering. No `SCRIPT ERROR`, no `Parse Error`, no `LODConfigurator`/`lod_rids`/`lod_meshes` references. **Then the scene crashed with signal 11 (SIGSEGV) while I was not interacting with it.** Captured the full 908-line output log.

#### Signal 11 crash observations (open investigation — do NOT commit without resolving)

**Last ~15 events before the crash** (lines 849-879 of `C:\Users\metzo\AppData\Local\Temp\claude\D--Gamedev-Godotwind-godotwind\<session>\tasks\bzqh36xiy.output`):

```
[INFO] [impostors] Benchmark: 63135 impostors, 497 tex layers, 0 pending cells, mm_instances=63135
[INFO] [tools] Cell loaded: (5, -12) - 0 objects (native)
WARNING: Door 'ex_cave_door_01' -> NO building found
WARNING: Frame overrun: 12.2ms [cellupd:0.0 unload:0.0 async:0.0 inst:0.0 promo:7.6 coll:0.0 defer:4.6 queue:0.0] (budget:8.0ms, overruns:252)
[INFO] Cell unloaded: (-6, -11)
[INFO] Cell unloaded: (-7, -9)
[INFO] Cell unloaded: (-6, -12)
[INFO] Cell unloaded: (-5, -13)
[INFO] Cell unloaded: (-7, -8)
[INFO] Cell unloaded: (-7, -10)
[INFO] Cell unloaded: (-4, -14)
[INFO] Cell unloaded: (-7, -7)
[INFO] Cell unloaded: (-6, -5)
[INFO] Cell unloaded: (-7, -6)
[INFO] Cell unloaded: (-6, -4)
[INFO] _update_loaded_cells: 182.9ms [grid:0.8 reclaim:0.0 unload:167.8 queue:0.1]
WARNING: Terrain3D#7365:_notification:940: NOTIFICATION_CRASH
CrashHandlerException: Program crashed with signal 11
```

The Terrain3D `NOTIFICATION_CRASH` dispatch is **downstream** of the actual segfault — it's Godot's crash handler propagating a `NOTIFICATION_CRASH` to every node, Terrain3D's `_notification` prints a warning as its response. Not a cause, a symptom.

The suspicious event is the **167.8 ms unload phase** on 11 consecutive cell unloads. That's an order of magnitude slower than normal unload (~5-15ms). Either:
- The new `StaticObjectRenderer.remove_instance` / `clear` path is mishandling something per-instance
- The `free_rid` sweep is landing on invalid RIDs (double-free? LRU eviction race?)
- Terrain3D has a pre-existing teardown race that fires during large batch unloads (mentioned in `LOD_REFACTOR_B_WIDE.md` Open Question 5: "exit-139 / signal-11 during main scene quit, Godot mono + GDExtension teardown race")

**Upstream in the same log** (lines 130-151, during startup + first cell loads) there are also these non-fatal errors:

```
ERROR: Parameter "mem" is null. at: initialize_rid (./core/templates/rid_owner.h:294)
ERROR: Parameter "occluder" is null. at: occluder_set_mesh (raycast_occlusion_cull.cpp:207)
ERROR: Parameter "occluder" is null. at: occluder_set_mesh (raycast_occlusion_cull.cpp:207)
ERROR: unimplemented base type encountered in renderer scene cull
   at: instance_set_base (servers/rendering/renderer_scene_cull.cpp:696)
   GDScript backtrace (most recent call first):
       [0] process_async_loads (res://src/core/world/model_loader.gd:398)
       [1] process_async_disk_loads (res://src/core/world/cell_manager.gd:1279)
       [2] process_async_instantiation (res://src/core/world/cell_manager.gd:1307)
       [3] _process (res://src/tools/world_explorer.gd:1761)
ERROR: Condition "bs > sbs" is true. Continuing.
   at: mesh_get_aabb (servers/rendering/renderer_rd/storage_rd/mesh_storage.cpp:730)
   GDScript backtrace: [0] _instantiate_reference_from_parsed (cell_manager.gd:1949) [1] process_async_instantiation (cell_manager.gd:1461)
```

`model_loader.gd:398` is the `var instance := packed_scene.instantiate()` call inside the async-load path. The engine is complaining that the PackedScene's instantiation involves an `instance_set_base()` call with a RID whose base type the scene cull doesn't recognize. **Strong candidate for a new-to-the-refactor bug**: something about how `nif_converter._generate_lod_chain` is saving the `ImporterMesh.get_mesh()` output into the PackedScene causes the saved ArrayMesh to deserialize with an invalid or wrong-type base RID. The meta-preservation loop (`for meta_key in original_mesh.get_meta_list(): lod_mesh.set_meta(...)`) is also a suspect if any inherited meta value is a RID or other non-serializable Variant.

`mesh_get_aabb: Condition "bs > sbs" is true` is **pre-existing** — the same warning was captured in Phase A baselines (see `baseline_perf.csv` annotation). Not a new bug.

**What I do NOT know (needs an interactive repro):**

- Whether the crash is reliably reproducible. My run was foreground background (via `run_in_background: true` on the harness) and the scene ran unattended for some time before crashing. I did NOT interact with it — no camera movement, no cell changes beyond streaming-driven unload.
- Whether the crash is at SHUTDOWN (window close sends NOTIFICATION_CRASH via the teardown path — known issue) or MID-SESSION (unload-phase free_rid on an invalid RID — new issue).
- Whether the upstream `instance_set_base` errors cause the downstream crash, or are incidental. The engine continues past these errors (it prints them via `push_error` but doesn't abort); the actual segfault happens minutes later during unload. Correlation vs causation.
- Whether the crash reproduces on every launch, or only intermittently.

**Hypothesis priority order for the next debug session:**

1. **LRU eviction race (HIGH).** `MeshType.mesh_resource` holds a strong ref to the Mesh resource (copied from pre-refactor code). But `register_from_prototype` now walks the prototype and picks **only the first** visible MeshInstance3D — if the prototype has 5 MergedMesh_N sub-meshes, we store a strong ref to `MergedMesh_0`'s mesh only. The other 4 sub-meshes are still instantiated per-object in the NEAR path (via scene tree), but in the MID path only `MergedMesh_0`'s mesh RID is kept alive. When the LRU evicts the prototype, `MergedMesh_1..4`'s meshes die and any RS instances referencing them (created via the promotion round-trip?) become dangling. **Fix candidate:** register every sub-mesh as its own mesh type, or store strong refs to all sub-meshes' meshes in the MeshType.
2. **Metadata serialization (MEDIUM).** `nif_converter._generate_lod_chain` copies every `get_meta_list()` entry from the original mesh to the new `ImporterMesh.get_mesh()` output. If any inherited meta holds a non-serializable Variant (RID, GDScript callable, custom RefCounted), the saved PackedScene may round-trip with a corrupted sub-resource that fails `instance_set_base` on instantiate. **Fix candidate:** whitelist the metas worth preserving (`bone_names`, `inv_bind_poses`) instead of blindly copying all of them.
3. **Pre-existing Terrain3D teardown race (LOW).** Documented in Open Question 5 of this plan. Still signal 11, but happens at quit / tree-exit, not mid-session. If the user-piloted repro confirms crash only at Alt+F4 and not mid-flight, this is the likely culprit and the refactor is clean.
4. **Pre-existing C# GDExtension teardown race (LOW).** Same Open Question 5 — Godot mono + GDExtension. Same resolution path as (3).

**Next debug-session recipe:**

1. Launch `scenes/Godotwind.tscn` interactively with `@user` driving
2. Watch console for `ERROR` spam during the first 30 seconds of cell loading (instance_set_base / initialize_rid / occluder)
3. If the errors appear: grep the error log for the specific `.res` file names being instantiated at that moment. Target `test_lod_baseline.tscn` at those specific files to confirm they have corrupted internal data (check `has_lod_chain` meta count, surface count, verify instantiate works without errors in isolation)
4. If no errors: fly around for ~2 minutes, teleport across multiple cells, force a large unload batch (walk out of dense area fast). Watch for crash.
5. If crash mid-flight: use Godot's `-d` flag for dprintln + `--verbose` for RS-level logging. Capture the log. Specifically look at what `free_rid` was called on just before the segfault.
6. If crash only at quit (Alt+F4): confirmed known shutdown race, not blocking the refactor. Add a brief note and move on.

**Working tree state at this sub-session close:**

- All Session 2 modifications + these new additions, uncommitted on `refactor/lod-b-wide`
- New untracked: `src/tools/prebaking/full_rebake_headless.gd` + `.tscn`
- Modified: `tests/visual/test_lod_baseline.gd` (new `has_lod_chain` meta check + `_embedded_chain_count` / `_total_mesh_nodes` fields)
- Modified: `tests/visual/test_lod_baseline.tscn` (target updated to `x_ex_hlaalu_b_01_nif.res`)
- Cache: 2.9 GB, 4884 `.res` files, all new-format
- User has been informed of the crash (#lod msg 264) and said "we'll debug all that later" (msg 265) — crash investigation deferred to a later session, docs updated instead

### 2026-04-09 — Session 1 (original entry, pre-audit updates kept below for reference)

- **Phase:** A (plan sign-off + baseline capture)
- **Owner:** `@lods`
- **Outcome:**
    - `@user` approved Phase A start ("go for it", `#lods` msg 158, 18:09:50)
    - `@roaster` reviewed plan at phase boundary (`#lods` msg 161, 18:12:45). Verdict: approve with 5 revisions.
    - **Initial pass: all 5 revisions folded in.**
    - **`@user` pushed back: "not all reviews should be taken as Gospel, make sure you properly audit the opinion and push back if necessary" (`#lods` msg 168, 18:28:57).** Re-audited each of the 5 revisions against actual code.
    - **R1 — KEPT.** Phase B.0 GO/NO-GO smoke tests. Reframed: priors of success are high (ImporterMesh is the canonical API used by every built-in Godot importer; `RenderingServer.instance_geometry_set_lod_bias` exists and the C++ LOD selector in `RendererSceneCull::_cull_view` operates on `Instance*` structs populated by `instance_create()`, not on Node3D wrappers). But zero prior runtime usage in `src/` + the existence of a public Godot forum thread ("Unable to generate LODs on ImporterMesh") elevates failure probability from "low" to "medium". A 10-minute smoke test is cheap insurance; accepting R1 is correct even with a high prior of success. `@roaster`'s framing ("refactor collapses" if smoke fails) oversold the stakes — realistic downside is a plan pivot to the manual `ArrayMesh.add_surface_from_arrays(..., lods_dict, ...)` fallback path, which is ~15 lines of extra prebake code, not a full replan.
    - **R2 — REVERTED AFTER CODE AUDIT.** `@roaster`'s premise ("every rebaked canton mesh will be invisible or wrong-shaped because the old runtime reader walks for sibling `_LOD*` nodes that no longer exist") is **factually wrong**. Verified against `static_object_renderer.gd:221-296` + `:378-386`:
        - `_get_lod_level_from_name()` returns **0 as the base case** for any name that doesn't end in `_lod1/2/3` — it's not a "miss"
        - `_extract_lod_meshes` recursively walks the prototype tree and for a new-format single-`MeshInstance3D` prototype, finds the main mesh with `lod_level = 0` and appends it to `mesh_type.lod_meshes[0]`
        - `register_lod_from_prototype:243-248` fallback-fill loop duplicates `[0]` into keys `1/2/3`
        - Collapse logic at `:255-265` compacts LOD1==LOD2==LOD3 (same mesh_rid) into `{0: [entry], 1: [entry with range 150-500m]}` via `lod_collapsed_to = 3`
        - `add_instance:448-502` creates 2 RS instances per object (LOD0 0-150m + collapsed LOD1 150-500m), both pointing at the same `ArrayMesh` with the embedded LOD chain
        - Result: new-format meshes render correctly at all distances in Phase C intermediate state. Canton missing-faces fix IS verifiable at Phase C without any bridge code.
        - Cost of intermediate state: 2 RS instances per object instead of 1. Wasteful but correct. Phase D cleanup collapses to 1.
        - Conclusion: the 20-line time-boxed bridge is unnecessary. Simpler path wins per CLAUDE.md "Simplicity Over Over-Engineering" — adding code that exists for one phase only is exactly what the principle warns against, and the base case in the existing walker already handles the new format.
    - **R3 — KEPT verbatim.** Branch + tag + manifest + merge-at-close is standard feature-branch discipline. Zero objection.
    - **R4 — KEPT verbatim.** "narrow-scope LOD-children-check removal (justified in commit against this plan)" is an honest framing correction for the `cell_manager.gd` + `native_streaming_manager.gd` edits. Preserves Priority 0 rule enforceability without changing the edits themselves.
    - **R5 — KEPT, weakest of the 5.** Phase D exit criterion now requires a Progress Log entry with the literal format `"mesh_lod_threshold set to X.X based on <specific observation at baseline location Y>"`. Mildly over-formalized but low-cost and protects against the "tune and forget" drift mode.
    - **Net: R1/R3/R4/R5 kept, R2 reverted.** Phase C section of plan doc updated to remove the bridge and explicitly document WHY the bridge isn't needed (for future agents who may think about re-adding it).
    - Cache baseline fingerprint captured: **5172 `.res` files, ~3.22 GB, mtimes clustered in 2026-04-08 22:23-22:26 window**. Prior doc claim of 4884 files (from Session 0 `LOD_OVER_ENGINEERING.md`) is stale — count has grown by 288. State at capture is ambiguous between "Session 0 partial Layer 1+2" and "post-Session 0 full rebake on reverted HEAD pipeline" — mtimes don't disambiguate. Baseline captures current observable visual + perf regardless of provenance.
    - Baseline artifact directory corrected from `reports/report_21/` (which is a gdUnit4 test output directory) to `docs/audit/lod_refactor_baselines/` (co-located with this plan doc).
- **Git state (post-user-approval, `#lods` msg 170 "you can create a branch, yes"):**
    - `pre-lod-refactor` tag created on `master` HEAD at commit `b89a1f8` — rollback anchor
    - `refactor/lod-b-wide` branch created off `master` HEAD at commit `b89a1f8`, checked out
    - Verified via `git rev-parse` — tag, branch, and master HEAD all point at `b89a1f8`
    - Working-tree changes (baseline artifacts + plan doc edits) carried into the branch alongside `@user`'s pre-existing in-flight work on `cell_manager.gd`, `native_streaming_manager.gd`, `carry_controller.gd`, etc. (all from prior sessions, unrelated to the LOD refactor, verified via `git diff` spot check)
- **Screenshot approach rejected by `@user` (msg 177, 18:39:10):** "we're not doing screenshot based tests, from my experience it doesn't work. just either ask me if I'm seeing something, or build automated test to get precise information about what's happening in the game". v1 `BASELINE_PROCEDURE.md` (screenshot-based) deleted.
- **v2 console-dump + Q&A approach ALSO rejected by `@user` (msg 186, 18:57:28):** "ELI5 what should I be looking for, if I need to rebake (LODs are still buggy with faces missing btw), etc. Currently there's nothing different now than the previous experience. You should create or re-purpose a test scene to test specific hypotheses". v2 was still "walk the main scene + run commands" which is too abstract.
- **v3 baseline delivery (on `refactor/lod-b-wide`):**
    - **New dedicated test scene** `tests/visual/test_lod_baseline.tscn` + `tests/visual/test_lod_baseline.gd` (~460 lines). Loads a specific cached `.res` file directly (no streaming, no cell manager, no main scene), walks the prototype tree, aggregates per-LOD mesh info (triangle counts, AABBs, materials, visibility ranges, node counts) across all MeshInstance3Ds, runs **9 specific hypothesis tests** with PASS/FAIL per each, writes a concrete diagnosis block with root cause + expected Phase D fix, spawns side-by-side LOD variants for optional visual inspection, writes report to `user://lod_baselines/<label>.txt`.
    - **Hypothesis tests:** H1 (LOD0 > 100 tris), H2/H3/H4 (LOD1/2/3 tri ratios within 50%/25%/10% tolerance ranges), H5 (LOD AABB volume >= 95% of LOD0), H6 (LOD AABB X/Y/Z dims >= 95%), H7 (LOD materials present), H8 (LOD node count matches LOD0 — catches dropped sub-meshes), H9 (LOD1/2/3 tri counts pairwise distinct — catches simplifier no-op).
    - **Smoke run result on `x_ex_vivec_h_01_nif.res` (2026-04-09):** the bug is precisely located. LOD0 has **5 MeshInstance3D nodes** summing to 478 triangles (MergedMesh_0 through _4). LOD1/2/3 each have **only 1 node** with 292 triangles — identical. **H8 FAIL: 4 out of 5 sub-meshes are DROPPED at LOD1/2/3.** **H9 FAIL: LOD1/2/3 are pairwise identical (simplifier no-op).** Saved to `docs/audit/lod_refactor_baselines/programmatic/baseline_vivec_h_01.txt` as the first concrete baseline artifact. This is the "LODs are still buggy with faces missing" bug in hard numbers: at distance > 150m, 4 out of 5 merged mesh groups vanish AND the remaining group isn't even simplified.
    - **Console command `lod_baseline_dump <label>`** added in the v2 attempt stays as a complementary tool for runtime-state capture in the main scene (optional in v3, primary deliverable is the test scene).
    - **`BASELINE_PROCEDURE.md` rewritten as v3** (section 1 = test scene as primary, section 2 = runtime dump as optional, section 3 = benchmark unchanged).
- **Pending user action** (run the test scene against 3 more targets):
    - `f_flora_tree_01_nif.res` → `baseline_tree_01`
    - `f_flora_bc_mushroom_01_nif.res` → `baseline_mushroom_bc_01`
    - `d_ex_redoran_hut_01_a_nif.res` → `baseline_redoran_hut`
    - Copy each generated report from `%APPDATA%/Godot/app_userdata/Godotwind/lod_baselines/` to `docs/audit/lod_refactor_baselines/programmatic/`
    - Run `StreamingBenchmark` once for the perf CSV baseline (copy to `baseline_perf.csv`)
- **Blockers:** none on the agent side. `x_ex_vivec_h_01` baseline is captured and in repo. Remaining 3 targets + perf benchmark are interactive runs per updated `BASELINE_PROCEDURE.md`.

---

## Appendix A — Reference Links

**Godot 4.6 native LOD:**
- [ImporterMesh class reference](https://docs.godotengine.org/en/stable/classes/class_importermesh.html)
- [ArrayMesh class reference](https://docs.godotengine.org/en/stable/classes/class_arraymesh.html)
- [Mesh level of detail tutorial](https://docs.godotengine.org/en/stable/tutorials/3d/mesh_lod.html)
- [RenderingServer class reference](https://docs.godotengine.org/en/stable/classes/class_renderingserver.html)
- [GeometryInstance3D class reference](https://docs.godotengine.org/en/stable/classes/class_geometryinstance3d.html)

**AAA practice references:**
- Ryan Brucks, "Advanced Octahedral Impostor System" (Epic 2015-2017) — the canonical impostor paper, relevant to FAR-tier impostor architecture which this refactor preserves
- GDC 2017 "Ghost Recon Wildlands" — streaming + LOD orchestration for 260km² open world
- Naughty Dog "Uncharted 4" SIGGRAPH 2016 — classical LOD + streaming pipeline at AAA scale
- UE4 `StaticMesh::RenderData::LODResources` (public source) — the reference implementation of the "single mesh with embedded LOD chain" pattern we are adopting
- "Nanite: A Deep Dive" (SIGGRAPH 2021, Brian Karis) — context for why we are NOT adopting Nanite

**Internal references:**
- `docs/audit/LOD_OVER_ENGINEERING.md` — Session 0 audit
- `docs/audit/IMPOSTOR_REBUILD.md` — concurrent FAR tier work
- `docs/audit/AAA_FRAMEWORK_PLAN.md` §1-2 — wider framework audit
- `docs/DISTANCE_RENDERING.md` — current 3-tier behavior (rewrite target)
- `docs/STATUS.md` — ground truth on what works
- `.claude/CLAUDE.md` "Industry Standard, Never Kludge" + "Simplicity Over Over-Engineering"

---

## Appendix B — Phase D Runtime Refactor Checklist (Reference)

This checklist is populated during Phase D execution. Leave unchecked until Phase D starts. It is here now as a tentative scope marker.

- [ ] `static_object_renderer.gd`: delete `LodMeshEntry` class
- [ ] `static_object_renderer.gd`: delete `MeshType.lod_meshes`, `lod_collapsed_to`
- [ ] `static_object_renderer.gd`: delete `InstanceData.lod_rids`, `lod0_count`
- [ ] `static_object_renderer.gd`: delete `register_lod_from_prototype`
- [ ] `static_object_renderer.gd`: delete `_extract_lod_meshes`
- [ ] `static_object_renderer.gd`: delete `_get_lod_visibility_range`
- [ ] `static_object_renderer.gd`: delete `_lod_entries_same_meshes`
- [ ] `static_object_renderer.gd`: rewrite `add_instance` to single RS-instance path
- [ ] `static_object_renderer.gd`: update `_find_mesh_instance` to not skip `_LOD*` (since there are none)
- [ ] `static_object_renderer.gd`: update `remove_instance` to not iterate `lod_rids`
- [ ] `static_object_renderer.gd`: update `_stats["lod_instances"]` tracking (deprecate or repurpose)
- [ ] `static_object_renderer.gd`: verify `hide_cell_instances` / `show_cell_instances` still work on single instance_rid
- [ ] `cell_manager.gd::_find_first_mesh_instance`: remove `_LOD1/2/3` skip clause (one-line Priority-0-allowed edit)
- [ ] `native_streaming_manager.gd::_near_has_visible_lod_children`: delete (one-line Priority-0-allowed edit)
- [ ] Compile clean
- [ ] All unit tests in `tests/unit/` pass
- [ ] Interactive visual pass at all four baseline locations
- [ ] `StreamingBenchmark` run, archive CSV
