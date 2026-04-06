#[compute]
#version 450

// Underwater Compute Shader — Godotwind
//
// Single-pass post-process: caustics, absorption, wobble, rays, backscatter, boundary.
// Ported from Rafael & Hrnchamd's DIVE.omwfx (OpenMW).
//
// Matrices passed via storage buffer (binding 2) to avoid 128-byte push constant limit.
// Same depth reconstruction as volumetric_fog.glsl: inv_proj * clip → view, inv_view * view → world.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Bindings
layout(set = 0, binding = 0) uniform sampler2D depth_tex;
layout(rgba16f, set = 0, binding = 1) uniform image2D color_image;
layout(std430, set = 0, binding = 2) restrict readonly buffer CameraMatrices {
	mat4 inv_projection;
	mat4 inv_view;
} cam;

// Push constants: 128 bytes = 32 floats (Godot hard limit)
layout(push_constant, std430) uniform Params {
	vec4 camera_pos_sea;    // xyz = cam pos, w = sea_level
	vec4 sun_params;        // xyz = sun dir, w = sun_vis
	vec4 effect1;           // x=caustic, y=ray, z=wobble, w=absorption
	vec4 effect2;           // x=scatter, y=boundary, z=blend, w=TIME
	vec4 water_tint_dbg;    // rgb=tint, w=debug_mode
	vec4 screen;            // x=width, y=height, z=pad, w=pad
	vec4 caustic_params;    // x=surface_floor, y=aa_cutoff_near, z=aa_cutoff_far, w=reserved
	vec4 _pad1;
} pc;

#define cam_pos       pc.camera_pos_sea.xyz
#define sea_level     pc.camera_pos_sea.w
#define sun_dir       pc.sun_params.xyz
#define sun_vis       pc.sun_params.w
#define caustic_str   pc.effect1.x
#define ray_str       pc.effect1.y
#define wobble_str    pc.effect1.z
#define absorption    pc.effect1.w
#define scatter_str   pc.effect2.x
#define boundary_str  pc.effect2.y
#define blend_factor  pc.effect2.z
#define TIME          pc.effect2.w
#define water_tint    pc.water_tint_dbg.xyz
#define debug_mode    pc.water_tint_dbg.w
#define screen_w           pc.screen.x
#define screen_h           pc.screen.y
#define caustic_surf_floor pc.caustic_params.x
#define caustic_aa_far     pc.caustic_params.y
#define caustic_aa_near    pc.caustic_params.z


// ============================================================================
// DEPTH → WORLD POSITION (same as volumetric_fog.glsl)
// ============================================================================

vec3 get_world_position(vec2 uv, float depth) {
	vec4 clip_pos = vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec4 view_pos = cam.inv_projection * clip_pos;
	view_pos.xyz /= view_pos.w;
	vec4 world_pos = cam.inv_view * vec4(view_pos.xyz, 1.0);
	return world_pos.xyz;
}

float get_linear_depth(vec2 uv) {
	float depth = texture(depth_tex, uv).r;
	vec4 clip_pos = vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec4 view_pos = cam.inv_projection * clip_pos;
	view_pos.xyz /= view_pos.w;
	return -view_pos.z;
}


// ============================================================================
// HASH & NOISE
// ============================================================================

float hash3(vec3 p) {
	p += dot(p, vec3(0.7, 0.3, 0.5));
	p = fract(p * vec3(0.3183099, 0.3678794, 0.6065307));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float hash2(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float a = hash2(i);
	float b = hash2(i + vec2(1.0, 0.0));
	float c = hash2(i + vec2(0.0, 1.0));
	float d = hash2(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm_noise(vec2 p) {
	return value_noise(p) * 0.65 + value_noise(p * 2.1 + 17.3) * 0.35;
}


// ============================================================================
// CAUSTICS — Voronoi edge detection (from DIVE)
// ============================================================================

float get_caustic_edge(vec3 P) {
	P += sin(P * 0.9 + 1.7) * 0.125;
	P += sin(P.yzx * 1.7 + 2.3) * 0.08;
	vec3 Pi = floor(P);
	vec3 Pf = fract(P);

	float best = 1.0, second_best = 1.0, third_best = 1.0;

	for (int z = -1; z <= 1; z++)
	for (int y = -1; y <= 1; y++)
	for (int x = -1; x <= 1; x++) {
		vec3 off = vec3(x, y, z);
		vec3 cell = Pi + off;
		vec3 h = vec3(hash3(cell), hash3(cell.yzx), hash3(cell.zxy)) * 2.0 - 1.0;
		vec3 jitter = normalize(vec3(h.x + best, h.y + h.z * 0.5, h.z - h.x * 0.5)) * 0.5;
		float d = length(Pf - off - jitter);

		if (d < best) { third_best = second_best; second_best = best; best = d; }
		else if (d < second_best) { third_best = second_best; second_best = d; }
		else if (d < third_best) { third_best = d; }
	}

	float edge = (second_best - best) / 1.732;
	float tri_edge = (third_best - best) / 1.732;
	return mix(edge, 1.0, smoothstep(0.05, 0.8, tri_edge) * 0.5);
}

float compute_caustics(vec3 wp) {
	const float SCALE = 1.5;
	float t = TIME * 1.8;
	vec3 P = wp * SCALE;

	vec3 warp;
	warp.x = sin(t * 1.7 + wp.y * 0.13) * cos((t + 1.2) * 1.3 + wp.z * 0.12);
	warp.y = sin((t + 1.2) * 1.3 + wp.z * 0.13) * cos((t + 2.5) * 1.1 + wp.x * 0.12);
	warp.z = sin((t + 2.5) * 1.1 + wp.x * 0.13) * cos(t * 1.7 + wp.y * 0.12);
	warp *= 0.4;
	warp += vec3(cos(t * 1.07), sin(t * 1.13), cos(t * 0.97));
	warp += 0.25 * sin(P.yzx * 1.3 + t * 0.9);

	float diff = get_caustic_edge(warp * 0.12 + P);
	return 1.0 - smoothstep(-0.15, 0.12, diff);
}


// ============================================================================
// LIGHT RAYS
// ============================================================================

float compute_rays(vec3 view_dir, float pixel_dist) {
	// 3-shell volumetric ray approximation. Each shell is already depth-attenuated
	// via its own shell_pos.y, so no separate cam_depth factor is needed —
	// when the camera descends, all shells descend with it, and shell depth_atten
	// reduces each contribution naturally.
	const int SHELL_COUNT = 3;
	float ray_sum = 0.0;
	for (int i = 0; i < SHELL_COUNT; i++) {
		float shell_dist = 8.0 + float(i) * 12.0;
		vec3 shell_pos = cam_pos + view_dir * min(shell_dist, pixel_dist);

		float n = value_noise(shell_pos.xz * 0.03 + TIME * vec2(0.3, 0.15))
		        * value_noise(shell_pos.xz * 0.07 - TIME * vec2(0.2, 0.25));

		float depth_atten = exp(-(sea_level - shell_pos.y) * 0.04);
		float dist_fade = clamp(pixel_dist / max(shell_dist, 1.0), 0.0, 1.0);
		float sun_align = pow(max(0.0, dot(view_dir, sun_dir)), 2.0);
		float up_comp = max(0.0, view_dir.y) * 0.5;

		ray_sum += sqrt(n) * depth_atten * dist_fade * (sun_align + up_comp + 0.25);
	}
	// Normalize by shell count so adding shells doesn't blow up brightness.
	return ray_sum / float(SHELL_COUNT);
}


// ============================================================================
// RECONSTRUCT WORLD NORMAL
// ============================================================================

vec3 reconstruct_normal(vec2 uv) {
	vec2 texel = 1.0 / vec2(screen_w, screen_h);
	vec3 wp_c = get_world_position(uv, texture(depth_tex, uv).r);
	vec3 wp_r = get_world_position(uv + vec2(texel.x, 0.0), texture(depth_tex, uv + vec2(texel.x, 0.0)).r);
	vec3 wp_d = get_world_position(uv + vec2(0.0, texel.y), texture(depth_tex, uv + vec2(0.0, texel.y)).r);
	return normalize(cross(wp_d - wp_c, wp_r - wp_c));
}


// ============================================================================
// MAIN
// ============================================================================

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (pixel.x >= int(screen_w) || pixel.y >= int(screen_h))
		return;

	vec2 uv = (vec2(pixel) + 0.5) / vec2(screen_w, screen_h);
	float cam_depth = sea_level - cam_pos.y;
	float submersion = clamp(cam_depth / 2.0, 0.0, 1.0);

	vec4 scene_color = imageLoad(color_image, pixel);
	float raw_depth = texture(depth_tex, uv).r;
	vec3 world_pos = get_world_position(uv, raw_depth);
	float pixel_dist = length(world_pos - cam_pos);
	vec3 view_dir = normalize(world_pos - cam_pos);

	float water_depth = sea_level - world_pos.y;
	bool pixel_uw = water_depth > 0.0;
	float sun_fade = clamp(sun_dir.y + 0.2, 0.0, 1.0);

	// --- Debug modes ---
	int dbg = int(debug_mode);
	if (dbg == 1) {
		float d = clamp(water_depth / 30.0, -1.0, 1.0);
		imageStore(color_image, pixel, vec4(d > 0.0 ? mix(vec3(0,0,1), vec3(1,0,0), d) : vec3(0, 1.0+d, 0), 1.0));
		return;
	} else if (dbg == 2) {
		imageStore(color_image, pixel, vec4(0.0, clamp((world_pos.y+20.0)/40.0, 0.0, 1.0), 1.0-clamp((world_pos.y+20.0)/40.0, 0.0, 1.0), 1.0));
		return;
	} else if (dbg == 3) {
		imageStore(color_image, pixel, vec4(pixel_uw ? vec3(0,0.8,0.8) : vec3(0.8,0.8,0), 1.0));
		return;
	} else if (dbg == 4) {
		imageStore(color_image, pixel, vec4(vec3(compute_caustics(world_pos)), 1.0));
		return;
	} else if (dbg == 5) {
		imageStore(color_image, pixel, vec4(reconstruct_normal(uv) * 0.5 + 0.5, 1.0));
		return;
	} else if (dbg == 6) {
		float ld = get_linear_depth(uv);
		imageStore(color_image, pixel, vec4(vec3(clamp(ld / 100.0, 0.0, 1.0)), 1.0));
		return;
	} else if (dbg == 7) {
		// SENTINEL: dump inv_view[3].xyz (camera position) scaled
		// If storage buffer binds correctly, this shows a uniform color reflecting cam pos.
		// Camera at (0,-8,20) → r=0.5, g=0.42 (-8*0.01+0.5), b=0.7 (20*0.01+0.5)
		vec3 cam_in_mat = vec3(cam.inv_view[3].x, cam.inv_view[3].y, cam.inv_view[3].z);
		imageStore(color_image, pixel, vec4(cam_in_mat * 0.01 + 0.5, 1.0));
		return;
	} else if (dbg == 8) {
		// World-pos 10m bands. If depth reconstruction works, pixels show stationary
		// RGB bands every 10m in world space. Camera movement should not slide the bands.
		imageStore(color_image, pixel, vec4(fract(world_pos * 0.1), 1.0));
		return;
	} else if (dbg == 9) {
		// Raw depth buffer value as grayscale. Reversed-Z: near=white, far=black.
		imageStore(color_image, pixel, vec4(vec3(raw_depth), 1.0));
		return;
	} else if (dbg == 10) {
		// inv_proj diagonal sentinel: write inv_proj[0][0], [1][1], [2][2] as RGB.
		// Perspective inv: [0][0] ~1.0, [1][1] ~0.58, [2][2]=0 (reversed-Z), [3][2]=-1/near.
		// If all zero, matrices aren't reaching the shader.
		imageStore(color_image, pixel, vec4(
			cam.inv_projection[0][0],
			cam.inv_projection[1][1],
			cam.inv_projection[3][2] * 0.1 + 0.5,
			1.0));
		return;
	}

	if (cam_depth < -0.5 && !pixel_uw)
		return;

	vec3 color = scene_color.rgb;

	// --- Wobble ---
	if (wobble_str > 0.001) {
		vec2 wobble;
		wobble.x = fbm_noise(uv * 18.0 + vec2(TIME * 0.7, TIME * 0.3)) - 0.5;
		wobble.y = fbm_noise(uv * 18.0 + vec2(TIME * 0.3, TIME * 0.7) + 50.0) - 0.5;
		wobble *= wobble_str * submersion;
		vec2 ef = smoothstep(vec2(0.0), vec2(0.05), uv) * smoothstep(vec2(0.0), vec2(0.05), 1.0 - uv);
		wobble *= ef.x * ef.y;
		float d_here = get_linear_depth(uv);
		float d_there = get_linear_depth(uv + wobble);
		wobble *= 1.0 - smoothstep(0.1, 0.5, abs(d_here - d_there) / max(d_here, 0.1));
		ivec2 wp = clamp(ivec2((uv + wobble) * vec2(screen_w, screen_h)), ivec2(0), ivec2(screen_w-1, screen_h-1));
		color = imageLoad(color_image, wp).rgb;
	}

	// --- Absorption ---
	float travel = pixel_uw ? pixel_dist : max(pixel_dist - max(0.0, -cam_depth), 0.0);
	vec3 sigma = absorption * (1.0 - water_tint);
	vec3 abs_col = water_tint * (0.8 + 1.4 * sun_fade * sun_vis);
	color = mix(abs_col, color, min(vec3(0.85), exp(-sigma * travel)));

	// --- Caustics ---
	// Caustics are driven by water column depth, NOT observer distance.
	// Previously multiplied by dist_fade which crushed caustics into invisibility.
	// The anti-alias cutoff below is a shimmer guard, not a physical falloff:
	// past ~80m the caustic pattern frequency exceeds the pixel rate and aliases badly.
	if (caustic_str > 0.01 && cam_depth > 0.0 && pixel_uw) {
		float caustic = compute_caustics(world_pos);
		float depth_fade = exp(-water_depth * 0.02);
		vec3 wn = reconstruct_normal(uv);
		float surf = max(wn.y, caustic_surf_floor);
		float aa_cutoff = smoothstep(caustic_aa_far, caustic_aa_near, pixel_dist);
		color += caustic * caustic_str * depth_fade * surf * sun_fade * aa_cutoff
		       * vec3(0.8, 0.95, 1.0);
	}

	// --- Depth fog ---
	if (pixel_uw) {
		float fog = clamp(pixel_dist / 80.0, 0.0, 1.0);
		float dl = exp((mix(world_pos.y, cam_pos.y, 0.5) - sea_level) * 0.003);
		color = mix(color, water_tint * 2.5, fog * 0.4 * clamp(sun_vis * 4.0, 0.15, 1.0) * dl);
	}

	// --- Light rays ---
	if (ray_str > 0.01 && sun_fade > 0.01) {
		float rays = compute_rays(view_dir, pixel_dist);
		float lf = 0.2 + 0.8 * sun_vis;
		color += rays * ray_str * lf * vec3(0.6, 0.91, 1.0) * submersion;
	}

	// --- Backscatter ---
	// Base color bumped 4x from (0.05, 0.10, 0.13) to match DIVE.omwfx visible range.
	// Previously crushed by compound attenuation into invisibility.
	if (scatter_str > 0.01 && pixel_uw) {
		vec3 wn = reconstruct_normal(uv);
		float vf = pow(clamp(dot(normalize(cam_pos - world_pos), wn), 0.0, 1.0), 1.5);
		float sa = (1.0 - exp(-water_depth * 0.08)) * scatter_str;
		float df = 1.0 - smoothstep(0.0, 100.0, pixel_dist);
		color += vec3(0.20, 0.40, 0.52) * vf * sa * df * smoothstep(-0.5, 0.3, sun_dir.y) * 2.0;
	}

	// --- Boundary ---
	if (boundary_str > 0.001 && abs(cam_depth) < 2.0 && abs(view_dir.y) > 0.001) {
		float t_water = (sea_level - cam_pos.y) / view_dir.y;
		if (t_water > 0.0) {
			float bf = exp(-abs(t_water / max(pixel_dist, 0.01) - 1.0) * 15.0)
			         * exp(-abs(cam_depth) * 1.5);
			if (bf > 0.01) {
				vec2 bw;
				bw.x = fbm_noise(uv * 25.0 + TIME * vec2(1.3, 0.7)) - 0.5;
				bw.y = fbm_noise(uv * 25.0 + TIME * vec2(0.7, 1.3) + 100.0) - 0.5;
				bw *= boundary_str * bf;
				ivec2 bp = clamp(ivec2((uv + bw) * vec2(screen_w, screen_h)), ivec2(0), ivec2(screen_w-1, screen_h-1));
				vec3 bs = imageLoad(color_image, bp).rgb;
				color = mix(color, mix(bs, vec3(0.6, 0.85, 0.95), 0.5 * bf), bf * 0.9);
			}
		}
	}

	// --- Dithering ---
	float dither = fract(52.9829189 * fract(0.06711056 * float(pixel.x) + 0.00583715 * float(pixel.y)));
	color += vec3(dither * 2.0 - 1.0) / 255.0;

	imageStore(color_image, pixel, vec4(color, scene_color.a));
}
