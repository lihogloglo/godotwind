#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_tex;
layout(set = 0, binding = 2) uniform sampler2D source_color_tex;
layout(set = 0, binding = 4) uniform sampler2DArray displacement_tex;
layout(set = 0, binding = 5) uniform sampler2D shore_mask_tex;
layout(set = 0, binding = 6) uniform sampler2D caustics_noise_tex;
layout(set = 0, binding = 7) uniform sampler2D water_body_atlas_tex;

#define MAX_CASCADES 8

layout(std430, set = 0, binding = 3) readonly buffer UnderwaterState {
	mat4 inv_projection;
	mat4 inv_view;
	vec4 map_scales[MAX_CASCADES];
	vec4 shore_mask_bounds;
	vec4 shore_params0; // x=fade, y=amp, z=freq, w=speed
	vec4 shore_params1; // x=steep, yzw=reserved
	vec4 water_tint; // rgb=medium asymptote, a=caustics strength
	vec4 water_body_atlas_bounds; // x=min_x, y=min_z, z=size_x, w=size_z
	vec4 water_body_atlas_params; // x=available, yzw=reserved
} state;

layout(push_constant, std430) uniform Params {
	vec4 screen; // x=width, y=height, z=time, w=blend
	vec4 water; // x=sea_level, y=max_path_m, z=camera_water_level, w=wobble_strength
	vec4 sigma_debug; // xyz=absorption sigma, w=debug mode
	vec4 flags; // x=absorption, y=wobble, z=source_valid, w=snell
	vec4 surface; // x=wave_scale, y=cascade_count, z=surface_sample_enabled, w=caustics
	vec4 sun; // xyz=toward sun, w=visibility
} pc;

#define screen_w pc.screen.x
#define screen_h pc.screen.y
#define TIME pc.screen.z
#define blend_factor pc.screen.w
#define sea_level pc.water.x
#define max_path_m pc.water.y
#define camera_water_level_cached pc.water.z
#define wobble_strength pc.water.w
#define debug_mode int(pc.sigma_debug.w + 0.5)
#define absorption_enabled (pc.flags.x > 0.5)
#define wobble_enabled (pc.flags.y > 0.5)
#define source_valid (pc.flags.z > 0.5)
#define snell_enabled (pc.flags.w > 0.5)
#define wave_scale pc.surface.x
#define cascade_count int(pc.surface.y)
#define surface_sample_enabled (pc.surface.z > 0.5)
#define caustics_enabled (pc.surface.w > 0.5)
#define sun_visibility clamp(pc.sun.w, 0.0, 1.0)

#include "res://src/core/shaders/compute/water_surface_contract.glslinc"

const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);
const float AIR_IOR = 1.000293;
const float WATER_IOR = 1.3330;
const float WATER_TO_AIR_ETA = WATER_IOR / AIR_IOR;
const float SNELL_EDGE_SIN_WIDTH = 0.030;
const float SNELL_WAVE_NORMAL_SHALLOW_WEIGHT = 0.16;
const float SNELL_WAVE_NORMAL_DEEP_WEIGHT = 0.36;
const float CAUSTICS_SPEED = 0.10;
const float CAUSTICS_POWER = 2.0;
const float CAUSTICS_CHROMA_SPLIT = 0.002;
const float CAUSTICS_LUMA_MASK_STRENGTH = 0.22;
const float CAUSTICS_LUMA_LOW = 0.00560224;
const float CAUSTICS_LUMA_HIGH = 0.10559;

struct SnellSample {
	float window;
	float cos_theta;
	float valid;
	float surface_t;
	vec3 surface_normal;
	vec3 surface_pos;
	vec3 air_dir;
};

vec3 safe_sun_direction() {
	return dot(pc.sun.xyz, pc.sun.xyz) > 1e-6 ? normalize(pc.sun.xyz) : vec3(0.0, 1.0, 0.0);
}

vec3 get_world_position(vec2 uv, float depth) {
	vec4 clip_pos = vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec4 view_pos = state.inv_projection * clip_pos;
	view_pos.xyz /= view_pos.w;
	vec4 world_pos = state.inv_view * vec4(view_pos.xyz, 1.0);
	return world_pos.xyz;
}

vec3 get_world_ray(vec2 uv) {
	vec4 clip_pos = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
	vec4 view_pos = state.inv_projection * clip_pos;
	vec3 view_dir = normalize(view_pos.xyz / view_pos.w);
	return normalize((state.inv_view * vec4(view_dir, 0.0)).xyz);
}

vec4 sample_water_body_atlas(vec2 world_xz) {
	if (state.water_body_atlas_params.x <= 0.5 || state.water_body_atlas_bounds.z <= 0.0 || state.water_body_atlas_bounds.w <= 0.0) {
		return vec4(0.0);
	}
	vec2 atlas_uv = (world_xz - state.water_body_atlas_bounds.xy) / state.water_body_atlas_bounds.zw;
	if (atlas_uv.x < 0.0 || atlas_uv.x > 1.0 || atlas_uv.y < 0.0 || atlas_uv.y > 1.0) {
		return vec4(0.0);
	}
	return textureLod(water_body_atlas_tex, atlas_uv, 0.0);
}

float water_body_atlas_gate(vec2 world_xz) {
	return smoothstep(0.015, 0.12, clamp(sample_water_body_atlas(world_xz).r, 0.0, 1.0));
}

float dynamic_water_level(vec2 world_xz, vec3 cam_pos) {
	vec4 atlas = sample_water_body_atlas(world_xz);
	float atlas_gate = smoothstep(0.015, 0.12, clamp(atlas.r, 0.0, 1.0));
	if (atlas_gate > 0.001) {
		return atlas.g;
	}
	if (!surface_sample_enabled) {
		return camera_water_level_cached;
	}
	return get_dynamic_water_level(world_xz, cam_pos, true, true);
}

float safe_surface_exit_distance(vec3 cam_pos, vec3 ray_dir, float camera_surface_level) {
	if (ray_dir.y <= 0.015) {
		return max_path_m;
	}
	float t = clamp((camera_surface_level - cam_pos.y) / max(ray_dir.y, 0.015), 0.0, max_path_m);
	for (int i = 0; i < 4; i++) {
		vec3 probe_pos = cam_pos + ray_dir * t;
		float water_y = dynamic_water_level(probe_pos.xz, cam_pos);
		t = clamp((water_y - cam_pos.y) / max(ray_dir.y, 0.015), 0.0, max_path_m);
	}
	return t;
}

float safe_surface_entry_distance(vec3 cam_pos, vec3 ray_dir, vec3 hit_pos, bool hit_valid, float camera_surface_level) {
	if (ray_dir.y >= -0.015) {
		return max_path_m;
	}
	float max_t = hit_valid ? clamp(length(hit_pos - cam_pos), 0.0, max_path_m) : max_path_m;
	float t = clamp((camera_surface_level - cam_pos.y) / min(ray_dir.y, -0.015), 0.0, max_t);
	for (int i = 0; i < 4; i++) {
		vec3 probe_pos = cam_pos + ray_dir * t;
		float water_y = dynamic_water_level(probe_pos.xz, cam_pos);
		t = clamp((water_y - cam_pos.y) / min(ray_dir.y, -0.015), 0.0, max_t);
	}
	return t;
}

float water_path_length(vec3 cam_pos, vec3 ray_dir, vec3 hit_pos, bool hit_valid, float camera_surface_level) {
	bool camera_underwater = cam_pos.y < camera_surface_level - 0.02;
	if (!camera_underwater) {
		if (!hit_valid) {
			return 0.0;
		}
		float hit_water_level = dynamic_water_level(hit_pos.xz, cam_pos);
		if (hit_pos.y > hit_water_level + 0.03) {
			return 0.0;
		}
		float hit_t = clamp(length(hit_pos - cam_pos), 0.0, max_path_m);
		float entry_t = safe_surface_entry_distance(cam_pos, ray_dir, hit_pos, true, camera_surface_level);
		return clamp(hit_t - entry_t, 0.0, max_path_m);
	}
	if (!hit_valid) {
		return safe_surface_exit_distance(cam_pos, ray_dir, camera_surface_level);
	}
	float hit_water_level = dynamic_water_level(hit_pos.xz, cam_pos);
	if (hit_pos.y <= hit_water_level + 0.03) {
		return clamp(length(hit_pos - cam_pos), 0.0, max_path_m);
	}
	return safe_surface_exit_distance(cam_pos, ray_dir, camera_surface_level);
}

float wave_hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

vec2 wobble_offset(vec2 uv, float path_len) {
	float depth_gate = smoothstep(0.15, 2.0, path_len);
	float a = sin((uv.x * 42.0 + uv.y * 17.0) + TIME * 1.9);
	float b = sin((uv.x * -23.0 + uv.y * 38.0) + TIME * 1.3 + wave_hash(floor(uv * 64.0)));
	return vec2(a, b) * wobble_strength * depth_gate;
}

vec3 water_normal_at(vec2 world_xz, vec3 cam_pos) {
	float step_m = 0.65;
	float h_l = dynamic_water_level(world_xz - vec2(step_m, 0.0), cam_pos);
	float h_r = dynamic_water_level(world_xz + vec2(step_m, 0.0), cam_pos);
	float h_d = dynamic_water_level(world_xz - vec2(0.0, step_m), cam_pos);
	float h_u = dynamic_water_level(world_xz + vec2(0.0, step_m), cam_pos);
	return normalize(vec3(h_l - h_r, step_m * 2.0, h_d - h_u));
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

SnellSample compute_snell_sample(vec3 cam_pos, vec3 ray_dir, float camera_surface_level, float camera_depth, bool hit_valid, vec3 hit_pos) {
	SnellSample result;
	result.window = 0.0;
	result.cos_theta = 0.0;
	result.valid = 0.0;
	result.surface_t = 0.0;
	result.surface_normal = vec3(0.0, 1.0, 0.0);
	result.surface_pos = cam_pos;
	result.air_dir = vec3(0.0, 1.0, 0.0);

	if (!snell_enabled || ray_dir.y <= 0.015 || camera_depth <= 0.05) {
		return result;
	}

	float surface_t = safe_surface_exit_distance(cam_pos, ray_dir, camera_surface_level);
	if (surface_t <= 0.02 || surface_t >= max_path_m - 0.02) {
		return result;
	}
	float hit_t = hit_valid ? length(hit_pos - cam_pos) : max_path_m;
	if (hit_valid && hit_t < surface_t - 0.12) {
		return result;
	}

	vec3 surface_pos = cam_pos + ray_dir * surface_t;
	vec3 surface_normal = water_normal_at(surface_pos.xz, cam_pos);
	vec3 mask_normal = snell_mask_normal(surface_normal, camera_depth);
	float wave_cos_theta = clamp(dot(ray_dir, mask_normal), 0.0, 1.0);
	if (wave_cos_theta <= 0.0) {
		return result;
	}

	vec3 air_dir = refract_water_to_air(ray_dir, mask_normal);
	if (dot(air_dir, air_dir) <= 1e-6) {
		return result;
	}

	result.window = snells_window(mask_normal, ray_dir, WATER_TO_AIR_ETA);
	result.cos_theta = wave_cos_theta;
	result.valid = 1.0;
	result.surface_t = surface_t;
	result.surface_normal = surface_normal;
	result.surface_pos = surface_pos;
	result.air_dir = air_dir;
	return result;
}

vec3 exterior_atmosphere_color(vec3 air_dir, vec3 fallback) {
	vec3 dir = dot(air_dir, air_dir) > 1e-6 ? normalize(air_dir) : vec3(0.0, 1.0, 0.0);
	float up = clamp(dir.y, 0.0, 1.0);
	vec3 horizon = vec3(0.70, 0.82, 0.92);
	vec3 zenith = vec3(0.30, 0.48, 0.76);
	vec3 sky = mix(horizon, zenith, smoothstep(0.06, 0.92, up));

	vec3 sun_dir = safe_sun_direction();
	float sun_disk = pow(max(dot(dir, sun_dir), 0.0), 320.0);
	float sun_glow = pow(max(dot(dir, sun_dir), 0.0), 18.0) * smoothstep(0.02, 0.28, sun_dir.y);
	vec3 sun_color = vec3(1.0, 0.86, 0.58) * (sun_disk * 2.3 + sun_glow * 0.18) * sun_visibility;

	float air_valid = smoothstep(-0.02, 0.10, dir.y);
	return mix(fallback, sky + sun_color, air_valid);
}

vec2 caustics_panner(vec2 uv, float speed, float tiling) {
	return vec2(TIME * speed, 0.0) + uv * tiling;
}

vec3 caustics_aberration_sample(vec2 uv, float split) {
	vec2 uv1 = uv + vec2(split, split);
	vec2 uv2 = uv + vec2(split, -split);
	vec2 uv3 = uv + vec2(-split, -split);
	float r = textureLod(caustics_noise_tex, uv1, 0.0).r;
	float g = textureLod(caustics_noise_tex, uv2, 0.0).r;
	float b = textureLod(caustics_noise_tex, uv3, 0.0).r;
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

vec3 underwater_caustics(
	vec3 world_pos,
	vec3 cam_pos,
	vec3 base_color,
	vec3 sigma,
	float view_path_len,
	float water_depth,
	bool hit_valid
) {
	float strength = state.water_tint.a;
	if (!caustics_enabled || !hit_valid || strength <= 0.001 || water_depth <= 0.08) {
		return vec3(0.0);
	}

	vec3 sun_dir = safe_sun_direction();
	float sun_gate = smoothstep(0.04, 0.30, sun_dir.y) * sun_visibility;
	if (sun_gate <= 0.001) {
		return vec3(0.0);
	}

	float camera_dist = length(world_pos - cam_pos);
	float dist_gate = 1.0 - smoothstep(55.0, 155.0, camera_dist);
	float depth_gate = smoothstep(0.12, 0.85, water_depth) * (1.0 - smoothstep(24.0, 70.0, water_depth));
	if (dist_gate <= 0.001 || depth_gate <= 0.001) {
		return vec3(0.0);
	}

	float sun_height = max(sun_dir.y, 0.05);
	float sun_water_path = water_depth / sun_height;
	vec3 optical_gate = exp(-max(sigma, vec3(0.0)) * max(view_path_len + sun_water_path, 0.0));
	vec2 surface_xz = world_pos.xz + sun_dir.xz * (water_depth / sun_height);
	vec3 surface_normal = water_normal_at(surface_xz, cam_pos);
	float slope_focus = clamp(length(surface_normal.xz) * 2.6, 0.0, 1.0);
	mat3 light_basis = make_light_projection_basis(sun_dir);
	vec2 caustic_uv = (light_basis * vec3(surface_xz.x, world_pos.y, surface_xz.y)).xy;
	float caustic_scale = dominant_caustics_scale();
	vec2 uv1 = caustics_panner(caustic_uv, 0.75 * CAUSTICS_SPEED, 1.0 / caustic_scale);
	vec2 uv2 = caustics_panner(caustic_uv, CAUSTICS_SPEED, -1.0 / caustic_scale);
	vec3 caus1 = pow(caustics_aberration_sample(uv1, CAUSTICS_CHROMA_SPLIT), vec3(CAUSTICS_POWER));
	vec3 caus2 = pow(caustics_aberration_sample(uv2, CAUSTICS_CHROMA_SPLIT), vec3(CAUSTICS_POWER));
	vec3 caustic = min(caus1, caus2);

	float scene_luma = clamp(dot(base_color, LUMA), 0.0, 1.0);
	float luma_ramp = smoothstep(CAUSTICS_LUMA_LOW, CAUSTICS_LUMA_HIGH, scene_luma);
	float luma_gate = mix(1.0, luma_ramp, CAUSTICS_LUMA_MASK_STRENGTH);
	return caustic * vec3(0.42, 0.78, 1.0) * optical_gate * mix(0.45, 1.15, slope_focus)
		* depth_gate * dist_gate * luma_gate * sun_gate * strength * 0.55;
}

float wobble_sample_guard(
	vec2 uv,
	vec3 cam_pos,
	float base_depth,
	float base_path,
	out vec2 shifted_uv,
	out vec3 shifted_source,
	out float shifted_path
) {
	shifted_uv = clamp(uv + wobble_offset(uv, base_path), vec2(0.001), vec2(0.999));
	shifted_source = texture(source_color_tex, shifted_uv).rgb;
	shifted_path = base_path;
	float shifted_depth = texture(depth_tex, shifted_uv).r;
	bool base_valid = base_depth > 0.0001;
	bool shifted_valid = shifted_depth > 0.0001;
	if (!base_valid || !shifted_valid) {
		return base_valid == shifted_valid ? 1.0 : 0.0;
	}

	vec3 base_pos = get_world_position(uv, base_depth);
	vec3 shifted_pos = get_world_position(shifted_uv, shifted_depth);
	vec3 shifted_ray = get_world_ray(shifted_uv);
	float shifted_camera_surface = dynamic_water_level(cam_pos.xz, cam_pos);
	shifted_path = water_path_length(cam_pos, shifted_ray, shifted_pos, true, shifted_camera_surface);
	float path_guard = 1.0 - smoothstep(max(1.0, base_path * 0.20), max(2.0, base_path * 0.45), abs(shifted_path - base_path));
	float base_hit_dist = distance(base_pos, cam_pos);
	float shifted_hit_dist = distance(shifted_pos, cam_pos);
	float hit_delta = abs(shifted_hit_dist - base_hit_dist);
	float hit_guard = 1.0 - smoothstep(0.08, max(0.35, base_hit_dist * 0.03), hit_delta);
	float guard = path_guard * hit_guard;
	if (guard <= 0.02) {
		return 0.0;
	}
	return guard;
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (pixel.x >= int(screen_w) || pixel.y >= int(screen_h)) {
		return;
	}

	vec2 uv = (vec2(pixel) + vec2(0.5)) / vec2(screen_w, screen_h);
	vec4 original = imageLoad(color_image, pixel);
	vec3 cam_pos = state.inv_view[3].xyz;
	float camera_surface_level = dynamic_water_level(cam_pos.xz, cam_pos);
	bool camera_underwater = cam_pos.y < camera_surface_level - 0.02;

	float depth = texture(depth_tex, uv).r;
	bool hit_valid = depth > 0.0001;
	vec3 ray_dir = get_world_ray(uv);
	vec3 hit_pos = hit_valid ? get_world_position(uv, depth) : cam_pos + ray_dir * max_path_m;
	float path_len = water_path_length(cam_pos, ray_dir, hit_pos, hit_valid, camera_surface_level);
	if (!camera_underwater && path_len <= 0.015 && debug_mode == 0) {
		return;
	}
	float hit_water_level = dynamic_water_level(hit_pos.xz, cam_pos);
	bool underwater_hit = hit_valid && hit_pos.y <= hit_water_level + 0.03;

	vec3 source = original.rgb;
	vec2 shifted_uv = uv;
	vec3 shifted_source = original.rgb;
	float shifted_path = path_len;
	float wobble_guard_value = 0.0;
	float wobble_mix_value = 0.0;
	bool wobble_debug = debug_mode == 4 || debug_mode == 5;
	bool has_wobble_sample = false;
	if (source_valid && (wobble_enabled || wobble_debug) && wobble_strength > 0.0001) {
		wobble_guard_value = wobble_sample_guard(uv, cam_pos, depth, path_len, shifted_uv, shifted_source, shifted_path);
		wobble_mix_value = wobble_guard_value >= 0.5 ? 1.0 : 0.0;
		has_wobble_sample = true;
		if (wobble_enabled) {
			source = mix(original.rgb, shifted_source, wobble_mix_value);
		}
	}
	vec3 sigma = absorption_enabled ? pc.sigma_debug.xyz : vec3(0.0);
	vec3 transmittance = exp(-sigma * path_len);
	vec3 tint = max(state.water_tint.rgb, vec3(0.0));
	vec3 medium = source * transmittance + tint * (vec3(1.0) - transmittance);
	float camera_depth = max(camera_surface_level - cam_pos.y, 0.0);
	SnellSample snell = compute_snell_sample(cam_pos, ray_dir, camera_surface_level, camera_depth, hit_valid, hit_pos);
	if (snell_enabled && snell.valid > 0.5) {
		float snell_reflection = 1.0 - snell.window;
		if (snell_reflection > 0.001) {
			vec3 ceiling_tint = mix(tint * 1.45, source, 0.18);
			medium = mix(medium, ceiling_tint, snell_reflection * 0.28);
		}
		if (snell.window > 0.001) {
			vec3 atmosphere = exterior_atmosphere_color(snell.air_dir, tint * 1.24);
			vec3 window_transmittance = exp(-sigma * max(snell.surface_t, camera_depth));
			vec3 atmospheric_window = absorption_enabled
				? atmosphere * window_transmittance + tint * (vec3(1.0) - window_transmittance)
				: atmosphere;
			float window_visibility = absorption_enabled ? clamp(dot(window_transmittance, LUMA), 0.0, 1.0) : 1.0;
			float window_strength = clamp(snell.window * window_visibility, 0.0, 0.90);
			medium = mix(medium, atmospheric_window, window_strength);
		}
	}
	if (caustics_enabled) {
		float target_water_depth = hit_valid ? max(hit_water_level - hit_pos.y, 0.0) : 0.0;
		medium += underwater_caustics(hit_pos, cam_pos, medium, sigma, path_len, target_water_depth, hit_valid && underwater_hit);
	}
	vec3 final_color = mix(original.rgb, medium, clamp(blend_factor, 0.0, 1.0));

	if (debug_mode > 0) {
		if (debug_mode == 1) {
			float t = clamp(path_len / max(max_path_m, 1.0), 0.0, 1.0);
			final_color = vec3(t, t * 0.65, 1.0 - t);
		} else if (debug_mode == 2) {
			final_color = transmittance;
		} else if (debug_mode == 3) {
			final_color = vec3(camera_underwater ? 0.0 : 1.0, underwater_hit ? 1.0 : 0.0, hit_valid ? 0.0 : 1.0);
		} else if (debug_mode == 4) {
			float delta = has_wobble_sample ? clamp(length(shifted_source - original.rgb) * 3.0, 0.0, 1.0) : 0.0;
			final_color = vec3(delta, delta * 0.35, source_valid ? 0.0 : 1.0);
		} else if (debug_mode == 5) {
			final_color = has_wobble_sample
				? vec3(1.0 - wobble_mix_value, wobble_mix_value, wobble_guard_value * 0.25)
				: vec3(0.15, 0.0, source_valid ? 0.0 : 1.0);
		}
	}

	imageStore(color_image, pixel, vec4(final_color, original.a));
}
