shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

/**
 * Ocean shader with FFT wave displacement + OpenMW-style visual rendering
 *
 * FFT Waves: From GodotOceanWaves (displacement + normals from compute shader)
 * Visual Style: Ported from OpenMW water.frag (scattering, fresnel, colors)
 *
 * Performance optimizations:
 * - No detail normal layers (FFT provides all detail)
 * - SSR disabled by default (use environment reflections)
 * - Single depth sample, cached and reused
 * - Bilinear filtering only (bicubic removed)
 */

#define MAX_CASCADES 3
#define REFLECTANCE 0.02

// Screen textures
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;

// ============================================================================
// WATER COLORS - OpenMW style
// ============================================================================
// OpenMW: WATER_COLOR = vec3(0.090195, 0.115685, 0.12745)
global uniform vec4 water_color : source_color;
global uniform vec4 foam_color : source_color;
uniform vec3 color_deep : source_color = vec3(0.02, 0.04, 0.06);

// ============================================================================
// WAVE PARAMETERS - From FFT compute shader
// ============================================================================
group_uniforms cascade_data;
uniform vec4 map_scales[MAX_CASCADES];
global uniform uint num_cascades;
global uniform sampler2DArray displacements;
global uniform sampler2DArray normals : hint_normal;

// ============================================================================
// VISUAL SETTINGS
// ============================================================================
// Unit conversion: 1 Morrowind unit ≈ 0.0138 meters (22.1 units = 1 foot)
// So: MW_value * 0.0138 = meters

uniform float roughness : hint_range(0.0, 1.0) = 0.05;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform float refraction_strength : hint_range(0.0, 0.2) = 0.07;  // OpenMW REFR_BUMP

// Depth/visibility - OpenMW VISIBILITY = 2500 MW ≈ 34.5m
uniform float water_visibility : hint_range(1.0, 100.0) = 34.5;
// OpenMW DEPTH_FADE = 0.15, but that's tuned for MW units
// For meters, we need stronger absorption: depth_fade / 0.0138 ≈ 10.9
uniform float depth_fade : hint_range(0.1, 20.0) = 10.0;

// Shore settings - OpenMW BUMP_SUPPRESS_DEPTH = 300 MW ≈ 4.1m
uniform float shore_depth_scale : hint_range(0.0, 20.0) = 4.0;
uniform sampler2D shore_mask : filter_linear;
uniform vec4 shore_mask_bounds = vec4(-8000.0, -8000.0, 16000.0, 16000.0);

// ============================================================================
// SUNLIGHT SCATTERING - OpenMW style
// ============================================================================
uniform bool enable_sunlight_scattering = true;
uniform float scatter_amount : hint_range(0.0, 1.0) = 0.3;  // OpenMW SCATTER_AMOUNT = 0.3
uniform vec3 scatter_color : source_color = vec3(0.0, 1.0, 0.95);  // OpenMW SCATTER_COLOUR
uniform vec3 sun_extinction : source_color = vec3(0.45, 0.55, 0.68);  // OpenMW SUN_EXT
uniform vec3 sun_direction = vec3(0.5, 0.7, 0.5);
uniform float sun_fade : hint_range(0.0, 1.0) = 1.0;  // Ambient light level

// ============================================================================
// RAIN RIPPLES - OpenMW style
// ============================================================================
uniform bool enable_rain_ripples = false;
uniform float rain_intensity : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D ripple_map : filter_linear, repeat_enable;

// ============================================================================
// WOBBLY SHORES - OpenMW style
// ============================================================================
uniform bool enable_wobbly_shores = true;
// OpenMW WOBBLY_SHORE_FADE_DISTANCE = 6200 MW ≈ 85m
uniform float wobbly_shore_fade_distance = 85.0;

// ============================================================================
// SSR (optional - disabled by default for performance)
// ============================================================================
uniform bool enable_ssr = false;
uniform float ssr_max_travel : hint_range(0.0, 100.0) = 30.0;
uniform float ssr_step_size : hint_range(0.5, 5.0) = 2.0;
uniform float ssr_max_diff : hint_range(0.1, 5.0) = 2.0;

// Camera position for distance calculations
uniform vec3 camera_position_world;

// ============================================================================
// VARYINGS
// ============================================================================
varying float v_wave_height;
varying float v_foam_factor;
varying vec3 v_world_pos;
varying vec3 v_displacement;
varying float v_shore_factor;

// ============================================================================
// FRESNEL - Physically accurate dielectric (from OpenMW)
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
	return 1.0;  // Total internal reflection
}

// ============================================================================
// SHORE MASK SAMPLING
// ============================================================================
float sample_shore_mask(vec2 world_xz) {
	vec2 uv = (world_xz - shore_mask_bounds.xy) / shore_mask_bounds.zw;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		return 1.0;  // Outside bounds = open ocean
	}
	return texture(shore_mask, uv).r;
}

// ============================================================================
// RAIN RIPPLES - Procedural (from OpenMW rain_ripples.glsl)
// ============================================================================
vec4 rain_ripple(vec2 uv, float time, vec2 seed) {
	// Simple procedural ripple based on distance from random centers
	vec2 p = fract(uv * 4.0 + seed) - 0.5;
	float d = length(p);
	float ripple_time = fract(time * 0.5 + seed.x * 0.3);
	float ring = smoothstep(0.0, 0.1, ripple_time) * smoothstep(0.5, 0.3, ripple_time);
	float ripple = sin((d - ripple_time * 0.5) * 40.0) * ring * smoothstep(0.4, 0.0, d);
	return vec4(p * ripple * 2.0, 0.0, abs(ripple));
}

vec4 rain_combined(vec2 uv, float time) {
	vec4 r1 = rain_ripple(uv, time, vec2(0.0, 0.0));
	vec4 r2 = rain_ripple(uv * 1.3, time * 1.1, vec2(0.3, 0.7));
	vec4 r3 = rain_ripple(uv * 0.8, time * 0.9, vec2(0.6, 0.2));
	return (r1 + r2 + r3) / 3.0;
}

// ============================================================================
// VERTEX SHADER
// ============================================================================
void vertex() {
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_pos = world_pos;
	UV = world_pos.xz;

	// Distance-based displacement fade (prevents popping at LOD boundaries)
	float dist_to_cam = length(world_pos.xz - camera_position_world.xz);
	float distance_fade = min(exp(-(dist_to_cam - 150.0) * 0.007), 1.0);

	// Shore factor for wave dampening
	v_shore_factor = sample_shore_mask(world_pos.xz);

	// Sample FFT displacement from all cascades
	vec3 displacement = vec3(0.0);
	for (uint i = 0U; i < num_cascades; ++i) {
		vec4 scales = map_scales[i];
		vec3 cascade_disp = texture(displacements, vec3(UV * scales.xy, float(i))).xyz * scales.z;
		displacement += cascade_disp * v_shore_factor;
	}

	v_displacement = displacement;
	v_wave_height = displacement.y * distance_fade;
	VERTEX += displacement * distance_fade;
}

// ============================================================================
// SIMPLE SSR (optional, low-cost version)
// ============================================================================
vec3 simple_ssr(vec3 view_pos, vec3 reflect_dir, mat4 proj_m) {
	if (!enable_ssr) return vec3(-1.0);

	vec3 current_pos = view_pos;
	for (float travel = 0.0; travel < ssr_max_travel; travel += ssr_step_size) {
		current_pos += reflect_dir * ssr_step_size;

		// Project to screen
		vec4 clip_pos = proj_m * vec4(current_pos, 1.0);
		vec2 screen_uv = (clip_pos.xy / clip_pos.w) * 0.5 + 0.5;

		// Check bounds
		if (screen_uv.x < 0.0 || screen_uv.x > 1.0 || screen_uv.y < 0.0 || screen_uv.y > 1.0) {
			break;
		}

		// Sample depth
		float sampled_depth = texture(depth_texture, screen_uv).x;
		vec4 depth_ndc = vec4(screen_uv * 2.0 - 1.0, sampled_depth, 1.0);
		vec4 depth_view = inverse(proj_m) * depth_ndc;
		float scene_z = depth_view.z / depth_view.w;

		// Check hit
		float diff = scene_z - current_pos.z;
		if (diff >= 0.0 && diff < ssr_max_diff) {
			// Fade at screen edges
			vec2 edge_fade = smoothstep(0.0, 0.1, screen_uv) * smoothstep(1.0, 0.9, screen_uv);
			float alpha = edge_fade.x * edge_fade.y;
			return texture(screen_texture, screen_uv).rgb * alpha + vec3(-1.0) * (1.0 - alpha);
		}
	}
	return vec3(-1.0);
}

// ============================================================================
// FRAGMENT SHADER
// ============================================================================
void fragment() {
	float dist_to_cam = length(v_world_pos.xz - camera_position_world.xz);
	float linear_dist = length(v_world_pos - camera_position_world);

	// === SINGLE DEPTH SAMPLE (cached) ===
	float depth_raw = texture(depth_texture, SCREEN_UV).r;

	// Reconstruct floor position
	vec4 floor_ndc = vec4(SCREEN_UV * 2.0 - 1.0, depth_raw, 1.0);
	vec4 floor_view = INV_PROJECTION_MATRIX * floor_ndc;
	float floor_depth = floor_view.z / floor_view.w;
	float water_depth = max(VERTEX.z - floor_depth, 0.0);

	// === SHORE FACTOR ===
	float shore_map_factor = sample_shore_mask(v_world_pos.xz);
	float depth_shore_factor = smoothstep(0.0, shore_depth_scale, water_depth);
	float shore_factor = min(shore_map_factor, depth_shore_factor);

	// === NORMALS FROM FFT (no detail layers needed) ===
	vec3 gradient = vec3(0.0);
	for (uint i = 0U; i < num_cascades; ++i) {
		vec4 scales = map_scales[i];
		vec3 coords = vec3(UV * scales.xy, float(i));
		vec4 normal_sample = texture(normals, coords);
		gradient += normal_sample.xyw * vec3(scales.ww * shore_factor, 1.0);
	}

	// === RAIN RIPPLES (OpenMW style) ===
	vec3 ripple_add = vec3(0.0);
	float rain_specular = 0.0;
	if (enable_rain_ripples && rain_intensity > 0.01) {
		vec4 rain = rain_combined(v_world_pos.xz / 1000.0, TIME) * rain_intensity;
		ripple_add = rain.xyz * 10.0;
		rain_specular = abs(rain.w) * 0.5;

		// Rain makes waves choppier (OpenMW MID_WAVES_RAIN, SMALL_WAVES_RAIN)
		gradient.xy *= mix(1.0, 1.5, rain_intensity);
	}
	gradient.xy += ripple_add.xy;

	// === FOAM FACTOR ===
	v_foam_factor = smoothstep(0.0, 1.0, gradient.z * 0.75) * exp(-dist_to_cam * 0.0075) * shore_factor;

	// === WORLD NORMAL ===
	// Normal strength fades with distance
	float effective_normal_strength = mix(0.015, normal_strength, exp(-dist_to_cam * 0.0175));
	float bump = mix(0.5, 1.5, rain_intensity);  // OpenMW BUMP/BUMP_RAIN
	gradient.xy *= effective_normal_strength * bump;

	vec3 world_normal = normalize(vec3(-gradient.x, 1.0, -gradient.y));
	NORMAL = (VIEW_MATRIX * vec4(world_normal, 0.0)).xyz;

	// === FRESNEL ===
	vec3 view_world = normalize(camera_position_world - v_world_pos);
	float ior = 1.333;  // Water
	float fresnel = fresnel_dielectric(-view_world, world_normal, ior);
	fresnel = clamp(fresnel, REFLECTANCE, 1.0);

	// === REFRACTION ===
	// OpenMW: suppress bump at shores to prevent artifacts
	// BUMP_SUPPRESS_DEPTH = 300 MW ≈ 4m (now using shore_depth_scale)
	vec2 refr_offset = world_normal.xz * refraction_strength;
	refr_offset *= clamp(water_depth / shore_depth_scale, 0.0, 1.0);
	vec2 refraction_uv = SCREEN_UV - refr_offset;

	// Clamp to screen
	refraction_uv = clamp(refraction_uv, vec2(0.001), vec2(0.999));

	vec3 refracted_color = texture(screen_texture, refraction_uv).rgb;

	// === WATER COLOR WITH DEPTH ABSORPTION (OpenMW style) ===
	// OpenMW formula: factor = DEPTH_FADE² / (-0.5*correction + 0.5 - depth/VISIBILITY) + 0.5*correction + 0.5
	// where correction = sqrt(1 + 4*DEPTH_FADE²)
	// This gives a nice S-curve that transitions more gradually
	vec3 water_col = water_color.rgb * sun_fade;

	float depth_correction = sqrt(1.0 + 4.0 * depth_fade * depth_fade);
	float depth_factor = depth_fade * depth_fade /
		(-0.5 * depth_correction + 0.5 - water_depth / water_visibility)
		+ 0.5 * depth_correction + 0.5;
	depth_factor = clamp(depth_factor, 0.0, 1.0);

	vec3 underwater_color = mix(refracted_color, water_col, depth_factor);

	// Deep water gets darker - transition starts around half visibility distance
	float deep_factor = smoothstep(water_visibility * 0.3, water_visibility, water_depth);
	underwater_color = mix(underwater_color, color_deep, deep_factor * 0.6);

	// === SUNLIGHT SCATTERING (OpenMW style) ===
	vec3 scatter_contribution = vec3(0.0);
	if (enable_sunlight_scattering) {
		vec3 sun_dir = normalize(sun_direction);
		float sun_height = sun_dir.y;

		if (sun_height > 0.0) {
			// Scatter color adjusts with sun height (redder at sunset)
			vec3 scatter_col = mix(scatter_color * vec3(1.0, 0.4, 0.0), scatter_color,
								   max(1.0 - exp(-sun_height * sun_extinction), vec3(0.0)));

			// OpenMW scatter formula:
			// scatterLambert = max(dot(sunDir, scatterNormal) * 0.7 + 0.3, 0.0)
			// scatterReflectAngle = max(dot(reflect(sunDir, scatterNormal), viewDir) * 2.0 - 1.2, 0.0)
			float scatter_lambert = max(dot(sun_dir, world_normal) * 0.7 + 0.3, 0.0);
			float scatter_reflect = max(dot(reflect(sun_dir, world_normal), -view_world) * 2.0 - 1.2, 0.0);

			float light_scatter = scatter_lambert * scatter_reflect * scatter_amount * sun_fade
								  * max(1.0 - exp(-sun_height), 0.0);

			scatter_contribution = scatter_col * light_scatter;
		}
	}

	// Apply scattering to refracted color
	underwater_color = mix(underwater_color, scatter_contribution, length(scatter_contribution) * 0.5);

	// === REFLECTION ===
	vec3 reflection_color = vec3(0.0);

	// Try SSR if enabled (expensive, off by default)
	if (enable_ssr && dist_to_cam < 200.0) {
		vec3 view_pos = (VIEW_MATRIX * vec4(v_world_pos, 1.0)).xyz;
		vec3 reflect_dir = normalize(reflect(-VIEW, NORMAL));
		vec3 ssr = simple_ssr(view_pos, reflect_dir, PROJECTION_MATRIX);
		if (ssr.x >= 0.0) {
			reflection_color = ssr;
		}
	}
	// Fallback: environment reflection handled by Godot's built-in system

	// === FINAL COLOR BLEND ===
	// OpenMW: mix(refraction, reflection, fresnel)
	vec3 final_color;
	if (reflection_color.x >= 0.0) {
		final_color = mix(underwater_color, reflection_color, fresnel * 0.7);
	} else {
		// Let Godot handle reflection via environment
		final_color = underwater_color;
	}

	// === WOBBLY SHORES (OpenMW style) ===
	if (enable_wobbly_shores && linear_dist < wobbly_shore_fade_distance) {
		// Wobbly effect: blend to raw refraction at very shallow depths with wave-based offset
		// OpenMW: verticalWaterDepth = realWaterDepth * viewFactor
		// shoreOffset = verticalWaterDepth - (normal.r + 0.15) * 8.0  (in MW units)
		// In meters: 8 MW ≈ 0.11m, so we use ~0.1
		float view_factor = mix(abs(view_world.y), 1.0, 0.2);
		float vertical_depth = water_depth * view_factor;
		float shore_offset = vertical_depth - (gradient.x + 0.15) * 0.1;

		// Precision fade at distance - OpenMW: fuzzFactor = min(1, 1000/surfaceDepth) * viewFactor
		// 1000 MW ≈ 13.8m
		float fuzz = min(1.0, 14.0 / linear_dist) * view_factor;
		shore_offset *= fuzz;
		shore_offset = clamp(mix(shore_offset, 1.0, linear_dist / wobbly_shore_fade_distance), 0.0, 1.0);

		// Blend raw refraction at wobbly shores
		vec3 raw_refraction = texture(screen_texture, SCREEN_UV).rgb;
		final_color = mix(raw_refraction, final_color, shore_offset);
	}

	// === SPECULAR HIGHLIGHTS ===
	// OpenMW: artificial specularity for rain ripples
	vec3 sky_estimate = vec3(max(0.0, mix(-0.3, 1.0, sun_fade)));
	vec3 rain_spec_color = rain_specular * mix(sky_estimate, vec3(1.0), 0.05) * 0.5 * rain_intensity;

	// === FOAM ===
	final_color = mix(final_color, foam_color.rgb, v_foam_factor);
	final_color += rain_spec_color;

	// === OUTPUT ===
	ALBEDO = final_color;
	ROUGHNESS = mix(0.02, 0.5, v_foam_factor);
	METALLIC = 0.0;
	SPECULAR = 0.5;

	// OpenMW-style transparency: fresnel affects how much we see through vs reflect
	// But we keep alpha=1 since we're doing refraction manually
	ALPHA = 1.0;
}

// ============================================================================
// SPECULAR - GGX microfacet model (from GodotOceanWaves)
// ============================================================================
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

// ============================================================================
// LIGHT FUNCTION - OpenMW style specular + SSS
// ============================================================================
void light() {
	vec3 halfway = normalize(LIGHT + VIEW);
	float dot_nl = max(dot(NORMAL, LIGHT), 0.0001);
	float dot_nv = max(dot(NORMAL, VIEW), 0.0001);
	float dot_nh = max(dot(NORMAL, halfway), 0.0);
	float dot_lh = max(dot(LIGHT, halfway), 0.0);

	// === SPECULAR (GGX) ===
	float alpha = roughness * roughness;
	float light_mask = smith_masking_shadowing(alpha, dot_nv);
	float view_mask = smith_masking_shadowing(alpha, dot_nl);
	float D = ggx_distribution(dot_nh, alpha);
	float G = 1.0 / (1.0 + light_mask + view_mask);

	// Fresnel for specular (half-vector based)
	float F = mix(pow(1.0 - dot_lh, 5.0), 1.0, REFLECTANCE);

	// OpenMW boosts specular with SPEC_BRIGHTNESS = 1.5
	float spec = F * D * G / (4.0 * dot_nv + 0.001) * 1.5;
	SPECULAR_LIGHT += spec * ATTENUATION * LIGHT_COLOR;

	// === SUBSURFACE SCATTERING (from wave crests) ===
	// Light transmits through thin wave peaks when backlit
	// This is calculated from NORMAL gradient, not vertex wave_height

	// Wave crest thinness: derived from how much the normal deviates from up
	float normal_deviation = 1.0 - dot(NORMAL, vec3(0.0, 1.0, 0.0));
	float wave_thinness = normal_deviation * 2.0;

	// Transmission: strongest when looking toward light through water
	float transmission = pow(max(dot(LIGHT, VIEW), 0.0), 4.0);

	// SSS color - cyan/green tinted (from GodotOceanWaves sss_modifier)
	const vec3 sss_color = vec3(0.9, 1.15, 0.85);
	float sss_intensity = transmission * wave_thinness * 0.5;

	// Standard diffuse (reduced for water)
	float diffuse = dot_nl * 0.3;

	// Combine
	vec3 diffuse_sss = (diffuse + sss_intensity * sss_color) * LIGHT_COLOR;

	// Fresnel reduces diffuse (more reflection = less transmission)
	float view_fresnel = mix(pow(1.0 - dot_nv, 5.0), 1.0, REFLECTANCE);
	DIFFUSE_LIGHT += mix(diffuse_sss, foam_color.rgb * dot_nl, v_foam_factor) * (1.0 - view_fresnel) * ATTENUATION;
}
