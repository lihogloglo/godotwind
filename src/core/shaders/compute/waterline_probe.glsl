#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_tex;
layout(set = 0, binding = 2) uniform sampler2DArray displacement_tex;
layout(set = 0, binding = 3) uniform sampler2D shore_mask_tex;
layout(set = 0, binding = 5) uniform sampler2D source_color_tex;
layout(set = 0, binding = 6) uniform sampler2D source_depth_tex;

#define MAX_CASCADES 8

layout(std430, set = 0, binding = 4) readonly buffer WaterlineState {
	mat4 inv_projection;
	mat4 inv_view;
	vec4 map_scales[MAX_CASCADES];
	vec4 shore_mask_bounds;
	vec4 shore_params0; // x=fade, y=amp, z=freq, w=speed
	vec4 shore_params1; // x=steep, yzw=water_tint
	vec4 optical_params; // xyz=sigma, w=caustics strength
	mat4 projection;
	mat4 view;
} state;

layout(push_constant, std430) uniform Params {
	vec4 screen; // x=width, y=height, z=time, w=blend
	vec4 water; // x=sea_level, y=wave_scale, z=cascade_count, w=probe_strength
	vec4 debug; // x=debug_mode, y=source_color_valid, z=source_depth_valid, w=reserved
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
#define source_valid   (pc.debug.y > 0.5)
#define source_depth_valid (pc.debug.z > 0.5)

struct SurfaceSample {
	float y;
	vec2 horizontal_offset;
};

struct RefractSample {
	vec3 color;
	float valid;
	float offset;
	float status;
	float path_length;
	float below_mask;
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

float get_scene_depth(vec2 uv) {
	return source_depth_valid ? texture(source_depth_tex, uv).r : texture(depth_tex, uv).r;
}


vec2 view_to_uv(vec3 view_pos) {
	vec4 clip = state.projection * vec4(view_pos, 1.0);
	if (clip.w <= 1e-5) {
		return vec2(-1.0);
	}
	return (clip.xy / clip.w) * 0.5 + 0.5;
}


bool uv_in_screen(vec2 uv) {
	return uv.x > 0.001 && uv.x < 0.999 && uv.y > 0.001 && uv.y < 0.999;
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


float find_water_entry_t(vec3 cam_pos, vec3 scene_pos) {
	float denom = scene_pos.y - cam_pos.y;
	if (abs(denom) < 1e-4) {
		return 1.0;
	}

	float water_y = get_dynamic_water_level(scene_pos.xz, cam_pos, true, true);
	float t = clamp((water_y - cam_pos.y) / denom, 0.0, 1.0);
	for (int i = 0; i < 3; i++) {
		vec3 entry = mix(cam_pos, scene_pos, t);
		water_y = get_dynamic_water_level(entry.xz, cam_pos, true, true);
		t = clamp((water_y - cam_pos.y) / denom, 0.0, 1.0);
	}
	return t;
}


vec3 water_normal_at(vec2 xz, vec3 cam_pos) {
	const float normal_eps = 0.75;
	float water_x0 = get_dynamic_water_level(xz - vec2(normal_eps, 0.0), cam_pos, true, true);
	float water_x1 = get_dynamic_water_level(xz + vec2(normal_eps, 0.0), cam_pos, true, true);
	float water_z0 = get_dynamic_water_level(xz - vec2(0.0, normal_eps), cam_pos, true, true);
	float water_z1 = get_dynamic_water_level(xz + vec2(0.0, normal_eps), cam_pos, true, true);
	vec2 slope = vec2(water_x1 - water_x0, water_z1 - water_z0) / (2.0 * normal_eps);
	return normalize(vec3(-slope.x, 1.0, -slope.y));
}


float estimate_water_path_length(vec3 cam_pos, vec3 world_pos) {
	float camera_water_level = get_dynamic_water_level(cam_pos.xz, cam_pos, true, true);
	if (cam_pos.y < camera_water_level - 0.02) {
		return length(world_pos - cam_pos);
	}

	float entry_t = find_water_entry_t(cam_pos, world_pos);
	if (entry_t <= 0.0 || entry_t >= 1.0) {
		return max(get_dynamic_water_level(world_pos.xz, cam_pos, true, true) - world_pos.y, 0.0);
	}

	vec3 entry_world = mix(cam_pos, world_pos, entry_t);
	return length(world_pos - entry_world);
}


bool fetch_underwater_source(
	vec2 sample_uv,
	vec3 cam_pos,
	out vec3 sample_color,
	out vec3 sample_world,
	out float reject_status
) {
	sample_color = vec3(0.0);
	sample_world = vec3(0.0);
	reject_status = 0.0;

	if (!uv_in_screen(sample_uv)) {
		reject_status = 5.0;
		return false;
	}

	float sample_depth = get_scene_depth(sample_uv);
	if (sample_depth <= 0.0001) {
		reject_status = 6.0;
		return false;
	}

	sample_world = get_world_position(sample_uv, sample_depth);
	float sample_water_level = get_dynamic_water_level(sample_world.xz, cam_pos, true, true);
	if (sample_world.y >= sample_water_level + 0.05) {
		reject_status = 7.0;
		return false;
	}

	sample_color = texture(source_color_tex, sample_uv).rgb;
	return true;
}


RefractSample refracted_source_color(
	vec2 uv,
	vec3 scene_color,
	vec3 cam_pos,
	vec3 world_pos,
	float below_mask
) {
	RefractSample result;
	result.color = scene_color;
	result.valid = 0.0;
	result.offset = 0.0;
	result.status = 0.0;
	result.path_length = max(get_dynamic_water_level(world_pos.xz, cam_pos, true, true) - world_pos.y, 0.0);
	result.below_mask = below_mask;
	if (!source_valid) {
		result.status = 1.0;
		return result;
	}
	if (debug_mode != 0 && debug_mode != 5 && debug_mode != 6) {
		return result;
	}
	if (below_mask <= 0.001) {
		result.status = 2.0;
		return result;
	}

	float camera_water_level = get_dynamic_water_level(cam_pos.xz, cam_pos, true, true);
	float path_length = estimate_water_path_length(cam_pos, world_pos);
	vec3 view_dir = normalize(world_pos - cam_pos);
	vec2 surface_xz = world_pos.xz;
	if (cam_pos.y < camera_water_level - 0.02) {
		surface_xz = world_pos.xz;
	} else {
		float entry_t = find_water_entry_t(cam_pos, world_pos);
		if (entry_t > 0.0 && entry_t < 1.0) {
			vec3 entry_world = mix(cam_pos, world_pos, entry_t);
			surface_xz = entry_world.xz;
		}
	}
	vec3 world_normal = water_normal_at(surface_xz, cam_pos);
	vec3 normal_view = normalize((state.view * vec4(world_normal, 0.0)).xyz);
	float view_grazing = 1.0 - abs(dot(view_dir, world_normal));
	float camera_underwater = cam_pos.y < camera_water_level - 0.02 ? 1.0 : 0.0;
	float offset_scale = mix(0.006, 0.010, camera_underwater)
		+ mix(0.016, 0.018, camera_underwater) * view_grazing;
	offset_scale *= clamp(path_length / 3.0, 0.25, 1.35) * below_mask;
	vec2 offset = normal_view.xy * offset_scale;

	float reject_status = 0.0;
	vec3 sample_color = scene_color;
	vec3 sample_world = world_pos;
	for (int i = 0; i < 4; i++) {
		float scale = 1.0;
		if (i == 1) {
			scale = 0.66;
		} else if (i == 2) {
			scale = 0.33;
		} else if (i == 3) {
			scale = 0.0;
		}

		vec2 refr_uv = uv + offset * scale;
		if (!fetch_underwater_source(refr_uv, cam_pos, sample_color, sample_world, reject_status)) {
			result.status = reject_status;
			continue;
		}

		result.color = sample_color;
		result.valid = scale > 0.0 ? 1.0 : 0.5;
		result.offset = length(refr_uv - uv);
		result.status = scale > 0.0 ? 9.0 : 8.0;
		result.path_length = max(estimate_water_path_length(cam_pos, sample_world), path_length);
		float sample_water_depth = max(get_dynamic_water_level(sample_world.xz, cam_pos, true, true) - sample_world.y, 0.0);
		result.below_mask = smoothstep(0.02, 0.35, sample_water_depth);
		return result;
	}

	return result;
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

	float raw_depth = get_scene_depth(uv);
	if (raw_depth <= 0.0001) {
		return;
	}

	vec3 world_pos = get_world_position(uv, raw_depth);
	vec3 cam_pos = state.inv_view[3].xyz;
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
		? max(below_mask * 0.80, final_transition_band * 0.22)
		: max(below_mask * 0.55, waterline_band);
	if (mask <= 0.001) {
		return;
	}

	vec4 scene_color = imageLoad(color_image, pixel);
	RefractSample refr_sample = refracted_source_color(uv, scene_color.rgb, cam_pos, world_pos, below_mask);
	float refracted_mask = max(mask, refr_sample.below_mask);
	vec3 source_color = refr_sample.color;
	vec3 tint = state.shore_params1.yzw;
	vec3 sigma = state.optical_params.xyz;
	float travel = max(refr_sample.path_length, max(water_depth, 0.0));
	vec3 transmittance = exp(-sigma * min(travel, 45.0));
	if (debug_mode == 0 && refr_sample.valid > 0.5) {
		float shallow_clear = 1.0 - smoothstep(1.0, 8.0, travel);
		transmittance = max(transmittance, mix(vec3(0.42, 0.50, 0.58), vec3(0.72, 0.78, 0.84), shallow_clear));
	}
	vec3 absorbed = mix(tint, source_color, transmittance);
	if (debug_mode == 0 && refr_sample.valid > 0.5) {
		float clarity = 1.0 - smoothstep(2.0, 12.0, travel);
		absorbed = mix(absorbed, source_color, 0.28 + clarity * 0.22);
	}

	vec3 line_tint = mix(scene_color.rgb, tint * 1.8, 0.35);
	vec3 proof_color = debug_mode == 0
		? mix(absorbed, line_tint, final_transition_band * 0.12)
		: mix(absorbed, vec3(0.0, 0.85, 1.0), waterline_band * 0.65);
	if (debug_mode == 4) {
		float flat_delta = clamp((water_level - sea_level) * 0.5 + 0.5, 0.0, 1.0);
		proof_color = mix(vec3(0.05, 0.15, 1.0), vec3(1.0, 0.15, 0.05), flat_delta);
	} else if (debug_mode == 5) {
		if (refr_sample.status < 1.5) {
			proof_color = vec3(1.0, 0.0, 0.85);
		} else if (refr_sample.status < 2.5) {
			proof_color = vec3(0.05, 0.05, 0.08);
		} else if (refr_sample.status < 3.5) {
			proof_color = vec3(1.0, 0.9, 0.0);
		} else if (refr_sample.status < 4.5) {
			proof_color = vec3(0.65, 0.0, 1.0);
		} else if (refr_sample.status < 5.5) {
			proof_color = vec3(0.0, 0.85, 1.0);
		} else if (refr_sample.status < 6.5) {
			proof_color = vec3(1.0);
		} else if (refr_sample.status < 7.5) {
			proof_color = vec3(1.0, 0.18, 0.0);
		} else if (refr_sample.status < 8.5) {
			proof_color = mix(refr_sample.color, vec3(1.0, 0.9, 0.0), 0.45);
		} else if (refr_sample.valid > 0.5) {
			proof_color = mix(refr_sample.color, vec3(0.0, 1.0, 0.25), clamp(refr_sample.offset * 35.0, 0.0, 0.45));
		} else {
			proof_color = vec3(0.4, 0.4, 0.4);
		}
	} else if (debug_mode == 6) {
		vec3 raw_source = source_valid ? texture(source_color_tex, uv).rgb : scene_color.rgb;
		float source_delta = length(refr_sample.color - raw_source);
		float offset_meter = clamp(refr_sample.offset * 80.0, 0.0, 1.0);
		float color_meter = clamp(source_delta * 8.0, 0.0, 1.0);
		proof_color = vec3(offset_meter, color_meter, refr_sample.valid > 0.5 ? 0.08 : 0.65);
	}
	float debug_strength = (debug_mode == 5 || debug_mode == 6) ? 1.0 : probe_strength;
	float final_refraction_boost = debug_mode == 0 && refr_sample.valid > 0.5 ? 1.35 : 1.0;
	float strength = clamp(debug_strength * final_refraction_boost * blend_factor * refracted_mask, 0.0, 1.0);
	imageStore(color_image, pixel, vec4(mix(scene_color.rgb, proof_color, strength), scene_color.a));
}
