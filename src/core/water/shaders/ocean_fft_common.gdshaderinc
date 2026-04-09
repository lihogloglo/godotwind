// ============================================================================
// ocean_fft_common.gdshaderinc — shared state + fragment + light
// ============================================================================
// Included by BOTH `ocean_fft.gdshader` (clipmap mesh path) and
// `ocean_fft_projected.gdshader` (Sea of Thieves / Wicked Engine screen-space
// projected grid path). Contains every piece of the ocean surface shader that
// does NOT depend on how vertices reach the water plane — uniforms, varyings,
// SSR + bicubic + shore helpers, the full fragment() and light() functions.
//
// The including .gdshader file is responsible for:
//   - `shader_type spatial;`
//   - `render_mode ...;`      (clipmap uses `world_vertex_coords`, projected does NOT)
//   - `void vertex() { ... }` (clipmap reads world VERTEX.xz; projected unprojects NDC)
//
// Keeping the split at the vertex() boundary means only ~40 lines differ
// between the two meshes, and everything downstream — SSR, refraction guards,
// shore mask, SSS, debug modes, lighting — stays in lockstep automatically.
//
// DO NOT add `shader_type` or `render_mode` to this file; the include is
// inlined literally and a second declaration is a compile error.
// ============================================================================

#define MAX_CASCADES 8
#define REFLECTANCE  0.02

// FFT cascade data (set via global shader parameters)
global uniform uint num_cascades;
global uniform sampler2DArray displacements;
global uniform sampler2DArray normals : hint_normal;

// Cascade scale/UV parameters (per-cascade: uv_scale.xy, displacement_scale, normal_scale)
uniform vec4 map_scales[MAX_CASCADES];

// Water colors
group_uniforms water_color;
uniform vec3 color_shallow : source_color = vec3(0.09, 0.12, 0.13);  // OpenMW-matched: dark, desaturated
uniform vec3 color_deep : source_color = vec3(0.02, 0.04, 0.06);
uniform vec3 color_sky_tint : source_color = vec3(0.3, 0.38, 0.45);
uniform float sky_tint_strength : hint_range(0.0, 1.0) = 0.5;  // Weather-driven: calm=0.8, storm=0.3

// Foam
group_uniforms foam;
uniform vec3 foam_color : source_color = vec3(0.9, 0.92, 0.95);
uniform sampler2D foam_texture : filter_linear_mipmap, repeat_enable;
uniform float foam_edge_width : hint_range(0.01, 2.0) = 0.3;
uniform float foam_flow_speed : hint_range(0.0, 0.1) = 0.03;
uniform float foam_intensity : hint_range(0.0, 1.0) = 1.0;  // Weather-driven: 0=calm, 1=storm

// Shore
group_uniforms shore;
uniform sampler2D shore_mask : hint_default_white, filter_linear;
uniform vec4 shore_mask_bounds = vec4(-8000.0, -8000.0, 16000.0, 16000.0);

// Refraction — real depth-driven Beer-Lambert from DEPTH_TEXTURE + SCREEN_TEXTURE.
// Declaring these samplers disables Godot 4.6 native SSR on this material
// (Phase 0 verdict, 2026-04-06). ReflectionProbe + sky-cube via SPECULAR still work.
group_uniforms refraction;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D DEPTH_TEXTURE  : hint_depth_texture, filter_nearest;
// Beer-Lambert extinction coefficients per channel (m^-1, applied after density scale).
// R absorbed fastest, G/B slower — matches real ocean spectrum.
uniform vec3 absorption_rate = vec3(0.4, 0.1, 0.06);
uniform float absorption_density : hint_range(0.01, 2.0) = 0.3;
// Clamp water thickness to this many meters when background is far-plane/sky.
// Prevents division by zero and caps extreme absorption for looking-at-horizon cases.
uniform float max_visible_depth : hint_range(1.0, 50.0) = 20.0;
// Strength of the refraction UV offset. 0.6 is the shader-specialist-tuned
// default — visibly refractive without crossing silhouettes. 0 to disable.
uniform float refraction_strength : hint_range(0.0, 1.0) = 0.6;
// Clamp refraction ray travel distance (meters along the refracted ray direction).
// Combined with refraction_strength, this caps the view-space step length. At
// 1.5 and 0.6 the max projected ray is ~0.9m → clearly visible pixel offsets.
uniform float max_refr_thickness : hint_range(0.1, 5.0) = 1.5;
// Depth-contrast rejection: if the refracted sample's view-space depth differs
// from the unrefracted sample's depth by more than this many meters, the
// refracted ray has crossed a silhouette edge (e.g. the edge of a submerged
// rock or the monolith). Fall back to unrefracted to kill ghost/halo artifacts.
uniform float refraction_silhouette_threshold : hint_range(0.1, 10.0) = 1.5;
// World-space Y of the undisplaced water surface. Used by Guard (3b) to reject
// refracted samples that are view-space-behind the water surface but
// world-space-ABOVE the waterline (tall objects poking out of the water). Set
// by OceanManager when the material is initialized; default 0 works for any
// scene whose sea_level is the world origin.
uniform float sea_level = 0.0;

// ============================================================================
// Custom in-shader SSR (Phase 6 / Step 3)
// Ported faithfully from inspos/GodotSSRWater-main/shaders/water.gdshader.
// Replaces Godot 4.6 native SSR which is disabled on this material by
// Phase 0 verdict — declaring hint_depth_texture + hint_screen_texture
// disables the native SSR pass in Forward+ regardless of whether we sample.
// ============================================================================
group_uniforms ssr;
uniform int ssr_max_steps : hint_range(4, 64) = 24;
uniform float ssr_resolution : hint_range(0.1, 5.0) = 1.5;   // view-space meters per step
uniform float ssr_max_travel : hint_range(1.0, 100.0) = 30.0; // view-space meters, total
uniform float ssr_max_diff : hint_range(0.1, 10.0) = 4.0;    // depth tolerance per step
uniform float ssr_mix_strength : hint_range(0.0, 1.0) = 0.7; // master reflection knob
uniform float ssr_screen_border_fadeout : hint_range(0.0, 1.0) = 0.3;

// Visual tuning
group_uniforms visual;
uniform float roughness : hint_range(0.0, 1.0) = 0.02;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform float wave_scale : hint_range(0.0, 3.0) = 1.0;

// Debug visualization — cycles through views of the fragment-shader
// intermediate state. 0 = normal render. Set via `OceanManager.set_debug_mode(int)`.
//   0 = Normal (production)
//   1 = Shore factor (R=0, G=1)
//   2 = Shore discard zone (pixels that WOULD discard, as red overlay)
//   3 = Water thickness / max_visible_depth (blue=thin, red=thick)
//   4 = Transmittance (beer-lambert absorption, gray)
//   5 = Fresnel (gray)
//   6 = SSR hit (green = hit, black = miss)
//   7 = Refraction UV offset magnitude (black=none, red=large)
//   8 = Normal.y (up-facing = white, sideways = black)
//   9 = SSS scatter factor (sub-surface emission)
uniform int debug_mode : hint_range(0, 9) = 0;

// Subsurface scattering — Sea of Thieves "scattering approximation" model.
// Blends between the base water color and a sub-surface scatter color based on
// FFT choppiness (canonical SoT peak mask = horizontal displacement magnitude),
// view angle, and sun backlight. Runs in fragment() as an ALBEDO blend, NOT as
// an additive term in light() — the additive path was getting crushed by the
// final `DIFFUSE_LIGHT * LIGHT_COLOR` multiply, tinting cyan to yellow at sunset.
//
// Reference: "Technical Art of Sea of Thieves" (Rare Ltd., GDC). Quote:
// "The water colour is based on scattering approximations. We blend between a
//  deep water colour and a sub-surface water colour based on a combination of
//  view angle, sun direction and a wave peak mask. The wave peak mask is
//  generated from the FFT choppiness vertex offsets. Where the choppiness
//  offset is greater, this corresponds to wave peaks, which show more
//  sub-surface due to shorter distance traveled by light through the water."
group_uniforms sss;
// Colour the scatter picks up at wave peaks — default is light aquamarine to
// match thin-water appearance (sun passing through 10-20cm of water over a
// crest). Weather-driven via OceanManager (calm = brighter, storm = darker).
uniform vec3 color_sub_surface : source_color = vec3(0.28, 0.62, 0.48);
// Master scatter strength — 0 disables, 1 is reference, >1 boosts. Kept uniform
// name `sss_strength` for compatibility with existing OceanManager weather hooks.
uniform float sss_strength : hint_range(0.0, 3.0) = 0.9;
// Choppiness thresholds for the peak mask. Min = ignored noise floor, max =
// fully saturated at this choppiness. 2026-04-10 tuning: bumped both up
// significantly after user reported "big patches of flat green" — the old
// 0.08 floor fired scatter on every mid-sea wave because FFT has a baseline
// choppiness everywhere. 0.28 → 0.75 restricts scatter to actual sharp crests.
uniform float scatter_choppiness_min : hint_range(0.0, 2.0) = 0.28;
uniform float scatter_choppiness_max : hint_range(0.1, 3.0) = 0.75;
// Sun direction in WORLD space (pointing FROM sun TO world). Set per-frame by
// OceanManager from the scene's DirectionalLight3D. Default (down) = noon.
uniform vec3 sun_dir_world = vec3(0.0, -1.0, 0.0);

// Varyings — populated by vertex() in each .gdshader, read by fragment() here.
varying float wave_height;
varying float foam_factor;
varying float fresnel;
varying vec3 v_world_pos;      // displaced world position (for normals, SSS, refraction)
varying float v_shore_factor;
varying float v_vertex_dist;
// FFT choppiness magnitude — horizontal displacement length summed across all
// cascades, with shore mask applied. This is SoT's canonical "wave peak mask".
// Large values = sharp crest with short light path through water = more scatter.
varying float v_choppiness;

// ============================================================================
// SHORE MASK
// ============================================================================
float sample_shore(vec2 world_xz) {
	vec2 uv = (world_xz - shore_mask_bounds.xy) / shore_mask_bounds.zw;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		return 1.0;
	}
	return texture(shore_mask, uv).r;
}

// ============================================================================
// BICUBIC FILTERING (for normal maps — reduces aliasing at distance)
// Source: GPU Gems 2, Ch. 20
// ============================================================================
vec4 cubic_weights(float a) {
	float a2 = a*a;
	float a3 = a2*a;
	float w0 = -a3     + a2*3.0 - a*3.0 + 1.0;
	float w1 =  a3*3.0 - a2*6.0         + 4.0;
	float w2 = -a3*3.0 + a2*3.0 + a*3.0 + 1.0;
	float w3 =  a3;
	return vec4(w0, w1, w2, w3) / 6.0;
}

vec4 texture_bicubic(in sampler2DArray sampler_tex, in vec3 uvw) {
	vec2 dims = vec2(textureSize(sampler_tex, 0).xy);
	vec2 dims_inv = 1.0 / dims;
	uvw.xy = uvw.xy * dims + 0.5;

	vec2 fuv = fract(uvw.xy);
	vec4 wx = cubic_weights(fuv.x);
	vec4 wy = cubic_weights(fuv.y);

	vec4 g = vec4(wx.xz + wx.yw, wy.xz + wy.yw);
	vec4 h = (vec4(wx.yw, wy.yw) / g + vec2(-1.5, 0.5).xyxy + floor(uvw.xy).xxyy) * dims_inv.xxyy;
	vec2 w = g.xz / (g.xz + g.yw);
	return mix(
		mix(texture(sampler_tex, vec3(h.yw, uvw.z)), texture(sampler_tex, vec3(h.xw, uvw.z)), w.x),
		mix(texture(sampler_tex, vec3(h.yz, uvw.z)), texture(sampler_tex, vec3(h.xz, uvw.z)), w.x), w.y);
}

// ============================================================================
// CUSTOM SSR RAYMARCH
// Port of get_ssr_color() from inspos/GodotSSRWater-main/shaders/water.gdshader.
// Naming is Godotwind-style (ssr_* prefix) but the algorithm is unchanged.
// View-space raymarch along the reflected view ray, sampling DEPTH_TEXTURE
// and SCREEN_TEXTURE at each step, accepting the first hit where the ray
// position is behind the scene depth by less than ssr_max_diff.
// ============================================================================
bool ssr_in_screen(vec2 pos) {
	return pos.x > 0.0 && pos.x < 1.0 && pos.y > 0.0 && pos.y < 1.0;
}

vec2 ssr_view_to_uv(vec3 view_pos, mat4 proj) {
	vec4 clip = proj * vec4(view_pos, 1.0);
	vec2 ndc = clip.xy / clip.w;
	return ndc * 0.5 + 0.5;
}

vec3 ssr_uv_to_view(vec2 uv, float depth, mat4 inv_proj) {
	vec4 ndc = vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec4 view = inv_proj * ndc;
	return view.xyz / view.w;
}

float ssr_edge_alpha(vec2 pos) {
	// Ported verbatim from GodotSSRWater get_screen_border_alpha(). At the
	// screen center `mask` approaches 1.0; at the edges it approaches 0.
	// The smoothstep width + offset trick lets a single uniform
	// (ssr_screen_border_fadeout) control both the softness of the fade and
	// how far from the edge it reaches. Disable entirely when ~0.
	vec2 shifted = 4.0 * pos * (1.0 - pos);
	float mask = shifted.x * shifted.y;
	float offset = mix(0.0, 0.5, (clamp(ssr_screen_border_fadeout, 0.75, 1.0) - 0.75) / 0.25);
	float alpha = clamp(smoothstep(0.0, 2.0 * ssr_screen_border_fadeout, mask) - offset, 0.0, 1.0);
	return ssr_screen_border_fadeout < 1e-5 ? 1.0 : alpha;
}

vec4 ssr_trace(
	vec3 surf_view_pos,
	vec3 view_normal,
	vec3 view_vec,
	mat4 proj,
	mat4 inv_proj,
	int steps
) {
	if (ssr_max_travel < 1e-5 || steps <= 0) {
		return vec4(0.0);
	}
	// VIEW in Godot fragment is surface→camera; negate to get the incident
	// direction (camera→surface) for reflect().
	vec3 incident = -view_vec;
	vec3 reflect_dir = normalize(reflect(incident, view_normal));

	vec3 current = surf_view_pos;
	vec2 screen_pos = vec2(0.5);
	vec3 result = vec3(-1.0);
	float travel = 0.0;
	for (int i = 0; i < steps; i++) {
		if (result.x >= 0.0) { break; }
		if (travel >= ssr_max_travel) { break; }
		current += reflect_dir * ssr_resolution;
		travel += ssr_resolution;
		screen_pos = ssr_view_to_uv(current, proj);
		float probe_depth = texture(DEPTH_TEXTURE, screen_pos).r;
		vec3 probe_view = ssr_uv_to_view(screen_pos, probe_depth, inv_proj);
		// depth_diff > 0 → scene surface at this UV is behind our probe point
		// (i.e. ray hasn't reached it yet). depth_diff < max → accept the hit.
		float depth_diff = probe_view.z - current.z;
		vec3 sample_color = texture(SCREEN_TEXTURE, screen_pos).rgb;
		if (ssr_in_screen(screen_pos) && depth_diff >= 0.0 && depth_diff < ssr_max_diff) {
			result = sample_color;
		}
	}
	if (result.x < 0.0) {
		return vec4(0.0);
	}
	return vec4(result, ssr_edge_alpha(screen_pos));
}

// ============================================================================
// SPECULAR HELPERS — Smith masking-shadowing + GGX distribution
// Ported from GodotOceanWaves (2Retr0). Declared BEFORE light() so the
// shader parser sees the definitions in order.
// ============================================================================
float smith_masking_shadowing(in float cos_theta, in float alpha) {
	float a = cos_theta / (alpha * sqrt(1.0 - cos_theta * cos_theta));
	float a_sq = a * a;
	return a < 1.6 ? (1.0 - 1.259 * a + 0.396 * a_sq) / (3.535 * a + 2.181 * a_sq) : 0.0;
}

float ggx_distribution(in float cos_theta, in float alpha) {
	float a_sq = alpha * alpha;
	float d = 1.0 + (a_sq - 1.0) * cos_theta * cos_theta;
	return a_sq / (PI * d * d);
}

// ============================================================================
// FRAGMENT — Opaque ocean: depth-buffer refraction + Beer-Lambert absorption +
// depth-driven shore foam + Fresnel + custom in-shader SSR raymarch + SSS.
// ============================================================================
void fragment() {
	float map_size = float(textureSize(normals, 0).x);
	float dist = v_vertex_dist;

	// Read gradient and foam from normal maps (all cascades)
	vec3 gradient = vec3(0);
	for (uint i = 0U; i < num_cascades; ++i) {
		vec4 scales = map_scales[i];
		vec3 coords = vec3(UV * scales.xy, float(i));
		float ppm = map_size * min(scales.x, scales.y);
		gradient += mix(texture_bicubic(normals, coords), texture(normals, coords), min(1.0, ppm * 0.1)).xyw * vec3(scales.ww, 1.0);
	}
	gradient *= v_shore_factor;

	// ========================================================================
	// SHORE — prebaked mask is the single authority for land/water boundary.
	// ========================================================================
	// Debug modes DISABLE the discard so we can SEE the geometry that would
	// normally be killed. In production (debug_mode == 0) the discard still
	// runs unchanged.
	if (v_shore_factor < 0.01 && debug_mode == 0) {
		discard;
	}
	// Shore blend factor from prebaked mask (0=land, 1=open ocean)
	float shore_blend = smoothstep(0.01, 0.3, v_shore_factor);

	// ========================================================================
	// FOAM — Jacobian whitecaps + flow-mapped detail + shore edge foam
	// ========================================================================
	// Jacobian foam — extended range (200-4000m)
	float foam_dist_fade = 1.0 - smoothstep(200.0, 4000.0, dist);
	float jacobian_foam = smoothstep(0.0, 1.0, gradient.z * 0.75) * foam_dist_fade * foam_intensity;

	// Flow-mapped dual-layer foam texture for animated detail
	vec2 foam_uv_a = v_world_pos.xz * 0.15 + TIME * vec2(foam_flow_speed, foam_flow_speed * 0.7);
	vec2 foam_uv_b = v_world_pos.xz * 0.12 + TIME * vec2(-foam_flow_speed * 0.6, foam_flow_speed);
	float foam_tex_a = texture(foam_texture, foam_uv_a).r;
	float foam_tex_b = texture(foam_texture, foam_uv_b).r;
	float foam_detail = foam_tex_a * foam_tex_b;  // multiply for sharper, more natural pattern
	// Jacobian drives where foam appears, texture gives it detail
	jacobian_foam *= mix(0.6, 1.0, foam_detail);

	// Shore edge foam — depth-buffer driven. Reconstruct view-space thickness
	// here (before NORMAL/fresnel) so foam can use real water depth instead of
	// the prebaked shore mask. This also rings foam around submerged rocks for
	// free, since DEPTH_TEXTURE sees any opaque geometry below the surface.
	// Unit semantics: foam_edge_width is meters of water depth (matches
	// ocean_standard.gdshader). OceanManager wind animation (0.1→1.5m) still
	// reads sensibly: calm = thin shoreline, storm = wider band.
	//
	// Canonical Godot 4.6 reversed-Z depth→view-space-Z reconstruction. Forward+
	// / D3D12 / Vulkan use infinite reversed-Z where the depth buffer stores
	// 1.0 at near plane, 0.0 at far plane, and PROJECTION_MATRIX[3][2] encodes
	// the negated near distance. Avoids the numerical blowup near the near
	// plane that a full INV_PROJECTION_MATRIX * clip pipeline produces when
	// bg_view4.w approaches zero.
	vec4 surf_view4 = VIEW_MATRIX * vec4(v_world_pos, 1.0);
	vec3 surf_view = surf_view4.xyz / surf_view4.w;
	float bg_ndc_z = texture(DEPTH_TEXTURE, SCREEN_UV).r;
	float bg_view_z = -PROJECTION_MATRIX[3][2] / max(bg_ndc_z, 1e-5);
	float raw_thickness = max(0.0, surf_view.z - bg_view_z);
	bool is_sky_or_far = raw_thickness >= max_visible_depth;
	float water_thickness = min(raw_thickness, max_visible_depth);

	// Smoothstep on depth: 1.0 at zero depth → 0.0 past foam_edge_width meters.
	float shore_foam = (1.0 - smoothstep(0.0, foam_edge_width, water_thickness)) * foam_detail;
	foam_factor = max(jacobian_foam, shore_foam);

	// ========================================================================
	// NORMALS — flatten at distance to reduce shimmer
	// ========================================================================
	float normal_fade = mix(0.015, normal_strength, exp(-dist * 0.0175));
	float normal_y_scale = max(1.0, dist * 0.002);
	gradient.xy *= normal_fade;
	vec3 world_normal = normalize(vec3(-gradient.x, normal_y_scale, -gradient.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);

	// ========================================================================
	// FRESNEL — Schlick with roughness-dependent power (GodotOceanWaves approach)
	// ========================================================================
	float cos_theta = max(dot(VIEW, NORMAL), 0.0);
	float fresnel_power = 5.0 * exp(-2.69 * roughness);
	fresnel = mix(pow(1.0 - cos_theta, fresnel_power) / (1.0 + 22.7 * pow(roughness, 1.5)), 1.0, REFLECTANCE);

	// ========================================================================
	// WATER COLOR — real view-space depth + per-channel Beer-Lambert absorption
	// ========================================================================
	// Beer-Lambert transmittance per channel (exponential falloff with thickness).
	vec3 transmittance = exp(-water_thickness * absorption_rate * absorption_density);

	// ========================================================================
	// STEP 2 — Refraction UV offset
	// Refract the view direction through the surface normal using air→water IOR
	// (1/1.333 = 0.7509). Step along the refracted ray by a distance proportional
	// to water thickness, project that point back to screen UV, and sample there.
	// This bends submerged geometry at the waterline.
	//
	// Guards (in order):
	//   (1) Total internal reflection — refract() returns zero; fall back.
	//   (2) Refracted UV is off-screen [0,1] — fall back.
	//   (3) SKY REJECT — refracted UV samples the sky/far plane (NDC depth near
	//       zero in reversed-Z). Belt-and-suspenders early-out before doing
	//       reconstruction on garbage depth.
	//   (4) Refracted sample is BEHIND the water surface in view space
	//       (cand_view_z less than surf_view.z).
	//   (5) SILHOUETTE CROSSING — refracted sample's depth differs from the
	//       unrefracted sample's depth by more than refraction_silhouette_threshold.
	//   (6) WORLD-Y REJECT — refracted sample must be BELOW sea_level in WORLD
	//       space. Prevents pulling above-water pixels into underwater regions.
	// ========================================================================
	vec2 refr_uv = SCREEN_UV;
	if (!is_sky_or_far && refraction_strength > 0.0) {
		vec3 refr_dir = refract(-VIEW, NORMAL, 0.7509); // air→water, IOR 1.333
		if (dot(refr_dir, refr_dir) > 1e-6) {
			float edge_t = clamp(length((SCREEN_UV - 0.5) * 2.0), 0.0, 1.0);
			float edge_fade = 1.0 - smoothstep(0.7, 1.0, edge_t);
			float travel = min(water_thickness, max_refr_thickness)
				* refraction_strength * edge_fade;
			vec3 refr_target_view = surf_view + refr_dir * travel;
			vec4 refr_clip = PROJECTION_MATRIX * vec4(refr_target_view, 1.0);
			if (refr_clip.w > 1e-4) {
				vec2 candidate_uv = (refr_clip.xy / refr_clip.w) * 0.5 + 0.5;
				// Guard (2): on-screen?
				if (all(greaterThan(candidate_uv, vec2(0.0)))
					&& all(lessThan(candidate_uv, vec2(1.0)))) {
					float cand_ndc_z = texture(DEPTH_TEXTURE, candidate_uv).r;
					// Guard (3): sky reject (reversed-Z → far plane near zero).
					if (cand_ndc_z > 1e-4) {
						// Canonical reversed-Z view-space Z.
						float cand_view_z = -PROJECTION_MATRIX[3][2] / max(cand_ndc_z, 1e-5);
						// Guard (4): refracted sample must be behind the surface.
						bool passes_above = cand_view_z < surf_view.z - 0.01;
						// Guard (5): depth-contrast silhouette rejection.
						bool passes_silhouette = abs(cand_view_z - bg_view_z) < refraction_silhouette_threshold;
						// Guard (6): refracted sample's WORLD Y must be below sea_level.
						vec4 cand_clip = vec4(candidate_uv * 2.0 - 1.0, cand_ndc_z, 1.0);
						vec4 cand_view4 = INV_PROJECTION_MATRIX * cand_clip;
						vec3 cand_view_xyz = cand_view4.xyz / max(abs(cand_view4.w), 1e-4);
						vec4 cand_world4 = INV_VIEW_MATRIX * vec4(cand_view_xyz, 1.0);
						float cand_world_y = cand_world4.y / cand_world4.w;
						bool passes_underwater = cand_world_y < sea_level;
						if (passes_above && passes_silhouette && passes_underwater) {
							refr_uv = candidate_uv;
						}
					}
				}
			}
		}
	}

	// Sample the scene behind the water at the refracted UV (or raw UV if any
	// guard fell through). At sky-depth, skip the sample entirely and use deep
	// water color — sampling and tinting sky would bleed sky through refraction.
	vec3 screen_behind = is_sky_or_far
		? color_deep
		: texture(SCREEN_TEXTURE, refr_uv).rgb;
	vec3 refracted_col = screen_behind * transmittance + color_deep * (1.0 - transmittance);

	// Base water color for the "no refraction contribution" term (grazing angles).
	vec3 base_water = mix(color_shallow, color_deep, clamp(water_thickness * 0.1, 0.0, 1.0));

	// ========================================================================
	// SSS — Sea of Thieves scattering approximation (fragment path, ALBEDO)
	// ------------------------------------------------------------------------
	// Blend the base water color toward `color_sub_surface` based on three
	// multiplicative factors:
	//   (a) peak_mask   — FFT choppiness (thin wave tops transmit more light)
	//   (b) view_fade   — grazing angles see more scatter
	//   (c) sun_back    — soft half-lambert on sun behind wave
	// Runs BEFORE the fresnel/refraction mix so fresnel at grazing angles still
	// pulls the color toward sky tint on top of the scatter. Writes directly to
	// ALBEDO downstream — no LIGHT_COLOR multiply, so the scatter color survives
	// sunset lighting without being crushed to the sun's warm tint.
	// ========================================================================
	float peak_mask = smoothstep(scatter_choppiness_min, scatter_choppiness_max, v_choppiness);
	vec3 world_view_dir = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	float world_cos_theta = clamp(dot(world_view_dir, world_normal), 0.0, 1.0);
	// 2026-04-10 — view_fade floor dropped from 0.35 → 0.05 so top-down
	// views (camera nearly perpendicular to water) get almost no scatter,
	// which eliminates the "flat green patches" artifact. The user's mental
	// model is "backlit thin crests glow", not "water is always greenish".
	float view_fade = pow(1.0 - world_cos_theta, 2.0);
	float sun_back = clamp(0.5 + 0.5 * dot(-world_view_dir, sun_dir_world), 0.0, 1.0);
	float scatter = sss_strength * peak_mask
		* mix(0.05, 1.0, view_fade)
		* mix(0.15, 1.0, sun_back);
	scatter = clamp(scatter, 0.0, 1.0);
	base_water = mix(base_water, color_sub_surface, scatter);

	// Fresnel blend: steep angles see through water (refraction dominates),
	// grazing angles reflect sky (fresnel→1 drives sky tint).
	vec3 water_col = mix(refracted_col, base_water, fresnel);
	water_col = mix(water_col, color_sky_tint, fresnel * sky_tint_strength);

	// ========================================================================
	// STEP 3 — Custom in-shader SSR raymarch
	// ========================================================================
	int ssr_steps = int(mix(
		float(ssr_max_steps),
		float(max(ssr_max_steps / 4, 4)),
		smoothstep(50.0, 500.0, v_vertex_dist)
	));
	vec4 ssr_result = ssr_trace(
		surf_view, NORMAL, VIEW,
		PROJECTION_MATRIX, INV_PROJECTION_MATRIX,
		ssr_steps
	);
	water_col = mix(water_col, ssr_result.rgb, ssr_result.a * ssr_mix_strength * fresnel);

	// ========================================================================
	// COMPOSE — fully opaque
	// ========================================================================
	vec3 final_col = mix(color_shallow * 1.5, water_col, shore_blend);
	final_col = mix(final_col, foam_color, foam_factor);

	// ========================================================================
	// DEBUG VISUALIZATION — systematic fragment-state overrides.
	// ========================================================================
	if (debug_mode != 0) {
		vec3 debug_col = vec3(0.0);
		if (debug_mode == 1) {
			debug_col = vec3(1.0 - v_shore_factor, v_shore_factor, 0.0);
		} else if (debug_mode == 2) {
			debug_col = v_shore_factor < 0.01
				? vec3(1.0, 0.0, 0.0)
				: vec3(0.05, 0.1, 0.2);
		} else if (debug_mode == 3) {
			if (is_sky_or_far) {
				debug_col = vec3(1.0, 0.0, 1.0);
			} else {
				float t = clamp(water_thickness / max_visible_depth, 0.0, 1.0);
				debug_col = vec3(t, 0.0, 1.0 - t);
			}
		} else if (debug_mode == 4) {
			debug_col = transmittance;
		} else if (debug_mode == 5) {
			debug_col = vec3(fresnel);
		} else if (debug_mode == 6) {
			debug_col = vec3(0.0, ssr_result.a, 0.0) + ssr_result.rgb * ssr_result.a * 0.5;
		} else if (debug_mode == 7) {
			float offset_mag = length(refr_uv - SCREEN_UV);
			debug_col = vec3(offset_mag * 20.0, 0.0, 0.0);
		} else if (debug_mode == 8) {
			debug_col = vec3(clamp(world_normal.y, 0.0, 1.0));
		} else if (debug_mode == 9) {
			// SSS scatter factor — visualizes the peak_mask × view_fade ×
			// sun_back chain from the fragment-path SSS. Emission = where
			// the scatter is firing + how strong. Light-independent rendering
			// of the `scatter` scalar so we can verify choppiness → peak mask
			// before the sub_surface tint reaches final color.
			debug_col = vec3(0.05, 0.1, 0.15);
			EMISSION = color_sub_surface * scatter * 4.0;
		}
		ALBEDO = debug_col;
		ROUGHNESS = 1.0;
		METALLIC = 0.0;
		SPECULAR = 0.0;
	} else {
		ALBEDO = final_col;
	}
	// Foam perturbs normal for rough micro-detail (foam isn't mirror-smooth)
	if (foam_factor > 0.01) {
		vec3 foam_normal_perturb = vec3(
			(foam_tex_a - 0.5) * 0.3,
			1.0,
			(foam_tex_b - 0.5) * 0.3
		);
		vec3 perturbed = normalize(mix(world_normal, foam_normal_perturb, foam_factor * 0.4));
		NORMAL = normalize((VIEW_MATRIX * vec4(perturbed, 0.0)).xyz);
	}
	// Roughness: base from uniform, foam adds roughness. Low roughness is
	// critical for sharp SSR reflections on calm water.
	ROUGHNESS = (1.0 - fresnel) * foam_factor * 0.6 + roughness;
	METALLIC = 0.0;
	SPECULAR = 0.5;  // F0 for environment reflections (SSR, probes, sky) — separate from light() specular
}

// ============================================================================
// CUSTOM LIGHTING — Smith-GGX specular + half-lambert diffuse + foam mix
// ============================================================================
// 2026-04-10 — SSS moved out of light() and into fragment() as an ALBEDO blend
// (see SSS section in fragment()). The previous additive SSS term in
// DIFFUSE_LIGHT was crushed by the final `* LIGHT_COLOR` multiply, which
// tinted the blue-green scatter yellow at sunset. The SoT paper describes SSS
// as a blend between deep and sub-surface water color, which maps naturally to
// an ALBEDO operation, not a DIFFUSE_LIGHT addition.
//
// Direct-light specular via SPECULAR_LIGHT (sun glints, point lights).
// Environment reflections (SSR, probes, sky) handled by SPECULAR in fragment().
// ============================================================================
void light() {
	vec3 halfway = normalize(LIGHT + VIEW);
	float dot_nl = max(dot(NORMAL, LIGHT), 2e-5);
	float dot_nv = max(dot(NORMAL, VIEW), 2e-5);

	// --- SPECULAR (direct light) --- Smith-GGX with Fresnel
	float spec_alpha = max(roughness, 0.05);  // Use base roughness uniform, floor to avoid artifacts
	float light_mask = smith_masking_shadowing(spec_alpha, dot_nv);
	float view_mask = smith_masking_shadowing(spec_alpha, dot_nl);
	float microfacet_distribution = ggx_distribution(dot(NORMAL, halfway), spec_alpha);
	float geometric_attenuation = 1.0 / (1.0 + light_mask + view_mask);
	SPECULAR_LIGHT += fresnel * microfacet_distribution * geometric_attenuation / (4.0 * dot_nv + 0.1) * ATTENUATION;

	// --- DIFFUSE --- half-lambert + foam mix
	float half_lambert = dot_nl * 0.5 + 0.5;
	vec3 diffuse_base = vec3(half_lambert * 0.9);
	DIFFUSE_LIGHT += mix(diffuse_base, foam_color, foam_factor)
		* (1.0 - fresnel) * ATTENUATION * LIGHT_COLOR;
}
