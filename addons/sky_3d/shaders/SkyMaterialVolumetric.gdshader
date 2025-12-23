// Copyright (c) 2023-2025 Cory Petkovsek and Contributors
// Copyright (c) 2021 J. Cuellar
// Volumetric cloud integration inspired by Sky++ (Andrey Soldatov)

shader_type sky;
render_mode use_debanding, use_half_res_pass;

// =============================================================================
// UNIFORMS - General
// =============================================================================
group_uniforms general;
uniform bool sky_visible = true;
uniform vec2 color_correction = vec2(0.0, 1.0);
uniform vec4 ground_color: source_color = vec4(0.3, 0.3, 0.3, 1.0);
uniform float horizon_offset = 0.0;

// =============================================================================
// UNIFORMS - Atmosphere
// =============================================================================
group_uniforms atmosphere;
uniform float atm_darkness = 0.5;
uniform float atm_sun_intensity = 18.0;
uniform vec4 atm_day_tint: source_color = vec4(0.808, 0.91, 1.0, 1.0);
uniform vec4 atm_horizon_light_tint: source_color = vec4(0.98, 0.635, 0.463, 1.0);
uniform vec4 atm_night_tint: source_color = vec4 (0.041, 0.049, 0.061, 0.245);
uniform vec3 atm_level_params = vec3(1.0, 0.0, 0.0);
uniform float atm_thickness = 0.7;
uniform vec3 atm_beta_ray = vec3(0.00001, 0.00001, 0.00003);
uniform vec3 atm_beta_mie = vec3(0.00000003038);

// =============================================================================
// UNIFORMS - Sun Disk
// =============================================================================
group_uniforms sun_disk;
uniform vec4 sun_disk_color: source_color = vec4(0.996, 0.541, 0.14, 1.0);
uniform float sun_disk_intensity = 2.0;
uniform float sun_disk_size = 0.015;

// =============================================================================
// UNIFORMS - Sun Mie
// =============================================================================
group_uniforms sun_mie;
uniform vec4 atm_sun_mie_tint: source_color = vec4(1.0);
uniform float atm_sun_mie_intensity = 1.0;
uniform vec3 atm_sun_partial_mie_phase = vec3(0.36, 1.64, 1.6);

// =============================================================================
// UNIFORMS - Moon
// =============================================================================
group_uniforms moon;
uniform vec4 moon_color: source_color = vec4(1.0);
uniform sampler2D moon_texture: source_color, repeat_disable;
uniform vec3 moon_texture_alignment = vec3(7.0, 1.4, 4.8);
uniform bool moon_texture_flip_u;
uniform bool moon_texture_flip_v;
uniform float moon_size = 0.07;

// =============================================================================
// UNIFORMS - Moon Mie
// =============================================================================
group_uniforms moon_mie;
uniform vec4 atm_moon_mie_tint: source_color = vec4(0.137, 0.184, 0.292, 1.0);
uniform float atm_moon_mie_intensity = 0.17152;
uniform vec3 atm_moon_partial_mie_phase = vec3(0.36, 1.64, 1.6);

// =============================================================================
// UNIFORMS - Star Map
// =============================================================================
group_uniforms star_map;
uniform vec4 starmap_color: source_color = vec4(0.71, 0.71, 0.71, 0.855);
uniform sampler2D starmap_texture: source_color;
uniform bool starmap_flip_u = false;
uniform bool starmap_flip_v = false;
uniform vec3 starmap_alignment = vec3(2.68288, -0.25891, 0.40101);
uniform float star_rotation_offset = 9.38899;
uniform float star_rotation = 0.0;
uniform float star_tilt = 0.0;

// =============================================================================
// UNIFORMS - Star Field
// =============================================================================
group_uniforms star_field;
uniform vec4 star_field_color: source_color = vec4(1.0);
uniform sampler2D star_field_texture: source_color;
uniform float star_scintillation = 0.75;
uniform float star_scintillation_speed = 0.01;
uniform sampler2D noise_tex: source_color;

// =============================================================================
// UNIFORMS - Cirrus Clouds (kept from original Sky3D)
// =============================================================================
group_uniforms cirrus_clouds;
uniform bool cirrus_visible = true;
uniform float cirrus_coverage = 0.5;
uniform float cirrus_thickness = 10.0;
uniform float cirrus_absorption = 2.0;
uniform float cirrus_sky_tint_fade = 0.5;
uniform float cirrus_intensity = 10.0;
uniform float cirrus_size = 1.0;
uniform vec2 cirrus_uv = vec2(0.16, 0.11);
uniform vec2 cirrus_position1 = vec2(0.0);
uniform vec2 cirrus_position2 = vec2(0.0);
uniform vec4 cirrus_day_color: source_color = vec4(0.824, 0.875, 1.0, 1.0);
uniform vec4 cirrus_horizon_light_color: source_color = vec4(0.98, 0.43, 0.15, 1.0);
uniform vec4 cirrus_night_color: source_color = vec4(0.09, 0.094, 0.129, 1.0);
uniform sampler2D cirrus_texture;

// =============================================================================
// UNIFORMS - Volumetric Cumulus Clouds (Sky++ inspired)
// =============================================================================
group_uniforms volumetric_clouds;
uniform bool volumetric_clouds_enabled = true;

group_uniforms volumetric_clouds.colors;
uniform vec3 cloud_base_color: source_color = vec3(0.95, 0.95, 1.0);
uniform vec3 cloud_shadow_color: source_color = vec3(0.4, 0.45, 0.55);
uniform vec4 cloud_day_tint: source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 cloud_horizon_tint: source_color = vec4(1.0, 0.85, 0.7, 1.0);
uniform vec4 cloud_night_tint: source_color = vec4(0.12, 0.14, 0.18, 1.0);

group_uniforms volumetric_clouds.density;
uniform float cloud_coverage: hint_range(0.0, 1.0) = 0.35;
uniform float cloud_density_mult: hint_range(0.1, 3.0) = 1.0;
uniform float cloud_smoothness: hint_range(0.0, 0.2) = 0.05;

group_uniforms volumetric_clouds.shape;
uniform float cloud_base_height = 3.0;
uniform float cloud_layer_thickness = 10.0;
uniform float cloud_scale = 0.15;
uniform vec3 cloud_offset = vec3(0.0);
uniform float cloud_detail_strength: hint_range(0.0, 1.0) = 0.2;

group_uniforms volumetric_clouds.raymarching;
uniform int cloud_march_steps: hint_range(8, 64) = 32;
uniform int cloud_light_steps: hint_range(2, 12) = 6;
uniform float cloud_falloff_power: hint_range(0.1, 1.0) = 0.4;
uniform bool cloud_temporal_jitter = false;
uniform float cloud_jitter_amount: hint_range(0.0, 1.0) = 0.5;

group_uniforms volumetric_clouds.lighting;
uniform float cloud_light_strength = 10.0;
uniform float cloud_ambient_strength = 0.35;
uniform float cloud_anisotropy: hint_range(0.0, 0.95) = 0.25;
uniform float cloud_absorption_coeff: hint_range(0.1, 2.0) = 0.7;
uniform float cloud_powder_strength: hint_range(0.0, 1.0) = 0.5;

group_uniforms volumetric_clouds.textures;
uniform bool use_procedural_noise = true;
uniform sampler3D cloud_shape_texture: filter_linear_mipmap, repeat_enable;
uniform sampler3D cloud_detail_texture: filter_linear_mipmap, repeat_enable;
uniform float cloud_shape_scale = 1.0;
uniform float cloud_detail_scale = 2.0;
uniform float cloud_noise_blend = 0.5;

// =============================================================================
// UNIFORMS - Overlays
// =============================================================================
group_uniforms overlays;
uniform bool show_azimuthal_grid = false;
uniform vec4 azimuthal_grid_color : source_color = vec4(.871, .722, .529, 1.);
uniform float azimuthal_grid_rotation_offset = 0.03;
uniform bool show_equatorial_grid = false;
uniform vec4 equatorial_grid_color : source_color = vec4(0., .75, 1., 1.);
uniform float equatorial_grid_rotation_offset = 0.03;

// =============================================================================
// UNIFORMS - Transform Matrices
// =============================================================================
group_uniforms transform_matrices;
uniform mat3 moon_matrix;

// =============================================================================
// INCLUDES AND CONSTANTS
// =============================================================================
#include "Common.gdshaderinc"

const float EPS = 1e-6;

// =============================================================================
// UTILITY FUNCTIONS
// =============================================================================

float hash(vec2 p) {
	return fract(sin(mod(dot(p, vec2(12.9898, 78.233)), 6.283)) * 43758.5453);
}

float hash3(vec3 p) {
	return fract(sin(dot(p, vec3(12.9898, 78.233, 45.164))) * 43758.5453);
}

// =============================================================================
// PROCEDURAL 3D NOISE (for when 3D textures are not available)
// =============================================================================

// Better hash function for 3D positions
vec3 hash33(vec3 p) {
	p = vec3(
		dot(p, vec3(127.1, 311.7, 74.7)),
		dot(p, vec3(269.5, 183.3, 246.1)),
		dot(p, vec3(113.5, 271.9, 124.6))
	);
	return fract(sin(p) * 43758.5453123);
}

float hash31(vec3 p) {
	return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453123);
}

// 3D value noise with proper interpolation
float noise3d(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);

	// Quintic interpolation for smoother results
	vec3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);

	// Hash the 8 corners of the cube
	float n000 = hash31(i + vec3(0.0, 0.0, 0.0));
	float n100 = hash31(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash31(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash31(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash31(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash31(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash31(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash31(i + vec3(1.0, 1.0, 1.0));

	// Trilinear interpolation
	float nx00 = mix(n000, n100, u.x);
	float nx10 = mix(n010, n110, u.x);
	float nx01 = mix(n001, n101, u.x);
	float nx11 = mix(n011, n111, u.x);

	float nxy0 = mix(nx00, nx10, u.y);
	float nxy1 = mix(nx01, nx11, u.y);

	return mix(nxy0, nxy1, u.z);
}

// FBM (Fractal Brownian Motion) for cloud-like shapes
float fbm3d(vec3 p, int octaves) {
	float value = 0.0;
	float amplitude = 0.5;
	float frequency = 1.0;
	float total_amplitude = 0.0;

	for (int i = 0; i < octaves; i++) {
		value += amplitude * noise3d(p * frequency);
		total_amplitude += amplitude;
		amplitude *= 0.5;
		frequency *= 2.0;
	}

	return value / total_amplitude; // Normalize to 0-1 range
}

// Worley noise approximation for cellular patterns
float worley3d(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);

	float min_dist = 1.0;

	for (int z = -1; z <= 1; z++) {
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				vec3 neighbor = vec3(float(x), float(y), float(z));
				vec3 random_offset = hash33(i + neighbor);
				vec3 point = neighbor + random_offset - f;
				float dist = length(point);
				min_dist = min(min_dist, dist);
			}
		}
	}

	return min_dist;
}

// Cloud shape noise - combines FBM and Worley for puffy clouds
float cloud_noise_procedural(vec3 p, float scale) {
	vec3 coord = p * scale;

	// Low frequency FBM for base shape
	float shape = fbm3d(coord * 0.5, 4);

	// Worley for cellular structure (inverted for puffy centers)
	float worley = 1.0 - worley3d(coord * 2.0);

	// Blend: Perlin-Worley combination like Sky++
	float combined = shape * 0.6 + worley * 0.4;

	return combined;
}

// Detail noise for cloud erosion
float cloud_detail_procedural(vec3 p, float scale) {
	vec3 coord = p * scale;

	// Higher frequency FBM
	float detail = fbm3d(coord * 2.0, 3);

	// Add some Worley for fine detail
	float worley = worley3d(coord * 4.0);

	return mix(detail, worley, 0.3);
}

mat3 create_rotation_matrix(vec3 r) {
	float c1 = cos(r.x), s1 = sin(r.x);
	float c2 = cos(r.y), s2 = sin(r.y);
	float c3 = cos(r.z), s3 = sin(r.z);

	mat3 rotX = mat3(
		vec3(1.0, 0.0, 0.0),
		vec3(0.0, c1, -s1),
		vec3(0.0, s1, c1)
	);

	mat3 rotY = mat3(
		vec3(c2, 0.0, s2),
		vec3(0.0, 1.0, 0.0),
		vec3(-s2, 0.0, c2)
	);

	mat3 rotZ = mat3(
		vec3(c3, -s3, 0.0),
		vec3(s3, c3, 0.0),
		vec3(0.0, 0.0, 1.0)
	);

	return rotZ * rotY * rotX;
}

vec2 calc_equirect_uv(vec3 norm) {
	float flipu = starmap_flip_u ? -1.0 : 1.0;
	float flipv = starmap_flip_v ? -1.0 : 1.0;
	float u = flipu * ((atan(norm.y, norm.x) + PI) * INV_TAU);
	float v = -flipv * (acos(norm.z) * INV_PI);
	return vec2(u, v);
}

vec3 sample_moon_texture(vec3 dir) {
	dir = moon_matrix * dir * create_rotation_matrix(moon_texture_alignment);
	dir.x = -dir.x;
	dir.z = -dir.z;
	float flipu = moon_texture_flip_u ? 1.0 : -1.0;
	float flipv = moon_texture_flip_v ? 1.0 : -1.0;
	float u = 0.5 + flipu * atan(dir.z, dir.x) * INV_TAU;
	float v = 0.5 + flipv * asin(dir.y) * INV_PI;
	return texture(moon_texture, vec2(u, v)).rgb;
}

float calc_disk_mask(vec3 norm, vec3 coords, lowp float size) {
	float dist = length(norm - coords);
	return 1.0 - step(size, dist);
}

float simple_sphere_intersect(vec3 ray_dir, vec3 sphere_pos, float radius) {
	vec3 oc = -sphere_pos;
	float b = dot(oc, ray_dir);
	float c = dot(oc, oc) - radius * radius;
	float h = b * b - c;
	float valid = step(0.0, h);
	h = sqrt(max(h, 0.0));
	return mix(-1.0, -b - h, valid);
}

// =============================================================================
// ATMOSPHERE FUNCTIONS
// =============================================================================

vec3 calc_atmospheric_scatter(float sr, float sm, vec2 mu, vec3 mult) {
	vec3 beta_mie = atm_beta_mie;
	vec3 beta_ray = atm_beta_ray * atm_thickness;

	vec3 extc_factor = clamp_rgb_to_unit(exp(-(beta_ray * sr + beta_mie * sm)));

	float extc_ff = mix(clamp_to_unit(atm_thickness * 0.5), 1.0, mult.x);
	vec3 final_extc_factor = mix(1.0 - extc_factor, (1.0 - extc_factor) * extc_factor, extc_ff);
	float rayleigh_phase = calc_rayleigh_phase(mu.x);
	vec3 BRT = beta_ray * rayleigh_phase;
	vec3 BMT = beta_mie * calc_mie_phase(mu.x, atm_sun_partial_mie_phase);
	BMT *= atm_sun_mie_intensity * atm_sun_mie_tint.rgb;

	vec3 BRMT = (BRT + BMT) / (beta_ray + beta_mie);
	vec3 scatter = atm_sun_intensity * (BRMT * final_extc_factor) * atm_day_tint.rgb * mult.y;
	scatter = mix(scatter, scatter * (1.0 - extc_factor), atm_darkness);

	vec3 lcol =  mix(atm_day_tint.rgb, atm_horizon_light_tint.rgb, mult.x);
	vec3 nscatter = (1.0 - extc_factor) * atm_night_tint.rgb;
	nscatter += calc_mie_phase(mu.y, atm_moon_partial_mie_phase) *
		atm_moon_mie_tint.rgb * atm_moon_mie_intensity * 0.005;

	return (scatter * lcol) + nscatter;
}

// =============================================================================
// CIRRUS CLOUD FUNCTIONS (Original Sky3D)
// =============================================================================

float sample_cirrus_noise(vec2 coords) {
	float a = textureLod(cirrus_texture, coords.xy * cirrus_uv + cirrus_position1, 0.0).r;
	float b = textureLod(cirrus_texture, coords.xy * cirrus_uv + cirrus_position2, 0.0).r;
	return ((a + b) * 0.5);
}

float calc_cirrus_density(vec2 p) {
	float d = sample_cirrus_noise(p);
	float c = 1.0 - cirrus_coverage;
	d = d - c;
	return clamp_to_unit(d);
}

vec4 render_cirrus_clouds(vec3 pos) {
	pos.xy = pos.xz / pos.y;
	pos *= cirrus_size;
	float density = calc_cirrus_density(pos.xy);
	float sh = clamp_to_unit(exp(-cirrus_absorption * density));
	float a = clamp_to_unit(density * cirrus_thickness);
	return vec4(vec3(density*sh) * cirrus_intensity, a);
}

// =============================================================================
// VOLUMETRIC CLOUD FUNCTIONS (Sky++ inspired)
// =============================================================================

float henyey_greenstein(float cos_theta, float g) {
	float g2 = g * g;
	return (1.0 - g2) / (4.0 * PI * pow(1.0 + g2 - 2.0 * g * cos_theta, 1.5));
}

// Sample cloud density - uses procedural noise or 3D textures
float take_cloud_sample(vec3 coord) {
	vec3 sample_coord = coord * 0.01 + cloud_offset;

	float shape_sample;
	float noise_sample;

	if (use_procedural_noise) {
		// Procedural 3D noise (no texture needed)
		shape_sample = cloud_noise_procedural(sample_coord, cloud_shape_scale);
		noise_sample = cloud_detail_procedural(sample_coord, cloud_detail_scale);
	} else {
		// Sample from 3D textures
		shape_sample = texture(cloud_shape_texture, sample_coord * cloud_shape_scale).r;
		noise_sample = texture(cloud_detail_texture, sample_coord * cloud_detail_scale).r;
	}

	// Blend shape and noise like Sky++
	float mixed_sample = shape_sample * (1.0 - cloud_noise_blend) + noise_sample * cloud_noise_blend;

	return mixed_sample;
}

// Get detail noise for erosion
float get_detail_noise(vec3 coord) {
	vec3 detail_coord = coord * cloud_detail_scale * 2.0 * 0.01 + cloud_offset * 2.0;

	if (use_procedural_noise) {
		return cloud_detail_procedural(detail_coord, 1.0);
	} else {
		return texture(cloud_detail_texture, detail_coord).r;
	}
}

float sample_cloud_density(vec3 pos, float height_fraction) {
	// Sample the 3D noise
	float sample_value = take_cloud_sample(pos);

	// Height gradient - clouds are denser at bottom, wispy at top
	// Sky++ uses similar height-based falloff
	float height_gradient = smoothstep(0.0, 0.15, height_fraction) * smoothstep(1.0, 0.6, height_fraction);

	// Apply height gradient to sample
	float density = sample_value * height_gradient;

	// Subtract detail for erosion effect (makes edges wispy)
	float detail = get_detail_noise(pos);
	density -= detail * cloud_detail_strength * (1.0 - height_fraction * 0.5);

	// Apply coverage threshold with smooth falloff
	float coverage_threshold = 1.0 - cloud_coverage;
	density = smoothstep(coverage_threshold - cloud_smoothness, coverage_threshold + cloud_smoothness, density);

	return max(density, 0.0);
}

float light_march(vec3 pos, vec3 light_dir, float current_height_fraction) {
	float optical_depth = 0.0;
	float step_size = cloud_layer_thickness / float(cloud_light_steps);

	for (int i = 0; i < cloud_light_steps; i++) {
		vec3 sample_pos = pos + light_dir * float(i + 1) * step_size;

		// Calculate height fraction for this sample
		float height = (float(i + 1) * step_size + current_height_fraction * cloud_layer_thickness) / cloud_layer_thickness;
		height = clamp(height, 0.0, 1.0);

		float density = sample_cloud_density(sample_pos, height);
		optical_depth += density * step_size * cloud_absorption_coeff;
	}

	// Beer's law for light extinction
	float beer = exp(-optical_depth * cloud_density_mult);

	// Powder effect - darkens thin edges, brightens thick clouds
	float powder = 1.0 - exp(-optical_depth * cloud_density_mult * 2.0);
	powder = mix(1.0, powder, cloud_powder_strength);

	return beer * powder;
}

vec4 raymarch_volumetric_clouds(vec3 ray_dir, vec3 sun_dir, vec3 ambient_color, vec2 screen_uv, vec4 angle_mult, float time) {
	// Only render above horizon
	if (ray_dir.y <= 0.02) {
		return vec4(0.0);
	}

	// Normalize ray direction for consistent sampling
	vec3 rd = normalize(ray_dir);

	// Calculate intersection with cloud layer planes
	// We treat clouds as a flat layer at cloud_base_height
	float t_base = cloud_base_height / rd.y;
	float t_top = (cloud_base_height + cloud_layer_thickness) / rd.y;

	// World-space start position on cloud layer base
	vec3 world_start = rd * t_base;

	// Adaptive march distance based on view angle
	float angle_factor = clamp(pow(rd.y, cloud_falloff_power), 0.05, 1.0);
	float march_dist = (t_top - t_base) * angle_factor;
	float step_size = march_dist / float(cloud_march_steps);

	// Temporal jitter to reduce banding (applied to step offset, not position)
	float jitter_offset = 0.0;
	if (cloud_temporal_jitter) {
		jitter_offset = hash(screen_uv + vec2(time * 0.1)) * step_size * cloud_jitter_amount;
	}

	// Phase function for anisotropic scattering
	float cos_theta = dot(rd, sun_dir);
	float phase = henyey_greenstein(cos_theta, cloud_anisotropy);

	// Multi-scattering approximation with second, less focused phase
	float phase2 = henyey_greenstein(cos_theta, cloud_anisotropy * 0.5);
	float combined_phase = mix(phase, phase2, 0.3);

	// Cloud coloring based on time of day
	vec3 cloud_lit_color = mix(
		mix(cloud_base_color * cloud_day_tint.rgb, cloud_base_color * cloud_horizon_tint.rgb, angle_mult.x),
		cloud_base_color * cloud_night_tint.rgb, angle_mult.w
	);
	vec3 cloud_dark_color = mix(
		mix(cloud_shadow_color * cloud_day_tint.rgb, cloud_shadow_color * cloud_horizon_tint.rgb, angle_mult.x),
		cloud_shadow_color * cloud_night_tint.rgb, angle_mult.w
	);

	// Accumulate color and transmittance
	vec3 accumulated_color = vec3(0.0);
	float transmittance = 1.0;

	for (int i = 0; i < cloud_march_steps; i++) {
		if (transmittance < 0.01) break;

		float t = float(i) * step_size + jitter_offset;

		// World-space sample position along the ray
		vec3 world_pos = world_start + rd * t;

		// Use XZ coordinates for cloud sampling (clouds are in a horizontal layer)
		// This makes clouds independent of camera rotation
		vec3 sample_pos = vec3(world_pos.x, world_pos.y - cloud_base_height, world_pos.z);
		sample_pos *= cloud_scale;

		// Height fraction within cloud layer
		float height_fraction = t / march_dist;

		float density = sample_cloud_density(sample_pos, height_fraction);

		if (density > 0.001) {
			// Light marching for shadows
			float light_transmittance = light_march(sample_pos, sun_dir, height_fraction);

			// Calculate direct lighting
			float direct_light = light_transmittance * combined_phase * cloud_light_strength;

			// Ambient lighting (sky contribution)
			float ambient = cloud_ambient_strength * (0.5 + 0.5 * height_fraction); // More ambient at top

			// Total lighting
			float total_light = direct_light + ambient;

			// Color based on lighting
			vec3 cloud_color = mix(cloud_dark_color, cloud_lit_color, light_transmittance * 0.7 + 0.3);
			cloud_color *= total_light;

			// Accumulate with transmittance
			float sample_transmittance = exp(-density * cloud_absorption_coeff * step_size * cloud_density_mult);
			vec3 sample_color = cloud_color * density * (1.0 - sample_transmittance);

			accumulated_color += sample_color * transmittance;
			transmittance *= sample_transmittance;
		}
	}

	float alpha = 1.0 - transmittance;

	// Fade clouds near horizon to prevent hard cutoff
	alpha *= smoothstep(0.02, 0.15, rd.y);

	return vec4(accumulated_color, clamp(alpha, 0.0, 1.0));
}

// =============================================================================
// GRID OVERLAY FUNCTIONS
// =============================================================================

vec4 create_axis_angle_quat(vec3 axis, float angle) {
	float s = sin(angle * 0.5);
	return vec4(axis * s, cos(angle * 0.5));
}

vec3 rotate_vector_by_quat(vec3 v, vec4 q) {
	vec3 t = 2.0 * cross(q.xyz, v);
	return v + q.w * t + cross(q.xyz, t);
}

vec3 align_and_rotate_vector(vec3 dir, vec3 target, float rotation_angle) {
	vec3 z_axis = vec3(0.0, 0.0, 1.0);
	target = normalize(target);
	vec3 axis = cross(z_axis, target);
	float angle = acos(dot(z_axis, target));
	float valid = step(0.0001, length(axis));
	axis = normalize(axis);
	vec4 align_quat = create_axis_angle_quat(axis, angle);
	dir = mix(dir, rotate_vector_by_quat(dir, align_quat), valid);
	vec4 rot_quat = create_axis_angle_quat(vec3(0.0, 0.0, 1.0), rotation_angle);
	dir = mix(dir, rotate_vector_by_quat(dir, rot_quat), valid);
	return dir;
}

void render_grid(vec3 dir, vec3 pole_dir, float rotation_angle, vec4 line_color, float grid_spacing, float line_thickness, inout vec3 color) {
	float spacing = max(grid_spacing, 0.001);
	float thickness = max(line_thickness, 0.0001);

	dir = align_and_rotate_vector(dir, pole_dir, rotation_angle);

	float theta = acos(dir.z);
	float theta_deriv = fwidth(theta);
	float circle_thickness = max(thickness, theta_deriv);
	float circle = mod(theta, spacing);
	float circle_line = 1.0 - smoothstep(0.0, circle_thickness * 1.5, abs(circle - circle_thickness * 0.5));
	circle_line *= clamp_to_unit(thickness / circle_thickness);

	float pole_thickness = circle_thickness;
	float north_pole = 1.0 - smoothstep(0.0, pole_thickness, theta);
	float south_pole = 1.0 - smoothstep(0.0, pole_thickness, abs(theta - PI));
	circle_line = max(circle_line, max(north_pole, south_pole));

	float circle_adjust = sin(theta);
	circle_line *= clamp(circle_adjust, 0.2, 1.0);

	float phi = atan(dir.y, dir.x);
	float phi_deriv = fwidth(phi);
	float radial_thickness = max(thickness, phi_deriv);
	float radial = mod(phi + PI, spacing);
	float radial_line = 1.0 - smoothstep(0.0, radial_thickness * 1.5, abs(radial - radial_thickness));
	radial_line *= clamp_to_unit(thickness / radial_thickness);

	float grid = max(radial_line, circle_line);
	color += line_color.rgb * line_color.a * grid;
}

// =============================================================================
// MAIN SKY RENDERING
// =============================================================================

vec3 render_sky(vec3 world_pos, vec3 clouds_pos, vec3 sun_pos, vec3 moon_pos, float p_time) {
	vec3 col = vec3(0.0);

	vec4 angle_mult;
	angle_mult.x = clamp_to_unit(1.0 - sun_pos.y);
	angle_mult.y = clamp_to_unit(sun_pos.y + 0.45);
	angle_mult.z = clamp_to_unit(-sun_pos.y + 0.30);
	angle_mult.w = clamp_to_unit(-sun_pos.y + 0.60);

	// Atmosphere
	vec2 mu = vec2(dot(sun_pos, world_pos), dot(moon_pos, world_pos));
	float sr, sm;
	calc_simple_optical_depth(world_pos.y + atm_level_params.z - horizon_offset, sr, sm, atm_level_params.xy);

	world_pos.y -= horizon_offset;
	float horizonBlend = clamp_to_unit((world_pos.y - 0.03) * 3.0);

	vec3 scatter = calc_atmospheric_scatter(sr, sm, mu.xy, angle_mult.xyz);
	col.rgb += scatter.rgb;

	// Sun
	vec3 sun_disk = calc_disk_mask(world_pos, sun_pos, sun_disk_size) * sun_disk_color.rgb * scatter.rgb;
	sun_disk *= sun_disk_intensity;

	// Moon
	float moon_intersect = simple_sphere_intersect(world_pos, moon_pos, moon_size);
	float moon_mask = moon_intersect > (-1. + sqrt(moon_size)) ? 1.0 : 0.0;
	vec3 moon_normal = normalize(world_pos * moon_intersect - moon_pos);

	float moon_ndotl = clamp(dot(moon_normal, sun_pos), 0.0, 1.0);
	vec3 moon_tex = sample_moon_texture(moon_normal);
	vec3 moon_output = moon_mask * moon_ndotl * exp2(1.0) * moon_tex * moon_color.rgb;
	float moonMask = (1.0 - moon_mask);

	// Deep space
	mat3 tilt = create_rotation_matrix(vec3(star_tilt, 0.0, 0.0));
	mat3 rotation = create_rotation_matrix(vec3(0.0, star_rotation + star_rotation_offset, 0.0));
	mat3 alignment_xyz = create_rotation_matrix(starmap_alignment);
	vec3 final_alignment = normalize(alignment_xyz * rotation * tilt * world_pos);
	vec2 deep_space_uv = calc_equirect_uv(normalize(final_alignment));

	// Star map
	vec3 deep_space_background = textureLod(starmap_texture, deep_space_uv, 0.0).rgb;
	deep_space_background *= starmap_color.rgb;
	deep_space_background = adjust_contrast(deep_space_background, starmap_color.a);
	vec3 deep_space = deep_space_background.rgb * moonMask + moon_output;

	// Star Field
	float star_scint = textureLod(noise_tex, deep_space_uv + (p_time * star_scintillation_speed), 0.0).r;
	star_scint = mix(1.0, star_scint * 1.5, star_scintillation);

	vec3 star_field = textureLod(star_field_texture, deep_space_uv, 0.0).rgb * star_field_color.rgb;
	star_field = clamp_rgb_to_unit(mix(star_field.rgb, star_field.rgb * star_scint, star_scintillation));
	star_field = clamp_rgb_to_unit(star_field.rgb);
	deep_space.rgb += star_field.rgb * moonMask;
	deep_space.rgb *= angle_mult.z;
	col.rgb += sun_disk.rgb + deep_space.rgb * horizonBlend;

	// Cirrus Clouds (high altitude, 2D)
	if (cirrus_visible) {
		vec4 cirrus_clouds = render_cirrus_clouds(clouds_pos);
		cirrus_clouds.a = clamp_to_unit(cirrus_clouds.a);
		cirrus_clouds.rgb *= mix(mix(cirrus_day_color.rgb, cirrus_horizon_light_color.rgb, angle_mult.x), cirrus_night_color.rgb, angle_mult.w);

		cirrus_clouds.a = mix(0.0, cirrus_clouds.a, horizonBlend);
		col.rgb = mix(col.rgb, cirrus_clouds.rgb + mix(vec3(0.0), scatter, cirrus_sky_tint_fade), cirrus_clouds.a);
	}

	// Ground color below horizon
	col.rgb = mix(col.rgb, ground_color.rgb * scatter, clamp_to_unit((-world_pos.y - atm_level_params.z) * 100.0));
	col.rgb = apply_photo_tonemap(col.rgb, color_correction.y, color_correction.x);
	return col;
}

// =============================================================================
// SKY SHADER ENTRY POINT
// =============================================================================

void sky() {
	float current_time = TIME;
	vec3 col = vec3(0.0);
	vec3 world_pos = EYEDIR;
	vec3 clouds_pos = EYEDIR;
	vec3 sun_pos = LIGHT0_DIRECTION;
	vec3 moon_pos = LIGHT1_DIRECTION;

	// Half resolution pass: render volumetric clouds
	if (AT_HALF_RES_PASS) {
		COLOR = vec3(0.0);
		ALPHA = 0.0;

		if (volumetric_clouds_enabled && EYEDIR.y > 0.0) {
			vec4 angle_mult;
			angle_mult.x = clamp_to_unit(1.0 - sun_pos.y);
			angle_mult.y = clamp_to_unit(sun_pos.y + 0.45);
			angle_mult.z = clamp_to_unit(-sun_pos.y + 0.30);
			angle_mult.w = clamp_to_unit(-sun_pos.y + 0.60);

			// Get ambient color from atmosphere
			vec2 mu = vec2(dot(sun_pos, EYEDIR), dot(moon_pos, EYEDIR));
			float sr, sm;
			calc_simple_optical_depth(EYEDIR.y + atm_level_params.z, sr, sm, atm_level_params.xy);
			vec3 ambient = calc_atmospheric_scatter(sr, sm, mu.xy, angle_mult.xyz);

			vec4 clouds = raymarch_volumetric_clouds(EYEDIR, sun_pos, ambient, SKY_COORDS, angle_mult, current_time);
			COLOR = clouds.rgb;
			ALPHA = clouds.a;
		}
	} else {
		// Full resolution pass: render everything else
		if (sky_visible) {
			col = render_sky(world_pos, clouds_pos, sun_pos, moon_pos, current_time);
		}

		// Composite volumetric clouds from half-res pass
		if (volumetric_clouds_enabled) {
			vec4 clouds = HALF_RES_COLOR;
			col = mix(col, col * (1.0 - clouds.a * 0.3) + clouds.rgb, clouds.a);
		}

		// Draw overlay grids
		{
			float grid_thickness = 0.0002;
			float grid_spacing = 0.261799;
			vec3 zenith_dir = vec3(0.0, 1.0, 0.0);
			vec3 north_celestial_pole = create_rotation_matrix(vec3(star_tilt, 0.0, 0.0)) * zenith_dir;
			float rotation_angle = star_rotation + star_rotation_offset;
			if (show_azimuthal_grid) {
				render_grid(EYEDIR, zenith_dir, azimuthal_grid_rotation_offset, azimuthal_grid_color, grid_spacing, grid_thickness, col);
			}
			if (show_equatorial_grid) {
				render_grid(EYEDIR, north_celestial_pole, rotation_angle + equatorial_grid_rotation_offset, equatorial_grid_color, grid_spacing, grid_thickness, col);
			}
		}

		COLOR = col.rgb;
	}
}
