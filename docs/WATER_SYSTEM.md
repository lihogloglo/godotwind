# Water System Documentation

Godotwind includes two complementary water systems for different use cases:

1. **OceanManager** - Infinite ocean plane that follows the camera (exterior cells)
2. **WaterVolume** - Bounded water volumes for lakes, rivers, and pools (interior/exterior)

---

## Ocean System

### Overview

The ocean system provides an infinite water plane that follows the camera, with multi-LOD clipmap rendering and GPU-accelerated wave simulation. It's designed for Morrowind's exterior ocean.

### Features

- **Multiple Quality Levels:**
  - **HIGH** - GPU FFT compute shaders (3 cascades) for realistic ocean waves
  - **MEDIUM** - Vertex Gerstner waves (4 waves) with full GGX lighting
  - **LOW** - Simplified Gerstner waves (2 waves) for weak GPUs
  - **ULTRA_LOW** - Flat plane for software renderers

- **Visual Features:**
  - Physically-based Fresnel reflections
  - Screen-space refraction
  - Depth-based transparency
  - Subsurface scattering (SSS)
  - Dynamic foam on wave crests
  - Shore mask integration with Terrain3D

- **Physics Integration:**
  - Buoyancy system for floating objects
  - Wave height queries for boats/swimming
  - Shore dampening near land

### Setup

#### 1. Required Global Shader Parameters

**CRITICAL**: For FFT ocean waves (HIGH quality) to work, you must define global shader parameters in `project.godot`:

\`\`\`ini
[shader_globals]

displacements={
"type": "sampler2DArray",
"value": ""
}
normals={
"type": "sampler2DArray",
"value": ""
}
num_cascades={
"type": "uint",
"value": 3
}
water_color={
"type": "color",
"value": Color(0.02, 0.12, 0.22, 1)
}
foam_color={
"type": "color",
"value": Color(0.9, 0.9, 0.9, 1)
}
\`\`\`

These are automatically set by the project and should already be configured. If FFT waves don't appear, verify this section exists.

#### 2. Enable Ocean in Project Settings

Edit `project.godot`:

\`\`\`ini
[ocean]
enabled=true
sea_level=0.0
radius=8000.0
quality=-1  # -1 = auto-detect, 0-3 = specific quality
\`\`\`

#### 3. Ocean Auto-Initializes

The OceanManager is an autoload singleton that initializes automatically when enabled. It will:
- Detect your GPU and select appropriate quality level
- Find the active camera automatically
- Generate shore masks from Terrain3D if available
- Create the ocean mesh and position it at sea level

#### 4. Manual Control (Optional)

\`\`\`gdscript
# Force initialization (if ocean/enabled=false but you want it in specific scene)
OceanManager.force_initialize()

# Set custom camera
OceanManager.set_camera(my_camera)

# Change sea level
OceanManager.set_sea_level(-1000.0)  # Morrowind sea level

# Toggle ocean on/off at runtime
OceanManager.toggle_ocean()

# Query wave height for buoyancy
var wave_height = OceanManager.get_wave_height(world_position)

# Check if position is in ocean
var in_ocean = OceanManager.is_in_ocean(world_position)
\`\`\`

### Configuration

Ocean parameters can be set via the OceanManager node or script:

\`\`\`gdscript
@export var ocean_radius: float = 8000.0  # Clipmap radius in meters
@export var wave_update_rate: int = 30    # Wave updates per second (GPU compute)
@export var shore_fade_distance: float = 50.0  # Fade waves near shore

# Wave parameters
@export var wind_speed: float = 10.0      # m/s
@export var wind_direction: float = 0.0   # radians
@export var wave_scale: float = 1.0       # Overall wave height multiplier
@export var choppiness: float = 1.0       # Wave sharpness

# Visual
@export var water_color: Color = Color(0.02, 0.08, 0.15, 1.0)
@export var foam_color: Color = Color(0.9, 0.9, 0.9, 1.0)
@export var depth_color_absorption: Vector3 = Vector3(7.5, 22.0, 38.0)
\`\`\`

### Shaders

Ocean shaders are located in `src/core/water/shaders/`:

- **ocean_compute.gdshader** - HIGH quality (GPU FFT)
- **ocean_gerstner.gdshader** - MEDIUM quality (4 Gerstner waves)
- **ocean_low.gdshader** - LOW quality (2 Gerstner waves)
- **ocean_flat.gdshader** - ULTRA_LOW quality (flat plane)

All shaders now include:
- ✅ Transparency and refraction
- ✅ Screen-space reflections (SSR)
- ✅ Depth-based blending
- ✅ Fresnel effect
- ✅ Subsurface scattering

### Buoyancy System

Attach `BuoyantBody` to any RigidBody3D to make it float:

\`\`\`gdscript
# Add to a boat/ship RigidBody3D
var buoyant_body = $BuoyantBody
buoyant_body.enabled = true
buoyant_body.fluid_density = 1025.0  # Seawater density
buoyant_body.drag_coefficient = 0.5
buoyant_body.auto_generate_cells = true
buoyant_body.auto_cell_count = 12
\`\`\`

The BuoyantBody will:
- Query wave heights from OceanManager
- Apply distributed buoyancy forces at each cell
- Calculate realistic tilting on waves
- Apply water drag

---

## WaterVolume System

### Overview

WaterVolume provides bounded water bodies for lakes, rivers, pools, and indoor water. Each volume is independent and configurable.

### Features

- **Water Types:**
  - **LAKE** - Still water with gentle waves
  - **RIVER** - Flowing water with current
  - **POOL** - Calm water with no waves
  - **OCEAN** - (Use OceanManager instead)

- **Visual Features:**
  - Screen-space refraction
  - Depth-based transparency
  - Simple wave simulation
  - River flow animation
  - SSR support

- **Gameplay Features:**
  - Swimming detection
  - Buoyancy for physics objects
  - River current forces
  - Customizable per-volume

### Setup

#### 1. Create WaterVolume Scene

\`\`\`
Add Node → Node3D → Set script to water_volume.gd
\`\`\`

Or use example scenes:
- `scenes/water_examples/lake.tscn`
- `scenes/water_examples/river.tscn`

#### 2. Configure Volume

\`\`\`gdscript
# In Inspector or code:
var water = WaterVolume.new()
add_child(water)

# Set dimensions
water.size = Vector3(50, 10, 50)  # Width, depth, length
water.water_surface_height = 0.0  # Y position of water surface

# Set type
water.water_type = WaterVolume.WaterType.LAKE

# Visual settings
water.water_color = Color(0.02, 0.15, 0.22)
water.clarity = 0.5  # 0 = opaque, 1 = transparent
water.roughness = 0.1
water.enable_waves = true
water.wave_scale = 0.3

# For rivers
if water.water_type == WaterVolume.WaterType.RIVER:
    water.flow_direction = Vector2(1, 0)  # Flow along X axis
    water.flow_speed = 2.0
    water.current_strength = 1.5
\`\`\`

#### 3. Connect Signals

\`\`\`gdscript
water.body_entered_water.connect(_on_body_entered_water)
water.body_exited_water.connect(_on_body_exited_water)
water.body_swimming.connect(_on_body_swimming)

func _on_body_entered_water(body: Node3D):
    print("Body entered water: ", body.name)

func _on_body_swimming(body: Node3D):
    # Apply swimming mechanics
    if body is CharacterBody3D:
        body.velocity *= 0.6  # Slow down movement
\`\`\`

### Configuration Reference

\`\`\`gdscript
# Dimensions
@export var size: Vector3 = Vector3(20, 5, 20)
@export var water_surface_height: float = 0.0

# Visual
@export var water_color: Color = Color(0.02, 0.15, 0.22, 1.0)
@export var clarity: float = 0.5            # 0-1, transparency
@export var roughness: float = 0.1          # 0-1, surface roughness
@export var refraction_strength: float = 0.05  # 0-0.3, distortion amount

# Waves
@export var enable_waves: bool = true
@export var wave_scale: float = 0.3         # Wave height multiplier
@export var wave_speed: float = 1.0         # Animation speed

# River (only for RIVER type)
@export var flow_direction: Vector2 = Vector2(1, 0)  # Normalized
@export var flow_speed: float = 2.0         # Flow animation speed
@export var current_strength: float = 1.0   # Force applied to bodies

# Gameplay
@export var enable_swimming: bool = true
@export var enable_buoyancy: bool = true
@export var swim_speed_multiplier: float = 0.6  # Movement penalty
\`\`\`

### API Reference

\`\`\`gdscript
# Query methods
water.is_position_in_water(world_pos: Vector3) -> bool
water.get_water_height(world_pos: Vector3) -> float
water.is_body_in_water(body: Node3D) -> bool
water.get_bodies_in_water() -> Array[Node3D]

# Signals
signal body_entered_water(body: Node3D)
signal body_exited_water(body: Node3D)
signal body_swimming(body: Node3D)
\`\`\`

---

## Usage Examples

### Morrowind-style Ocean

\`\`\`gdscript
# Set sea level to Morrowind's value
OceanManager.set_sea_level(-1000.0)  # Or whatever Morrowind uses

# Set ocean color to match Morrowind
OceanManager.water_color = Color(0.02, 0.1, 0.15)

# Adjust wave parameters
OceanManager.wave_scale = 0.8
OceanManager.wind_speed = 12.0
\`\`\`

### Lake in Forest

\`\`\`gdscript
var lake = WaterVolume.new()
add_child(lake)
lake.water_type = WaterVolume.WaterType.LAKE
lake.size = Vector3(100, 20, 100)
lake.water_color = Color(0.01, 0.12, 0.15)  # Darker for forest lake
lake.clarity = 0.3  # Murky water
lake.wave_scale = 0.2  # Gentle waves
\`\`\`

### Fast-Flowing River

\`\`\`gdscript
var river = WaterVolume.new()
add_child(river)
river.water_type = WaterVolume.WaterType.RIVER
river.size = Vector3(15, 8, 200)  # Long and narrow
river.flow_direction = Vector2(0, 1)  # Flow along Z axis
river.flow_speed = 3.0
river.current_strength = 2.0  # Strong current
river.wave_scale = 0.15
river.clarity = 0.7  # Clear mountain stream
\`\`\`

### Indoor Pool (No Waves)

\`\`\`gdscript
var pool = WaterVolume.new()
add_child(pool)
pool.water_type = WaterVolume.WaterType.POOL
pool.size = Vector3(10, 3, 20)
pool.enable_waves = false  # Still water
pool.clarity = 0.8  # Very clear
pool.roughness = 0.05  # Very smooth surface
\`\`\`

### Swimming Character

\`\`\`gdscript
extends CharacterBody3D

var in_water: bool = false
var swimming: bool = false

func _ready():
    # Connect to all WaterVolumes in scene
    for water in get_tree().get_nodes_in_group("water_volumes"):
        water.body_entered_water.connect(_on_entered_water)
        water.body_exited_water.connect(_on_exited_water)

func _on_entered_water(body):
    if body == self:
        in_water = true

func _on_exited_water(body):
    if body == self:
        in_water = false
        swimming = false

func _physics_process(delta):
    if in_water:
        var water_level = _get_water_level()
        swimming = global_position.y < water_level

        if swimming:
            # Apply swimming movement penalty
            velocity *= 0.6
            # Reduce gravity
            velocity.y += 9.8 * 0.8 * delta
\`\`\`

---

## Performance Considerations

### Ocean System

- **HIGH quality (GPU FFT)** - Requires dedicated GPU, 1-2ms per frame
- **MEDIUM quality (Gerstner)** - Works on integrated GPUs, 0.5-1ms per frame
- **LOW quality** - Works on all GPUs, 0.2-0.5ms per frame
- **ULTRA_LOW** - Minimal performance impact, <0.1ms per frame

The system auto-detects GPU and selects appropriate quality.

### WaterVolume System

- Each volume adds a draw call and Area3D monitoring
- Keep volumes to reasonable size (< 20 active volumes)
- Disable waves for indoor/pool water to save performance
- Use lower subdivision counts for distant water

---

## Troubleshooting

### Ocean doesn't appear

1. Check `project.godot`: `[ocean] enabled=true`
2. Verify camera is active: `OceanManager.set_camera(camera)`
3. Check sea level: Ocean plane is at `OceanManager.sea_level`
4. Try `OceanManager.force_initialize()` if disabled by default

### Ocean is invisible/transparent

1. Shaders updated - may need to adjust `water_clarity` parameter
2. Check water_color alpha channel (should be 1.0)
3. Verify material_override is set on ocean mesh

### WaterVolume not detecting bodies

1. Ensure Area3D monitoring is enabled (automatic)
2. Check that bodies have CollisionShape3D
3. Verify body is CharacterBody3D or RigidBody3D
4. Connect to signals to debug: `body_entered_water.connect()`

### Poor performance

1. Ocean: Lower quality level in project settings
2. WaterVolume: Reduce mesh subdivision
3. Disable waves on distant/indoor water
4. Reduce number of active water volumes

### Refraction looks wrong

1. Adjust `refraction_strength` (default 0.05)
2. Check that SCREEN_TEXTURE is available (Forward+ renderer)
3. Verify depth texture is enabled in project settings

---

## Technical Details

### Shader Features

All water shaders include:

- **Transparency** - `blend_mix` mode with depth-based alpha
- **Refraction** - SCREEN_TEXTURE sampling with normal-based offset
- **Reflections** - Fresnel-based mixing, SSR compatible
- **Depth Fade** - Exponential falloff based on water depth
- **Subsurface Scattering** - Light transmission through wave peaks
- **Physically-Based Lighting** - GGX microfacet BRDF

### Ocean Wave Generation

- **GPU Compute (HIGH)** - FFT-based JONSWAP spectrum
  - 256x256 displacement maps per cascade
  - 3 cascades at different scales (250m, 67m, 17m tiles)
  - Real-time FFT on GPU using compute shaders
  - Based on: https://github.com/2Retr0/GodotOceanWaves

- **Vertex Gerstner (MEDIUM/LOW)** - Analytical wave function
  - Sum of 2-4 sinusoidal waves
  - Different wavelengths, directions, phase speeds
  - Calculated in vertex shader (no textures)

### WaterVolume Detection

- Uses Area3D with BoxShape3D
- Monitors body_entered/body_exited signals
- Calculates submersion based on body position vs water level
- Applies forces to RigidBody3D objects automatically

---

## File Structure

\`\`\`
src/core/water/
├── ocean_manager.gd           # Main ocean singleton
├── ocean_mesh.gd              # Clipmap mesh rendering
├── wave_generator.gd          # GPU FFT wave computation
├── buoyant_body.gd            # Buoyancy physics component
├── shore_mask_generator.gd    # Terrain integration
├── hardware_detection.gd      # Quality auto-detection
├── wave_cascade_parameters.gd # Wave configuration
├── rendering_context.gd       # GPU compute helpers
├── water_volume.gd            # Volume-based water system
└── shaders/
    ├── ocean_compute.gdshader     # HIGH quality
    ├── ocean_gerstner.gdshader    # MEDIUM quality
    ├── ocean_low.gdshader         # LOW quality
    ├── ocean_flat.gdshader        # ULTRA_LOW quality
    └── compute/                   # GPU compute shaders
        ├── spectrum_compute.glsl
        ├── spectrum_modulate.glsl
        ├── fft_butterfly.glsl
        ├── fft_compute.glsl
        ├── transpose.glsl
        └── fft_unpack.glsl

scenes/water_examples/
├── lake.tscn                  # Example lake
└── river.tscn                 # Example river
\`\`\`

---

## Credits

- Ocean system based on: [GodotOceanWaves](https://github.com/2Retr0/GodotOceanWaves) (MIT License)
- Lighting model: GDC 2019 - "Interactive Water Simulation in Atlas"
- Wave simulation: Jerry Tessendorf - "Simulating Ocean Water"
- Gerstner waves: NVIDIA GPU Gems - Chapter 1

---

## Future Improvements

- [ ] Underwater post-processing (fog, caustics, god rays)
- [ ] Splashes and particle effects
- [ ] Foam trails from boats
- [ ] Dynamic wave interaction (boat wakes)
- [ ] Waterfalls and cascades
- [ ] Shoreline foam and wetness
- [ ] Integration with weather system
