// ============================================================================
// Boujie High Feature surface optics.
// ============================================================================
// Shader path adapted from Chrisknyfe/boujie_water_shader commit
// 444067b4a39b28d0b9e2e0caf541ccf485723b73 (MIT). This keeps Godotwind's FFT
// displacement, shore contract, SSS, and foam, but swaps the final surface
// optics toward Boujie's triplanar albedo/refraction, Snell tint, depth fog,
// distance fades, and squared refraction distance falloff.
//
// The including .gdshader owns shader_type, render_mode, and vertex().
// ============================================================================

#define MAX_CASCADES 8
#define REFLECTANCE 0.02

global uniform uint num_cascades;
global uniform sampler2DArray displacements;
global uniform sampler2DArray normals;

uniform vec4 map_scales[MAX_CASCADES];

group_uniforms water_color;
uniform vec3 color_shallow : source_color = vec3(0.09, 0.12, 0.13);
uniform vec3 color_deep : source_color = vec3(0.02, 0.04, 0.06);
uniform vec3 color_sky_tint : source_color = vec3(0.3, 0.38, 0.45);
uniform float sky_tint_strength : hint_range(0.0, 1.0) = 0.5;

group_uniforms boujie;
uniform vec4 boujie_albedo : source_color = vec4(0.235294, 0.647059, 0.960784, 0.0);
uniform vec4 boujie_albedo_fresnel : source_color = vec4(0.317647, 0.596078, 0.988235, 1.0);
uniform vec4 boujie_albedo_snell : source_color = vec4(0.0, 0.101961, 0.239216, 1.0);
uniform sampler2D boujie_texture_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D boujie_texture_refraction : filter_linear_mipmap, repeat_enable;
uniform sampler2D micro_normal_texture : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float boujie_refraction : hint_range(-2.0, 2.0) = 0.088;
uniform vec4 boujie_refraction_texture_channel = vec4(1.0, 0.0, 0.0, 0.0);
uniform float boujie_refraction_opacity : hint_range(0.0, 1.0) = 1.0;
uniform float boujie_beers_law : hint_range(0.001, 0.2) = 0.02;
uniform float boujie_depth_offset : hint_range(-100.0, 5.0) = -0.75;
uniform float boujie_snell_tightness : hint_range(0.0, 1.0) = 0.6;
uniform float boujie_uv_blend_sharpness : hint_range(0.1, 8.0) = 2.0;
uniform vec3 boujie_uv_tri_scale = vec3(36.0, 36.0, 36.0);
uniform vec3 boujie_uv_tri_offset = vec3(0.0);

group_uniforms foam;
uniform vec3 foam_color : source_color = vec3(0.9, 0.92, 0.95);
uniform sampler2D foam_texture : filter_linear_mipmap, repeat_enable;
uniform float foam_edge_width : hint_range(0.01, 2.0) = 0.3;
uniform float foam_flow_speed : hint_range(0.0, 0.1) = 0.03;
uniform float foam_intensity : hint_range(0.0, 1.0) = 1.0;

group_uniforms shore;
uniform sampler2D shore_mask : filter_linear_mipmap;
uniform vec4 shore_mask_bounds = vec4(-8000.0, -8000.0, 16000.0, 16000.0);
uniform float shore_fade_distance : hint_range(10.0, 200.0) = 50.0;
uniform float shore_wave_amplitude : hint_range(0.0, 3.0) = 0.5;
uniform float shore_wave_frequency : hint_range(0.02, 0.5) = 0.1;
uniform float shore_wave_speed : hint_range(0.1, 5.0) = 0.4;
uniform float shore_wave_steepness : hint_range(0.0, 1.0) = 0.58;

group_uniforms optics;
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
uniform vec3 medium_color : source_color = vec3(0.02, 0.04, 0.06);
uniform vec3 extinction_sigma = vec3(0.08, 0.02, 0.012);
uniform float visibility_distance_m : hint_range(0.5, 500.0) = 57.5;
uniform float max_visible_depth : hint_range(1.0, 50.0) = 20.0;
uniform float refraction_scaling_distance_min : hint_range(0.1, 500.0) = 50.0;
uniform float refraction_scaling_power : hint_range(0.25, 6.0) = 2.0;
uniform float refraction_strength : hint_range(0.0, 1.0) = 0.0;
uniform float refraction_edge_guard_strength : hint_range(0.0, 1.0) = 0.0;
uniform float sea_level = 0.0;

group_uniforms visual;
uniform float roughness : hint_range(0.0, 1.0) = 0.087;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform float wave_scale : hint_range(0.0, 3.0) = 1.0;
uniform float ocean_time = 0.0;
uniform vec2 wind_dir_xz = vec2(0.7071, 0.7071);
uniform float wind_speed_mps : hint_range(0.0, 60.0) = 2.0;
uniform float texture_advection_strength : hint_range(0.0, 2.0) = 1.0;
uniform float micro_normal_strength : hint_range(0.0, 1.0) = 0.16;
uniform float micro_normal_uv_scale : hint_range(0.001, 0.5) = 0.075;
uniform float micro_normal_speed_scale : hint_range(0.0, 0.25) = 0.04;
uniform float micro_normal_flat_boost : hint_range(0.0, 3.0) = 1.35;

group_uniforms distance_fade;
uniform float distance_fade_min = 2708.0;
uniform float distance_fade_max = 4000.0;
uniform float near_fade_min = 1.5;
uniform float near_fade_max = 1.7;
uniform float foam_fade_min = 516.96;
uniform float foam_fade_max = 1440.0;
uniform float shore_fade_min = 516.96;
uniform float shore_fade_max = 1440.0;
uniform float depth_fog_fade_min = 516.96;
uniform float depth_fog_fade_max = 1440.0;

uniform int debug_mode : hint_range(0, 20) = 0;

group_uniforms sss;
uniform vec3 color_sub_surface : source_color = vec3(0.28, 0.62, 0.48);
uniform float sss_strength : hint_range(0.0, 3.0) = 0.9;
uniform float sss_emission_strength : hint_range(0.0, 2.0) = 0.45;
uniform float scatter_choppiness_min : hint_range(0.0, 2.0) = 0.28;
uniform float scatter_choppiness_max : hint_range(0.1, 3.0) = 0.75;
uniform vec3 sun_dir_world = vec3(0.0, -1.0, 0.0);

varying float wave_height;
varying float foam_factor;
varying float fresnel;
varying vec3 v_world_pos;
varying float v_vertex_dist;
varying float v_choppiness;
varying vec2 v_shore_slope;
varying float v_shore_choppiness;
varying vec3 v_boujie_uv_tri;
varying vec3 v_boujie_uv_power_normal;
varying vec3 v_boujie_refraction_uv_tri;
varying float v_projected_coverage;

#include "ocean_surface_common.gdshaderinc"

vec4 boujie_triplanar_texture(sampler2D sampler_tex, vec3 weights, vec3 tri_pos) {
	vec4 sample_value = vec4(0.0);
	sample_value += texture(sampler_tex, tri_pos.xy) * weights.z;
	sample_value += texture(sampler_tex, tri_pos.xz) * weights.y;
	sample_value += texture(sampler_tex, tri_pos.zy * vec2(-1.0, 1.0)) * weights.x;
	return sample_value;
}

float boujie_fresnel(float amount, vec3 normal, vec3 view) {
	return pow(1.0 - clamp(dot(normalize(normal), normalize(view)), 0.0, 1.0), amount);
}

float boujie_snell(float amount, vec3 normal, vec3 view) {
	float cos_theta = clamp(dot(normalize(normal), normalize(view)), 0.0, 1.0);
	float feather = max(0.04, 1.0 - amount);
	return smoothstep(amount - feather, amount + feather, cos_theta);
}

float boujie_view_z_from_depth(vec2 uv, float depth, mat4 inv_projection_matrix) {
	vec4 view4 = inv_projection_matrix * vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec3 view = view4.xyz / view4.w;
	return view.z;
}

vec2 boujie_safe_wind_dir() {
	float len_sq = dot(wind_dir_xz, wind_dir_xz);
	return len_sq > 1e-5 ? wind_dir_xz * inversesqrt(len_sq) : vec2(0.7071, 0.7071);
}

vec2 boujie_wind_advection(float speed_scale) {
	return boujie_safe_wind_dir() * ocean_time * max(wind_speed_mps, 0.0) * speed_scale * texture_advection_strength;
}

vec2 boujie_micro_normal_gradient(vec2 world_xz, float macro_chop) {
	if (micro_normal_strength <= 0.0001) {
		return vec2(0.0);
	}

	vec2 wind_dir = boujie_safe_wind_dir();
	vec2 lateral = vec2(-wind_dir.y, wind_dir.x);
	float advect_m = ocean_time * max(wind_speed_mps, 0.0) * micro_normal_speed_scale * texture_advection_strength;
	vec2 uv_a = (world_xz + wind_dir * advect_m) * micro_normal_uv_scale;
	vec2 uv_b = (world_xz * 1.73 + (wind_dir * 0.62 + lateral * 0.38) * advect_m) * micro_normal_uv_scale;
	vec3 n_a = texture(micro_normal_texture, uv_a).xyz * 2.0 - 1.0;
	vec3 n_b = texture(micro_normal_texture, uv_b).xyz * 2.0 - 1.0;
	vec2 normal_xy = n_a.xy * 0.65 + n_b.xy * 0.35;
	float flat_boost = mix(micro_normal_flat_boost, 1.0, clamp(macro_chop, 0.0, 1.0));
	float wind_gate = mix(0.55, 1.15, clamp(wind_speed_mps / 30.0, 0.0, 1.0));
	return normal_xy * micro_normal_strength * flat_boost * wind_gate;
}

float boujie_water_thickness_at(vec2 uv, vec3 surf_view, mat4 inv_projection_matrix, out bool sky_or_far) {
	float bg_ndc_z = texture(depth_texture, uv).r;
	sky_or_far = bg_ndc_z <= 1e-5;
	if (sky_or_far) {
		return max_visible_depth;
	}
	float bg_view_z = boujie_view_z_from_depth(uv, bg_ndc_z, inv_projection_matrix);
	return min(max(0.0, surf_view.z - bg_view_z), max_visible_depth);
}

vec3 boujie_surface_gradient(vec2 world_xz, float water_thickness) {
	float map_size = float(textureSize(normals, 0).x);
	vec3 gradient = vec3(0.0);
	for (uint i = 0U; i < num_cascades; ++i) {
		if (i >= uint(MAX_CASCADES)) {
			break;
		}
		vec4 scales = map_scales[i];
		vec3 coords = vec3(world_xz * scales.xy, float(i));
		float ppm = map_size * min(scales.x, scales.y);
		gradient += texture(normals, coords).xyw * vec3(scales.ww, 1.0) * min(1.0, ppm * 0.1);
	}
	gradient *= smoothstep(0.0, 1.0, water_thickness);
	gradient.xy += v_shore_slope;
	return gradient;
}

float smith_masking_shadowing(float cos_theta, float alpha) {
	float safe_cos = clamp(cos_theta, 0.0, 0.9999);
	float a = safe_cos / (alpha * sqrt(max(1.0 - safe_cos * safe_cos, 1e-5)));
	float a_sq = a * a;
	return a < 1.6 ? (1.0 - 1.259 * a + 0.396 * a_sq) / (3.535 * a + 2.181 * a_sq) : 0.0;
}

float ggx_distribution(float cos_theta, float alpha) {
	float a_sq = alpha * alpha;
	float d = 1.0 + (a_sq - 1.0) * cos_theta * cos_theta;
	return a_sq / (PI * d * d);
}

void fragment() {
	vec4 surf_view4 = VIEW_MATRIX * vec4(v_world_pos, 1.0);
	vec3 surf_view = surf_view4.xyz / surf_view4.w;

	bool straight_sky_or_far = false;
	float water_thickness = boujie_water_thickness_at(SCREEN_UV, surf_view, INV_PROJECTION_MATRIX, straight_sky_or_far);

	vec3 gradient = boujie_surface_gradient(v_world_pos.xz, water_thickness);
	float macro_chop_for_micro = smoothstep(scatter_choppiness_min, scatter_choppiness_max, v_choppiness + v_shore_choppiness);
	gradient.xy += boujie_micro_normal_gradient(v_world_pos.xz, macro_chop_for_micro);
	float normal_fade = mix(0.015, normal_strength, exp(-v_vertex_dist * 0.0175));
	float normal_y_scale = max(1.0, v_vertex_dist * 0.002);
	gradient.xy *= normal_fade;
	vec3 world_normal = normalize(vec3(-gradient.x, normal_y_scale, -gradient.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);

	float distance_from_camera = distance(CAMERA_POSITION_WORLD, v_world_pos);
	float alpha_fade = 1.0 - smoothstep(distance_fade_min, distance_fade_max, distance_from_camera);
	alpha_fade *= smoothstep(near_fade_min, near_fade_max, distance_from_camera);
	alpha_fade *= clamp(v_projected_coverage, 0.0, 1.0);
	if (alpha_fade <= 0.001) {
		discard;
	}

	float foam_fade_alpha = 1.0 - smoothstep(foam_fade_min, foam_fade_max, distance_from_camera);
	float shore_fade_alpha = 1.0 - smoothstep(shore_fade_min, shore_fade_max, distance_from_camera);
	float contact_width = mix(
		foam_edge_width,
		max(foam_edge_width * 1.5, 0.12),
		clamp(refraction_edge_guard_strength, 0.0, 1.0)
	);
	float contact_factor = 1.0 - smoothstep(0.0, contact_width, water_thickness);
	vec2 wind_dir = boujie_safe_wind_dir();
	vec2 wind_lateral = vec2(-wind_dir.y, wind_dir.x);
	vec2 foam_advect_a = boujie_wind_advection(foam_flow_speed * 0.20);
	vec2 foam_advect_b = boujie_wind_advection(foam_flow_speed * 0.13) + wind_lateral * ocean_time * foam_flow_speed * 0.12 * texture_advection_strength;
	vec2 foam_uv_a = v_world_pos.xz * 0.15 + foam_advect_a;
	vec2 foam_uv_b = v_world_pos.xz * 0.12 + foam_advect_b;
	float foam_tex_a = texture(foam_texture, foam_uv_a).r;
	float foam_tex_b = texture(foam_texture, foam_uv_b).r;
	float foam_detail = foam_tex_a * foam_tex_b;
	float foam_dist_fade = 1.0 - smoothstep(200.0, 4000.0, distance_from_camera);
	float jacobian_foam = smoothstep(0.0, 1.0, gradient.z * 0.75) * foam_dist_fade * foam_intensity;
	jacobian_foam *= mix(0.6, 1.0, foam_detail) * foam_fade_alpha;
	float shore_foam = contact_factor * foam_detail * shore_fade_alpha;
	foam_factor = max(jacobian_foam, shore_foam);
	float transmission_visibility = 1.0 - clamp(max(foam_factor, contact_factor), 0.0, 1.0);

	vec4 ref_tex = boujie_triplanar_texture(
		boujie_texture_refraction,
		v_boujie_uv_power_normal,
		v_boujie_refraction_uv_tri + vec3(boujie_wind_advection(0.015), dot(wind_lateral, boujie_wind_advection(0.008)))
	);
	float refraction_distance = max(distance_from_camera, 0.001);
	float refraction_control = clamp(refraction_strength, 0.0, 1.0);
	float r_final = boujie_refraction * refraction_control;
	r_final *= clamp(
		pow(refraction_scaling_distance_min / refraction_distance, refraction_scaling_power),
		0.0,
		1.0
	);
	r_final *= transmission_visibility;
	float ref_sample = dot(ref_tex, boujie_refraction_texture_channel);
	vec2 ref_uv_offset = (NORMAL.xy * ref_sample + ref_sample - 0.5) * r_final;
	vec2 screen_uv = clamp(SCREEN_UV - ref_uv_offset, vec2(0.001), vec2(0.999));

	ROUGHNESS = roughness;
	METALLIC = 0.0;
	SPECULAR = 0.5;

	vec4 albedo_tex = boujie_triplanar_texture(
		boujie_texture_albedo,
		v_boujie_uv_power_normal,
		v_boujie_uv_tri + vec3(boujie_wind_advection(0.006), dot(wind_lateral, boujie_wind_advection(0.004)))
	);

	fresnel = boujie_fresnel(3.0, NORMAL, VIEW);
	vec4 surface_color = mix(boujie_albedo, boujie_albedo_fresnel, fresnel);

	float final_refraction_opacity = boujie_refraction_opacity * refraction_control;
	vec2 snell_offset = ref_uv_offset * 2.0;
	vec3 snell_normal = normalize(vec3(NORMAL.x - snell_offset.x, NORMAL.y - snell_offset.y, NORMAL.z));
	float snell_factor = boujie_snell(boujie_snell_tightness, snell_normal, VIEW);
	if (FRONT_FACING) {
		snell_factor = 1.0;
	}
	final_refraction_opacity = clamp(final_refraction_opacity * snell_factor * transmission_visibility, 0.0, 1.0);
	surface_color = mix(boujie_albedo_snell, surface_color, snell_factor);

	bool refracted_sky_or_far = false;
	float refracted_thickness = boujie_water_thickness_at(screen_uv, surf_view, INV_PROJECTION_MATRIX, refracted_sky_or_far);
	float optical_depth = max(refracted_thickness + boujie_depth_offset, 0.0);
	float legacy_density_scale = max(boujie_beers_law / 0.02, 0.001);
	vec3 effective_extinction = max(extinction_sigma * legacy_density_scale, vec3(0.0001));
	vec3 transmittance = exp(-effective_extinction * optical_depth);
	float transmittance_luma = dot(transmittance, vec3(0.2126, 0.7152, 0.0722));
	float depth_blend = 1.0 - transmittance_luma;
	depth_blend = clamp(depth_blend, 0.0, 1.0);
	float depth_blend_power = clamp(pow(depth_blend, 2.5), 0.0, 1.0);
	depth_blend_power += smoothstep(depth_fog_fade_min, depth_fog_fade_max, distance_from_camera);
	depth_blend_power = clamp(depth_blend_power, 0.0, 1.0);

	float screen_lod = depth_blend_power * 2.5 + ROUGHNESS * 8.0;
	vec3 screen_color = textureLod(screen_texture, screen_uv, screen_lod).rgb;
	screen_color = screen_color * transmittance + medium_color * (vec3(1.0) - transmittance);
	vec3 shallow_screen_color = mix(screen_color, color_shallow, 0.55);
	vec3 deep_water_color = mix(color_deep, medium_color, 0.82);
	vec3 deep_screen_color = mix(screen_color, deep_water_color, 0.88);
	if (FRONT_FACING) {
		screen_color = mix(shallow_screen_color, deep_screen_color, depth_blend_power);
	}

	float screen_read_blend_amount = (1.0 - surface_color.a * albedo_tex.a) * final_refraction_opacity;

	float shore_blend = smoothstep(0.0, 0.5, water_thickness);

	float chop_mask = smoothstep(scatter_choppiness_min, scatter_choppiness_max, v_choppiness + v_shore_choppiness);
	vec3 world_view_dir = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	float side_mask = smoothstep(0.06, 0.38, 1.0 - world_normal.y);
	float peak_mask = chop_mask * mix(0.55, 1.0, side_mask);
	float sun_back = clamp(dot(world_view_dir, sun_dir_world), 0.0, 1.0);
	float scatter = clamp(
		sss_strength * peak_mask * mix(0.25, 1.0, side_mask) * mix(0.20, 1.0, sun_back),
		0.0,
		1.0
	);
	vec3 optical_surface_color = mix(
		mix(color_shallow, medium_color, 0.65),
		mix(color_sky_tint, medium_color, 0.35),
		fresnel
	);
	vec3 optical_snell_color = mix(color_deep, medium_color, 0.85);
	surface_color.rgb = mix(optical_snell_color, optical_surface_color, snell_factor);
	surface_color.rgb = mix(surface_color.rgb, color_sub_surface, scatter);
	surface_color.rgb = mix(surface_color.rgb, color_sky_tint, fresnel * sky_tint_strength);
	float albedo_luma = dot(albedo_tex.rgb, vec3(0.2126, 0.7152, 0.0722));
	vec3 albedo_detail = mix(vec3(1.0), vec3(albedo_luma), 0.65);
	vec3 final_col = surface_color.rgb * albedo_detail;
	final_col *= 1.0 - screen_read_blend_amount;
	final_col = mix(color_shallow * 1.5, final_col, shore_blend);
	final_col = mix(final_col, foam_color, foam_factor);

	vec3 debug_col = vec3(0.0);
	if (debug_mode == 3) {
		float t = clamp(water_thickness / max_visible_depth, 0.0, 1.0);
		debug_col = straight_sky_or_far ? vec3(1.0, 0.0, 1.0) : vec3(t, 0.0, 1.0 - t);
	} else if (debug_mode == 4) {
		debug_col = vec3(1.0 - depth_blend_power);
	} else if (debug_mode == 5) {
		debug_col = vec3(fresnel);
	} else if (debug_mode == 6) {
		debug_col = vec3(abs(ref_uv_offset) * 80.0, 0.0);
	} else if (debug_mode == 9) {
		debug_col = vec3(foam_factor);
	} else if (debug_mode == 10) {
		debug_col = vec3(clamp(world_normal.y, 0.0, 1.0));
	} else if (debug_mode == 11) {
		debug_col = vec3(scatter);
	} else if (debug_mode == 13) {
		debug_col = textureLod(screen_texture, SCREEN_UV, 0.0).rgb;
	} else if (debug_mode == 14) {
		debug_col = textureLod(screen_texture, screen_uv, 0.0).rgb;
	} else if (debug_mode == 19) {
		debug_col = vec3(screen_read_blend_amount);
	} else if (debug_mode == 20) {
		debug_col = screen_color;
	}

	if (debug_mode != 0) {
		ALBEDO = debug_col;
		EMISSION = vec3(0.0);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
	} else {
		ALBEDO = final_col;
		EMISSION = screen_color * screen_read_blend_amount;
		EMISSION += color_sub_surface * scatter * sss_emission_strength * (1.0 - foam_factor * 0.5);
	}

	if (foam_factor > 0.01) {
		vec3 foam_normal_perturb = vec3(
			(foam_tex_a - 0.5) * 0.3,
			1.0,
			(foam_tex_b - 0.5) * 0.3
		);
		vec3 perturbed = normalize(mix(world_normal, foam_normal_perturb, foam_factor * 0.4));
		NORMAL = normalize((VIEW_MATRIX * vec4(perturbed, 0.0)).xyz);
	}
	ROUGHNESS = (1.0 - fresnel) * foam_factor * 0.6 + roughness;
	ALPHA = alpha_fade;
}

void light() {
	vec3 halfway = normalize(LIGHT + VIEW);
	float dot_nl = max(dot(NORMAL, LIGHT), 2e-5);
	float dot_nv = max(dot(NORMAL, VIEW), 2e-5);

	float spec_alpha = max(roughness, 0.05);
	float light_mask = smith_masking_shadowing(dot_nl, spec_alpha);
	float view_mask = smith_masking_shadowing(dot_nv, spec_alpha);
	float microfacet_distribution = ggx_distribution(dot(NORMAL, halfway), spec_alpha);
	float geometric_attenuation = 1.0 / (1.0 + light_mask + view_mask);
	SPECULAR_LIGHT += fresnel * microfacet_distribution * geometric_attenuation / (4.0 * dot_nv + 0.1) * ATTENUATION;

	float half_lambert = dot_nl * 0.5 + 0.5;
	vec3 diffuse_base = vec3(half_lambert * 0.9);
	DIFFUSE_LIGHT += mix(diffuse_base, foam_color, foam_factor)
		* (1.0 - fresnel) * ATTENUATION * LIGHT_COLOR;
}
