# RTT Deformation System - Production Design

## Executive Summary

This document describes a production-ready **Render-To-Texture (RTT) based deformation system** for open-world terrain in Godotwind. The system enables real-time, dynamic surface deformation for snow, mud, ash, and other materials, with grass integration and optional persistence.

**Key Features:**
- Real-time footprint/vehicle track deformation
- Multiple material types (snow, mud, ash) with unique behaviors
- Grass deformation integration via shader sampling
- Optional accumulation and persistence
- Streaming-compatible chunked architecture
- 60+ FPS performance target for open-world games
- Memory-efficient texture pooling

---

## 1. Architecture Overview

### 1.1 High-Level Design

```
                    ┌─────────────────────────────┐
                    │   DeformationManager        │
                    │  (Singleton/Autoload)       │
                    │  - Material presets         │
                    │  - Chunk tracking           │
                    │  - Texture pool management  │
                    └──────────┬──────────────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
              ▼                ▼                ▼
    ┌─────────────────┐ ┌─────────────┐ ┌──────────────┐
    │ DeformationChunk│ │ Deformable  │ │ Deformation  │
    │  - RTT texture  │ │  Agents     │ │  Painter     │
    │  - Viewport     │ │  (Player,   │ │  (GPU brush) │
    │  - Brush render │ │   NPCs,     │ │              │
    │  - Persistence  │ │   Vehicles) │ │              │
    └────────┬────────┘ └──────┬──────┘ └──────┬───────┘
             │                 │                │
             ▼                 ▼                ▼
    ┌────────────────────────────────────────────────┐
    │         Terrain Shader Integration             │
    │  - Sample deformation texture                  │
    │  - Vertex displacement                         │
    │  - Normal perturbation                         │
    └────────────────────────────────────────────────┘
             │                                 │
             ▼                                 ▼
    ┌─────────────────┐              ┌────────────────┐
    │   Terrain3D     │              │  GrassManager  │
    │  (Heightmap)    │              │  (Shader)      │
    └─────────────────┘              └────────────────┘
```

### 1.2 Integration with Existing Systems

**Streaming System Integration:**
- Chunks align with terrain streaming regions (256m × 256m)
- Deformation chunks load/unload with `GenericTerrainStreamer`
- Time-budgeted chunk initialization (2ms/frame budget)
- Async texture persistence save/load

**Terrain3D Integration:**
- Deformation applied as vertex shader displacement
- Does NOT modify base heightmap (non-destructive)
- Blends with terrain normals for lighting
- Uses world-space coordinates for consistent placement

**Grass Integration:**
- Grass shader samples deformation texture
- Vertex displacement matches terrain deformation
- Optional grass flattening in deep deformations
- Wind animation preserved

---

## 2. Core Components

### 2.1 DeformationManager (Singleton)

**Responsibilities:**
- Create/destroy deformation chunks as camera moves
- Pool and reuse SubViewport resources
- Track active deformations
- Manage material presets (snow, mud, ash)
- Handle persistence (save/load to disk)

**Key Properties:**
```gdscript
class_name DeformationManager
extends Node

# Configuration
@export var enabled: bool = true
@export var chunk_size: float = 256.0  # Matches Terrain3D region size
@export var texture_resolution: int = 512  # Per chunk (adjustable for quality/memory)
@export var max_active_chunks: int = 25  # 5×5 chunks around camera
@export var deformation_depth_max: float = 0.3  # Max depth in meters

# Material Presets
@export var snow_preset: DeformationPreset
@export var mud_preset: DeformationPreset
@export var ash_preset: DeformationPreset

# Performance
@export var chunk_init_budget_ms: float = 2.0  # Max ms/frame for chunk creation
@export var enable_persistence: bool = true
@export var persistence_save_interval: float = 10.0  # Seconds

# Internal State
var active_chunks: Dictionary = {}  # Vector2i -> DeformationChunk
var viewport_pool: Array[SubViewport] = []  # Reusable viewports
var camera: Camera3D
var current_material: DeformationPreset
```

**Key Methods:**
```gdscript
func update_chunks(camera_position: Vector3) -> void
func get_chunk(world_pos: Vector3) -> DeformationChunk
func create_chunk(chunk_coord: Vector2i) -> DeformationChunk
func unload_chunk(chunk_coord: Vector2i) -> void
func apply_deformation(world_pos: Vector3, brush_settings: Dictionary) -> void
func save_persistence_data() -> void
func load_persistence_data() -> void
```

---

### 2.2 DeformationChunk

**Responsibilities:**
- Manage RTT for a single terrain chunk
- Render deformation brushes to texture
- Handle accumulation and decay
- Provide texture sampling for terrain/grass

**Structure:**
```gdscript
class_name DeformationChunk
extends Node3D

# RTT Setup
var viewport: SubViewport
var deformation_texture: ViewportTexture  # R: depth, G: accumulation, B: wetness, A: age
var brush_renderer: MeshInstance3D  # Quad that renders brush stamps
var camera: Camera2D  # Orthographic for top-down rendering

# Chunk Properties
var chunk_coord: Vector2i  # Chunk grid coordinates
var world_offset: Vector3  # World position of chunk center
var size: float = 256.0
var resolution: int = 512
var is_dirty: bool = false  # Needs render update

# Material/Surface Type
var material_preset: DeformationPreset

# Persistence
var persistence_data: Image  # Saved/loaded deformation state
```

**Key Methods:**
```gdscript
func initialize(coord: Vector2i, preset: DeformationPreset, pooled_viewport: SubViewport) -> void
func render_brush(world_pos: Vector3, brush_radius: float, pressure: float) -> void
func update_decay(delta: float) -> void
func get_deformation_at(world_pos: Vector3) -> float
func save_to_image() -> Image
func load_from_image(img: Image) -> void
```

**RTT Texture Format:**
- **R channel**: Deformation depth (0.0 = no deformation, 1.0 = max depth)
- **G channel**: Accumulation factor (for permanent deformation)
- **B channel**: Wetness/freshness (for visual effects like wet mud)
- **A channel**: Age (for decay over time)

---

### 2.3 DeformationPreset (Resource)

Material behavior presets for different surface types.

```gdscript
class_name DeformationPreset
extends Resource

# Material Properties
@export var material_name: String = "Snow"
@export var max_depth: float = 0.3  # Maximum deformation depth in meters
@export var compression_factor: float = 0.7  # How much material compresses (1.0 = full, 0.0 = none)

# Accumulation
@export var enable_accumulation: bool = true  # Permanent deformation
@export var accumulation_rate: float = 0.5  # How fast deformation becomes permanent (0-1)
@export var accumulation_threshold: float = 0.3  # Minimum depth to accumulate

# Decay (for temporary deformations)
@export var enable_decay: bool = false  # If true, deformations fade over time
@export var decay_rate: float = 0.1  # Units per second
@export var decay_delay: float = 5.0  # Seconds before decay starts

# Visual
@export var normal_strength: float = 0.8  # How much deformation affects normals
@export var edge_sharpness: float = 0.6  # Sharpness of deformation edges
@export var color_tint: Color = Color.WHITE  # Tint for deformed areas (e.g., darker mud)

# Behavior
@export var max_slope_angle: float = 45.0  # Degrees - no deformation on steep slopes
@export var displacement_curve: Curve  # Non-linear depth mapping

# Examples:
# Snow: high accumulation, slow decay, soft edges
# Mud: medium accumulation, no decay, sharp edges
# Ash: high accumulation, medium decay, very soft edges
```

---

### 2.4 DeformableAgent

Component attached to entities that create deformations (player, NPCs, vehicles).

```gdscript
class_name DeformableAgent
extends Node3D

# Configuration
@export var deformation_radius: float = 0.3  # Footprint/tire size
@export var deformation_strength: float = 1.0  # Pressure multiplier
@export var deformation_frequency: float = 10.0  # Hz - how often to stamp
@export var min_velocity: float = 0.1  # Minimum movement speed to deform

# State
var last_deformation_time: float = 0.0
var last_deformation_pos: Vector3

func _physics_process(delta: float) -> void:
	if not DeformationManager.enabled:
		return

	var current_time = Time.get_ticks_msec() / 1000.0
	var velocity = (global_position - last_deformation_pos) / delta

	# Check if we should deform
	if velocity.length() < min_velocity:
		return

	if current_time - last_deformation_time < 1.0 / deformation_frequency:
		return

	# Apply deformation
	DeformationManager.apply_deformation(global_position, {
		"radius": deformation_radius,
		"strength": deformation_strength,
	})

	last_deformation_time = current_time
	last_deformation_pos = global_position
```

---

## 3. Rendering Pipeline

### 3.1 Brush Rendering (GPU-Based)

Deformations are rendered using GPU painting to RTT:

1. **Brush Quad Setup:**
   - Each chunk has an orthographic camera looking down
   - Camera covers chunk area (256m × 256m)
   - Viewport renders to 512×512 texture (adjustable)

2. **Brush Shader:**
   ```glsl
   shader_type spatial;
   render_mode unshaded, cull_disabled, depth_test_disabled;

   uniform float brush_radius = 1.0;
   uniform float brush_strength = 1.0;
   uniform vec2 brush_center;  // World XZ coordinates
   uniform sampler2D current_deformation;  // Previous frame
   uniform bool accumulate = false;
   uniform float accumulation_rate = 0.5;

   void fragment() {
       vec2 world_uv = UV;  // Already in chunk-local space
       float dist = length(world_uv - brush_center);

       // Radial falloff
       float falloff = 1.0 - smoothstep(0.0, brush_radius, dist);
       float depth = falloff * brush_strength;

       // Sample existing deformation
       vec4 existing = texture(current_deformation, UV);

       // Blend with existing (max blend for additive deformation)
       float new_depth = max(existing.r, depth);

       // Accumulation
       float accumulation = existing.g;
       if (accumulate && new_depth > 0.3) {
           accumulation = mix(existing.g, new_depth, accumulation_rate);
       }

       // Output: R=depth, G=accumulation, B=wetness, A=age
       ALBEDO = vec3(new_depth, accumulation, 1.0);
       ALPHA = 0.0;  // Reset age on new deformation
   }
   ```

3. **Multi-Pass Rendering:**
   - **Pass 1**: Render new brush stamp
   - **Pass 2**: Copy to persistent texture (with accumulation)
   - **Pass 3**: Apply decay (if enabled)

---

### 3.2 Terrain Shader Integration

Modify Terrain3D shader to sample and apply deformation:

```glsl
// In Terrain3D custom shader (or shader overlay)
uniform sampler2D deformation_texture_chunk;  // Current chunk RTT
uniform vec3 chunk_world_offset;  // For coordinate mapping
uniform float chunk_size = 256.0;
uniform float deformation_scale = 0.3;  // Max displacement depth

void vertex() {
    // Calculate chunk-local UV
    vec3 world_pos = VERTEX + chunk_world_offset;
    vec2 chunk_uv = (world_pos.xz - chunk_world_offset.xz) / chunk_size;

    // Sample deformation
    vec4 deform = texture(deformation_texture_chunk, chunk_uv);
    float depth = deform.r;  // 0-1 range

    // Apply vertical displacement
    VERTEX.y -= depth * deformation_scale;

    // Perturb normal (approximate derivative for better lighting)
    vec2 texel_size = 1.0 / vec2(textureSize(deformation_texture_chunk, 0));
    float depth_x = texture(deformation_texture_chunk, chunk_uv + vec2(texel_size.x, 0.0)).r;
    float depth_z = texture(deformation_texture_chunk, chunk_uv + vec2(0.0, texel_size.y)).r;

    vec3 normal_offset = normalize(vec3(
        (depth - depth_x) * deformation_scale,
        1.0,
        (depth - depth_z) * deformation_scale
    ));

    NORMAL = mix(NORMAL, normal_offset, 0.5);  // Blend with terrain normal
}

void fragment() {
    // Sample deformation for visual effects
    vec4 deform = texture(deformation_texture_chunk, UV);

    // Darken deformed areas (compressed soil/snow)
    float darkening = deform.r * 0.2;
    ALBEDO = ALBEDO * (1.0 - darkening);

    // Optional: wetness effect for mud
    float wetness = deform.b;
    ROUGHNESS = mix(ROUGHNESS, 0.3, wetness);
    SPECULAR = mix(SPECULAR, 0.5, wetness);
}
```

---

### 3.3 Grass Shader Integration

Extend existing grass shader to sample deformation:

```glsl
// Add to grass.gdshader vertex shader
uniform sampler2D deformation_texture : hint_default_white;
uniform vec3 deformation_chunk_offset;
uniform float deformation_chunk_size = 256.0;
uniform float grass_deformation_scale = 0.3;

void vertex() {
    // Existing grass wind animation code...

    // Sample deformation at grass blade position
    vec3 world_pos = MODEL_MATRIX[3].xyz;
    vec2 deform_uv = (world_pos.xz - deformation_chunk_offset.xz) / deformation_chunk_size;

    vec4 deform = texture(deformation_texture, deform_uv);
    float depth = deform.r;

    // Displace grass blade down with terrain
    VERTEX.y -= depth * grass_deformation_scale;

    // Flatten grass in deep deformations (optional)
    float flatten_factor = smoothstep(0.3, 0.6, depth);
    VERTEX.xz *= mix(1.0, 0.3, flatten_factor);  // Collapse horizontally

    // Reduce height in deformed areas
    float height_reduction = depth * 0.5;
    VERTEX.y *= (1.0 - height_reduction);
}
```

---

## 4. Performance Optimization

### 4.1 Memory Management

**Texture Pooling:**
- Reuse SubViewports when chunks unload
- Pool size: `max_active_chunks + 5` (buffer for transitions)
- Viewport recycling prevents allocation hitches

**Texture Resolution Scaling:**
- **High Quality**: 1024×1024 per chunk (4MB RGBA16F)
- **Medium Quality**: 512×512 per chunk (1MB RGBA16F)
- **Low Quality**: 256×256 per chunk (256KB RGBA16F)
- **Total Memory** (25 chunks, medium): ~25MB

**LOD System:**
- Distant chunks (>200m): 256×256 resolution
- Medium chunks (100-200m): 512×512 resolution
- Close chunks (<100m): 1024×1024 resolution
- Dynamic resolution switching on chunk reuse

### 4.2 Update Budgeting

**Per-Frame Limits:**
```gdscript
# In DeformationManager._process()
var budget_start = Time.get_ticks_usec()
var budget_us = chunk_init_budget_ms * 1000.0

# Chunk creation (time-budgeted)
while chunk_creation_queue.size() > 0:
    if (Time.get_ticks_usec() - budget_start) > budget_us:
        break  # Defer to next frame

    var chunk = create_chunk(chunk_creation_queue.pop_front())

# Brush rendering (batched)
for chunk in dirty_chunks:
    chunk.render_pending_brushes()  # GPU work, minimal CPU time
```

**Dirty Flag System:**
- Chunks only re-render when new deformations occur
- Decay updates batched (1 chunk per frame max)
- Persistence saves background-threaded

### 4.3 Streaming Integration

**Chunk Lifecycle:**
```gdscript
# In WorldStreamingManager
func _on_terrain_region_loaded(region_coord: Vector2i) -> void:
    # Load corresponding deformation chunk
    var chunk_coord = region_coord  # 1:1 mapping
    DeformationManager.request_chunk_load(chunk_coord)

func _on_terrain_region_unloaded(region_coord: Vector2i) -> void:
    # Save and unload deformation chunk
    var chunk_coord = region_coord
    DeformationManager.request_chunk_unload(chunk_coord)
```

**Persistence Loading:**
- Load deformation data async during chunk creation
- If persistence file exists: load and apply to RTT
- If no file: start with clean slate
- Save on chunk unload + periodic auto-save

---

## 5. Material Behaviors

### 5.1 Snow Preset

**Characteristics:**
- High compression (deep footprints)
- Gradual accumulation (semi-permanent)
- Very slow decay (melting over minutes)
- Soft edges (powder consistency)

```gdscript
var snow_preset = DeformationPreset.new()
snow_preset.material_name = "Snow"
snow_preset.max_depth = 0.4
snow_preset.compression_factor = 0.85
snow_preset.enable_accumulation = true
snow_preset.accumulation_rate = 0.6
snow_preset.accumulation_threshold = 0.25
snow_preset.enable_decay = true
snow_preset.decay_rate = 0.02  # Very slow
snow_preset.decay_delay = 30.0  # 30 seconds
snow_preset.edge_sharpness = 0.3
snow_preset.color_tint = Color(0.95, 0.95, 1.0)
```

### 5.2 Mud Preset

**Characteristics:**
- Medium compression
- High accumulation (permanent tracks)
- No decay (sticky)
- Sharp edges

```gdscript
var mud_preset = DeformationPreset.new()
mud_preset.material_name = "Mud"
mud_preset.max_depth = 0.25
mud_preset.compression_factor = 0.6
mud_preset.enable_accumulation = true
mud_preset.accumulation_rate = 0.8
mud_preset.accumulation_threshold = 0.15
mud_preset.enable_decay = false  # Permanent
mud_preset.edge_sharpness = 0.7
mud_preset.color_tint = Color(0.6, 0.5, 0.4)  # Brown tint
```

### 5.3 Ash Preset

**Characteristics:**
- Very high compression (volcanic ash)
- Fast accumulation
- Medium decay (wind dispersal)
- Very soft edges (fine particles)

```gdscript
var ash_preset = DeformationPreset.new()
ash_preset.material_name = "Ash"
ash_preset.max_depth = 0.5
ash_preset.compression_factor = 0.9
ash_preset.enable_accumulation = true
ash_preset.accumulation_rate = 0.7
ash_preset.accumulation_threshold = 0.2
ash_preset.enable_decay = true
ash_preset.decay_rate = 0.05
ash_preset.decay_delay = 15.0
ash_preset.edge_sharpness = 0.2
ash_preset.color_tint = Color(0.7, 0.7, 0.7)
```

---

## 6. Advanced Features

### 6.1 Multi-Material Blending

For biomes with mixed terrain (e.g., snowy mud):

```gdscript
# In DeformationChunk
func blend_materials(primary: DeformationPreset, secondary: DeformationPreset, blend: float) -> void:
    # Create blended preset
    var blended = DeformationPreset.new()
    blended.max_depth = lerp(primary.max_depth, secondary.max_depth, blend)
    blended.compression_factor = lerp(primary.compression_factor, secondary.compression_factor, blend)
    # ... blend other properties

    material_preset = blended
```

### 6.2 Vehicle Tracks

Enhanced deformation for wheeled vehicles:

```gdscript
class_name VehicleDeformable
extends DeformableAgent

@export var tire_spacing: float = 1.8  # Distance between left/right tires
@export var tire_width: float = 0.2

func apply_tire_deformations() -> void:
    # Get vehicle forward direction
    var forward = -global_transform.basis.z
    var right = global_transform.basis.x

    # Apply deformation at each tire position
    var left_tire_pos = global_position - right * (tire_spacing / 2.0)
    var right_tire_pos = global_position + right * (tire_spacing / 2.0)

    DeformationManager.apply_deformation(left_tire_pos, {
        "radius": tire_width,
        "strength": deformation_strength,
        "shape": "ellipse",  # Elongated for tire shape
        "rotation": forward,
    })

    DeformationManager.apply_deformation(right_tire_pos, {
        "radius": tire_width,
        "strength": deformation_strength,
        "shape": "ellipse",
        "rotation": forward,
    })
```

### 6.3 Slope-Based Deformation

Prevent deformation on steep slopes (snow doesn't stick):

```glsl
// In brush shader
uniform float max_slope_angle = 45.0;

void fragment() {
    // Sample terrain normal from terrain system
    vec3 terrain_normal = texture(terrain_normal_map, UV).xyz;

    // Calculate slope
    float slope = acos(dot(terrain_normal, vec3(0.0, 1.0, 0.0)));
    float slope_deg = degrees(slope);

    // Reduce deformation on steep slopes
    float slope_factor = 1.0 - smoothstep(max_slope_angle * 0.8, max_slope_angle, slope_deg);

    float depth = falloff * brush_strength * slope_factor;
    // ...
}
```

### 6.4 Seasonal Variation

Dynamic preset switching based on weather:

```gdscript
# In DeformationManager
func set_season(season: String) -> void:
    match season:
        "winter":
            current_material = snow_preset
        "spring":
            current_material = mud_preset  # Melted snow
        "summer":
            # Disable deformation or use dust preset
            enabled = false
        "fall":
            current_material = mud_preset
```

---

## 7. Persistence System

### 7.1 Save Format

Deformation data saved as compressed PNG images:

```
godotwind_data/
├── deformation_cache/
│   ├── chunk_-1_-1.png  # Chunk coordinates
│   ├── chunk_-1_0.png
│   ├── chunk_0_-1.png
│   ├── chunk_0_0.png
│   └── manifest.json     # Metadata
```

**Manifest Format:**
```json
{
    "version": 1,
    "chunk_size": 256.0,
    "texture_resolution": 512,
    "chunks": {
        "-1,-1": {
            "file": "chunk_-1_-1.png",
            "last_modified": 1678901234,
            "material": "Snow",
            "max_depth": 0.4
        }
    }
}
```

### 7.2 Save/Load Implementation

```gdscript
# In DeformationChunk
func save_to_disk() -> void:
    if not DeformationManager.enable_persistence:
        return

    # Get viewport texture as image
    var img = viewport.get_texture().get_image()

    # Compress and save
    var path = DeformationManager.get_chunk_path(chunk_coord)
    img.save_png(path)

    # Update manifest
    DeformationManager.update_manifest(chunk_coord, {
        "file": path.get_file(),
        "last_modified": Time.get_unix_time_from_system(),
        "material": material_preset.material_name,
        "max_depth": material_preset.max_depth,
    })

func load_from_disk() -> void:
    var path = DeformationManager.get_chunk_path(chunk_coord)
    if not FileAccess.file_exists(path):
        return  # No saved data

    var img = Image.load_from_file(path)
    if not img:
        push_error("Failed to load deformation chunk: " + path)
        return

    # Apply to viewport texture (render full-screen quad with loaded texture)
    _apply_loaded_texture(img)
```

### 7.3 Auto-Save Strategy

```gdscript
# In DeformationManager
var _save_timer: float = 0.0

func _process(delta: float) -> void:
    if not enable_persistence:
        return

    _save_timer += delta
    if _save_timer >= persistence_save_interval:
        _save_dirty_chunks()
        _save_timer = 0.0

func _save_dirty_chunks() -> void:
    # Background thread to avoid hitches
    BackgroundProcessor.submit_task(func():
        for chunk in active_chunks.values():
            if chunk.is_dirty:
                chunk.save_to_disk()
                chunk.is_dirty = false
    , BackgroundProcessor.PRIORITY_LOW)
```

---

## 8. Implementation Plan

### Phase 1: Core System (Week 1-2)
1. **DeformationManager singleton**
   - Chunk tracking and lifecycle
   - Viewport pooling
   - Material preset system

2. **DeformationChunk basic rendering**
   - RTT setup with SubViewport
   - Simple brush shader (radial falloff)
   - Orthographic camera setup

3. **Basic terrain integration**
   - Shader modification for vertex displacement
   - Coordinate mapping (world to chunk UV)
   - Single-chunk testing

### Phase 2: Agent & Brush System (Week 2-3)
4. **DeformableAgent component**
   - Player attachment
   - Frequency-based stamping
   - Velocity threshold

5. **Brush painter improvements**
   - Multi-pass rendering (accumulation)
   - Texture channel utilization (R/G/B/A)
   - Pressure variation

6. **Material presets**
   - Snow, mud, ash configurations
   - Decay system implementation
   - Accumulation logic

### Phase 3: Streaming & Optimization (Week 3-4)
7. **Streaming integration**
   - Align with GenericTerrainStreamer
   - Chunk load/unload with terrain regions
   - Time-budgeted initialization

8. **Performance optimization**
   - Texture resolution LOD
   - Dirty flag system
   - Batch rendering

9. **Memory management**
   - Viewport pooling implementation
   - Memory profiling and tuning
   - Chunk limit enforcement

### Phase 4: Grass & Advanced Features (Week 4-5)
10. **Grass integration**
    - Modify grass.gdshader
    - Deformation texture sampling
    - Flatten/bend behavior

11. **Advanced features**
    - Slope-based deformation
    - Vehicle tracks (dual-tire)
    - Multi-material blending

### Phase 5: Persistence & Polish (Week 5-6)
12. **Persistence system**
    - Save/load implementation
    - Manifest management
    - Background saving

13. **Testing & tuning**
    - Performance profiling
    - Visual quality tuning
    - Edge case handling (chunk boundaries)

14. **Documentation & examples**
    - API documentation
    - Example scenes
    - Material preset library

---

## 9. Performance Targets

| Metric | Target | Strategy |
|--------|--------|----------|
| **FPS** | 60+ | Time-budgeted updates, GPU rendering |
| **Memory** | <50MB | Texture pooling, LOD, 512² default |
| **Chunk init time** | <2ms | Deferred initialization, viewport reuse |
| **Draw calls** | +1 per chunk | Single deformation texture per chunk |
| **CPU overhead** | <5% | GPU-based painting, minimal CPU work |
| **Save time** | <100ms | Background threading, PNG compression |

---

## 10. Known Limitations & Future Work

### Limitations
1. **Chunk boundaries**: Potential seams if deformation spans chunks
   - *Mitigation*: Overlap sampling at edges
2. **Texture resolution**: Trade-off between quality and memory
   - *Mitigation*: Dynamic LOD based on distance
3. **Physics integration**: Deformation doesn't affect physics collision
   - *Future*: Optional heightfield collision update for vehicles

### Future Enhancements
1. **Particle integration**: Dust/snow particles on deformation
2. **Audio triggers**: Footstep sounds vary with deformation depth
3. **Weather interaction**: Rain fills depressions, snow accumulates
4. **Multiplayer sync**: Network deformation data for shared worlds
5. **GPU compute**: Use compute shaders for decay updates (Vulkan only)

---

## 11. References & Integration Points

**Existing Systems:**
- `src/core/world/generic_terrain_streamer.gd` - Chunk streaming
- `src/core/world/terrain_manager.gd` - Terrain3D integration
- `addons/open-world-database/demo/resources/terrain/grass.gd` - Grass manager
- `src/core/water/ocean_manager.gd` - RTT reference implementation
- `docs/STREAMING.md` - Streaming architecture

**External Resources:**
- Terrain3D addon: `/home/user/godotwind/addons/terrain_3d/`
- Godot ViewportTexture docs: https://docs.godotengine.org/en/stable/classes/class_viewporttexture.html
- RTT best practices: https://docs.godotengine.org/en/stable/tutorials/rendering/viewports.html

---

## 12. Conclusion

This RTT deformation system provides a production-ready, performant solution for dynamic terrain interaction in open-world games. By leveraging GPU rendering, chunked streaming, and careful memory management, it achieves high visual quality while maintaining 60+ FPS.

The modular design allows for easy extension (new material types, custom brushes) and integration with existing systems (terrain streaming, grass rendering, water). Persistence support ensures player-created deformations enhance world permanence and immersion.

**Next Steps:**
1. Review and approve this design
2. Begin Phase 1 implementation (DeformationManager + basic RTT)
3. Create test scene with player deformation
4. Iterate on visual quality and performance

---

**Document Version**: 1.0
**Author**: Claude (Anthropic)
**Date**: 2025-12-17
**Status**: Design Review
