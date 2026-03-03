# Session 2026-03-03: White Objects Fix + Transparent Faces Investigation

## Session Overview

Multi-agent debugging session (coder + arbiter + roaster) to fix white/textureless objects in the NEAR and MID tiers, broken console commands, and investigate transparent vertical faces at close distance.

---

## FIXED: White Objects in NEAR/MID Tiers

**Root cause:** Fade-in race condition + pool recycling not clearing stuck fade ShaderMaterials.

**Result:** User confirmed "no white objects anymore" after implementing all 6 fixes below.

### Fix 1: Deferred add_child + fade race (cell_manager.gd)
- **Problem:** When `use_deferred` is true (batches >20), `call_deferred("add_child")` delays tree entry, but fade-in called `create_tween()` immediately — fails because node isn't in tree yet.
- **Fix:** Defer fade-in via `tree_entered` signal with `CONNECT_ONE_SHOT`.

### Fix 2: Guard _apply_fade_in with tree check (reference_instantiator.gd)
- **Problem:** `_apply_fade_in()` could be called on nodes not yet in scene tree.
- **Fix:** Added `is_inside_tree()` guard at top of function. Also added stuck fade detection (checks for leftover `fade_amount` shader parameter) and metadata-based material tracking (`_pre_fade_material`).

### Fix 3: Reset material_override in pool (object_pool.gd)
- **Problem:** Pooled objects recycled with leftover fade ShaderMaterial as `material_override`, making next use white.
- **Fix:** `_reset_materials()` recursive function clears fade ShaderMaterials (identified by `fade_amount` parameter) and removes `_pre_fade_material` metadata.
- **Note:** Roaster flagged initial version was too broad (cleared ALL ShaderMaterials). Tightened to only clear fade-specific ones.

### Fix 4: Store original material as metadata (reference_instantiator.gd)
- **Problem:** Fade completion needed to restore original material, but could lose track during transitions.
- **Fix:** `set_meta("_pre_fade_material", original_mat)` before fade, restore from metadata with fallback on completion.

### Fix 5: Skip hidden meshes in _extract_lod_meshes (static_object_renderer.gd)
- **Problem:** Hidden MeshInstance3D nodes were being processed for LOD extraction.
- **Fix:** Early `return` if `not mi.visible`.

### Fix 6: RS audit in tex_audit command (lod_debug_commands.gd)
- **Problem:** `tex_audit` only audited NEAR tier Node3D objects, not MID tier RenderingServer instances.
- **Fix:** Added `_audit_rs_materials()` function that inspects MID tier mesh types.

---

## FIXED: tex_audit "Command callback is invalid" (world_explorer.gd)

**Root cause:** `LodDebugCommands` was stored in a local `var` (RefCounted) that got garbage collected after `register_commands()`. The console held callbacks to a dead object.

**Fix:** Stored as member variable `_lod_debug_commands` on WorldExplorer.

---

## ADDED: `look` command (lod_debug_commands.gd)

New ray-based mesh inspector that doesn't need collision shapes. Reports:
- Node name, parent, model path, distance
- LOD level detection
- Material source (override vs surface), type, texture, transparency
- Visibility range settings
- Mesh surfaces and AABB

Uses ray-to-mesh-center matching within a 5-degree cone.

---

## FIXED: Multi-surface LOD texture loss (nif_converter.gd)

**Root cause:** `_add_visibility_range_lods()` only processed surface 0 of multi-surface meshes. Vivec buildings with multiple surfaces (stone, trim, windows) lost all but surface 0 in LOD levels.

**Fix:** Rewrote to process ALL surfaces independently — counts triangles across all surfaces, simplifies each surface separately, preserves per-surface materials.

**Status: NEEDS VERIFICATION** — User reported Vivec palace still plain color after rebake. Possible causes:
- Rebake may not have regenerated models (only ran impostors?)
- Multi-surface materials may need a different approach for LOD levels
- The LOD meshes may need the material applied differently

---

## IN PROGRESS: Transparent Vertical Faces (NiStencilProperty.draw_mode)

### Problem
At close distance, many model faces (walls, tree trunks) are invisible/transparent. Buildings appear as wireframe "skeletons." This is a NEAR tier issue — full Node3D meshes with missing back faces.

### Root Cause Identified
NiStencilProperty.draw_mode controls face culling in Morrowind NIFs:
- 0 = CCW (cull back) — default
- 1 = CW (cull front) — rare
- 2 = BOTH (double-sided) — walls, leaves, many building parts
- 3 = NONE (no culling)

The draw_mode was correctly parsed by the GDScript NIF reader but **never applied to Godot materials**. Every material defaulted to `CULL_BACK`, so geometry flagged as double-sided lost its back faces.

### Changes Made (4 files)

**C# NativeNIFReader.cs:**
- `ReadNiStencilProperty()` now reads all fields (was `Skip(2+1+4*6)`)
- Added `NiStencilProperty` class with `DrawMode` property

**C# NativeNIFConverter.cs:**
- `ExtractMaterialInfo()` processes NiStencilProperty, adds `draw_mode` to info dict

**GDScript nif_converter.gd:**
- `_get_material_for_shape()`: Collects NiStencilProperty, sets `CULL_DISABLED` for draw_mode 2 or 3
- `_create_material_from_native_info()`: Reads draw_mode from C# info dict, sets cull_mode
- Both MaterialLibrary and fallback paths covered

### Status: NOT WORKING — Needs Investigation

After rebake, user reported:
1. **Transparent faces unchanged** — still invisible at close range
2. **Severe FPS regression** — 130 FPS → 25 FPS (stuttering)
3. **App crash** (may or may not be related)

### Likely Issues to Investigate

1. **CULL_DISABLED on too many materials → FPS drop**: If many models have draw_mode != 0, disabling backface culling roughly doubles GPU fragment work. Need to audit how many materials got CULL_DISABLED and whether the mapping is correct.

2. **Transparent faces may NOT be a cull_mode issue**: The problem could be:
   - **Winding order mismatch**: Morrowind NIFs may have different vertex winding than Godot expects. Faces that appear invisible may have incorrect normals/winding after coordinate conversion (Z-up → Y-up).
   - **Alpha property interaction**: NiAlphaProperty may be setting transparency on geometry that shouldn't be transparent.
   - **mesh_visibility_utils.gd**: `hide_lod_and_materialless()` hides meshes with no material or exact `Color.WHITE` + no texture on surface 0 — could be incorrectly hiding valid meshes.
   - **Material override chain**: `material_override` from fade-in system may be stomping real materials.

3. **MaterialLibrary cache key includes cull_mode**: Setting CULL_DISABLED creates separate cache entries. If a texture was previously cached as CULL_BACK, the CULL_DISABLED variant creates a new entry. This is correct behavior but increases cache size.

4. **Rebake completeness**: The prebake UI may have only rebaked impostors (3843 completed), not models (0 completed). Models may still use old cached .res files without cull_mode. Need to verify model rebake actually ran.

### Recommended Next Steps

1. **Revert the cull_mode changes temporarily** to restore FPS, then investigate more carefully
2. **Audit winding order** in the NIF → Godot conversion (coordinate_system.gd, nif_converter mesh building)
3. **Count how many NiStencilProperty records have draw_mode=2** across all Morrowind models to understand scope
4. **Check if the transparent faces exist BEFORE our changes** — if they were always there, the issue predates this session
5. **Profile the FPS regression** — determine if it's from CULL_DISABLED, material cache bloat, or something else
6. **Verify model rebake** actually regenerated the .res files (check timestamps in cache dir)

---

## Files Modified This Session

| File | Changes |
|------|---------|
| `src/core/world/cell_manager.gd` | Fix 1: Deferred fade via tree_entered signal |
| `src/core/world/reference_instantiator.gd` | Fix 2+4: Tree guard, stuck fade detection, metadata tracking |
| `src/core/world/object_pool.gd` | Fix 3: Material reset on pool release |
| `src/core/world/static_object_renderer.gd` | Fix 5: Skip hidden meshes |
| `src/tools/lod_debug_commands.gd` | Fix 6: RS audit + new `look` command |
| `src/tools/world_explorer.gd` | GC fix: Store LodDebugCommands as member var |
| `src/core/nif/nif_converter.gd` | Multi-surface LOD fix + cull_mode from NiStencilProperty |
| `src/native/NativeNIFReader.cs` | Read NiStencilProperty fields (was skipping) |
| `src/native/NativeNIFConverter.cs` | Pass draw_mode in material info dict |
