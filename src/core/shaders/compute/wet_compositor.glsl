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

#define WATER_SURFACE_CAN_SAMPLE_DISPLACEMENT displacement_valid
#include "res://src/core/shaders/compute/water_surface_contract.glslinc"

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
