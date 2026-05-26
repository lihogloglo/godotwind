## PrewaterCaptureEffect
##
## Historical name retained for script compatibility. Runtime use is now a
## receiver-only capture for waterline refraction.
##
## Copies a secondary viewport's color and depth buffers into sampleable RD
## textures. Ocean Lab uses that viewport as an explicit refraction receiver
## capture: only objects on the receiver layer are rendered into this source.
@tool
class_name PrewaterCaptureEffect
extends PostProcessEffect

const SHADER_PATH := "res://src/core/shaders/compute/prewater_capture.glsl"
const TimestampTimingUtilsScript := preload("res://src/core/shaders/timestamp_timing_utils.gd")
const RETIRED_TEXTURE_FRAME_DELAY := 3
const MAX_REASONABLE_TIMESTAMP_MS := 100.0
const DEFAULT_COPY_BEGIN_MARKER := "godotwind_prewater_copy_begin"
const DEFAULT_COPY_END_MARKER := "godotwind_prewater_copy_end"

var _depth_sampler: RID
var _source_color_rid: RID
var _source_depth_rid: RID
var _source_size: Vector2i = Vector2i.ZERO
var _copy_begin_marker_name: String = DEFAULT_COPY_BEGIN_MARKER
var _copy_end_marker_name: String = DEFAULT_COPY_END_MARKER
var _timing_marker_scope: String = "global"
var _retired_textures: Array[Dictionary] = []
var _last_perf_frame: int = -1
var _last_capture_process_frame: int = -1
var _last_perf_snapshot: Dictionary = {
	"prewater_copy_ms": 0.0,
	"frame": -1,
	"timing_available": false,
	"timing_valid": false,
}
var _last_capture_projection: Projection = Projection()
var _last_capture_camera_transform: Transform3D = Transform3D.IDENTITY
var _last_capture_renderer_matrix_frame: int = -1
var _last_capture_has_renderer_matrices: bool = false


func configure_copy_timing_markers(begin_marker_name: String, end_marker_name: String, marker_scope: String) -> void:
	_copy_begin_marker_name = begin_marker_name
	_copy_end_marker_name = end_marker_name
	_timing_marker_scope = marker_scope


func _init() -> void:
	super._init()
	effect_name = "prewater_capture"
	display_name = "Refraction Receiver Capture"
	description = "Copies a receiver-only viewport color/depth pair for waterline refraction."
	category = "Water"
	render_priority = 0
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	needs_depth = true


func on_effect_added() -> void:
	if not load_compute_shader(SHADER_PATH):
		Log.error("water", "PrewaterCaptureEffect: failed to load shader")
		return
	_create_samplers()
	Log.info("water", "PrewaterCaptureEffect initialized")


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


func get_source_color_rid() -> RID:
	return _source_color_rid


func get_source_depth_rid() -> RID:
	return _source_depth_rid


func get_source_size() -> Vector2i:
	return _source_size


func get_capture_process_frame() -> int:
	return _last_capture_process_frame


func has_capture_renderer_matrices() -> bool:
	return _last_capture_has_renderer_matrices


func get_capture_renderer_projection() -> Projection:
	return _last_capture_projection


func get_capture_renderer_camera_transform() -> Transform3D:
	return _last_capture_camera_transform


func get_capture_renderer_matrix_frame() -> int:
	return _last_capture_renderer_matrix_frame


func has_capture() -> bool:
	return _source_color_rid.is_valid() and _source_depth_rid.is_valid() and _source_size != Vector2i.ZERO


func get_capture_perf_snapshot() -> Dictionary:
	_refresh_timestamp_snapshot()
	return _last_perf_snapshot.duplicate()


func _render_callback(p_effect_callback_type: int, render_data: RenderData) -> void:
	if p_effect_callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
		return
	_refresh_timestamp_snapshot()
	if not effect_enabled or blend_factor <= 0.0 or not pipeline_rid.is_valid():
		return
	if rd == null:
		rd = RenderingServer.get_rendering_device()
		if rd == null:
			return
	_release_retired_textures()

	var buffers := render_data.get_render_scene_buffers()
	if buffers == null:
		return
	var scene_data := render_data.get_render_scene_data()
	if scene_data != null:
		_last_capture_projection = scene_data.get_cam_projection()
		_last_capture_camera_transform = scene_data.get_cam_transform()
		_last_capture_renderer_matrix_frame = Engine.get_process_frames()
		_last_capture_has_renderer_matrices = true
	else:
		_last_capture_has_renderer_matrices = false
		_last_capture_renderer_matrix_frame = -1
	var size: Vector2i = buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return

	var view_count: int = buffers.get_view_count()
	for view in view_count:
		_render_view(view, size, buffers)


func _render_view(view: int, size: Vector2i, buffers: RenderSceneBuffersRD) -> void:
	var color_image := buffers.get_color_layer(view)
	var depth_texture := buffers.get_depth_layer(view)
	if not color_image.is_valid() or not depth_texture.is_valid():
		return
	if not _ensure_target_textures(color_image, size):
		return

	var uniforms: Array[RDUniform] = []

	var u_color_src := RDUniform.new()
	u_color_src.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_color_src.binding = 0
	u_color_src.add_id(color_image)
	uniforms.append(u_color_src)

	var u_depth_src := RDUniform.new()
	u_depth_src.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_depth_src.binding = 1
	u_depth_src.add_id(_depth_sampler)
	u_depth_src.add_id(depth_texture)
	uniforms.append(u_depth_src)

	var u_color_dst := RDUniform.new()
	u_color_dst.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_color_dst.binding = 2
	u_color_dst.add_id(_source_color_rid)
	uniforms.append(u_color_dst)

	var u_depth_dst := RDUniform.new()
	u_depth_dst.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_depth_dst.binding = 3
	u_depth_dst.add_id(_source_depth_rid)
	uniforms.append(u_depth_dst)

	var uniform_set := rd.uniform_set_create(uniforms, shader_rid, 0)
	if not uniform_set.is_valid():
		return

	var pc := PackedFloat32Array()
	pc.append(float(size.x))
	pc.append(float(size.y))
	pc.append(0.0)
	pc.append(0.0)
	var pc_bytes := pc.to_byte_array()

	var groups_x := (size.x + 7) / 8
	var groups_y := (size.y + 7) / 8
	rd.capture_timestamp(_copy_begin_marker_name)
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline_rid)
	rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	rd.compute_list_set_push_constant(cl, pc_bytes, pc_bytes.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	rd.compute_list_add_barrier(cl)
	rd.compute_list_end()
	rd.capture_timestamp(_copy_end_marker_name)
	rd.free_rid(uniform_set)
	_last_capture_process_frame = Engine.get_process_frames()


func _ensure_target_textures(color_image: RID, size: Vector2i) -> bool:
	if _source_color_rid.is_valid() and _source_depth_rid.is_valid() and _source_size == size:
		return true

	if _source_color_rid.is_valid():
		_retire_texture(_source_color_rid)
		_source_color_rid = RID()
	if _source_depth_rid.is_valid():
		_retire_texture(_source_depth_rid)
		_source_depth_rid = RID()
	_source_size = Vector2i.ZERO

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
	_source_color_rid = rd.texture_create(color_fmt, RDTextureView.new())

	var depth_fmt := RDTextureFormat.new()
	depth_fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	depth_fmt.width = size.x
	depth_fmt.height = size.y
	depth_fmt.depth = 1
	depth_fmt.array_layers = 1
	depth_fmt.mipmaps = 1
	depth_fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	depth_fmt.samples = RenderingDevice.TEXTURE_SAMPLES_1
	depth_fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	_source_depth_rid = rd.texture_create(depth_fmt, RDTextureView.new())

	if not _source_color_rid.is_valid() or not _source_depth_rid.is_valid():
		return false
	_source_size = size
	return true


func _retire_texture(rid: RID) -> void:
	if not rid.is_valid():
		return
	_retired_textures.append({
		"rid": rid,
		"release_frame": Engine.get_process_frames() + RETIRED_TEXTURE_FRAME_DELAY,
	})


func _release_retired_textures(force: bool = false) -> void:
	if rd == null:
		return
	var frame := Engine.get_process_frames()
	for i in range(_retired_textures.size() - 1, -1, -1):
		var entry := _retired_textures[i]
		var rid: RID = entry["rid"]
		var release_frame := int(entry["release_frame"])
		if force or frame >= release_frame:
			if rid.is_valid():
				rd.free_rid(rid)
			_retired_textures.remove_at(i)


func _refresh_timestamp_snapshot() -> void:
	if rd == null:
		return
	var frame := rd.get_captured_timestamps_frame()
	if frame == _last_perf_frame:
		return
	_last_perf_frame = frame

	var copy_ms := _timestamp_pair_delta_ms(
		_copy_begin_marker_name,
		_copy_end_marker_name
	)
	var timing_available := rd.get_captured_timestamps_count() > 0
	var timing_valid := copy_ms >= 0.0
	copy_ms = maxf(copy_ms, 0.0)
	_last_perf_snapshot = {
		"prewater_copy_ms": copy_ms,
		"frame": frame,
		"timing_available": timing_available,
		"timing_valid": timing_valid,
		"timing_marker_scope": _timing_marker_scope,
		"timing_marker_begin": _copy_begin_marker_name,
		"timing_marker_end": _copy_end_marker_name,
		"source_size": _source_size,
		"capture_process_frame": _last_capture_process_frame,
		"capture_frame_age": Engine.get_process_frames() - _last_capture_process_frame if _last_capture_process_frame >= 0 else -1,
		"capture_has_renderer_matrices": _last_capture_has_renderer_matrices,
		"capture_renderer_matrix_frame": _last_capture_renderer_matrix_frame,
		"capture_renderer_matrix_age": Engine.get_process_frames() - _last_capture_renderer_matrix_frame if _last_capture_renderer_matrix_frame >= 0 else -1,
	}


func _timestamp_pair_delta_ms(begin_name: String, end_name: String) -> float:
	if rd == null:
		return -1.0
	var begin_times: Array[int] = []
	var end_times: Array[int] = []
	var begin_cpu_times: Array[int] = []
	var end_cpu_times: Array[int] = []
	var last_valid_ms := -1.0
	var count := rd.get_captured_timestamps_count()
	for i in count:
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


func _timestamp_delta_is_plausible(gpu_ms: float) -> bool:
	return gpu_ms >= 0.0 and gpu_ms <= MAX_REASONABLE_TIMESTAMP_MS


func on_effect_removed() -> void:
	super.on_effect_removed()
	if rd:
		if _depth_sampler.is_valid():
			rd.free_rid(_depth_sampler)
			_depth_sampler = RID()
		if _source_color_rid.is_valid():
			rd.free_rid(_source_color_rid)
			_source_color_rid = RID()
		if _source_depth_rid.is_valid():
			rd.free_rid(_source_depth_rid)
			_source_depth_rid = RID()
		_release_retired_textures(true)
	_source_size = Vector2i.ZERO
	_last_capture_process_frame = -1
	_last_capture_has_renderer_matrices = false
	_last_capture_renderer_matrix_frame = -1
