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

const DU := preload("res://src/core/world/distance_utils.gd")

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
	console.register_command(
		"look",
		_cmd_look,
		"Inspect mesh under crosshair: LOD level, material, visibility_range (no collision needed)",
		"debug"
	)
	console.register_command(
		"mid_lod_textures",
		_cmd_mid_lod_textures,
		"Audit MID-tier RS LOD materials: find models with textureless LODs (plain colored buildings)",
		"debug"
	)
	console.register_command(
		"reload_compare",
		_cmd_reload_compare,
		"Compare NEAR-tier object state: shows LOD0 visibility, cull_mode, material for loaded buildings",
		"debug"
	)
	console.register_command(
		"lod_baseline_dump",
		_cmd_lod_baseline_dump,
		"Dump combined LOD+streaming diagnostics for the current camera position to user://lod_baselines/<label>.txt. Used for LOD refactor B-wide before/after comparison (see docs/audit/LOD_REFACTOR_B_WIDE.md).",
		"debug",
		PackedStringArray(),
		[CommandRegistry.ParameterInfo.new("label", TYPE_STRING, "Baseline label (e.g. vivec_canton)")] as Array[CommandRegistry.ParameterInfo]
	)

	# Post-B-wide refactor: screen-space LOD tuning commands.
	console.register_command(
		"lod_threshold",
		_cmd_lod_threshold,
		"Get or set viewport.mesh_lod_threshold (pixels). Lower = higher quality, higher = more aggressive LOD. 1.0 is Godot default.",
		"debug",
		PackedStringArray(),
		[CommandRegistry.ParameterInfo.new("value", TYPE_FLOAT, "Threshold in pixels (omit to query)", true)] as Array[CommandRegistry.ParameterInfo]
	)
	console.register_command(
		"lod_bias_global",
		_cmd_lod_bias_global,
		"Set default lod_bias on all currently-loaded static MID-tier instances. >1.0 keeps higher detail further out, <1.0 accelerates LOD drops.",
		"debug",
		PackedStringArray(),
		[CommandRegistry.ParameterInfo.new("bias", TYPE_FLOAT, "LOD bias (default 1.0)")] as Array[CommandRegistry.ParameterInfo]
	)
	console.register_command(
		"lod_info",
		_cmd_lod_info,
		"Print post-B-wide LOD pipeline status: viewport threshold, mesh type count, instance count, how many mesh types carry an embedded LOD chain.",
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

	# Audit RS instances (MID tier) if static renderer is available
	if _streaming_manager.get("_static_renderer"):
		var rs_stats := _audit_rs_materials(_streaming_manager._static_renderer)
		output += "\n=== RS INSTANCE MATERIAL AUDIT (MID tier) ===\n"
		output += "Mesh types registered: %d\n" % rs_stats.total_types
		output += "  With texture:        %d\n" % rs_stats.textured
		output += "  Color only (no tex): %d\n" % rs_stats.color_only
		output += "  No material:         %d  <-- uses mesh default (may be white)\n" % rs_stats.no_material
		if not rs_stats.no_mat_types.is_empty():
			output += "\nNo-material RS types (first 10):\n"
			for t in rs_stats.no_mat_types.slice(0, 10):
				output += "  %s\n" % t
		if not rs_stats.color_only_types.is_empty():
			output += "\nColor-only RS types (first 10):\n"
			for t in rs_stats.color_only_types.slice(0, 10):
				output += "  %s\n" % t

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


## Audit RS instance materials in the static renderer (MID tier)
## Returns dict with texture/material stats for registered mesh types
func _audit_rs_materials(renderer: Node3D) -> Dictionary:
	var result := {
		"total_types": 0,
		"textured": 0,
		"color_only": 0,
		"no_material": 0,
		"no_mat_types": [] as Array[String],
		"color_only_types": [] as Array[String],
	}
	if not renderer or not ("_mesh_types" in renderer):
		return result

	for type_name: String in renderer._mesh_types:
		var mt: Variant = renderer._mesh_types[type_name]
		result.total_types += 1

		var has_mat := false
		var has_tex := false

		# Check primary material (whole-mesh override)
		if mt.material_resource:
			has_mat = true
			if mt.material_resource is StandardMaterial3D:
				has_tex = (mt.material_resource as StandardMaterial3D).albedo_texture != null

		# Check per-surface materials
		if not has_mat and not mt.surface_materials.is_empty():
			for sm: Material in mt.surface_materials:
				if sm:
					has_mat = true
					if sm is StandardMaterial3D and (sm as StandardMaterial3D).albedo_texture:
						has_tex = true

		if has_tex:
			result.textured += 1
		elif has_mat:
			result.color_only += 1
			if result.color_only_types.size() < 20:
				result.color_only_types.append(type_name)
		else:
			result.no_material += 1
			if result.no_mat_types.size() < 20:
				result.no_mat_types.append(type_name)

	return result


## Console command: look — inspect mesh under camera crosshair (no collision needed)
## Uses ray-to-center distance with angular weighting to pick the best match
func _cmd_look(_args: Dictionary) -> String:
	if not _streaming_manager:
		return "Streaming manager not available"

	var viewport: Viewport = _streaming_manager.get_viewport()
	if not viewport:
		return "No viewport"
	var camera: Camera3D = viewport.get_camera_3d()
	if not camera:
		return "No camera available"

	var ray_origin := camera.global_position
	var ray_dir := -camera.global_basis.z  # Camera forward

	# Search all loaded cell objects
	var best: Dictionary = {"node": null, "score": INF}
	for grid: Vector2i in _streaming_manager._loaded_cells:
		var cell_node: Node3D = _streaming_manager._loaded_cells[grid]
		if cell_node:
			_find_mesh_on_ray(cell_node, ray_origin, ray_dir, 300.0, best)

	if not best.node:
		return "No mesh found in crosshair direction (within 300m)"

	return _format_mesh_info(best.node as MeshInstance3D, ray_origin)


## Recursively find the MeshInstance3D closest to the camera ray
func _find_mesh_on_ray(node: Node, origin: Vector3, dir: Vector3, max_dist: float, best: Dictionary) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.visible and mi.mesh:
			var center := mi.global_transform.origin
			# Get mesh center offset (approximate — use AABB center)
			var local_center := mi.get_aabb().get_center()
			if local_center != Vector3.ZERO:
				center = mi.global_transform * local_center

			var to_mesh := center - origin
			var along := to_mesh.dot(dir)
			if along > 0.5 and along < max_dist:
				# Perpendicular distance from mesh center to ray
				var closest_on_ray := origin + dir * along
				var perp_dist := center.distance_to(closest_on_ray)
				# Score: angular offset (radians) — smaller is better
				var angular := perp_dist / along if along > 0.0 else INF
				# Only consider meshes within ~5 degree cone (0.087 rad)
				if angular < 0.087 and angular < best.score:
					best.node = mi
					best.score = angular

	for child in node.get_children():
		_find_mesh_on_ray(child, origin, dir, max_dist, best)


## Format detailed info about a picked MeshInstance3D
func _format_mesh_info(mi: MeshInstance3D, cam_pos: Vector3) -> String:
	var lines: PackedStringArray = []
	lines.append("=== MESH INSPECT (look) ===")
	lines.append("")

	# Node identity
	lines.append("Node: %s" % mi.name)
	var parent := mi.get_parent()
	if parent:
		lines.append("Parent: %s" % parent.name)
		# Walk up for cell/model info
		var current: Node = parent
		while current:
			if current.has_meta("model_path"):
				lines.append("Model: %s" % str(current.get_meta("model_path")))
				break
			if current.has_meta("cell_ref_id"):
				lines.append("Ref ID: %s" % str(current.get_meta("cell_ref_id")))
			current = current.get_parent()

	# Distance
	var dist := cam_pos.distance_to(mi.global_position)
	lines.append("Distance: %.1fm" % dist)

	# LOD level detection
	var lod_level := _detect_lod_level(mi)
	lines.append("LOD level: %s" % lod_level)

	# Visibility range
	var vr_begin := mi.visibility_range_begin
	var vr_end := mi.visibility_range_end
	var vr_margin := mi.visibility_range_end_margin
	var fade_mode := mi.visibility_range_fade_mode
	var fade_str := "DISABLED"
	if fade_mode == GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF:
		fade_str = "FADE_SELF"
	elif fade_mode == GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES:
		fade_str = "FADE_DEPENDENCIES"
	lines.append("Visibility: begin=%.0f end=%.0f margin=%.0f fade=%s" % [vr_begin, vr_end, vr_margin, fade_str])

	# Material info
	var mat: Material = mi.material_override
	var mat_source := "material_override"
	if mat == null and mi.mesh and mi.mesh.get_surface_count() > 0:
		mat = mi.get_surface_override_material(0)
		mat_source = "surface_override(0)"
	if mat == null and mi.mesh and mi.mesh.get_surface_count() > 0:
		mat = mi.mesh.surface_get_material(0)
		mat_source = "mesh_surface(0)"
	if mat == null:
		mat_source = "NONE"

	lines.append("")
	lines.append("Material source: %s" % mat_source)
	if mat is StandardMaterial3D:
		var std := mat as StandardMaterial3D
		var tex_name := "NONE"
		if std.albedo_texture:
			tex_name = std.albedo_texture.resource_path
			if tex_name.is_empty():
				tex_name = "embedded (%dx%d)" % [
					std.albedo_texture.get_width() if std.albedo_texture.get_width() > 0 else 0,
					std.albedo_texture.get_height() if std.albedo_texture.get_height() > 0 else 0
				]
		lines.append("Type: StandardMaterial3D")
		lines.append("Albedo color: %s" % std.albedo_color.to_html())
		lines.append("Albedo texture: %s" % tex_name)
		lines.append("Transparency: %s" % _transparency_name(std.transparency))
	elif mat is ShaderMaterial:
		var sm := mat as ShaderMaterial
		var spawn_val: Variant = sm.get_shader_parameter("spawn_time")
		if spawn_val != null:
			var dur_val: Variant = sm.get_shader_parameter("fade_duration")
			var dur: float = float(dur_val) if dur_val != null else 0.3
			var age: float = float(Time.get_ticks_msec()) / 1000.0 - float(spawn_val)
			var progress: float = (clamp(age / dur, 0.0, 1.0) if dur > 0.0 else 1.0)
			lines.append("Type: FADE ShaderMaterial (progress=%.3f, spawn_time=%.2f)" % [progress, float(spawn_val)])
		else:
			lines.append("Type: ShaderMaterial (custom)")
	elif mat:
		lines.append("Type: %s" % mat.get_class())
	else:
		lines.append("Type: NO MATERIAL — will render white/default")

	# Mesh info
	if mi.mesh:
		lines.append("")
		lines.append("Mesh surfaces: %d" % mi.mesh.get_surface_count())
		lines.append("Mesh AABB: %s" % str(mi.get_aabb()))

	return "\n".join(lines)


## Detect LOD level from node name and parent context
func _detect_lod_level(mi: MeshInstance3D) -> String:
	var name_lower: String = mi.name.to_lower()

	# Check for LOD suffix in node name
	if name_lower.ends_with("_lod4") or name_lower.ends_with("_lod3"):
		return "LOD3/4 (very low detail)"
	if name_lower.ends_with("_lod2"):
		return "LOD2 (low detail)"
	if name_lower.ends_with("_lod1"):
		return "LOD1 (medium detail)"
	if "_lod" in name_lower:
		var lod_idx := name_lower.find("_lod")
		var suffix := name_lower.substr(lod_idx)
		return "LOD (%s)" % suffix

	# Check parent name for LOD indicators
	var mi_parent := mi.get_parent()
	if mi_parent:
		var parent_lower: String = mi_parent.name.to_lower()
		if "_lod" in parent_lower:
			return "LOD (parent: %s)" % mi_parent.name

	# Check visibility_range to infer tier
	if mi.visibility_range_begin > 0 and mi.visibility_range_end > 0:
		if mi.visibility_range_begin >= 100:
			return "LOD0 (main mesh, visibility suggests MID-range display)"
		return "LOD0 (main mesh, NEAR tier)"

	if mi.visibility_range_end > 0:
		return "LOD0 (main mesh, visibility_range_end=%.0f)" % mi.visibility_range_end

	return "LOD0 (main mesh, no visibility_range)"


## Helper: transparency mode name
func _transparency_name(mode: int) -> String:
	match mode:
		BaseMaterial3D.TRANSPARENCY_DISABLED: return "DISABLED"
		BaseMaterial3D.TRANSPARENCY_ALPHA: return "ALPHA"
		BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR: return "ALPHA_SCISSOR"
		BaseMaterial3D.TRANSPARENCY_ALPHA_HASH: return "ALPHA_HASH"
		BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS: return "DEPTH_PRE_PASS"
		_: return "UNKNOWN(%d)" % mode


#region MID LOD Texture Audit

## Audit MID-tier RS mesh materials for missing textures.
##
## Post-B-wide refactor: there's no per-LOD mesh array anymore — each mesh_type
## holds a single ArrayMesh with an embedded LOD chain, so "LOD texture" is
## identical to "mesh texture". This command now audits surface materials
## (whole-mesh override + per-surface + baked-in mesh materials) across all
## registered mesh types.
@warning_ignore("untyped_declaration")
func _cmd_mid_lod_textures(_args: Dictionary) -> String:
	if not _streaming_manager or not _streaming_manager._static_renderer:
		return "MID-tier static renderer not available"

	var renderer: StaticObjectRenderer = _streaming_manager._static_renderer
	var mesh_types: Dictionary = renderer._mesh_types

	var total_types := 0
	var textured := 0
	var textureless := 0
	var building_textureless: Array[String] = []
	var other_textureless: Array[String] = []

	for type_name: String in mesh_types:
		var mt: StaticObjectRenderer.MeshType = mesh_types[type_name]
		if not mt.mesh_resource:
			continue

		total_types += 1
		var is_building := type_name.begins_with("ex_") or type_name.begins_with("in_")

		var has_texture := false
		if mt.material_resource and _material_has_texture(mt.material_resource):
			has_texture = true
		if not has_texture:
			for sm: Material in mt.surface_materials:
				if sm and _material_has_texture(sm):
					has_texture = true
					break
		if not has_texture:
			for si in range(mt.mesh_resource.get_surface_count()):
				var smat: Material = mt.mesh_resource.surface_get_material(si)
				if smat and _material_has_texture(smat):
					has_texture = true
					break

		if has_texture:
			textured += 1
		else:
			textureless += 1
			var info := "%s%s" % [type_name, " [lod_chain]" if mt.has_lod_chain else ""]
			if is_building:
				building_textureless.append(info)
			else:
				other_textureless.append(info)

	var lines: PackedStringArray = []
	lines.append("=== MID-TIER MESH TEXTURE AUDIT ===")
	lines.append("Registered mesh types: %d" % total_types)
	lines.append("With texture:    %d" % textured)
	lines.append("Without texture: %d" % textureless)

	if not building_textureless.is_empty():
		lines.append("")
		lines.append("BUILDINGS without texture (%d):" % building_textureless.size())
		for info in building_textureless.slice(0, 15):
			lines.append("  %s" % info)
		if building_textureless.size() > 15:
			lines.append("  ... and %d more" % (building_textureless.size() - 15))

	if not other_textureless.is_empty():
		lines.append("")
		lines.append("Other models without texture (%d):" % other_textureless.size())
		for info in other_textureless.slice(0, 10):
			lines.append("  %s" % info)
		if other_textureless.size() > 10:
			lines.append("  ... and %d more" % (other_textureless.size() - 10))

	return "\n".join(lines)


func _material_has_texture(mat: Material) -> bool:
	if mat is StandardMaterial3D:
		return (mat as StandardMaterial3D).albedo_texture != null
	if mat is ShaderMaterial:
		var sm := mat as ShaderMaterial
		var tex: Variant = sm.get_shader_parameter("albedo_texture")
		if tex is Texture2D:
			return true
		tex = sm.get_shader_parameter("texture_albedo")
		if tex is Texture2D:
			return true
	return false


func _mat_summary(mat: Material) -> String:
	if mat == null:
		return "null"
	if mat is StandardMaterial3D:
		var std := mat as StandardMaterial3D
		var tex_str := "tex=YES" if std.albedo_texture else "tex=NO"
		return "Std3D(%s, color=%s, cull=%d)" % [tex_str, std.albedo_color, std.cull_mode]
	if mat is ShaderMaterial:
		return "Shader(%s)" % (mat as ShaderMaterial).shader.resource_path.get_file() if (mat as ShaderMaterial).shader else "Shader(null)"
	return mat.get_class()

#endregion


#region Reload Compare (Bug 1 diagnostic)

## Compare NEAR-tier buildings: check LOD0 mesh state, visibility, cull mode, materials.
## Helps diagnose "missing faces on reload" by showing the actual state of loaded objects.
@warning_ignore("untyped_declaration")
func _cmd_reload_compare(_args: Dictionary) -> String:
	if not _streaming_manager:
		return "Streaming manager not available"

	var lines: PackedStringArray = []
	lines.append("=== NEAR-TIER BUILDING STATE ===")

	var counts := {
		"buildings": 0, "promoted": 0, "initial": 0,
		"fade_self": 0, "fade_deps": 0, "hidden_lod0": 0,
		"cull_disabled": 0, "cull_back": 0,
	}

	for grid: Vector2i in _streaming_manager._loaded_cells:
		var cell_node: Node3D = _streaming_manager._loaded_cells[grid]
		if not cell_node:
			continue
		for child_idx in range(cell_node.get_child_count()):
			var obj: Node = cell_node.get_child(child_idx)
			if not obj is Node3D:
				continue
			var model_path: String = obj.get_meta("model_path", "")
			if model_path.is_empty():
				continue
			# Only check building-type models
			var fname := model_path.get_file().to_lower()
			if not (fname.begins_with("ex_") or fname.begins_with("in_")):
				continue

			counts["buildings"] += 1
			var is_promoted_obj := obj.has_meta("promoted_from_mid")
			if is_promoted_obj:
				counts["promoted"] += 1
			else:
				counts["initial"] += 1

			# Check all MeshInstance3D children for LOD state
			_audit_building_meshes(obj, lines, counts["buildings"] <= 5,
				counts, is_promoted_obj)

	lines.insert(1, "Buildings checked: %d (initial: %d, promoted: %d)" % [counts["buildings"], counts["initial"], counts["promoted"]])
	lines.insert(2, "LOD0 fade modes: FADE_SELF=%d, FADE_DEPS=%d" % [counts["fade_self"], counts["fade_deps"]])
	lines.insert(3, "LOD0 hidden: %d, Cull: disabled=%d, back=%d" % [counts["hidden_lod0"], counts["cull_disabled"], counts["cull_back"]])

	if counts["buildings"] == 0:
		lines.append("No buildings found in loaded NEAR-tier cells.")

	return "\n".join(lines)


## Audit meshes within a building object
func _audit_building_meshes(node: Node, lines: PackedStringArray, verbose: bool,
		counts: Dictionary, is_promoted: bool) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var mesh_name: String = mi.name
		var is_lod := MeshVisibilityUtils.is_lod_node_name(mesh_name)

		if not is_lod:
			# LOD0 mesh
			if not mi.visible:
				counts["hidden_lod0"] += 1
			var fade_mode := mi.visibility_range_fade_mode
			if fade_mode == GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF:
				counts["fade_self"] += 1
			elif fade_mode == GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES:
				counts["fade_deps"] += 1

			# Check cull mode
			var mat: Material = mi.material_override
			if mat == null and mi.mesh and mi.mesh.get_surface_count() > 0:
				mat = mi.mesh.surface_get_material(0)
			if mat is StandardMaterial3D:
				if (mat as StandardMaterial3D).cull_mode == BaseMaterial3D.CULL_DISABLED:
					counts["cull_disabled"] += 1
				else:
					counts["cull_back"] += 1

			if verbose:
				var promo_tag := " [PROMOTED]" if is_promoted else " [INITIAL]"
				var vis_tag := " HIDDEN" if not mi.visible else ""
				var fade_str := "DEPS" if fade_mode == GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES else "SELF"
				lines.append("  %s%s%s: vis=%.0f-%.0f fade=%s" % [
					mesh_name, promo_tag, vis_tag,
					mi.visibility_range_begin, mi.visibility_range_end, fade_str])

	for child in node.get_children():
		_audit_building_meshes(child, lines, verbose, counts, is_promoted)


## Console command: lod_baseline_dump <label>
## Combines lod_stats + mid_batch_stats + visibility_gaps + streaming_diag + look
## into one text file under user://lod_baselines/<label>.txt with a header
## capturing camera position + cell + frame time. One-shot baseline capture
## for the LOD B-wide refactor (pre vs post comparison).
## On Windows, user:// resolves to
##   %APPDATA%/Godot/app_userdata/Godotwind/lod_baselines/<label>.txt
func _cmd_lod_baseline_dump(args: Dictionary) -> String:
	var label: String = str(args.get("label", "")).strip_edges()
	if label.is_empty():
		return "Usage: lod_baseline_dump <label>  (e.g. vivec_canton)"
	# Sanitise label for filename use
	var sanitised := ""
	for ch in label:
		if ch.to_lower() in "abcdefghijklmnopqrstuvwxyz0123456789_-":
			sanitised += ch
		else:
			sanitised += "_"
	if sanitised.is_empty():
		return "Invalid label after sanitisation"

	var out_dir := "user://lod_baselines"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	var out_path := "%s/%s.txt" % [out_dir, sanitised]

	var camera: Camera3D = null
	if _streaming_manager:
		camera = _streaming_manager.get_viewport().get_camera_3d()
	var cam_pos := camera.global_position if camera else Vector3.ZERO
	var cam_rot_deg := camera.rotation_degrees if camera else Vector3.ZERO
	var cam_fov: float = camera.fov if camera else 0.0
	var cam_cell := Vector2i.ZERO
	if _streaming_manager:
		cam_cell = _streaming_manager._camera_cell

	var header := "=== LOD BASELINE DUMP: %s ===\n" % sanitised
	header += "Timestamp: %s\n" % Time.get_datetime_string_from_system(true)
	header += "Frames drawn: %d\n" % Engine.get_frames_drawn()
	header += "Frame time (ms): %.2f\n" % (1000.0 / maxf(Engine.get_frames_per_second(), 1.0))
	header += "Camera pos: (%.1f, %.1f, %.1f)\n" % [cam_pos.x, cam_pos.y, cam_pos.z]
	header += "Camera rot (deg): (%.1f, %.1f, %.1f)\n" % [cam_rot_deg.x, cam_rot_deg.y, cam_rot_deg.z]
	header += "Camera FOV: %.1f\n" % cam_fov
	header += "Camera cell: %s\n" % str(cam_cell)
	header += "mesh_lod_threshold: %.2f\n" % (camera.get_viewport().mesh_lod_threshold if camera else 0.0)
	header += "================================\n\n"

	var sections: Array[String] = [
		"--- lod_stats ---\n" + _cmd_lod_stats({}),
		"--- mid_batch_stats ---\n" + _cmd_mid_batch_stats({}),
		"--- visibility_gaps ---\n" + _cmd_visibility_gaps({}),
		"--- streaming_diag ---\n" + _cmd_streaming_diag({}),
		"--- look ---\n" + _cmd_look({}),
		"--- mid_lod_textures ---\n" + _cmd_mid_lod_textures({}),
	]
	var body := "\n\n".join(sections)

	var file := FileAccess.open(out_path, FileAccess.WRITE)
	if not file:
		return "FAILED to open %s for writing (error %d)" % [out_path, FileAccess.get_open_error()]
	file.store_string(header + body)
	file.close()

	var globalised := ProjectSettings.globalize_path(out_path)
	Log.info("tools", "Baseline dump written: %s" % globalised)
	return "Baseline dump written: %s\n(%d bytes, %d sections)" % [globalised, header.length() + body.length(), sections.size()]

#endregion


#region Post-B-wide LOD tuning commands

## Get or set the viewport `mesh_lod_threshold` (screen-space LOD bias).
## Lower values = higher quality (LOD transitions happen later), higher values
## = more aggressive LOD drops. Godot default 1.0 is "perceptually lossless".
@warning_ignore("untyped_declaration")
func _cmd_lod_threshold(args: Dictionary) -> String:
	var viewport := _streaming_manager.get_viewport() if _streaming_manager else null
	if not viewport:
		return "No viewport available"
	if not args.has("value"):
		return "Current viewport.mesh_lod_threshold = %.3f px" % viewport.mesh_lod_threshold
	var value: float = args["value"]
	if value < 0.0:
		return "mesh_lod_threshold must be >= 0.0"
	viewport.mesh_lod_threshold = value
	return "viewport.mesh_lod_threshold = %.3f px (was %s)" % [value, str(viewport.mesh_lod_threshold)]


## Apply a new lod_bias to every currently-loaded static MID-tier RS instance.
## Does not affect the NEAR tier scene-tree path (use per-type overrides there).
@warning_ignore("untyped_declaration")
func _cmd_lod_bias_global(args: Dictionary) -> String:
	if not _streaming_manager or not _streaming_manager._static_renderer:
		return "MID-tier static renderer not available"
	var bias: float = args.get("bias", 1.0)
	var renderer: StaticObjectRenderer = _streaming_manager._static_renderer
	var updated := 0
	for id: int in renderer._instances:
		var data: StaticObjectRenderer.InstanceData = renderer._instances[id]
		if data.instance_rid.is_valid():
			RenderingServer.instance_geometry_set_lod_bias(data.instance_rid, bias)
			updated += 1
	return "Applied lod_bias=%.2f to %d RS instances" % [bias, updated]


## Post-B-wide LOD pipeline status readout.
@warning_ignore("untyped_declaration")
func _cmd_lod_info(_args: Dictionary) -> String:
	var lines: PackedStringArray = []
	lines.append("=== LOD pipeline status (post-B-wide) ===")

	var viewport := _streaming_manager.get_viewport() if _streaming_manager else null
	if viewport:
		lines.append("Viewport mesh_lod_threshold: %.3f px" % viewport.mesh_lod_threshold)
		lines.append("Viewport size: %s" % str(viewport.get_visible_rect().size))

	if _streaming_manager and _streaming_manager._static_renderer:
		var renderer: StaticObjectRenderer = _streaming_manager._static_renderer
		var stats: Dictionary = renderer.get_stats()
		lines.append("")
		lines.append("StaticObjectRenderer:")
		lines.append("  mesh_types:        %d" % int(stats.get("mesh_types", 0)))
		lines.append("  total_instances:   %d" % int(stats.get("total_instances", 0)))
		lines.append("  visible_instances: %d" % int(stats.get("visible_instances", 0)))

		var with_chain := 0
		var without_chain := 0
		for type_name: String in renderer._mesh_types:
			var mt: StaticObjectRenderer.MeshType = renderer._mesh_types[type_name]
			if mt.has_lod_chain:
				with_chain += 1
			else:
				without_chain += 1
		lines.append("  with embedded LOD chain:    %d" % with_chain)
		lines.append("  without embedded LOD chain: %d" % without_chain)

	lines.append("")
	lines.append("Render tier band: 0-%.0fm (single visibility_range, FADE_SELF, %.0fm margin)" % [
		DU.MID_END, DU.FADE_MARGIN_RENDER_FAR
	])
	lines.append("Sub-LOD selection: automatic (Godot RendererSceneCull screen-space coverage)")

	return "\n".join(lines)

#endregion
