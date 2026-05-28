#[compute]
#version 460

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D state_image;
layout(set = 0, binding = 1) uniform sampler2D water_body_atlas_tex;

struct SplatCommand {
	vec4 shape; // world_x, world_z, radius_m, strength
	vec4 water; // height, body_gate, requires_atlas, height_tolerance
	ivec4 rect; // min_x, min_y, width, height in ripple texels
	vec4 trail; // dir_x, dir_z, length_m, strength
};

layout(std430, set = 0, binding = 2) restrict readonly buffer SplatCommands {
	SplatCommand commands[];
};

layout(push_constant) restrict readonly uniform Params {
	vec4 bounds; // min_x, min_z, world_size, texel_size
	vec4 atlas_bounds; // min_x, min_z, size_x, size_z
	vec4 tuning; // atlas_available, global_height_tolerance, height_strength, resolution
	ivec4 params; // command_count, max_rect_width, max_rect_height, unused
} pc;

bool atlas_rejects(vec2 world_xz, SplatCommand command) {
	if (command.water.z <= 0.5) {
		return false;
	}
	if (pc.tuning.x <= 0.5 || pc.atlas_bounds.z <= 0.0 || pc.atlas_bounds.w <= 0.0) {
		return true;
	}
	vec2 uv = (world_xz - pc.atlas_bounds.xy) / pc.atlas_bounds.zw;
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
		return true;
	}
	vec4 atlas = textureLod(water_body_atlas_tex, uv, 0.0);
	float gate = smoothstep(0.015, 0.12, clamp(atlas.r, 0.0, 1.0));
	float min_gate = max(command.water.y * 0.5, 0.15);
	float height_tolerance = max(command.water.w, pc.tuning.y);
	return gate < min_gate || abs(atlas.g - command.water.x) > height_tolerance;
}

float impulse_shape(vec2 world_xz, SplatCommand command) {
	float radius = max(command.shape.z, 0.04);
	float ring_width = max(radius * 0.22, pc.bounds.w * 1.5);
	float center_width = max(radius * 0.42, pc.bounds.w * 1.5);
	float support = radius + max(ring_width, center_width) * 3.0;
	vec2 delta = world_xz - command.shape.xy;
	float d = length(delta);
	bool has_trail = command.trail.w > 0.001 && command.trail.z > 0.001 && dot(command.trail.xy, command.trail.xy) > 0.0001;
	if (atlas_rejects(world_xz, command) || (d > support && !has_trail)) {
		return 0.0;
	}
	float base_impulse = 0.0;
	if (d <= support) {
		float ring_x = (d - radius) / ring_width;
		float center_x = d / center_width;
		float ring = exp(-(ring_x * ring_x));
		float center = exp(-(center_x * center_x));
		base_impulse = command.shape.w * pc.tuning.z * (ring - center * 0.45);
	}
	if (!has_trail) {
		return base_impulse;
	}

	vec2 dir = normalize(command.trail.xy);
	float along = dot(delta, dir);
	float lateral = dot(delta, vec2(-dir.y, dir.x));
	float tail_gate = smoothstep(0.0, radius * 0.35, along) * (1.0 - smoothstep(command.trail.z, command.trail.z + radius, along));
	float lateral_width = max(radius * 0.45, pc.bounds.w * 2.0);
	float tail = exp(-pow(lateral / lateral_width, 2.0)) * exp(-along / max(command.trail.z, 0.001)) * tail_gate;
	return base_impulse - abs(command.shape.w) * pc.tuning.z * tail * command.trail.w * 0.55;
}

void main() {
	uint command_index = gl_GlobalInvocationID.z;
	if (command_index >= uint(pc.params.x)) {
		return;
	}
	SplatCommand command = commands[command_index];
	ivec2 local_texel = ivec2(gl_GlobalInvocationID.xy);
	if (local_texel.x >= command.rect.z || local_texel.y >= command.rect.w) {
		return;
	}

	ivec2 texel = command.rect.xy + local_texel;
	int resolution = int(pc.tuning.w);
	if (texel.x < 0 || texel.y < 0 || texel.x >= resolution || texel.y >= resolution) {
		return;
	}

	vec2 uv = (vec2(texel) + vec2(0.5)) / float(resolution);
	vec2 world_xz = pc.bounds.xy + uv * pc.bounds.z;
	float impulse = impulse_shape(world_xz, command);
	if (abs(impulse) <= 0.000001) {
		return;
	}

	vec4 state = imageLoad(state_image, texel);
	state.r += impulse;
	state.g += impulse * 0.45;
	state.rg = clamp(state.rg, vec2(-4.0), vec2(4.0));
	imageStore(state_image, texel, state);
}
