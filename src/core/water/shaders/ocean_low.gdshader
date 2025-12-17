shader_type spatial;
render_mode world_vertex_coords, depth_draw_always;

/**
 * Low quality water shader
 * Simple Gerstner waves with basic lighting
 * No screen/depth texture sampling
 * For old or low-end GPUs
 */

uniform vec4 water_color : source_color = vec4(0.02, 0.08, 0.15, 0.9);
uniform vec4 foam_color : source_color = vec4(0.9, 0.9, 0.9, 1.0);
uniform float time = 0.0;

varying vec3 world_normal;
varying float wave_height;

// Simple Gerstner wave
vec3 gerstner_wave(vec2 pos, float wavelength, float steepness, vec2 direction, float t) {
	float k = 2.0 * PI / wavelength;
	float c = sqrt(9.81 / k);
	vec2 d = normalize(direction);
	float f = k * (dot(d, pos) - c * t);
	float a = steepness / k;
	return vec3(
		d.x * (a * cos(f)),
		a * sin(f),
		d.y * (a * cos(f))
	);
}

void vertex() {
	vec2 pos = VERTEX.xz;

	// Only 2 waves for performance
	vec3 displacement = vec3(0.0);
	displacement += gerstner_wave(pos, 50.0, 0.2, vec2(1.0, 0.3), time);
	displacement += gerstner_wave(pos, 25.0, 0.15, vec2(0.7, 1.0), time);

	// Distance-based fade to reduce popping
	float dist = length(pos - CAMERA_POSITION_WORLD.xz);
	float fade = 1.0 - smoothstep(300.0, 500.0, dist);

	VERTEX += displacement * fade;
	wave_height = displacement.y * fade;

	// Calculate normal analytically
	float eps = 0.5;
	vec3 dx = gerstner_wave(pos + vec2(eps, 0), 50.0, 0.2, vec2(1.0, 0.3), time)
			+ gerstner_wave(pos + vec2(eps, 0), 25.0, 0.15, vec2(0.7, 1.0), time);
	vec3 dz = gerstner_wave(pos + vec2(0, eps), 50.0, 0.2, vec2(1.0, 0.3), time)
			+ gerstner_wave(pos + vec2(0, eps), 25.0, 0.15, vec2(0.7, 1.0), time);

	vec3 tangent = vec3(eps, dx.y - displacement.y, 0.0);
	vec3 bitangent = vec3(0.0, dz.y - displacement.y, eps);
	world_normal = normalize(cross(bitangent, tangent));
}

void fragment() {
	// Simple fresnel
	float fresnel = pow(1.0 - max(dot(VIEW, NORMAL), 0.0), 3.0);

	// Mix water color with sky reflection approximation
	vec3 sky_color = vec3(0.6, 0.7, 0.9);
	ALBEDO = mix(water_color.rgb, sky_color, fresnel * 0.4);

	// Simple foam from wave height
	float foam = smoothstep(0.3, 0.8, wave_height);
	ALBEDO = mix(ALBEDO, foam_color.rgb, foam * 0.3);

	ROUGHNESS = mix(0.1, 0.4, foam);
	METALLIC = 0.0;
	ALPHA = water_color.a;
}
