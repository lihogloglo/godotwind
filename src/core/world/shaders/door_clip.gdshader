// Door clip shader — discards fragments inside an oriented box to cut a
// door-shaped hole in wall meshes during seamless transitions.
// Uses an oriented box (not AABB) so the clip region is thin through the wall
// and wide across the doorway, regardless of wall orientation.
// Applied as material_override, copying the original material's properties.
shader_type spatial;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform float roughness : hint_range(0.0, 1.0) = 1.0;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D normal_texture : hint_normal;
uniform float normal_scale : hint_range(-2.0, 2.0) = 1.0;
uniform bool has_normal = false;

// Oriented clip box: center, half-extents in clip-local space, inverse rotation
// half_extents.x = across doorway (wide), y = height, z = through wall (thin)
uniform vec3 clip_center;
uniform vec3 clip_half_extents;
uniform mat3 clip_rotation_inv;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Transform world position into clip box local space
	vec3 local = clip_rotation_inv * (world_pos - clip_center);
	if (abs(local.x) < clip_half_extents.x &&
		abs(local.y) < clip_half_extents.y &&
		abs(local.z) < clip_half_extents.z) {
		discard;
	}
	vec4 tex = texture(albedo_texture, UV);
	ALBEDO = tex.rgb * albedo_color.rgb;
	ROUGHNESS = roughness;
	METALLIC = metallic;
	if (has_normal) {
		NORMAL_MAP = texture(normal_texture, UV).rgb;
		NORMAL_MAP_DEPTH = normal_scale;
	}
}
