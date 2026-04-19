# Open-World Streaming Architecture — Godotwind 2026-04-19

**Status:** DRAFT v2 — patched 2026-04-19 after coder review. User authorized doc patch + NEAR-only scope. No code changes authorized yet.
**Paired with:** `docs/plans/distant_rendering_2026_04/plan.md` (parent distant-rendering work log, inherits its §2 ground rules; PHASE 0 baseline must run BEFORE this doc's S.0).
**Supersedes:** the earlier "ring-based tier" sketch in revisions of this file prior to 2026-04-19.

Godotwind is a **generic open-world RPG framework**, not a Morrowind-specific streamer. The architecture must therefore reflect **modern AAA streaming patterns**, not legacy Bethesda cell-grid idioms. Morrowind data is one adapter on top; the core streaming layer should look like what a team at Epic / Guerrilla / CDPR would build in 2026.

---

## 0. Session Resume Pointer

Read in this order:
1. §1 — Non-Goals (scope).
2. §2 — Problem Statement (why we're here).
3. §3 — Target Architecture (the shape we're building toward).
4. §4 — Current Code Mapping (what we already have; what needs to change).
5. §4.5 — Salvage Strategy (KEEP / DELETE / REWRITE — what survives the refactor).
6. §5 — Refactor Phases. Pick the first phase with status `TODO`.
7. §6 — Godot-Native Innovations to preserve. Non-negotiable.
8. §7 — Ground Rules (inherited from parent plan).
9. §8 — Open Questions (user answers locked 2026-04-19, see §8.1).

**User-locked acceptance criterion (2026-04-19):**
> "When launching the game, only NEAR loads. When I move: circle of meshes follows my steps neatly, and unloads where I left."

This is the S.6 sign-off gate. Every phase S.0-S.5 must preserve or improve toward this behavior. NO MID / HLOD / IMPOSTOR work until the user signs off on this in chat.

**Hard prerequisite:** parent `plan.md` PHASE 0 (baseline measurement on `Godotwind.tscn` with `bench`) MUST be run BEFORE this doc's S.0 starts. Without baseline numbers in parent §4, none of S.0-S.6 have a measurable acceptance gate.

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
- **Player-cell pin (OpenMW invariant).** The cell that contains the player position (`mCurrentCell`) NEVER unloads regardless of the distance formula. At cell size 117 m, half is 58 m; with a 15 m hysteresis margin, naive math allows the player's own cell to drop when the camera sits near a corner. Explicit guard in `cell_manager`: `if cell_grid == _current_player_cell_grid: do not unload`.
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
- Our `src/core/world/object_paging.gd` already implements adaptive 1×1 / 2×2 / 4×4 chunk sizes — **closest Godot equivalent of UE5 World Composition's runtime merger, NOT UE5 HLOD layers proper.** UE5 HLOD layers are authored bake-time meshes referenced by GUID; our merger thread-builds at runtime from prototype data. The two patterns reach the same end (one draw call per chunk footprint) via different paths. Plan keeps the runtime-merger implementation; only the activation API formalizes as "HLOD-style layers" so the FSM can drive it.

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

## 4.5 Salvage Strategy — KEEP / DELETE / REWRITE

User asked 2026-04-19: "we have done a few things since master that might be useful, can't just revert." Correct. Branch has real wins. Salvage > revert.

### KEEP (survives refactor unchanged or near-unchanged)
| File / system | Why it stays |
|---|---|
| `prototype_registry.gd` (450 lines) + `prototype_batch.gd` (440 lines) | World-scoped MultiMesh batching IS the canonical Godot MID pattern. Becomes the implementation under `request_cell_tier(grid, MID)` in S.7. |
| `object_paging.gd` (998 lines) | Runtime chunk merger. Re-frames as HLOD layer impl in S.7. Code stays, semantics tighten. |
| `streaming_benchmark.gd` + `benchmark_hud.gd` + `subsystem_toggles.gd` | Non-negotiable. The acceptance-gate harness for every phase. |
| Phase 8 loading state machine (`85018f9` cold-boot + teleport gate) | Composes cleanly with per-cell FSM. Becomes the global state above the per-cell layer. |
| Async impostor texture-array rebuild (`387ac49`) | Standalone win. |
| `WorldMidCuller.cs` C# cull kernel (`b35cd1c`) | Standalone win, used by registry path. |
| `distance_utils.gd` centralized constants | Single source of truth for ranges. |
| ESM grid-indexed cell lookup (`ESMManager.get_cell_by_grid`) | Independent of streaming layer. |
| `native_impostor_renderer.gd` | FAR tier stays as-is per §1 Non-Goals. |
| Audit docs + `STATUS.md` + `docs/audit/` salvage pass | Reference material. |

### DELETE (the actual debt — this is what's been broken)
| Code | File | Reason |
|---|---|---|
| Per-object 4-way `(mid_worthy, beyond_near, always_near)` branch | `cell_manager.gd:1389-1470` | Wrong axis of variation. Replaced by per-cell tier. |
| `_defer_for_near` + `_deferred_near_refs` + `_create_near_only_rs_instance` + `process_deferred_near` + `clear_deferred_for_cell` + `get_deferred_near_count` | `cell_manager.gd` | Defer queue exists ONLY because per-object gating exists. |
| `_process_deferred_near_instantiation` | `native_streaming_manager.gd` | Same. |
| `_process_mid_to_near_promotions` + `_promoted_objects` + `_demote_all_promoted` + `promote_mid_to_near` | `native_streaming_manager.gd` | Per-actor promote/demote dance. Replaced by cell-level tier swap. |
| `_apply_near_visibility_range` per-object override | `cell_manager.gd` | VR will be driven by per-cell tier, not per-object override. |
| `lod_configurator.gd` | already removed in current branch | — |

### REWRITE (against new FSM, NOT delete + re-add later)
| Concern | Current shape | Target shape |
|---|---|---|
| Cell activation loop | `native_streaming_manager._update_loaded_cells` walks a fixed radius around camera | `StreamingSourceRegistry.get_active_cells()` — union over all sources, returns Set[Vector2i] |
| Cell load entry point | `_queue_cell_load(grid, ...)` | `cell_manager.request_cell_tier(grid, target_tier)` — single atomic transition function |
| AABB-upgrade decision | runtime check at `cell_manager.gd:1414-1418` | moved to prebake (`model_prebaker.gd`) so the prototype's `mid_worthy` flag is correct from disk; no runtime upgrade needed |
| `_model_loader` cache write/read | informal — write under no lock, read under no lock | `RWMutex` (`Mutex` for writes; reads acquire shared) OR double-buffered immutable snapshot. Audit every cache site. |

### HONEST ACCOUNTING
- Net code AFTER refactor will sit between current branch and master.
- Most of the 5,497 line `src/core/world/` insertion since master is debt the per-object branch dragged with it (defer queue, promotion, AABB upgrade, etc.). That goes.
- The genuine wins (registry/batch/paging/bench/Phase 8) — ~2,400 lines — survive.
- Expect ~-2,500 to -3,000 net lines vs current branch after S.6, with NEAR ring actually working.

---

## 5. Refactor Phases

Each phase is small, independently testable, and ends with a measurement (§9). Phases are ordered so the game stays runnable throughout — we never leave `master` in a broken state.

### Phase S.0 — Park non-NEAR tiers + banner — STATUS: DONE 2026-04-19 (commit `0a35ca6`)

**Goal:** isolate NEAR tier. Boot-time defaults: MID/HLOD/IMPOSTORS off. Does NOT delete tier code — just gates it at the default-flag level.

**Prerequisite:** parent `plan.md` PHASE 0 baseline run. §9 §4.1 numbers exist before S.0 starts.

**Changes:**
- `src/tools/world_explorer.gd` defaults dict (~line 1587): flip `mid_objects`, `hlod`, `impostors` to `false`.
- Console banner on boot: `"[NEAR-only mode] MID/HLOD/IMPOSTORS parked — open_world_streaming refactor in progress"` so the user knows.
- No code deletion yet.

**Acceptance:**
- `toggle list` on boot shows NEAR + TERRAIN on, everything else off.
- Scene launches with only NEAR + terrain rendering.
- User-locked behavior gate (the bug-of-record from §2 — these still fail at S.0; they pass at S.6):
  - Launch `Godotwind.tscn`, walk in any direction.
  - Only NEAR objects appear (no MID RS instances, no HLOD chunks, no impostors).
  - Per the user's 2026-04-19 acceptance: "circle of meshes follows my steps neatly, and unloads where I left." S.0 alone does NOT pass this — phase exists to isolate the failure for S.1+ to fix.
- Measurement (§9): FPS, draw calls, `rendered_objects` count at Seyda Neen dock with NEAR + TERRAIN only.

**Risk:** trivial. Pure default flip.

---

### Phase S.1 — Delete per-object distance gating in cell insert — STATUS: DONE-WITH-KNOWN-ISSUES 2026-04-19 (commits `d979373`, `6a63eac`, `095c8f8`)

**Goal:** collapse the 4-way branch in `process_async_instantiation` to one path: every ref in an active cell → Node3D.

**Changes:**
- `cell_manager.gd::process_async_instantiation` (line ~1351): delete Step 1 (mid-worthy branch) and Step 2 (non-mid-worthy beyond-near branch). Keep only Step 3 (full Node3D instantiation).
- Delete: `_defer_for_near`, `_deferred_near_refs`, `_create_near_only_rs_instance`, `process_deferred_near`, `clear_deferred_for_cell`, `get_deferred_near_count`.
- Delete: `_process_deferred_near_instantiation` in `native_streaming_manager.gd`.
- **Delete (don't const-gate)** the promotion/demotion loops in `native_streaming_manager.gd`: `_process_mid_to_near_promotions`, `_promoted_objects`, `_demote_all_promoted`, `promote_mid_to_near`. CLAUDE.md Simplicity rule: replace, don't extend bad architecture. When MID comes back in S.7 it will be driven by `request_cell_tier(grid, MID)`, not per-actor promote. Git restores the deleted code if a reference is needed.
- **KEEP `_apply_near_visibility_range`** (updated 2026-04-19 post-launch). Earlier plan revision said "delete entirely — VR will be driven by per-cell tier in S.7+." That was wrong on two counts: (1) baked NIF VR is 0-500m (stale legacy MID artifact, narrowed to 0-300m post-refactor but NIFs not rebaked yet), and (2) even after S.7 brings MID back, NEAR Node3Ds should STILL cull at NEAR_END — MID RS instances cover 150m+ via `RenderingServer.instance_geometry_set_visibility_range` at add-time, which is orthogonal to Node3D VR. The override is the canonical NEAR-tier visibility contract; it stays permanently. 11-line function, micro-second cost per spawn. Deleting it in the initial S.1 pass regressed mid-load FPS 206 → 35 because Node3Ds in cells 150-350m from camera were drawing at full cost with no MID offload. Restored in follow-up commit `6a63eac`, FPS recovered to 89-92 @ mid-load.
- **AABB upgrade orphan fix (gap #1).** Current `cell_manager.gd:1414-1418` runtime-upgrades non-mid-worthy objects with AABB max-dim > 2 m. Pre-classifier is broken because it sees only the path. **Move the AABB upgrade decision into the prebake pipeline** (`src/tools/prebaking/model_prebaker.gd`) so the prototype's `mid_worthy` flag is correct from disk. One-time prebake re-run regenerates `.res` files with the corrected flag. After this, runtime upgrade is deleted; `mid_worthy` is read from disk and trusted. (S.1's deletion of Step 1 makes the runtime upgrade unreachable anyway during NEAR-only mode, but the prebake fix is required before S.7's MID re-enable.)

**Acceptance:**
- `toggle none → toggle terrain → toggle near_objects` + walk anywhere. Every object in every loaded cell appears as a Node3D. No ghost objects beyond 150 m. NEAR Node3Ds cull via the cell's visibility, not per-object VR.
- **User-locked NEAR criterion (2026-04-19):** "circle of meshes follows my steps neatly, and unloads where I left." S.1 should already approach this — defer queue is gone, every active-cell ref is a Node3D. Residual unload glitches expected, fixed in S.5.
- No compile errors. No runtime warnings about missing `_defer_for_near` callers.
- `git grep` returns 0 hits for: `_defer_for_near|_deferred_near_refs|_create_near_only_rs_instance|process_deferred_near|_process_mid_to_near_promotions|_promoted_objects|_demote_all_promoted|promote_mid_to_near|_apply_near_visibility_range`.
- Measurement (§9): record frame time + loaded-object count + per-frame `process_async_instantiation` time before vs after.

**Risk:** medium. Removing the defer path + promotion loops surfaces any downstream assumption that MID RS instances exist. Follow up with compile pass + grep for leftover references. Likely 5-10 cleanup edits in adjacent files.

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

**Hard prerequisite:** the `model_loader` instantiate-race noted in commit `5c1bc88` ("disable auto-trigger pending model_loader instantiate-race fix") must be resolved BEFORE S.4 ships, OR S.4 fixes it as part of the cache thread-safety work below. Worker-thread preload warm WILL amplify the existing race if not addressed. Block S.4 acceptance until race is closed.

**Changes:**
- New class `CellPreloader` in `src/core/world/cell_preloader.gd`. Per-frame call: `preload_cells(sources, prediction_time)`.
- Implementation:
  - For each source, compute `predicted_pos = source.position + source.velocity * prediction_time`. `prediction_time` is **velocity-scaled**: `clamp(k_distance / max(speed, 1.0), 0.3, 1.5)` seconds — short look-ahead for slow walk, longer for fast traversal. Default `k_distance = 5 m`.
  - Query cells within `preload_range` of predicted_pos.
  - Submit `WorkerThreadPool.add_task` per cell: parse refs from ESM, warm `_model_loader` cache (load `.res` files, unpack materials — NO scene-tree attach on worker thread, NO `instantiate()` from worker thread per CLAUDE.md anti-pattern list).
  - Cache resident for `expiry_delay` seconds after last source proximity — if player backtracks, cell is instant-attach.
- **Thread-safety (gap #3 — corrected from prior draft).** Earlier draft claimed "Godot `Dictionary` reads are safe concurrent with no writes." That is NOT a documented Godot guarantee — `Variant` copies on read mutate refcount on shared objects. Use **one of:**
  - **Option A (preferred): `Mutex` on every read AND write site of the cache.** Simple, safe, lock contention is negligible for the read-mostly workload (cells parse once, get read N times during attach). Audit every call site of `_model_loader` cache reads — they ALL acquire the mutex.
  - **Option B (faster, more code): double-buffered immutable snapshot.** Worker writes into a "next" dictionary; on completion atomically swaps (`atomic_exchange` on the `Object` pointer / via Godot's `Mutex` + pointer swap). Readers always see a consistent snapshot. Requires ~50 extra lines + careful ownership.
  - **Pick A unless A measures > 0.5 ms/frame in profiling.** Premature optimization otherwise.
- Main-thread attach path (unchanged API) hits warm cache → no parse cost in the attach frame.

**Acceptance:**
- Walk at normal speed — new cells visible the moment they enter active range, no parse hitch.
- Fast traversal (`player.speed = 50`): degraded gracefully (some cells miss the preload window but don't crash).
- Preload budget < 2 ms / frame main thread (worker threads do the heavy lift).
- Cache eviction works: leave a region, return 60 s later, no stale cache.
- **Stress test:** 5-minute looped flyby with `bench`. No sig11 or `model_loader` race assert. Closes commit `5c1bc88`'s open race.
- Measurement: P95 attach time per cell, pre-vs-post preload.

**Risk:** medium-high. Thread-safety of `_model_loader` is the biggest open risk in the entire refactor. Audit every cache write AND read site. Add a debug assert (`# debug-only Mutex.try_lock() / unlock()` pair) that the lock is held during cache mutations during early phases.

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

**Acceptance — user-locked 2026-04-19:**
> "When launching the game, only NEAR loads. When I move: circle of meshes follows my steps neatly, and unloads where I left."

Concrete pass criteria (must ALL hold during interactive user pilot):
1. Boot `Godotwind.tscn`. Wait for streaming settle (HUD `rendered_objects` flat). Only NEAR objects + terrain visible. No ghost MID RS instances. No HLOD chunks. No impostors.
2. Walk in any direction at default speed for 30 s. Visible NEAR set forms a clean disc / band around the player position; new objects enter on the leading edge as the player moves into them.
3. Turn around, walk back. Cells re-activate from cache (fast path); no parse hitch.
4. Walk past the cells, keep going. Cells behind the player unload after `cell_size/2 + HYSTERESIS` of distance crossed. NO orphan objects left in world. NO ghost RS instances visible past the unload boundary.
5. Sprint (`player.speed = 50`) for 60 s along a straight line. Preload keeps up; no "crested a hill, nothing loaded" symptom.
6. `bench` run at Seyda Neen dock. Frame time stable. No frame spikes > 25 ms (NEAR-only baseline; we're not at 140 FPS target yet — that requires MID/HLOD/IMPOSTOR re-enable in S.7+).
7. Before/after table in §9 fully populated for S.0-S.5.
8. User confirms in chat: "NEAR is satisfying" or equivalent. Until that message lands, S.7+ is blocked.

Any outstanding bug → re-open whichever phase introduced it. Don't paper over in S.6.

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

### 8.1 Locked 2026-04-19 (user answers via coder review)

1. **Cell activation range per source.** `active_range = 2 cells = 234 m` for the player source. (OpenMW 3×3 / UE5 256 m equivalents.) **LOCKED.**
2. **Hysteresis margin.** `HYSTERESIS_MARGIN = 15 m` past cell boundary. **LOCKED.** Plus player-cell pin per §3.1.
3. **Preload prediction time.** Velocity-scaled: `clamp(5.0 / max(speed, 1.0), 0.3, 1.5)` seconds. **LOCKED.** Replaces fixed 0.5 s.
4. **Preload cache eviction.** `expiry_delay = 60 s`, `max_cache_size = 128 cells`. **LOCKED.** (128 not 64 — backtrack support.) Tune against §9 numbers.
5. **Single `StreamingSource` abstraction.** Single class with range dict + priority. UE5-style. **LOCKED.**
6. **Parked tier code.** **DELETE, don't const-gate.** CLAUDE.md Simplicity rule. Git restores if needed. **LOCKED.**
7. **`StreamingSource` scene-tree placement.** Camera rig auto-registers as primary source. Tests / scripted scenes register manually via `StreamingSourceRegistry.register_source(source)`. **LOCKED.**

### 8.2 Still open (need answers if/when phase reaches them)

8. **`model_loader` race.** Is the race in `5c1bc88` already mapped (which files / which functions race)? If not, a discovery sub-task is needed before S.4. Coder can investigate or user can drop a known-bad case in chat.
9. **Cell-cache memory ceiling.** 128 cells × ~1-3 MB prototype data = ~128-384 MB. Acceptable? Or should we cap at total bytes instead of cell count?
10. **AABB upgrade prebake re-run.** Moving the AABB-upgrade decision to prebake (S.1 fix) requires regenerating prototype `.res` files. Is the prebake pipeline idempotent + fast enough to re-run without disrupting other work, or does this need its own scheduled session?

---

## 9. Measurement Log

Record before/after for each phase. Canonical metrics:

| Phase | Metric | Before | After | Notes |
|---|---|---|---|---|
| S.0 | FPS steady state, Seyda Neen dock | — | 206 | NEAR + terrain only, `reg_slots=0`, `imp_pending=0` — MID/HLOD/IMPOSTORS truly off |
| S.0 | Draw calls | — | 2593 | heartbeat sec=64 |
| S.0 | `loaded` cell count | — | 117 | radius 3 = 7×7 grid = 49 cells in steady, more during traversal |
| S.0 | Objects rendered | — | 5134 | |
| S.0 | Primitives | — | 590k | |
| S.1 | NEAR ring fill test | fail | pass | User walked + confirmed "NEAR seems to be working correctly now. Nothing seems rendering past the NEAR" |
| S.1 | Per-cell Node3D count (Seyda Neen `(-1,-9)`) | 45 | 123 | ~3× — confirms every-ref-is-Node3D rule works |
| S.1 (broken draft) | FPS mid-load | — | 35 | VR override accidentally deleted → 500m prebaked VR leaked |
| S.1 (VR fix, commit `6a63eac`) | FPS mid-load | 35 | 89-92 | `_apply_near_visibility_range` restored |
| S.1 (steady state, user walk) | FPS | — | **50-60** | **Regression vs S.0's 206** — see §12 Known Issues |
| S.2 | Source-query cost per frame | N/A | TBD | |
| S.3 | Tier state machine overhead | N/A | TBD | |
| S.4 | P95 cell attach time, preload-warm | TBD | TBD | |
| S.4 | P99 frame spike during fast traversal | TBD | TBD | |
| S.5 | P99 frame spike during unload | TBD | TBD | |
| S.6 | NEAR baseline complete | — | — | Blocked: FPS regression + second crash site (see §12) |

---

## 10. Review Checklist (for user)

- [x] Non-Goals (§1) correctly scope the work.
- [x] Problem Statement (§2) matches observed symptoms.
- [x] Target Architecture (§3) reflects modern AAA patterns, not a Morrowind-specific idiom.
- [x] Current Code Mapping (§4) correctly identifies what to keep, delete, gate, add.
- [x] Salvage Strategy (§4.5) — KEEP / DELETE / REWRITE tables explicit. Honest accounting of net line count.
- [x] Phase ordering (§5) — park → delete per-object → abstract source → state machine → preload → unload queue → baseline.
- [x] Godot-Native Innovations (§6) — list confirmed.
- [x] Open Questions (§8.1) — locked by user 2026-04-19.
- [ ] Parent `plan.md` PHASE 0 baseline run — gate before S.0.
- [ ] User-locked NEAR acceptance criterion (§0 + §S.6) — sign-off blocks S.7+.

---

## 11. Patch Log

- **v3 (2026-04-19, post-S.1 launch):** S.0 + S.1 marked DONE with commit refs. §9 populated with real numbers. Added §12 Known Issues (corrupt `.res`, second crash site, FPS regression root cause). Added §13 Next-Session Pickup. S.1 acceptance confirmed by user interactive walk: "NEAR seems to be working correctly now. Nothing seems rendering past the NEAR." But FPS regressed 206 → 50-60 due to architectural hole: 49 cells × ~150-250 refs each = ~10k Node3Ds with Jolt bodies, all ticking every frame, for content that VR-culls past 155m. Per-ref distance gate (Option A) proposed but not implemented — user paused session.
- **v2 (2026-04-19, post-coder-review):** added §0 user-locked acceptance criterion + parent PHASE 0 prerequisite. Added §3.1 player-cell pin (OpenMW invariant). Added §4.5 Salvage Strategy with KEEP/DELETE/REWRITE tables. S.0 acceptance now lists explicit launch-and-walk gate. S.1 deletes promotion code (not const-gate per CLAUDE.md Simplicity), adds AABB-upgrade prebake fix. S.3 §3.3 honest about `object_paging.gd` ≠ UE5 HLOD layers (it's UE5 World Composition runtime merger). S.4 thread-safety claim corrected — `Mutex` required, "lockless dictionary read" claim was wrong; added `model_loader` race prerequisite from commit `5c1bc88`. S.4 prediction time velocity-scaled. S.6 acceptance binds user's launch-and-walk gate as the sign-off contract. §8.1 questions locked. §8.2 holds 3 still-open items for later phases.
- **v1 (2026-04-19):** initial DRAFT. Superseded the prior ring-based sketch.

---

## 12. Known Issues (post-S.1)

### 12.1 Corrupt `.res` cache file — `f_terrain_rock_bc_11_nif.res`

**Symptom:** `PackedScene.instantiate()` on this specific `.res` reliably SIGSEGVs ~57s into any session (the time it takes for a cell containing this rock to stream in). Native-level crash, no GDScript backtrace in release builds.

**Proof:** breadcrumb diagnostic (`src/core/logging/crash_breadcrumb.gd`) caught the exact file. `instantiate_begin :: f_terrain_rock_bc_11_nif.res` recorded with no matching `instantiate_end` = crash occurred inside `packed_scene.instantiate()`.

**Status:** QUARANTINED 2026-04-19. File renamed to `.crashtest` suffix in `C:/Users/metzo/Documents/Godotwind/cache/models/`. Game survives 3× longer after quarantine. Proper fix: rebake JUST this file via the prebake pipeline (user said rebake takes a few minutes). Or: full cache rebake + hash validation so corrupt files are regenerated automatically at boot.

**Why it's corrupt:** unknown. All 4884 `.res` files in cache are dated `Apr 19` (today's rebake), so not a stale file. File size matches siblings (360215 bytes, same as `bc_02`). Either:
(a) prebake pipeline occasionally produces a malformed subresource reference (rare, non-deterministic)
(b) NIF source has something the converter handles incorrectly for `_bc_11` specifically
(c) filesystem corruption during the Apr 19 rebake pass

Next-session action: rebake + hash-validate. If it corrupts again, investigate the `nif_converter.gd` path for `bc_11` specifically.

### 12.2 Second crash site at sec=~183 — outside `_instantiate_from_scene`

**Symptom:** after quarantining `bc_11`, a second SIGSEGV fires ~180-185s into session, only when game runs unattended under heavy streaming. User's interactive walk completed without hitting it.

**Breadcrumb signature:** last successful breadcrumb = `instantiate_return :: f_terrain_rock_ai_12_nif.res` (or `f_flora_muckspunge_06_nif.res` on other runs) — meaning `_instantiate_from_scene` completed FULLY for that file. Crash happens AFTER that, in an uninstrumented code path.

**Suspect list (un-instrumented hazards):**
- `reference_instantiator.gd::_instantiate_model_object` — `_enable_collision_shapes_in_tree` for NEAR refs, `_hide_lod_nodes`, `_apply_transform`, carryable conversion at line 315.
- `cell_manager.gd::process_async_instantiation` — batch `add_child` / `queue_free` loop.
- `native_streaming_manager._process_budgeted_unloading` — `queue_free` on children with disabled Jolt bodies still registered in broadphase. Rapid unload churn (13+ cells/2s during fast player movement) is a known trigger.
- Jolt broadphase corruption from concurrent body register/unregister.

**Next-session action:** extend breadcrumbs into the above paths. Run until crash, read last breadcrumb, narrow down. Probably one more diagnostic pass before root cause is visible.

### 12.3 FPS regression — S.0's 206 FPS → S.1's 50-60 FPS

**Root cause (identified, not fixed):** S.1's architectural rule "every ref in a resident cell becomes a Node3D" created a hidden cost. Per-frame math:
- Cell = 117m × 117m (`CELL_SIZE_GODOT`)
- `load_radius_cells = 3` → `_get_cells_in_radius` returns 49 cells (7×7 grid)
- Each cell contains 150-250 refs after mid-range Morrowind content (Seyda Neen region)
- ~10,000 Node3Ds in steady state, **all with Jolt StaticBody3D + CollisionShape3D children** (collision `disabled = true` for refs beyond NEAR, but the BODIES are still registered in Jolt broadphase)
- Jolt ticks ~10k bodies per physics frame = 600k body-ops/sec at 60Hz

S.0 was 206 FPS because MID-tier refs (80% of cell content) were **RS instances** (single RID, zero physics, zero scene-tree processing). Only NEAR Node3Ds had bodies. Total bodies: ~5k not ~10k. **S.0 had fewer bodies than S.1 currently does.**

**Fix (proposed, not shipped) — Option A:** per-ref distance gate at instantiation time. `if ref.position.distance_to(camera) > NEAR_END + hysteresis: skip spawn`. Deferred refs stay in the instantiation queue; when camera approaches, they spawn. Pure distance check, no tier classification (NOT a revert to the S.0 4-way branch). Forward-compatible with S.7: the gate extends to "close enough for Node3D, else spawn RS instance" once MID returns.

**Why Option A works without compromising radius:** user vetoed reducing `load_radius_cells` 3 → 2. Option A keeps radius at 3 (cells still LOAD out to 351m) but stops creating physics-body Node3Ds for refs the player can't interact with. Matches the plan's §3.1 intent that "attach is incremental across frames" — Option A makes attach distance-aware rather than all-or-nothing.

**Alternative — Option C:** dynamic Jolt body unregister (keep every Node3D, detach StaticBody3D from Jolt when >NEAR_END). More complex, introduces physics state lifecycle bugs.

### 12.4 `_apply_near_visibility_range` is PERMANENT, not time-boxed

Updated in v2 patch: the NEAR Node3D VR override (`_apply_near_visibility_range` in `cell_manager.gd`) stays forever. Prebaked NIFs carry 0-500m VR (stale MID-tier artifact); NEAR Node3Ds MUST cull at NEAR_END. MID RS instances (S.7+) get their own VR via `RenderingServer.instance_geometry_set_visibility_range` at add-time — orthogonal to Node3D VR. Initial S.1 draft deleted the override per plan; restored in commit `6a63eac` after launch revealed the regression.

---

## 13. Next-Session Pickup

**Priorities in order:**

1. **Implement Option A (per-ref distance gate).** Expected to recover most of the S.0 FPS. In `cell_manager.process_async_instantiation` add a distance check before the Node3D spawn path. If ref is beyond `NEAR_END + hysteresis`, skip — leave entry in the instantiation queue for a future frame when camera is closer. Re-process the queue on camera cell change. Acceptance: Seyda Neen dock FPS back to >150, Node3D count drops from ~10k to ~3-5k.

2. **Rebake `f_terrain_rock_bc_11_nif.res`.** Delete from cache, trigger re-prebake. If it corrupts again, investigate `nif_converter.gd` for the specific NIF. User said rebake is a few minutes. Un-quarantine the `.crashtest` file once rebake succeeds.

3. **Extend breadcrumbs to find second crash site.** Add write calls in:
   - `reference_instantiator._instantiate_model_object` — before/after `_enable_collision_shapes_in_tree`, `_apply_transform`, carryable conversion
   - `cell_manager.process_async_instantiation` — before batch `add_child`
   - `native_streaming_manager._process_budgeted_unloading` — already has `unload_child` but consider per-`queue_free` granularity

4. **Once both crashes are fixed**, remove `CrashBreadcrumb` calls (keep the utility file — cheap insurance for future diagnostics). Commit message should explicitly remove the overhead.

5. **Then resume S.2 / S.3** (StreamingSource + per-cell FSM). The FSM is the proper long-term home for tier-based distance gating; Option A is a compatible scaffold.

**Code state pointers for next agent:**
- `src/core/logging/crash_breadcrumb.gd` — the diagnostic utility, 35 lines, static functions
- `src/core/world/model_loader.gd:_instantiate_from_scene` — 4 breadcrumb calls installed
- `src/core/world/native_streaming_manager.gd:_unload_cell` + `_process_budgeted_unloading` — 3 breadcrumb calls installed
- Quarantined file: `C:/Users/metzo/Documents/Godotwind/cache/models/f_terrain_rock_bc_11_nif.res.crashtest` — verify before rebake
- Commits: `0a35ca6` (S.0), `d979373` (S.1), `6a63eac` (VR fix), `095c8f8` (doc correction), `3d1eabd` (breadcrumb diagnostic)

**DO NOT:**
- Revert the VR override deletion. Override stays; it's correct NEAR-tier behavior (see §12.4).
- Re-introduce the per-object tier-classification branch. Per-ref DISTANCE gate only, no `mid_worthy` / `always_near` classification.
- Reduce `load_radius_cells` below 3 to work around FPS — user vetoed.
