shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 water_color : source_color = vec4(0.02, 0.15, 0.22, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.1;
uniform float clarity : hint_range(0.0, 1.0) = 0.5;
uniform float refraction_strength : hint_range(0.0, 0.3) = 0.05;
uniform float depth_fade_distance : hint_range(0.0, 100.0) = 5.0;
uniform float water_normal_strength : hint_range(0.0, 2.0) = 0.55;
uniform float water_normal_uv_scale : hint_range(0.01, 2.0) = 0.18;

#include "res://src/core/water/shaders/water_interaction_common.gdshaderinc"
#include "res://src/core/water/shaders/water_surface_optics_common.gdshaderinc"

uniform bool enable_waves = true;
uniform float wave_scale : hint_range(0.0, 2.0) = 0.3;
uniform float time = 0.0;

// River flow
uniform vec2 flow_direction = vec2(1.0, 0.0);
uniform float flow_speed = 0.0;
uniform float flow_visual_strength : hint_range(0.0, 1.0) = 0.42;
uniform int debug_display_mode = 0;

varying float wave_height;
varying float fresnel;
varying vec2 flow_space;
varying vec2 world_xz;

// Simple wave function for small water bodies
vec3 simple_wave(vec2 pos, float time_val) {
	if (!enable_waves) {
		return vec3(0.0);
	}

	// Combine two sine waves for variety
	float wave1 = sin(pos.x * 0.5 + time_val * 1.5) * cos(pos.y * 0.3 + time_val * 1.2);
	float wave2 = sin(pos.x * 0.8 - pos.y * 0.5 + time_val * 1.8) * 0.5;
	float height = (wave1 + wave2) * wave_scale * 0.1;

	return vec3(0.0, height, 0.0);
}

// Calculate normal from wave function
vec3 calculate_wave_normal(vec2 pos, float time_val) {
	if (!enable_waves) {
		return vec3(0.0, 1.0, 0.0);
	}

	const float eps = 0.1;
	vec3 p = simple_wave(pos, time_val);
	vec3 px = simple_wave(pos + vec2(eps, 0.0), time_val);
	vec3 py = simple_wave(pos + vec2(0.0, eps), time_val);

	vec3 tangent = normalize(vec3(eps, px.y - p.y, 0.0));
	vec3 binormal = normalize(vec3(0.0, py.y - p.y, eps));

	return normalize(cross(binormal, tangent));
}

void vertex() {
	vec2 pos = VERTEX.xz;
	vec3 base_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_xz = base_world.xz;

	// Apply river flow offset to UV for scrolling effect
	vec2 flow_offset = flow_direction * time * flow_speed * 0.1;
	UV = (pos + flow_offset) * 0.1;
	vec2 fdir = normalize(flow_direction + vec2(0.0001, 0.0));
	vec2 side = vec2(-fdir.y, fdir.x);
	vec2 advected = pos + fdir * time * flow_speed * 3.0;
	flow_space = vec2(dot(advected, side), dot(advected, fdir));

	// Apply wave displacement
	vec3 wave_disp = simple_wave(pos, time);
	VERTEX += wave_disp;
	float interaction_height = water_surface_interaction_height_at(world_xz, base_world.y);
	VERTEX.y += interaction_height;
	wave_height = wave_disp.y + interaction_height;

	// Calculate normal from waves
	if (enable_waves) {
		NORMAL = calculate_wave_normal(pos, time);
	}
	vec2 interaction_slope = water_surface_interaction_gradient_at(world_xz, base_world.y);
	if (water_interaction_enabled) {
		NORMAL = normalize(NORMAL + vec3(-interaction_slope.x, 0.0, -interaction_slope.y));
	}
}

void fragment() {
	vec2 ripple_gradient = water_surface_interaction_gradient_at(world_xz, water_interaction_surface_height);
	vec2 fdir = normalize(flow_direction + vec2(0.0001, 0.0));
	vec2 surface_normal_xy = water_surface_micro_normal(world_xz, fdir, max(flow_speed, 0.0)) * water_normal_strength + ripple_gradient * 0.25;
	NORMAL_MAP = vec3(surface_normal_xy, 1.0);
	NORMAL_MAP_DEPTH = 0.75;

	float flow_mask = clamp(flow_speed * 0.30, 0.0, 1.0);
	float transverse = sin(flow_space.x * 2.7 + sin(flow_space.y * 0.23) * 1.4) * 0.5 + 0.5;
	float broken = sin(flow_space.y * 2.2 + time * max(flow_speed, 0.1) * 1.4) * 0.5 + 0.5;
	float streak = smoothstep(0.72, 0.96, transverse) * smoothstep(0.30, 0.86, broken);
	float interaction_foam = water_surface_interaction_foam_at(world_xz, water_interaction_surface_height);
	float flow_foam = streak * flow_mask * flow_visual_strength * 0.25;
	float foam = clamp(interaction_foam * 0.35 + flow_foam, 0.0, 1.0);
	vec4 surf_view4 = VIEW_MATRIX * vec4(vec3(world_xz.x, water_interaction_surface_height, world_xz.y), 1.0);
	vec3 surf_view = surf_view4.xyz / max(surf_view4.w, 0.00001);
	bool sky_or_far = false;
	float water_depth = water_surface_thickness(SCREEN_UV, surf_view, INV_PROJECTION_MATRIX, sky_or_far);
	float edge_factor = 1.0 - smoothstep(0.0, max(depth_fade_distance * 0.08, 0.25), water_depth);
	vec3 refracted_color = vec3(0.0);
	fresnel = 0.0;
	ALBEDO = water_surface_optical_color(surf_view, NORMAL, VIEW, SCREEN_UV, INV_PROJECTION_MATRIX, surface_normal_xy, fdir, max(flow_speed, 0.0), foam, edge_factor, fresnel, refracted_color);

	// Transparency
	ALPHA = mix(clarity, 1.0, fresnel * 0.5);

	ROUGHNESS = water_surface_roughness + foam * 0.25;
	METALLIC = 0.0;
	SPECULAR = 0.5;
	SSS_STRENGTH = 0.05;
	if (debug_display_mode == 1) {
		if (flow_speed <= 0.001) {
			ALBEDO = vec3(0.08, 0.22, 0.32);
			EMISSION = vec3(0.01, 0.05, 0.08);
		} else {
			vec2 fdir = normalize(flow_direction + vec2(0.0001, 0.0));
			ALBEDO = vec3(fdir * 0.5 + 0.5, 0.18);
			EMISSION = ALBEDO * 0.6;
		}
		ALPHA = 1.0;
	} else if (debug_display_mode == 2) {
		float speed_debug = clamp(flow_speed / 4.0, 0.0, 1.0);
		ALBEDO = mix(vec3(0.02, 0.08, 0.25), vec3(0.95, 0.82, 0.28), speed_debug);
		EMISSION = ALBEDO * 0.5;
		ALPHA = 1.0;
	} else if (debug_display_mode == 3) {
		float depth_debug = clamp(water_depth / max(water_surface_max_visible_depth_m, 0.001), 0.0, 1.0);
		ALBEDO = mix(vec3(0.90, 0.22, 0.10), vec3(0.04, 0.34, 0.92), depth_debug);
		EMISSION = ALBEDO * 0.45;
		ALPHA = 1.0;
	} else if (debug_display_mode == 4) {
		ALBEDO = vec3(0.82, 0.90, 0.96);
		EMISSION = ALBEDO * 0.35;
		ALPHA = 1.0;
	} else if (debug_display_mode == 5 || water_interaction_debug_enabled) {
		vec3 interaction_debug_color = water_surface_interaction_debug_color_at(world_xz, water_interaction_surface_height);
		ALBEDO = interaction_debug_color;
		EMISSION = interaction_debug_color * 1.4;
		ALPHA = 1.0;
		ROUGHNESS = 1.0;
		METALLIC = 0.0;
		SPECULAR = 0.0;
	}
}

void light() {
	// Simple PBR lighting
	vec3 halfway = normalize(LIGHT + VIEW);
	float dot_nl = max(dot(NORMAL, LIGHT), 0.001);
	float dot_nh = max(dot(NORMAL, halfway), 0.001);

	// Specular (simplified GGX)
	float a_sq = roughness * roughness;
	float d = 1.0 + (a_sq - 1.0) * dot_nh * dot_nh;
	float D = a_sq / (PI * d * d);
	float spec = fresnel * D * 0.25;
	SPECULAR_LIGHT += spec * ATTENUATION * LIGHT_COLOR;

	// Diffuse with subtle SSS
	float sss = pow(max(dot(LIGHT, -VIEW), 0.0), 3.0) * 0.3;
	vec3 diff_color = mix(water_color.rgb, vec3(0.1, 0.4, 0.3), sss);
	DIFFUSE_LIGHT += diff_color * dot_nl * (1.0 - fresnel) * ATTENUATION * LIGHT_COLOR;
}
