## Auto-performance snapshot — waits for scene to fully load, collects FPS data, writes report
## Detects scene readiness by watching for FPS > 5 (loading runs at ~1 FPS)
extends Node

enum State { WAITING_FOR_LOAD, STABILIZING, SAMPLING, DONE }

var _state: int = State.WAITING_FOR_LOAD
var _samples: Array[Dictionary] = []
var _sample_interval: float = 0.5
var _last_sample: float = 0.0
var _duration: float = 15.0  # sample for 15 seconds
var _stable_start: float = 0.0
var _sample_start: float = 0.0
var _stabilize_time: float = 3.0  # wait 3s after FPS > 5 before sampling
var _consecutive_good: int = 0
var _quit_after: bool = false  # Only quit app after report if --perf-quit CLI flag is set

func _ready() -> void:
	_quit_after = OS.get_cmdline_args().has("--perf-quit") or OS.get_cmdline_user_args().has("--perf-quit")
	print("[PERF] Auto-profiler waiting for scene to finish loading (FPS > 5)...")

func _process(_delta: float) -> void:
	match _state:
		State.WAITING_FOR_LOAD:
			var fps := Engine.get_frames_per_second()
			if fps > 5:
				_consecutive_good += 1
				if _consecutive_good >= 3:
					print("[PERF] Scene loaded (FPS=%d). Stabilizing for %.0fs..." % [fps, _stabilize_time])
					_state = State.STABILIZING
					_stable_start = Time.get_ticks_msec() / 1000.0
			else:
				_consecutive_good = 0

		State.STABILIZING:
			var now: float = Time.get_ticks_msec() / 1000.0
			if now - _stable_start >= _stabilize_time:
				print("[PERF] Sampling for %.0fs..." % _duration)
				_state = State.SAMPLING
				_sample_start = now
				_last_sample = 0.0

		State.SAMPLING:
			var now: float = Time.get_ticks_msec() / 1000.0
			var elapsed: float = now - _sample_start

			if elapsed >= _duration:
				_write_report()
				_state = State.DONE
				# Only quit if launched with --perf-quit (CLI benchmarking mode)
				if _quit_after:
					get_tree().quit()
				return

			if now - _last_sample >= _sample_interval:
				_last_sample = now
				_samples.append(_take_sample(elapsed))

		State.DONE:
			pass

func _take_sample(t: float) -> Dictionary:
	return {
		"t": snappedf(t, 0.1),
		"fps": Engine.get_frames_per_second(),
		"frame_time_ms": snappedf(1000.0 / maxf(Engine.get_frames_per_second(), 1), 0.1),
		"objects_rendered": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		"video_mem_mb": snappedf(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 0.1),
		"texture_mem_mb": snappedf(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0, 0.1),
		"static_mem_mb": snappedf(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, 0.1),
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"resources": Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
		"orphan_nodes": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
		"physics_objects": Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS),
		"mid_rs_instances": _get_mid_tier_instances(),
		"mid_mesh_types": _get_mid_tier_mesh_types(),
		"promoted_objects": _get_promoted_count(),
	}


func _get_mid_tier_instances() -> float:
	var nsm := _get_streaming_manager()
	if nsm and nsm.has_method("get_static_renderer_stats"):
		var stats: Dictionary = nsm.get_static_renderer_stats()
		return float(stats.get("total_instances", 0))
	return 0.0


func _get_mid_tier_mesh_types() -> float:
	var nsm := _get_streaming_manager()
	if nsm and nsm.has_method("get_static_renderer_stats"):
		var stats: Dictionary = nsm.get_static_renderer_stats()
		return float(stats.get("mesh_types", 0))
	return 0.0


func _get_promoted_count() -> float:
	var nsm := _get_streaming_manager()
	if nsm and nsm.has_method("get_stats"):
		var stats: Dictionary = nsm.get_stats()
		return float(stats.get("mid_to_near_promotions", 0))
	return 0.0


func _get_streaming_manager() -> Node:
	# Find NativeStreamingManager in scene tree
	var root := get_tree().root
	return _find_node_by_class(root, "NativeStreamingManager")


func _find_node_by_class(node: Node, class_str: String) -> Node:
	if node.get_class() == class_str or (node is Node3D and node.has_method("get_static_renderer_stats")):
		return node
	for child in node.get_children():
		var found := _find_node_by_class(child, class_str)
		if found:
			return found
	return null

func _write_report() -> void:
	var path := "user://perf_snapshot.txt"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if not f:
		push_error("[PERF] Cannot write to %s" % path)
		return

	f.store_line("=== PERFORMANCE SNAPSHOT ===")
	f.store_line("Date: %s" % Time.get_datetime_string_from_system())
	f.store_line("Samples: %d over %.0fs" % [_samples.size(), _duration])
	f.store_line("")

	if _samples.is_empty():
		f.store_line("NO SAMPLES COLLECTED")
		f.close()
		return

	# Compute stats
	var fps_arr: Array[float] = []
	var draw_arr: Array[float] = []
	var prim_arr: Array[float] = []
	var obj_arr: Array[float] = []
	var vmem_arr: Array[float] = []
	var node_arr: Array[float] = []

	for s: Dictionary in _samples:
		fps_arr.append(s["fps"])
		draw_arr.append(s["draw_calls"])
		prim_arr.append(s["primitives"])
		obj_arr.append(s["objects_rendered"])
		vmem_arr.append(s["video_mem_mb"])
		node_arr.append(s["nodes"])

	fps_arr.sort()
	draw_arr.sort()

	var avg_fps: float = 0.0
	for v: float in fps_arr:
		avg_fps += v
	avg_fps /= fps_arr.size()

	var avg_draw: float = 0.0
	for v: float in draw_arr:
		avg_draw += v
	avg_draw /= draw_arr.size()

	var avg_prim: float = 0.0
	for v: float in prim_arr:
		avg_prim += v
	avg_prim /= prim_arr.size()

	var avg_nodes: float = 0.0
	for v: float in node_arr:
		avg_nodes += v
	avg_nodes /= node_arr.size()

	var p1_idx := int(fps_arr.size() * 0.01)
	var p5_idx := int(fps_arr.size() * 0.05)

	f.store_line("--- SUMMARY ---")
	f.store_line("FPS: min=%.0f  p1=%.0f  p5=%.0f  avg=%.1f  max=%.0f" % [
		fps_arr[0], fps_arr[p1_idx], fps_arr[p5_idx], avg_fps, fps_arr[-1]
	])
	f.store_line("Frame time: best=%.1fms  avg=%.1fms  worst=%.1fms" % [
		1000.0 / maxf(fps_arr[-1], 1), 1000.0 / maxf(avg_fps, 1), 1000.0 / maxf(fps_arr[0], 1)
	])
	f.store_line("Draw calls: min=%.0f  avg=%.0f  max=%.0f" % [draw_arr[0], avg_draw, draw_arr[-1]])
	f.store_line("Primitives (avg): %.0f" % avg_prim)
	f.store_line("Objects rendered (avg): %.0f" % (0.0 if obj_arr.is_empty() else obj_arr.reduce(func(a: float, b: float) -> float: return a + b) / obj_arr.size()))
	f.store_line("Nodes (avg): %.0f" % avg_nodes)
	f.store_line("VRAM (last): %.1f MB" % vmem_arr[-1])
	f.store_line("Texture mem (last): %.1f MB" % _samples[-1]["texture_mem_mb"])
	f.store_line("Static mem (last): %.1f MB" % _samples[-1]["static_mem_mb"])
	f.store_line("Resources (last): %.0f" % _samples[-1]["resources"])
	f.store_line("Orphan nodes (last): %.0f" % _samples[-1]["orphan_nodes"])
	f.store_line("Physics objects (last): %.0f" % _samples[-1]["physics_objects"])
	f.store_line("MID RS instances (last): %.0f" % _samples[-1]["mid_rs_instances"])
	f.store_line("MID mesh types (last): %.0f" % _samples[-1]["mid_mesh_types"])
	f.store_line("Promoted objects (total): %.0f" % _samples[-1]["promoted_objects"])
	f.store_line("")

	f.store_line("--- PER-SECOND SAMPLES ---")
	f.store_line("t(s) | FPS | FrameMS | DrawCalls | Primitives | ObjRendered | VRAM_MB | Nodes | MID_RS | MID_Types | Promoted")
	for s: Dictionary in _samples:
		f.store_line("%.1f | %.0f | %.1f | %.0f | %.0f | %.0f | %.1f | %.0f | %.0f | %.0f | %.0f" % [
			s["t"], s["fps"], s["frame_time_ms"], s["draw_calls"], s["primitives"],
			s["objects_rendered"], s["video_mem_mb"], s["nodes"],
			s["mid_rs_instances"], s["mid_mesh_types"], s["promoted_objects"]
		])

	f.close()
	var abs_path := ProjectSettings.globalize_path(path)
	print("[PERF] Report written to: %s" % abs_path)
	print("[PERF] ============================")
	print("[PERF] FPS: min=%.0f  avg=%.1f  max=%.0f" % [fps_arr[0], avg_fps, fps_arr[-1]])
	print("[PERF] Draw calls (avg): %.0f" % avg_draw)
	print("[PERF] Primitives (avg): %.0f" % avg_prim)
	print("[PERF] Nodes (avg): %.0f" % avg_nodes)
	print("[PERF] VRAM: %.1f MB | Textures: %.1f MB" % [vmem_arr[-1], _samples[-1]["texture_mem_mb"]])
	print("[PERF] MID RS instances: %.0f | Types: %.0f | Promoted: %.0f" % [
		_samples[-1]["mid_rs_instances"], _samples[-1]["mid_mesh_types"], _samples[-1]["promoted_objects"]
	])
	print("[PERF] Orphan nodes: %.0f" % _samples[-1]["orphan_nodes"])
	print("[PERF] ============================")
