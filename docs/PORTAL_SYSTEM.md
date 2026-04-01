# Stencil Portal System — Design & Status

## What It Does

Renders Morrowind interiors visible through exterior doorways without loading screens.
When the player approaches a door, the interior loads into a "pocket" at Y=-500,
gets repositioned so its exit door aligns with the exterior door, and renders
through a stencil mask at the doorframe.

Two modes: **Classic** (default, fade-to-black teleport) and **Seamless** (experimental,
walk-through with stencil portal preview).

## Architecture

```
InteriorPocketManager (Node)     — Orchestrator: pockets, doors, transitions, walk-through
DoorPortal (RefCounted)          — Stencil plane + material management (outside-looking-in)
DoorUtils (static helpers)       — Door mesh finding, orientation computation
door_clip.gdshader               — Fragment discard shader for wall clipping
light_animator.gd                — Interior light flicker/pulse effects (OpenMW-matched)
light_shadow_budget.gd           — Per-instance shadow budget (configurable thresholds)
```

## Classic Mode (Default)

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

## Seamless Mode (Experimental)

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

1. **AABB thinnest-axis** (line 415, `_compute_alignment_rotation`): Measures door mesh
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

## The Depth Sorting Problem

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

## Approaches Tried & Failed

### Depth-Clear Shader (FAILED)
Quad at door writes `DEPTH=1.0` to replace wall depth:
- **Attempt A:** `depth_test_disabled` — Godot disables entire depth pipeline (read AND write)
- **Attempt B:** Transparent pass — depth writes don't overwrite opaque depth in Forward+
- **Attempt C:** Opaque with `sorting_offset` — not tested, showed black rectangle

### Render Priority Tiers (PARTIAL)
Structural meshes priority 1, decorative priority 3. Fixed tapestries but broke ceilings.
Can't solve 3D depth with 1D priority.

## Building Identification & Hiding

Data-driven approach for seamless mode:

- `BUILDING_PATTERNS` (Array[String]): Substring patterns matching ESM STAT model paths
  for buildings that support seamless transitions (Hlaalu, Redoran, Imperial, etc.)
- `NON_SEAMLESS_PATTERNS`: Caves, tombs, terrain entrances → use fade-to-black
- `DoorInfo.building_ref_id`: Set at registration from ESM data, stored as node metadata
- Building found by: metadata ref_id match (primary) → AABB coverage check → AABB fallback
- All descendant MeshInstance3D + StaticBody3D hidden during seamless

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

## Known Issues (2026-03-30)

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
10. **Environment blend not wired:** `_blend_environment()` exists but not called in
    seamless path.

### Seamless Mode — Doors
11. **Ship trapdoor (horizontal door):** Alignment assumes Y-axis yaw only.
    Should be classified as `NON_SEAMLESS_PATTERNS`.
12. **MW door meshes are single-faced:** Interior/exterior doors in Morrowind are
    typically one-sided quads (visible from one direction only). In seamless mode,
    walking through reveals the invisible backface. Need either: (a) find the "full"
    double-sided door model variant if it exists in MW data, or (b) generate a
    mirrored backface at runtime, or (c) hide both int/ext door meshes and replace
    with a double-sided animated door.
13. **Door animation needed for seamless:** Walking through a door should animate it
    opening. NIF mesh origin = hinge edge. Rotate `closed_basis * Basis(Y, +90°)`.
    Currently no door animation in seamless mode (door mesh is just hidden).

### Classic Mode
14. **Camera height slightly too high:** +1.6m eye offset may double if MW teleport
    position already includes partial height. Needs diagnostic verification.

### Both Modes
15. **Pocket loading is synchronous:** `_cell_manager.load_cell()` blocks the main
    thread. Mitigated by 10m preload radius (loads before player reaches door).
    Proper fix: async budgeted instantiation pipeline.

---

## TODO / Roadmap

### Phase 1: Core Robustness (fix what exists) — DONE 2026-03-30
- [x] Fix interior wall clip axis mapping — `force_update_transform()` + use mesh global_transform.basis
- [x] Fix stencil plane positioning — `DoorUtils` now checks node metadata `ref_id` (not just name prefix)
- [x] Fix stencil plane rotation — `compute_door_basis()` uses `mi.global_transform.basis` instead of raw ESM basis
- [x] Fix stencil occluding objects in front of doors (PARTIAL) — stencil plane inset 0.1m. Full fix needs Phase 2.
- [x] Tighten building-hide AABB — allow-list filtering via `model_path` metadata + `BUILDING_PATTERNS`
- [x] Investigate stray models in pocket interiors — diagnostic logging added, needs visual verification
- [x] Add ship/trapdoor to NON_SEAMLESS_PATTERNS
- [x] Wire environment blend in seamless path — `_blend_environment()` called in enter/exit

### Phase 2: Visual Quality
- [ ] Exterior wall clip → proper depth sorting (code exists, supplementary only — MW geometry too varied for pixel-perfect clips)
- [ ] Double-sided animated door for seamless mode
- [x] Interior lighting fidelity (AMBI data in seamless via environment blend) — DONE 2026-03-30
- [ ] Camera height verification (MW teleport pos at feet or partial height?)

### Phase 3: Performance & Scalability
- [ ] Async pocket loading (budgeted instantiation pipeline)
- [ ] Interior-to-interior seamless transitions
- [ ] Multiple simultaneous portals (multiple stencil reference values)
- [ ] Window parallax (SubViewport for windows)

## Key Files

| File | Purpose |
|------|---------|
| `src/core/world/interior_pocket_manager.gd` | Pocket lifecycle, transitions, classic/seamless toggle (~1900 lines) |
| `src/core/world/door_portal.gd` | Stencil portal rendering (~550 lines) |
| `src/core/world/door_utils.gd` | Door mesh finding, orientation helpers (212 lines) |
| `src/core/world/shaders/door_clip.gdshader` | Fragment discard for wall clipping |
| `src/core/world/light_animator.gd` | Interior light flicker/pulse |
| `src/core/world/light_shadow_budget.gd` | Configurable shadow budget |
| `tests/visual/test_interior_transition.gd` | Visual test (F5 toggle, E activate, TAB cycle) |

## Stencil API Reference (Godot 4.6)

Stencil is on `StandardMaterial3D` only (not ShaderMaterial):
```
stencil_mode: 0=Disabled, 3=Custom
stencil_flags: 1=Read, 2=Write, 4=WriteDepthFail (bitmask)
stencil_compare: 0=Always, 2=Equal, 5=NotEqual
stencil_reference: int (match value)
```

**Critical caveat:** Stencil READ requires `transparency=ALPHA` (Godot issue #107731).
Opaque materials skip stencil read even with Custom mode.
