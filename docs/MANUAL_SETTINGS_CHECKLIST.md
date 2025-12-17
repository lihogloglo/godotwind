# Manual Settings Checklist for Godotwind

This document lists settings that **cannot be configured in code** and must be set manually in Godot's UI/inspector for the world streaming system to work correctly.

## Critical Settings

### 1. Camera3D Far Plane Distance ⚠️

**Location:** Any scene with Camera3D node → Inspector → Camera3D → Far

**Recommended Value:** `2000.0` meters

**Issue:** If set too high (e.g., 10000m), it causes:
- Excessive rendering load (too many objects/terrain drawn)
- Z-fighting and depth precision issues
- Performance degradation

**Current Values in Scenes:**
- ✅ `world_explorer.tscn`: `2000.0` (CORRECT)
- ✅ `terrain_test.tscn`: `2000.0` (CORRECT)
- ❌ `lapalma_explorer.tscn`: `50000.0` (TOO HIGH - for large terrain, but reconsider)

**How to Check/Fix:**
1. Open scene in Godot editor
2. Select Camera3D node
3. In Inspector, find "Far" property under Camera3D section
4. Set to `2000.0`

---

### 2. DirectionalLight3D Shadow Distance

**Location:** Any scene with DirectionalLight3D → Inspector → Shadow → Max Distance

**Recommended Value:** `300.0` meters (for Morrowind)

**Reasoning:**
- Shadows beyond this distance are barely visible
- Reducing shadow distance improves performance significantly
- Can be increased if needed, but diminishing returns

**Current Values:**
- ✅ `world_explorer.tscn`: `300.0` (CORRECT)
- ✅ `terrain_test.tscn`: `300.0` (CORRECT)
- ⚠️ `lapalma_explorer.tscn`: `2000.0` (higher for large terrain)

**How to Check/Fix:**
1. Open scene in Godot editor
2. Select DirectionalLight3D node
3. In Inspector → Shadow → Directional Shadow → Max Distance
4. Set to `300.0` (or adjust based on your needs)

---

### 3. Terrain3D Material Settings

**Location:** Terrain3D node → Inspector → Material → Terrain3DMaterial

**Important Properties:**

#### Show Checkered (Debug)
- **Default:** `true` (shows pink checkerboard for missing textures)
- **Production:** `false` (hide debugging)
- Set in: `terrain_3d.material.show_checkered = false`

#### Blend Sharpness
- **Range:** 0.0 - 1.0
- **Default:** 0.5
- Controls texture blending sharpness
- Currently configured in code via shader parameters

**Note:** Most Terrain3D material settings ARE configurable in code (see `_init_terrain3d()` in world_explorer.gd), but they can be overridden in the scene if needed.

---

### 4. Terrain3D Region Size

**Location:** Terrain3D node → Inspector (must use code)

**Value:** `256` (256×256 pixels per region)

**WARNING:** ⚠️ This setting **MUST** match the code configuration:
```gdscript
terrain_3d.change_region_size(256)
```

**Why 256?**
- Each Morrowind cell = 64 vertices (65 cropped to 64)
- 4×4 cells per region = 256 vertices
- This gives optimal memory layout

**How to Check:**
1. Open scene in Godot editor
2. Select Terrain3D node
3. Check Inspector → Terrain3D → Region Size
4. Verify it matches code (currently 256)

**If Changed:** You must update:
- `terrain_manager.gd` CELLS_PER_REGION constant
- All region generation code
- **Don't change this unless you know what you're doing!**

---

### 5. Terrain3D Vertex Spacing

**Location:** Terrain3D node → Inspector → Vertex Spacing

**Value:** ~`1.83` meters (calculated: 117m / 64 vertices)

**WARNING:** ⚠️ This is calculated in code:
```gdscript
var vertex_spacing := CS.CELL_SIZE_GODOT / 64.0  # ≈ 1.828125
terrain_3d.vertex_spacing = vertex_spacing
```

**If manually changed in scene**, code will override it at runtime.

**How to Check:**
1. Open scene in Godot editor
2. Select Terrain3D node
3. Inspector → Terrain3D → Vertex Spacing
4. Should be ~1.83 (exact: 1.828125)

---

### 6. Terrain3D Mesh LOD Settings

**Location:** Terrain3D node → Inspector → Mesh LODs / Mesh Size

**Current Code Values:**
```gdscript
terrain_3d.mesh_lods = 7
terrain_3d.mesh_size = 48
```

**Can be overridden in scene**, but code will set them at runtime.

- **mesh_lods**: Number of LOD levels (more = smoother transitions, but higher cost)
  - Range: 4-8 typical
  - Current: 7

- **mesh_size**: Vertices per mesh chunk
  - Range: 16-64 typical
  - Current: 48
  - Larger = fewer draw calls, but less culling precision

**How to Check:**
1. Select Terrain3D node
2. Inspector → Terrain3D section
3. Check Mesh LODs and Mesh Size

---

### 7. Environment Settings (Fog)

**Location:** WorldEnvironment node → Inspector → Environment → Fog

**Current Settings (world_explorer.tscn):**
```
fog_enabled = true
fog_density = 0.00005
fog_sky_affect = 0.1
```

**Impact:**
- Fog helps hide terrain pop-in at distance
- Too much fog reduces visibility
- Too little fog shows terrain edges

**Not critical**, but affects visual quality.

---

### 8. Project Settings (Physics Engine)

**Location:** Project → Project Settings → Physics → 3D

**Current Value:**
```
3d/physics_engine = "JoltPhysics3D"
```

**Note:** This is set in `project.godot`, not in scenes.

**Why JoltPhysics3D?**
- Better performance than default Godot Physics
- More stable for large worlds
- Better suited for open-world streaming

**How to Check:**
1. Project → Project Settings
2. Physics → 3D
3. Verify Physics Engine is set to "JoltPhysics3D"

---

## Settings That ARE Configurable in Code

These settings are mentioned for completeness, but they're already handled in code:

✅ **BackgroundProcessor settings** - All in code
✅ **WorldStreamingManager view distance** - Configured in code
✅ **Cell load budgets** - Time-budgeted in code
✅ **Terrain texture loading** - Automated
✅ **OWDB chunk sizes** - Configured in code
✅ **Ocean settings** - OceanManager handles this

---

## Quick Audit Process

When creating or modifying a scene with world streaming:

1. ✅ Check Camera3D → Far = 2000.0 (not 10000+)
2. ✅ Check DirectionalLight3D → Shadow Max Distance = 300.0
3. ✅ Check Terrain3D → Region Size = 256
4. ✅ Check Terrain3D → Vertex Spacing ≈ 1.83
5. ✅ Verify fog is enabled for visual quality
6. ✅ Run scene and monitor performance

---

## Common Issues

### Issue: Terrain looks wrong / stretched
**Cause:** Incorrect vertex_spacing or region_size
**Fix:** Verify Terrain3D settings match code values

### Issue: Performance is poor
**Cause:** Camera far plane too high, shadow distance too high
**Fix:** Set Camera3D far = 2000, DirectionalLight shadow = 300

### Issue: Z-fighting / depth artifacts
**Cause:** Camera far plane too high (depth precision issues)
**Fix:** Reduce Camera3D far plane to 2000 or lower

### Issue: Pink checkerboard visible on terrain
**Cause:** show_checkered = true, or textures not loaded
**Fix:** Set material.show_checkered = false, verify textures loaded

---

## Scene-Specific Recommendations

### Morrowind World Streaming (world_explorer.tscn, terrain_test.tscn)
- Camera Far: **2000.0** ✅
- Shadow Distance: **300.0** ✅
- Fog: **Enabled** ✅

### Large Terrain Testing (lapalma_explorer.tscn)
- Camera Far: **Can be higher** (50000 currently, but consider performance)
- Shadow Distance: **2000.0** (appropriate for scale)
- Note: La Palma is much larger than Morrowind

---

## Conclusion

The most critical manual settings are:

1. **Camera3D far plane** (2000m recommended)
2. **DirectionalLight3D shadow distance** (300m recommended)
3. **Terrain3D region size & vertex spacing** (must match code)

Most other settings are either:
- Already configured in code (preferred)
- Optional visual quality tweaks
- Platform-specific (project settings)

**When in doubt:** Compare your scene to `world_explorer.tscn` or `terrain_test.tscn` as reference.
