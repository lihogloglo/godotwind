extends "res://tests/visual/test_ocean_lab.gd"

## Numeric smoke for ocean lifecycle phases.
## Reuses Ocean Lab initialization, hides non-ocean scene geometry, then compares:
## visible ocean, old-style surface hide, full disable, and re-enable.

const SETTLE_FRAMES: int = 90
const SAMPLE_FRAMES: int = 180

var _perf_phases: Array[Dictionary] = []
var _perf_phase_index: int = -1
var _perf_frames: int = 0
var _perf_samples: int = 0
var _perf_frame_ms_sum: float = 0.0
var _perf_frame_ms_min: float = INF
var _perf_frame_ms_max: float = 0.0
var _perf_fps_sum: float = 0.0
var _perf_results: Array[Dictionary] = []
var _perf_finished: bool = false


func _ready() -> void:
	super._ready()
	_strip_to_ocean_only()
	_perf_phases = [
		{"name": "ocean_on", "action": Callable(self, "_phase_ocean_on")},
		{"name": "surface_hidden_only", "action": Callable(self, "_phase_surface_hidden_only")},
		{"name": "full_disabled", "action": Callable(self, "_phase_full_disabled")},
		{"name": "re_enabled", "action": Callable(self, "_phase_ocean_on")},
	]
	call_deferred("_start_next_perf_phase")


func _process(delta: float) -> void:
	if _perf_finished:
		return
	_perf_frames += 1
	if _perf_phase_index < 0:
		return
	if _perf_frames <= SETTLE_FRAMES:
		return

	_perf_samples += 1
	var frame_ms := delta * 1000.0
	_perf_frame_ms_sum += frame_ms
	_perf_frame_ms_min = minf(_perf_frame_ms_min, frame_ms)
	_perf_frame_ms_max = maxf(_perf_frame_ms_max, frame_ms)
	_perf_fps_sum += float(Engine.get_frames_per_second())

	if _perf_samples >= SAMPLE_FRAMES:
		_finish_perf_phase()


func _strip_to_ocean_only() -> void:
	if _terrain != null:
		_terrain.visible = false
		_terrain.process_mode = Node.PROCESS_MODE_DISABLED
	if _debug_mmi != null:
		_debug_mmi.visible = false
	for entry: Dictionary in _test_objects:
		var node: Node = entry.get("node", null)
		if node != null:
			node.queue_free()
	_test_objects.clear()
	var managed := get_node_or_null("ManagedWetCube")
	if managed != null:
		managed.queue_free()
	if _surface_refraction_layer != null:
		_surface_refraction_layer.call("set_enabled", false)
	if _waterline_stack != null:
		_waterline_stack.set_enabled(false)
	if WaterSystem:
		WaterSystem.set_sea_spray_enabled(false)
		WaterSystem.set_gpu_wave_readback_enabled(false)
	if _camera != null:
		_camera.global_position = Vector3(0.0, 8.0, 24.0)
		_camera.look_at(Vector3(0.0, 0.0, 0.0), Vector3.UP)
	print("[OceanLifecyclePerf] stripped lab to ocean-only geometry")


func _start_next_perf_phase() -> void:
	_perf_phase_index += 1
	if _perf_phase_index >= _perf_phases.size():
		_perf_finished = true
		_write_perf_report()
		call_deferred("_shutdown_and_quit")
		return

	var phase := _perf_phases[_perf_phase_index]
	var action: Callable = phase["action"]
	action.call()
	_perf_frames = 0
	_perf_samples = 0
	_perf_frame_ms_sum = 0.0
	_perf_frame_ms_min = INF
	_perf_frame_ms_max = 0.0
	_perf_fps_sum = 0.0
	print("[OceanLifecyclePerf] phase=%s settling" % phase["name"])


func _finish_perf_phase() -> void:
	var phase := _perf_phases[_perf_phase_index]
	var avg_ms := _perf_frame_ms_sum / maxf(float(_perf_samples), 1.0)
	var avg_fps := _perf_fps_sum / maxf(float(_perf_samples), 1.0)
	var sample := _snapshot_perf(phase["name"])
	sample["avg_frame_ms"] = avg_ms
	sample["min_frame_ms"] = _perf_frame_ms_min
	sample["max_frame_ms"] = _perf_frame_ms_max
	sample["avg_engine_fps"] = avg_fps
	sample["samples"] = _perf_samples
	_perf_results.append(sample)
	print("[OceanLifecyclePerf] phase=%s avg_ms=%.3f avg_fps=%.1f draws=%d prims=%d initialized=%s" % [
		phase["name"],
		avg_ms,
		avg_fps,
		int(sample["draw_calls"]),
		int(sample["primitives"]),
		str(sample["water_initialized"]),
	])
	call_deferred("_start_next_perf_phase")


func _phase_ocean_on() -> void:
	if not WaterSystem:
		return
	if not WaterSystem.is_initialized():
		WaterSystem.force_initialize()
	WaterSystem.set_enabled(true)
	WaterSystem.set_water_layer_enabled(&"ocean_surface", true)
	WaterSystem.set_water_quality(OceanMesh.QualityMode.HIGH)
	if WaterSystem.get_mesh_mode() != OceanMesh.MeshMode.CLIPMAP:
		WaterSystem.rebuild_mesh_with_mode(OceanMesh.MeshMode.CLIPMAP)
	WaterSystem.set_surface_shader_mode(OceanMesh.SurfaceShaderMode.BOUJIE_EXPERIMENTAL)
	_ocean = WaterSystem.get_ocean_mesh()
	if _ocean != null:
		_ocean.layers = WATER_RENDER_LAYER_MASK
		_ocean.visible = true


func _phase_surface_hidden_only() -> void:
	if WaterSystem:
		WaterSystem.set_water_layer_enabled(&"ocean_surface", false)


func _phase_full_disabled() -> void:
	if WaterSystem:
		WaterSystem.set_water_layer_enabled(&"ocean_surface", false)
		WaterSystem.set_enabled(false)


func _snapshot_perf(phase_name: String) -> Dictionary:
	var p := Performance
	var ocean_mesh: OceanMesh = WaterSystem.get_ocean_mesh() if WaterSystem else null
	var spray: Node = WaterSystem.get_ocean_spray() if WaterSystem else null
	return {
		"phase": phase_name,
		"fps_now": float(Engine.get_frames_per_second()),
		"process_ms": p.get_monitor(p.TIME_PROCESS) * 1000.0,
		"physics_ms": p.get_monitor(p.TIME_PHYSICS_PROCESS) * 1000.0,
		"draw_calls": int(p.get_monitor(p.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"objects": int(p.get_monitor(p.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"primitives": int(p.get_monitor(p.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"vram_mb": p.get_monitor(p.RENDER_VIDEO_MEM_USED) / 1048576.0,
		"texture_mem_mb": p.get_monitor(p.RENDER_TEXTURE_MEM_USED) / 1048576.0,
		"node_count": int(p.get_monitor(p.OBJECT_NODE_COUNT)),
		"resource_count": int(p.get_monitor(p.OBJECT_RESOURCE_COUNT)),
		"water_initialized": WaterSystem.is_initialized() if WaterSystem else false,
		"ocean_layer_enabled": WaterSystem.is_water_layer_enabled(&"ocean_surface") if WaterSystem else false,
		"ocean_mesh_alive": ocean_mesh != null,
		"ocean_mesh_visible": ocean_mesh.visible if ocean_mesh != null else false,
		"spray_alive": spray != null,
		"spray_visible": spray.visible if spray != null else false,
		"fft_cascades": WaterSystem.get_fft_cascade_count() if WaterSystem else 0,
		"quality": WaterSystem.get_water_quality_name() if WaterSystem else "none",
		"mesh_mode": "Projected" if WaterSystem and WaterSystem.get_mesh_mode() == OceanMesh.MeshMode.PROJECTED else "Clipmap",
		"surface_shader": WaterSystem.get_surface_shader_mode_name() if WaterSystem else "none",
	}


func _write_perf_report() -> void:
	var report := {
		"scene": "res://tests/visual/test_ocean_lifecycle_perf_smoke.tscn",
		"settle_frames": SETTLE_FRAMES,
		"sample_frames": SAMPLE_FRAMES,
		"results": _perf_results,
	}
	var path := "res://reports/ocean_lifecycle_perf_smoke.json"
	var absolute_path := ProjectSettings.globalize_path(path)
	var dir := absolute_path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	var file := FileAccess.open(absolute_path, FileAccess.WRITE)
	if file == null:
		push_error("[OceanLifecyclePerf] failed to write %s" % absolute_path)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("[OceanLifecyclePerf] wrote %s" % absolute_path)


func _shutdown_and_quit() -> void:
	if WaterSystem:
		WaterSystem.set_enabled(false)
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit(0)
