#[compute]
#version 460

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) restrict writeonly uniform image2D image_out;
layout(rgba16f, set = 0, binding = 1) restrict readonly uniform image2D image_in;

layout(push_constant) restrict readonly uniform Params {
	ivec4 params; // resolution, unused...
	vec4 tuning; // wave coefficient, velocity damping, height decay, texel size
} pc;

float read_height(ivec2 texel, int resolution) {
	if (texel.x < 0 || texel.y < 0 || texel.x >= resolution || texel.y >= resolution) {
		return 0.0;
	}
	return imageLoad(image_in, texel).r;
}

void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	int resolution = pc.params.x;
	if (texel.x >= resolution || texel.y >= resolution) {
		return;
	}

	vec4 state = imageLoad(image_in, texel);
	float center = state.r;
	float previous = state.g;
	float laplacian =
		read_height(texel + ivec2(1, 0), resolution) +
		read_height(texel + ivec2(-1, 0), resolution) +
		read_height(texel + ivec2(0, 1), resolution) +
		read_height(texel + ivec2(0, -1), resolution) -
		center * 4.0;

	float next = (center * 2.0 - previous + laplacian * pc.tuning.x) * pc.tuning.y;
	next *= pc.tuning.z;

	float sx = (read_height(texel + ivec2(1, 0), resolution) - read_height(texel + ivec2(-1, 0), resolution)) * 0.5 / max(pc.tuning.w, 0.001);
	float sz = (read_height(texel + ivec2(0, 1), resolution) - read_height(texel + ivec2(0, -1), resolution)) * 0.5 / max(pc.tuning.w, 0.001);

	imageStore(image_out, texel, vec4(next, center, sx, sz));
}
