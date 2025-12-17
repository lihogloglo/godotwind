// Terrain Deformation Shader - Applies RTT deformation to terrain
// This is a reference shader - integrate into your Terrain3D custom shader
shader_type spatial;

// Deformation texture (from DeformationChunk)
uniform sampler2D deformation_texture : hint_default_white;
uniform vec3 chunk_world_offset = vec3(0.0, 0.0, 0.0);  // World position of chunk
uniform float chunk_size = 256.0;  // Chunk size in meters
uniform float deformation_scale = 0.3;  // Max displacement depth

// Material properties
uniform float normal_strength = 0.8;  // How much deformation affects normals
uniform float darkening_strength = 0.2;  // Darken compressed areas

void vertex() {
	// Calculate chunk-local UV from world position
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 chunk_uv = (world_pos.xz - chunk_world_offset.xz) / chunk_size;

	// Sample deformation depth
	vec4 deform = texture(deformation_texture, chunk_uv);
	float depth = deform.r;  // 0-1 range

	// Apply vertical displacement (negative Y = down)
	VERTEX.y -= depth * deformation_scale;

	// Perturb normal based on deformation gradient (approximate derivative)
	vec2 texel_size = 1.0 / vec2(textureSize(deformation_texture, 0));
	float depth_x = texture(deformation_texture, chunk_uv + vec2(texel_size.x, 0.0)).r;
	float depth_z = texture(deformation_texture, chunk_uv + vec2(0.0, texel_size.y)).r;

	// Calculate normal offset
	vec3 normal_offset = normalize(vec3(
		(depth - depth_x) * deformation_scale * 10.0,
		1.0,
		(depth - depth_z) * deformation_scale * 10.0
	));

	// Blend with terrain normal
	NORMAL = mix(NORMAL, normal_offset, normal_strength);
}

void fragment() {
	// Re-calculate UV in fragment shader
	vec2 chunk_uv = (VERTEX.xz - chunk_world_offset.xz) / chunk_size;
	vec4 deform = texture(deformation_texture, chunk_uv);
	float depth = deform.r;
	float wetness = deform.b;

	// Darken deformed areas (compressed soil/snow)
	float darkening = depth * darkening_strength;
	ALBEDO = ALBEDO * (1.0 - darkening);

	// Optional: wetness effect (for mud)
	ROUGHNESS = mix(ROUGHNESS, 0.3, wetness * 0.5);
	SPECULAR = mix(SPECULAR, 0.5, wetness * 0.3);
}
