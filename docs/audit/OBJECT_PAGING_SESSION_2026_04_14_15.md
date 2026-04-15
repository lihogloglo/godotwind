# Object Paging Session — 2026-04-14 / 2026-04-15

**Author:** @coder (Claude Opus 4.6) · **Reviewer:** @roaster · **Branch:** `refactor/lod-b-wide`

Two-day session implementing OpenMW-style distance-adaptive object paging. Reference: `docs/audit/OBJECT_PAGING_PLAN.md` (the full design doc; this file is the execution log).

---

## 1. Context — Why This Work

`bench_progressive` (`src/tools/progressive_benchmark.gd`) flagged MID-tier objects as the single largest marginal rendering cost in the additive subsystem sweep. Each MID static was rendering as an individual RS instance in the 150-500m band at thousands of draw calls. Previous attempts at fixing this:

1. **Prebaked HLOD chunks on disk** — rejected, massive disk footprint.
2. **`runtime_hlod_merger.gd` (pre-Phase-1 state, 839 lines)** — runtime cell-level merger in the HLOD 300-1000m band. Disabled by default (`enabled = false`). Used a keyword-substring filter (`is_mid_worthy`) to decide which refs merge. Never validated on real workloads — `hlod` deliberately omitted from `PROGRESSIVE_ORDER`.

User directive (chat msg 1012): adopt OpenMW's `ObjectPaging` pattern (`inspos/openmw/apps/openmw/mwrender/objectpaging.cpp`), use a quadtree, filter to big statics. Session plan reviewed + signed off by @roaster.

---

## 2. Plan Doc — `OBJECT_PAGING_PLAN.md`

Written first, reviewed + iterated before any code landed:
- **6 canonical OpenMW pieces** adopted (§2.1-2.6): distance-adaptive chunks, projected-size filter, per-mesh-type cost-benefit, type pre-filter, minSizeMergeFactor re-filter, merge primitive.
- **Mapping table** OpenMW → Godotwind (§3): chunk IDs, merge kernel, filters.
- **Chunk geometry** (§4) revised after Phase-3 close with detailed §4.1-4.5 sub-sections covering alignment math, band classification, anti-overlap walk, hysteresis, and ring-walk bounds.
- **Cold-start cost** (§16b) documenting unregistered-AABB refs bypassing the size filter on first cell activation.
- **Cell-distance slider hook** (§14b) user-requested future feature — plan discipline keeps constants override-able from a single scale multiplier.
- **Known risks** (§14) with the load-bearing one being `ImporterMesh.generate_lods()` on exported builds; Phase 6 has an explicit gate.

Plan reviewer trail: @roaster plan-review msg 1020 (initial), msg 1050 (Phase 1), msg 1060 (Phase 2), msg 1068 (Phase 3), msg 1079 (Phase 4 pre-pass close).

---

## 3. Commits (this session, in order)

```
d107bd8 refactor(paging): Phase 4b — ChunkKey refactor + top-down tier walk
2432a70 refactor(paging): Phase 4a — chunk-key math helpers + tier constants
17b1406 docs(paging): Phase 4 plan revision — §4.1-4.5 pre-pass
1a66b62 chore(paging): Phase 3 post-review cleanup
2c70da7 refactor(paging): Phase 3b — cost-benefit merge decision
91485e2 refactor(paging): Phase 3a — record-type filter table
f3c94c7 refactor(paging): Phase 2 — projected-size filter + SizeCache
0b2e3cb refactor(paging): Phase 1 — extract merge kernel to C#, add plan doc
```

All committed LOCAL, not pushed. User has not requested push.

Flycam's concurrent Commit A (`6314b44 fix(streaming): route cell instantiation through reference_instantiator`) sits upstream of mine — same branch, different domain. Our work coordinated via #flycaminteract + #debugandoptimization channels.

---

## 4. Phase-by-Phase Summary

### Phase 1 — Kernel extraction (`0b2e3cb`)

**What**: moved the merge math out of the monolithic `runtime_hlod_merger.gd` into a shared kernel. C#/GDScript split per `.claude/CLAUDE.md` Language Policy (hot compute in C#, orchestration in GDScript).

**Files**:
- NEW `src/native/NativeObjectPagingKernel.cs` — 340 lines. Hot vertex-transform loops, material-hash grouping, PackedArray concat, byte estimate. `[GlobalClass] RefCounted`, stateless, worker-thread safe. Exposed via `NativeFactory.CreateObjectPagingKernel()`.
- NEW `src/core/world/object_paging_kernel.gd` — 160 lines. GDScript orchestrator. Pre-flattens `RefInput × SubMeshInput × surface → (arrays, xform, material)` triplets so C# skips Variant unpacking. Owns `ImporterMesh.generate_lods()` on merged ArrayMesh. Native lookup via `NativeBridge._factory.call()` pattern (matches `NativeHorizonMapBaker`/`NativeShoreMaskBaker`).
- MOD `src/native/NativeFactory.cs` — one factory method added.
- MOD `src/core/world/runtime_hlod_merger.gd` — 839 → 545 lines. Dead merge math deleted; callers route through `Kernel.merge_refs` / `Kernel.estimate_mesh_bytes`.
- NEW `tests/unit/test_object_paging_kernel.gd` — 9 parity tests with structural assertions (not whole-mesh hashing — fragile under LOD).

**Build required**: `dotnet build Godotwind.sln` — 0 errors.

**Rollback anchor**: this commit is where the refactor could be reverted to a clean pre-paging state.

### Phase 2 — Projected-size filter + SizeCache (`f3c94c7`)

**What**: replaced the keyword-substring `StreamingPolicy.is_mid_worthy` gate with OpenMW's geometry-based projected-size test. `keep iff mesh_radius² × scale² >= dist² × min_size²`. `PAGING_MIN_SIZE = 0.14` (OpenMW canonical, `inspos/openmw/components/settings/categories/terrain.hpp:34`).

**SizeCache short-circuit** (required by roaster review msg 1060 must-fix #1): cache stores `radius² × scale²` keyed by `ref_num`. Cache hit + still-rejected at current dist → continue with ZERO I/O (no AABB dict lookup, no prototype load). Cache hit + now-kept → evict entry, fall through to full path. Mesh-invariant cached value; only dist changes per frame.

**Files**:
- MOD `src/core/world/distance_utils.gd` — `PAGING_MIN_SIZE` + `PAGING_MIN_SIZE_SQ` constants.
- MOD `src/core/world/static_object_renderer.gd` — `get_mesh_aabb(type_name) -> AABB` accessor.
- MOD `src/core/world/runtime_hlod_merger.gd` — SizeCache + mutex + `_is_size_worthy` static helper.
- MOD `src/core/world/native_streaming_manager.gd` — pass real `_camera_position` to `update_for_camera`.
- MOD `tests/unit/test_object_paging_kernel.gd` — +8 projected-size tests.

**Docstring divergence note**: `_is_size_worthy` returns `true` for `mesh_radius_sq == 0` (conservative keep) instead of OpenMW's implicit skip — caller guards the case.

### Phase 3a + 3b — Type filter + cost-benefit (`91485e2`, `2c70da7`)

**What**: reintroduced type-based candidate pre-rejection (Phase 2 had stripped it with the keyword gate) via a proper lookup table. Added cost-benefit merge decision per mesh-type.

**Type filter contract** (`_type_eligible(type_name, size_level)`):
- `static`, `door`, `activator` → always eligible
- `container` → only at `size_level == 0` (1×1 chunks)
- `light`, `npc`, `creature`, `weapon`, `armor`, `book`, … → never eligible
- TES4 records intentionally omitted — Godotwind is TES3-only.

**Cost-benefit formula** (`object_paging_kernel.gd::_analyze_chunk`):
```
mergeBenefit_type = ref_count_in_chunk × shared_material_count
mergeCost        = total_verts × (size_level + 1)
merge            = mergeBenefit × PAGING_MERGE_FACTOR > mergeCost
```
where `shared_material_count` is the number of this type's materials ALSO used by ≥2 distinct mesh-types in the chunk. `PAGING_MERGE_FACTOR = 256.0` (OpenMW canonical, `terrain.hpp:32`).

**`force_merge_all` escape**: `merge_refs(inputs, origin, size_level=0, force_merge_all=false)`. Phase 1 parity tests pass `(0, true)` because their synthetic single-type/single-material fixtures legitimately fail cost-benefit. Real callers use the default.

**Post-review cleanup** (`1a66b62`): extracted `_resolve_material(sm, surface_index)` helper used by both `_analyze_chunk` and `_flatten_to_triplets` (roaster nit #1). Added TES4-omission docstring note on `_type_eligible` (roaster nit #3). Vert-count caching between analyze + flatten deferred to Phase 4 review (roaster nit #2).

### Phase 4a — Math helpers (`2432a70`)

**What**: static helpers + constants consumed by Phase 4b. No behavior change.

**Added to `distance_utils.gd`**:
- Constants: `PAGING_TIER_0_START/END` (150/300), `PAGING_TIER_1_END` (600), `PAGING_TIER_2_END` (1000), `PAGING_HYSTERESIS` (20.0), `PAGING_MERGE_FACTOR` (already there from 3b).
- `chunk_key_for_cell(cell, size_level) -> Vector2i` — bitwise two's-complement alignment `cell.x & ~(size - 1)` for correct floor-toward-negative-infinity behavior. The naïve-truncation bug (`-5 // 4 = -1 → -4 instead of -8`) was the primary motivation.
- `chunk_center_world(center_cell, size_level) -> Vector2` — Z-flipped to match Godot world space (MW +Y → Godot -Z).
- `paging_band_start`, `paging_band_end`, `paging_ring_radius` — tier constants exposed as pure functions.

**Tests**: +9 cases including explicit negative-cell boundary (`-5 & ~3 = -8`, `-8 & ~3 = -8`).

### Phase 4b — ChunkKey refactor + top-down walk (`d107bd8`)

**What**: the centerpiece. Merger evolves from single-tier (Vector2i cell keys) to three-tier adaptive pager (Vector3i ChunkKey = `(center.x, center.y, size_level)`).

**Architectural changes**:
- `HLODCellData` → `HLODChunkData` with `key: Vector3i` field.
- All state re-keyed Vector2i → Vector3i: `_active_chunks`, `_pending_merges`, `_task_to_key`, `_merge_queue`, `_mesh_cache`, `_mesh_sizes`, `_lru_order`.
- `_compute_desired_chunks(camera_cell, camera_pos)` — plan §4.3 top-down walk. Iterates size_levels `[2, 1, 0]`; `covered_cells` dict enforces no 1×1 MW cell claimed by more than one chunk.
- `_request_chunk_merge(key, …)` replaces `_request_merge(grid, …)`. Iterates `size × size` covered cells for the chunk.
- `_merge_chunk_worker(key, …)` threads `key.z` as `size_level` to `Kernel.merge_refs(...)` — cost-benefit is now tier-aware.
- `_chunk_origin_world(key)` places RS instance at chunk CENTER (matches OpenMW + plan §4.2 band classification).
- `_create_rs_instance` tier-specific `visibility_range`: `[150, 300]` / `[300, 600]` / `[600, 1000]`, 20m fade both sides.

**Telemetry**: `chunks_tier_0/1/2` per-tier active counts added to stats. `active_cells` retained as total-across-tiers for caller compat.

**Public API unchanged**: all six public methods (`update_for_camera`, `process_merge_queue`, `process_completions`, `get_stats`, `set_all_visible`, `cleanup`) keep pre-Phase-4 signatures. Zero touches to `NativeStreamingManager` or `world_explorer.gd`.

**Tests**: +4 walker-invariant cases — no 1×1 cell double-coverage, every chunk center in its tier's strict band, all three tiers populated from origin camera, large-chunk-blocks-smaller overlap.

---

## 5. Test Suite Growth

```
Pre-session:   43 tests (gdUnit4 suite in tests/unit/)
Post-Phase 1:  52 tests (+9 kernel parity)
Post-Phase 2:  60 tests (+8 projected-size)
Post-Phase 3a: 66 tests (+6 type filter)
Post-Phase 3b: 73 tests (+7 cost-benefit)
Post-Phase 4a: 82 tests (+9 chunk-key math)
Post-Phase 4b: 86 tests (+4 walker invariants)
```

All pass. `run_tests.tscn` runtime: ~20s on the full suite. No flakes observed across the session.

---

## 6. Still Blocked On

### sig 139 (NOT my scope — roaster + @flycam)

Background: `bench_progressive` is a 14-minute scripted flyby that cannot survive sig 139 streaming-burst crashes. Phase validation from bench is stuck behind the fix.

**Timeline**:
- Before session: sig 139 only fired on intentional ALT+F4 quit (benign per user msg 1055).
- Flycam's Commit A (`6314b44`, Belt B → Belt A canonical cell instantiation rewrite) exposed a race that wasn't visible before.
- Roaster bridge fix was in progress (local, not yet pushed as of last session notification) — `MODEL_LOADER_RACE.md` + `model_loader.gd` touches.
- Post-bridge: 33× more cells streamed before crash (30 → 1002 `instantiate_attempt` log lines). Crash signature changed — original `model_loader.gd:438 packed_scene.instantiate()` stack gone; new native-side crash with no GDScript backtrace.
- Diagnosis (roaster msg 1078): `convert_static_to_rigid` in `carryable_body_factory.gd` reparents `CollisionShape3D` without clearing owner — was silently skipped on Belt B. Owner-inconsistent reparenting is a Godot smell that can corrupt state.
- **Fix owner**: @roaster currently working this — NOT @coder.

**Impact on paging phases**: parity rests on the 86 unit tests. When sig 139 resolves and bench can run, we regenerate the `docs/audit/lod_refactor_baselines/` CSV and measure `mid_objects` delta. Pure-refactor phases (1-3) should show ≈0ms delta; adaptive-chunk phases (4b+) should show ≥1ms/frame win per plan §13 acceptance criterion.

---

## 7. Phases Remaining

### Phase 4c — Hysteresis (plan §4.4)

Strict band transitions (current 4b) cause mild thrash near tier boundaries. Per plan §4.4, active chunks retain their previous tier assignment until camera moves 20m past the demote threshold. Implementation sketch: per-`HLODChunkData` `demote_threshold: float`; during `_compute_desired_chunks`, active chunks whose dist is within `[band_start - 20, band_end + 20]` stay at their current tier even if the strict band would re-tier them.

Scope: ~40 LOC on `runtime_hlod_merger.gd`. Plan closed by roaster msg 1079, impl-draft still needed.

### Phase 4d — Prototype warmup on teleport

Per plan §11 Phase 3 (moved to Phase 4 by roaster msg 1068 after §9 hand-off clarification): on first `update_for_camera` after a camera teleport (`> 500m jump`), pre-stage prototype `.res` loads for the incoming chunk ring over 2-3 frames. Prevents teleport-spike frame-time regression.

Scope: ~50 LOC. Teleport detection in `update_for_camera`, warmup queue drained by `process_merge_queue`.

### Phase 5 — Second-pass `minSizeMergeFactor` (plan §2.5)

Tightens cost-benefit by re-filtering merged refs against `mesh_radius² × scale² < dist² × minSizeMergeFactor²` where `minSizeMergeFactor` scales with merge-benefit. Polish only — ships with 4d if bench is already green.

### Phase 6 — Rename + deprecation sweep

- `runtime_hlod_merger.gd` → `object_paging.gd` (rename, update imports).
- Delete residual `is_mid_worthy` call sites: `cell_manager.gd:1952-1953, :2124`, `mid_tier_debugger.gd:319`. Phase 2 only removed the merger-internal usage.
- Update `docs/STATUS.md`, `docs/DISTANCE_RENDERING.md`, `docs/audit/MASTERPLAN.md` with final architecture.
- **Exported-build smoke test**: verify `ImporterMesh.generate_lods()` works on worker thread in release build (plan §14 risk 2). If editor-only, re-plan Phase 2: either use prebake-time LOD chains (bypass runtime gen) or move LOD gen to main thread only in release.
- Regenerate `docs/audit/lod_refactor_baselines/` CSV post-fix.

---

## 8. File Layout (post-Phase 4b)

```
src/core/world/
    runtime_hlod_merger.gd          — 550 LOC, main paging orchestrator
    object_paging_kernel.gd         — 280 LOC, merge kernel facade (GDScript)
    distance_utils.gd               — tier constants + ChunkKey helpers
    static_object_renderer.gd       — get_mesh_aabb accessor added
    native_streaming_manager.gd     — passes camera_world_pos to merger
    streaming_policy.gd             — is_mid_worthy untouched (still used by prebaking)

src/native/
    NativeObjectPagingKernel.cs     — 340 LOC, hot merge math (C#)
    NativeFactory.cs                — CreateObjectPagingKernel factory method

tests/unit/
    test_object_paging_kernel.gd    — 86 tests total, full surface coverage

docs/audit/
    OBJECT_PAGING_PLAN.md                     — primary design doc
    OBJECT_PAGING_SESSION_2026_04_14_15.md    — this file
```

---

## 9. Reviewer Trail (chat IDs, #debugandoptimization)

| msg | from     | content |
|-----|----------|---------|
| 1012 | user     | initial directive — OpenMW ObjectPaging port, quadtree, big-statics filter |
| 1020 | roaster  | plan review — 6 must-fixes + 3 nice-to-haves, answers to my 3 questions |
| 1028 | roaster  | Belt A/B canonical fix signoff (flycam channel, but referenced here) |
| 1041 | roaster  | impl-draft review Phase 1 — 2 blockers + 3 issues |
| 1050 | roaster  | Phase 1 signoff after must-fixes + parity test |
| 1060 | roaster  | Phase 2 review — 1 must-fix (SizeCache no-op) + 3 nits |
| 1064 | roaster  | Phase 2 signoff after option A short-circuit |
| 1068 | roaster  | Phase 3a + 3b signoff + 3 nits, Phase 3c moved to Phase 4 |
| 1075 | roaster  | Phase 4 plan-review pre-pass — 5 items to land in §4 |
| 1079 | roaster  | Phase 4 plan-review closed |

---

## 10. Rules-of-Engagement Notes

- All work on branch `refactor/lod-b-wide`, committed local, not pushed. User controls push.
- Flycam concurrent work on `cell_manager.gd` coordinated via #flycaminteract — bundling was a single-tree artifact, not a scope dispute. Commit A (flycam) shipped first, Commit B (paging Phase 1) stacked cleanly.
- Caveman-full communication mode per `~/.claude/skills/caveman/SKILL.md` (user lock 2026-04-07).
- Reviewer engagement scope per `.claude/CLAUDE.md` — plan review + impl-draft review, not continuous. Followed for all phases.
- Sig 139 triage deliberately NOT touched by me — user msg 1055 assigned to @roaster.
- Never launched main game unprompted (memory: `feedback_never_launch_main_game_unprompted.md`). Did launch for user's bench attempt msg 1052; died before user could interact (msg 1054).

---

## 11. Future-Agent Quickstart

1. Read this doc + `docs/audit/OBJECT_PAGING_PLAN.md` (primary design doc).
2. `git log --oneline --all | head -20` — see commit stack.
3. `run_tests.tscn` — 86 tests cover the paging surface. Run before/after any change.
4. `bench_progressive` (console in-game) — blocked on sig 139 as of this session. When clear, regenerate CSV in `docs/audit/lod_refactor_baselines/`.
5. Phase 4c (hysteresis) is the next logical unit of work. Scope contained, ~40 LOC.
6. If `ImporterMesh.generate_lods()` turns out to be editor-only in exported builds, Phase 2 re-plan per plan §14 risk 2 / §11 Phase 6 gate.

---

## 12. Known Cold-Start Costs

Documented in plan §16b:
- First-cell unregistered AABBs bypass the projected-size filter (returns `true` on radius=0) and fall through to slow-path prototype load. Front-loads during initial exterior streaming (~30-50 unique architectural mesh types). Settles after registry is populated.
- Not a regression vs Phase 1; Phase 1 had no filter at all.
- Fix option if profiling flags it: pre-register AABBs during ESM parse by reading NIF header bounding boxes into `StaticObjectRenderer` before the first cell stream. Not scheduled.

---

## 13. Tunables (if benchmarks warrant adjustment)

All in `src/core/world/distance_utils.gd`:
- `PAGING_MIN_SIZE = 0.14` — higher = more aggressive clutter rejection. OpenMW canonical.
- `PAGING_MERGE_FACTOR = 256.0` — higher = merge more aggressively. OpenMW canonical.
- `PAGING_TIER_0/1/2_END` — band boundaries, currently 300/600/1000. User requested 150-1km merged band; impostor start needs to move from 500→1000 in Phase 6 (currently `FAR_START = MID_END = 500`).
- `PAGING_HYSTERESIS = 20.0` — only consumed when Phase 4c ships.

Per plan §14b, all distances read from constants — never hardcoded inline. A future `cell_distance` user slider would be a single `quality_scale ∈ [0.25, 1.0]` multiplier.

---

*End of session log. Continue at Phase 4c or wait for bench validation post-sig-139.*
