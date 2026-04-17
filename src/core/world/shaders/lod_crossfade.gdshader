shader_type spatial;
render_mode cull_back;

// =============================================================================
// LOD Crossfade Shader - Screen-door dithering for smooth LOD transitions
// =============================================================================
// Industry-standard technique used in Witcher 3, Horizon Zero Dawn, etc.
// Both outgoing and incoming LODs are visible during transition with
// complementary dither patterns that sum to full coverage.
// =============================================================================

#include "res://src/core/world/shaders/dither_include.gdshaderinc"

group_uniforms Material;
// Original material properties (preserved from source)
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap_anisotropic;
uniform float normal_scale : hint_range(-2.0, 2.0) = 1.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.5;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float specular : hint_range(0.0, 1.0) = 0.5;

group_uniforms Crossfade;
// Spawn-driven fade. Shader computes fade_amount internally from
//     fade_amount = clamp((TIME - spawn_time) / fade_duration, 0, 1)
// so no per-frame CPU work / Tween is needed. GDScript just sets spawn_time
// once at material application and schedules a single SceneTreeTimer for
// material restoration.
uniform float spawn_time = 0.0;
uniform float fade_duration : hint_range(0.0001, 10.0) = 0.3;

// Alpha cutout threshold for transparent materials
uniform float alpha_cutout : hint_range(0.0, 1.0) = 0.5;
uniform bool use_alpha_cutout = false;

void fragment() {
	// Sample original textures
	vec4 albedo_sample = texture(albedo_texture, UV) * albedo_color;

	// Handle alpha cutout first (for vegetation, etc.)
	if (use_alpha_cutout && albedo_sample.a < alpha_cutout) {
		discard;
	}

	// Calculate dither threshold from screen position (uses shared include)
	float dither_threshold = get_dither_threshold(ivec2(FRAGCOORD.xy));

	// Auto-computed fade amount from clock. 1.0 = fully visible, 0.0 = invisible.
	// Once TIME - spawn_time >= fade_duration, fade_amount stays clamped to 1.0
	// and the shader is functionally identical to the unfaded path.
	float fade_amount = clamp((TIME - spawn_time) / fade_duration, 0.0, 1.0);

	// Screen-door dithering: discard pixel if threshold exceeds visibility
	if (dither_threshold >= fade_amount) {
		discard;
	}

	// Standard material output - preserves original appearance
	ALBEDO = albedo_sample.rgb;

	// NOTE: Normal mapping disabled to avoid tangent requirements on LOD meshes.
	// Many prebaked/simplified meshes don't have tangent data generated.
	// If your meshes have tangents, uncomment below:
	// vec3 normal_map = texture(normal_texture, UV).rgb;
	// if (length(normal_map) > 0.01) {
	//     NORMAL_MAP = normal_map;
	//     NORMAL_MAP_DEPTH = normal_scale;
	// }

	ROUGHNESS = roughness;
	METALLIC = metallic;
	SPECULAR = specular;
}
