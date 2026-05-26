## SurfaceRefractionCompositorEffect
##
## POST_TRANSPARENT surface-refraction pass for the visible ocean surface.
## It samples an explicit water-excluded capture color/depth pair and replaces
## only pixels owned by the visible water surface with a single refracted
## submerged source sample. The main ocean material remains opaque.
@tool
class_name SurfaceRefractionCompositorEffect
extends PostProcessEffect

const SHADER_PATH := "res://src/core/shaders/compute/surface_refraction.glsl"
const TimestampTimingUtilsScript := preload("res://src/core/shaders/timestamp_timing_utils.gd")
const MAX_CASCADES := 8
const MAX_REASONABLE_TIMESTAMP_MS := 1000.0
const DEFAULT_SOURCE_FRAME_TOLERANCE := 2
const DEBUG_STATS_COUNTER_COUNT := 16
const DEBUG_STATS_BYTE_SIZE := DEBUG_STATS_COUNTER_COUNT * 4
const DEBUG_STATS_NAMES: Array[String] = [
	"total_pixels",
	"main_depth_far_pixels",
	"visible_water_pixels",
	"source_ready_pixels",
	"projected_invalid_pixels",
	"candidate_main_depth_far_pixels",
	"candidate_water_owned_pixels",
	"effective_depth_far_pixels",
	"receiver_ray_miss_pixels",
	"source_not_submerged_pixels",
	"candidate_mask_pixels",
	"stored_pixels",
	"candidate_not_water_depth_far_pixels",
	"candidate_offset_gt_half_px_pixels",
	"candidate_offset_gt_two_px_pixels",
	"source_candidate_mismatch_gt_half_px_pixels",
]

var refraction_strength: float = 0.45
var edge_guard_strength: float = 1.0
var max_refr_thickness: float = 2.0
var source_frame_tolerance: int = DEFAULT_SOURCE_FRAME_TOLERANCE:
	set(value):
		source_frame_tolerance = maxi(0, value)
var diagnostic_stats_enabled: bool = false

var _depth_sampler: RID
var _linear_sampler: RID
var _linear_repeat_sampler: RID
var _state_buffer: RID
var _state_buffer_size: int = 0
var _debug_stats_buffer: RID
var _displacement_rid: RID
var _shore_mask_rid: RID
var _fallback_shore_rid: RID
var _dummy_displacement_rid: RID
var _external_source_color_rid: RID
var _external_source_depth_rid: RID
var _external_source_size: Vector2i = Vector2i.ZERO
var _external_source_process_frame: int = -1
var _source_camera_projection: Projection = Projection()
var _source_camera_transform: Transform3D = Transform3D.IDENTITY
var _has_source_camera_matrices: bool = false

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
var _medium_color: Vector3 = Vector3(0.02, 0.04, 0.06)
var _absorption_sigma: Vector3 = Vector3(0.08, 0.02, 0.012)
var _debug_mode: int = 0
var _last_perf_frame: int = -1
var _last_source_color_valid: bool = false
var _last_source_depth_valid: bool = false
var _last_source_size_valid: bool = false
var _last_source_valid: bool = false
var _last_source_fresh: bool = false
var _last_dispatch_size: Vector2i = Vector2i.ZERO
var _last_debug_stats: Dictionary = {}
var _render_logged: bool = false
var _dispatch_logged: bool = false
var _last_perf_snapshot: Dictionary = {
	"surface_refraction_ms": 0.0,
	"frame": -1,
	"timing_available": false,
	"timing_valid": false,
	"timing_debug": {},
	"source_color_valid": false,
	"source_valid": false,
	"source_size_valid": false,
	"source_depth_valid": false,
	"source_fresh": false,
	"source_size": Vector2i.ZERO,
	"source_frame_age": -1,
	"source_frame_tolerance": DEFAULT_SOURCE_FRAME_TOLERANCE,
	"dispatch_size": Vector2i.ZERO,
	"debug_stats": {},
	"debug_mode": 0,
	"mask_mode": "final",
	"reject_reason": "inactive",
}


func _init() -> void:
	super._init()
	effect_name = "surface_refraction"
	display_name = "Surface Refraction"
	description = "POST_TRANSPARENT water-surface refraction from explicit color/depth capture."
	category = "Water"
	render_priority = 7
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	needs_depth = true


func on_effect_added() -> void:
	if not load_compute_shader(SHADER_PATH):
		Log.error("water", "SurfaceRefractionCompositorEffect: failed to load shader")
		return
	_create_samplers()
	Log.info("water", "SurfaceRefractionCompositorEffect initialized")


func on_effect_removed() -> void:
	if rd != null:
		for rid: RID in [
			_depth_sampler,
			_linear_sampler,
			_linear_repeat_sampler,
			_state_buffer,
			_debug_stats_buffer,
			_fallback_shore_rid,
			_dummy_displacement_rid,
		]:
			if rid.is_valid():
				rd.free_rid(rid)
	_depth_sampler = RID()
	_linear_sampler = RID()
	_linear_repeat_sampler = RID()
	_state_buffer = RID()
	_debug_stats_buffer = RID()
	_displacement_rid = RID()
	_shore_mask_rid = RID()
	_fallback_shore_rid = RID()
	_dummy_displacement_rid = RID()
	_external_source_color_rid = RID()
	_external_source_depth_rid = RID()
	_external_source_size = Vector2i.ZERO
	_external_source_process_frame = -1
	_state_buffer_size = 0
	super.on_effect_removed()


func sync_from_water_state(state: WaterSurfaceState) -> void:
	if state == null:
		return
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
	elif _fallback_shore_rid.is_valid():
		_shore_mask_rid = _fallback_shore_rid
	_medium_color = state.optical_profile.get_medium_color()
	_absorption_sigma = state.optical_profile.get_extinction_sigma()


func set_external_source_buffers(color_rid: RID, depth_rid: RID, size: Vector2i, source_process_frame: int = -1) -> void:
	_external_source_color_rid = color_rid
	_external_source_depth_rid = depth_rid
	_external_source_size = size
	_external_source_process_frame = source_process_frame


func set_source_camera_matrices(projection: Projection, camera_transform: Transform3D) -> void:
	_source_camera_projection = projection
	_source_camera_transform = camera_transform
	_has_source_camera_matrices = true


func clear_source_camera_matrices() -> void:
	_source_camera_projection = Projection()
	_source_camera_transform = Transform3D.IDENTITY
	_has_source_camera_matrices = false


func clear_external_source_buffers() -> void:
	_external_source_color_rid = RID()
	_external_source_depth_rid = RID()
	_external_source_size = Vector2i.ZERO
	_external_source_process_frame = -1
	clear_source_camera_matrices()
	_last_source_color_valid = false
	_last_source_depth_valid = false
	_last_source_size_valid = false
	_last_source_valid = false
	_last_source_fresh = false


func set_debug_mode(value: int) -> void:
	_debug_mode = clampi(value, 0, 7)


func get_debug_mode() -> int:
	return _debug_mode


func get_surface_refraction_perf_snapshot() -> Dictionary:
	_refresh_timestamp_snapshot()
	return _last_perf_snapshot.duplicate()


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
		Log.info("water", "SurfaceRefractionCompositorEffect: render callback fired enabled=%s pipeline=%s" % [
			effect_enabled,
			pipeline_rid.is_valid(),
		])
	if (
		not effect_enabled
		or blend_factor <= 0.0
		or (refraction_strength <= 0.001 and _debug_mode == 0)
		or not pipeline_rid.is_valid()
	):
		_last_dispatch_size = Vector2i.ZERO
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

	var source_color_valid := _external_source_color_rid.is_valid() and rd.texture_is_valid(_external_source_color_rid)
	var source_depth_valid := _external_source_depth_rid.is_valid() and rd.texture_is_valid(_external_source_depth_rid)
	var source_size_valid := _external_source_size != Vector2i.ZERO
	var source_valid := source_color_valid and source_depth_valid and source_size_valid
	var source_age := Engine.get_process_frames() - _external_source_process_frame if _external_source_process_frame >= 0 else -1
	var source_fresh := source_valid and source_age >= 0 and source_age <= source_frame_tolerance
	_last_source_color_valid = source_color_valid
	_last_source_depth_valid = source_depth_valid
	_last_source_size_valid = source_size_valid
	_last_source_valid = source_valid
	_last_source_fresh = source_fresh
	_last_dispatch_size = size
	if not source_fresh and _debug_mode == 0:
		_last_dispatch_size = Vector2i.ZERO
		_last_perf_snapshot = {
			"surface_refraction_ms": 0.0,
			"frame": rd.get_captured_timestamps_frame() if rd != null else -1,
			"timing_available": rd.get_captured_timestamps_count() > 0 if rd != null else false,
			"timing_valid": false,
			"source_color_valid": _last_source_color_valid,
			"source_depth_valid": _last_source_depth_valid,
			"source_size_valid": _last_source_size_valid,
			"source_valid": _last_source_valid,
			"source_fresh": _last_source_fresh,
			"source_size": _external_source_size,
			"source_process_frame": _external_source_process_frame,
			"source_frame_age": source_age,
			"source_frame_tolerance": source_frame_tolerance,
			"dispatch_size": _last_dispatch_size,
			"debug_stats": _refresh_debug_stats_snapshot(),
			"debug_mode": _debug_mode,
			"mask_mode": _mask_mode_name(),
			"reject_reason": _reject_reason_name(),
		}
		return

	var matrix_data := _build_state_buffer_data(scene_data)
	var matrix_bytes := matrix_data.to_byte_array()
	if not _ensure_state_buffer(matrix_bytes):
		return
	if not _ensure_debug_stats_buffer():
		return
	if diagnostic_stats_enabled:
		_reset_debug_stats_buffer()

	var pc := PackedFloat32Array()
	pc.append(float(size.x))
	pc.append(float(size.y))
	pc.append(_ocean_time)
	pc.append(blend_factor)
	pc.append(_sea_level)
	pc.append(_wave_scale)
	pc.append(float(mini(_map_scales.size(), MAX_CASCADES)))
	pc.append(refraction_strength)
	pc.append(_absorption_sigma.x)
	pc.append(_absorption_sigma.y)
	pc.append(_absorption_sigma.z)
	pc.append(max_refr_thickness)
	pc.append(1.0 if source_color_valid else 0.0)
	pc.append(1.0 if source_depth_valid else 0.0)
	pc.append(1.0 if source_fresh else 0.0)
	pc.append(float(_debug_mode))
	pc.append(edge_guard_strength)
	pc.append(1.0 if diagnostic_stats_enabled else 0.0)
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

	var u_source := RDUniform.new()
	u_source.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_source.binding = 2
	u_source.add_id(_linear_sampler)
	u_source.add_id(_external_source_color_rid if source_color_valid else color_image)
	uniforms.append(u_source)

	var u_source_depth := RDUniform.new()
	u_source_depth.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_source_depth.binding = 3
	u_source_depth.add_id(_depth_sampler)
	u_source_depth.add_id(_external_source_depth_rid if source_depth_valid else depth_texture)
	uniforms.append(u_source_depth)

	var u_state := RDUniform.new()
	u_state.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_state.binding = 4
	u_state.add_id(_state_buffer)
	uniforms.append(u_state)

	var u_displacement := RDUniform.new()
	u_displacement.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_displacement.binding = 5
	u_displacement.add_id(_linear_repeat_sampler)
	u_displacement.add_id(_displacement_rid if _displacement_rid.is_valid() else _dummy_displacement_rid)
	uniforms.append(u_displacement)

	var u_shore := RDUniform.new()
	u_shore.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_shore.binding = 6
	u_shore.add_id(_linear_sampler)
	u_shore.add_id(_shore_mask_rid)
	uniforms.append(u_shore)

	var u_debug_stats := RDUniform.new()
	u_debug_stats.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_debug_stats.binding = 7
	u_debug_stats.add_id(_debug_stats_buffer)
	uniforms.append(u_debug_stats)

	var uniform_set := rd.uniform_set_create(uniforms, shader_rid, 0)
	if not uniform_set.is_valid():
		return

	var groups_x := (size.x + 7) / 8
	var groups_y := (size.y + 7) / 8
	if not _dispatch_logged:
		_dispatch_logged = true
		Log.info("water", "SurfaceRefractionCompositorEffect: dispatching pass size=%s source=%s depth=%s age_tolerance=%d fresh=%s" % [
			size,
			source_color_valid,
			source_depth_valid,
			source_frame_tolerance,
			source_fresh,
		])
	rd.capture_timestamp("godotwind_surface_refraction_begin")
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline_rid)
	rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	rd.compute_list_set_push_constant(cl, pc_bytes, pc_bytes.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	rd.compute_list_add_barrier(cl)
	rd.compute_list_end()
	rd.capture_timestamp("godotwind_surface_refraction_end")
	rd.free_rid(uniform_set)


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


func _ensure_debug_stats_buffer() -> bool:
	if rd == null:
		return false
	if _debug_stats_buffer.is_valid():
		return true
	var zero_bytes := PackedByteArray()
	zero_bytes.resize(DEBUG_STATS_BYTE_SIZE)
	_debug_stats_buffer = rd.storage_buffer_create(DEBUG_STATS_BYTE_SIZE, zero_bytes)
	return _debug_stats_buffer.is_valid()


func _reset_debug_stats_buffer() -> void:
	if rd == null or not _debug_stats_buffer.is_valid():
		return
	var zero_bytes := PackedByteArray()
	zero_bytes.resize(DEBUG_STATS_BYTE_SIZE)
	rd.buffer_update(_debug_stats_buffer, 0, DEBUG_STATS_BYTE_SIZE, zero_bytes)


func _build_state_buffer_data(scene_data: RenderSceneDataRD) -> PackedFloat32Array:
	var data := PackedFloat32Array()
	var projection: Projection = scene_data.get_cam_projection()
	var inv_proj: Projection = projection.inverse()
	var inv_view: Transform3D = scene_data.get_cam_transform()
	var view: Transform3D = inv_view.affine_inverse()
	var source_projection: Projection = _source_camera_projection if _has_source_camera_matrices else projection
	var source_inv_proj: Projection = source_projection.inverse()
	var source_inv_view: Transform3D = _source_camera_transform if _has_source_camera_matrices else inv_view
	var source_view: Transform3D = source_inv_view.affine_inverse()

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

	for col: int in 4:
		for row: int in 4:
			data.append(projection[col][row])
	for col: int in 3:
		data.append(view.basis[col].x)
		data.append(view.basis[col].y)
		data.append(view.basis[col].z)
		data.append(0.0)
	data.append(view.origin.x)
	data.append(view.origin.y)
	data.append(view.origin.z)
	data.append(1.0)

	for col: int in 4:
		for row: int in 4:
			data.append(source_inv_proj[col][row])
	for col: int in 3:
		data.append(source_inv_view.basis[col].x)
		data.append(source_inv_view.basis[col].y)
		data.append(source_inv_view.basis[col].z)
		data.append(0.0)
	data.append(source_inv_view.origin.x)
	data.append(source_inv_view.origin.y)
	data.append(source_inv_view.origin.z)
	data.append(1.0)

	for col: int in 4:
		for row: int in 4:
			data.append(source_projection[col][row])
	for col: int in 3:
		data.append(source_view.basis[col].x)
		data.append(source_view.basis[col].y)
		data.append(source_view.basis[col].z)
		data.append(0.0)
	data.append(source_view.origin.x)
	data.append(source_view.origin.y)
	data.append(source_view.origin.z)
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

	var pass_ms := _timestamp_pair_delta_ms(
		"godotwind_surface_refraction_begin",
		"godotwind_surface_refraction_end"
	)
	var timing_debug := _timestamp_pair_debug(
		"godotwind_surface_refraction_begin",
		"godotwind_surface_refraction_end"
	)
	var timing_available := rd.get_captured_timestamps_count() > 0
	var timing_valid := pass_ms >= 0.0
	pass_ms = maxf(pass_ms, 0.0)
	var source_age := Engine.get_process_frames() - _external_source_process_frame if _external_source_process_frame >= 0 else -1
	var debug_stats := _refresh_debug_stats_snapshot()
	_last_perf_snapshot = {
		"surface_refraction_ms": pass_ms,
		"frame": frame,
		"timing_available": timing_available,
		"timing_valid": timing_valid,
		"timing_debug": timing_debug,
		"source_color_valid": _last_source_color_valid,
		"source_depth_valid": _last_source_depth_valid,
		"source_size_valid": _last_source_size_valid,
		"source_valid": _last_source_valid,
		"source_fresh": _last_source_fresh,
		"source_size": _external_source_size,
		"source_process_frame": _external_source_process_frame,
		"source_frame_age": source_age,
		"source_frame_tolerance": source_frame_tolerance,
		"dispatch_size": _last_dispatch_size,
		"debug_stats": debug_stats,
		"debug_mode": _debug_mode,
		"mask_mode": _mask_mode_name(),
		"reject_reason": _reject_reason_name(),
	}


func _refresh_debug_stats_snapshot() -> Dictionary:
	if not diagnostic_stats_enabled:
		_last_debug_stats = {}
		return _last_debug_stats
	if rd == null or not _debug_stats_buffer.is_valid():
		_last_debug_stats = {"available": false, "reason": "buffer_unavailable"}
		return _last_debug_stats
	if not rd.has_method("buffer_get_data"):
		_last_debug_stats = {"available": false, "reason": "buffer_get_data_unavailable"}
		return _last_debug_stats
	var bytes: PackedByteArray = rd.buffer_get_data(_debug_stats_buffer)
	if bytes.size() < DEBUG_STATS_BYTE_SIZE:
		_last_debug_stats = {
			"available": false,
			"reason": "short_read",
			"byte_size": bytes.size(),
		}
		return _last_debug_stats
	var result := {"available": true}
	for i: int in DEBUG_STATS_NAMES.size():
		result[DEBUG_STATS_NAMES[i]] = int(bytes.decode_u32(i * 4))
	_last_debug_stats = result
	return _last_debug_stats


func _mask_mode_name() -> String:
	match _debug_mode:
		1:
			return "final_mask"
		2:
			return "source_depth_validity"
		3:
			return "candidate_uv_offset"
		4:
			return "reject_reason"
		5:
			return "pre_absorption"
		6:
			return "post_absorption"
		7:
			return "ownership_rgb"
		_:
			return "final"


func _reject_reason_name() -> String:
	if not effect_enabled:
		return "inactive"
	if not _last_source_color_valid:
		return "source_color_invalid"
	if not _last_source_depth_valid:
		return "source_depth_invalid"
	if not _last_source_size_valid or not _last_source_valid:
		return "source_invalid"
	if not _last_source_fresh:
		return "source_stale"
	return "gpu_classified"


func _timestamp_pair_delta_ms(begin_name: String, end_name: String) -> float:
	if rd == null:
		return -1.0
	var begin_times: Array[int] = []
	var end_times: Array[int] = []
	var begin_cpu_times: Array[int] = []
	var end_cpu_times: Array[int] = []
	var last_valid_ms := -1.0
	var count := rd.get_captured_timestamps_count()
	for i: int in count:
		var name := rd.get_captured_timestamp_name(i)
		if name == begin_name:
			begin_times.append(rd.get_captured_timestamp_gpu_time(i))
			begin_cpu_times.append(rd.get_captured_timestamp_cpu_time(i))
		elif name == end_name:
			end_times.append(rd.get_captured_timestamp_gpu_time(i))
			end_cpu_times.append(rd.get_captured_timestamp_cpu_time(i))
	for begin_index: int in begin_times.size():
		for end_index: int in end_times.size():
			var gpu_ms := TimestampTimingUtilsScript.choose_delta_ms(
				begin_times[begin_index],
				end_times[end_index],
				MAX_REASONABLE_TIMESTAMP_MS,
				begin_cpu_times[begin_index],
				end_cpu_times[end_index]
			)
			if _timestamp_delta_is_plausible(gpu_ms):
				last_valid_ms = gpu_ms
	return last_valid_ms


func _timestamp_pair_debug(begin_name: String, end_name: String) -> Dictionary:
	var result := {
		"begin_count": 0,
		"end_count": 0,
		"first_begin_gpu_raw": -1,
		"first_end_gpu_raw": -1,
		"first_begin_cpu_raw": -1,
		"first_end_cpu_raw": -1,
		"min_positive_gpu_ms": -1.0,
		"min_positive_cpu_ms": -1.0,
		"chosen_unit": "invalid",
		"chosen_micro_ms": -1.0,
		"chosen_nano_ms": -1.0,
	}
	if rd == null:
		return result
	var begin_gpu_times: Array[int] = []
	var end_gpu_times: Array[int] = []
	var begin_cpu_times: Array[int] = []
	var end_cpu_times: Array[int] = []
	var count := rd.get_captured_timestamps_count()
	for i: int in count:
		var name := rd.get_captured_timestamp_name(i)
		if name == begin_name:
			begin_gpu_times.append(rd.get_captured_timestamp_gpu_time(i))
			begin_cpu_times.append(rd.get_captured_timestamp_cpu_time(i))
		elif name == end_name:
			end_gpu_times.append(rd.get_captured_timestamp_gpu_time(i))
			end_cpu_times.append(rd.get_captured_timestamp_cpu_time(i))
	result["begin_count"] = begin_gpu_times.size()
	result["end_count"] = end_gpu_times.size()
	if not begin_gpu_times.is_empty():
		result["first_begin_gpu_raw"] = begin_gpu_times[0]
		result["first_begin_cpu_raw"] = begin_cpu_times[0]
	if not end_gpu_times.is_empty():
		result["first_end_gpu_raw"] = end_gpu_times[0]
		result["first_end_cpu_raw"] = end_cpu_times[0]
	for begin_index: int in begin_gpu_times.size():
		for end_index: int in end_gpu_times.size():
			var delta := TimestampTimingUtilsScript.choose_delta(
				begin_gpu_times[begin_index],
				end_gpu_times[end_index],
				MAX_REASONABLE_TIMESTAMP_MS,
				begin_cpu_times[begin_index],
				end_cpu_times[end_index]
			)
			var gpu_ms := float(delta.get("ms", -1.0))
			if gpu_ms >= 0.0 and (float(result["min_positive_gpu_ms"]) < 0.0 or gpu_ms < float(result["min_positive_gpu_ms"])):
				result["min_positive_gpu_ms"] = gpu_ms
				result["chosen_unit"] = str(delta.get("unit", "invalid"))
				result["chosen_micro_ms"] = float(delta.get("micro_ms", -1.0))
				result["chosen_nano_ms"] = float(delta.get("nano_ms", -1.0))
	for begin_cpu: int in begin_cpu_times:
		for end_cpu: int in end_cpu_times:
			var cpu_ms := TimestampTimingUtilsScript.microsecond_delta_ms(begin_cpu, end_cpu)
			if cpu_ms >= 0.0 and (float(result["min_positive_cpu_ms"]) < 0.0 or cpu_ms < float(result["min_positive_cpu_ms"])):
				result["min_positive_cpu_ms"] = cpu_ms
	return result


func _timestamp_delta_is_plausible(gpu_ms: float) -> bool:
	return gpu_ms >= 0.0 and gpu_ms <= MAX_REASONABLE_TIMESTAMP_MS
