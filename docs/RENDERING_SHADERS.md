# Rendering & Shaders

---

## Ocean System (FFT-based)

> **Status:** Framework ready, NOT integrated into main world_explorer scene.

**Implementation:** `src/core/water/`

**Features:**
- Compute shader FFT for realistic wave simulation
- Gerstner waves for surface displacement
- Buoyancy simulation for objects
- Underwater rendering (fog, caustics)

**Compute shader (FFT):**
```glsl
// src/core/water/shaders/compute/fft_pass.glsl
#version 450

layout(local_size_x = 16, local_size_y = 16) in;
layout(set = 0, binding = 0, rgba32f) uniform image2D displacement_map;

void main() {
    ivec2 pixel_coords = ivec2(gl_GlobalInvocationID.xy);
    vec4 wave_data = perform_fft_step(pixel_coords);
    imageStore(displacement_map, pixel_coords, wave_data);
}
```

**Surface shader:**
```gdshader
shader_type spatial;

uniform sampler2D displacement_map;
uniform sampler2D normal_map;
uniform float wave_amplitude = 1.0;

void vertex() {
    vec4 displacement = texture(displacement_map, UV);
    VERTEX.y += displacement.y * wave_amplitude;
}

void fragment() {
    ALBEDO = vec3(0.02, 0.05, 0.1);
    ROUGHNESS = 0.1;
    METALLIC = 0.0;
    NORMAL_MAP = texture(normal_map, UV).rgb;
}
```

**Note:** Custom SSR in water shaders (`src/core/water/shaders/flat_water.gdshader`) is SEPARATE from Godot's engine SSR.

---

## Terrain Deformation (RTT-based)

**Implementation:** `src/core/deformation/`

**Technique: Render-to-Texture (RTT) stamping**
- Render deformation "stamps" to heightmap texture
- Use texture in terrain shader for displacement
- Supports dynamic recovery (deformation fades over time)

```gdshader
shader_type spatial;

uniform sampler2D deformation_map;
uniform float deformation_strength = 1.0;

void vertex() {
    vec2 world_uv = (VERTEX.xz - world_origin) / world_size;
    float deformation = texture(deformation_map, world_uv).r;
    VERTEX.y -= deformation * deformation_strength;
}
```

---

## Selection Outline Shader

**Usage:** Console command selection in world explorer

```gdshader
shader_type spatial;
render_mode unshaded;

uniform vec4 outline_color : source_color = vec4(1.0, 0.5, 0.0, 1.0);
uniform float outline_width = 0.05;

void vertex() {
    VERTEX += NORMAL * outline_width;
}

void fragment() {
    ALBEDO = outline_color.rgb;
}
```

---

## Impostor Billboard Shader

**Octahedral projection for FAR tier (500-5000m):**

```gdshader
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;

uniform sampler2DArray impostor_textures;
uniform int texture_layer = 0;

void vertex() {
    mat4 billboard_mat = mat4(1.0);
    billboard_mat[0].xyz = normalize(CAMERA_MATRIX[0].xyz);
    billboard_mat[1].xyz = normalize(CAMERA_MATRIX[1].xyz);
    billboard_mat[2].xyz = normalize(CAMERA_MATRIX[2].xyz);
    MODELVIEW_MATRIX = CAMERA_MATRIX * billboard_mat;
}

void fragment() {
    vec3 view_dir = normalize(CAMERA_POSITION_WORLD - VERTEX);
    int layer = calculate_octahedral_layer(view_dir);
    vec4 color = texture(impostor_textures, vec3(UV, float(layer)));
    ALBEDO = color.rgb;
    ALPHA = color.a;
}

int calculate_octahedral_layer(vec3 view_dir) {
    vec3 abs_dir = abs(view_dir);
    if (abs_dir.x > abs_dir.y && abs_dir.x > abs_dir.z) {
        return view_dir.x > 0.0 ? 0 : 1;
    } else if (abs_dir.y > abs_dir.z) {
        return view_dir.y > 0.0 ? 2 : 3;
    } else {
        return view_dir.z > 0.0 ? 4 : 5;
    }
}
```

---

## Distance Rendering Details

See `docs/DISTANCE_RENDERING_AUDIT.md` for full implementation status, recent fixes, and known issues.

**Distance constants (single source of truth):** `src/core/world/distance_utils.gd`

| Tier | Range | Technique |
|------|-------|-----------|
| NEAR | 0-150m | Full 3D meshes + physics |
| MID | 150-500m | LOD meshes (3 levels) via visibility_range |
| FAR | 500-5km | Octahedral impostors via single MultiMesh |

**LOD Configuration:**
```gdscript
# NEAR tier
geo.visibility_range_begin = 0.0
geo.visibility_range_end = 150.0
geo.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
geo.visibility_range_end_margin = 50.0  # Hysteresis prevents flicker

# MID tier LOD1 (150-250m)
geo.visibility_range_begin = 150.0
geo.visibility_range_end = 250.0
geo.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES
```
