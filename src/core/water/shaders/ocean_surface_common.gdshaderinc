// ============================================================================
// Shared dynamic water-surface helpers for spatial shaders.
// ============================================================================
// Adds the canonical visual water surface contract:
//   sea_level + FFT displacement * wave_scale * shore_factor
//   + analytical shore swash.
//
// Consumers must declare MAX_CASCADES plus the FFT/shore uniforms before this
// include. Imported GLSL compute shaders intentionally do not include this file.

#include "res://src/core/water/shaders/ocean_shore_common.gdshaderinc"

vec3 water_surface_fft_displacement(vec2 world_xz, float dist_to_camera, inout float chop_accum) {
	vec3 displacement = vec3(0.0);
	chop_accum = 0.0;
	for (int i = 0; i < MAX_CASCADES; ++i) {
		if (uint(i) >= num_cascades) {
			break;
		}
		vec4 scales = map_scales[i];
		float tile_size = 1.0 / max(scales.x, 1e-6);
		float cascade_fade = clamp(exp(-(dist_to_camera - 50.0) / (tile_size * 20.0)), 0.0, 1.0);
		vec3 cascade_disp = texture(displacements, vec3(world_xz * scales.xy, float(i))).xyz * scales.z * cascade_fade;
		displacement += cascade_disp;
		chop_accum += length(cascade_disp.xz);
	}
	return displacement;
}

float water_surface_dynamic_level(vec2 world_xz, float dist_to_camera, bool use_fft, bool use_shore_mask, bool include_shore_waves) {
	if (!use_fft) {
		return sea_level;
	}

	float chop_accum = 0.0;
	vec3 displacement = water_surface_fft_displacement(world_xz, dist_to_camera, chop_accum);
	vec2 shore_uv = water_surface_shore_uv(world_xz);
	bool in_mask = use_shore_mask && water_surface_shore_uv_in_bounds(shore_uv);
	vec4 shore_data = water_surface_shore_sample(shore_uv, use_shore_mask);
	float water_y = sea_level + displacement.y * wave_scale * shore_data.r;
	if (include_shore_waves) {
		water_y += water_surface_shore_offset(world_xz, shore_uv, in_mask, shore_data).z;
	}
	return water_y;
}
