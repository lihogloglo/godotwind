# Interior Transitions & Stencil Portal System

## Status (2026-05-30)

- **Async load pipeline shipped 2026-04-06.** `InteriorPocketManager._load_pocket()` routes through `CellManager.request_cell_async(cell_name, LoadProfile.interior_pocket())` and drains the result over 1–2 frames via `_update_async_loads()` + `_update_pocket_finish_up()`. A fade-to-black bridge handles the case where the player rushes a door faster than the load completes. Real-renderer peaks verified at ≤ ~6 ms on NORMAL path (Seyda Neen 268-ref Census and Excise Office), ~10 ms on first-visit shader warm-up, ~12 ms on BRIDGE path.
- **Classic mode is the default and wired in the main scene.** Raycast door activation emits a placed-door `instance_key`, `world_explorer.gd` resolves that key through `InteriorPocketManager`, then routes exterior→interior, interior→exterior, and interior→interior through the same fade/priority/wait bridge.
- **World streaming freezes tracking, not processing.** `NativeStreamingManager.set_world_tracking_frozen()` keeps the exterior anchor stable while the camera is inside a pocket, but async completions and `CellManager.process_async_instantiation()` keep draining so rushed door activation cannot starve an in-flight pocket load.
- **Seamless mode is experimental** and gated behind `InteriorPocketManager.seamless_enabled`. Walk-through with stencil portal preview. Has known depth-sorting, lighting, and building-hide issues (see Known Issues below).
- **Test scene:** `tests/visual/test_interior_transition.tscn` (F5 toggle classic/seamless, E activate, TAB cycle doors, frametime readout per transition).
- **Main-scene smoke:** launch `scenes/Godotwind.tscn -- --interior-door-smoke`
  to activate a registered travel door, wait for the active pocket, activate an
  exit door, and verify exterior tracking unfreezes. Add
  `--interior-door-smoke-rush` to skip the preload wait and exercise the bridge.

---

## Morrowind Data Model

Interior transitions are encoded in ESM door references:

- `is_teleport` flag marks a reference as a door transition
- `DODT` subrecord: destination position + rotation (player arrival facing, yaw only)
- `DNAM` subrecord: destination cell name (string for interiors, grid coords for exteriors)
- Interior cells have their own `water_height`, `ambient_color`, `sunlight_color`, `fog_color`, `fog_density`
- `is_quasi_exterior()` flag: some interiors share exterior sky/weather (e.g., Vivec plazas)

### Placed-Door Identity

Gameplay uses a placed-reference key, not the base DOOR record id:

- Exterior: `ext:x,y:<base_ref_id_lower>:<ref_num>`
- Interior: `int:<cell_name_lower>:<base_ref_id_lower>:<ref_num>`

`ref_id` / `base_ref_id` still identify the base door mesh and record. `ref_num`
distinguishes multiple placed references that share that same base record. Main-scene
activation, duplicate checks, portal tracking, preload tracking, and active-door maps
use `DoorInfo.instance_key`.

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

## Architecture: Cell Pocket System

Interiors are loaded as isolated "pockets" in the same World3D as the exterior, hidden below it.

**Spatial layout:**
- Y=-500 base offset (1km X spacing between pocket slots)
- 2-slot reusable pool with distance-based eviction

**Layer isolation:**
- Visual render layers: Exterior = 1-2, Interior = 3-4
- Physics layers: Exterior = 1-4, Interior = 5-6 per slot
- Camera cull_mask swaps on transition

**Two modes** — toggle via `InteriorPocketManager.seamless_enabled`:
- **Classic (default):** ENTER key → fade-to-black → teleport. Original MW behavior.
- **Seamless (experimental):** Stencil portal preview + walk-through + building hiding.

### Key Insight: Why TARDIS Is a Non-Issue

The doorframe is the mask. The player can ONLY see the interior through the door opening.
As long as what's visible through that opening looks continuous with the exterior, the
transition is seamless — even if the interior is 10x larger than the exterior shell.

This is exactly how Portal (Valve) works: two portals connect spaces of any size/orientation,
and the player never notices because each portal shows only what fits through its opening.

### Subsystems

```
InteriorPocketManager (Node)     — Orchestrator: pockets, doors, transitions, walk-through
DoorPortal (RefCounted)          — Stencil plane + material management (outside-looking-in)
DoorUtils (static helpers)       — Door mesh finding, orientation computation
door_clip.gdshader               — Fragment discard shader for wall clipping
light_animator.gd                — Interior light flicker/pulse effects (OpenMW-matched)
light_shadow_budget.gd           — Per-instance shadow budget (configurable thresholds)
```

---

## Classic Mode (default)

ENTER key near a door → fade-to-black → teleport to pocket → layer/environment swap → fade-in.
Exit: ENTER key near exit door → reverse process.

- No portal preview, no walk-through detection, no building hiding
- Pockets preloaded at 10m (closest door only) for fast transitions
- Toggle: Escape menu checkbox or F5 in test scene
- `InteriorPocketManager.seamless_enabled = false` (default)

### Teleport Orientation

ESM DODT rotation stores **player arrival facing** (yaw only, Z component).
MW builds yaw quaternion around -Z (down), which negates when converted to Godot Y-up:

```gdscript
func get_teleport_yaw_basis_godot() -> Basis:
    return Basis(Vector3.UP, -teleport_rot_mw.z)  # negated for MW→Godot
```

**Not the same as object rotation.** `get_teleport_basis_godot()` (full 3-axis ZYX chain)
is for placing objects. `get_teleport_yaw_basis_godot()` (yaw-only with negation) is for
player/camera facing after teleport. MW exit doors face you toward the door (intended behavior).

### Camera Sync After Teleport

Fly camera (test scene) overwrites basis every frame via `_yaw`/`_pitch`. Must freeze
camera updates during the fade transition, then sync `_yaw`/`_pitch` from the teleported
basis after completion. Without this, the old facing direction bleeds through.

---

## Seamless Mode (experimental)

Walk-through with stencil portal preview. Toggle `seamless_enabled = true`.

### Render Pipeline (Portal Preview)

1. **Stencil-write plane** at door opening: invisible quad writes stencil value 1
   - `StandardMaterial3D`, `transparency=ALPHA`, `alpha=0.01`, `no_depth_test=true`
   - `render_priority=-10` (renders first in alpha queue)
   - `stencil_mode=Custom`, `stencil_flags=Write`, `stencil_reference=1`

2. **Interior materials** get stencil-read: only render where stencil=1
   - Each `StandardMaterial3D` duplicated, stencil-read applied
   - `transparency=ALPHA`, `alpha=1.0`, `depth_draw=ALWAYS`
   - `no_depth_test=true` (bypasses exterior wall depth)
   - Dimmed to 35% to mask depth sorting artifacts
   - `stencil_mode=Custom`, `stencil_flags=Read`, `stencil_compare=Equal`, `stencil_reference=1`

3. **Exterior door mesh** hidden, **interior door meshes** near opening hidden

4. **Camera cull_mask** expanded to COMBINED (layers 1-4)

5. **Interior lights** expanded to illuminate combined layers

### Pocket Repositioning & Alignment

Interior pocket normally at Y=-500. On portal activate:

1. Find matching interior exit door (exit door's teleport_pos near exterior door)
2. Compute rotation delta to align interior exit → exterior door
3. Translate pocket so interior door position = exterior door position

**Alignment rotation** uses two methods (priority order):

1. **AABB thinnest-axis** (`_compute_alignment_rotation`): Measures door mesh
   bounding box, thinnest dimension = wall normal. Requires finding the door mesh node.
   Works when door mesh has clear thin axis (ratio < 0.5 between smallest dimensions).

2. **ESM door object rotation** (fallback): When interior door mesh can't be found
   (common — node names don't match ref_ids in pockets), uses `door_rotation_mw`
   (the door object's placement rotation from ESM data). Extracts forward direction
   via `CS.esm_rotation_to_godot_basis(door_rotation_mw)` → `-basis.z` → horizontal
   projection. This is the geometric orientation of the door in cell-local space.

**Important:** `door_rotation_mw` (object placement) ≠ `teleport_rot_mw` (player facing).
Object placement rotation tells us which way the door faces in the wall.
Teleport rotation is a gameplay hint (designer can point player at an NPC, table, etc.).

### Walk-Through Detection

`_update_walkthrough()` checks signed distance to door plane each frame:
- Positive = exterior side, negative = interior side
- Crossing from + to - triggers `_seamless_enter()` (or `enter_interior()` for non-seamless doors)
- Exit: crossing back to + past SEAMLESS_PLANE_THRESHOLD (0.3m hysteresis)

### Seamless Enter

No teleport, no fade, no layer swap. Pocket already at door position:
1. Deactivate stencil portal (interior renders normally)
2. Camera on COMBINED layers (sees both worlds)
3. Hide exterior building mesh + collision near door
4. Hide interior wall near door (clip shader for view-out hole)
5. Player physics: combined exterior + interior layers
6. Sun excluded from interior layers (OmniLights handle interior)

### Seamless Exit

Player crosses back to exterior side of door plane:
1. Instant black screen (masks mesh restore)
2. Restore camera to exterior layers
3. Restore building meshes, collision, sun, interior lights
4. Pocket returns to Y=-500
5. Fade-in (0.2s)

### Building Identification & Hiding

Data-driven approach for seamless mode:

- `BUILDING_PATTERNS` (Array[String]): Substring patterns matching ESM STAT model paths
  for buildings that support seamless transitions (Hlaalu, Redoran, Imperial, etc.)
- `NON_SEAMLESS_PATTERNS`: Caves, tombs, terrain entrances, ship trapdoors (horizontal
  doors) → use fade-to-black
- `DoorInfo.building_ref_id`: Set at registration from ESM data, stored as node metadata
- Building found by: metadata ref_id match (primary) → AABB coverage check → AABB fallback
- All descendant MeshInstance3D + StaticBody3D hidden during seamless

---

## Async Load Pipeline (post-2026-04-06 P0 fix)

`InteriorPocketManager._load_pocket()` routes through `CellManager.request_cell_async`
with an interior `LoadProfile`. Main-thread work is budgeted across 1–2 frames. A
fade-to-black bridge handles the case where the player E-presses a door before the
load completes.

**Shipped API surface & behavior:**

- `CellManager.LoadProfile` — inner class with `fade_in`, `use_static_renderer`,
  `max_actor_distance`, `interior_priority`. Static factories
  `LoadProfile.exterior_default()` / `LoadProfile.interior_pocket()`. Stored on
  `AsyncCellRequest` and mirrored onto each `InstantiationEntry` at queue time.
- `CellManager.request_cell_async(cell_name, profile)` — the public entry point for
  pocket loads. The interior profile disables RS batching so interior objects render
  at the pocket offset, not the ESM world position.
- `CellManager.set_request_priority(request_id, bool)` + `force_queue_resort()` —
  used by the bridge to boost an in-flight interior load ahead of exterior work.
- `ReferenceInstantiator._current_load_profile` — transient read by
  `_effective_max_actor_distance()` / `_effective_use_static_renderer()`.
  `_set_transient_profile` / `_clear_transient_profile` pair wraps each queue drain
  with a debug assert catching leaked transients.
- `InstantiationEntry.interior_priority` — priority-lane flag.
  `_sort_queue_by_priority` stable-sorts on `(interior_priority desc, distance)` so
  in-flight interior entries jump to the tail of the queue (where `pop_back()` takes
  from) during a transition.
- `InteriorPocketManager._begin_pocket_finish_up(slot, collapse)` — 2-phase spread:
  - **F0:** place, `visible=false`, `add_child`, single-pass `_finalize_cell_node`
    walk (render layers on all VisualInstance3D, `light_cull_mask` on Light3D,
    physics layers on CollisionObject3D, AABB accumulation on MeshInstance3D — one
    walk replaces three), build environment, register interior doors.
  - **F1 (next frame, OR same frame if `collapse`):** `_add_lightbox_from_aabb`
    using F0's cached AABB, LightAnimator, LightShadowBudget, `visible=true`, mark
    occupied, emit `pocket_loaded`.
  - **Fast path:** if the player is within
    `INTERACT_RADIUS * FAST_PATH_RADIUS_MULT (=2.0)` of the door at completion,
    F0+F1 run synchronously on the same frame.
- **Fade-to-black bridge** (`_prepare_target_pocket_for_transition`): if the slot is still loading when E
  is pressed (exterior→interior or interior→interior):
  1. Set `_is_transitioning=true`, emit `transition_started`
  2. Boost via `set_request_priority(rid, true)` + `force_queue_resort()`
  3. `await _fade(0, 1, FADE_DURATION)` — 300 ms out
  4. Poll completion with a generous hard timeout (`INTERIOR_LOAD_TIMEOUT`)
  5. On timeout: log error, emit `interior_load_timeout(cell_name, rid)` signal,
     `cancel_async_request`, clear slot, fade back in, return false
  6. On success: teleport + fade-in via `_do_transition`
- **`_get_slot_for_cell_any(cell_name)`** — relaxed lookup that matches
  `is_loading OR finish_up_phase >= 0 OR is_occupied`. Required for the bridge —
  strict `_get_slot_for_cell` only matches occupied and would drop the bridge into
  the error path.
- **Stuck-load eviction** — `_evict_oldest_pocket` falls back to cancelling the
  oldest in-flight load (via `CellManager.cancel_async_request`) if no
  fully-occupied slot is available. Prevents both pocket slots wedging in
  `is_loading` if the player rushes past multiple doors.
- **Test scene pump** — `tests/visual/test_interior_transition.gd._process()` calls
  `CellManager.process_async_instantiation(4.0, camera_pos, camera_fwd)` every
  frame. Without this, the async pipeline's main-thread drain never runs in the
  test scene (main scene gets it from NativeStreamingManager).
- **Main-scene freeze mode** — `world_explorer.gd` calls
  `NativeStreamingManager.set_world_tracking_frozen(true, anchor_position)` before
  entering an interior and unfreezes only after a real exterior exit or failed enter.
  While frozen, the manager skips camera-cell updates, exterior load requests,
  unload ticks, preloader ticks, and distant-tier camera tracking. It keeps async
  completions and cell instantiation processing alive.

---

## Interior Lighting

### Shadow Budget (`LightShadowBudget`)

Configurable per-instance thresholds:

| Setting | Exterior Default | Interior Default |
|---------|-----------------|-----------------|
| CUBE shadow range | 0-10m | 0-20m |
| DUAL_PARABOLOID range | 10-30m | 20-50m |
| Max shadow lights | 8 | 16 |

Morrowind interiors have 5-15 lights — generous budget is fine.
Hysteresis: 2m buffer prevents shadow flickering at tier boundaries.
Updated every 0.5 seconds (not every frame).

### Light Animator (`LightAnimator`)

Matches OpenMW behavior at effective 15 FPS with temporal smoothing:
- Flicker: random brightness in [0.25, 1.0]
- Pulse: triangle wave between 0.25 and 1.0
- Fast/slow variants via MW light flags

---

## Known Issues

### Seamless Mode — Visual

1. **Interior wall clip not revealing outside:** Clip box axis mapping may be swapped.
   Transform propagation may be stale after pocket repositioning.
2. **Stencil plane mispositioned on some doors:** ESM position ≠ visual mesh position.
   Census exit stencil drifts from doorframe.
3. **Lighthouse stencil rotated 90°:** AABB ambiguity on lighthouse door mesh.
   Needs ESM yaw fallback applied to stencil plane orientation too.
4. **Stencil renders in front of everything:** `no_depth_test=true` means objects in
   front of doors (barrels, characters) don't occlude the portal preview.
   Supplementary wall clip helps where geometry allows. Full fix needs per-building tuning.
5. **Depth sorting between interior objects:** `no_depth_test=true` breaks
   inter-object sorting. 50% dimming + interior lightbox backdrop mask artifacts.
   ShaderMaterial meshes hidden during portal preview to prevent stencil leaks.

### Seamless Mode — Geometry & Building Hiding

6. **Missing exterior objects from inside:** `_hide_building_near_door()` hides too
   aggressively (pontoons near Census hidden along with building). Need tighter
   AABB or smarter filtering (only hide the building container, not nearby objects).
7. **Stray models in pocket interiors:** Some pockets show models that shouldn't be
   there (exterior objects or objects from other cells). May be cell loading pulling
   in references from wrong cells, or ESM data including exterior markers.
8. **Not all houses detected in test scene:** Some exterior doors may not register
   if their cells aren't in the loaded radius. Verify with main scene (world_explorer).

### Seamless Mode — Lighting

9. **Interior lighting not faithful:** Interior AMBI data (ambient, sun, fog colors)
   isn't fully applied in seamless mode. Classic mode swaps the full WorldEnvironment;
   seamless mode keeps COMBINED layers with exterior environment. Need distance-based
   environment blend or separate interior-only lighting solution for seamless.

### Seamless Mode — Doors

10. **MW door meshes are single-faced:** Interior/exterior doors in Morrowind are
    typically one-sided quads (visible from one direction only). In seamless mode,
    walking through reveals the invisible backface. Need either: (a) find the "full"
    double-sided door model variant if it exists in MW data, or (b) generate a
    mirrored backface at runtime, or (c) hide both int/ext door meshes and replace
    with a double-sided animated door.
11. **Door animation needed for seamless:** Walking through a door should animate it
    opening. NIF mesh origin = hinge edge. Rotate `closed_basis * Basis(Y, +90°)`.
    Currently no door animation in seamless mode (door mesh is just hidden).

### Classic Mode

12. **Camera height slightly too high:** +1.6m eye offset may double if MW teleport
    position already includes partial height. Needs diagnostic verification.

### Depth Sorting Problem (Seamless)

Interior stencil-read materials use `no_depth_test=true` to bypass exterior wall depth.
This breaks inter-object sorting (render order wins over depth, so walls can overdraw
tapestries, furniture can show through ceilings). Dimmed to 50% to mask artifacts.

**Supplementary wall clip:** `door_clip.gdshader` applied to exterior walls near the
door during portal activation. Helps with depth sorting where geometry allows, but
not relied upon for visibility (MW building geometry is too varied for pixel-perfect
clip boxes). Wall clip code is active but supplementary.

**Lightbox backdrop:** Interior lightbox on `INTERIOR_RENDER_LAYERS` provides a solid
black backdrop behind interior geometry gaps, preventing sky/exterior from showing
through holes in MW interior meshes.

**Future fix:** Proper depth sorting requires either per-building clip tuning or
Godot-level stencil/depth enhancements (e.g., stencil-read with depth test against
a separate depth layer).

### Failed Approaches (seamless depth sorting)

- **Depth-clear shader — FAILED.** Quad at door writes `DEPTH=1.0` to replace wall
  depth. Attempt A (`depth_test_disabled`): Godot disables entire depth pipeline
  (read AND write). Attempt B (transparent pass): depth writes don't overwrite
  opaque depth in Forward+. Attempt C (opaque with `sorting_offset`): not fully
  tested, showed black rectangle.
- **Render priority tiers — PARTIAL.** Structural meshes priority 1, decorative
  priority 3. Fixed tapestries but broke ceilings. Can't solve 3D depth with 1D
  priority.

---

## Left To Do / Open Follow-ups

Tracked here (`docs/FUTURE_STEPS.md` no longer exists — consolidated into per-system docs).

1. **Streaming freeze regression coverage** — main-scene travel now uses
   `NativeStreamingManager.set_world_tracking_frozen()` instead of a hard process
   pause. Keep the `--interior-door-smoke` and `--interior-door-smoke-rush` paths
   current so regressions in frozen async draining are caught before manual QA.
2. **MW adapter extraction (`DoorDescriptor` + `WorldDataProvider`)** —
   `InteriorPocketManager` still imports ESM types directly, holds
   `BUILDING_PATTERNS`/`NON_SEAMLESS_PATTERNS` MW STAT prefixes, reads
   `teleport_rot_mw.z` for yaw negation. All of this belongs behind a
   `src/core/world/morrowind/mw_door_adapter.gd` + a `WorldDataProvider` base class
   with a `MWWorldDataProvider` implementation. Scoped out of the P0 session
   because it's orthogonal to the hiccup fix and doesn't affect perf.
3. **First-visit shader warm-up** (Arrille's Tradehouse = 9.77 ms NORMAL on cold
   cache). Under the 16.67 ms per-frame budget, but 1.77 ms over the aggressive
   8 ms threshold. Options if this matters later:
   - Shader prewarm: off-screen SubViewport render of each unique material before visibility flip
   - Raise the threshold to 16 ms (actual per-frame budget at 60 fps)
   - Profile and identify the exact culprit (likely first material compile on visibility flip during fade-in)
4. **BRIDGE path peak (12.16 ms)** — real but bounded and only engages on player
   rush. The `_fade` tween creates a Tween per call; could pool or pre-warm. Low
   priority — real-world players aren't rushing past every door.
5. **`_diag_duplicate_time_total_us` / `_diag_duplicate_count`** on `CellManager`
   — existing diagnostic counters that the transient-profile wrap increments. If
   the assertion ever fires in production they'll give context; otherwise no-op.

---

## Stencil API Reference (Godot 4.6)

Stencil is on `StandardMaterial3D` only (not ShaderMaterial):

```
stencil_mode: 0=Disabled, 3=Custom
stencil_flags: 1=Read, 2=Write, 4=WriteDepthFail (bitmask)
stencil_compare: 0=Always, 2=Equal, 5=NotEqual
stencil_reference: int (match value)
```

**Critical caveat:** Stencil READ requires `transparency=ALPHA` (Godot issue #107731).
Opaque materials skip stencil read even with Custom mode. This pushes interior
materials into the transparent queue, which affects depth sorting.

---

## Key Files

| File | Purpose | Lines |
|------|---------|-------|
| `src/core/world/interior_pocket_manager.gd` | Pocket lifecycle, transitions, classic/seamless toggle, async load pipeline | 2544 |
| `src/core/world/door_portal.gd` | Stencil portal rendering (outside-looking-in) | 1085 |
| `src/core/world/door_utils.gd` | Door mesh finding, orientation helpers | 226 |
| `src/core/world/shaders/door_clip.gdshader` | Fragment discard for wall clipping | — |
| `src/core/world/light_animator.gd` | Interior light flicker/pulse (OpenMW-matched) | 128 |
| `src/core/world/light_shadow_budget.gd` | Configurable per-instance shadow budget | 161 |
| `tests/visual/test_interior_transition.gd` | Visual test (F5 toggle, E activate, TAB cycle, frametime readout) | — |
| `tests/visual/test_interior_transition.tscn` | Test scene | — |
