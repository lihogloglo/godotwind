shader_type spatial;
render_mode world_vertex_coords, depth_draw_always, cull_disabled;

// Godot 4.3+ requires explicit screen texture samplers
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;

/**
 * LOW quality water shader - 2 Gerstner waves
 * Simpler than MEDIUM (4 waves) for better performance on weak GPUs
 * Still has GGX lighting, SSS, and depth-based color absorption
 */

#define REFLECTANCE 0.02

uniform vec4 water_color : source_color = vec4(0.1, 0.15, 0.18, 1.0);
uniform vec4 foam_color : source_color = vec4(0.9, 0.9, 0.9, 1.0);
uniform vec3 depth_color_consumption = vec3(1.5, 4.0, 8.0); // RGB absorption depths in meters (murky water)
uniform float time : hint_range(0.0, 1000.0) = 0.0;
uniform float wave_scale : hint_range(0.0, 4.0) = 2.5; // Default to strong waves for testing
uniform float roughness : hint_range(0.0, 1.0) = 0.3;

// Shore mask for fading ocean on land
uniform sampler2D shore_mask : filter_linear;
uniform vec4 shore_mask_bounds = vec4(-8000.0, -8000.0, 16000.0, 16000.0);

varying float wave_height;
varying float foam_factor;
varying float fresnel;
varying float shore_factor;

// Sample shore mask - 1.0 = ocean, 0.0 = land
float sample_shore_mask(vec2 world_xz) {
	vec2 uv = (world_xz - shore_mask_bounds.xy) / shore_mask_bounds.zw;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		return 1.0; // Outside mask bounds = assume ocean
	}
	return texture(shore_mask, uv).r;
}

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
	UV = pos;

	// Distance-based LOD (more aggressive for LOW quality)
	float dist = length(pos - CAMERA_POSITION_WORLD.xz);
	float distance_fade = 1.0 - smoothstep(200.0, 400.0, dist);

	// Sample shore mask
	shore_factor = sample_shore_mask(pos);

	// Only 2 waves for LOW quality (vs 4 for MEDIUM)
	vec3 displacement = vec3(0.0);
	vec3 tangent_sum = vec3(1.0, 0.0, 0.0);
	vec3 binormal_sum = vec3(0.0, 0.0, 1.0);
	vec3 t, b;

	// Wave 1: Large swell (steepness increased for dramatic waves)
	displacement += gerstner_wave(pos, 60.0, 0.40 * wave_scale, vec2(1.0, 0.3), time, t, b);
	tangent_sum += t - vec3(1.0, 0.0, 0.0);
	binormal_sum += b - vec3(0.0, 0.0, 1.0);

	// Wave 2: Secondary wave
	displacement += gerstner_wave(pos, 28.0, 0.30 * wave_scale, vec2(0.8, 1.0), time * 1.1, t, b);
	tangent_sum += t - vec3(1.0, 0.0, 0.0);
	binormal_sum += b - vec3(0.0, 0.0, 1.0);

	// Apply displacement with distance fade and shore dampening
	float total_fade = distance_fade * shore_factor;
	VERTEX += displacement * total_fade;
	wave_height = displacement.y * total_fade;  // FIXED: Apply shore_factor to wave_height too

	// Damp normals near shore to match damped geometry
	vec3 wave_normal = normalize(cross(binormal_sum, tangent_sum));
	NORMAL = normalize(mix(vec3(0.0, 1.0, 0.0), wave_normal, shore_factor));
}

void fragment() {
	// Discard if not in ocean
	if (shore_factor < 0.01) {
		discard;
	}

	// Calculate foam from wave height
	foam_factor = smoothstep(1.0, 2.5, abs(wave_height));
	// Add shore foam
	foam_factor += (1.0 - shore_factor) * 0.5;
	foam_factor = clamp(foam_factor, 0.0, 1.0);

	float NdotV = max(dot(VIEW, NORMAL), 0.001);
	fresnel = REFLECTANCE + (1.0 - REFLECTANCE) * pow(1.0 - NdotV, 5.0);

	// Depth-based effects
	float depth_tex = texture(depth_texture, SCREEN_UV).r;
	vec4 world_pos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth_tex, 1.0);
	world_pos.xyz /= world_pos.w;

	// Alpha based on depth
	float smooth_alpha = 1.0 - smoothstep(world_pos.z + 0.66, world_pos.z, VERTEX.z);
	ALPHA = clamp(smooth_alpha * shore_factor, 0.0, 1.0);

	// Increase foam in shallow areas
	if (ALPHA < 0.9) {
		foam_factor = clamp(foam_factor + 0.5 - ALPHA, 0.0, 1.0);
	}

	// ============ DEPTH-BASED COLOR ABSORPTION ============
	// water_depth: positive value = how far below water surface the floor is
	float water_depth = VERTEX.z - world_pos.z;
	float depth_visibility_range = clamp(max(depth_color_consumption.r, max(depth_color_consumption.g, depth_color_consumption.b)), 0.0, 200.0);

	// factor_translucency: 0 = transparent (shallow), 1 = opaque water_color (deep)
	float factor_translucency = smoothstep(0.0, depth_visibility_range, water_depth);

	// Sample what's behind the water
	vec3 screen_albedo = texture(screen_texture, SCREEN_UV).rgb;

	// Base water color mixed with background
	vec3 depth_water_color = mix(screen_albedo, water_color.rgb, factor_translucency);

	// Per-channel color absorption (red fades first, then green, blue last)
	float shallow_red = 1.0 - smoothstep(0.0, depth_color_consumption.r, water_depth);
	float shallow_green = 1.0 - smoothstep(0.0, depth_color_consumption.g, water_depth);
	float shallow_blue = 1.0 - smoothstep(0.0, depth_color_consumption.b, water_depth);
	vec3 color_absorbed = vec3(shallow_red, shallow_green, shallow_blue) * screen_albedo;
	vec3 color_shallow = max(color_absorbed, water_color.rgb);

	// Final water color with depth absorption
	depth_water_color = mix(color_shallow, water_color.rgb, factor_translucency);

	// Mix in foam
	ALBEDO = mix(depth_water_color, foam_color.rgb, foam_factor);

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
