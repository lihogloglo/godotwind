shader_type spatial;
render_mode cull_back;

// =============================================================================
// LOD Crossfade Shader - Screen-door dithering for smooth LOD transitions
// =============================================================================
// Industry-standard technique used in Witcher 3, Horizon Zero Dawn, etc.
// Both outgoing and incoming LODs are visible during transition with
// complementary dither patterns that sum to full coverage.
// =============================================================================

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
// Crossfade parameters
// fade_amount: 1.0 = fully visible, 0.0 = fully invisible
uniform float fade_amount : hint_range(0.0, 1.0) = 1.0;

// Alpha cutout threshold for transparent materials
uniform float alpha_cutout : hint_range(0.0, 1.0) = 0.5;
uniform bool use_alpha_cutout = false;

// 4x4 Bayer dither matrix for smooth screen-door effect
// This creates a visually pleasing pattern that blends well at distance
// Values are normalized to 0.0-1.0 range
const float BAYER_MATRIX[16] = {
	0.0 / 16.0,  8.0 / 16.0,  2.0 / 16.0, 10.0 / 16.0,
	12.0 / 16.0, 4.0 / 16.0, 14.0 / 16.0,  6.0 / 16.0,
	3.0 / 16.0, 11.0 / 16.0,  1.0 / 16.0,  9.0 / 16.0,
	15.0 / 16.0, 7.0 / 16.0, 13.0 / 16.0,  5.0 / 16.0
};

float get_bayer_threshold(ivec2 screen_pos) {
	int x = screen_pos.x % 4;
	int y = screen_pos.y % 4;
	return BAYER_MATRIX[y * 4 + x];
}

void fragment() {
	// Sample original textures
	vec4 albedo_sample = texture(albedo_texture, UV) * albedo_color;

	// Handle alpha cutout first (for vegetation, etc.)
	if (use_alpha_cutout && albedo_sample.a < alpha_cutout) {
		discard;
	}

	// Calculate dither threshold from screen position
	ivec2 screen_pos = ivec2(FRAGCOORD.xy);
	float dither_threshold = get_bayer_threshold(screen_pos);

	// Screen-door dithering: discard pixel if threshold exceeds visibility
	// When fade_amount = 1.0, all pixels pass (fully visible)
	// When fade_amount = 0.5, ~50% of pixels pass (half visible)
	// When fade_amount = 0.0, no pixels pass (invisible)
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
