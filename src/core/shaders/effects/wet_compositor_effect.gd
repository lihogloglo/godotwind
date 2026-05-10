## WetCompositorEffect - shared screen-space exposed-surface wetness.
##
## This compositor owns the broad, world-consistent live wetness mask. It is
## intentionally conservative: submerged pixels are left to underwater optics,
## visible water is left to the transparent water pass, and retained wetness is
## handled by material shader hooks.
@tool
class_name WetCompositorEffect
extends PostProcessEffect

const SHADER_PATH := "res://src/core/shaders/compute/wet_compositor.glsl"
const MAX_CASCADES := 8

var _depth_sampler: RID
var _linear_sampler: RID
var _shore_mask_rid: RID
var _displacement_rid: RID
var _fallback_shore_texture: Texture2D
var _fallback_normal_texture: Texture2D
var _fallback_normal_rid: RID
var _dummy_displacement_rid: RID
var _state_buffer: RID

var _sea_level: float = 0.0
var _wave_scale: float = 1.0
var _ocean_time: float = 0.0
var _map_scales: PackedVector4Array = PackedVector4Array()
var _shore_mask_bounds: Vector4 = Vector4(-8000.0, -8000.0, 16000.0, 16000.0)
var _shore_fade_distance: float = 50.0
var _shore_wave_amplitude: float = 0.0
var _shore_wave_frequency: float = 0.1
var _shore_wave_speed: float = 0.4
var _shore_wave_steepness: float = 0.58
var _wet_margin: float = 0.3
var _wet_albedo_darken: float = 0.6
var _wet_roughness_target: float = 0.05
var _retained_wetness_strength: float = 0.35
var _submerged_optics_depth: float = 0.10
var _debug_mode: int = 0
var _has_water_state: bool = false
var _render_logged: bool = false


func _init() -> void:
	super._init()
	effect_name = "wet_compositor"
	display_name = "Wetness Compositor"
	description = "Shared pre-water screen-space wetness for exposed water-contact surfaces."
	category = "Water"
	render_priority = 7
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	needs_depth = true
	needs_normals = true
	needs_normal_roughness = true


func on_effect_added() -> void:
	if not load_compute_shader(SHADER_PATH):
		Log.error("water", "WetCompositorEffect: failed to load shader")
		return
	_create_samplers()
	_create_fallback_textures()
	_register_with_manager()
	Log.info("water", "WetCompositorEffect initialized")


func on_effect_removed() -> void:
	_unregister_from_manager()
	if rd != null:
		for rid: RID in [
			_state_buffer,
			_depth_sampler,
			_linear_sampler,
			_dummy_displacement_rid,
		]:
			if rid.is_valid():
				rd.free_rid(rid)
		_state_buffer = RID()
		_depth_sampler = RID()
		_linear_sampler = RID()
		_dummy_displacement_rid = RID()
	super.on_effect_removed()


func _register_with_manager() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or not tree.root.has_node("WetnessManager"):
		return
	var manager := tree.root.get_node("WetnessManager")
	if manager.has_method("register_compositor"):
		manager.call("register_compositor", self)


func _unregister_from_manager() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or not tree.root.has_node("WetnessManager"):
		return
	var manager := tree.root.get_node("WetnessManager")
	if manager.has_method("unregister_compositor"):
		manager.call("unregister_compositor", self)


func _create_samplers() -> void:
	if rd == null:
		return
	var depth_state := RDSamplerState.new()
	depth_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	depth_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	depth_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	depth_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	depth_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_depth_sampler = rd.sampler_create(depth_state)

	var linear_state := RDSamplerState.new()
	linear_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	linear_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	linear_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_linear_sampler = rd.sampler_create(linear_state)


func _create_fallback_textures() -> void:
	var shore_img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	shore_img.set_pixel(0, 0, Color(1.0, 0.5, 0.5, 1.0))
	_fallback_shore_texture = ImageTexture.create_from_image(shore_img)
	_shore_mask_rid = RenderingServer.texture_get_rd_texture(_fallback_shore_texture.get_rid())

	var normal_img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	normal_img.set_pixel(0, 0, Color(0.5, 0.5, 1.0, 0.7))
	_fallback_normal_texture = ImageTexture.create_from_image(normal_img)
	_fallback_normal_rid = RenderingServer.texture_get_rd_texture(_fallback_normal_texture.get_rid())

	_create_dummy_displacement_texture()
	_displacement_rid = _dummy_displacement_rid


func _create_dummy_displacement_texture() -> void:
	if rd == null:
		return
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.width = 1
	fmt.height = 1
	fmt.depth = 1
	fmt.array_layers = 1
	fmt.mipmaps = 1
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	fmt.samples = RenderingDevice.TEXTURE_SAMPLES_1
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var zero := PackedFloat32Array([0.0, 0.0, 0.0, 1.0]).to_byte_array()
	_dummy_displacement_rid = rd.texture_create(fmt, RDTextureView.new(), [zero])


func set_wet_params(
	margin: float,
	albedo_darken: float,
	roughness_target: float,
	retained_strength: float,
	submerged_optics_depth: float,
	debug_mode: Variant
) -> void:
	_wet_margin = maxf(margin, 0.0)
	_wet_albedo_darken = clampf(albedo_darken, 0.0, 1.0)
	_wet_roughness_target = clampf(roughness_target, 0.0, 0.3)
	_retained_wetness_strength = clampf(retained_strength, 0.0, 1.0)
	_submerged_optics_depth = maxf(submerged_optics_depth, 0.0)
	if debug_mode is bool:
		_debug_mode = 1 if debug_mode else 0
	else:
		_debug_mode = clampi(int(debug_mode), 0, 5)


func set_debug_mask(enabled: bool) -> void:
	_debug_mode = 1 if enabled else 0


func set_debug_mode(mode: int) -> void:
	_debug_mode = clampi(mode, 0, 5)


func sync_from_water_state(state: WaterSurfaceState) -> void:
	if state == null:
		_has_water_state = false
		return
	_has_water_state = state.water_body_id != WaterSurfaceState.WATER_BODY_NONE and state.coverage_available
	_sea_level = state.sea_level
	_wave_scale = state.wave_scale
	_ocean_time = state.ocean_time
	_map_scales = state.map_scales
	_shore_mask_bounds = state.shore_mask_bounds
	_shore_fade_distance = state.shore_fade_distance
	_shore_wave_amplitude = state.shore_wave_amplitude
	_shore_wave_frequency = state.shore_wave_frequency
	_shore_wave_speed = state.shore_wave_speed
	_shore_wave_steepness = state.shore_wave_steepness
	_displacement_rid = state.displacement_texture_rd if state.displacement_texture_rd.is_valid() else _dummy_displacement_rid
	if state.shore_mask_rd.is_valid():
		_shore_mask_rid = state.shore_mask_rd
	elif _fallback_shore_texture != null:
		_shore_mask_rid = RenderingServer.texture_get_rd_texture(_fallback_shore_texture.get_rid())


func _render_callback(p_effect_callback_type: int, render_data: RenderData) -> void:
	if p_effect_callback_type != EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT:
		return
	if not _render_logged:
		_render_logged = true
		Log.info("water", "WetCompositorEffect: render callback fired enabled=%s pipeline=%s water=%s" % [
			effect_enabled,
			pipeline_rid.is_valid(),
			_has_water_state,
		])
	if not effect_enabled or blend_factor <= 0.0 or not pipeline_rid.is_valid() or not _has_water_state:
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
	if size.x <= 0 or size.y <= 0:
		return

	var view_count: int = buffers.get_view_count()
	for view: int in view_count:
		_render_view(view, size, buffers, scene_data)


func _render_view(view: int, size: Vector2i, buffers: RenderSceneBuffersRD, scene_data: RenderSceneDataRD) -> void:
	var color_image := buffers.get_color_layer(view)
	var depth_texture := buffers.get_depth_layer(view)
	if not color_image.is_valid() or not depth_texture.is_valid():
		return

	var normal_texture := buffers.get_texture(&"forward_clustered", &"normal_roughness")
	var normal_valid := normal_texture.is_valid()
	if not normal_valid:
		normal_texture = _fallback_normal_rid

	var matrix_data := _build_state_buffer_data(scene_data)
	var matrix_bytes := matrix_data.to_byte_array()
	if _state_buffer.is_valid():
		rd.free_rid(_state_buffer)
	_state_buffer = rd.storage_buffer_create(matrix_bytes.size(), matrix_bytes)

	var pc := PackedFloat32Array()
	pc.append(float(size.x))
	pc.append(float(size.y))
	pc.append(_ocean_time)
	pc.append(blend_factor)
	pc.append(_sea_level)
	pc.append(_wave_scale)
	pc.append(float(mini(_map_scales.size(), MAX_CASCADES)))
	pc.append(_wet_margin)
	pc.append(_wet_albedo_darken)
	pc.append(_wet_roughness_target)
	pc.append(_submerged_optics_depth)
	pc.append(float(_debug_mode))
	pc.append(1.0 if _displacement_rid.is_valid() and _displacement_rid != _dummy_displacement_rid else 0.0)
	pc.append(1.0 if normal_valid else 0.0)
	pc.append(1.0 if _shore_mask_rid.is_valid() else 0.0)
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

	var u_normal := RDUniform.new()
	u_normal.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_normal.binding = 2
	u_normal.add_id(_linear_sampler)
	u_normal.add_id(normal_texture)
	uniforms.append(u_normal)

	var u_displacement := RDUniform.new()
	u_displacement.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_displacement.binding = 3
	u_displacement.add_id(_linear_sampler)
	u_displacement.add_id(_displacement_rid)
	uniforms.append(u_displacement)

	var u_shore := RDUniform.new()
	u_shore.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_shore.binding = 4
	u_shore.add_id(_linear_sampler)
	u_shore.add_id(_shore_mask_rid)
	uniforms.append(u_shore)

	var u_state := RDUniform.new()
	u_state.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_state.binding = 5
	u_state.add_id(_state_buffer)
	uniforms.append(u_state)

	var uniform_set := rd.uniform_set_create(uniforms, shader_rid, 0)
	if not uniform_set.is_valid():
		return

	var groups_x := (size.x + 7) / 8
	var groups_y := (size.y + 7) / 8
	rd.capture_timestamp("godotwind_wet_compositor_begin")
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline_rid)
	rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	rd.compute_list_set_push_constant(cl, pc_bytes, pc_bytes.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	rd.compute_list_end()
	rd.capture_timestamp("godotwind_wet_compositor_end")
	rd.free_rid(uniform_set)


func _build_state_buffer_data(scene_data: RenderSceneDataRD) -> PackedFloat32Array:
	var data := PackedFloat32Array()
	var inv_proj: Projection = scene_data.get_cam_projection().inverse()
	var inv_view: Transform3D = scene_data.get_cam_transform()

	for col: int in 4:
		for row: int in 4:
			data.append(inv_proj[col][row])
	for col: int in 3:
		data.append(inv_view.basis[col].x)
		data.append(inv_view.basis[col].y)
		data.append(inv_view.basis[col].z)
		data.append(0.0)
	data.append(inv_view.origin.x)
	data.append(inv_view.origin.y)
	data.append(inv_view.origin.z)
	data.append(1.0)

	for i: int in MAX_CASCADES:
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
	data.append(0.0)
	data.append(0.0)
	data.append(0.0)
	return data
