## Stats collection and panel label updates for WorldExplorer.
##
## Extracted from world_explorer.gd (Session 6). Gathers performance metrics
## from profiler, streaming manager, and terrain, then pushes values to the
## foldable panel labels. All data is read-only — no world state is modified.
##
## Usage:
## [codeblock]
## var stats := StatsCollector.new(panels)
## stats.set_profiler(profiler)
## stats.set_terrain(terrain_3d)
## stats.set_world_streaming_manager(wsm)
## stats.update({"camera_mode_str": "Fly", "view_distance": 5})
## [/codeblock]
class_name StatsCollector
extends RefCounted

# ── References (set via setters as they become available) ──

var _panels: ExplorerPanels = null
var _profiler: PerformanceProfiler = null
var _terrain: Terrain3D = null
var _world_streaming_manager: Node3D = null


## Create the stats collector.
## [param panels] ExplorerPanels reference for updating UI labels.
func _init(panels: ExplorerPanels) -> void:
	_panels = panels


## Set the profiler reference.
func set_profiler(p: PerformanceProfiler) -> void:
	_profiler = p


## Set the terrain reference.
func set_terrain(t: Terrain3D) -> void:
	_terrain = t


## Set the world streaming manager reference.
func set_world_streaming_manager(wsm: Node3D) -> void:
	_world_streaming_manager = wsm


## Collect stats from all sources and update panel labels.
## [param state] Dictionary with world_explorer state:
##   camera_mode_str: String, view_distance: int
func update(state: Dictionary[String, Variant]) -> void:
	var stats: Dictionary = {}
	if _world_streaming_manager:
		stats = _world_streaming_manager.get_stats()

	# Get profiler data
	var fps := 0.0
	var frame_ms := 0.0
	var draw_calls := 0
	var primitives := 0
	var mem_mb := 0.0
	var p95_ms := 0.0

	if _profiler:
		fps = _profiler.get_fps()
		frame_ms = _profiler.get_avg_frame_time_ms()
		var render: Dictionary = _profiler.get_render_stats()
		var render_draw_calls: int = render.draw_calls
		var render_primitives: int = render.primitives
		draw_calls = render_draw_calls
		primitives = render_primitives
		var mem: Dictionary = _profiler.get_memory_stats()
		var static_mem: float = mem.static_memory_mb
		mem_mb = static_mem
		var percentiles: Dictionary = _profiler.get_frame_time_percentiles()
		var p95_val: float = percentiles.p95
		p95_ms = p95_val

	# Get terrain stats
	var total_regions := 0
	if _terrain and _terrain.data:
		total_regions = _terrain.data.get_region_count()

	var camera_mode_str: String = state.get("camera_mode_str", "Fly")
	var camera_cell: Vector2i = stats.get("camera_cell", Vector2i(0, 0))
	var view_distance: int = state.get("view_distance", 5)

	_update_panel_labels(fps, frame_ms, p95_ms, draw_calls, primitives, mem_mb,
						  stats, total_regions, camera_mode_str, camera_cell, view_distance)


## Update labels in foldable panels.
func _update_panel_labels(fps: float, frame_ms: float, p95_ms: float, draw_calls: int,
						   primitives: int, mem_mb: float, stats: Dictionary,
						   total_regions: int, camera_mode_str: String, camera_cell: Vector2i,
						   view_distance: int) -> void:
	if not _panels:
		return

	# Update performance panel
	if _panels.performance_panel:
		var content := _panels.performance_panel.get_content_container()
		var fps_label: Label = content.get_node_or_null("FPSLabel")
		if fps_label:
			fps_label.text = "FPS: %.1f (%.2f ms avg)" % [fps, frame_ms]
		var timing_label: Label = content.get_node_or_null("TimingLabel")
		if timing_label:
			timing_label.text = "P95: %.2f ms" % p95_ms
		var render_label: Label = content.get_node_or_null("RenderLabel")
		if render_label:
			render_label.text = "Draw: %d | Tris: %.1fk" % [draw_calls, primitives / 1000.0]
		var memory_label: Label = content.get_node_or_null("MemoryLabel")
		if memory_label:
			memory_label.text = "Memory: %.1f MB" % mem_mb

	# Update navigation panel
	if _panels.navigation_panel:
		var content := _panels.navigation_panel.get_content_container()
		var camera_label: Label = content.get_node_or_null("CameraLabel")
		if camera_label:
			camera_label.text = "Cell: (%d, %d) | Mode: %s [P]" % [camera_cell.x, camera_cell.y, camera_mode_str]
		var dist_label: Label = content.get_node_or_null("DistLabel")
		if dist_label:
			dist_label.text = "%d cells" % view_distance

	# Update terrain panel
	if _panels.terrain_panel:
		var content := _panels.terrain_panel.get_content_container()
		var terrain_label: Label = content.get_node_or_null("TerrainLabel")
		if terrain_label:
			terrain_label.text = "Regions loaded: %d" % total_regions
		# Update preprocess status
		var status_label_panel: Label = content.get_node_or_null("PreprocessStatusLabel")
		if status_label_panel:
			var terrain_data_dir := SettingsManager.get_terrain_path()
			var has_terrain := DirAccess.dir_exists_absolute(terrain_data_dir)
			if has_terrain:
				status_label_panel.text = "Status: Preprocessed"
				status_label_panel.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
			else:
				status_label_panel.text = "Status: Not preprocessed"
				status_label_panel.add_theme_color_override("font_color", Color(1.0, 0.5, 0.3))

	# Update debug panel
	if _panels.debug_panel:
		var content := _panels.debug_panel.get_content_container()
		var debug_label: Label = content.get_node_or_null("DebugInfoLabel")
		if debug_label:
			var loaded_cells: int = stats.get("loaded_cells", 0)
			var queue_size: int = stats.get("load_queue_size", 0)
			var async_pending: int = stats.get("async_pending", 0)
			debug_label.text = "Cells: %d | Queue: %d | Async: %d" % [loaded_cells, queue_size, async_pending]

		# Update ODM stats
		var odm_label: Label = content.get_node_or_null("ODMLabel")
		if odm_label:
			var odm_stats: Dictionary = stats.get("object_distance_manager", {})
			var total_obj: int = odm_stats.get("total_objects", 0)
			var near_obj: int = odm_stats.get("near_visible", 0)
			var mid_obj: int = odm_stats.get("mid_visible", 0)
			var far_obj: int = odm_stats.get("far_visible", 0)
			odm_label.text = "ODM: %d tracked | NEAR: %d MID: %d FAR: %d" % [total_obj, near_obj, mid_obj, far_obj]

		# Update streaming profiler summary
		var profiler_label_node: Label = content.get_node_or_null("ProfilerLabel")
		if profiler_label_node and _world_streaming_manager and _world_streaming_manager.has_method("get_streaming_profiler"):
			var sp: StreamingProfiler = _world_streaming_manager.get_streaming_profiler()
			if sp:
				profiler_label_node.text = sp.get_compact_summary()
			else:
				profiler_label_node.text = "Profiler: not initialized"
