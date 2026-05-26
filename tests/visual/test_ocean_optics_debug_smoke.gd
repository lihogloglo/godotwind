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
	if _surface_refraction_layer != null:
		_surface_refraction_layer.set("diagnostic_stats_enabled", true)
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
	var surface_debug_stats: Dictionary = surface_snapshot.get("surface_refraction_debug_stats", {})
	if not _assert_surface_refraction_accepts_pixels(surface_debug_stats):
		return
	if not _assert_source_candidate_projection_matches(surface_debug_stats, "normal"):
		return
	var zero_travel_debug_stats: Dictionary = {}
	if _surface_refraction_layer != null:
		_surface_refraction_layer.set("diagnostic_stats_enabled", false)
	await _wait_frames(4)
	var surface_report_snapshot: Dictionary = {}
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
	var required_debug_modes := {
		1: "final_mask",
		5: "pre_absorption",
		7: "ownership_rgb",
	}
	for mode in [1, 2, 3, 4, 5, 7]:
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
		if required_debug_modes.has(mode) and str(surface_snapshot.get("mask_mode", "")) != required_debug_modes[mode]:
			push_error("[Ocean Optics Smoke] surface refraction mode %d reported mask mode %s, expected %s" % [
				mode,
				str(surface_snapshot.get("mask_mode", "")),
				required_debug_modes[mode],
			])
			get_tree().quit(1)
			return
	_surface_refraction_layer.set("diagnostic_stats_enabled", true)
	_surface_refraction_layer.set("refraction_strength", 0.0)
	_surface_refraction_layer.call("set_debug_mode", 7)
	await _wait_frames(4)
	surface_snapshot = _assert_surface_refraction_ready("zero-travel ownership")
	zero_travel_debug_stats = surface_snapshot.get("surface_refraction_debug_stats", {})
	if not _assert_zero_travel_ownership_collapses(zero_travel_debug_stats):
		return
	_surface_refraction_layer.call("set_debug_mode", 0)
	_surface_refraction_layer.set("refraction_strength", 0.45)
	_surface_refraction_layer.set("diagnostic_stats_enabled", false)
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
	await _wait_frames(8)
	surface_report_snapshot = _surface_refraction_layer.call("get_runtime_status")

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

	if not surface_report_snapshot.is_empty():
		_write_controlled_refraction_report(surface_report_snapshot, surface_debug_stats, zero_travel_debug_stats)

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
	if str(snapshot.get("source_mode", "")) != "controlled":
		push_error("[Ocean Optics Smoke] surface refraction did not use controlled source mode in %s mode" % label)
		get_tree().quit(1)
		return {}
	if not bool(snapshot.get("source_has_renderer_matrices", false)):
		push_error("[Ocean Optics Smoke] controlled refraction source did not publish renderer-native matrices in %s mode" % label)
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


func _assert_surface_refraction_accepts_pixels(stats: Dictionary) -> bool:
	if not bool(stats.get("available", false)):
		push_error("[Ocean Optics Smoke] surface refraction diagnostic stats unavailable: %s" % str(stats))
		get_tree().quit(1)
		return false
	for counter_name in [
		"visible_water_pixels",
		"source_ready_pixels",
		"candidate_mask_pixels",
		"stored_pixels",
	]:
		if int(stats.get(counter_name, 0)) <= 0:
			push_error("[Ocean Optics Smoke] surface refraction accepted zero %s; stats=%s" % [
				counter_name,
				str(stats),
			])
			get_tree().quit(1)
			return false
	return true


func _assert_source_candidate_projection_matches(stats: Dictionary, label: String) -> bool:
	if not bool(stats.get("available", false)):
		push_error("[Ocean Optics Smoke] %s source/main projection diagnostic stats unavailable: %s" % [
			label,
			str(stats),
		])
		get_tree().quit(1)
		return false
	var visible_pixels := int(stats.get("visible_water_pixels", 0))
	if visible_pixels <= 0:
		push_error("[Ocean Optics Smoke] %s source/main projection diagnostic saw no visible water pixels: %s" % [
			label,
			str(stats),
		])
		get_tree().quit(1)
		return false
	var tolerance := maxi(16, int(float(visible_pixels) * 0.001))
	var mismatch_pixels := int(stats.get("source_candidate_mismatch_gt_half_px_pixels", 0))
	if mismatch_pixels > tolerance:
		push_error("[Ocean Optics Smoke] %s source/main projected candidate mismatch exceeded tolerance; mismatch=%d tolerance=%d stats=%s" % [
			label,
			mismatch_pixels,
			tolerance,
			str(stats),
		])
		get_tree().quit(1)
		return false
	return true


func _assert_zero_travel_ownership_collapses(stats: Dictionary) -> bool:
	if not bool(stats.get("available", false)):
		push_error("[Ocean Optics Smoke] zero-travel diagnostic stats unavailable: %s" % str(stats))
		get_tree().quit(1)
		return false
	var visible_pixels := int(stats.get("visible_water_pixels", 0))
	if visible_pixels <= 0:
		push_error("[Ocean Optics Smoke] zero-travel diagnostic saw no visible water pixels: %s" % str(stats))
		get_tree().quit(1)
		return false
	var tolerance := maxi(16, int(float(visible_pixels) * 0.001))
	for counter_name in [
		"candidate_offset_gt_half_px_pixels",
		"candidate_offset_gt_two_px_pixels",
		"source_candidate_mismatch_gt_half_px_pixels",
	]:
		if int(stats.get(counter_name, 0)) > tolerance:
			push_error("[Ocean Optics Smoke] zero-travel ownership did not collapse; %s=%d tolerance=%d stats=%s" % [
				counter_name,
				int(stats.get(counter_name, 0)),
				tolerance,
				str(stats),
			])
			get_tree().quit(1)
			return false
	return true


func _stat_fraction(stats: Dictionary, numerator_name: String, denominator_name: String = "visible_water_pixels") -> float:
	var denominator := int(stats.get(denominator_name, 0))
	if denominator <= 0:
		return 0.0
	return float(int(stats.get(numerator_name, 0))) / float(denominator)


func _write_controlled_refraction_report(snapshot: Dictionary, diagnostic_stats: Dictionary, zero_travel_debug_stats: Dictionary) -> void:
	var zero_tolerance := maxi(16, int(float(zero_travel_debug_stats.get("visible_water_pixels", 0)) * 0.001))
	var report := {
		"source_mode": str(snapshot.get("source_mode", "")),
		"source_valid": bool(snapshot.get("source_valid", false)),
		"source_depth_valid": bool(snapshot.get("source_depth_valid", false)),
		"source_fresh": bool(snapshot.get("source_fresh", false)),
		"source_size": str(snapshot.get("source_size", Vector2i.ZERO)),
		"source_frame_age": int(snapshot.get("capture_frame_age", -1)),
		"source_frame_tolerance": int(snapshot.get("source_frame_tolerance", -1)),
		"source_has_renderer_matrices": bool(snapshot.get("source_has_renderer_matrices", false)),
		"source_renderer_matrix_frame": int(snapshot.get("source_renderer_matrix_frame", -1)),
		"source_renderer_matrix_age": int(snapshot.get("source_renderer_matrix_age", -1)),
		"layer_enabled": bool(snapshot.get("enabled", false)),
		"compositor_enabled": bool(snapshot.get("compositor_enabled", false)),
		"refraction_strength": float(snapshot.get("refraction_strength", 0.0)),
		"edge_guard_strength": float(snapshot.get("edge_guard_strength", 0.0)),
		"debug_mode": int(snapshot.get("debug_mode", -1)),
		"mask_mode": str(snapshot.get("mask_mode", "")),
		"reject_reason": str(snapshot.get("reject_reason", "")),
		"dispatch_size": str(snapshot.get("dispatch_size", Vector2i.ZERO)),
		"surface_refraction_debug_stats": diagnostic_stats,
		"normal_candidate_offset_gt_half_px_fraction": _stat_fraction(diagnostic_stats, "candidate_offset_gt_half_px_pixels"),
		"normal_candidate_offset_gt_two_px_fraction": _stat_fraction(diagnostic_stats, "candidate_offset_gt_two_px_pixels"),
		"normal_source_candidate_mismatch_gt_half_px_fraction": _stat_fraction(diagnostic_stats, "source_candidate_mismatch_gt_half_px_pixels"),
		"zero_travel_ownership_debug_stats": zero_travel_debug_stats,
		"zero_travel_candidate_offset_gt_half_px_fraction": _stat_fraction(zero_travel_debug_stats, "candidate_offset_gt_half_px_pixels"),
		"zero_travel_candidate_offset_gt_two_px_fraction": _stat_fraction(zero_travel_debug_stats, "candidate_offset_gt_two_px_pixels"),
		"zero_travel_source_candidate_mismatch_gt_half_px_fraction": _stat_fraction(zero_travel_debug_stats, "source_candidate_mismatch_gt_half_px_pixels"),
		"zero_travel_red_green_collapsed": (
			bool(zero_travel_debug_stats.get("available", false))
			and int(zero_travel_debug_stats.get("candidate_offset_gt_half_px_pixels", 0)) <= zero_tolerance
			and int(zero_travel_debug_stats.get("candidate_offset_gt_two_px_pixels", 0)) <= zero_tolerance
			and int(zero_travel_debug_stats.get("source_candidate_mismatch_gt_half_px_pixels", 0)) <= zero_tolerance
		),
		"checked_surface_debug_modes": [0, 1, 2, 3, 4, 5, 7],
		"required_surface_debug_modes": {
			"final": 0,
			"final_mask": 1,
			"pre_absorption": 5,
			"ownership_rgb": 7,
		},
		"surface_refraction_ms": float(snapshot.get("surface_refraction_ms", 0.0)),
		"surface_refraction_frame": int(snapshot.get("surface_refraction_frame", -1)),
		"surface_refraction_timing_available": bool(snapshot.get("surface_refraction_timing_available", false)),
		"surface_refraction_timing_valid": bool(snapshot.get("surface_refraction_timing_valid", false)),
		"surface_refraction_timing_debug": snapshot.get("surface_refraction_timing_debug", {}),
		"controlled_source_copy_ms": float(snapshot.get("controlled_source_copy_ms", 0.0)),
		"controlled_source_copy_frame": int(snapshot.get("controlled_source_copy_frame", -1)),
		"controlled_source_copy_timing_available": bool(snapshot.get("controlled_source_copy_timing_available", false)),
		"controlled_source_copy_timing_valid": bool(snapshot.get("controlled_source_copy_timing_valid", false)),
		"controlled_source_copy_timing_marker_scope": str(snapshot.get("controlled_source_copy_timing_marker_scope", "")),
		"controlled_source_copy_timing_marker_begin": str(snapshot.get("controlled_source_copy_timing_marker_begin", "")),
		"controlled_source_copy_timing_marker_end": str(snapshot.get("controlled_source_copy_timing_marker_end", "")),
		"controlled_source_update_cpu_ms": float(snapshot.get("controlled_source_update_cpu_ms", 0.0)),
		"controlled_copy_surface_ms": float(snapshot.get("controlled_copy_surface_ms", -1.0)),
		"controlled_copy_surface_timing_available": bool(snapshot.get("controlled_copy_surface_timing_available", false)),
		"controlled_copy_surface_timing_valid": bool(snapshot.get("controlled_copy_surface_timing_valid", false)),
		"controlled_total_refraction_ms": (
			float(snapshot.get("controlled_total_refraction_ms", -1.0))
			if bool(snapshot.get("controlled_total_refraction_timing_valid", false))
			else "unavailable"
		),
		"controlled_total_refraction_timing_available": bool(snapshot.get("controlled_total_refraction_timing_available", false)),
		"controlled_total_refraction_timing_valid": bool(snapshot.get("controlled_total_refraction_timing_valid", false)),
		"controlled_total_refraction_unavailable_reason": str(snapshot.get("controlled_total_refraction_unavailable_reason", "unknown")),
		"controlled_source_render_ms": (
			float(snapshot.get("controlled_source_render_ms", -1.0))
			if bool(snapshot.get("controlled_source_render_timing_valid", false))
			else "unavailable"
		),
		"controlled_source_render_frame": int(snapshot.get("controlled_source_render_frame", -1)),
		"controlled_source_render_timing_available": bool(snapshot.get("controlled_source_render_timing_available", false)),
		"controlled_source_render_timing_valid": bool(snapshot.get("controlled_source_render_timing_valid", false)),
		"controlled_source_render_timing_scope": str(snapshot.get("controlled_source_render_timing_scope", "unavailable")),
		"controlled_source_render_timing_marker_scope": str(snapshot.get("controlled_source_render_timing_marker_scope", "")),
		"controlled_source_render_timing_marker_begin": str(snapshot.get("controlled_source_render_timing_marker_begin", "")),
		"controlled_source_render_timing_marker_end": str(snapshot.get("controlled_source_render_timing_marker_end", "")),
		"controlled_total_same_timing_frame": bool(snapshot.get("controlled_total_same_timing_frame", false)),
	}
	var report_path := ProjectSettings.globalize_path("res://.godot/ocean_optics_debug_smoke_report.json")
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		push_error("[Ocean Optics Smoke] failed to write controlled refraction report to %s" % report_path)
		get_tree().quit(1)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.flush()
	file.close()
