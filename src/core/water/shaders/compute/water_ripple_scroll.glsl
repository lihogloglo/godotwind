#[compute]
#version 460

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) restrict writeonly uniform image2D image_out;
layout(rgba16f, set = 0, binding = 1) restrict readonly uniform image2D image_in;

layout(push_constant) restrict readonly uniform Params {
	ivec4 params; // resolution, scroll_x, scroll_y, unused
} pc;

void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	int resolution = pc.params.x;
	if (texel.x >= resolution || texel.y >= resolution) {
		return;
	}

	ivec2 src_texel = texel + pc.params.yz;
	vec4 state = vec4(0.0);
	if (src_texel.x >= 0 && src_texel.y >= 0 && src_texel.x < resolution && src_texel.y < resolution) {
		state = imageLoad(image_in, src_texel);
	}
	imageStore(image_out, texel, state);
}
