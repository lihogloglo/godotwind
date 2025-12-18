shader_type spatial;
render_mode unshaded, cull_front, depth_draw_always;

// Selection outline shader using inverted hull technique
// Renders the backfaces of the mesh, expanded outward along normals

uniform vec4 outline_color : source_color = vec4(1.0, 0.7, 0.0, 1.0);
uniform float outline_width : hint_range(0.001, 0.1, 0.001) = 0.015;
uniform float pulse_speed : hint_range(0.0, 5.0) = 2.0;
uniform float pulse_amount : hint_range(0.0, 0.5) = 0.15;

void vertex() {
	// Calculate pulsing effect
	float pulse = 1.0 + sin(TIME * pulse_speed) * pulse_amount;

	// Expand vertices along normals (in model space)
	VERTEX += NORMAL * outline_width * pulse;
}

void fragment() {
	ALBEDO = outline_color.rgb;
	ALPHA = outline_color.a;
}
