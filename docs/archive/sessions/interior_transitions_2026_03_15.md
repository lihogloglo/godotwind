# Interior Transitions — Session Summary (2026-03-15)

## What We Did

### Door Opening (WORKING)
- Decoupled door swing from portal activation — doors now open at 3m proximity, close at 5m (hysteresis)
- Fixed mesh finding: searches Node3D containers (not just MeshInstance3D), excludes "doorframe"/"doorstep"/"doorjamb"
- Fixed AZERTY: test scene uses `Input.is_physical_key_pressed()` instead of `Input.is_key_pressed()`
- Known: door rotates on center axis, not hinge edge (pivot point issue — low priority)

### Stencil Portal (PARTIALLY WORKING)
Replaced SubViewport-based portal with stencil buffer approach:

1. **Stencil-write plane** at door opening — writes stencil ref=1
2. **Stencil-read on interior materials** — only renders where stencil matches (through doorframe)
3. **Pocket repositioning** — moves interior pocket from Y=-500 to behind the door, aligning teleport destination with door position. Includes rotation correction so interior orientation matches exterior approach direction.
4. **Camera cull_mask toggle** — layers 1-4 when portal active, layers 1-2 otherwise

**Status: Interior geometry IS visible through stencil (confirmed by leak artifacts), but the exterior and/or interior door mesh is blocking the view.** The door swing opens the exterior door, but the interior's own door mesh (from the Morrowind data) sits at the same position and blocks the portal view. Interior door hiding was implemented but may not be finding the right mesh.

### What We Tried and Abandoned
- **Stencil-only with offset pockets (Y=-500):** Doesn't work — stencil masking can't relocate geometry. The camera can't see geometry 500m below through a door at ground level.
- **SubViewport approach:** Was 90% working but @user wanted real geometry, not a texture image of it.

## Current Code State

| File | Status | Description |
|------|--------|-------------|
| `src/core/world/door_portal.gd` | Rewritten | Stencil portal + pocket repositioning (was SubViewport) |
| `src/core/world/interior_pocket_manager.gd` | Modified | Added door swing (`_update_door_swings`), door swing constants, `_open_doors` tracking |
| `tests/visual/test_interior_transition.gd` | Modified | AZERTY fix (physical keys) |
| `docs/INTERIOR_TRANSITIONS.md` | Updated | Full options analysis, stencil API reference, phased plan |

## Remaining Bugs (Priority Order)

### 1. Door mesh blocking stencil portal view
**Symptom:** Interior visible through stencil (confirmed by leak) but door mesh blocks the view.
**Likely cause:** Interior door mesh not being found/hidden by `_hide_interior_doors()`. Could also be exterior door not swinging, or stencil plane positioned behind the closed door.
**Debug approach:** Add logging to `_hide_interior_doors()` to see what it finds. Verify exterior door swing triggers. Check stencil plane Z-position relative to door mesh.

### 2. Stencil leak (some interior objects visible outside doorframe)
**Cause:** `ShaderMaterial` and null-material meshes skip stencil-read application (code only handles `StandardMaterial3D`).
**Fix:** Either hide non-StandardMaterial3D meshes when portal is active, or apply stencil via shader injection.

### 3. Door mesh finding is fragile
**Cause:** `_find_door_mesh_near()` does a full scene tree walk searching by name + proximity. Should track door mesh Node3D at cell load time via CellReference ref_id.

### 4. print() cleanup
Removed most debug prints but verify no stray ones remain.

## Stencil API Reference (Godot 4.6)

Confirmed present in `StandardMaterial3D`:
- `stencil_mode`: 0=Disabled, 3=Custom
- `stencil_flags`: 1=Read, 2=Write
- `stencil_compare`: 2=Equal
- `stencil_reference`: integer (0-255)

**Critical caveat:** Stencil READ requires alpha queue (`transparency=ALPHA`). Use `alpha=1.0` + `depth_draw=ALWAYS` for visually opaque materials. See Godot issue #107731.

**Render order:** Lower `render_priority` renders first in alpha queue. Stencil-write plane: `render_priority=-10`. Interior stencil-read: `render_priority=1`.

## Next Steps (Future Sessions)

1. **Fix door blocking** — debug interior door hiding, verify exterior door swing timing vs portal activation
2. **Fix stencil leaks** — handle ShaderMaterial/null material meshes
3. **Track door meshes at registration** — store Node3D ref in DoorInfo at cell load time
4. **Interior→exterior portal** (Phase 2) — reverse stencil portal for exit doors
5. **Seamless walk-through** (Phase 3) — door plane trigger, frame-perfect layer swap + teleport
6. **Window parallax** (Phase 4) — SubViewport for windows (keep existing code)

## Architecture Decision

**Chosen approach:** Stencil portal with pocket repositioning.
- Pocket moves from Y=-500 to behind the door when portal activates, moves back on deactivate
- Stencil masking ensures interior only visible through doorframe
- Render layers (exterior 1-2, interior 3-4) prevent visual bleed outside stencil mask
- Physics layers prevent collision overlap
- Single-portal-at-a-time (Phase 1) — pocket repositioned for nearest door only

**Why not SubViewport:** User wanted real geometry visible through doors, not a texture. SubViewport approach kept for windows (Phase 4).

**Why not stencil-only at Y=-500:** Stencil can't bridge spatial gaps — geometry must be in the camera frustum behind the door.
