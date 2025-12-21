shader_type spatial;
render_mode world_vertex_coords, blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

/**
 * Low quality water shader - 2 Gerstner waves
 * Simpler than MEDIUM (4 waves) for better performance on weak GPUs
 * Still has proper GGX lighting and SSS
 */

#define REFLECTANCE 0.02

uniform vec4 water_color : source_color = vec4(0.02, 0.12, 0.22, 1.0);
uniform vec4 foam_color : source_color = vec4(0.9, 0.9, 0.9, 1.0);
uniform float time : hint_range(0.0, 1000.0) = 0.0;
uniform float wave_scale : hint_range(0.0, 2.0) = 1.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.3;
uniform float refraction_strength : hint_range(0.0, 0.3) = 0.05;
uniform float water_clarity : hint_range(0.0, 1.0) = 0.4;
uniform float depth_fade_distance : hint_range(0.0, 100.0) = 10.0;

varying float wave_height;
varying float foam_factor;
varying float fresnel;

// Gerstner wave with tangent/binormal output
vec3 gerstner_wave(vec2 pos, float wavelength, float steepness, vec2 direction, float time_val, out vec3 tangent, out vec3 binormal) {
	float k = 6.28318 / wavelength;
	float c = sqrt(9.81 / k);
	vec2 d = normalize(direction);
	float f = k * (dot(d, pos) - c * time_val);
	float a = steepness / k;

	float cos_f = cos(f);
	float sin_f = sin(f);

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

	// Distance-based LOD
	float dist = length(pos - CAMERA_POSITION_WORLD.xz);
	float distance_fade = 1.0 - smoothstep(200.0, 400.0, dist);

	// Only 2 waves for LOW quality (vs 4 for MEDIUM)
	vec3 displacement = vec3(0.0);
	vec3 tangent_sum = vec3(1.0, 0.0, 0.0);
	vec3 binormal_sum = vec3(0.0, 0.0, 1.0);
	vec3 t, b;

	// Wave 1: Large swell
	displacement += gerstner_wave(pos, 60.0, 0.18 * wave_scale, vec2(1.0, 0.3), time, t, b);
	tangent_sum += t - vec3(1.0, 0.0, 0.0);
	binormal_sum += b - vec3(0.0, 0.0, 1.0);

	// Wave 2: Secondary wave
	displacement += gerstner_wave(pos, 28.0, 0.14 * wave_scale, vec2(0.8, 1.0), time * 1.1, t, b);
	tangent_sum += t - vec3(1.0, 0.0, 0.0);
	binormal_sum += b - vec3(0.0, 0.0, 1.0);

	VERTEX += displacement * distance_fade;
	wave_height = displacement.y * distance_fade;
	NORMAL = normalize(cross(binormal_sum, tangent_sum));

	UV = pos * 0.01;
}

void fragment() {
	foam_factor = smoothstep(1.0, 2.5, abs(wave_height));
	foam_factor = clamp(foam_factor, 0.0, 0.5);

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

	// Alpha for transparency
	ALPHA = mix(water_clarity, 1.0, fresnel * 0.5);

	ROUGHNESS = mix(0.05, 0.6, foam_factor);
	METALLIC = 0.0;
	SPECULAR = 0.5;
	SSS_STRENGTH = 0.05;
}

// Simplified GGX for LOW quality - skip smith masking for performance
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

	// Simplified specular (no smith masking for performance)
	float D = ggx_distribution(dot_nh, roughness);
	float spec = fresnel * D * 0.25; // Simplified geometric term
	SPECULAR_LIGHT += spec * ATTENUATION * LIGHT_COLOR;

	// Simplified SSS
	const vec3 sss_color = vec3(0.1, 0.4, 0.35);
	float backlit = pow(max(dot(LIGHT, -VIEW), 0.0), 4.0);
	float sss = max(0.0, wave_height + 1.0) * backlit * 0.5;

	vec3 diff_color = mix(water_color.rgb, sss_color, sss * 0.4);
	diff_color = mix(diff_color, foam_color.rgb, foam_factor);

	DIFFUSE_LIGHT += diff_color * dot_nl * (1.0 - fresnel) * ATTENUATION * LIGHT_COLOR;
}
