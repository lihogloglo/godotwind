# RTT Deformation: Player-Following Camera & Material Types

## Overview

This guide covers the newly added player-following camera system and ROCK material type for the RTT deformation system.

---

## Player-Following Camera Mode

### What is it?

Instead of using static cameras for each terrain region (469m x 469m), the system can now use a **single camera that follows the player**, providing higher detail deformation in a smaller area around the player.

### Comparison

| Feature | Region-Based (Default) | Player-Following (New) |
|---------|------------------------|------------------------|
| Camera Movement | Static per region | Follows player XZ position |
| Viewport Size | 469m x 469m | Configurable (default 80m) |
| Detail Level | Low (2.18 texels/meter) | High (12.8 texels/meter @ 40m radius) |
| Memory Usage | 36MB for 9 regions | 4MB for single viewport |
| Use Case | Open world persistence | Close-up character deformation |

---

## Enabling Player-Following Mode

### Step 1: Configure in Project Settings

Add to `project.godot`:

```ini
[deformation]
enabled=true
enable_terrain_integration=true

# Player-following settings
camera/follow_player=true
camera/follow_radius=40.0  # Radius in meters (diameter = 80m)
```

**OR** set programmatically:

```gdscript
# In your game initialization script
func _ready():
    DeformationConfig.camera_follow_player = true
    DeformationConfig.camera_follow_radius = 40.0
```

### Step 2: Set Player Reference

In your player script or game manager:

```gdscript
extends CharacterBody3D

func _ready():
    # Tell the deformation system to follow this node
    DeformationManager.set_player(self)
```

### Step 3: Add Deformation on Movement

```gdscript
extends CharacterBody3D

@export var deformation_strength: float = 0.3
@export var ground_material: DeformationManager.MaterialType = DeformationManager.MaterialType.SNOW

func _physics_process(delta):
    # Your movement code
    move_and_slide()

    # Add deformation when moving
    if velocity.length() > 0.1:
        DeformationManager.add_deformation(
            global_position,
            ground_material,
            deformation_strength * delta
        )
```

---

## Camera Follow Radius Guidelines

| Radius | Detail Level | Use Case |
|--------|-------------|----------|
| 20m | Very High | Indoor scenes, close combat |
| 40m | High (recommended) | Third-person games, hiking simulator |
| 60m | Medium | Open world with focused area |
| 80m | Lower | Large creatures, vehicle tracks |

**Formula**: Detail = `1024 pixels / (radius * 2)` texels/meter

---

## Material Types

### Available Materials

```gdscript
enum MaterialType {
    SNOW = 0,  # Deep footprints, slow recovery
    MUD = 1,   # Sticky footprints, very slow recovery
    ASH = 2,   # Medium depth, normal recovery
    SAND = 3,  # Shallow footprints, fast recovery
    ROCK = 4   # NO DEFORMATION (new!)
}
```

### Material Behavior Table

| Material | Max Depth | Accumulation | Recovery Rate | Use Case |
|----------|-----------|--------------|---------------|----------|
| **SNOW** | 100% | Additive | 0.5x (slow) | Fresh snow, powder |
| **MUD** | 70% | Replace | 0.2x (very slow) | Wet mud, clay |
| **ASH** | 80% | 50% additive | 1.0x (normal) | Volcanic ash, dust |
| **SAND** | 50% | Replace | 2.0x (fast) | Beach sand, desert |
| **ROCK** | 0% | None | 0x (never) | Stone paths, bedrock, roads |

---

## ROCK Material Type Usage

### When to Use ROCK

- Stone paths and cobblestone roads
- Rocky terrain and cliffs
- Indoor floors (wood, tile, concrete)
- Any hard surface that shouldn't deform

### Example: Detect Ground Material

```gdscript
func get_ground_material_at(position: Vector3) -> int:
    # Raycast to detect ground
    var space_state = get_world_3d().direct_space_state
    var query = PhysicsRayQueryParameters3D.create(
        position + Vector3.UP,
        position + Vector3.DOWN * 2.0
    )
    var result = space_state.intersect_ray(query)

    if result:
        var collider = result.collider
        # Check ground type (example using metadata)
        if collider.has_meta("ground_type"):
            match collider.get_meta("ground_type"):
                "snow":
                    return DeformationManager.MaterialType.SNOW
                "mud":
                    return DeformationManager.MaterialType.MUD
                "rock":
                    return DeformationManager.MaterialType.ROCK
                "sand":
                    return DeformationManager.MaterialType.SAND

    # Default to snow
    return DeformationManager.MaterialType.SNOW

func _physics_process(delta):
    if velocity.length() > 0.1:
        var ground_mat = get_ground_material_at(global_position)
        DeformationManager.add_deformation(
            global_position,
            ground_mat,
            0.3 * delta
        )
```

### Example: Terrain3D Texture-Based Detection

```gdscript
# Map Terrain3D texture IDs to material types
const TEXTURE_TO_MATERIAL = {
    0: DeformationManager.MaterialType.SNOW,    # Texture 0 = Snow
    1: DeformationManager.MaterialType.MUD,     # Texture 1 = Mud
    2: DeformationManager.MaterialType.ROCK,    # Texture 2 = Rock
    3: DeformationManager.MaterialType.SAND,    # Texture 3 = Sand
    4: DeformationManager.MaterialType.ROCK,    # Texture 4 = Stone path
}

func get_terrain_material(world_pos: Vector3) -> int:
    # TODO: Sample Terrain3D control map to get texture ID at world_pos
    # For now, return default
    var texture_id = _sample_terrain_texture_id(world_pos)
    return TEXTURE_TO_MATERIAL.get(texture_id, DeformationManager.MaterialType.SNOW)
```

---

## Advanced: Switching Modes at Runtime

```gdscript
# Switch from region-based to player-following
func enable_player_following(player: Node3D):
    DeformationConfig.camera_follow_player = true
    DeformationConfig.camera_follow_radius = 40.0
    DeformationManager.set_player(player)

    # Note: You may need to reload the renderer for changes to take effect
    # This is best done during scene transitions

# Switch back to region-based
func disable_player_following():
    DeformationConfig.camera_follow_player = false
    # Renderer will use static region cameras on next initialization
```

---

## Performance Considerations

### Player-Following Mode

**Advantages:**
- Lower memory usage (1 viewport vs 9)
- Higher detail in player area
- Simpler setup

**Disadvantages:**
- Deformation only exists near player
- No world-wide persistence (unless combined with save system)
- Camera updates every frame

### Region-Based Mode

**Advantages:**
- World-wide persistent deformation
- Works with terrain streaming
- No camera updates needed

**Disadvantages:**
- Higher memory usage
- Lower detail per texel
- More complex system

---

## Debugging

### Visualize Camera Coverage

```gdscript
func _process(_delta):
    if DeformationConfig.camera_follow_player:
        var radius = DeformationConfig.camera_follow_radius
        # Draw debug circle around player
        DebugDraw.draw_circle(
            global_position,
            radius,
            Color.CYAN
        )
```

### Check Material Types

```gdscript
# In deformation_test.gd or debug script
func _input(event):
    if event.is_action_pressed("ui_page_up"):
        # Cycle through material types
        test_material = (test_material + 1) % 5
        print("Material: ", test_material, " = ", _get_material_name(test_material))

func _get_material_name(mat: int) -> String:
    match mat:
        0: return "SNOW"
        1: return "MUD"
        2: return "ASH"
        3: return "SAND"
        4: return "ROCK"
        _: return "UNKNOWN"
```

---

## Complete Example

```gdscript
extends CharacterBody3D

const SPEED = 5.0
const DEFORM_STRENGTH = 0.3

func _ready():
    # Enable player-following mode
    DeformationConfig.camera_follow_player = true
    DeformationConfig.camera_follow_radius = 40.0
    DeformationManager.set_player(self)

func _physics_process(delta):
    # Movement
    var input_dir = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
    var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

    if direction:
        velocity.x = direction.x * SPEED
        velocity.z = direction.z * SPEED
    else:
        velocity.x = move_toward(velocity.x, 0, SPEED)
        velocity.z = move_toward(velocity.z, 0, SPEED)

    move_and_slide()

    # Add deformation when moving
    if velocity.length() > 0.1:
        var ground_material = _detect_ground_material()
        DeformationManager.add_deformation(
            global_position,
            ground_material,
            DEFORM_STRENGTH * delta
        )

func _detect_ground_material() -> int:
    # Simple example: detect based on Y position
    if global_position.y > 10.0:
        return DeformationManager.MaterialType.SNOW
    elif global_position.y > 0.0:
        return DeformationManager.MaterialType.MUD
    else:
        return DeformationManager.MaterialType.ROCK
```

---

## Next Steps

1. **Update Terrain3D** to version 1.1+ for tessellation support (see TERRAIN3D_UPDATE.md)
2. **Enable displacement** in Terrain3D material settings
3. **Implement terrain texture sampling** for automatic material detection
4. **Test with different radius values** to find optimal detail level

---

## API Reference

### DeformationManager

```gdscript
# Set player node to follow (player-following mode only)
DeformationManager.set_player(player: Node3D) -> void

# Add deformation at world position
DeformationManager.add_deformation(
    world_pos: Vector3,
    material_type: int,  # MaterialType enum
    strength: float      # 0.0 to 1.0
) -> void
```

### DeformationConfig

```gdscript
# Player-following settings
static var camera_follow_player: bool = false
static var camera_follow_radius: float = 40.0  # Meters

# Access via project settings
DeformationConfig.load_from_project_settings()
```

---

## Troubleshooting

**Q: Camera doesn't follow player**
- A: Make sure you called `DeformationManager.set_player(self)` in player's `_ready()`
- A: Check that `camera_follow_player = true` in config

**Q: Deformation not visible**
- A: Ensure `deformation/enabled = true` in project settings
- A: Check that Terrain3D integration is enabled
- A: Verify player is within camera follow radius

**Q: ROCK still deforms**
- A: Make sure you're using `MaterialType.ROCK` (value 4), not 3 (SAND)
- A: Check shader uniform is set correctly (should be 1.0)

**Q: Low detail deformation**
- A: Decrease `camera_follow_radius` for higher texel density
- A: Wait for Terrain3D 1.1+ update for tessellation support
