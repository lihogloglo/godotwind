#[compute]
#version 460

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) restrict writeonly uniform image2D image_out;
layout(rgba16f, set = 0, binding = 1) restrict readonly uniform image2D image_in;

layout(push_constant) restrict readonly uniform Params {
	ivec4 params; // resolution, unused...
	vec4 tuning; // diffusion, velocity damping, energy damping, texel size
} pc;

vec4 read_state(ivec2 texel, int resolution) {
	if (texel.x < 0 || texel.y < 0 || texel.x >= resolution || texel.y >= resolution) {
		return vec4(0.0);
	}
	return imageLoad(image_in, texel);
}

void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	int resolution = pc.params.x;
	if (texel.x >= resolution || texel.y >= resolution) {
		return;
	}

	vec4 center = imageLoad(image_in, texel);
	vec4 average =
		read_state(texel + ivec2(1, 0), resolution) +
		read_state(texel + ivec2(-1, 0), resolution) +
		read_state(texel + ivec2(0, 1), resolution) +
		read_state(texel + ivec2(0, -1), resolution);
	average *= 0.25;

	vec2 velocity = mix(center.rg, average.rg, pc.tuning.x) * pc.tuning.y;
	float turbulence = mix(center.b, average.b, pc.tuning.x) * pc.tuning.z;
	float influence = mix(center.a, average.a, pc.tuning.x) * pc.tuning.z;

	imageStore(image_out, texel, vec4(velocity, turbulence, influence));
}
