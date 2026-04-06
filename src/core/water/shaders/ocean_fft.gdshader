shader_type spatial;
render_mode world_vertex_coords, cull_disabled, shadows_disabled, depth_draw_opaque;

/**
 * Ocean FFT Shader — Godotwind
 *
 * Fully opaque ocean surface. Real depth-driven Beer-Lambert absorption via
 * SCREEN_TEXTURE + DEPTH_TEXTURE sampling and view-space thickness.
 * ReflectionProbe + sky-cube contributions reach the surface via SPECULAR;
 * screen-space reflection of objects is (will be in Step 3) a custom in-shader
 * raymarch ported from GodotSSRWater.
 *
 * Features:
 * - FFT displacement from JONSWAP spectrum (multi-cascade)
 * - Bicubic normal map filtering (reduces aliasing at distance)
 * - Jacobian-based whitecap foam from FFT + distance fade
 * - Prebaked shore mask for wave dampening, discard, and shore-edge foam ONLY
 *   (NOT used as depth proxy — real depth now comes from DEPTH_TEXTURE)
 * - View-space depth reconstruction via INV_PROJECTION_MATRIX
 * - Per-channel Beer-Lambert absorption from real water thickness
 * - Screen-space sampling of seafloor behind the water surface
 * - Schlick Fresnel with roughness-dependent power
 * - Distance-based normal flattening (reduces shimmer at far LODs)
 * - SSS (subsurface scattering) on wave crests via custom light()
 *
 * Phase 0 verdict (2026-04-06, verified in test_reflections.tscn):
 * declaring hint_depth_texture + hint_screen_texture disables Godot 4.6
 * native SSR on this material (even without sampling). ReflectionProbe +
 * sky-cube contributions via SPECULAR still reach the surface — confirmed by
 * toggling the probe and observing ocean color change. We accept losing
 * native SSR in exchange for refraction; a custom SSR trace will be added
 * in Step 3 (port from inspos/GodotSSRWater-main).
 *
 * Lighting: custom light() for SSS + lambertian diffuse + Smith-GGX specular.
 */

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
// Strength of the refraction UV offset. Lower values = subtler distortion,
// 0 to disable. Deliberately under 1.0 to avoid silhouette crossing artifacts
// (refracted sample landing on the wrong side of an opaque object's edge).
uniform float refraction_strength : hint_range(0.0, 1.0) = 0.25;
// Clamp refraction ray travel distance (meters along the refracted ray direction).
// Smaller = less shimmer but fewer silhouette artifacts. 0.8m is conservative.
uniform float max_refr_thickness : hint_range(0.1, 5.0) = 0.8;
// Depth-contrast rejection: if the refracted sample's view-space depth differs
// from the unrefracted sample's depth by more than this many meters, the
// refracted ray has crossed a silhouette edge (e.g. the edge of a submerged
// rock or the monolith). Fall back to unrefracted to kill ghost/halo artifacts.
uniform float refraction_silhouette_threshold : hint_range(0.1, 10.0) = 1.5;

// Visual tuning
group_uniforms visual;
uniform float roughness : hint_range(0.0, 1.0) = 0.02;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform float wave_scale : hint_range(0.0, 3.0) = 1.0;

// Subsurface scattering
group_uniforms sss;
uniform float sss_strength : hint_range(0.0, 2.0) = 0.8;

// Varyings
varying float wave_height;
varying float foam_factor;
varying float fresnel;
varying vec3 v_world_pos;      // displaced position (for normals, SSS)
varying float v_shore_factor;
varying float v_vertex_dist;

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
// VERTEX — Sample FFT displacement maps
// ============================================================================
void vertex() {
	// Mesh position snapped to 64m grid by ocean_mesh.gd (scrolling clipmap)
	UV = VERTEX.xz;
	// Shore mask dampens wave displacement near shore to prevent geometry clipping
	v_shore_factor = sample_shore(VERTEX.xz);

	// 3D distance for altitude-aware cascade fading
	float dist = length(VERTEX - CAMERA_POSITION_WORLD);
	v_vertex_dist = dist;
	float shore = v_shore_factor * wave_scale;

	// Accumulate displacement from all cascades with per-cascade distance fade
	vec3 displacement = vec3(0);
	for (uint i = 0U; i < num_cascades; ++i) {
		vec4 scales = map_scales[i];
		float tile_size = 1.0 / max(scales.x, 1e-6);
		float cascade_fade = clamp(exp(-(dist - 50.0) / (tile_size * 20.0)), 0.0, 1.0);
		displacement += texture(displacements, vec3(UV * scales.xy, float(i))).xyz * scales.z * cascade_fade;
	}
	VERTEX += displacement * shore;
	VERTEX.y += 0.15; // slight bias prevents z-fighting with terrain
	wave_height = displacement.y;
	v_world_pos = VERTEX;
}

// ============================================================================
// FRAGMENT — Opaque ocean: ALBEDO + Fresnel + foam + shore-mask refraction.
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
	if (v_shore_factor < 0.01) {
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

	// Shore edge foam — driven by shore mask instead of depth buffer
	float shore_foam = 0.0;
	if (v_shore_factor < foam_edge_width) {
		float edge_t = 1.0 - v_shore_factor / foam_edge_width;
		shore_foam = step(edge_t, foam_detail) * edge_t;
	}
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
	// Reconstruct view-space positions for the water surface AND the scene
	// fragment directly behind it. View-space -Z is forward, so deeper points
	// are MORE NEGATIVE; thickness = (surf.z - bg.z) is positive when bg is
	// further from the camera than the water surface.
	//
	// Sky-depth handling: when DEPTH_TEXTURE at SCREEN_UV reads the far plane
	// (sky, no opaque behind water), the reconstructed bg_view goes to the far
	// clip distance and thickness blows up. We clamp thickness to max_visible_depth
	// and skip the SCREEN_TEXTURE sample — the sky is not "behind" the water at
	// any meaningful depth; sampling it and tinting it through absorption would
	// bleed sky color into the water color, which is wrong. Do NOT "optimize"
	// this branch away.
	vec4 surf_view4 = VIEW_MATRIX * vec4(v_world_pos, 1.0);
	vec3 surf_view = surf_view4.xyz / surf_view4.w;

	float bg_ndc_z = texture(DEPTH_TEXTURE, SCREEN_UV).r;
	vec4 bg_clip = vec4(SCREEN_UV * 2.0 - 1.0, bg_ndc_z, 1.0);
	vec4 bg_view4 = INV_PROJECTION_MATRIX * bg_clip;
	vec3 bg_view = bg_view4.xyz / max(abs(bg_view4.w), 1e-6) * sign(bg_view4.w);

	float raw_thickness = max(0.0, surf_view.z - bg_view.z);
	bool is_sky_or_far = raw_thickness >= max_visible_depth;
	float water_thickness = min(raw_thickness, max_visible_depth);

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
	//   (3) Refracted sample is ABOVE water (view-space z less negative than
	//       surf_view.z). Refracted ray exited back through the surface or into
	//       above-water geometry; sampling there would bleed that color through.
	//   (4) SILHOUETTE CROSSING — refracted sample's depth differs from the
	//       unrefracted sample's depth by more than refraction_silhouette_threshold.
	//       This catches the "monolith ghost" / "seafloor-colored outline around
	//       submerged rock" artifact where the refracted ray lands on the far
	//       side of an opaque object's edge and drags its color into the wrong
	//       pixel. Fall back to unrefracted SCREEN_UV in that case.
	//
	// Screen-center-distance deglitch: fade refraction strength toward 0 near the
	// screen edges so off-screen sampling artifacts don't jitter along the borders.
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
					vec4 cand_clip = vec4(candidate_uv * 2.0 - 1.0, cand_ndc_z, 1.0);
					vec4 cand_view4 = INV_PROJECTION_MATRIX * cand_clip;
					vec3 cand_view = cand_view4.xyz / max(abs(cand_view4.w), 1e-6) * sign(cand_view4.w);
					// Guard (3): refracted sample must be BEHIND the surface.
					bool passes_above = cand_view.z < surf_view.z - 0.01;
					// Guard (4): refracted sample's depth must be reasonably
					// close to the unrefracted sample's depth. If the refracted
					// ray crossed a silhouette edge (e.g. off the side of a
					// submerged rock), the depth difference will be large.
					bool passes_silhouette = abs(cand_view.z - bg_view.z) < refraction_silhouette_threshold;
					if (passes_above && passes_silhouette) {
						refr_uv = candidate_uv;
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
	// Fresnel blend: steep angles see through water (refraction dominates),
	// grazing angles reflect sky (fresnel→1 drives sky tint).
	vec3 water_col = mix(refracted_col, base_water, fresnel);
	water_col = mix(water_col, color_sky_tint, fresnel * sky_tint_strength);

	// ========================================================================
	// COMPOSE — fully opaque
	// ========================================================================
	// Shore transition: near shore, lighten the water color toward shallow
	vec3 final_col = mix(color_shallow * 1.5, water_col, shore_blend);
	// Foam overlay
	final_col = mix(final_col, foam_color, foam_factor);

	ALBEDO = final_col;
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
	// Roughness: base from uniform (weather-driven: calm=0.01, storm=0.15), foam adds roughness.
	// Low roughness is critical for sharp SSR reflections on calm water.
	ROUGHNESS = (1.0 - fresnel) * foam_factor * 0.6 + roughness;
	METALLIC = 0.0;
	SPECULAR = 0.5;  // F0 for environment reflections (SSR, probes, sky) — separate from light() specular
}

// ============================================================================
// SPECULAR HELPERS — Smith masking-shadowing + GGX distribution
// Ported from GodotOceanWaves (2Retr0)
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
// CUSTOM LIGHTING — SSS + lambertian diffuse + Smith-GGX specular
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

	// --- DIFFUSE --- SSS + lambertian
	const vec3 sss_tint = vec3(0.9, 1.15, 0.85);
	float sss_height = sss_strength * max(0.0, wave_height + 2.5)
		* pow(max(dot(LIGHT, -VIEW), 0.0), 4.0)
		* pow(max(0.5 - 0.5 * dot(LIGHT, NORMAL), 0.0), 3.0);
	float sss_near = 0.5 * pow(dot_nv, 2.0);
	float lambertian = 0.5 * dot_nl;

	DIFFUSE_LIGHT += mix(
		(sss_height + sss_near) * sss_tint / (1.0 + light_mask) + lambertian,
		foam_color, foam_factor
	) * (1.0 - fresnel) * ATTENUATION * LIGHT_COLOR;
}
