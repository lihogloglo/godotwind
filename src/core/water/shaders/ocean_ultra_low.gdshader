shader_type spatial;
render_mode world_vertex_coords, depth_draw_always, cull_disabled;

/**
 * Ultra-low quality water shader
 * Flat plane with basic color and transparency
 * For software renderers and systems without GPU
 */

uniform vec4 water_color : source_color = vec4(0.02, 0.15, 0.25, 0.85);
uniform float time = 0.0;

void vertex() {
	// No displacement - flat water
	// Just slight UV animation for visual feedback
	UV = VERTEX.xz * 0.01;
}

void fragment() {
	// Simple animated color variation
	float wave = sin(UV.x * 10.0 + time * 0.5) * 0.5 + 0.5;
	wave *= sin(UV.y * 8.0 + time * 0.3) * 0.5 + 0.5;

	ALBEDO = water_color.rgb + wave * 0.02;
	ALPHA = water_color.a;
	ROUGHNESS = 0.3;
	METALLIC = 0.1;

	// Basic fresnel approximation without VIEW dependency issues
	SPECULAR = 0.5;
}
