## UnderwaterCompositorEffect — CompositorEffect for underwater post-processing
##
## Single-pass compute shader that applies caustics, absorption, wobble, light rays,
## backscattering, and boundary effects when the camera is submerged.
##
## Ported from Rafael & Hrnchamd's DIVE.omwfx (OpenMW).
## Follows the same pattern as GodraysEffect: compute shader + push constants.
##
## Managed by OceanManager — enabled when camera is below sea level.
@tool
class_name UnderwaterCompositorEffect
extends PostProcessEffect

const SHADER_PATH := "res://src/core/shaders/compute/underwater.glsl"

## Samplers and buffers
var _depth_sampler: RID
var _matrix_buffer: RID  # Storage buffer for inv_projection + inv_view (128 bytes)

## Sea level and camera state (set from main thread)
var _sea_level: float = 0.0
var _camera_pos: Vector3 = Vector3.ZERO
var _camera_basis: Basis = Basis.IDENTITY

## Sun tracking
var _sun_dir: Vector3 = Vector3(0.3, 0.8, 0.2).normalized()
var _sun_vis: float = 1.0

## Debug mode (0=off, 1-6=visualizations)
var _debug_mode: int = 0

## One-time render callback diagnostic
var _render_logged: bool = false


func _init() -> void:
	super._init()

	effect_name = "underwater"
	display_name = "Underwater Effects"
	description = "Caustics, absorption, light rays, wobble, backscatter for submerged camera. Ported from DIVE.omwfx."
	category = "Water"
	render_priority = 12  # After fog (10) and godrays (11)

	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	needs_depth = true

	_define_parameters()


func _define_parameters() -> void:
	register_parameter("caustic_intensity", 2.5, 0.0, 6.0, 0.1,
		"Caustic Intensity", "Brightness of underwater caustic patterns")
	register_parameter("ray_intensity", 3.0, 0.0, 10.0, 0.1,
		"Ray Intensity", "Brightness of underwater light rays")
	register_parameter("wobble_strength", 0.012, 0.0, 0.05, 0.001,
		"Wobble Strength", "Screen distortion from water")
	register_parameter("absorption_rate", 0.0015, 0.0005, 0.01, 0.0005,
		"Absorption Rate", "How quickly light is absorbed by water")
	register_parameter("scatter_strength", 0.55, 0.0, 1.0, 0.05,
		"Backscatter", "View-dependent light scattering from surfaces")
	register_parameter("boundary_distortion", 0.03, 0.0, 0.1, 0.005,
		"Boundary Distortion", "Refraction at the water surface boundary")
	register_parameter("caustic_surface_floor", 0.3, 0.0, 1.0, 0.05,
		"Caustic Surface Floor", "Minimum surface-alignment multiplier for caustics (was magic 0.2 clamp)")
	register_parameter("caustic_aa_far", 80.0, 10.0, 200.0, 5.0,
		"Caustic AA Start", "Distance where caustic anti-alias fade begins (m)")
	register_parameter("caustic_aa_near", 60.0, 10.0, 200.0, 5.0,
		"Caustic AA Full", "Distance where caustics are fully visible (m, must be < AA Start)")


func on_effect_added() -> void:
	var success := load_compute_shader(SHADER_PATH)
	Log.info("water", "UnderwaterCompositorEffect shader load: %s, pipeline_valid: %s, shader_valid: %s" % [
		success, pipeline_rid.is_valid(), shader_rid.is_valid()])
	if not success:
		push_error("[UnderwaterCompositorEffect] Failed to load shader")
		return

	_create_samplers()
	Log.info("water", "UnderwaterCompositorEffect initialized")


func _create_samplers() -> void:
	if rd == null:
		return
	var state := RDSamplerState.new()
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_depth_sampler = rd.sampler_create(state)


# ============================================================================
# PUBLIC API — called from main thread by OceanManager
# ============================================================================

func set_sea_level(level: float) -> void:
	_sea_level = level


func set_camera_state(pos: Vector3, basis: Basis) -> void:
	_camera_pos = pos
	_camera_basis = basis


func set_sun_direction(direction: Vector3, visibility: float) -> void:
	_sun_dir = direction.normalized()
	_sun_vis = visibility


func set_debug_mode(mode: int) -> void:
	_debug_mode = mode


func is_camera_submerged() -> bool:
	return _camera_pos.y < _sea_level + 2.0  # Include boundary zone


# ============================================================================
# RENDER CALLBACK — runs on render thread
# ============================================================================

func _render_callback(p_effect_callback_type: int, render_data: RenderData) -> void:
	if not _render_logged:
		_render_logged = true
		print("[UNDERWATER] _render_callback fired. enabled=%s blend=%.2f pipeline_valid=%s shader_valid=%s" % [
			effect_enabled, blend_factor, pipeline_rid.is_valid(), shader_rid.is_valid()])
	if not effect_enabled or blend_factor <= 0.0:
		return
	if not pipeline_rid.is_valid():
		return

	if rd == null:
		rd = RenderingServer.get_rendering_device()
		if rd == null:
			return

	var buffers := render_data.get_render_scene_buffers()
	if buffers == null:
		return
	var scene_data := render_data.get_render_scene_data()
	if scene_data == null:
		return

	var size: Vector2i = buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return

	var view_count: int = buffers.get_view_count()
	for view in view_count:
		_render_view(view, size, buffers, scene_data)


func _render_view(view: int, size: Vector2i,
		buffers: RenderSceneBuffersRD, scene_data: RenderSceneDataRD) -> void:
	var color_image := buffers.get_color_layer(view)
	var depth_texture := buffers.get_depth_layer(view)
	if not color_image.is_valid() or not depth_texture.is_valid():
		return

	# Get camera data from render thread (authoritative)
	var cam_transform := scene_data.get_cam_transform()
	var projection := scene_data.get_cam_projection()
	var cam_pos := cam_transform.origin

	# ── Build matrix buffer (binding 2, storage buffer) ──
	# inv_projection + inv_view = 32 floats = 128 bytes
	var inv_proj: Projection = projection.inverse()
	var inv_view: Transform3D = cam_transform  # inverse of view matrix = camera transform

	var matrix_data := PackedFloat32Array()
	# inv_projection (16 floats, column-major)
	for col in 4:
		for row in 4:
			matrix_data.append(inv_proj[col][row])
	# inv_view (16 floats, column-major from Transform3D)
	for col in 3:
		matrix_data.append(inv_view.basis[col].x)
		matrix_data.append(inv_view.basis[col].y)
		matrix_data.append(inv_view.basis[col].z)
		matrix_data.append(0.0)
	matrix_data.append(inv_view.origin.x)
	matrix_data.append(inv_view.origin.y)
	matrix_data.append(inv_view.origin.z)
	matrix_data.append(1.0)

	# Create or update matrix storage buffer
	var matrix_bytes := matrix_data.to_byte_array()
	if _matrix_buffer.is_valid():
		rd.free_rid(_matrix_buffer)
	_matrix_buffer = rd.storage_buffer_create(matrix_bytes.size(), matrix_bytes)

	# ── Build push constants (128 bytes = 32 floats, Godot hard limit) ──
	var pc := PackedFloat32Array()

	# camera_pos_sea: xyz=pos, w=sea_level
	pc.append(cam_pos.x)
	pc.append(cam_pos.y)
	pc.append(cam_pos.z)
	pc.append(_sea_level)

	# sun_params: xyz=dir, w=visibility
	pc.append(_sun_dir.x)
	pc.append(_sun_dir.y)
	pc.append(_sun_dir.z)
	pc.append(_sun_vis)

	# effect1: caustic, ray, wobble, absorption
	pc.append(get_param("caustic_intensity"))
	pc.append(get_param("ray_intensity"))
	pc.append(get_param("wobble_strength"))
	pc.append(get_param("absorption_rate"))

	# effect2: scatter, boundary, blend, TIME
	pc.append(get_param("scatter_strength"))
	pc.append(get_param("boundary_distortion"))
	pc.append(blend_factor)
	pc.append(Time.get_ticks_msec() / 1000.0)

	# water_tint_dbg: rgb=tint, w=debug_mode
	pc.append(0.015)
	pc.append(0.115)
	pc.append(0.145)
	pc.append(float(_debug_mode))

	# screen: width, height, pad, pad
	pc.append(float(size.x))
	pc.append(float(size.y))
	pc.append(0.0)
	pc.append(0.0)

	# caustic_params: surface_floor, aa_far, aa_near, reserved
	pc.append(get_param("caustic_surface_floor"))
	pc.append(get_param("caustic_aa_far"))
	pc.append(get_param("caustic_aa_near"))
	pc.append(0.0)

	# _pad1: reserved for future use
	pc.append(0.0); pc.append(0.0); pc.append(0.0); pc.append(0.0)

	var pc_bytes := pc.to_byte_array()

	# ── Create uniform set ──
	var uniforms: Array[RDUniform] = []

	# Binding 0: depth texture (sampler)
	var u0 := RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u0.binding = 0
	u0.add_id(_depth_sampler)
	u0.add_id(depth_texture)
	uniforms.append(u0)

	# Binding 1: color image (storage, read/write)
	var u1 := RDUniform.new()
	u1.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u1.binding = 1
	u1.add_id(color_image)
	uniforms.append(u1)

	# Binding 2: camera matrices (storage buffer, read-only)
	var u2 := RDUniform.new()
	u2.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u2.binding = 2
	u2.add_id(_matrix_buffer)
	uniforms.append(u2)

	var uniform_set := rd.uniform_set_create(uniforms, shader_rid, 0)
	if not uniform_set.is_valid():
		return

	# ── Dispatch ──
	var groups_x := (size.x + 7) / 8
	var groups_y := (size.y + 7) / 8

	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline_rid)
	rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	rd.compute_list_set_push_constant(cl, pc_bytes, pc_bytes.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	rd.compute_list_end()

	rd.free_rid(uniform_set)


func on_effect_removed() -> void:
	super.on_effect_removed()
	if rd:
		if _depth_sampler.is_valid():
			rd.free_rid(_depth_sampler)
			_depth_sampler = RID()
		if _matrix_buffer.is_valid():
			rd.free_rid(_matrix_buffer)
			_matrix_buffer = RID()
