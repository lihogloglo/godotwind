shader_type spatial;
render_mode world_vertex_coords, depth_draw_always, cull_disabled;

// Godot 4.3+ requires explicit screen texture samplers
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;

/**
 * ULTRA_LOW quality water shader - flat plane
 * No wave displacement, basic water color with depth-based absorption
 * Extremely lightweight - no compute, minimal texture sampling
 * For software renderers and very weak hardware
 */

#define REFLECTANCE 0.02

uniform vec4 water_color : source_color = vec4(0.1, 0.15, 0.18, 1.0);
uniform vec4 foam_color : source_color = vec4(0.9, 0.9, 0.9, 1.0);
uniform vec3 depth_color_consumption = vec3(1.5, 4.0, 8.0); // RGB absorption depths in meters (murky water)
uniform float roughness : hint_range(0.0, 1.0) = 0.3;

// Shore mask for fading ocean on land
uniform sampler2D shore_mask : filter_linear;
uniform vec4 shore_mask_bounds = vec4(-8000.0, -8000.0, 16000.0, 16000.0);

varying float fresnel;
varying float shore_factor;

// Sample shore mask - 1.0 = ocean, 0.0 = land
float sample_shore_mask(vec2 world_xz) {
	vec2 uv = (world_xz - shore_mask_bounds.xy) / shore_mask_bounds.zw;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		return 1.0; // Outside mask bounds = assume ocean
	}
	return texture(shore_mask, uv).r;
}

void vertex() {
	UV = VERTEX.xz * 0.01;
	shore_factor = sample_shore_mask(VERTEX.xz);
}

void fragment() {
	// Discard if not in ocean
	if (shore_factor < 0.01) {
		discard;
	}

	// Physically-based fresnel
	fresnel = mix(pow(1.0 - max(dot(VIEW, NORMAL), 0.0), 5.0), 1.0, REFLECTANCE);

	// Depth-based effects
	float depth_tex = texture(depth_texture, SCREEN_UV).r;
	vec4 world_pos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth_tex, 1.0);
	world_pos.xyz /= world_pos.w;

	// Alpha based on depth
	float smooth_alpha = 1.0 - smoothstep(world_pos.z + 0.66, world_pos.z, VERTEX.z);
	ALPHA = clamp(smooth_alpha * shore_factor, 0.0, 1.0);

	// ============ DEPTH-BASED COLOR ABSORPTION ============
	// water_depth: positive value = how far below water surface the floor is
	float water_depth = VERTEX.z - world_pos.z;
	float depth_visibility_range = clamp(max(depth_color_consumption.r, max(depth_color_consumption.g, depth_color_consumption.b)), 0.0, 200.0);

	// factor_translucency: 0 = transparent (shallow), 1 = opaque water_color (deep)
	float factor_translucency = smoothstep(0.0, depth_visibility_range, water_depth);

	// Sample what's behind the water
	vec3 screen_albedo = texture(screen_texture, SCREEN_UV).rgb;

	// Base water color mixed with background
	vec3 depth_water_color = mix(screen_albedo, water_color.rgb, factor_translucency);

	// Per-channel color absorption (red fades first, then green, blue last)
	float shallow_red = 1.0 - smoothstep(0.0, depth_color_consumption.r, water_depth);
	float shallow_green = 1.0 - smoothstep(0.0, depth_color_consumption.g, water_depth);
	float shallow_blue = 1.0 - smoothstep(0.0, depth_color_consumption.b, water_depth);
	vec3 color_absorbed = vec3(shallow_red, shallow_green, shallow_blue) * screen_albedo;
	vec3 color_shallow = max(color_absorbed, water_color.rgb);

	// Final water color with depth absorption
	ALBEDO = mix(color_shallow, water_color.rgb, factor_translucency);

	// Shore foam (even for flat water)
	float shore_foam = (1.0 - shore_factor) * 0.3;
	ALBEDO = mix(ALBEDO, foam_color.rgb, shore_foam);

	ROUGHNESS = roughness;
	METALLIC = 0.0;
	SPECULAR = 0.5;
}

// Simplified specular for flat water
void light() {
	vec3 halfway = normalize(LIGHT + VIEW);
	float dot_nl = max(dot(NORMAL, LIGHT), 0.0);
	float dot_nv = max(dot(NORMAL, VIEW), 0.0);
	float dot_nh = max(dot(NORMAL, halfway), 0.0);

	// Simple Blinn-Phong specular
	float spec_power = 64.0 * (1.0 - roughness);
	float specular = pow(dot_nh, spec_power) * fresnel;
	SPECULAR_LIGHT += specular * ATTENUATION;

	// Simple diffuse
	float lambertian = 0.5 * dot_nl;
	DIFFUSE_LIGHT += (lambertian * water_color.rgb + vec3(0.02, 0.04, 0.06) * dot_nv) * (1.0 - fresnel) * ATTENUATION * LIGHT_COLOR;
}
