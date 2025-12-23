shader_type spatial;
render_mode world_vertex_coords, blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

// Godot 4.3+ requires explicit screen texture samplers
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;
/**
 * Water lighting model roughly follows the 2019 GDC talk: "Wakes, Explosions and Lighting: Interactive Water Simulation in Atlas".
 * Source: https://gpuopen.com/gdc-presentations/2019/gdc-2019-agtd6-interactive-water-simulation-in-atlas.pdf
 */

#define MAX_CASCADES 8    // I am unsure how to generalize this.
#define REFLECTANCE  0.02 // Reflectance from air to water (eta=1.33).

global uniform vec4 water_color : source_color;
global uniform vec4 foam_color : source_color;

uniform float roughness : hint_range(0.0, 1.0) = 0.4;
uniform float normal_strength : hint_range(0.0, 1.0) = 1.0; // Global normal strength
uniform float refraction_strength : hint_range(0.0, 0.3) = 0.05; // Refraction distortion amount
uniform float water_clarity : hint_range(0.0, 1.0) = 0.15; // How clear/transparent the water is (lower = murkier)
uniform float depth_fade_distance : hint_range(0.0, 100.0) = 2.0; // Distance for depth fade (lower = faster opacity)
uniform bool debug_shore_mask = false; // Debug: visualize shore damping factor

// Shore mask for fading ocean on land
uniform sampler2D shore_mask : filter_linear;
uniform vec4 shore_mask_bounds = vec4(-8000.0, -8000.0, 16000.0, 16000.0); // x, y, width, height

group_uniforms cascade_data;
uniform vec4 map_scales[MAX_CASCADES];               // Scales for displacement/normal maps. Packed: [uv scale, displacement scale, normal scale]
global uniform uint num_cascades;
global uniform sampler2DArray displacements;         // Each layer represents one wave cascade.
global uniform sampler2DArray normals : hint_normal; // Each layer represents one wave cascade.

varying float wave_height;
varying float foam_factor;
varying float fresnel;
varying float shore_factor;

// Sample shore mask - 1.0 = ocean, 0.0 = land
float sample_shore_mask(vec2 world_xz) {
	vec2 uv = (world_xz - shore_mask_bounds.xy) / shore_mask_bounds.zw;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		return 1.0; // Outside mask bounds = assume ocean
	}
	return texture(shore_mask, uv).r;
}

void vertex() {
	// Compute world position for shore mask (needs to be fixed to terrain, not camera)
	// With world_vertex_coords, VERTEX is in local space. NODE_POSITION_WORLD gives mesh origin.
	vec3 world_pos = NODE_POSITION_WORLD + VERTEX;

	// UV uses world coordinates so waves tile correctly in world space (not camera-relative)
	UV = world_pos.xz;

	// Distance factor uses local coords (relative to camera) for LOD falloff
	float distance_factor = min(exp(-(length(VERTEX.xz) - 150.0)*0.007), 1.0); // Displacement amount falls off after 150m.

	// Sample shore mask using world coordinates (fixed to terrain, not camera)
	shore_factor = sample_shore_mask(world_pos.xz);

	// Read displacements from displacement maps.
	vec3 displacement = vec3(0);
	for (uint i = 0U; i < num_cascades; ++i) {
		vec4 scales = map_scales[i];
		displacement += texture(displacements, vec3(UV*scales.xy, float(i))).xyz * scales.z;
	}
	// Dampen waves on shore
	float total_fade = distance_factor * shore_factor;
	wave_height = displacement.y * total_fade;

	// CRITICAL FIX: With world_vertex_coords, VERTEX output must be in world space.
	// We set VERTEX to world_pos + displacement so the ocean stays fixed in place
	// while the mesh center follows the camera for LOD purposes.
	VERTEX = world_pos + displacement * total_fade;
}

/** Filter weights for a cubic B-spline. */
vec4 cubic_weights(float a) {
	float a2 = a*a;
	float a3 = a2*a;
	
	float w0 =-a3     + a2*3.0 - a*3.0 + 1.0;
	float w1 = a3*3.0 - a2*6.0         + 4.0;
	float w2 =-a3*3.0 + a2*3.0 + a*3.0 + 1.0;
	float w3 = a3;
	return vec4(w0, w1, w2, w3) / 6.0;
}

/** Performs bicubic B-spline filtering on the provided sampler. */
// Source: https://developer.nvidia.com/gpugems/gpugems2/part-iii-high-quality-rendering/chapter-20-fast-third-order-texture-filtering
vec4 texture_bicubic(in sampler2DArray sampler, in vec3 uvw) {
	vec2 dims = vec2(textureSize(sampler, 0).xy);
	vec2 dims_inv = 1.0 / dims;
	uvw.xy = uvw.xy*dims + 0.5;
	
	vec2 fuv = fract(uvw.xy);
	vec4 wx = cubic_weights(fuv.x);
	vec4 wy = cubic_weights(fuv.y);

	vec4 g = vec4(wx.xz + wx.yw, wy.xz + wy.yw);
	vec4 h = (vec4(wx.yw, wy.yw) / g + vec2(-1.5, 0.5).xyxy + floor(uvw.xy).xxyy)*dims_inv.xxyy;
	vec2 w = g.xz / (g.xz + g.yw);
    return mix(
		mix(texture(sampler, vec3(h.yw, uvw.z)), texture(sampler, vec3(h.xw, uvw.z)), w.x),
		mix(texture(sampler, vec3(h.yz, uvw.z)), texture(sampler, vec3(h.xz, uvw.z)), w.x), w.y); 
}

void fragment() {
	float map_size = float(textureSize(normals, 0).x);
	float dist = length(VERTEX.xz);
	// Read foam and normal information from normal maps.
	vec3 gradient = vec3(0);
	for (uint i = 0U; i < num_cascades; ++i) {
		vec4 scales = map_scales[i];
		vec3 coords = vec3(UV*scales.xy, float(i));
		float ppm = map_size * min(scales.x, scales.y); // Pixels per meter
		// Mix between bicubic and bilinear filtering depending on the world space pixels per meter.
		// This is dependent on the tile size as well as displacement/normal map resolution.
		gradient += mix(texture_bicubic(normals, coords), texture(normals, coords), min(1.0, ppm*0.1)).xyw * vec3(scales.ww, 1.0);
	}

	// FIXED: Dampen gradient by shore_factor so normals/foam match damped displacement
	gradient *= shore_factor;

	foam_factor = smoothstep(0.0, 1.0, gradient.z*0.75) * exp(-dist*0.0075);
	// Add shore foam (gentle foam at the shoreline)
	foam_factor += (1.0 - shore_factor) * 0.3;
	foam_factor = clamp(foam_factor, 0.0, 1.0);

	// Blend normal with flat normal as distance increases, and damp near shore
	float effective_normal_strength = mix(0.015, normal_strength, exp(-dist*0.0175)) * shore_factor;
	gradient *= effective_normal_strength;
	NORMAL = (VIEW_MATRIX * vec4(normalize(vec3(-gradient.x, 1.0, -gradient.y)), 0.0)).xyz;

	fresnel = mix(pow(1.0 - dot(VIEW, NORMAL), 5.0*exp(-2.69*roughness)) / (1.0 + 22.7*pow(roughness, 1.5)), 1.0, REFLECTANCE);

	// Refraction using screen texture
	vec2 refraction_offset = NORMAL.xy * refraction_strength;
	vec3 refracted_color = textureLod(screen_texture, SCREEN_UV + refraction_offset, 0.0).rgb;

	// Depth-based transparency
	// In view space, both values are negative (into screen)
	// water_depth: positive when floor is below water surface
	float depth = texture(depth_texture, SCREEN_UV).r;
	vec4 world_pos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float floor_depth = world_pos.z / world_pos.w;
	float water_depth = VERTEX.z - floor_depth; // Positive when floor is deeper than surface

	// Opacity increases with depth - murky water becomes opaque quickly
	// water_clarity controls how much of the floor shows through in shallow water
	// depth_fade_distance controls how quickly the water becomes opaque
	float depth_opacity = 1.0 - exp(-water_depth / depth_fade_distance);

	// Mix refracted color with water color based on depth
	// At depth 0: show refracted_color * water_clarity + water_color * (1-water_clarity)
	// At max depth: show water_color
	vec3 shallow_color = mix(water_color.rgb, refracted_color, water_clarity);
	vec3 water_with_refraction = mix(shallow_color, water_color.rgb, depth_opacity);
	ALBEDO = mix(water_with_refraction, foam_color.rgb, foam_factor);

	// Alpha: mostly opaque, only slightly transparent at shallow depths and glancing angles
	// CRITICAL: Multiply by shore_factor to hide ocean on land (0.0 = land, 1.0 = ocean)
	float base_alpha = mix(0.85, 1.0, depth_opacity); // 85% opaque minimum, 100% in deep water
	ALPHA = mix(base_alpha, 1.0, fresnel * 0.3) * shore_factor;

	// Debug mode: visualize shore_factor as color gradient
	// Magenta/pink (1,0,1) = shore (low damping), Cyan (0,1,1) = deep water (no damping)
	if (debug_shore_mask) {
		// shore_factor: 0 = land, 1 = ocean
		// We want: near shore (low shore_factor) = magenta, deep (high shore_factor) = cyan
		vec3 shore_color = vec3(1.0, 0.0, 1.0);  // Magenta for shore
		vec3 ocean_color = vec3(0.0, 1.0, 1.0);  // Cyan for deep ocean
		ALBEDO = mix(shore_color, ocean_color, shore_factor);
		ALPHA = 0.9;
		ROUGHNESS = 0.5;
		METALLIC = 0.0;
		SPECULAR = 0.0;
		SSS_STRENGTH = 0.0;
	} else {
		ROUGHNESS = mix(0.05, 0.6, foam_factor); // Smoother water, rougher foam
		METALLIC = 0.0;
		SPECULAR = 0.5;
		// Enable SSR for reflections
		SSS_STRENGTH = 0.05;
	}
}

float smith_masking_shadowing(in float cos_theta, in float alpha) {
	float a = cos_theta / (alpha * sqrt(1.0 - cos_theta*cos_theta)); // Approximate: 1.0 / (alpha * tan(acos(cos_theta)))
	float a_sq = a*a;
	return a < 1.6 ? (1.0 - 1.259*a + 0.396*a_sq) / (3.535*a + 2.181*a_sq) : 0.0;
}

// Source: https://github.com/godotengine/godot/blob/7b56111c297f24304eb911fe75082d8cdc3d4141/drivers/gles3/shaders/scene.glsl#L995
float ggx_distribution(in float cos_theta, in float alpha) {
	float a_sq = alpha*alpha;
	float d = 1.0 + (a_sq - 1.0) * cos_theta * cos_theta;
	return a_sq / (PI * d*d);
}

void light() {
	vec3 halfway = normalize(LIGHT + VIEW);
	float dot_nl = max(dot(NORMAL, LIGHT), 2e-5);
	float dot_nv = max(dot(NORMAL, VIEW), 2e-5);

	// --- SPECULAR ---
	float light_mask = smith_masking_shadowing(roughness, dot_nv);
	float view_mask = smith_masking_shadowing(roughness, dot_nl);
	float microfacet_distribution = ggx_distribution(dot(NORMAL, halfway), roughness);
	float geometric_attenuation = 1.0 / (1.0 + light_mask + view_mask);
	SPECULAR_LIGHT += fresnel * microfacet_distribution * geometric_attenuation / (4.0 * dot_nv + 0.1) * ATTENUATION;

	// --- DIFFUSE ---
	const vec3 sss_modifier = vec3(0.9,1.15,0.85); // Subsurface scattering produces a 'greener' color.
	float sss_height = 1.0*max(0.0, wave_height + 2.5) * pow(max(dot(LIGHT, -VIEW), 0.0), 4.0) * pow(0.5 - 0.5 * dot(LIGHT, NORMAL), 3.0);
	float sss_near = 0.5*pow(dot_nv, 2.0);
	float lambertian = 0.5*dot_nl;
	DIFFUSE_LIGHT += mix((sss_height + sss_near) * sss_modifier / (1.0 + light_mask) + lambertian, foam_color.rgb, foam_factor) * (1.0 - fresnel) * ATTENUATION * LIGHT_COLOR;
}
