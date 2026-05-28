shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

#include "res://src/core/water/shaders/water_interaction_common.gdshaderinc"
#include "res://src/core/water/shaders/water_surface_optics_common.gdshaderinc"

group_uniforms color;
uniform vec4 water_color : source_color = vec4(0.035, 0.18, 0.22, 1.0);
uniform vec3 medium_color : source_color = vec3(0.02, 0.04, 0.05);
uniform vec3 foam_color : source_color = vec3(0.82, 0.90, 0.88);

group_uniforms optics;
uniform float visibility_distance_m : hint_range(0.5, 300.0) = 32.0;
uniform float absorption_density : hint_range(0.01, 2.0) = 0.26;
uniform float refraction_strength : hint_range(0.0, 0.4) = 0.065;
uniform float roughness : hint_range(0.0, 1.0) = 0.065;
uniform float edge_fade_distance : hint_range(0.01, 4.0) = 0.45;

group_uniforms flow;
uniform sampler2D normal_bump_texture : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D foam_texture : filter_linear_mipmap, repeat_enable;
uniform float flow_speed : hint_range(0.0, 10.0) = 1.0;
uniform float flowmap_max_speed_mps : hint_range(0.1, 20.0) = 6.0;
uniform float flow_normal_strength : hint_range(0.0, 3.0) = 1.15;
uniform float flow_uv_scale : hint_range(0.01, 2.0) = 0.16;
uniform float bank_foam_strength : hint_range(0.0, 2.0) = 0.62;
uniform float pressure_strength : hint_range(0.0, 2.0) = 0.45;
uniform float bend_foam_strength : hint_range(0.0, 2.0) = 0.28;
uniform sampler2D flowmap_texture : filter_linear, repeat_disable;
uniform vec4 flowmap_region_bounds = vec4(0.0, 0.0, 1.0, 1.0); // min_x, min_z, size_x, size_z
uniform bool flowmap_enabled = false;
uniform float river_time = 0.0;
uniform int debug_display_mode = 0;

varying vec2 v_flow_dir;
varying float v_bank_distance;
varying float v_bank_foam;
varying vec3 v_world_pos;

vec3 flow_uvw(vec2 uv_in, vec2 flow_vector, vec2 jump, vec2 tiling, float phase_time, bool flow_b) {
	float phase_offset = flow_b ? 0.5 : 0.0;
	float progress = fract(phase_time + phase_offset);
	vec3 uvw;
	uvw.xy = uv_in - flow_vector * (progress - 0.5);
	uvw.xy *= tiling;
	uvw.xy += phase_offset;
	uvw.xy += (phase_time - progress) * jump;
	uvw.z = 1.0 - abs(1.0 - 2.0 * progress);
	return uvw;
}

vec4 river_flowmap_sample(vec2 world_xz) {
	if (!flowmap_enabled) {
		return vec4(0.5, 0.5, 0.0, 0.0);
	}
	vec2 uv = (world_xz - flowmap_region_bounds.xy) / max(flowmap_region_bounds.zw, vec2(0.001));
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
		return vec4(0.5, 0.5, 0.0, 0.0);
	}
	return texture(flowmap_texture, uv);
}

vec3 direction_debug_color(vec2 dir) {
	float angle = atan(dir.y, dir.x);
	return vec3(
		0.5 + 0.5 * cos(angle),
		0.5 + 0.5 * cos(angle - 2.09439510239),
		0.5 + 0.5 * cos(angle + 2.09439510239)
	);
}

float debug_grid_line(float value, float scale) {
	float f = fract(value * scale);
	float w = max(fwidth(value * scale), 0.001);
	return 1.0 - smoothstep(0.0, w * 1.5, min(f, 1.0 - f));
}

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 vertex_flow = COLOR.rg * 2.0 - 1.0;
	if (length(vertex_flow) < 0.001) {
		v_flow_dir = vec2(0.0, 1.0);
	} else {
		v_flow_dir = normalize(vertex_flow);
	}
	v_bank_distance = clamp(COLOR.b, 0.0, 1.0);
	v_bank_foam = clamp(COLOR.a, 0.0, 1.0);

	VERTEX.y += water_surface_interaction_height_at(v_world_pos.xz, v_world_pos.y);
}

void fragment() {
	vec4 flowmap_sample = river_flowmap_sample(v_world_pos.xz);
	float flowmap_coverage = clamp(flowmap_sample.a, 0.0, 1.0);
	vec2 flowmap_encoded_dir = flowmap_sample.rg * 2.0 - 1.0;
	float flowmap_speed_mps = max(flowmap_sample.b, 0.0) * flowmap_max_speed_mps;
	vec2 flowmap_velocity = flowmap_encoded_dir * flowmap_speed_mps;
	float flowmap_velocity_len = length(flowmap_velocity);
	bool flowmap_valid = flowmap_coverage > 0.015 && flowmap_velocity_len > 0.015;
	vec2 flowmap_dir = v_flow_dir;
	if (flowmap_valid) {
		flowmap_dir = flowmap_velocity / flowmap_velocity_len;
	}
	float flowmap_coverage_weight = smoothstep(0.015, 0.22, flowmap_coverage);
	float flowmap_speed_weight = smoothstep(0.015, 0.12, flowmap_velocity_len);
	float flowmap_weight = flowmap_valid ? flowmap_coverage_weight * flowmap_speed_weight : 0.0;
	vec2 curve_velocity = v_flow_dir * flow_speed;
	vec2 base_velocity = mix(curve_velocity, flowmap_velocity, flowmap_weight);
	float base_flow_speed = length(base_velocity);
	vec2 base_flow_dir = base_flow_speed > 0.001 ? base_velocity / base_flow_speed : v_flow_dir;
	float direction_mismatch = clamp(1.0 - dot(v_flow_dir, flowmap_dir), 0.0, 2.0) * 0.5 * flowmap_weight;
	vec4 dynamic_flow_sample = water_surface_dynamic_flow_sample_at(v_world_pos.xz, v_world_pos.y);
	vec2 dynamic_flow_delta = dynamic_flow_sample.rg;
	vec2 combined_velocity = base_velocity + dynamic_flow_delta;
	float effective_flow_speed = length(combined_velocity);
	vec2 flow_dir = effective_flow_speed > 0.001 ? combined_velocity / effective_flow_speed : base_flow_dir;
	float flow_speed_scale = effective_flow_speed / max(flow_speed, 0.001);
	vec2 river_flow_uv = vec2((UV.x - 0.5) * 2.15, UV.y * flow_uv_scale);
	float dynamic_energy = water_surface_dynamic_flow_energy_at(v_world_pos.xz, v_world_pos.y);
	float pressure = 1.0 + (1.0 - v_bank_distance) * pressure_strength + dynamic_energy * 0.35;
	vec2 flow = vec2(0.0, 1.0) * pressure * max(flow_speed_scale, 0.01);
	float phase_time = river_time * max(effective_flow_speed, 0.01) * 0.18;

	vec3 uv_a = flow_uvw(river_flow_uv, flow, vec2(0.24, 0.208333), vec2(1.0), phase_time, false);
	vec3 uv_b = flow_uvw(river_flow_uv, flow, vec2(0.24, 0.208333), vec2(1.0), phase_time, true);
	vec3 uv_c = flow_uvw(river_flow_uv, flow, vec2(0.20, 0.25), vec2(2.2), phase_time, false);
	vec3 uv_d = flow_uvw(river_flow_uv, flow, vec2(0.20, 0.25), vec2(2.2), phase_time, true);

	vec3 n0 = texture(normal_bump_texture, uv_a.xy).rgb * uv_a.z + texture(normal_bump_texture, uv_b.xy).rgb * uv_b.z;
	vec3 n1 = texture(normal_bump_texture, uv_c.xy).rgb * uv_c.z + texture(normal_bump_texture, uv_d.xy).rgb * uv_d.z;
	vec2 normal_rg = mix(n0.rg, n1.rg, 0.36);
	vec2 aligned_ripple_uv = vec2((UV.x - 0.5) * 4.0, UV.y * flow_uv_scale * 2.35 - river_time * max(effective_flow_speed, 0.01) * 0.11);
	vec2 aligned_ripple_rg = texture(normal_bump_texture, aligned_ripple_uv).rg;
	normal_rg = mix(normal_rg, aligned_ripple_rg, 0.18 * smoothstep(0.35, 2.5, effective_flow_speed));
	vec2 ripple_gradient = water_surface_interaction_gradient_at(v_world_pos.xz, v_world_pos.y);
	vec2 micro_normal = water_surface_micro_normal(v_world_pos.xz, flow_dir, effective_flow_speed);
	float normal_boost = 1.0 + dynamic_energy * 0.75 + direction_mismatch * 0.35 + (1.0 - v_bank_distance) * 0.18;
	vec2 normal_xy = normal_rg * flow_normal_strength * normal_boost + micro_normal * 0.55 + ripple_gradient;
	NORMAL_MAP = vec3(normal_xy, 1.0);
	NORMAL_MAP_DEPTH = 0.85;
	if (water_interaction_enabled) {
		vec3 ripple_world_normal = normalize(vec3(-ripple_gradient.x, 1.0, -ripple_gradient.y));
		vec3 ripple_view_normal = normalize((VIEW_MATRIX * vec4(ripple_world_normal, 0.0)).xyz);
		NORMAL = normalize(mix(NORMAL, ripple_view_normal, clamp(length(ripple_gradient) * 0.55, 0.0, 0.85)));
	}

	vec4 surf_view4 = VIEW_MATRIX * vec4(v_world_pos, 1.0);
	vec3 surf_view = surf_view4.xyz / max(surf_view4.w, 0.00001);
	bool sky_or_far = false;
	float water_depth = water_surface_thickness(SCREEN_UV, surf_view, INV_PROJECTION_MATRIX, sky_or_far);

	float bank_foam = v_bank_foam * bank_foam_strength;
	float bend_noise = texture(foam_texture, river_flow_uv * vec2(0.65, 0.42) - vec2(0.0, 1.0) * river_time * 0.04 * max(effective_flow_speed, 0.01)).r;
	float streak = smoothstep(0.56, 0.95, n0.b * n1.b) * smoothstep(0.15, 0.85, bend_noise);
	float ripple_foam = water_surface_interaction_foam_at(v_world_pos.xz, v_world_pos.y) * 0.65;
	float foam_detail = water_surface_foam_detail(v_world_pos.xz, flow_dir, effective_flow_speed);
	float flow_foam = dynamic_energy * 0.45 + direction_mismatch * bend_foam_strength * 0.35;
	float foam = clamp(bank_foam + streak * bend_foam_strength * mix(0.55, 1.0, foam_detail) + ripple_foam + flow_foam, 0.0, 1.0);

	float edge_factor = 1.0 - smoothstep(0.0, edge_fade_distance, water_depth);
	float fresnel = 0.0;
	vec3 refracted_color = vec3(0.0);
	ALBEDO = water_surface_optical_color(surf_view, NORMAL, VIEW, SCREEN_UV, INV_PROJECTION_MATRIX, normal_xy, flow_dir, effective_flow_speed, foam, edge_factor, fresnel, refracted_color);
	ALPHA = clamp(mix(0.74, 1.0, fresnel + foam + edge_factor * 0.2), 0.0, 1.0);
	ROUGHNESS = water_surface_roughness + foam * 0.28;
	METALLIC = 0.0;
	SPECULAR = 0.5;
	if (debug_display_mode == 1) {
		ALBEDO = direction_debug_color(flow_dir);
		EMISSION = ALBEDO * 0.85;
		ALPHA = 1.0;
	} else if (debug_display_mode == 2) {
		float speed_debug = clamp(effective_flow_speed / max(flowmap_max_speed_mps, 0.001), 0.0, 1.0);
		vec3 slow_color = vec3(0.02, 0.18, 0.92);
		vec3 mid_color = vec3(0.95, 0.86, 0.18);
		vec3 fast_color = vec3(1.0, 0.16, 0.05);
		ALBEDO = mix(mix(slow_color, mid_color, smoothstep(0.0, 0.58, speed_debug)), fast_color, smoothstep(0.58, 1.0, speed_debug));
		EMISSION = ALBEDO * 0.75;
		ALPHA = 1.0;
	} else if (debug_display_mode == 3) {
		ALBEDO = vec3(flowmap_coverage, flowmap_coverage, flowmap_coverage);
		EMISSION = ALBEDO * 0.4;
		ALPHA = 1.0;
	} else if (debug_display_mode == 4) {
		ALBEDO = mix(vec3(0.90, 0.22, 0.10), vec3(0.04, 0.34, 0.92), v_bank_distance);
		EMISSION = ALBEDO * 0.45;
		ALPHA = 1.0;
	} else if (debug_display_mode == 5 || water_interaction_debug_enabled) {
		vec3 interaction_debug_color = water_surface_interaction_debug_color_at(v_world_pos.xz, v_world_pos.y);
		ALBEDO = interaction_debug_color;
		EMISSION = interaction_debug_color * 1.4;
		ALPHA = 1.0;
		ROUGHNESS = 1.0;
		METALLIC = 0.0;
		SPECULAR = 0.0;
	} else if (debug_display_mode == 6) {
		ALBEDO = vec3(
			0.5 + dynamic_flow_delta.x * 0.2,
			dynamic_energy,
			0.5 + dynamic_flow_delta.y * 0.2
		);
		EMISSION = ALBEDO * 1.2;
		ALPHA = 1.0;
	} else if (debug_display_mode == 7) {
		ALBEDO = mix(direction_debug_color(base_flow_dir), vec3(1.0, 0.1, 0.85), smoothstep(0.25, 0.95, direction_mismatch));
		EMISSION = ALBEDO * 0.9;
		ALPHA = 1.0;
	} else if (debug_display_mode == 8) {
		float across_line = debug_grid_line(UV.x, 8.0);
		float along_line = debug_grid_line(UV.y, 0.25);
		vec3 uv_color = vec3(UV.x, fract(UV.y * 0.05), UV2.x);
		ALBEDO = mix(uv_color, vec3(1.0), max(across_line, along_line));
		EMISSION = ALBEDO * 0.7;
		ALPHA = 1.0;
	} else if (debug_display_mode == 9) {
		float basis_jump = clamp((length(dFdx(flow_dir)) + length(dFdy(flow_dir))) * 18.0, 0.0, 1.0);
		float speed_jump = clamp(fwidth(effective_flow_speed) * 4.0, 0.0, 1.0);
		vec3 basis_color = direction_debug_color(flow_dir);
		ALBEDO = mix(basis_color, vec3(1.0, 0.05, 0.0), max(basis_jump, speed_jump));
		EMISSION = ALBEDO * mix(0.55, 1.6, max(basis_jump, speed_jump));
		ALPHA = 1.0;
	} else if (debug_display_mode == 10) {
		vec2 debug_uv = river_flow_uv;
		float u_line = debug_grid_line(debug_uv.x, 1.0);
		float v_line = debug_grid_line(debug_uv.y, 1.0);
		ALBEDO = vec3(fract(debug_uv.x), fract(debug_uv.y), 0.18);
		ALBEDO = mix(ALBEDO, vec3(1.0), max(u_line, v_line));
		EMISSION = ALBEDO * 0.8;
		ALPHA = 1.0;
	} else if (debug_display_mode == 11) {
		ALBEDO = direction_debug_color(base_flow_dir);
		EMISSION = ALBEDO * 0.85;
		ALPHA = 1.0;
	} else if (debug_display_mode == 12) {
		vec3 invalid = vec3(0.05, 0.05, 0.05);
		vec3 valid = direction_debug_color(flowmap_valid ? flowmap_dir : vec2(0.0, 1.0));
		ALBEDO = mix(invalid, valid, flowmap_coverage);
		EMISSION = ALBEDO * 0.9;
		ALPHA = 1.0;
	} else if (debug_display_mode == 13) {
		float raw_speed = clamp(flowmap_velocity_len / max(flowmap_max_speed_mps, 0.001), 0.0, 1.0);
		vec3 slow_color = vec3(0.02, 0.12, 0.85);
		vec3 mid_color = vec3(0.10, 0.95, 0.28);
		vec3 fast_color = vec3(1.0, 0.95, 0.02);
		ALBEDO = mix(mix(slow_color, mid_color, smoothstep(0.0, 0.55, raw_speed)), fast_color, smoothstep(0.55, 1.0, raw_speed));
		EMISSION = ALBEDO * 1.0;
		ALPHA = 1.0;
	}
}
