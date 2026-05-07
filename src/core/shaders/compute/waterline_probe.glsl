#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_tex;
layout(set = 0, binding = 2) uniform sampler2DArray displacement_tex;
layout(set = 0, binding = 3) uniform sampler2D shore_mask_tex;

#define MAX_CASCADES 8

layout(std430, set = 0, binding = 4) readonly buffer WaterlineState {
	mat4 inv_projection;
	mat4 inv_view;
	vec4 map_scales[MAX_CASCADES];
	vec4 shore_mask_bounds;
	vec4 shore_params0; // x=fade, y=amp, z=freq, w=speed
	vec4 shore_params1; // x=steep, yzw=water_tint
	vec4 optical_params; // xyz=sigma, w=caustics strength
} state;

layout(push_constant, std430) uniform Params {
	vec4 screen; // x=width, y=height, z=time, w=blend
	vec4 water; // x=sea_level, y=wave_scale, z=cascade_count, w=probe_strength
	vec4 debug; // x=debug_mode, yzw=reserved
} pc;

#define screen_w       pc.screen.x
#define screen_h       pc.screen.y
#define TIME           pc.screen.z
#define blend_factor   pc.screen.w
#define sea_level      pc.water.x
#define wave_scale     pc.water.y
#define cascade_count  int(pc.water.z)
#define probe_strength pc.water.w
#define debug_mode     int(pc.debug.x)

struct SurfaceSample {
	float y;
	vec2 horizontal_offset;
};

float shore_breaker_envelope(float raw_dist, float shore_fade_distance) {
	float dist_t = clamp(raw_dist / max(shore_fade_distance, 0.001), 0.0, 1.0);
	float shore_ramp = smoothstep(0.03, 0.22, dist_t);
	float offshore_fade = 1.0 - smoothstep(0.45, 0.90, dist_t);
	return shore_ramp * offshore_fade;
}

float shore_runup_envelope(float raw_dist, float shore_fade_distance) {
	float dist_t = clamp(raw_dist / max(shore_fade_distance, 0.001), 0.0, 1.0);
	return 1.0 - smoothstep(0.00, 0.16, dist_t);
}

float shore_swash_curve(float phase) {
	float cycle = fract(phase / 6.2831853);
	float uprush = smoothstep(0.00, 0.30, cycle);
	float backwash = 1.0 - smoothstep(0.30, 1.00, cycle);
	return uprush * backwash;
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


SurfaceSample sample_surface(vec2 sample_xz, vec3 cam_pos, bool include_fft, bool include_shore_waves) {
	vec3 displacement = vec3(0.0);
	if (include_fft) {
		float dist_to_camera = length(vec3(sample_xz.x, sea_level, sample_xz.y) - cam_pos);
		int count = clamp(cascade_count, 0, MAX_CASCADES);
		for (int i = 0; i < count; i++) {
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
	vec4 shore_data = in_mask ? texture(shore_mask_tex, shore_uv) : vec4(1.0, 0.5, 0.5, 1.0);
	float shore = shore_data.r;
	float water_y = sea_level + displacement.y * wave_scale * shore;
	vec2 horizontal_offset = displacement.xz * wave_scale * shore;

	float shore_fade_distance = state.shore_params0.x;
	float shore_wave_amplitude = state.shore_params0.y;
	float shore_wave_frequency = state.shore_params0.z;
	float shore_wave_speed = state.shore_params0.w;
	float shore_wave_steepness = state.shore_params1.x;
	float raw_dist = shore_data.a * shore_fade_distance;
	vec2 shore_dir = in_mask ? shore_direction_from_mask(shore_uv, shore_data.gb) : vec2(0.0);
	float shore_dir_len = length(shore_dir);
	if (include_shore_waves && shore_dir_len > 0.01 && shore_wave_amplitude > 0.0) {
		shore_dir /= shore_dir_len;
		float phase = raw_dist * shore_wave_frequency * 6.2832 + TIME * shore_wave_speed * 6.2832;
		float sin_phase = sin(phase);
		float breaker_env = shore_breaker_envelope(raw_dist, shore_fade_distance);
		float runup_env = shore_runup_envelope(raw_dist, shore_fade_distance);
		float swash = shore_swash_curve(phase);
		water_y += shore_wave_amplitude * (
			breaker_env * sin_phase
			+ runup_env * swash * 0.75
		);
		horizontal_offset -= shore_dir * (shore_wave_amplitude * shore_wave_steepness * (
			breaker_env * cos(phase)
			+ runup_env * swash * 0.90
		));
	}

	SurfaceSample result;
	result.y = water_y;
	result.horizontal_offset = horizontal_offset;
	return result;
}


float get_dynamic_water_level(vec2 final_xz, vec3 cam_pos, bool include_fft, bool include_shore_waves) {
	vec2 sample_xz = final_xz;
	// The visible ocean is parametric: xz is displaced horizontally before it
	// hits the object. Iterate a tiny inverse so the compositor classifies
	// against approximately the same final surface the mesh draws.
	for (int i = 0; i < 2; i++) {
		SurfaceSample s = sample_surface(sample_xz, cam_pos, include_fft, include_shore_waves);
		sample_xz = final_xz - s.horizontal_offset;
	}
	return sample_surface(sample_xz, cam_pos, include_fft, include_shore_waves).y;
}


void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (pixel.x >= int(screen_w) || pixel.y >= int(screen_h)) {
		return;
	}

	vec2 uv = (vec2(pixel) + 0.5) / vec2(screen_w, screen_h);
	if (pixel.x < 72 && pixel.y < 24) {
		vec4 marker = imageLoad(color_image, pixel);
		imageStore(color_image, pixel, vec4(mix(marker.rgb, vec3(1.0, 0.0, 0.85), 0.85 * blend_factor), marker.a));
	}

	float raw_depth = texture(depth_tex, uv).r;
	if (raw_depth <= 0.0001) {
		return;
	}

	vec3 world_pos = get_world_position(uv, raw_depth);
	vec3 cam_pos = state.inv_view[3].xyz;
	float camera_scene_dist = length(world_pos - cam_pos);
	float water_level = get_dynamic_water_level(world_pos.xz, cam_pos, true, true);
	if (debug_mode == 1) {
		water_level = sea_level;
	} else if (debug_mode == 2) {
		water_level = get_dynamic_water_level(world_pos.xz, cam_pos, true, false);
	}
	float water_depth = water_level - world_pos.y;

	float below_mask = smoothstep(0.02, 0.35, water_depth);
	// Debug waterline marker: keep this narrow so alignment errors are readable.
	float waterline_band = 1.0 - smoothstep(0.08, 0.14, abs(water_depth));
	float final_transition_band = 1.0 - smoothstep(0.0, 0.22, abs(water_depth));
	float mask = debug_mode == 0
		? max(below_mask * 0.55, final_transition_band * 0.18)
		: max(below_mask * 0.55, waterline_band);
	if (mask <= 0.001) {
		return;
	}

	vec4 scene_color = imageLoad(color_image, pixel);
	vec3 tint = state.shore_params1.yzw;
	vec3 sigma = state.optical_params.xyz;
	float travel = max(camera_scene_dist, 0.0);
	vec3 transmittance = exp(-sigma * min(travel, 45.0));
	vec3 absorbed = mix(tint, scene_color.rgb, transmittance);

	vec3 line_tint = mix(scene_color.rgb, tint * 1.8, 0.35);
	vec3 proof_color = debug_mode == 0
		? mix(absorbed, line_tint, final_transition_band * 0.22)
		: mix(absorbed, vec3(0.0, 0.85, 1.0), waterline_band * 0.65);
	if (debug_mode == 4) {
		float flat_delta = clamp((water_level - sea_level) * 0.5 + 0.5, 0.0, 1.0);
		proof_color = mix(vec3(0.05, 0.15, 1.0), vec3(1.0, 0.15, 0.05), flat_delta);
	}
	float strength = clamp(probe_strength * blend_factor * mask, 0.0, 1.0);
	imageStore(color_image, pixel, vec4(mix(scene_color.rgb, proof_color, strength), scene_color.a));
}
