#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) readonly uniform image2D source_image;
layout(rgba16f, set = 0, binding = 1) writeonly uniform image2D target_image;

layout(push_constant, std430) uniform Params {
	vec4 screen; // x=width, y=height, zw=reserved
} pc;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (pixel.x >= int(pc.screen.x) || pixel.y >= int(pc.screen.y)) {
		return;
	}
	imageStore(target_image, pixel, imageLoad(source_image, pixel));
}
