#[compute]
#version 450

// Volumetric Fog Compute Shader — Weather-Aware
// Based on Rafael's VAIO shader for OpenMW, adapted for Godot 4.6 CompositorEffect.
//
// OpenMW Compatibility Reference:
//   omw.eyePos         → params.camera_position.xyz
//   omw.simulationTime → params.camera_position.w
//   omw.sunPos          → params.sun_direction.xyz (normalized)
//   omw.sunColor        → implicit in sun_intensity
//   omw.fogColor        → params.fog_color.rgb
//   omw.weatherID       → int(params.weather_params.x)
//   omw.nextWeatherID   → int(params.weather_params.y)
//   omw.weatherTransition → params.weather_params.z
//   omw.gameHour        → params.weather_params.w
//   omw_GetDepth(uv)    → texture(depth_texture, uv).r
//   omw_GetWorldPosFromUV → get_world_position()

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Input/output images
layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_texture;
layout(set = 0, binding = 2) uniform sampler3D noise_texture;
layout(set = 0, binding = 3) uniform sampler2D noise_2d_texture;
// Sky transmittance LUT (from SkyTransmittanceEffect, Phase 4).
// U = cos(zenith) * 0.5 + 0.5, V = normalized altitude (0=surface, 1=top).
// When available, tints fog scattering with physically-correct atmospheric extinction.
layout(set = 0, binding = 4) uniform sampler2D transmittance_lut;

// Push constants for parameters
layout(push_constant, std430) uniform Params {
    mat4 inv_projection;
    mat4 inv_view;
    vec4 camera_position;   // xyz = position, w = time
    vec4 fog_color;         // rgb = color, a = intensity
    vec4 fog_params;        // x = density, y = height_falloff, z = start_distance, w = end_distance
    vec4 fog_params2;       // x = speed, y = height_based_multiplier, z = stamp_intensity, w = stamp_contrast
    vec4 sun_direction;     // xyz = direction, w = sun_intensity
    vec4 weather_params;    // x = weather_id (0-9), y = next_weather_id, z = transition (0-1), w = game_hour (0-24)
    vec2 resolution;
    float blend_factor;
    float has_transmittance;  // 1.0 = transmittance LUT available, 0.0 = use flat fog color
} params;

// ─── OpenMW Compatibility: Weather Modifier Tables (from VAIO) ───
// These lookup tables drive fog density, exposure, and cloud density per weather type.
// Index: 0=Clear, 1=Cloudy, 2=Foggy, 3=Overcast, 4=Rain, 5=Thunderstorm,
//        6=Ashstorm, 7=Blight, 8=Snow, 9=Blizzard

const float FOG_WEATHER_MODIFIERS[10] = float[10](
    1.00,  // Clear
    1.12,  // Cloudy
    2.30,  // Foggy        — heavy
    1.15,  // Overcast
    1.70,  // Rain
    1.45,  // Thunderstorm
    1.25,  // Ashstorm
    0.80,  // Blight       — less fog, more particles
    1.12,  // Snow
    2.50   // Blizzard     — heaviest
);

const float FOG_HEIGHT_MODIFIERS[10] = float[10](
    1.0,   // Clear        — base height fog
    1.2,   // Cloudy
    3.5,   // Foggy        — thick valley fog
    1.4,   // Overcast
    2.0,   // Rain         — misty valleys
    2.5,   // Thunderstorm — dark valleys
    1.8,   // Ashstorm     — ash settles low
    2.0,   // Blight
    1.5,   // Snow
    3.0    // Blizzard     — whiteout in valleys
);

const float SCATTER_MODIFIERS[10] = float[10](
    1.0,   // Clear        — full sun scatter
    0.7,   // Cloudy       — some diffusion
    0.2,   // Foggy        — sun barely visible
    0.3,   // Overcast     — flat light
    0.3,   // Rain         — grey
    0.15,  // Thunderstorm — dark
    0.1,   // Ashstorm     — sun blocked
    0.05,  // Blight       — sun gone
    0.4,   // Snow         — diffuse
    0.1    // Blizzard     — whiteout
);

// VAIO-style time-of-day fog adjustment
// Dawn and dusk naturally have more visible fog (low sun angle, moisture)
const float TIME_FOG_MODIFIERS[4] = float[4](
    1.3,   // Pre-sunrise  (5-7h)  — morning mist
    1.0,   // Day          (7-17h) — base
    1.2,   // Sunset       (17-19h) — golden hour haze
    1.1    // Night        (19-5h) — slight increase
);

// ─── Constants ───

const int RAY_STEPS = 24;
const float PI = 3.14159265359;

// ─── Sky Transmittance LUT Lookup ───
// Reads atmospheric extinction from the precomputed Bruneton LUT.
// cos_theta: cosine of zenith angle (1.0 = up, -1.0 = down)
// altitude_km: height above sea level in kilometers
// Returns RGB transmittance (0-1, fraction of light surviving the path).
const float ATMOSPHERE_THICKNESS_KM = 100.0;

vec3 lookup_transmittance(float cos_theta, float altitude_km) {
    float u = cos_theta * 0.5 + 0.5;
    float v = clamp(altitude_km / ATMOSPHERE_THICKNESS_KM, 0.0, 1.0);
    return texture(transmittance_lut, vec2(u, v)).rgb;
}

// ─── OpenMW Compat Helpers ───

// Get weather modifier with smooth transition between weather types
float get_weather_modifier(in float[10] modifiers) {
    int current = clamp(int(params.weather_params.x), 0, 9);
    int next = clamp(int(params.weather_params.y), 0, 9);
    float transition = params.weather_params.z;
    return mix(modifiers[current], modifiers[next], transition);
}

// Get time-of-day fog modifier (VAIO-style)
float get_time_fog_modifier() {
    float hour = params.weather_params.w;
    if (hour < 5.0 || hour > 19.0) return TIME_FOG_MODIFIERS[3];       // Night
    if (hour < 7.0) return mix(TIME_FOG_MODIFIERS[3], TIME_FOG_MODIFIERS[0], (hour - 5.0) / 2.0);  // Pre-sunrise
    if (hour < 17.0) return TIME_FOG_MODIFIERS[1];                     // Day
    return mix(TIME_FOG_MODIFIERS[1], TIME_FOG_MODIFIERS[2], (hour - 17.0) / 2.0);  // Sunset
}

// Reconstruct world position from depth
vec3 get_world_position(vec2 uv, float depth) {
    vec4 clip_pos = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 view_pos = params.inv_projection * clip_pos;
    view_pos /= view_pos.w;
    vec4 world_pos = params.inv_view * view_pos;
    return world_pos.xyz;
}

// Mie scattering phase function (Henyey-Greenstein)
float mie_phase(float cos_theta, float g) {
    float g2 = g * g;
    float num = (1.0 - g2);
    float denom = 4.0 * PI * pow(1.0 + g2 - 2.0 * g * cos_theta, 1.5);
    return num / denom;
}

// ─── Noise Sampling ───

// Sample 3D noise with wind animation
float sample_noise_3d(vec3 pos, float time) {
    vec3 animated_pos = pos * 0.00018 - vec3(time * params.fog_params2.x * 0.002);
    animated_pos.y *= -1.17;  // Y-up: height axis distortion for noise variation
    return texture(noise_texture, animated_pos).r;
}

// Sample 2D noise for stamping / low-frequency variation
float sample_noise_2d(vec2 uv, float time) {
    vec2 animated_uv = uv * 0.0002 - vec2(time * params.fog_params2.x * 0.0021);
    return texture(noise_2d_texture, animated_uv).r;
}

// ─── Height Fog ───

// NOTE: Godot is Y-up. OpenMW/VAIO uses Z-up — all height references converted to .y
float get_height_factor(float height, float eye_height) {
    float falloff = params.fog_params.y;
    float height_diff = eye_height - height;

    // Weather-driven height multiplier (foggy/blizzard = thick valleys)
    float height_mod = get_weather_modifier(FOG_HEIGHT_MODIFIERS);

    if (height_diff > 0.0) {
        // Below camera — more fog in valleys
        return mix(1.0, params.fog_params2.y * height_mod, smoothstep(0.0, 3500.0, height_diff));
    } else {
        // Above camera — fog thins with altitude
        return smoothstep(eye_height + 3500.0, eye_height - 500.0, height);
    }
}

// ─── Main Fog Calculation ───

float calculate_fog(vec3 world_pos, vec3 ray_dir, float world_distance, float time) {
    float fog_amount = 0.0;
    float intensity = params.fog_color.a;

    if (intensity <= 0.0 || world_distance <= 0.0) {
        return 0.0;
    }

    // Weather-driven density multiplier
    float weather_fog_mod = get_weather_modifier(FOG_WEATHER_MODIFIERS);
    float time_fog_mod = get_time_fog_modifier();

    // Clamp march distance
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

        // High-frequency 3D noise (animated, per-step)
        noise_hi = sample_noise_3d(ray_pos, time);

        // Distance-based attenuation to prevent far-field aliasing
        noise_hi = mix(noise_hi, 0.5, smoothstep(0.0, 15000.0, ray_length));

        // Low-frequency 2D noise every other step (cheaper)
        if (i % 2 == 0) {
            vec2 uv = ray_pos.xz + vec2(noise_hi, noise_hi_prev) * 1900.0;  // XZ = horizontal plane (Y-up)
            noise_lo = 0.25 + 0.75 * sample_noise_2d(uv, time);
        }

        // Combine noise layers
        float noise = noise_lo * noise_hi;

        // Height-based fog density (weather-aware) — Y-up in Godot
        float height_factor = get_height_factor(ray_pos.y, params.camera_position.y);
        noise *= height_factor;

        ray_pos += ray_step;
        fog_amount += noise;
        ray_length += ray_step_length;
    }

    fog_amount /= float(RAY_STEPS);

    // Distance-based distribution — Y-up in Godot
    vec3 distance_traveled = ray_pos - params.camera_position.xyz;
    if (distance_traveled.y < 0.0) {
        distance_traveled.y *= params.fog_params2.y; // Valley bias
    }
    fog_amount *= sqrt(length(distance_traveled)) * 0.019;

    // Apply weather + time-of-day multipliers
    fog_amount *= weather_fog_mod * time_fog_mod;

    // Stamping: organic texture variation (rolling fog look)
    if (fog_amount > 0.00001 && params.fog_params2.z > 0.0) {
        float wave = sin(time * 0.2);
        vec2 stamp_uv = ray_pos.xz + vec2(wave, -wave) * 200.0 - ray_pos.yy;  // XZ horizontal plane, Y height
        stamp_uv += vec2(noise_hi, -noise_hi_prev) * 177.0;

        float stamp = sample_noise_2d(stamp_uv * 0.68, time);
        stamp = params.fog_params2.w * (stamp - 0.5) + 0.5; // Contrast
        stamp = mix(1.0, stamp, params.fog_params2.z);
        fog_amount *= max(stamp, 0.25);
    }

    // Final exponential density
    float density_sq = params.fog_params.x * params.fog_params.x;
    fog_amount = 1.0 - exp(-fog_amount * density_sq * 2.0);
    fog_amount *= smoothstep(-250.0, params.fog_params.z, world_distance);

    return clamp(fog_amount * 1.77, 0.0, 1.0);
}

// ─── Entry Point ───

void main() {
    ivec2 pixel_coords = ivec2(gl_GlobalInvocationID.xy);

    if (pixel_coords.x >= int(params.resolution.x) || pixel_coords.y >= int(params.resolution.y)) {
        return;
    }

    vec2 uv = (vec2(pixel_coords) + 0.5) / params.resolution;

    // Sample depth (Godot uses reversed-Z)
    float depth = texture(depth_texture, uv).r;
    bool is_sky = depth < 0.0001;

    // Reconstruct world position
    vec3 world_pos = get_world_position(uv, depth);
    vec3 ray_dir = normalize(world_pos - params.camera_position.xyz);
    float world_distance = is_sky ? params.fog_params.w : length(world_pos - params.camera_position.xyz);

    // Calculate fog with weather integration
    float time = params.camera_position.w;
    float fog_amount = calculate_fog(world_pos, ray_dir, world_distance, time);

    // Apply blend factor for enable/disable transitions
    fog_amount *= params.blend_factor;

    if (fog_amount > 0.0) {
        vec4 original_color = imageLoad(color_image, pixel_coords);

        // Fog color with weather-aware sun scattering
        vec3 fog_col = params.fog_color.rgb;
        float scatter_mod = get_weather_modifier(SCATTER_MODIFIERS);
        float cos_theta = dot(ray_dir, params.sun_direction.xyz);
        float mie = mie_phase(cos_theta, 0.76);

        // When transmittance LUT is available, tint the sun scattering
        // with physically-correct atmospheric extinction along the sun path.
        // This gives proper red sunsets, blue-shifted zenith fog, and
        // weather-dependent haze color (ashstorm = brown, blight = red).
        vec3 sun_transmittance = vec3(1.0, 0.9, 0.7); // default warm tint
        if (params.has_transmittance > 0.5) {
            // Sun direction cosine with zenith (Y-up)
            float sun_cos_zenith = params.sun_direction.y;
            // Camera altitude in km (approximate — world units are meters)
            float cam_alt_km = max(params.camera_position.y * 0.001, 0.0);
            sun_transmittance = lookup_transmittance(sun_cos_zenith, cam_alt_km);
        }
        fog_col += params.sun_direction.w * mie * sun_transmittance * 0.3 * scatter_mod;

        vec3 final_color = mix(original_color.rgb, fog_col, fog_amount);
        imageStore(color_image, pixel_coords, vec4(final_color, original_color.a));
    }
}
