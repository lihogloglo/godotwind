# Terrain3D Integration Analysis for RTT Deformation

## Overview

This document analyzes Terrain3D's capabilities and how to optimally integrate the RTT deformation system with it.

---

## Terrain3D Core Capabilities

### 1. Runtime API

Based on code analysis in `project_on_terrain3d.gd` and existing usage:

```gdscript
# Height Queries
var height: float = terrain.data.get_height(world_position)  # Returns NaN if not in region
var is_valid = not is_nan(height)

# Normal Queries
var normal: Vector3 = terrain.data.get_normal(world_position)  # For slope calculations

# Texture Queries
var texture_info: Vector3 = terrain.data.get_texture_id(world_position)
var base_texture_id: int = int(texture_info.x)
var overlay_texture_id: int = int(texture_info.y)
var blend_value: float = texture_info.z  # 0-1 blend between base and overlay

# Region Management
var region_count: int = terrain.data.get_region_count()
var region_location: Vector2i = terrain.data.get_region_location(world_pos)

# Import/Modify Data
terrain.data.import_images(images, world_pos, height_offset, height_scale)
# images: Array[Image] with [TYPE_HEIGHT, TYPE_CONTROL, TYPE_COLOR]
```

### 2. Shader Architecture

From `minimum.gdshader` and `lightweight.gdshader`:

**Key Uniforms (Built-in):**
```glsl
uniform vec3 _camera_pos;
uniform float _mesh_size = 48.0;
uniform float _vertex_spacing = 1.0;
uniform float _region_size = 1024.0;
uniform float _region_texel_size = 0.0009765625;  // 1/region_size
uniform int _region_map_size = 32;
uniform int _region_map[1024];  // Region lookup table
uniform highp sampler2DArray _height_maps;  // All region heightmaps
uniform highp sampler2DArray _control_maps;  // Texture/hole data
uniform highp sampler2DArray _color_maps;  // Vertex colors
```

**Render Mode:**
```glsl
render_mode skip_vertex_transform;
// Terrain3D handles vertex transformation manually for optimal LOD
```

**UV System:**
- `UV` = World space coordinates (in meters, using vertex density)
- `UV2` = Region-local coordinates (0-1 within each region)
- `get_index_coord(uv, pass)` = Convert to region index + layer

**Height Application (vertex shader, line 116):**
```glsl
void vertex() {
    // ... geomorphing and region lookup ...

    float h = mix(
        texelFetch(_height_maps, uv_a, 0).r,
        texelFetch(_height_maps, uv_b, 0).r,
        vertex_lerp
    );
    v_vertex.y = h;  // ← Set vertex height

    // Convert to view space
    VERTEX = (VIEW_MATRIX * vec4(v_vertex, 1.0)).xyz;
}
```

**Normal Calculation (fragment shader, lines 166-199):**
```glsl
void fragment() {
    // Sample surrounding heights for gradient
    float h[4];
    h[3] = texelFetch(_height_maps, index[3], 0).r;
    h[2] = texelFetch(_height_maps, index[2], 0).r;
    // ... more samples ...

    // Custom derivative injection point (lines 166-167):
    float u = 0.0;  // ← Can be modified for custom effects
    float v = 0.0;  // ← Can be modified for custom effects

    // Calculate normal with custom derivatives
    index_normal[3] = normalize(vec3(
        h[3] - h[2] + u,  // X gradient + custom
        _vertex_spacing,
        h[3] - h[0] + v   // Z gradient + custom
    ));
}
```

### 3. Region System

**Region Structure:**
- Size: 1024x1024 pixels (default)
- Texel size: ~0.00097 (1/1024)
- World coverage: `region_size * vertex_spacing` meters
- Multiple regions in a sparse grid (32x32 max)
- Regions can be non-contiguous

**Current Godotwind Configuration:**
- Effective region size: 256x256 (4x4 Morrowind cells)
- Vertex spacing: ~1.83m (117m cell / 64 vertices)
- Region world size: ~468m (256 * 1.83)
- Total coverage: 32x32 regions = ~15km × 15km

---

## Integration Strategy for RTT Deformation

### Option 1: Shader-Only Deformation (RECOMMENDED)

**Approach:** Add deformation texture sampling directly in custom Terrain3D shader.

**Pros:**
- ✅ Non-destructive (doesn't modify base heightmap)
- ✅ Per-frame updates (dynamic)
- ✅ Minimal memory overhead (one RTT per chunk)
- ✅ Clean separation of concerns
- ✅ Works with existing terrain streaming
- ✅ Can easily disable/enable

**Cons:**
- ❌ Physics collision doesn't match visuals (unless manually synced)
- ❌ Shader complexity increases

**Implementation:**
```glsl
// In custom Terrain3D shader (vertex function)
uniform sampler2DArray deformation_textures;  // One per region
uniform int deformation_texture_count = 0;

void vertex() {
    // ... existing Terrain3D height lookup ...
    float base_height = texelFetch(_height_maps, uv, 0).r;

    // Sample deformation for this region
    vec3 region_uv = get_index_uv(UV2);  // Terrain3D built-in function
    int region_index = int(region_uv.z);

    float deformation = 0.0;
    if (region_index >= 0 && region_index < deformation_texture_count) {
        deformation = texture(_deformation_textures[region_index], region_uv.xy).r;
    }

    // Apply deformation (negative = down)
    v_vertex.y = base_height - (deformation * 0.3);  // 0.3m max depth

    // ... rest of Terrain3D vertex transform ...
}

void fragment() {
    // Modify u/v for normal perturbation
    vec3 region_uv = get_index_uv(UV2);
    int region_index = int(region_uv.z);

    float u = 0.0;
    float v = 0.0;

    if (region_index >= 0 && region_index < deformation_texture_count) {
        vec2 texel = 1.0 / vec2(textureSize(_deformation_textures[region_index], 0));
        float d_center = texture(_deformation_textures[region_index], region_uv.xy).r;
        float d_x = texture(_deformation_textures[region_index], region_uv.xy + vec2(texel.x, 0.0)).r;
        float d_z = texture(_deformation_textures[region_index], region_uv.xy + vec2(0.0, texel.y)).r;

        u = (d_center - d_x) * 0.3;  // X gradient
        v = (d_center - d_z) * 0.3;  // Z gradient
    }

    // ... Terrain3D normal calculation uses u/v ...
}
```

**Texture Management:**
- One `Texture2DArray` with all active deformation chunks
- Update array when chunks load/unload
- Map region index to array layer

---

### Option 2: Heightmap Modification

**Approach:** Directly modify Terrain3D's heightmap data.

**Pros:**
- ✅ Physics collision matches visuals automatically
- ✅ Simpler shader (no additional sampling)
- ✅ Native Terrain3D normals

**Cons:**
- ❌ Destructive (modifies original terrain)
- ❌ Harder to reset/disable
- ❌ Requires heightmap CPU/GPU sync
- ❌ May conflict with streaming system
- ❌ Performance cost of re-importing

**Implementation:**
```gdscript
# In DeformationChunk
func apply_to_terrain3d(terrain: Terrain3D) -> void:
    # Get current heightmap
    var world_pos = Vector3(chunk_coord.x * chunk_size, 0, chunk_coord.y * chunk_size)
    var region_loc = terrain.data.get_region_location(world_pos)

    # Read back RTT deformation texture
    var deform_image = viewport.get_texture().get_image()

    # Read current Terrain3D heightmap
    var heightmap = terrain.data.get_height_map(region_loc)  # Need to verify this API

    # Blend deformation into heightmap
    for y in heightmap.get_height():
        for x in heightmap.get_width():
            var deform_depth = deform_image.get_pixel(x, y).r
            var current_height = heightmap.get_pixel(x, y).r
            heightmap.set_pixel(x, y, Color(current_height - deform_depth * 0.3, 0, 0))

    # Re-import modified heightmap
    var images: Array[Image] = []
    images.resize(Terrain3DRegion.TYPE_MAX)
    images[Terrain3DRegion.TYPE_HEIGHT] = heightmap
    terrain.data.import_images(images, world_pos, 0.0, 1.0)
```

**Issues:**
- Performance: Re-importing large heightmaps every frame is expensive
- Conflicts: Terrain streaming may overwrite modifications
- Persistence: Need to save modified heightmaps separately

---

### Option 3: Hybrid Approach

**Approach:** Use shader for visuals, sync to heightmap periodically for physics.

**Pros:**
- ✅ Dynamic visual updates
- ✅ Physics eventually consistent
- ✅ Can batch physics updates

**Cons:**
- ❌ Complex coordination
- ❌ Temporary visual/physics mismatch
- ❌ Both systems running

---

## Recommended Implementation: Shader-Only (Option 1)

### Architecture

```
DeformationManager (Singleton)
├─ Per-Region Deformation Chunks
│  ├─ RTT Viewport (512x512)
│  └─ Deformation Texture (R=depth, G=accumulation, B=wetness, A=age)
│
├─ Texture2DArray Builder
│  └─ Combines all active chunk textures into array
│
└─ Material Management
   └─ Updates Terrain3D shader uniforms

Terrain3D Custom Shader
├─ vertex(): Sample deformation array, apply offset
└─ fragment(): Sample deformation for normal derivatives
```

### Chunk-to-Region Mapping

**Alignment:**
- Terrain3D regions: ~468m (256 * 1.83m spacing)
- Deformation chunks: 256m (configurable)
- **Strategy**: 1 deformation chunk per terrain region (resize chunks to match)

**Alternative:**
- Multiple deformation chunks per region (e.g., 2×2 for finer detail)
- Requires texture atlas or layered sampling

### Shader Uniform Updates

```gdscript
# In DeformationManager
func update_terrain_shader() -> void:
    if not terrain_3d:
        return

    # Build Texture2DArray from active chunks
    var texture_array = _build_deformation_array()

    # Update shader uniforms
    var material: ShaderMaterial = terrain_3d.material  # or override material
    material.set_shader_parameter("deformation_textures", texture_array)
    material.set_shader_parameter("deformation_texture_count", active_chunks.size())
    material.set_shader_parameter("deformation_scale", deformation_depth_max)
```

### Texture2DArray Building

```gdscript
func _build_deformation_array() -> Texture2DArray:
    var texture_array = Texture2DArray.new()

    # Collect all chunk textures
    var images: Array[Image] = []
    for chunk in active_chunks.values():
        var img = chunk.deformation_texture.get_image()
        images.append(img)

    # Create array texture
    if images.size() > 0:
        texture_array.create_from_images(images)

    return texture_array
```

---

## Custom Shader Template

Create `/addons/terrain_3d/extras/shaders/deformation.gdshader`:

```glsl
shader_type spatial;
render_mode blend_mix,depth_draw_opaque,cull_back,diffuse_burley,specular_schlick_ggx,skip_vertex_transform;

// Include Terrain3D base shader (copy from lightweight.gdshader)
// ... [full Terrain3D shader code] ...

// ============= DEFORMATION SYSTEM ADDITIONS =============

// Deformation uniforms
uniform sampler2DArray deformation_textures : hint_default_white;
uniform int deformation_region_count = 0;
uniform float deformation_scale = 0.3;  // Max depth in meters

// Deformation region map: region_index -> deformation_texture_layer
// -1 = no deformation for this region
uniform int deformation_map[1024];

void vertex() {
    // ... [Terrain3D vertex code up to height application] ...

    float h = mix(texelFetch(_height_maps, uv_a, 0).r, texelFetch(_height_maps, uv_b, 0).r, vertex_lerp);

    // ===== DEFORMATION SAMPLING =====
    float deformation_depth = 0.0;

    ivec3 v_region = get_index_coord(start_pos, VERTEX_PASS);
    int region_layer = v_region.z;

    if (region_layer >= 0 && region_layer < 1024) {
        int deform_layer = deformation_map[region_layer];
        if (deform_layer >= 0 && deform_layer < deformation_region_count) {
            vec2 region_uv = UV2;  // Already calculated by Terrain3D
            deformation_depth = texture(deformation_textures, vec3(region_uv, float(deform_layer))).r;
        }
    }

    // Apply deformation (negative displacement)
    v_vertex.y = h - (deformation_depth * deformation_scale);
    // ===== END DEFORMATION =====

    // ... [rest of Terrain3D vertex transform] ...
}

void fragment() {
    // ... [Terrain3D fragment code] ...

    // ===== DEFORMATION NORMAL MODIFICATION =====
    float u = 0.0;
    float v = 0.0;

    ivec3 region = get_index_coord(index_id, FRAGMENT_PASS);
    int region_layer = region.z;

    if (region_layer >= 0 && region_layer < 1024) {
        int deform_layer = deformation_map[region_layer];
        if (deform_layer >= 0 && deform_layer < deformation_region_count) {
            vec2 texel_size = 1.0 / vec2(textureSize(deformation_textures, 0).xy);
            float d_center = texture(deformation_textures, vec3(UV2, float(deform_layer))).r;
            float d_x = texture(deformation_textures, vec3(UV2 + vec2(texel_size.x, 0.0), float(deform_layer))).r;
            float d_z = texture(deformation_textures, vec3(UV2 + vec2(0.0, texel_size.y), float(deform_layer))).r;

            u = (d_center - d_x) * deformation_scale * 10.0;
            v = (d_center - d_z) * deformation_scale * 10.0;
        }
    }
    // ===== END DEFORMATION NORMAL =====

    // ... [Terrain3D normal calculation uses u/v] ...
}
```

---

## Physics Collision Handling

**Problem:** Shader deformation doesn't affect physics collision.

**Solutions:**

### Solution A: Ignore (Recommended for most cases)
- Deformation is shallow (<30cm typically)
- Players/NPCs can "sink" slightly into visual deformation
- Most noticeable in deep snow - acceptable tradeoff

### Solution B: Character Controller Raycasting
- Custom character controller uses terrain height queries
- Raycast down, adjust player height
- Check deformation depth at player position
- Offset player Y by deformation amount

```gdscript
# In player controller
func adjust_for_terrain_deformation() -> void:
    var terrain_height = terrain.data.get_height(global_position)
    var deform_depth = DeformationManager.get_deformation_at(global_position)

    # Adjust player height to match visual deformation
    var target_y = terrain_height - deform_depth
    global_position.y = target_y + player_height_offset
```

### Solution C: Dynamic Collision Shape Updates (Heavy)
- Periodically update terrain collision heightfield
- Only practical for small, localized areas
- Not recommended for open-world streaming

---

## Performance Analysis

### Memory Footprint

**Per Chunk:**
- RTT texture: 512×512 × RGBA16F = 2MB
- Viewport overhead: ~500KB
- **Total per chunk: ~2.5MB**

**25 Active Chunks:**
- Deformation textures: 25 × 2.5MB = 62.5MB
- Texture2DArray (references same data): Minimal overhead
- **Total: ~65MB**

**Optimizations:**
- Use RGBA8 instead of RGBA16F: 512KB per chunk (12.5MB total)
- Reduce resolution to 256×256: 256KB per chunk (6.25MB total)
- Aggressive unloading: Keep only visible chunks

### Rendering Cost

**Additional Draw Calls:** None (integrated into Terrain3D shader)

**Additional Texture Samples:**
- Vertex shader: 1 sample per vertex (deformation depth)
- Fragment shader: 3 samples per fragment (depth + gradients for normal)
- **Total: +4 texture samples per fragment**

**GPU Impact:**
- Modern GPUs: Negligible (<1% for texture sampling)
- Bottleneck likely elsewhere (terrain geometry, textures)

### Update Cost

**Per Frame:**
- Dirty chunk rendering: 1-2 chunks max
- Texture2DArray rebuild: Only when chunks load/unload
- Shader uniform update: Minimal (one set_shader_parameter call)

**Time Budget:**
- Chunk creation: <2ms (viewport pooling)
- Brush rendering: <0.5ms (GPU)
- Array rebuild: <1ms (on chunk change only)
- **Total overhead: <1ms average**

---

## Implementation Checklist

### Phase 1: Core Integration
- [ ] Create custom Terrain3D shader with deformation support
- [ ] Implement Texture2DArray builder in DeformationManager
- [ ] Map deformation chunks to Terrain3D regions (1:1)
- [ ] Connect chunk load/unload to shader uniform updates
- [ ] Test single region with basic deformation

### Phase 2: Shader Optimization
- [ ] Implement deformation_map for sparse region lookup
- [ ] Add normal perturbation via u/v derivatives
- [ ] Optimize texture sampling (early exit if no deformation)
- [ ] Test with multiple active regions

### Phase 3: Advanced Features
- [ ] Implement grass deformation (separate shader)
- [ ] Add material presets (snow/mud/ash)
- [ ] Implement decay and accumulation
- [ ] Add persistence system

### Phase 4: Polish
- [ ] Performance profiling and optimization
- [ ] Edge case handling (chunk boundaries)
- [ ] Visual quality tuning
- [ ] Documentation and examples

---

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Integration Method** | Shader-Only | Non-destructive, performant, flexible |
| **Chunk Size** | Match Terrain3D regions (~256m) | Simplifies mapping, reduces overhead |
| **Texture Format** | RGBA8 | Good quality/memory balance |
| **Texture Resolution** | 512×512 | 0.5m/pixel detail, reasonable memory |
| **Physics Handling** | Character controller adjustment | Acceptable tradeoff for open-world |
| **Update Strategy** | Lazy (on-demand) | Minimize overhead, most areas static |

---

## Next Steps

1. Read through full Terrain3D shader (lightweight.gdshader)
2. Create modified version with deformation sampling
3. Implement Texture2DArray management in DeformationManager
4. Test with single region in isolated scene
5. Integrate with existing terrain streaming system
6. Add grass deformation support
7. Optimize and polish

---

**Document Version**: 1.0
**Date**: 2025-12-17
**Status**: Design Review → Implementation Ready
