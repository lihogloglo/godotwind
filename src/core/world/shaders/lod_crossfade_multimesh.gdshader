shader_type spatial;
render_mode cull_back;

// =============================================================================
// LOD Crossfade Shader for MultiMesh Batching (Phase 3 MID registry)
// =============================================================================
// Per-instance spawn-driven fade. Each MultiMesh slot's INSTANCE_CUSTOM is
// written once at slot claim by PrototypeRegistry.add_instance:
//   INSTANCE_CUSTOM.x = spawn_time     (Engine TIME value at add)
//   INSTANCE_CUSTOM.y = fade_duration  (typically 0.3 s)
//   INSTANCE_CUSTOM.z = reserved
//   INSTANCE_CUSTOM.w = reserved
//
// The shader computes fade_amount internally — no CPU-side Tween, no
// per-frame material-parameter updates. Once TIME - spawn_time >=
// fade_duration the pixel is at full opacity and the dither is a no-op
// (the discard path is never taken once fade_amount >= 1).
//
// Mirrors Phase 2's lod_crossfade.gdshader — same formula, same dither
// include, just fed from per-instance custom data instead of a whole-
// material uniform.
// =============================================================================

#include "res://src/core/world/shaders/dither_include.gdshaderinc"

group_uniforms Material;
// Material properties preserved from source StandardMaterial3D
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap_anisotropic;
uniform float normal_scale : hint_range(-2.0, 2.0) = 1.0;
uniform bool use_normal_map = false;  // Only apply normal map if explicitly enabled
uniform float roughness : hint_range(0.0, 1.0) = 0.5;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float specular : hint_range(0.0, 1.0) = 0.5;

group_uniforms AlphaCutout;
// Alpha cutout for vegetation and transparent materials
uniform float alpha_cutout : hint_range(0.0, 1.0) = 0.5;
uniform bool use_alpha_cutout = false;

group_uniforms Debug;
// Debug mode: tint by LOD level (set via shader global or material override)
uniform bool debug_lod_colors = false;
// LOD level for this batch (0-3, set by batcher)
uniform int lod_level : hint_range(0, 3) = 1;

// Per-instance fade timing passed through varying (flat — same per primitive).
varying flat float v_spawn_time;
varying flat float v_fade_duration;

void vertex() {
	// INSTANCE_CUSTOM is written once per slot by PrototypeRegistry. Layout:
	//   .x = spawn_time, .y = fade_duration (see prototype_registry.gd
	//   add_instance + design doc §6).
	v_spawn_time = INSTANCE_CUSTOM.x;
	v_fade_duration = INSTANCE_CUSTOM.y;
}

void fragment() {
	// Sample albedo texture
	vec4 albedo_sample = texture(albedo_texture, UV) * albedo_color;

	// Alpha cutout first (for vegetation, fences, etc.)
	if (use_alpha_cutout && albedo_sample.a < alpha_cutout) {
		discard;
	}

	// Auto-computed fade from slot's spawn_time + fade_duration. Once
	// TIME - spawn_time >= fade_duration, fade_amount stays clamped to 1.0
	// and the shader is functionally identical to the unfaded path.
	// max() on denominator guards a zero-duration custom data row (never
	// intended, but cheaper to clamp than branch).
	float fade_amount = clamp(
		(TIME - v_spawn_time) / max(v_fade_duration, 0.0001),
		0.0, 1.0
	);

	// Screen-door dithering for smooth in/out transitions (shared include).
	// When fade_amount = 1.0: all pixels pass (fully visible).
	// When fade_amount = 0.5: ~50% of pixels pass (half visible).
	// When fade_amount = 0.0: no pixels pass (invisible).
	float dither_threshold = get_dither_threshold(ivec2(FRAGCOORD.xy));

	if (dither_threshold >= fade_amount) {
		discard;
	}

	// Standard PBR material output
	vec3 final_albedo = albedo_sample.rgb;

	// Debug: Tint by LOD level if enabled
	// LOD0 = Green (NEAR), LOD1 = Yellow (MID close), LOD2 = Orange (MID far), LOD3 = Red (FAR)
	if (debug_lod_colors) {
		vec3 lod_colors[4] = vec3[4](
			vec3(0.0, 1.0, 0.0),   // LOD0 = Green
			vec3(1.0, 1.0, 0.0),   // LOD1 = Yellow
			vec3(1.0, 0.5, 0.0),   // LOD2 = Orange
			vec3(1.0, 0.0, 0.0)    // LOD3 = Red
		);
		int clamped_lod = clamp(lod_level, 0, 3);
		final_albedo = mix(final_albedo, lod_colors[clamped_lod], 0.5);
	}

	ALBEDO = final_albedo;

	// NOTE: Normal mapping disabled for LOD meshes to avoid tangent requirements.
	// Many prebaked LOD meshes don't have tangent data. If you need normal maps:
	// 1. Enable use_normal_map in the material
	// 2. Ensure the mesh has tangents (generate_tangents() in SurfaceTool)

	ROUGHNESS = roughness;
	METALLIC = metallic;
	SPECULAR = specular;
}
