// Per-pixel object wetness shader — Lagarde PBR wet surfaces.
// Darkens and glossifies only the portion of the mesh below wet_line_y.
// wet_line_y tracks the "high water mark" and decays over time (drying from top).
//
// Usage: assign as ShaderMaterial on any MeshInstance3D.
// Push wet_line_y from GDScript via RenderingServer.material_set_param().

shader_type spatial;

#define MAX_CASCADES 8

global uniform uint num_cascades;
global uniform sampler2DArray displacements;

// Object appearance (set from GDScript to match the original material)
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.7;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float specular : hint_range(0.0, 1.0) = 0.5;
uniform sampler2D albedo_texture : source_color, hint_default_white;

// Wet map parameters. `wet_line_y` is retained high-water memory; the optional
// dynamic water path adds the current FFT/shore waterline per fragment.
uniform float wet_line_y = -1000.0; // world-space Y of the water line on this object
uniform float wet_margin : hint_range(0.0, 2.0) = 0.3; // capillary rise above wet_line
uniform float wet_albedo_darken : hint_range(0.0, 1.0) = 0.6;
uniform float wet_roughness_target : hint_range(0.0, 0.3) = 0.05;
uniform bool wet_debug = false;
uniform bool dynamic_water_enabled = false;
uniform bool dynamic_water_has_shore_mask = false;
uniform vec3 camera_world_position = vec3(0.0);
uniform float sea_level = 0.0;
uniform float wave_scale = 1.0;
uniform float ocean_time = 0.0;
uniform vec4 map_scales[MAX_CASCADES];
uniform sampler2D shore_mask : filter_linear_mipmap, repeat_disable;
uniform vec4 shore_mask_bounds = vec4(-8000.0, -8000.0, 16000.0, 16000.0);
uniform float shore_fade_distance : hint_range(10.0, 200.0) = 50.0;
uniform float shore_wave_amplitude : hint_range(0.0, 3.0) = 0.0;
uniform float shore_wave_frequency : hint_range(0.02, 0.5) = 0.1;
uniform float shore_wave_speed : hint_range(0.1, 5.0) = 0.4;
uniform float shore_wave_steepness : hint_range(0.0, 1.0) = 0.58;

// World-space position passed from vertex to fragment
varying vec3 v_world_pos;

const float SHORE_TAU = 6.2831853;

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

float dynamic_water_level(vec2 world_xz) {
	if (!dynamic_water_enabled) {
		return sea_level;
	}

	float dist_to_camera = length(vec3(world_xz.x, sea_level, world_xz.y) - camera_world_position);
	vec3 displacement = vec3(0.0);
	for (int i = 0; i < MAX_CASCADES; ++i) {
		if (uint(i) >= num_cascades) {
			break;
		}
		vec4 scales = map_scales[i];
		float tile_size = 1.0 / max(scales.x, 1e-6);
		float cascade_fade = clamp(exp(-(dist_to_camera - 50.0) / (tile_size * 20.0)), 0.0, 1.0);
		displacement += texture(displacements, vec3(world_xz * scales.xy, float(i))).xyz * scales.z * cascade_fade;
	}

	vec4 shore_data = vec4(1.0, 0.5, 0.5, 1.0);
	vec2 shore_uv = (world_xz - shore_mask_bounds.xy) / shore_mask_bounds.zw;
	bool in_mask = dynamic_water_has_shore_mask
		&& shore_uv.x >= 0.0 && shore_uv.x <= 1.0
		&& shore_uv.y >= 0.0 && shore_uv.y <= 1.0;
	if (in_mask) {
		shore_data = texture(shore_mask, shore_uv);
	}

	float shore = shore_data.r;
	float water_y = sea_level + displacement.y * wave_scale * shore;
	float raw_dist = shore_data.a * shore_fade_distance;
	vec2 shore_dir = in_mask ? shore_direction_from_mask(shore_uv, shore_data.gb) : vec2(0.0);
	if (length(shore_dir) > 0.01 && shore_wave_amplitude > 0.0) {
		shore_dir = normalize(shore_dir);
		float phase = raw_dist * shore_wave_frequency * SHORE_TAU + ocean_time * shore_wave_speed * SHORE_TAU;
		float modulation = shore_along_modulation(world_xz, shore_dir);
		float breaker_env = shore_breaker_envelope(raw_dist);
		float runup_env = shore_runup_envelope(raw_dist);
		float swash = shore_swash_curve(phase);
		float mod_runup = runup_env * swash * mix(0.65, 1.0, modulation);
		water_y += shore_wave_amplitude * (
			breaker_env * modulation * shore_crest_shape(phase, shore_wave_steepness)
			+ mod_runup * 0.32
		);
	}
	return water_y;
}

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec4 tex = texture(albedo_texture, UV);
	vec3 base_albedo = albedo_color.rgb * tex.rgb;
	float base_roughness = roughness;

	ALBEDO = base_albedo;
	ROUGHNESS = base_roughness;
	METALLIC = metallic;
	SPECULAR = specular;

	// Per-pixel wetness: current water contact plus retained high-water memory.
	float memory_wetness = smoothstep(wet_line_y + wet_margin, wet_line_y, v_world_pos.y);
	float contact_water_y = dynamic_water_level(v_world_pos.xz);
	float contact_wetness = dynamic_water_enabled
		? smoothstep(contact_water_y + wet_margin, contact_water_y, v_world_pos.y)
		: 0.0;
	float wetness = max(memory_wetness, contact_wetness);

	if (wet_debug) {
		ALBEDO = mix(ALBEDO, vec3(0.0, 0.2, 0.8), wetness * 0.8);
	} else if (wetness > 0.001) {
		float porosity = clamp((base_roughness - 0.2) / 0.6, 0.0, 1.0);
		float effective_wet = wetness * porosity;
		ALBEDO *= mix(1.0, 1.0 - wet_albedo_darken, effective_wet);
		ROUGHNESS = mix(ROUGHNESS, wet_roughness_target, effective_wet);
	}
}
