shader_type spatial;
render_mode cull_back;

// =============================================================================
// LOD Crossfade Shader for Node3D (LOD0)
// =============================================================================
// Used for LOD0 (full detail Node3D) during fade transitions.
// Unlike MultiMesh shader, this uses a uniform for fade amount since
// Node3D instances don't support per-instance custom data.
//
// Applied temporarily as material_override during LOD0 fade zone.
// Original materials are restored after transition completes.
// =============================================================================

#include "res://src/core/world/shaders/dither_include.gdshaderinc"

group_uniforms Material;
// Material properties preserved from source StandardMaterial3D
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap_anisotropic;
uniform float normal_scale : hint_range(-2.0, 2.0) = 1.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.5;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float specular : hint_range(0.0, 1.0) = 0.5;

group_uniforms AlphaCutout;
// Alpha cutout for vegetation and transparent materials
uniform float alpha_cutout : hint_range(0.0, 1.0) = 0.5;
uniform bool use_alpha_cutout = false;

group_uniforms Crossfade;
// Fade amount: 1.0 = fully visible, 0.0 = invisible
// Updated per-frame by ObjectStreamer during tier transitions
uniform float fade_amount : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	// Sample albedo texture
	vec4 albedo_sample = texture(albedo_texture, UV) * albedo_color;

	// Alpha cutout first (for vegetation, fences, etc.)
	if (use_alpha_cutout && albedo_sample.a < alpha_cutout) {
		discard;
	}

	// Screen-door dithering for LOD crossfade (uses shared include)
	float dither_threshold = get_dither_threshold(ivec2(FRAGCOORD.xy));

	if (dither_threshold >= fade_amount) {
		discard;
	}

	// Standard PBR material output
	ALBEDO = albedo_sample.rgb;

	// Normal mapping
	vec3 normal_map = texture(normal_texture, UV).rgb;
	if (length(normal_map) > 0.01) {
		NORMAL_MAP = normal_map;
		NORMAL_MAP_DEPTH = normal_scale;
	}

	ROUGHNESS = roughness;
	METALLIC = metallic;
	SPECULAR = specular;
}
