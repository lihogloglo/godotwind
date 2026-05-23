#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_tex;
layout(set = 0, binding = 2) uniform sampler2D source_color_tex;
layout(set = 0, binding = 4) uniform sampler2DArray displacement_tex;
layout(set = 0, binding = 5) uniform sampler2D shore_mask_tex;

#define MAX_CASCADES 8

layout(std430, set = 0, binding = 3) readonly buffer UnderwaterState {
	mat4 inv_projection;
	mat4 inv_view;
	vec4 map_scales[MAX_CASCADES];
	vec4 shore_mask_bounds;
	vec4 shore_params0; // x=fade, y=amp, z=freq, w=speed
	vec4 shore_params1; // x=steep, yzw=reserved
	vec4 water_tint; // rgb=medium asymptote
} state;

layout(push_constant, std430) uniform Params {
	vec4 screen; // x=width, y=height, z=time, w=blend
	vec4 water; // x=sea_level, y=max_path_m, z=camera_water_level, w=wobble_strength
	vec4 sigma_debug; // xyz=absorption sigma, w=debug mode
	vec4 flags; // x=absorption, y=wobble, z=source_valid, w=reserved
	vec4 surface; // x=wave_scale, y=cascade_count, z=surface_sample_enabled, w=reserved
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
#define wave_scale pc.surface.x
#define cascade_count int(pc.surface.y)
#define surface_sample_enabled (pc.surface.z > 0.5)

#include "res://src/core/shaders/compute/water_surface_contract.glslinc"

const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

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

float dynamic_water_level(vec2 world_xz, vec3 cam_pos) {
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

float water_path_length(vec3 cam_pos, vec3 ray_dir, vec3 hit_pos, bool hit_valid, float camera_surface_level) {
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
	if (!camera_underwater && debug_mode == 0) {
		return;
	}

	float depth = texture(depth_tex, uv).r;
	bool hit_valid = depth > 0.0001;
	vec3 ray_dir = get_world_ray(uv);
	vec3 hit_pos = hit_valid ? get_world_position(uv, depth) : cam_pos + ray_dir * max_path_m;
	float path_len = water_path_length(cam_pos, ray_dir, hit_pos, hit_valid, camera_surface_level);
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
