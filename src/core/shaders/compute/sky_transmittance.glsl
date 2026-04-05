#[compute]
#version 450

// Sky Transmittance LUT Compute Shader
// Ported from VAIO (Rafael's Shader Pack) — Bruneton & Neyret 2008.
// Generates a 2D transmittance lookup table for atmospheric scattering.
//
// LUT axes:
//   U (x) = cos(zenith angle) mapped to [0,1] via cosTheta * 0.5 + 0.5
//   V (y) = normalized altitude: (height - planet_surface) / atmosphere_thickness
//
// Output: RGB transmittance (fraction of light surviving the path).
// Consumed by: volumetric fog, godrays, sky inscattering.
//
// Adapted from VAIO's 4-wavelength spectral approach to 3-channel RGB.
// Coordinate system: Godot Y-up (VAIO uses Z-up — all height refs converted).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Output LUT image
layout(rgba16f, set = 0, binding = 0) uniform image2D transmittance_lut;

// Push constants
layout(push_constant, std430) uniform Params {
    vec4 weather_params;    // x = weather_id, y = next_weather_id, z = transition, w = game_hour
    vec2 lut_size;          // width, height of the LUT texture
    float aerosol_turbidity; // base turbidity multiplier
    float _pad;
} params;

// ─── Physical Constants ───

const float PI = 3.14159265359;
const float EARTH_RADIUS = 6371.0;          // km
const float ATMOSPHERE_THICKNESS = 100.0;   // km
const float ATMOSPHERE_RADIUS = EARTH_RADIUS + ATMOSPHERE_THICKNESS;

const int TRANSMITTANCE_STEPS = 32;

// ─── Scattering Coefficients (RGB, wavelengths ~680/550/440 nm) ───

// Rayleigh scattering coefficients at sea level (per km)
const vec3 RAYLEIGH_SCATTER_BASE = vec3(5.802e-3, 13.558e-3, 33.1e-3);
const float RAYLEIGH_SCALE_HEIGHT = 8.0; // km

// Mie scattering (wavelength-independent for small particles)
const float MIE_SCATTER_BASE = 3.996e-3;   // per km at sea level
const float MIE_ABSORB_BASE = 4.4e-4;      // per km at sea level
const float MIE_SCALE_HEIGHT = 1.2;         // km

// Ozone absorption cross section (RGB approximation)
// Peak absorption at ~600nm (R channel), less at shorter wavelengths
const vec3 OZONE_ABSORB = vec3(0.650e-3, 1.881e-3, 0.085e-3);

// ─── Per-Weather Aerosol Density Tables (from VAIO) ───
// Index: 0=Clear, 1=Cloudy, 2=Foggy, 3=Overcast, 4=Rain,
//        5=Thunderstorm, 6=Ashstorm, 7=Blight, 8=Snow, 9=Blizzard

// x = base density multiplier, y = height scale (km)
const vec2 AEROSOL_DENSITIES[10] = vec2[10](
    vec2(1.0,  1.2),   // Clear      — base aerosols
    vec2(1.5,  1.2),   // Cloudy     — slightly more
    vec2(8.0,  2.0),   // Foggy      — heavy low aerosols
    vec2(3.0,  2.0),   // Overcast   — moderate spread
    vec2(6.0,  2.2),   // Rain       — lots of moisture
    vec2(7.0,  2.4),   // Thunder    — heavy turbidity
    vec2(4.0,  2.0),   // Ashstorm   — volcanic particles
    vec2(2.0,  2.0),   // Blight     — reduced visibility
    vec2(3.5,  1.5),   // Snow       — ice crystals
    vec2(5.0,  2.0)    // Blizzard   — heavy whiteout
);

// Per-weather sun spectral tint (RGB). Modifies sun color per weather.
// Ashstorm/Blight dramatically reduce blue channel.
const vec3 SUN_TINTS[10] = vec3[10](
    vec3(1.0,  1.0,  1.0),    // Clear
    vec3(1.0,  1.0,  1.0),    // Cloudy
    vec3(1.0,  1.0,  1.0),    // Foggy
    vec3(0.95, 0.98, 1.0),    // Overcast  — slightly cool
    vec3(0.90, 0.96, 1.0),    // Rain      — cooler
    vec3(0.85, 0.92, 0.98),   // Thunder   — dark
    vec3(0.40, 0.25, 0.05),   // Ashstorm  — warm brown
    vec3(0.90, 0.30, 0.05),   // Blight    — red
    vec3(0.70, 0.80, 1.0),    // Snow      — blue tint
    vec3(0.80, 0.90, 1.0)     // Blizzard  — cool
);

// ─── Weather Interpolation ───

vec2 get_aerosol_density_params() {
    int current = clamp(int(params.weather_params.x), 0, 9);
    int next = clamp(int(params.weather_params.y), 0, 9);
    float t = params.weather_params.z;
    return mix(AEROSOL_DENSITIES[current], AEROSOL_DENSITIES[next], t);
}

vec3 get_sun_tint() {
    int current = clamp(int(params.weather_params.x), 0, 9);
    int next = clamp(int(params.weather_params.y), 0, 9);
    float t = params.weather_params.z;
    return mix(SUN_TINTS[current], SUN_TINTS[next], t);
}

// ─── Atmospheric Density Functions ───

// Rayleigh density at altitude h (km)
float rayleigh_density(float h) {
    return exp(-h / RAYLEIGH_SCALE_HEIGHT);
}

// Mie/aerosol density at altitude h (km), weather-aware
float mie_density(float h, vec2 aerosol_params) {
    float base_mie = exp(-h / MIE_SCALE_HEIGHT);
    float weather_mie = aerosol_params.x * exp(-h / aerosol_params.y);
    return base_mie + weather_mie;
}

// Ozone density at altitude h (km) — peaks around 25 km
float ozone_density(float h) {
    h = max(h, 1e-4);
    float t = log(h) - 3.22261; // peak near 25km
    return exp(-t * t * 5.5556);
}

// ─── Ray-Sphere Intersection ───

float ray_sphere_intersect(vec3 origin, vec3 dir, float radius) {
    float b = dot(origin, dir);
    float c = dot(origin, origin) - radius * radius;
    float discriminant = b * b - c;
    if (discriminant < 0.0) return -1.0;
    return -b + sqrt(discriminant);
}

// ─── Transmittance Integration ───

// Compute optical depth along a ray from origin in direction dir.
// Returns RGB extinction coefficients integrated over the path.
vec3 compute_optical_depth(vec3 origin, vec3 dir, float path_length, vec2 aerosol_params) {
    float step_size = path_length / float(TRANSMITTANCE_STEPS);

    vec3 total_extinction = vec3(0.0);

    for (int i = 0; i < TRANSMITTANCE_STEPS; i++) {
        float t = (float(i) + 0.5) * step_size;
        vec3 sample_pos = origin + dir * t;

        float altitude = max(length(sample_pos) - EARTH_RADIUS, 0.0);

        // Rayleigh scattering (wavelength-dependent)
        float rho_r = rayleigh_density(altitude);
        vec3 sigma_r = RAYLEIGH_SCATTER_BASE * rho_r;

        // Mie scattering + absorption (weather-aware)
        float rho_m = mie_density(altitude, aerosol_params);
        float sigma_m_scatter = MIE_SCATTER_BASE * rho_m * params.aerosol_turbidity;
        float sigma_m_absorb = MIE_ABSORB_BASE * rho_m * params.aerosol_turbidity;
        vec3 sigma_m = vec3(sigma_m_scatter + sigma_m_absorb);

        // Ozone absorption
        float rho_o = ozone_density(altitude);
        vec3 sigma_o = OZONE_ABSORB * rho_o;

        // Total extinction at this sample
        total_extinction += (sigma_r + sigma_m + sigma_o) * step_size;
    }

    return total_extinction;
}

// ─── Entry Point ───

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);

    if (pixel.x >= int(params.lut_size.x) || pixel.y >= int(params.lut_size.y)) {
        return;
    }

    // UV coordinates in the LUT
    vec2 uv = (vec2(pixel) + 0.5) / params.lut_size;

    // Decode LUT axes
    // U → cos(zenith angle): -1 (straight down) to +1 (straight up)
    float cos_theta = uv.x * 2.0 - 1.0;

    // V → normalized altitude: 0 (planet surface) to 1 (top of atmosphere)
    float normalized_altitude = uv.y;
    float altitude = normalized_altitude * ATMOSPHERE_THICKNESS;

    // Ray origin at this altitude (Y-up: height is along Y axis)
    float distance_to_center = EARTH_RADIUS + altitude;
    vec3 ray_origin = vec3(0.0, distance_to_center, 0.0);

    // Ray direction from cos_theta (in the YZ plane for Y-up)
    float sin_theta = sqrt(max(1.0 - cos_theta * cos_theta, 0.0));
    vec3 ray_dir = vec3(0.0, cos_theta, sin_theta);

    // Find path length through atmosphere
    float path_length = ray_sphere_intersect(ray_origin, ray_dir, ATMOSPHERE_RADIUS);
    if (path_length < 0.0) {
        // Below horizon — check if we hit the planet
        imageStore(transmittance_lut, pixel, vec4(0.0, 0.0, 0.0, 1.0));
        return;
    }

    // Check for ground intersection (ray hits planet before leaving atmosphere)
    float ground_dist = ray_sphere_intersect(ray_origin, -ray_dir, EARTH_RADIUS);
    // For downward rays that hit the ground, clamp path
    if (cos_theta < 0.0) {
        float b = dot(ray_origin, ray_dir);
        float c = dot(ray_origin, ray_origin) - EARTH_RADIUS * EARTH_RADIUS;
        float disc = b * b - c;
        if (disc > 0.0) {
            float ground_hit = -b - sqrt(disc);
            if (ground_hit > 0.0) {
                path_length = ground_hit;
            }
        }
    }

    // Get weather-dependent aerosol parameters
    vec2 aerosol_params = get_aerosol_density_params();

    // Integrate optical depth along the ray
    vec3 optical_depth = compute_optical_depth(ray_origin, ray_dir, path_length, aerosol_params);

    // Transmittance = exp(-optical_depth)
    vec3 transmittance = exp(-optical_depth);

    // Apply per-weather sun tint (subtle color shift for ashstorm, blight, etc.)
    vec3 sun_tint = get_sun_tint();
    transmittance *= sun_tint;

    imageStore(transmittance_lut, pixel, vec4(transmittance, 1.0));
}
