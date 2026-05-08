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
	float chop_accum = 0.0;
	vec3 displacement = water_surface_fft_displacement(UV, dist, chop_accum);
	// Shore dampening — fade displacement to zero near coastline (CREST pattern).
	// Outside mask bounds (open sea) → shore = 1.0 (full waves).
	vec2 shore_uv = water_surface_shore_uv(VERTEX.xz);
	bool in_mask = water_surface_shore_uv_in_bounds(shore_uv);
	vec4 shore_data = water_surface_shore_sample(shore_uv, true);
	float shore = shore_data.r;

	VERTEX += displacement * wave_scale * shore;

	// Shore waves — analytical swash oriented perpendicular to coastline
	// (Outerra pattern). Phase driven by distance-to-shore so waves "arrive"
	// at the beach. Bell-curve amplitude: grows from zero, peaks, fades at deep.
	vec4 shore_offset = water_surface_shore_offset(VERTEX.xz, shore_uv, in_mask, shore_data);
	vec2 shore_slope = water_surface_shore_slope(VERTEX.xz, shore_uv, in_mask, shore_data);
	VERTEX.xz += shore_offset.xy;
	VERTEX.y += shore_offset.z;
	v_shore_slope = shore_slope;
	v_shore_choppiness = shore_offset.w;

	wave_height = displacement.y * shore + shore_offset.z;
	v_world_pos = VERTEX;
	v_choppiness = chop_accum * wave_scale * shore;
}
