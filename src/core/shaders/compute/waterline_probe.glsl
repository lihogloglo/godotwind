#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_tex;
layout(set = 0, binding = 2) uniform sampler2DArray displacement_tex;
layout(set = 0, binding = 3) uniform sampler2D shore_mask_tex;
layout(set = 0, binding = 5) uniform sampler2D source_color_tex;
layout(set = 0, binding = 6) uniform sampler2D source_depth_tex;
layout(set = 0, binding = 7) uniform sampler2D scene_color_tex;

#define MAX_CASCADES 8

layout(std430, set = 0, binding = 4) readonly buffer WaterlineState {
	mat4 inv_projection;
	mat4 inv_view;
	vec4 map_scales[MAX_CASCADES];
	vec4 shore_mask_bounds;
	vec4 shore_params0; // x=fade, y=amp, z=freq, w=speed
	vec4 shore_params1; // x=steep, yzw=water_tint
	vec4 optical_params; // xyz=sigma, w=caustics strength
	vec4 sun_params; // xyz=toward sun, w=visibility
	mat4 projection;
	mat4 view;
} state;

layout(push_constant, std430) uniform Params {
	vec4 screen; // x=width, y=height, z=time, w=blend
	vec4 water; // x=sea_level, y=wave_scale, z=cascade_count, w=probe_strength
	vec4 debug; // x=debug_mode, y=source_color_valid, z=source_depth_valid, w=reserved
	vec4 features; // x=feature_flags, y=camera_water_level, zw=reserved
	vec4 ray_params; // x=shell_count, y=shell_spacing_m, z=intensity, w=shell_start_m
	vec4 particle_params; // x=noise_scale, y=density, z=near_gate_m, w=far_gate_m
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
#define scene_color_valid (pc.debug.w > 0.5)
#define feature_flags int(pc.features.x)
#define camera_water_level_cached pc.features.y
#define ray_shell_count pc.ray_params.x
#define ray_shell_spacing pc.ray_params.y
#define ray_intensity pc.ray_params.z
#define ray_shell_start pc.ray_params.w
#define particle_noise_scale pc.particle_params.x
#define particle_density pc.particle_params.y
#define particle_near_gate pc.particle_params.z
#define particle_far_gate pc.particle_params.w

const int FEATURE_ABSORPTION_FOG = 1;
const int FEATURE_SNELL = 2;
const int FEATURE_RAYS = 4;
const int FEATURE_WOBBLE = 8;
const int FEATURE_PARTICLES = 16;
const int FEATURE_MENISCUS_REFRACTION = 32;

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
const float AIR_IOR = 1.000293;
const float WATER_IOR = 1.3330;
const float WATER_TO_AIR_ETA = WATER_IOR / AIR_IOR;
const float WATER_TO_AIR_CRITICAL_SIN = AIR_IOR / WATER_IOR;
const float WATER_TO_AIR_CRITICAL_COS = sqrt(1.0 - WATER_TO_AIR_CRITICAL_SIN * WATER_TO_AIR_CRITICAL_SIN);

struct SnellSample {
	float window;
	float rim;
	float cos_theta;
	float valid;
	vec3 air_dir;
	vec3 surface_normal;
	vec3 surface_pos;
};

bool feature_enabled(int bit) {
	return (feature_flags & bit) != 0;
}

float hash21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float hash31(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
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

float fbm2(vec2 p) {
	float n = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; i++) {
		n += value_noise2(p) * amp;
		p = p * 2.03 + vec2(17.7, -11.3);
		amp *= 0.5;
	}
	return n;
}

float interleaved_gradient_noise(vec2 pixel) {
	return fract(52.9829189 * fract(0.06711056 * pixel.x + 0.00583715 * pixel.y));
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


vec3 sample_scene_color(vec2 uv, vec3 fallback) {
	if (!scene_color_valid) {
		return fallback;
	}
	return texture(scene_color_tex, clamp(uv, vec2(0.001), vec2(0.999))).rgb;
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


vec3 get_world_ray_dir(vec2 uv) {
	vec4 clip_pos = vec4(uv * 2.0 - 1.0, 1.0, 1.0);
	vec4 view_pos = state.inv_projection * clip_pos;
	if (abs(view_pos.w) > 1e-5) {
		view_pos.xyz /= view_pos.w;
	}
	vec3 cam_pos = state.inv_view[3].xyz;
	vec3 world_pos = (state.inv_view * vec4(view_pos.xyz, 1.0)).xyz;
	return normalize(world_pos - cam_pos);
}


vec3 pipeline_debug_color(
	vec2 uv,
	float source_bound,
	float source_depth_bound,
	float receiver_depth_present,
	float main_depth_present,
	float receiver_mask,
	float water_body_gate,
	float visible_water_gate,
	float final_mask
) {
	if (uv.x < 0.25) {
		return vec3(source_bound, source_depth_bound, receiver_depth_present);
	}
	if (uv.x < 0.50) {
		return vec3(receiver_depth_present, main_depth_present, source_bound * source_depth_bound * 0.20);
	}
	if (uv.x < 0.75) {
		return vec3(receiver_mask, water_body_gate, visible_water_gate);
	}
	return vec3(final_mask, final_mask > 0.001 ? 1.0 : 0.0, 1.0);
}


vec4 sample_shore_data(vec2 world_xz) {
	vec2 shore_uv = (world_xz - state.shore_mask_bounds.xy) / state.shore_mask_bounds.zw;
	bool in_mask = shore_uv.x >= 0.0 && shore_uv.x <= 1.0 && shore_uv.y >= 0.0 && shore_uv.y <= 1.0;
	return in_mask ? texture(shore_mask_tex, shore_uv) : vec4(1.0, 0.5, 0.5, 1.0);
}


float get_dynamic_water_level(vec2 final_xz, vec3 cam_pos, bool include_fft, bool include_shore_waves);


float water_coverage_at(vec2 world_xz, vec3 cam_pos) {
	vec4 shore_data = sample_shore_data(world_xz);
	float coverage = shore_data.r;
	float dynamic_level = get_dynamic_water_level(world_xz, cam_pos, true, true);
	float runup_hint = smoothstep(0.015, 0.12, max(dynamic_level - sea_level, 0.0));
	return clamp(max(coverage, runup_hint * 0.45), 0.0, 1.0);
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
	vec4 shore_data = sample_shore_data(sample_xz);
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


bool trace_water_surface(vec2 uv, vec3 cam_pos, out vec3 water_world, out float water_gate) {
	vec3 ray_dir = get_world_ray_dir(uv);
	if (abs(ray_dir.y) < 1e-4) {
		water_world = cam_pos + ray_dir * 5000.0;
		water_gate = 0.0;
		return false;
	}

	float water_y = get_dynamic_water_level(cam_pos.xz, cam_pos, true, true);
	float t = (water_y - cam_pos.y) / ray_dir.y;
	for (int i = 0; i < 4; i++) {
		if (t <= 0.0 || t > 5000.0) {
			water_world = cam_pos + ray_dir * max(t, 0.0);
			water_gate = 0.0;
			return false;
		}
		vec3 p = cam_pos + ray_dir * t;
		water_y = get_dynamic_water_level(p.xz, cam_pos, true, true);
		t = (water_y - cam_pos.y) / ray_dir.y;
	}

	water_world = cam_pos + ray_dir * t;
	float coverage = water_coverage_at(water_world.xz, cam_pos);
	water_gate = smoothstep(0.015, 0.12, coverage);
	return water_gate > 0.001;
}

SnellSample compute_snell_sample(vec3 cam_pos, vec3 view_dir, vec3 water_surface_pos, bool water_surface_hit) {
	SnellSample result;
	result.window = 0.0;
	result.rim = 0.0;
	result.cos_theta = 0.0;
	result.valid = 0.0;
	result.air_dir = vec3(0.0, 1.0, 0.0);
	result.surface_normal = vec3(0.0, 1.0, 0.0);
	result.surface_pos = water_surface_pos;

	if (!water_surface_hit) {
		return result;
	}

	vec3 surface_ray = normalize(water_surface_pos - cam_pos);
	if (surface_ray.y <= 0.0 || dot(surface_ray, view_dir) <= 0.985) {
		return result;
	}

	vec3 surface_normal = water_normal_at(water_surface_pos.xz, cam_pos);
	float cos_theta = clamp(dot(surface_ray, surface_normal), 0.0, 1.0);
	if (cos_theta <= 0.0) {
		return result;
	}

	// Snell window for water->air transmission. The hard physics boundary is
	// theta_c = asin(n_air / n_water), which gives a ~97 degree full cone.
	float window = smoothstep(
		WATER_TO_AIR_CRITICAL_COS - 0.010,
		WATER_TO_AIR_CRITICAL_COS + 0.028,
		cos_theta
	);
	float rim = (1.0 - smoothstep(0.0, 0.040, abs(cos_theta - WATER_TO_AIR_CRITICAL_COS)))
		* smoothstep(0.18, 0.60, cos_theta);
	vec3 air_dir = refract(surface_ray, -surface_normal, WATER_TO_AIR_ETA);
	float refracted = step(1e-5, dot(air_dir, air_dir));

	result.window = window * refracted;
	result.rim = rim;
	result.cos_theta = cos_theta;
	result.valid = 1.0;
	result.air_dir = refracted > 0.5 ? normalize(air_dir) : reflect(surface_ray, surface_normal);
	result.surface_normal = surface_normal;
	return result;
}


vec3 snell_sky_color(vec3 air_dir, vec3 sun_dir, float sun_visibility, vec3 water_tint) {
	float horizon = clamp(air_dir.y * 0.5 + 0.5, 0.0, 1.0);
	vec3 low_sky = mix(water_tint * 1.20, vec3(0.43, 0.67, 0.82), sun_visibility);
	vec3 high_sky = mix(vec3(0.24, 0.45, 0.64), vec3(0.72, 0.91, 1.0), sun_visibility);
	float sun_core = pow(max(dot(air_dir, sun_dir), 0.0), 180.0) * sun_visibility;
	float sun_haze = pow(max(dot(air_dir, sun_dir), 0.0), 14.0) * sun_visibility;
	return mix(low_sky, high_sky, smoothstep(0.20, 0.95, horizon))
		+ vec3(1.0, 0.88, 0.62) * sun_core * 1.15
		+ vec3(0.55, 0.72, 0.82) * sun_haze * 0.16;
}


float compute_underwater_rays(
	vec3 cam_pos,
	vec3 view_dir,
	float pixel_dist,
	float camera_water_level,
	vec3 water_surface_pos,
	float water_surface_hit
) {
	vec3 sun_dir = normalize(state.sun_params.xyz);
	float sun_vis = clamp(state.sun_params.w, 0.0, 1.0);
	float sun_height = max(sun_dir.y, 0.03);
	float sun_fade = smoothstep(0.02, 0.32, sun_dir.y) * sun_vis;
	float view_to_sun = max(dot(view_dir, sun_dir), 0.0);
	vec2 sun_xz = normalize(sun_dir.xz + vec2(0.001, -0.001));
	vec2 sun_perp = vec2(-sun_xz.y, sun_xz.x);
	float camera_depth = max(camera_water_level - cam_pos.y, 0.0);
	float camera_depth_gate = smoothstep(0.20, 2.50, camera_depth) * exp(-camera_depth * 0.010);
	float ray_sum = 0.0;
	int shell_count = clamp(int(round(ray_shell_count)), 1, 8);
	float start_dist = max(ray_shell_start, 0.65);
	float max_dist = min(max(pixel_dist, 12.0), start_dist + max(ray_shell_spacing, 1.0) * float(shell_count));

	for (int i = 0; i < 8; i++) {
		if (i >= shell_count) {
			break;
		}
		float slice = (float(i) + 0.5) / float(shell_count);
		float sample_dist = mix(start_dist, max_dist, slice);
		vec3 sample_pos = cam_pos + view_dir * sample_dist;
		float water_y = get_dynamic_water_level(sample_pos.xz, cam_pos, true, true);
		float sample_depth = max(water_y - sample_pos.y, 0.0);
		if (sample_depth <= 0.01) {
			continue;
		}

		// Project the underwater sample back to the surface along sunlight.
		// The column pattern is evaluated at that surface footprint, so rays
		// stay fixed in world water instead of riding the camera frustum.
		vec2 surface_xz = sample_pos.xz + sun_dir.xz * (sample_depth / sun_height);
		float along = dot(surface_xz, sun_xz);
		float across = dot(surface_xz, sun_perp);
		float column_a = fbm2(vec2(across * 0.055, along * 0.010) + vec2(TIME * 0.010, -TIME * 0.004));
		float column_b = fbm2(surface_xz * 0.018 + vec2(-TIME * 0.006, TIME * 0.008) + float(i) * 9.17);
		float column = column_a * 0.72 + column_b * 0.28;
		float shaft = pow(smoothstep(0.58, 0.86, column), 2.15);
		float shimmer = 0.86 + 0.14 * sin(TIME * 0.75 + along * 0.030 + across * 0.017);
		float depth_atten = exp(-sample_depth * 0.030) * (1.0 - smoothstep(62.0, 145.0, sample_depth));
		float dist_gate = smoothstep(1.0, 7.0, sample_dist)
			* (1.0 - smoothstep(max_dist * 0.76, max_dist, sample_dist));
		float phase = 0.24 + pow(view_to_sun, 1.75) * 0.88 + smoothstep(0.0, 0.72, sun_dir.y) * 0.22;
		ray_sum += shaft * shimmer * depth_atten * dist_gate * phase / (1.0 + float(i) * 0.30);
	}

	return clamp(ray_sum * ray_intensity * sun_fade * camera_depth_gate * 0.22, 0.0, 0.38);
}


float underwater_speck_layer(vec3 sample_pos, float cell_scale, float radius, float threshold) {
	vec3 q = sample_pos * cell_scale;
	vec3 cell = floor(q);
	vec3 local = fract(q);
	vec3 center = vec3(
		hash31(cell + vec3(17.0, 3.0, 11.0)),
		hash31(cell + vec3(5.0, 23.0, 7.0)),
		hash31(cell + vec3(31.0, 13.0, 19.0))
	);
	float speck_active = step(threshold, hash31(cell));
	float dist = length(local - center);
	return speck_active * (1.0 - smoothstep(radius, radius * 1.85, dist));
}


float compute_underwater_particles(vec2 uv, vec3 cam_pos, vec3 view_dir, float pixel_dist, float camera_depth) {
	float scale = clamp(particle_noise_scale, 0.005, 1.5);
	float coarse_scale = mix(0.32, 1.15, clamp(scale / 1.5, 0.0, 1.0));
	float fine_scale = coarse_scale * 2.35;
	vec3 drift = vec3(0.145, 0.065, -0.110) * TIME;
	float sample_limit = min(pixel_dist, particle_far_gate);
	float flecks = 0.0;
	for (int i = 0; i < 6; i++) {
		float jitter = interleaved_gradient_noise(uv * vec2(screen_w, screen_h) + float(i) * 41.0);
		float t = (float(i) + 0.24 + 0.56 * jitter) / 6.0;
		float sample_dist = mix(0.45, sample_limit, t);
		vec3 p = cam_pos + view_dir * sample_dist + drift + vec3(0.31, -0.17, 0.23) * float(i);
		float near_speck = underwater_speck_layer(p, coarse_scale, 0.160, 0.62);
		float fine_speck = underwater_speck_layer(p + vec3(9.7, -3.1, 4.3), fine_scale, 0.120, 0.78);
		flecks += near_speck * 0.92 + fine_speck * 0.42;
	}
	flecks *= 0.18;
	float depth_gate = smoothstep(0.20, 3.5, camera_depth);
	float near_gate = max(particle_near_gate, 0.25);
	float far_gate = max(particle_far_gate, near_gate + 1.0);
	float dist_gate = smoothstep(near_gate, near_gate + 4.0, pixel_dist)
		* (1.0 - smoothstep(far_gate, far_gate + 85.0, pixel_dist));
	return clamp(flecks * particle_density * dist_gate * depth_gate, 0.0, 1.0);
}


float estimate_water_path_length(vec3 cam_pos, vec3 world_pos) {
	float camera_water_level = get_dynamic_water_level(cam_pos.xz, cam_pos, true, true);
	if (cam_pos.y < camera_water_level - 0.02) {
		float receiver_water_level = get_dynamic_water_level(world_pos.xz, cam_pos, true, true);
		if (world_pos.y <= receiver_water_level + 0.02) {
			return length(world_pos - cam_pos);
		}
		float exit_t = find_water_entry_t(cam_pos, world_pos);
		if (exit_t > 0.0 && exit_t < 1.0) {
			vec3 exit_world = mix(cam_pos, world_pos, exit_t);
			return length(exit_world - cam_pos);
		}
		return length(world_pos - cam_pos);
	}

	float entry_t = find_water_entry_t(cam_pos, world_pos);
	if (entry_t <= 0.0 || entry_t >= 1.0) {
		return max(get_dynamic_water_level(world_pos.xz, cam_pos, true, true) - world_pos.y, 0.0);
	}

	vec3 entry_world = mix(cam_pos, world_pos, entry_t);
	return length(world_pos - entry_world);
}


float ray_water_crossing_mask(vec3 cam_pos, vec3 world_pos, float camera_water_level, float receiver_water_depth) {
	float cam_depth = camera_water_level - cam_pos.y;
	if (abs(cam_depth) <= 0.02) {
		return 1.0;
	}
	bool camera_underwater = cam_depth > 0.0;
	bool receiver_underwater = receiver_water_depth > 0.02;
	if (camera_underwater == receiver_underwater) {
		return 0.0;
	}
	float t = find_water_entry_t(cam_pos, world_pos);
	return (t > 0.001 && t < 0.999) ? 1.0 : 0.0;
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
	if (sample_world.y >= sample_water_level - 0.02) {
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
		float exit_t = find_water_entry_t(cam_pos, world_pos);
		if (exit_t > 0.0 && exit_t < 1.0) {
			vec3 exit_world = mix(cam_pos, world_pos, exit_t);
			surface_xz = exit_world.xz;
		}
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
	float offset_scale = mix(0.0022, 0.0030, camera_underwater)
		+ mix(0.0065, 0.0080, camera_underwater) * view_grazing;
	offset_scale *= clamp(path_length / 3.0, 0.25, 1.20) * below_mask;
	vec2 offset = normal_view.xy * offset_scale;

	float reject_status = 0.0;
	vec3 sample_color = scene_color;
	vec3 sample_world = world_pos;
	for (int i = 0; i < 6; i++) {
		float scale = 1.0;
		if (i == 1) {
			scale = 0.66;
		} else if (i == 2) {
			scale = 0.33;
		} else if (i == 3) {
			scale = -0.66;
		} else if (i == 4) {
			scale = -0.33;
		} else if (i == 5) {
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


RefractSample refracted_receiver_from_water_pixel(
	vec2 uv,
	vec3 scene_color,
	vec3 cam_pos,
	vec3 water_world_pos,
	float water_gate
) {
	RefractSample result;
	result.color = scene_color;
	result.valid = 0.0;
	result.offset = 0.0;
	result.status = 0.0;
	result.path_length = 0.0;
	result.below_mask = 0.0;
	if (!source_valid) {
		result.status = 1.0;
		return result;
	}
	if (water_gate <= 0.001) {
		result.status = 3.0;
		return result;
	}

	vec3 view_dir = normalize(water_world_pos - cam_pos);
	vec3 world_normal = water_normal_at(water_world_pos.xz, cam_pos);
	vec3 normal_view = normalize((state.view * vec4(world_normal, 0.0)).xyz);
	float view_grazing = 1.0 - abs(dot(view_dir, world_normal));
	float view_dist = length(water_world_pos - cam_pos);
	float offset_scale = (0.0075 + 0.0200 * view_grazing)
		* clamp(view_dist / 35.0, 0.45, 1.45)
		* water_gate;
	vec2 offset = normal_view.xy * offset_scale;

	float reject_status = 0.0;
	vec3 sample_color = scene_color;
	vec3 sample_world = water_world_pos;
	for (int i = 0; i < 6; i++) {
		float scale = 1.0;
		if (i == 1) {
			scale = 0.66;
		} else if (i == 2) {
			scale = 0.33;
		} else if (i == 3) {
			scale = -0.66;
		} else if (i == 4) {
			scale = -0.33;
		} else if (i == 5) {
			scale = 0.0;
		}

		vec2 refr_uv = uv + offset * scale;
		if (!fetch_underwater_source(refr_uv, cam_pos, sample_color, sample_world, reject_status)) {
			result.status = reject_status;
			continue;
		}

		result.color = sample_color;
		result.valid = scale != 0.0 ? 1.0 : 0.5;
		result.offset = length(refr_uv - uv);
		result.status = scale != 0.0 ? 9.0 : 8.0;
		result.path_length = max(estimate_water_path_length(cam_pos, sample_world), 0.25);
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
	bool pipeline_debug = debug_mode == 9;
	vec4 scene_color = imageLoad(color_image, pixel);
	vec3 cam_pos = state.inv_view[3].xyz;
	float camera_water_level = camera_water_level_cached;
	bool camera_underwater = cam_pos.y < camera_water_level - 0.02;
	vec3 view_dir = get_world_ray_dir(uv);
	bool absorption_enabled = feature_enabled(FEATURE_ABSORPTION_FOG);
	bool snell_enabled = feature_enabled(FEATURE_SNELL);
	bool rays_enabled = feature_enabled(FEATURE_RAYS);
	bool wobble_enabled = feature_enabled(FEATURE_WOBBLE);
	bool particles_enabled = feature_enabled(FEATURE_PARTICLES);
	bool meniscus_refraction_enabled = feature_enabled(FEATURE_MENISCUS_REFRACTION);
	bool underwater_any_enabled = absorption_enabled || snell_enabled || rays_enabled || wobble_enabled || particles_enabled;
	if (debug_mode == 0 && camera_underwater && !underwater_any_enabled && !meniscus_refraction_enabled) {
		return;
	}
	vec3 analytic_water_pos = cam_pos + view_dir * 5000.0;
	float analytic_water_gate = 0.0;
	bool refraction_mode = debug_mode == 0 || debug_mode == 5 || debug_mode == 6;
	bool needs_water_ray = camera_underwater || pipeline_debug || debug_mode != 0 || (meniscus_refraction_enabled && refraction_mode);
	bool water_ray_hit = false;
	if (needs_water_ray) {
		water_ray_hit = trace_water_surface(uv, cam_pos, analytic_water_pos, analytic_water_gate);
	}

	float raw_depth = source_depth_valid ? get_source_depth(uv) : 0.0;
	float main_depth = get_main_depth(uv);
	bool main_depth_present = main_depth > 0.0001;
	bool receiver_depth_present = source_depth_valid && raw_depth > 0.0001;
	if ((!main_depth_present && !receiver_depth_present && !water_ray_hit && !camera_underwater) || (!receiver_depth_present && !refraction_mode && !camera_underwater)) {
		if (pipeline_debug) {
			vec3 debug_color = pipeline_debug_color(
				uv,
				source_valid ? 1.0 : 0.0,
				source_depth_valid ? 1.0 : 0.0,
				receiver_depth_present ? 1.0 : 0.0,
				main_depth_present ? 1.0 : 0.0,
				0.0,
				analytic_water_gate,
				water_ray_hit ? 1.0 : 0.0,
				0.0
			);
			imageStore(color_image, pixel, vec4(debug_color, scene_color.a));
		}
		return;
	}

	vec3 fallback_world_pos = water_ray_hit ? analytic_water_pos : cam_pos + view_dir * 200.0;
	vec3 main_world_pos = main_depth_present ? get_world_position(uv, main_depth) : fallback_world_pos;
	vec3 world_pos = receiver_depth_present ? get_world_position(uv, raw_depth) : main_world_pos;
	float water_level = get_dynamic_water_level(world_pos.xz, cam_pos, true, true);
	if (debug_mode == 1) {
		water_level = sea_level;
	} else if (debug_mode == 2) {
		water_level = get_dynamic_water_level(world_pos.xz, cam_pos, true, false);
	}
	float water_depth = water_level - world_pos.y;
	float main_water_level = get_dynamic_water_level(main_world_pos.xz, cam_pos, true, true);
	float main_water_depth = main_water_level - main_world_pos.y;
	float receiver_coverage = receiver_depth_present ? water_coverage_at(world_pos.xz, cam_pos) : 0.0;
	float main_coverage = water_coverage_at(main_world_pos.xz, cam_pos);
	float camera_coverage = water_coverage_at(cam_pos.xz, cam_pos);
	float water_body_gate = max(
		smoothstep(0.015, 0.12, max(max(receiver_coverage, main_coverage), camera_underwater ? camera_coverage : 0.0)),
		analytic_water_gate
	);

	float below_mask = smoothstep(0.02, 0.35, water_depth);
	float crossing_mask = ray_water_crossing_mask(cam_pos, world_pos, camera_water_level, water_depth);
	if (!receiver_depth_present && !main_depth_present && water_ray_hit) {
		crossing_mask = 1.0;
	}
	float underwater_ray_mask = camera_underwater
		? max(below_mask, crossing_mask)
		: below_mask;
	float waterline_band = 1.0 - smoothstep(0.00, 0.24, abs(water_depth));
	float receiver_mask = receiver_depth_present
		? max(underwater_ray_mask, waterline_band * 0.35)
		: max(camera_underwater ? underwater_ray_mask : 0.0, waterline_band * 0.20);
	// Main-view ocean depth is a useful hint, but the water body ray keeps the
	// compositor stable when the finite clipmap mesh/depth footprint drops out.
	float visible_water_depth_gate = main_depth_present ? smoothstep(-0.08, 0.04, main_water_depth) : 0.0;
	float visible_water_band_gate = main_depth_present ? 1.0 - smoothstep(0.55, 1.45, abs(main_water_depth)) : 0.0;
	float analytic_visible_water_gate = water_ray_hit ? analytic_water_gate : 0.0;
	float visible_water_gate = camera_underwater
		? max(max(underwater_ray_mask, crossing_mask * 0.65), analytic_visible_water_gate * 0.75)
		: max(visible_water_depth_gate * visible_water_band_gate, analytic_visible_water_gate);
	float receiver_visibility_gate = max(visible_water_gate, underwater_ray_mask);
	float mask = receiver_mask * receiver_visibility_gate * water_body_gate;

	vec3 receiver_color = receiver_depth_present ? sample_source_color_nearest(uv) : scene_color.rgb;
	RefractSample refr_sample;
	if (!meniscus_refraction_enabled && debug_mode == 0) {
		refr_sample.color = receiver_color;
		refr_sample.valid = 0.0;
		refr_sample.offset = 0.0;
		refr_sample.status = 0.0;
		refr_sample.path_length = max(water_depth, 0.0);
		refr_sample.below_mask = underwater_ray_mask;
	} else if (receiver_depth_present) {
		refr_sample = refracted_source_color(uv, receiver_color, cam_pos, world_pos, underwater_ray_mask);
	} else {
		refr_sample = refracted_receiver_from_water_pixel(uv, scene_color.rgb, cam_pos, main_world_pos, visible_water_gate * water_body_gate);
	}
	float refracted_silhouette_mask = (!receiver_depth_present && refr_sample.valid > 0.0)
		? refr_sample.below_mask * visible_water_gate * water_body_gate
		: 0.0;
	mask = max(mask, refracted_silhouette_mask);
	if (debug_mode == 0 && mask <= 0.001 && !camera_underwater) {
		return;
	}

	vec3 tint = state.shore_params1.yzw;
	vec3 source_color = refr_sample.color;
	vec3 sigma = state.optical_params.xyz;
	float travel = max(refr_sample.path_length, receiver_depth_present ? max(water_depth, 0.0) : refr_sample.below_mask * 2.0);
	vec3 transmittance = exp(-sigma * min(travel, 45.0));
	vec3 absorbed = mix(tint * 0.92, source_color, transmittance);
	float path_fog = 1.0 - exp(-min(travel, 75.0) * 0.038);
	vec3 backscatter = tint * mix(1.00, 1.70, clamp(path_fog, 0.0, 1.0));
	vec3 water_color = absorption_enabled
		? mix(absorbed, backscatter, path_fog * mix(0.22, 0.38, camera_underwater ? 1.0 : 0.0))
		: source_color;

	float meniscus_core = 1.0 - smoothstep(0.00, 0.085, abs(water_depth));
	float meniscus_halo = waterline_band * (1.0 - smoothstep(0.10, 0.32, abs(water_depth)));
	vec3 meniscus_tint = mix(tint * 1.35, vec3(0.62, 0.92, 1.0), 0.55);
	vec3 line_tint = mix(scene_color.rgb, meniscus_tint, 0.38);
	float meniscus = meniscus_refraction_enabled
		? max(meniscus_core * 0.16, meniscus_halo * mix(0.05, 0.14, max(crossing_mask, camera_underwater ? 0.5 : 0.0)))
		: 0.0;
	vec3 proof_color = debug_mode == 0
		? mix(water_color, line_tint, meniscus)
		: mix(water_color, vec3(0.0, 0.85, 1.0), waterline_band * 0.55);
	if (debug_mode == 4) {
		proof_color = vec3(receiver_mask, water_body_gate, receiver_visibility_gate);
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
			scene_color_valid ? 0.25 : 0.0
		);
	} else if (debug_mode == 8) {
		proof_color = vec3(below_mask, crossing_mask, receiver_visibility_gate * water_body_gate);
	} else if (pipeline_debug) {
		proof_color = pipeline_debug_color(
			uv,
			1.0,
			1.0,
			source_valid ? 1.0 : 0.0,
			source_depth_valid ? 1.0 : 0.0,
			receiver_mask,
			water_body_gate,
			visible_water_gate,
			mask
		);
	}

	float camera_depth = camera_water_level - cam_pos.y;
	float underwater_view_mask = smoothstep(0.04, 0.55, camera_depth);
	vec3 underwater_color = scene_color.rgb;
	if (camera_underwater && underwater_any_enabled) {
		bool needs_surface_normal = snell_enabled || wobble_enabled;
		float surface_dist = water_ray_hit ? length(analytic_water_pos - cam_pos) : 8.0;
		SnellSample snell = compute_snell_sample(cam_pos, view_dir, analytic_water_pos, water_ray_hit);
		vec3 surface_normal = (needs_surface_normal && snell.valid > 0.5) ? snell.surface_normal : vec3(0.0, 1.0, 0.0);
		vec3 normal_view = normalize((state.view * vec4(surface_normal, 0.0)).xyz);
		float snell_window = snell_enabled ? snell.window : 0.0;
		float snell_rim = snell_enabled ? snell.rim : 0.0;
		float total_internal_reflection = snell_enabled && snell.valid > 0.5 ? 1.0 - snell_window : 0.0;
		float up_dot = snell.valid > 0.5 ? snell.cos_theta : max(view_dir.y, 0.0);
		float scene_dist = main_depth_present ? length(main_world_pos - cam_pos) : min(surface_dist + 55.0, 95.0);
		vec2 wobble_low = vec2(
			fbm2(uv * vec2(3.1, 4.7) + TIME * vec2(0.055, -0.024)),
			fbm2(uv * vec2(4.2, 2.9) - TIME * vec2(0.032, 0.041))
		) * 2.0 - 1.0;
		vec2 wobble_mid = vec2(
			fbm2(uv * vec2(9.5, 7.0) + TIME * vec2(-0.078, 0.039)),
			fbm2(uv * vec2(7.7, 10.2) + TIME * vec2(0.046, 0.071))
		) * 2.0 - 1.0;
		float wobble_strength = (
			0.0055
			+ 0.0075 * smoothstep(0.0, 0.90, up_dot)
			+ 0.000075 * min(scene_dist, 85.0)
		) * underwater_view_mask;
		vec2 wobble_offset = (wobble_low * 0.72 + wobble_mid * 0.28 + normal_view.xy * 0.18) * wobble_strength;
		vec2 wobbled_uv = wobble_enabled ? clamp(uv + wobble_offset, vec2(0.001), vec2(0.999)) : uv;
		vec3 wobbled_scene = sample_scene_color(wobbled_uv, scene_color.rgb);
		float water_travel = mix(scene_dist, max(surface_dist * 0.42, 0.75), snell_window);
		vec3 underwater_sigma = max(sigma * 1.65, vec3(0.075, 0.025, 0.018));
		vec3 underwater_transmittance = exp(-underwater_sigma * min(water_travel, 90.0));
		vec3 underwater_absorbed = mix(tint * 1.08, wobbled_scene, underwater_transmittance);
		float underwater_fog = 1.0 - exp(-min(water_travel, 130.0) * 0.085);
		underwater_color = absorption_enabled
			? mix(underwater_absorbed, tint * mix(1.70, 2.55, snell_window), clamp(underwater_fog * 0.86, 0.0, 0.96))
			: wobbled_scene;
		if (total_internal_reflection > 0.001) {
			vec3 reflected_dir = reflect(view_dir, surface_normal);
			vec2 reflect_uv = clamp(uv + normal_view.xy * 0.010 + reflected_dir.xz * 0.0025, vec2(0.001), vec2(0.999));
			vec3 reflected_water = sample_scene_color(reflect_uv, scene_color.rgb);
			vec3 ceiling_tint = mix(tint * 1.45, reflected_water, 0.32);
			underwater_color = mix(underwater_color, ceiling_tint, total_internal_reflection * 0.22);
		}
		float rays = rays_enabled ? compute_underwater_rays(
			cam_pos,
			view_dir,
			max(scene_dist, surface_dist + 10.0),
			camera_water_level,
			analytic_water_pos,
			water_ray_hit ? 1.0 : 0.0
		) : 0.0;
		underwater_color += rays * vec3(0.46, 0.82, 1.0) * (0.45 + 0.55 * state.sun_params.w);
		float particles = particles_enabled ? compute_underwater_particles(uv, cam_pos, view_dir, max(scene_dist, surface_dist + 12.0), camera_depth) : 0.0;
		underwater_color += particles * mix(vec3(0.58, 0.82, 0.78), vec3(0.95, 1.0, 0.92), underwater_fog) * 0.58;
		vec3 snell_color = snell_sky_color(snell.air_dir, normalize(state.sun_params.xyz), state.sun_params.w, tint);
		vec3 surface_sample = sample_scene_color(clamp(wobbled_uv - normal_view.xy * 0.004, vec2(0.001), vec2(0.999)), scene_color.rgb);
		snell_color = mix(snell_color, max(snell_color, surface_sample * 1.10), 0.25);
		underwater_color = snell_enabled ? mix(underwater_color, snell_color, snell_window * 0.78) : underwater_color;
		underwater_color += vec3(0.38, 0.78, 0.96) * snell_rim * 0.18;
		float dither = interleaved_gradient_noise(vec2(pixel));
		underwater_color += vec3(dither * 2.0 - 1.0) / 255.0;
	}

	float debug_strength = (debug_mode == 5 || debug_mode == 6 || debug_mode == 7 || debug_mode == 8 || pipeline_debug) ? 1.0 : probe_strength;
	float final_refraction_boost = debug_mode == 0 && refr_sample.valid > 0.5 ? 1.16 : 1.0;
	float final_opacity = mix(0.34, 0.50, camera_underwater ? 1.0 : 0.0);
	float strength = pipeline_debug
		? 1.0
		: debug_mode == 0
		? clamp(debug_strength * final_refraction_boost * blend_factor * mask * final_opacity, 0.0, final_opacity)
		: clamp(debug_strength * blend_factor * max(receiver_mask, waterline_band), 0.0, 1.0);
	vec3 output_color = mix(scene_color.rgb, proof_color, strength);
	if (debug_mode == 0 && camera_underwater && underwater_any_enabled) {
		output_color = mix(output_color, underwater_color, clamp(blend_factor * underwater_view_mask, 0.0, 0.96));
	}
	imageStore(color_image, pixel, vec4(output_color, scene_color.a));
}
