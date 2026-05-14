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
layout(set = 0, binding = 8) uniform sampler2D caustics_noise_tex;
layout(set = 0, binding = 9) uniform sampler2DArray normal_tex;

#define MAX_CASCADES 8

layout(std430, set = 0, binding = 4) readonly buffer WaterlineState {
	mat4 inv_projection;
	mat4 inv_view;
	vec4 map_scales[MAX_CASCADES];
	vec4 shore_mask_bounds;
	vec4 shore_params0; // x=fade, y=amp, z=freq, w=speed
	vec4 shore_params1; // x=steep, yzw=medium asymptote
	vec4 optical_params; // xyz=sigma, w=caustics strength
	vec4 sun_params; // xyz=toward sun, w=visibility
	vec4 render_surface0; // x=mesh_mode, y=clipmap_origin_x, z=clipmap_origin_z, w=clipmap_base_quad
	vec4 render_surface1; // x=clipmap_ring_vertices, y=clipmap_ring_count, z=projected_grid_dim, w=projected_overscan
	vec4 receiver_optics; // x=max path, y=surface visual depth, z=debug depth scale, w=reserved
	mat4 projection;
	mat4 view;
} state;

layout(push_constant, std430) uniform Params {
	vec4 screen; // x=width, y=height, z=time, w=blend
	vec4 water; // x=sea_level, y=wave_scale, z=cascade_count, w=probe_strength
	vec4 debug; // x=debug_mode, y=source_color_valid, z=source_depth_valid, w=reserved
	vec4 features; // x=feature_flags, y=camera_water_level, z=normal_valid, w=receiver_source_mode
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
#define normal_valid (pc.features.z > 0.5)
#define receiver_source_mode int(pc.features.w)
#define particle_noise_scale pc.particle_params.x
#define particle_density pc.particle_params.y
#define particle_near_gate pc.particle_params.z
#define particle_far_gate pc.particle_params.w

const int FEATURE_ABSORPTION_FOG = 1;
const int FEATURE_SNELL = 2;
const int FEATURE_WOBBLE = 8;
const int FEATURE_PARTICLES = 16;
const int FEATURE_CAUSTICS = 64;
const int RECEIVER_SOURCE_CAPTURE_DIRECT = 0;
const int RECEIVER_SOURCE_MAIN_ABOVE_CAPTURE_UNDER = 1;
const float CAUSTICS_SPEED = 0.10;
const float CAUSTICS_POWER = 2.0;
const float CAUSTICS_CHROMA_SPLIT = 0.002;
const float CAUSTICS_LUMA_MASK_STRENGTH = 0.22;
const float CAUSTICS_LUMA_LOW = 0.00560224;
const float CAUSTICS_LUMA_HIGH = 0.10559;
const int UNDERWATER_PARTICLE_STEPS = 3;
const float UNDERWATER_PARTICLE_COARSE_THRESHOLD = 0.59;
const float UNDERWATER_PARTICLE_FINE_THRESHOLD = 0.70;
const float UNDERWATER_PARTICLE_FINE_WEIGHT = 0.12;
const vec3 UNDERWATER_PARTICLE_DRIFT = vec3(0.52, 0.15, -0.39);

struct RefractSample {
	vec3 color;
	float valid;
	vec3 world_pos;
	float offset;
	float status;
	float path_length;
	float below_mask;
	float edge_alpha;
};

struct RenderedSurfaceSample {
	float y;
	float valid;
};

struct OpticalSegment {
	float path_length_m;
	float vertical_depth_m;
	vec3 entry_pos;
	float entry_valid;
	vec3 exit_pos;
	float exit_valid;
	float body_gate;
	float valid;
};

struct MediumSample {
	vec3 color;
	vec3 transmittance;
	float fog;
};

const float AIR_IOR = 1.000293;
const float WATER_IOR = 1.3330;
const float WATER_TO_AIR_ETA = WATER_IOR / AIR_IOR;
const float WATER_RAY_MAX_DISTANCE = 5000.0;
const float OPTICAL_SURFACE_EPS = 0.020;
const float SNELL_EDGE_SIN_WIDTH = 0.030;
const float SNELL_WAVE_NORMAL_SHALLOW_WEIGHT = 0.16;
const float SNELL_WAVE_NORMAL_DEEP_WEIGHT = 0.36;
const float WOBBLE_MAX_UV_OFFSET = 0.012;
const float WOBBLE_MIN_CAMERA_DEPTH_M = 0.16;
const float WOBBLE_FULL_CAMERA_DEPTH_M = 0.70;
const float RECEIVER_REFRACTION_REPLACE_OPACITY = 1.0;
const int RECEIVER_RAY_STEPS = 24;
const float RECEIVER_RAY_START_M = 0.12;
const int RENDER_MESH_CLIPMAP = 0;
const int RENDER_MESH_PROJECTED = 1;
const float RENDERED_SURFACE_NEAR_BAND_M = 0.90;

#include "res://src/core/shaders/compute/water_surface_contract.glslinc"

struct SnellSample {
	float window;
	float cos_theta;
	float valid;
	vec3 surface_normal;
	vec3 surface_pos;
	vec3 air_dir;
};

struct WobbleSceneSample {
	vec3 color;
	float guard;
	float status;
	float offset;
	vec2 uv;
};

bool feature_enabled(int bit) {
	return (feature_flags & bit) != 0;
}

float fresnel_dielectric(vec3 incoming, vec3 normal, float eta) {
	float c = abs(dot(incoming, normal));
	float g = eta * eta - 1.0 + c * c;
	if (g <= 0.0) {
		return 1.0;
	}

	g = sqrt(g);
	float a = (g - c) / (g + c);
	float b = (c * (g + c) - 1.0) / (c * (g - c) + 1.0);
	return clamp(0.5 * a * a * (1.0 + b * b), 0.0, 1.0);
}

float snells_window(vec3 normal, vec3 view, float ior) {
	float cos_theta = clamp(dot(normal, view), 0.0, 1.0);
	float sin_theta = sqrt(max(0.0, 1.0 - cos_theta * cos_theta));
	float critical_sin = 1.0 / max(ior, 1e-5);
	float cone_transmission = 1.0 - smoothstep(
		critical_sin - SNELL_EDGE_SIN_WIDTH,
		critical_sin + SNELL_EDGE_SIN_WIDTH,
		sin_theta
	);
	float reflectance = fresnel_dielectric(view, normal, 1.0 / max(ior, 1e-5));
	return cone_transmission * (1.0 - reflectance);
}

vec3 snell_mask_normal(vec3 dynamic_surface_normal, float camera_depth) {
	float wave_weight = mix(
		SNELL_WAVE_NORMAL_SHALLOW_WEIGHT,
		SNELL_WAVE_NORMAL_DEEP_WEIGHT,
		smoothstep(2.0, 10.0, max(camera_depth, 0.0))
	);
	return normalize(mix(vec3(0.0, 1.0, 0.0), dynamic_surface_normal, wave_weight));
}

vec3 refract_water_to_air(vec3 water_ray, vec3 normal) {
	vec3 air_ray = refract(normalize(water_ray), -normalize(normal), WATER_TO_AIR_ETA);
	if (dot(air_ray, air_ray) <= 1e-6 || air_ray.y <= 0.0) {
		return vec3(0.0);
	}
	return normalize(air_ray);
}

vec3 refract_air_to_water(vec3 air_ray, vec3 normal) {
	vec3 water_ray = refract(normalize(air_ray), normalize(normal), AIR_IOR / WATER_IOR);
	if (dot(water_ray, water_ray) <= 1e-6 || water_ray.y >= -0.001) {
		return vec3(0.0);
	}
	return normalize(water_ray);
}

float receiver_optical_max_path() {
	return max(state.receiver_optics.x, 1.0);
}

float receiver_surface_visual_depth() {
	return max(state.receiver_optics.y, 1.0);
}

float receiver_debug_depth_scale() {
	return max(state.receiver_optics.z, 1.0);
}

float luminance(vec3 color) {
	return dot(color, vec3(0.299, 0.587, 0.114));
}

vec2 caustics_panner(vec2 uv, float speed, float tiling) {
	return vec2(TIME * speed, 0.0) + uv * tiling;
}

vec3 caustics_aberration_sample(sampler2D tex, vec2 uv, float split) {
	vec2 uv1 = uv + vec2(split, split);
	vec2 uv2 = uv + vec2(split, -split);
	vec2 uv3 = uv + vec2(-split, -split);
	float r = texture(tex, uv1).r;
	float g = texture(tex, uv2).r;
	float b = texture(tex, uv3).r;
	return vec3(r, g, b);
}

mat3 make_light_projection_basis(vec3 direction) {
	vec3 zaxis = normalize(direction);
	vec3 up = abs(zaxis.y) > 0.98 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
	vec3 xaxis = normalize(cross(up, zaxis));
	vec3 yaxis = normalize(cross(zaxis, xaxis));
	return mat3(
		vec3(xaxis.x, yaxis.x, zaxis.x),
		vec3(xaxis.y, yaxis.y, zaxis.y),
		vec3(xaxis.z, yaxis.z, zaxis.z)
	);
}

float dominant_caustics_scale() {
	float weighted_inverse_tile = 0.0;
	float total_weight = 0.0;
	int count = clamp(cascade_count, 0, MAX_CASCADES);
	for (int i = 0; i < MAX_CASCADES; i++) {
		if (i >= count) {
			break;
		}
		vec4 scales = state.map_scales[i];
		float tile_size = 1.0 / max(max(scales.x, scales.y), 1e-6);
		float weight = max(scales.z * scales.w, 0.0);
		weighted_inverse_tile += weight / max(tile_size, 1.0);
		total_weight += weight;
	}
	if (total_weight <= 0.001 || weighted_inverse_tile <= 1e-6) {
		return 4.0;
	}
	float harmonic_tile = total_weight / weighted_inverse_tile;
	return clamp(harmonic_tile * 0.055, 3.0, 7.0);
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


bool uv_in_screen(vec2 uv);


vec3 sample_source_color_linear(vec2 uv) {
	return texture(source_color_tex, clamp(uv, vec2(0.001), vec2(0.999))).rgb;
}


float receiver_presence_at(vec2 uv) {
	if (!uv_in_screen(uv) || !source_depth_valid) {
		return 0.0;
	}
	return texture(source_depth_tex, uv).r > 0.0001 ? 1.0 : 0.0;
}


float receiver_capture_scale() {
	if (!source_depth_valid) {
		return 1.0;
	}
	vec2 source_size = vec2(textureSize(source_depth_tex, 0));
	vec2 target_size = max(vec2(screen_w, screen_h), vec2(1.0));
	return clamp(min(source_size.x / target_size.x, source_size.y / target_size.y), 0.0, 1.0);
}


bool fetch_receiver_depth_near(vec2 uv, out vec2 receiver_uv, out float depth) {
	receiver_uv = uv;
	depth = 0.0;
	if (!uv_in_screen(uv) || !source_depth_valid) {
		return false;
	}

	depth = texture(source_depth_tex, uv).r;
	if (depth > 0.0001) {
		return true;
	}

	if (receiver_capture_scale() < 0.49) {
		return false;
	}

	vec2 texel = 1.0 / vec2(textureSize(source_depth_tex, 0));

	vec2 candidate_uv = uv + vec2(texel.x, 0.0);
	if (uv_in_screen(candidate_uv)) {
		float candidate_depth = texture(source_depth_tex, candidate_uv).r;
		if (candidate_depth > 0.0001) {
			receiver_uv = candidate_uv;
			depth = candidate_depth;
			return true;
		}
	}
	candidate_uv = uv - vec2(texel.x, 0.0);
	if (uv_in_screen(candidate_uv)) {
		float candidate_depth = texture(source_depth_tex, candidate_uv).r;
		if (candidate_depth > 0.0001) {
			receiver_uv = candidate_uv;
			depth = candidate_depth;
			return true;
		}
	}
	candidate_uv = uv + vec2(0.0, texel.y);
	if (uv_in_screen(candidate_uv)) {
		float candidate_depth = texture(source_depth_tex, candidate_uv).r;
		if (candidate_depth > 0.0001) {
			receiver_uv = candidate_uv;
			depth = candidate_depth;
			return true;
		}
	}
	candidate_uv = uv - vec2(0.0, texel.y);
	if (uv_in_screen(candidate_uv)) {
		float candidate_depth = texture(source_depth_tex, candidate_uv).r;
		if (candidate_depth > 0.0001) {
			receiver_uv = candidate_uv;
			depth = candidate_depth;
			return true;
		}
	}
	candidate_uv = uv + texel;
	if (uv_in_screen(candidate_uv)) {
		float candidate_depth = texture(source_depth_tex, candidate_uv).r;
		if (candidate_depth > 0.0001) {
			receiver_uv = candidate_uv;
			depth = candidate_depth;
			return true;
		}
	}
	candidate_uv = uv - texel;
	if (uv_in_screen(candidate_uv)) {
		float candidate_depth = texture(source_depth_tex, candidate_uv).r;
		if (candidate_depth > 0.0001) {
			receiver_uv = candidate_uv;
			depth = candidate_depth;
			return true;
		}
	}
	candidate_uv = uv + vec2(texel.x, -texel.y);
	if (uv_in_screen(candidate_uv)) {
		float candidate_depth = texture(source_depth_tex, candidate_uv).r;
		if (candidate_depth > 0.0001) {
			receiver_uv = candidate_uv;
			depth = candidate_depth;
			return true;
		}
	}
	candidate_uv = uv + vec2(-texel.x, texel.y);
	if (uv_in_screen(candidate_uv)) {
		float candidate_depth = texture(source_depth_tex, candidate_uv).r;
		if (candidate_depth > 0.0001) {
			receiver_uv = candidate_uv;
			depth = candidate_depth;
			return true;
		}
	}
	return false;
}


float receiver_edge_alpha(vec2 uv) {
	if (!source_depth_valid) {
		return 0.0;
	}
	float capture_scale = receiver_capture_scale();
	vec2 texel = 1.0 / vec2(textureSize(source_depth_tex, 0));
	float weighted = receiver_presence_at(uv) * 5.0;
	float total = 5.0;

	weighted += receiver_presence_at(uv + vec2(texel.x, 0.0)) * 2.5;
	weighted += receiver_presence_at(uv - vec2(texel.x, 0.0)) * 2.5;
	weighted += receiver_presence_at(uv + vec2(0.0, texel.y)) * 2.5;
	weighted += receiver_presence_at(uv - vec2(0.0, texel.y)) * 2.5;
	total += 10.0;

	weighted += receiver_presence_at(uv + texel) * 1.25;
	weighted += receiver_presence_at(uv - texel) * 1.25;
	weighted += receiver_presence_at(uv + vec2(texel.x, -texel.y)) * 1.25;
	weighted += receiver_presence_at(uv + vec2(-texel.x, texel.y)) * 1.25;
	total += 5.0;

	if (capture_scale >= 0.49) {
		vec2 wide = texel * 2.0;
		weighted += receiver_presence_at(uv + vec2(wide.x, 0.0)) * 0.75;
		weighted += receiver_presence_at(uv - vec2(wide.x, 0.0)) * 0.75;
		weighted += receiver_presence_at(uv + vec2(0.0, wide.y)) * 0.75;
		weighted += receiver_presence_at(uv - vec2(0.0, wide.y)) * 0.75;
		total += 3.0;
	}

	float high_res_blend = smoothstep(0.49, 1.0, capture_scale);
	float low_threshold = mix(0.24, 0.10, high_res_blend);
	float high_threshold = mix(0.72, 0.48, high_res_blend);
	return smoothstep(low_threshold, high_threshold, weighted / total);
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


vec2 world_to_uv(vec3 world_pos) {
	return view_to_uv((state.view * vec4(world_pos, 1.0)).xyz);
}


bool uv_in_screen(vec2 uv) {
	return uv.x > 0.001 && uv.x < 0.999 && uv.y > 0.001 && uv.y < 0.999;
}


float get_dynamic_water_level(vec2 final_xz, vec3 cam_pos, bool include_fft, bool include_shore_waves);


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


bool scene_sample_is_above_water(vec2 sample_uv, vec3 cam_pos) {
	if (!uv_in_screen(sample_uv) || !scene_color_valid) {
		return false;
	}
	float depth = get_main_depth(sample_uv);
	if (depth <= 0.0001) {
		return true;
	}
	vec3 sample_world = get_world_position(sample_uv, depth);
	float sample_water_level = get_dynamic_water_level(sample_world.xz, cam_pos, true, true);
	return sample_world.y >= sample_water_level + 0.080;
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


vec3 exterior_atmosphere_color(vec3 air_dir, vec3 fallback) {
	vec3 dir = dot(air_dir, air_dir) > 1e-6 ? normalize(air_dir) : vec3(0.0, 1.0, 0.0);
	float up = clamp(dir.y, 0.0, 1.0);
	vec3 horizon = vec3(0.70, 0.82, 0.92);
	vec3 zenith = vec3(0.30, 0.48, 0.76);
	vec3 sky = mix(horizon, zenith, smoothstep(0.06, 0.92, up));

	vec3 sun_dir = dot(state.sun_params.xyz, state.sun_params.xyz) > 1e-6
		? normalize(state.sun_params.xyz)
		: vec3(0.0, 1.0, 0.0);
	float sun_vis = clamp(state.sun_params.w, 0.0, 1.0);
	float sun_disk = pow(max(dot(dir, sun_dir), 0.0), 320.0);
	float sun_glow = pow(max(dot(dir, sun_dir), 0.0), 18.0) * smoothstep(0.02, 0.28, sun_dir.y);
	vec3 sun_color = vec3(1.0, 0.86, 0.58) * (sun_disk * 2.3 + sun_glow * 0.18) * sun_vis;

	float air_valid = smoothstep(-0.02, 0.10, dir.y);
	return mix(fallback, sky + sun_color, air_valid);
}


vec3 sample_atmosphere_color(vec2 uv, vec3 fallback, vec3 cam_pos, vec3 air_dir, vec3 surface_pos) {
	vec3 atmosphere_fallback = exterior_atmosphere_color(air_dir, fallback);
	if (!scene_color_valid) {
		return atmosphere_fallback;
	}

	if (dot(air_dir, air_dir) > 1e-6) {
		vec3 safe_air_dir = normalize(air_dir);
		vec2 refracted_uv = world_to_uv(surface_pos + safe_air_dir * 240.0);
		if (scene_sample_is_above_water(refracted_uv, cam_pos)) {
			return sample_scene_color(refracted_uv, atmosphere_fallback);
		}

		vec2 near_refracted_uv = world_to_uv(surface_pos + safe_air_dir * 80.0);
		if (scene_sample_is_above_water(near_refracted_uv, cam_pos)) {
			return sample_scene_color(near_refracted_uv, atmosphere_fallback);
		}
	}

	if (scene_sample_is_above_water(uv, cam_pos)) {
		return sample_scene_color(uv, atmosphere_fallback);
	}
	vec2 sample_uv = uv + vec2(0.0, -0.025);
	if (scene_sample_is_above_water(sample_uv, cam_pos)) {
		return sample_scene_color(sample_uv, atmosphere_fallback);
	}
	sample_uv = uv + vec2(0.0, -0.055);
	if (scene_sample_is_above_water(sample_uv, cam_pos)) {
		return sample_scene_color(sample_uv, atmosphere_fallback);
	}
	sample_uv = uv + vec2(0.018, -0.040);
	if (scene_sample_is_above_water(sample_uv, cam_pos)) {
		return sample_scene_color(sample_uv, atmosphere_fallback);
	}
	sample_uv = uv + vec2(-0.018, -0.040);
	if (scene_sample_is_above_water(sample_uv, cam_pos)) {
		return sample_scene_color(sample_uv, atmosphere_fallback);
	}
	sample_uv = uv + vec2(0.0, -0.090);
	if (scene_sample_is_above_water(sample_uv, cam_pos)) {
		return sample_scene_color(sample_uv, atmosphere_fallback);
	}
	return atmosphere_fallback;
}


vec3 rendered_surface_vertex_at_xz(vec2 mesh_xz, vec3 cam_pos) {
	SurfaceSample surface = sample_surface(mesh_xz, cam_pos, true, true);
	return vec3(mesh_xz.x + surface.horizontal_offset.x, surface.y, mesh_xz.y + surface.horizontal_offset.y);
}


bool barycentric_surface_y(vec2 p, vec3 a, vec3 b, vec3 c, out float y) {
	vec2 av = a.xz;
	vec2 bv = b.xz;
	vec2 cv = c.xz;
	vec2 v0 = bv - av;
	vec2 v1 = cv - av;
	vec2 v2 = p - av;
	float d00 = dot(v0, v0);
	float d01 = dot(v0, v1);
	float d11 = dot(v1, v1);
	float d20 = dot(v2, v0);
	float d21 = dot(v2, v1);
	float denom = d00 * d11 - d01 * d01;
	if (abs(denom) <= 1e-7) {
		y = 0.0;
		return false;
	}

	float v = (d11 * d20 - d01 * d21) / denom;
	float w = (d00 * d21 - d01 * d20) / denom;
	float u = 1.0 - v - w;
	const float edge_slop = -0.035;
	if (u < edge_slop || v < edge_slop || w < edge_slop) {
		y = 0.0;
		return false;
	}
	y = a.y * u + b.y * v + c.y * w;
	return true;
}


RenderedSurfaceSample rendered_clipmap_surface(vec2 final_xz, vec3 cam_pos) {
	RenderedSurfaceSample result;
	result.y = get_dynamic_water_level(final_xz, cam_pos, true, true);
	result.valid = 0.0;

	float quad_size = state.render_surface0.w;
	float ring_vertices = state.render_surface1.x;
	if (quad_size <= 0.001 || ring_vertices < 2.0) {
		return result;
	}

	vec2 origin = state.render_surface0.yz;
	float half_size = quad_size * ring_vertices * 0.5;
	vec2 local = final_xz - origin;
	if (abs(local.x) > half_size + quad_size * 2.0 || abs(local.y) > half_size + quad_size * 2.0) {
		return result;
	}

	vec2 grid = (local + vec2(half_size)) / quad_size;
	ivec2 base_cell = ivec2(floor(grid));
	int dim = int(ring_vertices);
	ivec2 cell = clamp(base_cell, ivec2(0), ivec2(dim - 1));
	vec2 mesh00 = origin + vec2(-half_size) + vec2(float(cell.x), float(cell.y)) * quad_size;
	vec2 mesh10 = mesh00 + vec2(quad_size, 0.0);
	vec2 mesh01 = mesh00 + vec2(0.0, quad_size);
	vec2 mesh11 = mesh00 + vec2(quad_size, quad_size);
	vec3 v00 = rendered_surface_vertex_at_xz(mesh00, cam_pos);
	vec3 v10 = rendered_surface_vertex_at_xz(mesh10, cam_pos);
	vec3 v01 = rendered_surface_vertex_at_xz(mesh01, cam_pos);
	vec3 v11 = rendered_surface_vertex_at_xz(mesh11, cam_pos);
	float y = 0.0;
	if (barycentric_surface_y(final_xz, v00, v01, v10, y)) {
		result.y = y;
		result.valid = 1.0;
		return result;
	}
	if (barycentric_surface_y(final_xz, v10, v01, v11, y)) {
		result.y = y;
		result.valid = 1.0;
		return result;
	}
	return result;
}


vec3 projected_grid_plane_vertex(vec2 grid_uv, vec3 cam_pos) {
	float overscan = max(state.render_surface1.w, 1.0);
	vec2 ndc = (grid_uv - 0.5) * 2.0 * overscan;
	vec4 near_view = state.inv_projection * vec4(ndc, 1.0, 1.0);
	vec4 far_view = state.inv_projection * vec4(ndc, 0.0, 1.0);
	near_view.xyz /= max(abs(near_view.w), 1e-6) * sign(near_view.w);
	far_view.xyz /= max(abs(far_view.w), 1e-6) * sign(far_view.w);
	vec3 near_world = (state.inv_view * vec4(near_view.xyz, 1.0)).xyz;
	vec3 far_world = (state.inv_view * vec4(far_view.xyz, 1.0)).xyz;
	vec3 ray_dir = normalize(far_world - near_world);
	if (ray_dir.y > -1e-4) {
		vec2 horiz_dir = length(ray_dir.xz) > 1e-5 ? normalize(ray_dir.xz) : vec2(0.0, 1.0);
		return vec3(near_world.x + horiz_dir.x * 20000.0, sea_level, near_world.z + horiz_dir.y * 20000.0);
	}
	float t = (sea_level - near_world.y) / ray_dir.y;
	if (t < 0.0) {
		vec2 horiz_dir = length(ray_dir.xz) > 1e-5 ? normalize(ray_dir.xz) : vec2(0.0, 1.0);
		return vec3(near_world.x + horiz_dir.x * 20000.0, sea_level, near_world.z + horiz_dir.y * 20000.0);
	}
	return near_world + ray_dir * min(t, 20000.0);
}


vec3 rendered_projected_vertex(vec2 grid_uv, vec3 cam_pos) {
	vec3 plane = projected_grid_plane_vertex(grid_uv, cam_pos);
	vec3 rendered = rendered_surface_vertex_at_xz(plane.xz, cam_pos);
	return rendered;
}


RenderedSurfaceSample rendered_projected_surface(vec2 uv, vec3 cam_pos) {
	RenderedSurfaceSample result;
	vec3 ray_dir = get_world_ray_dir(uv);
	vec3 fallback = cam_pos + ray_dir * 2.0;
	result.y = get_dynamic_water_level(fallback.xz, cam_pos, true, true);
	result.valid = 0.0;

	float dim_f = state.render_surface1.z;
	float overscan = max(state.render_surface1.w, 1.0);
	if (dim_f < 2.0) {
		return result;
	}

	vec2 grid = ((uv * 2.0 - 1.0) / (2.0 * overscan)) + 0.5;
	int dim = int(dim_f);
	ivec2 base_cell = ivec2(floor(grid * dim_f));
	for (int dy = -1; dy <= 1; dy++) {
		for (int dx = -1; dx <= 1; dx++) {
			ivec2 cell = clamp(base_cell + ivec2(dx, dy), ivec2(0), ivec2(dim - 1));
			vec2 g00 = vec2(float(cell.x), float(cell.y)) / dim_f;
			vec2 g10 = vec2(float(cell.x + 1), float(cell.y)) / dim_f;
			vec2 g01 = vec2(float(cell.x), float(cell.y + 1)) / dim_f;
			vec2 g11 = vec2(float(cell.x + 1), float(cell.y + 1)) / dim_f;
			vec3 v00 = rendered_projected_vertex(g00, cam_pos);
			vec3 v10 = rendered_projected_vertex(g10, cam_pos);
			vec3 v01 = rendered_projected_vertex(g01, cam_pos);
			vec3 v11 = rendered_projected_vertex(g11, cam_pos);
			vec2 p00 = world_to_uv(v00);
			vec2 p10 = world_to_uv(v10);
			vec2 p01 = world_to_uv(v01);
			vec2 p11 = world_to_uv(v11);
			float y = 0.0;
			if (barycentric_surface_y(uv, vec3(p00.x, v00.y, p00.y), vec3(p01.x, v01.y, p01.y), vec3(p10.x, v10.y, p10.y), y)) {
				result.y = y;
				result.valid = 1.0;
				return result;
			}
			if (barycentric_surface_y(uv, vec3(p10.x, v10.y, p10.y), vec3(p01.x, v01.y, p01.y), vec3(p11.x, v11.y, p11.y), y)) {
				result.y = y;
				result.valid = 1.0;
				return result;
			}
		}
	}
	return result;
}


RenderedSurfaceSample rendered_surface_sample(vec2 final_xz, vec2 uv, vec3 cam_pos) {
	int mesh_mode = int(state.render_surface0.x + 0.5);
	if (mesh_mode == RENDER_MESH_PROJECTED) {
		RenderedSurfaceSample fallback;
		fallback.y = get_dynamic_water_level(final_xz, cam_pos, true, true);
		fallback.valid = 0.0;
		return fallback;
	}
	return rendered_clipmap_surface(final_xz, cam_pos);
}


float get_near_rendered_water_level(vec2 final_xz, vec2 uv, vec3 cam_pos, float fallback_y, float test_y) {
	if (abs(fallback_y - test_y) > RENDERED_SURFACE_NEAR_BAND_M) {
		return fallback_y;
	}
	RenderedSurfaceSample rendered = rendered_surface_sample(final_xz, uv, cam_pos);
	return rendered.valid > 0.5 ? rendered.y : fallback_y;
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


vec3 water_optical_normal_at(vec2 xz, vec3 cam_pos) {
	if (!normal_valid || cascade_count <= 0) {
		return water_normal_at(xz, cam_pos);
	}

	vec2 gradient = vec2(0.0);
	float total_weight = 0.0;
	float dist_to_camera = length(vec3(xz.x, sea_level, xz.y) - cam_pos);
	int count = clamp(cascade_count, 0, MAX_CASCADES);
	for (int i = 0; i < MAX_CASCADES; i++) {
		if (i >= count) {
			break;
		}
		vec4 scales = state.map_scales[i];
		float tile_size = 1.0 / max(scales.x, 1e-6);
		float cascade_fade = clamp(exp(-(dist_to_camera - 50.0) / (tile_size * 20.0)), 0.0, 1.0);
		vec4 normal_sample = texture(normal_tex, vec3(xz * scales.xy, float(i)));
		gradient += normal_sample.xy * scales.w * cascade_fade;
		total_weight += cascade_fade;
	}

	if (total_weight <= 0.001) {
		return water_normal_at(xz, cam_pos);
	}
	return normalize(vec3(-gradient.x, 1.0, -gradient.y));
}


bool trace_water_surface(vec2 uv, vec3 cam_pos, out vec3 water_world, out float water_gate) {
	vec3 ray_dir = get_world_ray_dir(uv);
	if (abs(ray_dir.y) < 1e-4) {
		water_world = cam_pos + ray_dir * WATER_RAY_MAX_DISTANCE;
		water_gate = 0.0;
		return false;
	}

	float plane_t = (sea_level - cam_pos.y) / ray_dir.y;
	if (plane_t <= 0.0 || plane_t > WATER_RAY_MAX_DISTANCE) {
		water_world = cam_pos + ray_dir * clamp(plane_t, 0.0, WATER_RAY_MAX_DISTANCE);
		water_gate = 0.0;
		return false;
	}

	vec3 plane_world = cam_pos + ray_dir * plane_t;
	float stable_gate = water_surface_body_gate(stable_water_body_coverage(plane_world.xz));
	if (stable_gate <= 0.001) {
		water_world = plane_world;
		water_gate = 0.0;
		return false;
	}

	float t = plane_t;
	for (int i = 0; i < 4; i++) {
		if (t <= 0.0 || t > WATER_RAY_MAX_DISTANCE) {
			water_world = plane_world;
			water_gate = stable_gate;
			return true;
		}
		vec3 p = cam_pos + ray_dir * t;
		float water_y = get_dynamic_water_level(p.xz, cam_pos, true, true);
		water_y = get_near_rendered_water_level(p.xz, uv, cam_pos, water_y, p.y);
		t = (water_y - cam_pos.y) / ray_dir.y;
	}
	if (t <= 0.0 || t > WATER_RAY_MAX_DISTANCE) {
		water_world = plane_world;
		water_gate = stable_gate;
		return true;
	}

	water_world = cam_pos + ray_dir * t;
	float coverage = max(water_coverage_at(water_world.xz, cam_pos), stable_water_body_coverage(plane_world.xz));
	water_gate = smoothstep(0.015, 0.12, coverage);
	return water_gate > 0.001;
}

SnellSample compute_snell_sample(vec3 cam_pos, vec3 view_dir, vec3 water_surface_pos, bool water_surface_hit, float camera_depth) {
	SnellSample result;
	result.window = 0.0;
	result.cos_theta = 0.0;
	result.valid = 0.0;
	result.surface_normal = vec3(0.0, 1.0, 0.0);
	result.surface_pos = water_surface_pos;
	result.air_dir = vec3(0.0, 1.0, 0.0);

	if (!water_surface_hit) {
		return result;
	}

	vec3 surface_ray = normalize(water_surface_pos - cam_pos);
	if (surface_ray.y <= 0.0 || dot(surface_ray, view_dir) <= 0.985) {
		return result;
	}

	vec3 surface_normal = water_optical_normal_at(water_surface_pos.xz, cam_pos);
	vec3 mask_normal = snell_mask_normal(surface_normal, camera_depth);
	float wave_cos_theta = clamp(dot(surface_ray, mask_normal), 0.0, 1.0);
	if (wave_cos_theta <= 0.0) {
		return result;
	}

	// Snell window for water->air transmission. The critical boundary is
	// theta_c = asin(n_air / n_water), which gives a ~97 degree full cone.
	float window = snells_window(mask_normal, surface_ray, WATER_TO_AIR_ETA);
	vec3 air_dir = refract_water_to_air(surface_ray, mask_normal);
	if (dot(air_dir, air_dir) <= 1e-6) {
		return result;
	}

	result.window = window;
	result.cos_theta = wave_cos_theta;
	result.valid = 1.0;
	result.surface_normal = surface_normal;
	result.air_dir = air_dir;
	return result;
}


float underwater_mote_layer(vec3 sample_pos, float cell_scale, float threshold) {
	vec3 p = sample_pos * cell_scale;
	float xz = fbm2(p.xz + vec2(p.y * 0.071, -p.y * 0.043));
	float xy = fbm2(p.xy * 0.83 + vec2(p.z * 0.049, p.z * 0.061));
	float yz = fbm2(p.yz * 0.67 + vec2(-p.x * 0.037, p.x * 0.052));
	float field = xz * 0.52 + xy * 0.30 + yz * 0.18;
	return pow(smoothstep(threshold, 0.92, field), 1.35);
}


float compute_underwater_particles(vec2 uv, vec3 cam_pos, vec3 view_dir, float pixel_dist, float camera_depth) {
	float scale = clamp(particle_noise_scale, 0.005, 1.5);
	float coarse_scale = mix(0.18, 0.62, clamp(scale / 1.5, 0.0, 1.0));
	float fine_scale = coarse_scale * 2.20;
	vec3 drift = UNDERWATER_PARTICLE_DRIFT * TIME;
	float sample_limit = min(pixel_dist, particle_far_gate);
	float flecks = 0.0;
	for (int i = 0; i < UNDERWATER_PARTICLE_STEPS; i++) {
		float t = (float(i) + 0.5) / float(UNDERWATER_PARTICLE_STEPS);
		float sample_dist = mix(0.45, sample_limit, t);
		vec3 p = cam_pos + view_dir * sample_dist + drift + vec3(0.31, -0.17, 0.23) * float(i);
		float coarse_mote = underwater_mote_layer(p, coarse_scale, UNDERWATER_PARTICLE_COARSE_THRESHOLD);
		float fine_mote = underwater_mote_layer(p + vec3(9.7, -3.1, 4.3), fine_scale, UNDERWATER_PARTICLE_FINE_THRESHOLD);
		flecks += coarse_mote + fine_mote * UNDERWATER_PARTICLE_FINE_WEIGHT;
	}
	flecks *= 0.24;
	float depth_gate = smoothstep(0.20, 3.5, camera_depth);
	float near_gate = max(particle_near_gate, 0.25);
	float far_gate = max(particle_far_gate, near_gate + 1.0);
	float dist_gate = smoothstep(near_gate, near_gate + 4.0, pixel_dist)
		* (1.0 - smoothstep(far_gate, far_gate + 85.0, pixel_dist));
	return clamp(flecks * particle_density * dist_gate * depth_gate, 0.0, 1.0);
}


vec3 compute_receiver_caustics(vec3 world_pos, vec3 cam_pos, vec3 receiver_color, float water_depth, float water_gate) {
	float strength = state.optical_params.w;
	if (strength <= 0.001 || water_depth <= 0.02 || water_gate <= 0.001) {
		return vec3(0.0);
	}

	vec3 sun_dir = normalize(state.sun_params.xyz);
	float sun_vis = clamp(state.sun_params.w, 0.0, 1.0);
	float sun_gate = smoothstep(0.04, 0.30, sun_dir.y) * sun_vis;
	if (sun_gate <= 0.001) {
		return vec3(0.0);
	}

	float sun_height = max(sun_dir.y, 0.05);
	vec2 surface_xz = world_pos.xz + sun_dir.xz * (water_depth / sun_height);
	vec3 surface_normal = water_normal_at(surface_xz, cam_pos);
	float slope_focus = clamp(length(surface_normal.xz) * 2.6, 0.0, 1.0);
	mat3 light_basis = make_light_projection_basis(sun_dir);
	vec2 caustic_uv = (light_basis * vec3(surface_xz.x, world_pos.y, surface_xz.y)).xy;
	float caustic_scale = dominant_caustics_scale();
	vec2 uv1 = caustics_panner(caustic_uv, 0.75 * CAUSTICS_SPEED, 1.0 / caustic_scale);
	vec2 uv2 = caustics_panner(caustic_uv, CAUSTICS_SPEED, -1.0 / caustic_scale);
	vec3 caus1 = pow(caustics_aberration_sample(caustics_noise_tex, uv1, CAUSTICS_CHROMA_SPLIT), vec3(CAUSTICS_POWER));
	vec3 caus2 = pow(caustics_aberration_sample(caustics_noise_tex, uv2, CAUSTICS_CHROMA_SPLIT), vec3(CAUSTICS_POWER));
	vec3 caustic = min(caus1, caus2);

	float scene_luma = clamp(luminance(receiver_color), 0.0, 1.0);
	float luma_ramp = smoothstep(CAUSTICS_LUMA_LOW, CAUSTICS_LUMA_HIGH, scene_luma);
	float luma_mask = mix(1.0, luma_ramp, CAUSTICS_LUMA_MASK_STRENGTH);
	float depth_atten = exp(-water_depth * 0.060) * (1.0 - smoothstep(42.0, 90.0, water_depth));
	float camera_dist = length(world_pos - cam_pos);
	float distance_gate = 1.0 - smoothstep(90.0, 180.0, camera_dist);
	float shallow_gate = smoothstep(0.08, 0.45, water_depth);
	float view_atten = exp(-dot(state.optical_params.xyz, vec3(0.333333)) * min(camera_dist, 70.0) * 0.35);
	return caustic * vec3(0.48, 0.86, 1.0) * luma_mask * mix(0.45, 1.20, slope_focus)
		* depth_atten * distance_gate * shallow_gate * view_atten * water_gate * sun_gate * strength * 0.58;
}


OpticalSegment compute_optical_segment(vec3 ray_start, vec3 ray_end, vec3 surface_cam_pos) {
	OpticalSegment result;
	result.path_length_m = 0.0;
	result.vertical_depth_m = 0.0;
	result.entry_pos = ray_start;
	result.entry_valid = 0.0;
	result.exit_pos = ray_start;
	result.exit_valid = 0.0;
	result.body_gate = 0.0;
	result.valid = 0.0;

	vec3 ray_delta = ray_end - ray_start;
	float ray_len = length(ray_delta);
	if (ray_len <= 1e-5) {
		return result;
	}

	WaterSurfaceContractSample start_surface = water_surface_query(ray_start, surface_cam_pos, true, true);
	WaterSurfaceContractSample end_surface = water_surface_query(ray_end, surface_cam_pos, true, true);
	result.vertical_depth_m = max(end_surface.depth, 0.0);
	result.body_gate = max(start_surface.body_gate, end_surface.body_gate);
	if (result.body_gate <= 0.001) {
		return result;
	}

	bool start_in_water = start_surface.depth >= -OPTICAL_SURFACE_EPS;
	bool end_in_water = end_surface.depth > OPTICAL_SURFACE_EPS;
	if (start_in_water && end_in_water) {
		result.entry_pos = ray_start;
		result.exit_pos = ray_end;
		result.entry_valid = 1.0;
		result.exit_valid = 1.0;
		result.path_length_m = ray_len;
	} else if (!start_in_water && end_in_water) {
		float entry_t = find_water_entry_t(ray_start, ray_end);
		if (entry_t > 0.0 && entry_t < 1.0) {
			result.entry_pos = mix(ray_start, ray_end, entry_t);
			result.exit_pos = ray_end;
			result.entry_valid = 1.0;
			result.exit_valid = 1.0;
			result.path_length_m = length(result.exit_pos - result.entry_pos);
		} else {
			result.entry_pos = ray_end - normalize(ray_delta) * min(ray_len, result.vertical_depth_m);
			result.exit_pos = ray_end;
			result.entry_valid = result.vertical_depth_m > 0.001 ? 1.0 : 0.0;
			result.exit_valid = result.entry_valid;
			result.path_length_m = min(ray_len, result.vertical_depth_m);
		}
	} else if (start_in_water && !end_in_water) {
		float exit_t = find_water_entry_t(ray_start, ray_end);
		if (exit_t > 0.0 && exit_t < 1.0) {
			result.entry_pos = ray_start;
			result.exit_pos = mix(ray_start, ray_end, exit_t);
			result.entry_valid = 1.0;
			result.exit_valid = 1.0;
			result.path_length_m = length(result.exit_pos - result.entry_pos);
		} else {
			result.entry_pos = ray_start;
			result.exit_pos = ray_end;
			result.entry_valid = 1.0;
			result.exit_valid = 0.0;
			result.path_length_m = ray_len;
		}
	}

	result.valid = (result.path_length_m > 0.001 && result.body_gate > 0.001) ? 1.0 : 0.0;
	return result;
}


MediumSample apply_water_medium(vec3 source_color, vec3 tint, vec3 sigma, float path_length_m) {
	MediumSample result;
	float optical_path = min(max(path_length_m, 0.0), receiver_optical_max_path());
	vec3 extinction = max(sigma, vec3(0.0));
	result.transmittance = exp(-extinction * optical_path);
	result.fog = clamp(1.0 - luminance(result.transmittance), 0.0, 1.0);
	result.color = source_color * result.transmittance
		+ tint * (vec3(1.0) - result.transmittance);
	return result;
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


float screen_edge_guard(vec2 sample_uv) {
	float edge_dist = min(min(sample_uv.x, 1.0 - sample_uv.x), min(sample_uv.y, 1.0 - sample_uv.y));
	return smoothstep(0.006, 0.035, edge_dist);
}


float foreground_occludes_water_surface(bool main_depth_present, vec3 main_world_pos, vec3 cam_pos, bool water_ray_hit, vec3 water_surface_pos) {
	if (!main_depth_present || !water_ray_hit) {
		return 0.0;
	}

	float scene_dist = length(main_world_pos - cam_pos);
	float surface_dist = length(water_surface_pos - cam_pos);
	float foreground_gap = surface_dist - scene_dist;
	return smoothstep(0.12, 0.55, foreground_gap);
}


vec2 projected_wobble_uv_offset(vec3 focal_world, vec3 normal_view, float offset_meters) {
	vec2 view_dir_xy = normal_view.xy;
	float view_dir_len = length(view_dir_xy);
	if (view_dir_len <= 1e-5 || offset_meters <= 1e-5) {
		return vec2(0.0);
	}

	vec3 focal_view = (state.view * vec4(focal_world, 1.0)).xyz;
	vec2 focal_uv = view_to_uv(focal_view);
	if (!uv_in_screen(focal_uv)) {
		return vec2(0.0);
	}

	vec3 shifted_view = focal_view + vec3(view_dir_xy / view_dir_len * offset_meters * clamp(view_dir_len, 0.0, 1.0), 0.0);
	vec2 shifted_uv = view_to_uv(shifted_view);
	vec2 offset = shifted_uv - focal_uv;
	float offset_len = length(offset);
	if (offset_len > WOBBLE_MAX_UV_OFFSET) {
		offset *= WOBBLE_MAX_UV_OFFSET / offset_len;
	}
	return offset;
}


WobbleSceneSample guarded_underwater_scene_sample(
	vec2 uv,
	vec2 full_offset,
	vec3 base_world,
	vec3 cam_pos,
	float pre_guard,
	vec3 fallback_color
) {
	WobbleSceneSample result;
	result.color = fallback_color;
	result.guard = 0.0;
	result.status = 0.0;
	result.offset = 0.0;
	result.uv = uv;

	float full_offset_len = length(full_offset);
	if (!scene_color_valid || full_offset_len <= 1e-6) {
		result.status = 1.0;
		return result;
	}
	if (pre_guard <= 0.001) {
		result.status = 8.0;
		return result;
	}

	float base_dist = length(base_world - cam_pos);
	float reject_status = 0.0;
	for (int i = 0; i < 3; i++) {
		float scale = 1.0;
		if (i == 1) {
			scale = 0.66;
		} else if (i == 2) {
			scale = 0.33;
		}

		vec2 sample_uv = uv + full_offset * scale;
		if (!uv_in_screen(sample_uv)) {
			reject_status = 2.0;
			continue;
		}

		float edge_guard = screen_edge_guard(sample_uv);
		if (edge_guard <= 0.001) {
			reject_status = 2.0;
			continue;
		}

		float sample_depth = get_main_depth(sample_uv);
		if (sample_depth <= 0.0001) {
			reject_status = 3.0;
			continue;
		}

		vec3 sample_world = get_world_position(sample_uv, sample_depth);
		float sample_water_depth = get_dynamic_water_level(sample_world.xz, cam_pos, true, true) - sample_world.y;
		float sample_underwater_gate = smoothstep(0.02, 0.35, sample_water_depth);
		if (sample_underwater_gate <= 0.001) {
			reject_status = 4.0;
			continue;
		}

		float sample_dist = length(sample_world - cam_pos);
		float depth_delta = abs(sample_dist - base_dist);
		float depth_edge_start = max(0.75, base_dist * 0.045);
		float depth_edge_end = max(2.00, base_dist * 0.160);
		float depth_guard = 1.0 - smoothstep(depth_edge_start, depth_edge_end, depth_delta);
		if (depth_guard <= 0.025) {
			reject_status = 5.0;
			continue;
		}

		float guard = pre_guard * edge_guard * sample_underwater_gate * depth_guard * mix(0.55, 1.0, scale);
		if (guard <= 0.005) {
			reject_status = 6.0;
			continue;
		}

		result.color = sample_scene_color(sample_uv, fallback_color);
		result.guard = guard;
		result.status = 9.0;
		result.offset = length(full_offset * scale);
		result.uv = sample_uv;
		return result;
	}

	result.status = reject_status;
	return result;
}


bool fetch_underwater_source(
	vec2 sample_uv,
	vec3 cam_pos,
	out vec3 sample_color,
	out vec3 sample_world,
	out float edge_alpha,
	out float reject_status
) {
	sample_color = vec3(0.0);
	sample_world = vec3(0.0);
	edge_alpha = 0.0;
	reject_status = 0.0;

	if (!uv_in_screen(sample_uv)) {
		reject_status = 5.0;
		return false;
	}

	if (!source_valid || !source_depth_valid) {
		reject_status = 1.0;
		return false;
	}

	vec2 receiver_uv = sample_uv;
	float sample_depth = 0.0;
	if (!fetch_receiver_depth_near(sample_uv, receiver_uv, sample_depth)) {
		reject_status = 6.0;
		return false;
	}

	sample_world = get_world_position(receiver_uv, sample_depth);
	float sample_water_level = get_dynamic_water_level(sample_world.xz, cam_pos, true, true);
	if (sample_world.y >= sample_water_level + 0.015) {
		reject_status = 7.0;
		return false;
	}

	edge_alpha = max(receiver_edge_alpha(sample_uv), receiver_edge_alpha(receiver_uv));
	if (edge_alpha <= 0.001) {
		reject_status = 10.0;
		return false;
	}

	sample_color = sample_source_color_linear(receiver_uv);
	return true;
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
	result.world_pos = water_world_pos;
	result.offset = 0.0;
	result.status = 0.0;
	result.path_length = 0.0;
	result.below_mask = 0.0;
	result.edge_alpha = 0.0;
	if (!source_valid || !source_depth_valid) {
		result.status = 1.0;
		return result;
	}
	if (water_gate <= 0.001) {
		result.status = 3.0;
		return result;
	}

	vec3 view_dir = normalize(water_world_pos - cam_pos);
	vec3 world_normal = water_optical_normal_at(water_world_pos.xz, cam_pos);
	vec3 water_ray = refract_air_to_water(view_dir, world_normal);
	if (dot(water_ray, water_ray) <= 1e-6) {
		result.status = 4.0;
		return result;
	}

	float reject_status = 0.0;
	float max_path = receiver_optical_max_path();
	for (int i = 0; i < RECEIVER_RAY_STEPS; i++) {
		float step_t = (float(i) + 0.5) / float(RECEIVER_RAY_STEPS);
		float ray_t = mix(RECEIVER_RAY_START_M, max_path, pow(step_t, 1.25));
		vec3 ray_world = water_world_pos + water_ray * ray_t;
		float ray_water_level = get_dynamic_water_level(ray_world.xz, cam_pos, true, true);
		if (ray_world.y > ray_water_level + 0.10) {
			reject_status = 7.0;
			continue;
		}

		vec2 refr_uv = world_to_uv(ray_world);
		if (!uv_in_screen(refr_uv)) {
			reject_status = 5.0;
			continue;
		}

		vec2 receiver_uv = refr_uv;
		float receiver_depth = 0.0;
		if (!fetch_receiver_depth_near(refr_uv, receiver_uv, receiver_depth)) {
			reject_status = 6.0;
			continue;
		}

		vec3 sample_world = get_world_position(receiver_uv, receiver_depth);
		float sample_water_level = get_dynamic_water_level(sample_world.xz, cam_pos, true, true);
		if (sample_world.y >= sample_water_level + 0.015) {
			reject_status = 7.0;
			continue;
		}

		vec3 receiver_delta = sample_world - water_world_pos;
		float receiver_t = dot(receiver_delta, water_ray);
		if (receiver_t < RECEIVER_RAY_START_M || receiver_t > max_path) {
			reject_status = 8.0;
			continue;
		}

		vec3 closest = water_world_pos + water_ray * receiver_t;
		float miss_distance = length(sample_world - closest);
		float depth_delta = abs(receiver_t - ray_t);
		float hit_radius = max(0.22, receiver_t * 0.028);
		float step_radius = max(max_path / float(RECEIVER_RAY_STEPS) * 1.35, receiver_t * 0.018);
		if (miss_distance > hit_radius || depth_delta > step_radius) {
			reject_status = 8.0;
			continue;
		}

		float edge_alpha = max(receiver_edge_alpha(refr_uv), receiver_edge_alpha(receiver_uv));
		if (edge_alpha <= 0.001) {
			reject_status = 10.0;
			continue;
		}

		result.color = sample_source_color_linear(receiver_uv);
		result.valid = edge_alpha;
		result.world_pos = sample_world;
		result.offset = length(refr_uv - uv);
		result.status = 9.0;
		result.path_length = max(receiver_t, RECEIVER_RAY_START_M);
		float sample_water_depth = max(sample_water_level - sample_world.y, 0.0);
		result.below_mask = smoothstep(0.02, 0.35, sample_water_depth);
		result.edge_alpha = edge_alpha;
		return result;
	}

	result.status = reject_status;
	return result;
}


void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (pixel.x >= int(screen_w) || pixel.y >= int(screen_h)) {
		return;
	}

	vec2 uv = (vec2(pixel) + 0.5) / vec2(screen_w, screen_h);
	bool pipeline_debug = debug_mode == 9;
	bool phase2_debug = debug_mode >= 10 && debug_mode <= 14;
	vec4 scene_color = imageLoad(color_image, pixel);
	vec3 cam_pos = state.inv_view[3].xyz;
	float camera_water_level = get_dynamic_water_level(cam_pos.xz, cam_pos, true, true);
	bool camera_underwater = cam_pos.y < camera_water_level - 0.02;
	vec3 view_dir = get_world_ray_dir(uv);
	bool absorption_enabled = feature_enabled(FEATURE_ABSORPTION_FOG);
	bool snell_enabled = feature_enabled(FEATURE_SNELL);
	bool wobble_enabled = feature_enabled(FEATURE_WOBBLE);
	bool particles_enabled = false;
	bool caustics_enabled = feature_enabled(FEATURE_CAUSTICS);
	bool underwater_any_enabled = absorption_enabled || snell_enabled || wobble_enabled || particles_enabled || caustics_enabled;
	if (debug_mode == 0 && camera_underwater && !underwater_any_enabled) {
		return;
	}
	vec3 analytic_water_pos = cam_pos + view_dir * 5000.0;
	float analytic_water_gate = 0.0;
	bool needs_water_ray = camera_underwater || pipeline_debug || debug_mode != 0 || source_depth_valid;
	bool water_ray_hit = false;
	if (needs_water_ray) {
		water_ray_hit = trace_water_surface(uv, cam_pos, analytic_water_pos, analytic_water_gate);
	}

	float raw_depth = source_depth_valid ? get_source_depth(uv) : 0.0;
	float main_depth = get_main_depth(uv);
	bool main_depth_present = main_depth > 0.0001;
	bool receiver_depth_present = source_depth_valid && raw_depth > 0.0001;
	if (!main_depth_present && !receiver_depth_present && !water_ray_hit && !camera_underwater) {
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
	WaterSurfaceContractSample receiver_surface = water_surface_query(world_pos, cam_pos, true, true);
	WaterSurfaceContractSample main_surface = water_surface_query(main_world_pos, cam_pos, true, true);
	WaterSurfaceContractSample camera_surface = water_surface_query(cam_pos, cam_pos, true, true);
	float water_level = receiver_surface.y;
	if (debug_mode == 1) {
		water_level = sea_level;
	} else if (debug_mode == 2) {
		water_level = get_dynamic_water_level(world_pos.xz, cam_pos, true, false);
	}
	float water_depth = water_level - world_pos.y;
	float main_water_level = main_surface.y;
	float main_water_depth = main_water_level - main_world_pos.y;
	float receiver_coverage = receiver_depth_present ? receiver_surface.coverage : 0.0;
	float main_coverage = main_surface.coverage;
	float camera_coverage = camera_surface.coverage;
	float water_body_gate = max(
		water_surface_body_gate(max(main_coverage, camera_underwater ? camera_coverage : 0.0)),
		analytic_water_gate
	);

	float below_mask = smoothstep(0.02, 0.35, water_depth);
	float crossing_mask = ray_water_crossing_mask(cam_pos, world_pos, camera_water_level, water_depth);
	if (!receiver_depth_present && !main_depth_present && water_ray_hit) {
		crossing_mask = 1.0;
	}
	float submerged_view_mask = camera_underwater
		? max(below_mask, crossing_mask)
		: below_mask;
	float receiver_mask = receiver_depth_present
		? submerged_view_mask
		: 0.0;
	// Main-view ocean depth is a useful hint, but the water body ray keeps the
	// compositor stable when the finite clipmap mesh/depth footprint drops out.
	float visible_water_depth_gate = main_depth_present ? smoothstep(-0.08, 0.04, main_water_depth) : 0.0;
	float visible_water_band_gate = main_depth_present ? 1.0 - smoothstep(0.55, 1.45, abs(main_water_depth)) : 0.0;
	float analytic_visible_water_gate = water_ray_hit ? analytic_water_gate : 0.0;
	float visible_water_gate = camera_underwater
		? max(max(submerged_view_mask, crossing_mask * 0.65), analytic_visible_water_gate * 0.75)
		: max(visible_water_depth_gate * visible_water_band_gate, analytic_visible_water_gate);
	float visible_water_pixel_gate = main_depth_present
		? visible_water_depth_gate * visible_water_band_gate
		: 0.0;
	float receiver_occludes_surface_gate = receiver_depth_present
		? receiver_mask * crossing_mask * analytic_visible_water_gate
		: 0.0;
	float receiver_refraction_gate = max(visible_water_pixel_gate, receiver_occludes_surface_gate) * water_body_gate;
	float direct_receiver_gate = receiver_mask * water_body_gate;
	if (debug_mode == 0 && !camera_underwater && max(receiver_refraction_gate, direct_receiver_gate) <= 0.001) {
		return;
	}

	vec3 receiver_surface_pos = receiver_occludes_surface_gate > visible_water_pixel_gate && water_ray_hit
		? analytic_water_pos
		: main_world_pos;
	RefractSample refr_sample = refracted_receiver_from_water_pixel(uv, scene_color.rgb, cam_pos, receiver_surface_pos, receiver_refraction_gate);
	OpticalSegment refracted_segment = compute_optical_segment(receiver_surface_pos, refr_sample.world_pos, cam_pos);
	if (refr_sample.valid > 0.001 && refracted_segment.valid <= 0.001 && refr_sample.path_length > 0.001) {
		refracted_segment.path_length_m = refr_sample.path_length;
		refracted_segment.vertical_depth_m = max(get_dynamic_water_level(refr_sample.world_pos.xz, cam_pos, true, true) - refr_sample.world_pos.y, 0.0);
		refracted_segment.entry_pos = receiver_surface_pos;
		refracted_segment.entry_valid = 1.0;
		refracted_segment.exit_pos = refr_sample.world_pos;
		refracted_segment.exit_valid = 1.0;
		refracted_segment.body_gate = 1.0;
		refracted_segment.valid = 1.0;
	}
	float refracted_receiver_mask = refr_sample.valid * refr_sample.below_mask * receiver_refraction_gate;

	vec3 direct_source_color = scene_color.rgb;
	vec3 direct_source_world = world_pos;
	float direct_edge_alpha = 0.0;
	float direct_reject_status = 0.0;
	bool direct_source_valid = direct_receiver_gate > 0.001
		&& fetch_underwater_source(uv, cam_pos, direct_source_color, direct_source_world, direct_edge_alpha, direct_reject_status);
	OpticalSegment direct_segment = compute_optical_segment(cam_pos, direct_source_world, cam_pos);
	float direct_below_mask = direct_source_valid ? smoothstep(0.02, 0.35, direct_segment.vertical_depth_m) : 0.0;
	float direct_receiver_mask = direct_source_valid
		? direct_edge_alpha * direct_below_mask * direct_receiver_gate * direct_segment.valid
		: 0.0;
	float mask = max(refracted_receiver_mask, direct_receiver_mask);
	if (debug_mode == 0 && mask <= 0.001 && !camera_underwater) {
		return;
	}

	vec3 tint = state.shore_params1.yzw;
	vec3 sigma = state.optical_params.xyz;
	bool use_refracted_receiver = refracted_receiver_mask > 0.001;
	vec3 receiver_world_pos = direct_source_valid ? direct_source_world : (use_refracted_receiver ? refr_sample.world_pos : world_pos);
	vec3 source_color = use_refracted_receiver
		? refr_sample.color
		: (direct_receiver_mask > 0.001 ? direct_source_color : scene_color.rgb);
	OpticalSegment receiver_segment = direct_source_valid ? direct_segment : refracted_segment;
	if (!direct_source_valid && use_refracted_receiver) {
		receiver_segment = refracted_segment;
	}
	float receiver_path_length = receiver_segment.valid > 0.001 ? receiver_segment.path_length_m : 0.0;
	float receiver_vertical_depth = receiver_segment.valid > 0.001 ? receiver_segment.vertical_depth_m : water_depth;
	MediumSample receiver_medium = apply_water_medium(source_color, tint, sigma, receiver_path_length);
	vec3 water_color = source_color;
	if (absorption_enabled) {
		water_color = receiver_medium.color;
	}
	float caustic_gate = mask;
	water_color += caustics_enabled
		? compute_receiver_caustics(receiver_world_pos, cam_pos, water_color, max(receiver_vertical_depth, 0.0), caustic_gate) * (camera_underwater ? 1.0 : 0.35)
		: vec3(0.0);

	vec3 proof_color = water_color;
	if (debug_mode == 4) {
		proof_color = vec3(receiver_mask, water_body_gate, receiver_refraction_gate);
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
		} else if (refr_sample.valid > 0.5) {
			proof_color = mix(refr_sample.color, vec3(0.0, 1.0, 0.25), 0.16);
		} else {
			proof_color = vec3(0.4, 0.4, 0.4);
		}
	} else if (debug_mode == 6) {
		float offset_meter = clamp(refr_sample.offset * 80.0, 0.0, 1.0);
		float accepted_meter = clamp(mask, 0.0, 1.0);
		proof_color = vec3(offset_meter, accepted_meter, refr_sample.valid > 0.5 ? 0.08 : 0.65);
	} else if (debug_mode == 7) {
		proof_color = vec3(
			source_valid ? 0.0 : 1.0,
			source_depth_valid ? 1.0 : 0.0,
			scene_color_valid ? 0.25 : 0.0
		);
	} else if (debug_mode == 8) {
		proof_color = vec3(camera_underwater ? 1.0 : 0.0, water_body_gate, analytic_water_gate);
	} else if (pipeline_debug) {
		proof_color = pipeline_debug_color(
			uv,
			1.0,
			1.0,
			source_valid ? 1.0 : 0.0,
			source_depth_valid ? 1.0 : 0.0,
			receiver_mask,
			water_body_gate,
			receiver_refraction_gate,
			mask
		);
	} else if (debug_mode == 10) {
		float camera_depth_t = clamp((camera_water_level - cam_pos.y) / 8.0, -1.0, 1.0);
		proof_color = camera_depth_t >= 0.0
			? vec3(0.0, camera_depth_t, 1.0 - camera_depth_t * 0.35)
			: vec3(-camera_depth_t, 0.10, 0.0);
	} else if (debug_mode == 11) {
		float receiver_depth_t = clamp(receiver_path_length / receiver_debug_depth_scale(), 0.0, 1.0);
		proof_color = receiver_segment.valid > 0.001
			? vec3(0.0, receiver_depth_t, 1.0 - receiver_depth_t * 0.35)
			: vec3(1.0, 0.05, 0.0);
	} else if (debug_mode == 12) {
		proof_color = vec3(water_ray_hit ? 1.0 : 0.0, crossing_mask, analytic_water_gate);
	} else if (debug_mode == 13) {
		proof_color = vec3(receiver_coverage, main_coverage, camera_coverage);
	} else if (debug_mode == 14) {
		proof_color = vec3(mask, water_body_gate, visible_water_gate);
	}

	float camera_depth = camera_water_level - cam_pos.y;
	float underwater_view_mask = camera_underwater ? 1.0 : 0.0;
	vec3 underwater_color = scene_color.rgb;
	WobbleSceneSample wobble_sample;
	wobble_sample.color = scene_color.rgb;
	wobble_sample.guard = 0.0;
	wobble_sample.status = 0.0;
	wobble_sample.offset = 0.0;
	wobble_sample.uv = uv;
	vec2 wobble_offset = vec2(0.0);
	if (underwater_view_mask > 0.001 && underwater_any_enabled) {
		bool needs_surface_normal = snell_enabled || wobble_enabled;
		float surface_dist = water_ray_hit ? length(analytic_water_pos - cam_pos) : 8.0;
		SnellSample snell = compute_snell_sample(cam_pos, view_dir, analytic_water_pos, water_ray_hit, camera_depth);
		vec3 surface_normal = (needs_surface_normal && snell.valid > 0.5) ? snell.surface_normal : vec3(0.0, 1.0, 0.0);
		float snell_surface_visibility = 1.0 - foreground_occludes_water_surface(
			main_depth_present,
			main_world_pos,
			cam_pos,
			water_ray_hit,
			analytic_water_pos
		);
		float snell_window = (snell_enabled ? snell.window : 0.0) * snell_surface_visibility;
		float snell_reflection = (snell_enabled && snell.valid > 0.5 ? 1.0 - snell.window : 0.0) * snell_surface_visibility;
		float up_dot = snell.valid > 0.5 ? snell.cos_theta : max(view_dir.y, 0.0);
		float scene_dist = main_depth_present ? length(main_world_pos - cam_pos) : min(surface_dist + 55.0, 95.0);
		float lens_focal_dist = clamp(max(camera_depth, 0.0) + 0.85, 0.85, 3.0);
		vec3 wobble_focal_world = water_ray_hit ? analytic_water_pos : cam_pos + view_dir * lens_focal_dist;
		vec2 wobble_xz = (snell.valid > 0.5) ? snell.surface_pos.xz : wobble_focal_world.xz;
		vec3 optical_normal = needs_surface_normal ? water_optical_normal_at(wobble_xz, cam_pos) : surface_normal;
		vec3 normal_view = normalize((state.view * vec4(optical_normal, 0.0)).xyz);
		float wobble_meters = 0.035 + 0.075 * smoothstep(0.0, 0.90, up_dot);
		wobble_meters *= mix(0.65, 1.0, smoothstep(0.80, 9.0, surface_dist));
		wobble_offset = projected_wobble_uv_offset(wobble_focal_world, normal_view, wobble_meters);
		float camera_depth_guard = smoothstep(WOBBLE_MIN_CAMERA_DEPTH_M, WOBBLE_FULL_CAMERA_DEPTH_M, max(camera_depth, 0.0));
		float wobble_pre_guard = wobble_enabled
			? underwater_view_mask * camera_depth_guard * water_body_gate
			: 0.0;
		wobble_sample = guarded_underwater_scene_sample(
			uv,
			wobble_offset,
			main_depth_present ? main_world_pos : fallback_world_pos,
			cam_pos,
			wobble_pre_guard,
			scene_color.rgb
		);
		vec3 wobbled_scene = mix(scene_color.rgb, wobble_sample.color, clamp(wobble_sample.guard, 0.0, 1.0));
		vec3 underwater_target = main_depth_present
			? main_world_pos
			: (water_ray_hit ? analytic_water_pos : fallback_world_pos);
		OpticalSegment underwater_segment = compute_optical_segment(cam_pos, underwater_target, cam_pos);
		float water_travel = underwater_segment.valid > 0.001
			? underwater_segment.path_length_m
			: max(camera_depth, 0.0);
		if (underwater_segment.valid <= 0.001 && main_depth_present) {
			WaterSurfaceContractSample target_surface = water_surface_query(underwater_target, cam_pos, true, true);
			if (target_surface.body_gate > 0.001 && target_surface.depth > OPTICAL_SURFACE_EPS) {
				water_travel = length(underwater_target - cam_pos);
			}
		}
		MediumSample underwater_medium = apply_water_medium(wobbled_scene, tint, sigma, water_travel);
		float underwater_fog = underwater_medium.fog;
		underwater_color = absorption_enabled
			? underwater_medium.color
			: wobbled_scene;
		if (snell_reflection > 0.001) {
			vec3 ceiling_tint = mix(tint * 1.45, scene_color.rgb, 0.18);
			underwater_color = mix(underwater_color, ceiling_tint, snell_reflection * 0.32);
		}
		float particles = particles_enabled ? compute_underwater_particles(uv, cam_pos, view_dir, max(scene_dist, surface_dist + 12.0), max(camera_depth, 0.0)) : 0.0;
		underwater_color += particles * mix(vec3(0.58, 0.82, 0.78), vec3(0.95, 1.0, 0.92), underwater_fog) * 0.58;
		float underwater_caustic_depth = main_depth_present
			? max(get_dynamic_water_level(main_world_pos.xz, cam_pos, true, true) - main_world_pos.y, 0.0)
			: 0.0;
		float underwater_caustic_gate = (main_depth_present ? water_body_gate : 0.0) * underwater_view_mask;
		underwater_color += caustics_enabled
			? compute_receiver_caustics(main_world_pos, cam_pos, underwater_color, underwater_caustic_depth, underwater_caustic_gate) * 0.70
			: vec3(0.0);
		if (snell_enabled && snell.valid > 0.5 && snell_window > 0.001) {
			vec3 atmosphere = sample_atmosphere_color(uv, tint * 1.24, cam_pos, snell.air_dir, snell.surface_pos);
			OpticalSegment window_segment = compute_optical_segment(cam_pos, snell.surface_pos, cam_pos);
			float water_window_path = window_segment.valid > 0.001
				? window_segment.path_length_m
				: max(camera_depth, 0.0);
			MediumSample window_medium = apply_water_medium(atmosphere, tint, sigma, water_window_path, 0.40);
			float window_visibility = absorption_enabled ? clamp(luminance(window_medium.transmittance), 0.0, 1.0) : 1.0;
			float window_strength = snell_window * window_visibility;
			vec3 atmospheric_window = absorption_enabled ? window_medium.color : atmosphere;
			underwater_color = mix(underwater_color, atmospheric_window, clamp(window_strength, 0.0, 0.90));
		}
		float dither = interleaved_gradient_noise(vec2(pixel));
		underwater_color += vec3(dither * 2.0 - 1.0) / 255.0;
	}
	if (debug_mode == 15) {
		float wobble_accepted = wobble_sample.status > 8.5 ? 1.0 : 0.0;
		float wobble_rejected = (wobble_enabled && underwater_view_mask > 0.001 && length(wobble_offset) > 1e-6 && wobble_accepted < 0.5) ? 1.0 : 0.0;
		proof_color = vec3(wobble_rejected, wobble_accepted, clamp(wobble_sample.guard, 0.0, 1.0));
	}

	bool receiver_refraction_debug = debug_mode == 5 || debug_mode == 6;
	float debug_strength = (debug_mode >= 5 || pipeline_debug) ? 1.0 : probe_strength;
	float debug_mask = phase2_debug
		? 1.0
		: receiver_refraction_debug
		? mask
		: max(receiver_mask, receiver_refraction_gate);
	if (debug_mode == 15) {
		debug_mask = underwater_view_mask;
	}
	float receiver_replace_strength = camera_underwater
		? 0.0
		: clamp(blend_factor * mask, 0.0, RECEIVER_REFRACTION_REPLACE_OPACITY);
	float strength = pipeline_debug
		? 1.0
		: debug_mode == 0
		? receiver_replace_strength
		: clamp(debug_strength * blend_factor * debug_mask, 0.0, 1.0);
	vec3 output_color = scene_color.rgb;
	output_color = mix(output_color, proof_color, strength);
	if (debug_mode == 0 && underwater_view_mask > 0.001 && underwater_any_enabled) {
		output_color = mix(output_color, underwater_color, clamp(blend_factor * underwater_view_mask, 0.0, 0.96));
	}
	imageStore(color_image, pixel, vec4(output_color, scene_color.a));
}
