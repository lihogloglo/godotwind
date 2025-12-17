// deformation_stamp.gdshader
// Renders deformation stamps onto the RTT deformation texture
// Blends with previous deformation state based on material type
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_test_disabled;

// Inputs
uniform sampler2D previous_deformation : hint_default_black;
uniform vec2 stamp_center_uv = vec2(0.5, 0.5);
uniform float stamp_radius = 0.5;  // Meters
uniform float stamp_strength = 1.0;  // 0.0 to 1.0
uniform float material_type = 0.0;  // 0.0=snow, 0.25=mud, 0.5=ash, 0.75=sand
uniform float region_size_meters = 469.0;

varying vec2 world_uv;

void vertex() {
	// Pass through UV coordinates
	world_uv = UV;

	// Standard vertex transformation
	POSITION = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
}

void fragment() {
	vec2 uv = world_uv;

	// Calculate distance from stamp center in meters
	vec2 delta_uv = uv - stamp_center_uv;
	vec2 delta_meters = delta_uv * region_size_meters;
	float dist = length(delta_meters);

	// Radial falloff with smooth edges
	float falloff = 1.0 - smoothstep(0.0, stamp_radius, dist);
	float deformation = stamp_strength * falloff;

	// Read previous deformation state
	vec4 prev = texture(previous_deformation, uv);
	float prev_depth = prev.r;
	float prev_material = prev.g;

	// Material-specific blending behavior
	float final_depth = prev_depth;

	if (material_type < 0.125) {
		// Snow: accumulates easily
		final_depth = min(prev_depth + deformation, 1.0);
	}
	else if (material_type < 0.375) {
		// Mud: replaces but doesn't accumulate much
		final_depth = max(prev_depth, deformation * 0.7);
	}
	else if (material_type < 0.625) {
		// Ash: similar to snow but less depth
		final_depth = min(prev_depth + deformation * 0.5, 0.8);
	}
	else {
		// Sand: minimal accumulation, recovers quickly
		final_depth = max(prev_depth, deformation * 0.5);
	}

	// Only update material type where we're actually deforming
	float final_material = prev_material;
	if (deformation > 0.001) {
		final_material = material_type;
	}

	// Output: R=depth, G=material_type
	ALBEDO = vec3(final_depth, final_material, 0.0);
	ALPHA = 1.0;
}
