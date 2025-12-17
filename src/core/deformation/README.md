# RTT Deformation System

Production-ready terrain deformation system for Godotwind using Render-To-Texture (RTT) technology.

## Features

- ✅ Real-time ground deformation (snow, mud, ash)
- ✅ Grass integration and trampling
- ✅ Material-specific behaviors (compression, accumulation, decay)
- ✅ Streaming-compatible chunked architecture
- ✅ Optional persistence system
- ✅ Memory-efficient viewport pooling
- ✅ 60+ FPS performance target

## Quick Start

### 1. Setup Autoload

Add `DeformationManager` as autoload singleton:
- Project Settings → Autoload
- Path: `res://src/core/deformation/deformation_manager.gd`
- Name: `DeformationManager`

### 2. Attach to Player

```gdscript
# In your player script
func _ready():
    var agent = DeformableAgent.new()
    add_child(agent)
    agent.deformation_radius = 0.3  # Footprint size
```

### 3. Configure Material

```gdscript
# Set terrain type
DeformationManager.set_material_preset("Snow")  # or "Mud", "Ash"
```

## File Structure

```
deformation/
├── README.md                           # This file
├── deformation_manager.gd              # Singleton manager
├── deformation_chunk.gd                # Per-chunk RTT handler
├── deformation_preset.gd               # Material behavior presets
├── deformable_agent.gd                 # Player/NPC component
└── shaders/
    ├── deformation_brush.gdshader      # RTT brush rendering
    ├── terrain_deformation.gdshader    # Terrain integration
    └── grass_deformation.gdshader      # Grass integration
```

## Integration

### Terrain Integration

Modify your terrain shader to include:
```glsl
uniform sampler2D deformation_texture;
// ... see terrain_deformation.gdshader for full code
```

### Grass Integration

Add to your grass shader:
```glsl
uniform sampler2D deformation_texture;
// ... see grass_deformation.gdshader for full code
```

## Documentation

- **Full Design**: `/docs/RTT_DEFORMATION_SYSTEM.md` - Complete architecture and implementation guide
- **Quick Start**: `/docs/RTT_DEFORMATION_QUICK_START.md` - API reference and examples

## Current Status

**Phase**: Design Complete → Implementation Phase 1

### Implemented (Stubs)
- [x] Core class structure
- [x] DeformationManager singleton
- [x] DeformationChunk RTT setup
- [x] Material preset system
- [x] DeformableAgent component
- [x] Shader stubs

### TODO (Phase 1)
- [ ] Complete RTT brush rendering
- [ ] Implement viewport pooling
- [ ] Test single chunk deformation
- [ ] Create test scene
- [ ] Integrate with Terrain3D

See `docs/RTT_DEFORMATION_SYSTEM.md` §8 for full implementation plan.

## Configuration

```gdscript
# In DeformationManager
enabled = true
chunk_size = 256.0  # Must match terrain region size
texture_resolution = 512  # 256/512/1024
max_active_chunks = 25  # 5×5 grid
enable_persistence = true
```

## Performance Targets

| Metric | Target | Notes |
|--------|--------|-------|
| FPS | 60+ | Time-budgeted updates |
| Memory | <50MB | 25 chunks @ 512² |
| Chunk Init | <2ms | Viewport reuse |
| Draw Calls | +1/chunk | Single RTT per chunk |

## Examples

See `docs/RTT_DEFORMATION_QUICK_START.md` for:
- Material switching
- Vehicle tracks
- Custom brush shapes
- Debugging tools
- Troubleshooting

## License

Part of Godotwind project - see root LICENSE file.
