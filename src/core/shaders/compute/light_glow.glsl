#[compute]
#version 450

// Light Glow Compute Shader — Point Light Fog Halos
// Point-light glow (CalculateLights) pass.
//
// Accumulates per-pixel glow from nearby point lights, creating halos
// through fog. Light radius expands in foggier conditions. Glow fades
// with sun height (lights more visible at night/dusk).
//
// Light data is uploaded as a Storage Buffer (SSBO) since push constants
// can't hold variable-length arrays. Max 64 lights per frame.
//
// Runs at half resolution for performance. The combine pass in the
// godrays/fog pipeline reads the result via shared texture.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Output glow image (half resolution, additive RGB)
layout(rgba16f, set = 0, binding = 0) uniform image2D glow_image;
// Scene depth for world position reconstruction
layout(set = 0, binding = 1) uniform sampler2D depth_texture;

// Light data SSBO — each light is 8 floats (2 vec4s)
// [0]: position.xyz, radius
// [1]: color.rgb, intensity
layout(std430, set = 0, binding = 2) readonly buffer LightBuffer {
    vec4 light_data[];  // pairs of vec4: [pos+radius, color+intensity]
};

// Push constants (128 bytes max)
layout(push_constant, std430) uniform Params {
    mat4 inv_projection;        // 64 bytes
    vec4 camera_position;       // xyz = pos, w = time
    vec4 fog_params;            // x = fog_intensity, y = fogginess, z = sun_height, w = light_count
    vec2 resolution;            // full scene resolution
    vec2 half_resolution;       // half resolution (dispatch size)
} params;
// Total: 64 + 16 + 16 + 8 + 8 = 112 bytes (under 128)

const float PI = 3.14159265359;

// ─── World Position Reconstruction ───

vec3 get_world_position(vec2 uv, float depth) {
    vec4 clip_pos = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 view_pos = params.inv_projection * clip_pos;
    view_pos /= view_pos.w;
    // Note: inv_projection gives us view-space position
    // For this effect we use view-space distance which is sufficient
    return view_pos.xyz;
}

// ─── Light Glow Calculation ───

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    if (pixel.x >= int(params.half_resolution.x) || pixel.y >= int(params.half_resolution.y))
        return;

    int light_count = int(params.fog_params.w);
    if (light_count <= 0) {
        imageStore(glow_image, pixel, vec4(0.0));
        return;
    }

    // Map half-res pixel to full-res UV for depth sampling
    vec2 uv = (vec2(pixel) * 2.0 + 1.0) / params.resolution;

    // Sample depth (reversed-Z)
    float depth = texture(depth_texture, uv).r;
    bool is_sky = depth < 0.001;

    // Reconstruct world position
    vec3 world_pos = get_world_position(uv, depth);
    float world_distance = is_sky ? 10000.0 : length(world_pos - params.camera_position.xyz);
    vec3 view_dir = normalize(world_pos - params.camera_position.xyz);

    // Fog-based radius expansion (lightRadius *= (fogginess + 1.0))
    float fogginess = params.fog_params.y;  // 0 = clear, ~5 = very foggy

    // Sun-based intensity reduction (lights less visible in bright daylight)
    float sun_height = params.fog_params.z;  // sun Y direction
    float day_factor = clamp(max(sun_height, 0.0) * 2.0, 0.0, 1.0);
    float base_intensity = mix(1.0, 0.025, day_factor) * 0.5;

    // Accumulate glow from all lights
    vec3 sum_color = vec3(0.0);

    for (int i = 0; i < light_count; i++) {
        // Read light data from SSBO (2 vec4s per light)
        vec4 pos_radius = light_data[i * 2];
        vec4 col_intensity = light_data[i * 2 + 1];

        vec3 light_pos = pos_radius.xyz;
        float light_radius = max(0.001, pos_radius.w);

        // Fog-expanded radius
        light_radius *= (fogginess + 1.0);

        // Distance from pixel's world ray to the light
        float light_dist = distance(params.camera_position.xyz, light_pos);

        // Project pixel along view ray to the closest point to the light
        vec3 projected_pos = params.camera_position.xyz + min(world_distance, light_dist) * view_dir;
        float dist_to_light = distance(projected_pos, light_pos);

        float dist_ratio = dist_to_light / light_radius;
        if (dist_ratio > 1.0)
            continue;

        // Glow intensity
        float intensity = params.fog_params.x * base_intensity * col_intensity.w;

        // Fade with distance to the light source
        float fade_dist = 13000.0;  // LightsFadeDistanceEnd default
        intensity *= smoothstep(fade_dist, fade_dist * 0.9, light_dist);

        // Reduce in bright fog (smoothstep(5.0, 0.0, fogginess) * 0.75 + 0.25)
        intensity *= 0.75 * smoothstep(5.0, 0.0, fogginess) + 0.25;

        // Directional occlusion: reduce glow when looking away from the light
        if (dist_to_light > 0.0)
            intensity *= 1.0 - max(0.0, dot(view_dir, (light_pos - projected_pos) / dist_to_light));

        // Smooth falloff (1 - sqrt(distanceRatio), then pow with per-channel exponents)
        dist_ratio = 1.0 - sqrt(max(dist_ratio, 0.0));
        vec3 light_color = col_intensity.rgb * pow(vec3(dist_ratio), vec3(1.3, 1.4, 1.5)) * intensity;

        // Additive accumulation with saturation
        sum_color = clamp(light_color * (1.0 - sum_color) + sum_color, 0.0, 1.0);
    }

    imageStore(glow_image, pixel, vec4(sum_color, 1.0));
}
