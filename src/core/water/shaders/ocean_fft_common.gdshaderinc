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
// between the two meshes, and everything downstream — SSR, opaque optics,
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
global uniform sampler2DArray normals;

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

// Shore — prebaked shore mask for VERTEX dampening only (CREST OceanDepthCache
// pattern). Fragment-side shore visuals (foam, color blend, normals) remain
// depth-driven via screen-space water_thickness — no fragment mask reads.
group_uniforms shore;
uniform sampler2D shore_mask : filter_linear_mipmap;
uniform vec4 shore_mask_bounds = vec4(-8000.0, -8000.0, 16000.0, 16000.0);
// Shore fade distance in meters — matches ShoreMaskGenerator's fade_distance.
// Used to denormalize the raw distance stored in shore_mask.a.
uniform float shore_fade_distance : hint_range(10.0, 200.0) = 50.0;
// Shore wave parameters (Outerra-style trochoidal waves oriented by SDF gradient)
uniform float shore_wave_amplitude : hint_range(0.0, 3.0) = 0.5;
// Waves per meter of shore distance — 0.1 = 10m wavelength, 0.05 = 20m.
// Must be low enough that wavelength exceeds clipmap vertex spacing (~2-4m inner rings).
uniform float shore_wave_frequency : hint_range(0.02, 0.5) = 0.1;
// Temporal frequency in cycles/sec. OceanManager derives this from the same
// gravity-wave dispersion relation used by the FFT compute shader.
uniform float shore_wave_speed : hint_range(0.1, 5.0) = 0.4;
uniform float shore_wave_steepness : hint_range(0.0, 1.0) = 0.58;

// Opaque depth-driven Beer-Lambert tint. The waterline compositor owns
// scene-color bending for submerged receivers; this surface still samples the
// opaque scene copy for per-surface SSR.
group_uniforms optics;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D DEPTH_TEXTURE  : hint_depth_texture, filter_nearest;
// Beer-Lambert extinction coefficients per channel (m^-1, applied after density scale).
// R absorbed fastest, G/B slower — matches real ocean spectrum.
uniform vec3 absorption_rate = vec3(0.4, 0.1, 0.06);
uniform float absorption_density : hint_range(0.01, 2.0) = 0.3;
// Clamp water thickness to this many meters for Beer-Lambert absorption and
// debug scaling. Depths beyond this remain real scene geometry; only a near-zero
// reversed-Z depth sample means far-plane/sky.
uniform float max_visible_depth : hint_range(1.0, 50.0) = 20.0;
// World-space Y of the undisplaced water surface. Set by OceanManager when the
// material is initialized; default 0 works for sea-level-at-origin scenes.
uniform float sea_level = 0.0;

// Custom in-shader SSR. Godot native SSR is enabled in the lab environment, but
// water's depth/screen-reading shader path is not a reliable native SSR
// receiver. This raymarch restores object reflections on the ocean itself.
group_uniforms ssr;
uniform int ssr_max_steps : hint_range(4, 64) = 24;
uniform float ssr_resolution : hint_range(0.1, 5.0) = 1.5;
uniform float ssr_max_travel : hint_range(1.0, 100.0) = 30.0;
uniform float ssr_max_diff : hint_range(0.1, 10.0) = 4.0;
uniform float ssr_mix_strength : hint_range(0.0, 1.0) = 0.7;
uniform float ssr_screen_border_fadeout : hint_range(0.0, 1.0) = 0.3;

// Visual tuning
group_uniforms visual;
uniform float roughness : hint_range(0.0, 1.0) = 0.02;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform float wave_scale : hint_range(0.0, 3.0) = 1.0;
// Shared clock driven by OceanManager. Keep ocean surface animation and
// compositor classifiers on one time source instead of mixing shader TIME with
// GDScript wall-clock samples.
uniform float ocean_time = 0.0;

// Debug visualization — cycles through views of the fragment-shader
// intermediate state. 0 = normal render. Set via `OceanManager.set_debug_mode(int)`.
//   0 = Normal (production)
//   1 = Shore depth (R=thin/near shore, G=deep)
//   2 = Shore intersection zone (red = ocean behind terrain)
//   3 = Water thickness / max_visible_depth (blue=thin, red=thick)
//   4 = Transmittance (beer-lambert absorption, gray)
//   5 = Fresnel (gray)
//   6 = SSR hit (green = hit, reflected color = sampled scene)
//   7 = Foam factor
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
uniform float sss_emission_strength : hint_range(0.0, 2.0) = 0.45;
// Choppiness thresholds for the peak mask. Min = ignored noise floor, max =
// fully saturated at this choppiness. Combined with the side-slope mask below
// so flat mid-sea chop does not become broad green patches.
uniform float scatter_choppiness_min : hint_range(0.0, 2.0) = 0.28;
uniform float scatter_choppiness_max : hint_range(0.1, 3.0) = 0.75;
// Sun direction in WORLD space (pointing FROM sun TO world). Set per-frame by
// OceanManager from the scene's DirectionalLight3D. Default (down) = noon.
uniform vec3 sun_dir_world = vec3(0.0, -1.0, 0.0);

// Varyings — populated by vertex() in each .gdshader, read by fragment() here.
varying float wave_height;
varying float foam_factor;
varying float fresnel;
varying vec3 v_world_pos;      // displaced world position (for normals, SSS, depth, SSR)
varying float v_vertex_dist;
// FFT choppiness magnitude — horizontal displacement length summed across all
// cascades, with shore mask applied. This is SoT's canonical "wave peak mask".
// Large values = sharp crest with short light path through water = more scatter.
varying float v_choppiness;
// Shore-wave surface signals are computed in vertex() from the already-sampled
// shore mask and carried into fragment() so lapping waves affect lighting
// without adding per-fragment shore-mask reads.
varying vec2 v_shore_slope;
varying float v_shore_choppiness;

// Shore mask sampled in vertex() of each .gdshader — not here in fragment.

#include "ocean_surface_common.gdshaderinc"

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
		if (!ssr_in_screen(screen_pos)) { continue; }

		float probe_depth = texture(DEPTH_TEXTURE, screen_pos).r;
		vec3 probe_view = ssr_uv_to_view(screen_pos, probe_depth, inv_proj);
		float depth_diff = probe_view.z - current.z;
		if (depth_diff >= 0.0 && depth_diff < ssr_max_diff) {
			result = texture(SCREEN_TEXTURE, screen_pos).rgb;
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
// FRAGMENT — Opaque ocean: depth thickness + Beer-Lambert absorption +
// depth-driven shore foam + Fresnel + custom in-shader SSR + SSS.
// ============================================================================
void fragment() {
	float map_size = float(textureSize(normals, 0).x);
	float dist = v_vertex_dist;

	// ========================================================================
	// DEPTH RECONSTRUCTION — moved to top of fragment so water_thickness is
	// available for gradient dampening, shore blend, and foam. Canonical
	// Godot 4.6 reversed-Z depth→view-space-Z. Forward+ / D3D12 / Vulkan use
	// infinite reversed-Z: 1.0 at near, 0.0 at far. PROJECTION_MATRIX[3][2]
	// encodes the negated near distance.
	// ========================================================================
	vec4 surf_view4 = VIEW_MATRIX * vec4(v_world_pos, 1.0);
	vec3 surf_view = surf_view4.xyz / surf_view4.w;
	float bg_ndc_z = texture(DEPTH_TEXTURE, SCREEN_UV).r;
	float bg_view_z = -PROJECTION_MATRIX[3][2] / max(bg_ndc_z, 1e-5);
	float raw_thickness = max(0.0, surf_view.z - bg_view_z);
	bool is_sky_or_far = bg_ndc_z <= 1e-5;
	float water_thickness = min(raw_thickness, max_visible_depth);

	// Read gradient and foam from normal maps (all cascades)
	vec3 gradient = vec3(0);
	for (uint i = 0U; i < num_cascades; ++i) {
		vec4 scales = map_scales[i];
		vec3 coords = vec3(UV * scales.xy, float(i));
		float ppm = map_size * min(scales.x, scales.y);
		gradient += mix(texture_bicubic(normals, coords), texture(normals, coords), min(1.0, ppm * 0.1)).xyw * vec3(scales.ww, 1.0);
	}
	// Dampen normals near shore — depth-driven replacement for prebaked mask.
	// At shore (water_thickness → 0), gradient → 0, giving calm flat normals.
	// At depth > 1m, full gradient. Prevents visual noise at the thin-water zone.
	gradient *= smoothstep(0.0, 1.0, water_thickness);
	gradient.xy += v_shore_slope;

	// ========================================================================
	// SHORE BLEND — depth-driven. Thin water blends toward shallow color,
	// deep water gets full water rendering (optics + SSS).
	// ========================================================================
	float shore_blend = smoothstep(0.0, 0.5, water_thickness);

	// ========================================================================
	// FOAM — Jacobian whitecaps + flow-mapped detail + shore edge foam
	// ========================================================================
	// Jacobian foam — extended range (200-4000m)
	float foam_dist_fade = 1.0 - smoothstep(200.0, 4000.0, dist);
	float jacobian_foam = smoothstep(0.0, 1.0, gradient.z * 0.75) * foam_dist_fade * foam_intensity;

	// Flow-mapped dual-layer foam texture for animated detail
	vec2 foam_uv_a = v_world_pos.xz * 0.15 + ocean_time * vec2(foam_flow_speed, foam_flow_speed * 0.7);
	vec2 foam_uv_b = v_world_pos.xz * 0.12 + ocean_time * vec2(-foam_flow_speed * 0.6, foam_flow_speed);
	float foam_tex_a = texture(foam_texture, foam_uv_a).r;
	float foam_tex_b = texture(foam_texture, foam_uv_b).r;
	float foam_detail = foam_tex_a * foam_tex_b;  // multiply for sharper, more natural pattern
	// Jacobian drives where foam appears, texture gives it detail
	jacobian_foam *= mix(0.6, 1.0, foam_detail);

	// Shore edge foam — depth-buffer driven. Foam rings around any opaque
	// geometry below the surface (terrain, rocks) for free.
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
	// OPAQUE OPTICS — the surface owns water color, not scene-color bending.
	// The waterline compositor bends/tints submerged objects from pre-water
	// buffers. This shader stays opaque and only uses depth for thickness.
	// ========================================================================
	float optical_water_thickness = water_thickness;
	vec3 transmittance = exp(-optical_water_thickness * absorption_rate * absorption_density);
	float depth_t = is_sky_or_far ? 1.0 : clamp(optical_water_thickness / max_visible_depth, 0.0, 1.0);
	vec3 base_water = mix(color_shallow, color_deep, depth_t);

	// ========================================================================
	// SSS — Sea of Thieves scattering approximation (fragment path, ALBEDO)
	// ------------------------------------------------------------------------
	// Blend the base water color toward `color_sub_surface` based on three
	// multiplicative factors:
	//   (a) peak_mask   — FFT choppiness (thin wave tops transmit more light)
	//   (b) side_mask   — sloped wave sides/peaks transmit more light
	//   (c) sun_back    — strongest when the light travels through the wave toward camera
	// Runs BEFORE the fresnel tint so grazing angles still
	// pulls the color toward sky tint on top of the scatter. Writes directly to
	// ALBEDO downstream — no LIGHT_COLOR multiply, so the scatter color survives
	// sunset lighting without being crushed to the sun's warm tint.
	// ========================================================================
	float chop_mask = smoothstep(scatter_choppiness_min, scatter_choppiness_max, v_choppiness + v_shore_choppiness);
	vec3 world_view_dir = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	float side_mask = smoothstep(0.06, 0.38, 1.0 - world_normal.y);
	float peak_mask = chop_mask * mix(0.55, 1.0, side_mask);
	float sun_back = clamp(dot(world_view_dir, sun_dir_world), 0.0, 1.0);
	float scatter = sss_strength * peak_mask
		* mix(0.25, 1.0, side_mask)
		* mix(0.20, 1.0, sun_back);
	scatter = clamp(scatter, 0.0, 1.0);
	base_water = mix(base_water, color_sub_surface, scatter);

	// Fresnel blend: steep angles show depth-colored water, grazing angles
	// reflect sky tint through the engine's opaque lighting/reflection path.
	vec3 water_col = base_water;
	water_col = mix(water_col, color_sky_tint, fresnel * sky_tint_strength);

	int ssr_steps = int(mix(
		float(ssr_max_steps),
		float(max(ssr_max_steps / 4, 4)),
		smoothstep(50.0, 500.0, v_vertex_dist)
	));
	vec4 ssr_result = ssr_trace(
		surf_view,
		NORMAL,
		VIEW,
		PROJECTION_MATRIX,
		INV_PROJECTION_MATRIX,
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
			// Shore depth: red = thin water (near shore), green = deep
			float shore_t = clamp(water_thickness / 2.0, 0.0, 1.0);
			debug_col = vec3(1.0 - shore_t, shore_t, 0.0);
		} else if (debug_mode == 2) {
			// Shore intersection zone: red = ocean behind terrain (would be occluded)
			debug_col = water_thickness < 0.05
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
			debug_col = vec3(foam_factor);
		} else if (debug_mode == 8) {
			debug_col = vec3(clamp(world_normal.y, 0.0, 1.0));
		} else if (debug_mode == 9) {
			// SSS scatter factor — visualizes the peak_mask × side_mask ×
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
		EMISSION = color_sub_surface * scatter * sss_emission_strength * (1.0 - foam_factor * 0.5);
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
	// Roughness: base from uniform, foam adds roughness. Low roughness keeps
	// SSR/probe/sky reflections sharp on calm water.
	ROUGHNESS = (1.0 - fresnel) * foam_factor * 0.6 + roughness;
	METALLIC = 0.0;
	SPECULAR = 0.5;  // F0 for environment reflections — separate from light() specular
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
// Environment reflections (native/probes/sky) handled by SPECULAR in fragment();
// object SSR is supplied by the explicit surface raymarch above.
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
