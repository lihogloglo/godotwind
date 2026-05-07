#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) readonly uniform image2D source_color_image;
layout(set = 0, binding = 1) uniform sampler2D source_depth_tex;
layout(rgba16f, set = 0, binding = 2) writeonly uniform image2D target_color_image;
layout(r32f, set = 0, binding = 3) writeonly uniform image2D target_depth_image;

layout(push_constant, std430) uniform Params {
	vec4 screen; // x=width, y=height, zw=reserved
} pc;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (pixel.x >= int(pc.screen.x) || pixel.y >= int(pc.screen.y)) {
		return;
	}

	vec2 uv = (vec2(pixel) + 0.5) / pc.screen.xy;
	imageStore(target_color_image, pixel, imageLoad(source_color_image, pixel));
	imageStore(target_depth_image, pixel, vec4(texture(source_depth_tex, uv).r, 0.0, 0.0, 1.0));
}
