// deformation_recovery.gdshader
// Gradually fades deformation over time (recovery system)
// Material-specific recovery rates for realistic behavior
shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled;

uniform sampler2D previous_deformation : hint_default_black;
uniform float recovery_rate = 0.01;  // Units per second
uniform float delta_time = 1.0;  // Time since last recovery update

void vertex() {
	POSITION = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
}

void fragment() {
	// Read current deformation state
	vec4 prev = texture(previous_deformation, UV);
	float depth = prev.r;
	float material_type = prev.g;

	// Material-specific recovery rates
	float recovery_speed = recovery_rate;

	if (material_type < 0.125) {
		// Snow: recovers slowly (soft snow fills in gradually)
		recovery_speed *= 0.5;
	}
	else if (material_type < 0.375) {
		// Mud: recovers very slowly (footprints last long)
		recovery_speed *= 0.2;
	}
	else if (material_type < 0.625) {
		// Ash: recovers normally (wind can fill in)
		recovery_speed *= 1.0;
	}
	else {
		// Sand: recovers quickly (flows back easily)
		recovery_speed *= 2.0;
	}

	// Apply recovery (exponential decay toward zero)
	float recovery_amount = recovery_speed * delta_time;
	float new_depth = max(depth - recovery_amount, 0.0);

	// If depth is near zero, clear material type as well
	float new_material = material_type;
	if (new_depth < 0.01) {
		new_material = 0.0;
		new_depth = 0.0;
	}

	// Output recovered state
	ALBEDO = vec3(new_depth, new_material, 0.0);
	ALPHA = 1.0;
}
