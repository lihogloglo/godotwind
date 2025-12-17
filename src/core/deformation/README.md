# RTT Deformation System - Implementation Guide

## ⚠️ Important: This System is OPTIONAL and DISABLED by Default

The deformation system is **completely optional** and adds zero overhead when disabled. You must explicitly enable it to use it.

**Quick Enable:**
```gdscript
# Add to project.godot or enable at runtime:
DeformationConfig.enable_system()
```

See [CONFIGURATION.md](CONFIGURATION.md) for full configuration options.

---

## Overview

The RTT (Render-to-Texture) deformation system provides dynamic ground deformation for snow, mud, ash, and sand. It integrates with Terrain3D and supports streaming, persistence, and recovery.

**Status:** Core system implemented, disabled by default for safety.

## Components

### Core Files
- **deformation_manager.gd** - Main singleton coordinating all systems
- **deformation_renderer.gd** - Handles RTT rendering with SubViewport
- **deformation_streamer.gd** - Manages region loading/unloading
- **deformation_compositor.gd** - Handles recovery and blending
- **terrain_deformation_integration.gd** - Bridges with Terrain3D

### Shaders
- **deformation_stamp.gdshader** - Renders deformation stamps
- **deformation_recovery.gdshader** - Time-based recovery system

## Quick Start

### 0. Enable the System First!

**The system is disabled by default.** Enable it before use:

```gdscript
# Method 1: Enable at runtime (in your game's initialization)
func _ready():
    DeformationConfig.enable_system()
```

Or add to `project.godot`:
```ini
[deformation]
enabled=true
```

**See [CONFIGURATION.md](CONFIGURATION.md) for all configuration options.**

---

### 1. Basic Usage

Once enabled, the DeformationManager is available as an autoload. To add deformation from any script:

```gdscript
# Add deformation at a world position
DeformationManager.add_deformation(
    Vector3(100, 0, 50),  # World position
    DeformationManager.MaterialType.SNOW,  # Material type
    0.5  # Strength (0.0 to 1.0)
)
```

### 2. Player Integration Example

Add this to your player controller script:

```gdscript
# player_controller.gd
extends CharacterBody3D

# Deformation settings
@export var deformation_enabled: bool = true
@export var deformation_material: DeformationManager.MaterialType = DeformationManager.MaterialType.SNOW
@export var deformation_strength: float = 0.3

func _physics_process(delta):
    # Normal movement
    move_and_slide()

    # Apply deformation when moving
    if deformation_enabled and velocity.length() > 0.1:
        DeformationManager.add_deformation(
            global_position,
            deformation_material,
            deformation_strength * delta
        )
```

### 3. Terrain3D Integration

The system will automatically try to find and integrate with Terrain3D. To manually set it up:

```gdscript
# In your world setup script
func _ready():
    # The integration will auto-connect if Terrain3D is in the scene
    # No manual setup required!

    # Optional: Enable/disable deformation
    DeformationManager.set_deformation_enabled(true)
```

### 4. Streaming Integration

The system automatically hooks into GenericTerrainStreamer if available. For manual region management:

```gdscript
# Load regions around a position
var streamer = DeformationManager._streamer
streamer.load_regions_around_position(player_position, radius=2)

# Cleanup distant regions
DeformationManager.cleanup_distant_regions(camera_position)
```

### 5. Recovery System

Enable time-based recovery (deformations gradually fade):

```gdscript
# Enable recovery
DeformationManager.set_recovery_enabled(true)

# Set recovery rate (units per second)
# 0.01 = 1% recovery per second
DeformationManager.set_recovery_rate(0.01)
```

## Material Types

### MaterialType.SNOW (0)
- **Behavior:** Accumulates easily, recovers slowly
- **Max Depth:** 20cm
- **Recovery:** Very slow (footprints last minutes)
- **Visual:** Bright, soft edges

### MaterialType.MUD (1)
- **Behavior:** Replaces but doesn't accumulate
- **Max Depth:** 8cm
- **Recovery:** Extremely slow (footprints last long)
- **Visual:** Dark, wet appearance

### MaterialType.ASH (2)
- **Behavior:** Medium accumulation
- **Max Depth:** 15cm
- **Recovery:** Medium (wind can fill in)
- **Visual:** Gray, dusty

### MaterialType.SAND (3)
- **Behavior:** Minimal accumulation
- **Max Depth:** 5cm
- **Recovery:** Fast (collapses back quickly)
- **Visual:** Flows naturally

## Configuration

### Performance Tuning

```gdscript
# In deformation_manager.gd constants:
const DEFORMATION_UPDATE_BUDGET_MS: float = 2.0  # Time budget per frame
const MAX_ACTIVE_REGIONS: int = 9  # 3x3 grid
const DEFORMATION_TEXTURE_SIZE: int = 1024  # Resolution per region
```

### Memory Usage

- **Per Region:** 4MB (RG16F 1024x1024)
- **Total (9 regions):** ~36MB
- **Reduce resolution to 512x512:** 9MB total

## Testing

### Simple Test Script

Create a test scene with this script:

```gdscript
# test_deformation.gd
extends Node3D

func _ready():
    print("Deformation system test")

    # Enable deformation
    DeformationManager.set_deformation_enabled(true)

    # Load test region
    var test_region = Vector2i(0, 0)
    DeformationManager.load_deformation_region(test_region)

    # Wait a frame
    await get_tree().process_frame

    # Apply test deformation
    for i in range(10):
        var pos = Vector3(i * 2.0, 0, 0)
        DeformationManager.add_deformation(
            pos,
            DeformationManager.MaterialType.SNOW,
            1.0
        )

    print("Test deformations applied")

func _input(event):
    # Press SPACE to add deformation at camera position
    if event is InputEventKey and event.pressed and event.keycode == KEY_SPACE:
        var camera = get_viewport().get_camera_3d()
        if camera:
            DeformationManager.add_deformation(
                camera.global_position,
                DeformationManager.MaterialType.SNOW,
                0.5
            )
            print("Deformation added at: ", camera.global_position)
```

### Verification Checklist

- [ ] DeformationManager loads without errors
- [ ] Regions load/unload correctly
- [ ] Deformation textures update when add_deformation is called
- [ ] Recovery system works (if enabled)
- [ ] Terrain3D integration connects (if Terrain3D is present)

## Troubleshooting

### Issue: Deformation not visible on terrain

**Possible causes:**
1. Terrain3D not found - Check console for integration messages
2. Shader not configured - Terrain3D shader needs deformation support
3. Deformation disabled - Check `DeformationManager.deformation_enabled`

**Solutions:**
- Verify Terrain3D is in the scene
- Check that terrain material has deformation shader parameters
- Enable deformation: `DeformationManager.set_deformation_enabled(true)`

### Issue: Performance drops

**Possible causes:**
1. Too many deformations per frame
2. High texture resolution
3. Too many active regions

**Solutions:**
- Reduce `DEFORMATION_UPDATE_BUDGET_MS`
- Lower `DEFORMATION_TEXTURE_SIZE` to 512
- Reduce `MAX_ACTIVE_REGIONS`

### Issue: Regions not loading

**Possible causes:**
1. Streamer not connected to terrain system
2. Manual region management needed

**Solutions:**
- Check console for streamer connection messages
- Manually load regions: `DeformationManager.load_deformation_region(coord)`

## Next Steps

### Phase 1: Basic Testing (Current)
Test the core system with manual deformation calls.

### Phase 2: Terrain Shader Integration
Modify Terrain3D shader to sample and apply deformation textures.

### Phase 3: Grass Deformation
Implement grass system with deformation support.

### Phase 4: Persistence
Save/load deformation state to disk.

## Advanced Features

### Custom Deformation Patterns

```gdscript
# Create circular deformation pattern
func create_circular_deformation(center: Vector3, radius: float):
    var steps = 20
    for i in range(steps):
        var angle = (i / float(steps)) * TAU
        var offset = Vector3(cos(angle), 0, sin(angle)) * radius
        DeformationManager.add_deformation(
            center + offset,
            DeformationManager.MaterialType.SNOW,
            0.5
        )
```

### Multi-Entity Deformation

```gdscript
# NPCs, creatures, vehicles all leave tracks
func _on_entity_moved(entity_position: Vector3, entity_weight: float):
    var material_type = _get_ground_material_type(entity_position)
    var strength = entity_weight / 100.0  # Normalize weight

    DeformationManager.add_deformation(
        entity_position,
        material_type,
        strength
    )
```

## API Reference

### DeformationManager

#### Methods

```gdscript
# Add deformation at world position
add_deformation(world_pos: Vector3, material_type: int, strength: float)

# Region management
load_deformation_region(region_coord: Vector2i)
unload_deformation_region(region_coord: Vector2i)
get_region_texture(region_coord: Vector2i) -> ImageTexture

# Settings
set_deformation_enabled(enabled: bool)
set_recovery_enabled(enabled: bool)
set_recovery_rate(rate: float)

# Utilities
world_to_region_coord(world_pos: Vector3) -> Vector2i
world_to_region_uv(world_pos: Vector3, region_coord: Vector2i) -> Vector2
cleanup_distant_regions(camera_position: Vector3)
```

#### Constants

```gdscript
MaterialType.SNOW = 0
MaterialType.MUD = 1
MaterialType.ASH = 2
MaterialType.SAND = 3

REGION_SIZE_METERS = 469.0
DEFORMATION_TEXTURE_SIZE = 1024
MAX_ACTIVE_REGIONS = 9
```

## Credits

Designed and implemented based on the RTT Deformation System Design document.
