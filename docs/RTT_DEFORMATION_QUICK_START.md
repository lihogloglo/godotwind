# RTT Deformation System - Quick Start Guide

## Overview

This guide provides a quick reference for implementing the RTT deformation system designed for Godotwind. For full architectural details, see [RTT_DEFORMATION_SYSTEM_DESIGN.md](RTT_DEFORMATION_SYSTEM_DESIGN.md).

---

## Key Concepts

### Virtual Texture Regions
- Each Terrain3D region gets its own 1024x1024 deformation texture
- Only 9 regions active at once (3x3 grid around player) = ~36MB memory
- Regions stream in/out with terrain

### Deformation Texture Format
- **RG16F** (2 channels, 16-bit float)
  - R: Deformation depth (0.0 = none, 1.0 = max)
  - G: Material type (0.0-0.25 = snow, 0.25-0.5 = mud, etc.)

### Rendering Pipeline
1. Player moves → `DeformationManager.add_deformation()`
2. Stamp rendered to SubViewport RTT
3. Compositor blends with previous state
4. Terrain shader samples deformation texture
5. Grass shader samples same texture

---

## Quick Integration Checklist

### 1. Create Core Files

```
src/core/deformation/
├── deformation_manager.gd              # Singleton (autoload)
├── deformation_renderer.gd             # Handles RTT
├── deformation_streamer.gd             # Region streaming
└── shaders/
    ├── deformation_stamp.gdshader      # Stamp shader
    └── deformation_recovery.gdshader   # Recovery shader
```

### 2. Register Autoload

In `project.godot`:
```ini
[autoload]
DeformationManager="*res://src/core/deformation/deformation_manager.gd"
```

### 3. Hook into Terrain Streaming

```gdscript
# In world_streaming_manager.gd or world_explorer.gd
func _ready():
	var terrain_streamer = $GenericTerrainStreamer
	terrain_streamer.terrain_region_loaded.connect(_on_terrain_loaded)
	terrain_streamer.terrain_region_unloaded.connect(_on_terrain_unloaded)

func _on_terrain_loaded(region_coord: Vector2i):
	DeformationManager.load_deformation_region(region_coord)

func _on_terrain_unloaded(region_coord: Vector2i):
	DeformationManager.unload_deformation_region(region_coord)
```

### 4. Modify Terrain3D Shader

Option A: Fork `lightweight.gdshader` and add deformation sampling
Option B: Create new material variant with injected code

Add to fragment():
```glsl
uniform sampler2DArray deformation_textures;
uniform bool deformation_enabled = false;

if (deformation_enabled) {
	vec2 region_uv = fract(VERTEX.xz / REGION_SIZE);
	vec4 deformation = texture(deformation_textures, vec3(region_uv, region_index));
	float depth = deformation.r;

	// Displace vertex
	VERTEX -= v_normal * depth * 0.1;  // 10cm max depth
}
```

### 5. Add Player Deformation

```gdscript
# In player_controller.gd
func _physics_process(delta):
	move_and_slide()

	if velocity.length() > 0.1:
		DeformationManager.add_deformation(
			global_position,
			DeformationManager.MATERIAL_SNOW,
			0.3  # Strength
		)
```

---

## Minimal Implementation (Proof of Concept)

For a quick proof of concept, implement only:

1. **DeformationManager** - Basic singleton with stub functions
2. **DeformationRenderer** - Single SubViewport with orthographic camera
3. **deformation_stamp.gdshader** - Simple radial falloff stamp
4. **Terrain shader modification** - Sample single texture (no streaming)
5. **Player hook** - Call add_deformation on movement

**Time estimate:** 1-2 days for working prototype on single terrain region.

---

## API Reference

### DeformationManager (Singleton)

```gdscript
# Add deformation at world position
DeformationManager.add_deformation(
	world_pos: Vector3,
	material_type: int,
	strength: float
)

# Material types
DeformationManager.MATERIAL_SNOW = 0
DeformationManager.MATERIAL_MUD = 1
DeformationManager.MATERIAL_ASH = 2
DeformationManager.MATERIAL_SAND = 3

# Enable/disable recovery
DeformationManager.set_recovery_enabled(enabled: bool)
DeformationManager.set_recovery_rate(rate: float)  # Units per second

# Region management (called by WorldStreamingManager)
DeformationManager.load_deformation_region(region_coord: Vector2i)
DeformationManager.unload_deformation_region(region_coord: Vector2i)

# Get texture for shader binding
var tex = DeformationManager.get_region_texture(region_coord: Vector2i)
```

---

## Performance Tuning

### Memory
- **36MB** for 9 active regions (RG16F 1024x1024)
- Reduce resolution to 512x512 for distant regions → 9MB savings

### Update Budget
- Default: 2ms/frame for deformation updates
- Adjust `DEFORMATION_UPDATE_BUDGET_MS` in DeformationManager

### Stamp Batching
- Group nearby stamps into single render pass
- Enable with `DeformationRenderer.batch_mode = true`

### LOD
- Close regions: 1024x1024
- Medium (100-200m): 512x512
- Far (200m+): 256x256

---

## Testing

### Verify Basic Deformation
1. Run world_explorer scene
2. Move player character
3. Check console for "Deformation applied at [position]"
4. Observe terrain depression at player position

### Verify Streaming
1. Move player across region boundaries
2. Check console for region load/unload messages
3. Verify deformation persists when returning to previous region

### Verify Recovery
1. Enable recovery: `DeformationManager.set_recovery_enabled(true)`
2. Create deformation, then wait
3. Observe deformation gradually fading over time

---

## Common Issues

### Issue: Deformation not visible
**Solution:** Check shader uniform binding. Ensure `deformation_enabled = true`.

### Issue: Performance drops
**Solution:** Reduce `max_loads_per_frame` or use lower resolution textures.

### Issue: Deformation disappears at region boundaries
**Solution:** Implement 1-texel overlap in regions and blend in shader.

### Issue: Stamp appears offset
**Solution:** Verify world-to-UV coordinate conversion matches Terrain3D's coordinate system.

---

## Next Steps

After basic system works:
1. Add grass deformation (requires implementing grass system first)
2. Implement persistence (save/load deformation textures)
3. Add accumulation tracking
4. Material-specific behaviors (snow vs mud vs ash)
5. Optimize with LOD and batching

---

## Example: Complete Minimal deformation_manager.gd

```gdscript
# src/core/deformation/deformation_manager.gd
extends Node

# Material types
const MATERIAL_SNOW = 0
const MATERIAL_MUD = 1
const MATERIAL_ASH = 2
const MATERIAL_SAND = 3

var _renderer: Node  # DeformationRenderer instance
var _active_regions: Dictionary = {}  # Vector2i -> texture

func _ready():
	_renderer = preload("res://src/core/deformation/deformation_renderer.gd").new()
	add_child(_renderer)

func add_deformation(world_pos: Vector3, material_type: int, strength: float):
	var region_coord = _world_to_region(world_pos)

	if not _active_regions.has(region_coord):
		print("Deformation region not loaded: ", region_coord)
		return

	# Convert to region-local UV
	var region_uv = _world_to_region_uv(world_pos, region_coord)

	# Render stamp
	_renderer.render_stamp(
		_active_regions[region_coord],
		region_uv,
		material_type,
		strength
	)

func load_deformation_region(region_coord: Vector2i):
	# Create or load texture
	var texture = ImageTexture.create_from_image(
		Image.create(1024, 1024, false, Image.FORMAT_RGF)
	)
	_active_regions[region_coord] = texture
	print("Loaded deformation region: ", region_coord)

func unload_deformation_region(region_coord: Vector2i):
	# TODO: Save texture to disk
	_active_regions.erase(region_coord)
	print("Unloaded deformation region: ", region_coord)

func get_region_texture(region_coord: Vector2i) -> Texture2D:
	return _active_regions.get(region_coord, null)

func _world_to_region(world_pos: Vector3) -> Vector2i:
	const REGION_SIZE = 469.0  # From Terrain3D
	return Vector2i(
		floori(world_pos.x / REGION_SIZE),
		floori(world_pos.z / REGION_SIZE)
	)

func _world_to_region_uv(world_pos: Vector3, region_coord: Vector2i) -> Vector2:
	const REGION_SIZE = 469.0
	var region_origin = Vector2(region_coord) * REGION_SIZE
	var local_pos = Vector2(world_pos.x, world_pos.z) - region_origin
	return local_pos / REGION_SIZE
```

---

## Resources

- Full design doc: [RTT_DEFORMATION_SYSTEM_DESIGN.md](RTT_DEFORMATION_SYSTEM_DESIGN.md)
- Terrain streaming: [STREAMING.md](STREAMING.md)
- Godot SubViewport: https://docs.godotengine.org/en/stable/classes/class_subviewport.html
- Terrain3D docs: https://github.com/TokisanGames/Terrain3D

---

**Questions?** See the full design document or check existing implementations in:
- Water system: `src/core/water/` (similar RTT approach for FFT waves)
- Terrain streaming: `src/core/world/generic_terrain_streamer.gd`
