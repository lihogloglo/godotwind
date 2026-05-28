shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://src/core/water/shaders/water_interaction_common.gdshaderinc"
#include "res://src/core/water/shaders/water_surface_optics_common.gdshaderinc"

uniform vec4 water_color : source_color = vec4(0.02, 0.18, 0.20, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.18;
uniform float time = 0.0;
uniform float wave_scale : hint_range(0.0, 2.0) = 0.18;
uniform vec2 flow_direction = vec2(1.0, 0.0);
uniform float flow_speed = 0.0;
uniform int debug_display_mode = 0;

varying vec2 v_world_xz;
varying float v_flow_streak;

void vertex() {
	vec3 base_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_xz = base_world.xz;

	float small_wave = sin(VERTEX.x * 0.55 + time * 1.4) * cos(VERTEX.z * 0.36 - time * 1.1) * wave_scale * 0.018;
	float ripple_height = water_surface_interaction_height_at(v_world_xz, base_world.y);
	VERTEX.y += small_wave + ripple_height;

	vec2 ripple_slope = water_surface_interaction_gradient_at(v_world_xz, base_world.y);
	NORMAL = normalize(NORMAL + vec3(-ripple_slope.x, 0.0, -ripple_slope.y));

	vec2 fdir = normalize(flow_direction + vec2(0.0001, 0.0));
	float flow_phase = dot(v_world_xz, fdir) * 1.35 - time * flow_speed * 1.7;
	v_flow_streak = smoothstep(0.72, 0.98, sin(flow_phase) * 0.5 + 0.5) * clamp(flow_speed * 0.24, 0.0, 1.0);
}

void fragment() {
	float ripple_foam = water_surface_interaction_foam_at(v_world_xz, water_interaction_surface_height);
	float foam = clamp(ripple_foam * 0.35 + v_flow_streak * 0.18, 0.0, 1.0);
	vec2 fdir = normalize(flow_direction + vec2(0.0001, 0.0));
	vec2 normal_xy = water_surface_micro_normal(v_world_xz, fdir, flow_speed) * 0.35 + water_surface_interaction_gradient_at(v_world_xz, water_interaction_surface_height) * 0.25;
	NORMAL_MAP = vec3(normal_xy, 1.0);
	NORMAL_MAP_DEPTH = 0.65;
	vec4 surf_view4 = VIEW_MATRIX * vec4(vec3(v_world_xz.x, water_interaction_surface_height, v_world_xz.y), 1.0);
	vec3 surf_view = surf_view4.xyz / max(surf_view4.w, 0.00001);
	float fresnel_value = 0.0;
	vec3 refracted_color = vec3(0.0);
	ALBEDO = water_surface_optical_color(surf_view, NORMAL, VIEW, SCREEN_UV, INV_PROJECTION_MATRIX, normal_xy, fdir, flow_speed, foam, 0.0, fresnel_value, refracted_color);
	ALPHA = 0.88 + fresnel_value * 0.10;
	ROUGHNESS = water_surface_roughness + foam * 0.2;
	METALLIC = 0.0;
	SPECULAR = 0.55;

	if (debug_display_mode == 5 || water_interaction_debug_enabled) {
		vec3 interaction_debug_color = water_surface_interaction_debug_color_at(v_world_xz, water_interaction_surface_height);
		ALBEDO = interaction_debug_color;
		EMISSION = interaction_debug_color * 1.4;
		ALPHA = 1.0;
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
	}
}
