shader_type spatial;
render_mode world_vertex_coords, diffuse_lambert, specular_schlick_ggx, cull_disabled;

/**
 * Gerstner Wave Water Shader
 * Adapted from Godot-Water-Shader-Prototype-4.4 by OKiN
 *
 * Features:
 * - Analytical Gerstner wave displacement (two layers)
 * - Shore mask support for wave dampening near land
 * - Extends to horizon via clipmap mesh
 * - Distance-based wave detail fadeout
 * - Foam and bubble effects
 * - Subsurface scattering
 * - Depth-based color and transparency
 */

// ============================================================================
// TEXTURE UNIFORMS
// ============================================================================
uniform sampler2D water_color_gradient : source_color;
uniform sampler2D vector_map : filter_linear_mipmap, repeat_enable;  // Flow/height map for base waves
uniform sampler2D gerstner_height_map : filter_linear_mipmap, repeat_enable;
uniform sampler2D gerstner_normal_map : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_normal_map : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D foam_albedo_map : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D foam_normal_map : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D bubble_albedo_map : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D bubble_normal_map : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D beach_waves_map : filter_linear, repeat_enable;
uniform sampler2D water_highlight_map : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_linear_mipmap;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;

// ============================================================================
// SHORE MASK
// ============================================================================
group_uniforms shore;
uniform sampler2D shore_mask : filter_linear;
uniform vec4 shore_mask_bounds = vec4(-8000.0, -8000.0, 16000.0, 16000.0);
uniform float shore_fade_distance = 50.0;

// ============================================================================
// GERSTNER WAVE PARAMETERS - Layer 1 (Large waves)
// ============================================================================
group_uniforms gerstner_waves;
uniform float gerstner_height = 0.4;
uniform float gerstner_normal = 0.25;
uniform float gerstner_stretch = 1.5;
uniform float gerstner_tiling = 0.1;
uniform vec2 gerstner_speed = vec2(0.011, 0.014);

// Gerstner Wave Layer 2 (Secondary detail waves)
uniform float gerstner_2_height = 1.0;
uniform float gerstner_2_normal = 0.4;
uniform float gerstner_2_stretch = 1.0;
uniform float gerstner_2_tiling = 0.412;
uniform vec2 gerstner_2_speed = vec2(0.003, 0.008);

// Distance fadeout for Gerstner waves (in world units/meters)
uniform float gerstner_distance_fadeout = 50.0;

// Base wave parameters (additional wave layer from vector_map)
uniform float wave_height = 0.3;
uniform float wave_z_offset = -0.15;

// ============================================================================
// NORMAL AND DETAIL PARAMETERS
// ============================================================================
group_uniforms normals;
uniform float normal_base_intensity = 0.7;
uniform float normal_peak_intensity = 1.5;
uniform float normal_dist_fadeout = 10.0;  // Matches original
uniform float detail_normal_intensity = 0.05;
uniform float detail_normal_tiling = 10.0;
uniform float detail_normal_speed = 12.0;

// ============================================================================
// FOAM AND BUBBLE PARAMETERS
// ============================================================================
group_uniforms foam;
uniform float foam_ramp = 0.2;
uniform float foam_amount = 3.0;
uniform int foam_tiling = 8;
uniform float foam_gerstner = 0.7;
uniform float bubble_ramp = 0.1;
uniform float bubble_amount = 1.0;
uniform int bubble_tiling = 3;
uniform float bubble_gerstner = 2.0;

// ============================================================================
// BEACH AND WATER PARAMETERS
// ============================================================================
group_uniforms water;
uniform float beach_alpha_fadeout = 0.05;
uniform float beach_normal_fadeout = 0.3;
uniform float beach_foam_depth = 2.0;
uniform float beach_foam_distortion = 3.74;
uniform float beach_foam_amount = 0.7;
uniform float water_color_depth = 1.0;
uniform float sss_strength = 5.0;
uniform vec3 water_color_shallow : source_color = vec3(0.1, 0.3, 0.4);
uniform vec3 water_color_deep : source_color = vec3(0.02, 0.08, 0.12);

// ============================================================================
// FLOW MAP TIMING
// ============================================================================
group_uniforms flow;
uniform float flow_blend_timing = 1.0;
uniform float flow_blend_stretch = 0.35;

// ============================================================================
// TIME (set from GDScript)
// ============================================================================
uniform float time = 0.0;

// ============================================================================
// CAMERA POSITION (for distance calculations)
// ============================================================================
uniform vec3 camera_position_world = vec3(0.0);

// ============================================================================
// VARYINGS
// ============================================================================
varying float v_shore_factor;
varying float v_camera_distance;
varying vec3 v_world_pos;
varying float v_wave_height;

// ============================================================================
// SHORE MASK SAMPLING
// ============================================================================
float sample_shore_mask(vec2 world_xz) {
	vec2 uv = (world_xz - shore_mask_bounds.xy) / shore_mask_bounds.zw;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		return 1.0;  // Outside bounds = open ocean
	}
	return texture(shore_mask, uv).r;
}

// ============================================================================
// HEIGHT SAMPLING (multi-sample for smoother results)
// ============================================================================
float get_height(sampler2D tex, vec2 uv, float offset) {
	vec2 v1 = vec2(0.0, 1.0);
	vec2 v2 = vec2(0.866025, 0.5);
	vec2 v3 = vec2(0.866025, -0.5);

	float p1 = texture(tex, fract(uv + v1 * offset)).z;
	float p2 = texture(tex, fract(uv + v1 * -offset)).z;
	float p3 = texture(tex, fract(uv + v2 * offset)).z;
	float p4 = texture(tex, fract(uv + v2 * -offset)).z;
	float p5 = texture(tex, fract(uv + v3 * offset)).z;
	float p6 = texture(tex, fract(uv + v3 * -offset)).z;

	return (p1 + p2 + p3 + p4 + p5 + p6) / 6.0;
}

// ============================================================================
// NORMAL CALCULATION FROM HEIGHT
// ============================================================================
vec3 get_normal_from_height(sampler2D tex, vec2 uv, float offset, float intensity) {
	float p_up = texture(tex, fract(uv + vec2(0.0, -offset))).z;
	float p_right = texture(tex, fract(uv + vec2(offset, 0.0))).z;
	float p_down = texture(tex, fract(uv + vec2(0.0, offset))).z;
	float p_left = texture(tex, fract(uv + vec2(-offset, 0.0))).z;

	float red = mix(p_left * intensity, 1.0 - p_right * intensity, 0.5);
	float green = mix(p_down * intensity, 1.0 - p_up * intensity, 0.5);

	return vec3(red, green, clamp(1.0 - abs(0.5 - red) - abs(0.5 - green), 0.5, 1.0));
}

// ============================================================================
// VERTEX SHADER
// ============================================================================
void vertex() {
	v_world_pos = VERTEX;

	// Sample shore mask for wave dampening
	v_shore_factor = sample_shore_mask(VERTEX.xz);

	// Calculate distance to camera for LOD fadeout
	// Store in COLOR[0] for compatibility with original shader pattern
	v_camera_distance = length(camera_position_world - VERTEX);

	// Distance-based Gerstner wave fade (matches original: fades at 50m)
	float gerstner_fade = smoothstep(gerstner_distance_fadeout, 0.0, v_camera_distance);
	gerstner_fade *= v_shore_factor;  // Also dampen near shores

	// UV calculation - CRITICAL for proper wave scale
	// Original uses tiled mesh UV, we use world coords scaled to match
	// The 0.25 factor creates ~4m tiles, giving proper wave frequency
	vec2 uv = VERTEX.xz * 0.25;

	// Gerstner wave UV calculations (tiling further subdivides the UV)
	vec2 uv_gerstner = uv * gerstner_tiling + time * gerstner_speed;
	vec2 uv_gerstner_2 = uv_gerstner * gerstner_2_tiling + time * gerstner_2_speed;

	// Sample Gerstner displacement from textures
	vec2 gerstner_normal_read = (texture(gerstner_normal_map, uv_gerstner).xy - 0.5) * gerstner_height;
	vec2 gerstner_2_normal_read = (texture(gerstner_normal_map, uv_gerstner_2).xy - 0.5) * gerstner_2_height;

	// Calculate Gerstner displacement vectors
	// Layer 1: Primary waves
	vec3 gerstner = vec3(
		-gerstner_normal_read.x * gerstner_stretch,
		(pow(texture(gerstner_height_map, uv_gerstner).x, 0.4545) - 0.5) * gerstner_height,
		gerstner_normal_read.y * gerstner_stretch
	);

	// Layer 2: Secondary detail waves
	vec3 gerstner_2 = vec3(
		-gerstner_2_normal_read.x * gerstner_2_stretch,
		(pow(texture(gerstner_height_map, uv_gerstner_2).x, 0.4545) - 0.5) * gerstner_2_height,
		gerstner_2_normal_read.y * gerstner_2_stretch
	);

	// Base wave layer from vector_map (like original shader)
	float base_height = get_height(vector_map, fract(uv), 0.07);

	// Apply displacement with shore and distance fade
	// Original: VERTEX += vec3(0, height + wave_z_offset, 0) * wave_height + gerstner + gerstner_2
	vec3 base_displacement = vec3(0.0, base_height + wave_z_offset, 0.0) * wave_height;
	vec3 gerstner_displacement = (gerstner + gerstner_2) * gerstner_fade;
	VERTEX += base_displacement + gerstner_displacement;

	// Store wave height for fragment shader (foam/bubbles) - use base_height like original
	v_wave_height = base_height;
}

// ============================================================================
// FRAGMENT SHADER
// ============================================================================
void fragment() {
	// Discard fragments on land
	if (v_shore_factor < 0.01) {
		discard;
	}

	// UV based on world position (same scale as vertex shader)
	vec2 uv = v_world_pos.xz * 0.25;
	vec2 uv_gerstner = uv * gerstner_tiling + time * gerstner_speed;
	vec2 uv_gerstner_2 = uv_gerstner * gerstner_2_tiling + time * gerstner_2_speed;

	// Get base height for masking (from vector_map like original)
	float height = texture(vector_map, uv).z;
	vec2 flow_map = texture(vector_map, uv).xy - 0.5;

	// GERSTNER WAVE NORMALS
	vec3 normal_gerstner = texture(gerstner_normal_map, uv_gerstner).xyz - vec3(0.5, 0.5, 1.0);
	vec3 normal_gerstner_2 = texture(gerstner_normal_map, uv_gerstner_2).xyz - vec3(0.5, 0.5, 1.0);
	vec3 height_gerstner = texture(gerstner_height_map, uv_gerstner).xyz;
	vec3 height_gerstner_2 = texture(gerstner_height_map, uv_gerstner_2).xyz;

	// ========================================================================
	// MULTI-SCALE NORMAL SAMPLING (from vector_map like original)
	// ========================================================================
	vec3 normal_output = get_normal_from_height(vector_map, uv, 0.000976, 4.0 * normal_peak_intensity);
	normal_output += get_normal_from_height(vector_map, uv, 0.001953, 3.0 * normal_peak_intensity);
	normal_output += get_normal_from_height(vector_map, uv, 0.003906, 2.0 * normal_base_intensity);
	normal_output += get_normal_from_height(vector_map, uv, 0.007812, 2.0 * normal_base_intensity);
	normal_output += get_normal_from_height(vector_map, uv, 0.015625, 1.0 * normal_base_intensity);
	normal_output += get_normal_from_height(vector_map, uv, 0.03125, 1.0 * normal_base_intensity);
	normal_output /= 6.0;

	// Detail normal fade at distance (original uses COLOR[0] which is camera distance)
	normal_output = mix(normal_output, vec3(0.5, 0.5, 1.0), 1.0 - smoothstep(0.0, v_camera_distance, normal_dist_fadeout));

	// Add detail normal layer
	normal_output += (texture(detail_normal_map, uv_gerstner * detail_normal_tiling - time * gerstner_speed * detail_normal_speed).xyz - vec3(0.5, 0.5, 1.0)) * detail_normal_intensity;

	// Add Gerstner wave normals, then fade at distance (original order)
	normal_output += normal_gerstner * gerstner_normal + normal_gerstner_2 * gerstner_2_normal;
	normal_output = mix(normal_output, vec3(0.5, 0.5, 1.0), 1.0 - smoothstep(0.0, v_camera_distance, gerstner_distance_fadeout));

	// ========================================================================
	// DEPTH CALCULATIONS
	// ========================================================================
	float depth = texture(DEPTH_TEXTURE, SCREEN_UV).r;
	depth = PROJECTION_MATRIX[3][2] / (depth - PROJECTION_MATRIX[2][2]);
	depth = depth + VERTEX.z;

	// Re-read depth with normal distortion
	depth = texture(DEPTH_TEXTURE, SCREEN_UV + (normal_output.xy - 0.5) * clamp(depth * 0.2, 0.0, 0.1)).r;
	depth = PROJECTION_MATRIX[3][2] / (depth - PROJECTION_MATRIX[2][2]);
	depth = depth + VERTEX.z;

	float depth_mask = clamp(depth * 4.0, 0.0, 1.0);

	// ========================================================================
	// WATER COLOR
	// ========================================================================
	// Blend shallow to deep color based on depth
	vec3 albedo_output = mix(water_color_shallow, water_color_deep, clamp(depth * water_color_depth, 0.0, 1.0));

	// Screen-space underwater view
	vec3 screen = textureLod(SCREEN_TEXTURE, SCREEN_UV + ((normal_output.xy - 0.5) * clamp(depth, 0.0, 0.1)), 0.0).xyz;
	albedo_output = mix(screen, albedo_output, depth_mask);

	// ========================================================================
	// FLOW MAP TIMING (for foam/bubbles animation)
	// ========================================================================
	float flow_timing = time * flow_blend_timing;
	float flow_timing_a = flow_timing;
	float flow_timing_b = flow_timing + 0.5;

	// flow_map already read from vector_map above
	vec2 uv_detail_a = uv + flow_map * -flow_timing_a * flow_blend_stretch;
	vec2 uv_detail_b = uv + flow_map * -flow_timing_b * flow_blend_stretch;
	float time_mask = cos(flow_timing_a * 2.0 * PI) / 2.0 + 0.5;

	// Detail fade for foam/bubbles (based on camera distance)
	float detail_fade = smoothstep(0.0, v_camera_distance, normal_dist_fadeout);

	// ========================================================================
	// BEACH WAVES MASK
	// ========================================================================
	float mask_beach_waves = pow(texture(beach_waves_map, vec2(clamp(depth * beach_foam_depth + (normal_output.y - 0.5) * beach_foam_distortion, 0.0, 1.0), 0.0)).x, 2.2) * beach_foam_amount * v_shore_factor;

	// ========================================================================
	// BUBBLES
	// ========================================================================
	vec3 albedo_bubbles_a = texture(bubble_albedo_map, uv_detail_a * float(bubble_tiling)).xyz;
	vec3 albedo_bubbles_b = texture(bubble_albedo_map, uv_detail_b * float(bubble_tiling)).xyz;
	albedo_bubbles_a = mix(albedo_bubbles_a, albedo_bubbles_b, time_mask);

	vec3 normal_bubbles_a = texture(bubble_normal_map, uv_detail_a * float(bubble_tiling)).xyz - vec3(0.5, 0.5, 1.0);
	vec3 normal_bubbles_b = texture(bubble_normal_map, uv_detail_b * float(bubble_tiling)).xyz - vec3(0.5, 0.5, 1.0);
	normal_bubbles_a = mix(normal_bubbles_a, normal_bubbles_b, time_mask);

	// Original: albedo_bubbles_mask = 1.0 - smoothstep(0.0, height, bubble_ramp) * dist_fade
	float albedo_bubbles_mask = 1.0 - smoothstep(0.0, height, bubble_ramp);
	albedo_bubbles_mask *= detail_fade;

	// Apply bubbles (original doesn't multiply gerstner component by fade)
	float bubble_factor = albedo_bubbles_mask * bubble_amount + mask_beach_waves * 5.0 + (height_gerstner.y + height_gerstner_2.y) * bubble_gerstner;
	albedo_output = mix(albedo_output, albedo_output + albedo_bubbles_a, bubble_factor);
	normal_output = mix(normal_output, normal_output + normal_bubbles_a, bubble_factor);

	// ========================================================================
	// FOAM
	// ========================================================================
	vec3 albedo_foam_a = texture(foam_albedo_map, uv_detail_a * float(foam_tiling)).xyz;
	vec3 albedo_foam_b = texture(foam_albedo_map, uv_detail_b * float(foam_tiling)).xyz;
	albedo_foam_a = mix(albedo_foam_a, albedo_foam_b, time_mask);

	vec3 normal_foam_a = texture(foam_normal_map, uv_detail_a * float(foam_tiling)).xyz - vec3(0.5, 0.5, 1.0);
	vec3 normal_foam_b = texture(foam_normal_map, uv_detail_b * float(foam_tiling)).xyz - vec3(0.5, 0.5, 1.0);
	normal_foam_a = mix(normal_foam_a, normal_foam_b, time_mask);

	// Original: mask_foam = 1.0 - smoothstep(-0.4, height, foam_ramp) * dist_fade
	float mask_foam = 1.0 - smoothstep(-0.4, height, foam_ramp);
	mask_foam *= detail_fade;

	// Gerstner-based foam (wave peaks)
	float gerstner_foam_1 = smoothstep(0.0, 0.05, pow(height_gerstner.y, 4.0));
	float gerstner_foam_2 = smoothstep(0.0, 0.05, pow(height_gerstner_2.y, 4.0));

	// Apply foam (original doesn't multiply by shore_factor here)
	float foam_factor = (mask_foam * foam_amount + mask_beach_waves) + (gerstner_foam_1 + gerstner_foam_2) * foam_gerstner;
	albedo_output = mix(albedo_output, albedo_output + albedo_foam_a, foam_factor);
	normal_output = mix(normal_output, normal_output + normal_foam_a, foam_factor);

	// ========================================================================
	// BEACH SMOOTHING
	// ========================================================================
	normal_output = mix(normal_output, vec3(0.5, 0.5, 1.0), clamp(smoothstep(0.0, depth, beach_normal_fadeout) + mask_beach_waves, 0.5, 1.0));
	float alpha_output = 1.0 - smoothstep(0.0, depth, beach_alpha_fadeout);

	// Shore factor alpha blend
	alpha_output *= v_shore_factor;

	// ========================================================================
	// OUTPUT
	// ========================================================================
	ALBEDO = clamp(albedo_output, 0.0, 1.0);
	NORMAL_MAP = clamp(normal_output, 0.0, 1.0);
	SPECULAR = 0.6;
	ROUGHNESS = 0.08;
	METALLIC = 0.0;
	ALPHA = alpha_output;
}

// ============================================================================
// LIGHT SHADER
// ============================================================================
void light() {
	// Water highlight masks for specular variation
	vec2 uv = v_world_pos.xz * 0.25;
	float water_highlight_mask_1 = texture(water_highlight_map, uv + time * 0.051031).x;
	float water_highlight_mask_2 = texture(water_highlight_map, (uv + time * -0.047854) * 2.0).x;

	// Subsurface scattering
	float sss = clamp(
		smoothstep(0.65, 0.7, dot(NORMAL, VIEW) * 0.5 + 0.5) *
		smoothstep(0.5, 1.0, (dot(-LIGHT, VIEW) * 0.5 + 0.5)) *
		(dot(-VIEW_MATRIX[2].xyz, vec3(0.0, 1.0, 0.0)) * 0.5 + 0.5),
		0.0, 1.0
	) * sss_strength * v_shore_factor;

	// Lambert diffuse
	float lambert = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);

	// Specular highlights
	float spec = clamp(pow(dot(reflect(LIGHT, NORMAL), -VIEW), 1000.0), 0.0, 1.0) * 2.0;
	float spec_glare = clamp(pow(dot(reflect(LIGHT, NORMAL), -VIEW), 100.0), 0.0, 1.0) * smoothstep(0.0, 0.1, water_highlight_mask_1 * water_highlight_mask_2) * 30.0;

	// Apply lighting
	DIFFUSE_LIGHT += (LIGHT_COLOR * ALBEDO * ATTENUATION / PI) * lambert;
	DIFFUSE_LIGHT += (LIGHT_COLOR * ALBEDO * ATTENUATION / PI) * sss;
	SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * (spec + spec_glare);
}
