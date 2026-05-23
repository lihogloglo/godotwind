// Per-pixel object wetness shader — Lagarde PBR wet surfaces.
// Live water contact is screen-space; wet_line_y tracks retained high-water
// memory for objects that should stay wet after leaving water.
//
// Usage: assign as ShaderMaterial on any MeshInstance3D.
// Push wet_line_y from GDScript via RenderingServer.material_set_param().

shader_type spatial;

#define MAX_CASCADES 8

global uniform uint num_cascades;
global uniform sampler2DArray displacements;

// Object appearance (set from GDScript to match the original material)
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.7;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float specular : hint_range(0.0, 1.0) = 0.5;
uniform sampler2D albedo_texture : source_color, hint_default_white;
uniform bool normal_enabled = false;
uniform sampler2D normal_texture : hint_normal;
uniform float normal_scale : hint_range(0.0, 2.0) = 1.0;

// Wet map parameters. The dynamic water path is only a fallback when the
// screen-space compositor is not providing live contact wetness.
uniform float wet_line_y = -1000.0; // world-space Y of the water line on this object
uniform float wet_margin : hint_range(0.0, 2.0) = 0.3; // capillary rise above wet_line
uniform float wet_albedo_darken : hint_range(0.0, 1.0) = 0.6;
uniform float wet_roughness_target : hint_range(0.0, 0.3) = 0.05;
uniform float retained_wetness_strength : hint_range(0.0, 1.0) = 0.35;
uniform bool wet_debug = false;
uniform bool live_contact_from_compositor = true;
uniform bool dynamic_water_enabled = false;
uniform bool dynamic_water_use_fft = true;
uniform bool dynamic_water_has_shore_mask = false;
uniform vec3 camera_world_position = vec3(0.0);
uniform float sea_level = 0.0;
uniform float wave_scale = 1.0;
uniform float ocean_time = 0.0;
uniform vec4 map_scales[MAX_CASCADES];
uniform sampler2D shore_mask : filter_linear_mipmap, repeat_disable;
uniform vec4 shore_mask_bounds = vec4(-8000.0, -8000.0, 16000.0, 16000.0);
uniform float shore_fade_distance : hint_range(10.0, 200.0) = 50.0;
uniform float shore_wave_amplitude : hint_range(0.0, 3.0) = 0.0;
uniform float shore_wave_frequency : hint_range(0.02, 0.5) = 0.1;
uniform float shore_wave_speed : hint_range(0.1, 5.0) = 0.4;
uniform float shore_wave_steepness : hint_range(0.0, 1.0) = 0.58;

#include "res://src/core/water/shaders/ocean_surface_common.gdshaderinc"

// World-space position passed from vertex to fragment
varying vec3 v_world_pos;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec4 tex = texture(albedo_texture, UV);
	vec3 base_albedo = albedo_color.rgb * tex.rgb;
	float base_roughness = roughness;

	ALBEDO = base_albedo;
	ROUGHNESS = base_roughness;
	METALLIC = metallic;
	SPECULAR = specular;
	if (normal_enabled) {
		NORMAL_MAP = texture(normal_texture, UV).rgb;
		NORMAL_MAP_DEPTH = normal_scale;
	}

	// Retained wetness memory. Live contact is supplied by WetCompositorEffect;
	// the dynamic shader path remains only for explicit fallback materials.
	float wet_margin_safe = max(wet_margin, 0.001);
	float memory_wetness = 1.0 - smoothstep(wet_line_y, wet_line_y + wet_margin_safe, v_world_pos.y);
	float contact_wetness = 0.0;
	if (dynamic_water_enabled && !live_contact_from_compositor) {
		float dist_to_camera = length(vec3(v_world_pos.x, sea_level, v_world_pos.z) - camera_world_position);
		WaterSurfaceContractSample surface = water_surface_query(
			v_world_pos,
			dist_to_camera,
			dynamic_water_use_fft,
			dynamic_water_has_shore_mask,
			true
		);
		contact_wetness = (1.0 - smoothstep(surface.y, surface.y + wet_margin_safe, v_world_pos.y))
			* surface.body_gate;
	}
	float retained_wetness = live_contact_from_compositor
		? memory_wetness * retained_wetness_strength
		: dynamic_water_enabled
		? memory_wetness * (1.0 - contact_wetness) * retained_wetness_strength
		: memory_wetness;
	float wetness = max(contact_wetness, retained_wetness);

	if (wet_debug) {
		ALBEDO = mix(ALBEDO, vec3(0.0, 0.2, 0.8), wetness * 0.8);
	} else if (wetness > 0.001) {
		float porosity = clamp((base_roughness - 0.2) / 0.6, 0.0, 1.0);
		float effective_wet = wetness * porosity;
		ALBEDO *= mix(1.0, 1.0 - wet_albedo_darken, effective_wet);
		ROUGHNESS = mix(ROUGHNESS, wet_roughness_target, effective_wet);
	}
}
