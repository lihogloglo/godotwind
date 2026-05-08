// Terrain3D shader override — extracted from Terrain3D v1.0.1 internal C++ shader
// via RenderingServer.shader_get_code() on 2026-04-13.
//
// ONLY ADDITION: wet map block at end of fragment() (~15 lines).
// Horizon maps are PARKED — all horizon uniforms/code removed.
// This guarantees baseline parity with the internal shader.

shader_type spatial;
render_mode blend_mix,depth_draw_opaque,cull_back,diffuse_burley,specular_schlick_ggx,skip_vertex_transform;

// Private uniforms (set by Terrain3D C++ internals)
uniform vec3 _camera_pos = vec3(0.f);
uniform float _mesh_size = 48.f;
uniform uint _background_mode = 1u;
uniform uint _mouse_layer = 0x80000000u;
uniform float _vertex_spacing = 1.0;
uniform float _vertex_density = 1.0;
uniform float _region_size = 1024.0;
uniform float _region_texel_size = 0.0009765625;
uniform int _region_map_size = 32;
uniform int _region_map[1024];
uniform vec2 _region_locations[1024];
uniform float _texture_normal_depth_array[32];
uniform float _texture_ao_strength_array[32];
uniform float _texture_roughness_mod_array[32];
uniform float _texture_uv_scale_array[32];
uniform vec2 _texture_detile_array[32];
uniform vec4 _texture_color_array[32];
uniform highp sampler2DArray _height_maps : repeat_disable;
uniform highp sampler2DArray _control_maps : repeat_disable;
uniform highp sampler2DArray _color_maps : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform highp sampler2DArray _texture_array_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform highp sampler2DArray _texture_array_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;

// Public uniforms (from Terrain3D material settings)
uniform float blend_sharpness : hint_range(0, 1) = 0.5;
uniform bool flat_terrain_normals = false;
uniform bool enable_projection = true;
uniform float projection_threshold : hint_range(0.0, 0.99, 0.01) = 0.8;
uniform float mipmap_bias : hint_range(0.5, 1.5, 0.01) = 1.0;
uniform float depth_blur : hint_range(0.0, 35.0, 0.1) = 0.0;
uniform float bias_distance : hint_range(0.0, 16384.0, 0.1) = 512.0;
uniform bool enable_macro_variation = true;
uniform vec3 macro_variation1 : source_color = vec3(1.);
uniform vec3 macro_variation2 : source_color = vec3(1.);
uniform float macro_variation_slope : hint_range(0., 1.) = 0.333;
uniform highp sampler2D noise_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float noise1_scale : hint_range(0.001, 1.) = 0.04;
uniform float noise1_angle : hint_range(0, 6.283) = 0.;
uniform vec2 noise1_offset = vec2(0.5);
uniform float noise2_scale : hint_range(0.001, 1.) = 0.076;

// === CUSTOM: Wet map (only addition to internal shader) ===
uniform float sea_level_wet = 0.0;
uniform float wet_margin : hint_range(0.0, 5.0) = 1.5;
uniform float wet_albedo_darken : hint_range(0.0, 1.0) = 0.6;
uniform float wet_roughness_target : hint_range(0.0, 0.3) = 0.05;
uniform bool wet_debug = false;
uniform bool shore_wave_wetness_enabled = false;
uniform highp sampler2D shore_mask : filter_linear_mipmap, repeat_disable;
uniform vec4 shore_mask_bounds = vec4(-8000.0, -8000.0, 16000.0, 16000.0);
uniform float shore_fade_distance : hint_range(10.0, 200.0) = 50.0;
uniform float shore_wave_amplitude : hint_range(0.0, 3.0) = 0.0;
uniform float shore_wave_frequency : hint_range(0.02, 0.5) = 0.1;
uniform float shore_wave_speed : hint_range(0.1, 5.0) = 0.4;
uniform float shore_wave_steepness : hint_range(0.0, 1.0) = 0.58;
uniform float shore_wet_runup_width : hint_range(0.5, 20.0) = 8.0;
uniform float ocean_time = 0.0;
// === CUSTOM: enable_texturing toggle for test scenes without MW textures ===
uniform bool enable_texturing = true;
// === CUSTOM: Morrowind LTEX sidecar texturing ===
uniform bool mw_texturing_enabled = false;
uniform highp sampler2DArray mw_land_albedo_array : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform highp sampler2DArray mw_land_index_maps : filter_nearest, repeat_disable;
uniform float mw_texture_tile_scale = 0.136752;
uniform float mw_texture_blend_softness : hint_range(0.0, 1.0) = 1.0;

// Types & varyings (from internal shader)
struct material {
	vec4 albedo_height;
	vec4 normal_rough;
	float normal_map_depth;
	float ao_strength;
	float total_weight;
};

varying float v_vertex_xz_dist;
varying vec3 v_vertex;

////////////////////////
// Functions (from internal shader)
////////////////////////

ivec3 get_index_coord(const vec2 uv, const int search) {
	vec2 r_uv = round(uv);
	vec2 o_uv = mod(r_uv, _region_size);
	ivec2 pos;
	int bounds, layer_index = -1;
	for (int i = -1; i < clamp(search, 0, 2); i++) {
		if ((layer_index == -1 && _background_mode == 0u) || i < 0) {
			r_uv -= i == -1 ? vec2(0.0) : vec2(float(o_uv.x <= o_uv.y), float(o_uv.y <= o_uv.x));
			pos = ivec2(floor((r_uv) * _region_texel_size)) + (_region_map_size / 2);
			bounds = int(uint(pos.x | pos.y) < uint(_region_map_size));
			layer_index = (_region_map[pos.y * _region_map_size + pos.x] * bounds - 1);
		}
	}
	return ivec3(ivec2(mod(r_uv, _region_size)), layer_index);
}

vec3 get_index_uv(const vec2 uv2) {
	ivec2 pos = ivec2(floor(uv2)) + (_region_map_size / 2);
	int bounds = int(uint(pos.x | pos.y) < uint(_region_map_size));
	int layer_index = _region_map[pos.y * _region_map_size + pos.x] * bounds - 1;
	return vec3(uv2 - _region_locations[layer_index], float(layer_index));
}

float random(in vec2 xy) {
	return fract(sin(dot(xy, vec2(12.9898, 78.233))) * 43758.5453);
}

vec2 rotate_vec2(const vec2 v, const vec2 cs) {
	return vec2(fma(cs.x, v.x, cs.y * v.y), fma(cs.x, v.y, -cs.y * v.x));
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

float shore_swash_curve(float phase) {
	float cycle = fract(phase / 6.2831853);
	float uprush = smoothstep(0.00, 0.30, cycle);
	float backwash = 1.0 - smoothstep(0.30, 1.00, cycle);
	return uprush * backwash;
}

float shore_crest_shape(float sin_phase) {
	return sin_phase >= 0.0
		? pow(max(sin_phase, 0.0), 1.45)
		: -0.65 * pow(max(-sin_phase, 0.0), 1.15);
}

vec2 shore_direction_from_mask(vec2 shore_uv, vec2 encoded_dir) {
	vec2 dir = encoded_dir * 2.0 - 1.0;
	if (length(dir) > 0.01) {
		return normalize(dir);
	}

	vec2 texel = 1.0 / vec2(textureSize(shore_mask, 0));
	for (int radius = 1; radius <= 8; radius *= 2) {
		vec2 step_uv = texel * float(radius);
		float x_pos = texture(shore_mask, clamp(shore_uv + vec2(step_uv.x, 0.0), vec2(0.0), vec2(1.0))).a;
		float x_neg = texture(shore_mask, clamp(shore_uv - vec2(step_uv.x, 0.0), vec2(0.0), vec2(1.0))).a;
		float z_pos = texture(shore_mask, clamp(shore_uv + vec2(0.0, step_uv.y), vec2(0.0), vec2(1.0))).a;
		float z_neg = texture(shore_mask, clamp(shore_uv - vec2(0.0, step_uv.y), vec2(0.0), vec2(1.0))).a;
		vec2 gradient_dir = vec2(x_pos - x_neg, z_pos - z_neg);
		if (length(gradient_dir) > 1e-5) {
			return normalize(gradient_dir);
		}
	}
	return vec2(0.0);
}

float shore_land_distance(vec2 shore_uv, vec2 offshore_dir) {
	if (length(offshore_dir) <= 0.01) {
		return 1.0e6;
	}

	vec2 texel = 1.0 / vec2(textureSize(shore_mask, 0));
	float texel_world = max(shore_mask_bounds.z, shore_mask_bounds.w) / float(max(textureSize(shore_mask, 0).x, 1));
	for (int radius = 1; radius <= 8; radius++) {
		vec2 sample_uv = clamp(shore_uv + offshore_dir * texel * float(radius), vec2(0.0), vec2(1.0));
		vec4 sample_data = texture(shore_mask, sample_uv);
		if (sample_data.a > 0.001 || sample_data.r > 0.001) {
			return float(radius) * texel_world;
		}
	}
	return shore_wet_runup_width + texel_world;
}

float shore_water_coverage(vec3 world_pos) {
	vec2 shore_uv = (world_pos.xz - shore_mask_bounds.xy) / shore_mask_bounds.zw;
	bool in_mask = shore_uv.x >= 0.0 && shore_uv.x <= 1.0 && shore_uv.y >= 0.0 && shore_uv.y <= 1.0;
	if (!in_mask) {
		return 0.0;
	}
	vec4 shore_data = texture(shore_mask, shore_uv);
	return smoothstep(0.001, 0.05, max(shore_data.r, shore_data.a));
}

float shore_wave_wetness(vec3 world_pos) {
	if (!shore_wave_wetness_enabled || shore_wave_amplitude <= 0.0) {
		return 0.0;
	}

	vec2 shore_uv = (world_pos.xz - shore_mask_bounds.xy) / shore_mask_bounds.zw;
	bool in_mask = shore_uv.x >= 0.0 && shore_uv.x <= 1.0 && shore_uv.y >= 0.0 && shore_uv.y <= 1.0;
	if (!in_mask) {
		return 0.0;
	}

	vec4 shore_data = texture(shore_mask, shore_uv);
	float raw_dist = shore_data.a * shore_fade_distance;
	vec2 shore_dir = shore_direction_from_mask(shore_uv, shore_data.gb);
	bool shore_eligible = max(shore_data.r, shore_data.a) > 0.001 || length(shore_dir) > 0.01;
	if (!shore_eligible) {
		return 0.0;
	}
	float phase = raw_dist * shore_wave_frequency * 6.2832 + ocean_time * shore_wave_speed * 6.2832;
	float breaker_env = shore_breaker_envelope(raw_dist);
	float runup_env = shore_runup_envelope(raw_dist);
	float swash = shore_swash_curve(phase);
	float cycle = fract(phase / 6.2831853);
	float recede_gate = smoothstep(0.30, 0.42, cycle);
	float dry_tail = (1.0 - smoothstep(0.35, 1.00, cycle)) * recede_gate;
	float crest_phase = shore_crest_shape(sin(phase));
	float dynamic_water_y = sea_level_wet + shore_wave_amplitude * (
		breaker_env * crest_phase
		+ runup_env * swash * 0.75
	);

	float wet_margin_safe = max(wet_margin, 0.001);
	float land_dist = shore_land_distance(shore_uv, shore_dir);
	float current_runup_width = wet_margin_safe + shore_wet_runup_width * max(swash, max(0.0, sin(phase)) * breaker_env);
	float high_runup_width = wet_margin_safe + shore_wet_runup_width;
	float waterline_contact = 1.0 - smoothstep(
		dynamic_water_y - wet_margin_safe * 0.25,
		dynamic_water_y + wet_margin_safe * 1.50,
		world_pos.y
	);
	float footprint_wet = (1.0 - smoothstep(current_runup_width, current_runup_width + wet_margin_safe * 1.5, land_dist))
		* waterline_contact
		* max(runup_env, breaker_env)
		* recede_gate;
	float footprint_tail = (1.0 - smoothstep(high_runup_width, high_runup_width + wet_margin_safe, land_dist))
		* dry_tail
		* waterline_contact
		* runup_env * 0.75;

	float high_water_y = sea_level_wet + shore_wave_amplitude * runup_env * 0.75;
	float trailing_wet = (1.0 - smoothstep(high_water_y, high_water_y + wet_margin_safe * 2.0, world_pos.y))
		* dry_tail * runup_env * 0.75;

	return max(trailing_wet, max(footprint_wet, footprint_tail) * runup_env);
}

void accumulate_material(const vec3 base_ddx, const vec3 base_ddy, const float weight, const ivec3 index,
	const uint control, const vec2 texture_weight, const ivec2 texture_id, const vec3 i_normal,
	const float h, inout material mat) {

	vec2 i_pos = fma(_region_locations[index.z], vec2(_region_size), vec2(index.xy)) * _vertex_spacing;
	vec2 i_uv = v_vertex.xz;
	vec4 i_dd = vec4(base_ddx.xz, base_ddy.xz);
	mat2 p_align = mat2(1.);

	if (i_normal.y <= projection_threshold && enable_projection) {
		p_align = mat2(vec2(i_normal.z, -i_normal.x), vec2(i_normal.x, i_normal.z));
		vec2 xz = round(normalize(-i_normal.xz) * 1.3065629648763765);
		xz *= abs(xz.x) + abs(xz.y) > 1.5 ? 0.7071067811865475 : 1.0;
		xz = vec2(-xz.y, xz.x);
		i_pos = floor(vec2(dot(i_pos, xz), -h));
		i_uv = vec2(dot(v_vertex.xz, xz), -v_vertex.y);
		i_dd.xy = vec2(dot(base_ddx.xz, xz), -base_ddx.y);
		i_dd.zw = vec2(dot(base_ddy.xz, xz), -base_ddy.y);
	}

	float control_scale = (0.9 - float(((control >> 7u & 0x7u) + 3u) % 8u + 1u) * 0.1);
	i_dd *= control_scale;
	i_uv *= control_scale;
	i_pos *= control_scale;

	float c_angle = float(control >> 10u & 0xFu) * -0.392699081698724;
	vec2 c_cs_angle = vec2(cos(c_angle), sin(c_angle));
	i_uv = rotate_vec2(i_uv, c_cs_angle);
	i_pos = rotate_vec2(i_pos, c_cs_angle);

	float world_normal = 1.;
	vec3 T = normalize(base_ddx), B = -normalize(base_ddy);

	float blend = float(control >> 14u & 0xFFu) * 0.003921568627450;
	float sharpness = fma(56., blend_sharpness, 8.);

	// Base texture
	if (blend < 1.0) {
		const int id = texture_id[0];
		const float id_w = texture_weight[0];
		float id_scale = _texture_uv_scale_array[id];
		vec4 id_dd = i_dd * id_scale;

		vec2 uv_center = floor(fma(i_pos, vec2(id_scale), vec2(0.5)));
		vec2 id_detile = fma(random(uv_center), 2.0, -1.0) * _texture_detile_array[id] * TAU;
		vec2 id_cs_angle = vec2(cos(id_detile.x), sin(id_detile.x));
		vec2 id_uv = rotate_vec2(fma(i_uv, vec2(id_scale), -uv_center), id_cs_angle) + uv_center + id_detile.y - 0.5;

		id_cs_angle = vec2(
			fma(id_cs_angle.x, c_cs_angle.x, -id_cs_angle.y * c_cs_angle.y),
			fma(id_cs_angle.y, c_cs_angle.x, id_cs_angle.x * c_cs_angle.y));

		id_dd.xy = rotate_vec2(id_dd.xy, id_cs_angle);
		id_dd.zw = rotate_vec2(id_dd.zw, id_cs_angle);

		vec4 alb = textureGrad(_texture_array_albedo, vec3(id_uv, float(id)), id_dd.xy, id_dd.zw);
		vec4 nrm = textureGrad(_texture_array_normal, vec3(id_uv, float(id)), id_dd.xy, id_dd.zw);

		alb.rgb *= _texture_color_array[id].rgb;
		nrm.a = clamp(nrm.a + _texture_roughness_mod_array[id], 0., 1.);
		nrm.xyz = fma(nrm.xzy, vec3(2.0), vec3(-1.0));
		nrm.xz = rotate_vec2(nrm.xz, id_cs_angle) * p_align;

		world_normal = fma(T, vec3(nrm.x), fma(B, vec3(nrm.z), i_normal * vec3(nrm.y))).y;

		float id_weight = exp2(sharpness * log2(weight + id_w + alb.a)) * weight;
		mat.albedo_height = fma(alb, vec4(id_weight), mat.albedo_height);
		mat.normal_rough = fma(nrm, vec4(id_weight), mat.normal_rough);
		mat.normal_map_depth = fma(_texture_normal_depth_array[id], id_weight, mat.normal_map_depth);
		mat.ao_strength = fma(_texture_ao_strength_array[id], id_weight, mat.ao_strength);
		mat.total_weight += id_weight;
	}

	// Overlay texture
	if (blend > 0.0 && texture_id[1] != texture_id[0]) {
		const int id = texture_id[1];
		const float id_w = texture_weight[1];
		float id_scale = _texture_uv_scale_array[id];
		vec4 id_dd = i_dd * id_scale;

		vec2 uv_center = floor(fma(i_pos, vec2(id_scale), vec2(0.5)));
		vec2 id_detile = _texture_detile_array[id] * fma(random(uv_center), 2.0, -1.0) * TAU;
		vec2 id_cs_angle = vec2(cos(id_detile.x), sin(id_detile.x));
		vec2 id_uv = rotate_vec2(fma(i_uv, vec2(id_scale), -uv_center), id_cs_angle) + uv_center + id_detile.y - 0.5;

		id_cs_angle = vec2(
			fma(id_cs_angle.x, c_cs_angle.x, -id_cs_angle.y * c_cs_angle.y),
			fma(id_cs_angle.y, c_cs_angle.x, id_cs_angle.x * c_cs_angle.y));

		id_dd.xy = rotate_vec2(id_dd.xy, id_cs_angle);
		id_dd.zw = rotate_vec2(id_dd.zw, id_cs_angle);

		vec4 alb = textureGrad(_texture_array_albedo, vec3(id_uv, float(id)), id_dd.xy, id_dd.zw);
		vec4 nrm = textureGrad(_texture_array_normal, vec3(id_uv, float(id)), id_dd.xy, id_dd.zw);
		alb.rgb *= _texture_color_array[id].rgb;
		nrm.a = clamp(nrm.a + _texture_roughness_mod_array[id], 0., 1.);
		nrm.xyz = fma(nrm.xzy, vec3(2.0), vec3(-1.0));
		nrm.xz = rotate_vec2(nrm.xz, id_cs_angle) * p_align;

		float id_weight = exp2(sharpness * log2(weight + id_w + alb.a * clamp(world_normal, 0., 1.))) * weight;
		mat.albedo_height = fma(alb, vec4(id_weight), mat.albedo_height);
		mat.normal_rough = fma(nrm, vec4(id_weight), mat.normal_rough);
		mat.normal_map_depth = fma(_texture_normal_depth_array[id], id_weight, mat.normal_map_depth);
		mat.ao_strength = fma(_texture_ao_strength_array[id], id_weight, mat.ao_strength);
		mat.total_weight += id_weight;
	}
}

int mw_decode_layer(const ivec3 coord) {
	return int(round(texelFetch(mw_land_index_maps, coord, 0).r * 255.0));
}

void accumulate_mw_material(const float weight, const int id, const vec2 uv, const vec4 dd, inout material mat) {
	if (weight <= 0.0) {
		return;
	}
	vec4 alb = textureGrad(mw_land_albedo_array, vec3(uv, float(id)), dd.xy, dd.zw);
	float id_weight = weight;
	mat.albedo_height = fma(alb, vec4(id_weight), mat.albedo_height);
	mat.normal_rough = fma(vec4(0., 1., 0., 0.7), vec4(id_weight), mat.normal_rough);
	mat.normal_map_depth += id_weight;
	mat.total_weight += id_weight;
}

////////////////////////
// Vertex (from internal shader)
////////////////////////

void vertex() {
	v_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_vertex_xz_dist = length(v_vertex.xz - _camera_pos.xz);

	float scale = MODEL_MATRIX[0][0];
	float vertex_lerp = smoothstep(0.55, 0.95, (v_vertex_xz_dist / scale - _mesh_size - 4.0) / (_mesh_size - 2.0));
	vec2 v_fract = fract(VERTEX.xz * 0.5) * 2.0;

	vec2 shift = (scale < _vertex_spacing + 1e-6) ?
		mix(v_fract, vec2(v_fract.x, -v_fract.y),
			round(fract(round(mod(v_vertex.z * _vertex_density, 4.0)) *
			round(mod(v_vertex.x * _vertex_density, 4.0)) * 0.25))
		) :
		v_fract * round((fract(v_vertex.xz * 0.25 / scale) - 0.5) * 4.0);
	vec2 start_pos = v_vertex.xz * _vertex_density;
	vec2 end_pos = (v_vertex.xz - shift * scale) * _vertex_density;
	v_vertex.xz -= shift * scale * vertex_lerp;

	UV = v_vertex.xz * _vertex_density;
	UV2 = fma(UV, vec2(_region_texel_size), vec2(0.5 * _region_texel_size));

	ivec3 v_region = get_index_coord(start_pos, 1);
	uint control = floatBitsToUint(texelFetch(_control_maps, v_region, 0)).r;
	bool hole = bool(control >> 2u & 0x1u);

	if (!(CAMERA_VISIBLE_LAYERS == _mouse_layer) &&
			(hole || (_background_mode == 0u && v_region.z == -1))) {
		v_vertex.x = 0. / 0.;
	} else {
		ivec3 coord_a = get_index_coord(start_pos, 1);
		ivec3 coord_b = get_index_coord(end_pos, 1);
		float h = mix(texelFetch(_height_maps, coord_a, 0).r, texelFetch(_height_maps, coord_b, 0).r, vertex_lerp);
		v_vertex.y = h;
	}

	VERTEX = (VIEW_MATRIX * vec4(v_vertex, 1.0)).xyz;
	NORMAL = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	BINORMAL = normalize((MODELVIEW_MATRIX * vec4(BINORMAL, 0.0)).xyz);
	TANGENT = normalize((MODELVIEW_MATRIX * vec4(TANGENT, 0.0)).xyz);
}

////////////////////////
// Fragment (from internal shader + wet map)
////////////////////////

void fragment() {
	vec2 uv = UV;
	vec2 uv2 = UV2;

	vec3 region_uv = get_index_uv(uv2);
	const vec3 offsets = vec3(0, 1, 2);
	vec2 index_id = floor(uv);
	vec2 weight = fract(uv);
	vec2 invert = 1.0 - weight;
	vec4 weights = vec4(
		invert.x * weight.y,
		weight.x * weight.y,
		weight.x * invert.y,
		invert.x * invert.y
	);

	ivec3 index[4];
	index[0] = get_index_coord(index_id + offsets.xy, 2);
	index[1] = get_index_coord(index_id + offsets.yy, 2);
	index[2] = get_index_coord(index_id + offsets.yx, 2);
	index[3] = get_index_coord(index_id + offsets.xx, 2);

	vec3 base_ddx = dFdxCoarse(v_vertex);
	vec3 base_ddy = dFdyCoarse(v_vertex);

	float region_mip = log2(max(length(base_ddx.xz), length(base_ddy.xz)) * _vertex_density);
	bool bilerp = region_mip < 0.0 && region_uv.z > -1.;

	// Fragment normals from heightmap (internal shader computes per-fragment, not per-vertex)
	vec3 index_normal[4];
	float h[4];
	float u = 0.0;
	float v = 0.0;

	h[3] = texelFetch(_height_maps, index[3], 0).r;
	h[2] = texelFetch(_height_maps, index[2], 0).r;
	h[0] = texelFetch(_height_maps, index[0], 0).r;
	index_normal[3] = normalize(vec3(h[3] - h[2] + u, _vertex_spacing, h[3] - h[0] + v));

	vec3 w_normal = index_normal[3];

	// Distance-based mipmap bias (internal shader feature)
	float bias = mix(mipmap_bias,
		depth_blur + 1.,
		smoothstep(0.0, 1.0, (v_vertex_xz_dist - bias_distance) * 0.0009765625));
	base_ddx *= bias;
	base_ddy *= bias;

	// Color map
	vec4 color_map = region_uv.z > -1.0 ? textureLod(_color_maps, region_uv, region_mip) : vec4(1.0, 1.0, 1.0, 0.5);

	// Bilinear interpolation (close-up detail — internal shader feature)
	if (bilerp) {
		vec4 col_map[4];
		col_map[3] = index[3].z > -1 ? texelFetch(_color_maps, index[3], 0) : vec4(1.0, 1.0, 1.0, 0.5);
		col_map[0] = index[0].z > -1 ? texelFetch(_color_maps, index[0], 0) : vec4(1.0, 1.0, 1.0, 0.5);
		col_map[1] = index[1].z > -1 ? texelFetch(_color_maps, index[1], 0) : vec4(1.0, 1.0, 1.0, 0.5);
		col_map[2] = index[2].z > -1 ? texelFetch(_color_maps, index[2], 0) : vec4(1.0, 1.0, 1.0, 0.5);

		color_map =
			col_map[0] * weights[0] +
			col_map[1] * weights[1] +
			col_map[2] * weights[2] +
			col_map[3] * weights[3];

		h[1] = texelFetch(_height_maps, index[1], 0).r;
		float h_4 = texelFetch(_height_maps, get_index_coord(index_id + offsets.yz, 2), 0).r;
		float h_5 = texelFetch(_height_maps, get_index_coord(index_id + offsets.zy, 2), 0).r;
		float h_6 = texelFetch(_height_maps, get_index_coord(index_id + offsets.zx, 2), 0).r;
		float h_7 = texelFetch(_height_maps, get_index_coord(index_id + offsets.xz, 2), 0).r;

		index_normal[0] = normalize(vec3(h[0] - h[1] + u, _vertex_spacing, h[0] - h_7 + v));
		index_normal[1] = normalize(vec3(h[1] - h_5 + u, _vertex_spacing, h[1] - h_4 + v));
		index_normal[2] = normalize(vec3(h[2] - h_6 + u, _vertex_spacing, h[2] - h[1] + v));

		w_normal =
			index_normal[0] * weights[0] +
			index_normal[1] * weights[1] +
			index_normal[2] * weights[2] +
			index_normal[3] * weights[3];
	}

	// Normal computation
	if (flat_terrain_normals) {
		NORMAL = normalize(cross(dFdyCoarse(VERTEX), dFdxCoarse(VERTEX)));
		TANGENT = normalize(cross(NORMAL, VIEW_MATRIX[2].xyz));
		BINORMAL = normalize(cross(NORMAL, TANGENT));
	} else {
		vec3 w_tangent = normalize(cross(w_normal, vec3(0.0, 0.0, 1.0)));
		vec3 w_binormal = normalize(cross(w_normal, w_tangent));
		NORMAL = mat3(VIEW_MATRIX) * w_normal;
		TANGENT = mat3(VIEW_MATRIX) * w_tangent;
		BINORMAL = mat3(VIEW_MATRIX) * w_binormal;
	}

	// Material accumulation
	material mat = material(vec4(0.0), vec4(0.0), 0., 0., 0.);

	if (enable_texturing) {
		if (mw_texturing_enabled && region_uv.z > -1.0) {
			vec2 mw_grid = clamp(region_uv.xy * 64.0, vec2(0.0), vec2(64.0));
			ivec2 mw_base = ivec2(floor(clamp(mw_grid, vec2(0.0), vec2(63.999))));
			vec2 mw_frac = fract(mw_grid);
			mw_frac = mix(mw_frac, smoothstep(vec2(0.0), vec2(1.0), mw_frac), mw_texture_blend_softness);

			vec4 mw_weights = vec4(
				(1.0 - mw_frac.x) * (1.0 - mw_frac.y),
				mw_frac.x * (1.0 - mw_frac.y),
				(1.0 - mw_frac.x) * mw_frac.y,
				mw_frac.x * mw_frac.y
			);

			int mw_layer = int(region_uv.z);
			ivec2 mw_next = min(mw_base + ivec2(1), ivec2(64));
			int mw_id_00 = mw_decode_layer(ivec3(mw_base.x, mw_base.y, mw_layer));
			int mw_id_10 = mw_decode_layer(ivec3(mw_next.x, mw_base.y, mw_layer));
			int mw_id_01 = mw_decode_layer(ivec3(mw_base.x, mw_next.y, mw_layer));
			int mw_id_11 = mw_decode_layer(ivec3(mw_next.x, mw_next.y, mw_layer));

			vec2 mw_uv = v_vertex.xz * mw_texture_tile_scale;
			vec4 mw_dd = vec4(base_ddx.xz * mw_texture_tile_scale, base_ddy.xz * mw_texture_tile_scale);
			accumulate_mw_material(mw_weights.x, mw_id_00, mw_uv, mw_dd, mat);
			accumulate_mw_material(mw_weights.y, mw_id_10, mw_uv, mw_dd, mat);
			accumulate_mw_material(mw_weights.z, mw_id_01, mw_uv, mw_dd, mat);
			accumulate_mw_material(mw_weights.w, mw_id_11, mw_uv, mw_dd, mat);
		} else {
			// Control map decode
			uvec4 control = uvec4(floatBitsToUint(texelFetch(_control_maps, index[3], 0).r));
			if (bilerp) {
				control = uvec4(
					floatBitsToUint(texelFetch(_control_maps, index[0], 0).r),
					floatBitsToUint(texelFetch(_control_maps, index[1], 0).r),
					floatBitsToUint(texelFetch(_control_maps, index[2], 0).r),
					control[3]);
			}

			// Texture ID decode
			ivec4 t_id[2] = {ivec4(control >> uvec4(27u) & uvec4(0x1Fu)),
				ivec4(control >> uvec4(22u) & uvec4(0x1Fu))};
			ivec2 texture_ids[4] = ivec2[4](
				ivec2(t_id[0].x, t_id[1].x),
				ivec2(t_id[0].y, t_id[1].y),
				ivec2(t_id[0].z, t_id[1].z),
				ivec2(t_id[0].w, t_id[1].w));

			// Texture weight interpolation
			vec4 weights_id_1 = vec4(control >> uvec4(14u) & uvec4(0xFFu)) * 0.003921568627450;
			vec4 weights_id_0 = 1.0 - weights_id_1;
			vec2 t_weights[4] = vec2[4](
				vec2(weights_id_0[0], weights_id_1[0]),
				vec2(weights_id_0[1], weights_id_1[1]),
				vec2(weights_id_0[2], weights_id_1[2]),
				vec2(weights_id_0[3], weights_id_1[3]));

			if (bilerp) {
				t_weights = {vec2(0), vec2(0), vec2(0), vec2(0)};
				weights_id_0 *= weights;
				weights_id_1 *= weights;
				for (int i = 0; i < 4; i++) {
					vec2 w_0 = vec2(weights_id_0[i]);
					vec2 w_1 = vec2(weights_id_1[i]);
					ivec2 id_0 = texture_ids[i].xx;
					ivec2 id_1 = texture_ids[i].yy;
					t_weights[0] += fma(w_0, vec2(equal(texture_ids[0], id_0)), w_1 * vec2(equal(texture_ids[0], id_1)));
					t_weights[1] += fma(w_0, vec2(equal(texture_ids[1], id_0)), w_1 * vec2(equal(texture_ids[1], id_1)));
					t_weights[2] += fma(w_0, vec2(equal(texture_ids[2], id_0)), w_1 * vec2(equal(texture_ids[2], id_1)));
					t_weights[3] += fma(w_0, vec2(equal(texture_ids[3], id_0)), w_1 * vec2(equal(texture_ids[3], id_1)));
				}
			}

			accumulate_material(base_ddx, base_ddy, weights[3], index[3], control[3], t_weights[3],
				texture_ids[3], index_normal[3], h[3], mat);

			if (bilerp) {
				accumulate_material(base_ddx, base_ddy, weights[2], index[2], control[2], t_weights[2],
					texture_ids[2], index_normal[2], h[2], mat);
				accumulate_material(base_ddx, base_ddy, weights[1], index[1], control[1], t_weights[1],
					texture_ids[1], index_normal[1], h[1], mat);
				accumulate_material(base_ddx, base_ddy, weights[0], index[0], control[0], t_weights[0],
					texture_ids[0], index_normal[0], h[0], mat);
			}
		}
	}

	// Normalize or use defaults
	if (mat.total_weight > 0.0) {
		float weight_inv = 1.0 / mat.total_weight;
		mat.albedo_height *= weight_inv;
		mat.normal_rough *= weight_inv;
		mat.normal_map_depth *= weight_inv;
		mat.ao_strength *= weight_inv;
	} else {
		// No textures — clean white surface (test scene fallback)
		mat.albedo_height = vec4(1.0);
		mat.normal_rough = vec4(0., 1., 0., 0.7);
		mat.normal_map_depth = 1.0;
		mat.ao_strength = 0.0;
	}

	// Macro variation
	vec3 macrov = vec3(1.);
	if (enable_macro_variation) {
		float noise1 = texture(noise_texture, rotate_vec2(fma(uv, vec2(noise1_scale * .1), noise1_offset),
			vec2(cos(noise1_angle), sin(noise1_angle)))).r;
		float noise2 = texture(noise_texture, uv * noise2_scale * .1).r;
		macrov = mix(macro_variation1, vec3(1.), noise1);
		macrov *= mix(macro_variation2, vec3(1.), noise2);
		macrov = mix(vec3(1.0), macrov, clamp(w_normal.y + macro_variation_slope, 0., 1.));
	}

	// Apply PBR
	float roughness = clamp(fma(color_map.a - 0.5, 2.0, mat.normal_rough.a), 0., 1.);
	ALBEDO = mat.albedo_height.rgb * color_map.rgb * macrov;
	ROUGHNESS = roughness;
	SPECULAR = 1. - mat.normal_rough.a;
	NORMAL_MAP = fma(normalize(mat.normal_rough.xzy), vec3(0.5), vec3(0.5));
	NORMAL_MAP_DEPTH = mat.normal_map_depth;

	float ao = (1. - (mat.albedo_height.a * log(2.1 - mat.ao_strength))) * (1. - mat.normal_rough.y);
	AO = clamp(1. - ao * mat.ao_strength, mat.albedo_height.a, 1.0);
	AO_LIGHT_AFFECT = (1.0 - mat.albedo_height.a) * clamp(mat.normal_rough.y, 0., 1.);

	// === CUSTOM: Wet map — Lagarde PBR wet surfaces ===
	// Terrain below sea_level + wet_margin darkens and gets glossy.
	{
		float wet_margin_safe = max(wet_margin, 0.001);
		float static_wetness = (1.0 - smoothstep(sea_level_wet, sea_level_wet + wet_margin_safe, v_vertex.y))
			* shore_water_coverage(v_vertex);
		if (shore_wave_wetness_enabled) {
			static_wetness = 0.0;
		}
		float wetness = max(static_wetness, shore_wave_wetness(v_vertex));
		if (wet_debug) {
			ALBEDO = mix(ALBEDO, vec3(0.0, 0.2, 0.8), wetness * 0.8);
		} else {
			float porosity = clamp((ROUGHNESS - 0.2) / 0.6, 0.0, 1.0);
			float effective_wet = wetness * porosity;
			ALBEDO *= mix(1.0, 1.0 - wet_albedo_darken, effective_wet);
			ROUGHNESS = mix(ROUGHNESS, wet_roughness_target, effective_wet);
		}
	}
}
