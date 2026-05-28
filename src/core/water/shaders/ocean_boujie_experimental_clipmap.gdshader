shader_type spatial;
// Boujie High Feature transparent screen-reading surface path.
// Keeps the Godotwind clipmap FFT vertex path, then uses Boujie-style optics
// in ocean_boujie_experimental_common.gdshaderinc.
render_mode world_vertex_coords, blend_mix, cull_disabled, shadows_disabled, depth_draw_always, diffuse_burley, specular_schlick_ggx;

#include "ocean_boujie_experimental_common.gdshaderinc"

void vertex() {
	UV = VERTEX.xz;
	float dist = length(VERTEX - CAMERA_POSITION_WORLD);
	v_vertex_dist = dist;

	float chop_accum = 0.0;
	vec3 displacement = water_surface_fft_displacement(UV, dist, chop_accum);
	vec2 shore_uv = water_surface_shore_uv(VERTEX.xz);
	bool in_mask = water_surface_shore_uv_in_bounds(shore_uv);
	vec4 shore_data = water_surface_shore_sample(shore_uv, true);
	float shore = shore_data.r;

	VERTEX += displacement * wave_scale * shore;

	vec4 shore_offset = water_surface_shore_offset(VERTEX.xz, shore_uv, in_mask, shore_data);
	vec2 shore_slope = water_surface_shore_slope(VERTEX.xz, shore_uv, in_mask, shore_data);
	VERTEX.xz += shore_offset.xy;
	VERTEX.y += shore_offset.z;
	v_shore_slope = shore_slope;
	v_shore_choppiness = shore_offset.w;
	float interaction_height = water_surface_interaction_height(VERTEX.xz);
	VERTEX.y += interaction_height;
	v_interaction_foam = water_surface_interaction_foam(VERTEX.xz);

	wave_height = displacement.y * shore + shore_offset.z + interaction_height;
	v_world_pos = VERTEX;
	v_choppiness = chop_accum * wave_scale * shore;
	v_projected_coverage = 1.0;

	vec3 tri_normal = pow(abs(NORMAL), vec3(boujie_uv_blend_sharpness));
	float tri_sum = max(dot(tri_normal, vec3(1.0)), 1e-5);
	v_boujie_uv_power_normal = tri_normal / tri_sum;
	v_boujie_uv_tri = (v_world_pos.xyz / boujie_uv_tri_scale) + boujie_uv_tri_offset;
	v_boujie_uv_tri *= vec3(1.0, -1.0, 1.0);
	v_boujie_refraction_uv_tri = v_boujie_uv_tri;
}
