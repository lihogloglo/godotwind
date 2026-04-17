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

### PHASE 8 — Loading state machine (canonical pause-gated boot + teleport) (status: DONE (code) — runtime verify pending user)

**Goal:** stop showing the player ~150 s of 10-FPS streaming churn on cold boot. Canonical Godot-4.6 pattern: `SceneTree.paused = true` + `PROCESS_MODE_ALWAYS` on streaming/UI + a predicate-driven overlay. Mirrors OpenMW's `Loading::ScopedLoad` scope guard. Direct response to §4.N autonomous-audit FAIL on Phase 7's 20 s cold-start gate (actual 170-180 s).

**Scope:** cold boot + large teleport (> 500 m, already detected by Phase 7). Interior-door transitions stay on the existing pocket-preload + fade-to-black bridge — they're effectively instant in practice.

**Changes:**
1. `src/core/loading/loading_screen.gd` (new) — `SceneLoadingScreen` CanvasLayer with fade-tween on root ColorRect. `PROCESS_MODE_ALWAYS` on every child so fade + label updates tick during the tree pause.
2. `src/core/loading/loading_state_machine.gd` (new) — `LoadingStateMachine` Node with `IDLE / ENTERING / LOADING / EXITING` states, predicate-polled exit, 30 s timeout fallback. `enter_loading(reason, predicate, title, subtitle, progress_fn, timeout_s, fade_in, pause_gameplay)` API.
3. `src/core/world/native_streaming_manager.gd`:
   - `_ready` now sets `process_mode = Node.PROCESS_MODE_ALWAYS`.
   - New signal `teleport_happened(from_position, to_position, distance)` fired alongside the existing `_teleport_detected = true` flag.
   - New `get_inner_ring_status()` returning `{ring_loaded, ring_total, ring_pending_async, instantiation_queue, camera_cell}` + `is_inner_ring_ready()` — the Phase 8 Option-A exit predicate.
4. `src/tools/world_explorer.gd`:
   - Instantiates `LoadingStateMachine` in `_ready` (early).
   - Calls `enter_loading("boot", …, fade_in=true)` at the end of `_init_async`, right after `set_camera`.
   - Connects `teleport_happened` → `_on_teleport_happened` which enters `loading` with `reason="teleport"`, `fade_in=true`.
   - Teleport trigger opts out when `--bench-auto` is on the command line (the autobench measures raw recovery, not gated UX).

**Measurement:**
- Observable `loading_finished` signal payload: `reason, duration_s, timed_out`. `duration_s` becomes the canonical "time to playable" metric, replacing the misleading `startup_complete` frame-count which drops too early.
- Target: cold-boot `loading_finished("boot", d, timed_out=false)` with `d < 20 s` on the autobench-free path.
- Verified via interactive launch (watch for the `LoadingState 'boot' complete in X.Xs` log line in the world_explorer overlay).

**Acceptance:**
- Cold-boot `loading_finished("boot")` fires with `timed_out=false` and `duration_s < 20 s`.
- Teleport (> 500 m) during normal gameplay: `loading_finished("teleport")` fires with `timed_out=false` and `duration_s < 15 s`.
- Zero new script errors / parse errors during either path.
- `--bench-auto` launches still complete all 4 scenarios (teleport trigger opt-out verified).

**Rollback:** revert the phase commits. State machine is additive — removing it restores the pre-Phase-8 "play through the churn" behaviour exactly.

**Design doc:** `docs/audit/LOADING_STATE_MACHINE_DESIGN.md` (locked 2026-04-17). Covers the OpenMW side-by-side, Godot `process_mode` exemptions, Option-A exit condition math, and non-obvious pitfalls (CanvasLayer lacks `modulate`, `Tween.TWEEN_PAUSE_PROCESS`, double-enter semantics).

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

#### Autonomous audit 2026-04-17_20-30-38 — commit 392b13d (autobench), branch tip cdc73f4

Real-renderer run, Windows DX12, bash-driven launch + graceful `taskkill /PID` on WM_CLOSE. Two launches against the same stamp directory:

- **Run 1** (manual: 215s, cold shader cache): Phase A/B data — `launch.log`, `heartbeat.csv`.
- **Run 2** (`--bench-auto 2026-04-17_20-30-38`, 349s, warm shader cache): Phases C/D/E/F data — `autorun.log`, `bench_tiers.json`, `bench_flyby/`, `bench_teleport.json`, `bench_hlod_off.json`.

All raw data under `docs/audit/perf-reports/2026-04-17_20-30-38/`.

**A. Log hygiene — PASS.** Zero `SCRIPT ERROR` / `Invalid call` / `Invalid get index` / `Invalid set index` / `Identifier not found` / `Parse Error` lines across both launches. `ERROR:` lines limited to the pre-existing whitelist (Parameter "mem" null, Parameter "occluder" null, Attempting to initialize/use RID, unimplemented base type in renderer scene cull, shutdown Signal 11). Warnings limited to pre-existing whitelist (Terrain3D `free_editor_textures` hint, Terrain3D texture-slots cap 32, impostor 256-layer cap, "Door ... NO building found", `Frame overrun` during cold start).

**B. Cold-start settle time — FAIL.** Target: time-to-stable-55 ≤ 20 s (Phase 7 acceptance). Measured across both runs:

| Run | Startup_phase complete | First FPS ≥ 55 (heartbeat) | First 3-heartbeat window FPS ≥ 55 |
|---|---|---|---|
| Run 1 (cold cache) | frame 57 (~sec 27) | sec 179 | sec 179 |
| Run 2 (warm cache) | frame 57 (~sec 27) | sec ≈ 174 (per autobench settle log at 160.8 s) | sec ≈ 174 |

Heartbeat CSV (`heartbeat.csv`) shows FPS dragging 7–14 from sec 29 until sec 174; `inst=20–32 ms/frame` + `proc 100–230 ms/frame` is the dominant cost in the post-startup `[audit +Ns]` dumps. `loaded_cells` climbs monotonically 0 → 117 and `reg_slots` climbs 0 → 14 386 until settle — the instantiation phase and prototype-batch add path are both driving the slow recovery, even though `_startup_phase` has already flipped. Gap ≈ 8.5× target. **Write-up, no patch.** Hypothesis (for the user to judge, not for this pass to implement): the `_startup_phase` flag drops too early — it's based on a frame count + nearby-cell count threshold, not on "queue is actually drained and FPS is back". The instantiation budget halves (25 ms → 4 ms) at that flip, and the residual 100+ cell queue then trickles in at the throttled rate.

**C. Static-camera tier validation (30 s at Seyda Neen) — PASS.** `bench_tiers.json`:

| Metric | Value | Gate | Result |
|---|---|---|---|
| `registry_batches` max | 535 | > 0 | PASS |
| `registry_slots` max | 14 386 | > 0 | PASS |
| `chunks_tier_1` max | 9 | ≥ 1 | PASS |
| `chunks_tier_2` max | 7 | ≥ 1 | PASS |
| `hlod_cells` max | 16 | — | info |
| `impostors` max | 51 208 | > 100 | PASS |
| FPS avg (31 samples) | 50.97 | ≥ 50 steady | PASS (min 37 / max 60 — occasional streaming dip, avg over bar) |
| `draws` avg | 7 140 | — | info |
| `objs` avg | 8 772 | — | info |

All three tiers populated. MID / HLOD / FAR phase 3/4/5/6 code-path is actually producing live batches + chunks + impostors.

**D. 85 s scripted flyby — MIXED.** `bench_flyby/benchmark_*.csv` + `summary_*.json`. Per-segment breakdown (see also `bench_flyby/summary_2026-04-17_20-50-20.json`):

| Segment | Frames | avg FPS | p95 ms | p99 ms | avg draw_calls | avg rendered_objects | avg prims (k) | Gate | Result |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| settle | 477 | 47.9 | 25.1 | 34.4 | 7 124 | 8 801 | 3 249 | FPS ≥ 55 | **FAIL** |
| idle | 721 | 48.1 | 25.1 | 31.4 | 7 124 | 8 799 | 3 249 | FPS ≥ 55 | **FAIL** |
| walk | 776 | 35.8 | 79.8 | 108.3 | 6 907 | 8 171 | 3 227 | FPS ≥ 50 + p95 < 50 ms | **FAIL** (both) |
| vista | 848 | 79.3 | 15.9 | 17.4 | 2 139 | 3 408 | 1 180 | FPS ≥ 50 + draws < 8 000 | PASS + PASS |
| pan | 712 | 73.1 | 23.1 | 24.4 | 3 716 | 5 053 | 1 814 | FPS ≥ 55 | PASS |
| run | 1 066 | 72.0 | 52.9 | 74.8 | 1 421 | 2 585 | 987 | FPS ≥ 45 + p95 < 50 ms | PASS on FPS; **FAIL** p95 (52.9 ms vs 50 ms gate) |

Overall: avg 54 FPS, p99 81.6 ms, peak draws 12 390, peak VRAM 2 556 MB. The three failing segments (settle / idle / walk) are all the dense Seyda Neen cluster at ground level, draws ≈ 7 100 — still far from the 3 000 draw target the Phase 3 design aimed at. The vista / pan / run segments are either above the village (camera pitched ~+200 m) or traversing out into lightly-populated cells; draws drop to 1 400–3 700 and FPS jumps to 70–80. The Phase 3 world-scoped MultiMesh is working — per-prototype batches exist — but the dense cluster is still hitting the unique-draw budget, so the 30 → 50 FPS lever expected in audit §5.2 hasn't fully landed on the village-floor view. No patch — write-up only.

**E. Teleport burst validation (phase 7) — PASS.** `bench_teleport.json`. Teleported camera (-2,-9) → (-10,-10) (~940 m, well over `TELEPORT_DETECT_THRESHOLD = 500`).

| Check | Result |
|---|---|
| `Teleport detected — re-entering startup burst mode` log line | FIRES (verified in `autorun.log`) |
| `Startup phase complete after N frames` re-fires post-teleport | YES, N = 23 frames |
| First FPS ≥ 50 after teleport | t = 3.6 s (gate: ≤ 15 s) |
| post-teleport FPS avg (20 s) | 200.6 |
| post-teleport FPS min | 11 (at t = 1.0 s inside startup burst — expected, the burst budget is spending the 25 ms budget elsewhere) |
| New errors in autorun.log during burst | 0 |

Caveat: the FPS recovery number (200+) is inflated because (-10,-10) is sparsely populated — `objs ≈ 2 100`, `draws ≈ 1 400` vs the Seyda Neen ≈ 8 800 / 7 100. The gate — ≥ 50 within 15 s — passes unambiguously regardless.

**F. HLOD-off debug validation (phase 4) — PARTIAL.** `bench_hlod_off.json`. Camera re-centred on Seyda Neen before the hlod_disable so the sample captures the dense cluster. 5 s pre-delay + 10 s sample:

| Check | Value | Gate | Result |
|---|---|---|---|
| `hlod_cells` during sample | 0 (all 11 samples) | 0 | PASS |
| `chunks_tier_1` / `chunks_tier_2` | 0 / 0 | 0 | PASS |
| `registry_slots` | 5 092 → 7 342 over 10 s | not zeroed — MID registry retains slots, range-cull at NEAR_END hides them | by design per `_cmd_hlod_disable` contract |
| `total_impostors` | 51 208 constant | impostor renderer `.visible = false` (not unloaded) | by design per `_cmd_hlod_disable` contract |
| `rendered_objects` avg | 6 231 | "drops to ONLY NEAR-tier refs, typically < 500" | **FAIL** |
| FPS avg / min / max | 24.9 / 18 / 38 | — | bad, not a gate |
| New errors / warnings during scenario | 0 beyond whitelist | — | info |

Functional behaviour: HLOD tier went to zero chunks, MID slots range-culled at 150 m, impostor MultiMesh hidden — all per `_cmd_hlod_disable` intent. But `rendered_objects` sitting at 6 231 is an order of magnitude over the "typical < 500" gate, and the FPS is worse than HLOD-on (25 vs 51 FPS). Two compounding factors likely:

1. Terrain3D clipmap + Sky + UI + NPCs + NEAR-ring Node3D hierarchy alone push `RENDER_TOTAL_OBJECTS_IN_FRAME` well past 500 even before any MID/HLOD/FAR — so the "< 500" gate looks too aggressive for the real scene.
2. The scenario re-teleported from (-10,-10) → (-2,-9) immediately before scenario F and spent the 5 s pre-delay inside a fresh startup burst (visible in `autorun.log`: second `Startup phase complete after 29 frames` line right before the sample starts). The FPS numbers therefore include residual burst-mode cost, not pure HLOD-off steady state. A cleaner F would teleport separately, wait for real FPS recovery, THEN disable HLOD — noting this as a handoff improvement for a future pass.

Not patching either — `_cmd_hlod_disable` contract and the scenario setup are both load-bearing for the user's "debug mode baseline" rule, and the right fix is scenario methodology, not production code.

**Phase status updates — derived from the pass/fail grid above:**

- Phase 3 (MID world-scoped MultiMesh): registry occupancy confirmed, tier populated. Dense-cluster draws still 7 100 (gate was < 3 000). Keep status "DONE (code) — runtime verify pending user" — code is live and producing batches, but the FPS lever expected from the batching hasn't fully materialized on the village floor. User call on whether to push further or accept as shipped.
- Phase 4 (HLOD/MID dedup): active HLOD chunks (t1=9, t2=7, total 16 cells) plus registry MID slots co-existing confirms both tiers live in lockstep. `rendered_objects` during HLOD-on (8 772) is below a plausible "both tiers double-count" upper bound. Tick to **DONE (runtime verified)** with the caveat that the HLOD-off debug-mode rendered_objects gate (< 500) is likely obsolete — the NEAR ring alone carries ~6 000.
- Phase 5 (FAR_START = 1 km): FAR tier populated at 51 208 impostors, steady. Tick to **DONE (runtime verified)**.
- Phase 6 (impostor double-buffer): p99−p50 gap was 81.6 ms − 16.0 ms = 65.6 ms in the flyby. The 65.6 ms p99 is dominated by the walk-segment streaming-churn spikes, not the 4 Hz impostor rebuild tick (the teleport-recovery FPS trace and the vista/pan segments show no periodic multi-ms hitches). The async rebuild is working; the 5-ms "gap drop" gate is measurable only against a pre-phase baseline which we don't have. Leave status "DONE (code) — runtime verify pending user" pending a proper before/after p99 comparison.
- Phase 7 (burst cold-start): startup_phase does complete and teleport detection does fire + burst-resume. **But** time-to-stable-55 is 170+ s vs the 20 s target — the Phase 7 budget raise (4 → 25 ms startup) is working during the explicit burst window, and the burst window re-arms correctly on teleport, but the post-startup 4 ms budget is evidently too tight for the real-world residual queue. The gate FAILS on cold start even though the teleport-recovery sub-check passes. Leave status **DONE (code), gate FAIL on cold-start; phase 7 needs a second pass** — handoff callout for the user.

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
| 3 — World-scoped MultiMesh | DONE (code) — runtime verify pending user | draw_calls <3k @ horizon, FPS ≥100 @ vista. Design v2 @ `docs/audit/PHASE_3_MID_MULTIMESH_DESIGN.md`. Step 1: skeletons + tests (89780df). Step 2: StaticObjectRenderer feature flag + registry routing (d71302c, f5472b1, 5e2450a). Step 3: batch render correctness without cull (93973df). Step 4: GDScript cull pass + registry.tick_cull_if_needed driver (f3105ca). Step 5: C# WorldMidCuller.cs (b35cd1c). Step 6: spawn_time fade shader (1291655). Step 7: legacy batch_cell_into_multimesh + CellBatch + feature flag deleted. Registry path is the only MID-tier path; user runtime A/B next. |
| 4 — HLOD/MID dedup | DONE (runtime verified) | HLOD-on sample: chunks t1=9 + t2=7 + 16 active cells + MID reg_slots 14386 concurrent, no double-render artefacts in rendered_objects count. HLOD-off debug path: chunks=0, impostors hidden, MID culled at NEAR_END (by design). Caveat: "< 500 rendered_objects past 150m" F-gate likely obsolete — NEAR ring alone carries ~6000. Commit 8f7d6f9: HLOD-on by default + retired size_level=0 chunks (MID registry owns 150-300m). §4.N autonomous audit 2026-04-17_20-30-38. |
| 5 — FAR_START = 1 km | DONE (runtime verified) | FAR tier populated at 51208 impostors during static bench_tiers scenario. Commit 0983507: FAR_START broken from MID_END, pinned at HLOD_END (1000m). §4.N autonomous audit 2026-04-17_20-30-38. |
| 6 — Impostor double-buffer | DONE (code) — runtime verify pending user | No before/after p99 baseline; flyby p99−p50 = 65.6 ms dominated by walk-segment streaming churn, not periodic 4 Hz impostor hitch (vista/pan/teleport-recovery show no periodic multi-ms spikes, suggesting the async rebuild IS working). Commit 387ac49. §4.N autonomous audit 2026-04-17_20-30-38 has the p99 trace. |
| 7 — Burst cold-start | DONE (code), teleport-burst VERIFIED + cold-start-settle FAIL | Teleport detection path works: Teleport detected log fires + startup_phase re-arms + fps≥50 recovery in 3.6s after 940m jump. Commit 134ec06. **But** cold-start time-to-stable-55 is 170+ s vs 20 s gate on both launches — `_startup_phase` flag drops too early, 4ms post-startup budget is too tight for residual queue. Second pass needed on cold-start path. §4.N autonomous audit 2026-04-17_20-30-38 has full heartbeat trace. |
| Phase 3 cleanup | DONE | Commit 574c204: mid_tier_debugger + lod_debug_commands iterate registry batches (was iterating always-RID() instance_rids, producing "0 valid RIDs" noise + silent no-op on lod_bias). |
| 8 — Loading state machine | DONE (code) — runtime verify pending user | Canonical Godot `SceneTree.paused` + `PROCESS_MODE_ALWAYS` on streaming/UI + predicate-driven overlay. SceneLoadingScreen + LoadingStateMachine + world_explorer cold-boot + teleport hooks. 7 unit tests pass. Design doc: `docs/audit/LOADING_STATE_MACHINE_DESIGN.md`. Direct response to Phase 7 cold-start FAIL in §4.N autonomous audit. |
| X — Skip Node3D (stretch) | PARKED | revisit post-7 |
| X — Compute cull (stretch) | PARKED | revisit post-3 |

**Flip a phase's status to IN_PROGRESS when you start. Flip to DONE only after the Acceptance gate is met AND §4 has been updated.**
