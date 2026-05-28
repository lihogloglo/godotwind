// ============================================================================
// Shared dynamic water interaction helpers.
// ============================================================================
// One contract for ocean, river, and local water-volume renderers sampling the
// GPU ripple atlas written by WaterInteractionSim.

group_uniforms water_interaction;
uniform sampler2D water_interaction_map : filter_linear, repeat_disable;
uniform sampler2D water_dynamic_flow_map : filter_linear, repeat_disable;
uniform vec4 water_interaction_bounds = vec4(0.0, 0.0, 1.0, 1.0); // min_x, min_z, world_size, texel_size
uniform bool water_interaction_enabled = false;
uniform bool water_dynamic_flow_enabled = false;
uniform bool water_interaction_debug_enabled = false;
uniform float water_interaction_height_strength : hint_range(0.0, 0.25) = 0.012;
uniform float water_interaction_normal_strength : hint_range(0.0, 4.0) = 2.2;
uniform float water_interaction_foam_strength : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D water_body_atlas_map : filter_nearest, repeat_disable;
uniform vec4 water_body_atlas_bounds = vec4(0.0, 0.0, 0.0, 0.0);
uniform bool water_body_atlas_available = false;
uniform float water_interaction_surface_height = 0.0;
uniform float water_interaction_height_tolerance : hint_range(0.01, 2.0) = 0.35;
// 0 = no body gate, 1 = registered local water, 2 = ocean with registered-water holes.
uniform int water_interaction_body_filter_mode = 0;

vec2 water_surface_interaction_uv(vec2 world_xz) {
	return (world_xz - water_interaction_bounds.xy) / max(water_interaction_bounds.z, 0.001);
}

bool water_surface_interaction_in_bounds(vec2 uv) {
	return water_interaction_enabled &&
		all(greaterThanEqual(uv, vec2(0.0))) &&
		all(lessThanEqual(uv, vec2(1.0)));
}

bool water_surface_interaction_body_allows(vec2 world_xz, float surface_height) {
	if (!water_body_atlas_available || water_body_atlas_bounds.z <= 0.0 || water_body_atlas_bounds.w <= 0.0) {
		return true;
	}
	vec2 atlas_uv = (world_xz - water_body_atlas_bounds.xy) / water_body_atlas_bounds.zw;
	if (any(lessThan(atlas_uv, vec2(0.0))) || any(greaterThan(atlas_uv, vec2(1.0)))) {
		return true;
	}
	vec4 atlas = texture(water_body_atlas_map, atlas_uv);
	float body_gate = smoothstep(0.015, 0.12, clamp(atlas.r, 0.0, 1.0));
	bool registered_body = body_gate > 0.15;
	bool height_matches = abs(atlas.g - surface_height) <= water_interaction_height_tolerance;
	if (water_interaction_body_filter_mode == 1) {
		return registered_body && height_matches;
	}
	if (water_interaction_body_filter_mode == 2) {
		return !registered_body;
	}
	return true;
}

vec4 water_surface_interaction_sample_at(vec2 world_xz, float surface_height) {
	vec2 uv = water_surface_interaction_uv(world_xz);
	if (!water_surface_interaction_in_bounds(uv) || !water_surface_interaction_body_allows(world_xz, surface_height)) {
		return vec4(0.0);
	}
	float dist_to_center = length(uv - vec2(0.5));
	float blend_close = smoothstep(0.001, 0.02, dist_to_center);
	float blend_far = 1.0 - smoothstep(0.38, 0.48, dist_to_center);
	return texture(water_interaction_map, uv) * blend_close * blend_far;
}

vec4 water_surface_dynamic_flow_sample_at(vec2 world_xz, float surface_height) {
	vec2 uv = water_surface_interaction_uv(world_xz);
	if (!water_dynamic_flow_enabled || !water_surface_interaction_in_bounds(uv) || !water_surface_interaction_body_allows(world_xz, surface_height)) {
		return vec4(0.0);
	}
	float dist_to_center = length(uv - vec2(0.5));
	float blend_close = smoothstep(0.001, 0.02, dist_to_center);
	float blend_far = 1.0 - smoothstep(0.38, 0.48, dist_to_center);
	return texture(water_dynamic_flow_map, uv) * blend_close * blend_far;
}

vec2 water_surface_dynamic_flow_velocity_at(vec2 world_xz, float surface_height) {
	return water_surface_dynamic_flow_sample_at(world_xz, surface_height).rg;
}

float water_surface_dynamic_flow_energy_at(vec2 world_xz, float surface_height) {
	vec4 sample_value = water_surface_dynamic_flow_sample_at(world_xz, surface_height);
	return clamp(sample_value.b + sample_value.a * 0.45, 0.0, 1.0);
}

vec4 water_surface_interaction_sample(vec2 world_xz) {
	return water_surface_interaction_sample_at(world_xz, water_interaction_surface_height);
}

float water_surface_interaction_height_at(vec2 world_xz, float surface_height) {
	return water_surface_interaction_sample_at(world_xz, surface_height).r * water_interaction_height_strength;
}

float water_surface_interaction_height(vec2 world_xz) {
	return water_surface_interaction_sample(world_xz).r * water_interaction_height_strength;
}

vec2 water_surface_interaction_gradient_at(vec2 world_xz, float surface_height) {
	return water_surface_interaction_sample_at(world_xz, surface_height).ba * water_interaction_normal_strength;
}

vec2 water_surface_interaction_gradient(vec2 world_xz) {
	return water_surface_interaction_sample(world_xz).ba * water_interaction_normal_strength;
}

float water_surface_interaction_foam_at(vec2 world_xz, float surface_height) {
	if (water_interaction_foam_strength <= 0.0001) {
		return 0.0;
	}
	vec4 sample_value = water_surface_interaction_sample_at(world_xz, surface_height);
	float height_energy = abs(sample_value.r);
	float slope_energy = length(sample_value.ba) * max(water_interaction_bounds.w, 0.001);
	return smoothstep(0.08, 0.32, height_energy + slope_energy) * water_interaction_foam_strength;
}

float water_surface_interaction_foam(vec2 world_xz) {
	return water_surface_interaction_foam_at(world_xz, water_interaction_surface_height);
}

vec3 water_surface_interaction_debug_color_at(vec2 world_xz, float surface_height) {
	vec4 sample_value = water_surface_interaction_sample_at(world_xz, surface_height);
	float positive = smoothstep(0.0, 0.18, sample_value.r);
	float negative = smoothstep(0.0, 0.18, -sample_value.r);
	float slope = smoothstep(0.0, 0.45, length(sample_value.ba) * max(water_interaction_bounds.w, 0.001));
	return vec3(positive, slope, negative);
}

vec3 water_surface_interaction_debug_color(vec2 world_xz) {
	return water_surface_interaction_debug_color_at(world_xz, water_interaction_surface_height);
}
