shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

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
uniform float shore_depth_scale : hint_range(0.0, 100.0) = 50.0; // Depth at which shore effect fades (OpenMW-style)
uniform bool debug_shore_mask = false; // Debug: visualize shore damping factor
uniform vec3 camera_position_world; // True camera position for smooth LOD/fade

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
varying vec3 world_pos_val;

// Sample shore mask - 1.0 = ocean, 0.0 = land
float sample_shore_mask(vec2 world_xz) {
	vec2 uv = (world_xz - shore_mask_bounds.xy) / shore_mask_bounds.zw;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		return 1.0; // Outside mask bounds = assume ocean
	}
	return texture(shore_mask, uv).r;
}

void vertex() {
	// Standard Mode: VERTEX is local.
	// Calculate world position explicitly for sampling waves/shore.
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_pos_val = world_pos;

	// UV uses absolute world coordinates so wave patterns stay fixed in the world.
	UV = world_pos.xz;

	// Distance factor uses distance from camera for smooth LOD falloff.
	float dist_to_cam = length(world_pos.xz - camera_position_world.xz);
	float distance_factor = min(exp(-(dist_to_cam - 150.0)*0.007), 1.0);

	// Sample shore mask using world coordinates (fixed to terrain).
	// Note: Vertex shader only has shore mask, no depth buffer access.
	// Fragment shader will refine with dual-factor detection.
	shore_factor = sample_shore_mask(world_pos.xz);

	// Read displacements from displacement maps with cascade-specific shore weights.
	// OpenMW-style: large swells (cascade 0) suppressed more than small ripples (cascade 2+)
	vec3 displacement = vec3(0);
	for (uint i = 0U; i < num_cascades; ++i) {
		vec4 scales = map_scales[i];
		vec3 cascade_disp = texture(displacements, vec3(UV*scales.xy, float(i))).xyz * scales.z;

		// All cascades fully suppressed at shore (shore_factor=0 means flat)
		displacement += cascade_disp * shore_factor;
	}

	// Apply distance fade
	float total_fade = distance_factor;
	wave_height = displacement.y * total_fade;

	// Displacement is applied to local VERTEX.
	// This prevents geometry jitter since local coordinates are small.
	VERTEX += displacement * total_fade;
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
	float dist_to_cam = length(world_pos_val.xz - camera_position_world.xz);

	// ============ DUAL-FACTOR SHORE DETECTION (OpenMW-style) ============
	// Factor 1: Shore mask (pre-baked texture)
	float shore_map_factor = sample_shore_mask(world_pos_val.xz);

	// Factor 2: Depth buffer (runtime, for more accurate detection near shore)
	float depth_raw = texture(depth_texture, SCREEN_UV).r;
	vec4 floor_pos_view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth_raw, 1.0);
	float floor_depth = floor_pos_view.z / floor_pos_view.w;
	float early_water_depth = max(VERTEX.z - floor_depth, 0.0);
	float depth_buffer_factor = smoothstep(0.0, shore_depth_scale, early_water_depth);

	// Conservative blend: take MINIMUM so waves calm when EITHER detects shore
	float frag_shore_factor = min(shore_map_factor, depth_buffer_factor);

	// Read foam and normal information from normal maps.
	// All cascades fully suppressed at shore for completely flat water
	vec3 gradient = vec3(0);
	for (uint i = 0U; i < num_cascades; ++i) {
		vec4 scales = map_scales[i];
		vec3 coords = vec3(UV*scales.xy, float(i));
		float ppm = map_size * min(scales.x, scales.y); // Pixels per meter
		// Mix between bicubic and bilinear filtering depending on the world space pixels per meter.
		vec4 normal_sample = mix(texture_bicubic(normals, coords), texture(normals, coords), min(1.0, ppm*0.1));

		// All cascades use same shore weight - fully flat at shore
		gradient += normal_sample.xyw * vec3(scales.ww * frag_shore_factor, 1.0);
	}

	foam_factor = smoothstep(0.0, 1.0, gradient.z*0.75) * exp(-dist_to_cam*0.0075);

	// Blend normal with flat normal as distance increases, and damp near shore
	float effective_normal_strength = mix(0.015, normal_strength, exp(-dist_to_cam*0.0175)) * frag_shore_factor;
	gradient *= effective_normal_strength;
	NORMAL = (VIEW_MATRIX * vec4(normalize(vec3(-gradient.x, 1.0, -gradient.y)), 0.0)).xyz;

	fresnel = mix(pow(1.0 - dot(VIEW, NORMAL), 5.0*exp(-2.69*roughness)) / (1.0 + 22.7*pow(roughness, 1.5)), 1.0, REFLECTANCE);

	// Refraction using screen texture
	vec2 refraction_offset = NORMAL.xy * refraction_strength;
	vec3 refracted_color = textureLod(screen_texture, SCREEN_UV + refraction_offset, 0.0).rgb;

	// Depth-based transparency
	// Reuse water_depth from dual-factor shore detection (already calculated above)
	float water_depth = early_water_depth;

	// ============ SHALLOW WATER COLOR ============
	// Key insight: Real water ALWAYS has color, even at 0 depth, due to:
	// 1. Scattering from suspended particles
	// 2. Surface reflection of the sky
	// 3. The water surface itself has color

	// Minimum water color blend - even at depth 0, water is not invisible
	const float MIN_WATER_BLEND = 0.35; // 35% water color minimum in shallows
	const float DEPTH_SCALE = 8.0; // Depth in meters where water becomes mostly opaque

	// Exponential falloff - water color increases rapidly with depth
	float depth_blend = 1.0 - exp(-water_depth / DEPTH_SCALE);
	// Ensure minimum water presence even at zero depth
	float water_amount = MIN_WATER_BLEND + (1.0 - MIN_WATER_BLEND) * depth_blend;

	// Blend refraction with water color additively in shallows for that "tinted" look
	// In deep water, transition to pure water color
	vec3 shallow_tint = mix(refracted_color, refracted_color * water_color.rgb * 1.5 + water_color.rgb * 0.4, 0.7);
	vec3 water_with_refraction = mix(shallow_tint, water_color.rgb, water_amount);

	// Fresnel: at glancing angles, show more reflection (water_color), less refraction
	// This gives water its characteristic "solid" look when viewed at low angles
	vec3 final_water = mix(water_with_refraction, water_color.rgb, fresnel * 0.6);

	ALBEDO = mix(final_water, foam_color.rgb, foam_factor);

	// Alpha: Water should be mostly opaque - transparency is handled through
	// the color blend above (refracted_color mixed with water_color).
	// Minimum alpha of 0.7 even at depth=0 gives water its inherent "presence"
	// Only fade alpha at shore mask boundaries (frag_shore_factor).
	float depth_alpha = mix(0.7, 1.0, smoothstep(0.0, 2.0, water_depth)); // 70% min, 100% at 2m depth
	ALPHA = depth_alpha * frag_shore_factor;

	// Debug mode: visualize frag_shore_factor as color gradient
	// Magenta/pink (1,0,1) = shore (low damping), Cyan (0,1,1) = deep water (no damping)
	if (debug_shore_mask) {
		// frag_shore_factor: 0 = land, 1 = ocean
		// We want: near shore (low frag_shore_factor) = magenta, deep (high frag_shore_factor) = cyan
		vec3 shore_color = vec3(1.0, 0.0, 1.0);  // Magenta for shore
		vec3 ocean_color = vec3(0.0, 1.0, 1.0);  // Cyan for deep ocean
		ALBEDO = mix(shore_color, ocean_color, frag_shore_factor);
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
