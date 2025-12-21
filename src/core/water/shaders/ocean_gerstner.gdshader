shader_type spatial;
render_mode world_vertex_coords, blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

/**
 * Vertex shader Gerstner waves for LOW/MEDIUM quality setting
 * Animated waves calculated entirely in vertex shader - no compute shaders needed
 * Works on any GPU including integrated graphics
 * Lighting model from GDC 2019: "Wakes, Explosions and Lighting: Interactive Water Simulation in Atlas"
 * Based on: https://developer.nvidia.com/gpugems/gpugems/part-i-natural-effects/chapter-1-effective-water-simulation-physical-models
 */

#define REFLECTANCE 0.02 // Reflectance from air to water (eta=1.33)

uniform vec4 water_color : source_color = vec4(0.02, 0.12, 0.22, 1.0);
uniform vec4 foam_color : source_color = vec4(0.9, 0.9, 0.9, 1.0);
uniform float time : hint_range(0.0, 1000.0) = 0.0;
uniform float wave_scale : hint_range(0.0, 2.0) = 1.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.3;
uniform float refraction_strength : hint_range(0.0, 0.3) = 0.05;
uniform float water_clarity : hint_range(0.0, 1.0) = 0.4;
uniform float depth_fade_distance : hint_range(0.0, 100.0) = 10.0;

// Varyings for lighting
varying float wave_height;
varying float foam_factor;
varying float fresnel;

// Gerstner wave function
// Returns displacement and contributes to normal calculation
vec3 gerstner_wave(vec2 pos, float wavelength, float steepness, vec2 direction, float time_val, out vec3 tangent, out vec3 binormal) {
	float k = 6.28318 / wavelength;  // 2*PI / wavelength
	float c = sqrt(9.81 / k);        // Phase speed
	vec2 d = normalize(direction);
	float f = k * (dot(d, pos) - c * time_val);
	float a = steepness / k;

	float cos_f = cos(f);
	float sin_f = sin(f);

	// Tangent and binormal for normal calculation
	tangent = vec3(
		1.0 - d.x * d.x * steepness * sin_f,
		d.x * steepness * cos_f,
		-d.x * d.y * steepness * sin_f
	);
	binormal = vec3(
		-d.x * d.y * steepness * sin_f,
		d.y * steepness * cos_f,
		1.0 - d.y * d.y * steepness * sin_f
	);

	return vec3(
		d.x * a * cos_f,
		a * sin_f,
		d.y * a * cos_f
	);
}

void vertex() {
	vec2 pos = VERTEX.xz;

	// Distance-based LOD for wave detail
	float dist = length(pos - CAMERA_POSITION_WORLD.xz);
	float distance_fade = 1.0 - smoothstep(300.0, 600.0, dist);

	// Sum multiple Gerstner waves with different parameters
	vec3 displacement = vec3(0.0);
	vec3 tangent_sum = vec3(1.0, 0.0, 0.0);
	vec3 binormal_sum = vec3(0.0, 0.0, 1.0);
	vec3 t, b;

	// Wave 1: Large swell
	displacement += gerstner_wave(pos, 60.0, 0.15 * wave_scale, vec2(1.0, 0.3), time, t, b);
	tangent_sum += t - vec3(1.0, 0.0, 0.0);
	binormal_sum += b - vec3(0.0, 0.0, 1.0);

	// Wave 2: Medium waves
	displacement += gerstner_wave(pos, 31.0, 0.12 * wave_scale, vec2(1.0, 0.8), time * 1.1, t, b);
	tangent_sum += t - vec3(1.0, 0.0, 0.0);
	binormal_sum += b - vec3(0.0, 0.0, 1.0);

	// Wave 3: Smaller detail
	displacement += gerstner_wave(pos, 18.0, 0.10 * wave_scale, vec2(0.8, 1.0), time * 1.2, t, b);
	tangent_sum += t - vec3(1.0, 0.0, 0.0);
	binormal_sum += b - vec3(0.0, 0.0, 1.0);

	// Wave 4: Fine ripples
	displacement += gerstner_wave(pos, 8.0, 0.05 * wave_scale, vec2(0.5, 1.2), time * 1.3, t, b);
	tangent_sum += t - vec3(1.0, 0.0, 0.0);
	binormal_sum += b - vec3(0.0, 0.0, 1.0);

	// Apply displacement with distance fade
	VERTEX += displacement * distance_fade;
	wave_height = displacement.y * distance_fade;

	// Calculate normal from tangent and binormal
	NORMAL = normalize(cross(binormal_sum, tangent_sum));

	UV = pos * 0.01;
}

void fragment() {
	// NORMAL is already in view space from Godot's pipeline with world_vertex_coords

	// Calculate foam from wave height only (steepness is unreliable after interpolation)
	foam_factor = smoothstep(0.8, 2.0, abs(wave_height));
	foam_factor = clamp(foam_factor, 0.0, 0.6); // Cap foam to avoid pure white

	// Fresnel effect - physically based
	float NdotV = max(dot(VIEW, NORMAL), 0.001);
	fresnel = REFLECTANCE + (1.0 - REFLECTANCE) * pow(1.0 - NdotV, 5.0);

	// Refraction using screen texture
	vec2 refraction_offset = NORMAL.xy * refraction_strength;
	vec3 refracted_color = textureLod(SCREEN_TEXTURE, SCREEN_UV + refraction_offset, 0.0).rgb;

	// Depth-based transparency
	float depth = texture(DEPTH_TEXTURE, SCREEN_UV).r;
	vec4 world_pos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float depth_diff = world_pos.z / world_pos.w - VERTEX.z;
	float water_depth_fade = 1.0 - exp(-depth_diff / depth_fade_distance);

	// Mix refracted color with water color based on depth
	vec3 water_with_refraction = mix(refracted_color, water_color.rgb, water_depth_fade * (1.0 - water_clarity));
	ALBEDO = mix(water_with_refraction, foam_color.rgb, foam_factor);

	// Alpha for transparency (less transparent at steep viewing angles due to fresnel)
	ALPHA = mix(water_clarity, 1.0, fresnel * 0.5);

	// Roughness increases with foam
	ROUGHNESS = mix(0.05, 0.6, foam_factor);
	METALLIC = 0.0;
	SPECULAR = 0.5;

	// Enable subsurface scattering
	SSS_STRENGTH = 0.05;
}

// Smith masking-shadowing function for GGX
float smith_masking_shadowing(in float cos_theta, in float alpha) {
	float a = cos_theta / (alpha * sqrt(1.0 - cos_theta * cos_theta));
	float a_sq = a * a;
	return a < 1.6 ? (1.0 - 1.259 * a + 0.396 * a_sq) / (3.535 * a + 2.181 * a_sq) : 0.0;
}

// GGX microfacet distribution
float ggx_distribution(in float cos_theta, in float alpha) {
	float a_sq = alpha * alpha;
	float d = 1.0 + (a_sq - 1.0) * cos_theta * cos_theta;
	return a_sq / (PI * d * d);
}

void light() {
	vec3 halfway = normalize(LIGHT + VIEW);
	float dot_nl = max(dot(NORMAL, LIGHT), 0.001);
	float dot_nv = max(dot(NORMAL, VIEW), 0.001);
	float dot_nh = max(dot(NORMAL, halfway), 0.001);

	// --- SPECULAR (GGX) ---
	// Note: smith_masking_shadowing(cos_theta, alpha) - parameters were swapped in original!
	float view_mask = smith_masking_shadowing(dot_nv, roughness);
	float light_mask = smith_masking_shadowing(dot_nl, roughness);
	float D = ggx_distribution(dot_nh, roughness);
	float G = 1.0 / (1.0 + view_mask + light_mask);
	float spec = fresnel * D * G / (4.0 * dot_nv + 0.1);
	SPECULAR_LIGHT += spec * ATTENUATION * LIGHT_COLOR;

	// --- DIFFUSE with Subsurface Scattering ---
	const vec3 sss_color = vec3(0.1, 0.4, 0.35); // Teal/green SSS color
	// SSS through wave peaks when backlit
	float backlit = pow(max(dot(LIGHT, -VIEW), 0.0), 4.0);
	float wrap = pow(0.5 - 0.5 * dot(LIGHT, NORMAL), 2.0);
	float sss = max(0.0, wave_height + 1.0) * backlit * wrap;

	// Lambertian diffuse
	float diffuse = dot_nl;

	// Combine diffuse and SSS
	vec3 diffuse_color = mix(water_color.rgb, sss_color, sss * 0.5);
	diffuse_color = mix(diffuse_color, foam_color.rgb, foam_factor);

	DIFFUSE_LIGHT += diffuse_color * diffuse * (1.0 - fresnel) * ATTENUATION * LIGHT_COLOR;
}
