shader_type spatial;
render_mode world_vertex_coords, depth_draw_always;

/**
 * Ocean water shader with FFT wave displacement
 * Based on: https://github.com/ManickYoj/godot-ocean-waves-buoyancy
 * Lighting model from GDC 2019: "Wakes, Explosions and Lighting: Interactive Water Simulation in Atlas"
 */

#define MAX_CASCADES 8
#define REFLECTANCE  0.02

// Water appearance
uniform vec4 water_color : source_color = vec4(0.02, 0.08, 0.15, 1.0);
uniform vec4 foam_color : source_color = vec4(0.9, 0.9, 0.9, 1.0);
uniform vec3 depth_color_consumption = vec3(7.5, 22.0, 38.0);

// Material properties
uniform float roughness : hint_range(0.0, 1.0) = 0.4;
uniform float normal_strength : hint_range(0.0, 1.0) = 1.0;

// Time
uniform float time = 0.0;

// Textures
uniform sampler2D foam_noise_tex : repeat_enable, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

// Shore mask
uniform sampler2D shore_mask : filter_linear;
uniform vec4 shore_mask_bounds = vec4(-8000.0, -8000.0, 16000.0, 16000.0);

// Wave cascade data
uniform vec4 map_scales[MAX_CASCADES];
uniform uint num_cascades = 3u;
uniform sampler2DArray displacements;
uniform sampler2DArray normals : hint_normal;

// Varyings
varying float wave_height;
varying float foam_factor;
varying float fresnel;
varying float shore_factor;

// Sample shore mask at world position
float sample_shore_mask(vec2 world_xz) {
	vec2 uv = (world_xz - shore_mask_bounds.xy) / shore_mask_bounds.zw;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		return 0.0; // Outside bounds = no ocean
	}
	return texture(shore_mask, uv).r;
}

// Gerstner wave fallback (when no displacement textures)
vec3 gerstner_wave(vec2 pos, float wavelength, float steepness, vec2 direction, float t) {
	float k = 2.0 * PI / wavelength;
	float c = sqrt(9.81 / k);
	vec2 d = normalize(direction);
	float f = k * (dot(d, pos) - c * t);
	float a = steepness / k;
	return vec3(
		d.x * (a * cos(f)),
		a * sin(f),
		d.y * (a * cos(f))
	);
}

void vertex() {
	UV = VERTEX.xz;

	// Sample shore mask
	shore_factor = sample_shore_mask(VERTEX.xz);

	// Initialize wave_height
	wave_height = 0.0;

	// Only apply displacement if in ocean area
	if (shore_factor >= 0.01) {
		float distance_cam = length(VERTEX.xz - CAMERA_POSITION_WORLD.xz);

		if (distance_cam < 1024.0) {
			float distance_factor = min(exp(-(distance_cam - 512.0) * 0.007), 1.0);
			vec3 displacement = vec3(0);

			// Check if we have displacement textures
			if (num_cascades > 0u && textureSize(displacements, 0).x > 1) {
				// FFT displacement from textures
				for (uint i = 0u; i < num_cascades; ++i) {
					vec4 scales = map_scales[i];
					displacement += texture(displacements, vec3(UV * scales.xy, float(i))).xyz * scales.z;
				}
			} else {
				// Gerstner fallback
				displacement += gerstner_wave(UV, 60.0, 0.25, vec2(1.0, 0.0), time);
				displacement += gerstner_wave(UV, 31.0, 0.25, vec2(1.0, 0.6), time);
				displacement += gerstner_wave(UV, 18.0, 0.25, vec2(1.0, 1.3), time);
				displacement += gerstner_wave(UV, 8.0, 0.15, vec2(0.5, 1.0), time);
			}

			// Apply shore dampening to displacement
			displacement *= shore_factor;

			VERTEX += displacement * distance_factor;
			wave_height = displacement.y;
		}
	}
}

// Bicubic B-spline weights
vec4 cubic_weights(float a) {
	float a2 = a * a;
	float a3 = a2 * a;
	float w0 = -a3 + a2 * 3.0 - a * 3.0 + 1.0;
	float w1 = a3 * 3.0 - a2 * 6.0 + 4.0;
	float w2 = -a3 * 3.0 + a2 * 3.0 + a * 3.0 + 1.0;
	float w3 = a3;
	return vec4(w0, w1, w2, w3) / 6.0;
}

// Bicubic texture sampling for smooth normals
vec4 texture_bicubic(in sampler2DArray sampler, in vec3 uvw) {
	vec2 dims = vec2(textureSize(sampler, 0).xy);
	vec2 dims_inv = 1.0 / dims;
	uvw.xy = uvw.xy * dims + 0.5;
	vec2 fuv = fract(uvw.xy);
	vec4 wx = cubic_weights(fuv.x);
	vec4 wy = cubic_weights(fuv.y);
	vec4 g = vec4(wx.xz + wx.yw, wy.xz + wy.yw);
	vec4 h = (vec4(wx.yw, wy.yw) / g + vec2(-1.5, 0.5).xyxy + floor(uvw.xy).xxyy) * dims_inv.xxyy;
	vec2 w = g.xz / (g.xz + g.yw);
	return mix(
		mix(texture(sampler, vec3(h.yw, uvw.z)), texture(sampler, vec3(h.xw, uvw.z)), w.x),
		mix(texture(sampler, vec3(h.yz, uvw.z)), texture(sampler, vec3(h.xz, uvw.z)), w.x), w.y);
}

void fragment() {
	// If not in ocean, discard the fragment
	if (shore_factor < 0.01) {
		discard;
	}

	float map_size = float(textureSize(normals, 0).x);
	float dist = length(VERTEX.xz);
	vec3 gradient = vec3(0);
	float foam_alpha = 0.0;

	// Sample normal maps
	if (num_cascades > 0u && map_size > 1.0) {
		for (uint i = 0u; i < num_cascades; ++i) {
			vec4 scales = map_scales[i];
			vec3 coords = vec3(UV * scales.xy, float(i));
			float ppm = map_size * min(scales.x, scales.y);
			gradient += mix(texture_bicubic(normals, coords), texture(normals, coords), min(1.0, ppm * 0.1)).xyw * vec3(scales.ww, 1.0);
			foam_alpha += texture(foam_noise_tex, UV * scales.xy * 1.0).r;
		}
	} else {
		// Fallback: calculate normal from wave height gradient
		float eps = 0.5;
		vec3 wave0 = gerstner_wave(UV, 60.0, 0.25, vec2(1.0, 0.0), time);
		vec3 wave_dx = gerstner_wave(UV + vec2(eps, 0), 60.0, 0.25, vec2(1.0, 0.0), time);
		vec3 wave_dz = gerstner_wave(UV + vec2(0, eps), 60.0, 0.25, vec2(1.0, 0.0), time);
		gradient = vec3((wave_dx.y - wave0.y) / eps, 1.0, (wave_dz.y - wave0.y) / eps);
	}

	foam_factor = smoothstep(0.0, 1.0, gradient.z * 0.75) * exp(-dist * 0.0075);

	// Increase foam near shore
	foam_factor += (1.0 - shore_factor) * 0.5;
	foam_factor = clamp(foam_factor, 0.0, 1.0);

	// Depth-based effects
	float depth_tex = texture(depth_texture, SCREEN_UV).r;
	vec4 world_pos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth_tex, 1.0);
	world_pos.xyz /= world_pos.w;
	float smooth_alpha = 1.0 - smoothstep(world_pos.z + 0.66, world_pos.z, VERTEX.z);
	ALPHA = clamp(smooth_alpha * shore_factor, 0.0, 1.0);

	if (ALPHA < 0.9) {
		foam_factor = clamp(foam_factor + 0.5 - ALPHA, 0.0, 1.0);
	}

	// Depth-based color absorption
	float depth_visibility_range = clamp(max(depth_color_consumption.r, max(depth_color_consumption.g, depth_color_consumption.b)), 0.0, 200.0);
	float factor_translucency = 1.0 - smoothstep(world_pos.z + depth_visibility_range, world_pos.z, VERTEX.z);
	factor_translucency = clamp(factor_translucency, 0.35, 1.0);
	vec3 screen_albedo = texture(screen_texture, SCREEN_UV, 0.0).rgb;
	vec3 depth_water_color = mix(screen_albedo, water_color.rgb, factor_translucency);

	// Color absorption per channel
	float smooth_red = smoothstep(world_pos.z + depth_color_consumption.r, world_pos.z, VERTEX.z);
	float smooth_green = smoothstep(world_pos.z + depth_color_consumption.g, world_pos.z, VERTEX.z);
	float smooth_blue = smoothstep(world_pos.z + depth_color_consumption.b, world_pos.z, VERTEX.z);
	vec3 color_shallow = max(vec3(smooth_red, smooth_green, smooth_blue) * depth_water_color, water_color.rgb);

	depth_water_color = mix(color_shallow, water_color.rgb, factor_translucency);
	ALBEDO = mix(depth_water_color, foam_color.rgb, foam_factor * foam_alpha * foam_alpha);

	// Fresnel
	fresnel = mix(pow(1.0 - dot(VIEW, NORMAL), 5.0 * exp(-2.69 * roughness)) / (1.0 + 22.7 * pow(roughness, 1.5)), 1.0, REFLECTANCE);
	ROUGHNESS = (1.0 - fresnel) * foam_factor + 0.4;

	// Normal
	gradient *= mix(0.015, normal_strength, exp(-dist * 0.0175));
	NORMAL = (VIEW_MATRIX * vec4(normalize(vec3(-gradient.x, 1.0, -gradient.y)), 0.0)).xyz;
}

// Smith masking-shadowing function
float smith_masking_shadowing(in float cos_theta, in float alpha) {
	float a = cos_theta / (alpha * sqrt(1.0 - cos_theta * cos_theta));
	float a_sq = a * a;
	return a < 1.6 ? (1.0 - 1.259 * a + 0.396 * a_sq) / (3.535 * a + 2.181 * a_sq) : 0.0;
}

// GGX distribution
float ggx_distribution(in float cos_theta, in float alpha) {
	float a_sq = alpha * alpha;
	float d = 1.0 + (a_sq - 1.0) * cos_theta * cos_theta;
	return a_sq / (PI * d * d);
}

void light() {
	vec3 halfway = normalize(LIGHT + VIEW);
	float dot_nl = max(dot(NORMAL, LIGHT), 2e-5);
	float dot_nv = max(dot(NORMAL, VIEW), 2e-5);

	// Specular
	float light_mask = smith_masking_shadowing(roughness, dot_nv);
	float view_mask = smith_masking_shadowing(roughness, dot_nl);
	float microfacet_distribution = ggx_distribution(dot(NORMAL, halfway), roughness);
	float geometric_attenuation = 1.0 / (1.0 + light_mask + view_mask);
	SPECULAR_LIGHT += fresnel * microfacet_distribution * geometric_attenuation / (4.0 * dot_nv + 0.1) * ATTENUATION;

	// Subsurface scattering
	const vec3 sss_modifier = vec3(0.9, 1.15, 0.85);
	float sss_height = 1.0 * max(0.0, wave_height + 2.5) * pow(max(dot(LIGHT, -VIEW), 0.0), 4.0) * pow(0.5 - 0.5 * dot(LIGHT, NORMAL), 3.0);
	float sss_near = 0.5 * pow(dot_nv, 2.0);
	float lambertian = 0.5 * dot_nl;
	DIFFUSE_LIGHT += mix((sss_height + sss_near) * sss_modifier / (1.0 + light_mask) + lambertian, foam_color.rgb, foam_factor) * (1.0 - fresnel) * ATTENUATION * LIGHT_COLOR;
}
