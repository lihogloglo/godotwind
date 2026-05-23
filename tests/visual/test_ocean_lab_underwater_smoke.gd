extends "res://tests/visual/test_ocean_lab.gd"

## Crash smoke for the active underwater medium compositor.
## Inherits the interactive lab, enables the underwater pass, places the camera
## below the sampled water surface, waits for a few compositor dispatches, then
## quits without screenshots or automated capture.

var _smoke_frames: int = 0
var _finishing: bool = false


func _ready() -> void:
	super._ready()
	_underwater_effect_enabled = true
	_uw_wobble_effect_enabled = true
	_underwater_debug_mode = 3
	_push_underwater_effect_controls()
	_place_camera_underwater()
	_refresh_control_labels()
	print("[Ocean Lab Underwater Smoke] Ready")


func _process(delta: float) -> void:
	if _finishing:
		return
	super._process(delta)
	_smoke_frames += 1
	if _smoke_frames < 12:
		return
	var perf := _get_underwater_perf_snapshot()
	print("[Ocean Lab Underwater Smoke] underwater perf=%s" % str(perf))
	_finish_smoke(0)


func _finish_smoke(exit_code: int) -> void:
	_finishing = true
	_underwater_effect_enabled = false
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
	if OceanManager != null and OceanManager.has_method("release_runtime_resources"):
		OceanManager.release_runtime_resources()
	_shutdown_shader_manager_effects()
	for i in range(6):
		await get_tree().process_frame
	get_tree().quit(exit_code)


func _shutdown_shader_manager_effects() -> void:
	var shader_manager := get_node_or_null("/root/ShaderManager")
	if shader_manager != null and shader_manager.has_method("shutdown"):
		shader_manager.call("shutdown")


func _place_camera_underwater() -> void:
	if _camera == null:
		return
	var target := _playground_origin
	var sample_pos := target + Vector3(0.0, 0.0, 18.0)
	var water_y := _sea_level
	var state := _get_water_state()
	if state != null and state.can_sample_height():
		water_y = state.sample_height(sample_pos, _sea_level)
	_camera.global_position = Vector3(sample_pos.x, water_y - 2.0, sample_pos.z)
	_camera.look_at(Vector3(target.x, water_y - 2.0, target.z), Vector3.UP)
