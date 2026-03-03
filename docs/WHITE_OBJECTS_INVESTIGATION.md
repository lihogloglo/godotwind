# White/Textureless Objects Investigation

## Problem Statement

Two visual issues persist after the distant rendering overhaul:

1. **White objects in NEAR tier** — objects close to camera appear fully white (no texture, no color)
2. **Textureless objects in MID tier** — LOD2/LOD3/LOD4 meshes show a single flat color (correct albedo_color but no albedo_texture)

## What Has Been Tried

### Fix 1: Always-RS Architecture (IMPLEMENTED)
- Objects always get RenderingServer instances regardless of distance tier
- Before: objects outside MID range got no RS instance → invisible in MID tier
- File: `static_object_renderer.gd`

### Fix 2: FADE_SELF for Standalone Objects (IMPLEMENTED)
- Changed `lod_configurator.gd` to use `VISIBILITY_RANGE_FADE_SELF` (dither) for objects without LOD siblings
- Objects WITH `_LOD1/_LOD2/_LOD3` siblings use `VISIBILITY_RANGE_FADE_DEPENDENCIES` (crossfade)
- `_has_lod_siblings()` scans parent's children for LOD suffixes
- `cell_manager.gd` meta guard removed — `LODConfigurator.configure_for_prebake(obj)` runs unconditionally
- Files: `lod_configurator.gd` (lines 50-63, 313-323), `cell_manager.gd` (line 1355-1359)

### Fix 3: Relaxed White-Material Filter (IMPLEMENTED)
- Changed white-material filter to only skip exact `Color.WHITE` (was too aggressive, filtering out near-white textured materials)
- File: `static_object_renderer.gd`

### Fix 4: 3-Source Material Fallback for Fade-in (IMPLEMENTED)
- Material lookup now checks: `material_override` → `surface_override_material(0)` → `mesh.surface_get_material(0)`
- Applied in both `static_object_renderer.gd` and `nif_converter.gd` LOD generation

### Fix 5: Startup Burst Loading (NOT YET DONE)
- Frame budget overruns during initial streaming burst (12-17ms vs 8ms budget)
- Tuning task deferred

### Fix 6: Full Model Rebake (DONE — DID NOT FULLY RESOLVE)
- Hypothesis: stale cache from Feb 7 had models baked before texture embedding fixes
- Deleted entire cache (`C:\Users\metzo\Documents\Godotwind\cache\models\`)
- Ran full rebake via `prebaking_ui.tscn`: **4846/4910 models** baked successfully
- 64 failures: glass/ebony armor items with unsupported NIF record types
- Post-rebake diagnostic: only 1 model (`l_light_com_lantern_02_nif.res`) has no texture (intentional colored glass)
- **Result: Diagnostic says textures ARE embedded, but white/textureless objects STILL visible in-game**

### AABB Upgrade (IMPLEMENTED)
- Runtime >2m AABB threshold catches large objects that prefix filter missed
- `streaming_config.gd`: `AABB_MID_WORTHY_THRESHOLD := 2.0`

### Mushroom Prefix (IMPLEMENTED)
- Added `flora_mushroom` to streaming policy prefix list

### Diagnostic: `_check_textureless_materials()` (ADDED)
- Added to `model_loader.gd` after `_debug_log_mesh_nodes()`
- Called from `_load_from_disk_cache()` before `_clear_resource_paths()`
- Logs warnings for models with `StandardMaterial3D` that have no `albedo_texture`
- After rebake: only 1 warning (lantern) — suggests textures ARE in .res files

### Diagnostic: `tex_audit` Console Command (ADDED by @arbiter)
- `lod_debug_commands.gd` line 585-663
- In-game console command that audits loaded objects: textured, color-only, no-material, magenta-fallback
- **Not yet run in-game** — user should try this

## Key Observations

### The Paradox
The `_check_textureless_materials()` diagnostic finds almost no textureless models in the .res cache, yet the user sees white/textureless objects in-game. This means the problem is likely NOT in the .res files but in the **runtime pipeline** — somewhere between loading from cache and rendering.

### Possible Root Causes Still Unexplored

1. **`_clear_resource_paths()` side effect** — `model_loader.gd` calls this after loading from cache. It clears `resource_path` on sub-resources. Could this break texture references in some edge case? The function only clears paths (not data), but worth investigating.

2. **`duplicate()` losing texture refs** — Prototype cache stores one instance, then `duplicate()` creates copies. If `duplicate()` doesn't deep-copy materials/textures correctly, copies could lose textures. Check `DUPLICATE_SIGNALS | DUPLICATE_GROUPS | DUPLICATE_SCRIPTS` flags.

3. **Material override vs surface material priority** — When `material_override` is set but is a DIFFERENT material than the mesh surface material, which one wins? If `material_override` is a white/empty material from the fade-in pool, it may override the textured surface material.

4. **Fade-in material pool** — Phase 6 added 200 pre-allocated ShaderMaterials for fade-in animation. If these aren't properly removed after fade completes, objects stay white. Check `cell_manager.gd` fade cleanup.

5. **LOD mesh material copy** — `nif_converter.gd:_add_visibility_range_lods()` copies material to LOD meshes. If the source mesh has per-surface materials (not `material_override`), the LOD copy may grab the wrong surface or miss surfaces entirely.

6. **MID tier RS instance material** — `static_object_renderer.gd` extracts materials and applies via RS override functions. If extraction fails (returns null), the RS instance renders with default white material.

7. **Prebake visibility_range embed** — Phase 4 bakes visibility_range into PackedScene. If this conflicts with runtime LOD configuration, some objects may not transition correctly between tiers.

## Texture Pipeline (Full Trace)

```
NIF file
  → C# NIF parser (binary)
  → nif_material metadata on MeshInstance3D
  → _create_material_from_native_info() → TexLoader.load_texture() → ImageTexture
  → material_override on MeshInstance3D
  → _prepare_resources_for_embedding():
      - resource_local_to_scene = true
      - resource_path = ""  (for materials AND textures)
  → PackedScene.pack() → ResourceSaver.save() → binary .res file

Runtime load:
  → ResourceLoader.load() → packed_scene.instantiate()
  → _clear_resource_paths() (clears path strings, NOT texture data)
  → prototype cache (Dictionary)
  → duplicate() for each placement
  → cell_manager adds to scene tree
  → LODConfigurator sets visibility_range
  → static_object_renderer creates RS instances for MID tier
```

## Files to Investigate Next

| File | What to check |
|------|--------------|
| `model_loader.gd` | `duplicate()` flags, `_clear_resource_paths()` side effects |
| `cell_manager.gd` | Fade-in material cleanup, object instantiation path |
| `static_object_renderer.gd` | RS instance material extraction, null material fallback |
| `nif_converter.gd` | LOD material copy for multi-surface meshes |
| `lod_configurator.gd` | Interaction between prebaked and runtime visibility_range |
| `mesh_visibility_utils.gd` | Utility functions for visibility configuration |

## Recommended Next Steps

1. **Run `tex_audit` in-game** — press `` ` ``, type `tex_audit`, get hard numbers on textured vs untextured objects
2. **Add logging at `duplicate()` call** — check if materials survive duplication
3. **Add logging at RS instance creation** — check if `static_object_renderer` receives null materials
4. **Check fade-in cleanup** — verify ShaderMaterial overrides are removed after fade animation
5. **Inspect a specific white object** — use console to identify one white mesh, trace its full material chain from .res to rendered instance
