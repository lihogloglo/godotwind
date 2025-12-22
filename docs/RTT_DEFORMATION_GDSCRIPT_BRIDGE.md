# GDScript Bridge for Terrain Deformation (No Terrain3D Modification Required!)

## Overview

This guide shows you how to use **per-texture deformation heights** without forking or modifying Terrain3D. The bridge system uses pure GDScript to populate the shader uniforms.

---

## ✅ **Why Use the Bridge?**

**Advantages:**
- ✅ **No Terrain3D fork** - Works with stock Terrain3D from Asset Library
- ✅ **Easy updates** - Update Terrain3D normally, bridge stays compatible
- ✅ **No maintenance burden** - No C++ compilation required
- ✅ **Pure GDScript** - Easy to understand and modify
- ✅ **Editor-friendly** - Configure textures visually in Inspector
- ✅ **Presets included** - Quick setup for common game styles

**How It Works:**
- Bridge script reads your texture configuration
- Populates `_texture_deform_rest_array` shader uniform via GDScript
- Updates automatically when Terrain3D material changes
- Zero modification to Terrain3D source code!

---

## 🚀 **Quick Start (5 Minutes)**

### **Step 1: Add Bridge to Scene**

```
Scene Tree:
├── Terrain3D
└── TerrainDeformationBridge  ← Add this as sibling
```

**In Godot Editor:**
1. Select your `Terrain3D` node's parent
2. Right-click → "Add Child Node"
3. Search: `Node` → Create
4. Rename to: `TerrainDeformationBridge`
5. Attach script: `res://src/core/deformation/terrain_deformation_bridge.gd`

---

### **Step 2: Create Configuration Resource**

**Option A: Use Preset (Fastest)**

1. In Inspector (with `TerrainDeformationBridge` selected):
   - `Texture Config` → Click arrow → `New TerrainDeformationTextureConfig`
   - Click the new resource to edit it
2. In Script Editor (or via Tool button):
   ```gdscript
   # Run this once in _ready() or via @tool script
   $TerrainDeformationBridge.texture_config.apply_preset(
       TerrainDeformationTextureConfig.Preset.MORROWIND
   )
   $TerrainDeformationBridge.apply_deformation_heights()
   ```

**Option B: Manual Configuration**

1. Create resource: `Texture Config` → New
2. Add entries manually:
   - Click `Texture Heights` → Add Element
   - Set `Texture Id`: 0
   - Set `Rest Height`: 0.30
   - Set `Texture Name`: "Snow"
   - Repeat for all textures...

---

### **Step 3: Link Terrain3D (Auto or Manual)**

**Auto-Detection (Default):**
- Bridge automatically finds Terrain3D if it's a sibling or parent
- Just make sure `Terrain Node` is left empty

**Manual Link:**
- Drag `Terrain3D` node into `Terrain Node` field in Inspector

---

### **Step 4: Apply Heights**

**Automatic (Default):**
- Bridge applies heights on `_ready()`
- Auto-updates if Terrain3D material changes

**Manual:**
```gdscript
$TerrainDeformationBridge.apply_deformation_heights()
```

---

## 📖 **Complete Example**

### **Scene Setup**

```
godotwind/
├── scenes/
│   └── world.tscn
│       ├── Terrain3D
│       └── TerrainDeformationBridge
└── resources/
    └── deformation/
        └── morrowind_texture_heights.tres
```

### **Configuration Resource (morrowind_texture_heights.tres)**

Create this resource in Godot Editor:

```
Right-click in FileSystem → New Resource → TerrainDeformationTextureConfig
```

Then configure:

```
Texture Heights:
  [0] Texture Id: 0,  Rest Height: 0.15, Name: "Ash (Gray)"
  [1] Texture Id: 1,  Rest Height: 0.12, Name: "Ash (Red)"
  [2] Texture Id: 2,  Rest Height: 0.00, Name: "Rock"
  [3] Texture Id: 3,  Rest Height: 0.10, Name: "Mud"
  [4] Texture Id: 4,  Rest Height: 0.05, Name: "Dirt"
  [5] Texture Id: 5,  Rest Height: 0.25, Name: "Snow"
  [6] Texture Id: 6,  Rest Height: 0.00, Name: "Cobblestone"
```

Save as: `res://resources/deformation/morrowind_texture_heights.tres`

---

### **Bridge Script Setup**

**Attach to your `TerrainDeformationBridge` node:**

```gdscript
# terrain_deformation_bridge.gd is already created
# Just configure in Inspector:

[TerrainDeformationBridge Inspector]
  Texture Config: res://resources/deformation/morrowind_texture_heights.tres
  Terrain Node: (leave empty for auto-detect)
  Auto Update: ✓ true
  Debug: ✓ true (optional, for testing)
```

---

### **Runtime Usage**

**Basic:**
```gdscript
# In your world/game initialization script
extends Node3D

func _ready():
    # Bridge automatically applies on ready!
    # Nothing else needed if you set up Inspector correctly
    pass
```

**Dynamic Updates:**
```gdscript
# Change a texture's rest height at runtime
func set_snow_depth(depth: float):
    var bridge = $TerrainDeformationBridge
    bridge.set_rest_height(5, depth)  # Texture ID 5 = Snow
```

**Debug:**
```gdscript
func _ready():
    # Print current configuration
    $TerrainDeformationBridge.print_configuration()
```

---

## 🎨 **Using Presets**

### **Available Presets**

```gdscript
enum Preset {
    CUSTOM,      # User-defined
    MORROWIND,   # Morrowind/OpenMW style
    SKYRIM,      # Skyrim style
    OBLIVION,    # Oblivion style
    SNOW_WORLD,  # Heavy snow environment
    DESERT,      # Desert/sand environment
    VOLCANIC     # Volcanic ash environment
}
```

### **Apply Preset via Code**

```gdscript
# In a @tool script or _ready()
extends Node

func _ready():
    var config = $TerrainDeformationBridge.texture_config

    # Apply Morrowind preset
    config.apply_preset(TerrainDeformationTextureConfig.Preset.MORROWIND)

    # Update Terrain3D
    $TerrainDeformationBridge.apply_deformation_heights()

    # Save the resource for reuse
    ResourceSaver.save(config, "res://my_config.tres")
```

### **Customize After Preset**

```gdscript
# Start with preset, then customize
var config = $TerrainDeformationBridge.texture_config

# Apply base preset
config.apply_preset(TerrainDeformationTextureConfig.Preset.MORROWIND)

# Override specific textures
config.set_height(5, 0.35, "Deep Solstheim Snow")  # More snow!
config.set_height(2, 0.00, "Hard Volcanic Rock")   # Ensure no deformation

# Apply to Terrain3D
$TerrainDeformationBridge.apply_deformation_heights()
```

---

## 🔍 **Advanced Usage**

### **Multiple Terrains**

```gdscript
# If you have multiple Terrain3D nodes in different scenes
extends Node

@export var terrain_configs: Array[TerrainConfig]

func _ready():
    for terrain_config in terrain_configs:
        var bridge = TerrainDeformationBridge.new()
        bridge.terrain_node = terrain_config.terrain
        bridge.texture_config = terrain_config.config
        add_child(bridge)
        bridge.apply_deformation_heights()

class TerrainConfig:
    var terrain: Terrain3D
    var config: TerrainDeformationTextureConfig
```

---

### **Editor Tool Script**

Make the bridge update in-editor as you change values:

```gdscript
# terrain_deformation_bridge.gd (add @tool)
@tool
class_name TerrainDeformationBridge
extends Node

# ... existing code ...

# Add this:
func _process(delta):
    # In-editor preview (only when @tool is active)
    if Engine.is_editor_hint() and auto_update:
        # Update every second in editor
        if Time.get_ticks_msec() % 1000 < delta * 1000:
            apply_deformation_heights()
```

---

### **Conditional Heights (Weather, Season)**

```gdscript
# Dynamically adjust heights based on game state
extends Node

@export var summer_config: TerrainDeformationTextureConfig
@export var winter_config: TerrainDeformationTextureConfig

var current_season: String = "summer"

func change_season(new_season: String):
    current_season = new_season

    var bridge = $TerrainDeformationBridge

    match new_season:
        "summer":
            bridge.texture_config = summer_config
        "winter":
            bridge.texture_config = winter_config

    bridge.apply_deformation_heights()
    print("Season changed to: ", new_season)
```

---

## 🛠️ **Texture ID Mapping**

### **How to Find Your Texture IDs**

Terrain3D assigns texture IDs based on the order in your Texture List:

```
Terrain3D → Assets → Texture List:
  [0] snow_texture.png        ← Texture ID = 0
  [1] rock_texture.png        ← Texture ID = 1
  [2] mud_texture.png         ← Texture ID = 2
  [3] grass_texture.png       ← Texture ID = 3
  etc...
```

**⚠️ Important:**
- IDs are **zero-indexed** (first texture = 0)
- If you **reorder** textures, update your config!
- Use `texture_name` field to track which is which

---

### **Automatic Mapping (Advanced)**

For large projects, create a mapping resource:

```gdscript
class_name TerrainTextureMapping
extends Resource

@export var texture_names: Dictionary = {
    "snow": 0,
    "rock": 1,
    "mud": 2,
    "grass": 3,
    # etc...
}

func get_id(name: String) -> int:
    return texture_names.get(name, -1)
```

Then use:
```gdscript
var mapping = preload("res://terrain_mapping.tres")
config.set_height(mapping.get_id("snow"), 0.30, "Snow")
```

---

## ⚡ **Performance**

**Bridge Overhead:**
- One-time cost on `_ready()` or material change
- ~0.1ms to populate 32-element array
- Zero runtime cost after application
- Shader performance unchanged

**Auto-Update Cost:**
- Connects to `material_changed` signal
- Only fires when Terrain3D reloads material
- Negligible impact

**Disable if not needed:**
```gdscript
$TerrainDeformationBridge.auto_update = false
```

---

## 🐛 **Troubleshooting**

### **Heights not applying?**

**Check 1:** Is deformation enabled in shader?
```gdscript
var material = $Terrain3D.get_material()
print(material.get_shader_parameter("deformation_enabled"))
# Should print: true
```

**Check 2:** Print current array values:
```gdscript
var material = $Terrain3D.get_material()
var heights = material.get_shader_parameter("_texture_deform_rest_array")
print("Heights: ", heights)
# Should show your configured values
```

**Check 3:** Is bridge finding Terrain3D?
```gdscript
print($TerrainDeformationBridge.terrain_node)
# Should print: Terrain3D node reference
```

---

### **Texture IDs don't match?**

**Solution:** Export texture list from Terrain3D:
```gdscript
func print_terrain_textures():
    var terrain = $Terrain3D
    var assets = terrain.get_assets()
    var texture_list = assets.get_texture_list()

    print("=== Terrain3D Texture IDs ===")
    for i in texture_list.size():
        var tex = texture_list[i]
        print("[%d] %s" % [i, tex.get_name() if tex else "Empty"])
```

Then update your config to match!

---

### **Bridge not auto-updating?**

**Fix:** Manually trigger update:
```gdscript
# After changing config
$TerrainDeformationBridge.update_heights()
```

Or check signal connection:
```gdscript
print($Terrain3D.is_connected("material_changed",
    $TerrainDeformationBridge._on_material_changed))
# Should print: true
```

---

## 📝 **Example Configurations**

### **Morrowind (Vvardenfell)**

```gdscript
var config = TerrainDeformationTextureConfig.new()

# Ash Wastes
config.set_height(0, 0.15, "Ash (Gray)")
config.set_height(1, 0.12, "Ash (Red)")

# Rock
config.set_height(2, 0.00, "Volcanic Rock")
config.set_height(3, 0.00, "Black Rock")

# Organic
config.set_height(4, 0.10, "Mud (Bitter Coast)")
config.set_height(5, 0.05, "Dirt")
config.set_height(6, 0.03, "Grass (Grazelands)")

# Special
config.set_height(7, 0.25, "Snow (Solstheim)")
config.set_height(8, 0.08, "Sand")
config.set_height(9, 0.00, "Cobblestone")
```

---

### **Skyrim (Nordic)**

```gdscript
var config = TerrainDeformationTextureConfig.new()

# Snow (primary)
config.set_height(0, 0.35, "Deep Snow")
config.set_height(1, 0.25, "Medium Snow")
config.set_height(2, 0.15, "Light Snow")

# Terrain
config.set_height(3, 0.00, "Mountain Rock")
config.set_height(4, 0.05, "Tundra Dirt")
config.set_height(5, 0.03, "Grass")

# Special
config.set_height(6, 0.00, "Ice")
config.set_height(7, 0.00, "Stone (Ruins)")
```

---

## 🔄 **Migration from Manual Method**

If you were using the manual `set_shader_parameter()` method:

**Before:**
```gdscript
func setup_deformation_heights():
    var heights = PackedFloat32Array()
    heights.resize(32)
    heights.fill(0.0)
    heights[0] = 0.30  # Snow
    heights[1] = 0.00  # Rock
    # etc...

    var material = $Terrain3D.get_material()
    material.set_shader_parameter("_texture_deform_rest_array", heights)
```

**After:**
```gdscript
# Create config resource (once)
var config = TerrainDeformationTextureConfig.new()
config.set_height(0, 0.30, "Snow")
config.set_height(1, 0.00, "Rock")
# etc...
ResourceSaver.save(config, "res://my_config.tres")

# Use bridge (in scene)
$TerrainDeformationBridge.texture_config = preload("res://my_config.tres")
$TerrainDeformationBridge.apply_deformation_heights()
```

**Benefits:**
- ✅ Resource saved in editor (no code needed)
- ✅ Auto-updates on material change
- ✅ Visual configuration in Inspector
- ✅ Reusable across scenes

---

## 📚 **Complete File List**

**Required Files:**
- `src/core/deformation/terrain_deformation_bridge.gd` - Bridge script
- `src/core/deformation/terrain_deformation_texture_config.gd` - Config resource

**Your Resources:**
- `resources/deformation/my_texture_config.tres` - Your texture heights

**Scene Setup:**
- Add `TerrainDeformationBridge` node
- Assign config resource
- Done!

---

## ✅ **Summary**

**GDScript Bridge Advantages:**
- ✅ **No Terrain3D modification** - Works with stock version
- ✅ **Easy updates** - Update Terrain3D without conflicts
- ✅ **Visual configuration** - Use Inspector, no code needed
- ✅ **Presets included** - Quick start for common games
- ✅ **Runtime dynamic** - Change heights during gameplay
- ✅ **Auto-updates** - Reapplies on material changes
- ✅ **Zero performance cost** - One-time application only

**You can now have per-texture deformation without forking Terrain3D!** 🎉

---

**Created:** 2025-12-22
**Compatible:** Terrain3D 1.0.1+ (stock)
**Maintenance:** Zero - pure GDScript
