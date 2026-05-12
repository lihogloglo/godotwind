// ============================================================================
// Shared analytical shore swash helpers.
// ============================================================================
// Consumers must declare:
//   uniform sampler2D shore_mask;
//   uniform vec4 shore_mask_bounds;
//   uniform float shore_fade_distance;
//   uniform float shore_wave_amplitude;
//   uniform float shore_wave_frequency;
//   uniform float shore_wave_speed;
//   uniform float shore_wave_steepness;
//   uniform float ocean_time;

const float SHORE_TAU = 6.2831853;

vec2 water_surface_shore_uv(vec2 world_xz) {
	return (world_xz - shore_mask_bounds.xy) / shore_mask_bounds.zw;
}

bool water_surface_shore_uv_in_bounds(vec2 shore_uv) {
	return shore_uv.x >= 0.0 && shore_uv.x <= 1.0 && shore_uv.y >= 0.0 && shore_uv.y <= 1.0;
}

vec4 water_surface_shore_sample(vec2 shore_uv, bool use_shore_mask) {
	return use_shore_mask && water_surface_shore_uv_in_bounds(shore_uv)
		? texture(shore_mask, shore_uv)
		: vec4(1.0, 0.5, 0.5, 1.0);
}

float water_surface_shore_water_distance_norm(vec4 shore_data) {
	return clamp(shore_data.a * 2.0 - 1.0, 0.0, 1.0);
}

float water_surface_shore_body_coverage(vec4 shore_data) {
	return step(0.25, shore_data.a);
}

float shore_breaker_envelope(float raw_dist) {
	float dist_t = clamp(raw_dist / max(shore_fade_distance, 0.001), 0.0, 1.0);
	float shore_ramp = smoothstep(0.05, 0.20, dist_t);
	float offshore_fade = 1.0 - smoothstep(0.42, 0.82, dist_t);
	return shore_ramp * offshore_fade;
}

float shore_runup_envelope(float raw_dist) {
	float dist_t = clamp(raw_dist / max(shore_fade_distance, 0.001), 0.0, 1.0);
	return 1.0 - smoothstep(0.00, 0.12, dist_t);
}

float shore_swash_curve(float phase) {
	float cycle = fract(phase / SHORE_TAU);
	float uprush = smoothstep(0.02, 0.24, cycle);
	float backwash = 1.0 - smoothstep(0.24, 0.72, cycle);
	return uprush * backwash;
}

float shore_skewed_sine(float phase, float steepness) {
	float s = sin(phase);
	float c = cos(phase);
	float skew = clamp(0.22 + 0.22 * steepness, 0.0, 0.44);
	return clamp(s + (2.0 * s * c) * skew, -1.0, 1.0);
}

float shore_crest_shape(float phase, float steepness) {
	float skew_s = shore_skewed_sine(phase, steepness);
	float crest = max(skew_s, 0.0);
	float trough = max(-skew_s, 0.0);
	float crest2 = crest * crest;
	float shaped_crest = crest2 * (1.65 - 0.65 * crest);
	float broad_trough = trough * (2.0 - trough);
	return shaped_crest - broad_trough * mix(0.40, 0.22, steepness);
}

float shore_profile_slope(float phase, float steepness) {
	float c = cos(phase);
	float skew_s = shore_skewed_sine(phase, steepness);
	float crest = max(skew_s, 0.0);
	float trough = max(-skew_s, 0.0);
	float crest_slope = 3.30 * crest - 1.95 * crest * crest;
	float trough_slope = mix(0.80, 0.44, steepness) * (1.0 - trough);
	return c * mix(trough_slope, crest_slope, step(0.0, skew_s));
}

float shore_forward_push(float phase, float steepness) {
	float crest = max(shore_skewed_sine(phase, steepness), 0.0);
	return cos(phase) * (0.45 + 0.35 * crest);
}

float shore_along_modulation(vec2 world_xz, vec2 shore_dir) {
	vec2 tangent = vec2(-shore_dir.y, shore_dir.x);
	float along = dot(world_xz, tangent);
	float n = sin(along * 0.035 + ocean_time * 0.19) * 0.50
		+ sin(along * 0.079 - ocean_time * 0.13) * 0.25;
	return clamp(0.78 + n * 0.28, 0.55, 1.0);
}

vec2 shore_direction_from_mask(vec2 shore_uv, vec2 encoded_dir) {
	vec2 dir = encoded_dir * 2.0 - 1.0;
	if (length(dir) > 0.01) {
		return normalize(dir);
	}

	vec2 texel = 1.0 / vec2(textureSize(shore_mask, 0));
	for (int radius = 1; radius <= 8; radius *= 2) {
		vec2 step_uv = texel * float(radius);
		float x_pos = texture(shore_mask, clamp(shore_uv + vec2(step_uv.x, 0.0), vec2(0.0), vec2(1.0))).a;
		float x_neg = texture(shore_mask, clamp(shore_uv - vec2(step_uv.x, 0.0), vec2(0.0), vec2(1.0))).a;
		float z_pos = texture(shore_mask, clamp(shore_uv + vec2(0.0, step_uv.y), vec2(0.0), vec2(1.0))).a;
		float z_neg = texture(shore_mask, clamp(shore_uv - vec2(0.0, step_uv.y), vec2(0.0), vec2(1.0))).a;
		vec2 gradient_dir = vec2(x_pos - x_neg, z_pos - z_neg);
		if (length(gradient_dir) > 1e-5) {
			return normalize(gradient_dir);
		}
	}
	return vec2(0.0);
}

float water_surface_shore_phase(float raw_dist) {
	return raw_dist * shore_wave_frequency * SHORE_TAU + ocean_time * shore_wave_speed * SHORE_TAU;
}

vec4 water_surface_shore_offset(vec2 world_xz, vec2 shore_uv, bool in_mask, vec4 shore_data) {
	float raw_dist = water_surface_shore_water_distance_norm(shore_data) * shore_fade_distance;
	vec2 shore_dir = in_mask ? shore_direction_from_mask(shore_uv, shore_data.gb) : vec2(0.0);
	float shore_dir_len = length(shore_dir);
	if (shore_dir_len <= 0.01 || shore_wave_amplitude <= 0.0) {
		return vec4(0.0);
	}

	shore_dir /= shore_dir_len;
	float phase = water_surface_shore_phase(raw_dist);
	float modulation = shore_along_modulation(world_xz, shore_dir);
	float breaker_env = shore_breaker_envelope(raw_dist);
	float runup_env = shore_runup_envelope(raw_dist);
	float swash = shore_swash_curve(phase);
	float mod_runup = runup_env * swash * mix(0.65, 1.0, modulation);
	float shore_y = shore_wave_amplitude * (
		breaker_env * modulation * shore_crest_shape(phase, shore_wave_steepness)
		+ mod_runup * 0.32
	);
	float shore_xz = shore_wave_amplitude * shore_wave_steepness * (
		breaker_env * modulation * shore_forward_push(phase, shore_wave_steepness)
		+ mod_runup * 1.10
	);
	return vec4(-shore_dir * shore_xz, shore_y, abs(shore_xz) * 0.65);
}

vec2 water_surface_shore_slope(vec2 world_xz, vec2 shore_uv, bool in_mask, vec4 shore_data) {
	float raw_dist = water_surface_shore_water_distance_norm(shore_data) * shore_fade_distance;
	vec2 shore_dir = in_mask ? shore_direction_from_mask(shore_uv, shore_data.gb) : vec2(0.0);
	float shore_dir_len = length(shore_dir);
	if (shore_dir_len <= 0.01 || shore_wave_amplitude <= 0.0) {
		return vec2(0.0);
	}

	shore_dir /= shore_dir_len;
	float phase = water_surface_shore_phase(raw_dist);
	float modulation = shore_along_modulation(world_xz, shore_dir);
	float breaker_env = shore_breaker_envelope(raw_dist);
	float runup_env = shore_runup_envelope(raw_dist);
	float swash = shore_swash_curve(phase);
	float mod_runup = runup_env * swash * mix(0.65, 1.0, modulation);
	float slope = shore_wave_amplitude * shore_wave_frequency * SHORE_TAU * (
		breaker_env * modulation * shore_profile_slope(phase, shore_wave_steepness)
		+ mod_runup * 0.10 * cos(phase)
	);
	return shore_dir * clamp(slope, -1.6, 1.6);
}
