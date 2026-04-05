shader_type spatial;
render_mode world_vertex_coords, cull_disabled, diffuse_lambert, specular_schlick_ggx;

/**
 * Ocean Standard Shader — Godotwind
 *
 * Analytical multi-octave Gerstner waves with Godot 4.6 native SSR.
 * No manual raymarching. No compute pipeline. Clean and maintainable.
 *
 * WARNING: Wave constants below MUST match GerstnerMath.gd for CPU-GPU sync.
 * If you change wave params here, update GerstnerMath.gd too (and vice versa).
 *
 * Features:
 * - 3-octave Gerstner displacement (12 waves, distance-LOD'd)
 * - Analytical normals from wave derivatives
 * - Depth-based water coloring (shallow/deep)
 * - Shore mask dampening
 * - Depth-edge foam
 * - Schlick Fresnel
 * - Fake refraction via distorted depth UV + Beer-Lambert absorption (no SCREEN_TEXTURE)
 * - Schlick Fresnel blends refraction (steep) vs reflection (grazing)
 * - Relies on Godot 4.6 native SSR + ReflectionProbe for reflections (requires opaque pass)
 */

// Depth texture (no SCREEN_TEXTURE — it forces transparent pass, breaking SSR)
uniform sampler2D DEPTH_TEX : hint_depth_texture, filter_linear_mipmap, repeat_disable;

// Water colors
group_uniforms water_color;
uniform vec3 color_shallow : source_color = vec3(0.1, 0.3, 0.4);
uniform vec3 color_deep : source_color = vec3(0.02, 0.08, 0.12);
uniform float color_depth_range : hint_range(1.0, 100.0) = 8.0;

// Shore mask
group_uniforms shore;
uniform sampler2D shore_mask : hint_default_white, filter_linear;
uniform vec4 shore_mask_bounds = vec4(-8000.0, -8000.0, 16000.0, 16000.0);

// Foam
group_uniforms foam;
uniform sampler2D foam_texture : filter_linear_mipmap, repeat_enable;
uniform float foam_edge_width : hint_range(0.01, 2.0) = 0.3;
uniform float foam_scroll_speed : hint_range(0.0, 0.1) = 0.02;
uniform vec3 foam_color : source_color = vec3(0.9, 0.92, 0.95);

// Shore color (visible through shallow water where depth → 0)
group_uniforms shore_color;
uniform vec3 color_shore : source_color = vec3(0.25, 0.22, 0.18);

// Refraction (fake — distorted depth UV, no SCREEN_TEXTURE)
group_uniforms refraction;
uniform float refraction_strength : hint_range(0.0, 0.1) = 0.03;
uniform vec3 absorption_rate = vec3(0.4, 0.1, 0.06); // R absorbed fast, G/B slower (Beer-Lambert)
uniform float absorption_density : hint_range(0.01, 2.0) = 0.3;

// Visual tuning
group_uniforms visual;
uniform float wave_scale : hint_range(0.0, 3.0) = 1.0;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;

// Varyings
varying vec3 v_world_pos;
varying float v_shore_factor;

// ============================================================================
// WAVE CONSTANTS — Must match GerstnerMath.gd WAVES array
// 12 waves: 3 octaves x 4 waves
// Each wave: vec4(dir.x, dir.z, frequency, amplitude), vec2(steepness, speed)
// Packed as 12 x vec4 (dir_freq) + 12 x vec2 (steep_speed) for GPU efficiency
// ============================================================================

// Octave 0 — Swell (wavelength ~150-250m, calm Morrowind Inner Sea)
const vec4 W0_DF = vec4(0.8, 0.6, 0.04, 1.0);
const vec2 W0_SS = vec2(0.3, 0.8);
const vec4 W1_DF = vec4(-0.3, 0.95, 0.035, 0.7);
const vec2 W1_SS = vec2(0.25, 0.7);
const vec4 W2_DF = vec4(0.5, -0.86, 0.03, 0.55);
const vec2 W2_SS = vec2(0.2, 0.6);
const vec4 W3_DF = vec4(-0.7, -0.7, 0.045, 0.4);
const vec2 W3_SS = vec2(0.2, 0.75);

// Octave 1 — Chop (wavelength ~25-40m)
const vec4 W4_DF = vec4(0.9, 0.4, 0.18, 0.25);
const vec2 W4_SS = vec2(0.4, 1.8);
const vec4 W5_DF = vec4(-0.5, 0.87, 0.22, 0.2);
const vec2 W5_SS = vec2(0.35, 2.0);
const vec4 W6_DF = vec4(0.3, -0.95, 0.15, 0.22);
const vec2 W6_SS = vec2(0.3, 1.6);
const vec4 W7_DF = vec4(-0.85, -0.5, 0.2, 0.15);
const vec2 W7_SS = vec2(0.25, 1.9);

// Octave 2 — Ripple (wavelength ~3-5m, close range detail)
const vec4 W8_DF = vec4(0.7, 0.7, 1.5, 0.05);
const vec2 W8_SS = vec2(0.5, 3.5);
const vec4 W9_DF = vec4(-0.6, 0.8, 1.8, 0.04);
const vec2 W9_SS = vec2(0.45, 4.0);
const vec4 W10_DF = vec4(0.4, -0.9, 1.2, 0.045);
const vec2 W10_SS = vec2(0.4, 3.2);
const vec4 W11_DF = vec4(-0.9, -0.4, 1.6, 0.03);
const vec2 W11_SS = vec2(0.35, 3.8);

// Octave distance fade — MUST match GerstnerMath.OCTAVE_FADE_DISTANCES
const float SWELL_FADE = 5000.0;
const float CHOP_FADE = 500.0;
const float RIPPLE_FADE = 150.0;

// Foam texture tiling (world-space meters per tile)
const float FOAM_TILING = 0.15;

// ============================================================================
// GERSTNER WAVE EVALUATION — single wave
// Returns: vec3(dx, dy, dz) displacement
// ============================================================================
vec3 gerstner_disp(vec2 pos, float t, vec4 df, vec2 ss) {
	float phase = (df.x * pos.x + df.y * pos.y) * df.z + t * ss.y;
	float c = cos(phase);
	float s = sin(phase);
	return vec3(ss.x * df.w * df.x * c, df.w * s, ss.x * df.w * df.y * c);
}

// Returns: vec2(dnx, dnz) normal derivative contribution
vec2 gerstner_norm(vec2 pos, float t, vec4 df, vec2 ss) {
	float phase = (df.x * pos.x + df.y * pos.y) * df.z + t * ss.y;
	float c = cos(phase);
	return vec2(-df.x * df.z * df.w * c, -df.y * df.z * df.w * c);
}

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
// VERTEX
// ============================================================================
void vertex() {
	v_shore_factor = sample_shore(VERTEX.xz);

	float dist = length(VERTEX.xz - CAMERA_POSITION_WORLD.xz);
	float shore = v_shore_factor * wave_scale;
	float t = TIME;

	// Octave fades
	float swell_f = shore * smoothstep(SWELL_FADE, SWELL_FADE * 0.8, dist);
	float chop_f = shore * smoothstep(CHOP_FADE, CHOP_FADE * 0.7, dist);
	float ripple_f = shore * smoothstep(RIPPLE_FADE, RIPPLE_FADE * 0.5, dist);

	vec3 d = vec3(0.0);

	// Swell
	d += gerstner_disp(VERTEX.xz, t, W0_DF, W0_SS) * swell_f;
	d += gerstner_disp(VERTEX.xz, t, W1_DF, W1_SS) * swell_f;
	d += gerstner_disp(VERTEX.xz, t, W2_DF, W2_SS) * swell_f;
	d += gerstner_disp(VERTEX.xz, t, W3_DF, W3_SS) * swell_f;

	// Chop
	d += gerstner_disp(VERTEX.xz, t, W4_DF, W4_SS) * chop_f;
	d += gerstner_disp(VERTEX.xz, t, W5_DF, W5_SS) * chop_f;
	d += gerstner_disp(VERTEX.xz, t, W6_DF, W6_SS) * chop_f;
	d += gerstner_disp(VERTEX.xz, t, W7_DF, W7_SS) * chop_f;

	// Ripple
	d += gerstner_disp(VERTEX.xz, t, W8_DF, W8_SS) * ripple_f;
	d += gerstner_disp(VERTEX.xz, t, W9_DF, W9_SS) * ripple_f;
	d += gerstner_disp(VERTEX.xz, t, W10_DF, W10_SS) * ripple_f;
	d += gerstner_disp(VERTEX.xz, t, W11_DF, W11_SS) * ripple_f;

	VERTEX += d;
	v_world_pos = VERTEX;  // After displacement so fragment uses displaced pos
}

// ============================================================================
// FRAGMENT
// ============================================================================
void fragment() {
	if (v_shore_factor < 0.01) {
		discard;
	}

	float dist = length(v_world_pos.xz - CAMERA_POSITION_WORLD.xz);
	float shore = v_shore_factor * wave_scale;
	float t = TIME;

	// Compute analytical normal
	float swell_f = shore * smoothstep(SWELL_FADE, SWELL_FADE * 0.8, dist);
	float chop_f = shore * smoothstep(CHOP_FADE, CHOP_FADE * 0.7, dist);
	float ripple_f = shore * smoothstep(RIPPLE_FADE, RIPPLE_FADE * 0.5, dist);

	vec2 n = vec2(0.0);
	n += gerstner_norm(v_world_pos.xz, t, W0_DF, W0_SS) * swell_f;
	n += gerstner_norm(v_world_pos.xz, t, W1_DF, W1_SS) * swell_f;
	n += gerstner_norm(v_world_pos.xz, t, W2_DF, W2_SS) * swell_f;
	n += gerstner_norm(v_world_pos.xz, t, W3_DF, W3_SS) * swell_f;
	n += gerstner_norm(v_world_pos.xz, t, W4_DF, W4_SS) * chop_f;
	n += gerstner_norm(v_world_pos.xz, t, W5_DF, W5_SS) * chop_f;
	n += gerstner_norm(v_world_pos.xz, t, W6_DF, W6_SS) * chop_f;
	n += gerstner_norm(v_world_pos.xz, t, W7_DF, W7_SS) * chop_f;
	n += gerstner_norm(v_world_pos.xz, t, W8_DF, W8_SS) * ripple_f;
	n += gerstner_norm(v_world_pos.xz, t, W9_DF, W9_SS) * ripple_f;
	n += gerstner_norm(v_world_pos.xz, t, W10_DF, W10_SS) * ripple_f;
	n += gerstner_norm(v_world_pos.xz, t, W11_DF, W11_SS) * ripple_f;

	n *= normal_strength;
	vec3 world_normal = normalize(vec3(n.x, 1.0, n.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);

	// Fresnel — Schlick approximation (F0 = 0.02 for water)
	float cos_theta = max(dot(normalize(-VERTEX), NORMAL), 0.0);
	float fresnel = 0.02 + 0.98 * pow(1.0 - cos_theta, 5.0);

	// Depth — robust linearization for Godot 4 reversed-Z projection
	float surface_dist = -(VIEW_MATRIX * vec4(v_world_pos, 1.0)).z;

	// Fake refraction: distort depth UV by wave normal, scaled by distance
	// Waves shift the apparent position of submerged objects
	vec2 refract_offset = world_normal.xz * refraction_strength / max(surface_dist, 1.0);
	vec2 refract_uv = SCREEN_UV + refract_offset;
	// Clamp to screen to prevent sampling outside viewport
	refract_uv = clamp(refract_uv, vec2(0.001), vec2(0.999));

	// Sample depth at distorted UV — shows submerged geometry shifting with waves
	float depth_raw = texture(DEPTH_TEX, refract_uv).r;
	float floor_dist = PROJECTION_MATRIX[3][2] / (depth_raw + PROJECTION_MATRIX[2][2]);
	float water_depth = max(floor_dist - surface_dist, 0.0);

	// Sanity check: if distorted UV gives nonsensical depth, fall back to undistorted
	if (water_depth > 500.0 || water_depth < 0.0) {
		depth_raw = texture(DEPTH_TEX, SCREEN_UV).r;
		floor_dist = PROJECTION_MATRIX[3][2] / (depth_raw + PROJECTION_MATRIX[2][2]);
		water_depth = max(floor_dist - surface_dist, 0.0);
	}

	// Beer-Lambert absorption — exponential color shift by water thickness
	// R absorbed fastest (warm colors vanish first), G/B persist (underwater looks blue-green)
	vec3 absorption = exp(-water_depth * absorption_rate * absorption_density);
	// Seabed color tinted by absorption (what you'd see looking down through water)
	vec3 refracted_col = color_shore * absorption;
	// Deep water: absorption bottoms out to deep ocean color
	refracted_col = mix(color_deep, refracted_col, exp(-water_depth * absorption_density * 0.5));

	// Blend refraction (steep viewing angle) vs water surface color (grazing angle)
	// At steep angles (low fresnel): see through to seabed with absorption tint
	// At grazing angles (high fresnel): SSR/sky reflections dominate via SPECULAR
	vec3 underwater = mix(refracted_col, color_shallow, fresnel);

	// Foam at edges
	float foam_mask = 0.0;
	if (water_depth < foam_edge_width) {
		float edge_t = 1.0 - water_depth / foam_edge_width;
		vec2 foam_uv = v_world_pos.xz * FOAM_TILING + TIME * foam_scroll_speed;
		float foam_tex = texture(foam_texture, foam_uv).r;
		foam_mask = step(edge_t, foam_tex) * edge_t * v_shore_factor;
	}

	// Compose — shore edges blend toward shore color (no alpha, stays opaque for SSR)
	float shore_blend = smoothstep(0.01, 0.15, v_shore_factor) * clamp(water_depth * 4.0, 0.0, 1.0);
	vec3 final_col = mix(color_shore, mix(underwater, foam_color, foam_mask), shore_blend);

	// Output — fully opaque PBR surface. Godot's SSR + sky reflections work via specular path.
	// Low roughness + specular 0.5 gives realistic Fresnel reflection blending.
	ALBEDO = final_col;
	ROUGHNESS = mix(mix(0.02, 0.15, 1.0 - fresnel), 0.6, foam_mask);
	METALLIC = 0.0;
	SPECULAR = 0.5;
}
