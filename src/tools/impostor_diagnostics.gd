## ImpostorDiagnostics - Diagnostic tool for impostor rendering pipeline
##
## This tool helps diagnose why impostors might not be displayed.
## Attach to any node in a scene with WorldStreamingManager to run diagnostics.
##
## Usage:
##   1. Add this script to a node in your scene
##   2. Run the scene and press F9 to run diagnostics
##   3. Check output for issues
class_name ImpostorDiagnostics
extends Node

@export var diagnostic_key: Key = KEY_F9
@export var auto_run_on_ready: bool = true
@export var print_sample_objects: int = 10

var _wsm: Node = null
var _tier_manager: RefCounted = null
var _impostor_manager: Node = null
var _object_streamer: Node = null

func _ready() -> void:
	if auto_run_on_ready:
		call_deferred("_run_diagnostics")


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == diagnostic_key:
		_run_diagnostics()


func _find_streaming_components() -> bool:
	# Find WorldStreamingManager
	_wsm = _find_node_by_class("WorldStreamingManager")
	if not _wsm:
		print("[DIAG] ❌ WorldStreamingManager not found!")
		return false

	print("[DIAG] ✓ WorldStreamingManager found: %s" % _wsm.name)

	# Get tier manager
	if _wsm.has_method("get") or "tier_manager" in _wsm:
		_tier_manager = _wsm.get("tier_manager")

	if _tier_manager:
		print("[DIAG] ✓ DistanceTierManager found")
	else:
		print("[DIAG] ❌ DistanceTierManager NOT found!")

	# Get impostor manager
	if "impostor_manager" in _wsm:
		_impostor_manager = _wsm.get("impostor_manager")

	if _impostor_manager:
		print("[DIAG] ✓ ImpostorManager found: %s" % _impostor_manager.name)
	else:
		print("[DIAG] ❌ ImpostorManager NOT found!")

	# Get object streamer
	if "object_streamer" in _wsm:
		_object_streamer = _wsm.get("object_streamer")

	if _object_streamer:
		print("[DIAG] ✓ ObjectStreamer found: %s" % _object_streamer.name)
	else:
		print("[DIAG] ❌ ObjectStreamer NOT found!")

	return true


func _find_node_by_class(class_name_str: String) -> Node:
	return _find_node_recursive(get_tree().root, class_name_str)


func _find_node_recursive(node: Node, class_name_str: String) -> Node:
	if node.get_class() == class_name_str:
		return node
	# Check script class name
	var script: Script = node.get_script()
	if script and script.get_global_name() == class_name_str:
		return node

	for child in node.get_children():
		var result := _find_node_recursive(child, class_name_str)
		if result:
			return result
	return null


func _run_diagnostics() -> void:
	print("")
	print("=" .repeat(80))
	print("[DIAG] IMPOSTOR PIPELINE DIAGNOSTICS")
	print("=" .repeat(80))
	print("")

	if not _find_streaming_components():
		print("[DIAG] Cannot run diagnostics - missing components")
		return

	_check_wsm_config()
	_check_tier_manager()
	_check_impostor_manager()
	_check_object_streamer()
	_check_far_tier_visibility()

	print("")
	print("=" .repeat(80))
	print("[DIAG] DIAGNOSTICS COMPLETE - Check output above for ❌ errors")
	print("=" .repeat(80))


func _check_wsm_config() -> void:
	print("")
	print("[DIAG] --- WorldStreamingManager Config ---")

	var distant_enabled: bool = _wsm.get("distant_rendering_enabled") if "distant_rendering_enabled" in _wsm else false
	var load_objects: bool = _wsm.get("load_objects") if "load_objects" in _wsm else false

	print("[DIAG] distant_rendering_enabled: %s %s" % [distant_enabled, "✓" if distant_enabled else "❌ (impostors require this!)"])
	print("[DIAG] load_objects: %s %s" % [load_objects, "✓" if load_objects else "❌ (objects disabled)"])


func _check_tier_manager() -> void:
	print("")
	print("[DIAG] --- DistanceTierManager Status ---")

	if not _tier_manager:
		print("[DIAG] ❌ No tier manager - cannot check visibility!")
		return

	# Get camera position
	var camera_pos: Vector3 = Vector3.ZERO
	if _tier_manager.has_method("get_camera_position"):
		camera_pos = _tier_manager.call("get_camera_position")
	print("[DIAG] Camera position: %s" % camera_pos)

	# Get registered object count
	var obj_count: int = 0
	if _tier_manager.has_method("get_registered_object_count"):
		obj_count = _tier_manager.call("get_registered_object_count")
	print("[DIAG] Registered objects: %d %s" % [obj_count, "✓" if obj_count > 0 else "❌ (no objects registered!)"])

	# Get visible cells by tier
	var camera_cell := Vector2i(floori(camera_pos.x / 117.0), floori(-camera_pos.z / 117.0))
	print("[DIAG] Camera cell: %s" % camera_cell)

	# Get tier configuration from get_debug_info
	if _tier_manager.has_method("get_debug_info"):
		var debug_info: Dictionary = _tier_manager.call("get_debug_info")
		var tier_distances: Dictionary = debug_info.get("tier_distances", {})
		var tier_end_distances: Dictionary = debug_info.get("tier_end_distances", {})
		var max_cells: Dictionary = debug_info.get("max_cells_per_tier", {})
		print("[DIAG] Tier distances: NEAR=0-%.0fm, MID=%.0f-%.0fm, FAR=%.0f-%.0fm" % [
			tier_end_distances.get(0, 0),  # NEAR end
			tier_distances.get(1, 0), tier_end_distances.get(1, 0),  # MID start-end
			tier_distances.get(2, 0), tier_end_distances.get(2, 0),  # FAR start-end
		])
		print("[DIAG] Max cells per tier: NEAR=%d, MID=%d, FAR=%d" % [
			max_cells.get(0, 0), max_cells.get(1, 0), max_cells.get(2, 0)
		])
		print("[DIAG] Frustum culling: %s, Has camera: %s" % [
			debug_info.get("frustum_culling", false),
			debug_info.get("has_camera", false)
		])
		var dtm_enabled: bool = debug_info.get("enabled", false)
		print("[DIAG] DTM distant_rendering_enabled: %s %s" % [
			dtm_enabled,
			"✓" if dtm_enabled else "❌ (FAR tier disabled in tier manager!)"
		])

	if _tier_manager.has_method("get_visible_cells_by_tier"):
		var cells_by_tier: Dictionary = _tier_manager.call("get_visible_cells_by_tier", camera_cell)

		for tier_key in cells_by_tier:
			var tier_cells: Array = cells_by_tier[tier_key]
			var tier_name := _get_tier_name(tier_key)
			print("[DIAG] %s tier cells: %d" % [tier_name, tier_cells.size()])

	# Get visible objects by tier
	if _tier_manager.has_method("get_visible_objects_by_tier"):
		var objects_by_tier: Dictionary = _tier_manager.call("get_visible_objects_by_tier")

		for tier_key in objects_by_tier:
			var tier_objs: Array = objects_by_tier[tier_key]
			var tier_name := _get_tier_name(tier_key)
			print("[DIAG] %s tier objects: %d" % [tier_name, tier_objs.size()])


func _get_tier_name(tier: int) -> String:
	match tier:
		0: return "NEAR"
		1: return "MID"
		2: return "FAR"
		3: return "HORIZON"
		4: return "NONE"
		_: return "T%d" % tier


func _check_impostor_manager() -> void:
	print("")
	print("[DIAG] --- ImpostorManager Status ---")

	if not _impostor_manager:
		print("[DIAG] ❌ No impostor manager!")
		return

	# Check if tier manager is connected
	var has_tier_manager := false
	if "_distance_tier_manager" in _impostor_manager:
		has_tier_manager = _impostor_manager.get("_distance_tier_manager") != null
	print("[DIAG] DistanceTierManager connected: %s %s" % [has_tier_manager, "✓" if has_tier_manager else "❌ (critical!)"])

	# Get stats
	if _impostor_manager.has_method("get_stats"):
		var stats: Dictionary = _impostor_manager.call("get_stats")
		print("[DIAG] Total impostors: %d" % stats.get("total_impostors", 0))
		print("[DIAG] Visible impostors: %d %s" % [
			stats.get("visible_impostors", 0),
			"✓" if stats.get("visible_impostors", 0) > 0 else "❌ (no visible impostors!)"
		])
		print("[DIAG] Texture cache size: %d" % stats.get("texture_cache_size", 0))
		print("[DIAG] Texture array layers: %d" % stats.get("texture_array_layers", 0))
		print("[DIAG] Cells with impostors: %d" % stats.get("cells_with_impostors", 0))
		print("[DIAG] Pending loads: %d" % stats.get("pending_loads", 0))

	# Check MultiMesh
	if "_master_multimesh" in _impostor_manager and "_master_instance" in _impostor_manager:
		var mm: MultiMesh = _impostor_manager.get("_master_multimesh")
		var mi: MultiMeshInstance3D = _impostor_manager.get("_master_instance")

		if mm:
			print("[DIAG] MultiMesh instance_count: %d" % mm.instance_count)
		else:
			print("[DIAG] ❌ MultiMesh is NULL!")

		if mi:
			print("[DIAG] MultiMeshInstance3D visible: %s %s" % [
				mi.visible, "✓" if mi.visible else "❌ (hidden!)"
			])
			print("[DIAG] MultiMeshInstance3D material_override: %s" % ("set" if mi.material_override else "❌ NOT SET!"))
		else:
			print("[DIAG] ❌ MultiMeshInstance3D is NULL!")

	# Check cached visible cells
	if "_cached_visible_cells" in _impostor_manager:
		var cached: Dictionary = _impostor_manager.get("_cached_visible_cells")
		print("[DIAG] Cached visible cells: %d %s" % [
			cached.size(),
			"✓" if cached.size() > 0 else "❌ (no cells marked visible!)"
		])

	# Check global visibility
	if "_globally_visible" in _impostor_manager:
		var global_vis: bool = _impostor_manager.get("_globally_visible")
		print("[DIAG] _globally_visible: %s %s" % [global_vis, "✓" if global_vis else "❌ (all hidden!)"])


func _check_object_streamer() -> void:
	print("")
	print("[DIAG] --- ObjectStreamer Status ---")

	if not _object_streamer:
		print("[DIAG] ❌ No object streamer!")
		return

	# Check if enabled
	var enabled: bool = _object_streamer.get("enabled") if "enabled" in _object_streamer else false
	print("[DIAG] enabled: %s %s" % [enabled, "✓" if enabled else "❌ (disabled!)"])

	# Check tier manager connection
	if "_distance_tier_manager" in _object_streamer:
		var has_tm: bool = _object_streamer.get("_distance_tier_manager") != null
		print("[DIAG] DistanceTierManager connected: %s %s" % [has_tm, "✓" if has_tm else "❌"])

	# Check impostor manager connection
	if "_impostor_manager" in _object_streamer:
		var has_im: bool = _object_streamer.get("_impostor_manager") != null
		print("[DIAG] ImpostorManager connected: %s %s" % [has_im, "✓" if has_im else "❌"])

	# Check AAA streaming / position index
	if "_position_index" in _object_streamer:
		var pos_index = _object_streamer.get("_position_index")
		if pos_index:
			print("[DIAG] PositionIndex connected: true ✓")
			if pos_index.has_method("is_built"):
				var is_built: bool = pos_index.call("is_built")
				print("[DIAG] PositionIndex built: %s %s" % [is_built, "✓" if is_built else "❌ (not built!)"])
			if pos_index.has_method("get_total_objects"):
				var total: int = pos_index.call("get_total_objects")
				print("[DIAG] PositionIndex total objects: %d %s" % [total, "✓" if total > 0 else "❌ (empty!)"])
		else:
			print("[DIAG] PositionIndex connected: false ❌ (AAA streaming disabled!)")

	if "_aaa_streaming_enabled" in _object_streamer:
		var aaa_enabled: bool = _object_streamer.get("_aaa_streaming_enabled")
		print("[DIAG] AAA streaming enabled: %s %s" % [aaa_enabled, "✓" if aaa_enabled else "❌"])

	if "_aaa_registered_objects" in _object_streamer:
		var aaa_registered: Dictionary = _object_streamer.get("_aaa_registered_objects")
		print("[DIAG] AAA registered objects: %d" % aaa_registered.size())

	# Get stats
	if _object_streamer.has_method("get_stats"):
		var stats: Dictionary = _object_streamer.call("get_stats")
		print("[DIAG] Total objects: %d" % stats.get("total_objects", 0))
		print("[DIAG] NEAR visible: %d" % stats.get("near_visible", 0))
		print("[DIAG] MID visible: %d" % stats.get("mid_visible", 0))
		print("[DIAG] FAR visible: %d %s" % [
			stats.get("far_visible", 0),
			"✓" if stats.get("far_visible", 0) > 0 else "(no FAR tier objects)"
		])
		print("[DIAG] Hidden: %d" % stats.get("hidden", 0))
		print("[DIAG] Transitioning: %d" % stats.get("transitioning", 0))

	# Get debug info for sample objects
	if _object_streamer.has_method("get_debug_info"):
		var debug_info: Dictionary = _object_streamer.call("get_debug_info")
		print("[DIAG] Significant objects: %d" % debug_info.get("significant_objects", 0))
		print("[DIAG] LODs loaded: %d" % debug_info.get("lods_loaded", 0))

		# Position index info from debug
		var pos_info: Dictionary = debug_info.get("position_index", {})
		if not pos_info.is_empty():
			print("[DIAG] PositionIndex (from debug_info): set=%s built=%s total=%d" % [
				pos_info.get("set", false),
				pos_info.get("is_built", false),
				pos_info.get("total_objects", 0)
			])

		# Sample objects
		var samples: Array = debug_info.get("sample_objects", [])
		if not samples.is_empty():
			print("[DIAG] Sample objects (first %d):" % min(samples.size(), print_sample_objects))
			for i in range(min(samples.size(), print_sample_objects)):
				var obj: Dictionary = samples[i]
				print("[DIAG]   %d. %s sig=%s tier=%s dist=%.0fm" % [
					i + 1,
					obj.get("model", "?"),
					obj.get("significant", false),
					_get_tier_name(obj.get("tier", -1)),
					obj.get("distance", 0.0)
				])


func _check_far_tier_visibility() -> void:
	print("")
	print("[DIAG] --- FAR Tier Visibility Chain ---")

	if not _tier_manager:
		print("[DIAG] ❌ Cannot check - no tier manager")
		return

	if not _impostor_manager:
		print("[DIAG] ❌ Cannot check - no impostor manager")
		return

	# Get camera position and cell
	var camera_pos: Vector3 = Vector3.ZERO
	if _tier_manager.has_method("get_camera_position"):
		camera_pos = _tier_manager.call("get_camera_position")

	var camera_cell := Vector2i(floori(camera_pos.x / 117.0), floori(-camera_pos.z / 117.0))

	# Get FAR tier cells from tier manager
	var far_cells_from_tm: Array = []
	if _tier_manager.has_method("get_visible_cells_by_tier"):
		var cells_by_tier: Dictionary = _tier_manager.call("get_visible_cells_by_tier", camera_cell)
		far_cells_from_tm = cells_by_tier.get(2, [])  # 2 = FAR tier

	print("[DIAG] FAR cells from DistanceTierManager: %d" % far_cells_from_tm.size())

	# Get cached visible cells in impostor manager
	var cached_cells: Dictionary = {}
	if "_cached_visible_cells" in _impostor_manager:
		cached_cells = _impostor_manager.get("_cached_visible_cells")

	print("[DIAG] Cached visible cells in ImpostorManager: %d" % cached_cells.size())

	# Get impostors by cell
	var impostors_by_cell: Dictionary = {}
	if "_impostors_by_cell" in _impostor_manager:
		impostors_by_cell = _impostor_manager.get("_impostors_by_cell")

	print("[DIAG] Cells with impostors: %d" % impostors_by_cell.size())

	# Check for overlap
	var cells_with_visible_impostors := 0
	for cell_grid in impostors_by_cell:
		if cell_grid in cached_cells:
			cells_with_visible_impostors += 1

	print("[DIAG] Cells with impostors that are visible: %d %s" % [
		cells_with_visible_impostors,
		"✓" if cells_with_visible_impostors > 0 else "❌ (NO OVERLAP!)"
	])

	# Print sample FAR cells
	if far_cells_from_tm.size() > 0:
		print("[DIAG] Sample FAR cells from tier manager (first 5):")
		for i in range(min(5, far_cells_from_tm.size())):
			var cell: Vector2i = far_cells_from_tm[i]
			var has_impostors: bool = cell in impostors_by_cell
			var is_cached: bool = cell in cached_cells
			print("[DIAG]   %s - has_impostors=%s cached=%s" % [cell, has_impostors, is_cached])

	# Check LOD-managed impostors
	var lod_managed: Dictionary = {}
	if "_lod_managed_impostors" in _impostor_manager:
		lod_managed = _impostor_manager.get("_lod_managed_impostors")

	print("[DIAG] LOD-managed impostors: %d" % lod_managed.size())

	# CRITICAL CHECK: Are impostors being added at all?
	var total_impostors: Dictionary = {}
	if "_impostors" in _impostor_manager:
		total_impostors = _impostor_manager.get("_impostors")

	if total_impostors.is_empty():
		print("")
		print("[DIAG] ❌❌❌ CRITICAL: No impostors have been added! ❌❌❌")
		print("[DIAG] This means either:")
		print("[DIAG]   1. No objects match impostor_candidates patterns")
		print("[DIAG]   2. ObjectStreamer isn't calling add_impostor()")
		print("[DIAG]   3. Impostor textures don't exist in cache")
		print("")
