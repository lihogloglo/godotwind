#[compute]
#version 450

// Volumetric Clouds Compute Shader
// Inspired by Rafael's VAIO shader for OpenMW
// Adapted for Godot 4.5 CompositorEffect

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Input/output images
layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_texture;
layout(set = 0, binding = 2) uniform sampler3D noise_texture;

// Push constants
layout(push_constant, std430) uniform Params {
    mat4 inv_projection;
    mat4 inv_view;
    vec4 camera_position;       // xyz = position, w = time
    vec4 sun_direction;         // xyz = direction, w = sun_intensity
    vec4 cloud_params;          // x = density, y = coverage, z = speed, w = scattering
    vec4 cloud_params2;         // x = bottom_layer, y = top_layer, z = shadow_roughness, w = blend_factor
    vec4 cloud_color_day;       // RGB = day cloud color, A = cloud brightness
    vec4 cloud_color_sunset;    // RGB = sunset tint
    vec2 resolution;
    vec2 _pad;
} params;

// Constants
const int RAY_STEPS = 13;
const float PI = 3.14159265359;
const float SCALE = 0.0000050;

// Reconstruct view direction from UV
vec3 get_view_direction(vec2 uv) {
    vec4 clip_pos = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
    vec4 view_pos = params.inv_projection * clip_pos;
    view_pos.w = 0.0;
    vec4 world_dir = params.inv_view * view_pos;
    return normalize(world_dir.xyz);
}

// Get world position from depth
vec3 get_world_position(vec2 uv, float depth) {
    vec4 clip_pos = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 view_pos = params.inv_projection * clip_pos;
    view_pos /= view_pos.w;
    vec4 world_pos = params.inv_view * view_pos;
    return world_pos.xyz;
}

// Light extinction calculation
float calculate_light_exp(float l) {
    return exp(-l) * (1.0 - exp(-l * 2.0));
}

// Henyey-Greenstein phase function for cloud scattering
float hg_phase(float cos_theta, float g) {
    float g2 = g * g;
    float num = 1.0 - g2;
    float denom = 4.0 * PI * pow(1.0 + g2 - 2.0 * g * cos_theta, 1.5);
    return num / denom;
}

// Sample 3D noise for clouds
float sample_cloud_noise(vec3 pos, float time) {
    vec3 animated_pos = pos * SCALE * vec3(1.0, 1.0, 7.5);
    animated_pos -= vec3(time * params.cloud_params.z * 0.00578, 0.0, 0.0);
    return texture(noise_texture, animated_pos).r;
}

// Calculate volumetric clouds
vec2 calculate_clouds(vec3 direction, float time) {
    // Normalize and check validity
    direction = normalize(direction);
    const float MIN_DIR_Z = 0.001;

    // Clouds only visible looking up
    if (direction.z < MIN_DIR_Z) {
        return vec2(1.0, 0.0); // transmittance = 1, lighting = 0
    }

    float bottom_layer = params.cloud_params2.x;
    float top_layer = params.cloud_params2.y;

    // Bend Z for earth curvature effect
    direction.z += (1.0 - sqrt(direction.z)) * 0.07;
    direction = normalize(direction);

    float cloud_amount = 0.0;
    float cloud_lighting = 0.0;
    float density_tt = 1.0;

    float cloud_coverage = 2.0 * params.cloud_params.y;
    float cloud_threshold = 0.9 * smoothstep(2.0, 0.8, cloud_coverage);
    float absorption = 0.00175 * (1.0 + smoothstep(0.9, 2.0, cloud_coverage));

    // Calculate ray start and end
    vec3 eye_pos = params.camera_position.xyz;
    eye_pos.z = 0.0;
    vec3 ray_pos = eye_pos + (bottom_layer / direction.z) * direction;
    vec3 ray_end = eye_pos + (top_layer / direction.z) * direction;
    vec3 ray_step = (ray_end - ray_pos) / float(RAY_STEPS);

    float ray_step_length = length(ray_step);
    const float MAX_RAY_STEP = 6000.0;

    if (ray_step_length > MAX_RAY_STEP) {
        density_tt = smoothstep(9000.0, MAX_RAY_STEP, ray_step_length) * 0.15 + 0.85;
        ray_step = ray_step / ray_step_length * MAX_RAY_STEP;
        ray_step_length = MAX_RAY_STEP;
    }

    // Direction for stretch effect
    const vec2 MOVE_DIR = normalize(vec2(1.0, -1.0));
    const float STRETCH = 1.5;
    mat2 stretch_mat = mat2(
        mix(1.0, STRETCH, MOVE_DIR.x * MOVE_DIR.x),
        MOVE_DIR.x * MOVE_DIR.y * (STRETCH - 1.0),
        MOVE_DIR.x * MOVE_DIR.y * (STRETCH - 1.0),
        mix(1.0, STRETCH, MOVE_DIR.y * MOVE_DIR.y)
    );

    vec3 light_dir = params.sun_direction.xyz;
    light_dir.z = abs(light_dir.z); // Ensure positive for night

    float noise_hi = 1.0;
    float noise_prev = 0.0;
    float variance = 0.0;
    const float FLUFFINESS = 1.3;

    // Ray march through cloud layer
    for (int i = 0; i < RAY_STEPS; i++) {
        vec3 warped_pos = vec3(stretch_mat * ray_pos.xy, ray_pos.z);
        noise_prev = noise_hi;
        noise_hi = sample_cloud_noise(warped_pos, time);

        if (i > 0) {
            variance += abs(noise_hi - noise_prev);
        }

        float noise_shaped = noise_hi * noise_hi;
        noise_shaped *= cloud_coverage * 4.0 * FLUFFINESS;

        if (noise_shaped > 0.01) {
            const float FADE_MARGIN = 5000.0;
            float light_tt = density_tt;

            // Light sampling - two steps toward sun
            vec3 light_sample_pos = warped_pos + light_dir * 1500.0;
            float ls = sample_cloud_noise(light_sample_pos, time);
            ls *= cloud_coverage * FLUFFINESS * absorption * 1500.0
                * smoothstep(bottom_layer - FADE_MARGIN, bottom_layer, light_sample_pos.z)
                * smoothstep(top_layer + FADE_MARGIN, top_layer, light_sample_pos.z);
            light_tt *= calculate_light_exp(ls);

            light_sample_pos += light_dir * 2200.0;
            ls = sample_cloud_noise(light_sample_pos, time);
            ls *= cloud_coverage * absorption * 2200.0
                * smoothstep(bottom_layer - FADE_MARGIN, bottom_layer, light_sample_pos.z)
                * smoothstep(top_layer + FADE_MARGIN, top_layer, light_sample_pos.z);
            light_tt *= calculate_light_exp(ls);

            ls = log2(1.0 + noise_shaped) * 1.442695; // 1/log2(2)
            cloud_lighting += light_tt * ls;
        }

        // Accumulate cloud density
        float extinction = absorption * noise_hi * cloud_coverage * FLUFFINESS * 0.01;
        extinction = exp(-extinction * ray_step_length);
        cloud_amount += density_tt * noise_shaped * (1.0 - extinction * 0.935);
        density_tt *= extinction;

        ray_pos += ray_step;
    }

    // Calculate variance-based lighting adjustment
    float sun_dot = dot(light_dir, direction);
    variance = exp2(-variance * 0.2) * mix(
        1.0,
        1.0 - exp2(-pow(cloud_amount, 8.0) * 3.0),
        (1.0 - pow(sun_dot, 5.0)) * smoothstep(0.05, 0.2, params.sun_direction.z)
    );

    cloud_lighting = clamp(cloud_lighting * mix(variance, 1.0, ray_step_length * 0.00012), 0.0, 1.0);
    cloud_lighting *= sqrt(cloud_lighting);

    // Apply threshold
    cloud_amount = max(0.0, clamp(cloud_amount, 0.0, 1.0) - cloud_threshold) / (1.0 - cloud_threshold);

    return vec2(clamp(cloud_amount, 0.0, 1.0), 1.0 - clamp(cloud_lighting, 0.0, 1.0));
}

void main() {
    ivec2 pixel_coords = ivec2(gl_GlobalInvocationID.xy);

    if (pixel_coords.x >= int(params.resolution.x) || pixel_coords.y >= int(params.resolution.y)) {
        return;
    }

    vec2 uv = (vec2(pixel_coords) + 0.5) / params.resolution;

    // Sample depth
    float depth = texture(depth_texture, uv).r;

    // Only render clouds on sky pixels (reversed-Z: sky is near 0)
    bool is_sky = depth < 0.0001;
    if (!is_sky) {
        return;
    }

    // Get view direction
    vec3 direction = get_view_direction(uv);

    // Skip if looking down
    if (direction.z < 0.001) {
        return;
    }

    float time = params.camera_position.w;

    // Calculate clouds
    vec2 cloud_result = calculate_clouds(direction, time);
    float cloud_amount = cloud_result.x;
    float cloud_shadow = cloud_result.y;

    if (cloud_amount < 0.001) {
        return;
    }

    // Apply blend factor
    cloud_amount *= params.cloud_params2.w;

    // Load original sky color
    vec4 original_color = imageLoad(color_image, pixel_coords);

    // Calculate cloud color based on lighting and sun position
    float sun_height = params.sun_direction.z;
    float sunset_factor = 1.0 - smoothstep(0.0, 0.3, sun_height);

    vec3 cloud_lit = params.cloud_color_day.rgb * params.cloud_color_day.a;
    vec3 cloud_shadow_color = cloud_lit * 0.4;

    // Add sunset tint
    cloud_lit = mix(cloud_lit, params.cloud_color_sunset.rgb, sunset_factor * 0.5);

    // Apply scattering
    float cos_theta = dot(direction, params.sun_direction.xyz);
    float scatter = hg_phase(cos_theta, 0.3) * params.cloud_params.w;
    cloud_lit += scatter * params.cloud_color_sunset.rgb * params.sun_direction.w;

    // Mix lit and shadowed cloud colors
    vec3 cloud_color = mix(cloud_lit, cloud_shadow_color, cloud_shadow);

    // Blend clouds with sky
    vec3 final_color = mix(original_color.rgb, cloud_color, cloud_amount);

    imageStore(color_image, pixel_coords, vec4(final_color, original_color.a));
}
