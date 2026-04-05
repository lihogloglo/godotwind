shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, fog_disabled;

/**
 * Underwater Post-Process Shader — Godotwind
 *
 * Full-screen post-process applied when camera is submerged.
 * Ported from Rafael & Hrnchamd's DIVE.omwfx (OpenMW) with Godot adaptations.
 *
 * Features:
 * - Voronoi caustics projected onto underwater surfaces
 * - Exponential depth absorption (Beer-Lambert)
 * - Screen UV wobble from animated water normals
 * - Shell-based volumetric light rays
 * - Backscattering (view-dependent light transmission)
 * - Water boundary effect (partial submersion waterline)
 * - Interleaved gradient noise dithering (anti-banding)
 *
 * Attached to a full-screen quad parented to the camera.
 * Reads SCREEN_TEXTURE + DEPTH_TEXTURE for post-processing.
 */

// Screen sampling
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;

// Water parameters (set by UnderwaterEffect.gd)
group_uniforms water;
uniform float sea_level = 0.0;
uniform vec3 camera_world_pos = vec3(0.0);
uniform vec3 water_tint = vec3(0.015, 0.115, 0.145);

// Sun/lighting
group_uniforms lighting;
uniform vec3 sun_direction = vec3(0.3, 0.8, 0.2);
uniform float sun_visibility = 1.0;
uniform vec3 sun_color = vec3(1.0, 0.95, 0.85);

// Effect intensities
group_uniforms effects;
uniform float caustic_intensity : hint_range(0.0, 3.0) = 1.2;
uniform float ray_intensity : hint_range(0.0, 3.0) = 0.8;
uniform float wobble_strength : hint_range(0.0, 0.05) = 0.012;
uniform float absorption_rate : hint_range(0.0005, 0.01) = 0.0015;
uniform float backscatter_strength : hint_range(0.0, 1.0) = 0.55;
uniform float dither_strength : hint_range(0.0, 5.0) = 1.0;

// Boundary effect
group_uniforms boundary;
uniform float boundary_distortion : hint_range(0.0, 0.1) = 0.03;
uniform float boundary_thickness : hint_range(0.5, 5.0) = 2.0;
uniform vec3 boundary_highlight_color : source_color = vec3(0.6, 0.85, 0.95);

// Debug: 0=off, 1=water_depth heatmap, 2=world_pos.y, 3=pixel_underwater mask,
//        4=caustic pattern, 5=world normal, 6=linear depth
group_uniforms debug;
uniform int debug_mode : hint_range(0, 6) = 0;

// ============================================================================
// WORLD POSITION RECONSTRUCTION
// Built-in matrices (INV_PROJECTION_MATRIX, INV_VIEW_MATRIX) are only available
// in vertex/fragment/light — must be passed as parameters to helper functions.
// ============================================================================

vec3 reconstruct_world_pos(vec2 screen_uv, mat4 inv_proj, mat4 inv_view) {
	float depth_raw = textureLod(depth_texture, screen_uv, 0.0).r;
	vec4 ndc = vec4(screen_uv * 2.0 - 1.0, depth_raw, 1.0);
	vec4 view_pos = inv_proj * ndc;
	view_pos.xyz /= view_pos.w;
	return (inv_view * vec4(view_pos.xyz, 1.0)).xyz;
}

float get_linear_depth(vec2 screen_uv, mat4 inv_proj) {
	float depth_raw = textureLod(depth_texture, screen_uv, 0.0).r;
	vec4 ndc = vec4(screen_uv * 2.0 - 1.0, depth_raw, 1.0);
	vec4 view_pos = inv_proj * ndc;
	view_pos.xyz /= view_pos.w;
	return -view_pos.z;
}

// ============================================================================
// RECONSTRUCT WORLD NORMAL (from depth buffer derivatives)
// ============================================================================

vec3 reconstruct_world_normal(vec2 screen_uv, mat4 inv_proj, mat4 inv_view) {
	vec3 wp_c = reconstruct_world_pos(screen_uv, inv_proj, inv_view);
	vec2 texel = vec2(1.0) / vec2(textureSize(depth_texture, 0));
	vec3 wp_r = reconstruct_world_pos(screen_uv + vec2(texel.x, 0.0), inv_proj, inv_view);
	vec3 wp_d = reconstruct_world_pos(screen_uv + vec2(0.0, texel.y), inv_proj, inv_view);
	vec3 dx = wp_r - wp_c;
	vec3 dy = wp_d - wp_c;
	return normalize(cross(dy, dx));
}

// ============================================================================
// HASH & NOISE
// ============================================================================

float hash3(vec3 p) {
	p += dot(p, vec3(0.7, 0.3, 0.5));
	p = fract(p * vec3(0.3183099, 0.3678794, 0.6065307));
	p = p * 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

// Integer-based hash (avoids sin() precision issues)
float hash2(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// Smooth 2D value noise with quintic interpolation
float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	// Quintic Hermite — smoother than cubic, avoids blocky patterns
	f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float a = hash2(i);
	float b = hash2(i + vec2(1.0, 0.0));
	float c = hash2(i + vec2(0.0, 1.0));
	float d = hash2(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// FBM noise (2 octaves) for smoother wobble
float fbm_noise(vec2 p) {
	float val = value_noise(p) * 0.65;
	val += value_noise(p * 2.1 + 17.3) * 0.35;
	return val;
}

// ============================================================================
// CAUSTICS — Voronoi cell edge detection (from DIVE)
// ============================================================================

float get_caustic_edge(vec3 P) {
	P += sin(P * 0.9 + 1.7) * 0.125;
	P += sin(P.yzx * 1.7 + 2.3) * 0.08;
	vec3 Pi = floor(P);
	vec3 Pf = fract(P);

	float best = 1.0;
	float second_best = 1.0;
	float third_best = 1.0;

	for (int z = -1; z <= 1; z++) {
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				vec3 off = vec3(float(x), float(y), float(z));
				vec3 cell = Pi + off;
				vec3 h = vec3(hash3(cell), hash3(cell.yzx), hash3(cell.zxy));
				h = h * 2.0 - 1.0;
				vec3 jitter = normalize(vec3(h.x + best, h.y + h.z * 0.5, h.z - h.x * 0.5)) * 0.5;
				vec3 site = off + jitter;
				float d = length(Pf - site);

				if (d < best) {
					third_best = second_best;
					second_best = best;
					best = d;
				} else if (d < second_best) {
					third_best = second_best;
					second_best = d;
				} else if (d < third_best) {
					third_best = d;
				}
			}
		}
	}

	float edge = (second_best - best) / 1.732;
	float tri_edge = (third_best - best) / 1.732;
	float pinch = smoothstep(0.05, 0.8, tri_edge);
	return mix(edge, 1.0, pinch * 0.5);
}

float compute_caustics(vec3 world_pos, float time) {
	const float SCALE = 1.5;  // ~0.67m cells — Godot meters, not MW units
	const float FREQ = 1.8;
	const float WARP_AMT = 0.15 / SCALE * 0.5;

	vec3 P = world_pos * SCALE;
	float t = time * FREQ;
	float t1 = t * 1.7;
	float t2 = (t + 1.2) * 1.3;
	float t3 = (t + 2.5) * 1.1;

	vec3 warp;
	warp.x = sin(t1 + world_pos.y * 0.13) * cos(t2 + world_pos.z * 0.12);
	warp.y = sin(t2 + world_pos.z * 0.13) * cos(t3 + world_pos.x * 0.12);
	warp.z = sin(t3 + world_pos.x * 0.13) * cos(t1 + world_pos.y * 0.12);
	warp *= 0.4;
	warp.x += cos(t * 1.07);
	warp.y += sin(t * 1.13);
	warp.z += cos(t * 0.97);
	warp += 0.25 * sin(P.yzx * 1.3 + t * 0.9);

	float diff = get_caustic_edge(warp * WARP_AMT + P);
	// Sharper threshold than DIVE defaults for more visible pattern
	float edge = smoothstep(-0.15, 0.12, diff);
	return 1.0 - edge;
}

// ============================================================================
// LIGHT RAYS — Shell-based volumetric beams (scaled for near geometry)
// ============================================================================

float compute_rays(vec3 cam_pos, vec3 view_dir, float pixel_dist, float time) {
	float ray_sum = 0.0;

	// 3 shells at distances scaled to near-field geometry
	for (int i = 0; i < 3; i++) {
		float shell_dist = 8.0 + float(i) * 12.0;
		float sample_dist = min(shell_dist, pixel_dist);
		vec3 shell_pos = cam_pos + view_dir * sample_dist;

		// Two-octave noise for organic rays
		float n1 = value_noise(shell_pos.xz * 0.03 + time * vec2(0.3, 0.15));
		float n2 = value_noise(shell_pos.xz * 0.07 - time * vec2(0.2, 0.25));
		float noise_val = n1 * n2;

		// Depth attenuation — exponential fade below surface
		float depth_below = sea_level - shell_pos.y;
		float depth_atten = exp(-depth_below * 0.04);

		// Distance fade
		float dist_fade = clamp(pixel_dist / max(shell_dist, 1.0), 0.0, 1.0);

		// Directional component: stronger toward sun, but always present
		float sun_align = max(0.0, dot(view_dir, sun_direction));
		sun_align = pow(sun_align, 2.0);
		float up_factor = max(0.0, view_dir.y) * 0.5;
		// Ambient ray component: scattered light is omnidirectional underwater
		// This ensures rays are visible in all view directions
		float ambient_ray = 0.25;

		ray_sum += sqrt(noise_val) * depth_atten * dist_fade * (sun_align + up_factor + ambient_ray);
	}

	// Fade rays deeper underwater
	float cam_depth_val = sea_level - cam_pos.y;
	float deep_fade = exp(-cam_depth_val * 0.025);
	return ray_sum * deep_fade;
}

// ============================================================================
// DITHERING — Interleaved Gradient Noise (anti-banding)
// ============================================================================

float interleaved_gradient_noise(vec2 uv) {
	float noise = fract(52.9829189 * fract(0.06711056 * uv.x + 0.00583715 * uv.y));
	return noise * 2.0 - 1.0;
}

// ============================================================================
// MAIN FRAGMENT
// ============================================================================

void fragment() {
	float cam_depth = sea_level - camera_world_pos.y;
	float submersion_factor = clamp(cam_depth / 2.0, 0.0, 1.0);

	// --- Screen wobble ---
	vec2 uv = SCREEN_UV;
	vec2 wobble = vec2(0.0);
	if (wobble_strength > 0.001) {
		float t = TIME;
		// Higher frequency FBM noise for smooth, non-blocky distortion
		wobble.x = fbm_noise(uv * 18.0 + vec2(t * 0.7, t * 0.3)) - 0.5;
		wobble.y = fbm_noise(uv * 18.0 + vec2(t * 0.3, t * 0.7) + 50.0) - 0.5;
		wobble *= wobble_strength * submersion_factor;
		// Edge fade
		vec2 edge_fade = smoothstep(vec2(0.0), vec2(0.05), uv) * smoothstep(vec2(0.0), vec2(0.05), 1.0 - uv);
		wobble *= edge_fade.x * edge_fade.y;

		// Depth-discontinuity fade: reduce wobble where depth changes sharply
		// This prevents the blocky pattern at the water surface horizon
		float depth_c = get_linear_depth(uv, INV_PROJECTION_MATRIX);
		float depth_near = get_linear_depth(uv + wobble, INV_PROJECTION_MATRIX);
		float depth_diff = abs(depth_c - depth_near) / max(depth_c, 0.1);
		float depth_fade = 1.0 - smoothstep(0.1, 0.5, depth_diff);
		wobble *= depth_fade;
	}
	vec2 sample_uv = clamp(uv + wobble, vec2(0.001), vec2(0.999));

	// --- Read scene color and reconstruct world position ---
	vec4 scene_color = texture(screen_texture, sample_uv);
	vec3 world_pos = reconstruct_world_pos(sample_uv, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX);
	float linear_depth = get_linear_depth(sample_uv, INV_PROJECTION_MATRIX);
	float pixel_dist = length(world_pos - camera_world_pos);
	vec3 view_dir = normalize(world_pos - camera_world_pos);

	// Water depth: positive = below surface
	float water_depth = sea_level - world_pos.y;
	bool pixel_underwater = water_depth > 0.0;

	// --- Debug modes ---
	if (debug_mode == 1) {
		// Water depth heatmap: blue=shallow, red=deep
		float d = clamp(water_depth / 30.0, -1.0, 1.0);
		ALBEDO = d > 0.0 ? mix(vec3(0,0,1), vec3(1,0,0), d) : vec3(0, 1.0 + d, 0);
		ALPHA = 1.0;
	} else if (debug_mode == 2) {
		// World Y position: green=high, blue=low
		float y = clamp((world_pos.y + 20.0) / 40.0, 0.0, 1.0);
		ALBEDO = vec3(0.0, y, 1.0 - y);
		ALPHA = 1.0;
	} else if (debug_mode == 3) {
		// Pixel underwater mask: cyan=underwater, yellow=above
		ALBEDO = pixel_underwater ? vec3(0, 0.8, 0.8) : vec3(0.8, 0.8, 0);
		ALPHA = 1.0;
	} else if (debug_mode == 4) {
		// Raw caustic pattern (regardless of depth gates)
		float c = compute_caustics(world_pos, TIME);
		ALBEDO = vec3(c);
		ALPHA = 1.0;
	} else if (debug_mode == 5) {
		// World normal
		vec3 wn = reconstruct_world_normal(sample_uv, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX);
		ALBEDO = wn * 0.5 + 0.5;
		ALPHA = 1.0;
	} else if (debug_mode == 6) {
		// Linear depth (white=far, black=near)
		float d = clamp(linear_depth / 100.0, 0.0, 1.0);
		ALBEDO = vec3(d);
		ALPHA = 1.0;
	} else {

	// ========================================================================
	// NORMAL RENDERING PATH
	// ========================================================================

	// Camera at waterline — boundary effect
	float boundary_factor = 0.0;
	if (abs(cam_depth) < boundary_thickness && boundary_distortion > 0.001) {
		// Simple approach: use screen-space Y position where the water plane
		// would intersect the view. For a flat water plane at sea_level,
		// project (camera + forward * t) where t solves ray.y = sea_level.
		if (abs(view_dir.y) > 0.001) {
			float t_hit = (sea_level - camera_world_pos.y) / view_dir.y;
			if (t_hit > 0.0) {
				// Compare pixel depth to intersection depth
				float t_ratio = t_hit / max(pixel_dist, 0.01);
				// Boundary band: pixels near the water plane intersection
				float proximity = 1.0 - clamp(abs(t_ratio - 1.0) * 10.0, 0.0, 1.0);
				boundary_factor = proximity * smoothstep(0.0, 1.0, 1.0 - abs(cam_depth) / boundary_thickness);
			}
		}
	}

	// Skip flag: camera well above water AND pixel above water
	bool skip_effects = (cam_depth < -0.5 && !pixel_underwater);
	float effect_strength = skip_effects ? 0.0 : submersion_factor;
	if (!pixel_underwater && cam_depth > 0.0) {
		effect_strength *= 0.1;
	}

	vec3 color = scene_color.rgb;
	float sun_fade = clamp(sun_direction.y + 0.2, 0.0, 1.0);

	// --- Absorption (Beer-Lambert) ---
	if (!skip_effects) {
		float travel_dist = pixel_underwater ? pixel_dist : max(pixel_dist - max(0.0, -cam_depth), 0.0);
		vec3 sigma = absorption_rate * (1.0 - water_tint);
		vec3 absorption_color = water_tint * (0.8 + 1.4 * sun_fade * sun_visibility);
		color = mix(absorption_color, color, min(vec3(0.85), exp(-sigma * travel_dist)));
	}

	// --- Reconstruct world normal ---
	vec3 world_normal = vec3(0.0, 1.0, 0.0);
	if (!skip_effects && (caustic_intensity > 0.01 || backscatter_strength > 0.01)) {
		world_normal = reconstruct_world_normal(sample_uv, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX);
	}

	// --- Caustics ---
	// Apply to any pixel where camera is submerged — not just pixel_underwater.
	// Looking up at the ocean surface from below also gets caustic light.
	if (!skip_effects && caustic_intensity > 0.01 && cam_depth > 0.0) {
		const vec3 CAUSTICS_COLOR = vec3(0.8, 0.95, 1.0);
		float caustic = compute_caustics(world_pos, TIME);

		// Depth fade: strongest near the surface, fades deeper
		float depth_fade = pixel_underwater ? exp(-water_depth * 0.02) : 1.0;
		// Upward-facing surfaces receive more, but don't fully zero out others
		float surface_factor = clamp(world_normal.y * 0.5 + 0.7, 0.2, 1.0);
		// Distance fade
		float dist_fade = exp(-pixel_dist * 0.005);

		color += caustic * caustic_intensity * depth_fade * surface_factor * dist_fade * sun_fade * CAUSTICS_COLOR;
	}

	// --- Depth fog (light penetration from DIVE) ---
	// Apply AFTER caustics so fog doesn't erase them entirely
	if (!skip_effects && pixel_underwater) {
		float fog_coverage = clamp(pixel_dist / 80.0, 0.0, 1.0);
		float avg_depth = mix(world_pos.y, camera_world_pos.y, 0.5);
		float depth_light = exp((avg_depth - sea_level) * 0.003);
		// Reduced fog blend to preserve caustics and other effects
		color = mix(color, water_tint * 2.5, fog_coverage * 0.4 * clamp(sun_visibility * 4.0, 0.15, 1.0) * depth_light);
	}

	// --- Light rays ---
	// Rays are visible in ALL directions: ambient scattered light from surface,
	// stronger when looking toward or away from the sun
	if (!skip_effects && ray_intensity > 0.01 && sun_fade > 0.01) {
		float rays = compute_rays(camera_world_pos, view_dir, pixel_dist, TIME);
		vec3 ray_color = vec3(0.6, 0.91, 1.0) * sun_color;
		float lf = (0.2 + 0.8 * sun_visibility) * dot(sun_color, vec3(0.32, 0.47, 0.21));
		color += rays * ray_intensity * lf * ray_color * effect_strength;
	}

	// --- Backscattering ---
	if (!skip_effects && backscatter_strength > 0.01 && pixel_underwater) {
		const vec3 scatter_tint = vec3(0.05, 0.10, 0.13);
		float view_factor = pow(clamp(dot(normalize(camera_world_pos - world_pos), world_normal), 0.0, 1.0), 1.5);
		float scatter_amount = (1.0 - exp(-water_depth * 0.08)) * backscatter_strength;
		float dist_fade = 1.0 - smoothstep(0.0, 100.0, pixel_dist);
		color += scatter_tint * view_factor * scatter_amount * dist_fade * smoothstep(-0.5, 0.3, sun_direction.y) * 2.0;
	}

	// --- Water boundary highlight ---
	// Simplified: detect waterline via screen-space Y where the water plane
	// intersects the view frustum. Show highlight band at that Y position.
	if (boundary_distortion > 0.001 && abs(cam_depth) < boundary_thickness) {
		// For each pixel, check if its view ray is near the water plane intersection
		float ray_y = view_dir.y;
		if (abs(ray_y) > 0.001) {
			float t_water = (sea_level - camera_world_pos.y) / ray_y;
			// Boundary band: screen-space proximity to the waterline
			if (t_water > 0.0) {
				float depth_ratio = t_water / max(pixel_dist, 0.01);
				// Tight band around where geometry depth matches waterline depth
				float band = exp(-abs(depth_ratio - 1.0) * 15.0);
				// Also add a Fresnel-like glow based on how close to the surface plane
				float surface_prox = exp(-abs(cam_depth) / boundary_thickness * 3.0);
				float bf = band * surface_prox;
				if (bf > 0.01) {
					vec2 bw = vec2(
						fbm_noise(SCREEN_UV * 25.0 + TIME * vec2(1.3, 0.7)) - 0.5,
						fbm_noise(SCREEN_UV * 25.0 + TIME * vec2(0.7, 1.3) + 100.0) - 0.5
					) * boundary_distortion * bf;
					vec4 bsample = texture(screen_texture, clamp(sample_uv + bw, vec2(0.001), vec2(0.999)));
					vec3 highlight = mix(bsample.rgb, boundary_highlight_color, 0.5 * bf);
					color = mix(color, highlight, bf * 0.9);
				}
			}
		}
	}

	// --- Dithering ---
	vec2 screen_res = vec2(textureSize(depth_texture, 0));
	float dither = interleaved_gradient_noise(SCREEN_UV * screen_res) * dither_strength / 255.0;
	color += vec3(dither, -dither, dither);

	ALBEDO = color;
	ALPHA = 1.0;

	} // end else (non-debug path)
}
