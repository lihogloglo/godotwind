# Object Paging (runtime HLOD)

OpenMW-style distance-adaptive chunk paging. One RS instance per merged chunk across the MID+HLOD band (150-1000m). Replaces the old cell-scoped `runtime_hlod_merger.gd` and the keyword-substring `is_mid_worthy` gate.

**Status:** Phases 1-6 shipped. 61 unit tests (`tests/unit/test_object_paging_kernel.gd`). Enabled by default on 2026-04-17 (`object_paging.gd:101 → enabled: bool = true`). Runtime toggle via console: `hlod_enable` / `hlod_disable` / `hlod_stats` (`world_explorer.gd:1877-1892`).

**Canonical pattern:** OpenMW `ObjectPaging` (`inspos/openmw/apps/openmw/mwrender/objectpaging.cpp`). Design + OpenMW mapping folded into this doc.

## Files

```
src/core/world/object_paging.gd         — orchestrator, chunk LRU, desired-chunk walk, completion queue
src/core/world/object_paging_kernel.gd  — GDScript merge kernel wrapper + C# delegate
src/native/NativeObjectPagingKernel.cs  — hot merge kernel (PackedArray concat, material-hash dedup, cost-benefit)
src/core/world/distance_utils.gd        — all PAGING_* constants + chunk key/center/band helpers (single source of truth)
src/core/world/object_position_index.gd — prebuilt spatial index; `get_refs_in_chunk(center, size)` query
tests/unit/test_object_paging_kernel.gd — kernel unit coverage
tests/visual/test_hlod_benchmark.gd     — interactive flyby benchmark (CSV export)
```

## Chunk geometry

| size_level | Tier     | Band            | Chunk cells | World extent |
|------------|----------|-----------------|-------------|--------------|
| 0          | MID-near | [150, 300)m     | 1×1         | 117m         |
| 1          | MID-far  | [300, 600)m     | 2×2         | 234m         |
| 2          | HLOD     | [600, 1000)m    | 4×4         | 468m         |
| —          | FAR      | [1000, 5000)m   | impostors   | —            |

`ChunkKey = Vector3i(center_cell.x, center_cell.y, size_level)`. Alignment uses two's-complement bitwise mask: `cell & ~(size - 1)` (handles negative cells — naive `(cell / size) * size` truncates toward zero and mis-aligns the negative quadrant). See `DistanceUtils.chunk_key_for_cell`.

Band classification uses chunk-**center** distance, not nearest-edge. Top-down anti-overlap walk (size_level 2 → 1 → 0) marks covered 1×1 sub-cells so a smaller chunk never subdivides an already-accepted larger chunk. See `object_paging.gd::_compute_desired_chunks` + `_any_sub_cell_covered` + `_mark_sub_cells`.

## Filter pipeline

Per candidate ref, in order (all in `NativeObjectPagingKernel` except type filter, which is pre-applied GDScript-side):

1. **Type filter** — REC_STAT / REC_DOOR / REC_ACTI always eligible; REC_CONT / REC_FURN etc. only at `size_level == 0`. `object_paging.gd::_type_eligible`.
2. **Projected-size filter** — `radius² × scale² >= dist² × PAGING_MIN_SIZE²`. Failed refs memoized in a `SizeCache` so subsequent chunks don't re-test them. OpenMW default is `0.14` (MW-unit scale); Godotwind works in meters and ships `0.02` — `0.14` rejects every MW building and tree at 200m. Tuned in `distance_utils.gd::PAGING_MIN_SIZE` with the derivation in-comment. Source: `inspos/openmw/components/settings/categories/terrain.hpp:34`.
3. **Cost-benefit merge decision** (per mesh type, per chunk) — `mergeBenefit × PAGING_MERGE_FACTOR > mergeCost` where `mergeBenefit = ref_count × shared_material_count` and `mergeCost = num_verts × (size_level + 1)`. OpenMW canonical default 256.0. Source: `inspos/openmw/components/settings/categories/terrain.hpp:32`. Unmerged types fall through as individual `StaticObjectRenderer` RS instances.
4. **`minSizeMergeFactor` second-pass** — merged-eligible refs face a second size filter that scales with how merge-beneficial the type turned out to be. Formula (`inspos/openmw/components/settings/categories/terrain.hpp:35-39`):
   ```
   factor2             = clamp(mergeCost × PAGING_MIN_SIZE_COST_MULTIPLIER / mergeBenefit, 0, 1)
   minSizeMergeFactor2 = (1 − factor2) × PAGING_MIN_SIZE_MERGE_FACTOR + factor2
   minSizeMerged       = PAGING_MIN_SIZE × minSizeMergeFactor2
   ```
   Types with high mergeBenefit use a looser effective min-size (more refs merged); marginal types tighten the filter.

## Hysteresis

20m retention band (`PAGING_HYSTERESIS` in `distance_utils.gd`). Matches the NEAR↔MID promotion/demotion asymmetry in `streaming_config.gd` (250m / 280m). Active chunks keep their tier assignment until the camera crosses the demote threshold — prevents LRU thrash when walking along a tier boundary. Applied in `_is_within_retention` / `_is_within_retention_for`.

## Teleport warmup

Camera jumps > `TELEPORT_THRESHOLD` trigger a prototype warmup pass: unregistered mesh types in the new chunk ring are pre-staged over 2-3 frames instead of landing inside the first `_request_chunk_merge`. Prevents the cold-chunk `_load_prototype_from_cache` spike that would otherwise dominate the frame after a teleport. `object_paging.gd::_prime_warmup_queue` + `_drain_warmup_queue`. Stats tracked in `_stats["total_teleports"]`.

## Thread safety (load-bearing)

| Operation                                    | Thread                      |
|----------------------------------------------|-----------------------------|
| `ObjectPositionIndex` reads                  | any (immutable after build) |
| `ArrayMesh.surface_get_arrays` (prototype)   | any (immutable)             |
| `NativeObjectPagingKernel` C# kernel         | worker                      |
| GDScript filter math, bounds, array packing  | worker                      |
| `SizeCache` writes                           | worker, mutex-guarded       |
| `ImporterMesh.new()`                         | **main only**               |
| `ImporterMesh.generate_lods()`               | **main only**               |
| `RenderingServer.*` (instance/scenario/free) | **main only**               |

`ImporterMesh` touches `RenderingServer` internally, so post-merge LOD generation happens in `process_completions` on the main thread after the worker returns the concatenated surface arrays. Verified with editor-only `ImporterMesh` semantics in mind (see plan §14 risk 2 — exported-build gate was Phase 6).

## Console surface

| Command       | Effect                                                    |
|---------------|-----------------------------------------------------------|
| `hlod_enable` | `paging.enabled = true` — full MID+HLOD pipeline          |
| `hlod_disable`| `paging.enabled = false` — debug/baseline (NEAR only past 150m) |
| `hlod_stats`  | Prints live chunk count, cache bytes, merges/s, teleport count |

Defined in `world_explorer.gd::_cmd_hlod_enable` / `_cmd_hlod_disable` / `_cmd_hlod_stats`.

## Known cold-start caveat

First cell re-request for an unregistered mesh type bypasses the projected-size filter (AABB not yet in `StaticObjectRenderer`) and falls through to the slow-path prototype load. Front-loads during initial exterior streaming (~30-50 unique architectural types) and settles out. Not a regression — Phase 1 had no filter at all. Fix option: pre-register AABBs during ESM parse. Not scheduled.

## History

- `docs/archive/sessions/object_paging_2026_04_14_15.md` — Phases 1-3 session log (kernel extraction, projected-size filter, cost-benefit).
- `docs/archive/sessions/object_paging_2026_04_16.md` — Phase 4-6 session log (adaptive quadtree, warmup, default-on flip).
