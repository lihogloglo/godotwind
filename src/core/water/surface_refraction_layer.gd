## SurfaceRefractionLayer
##
## Coordinator for the experimental above-water surface refraction compositor.
## The main ocean remains opaque; this node consumes either the legacy
## water-excluded capture or an explicit controlled refraction source.
class_name SurfaceRefractionLayer
extends Node3D

const PrewaterCaptureRendererScript := preload("res://src/core/water/prewater_capture_renderer.gd")
const SurfaceRefractionCompositorScript := preload("res://src/core/shaders/effects/surface_refraction_compositor_effect.gd")

const CLIPMAP_SHADER_PATH := "res://src/core/water/shaders/ocean_surface_refraction_clipmap.gdshader"
const PROJECTED_SHADER_PATH := "res://src/core/water/shaders/ocean_surface_refraction_projected.gdshader"
const DEFAULT_SOURCE_RESOLUTION_SCALE: float = 0.5
const MIN_SOURCE_RESOLUTION_SCALE: float = 0.25
const MAX_SOURCE_RESOLUTION_SCALE: float = 1.0
const DEFAULT_SOURCE_FRAME_TOLERANCE: int = 2

var source_exclusion_layer_mask: int = 0
var refraction_strength: float = 0.45
var edge_guard_strength: float = 1.0
var overlay_opacity: float = 0.42
var diagnostic_overlay_enabled: bool = false
var source_resolution_scale: float = DEFAULT_SOURCE_RESOLUTION_SCALE:
	set(value):
		source_resolution_scale = clampf(value, MIN_SOURCE_RESOLUTION_SCALE, MAX_SOURCE_RESOLUTION_SCALE)
var source_frame_tolerance: int = DEFAULT_SOURCE_FRAME_TOLERANCE:
	set(value):
		source_frame_tolerance = maxi(0, value)
		if _effect != null:
			_effect.source_frame_tolerance = source_frame_tolerance
var diagnostic_stats_enabled: bool = false:
	set(value):
		diagnostic_stats_enabled = value
		if _effect != null:
			_effect.diagnostic_stats_enabled = diagnostic_stats_enabled

var _camera: Camera3D = null
var _environment: Environment = null
var _world_environment: WorldEnvironment = null
var _ocean_mesh: OceanMesh = null
var _enabled: bool = false
var _overlay: MeshInstance3D = null
var _capture: PrewaterCaptureRenderer = null
var _effect: SurfaceRefractionCompositorEffect = null
var _controlled_source: Object = null
var _material: ShaderMaterial = null
var _mesh_mode: int = -1
var _attached_world_environment: WorldEnvironment = null
var _attached_compositor: Compositor = null
var _created_attached_compositor: bool = false


func _ready() -> void:
	_ensure_nodes()


func _exit_tree() -> void:
	shutdown()


func shutdown() -> void:
	_enabled = false
	_detach_effect()
	if _capture != null:
		_capture.shutdown()
	if _effect != null:
		_effect.clear_external_source_buffers()
		_effect.effect_enabled = false
		_effect.blend_factor = 0.0
		_effect.on_effect_removed()
	if _overlay != null:
		_overlay.visible = false


func configure(camera: Camera3D, environment_or_world: Variant, ocean_mesh: OceanMesh, exclusion_layer_mask: int) -> void:
	_camera = camera
	_environment = null
	_world_environment = null
	if environment_or_world is WorldEnvironment:
		_world_environment = environment_or_world
		_environment = _world_environment.environment
	elif environment_or_world is Environment:
		_environment = environment_or_world
	source_exclusion_layer_mask = exclusion_layer_mask
	_ocean_mesh = ocean_mesh
	if _ocean_mesh != null:
		_mesh_mode = int(_ocean_mesh.get_mesh_mode())
	_ensure_nodes()
	_ensure_effect()
	if diagnostic_overlay_enabled:
		_ensure_material()


func set_enabled(value: bool) -> void:
	_enabled = value
	_apply_enabled_state()


func is_enabled() -> bool:
	return _enabled


func set_debug_mode(value: int) -> void:
	_ensure_effect()
	if _effect != null:
		_effect.set_debug_mode(value)


func get_debug_mode() -> int:
	if _effect != null:
		return _effect.get_debug_mode()
	return 0


func set_source_resolution_scale(value: float) -> void:
	source_resolution_scale = value


func set_source_frame_tolerance(value: int) -> void:
	source_frame_tolerance = value


func set_controlled_source(source: Object) -> void:
	_controlled_source = source


func clear_controlled_source() -> void:
	_controlled_source = null


func process_layer(main_viewport_size: Vector2i) -> void:
	_ensure_nodes()
	_ensure_effect()
	if not _enabled or _camera == null or _ocean_mesh == null or not is_instance_valid(_ocean_mesh):
		_apply_enabled_state()
		return

	if diagnostic_overlay_enabled:
		_ensure_material()
		_sync_overlay_from_ocean()
		_sync_material_from_ocean()

	if _has_controlled_source():
		_controlled_source.call("set_enabled", true)
		_controlled_source.set("source_resolution_scale", source_resolution_scale)
		_controlled_source.call("process_source", _safe_viewport_size(main_viewport_size), _get_ocean_sea_level())
	else:
		var capture_mask := _camera.cull_mask & ~source_exclusion_layer_mask
		_capture.configure(_camera, _environment, capture_mask, 0)
		_capture.near_water_capture_fade_start_m = 1.0e6 - 1.0
		_capture.near_water_capture_distance_m = 1.0e6
		_capture.set_resolution_scale(source_resolution_scale)
		_capture.set_capture_enabled(true)
		_capture.set_blend_factor(1.0)
		_capture.set_activation_water_level(_get_ocean_sea_level())
		_capture.update_capture(_safe_viewport_size(main_viewport_size))

	_sync_effect_from_water_state()
	_apply_enabled_state()
	_push_capture_to_effect()
	if diagnostic_overlay_enabled:
		_push_capture_to_overlay()


func get_runtime_status() -> Dictionary:
	var source_size := Vector2i.ZERO
	var source_valid := false
	var source_depth_valid := false
	var source_fresh := false
	var capture_age := -1
	var dispatch_size := Vector2i.ZERO
	var mask_mode := "final"
	var reject_reason := "inactive"
	var compositor_enabled := false
	var overlay_active := false
	var surface_refraction_ms := 0.0
	var source_mode := "controlled" if _has_controlled_source() else "legacy_exclusion"
	var source_copy_ms := 0.0
	var source_copy_frame := -1
	var source_copy_timing_available := false
	var source_copy_timing_valid := false
	var source_copy_timing_marker_scope := ""
	var source_copy_timing_marker_begin := ""
	var source_copy_timing_marker_end := ""
	var source_update_cpu_ms := 0.0
	var source_render_ms := -1.0
	var source_render_frame := -1
	var source_render_timing_available := false
	var source_render_timing_valid := false
	var source_render_timing_scope := "unavailable"
	var source_render_timing_marker_scope := ""
	var source_render_timing_marker_begin := ""
	var source_render_timing_marker_end := ""
	var source_has_renderer_matrices := false
	var source_renderer_matrix_frame := -1
	var source_renderer_matrix_age := -1
	var surface_refraction_timing_available := false
	var surface_refraction_timing_valid := false
	var surface_refraction_frame := -1
	var surface_refraction_timing_debug := {}
	var debug_stats := {}
	if _has_controlled_source():
		var controlled_snapshot: Dictionary = _controlled_source.call("get_runtime_status")
		source_size = controlled_snapshot.get("source_size", Vector2i.ZERO)
		source_valid = bool(controlled_snapshot.get("source_valid", false))
		capture_age = int(controlled_snapshot.get("source_frame_age", -1))
		source_copy_ms = float(controlled_snapshot.get("prewater_copy_ms", 0.0))
		source_copy_frame = int(controlled_snapshot.get("prewater_copy_frame", -1))
		source_copy_timing_available = bool(controlled_snapshot.get("prewater_copy_timing_available", false))
		source_copy_timing_valid = bool(controlled_snapshot.get("prewater_copy_timing_valid", false))
		source_copy_timing_marker_scope = str(controlled_snapshot.get("prewater_copy_timing_marker_scope", ""))
		source_copy_timing_marker_begin = str(controlled_snapshot.get("prewater_copy_timing_marker_begin", ""))
		source_copy_timing_marker_end = str(controlled_snapshot.get("prewater_copy_timing_marker_end", ""))
		source_update_cpu_ms = float(controlled_snapshot.get("source_update_cpu_ms", 0.0))
		source_render_ms = float(controlled_snapshot.get("source_render_ms", -1.0))
		source_render_frame = int(controlled_snapshot.get("source_render_frame", -1))
		source_render_timing_available = bool(controlled_snapshot.get("source_render_timing_available", false))
		source_render_timing_valid = bool(controlled_snapshot.get("source_render_timing_valid", false))
		source_render_timing_scope = str(controlled_snapshot.get("source_render_timing_scope", "unavailable"))
		source_render_timing_marker_scope = str(controlled_snapshot.get("source_render_timing_marker_scope", ""))
		source_render_timing_marker_begin = str(controlled_snapshot.get("source_render_timing_marker_begin", ""))
		source_render_timing_marker_end = str(controlled_snapshot.get("source_render_timing_marker_end", ""))
		source_has_renderer_matrices = bool(controlled_snapshot.get("source_has_renderer_matrices", false))
		source_renderer_matrix_frame = int(controlled_snapshot.get("source_renderer_matrix_frame", -1))
		source_renderer_matrix_age = int(controlled_snapshot.get("source_renderer_matrix_age", -1))
	elif _capture != null:
		source_size = _capture.get_source_size()
		source_valid = _capture.has_capture()
		var frame := _capture.get_capture_process_frame()
		capture_age = Engine.get_process_frames() - frame if frame >= 0 else -1
		var capture_snapshot := _capture.get_perf_snapshot()
		source_copy_ms = float(capture_snapshot.get("prewater_copy_ms", 0.0))
		source_copy_frame = int(capture_snapshot.get("frame", -1))
		source_copy_timing_available = bool(capture_snapshot.get("timing_available", false))
		source_copy_timing_valid = bool(capture_snapshot.get("timing_valid", false))
		source_copy_timing_marker_scope = str(capture_snapshot.get("prewater_copy_timing_marker_scope", ""))
		source_copy_timing_marker_begin = str(capture_snapshot.get("prewater_copy_timing_marker_begin", ""))
		source_copy_timing_marker_end = str(capture_snapshot.get("prewater_copy_timing_marker_end", ""))
		source_render_ms = float(capture_snapshot.get("source_render_ms", -1.0))
		source_render_frame = int(capture_snapshot.get("source_render_frame", -1))
		source_render_timing_available = bool(capture_snapshot.get("source_render_timing_available", false))
		source_render_timing_valid = bool(capture_snapshot.get("source_render_timing_valid", false))
		source_render_timing_scope = str(capture_snapshot.get("source_render_timing_scope", "unavailable"))
		source_render_timing_marker_scope = str(capture_snapshot.get("source_render_timing_marker_scope", ""))
		source_render_timing_marker_begin = str(capture_snapshot.get("source_render_timing_marker_begin", ""))
		source_render_timing_marker_end = str(capture_snapshot.get("source_render_timing_marker_end", ""))
		source_has_renderer_matrices = bool(capture_snapshot.get("capture_has_renderer_matrices", false))
		source_renderer_matrix_frame = int(capture_snapshot.get("capture_renderer_matrix_frame", -1))
		source_renderer_matrix_age = int(capture_snapshot.get("capture_renderer_matrix_age", -1))
	if _effect != null:
		var snapshot := _effect.get_surface_refraction_perf_snapshot()
		surface_refraction_ms = float(snapshot.get("surface_refraction_ms", 0.0))
		surface_refraction_timing_available = bool(snapshot.get("timing_available", false))
		surface_refraction_timing_valid = bool(snapshot.get("timing_valid", false))
		surface_refraction_frame = int(snapshot.get("frame", -1))
		surface_refraction_timing_debug = snapshot.get("timing_debug", {})
		debug_stats = snapshot.get("debug_stats", {})
		source_depth_valid = bool(snapshot.get("source_depth_valid", false))
		source_fresh = bool(snapshot.get("source_fresh", false))
		dispatch_size = snapshot.get("dispatch_size", Vector2i.ZERO)
		mask_mode = str(snapshot.get("mask_mode", "final"))
		reject_reason = str(snapshot.get("reject_reason", "inactive"))
		compositor_enabled = _effect.effect_enabled
	if _overlay != null:
		overlay_active = _overlay.visible
	var copy_surface_timing_available := source_copy_timing_available and surface_refraction_timing_available
	var copy_surface_timing_valid := (
		copy_surface_timing_available
		and source_copy_timing_valid
		and surface_refraction_timing_valid
	)
	var copy_surface_ms := source_copy_ms + surface_refraction_ms if copy_surface_timing_valid else -1.0
	var same_timing_frame := (
		source_render_frame >= 0
		and source_copy_frame >= 0
		and surface_refraction_frame >= 0
		and source_render_frame == source_copy_frame
		and source_copy_frame == surface_refraction_frame
	)
	var total_timing_available := (
		source_render_timing_available
		and source_copy_timing_available
		and surface_refraction_timing_available
	)
	var total_timing_valid := (
		total_timing_available
		and source_render_timing_valid
		and copy_surface_timing_valid
		and same_timing_frame
	)
	var total_refraction_ms := source_render_ms + copy_surface_ms if total_timing_valid else -1.0
	var total_unavailable_reason := "available"
	if not source_render_timing_available:
		total_unavailable_reason = "source_render_timing_unavailable"
	elif not source_render_timing_valid:
		total_unavailable_reason = "source_render_timing_invalid"
	elif not source_copy_timing_available:
		total_unavailable_reason = "source_copy_timing_unavailable"
	elif not source_copy_timing_valid:
		total_unavailable_reason = "source_copy_timing_invalid"
	elif not surface_refraction_timing_available:
		total_unavailable_reason = "surface_refraction_timing_unavailable"
	elif not surface_refraction_timing_valid:
		total_unavailable_reason = "surface_refraction_timing_invalid"
	elif not same_timing_frame:
		total_unavailable_reason = "timing_frame_mismatch"
	return {
		"enabled": _enabled,
		"source_valid": source_valid,
		"source_depth_valid": source_depth_valid,
		"source_fresh": source_fresh,
		"source_size": source_size,
		"source_mode": source_mode,
		"source_resolution_scale": source_resolution_scale,
		"capture_frame_age": capture_age,
		"source_has_renderer_matrices": source_has_renderer_matrices,
		"source_renderer_matrix_frame": source_renderer_matrix_frame,
		"source_renderer_matrix_age": source_renderer_matrix_age,
		"source_frame_tolerance": source_frame_tolerance,
		"refraction_strength": refraction_strength,
		"edge_guard_strength": edge_guard_strength,
		"mesh_mode": _mesh_mode,
		"compositor_enabled": compositor_enabled,
		"overlay_active": overlay_active,
		"dispatch_size": dispatch_size,
		"surface_refraction_ms": surface_refraction_ms,
		"surface_refraction_frame": surface_refraction_frame,
		"surface_refraction_timing_available": surface_refraction_timing_available,
		"surface_refraction_timing_valid": surface_refraction_timing_valid,
		"surface_refraction_timing_debug": surface_refraction_timing_debug,
		"surface_refraction_debug_stats": debug_stats,
		"controlled_source_render_ms": source_render_ms,
		"controlled_source_render_frame": source_render_frame,
		"controlled_source_render_timing_available": source_render_timing_available,
		"controlled_source_render_timing_valid": source_render_timing_valid,
		"controlled_source_render_timing_scope": source_render_timing_scope,
		"controlled_source_render_timing_marker_scope": source_render_timing_marker_scope,
		"controlled_source_render_timing_marker_begin": source_render_timing_marker_begin,
		"controlled_source_render_timing_marker_end": source_render_timing_marker_end,
		"controlled_source_copy_ms": source_copy_ms,
		"controlled_source_copy_frame": source_copy_frame,
		"controlled_source_copy_timing_available": source_copy_timing_available,
		"controlled_source_copy_timing_valid": source_copy_timing_valid,
		"controlled_source_copy_timing_marker_scope": source_copy_timing_marker_scope,
		"controlled_source_copy_timing_marker_begin": source_copy_timing_marker_begin,
		"controlled_source_copy_timing_marker_end": source_copy_timing_marker_end,
		"controlled_source_update_cpu_ms": source_update_cpu_ms,
		"controlled_copy_surface_ms": copy_surface_ms,
		"controlled_copy_surface_timing_available": copy_surface_timing_available,
		"controlled_copy_surface_timing_valid": copy_surface_timing_valid,
		"controlled_total_refraction_ms": total_refraction_ms,
		"controlled_total_refraction_timing_available": total_timing_available,
		"controlled_total_refraction_timing_valid": total_timing_valid,
		"controlled_total_refraction_unavailable_reason": total_unavailable_reason,
		"controlled_total_same_timing_frame": same_timing_frame,
		"mask_mode": mask_mode,
		"reject_reason": reject_reason,
		"debug_mode": get_debug_mode(),
	}


func _ensure_nodes() -> void:
	if _capture == null:
		_capture = PrewaterCaptureRendererScript.new()
		_capture.name = "SurfaceRefractionSourceCapture"
		_capture.occlusion_capture_enabled = false
		add_child(_capture)
	if _overlay == null:
		_overlay = MeshInstance3D.new()
		_overlay.name = "SurfaceRefractionDiagnosticOverlay"
		_overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_overlay)
	_apply_enabled_state()


func _ensure_effect() -> void:
	if _effect == null:
		_effect = SurfaceRefractionCompositorScript.new()
		_effect.effect_enabled = false
		_effect.blend_factor = 0.0
		_effect.source_frame_tolerance = source_frame_tolerance
		_effect.diagnostic_stats_enabled = diagnostic_stats_enabled
		_effect.on_effect_added()
	_ensure_attached()


func _ensure_attached() -> void:
	if _world_environment == null or _effect == null:
		return
	if (
		_attached_world_environment != _world_environment
		or (_attached_compositor != null and _attached_compositor != _world_environment.compositor)
	):
		_detach_effect()

	var compositor := _world_environment.compositor
	var created := false
	if compositor == null:
		compositor = Compositor.new()
		_world_environment.compositor = compositor
		created = true

	var effects := compositor.compositor_effects
	if not effects.has(_effect):
		effects.append(_effect)
		compositor.compositor_effects = effects

	_attached_world_environment = _world_environment
	_attached_compositor = compositor
	_created_attached_compositor = created


func _detach_effect() -> void:
	if _attached_compositor != null and _effect != null:
		var effects := _attached_compositor.compositor_effects
		if effects.has(_effect):
			effects.erase(_effect)
			_attached_compositor.compositor_effects = effects
		if (
			_created_attached_compositor
			and effects.is_empty()
			and _attached_world_environment != null
			and _attached_world_environment.compositor == _attached_compositor
		):
			_attached_world_environment.compositor = null
	_attached_world_environment = null
	_attached_compositor = null
	_created_attached_compositor = false


func _ensure_material() -> void:
	if _ocean_mesh == null:
		return
	var next_mode := int(_ocean_mesh.get_mesh_mode())
	if _material != null and _mesh_mode == next_mode:
		return

	var shader_path := PROJECTED_SHADER_PATH if next_mode == OceanMesh.MeshMode.PROJECTED else CLIPMAP_SHADER_PATH
	var shader := load(shader_path) as Shader
	if shader == null:
		push_error("[SurfaceRefractionLayer] Failed to load shader: %s" % shader_path)
		return
	_material = ShaderMaterial.new()
	_material.shader = shader
	_mesh_mode = next_mode
	if _overlay != null:
		_overlay.material_override = _material


func _apply_enabled_state() -> void:
	var active := (
		_enabled
		and _camera != null
		and _ocean_mesh != null
		and _effect != null
	)
	if _effect != null:
		_effect.effect_enabled = active
		_effect.blend_factor = 1.0 if active else 0.0
		_effect.refraction_strength = refraction_strength if active else 0.0
		_effect.edge_guard_strength = edge_guard_strength
	if _overlay != null:
		_overlay.visible = active and diagnostic_overlay_enabled and _material != null
	if _capture != null and not active:
		_capture.set_capture_enabled(false)
		_capture.set_blend_factor(0.0)
	if _has_controlled_source():
		_controlled_source.call("set_enabled", active)
	if _effect != null and not active:
		_effect.clear_external_source_buffers()
	if _material != null and (not active or not diagnostic_overlay_enabled):
		_material.set_shader_parameter("source_valid", 0.0)


func _push_capture_to_effect() -> void:
	if _effect == null or _capture == null:
		return
	if _has_controlled_source():
		if not bool(_controlled_source.call("push_to_surface_refraction_effect", _effect)):
			_effect.clear_external_source_buffers()
		return
	if not _capture.has_capture():
		_effect.clear_external_source_buffers()
		return
	if _capture.has_capture_renderer_matrices():
		_effect.set_source_camera_matrices(
			_capture.get_capture_renderer_projection(),
			_capture.get_capture_renderer_camera_transform()
		)
	else:
		_effect.clear_source_camera_matrices()
	_effect.set_external_source_buffers(
		_capture.get_source_color_rid(),
		_capture.get_source_depth_rid(),
		_capture.get_source_size(),
		_capture.get_capture_process_frame()
	)


func _has_controlled_source() -> bool:
	return _controlled_source != null and is_instance_valid(_controlled_source)


func _sync_effect_from_water_state() -> void:
	if _effect == null:
		return
	var ocean_manager := get_node_or_null("/root/WaterSystem")
	if ocean_manager != null and ocean_manager.has_method("get_water_surface_state"):
		var state := ocean_manager.call("get_water_surface_state") as WaterSurfaceState
		if state != null:
			_effect.sync_from_water_state(state)


func _push_capture_to_overlay() -> void:
	if _material == null or _capture == null:
		return
	var source_texture := _capture.get_source_texture()
	_material.set_shader_parameter("source_color_texture", source_texture)
	_material.set_shader_parameter("source_valid", 1.0 if _capture.has_capture() and source_texture != null else 0.0)
	_material.set_shader_parameter("source_resolution_scale", source_resolution_scale)
	_material.set_shader_parameter("refraction_strength", refraction_strength)
	_material.set_shader_parameter("edge_guard_strength", edge_guard_strength)
	_material.set_shader_parameter("overlay_opacity", overlay_opacity)


func _sync_overlay_from_ocean() -> void:
	if _overlay == null or _ocean_mesh == null:
		return
	_overlay.mesh = _ocean_mesh.mesh
	_overlay.global_transform = _ocean_mesh.global_transform
	_overlay.layers = _ocean_mesh.layers
	_overlay.extra_cull_margin = _ocean_mesh.extra_cull_margin


func _sync_material_from_ocean() -> void:
	if _material == null or _ocean_mesh == null:
		return
	var ocean_mat := _ocean_mesh.get_material()
	if ocean_mat == null:
		return
	for param_name in [
		"map_scales",
		"shore_mask",
		"shore_mask_bounds",
		"shore_fade_distance",
		"sea_level",
		"wave_scale",
		"shore_wave_amplitude",
		"shore_wave_frequency",
		"shore_wave_speed",
		"shore_wave_steepness",
		"ocean_time",
		"max_refr_thickness",
		"medium_color",
		"extinction_sigma",
	]:
		var value: Variant = ocean_mat.get_shader_parameter(param_name)
		if value != null:
			_material.set_shader_parameter(param_name, value)


func _get_ocean_sea_level() -> float:
	if _ocean_mesh == null:
		return 0.0
	var ocean_mat := _ocean_mesh.get_material()
	if ocean_mat == null:
		return 0.0
	var value: Variant = ocean_mat.get_shader_parameter("sea_level")
	return float(value) if value != null else 0.0


func _safe_viewport_size(size: Vector2i) -> Vector2i:
	if size.x > 0 and size.y > 0:
		return size
	var viewport := get_viewport()
	if viewport != null:
		var rect_size := viewport.get_visible_rect().size
		if rect_size.x > 0.0 and rect_size.y > 0.0:
			return Vector2i(int(rect_size.x), int(rect_size.y))
	return PrewaterCaptureRenderer.DEFAULT_FALLBACK_SIZE
