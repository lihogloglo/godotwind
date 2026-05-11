## WaterlineStack
##
## Production wrapper for the receiver-only waterline compositor path. It keeps
## the pre-water capture viewport, active WorldEnvironment compositor, camera
## receiver-layer contract, and OceanManager WaterSurfaceState in sync.
class_name WaterlineStack
extends Node

const PrewaterCaptureRendererScript := preload("res://src/core/water/prewater_capture_renderer.gd")
const WaterlineCompositorScript := preload("res://src/core/shaders/effects/waterline_compositor_effect.gd")

const DEFAULT_RECEIVER_LAYER_MASK: int = 1 << 18
const DEFAULT_NEAR_WATER_FADE_START_M: float = 80.0
const DEFAULT_NEAR_WATER_CAPTURE_DISTANCE_M: float = 140.0

const QUALITY_LOW: int = 0
const QUALITY_MEDIUM: int = 1
const QUALITY_HIGH: int = 2

@export var receiver_layer_mask: int = DEFAULT_RECEIVER_LAYER_MASK
@export var enabled: bool = false:
	set(value):
		set_enabled(value)
	get:
		return _enabled

@export var quality_tier: int = QUALITY_MEDIUM:
	set(value):
		_quality_tier = clampi(value, QUALITY_LOW, QUALITY_HIGH)
		if _prewater_capture != null:
			_prewater_capture.set_resolution_scale(_get_resolution_scale())
		if _waterline_effect != null and _waterline_effect.has_method("set_quality_tier"):
			_waterline_effect.call("set_quality_tier", _quality_tier)
	get:
		return _quality_tier

var _camera: Camera3D = null
var _world_environment: WorldEnvironment = null
var _ocean_manager: Node = null
var _sun: DirectionalLight3D = null
var _enabled: bool = false
var _quality_tier: int = QUALITY_MEDIUM
var _prewater_capture: PrewaterCaptureRenderer = null
var _waterline_effect: WaterlineCompositorEffect = null
var _attached_world_environment: WorldEnvironment = null
var _attached_compositor: Compositor = null
var _created_attached_compositor: bool = false
var _camera_receiver_bit_was_enabled: Dictionary = {}


func _ready() -> void:
	_ensure_effects()


func _exit_tree() -> void:
	set_enabled(false)
	_restore_all_camera_receiver_bits()
	_detach_effect()
	if _waterline_effect != null:
		_waterline_effect.on_effect_removed()
	_waterline_effect = null
	_prewater_capture = null


func configure(
		camera: Camera3D,
		world_environment: WorldEnvironment,
		ocean_manager: Node,
		p_receiver_layer_mask: int = DEFAULT_RECEIVER_LAYER_MASK,
		p_quality_tier: int = QUALITY_MEDIUM,
		sun: DirectionalLight3D = null
) -> void:
	receiver_layer_mask = p_receiver_layer_mask
	_ocean_manager = ocean_manager
	quality_tier = p_quality_tier
	set_camera(camera)
	set_world_environment(world_environment)
	set_sun(sun)


func set_enabled(value: bool) -> void:
	if _enabled == value:
		return
	_enabled = value
	if not _enabled:
		_restore_all_camera_receiver_bits()
		_set_effect_active(false, 0.0)
		if _prewater_capture != null:
			_prewater_capture.set_capture_enabled(false)
			_prewater_capture.set_blend_factor(0.0)
		return
	_ensure_effects()
	_ensure_attached()


func set_camera(camera: Camera3D) -> void:
	if _camera == camera:
		return
	_restore_camera_receiver_bit(_camera)
	_camera = camera
	if _prewater_capture != null:
		_prewater_capture.configure(_camera, _get_environment(), receiver_layer_mask)


func set_world_environment(world_environment: WorldEnvironment) -> void:
	if _world_environment == world_environment:
		return
	_world_environment = world_environment
	_ensure_attached()
	if _prewater_capture != null:
		_prewater_capture.configure(_camera, _get_environment(), receiver_layer_mask)


func set_ocean_manager(ocean_manager: Node) -> void:
	_ocean_manager = ocean_manager


func set_sun(sun: DirectionalLight3D) -> void:
	_sun = sun


func process_stack(_delta: float, main_viewport_size: Vector2i = Vector2i.ZERO) -> void:
	if not _enabled:
		return
	_ensure_effects()
	_ensure_attached()
	_apply_receiver_layer_contract()

	var state: WaterSurfaceState = _get_water_state()
	var active_water: bool = (
		state != null
		and state.water_body_id != WaterSurfaceState.WATER_BODY_NONE
		and state.coverage_available
	)
	var sea_level: float = state.sea_level if state != null else ProjectSettings.get_setting("ocean/sea_level", 0.0)

	_prewater_capture.configure(_camera, _get_environment(), receiver_layer_mask)
	_prewater_capture.near_water_capture_fade_start_m = DEFAULT_NEAR_WATER_FADE_START_M
	_prewater_capture.near_water_capture_distance_m = DEFAULT_NEAR_WATER_CAPTURE_DISTANCE_M
	_prewater_capture.set_capture_enabled(active_water)
	_prewater_capture.set_blend_factor(1.0 if active_water else 0.0)
	_prewater_capture.set_resolution_scale(_get_resolution_scale())
	_prewater_capture.set_activation_water_level(sea_level)
	_prewater_capture.update_capture(_get_safe_viewport_size(main_viewport_size))

	var activation_fade := _prewater_capture.get_activation_fade()
	var effect_active := active_water and activation_fade > 0.001
	_set_effect_active(effect_active, activation_fade if effect_active else 0.0)
	if _waterline_effect.has_method("set_activation_water_level"):
		_waterline_effect.call("set_activation_water_level", sea_level)
	if _waterline_effect.has_method("set_near_water_fade_start_distance"):
		_waterline_effect.call("set_near_water_fade_start_distance", DEFAULT_NEAR_WATER_FADE_START_M)
	if _waterline_effect.has_method("set_near_water_activation_distance"):
		_waterline_effect.call("set_near_water_activation_distance", DEFAULT_NEAR_WATER_CAPTURE_DISTANCE_M)
	if _waterline_effect.has_method("set_quality_tier"):
		_waterline_effect.call("set_quality_tier", _quality_tier)
	if _waterline_effect.has_method("set_receiver_source_mode"):
		_waterline_effect.call("set_receiver_source_mode", 1)
	_sync_sun()

	if effect_active:
		if state != null:
			_waterline_effect.sync_from_water_state(state)
		_prewater_capture.push_to_waterline_effect(_waterline_effect)
	elif _waterline_effect.has_method("clear_external_source_buffers"):
		_waterline_effect.call("clear_external_source_buffers")


func get_waterline_effect() -> WaterlineCompositorEffect:
	return _waterline_effect


func get_prewater_capture() -> PrewaterCaptureRenderer:
	return _prewater_capture


func _ensure_effects() -> void:
	if _waterline_effect == null:
		_waterline_effect = WaterlineCompositorScript.new()
		_waterline_effect.effect_enabled = false
		_waterline_effect.blend_factor = 0.0
		_waterline_effect.on_effect_added()
		if _waterline_effect.has_method("set_quality_tier"):
			_waterline_effect.call("set_quality_tier", _quality_tier)
		if _waterline_effect.has_method("set_receiver_source_mode"):
			_waterline_effect.call("set_receiver_source_mode", 1)

	if _prewater_capture == null:
		_prewater_capture = PrewaterCaptureRendererScript.new()
		_prewater_capture.name = "WaterlinePrewaterCapture"
		_prewater_capture.near_water_capture_fade_start_m = DEFAULT_NEAR_WATER_FADE_START_M
		_prewater_capture.near_water_capture_distance_m = DEFAULT_NEAR_WATER_CAPTURE_DISTANCE_M
		_prewater_capture.configure(_camera, _get_environment(), receiver_layer_mask)
		_prewater_capture.set_resolution_scale(_get_resolution_scale())
		add_child(_prewater_capture)


func _ensure_attached() -> void:
	if _world_environment == null or _waterline_effect == null:
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
	if not effects.has(_waterline_effect):
		effects.append(_waterline_effect)
		compositor.compositor_effects = effects

	_attached_world_environment = _world_environment
	_attached_compositor = compositor
	_created_attached_compositor = created


func _detach_effect() -> void:
	if _attached_compositor != null and _waterline_effect != null:
		var effects := _attached_compositor.compositor_effects
		if effects.has(_waterline_effect):
			effects.erase(_waterline_effect)
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


func _set_effect_active(active: bool, blend_factor: float) -> void:
	if _waterline_effect == null:
		return
	_waterline_effect.effect_enabled = active
	_waterline_effect.blend_factor = clampf(blend_factor, 0.0, 1.0) if active else 0.0


func _get_water_state() -> WaterSurfaceState:
	if _ocean_manager == null or not is_instance_valid(_ocean_manager):
		return null
	if not _ocean_manager.has_method("get_water_surface_state"):
		return null
	var result: Variant = _ocean_manager.call("get_water_surface_state")
	if result is WaterSurfaceState:
		return result
	return null


func _get_environment() -> Environment:
	if _world_environment != null and is_instance_valid(_world_environment):
		return _world_environment.environment
	return null


func _get_resolution_scale() -> float:
	match _quality_tier:
		QUALITY_HIGH:
			return 0.75
		QUALITY_MEDIUM:
			return 0.5
		_:
			return 0.25


func _get_safe_viewport_size(size: Vector2i) -> Vector2i:
	if size.x > 0 and size.y > 0:
		return size
	var viewport := get_viewport()
	if viewport != null:
		var viewport_size := viewport.get_visible_rect().size
		if viewport_size.x > 0.0 and viewport_size.y > 0.0:
			return Vector2i(int(viewport_size.x), int(viewport_size.y))
	return PrewaterCaptureRenderer.DEFAULT_FALLBACK_SIZE


func _sync_sun() -> void:
	if _waterline_effect == null or _sun == null or not is_instance_valid(_sun):
		return
	if _waterline_effect.has_method("set_sun_direction"):
		_waterline_effect.call("set_sun_direction", _sun.global_basis.z)
	if _waterline_effect.has_method("set_sun_visibility"):
		_waterline_effect.call("set_sun_visibility", clampf(_sun.light_energy / 1.4, 0.0, 1.0))


func _apply_receiver_layer_contract() -> void:
	if _camera == null or not is_instance_valid(_camera):
		return
	var id := _camera.get_instance_id()
	if not _camera_receiver_bit_was_enabled.has(id):
		_camera_receiver_bit_was_enabled[id] = (_camera.cull_mask & receiver_layer_mask) != 0
	_camera.cull_mask = _camera.cull_mask | receiver_layer_mask


func _restore_all_camera_receiver_bits() -> void:
	for id_variant: Variant in _camera_receiver_bit_was_enabled.keys():
		var id := int(id_variant)
		var obj := instance_from_id(id)
		if obj is Camera3D:
			_restore_camera_receiver_bit(obj as Camera3D)
	_camera_receiver_bit_was_enabled.clear()


func _restore_camera_receiver_bit(camera: Camera3D) -> void:
	if camera == null or not is_instance_valid(camera):
		return
	var id := camera.get_instance_id()
	if not _camera_receiver_bit_was_enabled.has(id):
		return
	if bool(_camera_receiver_bit_was_enabled[id]):
		camera.cull_mask = camera.cull_mask | receiver_layer_mask
	else:
		camera.cull_mask = camera.cull_mask & ~receiver_layer_mask
	_camera_receiver_bit_was_enabled.erase(id)
