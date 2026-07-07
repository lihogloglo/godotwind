# Terrain3D: Building From Source for Godotwind

This document compiles everything learned from multiple sessions of building Terrain3D from source (v1.1.0-dev) for use with Godotwind. Its purpose is to help future agents successfully build and integrate a custom Terrain3D build.

**Goal:** Use Terrain3D's v1.1-dev features (tessellation, displacement, ocean clipmap) with Godotwind's non-standard vertex_spacing (~1.828m).

**Current state (2026-04-03):** Reverted to v1.0.1 stable release. Custom build abandoned due to accumulated DLL bugs. This guide documents what went wrong and what needs to be done differently next time.

---

## Why Build From Source?

Terrain3D v1.0.1 (the current stable release, June 2025) lacks features we need:

| Feature | Why We Want It |
|---------|---------------|
| `tessellation_level` (0-6) | Dense near-camera mesh for deformation (footprints, cobblestones) — Morrowind terrain is 1.83m/vertex, too coarse for visible detail. Eliminates the need for overlay meshes. |
| `displacement_scale/sharpness` | Heightmap displacement from texture alpha channels (cobblestone bumps, rocky ground). Per-texture offset and scale for different ground types. |
| `ocean_enabled/mesh_lods/vertex_spacing` | Integrated ocean clipmap with terrain — depth-buffer shore blending, no separate ocean mesh needed |
| Custom shader uniforms | v1.0.1's shader has ZERO deformation uniforms. Our RTT deformation injection via `material_set_param()` silently does nothing. v1.1 adds `group_uniforms displacement` block. |
| Vertex spacing fixes | v1.1 fixes import_images() position calculations (#770, #897, #898), decal positioning (#954), and removes vertex spacing rounding. |
| Godot 4.6 compatibility | Issue #931 tracks 4.6-specific bugs being fixed on main branch. |

Without tessellation, the only alternative for terrain deformation is an overlay mesh approach (separate dense disc rendered on top of terrain). This works but has visual compositing challenges (z-fighting, texture matching).

---

## v1.1 Development Status (April 2026)

| Version | Status | Notes |
|---------|--------|-------|
| v1.0.1 | Latest stable release | Works with Godot 4.6, vertex_spacing works natively |
| v1.1 | 83% complete (66/79 issues closed, 13 open) | No release date. Active development. |
| v1.2 | 6% complete | Future milestone |
| main branch | Active (multiple commits/week) | Contains all v1.1 fixes + displacement system |

---

## Source & Build Info

- **Repository:** https://github.com/TokisanGames/Terrain3D
- **Branch used:** `1.1-godot4.4` (v1.1.0-dev)
- **Local source (if still present):** `<terrain3d-source>/src/`
- **Build system:** SCons (GDExtension)
- **Output DLLs:** `addons/terrain_3d/bin/libterrain.windows.{debug,release}.x86_64.dll`
- **Docs:** https://terrain3d.readthedocs.io
- **Lead maintainer:** TokisanGames (Cory Petkovsek)
- **Key issue:** #770 — the vertex_spacing import position bug (our exact problem)

---

## What Broke in Our Previous Attempt (ce26144)

### Bug 1: `set_vertex_spacing()` Segfault

**Root cause:** `terrain_3d.h:113` — `Node3D *_label_parent;` NOT initialized to nullptr.

**Crash path:** `set_vertex_spacing()` -> `update_region_labels()` -> `_destroy_labels()` -> `_label_parent->get_children()` on uninitialized pointer.

**Fix (3 locations):**
```cpp
// terrain_3d.h:113 — initialize pointer
Node3D *_label_parent = nullptr;

// terrain_3d.cpp:~270 — guard _destroy_labels()
void Terrain3D::_destroy_labels() {
    if (!_label_parent) { return; }
    // ... rest of function
}

// terrain_3d.cpp:~599 — guard update_region_labels()
// Add `&& _label_parent` to the existing condition
```

### Bug 2: Node Transform Reset Every Frame

**Root cause:** `terrain_3d.cpp` NOTIFICATION_TRANSFORM_CHANGED handler calls `set_transform(Transform3D())` — resets ALL transform properties (position, rotation, scale) to identity.

**Why it matters:** The scale workaround (`terrain.scale = Vector3(1.828, 1, 1.828)`) gets cleared every frame.

**Fix:** Patch to only reset position, preserving scale:
```cpp
case NOTIFICATION_TRANSFORM_CHANGED: {
    Transform3D t = get_transform();
    if (t.origin != Vector3()) {
        t.origin = Vector3();
        set_transform(t);
    }
    break;
}
```

### Bug 3: `set_vertex_spacing()` Triggers Full Mesher Rebuild

Even after fixing the segfault, calling `set_vertex_spacing()` post-tree triggers `_setup_terrain_mesher()` and `_collision->build()`, which crashes or causes performance issues.

**Best approach for next attempt:**
1. Set `vertex_spacing` BEFORE `add_child()` (pre-tree) so `_initialize()` builds the mesher with the correct value from the start
2. Make the post-tree `set_vertex_spacing()` a no-op if value hasn't changed (use `SET_IF_DIFF` or `is_equal_approx`)
3. If post-tree setting IS needed, make it lightweight: only update `_data->_vertex_spacing` and `_terrain_mesher->_vertex_spacing` without full rebuild

### Bug 4: ENTER_TREE Re-enables Physics

C++ handler calls `set_physics_process(true)` when node enters tree. GDScript must re-disable AFTER `add_child()`:
```gdscript
add_child(terrain_3d)
terrain_node.set_physics_process(false)
terrain_node.set_process(false)
```

### Bug 5: Missing Camera3D Crash

Terrain3D v1.1+ crashes in `_grab_camera()` if no Camera3D exists in the viewport. Always add a dummy Camera3D before adding Terrain3D to the tree (especially in @tool scripts and prebaking scenes).

### Stale Cache Problem

After reverting code back to v1.0.1 style, terrain was STILL broken until:
1. Godot was fully quit (DLLs load at startup)
2. Terrain cache was cleared (`C:/Users/<user>/Documents/Godotwind/cache/terrain/`)
3. Godot was relaunched (fresh DLL load)
4. Terrain was rebaked

**Lesson:** Always do a full restart + cache clear cycle when changing Terrain3D DLLs or vertex_spacing logic.

---

## API Differences: v1.0.1 vs v1.1-dev

| Feature | v1.0.1 (stable) | v1.1-dev (custom) |
|---------|-----------------|-------------------|
| `vertex_spacing` | Property assignment works (`terrain.vertex_spacing = X`) | `set_vertex_spacing()` crashes (see Bug 1-3) |
| `change_region_size()` | Available | Removed — use `set_region_size()` or property |
| `set_texture()` / `get_texture()` | Available | RENAMED to `set_texture_asset()` / `get_texture_asset()` |
| `get_texture_count()` | Available | Available |
| `show_checkered` | Property on material | Property on material |
| `mesh_lods`, `mesh_size` | Properties | May not exist (check with `"mesh_lods" in terrain`) |
| `tessellation_level` | NOT available | Available (0-6) |
| `displacement_scale/sharpness` | NOT available | Available |
| `ocean_enabled/mesh_lods/vertex_spacing/mesh_size` | NOT available | Available |
| `import_images()` position | CENTER of region | Fixed: logical coordinates accounting for vertex_spacing (PR #898) |
| `get_height()` | Direct world position | Needs region blend update (issue #949, still open) |
| Deformation shader uniforms | NONE in shader | `group_uniforms displacement` block |

### CRITICAL: Import Position Difference

v1.0.1 uses CENTER coordinates for `import_images()`:
```gdscript
# v1.0.1 — CENTER position, world coordinates
world_x = region_coord.x * region_size + region_size * 0.5
world_z = -region_coord.y * region_size - region_size * 0.5
terrain.data.import_images(images, Vector3(world_x, 0, world_z), 0.0, 1.0)
```

v1.1-dev MAY use NW CORNER coordinates (finding during debugging, never conclusively verified):
```gdscript
# v1.1-dev (UNVERIFIED) — NW CORNER position, internal coordinates
import_x = region_coord.x * internal_region_size + 0.5
import_z = -(region_coord.y + 1) * internal_region_size + 0.5
terrain.data.import_images(images, Vector3(import_x, 0, import_z), 0.0, 1.0)
```

**IMPORTANT:** When building from source, test import position behavior FIRST with a single region before baking 289 regions.

---

## The vertex_spacing Problem

Godotwind needs `vertex_spacing = ~1.828m` (Morrowind cell size / 64 vertices). Terrain3D defaults to 1.0m.

### v1.0.1 Solution (Working)
```gdscript
terrain.vertex_spacing = CS.TERRAIN_VERTEX_SPACING  # Property assignment, no crash
# All APIs accept world positions directly
terrain.data.import_images(images, world_pos, 0.0, 1.0)
terrain.data.get_height(world_pos)
```

### v1.1-dev Solution (If Bugs Are Fixed)
```gdscript
# Pre-tree: set before add_child() so mesher initializes correctly
terrain.set_vertex_spacing(CS.TERRAIN_VERTEX_SPACING)
add_child(terrain)
# Post-tree: should be no-op if pre-tree worked
```

### v1.1-dev Workaround (If Bugs Are NOT Fixed)
Scale workaround — vertex_spacing stays 1.0, node is scaled:
```gdscript
terrain.scale = Vector3(CS.TERRAIN_VERTEX_SPACING, 1.0, CS.TERRAIN_VERTEX_SPACING)
# ALL position inputs must be converted to internal coords:
var internal_pos = terrain.global_transform.affine_inverse() * world_pos
terrain.data.import_images(images, internal_pos, 0.0, 1.0)
# Height queries also need conversion:
var internal = terrain.global_transform.affine_inverse() * world_pos
var height = terrain.data.get_height(internal)
```

**WARNING:** The scale workaround requires converting EVERY world position to internal coordinates. This was a source of many bugs. If you use this approach, grep for ALL calls to `import_images()`, `get_height()`, `get_region_location()` etc. and ensure they use converted positions. If vertex_spacing doesn't work natively, the workaround touches nearly every terrain-related file. Fix the DLL instead.

---

## Upstream Fixes Already Merged (v1.1 branch/main)

These PRs on the Terrain3D repo fix issues we encountered:

| PR | Title | Merged | Impact |
|----|-------|--------|--------|
| #897 | Vertex spacing no longer gets rounded | Dec 12 2025 | Our TERRAIN_VERTEX_SPACING = ~1.8286 would have been rounded |
| #898 | Fix region boundary slicing, negative coords, UI coord conversion | Dec 16 2025 | **Directly fixes issue #770** — the "nonsensical" import position problem we hit |
| #905 | Add update_region() for per-region collision updates | Mar 28 2026 | Useful for streaming |
| #954 | Fix decal position and macro variation when vertex_spacing != 1 | Mar 18 2026 | Fixed double-scaling of UV coordinates |
| #963 | Fix save race condition in Terrain3DMaterial | Apr 1 2026 | Fixes crash during save operations |

---

## v1.1 Open Issues (13 remaining)

| # | Title | Impact on Godotwind |
|---|-------|---------------------|
| #961 | Update C# bindings (Draft) | We use C# — need this |
| #949 | get_height() needs region blend | Affects our height queries |
| #932 | Enable MMI fade mode | Nice-to-have for LOD |
| #931 | 4.6 Issues (umbrella) | Critical — 4.6 compat |
| #925 | Redesign Asset dock for 4.6 (Draft) | Editor-only |
| #924 | Error spam with OpenGL | Not relevant (we use Vulkan) |
| #921 | Asset Dock broken in 4.6 | Editor-only |
| #908 | Export bounds fix | Nice-to-have |
| #870 | Scale AO/Normals by distance | Visual quality |
| #857 | Scale Normals/AO by distance | Visual quality |
| #835 | Dev mode | Debug tooling |
| #821 | Export bounds | Nice-to-have |
| #44 | Documentation tracker | Not blocking |

**Critical for us:** #931 (4.6 issues), #949 (get_height), #961 (C# bindings)

---

## Displacement System (v1.1 Feature)

This is the main reason to build from source. From the Terrain3D docs:

> "This will subdivide the clipmap mesh, greatly increasing the vertex density around the camera."

**How it works:**
- `Tessellation Level` (0-6) controls subdivision amount in Terrain Mesh group
- Uses an atlas texture buffer via viewport + canvas_item shader
- Buffer updates only when terrain mesh moves (not every frame)
- `Displacement Scale` controls max vertical separation between adjacent vertices
- Per-texture `Displacement Offset` and `Displacement Scale` for different ground types
- **Custom shader override** via `Terrain Mesh/Displacement/Buffer Shader Override Enabled`
- Custom uniforms in the `group_uniforms displacement` block enable footstep deformation

**This replaces our entire overlay mesh approach.** Instead of a separate dense mesh rendered on top of terrain, we get native vertex subdivision from the terrain itself + custom displacement shader.

---

## Build Instructions

### Prerequisites
- Python 3.x + SCons (Godot's build system)
- C++ compiler (MSVC on Windows, GCC/Clang on Linux)
- Follow Godot's platform-specific setup: https://docs.godotengine.org/en/stable/contributing/development/compiling/

### Steps

```bash
# 1. Clone
git clone git@github.com:TokisanGames/Terrain3D.git
cd Terrain3D

# 2. Initialize submodules (godot-cpp)
git submodule init
git submodule update

# 3. CRITICAL: Match godot-cpp version to your Godot binary
# For Godot 4.6-stable, check godot-cpp tags/commits
cd godot-cpp
git checkout <tag-matching-4.6-stable>
cd ..

# 4. Build debug + release
scons platform=windows target=template_debug arch=x86_64
scons platform=windows target=template_release arch=x86_64

# 5. Optional: debug symbols
scons dev_build=yes

# 6. Copy DLLs to Godotwind
cp bin/libterrain.windows.debug.x86_64.dll <project-path>/addons/terrain_3d/bin/
cp bin/libterrain.windows.release.x86_64.dll <project-path>/addons/terrain_3d/bin/
```

### Critical: godot-cpp Version Matching
The godot-cpp submodule version MUST match your Godot Engine version. Mismatched versions cause crashes. Check `git log` in godot-cpp to find the right commit for Godot 4.6.

---

## Recommended Approach for Next Attempt

### Option A: Build from main branch (recommended)
1. Clone Terrain3D main branch (has all v1.1 fixes)
2. Match godot-cpp to Godot 4.6-stable
3. Apply Bug 1-5 fixes if not yet merged upstream
4. Build with SCons
5. Test vertex_spacing FIRST: `terrain.vertex_spacing = 1.8286` — if it crashes, the clipmap bug persists
6. If it works: remove ALL workaround code (world_to_terrain_internal, configure_terrain3d_pre_tree, scale workaround comments)
7. Test import_images with CENTER positions — PR #898 may have changed expected coordinates
8. Test displacement system (Tessellation Level > 0)

### Option B: Wait for v1.1 release
- 83% complete, active development
- No release date announced
- Could be weeks or months

### Option C: Cherry-pick specific fixes onto v1.0.1
- Build v1.0.1 from source with selected PRs backported
- Most conservative but most work
- Would need: #897, #898, #954 at minimum

---

## Files That Need Changes When Switching DLLs

### Core Terrain Config
| File | What Changes |
|------|-------------|
| `src/core/coordinate_system.gd` | `configure_terrain3d()` — vertex_spacing method, scale workaround, tessellation/displacement properties |
| `src/core/coordinate_system.gd` | `get_terrain_height()` — with/without coordinate conversion |
| `src/core/coordinate_system.gd` | `configure_terrain3d_pre_tree()` — no-op vs set_vertex_spacing |
| `src/core/coordinate_system.gd` | `world_to_terrain_internal()` — remove if native vertex_spacing works |

### Import Position Code
| File | What Changes |
|------|-------------|
| `src/core/world/world_data_provider.gd` | `region_to_world_pos()` — CENTER vs NW CORNER |
| `src/core/world/generic_terrain_streamer.gd` | `_load_region_sync()`, `_generate_region_on_worker()`, `_import_generated_data()` — position formula + coordinate conversion |
| `src/core/world/terrain_manager.gd` | `import_cell_to_terrain()`, `import_combined_region()` — position formula |

### Texture API
| File | What Changes |
|------|-------------|
| `src/core/world/terrain_texture_loader.gd` | `set_texture()` vs `set_texture_asset()`, `get_texture()` vs `get_texture_asset()` |

### Shore/Horizon (World-Space Calculations)
| File | What Changes |
|------|-------------|
| `src/tools/shore_mask_baker.gd` | `get_vertex_spacing()` returns correct value if native, wrong if scale workaround |
| `src/core/water/shore_mask_generator.gd` | Same |
| `src/tools/prebaking/prebaking_manager.gd` | Horizon map texel spacing |

### Other
| File | What Changes |
|------|-------------|
| `src/tools/world_explorer.gd` | `_init_terrain3d()` — configuration + logging |
| `src/core/deformation/terrain_deformation_integration.gd` | Shader param injection — test if v1.1 shader reads them |
| `addons/terrain_3d/plugin.cfg` | Version string |
| `.claude/CLAUDE.md` | Gotchas #8-10 about Terrain3D |

---

## Verification Checklist

```
[ ] vertex_spacing = 1.828 confirmed at runtime (get_vertex_spacing() returns 1.828, not rounded)
[ ] Single region imports at correct world position
[ ] Terrain aligns with objects (houses in Seyda Neen)
[ ] Textures load (set_texture_asset works)
[ ] Tessellation visible at close range (Tessellation Level > 0)
[ ] Displacement visible (if wired)
[ ] Prebake completes without crash (289 regions)
[ ] Height queries return correct values
[ ] Shore mask generates correctly
[ ] Horizon maps generate correctly
[ ] C# bindings compile and work (dotnet build)
[ ] No crashes during save/load cycle
[ ] No error spam in console
```

---

## Token Cost Estimate

Previous attempt: ~5 sessions, multiple agents, significant token burn debugging DLL crashes and coordinate conversion bugs.

With this guide: should be 1-2 sessions — build with patches, run verification checklist, fix any remaining issues.

---

## Related Files

- `src/core/coordinate_system.gd` — single source of truth for terrain config
- `src/tools/prebaking/prebaking_manager.gd` — terrain prebaking pipeline
- `addons/terrain_3d/bin/` — DLL location
- `addons/terrain_3d/plugin.cfg` — version indicator
