#[compute]
#version 450

// Volumetric ground fog — analytic exponential height layer + raymarched detail.
// Fog model rebuilt 2026-07-06 on the
// UE Exponential Height Fog / iq analytic-fog pattern.
//
// Fog model:
//   density(h) = d0                        for h ≤ base altitude
//              = d0 · exp(-(h − base) · k) for h > base
// integrated in CLOSED FORM along every ray — geometry and sky pixels share one
// code path. Long near-horizontal rays accumulate unbounded optical depth, so
// the horizon closes geometrically: there is no raymarch distance limit, no
// camera-anchored fog wall, and fog is monotonic with distance by construction.
//
// The raymarch survives only for DETAIL: animated noise modulates the analytic
// optical depth over the first "Detail Distance" meters of in-layer travel
// (a user slider, fog_params2.y), and the cloud deck band is integrated
// numerically over the same segment. Both the noise AND the deck fade smoothly
// to nothing over the last stretch of that distance — no hard cutoff line — and
// hand off to the pure analytic layer with no seam. Step count is also a user
// slider (Ray Steps, fog_params2.z).

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

// Camera matrices in a storage buffer (the 128-byte push constant block is full)
layout(std430, set = 0, binding = 5) readonly buffer CameraMatrices {
    mat4 inv_projection;
    mat4 inv_view;
} camera;

// Push constants (128 bytes — exactly the guaranteed Vulkan minimum limit;
// fog_params2.yzw are the only spare slots — beyond that, move fields to the
// storage buffer at binding 5)
layout(push_constant, std430) uniform Params {
    vec4 camera_position;   // xyz = position, w = time
    vec4 fog_color;         // rgb = color, a = master strength (shared weather Fog slider)
    vec4 fog_params;        // x = density d0 (1/m), y = height falloff k (1/m), z = base altitude (m), w = detail amount (0-1)
    vec4 fog_params2;       // x = animation speed, y = detail-march distance (m), z = ray-step count, w = reserved
    vec4 sun_direction;     // xyz = direction, w = sun_intensity
    vec4 weather_params;    // x = weather_id (0-9), y = next_weather_id, z = transition (0-1), w = game_hour (0-24)
    vec4 cloud_params;      // x = deck center altitude (m), y = deck half-thickness (m), z = coverage (0-1), w = density multiplier
    vec2 resolution;
    float blend_factor;
    float has_transmittance;  // 1.0 = transmittance LUT available, 0.0 = use flat fog color
} params;

// ─── Weather Modifier Tables ───
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

// Time-of-day fog adjustment
// Dawn and dusk naturally have more visible fog (low sun angle, moisture)
const float TIME_FOG_MODIFIERS[4] = float[4](
    1.3,   // Pre-sunrise  (5-7h)  — morning mist
    1.0,   // Day          (7-17h) — base
    1.2,   // Sunset       (17-19h) — golden hour haze
    1.1    // Night        (19-5h) — slight increase
);

// ─── Constants ───

const float PI = 3.14159265359;

// Sky rays integrate out to here — far enough that any ray still inside the
// layer saturates to full fog, while rays above the layer converge analytically.
const float SKY_DISTANCE = 1.0e5;

// The in-layer detail-march distance and the ray-step count are user sliders now
// (fog_params2.y / fog_params2.z), not compile-time constants — see march_detail.

// Mean of noise_lo · noise_hi (noise_lo ∈ [0.25, 1], noise_hi ∈ [0, 1]) —
// normalizes the detail modulation factor to average ~1.
const float NOISE_MEAN = 0.3125;

// Cloud deck density slider unit → extinction coefficient (1/m):
// deck density 2.5 ≈ 86% opacity across a 200 m bank.
const float CLOUD_EXTINCTION = 0.004;

// Aerial perspective — applied to SKY pixels ONLY. Near-horizontal sky rays
// saturate the layer to full opacity; without this they paint the fixed white
// fog tint and meet the blue sky above at a hard curtain. Fading sky fog most
// of the way toward the sky behind it turns that into light horizon haze.
// GEOMETRY is deliberately excluded: terrain must stay fogged at every
// distance (height fog has no camera radius), so a distant valley is as misty
// as a near one. The horizon melt for terrain is owned by the engine depth
// fog, which fades geometry toward the sky color.
const float SKY_AERIAL = 0.8;

// exp() argument guard — beyond this the result is already fully saturated
const float EXP_CLAMP = 60.0;

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

// ─── Weather Helpers ───

// Get weather modifier with smooth transition between weather types
float get_weather_modifier(in float[10] modifiers) {
    int current = clamp(int(params.weather_params.x), 0, 9);
    int next = clamp(int(params.weather_params.y), 0, 9);
    float transition = params.weather_params.z;
    return mix(modifiers[current], modifiers[next], transition);
}

// Get time-of-day fog modifier
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
    vec4 view_pos = camera.inv_projection * clip_pos;
    view_pos /= view_pos.w;
    vec4 world_pos = camera.inv_view * view_pos;
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

// Sample 3D noise with wind animation.
// 0.0077 = 0.00011 per-MW-unit noise scale × 70 units/m. The old 0.00018
// was the unit-space value used raw on Godot METERS, so the fog blobs came out
// ~40× too large — a flat, textureless wash that read as a solid curtain.
float sample_noise_3d(vec3 pos, float time) {
    vec3 animated_pos = pos * 0.0077 - vec3(time * params.fog_params2.x * 0.002);
    animated_pos.y *= -1.17;  // Y-up: height axis distortion for noise variation
    return texture(noise_texture, animated_pos).r;
}

// Sample 2D noise for low-frequency variation.
// 0.0084 = 0.00012 per-MW-unit scale × 70 units/m (same unit fix).
float sample_noise_2d(vec2 uv, float time) {
    vec2 animated_uv = uv * 0.0084 - vec2(time * params.fog_params2.x * 0.0021);
    return texture(noise_2d_texture, animated_uv).r;
}

// ─── Analytic Fog Layer ───
// NOTE: Godot is Y-up. The source shader is Z-up — all height references are .y.

// Optical depth of the exponential regime over ray segment [ta, tb].
// Assumes the segment sits at or above the base altitude, so the combined
// exponent -(height(t) - base)·k is ≤ 0 and exp() cannot overflow.
float od_exp_segment(float origin_y, float dir_y, float ta, float tb, float k, float base) {
    float ky = dir_y * k;
    float a = -(origin_y - base) * k;
    if (abs(ky) < 1e-6) {
        return exp(clamp(a, -EXP_CLAMP, 0.0)) * (tb - ta);
    }
    float ea = exp(clamp(a - ky * ta, -EXP_CLAMP, 0.0));
    float eb = exp(clamp(a - ky * tb, -EXP_CLAMP, 0.0));
    return (ea - eb) / ky;
}

// Closed-form optical depth of the fog layer along [0, t] from origin_y.
// A straight ray crosses the base plane at most once, so the path splits into
// a uniform-density segment (below base) and an exponential segment (above).
float analytic_optical_depth(float origin_y, float dir_y, float t, float d0, float k, float base) {
    float end_y = origin_y + dir_y * t;
    float od;
    if (abs(dir_y) < 1e-6) {
        od = (origin_y <= base)
            ? t
            : exp(clamp(-(origin_y - base) * k, -EXP_CLAMP, 0.0)) * t;
    } else if (origin_y <= base && end_y <= base) {
        od = t;  // entirely inside the uniform slab
    } else if (origin_y > base && end_y > base) {
        od = od_exp_segment(origin_y, dir_y, 0.0, t, k, base);  // entirely above
    } else {
        float t_cross = (base - origin_y) / dir_y;
        if (origin_y <= base) {
            // rises out of the uniform slab into the exponential tail
            od = t_cross + od_exp_segment(origin_y, dir_y, t_cross, t, k, base);
        } else {
            // descends from the exponential tail into the uniform slab
            od = od_exp_segment(origin_y, dir_y, 0.0, t_cross, k, base) + (t - t_cross);
        }
    }
    return d0 * od;
}

// Altitude where the layer density becomes negligible (~1%); the cloud deck
// extends it when enabled. Bounds the detail march only — not the fog itself.
float get_layer_top(float k, float base) {
    float top = base + 4.5 / k;
    if (params.cloud_params.y > 0.0 && params.cloud_params.z > 0.0) {
        top = max(top, params.cloud_params.x + params.cloud_params.y);
    }
    return top;
}

// ─── Detail Raymarch ───
// Marches only the in-layer segment of the ray: computes a density-weighted
// noise modulation factor for the analytic fog and integrates the cloud deck
// band numerically. Returns the march end distance (0 when the ray never
// enters the layer); the analytic fog beyond it stays unmodulated.
float march_detail(vec3 origin, vec3 dir, float t_scene, float k, float base,
                   float time, out float modulation, out float cloud_od) {
    modulation = 1.0;
    cloud_od = 0.0;

    // User-driven detail reach + quality (ray-steps multiplier + fog distance).
    float detail_dist = max(params.fog_params2.y, 1.0);
    int ray_steps = max(int(params.fog_params2.z), 1);

    float top = get_layer_top(k, base);

    // In-layer segment [t0, t1]
    float t0 = 0.0;
    if (origin.y > top) {
        if (dir.y > -1e-4) {
            return 0.0;  // above the layer and not descending — no detail
        }
        t0 = (top - origin.y) / dir.y;
    }
    float t1 = min(t_scene, t0 + detail_dist);
    if (origin.y < top && dir.y > 1e-4) {
        t1 = min(t1, (top - origin.y) / dir.y);  // exits through the layer top
    }
    if (t1 <= t0) {
        return 0.0;
    }

    float step_len = (t1 - t0) / float(ray_steps);
    vec3 step_vec = dir * step_len;
    vec3 pos = origin + dir * (t0 + step_len * 0.5);

    bool deck_on = params.cloud_params.y > 0.0 && params.cloud_params.z > 0.0;
    float cov = clamp(params.cloud_params.z, 0.0, 1.0);
    float noise_hi = 0.5;
    float noise_hi_prev = 0.5;
    float noise_lo = 1.0;
    float weighted_noise = 0.0;
    float weight_sum = 0.0;

    for (int i = 0; i < ray_steps; i++) {
        noise_hi_prev = noise_hi;
        noise_hi = sample_noise_3d(pos, time);

        // Low-frequency 2D noise every other step (cheaper)
        if (i % 2 == 0) {
            vec2 uv = pos.xz + vec2(noise_hi, noise_hi_prev) * 27.0;  // XZ plane (Y-up); domain warp ≈27 m (was 1900 MW units)
            noise_lo = 0.25 + 0.75 * sample_noise_2d(uv, time);
        }

        // Fade detail to its mean with in-layer travel: kills far-field noise
        // aliasing and makes the modulation converge to 1 at the march end.
        float in_layer_dist = (float(i) + 0.5) * step_len;
        // Smooth dissolve over the last 40% of the detail distance — the noise
        // AND the cloud deck (below) fade out here instead of ending on a line.
        float edge_fade = 1.0 - smoothstep(detail_dist * 0.6, detail_dist, in_layer_dist);
        float noise = mix(noise_lo * noise_hi, NOISE_MEAN,
                          smoothstep(200.0, detail_dist, in_layer_dist));

        // Weight by layer density so the modulation reflects where fog actually is
        float w = exp(clamp(-(pos.y - base) * k, -EXP_CLAMP, 0.0));
        weighted_noise += noise * w;
        weight_sum += w;

        // Cloud deck — coverage-gated dense noise in an altitude band. Banks
        // cling to relief because geometry depth terminates the ray, so peaks
        // above the band and slopes piercing it poke through.
        if (deck_on) {
            float band = 1.0 - smoothstep(0.0, params.cloud_params.y,
                                          abs(pos.y - params.cloud_params.x));
            if (band > 0.0) {
                float shape = smoothstep(1.0 - cov, min(1.0 - cov + 0.2, 1.0), noise);
                cloud_od += band * shape * params.cloud_params.w * CLOUD_EXTINCTION * step_len * edge_fade;
            }
        }

        pos += step_vec;
    }

    if (weight_sum > 1e-4) {
        float mean_noise = (weighted_noise / weight_sum) / NOISE_MEAN;
        modulation = mix(1.0, mean_noise, clamp(params.fog_params.w, 0.0, 1.0));
    }
    return t1;
}

// ─── Entry Point ───

void main() {
    ivec2 pixel_coords = ivec2(gl_GlobalInvocationID.xy);

    if (pixel_coords.x >= int(params.resolution.x) || pixel_coords.y >= int(params.resolution.y)) {
        return;
    }

    // Master strength (shared weather Fog slider) scales the layer's optical
    // depth — the same semantics as the engine fog density multiplier.
    float strength = params.fog_color.a * params.blend_factor;
    if (strength <= 0.0) {
        return;
    }

    vec2 uv = (vec2(pixel_coords) + 0.5) / params.resolution;

    // Sample depth (Godot uses reversed-Z; ~0 = sky)
    float depth = texture(depth_texture, uv).r;
    bool is_sky = depth < 0.0001;

    // Reconstruct world position
    vec3 cam_pos = params.camera_position.xyz;
    vec3 world_pos = get_world_position(uv, depth);
    vec3 ray_dir = normalize(world_pos - cam_pos);
    float t_scene = is_sky ? SKY_DISTANCE : length(world_pos - cam_pos);

    // Weather-modified layer coefficients
    float d0 = params.fog_params.x * strength
             * get_weather_modifier(FOG_WEATHER_MODIFIERS) * get_time_fog_modifier();
    float k = max(params.fog_params.y, 1e-4)
            / max(get_weather_modifier(FOG_HEIGHT_MODIFIERS), 0.01);
    float base = params.fog_params.z;

    // Detail march over the in-layer segment
    float time = params.camera_position.w;
    float modulation;
    float cloud_od;
    float t_detail = march_detail(cam_pos, ray_dir, t_scene, k, base, time, modulation, cloud_od);

    // Optical depth: noise-modulated up to the march end, pure analytic beyond
    float od_near = analytic_optical_depth(cam_pos.y, ray_dir.y, t_detail, d0, k, base);
    float od_full = analytic_optical_depth(cam_pos.y, ray_dir.y, t_scene, d0, k, base);
    float od = od_near * modulation + max(od_full - od_near, 0.0) + cloud_od * strength;

    float fog_amount = clamp(1.0 - exp(-od), 0.0, 1.0);
    if (fog_amount < 0.002) {
        return;
    }

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
        float cam_alt_km = max(cam_pos.y * 0.001, 0.0);
        sun_transmittance = lookup_transmittance(sun_cos_zenith, cam_alt_km);
    }
    fog_col += params.sun_direction.w * mie * sun_transmittance * 0.3 * scatter_mod;

    // Aerial perspective — sky pixels only (see SKY_AERIAL). Terrain keeps its
    // full fog tint at every distance so ground fog does not read as a puddle
    // around the camera; only the saturated horizon SKY fades toward the sky
    // behind it, softening the curtain into haze.
    if (is_sky) {
        fog_col = mix(fog_col, original_color.rgb, SKY_AERIAL);
    }

    vec3 final_color = mix(original_color.rgb, fog_col, fog_amount);
    imageStore(color_image, pixel_coords, vec4(final_color, original_color.a));
}
