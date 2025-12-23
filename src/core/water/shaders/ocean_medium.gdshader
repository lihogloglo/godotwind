shader_type spatial;
render_mode world_vertex_coords, depth_draw_always;

/**
 * Medium quality water shader
 * Full Gerstner waves with foam and proper lighting
 * No screen/depth texture sampling (avoids GPU-intensive operations)
 * For integrated GPUs (Intel, AMD APU, etc.)
 */

uniform vec4 water_color : source_color = vec4(0.1, 0.15, 0.18, 0.95);
uniform vec4 foam_color : source_color = vec4(0.9, 0.9, 0.9, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.4;
uniform float normal_strength : hint_range(0.0, 1.0) = 1.0;
uniform float time = 0.0;

// Shore mask
uniform sampler2D shore_mask : filter_linear;
uniform vec4 shore_mask_bounds = vec4(-8000.0, -8000.0, 16000.0, 16000.0);

varying float wave_height;
varying float foam_factor;
varying float shore_factor;
varying vec3 wave_gradient;

// Sample shore mask
float sample_shore_mask(vec2 world_xz) {
	vec2 uv = (world_xz - shore_mask_bounds.xy) / shore_mask_bounds.zw;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		return 0.0;
	}
	return texture(shore_mask, uv).r;
}

// Gerstner wave
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

// Analytical gradient of wave
vec2 gerstner_gradient(vec2 pos, float wavelength, float steepness, vec2 direction, float t) {
	float k = 2.0 * PI / wavelength;
	float c = sqrt(9.81 / k);
	vec2 d = normalize(direction);
	float f = k * (dot(d, pos) - c * t);
	float a = steepness / k;
	// Derivative of sin is cos
	float grad = a * k * cos(f);
	return d * grad;
}

void vertex() {
	UV = VERTEX.xz;

	// Sample shore mask
	shore_factor = sample_shore_mask(VERTEX.xz);

	wave_height = 0.0;
	wave_gradient = vec3(0.0, 1.0, 0.0);

	if (shore_factor >= 0.01) {
		vec2 pos = VERTEX.xz;
		float dist = length(pos - CAMERA_POSITION_WORLD.xz);

		if (dist < 800.0) {
			float fade = 1.0 - smoothstep(400.0, 800.0, dist);

			// 4 Gerstner waves for good detail
			vec3 displacement = vec3(0.0);
			vec2 gradient = vec2(0.0);

			displacement += gerstner_wave(pos, 60.0, 0.25, vec2(1.0, 0.0), time);
			gradient += gerstner_gradient(pos, 60.0, 0.25, vec2(1.0, 0.0), time);

			displacement += gerstner_wave(pos, 31.0, 0.25, vec2(1.0, 0.6), time);
			gradient += gerstner_gradient(pos, 31.0, 0.25, vec2(1.0, 0.6), time);

			displacement += gerstner_wave(pos, 18.0, 0.2, vec2(1.0, 1.3), time);
			gradient += gerstner_gradient(pos, 18.0, 0.2, vec2(1.0, 1.3), time);

			displacement += gerstner_wave(pos, 8.0, 0.15, vec2(0.5, 1.0), time);
			gradient += gerstner_gradient(pos, 8.0, 0.15, vec2(0.5, 1.0), time);

			// Apply shore dampening to both displacement and gradient (for normals)
			float shore_fade = shore_factor * fade;
			displacement *= shore_fade;
			gradient *= shore_fade;

			VERTEX += displacement;
			wave_height = displacement.y;
			wave_gradient = vec3(-gradient.x, 1.0, -gradient.y);
		}
	}
}

void fragment() {
	if (shore_factor < 0.01) {
		discard;
	}

	// Calculate normal from gradient
	vec3 normal = normalize(wave_gradient);
	normal = mix(vec3(0.0, 1.0, 0.0), normal, normal_strength);

	// Transform to view space
	NORMAL = normalize((VIEW_MATRIX * vec4(normal, 0.0)).xyz);

	// Fresnel effect
	float fresnel = pow(1.0 - max(dot(VIEW, NORMAL), 0.0), 4.0);
	fresnel = mix(fresnel, 1.0, 0.02); // Add base reflectance

	// Foam from wave steepness
	foam_factor = smoothstep(0.4, 1.0, abs(wave_height) * 2.0);
	foam_factor += (1.0 - shore_factor) * 0.3; // More foam near shore
	foam_factor = clamp(foam_factor, 0.0, 1.0);

	// Sky reflection approximation (no screen texture)
	vec3 sky_color = vec3(0.5, 0.6, 0.8);
	vec3 deep_color = water_color.rgb;

	// Mix based on fresnel and view angle
	ALBEDO = mix(deep_color, sky_color, fresnel * 0.5);
	ALBEDO = mix(ALBEDO, foam_color.rgb, foam_factor * 0.4);

	ROUGHNESS = mix(roughness, 0.6, foam_factor);
	METALLIC = 0.0;
	SPECULAR = 0.5;
	ALPHA = mix(water_color.a, 1.0, foam_factor * 0.5);
}
