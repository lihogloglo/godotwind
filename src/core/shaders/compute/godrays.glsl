#[compute]
#version 450

// Godrays Compute Shader — Screen-Space God Rays
// Based on Rafael's godrays.omwfx for OpenMW, adapted for Godot 4.6 CompositorEffect.
//
// 4-pass architecture (selected by pass_id push constant):
//   Pass 0 (Sky Mask):     Depth-based sun occlusion detection (full res)
//   Pass 1 (Radial Blur):  Gaussian blur along radial from sun (full res)
//   Pass 2 (Rays):         Iterative sampling toward sun with blue noise (half res)
//   Pass 3 (Combine):      Composite rays + sun disc onto scene color (full res)
//
// Push constants: 128 bytes (Godot hard limit). Weather/horizon precomputed on CPU.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Bindings — same layout for all passes, different textures bound per pass
layout(set = 0, binding = 0) uniform sampler2D tex_a;              // primary input sampler
layout(set = 0, binding = 1) uniform sampler2D tex_b;              // secondary input sampler
layout(r16f, set = 0, binding = 2) uniform image2D img_out;        // intermediate output
layout(rgba16f, set = 0, binding = 3) uniform image2D color_image; // scene color (pass 3)

layout(push_constant, std430) uniform Params {
	vec4 sun_screen_pos;   // xy = sun UV, z = forward_dot (<0 = visible), w = time
	vec4 sun_params;       // xyz = direction toward sun, w = sun_height_vis (precomputed)
	vec4 sun_color;        // rgb = light color, a = blend_factor
	vec4 ray_params;       // x = iterations, y = ray_radius, z = ray_strength, w = ray_falloff
	vec4 ray_params2;      // x = falloff_const, y = sun_falloff, z = center_vis, w = ray_occlude
	vec4 disc_params;      // x = radius, y = brightness, z = desaturate, w = disc_occlude
	vec4 misc_params;      // x = offscreen_range, y = horizon_mult, z = ray_brightness, w = pass_id
	vec4 extra_params;     // x = resolution_x, y = resolution_y, z = sun_weather_vis, w = disc_light
} params;
// Total: 8 × vec4 = 32 floats = 128 bytes

const int PASS_SKY_MASK    = 0;
const int PASS_RADIAL_BLUR = 1;
const int PASS_RAYS        = 2;
const int PASS_COMBINE     = 3;


// ═══════════════════════════════════════════════════════════════════
// Pass 0: Sky Mask
// ═══════════════════════════════════════════════════════════════════

void sky_mask() {
	// Full resolution for sharp silhouette edges (matches Rafael's RT_Stretch)
	vec2 full_res = params.extra_params.xy;
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (pixel.x >= int(full_res.x) || pixel.y >= int(full_res.y))
		return;

	if (params.sun_screen_pos.z >= 0.0) {
		imageStore(img_out, pixel, vec4(0.0));
		return;
	}

	vec2 uv = (vec2(pixel) + 0.5) / full_res;

	// Single depth sample at full-res (no supersampling needed at native resolution).
	// Godot reversed-Z: sky = 0.0, geometry = near/distance. Use tight threshold
	// so distant geometry (depth > 1e-6) still occludes — old 0.001 missed everything
	// beyond ~50m with near=0.05.
	const float SKY_THRESHOLD = 1e-6;
	float mask = step(texture(tex_a, uv).r, SKY_THRESHOLD);

	imageStore(img_out, pixel, vec4(mask));
}


// ═══════════════════════════════════════════════════════════════════
// Pass 1: Radial Blur
// ═══════════════════════════════════════════════════════════════════

void radial_blur() {
	// Full resolution for edge-precise blur (matches Rafael's RT_Blur)
	vec2 full_res = params.extra_params.xy;
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (pixel.x >= int(full_res.x) || pixel.y >= int(full_res.y))
		return;

	if (params.sun_screen_pos.z >= 0.0) {
		imageStore(img_out, pixel, vec4(0.0));
		return;
	}

	vec2 uv = (vec2(pixel) + 0.5) / full_res;
	vec2 sun_uv = params.sun_screen_pos.xy;
	vec2 dir = normalize(uv - sun_uv);
	vec2 rcp_full = 1.0 / full_res;
	vec2 radial = dir * rcp_full.yx;

	float alpha = 0.0;
	alpha += 0.3333 * texture(tex_a, uv).r;
	alpha += 0.2222 * texture(tex_a, uv + radial).r;
	alpha += 0.2222 * texture(tex_a, uv - radial).r;
	alpha += 0.1111 * texture(tex_a, uv + 2.0 * radial).r;
	alpha += 0.1111 * texture(tex_a, uv - 2.0 * radial).r;

	imageStore(img_out, pixel, vec4(alpha));
}


// ═══════════════════════════════════════════════════════════════════
// Pass 2: Ray Computation
// ═══════════════════════════════════════════════════════════════════

void compute_rays() {
	vec2 half_res = params.extra_params.xy * 0.5;
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (pixel.x >= int(half_res.x) || pixel.y >= int(half_res.y))
		return;

	if (params.sun_screen_pos.z >= 0.0) {
		imageStore(img_out, pixel, vec4(0.0));
		return;
	}

	vec2 uv = (vec2(pixel) + 0.5) / half_res;
	vec2 sun_uv = params.sun_screen_pos.xy;
	float raspect = half_res.y / half_res.x;

	// Blue noise temporal offset — slow cycle to reduce shimmer
	float timer = params.sun_screen_pos.w * 0.15;
	float offset = texture(tex_b, 3.2 * uv * vec2(1.0, raspect)).r;
	offset = fract(offset + timer * 0.61803398875);

	float offscreen_range = params.misc_params.x;
	float strength = params.ray_params.z
		* smoothstep(-offscreen_range, 0.0, 0.5 - abs(sun_uv.x - 0.5))
		* smoothstep(-offscreen_range, 0.0, 0.5 - abs(sun_uv.y - 0.5));

	vec2 screen_dir = uv - sun_uv;
	float screen_dist = length(screen_dir * vec2(1.0, raspect));
	screen_dir /= max(screen_dist, 0.0001);

	float sun_radius   = min(params.ray_params.y, screen_dist);
	float ray_falloff   = params.ray_params.w;
	float falloff_const = params.ray_params2.x;
	float sun_falloff   = params.ray_params2.y;
	float center_vis    = params.ray_params2.z;
	int   iterations    = clamp(int(params.ray_params.x), 1, 50);

	float l = 0.0;
	for (int i = 1; i <= iterations; i++) {
		float sundist = (float(i) + offset) / float(iterations) * sun_radius;
		sundist *= clamp(offset * 0.05, 0.0, 0.05) + 0.975;

		vec2 coords = clamp(sun_uv + sundist * screen_dir, vec2(0.0), vec2(1.0));
		float sample_val = texture(tex_a, coords).r;
		float falloff_exp = exp(-((screen_dist - sundist) / (falloff_const + sundist)) * ray_falloff);
		float dist_weight = pow(1.0 - clamp(sundist / params.ray_params.y, 0.0, 1.0), sun_falloff);
		l += sample_val * falloff_exp * dist_weight;
	}

	float one_minus_center = 1.0 - center_vis;
	l *= strength / float(iterations) * (screen_dist / params.ray_params.y * one_minus_center + center_vis);

	imageStore(img_out, pixel, vec4(l));
}


// ═══════════════════════════════════════════════════════════════════
// Pass 3: Combine
// ═══════════════════════════════════════════════════════════════════

void combine() {
	vec2 full_res = params.extra_params.xy;
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (pixel.x >= int(full_res.x) || pixel.y >= int(full_res.y))
		return;

	vec2 uv = (vec2(pixel) + 0.5) / full_res;

	vec4 ray = vec4(0.0);

	float forward = params.sun_screen_pos.z;
	float raspect = full_res.y / full_res.x;

	// ── Ray compositing ──
	if (forward < 0.0) {
		vec2 sun_uv = params.sun_screen_pos.xy;

		// Tangent-direction blur (perpendicular to radial) for smooth upscaling
		vec2 radial = normalize(uv - sun_uv);
		vec2 tan_dir = vec2(-radial.y, radial.x) / full_res;

		// 5-tap tangent blur on ray result (bilinear from half-res sampler)
		ray.a  = 0.3333 * texture(tex_a, uv).r;
		ray.a += 0.2222 * texture(tex_a, uv + tan_dir).r;
		ray.a += 0.2222 * texture(tex_a, uv - tan_dir).r;
		ray.a += 0.1111 * texture(tex_a, uv + 2.0 * tan_dir).r;
		ray.a += 0.1111 * texture(tex_a, uv - 2.0 * tan_dir).r;

		ray.rgb = params.sun_color.rgb;
		if (ray.r < ray.b)
			ray.rb = ray.br;

		ray.rgb *= 1.0 + params.misc_params.z * ray.a * ray.a * ray.a;
	}

	vec4 col = imageLoad(color_image, pixel);

	// Sun height visibility and weather occlusion (precomputed on CPU)
	float sun_height_vis = params.sun_params.w;
	float sun_weather_vis = params.extra_params.z;
	ray.a *= sun_height_vis * sun_weather_vis;

	// Composite rays (no HDR clamp — allow bloom interaction)
	float ray_occlude = params.ray_params2.w;
	col *= clamp(1.0 - ray_occlude * ray.a, 0.0, 1.0);
	col.rgb = max(col.rgb + ray.rgb * ray.a, vec3(0.0));

	// ── Sun disc ──
	if (forward < 0.0) {
		float light = params.extra_params.w;  // precomputed nice_weather * sun_vis
		float sun_height = params.sun_params.y;

		vec2 sun_uv = params.sun_screen_pos.xy;
		vec2 screen_offset = uv - sun_uv;
		screen_offset.y *= raspect;

		// Depth check: only in sky (reversed-Z: sky = 0.0, geometry > 1e-6)
		float depth = texture(tex_b, uv).r;
		float is_sky = step(depth, 1e-6);
		float disc_occl = light * is_sky;
		// Disc sharpness: higher = sharper edge. Precomputed fog_near_ratio affects this.
		float disc_radius = params.disc_params.x;
		float sharpness = mix(60.0, 660.0, clamp(sun_height + 0.5, 0.0, 1.0));
		disc_occl *= clamp(exp2(sharpness * (disc_radius - length(screen_offset))), 0.0, 1.0);

		if (disc_occl > 0.004) {
			vec3 sun_col_disc = vec3(1.0, 0.76 + 0.24 * sun_height, 0.54 + 0.46 * sun_height);
			float max_c = max(params.sun_color.r, max(params.sun_color.g, params.sun_color.b));
			vec3 norm_sun = (max_c > 0.0) ? params.sun_color.rgb / max_c : vec3(1.0);
			float desat = params.disc_params.z;
			sun_col_disc *= clamp(norm_sun * (1.0 - desat) + vec3(desat), 0.0, 1.0);

			float horizon_mult = params.misc_params.y;
			float horizon_boost = 1.0 + horizon_mult * min(
				smoothstep(-0.1, 0.05, sun_height),
				smoothstep(0.20, 0.05, sun_height)
			);

			vec3 scol = sun_col_disc * params.disc_params.y * horizon_boost;
			col.rgb = mix(col.rgb, scol, params.disc_params.w * disc_occl * horizon_boost);
		}
	}

	// Blend factor for enable/disable transitions
	vec4 original = imageLoad(color_image, pixel);
	col = mix(original, col, params.sun_color.a);

	imageStore(color_image, pixel, vec4(col.rgb, original.a));
}


// ═══════════════════════════════════════════════════════════════════
// Entry Point
// ═══════════════════════════════════════════════════════════════════

void main() {
	int pass_id = int(params.misc_params.w);
	if      (pass_id == PASS_SKY_MASK)    sky_mask();
	else if (pass_id == PASS_RADIAL_BLUR) radial_blur();
	else if (pass_id == PASS_RAYS)        compute_rays();
	else                                  combine();
}
