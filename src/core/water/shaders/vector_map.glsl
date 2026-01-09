#[compute]
#version 450

// Vector Map Generator Compute Shader
// Generates animated flow vectors and height data for water surface
// Based on Godot-Water-Shader-Prototype-4.4 by OKiN

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Previous frame's vector map (for temporal continuity)
layout(set = 0, binding = 0) uniform sampler2D current_image;

// Output vector map: RG = flow direction, B = height, A = 1.0
layout(rgba32f, set = 1, binding = 0) uniform restrict writeonly image2D output_image;

// Source flow texture (static flow field from artist)
layout(set = 2, binding = 0) uniform sampler2D flow_texture;

// Shader parameters
layout(push_constant, std430) uniform Params {
	float forward_offset;      // Offset for forward flow sampling (default: 1.5)
	float forward_fadeoff;     // Fadeoff for forward flow (default: 0.001)
	float flow_strength;       // Strength of source flow texture (default: 1.0)
	float flow_randomize;      // Amount of randomization (default: 0.2)
	float flow_random_speed;   // Speed of random animation (default: 0.5)
	float blur_strength;       // Blur amount for smoothing (default: 0.02)
	float blur_offset;         // Blur sample offset (default: 1.0)
	float curl_strength;       // Curl noise strength (default: 0.6)
	float curl_offset;         // Curl sample offset (default: 7.0)
	float shift_vector_x;      // UV shift X (default: 0.01)
	float shift_vector_y;      // UV shift Y (default: 0.05)
	float shift_speed;         // UV shift speed (default: 1.0)
	float time;                // Current time
	float padding1;            // Padding for alignment
	float padding2;
	float padding3;
} param;

// Calculate height delta from flow divergence
float get_delta(sampler2D tex, vec2 uv, float offset) {
	float pyt = 0.707107;  // 1/sqrt(2) for diagonal offsets

	vec2 m = texture(tex, uv).xy;

	vec2 p1 = texture(tex, fract(uv + vec2(0.0, -offset))).xy;
	vec2 p2 = texture(tex, fract(uv + vec2(offset, 0.0))).xy;
	vec2 p3 = texture(tex, fract(uv + vec2(0.0, offset))).xy;
	vec2 p4 = texture(tex, fract(uv + vec2(-offset, 0.0))).xy;
	vec2 p5 = texture(tex, fract(uv + vec2(offset, -offset) * pyt)).xy;
	vec2 p6 = texture(tex, fract(uv + vec2(offset, offset) * pyt)).xy;
	vec2 p7 = texture(tex, fract(uv + vec2(-offset, offset) * pyt)).xy;
	vec2 p8 = texture(tex, fract(uv + vec2(-offset, -offset) * pyt)).xy;

	return (length(m - p1) + length(m - p2) + length(m - p3) + length(m - p4) +
			length(m - p5) + length(m - p6) + length(m - p7) + length(m - p8)) * 0.125;
}

// Get average of surrounding samples (blur)
vec2 get_average(sampler2D tex, vec2 uv, float offset) {
	float pyt = 0.707107;

	vec2 p1 = texture(tex, fract(uv + vec2(0.0, -offset))).xy;
	vec2 p2 = texture(tex, fract(uv + vec2(offset, 0.0))).xy;
	vec2 p3 = texture(tex, fract(uv + vec2(0.0, offset))).xy;
	vec2 p4 = texture(tex, fract(uv + vec2(-offset, 0.0))).xy;
	vec2 p5 = texture(tex, fract(uv + vec2(-offset, -offset) * pyt)).xy;
	vec2 p6 = texture(tex, fract(uv + vec2(offset, -offset) * pyt)).xy;
	vec2 p7 = texture(tex, fract(uv + vec2(offset, offset) * pyt)).xy;
	vec2 p8 = texture(tex, fract(uv + vec2(-offset, offset) * pyt)).xy;

	return (p1 + p2 + p3 + p4 + p5 + p6 + p7 + p8) / 8.0;
}

// Calculate forward flow propagation
vec2 get_forward(sampler2D tex, vec2 uv, float offset, float fadeout) {
	float forward_fadeout = 0.414 - fadeout;
	float pyt = 0.707107;

	vec2 p1 = texture(tex, fract(uv + vec2(0.0, -offset))).xy - 0.5;
	vec2 p2 = texture(tex, fract(uv + vec2(offset, -offset) * pyt)).xy - 0.5;
	vec2 p3 = texture(tex, fract(uv + vec2(offset, 0.0))).xy - 0.5;
	vec2 p4 = texture(tex, fract(uv + vec2(offset, offset) * pyt)).xy - 0.5;
	vec2 p5 = texture(tex, fract(uv + vec2(0.0, offset))).xy - 0.5;
	vec2 p6 = texture(tex, fract(uv + vec2(-offset, offset) * pyt)).xy - 0.5;
	vec2 p7 = texture(tex, fract(uv + vec2(-offset, 0.0))).xy - 0.5;
	vec2 p8 = texture(tex, fract(uv + vec2(-offset, -offset) * pyt)).xy - 0.5;

	vec2 middle = vec2(0.0, 0.0);

	// Accumulate directional flow
	middle.y += clamp(dot(p1, vec2(0.0, 1.0)) * forward_fadeout, 0.0, 1.0);
	middle.y += clamp(dot(p2, vec2(-pyt, pyt)) * forward_fadeout, 0.0, 1.0);
	middle.y += clamp(dot(p8, vec2(pyt, pyt)) * forward_fadeout, 0.0, 1.0);

	middle.x -= clamp(dot(p2, vec2(-pyt, pyt)) * forward_fadeout, 0.0, 1.0);
	middle.x -= clamp(dot(p3, vec2(-1.0, 0.0)) * forward_fadeout, 0.0, 1.0);
	middle.x -= clamp(dot(p4, vec2(-pyt, -pyt)) * forward_fadeout, 0.0, 1.0);

	middle.y -= clamp(dot(p4, vec2(-pyt, -pyt)) * forward_fadeout, 0.0, 1.0);
	middle.y -= clamp(dot(p5, vec2(0.0, -1.0)) * forward_fadeout, 0.0, 1.0);
	middle.y -= clamp(dot(p6, vec2(pyt, -pyt)) * forward_fadeout, 0.0, 1.0);

	middle.x += clamp(dot(p6, vec2(pyt, -pyt)) * forward_fadeout, 0.0, 1.0);
	middle.x += clamp(dot(p7, vec2(1.0, 0.0)) * forward_fadeout, 0.0, 1.0);
	middle.x += clamp(dot(p8, vec2(pyt, pyt)) * forward_fadeout, 0.0, 1.0);

	return middle;
}

// Calculate curl (rotational) component
vec2 get_curl(sampler2D tex, vec2 uv, float offset) {
	vec2 middle = vec2(0.0, 0.0);
	float pyt = 0.707107;

	vec2 p1 = texture(tex, fract(uv + vec2(0.0, -offset))).xy - 0.5;
	vec2 p2 = texture(tex, fract(uv + vec2(0.0, -offset * 2.0))).xy - 0.5;
	vec2 p3 = texture(tex, fract(uv + vec2(offset, 0.0))).xy - 0.5;
	vec2 p4 = texture(tex, fract(uv + vec2(offset * 2.0, 0.0))).xy - 0.5;
	vec2 p5 = texture(tex, fract(uv + vec2(0.0, offset))).xy - 0.5;
	vec2 p6 = texture(tex, fract(uv + vec2(0.0, offset * 2.0))).xy - 0.5;
	vec2 p7 = texture(tex, fract(uv + vec2(-offset, 0.0))).xy - 0.5;
	vec2 p8 = texture(tex, fract(uv + vec2(-offset * 2.0, 0.0))).xy - 0.5;

	vec2 p9 = texture(tex, fract(uv + vec2(offset, -offset) * pyt)).xy - 0.5;
	vec2 p10 = texture(tex, fract(uv + vec2(offset * 2.0, -offset * 2.0) * pyt)).xy - 0.5;
	vec2 p11 = texture(tex, fract(uv + vec2(offset, offset) * pyt)).xy - 0.5;
	vec2 p12 = texture(tex, fract(uv + vec2(offset * 2.0, offset * 2.0) * pyt)).xy - 0.5;
	vec2 p13 = texture(tex, fract(uv + vec2(-offset, offset) * pyt)).xy - 0.5;
	vec2 p14 = texture(tex, fract(uv + vec2(-offset * 2.0, offset * 2.0) * pyt)).xy - 0.5;
	vec2 p15 = texture(tex, fract(uv + vec2(-offset, -offset) * pyt)).xy - 0.5;
	vec2 p16 = texture(tex, fract(uv + vec2(-offset * 2.0, -offset * 2.0) * pyt)).xy - 0.5;

	middle += ((p1 - p2) + (p3 - p4) + (p5 - p6) + (p7 - p8) +
			   (p9 - p10) + (p11 - p12) + (p13 - p14) + (p15 - p16)) * 0.005;

	return middle;
}

void main() {
	ivec2 image_size = imageSize(output_image);
	vec2 uv = vec2(gl_GlobalInvocationID.xy) / vec2(image_size - 1);

	// Animated UV shift for organic movement
	vec2 uv_shifted = fract(uv + vec2(
		sin(param.time * param.shift_speed) * param.shift_vector_x * 0.01,
		cos(param.time * param.shift_speed * 0.97231) * param.shift_vector_y * 0.01
	));

	// Build vector map from previous frame + new contributions
	vec2 flow_pixel = vec2(0.5, 0.5);
	flow_pixel += get_forward(current_image, uv_shifted, param.forward_offset / 1024.0, param.forward_fadeoff);
	flow_pixel += get_curl(current_image, uv_shifted, param.curl_offset / 1024.0) * param.curl_strength;
	flow_pixel = mix(flow_pixel, get_average(current_image, uv_shifted, param.blur_offset / 1024.0), param.blur_strength);

	// Sample source flow texture
	// R,G = flow direction, B = flow strength
	vec3 flow_source = texture(flow_texture, uv).xyz;
	float flow_source_overlay = texture(flow_texture, fract(uv + vec2(param.time * 0.0121, param.time * 0.0372))).z;

	// Random flow component for organic variation
	vec2 flow_random = vec2(
		sin(uv.x * 6.25 + param.time * param.flow_random_speed) * 0.5 + 0.5,
		cos(uv.y * 6.25 + param.time * param.flow_random_speed) * 0.5 + 0.5
	);

	// Modulate flow strength
	flow_source.z *= flow_source_overlay * clamp(param.flow_strength, 0.0, 1.0);

	// Mix in random flow
	flow_source.xy = mix(flow_source.xy, flow_random, param.flow_randomize);

	// Calculate height from flow divergence (multi-scale)
	float height = get_delta(current_image, uv, 0.0009765625) +  // 1/1024
				   get_delta(current_image, uv, 0.001953125) +   // 1/512
				   get_delta(current_image, uv, 0.00390625) +    // 1/256
				   get_delta(current_image, uv, 0.0078125) +     // 1/128
				   get_delta(current_image, uv, 0.015625) +      // 1/64
				   get_delta(current_image, uv, 0.03125) +       // 1/32
				   get_delta(current_image, uv, 0.0625);         // 1/16

	// Final output: blend computed flow with source flow, store height
	vec2 final_flow = mix(flow_pixel, flow_source.xy, flow_source.z);
	imageStore(output_image, ivec2(gl_GlobalInvocationID.xy), vec4(final_flow, height, 1.0));
}
