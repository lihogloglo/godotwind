shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled;

/**
 * Flat water shader - lightweight fallback without FFT
 * Uses scrolling noise textures for wave animation
 * Visual style matches ocean_compute.gdshader (OpenMW-inspired)
 */

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;

// ============================================================================
// WATER COLORS - OpenMW style
// ============================================================================
uniform vec3 water_color : source_color = vec3(0.090, 0.116, 0.127);
uniform vec3 color_deep : source_color = vec3(0.02, 0.04, 0.06);

// ============================================================================
// MATERIAL PROPERTIES
// ============================================================================
// Unit conversion: 1 Morrowind unit ≈ 0.0138 meters
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.05;
uniform float water_visibility : hint_range(1.0, 100.0) = 34.5;  // 2500 MW ≈ 34.5m
uniform float depth_fade : hint_range(0.1, 20.0) = 10.0;  // Tuned for meters

// ============================================================================
// WAVE TEXTURES (noise-based displacement)
// ============================================================================
uniform sampler2D wave_normal : repeat_enable, filter_linear_mipmap, hint_normal;
uniform vec2 wave_direction_a = vec2(-1.0, 0.0);
uniform vec2 wave_direction_b = vec2(0.0, 1.0);
uniform float wave_scale : hint_range(0.001, 0.5) = 0.05;
uniform float wave_speed : hint_range(0.0, 1.0) = 0.15;
uniform float wave_height : hint_range(0.0, 2.0) = 0.3;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;

// ============================================================================
// REFRACTION
// ============================================================================
uniform float refraction_strength : hint_range(0.0, 0.2) = 0.07;

// ============================================================================
// SHORE
// ============================================================================
uniform sampler2D shore_mask : filter_linear;
uniform vec4 shore_mask_bounds = vec4(-8000.0, -8000.0, 16000.0, 16000.0);
uniform float shore_depth_scale : hint_range(0.0, 20.0) = 4.0;  // 300 MW ≈ 4m
uniform vec3 foam_color : source_color = vec3(0.9, 0.9, 0.9);
uniform float foam_scale : hint_range(0.0, 5.0) = 1.5;

// ============================================================================
// SUNLIGHT SCATTERING
// ============================================================================
uniform bool enable_sunlight_scattering = true;
uniform float scatter_amount : hint_range(0.0, 1.0) = 0.3;
uniform vec3 scatter_color : source_color = vec3(0.0, 1.0, 0.95);
uniform vec3 sun_direction = vec3(0.5, 0.7, 0.5);
uniform float sun_fade : hint_range(0.0, 1.0) = 1.0;

// Camera
uniform vec3 camera_position_world;

// ============================================================================
// VARYINGS
// ============================================================================
varying vec3 v_world_pos;
varying vec3 v_world_normal;

// ============================================================================
// FRESNEL
// ============================================================================
float fresnel_dielectric(vec3 incoming, vec3 normal, float eta) {
	float c = abs(dot(incoming, normal));
	float g = eta * eta - 1.0 + c * c;
	if (g > 0.0) {
		g = sqrt(g);
		float A = (g - c) / (g + c);
		float B = (c * (g + c) - 1.0) / (c * (g - c) + 1.0);
		return 0.5 * A * A * (1.0 + B * B);
	}
	return 1.0;
}

// ============================================================================
// SHORE MASK
// ============================================================================
float sample_shore_mask(vec2 world_xz) {
	vec2 uv = (world_xz - shore_mask_bounds.xy) / shore_mask_bounds.zw;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		return 1.0;
	}
	return texture(shore_mask, uv).r;
}

// ============================================================================
// NORMAL BLENDING (UDN method)
// ============================================================================
vec3 blend_normals(vec3 n1, vec3 n2) {
	return normalize(vec3(n1.xy + n2.xy, n1.z * n2.z));
}

// ============================================================================
// VERTEX
// ============================================================================
void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// Animated wave UVs
	vec2 uv = v_world_pos.xz * wave_scale;
	vec2 uv_a = uv + wave_direction_a * TIME * wave_speed;
	vec2 uv_b = uv + wave_direction_b * TIME * wave_speed * 0.8;

	// Sample height from normal map (use green channel)
	float h1 = texture(wave_normal, uv_a).g;
	float h2 = texture(wave_normal, uv_b).g;
	float height = (h1 + h2) * 0.5 - 0.5;

	// Shore dampening
	float shore = sample_shore_mask(v_world_pos.xz);
	VERTEX.y += height * wave_height * shore;

	// Calculate normal from height gradient
	vec2 e = vec2(0.01, 0.0);
	float h_l = texture(wave_normal, uv_a - e).g + texture(wave_normal, uv_b - e).g;
	float h_r = texture(wave_normal, uv_a + e).g + texture(wave_normal, uv_b + e).g;
	float h_d = texture(wave_normal, uv_a - e.yx).g + texture(wave_normal, uv_b - e.yx).g;
	float h_u = texture(wave_normal, uv_a + e.yx).g + texture(wave_normal, uv_b + e.yx).g;

	vec3 calc_normal = normalize(vec3(
		(h_l - h_r) * wave_height * shore,
		2.0 * e.x,
		(h_d - h_u) * wave_height * shore
	));

	v_world_normal = calc_normal;
	NORMAL = calc_normal;
}

// ============================================================================
// FRAGMENT
// ============================================================================
void fragment() {
	float dist_to_cam = length(v_world_pos.xz - camera_position_world.xz);

	// Depth
	float depth_raw = texture(depth_texture, SCREEN_UV).r;
	vec4 floor_ndc = vec4(SCREEN_UV * 2.0 - 1.0, depth_raw, 1.0);
	vec4 floor_view = INV_PROJECTION_MATRIX * floor_ndc;
	float floor_depth = floor_view.z / floor_view.w;
	float water_depth = max(VERTEX.z - floor_depth, 0.0);

	// Shore factor
	float shore_map = sample_shore_mask(v_world_pos.xz);
	float depth_shore = smoothstep(0.0, shore_depth_scale, water_depth);
	float shore_factor = min(shore_map, depth_shore);

	if (shore_factor < 0.05) {
		discard;
	}

	// Detail normals from texture
	vec2 uv = v_world_pos.xz * wave_scale;
	vec2 uv_a = uv + wave_direction_a * TIME * wave_speed;
	vec2 uv_b = uv + wave_direction_b * TIME * wave_speed * 0.8;

	vec3 n1 = texture(wave_normal, uv_a).xyz * 2.0 - 1.0;
	vec3 n2 = texture(wave_normal, uv_b).xyz * 2.0 - 1.0;
	vec3 detail = blend_normals(n1, n2);

	// Blend with vertex normal
	float detail_blend = exp(-dist_to_cam * 0.002) * normal_strength;
	vec3 world_normal = normalize(mix(v_world_normal, detail, detail_blend * 0.5));

	// Flip for backface
	if (!FRONT_FACING) {
		world_normal = -world_normal;
	}

	NORMAL = (VIEW_MATRIX * vec4(world_normal, 0.0)).xyz;

	// Fresnel
	vec3 view_world = normalize(camera_position_world - v_world_pos);
	float fresnel = fresnel_dielectric(-view_world, world_normal, 1.333);
	fresnel = clamp(fresnel, 0.02, 1.0);

	// Refraction - suppress at shores to prevent artifacts
	vec2 refr_offset = world_normal.xz * refraction_strength;
	refr_offset *= clamp(water_depth / shore_depth_scale, 0.0, 1.0);
	vec2 refraction_uv = clamp(SCREEN_UV - refr_offset, vec2(0.001), vec2(0.999));
	vec3 refracted = texture(screen_texture, refraction_uv).rgb;

	// Water color absorption (OpenMW formula)
	vec3 water_col = water_color * sun_fade;
	float depth_correction = sqrt(1.0 + 4.0 * depth_fade * depth_fade);
	float absorption = depth_fade * depth_fade /
		(-0.5 * depth_correction + 0.5 - water_depth / water_visibility)
		+ 0.5 * depth_correction + 0.5;
	absorption = clamp(absorption, 0.0, 1.0);
	vec3 underwater = mix(refracted, water_col, absorption);

	// Deep water
	float deep = smoothstep(water_visibility * 0.3, water_visibility, water_depth);
	underwater = mix(underwater, color_deep, deep * 0.6);

	// Sunlight scattering
	if (enable_sunlight_scattering) {
		vec3 sun_dir = normalize(sun_direction);
		float sun_height = sun_dir.y;
		if (sun_height > 0.0) {
			float scatter_lambert = max(dot(sun_dir, world_normal) * 0.7 + 0.3, 0.0);
			float scatter_reflect = max(dot(reflect(sun_dir, world_normal), -view_world) * 2.0 - 1.2, 0.0);
			float light_scatter = scatter_lambert * scatter_reflect * scatter_amount * sun_fade
								  * max(1.0 - exp(-sun_height), 0.0);
			underwater = mix(underwater, scatter_color, light_scatter * 0.5);
		}
	}

	// Shore foam
	float foam_factor = 1.0 - smoothstep(0.0, foam_scale, water_depth);
	vec3 final_color = mix(underwater, foam_color, foam_factor * shore_factor);

	// Output
	ALBEDO = final_color;
	METALLIC = metallic;
	ROUGHNESS = mix(roughness, 0.5, foam_factor);
	ALPHA = 1.0;
}
