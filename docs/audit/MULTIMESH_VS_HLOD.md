# MultiMesh Batching vs HLOD Merging — Compatibility Analysis
**Date:** 2026-04-16 · **For:** next agent taking steady-state FPS work

Two systems reduce draw calls for distant objects. They target different distance ranges
and are **complementary, not conflicting**.

---

## System Overview

### MultiMesh Batching (proposed, partially implemented)

**What it does:** Groups all MID-tier RS instances of the *same mesh* into a single
`MultiMesh` resource — one draw call per unique mesh type instead of one per instance.

**Range:** MID tier: 150-500m (0-300m with HLOD enabled; see below).

**Mechanism:**
- `RenderingServer.multimesh_set_instance_transform(multimesh, i, xform)` per instance
- One `RenderingServer.instance_set_base(instance, multimesh_rid)` draws all at once
- Engine handles GPU instancing internally (D3D12 DrawIndexedInstanced)

**Dead code:** `cell_manager.gd` lines 335-520 has a `LodMultiMeshBatcher` class that
does this — but it's on the **sync** loading path, which never runs at runtime (async is
default). Would need porting to the async path to be useful.

**Cost:** One MultiMesh per mesh type per visible cell range. Memory: ~48 bytes/instance
for transforms. At 14k MID instances of ~300 unique mesh types → ~300 MultiMesh objects.

**Impact estimate:**
- Current: 8,338 draw calls (1 RS instance per object)
- With batching: ~300-500 draw calls for MID tier + ~200 for NEAR tier ≈ 500-700 total
- Expected FPS: breaks 54 FPS GPU ceiling, target ≥60 FPS steady

---

### HLOD Merging (implemented, enabled via `hlod_enable`)

**What it does:** At bake time (or runtime via WorkerThreadPool), merges the static
geometry from multiple objects in a chunk into a *single combined ArrayMesh*, then creates
one RS instance per chunk. This is Unreal's HISM / Unity's StaticBatchingUtility pattern.

**Range:** 300-1000m (adaptive chunk sizes: 1×1 @ 150-300m, 2×2 @ 300-600m, 4×4 @ 600-1000m).

**Status:** Working (`hlod_cells=~32` confirmed). Missing-objects issue under investigation
(see `docs/audit/OBJECT_PAGING_SESSION_2026_04_16.md`).

**Impact:** Collapses potentially thousands of RS instances at 300-1000m into ~32-100
chunk instances. Already contributing to draw call reduction at that range.

---

## Compatibility

They are **complementary** — operating at different ranges:

```
0m ──── 150m ──── 300m ──── 1000m ──── 5000m
  NEAR     │  MID   │  HLOD  │   FAR
  Node3Ds  │ (Multi)│ merged │ impostors
```

- `MultiMesh batching` targets 150-300m (MID tier below HLOD handoff)
- `HLOD merging` targets 300-1000m (replaces individual MID RS instances with merged geometry)

With HLOD enabled, MID range shrinks from 0-500m to 0-300m. MultiMesh batching still applies
to the 150-300m slice — where objects are close enough to need individual transforms but far
enough not to need full Node3D/physics.

**No conflicts:**
1. HLOD operates on loaded cell data AFTER MID instances exist. MultiMesh batching replaces
   how those MID instances are drawn — the cell loading pipeline is unchanged.
2. Objects that enter HLOD range (>300m) are replaced by merged geometry. The MultiMesh
   for those objects would be destroyed/updated as cells exit MID range — same lifecycle as
   the current individual RS instance destruction.
3. SubsystemToggles: `toggle mid false` should disable MultiMesh instances (same as RS
   instance hiding today). `toggle hlod false` disables the merged chunks. Independent.

---

## Implementation Path for MultiMesh Batching

### What exists

`cell_manager.gd` lines 335-520: `LodMultiMeshBatcher` class (dead code on sync path).

### What's needed

1. Port `LodMultiMeshBatcher` to the async instantiation path (`process_async_instantiation`).
   When a MID-tier RS instance would be created, add it to the batcher instead.
2. On batcher flush (budget-gated, every few frames), call
   `RenderingServer.multimesh_set_instance_count` + `multimesh_set_instance_transform` for all
   instances of that mesh type.
3. Replace `instance_set_base(rs_id, mesh_rid)` with `instance_set_base(rs_id, multimesh_rid)`.
4. On cell unload, remove per-cell instances from batcher, rebuild affected MultiMesh.

### Risks

- **Dynamic updates:** Objects whose transforms change (animated, physics) can't be in a static
  MultiMesh. NIF objects are static — this is safe. Characters are NEAR tier — not affected.
- **Material variation:** Objects with per-instance material overrides (e.g., color tints) need
  per-instance data in the MultiMesh (`USE_CUSTOM_DATA` flag). Morrowind NIFs rarely use this —
  check with a survey before assuming it's needed.
- **Cell boundary seams:** When a cell loads/unloads, affected MultiMesh must rebuild. With
  staggered loading this happens every few frames — acceptable if rebuild is budget-gated.

---

## Recommendation

1. **First: validate steady-state FPS with Fix 1+2 applied** (time-budgeted instantiation
   from `PERF_AUDIT_SESSION_2026_04_16B.md`). May shift the bottleneck — re-profile before
   assuming MultiMesh is still needed.
2. If still GPU-bound at 54 FPS: port `LodMultiMeshBatcher` to async path. Expected to drop
   draw calls from 8,338 to ~500-700 and break the ceiling.
3. HLOD is already running — focus on missing-objects issue in parallel
   (`docs/audit/OBJECT_PAGING_SESSION_2026_04_16.md §6`).
4. MultiMesh + HLOD together: MultiMesh handles 150-300m, HLOD handles 300-1000m.
   In principle: ~500 draws (MultiMesh) + ~50 draws (HLOD chunks) + 200 (NEAR) + 1 (impostors)
   ≈ 750 draw calls total. Should comfortably achieve ≥60 FPS on RTX 4060 at this density.
