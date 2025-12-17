shader_type spatial;
render_mode world_vertex_coords, depth_draw_opaque, cull_disabled;

/**
 * Simple flat water shader for ultra-low-end hardware
 * No wave displacement, basic water color with improved lighting
 * Extremely lightweight - no compute, no texture sampling
 * Includes simplified specular for better appearance
 */

#define REFLECTANCE 0.02

uniform vec4 water_color : source_color = vec4(0.02, 0.15, 0.25, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.3;

varying float fresnel;

void vertex() {
	UV = VERTEX.xz * 0.01;
}

void fragment() {
	// Physically-based fresnel
	fresnel = mix(pow(1.0 - max(dot(VIEW, NORMAL), 0.0), 5.0), 1.0, REFLECTANCE);

	// Base water color
	ALBEDO = water_color.rgb;

	// Roughness
	ROUGHNESS = roughness;
	METALLIC = 0.0;
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
