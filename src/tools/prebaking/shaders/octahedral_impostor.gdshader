shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, shadows_disabled;

// Octahedral impostor shader with 16-frame support and parallax
// Optimized for distant rendering with smooth rotation transitions
// Supports both 4x4 (16 frames) and 4x2 (8 frames) atlas layouts

uniform sampler2D albedo_atlas : source_color, filter_linear_mipmap;
uniform float alpha_cutoff : hint_range(0.0, 1.0) = 0.5;

// Atlas configuration (4x4 = 16 frames for smooth rotation)
uniform int atlas_columns = 4;
uniform int atlas_rows = 4;

// Impostor settings
uniform vec2 impostor_size = vec2(10.0, 10.0);

// Parallax settings (uses depth baked in alpha channel)
uniform bool use_parallax = true;
uniform float parallax_depth : hint_range(0.0, 0.5) = 0.15;

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

// Convert view direction to frame index
int get_frame_index(vec3 view_dir) {
	// Project to XZ plane and get angle
	float angle = atan(view_dir.x, view_dir.z);  // -PI to PI

	// Convert to 0-N range (N = total frames)
	float normalized = (angle + PI) / (2.0 * PI);  // 0-1
	int total_frames = atlas_columns * atlas_rows;
	int frame = int(normalized * float(total_frames)) % total_frames;

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

// Sample with parallax offset using depth from alpha
vec4 sample_with_parallax(vec3 view_dir, vec2 uv, int frame) {
	vec2 atlas_uv = get_frame_uv(frame, uv);

	if (!use_parallax) {
		return texture(albedo_atlas, atlas_uv);
	}

	// Simple parallax offset based on view angle
	// Depth is encoded in alpha: 1 = close, 0 = far
	vec2 parallax_offset = vec2(view_dir.x, -view_dir.y) * parallax_depth * (1.0 - uv.y);
	vec2 frame_size = vec2(1.0 / float(atlas_columns), 1.0 / float(atlas_rows));

	// Clamp offset to stay within frame bounds
	vec2 offset_uv = atlas_uv + parallax_offset * frame_size;
	vec2 frame_min = get_frame_uv(frame, vec2(0.0, 0.0));
	vec2 frame_max = get_frame_uv(frame, vec2(1.0, 1.0));
	offset_uv = clamp(offset_uv, frame_min, frame_max);

	return texture(albedo_atlas, offset_uv);
}

// Smoothly blend between two frames based on angle
vec4 sample_interpolated(vec3 view_dir, vec2 uv) {
	float angle = atan(view_dir.x, view_dir.z) + PI;  // 0 to 2*PI
	int total_frames = atlas_columns * atlas_rows;
	float frame_angle = angle / (2.0 * PI) * float(total_frames);  // 0 to N

	int frame_a = int(floor(frame_angle)) % total_frames;
	int frame_b = (frame_a + 1) % total_frames;
	float blend = fract(frame_angle);

	// Sharpen the blend for less ghosting
	blend = smoothstep(0.5 - 0.5/interpolation_sharpness, 0.5 + 0.5/interpolation_sharpness, blend);

	vec4 color_a = sample_with_parallax(view_dir, uv, frame_a);
	vec4 color_b = sample_with_parallax(view_dir, uv, frame_b);

	return mix(color_a, color_b, blend);
}

void fragment() {
	vec4 tex;

	if (interpolate_frames) {
		tex = sample_interpolated(view_direction, UV);
	} else {
		int frame = get_frame_index(view_direction);
		tex = sample_with_parallax(view_direction, UV, frame);
	}

	// Alpha test - discard transparent pixels
	if (tex.a < alpha_cutoff) {
		discard;
	}

	ALBEDO = tex.rgb;
	// No ALPHA assignment - treated as fully opaque after discard test
}
