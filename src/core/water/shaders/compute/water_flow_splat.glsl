#[compute]
#version 460

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D flow_image;
layout(set = 0, binding = 1) uniform sampler2D water_body_atlas_tex;

struct FlowCommand {
	vec4 shape; // world_x, world_z, radius_m, block_strength
	vec4 water; // height, body_gate, requires_atlas, height_tolerance
	ivec4 rect; // min_x, min_y, width, height in flow texels
	vec4 flow; // base_vel_x, base_vel_z, wake_strength, active
};

layout(std430, set = 0, binding = 2) restrict readonly buffer FlowCommands {
	FlowCommand commands[];
};

layout(push_constant) restrict readonly uniform Params {
	vec4 bounds; // min_x, min_z, world_size, texel_size
	vec4 atlas_bounds; // min_x, min_z, size_x, size_z
	vec4 tuning; // atlas_available, global_height_tolerance, velocity_scale, resolution
	ivec4 params; // command_count, max_rect_width, max_rect_height, unused
} pc;

bool atlas_rejects(vec2 world_xz, FlowCommand command) {
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

vec4 flow_shape(vec2 world_xz, FlowCommand command) {
	vec2 base_velocity = command.flow.xy;
	float base_speed = length(base_velocity);
	if (command.flow.w <= 0.001 || base_speed <= 0.001 || atlas_rejects(world_xz, command)) {
		return vec4(0.0);
	}

	float radius = max(command.shape.z, pc.bounds.w * 2.0);
	vec2 delta = world_xz - command.shape.xy;
	float dist = length(delta);
	float support = radius * 5.0;
	if (dist > support) {
		return vec4(0.0);
	}

	vec2 dir = base_velocity / base_speed;
	vec2 side = vec2(-dir.y, dir.x);
	float along = dot(delta, dir);
	float lateral = dot(delta, side);
	float core = exp(-pow(dist / radius, 2.0));
	float downstream = smoothstep(-radius * 0.5, radius * 2.0, along) *
		(1.0 - smoothstep(radius * 2.0, support, along));
	float side_gate = smoothstep(0.0, radius * 0.95, abs(lateral)) *
		(1.0 - smoothstep(radius * 0.95, radius * 2.8, abs(lateral)));

	float block_strength = clamp(command.shape.w, 0.0, 2.0);
	float wake_strength = clamp(command.flow.z, 0.0, 2.0);
	vec2 slow = -base_velocity * block_strength * core;
	float side_sign = lateral >= 0.0 ? 1.0 : -1.0;
	vec2 deflect = side * side_sign * base_speed * wake_strength * side_gate * downstream * 0.55;
	float turbulence = clamp(core * block_strength + side_gate * downstream * wake_strength, 0.0, 1.0);
	float influence = clamp(core + downstream * side_gate, 0.0, 1.0);
	return vec4((slow + deflect) * pc.tuning.z, turbulence, influence);
}

void main() {
	uint command_index = gl_GlobalInvocationID.z;
	if (command_index >= uint(pc.params.x)) {
		return;
	}
	FlowCommand command = commands[command_index];
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
	vec4 delta = flow_shape(world_xz, command);
	if (dot(abs(delta), vec4(1.0)) <= 0.000001) {
		return;
	}

	vec4 state = imageLoad(flow_image, texel);
	state.rg += delta.rg;
	state.ba = max(state.ba, delta.ba);
	state.rg = clamp(state.rg, vec2(-8.0), vec2(8.0));
	state.ba = clamp(state.ba, vec2(0.0), vec2(1.0));
	imageStore(flow_image, texel, state);
}
