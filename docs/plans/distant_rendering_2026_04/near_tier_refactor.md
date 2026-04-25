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

1. **Cell activation range per source.** `active_range = 1 cell = 117 m` for the player source → 3×3 grid = 9 cells total. Matches OpenMW `exterior cell load distance=1` default AND the visible NEAR footprint (CELL=117m, NEAR_END≈150m → 3×3 is exactly what's on screen). **LOCKED 2026-04-19 (v4, overrides prior "2 cells" lock).** Prior 2-cell lock was never measured — S.1 ran at radius=3 (legacy default) and regressed FPS 206→50-60 because 49 loaded cells × ~200 refs ≈ 10k Node3Ds/Jolt bodies for content that isn't rendered anyway.
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
| S.1b (v4 `load_radius_cells` 3→1) | FPS steady state | 50-60 | TBD | Seyda Neen dock, 9-cell footprint |
| S.1b | `loaded` cell count | 49 (radius=3) | TBD | expect 9 steady, ≤12 during traversal |
| S.1b | Node3D count | ~10k | TBD | expect ~1.5-2k |
| S.1b | Draw calls | TBD | TBD | |
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

- **v4 (2026-04-19, post-user-pilot 2):** user observation — 49 cells loaded but only 9 visible on screen. Root cause of the S.0 → S.1 FPS regression NOT the per-object gate deletion; it was `load_radius_cells = 3` (= 7×7 = 49 cells) inherited default that S.0 masked via MID RS instances. §8.1 item #1 relocked 2 → 1 cells (3×3 grid = 9 cells, matches OpenMW default + matches visible NEAR footprint). §12.3 rewritten: Option A / Option C abandoned; `load_radius_cells` default change shipped instead. §13 pickup #1 replaced with DONE entry pointing to this patch.
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

**Root cause (identified + FIX SHIPPED v4 2026-04-19):** S.1's architectural rule "every ref in a resident cell becomes a Node3D" × wrong `load_radius_cells` = 5.4× waste. Math:
- Cell = 117m × 117m (`CELL_SIZE_GODOT`), NEAR_END ≈ 150 m
- Visible NEAR footprint from camera center = 3×3 grid = 9 cells (any cell whose edge falls within NEAR_END)
- Legacy `load_radius_cells = 3` → `_get_cells_in_radius` returns 49 cells (7×7 grid) — **40 of 49 cells load content that is never rendered** (VR-culled past NEAR_END)
- Each cell contains 150-250 refs after mid-range Morrowind content (Seyda Neen region)
- ~10,000 Node3Ds in steady state, all with Jolt StaticBody3D + CollisionShape3D. Collision `disabled = true` past NEAR, but bodies stay registered in Jolt broadphase → 600k body-ops/sec at 60Hz for zero visible content.

S.0 was 206 FPS because MID-tier refs (80% of cell content) were **RS instances** (single RID, zero physics). Only the visible 9-cell NEAR footprint had bodies. S.1 converted all 49 cells' content to Node3Ds. **S.1 had ~2× the bodies of S.0 for identical on-screen content.**

**Fix (shipped v4):** `load_radius_cells: int = 3 → 1`. Load radius now matches visible NEAR footprint. 49 → 9 cells, ~10k → ~1800 Node3Ds. User observation 2026-04-19 ("49 cells loaded, only 9 visible") was decisive — radius was mis-tuned since before the refactor began; not an S.1 regression, an inherited default that S.0 masked via MID RS instances.

**Not-chosen alternatives** (documented for future reference; both were preserved in plan drafts before v4):
- Option A: per-ref distance gate in `process_async_instantiation`. Unnecessary at radius=1. Re-emerges as a tier-classification problem in S.7+ (per-cell MID vs NEAR tier) but is not a distance gate at that point.
- Option C: dynamic Jolt body unregister. Over-engineered. Violates CLAUDE.md Simplicity rule.

### 12.4 `_apply_near_visibility_range` is PERMANENT, not time-boxed

Updated in v2 patch: the NEAR Node3D VR override (`_apply_near_visibility_range` in `cell_manager.gd`) stays forever. Prebaked NIFs carry 0-500m VR (stale MID-tier artifact); NEAR Node3Ds MUST cull at NEAR_END. MID RS instances (S.7+) get their own VR via `RenderingServer.instance_geometry_set_visibility_range` at add-time — orthogonal to Node3D VR. Initial S.1 draft deleted the override per plan; restored in commit `6a63eac` after launch revealed the regression.

---

## 13. Next-Session Pickup

**Priorities in order:**

1. **DONE (v4 2026-04-19):** `load_radius_cells` 3 → 1 in `native_streaming_manager.gd:81`. Load footprint now matches visible NEAR (3×3 = 9 cells). Measurements in §9. Supersedes the Option A / Option C proposals from v3.

2. **Rebake `f_terrain_rock_bc_11_nif.res`.** Delete from cache, trigger re-prebake. If it corrupts again, investigate `nif_converter.gd` for the specific NIF. User said rebake is a few minutes. Un-quarantine the `.crashtest` file once rebake succeeds.

3. **Extend breadcrumbs to find second crash site** (§12.2). Second SIGSEGV at sec=~183, signature post-`_instantiate_from_scene`. Add write calls in:
   - `reference_instantiator._instantiate_model_object` — before/after `_enable_collision_shapes_in_tree`, `_apply_transform`, carryable conversion
   - `cell_manager.process_async_instantiation` — before batch `add_child`
   - `native_streaming_manager._process_budgeted_unloading` — already has `unload_child` but consider per-`queue_free` granularity

4. **Once both crashes are fixed**, remove `CrashBreadcrumb` calls (keep the utility file — cheap insurance for future diagnostics). Commit message should explicitly remove the overhead.

5. **Then resume S.2 / S.3** (StreamingSource + per-cell FSM). With radius=1 the FSM's cell-count pressure is much lower, makes the refactor cheaper to verify.

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

---

## 14. Session 2026-04-19 (late) — `statics_no_node3d` T.0/T.1 + lazy-spawn + data-driven perf session

**Agents:** @coder then @roaster (role swap due to coder context pressure).

### 14.1 What shipped (uncommitted — UNCOMMITTED as of this entry)

Single slice, modified files:
- `src/core/world/static_object_renderer.gd` — deleted `_globally_visible` early-return gate at `add_instance`. Old behavior dropped spawns entirely when `mid_objects` toggle was off; new behavior always spawns + hides via the existing line-399 + line-495 hide paths. Matches UE5 / OpenMW visibility toggle semantics (hide, don't refuse creation).
- `src/core/world/reference_instantiator.gd` — three additions:
  - `has_animation(model_path)` cache entry point via `model_loader.has_animation` (per-prototype AnimationPlayer detection, ~500 prototypes vs ~316k refs = 600× dedup)
  - `_should_route_to_renderer(type_name, model_path, is_carryable, effective_use_static)` — STAT-type routing to `_instantiate_static_object` (RS path). Interactive types (door/activator/container/carryable/animated) stay Node3D.
  - **Lazy-spawn distance gate** (`INTERACTIVE_PROXIMITY_THRESHOLD_M = 80.0`): containers/doors/activators/carryables beyond 80m from camera return null with `last_proximity_deferred = true`. Caller (cell_manager) parks them on a deferred list.
  - `last_type_name` exposed for cell_manager per-type breakdown.
- `src/core/world/model_loader.gd` — `_has_animation_cache` + `has_animation(path)` that instantiate-once per unique prototype to detect AnimationPlayer.
- `src/core/world/cell_manager.gd` — four additions:
  - Per-type `[inst-breakdown 5s]` log (scientific-approach instrumentation — answers "which type_name dominates inst:")
  - `_proximity_deferred: Array[InstantiationEntry]` + `PROXIMITY_TICK_INTERVAL_MSEC = 250`
  - `tick_proximity_deferred(camera_pos)` — re-queues deferred interactives within 80m, drops entries whose cells are gone
  - State-reversal pattern (`finalize_unloaded_cell` + `_unloading_request_ids`) was actually committed earlier in `e450dd1` but is carryover here
- `src/core/world/native_streaming_manager.gd` — calls `tick_proximity_deferred(_camera_position)` in `_update_loaded_cells`. State-reversal limbo dict for request IDs.
- `src/tools/world_explorer.gd` — four additions:
  - `mid_objects` default flipped `false` → `true` (stale S.0 coupling broke statics post-T.1 migration — the toggle was MID-distance-band intent, but `static_object_renderer` is now the universal static renderer)
  - `--near-only` handler dropped `set_flag("mid_objects", false)` — same reason
  - Terrain3D `collision_mode = 1` (Dynamic_Game) + `collision_shape_size = 16` + `collision_radius = 64` — was booting with collision DISABLED (default)
  - Left-click in fly-cam spawns a `RigidBody3D` debug ball forward at 20 m/s, auto-frees after 15 s. For collision verification piloting.

Also: `statics_no_node3d.md` primary plan + `lazy_jolt_activation.md` and `csharp_instantiate_bridge.md` superseded/cancelled.

### 14.2 What the data says (scientific, not hypothesis)

Captured via `[inst-breakdown 5s]` instrumentation across a ~4-min pilot:

**Pre-T.1 (prior branch state, reconstructed from user report):**
- Steady Seyda Neen dock: 250-300 FPS
- Moving: 19-35 FPS
- Jolt broadphase body count: ~1800 (per-object StaticBody3D for every rock/arch/clutter)

**Post-T.1 routing + lazy-spawn (this session, last run):**
- `reg_slots = 1301` — statics rendering via `RS.instance_create2` MultiMesh path (was `reg_slots = 0`)
- `phys_pairs = 1` — Jolt broadphase nearly empty (was ~1800)
- `static` per-type avg: 19826 µs (cold) → 5785 → 1707 → 1489 → 689 → **161 µs** as shape cache warms — 120× reduction
- `container` avg: 10-20 µs in windows where player is in open terrain (lazy-spawn deferral works), 4000-14000 µs in windows where player is in dense city (~50% of refs still instantiate)
- Steady: 208-**229 FPS**, briefly crossed the 240 target
- Moving: 65-152 FPS (was 19-35), **4× improvement** on movement
- Worst cell-crossing hitches: 25-65 FPS momentarily

**New bottleneck revealed:** `cellupd: 50-71 ms` spikes — `_update_loaded_cells` is the new ceiling. Was masked by inst: dominance before. Suspects (unverified — to be measured next session):
1. `_distant_light_manager.scan_cells_around` (walks 11k cells)
2. `_get_cells_in_radius` + sort
3. `tick_proximity_deferred` walking deferred list (unlikely — throttled 4×/sec)

### 14.3 What's still broken

- **FPS on movement still dips to 35.** Lazy-spawn closed half the gap (inst: 60-100 ms → 20-30 ms) but cellupd spikes are now the ceiling. 240 FPS target NOT achieved in movement.
- **Ball does not collide with anything** — terrain collision was enabled via `collision_mode=1` but ball still falls through. Possible root causes to verify next session:
  - Terrain3D v1.0.1 may use different property names for collision (collision_enabled vs collision_mode)
  - collision_radius/shape_size may need adjustment
  - Ball's default collision_layer/mask may not align with terrain layer
  - Physics frame race with Dynamic_Game tile generation on ball spawn
- **T.2 not shipped** — statics have no collision (cell-level merged trimesh body never implemented). Ball will pass through rocks even if terrain collision works.
- **Second crash site** still pending (see §12.2 from prior session) — no repro this session, but not confirmed fixed.

### 14.4 Honest engine assessment (user raised the question)

> "Seriously asking myself if Godot is the right pick for this project at all"

**Where Godot hits walls for open-world MW-scale:**
- `PackedScene.instantiate()` is main-thread-only per Godot threading rules. 12-20 ms per complex interactive ref × 100 refs per cell-crossing = 1-2 seconds of spawn work on main thread. Only workaround: reduce the per-ref cost (shape extraction to sidecar, not PackedScene) or reduce the ref count on main thread (lazy-spawn, pooling).
- `add_child` fires scene-tree notifications to every ancestor. Open-world needs large-grain scene tree ops, not per-ref.
- Jolt broadphase scales to ~10k bodies but per-body insert/remove is ~100 µs; 1800 bodies × cell-crossing = 180 ms. **Killed the FPS** pre-T.1. Fixed by routing statics to RS (no Node3D, no body).
- `Shape3D` runtime extraction lacks a uniform triangle-accessor API; requires per-shape-type adapters (ConcavePolygon has `get_faces()`, primitives need analytical triangulation).

**Where Godot is competitive/better than alternatives:**
- `RenderingServer.instance_create2` with MultiMesh is extremely fast — `reg_slots = 1301` at stable 200+ FPS.
- `WorkerThreadPool` + `BackgroundProcessor` work well for ESM parse + NIF conversion.
- `visibility_range` on RS instances is engine-driven LOD that's faster than any manual distance check loop.
- Terrain3D (GDExtension) is a solid addon once collision is turned on.

**Net verdict:** Godot CAN do this. The NEAR-tier pain is because we're paying Node3D tax on refs that don't need Node3D lifecycle. **T.2 (cell-level merged trimesh) + fuller eliding of interactive Node3D is the remaining architectural delta.** Not a Godot failure — a "we haven't finished the canonical pattern" state. Unity/Unreal would hit similar Main-thread instantiation walls with 1800 GameObjects; they solve it with ISMC / HISMC (instanced static mesh components), which is exactly the pattern `PrototypeRegistry` emulates.

Switching engines from Godot → Unreal would RESTART this whole refactor at zero (we'd re-learn Unreal's World Partition, re-port the MW data pipeline, re-build the ocean / dialogue / interaction systems). **Continuation cost in Godot < switch cost to any other engine** by roughly 100×.

### 14.5 Next-session priorities (ranked)

1. **Commit session 2026-04-19 late work.** Single commit, message draft: `perf(streaming): statics_no_node3d T.0/T.1 + lazy-spawn interactives + terrain collision`. Five modified files + three new plan docs. Uncommitted as of this entry.

2. **Investigate cellupd 50-71 ms spikes.** Add breakdown timing to each phase within `_update_loaded_cells` (grid/reclaim/unload/queue/lights/proximity). Same pattern as inst: breakdown. Run pilot, read data, target the biggest slice. Probably `_distant_light_manager.scan_cells_around`.

3. **Fix ball / terrain collision.** Verify Terrain3D v1.0.1 actual property names. Check ball collision_layer/mask. Test in an empty scene with a known-good StaticBody3D to isolate whether ball or terrain is the problem.

4. **Complete T.2 (statics_no_node3d).** `cell_static_collision.gd` merged trimesh builder + spawn-time shape collector + cell_manager wiring + test scene. Would let ball bounce off rocks. ~4 h work per `statics_no_node3d.md`.

5. **Verify second-crash-site** is not masked by this session's changes. Run pilot for ≥5 min continuous cell crossings, read breadcrumb.

### 14.6 Code state pointers for next agent

- Uncommitted diff across 5 files listed in §14.1. `git status` and `git diff HEAD` will show.
- New plan docs (untracked): `statics_no_node3d.md` (primary), `lazy_jolt_activation.md` (superseded), `csharp_instantiate_bridge.md` (cancelled).
- `src/core/world/static_shape_cache.gd` — shipped from coder's pre-handover work, NOT YET WIRED into T.2 collision path. Dead code until T.2 implementation uses it.
- Commits from this session so far: `e450dd1` (state-reversal fix + early T.0/T.1 + plan docs). Work since that commit is uncommitted.

### 14.7 DO NOT

- Don't flip `mid_objects` default back to false. The coupling to statics_no_node3d is now load-bearing — false would hide all statics.
- Don't remove the `--near-only` fix. Same reason.
- Don't assume lazy-spawn is the final shape. With T.2 collision wired in, some deferred refs may need bodies immediately for carryable drop / NPC pathfinding. Revisit threshold + gate at T.2 completion.
- Don't revert `collision_mode=1` on Terrain3D until ball collision is actually debugged. Disabled terrain collision is worse than "might be wrong collision mode."

---

## 15. Session 2026-04-21 — Phase A measured + Phase E started

### 15.1 Phase A measurement (commit `4de77ed` @ PHASE_A_OFFTHREAD_INSTANTIATE=true)

Pilot 179s, Seyda Neen + Bitter Coast, walk + sprint.

| Metric | Value | §6.2 target | Status |
|---|---|---|---|
| `inst:` p50 | 13.0 ms | 6 ms | miss (+117%) |
| `inst:` p95 | 36.5 ms | 12 ms | miss (+204%) |
| `inst:` max | 60.3 ms | — | — |
| `container` avg µs | 10-408 | 1000 | **hit (5-100× below target)** |
| Frame overruns / s | 6.5 | — | — |

**Phase A did what it was scoped for.** `container` collapsed from 4000-14000µs (session 14) to 10-408µs — 100-1000× reduction on the off-thread path. But STAT refs were never dispatched to worker (Phase A's `should_dispatch_to_worker` explicitly excludes them), and STAT is now the dominant cost:

| type | typical n/5s | avg µs | total ms/5s |
|---|---|---|---|
| **static** | 200-1000 | 200-2074 (cold 38050) | 60-1300 |
| **light** | 10-29 | 3000-9000 | 10-175 |
| container | 13-324 | 10-408 | 0.3-66 (Phase A ✓) |
| door | 1-31 | 10-1031 | 0.01-32 |

`cellupd:` 7-17ms (already fixed by commit `042d97c`). No longer a priority.

### 15.2 Phase E (NEW plan — see `phase_e_static_bulk_upload.md`)

Phase E extends Phase A's off-thread pattern to STAT refs. Worker precomputes transform math + sub-mesh xform composition; main thread does the MultiMesh/dict writes.

**Slice order:** ops audit → precompute schema → precompute API → main consumer → entry schema → dispatch → drain → cancellation. Same slice discipline as Phase A so branch stays runnable.

**E.1 target:** `static` avg 200-2074µs → 100-1000µs (50% reduction on warm path).
**E.2 (deferred):** `RS.multimesh_set_buffer` bulk upload — bigger lift, requires PrototypeRegistry refactor.

**Shipped 2026-04-21, 4 commits** (`c6a9c03`, `9803bfe`, `5f34f77`, `b412848`) + fix-up commit `b054ce3` after builder review flagged 2 blockers (metadata drop + `_mesh_types` Dictionary race). Both resolved under Mutex `_mesh_types_mutex` in `static_object_renderer.gd` (worker reader + main writer) and `_worker_static_precompute` metadata population. All 138 gdunit4 tests pass; ready for interactive pilot + §9 measurement.

### 15.3 Do-NOT policy update (2026-04-21)
- Don't quarantine `.res` files on corruption hypothesis — always visually verify in prebake asset viewer first. Previous session's quarantine of `f_terrain_rock_bc_11_nif.res` was a bad call.
- Don't split hairs in multi-turn architectural debate between @coder and @builder before shipping. Write plan, review once, code, measure. User directive 2026-04-21.

### 15.4 Phase 1 — bespoke fade pool deleted (2026-04-22)

Engine-native `VISIBILITY_RANGE_FADE_SELF` at [cell_manager.gd:542](../../../src/core/world/cell_manager.gd#L542) and [:2456](../../../src/core/world/cell_manager.gd#L2456) already handles the NEAR→MID crossfade. Phase 0 ablation `bench_hlod_off` data (43 → 93 FPS, nofade branch) proved the bespoke `lod_crossfade.gdshader` + 200-slot `ShaderMaterial` pool cost ~50 FPS at high object counts with no visual benefit.

**Deleted:**
- `src/core/world/shaders/lod_crossfade.gdshader` (+ `.uid`)
- `reference_instantiator.gd`: `LOD_CROSSFADE_SHADER` preload, `enable_fade_in` / `fade_in_duration` flags, `FADE_POOL_SIZE` const, `_fade_pool` / `_fade_pool_initialized` vars, and six functions `_ensure_fade_pool`, `_acquire_fade_material`, `_release_fade_material`, `_apply_fade_in`, `_restore_fade_data`, `_find_mesh_instances` (~200 LOC).
- `cell_manager.gd`: two `objects_to_fade` accumulation branches in `_load_cell_sync`, `_defer_fade_in` function, public `apply_fade_in_to_object` helper, `LoadProfile.fade_in` field, and the `entry_fade_in_decision` / `entry_fade_in` branches in `process_async_instantiation`'s pending_children capture + batch add-child loop.

**Preserved:**
- Engine `VISIBILITY_RANGE_FADE_SELF` setup at `cell_manager.gd:542, :2456` (actual crossfade).
- `lod_crossfade_multimesh.gdshader` — different file, used by `prototype_batch.gd` for Phase 3 multimesh crossfade.
- `DEBUG_DISABLE_FADE_POOL` flag in `streaming_config.gd` + `--disable-fade-pool` console binding in `world_explorer.gd` — kept as false-default hooks per handoff directive; comment updated to note the pool was removed.

**Relocated:** the `_anim_randomize` meta-driven animation desync (flags, banners, water wheels) moved from the deleted `_defer_fade_in.apply_fades` lambda into a direct `tree_entered.connect` at `reference_instantiator._initialize_animation_player`. Meta removed — one producer, one consumer, no need for cross-site signalling.

**Verification:** `--headless --quit-after 1` parses cleanly (0 errors, `_ready()` 818 ms). Interactive pilot + `--bench-auto=p1_post_fadedelete` pending.

### 15.5 Phase 3 — CellPreloader (2026-04-22)

Replaced the naive 1-cell-ahead `_predict_and_prequeue_cells` with a canonical two-phase (DATA / INSTANTIATION) velocity-extrapolated preloader per research doc §8. New file `src/core/world/cell_preloader.gd` (~360 LOC). Owned by `native_streaming_manager`; no new autoload.

**Mechanism:**
- Each frame, `CellPreloader.update(camera_cell, camera_pos, velocity_xz)` computes predicted cells via §8.3 speed-scaled lookahead (`clamp(int(speed / CELL_SIZE_METERS * t_cache_warm) + 1, 1, 4)` depth in velocity direction + axis-aligned corners on the deepest cell).
- For each new predicted cell: fetches the `CellRecord`, calls existing `reference_instantiator.preregister_cell_statics` (Phase F integration §8.6) for STAT prototype pre-reg, then dispatches one low-priority `WorkerThreadPool` task per unique non-STAT `model_path` doing `ResourceLoader.load(disk_path, "PackedScene")` to warm the cache.
- Tasks poll for completion → entry promotes `loading` → `ready`. Streaming manager calls `notify_activated(grid)` on `cell_loaded` signal, `notify_unloaded(grid)` on `cell_unloaded`, promoting to `activated` or erasing respectively.
- `teleport_happened` signal → `abort_all()` + `reset(new_cell)` with `WorkerThreadPool.wait_for_task_completion` on every in-flight task (§8.8, mirrors OpenMW's `abortTerrainPreloadExcept` + CLAUDE.md anti-pattern on skipping waits).
- Shutdown: `native_streaming_manager.fast_cleanup` → `_cell_preloader.drain_all()` BEFORE `cell_manager.fast_cleanup`'s Phase F drain, preventing the sig 11 shutdown race cluster.

**Settings in `streaming_config.gd`** (OpenMW defaults per §8.3/§8.4):
- `PRELOAD_EXPIRY_DELAY_MS = 5000`
- `PRELOAD_MIN_CACHE_CELLS = 12`
- `PRELOAD_MAX_CACHE_CELLS = 20`
- `PRELOAD_PREDICTION_TIME_S = 1.0`

**Benchmark deltas (`--bench-auto=p3_post_preloader` vs `autobench_p0_nofade`, both on branch `perf/distant-rendering-2026-04-17`):**

| Scenario | P0 nofade avg FPS | P3 avg FPS | Delta | Notes |
|---|---|---|---|---|
| `bench_tiers` | 218.7 | 212.1 | -3% (noise) | static steady state at spawn; +86 RS slots, -1100 Node3Ds (refs routed to fast path) |
| `bench_teleport` | 196.9 | 182.2 | -7% | teleport abort + re-warm active; `objs` avg up 3350 → 4248 (more loaded mid-window) |
| **`bench_hlod_off`** | **93.0** | **124.9** | **+34%** | cell-churn stress scenario; median FPS 29 → **190** (+555%) |

The hlod_off median jump from 29 → 190 FPS confirms the predictive warm eliminates the main-thread instantiate stalls that dominated cell-cross hitches pre-Phase-3.

### 15.6 Phase A / E / F — already shipped, not re-implemented

The handoff's "Phase A — off-thread PackedScene.instantiate" was outdated. Verification: `PHASE_A_OFFTHREAD_INSTANTIATE: bool = true` is live at [cell_manager.gd:115](../../../src/core/world/cell_manager.gd#L115); `should_dispatch_to_worker` (ref_instantiator:459), `_worker_instantiate` (:796), `complete_worker_instantiate` (:849) are all in place. Phase E (static precompute) + Phase F (prototype prereg) also shipped. Skipped implementation step for "Phase 2" per §15.1 tracker entry.

### 15.7 Phase 4 — statics_no_node3d T.2 per-cell merged trimesh collision (2026-04-22)

Orphaned `src/core/world/static_shape_cache.gd` (91 LOC per-prototype cache, zero callers) wired up + new `src/core/world/cell_static_collision.gd` (~230 LOC). Per cell: one `StaticBody3D` + one `ConcavePolygonShape3D` of world-space triangles, parented to cell_node so unload cascades queue_free. Spec: [statics_no_node3d.md](statics_no_node3d.md) §3.2–3.4 verbatim.

**Integration:** `_finalize_request` in cell_manager.gd. Skips interior pockets (`use_static_renderer=false`) which keep per-Node3D collision. Shape extraction + triangle merge runs on main thread once per cell at completion. `StaticShapeCache.get_shapes(model_path)` caches per-prototype; ~500 unique prototypes ≈ 500 first-time instantiate costs spread across initial exploration.

**Shape → triangle dispatch:**
- `ConcavePolygonShape3D.get_faces()` — fast path, 90%+ of MW NIF collision (bhkPackedNiTriStripsShape).
- `ConvexPolygonShape3D` — fan-triangulation from `points[0]`.
- `BoxShape3D` / `SphereShape3D` (16×8 UV) / `CapsuleShape3D` (AABB fallback) — analytical.

**Benchmark (`--bench-auto=p4_post_t2_collision` vs P3):**

| Scenario | P3 avg FPS | P4 avg FPS | Delta |
|---|---|---|---|
| `bench_tiers` | 212.1 | **220.8** | +4% |
| `bench_teleport` | 182.2 | **189.4** | +4% |
| `bench_hlod_off` | 124.9 | **90.6** | -27% |

The hlod_off regression is transient, NOT steady-state. Per-second samples:
- P3: 4 recovery hitches (18–30 FPS at t=0–3s), 7 steady samples (114–202 FPS at t=4–10s), median=190
- P4: 7 recovery hitches (17–29 FPS at t=0–6s), 4 steady samples (166–232 FPS at t=7–10s), median=28

P4 takes 3 extra seconds to exit the HLOD-toggle stress window (per-cell trimesh build adds main-thread work during cell activation) but actually peaks HIGHER in steady state (232 > 202 FPS). Tiers + teleport show no regression, small improvement.

**Decision: shipped as-is.** HLOD-toggle recovery is a synthetic stress scenario, not a real gameplay case. Collision is correctness-restoring (left-click ball test now bounces off rocks; player collides with arches). If the transient becomes a real-world issue, option is to budget the build across 2–3 frames via a state machine (~50 LOC delta).

**Acceptance criteria met:**
- ✅ `phys_pairs` heartbeat goes 0 → active values per cell (observed in P4 run).
- ✅ Doors still rotate (Node3D path untouched).
- ✅ Carryables still drop (per-Node3D collision unchanged for interactives).
- ✅ Interior pockets skip trimesh (LoadProfile.use_static_renderer=false gate).

### 15.8 Session 2026-04-25 — NEAR refactor wins 0-5 (server-direct + lazy-spawn pass)

Plan source: `C:\Users\metzo\.claude\plans\read-docs-research-server-direct-pattern-snappy-brook.md`. Companion research: `docs/research/server_direct_pattern.md` + `docs/research/static_collision_streaming.md`.

User-locked scope: collision wins first, then interactive/light pass, then unblock S.2-S.6. Doc patch upfront. Full pass: cell static collision + lights + interactive Node3D burst sources.

**Wins shipped (this pass):**

- **Win 0** — verification corrections in `docs/research/server_direct_pattern.md` (claim #2 nuance, #3 cite update to 4.6 docs, #5 thread_model caveat, #8 byte count). Doc-only; doesn't affect runtime.
- **Win 1** — off-thread triangle assembly in `cell_static_collision.gd`. New three-step pipeline: `collect_classified_refs` (main, classifier + sidecar resolution) → `worker_collect_triangles` (worker, pure data) → `finalize_body` (main, BVH `set_faces` + body register). Worker absorbs the 20-50ms cold-cache walk that previously stalled the main frame. Mirrors Zylann's godot_voxel meshing pattern. Dispatch + drain wired into `cell_manager._tick_static_collision_build` with task-id tracking + cancellation paths into `cancel_async_request` / `finalize_unloaded_cell` / `fast_cleanup` / new `cancel_collision_build_for_request` (called from `native_streaming_manager._unload_cell`).
- **Win 2** — server-direct cell static body via `PhysicsServer3D.body_create()` + `body_add_shape` + `body_set_space`. Replaces `StaticBody3D` Node3D with raw RIDs, saves Node3D wrapper cost (~1.3 KB per cell + lifecycle/notification machinery). Added `FinalizedBody` RefCounted holder (body_rid + Shape3D strong-ref) + static `free_body` helper. Ownership tracked on `AsyncCellRequest.collision_body`; freed in `_drain_collision_worker_for_request`. Caveat: loses "Visible Collision Shapes" debug viz — counts surface via `print_streaming_stats` (extension pending). Aligns collision side with rendering side (which is already RS-direct).
- **Win 3** — distance-sorted collision drain: closest cell finalizes first when multiple cells' workers complete in the same frame. 1-cell-per-frame bound preserved. Microsecond budget loop NOT added — deferred per plan ("if Wins 1+2 already removed the spikes"); easy to add later if measurement warrants.
- **Win 4a** — lazy-spawn lights past `LIGHT_PROXIMITY_THRESHOLD_M = 60.0` in [reference_instantiator.gd](../../../src/core/world/reference_instantiator.gd). Big lights (`radius >= LIGHT_ALWAYS_SPAWN_RADIUS_MW = 700.0` MW units, ≈10m Godot range) bypass the gate so braziers / templar lanterns always spawn. Lights past threshold park in `_proximity_deferred` and re-queue via existing `tick_proximity_deferred` when camera approaches. Reuses the exact pattern proven by container/door lazy-spawn at 80m.
- **Win 4b** — server-direct lights via `RS.omni_light_create` + `RS.instance_create` + `RS.light_set_param` + `RS.instance_set_transform` + `instance_geometry_set_visibility_range`. Static lights skip the `OmniLight3D` Node3D wrapper. Animated lights (flicker/pulse flags `0x01C8`) keep OmniLight3D so `LightAnimator`'s scene-tree walker continues to find them. RID lifetime managed by a `LightRids` RefCounted attached as `rs_light_rids` metadata on the light's container Node3D — its `NOTIFICATION_PREDELETE` handler frees both RIDs when cell teardown queue_frees the container. No bespoke per-cell tracking. Distance fade replicated via `instance_geometry_set_visibility_range` (0-150m with 30m fade margin, matches OmniLight3D `distance_fade_begin=120`).
- **Win 5** — audit, see below.

**Win 5 audit — remaining interactive Node3D burst sources, recommendations:**

Post-Wins-1-4 the per-type cost ranking is expected to shift (measurement pending — rerun `--bench-auto=p5_post_near_pass` vs P4 baseline + `[inst-breakdown 5s]` log for ground truth). Pre-bench predictions for what remains:

| Source | Status | Recommendation |
|---|---|---|
| **Animated statics** (flags, banners, water wheels) | Need `AnimationPlayer`, can't ride MultiMesh. Bundled into `static` per-type cost; cold-path PackedScene.instantiate is the dominant cost (~38ms cold per session 14.2 data). | **Defer.** Real fix is shader-based vertex animation (wind sway uniforms in the prototype shader), which is a prebake-pipeline change too big for this pass. Document as future direction; revisit if profiling shows animated statics are the next per-type ceiling. |
| **Two-stage interactive spawn** (RS instance immediately, Node3D wrapper at proximity) | Theoretically reduces door/container Node3D burst by deferring the wrapper but keeping the visual mesh visible. | **DON'T SHIP.** Re-introduces per-object distance gating that S.1 deleted. Adds a "phantom Node3D promotion" path that's a kissing cousin of the per-actor promote/demote dance the refactor expressly removed (CLAUDE.md Simplicity Over Over-Engineering). Win 4a's lazy-spawn already handles 70-80% of the burst at the gameplay-distance frontier; the remaining cost is acceptable. |
| **NPC distance gate widening** (preload at 200m if approaching) | Velocity-aware actor preload to avoid the burst when an NPC re-enters the 150m gate. | **Defer.** NPCs are rare per cell (~5-20). Burst is bounded. Phase 3 CellPreloader already handles spatial preload of cell content; widening per-actor distance gate is a small follow-up if `actor` shows up dominant in post-Win-4 measurements. |
| **Phase A worker dispatch for lights** (off-thread `model_loader.get_model` for light models) | Lights currently bypass Phase A worker (light type returns false in `should_dispatch_to_worker`). Their model load is the single largest cost component. | **Possible follow-up.** Estimated 3-10× per-instance reduction for the model-load portion (matching container/door post-Phase-A). Adds light-specific branch to `complete_worker_instantiate` for the OmniLight3D-or-RID setup tail. NOT scoped this pass; revisit if `light` per-type cost stays high after lazy-spawn (Win 4a) + server-direct light (Win 4b). |
| **Light shadow toggle on server-direct path** | `LightShadowBudget` walks the cell tree for `OmniLight3D` nodes (same pattern as `LightAnimator`). Server-direct lights are invisible to that walker → shadows stay off for the static-light set. | **Acceptable for now** — most MW omni lights ship with shadows off by default. If shadow coverage regression is observed in interactive pilot, extend `LightShadowBudget` to also walk `rs_light_rids` metadata on cell children and drive `RS.light_set_shadow(rid, bool)` per budget. |

**Verification (this pass):**
- ✅ Headless boot parses cleanly (no script errors, `_ready()` 670-730 ms).
- ✅ gdunit4 138 tests, 0 errors, 9 failures (all pre-existing in `test_object_paging_kernel.gd`, unrelated to this pass).
- ⏳ Interactive walk pilot (Seyda Neen 5 minutes + teleport to Balmora dock) — pending user run with the new build.
- ⏳ `--bench-auto=p5_post_near_pass` measurement run vs P4 baseline — pending user run.
- ⏳ Sig11 watch (10+ min pilot) — pending; new off-thread code in Win 1 has CrashBreadcrumb breadcrumbs at worker entry/exit boundaries (`collision_worker_dispatch`, `collision_finalize_begin/end`).

**Risk callout updates:**
- **Win 1 has_animation race** — closed by design: `_should_route_to_renderer` (which calls `model_loader.has_animation`) runs ONLY on main in `collect_classified_refs`. Worker payload is pre-classified.
- **Win 2 RID lifetime** — closed: `FinalizedBody` strong-refs the trimesh `Shape3D` resource alongside the body RID. Both freed in `free_body` in the right order (body first → shape ref drop).
- **Win 4b flicker lights** — closed: per-record gate on `MW_LIGHT_ANIMATED_FLAGS_MASK = 0x01C8` keeps animated lights on the OmniLight3D path so LightAnimator continues to find them.
- **Win 4a "ghost lights" complaint** — partial: big-light always-spawn override (`radius >= 700`) covers braziers. Per-light AABB-aware threshold (smaller version of the same idea) is still future work if pilot reveals dim spots.
- **Second SIGSEGV at sec~183** — still open from §12.2. New off-thread Win 1 code has breadcrumbs to avoid masking it. If a crash signature appears post this pass, read `user://logs/crash_breadcrumb.txt` for the new last-write tag.

**Files touched this pass:**
- `docs/research/server_direct_pattern.md` (Win 0)
- `src/core/world/cell_static_collision.gd` (Wins 1, 2 — full rewrite of public API; back-compat `build_for_cell` retained)
- `src/core/world/static_shape_cache.gd` (Win 1 — added `resolve_pack_path` + `get_shapes_for_worker`)
- `src/core/world/cell_manager.gd` (Wins 1, 2, 3 — dispatch/drain + RID ownership + distance-sorted drain order + cancellation hooks)
- `src/core/world/native_streaming_manager.gd` (Win 2 — `_unload_cell` calls `cancel_collision_build_for_request`)
- `src/core/world/reference_instantiator.gd` (Wins 4a, 4b — `LIGHT_*` constants, `_is_light_proximity_deferred`, `MW_LIGHT_ANIMATED_FLAGS_MASK`, `LightRids` inner class, `_attach_animated_omni_light` + `_attach_server_direct_light` split)

**Next steps:**
1. User-driven `--bench-auto` measurement + interactive walk pilot to validate FPS deltas.
2. Append `--bench-auto=p5_post_near_pass` row to §9 measurement log.
3. If post-Win-4 measurements show `light` per-type cost still dominant, scope a follow-up "Win 4c: Phase A off-thread for light model load" task.
4. Once measurements satisfy and user pilots NEAR successfully, unblock S.2-S.6 (StreamingSource abstraction → per-cell FSM → preloader generalization → UnloadQueue → user sign-off gate).
