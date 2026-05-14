extends "res://tests/visual/test_ocean_lab.gd"

## Crash smoke for Ocean Lab optics debug paths.
## Inherits the interactive lab, toggles the surface SSR/refraction uniforms,
## then forces the camera underwater so the post-transparent medium pass
## dispatches its wobble source-delta and guard debug modes. No screenshots.


func _ready() -> void:
	super._ready()
	if OceanManager == null:
		push_error("[Ocean Optics Smoke] OceanManager missing")
		get_tree().quit(1)
		return

	var mat := _get_ocean_material()
	if mat == null:
		push_error("[Ocean Optics Smoke] Ocean material missing")
		get_tree().quit(1)
		return

	_surface_ssr_enabled = true
	_push_surface_ssr_control()
	if not bool(mat.get_shader_parameter("ssr_enabled")):
		push_error("[Ocean Optics Smoke] ssr_enabled did not reach ocean material")
		get_tree().quit(1)
		return

	_surface_ssr_enabled = false
	_push_surface_ssr_control()
	if bool(mat.get_shader_parameter("ssr_enabled")):
		push_error("[Ocean Optics Smoke] ssr_enabled did not toggle off")
		get_tree().quit(1)
		return

	_surface_ssr_enabled = true
	_push_surface_ssr_control()
	_surface_refraction_enabled = false
	_push_surface_refraction_control()
	if float(mat.get_shader_parameter("refraction_strength")) > 0.001:
		push_error("[Ocean Optics Smoke] refraction_strength did not toggle off")
		get_tree().quit(1)
		return

	_surface_refraction_enabled = true
	_push_surface_refraction_control()
	if float(mat.get_shader_parameter("refraction_strength")) < 0.001:
		push_error("[Ocean Optics Smoke] refraction_strength did not toggle on")
		get_tree().quit(1)
		return
	_surface_edge_guard_enabled = true
	_push_surface_refraction_control()
	if float(mat.get_shader_parameter("refraction_edge_guard_strength")) < 0.999:
		push_error("[Ocean Optics Smoke] refraction edge guard did not toggle on")
		get_tree().quit(1)
		return
	_surface_edge_guard_enabled = false
	_push_surface_refraction_control()
	if float(mat.get_shader_parameter("refraction_edge_guard_strength")) > 0.001:
		push_error("[Ocean Optics Smoke] refraction edge guard did not toggle off")
		get_tree().quit(1)
		return

	_toggle_environment_ssr()
	if _world_env == null or _world_env.environment == null or _world_env.environment.ssr_enabled:
		push_error("[Ocean Optics Smoke] environment SSR did not toggle off")
		get_tree().quit(1)
		return
	_toggle_environment_ssr()
	if _world_env == null or _world_env.environment == null or not _world_env.environment.ssr_enabled:
		push_error("[Ocean Optics Smoke] environment SSR did not toggle on")
		get_tree().quit(1)
		return

	_debug_mode = 8
	OceanManager.set_debug_mode(_debug_mode)
	await _wait_frames(4)

	for mode in [13, 14, 15, 16, 17, 18]:
		_debug_mode = mode
		OceanManager.set_debug_mode(_debug_mode)
		await _wait_frames(2)

	if _camera != null:
		_camera.global_position = _playground_origin + Vector3(0.0, -2.0, 8.0)
		_camera.look_at(_playground_origin + Vector3(0.0, -4.0, 0.0), Vector3.UP)

	_underwater_debug_mode = 4
	if _underwater_effect != null and _underwater_effect.has_method("set_debug_mode"):
		_underwater_effect.call("set_debug_mode", _underwater_debug_mode)
	await _wait_frames(12)

	var delta_perf := _get_underwater_perf_snapshot()
	if not bool(delta_perf.get("scene_copy_active", false)):
		push_error("[Ocean Optics Smoke] wobble delta debug did not activate source copy")
		get_tree().quit(1)
		return

	_underwater_debug_mode = 5
	if _underwater_effect != null and _underwater_effect.has_method("set_debug_mode"):
		_underwater_effect.call("set_debug_mode", _underwater_debug_mode)
	await _wait_frames(8)

	var guard_perf := _get_underwater_perf_snapshot()
	if not bool(guard_perf.get("scene_copy_active", false)):
		push_error("[Ocean Optics Smoke] wobble guard debug did not keep source copy active")
		get_tree().quit(1)
		return

	print("[Ocean Optics Smoke] surface toggles + underwater wobble debug dispatch passed")
	get_tree().quit(0)


func _wait_frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame
