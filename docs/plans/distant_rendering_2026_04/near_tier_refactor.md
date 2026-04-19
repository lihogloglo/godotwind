# Open-World Streaming Architecture — Godotwind 2026-04-19

**Status:** DRAFT — master architecture doc. Awaiting user review. No code changes authorized yet.
**Paired with:** `docs/plans/distant_rendering_2026_04/plan.md` (parent distant-rendering work log, inherits its §2 ground rules).
**Supersedes:** the earlier "ring-based tier" sketch in revisions of this file prior to 2026-04-19.

Godotwind is a **generic open-world RPG framework**, not a Morrowind-specific streamer. The architecture must therefore reflect **modern AAA streaming patterns**, not legacy Bethesda cell-grid idioms. Morrowind data is one adapter on top; the core streaming layer should look like what a team at Epic / Guerrilla / CDPR would build in 2026.

---

## 0. Session Resume Pointer

Read in this order:
1. §1 — Non-Goals (scope).
2. §2 — Problem Statement (why we're here).
3. §3 — Target Architecture (the shape we're building toward).
4. §4 — Current Code Mapping (what we already have; what needs to change).
5. §5 — Refactor Phases. Pick the first phase with status `TODO`.
6. §6 — Godot-Native Innovations to preserve. Non-negotiable.
7. §7 — Ground Rules (inherited from parent plan).
8. §8 — Open Questions.

Acceptance gate: every phase ends with before/after numbers recorded in §9 (Measurement Log). No numbers = phase not done.

---

## 1. Non-Goals

- Not a Morrowind port. Morrowind data is an adapter; the core streaming code stays generic.
- Not shipping Nanite / virtualized geometry / GPU-driven mesh-shader pipeline. Godot 4.6 doesn't expose the hardware path. If / when it does, we revisit the MID tier (Nanite-class engines collapse MID→HLOD into continuous cluster streaming).
- Not touching Terrain3D internals. Treat as black-box.
- Not re-baking impostor textures. FAR tier stays as-is.
- Not redesigning the character / NPC streaming path. Actors are separate.
- Not building an editor-side "World Partition editor" UI. Authoring happens in the existing prebake pipeline.

---

## 2. Problem Statement

Three symptoms, one root cause:

1. When the user toggles `none → terrain → near_objects` (NEAR-only diagnostic), the NEAR ring does not behave as expected — objects that should appear within 150 m are missing, small objects sometimes render beyond 150 m, moving the camera does not reliably spawn new NEAR objects.
2. Three sessions of patching on `cell_manager.gd` have not fixed it (defer-for-NEAR queue, `_create_near_only_rs_instance` guard, VR overrides). Each patch papers over a symptom of a deeper issue.
3. The MID / HLOD / IMPOSTORS tiers interact with NEAR via per-object runtime promotions and demotions. Disabling one tier breaks the others.

Root cause (per the two research reports on 2026-04-19):

**`src/core/world/cell_manager.gd::process_async_instantiation` runs a per-object distance check at instantiation time and branches 4 ways based on `(mid_worthy, beyond_near, always_near)`.** That is the wrong axis of variation.

In modern AAA engines (UE5 World Partition, REDengine, RAGE, OpenMW), **cells are the I/O unit and the scene-graph attach unit**. A cell is activated by one or more `StreamingSource`s. Once a cell is resident, all its NEAR-tier actors attach to the scene graph unconditionally. The NEAR / MID / HLOD / FAR distinction is **a per-cell state** (which tier of asset to render for this cell), not a per-object runtime branch.

Our current code conflates the I/O axis (cell loaded / unloaded) with the rendering axis (per-object distance). That conflation makes feature-flag toggling fragile, makes the defer queue necessary, and makes the per-object promotion / demotion loops grow without bound as we add tiers.

---

## 3. Target Architecture

Four pillars, each with a clear responsibility. Each pillar maps 1:1 onto a canonical pattern in a shipping AAA engine.

### 3.1 Cell Grid (I/O unit)

The cell is the **only** I/O and scene-graph attach unit.

- Cell size: `DistanceUtils.CELL_SIZE_METERS = 8192 MW units ≈ 117 m`. Morrowind-derived but engine-generic — arbitrary game data can author cells at any size by changing this constant.
- Active set = union over all `StreamingSource` query ranges. NOT a fixed ring around the player.
- Transitions on boundary crossings use `mCellLoadingThreshold`-style hysteresis: a cell unloads when `min_dist_from_source > cell_size/2 + HYSTERESIS_MARGIN`, not the same threshold that loaded it. Prevents thrash.
- Attach is incremental across frames (main-thread budget), but is NOT per-object distance-gated. If a cell is resident, every NEAR actor in it becomes a Node3D.

References:
- UE5 World Partition: cells are `.uasset` I/O units; `UWorldPartitionSubsystem::UpdateStreamingState` walks the grid per source.
- OpenMW: `Scene::loadCell` attaches the full cell's refs to the scene graph in one incremental pass.

### 3.2 Streaming Sources

The `StreamingSource` abstraction replaces "player-centric ring" thinking.

- Any component can carry a source: the player camera, the active cinematic camera, an AI director, a network-replicated peer, a `FastTravelDestination`, a `QuestObjective`.
- Source carries `(position, velocity, near_range, mid_range, hlod_range, far_range)`. Cell state = worst-tier-any-source-demands.
- Player is the primary source; we ship with exactly one at first. The abstraction is free insurance for future features (spectator cam, split-screen, AI prefetch).
- Predictive preload uses `position + velocity * prediction_time` per source.

Reference: UE5 `UWorldPartitionStreamingSourceComponent`.

### 3.3 Stacked HLOD Grids (NOT rings)

Each render tier (MID / HLOD / FAR) is **its own grid**, not a radial ring around the cell grid.

- MID grid: 1×1 cell (= base cell grid), one RS instance per actor with embedded LOD chain (existing `StaticObjectRenderer` + `PrototypeRegistry`).
- HLOD grid 0: 1×1 cell (one merged mesh per cell footprint, covers ~150-300 m).
- HLOD grid 1: 2×2 cells (one merged mesh per 2×2 footprint, covers ~300-600 m).
- HLOD grid 2: 4×4 cells (one merged mesh per 4×4 footprint, covers ~600-1000 m).
- FAR grid: octahedral impostor MultiMesh (1000 m-5 km).

Each grid has its own `StreamingSource`-driven activation. A 4×4 HLOD chunk stays resident even when the inner 1×1 cells are NEAR/MID-resident — neighbor 4×4 HLODs don't unload just because the player's own footprint cell goes Full. This is how UE5 reaches 5-10 km draw distance without HLOD memory blowing up.

Key property: **per-cell state machine**, one state per (cell × grid):
```
UNLOADED → HLOD_L2 (4×4 merged) → HLOD_L1 (2×2 merged) → HLOD_L0 (1×1 merged)
                                                         → MID   (per-actor RS instances)
                                                         → FULL  (per-actor Node3Ds)
```

Transitions are driven by `min(dist_from_any_source)` against per-layer thresholds. No per-actor promote / demote dance.

References:
- UE5 HLOD: independent grids per layer, `OnScreenSize` / loading-range metric.
- Our `src/core/world/object_paging.gd` already implements adaptive 1×1 / 2×2 / 4×4 chunk sizes — **this IS the canonical pattern**, just not formalized as explicit HLOD layers.

### 3.4 Per-Cell State Machine

Each cell tracks `current_tier: Tier` and a single atomic transition function `request_tier(cell, new_tier)`. The transition:

1. If currently `UNLOADED` → start async asset parse via WorkerThreadPool. Mark cell `LOADING_<new_tier>`.
2. On parse completion → attach on main thread, budgeted across frames, mark cell `new_tier`.
3. On demote (`new_tier` = lower fidelity) → swap render (free high-tier assets, surface low-tier), no scene-graph rebuild.
4. On promote (`new_tier` = higher fidelity) → reverse of demote.
5. On full unload → queue scene nodes to `UnloadQueue`, drain across frames (UE5 `FStreamableManager` / OpenMW `UnrefQueue` pattern).

Crucially: **the transition function is oblivious to "which objects are in the cell"**. It operates on cell-level render resources (merged meshes for HLOD tiers, prototype RS instances for MID, full scene tree for FULL). Per-object concerns (Data Layers, interior pockets) are filters applied AFTER the cell is resident, not inputs to the transition.

### 3.5 Per-Actor Filtering — Future (Data Layers)

**Not in scope for this refactor.** Documented here so we don't architect it out.

Once cells + sources + HLOD grids work, actors within a resident cell can be filtered by runtime flags:
- `interior_only`: only surface in interior pockets.
- `quest_X_active`: only surface while quest is active.
- `combat_only`: only surface during combat.

UE5 calls this Data Layers. Implementation is a per-actor bitmask + a global "active layers" set, intersected at cell-resident time. 2-3 day add-on once cells + sources are in.

### 3.6 Retained Godot-Native Innovations

User directive: **keep the Godot-native innovations, don't reinvent them.** These survive the refactor unchanged:

- **`RenderingServer.instance_geometry_set_visibility_range`** on each RS instance — hard-cull at the MID→HLOD handoff. Godot's C++ culler does the per-frame distance test; we never read back or poll per-frame in script.
- **Embedded `ArrayMesh.surface_lod_indices` cascade** via `ImporterMesh.generate_lods()` at bake time. Engine C++ picks the right sub-LOD from screen-space coverage + `mesh_lod_threshold` + `lod_bias`. NO manual per-band visibility_range sub-bands.
- **MultiMesh batching via `PrototypeRegistry`** in `static_object_renderer.gd` — single draw call for identical meshes across cells. Canonical Godot pattern.
- **`WorkerThreadPool`** for all async parse/load (NOT `Thread.start()` — CLAUDE.md forbids naked threads).
- **Jolt Physics** for collision. NEAR-tier actors have physics bodies; MID/HLOD/FAR are pure render.
- **Octahedral impostors** at 1-5 km. `NativeImpostorRenderer` stays as-is; UE5 doesn't have built-in impostors either (Nanite replaced the use case), so octahedral impostors are the right far-tier for non-Nanite engines.
- **Jolt `visibility_range` + `visibility_range_fade_mode = VISIBILITY_RANGE_FADE_SELF`** for crossfade between tiers. Engine handles the alpha blend — no custom shader logic in the streaming layer.

---

## 4. Current Code Mapping

What we already have vs. what needs to change.

| Concern | Current state | Target |
|---|---|---|
| Cell grid | `cell_manager.gd` holds `_loaded_cells: Dictionary[Vector2i, Node3D]`. Activation via `_get_cells_in_radius`. | Keep. Generalize activation to `StreamingSource`-driven, replace radius scan with source union. |
| Streaming source | **Implicit** — only the camera, hard-coded in `native_streaming_manager.gd`. | **New.** `src/core/world/streaming_source.gd` as a `Node`-attachable component. Scene maintains a `Array[StreamingSource]`. |
| Per-object distance branch | `cell_manager.gd:1389-1470` — the 4-way branch on `(mid_worthy, beyond_near, always_near)`. | **Delete.** Replace with cell-level tier state. |
| Defer queue | `_deferred_near_refs`, `_defer_for_near`, `process_deferred_near`. | **Delete.** Unnecessary once per-object gating is gone. |
| MID promotion/demotion | `_process_mid_to_near_promotions`, `_promoted_objects`, `promote_mid_to_near`. | **Gate behind `ENABLE_MID_PROMOTION=false` const** during NEAR-only phase. Refactor to per-cell tier transitions later. |
| HLOD chunks | `object_paging.gd` has adaptive 1×1 / 2×2 / 4×4 chunks with cost-benefit merge. | Keep the chunk engine. **Formalize as explicit HLOD layers** (new API: `set_active_for_chunk(layer, chunk_key, active)`). |
| MID RS instances | `static_object_renderer.gd` + `PrototypeRegistry` — MultiMesh batched. | Keep. Expose a `set_cell_tier(cell_grid, tier)` entry point; tier change swaps which RIDs are visible. |
| Impostors | `NativeImpostorRenderer`. | Keep unchanged. |
| Preloader | **Missing.** Current loader is reactive. | **New.** `src/core/world/cell_preloader.gd` with velocity-extrapolated preload + `WorkerThreadPool`. |
| Unload | Inline `queue_free()` on cell exit (plus `_pending_rs_hide_cells` budget path). | **New.** `src/core/world/unload_queue.gd` — budgeted destructor drain. |
| Feature flags | `subsystem_toggles.gd` with per-tier bools. | Keep. Adjust semantics to match new tier system (flags gate the entire HLOD grid, not per-object visibility). |

---

## 5. Refactor Phases

Each phase is small, independently testable, and ends with a measurement (§9). Phases are ordered so the game stays runnable throughout — we never leave `master` in a broken state.

### Phase S.0 — Park non-NEAR tiers + banner

**Goal:** isolate NEAR tier. Boot-time defaults: MID/HLOD/IMPOSTORS off. Does NOT delete tier code — just gates it at the default-flag level.

**Changes:**
- `src/tools/world_explorer.gd` defaults dict (~line 1587): flip `mid_objects`, `hlod`, `impostors` to `false`.
- Console banner on boot: `"[NEAR-only mode] MID/HLOD/IMPOSTORS parked — open_world_streaming refactor in progress"` so the user knows.
- No code deletion yet.

**Acceptance:** `toggle list` on boot shows NEAR + TERRAIN on, everything else off. Scene launches with only NEAR + terrain rendering. No regressions to NEAR behavior (the bugs we're fixing persist — this phase just isolates them).

**Risk:** trivial. Pure default flip.

---

### Phase S.1 — Delete per-object distance gating in cell insert

**Goal:** collapse the 4-way branch in `process_async_instantiation` to one path: every ref in an active cell → Node3D.

**Changes:**
- `cell_manager.gd::process_async_instantiation` (line ~1351): delete Step 1 (mid-worthy branch) and Step 2 (non-mid-worthy beyond-near branch). Keep only Step 3 (full Node3D instantiation).
- Delete: `_defer_for_near`, `_deferred_near_refs`, `_create_near_only_rs_instance`, `process_deferred_near`, `clear_deferred_for_cell`, `get_deferred_near_count`.
- Delete: `_process_deferred_near_instantiation` in `native_streaming_manager.gd`.
- Gate behind `const ENABLE_MID_PROMOTION := false` (top of `native_streaming_manager.gd`): the promotion/demotion loops (`_process_mid_to_near_promotions`, `_promoted_objects`, `_demote_all_promoted`, etc.) — keeps the code readable for when MID comes back, dead-code eliminated by the const.
- Delete `_apply_near_visibility_range` added last session (no longer needed — VR will be driven by per-cell tier, not per-object override).

**Acceptance:**
- `toggle none → toggle terrain → toggle near_objects` + walk anywhere. Every object in every loaded cell appears as a Node3D. No ghost objects beyond 150 m. NEAR Node3Ds cull via the cell's visibility, not per-object VR.
- No compile errors. No runtime warnings about missing `_defer_for_near` callers.
- Measurement: record frame time + loaded-object count before and after.

**Risk:** medium. Removing the defer path surfaces any downstream assumption that MID RS instances exist (e.g. promotion callers). Follow up with compile pass + a quick grep for leftover references.

---

### Phase S.2 — `StreamingSource` abstraction + single-source activation

**Goal:** replace the implicit "camera is the source" with an explicit `StreamingSource` component. Player camera is registered as the first and only source. Cell activation = union over all sources.

**Changes:**
- New class `StreamingSource` in `src/core/world/streaming_source.gd`. Fields: `position`, `velocity`, `active_range`, `preload_range`, `priority`.
- New registry `StreamingSourceRegistry` (singleton-style on `native_streaming_manager` or a dedicated class, doesn't need to be autoload). Methods: `register_source`, `unregister_source`, `get_active_cells() -> Set[Vector2i]`.
- `native_streaming_manager._update_loaded_cells` rewritten: active set = union of per-source cell queries. Hysteresis on per-cell exit: cell drops out when `min_dist_from_source > cell_size/2 + HYSTERESIS`.
- Camera registers itself as the primary source at startup.

**Acceptance:**
- Same runtime behavior as phase S.1 (still one source = camera, so the active cell set is the same).
- Streaming source can be queried + inspected in a debug HUD.
- Code is the multi-source-ready shape without actually using multi-source yet.
- Measurement: cell activation changes per frame (should be 0 in steady state, match phase S.1).

**Risk:** low. Abstraction lift, no behavior change.

---

### Phase S.3 — Per-cell tier state machine (NEAR + UNLOADED only)

**Goal:** introduce the `CellTier` enum + transition function. With MID/HLOD/IMPOSTORS parked, the only transitions are `UNLOADED ↔ FULL`. Gets the state-machine shape in place without implementing lower tiers yet.

**Changes:**
- New enum `CellTier` in `src/core/world/cell_tier.gd`: `{UNLOADED, LOADING_FULL, FULL}`. (Space for `HLOD_L0 / HLOD_L1 / HLOD_L2 / MID` added but unused.)
- `cell_manager` adds `_cell_tier: Dictionary[Vector2i, CellTier]`. Every `_loaded_cells` entry has a tier value.
- `cell_manager.request_cell_tier(grid, target_tier)` — the sole entry point for changing a cell's tier. Calls out to tier-specific subroutines (only `_load_full_cell` / `_unload_cell` exist in this phase).
- `native_streaming_manager._update_loaded_cells` delegates to `cell_manager.request_cell_tier` instead of calling `_queue_cell_load` directly.

**Acceptance:**
- Identical runtime behavior to phase S.2 (only NEAR tier exists, transitions are binary).
- `cell_tier` dictionary is visible in a debug HUD; every loaded cell reads `FULL`.
- Measurement: state-machine overhead must be < 0.1 ms / frame (shouldn't be a hot path at all).

**Risk:** low. Refactor for shape, no behavior change.

---

### Phase S.4 — Velocity-extrapolated preload + `WorkerThreadPool`

**Goal:** warm assets one cell ahead of the player's predicted position so the attach phase sees pre-parsed data. Eliminates the "crested a hill, nothing loaded" symptom.

**Changes:**
- New class `CellPreloader` in `src/core/world/cell_preloader.gd`. Per-frame call: `preload_cells(sources, prediction_time)`.
- Implementation:
  - For each source, compute `predicted_pos = source.position + source.velocity * prediction_time`.
  - Query cells within `preload_range` of predicted_pos.
  - Submit `WorkerThreadPool.add_task` per cell: parse refs from ESM, warm `_model_loader` cache (load `.res` files, unpack materials — NO scene-tree attach on worker thread).
  - Cache resident for `expiry_delay` seconds after last source proximity — if player backtracks, cell is instant-attach.
- Thread-safety: `_model_loader` cache writes behind a `Mutex`; reads are lockless (Godot `Dictionary` reads are safe concurrent with no writes).
- Main-thread attach path (unchanged API) hits warm cache → no parse cost in the attach frame.

**Acceptance:**
- Walk at normal speed — new cells visible the moment they enter active range, no parse hitch.
- Fast traversal (`player.speed = 50`): degraded gracefully (some cells miss the preload window but don't crash).
- Preload budget < 2 ms / frame main thread (worker threads do the heavy lift).
- Cache eviction works: leave a region, return 60 s later, no stale cache.
- Measurement: P95 attach time per cell, pre-vs-post preload.

**Risk:** medium. Thread-safety of `_model_loader`. Needs careful audit of cache write sites.

---

### Phase S.5 — `UnloadQueue` (UnrefQueue-style deferred teardown)

**Goal:** stop the frame hitch from bulk `queue_free()` on cell exit. Drain destructors across frames.

**Changes:**
- New class `UnloadQueue` in `src/core/world/unload_queue.gd`. Per-frame `drain(budget_ms)` processes pending `queue_free()` calls on a FIFO.
- `cell_manager._unload_cell` pushes cell scene nodes to the queue instead of calling `queue_free()` directly.
- Cancellation: if a cell re-activates while its nodes are still in the queue, pull them back out (restore to `_loaded_cells`, update `_cell_tier`).

**Acceptance:**
- Fast traversal on dense cells — no `> 10 ms` frame spikes traceable to unload.
- Backtrack test: walk into a region, walk back 2 cells, return — cells re-activate instantly (no reload).
- Measurement: P99 frame time during traversal, before vs after.

**Risk:** low. Godot's `queue_free` is already deferred; we're just budget-spreading it.

---

### Phase S.6 — NEAR baseline measurement + user sign-off

**Goal:** record perf numbers for NEAR-only mode in §9. User verifies NEAR behavior before any of MID / HLOD / IMPOSTORS comes back.

**Acceptance:** before/after table in §9 for each phase S.0-S.5. User confirms "NEAR is satisfying" in chat. Any outstanding bugs blocked here until resolved.

---

### Phase S.7+ — MID / HLOD / IMPOSTORS (separate plan docs)

Once NEAR is signed off, each re-introduction gets its own plan doc under `docs/plans/distant_rendering_2026_04/`:

- `phase_mid.md` — MID grid re-enable via `request_cell_tier(grid, MID)`. Uses existing `StaticObjectRenderer` + `PrototypeRegistry`. Tier transitions swap cell's RS instances on/off, no per-object promote.
- `phase_hlod.md` — stacked HLOD grids L0/L1/L2. Formalize `object_paging.gd` adaptive chunks as explicit layers with their own `StreamingSource` activation.
- `phase_impostors.md` — re-enable `NativeImpostorRenderer`, connect to the FAR grid.

This doc (the master) coordinates; each sub-phase doc owns its own measurement log.

---

## 6. Godot-Native Innovations — Non-Negotiable

User directive, 2026-04-19: preserve the innovations that got us here. Don't regress to bespoke solutions.

| Innovation | File | Why we keep |
|---|---|---|
| `RenderingServer.instance_geometry_set_visibility_range` | `static_object_renderer.gd:485` | Engine C++ culler does the per-frame distance test. Never poll in script. |
| `ImporterMesh.generate_lods()` at bake time | `src/tools/prebaking/model_prebaker.gd` | Embedded `surface_lod_indices` cascade, engine picks sub-LOD from screen-space coverage. |
| `mesh_lod_threshold` + `lod_bias` tuning | Prebake pipeline | LOD selection tuning without refactoring the render path. |
| `visibility_range_fade_mode = VISIBILITY_RANGE_FADE_SELF` | Applied per GeometryInstance3D | Engine crossfade between tiers, no custom shader. |
| `PrototypeRegistry` MultiMesh batching | `static_object_renderer.gd` + `prototype_registry.gd` | One draw call per unique mesh type across all cells. Canonical Godot pattern. |
| `WorkerThreadPool.add_task` for async parse | `model_loader.gd`, streaming pipeline | Non-`Thread.start()` async. CLAUDE.md rule. |
| Octahedral impostor MultiMesh (FAR tier) | `native_impostor_renderer` (C# + GDScript bridge) | Single draw call for 1-5 km billboards. UE5-equivalent since Godot has no Nanite. |
| Jolt `CollisionShape3D` primitives | NEAR tier Node3Ds | Box/sphere/capsule primitives, never trimesh when primitives fit. |
| Prebaked `.res` with embedded LODs + materials | `src/tools/prebaking/` | 1-5 ms load vs 50-200 ms parse. Single source of truth for asset shape. |

Refactor constraint: **if a phase would remove or regress any of the above, stop and redesign.**

---

## 7. Ground Rules (inherited from parent plan)

From `docs/plans/distant_rendering_2026_04/plan.md §2`:

1. **Only two sources of truth:** code in `src/` + runtime numbers from a live Godot scene. Docs are aspirational. Verify every claim against current code before acting.
2. **Before any change, record a baseline.** Before/after numbers go in §9. A phase without numbers in §9 is NOT done.
3. **Test interactively.** No `--auto-capture`, no scripted camera paths. User pilots the camera.
4. **No kludges, no quick fixes.** Canonical patterns (OpenMW, UE5 World Partition, Godot engine, Fiedler) win over bespoke. See CLAUDE.md "Industry Standard, Never Kludge" + "Simplicity Over Over-Engineering."
5. **Reviewer engages at plan draft + implementation draft boundaries**, not continuously. See CLAUDE.md "Reviewer Engagement Scope."
6. **Strict typing** in `src/core/` for all params, returns, vars.
7. **`Log.info/debug/warn/error`** instead of `print`. Category matches subsystem (`streaming`, `tier`, `preload`).

---

## 8. Open Questions

Need user answers before coding phase S.0.

1. **Cell activation range per source.** OpenMW uses 3×3 cells (1-cell radius). UE5 default is 256 m loading range (~2 cells at our size). Propose: `active_range = 2 cells = 234 m` for the player source. Acceptable?
2. **Hysteresis margin.** OpenMW uses `1024 units / 70 = ~14 m` past cell boundary. Propose: `HYSTERESIS_MARGIN = 15 m`. OK?
3. **Preload prediction time.** UE5 exposes as setting, OpenMW uses ~1 s. Propose: `prediction_time = 0.5 s` (at 5 m/s walk = 2.5 m, at 20 m/s run = 10 m). OK?
4. **Preload cache eviction.** `expiry_delay = 60 s`, `max_cache_size = 64 cells`. Placeholders — we'll tune against runtime numbers. OK to start here?
5. **Single `StreamingSource` abstraction vs. separate source types?** I can either have one class with a range dict `{near: 234m, mid: 600m, hlod: 1000m, far: 5000m}`, or specialized subclasses (`PlayerSource`, `CinematicSource`). Single class is simpler; UE5 uses one class with priority. Single class OK?
6. **Parked tier code: gate with `const ENABLE_MID_PROMOTION := false` or delete and git-restore later?** Gating keeps the file readable when the tier comes back; deletion is cleaner. User preference?
7. **Where does `StreamingSource` live in the scene tree?** Proposal: the camera rig auto-registers. For tests / scripted scenes, code can register manually via `StreamingSourceRegistry.register_source(source)`. OK?

---

## 9. Measurement Log

Record before/after for each phase. Canonical metrics:

| Phase | Metric | Before | After | Notes |
|---|---|---|---|---|
| S.0 | FPS steady state, Seyda Neen dock | TBD | TBD | Only NEAR + terrain active |
| S.0 | Draw calls | TBD | TBD | |
| S.0 | `loaded` cell count | TBD | TBD | |
| S.1 | P95 instantiation budget | TBD | TBD | Per-frame `process_async_instantiation` time |
| S.1 | NEAR ring fill test | fail | pass | `toggle none → terrain → near_objects` + walk: circle follows camera |
| S.2 | Source-query cost per frame | N/A | TBD | New metric |
| S.3 | Tier state machine overhead | N/A | TBD | `request_cell_tier` call cost |
| S.4 | P95 cell attach time, preload-warm | TBD | TBD | Cold cache vs warm cache |
| S.4 | P99 frame spike during fast traversal | TBD | TBD | |
| S.5 | P99 frame spike during unload | TBD | TBD | Bulk unload vs budgeted |
| S.6 | NEAR baseline complete | — | — | User sign-off |

---

## 10. Review Checklist (for user)

- [ ] Non-Goals (§1) correctly scope the work.
- [ ] Problem Statement (§2) matches observed symptoms.
- [ ] Target Architecture (§3) reflects modern AAA patterns, not a Morrowind-specific idiom.
- [ ] Current Code Mapping (§4) correctly identifies what to keep, delete, gate, add.
- [ ] Phase ordering (§5) — park → delete per-object → abstract source → state machine → preload → unload queue → baseline.
- [ ] Godot-Native Innovations (§6) — confirm the list is complete; anything missing I should preserve?
- [ ] Open Questions (§8) — answer before coding S.0.
