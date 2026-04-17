# Phase 3 — World-Scoped Per-Prototype MultiMesh for MID Tier

**Status:** DRAFT — pending user sign-off before implementation.
**Parent plan:** `docs/audit/DISTANT_RENDERING_PLAN_2026_04_17.md` §Phase 3.
**Audit ref:** `docs/audit/DISTANT_RENDERING_AUDIT_2026_04_17.md` §5.2.

---

## 1. Goal & Success Criteria

**Goal:** collapse the MID-tier (150 m-1 km) static draw count to the industry canonical floor of "one draw call per unique (mesh, material) in the world."

**Success criteria (measured via `bench` + HUD):**
- `vista` segment `draw_calls` drops by ≥5× vs. current baseline.
- `rendered_objects` per frame at horizon is expressible as ~`sum(live_slots_per_batch)` rather than a raw RS instance count.
- No visible regression: LOD cascade + fade handoff intact, no shimmering, no pop at MID→FAR tier boundary.
- Works with buildings (multi-sub-mesh prototypes) — current `batch_cell_into_multimesh` excludes them; Phase 3 must not.
- Compatible with Phase 2 shader fade (`spawn_time` routed via per-instance custom_data).
- Compatible with Phase 5 (`FAR_START` = 1 km) — MID holds to 1 km without blowing the budget.

**Non-goals:**
- Not Nanite / GPU-driven indirect. Not available on Godot 4.6 Forward+.
- Not replacing HLOD. Phase 3 is the per-prototype batcher, HLOD is the per-chunk merger. They are complementary tiers (see §2.5 — HLOD Integration), both kept long-term.
- Not changing NEAR-tier path.
- Not touching impostor pipeline.

---

## 2.5. HLOD Integration

Phase 3 (per-prototype MultiMesh) and HLOD (per-chunk merged geometry) are **different answers to different questions at different ranges** — both kept long-term:

| Tier | Range | Technique | Draw count | Per-object detail | Vertex count |
|---|---|---|---|---|---|
| **Phase 3 / MID** | 150 m-1 km (HLOD off) or 150 m-300 m (HLOD on) | Per-prototype MultiMesh (one MM per `(mesh, material)`, slots rendered individually) | 1 per unique `(mesh, material)` | Full — each slot is a distinct mesh with LOD cascade | Full × slot count |
| **HLOD / Object Paging** | 300 m-1 km (when enabled) | Per-chunk merged ArrayMesh (OpenMW Object Paging port: N prototypes in a spatial bucket fused into one mesh with `ImporterMesh.generate_lods(60°, 0.25)` decimation) | 1 per (chunk, material_group) | None — individual objects vertex-welded into one mesh; no LOD cascade across objects | Decimated (per `generate_lods` merge-angle + screen-coverage params) |

**Why both:** per-prototype keeps per-object fidelity at closer range where it matters. HLOD fuses + decimates at distance where no individual object's silhouette is distinguishable anyway. Industry: RDR2 SLOD tiers, UE5 HLOD fallback, CryEngine `CMergedMeshRenderNode` — all do the same split.

**Dedup handoff (covered by Phase 4):** when HLOD builds a chunk, the instances it absorbs must NOT also live as Phase 3 slots. Registry API supports this cleanly — `registry.remove_instance(instance_id)` releases slots; HLOD's chunk-build publishes the covered instance IDs, chunk-destroy re-adds them. Phase 3's architecture makes Phase 4 a clean bolt-on rather than a lifecycle rewrite.

**Relationship to existing `object_paging.gd`:** current implementation is already the OpenMW Object Paging port (user flagged "WIP"). Phase 3 does not rewrite it. Phase 4 adds the dedup handoff. Future HLOD work (e.g. cost-benefit tuning, faster merging, better decimation) is separate and stays in `object_paging.gd`.

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

## 5. Per-Slot Cull Pass — THE Design Decision

Three candidates considered. Pick: **Option β** (CPU cull + packed buffer + `multimesh_set_visible_instances`). C# hot loop.

### Option α — Shader-side `discard`

Vertex-shader the whole slot set. Fragment shader computes view distance and `discard`s past threshold.

**Pros:** zero CPU. Implementation fits in existing shader.

**Cons:** fails to cull vertex work. A 5,000-vertex building slot past 1 km still pays vertex cost. At 100 culled buildings/frame that's 500k wasted vertex ops.

**Rejected.**

### Option β — CPU cull, packed-buffer write, `multimesh_set_visible_instances`

Per cull tick:
1. Iterate live slots.
2. For each slot, compute world-position distance to camera + optionally frustum-AABB check.
3. Partition into "visible" vs. "culled" lists.
4. Build a packed `PackedFloat32Array` = visible slot transforms, back-to-back, in front-to-back order.
5. `RenderingServer.multimesh_set_buffer(mm_rid, packed_buffer)` — single upload.
6. `RenderingServer.multimesh_set_visible_instances(mm_rid, visible_count)` — first N instances render.

Engine frustum-culls the whole batch AABB (which is big and always in view, so this is effectively a no-op). GPU renders only `visible_count` instances from the packed buffer. Vertex + fragment cost paid only for visible slots.

**When to tick:** camera moved ≥ `CULL_DISTANCE_HYSTERESIS` (20 m) OR camera basis rotated ≥ `CULL_ANGLE_HYSTERESIS` (15°) OR a cell loaded/unloaded (membership changed). Otherwise skip — the cull result is still valid.

**Per-tick cost (estimated, per batch):**
- N live slots → O(N) distance + frustum check.
- Packed buffer write: O(visible_count × 12 floats).
- RS calls: 2.
- Frequency: at walking pace ~1-2 Hz, at running pace ~3-4 Hz, idle ~0.

For ~200 batches × ~200 slots/batch avg × 4 Hz = 160k checks/sec. GDScript = ~20 ms/sec. **C# = ~1 ms/sec.** The C# choice matters here.

**Pros:** correct, canonical (Frostbite / OpenMW pattern), C#-amenable, per-slot cull is exact.

**Cons:** buffer rewrite when visibility set changes. Packed buffer order doesn't match slot order (a slot's MM position changes based on visibility), so per-instance custom_data must travel with the transform — easy since custom_data is also packed in the buffer write.

**Selected.**

### Option γ — Distance-band partitioning

Multiple MultiMeshes per prototype keyed by distance band:
- Band 0: 0-300 m
- Band 1: 300-700 m
- Band 2: 700-1000 m

Each band is an independent MultiMesh with its own engine `visibility_range`. Migration between bands on cell-change or player-moved events.

**Pros:** engine visibility_range does the work; no per-frame CPU cull pass.

**Cons:** 3× RS instance count (one per band per prototype). Migration logic is complex. Promotion/demotion becomes "which band do I move to?" every camera-move event. More state to get wrong.

**Rejected — prefer β's single-batch simplicity.** γ stays parked as a fallback if β's per-frame cost is measured as too high on final profiling.

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

- **Shadow caster budget per batch.** Batches past ~300 m probably don't need to cast sun shadows. Gated by Phase 1's already-capped 200 m shadow distance at `sky_manager.gd:276`, which side-steps this for now.
- **Per-instance LOD picking.** Engine picks LOD from mesh `surface_lod_indices`; this works at the MultiMesh level by evaluating the world-origin-anchored AABB, which is wrong for world-scoped. Two possible fixes: (a) LOD selection in the cull shader, picking LOD level per slot from distance; (b) accept LOD0-only at MID range and rely on HLOD / impostor for further-out simplifications. Pick (b) initially — simpler — reassess if GPU is the bound.
- **`MultiMesh.visible_instance_count` threshold.** If visible_count exceeds `MAX_RENDERABLE_ELEMENTS`, engine clamps. Godot 4.6 default is 128,000 which we're nowhere near per batch — skip for now.
- **Occlusion culling integration.** `OccluderInstance3D` applies to RS instances, which we have one of per batch. Whole-batch occlusion = all or nothing. Skip; let CPU distance cull carry the weight.

---

## 13. Rough Implementation Sequence

1. Write `prototype_batch.gd` + `prototype_registry.gd` skeletons. Tests for add / remove / grow-on-exhaustion / freelist correctness. **GDScript**, no cull yet.
2. Wire `static_object_renderer` to use registry for `add_instance`. Keep the OLD per-cell batch path side-by-side (feature flag). Verify: scene launches, MID renders correctly.
3. Disable old per-cell batch path. Verify again.
4. Add naive GDScript cull pass (per-slot distance). Measure. Should already be a win.
5. Port cull pass to C# (`WorldMidCuller.cs`). Re-measure.
6. Rewrite `lod_crossfade_multimesh.gdshader` for spawn-time fade via `INSTANCE_CUSTOM.x`. Verify fade works in MultiMesh path.
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
