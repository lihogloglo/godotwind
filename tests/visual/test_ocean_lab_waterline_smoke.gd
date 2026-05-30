extends "res://tests/visual/test_ocean_lab.gd"

## Crash smoke for the receiver-only waterline path.
## Enables the quarantined WaterlineStack in binary direct-replacement mode,
## waits for compositor dispatches, then quits without screenshots.

var _smoke_frames: int = 0
var _activation_frame: int = 8
var _inspection_started: bool = false
var _replacement_started: bool = false
var _finished: bool = false


func _ready() -> void:
	super._ready()
	print("[Ocean Lab Waterline Smoke] Ready")


func _process(delta: float) -> void:
	super._process(delta)
	if _finished:
		return
	_smoke_frames += 1
	if not _inspection_started and _smoke_frames >= _activation_frame:
		_inspection_started = true
		_start_waterline_receiver_inspection()
	if not _inspection_started or _smoke_frames < _activation_frame + 30:
		return
	if _replacement_started:
		if _smoke_frames < _activation_frame + 60:
			return
		if not _check_waterline_state("replacement", 0):
			return
		_finish_smoke(0)
		return
	if not _check_waterline_state("mask-inspect", 14):
		return
	_replacement_started = true
	_start_waterline_receiver_replacement_inspection()


func _check_waterline_state(label: String, expected_debug_mode: int) -> bool:
	var perf := {}
	if _waterline_stack != null:
		var effect := _waterline_stack.get_waterline_effect()
		if effect != null and effect.has_method("get_underwater_perf_snapshot"):
			var snapshot: Variant = effect.call("get_underwater_perf_snapshot")
			if snapshot is Dictionary:
				perf = snapshot
	print("[Ocean Lab Waterline Smoke] %s waterline perf=%s" % [label, str(perf)])
	if perf.is_empty():
		_fail("missing waterline perf snapshot")
		return false
	if not bool(perf.get("effect_enabled", false)):
		_fail("waterline compositor did not enable")
		return false
	if not bool(perf.get("external_source_valid", false)):
		_fail("receiver capture color/depth buffers were not bound")
		return false
	if not bool(perf.get("external_occlusion_depth_valid", false)):
		_fail("receiver occlusion depth buffer was not bound")
		return false
	if not bool(perf.get("binary_receiver_mask", false)):
		_fail("binary receiver replacement was not enabled")
		return false
	if bool(perf.get("receiver_refraction_enabled", true)):
		_fail("receiver refraction should remain disabled in recovery smoke")
		return false
	if not bool(perf.get("receiver_medium_enabled", false)):
		_fail("receiver water medium should be enabled for optical replacement")
		return false
	if not bool(perf.get("receiver_surface_film_enabled", false)):
		_fail("receiver surface film should be enabled for optical replacement")
		return false
	if int(perf.get("feature_flags", -1)) != 0:
		_fail("advanced waterline features should remain disabled in recovery smoke")
		return false
	if _waterline_debug_mode != expected_debug_mode:
		_fail("%s expected waterline debug mode %d, got %d" % [label, expected_debug_mode, _waterline_debug_mode])
		return false
	if int(perf.get("debug_mode", -1)) != expected_debug_mode:
		_fail("%s effect expected waterline debug mode %d, got %d" % [label, expected_debug_mode, int(perf.get("debug_mode", -1))])
		return false
	if int(perf.get("receiver_source_mode", -1)) != 1:
		_fail("%s expected receiver source mode 1, got %d" % [label, int(perf.get("receiver_source_mode", -1))])
		return false
	var source_size: Vector2i = perf.get("source_size", Vector2i.ZERO)
	var dispatch_size: Vector2i = perf.get("dispatch_size", Vector2i.ZERO)
	if source_size != dispatch_size:
		_fail("%s expected full-resolution source %s, got %s" % [label, str(dispatch_size), str(source_size)])
		return false
	var occlusion_size: Vector2i = perf.get("occlusion_size", Vector2i.ZERO)
	if occlusion_size != dispatch_size:
		_fail("%s expected full-resolution occlusion depth %s, got %s" % [label, str(dispatch_size), str(occlusion_size)])
		return false
	var source_age := int(perf.get("external_source_frame_age", -1))
	if source_age < 0 or source_age > 1:
		_fail("%s expected receiver source frame age <= 1, got %d" % [label, source_age])
		return false
	var occlusion_age := int(perf.get("external_occlusion_frame_age", -1))
	if occlusion_age < 0 or occlusion_age > 1:
		_fail("%s expected occlusion depth frame age <= 1, got %d" % [label, occlusion_age])
		return false
	return true


func _fail(message: String) -> void:
	_finished = true
	push_error("[Ocean Lab Waterline Smoke] %s" % message)
	_finish_smoke(1)


func _finish_smoke(exit_code: int) -> void:
	_finished = true
	_waterline_enabled = false
	_waterline_debug_mode = 0
	if _waterline_stack != null:
		_waterline_stack.set_enabled(false)
	if _underwater_effect != null:
		_underwater_effect.effect_enabled = false
		_underwater_effect.blend_factor = 0.0
	if _water_compositor != null:
		_water_compositor.compositor_effects = []
	if _world_env != null:
		_world_env.compositor = null
	await get_tree().process_frame
	await get_tree().process_frame
	if _waterline_stack != null:
		_waterline_stack.shutdown()
		_waterline_stack.queue_free()
		_waterline_stack = null
	if _underwater_effect != null:
		_underwater_effect.on_effect_removed()
		_underwater_effect = null
	if _wet_effect != null:
		_wet_effect.effect_enabled = false
		_wet_effect.blend_factor = 0.0
		_wet_effect.on_effect_removed()
		_wet_effect = null
	if WaterSystem != null and WaterSystem.has_method("release_runtime_resources"):
		WaterSystem.release_runtime_resources()
	_shutdown_shader_manager_effects()
	for i in range(6):
		await get_tree().process_frame
	get_tree().quit(exit_code)


func _shutdown_shader_manager_effects() -> void:
	var shader_manager := get_node_or_null("/root/ShaderManager")
	if shader_manager != null and shader_manager.has_method("shutdown"):
		shader_manager.call("shutdown")
