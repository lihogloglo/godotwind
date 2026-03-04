# Session 2026-03-04 — #notexture Channel Summary

## Team
- **Arbiter**: Performance investigation, root cause analysis
- **Coder**: Implementation, diagnostics, bug fixes
- **Roaster**: Code review, verification

---

## Bugs Investigated

### Bug 1: Missing Faces on Reload
**Symptom:** Buildings look fine on initial load at Seyda Neen. After flying away (LOD/impostor transitions) and flying back, buildings have missing faces — even at close range.

### Bug 2: Plain Colored LODs
**Symptom:** MID-tier LODs of large buildings (Vivec, Pelagiad castle, Balmora houses) are plain colored — no textures, just flat color at 150-500m range.

---

## Root Cause Found (Arbiter)

**`_extract_lod_meshes()` in `static_object_renderer.gd` stored only ONE mesh per LOD level.**

`lod_meshes` was `Dictionary[int → LodMeshEntry]`. For a building with 5 material groups (wall/roof/door/window/trim), all were LOD level 0. Each overwrote the previous — only the last mesh survived.

- **Bug 2 explained:** At MID range (150-500m), only 1/N material groups rendered via RS. Buildings appeared sparse/plain.
- **Bug 1 explained:** On initial load at NEAR range, full Node3D rendered ALL meshes. On re-approach from distance, the broken MID RS path (1/N meshes) was visible first.

---

## Fixes Applied

### Fix 1: Multi-Mesh LOD Support (Coder) — VERIFIED WORKING
**File:** `src/core/world/static_object_renderer.gd`

Changed `lod_meshes` from `Dict[int → LodMeshEntry]` to `Dict[int → Array[LodMeshEntry]]`:
- `_extract_lod_meshes()`: Appends to array per LOD level instead of overwriting
- `add_instance()`: Creates RS instances for ALL meshes at each LOD level
- `set_instance_promoted()`: Hides ALL LOD0 RIDs using `lod0_count`
- `register_lod_from_prototype()`: Fallback filling and AABB work with arrays

**Result:** User confirmed missing faces are GONE.

### Fix 2: Material Validity Filter (Coder) — NOT FULLY WORKING
**File:** `src/core/world/static_object_renderer.gd`

Added `MeshVisibilityUtils.has_valid_material(mi, false)` check in `_extract_lod_meshes()` to skip materialless/white meshes before RS registration. The raw prototype passed to `register_lod_from_prototype()` hasn't been processed by `_hide_lod_nodes()`, so white placeholder meshes were getting registered.

**Result:** User reports plain colored overlay STILL present with z-fighting. Fix was insufficient.

### Fix 3: Object Picker Rewrite (Arbiter) — WORKING
**File:** `src/core/console/object_picker.gd` (full rewrite)

Replaced physics raycasting (always hit Terrain3D) with AABB-based mesh proximity picking:
- Hover tooltip when console is open
- Click-to-select in 3D viewport
- Console-aware (ignores clicks inside console panel)
- Material restoration on deselect (bug found by Roaster, fixed by Arbiter)

### Fix 4: PerfSnapshot Quit Bug (Coder)
**File:** `tests/perf_snapshot.gd`

`perf_snapshot.gd` autoload was calling `get_tree().quit()` after 15s in ALL scenes (including prebaking). Now only quits with `--perf-quit` CLI flag.

### Fix 5: Compile Error Fix (Coder)
**File:** `src/tools/lod_debug_commands.gd`

Stale variable name `buildings_checked` → `counts["buildings"]` after the multi-mesh refactor.

---

## What's Left To Do

### P0: Plain Colored Mesh Overlay (STILL BROKEN)
The `has_valid_material` filter didn't fully solve the overlay issue. Plain colored meshes still render on top of textured ones with z-fighting.

**Remaining hypotheses to investigate:**
1. The white/plain meshes might NOT have `Color.WHITE` exactly — they could have a slightly off-white color that passes the `color == Color.WHITE` check in `_is_material_renderable()`. The threshold was changed from 0.95 to exact white to avoid hiding legitimate near-white surfaces, but this means near-white placeholder meshes also pass.
2. The meshes might have a non-null texture that's blank/white — `has_valid_material` returns `true` if `albedo_texture` is non-null regardless of content.
3. The prototype passed to `register_lod_from_prototype()` might have materialless meshes that DON'T get caught by `has_valid_material` because they have ShaderMaterial (line 67: ShaderMaterial always returns true).
4. Some meshes might be collision geometry nodes that have a mesh but shouldn't render. These aren't caught by material checks.

**Diagnostic approach:** Use `mid_lod_textures` console command to audit which LOD entries exist per building type, their material state, and whether they should be filtered. Also check if the plain overlay mesh is a separate Node3D or part of the same prototype tree.

### P1: Performance Issues (From Arbiter's Analysis)
- **2.5 GB VRAM / textures** — prebaked .res files embed uncompressed ImageTexture. Convert to CompressedTexture2D (S3TC/BC) during prebake for 4-8x reduction.
- **20,122 orphan nodes** — nodes instantiated but not freed. Audit cell unload path.
- **3,392 occluder RID leaks** — RS resources not cleaned up on cell unload.
- **Frame budget overruns** — 55 overruns logged, almost every frame exceeds 8ms budget during loading.
- **Multi-mesh fix increases RS instance count** — 5 materials × 4 LOD levels = 20 RS instances per building (was 4). Draw calls will increase. Monitor after overlay fix.

### P2: Double-Rendering at 150-500m (Pre-existing)
When a NEAR Node3D is promoted, both the Node3D's LOD children AND the RS LOD1-3 instances render at 150-500m. For opaque geometry this is just wasted GPU. Could hide RS LOD1-3 on promotion if the Node3D has its own LOD children.

### P2: LOD Texture Propagation
The LOD generation in `nif_converter.gd:1268-1293` copies materials to LOD meshes. But some LOD meshes in the cached .res files still appear textureless. Need to verify whether the .res files on disk have correct materials or if they're being lost during serialization/deserialization.

---

## Key Files Modified This Session
| File | Change |
|------|--------|
| `src/core/world/static_object_renderer.gd` | Multi-mesh LOD arrays + material validity filter |
| `src/core/console/object_picker.gd` | Full rewrite: AABB picking, hover, click-to-select |
| `src/core/console/console.gd` | Wired up cell provider and hover mode |
| `src/core/world/native_streaming_manager.gd` | Added `get_loaded_cell_nodes()` |
| `tests/perf_snapshot.gd` | Quit only with `--perf-quit` flag |
| `src/tools/lod_debug_commands.gd` | Compile error fix + diagnostic commands |
