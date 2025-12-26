## PerformanceProfiler - Tracks and reports performance metrics for world streaming
## Use this to identify bottlenecks in cell loading, rendering, and memory usage
class_name PerformanceProfiler
extends RefCounted

## Frame timing samples for averaging
var _frame_times: Array[float] = []
var _frame_sample_count: int = 60

## Cell loading timing
var _cell_load_times: Array[float] = []
var _cell_load_sample_count: int = 20

## Model instantiation timing
var _model_times: Dictionary = {}  # model_path -> Array[float]

## Memory tracking
var _last_memory_static: int = 0
var _last_memory_objects: int = 0

## Draw call tracking
var _peak_draw_calls: int = 0
var _peak_vertices: int = 0
var _peak_objects_visible: int = 0

## Light tracking
var _light_count: int = 0
var _shadow_light_count: int = 0

## Current profiling session
var _session_start_time: int = 0
var _total_cells_loaded: int = 0
var _total_objects_loaded: int = 0


## Start a profiling session
func start_session() -> void:
	_session_start_time = Time.get_ticks_msec()
	_total_cells_loaded = 0
	_total_objects_loaded = 0
	_peak_draw_calls = 0
	_peak_vertices = 0
	_frame_times.clear()
	_cell_load_times.clear()
	print("PerformanceProfiler: Session started")


## Record frame timing
func record_frame(delta: float) -> void:
	_frame_times.append(delta * 1000.0)  # Convert to ms
	if _frame_times.size() > _frame_sample_count:
		_frame_times.pop_front()

	# Update peak rendering stats from RenderingServer
	var rs := RenderingServer
	# Note: These are approximations - actual tracking requires more work
	_update_render_stats()


## Record cell load time
func record_cell_load(load_time_ms: float, object_count: int) -> void:
	_cell_load_times.append(load_time_ms)
	if _cell_load_times.size() > _cell_load_sample_count:
		_cell_load_times.pop_front()
	_total_cells_loaded += 1
	_total_objects_loaded += object_count


## Record model instantiation time
func record_model_instantiation(model_path: String, time_ms: float) -> void:
	if model_path not in _model_times:
		_model_times[model_path] = []
	var times: Array = _model_times[model_path]
	times.append(time_ms)
	if times.size() > 10:
		times.pop_front()


## Update render statistics from the engine
func _update_render_stats() -> void:
	# Get render info from Performance singleton
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var vertices := Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	var objects := Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)

	if draw_calls > _peak_draw_calls:
		_peak_draw_calls = int(draw_calls)
	if vertices > _peak_vertices:
		_peak_vertices = int(vertices)
	if objects > _peak_objects_visible:
		_peak_objects_visible = int(objects)


## Count lights in the scene tree
func count_lights(root: Node) -> Dictionary:
	_light_count = 0
	_shadow_light_count = 0
	_count_lights_recursive(root)
	return {
		"total_lights": _light_count,
		"shadow_lights": _shadow_light_count
	}


func _count_lights_recursive(node: Node) -> void:
	if node is Light3D:
		var light: Light3D = node as Light3D
		_light_count += 1
		if light.shadow_enabled:
			_shadow_light_count += 1
	for child: Node in node.get_children():
		_count_lights_recursive(child)


## Get average frame time in ms
func get_avg_frame_time_ms() -> float:
	if _frame_times.is_empty():
		return 0.0
	var sum := 0.0
	for t in _frame_times:
		sum += t
	return sum / _frame_times.size()


## Get FPS from frame times
func get_fps() -> float:
	var avg := get_avg_frame_time_ms()
	if avg <= 0:
		return 0.0
	return 1000.0 / avg


## Get frame time percentiles (useful for detecting hitches)
func get_frame_time_percentiles() -> Dictionary:
	if _frame_times.is_empty():
		return {"p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0}

	var sorted := _frame_times.duplicate()
	sorted.sort()

	var p50_idx := int(sorted.size() * 0.50)
	var p95_idx := int(sorted.size() * 0.95)
	var p99_idx := int(sorted.size() * 0.99)

	return {
		"p50": sorted[p50_idx],
		"p95": sorted[mini(p95_idx, sorted.size() - 1)],
		"p99": sorted[mini(p99_idx, sorted.size() - 1)],
		"max": sorted[-1]
	}


## Get average cell load time
func get_avg_cell_load_time_ms() -> float:
	if _cell_load_times.is_empty():
		return 0.0
	var sum := 0.0
	for t in _cell_load_times:
		sum += t
	return sum / _cell_load_times.size()


## Get slowest models (for optimization targeting)
func get_slowest_models(top_n: int = 5) -> Array:
	var avg_times: Array = []
	for model_path: String in _model_times:
		var times: Array = _model_times[model_path]
		if times.is_empty():
			continue
		var sum := 0.0
		for t: float in times:
			sum += t
		avg_times.append({"path": model_path, "avg_ms": sum / times.size(), "count": times.size()})

	avg_times.sort_custom(func(a: Variant, b: Variant) -> bool: return a.avg_ms > b.avg_ms)
	return avg_times.slice(0, top_n)


## Get memory usage stats
func get_memory_stats() -> Dictionary:
	return {
		"static_memory_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / (1024.0 * 1024.0),
		"objects_in_use": Performance.get_monitor(Performance.OBJECT_COUNT),
		"nodes_in_tree": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"resources_in_use": Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
	}


## Get rendering stats
func get_render_stats() -> Dictionary:
	return {
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"peak_draw_calls": _peak_draw_calls,
		"primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		"peak_primitives": _peak_vertices,
		"objects_visible": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		"peak_objects_visible": _peak_objects_visible,
	}


## Get material library stats if available
func get_material_library_stats() -> Dictionary:
	var MatLib: GDScript = load("res://src/core/texture/material_library.gd")
	if MatLib:
		return MatLib.call("get_stats")
	return {}


## Get texture loader stats if available
func get_texture_stats() -> Dictionary:
	var TexLoader: GDScript = load("res://src/core/texture/texture_loader.gd")
	if TexLoader:
		return TexLoader.call("get_stats")
	return {}


## Get complete profiling report
func get_report() -> Dictionary:
	var session_duration := (Time.get_ticks_msec() - _session_start_time) / 1000.0 if _session_start_time > 0 else 0.0
	var frame_percentiles := get_frame_time_percentiles()

	return {
		"session": {
			"duration_sec": session_duration,
			"total_cells_loaded": _total_cells_loaded,
			"total_objects_loaded": _total_objects_loaded,
		},
		"frame_timing": {
			"avg_ms": get_avg_frame_time_ms(),
			"fps": get_fps(),
			"p50_ms": frame_percentiles.p50,
			"p95_ms": frame_percentiles.p95,
			"p99_ms": frame_percentiles.p99,
			"max_ms": frame_percentiles.max,
		},
		"cell_loading": {
			"avg_load_time_ms": get_avg_cell_load_time_ms(),
		},
		"memory": get_memory_stats(),
		"rendering": get_render_stats(),
		"lights": {
			"total": _light_count,
			"with_shadows": _shadow_light_count,
		},
		"materials": get_material_library_stats(),
		"textures": get_texture_stats(),
		"slowest_models": get_slowest_models(5),
	}


## Get formatted report string for display
func get_formatted_report() -> String:
	var report := get_report()
	var frame: Dictionary = report.frame_timing
	var mem: Dictionary = report.memory
	var render: Dictionary = report.rendering

	return """[b]Performance Report[/b]

[b]Frame Timing[/b]
FPS: %.1f (%.2f ms avg)
P50: %.2f ms | P95: %.2f ms | P99: %.2f ms
Max: %.2f ms

[b]Rendering[/b]
Draw calls: %d (peak: %d)
Primitives: %d (peak: %d)
Objects visible: %d

[b]Memory[/b]
Static: %.1f MB
Nodes: %d | Resources: %d

[b]Cell Loading[/b]
Cells loaded: %d
Avg load time: %.1f ms
Objects loaded: %d

[b]Lights[/b]
Total: %d | With shadows: %d""" % [
		frame.fps, frame.avg_ms,
		frame.p50_ms, frame.p95_ms, frame.p99_ms,
		frame.max_ms,
		render.draw_calls, render.peak_draw_calls,
		render.primitives, render.peak_primitives,
		render.objects_visible,
		mem.static_memory_mb,
		mem.nodes_in_tree, mem.resources_in_use,
		report.session.total_cells_loaded,
		report.cell_loading.avg_load_time_ms,
		report.session.total_objects_loaded,
		report.lights.total, report.lights.with_shadows
	]
