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

struct WaterSurfaceContractSample {
	float y;
	vec2 horizontal_offset;
	float coverage;
	float body_gate;
	float depth;
};

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

vec3 water_surface_dynamic_sample_raw(vec2 sample_xz, float dist_to_camera, bool use_fft, bool use_shore_mask, bool include_shore_waves) {
	if (!use_fft) {
		return vec3(sea_level, 0.0, 0.0);
	}

	float chop_accum = 0.0;
	vec3 displacement = water_surface_fft_displacement(sample_xz, dist_to_camera, chop_accum);
	vec2 shore_uv = water_surface_shore_uv(sample_xz);
	bool in_mask = use_shore_mask && water_surface_shore_uv_in_bounds(shore_uv);
	vec4 shore_data = water_surface_shore_sample(shore_uv, use_shore_mask);
	float water_y = sea_level + displacement.y * wave_scale * shore_data.r;
	vec2 horizontal_offset = displacement.xz * wave_scale * shore_data.r;
	if (include_shore_waves) {
		vec4 shore_offset = water_surface_shore_offset(sample_xz, shore_uv, in_mask, shore_data);
		horizontal_offset += shore_offset.xy;
		water_y += shore_offset.z;
	}
	return vec3(water_y, horizontal_offset.x, horizontal_offset.y);
}

float water_surface_dynamic_level(vec2 final_xz, float dist_to_camera, bool use_fft, bool use_shore_mask, bool include_shore_waves) {
	if (!use_fft) {
		return sea_level;
	}

	vec2 sample_xz = final_xz;
	for (int i = 0; i < 2; ++i) {
		vec3 sample = water_surface_dynamic_sample_raw(sample_xz, dist_to_camera, use_fft, use_shore_mask, include_shore_waves);
		sample_xz = final_xz - sample.yz;
	}
	return water_surface_dynamic_sample_raw(sample_xz, dist_to_camera, use_fft, use_shore_mask, include_shore_waves).x;
}

float water_surface_body_coverage(vec2 world_xz, bool use_fft, bool use_shore_mask, bool include_shore_waves) {
	vec2 shore_uv = water_surface_shore_uv(world_xz);
	vec4 shore_data = water_surface_shore_sample(shore_uv, use_shore_mask);
	float coverage = shore_data.r;
	if (include_shore_waves) {
		float dynamic_level = water_surface_dynamic_level(world_xz, 0.0, use_fft, use_shore_mask, true);
		float runup_hint = smoothstep(0.015, 0.12, max(dynamic_level - sea_level, 0.0));
		coverage = max(coverage, runup_hint * 0.45);
	}
	return clamp(coverage, 0.0, 1.0);
}

float water_surface_body_gate(float coverage) {
	return smoothstep(0.015, 0.12, coverage);
}

WaterSurfaceContractSample water_surface_query(
	vec3 world_pos,
	float dist_to_camera,
	bool use_fft,
	bool use_shore_mask,
	bool include_shore_waves
) {
	WaterSurfaceContractSample result;
	vec3 raw = water_surface_dynamic_sample_raw(
		world_pos.xz,
		dist_to_camera,
		use_fft,
		use_shore_mask,
		include_shore_waves
	);
	result.y = water_surface_dynamic_level(
		world_pos.xz,
		dist_to_camera,
		use_fft,
		use_shore_mask,
		include_shore_waves
	);
	result.horizontal_offset = raw.yz;
	result.coverage = water_surface_body_coverage(world_pos.xz, use_fft, use_shore_mask, include_shore_waves);
	result.body_gate = water_surface_body_gate(result.coverage);
	result.depth = result.y - world_pos.y;
	return result;
}
