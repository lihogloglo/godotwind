# Interior/Exterior Transitions — Architecture & Industry Analysis

> **Update 2026-04-06**: The synchronous load hiccup was fixed. `InteriorPocketManager._load_pocket()` now calls `CellManager.request_cell_async(cell_name, LoadProfile.interior_pocket())` and drains the result over 1–2 frames via `_update_async_loads()` + `_update_pocket_finish_up()`. A fade-to-black bridge handles the case where the player rushes a door faster than the load completes. Real-renderer peaks verified at ≤ ~6 ms on NORMAL path (Seyda Neen 268-ref Census and Excise Office), ~10 ms on first-visit shader warm-up, ~12 ms on BRIDGE path. See the **P0 Fix** section below and the test scene at `tests/visual/test_interior_transition.tscn`.

## Left To Do (follow-ups from 2026-04-06 P0 session)

Tracked here and in `docs/FUTURE_STEPS.md` under "Tracked Follow-ups".

1. **`NativeStreamingManager.pause()/resume()` wiring in `world_explorer.gd`** — the test scene doesn't run the streaming manager so the fix couldn't be validated there, but the main scene does. When `InteriorPocketManager.transition_started` fires, the streaming manager should stop accepting new exterior cell requests (keep draining the existing queue — the priority lane already routes interior entries first) and resume on `transition_completed` or `interior_load_timeout`. The pause API already exists at `world_explorer.gd:~1855` — just needs signal connections in `_setup_pocket_manager()`.
2. **MW adapter extraction (`DoorDescriptor` + `WorldDataProvider`)** — `InteriorPocketManager` still imports ESM types directly, holds `BUILDING_PATTERNS`/`NON_SEAMLESS_PATTERNS` MW STAT prefixes, reads `teleport_rot_mw.z` for yaw negation. All of this belongs behind a `src/core/world/morrowind/mw_door_adapter.gd` + a `WorldDataProvider` base class with a `MWWorldDataProvider` implementation. Scoped out of the P0 session because it's orthogonal to the hiccup fix and doesn't affect perf. See also `docs/FUTURE_STEPS.md` and the note in #text about `DoorInteractable` future coupling.
3. **First-visit shader warm-up** (Arrille's Tradehouse = 9.77 ms NORMAL on cold cache). Under the 16.67 ms per-frame budget, but 1.77 ms over the aggressive 8 ms threshold. Options if this matters later:
   - Shader prewarm: off-screen SubViewport render of each unique material before visibility flip
   - Raise the threshold to 16 ms (actual per-frame budget at 60 fps)
   - Profile and identify the exact culprit (likely first material compile on visibility flip during fade-in)
4. **BRIDGE path peak (12.16 ms)** — real but bounded and only engages on player rush. The `_fade` tween creates a Tween per call; could pool or pre-warm. Low priority — real-world players aren't rushing past every door.
5. **`_diag_duplicate_time_total_us` / `_diag_duplicate_count`** on `CellManager` — these are existing diagnostic counters that my changes increment through the transient-profile wrap. If the assertion ever fires in production they'll give context; otherwise no-op.

## P0 Interior Load Fix (2026-04-06)

**Problem:** `_load_pocket()` used `CellManager.load_cell()` synchronously on the main thread when the player got within 10 m of a door. A 150-object interior stalled 35–250 ms. Worst case wedged the frame during approach.

**Fix:** Async pipeline with a per-request `LoadProfile` to eliminate shared-flag mutation races between concurrent exterior and interior loads.

**Key pieces:**
- `CellManager.LoadProfile` — inner class with `fade_in`, `use_static_renderer`, `max_actor_distance`, `interior_priority`. Static factories `exterior_default()` / `interior_pocket()`. Stored on `AsyncCellRequest` and mirrored onto each `InstantiationEntry` at queue time.
- `CellManager.request_cell_async(cell_name, profile)` already existed for interiors — IPM now uses it with `LoadProfile.interior_pocket()` (disables RS batching so interior objects render at the pocket offset, not ESM world position).
- `ReferenceInstantiator._current_load_profile` — transient read by `_effective_max_actor_distance()` / `_effective_use_static_renderer()`. `_set_transient_profile` / `_clear_transient_profile` pair wraps each queue drain call with a debug assert catching leaked transients.
- `InstantiationEntry.interior_priority` — priority-lane flag. `_sort_queue_by_priority` stable-sorts on `(interior_priority desc, distance)` so in-flight interior entries jump to the tail of the queue (where `pop_back()` takes from) during a transition. `CellManager.set_request_priority(request_id, bool)` + `force_queue_resort()` are the public APIs.
- `InteriorPocketManager._begin_pocket_finish_up(slot, collapse)` — 2-phase spread:
  - **F0:** place, visible=false, add_child, single-pass `_finalize_cell_node` walk (render layers on all VisualInstance3D, light_cull_mask on Light3D, physics layers on CollisionObject3D, AABB accumulation on MeshInstance3D — one walk replaces three), build environment, register interior doors.
  - **F1 (next frame, OR same frame if `collapse`):** `_add_lightbox_from_aabb` using F0's cached AABB, LightAnimator, LightShadowBudget, `visible=true`, mark occupied, emit `pocket_loaded`.
  - **Fast path:** if the player is within `INTERACT_RADIUS * FAST_PATH_RADIUS_MULT (=2.0)` of the door at completion, F0+F1 run synchronously on the same frame.
- **Fade-to-black bridge** (`enter_interior`): if the slot is still loading when E is pressed:
  1. Set `_is_transitioning=true`, emit `transition_started`
  2. Boost via `set_request_priority(rid, true)` + `force_queue_resort()`
  3. `await _fade(0, 1, FADE_DURATION)` — 300 ms out
  4. Poll completion with a 2.0 s hard timeout (`INTERIOR_LOAD_TIMEOUT`)
  5. On timeout: log error, emit `interior_load_timeout(cell_name, rid)` signal, `cancel_async_request`, clear slot, fade back in, return false
  6. On success: teleport + fade-in via `_do_transition`
- **`_get_slot_for_cell_any(cell_name)`** — relaxed lookup that matches `is_loading OR finish_up_phase >= 0 OR is_occupied`. Required for the bridge — strict `_get_slot_for_cell` only matches occupied and would drop the bridge into the error path.
- **Stuck-load eviction** — `_evict_oldest_pocket` now falls back to cancelling the oldest in-flight load (via `CellManager.cancel_async_request`) if no fully-occupied slot is available. Prevents both pocket slots wedging in `is_loading` if the player rushes past multiple doors.
- **Test scene pump** — `tests/visual/test_interior_transition.gd._process()` calls `CellManager.process_async_instantiation(4.0, camera_pos, camera_fwd)` every frame. Without this, the async pipeline's main-thread drain never runs in the test scene (main scene gets it from NativeStreamingManager).

**Verification:** `tests/visual/test_interior_transition.tscn` has a `[FRAMETIME]` readout per transition showing peak ms + `path=NORMAL|BRIDGE`. Launch with `-- --auto-test` for headless auto-drive (teleports camera to 2 m from Arrille's Tradehouse, loads, enters, reports peak). Real-renderer results on 2026-04-06:

| Cell | Refs | Path | Peak |
|------|------|------|------|
| Arrille's Tradehouse (first visit) | 207 | NORMAL | 9.77 ms (first-visit shader warmup) |
| Census and Excise Office | 268 | NORMAL | 4.76 ms |
| Census and Excise Office (re-entry) | 268 | NORMAL | 5.56 ms |
| Exterior (exit from interior) | — | NORMAL | 4.35–4.93 ms |
| Arrille's Tradehouse (bridge) | 207 | BRIDGE | 12.16 ms |

All normal-path peaks stay under one 60 Hz frame (16.67 ms). First-visit cells peak ~10 ms due to first-time shader compilation. Bridge path (worst case) ~12 ms, bounded.

---



## Morrowind Data Model

Interior transitions are encoded in ESM door references:

- `is_teleport` flag marks a reference as a door transition
- `DODT` subrecord: destination position + rotation (player arrival facing, yaw only)
- `DNAM` subrecord: destination cell name (string for interiors, grid coords for exteriors)
- Interior cells have their own `water_height`, `ambient_color`, `sunlight_color`, `fog_color`, `fog_density`
- `is_quasi_exterior()` flag: some interiors share exterior sky/weather (e.g., Vivec plazas)

### Morrowind-Specific Challenges

1. **Coordinate mismatch:** Interior cells use their own local origin, unrelated to world space
2. **Size mismatch (TARDIS):** Interior geometry often exceeds the exterior building shell
3. **Lighting isolation:** Interiors have ambient/fog from AMBI data, completely different from exterior
4. **Interior-to-interior chains:** Dungeons have doors between interior cells

### ESM Rotation Conventions

Two different rotation fields exist per door and they serve different purposes:

- **`door_rotation_mw`** (cell reference rotation): The door OBJECT's physical orientation
  in the cell. Tells us which way the door mesh faces in the wall. Used for pocket alignment.
- **`teleport_rot_mw`** (DODT rotation): Where the PLAYER faces after teleporting.
  A gameplay hint — designers can point toward NPCs, tables, etc. NOT a geometric property.

Both use MW coordinate conventions (Z-up, rotate around -Z for yaw). When converting
to Godot (Y-up), yaw is negated: `Basis(Vector3.UP, -rot_mw.z)`.

---

## Current Architecture: Cell Pocket System

See `docs/PORTAL_SYSTEM.md` for full technical details.

**Cell pockets:** Interiors loaded as isolated "pockets" at Y=-500 in the same World3D:
- Visual layers: Exterior = 1-2, Interior = 3-4
- Physics layers: Exterior = 1-4, Interior = 5-6 per slot
- Spatial offset: Y=-500 with 1km X spacing between slots
- 2-slot reusable pool with distance-based eviction

**Two modes:**
- **Classic (default):** ENTER key → fade-to-black → teleport. Original MW behavior.
- **Seamless (experimental):** Stencil portal preview + walk-through + building hiding.

Toggle: `InteriorPocketManager.seamless_enabled` (escape menu checkbox or F5 in test scene).

### Key Insight: Why TARDIS Is a Non-Issue

The doorframe is the mask. The player can ONLY see the interior through the door opening.
As long as what's visible through that opening looks continuous with the exterior, the
transition is seamless — even if the interior is 10x larger than the exterior shell.

This is exactly how Portal (Valve) works: two portals connect spaces of any size/orientation,
and the player never notices because each portal shows only what fits through its opening.

---

## Industry References

| Game | Technique | TARDIS? | Notes |
|------|-----------|---------|-------|
| **Morrowind/Skyrim/Starfield** | Fade-to-black + cell swap | Yes | Loading screen between exterior/interior |
| **The Witcher 3** | Contiguous geometry + Umbra 3 | No | Interiors part of same world |
| **GTA V / RDR2** | MLO shell + room portals | No | Interior at world position |
| **Prey (2017)** | Looking Glass (SubViewport-like) | No | Same-scale interiors |
| **Half-Life: Alyx** | Stencil portal + teleport | Minor | VR seamless transitions |
| **Portal (Valve)** | Stencil + dual camera | No | Same-scale portal connections |
| **God of War (2018)** | Squeeze-through corridors | N/A | Hides loading behind narrow passages |

### The Witcher 3 (REDengine 3)

TW3 interiors are **contiguous with the exterior** — no separate cells. Umbra 3
(middleware) handles automatic occlusion culling. When outside, interior geometry
is occluded by walls. When walking through door, Umbra sees interior through opening.
Single lighting system, no environment swap needed.

**Not applicable to us:** TW3 interiors fit their buildings (no TARDIS), and all
geometry was custom-built for spatial alignment.

### RDR2 / GTA V (RAGE Engine)

"Shell + MLO" architecture: exterior building has door/window holes cut out, interior
MLO streams in at the same world position. Room+portal system for interior occlusion.
Single deferred lighting pipeline handles transition naturally.

**Most relevant to our approach:** The proximity-based interior streaming and
portal-controlled visibility are similar to our pocket + stencil system. The key
difference: RAGE places interiors at world position (no coordinate gap).

### Comparison

| Aspect | TW3 | RDR2/GTA V | Godotwind |
|--------|-----|------------|-----------|
| Interior position | At building | At building (MLO) | Y=-500 pocket |
| TARDIS problem | None | None | Yes (Morrowind data) |
| Occlusion | Umbra 3 (auto) | Room+portal (manual) | Stencil + render layers |
| Lighting transition | Same system | Same pipeline | WorldEnvironment swap |
| Visual continuity | Natural | Shell hole alignment | Stencil portal |

Our approach is closest to **Valve's Portal**: two disconnected spaces linked by a
visual "window" at the doorframe, with a coordinate teleport on crossing.

---

## Godot 4.6 Capabilities & Limitations

### What we use:
- **Stencil buffer** (StandardMaterial3D) — portal rendering, no custom pipeline needed
- **Render layers** (20 layers) — exterior/interior visual separation
- **Physics layers** — per-slot collision isolation
- **visibility_range** — distance-based LOD (not used for portals, but for world streaming)

### What Godot lacks:
- **Built-in oblique clip planes** — must use shader `discard`
- **Portal culling** — removed in 4.0 (was in 3.x)
- **Rendering compositor** — still a proposal

### Stencil caveat:
Stencil READ requires `transparency=ALPHA` (Godot issue #107731). This pushes
interior materials into the transparent queue, which affects depth sorting.

---

## Future Directions

1. **Exterior wall clip** → enables `no_depth_test=false` → proper depth sorting
2. **Environment blend** in seamless path (distance-based interpolation)
3. **Interior→exterior portal** (reverse stencil for looking out from inside)
4. **Window parallax** (SubViewport for windows — small viewport, big atmosphere)
5. **Interior-to-interior seamless** (currently uses classic fade-to-black)
6. **Horizontal doors** (ship hatches — need pitch-based alignment)
7. **Async pocket loading** (budgeted instantiation instead of synchronous)
