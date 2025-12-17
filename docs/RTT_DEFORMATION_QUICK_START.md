# RTT Deformation System - Quick Start Guide

## Quick Reference

### Basic Usage

```gdscript
# 1. Attach to player
var agent = DeformableAgent.new()
player.add_child(agent)
agent.deformation_radius = 0.3  # Footprint size
agent.deformation_strength = 1.0

# 2. Set material type (in scene or code)
DeformationManager.set_material_preset("Snow")  # or "Mud", "Ash"

# 3. System auto-manages chunks and rendering
# No further setup needed!
```

### Material Preset Comparison

| Property | Snow | Mud | Ash |
|----------|------|-----|-----|
| **Max Depth** | 0.4m | 0.25m | 0.5m |
| **Accumulation** | Medium (0.6) | High (0.8) | High (0.7) |
| **Decay** | Very Slow | None | Medium |
| **Edge Sharpness** | Soft (0.3) | Sharp (0.7) | Very Soft (0.2) |
| **Best For** | Winter biomes | Wetlands | Volcanic regions |

### Performance Settings

```gdscript
# High Quality (expensive)
DeformationManager.texture_resolution = 1024
DeformationManager.max_active_chunks = 25

# Medium Quality (recommended)
DeformationManager.texture_resolution = 512
DeformationManager.max_active_chunks = 25

# Low Quality (mobile/low-end)
DeformationManager.texture_resolution = 256
DeformationManager.max_active_chunks = 16
```

### Memory Usage Estimation

```
Chunks × Resolution × Format = Total Memory
25 × 512² × RGBA16F = ~25 MB (Medium)
25 × 1024² × RGBA16F = ~100 MB (High)
16 × 256² × RGBA16F = ~4 MB (Low)
```

---

## Integration Checklist

### For Terrain
- [ ] Add `deformation_texture_chunk` uniform to terrain shader
- [ ] Implement vertex displacement in `vertex()` function
- [ ] Sample deformation for visual darkening in `fragment()`
- [ ] Connect to `DeformationManager.chunk_texture_updated` signal

### For Grass
- [ ] Add `deformation_texture` uniform to grass shader
- [ ] Sample deformation in `vertex()` function
- [ ] Apply displacement + flattening
- [ ] Test with/without wind animation

### For Agents
- [ ] Attach `DeformableAgent` to player/NPCs
- [ ] Configure radius based on character size
- [ ] Adjust frequency for walking vs running
- [ ] Test velocity threshold

### For Persistence
- [ ] Enable `DeformationManager.enable_persistence`
- [ ] Set save interval (default: 10s)
- [ ] Create `godotwind_data/deformation_cache/` directory
- [ ] Test save/load on scene reload

---

## Common Patterns

### Dynamic Material Switching

```gdscript
# Switch based on biome
func _on_enter_biome(biome_name: String) -> void:
    match biome_name:
        "Snowy_Mountains":
            DeformationManager.set_material_preset("Snow")
        "Swamp":
            DeformationManager.set_material_preset("Mud")
        "Red_Mountain":
            DeformationManager.set_material_preset("Ash")
```

### Vehicle Deformation

```gdscript
# Attach to vehicle
var vehicle_deform = VehicleDeformable.new()
vehicle.add_child(vehicle_deform)
vehicle_deform.tire_spacing = 1.8  # Distance between wheels
vehicle_deform.tire_width = 0.2
vehicle_deform.deformation_strength = 1.5  # Heavier than footprints
```

### Custom Brush Shapes

```gdscript
# Apply custom deformation
DeformationManager.apply_deformation(position, {
    "radius": 2.0,
    "strength": 0.8,
    "shape": "ellipse",  # "circle" (default), "ellipse", "square"
    "rotation": Vector2(1, 0),  # For directional shapes
    "falloff_curve": my_custom_curve,  # Optional Curve resource
})
```

---

## Debugging

### Visualize Deformation Textures

```gdscript
# Show deformation as overlay
func _debug_show_deformation() -> void:
    var chunk = DeformationManager.get_chunk_at(player.position)
    if chunk:
        var debug_quad = MeshInstance3D.new()
        debug_quad.mesh = QuadMesh.new()
        debug_quad.material_override = StandardMaterial3D.new()
        debug_quad.material_override.albedo_texture = chunk.deformation_texture
        debug_quad.position = Vector3(0, 50, 0)  # Above player
        debug_quad.rotation.x = -PI/2
        add_child(debug_quad)
```

### Print Performance Stats

```gdscript
# In DeformationManager
func print_stats() -> void:
    print("=== Deformation System Stats ===")
    print("Active chunks: %d" % active_chunks.size())
    print("Pooled viewports: %d" % viewport_pool.size())
    print("Dirty chunks: %d" % _get_dirty_count())
    print("Memory (est): %.1f MB" % _estimate_memory_mb())

func _estimate_memory_mb() -> float:
    var bytes_per_chunk = texture_resolution * texture_resolution * 8  # RGBA16F
    return (active_chunks.size() * bytes_per_chunk) / (1024.0 * 1024.0)
```

---

## Troubleshooting

### Problem: Deformation not visible

**Solutions:**
- Check `DeformationManager.enabled = true`
- Verify terrain shader has deformation sampling code
- Ensure chunk is loaded: `DeformationManager.get_chunk_at(position) != null`
- Check deformation strength > 0
- Verify agent velocity > `min_velocity`

### Problem: Performance drops

**Solutions:**
- Reduce `texture_resolution` (512 → 256)
- Lower `max_active_chunks` (25 → 16)
- Disable decay for static materials (mud)
- Reduce `deformation_frequency` on agents
- Check for chunk thrashing (camera moving rapidly)

### Problem: Seams at chunk boundaries

**Solutions:**
- Implement edge overlap sampling (see full doc §10)
- Increase chunk size (256m → 512m) - fewer chunks
- Reduce deformation radius near edges
- Enable texture filtering (linear vs nearest)

### Problem: Memory usage too high

**Solutions:**
- Use lower texture resolution
- Reduce max_active_chunks
- Enable aggressive chunk unloading
- Clear persistence cache periodically

### Problem: Deformation not persisting

**Solutions:**
- Check `enable_persistence = true`
- Verify directory exists: `godotwind_data/deformation_cache/`
- Ensure write permissions
- Check manifest.json is being updated
- Manually call `save_dirty_chunks()` before quit

---

## Advanced Configuration

### Custom Material Preset

```gdscript
# Create custom material
var sand_preset = DeformationPreset.new()
sand_preset.material_name = "Sand"
sand_preset.max_depth = 0.15  # Shallow impressions
sand_preset.compression_factor = 0.5
sand_preset.enable_accumulation = false  # Wind erases quickly
sand_preset.enable_decay = true
sand_preset.decay_rate = 0.15  # Fast decay
sand_preset.decay_delay = 3.0  # Quick fade
sand_preset.edge_sharpness = 0.4
sand_preset.color_tint = Color(1.0, 0.95, 0.85)

# Register with manager
DeformationManager.register_preset("Sand", sand_preset)
```

### Slope-Based Deformation

```gdscript
# In DeformationPreset
sand_preset.max_slope_angle = 30.0  # No deformation on slopes > 30°
snow_preset.max_slope_angle = 45.0  # Snow can stick to steeper slopes
```

### Seasonal Decay Variation

```gdscript
# Adjust decay based on temperature
func update_season_decay(temperature: float) -> void:
    if temperature > 0.0:  # Above freezing
        snow_preset.decay_rate = 0.05  # Faster melting
    else:
        snow_preset.decay_rate = 0.01  # Slow sublimation
```

---

## API Quick Reference

### DeformationManager

```gdscript
# Singleton: DeformationManager

# Configuration
var enabled: bool
var texture_resolution: int
var max_active_chunks: int
var enable_persistence: bool

# Methods
func set_material_preset(name: String) -> void
func register_preset(name: String, preset: DeformationPreset) -> void
func get_chunk_at(world_pos: Vector3) -> DeformationChunk
func apply_deformation(world_pos: Vector3, settings: Dictionary) -> void
func save_dirty_chunks() -> void
func clear_all_deformations() -> void
```

### DeformableAgent

```gdscript
# Attach to deforming entities

# Configuration
@export var deformation_radius: float = 0.3
@export var deformation_strength: float = 1.0
@export var deformation_frequency: float = 10.0  # Hz
@export var min_velocity: float = 0.1

# Automatic deformation in _physics_process
```

### DeformationPreset

```gdscript
# Resource for material behavior

# Key properties
@export var max_depth: float
@export var enable_accumulation: bool
@export var accumulation_rate: float
@export var enable_decay: bool
@export var decay_rate: float
@export var edge_sharpness: float
```

---

## File Structure

```
res://
├── src/
│   └── core/
│       └── deformation/
│           ├── deformation_manager.gd       # Singleton
│           ├── deformation_chunk.gd         # Chunk class
│           ├── deformation_preset.gd        # Resource
│           ├── deformable_agent.gd          # Component
│           ├── vehicle_deformable.gd        # Vehicle variant
│           └── shaders/
│               ├── deformation_brush.gdshader
│               ├── terrain_deformation.gdshader
│               └── grass_deformation.gdshader
├── scenes/
│   └── test_deformation.tscn                # Test scene
└── docs/
    ├── RTT_DEFORMATION_SYSTEM.md            # Full design doc
    └── RTT_DEFORMATION_QUICK_START.md       # This file
```

---

## Next Steps

1. **Read full design**: `docs/RTT_DEFORMATION_SYSTEM.md`
2. **Implement Phase 1**: Core DeformationManager + basic RTT
3. **Create test scene**: Single chunk with player deformation
4. **Integrate with terrain**: Modify terrain shader
5. **Add grass support**: Update grass shader
6. **Tune performance**: Profile and optimize
7. **Add persistence**: Save/load system

---

**Last Updated**: 2025-12-17
**Related**: `RTT_DEFORMATION_SYSTEM.md`
