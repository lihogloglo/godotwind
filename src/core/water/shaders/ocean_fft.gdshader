shader_type spatial;
render_mode world_vertex_coords, cull_disabled, shadows_disabled, depth_draw_opaque;

/**
 * Ocean FFT Shader — Godotwind
 *
 * Fully opaque ocean surface (no ALPHA, no transparent pipeline).
 * Water appearance comes from ALBEDO color + SSS lighting — NOT from
 * sampling SCREEN_TEXTURE or refraction tricks.
 *
 * Design follows GodotOceanWaves (2Retr0): opaque render, SSS scattering,
 * Jacobian foam, Fresnel-driven roughness. No refraction = no hollow crests.
 *
 * Features:
 * - FFT displacement from JONSWAP spectrum (multi-cascade)
 * - Bicubic normal map filtering (reduces aliasing at distance)
 * - Jacobian-based whitecap foam from FFT + distance fade
 * - Prebaked shore mask for wave dampening + shore discard (no DEPTH_TEXTURE)
 * - Schlick Fresnel with roughness-dependent power
 * - Distance-based normal flattening (reduces shimmer at far LODs)
 * - SSS (subsurface scattering) on wave crests via custom light()
 * - Relies on Godot 4.6 native SSR + ReflectionProbe for reflections
 *
 * NOTE: No DEPTH_TEXTURE or SCREEN_TEXTURE — both force a late render pass
 * that runs AFTER SSR, making the ocean invisible to screen-space reflections.
 *
 * Lighting: custom light() for SSS + lambertian diffuse + Smith-GGX specular.
 * Environment reflections (SSR, probes, sky) via SPECULAR in fragment().
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
uniform float absorption_coeff : hint_range(0.01, 1.0) = 0.2;
uniform float min_absorption : hint_range(0.0, 0.3) = 0.1;

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
// FRAGMENT — Opaque ocean: ALBEDO + Fresnel + foam. No refraction.
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
	// SHORE — prebaked mask is the single authority (no DEPTH_TEXTURE).
	// DEPTH_TEXTURE forces a late render pass that runs AFTER SSR.
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
	// WATER COLOR — shore-mask absorption + Fresnel sky tint
	// ========================================================================
	// Use shore_factor as proxy for depth: near shore (low) = shallow, open ocean (1.0) = deep
	float absorption = max(v_shore_factor * absorption_coeff * 10.0, min_absorption);
	absorption = min(absorption, 1.0);
	vec3 water_col = mix(color_shallow, color_deep, absorption);
	// Fresnel-weighted sky tint: at grazing angles, water reflects sky color.
	// This prevents calm water from looking like flat dark paint.
	water_col = mix(water_col, color_sky_tint, fresnel * sky_tint_strength);

	// ========================================================================
	// COMPOSE — fully opaque, no refraction
	// ========================================================================
	// Shore transition: near shore, lighten the water color toward shallow
	vec3 final_col = mix(color_shallow * 1.5, water_col, shore_blend);
	// Foam overlay — foam also perturbs normal slightly for rough micro-detail
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
