shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled;

/**
 * Flat water shader with SSR reflections and refraction
 * No FFT - lightweight alternative using noise textures for waves
 * Based on: https://github.com/GodotSSRWater
 * Adapted for Godotwind project with shore mask support
 */

const float EPSILON = 1e-5;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;

// Water colors (OpenMW style)
// WATER_COLOR from OpenMW: vec3(0.090195, 0.115685, 0.12745)
uniform vec3 water_color : source_color = vec3(0.09, 0.116, 0.127);
uniform vec3 color_deep : source_color = vec3(0.02, 0.04, 0.06);

// Material properties
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.25;
// OpenMW uses Morrowind units: 1 MW unit ≈ 0.014m, so VISIBILITY=2500 MW ≈ 35m
uniform float water_visibility : hint_range(5.0, 200.0) = 35.0;  // ~35m (OpenMW 2500 MW units)
uniform float depth_fade : hint_range(0.01, 1.0) = 0.15;  // OpenMW DEPTH_FADE

// Wave displacement textures (noise-based)
uniform sampler2D wave_a : repeat_enable, filter_linear_mipmap;
uniform sampler2D wave_b : repeat_enable, filter_linear_mipmap;
uniform vec2 wave_move_direction_a = vec2(-1.0, 0.0);
uniform vec2 wave_move_direction_b = vec2(0.0, 1.0);
uniform float wave_noise_scale_a = 15.0;
uniform float wave_noise_scale_b = 15.0;
uniform float wave_time_scale_a = 0.15;
uniform float wave_time_scale_b = 0.15;
uniform float wave_height_scale = 1.0;
uniform float wave_normal_flatness : hint_range(0.1, 100.0) = 50.0;

// Surface normal detail textures
uniform sampler2D surface_normals_a : repeat_enable, filter_linear_mipmap, hint_normal;
uniform sampler2D surface_normals_b : repeat_enable, filter_linear_mipmap, hint_normal;
uniform vec2 surface_normals_move_direction_a = vec2(-1.0, 0.2);
uniform vec2 surface_normals_move_direction_b = vec2(0.2, 1.0);
uniform float surface_texture_roughness : hint_range(0.0, 1.0) = 0.15;
uniform float surface_texture_scale : hint_range(0.001, 2.0) = 0.1;
uniform float surface_texture_time_scale : hint_range(0.001, 2.0) = 0.06;

// SSR settings
uniform float ssr_resolution : hint_range(0.01, 10.0) = 1.0;
uniform float ssr_max_travel : hint_range(0.0, 200.0) = 30.0;
uniform float ssr_max_diff : hint_range(0.1, 10.0) = 4.0;
uniform float ssr_mix_strength : hint_range(0.0, 1.0) = 0.7;
uniform float ssr_screen_border_fadeout : hint_range(0.0, 1.0) = 0.3;

// Refraction settings
uniform float refraction_intensity : hint_range(0.0, 1.0) = 0.4;

// Shore/border foam settings
uniform vec3 border_color : source_color = vec3(1.0);
uniform float border_scale : hint_range(0.0, 5.0) = 2.0;
uniform float border_near = 0.5;
uniform float border_far = 300.0;

// Shore mask for wave dampening (not visibility)
uniform sampler2D shore_mask : filter_linear;
uniform vec4 shore_mask_bounds = vec4(-8000.0, -8000.0, 16000.0, 16000.0);

varying vec2 vertex_uv;
varying vec3 world_position;
varying vec3 vertex_normal;

// Sample shore mask - Returns shore factor for wave dampening:
// 0.0 = at shore or on land (no waves, calm water)
// 1.0 = far from shore (full waves, open ocean)
float sample_shore_mask(vec2 world_xz) {
	vec2 uv = (world_xz - shore_mask_bounds.xy) / shore_mask_bounds.zw;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		return 1.0; // Outside mask bounds = full waves
	}
	return texture(shore_mask, uv).r;
}

float get_wave_height(vec2 uv_a, vec2 uv_b) {
	float height1 = texture(wave_a, uv_a).y;
	float height2 = texture(wave_b, uv_b).y;
	return (height1 + height2) / 2.0;
}

vec3 blend_normals(vec3 n1, vec3 n2) {
	// UDN blending for normal maps
	return normalize(vec3(n1.xy + n2.xy, n1.z * n2.z));
}

void vertex() {
	// Get world position for tiling
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vertex_uv = world_position.xz;

	// Wave UV with animation
	vec2 uv_a = vertex_uv / wave_noise_scale_a + (wave_move_direction_a * TIME * wave_time_scale_a);
	vec2 uv_b = vertex_uv / wave_noise_scale_b + (wave_move_direction_b * TIME * wave_time_scale_b);

	// Vertex displacement from wave textures
	float wave_height = get_wave_height(uv_a, uv_b) * wave_height_scale;
	VERTEX.y += wave_height;

	// Calculate normal from height gradient (finite differences)
	float normal_height_scale = wave_height_scale / wave_normal_flatness;
	vec2 e = vec2(0.01, 0.0);
	vec3 calculated_normal = normalize(vec3(
		get_wave_height(uv_a - e, uv_b - e) * normal_height_scale - get_wave_height(uv_a + e, uv_b + e) * normal_height_scale,
		2.0 * e.x,
		get_wave_height(uv_a - e.yx, uv_b - e.yx) * normal_height_scale - get_wave_height(uv_a + e.yx, uv_b + e.yx) * normal_height_scale
	));

	// Store world-space normal for fragment shader
	vertex_normal = calculated_normal;
	NORMAL = calculated_normal;
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

vec4 get_ssr_color(vec3 surface_view_position, vec3 normal_view_space, vec3 view_dir, mat4 proj_m, mat4 inv_proj_m) {
	if (ssr_max_travel < EPSILON) {
		return vec4(0.0);
	}

	vec3 current_position_view_space = surface_view_position;
	vec3 view_direction_view_space = -view_dir;
	vec3 reflect_vector_view_space = normalize(reflect(view_direction_view_space, normal_view_space));

	vec2 current_screen_position = vec2(0.0);
	vec3 resulting_color = vec3(-1.0);

	for (float travel = 0.0; resulting_color.x < 0.0 && travel < ssr_max_travel; travel += ssr_resolution) {
		current_position_view_space += reflect_vector_view_space * ssr_resolution;
		current_screen_position = get_uv_from_view_position(current_position_view_space, proj_m);

		float depth_probe = texture(depth_texture, current_screen_position).x;
		vec3 depth_probe_view_position = get_view_position_from_uv(current_screen_position, depth_probe, inv_proj_m);

		float depth_diff = depth_probe_view_position.z - current_position_view_space.z;

		vec3 ssr_screen_color = texture(screen_texture, current_screen_position).rgb;
		resulting_color = (is_within_screen_boundaries(current_screen_position) && depth_diff >= 0.0 && depth_diff < ssr_max_diff) ? ssr_screen_color : vec3(-1.0);
	}

	float alpha = get_screen_border_alpha(current_screen_position);
	return vec4(resulting_color, alpha);
}

float linear_depth(float cur_depth) {
	return border_far * border_near / (border_near + cur_depth * (border_far - border_near));
}

float normalize_float(float min_v, float max_v, float value) {
	float clamped_value = clamp(value, min_v, max_v);
	return (clamped_value - min_v) / (max_v - min_v);
}

vec2 get_refracted_uv(vec2 raw_screen_uv, float screen_depth_raw, vec3 view_dir, vec3 normal_view, mat4 proj_m, mat4 inv_proj_m) {
	vec3 screen_view_position_original = get_view_position_from_uv(raw_screen_uv, screen_depth_raw, inv_proj_m);
	float screen_center_distance = clamp(length(raw_screen_uv - vec2(0.5)) * 2.0, 0.0, 1.0);
	float refraction_intensity_deglitched = mix(1.0 - refraction_intensity, 1.0, screen_center_distance);
	vec3 refraction_position_view_space = screen_view_position_original + normalize(refract(view_dir, -normal_view, refraction_intensity_deglitched));
	return get_uv_from_view_position(refraction_position_view_space, proj_m);
}

void fragment() {
	// Shore mask check - discard on land
	float shore_factor = sample_shore_mask(world_position.xz);
	if (shore_factor < 0.05) {
		discard;
	}

	// Surface normal detail from scrolling textures
	vec2 time_vector_a = TIME * surface_normals_move_direction_a * surface_texture_time_scale;
	vec2 time_vector_b = TIME * surface_normals_move_direction_b * surface_texture_time_scale;

	vec3 normal_a = texture(surface_normals_a, vertex_uv * surface_texture_scale + time_vector_a).xyz * 2.0 - 1.0;
	vec3 normal_b = texture(surface_normals_b, vertex_uv * surface_texture_scale + time_vector_b).xyz * 2.0 - 1.0;

	// Blend wave normal with detail normals
	vec3 detail_normal = blend_normals(normal_a, normal_b);
	vec3 world_normal = normalize(mix(vertex_normal, detail_normal, surface_texture_roughness));

	// Flip normal if viewing from back side (underwater)
	if (!FRONT_FACING) {
		world_normal = -world_normal;
	}

	// Transform normal to view space for SSR and lighting
	vec3 normal_view_space = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);

	// Depth sampling
	float screen_depth_raw = texture(depth_texture, SCREEN_UV).x;

	// Refraction UV calculation
	vec2 refraction_uv = refraction_intensity > 0.0
		? get_refracted_uv(SCREEN_UV, screen_depth_raw, VIEW, normal_view_space, PROJECTION_MATRIX, INV_PROJECTION_MATRIX)
		: SCREEN_UV;

	float screen_depth = texture(depth_texture, refraction_uv).x;
	float surface_depth = FRAGCOORD.z;

	// Shore foam detection based on depth difference
	float border_diff = linear_depth(screen_depth_raw) - linear_depth(surface_depth);

	// Calculate water depth for absorption
	vec3 screen_view_position = get_view_position_from_uv(refraction_uv, screen_depth, INV_PROJECTION_MATRIX);
	vec3 surface_view_position = get_view_position_from_uv(SCREEN_UV, surface_depth, INV_PROJECTION_MATRIX);
	float water_depth_val = length(surface_view_position - screen_view_position);

	// Screen color (what's behind the water, with refraction offset)
	vec3 screen_color = texture(screen_texture, refraction_uv).rgb;

	// SSR reflections using view-space normal
	vec4 ssr_color = get_ssr_color(surface_view_position, normal_view_space, VIEW, PROJECTION_MATRIX, INV_PROJECTION_MATRIX);

	// ==========================================================================
	// WATER COLOR ABSORPTION (simplified OpenMW-style)
	// ==========================================================================
	// Exponential absorption - numerically stable version
	float safe_water_depth = max(water_depth_val, 0.0);

	// At depth=0: absorption=0 (see background)
	// At depth=visibility: absorption≈0.63 (mostly water color)
	float absorption_factor = 1.0 - exp(-safe_water_depth * depth_fade * 10.0 / water_visibility);
	absorption_factor = clamp(absorption_factor, 0.0, 1.0);

	// Mix refracted background with water color based on depth
	vec3 absorbed_color = mix(screen_color, water_color, absorption_factor);

	// Add deep water color for very deep areas
	float deep_factor = smoothstep(0.0, water_visibility * 0.3, safe_water_depth);
	vec3 surface_depth_color_mix = mix(absorbed_color, color_deep, deep_factor * 0.5);

	// Apply SSR if valid reflection found
	vec3 final_water_color;
	if (ssr_max_travel > EPSILON && ssr_color.x >= 0.0) {
		final_water_color = mix(surface_depth_color_mix, ssr_color.rgb, ssr_mix_strength * ssr_color.a);
	} else {
		final_water_color = surface_depth_color_mix;
	}

	// Shore foam - white border where water meets land
	vec3 final_color = mix(border_color, final_water_color, step(border_scale, border_diff));

	// Output - water is opaque, "transparency" comes from color mixing with refraction
	ALBEDO = final_color;
	METALLIC = metallic;
	ROUGHNESS = roughness;
	NORMAL = normal_view_space;
	ALPHA = 1.0;  // Water is always opaque - shore mask only dampens waves, not visibility
}
