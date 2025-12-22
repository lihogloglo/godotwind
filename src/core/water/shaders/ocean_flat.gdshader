shader_type spatial;
render_mode world_vertex_coords, blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

// Godot 4.3+ requires explicit screen texture samplers
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

/**
 * Simple flat water shader for ultra-low-end hardware
 * No wave displacement, basic water color with improved lighting
 * Extremely lightweight - no compute, minimal texture sampling
 * Includes simplified specular for better appearance
 */

#define REFLECTANCE 0.02

uniform vec4 water_color : source_color = vec4(0.02, 0.15, 0.25, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.3;
uniform float water_clarity : hint_range(0.0, 1.0) = 0.5;

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
	// Physically-based fresnel
	fresnel = mix(pow(1.0 - max(dot(VIEW, NORMAL), 0.0), 5.0), 1.0, REFLECTANCE);

	// Simple refraction (minimal for ultra-low quality)
	vec3 refracted_color = textureLod(screen_texture, SCREEN_UV, 0.0).rgb;
	ALBEDO = mix(refracted_color, water_color.rgb, 0.6);

	// Alpha for transparency
	// CRITICAL: Multiply by shore_factor to hide ocean on land (0.0 = land, 1.0 = ocean)
	ALPHA = mix(water_clarity, 1.0, fresnel * 0.3) * shore_factor;

	// Roughness
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
