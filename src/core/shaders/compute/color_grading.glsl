#[compute]
#version 450

// Color Grading Compute Shader
// Basic tonemapping and color adjustment post-processing

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;

layout(push_constant, std430) uniform Params {
    vec4 color_filter;      // RGB tint, A = intensity
    vec4 lift_gamma_gain;   // x = lift, y = gamma, z = gain, w = saturation
    vec4 contrast_params;   // x = contrast, y = brightness, z = exposure, w = blend
    vec2 resolution;
    vec2 _pad;
} params;

// sRGB to linear
vec3 srgb_to_linear(vec3 c) {
    return pow(c, vec3(2.2));
}

// Linear to sRGB
vec3 linear_to_srgb(vec3 c) {
    return pow(c, vec3(1.0 / 2.2));
}

// ACES filmic tonemapping
vec3 aces_tonemap(vec3 x) {
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

// Saturation adjustment
vec3 adjust_saturation(vec3 color, float saturation) {
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    return mix(vec3(luma), color, saturation);
}

// Lift/Gamma/Gain color correction
vec3 lift_gamma_gain(vec3 color, float lift, float gamma, float gain) {
    // Lift (shadows)
    color = color + lift * (1.0 - color);

    // Gamma (midtones)
    color = pow(max(color, 0.0), vec3(1.0 / max(gamma, 0.001)));

    // Gain (highlights)
    color = color * gain;

    return color;
}

void main() {
    ivec2 pixel_coords = ivec2(gl_GlobalInvocationID.xy);

    if (pixel_coords.x >= int(params.resolution.x) || pixel_coords.y >= int(params.resolution.y)) {
        return;
    }

    vec4 color = imageLoad(color_image, pixel_coords);
    vec3 original = color.rgb;

    // Apply exposure
    color.rgb *= pow(2.0, params.contrast_params.z);

    // Apply lift/gamma/gain
    color.rgb = lift_gamma_gain(
        color.rgb,
        params.lift_gamma_gain.x,
        params.lift_gamma_gain.y,
        params.lift_gamma_gain.z
    );

    // Apply contrast (around 0.5 midpoint)
    color.rgb = (color.rgb - 0.5) * params.contrast_params.x + 0.5;

    // Apply brightness
    color.rgb += params.contrast_params.y;

    // Apply saturation
    color.rgb = adjust_saturation(color.rgb, params.lift_gamma_gain.w);

    // Apply color filter/tint
    color.rgb = mix(color.rgb, color.rgb * params.color_filter.rgb, params.color_filter.a);

    // Clamp to valid range
    color.rgb = max(color.rgb, 0.0);

    // Blend with original
    color.rgb = mix(original, color.rgb, params.contrast_params.w);

    imageStore(color_image, pixel_coords, color);
}
