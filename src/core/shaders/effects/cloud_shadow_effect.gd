## CloudShadowEffect - screen-space cloud receiver shadows.
##
## Projects visible receiver pixels toward the sun onto the active
## SunshineClouds2 cloud layer, then samples the live cloud accumulation alpha.
## This keeps shadow shape coupled to the rendered/weather-driven clouds without
## a separate projected mask texture.
@tool
class_name CloudShadowEffect
extends PostProcessEffect

const SHADER_PATH := "res://src/core/shaders/compute/cloud_shadow.glsl"

var _depth_sampler: RID
var _cloud_sampler: RID
var _dummy_cloud_rid: RID
var _state_buffer: RID
var _state_buffer_size: int = 0

var _active_sun: DirectionalLight3D = null
var _cloud_source: Resource = null

var _cached_cloud_floor: float = 1500.0
var _cached_cloud_ceiling: float = 15000.0
var _cached_cloud_enabled: bool = false


func _init() -> void:
	super._init()

	effect_name = "cloud_shadow"
	display_name = "Cloud Shadows"
	description = "Fast screen-space receiver shadows from SunshineClouds2's live cloud density."
	category = "Atmosphere"
	render_priority = 13

	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	needs_depth = true

	_define_parameters()


func _define_parameters() -> void:
	register_parameter("strength", 0.22, 0.0, 0.75, 0.01,
		"Strength", "Maximum scene darkening under dense clouds")
	register_parameter("density_threshold", 0.08, 0.0, 1.0, 0.01,
		"Density Threshold", "Cloud alpha where the receiver shadow begins")
	register_parameter("softness", 0.45, 0.05, 1.0, 0.01,
		"Softness", "Cloud alpha range used to soften the shadow edge")
	register_parameter("height_bias", 0.50, 0.0, 1.0, 0.01,
		"Sample Height", "0 samples cloud floor, 1 samples cloud ceiling")
	register_parameter("max_distance", 25000.0, 1000.0, 80000.0, 500.0,
		"Max Distance", "Receiver distance where screen-space cloud shadows fade out")
	register_parameter("debug_mode", 0.0, 0.0, 1.0, 1.0,
		"Debug", "Show the raw computed cloud shadow mask")


func on_effect_added() -> void:
	if not load_compute_shader(SHADER_PATH):
		Log.error("shaders", "CloudShadowEffect: failed to load shader")
		return
	_create_samplers()
	_create_dummy_cloud_texture()
	Log.info("shaders", "CloudShadowEffect initialized")


func on_effect_removed() -> void:
	if rd != null:
		for rid: RID in [
			_depth_sampler,
			_cloud_sampler,
			_dummy_cloud_rid,
			_state_buffer,
		]:
			if rid.is_valid():
				rd.free_rid(rid)
		_depth_sampler = RID()
		_cloud_sampler = RID()
		_dummy_cloud_rid = RID()
		_state_buffer = RID()
		_state_buffer_size = 0
	super.on_effect_removed()


func set_sun(sun: DirectionalLight3D) -> void:
	_active_sun = sun


func set_cloud_source(resource: Resource) -> void:
	_cloud_source = resource
	update_weather_cache()


## Called from the main thread by ShaderManager or lab scenes.
func update_weather_cache() -> void:
	_cached_cloud_enabled = false
	if _cloud_source == null or not is_instance_valid(_cloud_source):
		return
	_cached_cloud_enabled = bool(_cloud_source.get("enabled"))
	_cached_cloud_floor = float(_cloud_source.get("cloud_floor"))
	_cached_cloud_ceiling = float(_cloud_source.get("cloud_ceiling"))


func _create_samplers() -> void:
	if rd == null:
		return

	var depth_state := RDSamplerState.new()
	depth_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	depth_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	depth_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	depth_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_depth_sampler = rd.sampler_create(depth_state)

	var cloud_state := RDSamplerState.new()
	cloud_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	cloud_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	cloud_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	cloud_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_cloud_sampler = rd.sampler_create(cloud_state)


func _create_dummy_cloud_texture() -> void:
	if rd == null:
		return
	var fmt := RDTextureFormat.new()
	fmt.width = 1
	fmt.height = 1
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	var zero := PackedByteArray()
	zero.resize(8)
	zero.fill(0)
	_dummy_cloud_rid = rd.texture_create(fmt, RDTextureView.new(), [zero])


func _render_callback(p_effect_callback_type: int, render_data: RenderData) -> void:
	if p_effect_callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
		return
	if not effect_enabled or blend_factor <= 0.0 or not pipeline_rid.is_valid():
		return
	if _active_sun == null or not is_instance_valid(_active_sun):
		return
	if not _cached_cloud_enabled:
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

	var cloud_texture := _get_cloud_density_rid(view)
	if not cloud_texture.is_valid():
		cloud_texture = _dummy_cloud_rid
	if not cloud_texture.is_valid():
		return

	var state_data := _build_state_buffer_data(scene_data)
	var state_bytes := state_data.to_byte_array()
	if not _ensure_state_buffer(state_bytes):
		return

	var pc := PackedFloat32Array()
	pc.append(float(size.x))
	pc.append(float(size.y))
	pc.append(blend_factor)
	pc.append(Time.get_ticks_msec() / 1000.0)
	pc.append(float(get_param("strength")))
	pc.append(float(get_param("density_threshold")))
	pc.append(float(get_param("softness")))
	pc.append(float(get_param("height_bias")))
	pc.append(float(get_param("max_distance")))
	pc.append(float(get_param("debug_mode")))
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

	var u_cloud := RDUniform.new()
	u_cloud.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_cloud.binding = 2
	u_cloud.add_id(_cloud_sampler)
	u_cloud.add_id(cloud_texture)
	uniforms.append(u_cloud)

	var u_state := RDUniform.new()
	u_state.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_state.binding = 3
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


func _get_cloud_density_rid(view: int) -> RID:
	if _cloud_source == null or not is_instance_valid(_cloud_source):
		return RID()
	var accum: Array = _cloud_source.get("accumulation_textures")
	if accum == null:
		return RID()
	var idx := view * 7 + 1
	if idx >= accum.size():
		return RID()
	var rid: RID = accum[idx]
	return rid if rid.is_valid() else RID()


func _ensure_state_buffer(state_bytes: PackedByteArray) -> bool:
	var required_size := state_bytes.size()
	if required_size <= 0:
		return false
	if not _state_buffer.is_valid() or _state_buffer_size != required_size:
		if _state_buffer.is_valid():
			rd.free_rid(_state_buffer)
		_state_buffer = rd.storage_buffer_create(required_size, state_bytes)
		_state_buffer_size = required_size if _state_buffer.is_valid() else 0
		return _state_buffer.is_valid()
	rd.buffer_update(_state_buffer, 0, required_size, state_bytes)
	return true


func _build_state_buffer_data(scene_data: RenderSceneDataRD) -> PackedFloat32Array:
	var data := PackedFloat32Array()
	var projection: Projection = scene_data.get_cam_projection()
	var inv_projection: Projection = projection.inverse()
	var cam_transform: Transform3D = scene_data.get_cam_transform()
	var view_transform: Transform3D = cam_transform.affine_inverse()
	var view_projection: Projection = projection * Projection(view_transform)
	var toward_sun: Vector3 = _active_sun.global_basis.z.normalized()
	var cloud_height := lerpf(
		_cached_cloud_floor,
		_cached_cloud_ceiling,
		clampf(float(get_param("height_bias")), 0.0, 1.0)
	)

	for col: int in 4:
		for row: int in 4:
			data.append(inv_projection[col][row])

	for col: int in 3:
		data.append(cam_transform.basis[col].x)
		data.append(cam_transform.basis[col].y)
		data.append(cam_transform.basis[col].z)
		data.append(0.0)
	data.append(cam_transform.origin.x)
	data.append(cam_transform.origin.y)
	data.append(cam_transform.origin.z)
	data.append(1.0)

	for col: int in 4:
		for row: int in 4:
			data.append(view_projection[col][row])

	data.append(toward_sun.x)
	data.append(toward_sun.y)
	data.append(toward_sun.z)
	data.append(cloud_height)
	data.append(_cached_cloud_floor)
	data.append(_cached_cloud_ceiling)
	data.append(0.0)
	data.append(0.0)
	return data
