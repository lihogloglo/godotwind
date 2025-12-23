shader_type spatial;
render_mode depth_draw_always, cull_disabled;

// Godot 4.3+ requires explicit screen texture samplers
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;

/**
 * FLAT quality water shader - flat plane
 * No wave displacement, basic water color with depth-based absorption
 * Lightweight - no compute, minimal texture sampling
 * For weak hardware or when FFT is not needed
 */

#define REFLECTANCE 0.02

uniform vec4 water_color : source_color = vec4(0.1, 0.15, 0.18, 1.0);
uniform vec4 foam_color : source_color = vec4(0.9, 0.9, 0.9, 1.0);
uniform vec3 depth_color_consumption = vec3(1.5, 4.0, 8.0); // RGB absorption depths in meters
uniform float roughness : hint_range(0.0, 1.0) = 0.3;
uniform vec3 camera_position_world;
uniform bool debug_shore_mask = false; // Debug: visualize shore damping factor

// Shore mask for fading ocean on land
uniform sampler2D shore_mask : filter_linear;
uniform vec4 shore_mask_bounds = vec4(-8000.0, -8000.0, 16000.0, 16000.0);

varying float fresnel;
varying vec3 world_pos_val;

// Sample shore mask - 1.0 = ocean, 0.0 = land
float sample_shore_mask(vec2 world_xz) {
	vec2 uv = (world_xz - shore_mask_bounds.xy) / shore_mask_bounds.zw;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		return 1.0; // Outside mask bounds = assume ocean
	}
	return texture(shore_mask, uv).r;
}

void vertex() {
	// Standard Mode: VERTEX is local.
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_pos_val = world_pos;
	UV = world_pos.xz * 0.01;
}

void fragment() {
	// Sample shore mask in fragment shader for pixel-accurate shore detection
	float frag_shore_factor = sample_shore_mask(world_pos_val.xz);

	// Discard if not in ocean
	if (frag_shore_factor < 0.01) {
		discard;
	}

	// Debug mode: visualize frag_shore_factor as color gradient
	if (debug_shore_mask) {
		vec3 shore_color = vec3(1.0, 0.0, 1.0);  // Magenta for shore
		vec3 ocean_color = vec3(0.0, 1.0, 1.0);  // Cyan for deep ocean
		ALBEDO = mix(shore_color, ocean_color, frag_shore_factor);
		ALPHA = 0.9;
		ROUGHNESS = 0.5;
		METALLIC = 0.0;
		SPECULAR = 0.0;
		return;
	}

	// Physically-based fresnel
	float NdotV = max(dot(VIEW, NORMAL), 0.001);
	fresnel = REFLECTANCE + (1.0 - REFLECTANCE) * pow(1.0 - NdotV, 5.0);

	// Depth-based effects
	float depth_tex = texture(depth_texture, SCREEN_UV).r;
	vec4 floor_pos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth_tex, 1.0);
	floor_pos.xyz /= floor_pos.w;

	// Alpha based on depth
	float smooth_alpha = 1.0 - smoothstep(floor_pos.z + 0.66, floor_pos.z, VERTEX.z);
	ALPHA = clamp(smooth_alpha * frag_shore_factor, 0.0, 1.0);

	// ============ SHALLOW WATER COLOR ============
	// Key insight: Real water ALWAYS has color, even at 0 depth
	float water_depth = max(VERTEX.z - floor_pos.z, 0.0);

	// Minimum water color blend - even at depth 0, water is not invisible
	const float MIN_WATER_BLEND = 0.35; // 35% water color minimum in shallows
	const float DEPTH_SCALE = 8.0; // Depth in meters where water becomes mostly opaque

	// Sample what's behind the water
	vec3 screen_albedo = texture(screen_texture, SCREEN_UV).rgb;

	// Exponential falloff - water color increases rapidly with depth
	float depth_blend = 1.0 - exp(-water_depth / DEPTH_SCALE);
	// Ensure minimum water presence even at zero depth
	float water_amount = MIN_WATER_BLEND + (1.0 - MIN_WATER_BLEND) * depth_blend;

	// Blend refraction with water color additively in shallows for that "tinted" look
	vec3 shallow_tint = mix(screen_albedo, screen_albedo * water_color.rgb * 1.5 + water_color.rgb * 0.4, 0.7);
	vec3 water_with_refraction = mix(shallow_tint, water_color.rgb, water_amount);

	// Final water color
	ALBEDO = water_with_refraction;

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
