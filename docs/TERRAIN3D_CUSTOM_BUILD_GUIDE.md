# Building Terrain3D From Source for Godotwind

## Purpose

This document compiles everything learned from multiple sessions of building Terrain3D from source (v1.1.0-dev) for use with Godotwind. It exists so future agents can solve these problems faster.

**Goal:** Use Terrain3D's v1.1-dev features (tessellation, displacement, ocean clipmap) with Godotwind's non-standard vertex_spacing (~1.828m).

**Current state (2026-04-03):** Reverted to v1.0.1 stable release. Custom build abandoned due to accumulated DLL bugs. This guide documents what went wrong and what needs to be done differently next time.

---

## Why We Want a Custom Build

Terrain3D v1.0.1 stable works but lacks:

| Feature | Why We Want It |
|---------|---------------|
| `tessellation_level` | Dense near-camera mesh for deformation (footprints, cobblestones) — Morrowind terrain is 1.83m/vertex, too coarse for visible detail |
| `displacement_scale/sharpness` | Heightmap displacement from texture alpha channels (cobblestone bumps, rocky ground) |
| `ocean_enabled/mesh_lods/vertex_spacing` | Integrated ocean clipmap with terrain — depth-buffer shore blending, no separate ocean mesh needed |
| Deformation shader uniforms | v1.0.1's shader has ZERO deformation uniforms. RTT deformation injection via `material_set_param()` silently does nothing. |

Without tessellation, the only alternative for terrain deformation is an overlay mesh approach (separate dense disc rendered on top of terrain). This works but has visual compositing challenges (z-fighting, texture matching).

---

## Terrain3D Source

- **Repository:** https://github.com/TokisanGames/Terrain3D
- **Branch used:** `1.1-godot4.4` (v1.1.0-dev)
- **Local source (if still present):** `D:/Gamedev/Terrain3D/src/`
- **Build system:** SCons (GDExtension)
- **Output DLLs:** `addons/terrain_3d/bin/libterrain.windows.{debug,release}.x86_64.dll`

---

## Known DLL Bugs in v1.1.0-dev (Must Fix Before Use)

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

**Attempted fixes:**
- Minimal DLL patch (just store float, skip subsystem propagation) — partially worked
- Pre-tree call (before `add_child()`) — subsystems are null, so it only stores the value, but the mesher then initializes with it during `_initialize()`

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

---

## API Differences: v1.0.1 vs v1.1-dev

| Feature | v1.0.1 (stable) | v1.1-dev (custom) |
|---------|-----------------|-------------------|
| `vertex_spacing` | Property assignment works (`terrain.vertex_spacing = X`) | `set_vertex_spacing()` method crashes (see Bug 1-3) |
| `change_region_size()` | Available | Available |
| `set_region_size()` | NOT available | NOT available |
| `set_texture()` / `get_texture()` | Available | RENAMED to `set_texture_asset()` / `get_texture_asset()` |
| `get_texture_count()` | Available | Available |
| `show_checkered` | Property on material | Property on material |
| `mesh_lods`, `mesh_size` | Properties | Properties |
| `tessellation_level` | NOT available | Available |
| `displacement_scale/sharpness` | NOT available | Available |
| `ocean_enabled/mesh_lods/vertex_spacing/mesh_size` | NOT available | Available |
| `import_images()` position | CENTER of region | Uncertain — may be NW CORNER (needs testing) |
| Deformation shader uniforms | NONE in shader | Unknown — not tested |

### CRITICAL: Import Position Difference

v1.0.1 uses CENTER coordinates for `import_images()`:
```gdscript
# v1.0.1 — CENTER position, world coordinates
world_x = region_coord.x * region_size + region_size * 0.5
world_z = -region_coord.y * region_size - region_size * 0.5
terrain.data.import_images(images, Vector3(world_x, 0, world_z), 0.0, 1.0)
```

v1.1-dev MAY use NW CORNER coordinates (this was the finding during debugging, but was never conclusively verified):
```gdscript
# v1.1-dev (UNVERIFIED) — NW CORNER position, internal coordinates
import_x = region_coord.x * internal_region_size + 0.5
import_z = -(region_coord.y + 1) * internal_region_size + 0.5
terrain.data.import_images(images, Vector3(import_x, 0, import_z), 0.0, 1.0)
```

**IMPORTANT:** When building from source, test import position behavior FIRST with a single region before baking 289 regions. Log the position, then verify with `get_region_location()` and visual alignment.

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
If `set_vertex_spacing()` is fixed to not crash:
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

**WARNING:** The scale workaround requires converting EVERY world position to internal coordinates. This was a source of many bugs. If you use this approach, grep for ALL calls to `import_images()`, `get_height()`, `get_region_location()` etc. and ensure they use converted positions.

---

## Files That Need Changes When Switching DLLs

### Always Change (Core Terrain Config)
| File | What Changes |
|------|-------------|
| `src/core/coordinate_system.gd` | `configure_terrain3d()` — vertex_spacing method, scale workaround, tessellation/displacement properties |
| `src/core/coordinate_system.gd` | `get_terrain_height()` — with/without coordinate conversion |
| `src/core/coordinate_system.gd` | `configure_terrain3d_pre_tree()` — no-op vs set_vertex_spacing |

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

### Documentation
| File | What Changes |
|------|-------------|
| `.claude/CLAUDE.md` | Gotchas section — terrain configuration details |

---

## Recommended Approach for Next Attempt

1. **Create a branch** — don't modify master
2. **Build Terrain3D from source** with ALL bug fixes (Bug 1-5) applied
3. **Test vertex_spacing first** — minimal test: create Terrain3D, set vertex_spacing, log `get_vertex_spacing()`, confirm 1.828
4. **Test import position** — import ONE region at known coordinates, verify alignment visually
5. **Test texture API** — confirm `set_texture_asset()` exists, load one texture
6. **Test tessellation** — set `tessellation_level = 3`, confirm visual effect
7. **Only then** do full prebake and integration

### Build Commands (SCons)
```bash
cd D:/Gamedev/Terrain3D
scons platform=windows target=template_debug arch=x86_64
scons platform=windows target=template_release arch=x86_64
# Copy DLLs to Godotwind
cp bin/libterrain.windows.debug.x86_64.dll D:/Gamedev/Godotwind/godotwind/addons/terrain_3d/bin/
cp bin/libterrain.windows.release.x86_64.dll D:/Gamedev/Godotwind/godotwind/addons/terrain_3d/bin/
```

### Verification Checklist
```
[ ] vertex_spacing = 1.828 confirmed at runtime
[ ] Single region imports at correct world position
[ ] Terrain aligns with objects (houses in Seyda Neen)
[ ] Textures load (set_texture_asset works)
[ ] Tessellation visible at close range
[ ] Displacement visible (if wired)
[ ] Prebake completes without crash (289 regions)
[ ] Height queries return correct values
[ ] Shore mask generates correctly
[ ] Horizon maps generate correctly
```

---

## Token Cost Estimate

Previous attempt: ~5 sessions, multiple agents, significant token burn debugging DLL crashes and coordinate conversion bugs.

With this guide: should be 1-2 sessions — build with patches, run verification checklist, fix any remaining issues.

---

## Related Files

- `docs/TERRAIN_ALIGNMENT_INVESTIGATION.md` — original investigation notes (partially outdated)
- `src/core/coordinate_system.gd` — single source of truth for terrain config
- `src/tools/prebaking/prebaking_manager.gd` — terrain prebaking pipeline
- `addons/terrain_3d/plugin.cfg` — version indicator (text label, not authoritative for DLL version)
- `addons/terrain_3d/bin/` — DLL location
