## WaterlineCompositorEffect - tiny Option C ownership/order prototype.
##
## This is intentionally blunt: it classifies the current opaque scene depth
## against the displaced FFT water surface and marks/tints matching pixels at
## PRE_TRANSPARENT. The first goal is render-order proof, not final refraction.
@tool
class_name WaterlineCompositorEffect
extends PostProcessEffect

const SHADER_PATH := "res://src/core/shaders/compute/waterline_probe.glsl"
const MAX_CASCADES := 8

var _depth_sampler: RID
var _linear_sampler: RID
var _state_buffer: RID
var _displacement_rid: RID
var _shore_mask_rid: RID
var _fallback_shore_texture: Texture2D
var _map_scales: PackedVector4Array = PackedVector4Array()
var _sea_level: float = 0.0
var _wave_scale: float = 1.0
var _shore_mask_bounds: Vector4 = Vector4(-8000.0, -8000.0, 16000.0, 16000.0)
var _shore_fade_distance: float = 50.0
var _shore_wave_amplitude: float = 0.0
var _shore_wave_frequency: float = 0.1
var _shore_wave_speed: float = 1.2
var _shore_wave_steepness: float = 0.5
var _water_tint: Vector3 = Vector3(0.02, 0.04, 0.06)
var _absorption_sigma: Vector3 = Vector3(0.12, 0.03, 0.018)
var _caustics_strength: float = 1.0
var _probe_strength: float = 0.7
var _debug_mode: int = 0
var _render_logged: bool = false


func _init() -> void:
	super._init()
	effect_name = "waterline_probe"
	display_name = "Waterline Probe"
	description = "PRE_TRANSPARENT waterline compositor prototype for Option C."
	category = "Water"
	render_priority = 8
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	needs_depth = true


func on_effect_added() -> void:
	if not load_compute_shader(SHADER_PATH):
		Log.error("water", "WaterlineCompositorEffect: failed to load shader")
		return
	_create_samplers()
	_create_fallback_shore_mask()
	Log.info("water", "WaterlineCompositorEffect initialized")


func _create_samplers() -> void:
	if rd == null:
		return
	var linear_state := RDSamplerState.new()
	linear_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	linear_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_depth_sampler = rd.sampler_create(linear_state)
	_linear_sampler = rd.sampler_create(linear_state)


func _create_fallback_shore_mask() -> void:
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.set_pixel(0, 0, Color(1.0, 0.5, 0.5, 1.0))
	_fallback_shore_texture = ImageTexture.create_from_image(img)
	_shore_mask_rid = RenderingServer.texture_get_rd_texture(_fallback_shore_texture.get_rid())


func sync_from_ocean(ocean_manager: Node, ocean_material: ShaderMaterial) -> void:
	if ocean_manager == null or ocean_material == null:
		return

	if ocean_manager.has_method("get_sea_level"):
		_sea_level = ocean_manager.get_sea_level()
	if ocean_manager.has_method("get_displacement_texture_rd"):
		_displacement_rid = ocean_manager.get_displacement_texture_rd()
	if ocean_manager.has_method("get_absorption_tint"):
		_water_tint = ocean_manager.get_absorption_tint()
	if ocean_manager.has_method("get_absorption_sigma"):
		_absorption_sigma = ocean_manager.get_absorption_sigma()
	if ocean_manager.has_method("get_underwater_caustics_strength"):
		_caustics_strength = ocean_manager.get_underwater_caustics_strength()

	var scales: Variant = ocean_material.get_shader_parameter("map_scales")
	_map_scales.clear()
	if scales is PackedVector4Array:
		for scale: Vector4 in scales:
			_map_scales.append(scale)

	var wave: Variant = ocean_material.get_shader_parameter("wave_scale")
	if wave != null:
		_wave_scale = float(wave)

	var shore_mask: Variant = ocean_material.get_shader_parameter("shore_mask")
	if shore_mask is Texture2D:
		_shore_mask_rid = RenderingServer.texture_get_rd_texture((shore_mask as Texture2D).get_rid())

	var bounds: Variant = ocean_material.get_shader_parameter("shore_mask_bounds")
	if bounds is Vector4:
		_shore_mask_bounds = bounds

	var fade: Variant = ocean_material.get_shader_parameter("shore_fade_distance")
	if fade != null:
		_shore_fade_distance = float(fade)
	var shore_amp: Variant = ocean_material.get_shader_parameter("shore_wave_amplitude")
	if shore_amp != null:
		_shore_wave_amplitude = float(shore_amp)
	var shore_freq: Variant = ocean_material.get_shader_parameter("shore_wave_frequency")
	if shore_freq != null:
		_shore_wave_frequency = float(shore_freq)
	var shore_speed: Variant = ocean_material.get_shader_parameter("shore_wave_speed")
	if shore_speed != null:
		_shore_wave_speed = float(shore_speed)
	var shore_steep: Variant = ocean_material.get_shader_parameter("shore_wave_steepness")
	if shore_steep != null:
		_shore_wave_steepness = float(shore_steep)


func set_probe_strength(value: float) -> void:
	_probe_strength = clampf(value, 0.0, 1.0)


func set_debug_mode(value: int) -> void:
	_debug_mode = clampi(value, 0, 4)


func _render_callback(p_effect_callback_type: int, render_data: RenderData) -> void:
	if p_effect_callback_type != EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT:
		return
	if not _render_logged:
		_render_logged = true
		print("[WATERLINE_PROTO] render callback fired enabled=%s pipeline=%s displacement=%s shore=%s" % [
			effect_enabled,
			pipeline_rid.is_valid(),
			_displacement_rid.is_valid(),
			_shore_mask_rid.is_valid(),
		])
	if not effect_enabled or blend_factor <= 0.0 or not pipeline_rid.is_valid():
		return
	if not _displacement_rid.is_valid() or not _shore_mask_rid.is_valid():
		return
	if rd == null:
		rd = RenderingServer.get_rendering_device()
		if rd == null:
			return

	var buffers := render_data.get_render_scene_buffers()
	var scene_data := render_data.get_render_scene_data()
	if buffers == null or scene_data == null:
		return
	var size: Vector2i = buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return

	var view_count: int = buffers.get_view_count()
	for view in view_count:
		_render_view(view, size, buffers, scene_data)


func _render_view(view: int, size: Vector2i, buffers: RenderSceneBuffersRD, scene_data: RenderSceneDataRD) -> void:
	var color_image := buffers.get_color_layer(view)
	var depth_texture := buffers.get_depth_layer(view)
	if not color_image.is_valid() or not depth_texture.is_valid():
		return

	var matrix_data := _build_state_buffer_data(scene_data)
	var matrix_bytes := matrix_data.to_byte_array()
	if _state_buffer.is_valid():
		rd.free_rid(_state_buffer)
	_state_buffer = rd.storage_buffer_create(matrix_bytes.size(), matrix_bytes)

	var pc := PackedFloat32Array()
	pc.append(float(size.x))
	pc.append(float(size.y))
	pc.append(Time.get_ticks_msec() / 1000.0)
	pc.append(blend_factor)
	pc.append(_sea_level)
	pc.append(_wave_scale)
	pc.append(float(mini(_map_scales.size(), MAX_CASCADES)))
	pc.append(_probe_strength)
	pc.append(float(_debug_mode))
	pc.append(0.0)
	pc.append(0.0)
	pc.append(0.0)
	var pc_bytes := pc.to_byte_array()

	var uniforms: Array[RDUniform] = []

	var u_color := RDUniform.new()
	u_color.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_color.binding = 0
	u_color.add_id(color_image)
	uniforms.append(u_color)

	var u_depth := RDUniform.new()
	u_depth.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_depth.binding = 1
	u_depth.add_id(_depth_sampler)
	u_depth.add_id(depth_texture)
	uniforms.append(u_depth)

	var u_displacement := RDUniform.new()
	u_displacement.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_displacement.binding = 2
	u_displacement.add_id(_linear_sampler)
	u_displacement.add_id(_displacement_rid)
	uniforms.append(u_displacement)

	var u_shore := RDUniform.new()
	u_shore.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_shore.binding = 3
	u_shore.add_id(_linear_sampler)
	u_shore.add_id(_shore_mask_rid)
	uniforms.append(u_shore)

	var u_state := RDUniform.new()
	u_state.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_state.binding = 4
	u_state.add_id(_state_buffer)
	uniforms.append(u_state)

	var uniform_set := rd.uniform_set_create(uniforms, shader_rid, 0)
	if not uniform_set.is_valid():
		return

	var groups_x := (size.x + 7) / 8
	var groups_y := (size.y + 7) / 8
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline_rid)
	rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	rd.compute_list_set_push_constant(cl, pc_bytes, pc_bytes.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	rd.compute_list_end()
	rd.free_rid(uniform_set)


func _build_state_buffer_data(scene_data: RenderSceneDataRD) -> PackedFloat32Array:
	var data := PackedFloat32Array()
	var inv_proj: Projection = scene_data.get_cam_projection().inverse()
	var inv_view: Transform3D = scene_data.get_cam_transform()

	for col in 4:
		for row in 4:
			data.append(inv_proj[col][row])
	for col in 3:
		data.append(inv_view.basis[col].x)
		data.append(inv_view.basis[col].y)
		data.append(inv_view.basis[col].z)
		data.append(0.0)
	data.append(inv_view.origin.x)
	data.append(inv_view.origin.y)
	data.append(inv_view.origin.z)
	data.append(1.0)

	for i in MAX_CASCADES:
		if i < _map_scales.size():
			var scale := _map_scales[i]
			data.append(scale.x)
			data.append(scale.y)
			data.append(scale.z)
			data.append(scale.w)
		else:
			data.append(0.0)
			data.append(0.0)
			data.append(0.0)
			data.append(0.0)

	data.append(_shore_mask_bounds.x)
	data.append(_shore_mask_bounds.y)
	data.append(_shore_mask_bounds.z)
	data.append(_shore_mask_bounds.w)
	data.append(_shore_fade_distance)
	data.append(_shore_wave_amplitude)
	data.append(_shore_wave_frequency)
	data.append(_shore_wave_speed)
	data.append(_shore_wave_steepness)
	data.append(_water_tint.x)
	data.append(_water_tint.y)
	data.append(_water_tint.z)
	data.append(_absorption_sigma.x)
	data.append(_absorption_sigma.y)
	data.append(_absorption_sigma.z)
	data.append(_caustics_strength)
	return data


func on_effect_removed() -> void:
	super.on_effect_removed()
	if rd:
		if _depth_sampler.is_valid():
			rd.free_rid(_depth_sampler)
			_depth_sampler = RID()
		if _linear_sampler.is_valid():
			rd.free_rid(_linear_sampler)
			_linear_sampler = RID()
		if _state_buffer.is_valid():
			rd.free_rid(_state_buffer)
			_state_buffer = RID()
