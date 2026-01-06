shader_type spatial;
render_mode cull_back;

// =============================================================================
// LOD Crossfade Shader for MultiMesh Batching
// =============================================================================
// Reads per-instance fade amount from INSTANCE_CUSTOM.x
// Uses Bayer 4x4 dithering for smooth screen-door transitions.
// Matches ImpostorManager's dithering pattern for visual consistency.
// =============================================================================

#include "res://src/core/world/shaders/dither_include.gdshaderinc"

group_uniforms Material;
// Material properties preserved from source StandardMaterial3D
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap_anisotropic;
uniform float normal_scale : hint_range(-2.0, 2.0) = 1.0;
uniform bool use_normal_map = false;  // Only apply normal map if explicitly enabled
uniform float roughness : hint_range(0.0, 1.0) = 0.5;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float specular : hint_range(0.0, 1.0) = 0.5;

group_uniforms AlphaCutout;
// Alpha cutout for vegetation and transparent materials
uniform float alpha_cutout : hint_range(0.0, 1.0) = 0.5;
uniform bool use_alpha_cutout = false;

group_uniforms Debug;
// Debug mode: tint by LOD level (set via shader global or material override)
uniform bool debug_lod_colors = false;
// LOD level for this batch (0-3, set by batcher)
uniform int lod_level : hint_range(0, 3) = 1;

// Per-instance fade amount passed via varying
varying flat float v_fade_amount;

void vertex() {
	// Read per-instance fade amount from custom data
	// x = fade amount (0.0 = invisible, 1.0 = fully visible)
	v_fade_amount = INSTANCE_CUSTOM.x;
}

void fragment() {
	// Sample albedo texture
	vec4 albedo_sample = texture(albedo_texture, UV) * albedo_color;

	// Alpha cutout first (for vegetation, fences, etc.)
	if (use_alpha_cutout && albedo_sample.a < alpha_cutout) {
		discard;
	}

	// Screen-door dithering for LOD crossfade (uses shared include)
	// When fade_amount = 1.0: all pixels pass (fully visible)
	// When fade_amount = 0.5: ~50% of pixels pass (half visible)
	// When fade_amount = 0.0: no pixels pass (invisible)
	float dither_threshold = get_dither_threshold(ivec2(FRAGCOORD.xy));

	if (dither_threshold >= v_fade_amount) {
		discard;
	}

	// Standard PBR material output
	vec3 final_albedo = albedo_sample.rgb;

	// Debug: Tint by LOD level if enabled
	// LOD0 = Green (NEAR), LOD1 = Yellow (MID close), LOD2 = Orange (MID far), LOD3 = Red (FAR)
	if (debug_lod_colors) {
		vec3 lod_colors[4] = vec3[4](
			vec3(0.0, 1.0, 0.0),   // LOD0 = Green
			vec3(1.0, 1.0, 0.0),   // LOD1 = Yellow
			vec3(1.0, 0.5, 0.0),   // LOD2 = Orange
			vec3(1.0, 0.0, 0.0)    // LOD3 = Red
		);
		int clamped_lod = clamp(lod_level, 0, 3);
		final_albedo = mix(final_albedo, lod_colors[clamped_lod], 0.5);
	}

	ALBEDO = final_albedo;

	// NOTE: Normal mapping disabled for LOD meshes to avoid tangent requirements.
	// Many prebaked LOD meshes don't have tangent data. If you need normal maps:
	// 1. Enable use_normal_map in the material
	// 2. Ensure the mesh has tangents (generate_tangents() in SurfaceTool)
	// Uncomment below if tangents are guaranteed:
	// if (use_normal_map) {
	//     vec3 normal_map = texture(normal_texture, UV).rgb;
	//     if (length(normal_map) > 0.01) {
	//         NORMAL_MAP = normal_map;
	//         NORMAL_MAP_DEPTH = normal_scale;
	//     }
	// }

	ROUGHNESS = roughness;
	METALLIC = metallic;
	SPECULAR = specular;
}
