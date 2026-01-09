#[compute]
#version 450

// Volumetric Fog Compute Shader
// Inspired by Rafael's VAIO shader for OpenMW
// Adapted for Godot 4.5 CompositorEffect

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Input/output images
layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_texture;
layout(set = 0, binding = 2) uniform sampler3D noise_texture;
layout(set = 0, binding = 3) uniform sampler2D noise_2d_texture;

// Push constants for parameters
layout(push_constant, std430) uniform Params {
    mat4 inv_projection;
    mat4 inv_view;
    vec4 camera_position;   // xyz = position, w = time
    vec4 fog_color;         // rgb = color, a = intensity
    vec4 fog_params;        // x = density, y = height_falloff, z = start_distance, w = end_distance
    vec4 fog_params2;       // x = speed, y = height_based_multiplier, z = stamp_intensity, w = stamp_contrast
    vec4 sun_direction;     // xyz = direction, w = sun_intensity
    vec2 resolution;
    float blend_factor;
    float _pad;
} params;

// Constants
const int RAY_STEPS = 24;
const float PI = 3.14159265359;

// Reconstruct world position from depth
vec3 get_world_position(vec2 uv, float depth) {
    // Convert UV to clip space
    vec4 clip_pos = vec4(uv * 2.0 - 1.0, depth, 1.0);

    // Transform to view space
    vec4 view_pos = params.inv_projection * clip_pos;
    view_pos /= view_pos.w;

    // Transform to world space
    vec4 world_pos = params.inv_view * view_pos;
    return world_pos.xyz;
}

// Sample 3D noise with animation
float sample_noise_3d(vec3 pos, float time) {
    vec3 animated_pos = pos * 0.00011 - vec3(time * params.fog_params2.x * 0.002);
    animated_pos.z *= -1.17;
    return texture(noise_texture, animated_pos).r;
}

// Sample 2D noise for stamping
float sample_noise_2d(vec2 uv, float time) {
    vec2 animated_uv = uv * 0.00012 - vec2(time * params.fog_params2.x * 0.0021);
    return texture(noise_2d_texture, animated_uv).r;
}

// Height-based fog density falloff
float get_height_factor(float height, float eye_height) {
    float falloff = params.fog_params.y;
    float height_diff = eye_height - height;

    if (height_diff > 0.0) {
        // Below camera - more fog
        return mix(1.0, params.fog_params2.y, smoothstep(0.0, 3500.0, height_diff));
    } else {
        // Above camera - less fog
        return smoothstep(eye_height + 3500.0, eye_height - 500.0, height);
    }
}

// Calculate volumetric fog using ray marching
float calculate_fog(vec3 world_pos, vec3 ray_dir, float world_distance, float time) {
    float fog_amount = 0.0;
    float intensity = params.fog_color.a;

    if (intensity <= 0.0 || world_distance <= 0.0) {
        return 0.0;
    }

    // Clamp distance for sky
    float march_distance = min(world_distance, params.fog_params.w);

    vec3 ray_step = ray_dir * (march_distance / float(RAY_STEPS));
    vec3 ray_pos = params.camera_position.xyz + ray_step * 0.5;
    float ray_step_length = length(ray_step);
    float ray_length = ray_step_length * 0.5;

    float noise_hi = 1.0;
    float noise_hi_prev = 1.0;
    float noise_lo = 1.0;

    // Ray march through the fog volume
    for (int i = 0; i < RAY_STEPS; i++) {
        noise_hi_prev = noise_hi;

        // Sample high-frequency 3D noise
        noise_hi = sample_noise_3d(ray_pos, time);

        // Distance-based attenuation to prevent aliasing
        noise_hi = mix(noise_hi, 0.5, smoothstep(0.0, 15000.0, ray_length));

        // Sample low-frequency 2D noise every other step
        if (i % 2 == 0) {
            vec2 uv = ray_pos.xy + vec2(noise_hi, noise_hi_prev) * 1900.0;
            noise_lo = 0.25 + 0.75 * sample_noise_2d(uv, time);
        }

        // Combine noises
        float noise = noise_lo * noise_hi;

        // Height-based adjustment
        float height_factor = get_height_factor(ray_pos.z, params.camera_position.z);
        noise *= height_factor;

        ray_pos += ray_step;
        fog_amount += noise;
        ray_length += ray_step_length;
    }

    fog_amount /= float(RAY_STEPS);

    // Distance-based distribution
    vec3 distance_traveled = ray_pos - params.camera_position.xyz;
    if (distance_traveled.z < 0.0) {
        distance_traveled.z *= params.fog_params2.y; // Height multiplier for valleys
    }
    fog_amount *= sqrt(length(distance_traveled)) * 0.019;

    // Apply stamping for more organic look
    if (fog_amount > 0.00001 && params.fog_params2.z > 0.0) {
        float wave = sin(time * 0.2);
        vec2 stamp_uv = ray_pos.xy + vec2(wave, -wave) * 200.0 - ray_pos.zz;
        stamp_uv += vec2(noise_hi, -noise_hi_prev) * 177.0;

        float stamp = sample_noise_2d(stamp_uv * 0.68, time);
        stamp = params.fog_params2.w * (stamp - 0.5) + 0.5; // Contrast
        stamp = mix(1.0, stamp, params.fog_params2.z);
        fog_amount *= max(stamp, 0.25);
    }

    // Final fog calculation with exponential falloff
    float density_sq = params.fog_params.x * params.fog_params.x;
    fog_amount = 1.0 - exp(-fog_amount * density_sq * 2.0);
    fog_amount *= smoothstep(-250.0, params.fog_params.z, world_distance);

    return clamp(fog_amount * 1.77, 0.0, 1.0);
}

// Mie scattering phase function for sun glow in fog
float mie_phase(float cos_theta, float g) {
    float g2 = g * g;
    float num = (1.0 - g2);
    float denom = 4.0 * PI * pow(1.0 + g2 - 2.0 * g * cos_theta, 1.5);
    return num / denom;
}

void main() {
    ivec2 pixel_coords = ivec2(gl_GlobalInvocationID.xy);

    // Bounds check
    if (pixel_coords.x >= int(params.resolution.x) || pixel_coords.y >= int(params.resolution.y)) {
        return;
    }

    vec2 uv = (vec2(pixel_coords) + 0.5) / params.resolution;

    // Sample depth
    float depth = texture(depth_texture, uv).r;

    // Early out for sky (infinite depth)
    // Note: Godot uses reversed-Z by default
    bool is_sky = depth < 0.0001;

    // Get world position and ray direction
    vec3 world_pos = get_world_position(uv, depth);
    vec3 ray_dir = normalize(world_pos - params.camera_position.xyz);
    float world_distance = is_sky ? params.fog_params.w : length(world_pos - params.camera_position.xyz);

    // Calculate fog
    float time = params.camera_position.w;
    float fog_amount = calculate_fog(world_pos, ray_dir, world_distance, time);

    // Apply blend factor for transitions
    fog_amount *= params.blend_factor;

    if (fog_amount > 0.0) {
        // Load original color
        vec4 original_color = imageLoad(color_image, pixel_coords);

        // Calculate fog color with sun scattering
        vec3 fog_col = params.fog_color.rgb;

        // Add Mie scattering for sun glow
        float cos_theta = dot(ray_dir, params.sun_direction.xyz);
        float mie = mie_phase(cos_theta, 0.76); // g = 0.76 for typical atmospheric haze
        fog_col += params.sun_direction.w * mie * vec3(1.0, 0.9, 0.7) * 0.3;

        // Blend fog with scene
        vec3 final_color = mix(original_color.rgb, fog_col, fog_amount);

        // Write result
        imageStore(color_image, pixel_coords, vec4(final_color, original_color.a));
    }
}
