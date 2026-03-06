shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled, shadows_disabled;

// Lit octahedral impostor shader with normal map support
// Used for prebaked impostor rendering in the FAR tier (500m-5km)
// Supports both v3 (albedo-only, unlit) and v4 (albedo + normals, lit) bakes

uniform sampler2D albedo_atlas : source_color, filter_linear_mipmap;
uniform sampler2D normal_atlas : filter_linear_mipmap;
uniform float alpha_cutoff : hint_range(0.0, 1.0) = 0.5;

// Atlas configuration (4x4 = 16 frames for smooth rotation)
uniform int atlas_columns = 4;
uniform int atlas_rows = 4;

// Whether normal atlas is available (false = legacy v3 unlit bake)
uniform bool has_normal_atlas = false;

// PBR settings (Morrowind: rough, non-metallic materials)
uniform float impostor_roughness : hint_range(0.0, 1.0) = 0.85;
uniform float impostor_specular : hint_range(0.0, 1.0) = 0.3;

// Parallax settings (uses depth baked in normal atlas alpha channel)
uniform float parallax_depth : hint_range(0.0, 0.2) = 0.1;

// Frame interpolation for smoother transitions
uniform bool interpolate_frames = true;
uniform float interpolation_sharpness = 4.0;

varying vec3 view_direction;

void vertex() {
	// Get view direction in world space
	vec3 camera_pos = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 world_pos = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	view_direction = normalize(camera_pos - world_pos);

	// Billboard: rotate to face camera (Y-axis only for upright billboards)
	vec3 look_dir = normalize(vec3(view_direction.x, 0.0, view_direction.z));
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), look_dir));
	vec3 up = vec3(0.0, 1.0, 0.0);

	// Build billboard matrix
	mat4 billboard = mat4(
		vec4(right, 0.0),
		vec4(up, 0.0),
		vec4(look_dir, 0.0),
		MODEL_MATRIX[3]
	);

	// Apply scale from model matrix
	float scale_x = length(MODEL_MATRIX[0].xyz);
	float scale_y = length(MODEL_MATRIX[1].xyz);
	float scale_z = length(MODEL_MATRIX[2].xyz);

	billboard[0] *= scale_x;
	billboard[1] *= scale_y;
	billboard[2] *= scale_z;

	MODELVIEW_MATRIX = VIEW_MATRIX * billboard;
}

// Get UV offset for a frame index
vec2 get_frame_uv(int frame_index, vec2 uv) {
	float col = float(frame_index % atlas_columns);
	float row = float(frame_index / atlas_columns);
	vec2 frame_size = vec2(1.0 / float(atlas_columns), 1.0 / float(atlas_rows));
	return vec2(col, row) * frame_size + uv * frame_size;
}

void fragment() {
	// Calculate view angle for frame selection
	float angle = atan(view_direction.x, view_direction.z);
	float normalized = (angle + PI) / (2.0 * PI);
	int total_frames = atlas_columns * atlas_rows;

	vec4 tex;
	vec4 normal_data;
	vec2 base_uv = UV;

	if (interpolate_frames) {
		// 2-frame angular blend
		float frame_angle = normalized * float(total_frames);
		int frame_a = int(floor(frame_angle)) % total_frames;
		int frame_b = (frame_a + 1) % total_frames;
		float blend = fract(frame_angle);
		blend = smoothstep(0.5 - 0.5/interpolation_sharpness, 0.5 + 0.5/interpolation_sharpness, blend);

		vec2 uv_a = get_frame_uv(frame_a, base_uv);
		vec2 uv_b = get_frame_uv(frame_b, base_uv);

		tex = mix(texture(albedo_atlas, uv_a), texture(albedo_atlas, uv_b), blend);
		if (has_normal_atlas) {
			normal_data = mix(texture(normal_atlas, uv_a), texture(normal_atlas, uv_b), blend);
		}
	} else {
		int frame = int(normalized * float(total_frames)) % total_frames;
		vec2 atlas_uv = get_frame_uv(frame, base_uv);
		tex = texture(albedo_atlas, atlas_uv);
		if (has_normal_atlas) {
			normal_data = texture(normal_atlas, atlas_uv);
		}
	}

	// Alpha test
	if (tex.a < alpha_cutoff) {
		discard;
	}

	ALBEDO = tex.rgb;

	if (has_normal_atlas) {
		// Decode world-space normal from atlas
		vec3 world_normal = normalize(normal_data.rgb * 2.0 - 1.0);

		// Convert world-space normal to view-space (Godot's NORMAL is view-space)
		NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);

		ROUGHNESS = impostor_roughness;
		SPECULAR = impostor_specular;
	}
}
