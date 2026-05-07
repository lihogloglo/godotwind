shader_type spatial;

#define MAX_CASCADES 8

// ============================================================================
// Underwater Volume — Step 2 (caustics + absorption + wobble)
// ============================================================================
//
// Ported from paddy-exe/Godot-RealTimeCaustics (MIT license):
//   https://github.com/paddy-exe/Godot-RealTimeCaustics
//   Caustics.gdshader at branch 4.3+
//
// Architecture: a BoxMesh with front-face culling + depth-test disabled, so
// the shader runs when the camera is INSIDE the volume. A box follower node
// (src/core/water/underwater_volume.gd) parents the box to the camera's
// position each frame (position only — rotation stays axis-aligned with
// world), and sizes/positions it relative to OceanManager.get_sea_level().
//
// World position of the scene pixel behind the volume is reconstructed from
// DEPTH_TEXTURE + INV_PROJECTION_MATRIX + INV_VIEW_MATRIX, with an explicit
// OUTPUT_IS_SRGB branch so both Compatibility (OpenGL NDC) and Forward+/Mobile
// (Vulkan NDC) paths reconstruct correctly. That branch is the single most
// important thing we got wrong in the previous CompositorEffect attempt.
//
// ----------------------------------------------------------------------------
// DEVIATION FROM PADDY-EXE REFERENCE
// ----------------------------------------------------------------------------
// paddy-exe uses:
//     render_mode blend_add, cull_front, depth_test_disabled, ambient_light_disabled
// because its shader is purely additive caustics.
//
// We use:
//     render_mode blend_mix, cull_front, depth_test_disabled, unshaded
// because Step 1 will add Beer-Lambert absorption via mix(scene, tint, ...),
// which cannot coexist with blend_add. The shader will sample SCREEN_TEXTURE
// itself, do the mix internally, then add caustics on top in a single pass.
// For Step 0, we still only output caustics — the SCREEN_TEXTURE sample and
// absorption code lands in Step 1. This render_mode choice is an anticipatory
// adaptation, not a creative addition, made in advance so Step 0 and Step 1
// touch the same render state without requiring a re-verification of Step 0.
//
// `unshaded` replaces paddy's `ambient_light_disabled` + `light()` function
// approach: we don't need multi-light support, the underwater caustics should
// be driven by the directional sun only. Computing everything in fragment()
// instead of light() is simpler and matches our single-sun use case.
// ============================================================================

render_mode blend_mix, cull_front, depth_test_disabled, unshaded;

// ── Caustics ────────────────────────────────────────────────────────────────
uniform sampler2D caustics_noise : filter_linear, repeat_enable;
uniform float caustics_scale = 4.0;
uniform float caustics_speed = 0.1;
uniform float caustics_strength : hint_range(0.0, 4.0) = 1.0;
uniform float caustics_power : hint_range(0.25, 8.0) = 2.0;
uniform float caustics_chroma_split : hint_range(0.0, 0.02) = 0.002;
uniform float caustics_luminance_mask_strength : hint_range(-2.0, 2.0) = 0.2;
uniform sampler2D luma_gradient : hint_default_white;

// ── Sun direction (driven by GDScript from the active DirectionalLight3D) ──
// paddy-exe pulls LIGHT from light() and transforms to world space per-light.
// We project from a single sun direction set from CPU-side.
uniform vec3 sun_direction_world = vec3(0.3, 0.8, 0.2);

// ── Volume bounds (sea level + depth) ──────────────────────────────────────
// Set from GDScript each frame. `sea_level` is the Y of the water surface.
// `volume_depth` is how far below `sea_level` caustics are drawn.
uniform float sea_level = 0.0;
uniform float volume_depth = 40.0;
uniform bool use_dynamic_water_surface = false;
global uniform uint num_cascades;
global uniform sampler2DArray displacements;
uniform vec4 map_scales[MAX_CASCADES];
uniform float wave_scale = 1.0;
uniform sampler2D shore_mask : filter_linear_mipmap;
uniform vec4 shore_mask_bounds = vec4(-8000.0, -8000.0, 16000.0, 16000.0);
uniform float shore_fade_distance : hint_range(10.0, 200.0) = 50.0;
uniform float ocean_time = 0.0;
uniform float shore_wave_amplitude : hint_range(0.0, 2.0) = 0.5;
uniform float shore_wave_frequency : hint_range(0.02, 0.5) = 0.1;
uniform float shore_wave_speed : hint_range(0.1, 5.0) = 0.4;
uniform float shore_wave_steepness : hint_range(0.0, 1.0) = 0.5;

// ── Absorption (Step 1) ────────────────────────────────────────────────────
// Beer-Lambert: surviving fraction of scene color = exp(-sigma * travel_distance)
// Matches the structure in DIVE.omwfx, values chosen for Morrowind-looking water.
// `water_tint` is the color light converges TO at infinite depth.
// `sigma_scale` scales absorption rate in world units (larger = darker faster).
uniform vec3 water_tint : source_color = vec3(0.015, 0.115, 0.145);
uniform vec3 absorption_sigma = vec3(0.12, 0.03, 0.018);
// Minimum travel distance before absorption kicks in — avoids aggressive
// darkening on geometry right next to the camera.
uniform float absorption_min_travel : hint_range(0.0, 5.0) = 0.0;

// ── Wobble (Step 2) ────────────────────────────────────────────────────────
// Vision distortion from the deformed water column above / around the pixel.
// Uses a REAL water normal texture (openmw/files/data/textures/omw/water_nm.png)
// sampled at world-space XZ with time animation. Not procedural FBM — that
// produced visible horizontal banding in the previous implementation.
//
// The normal's xy (decoded from [0,1] to [-1,1]) is used as a SCREEN_UV offset
// to re-sample SCREEN_TEXTURE. Pattern is anchored to world XZ, so looking at
// the same rock from different angles shows the same refraction deformation.
uniform sampler2D water_normal_map : hint_normal, filter_linear, repeat_enable;
uniform float wobble_strength : hint_range(0.0, 0.1) = 0.025;
uniform float wobble_tiling : hint_range(0.5, 20.0) = 6.0;  // world units per tile
uniform vec2 wobble_speed = vec2(0.15, 0.08);
uniform bool wobble_enabled = true;
uniform int debug_mode = 0; // 0 final, 1 slab mask, 2 depth/Y, 3 exaggerated wobble

// ── Screen reconstruction ──────────────────────────────────────────────────
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture;


// ── Helpers (from paddy-exe, verbatim) ─────────────────────────────────────

vec2 panner(vec2 uv, float speed, float tiling) {
	return (vec2(1.0, 0.0) * TIME * speed) + (uv * tiling);
}

vec3 aberration_sample(sampler2D tex, vec2 uv, float split) {
	vec2 uv1 = uv + vec2(split, split);
	vec2 uv2 = uv + vec2(split, -split);
	vec2 uv3 = uv + vec2(-split, -split);
	float r = texture(tex, uv1).r;
	float g = texture(tex, uv2).r;
	float b = texture(tex, uv3).r;
	return vec3(r, g, b);
}

float luminance(vec3 color) {
	return dot(color, vec3(0.299, 0.587, 0.114));
}

float shore_breaker_envelope(float raw_dist) {
	float dist_t = clamp(raw_dist / max(shore_fade_distance, 0.001), 0.0, 1.0);
	float shore_ramp = smoothstep(0.03, 0.22, dist_t);
	float offshore_fade = 1.0 - smoothstep(0.45, 0.90, dist_t);
	return shore_ramp * offshore_fade;
}

float shore_runup_envelope(float raw_dist) {
	float dist_t = clamp(raw_dist / max(shore_fade_distance, 0.001), 0.0, 1.0);
	return 1.0 - smoothstep(0.00, 0.16, dist_t);
}

// Build a rotation matrix whose +Z axis points along `direction`.
// Used to project world positions into a caustic UV plane perpendicular to
// the sun direction (caustics look right when they come from "above" relative
// to the sun, not from world up).
mat3 make_rotation_dir(vec3 direction, vec3 up) {
	vec3 xaxis = normalize(cross(up, direction));
	vec3 yaxis = normalize(cross(direction, xaxis));
	return mat3(
		vec3(xaxis.x, yaxis.x, direction.x),
		vec3(xaxis.y, yaxis.y, direction.y),
		vec3(xaxis.z, yaxis.z, direction.z)
	);
}

float get_dynamic_water_level(vec2 world_xz, float dist_to_camera) {
	if (!use_dynamic_water_surface) {
		return sea_level;
	}

	vec3 displacement = vec3(0.0);
	for (uint i = 0U; i < num_cascades; ++i) {
		vec4 scales = map_scales[i];
		float tile_size = 1.0 / max(scales.x, 1e-6);
		float cascade_fade = clamp(exp(-(dist_to_camera - 50.0) / (tile_size * 20.0)), 0.0, 1.0);
		vec3 cascade_disp = texture(displacements, vec3(world_xz * scales.xy, float(i))).xyz * scales.z * cascade_fade;
		displacement += cascade_disp;
	}

	vec2 shore_uv = (world_xz - shore_mask_bounds.xy) / shore_mask_bounds.zw;
	bool in_mask = shore_uv.x >= 0.0 && shore_uv.x <= 1.0 && shore_uv.y >= 0.0 && shore_uv.y <= 1.0;
	vec4 shore_data = in_mask ? texture(shore_mask, shore_uv) : vec4(1.0, 0.5, 0.5, 1.0);
	float shore = shore_data.r;
	float water_y = sea_level + displacement.y * wave_scale * shore;

	float raw_dist = shore_data.a * shore_fade_distance;
	vec2 shore_dir = shore_data.gb * 2.0 - 1.0;
	float shore_dir_len = length(shore_dir);
	if (shore_dir_len > 0.01 && shore_wave_amplitude > 0.0 && raw_dist > 0.05) {
		float phase = raw_dist * shore_wave_frequency * 6.2832 + ocean_time * shore_wave_speed * 6.2832;
		float sin_phase = sin(phase);
		float breaker_env = shore_breaker_envelope(raw_dist);
		float runup_env = shore_runup_envelope(raw_dist);
		float crest = smoothstep(0.0, 1.0, sin_phase);
		water_y += shore_wave_amplitude * (
			breaker_env * sin_phase
			+ runup_env * crest * 0.35
		);
	}

	return water_y;
}


void vertex() {
	// No vertex displacement — the BoxMesh is already in the right place.
}


void fragment() {
	// Step 2 specialist review note: previously declared as `varying` but
	// written in fragment() — that's unspecified behavior in Godot's shader
	// language. Now plain locals inside fragment(), which is what they
	// functionally were all along.
	vec3 scene_world_pos;
	vec3 scene_color;
	float inside_volume;

	// Reconstruct world position of whatever opaque pixel is BEHIND the volume
	// at this screen UV. Paddy-exe's exact pattern with the OUTPUT_IS_SRGB
	// branch for Vulkan-vs-OpenGL NDC convention.
	float depth = texture(DEPTH_TEXTURE, SCREEN_UV).x;
	vec3 ndc;
	if (OUTPUT_IS_SRGB) {
		// Compatibility path: OpenGL NDC [-1, 1] on all axes
		ndc = vec3(SCREEN_UV, depth) * 2.0 - 1.0;
	} else {
		// Forward+ / Mobile: Vulkan NDC [-1, 1] xy, [0, 1] z (reversed-Z)
		ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
	}
	vec4 world4 = INV_VIEW_MATRIX * INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	scene_world_pos = world4.xyz / world4.w;

	// ── Wobble (Step 2) ──
	// Sample the water normal at world XZ so the wobble pattern is anchored to
	// the world, not the camera. Apply the resulting normal.xy as a SCREEN_UV
	// offset — this distorts the re-sampled SCREEN_TEXTURE the way light
	// refraction through a wavy surface would. Time-animated via wobble_speed.
	vec2 nm_uv = scene_world_pos.xz / wobble_tiling + TIME * wobble_speed;
	vec3 nm_sample = texture(water_normal_map, nm_uv).xyz;
	vec2 wobble_offset = (nm_sample.xy * 2.0 - 1.0) * wobble_strength;
	if (!wobble_enabled) {
		wobble_offset = vec2(0.0);
	}

	// Guard against sampling outside the viewport — refracted off-screen
	// pixels would return garbage. Clamp to [0,1].
	vec2 wobbled_uv = clamp(SCREEN_UV + wobble_offset, vec2(0.0), vec2(1.0));
	vec3 cam_pos = INV_VIEW_MATRIX[3].xyz;

	// ── Above-water guard ──
	// The wobble offset might point at a neighbor pixel that belongs to
	// above-water geometry (pillar tops, monolith, sky). If we blindly sampled
	// that, we'd paint the ABOVE-water content into the BELOW-water fragment,
	// producing a visible ghost/double-image at the waterline. Same invariant
	// that every physically-motivated water shader enforces (DIVE, GodotSSR,
	// visual_water.gdshader).
	//
	// Fix: reconstruct the NEIGHBOR pixel's world Y. If the neighbor is not
	// below sea_level, fall back to an unwobbled sample for this fragment.
	// Sky pixels (far plane) are rejected explicitly — their reconstructed
	// world Y is garbage and might randomly pass the sea_level test.
	float neighbor_depth = texture(DEPTH_TEXTURE, wobbled_uv).x;
	bool neighbor_is_sky;
	if (OUTPUT_IS_SRGB) {
		// OpenGL NDC: far plane = 1.0
		neighbor_is_sky = neighbor_depth >= 0.9999;
	} else {
		// Vulkan reversed-Z: far plane = 0.0
		neighbor_is_sky = neighbor_depth <= 0.0001;
	}

	if (neighbor_is_sky) {
		// Sky — don't sample wobbled; fall back to the unrefracted UV so the
		// waterline doesn't get sky color stamped below it.
		wobbled_uv = SCREEN_UV;
	} else {
		vec3 neighbor_ndc;
		if (OUTPUT_IS_SRGB) {
			neighbor_ndc = vec3(wobbled_uv, neighbor_depth) * 2.0 - 1.0;
		} else {
			neighbor_ndc = vec3(wobbled_uv * 2.0 - 1.0, neighbor_depth);
		}
		vec4 neighbor_world4 = INV_VIEW_MATRIX * INV_PROJECTION_MATRIX * vec4(neighbor_ndc, 1.0);
		vec3 neighbor_world = neighbor_world4.xyz / neighbor_world4.w;
		float neighbor_dist = length(neighbor_world - cam_pos);
		float neighbor_water_level = get_dynamic_water_level(neighbor_world.xz, neighbor_dist);
		if (neighbor_world.y > neighbor_water_level) {
			// Above-water neighbor — fall back.
			wobbled_uv = SCREEN_UV;
		}
	}

	// Re-sample the scene color at the (possibly unwobbled) UV. Absorption
	// and caustics continue to use the UN-wobbled world position — wobble is
	// a visual-only refraction, not a physical ray bend. DIVE.omwfx takes the
	// same stance.
	scene_color = texture(SCREEN_TEXTURE, wobbled_uv).rgb;
	float camera_scene_dist = length(scene_world_pos - cam_pos);
	float water_level = get_dynamic_water_level(scene_world_pos.xz, camera_scene_dist);

	// Test whether the scene pixel is inside the caustic volume.
	// Volume is an axis-aligned slab: [sea_level - volume_depth, sea_level] in Y.
	// (The BoxMesh also constrains X/Z to the follower box, but Y is the
	// physically meaningful bound — we want caustics on the seafloor, not above
	// water, and not drawn on the sky when depth==1.)
	float y_top = water_level - 0.03;
	float y_bot = water_level - volume_depth;
	inside_volume = step(y_bot, scene_world_pos.y) * step(scene_world_pos.y, y_top);

	if (debug_mode == 1) {
		if (inside_volume < 0.5) {
			ALBEDO = vec3(0.0);
			ALPHA = 0.0;
		} else {
			ALBEDO = vec3(0.0, 0.85, 1.0);
			ALPHA = 0.85;
		}
	} else if (debug_mode == 2) {
		if (inside_volume < 0.5) {
			ALBEDO = vec3(0.0);
			ALPHA = 0.0;
		} else {
			float depth_band = clamp((water_level - scene_world_pos.y) / max(volume_depth, 0.001), 0.0, 1.0);
			ALBEDO = vec3(depth_band, 1.0 - depth_band, 0.25);
			ALPHA = 0.85;
		}
	} else if (inside_volume < 0.5) {
		// Pixel is above water or below the volume — draw fully transparent.
		// The slab test also rejects the ocean surface seen from below (@water's
		// flat dark ceiling) because those pixels reconstruct to world_pos.y
		// ≈ sea_level which sits AT the slab top, not inside it.
		ALBEDO = vec3(0.0);
		ALPHA = 0.0;
	} else {
		// ── Step 1: Beer-Lambert absorption ─────────────────────────────────
		// Travel distance = camera to scene pixel, in world units.
		// Uses actual view-space distance, not just vertical depth, so looking
		// sideways at a distant rock darkens correctly too.
		float travel = max(length(scene_world_pos - cam_pos) - absorption_min_travel, 0.0);
		vec3 transmittance = exp(-absorption_sigma * travel);
		if (debug_mode == 3 && wobble_enabled) {
			vec2 debug_uv = clamp(SCREEN_UV + wobble_offset * 4.0, vec2(0.0), vec2(1.0));
			scene_color = mix(texture(SCREEN_TEXTURE, debug_uv).rgb, vec3(0.0, 0.9, 1.0), 0.35);
		}
		vec3 absorbed = mix(water_tint, scene_color, transmittance);

		// ── Step 0: Caustics (unchanged, just applied AFTER absorption) ─────
		mat3 lrm = make_rotation_dir(sun_direction_world, vec3(0.0, 1.0, 0.0));
		vec2 caustic_uv = (lrm * scene_world_pos).xy;

		vec2 uv1 = panner(caustic_uv, 0.75 * caustics_speed, 1.0 / caustics_scale);
		vec2 uv2 = panner(caustic_uv, caustics_speed, -1.0 / caustics_scale);

		vec3 caus1 = aberration_sample(caustics_noise, uv1, caustics_chroma_split);
		vec3 caus2 = aberration_sample(caustics_noise, uv2, caustics_chroma_split);
		caus1 = pow(caus1, vec3(caustics_power));
		caus2 = pow(caus2, vec3(caustics_power));
		vec3 c = min(caus1, caus2) * caustics_strength;

		// Luminance masking — caustics fade on dark surfaces so they don't
		// blow out shadowed geometry. Use ABSORBED scene luma so the mask
		// responds to what the viewer actually sees, not the raw (pre-tinted)
		// input.
		float scene_luma = luminance(absorbed);
		scene_luma = texture(luma_gradient, vec2(scene_luma)).r;
		float luma_mask = mix(1.0, scene_luma, caustics_luminance_mask_strength);

		// Caustics also attenuate with travel distance — the light focused
		// onto the seafloor has to travel back through the same water column
		// to reach the camera, so it's absorbed on the way back. Reusing
		// `transmittance` here is correct: same optical path, same attenuation.
		vec3 caustics_output = c * luma_mask * transmittance;

		ALBEDO = absorbed + caustics_output;
		ALPHA = 1.0;
	}
}
