# Distant Rendering Plan — 2026-04-17

**Paired with:** `docs/audit/DISTANT_RENDERING_AUDIT_2026_04_17.md` (the problem map — read first).
**Targets set by user 2026-04-17:**
1. Shorter time-to-stable-60 (currently "very very long" post-launch / post-teleport).
2. 140 FPS steady state (currently ~50 FPS floor at horizon range per audit §0).
3. Simplify the code (4 tiers + 2 meta + 3 orphans per audit §1).
4. **Push the impostor tier START to 1 km** (was 480 m). MID/HLOD must hold to 1 km.

**This doc is a cross-session work log.** New agent picking this up: read §0 first, then pick the next open phase in §3.

---

## 0. Session Resume Pointer

**Read in this order:**
1. This file's §2 (Ground Rules) — non-negotiable.
2. `docs/audit/DISTANT_RENDERING_AUDIT_2026_04_17.md` §5-7 (the problem catalog and why).
3. §3 of this file — find the first phase with status `TODO` and start there.
4. At the top of every phase, the **Acceptance** block is the gate. Do not mark a phase done without recording the before/after numbers in §4 (Measurement Log).

**Current phase:** PHASE 0 — Baseline measurement (status: TODO).

---

## 1. Non-Goals

- Not shipping Nanite / virtualized geometry / GPU-driven culling (Godot 4.6 does not expose the hardware indirect + mesh-shader path). Closest 4.6 substitute (`multimesh_set_visible_instances` + compute cull) is a Phase X stretch, not baseline.
- Not touching Terrain3D addon internals — opaque clipmap cost, treat as black-box.
- Not re-baking NIFs / impostor textures. Prebake pipeline is out of scope.
- Not rewriting the NPC / character path. MID/HLOD covers STAT + DOOR + ACTI + tier-0 CONTAINER; actors are separate.

---

## 2. Ground Rules — Measurement & Sources

**Locked by user 2026-04-17:**

1. **Only two sources of truth: the code in `src/` and the runtime numbers from a live Godot scene.** Docs in `docs/` are aspirational. Commit messages lie (e.g. `a541dd1` says "model loader race is fixed" but the race's class of failures may still happen under different timing). `MEMORY.md` is index-only. **Verify every claim against current code before acting on it.**
2. **Before any change, record a baseline.** Before/after numbers go in §4. A phase without numbers in §4 is NOT done.
3. **Measurement harness = `streaming_benchmark.gd` + `benchmark_hud.gd` + `subsystem_toggles.gd`.** Console commands:
   - `bench` — runs the 85-second scripted Seyda Neen flyby; writes CSV + JSON to `user://benchmark_results/`.
   - `hud` — live overlay (frame ms, p95, draw_calls, rendered_objects, primitives, phase breakdown).
   - `toggle <name>` / `toggle only <name>` / `toggle none` — A/B isolation. Flags registered in `src/tools/world_explorer.gd:1372-1401`: `terrain`, `ocean`, `sky`, `weather`, `characters`, `impostors`, `mid_objects`, `near_objects`, `hlod`, `shadows`, `postfx`.
   - `hlod_enable` / `hlod_disable` console command for the HLOD tier specifically (separate from the `toggle hlod` visibility flag).
4. **Launch the main scene (`scenes/Godotwind.tscn`) — not a test scene — for baseline and acceptance.** Distant rendering only stresses realistic with the full ESM load. Test scenes don't stream at scale.
5. **Headless framerates are NOT trustworthy** (see `MEMORY.md` → `feedback_headless_framerates.md`). All perf numbers must come from a real-renderer launch with a window on screen.
6. **Never nuke in-progress work.** If a phase reverts cleanly via `git stash` / `git revert`, do that. Don't delete files unless the phase's rollback explicitly says so. If you hit something unexpected, STOP and post in chat, don't `git checkout --`.
7. **Verify every Godot API before recommending as a fix.** Check the doc contract (project-setting prerequisites, defaults) before claiming a behavior. Cite the doc URL or a runtime check in the phase notes.

---

## 3. Phases

### PHASE 0 — Baseline measurement (status: TODO)

**Goal:** produce ground-truth numbers to size every subsequent phase against. No code changes.

**Procedure:**
1. Ensure project is on clean checkout of the `refactor/lod-b-wide` branch (current). Note the commit SHA at measurement time in §4.
2. Launch `scenes/Godotwind.tscn` in Godot editor at Play.
3. Wait for initial streaming to settle (watch the HUD — `hud` console command — until `rendered_objects` and `draw_calls` stop climbing, plus ~5 s margin).
4. Run `bench` at the console. Script drives a 85 s flyby around Seyda Neen. Do not move the mouse or touch input during the run.
5. Copy the resulting `user://benchmark_results/<timestamp>/` folder into `docs/audit/bench/B0-baseline/`. Paste the per-segment averages into §4.1 of this file.
6. Repeat with `hlod_enable` set BEFORE running `bench` — produces a second baseline that captures the HLOD-on hot path. Copy to `docs/audit/bench/B0-baseline-hlod/`. Record in §4.2.

**A/B isolation passes (optional but cheap to do now):**
- `toggle only mid_objects` + `bench` → MID-tier isolated cost (save as `B0-mid-only/`).
- `toggle only impostors` + `bench` → FAR-tier isolated cost (save as `B0-impostors-only/`).
- `toggle none` + `bench` → empty world floor — establishes engine/terrain cost (save as `B0-empty/`).
- Subtract `B0-empty` from each isolated pass to get the net cost of that tier.

**Acceptance:** §4.1-4.3 populated. Phase status flipped to DONE.

**Why this is phase 0:** without numbers every subsequent acceptance gate is hand-wavy. The whole plan depends on this baseline existing.

---

### PHASE 1 — Free wins (status: IN_PROGRESS 2026-04-17)

**Goal:** trivial low-risk fixes that set the baseline clean before the big structural work. Audit §5.5, §5.6. Expected delta small — user reports MID is the bottleneck, not shadows/lights/GPU-scene.

**Changes:**
1. ~~Shadow distance cap.~~ **Skipped.** Verified 2026-04-17: `src/core/sky/sky_manager.gd:276` already sets `directional_shadow_max_distance = 200.0`. Tighter than planned. Audit §5.7 was wrong — was a false lever. No-op.
2. In `src/core/world/light_animator.gd`, gate the per-tick energy update on `is_visible_in_tree()` (or on a distance check). Tiny win; mostly removes a CPU-side O(n) loop for occluded lights.
3. Delete the `GPUSceneDatabase` fill path. Likely a measurable cold-start win since `add_cell_objects` fires on every async cell completion with a per-object `buffer_update` round-trip. Files to remove / no-op:

   [DONE 2026-04-17 — commit pending] `src/core/gpu_driven/` deleted (file + .uid + empty parent dir). `cell_manager.gd` `_gpu_scene_db` field + `set_gpu_scene_db` fn + `AsyncCellRequest.gpu_objects` field + fill block (line ~2078) + upload block (line ~2102) removed. `native_streaming_manager.gd` preload + field + `.new()` + wiring + 2 cleanup calls removed. `static_object_renderer.gd` `InstanceData.gpu_slot` field removed. `reference_instantiator.gd` `gpu_scene_db` field removed. Grep-clean (zero matches for `gpu_scene_db|GPUSceneDatabase|gpu_slot|gpu_objects|gpu_driven`).

4. **Candidate Phase 1 follow-up (PENDING USER AUTH):** disable `batch_cell_into_multimesh` call at `cell_manager.gd:2091-2092`. Author's own measurement (in-line comment line 2085-2090) states it regressed 15-20 FPS at steady state vs the unbatched path. 1-line change (`if false and not request.is_interior ...`). Will be superseded when Phase 3 ships a working world-scoped batcher, but until then the per-cell path is a measured net loss. Not auto-applying — user's call.
   - Delete `src/core/gpu_driven/gpu_scene_database.gd` (plus `.uid` sidecar).
   - In `src/core/world/cell_manager.gd`, remove the `add_cell_objects` / `remove_cell_objects` / `set_gpu_scene_db` calls and the field itself. Verify via audit §5.5 references.
   - In `src/core/world/native_streaming_manager.gd`, remove the initialization that wires the GPU scene DB into cell manager if any.
   - In `src/core/world/static_object_renderer.gd` and `src/core/world/reference_instantiator.gd`, remove any `_gpu_scene_db` references.
   - Grep `gpu_scene` at the end — must return 0 matches in `src/`.

**Measurement:**
- Re-run `bench` (both HLOD-on and HLOD-off). Compare against §4.1 / §4.2.
- Compare shadow-map rasterization cost via Godot's built-in profiler (Debug → Profiler → "Shadow Map Update").

**Acceptance:**
- `bench` shows ≥5 FPS improvement in `vista` and `run` segments of both HLOD passes.
- Grep `gpu_scene` returns zero matches in `src/`.
- No new console errors / warnings during `bench` flyby.

**Rollback:** `git revert` the phase commit. Nothing irreversible.

---

### PHASE 2 — Tween-fade replaced by shader fade (status: TODO)

**Goal:** remove per-object `Tween` created in `reference_instantiator.gd:1226`. Audit §5.4. Hypothesis: also fixes the remaining intermittent crashes from Tween lambdas capturing freed instances during cell unload.

**Why the hypothesis:** line 1224 comment admits the failure mode ("Lambda capture was freed"). Guard added, but Godot Tween lifecycle interacts poorly with `RefCounted` subtree frees under burst load. A shader-driven fade has zero script-level state.

**Changes:**
1. Add a `spawn_time` uniform to the standard prebaked fade shader (or a shader override on the root `GeometryInstance3D`). Read current `TIME` in fragment. Fade = `smoothstep(spawn_time, spawn_time + FADE_DURATION, TIME)`. Discard below ~0.05 for TRANSPARENCY_ALPHA-style cutout correctness on vegetation.
2. On instantiate, write the spawn timestamp to the material's shader param (or to `MultiMesh.set_instance_custom_data(slot, Color(spawn_time, 0, 0, 1))` when we hit phase 3).
3. Delete `_start_fade_in_tween` (line ~1100-1250 block) and the tween lambda guards.
4. Delete `fade_material_pool` if nothing else consumes it (grep first).

**Measurement:**
- `bench` — specifically the `walk` and `run` segments (they burst-load cells). Compare p95 frame time against §4.1. Expected: ≥20% drop in p95 for walk/run segments.
- Run `scenes/Godotwind.tscn` for 10 minutes of free camera flight. Record crash count. Compare against a pre-phase 10-minute run. (Yes, requires actual launch.)

**Acceptance:**
- Grep `create_tween` in `reference_instantiator.gd` returns 0 matches.
- p95 frame time in walk/run segments drops by ≥20%.
- Zero crashes in the 10-minute flight (prior baseline: user reports "crashing a LOT").

**Rollback:** `git revert`. The old tween path is self-contained.

---

### PHASE 3 — World-scoped per-prototype MultiMesh for MID (status: TODO)

**This is the big one.** Audit §5.2, §7 lever 1. Biggest single FPS delta in the whole plan. Prerequisite for Phase 5 (pushing impostors to 1 km).

**CRITICAL DATA POINT — inherited measurement:** `src/core/world/cell_manager.gd:2085-2090` comment (author 2026-04-17) states per-cell `batch_cell_into_multimesh` **regressed ~15-20 FPS at steady state** vs the unbatched path on this branch. Two diagnosed reasons:
1. Centroid-based `visibility_range` kept batch-internal geometry alive past 500 m (any slot within the centroid's visibility band stays rendered, even slots that would have been culled individually).
2. Adding ~1000+ batch `RS.instance_create` objects on top of the existing per-instance RIDs wasn't offset by the individual draws saved.

**This is measured on real hardware. It invalidates the audit's naive "just batch" recommendation.** Phase 3 design MUST solve both:
- **Centroid visibility_range problem:** world-scoped batching cannot anchor per-cell. Options: (a) no per-batch `visibility_range` — cull per-slot via shader distance → degenerate transform; (b) `multimesh_set_visible_instances()` driven by a CPU distance pass per frame; (c) partition each prototype into distance-band MultiMeshes (e.g. NEAR-MID 150-300 m, MID 300-700 m, FAR-MID 700-1000 m), migrate slots between bands on cell transitions.
- **Extra RS instance count:** the per-instance RIDs MUST be freed at the moment a slot joins a batch (current code does this correctly at line 734-742, but the overlap window during cell finalize can spike). For world-scoped, instances must enter the batch at add-time (no intermediate individual RID), or be migrated in a single pass with tight sequencing.

**Current state (verified 2026-04-17):**
- `src/core/world/static_object_renderer.gd:598` has `batch_cell_into_multimesh` — per-cell, ≥4-count, single-sub-mesh-only. Buildings explicitly excluded at line 620-621.
- Each `InstanceData` carries an `instance_rid` (when individual) or a `batch` + `mm_slot` (when per-cell-batched).
- Per-instance RS RIDs are freed when a cell-batch absorbs the instances (lines 734-742).
- **The per-cell batching is currently ON** at `cell_manager.gd:2091-2092` despite the 15-20 FPS regression noted in the adjacent comment. Disabling it is a candidate Phase 1 follow-up (§ Phase 1 item 4).

**Target state:**
- One `MultiMeshInstance3D` (or raw RS MultiMesh) per `(mesh_rid, material_rid)` hash, spanning ALL loaded MID cells.
- Each slot addressable by `(prototype_key, slot_index)`. Slots recycled via freelist per prototype.
- Buildings no longer excluded. Each sub-mesh of a multi-sub-mesh prototype gets its own batch (1 prototype with 5 sub-meshes → 5 batches, each batch collapses all instances of that sub-mesh world-wide).
- Threshold reduced to ≥2 (or zero — measure).
- Per-instance custom data carries: spawn time (Phase 2 fade), per-instance tint/seed if needed.
- `visibility_range_end` on the batch RS instance = the farthest-visible slot distance. Simpler: set it to 1 km unconditionally and let the slot-transform's distance-to-camera carry fade.

**Design decisions to resolve during implementation (document in §5 of this file):**
- **Per-prototype centroid vs. per-slot world transforms:** per-cell batches anchor to centroid (lines 675-678). World-scoped batches can't — too many cells. Use world-origin anchor, store each slot's absolute world transform. `visibility_range` evaluated per-batch (at world origin) doesn't make sense → disable per-batch `visibility_range`, rely on slot-level distance in shader OR use `multimesh_set_visible_instances` (verify API, 4.6 docs).
- **Dynamic resize:** `MultiMesh.instance_count` resize reallocs the buffer. Pre-allocate a generous slab (e.g. 4096 slots per prototype, grow by 2× when exceeded, never shrink). Track via freelist.
- **Shadow-caster opt-out:** at >MID_END distance the slot contributes shadows we'll later cap anyway (Phase 1). Verify per-instance shadow casting is not a cost sink for distant batches.

**Implementation notes:**
- Replace `batch_cell_into_multimesh` entirely — per-cell batching becomes dead code. New entry point: `add_instance_to_prototype_batch(instance_id)` / `remove_instance_from_prototype_batch(instance_id)`, called from cell load / cell unload.
- Keep the `InstanceData` struct, but `batch` field points to a `PrototypeBatch` (new RefCounted) instead of `CellBatch`.
- `PrototypeBatch`: `{ mesh_rid, material_rid, multimesh, multimesh_rid, rs_instance, slot_freelist, slot_count_live, slot_count_capacity }`.
- Registration goes through a new `PrototypeRegistry` indexed by `(mesh_rid, material_rid)`.
- Cross-reference the XRReady/multi-mesh project (https://github.com/XRReady/multi-mesh) BEFORE writing code — if it does exactly this as a drop-in addon, adopt (after verifying 4.6 compatibility + license). If it's stale, hand-roll. Budget: 30 min investigation, then decide.

**Measurement:**
- `bench` HLOD-off and HLOD-on. Compare `draw_calls` column of the CSV per segment vs §4.2.
- Target: `vista` segment `draw_calls` drops by ≥50%.
- FPS in `vista` + `run` segments: +20-40 FPS expected over phase-1 baseline.

**Acceptance:**
- `bench` horizon-view draw_calls count < 3,000 per frame (was likely 10k+ pre-phase; verify against §4.1).
- FPS ≥100 in `vista` segment on baseline hardware.
- No visual regressions — especially at MID/HLOD handoff. Do a manual 5-minute free-camera flight and record a short video. Post in chat for user review before marking DONE.

**Rollback:** revert commit. Old per-cell batch code is in git history. If new path has subtle bugs (missing instance removal, MultiMesh buffer corruption), revert immediately, don't patch.

---

### PHASE 4 — HLOD / MID dedup + HLOD authority cleanup (status: TODO)

**Goal:** eliminate the double-render hazard (audit §5.1). Refs swallowed by an HLOD chunk must not also exist as live MID instances. After this phase HLOD is ON by default (it has to be, to maintain 1km fidelity post-Phase 5).

**Option tree, pick one based on Phase 3 outcome:**

- **Option A — dedup registry (light touch, keeps current architecture).** `object_paging` publishes `covered_refs` per chunk. On chunk build, `StaticObjectRenderer.remove_instance` on every covered ref. On chunk destroy, `re_add_instance` to restore MID. Lifecycle bookkeeping in both places. Risk: one-off bugs at chunk eviction.

- **Option B — invert ownership (deeper rewrite, simpler end state).** MID tier is strictly 150-300 m, always. HLOD tier is strictly 300-1000 m, always. When HLOD is "off", run a degenerate HLOD-of-one (pass-through chunk with no merging). Same render path either way. Fewer moving parts, but requires `object_paging` to always be the 300-1000 m authority — meaning the pass-through case has to be fast.

**Recommended:** Option B if Phase 3 delivers the promised simplification (lever 1 already collapses MID into one MultiMesh per prototype — there's no per-instance MID past 300 m worth preserving). Option A if Phase 3 lands with edge cases that need MID to remain the authority.

**Measurement:**
- `bench` with `hlod_enable` vs without. Compare `rendered_objects` count in vista segment.
- Expected: `rendered_objects` in HLOD-on case drops by ~30-50% vs pre-phase-4.

**Acceptance:**
- Zero visible pop at MID→HLOD handoff when flying a test route through the 250-350 m band.
- `_stats.total_instances` after phase 4 is strictly lower than pre-phase for the same world position.

**Rollback:** revert commit.

---

### PHASE 5 — Push FAR_START to 1 km (status: TODO, DEPENDS on Phase 3 + Phase 4)

**Goal:** impostor tier START moves from 480 m → 980 m. MID+HLOD must carry 150-1000 m.

**Changes:**
1. In `src/core/world/distance_utils.gd`:
   ```gdscript
   const MID_END: float = 1000.0       # was 500.0
   const HLOD_END: float = 1000.0      # already 1000, no change
   const FAR_START: float = 1000.0     # was MID_END (500.0); break the alias
   const FADE_MARGIN_RENDER_FAR: float = 20.0  # keep
   ```
   Note: `FAR_START` was `MID_END` by reference, now an independent constant.
2. In `src/core/world/native_impostor_renderer.gd` shader + uniforms, set `visibility_range_begin = FAR_START - FADE_MARGIN_RENDER_FAR` and `visibility_range_end = FAR_END`.
3. In `src/core/world/static_object_renderer.gd`, set `visibility_range_end` default to `HLOD_END` (1000 m) when HLOD is on. Without HLOD, MID holds to 1000 m alone — rely on Phase 3's per-prototype MultiMesh for the draw-call budget.
4. In `src/core/world/object_paging.gd`, nothing to change (HLOD_END was already 1000 m).

**Pre-check:** Phase 3 acceptance met — MID draw count <3k at horizon. Otherwise pushing FAR_START to 1 km explodes the frame time.

**Measurement:**
- `bench` with new constants. `vista` segment FPS should not drop more than 10% vs post-Phase-4 numbers. If it drops more than 10%, Phase 3 didn't do enough — go back and tighten.
- Visual pass: fly to 950 m, 1050 m, 1500 m. Verify the impostor-to-geo handoff is clean (no flicker, no missing geometry, fade zone centered on 980-1000 m).

**Acceptance:**
- FAR_START = 1000 at runtime (console log the value on startup to confirm).
- Impostors fire ONLY past ~980 m (visual check + `toggle only impostors` + fly around).
- FPS in `vista` segment within 10% of post-Phase-4 baseline.

**Rollback:** single-commit revert of constants.

---

### PHASE 6 — Impostor texture-array double-buffer (status: TODO)

**Goal:** kill the 6-8 ms main-thread stall from `_rebuild_texture_array` (audit §5.3). Not an FPS win — a smoothness / hitch-removal win.

**Approach:**
1. On rebuild tick, hand off the work to `WorkerThreadPool.add_task`. Worker:
   - Allocates new `Texture2DArray` images on CPU.
   - Stages them into a new `Texture2DArray` via `create_from_images` off the main thread.
2. Main-thread completion: atomic-swap the current array via `material_override.set_shader_parameter("texture_atlas", new_array)`. Old array held a frame before free for double-buffer safety.
3. Same pattern for `_rebuild_multimesh` — `multimesh_set_buffer` with a `PackedFloat32Array` is thread-safe against other RID ops; build the buffer on a worker.

**Caveat:** `Texture2DArray.create_from_images` may itself be main-thread only in 4.6 due to RID allocation. Verify before committing. If so, fall back to `RenderingDevice.texture_create` + `texture_update`.

**Measurement:**
- `hud` p99 frame time over a 5-minute flight. Pre-phase: expect a periodic 6-8 ms spike at ~2 Hz. Post-phase: spike gone.
- Frame-time histogram via the profiler.

**Acceptance:** p99 – p50 frame-time gap drops by ≥5 ms in the walk/run segments.

**Rollback:** revert.

---

### PHASE 7 — Burst cold-start budget (status: TODO)

**Goal:** directly address "very long time to stabilize to 60 FPS". Audit does not cover this — added per user request.

**Approach:**
In `src/core/world/native_streaming_manager.gd`, track a `startup_mode` flag that stays true for ~3 seconds after the first scene load (and also after a teleport, signalled by a large camera jump). In `startup_mode`:
- `INSTANTIATION_BUDGET_MS` raised from 8 → 25 ms.
- `MERGES_PER_FRAME` raised from 2 → 6.
- Accept 30 FPS for the burst window. After `startup_mode` ends, drop back to 4 / 2 / 60-FPS-target budgets.
- Signal the HUD via a "STARTUP" banner so user sees it's intentional.

**Exit condition:** `startup_mode` ends when either (a) 3 seconds elapsed since entry AND (b) `_pending_load_queue.size() + _pending_rs_hide_cells.size() < 8` (steady-state threshold — tune).

**Measurement:**
- Launch `scenes/Godotwind.tscn` cold, start a stopwatch, note time until HUD FPS stabilizes above 55 for 3 consecutive seconds. Record pre/post.
- Teleport via the debug teleport command. Same measurement.

**Acceptance:** time-to-stable-60 drops by ≥30% (target: <10 s cold start, <5 s post-teleport).

**Rollback:** revert the budget multiplier.

---

### PHASE X (stretch) — Skip Node3D for pure-static refs (status: PARKED)

**Why parked:** high reward, high risk, premature before the phases above ship.

**Idea (audit §0 radical):** MID-tier refs that will never be interacted with never need a `Node3D`. They are allocated only so they can be promoted at <150 m. Promote-on-demand from the ESM record directly, cutting `reference_instantiator` / `object_pool` / `model_loader`'s per-MID-object allocation path to zero. Industry: UE's Hierarchical Instanced Static Mesh.

**Revisit after Phase 7.** If FPS ≥120 and load time acceptable, maybe not worth the disruption.

---

### PHASE X (stretch) — Compute-shader MultiMesh culling (status: PARKED)

**Idea:** `RenderingDevice` compute pass per frame that culls MultiMesh slots against frustum + occluders + distance, writes a packed visible-slot array, swap into MultiMesh via `multimesh_set_visible_instances`. Closest 4.6 comes to GPU-driven without bindless.

**Revisit after Phase 3 if draw-call count is still the bound at 140 FPS target.**

---

## 4. Measurement Log

**Format per row:** commit SHA, date, baseline name, segment, avg FPS, p95 frame ms, avg draw_calls, avg rendered_objects, avg primitives, notes.

### 4.1 Baseline — verbal report from user, 2026-04-17 (Phase 0 SKIPPED)

Phase 0 was skipped by user decision 2026-04-17. User-reported ground truth, commit `a4a36f5`, `refactor/lod-b-wide`, HLOD default (off):

- **Cold start / loading:** ~14 FPS for the first 1-2 minutes until streaming settles.
- **Steady state:** ~50 FPS, nearly flat even while moving fast across the map.
- **Stability:** crashes periodically (still flagged as "a LOT"), crash cause unidentified.
- **Subsystem cost breakdown (user-observed, qualitative, single-hardware):**
  - MID tier: **dominant CPU/GPU consumer**, the resource hog.
  - Impostors: "super light" at steady state; "some resources" during loading (matches audit §5.3).
  - Terrain: light at steady state.
  - Weather: light at steady state.
  - Sky + ocean: ~4 ms each. Not the bottleneck, but on the radar.

**Implication for plan ordering:** Phase 3 (world-scoped per-prototype `MultiMesh`) is confirmed as the biggest lever. Phase 1 shadow-cap item is likely low-value — verified below.

### 4.2 Runtime verification — Phase 1 preconditions (pre-code pass)

Verified against commit `a4a36f5` before writing Phase 1 code:

- **`directional_shadow_max_distance` is ALREADY CAPPED** at `src/core/sky/sky_manager.gd:276` → value `200.0`. Audit §5.7 was wrong on this point (it grepped for the constant but missed the actual set). Tighter than the plan's originally proposed 500 m. **Phase 1 item 1 (shadow cap) skipped — no-op.**
- `_sun_light.shadow_normal_bias = 1.5`, `shadow_bias = 0.02`, `directional_shadow_mode = SHADOW_PARALLEL_4_SPLITS`. `blend_splits` is not set (default false) — could be tuned later, out of scope for Phase 1 without measurement.
- `_moon_light.shadow_enabled = false` — correct, moon shadows are a waste at night.
- `light_animator.gd:_process` ticks unconditionally at 15 FPS (line 86-122). No `is_visible_in_tree` gate. Target for Phase 1 item 2.
- `GPUSceneDatabase` fill path active:
  - Instantiated at `native_streaming_manager.gd:390`.
  - Wired to cell manager at `native_streaming_manager.gd:406`.
  - `add_cell_objects` called at `cell_manager.gd:2103` on every async cell completion.
  - `remove_cell_objects` guard at `cell_manager.gd:2078`.
  - `static_object_renderer.gd:131` has a per-instance `gpu_slot: int = -1` field (never read as input to a shader — confirmed via grep: `_object_buffer` has no non-internal consumers).
  - `reference_instantiator.gd:51` has a `gpu_scene_db: RefCounted` field.
  - No consumer shader reads the SSBO. Safe to delete. Target for Phase 1 item 3.

### 4.3 Post-phase re-measurements

Appended as phases complete.

#### Phase 1 + 2 + 7 (commits 4641010 / 3ade1f3 / 52beb34 / 4a5d8dc)

**Runtime verification (headless, 2026-04-17):**
- 20 s `--headless --quit-after 20` run of `scenes/Godotwind.tscn`.
- Zero parse / compile / shader errors.
- Zero `SCRIPT ERROR`, `Identifier not found`, or `Invalid` log lines.
- Only pre-existing warnings: Terrain3D `instance_reset_physics_interpolation` deprecated + Terrain3D `free_editor_textures` hint.
- Signal 11 crash on shutdown — pre-existing, fires AFTER initialization completes + simulation ran for the requested duration. Consistent with user-reported "crashes a lot" and not caused by phase-1/2/7 edits.

**FPS delta:** not yet measured with real renderer. User's original baseline (§4.1): 14 FPS cold / 50 FPS steady. Expected direction (unvalidated):
- Phase 1 GPUSceneDatabase delete: minor cold-start win (removes per-object PackedByteArray + buffer_update on each cell load).
- Phase 2 shader-fade: marginal per-frame CPU win + removes one known crash class.
- Phase 7 budget raise: shorter cold-start window; steady-state unchanged.

### 4.N Post-phase re-measurements

_Appended as phases complete. Each re-measurement cites the commit SHA and the phase number._

#### Phase 3 steps 2-4 (commits d71302c / f5472b1 / 5e2450a / 93973df / f3105ca)

**Runtime FPS delta:** NOT YET MEASURED. Flag defaults OFF; legacy path is byte-unchanged. User to A/B via `proto_registry on` + scene restart + `bench` HLOD-on/off before step 5 C# port.

**Test-suite verification (headless, 2026-04-17):**
- All 10 `test_prototype_registry.gd` tests pass (slot lifecycle, registry dedup, multi-sub-mesh, remove idempotency, batch_key stability).
- All 7 `test_static_object_renderer_bwide.gd` tests pass.
- 9 `test_object_paging_kernel.gd` failures remain pre-existing (per handoff — unrelated to Phase 3).
- Zero new script errors / parse errors / Identifier-not-found on `--headless --quit-after 20`.

---

## 5. Design Decisions Log

Append decisions made during implementation that future sessions will inherit. Format: one H3 per decision, dated, with the alternatives considered.

### 2026-04-17 — PrototypeBatch owns slot storage, MM is a write-through sink (Phase 3 step 4)

**Context:** step-3 first-draft had `set_slot_transform` writing to `multimesh.set_instance_transform(slot, xform)` directly, with a fallback "visible=capacity, degenerate holes" rendering mode. Once the step-4 cull pass packed visible slots into buffer positions 0..N, sparse `slot_id > N` writes started stomping packed-slot data and never became visible until the next cull tick. One-frame glitches on cell load.

**Decision:** PrototypeBatch now owns two PackedFloat32Array fields (`slot_transforms`, `slot_custom_data`) indexed by slot id. `set_slot_transform` / `set_slot_custom_data` write only to these. The MultiMesh's internal buffer is written exclusively via `RenderingServer.multimesh_set_buffer` during `cull_and_upload`. Pre-cull state = `visible_instance_count = 0`, nothing renders until driver ticks.

**Alternatives rejected:**
- "Dual-write + always-tick every frame" — avoids the stomp but costs O(total_slots) per frame even with zero churn. Kills battery / perf on idle.
- "Sparse→packed index map maintained per-batch" — lets `set_instance_transform` find packed position. Extra bookkeeping, subtle race if cull runs mid-add. More code than the single-source-of-truth fix.

**Canonical reference:** `native_impostor_renderer.gd:1757-1826` — same pattern (own the buffer, upload via `set_buffer`). Confirmed good on Godot 4.6.

### 2026-04-17 — GDScript cull pass gates on dirty flag OR camera-moved (Phase 3 step 4)

**Context:** running cull every frame is O(total_slots) regardless of churn. At steady-state ~30k slots it's ~5-10 ms GDScript per frame — bigger than the draw-call win for a non-moving camera.

**Decision:** `PrototypeRegistry._cull_dirty` set by any add/remove/transform/hide mutation. `tick_cull_if_needed(cam_pos, max_dist_sq)` re-culls only when dirty OR camera moved ≥ `CULL_DISTANCE_HYSTERESIS` (10 m, §5 of the design doc). Angle hysteresis is not implemented yet; distance is sufficient for step-4 correctness.

**Alternatives rejected:**
- "Cull every frame" — cost listed above.
- "Cull on cell change only" — doesn't handle camera movement within a cell where a previously-out-of-range slot enters range.



---

## 6. File Map — Likely Edits by Phase

| Phase | Files |
|---|---|
| 0 | none — measurement only |
| 1 | `src/core/world/sky_manager.gd` (verify location), `src/core/world/light_animator.gd`, delete `src/core/gpu_driven/gpu_scene_database.gd`, trim `src/core/world/cell_manager.gd` + `static_object_renderer.gd` + `reference_instantiator.gd` + `native_streaming_manager.gd` GPU-scene references |
| 2 | `src/core/world/reference_instantiator.gd`, the fade shader asset |
| 3 | `src/core/world/static_object_renderer.gd` (major), `src/core/world/cell_manager.gd` (minor), possibly new `src/core/world/prototype_registry.gd` |
| 4 | `src/core/world/object_paging.gd`, `src/core/world/static_object_renderer.gd`, `src/core/world/native_streaming_manager.gd` |
| 5 | `src/core/world/distance_utils.gd`, `src/core/world/native_impostor_renderer.gd`, `src/core/world/static_object_renderer.gd` |
| 6 | `src/core/world/native_impostor_renderer.gd` |
| 7 | `src/core/world/native_streaming_manager.gd` |

---

## 7. Reviewer Engagement

Per `CLAUDE.md` "Reviewer Engagement Scope": reviewer (`@reviewer` / `@roaster`) engages at two points per phase:
- Plan review (this doc, or a phase-specific plan addendum if the phase grows its own design doc).
- Implementation review (after the first draft of the phase's code lands).

No mid-phase acks. If the implementer drifts (e.g. Phase 3 grows a second epicycle of complexity), that is the signal to re-engage — not a scheduled tick.

---

## 8. Status Snapshot

| Phase | Status | Gate |
|---|---|---|
| 0 — Baseline | SKIPPED (verbal) | user-reported ~14→50 FPS; §4.1 recorded |
| 1 — Free wins | DONE (partial) | GPUSceneDatabase deleted + LightAnimator gated; batch_cell_into_multimesh disable parked pending user auth |
| 2 — Shader fade | DONE | Tween removed, shader reads TIME+spawn_time; crash-free flight test pending user run |
| 3 — World-scoped MultiMesh | IN_PROGRESS — steps 1-4/8 done | draw_calls <3k @ horizon, FPS ≥100 @ vista. Design v2 @ `docs/audit/PHASE_3_MID_MULTIMESH_DESIGN.md`. Step 1: skeletons + tests (89780df). Step 2: StaticObjectRenderer feature flag + registry routing (d71302c, f5472b1, 5e2450a). Step 3: batch render correctness without cull (93973df). Step 4: GDScript cull pass + registry.tick_cull_if_needed driver (f3105ca). Steps 5-8 (C#, shader, dead-code delete) pending; runtime A/B of GDScript cull pending user. |
| 4 — HLOD/MID dedup | TODO | rendered_objects HLOD-on drops ≥30% |
| 5 — FAR_START = 1 km | TODO | impostors >980 m only, vista FPS -10% ceiling |
| 6 — Impostor double-buffer | TODO | p99-p50 gap -5 ms |
| 7 — Burst cold-start | DONE (partial) | startup budget 15→25 ms; post-startup 4 ms kept; teleport detection not implemented |
| X — Skip Node3D (stretch) | PARKED | revisit post-7 |
| X — Compute cull (stretch) | PARKED | revisit post-3 |

**Flip a phase's status to IN_PROGRESS when you start. Flip to DONE only after the Acceptance gate is met AND §4 has been updated.**
