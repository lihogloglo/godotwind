// Grass Deformation Shader - Extends grass shader with deformation support
// Add this code to your existing grass.gdshader vertex shader

// Deformation uniforms
uniform sampler2D deformation_texture : hint_default_white;
uniform vec3 deformation_chunk_offset = vec3(0.0, 0.0, 0.0);
uniform float deformation_chunk_size = 256.0;
uniform float grass_deformation_scale = 0.3;
uniform float grass_flatten_threshold = 0.4;  // Depth at which grass starts flattening

void vertex() {
	// ... existing grass wind animation code ...

	// Sample deformation at grass blade position
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 deform_uv = (world_pos.xz - deformation_chunk_offset.xz) / deformation_chunk_size;

	// Sample deformation texture
	vec4 deform = texture(deformation_texture, deform_uv);
	float depth = deform.r;

	// Displace grass blade down with terrain
	VERTEX.y -= depth * grass_deformation_scale;

	// Flatten grass in deep deformations
	float flatten_factor = smoothstep(grass_flatten_threshold, grass_flatten_threshold + 0.2, depth);

	// Collapse grass horizontally (simulate trampling)
	VERTEX.xz *= mix(1.0, 0.3, flatten_factor);

	// Reduce height in deformed areas
	float height_reduction = depth * 0.5;
	VERTEX.y *= (1.0 - height_reduction);

	// Optional: Tilt grass away from deformation center
	// vec2 deform_gradient = vec2(
	//     dFdx(depth),
	//     dFdy(depth)
	// );
	// VERTEX.xz += deform_gradient * 0.1;
}
