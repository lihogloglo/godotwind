// Deformation Brush Shader - Renders brush stamps to RTT
// Used by DeformationChunk to paint deformation into texture
shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, blend_add;

// Brush parameters
uniform vec2 brush_center = vec2(0.5, 0.5);  // UV coordinates (0-1)
uniform float brush_radius = 0.1;  // In UV space
uniform float brush_strength = 1.0;  // 0-1 depth
uniform float edge_sharpness = 0.6;  // 0=soft, 1=sharp

// Current deformation state (for accumulation)
uniform sampler2D current_deformation : hint_default_white;

// Accumulation settings
uniform bool enable_accumulation = true;
uniform float accumulation_rate = 0.5;  // How fast deformation becomes permanent
uniform float accumulation_threshold = 0.3;  // Minimum depth to accumulate

// Material properties
uniform float max_depth = 0.3;  // Maximum deformation depth in meters

void fragment() {
	// Calculate distance from brush center
	float dist = length(UV - brush_center);

	// Radial falloff with edge sharpness
	float falloff_start = brush_radius * (1.0 - edge_sharpness);
	float falloff = 1.0 - smoothstep(falloff_start, brush_radius, dist);

	// Calculate new deformation depth
	float new_depth = falloff * brush_strength;

	// Sample existing deformation
	vec4 existing = texture(current_deformation, UV);
	float existing_depth = existing.r;
	float existing_accumulation = existing.g;
	float existing_wetness = existing.b;
	float existing_age = existing.a;

	// Blend with existing (max blend for additive deformation)
	float final_depth = max(existing_depth, new_depth);

	// Update accumulation (permanent deformation)
	float final_accumulation = existing_accumulation;
	if (enable_accumulation && final_depth > accumulation_threshold) {
		final_accumulation = mix(existing_accumulation, final_depth, accumulation_rate);
	}

	// Reset wetness and age on new deformation
	float final_wetness = new_depth > 0.01 ? 1.0 : existing_wetness * 0.95;  // Decay wetness
	float final_age = new_depth > 0.01 ? 0.0 : existing_age + 0.016;  // ~1 frame at 60fps

	// Output: R=depth, G=accumulation, B=wetness, A=age
	ALBEDO = vec3(final_depth, final_accumulation, final_wetness);
	ALPHA = final_age;
}
