shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

// Octahedral impostor shader
// Selects the correct frame from atlas based on view direction
// Supports 8-direction hemisphere (4x2 atlas layout)

uniform sampler2D albedo_atlas : source_color, filter_linear_mipmap;
uniform float alpha_cutoff : hint_range(0.0, 1.0) = 0.5;

// Atlas configuration
uniform int atlas_columns = 4;
uniform int atlas_rows = 2;

// Impostor settings
uniform vec2 impostor_size = vec2(10.0, 10.0);  // World size of impostor

// Frame interpolation for smoother transitions
uniform bool interpolate_frames = true;
uniform float interpolation_sharpness = 4.0;

// Billboard mode
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

// Convert view direction to octahedral frame index (0-7)
int get_frame_index(vec3 view_dir) {
	// Project to XZ plane and get angle
	float angle = atan(view_dir.x, view_dir.z);  // -PI to PI

	// Convert to 0-8 range (8 directions)
	float normalized = (angle + PI) / (2.0 * PI);  // 0-1
	int frame = int(normalized * 8.0) % 8;

	return frame;
}

// Get UV offset for a frame index
vec2 get_frame_uv(int frame_index, vec2 uv) {
	float col = float(frame_index % atlas_columns);
	float row = float(frame_index / atlas_columns);

	vec2 frame_size = vec2(1.0 / float(atlas_columns), 1.0 / float(atlas_rows));
	vec2 frame_offset = vec2(col, row) * frame_size;

	return frame_offset + uv * frame_size;
}

// Smoothly blend between two frames based on angle
vec4 sample_interpolated(vec3 view_dir, vec2 uv) {
	float angle = atan(view_dir.x, view_dir.z) + PI;  // 0 to 2*PI
	float frame_angle = angle / (2.0 * PI) * 8.0;  // 0 to 8

	int frame_a = int(floor(frame_angle)) % 8;
	int frame_b = (frame_a + 1) % 8;
	float blend = fract(frame_angle);

	// Sharpen the blend for less ghosting
	blend = smoothstep(0.5 - 0.5/interpolation_sharpness, 0.5 + 0.5/interpolation_sharpness, blend);

	vec2 uv_a = get_frame_uv(frame_a, uv);
	vec2 uv_b = get_frame_uv(frame_b, uv);

	vec4 color_a = texture(albedo_atlas, uv_a);
	vec4 color_b = texture(albedo_atlas, uv_b);

	return mix(color_a, color_b, blend);
}

void fragment() {
	vec4 tex;

	if (interpolate_frames) {
		tex = sample_interpolated(view_direction, UV);
	} else {
		int frame = get_frame_index(view_direction);
		vec2 atlas_uv = get_frame_uv(frame, UV);
		tex = texture(albedo_atlas, atlas_uv);
	}

	ALBEDO = tex.rgb;

	// Alpha test
	if (tex.a < alpha_cutoff) {
		discard;
	}

	ALPHA = tex.a;
}
