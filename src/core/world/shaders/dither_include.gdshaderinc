// =============================================================================
// Shared Bayer 4x4 Dithering for LOD Crossfade
// =============================================================================
// Industry-standard screen-door dithering pattern used across all LOD shaders.
// Creates visually pleasing transitions that blend well at distance.
//
// Usage:
//   #include "res://src/core/world/shaders/dither_include.gdshaderinc"
//   ...
//   if (get_dither_threshold(ivec2(FRAGCOORD.xy)) >= fade_amount) {
//       discard;
//   }
// =============================================================================

// 4x4 Bayer dither matrix (normalized 0.0-1.0)
// Same pattern used in Witcher 3, Horizon Zero Dawn, etc.
const float BAYER_MATRIX[16] = float[16](
	0.0 / 16.0,  8.0 / 16.0,  2.0 / 16.0, 10.0 / 16.0,
	12.0 / 16.0, 4.0 / 16.0, 14.0 / 16.0,  6.0 / 16.0,
	3.0 / 16.0, 11.0 / 16.0,  1.0 / 16.0,  9.0 / 16.0,
	15.0 / 16.0, 7.0 / 16.0, 13.0 / 16.0,  5.0 / 16.0
);

// Get dither threshold for a screen position
// Returns value 0.0-1.0 based on 4x4 pattern
float get_dither_threshold(ivec2 screen_pos) {
	int x = screen_pos.x % 4;
	int y = screen_pos.y % 4;
	return BAYER_MATRIX[y * 4 + x];
}
