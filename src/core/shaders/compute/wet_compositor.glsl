#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_tex;
layout(set = 0, binding = 2) uniform sampler2D normal_roughness_tex;
layout(set = 0, binding = 3) uniform sampler2DArray displacement_tex;
layout(set = 0, binding = 4) uniform sampler2D shore_mask_tex;

#define MAX_CASCADES 8

layout(std430, set = 0, binding = 5) readonly buffer WetnessState {
	mat4 inv_projection;
	mat4 inv_view;
	vec4 map_scales[MAX_CASCADES];
	vec4 shore_mask_bounds;
	vec4 shore_params0; // x=fade, y=amp, z=freq, w=speed
	vec4 shore_params1; // x=steep, yzw=reserved
} state;

layout(push_constant, std430) uniform Params {
	vec4 screen; // x=width, y=height, z=time, w=blend
	vec4 water; // x=sea_level, y=wave_scale, z=cascade_count, w=wet_margin
vec4 wet; // x=albedo_darken, y=roughness_target, z=submerged_optics_depth, w=debug_mode
	vec4 flags; // x=displacement_valid, y=normal_valid, z=shore_valid, w=reserved
} pc;

#define screen_w pc.screen.x
#define screen_h pc.screen.y
#define TIME pc.screen.z
#define blend_factor pc.screen.w
#define sea_level pc.water.x
#define wave_scale pc.water.y
#define cascade_count int(pc.water.z)
#define wet_margin pc.water.w
#define wet_albedo_darken pc.wet.x
#define wet_roughness_target pc.wet.y
#define submerged_optics_depth pc.wet.z
#define debug_mode int(pc.wet.w + 0.5)
#define displacement_valid (pc.flags.x > 0.5)
#define normal_valid (pc.flags.y > 0.5)

const float SHORE_TAU = 6.2831853;

struct SurfaceSample {
	float y;
	vec2 horizontal_offset;
};

struct WaterSurfaceContractSample {
	float y;
	vec2 horizontal_offset;
	float coverage;
	float body_gate;
	float depth;
};

float hash21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float value_noise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float shore_breaker_envelope(float raw_dist, float shore_fade_distance) {
	float dist_t = clamp(raw_dist / max(shore_fade_distance, 0.001), 0.0, 1.0);
	float shore_ramp = smoothstep(0.05, 0.20, dist_t);
	float offshore_fade = 1.0 - smoothstep(0.42, 0.82, dist_t);
	return shore_ramp * offshore_fade;
}

float shore_runup_envelope(float raw_dist, float shore_fade_distance) {
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

float shore_forward_push(float phase, float steepness) {
	float crest = max(shore_skewed_sine(phase, steepness), 0.0);
	return cos(phase) * (0.45 + 0.35 * crest);
}

float shore_along_modulation(vec2 world_xz, vec2 shore_dir, float time) {
	vec2 tangent = vec2(-shore_dir.y, shore_dir.x);
	float along = dot(world_xz, tangent);
	float n = sin(along * 0.035 + time * 0.19) * 0.50
		+ sin(along * 0.079 - time * 0.13) * 0.25;
	return clamp(0.78 + n * 0.28, 0.55, 1.0);
}

vec2 shore_direction_from_mask(vec2 shore_uv, vec2 encoded_dir) {
	vec2 dir = encoded_dir * 2.0 - 1.0;
	if (length(dir) > 0.01) {
		return normalize(dir);
	}

	vec2 texel = 1.0 / vec2(textureSize(shore_mask_tex, 0));
	for (int radius = 1; radius <= 8; radius *= 2) {
		vec2 step_uv = texel * float(radius);
		float x_pos = texture(shore_mask_tex, clamp(shore_uv + vec2(step_uv.x, 0.0), vec2(0.0), vec2(1.0))).a;
		float x_neg = texture(shore_mask_tex, clamp(shore_uv - vec2(step_uv.x, 0.0), vec2(0.0), vec2(1.0))).a;
		float z_pos = texture(shore_mask_tex, clamp(shore_uv + vec2(0.0, step_uv.y), vec2(0.0), vec2(1.0))).a;
		float z_neg = texture(shore_mask_tex, clamp(shore_uv - vec2(0.0, step_uv.y), vec2(0.0), vec2(1.0))).a;
		vec2 gradient_dir = vec2(x_pos - x_neg, z_pos - z_neg);
		if (length(gradient_dir) > 1e-5) {
			return normalize(gradient_dir);
		}
	}
	return vec2(0.0);
}

vec3 get_world_position(vec2 uv, float depth) {
	vec4 clip_pos = vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec4 view_pos = state.inv_projection * clip_pos;
	view_pos.xyz /= view_pos.w;
	vec4 world_pos = state.inv_view * vec4(view_pos.xyz, 1.0);
	return world_pos.xyz;
}

vec4 normal_roughness_compatibility(vec4 p_normal_roughness) {
	float roughness = p_normal_roughness.w;
	if (roughness > 0.5) {
		roughness = 1.0 - roughness;
	}
	roughness /= (127.0 / 255.0);
	return vec4(normalize(p_normal_roughness.xyz * 2.0 - 1.0) * 0.5 + 0.5, roughness);
}

vec3 decode_world_normal(vec2 uv) {
	if (!normal_valid) {
		return vec3(0.0, 1.0, 0.0);
	}
	vec4 nr = normal_roughness_compatibility(texture(normal_roughness_tex, uv));
	vec3 view_normal = normalize(nr.xyz * 2.0 - 1.0);
	return normalize((state.inv_view * vec4(view_normal, 0.0)).xyz);
}

float decode_roughness(vec2 uv) {
	if (!normal_valid) {
		return 0.7;
	}
	return clamp(normal_roughness_compatibility(texture(normal_roughness_tex, uv)).w, 0.0, 1.0);
}

vec4 sample_shore_data(vec2 world_xz) {
	vec2 shore_uv = (world_xz - state.shore_mask_bounds.xy) / state.shore_mask_bounds.zw;
	bool in_mask = shore_uv.x >= 0.0 && shore_uv.x <= 1.0 && shore_uv.y >= 0.0 && shore_uv.y <= 1.0;
	return in_mask ? texture(shore_mask_tex, shore_uv) : vec4(1.0, 0.5, 0.5, 1.0);
}

float shore_water_distance_norm(vec4 shore_data) {
	return clamp(shore_data.a * 2.0 - 1.0, 0.0, 1.0);
}

float shore_body_coverage(vec4 shore_data) {
	return step(0.25, shore_data.a);
}

SurfaceSample sample_surface(vec2 sample_xz, vec3 cam_pos, bool include_fft, bool include_shore_waves) {
	vec3 displacement = vec3(0.0);
	if (include_fft && displacement_valid) {
		float dist_to_camera = length(vec3(sample_xz.x, sea_level, sample_xz.y) - cam_pos);
		int count = clamp(cascade_count, 0, MAX_CASCADES);
		for (int i = 0; i < MAX_CASCADES; i++) {
			if (i >= count) {
				break;
			}
			vec4 scales = state.map_scales[i];
			float tile_size = 1.0 / max(scales.x, 1e-6);
			float cascade_fade = clamp(exp(-(dist_to_camera - 50.0) / (tile_size * 20.0)), 0.0, 1.0);
			vec3 cascade_disp = texture(displacement_tex, vec3(sample_xz * scales.xy, float(i))).xyz
				* scales.z * cascade_fade;
			displacement += cascade_disp;
		}
	}

	vec2 shore_uv = (sample_xz - state.shore_mask_bounds.xy) / state.shore_mask_bounds.zw;
	bool in_mask = shore_uv.x >= 0.0 && shore_uv.x <= 1.0 && shore_uv.y >= 0.0 && shore_uv.y <= 1.0;
	vec4 shore_data = sample_shore_data(sample_xz);
	float shore = shore_data.r;
	float water_y = sea_level + displacement.y * wave_scale * shore;
	vec2 horizontal_offset = displacement.xz * wave_scale * shore;

	float shore_fade_distance = state.shore_params0.x;
	float shore_wave_amplitude = state.shore_params0.y;
	float shore_wave_frequency = state.shore_params0.z;
	float shore_wave_speed = state.shore_params0.w;
	float shore_wave_steepness = state.shore_params1.x;
	float raw_dist = shore_water_distance_norm(shore_data) * shore_fade_distance;
	vec2 shore_dir = in_mask ? shore_direction_from_mask(shore_uv, shore_data.gb) : vec2(0.0);
	float shore_dir_len = length(shore_dir);
	if (include_shore_waves && shore_dir_len > 0.01 && shore_wave_amplitude > 0.0) {
		shore_dir /= shore_dir_len;
		float phase = raw_dist * shore_wave_frequency * SHORE_TAU + TIME * shore_wave_speed * SHORE_TAU;
		float modulation = shore_along_modulation(sample_xz, shore_dir, TIME);
		float crest_phase = shore_crest_shape(phase, shore_wave_steepness);
		float breaker_env = shore_breaker_envelope(raw_dist, shore_fade_distance);
		float runup_env = shore_runup_envelope(raw_dist, shore_fade_distance);
		float swash = shore_swash_curve(phase);
		float mod_runup = runup_env * swash * mix(0.65, 1.0, modulation);
		water_y += shore_wave_amplitude * (
			breaker_env * modulation * crest_phase
			+ mod_runup * 0.32
		);
		horizontal_offset -= shore_dir * (shore_wave_amplitude * shore_wave_steepness * (
			breaker_env * modulation * shore_forward_push(phase, shore_wave_steepness)
			+ mod_runup * 1.10
		));
	}

	SurfaceSample result;
	result.y = water_y;
	result.horizontal_offset = horizontal_offset;
	return result;
}

float get_dynamic_water_level(vec2 final_xz, vec3 cam_pos, bool include_fft, bool include_shore_waves) {
	vec2 sample_xz = final_xz;
	for (int i = 0; i < 2; i++) {
		SurfaceSample s = sample_surface(sample_xz, cam_pos, include_fft, include_shore_waves);
		sample_xz = final_xz - s.horizontal_offset;
	}
	return sample_surface(sample_xz, cam_pos, include_fft, include_shore_waves).y;
}

float water_surface_body_coverage(vec2 world_xz, vec3 cam_pos) {
	vec4 shore_data = sample_shore_data(world_xz);
	float coverage = shore_body_coverage(shore_data);
	float dynamic_level = get_dynamic_water_level(world_xz, cam_pos, true, true);
	float runup_hint = smoothstep(0.015, 0.12, max(dynamic_level - sea_level, 0.0));
	return clamp(max(coverage, runup_hint * 0.45), 0.0, 1.0);
}

float water_surface_body_gate(float coverage) {
	return smoothstep(0.015, 0.12, coverage);
}

WaterSurfaceContractSample water_surface_query(vec3 world_pos, vec3 cam_pos, bool include_fft, bool include_shore_waves) {
	WaterSurfaceContractSample result;
	SurfaceSample surface = sample_surface(world_pos.xz, cam_pos, include_fft, include_shore_waves);
	result.y = get_dynamic_water_level(world_pos.xz, cam_pos, include_fft, include_shore_waves);
	result.horizontal_offset = surface.horizontal_offset;
	result.coverage = water_surface_body_coverage(world_pos.xz, cam_pos);
	result.body_gate = water_surface_body_gate(result.coverage);
	result.depth = result.y - world_pos.y;
	return result;
}

float exposed_contact_wetness(float water_depth) {
	float margin = max(wet_margin, 0.001);
	float contact = smoothstep(-margin, 0.02, water_depth);
	float submerged_skip = smoothstep(submerged_optics_depth, submerged_optics_depth + 0.08, water_depth);
	return contact * (1.0 - submerged_skip);
}

float water_surface_exclusion(float water_depth, float roughness, vec3 world_normal) {
	float near_surface = 1.0 - smoothstep(0.015, 0.10, abs(water_depth));
	float glossy_water = 1.0 - smoothstep(0.18, 0.34, roughness);
	float upward = smoothstep(0.25, 0.70, world_normal.y);
	return near_surface * glossy_water * upward;
}

vec3 debug_wet_depth(float water_depth, float base_contact) {
	float above_water = smoothstep(0.0, max(wet_margin * 2.0, 0.001), -water_depth);
	float submerged = smoothstep(submerged_optics_depth, submerged_optics_depth + 0.08, water_depth);
	return vec3(above_water, base_contact, submerged);
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (pixel.x >= int(screen_w) || pixel.y >= int(screen_h)) {
		return;
	}

	vec2 uv = (vec2(pixel) + vec2(0.5)) / vec2(screen_w, screen_h);
	vec4 scene_color = imageLoad(color_image, pixel);
	float depth = texture(depth_tex, uv).r;
	if (depth <= 0.0001) {
		return;
	}

	vec3 world_pos = get_world_position(uv, depth);
	vec3 cam_pos = state.inv_view[3].xyz;
	WaterSurfaceContractSample surface = water_surface_query(world_pos, cam_pos, true, true);

	vec3 world_normal = decode_world_normal(uv);
	float roughness = decode_roughness(uv);
	// The shore mask shapes waves, but live wetness follows actual receiver/surface contact.
	float base_contact = exposed_contact_wetness(surface.depth);
	float exclusion = water_surface_exclusion(surface.depth, roughness, world_normal);
	float wetness = base_contact * (1.0 - exclusion);
	wetness = clamp(wetness * blend_factor, 0.0, 1.0);

	if (debug_mode > 0) {
		vec3 debug_color = vec3(0.0);
		if (debug_mode == 1) {
			debug_color = mix(scene_color.rgb, vec3(0.0, 0.18, 0.85), wetness * 0.85);
		} else if (debug_mode == 2) {
			debug_color = debug_wet_depth(surface.depth, base_contact);
		} else if (debug_mode == 3) {
			debug_color = vec3(1.0 - surface.body_gate, surface.body_gate, surface.coverage);
		} else if (debug_mode == 4) {
			debug_color = vec3(exclusion, roughness, clamp(world_normal.y, 0.0, 1.0));
		} else {
			debug_color = vec3(fract(world_pos.x * 0.05), fract(world_pos.y * 0.20), fract(world_pos.z * 0.05));
		}
		imageStore(color_image, pixel, vec4(debug_color, scene_color.a));
		return;
	}

	if (wetness <= 0.001) {
		return;
	}

	float porosity = clamp((roughness - 0.2) / 0.6, 0.0, 1.0);
	float effective_wet = wetness * porosity;
	float darken = mix(1.0, 1.0 - wet_albedo_darken, effective_wet);
	vec3 output_color = scene_color.rgb * darken;

	float view_facing = pow(clamp(1.0 - abs(dot(normalize(cam_pos - world_pos), world_normal)), 0.0, 1.0), 4.0);
	float sheen = effective_wet * (1.0 - wet_roughness_target) * view_facing * 0.035;
	output_color += vec3(sheen);

	imageStore(color_image, pixel, vec4(output_color, scene_color.a));
}
