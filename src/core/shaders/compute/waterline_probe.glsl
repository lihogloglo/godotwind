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

const float SHORE_TAU = 6.2831853;

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

float get_main_depth(vec2 uv) {
	return texture(depth_tex, uv).r;
}


float get_source_depth(vec2 uv) {
	return source_depth_valid ? texture(source_depth_tex, uv).r : get_main_depth(uv);
}


float get_scene_depth(vec2 uv) {
	return get_source_depth(uv);
}


vec3 sample_source_color_nearest(vec2 uv) {
	ivec2 tex_size = textureSize(source_color_tex, 0);
	ivec2 texel = ivec2(clamp(uv, vec2(0.0), vec2(0.999999)) * vec2(tex_size));
	texel = clamp(texel, ivec2(0), tex_size - ivec2(1));
	return texelFetch(source_color_tex, texel, 0).rgb;
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

	sample_color = sample_source_color_nearest(sample_uv);
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

	float raw_depth = get_source_depth(uv);
	float main_depth = get_main_depth(uv);
	if (raw_depth <= 0.0001 || main_depth <= 0.0001) {
		return;
	}

	vec3 world_pos = get_world_position(uv, raw_depth);
	vec3 main_world_pos = get_world_position(uv, main_depth);
	vec3 cam_pos = state.inv_view[3].xyz;
	float water_level = get_dynamic_water_level(world_pos.xz, cam_pos, true, true);
	if (debug_mode == 1) {
		water_level = sea_level;
	} else if (debug_mode == 2) {
		water_level = get_dynamic_water_level(world_pos.xz, cam_pos, true, false);
	}
	float water_depth = water_level - world_pos.y;
	float main_water_level = get_dynamic_water_level(main_world_pos.xz, cam_pos, true, true);
	float main_water_depth = main_water_level - main_world_pos.y;
	float camera_water_level = get_dynamic_water_level(cam_pos.xz, cam_pos, true, true);
	bool camera_underwater = cam_pos.y < camera_water_level - 0.02;

	float below_mask = smoothstep(0.02, 0.35, water_depth);
	// Debug waterline marker: keep this narrow so alignment errors are readable.
	float waterline_band = 1.0 - smoothstep(0.08, 0.14, abs(water_depth));
	float final_transition_band = 1.0 - smoothstep(0.0, 0.22, abs(water_depth));
	float mask = debug_mode == 0
		? max(below_mask * 0.80, final_transition_band * 0.22)
		: max(below_mask * 0.55, waterline_band);
	float final_surface_gate = 1.0;
	if (debug_mode == 0 && !camera_underwater) {
		final_surface_gate = 1.0 - smoothstep(0.15, 0.75, abs(main_water_depth));
		mask *= final_surface_gate;
	}
	if (mask <= 0.001) {
		return;
	}

	vec4 scene_color = imageLoad(color_image, pixel);
	vec3 prewater_color = source_valid ? sample_source_color_nearest(uv) : scene_color.rgb;
	RefractSample refr_sample = refracted_source_color(uv, prewater_color, cam_pos, world_pos, below_mask);
	float refracted_mask = max(mask, refr_sample.below_mask * final_surface_gate);
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
	} else if (debug_mode == 7) {
		proof_color = vec3(
			source_valid ? 0.0 : 1.0,
			source_depth_valid ? 1.0 : 0.0,
			source_valid && source_depth_valid ? 0.15 : 0.0
		);
	}
	float debug_strength = (debug_mode == 5 || debug_mode == 6 || debug_mode == 7) ? 1.0 : probe_strength;
	float final_refraction_boost = debug_mode == 0 && refr_sample.valid > 0.5 ? 1.45 : 1.0;
	float strength = clamp(debug_strength * final_refraction_boost * blend_factor * refracted_mask, 0.0, 1.0);
	imageStore(color_image, pixel, vec4(mix(scene_color.rgb, proof_color, strength), scene_color.a));
}
