#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_tex;
layout(set = 0, binding = 2) uniform sampler2D source_color_tex;
layout(set = 0, binding = 3) uniform sampler2D source_depth_tex;
layout(set = 0, binding = 5) uniform sampler2DArray displacement_tex;
layout(set = 0, binding = 6) uniform sampler2D shore_mask_tex;
layout(std430, set = 0, binding = 7) buffer DebugStatsBuffer {
	uint counters[16];
} debug_stats;

#define MAX_CASCADES 8

layout(std430, set = 0, binding = 4) readonly buffer StateBuffer {
	mat4 inv_projection;
	mat4 inv_view;
	mat4 projection;
	mat4 view;
	mat4 source_inv_projection;
	mat4 source_inv_view;
	mat4 source_projection;
	mat4 source_view;
	vec4 map_scales[MAX_CASCADES];
	vec4 shore_mask_bounds;
	vec4 shore_params0;
	vec4 shore_params1;
	vec4 medium_params;
} state;

layout(push_constant, std430) uniform Params {
	vec4 screen; // x=width, y=height, z=time, w=blend
	vec4 water; // x=sea_level, y=wave_scale, z=cascade_count, w=refraction_strength
	vec4 optics; // xyz=extinction sigma, w=max refracted travel
	vec4 source; // x=color valid, y=depth valid, z=fresh, w=debug mode
	vec4 options; // x=edge guard, yzw=reserved
} pc;

#define TIME pc.screen.z
#define sea_level pc.water.x
#define wave_scale pc.water.y
#define cascade_count int(pc.water.z)
#define refraction_strength pc.water.w
#define source_color_valid (pc.source.x > 0.5)
#define source_depth_valid (pc.source.y > 0.5)
#define source_fresh (pc.source.z > 0.5)
#define debug_mode int(pc.source.w)
#define edge_guard_strength pc.options.x
#define debug_stats_enabled (pc.options.y > 0.5)

#include "water_surface_contract.glslinc"

const float AIR_TO_WATER_ETA = 1.0 / 1.333;
const float WATER_DEPTH_MATCH_MIN_EPS_M = 0.18;
const float WATER_DEPTH_MATCH_REL_EPS = 0.0015;
const float WATER_DEPTH_MATCH_MAX_EPS_M = 0.75;
const float SUBMERGED_EPS_M = 0.04;
const float FAR_DEPTH_EPS = 0.0001;
const float VISIBLE_WATER_EPS = 0.001;
const float SHORE_VERTICAL_ENVELOPE_SCALE = 1.45;
const float COARSE_GATE_RELAXATION = 0.10;
const int RECEIVER_RAY_STEPS = 8;
const float RECEIVER_RAY_START_M = 0.12;
const float RECEIVER_RAY_MIN_MAX_PATH_M = 1.0;
const float RECEIVER_RAY_ABOVE_SURFACE_EPS_M = 0.015;
const float RECEIVER_RAY_STEP_EXPONENT = 1.25;
const float RECEIVER_RAY_HIT_RADIUS_MIN_M = 0.22;
const float RECEIVER_RAY_HIT_RADIUS_REL = 0.028;
const float RECEIVER_RAY_STEP_RADIUS_REL = 0.018;
// Mask-collapse pixels should soften the invalid-offset boundary without restoring full refraction.
const float MASK_REJECT_COLLAPSE_BLEND = 0.70;
const float MASK_EDGE_OWNERSHIP_FADE = 0.20;

struct ReceiverSolveSample {
	float valid;
	float status;
	vec2 source_uv;
	vec2 main_uv;
	vec3 world_pos;
	float path_length;
};

bool uv_in_screen(vec2 uv) {
	return all(greaterThan(uv, vec2(0.0))) && all(lessThan(uv, vec2(1.0)));
}

void add_debug_stat(uint index) {
	if (debug_stats_enabled) {
		atomicAdd(debug_stats.counters[index], 1u);
	}
}

vec3 world_from_depth_with_matrices(vec2 uv, float depth, mat4 inv_projection, mat4 inv_view) {
	vec4 clip_pos = vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec4 view_pos = inv_projection * clip_pos;
	view_pos.xyz /= view_pos.w;
	vec4 world_pos = inv_view * vec4(view_pos.xyz, 1.0);
	return world_pos.xyz / world_pos.w;
}

vec3 main_world_from_depth(vec2 uv, float depth) {
	return world_from_depth_with_matrices(uv, depth, state.inv_projection, state.inv_view);
}

vec3 source_world_from_depth(vec2 uv, float depth) {
	return world_from_depth_with_matrices(uv, depth, state.source_inv_projection, state.source_inv_view);
}

vec2 uv_from_world_with_matrices(vec3 world_pos, mat4 projection, mat4 view, out bool valid) {
	vec4 view_pos = view * vec4(world_pos, 1.0);
	vec4 clip_pos = projection * view_pos;
	valid = clip_pos.w > 1e-5;
	if (!valid) {
		return vec2(0.0);
	}
	return clip_pos.xy / clip_pos.w * 0.5 + 0.5;
}

vec2 main_uv_from_world(vec3 world_pos, out bool valid) {
	return uv_from_world_with_matrices(world_pos, state.projection, state.view, valid);
}

vec2 source_uv_from_world(vec3 world_pos, out bool valid) {
	return uv_from_world_with_matrices(world_pos, state.source_projection, state.source_view, valid);
}

vec3 camera_position() {
	return state.inv_view[3].xyz;
}

float main_depth_at(vec2 uv) {
	return textureLod(depth_tex, uv, 0.0).r;
}

float source_depth_at(vec2 uv) {
	return textureLod(source_depth_tex, uv, 0.0).r;
}

float source_capture_scale() {
	if (!source_depth_valid) {
		return 1.0;
	}
	vec2 source_size = vec2(textureSize(source_depth_tex, 0));
	vec2 target_size = max(pc.screen.xy, vec2(1.0));
	return clamp(min(source_size.x / target_size.x, source_size.y / target_size.y), 0.0, 1.0);
}

bool fetch_source_depth_near(vec2 uv, out vec2 receiver_uv, out float depth) {
	receiver_uv = uv;
	depth = 0.0;
	if (!uv_in_screen(uv) || !source_depth_valid) {
		return false;
	}

	depth = source_depth_at(uv);
	if (depth > FAR_DEPTH_EPS) {
		return true;
	}

	if (source_capture_scale() < 0.49) {
		return false;
	}

	vec2 texel = 1.0 / vec2(textureSize(source_depth_tex, 0));
	vec2 offsets[8] = vec2[8](
		vec2(texel.x, 0.0),
		vec2(-texel.x, 0.0),
		vec2(0.0, texel.y),
		vec2(0.0, -texel.y),
		texel,
		-texel,
		vec2(texel.x, -texel.y),
		vec2(-texel.x, texel.y)
	);
	for (int i = 0; i < 8; i++) {
		vec2 candidate_uv = uv + offsets[i];
		if (!uv_in_screen(candidate_uv)) {
			continue;
		}
		float candidate_depth = source_depth_at(candidate_uv);
		if (candidate_depth > FAR_DEPTH_EPS) {
			receiver_uv = candidate_uv;
			depth = candidate_depth;
			return true;
		}
	}
	return false;
}

vec3 surface_normal_at(vec2 xz, vec3 cam_pos, float center_y) {
	float e = 0.45;
	float h_r = get_dynamic_water_level(xz + vec2(e, 0.0), cam_pos, true, true);
	float h_u = get_dynamic_water_level(xz + vec2(0.0, e), cam_pos, true, true);
	return normalize(vec3(center_y - h_r, e, center_y - h_u));
}

float water_depth_match_tolerance(float main_distance) {
	return clamp(
		max(WATER_DEPTH_MATCH_MIN_EPS_M, main_distance * WATER_DEPTH_MATCH_REL_EPS),
		WATER_DEPTH_MATCH_MIN_EPS_M,
		WATER_DEPTH_MATCH_MAX_EPS_M
	);
}

float water_contract_vertical_envelope() {
	float envelope = abs(state.shore_params0.y) * SHORE_VERTICAL_ENVELOPE_SCALE;
	int count = clamp(cascade_count, 0, MAX_CASCADES);
	for (int i = 0; i < MAX_CASCADES; i++) {
		if (i >= count) {
			break;
		}
		envelope += abs(state.map_scales[i].z) * abs(wave_scale);
	}
	return max(envelope, WATER_DEPTH_MATCH_MIN_EPS_M);
}

bool coarse_water_depth_gate(vec3 cam_pos, vec3 view_dir, float scene_distance) {
	float envelope = water_contract_vertical_envelope();
	float tolerance = water_depth_match_tolerance(scene_distance) + envelope * COARSE_GATE_RELAXATION;
	float min_y = sea_level - envelope - tolerance;
	float max_y = sea_level + envelope + tolerance;

	if (abs(view_dir.y) <= 1.0e-4) {
		float scene_y = cam_pos.y + view_dir.y * scene_distance;
		return scene_y >= min_y && scene_y <= max_y;
	}

	float t0 = (min_y - cam_pos.y) / view_dir.y;
	float t1 = (max_y - cam_pos.y) / view_dir.y;
	float t_min = min(t0, t1);
	float t_max = max(t0, t1);
	if (t_max <= 0.0) {
		return false;
	}
	return scene_distance >= max(0.0, t_min) - tolerance && scene_distance <= t_max + tolerance;
}

bool water_hit_from_ray(
	vec3 cam_pos,
	vec3 view_dir,
	float main_distance,
	out vec3 water_world,
	out float depth_delta,
	out float body_gate
) {
	depth_delta = 1.0e6;
	body_gate = 0.0;
	water_world = cam_pos;
	if (abs(view_dir.y) <= 1.0e-4) {
		return false;
	}

	float t = (sea_level - cam_pos.y) / view_dir.y;
	if (t <= 0.0) {
		return false;
	}

	for (int i = 0; i < 5; i++) {
		vec3 p = cam_pos + view_dir * t;
		float water_y = get_dynamic_water_level(p.xz, cam_pos, true, true);
		t = (water_y - cam_pos.y) / view_dir.y;
		if (t <= 0.0) {
			return false;
		}
	}

	water_world = cam_pos + view_dir * t;
	WaterSurfaceContractSample surface = water_surface_query(water_world, cam_pos, true, true);
	body_gate = surface.body_gate;
	if (body_gate <= 0.001) {
		return false;
	}

	depth_delta = abs(main_distance - t);
	return true;
}

ReceiverSolveSample invalid_receiver_sample(float status, vec2 uv, vec3 water_world) {
	ReceiverSolveSample result;
	result.valid = 0.0;
	result.status = status;
	result.source_uv = uv;
	result.main_uv = uv;
	result.world_pos = water_world;
	result.path_length = 0.0;
	return result;
}

ReceiverSolveSample direct_receiver_sample(vec2 uv, vec3 water_world) {
	vec2 receiver_uv = uv;
	float source_depth = 0.0;
	if (!fetch_source_depth_near(uv, receiver_uv, source_depth)) {
		return invalid_receiver_sample(5.0, uv, water_world);
	}

	vec3 source_world = source_world_from_depth(receiver_uv, source_depth);
	bool source_projected_valid = false;
	bool main_projected_valid = false;
	vec2 source_uv = source_uv_from_world(source_world, source_projected_valid);
	vec2 main_uv = main_uv_from_world(source_world, main_projected_valid);
	if (!source_projected_valid || !main_projected_valid || !uv_in_screen(source_uv) || !uv_in_screen(main_uv)) {
		return invalid_receiver_sample(4.0, uv, water_world);
	}

	ReceiverSolveSample result;
	result.valid = 1.0;
	result.status = 9.0;
	result.source_uv = source_uv;
	result.main_uv = main_uv;
	result.world_pos = source_world;
	result.path_length = max(length(source_world - water_world), RECEIVER_RAY_START_M);
	return result;
}

ReceiverSolveSample depth_guided_receiver_sample(
	vec2 uv,
	vec3 cam_pos,
	vec3 water_world,
	vec3 refr_dir,
	float edge_guard
) {
	if (!source_color_valid || !source_depth_valid || !source_fresh) {
		return invalid_receiver_sample(3.0, uv, water_world);
	}
	if (refraction_strength <= 0.001 || edge_guard <= 0.001) {
		return direct_receiver_sample(uv, water_world);
	}
	if (dot(refr_dir, refr_dir) <= 1e-7 || refr_dir.y >= -0.001) {
		return invalid_receiver_sample(4.0, uv, water_world);
	}

	float max_path = max(pc.optics.w, RECEIVER_RAY_MIN_MAX_PATH_M) * edge_guard;
	float reject_status = 5.0;

	vec2 direct_uv = uv;
	float direct_depth = 0.0;
	if (fetch_source_depth_near(uv, direct_uv, direct_depth)) {
		vec3 direct_world = source_world_from_depth(direct_uv, direct_depth);
		float direct_water_level = get_dynamic_water_level(direct_world.xz, cam_pos, true, true);
		if (direct_world.y < direct_water_level + RECEIVER_RAY_ABOVE_SURFACE_EPS_M) {
			vec3 direct_delta = direct_world - water_world;
			float direct_t = dot(direct_delta, refr_dir);
			if (direct_t >= RECEIVER_RAY_START_M && direct_t <= max_path) {
				vec3 direct_closest = water_world + refr_dir * direct_t;
				float direct_miss_distance = length(direct_world - direct_closest);
				float direct_hit_radius = max(RECEIVER_RAY_HIT_RADIUS_MIN_M, direct_t * RECEIVER_RAY_HIT_RADIUS_REL);
				if (direct_miss_distance <= direct_hit_radius) {
					bool direct_main_projected_valid = false;
					vec2 direct_main_uv = main_uv_from_world(direct_world, direct_main_projected_valid);
					if (direct_main_projected_valid && uv_in_screen(direct_main_uv)) {
						ReceiverSolveSample result;
						result.valid = 1.0;
						result.status = 9.0;
						result.source_uv = direct_uv;
						result.main_uv = direct_main_uv;
						result.world_pos = direct_world;
						result.path_length = max(direct_t, RECEIVER_RAY_START_M);
						return result;
					}
					reject_status = 4.0;
				} else {
					reject_status = 6.0;
				}
			} else {
				reject_status = 6.0;
			}
		} else {
			reject_status = 7.0;
		}
	}

	for (int i = 0; i < RECEIVER_RAY_STEPS; i++) {
		float step_t = (float(i) + 0.5) / float(RECEIVER_RAY_STEPS);
		float ray_t = mix(RECEIVER_RAY_START_M, max_path, pow(step_t, RECEIVER_RAY_STEP_EXPONENT));
		vec3 ray_world = water_world + refr_dir * ray_t;
		float ray_water_level = get_dynamic_water_level(ray_world.xz, cam_pos, true, true);
		if (ray_world.y > ray_water_level + 0.10) {
			reject_status = 7.0;
			continue;
		}

		bool source_projected_valid = false;
		vec2 refr_uv = source_uv_from_world(ray_world, source_projected_valid);
		if (!source_projected_valid || !uv_in_screen(refr_uv)) {
			reject_status = 4.0;
			continue;
		}

		vec2 receiver_uv = refr_uv;
		float receiver_depth = 0.0;
		if (!fetch_source_depth_near(refr_uv, receiver_uv, receiver_depth)) {
			reject_status = 5.0;
			continue;
		}

		vec3 sample_world = source_world_from_depth(receiver_uv, receiver_depth);
		float sample_water_level = get_dynamic_water_level(sample_world.xz, cam_pos, true, true);
		if (sample_world.y >= sample_water_level + RECEIVER_RAY_ABOVE_SURFACE_EPS_M) {
			reject_status = 7.0;
			continue;
		}

		vec3 receiver_delta = sample_world - water_world;
		float receiver_t = dot(receiver_delta, refr_dir);
		if (receiver_t < RECEIVER_RAY_START_M || receiver_t > max_path) {
			reject_status = 6.0;
			continue;
		}

		vec3 closest = water_world + refr_dir * receiver_t;
		float miss_distance = length(sample_world - closest);
		float depth_delta = abs(receiver_t - ray_t);
		float hit_radius = max(RECEIVER_RAY_HIT_RADIUS_MIN_M, receiver_t * RECEIVER_RAY_HIT_RADIUS_REL);
		float step_radius = max(max_path / float(RECEIVER_RAY_STEPS) * 1.35, receiver_t * RECEIVER_RAY_STEP_RADIUS_REL);
		if (miss_distance > hit_radius || depth_delta > step_radius) {
			reject_status = 6.0;
			continue;
		}

		bool main_projected_valid = false;
		vec2 main_uv = main_uv_from_world(sample_world, main_projected_valid);
		if (!main_projected_valid || !uv_in_screen(main_uv)) {
			reject_status = 4.0;
			continue;
		}

		ReceiverSolveSample result;
		result.valid = 1.0;
		result.status = 9.0;
		result.source_uv = receiver_uv;
		result.main_uv = main_uv;
		result.world_pos = sample_world;
		result.path_length = max(receiver_t, RECEIVER_RAY_START_M);
		return result;
	}

	return invalid_receiver_sample(reject_status, uv, water_world);
}

float classify_visible_water(
	vec2 uv,
	float depth,
	vec3 cam_pos,
	out vec3 scene_world,
	out vec3 view_dir,
	out float scene_distance,
	out vec3 water_world,
	out float water_depth_delta,
	out float water_depth_match,
	out float body_gate,
	out float water_ray_hits
) {
	scene_world = main_world_from_depth(uv, depth);
	view_dir = normalize(scene_world - cam_pos);
	scene_distance = length(scene_world - cam_pos);
	water_world = scene_world;
	water_depth_delta = 1.0e6;
	water_depth_match = 0.0;
	body_gate = 0.0;
	if (!coarse_water_depth_gate(cam_pos, view_dir, scene_distance)) {
		water_ray_hits = 0.0;
		return 0.0;
	}
	water_ray_hits = water_hit_from_ray(
		cam_pos,
		view_dir,
		scene_distance,
		water_world,
		water_depth_delta,
		body_gate
	) ? 1.0 : 0.0;

	float depth_tolerance = water_depth_match_tolerance(scene_distance);
	water_depth_match = water_ray_hits > 0.5
		? 1.0 - smoothstep(depth_tolerance, depth_tolerance * 2.0, water_depth_delta)
		: 0.0;
	return body_gate * water_depth_match;
}

float classify_visible_water_from_depth_sample(
	vec2 uv,
	float depth,
	vec3 cam_pos,
	out vec3 scene_world,
	out float scene_distance,
	out float body_gate
) {
	scene_world = main_world_from_depth(uv, depth);
	scene_distance = length(scene_world - cam_pos);
	WaterSurfaceContractSample surface = water_surface_query(scene_world, cam_pos, true, true);
	body_gate = surface.body_gate;
	float depth_tolerance = water_depth_match_tolerance(scene_distance);
	float depth_match = 1.0 - smoothstep(depth_tolerance, depth_tolerance * 2.0, abs(surface.depth));
	return body_gate * depth_match;
}

vec3 debug_reject_color(float reason) {
	if (reason < 1.5) {
		return vec3(0.02, 0.02, 0.02);
	}
	if (reason < 2.5) {
		return vec3(0.16, 0.16, 0.16); // not visible water
	}
	if (reason < 3.5) {
		return vec3(1.0, 0.0, 1.0); // source invalid/stale
	}
	if (reason < 4.5) {
		return vec3(1.0, 0.42, 0.0); // candidate out of bounds
	}
	if (reason < 5.5) {
		return vec3(1.0, 0.0, 0.0); // no candidate depth
	}
	if (reason < 6.5) {
		return vec3(1.0, 1.0, 0.0); // receiver ray miss / in front of the water surface
	}
	if (reason < 7.5) {
		return vec3(0.0, 0.35, 1.0); // above water / outside water body
	}
	if (reason < 8.5) {
		return vec3(0.0, 1.0, 1.0); // main depth is not the visible water surface
	}
	if (reason < 9.5) {
		return vec3(0.55, 0.0, 1.0); // shifted candidate UV is not water-owned
	}
	if (reason < 10.5) {
		return vec3(0.0, 0.15, 0.75); // source stale
	}
	return vec3(0.7, 0.0, 0.0);
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (pixel.x >= int(pc.screen.x) || pixel.y >= int(pc.screen.y)) {
		return;
	}
	add_debug_stat(0u);

	vec2 uv = (vec2(pixel) + 0.5) / pc.screen.xy;
	vec4 scene_color = imageLoad(color_image, pixel);
	float main_depth = main_depth_at(uv);
	if (main_depth <= FAR_DEPTH_EPS) {
		add_debug_stat(1u);
		return;
	}

	vec3 cam_pos = camera_position();
	vec3 main_world = vec3(0.0);
	vec3 view_dir = vec3(0.0);
	float main_distance = 0.0;
	vec3 water_world = vec3(0.0);
	float water_depth_delta = 0.0;
	float water_depth_match = 0.0;
	float main_body_gate = 0.0;
	float water_ray_hits = 0.0;
	float visible_water = classify_visible_water(
		uv,
		main_depth,
		cam_pos,
		main_world,
		view_dir,
		main_distance,
		water_world,
		water_depth_delta,
		water_depth_match,
		main_body_gate,
		water_ray_hits
	);
	float reject_reason = visible_water > VISIBLE_WATER_EPS ? 0.0 : 2.0;
	if (visible_water > VISIBLE_WATER_EPS) {
		add_debug_stat(2u);
	}
	if (water_ray_hits > 0.5 && main_body_gate > VISIBLE_WATER_EPS && water_depth_match <= VISIBLE_WATER_EPS) {
		reject_reason = 8.0;
	}

	float source_ready = (source_color_valid && source_depth_valid && source_fresh) ? 1.0 : 0.0;
	if (visible_water > VISIBLE_WATER_EPS && source_ready > 0.5) {
		add_debug_stat(3u);
	}
	if (visible_water > VISIBLE_WATER_EPS && source_ready < 0.5) {
		reject_reason = (!source_color_valid || !source_depth_valid) ? 3.0 : 10.0;
	}

	vec3 final_color = scene_color.rgb;
	vec3 candidate_color = vec3(0.0);
	vec3 water_color = scene_color.rgb;
	vec2 candidate_uv = uv;
	float candidate_offset = 0.0;
	float candidate_mask = 0.0;
	float candidate_water_owned = 0.0;
	float unshifted_source_submerged = 0.0;
	float post_absorption_luma = 0.0;

	if (visible_water > VISIBLE_WATER_EPS && source_ready > 0.5) {
		vec3 normal = surface_normal_at(water_world.xz, cam_pos, water_world.y);
		vec3 refr_dir = refract(view_dir, normal, AIR_TO_WATER_ETA);
		if (dot(refr_dir, refr_dir) <= 1e-7 || refr_dir.y >= -0.001) {
			refr_dir = normalize(mix(view_dir, vec3(view_dir.x, -abs(view_dir.y), view_dir.z), 0.5));
		}

		float edge_t = clamp(length((uv - 0.5) * 2.0), 0.0, 1.0);
		float edge_guard = mix(1.0, 1.0 - smoothstep(0.72, 1.0, edge_t), clamp(edge_guard_strength, 0.0, 1.0));
		ReceiverSolveSample receiver_sample = depth_guided_receiver_sample(uv, cam_pos, water_world, refr_dir, edge_guard);
		bool projected_valid = receiver_sample.valid > 0.5;
		bool source_projected_valid = projected_valid;
		vec2 source_candidate_uv = receiver_sample.source_uv;
		candidate_uv = receiver_sample.main_uv;
		candidate_offset = length(candidate_uv - uv);
		if (projected_valid && source_projected_valid) {
			vec2 candidate_offset_px = (candidate_uv - uv) * pc.screen.xy;
			if (length(candidate_offset_px) > 0.5) {
				add_debug_stat(13u);
			}
			if (length(candidate_offset_px) > 2.0) {
				add_debug_stat(14u);
			}
			vec2 source_mismatch_px = (source_candidate_uv - candidate_uv) * pc.screen.xy;
			if (length(source_mismatch_px) > 0.5) {
				add_debug_stat(15u);
			}
		}
		if (!projected_valid || !source_projected_valid || !uv_in_screen(candidate_uv) || !uv_in_screen(source_candidate_uv)) {
			reject_reason = receiver_sample.status;
			if (reject_reason < 4.5) {
				add_debug_stat(4u);
			} else if (reject_reason < 5.5) {
				add_debug_stat(7u);
			} else if (reject_reason < 6.5) {
				add_debug_stat(8u);
			} else if (reject_reason < 7.5) {
				add_debug_stat(9u);
			} else {
				add_debug_stat(4u);
			}
		} else {
			if (debug_mode == 7) {
				float original_source_depth = source_depth_at(uv);
				if (original_source_depth > FAR_DEPTH_EPS) {
					vec3 original_source_world = source_world_from_depth(uv, original_source_depth);
					WaterSurfaceContractSample original_source_surface = water_surface_query(original_source_world, cam_pos, true, true);
					unshifted_source_submerged = (
						original_source_surface.depth > SUBMERGED_EPS_M
						&& original_source_surface.body_gate > 0.001
					) ? 1.0 : 0.0;
				}
			}

			float candidate_main_depth = main_depth_at(candidate_uv);
			if (candidate_main_depth <= FAR_DEPTH_EPS) {
				add_debug_stat(5u);
				reject_reason = 5.0;
			} else {
				vec3 candidate_main_world = vec3(0.0);
				float candidate_main_distance = 0.0;
				float candidate_body_gate = 0.0;
				float candidate_visible_water = classify_visible_water_from_depth_sample(
					candidate_uv,
					candidate_main_depth,
					cam_pos,
					candidate_main_world,
					candidate_main_distance,
					candidate_body_gate
				);
				candidate_water_owned = candidate_visible_water;
				if (candidate_visible_water > VISIBLE_WATER_EPS) {
					add_debug_stat(6u);
				}
				// GPU Gems mask rule: if the perturbed UV exits the refractive owner mask,
				// collapse toward the original screen UV and keep color/depth on that same UV.
				float owner_fade = smoothstep(VISIBLE_WATER_EPS, MASK_EDGE_OWNERSHIP_FADE, candidate_visible_water);
				vec2 effective_uv = mix(uv, source_candidate_uv, owner_fade);
				float effective_depth = source_depth_at(effective_uv);
				if (effective_depth <= FAR_DEPTH_EPS) {
					add_debug_stat(7u);
					if (candidate_visible_water <= VISIBLE_WATER_EPS) {
						add_debug_stat(12u);
					}
					reject_reason = candidate_visible_water <= VISIBLE_WATER_EPS ? 9.0 : 5.0;
				} else {
					vec3 source_world = source_world_from_depth(effective_uv, effective_depth);
					float behind_surface = dot(source_world - water_world, refr_dir);
					bool source_is_behind_surface = behind_surface > 0.015;
					bool source_is_submerged = false;
					if (owner_fade <= VISIBLE_WATER_EPS) {
						source_is_submerged = source_world.y < water_world.y - SUBMERGED_EPS_M;
						if (debug_mode != 7) {
							unshifted_source_submerged = source_is_submerged ? 1.0 : 0.0;
						}
					} else {
						WaterSurfaceContractSample source_surface = water_surface_query(source_world, cam_pos, true, true);
						source_is_submerged = source_surface.depth > SUBMERGED_EPS_M && source_surface.body_gate > 0.001;
					}

					if (!source_is_behind_surface) {
						add_debug_stat(8u);
						reject_reason = owner_fade <= VISIBLE_WATER_EPS ? 9.0 : 6.0;
					} else if (!source_is_submerged) {
						add_debug_stat(9u);
						reject_reason = owner_fade <= VISIBLE_WATER_EPS ? 9.0 : 7.0;
					} else {
						float optical_depth = clamp(length(source_world - water_world), 0.0, max(pc.optics.w, 0.05));
						vec3 transmittance = exp(-pc.optics.xyz * optical_depth);
						candidate_color = textureLod(source_color_tex, effective_uv, 0.0).rgb;
						vec3 absorbed = candidate_color * transmittance + state.medium_params.xyz * (vec3(1.0) - transmittance);
						float cos_theta = clamp(dot(-view_dir, normal), 0.0, 1.0);
						float fresnel = pow(1.0 - cos_theta, 5.0);
						water_color = mix(absorbed, scene_color.rgb, clamp(fresnel * 0.70, 0.0, 0.85));
						post_absorption_luma = dot(water_color, vec3(0.2126, 0.7152, 0.0722));
						candidate_mask = 1.0;
						add_debug_stat(10u);
						reject_reason = 0.0;
						float collapsed_blend = mix(MASK_REJECT_COLLAPSE_BLEND, 1.0, owner_fade);
						float strength_blend = clamp(refraction_strength, 0.0, 1.0);
						final_color = mix(scene_color.rgb, water_color, clamp(pc.screen.w * visible_water * collapsed_blend * strength_blend, 0.0, 1.0));
					}
				}
			}
		}
	}

	if (debug_mode == 1) {
		final_color = candidate_mask > 0.5 ? vec3(0.0, 1.0, 0.0) : vec3(visible_water, 0.0, 0.0);
	} else if (debug_mode == 2) {
		final_color = vec3(source_color_valid ? 0.0 : 1.0, source_depth_valid ? 1.0 : 0.0, source_fresh ? 0.25 : 1.0);
	} else if (debug_mode == 3) {
		final_color = vec3(clamp(candidate_offset * 90.0, 0.0, 1.0), candidate_mask, visible_water);
	} else if (debug_mode == 4) {
		final_color = candidate_mask > 0.5 ? vec3(0.0, 1.0, 0.0) : debug_reject_color(reject_reason);
	} else if (debug_mode == 5) {
		final_color = candidate_mask > 0.5 ? candidate_color : debug_reject_color(reject_reason);
	} else if (debug_mode == 6) {
		final_color = vec3(post_absorption_luma);
	} else if (debug_mode == 7) {
		final_color = vec3(
			clamp(visible_water, 0.0, 1.0),
			clamp(candidate_water_owned, 0.0, 1.0),
			unshifted_source_submerged
		);
	}

	if (candidate_mask > 0.001 || debug_mode != 0) {
		add_debug_stat(11u);
		imageStore(color_image, pixel, vec4(final_color, scene_color.a));
	}
}
