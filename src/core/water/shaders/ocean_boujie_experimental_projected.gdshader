shader_type spatial;
// Boujie High Feature transparent screen-reading surface path.
// Keeps the Godotwind projected-grid vertex path, then uses Boujie-style
// optics in ocean_boujie_experimental_common.gdshaderinc.
render_mode blend_mix, cull_disabled, shadows_disabled, depth_draw_always, diffuse_burley, specular_schlick_ggx;

#include "ocean_boujie_experimental_common.gdshaderinc"

const float PROJECTED_GRID_FAR_HORIZON = 20000.0;
const float PROJECTED_GRID_FADE_START = 12000.0;
uniform float projected_grid_overscan : hint_range(1.0, 1.5) = 1.15;

void vertex() {
	vec2 grid_uv = VERTEX.xz;
	vec2 ndc = (grid_uv - 0.5) * 2.0 * projected_grid_overscan;

	mat4 inv_vp = INV_VIEW_MATRIX * INV_PROJECTION_MATRIX;
	vec4 near_h = inv_vp * vec4(ndc, 1.0, 1.0);
	vec4 far_h = inv_vp * vec4(ndc, 0.0, 1.0);
	vec3 near_w = near_h.xyz / near_h.w;
	vec3 far_w = far_h.xyz / far_h.w;
	vec3 ray_o = near_w;
	vec3 ray_d = normalize(far_w - near_w);

	vec3 world_pos;
	float projected_coverage = 1.0;
	if (ray_d.y > -1e-4) {
		vec2 horiz_dir = length(ray_d.xz) > 1e-5 ? normalize(ray_d.xz) : vec2(0.0, 1.0);
		world_pos = vec3(
			ray_o.x + horiz_dir.x * PROJECTED_GRID_FAR_HORIZON,
			sea_level,
			ray_o.z + horiz_dir.y * PROJECTED_GRID_FAR_HORIZON
		);
		projected_coverage = 0.0;
	} else {
		float t = (sea_level - ray_o.y) / ray_d.y;
		if (t < 0.0) {
			vec2 horiz_dir = length(ray_d.xz) > 1e-5 ? normalize(ray_d.xz) : vec2(0.0, 1.0);
			world_pos = vec3(
				ray_o.x + horiz_dir.x * PROJECTED_GRID_FAR_HORIZON,
				sea_level,
				ray_o.z + horiz_dir.y * PROJECTED_GRID_FAR_HORIZON
			);
			projected_coverage = 0.0;
		} else {
			world_pos = ray_o + ray_d * t;
			float dist_xz = length(world_pos.xz - ray_o.xz);
			if (dist_xz > PROJECTED_GRID_FAR_HORIZON) {
				vec2 horiz_dir = normalize(world_pos.xz - ray_o.xz);
				world_pos = vec3(
					ray_o.x + horiz_dir.x * PROJECTED_GRID_FAR_HORIZON,
					sea_level,
					ray_o.z + horiz_dir.y * PROJECTED_GRID_FAR_HORIZON
				);
				projected_coverage = 0.0;
			} else {
				projected_coverage = 1.0 - smoothstep(PROJECTED_GRID_FADE_START, PROJECTED_GRID_FAR_HORIZON, dist_xz);
			}
		}
	}

	UV = world_pos.xz;
	float dist = length(world_pos - CAMERA_POSITION_WORLD);
	v_vertex_dist = dist;

	float chop_accum = 0.0;
	vec3 displacement = water_surface_fft_displacement(UV, dist, chop_accum);
	vec2 shore_uv = water_surface_shore_uv(world_pos.xz);
	bool in_mask = water_surface_shore_uv_in_bounds(shore_uv);
	vec4 shore_data = water_surface_shore_sample(shore_uv, true);
	float shore = shore_data.r;

	world_pos += displacement * wave_scale * shore * projected_coverage;

	vec4 shore_offset = water_surface_shore_offset(world_pos.xz, shore_uv, in_mask, shore_data);
	vec2 shore_slope = water_surface_shore_slope(world_pos.xz, shore_uv, in_mask, shore_data);
	world_pos.xz += shore_offset.xy;
	world_pos.y += shore_offset.z;
	v_shore_slope = shore_slope;
	v_shore_choppiness = shore_offset.w;
	float interaction_height = water_surface_interaction_height(world_pos.xz) * projected_coverage;
	world_pos.y += interaction_height;
	v_interaction_foam = water_surface_interaction_foam(world_pos.xz) * projected_coverage;

	wave_height = displacement.y * shore * projected_coverage + shore_offset.z + interaction_height;
	v_world_pos = world_pos;
	v_choppiness = chop_accum * wave_scale * shore * projected_coverage;
	v_projected_coverage = projected_coverage;

	vec3 tri_normal = pow(abs(vec3(0.0, 1.0, 0.0)), vec3(boujie_uv_blend_sharpness));
	float tri_sum = max(dot(tri_normal, vec3(1.0)), 1e-5);
	v_boujie_uv_power_normal = tri_normal / tri_sum;
	v_boujie_uv_tri = (v_world_pos.xyz / boujie_uv_tri_scale) + boujie_uv_tri_offset;
	v_boujie_uv_tri *= vec3(1.0, -1.0, 1.0);
	v_boujie_refraction_uv_tri = v_boujie_uv_tri;

	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_pos, 1.0);
}
