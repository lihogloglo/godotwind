shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

/**
 * Ocean shader with FFT wave displacement + realistic water rendering
 *
 * FFT Waves: From GodotOceanWaves (displacement + normals from compute shader)
 * Visual Style: Combined OpenMW + GodotShaders + Godot Water Prototype techniques
 *
 * Features:
 * - Schlick Fresnel for angle-dependent reflectivity
 * - Screen-space reflections with proper edge fading
 * - Screen-space refraction with depth-aware distortion
 * - Snell's window for underwater viewing
 * - Texture-based color gradient (artistic control)
 * - Enhanced subsurface scattering with wave height
 * - Water sparkle/highlight map for sun glints
 * - Procedural Voronoi caustics underwater
 * - Foam with bubble layer blending
 */

#define MAX_CASCADES 3
#define REFLECTANCE 0.02

// Physical constants
const float IOR_AIR = 1.0;
const float IOR_WATER = 1.333;
const float CRITICAL_ANGLE = 0.6435; // asin(IOR_AIR / IOR_WATER) in radians

// Screen textures
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;

// ============================================================================
// WATER COLORS - Texture-based gradient for artistic control
// ============================================================================
global uniform vec4 water_color : source_color;
global uniform vec4 foam_color : source_color;
// Color gradient texture: X = depth (0=surface, 1=deep), sample Y=0.5
// If not provided, falls back to shallow/deep colors
uniform sampler2D water_color_gradient : filter_linear, repeat_disable;
uniform bool use_color_gradient = false;
// Fallback colors when no gradient texture
uniform vec3 color_shallow : source_color = vec3(0.1, 0.4, 0.5);
uniform vec3 color_deep : source_color = vec3(0.01, 0.05, 0.1);
// How deep (in meters) until we reach full deep color
uniform float color_gradient_depth : hint_range(1.0, 100.0) = 20.0;

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
// SUNLIGHT SCATTERING - OpenMW style + enhanced SSS
// ============================================================================
uniform bool enable_sunlight_scattering = true;
uniform float scatter_amount : hint_range(0.0, 1.0) = 0.3;  // OpenMW SCATTER_AMOUNT = 0.3
uniform vec3 scatter_color : source_color = vec3(0.0, 1.0, 0.95);  // OpenMW SCATTER_COLOUR
uniform vec3 sun_extinction : source_color = vec3(0.45, 0.55, 0.68);  // OpenMW SUN_EXT
uniform vec3 sun_direction = vec3(0.5, 0.7, 0.5);
uniform float sun_fade : hint_range(0.0, 1.0) = 1.0;  // Ambient light level

// ============================================================================
// WATER SPARKLES / HIGHLIGHTS - From Godot Water Prototype
// ============================================================================
uniform bool enable_sparkles = true;
uniform sampler2D sparkle_map : filter_linear_mipmap, repeat_enable;  // Noise texture for glints
uniform float sparkle_intensity : hint_range(0.0, 5.0) = 1.5;
uniform float sparkle_speed : hint_range(0.0, 0.2) = 0.05;
uniform float sparkle_scale : hint_range(0.001, 0.1) = 0.02;

// ============================================================================
// UNDERWATER CAUSTICS - Procedural Voronoi (from RafaelsShaderPack DIVE)
// ============================================================================
uniform bool enable_caustics = true;
uniform float caustic_intensity : hint_range(0.0, 2.0) = 0.7;
uniform float caustic_scale : hint_range(0.01, 0.1) = 0.025;
uniform float caustic_speed : hint_range(0.0, 3.0) = 1.8;

// ============================================================================
// ENHANCED FOAM - Bubble layers with flow
// ============================================================================
uniform sampler2D bubble_texture : filter_linear_mipmap, repeat_enable;  // Small bubbles
uniform bool enable_bubbles = true;
uniform float bubble_intensity : hint_range(0.0, 2.0) = 0.5;
uniform float bubble_scale : hint_range(1.0, 20.0) = 8.0;
uniform float flow_speed : hint_range(0.0, 2.0) = 0.5;

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
// SSR - Improved screen-space reflections
// ============================================================================
uniform bool enable_ssr = true;
uniform float ssr_max_travel : hint_range(0.0, 200.0) = 50.0;
uniform float ssr_resolution : hint_range(0.1, 5.0) = 1.0;
uniform float ssr_max_diff : hint_range(0.1, 10.0) = 4.0;
uniform float ssr_mix_strength : hint_range(0.0, 1.0) = 0.8;
uniform float ssr_edge_fadeout : hint_range(0.0, 1.0) = 0.3;

// ============================================================================
// UNDERWATER RENDERING
// ============================================================================
uniform bool enable_underwater = true;
// Snell's window - light bends at critical angle when viewing from underwater
uniform float snells_window_blend : hint_range(0.0, 1.0) = 0.8;

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
// FRESNEL - Schlick approximation (fast, good quality)
// ============================================================================
float fresnel_schlick(float cos_theta, float f0) {
	return f0 + (1.0 - f0) * pow(1.0 - cos_theta, 5.0);
}

// Full dielectric Fresnel for accurate underwater rendering
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
// SNELL'S WINDOW - Underwater viewing physics
// ============================================================================
// When looking up from underwater, light only enters within a cone (critical angle ~48.6°)
// Outside this cone, you see total internal reflection
float snells_window(vec3 view_dir, vec3 normal) {
	// Angle between view direction and surface normal
	float cos_angle = dot(view_dir, normal);

	// Critical angle for water-air interface
	float critical_cos = cos(CRITICAL_ANGLE);

	// Smooth transition at the edge of Snell's window
	return smoothstep(critical_cos - 0.1, critical_cos + 0.1, abs(cos_angle));
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
// VORONOI CAUSTICS - Procedural (from RafaelsShaderPack DIVE)
// Creates natural-looking underwater light patterns
// ============================================================================
float hash3(vec3 p) {
	p += dot(p, vec3(0.7, 0.3, 0.5));
	p = fract(p * vec3(0.3183099, 0.3678794, 0.6065307));
	p = p * 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float get_caustic_edge(vec3 P, vec3 normal, float time) {
	// Add organic warping
	P += sin(P * 0.9 + 1.7) * 0.125;
	P += sin(P.yzx * 1.7 + 2.3) * 0.08;

	vec3 Pi = floor(P);
	vec3 Pf = fract(P);

	float best = 1.0;
	float second_best = 1.0;
	float third_best = 1.0;

	// 3D Voronoi cell search
	for (int z = -1; z <= 1; z++) {
		for (int y = -1; y <= 1; y++) {
			for (int x = 0; x <= 1; x++) {
				vec3 off = vec3(float(x) - 0.5, float(y), float(z));
				vec3 cell = Pi + off;
				vec3 h = vec3(hash3(cell), hash3(cell.yzx), hash3(cell.zxy));
				h = h * 2.0 - 1.0;
				vec3 jitter = normalize(vec3(h.x + best, h.y + h.z * 0.5, h.z - h.x * 0.5)) * 0.5;

				vec3 site = off + jitter;
				float d = length(Pf - site);

				if (d < best) {
					third_best = second_best;
					second_best = best;
					best = d;
				} else if (d < second_best) {
					third_best = second_best;
					second_best = d;
				} else if (d < third_best) {
					third_best = d;
				}
			}
		}
	}

	float edge = (second_best - best) / 1.732;
	float tri_edge = (third_best - best) / 1.732;
	float pinch = smoothstep(0.05, 0.8, tri_edge);
	return mix(edge, 1.0, pinch * 0.5);
}

float compute_caustics(vec3 world_pos, float time, vec3 normal) {
	const float TMIN = -0.20;
	const float TMAX = 0.10;

	vec3 P = world_pos * caustic_scale;
	float t = time * caustic_speed;
	float t1 = t * 1.7;
	float t2 = (t + 1.2) * 1.3;
	float t3 = (t + 2.5) * 1.1;

	// Animated warping offset
	vec3 warp_offset;
	warp_offset.x = sin(t1 + world_pos.y * 0.13) * cos(t2 + world_pos.z * 0.12);
	warp_offset.y = sin(t2 + world_pos.z * 0.13) * cos(t3 + world_pos.x * 0.12);
	warp_offset.z = sin(t3 + world_pos.x * 0.13) * cos(t1 + world_pos.y * 0.12);
	warp_offset *= 0.4;
	warp_offset.x += cos(t * 1.07);
	warp_offset.y += sin(t * 1.13);
	warp_offset.z += cos(t * 0.97);
	warp_offset += 0.25 * sin(P.yzx * 1.3 + t * 0.9);
	warp_offset += normal * 0.5;

	float diff = get_caustic_edge(warp_offset * 0.04 / caustic_scale + P, normal, time);
	float edge = smoothstep(TMIN, TMAX, diff);
	return 1.0 - edge;
}

// ============================================================================
// WATER SPARKLES - Animated glints from Godot Water Prototype
// Creates sparkling highlights when sun reflects off wave peaks
// ============================================================================
float compute_sparkles(vec2 world_xz, float time, vec3 normal, vec3 view_dir, vec3 light_dir) {
	if (!enable_sparkles) return 0.0;

	// Two layers of sparkle noise moving in different directions
	vec2 uv1 = world_xz * sparkle_scale + time * sparkle_speed;
	vec2 uv2 = world_xz * sparkle_scale * 2.0 - time * sparkle_speed * 0.7;

	// Sample sparkle map (if available) or use procedural noise
	float sparkle1 = texture(sparkle_map, uv1).r;
	float sparkle2 = texture(sparkle_map, uv2).r;

	// Combine sparkle layers
	float sparkle_mask = smoothstep(0.0, 0.1, sparkle1 * sparkle2);

	// Only sparkle where light reflects toward camera (specular-like)
	float reflect_factor = pow(max(dot(reflect(light_dir, normal), -view_dir), 0.0), 100.0);

	// Also sparkle at wave peaks (higher normal deviation = wave crest)
	float peak_factor = max(0.0, 1.0 - dot(normal, vec3(0.0, 1.0, 0.0)));

	return sparkle_mask * reflect_factor * sparkle_intensity * (1.0 + peak_factor * 2.0);
}

// ============================================================================
// WATER COLOR GRADIENT - Sample from gradient texture or interpolate
// ============================================================================
vec3 sample_water_color(float depth_factor, float view_angle_factor) {
	// Combine depth and view angle (shallow angles see deeper)
	float combined_factor = mix(depth_factor, 1.0, 1.0 - view_angle_factor);
	combined_factor = clamp(combined_factor, 0.0, 1.0);

	if (use_color_gradient) {
		// Sample from gradient texture (X = depth, Y = 0.5)
		return texture(water_color_gradient, vec2(combined_factor, 0.5)).rgb;
	} else {
		// Fallback to simple lerp between shallow and deep
		return mix(color_shallow, color_deep, combined_factor);
	}
}

// ============================================================================
// BUBBLE LAYER - Flow-mapped bubbles for foam enhancement
// ============================================================================
vec3 compute_bubbles(vec2 world_xz, float time, float height_factor, float shore_factor) {
	if (!enable_bubbles || bubble_intensity < 0.01) return vec3(0.0);

	// Flow-based UV animation (two offset UVs that blend)
	float flow_time = time * flow_speed;
	float blend_factor = cos(flow_time * 2.0 * PI) * 0.5 + 0.5;

	vec2 uv_a = world_xz / bubble_scale + vec2(flow_time * 0.1, flow_time * 0.07);
	vec2 uv_b = world_xz / bubble_scale + vec2(-flow_time * 0.08, flow_time * 0.12) + 0.5;

	// Sample bubble texture at both UVs
	vec3 bubbles_a = texture(bubble_texture, uv_a).rgb;
	vec3 bubbles_b = texture(bubble_texture, uv_b).rgb;

	// Blend between the two based on time
	vec3 bubbles = mix(bubbles_a, bubbles_b, blend_factor);

	// Bubbles appear more on wave peaks and near shores
	float bubble_mask = height_factor * 0.5 + (1.0 - shore_factor) * 0.3;
	bubble_mask = clamp(bubble_mask, 0.0, 1.0);

	return bubbles * bubble_mask * bubble_intensity;
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
// HELPER FUNCTIONS
// ============================================================================
vec2 get_uv_from_view_position(vec3 pos_view, mat4 proj_m) {
	vec4 clip_pos = proj_m * vec4(pos_view, 1.0);
	vec2 ndc = clip_pos.xy / clip_pos.w;
	return ndc * 0.5 + 0.5;
}

vec3 get_view_position_from_uv(vec2 uv, float depth, mat4 inv_proj_m) {
	vec4 ndc = vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec4 view_pos = inv_proj_m * ndc;
	return view_pos.xyz / view_pos.w;
}

bool is_within_screen(vec2 uv) {
	return uv.x > 0.0 && uv.x < 1.0 && uv.y > 0.0 && uv.y < 1.0;
}

// Screen edge fade for SSR - smooth falloff at borders
float get_screen_edge_fade(vec2 screen_uv) {
	vec2 shifted = 4.0 * screen_uv * (1.0 - screen_uv);
	float mask = shifted.x * shifted.y; // 0 at edges, 1 at center

	// Offset for high fadeout values to ensure smooth transition to zero
	float offset = mix(0.0, 0.5, (clamp(ssr_edge_fadeout, 0.75, 1.0) - 0.75) / 0.25);
	float alpha = clamp(smoothstep(0.0, 2.0 * ssr_edge_fadeout, mask) - offset, 0.0, 1.0);

	return ssr_edge_fadeout < 0.001 ? 1.0 : alpha;
}

// ============================================================================
// IMPROVED SSR - Raymarching with proper edge handling
// ============================================================================
vec4 compute_ssr(vec3 surface_view_pos, vec3 normal_view, vec3 view_dir_view, mat4 proj_m, mat4 inv_proj_m) {
	if (!enable_ssr || ssr_max_travel < 0.001) {
		return vec4(-1.0);
	}

	vec3 reflect_dir = normalize(reflect(-view_dir_view, normal_view));
	vec3 current_pos = surface_view_pos;
	vec2 hit_uv = vec2(0.0);

	// Raymarching loop
	for (float travel = 0.0; travel < ssr_max_travel; travel += ssr_resolution) {
		current_pos += reflect_dir * ssr_resolution;
		hit_uv = get_uv_from_view_position(current_pos, proj_m);

		// Exit if outside screen
		if (!is_within_screen(hit_uv)) {
			break;
		}

		// Sample scene depth at this screen position
		float depth_sample = texture(depth_texture, hit_uv).x;
		vec3 scene_pos = get_view_position_from_uv(hit_uv, depth_sample, inv_proj_m);

		// Check if ray intersects scene
		float depth_diff = scene_pos.z - current_pos.z;

		if (depth_diff >= 0.0 && depth_diff < ssr_max_diff) {
			// Hit! Sample screen color with edge fade
			vec3 hit_color = texture(screen_texture, hit_uv).rgb;
			float edge_alpha = get_screen_edge_fade(hit_uv);

			// Fade based on travel distance (far reflections are less reliable)
			float distance_fade = 1.0 - (travel / ssr_max_travel);

			return vec4(hit_color, edge_alpha * distance_fade * ssr_mix_strength);
		}
	}

	return vec4(-1.0);
}

// ============================================================================
// IMPROVED REFRACTION - Depth-aware with edge deglitching
// ============================================================================
vec2 get_refracted_uv(vec2 screen_uv, float screen_depth, vec3 view_dir, vec3 normal, mat4 proj_m, mat4 inv_proj_m) {
	vec3 screen_pos = get_view_position_from_uv(screen_uv, screen_depth, inv_proj_m);

	// Reduce refraction intensity near screen edges to prevent artifacts
	float screen_center_dist = clamp(length(screen_uv - vec2(0.5)) * 2.0, 0.0, 1.0);
	float refr_intensity = mix(refraction_strength, refraction_strength * 0.1, screen_center_dist);

	// Calculate refracted ray
	vec3 refract_dir = refract(view_dir, -normal, IOR_AIR / IOR_WATER);
	vec3 refracted_pos = screen_pos + normalize(refract_dir) * refr_intensity * 10.0;

	vec2 refracted_uv = get_uv_from_view_position(refracted_pos, proj_m);

	// Clamp to valid screen range
	return clamp(refracted_uv, vec2(0.001), vec2(0.999));
}

// ============================================================================
// FRAGMENT SHADER
// ============================================================================
void fragment() {
	float dist_to_cam = length(v_world_pos.xz - camera_position_world.xz);
	float linear_dist = length(v_world_pos - camera_position_world);

	// === DEPTH CALCULATIONS ===
	float depth_raw = texture(depth_texture, SCREEN_UV).r;
	vec3 floor_view_pos = get_view_position_from_uv(SCREEN_UV, depth_raw, INV_PROJECTION_MATRIX);
	float floor_depth = floor_view_pos.z;
	float water_depth = max(VERTEX.z - floor_depth, 0.0);

	// Normalized depth for color blending (0 = surface, 1 = max visible depth)
	float depth_normalized = clamp(water_depth / water_visibility, 0.0, 1.0);

	// === SHORE FACTOR ===
	float shore_map_factor = sample_shore_mask(v_world_pos.xz);
	float depth_shore_factor = smoothstep(0.0, shore_depth_scale, water_depth);
	float shore_factor = min(shore_map_factor, depth_shore_factor);

	// === NORMALS FROM FFT ===
	vec3 gradient = vec3(0.0);
	for (uint i = 0U; i < num_cascades; ++i) {
		vec4 scales = map_scales[i];
		vec3 coords = vec3(UV * scales.xy, float(i));
		vec4 normal_sample = texture(normals, coords);
		gradient += normal_sample.xyw * vec3(scales.ww * shore_factor, 1.0);
	}

	// === RAIN RIPPLES ===
	vec3 ripple_add = vec3(0.0);
	float rain_specular = 0.0;
	if (enable_rain_ripples && rain_intensity > 0.01) {
		vec4 rain = rain_combined(v_world_pos.xz / 1000.0, TIME) * rain_intensity;
		ripple_add = rain.xyz * 10.0;
		rain_specular = abs(rain.w) * 0.5;
		gradient.xy *= mix(1.0, 1.5, rain_intensity);
	}
	gradient.xy += ripple_add.xy;

	// === FOAM FACTOR ===
	v_foam_factor = smoothstep(0.0, 1.0, gradient.z * 0.75) * exp(-dist_to_cam * 0.0075) * shore_factor;

	// === WORLD NORMAL ===
	float effective_normal_strength = mix(0.015, normal_strength, exp(-dist_to_cam * 0.0175));
	float bump = mix(0.5, 1.5, rain_intensity);
	gradient.xy *= effective_normal_strength * bump;

	vec3 world_normal = normalize(vec3(-gradient.x, 1.0, -gradient.y));
	vec3 view_normal = (VIEW_MATRIX * vec4(world_normal, 0.0)).xyz;
	NORMAL = view_normal;

	// Flip normal for backface (underwater viewing)
	bool is_underwater = !FRONT_FACING;
	if (is_underwater) {
		world_normal = -world_normal;
		view_normal = -view_normal;
	}

	// === VIEW DIRECTION & FRESNEL ===
	vec3 view_world = normalize(camera_position_world - v_world_pos);
	float cos_theta = max(dot(view_world, world_normal), 0.0);

	// Use Schlick for above water, dielectric for underwater (more accurate at critical angles)
	float fresnel;
	if (is_underwater) {
		fresnel = fresnel_dielectric(-view_world, world_normal, IOR_WATER);
	} else {
		fresnel = fresnel_schlick(cos_theta, REFLECTANCE);
	}
	fresnel = clamp(fresnel, REFLECTANCE, 1.0);

	// === REFRACTION WITH IMPROVED UV CALCULATION ===
	vec2 refraction_uv;
	if (refraction_strength > 0.001) {
		refraction_uv = get_refracted_uv(SCREEN_UV, depth_raw, -VIEW, view_normal, PROJECTION_MATRIX, INV_PROJECTION_MATRIX);
		// Suppress refraction at shores
		refraction_uv = mix(SCREEN_UV, refraction_uv, clamp(water_depth / shore_depth_scale, 0.0, 1.0));
	} else {
		refraction_uv = SCREEN_UV;
	}

	vec3 refracted_color = texture(screen_texture, refraction_uv).rgb;

	// === WATER COLOR - Using gradient texture or interpolation ===
	// Normalized depth for gradient sampling
	float gradient_depth = clamp(water_depth / color_gradient_depth, 0.0, 1.0);

	// Sample water color based on depth and view angle
	vec3 water_tint = sample_water_color(gradient_depth, cos_theta);

	// Blend with global water_color for consistency
	water_tint = mix(water_tint, water_color.rgb, 0.3) * sun_fade;

	// S-curve absorption (OpenMW formula)
	float depth_correction = sqrt(1.0 + 4.0 * depth_fade * depth_fade);
	float absorption = depth_fade * depth_fade /
		(-0.5 * depth_correction + 0.5 - water_depth / water_visibility)
		+ 0.5 * depth_correction + 0.5;
	absorption = clamp(absorption, 0.0, 1.0);

	// Apply absorption - refracted scene blends to water color
	vec3 underwater_color = mix(refracted_color, water_tint, absorption);

	// Extra darkening for very deep water
	float deep_factor = smoothstep(water_visibility * 0.5, water_visibility, water_depth);
	underwater_color = mix(underwater_color, color_deep * 0.5, deep_factor * 0.7);

	// === SUNLIGHT SCATTERING (Enhanced with wave-height SSS) ===
	vec3 sun_dir = normalize(sun_direction);
	if (enable_sunlight_scattering && !is_underwater) {
		float sun_height = sun_dir.y;

		if (sun_height > 0.0) {
			vec3 scatter_col = mix(scatter_color * vec3(1.0, 0.4, 0.0), scatter_color,
								   max(1.0 - exp(-sun_height * sun_extinction), vec3(0.0)));

			float scatter_lambert = max(dot(sun_dir, world_normal) * 0.7 + 0.3, 0.0);
			float scatter_reflect = max(dot(reflect(sun_dir, world_normal), -view_world) * 2.0 - 1.2, 0.0);
			float light_scatter = scatter_lambert * scatter_reflect * scatter_amount * sun_fade
								  * max(1.0 - exp(-sun_height), 0.0);

			// Enhanced SSS: Brighter scattering through wave crests (from wave height)
			// Wave peaks are thinner, allowing more light through
			float wave_sss = max(0.0, v_wave_height + 2.5) * pow(max(dot(sun_dir, -view_world), 0.0), 4.0);
			wave_sss *= pow(0.5 - 0.5 * dot(sun_dir, world_normal), 3.0) * 0.5;

			underwater_color += scatter_col * (light_scatter + wave_sss * sun_fade);
		}
	}

	// === UNDERWATER CAUSTICS ===
	if (enable_caustics && is_underwater && water_depth > 0.1) {
		// Caustics only visible when looking at underwater surfaces
		float caustic_depth_fade = smoothstep(150.0, 0.0, water_depth);
		float caustic_value = compute_caustics(v_world_pos, TIME, world_normal);

		// Caustics are brightest on upward-facing surfaces
		float surface_factor = max(0.0, world_normal.y + 0.4);

		vec3 caustic_color = vec3(0.8, 0.95, 1.0);  // Slightly cyan tinted
		underwater_color += caustic_color * caustic_value * caustic_intensity
						  * caustic_depth_fade * surface_factor * sun_fade;
	}

	// === SCREEN-SPACE REFLECTIONS ===
	vec3 reflection_color = vec3(0.0);
	float reflection_alpha = 0.0;

	if (enable_ssr && dist_to_cam < 300.0 && !is_underwater) {
		vec3 surface_view_pos = (VIEW_MATRIX * vec4(v_world_pos, 1.0)).xyz;
		vec4 ssr_result = compute_ssr(surface_view_pos, view_normal, VIEW, PROJECTION_MATRIX, INV_PROJECTION_MATRIX);

		if (ssr_result.w > 0.0) {
			reflection_color = ssr_result.rgb;
			reflection_alpha = ssr_result.w;
		}
	}

	// === SNELL'S WINDOW (Underwater) ===
	float snells_factor = 1.0;
	if (is_underwater && enable_underwater) {
		snells_factor = snells_window(view_world, world_normal);

		// Outside Snell's window: total internal reflection (see water color, not sky)
		// Inside Snell's window: see through to air/sky (refracted view)
		vec3 tir_color = water_tint * 0.8; // Total internal reflection color
		underwater_color = mix(tir_color, underwater_color, snells_factor * snells_window_blend);
	}

	// === FINAL COLOR COMPOSITION ===
	vec3 final_color;

	if (is_underwater) {
		// Underwater: less reflection, more refraction, affected by Snell's window
		final_color = mix(underwater_color, reflection_color, fresnel * reflection_alpha * 0.3);
	} else {
		// Above water: blend reflection and refraction based on Fresnel
		vec3 reflected = reflection_color;
		vec3 refracted = underwater_color;

		// If SSR didn't hit, use refracted color with Fresnel-based tint
		// (Godot's environment reflection will handle the rest)
		if (reflection_alpha > 0.0) {
			final_color = mix(refracted, reflected, fresnel * reflection_alpha);
		} else {
			// No SSR hit - still apply Fresnel to lighten color at grazing angles
			// This simulates sky reflection even without SSR
			vec3 sky_tint = vec3(0.6, 0.7, 0.8) * sun_fade;
			final_color = mix(refracted, sky_tint, fresnel * 0.3);
		}
	}

	// === WOBBLY SHORES ===
	if (enable_wobbly_shores && linear_dist < wobbly_shore_fade_distance && !is_underwater) {
		float view_factor = mix(abs(view_world.y), 1.0, 0.2);
		float vertical_depth = water_depth * view_factor;
		float shore_offset = vertical_depth - (gradient.x + 0.15) * 0.1;

		float fuzz = min(1.0, 14.0 / linear_dist) * view_factor;
		shore_offset *= fuzz;
		shore_offset = clamp(mix(shore_offset, 1.0, linear_dist / wobbly_shore_fade_distance), 0.0, 1.0);

		vec3 raw_refraction = texture(screen_texture, SCREEN_UV).rgb;
		final_color = mix(raw_refraction, final_color, shore_offset);
	}

	// === RAIN SPECULAR ===
	vec3 sky_estimate = vec3(max(0.0, mix(-0.3, 1.0, sun_fade)));
	vec3 rain_spec_color = rain_specular * mix(sky_estimate, vec3(1.0), 0.05) * 0.5 * rain_intensity;

	// === WATER SPARKLES (sun glints on wave peaks) ===
	if (enable_sparkles && !is_underwater && sun_fade > 0.1) {
		float sparkle = compute_sparkles(v_world_pos.xz, TIME, world_normal, view_world, sun_dir);
		// Sparkles are white/golden highlights
		vec3 sparkle_color = mix(vec3(1.0), vec3(1.0, 0.95, 0.85), 0.3);
		final_color += sparkle_color * sparkle * sun_fade;
	}

	// === BUBBLES (flow-mapped foam enhancement) ===
	float height_factor = smoothstep(0.0, 1.0, gradient.z * 0.75);  // From normal map
	vec3 bubble_color = compute_bubbles(v_world_pos.xz, TIME, height_factor, shore_factor);
	// Bubbles blend with foam
	float bubble_blend = v_foam_factor * 0.5 + height_factor * 0.3;
	final_color += bubble_color * bubble_blend;

	// === FOAM ===
	final_color = mix(final_color, foam_color.rgb, v_foam_factor);
	final_color += rain_spec_color;

	// === OUTPUT ===
	ALBEDO = final_color;
	ROUGHNESS = mix(0.02, 0.5, v_foam_factor);
	METALLIC = 0.0;
	SPECULAR = 0.5;
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
