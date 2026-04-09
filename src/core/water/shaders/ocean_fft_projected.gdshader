shader_type spatial;
// Projected-grid path — the mesh is a single flat N×N grid in local [0,1]²
// coords. Every vertex unprojects its own NDC position back to a world-space
// ray, intersects the ray with the water plane (y = sea_level), then samples
// FFT displacement at that point and writes the resulting clip-space position
// into `POSITION` directly. This is the Sea of Thieves / Wicked Engine
// canonical approach (Johanson 2004).
//
// We do NOT use `world_vertex_coords` here — VERTEX stays in local [0,1]
// space and the vertex function owns the entire clip-space output via
// POSITION, bypassing the standard MVP transform.
//
// `cull_disabled` — inherited from the clipmap path for symmetry. The
// projected grid doesn't strictly need it (we write POSITION ourselves and
// winding is consistent), but fragments straddling the horizon can get weird
// facing directions under extreme camera pitch, and the cost of disabling
// culling on a 192² grid is negligible.
// `depth_draw_always` — same rationale as the clipmap path: authoritative
// depth from the main pass, no prepass ambiguity.
render_mode cull_disabled, shadows_disabled, depth_draw_always;

/**
 * Ocean FFT Shader — Godotwind (projected-grid path)
 *
 * Entry point for the flat N×N grid mesh built by
 * `ocean_mesh.gd::_create_projected_mesh`. All shared state (uniforms,
 * varyings, SSR + refraction + SSS fragment, custom light()) lives in
 * `ocean_fft_common.gdshaderinc`. This file only owns the screen-space
 * unproject + ray-plane intersect vertex path.
 *
 * Reference:
 *   - Claes Johanson, "Real-time water rendering — Introducing the projected
 *     grid concept", 2004 (Lund University).
 *   - Wicked Engine `oceanSurfaceVS.hlsl` (public repo, MIT).
 *   - Sea of Thieves GDC talk, "Technical Art of Sea of Thieves" (Rare Ltd.).
 */

#include "ocean_fft_common.gdshaderinc"

// Max world-space distance to clamp a grid vertex to when its ray doesn't
// intersect the water plane (ray pointing up, or parallel). The vertex is
// pushed to this distance in the ray's XZ direction at y = sea_level, so the
// resulting triangle still produces a valid horizon silhouette instead of
// diverging to NaN / infinity.
const float PROJECTED_GRID_FAR_HORIZON = 20000.0;

// Overscan factor — how far BEYOND the standard [-1,1] NDC range the grid
// extends. At 1.0 the grid exactly covers the screen (and single-pixel gaps
// appear at the edges because the outermost vertices map to the screen edge
// without any margin). At 1.15 the grid extends 15% beyond the frustum on
// all sides, which gives enough overlap to hide quantization + camera
// rotation artifacts at the screen edges. Canonical Wicked Engine value
// is ~1.1-1.2. Exposed as a uniform so it can be tuned at runtime.
uniform float projected_grid_overscan : hint_range(1.0, 1.5) = 1.15;

// ============================================================================
// VERTEX — Unproject grid vertex from NDC → world ray → water plane.
// ============================================================================
// Each vertex of the flat mesh stores a grid-space coordinate in VERTEX.xz in
// the range [0,1]² (set at mesh build time). We treat that as a normalized
// screen coordinate, build two clip-space endpoints (near + far) at the
// matching NDC, transform them to world space via `INV_VIEW_MATRIX *
// INV_PROJECTION_MATRIX`, then intersect the resulting ray with the
// water plane y = sea_level to get the world-space foot of the vertex.
//
// Godot 4.6 Forward+ uses infinite reversed-Z: the near plane is at NDC z=1,
// the far plane at z=0. The `inv_vp` transform preserves homogeneous w so
// we must divide after multiplication, not before.
//
// Degenerate cases:
//   - Ray points up (ray_dir.y > -eps) → clamp to horizon in XZ direction.
//   - Intersection is behind the camera (t < 0) → same clamp.
//   - Intersection is beyond PROJECTED_GRID_FAR_HORIZON → clamp to keep FFT
//     sampling in a sane range (texture lookups still wrap, but the distance
//     fade in the cascade loop will have fully attenuated anyway).
// ============================================================================
void vertex() {
	// Grid coordinate in [0,1]² → NDC in [-overscan, +overscan]²
	// Standard remap `grid_uv * 2 - 1` maps [0,1] → [-1,1] exactly at the
	// frustum edges. That leaves no margin for camera rotation / numerical
	// precision — the outermost vertices project to the screen edge and
	// single-pixel gaps appear when the camera swings. Multiplying by
	// `projected_grid_overscan` pushes the grid slightly BEYOND the visible
	// frustum on all sides so there's always overlap.
	vec2 grid_uv = VERTEX.xz;
	vec2 ndc = (grid_uv - 0.5) * 2.0 * projected_grid_overscan;

	// Inverse view-projection: NDC + homogeneous depth → world space.
	mat4 inv_vp = INV_VIEW_MATRIX * INV_PROJECTION_MATRIX;

	// Reversed-Z: NDC z=1 at near, z=0 at far. Build both endpoints and
	// divide by w to land in world space.
	vec4 near_h = inv_vp * vec4(ndc, 1.0, 1.0);
	vec4 far_h  = inv_vp * vec4(ndc, 0.0, 1.0);
	vec3 near_w = near_h.xyz / near_h.w;
	vec3 far_w  = far_h.xyz  / far_h.w;
	vec3 ray_o = near_w;
	vec3 ray_d = normalize(far_w - near_w);

	// Ray-plane intersect with y = sea_level. Expect ray_d.y < 0 (camera
	// looking DOWN at the water) for a valid hit; fall back to a distant
	// horizon clamp for any upward / parallel / behind-camera case.
	vec3 world_pos;
	if (ray_d.y > -1e-4) {
		vec2 horiz_dir = length(ray_d.xz) > 1e-5 ? normalize(ray_d.xz) : vec2(0.0, 1.0);
		world_pos = vec3(
			ray_o.x + horiz_dir.x * PROJECTED_GRID_FAR_HORIZON,
			sea_level,
			ray_o.z + horiz_dir.y * PROJECTED_GRID_FAR_HORIZON
		);
	} else {
		float t = (sea_level - ray_o.y) / ray_d.y;
		if (t < 0.0) {
			vec2 horiz_dir = length(ray_d.xz) > 1e-5 ? normalize(ray_d.xz) : vec2(0.0, 1.0);
			world_pos = vec3(
				ray_o.x + horiz_dir.x * PROJECTED_GRID_FAR_HORIZON,
				sea_level,
				ray_o.z + horiz_dir.y * PROJECTED_GRID_FAR_HORIZON
			);
		} else {
			world_pos = ray_o + ray_d * t;
			// Distance clamp: keep FFT sampling bounded.
			float dist_xz = length(world_pos.xz - ray_o.xz);
			if (dist_xz > PROJECTED_GRID_FAR_HORIZON) {
				vec2 horiz_dir = normalize(world_pos.xz - ray_o.xz);
				world_pos = vec3(
					ray_o.x + horiz_dir.x * PROJECTED_GRID_FAR_HORIZON,
					sea_level,
					ray_o.z + horiz_dir.y * PROJECTED_GRID_FAR_HORIZON
				);
			}
		}
	}

	// From here on, the logic is identical to the clipmap path — sample FFT
	// displacement at the world XZ we just computed, accumulate choppiness
	// for SSS, and write v_world_pos + v_choppiness for the fragment stage.
	UV = world_pos.xz;
	v_shore_factor = sample_shore(world_pos.xz);
	float dist = length(world_pos - CAMERA_POSITION_WORLD);
	v_vertex_dist = dist;
	float shore = v_shore_factor * wave_scale;

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
	world_pos += displacement * shore;
	world_pos.y += 0.15; // slight bias prevents z-fighting with terrain
	wave_height = displacement.y;
	v_world_pos = world_pos;
	v_choppiness = chop_accum * shore;

	// Write POSITION directly — bypasses the default `PROJECTION_MATRIX *
	// MODELVIEW_MATRIX * vec4(VERTEX, 1.0)` Godot applies. The MeshInstance3D
	// transform is irrelevant in this mode; the mesh stays at origin with
	// identity basis and the vertex shader owns the full clip-space output.
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_pos, 1.0);
}
