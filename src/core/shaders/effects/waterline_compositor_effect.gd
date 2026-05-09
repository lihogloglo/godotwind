## WaterlineCompositorEffect - receiver-only waterline compositor core.
##
## Classifies opt-in receiver depth against the displaced FFT water surface
## after the visible ocean has drawn, then bends/tints only those receiver
## pixels through water. Empty water and terrain are left untouched.
@tool
class_name WaterlineCompositorEffect
extends PostProcessEffect

const SHADER_PATH := "res://src/core/shaders/compute/waterline_probe.glsl"
const SCENE_COPY_SHADER_PATH := "res://src/core/shaders/compute/screen_color_copy.glsl"
const CAUSTICS_NOISE_PATH := "res://assets/water/caustics_noise.png"
const MAX_CASCADES := 8
const FEATURE_ABSORPTION_FOG := 1
const FEATURE_SNELL := 2
const FEATURE_RAYS := 4
const FEATURE_WOBBLE := 8
const FEATURE_PARTICLES := 16
const FEATURE_MENISCUS_REFRACTION := 32
const FEATURE_CAUSTICS := 64

var _depth_sampler: RID
var _linear_clamp_sampler: RID
var _linear_repeat_sampler: RID
var _source_color_sampler: RID
var _scene_copy_shader_rid: RID
var _scene_copy_pipeline_rid: RID
var _scene_color_copy_rid: RID
var _scene_copy_size: Vector2i = Vector2i.ZERO
var _external_source_color_rid: RID
var _external_source_depth_rid: RID
var _external_source_size: Vector2i = Vector2i.ZERO
var _state_buffer: RID
var _displacement_rid: RID
var _shore_mask_rid: RID
var _caustics_noise_rid: RID
var _fallback_shore_texture: Texture2D
var _caustics_noise_texture: Texture2D
var _map_scales: PackedVector4Array = PackedVector4Array()
var _sea_level: float = 0.0
var _wave_scale: float = 1.0
var _shore_mask_bounds: Vector4 = Vector4(-8000.0, -8000.0, 16000.0, 16000.0)
var _shore_fade_distance: float = 50.0
var _shore_wave_amplitude: float = 0.0
var _shore_wave_frequency: float = 0.1
var _shore_wave_speed: float = 0.4
var _shore_wave_steepness: float = 0.5
var _water_tint: Vector3 = Vector3(0.02, 0.04, 0.06)
var _absorption_sigma: Vector3 = Vector3(0.12, 0.03, 0.018)
var _caustics_strength: float = 1.0
var _probe_strength: float = 0.85
var _debug_mode: int = 0
var _ocean_time: float = 0.0
var _camera_water_level: float = 0.0
var _near_water_activation_distance: float = 420.0
var _near_water_fade_start_distance: float = 280.0
var _sun_direction: Vector3 = Vector3(0.25, 0.85, 0.45).normalized()
var _sun_visibility: float = 1.0
var _underwater_feature_flags: int = (
	FEATURE_ABSORPTION_FOG
	| FEATURE_SNELL
	| FEATURE_RAYS
	| FEATURE_WOBBLE
	| FEATURE_PARTICLES
	| FEATURE_MENISCUS_REFRACTION
	| FEATURE_CAUSTICS
)
var _ray_shell_count: int = 6
var _ray_shell_spacing_m: float = 16.0
var _ray_intensity: float = 1.8
var _ray_shell_start_m: float = 2.0
var _particle_noise_scale: float = 0.70
var _particle_density: float = 0.15
var _particle_near_gate_m: float = 1.5
var _particle_far_gate_m: float = 95.0
var _last_perf_frame: int = -1
var _last_perf_snapshot: Dictionary = {
	"scene_copy_ms": 0.0,
	"probe_ms": 0.0,
	"total_ms": 0.0,
	"frame": -1,
}
var _render_logged: bool = false
var _missing_source_warning_logged: bool = false
var _last_source_log_key: String = ""


func _init() -> void:
	super._init()
	effect_name = "waterline_probe"
	display_name = "Waterline Compositor"
	description = "POST_TRANSPARENT receiver-only waterline compositor."
	category = "Water"
	render_priority = 8
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	needs_depth = true


func on_effect_added() -> void:
	if not load_compute_shader(SHADER_PATH):
		Log.error("water", "WaterlineCompositorEffect: failed to load shader")
		return
	if not _load_scene_copy_shader():
		Log.error("water", "WaterlineCompositorEffect: failed to load scene-copy shader")
		return
	_create_samplers()
	_create_fallback_shore_mask()
	_load_caustics_textures()
	Log.info("water", "WaterlineCompositorEffect initialized")


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

	var clamp_state := RDSamplerState.new()
	clamp_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	clamp_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	clamp_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	clamp_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	clamp_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_linear_clamp_sampler = rd.sampler_create(clamp_state)

	var repeat_state := RDSamplerState.new()
	repeat_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	repeat_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	repeat_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	repeat_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	repeat_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_linear_repeat_sampler = rd.sampler_create(repeat_state)

	var source_state := RDSamplerState.new()
	source_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	source_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	source_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	source_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	source_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_source_color_sampler = rd.sampler_create(source_state)


func _create_fallback_shore_mask() -> void:
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.set_pixel(0, 0, Color(1.0, 0.5, 0.5, 1.0))
	_fallback_shore_texture = ImageTexture.create_from_image(img)
	_shore_mask_rid = RenderingServer.texture_get_rd_texture(_fallback_shore_texture.get_rid())


func _load_caustics_textures() -> void:
	_caustics_noise_texture = load(CAUSTICS_NOISE_PATH) as Texture2D
	if _caustics_noise_texture == null:
		Log.warn("water", "WaterlineCompositorEffect: missing caustics noise texture, caustics disabled")
		_caustics_noise_texture = _make_solid_texture(Color.BLACK)
	_caustics_noise_rid = RenderingServer.texture_get_rd_texture(_caustics_noise_texture.get_rid())


func _make_solid_texture(color: Color) -> Texture2D:
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.set_pixel(0, 0, color)
	return ImageTexture.create_from_image(img)


func sync_from_water_state(state: WaterSurfaceState) -> void:
	if state == null:
		return

	_sea_level = state.sea_level
	_displacement_rid = state.displacement_texture_rd
	_water_tint = state.absorption_tint
	_absorption_sigma = state.absorption_sigma
	_caustics_strength = state.underwater_caustics_strength
	_ocean_time = state.ocean_time
	_map_scales = state.map_scales
	_wave_scale = state.wave_scale
	_shore_mask_bounds = state.shore_mask_bounds
	_shore_fade_distance = state.shore_fade_distance
	_shore_wave_amplitude = state.shore_wave_amplitude
	_shore_wave_frequency = state.shore_wave_frequency
	_shore_wave_speed = state.shore_wave_speed
	_shore_wave_steepness = state.shore_wave_steepness
	if state.shore_mask_rd.is_valid():
		_shore_mask_rid = state.shore_mask_rd
	elif _fallback_shore_texture != null:
		_shore_mask_rid = RenderingServer.texture_get_rd_texture(_fallback_shore_texture.get_rid())


func sync_from_ocean(ocean_manager: Node, ocean_material: ShaderMaterial) -> void:
	if ocean_manager == null:
		return
	if ocean_manager.has_method("get_water_surface_state"):
		sync_from_water_state(ocean_manager.get_water_surface_state())
		return
	if ocean_material != null:
		Log.warn("water", "WaterlineCompositorEffect: refused material fallback; WaterSurfaceState is the required water contract")


func set_probe_strength(value: float) -> void:
	_probe_strength = clampf(value, 0.0, 1.0)


func set_debug_mode(value: int) -> void:
	_debug_mode = clampi(value, 0, 14)


func set_camera_water_level(value: float) -> void:
	_camera_water_level = value


func set_near_water_activation_distance(value: float) -> void:
	_near_water_activation_distance = maxf(value, 0.0)
	_near_water_fade_start_distance = minf(_near_water_fade_start_distance, _near_water_activation_distance)


func set_near_water_fade_start_distance(value: float) -> void:
	_near_water_fade_start_distance = clampf(value, 0.0, _near_water_activation_distance)


func set_sun_direction(value: Vector3) -> void:
	if value.length_squared() <= 0.0001:
		return
	_sun_direction = value.normalized()


func set_sun_visibility(value: float) -> void:
	_sun_visibility = clampf(value, 0.0, 1.0)


func set_underwater_feature_enabled(feature_name: StringName, enabled: bool) -> void:
	var bit := _feature_bit(feature_name)
	if bit == 0:
		return
	if enabled:
		_underwater_feature_flags |= bit
	else:
		_underwater_feature_flags &= ~bit


func is_underwater_feature_enabled(feature_name: StringName) -> bool:
	var bit := _feature_bit(feature_name)
	return bit != 0 and (_underwater_feature_flags & bit) != 0


func set_underwater_ray_params(shell_count: int, shell_spacing_m: float, intensity: float, shell_start_m: float) -> void:
	_ray_shell_count = clampi(shell_count, 1, 8)
	_ray_shell_spacing_m = clampf(shell_spacing_m, 1.0, 80.0)
	_ray_intensity = clampf(intensity, 0.0, 4.0)
	_ray_shell_start_m = clampf(shell_start_m, 1.0, 80.0)


func set_underwater_particle_params(noise_scale: float, density: float, near_gate_m: float, far_gate_m: float) -> void:
	_particle_noise_scale = clampf(noise_scale, 0.005, 1.5)
	_particle_density = clampf(density, 0.0, 8.0)
	_particle_near_gate_m = clampf(near_gate_m, 0.25, 40.0)
	_particle_far_gate_m = maxf(clampf(far_gate_m, 5.0, 300.0), _particle_near_gate_m + 1.0)


func get_underwater_perf_snapshot() -> Dictionary:
	_refresh_timestamp_snapshot()
	return _last_perf_snapshot.duplicate()


func _feature_bit(feature_name: StringName) -> int:
	match feature_name:
		&"absorption_fog":
			return FEATURE_ABSORPTION_FOG
		&"snell":
			return FEATURE_SNELL
		&"rays":
			return FEATURE_RAYS
		&"wobble":
			return FEATURE_WOBBLE
		&"particles":
			return FEATURE_PARTICLES
		&"meniscus_refraction":
			return FEATURE_MENISCUS_REFRACTION
		&"caustics":
			return FEATURE_CAUSTICS
		_:
			return 0


func set_external_source_buffers(color_rid: RID, depth_rid: RID, size: Vector2i) -> void:
	_external_source_color_rid = color_rid
	_external_source_depth_rid = depth_rid
	_external_source_size = size


func clear_external_source_buffers() -> void:
	_external_source_color_rid = RID()
	_external_source_depth_rid = RID()
	_external_source_size = Vector2i.ZERO


func _render_callback(p_effect_callback_type: int, render_data: RenderData) -> void:
	if p_effect_callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
		return
	_refresh_timestamp_snapshot()
	if not _render_logged:
		_render_logged = true
		Log.info("water", "WaterlineCompositorEffect: render callback fired enabled=%s pipeline=%s displacement=%s shore=%s" % [
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
	var camera_pos := scene_data.get_cam_transform().origin
	var camera_delta := camera_pos.y - _camera_water_level
	var activation_fade := _compute_near_water_fade(camera_delta)
	if activation_fade <= 0.001 and _debug_mode == 0:
		return

	var view_count: int = buffers.get_view_count()
	for view in view_count:
		_render_view(view, size, buffers, scene_data, activation_fade)


func _compute_near_water_fade(camera_delta: float) -> float:
	if camera_delta <= 0.0:
		return 1.0
	var distance := absf(camera_delta)
	var fade_end := maxf(_near_water_activation_distance, 0.0)
	var fade_start := clampf(_near_water_fade_start_distance, 0.0, fade_end)
	if fade_end <= fade_start + 0.001:
		return 1.0 if distance <= fade_end else 0.0
	return 1.0 - smoothstep(fade_start, fade_end, distance)


func _render_view(view: int, size: Vector2i, buffers: RenderSceneBuffersRD, scene_data: RenderSceneDataRD, activation_fade: float) -> void:
	var color_image := buffers.get_color_layer(view)
	var depth_texture := buffers.get_depth_layer(view)
	if not color_image.is_valid() or not depth_texture.is_valid():
		return
	var scene_copy_valid := _copy_scene_color(color_image, size)
	var has_external_source := (
		_external_source_color_rid.is_valid()
		and _external_source_depth_rid.is_valid()
		and _external_source_size != Vector2i.ZERO
	)
	if not has_external_source:
		if not _missing_source_warning_logged:
			_missing_source_warning_logged = true
			Log.warn("water", "WaterlineCompositorEffect: missing receiver source buffers; receiver refraction disabled")
	var source_color_rid := _external_source_color_rid
	var source_depth_rid := _external_source_depth_rid
	var source_color_valid := has_external_source
	var source_depth_valid := has_external_source
	var source_log_key := "%s/%s/%s/%s" % [
		has_external_source,
		source_color_valid,
		source_depth_valid,
		_external_source_size,
	]
	if source_log_key != _last_source_log_key:
		_last_source_log_key = source_log_key
		Log.info("water", "WaterlineCompositorEffect: source buffers external=%s color_valid=%s depth_valid=%s size=%s" % [
			has_external_source,
			source_color_valid,
			source_depth_valid,
			_external_source_size,
		])

	var matrix_data := _build_state_buffer_data(scene_data)
	var matrix_bytes := matrix_data.to_byte_array()
	if _state_buffer.is_valid():
		rd.free_rid(_state_buffer)
	_state_buffer = rd.storage_buffer_create(matrix_bytes.size(), matrix_bytes)

	var pc := PackedFloat32Array()
	pc.append(float(size.x))
	pc.append(float(size.y))
	pc.append(_ocean_time)
	pc.append(blend_factor * activation_fade)
	pc.append(_sea_level)
	pc.append(_wave_scale)
	pc.append(float(mini(_map_scales.size(), MAX_CASCADES)))
	pc.append(_probe_strength)
	pc.append(float(_debug_mode))
	pc.append(1.0 if source_color_valid else 0.0)
	pc.append(1.0 if source_depth_valid else 0.0)
	pc.append(1.0 if scene_copy_valid else 0.0)
	pc.append(float(_underwater_feature_flags))
	pc.append(_camera_water_level)
	pc.append(0.0)
	pc.append(0.0)
	pc.append(float(_ray_shell_count))
	pc.append(_ray_shell_spacing_m)
	pc.append(_ray_intensity)
	pc.append(_ray_shell_start_m)
	pc.append(_particle_noise_scale)
	pc.append(_particle_density)
	pc.append(_particle_near_gate_m)
	pc.append(_particle_far_gate_m)
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
	u_displacement.add_id(_linear_repeat_sampler)
	u_displacement.add_id(_displacement_rid)
	uniforms.append(u_displacement)

	var u_shore := RDUniform.new()
	u_shore.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_shore.binding = 3
	u_shore.add_id(_linear_clamp_sampler)
	u_shore.add_id(_shore_mask_rid)
	uniforms.append(u_shore)

	var u_state := RDUniform.new()
	u_state.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_state.binding = 4
	u_state.add_id(_state_buffer)
	uniforms.append(u_state)

	var u_source := RDUniform.new()
	u_source.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_source.binding = 5
	u_source.add_id(_source_color_sampler)
	u_source.add_id(source_color_rid if source_color_rid.is_valid() else color_image)
	uniforms.append(u_source)

	var u_source_depth := RDUniform.new()
	u_source_depth.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_source_depth.binding = 6
	u_source_depth.add_id(_depth_sampler)
	u_source_depth.add_id(source_depth_rid if source_depth_rid.is_valid() else depth_texture)
	uniforms.append(u_source_depth)

	var u_scene_color := RDUniform.new()
	u_scene_color.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_scene_color.binding = 7
	u_scene_color.add_id(_source_color_sampler)
	u_scene_color.add_id(_scene_color_copy_rid if scene_copy_valid else color_image)
	uniforms.append(u_scene_color)

	var u_caustics_noise := RDUniform.new()
	u_caustics_noise.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_caustics_noise.binding = 8
	u_caustics_noise.add_id(_linear_repeat_sampler)
	u_caustics_noise.add_id(_caustics_noise_rid)
	uniforms.append(u_caustics_noise)

	var uniform_set := rd.uniform_set_create(uniforms, shader_rid, 0)
	if not uniform_set.is_valid():
		return

	var groups_x := (size.x + 7) / 8
	var groups_y := (size.y + 7) / 8
	rd.capture_timestamp("godotwind_waterline_probe_begin")
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline_rid)
	rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	rd.compute_list_set_push_constant(cl, pc_bytes, pc_bytes.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	rd.compute_list_end()
	rd.capture_timestamp("godotwind_waterline_probe_end")
	rd.free_rid(uniform_set)


func _copy_scene_color(color_image: RID, size: Vector2i) -> bool:
	if not color_image.is_valid() or not _scene_copy_pipeline_rid.is_valid():
		return false
	if not _ensure_scene_copy_texture(color_image, size):
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
	u_target.add_id(_scene_color_copy_rid)
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
	rd.capture_timestamp("godotwind_waterline_scene_copy_begin")
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, _scene_copy_pipeline_rid)
	rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	rd.compute_list_set_push_constant(cl, pc_bytes, pc_bytes.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	rd.compute_list_add_barrier(cl)
	rd.compute_list_end()
	rd.capture_timestamp("godotwind_waterline_scene_copy_end")
	rd.free_rid(uniform_set)
	return true


func _ensure_scene_copy_texture(color_image: RID, size: Vector2i) -> bool:
	if _scene_color_copy_rid.is_valid() and _scene_copy_size == size:
		return true

	if _scene_color_copy_rid.is_valid():
		rd.free_rid(_scene_color_copy_rid)
		_scene_color_copy_rid = RID()
	_scene_copy_size = Vector2i.ZERO

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
	_scene_color_copy_rid = rd.texture_create(color_fmt, RDTextureView.new())
	if not _scene_color_copy_rid.is_valid():
		return false
	_scene_copy_size = size
	return true


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
	data.append(_sun_direction.x)
	data.append(_sun_direction.y)
	data.append(_sun_direction.z)
	data.append(_sun_visibility)

	var projection: Projection = scene_data.get_cam_projection()
	for col in 4:
		for row in 4:
			data.append(projection[col][row])

	var view: Transform3D = inv_view.affine_inverse()
	for col in 3:
		data.append(view.basis[col].x)
		data.append(view.basis[col].y)
		data.append(view.basis[col].z)
		data.append(0.0)
	data.append(view.origin.x)
	data.append(view.origin.y)
	data.append(view.origin.z)
	data.append(1.0)
	return data


func _refresh_timestamp_snapshot() -> void:
	if rd == null:
		return
	var frame := rd.get_captured_timestamps_frame()
	if frame == _last_perf_frame:
		return
	_last_perf_frame = frame

	var count := rd.get_captured_timestamps_count()
	var scene_copy_begin := -1
	var scene_copy_end := -1
	var probe_begin := -1
	var probe_end := -1
	for i in count:
		var name := rd.get_captured_timestamp_name(i)
		match name:
			"godotwind_waterline_scene_copy_begin":
				scene_copy_begin = rd.get_captured_timestamp_gpu_time(i)
			"godotwind_waterline_scene_copy_end":
				scene_copy_end = rd.get_captured_timestamp_gpu_time(i)
			"godotwind_waterline_probe_begin":
				probe_begin = rd.get_captured_timestamp_gpu_time(i)
			"godotwind_waterline_probe_end":
				probe_end = rd.get_captured_timestamp_gpu_time(i)

	var scene_copy_ms := _timestamp_delta_ms(scene_copy_begin, scene_copy_end)
	var probe_ms := _timestamp_delta_ms(probe_begin, probe_end)
	_last_perf_snapshot = {
		"scene_copy_ms": scene_copy_ms,
		"probe_ms": probe_ms,
		"total_ms": scene_copy_ms + probe_ms,
		"frame": frame,
		"feature_flags": _underwater_feature_flags,
		"ray_shell_count": _ray_shell_count,
		"ray_shell_spacing_m": _ray_shell_spacing_m,
		"ray_intensity": _ray_intensity,
		"particle_noise_scale": _particle_noise_scale,
		"particle_density": _particle_density,
	}


func _timestamp_delta_ms(begin_us: int, end_us: int) -> float:
	if begin_us < 0 or end_us < 0 or end_us < begin_us:
		return 0.0
	return float(end_us - begin_us) / 1000.0


func on_effect_removed() -> void:
	super.on_effect_removed()
	if rd:
		if _depth_sampler.is_valid():
			rd.free_rid(_depth_sampler)
			_depth_sampler = RID()
		if _linear_clamp_sampler.is_valid():
			rd.free_rid(_linear_clamp_sampler)
			_linear_clamp_sampler = RID()
		if _linear_repeat_sampler.is_valid():
			rd.free_rid(_linear_repeat_sampler)
			_linear_repeat_sampler = RID()
		if _source_color_sampler.is_valid():
			rd.free_rid(_source_color_sampler)
			_source_color_sampler = RID()
		if _scene_color_copy_rid.is_valid():
			rd.free_rid(_scene_color_copy_rid)
			_scene_color_copy_rid = RID()
		if _scene_copy_pipeline_rid.is_valid():
			rd.free_rid(_scene_copy_pipeline_rid)
			_scene_copy_pipeline_rid = RID()
		if _scene_copy_shader_rid.is_valid():
			rd.free_rid(_scene_copy_shader_rid)
			_scene_copy_shader_rid = RID()
		if _state_buffer.is_valid():
			rd.free_rid(_state_buffer)
			_state_buffer = RID()
	_scene_copy_size = Vector2i.ZERO
