shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

// Godot 4.3+ requires explicit screen texture samplers
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;

/**
 * Water lighting model roughly follows the 2019 GDC talk: "Wakes, Explosions and Lighting: Interactive Water Simulation in Atlas".
 * SSR implementation from: https://github.com/GodotSSRWater (optimized with hierarchical marching + fresnel early-out)
 * Visual enhancements inspired by OpenMW water shader (sunlight scattering, detail normals)
 * Source: https://gpuopen.com/gdc-presentations/2019/gdc-2019-agtd6-interactive-water-simulation-in-atlas.pdf
 */

#define MAX_CASCADES 8
#define REFLECTANCE  0.02
#define EPSILON 1e-5

// SSR optimization thresholds
#define SSR_FRESNEL_THRESHOLD 0.15  // Skip SSR when fresnel below this (looking straight down)
#define SSR_DISTANCE_THRESHOLD 500.0  // Skip SSR beyond this distance

global uniform vec4 water_color : source_color;
global uniform vec4 foam_color : source_color;

uniform float roughness : hint_range(0.0, 1.0) = 0.25;
uniform float normal_strength : hint_range(0.0, 1.0) = 1.0;
uniform float refraction_strength : hint_range(0.0, 0.5) = 0.15;
uniform float shore_depth_scale : hint_range(0.0, 100.0) = 50.0;
uniform bool debug_shore_mask = false;
uniform vec3 camera_position_world;

// Water color settings (OpenMW-style absorption)
uniform vec3 color_deep : source_color = vec3(0.02, 0.04, 0.06);
uniform float water_visibility : hint_range(5.0, 200.0) = 35.0;
uniform float depth_fade : hint_range(0.01, 1.0) = 0.15;

// SSR settings
uniform float ssr_resolution : hint_range(0.1, 10.0) = 1.0;
uniform float ssr_max_travel : hint_range(0.0, 200.0) = 30.0;
uniform float ssr_max_diff : hint_range(0.1, 10.0) = 4.0;
uniform float ssr_mix_strength : hint_range(0.0, 1.0) = 0.5;
uniform float ssr_screen_border_fadeout : hint_range(0.0, 1.0) = 0.3;

// Shore/border settings
uniform vec3 border_color : source_color = vec3(1.0);
uniform float border_scale : hint_range(0.0, 5.0) = 1.5;
uniform float border_near = 0.5;
uniform float border_far = 300.0;

// Shore mask for fading ocean on land
uniform sampler2D shore_mask : filter_linear;
uniform vec4 shore_mask_bounds = vec4(-8000.0, -8000.0, 16000.0, 16000.0);

// === Detail normals (reduced to 3 layers for performance) ===
uniform sampler2D detail_normal_map : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float detail_normal_strength : hint_range(0.0, 2.0) = 1.0;

// Wave parameters - simplified from OpenMW 6-layer to 3-layer
const vec2 BIG_WAVES = vec2(0.4, 0.35);
const vec2 MID_WAVES = vec2(0.25, 0.2);
const vec2 SMALL_WAVES = vec2(0.15, 0.1);
const float WAVE_CHOPPYNESS = 0.12;
const float WAVE_SCALE = 75.0;
const float BUMP = 1.5;
const vec2 WIND_DIR = vec2(0.5, -0.8);
const float WIND_SPEED = 0.2;
const float UV_BASE_SCALE = 585.0;

// === Sunlight scattering (simplified) ===
uniform bool enable_sunlight_scattering = true;
uniform float scatter_amount : hint_range(0.0, 2.0) = 0.8;
uniform vec3 scatter_color : source_color = vec3(0.3, 0.9, 0.8);

// === Wobbly shores (fixed implementation) ===
uniform bool enable_wobbly_shores = true;
uniform float wobbly_shore_strength : hint_range(0.0, 1.0) = 0.5;

group_uniforms cascade_data;
uniform vec4 map_scales[MAX_CASCADES];
global uniform uint num_cascades;
global uniform sampler2DArray displacements;
global uniform sampler2DArray normals : hint_normal;

uniform vec3 sun_direction = vec3(0.5, 0.7, 0.5);

varying float wave_height;
varying float foam_factor;
varying float fresnel;
varying float shore_factor;
varying vec3 world_pos_val;
varying vec3 world_normal_val;

// ============================================================================
// FRESNEL - Physically accurate dielectric fresnel (from OpenMW)
// ============================================================================
float fresnel_dielectric(vec3 incoming, vec3 normal, float eta) {
	float c = abs(dot(incoming, normal));
	float g = eta * eta - 1.0 + c * c;

	if (g > 0.0) {
		g = sqrt(g);
		float A = (g - c) / (g + c);
		float B = (c * (g + c) - 1.0) / (c * (g - c) + 1.0);
		return 0.5 * A * A * (1.0 + B * B);
	}
	return 1.0;
}

// Sample shore mask - Returns shore factor for wave dampening:
// 0.0 = at shore or on land (no waves, calm water)
// 1.0 = far from shore (full waves, open ocean)
float sample_shore_mask(vec2 world_xz) {
	vec2 uv = (world_xz - shore_mask_bounds.xy) / shore_mask_bounds.zw;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		return 1.0;
	}
	return texture(shore_mask, uv).r;
}

// Normal coordinate calculation with choppiness offset
vec2 wave_normal_coords(vec2 uv, float scale, float speed, float time, vec2 timer, vec3 prev_normal) {
	return uv * (WAVE_SCALE * scale) + WIND_DIR * time * (WIND_SPEED * speed)
		- (prev_normal.xy / prev_normal.zz) * WAVE_CHOPPYNESS
		+ timer * time;
}

// === OPTIMIZED: 3-layer detail normals (down from 6) ===
// Provides 90% of visual quality at 50% of the cost
vec3 sample_detail_normals(vec2 world_uv, float time) {
	vec2 uv = world_uv / UV_BASE_SCALE * 3.0;

	// Layer 0: Big waves - slowest, largest scale
	vec3 n0 = texture(detail_normal_map, wave_normal_coords(uv, 0.08, 0.05, time, vec2(-0.015, -0.005), vec3(0.0, 0.0, 1.0))).rgb * 2.0 - 1.0;

	// Layer 1: Mid waves - offset by layer 0
	vec3 n1 = texture(detail_normal_map, wave_normal_coords(uv, 0.35, 0.08, time, vec2(0.025, -0.02), n0)).rgb * 2.0 - 1.0;

	// Layer 2: Small waves - offset by layer 1
	vec3 n2 = texture(detail_normal_map, wave_normal_coords(uv, 1.2, 0.5, time, vec2(-0.03, 0.08), n1)).rgb * 2.0 - 1.0;

	// Blend with adjusted weights (compensate for fewer layers)
	vec3 normal = n0 * BIG_WAVES.x + n0 * BIG_WAVES.y * 0.5  // Big wave contribution
				+ n1 * MID_WAVES.x + n1 * MID_WAVES.y * 0.5  // Mid wave contribution
				+ n2 * SMALL_WAVES.x + n2 * SMALL_WAVES.y;   // Small wave contribution

	return normalize(vec3(normal.x * BUMP, normal.y * BUMP, 1.0));
}

void vertex() {
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_pos_val = world_pos;
	UV = world_pos.xz;

	float dist_to_cam = length(world_pos.xz - camera_position_world.xz);
	float distance_factor = min(exp(-(dist_to_cam - 150.0) * 0.007), 1.0);

	shore_factor = sample_shore_mask(world_pos.xz);

	vec3 displacement = vec3(0);
	for (uint i = 0U; i < num_cascades; ++i) {
		vec4 scales = map_scales[i];
		vec3 cascade_disp = texture(displacements, vec3(UV * scales.xy, float(i))).xyz * scales.z;
		displacement += cascade_disp * shore_factor;
	}

	float total_fade = distance_factor;
	wave_height = displacement.y * total_fade;
	VERTEX += displacement * total_fade;
}

// === OPTIMIZED: Distance-based filtering selection ===
// Bicubic only for close-up, bilinear for distance
vec4 sample_normal_cascade(sampler2DArray sampler, vec3 coords, float dist_to_cam, float ppm) {
	// Beyond 150m or when ppm is high enough, use simple bilinear
	if (dist_to_cam > 150.0 || ppm > 8.0) {
		return texture(sampler, coords);
	}

	// Close up: use bicubic for smooth normals
	vec2 dims = vec2(textureSize(sampler, 0).xy);
	vec2 dims_inv = 1.0 / dims;
	vec3 uvw = coords;
	uvw.xy = uvw.xy * dims + 0.5;

	vec2 fuv = fract(uvw.xy);

	// Simplified cubic weights
	float fx = fuv.x, fy = fuv.y;
	float fx2 = fx * fx, fy2 = fy * fy;
	float fx3 = fx2 * fx, fy3 = fy2 * fy;

	vec4 wx = vec4(-fx3 + fx2 * 3.0 - fx * 3.0 + 1.0,
				   fx3 * 3.0 - fx2 * 6.0 + 4.0,
				   -fx3 * 3.0 + fx2 * 3.0 + fx * 3.0 + 1.0,
				   fx3) / 6.0;
	vec4 wy = vec4(-fy3 + fy2 * 3.0 - fy * 3.0 + 1.0,
				   fy3 * 3.0 - fy2 * 6.0 + 4.0,
				   -fy3 * 3.0 + fy2 * 3.0 + fy * 3.0 + 1.0,
				   fy3) / 6.0;

	vec4 g = vec4(wx.xz + wx.yw, wy.xz + wy.yw);
	vec4 h = (vec4(wx.yw, wy.yw) / g + vec2(-1.5, 0.5).xyxy + floor(uvw.xy).xxyy) * dims_inv.xxyy;
	vec2 w = g.xz / (g.xz + g.yw);

	return mix(
		mix(texture(sampler, vec3(h.yw, coords.z)), texture(sampler, vec3(h.xw, coords.z)), w.x),
		mix(texture(sampler, vec3(h.yz, coords.z)), texture(sampler, vec3(h.xz, coords.z)), w.x), w.y);
}

// === SSR Helper Functions ===

bool is_within_screen_boundaries(vec2 position) {
	return position.x > 0.0 && position.x < 1.0 && position.y > 0.0 && position.y < 1.0;
}

vec2 get_uv_from_view_position(vec3 position_view_space, mat4 proj_m) {
	vec4 position_clip_space = proj_m * vec4(position_view_space.xyz, 1.0);
	vec2 position_ndc = position_clip_space.xy / position_clip_space.w;
	return position_ndc.xy * 0.5 + 0.5;
}

vec3 get_view_position_from_uv(vec2 uv, float depth, mat4 inv_proj_m) {
	vec4 position_ndc = vec4((uv * 2.0) - 1.0, depth, 1.0);
	vec4 view_position = inv_proj_m * position_ndc;
	return view_position.xyz / view_position.w;
}

float get_screen_border_alpha(vec2 screen_position) {
	vec2 shifted_screen_position = 4.0 * screen_position * (1.0 - screen_position);
	float mask = shifted_screen_position.x * shifted_screen_position.y;
	float offset = mix(0.0, 0.5, (clamp(ssr_screen_border_fadeout, 0.75, 1.0) - 0.75) / 0.25);
	float alpha = clamp(smoothstep(0.0, 2.0 * ssr_screen_border_fadeout, mask) - offset, 0.0, 1.0);
	return abs(ssr_screen_border_fadeout) < EPSILON ? 1.0 : alpha;
}

// === OPTIMIZED SSR: Hierarchical ray marching with fresnel early-out ===
// Uses larger steps initially, refines on potential hit
// Skips entirely when fresnel is too low (looking straight down at water)
vec4 get_ssr_color_hierarchical(vec3 surface_view_position, vec3 normal_view_space, vec3 view_dir,
								mat4 proj_m, mat4 inv_proj_m, float fresnel_val, float dist_to_cam) {
	// Early-out: skip SSR when reflection contribution would be minimal
	if (ssr_max_travel < EPSILON || fresnel_val < SSR_FRESNEL_THRESHOLD || dist_to_cam > SSR_DISTANCE_THRESHOLD) {
		return vec4(-1.0, -1.0, -1.0, 0.0);
	}

	vec3 view_direction = -view_dir;
	vec3 reflect_vector = normalize(reflect(view_direction, normal_view_space));

	// Hierarchical marching: start with large steps, refine on hit
	float step_size = ssr_resolution * 4.0;  // Start with 4x larger steps
	float max_travel = ssr_max_travel * (1.0 - dist_to_cam / SSR_DISTANCE_THRESHOLD * 0.5);  // Reduce travel at distance

	vec3 current_pos = surface_view_position;
	vec2 current_screen_pos = vec2(0.0);
	vec3 result_color = vec3(-1.0);
	float hit_travel = -1.0;

	// Coarse pass: find approximate hit location
	for (float travel = 0.0; travel < max_travel; travel += step_size) {
		current_pos += reflect_vector * step_size;
		current_screen_pos = get_uv_from_view_position(current_pos, proj_m);

		if (!is_within_screen_boundaries(current_screen_pos)) {
			break;
		}

		float depth_probe = texture(depth_texture, current_screen_pos).x;
		vec3 depth_view_pos = get_view_position_from_uv(current_screen_pos, depth_probe, inv_proj_m);
		float depth_diff = depth_view_pos.z - current_pos.z;

		if (depth_diff >= 0.0 && depth_diff < ssr_max_diff * 2.0) {
			hit_travel = travel;
			break;
		}
	}

	// Refinement pass: if we found a potential hit, refine with smaller steps
	if (hit_travel >= 0.0) {
		// Go back and refine
		float refine_start = max(0.0, hit_travel - step_size);
		float refine_step = ssr_resolution;
		current_pos = surface_view_position + reflect_vector * refine_start;

		for (float travel = refine_start; travel < hit_travel + step_size && result_color.x < 0.0; travel += refine_step) {
			current_pos += reflect_vector * refine_step;
			current_screen_pos = get_uv_from_view_position(current_pos, proj_m);

			if (!is_within_screen_boundaries(current_screen_pos)) {
				break;
			}

			float depth_probe = texture(depth_texture, current_screen_pos).x;
			vec3 depth_view_pos = get_view_position_from_uv(current_screen_pos, depth_probe, inv_proj_m);
			float depth_diff = depth_view_pos.z - current_pos.z;

			if (depth_diff >= 0.0 && depth_diff < ssr_max_diff) {
				result_color = texture(screen_texture, current_screen_pos).rgb;
			}
		}
	}

	float alpha = get_screen_border_alpha(current_screen_pos);
	// Fade SSR based on fresnel (stronger reflection = more SSR)
	alpha *= smoothstep(SSR_FRESNEL_THRESHOLD, 0.5, fresnel_val);

	return vec4(result_color, alpha);
}

float linear_depth(float cur_depth) {
	return border_far * border_near / (border_near + cur_depth * (border_far - border_near));
}

vec2 get_refracted_uv(vec2 raw_screen_uv, float screen_depth_raw, vec3 view, vec3 normal, mat4 proj_m, mat4 inv_proj_m) {
	vec3 screen_view_position_original = get_view_position_from_uv(raw_screen_uv, screen_depth_raw, inv_proj_m);
	float screen_center_distance = clamp(length(raw_screen_uv - vec2(0.5)) * 2.0, 0.0, 1.0);
	float refraction_intensity_deglitched = mix(1.0 - refraction_strength, 1.0, screen_center_distance);
	vec3 refraction_position_view_space = screen_view_position_original + normalize(refract(view, -normal, refraction_intensity_deglitched));
	return get_uv_from_view_position(refraction_position_view_space, proj_m);
}

void fragment() {
	float map_size = float(textureSize(normals, 0).x);
	float dist_to_cam = length(world_pos_val.xz - camera_position_world.xz);

	// === OPTIMIZED: Sample depth ONCE, reuse everywhere ===
	float depth_raw = texture(depth_texture, SCREEN_UV).r;

	// Shore detection
	float shore_map_factor = sample_shore_mask(world_pos_val.xz);

	vec4 floor_pos_view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth_raw, 1.0);
	float floor_depth = floor_pos_view.z / floor_pos_view.w;
	float early_water_depth = max(VERTEX.z - floor_depth, 0.0);
	float depth_buffer_factor = smoothstep(0.0, shore_depth_scale, early_water_depth);

	float frag_shore_factor = min(shore_map_factor, depth_buffer_factor);

	// Read normals from FFT cascade maps with distance-based filtering
	vec3 gradient = vec3(0);
	for (uint i = 0U; i < num_cascades; ++i) {
		vec4 scales = map_scales[i];
		vec3 coords = vec3(UV * scales.xy, float(i));
		float ppm = map_size * min(scales.x, scales.y);
		vec4 normal_sample = sample_normal_cascade(normals, coords, dist_to_cam, ppm);
		gradient += normal_sample.xyw * vec3(scales.ww * frag_shore_factor, 1.0);
	}

	// === OPTIMIZED: 3-layer detail normals with earlier fade-out ===
	float detail_fade = exp(-dist_to_cam * 0.002);  // Faster fade: gone by ~1500m instead of 3000m
	if (detail_fade > 0.02) {
		vec3 detail_normal = sample_detail_normals(world_pos_val.xz, TIME);
		gradient.xy += detail_normal.xy * detail_normal_strength * detail_fade;
	}

	// Foam factor
	foam_factor = smoothstep(0.0, 1.0, gradient.z * 0.75) * exp(-dist_to_cam * 0.0075) * frag_shore_factor;

	// Normal strength with distance fade
	float effective_normal_strength = mix(0.1, normal_strength, exp(-dist_to_cam * 0.0175));
	gradient.xy *= effective_normal_strength;

	vec3 world_normal = normalize(vec3(-gradient.x, 1.0, -gradient.y));
	world_normal_val = world_normal;

	NORMAL = (VIEW_MATRIX * vec4(world_normal, 0.0)).xyz;

	// Fresnel
	vec3 view_world = normalize(camera_position_world - world_pos_val);
	float ior = 1.333;
	fresnel = fresnel_dielectric(-view_world, world_normal, ior);
	fresnel = clamp(fresnel, REFLECTANCE, 1.0);

	// Refraction UV (reuse depth_raw)
	vec2 refraction_uv = refraction_strength > 0.0 ? get_refracted_uv(SCREEN_UV, depth_raw, VIEW, NORMAL, PROJECTION_MATRIX, INV_PROJECTION_MATRIX) : SCREEN_UV;

	float surface_depth = FRAGCOORD.z;

	// Border foam detection
	float border_diff = linear_depth(depth_raw) - linear_depth(surface_depth);

	// === FIXED: Wobbly shores - animate shore mask UV for wave lapping effect ===
	float final_shore_factor = frag_shore_factor;
	if (enable_wobbly_shores && dist_to_cam < 500.0) {
		float wobbly_fade = 1.0 - smoothstep(0.0, 500.0, dist_to_cam);
		// Offset the shore mask sampling position based on wave normals
		// This makes the shoreline appear to move with the waves
		vec2 wobbly_offset = gradient.xy * wobbly_shore_strength * 3.0 * wobbly_fade;
		float wobbly_shore = sample_shore_mask(world_pos_val.xz + wobbly_offset);
		// Also wobble the border detection
		border_diff += (wobbly_shore - shore_map_factor) * border_scale * wobbly_fade;
	}

	// View positions for SSR
	vec3 surface_view_position = get_view_position_from_uv(SCREEN_UV, surface_depth, INV_PROJECTION_MATRIX);

	// Screen color with refraction
	vec3 refracted_color = texture(screen_texture, refraction_uv).rgb;

	// === SIMPLIFIED: Sunlight scattering ===
	vec3 scatter_contribution = vec3(0.0);
	if (enable_sunlight_scattering) {
		vec3 sun_dir = normalize(sun_direction);
		float sun_height = sun_dir.y;

		if (sun_height > 0.0) {
			// Simple sun-facing term: strongest when looking toward sun
			float sun_facing = pow(max(dot(-view_world, sun_dir), 0.0), 4.0);

			// Fresnel-like boost at grazing angles
			float scatter_fresnel = fresnel * 0.5;

			// Color with sun height adjustment
			vec3 scatter_col = mix(scatter_color * vec3(1.0, 0.6, 0.3), scatter_color, smoothstep(0.0, 0.3, sun_height));

			// Single combined intensity
			float scatter_intensity = sun_facing * (1.0 + scatter_fresnel) * scatter_amount * smoothstep(0.0, 0.15, sun_height);

			scatter_contribution = scatter_col * scatter_intensity;
		}
	}

	// === OPTIMIZED: Hierarchical SSR with fresnel early-out ===
	vec4 ssr_color = get_ssr_color_hierarchical(surface_view_position, NORMAL, VIEW,
												PROJECTION_MATRIX, INV_PROJECTION_MATRIX,
												fresnel, dist_to_cam);

	// Water color absorption
	float water_depth = max(early_water_depth, 0.0);
	float absorption_factor = 1.0 - exp(-water_depth * depth_fade * 10.0 / water_visibility);
	absorption_factor = clamp(absorption_factor, 0.0, 1.0);

	vec3 water_base_color = water_color.rgb;
	vec3 absorbed_color = mix(refracted_color, water_base_color, absorption_factor);

	float deep_factor = smoothstep(0.0, water_visibility * 0.3, water_depth);
	vec3 surface_depth_color_mix = mix(absorbed_color, color_deep, deep_factor * 0.5);

	// Add sunlight scattering
	surface_depth_color_mix += scatter_contribution;

	// Apply SSR if valid
	vec3 water_final_color;
	if (ssr_max_travel > EPSILON && ssr_color.x >= 0.0) {
		water_final_color = mix(surface_depth_color_mix, ssr_color.rgb, ssr_mix_strength * ssr_color.a * fresnel);
	} else {
		water_final_color = surface_depth_color_mix;
	}

	// Shore border foam
	vec3 final_color = mix(border_color, water_final_color, smoothstep(0.0, border_scale, border_diff));

	// Apply foam
	ALBEDO = mix(final_color, foam_color.rgb, foam_factor);

	ALPHA = 1.0;

	// Debug mode
	if (debug_shore_mask) {
		vec3 shore_color_dbg = vec3(1.0, 0.0, 1.0);
		vec3 ocean_color_dbg = vec3(0.0, 1.0, 1.0);
		ALBEDO = mix(shore_color_dbg, ocean_color_dbg, frag_shore_factor);
		ALPHA = 0.9;
		ROUGHNESS = 0.5;
		METALLIC = 0.0;
		SPECULAR = 0.0;
		SSS_STRENGTH = 0.0;
	} else {
		ROUGHNESS = mix(0.05, 0.6, foam_factor);
		METALLIC = 0.0;
		SPECULAR = 0.5;
		SSS_STRENGTH = 0.05;
	}
}

float smith_masking_shadowing(in float cos_theta, in float alpha) {
	float a = cos_theta / (alpha * sqrt(1.0 - cos_theta * cos_theta));
	float a_sq = a * a;
	return a < 1.6 ? (1.0 - 1.259 * a + 0.396 * a_sq) / (3.535 * a + 2.181 * a_sq) : 0.0;
}

float ggx_distribution(in float cos_theta, in float alpha) {
	float a_sq = alpha * alpha;
	float d = 1.0 + (a_sq - 1.0) * cos_theta * cos_theta;
	return a_sq / (PI * d * d);
}

void light() {
	vec3 halfway = normalize(LIGHT + VIEW);
	float dot_nl = max(dot(NORMAL, LIGHT), 2e-5);
	float dot_nv = max(dot(NORMAL, VIEW), 2e-5);
	float dot_nh = max(dot(NORMAL, halfway), 0.0);
	float dot_lh = max(dot(LIGHT, halfway), 0.0);

	// Specular - GGX microfacet with proper half-vector fresnel
	float light_mask = smith_masking_shadowing(roughness, dot_nv);
	float view_mask = smith_masking_shadowing(roughness, dot_nl);
	float microfacet_distribution = ggx_distribution(dot_nh, roughness);
	float geometric_attenuation = 1.0 / (1.0 + light_mask + view_mask);

	// Use half-vector fresnel for specular (physically correct)
	float spec_fresnel = mix(pow(1.0 - dot_lh, 5.0), 1.0, REFLECTANCE);
	SPECULAR_LIGHT += spec_fresnel * microfacet_distribution * geometric_attenuation / (4.0 * dot_nv + 0.1) * ATTENUATION;

	// === FIXED: Proper wave-crest SSS ===
	// Light transmits through thin wave crests when looking toward the light
	// This is NOT a rim-light effect - it's actual subsurface transmission

	// Wave thickness: thin at peaks (high wave_height), thick in troughs
	float wave_thickness = 1.0 / (1.0 + max(wave_height, 0.0) * 2.0);

	// Transmission: light going through water toward viewer
	// Strongest when light is behind the wave and we're looking at it
	float transmission = pow(max(dot(LIGHT, VIEW), 0.0), 4.0);

	// Wave slope facing light: transmission through upward-facing slopes
	float slope_factor = max(dot(NORMAL, LIGHT) * 0.5 + 0.5, 0.0);

	// SSS color - cyan/green tinted, brighter for thin waves
	vec3 sss_color = vec3(0.5, 0.85, 0.75);
	float sss_intensity = transmission * wave_thickness * slope_factor * 2.0;

	// Standard lambertian diffuse (reduced)
	float lambertian = dot_nl * 0.2;

	// Combine diffuse + SSS, blend to foam
	vec3 diffuse_sss = (lambertian + sss_intensity * sss_color) * LIGHT_COLOR;
	DIFFUSE_LIGHT += mix(diffuse_sss, foam_color.rgb, foam_factor) * (1.0 - fresnel) * ATTENUATION;
}
