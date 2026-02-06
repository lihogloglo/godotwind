## Generates detailed profiling reports for the UI log panel.
##
## Extracted from world_explorer.gd. Collects stats from profiler,
## cell_manager, streaming manager, and BSA cache, then outputs
## a formatted report via a log callback.
##
## Usage:
## [codeblock]
## var reporter := ProfilingReport.new(profiler, cell_manager, streaming_mgr, log_func)
## reporter.dump_report()
## [/codeblock]
class_name ProfilingReport
extends RefCounted

var _profiler: PerformanceProfiler = null
var _cell_manager: CellManager = null
var _streaming_manager: Node3D = null
var _log_callback: Callable
var _scene_root: Node = null


func _init(
	profiler: PerformanceProfiler,
	cell_manager: CellManager,
	streaming_manager: Node3D,
	log_callback: Callable,
	scene_root: Node = null
) -> void:
	_profiler = profiler
	_cell_manager = cell_manager
	_streaming_manager = streaming_manager
	_log_callback = log_callback
	_scene_root = scene_root


func _log(message: String) -> void:
	if _log_callback.is_valid():
		_log_callback.call(message)


## Dump a comprehensive profiling report to the UI log panel
func dump_report() -> void:
	if not _profiler:
		_log("[color=red]Profiler not initialized[/color]")
		return

	# Count lights in scene
	if _scene_root:
		_profiler.count_lights(_scene_root)

	var report: Dictionary = _profiler.get_report()

	_log("\n[b]====== PROFILING REPORT ======[/b]")
	_log("Session duration: %.1f seconds" % report.session.duration_sec)
	_log("")
	_log("[b]Frame Timing[/b]")
	_log("  FPS: %.1f (%.2f ms avg)" % [report.frame_timing.fps, report.frame_timing.avg_ms])
	_log("  P50: %.2f ms | P95: %.2f ms | P99: %.2f ms" % [
		report.frame_timing.p50_ms, report.frame_timing.p95_ms, report.frame_timing.p99_ms
	])
	_log("  Max frame: %.2f ms" % report.frame_timing.max_ms)
	_log("")
	_log("[b]Rendering[/b]")
	_log("  Draw calls: %d (peak: %d)" % [report.rendering.draw_calls, report.rendering.peak_draw_calls])
	_log("  Primitives: %d (peak: %d)" % [report.rendering.primitives, report.rendering.peak_primitives])
	_log("  Objects visible: %d" % report.rendering.objects_visible)
	_log("")
	_log("[b]Memory[/b]")
	_log("  Static: %.1f MB" % report.memory.static_memory_mb)
	_log("  Nodes: %d | Resources: %d" % [report.memory.nodes_in_tree, report.memory.resources_in_use])
	_log("")
	_log("[b]Cell Loading[/b]")
	_log("  Cells loaded: %d" % report.session.total_cells_loaded)
	_log("  Objects loaded: %d" % report.session.total_objects_loaded)
	_log("  Avg load time: %.1f ms" % report.cell_loading.avg_load_time_ms)
	_log("")
	_log("[b]Lights[/b]")
	_log("  Total: %d | With shadows: %d" % [report.lights.total, report.lights.with_shadows])

	var materials_data: Dictionary = report.get("materials", {})
	if not materials_data.is_empty():
		_log("")
		_log("[b]Materials[/b]")
		_log("  Unique materials: %d" % materials_data.get("cached_materials", 0))
		_log("  Cache hits: %d" % materials_data.get("cache_hits", 0))
		var mat_hit_rate: float = materials_data.get("hit_rate", 0.0)
		_log("  Hit rate: %.1f%%" % (mat_hit_rate * 100.0))

	var textures_data: Dictionary = report.get("textures", {})
	if not textures_data.is_empty():
		_log("")
		_log("[b]Textures[/b]")
		_log("  Loaded: %d (cached: %d)" % [
			textures_data.get("loaded", 0),
			textures_data.get("cached", 0)
		])
		_log("  Cache hits: %d | Failures: %d" % [
			textures_data.get("cache_hits", 0),
			textures_data.get("failures", 0)
		])

	# Object pool stats
	var cell_stats: Dictionary = {}
	if _cell_manager.has_method("get_stats"):
		cell_stats = _cell_manager.get_stats()
	var pool_available: int = cell_stats.get("pool_available", 0)
	var pool_in_use: int = cell_stats.get("pool_in_use", 0)
	var pool_acquires: int = cell_stats.get("pool_acquires", 0)
	if pool_available > 0 or pool_in_use > 0 or pool_acquires > 0:
		_log("")
		_log("[b]Object Pool[/b]")
		_log("  Available: %d | In use: %d | Total pools: %d" % [
			pool_available,
			pool_in_use,
			cell_stats.get("pool_total_pools", 0)
		])
		_log("  Acquires: %d | Releases: %d | New instances: %d" % [
			pool_acquires,
			cell_stats.get("pool_releases", 0),
			cell_stats.get("pool_new_instances", 0)
		])
		_log("  Objects from pool (reused): %d" % cell_stats.get("objects_from_pool", 0))
		_log("  Hit rate: %.1f%%" % (cell_stats.get("pool_hit_rate", 0.0) * 100.0))

	# Instantiation pipeline stats
	if _cell_manager.has_method("get_loading_stats"):
		var loading_stats: Dictionary = _cell_manager.get_loading_stats()
		_log("")
		_log("[b]Instantiation Pipeline[/b]")
		_log("  Queue size: %d | Burst active: %s" % [
			loading_stats.get("instantiation_queue_size", 0),
			"Yes" if loading_stats.get("burst_loading_active", false) else "No"
		])
		_log("  Burst budget: %.1f ms | Max instantiations: %d" % [
			loading_stats.get("burst_budget_ms", 0.0),
			loading_stats.get("burst_max_instantiations", 0)
		])
		_log("  Objects instantiated: %d | From pool: %d" % [
			loading_stats.get("objects_instantiated", 0),
			loading_stats.get("objects_from_pool", 0)
		])
		var avg_dup_us: int = loading_stats.get("avg_duplicate_time_us", 0)
		_log("  Avg duplicate time: %d us (%.2f ms)" % [avg_dup_us, avg_dup_us / 1000.0])
		_log("  Pre-warm pending: %d models" % loading_stats.get("prewarm_pending_count", 0))

	# BSA cache stats
	var bsa_cache_stats: Dictionary = BSAManager.get_cache_stats()
	_log("")
	_log("[b]BSA Extraction Cache[/b]")
	_log("  Size: %.1f MB (%d files)" % [
		bsa_cache_stats.get("cache_size_mb", 0.0),
		bsa_cache_stats.get("cached_files", 0)
	])
	_log("  Hits: %d | Misses: %d | Rate: %.1f%%" % [
		bsa_cache_stats.get("cache_hits", 0),
		bsa_cache_stats.get("cache_misses", 0),
		bsa_cache_stats.get("hit_rate", 0.0) * 100.0
	])

	var slowest_models: Array = report.get("slowest_models", [])
	if not slowest_models.is_empty():
		_log("")
		_log("[b]Slowest Models[/b]")
		for model: Dictionary in slowest_models:
			var avg_ms: float = model.get("avg_ms", 0.0)
			var model_path: String = model.get("path", "")
			var model_count: int = model.get("count", 0)
			_log("  %.2f ms - %s (x%d)" % [avg_ms, model_path.get_file(), model_count])

	# Streaming profiler data
	if _streaming_manager and _streaming_manager.has_method("get_streaming_profiler"):
		var streaming_profiler: StreamingProfiler = _streaming_manager.get_streaming_profiler()
		if streaming_profiler:
			_log("")
			_log("[b]Streaming Pipeline Breakdown[/b]")
			var sections: Dictionary = streaming_profiler.get_all_sections()

			var section_list: Array = []
			for name: String in sections:
				var data: Dictionary = sections[name]
				section_list.append({"name": name, "data": data})
			section_list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				return a.data.last_ms > b.data.last_ms
			)

			for s: Dictionary in section_list:
				var name: String = s.name
				var data: Dictionary = s.data
				var flag := " [color=red]◀ SLOW[/color]" if data.last_ms > 16.0 else ""
				_log("  %s: %.2f ms (avg %.2f, max %.2f)%s" % [
					name, data.last_ms, data.avg_ms, data.max_ms, flag
				])

			var frame_percs: Dictionary = streaming_profiler.get_frame_percentiles()
			_log("")
			_log("[b]Streaming Frame Times[/b]")
			_log("  P50: %.2f ms | P95: %.2f ms | P99: %.2f ms | Max: %.2f ms" % [
				frame_percs.p50, frame_percs.p95, frame_percs.p99, frame_percs.max
			])

	_log("[b]==============================[/b]")

	# Also print full report to console for easy copying
	Log.debug("debug", JSON.stringify(report, "  "))
