// Per-pixel object wetness shader — Lagarde PBR wet surfaces.
// Darkens and glossifies only the portion of the mesh below wet_line_y.
// wet_line_y tracks the "high water mark" and decays over time (drying from top).
//
// Usage: assign as ShaderMaterial on any MeshInstance3D.
// Push wet_line_y from GDScript via RenderingServer.material_set_param().

shader_type spatial;

// Object appearance (set from GDScript to match the original material)
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.7;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float specular : hint_range(0.0, 1.0) = 0.5;
uniform sampler2D albedo_texture : source_color, hint_default_white;

// Wet map parameters
uniform float wet_line_y = -1000.0; // world-space Y of the water line on this object
uniform float wet_margin : hint_range(0.0, 2.0) = 0.3; // capillary rise above wet_line
uniform float wet_albedo_darken : hint_range(0.0, 1.0) = 0.6;
uniform float wet_roughness_target : hint_range(0.0, 0.3) = 0.05;
uniform bool wet_debug = false;

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

	// Per-pixel wetness: only pixels below wet_line_y get wet
	float wetness = smoothstep(wet_line_y + wet_margin, wet_line_y, v_world_pos.y);

	if (wet_debug) {
		ALBEDO = mix(ALBEDO, vec3(0.0, 0.2, 0.8), wetness * 0.8);
	} else if (wetness > 0.001) {
		float porosity = clamp((base_roughness - 0.2) / 0.6, 0.0, 1.0);
		float effective_wet = wetness * porosity;
		ALBEDO *= mix(1.0, 1.0 - wet_albedo_darken, effective_wet);
		ROUGHNESS = mix(ROUGHNESS, wet_roughness_target, effective_wet);
	}
}
