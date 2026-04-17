# Phase 3 — World-Scoped Per-Prototype MultiMesh for MID Tier

**Status:** DRAFT v2 — scope simplified per user call 2026-04-17 (see §1.1). Pending final sign-off before implementation.
**Parent plan:** `docs/audit/DISTANT_RENDERING_PLAN_2026_04_17.md` §Phase 3.
**Audit ref:** `docs/audit/DISTANT_RENDERING_AUDIT_2026_04_17.md` §5.2.
**Reviewer pass:** @roaster 2026-04-17 — flagged LOD blocker at horizon range under HLOD-off. Blocker dissolved by §1.1 scope change (MID is no longer authoritative past 300 m).

---

## 1. Goal & Success Criteria

**Goal:** collapse the MID-tier (150-300 m) static draw count to the industry canonical floor of "one draw call per unique (mesh, material) in the world."

### 1.1 Scope — OpenMW pattern, locked by user 2026-04-17

Two configurations, no middle ground:

| HLOD state | NEAR (0-150m) | MID (150-300m) | HLOD (300m-1km) | FAR (1km-5km) | Past range |
|---|---|---|---|---|---|
| **ON** | Node3D + physics | Phase 3 per-prototype MM | Existing `object_paging.gd` merged chunks | Impostor MM | terrain + sky only |
| **OFF** | Node3D + physics | empty | empty | empty | terrain + sky only |

HLOD-off is the OpenMW "no far rendering" path. When HLOD is disabled, nothing renders past NEAR. MID, FAR, and impostors are all HLOD-dependent. This is a deliberate simplification — the alternative (MID carries 150 m-1 km alone) requires per-band LOD partitioning that the @roaster review correctly flagged as blocker-level architectural state.

Net: Phase 3 MID tier is always a narrow 150 m-300 m band. LOD0 is acceptable in that range (audit numbers support this). No per-band LOD machinery needed.

**Coupling implication:** HLOD stops being a "WIP feature we rarely enable" and becomes load-bearing for horizon rendering. Phase 4 HLOD work is mandatory, not optional.

### 1.2 Success criteria (measured via `bench` + HUD)

- `vista` segment `draw_calls` drops by ≥5× vs. current baseline (HLOD-on configuration).
- `rendered_objects` per frame in the 150-300 m band is `sum(live_slots_per_batch)` rather than a raw RS instance count.
- No visible regression: LOD cascade + fade handoff intact, no shimmering, no pop at MID→HLOD handoff at 300 m.
- Works with buildings (multi-sub-mesh prototypes) — current `batch_cell_into_multimesh` excludes them; Phase 3 must not.
- Compatible with Phase 2 shader fade (`spawn_time` routed via per-instance custom_data).
- Compatible with Phase 5 (`FAR_START` = 1 km) — HLOD already holds to 1 km; MID is unaffected.

**Non-goals:**
- Not Nanite / GPU-driven indirect. Not available on Godot 4.6 Forward+.
- Not replacing HLOD. Phase 3 is the per-prototype batcher for 150-300 m. HLOD is the per-chunk merger for 300 m-1 km. Both kept; see §2.5.
- Not changing NEAR-tier path.
- Not touching impostor pipeline.
- Not handling the HLOD-off "horizon rendering" case — explicitly out of scope per §1.1.

---

## 2.5. HLOD Integration

Phase 3 (per-prototype MultiMesh, 150-300 m) and HLOD (per-chunk merged geometry, 300 m-1 km) are **different answers to different questions at different ranges** — both kept long-term, both required for horizon rendering per §1.1.

| Tier | Range | Technique | Draw count | Per-object detail | Vertex count |
|---|---|---|---|---|---|
| **Phase 3 / MID** | 150 m-300 m | Per-prototype MultiMesh (one MM per `(mesh, material)`, slots rendered individually) | 1 per unique `(mesh, material)` | Full — each slot is a distinct mesh with LOD cascade | Full × slot count |
| **HLOD / Object Paging** | 300 m-1 km | Per-chunk merged ArrayMesh (OpenMW Object Paging port: N prototypes in a spatial bucket fused into one mesh with `ImporterMesh.generate_lods(60°, 0.25)` decimation) | 1 per (chunk, material_group) | None — individual objects vertex-welded into one mesh; no LOD cascade across objects | Decimated (per `generate_lods` merge-angle + screen-coverage params) |

**Why both:** per-prototype keeps per-object fidelity in the 150-300 m band where individual silhouettes are still visible. HLOD fuses + decimates at 300 m+ where no individual object's silhouette matters. Industry: RDR2 SLOD tiers, UE5 HLOD fallback, CryEngine `CMergedMeshRenderNode` — all do the same split.

**Why narrow MID band makes Phase 3 simple.** 150-300 m is a 150 m-wide band. Within one prototype's LOD cascade, screen-space selection on a world-origin AABB picks a reasonable LOD even without per-slot LOD picking. At 150 m a tree renders at its closest LOD; at 300 m it drops to the next. Both are acceptable. No γ-band partitioning, no shader-side LOD picking, no per-slot LOD selector needed. (This is the concession the user's §1.1 scope call buys us. Worth revisiting only if 150-300 m LOD drift becomes visible.)

**Dedup handoff (covered by Phase 4):** when HLOD builds a chunk, the instances it absorbs past 300 m must NOT double-render. Registry API supports this cleanly — `registry.remove_instance(instance_id)` releases slots; HLOD's chunk-build publishes the covered instance IDs, chunk-destroy re-adds them. Phase 3's architecture makes Phase 4 a clean bolt-on rather than a lifecycle rewrite.

**Relationship to existing `object_paging.gd`:** current implementation is the OpenMW Object Paging port (user flagged "WIP"). Phase 3 does not rewrite it. Phase 4 adds the dedup handoff. Future HLOD work (cost-benefit tuning, faster merging, better decimation) stays in `object_paging.gd` and is now load-bearing per §1.1.

---

## 2. Architectural Decision: Prototype Registry

**Identity key:** `(mesh_rid: RID, material_rid: RID)`.

- Two instances of the same mesh with the same material override share a batch. Typical case: 10,000 instances of `flora_kelp_01.mesh` → 1 batch.
- Different material override → different batch (rare in MW — most STATs use mesh-baked materials, not `material_override`).

**Multi-sub-mesh prototypes** (buildings: Vivec cantons, Hlaalu huts, Redoran pods):
- Each sub-mesh of the prototype becomes its own batch in the registry.
- An instance of a building claims ONE slot in EACH sub-mesh batch.
- Slot transform per sub-mesh = `world_transform * sub_mesh_local_transform`.
- Releasing an instance releases all its slots atomically.

This is the key win over `batch_cell_into_multimesh`, which excludes multi-sub-mesh prototypes entirely (`static_object_renderer.gd:620-621`).

---

## 3. Per-Batch Data

```gdscript
class PrototypeBatch:
    var mesh_rid: RID
    var material_rid: RID            # may be invalid (null override)
    var multimesh: MultiMesh
    var multimesh_rid: RID
    var rs_instance: RID              # single world-origin RS instance
    var slot_capacity: int            # current allocated slot count
    var slot_count_live: int          # count of active slots
    var slot_freelist: PackedInt32Array  # indices of freed slots
    var slot_transforms: PackedFloat32Array  # packed 12-float Transform3D rows, capacity*12
    var slot_custom_data: PackedFloat32Array # packed 4-float rows, capacity*4 (spawn_time, fade_duration, ...)
    var slot_live: PackedByteArray    # 1 byte per slot: 0 = free, 1 = live (for cull iteration)
```

**Capacity growth:** initial 1024 slots, grow 2× on exhaustion (buffer realloc), never shrink. Measured once (2026-04-17 prior session measurements suggest typical cell load is ~200-500 slots per prototype hash). Grow is rare.

**No per-batch `visibility_range`** — batch spans the world, anchor at world origin. Per-slot distance cull handled by the cull pass (§5).

---

## 4. Registry Data

```gdscript
class PrototypeRegistry:
    var _batches: Dictionary[Vector2i, PrototypeBatch] = {}  # key: (mesh_rid_hash, material_rid_hash)
    var _instance_to_slot: Dictionary[int, Array] = {}  # instance_id -> Array of (batch, slot) pairs (N for N-sub-mesh buildings)
```

(Using `Vector2i` for key because `Dictionary` hashing on tuples is fine; RIDs hash to int64 and pairing two ints is compact.)

---

## 5. Per-Slot Cull Pass

**Pick: CPU cull + packed-buffer write + `multimesh_set_visible_instances`.** C# hot loop. (β in the v1 draft's taxonomy; α and γ dropped — see below.)

Per cull tick:
1. Iterate live slots in the batch.
2. For each slot, compute world-position distance to camera + frustum-plane check.
3. Partition into "visible" vs. "culled" lists (visible = 150-300 m AND inside frustum).
4. Build a packed `PackedFloat32Array` = visible slot transforms + custom_data, back-to-back.
5. `RenderingServer.multimesh_set_buffer(mm_rid, packed_buffer)` — single upload.
6. `RenderingServer.multimesh_set_visible_instances(mm_rid, visible_count)` — GPU renders first N instances only.

Engine frustum-culls the whole batch AABB (world-anchored = always in view, so that's effectively a no-op). GPU pays vertex + fragment cost only for the visible slots in the packed buffer.

**When to tick:** camera moved ≥ `CULL_DISTANCE_HYSTERESIS` (10 m — tighter than a distant cull would need, because the 150-300 m band is narrow) OR camera basis rotated ≥ `CULL_ANGLE_HYSTERESIS` (15°) OR a cell loaded/unloaded (membership changed). Otherwise skip — cull result still valid.

**Per-tick cost (estimated, per batch):**
- N live slots → O(N) distance + frustum check.
- Packed buffer write: O(visible_count × 16 floats) [12 transform + 4 custom_data].
- RS calls: 2.
- Frequency: at walking pace ~2-3 Hz, at running pace ~4-5 Hz, idle ~0.

For ~200 batches × ~200 slots/batch avg × 5 Hz = 200k checks/sec. GDScript = ~25 ms/sec. **C# = ~1-2 ms/sec.** Even on a busy frame the C# cull is ~0.3 ms amortized.

**Why no shader-side discard.** Vertex cost is real — a 5,000-vertex building at 280 m in the MID band shouldn't be shaded if it's off-screen. Shader discard skips fragments, not vertices. Rejected.

**Why no γ-band LOD partitioning.** The simplified scope (§1.1) makes MID a narrow 150-300 m band. Within one prototype's LOD cascade, LOD0 is acceptable across the whole band. γ-banding would 3× the RS instance count and add migration logic to solve a problem we no longer have. Dropped from scope entirely.

---

## 6. Per-Instance Custom Data Layout

`MultiMesh.use_custom_data = true` provides 4 floats per instance via `INSTANCE_CUSTOM`:

| Component | Meaning | Notes |
|---|---|---|
| `INSTANCE_CUSTOM.x` | `spawn_time` | Engine `TIME` value at slot-claim; Phase 2 shader fade-in |
| `INSTANCE_CUSTOM.y` | `fade_duration` | Typically 0.3 s; allows per-instance fade tuning if ever needed |
| `INSTANCE_CUSTOM.z` | reserved | Possible future: tint / random seed / per-instance wind offset |
| `INSTANCE_CUSTOM.w` | reserved | - |

Shader variant `lod_crossfade_multimesh.gdshader` (already exists) rewritten to compute fade:
```glsl
float spawn_time = INSTANCE_CUSTOM.x;
float fade_duration = INSTANCE_CUSTOM.y;
float fade_amount = clamp((TIME - spawn_time) / max(fade_duration, 0.0001), 0.0, 1.0);
```

Mirrors Phase 2's `lod_crossfade.gdshader` change.

---

## 7. C# Boundary

**New file:** `src/native/WorldMidCuller.cs`.

**Interface (called from GDScript):**
```csharp
public static int CullAndPack(
    Vector3[] slotPositions,      // world positions
    byte[]    slotLive,            // 1 = live, 0 = free
    Span<float> slotTransformsFlat, // capacity*12 input, overwritten by packed output
    Span<float> slotCustomDataFlat, // capacity*4  input, overwritten by packed output
    Vector3   cameraPos,
    Plane[]   frustumPlanes,       // 5 planes (near, left, right, top, bottom)
    float     maxDistance,
    Span<float> outPackedTransforms, // visible_count*12 output
    Span<float> outPackedCustomData  // visible_count*4 output
);
```

Returns `visible_count`. Caller passes the output spans to `RenderingServer.multimesh_set_buffer`.

**Measurement hypothesis:** ~20-50× faster than the GDScript equivalent for the inner distance-check + pack loop. Verified by comparing with a GDScript path in a benchmark before committing the C# path.

**NativeBridge wiring:** existing pattern per `src/core/native_bridge.gd`.

---

## 8. Lifecycle — Add / Remove / Promote / Demote

### Add instance (from cell load)
1. `PrototypeRegistry.register_prototype(mesh, material, sub_mesh_count)` (idempotent per prototype).
2. For each sub-mesh of the prototype:
   - `batch = registry.get_or_create_batch(sub_mesh_rid, sub_mesh_material_rid)`.
   - `slot = batch.acquire_slot()` (pop from freelist, or grow if empty).
   - `batch.set_slot_transform(slot, world_transform * sub_mesh_local_transform)`.
   - `batch.set_slot_custom_data(slot, Color(spawn_time, fade_duration, 0, 0))`.
   - `batch.mark_slot_live(slot)`.
3. Record `instance_id -> [(batch_a, slot_a), (batch_b, slot_b), ...]` in `PrototypeRegistry._instance_to_slot`.
4. No RS instance create — the batch's single RS instance already exists and renders all its slots.

### Remove instance (from cell unload)
1. Lookup slots via `_instance_to_slot[instance_id]`.
2. For each `(batch, slot)`:
   - `batch.mark_slot_free(slot)` (sets live byte to 0; transform kept until next cull-and-pack overwrites it).
   - `batch.release_slot(slot)` (push onto freelist).
3. Erase `_instance_to_slot[instance_id]`.

### Promote MID→NEAR (at 150 m)
1. Same as Remove.
2. NEAR-tier Node3D path creates the node.
3. On Demote (camera retreats past 150 m + hysteresis), run the Add path again.

---

## 9. Cell Lifecycle Integration

- **Cell async completion (`cell_manager._finalize_request`):** drop the current `batch_cell_into_multimesh(request.grid)` call entirely. Per-cell batching is gone. Individual Add calls already happened during instantiation, flowing into the registry.
- **Cell unload:** iterate the cell's instance_ids, invoke Remove on each.

---

## 10. Static Object Renderer — Internal Changes

`static_object_renderer.gd`:
- `add_instance` routes to registry instead of creating RS instance + sub_rids.
- `remove_instance` routes to registry's Remove.
- `InstanceData.instance_rid` / `sub_rids` / `mm_slot` / `batch: CellBatch` fields go away. Replace with `batch_slots: Array[Vector2i]` (each entry is `(batch_key_hash, slot)`).
- `batch_cell_into_multimesh` + `_create_cell_batch` + `CellBatch` class: **deleted**.
- `get_promotable_instances` reads distances from the slot transforms via the registry.

Estimated net delta: -200 lines from `static_object_renderer.gd`, +500 lines spread across new `prototype_registry.gd` + `prototype_batch.gd` + `WorldMidCuller.cs`.

---

## 11. Measurement & Rollback Plan

**Before landing:**
- Pick a stable commit baseline (current HEAD: `8d1a135`). Run `bench` HLOD-off. Save to `docs/audit/bench/P3-pre/`. Record draw_calls + FPS per segment.

**After landing (first draft):**
- Run `bench` HLOD-off. Save to `docs/audit/bench/P3-post/`. Compare.
- If `vista` FPS hasn't moved significantly (>+10 FPS), investigate before committing more. Either the cull pass is too expensive, batch management is itself a regression, or the bottleneck isn't draw-call count.

**Rollback:** single-commit revert restores the per-cell batcher. Branch lets us iterate without touching master.

---

## 12. Out-of-Scope — Parked for Later

- **Per-instance LOD picking.** Engine picks LOD from mesh `surface_lod_indices` using the world-origin-anchored batch AABB. Within the narrow 150-300 m MID band, LOD0 is acceptable throughout (see §2.5). Revisit only if LOD drift within the band becomes visible — not expected given the 150 m range.
- **Shadow caster budget per batch.** Shadows already capped at 200 m by `sky_manager.gd:276`. MID band starts at 150 m so only ~50 m of MID casts shadow; fine.
- **`MultiMesh.visible_instance_count` threshold.** If visible_count exceeds `MAX_RENDERABLE_ELEMENTS` (Godot 4.6 default 128k), engine clamps. Per-batch count is in the low thousands at worst — skip.
- **Occlusion culling integration.** `OccluderInstance3D` applies to RS instances; we have one per batch. Whole-batch occlusion is all-or-nothing, useless for world-scoped. Permanently out of scope per @roaster review.
- **HLOD-off horizon rendering.** Explicitly out of scope per §1.1 user call. HLOD-off = only NEAR renders past 150 m.

---

## 13. Rough Implementation Sequence

**Pre-step (verification, no code):**
- Copy the known-good MultiMesh buffer layout from `native_impostor_renderer.gd:1757-1826`. That path already does `multimesh_set_buffer` with `PackedFloat32Array` on Godot 4.6 and works. Read it, document the row-major 12-float transform + 4-float custom_data stride. Anchors §14 Q1.
- Verify `RenderingServer.multimesh_set_visible_instances(mm_rid, n)` exists in Godot 4.6 (vs. property-only path `MultiMesh.visible_instance_count`). If the RS call doesn't exist, switch to the property path — semantics identical, threading assumptions differ.

**Implementation:**
1. Write `prototype_batch.gd` + `prototype_registry.gd` skeletons. Tests for add / remove / grow-on-exhaustion / freelist correctness. GDScript. No cull yet.
2. Wire `static_object_renderer` to use registry for `add_instance`. Keep the OLD per-cell batch path side-by-side (feature flag, env-var or console cmd toggle). Verify: scene launches, MID renders correctly under BOTH toggles.
3. Disable old per-cell batch path. Verify scene still renders + `bench` HLOD-on numbers don't regress. A/B measurement: prior-session "-15-20 FPS" claim validated or falsified here.
4. Add naive GDScript cull pass (per-slot distance + frustum). Measure. Should already be a win over unbatched or batched-but-not-culled state.
5. Port cull pass to C# (`WorldMidCuller.cs`). Marshalling layout per @roaster: `PackedFloat32Array` for positions, 6×4 float array for frustum planes (not `Plane[]`), `Span<float>` C#-side. NativeBridge pattern mirrors `src/core/native_bridge.gd`. Re-measure.
6. Rewrite `lod_crossfade_multimesh.gdshader` for spawn-time fade via `INSTANCE_CUSTOM.x`. Verify fade visible when a cell streams in.
7. Delete dead code: `batch_cell_into_multimesh`, `_create_cell_batch`, `CellBatch` class.
8. Commit per step. Branch isolated.

---

## 14. Risks & Open Questions

**Q1 — Slot transform packing format.** `MultiMesh.set_instance_transform` takes `Transform3D`; internally packs to 12 floats (3×4 matrix). We use `multimesh_set_buffer` directly, so we control the layout — must match what Godot expects (row-major 3×4 for 3D, or equivalent). Verify via Godot source before coding. If layout differs, `multimesh_set_buffer` is a footgun.

**Q2 — Multi-cell instance removal atomicity.** If the cull pass is running on a worker thread while the main thread removes an instance (cell unload), slot state races. Mitigation: cull always runs on main thread (between `_process` phases). C# call is a single synchronous call from main thread — no race.

**Q3 — Growing a batch mid-cull.** If cull is mid-flight and a cell load triggers `acquire_slot` which triggers a `grow()` (buffer realloc), the buffer pointer the C# side holds is stale. Mitigation: cull consumes a snapshot — pass arrays by value, not by reference. The packed output is written into a pre-sized output buffer owned by the caller.

**Q4 — Phase 2 fade continuity.** Current Phase 2 fade is NEAR-only (applied in `_apply_fade_in` to Node3D instances). Phase 3 MID-tier needs the same fade via `INSTANCE_CUSTOM.x`. Confirmed feasible in §6. Visually: MID-tier fade-ins will be less noticeable (objects are ≥150 m away), but correctness matters for the handoff frame.

**Q5 — Buildings with per-material override.** Some STATs override individual sub-mesh materials. Current code handles this via `surface_override_material`. In Phase 3, each sub-mesh batch keys off `(sub_mesh_rid, effective_material_rid)`. If overrides are common, batch count inflates. Profile early.

---

## 15. Sign-Off Gate

Before implementation begins:
- User reads this doc.
- User confirms Option β pick OR requests switch to γ / α.
- User confirms building-per-sub-mesh batching model is acceptable (alternative: keep buildings out of Phase 3 and rely on HLOD — degrades FAR-range fidelity).
- User confirms C# is OK here given the thermal perf profile (not a hot inner loop, but hot enough per tick that C# pays).

Then: branch stays `perf/distant-rendering-2026-04-17`, implementation proceeds per §13.
