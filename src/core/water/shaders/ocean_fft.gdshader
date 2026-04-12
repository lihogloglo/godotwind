shader_type spatial;
// Clipmap mesh path — vertex reads world-space XZ from VERTEX directly because
// `ocean_mesh.gd` snaps the mesh to a 64m grid centered on the camera. Kept
// `cull_disabled` (the clipmap mesh winding renders as the back face from
// above, so standard culling would hide the entire ocean). `depth_draw_always`
// forces depth to be written authoritatively from the main pass (fixes the
// "far sea drawn over near sea" artifact observed at ring boundaries when
// two-sided geometry went through the prepass).
render_mode world_vertex_coords, cull_disabled, shadows_disabled, depth_draw_always;

/**
 * Ocean FFT Shader — Godotwind (clipmap path)
 *
 * Entry point for the 11-ring clipmap mesh built by `ocean_mesh.gd`. All
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
	// Mesh position snapped to 64m grid by ocean_mesh.gd (scrolling clipmap)
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
	VERTEX += displacement * wave_scale;
	wave_height = displacement.y;
	v_world_pos = VERTEX;
	v_choppiness = chop_accum * wave_scale;
}
