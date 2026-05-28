// ============================================================================
// Shared water surface optics for non-FFT water bodies.
// ============================================================================
// Rivers, lakes, pools, and debug/test volumes use this include so their
// surface color, refraction, foam, and micro-normal treatment follows the same
// Boujie-inspired optics family as the ocean surface without depending on FFT
// cascades.

const float WATER_SURFACE_REFLECTANCE = 0.02;

group_uniforms water_surface_optics;
uniform sampler2D water_surface_screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform sampler2D water_surface_depth_texture : hint_depth_texture, filter_nearest;
uniform sampler2D water_surface_normal_texture : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D water_surface_foam_texture : filter_linear_mipmap, repeat_enable;
uniform vec3 water_surface_shallow_color : source_color = vec3(0.05, 0.22, 0.25);
uniform vec3 water_surface_deep_color : source_color = vec3(0.02, 0.04, 0.06);
uniform vec3 water_surface_medium_color : source_color = vec3(0.02, 0.04, 0.05);
uniform vec3 water_surface_foam_color : source_color = vec3(0.82, 0.90, 0.88);
uniform float water_surface_visibility_distance_m : hint_range(0.5, 300.0) = 38.0;
uniform float water_surface_max_visible_depth_m : hint_range(1.0, 80.0) = 22.0;
uniform float water_surface_absorption_density : hint_range(0.01, 2.0) = 0.24;
uniform float water_surface_refraction_strength : hint_range(0.0, 0.4) = 0.065;
uniform float water_surface_roughness : hint_range(0.0, 1.0) = 0.075;
uniform float water_surface_clarity : hint_range(0.0, 1.0) = 0.65;
uniform float water_surface_normal_strength : hint_range(0.0, 3.0) = 0.95;
uniform float water_surface_normal_uv_scale : hint_range(0.001, 2.0) = 0.12;
uniform float water_surface_foam_intensity : hint_range(0.0, 2.0) = 0.75;
uniform float water_surface_time = 0.0;

float water_surface_fresnel(vec3 normal, vec3 view_dir) {
	float ndotv = clamp(dot(normalize(normal), normalize(view_dir)), 0.0, 1.0);
	return WATER_SURFACE_REFLECTANCE + (1.0 - WATER_SURFACE_REFLECTANCE) * pow(1.0 - ndotv, 5.0);
}

float water_surface_view_z_from_depth(vec2 uv, float depth, mat4 inv_projection_matrix) {
	vec4 view4 = inv_projection_matrix * vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec3 view = view4.xyz / max(view4.w, 0.00001);
	return view.z;
}

float water_surface_thickness(vec2 uv, vec3 surface_view, mat4 inv_projection_matrix, out bool sky_or_far) {
	float bg_depth = texture(water_surface_depth_texture, uv).r;
	sky_or_far = bg_depth <= 0.00001;
	if (sky_or_far) {
		return water_surface_max_visible_depth_m;
	}
	float bg_view_z = water_surface_view_z_from_depth(uv, bg_depth, inv_projection_matrix);
	return clamp(surface_view.z - bg_view_z, 0.0, water_surface_max_visible_depth_m);
}

vec2 water_surface_micro_normal(vec2 world_xz, vec2 flow_dir, float flow_speed_mps) {
	vec2 dir = normalize(flow_dir + vec2(0.0001, 0.0));
	vec2 side = vec2(-dir.y, dir.x);
	float advect = water_surface_time * max(flow_speed_mps, 0.0);
	vec2 uv_a = (world_xz - dir * advect * 0.20 + side * advect * 0.025) * water_surface_normal_uv_scale;
	vec2 uv_b = (world_xz * 1.73 - dir * advect * 0.13 - side * advect * 0.041) * water_surface_normal_uv_scale;
	vec3 n_a = texture(water_surface_normal_texture, uv_a).xyz * 2.0 - 1.0;
	vec3 n_b = texture(water_surface_normal_texture, uv_b).xyz * 2.0 - 1.0;
	return (n_a.xy * 0.65 + n_b.xy * 0.35) * water_surface_normal_strength;
}

float water_surface_foam_detail(vec2 world_xz, vec2 flow_dir, float flow_speed_mps) {
	vec2 dir = normalize(flow_dir + vec2(0.0001, 0.0));
	vec2 side = vec2(-dir.y, dir.x);
	float advect = water_surface_time * max(flow_speed_mps, 0.0);
	float a = texture(water_surface_foam_texture, world_xz * 0.15 - dir * advect * 0.024).r;
	float b = texture(water_surface_foam_texture, world_xz * 0.11 - dir * advect * 0.017 + side * advect * 0.011).r;
	return a * b;
}

vec3 water_surface_optical_color(
	vec3 surface_view,
	vec3 normal_view,
	vec3 view_dir,
	vec2 screen_uv,
	mat4 inv_projection_matrix,
	vec2 normal_xy,
	vec2 flow_dir,
	float flow_speed_mps,
	float foam_factor,
	float edge_factor,
	out float fresnel_out,
	out vec3 refracted_out
) {
	bool sky_or_far = false;
	float thickness = water_surface_thickness(screen_uv, surface_view, inv_projection_matrix, sky_or_far);
	float depth_t = 1.0 - exp(-thickness * water_surface_absorption_density / max(water_surface_visibility_distance_m, 0.001));
	depth_t = clamp(depth_t, 0.0, 1.0);

	float clarity_gate = clamp(water_surface_clarity, 0.0, 1.0);
	float optical_visibility = pow(1.0 - depth_t, 1.35) * clarity_gate;
	float foam_guard = 1.0 - clamp(max(foam_factor, edge_factor), 0.0, 1.0);
	vec2 refr_uv = clamp(screen_uv + normal_xy * water_surface_refraction_strength * optical_visibility * foam_guard, vec2(0.001), vec2(0.999));

	bool refracted_sky = false;
	float refracted_thickness = water_surface_thickness(refr_uv, surface_view, inv_projection_matrix, refracted_sky);
	float refracted_depth_t = 1.0 - exp(-refracted_thickness * water_surface_absorption_density / max(water_surface_visibility_distance_m, 0.001));
	refracted_depth_t = clamp(refracted_depth_t, 0.0, 1.0);
	float screen_lod = refracted_depth_t * 3.0 + water_surface_roughness * 6.0;
	vec3 screen_color = textureLod(water_surface_screen_texture, refr_uv, screen_lod).rgb;
	vec3 absorbed = mix(screen_color, water_surface_medium_color, refracted_depth_t);
	vec3 depth_color = mix(water_surface_shallow_color, water_surface_deep_color, depth_t);
	refracted_out = mix(absorbed, depth_color, clamp(depth_t * (1.0 - clarity_gate * 0.65), 0.0, 0.95));

	fresnel_out = water_surface_fresnel(normal_view, view_dir);
	vec3 sky_tint = mix(water_surface_shallow_color, vec3(0.34, 0.48, 0.58), 0.25);
	vec3 surface_color = mix(refracted_out, sky_tint, fresnel_out * 0.55);
	surface_color = mix(surface_color, water_surface_foam_color, clamp(foam_factor, 0.0, 1.0));
	return surface_color;
}
