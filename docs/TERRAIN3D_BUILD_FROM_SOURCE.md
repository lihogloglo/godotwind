# Terrain3D: Building From Source — Knowledge Base

This document compiles everything learned from Godotwind's attempt to build Terrain3D from source (commit ce26144, April 1 2026), plus upstream research. Its purpose is to help future agents successfully build and integrate a custom Terrain3D build.

---

## Why Build From Source?

Terrain3D v1.0.1 (the current stable release, June 2025) lacks features we need:

1. **Displacement/Tessellation** — v1.1 adds `Tessellation Level` (0-6) that subdivides the clipmap mesh near the camera, increasing vertex density. Supports custom shader overrides for footstep deformation via `group_uniforms displacement`. This is the killer feature for terrain deformation — it eliminates the need for overlay meshes.
2. **Custom shader uniforms** — v1.0.1's shader has no `deformation_texture_array` or similar uniforms. Our existing deformation system (`src/core/deformation/terrain_deformation_integration.gd`) injects params via `RenderingServer.material_set_param()` that v1.0.1's shader silently ignores.
3. **Vertex spacing fixes** — v1.1 fixes import_images() position calculations (#770, #897, #898), decal positioning (#954), and removes vertex spacing rounding.
4. **Godot 4.6 compatibility** — Issue #931 tracks 4.6-specific bugs being fixed on main branch.

---

## Current State (April 2026)

| Version | Status | Notes |
|---------|--------|-------|
| v1.0.1 | Latest stable release | Works with Godot 4.6, vertex_spacing works natively |
| v1.1 | 83% complete (66/79 issues closed, 13 open) | No release date. Active development. |
| v1.2 | 6% complete | Future milestone |
| main branch | Active (multiple commits/week) | Contains all v1.1 fixes + displacement system |

---

## What Broke in Our Previous Attempt (ce26144)

### 1. `set_vertex_spacing()` Segfault
**Symptom:** Setting `terrain.vertex_spacing = 1.8286` caused a segfault in the v1.1.0-dev DLL, both pre-tree and in-tree.
**Root cause:** Likely a clipmap null-deref during rebuild. The clipmap is generated at startup; changing vertex_spacing triggers a full clipmap rebuild which may access uninitialized data.
**Workaround attempted:** Disable vertex_spacing (leave at 1.0), use `terrain.scale = Vector3(TERRAIN_VERTEX_SPACING, 1.0, TERRAIN_VERTEX_SPACING)` as node-level scaling.
**Result:** Partially worked but the workaround was INCOMPLETE — terrain.scale was never actually applied in the code, and all coordinate conversion functions needed updating.

### 2. API Changes (v1.0.1 → v1.1-dev)
| Feature | v1.0.1 | v1.1-dev |
|---------|--------|----------|
| `change_region_size()` | Method exists | Removed — use `set_region_size()` or property |
| `terrain.vertex_spacing` | Property setter works | Segfaults (clipmap rebuild crash) |
| `mesh_lods` property | Exists | May not exist (check with `"mesh_lods" in terrain`) |
| `mesh_size` property | Exists | May not exist |
| `material.show_checkered` | Exists | May not exist |
| `import_images()` positions | CENTER coordinates, pixel-based | Fixed: logical coordinates accounting for vertex_spacing (PR #898) |
| `get_height()` | Direct world position | Needs region blend update (issue #949, still open) |

### 3. Coordinate Conversion Cascade
The vertex_spacing workaround (scale instead of native spacing) required changes across 6+ files:
- `coordinate_system.gd` — Added `world_to_terrain_internal()` using `affine_inverse()`
- `coordinate_system.gd` — Added `get_terrain_height()` wrapper
- `coordinate_system.gd` — `configure_terrain3d()` disabled vertex_spacing, added version-conditional API calls
- `generic_terrain_streamer.gd` — Import positions converted through `world_to_terrain_internal()`
- `world_data_provider.gd` — `region_to_world_pos()` potentially affected
- `terrain_manager.gd` — Import positions potentially affected
- `prebaking_manager.gd` — Same

**Lesson:** If vertex_spacing doesn't work natively, the workaround touches nearly every terrain-related file. Fix the DLL instead.

### 4. Stale Cache Problem
After reverting code back to v1.0.1 style, terrain was STILL broken until:
1. Godot was fully quit (DLLs load at startup)
2. Terrain cache was cleared (`C:/Users/metzo/Documents/Godotwind/cache/terrain/`)
3. Godot was relaunched (fresh DLL load)
4. Terrain was rebaked

**Lesson:** Always do a full restart + cache clear cycle when changing Terrain3D DLLs or vertex_spacing logic.

---

## Upstream Fixes Already Merged (v1.1 branch/main)

These PRs on the Terrain3D repo fix issues we encountered:

### PR #897 — "Vertex spacing no longer gets rounded" (Merged Dec 12 2025)
- Removed rounding that corrupted non-integer vertex_spacing values
- Our TERRAIN_VERTEX_SPACING = ~1.8286 would have been rounded

### PR #898 — "Fix region boundary slicing, negative coords, UI coord conversion" (Merged Dec 16 2025)
- Fixed `import_images()` position calculations when vertex_spacing != 1.0
- Fixed negative coordinate handling (Math::floor instead of int cast)
- Fixed region boundary slicing for images crossing region boundaries
- Fixed region map overwrite bug
- **This directly fixes issue #770 which is the "nonsensical" import position problem we hit**

### PR #954 — "Fix decal position and macro variation when _vertex_spacing != 1" (Merged Mar 18 2026)
- Fixed double-scaling of UV coordinates in lightweight shader
- Affects visual correctness when vertex_spacing != 1.0

### PR #963 — "Fix save race condition in Terrain3DMaterial" (Merged Apr 1 2026)
- Fixes crash during save operations

### PR #905 — "Add update_region() for per-region collision updates" (Merged Mar 28 2026)
- New API for per-region collision updates (useful for streaming)

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

# 4. Build debug
scons

# 5. Build release
scons target=template_release

# 6. Optional: debug symbols
scons dev_build=yes

# 7. Output goes to bin/ directory
# Copy addons/terrain_3d/bin/ contents to your project
```

### Critical: godot-cpp Version Matching
The godot-cpp submodule version MUST match your Godot Engine version. Mismatched versions cause crashes. Check `git log` in godot-cpp to find the right commit for Godot 4.6.

---

## Recommended Approach for Next Attempt

### Option A: Build from main branch (recommended)
1. Clone Terrain3D main branch (has all v1.1 fixes)
2. Match godot-cpp to Godot 4.6-stable
3. Build with SCons
4. Test vertex_spacing FIRST: `terrain.vertex_spacing = 1.8286` — if it crashes, we know the clipmap bug persists
5. If it works: remove ALL workaround code (world_to_terrain_internal, configure_terrain3d_pre_tree, scale workaround comments)
6. Test import_images with CENTER positions — PR #898 may have changed expected coordinates
7. Test displacement system (Tessellation Level > 0)

### Option B: Wait for v1.1 release
- 83% complete, active development
- No release date announced
- Could be weeks or months

### Option C: Cherry-pick specific fixes onto v1.0.1
- Build v1.0.1 from source with selected PRs backported
- Most conservative but most work
- Would need: #897, #898, #954 at minimum

### Verification Checklist After Build
- [ ] `terrain.vertex_spacing = 1.8286` doesn't crash
- [ ] `terrain.get_vertex_spacing()` returns 1.8286 (not rounded)
- [ ] `import_images()` with CENTER positions places regions correctly
- [ ] `get_height(world_pos)` returns correct values
- [ ] 289 regions load successfully
- [ ] Terrain visually matches v1.0.1 stable (correct island size)
- [ ] C# bindings compile and work (`dotnet build`)
- [ ] Console shows `vertex_spacing=1.829` on startup
- [ ] Displacement/tessellation works (Tessellation Level > 0)
- [ ] No crashes during save/load cycle
- [ ] No error spam in console

---

## Files That Need Updating When Switching DLL Versions

When switching between v1.0.1 and a custom build, these files contain version-sensitive code:

| File | What to check |
|------|---------------|
| `src/core/coordinate_system.gd` | `configure_terrain3d()` — vertex_spacing, region_size API, mesh_lods/mesh_size |
| `src/core/coordinate_system.gd` | `world_to_terrain_internal()` — remove if native vertex_spacing works |
| `src/core/coordinate_system.gd` | `get_terrain_height()` — simplify if native spacing works |
| `src/core/world/generic_terrain_streamer.gd` | `_configure_terrain3d()` — vertex_spacing setting, region_size API |
| `src/core/world/generic_terrain_streamer.gd` | `_load_region_sync()` — import position conversion |
| `src/core/world/generic_terrain_streamer.gd` | `_import_generated_data()` — import position conversion |
| `src/core/world/terrain_manager.gd` | `import_combined_region()` — position formula |
| `src/core/world/world_data_provider.gd` | `region_to_world_pos()` — CENTER vs logical coords |
| `src/tools/prebaking/prebaking_manager.gd` | `CS.configure_terrain3d()` calls |
| `src/tools/world_explorer.gd` | `_init_terrain3d()` — configuration + logging |
| `src/core/deformation/terrain_deformation_integration.gd` | Shader param injection — test if v1.1 shader reads them |
| `addons/terrain_3d/plugin.cfg` | Version string |
| `.claude/CLAUDE.md` | Gotchas #8-10 about Terrain3D |

---

## Key Contacts / Resources

- **Terrain3D repo:** https://github.com/TokisanGames/Terrain3D
- **Lead maintainer:** TokisanGames (Cory Petkovsek)
- **Docs:** https://terrain3d.readthedocs.io
- **Discord:** Listed on repo (for build help)
- **Issue #770:** The vertex_spacing import position bug (our exact problem)
- **PR #898:** The fix for #770
- **Displacement docs:** `doc/docs/displacement.md` in repo
