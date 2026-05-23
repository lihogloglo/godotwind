## UnderwaterCompositorEffect - cheap underwater medium pass.
##
## This replaces the old receiver-only waterline probe for underwater viewing.
## It is one post-transparent compute pass: reconstruct scene depth, measure the
## camera-to-hit water segment, and apply Beer-Lambert absorption.
@tool
class_name UnderwaterCompositorEffect
extends PostProcessEffect

const SHADER_PATH := "res://src/core/shaders/compute/underwater.glsl"
const SCENE_COPY_SHADER_PATH := "res://src/core/shaders/compute/screen_color_copy.glsl"
const MAX_REASONABLE_TIMESTAMP_MS := 100.0
const MAX_CASCADES := 8
const QUALITY_LOW := 0
const QUALITY_MEDIUM := 1
const QUALITY_HIGH := 2

var _depth_sampler: RID
var _linear_sampler: RID
var _linear_repeat_sampler: RID
var _scene_copy_shader_rid: RID
var _scene_copy_pipeline_rid: RID
var _source_color_copy_rid: RID
var _source_copy_size: Vector2i = Vector2i.ZERO
var _state_buffer: RID
var _state_buffer_size: int = 0
var _displacement_rid: RID
var _shore_mask_rid: RID
var _fallback_shore_rid: RID
var _dummy_displacement_rid: RID

var _sea_level: float = 0.0
var _camera_water_level: float = 0.0
var _wave_scale: float = 1.0
var _ocean_time: float = 0.0
var _map_scales: PackedVector4Array = PackedVector4Array()
var _shore_mask_bounds: Vector4 = Vector4(-8000.0, -8000.0, 16000.0, 16000.0)
var _shore_fade_distance: float = 50.0
var _shore_wave_amplitude: float = 0.0
var _shore_wave_frequency: float = 0.1
var _shore_wave_speed: float = 0.4
var _shore_wave_steepness: float = 0.58
var _medium_color: Vector3 = Vector3(0.02, 0.04, 0.06)
var _absorption_sigma: Vector3 = Vector3(0.08, 0.02, 0.012)
var _max_path_m: float = 120.0
var _wobble_strength: float = 0.0025
var _debug_mode: int = 0
var _quality_tier: int = QUALITY_MEDIUM
var _absorption_enabled: bool = true
var _wobble_enabled: bool = true
var _last_copy_active: bool = false
var _last_perf_frame: int = -1
var _last_perf_snapshot: Dictionary = {
	"scene_copy_ms": 0.0,
	"probe_ms": 0.0,
	"total_ms": 0.0,
	"frame": -1,
	"timing_valid": false,
	"quality_tier": QUALITY_MEDIUM,
	"scene_copy_active": false,
}
var _render_logged: bool = false
var _dispatch_logged: bool = false


func _init() -> void:
	super._init()
	effect_name = "underwater_medium"
	display_name = "Underwater Medium"
	description = "Single-pass underwater absorption and bounded wobble."
	category = "Water"
	render_priority = 8
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	needs_depth = true


func on_effect_added() -> void:
	if not load_compute_shader(SHADER_PATH):
		Log.error("water", "UnderwaterCompositorEffect: failed to load shader")
		return
	if not _load_scene_copy_shader():
		Log.error("water", "UnderwaterCompositorEffect: failed to load scene-copy shader")
		return
	_create_samplers()
	Log.info("water", "UnderwaterCompositorEffect initialized")


func on_effect_removed() -> void:
	if rd != null:
		for rid: RID in [
			_depth_sampler,
			_linear_sampler,
			_linear_repeat_sampler,
			_source_color_copy_rid,
			_scene_copy_pipeline_rid,
			_scene_copy_shader_rid,
			_state_buffer,
			_fallback_shore_rid,
			_dummy_displacement_rid,
		]:
			if rid.is_valid():
				rd.free_rid(rid)
		_depth_sampler = RID()
		_linear_sampler = RID()
		_linear_repeat_sampler = RID()
		_source_color_copy_rid = RID()
		_scene_copy_pipeline_rid = RID()
		_scene_copy_shader_rid = RID()
		_state_buffer = RID()
		_displacement_rid = RID()
		_shore_mask_rid = RID()
		_fallback_shore_rid = RID()
		_dummy_displacement_rid = RID()
	_source_copy_size = Vector2i.ZERO
	_state_buffer_size = 0
	super.on_effect_removed()


func sync_from_water_state(state: WaterSurfaceState) -> void:
	if state == null:
		return
	_sea_level = state.sea_level
	_camera_water_level = state.sea_level
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
	elif _fallback_shore_rid.is_valid():
		_shore_mask_rid = _fallback_shore_rid
	_medium_color = state.optical_profile.get_medium_color()
	_absorption_sigma = state.optical_profile.get_extinction_sigma()


func sync_from_ocean(ocean_manager: Node, _ocean_material: ShaderMaterial) -> void:
	if ocean_manager != null and ocean_manager.has_method("get_water_surface_state"):
		sync_from_water_state(ocean_manager.get_water_surface_state())


func set_debug_mode(value: int) -> void:
	_debug_mode = clampi(value, 0, 5)


func set_camera_water_level(value: float) -> void:
	_camera_water_level = value


func set_quality_tier(value: int) -> void:
	_quality_tier = clampi(value, QUALITY_LOW, QUALITY_HIGH)


func set_underwater_feature_enabled(feature_name: StringName, enabled: bool) -> void:
	match feature_name:
		&"absorption_fog":
			_absorption_enabled = enabled
		&"wobble":
			_wobble_enabled = enabled
		&"snell", &"particles", &"caustics":
			pass


func set_underwater_particle_params(_noise_scale: float, _density: float, _near_gate_m: float, _far_gate_m: float) -> void:
	pass


func set_receiver_source_mode(_mode: int) -> void:
	pass


func set_sun_direction(_value: Vector3, _visibility: float = 1.0) -> void:
	pass


func set_sun_visibility(_value: float) -> void:
	pass


func get_underwater_perf_snapshot() -> Dictionary:
	_refresh_timestamp_snapshot()
	return _last_perf_snapshot.duplicate()


func _load_scene_copy_shader() -> bool:
	if rd == null:
		rd = RenderingServer.get_rendering_device()
		if rd == null:
			return false
	var shader_file := load(SCENE_COPY_SHADER_PATH) as RDShaderFile
	if shader_file == null:
		return false
	var shader_spirv := shader_file.get_spirv()
	if shader_spirv == null:
		return false
	_scene_copy_shader_rid = rd.shader_create_from_spirv(shader_spirv)
	if not _scene_copy_shader_rid.is_valid():
		return false
	_scene_copy_pipeline_rid = rd.compute_pipeline_create(_scene_copy_shader_rid)
	return _scene_copy_pipeline_rid.is_valid()


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

	var repeat_state := RDSamplerState.new()
	repeat_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	repeat_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	repeat_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	repeat_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	repeat_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_linear_repeat_sampler = rd.sampler_create(repeat_state)

	_create_fallback_textures()


func _create_fallback_textures() -> void:
	var shore_img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	shore_img.set_pixel(0, 0, Color(1.0, 0.5, 0.5, 1.0))
	_fallback_shore_rid = _create_rd_rgba8_texture(shore_img)
	_shore_mask_rid = _fallback_shore_rid
	_create_dummy_displacement_texture()
	_displacement_rid = _dummy_displacement_rid


func _create_rd_rgba8_texture(image: Image) -> RID:
	if rd == null:
		return RID()
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	fmt.width = image.get_width()
	fmt.height = image.get_height()
	fmt.depth = 1
	fmt.array_layers = 1
	fmt.mipmaps = 1
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	fmt.samples = RenderingDevice.TEXTURE_SAMPLES_1
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	return rd.texture_create(fmt, RDTextureView.new(), [image.get_data()])


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


func _render_callback(p_effect_callback_type: int, render_data: RenderData) -> void:
	if p_effect_callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
		return
	_refresh_timestamp_snapshot()
	if not _render_logged:
		_render_logged = true
		Log.info("water", "UnderwaterCompositorEffect: render callback fired enabled=%s pipeline=%s" % [
			effect_enabled,
			pipeline_rid.is_valid(),
		])
	if not effect_enabled or blend_factor <= 0.0 or not pipeline_rid.is_valid():
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

	var camera_pos := scene_data.get_cam_transform().origin
	var activation_water_level := _camera_water_level
	if camera_pos.y > activation_water_level + 0.05 and _debug_mode == 0:
		_last_copy_active = false
		return

	var view_count: int = buffers.get_view_count()
	for view: int in view_count:
		_render_view(view, size, buffers, scene_data)


func _render_view(view: int, size: Vector2i, buffers: RenderSceneBuffersRD, scene_data: RenderSceneDataRD) -> void:
	var color_image := buffers.get_color_layer(view)
	var depth_texture := buffers.get_depth_layer(view)
	if not color_image.is_valid() or not depth_texture.is_valid():
		return

	var source_color_rid := RID()
	var needs_source_copy := (_wobble_enabled or _debug_mode >= 4) and _wobble_strength > 0.0001
	var source_valid := false
	if needs_source_copy:
		source_valid = _copy_scene_color(color_image, size)
		source_color_rid = _source_color_copy_rid if source_valid else RID()
	_last_copy_active = source_valid

	var matrix_data := _build_state_buffer_data(scene_data)
	var matrix_bytes := matrix_data.to_byte_array()
	if not _ensure_state_buffer(matrix_bytes):
		return

	var pc := PackedFloat32Array()
	pc.append(float(size.x))
	pc.append(float(size.y))
	pc.append(_ocean_time)
	pc.append(blend_factor)
	pc.append(_sea_level)
	pc.append(_max_path_m)
	pc.append(_camera_water_level)
	pc.append(_wobble_strength)
	pc.append(_absorption_sigma.x)
	pc.append(_absorption_sigma.y)
	pc.append(_absorption_sigma.z)
	pc.append(float(_debug_mode))
	pc.append(1.0 if _absorption_enabled else 0.0)
	pc.append(1.0 if _wobble_enabled else 0.0)
	pc.append(1.0 if source_valid else 0.0)
	pc.append(0.0)
	pc.append(_wave_scale)
	pc.append(float(mini(_map_scales.size(), MAX_CASCADES)))
	pc.append(1.0 if _displacement_rid.is_valid() and _displacement_rid != _dummy_displacement_rid else 0.0)
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

	var u_source := RDUniform.new()
	u_source.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_source.binding = 2
	u_source.add_id(_linear_sampler)
	u_source.add_id(source_color_rid if source_valid else color_image)
	uniforms.append(u_source)

	var u_state := RDUniform.new()
	u_state.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_state.binding = 3
	u_state.add_id(_state_buffer)
	uniforms.append(u_state)

	var u_displacement := RDUniform.new()
	u_displacement.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_displacement.binding = 4
	u_displacement.add_id(_linear_repeat_sampler)
	u_displacement.add_id(_displacement_rid if _displacement_rid.is_valid() else _dummy_displacement_rid)
	uniforms.append(u_displacement)

	var u_shore := RDUniform.new()
	u_shore.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_shore.binding = 5
	u_shore.add_id(_linear_sampler)
	u_shore.add_id(_shore_mask_rid)
	uniforms.append(u_shore)

	var uniform_set := rd.uniform_set_create(uniforms, shader_rid, 0)
	if not uniform_set.is_valid():
		return

	var groups_x := (size.x + 7) / 8
	var groups_y := (size.y + 7) / 8
	if not _dispatch_logged:
		_dispatch_logged = true
		Log.info("water", "UnderwaterCompositorEffect: dispatching medium pass size=%s copy=%s" % [
			size,
			source_valid,
		])
	rd.capture_timestamp("godotwind_underwater_probe_begin")
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline_rid)
	rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	rd.compute_list_set_push_constant(cl, pc_bytes, pc_bytes.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	rd.compute_list_end()
	rd.capture_timestamp("godotwind_underwater_probe_end")
	rd.free_rid(uniform_set)


func _copy_scene_color(color_image: RID, size: Vector2i) -> bool:
	if not color_image.is_valid() or not _scene_copy_pipeline_rid.is_valid():
		return false
	if not _ensure_source_copy_texture(color_image, size):
		return false

	var uniforms: Array[RDUniform] = []
	var u_source := RDUniform.new()
	u_source.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_source.binding = 0
	u_source.add_id(color_image)
	uniforms.append(u_source)

	var u_target := RDUniform.new()
	u_target.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_target.binding = 1
	u_target.add_id(_source_color_copy_rid)
	uniforms.append(u_target)

	var uniform_set := rd.uniform_set_create(uniforms, _scene_copy_shader_rid, 0)
	if not uniform_set.is_valid():
		return false

	var pc := PackedFloat32Array()
	pc.append(float(size.x))
	pc.append(float(size.y))
	pc.append(0.0)
	pc.append(0.0)
	var pc_bytes := pc.to_byte_array()
	var groups_x := (size.x + 7) / 8
	var groups_y := (size.y + 7) / 8
	rd.capture_timestamp("godotwind_underwater_copy_begin")
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, _scene_copy_pipeline_rid)
	rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	rd.compute_list_set_push_constant(cl, pc_bytes, pc_bytes.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	rd.compute_list_add_barrier(cl)
	rd.compute_list_end()
	rd.capture_timestamp("godotwind_underwater_copy_end")
	rd.free_rid(uniform_set)
	return true


func _ensure_source_copy_texture(color_image: RID, size: Vector2i) -> bool:
	if _source_color_copy_rid.is_valid() and _source_copy_size == size:
		return true
	if _source_color_copy_rid.is_valid():
		rd.free_rid(_source_color_copy_rid)
		_source_color_copy_rid = RID()
	_source_copy_size = Vector2i.ZERO

	var src_format: RDTextureFormat = rd.texture_get_format(color_image)
	var color_fmt := RDTextureFormat.new()
	color_fmt.format = src_format.format
	color_fmt.width = size.x
	color_fmt.height = size.y
	color_fmt.depth = 1
	color_fmt.array_layers = 1
	color_fmt.mipmaps = 1
	color_fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	color_fmt.samples = RenderingDevice.TEXTURE_SAMPLES_1
	color_fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	_source_color_copy_rid = rd.texture_create(color_fmt, RDTextureView.new())
	if not _source_color_copy_rid.is_valid():
		return false
	_source_copy_size = size
	return true


func _ensure_state_buffer(matrix_bytes: PackedByteArray) -> bool:
	var required_size := matrix_bytes.size()
	if required_size <= 0:
		return false
	if not _state_buffer.is_valid() or _state_buffer_size != required_size:
		if _state_buffer.is_valid():
			rd.free_rid(_state_buffer)
		_state_buffer = rd.storage_buffer_create(required_size, matrix_bytes)
		_state_buffer_size = required_size if _state_buffer.is_valid() else 0
		return _state_buffer.is_valid()
	rd.buffer_update(_state_buffer, 0, required_size, matrix_bytes)
	return true


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
	for i: int in range(MAX_CASCADES):
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
	data.append(_medium_color.x)
	data.append(_medium_color.y)
	data.append(_medium_color.z)
	data.append(0.0)
	return data


func _refresh_timestamp_snapshot() -> void:
	if rd == null:
		return
	var frame := rd.get_captured_timestamps_frame()
	if frame == _last_perf_frame:
		return
	_last_perf_frame = frame

	var copy_ms := _timestamp_pair_delta_ms(
		"godotwind_underwater_copy_begin",
		"godotwind_underwater_copy_end"
	)
	var probe_ms := _timestamp_pair_delta_ms(
		"godotwind_underwater_probe_begin",
		"godotwind_underwater_probe_end"
	)
	var timing_valid := probe_ms >= 0.0 and (copy_ms >= 0.0 or not _last_copy_active)
	copy_ms = maxf(copy_ms, 0.0) if _last_copy_active else 0.0
	probe_ms = maxf(probe_ms, 0.0)
	_last_perf_snapshot = {
		"scene_copy_ms": copy_ms,
		"probe_ms": probe_ms,
		"total_ms": copy_ms + probe_ms,
		"frame": frame,
		"timing_valid": timing_valid,
		"quality_tier": _quality_tier,
		"scene_copy_active": _last_copy_active,
		"feature_flags": (1 if _absorption_enabled else 0) | (8 if _wobble_enabled else 0),
	}


func _timestamp_pair_delta_ms(begin_name: String, end_name: String) -> float:
	if rd == null:
		return -1.0
	var pending_gpu := -1
	var last_valid_ms := -1.0
	var count := rd.get_captured_timestamps_count()
	for i: int in count:
		var name := rd.get_captured_timestamp_name(i)
		if name == begin_name:
			pending_gpu = rd.get_captured_timestamp_gpu_time(i)
		elif name == end_name and pending_gpu >= 0:
			var gpu_ms := _timestamp_delta_ms(pending_gpu, rd.get_captured_timestamp_gpu_time(i))
			if _timestamp_delta_is_plausible(gpu_ms):
				last_valid_ms = gpu_ms
			pending_gpu = -1
	return last_valid_ms


func _timestamp_delta_is_plausible(gpu_ms: float) -> bool:
	return gpu_ms >= 0.0 and gpu_ms <= MAX_REASONABLE_TIMESTAMP_MS


func _timestamp_delta_ms(begin_us: int, end_us: int) -> float:
	if begin_us < 0 or end_us < 0 or end_us < begin_us:
		return -1.0
	return float(end_us - begin_us) / 1000.0
