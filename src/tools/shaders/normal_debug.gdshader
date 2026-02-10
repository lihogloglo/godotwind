// Debug shader: visualizes world-space normals as RGB color.
// Red = +X, Green = +Y, Blue = +Z. Cyan left side = normals point -X (correct).
// If left-side limbs show red where right shows cyan, normals are wrong.
shader_type spatial;
render_mode unshaded;

void fragment() {
	// Map normal from [-1,1] to [0,1] for display
	vec3 n = normalize(NORMAL);
	ALBEDO = n * 0.5 + 0.5;
}
