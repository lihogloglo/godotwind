# Object Paging Session — 2026-04-16

**Author:** @coder (Claude Sonnet 4.6) · **Branch:** `refactor/lod-b-wide`

First live-fire debug session after the paging system was implemented (Phases 1-6, session 2026-04-14/15). Prior sessions shipped all the pipeline code but `enabled = false`; this session turned it on, found three implementation bugs, and confirmed 32 active HLOD cells in the test scene.

Reference docs: `docs/audit/OBJECT_PAGING_PLAN.md`, `docs/audit/OBJECT_PAGING_SESSION_2026_04_14_15.md`.

---

## 1. Context — What "Working" Looked Like Before This Session

`object_paging.gd` had `enabled = false`. Enabling via `hlod_enable` console command produced:
- `hlod_cells = 0` in HUD — no chunks ever completed
- SIGSEGV crashes during merge bursts (WorkerThreadPool)
- Log line: `HLOD merge_refs: 0 triplets (cost_reject=N types, cost_accept=0, force=false)` for every chunk

All three failure modes had independent root causes. Fixed in order.

---

## 2. Bugs Found and Fixed

### Bug 1 — `generate_lods` called from background thread

**Symptom**: SIGSEGV (not sig 139 shutdown crash — this was a mid-session crash during merge bursts) with 8 concurrent WorkerThreadPool workers. Non-deterministic; sometimes 2-3 chunks completed before crash.

**Root cause**: `object_paging_kernel.gd::merge_refs` called `generate_lods()` at the end of the background-thread merge path. `generate_lods` internally calls:
```gdscript
var importer := ImporterMesh.new()   # allocates ObjectDB entry
importer.generate_lods(...)          # touches RenderingServer
importer.get_mesh()                  # RS call
```
All three touch Godot's `RenderingServer` or `ObjectDB` which are NOT thread-safe. Eight concurrent workers raced on ObjectDB allocation.

**Fix**: Removed `generate_lods` call from `merge_refs` entirely. Added it to `object_paging.gd::process_completions` (main thread), which already processes each completed mesh before RS instance creation:

```gdscript
# In process_completions(), main thread, before _create_rs_instance:
var lod_mesh := Kernel.generate_lods(mesh)
if lod_mesh:
    mesh = lod_mesh
mesh.set_meta("has_lod_chain", true)
```

**Rule**: Any call to `ImporterMesh.new()`, `importer.generate_lods()`, or `importer.get_mesh()` must run on the main thread. Worker threads may only use thread-safe C# code (`NativeObjectPagingKernel.cs`) and plain GDScript math — no Godot Resource allocation, no RS calls.

---

### Bug 2 — Cross-NIF material sharing (wrong OpenMW formula port)

**Symptom**: `cost_accept=0` for every chunk type after fixing Bug 1. Log always showed all types rejected by cost-benefit.

**Root cause**: The implementation in `_analyze_chunk` computed `shared_count` = number of OTHER mesh types in the chunk that share any of this type's materials:

```gdscript
# OLD (cross-NIF tracking):
mat_to_mesh_ids[mat_id].append(mesh_id)     # accumulate cross-type usage
# ...
var shared_count = count of other mesh types that use any of this type's materials
merge_benefit = ref_count × shared_count × PAGING_MERGE_FACTOR
```

This misread OpenMW's `avgStateSetReuse`. In OpenMW's `objectpaging.cpp`, `avgStateSetReuse` is the average number of **nodes inside one NIF** (one model file) that share the same `osg::StateSet` (roughly: same material). It is **intra-NIF** reuse — how many draw calls within a single model instance can be batched because they share a state set.

For Morrowind NIF content: each `.nif` file has its own unique materials (different texture paths, different render flags). Cross-NIF material sharing is essentially zero — different mesh types never share the same Material instance. So `shared_count` was always 0, making `merge_benefit = 0`, causing every type to fail `merge_benefit > merge_cost`.

**Fix**: Replace cross-NIF `shared_count` with `mat_count = maxi(1, group["mats"].size())` — the number of distinct materials within one mesh type (intra-NIF proxy). This approximates `avgStateSetReuse` for Godot's deduplication context:

```gdscript
# NEW (intra-NIF proxy):
var mat_count: int = maxi(1, group["mats"].size())
var merge_benefit_raw: float = float(group["ref_count"]) * float(mat_count)
var merge_benefit: float = merge_benefit_raw * DU.PAGING_MERGE_FACTOR
var merge: bool = merge_benefit > merge_cost
```

Also removed the now-unused `mat_to_mesh_ids: Dictionary` from `_analyze_chunk`.

**Canonical reference**: OpenMW `objectpaging.cpp` §"StateSet analysis" — `avgStateSetReuse` = average reuse count per StateSet within the SAME NIF instance, not across NIF types. The confusion arose because the prior implementation author interpreted "shared material" as cross-instance sharing (which IS meaningful for draw-call batching), but OpenMW's formula uses it as an intra-instance signal for merge worthiness.

---

### Bug 3 — Total-verts vs per-instance-verts in cost formula

**Symptom**: `cost_accept=0` persisted even after Bug 2 fix. Log showed types being analyzed but still all rejected.

**Root cause**: `group["verts"]` in `_analyze_chunk` accumulated verts from EVERY ref occurrence of the type:

```gdscript
# OLD (total verts across all refs):
group["verts"] += verts.size()   # called for every ref — result is ref_count × per_instance_verts
```

This meant `mergeCost = (ref_count × verts_per_instance) × (size_level + 1)`. The formula simplifies to:
```
merge_benefit (ref_count × mat_count × 256) > merge_cost (ref_count × verts × (size_level+1))
# ref_count cancels:
merge iff mat_count × 256 > verts × (size_level+1)
```

For any model with more than ~256 verts (all Morrowind architecture, most vegetation), this always fails. A house with 2000 verts at size_level=0 needs `mat_count × 256 > 2000` → `mat_count > 7.8` — impossible for typical single-material models.

OpenMW's `mergeCost` formula uses **per-instance vertex count** (the size of one NIF instance's geometry), NOT the total across all instances in the chunk.

**Fix**: Only accumulate verts from the FIRST ref occurrence (same prototype, same per-instance count):

```gdscript
# NEW (per-instance verts — only first occurrence):
if group["ref_count"] == 1 and verts is PackedVector3Array and not verts.is_empty():
    group["verts_per_instance"] += verts.size()
```

Changed key from `"verts"` to `"verts_per_instance"` in the group dict for clarity.

---

## 3. Pre-existing Startup SIGSEGV (separate from merge crash)

**Not fixed this session.** Pre-dated this work — already present in session 2026-04-15.

**Signature**: `model_loader._safe_instantiate` → `packed_scene.instantiate()` crashes with no GDScript backtrace (native C++ stack only, no debug symbols). Fires during heavy startup burst (~400+ objects queued simultaneously). Probabilistic — some runs survive startup, some crash immediately.

**Compounding factor**: interact agent had changed `instantiation_budget_ms` from `15.0ms` to `8.0ms` during startup phase in `native_streaming_manager.gd`, doubling burst size. Reverted to 15ms:

```gdscript
# Reverted in native_streaming_manager.gd:
var instantiation_budget_ms := 15.0 if _startup_phase else _get_dynamic_budget(delta)
```

**Status**: User assigned separate agent. Not @coder's scope. Test scene survived startup ~2/5 runs with revert applied.

---

## 4. Diagnostic Logging Added

Added cost-benefit diagnostic to `_analyze_chunk` / `merge_refs` in `object_paging_kernel.gd`. Kept in for future sessions:

```gdscript
var accepted_types: int = 0
var rejected_types: int = 0
for mesh_id: int in keep_mask:
    var entry: Variant = keep_mask[mesh_id]
    if (entry is bool and entry) or (entry is Dictionary and entry.get("merge", false)):
        accepted_types += 1
    else:
        rejected_types += 1

if triplets.is_empty():
    Log.info("streaming", "HLOD merge_refs: 0 triplets (cost_reject=%d types, cost_accept=%d, force=%s)" % [
        rejected_types, accepted_types, force_merge_all])
    return null
```

Enables per-chunk diagnosis: how many types were accepted vs rejected by cost-benefit, before and after each bug fix.

---

## 5. Confirmed Working

After all three fixes: `hlod_cells = ~32` observed in HUD. HLOD geometry visible in test scene at 300-1000m range. User confirmed (chat msg 1432, 2026-04-16).

---

## 6. Known Remaining Issues

### Missing objects in merged cells

Many objects that should appear in the 300-1000m merged geometry are absent. Possible causes (not yet diagnosed):

1. **`PAGING_MIN_SIZE` threshold too tight** — currently `0.14` (OpenMW canonical MW-unit value). Godotwind works in meters (1 MW unit ≈ 1/70 m), so the projected-size formula may be too strict for the meter-scale distances. See `distance_utils.gd` comment on this constant — lowering to `0.02` was already done for the size-worthiness filter, but `PAGING_MIN_SIZE` fed into the Phase 5 `minSizeMergeFactor` second-pass filter may still over-reject.

2. **Type filter too narrow** — `_type_eligible` may reject types that should contribute to distant merged geometry.

3. **Cost-benefit still rejecting valid types** — even with Bug 2+3 fixed, the intra-NIF `mat_count` proxy may underestimate benefit for types with low material diversity (single-material, single-surface NIFs). Potentially need to lower or bypass `PAGING_MERGE_FACTOR` for evaluation.

4. **RS instance visibility_range** — per-tier visibility ranges set in `_create_rs_instance` may clip objects that the camera can see but the bandwidth classifier deems outside the tier.

### FPS

Acknowledged but separate concern. Not investigated this session.

---

## 7. Files Modified This Session

```
src/core/world/object_paging_kernel.gd   — Bug 1 (remove BG generate_lods), Bug 2 (cross→intra NIF metric), Bug 3 (total→per-instance verts), diagnostic log
src/core/world/object_paging.gd          — Bug 1 (add generate_lods to process_completions, main thread)
src/core/world/native_streaming_manager.gd — startup budget revert (15ms)
```

---

## 8. Thread Safety Rules (Consolidated)

Canonicalized from the Bug 1 investigation. Must be respected by all future merge pipeline work:

| Location | Thread | Allowed |
|----------|--------|---------|
| `merge_refs` body | WorkerThreadPool BG | GDScript math, plain Array/Dict ops, `NativeObjectPagingKernel.cs` calls |
| `merge_refs` body | WorkerThreadPool BG | **NOT**: `ImporterMesh.new()`, `Resource.new()`, any `RenderingServer.*` call, `generate_lods()` |
| `process_completions` | Main thread | All Godot APIs including RenderingServer, `generate_lods()`, `ArrayMesh.set_meta()` |
| `_create_rs_instance` | Main thread | All RenderingServer instance creation |

`NativeObjectPagingKernel.cs` is marked `[GlobalClass] RefCounted`, stateless, worker-thread safe — vertex transform math only, no Godot Resource allocation.

---

## 9. Future Agent Quickstart

1. Read `docs/audit/OBJECT_PAGING_PLAN.md` (design) + `docs/audit/OBJECT_PAGING_SESSION_2026_04_14_15.md` (implementation history) + this file (debug history).
2. `hlod_enable` in console to activate. Watch `hlod_cells` / `hlod_pending` in HUD.
3. Next session focus: missing objects. Start by logging per-type rejection reasons in `_analyze_chunk` at `Log.debug` level — which types fail cost-benefit, which fail type_eligible, which fail size filter.
4. Check `PAGING_MIN_SIZE = 0.14` — try `0.02` (already used for size-worthiness) for the second-pass filter threshold too.
5. Startup crash: separate agent working it. Workaround: rerun test scene until it survives startup (2/5 success rate as of this session).

*End of session log. 2026-04-16.*
