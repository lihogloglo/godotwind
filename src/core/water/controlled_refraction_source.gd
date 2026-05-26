## ControlledRefractionSource
##
## Ocean Lab vertical slice for an OpenMW-style refraction source: a named
## receiver-only color/depth pair captured through PrewaterCaptureRenderer.
class_name ControlledRefractionSource
extends Node

const PrewaterCaptureRendererScript := preload("res://src/core/water/prewater_capture_renderer.gd")

const DEFAULT_RECEIVER_LAYER_MASK: int = 1 << 17
const DEFAULT_SOURCE_RESOLUTION_SCALE: float = 0.5
const ALWAYS_ACTIVE_FADE_START_M: float = 999999.0
const ALWAYS_ACTIVE_FADE_END_M: float = 1000000.0

var receiver_layer_mask: int = DEFAULT_RECEIVER_LAYER_MASK
var source_resolution_scale: float = DEFAULT_SOURCE_RESOLUTION_SCALE:
	set(value):
		source_resolution_scale = clampf(
			value,
			PrewaterCaptureRenderer.MIN_RESOLUTION_SCALE,
			PrewaterCaptureRenderer.MAX_RESOLUTION_SCALE
		)

var _camera: Camera3D = null
var _environment: Environment = null
var _world_environment: WorldEnvironment = null
var _enabled: bool = false
var _capture: PrewaterCaptureRenderer = null
var _last_update_cpu_ms: float = 0.0


func _ready() -> void:
	_ensure_capture()


func _exit_tree() -> void:
	shutdown()


func shutdown() -> void:
	_enabled = false
	if _capture != null:
		_capture.shutdown()
		_capture.queue_free()
	_capture = null


func configure(camera: Camera3D, environment_or_world: Variant, p_receiver_layer_mask: int = DEFAULT_RECEIVER_LAYER_MASK) -> void:
	_camera = camera
	_environment = null
	_world_environment = null
	if environment_or_world is WorldEnvironment:
		_world_environment = environment_or_world
		_environment = _world_environment.environment
	elif environment_or_world is Environment:
		_environment = environment_or_world
	receiver_layer_mask = p_receiver_layer_mask
	_ensure_capture()
	if _capture != null:
		_capture.configure(_camera, _environment, receiver_layer_mask, 0)


func set_enabled(value: bool) -> void:
	_enabled = value
	if not _enabled and _capture != null:
		_capture.set_capture_enabled(false)
		_capture.set_blend_factor(0.0)


func is_enabled() -> bool:
	return _enabled


func process_source(main_viewport_size: Vector2i, activation_water_level: float = 0.0) -> void:
	var start_usec := Time.get_ticks_usec()
	_ensure_capture()
	if _capture == null:
		_last_update_cpu_ms = 0.0
		return

	var active := _enabled and _camera != null and is_instance_valid(_camera)
	_capture.configure(_camera, _environment, receiver_layer_mask, 0)
	_capture.near_water_capture_fade_start_m = ALWAYS_ACTIVE_FADE_START_M
	_capture.near_water_capture_distance_m = ALWAYS_ACTIVE_FADE_END_M
	_capture.set_resolution_scale(source_resolution_scale)
	_capture.set_capture_enabled(active)
	_capture.set_blend_factor(1.0 if active else 0.0)
	_capture.set_activation_water_level(activation_water_level)
	_capture.update_capture(_safe_viewport_size(main_viewport_size))
	_last_update_cpu_ms = float(Time.get_ticks_usec() - start_usec) / 1000.0


func has_source() -> bool:
	return _capture != null and _capture.has_capture()


func get_source_color_rid() -> RID:
	if _capture == null:
		return RID()
	return _capture.get_source_color_rid()


func get_source_depth_rid() -> RID:
	if _capture == null:
		return RID()
	return _capture.get_source_depth_rid()


func get_source_size() -> Vector2i:
	if _capture == null:
		return Vector2i.ZERO
	return _capture.get_source_size()


func get_source_process_frame() -> int:
	if _capture == null:
		return -1
	return _capture.get_capture_process_frame()


func has_source_renderer_matrices() -> bool:
	return _capture != null and _capture.has_capture_renderer_matrices()


func get_source_renderer_matrix_frame() -> int:
	if _capture == null:
		return -1
	return _capture.get_capture_renderer_matrix_frame()


func get_source_projection() -> Projection:
	if _capture == null:
		return Projection()
	return _capture.get_capture_renderer_projection()


func get_source_camera_transform() -> Transform3D:
	if _capture == null:
		return Transform3D.IDENTITY
	return _capture.get_capture_renderer_camera_transform()


func push_to_surface_refraction_effect(effect: Object) -> bool:
	if effect == null:
		return false
	if not has_source():
		if effect.has_method("clear_external_source_buffers"):
			effect.call("clear_external_source_buffers")
		return false
	if has_source_renderer_matrices() and effect.has_method("set_source_camera_matrices"):
		effect.call("set_source_camera_matrices", get_source_projection(), get_source_camera_transform())
	elif effect.has_method("clear_source_camera_matrices"):
		effect.call("clear_source_camera_matrices")
	if not effect.has_method("set_external_source_buffers"):
		return false
	effect.call(
		"set_external_source_buffers",
		get_source_color_rid(),
		get_source_depth_rid(),
		get_source_size(),
		get_source_process_frame()
	)
	return true


func get_runtime_status() -> Dictionary:
	var copy_snapshot: Dictionary = {}
	if _capture != null:
		copy_snapshot = _capture.get_perf_snapshot()
	var copy_ms := float(copy_snapshot.get("prewater_copy_ms", 0.0))
	var copy_frame := int(copy_snapshot.get("frame", -1))
	var render_ms := float(copy_snapshot.get("source_render_ms", -1.0))
	var render_frame := int(copy_snapshot.get("source_render_frame", -1))
	var frame := get_source_process_frame()
	var frame_age := Engine.get_process_frames() - frame if frame >= 0 else -1
	var matrix_frame := get_source_renderer_matrix_frame()
	return {
		"enabled": _enabled,
		"source_valid": has_source(),
		"source_size": get_source_size(),
		"source_resolution_scale": source_resolution_scale,
		"source_process_frame": frame,
		"source_frame_age": frame_age,
		"source_has_renderer_matrices": has_source_renderer_matrices(),
		"source_renderer_matrix_frame": matrix_frame,
		"source_renderer_matrix_age": Engine.get_process_frames() - matrix_frame if matrix_frame >= 0 else -1,
		"receiver_layer_mask": receiver_layer_mask,
		"prewater_copy_ms": copy_ms,
		"prewater_copy_frame": copy_frame,
		"prewater_copy_timing_available": bool(copy_snapshot.get("timing_available", false)),
		"prewater_copy_timing_valid": bool(copy_snapshot.get("timing_valid", false)),
		"prewater_copy_timing_marker_scope": str(copy_snapshot.get("prewater_copy_timing_marker_scope", "")),
		"prewater_copy_timing_marker_begin": str(copy_snapshot.get("prewater_copy_timing_marker_begin", "")),
		"prewater_copy_timing_marker_end": str(copy_snapshot.get("prewater_copy_timing_marker_end", "")),
		"source_update_cpu_ms": _last_update_cpu_ms,
		"source_render_ms": render_ms,
		"source_render_frame": render_frame,
		"source_render_timing_available": bool(copy_snapshot.get("source_render_timing_available", false)),
		"source_render_timing_valid": bool(copy_snapshot.get("source_render_timing_valid", false)),
		"source_render_timing_scope": str(copy_snapshot.get("source_render_timing_scope", "unavailable")),
		"source_render_timing_marker_scope": str(copy_snapshot.get("source_render_timing_marker_scope", "")),
		"source_render_timing_marker_begin": str(copy_snapshot.get("source_render_timing_marker_begin", "")),
		"source_render_timing_marker_end": str(copy_snapshot.get("source_render_timing_marker_end", "")),
	}


func _ensure_capture() -> void:
	if _capture != null:
		return
	_capture = PrewaterCaptureRendererScript.new()
	_capture.name = "ControlledRefractionPrewaterCapture"
	_capture.occlusion_capture_enabled = false
	_capture.set_resolution_scale(source_resolution_scale)
	add_child(_capture)


func _safe_viewport_size(size: Vector2i) -> Vector2i:
	if size.x > 0 and size.y > 0:
		return size
	var viewport := get_viewport()
	if viewport != null:
		var rect_size := viewport.get_visible_rect().size
		if rect_size.x > 0.0 and rect_size.y > 0.0:
			return Vector2i(int(rect_size.x), int(rect_size.y))
	return PrewaterCaptureRenderer.DEFAULT_FALLBACK_SIZE
