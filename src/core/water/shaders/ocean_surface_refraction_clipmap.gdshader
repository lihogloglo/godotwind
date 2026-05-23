shader_type spatial;
render_mode world_vertex_coords, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

const int MAX_CASCADES = 4;

global uniform uint num_cascades;
global uniform sampler2DArray displacements;
global uniform sampler2DArray normals;

uniform vec4 map_scales[MAX_CASCADES];
uniform sampler2D shore_mask;
uniform vec4 shore_mask_bounds = vec4(-50000.0, -50000.0, 100000.0, 100000.0);
uniform float shore_fade_distance = 50.0;
uniform float shore_wave_amplitude = 0.0;
uniform float shore_wave_frequency = 0.1;
uniform float shore_wave_speed = 0.4;
uniform float shore_wave_steepness = 0.58;
uniform float ocean_time = 0.0;
uniform float sea_level = 0.0;
uniform float wave_scale = 1.0;

uniform sampler2D source_color_texture : filter_linear_mipmap, repeat_disable;
uniform float source_valid = 0.0;
uniform float source_resolution_scale = 0.5;
uniform float refraction_strength : hint_range(0.0, 1.0) = 0.45;
uniform float edge_guard_strength : hint_range(0.0, 1.0) = 1.0;
uniform float max_refr_thickness : hint_range(0.1, 5.0) = 1.5;
uniform float overlay_opacity : hint_range(0.0, 1.0) = 0.42;
uniform vec3 medium_color : source_color = vec3(0.02, 0.04, 0.06);
uniform vec3 extinction_sigma = vec3(0.08, 0.02, 0.012);

varying vec3 v_world_pos;
varying float v_vertex_dist;
varying vec2 v_shore_slope;
varying float v_coverage;

#include "ocean_surface_common.gdshaderinc"

vec3 sample_surface_gradient(vec2 world_xz) {
	float map_size = float(textureSize(normals, 0).x);
	vec3 gradient = vec3(0.0);
	for (uint i = 0U; i < num_cascades; ++i) {
		vec4 scales = map_scales[i];
		vec3 coords = vec3(world_xz * scales.xy, float(i));
		float ppm = map_size * min(scales.x, scales.y);
		gradient += texture(normals, coords).xyw * vec3(scales.ww, 1.0) * min(1.0, ppm * 0.1);
	}
	gradient.xy += v_shore_slope;
	return gradient;
}

void vertex() {
	UV = VERTEX.xz;
	v_vertex_dist = length(VERTEX - CAMERA_POSITION_WORLD);

	float chop_accum = 0.0;
	vec3 displacement = water_surface_fft_displacement(UV, v_vertex_dist, chop_accum);
	vec2 shore_uv = water_surface_shore_uv(VERTEX.xz);
	bool in_mask = water_surface_shore_uv_in_bounds(shore_uv);
	vec4 shore_data = water_surface_shore_sample(shore_uv, true);
	float shore = shore_data.r;

	VERTEX += displacement * wave_scale * shore;
	vec4 shore_offset = water_surface_shore_offset(VERTEX.xz, shore_uv, in_mask, shore_data);
	v_shore_slope = water_surface_shore_slope(VERTEX.xz, shore_uv, in_mask, shore_data);
	VERTEX.xz += shore_offset.xy;
	VERTEX.y += shore_offset.z + 0.025;

	v_world_pos = VERTEX;
	v_coverage = water_surface_body_gate(water_surface_shore_body_coverage(shore_data));
}


vec2 refraction_offset(vec3 view_normal) {
	vec3 gradient = sample_surface_gradient(v_world_pos.xz);
	vec2 raw_offset = vec2(-gradient.x, -gradient.y) + view_normal.xy * 0.25;
	if (dot(raw_offset, raw_offset) <= 1e-8) {
		return vec2(0.0);
	}
	vec2 normal_offset = normalize(raw_offset);
	return normal_offset * refraction_strength * max_refr_thickness * 0.018;
}


void fragment() {
	if (source_valid < 0.5 || refraction_strength <= 0.001 || overlay_opacity <= 0.001) {
		discard;
	}

	vec3 gradient = sample_surface_gradient(v_world_pos.xz);
	vec3 world_normal = normalize(vec3(-gradient.x, 1.0, -gradient.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);
	float fresnel = pow(1.0 - max(dot(VIEW, NORMAL), 0.0), 5.0);
	float face_gate = 1.0 - smoothstep(0.60, 0.98, fresnel);
	float edge_t = clamp(length((SCREEN_UV - 0.5) * 2.0), 0.0, 1.0);
	float screen_gate = mix(1.0, 1.0 - smoothstep(0.72, 1.0, edge_t), edge_guard_strength);

	vec2 offset = refraction_offset(NORMAL) * face_gate * screen_gate;
	vec2 refr_uv = clamp(SCREEN_UV + offset, vec2(0.001), vec2(0.999));
	vec3 straight_source = texture(source_color_texture, SCREEN_UV).rgb;
	vec3 refracted_source = texture(source_color_texture, refr_uv).rgb;
	float delta_gate = smoothstep(0.015, 0.090, length(refracted_source - straight_source));
	float optical_depth = max_refr_thickness * mix(0.35, 1.0, face_gate);
	vec3 transmittance = exp(-extinction_sigma * optical_depth);
	vec3 refracted_water = refracted_source * transmittance + medium_color * (vec3(1.0) - transmittance);
	float source_gate = mix(0.35, 1.0, delta_gate);
	float alpha = overlay_opacity * face_gate * screen_gate * v_coverage * source_gate;

	ALBEDO = refracted_water;
	ALPHA = alpha;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.0;
}
