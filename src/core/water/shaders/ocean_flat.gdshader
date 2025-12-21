shader_type spatial;
render_mode world_vertex_coords, blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

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

varying float fresnel;

void vertex() {
	UV = VERTEX.xz * 0.01;
}

void fragment() {
	// Physically-based fresnel
	fresnel = mix(pow(1.0 - max(dot(VIEW, NORMAL), 0.0), 5.0), 1.0, REFLECTANCE);

	// Simple refraction (minimal for ultra-low quality)
	vec3 refracted_color = textureLod(SCREEN_TEXTURE, SCREEN_UV, 0.0).rgb;
	ALBEDO = mix(refracted_color, water_color.rgb, 0.6);

	// Alpha for transparency
	ALPHA = mix(water_clarity, 1.0, fresnel * 0.3);

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
