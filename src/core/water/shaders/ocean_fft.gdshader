shader_type spatial;
// Clipmap mesh path — vertex reads world-space XZ from VERTEX directly because
// `ocean_mesh.gd` snaps the mesh to the active inner-ring grid around the camera. Kept
// `cull_disabled` (the clipmap mesh winding renders as the back face from
// above, so standard culling would hide the entire ocean). `depth_draw_always`
// forces depth to be written authoritatively from the main pass (fixes the
// "far sea drawn over near sea" artifact observed at ring boundaries when
// two-sided geometry went through the prepass).
render_mode world_vertex_coords, cull_disabled, shadows_disabled, depth_draw_always;

/**
 * Ocean FFT Shader — Godotwind (clipmap path)
 *
 * Entry point for the clipmap mesh built by `ocean_mesh.gd`. All
 * shared state (uniforms, varyings, SSR + refraction + SSS fragment, custom
 * light()) lives in `ocean_fft_common.gdshaderinc`. This file is only
 * responsible for the per-vertex path from the clipmap mesh to the displaced
 * world position.
 *
 * For the screen-space projected-grid alternative (Sea of Thieves / Wicked
 * Engine style), see `ocean_fft_projected.gdshader`.
 */

#include "ocean_fft_common.gdshaderinc"

// ============================================================================
// VERTEX — Sample FFT displacement maps at the clipmap vertex's world XZ.
// Because `render_mode world_vertex_coords` is set, `VERTEX` already arrives
// in world space (the clipmap mesh is snapped to a 64m grid around the camera
// by `ocean_mesh.gd::update_position`).
// ============================================================================
void vertex() {
	// Mesh position snapped to the active inner-ring grid by ocean_mesh.gd.
	UV = VERTEX.xz;
	// 3D distance for altitude-aware cascade fading
	float dist = length(VERTEX - CAMERA_POSITION_WORLD);
	v_vertex_dist = dist;

	// Accumulate displacement from all cascades with per-cascade distance fade.
	// Also accumulate horizontal-displacement magnitude (`chop_accum`) per
	// cascade — this is SoT's canonical wave peak mask for SSS. We sum
	// `length(cascade_displacement.xz)` instead of `length(total.xz)` so
	// opposing cascade motions don't cancel (two cascades pushing opposite
	// ways still represent sharp wave geometry, even if the sum is small).
	vec3 displacement = vec3(0);
	float chop_accum = 0.0;
	for (uint i = 0U; i < num_cascades; ++i) {
		vec4 scales = map_scales[i];
		float tile_size = 1.0 / max(scales.x, 1e-6);
		float cascade_fade = clamp(exp(-(dist - 50.0) / (tile_size * 20.0)), 0.0, 1.0);
		vec3 cascade_disp = texture(displacements, vec3(UV * scales.xy, float(i))).xyz * scales.z * cascade_fade;
		displacement += cascade_disp;
		chop_accum += length(cascade_disp.xz);
	}
	// Shore dampening — fade displacement to zero near coastline (CREST pattern).
	// Outside mask bounds (open sea) → shore = 1.0 (full waves).
	vec2 shore_uv = (VERTEX.xz - shore_mask_bounds.xy) / shore_mask_bounds.zw;
	bool in_mask = shore_uv.x >= 0.0 && shore_uv.x <= 1.0 && shore_uv.y >= 0.0 && shore_uv.y <= 1.0;
	vec4 shore_data = in_mask ? texture(shore_mask, shore_uv) : vec4(1.0, 0.5, 0.5, 1.0);
	float shore = shore_data.r;

	VERTEX += displacement * wave_scale * shore;

	// Shore waves — analytical Gerstner oriented perpendicular to coastline
	// (Outerra pattern). Phase driven by distance-to-shore so waves "arrive"
	// at the beach. Bell-curve amplitude: grows from zero, peaks, fades at deep.
	float raw_dist = shore_data.a * shore_fade_distance;
	vec2 shore_dir = in_mask ? shore_direction_from_mask(shore_uv, shore_data.gb) : vec2(0.0);
	float shore_dir_len = length(shore_dir);
	float shore_wave_y = 0.0;
	v_shore_slope = vec2(0.0);
	v_shore_choppiness = 0.0;
	if (shore_dir_len > 0.01 && shore_wave_amplitude > 0.0) {
		shore_dir /= shore_dir_len;
		// shore_dir points away from shore. Phase sign makes crests travel
		// toward decreasing distance, i.e. toward the real shoreline.
		float phase = raw_dist * shore_wave_frequency * SHORE_TAU + ocean_time * shore_wave_speed * SHORE_TAU;
		float modulation = shore_along_modulation(VERTEX.xz, shore_dir);
		float crest_phase = shore_crest_shape(phase, shore_wave_steepness);
		float breaker_env = shore_breaker_envelope(raw_dist);
		float runup_env = shore_runup_envelope(raw_dist);
		float swash = shore_swash_curve(phase);
		float mod_runup = runup_env * swash * mix(0.65, 1.0, modulation);
		float shore_y = shore_wave_amplitude * (
			breaker_env * modulation * crest_phase
			+ mod_runup * 0.32
		);
		shore_wave_y = shore_y;
		float shore_xz = shore_wave_amplitude * shore_wave_steepness * (
			breaker_env * modulation * shore_forward_push(phase, shore_wave_steepness)
			+ mod_runup * 1.10
		);
		VERTEX.y += shore_y;
		VERTEX.xz -= shore_dir * shore_xz;
		float slope = shore_wave_amplitude * shore_wave_frequency * SHORE_TAU * (
			breaker_env * modulation * shore_profile_slope(phase, shore_wave_steepness)
			+ mod_runup * 0.10 * cos(phase)
		);
		v_shore_slope = shore_dir * clamp(slope, -1.6, 1.6);
		v_shore_choppiness = abs(shore_xz) * 0.65;
	}

	wave_height = displacement.y * shore + shore_wave_y;
	v_world_pos = VERTEX;
	v_choppiness = chop_accum * wave_scale * shore;
}
