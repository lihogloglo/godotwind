extends "res://tests/visual/test_ocean_lab.gd"

## Crash smoke for Ocean Lab optics debug paths.
## Inherits the interactive lab, toggles surface SSR and the separate surface
## refraction layer, then forces the camera underwater so the post-transparent medium pass
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
	if _surface_refraction_layer != null and bool(_surface_refraction_layer.call("is_enabled")):
		push_error("[Ocean Optics Smoke] surface refraction layer did not toggle off")
		get_tree().quit(1)
		return

	_surface_refraction_enabled = true
	_push_surface_refraction_control()
	await _wait_frames(8)
	if _surface_refraction_layer == null or not bool(_surface_refraction_layer.call("is_enabled")):
		push_error("[Ocean Optics Smoke] surface refraction layer did not toggle on")
		get_tree().quit(1)
		return
	var surface_snapshot := _assert_surface_refraction_ready("clipmap")
	if surface_snapshot.is_empty():
		return
	for expected_mode in [OceanMesh.MeshMode.PROJECTED, OceanMesh.MeshMode.CLIPMAP]:
		if OceanManager.get_mesh_mode() != expected_mode:
			_toggle_mesh_mode()
			await _wait_frames(12)
		surface_snapshot = _assert_surface_refraction_ready("projected" if expected_mode == OceanMesh.MeshMode.PROJECTED else "clipmap")
		if surface_snapshot.is_empty():
			return
		if int(surface_snapshot.get("mesh_mode", -1)) != int(expected_mode):
			push_error("[Ocean Optics Smoke] surface refraction mesh mode status mismatch")
			get_tree().quit(1)
			return
	for mode in [1, 2, 3, 4]:
		_surface_refraction_layer.call("set_debug_mode", mode)
		await _wait_frames(2)
		surface_snapshot = _surface_refraction_layer.call("get_runtime_status")
		if int(surface_snapshot.get("debug_mode", -1)) != mode:
			push_error("[Ocean Optics Smoke] surface refraction debug mode did not apply")
			get_tree().quit(1)
			return
		if str(surface_snapshot.get("mask_mode", "")).is_empty():
			push_error("[Ocean Optics Smoke] surface refraction mask mode did not report")
			get_tree().quit(1)
			return
	_surface_refraction_layer.call("set_debug_mode", 0)
	_surface_edge_guard_enabled = true
	_push_surface_refraction_control()
	if float(_surface_refraction_layer.get("edge_guard_strength")) < 0.999:
		push_error("[Ocean Optics Smoke] refraction edge guard did not toggle on")
		get_tree().quit(1)
		return
	_surface_edge_guard_enabled = false
	_push_surface_refraction_control()
	if float(_surface_refraction_layer.get("edge_guard_strength")) > 0.001:
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


func _assert_surface_refraction_ready(label: String) -> Dictionary:
	if _surface_refraction_layer == null:
		push_error("[Ocean Optics Smoke] surface refraction layer missing during %s check" % label)
		get_tree().quit(1)
		return {}
	var snapshot: Dictionary = _surface_refraction_layer.call("get_runtime_status")
	if not bool(snapshot.get("source_valid", false)):
		push_error("[Ocean Optics Smoke] surface refraction source capture was not valid in %s mode" % label)
		get_tree().quit(1)
		return {}
	if not bool(snapshot.get("source_depth_valid", false)):
		push_error("[Ocean Optics Smoke] surface refraction source depth was not valid in %s mode" % label)
		get_tree().quit(1)
		return {}
	if int(snapshot.get("capture_frame_age", 99)) > 1:
		push_error("[Ocean Optics Smoke] surface refraction source was stale in %s mode" % label)
		get_tree().quit(1)
		return {}
	if not bool(snapshot.get("source_fresh", false)):
		push_error("[Ocean Optics Smoke] surface refraction compositor did not receive a fresh source in %s mode" % label)
		get_tree().quit(1)
		return {}
	if not bool(snapshot.get("compositor_enabled", false)):
		push_error("[Ocean Optics Smoke] surface refraction compositor was not enabled in %s mode" % label)
		get_tree().quit(1)
		return {}
	if bool(snapshot.get("overlay_active", false)):
		push_error("[Ocean Optics Smoke] diagnostic overlay was active in production mode during %s check" % label)
		get_tree().quit(1)
		return {}
	if snapshot.get("dispatch_size", Vector2i.ZERO) == Vector2i.ZERO:
		push_error("[Ocean Optics Smoke] surface refraction compositor did not dispatch in %s mode" % label)
		get_tree().quit(1)
		return {}
	return snapshot
