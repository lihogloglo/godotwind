## LOD and impostor debug commands for the developer console.
##
## Extracted from world_explorer.gd. Provides diagnostic commands for
## inspecting and fixing LOD visibility_range configuration on loaded cells.
##
## Usage:
## [codeblock]
## var lod_cmds := LodDebugCommands.new(native_streaming_manager)
## lod_cmds.register_commands(console)
## [/codeblock]
class_name LodDebugCommands
extends RefCounted

var _streaming_manager: Node3D = null


func _init(streaming_manager: Node3D) -> void:
	_streaming_manager = streaming_manager


## Register all LOD/impostor debug commands with the console
func register_commands(console: Console) -> void:
	console.register_command(
		"impostor_stats",
		_cmd_impostor_stats,
		"Show impostor renderer statistics",
		"debug"
	)
	console.register_command(
		"lod_check",
		_cmd_lod_check,
		"Check LOD configuration on loaded meshes (shows first 20 with issues)",
		"debug"
	)
	console.register_command(
		"lod_dump",
		_cmd_lod_dump,
		"Dump visibility_range config for a specific node name pattern",
		"debug"
	)
	console.register_command(
		"lod_stats",
		_cmd_lod_stats,
		"Show detailed LOD statistics by tier (LOD0/1/2/3) with configuration state",
		"debug"
	)
	console.register_command(
		"lod_fix",
		_cmd_lod_fix,
		"Force reconfigure visibility_range on all loaded cells",
		"debug"
	)
	console.register_command(
		"lod_materials",
		_cmd_lod_materials,
		"Check materials on LOD nodes (diagnose white LODs)",
		"debug"
	)
	console.register_command(
		"mid_batch_stats",
		_cmd_mid_batch_stats,
		"Show MID-tier MultiMesh batch pool statistics",
		"debug"
	)
	console.register_command(
		"visibility_gaps",
		_cmd_visibility_gaps,
		"Diagnose objects that may be invisible at the camera's current distance",
		"debug"
	)
	console.register_command(
		"streaming_diag",
		_cmd_streaming_diag,
		"Show detailed streaming pipeline status (queues, promotions, deferred)",
		"debug"
	)
	console.register_command(
		"tex_audit",
		_cmd_tex_audit,
		"Audit textures on loaded objects: find materials with color but no texture",
		"debug"
	)


func _cmd_impostor_stats(_args: Dictionary) -> String:
	if _streaming_manager and _streaming_manager._impostor_renderer:
		var stats = _streaming_manager._impostor_renderer.get_stats()
		var result = "Impostor Stats:\n"
		for key in stats:
			result += "  %s: %s\n" % [key, stats[key]]
		return result
	return "Impostor renderer not available"


## Console command: lod_check - verify LOD nodes have correct visibility_range
func _cmd_lod_check(_args: Dictionary) -> String:
	if not _streaming_manager:
		return "Native streaming manager not available"

	var results: Array[String] = []
	var counters := {"total": 0, "bad": 0, "good": 0}

	for grid: Vector2i in _streaming_manager._loaded_cells:
		var cell_node: Node3D = _streaming_manager._loaded_cells[grid]
		if cell_node:
			_check_lod_nodes_recursive(cell_node, results, counters)

	var output := "LOD Configuration Check:\n"
	output += "  Total LOD nodes found: %d\n" % counters["total"]
	output += "  Correctly configured: %d\n" % counters["good"]
	output += "  Misconfigured (end=0): %d\n" % counters["bad"]

	if not results.is_empty():
		output += "\nFirst %d issues:\n" % mini(results.size(), 20)
		for i in mini(results.size(), 20):
			output += "  %s\n" % results[i]

	if counters["bad"] == 0 and counters["total"] > 0:
		output += "\n[OK] All LOD nodes properly configured!"
	elif counters["total"] == 0:
		output += "\n[WARN] No LOD nodes found in loaded cells. Check prebaking."

	return output


func _check_lod_nodes_recursive(node: Node, results: Array[String], counters: Dictionary) -> void:
	if node is GeometryInstance3D:
		var geo := node as GeometryInstance3D
		var node_name: String = node.name

		if node_name.ends_with("_LOD1") or node_name.ends_with("_LOD2") or node_name.ends_with("_LOD3"):
			counters["total"] += 1

			if geo.visibility_range_end == 0.0:
				counters["bad"] += 1
				results.append("%s: begin=%.0f, end=%.0f [BAD - end=0 means always visible]" % [
					node_name, geo.visibility_range_begin, geo.visibility_range_end
				])
			else:
				counters["good"] += 1

	for child in node.get_children():
		_check_lod_nodes_recursive(child, results, counters)


## Console command: lod_dump - dump visibility_range for nodes matching pattern
func _cmd_lod_dump(args: Dictionary) -> String:
	if not _streaming_manager:
		return "Native streaming manager not available"

	var pattern: String = args.get("pattern", "")
	if pattern.is_empty():
		return "Usage: lod_dump <pattern>\nExample: lod_dump door"

	var results: Array[String] = []

	for grid: Vector2i in _streaming_manager._loaded_cells:
		var cell_node: Node3D = _streaming_manager._loaded_cells[grid]
		if cell_node:
			_dump_matching_nodes_recursive(cell_node, pattern.to_lower(), results)

	if results.is_empty():
		return "No nodes found matching '%s'" % pattern

	var output := "Nodes matching '%s' (max 30):\n" % pattern
	for i in mini(results.size(), 30):
		output += "%s\n" % results[i]

	return output


func _dump_matching_nodes_recursive(node: Node, pattern: String, results: Array[String]) -> void:
	if node is GeometryInstance3D:
		var geo := node as GeometryInstance3D
		var node_name: String = node.name

		if node_name.to_lower().contains(pattern):
			var fade_mode := "DISABLED"
			match geo.visibility_range_fade_mode:
				GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF:
					fade_mode = "SELF"
				GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES:
					fade_mode = "DEPS"

			results.append("%s: begin=%.0f, end=%.0f, fade=%s, visible=%s" % [
				node_name,
				geo.visibility_range_begin,
				geo.visibility_range_end,
				fade_mode,
				geo.visible
			])

	for child in node.get_children():
		_dump_matching_nodes_recursive(child, pattern, results)


## Console command: lod_stats - detailed LOD statistics by tier
func _cmd_lod_stats(_args: Dictionary) -> String:
	if not _streaming_manager:
		return "Native streaming manager not available"

	const EXPECTED := {
		"lod0": {"begin": 0.0, "end": 150.0},
		"lod1": {"begin": 150.0, "end": 250.0},
		"lod2": {"begin": 250.0, "end": 375.0},
		"lod3": {"begin": 375.0, "end": 500.0},
	}

	var stats := {
		"lod0_correct": 0, "lod0_bad": 0, "lod0_total": 0,
		"lod1_correct": 0, "lod1_bad": 0, "lod1_total": 0,
		"lod2_correct": 0, "lod2_bad": 0, "lod2_total": 0,
		"lod3_correct": 0, "lod3_bad": 0, "lod3_total": 0,
		"other_meshes": 0,
	}
	var examples: Dictionary = {"lod0_bad": [], "lod1_bad": [], "lod2_bad": [], "lod3_bad": []}

	for grid: Vector2i in _streaming_manager._loaded_cells:
		var cell_node: Node3D = _streaming_manager._loaded_cells[grid]
		if cell_node:
			_collect_lod_stats_recursive(cell_node, stats, examples, EXPECTED)

	var output := "=== LOD Statistics ===\n\n"

	output += "LOD0 (NEAR 0-150m):\n"
	output += "  Total: %d, Correct: %d, Bad: %d\n" % [
		stats["lod0_total"], stats["lod0_correct"], stats["lod0_bad"]]
	if not examples["lod0_bad"].is_empty():
		output += "  Bad examples: %s\n" % ", ".join(examples["lod0_bad"].slice(0, 3))

	output += "\nLOD1 (MID 150-250m):\n"
	output += "  Total: %d, Correct: %d, Bad: %d\n" % [
		stats["lod1_total"], stats["lod1_correct"], stats["lod1_bad"]]
	if not examples["lod1_bad"].is_empty():
		output += "  Bad examples: %s\n" % ", ".join(examples["lod1_bad"].slice(0, 3))

	output += "\nLOD2 (MID 250-375m):\n"
	output += "  Total: %d, Correct: %d, Bad: %d\n" % [
		stats["lod2_total"], stats["lod2_correct"], stats["lod2_bad"]]
	if not examples["lod2_bad"].is_empty():
		output += "  Bad examples: %s\n" % ", ".join(examples["lod2_bad"].slice(0, 3))

	output += "\nLOD3 (MID 375-500m):\n"
	output += "  Total: %d, Correct: %d, Bad: %d\n" % [
		stats["lod3_total"], stats["lod3_correct"], stats["lod3_bad"]]
	if not examples["lod3_bad"].is_empty():
		output += "  Bad examples: %s\n" % ", ".join(examples["lod3_bad"].slice(0, 3))

	output += "\nOther meshes (no LOD suffix): %d\n" % stats["other_meshes"]

	var total_bad: int = int(stats["lod0_bad"]) + int(stats["lod1_bad"]) + int(stats["lod2_bad"]) + int(stats["lod3_bad"])
	if total_bad == 0:
		output += "\n[OK] All LOD nodes properly configured!"
	else:
		output += "\n[WARN] %d nodes with incorrect visibility_range. Run 'lod_fix' to repair." % total_bad

	return output


func _collect_lod_stats_recursive(node: Node, stats: Dictionary, examples: Dictionary, expected: Dictionary) -> void:
	if node is GeometryInstance3D:
		var geo := node as GeometryInstance3D
		var node_name: String = node.name.to_lower()

		var lod_type := ""
		if node_name.ends_with("_lod1"):
			lod_type = "lod1"
		elif node_name.ends_with("_lod2"):
			lod_type = "lod2"
		elif node_name.ends_with("_lod3"):
			lod_type = "lod3"
		elif node is MeshInstance3D:
			var has_lod_sibling := false
			if node.get_parent():
				for sibling in node.get_parent().get_children():
					var sname: String = sibling.name.to_lower()
					if sname.ends_with("_lod1") or sname.ends_with("_lod2") or sname.ends_with("_lod3"):
						has_lod_sibling = true
						break
			if has_lod_sibling:
				lod_type = "lod0"
			else:
				stats["other_meshes"] += 1

		if not lod_type.is_empty():
			stats[lod_type + "_total"] += 1
			var exp: Dictionary = expected.get(lod_type, {"begin": 0.0, "end": 0.0})

			var begin_ok := absf(geo.visibility_range_begin - exp["begin"]) < 1.0
			var end_ok := absf(geo.visibility_range_end - exp["end"]) < 1.0

			if begin_ok and end_ok:
				stats[lod_type + "_correct"] += 1
			else:
				stats[lod_type + "_bad"] += 1
				var bad_list: Array = examples[lod_type + "_bad"]
				if bad_list.size() < 5:
					bad_list.append("%s (%.0f-%.0f)" % [node.name, geo.visibility_range_begin, geo.visibility_range_end])

	for child in node.get_children():
		_collect_lod_stats_recursive(child, stats, examples, expected)


## Console command: lod_fix - force reconfigure visibility_range on all loaded cells
func _cmd_lod_fix(_args: Dictionary) -> String:
	if not _streaming_manager:
		return "Native streaming manager not available"

	var fixed_count := 0
	var cell_count := 0

	for grid: Vector2i in _streaming_manager._loaded_cells:
		var cell_node: Node3D = _streaming_manager._loaded_cells[grid]
		if cell_node:
			cell_count += 1
			fixed_count += _fix_lod_nodes_recursive(cell_node)

	return "Reconfigured %d LOD nodes in %d cells.\nRun 'lod_stats' to verify." % [fixed_count, cell_count]


func _fix_lod_nodes_recursive(node: Node) -> int:
	var fixed := 0

	if node is GeometryInstance3D:
		var geo := node as GeometryInstance3D
		var node_name: String = node.name.to_lower()

		if node_name.ends_with("_lod1"):
			geo.visibility_range_begin = 150.0
			geo.visibility_range_end = 250.0
			geo.visibility_range_begin_margin = 50.0
			geo.visibility_range_end_margin = 50.0
			geo.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES
			fixed += 1
		elif node_name.ends_with("_lod2"):
			geo.visibility_range_begin = 250.0
			geo.visibility_range_end = 375.0
			geo.visibility_range_begin_margin = 50.0
			geo.visibility_range_end_margin = 50.0
			geo.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES
			fixed += 1
		elif node_name.ends_with("_lod3"):
			geo.visibility_range_begin = 375.0
			geo.visibility_range_end = 500.0
			geo.visibility_range_begin_margin = 50.0
			geo.visibility_range_end_margin = 50.0
			geo.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES
			fixed += 1
		elif node is MeshInstance3D:
			var has_lod_sibling := false
			if node.get_parent():
				for sibling in node.get_parent().get_children():
					var sname: String = sibling.name.to_lower()
					if sname.ends_with("_lod1") or sname.ends_with("_lod2") or sname.ends_with("_lod3"):
						has_lod_sibling = true
						break
			if has_lod_sibling:
				geo.visibility_range_begin = 0.0
				geo.visibility_range_end = 150.0
				geo.visibility_range_begin_margin = 0.0
				geo.visibility_range_end_margin = 50.0
				geo.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES
				fixed += 1
			else:
				if geo.visibility_range_begin == 0.0 and geo.visibility_range_end == 0.0:
					geo.visibility_range_begin = 0.0
					geo.visibility_range_end = 150.0
					geo.visibility_range_begin_margin = 0.0
					geo.visibility_range_end_margin = 50.0
					geo.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
					fixed += 1

	for child in node.get_children():
		fixed += _fix_lod_nodes_recursive(child)

	return fixed


## Console command: lod_materials - diagnose white LODs
func _cmd_lod_materials(_args: Dictionary) -> String:
	if not _streaming_manager:
		return "Native streaming manager not available"

	var stats := {
		"lod_with_material": 0,
		"lod_without_material": 0,
		"lod0_with_material": 0,
		"lod0_without_material": 0,
	}
	var examples_no_mat: Array[String] = []
	var examples_with_mat: Array[String] = []

	for grid: Vector2i in _streaming_manager._loaded_cells:
		var cell_node: Node3D = _streaming_manager._loaded_cells[grid]
		if cell_node:
			_collect_lod_material_stats(cell_node, stats, examples_no_mat, examples_with_mat)

	var output := "=== LOD Material Statistics ===\n\n"
	output += "LOD nodes (LOD1/2/3):\n"
	output += "  With material: %d\n" % stats["lod_with_material"]
	output += "  Without material (WHITE): %d\n" % stats["lod_without_material"]

	output += "\nLOD0 nodes:\n"
	output += "  With material: %d\n" % stats["lod0_with_material"]
	output += "  Without material: %d\n" % stats["lod0_without_material"]

	if not examples_no_mat.is_empty():
		output += "\nExamples without material:\n"
		for ex in examples_no_mat.slice(0, 5):
			output += "  - %s\n" % ex

	if not examples_with_mat.is_empty():
		output += "\nExamples with material:\n"
		for ex in examples_with_mat.slice(0, 3):
			output += "  - %s\n" % ex

	return output


func _collect_lod_material_stats(node: Node, stats: Dictionary, no_mat: Array[String], with_mat: Array[String]) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var node_name: String = node.name.to_lower()
		var is_lod := node_name.ends_with("_lod1") or node_name.ends_with("_lod2") or node_name.ends_with("_lod3")

		var has_mat := false
		if mi.material_override:
			has_mat = true
		elif mi.mesh and mi.mesh.get_surface_count() > 0:
			var surf_mat := mi.mesh.surface_get_material(0)
			if surf_mat:
				has_mat = true

		if is_lod:
			if has_mat:
				stats["lod_with_material"] += 1
				if with_mat.size() < 5:
					with_mat.append(node.name)
			else:
				stats["lod_without_material"] += 1
				if no_mat.size() < 10:
					no_mat.append(node.name)
		else:
			var has_lod_sibling := false
			if node.get_parent():
				for sibling in node.get_parent().get_children():
					var sname: String = sibling.name.to_lower()
					if sname.ends_with("_lod1") or sname.ends_with("_lod2") or sname.ends_with("_lod3"):
						has_lod_sibling = true
						break
			if has_lod_sibling:
				if has_mat:
					stats["lod0_with_material"] += 1
				else:
					stats["lod0_without_material"] += 1

	for child in node.get_children():
		_collect_lod_material_stats(child, stats, no_mat, with_mat)


func _cmd_mid_batch_stats(_args: Dictionary) -> String:
	if not _streaming_manager or not _streaming_manager._static_renderer:
		return "MID-tier static renderer not available"

	var stats: Dictionary = _streaming_manager._static_renderer.get_stats()
	var output := "MID-Tier Static Renderer Stats (per-instance RS visibility_range):\n"
	output += "  Mesh types: %d\n" % stats.get("mesh_types", 0)
	output += "  Total instances: %d\n" % stats.get("total_instances", 0)
	output += "  Visible instances: %d\n" % stats.get("visible_instances", 0)
	output += "  LOD RS instances: %d\n" % stats.get("lod_instances", 0)
	return output


## Diagnose visibility gaps: find objects that should be visible but aren't
func _cmd_visibility_gaps(_args: Dictionary) -> String:
	if not _streaming_manager:
		return "Streaming manager not available"

	var camera := _streaming_manager.get_viewport().get_camera_3d()
	if not camera:
		return "No active camera"

	var cam_pos := camera.global_position
	var output := "=== VISIBILITY GAP DIAGNOSTIC ===\n"
	output += "Camera: %.0f, %.0f, %.0f\n" % [cam_pos.x, cam_pos.y, cam_pos.z]

	# Check NEAR Node3Ds in loaded cells
	var near_count := 0
	var near_invisible := 0
	var near_no_vis_range := 0
	var mid_rs_count := 0
	var promoted_count: int = _streaming_manager._promoted_objects.size()

	for grid: Vector2i in _streaming_manager._loaded_cells:
		var cell: Node3D = _streaming_manager._loaded_cells[grid]
		if not is_instance_valid(cell):
			continue
		for child in cell.get_children():
			if child is Node3D:
				var dist := cam_pos.distance_to(child.global_position)
				_check_node_visibility(child, dist, near_count, near_invisible, near_no_vis_range)

	# Check MID-tier RS instances
	var sr: Node3D = _streaming_manager._static_renderer
	if sr:
		var sr_stats: Dictionary = sr.get_stats()
		mid_rs_count = sr_stats.get("total_instances", 0)
		var lod_rs: int = sr_stats.get("lod_instances", 0)
		var vis_rs: int = sr_stats.get("visible_instances", 0)
		output += "\nMID RS Instances: %d total, %d LOD RIDs, %d visible\n" % [mid_rs_count, lod_rs, vis_rs]

	# Check deferred NEAR
	var deferred := 0
	if _streaming_manager._cell_manager:
		deferred = _streaming_manager._cell_manager.get_deferred_near_count()

	output += "NEAR Node3Ds: %d total, %d invisible, %d missing vis_range\n" % [near_count, near_invisible, near_no_vis_range]
	output += "Promoted (MID->NEAR): %d\n" % promoted_count
	output += "Deferred NEAR (waiting): %d\n" % deferred

	# Queue status
	output += "\nQueues:\n"
	output += "  Pending load: %d cells\n" % _streaming_manager._pending_load_queue.size()
	output += "  Async requests: %d\n" % _streaming_manager._async_requests.size()
	output += "  Unloading: %d cells\n" % _streaming_manager._unloading_cells.size()
	if _streaming_manager._cell_manager:
		output += "  Instantiation queue: %d\n" % _streaming_manager._cell_manager.get_instantiation_queue_size()

	return output


## Helper: check a node tree for visibility issues
func _check_node_visibility(node: Node, dist: float, near_count: int, near_invisible: int, near_no_vis_range: int) -> void:
	if node is GeometryInstance3D:
		near_count += 1
		var geo := node as GeometryInstance3D
		if not geo.visible:
			near_invisible += 1
		if geo.visibility_range_end == 0.0 and geo.visibility_range_begin == 0.0:
			near_no_vis_range += 1
	for child in node.get_children():
		_check_node_visibility(child, dist, near_count, near_invisible, near_no_vis_range)


## Detailed streaming pipeline diagnostic
func _cmd_streaming_diag(_args: Dictionary) -> String:
	if not _streaming_manager:
		return "Streaming manager not available"

	var s: Dictionary = _streaming_manager.get_stats()
	var output := "=== STREAMING PIPELINE DIAGNOSTIC ===\n"
	output += "Camera cell: %s\n" % str(s.get("camera_cell", "?"))
	output += "Loaded cells: %d\n" % s.get("loaded_cells", 0)
	output += "Total objects: %d\n" % s.get("total_objects", 0)
	output += "Frame budget: %.1fms\n" % s.get("frame_budget_ms", 0)
	output += "Frame overruns: %d\n" % s.get("frame_overrun_count", 0)
	output += "\nAsync Loading:\n"
	output += "  Queue: %d\n" % s.get("instantiation_queue", 0)
	output += "  Pending conversions: %d\n" % s.get("pending_conversions", 0)
	output += "  Pending disk loads: %d\n" % s.get("pending_disk_loads", 0)
	output += "  Load queue: %d cells\n" % s.get("load_queue_size", 0)
	output += "  Async requests: %d\n" % s.get("async_requests", 0)
	output += "\nTier Transitions:\n"
	output += "  MID->NEAR promotions: %d\n" % s.get("mid_to_near_promotions", 0)
	output += "  NEAR->MID demotions: %d\n" % s.get("near_to_mid_demotions", 0)
	output += "\nMID Tier:\n"
	output += "  RS instances: %d\n" % s.get("mid_instances", 0)
	output += "  Visible: %d\n" % s.get("mid_visible", 0)
	output += "  Mesh types: %d\n" % s.get("mid_mesh_types", 0)

	# Add deferred NEAR info
	if _streaming_manager._cell_manager:
		var cm_stats: Dictionary = _streaming_manager._cell_manager.get_stats()
		output += "\nDeferred NEAR:\n"
		output += "  Waiting: %d\n" % cm_stats.get("deferred_near_count", 0)
		output += "  Instantiated: %d\n" % cm_stats.get("deferred_near_instantiated", 0)
		output += "  MID filtered: %d\n" % cm_stats.get("mid_filtered", 0)
		output += "  MID tier RS: %d\n" % cm_stats.get("mid_tier_instances", 0)
		output += "  MID promotions: %d\n" % cm_stats.get("mid_promotions", 0)

	return output


## Console command: tex_audit — find materials with color but no texture in loaded cells
func _cmd_tex_audit(_args: Dictionary) -> String:
	if not _streaming_manager:
		return "Streaming manager not available"

	var stats := {
		"total_meshes": 0,
		"with_texture": 0,
		"color_only": 0,
		"no_material": 0,
		"magenta_fallback": 0,
	}
	var color_only_examples: Array[String] = []
	var no_mat_examples: Array[String] = []

	for grid: Vector2i in _streaming_manager._loaded_cells:
		var cell_node: Node3D = _streaming_manager._loaded_cells[grid]
		if cell_node:
			_audit_textures_recursive(cell_node, stats, color_only_examples, no_mat_examples)

	var output := "=== TEXTURE AUDIT ===\n\n"
	output += "Total MeshInstance3D: %d\n" % stats["total_meshes"]
	output += "  With texture:      %d\n" % stats["with_texture"]
	output += "  Color only (no tex): %d  <-- white/brownish objects\n" % stats["color_only"]
	output += "  No material at all:  %d\n" % stats["no_material"]
	output += "  Magenta fallback:    %d\n" % stats["magenta_fallback"]

	if not color_only_examples.is_empty():
		output += "\nColor-only examples (first 10):\n"
		for ex in color_only_examples.slice(0, 10):
			output += "  %s\n" % ex

	if not no_mat_examples.is_empty():
		output += "\nNo-material examples (first 5):\n"
		for ex in no_mat_examples.slice(0, 5):
			output += "  %s\n" % ex

	return output


func _audit_textures_recursive(node: Node, stats: Dictionary, color_only: Array[String], no_mat: Array[String]) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		stats["total_meshes"] += 1

		# Get the effective material using 3-source fallback
		var mat: Material = mi.material_override
		if mat == null and mi.get_surface_override_material_count() > 0:
			mat = mi.get_surface_override_material(0)
		if mat == null and mi.mesh and mi.mesh.get_surface_count() > 0:
			mat = mi.mesh.surface_get_material(0)

		if mat == null:
			stats["no_material"] += 1
			if no_mat.size() < 10:
				no_mat.append("%s (parent: %s)" % [mi.name, mi.get_parent().name if mi.get_parent() else "?"])
		elif mat is StandardMaterial3D:
			var std := mat as StandardMaterial3D
			if std.albedo_texture != null:
				# Check for magenta fallback (8x8 checkerboard)
				if std.albedo_texture is ImageTexture:
					var img := (std.albedo_texture as ImageTexture).get_image()
					if img and img.get_width() == 8 and img.get_height() == 8:
						stats["magenta_fallback"] += 1
					else:
						stats["with_texture"] += 1
				else:
					stats["with_texture"] += 1
			else:
				# Has material but no texture — this is the white/brownish issue
				stats["color_only"] += 1
				if color_only.size() < 20:
					color_only.append("%s  color=%s (parent: %s)" % [
						mi.name,
						std.albedo_color.to_html(),
						mi.get_parent().name if mi.get_parent() else "?"
					])

	for child in node.get_children():
		_audit_textures_recursive(child, stats, color_only, no_mat)
