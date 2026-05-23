## PrewaterCaptureRenderer
##
## Owns the receiver-only pre-water capture viewport used by waterline and
## underwater compositor passes. This keeps the render-order workaround out of
## individual lab scenes: callers provide a source camera, an environment, and
## the receiver layer mask; this node maintains a matching SubViewport camera
## and exposes the last completed color/depth capture RIDs.
##
## Latency contract: the consuming compositor samples the most recent completed
## capture textures. Depending on viewport scheduling this can be one rendered
## frame behind the main viewport, and the effect must tolerate that. This node
## deliberately does not force a GPU sync or readback.
class_name PrewaterCaptureRenderer
extends Node

const PrewaterCaptureScript := preload("res://src/core/shaders/effects/prewater_capture_effect.gd")

const MIN_RESOLUTION_SCALE := 0.25
const MAX_RESOLUTION_SCALE := 1.0
const DEFAULT_FALLBACK_SIZE := Vector2i(1280, 720)
const DEFAULT_CAPTURE_FADE_START_M := 80.0
const DEFAULT_CAPTURE_FADE_END_M := 140.0

var receiver_layer_mask: int = 1
var occlusion_exclusion_layer_mask: int = 0
var near_water_capture_distance_m: float = DEFAULT_CAPTURE_FADE_END_M
var near_water_capture_fade_start_m: float = DEFAULT_CAPTURE_FADE_START_M

var _source_camera: Camera3D = null
var _source_environment: Environment = null
var _viewport: SubViewport = null
var _occlusion_viewport: SubViewport = null
var _capture_camera: Camera3D = null
var _occlusion_camera: Camera3D = null
var _compositor: Compositor = null
var _occlusion_compositor: Compositor = null
var _capture_effect: PrewaterCaptureEffect = null
var _occlusion_effect: PrewaterCaptureEffect = null
var _resolution_scale: float = 0.5
var _capture_enabled: bool = false
var _blend_factor: float = 0.0
var _camera_water_level: float = 0.0
var _capture_active: bool = false
var _activation_fade: float = 0.0


func _ready() -> void:
	_ensure_nodes()


func _exit_tree() -> void:
	shutdown()


func shutdown() -> void:
	_capture_enabled = false
	_blend_factor = 0.0
	_capture_active = false
	_activation_fade = 0.0
	if _viewport != null:
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if _occlusion_viewport != null:
		_occlusion_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if _capture_camera != null:
		_capture_camera.compositor = null
	if _occlusion_camera != null:
		_occlusion_camera.compositor = null
	if _compositor != null:
		_compositor.compositor_effects = []
	if _occlusion_compositor != null:
		_occlusion_compositor.compositor_effects = []
	if _capture_effect != null:
		_capture_effect.on_effect_removed()
	if _occlusion_effect != null:
		_occlusion_effect.on_effect_removed()
	if _viewport != null:
		_viewport.queue_free()
	if _occlusion_viewport != null:
		_occlusion_viewport.queue_free()
	_capture_camera = null
	_occlusion_camera = null
	_viewport = null
	_occlusion_viewport = null
	_capture_effect = null
	_occlusion_effect = null
	_compositor = null
	_occlusion_compositor = null


func configure(camera: Camera3D, environment: Environment, layer_mask: int, p_occlusion_exclusion_layer_mask: int = 0) -> void:
	_source_camera = camera
	_source_environment = environment
	receiver_layer_mask = layer_mask
	occlusion_exclusion_layer_mask = p_occlusion_exclusion_layer_mask
	_ensure_nodes()
	_sync_camera()


func set_capture_enabled(value: bool) -> void:
	_capture_enabled = value
	_apply_active_state()


func is_capture_enabled() -> bool:
	return _capture_enabled


func set_blend_factor(value: float) -> void:
	_blend_factor = clampf(value, 0.0, 1.0)
	_apply_active_state()


func set_resolution_scale(value: float) -> void:
	_resolution_scale = clampf(value, MIN_RESOLUTION_SCALE, MAX_RESOLUTION_SCALE)


func get_resolution_scale() -> float:
	return _resolution_scale


## Sets the water-body datum used only for capture activation. The compositor
## shader still owns per-pixel wave classification after the pass is active.
func set_activation_water_level(value: float) -> void:
	_camera_water_level = value


func set_camera_water_level(value: float) -> void:
	set_activation_water_level(value)


func get_activation_fade() -> float:
	return _activation_fade


func update_capture(main_size: Vector2i) -> void:
	_ensure_nodes()
	_update_active_state()
	_sync_viewport_size(main_size)
	_sync_camera()


func is_capture_active() -> bool:
	return _capture_active


func has_capture() -> bool:
	return _capture_active and _capture_effect != null and _capture_effect.has_capture()


func has_occlusion_capture() -> bool:
	return _capture_active and _occlusion_effect != null and _occlusion_effect.has_capture()


func get_source_color_rid() -> RID:
	if _capture_effect == null:
		return RID()
	return _capture_effect.get_source_color_rid()


func get_source_depth_rid() -> RID:
	if _capture_effect == null:
		return RID()
	return _capture_effect.get_source_depth_rid()


func get_source_size() -> Vector2i:
	if _capture_effect == null:
		return Vector2i.ZERO
	return _capture_effect.get_source_size()


func get_source_texture() -> Texture2D:
	if _viewport == null:
		return null
	return _viewport.get_texture()


func get_capture_process_frame() -> int:
	if _capture_effect == null or not _capture_effect.has_method("get_capture_process_frame"):
		return -1
	return int(_capture_effect.call("get_capture_process_frame"))


func get_occlusion_depth_rid() -> RID:
	if _occlusion_effect == null:
		return RID()
	return _occlusion_effect.get_source_depth_rid()


func get_occlusion_size() -> Vector2i:
	if _occlusion_effect == null:
		return Vector2i.ZERO
	return _occlusion_effect.get_source_size()


func get_occlusion_process_frame() -> int:
	if _occlusion_effect == null or not _occlusion_effect.has_method("get_capture_process_frame"):
		return -1
	return int(_occlusion_effect.call("get_capture_process_frame"))


func get_perf_snapshot() -> Dictionary:
	if _capture_effect == null or not _capture_effect.has_method("get_capture_perf_snapshot"):
		return {}
	var snapshot: Variant = _capture_effect.call("get_capture_perf_snapshot")
	if snapshot is Dictionary:
		var result := (snapshot as Dictionary).duplicate()
		result["capture_active"] = _capture_active
		result["resolution_scale"] = _resolution_scale
		result["activation_fade"] = _activation_fade
		result["current_process_frame"] = Engine.get_process_frames()
		result["capture_frame_age"] = Engine.get_process_frames() - get_capture_process_frame() if get_capture_process_frame() >= 0 else -1
		result["has_occlusion_capture"] = has_occlusion_capture()
		result["occlusion_size"] = get_occlusion_size()
		result["occlusion_process_frame"] = get_occlusion_process_frame()
		result["occlusion_frame_age"] = Engine.get_process_frames() - get_occlusion_process_frame() if get_occlusion_process_frame() >= 0 else -1
		return result
	return {}


func push_to_waterline_effect(effect: Object) -> bool:
	if effect == null:
		return false
	if not has_capture():
		if effect.has_method("clear_external_source_buffers"):
			effect.call("clear_external_source_buffers")
		if effect.has_method("clear_external_occlusion_depth_buffer"):
			effect.call("clear_external_occlusion_depth_buffer")
		return false
	if not effect.has_method("set_external_source_buffers"):
		return false
	effect.call(
		"set_external_source_buffers",
		get_source_color_rid(),
		get_source_depth_rid(),
		get_source_size(),
		get_capture_process_frame()
	)
	if effect.has_method("set_external_occlusion_depth_buffer") and has_occlusion_capture():
		effect.call(
			"set_external_occlusion_depth_buffer",
			get_occlusion_depth_rid(),
			get_occlusion_size(),
			get_occlusion_process_frame()
		)
	elif effect.has_method("clear_external_occlusion_depth_buffer"):
		effect.call("clear_external_occlusion_depth_buffer")
	return true


func _ensure_nodes() -> void:
	if _viewport == null:
		_viewport = SubViewport.new()
		_viewport.name = "PrewaterCaptureViewport"
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_viewport.transparent_bg = false
		_viewport.msaa_3d = Viewport.MSAA_DISABLED
		_viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
		_viewport.use_taa = false
		_viewport.own_world_3d = false
		_viewport.handle_input_locally = false
		add_child(_viewport)

	if _occlusion_viewport == null:
		_occlusion_viewport = SubViewport.new()
		_occlusion_viewport.name = "PrewaterOcclusionViewport"
		_occlusion_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_occlusion_viewport.transparent_bg = false
		_occlusion_viewport.msaa_3d = Viewport.MSAA_DISABLED
		_occlusion_viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
		_occlusion_viewport.use_taa = false
		_occlusion_viewport.own_world_3d = false
		_occlusion_viewport.handle_input_locally = false
		add_child(_occlusion_viewport)

	if _capture_effect == null:
		_capture_effect = PrewaterCaptureScript.new()
		_capture_effect.effect_enabled = false
		_capture_effect.blend_factor = 0.0
		_capture_effect.on_effect_added()

	if _occlusion_effect == null:
		_occlusion_effect = PrewaterCaptureScript.new()
		_occlusion_effect.effect_enabled = false
		_occlusion_effect.blend_factor = 0.0
		_occlusion_effect.on_effect_added()

	if _compositor == null:
		_compositor = Compositor.new()
		_compositor.compositor_effects = [_capture_effect]

	if _occlusion_compositor == null:
		_occlusion_compositor = Compositor.new()
		_occlusion_compositor.compositor_effects = [_occlusion_effect]

	if _capture_camera == null:
		_capture_camera = Camera3D.new()
		_capture_camera.name = "PrewaterCaptureCamera"
		_capture_camera.current = true
		_capture_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		_capture_camera.compositor = _compositor
		_viewport.add_child(_capture_camera)

	if _occlusion_camera == null:
		_occlusion_camera = Camera3D.new()
		_occlusion_camera.name = "PrewaterOcclusionCamera"
		_occlusion_camera.current = true
		_occlusion_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		_occlusion_camera.compositor = _occlusion_compositor
		_occlusion_viewport.add_child(_occlusion_camera)

	_apply_active_state()


func _update_active_state() -> void:
	var near_water_fade := 1.0
	if _source_camera != null and is_instance_valid(_source_camera):
		var camera_delta := _source_camera.global_position.y - _camera_water_level
		near_water_fade = _compute_near_water_fade(camera_delta)
	_activation_fade = near_water_fade
	_capture_active = _capture_enabled and _blend_factor > 0.0 and near_water_fade > 0.001
	_apply_active_state()


func _apply_active_state() -> void:
	if _capture_effect != null:
		_capture_effect.effect_enabled = _capture_active
		_capture_effect.blend_factor = _blend_factor * _activation_fade if _capture_active else 0.0
	if _occlusion_effect != null:
		_occlusion_effect.effect_enabled = _capture_active
		_occlusion_effect.blend_factor = _blend_factor * _activation_fade if _capture_active else 0.0
	if _viewport != null:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if _capture_active else SubViewport.UPDATE_DISABLED
	if _occlusion_viewport != null:
		_occlusion_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if _capture_active else SubViewport.UPDATE_DISABLED


func _compute_near_water_fade(camera_delta: float) -> float:
	if camera_delta <= 0.0:
		return 1.0
	var distance := absf(camera_delta)
	var fade_end := maxf(near_water_capture_distance_m, 0.0)
	var fade_start := clampf(near_water_capture_fade_start_m, 0.0, fade_end)
	if fade_end <= fade_start + 0.001:
		return 1.0 if distance <= fade_end else 0.0
	return 1.0 - smoothstep(fade_start, fade_end, distance)


func _sync_viewport_size(main_size: Vector2i) -> void:
	if _viewport == null:
		return
	var safe_size := main_size
	if safe_size.x <= 0 or safe_size.y <= 0:
		safe_size = DEFAULT_FALLBACK_SIZE
	var scaled := Vector2i(
		maxi(1, int(roundf(float(safe_size.x) * _resolution_scale))),
		maxi(1, int(roundf(float(safe_size.y) * _resolution_scale)))
	)
	if _viewport.size != scaled:
		_viewport.size = scaled
	if _occlusion_viewport != null and _occlusion_viewport.size != scaled:
		_occlusion_viewport.size = scaled


func _sync_camera() -> void:
	if _source_camera == null or not is_instance_valid(_source_camera):
		return
	_sync_camera_to(_capture_camera, receiver_layer_mask)
	_sync_camera_to(_occlusion_camera, _source_camera.cull_mask & ~occlusion_exclusion_layer_mask)


func _sync_camera_to(target_camera: Camera3D, cull_mask: int) -> void:
	if target_camera == null:
		return
	target_camera.global_transform = _source_camera.global_transform
	target_camera.projection = _source_camera.projection
	target_camera.fov = _source_camera.fov
	target_camera.size = _source_camera.size
	target_camera.near = _source_camera.near
	target_camera.far = _source_camera.far
	target_camera.cull_mask = cull_mask
	target_camera.environment = _source_environment
