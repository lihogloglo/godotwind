# Morrowind Texture Integration Guide

Complete guide for integrating RTT deformation with Morrowind/OpenMW textures, including automatic texture name parsing and normal map alpha channel support for Terrain3D displacement.

---

## 🎯 Overview

This guide covers two separate but complementary systems:

1. **RTT Deformation** (Dynamic footprints/tracks)
   - Automatic texture name parsing
   - Morrowind naming convention support
   - Special case handling

2. **Terrain3D Displacement** (Static texture detail)
   - Normal map alpha channel usage
   - Height map integration
   - Texture pack compatibility

---

## 📦 Part 1: Auto-Parsing Morrowind Texture Names

### **The Problem**

Morrowind has hundreds of textures with naming patterns like:
- `tx_snow_01.dds`
- `tx_rock_volcanic.dds`
- `tx_ash_red_01.dds`
- `tx_snow_grass.dds` ← Special case! (Actually grass, not snow)

Manual configuration for all these is tedious and error-prone.

### **The Solution**

**Automatic texture name parsing** based on filename patterns!

```gdscript
# Just add the bridge - it auto-parses!
var bridge = TerrainDeformationBridge.new()
bridge.auto_parse_textures = true  # Default
bridge.terrain_node = $Terrain3D
add_child(bridge)

# Done! Textures automatically classified:
# tx_snow_01.dds       → 0.25m (snow)
# tx_rock_volcanic.dds → 0.00m (rock)
# tx_ash_red_01.dds    → 0.12m (red ash)
# tx_snow_grass.dds    → 0.03m (grass, special case!)
```

---

### **How It Works**

**Step 1: Pattern Matching**

Parser checks filename against rules:

```
Filename: "tx_snow_01.dds"
  1. Clean: "tx_snow_01"
  2. Check special cases: Not found
  3. Check pattern rules:
     - Contains "rock"? NO
     - Contains "snow"? YES ✓
     - Excludes "grass"? YES ✓
     - Excludes "rock"? YES ✓
     → Match: "Snow (Deep)" → 0.25m
```

**Step 2: Special Cases**

Some textures have misleading names:

```gdscript
special_cases = {
    "tx_snow_grass": 0.03,    # Contains "snow" but is grass!
    "tx_snow_rock": 0.00,     # Contains "snow" but is rock!
    "tx_ice_01": 0.00,        # Hard surface (no deformation)
}
```

Special cases are checked **first**, before pattern rules.

**Step 3: Priority Order**

Rules are checked in priority order:

```
1. HARD SURFACES (0.00m) - rock, stone, ice, cobble
2. SNOW (0.15-0.25m)     - snow (excluding snow_grass, snow_rock)
3. ASH (0.12-0.15m)      - ash, red ash
4. MUD (0.10m)           - mud, swamp, marsh
5. SAND (0.08m)          - sand
6. DIRT (0.05m)          - dirt, soil
7. GRASS (0.03m)         - grass
8. PATHS (0.02m)         - path, road
```

This ensures correct classification even with complex names.

---

### **Usage Example**

**Automatic (Recommended):**

```gdscript
# In your scene
extends Node3D

func _ready():
    # Add Terrain3D
    var terrain = Terrain3D.new()
    add_child(terrain)
    # ... configure terrain with Morrowind textures ...

    # Add bridge with auto-parsing
    var bridge = TerrainDeformationBridge.new()
    bridge.terrain_node = terrain
    bridge.auto_parse_textures = true  # Default
    bridge.debug = true  # See what it parsed
    add_child(bridge)

    # Bridge automatically:
    # 1. Detects terrain
    # 2. Parses all texture names
    # 3. Assigns rest heights
    # 4. Applies to shader

    # Optional: Print what was detected
    bridge.print_configuration()
```

**Output:**
```
=== Texture Name Parser Rules ===
Special Cases: 12
  'tx_snow_grass' → 0.030m
  'tx_snow_rock' → 0.000m
  'tx_ice_01' → 0.000m
  ...

Pattern Rules: 14
  [0] Rock → 0.000m
      Contains: ['rock']
      Excludes: ['snow_rock']
  [1] Snow (Deep) → 0.250m
      Contains: ['snow']
      Excludes: ['grass', 'rock', 'light']
  ...

=== Terrain Deformation Heights Configuration ===
Terrain3D: Terrain3D
Textures configured: 42

  [ 0] tx_ash_01.dds          : 0.150m
  [ 1] tx_ash_red_01.dds      : 0.120m
  [ 2] tx_rock_volcanic.dds   : 0.000m
  [ 3] tx_snow_01.dds         : 0.250m
  [ 4] tx_snow_grass.dds      : 0.030m  ← Special case!
  [ 5] tx_mud_01.dds          : 0.100m
  ...
```

---

### **Customizing Rules**

**Add Custom Patterns:**

```gdscript
func setup_custom_parsing():
    var bridge = $TerrainDeformationBridge

    # Get the parser (create new one)
    var parser = TerrainTextureNameParser.new()

    # Add custom rules
    parser.add_rule("Lava Rock", 0.00, ["lava", "rock"])
    parser.add_rule("Volcanic Soil", 0.08, ["volcanic", "soil"])

    # Add special cases
    parser.add_special_case("my_weird_texture_01", 0.15)

    # Parse and apply
    bridge.texture_config = parser.create_config_from_terrain($Terrain3D)
    bridge.apply_deformation_heights()
```

**Override Auto-Parsing:**

```gdscript
# Disable auto-parse, use manual config
bridge.auto_parse_textures = false
bridge.texture_config = preload("res://my_manual_config.tres")
```

---

### **Common Morrowind Patterns**

| Filename Pattern | Classification | Height | Examples |
|------------------|----------------|--------|----------|
| `tx_snow_*.dds` | Snow (Deep) | 0.25m | `tx_snow_01`, `tx_snow_02` |
| `tx_snow_*light*.dds` | Snow (Light) | 0.15m | `tx_snow_light_01` |
| `tx_snow_grass*.dds` | Grass (Special!) | 0.03m | `tx_snow_grass`, `tx_snow_grass_01` |
| `tx_snow_rock*.dds` | Rock (Special!) | 0.00m | `tx_snow_rock` |
| `tx_ash_*.dds` | Ash (Gray) | 0.15m | `tx_ash_01`, `tx_ash_02` |
| `tx_ash_red*.dds` | Ash (Red) | 0.12m | `tx_ash_red_01` |
| `tx_rock_*.dds` | Rock | 0.00m | `tx_rock_volcanic`, `tx_rock_black` |
| `tx_mud_*.dds` | Mud | 0.10m | `tx_mud_01` |
| `tx_dirt_*.dds` | Dirt | 0.05m | `tx_dirt_01` |
| `tx_sand_*.dds` | Sand | 0.08m | `tx_sand_01` |
| `tx_grass_*.dds` | Grass | 0.03m | `tx_grass_01` |
| `tx_cobblestone*.dds` | Cobblestone | 0.00m | `tx_cobblestone_01` |
| `tx_ice_*.dds` | Ice | 0.00m | `tx_ice_01` |

---

### **Testing Your Configuration**

```gdscript
# Test parser without applying
func test_parsing():
    var parser = TerrainTextureNameParser.new()
    parser.debug = true

    # Test specific filenames
    var tests = [
        "tx_snow_01.dds",
        "tx_snow_grass.dds",
        "tx_rock_volcanic.dds",
        "tx_ash_red_01.dds",
    ]

    for filename in tests:
        var height = parser.parse_texture_name(filename)
        print("%s → %.3fm" % [filename, height])

# Output:
# [Parser] Analyzing: tx_snow_01.dds → tx_snow_01
#   → Rule match 'Snow (Deep)': 0.250m
# tx_snow_01.dds → 0.250m
#
# [Parser] Analyzing: tx_snow_grass.dds → tx_snow_grass
#   → Special case match: 0.030m
# tx_snow_grass.dds → 0.030m
# ...
```

---

## 📐 Part 2: Normal Map Alpha Channels for Terrain3D Displacement

### **Background**

Modern Morrowind texture packs (like Tamriel Rebuilt, OAAB, etc.) include normal maps with **alpha channels** containing height information:

```
my_texture_n.dds (Normal Map)
  - RGB: Normal vectors
  - Alpha: Height map (0.0 = low, 1.0 = high)
```

Terrain3D's **displacement system** can use these alpha channels for realistic detail!

---

### **How Terrain3D Displacement Works**

**Separate from RTT Deformation:**

| System | Purpose | Data Source | Dynamic? |
|--------|---------|-------------|----------|
| **Terrain3D Displacement** | Texture detail (rocks, cobbles) | Normal map alpha | Static |
| **RTT Deformation** | Footprints, tracks | Runtime RTT buffer | Dynamic |

**They work together:**
- Terrain3D displacement adds permanent surface detail
- RTT deformation adds dynamic footprints on top

---

### **Enabling Terrain3D Displacement**

**Step 1: Prepare Textures**

Your normal maps must have height data in the **alpha channel**:

```
Texture Files:
  tx_snow_01_d.dds  ← Diffuse/Albedo
  tx_snow_01_n.dds  ← Normal + Height (RGBA)
                       RGB = normals
                       A   = height! ← Must have this
```

**Step 2: Enable in Terrain3D**

```
1. Select Terrain3D node
2. Inspector → Terrain Mesh → Tessellation Level: 2-4
   (Higher = more detail, lower performance)

3. Terrain Mesh → Displacement:
   - Displacement Enabled: ✓ true
   - Displacement Scale: 0.5 (max displacement distance)
   - Displacement Sharpness: 1.0 (blend sharpness)
```

**Step 3: Configure Per-Texture**

Each texture asset needs displacement settings:

```
Terrain3D → Assets → Texture 0 (Snow):
  - Albedo Texture: tx_snow_01_d.dds
  - Normal Texture: tx_snow_01_n.dds  ← Must have alpha!

  - Displacement Scale: 0.8
    (How much to use the height map, 0-1)

  - Displacement Offset: -0.2
    (Shift height up/down to match collision)

  - Normal Depth: 1.0
    (Normal map strength)
```

---

### **Displacement vs Deformation**

**Visual Example:**

```
Terrain Cross-Section:

         Terrain3D Displacement (Static Detail)
         ↓
    ████░░░░████  ← Cobblestone bumps (from normal alpha)
    ███████████   ← Base terrain
         ↓
    ███████████   ← RTT Deformation (footprint)
    ███░░░░░███   ← Deformed down

Combined:
    ████░░░░████  ← Cobblestone bumps
    ███░░░░░███   ← Footprint in cobblestones
         ↑
    Both systems working together!
```

---

### **Recommended Settings by Material**

| Material | Tessellation | Displacement Scale | Displacement Offset | Notes |
|----------|--------------|-------------------|---------------------|-------|
| **Snow** | 2 | 0.5 | -0.1 | Soft bumps |
| **Rock** | 4 | 1.0 | -0.3 | Sharp details |
| **Cobblestone** | 4 | 0.8 | -0.2 | Defined stones |
| **Mud** | 2 | 0.3 | 0.0 | Subtle texture |
| **Grass** | 3 | 0.4 | 0.1 | Small variations |
| **Sand** | 2 | 0.2 | 0.0 | Gentle ripples |

---

### **Creating Height Maps from Normal Maps**

If your normal maps don't have alpha channels:

**Method 1: Use GIMP**

```
1. Open normal map: tx_snow_01_n.dds
2. Layer → Transparency → Add Alpha Channel
3. Filters → Map → Normalmap:
   - Method: "Sobel 3x3"
   - Check "Alpha Channel"
   - Height scale: Adjust to taste
4. Export as DDS with alpha
```

**Method 2: Use Substance Designer/Painter**

```
1. Import diffuse texture
2. Generate normal map
3. Export with "Height in Alpha" option
```

**Method 3: Use Existing Height Maps**

If you have separate height maps:

```
1. Open normal map in GIMP
2. Add alpha channel
3. Copy height map
4. Paste as layer mask → Apply
5. Export
```

---

### **Troubleshooting Displacement**

**Issue: No displacement visible**

**Solutions:**
- Increase Tessellation Level (try 3-4)
- Increase Displacement Scale (try 1.0)
- Check normal map has alpha channel (open in GIMP)
- Enable Debug View → Displacement Buffer

**Issue: Terrain too spiky**

**Solutions:**
- Decrease Displacement Scale (try 0.5)
- Adjust Displacement Offset (try negative values)
- Reduce Tessellation Level

**Issue: Collision mismatch**

**Solutions:**
- Adjust Displacement Offset to center displacement around collision
- Most textures need negative offset (-0.1 to -0.3)
- Use Debug View → Displacement Buffer to see alignment

---

### **Performance Considerations**

**Tessellation Levels:**

| Level | Vertices/m² | Performance | Use Case |
|-------|-------------|-------------|----------|
| 0 | ~0.4 | Best | No displacement |
| 1 | ~1.6 | Good | Subtle details |
| 2 | ~6.4 | Medium | **Recommended** |
| 3 | ~25.6 | Lower | Detailed textures |
| 4 | ~102.4 | Low | Very detailed |
| 5-6 | 400-1600 | Very Low | Extreme detail |

**Recommendations:**
- Use **Tessellation 2** for most textures
- Use **Tessellation 4** only for close-up surfaces (cobblestone roads)
- Use **Tessellation 0** for distant terrain (LOD)

---

### **Complete Morrowind Integration**

**Combined Setup:**

```gdscript
# scene_setup.gd
extends Node3D

func _ready():
    # 1. Setup Terrain3D with Morrowind textures
    var terrain = $Terrain3D
    terrain.set_mesh_lods(4)  # LOD levels
    terrain.set_mesh_size(48)  # Mesh segments

    # 2. Enable displacement (static detail from normal alpha)
    terrain.set_mesh_tessellation(2)  # Moderate detail
    terrain.set_displacement_enabled(true)
    terrain.set_displacement_scale(0.5)

    # 3. Add deformation bridge (dynamic footprints)
    var bridge = TerrainDeformationBridge.new()
    bridge.terrain_node = terrain
    bridge.auto_parse_textures = true  # Auto-parse Morrowind names!
    bridge.debug = true
    add_child(bridge)

    # 4. Enable deformation in material
    var material = terrain.get_material()
    material.set_shader_parameter("deformation_enabled", true)
    material.set_shader_parameter("deformation_depth_scale", 0.15)

    # Result:
    # - Terrain has static displacement from normal alpha (cobbles, rocks)
    # - RTT deformation adds dynamic footprints on top
    # - Texture heights auto-parsed from filenames!
```

---

## 📚 **Summary**

### **RTT Deformation (Dynamic)**
✅ Auto-parse Morrowind texture names
✅ Special case handling (snow_grass, snow_rock)
✅ Per-texture rest heights
✅ Runtime footprints/tracks

### **Terrain3D Displacement (Static)**
✅ Normal map alpha channels
✅ Static surface detail
✅ Tessellation-based
✅ Compatible with texture packs

### **Both Together**
✅ Static detail (displacement) + Dynamic tracks (deformation)
✅ Zero Terrain3D modification required
✅ Auto-configuration from filenames
✅ Production-ready for Morrowind ports

---

**Files Added:**
- `src/core/deformation/terrain_texture_name_parser.gd` - Auto-parser
- `src/core/deformation/terrain_deformation_bridge.gd` - Updated with auto-parse
- `docs/RTT_DEFORMATION_MORROWIND_INTEGRATION.md` - This guide

**Ready to use with your Morrowind port!** 🎉
