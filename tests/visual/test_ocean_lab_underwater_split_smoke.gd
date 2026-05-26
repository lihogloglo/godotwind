extends "res://tests/visual/test_ocean_lab.gd"

## Smoke for mixed above/underwater views.
## Keeps the camera above the sampled FFT surface with underwater debug off.
## The compositor must still dispatch so below-surface pixels receive medium.

var _smoke_frames: int = 0
var _finishing: bool = false


func _ready() -> void:
	super._ready()
	_underwater_effect_enabled = true
	_underwater_debug_mode = 0
	_uw_absorption_enabled = true
	_uw_wobble_effect_enabled = false
	_uw_snell_enabled = false
	_uw_caustics_enabled = false
	_push_underwater_effect_controls()
	_place_camera_above_waterline()
	_refresh_control_labels()
	print("[Ocean Lab Underwater Split Smoke] Ready")


func _process(delta: float) -> void:
	if _finishing:
		return
	super._process(delta)
	_smoke_frames += 1
	if _smoke_frames < 30:
		return
	if not _assert_split_dispatch():
		return
	print("[Ocean Lab Underwater Split Smoke] passed")
	_finish_smoke(0)


func _assert_split_dispatch() -> bool:
	if _camera == null:
		return _fail("camera missing")
	var state := _get_water_state()
	if state == null or not state.can_sample_height():
		return _fail("WaterSurfaceState height query was not ready")
	var camera_water_y := state.sample_height(_camera.global_position, _sea_level)
	if _camera.global_position.y <= camera_water_y + 0.10:
		return _fail("camera was not above the dynamic water surface")
	if _underwater_effect == null or not _underwater_effect.effect_enabled:
		return _fail("underwater compositor was not enabled")
	var perf := _get_underwater_perf_snapshot()
	if int(perf.get("frame", -1)) < 0:
		return _fail("underwater compositor did not dispatch for above-water split view")
	if not perf.has("total_ms"):
		return _fail("underwater compositor did not publish timing data")
	return true


func _place_camera_above_waterline() -> void:
	if _camera == null:
		return
	var target := _playground_origin
	var sample_pos := target + Vector3(0.0, 0.0, 18.0)
	var water_y := _sea_level
	var state := _get_water_state()
	if state != null and state.can_sample_height():
		water_y = state.sample_height(sample_pos, _sea_level)
	_camera.global_position = Vector3(sample_pos.x, water_y + 0.45, sample_pos.z)
	_camera.look_at(Vector3(target.x, water_y - 1.25, target.z), Vector3.UP)


func _fail(message: String) -> bool:
	push_error("[Ocean Lab Underwater Split Smoke] %s" % message)
	_finish_smoke(1)
	return false


func _finish_smoke(exit_code: int) -> void:
	_finishing = true
	_underwater_effect_enabled = false
	_push_underwater_effect_controls()
	if _underwater_effect != null:
		_underwater_effect.effect_enabled = false
		_underwater_effect.blend_factor = 0.0
	if _waterline_stack != null:
		_waterline_stack.set_enabled(false)
	if _water_compositor != null:
		_water_compositor.compositor_effects = []
	if _world_env != null:
		_world_env.compositor = null
	await get_tree().process_frame
	await get_tree().process_frame
	if _underwater_effect != null:
		_underwater_effect.on_effect_removed()
		_underwater_effect = null
	if _waterline_stack != null:
		_waterline_stack.shutdown()
		_waterline_stack.queue_free()
		_waterline_stack = null
	if _wet_effect != null:
		_wet_effect.effect_enabled = false
		_wet_effect.blend_factor = 0.0
		_wet_effect.on_effect_removed()
		_wet_effect = null
	var ocean_manager := get_node_or_null("/root/OceanManager")
	if ocean_manager != null and ocean_manager.has_method("release_runtime_resources"):
		ocean_manager.call("release_runtime_resources")
	_shutdown_shader_manager_effects()
	for _i in range(6):
		await get_tree().process_frame
	get_tree().quit(exit_code)


func _shutdown_shader_manager_effects() -> void:
	var shader_manager := get_node_or_null("/root/ShaderManager")
	if shader_manager != null and shader_manager.has_method("shutdown"):
		shader_manager.call("shutdown")
