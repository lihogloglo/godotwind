#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_texture;
layout(set = 0, binding = 2) uniform sampler2D cloud_texture;

layout(std430, set = 0, binding = 3) readonly buffer CloudShadowState {
	mat4 inv_projection;
	mat4 inv_view;
	mat4 view_projection;
	vec4 sun;      // xyz = direction toward sun, w = cloud sample height
	vec4 cloud;    // x = floor, y = ceiling, zw = reserved
} state;

layout(push_constant, std430) uniform Params {
	vec4 screen;   // x = width, y = height, z = blend, w = time
	vec4 shadow;   // x = strength, y = density threshold, z = softness, w = height bias
	vec4 limits;   // x = max distance, y = debug mode, zw = reserved
} pc;

const float SKY_DEPTH_THRESHOLD = 1e-6;

vec3 reconstruct_world_position(vec2 uv, float depth) {
	vec4 clip_pos = vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec4 view_pos = state.inv_projection * clip_pos;
	view_pos.xyz /= max(view_pos.w, 1e-6);
	vec4 world_pos = state.inv_view * vec4(view_pos.xyz, 1.0);
	return world_pos.xyz;
}

vec2 project_world_to_uv(vec3 world_pos, out bool valid) {
	vec4 clip_pos = state.view_projection * vec4(world_pos, 1.0);
	valid = clip_pos.w > 1e-5;
	if (!valid) {
		return vec2(0.0);
	}
	vec3 ndc = clip_pos.xyz / clip_pos.w;
	valid = ndc.x >= -1.0 && ndc.x <= 1.0 && ndc.y >= -1.0 && ndc.y <= 1.0;
	return ndc.xy * 0.5 + 0.5;
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (pixel.x >= int(pc.screen.x) || pixel.y >= int(pc.screen.y)) {
		return;
	}

	vec2 uv = (vec2(pixel) + 0.5) / pc.screen.xy;
	float depth = texture(depth_texture, uv).r;
	if (depth <= SKY_DEPTH_THRESHOLD) {
		return;
	}

	vec3 world_pos = reconstruct_world_position(uv, depth);
	vec3 toward_sun = normalize(state.sun.xyz);

	float sun_up = toward_sun.y;
	if (sun_up <= 0.02) {
		return;
	}

	float cloud_height = state.sun.w;
	float t = (cloud_height - world_pos.y) / sun_up;
	if (t <= 0.0) {
		return;
	}

	vec3 cloud_sample_pos = world_pos + toward_sun * t;
	bool projected = false;
	vec2 cloud_uv = project_world_to_uv(cloud_sample_pos, projected);
	if (!projected) {
		return;
	}

	float density = clamp(texture(cloud_texture, cloud_uv).a, 0.0, 1.0);
	float threshold = clamp(pc.shadow.y, 0.0, 1.0);
	float softness = max(pc.shadow.z, 0.001);
	float shadow_mask = smoothstep(threshold, min(threshold + softness, 1.0), density);

	float receiver_distance = length((state.inv_view * vec4(0.0, 0.0, 0.0, 1.0)).xyz - world_pos);
	float max_distance = max(pc.limits.x, 1.0);
	float distance_fade = 1.0 - smoothstep(max_distance * 0.85, max_distance, receiver_distance);
	float horizon_fade = smoothstep(0.02, 0.16, sun_up);
	shadow_mask *= distance_fade * horizon_fade;

	vec4 color = imageLoad(color_image, pixel);
	if (pc.limits.y > 0.5) {
		color.rgb = vec3(shadow_mask);
		imageStore(color_image, pixel, color);
		return;
	}

	float strength = clamp(pc.shadow.x, 0.0, 0.95) * clamp(pc.screen.z, 0.0, 1.0);
	color.rgb *= 1.0 - shadow_mask * strength;
	imageStore(color_image, pixel, color);
}
