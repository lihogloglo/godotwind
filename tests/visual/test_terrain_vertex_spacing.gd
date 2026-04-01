extends Node3D

## Test: Terrain3D vertex_spacing API
##
## Tests whether the new Terrain3D DLL supports set_vertex_spacing() without crashing.
## Also probes for new features (displacement, ocean clipmap, etc.)

const CS := preload("res://src/core/coordinate_system.gd")

var _info_label: Label
var _terrain: Terrain3D


func _ready() -> void:
	_setup_ui()
	_setup_camera()

	_log("=== TERRAIN3D VERTEX SPACING TEST ===")
	_log("")

	# Phase 1: Check Terrain3D class exists
	if not ClassDB.class_exists("Terrain3D"):
		_log("[FAIL] Terrain3D class not found — GDExtension not loaded")
		return

	# Phase 2: Create Terrain3D and check basic properties
	_terrain = Terrain3D.new()
	_terrain.name = "TestTerrain"
	_log("[INFO] Created Terrain3D instance")

	# Check default vertex_spacing
	var default_vs: float = _terrain.get_vertex_spacing()
	_log("[INFO] Default vertex_spacing: %.4f" % default_vs)

	# Phase 3: Probe available methods/properties BEFORE adding to tree
	_probe_terrain_api()

	var target_vs: float = CS.TERRAIN_VERTEX_SPACING  # ~1.8286

	# Phase 4: Add to tree FIRST with default spacing
	_log("")
	_log("--- Phase 4: add_child with default spacing ---")
	add_child(_terrain)
	await get_tree().process_frame
	await get_tree().process_frame
	_log("[INFO] Terrain3D added to tree, data=%s" % (_terrain.data != null))

	# Phase 5: Try set_vertex_spacing AFTER add_child + process frames
	_log("")
	_log("--- Phase 5: set_vertex_spacing AFTER add_child ---")
	_log("[INFO] Target vertex_spacing: %.4f" % target_vs)
	var post_tree_ok := _try_set_vertex_spacing(target_vs, "post-tree")

	# Verify final state
	var final_vs: float = _terrain.get_vertex_spacing()
	_log("")
	_log("[RESULT] Final vertex_spacing: %.4f (target: %.4f)" % [final_vs, target_vs])
	if is_equal_approx(final_vs, target_vs):
		_log("[PASS] vertex_spacing set correctly!")
	else:
		_log("[FAIL] vertex_spacing mismatch — workaround still needed")

	# Phase 7: Check terrain data API
	if _terrain.data:
		_log("")
		_log("--- Phase 7: Terrain3DData API probe ---")
		_probe_terrain_data_api()

	_log("")
	_log("=== TEST COMPLETE ===")

	# Keep window open
	await get_tree().create_timer(30.0).timeout
	get_tree().quit()


func _try_set_vertex_spacing(vs: float, context: String) -> bool:
	if _terrain.has_method("set_vertex_spacing"):
		_log("[INFO] set_vertex_spacing() method exists")
		_terrain.set_vertex_spacing(vs)
		var actual: float = _terrain.get_vertex_spacing()
		if is_equal_approx(actual, vs):
			_log("[PASS] %s: vertex_spacing = %.4f" % [context, actual])
			return true
		else:
			_log("[WARN] %s: vertex_spacing = %.4f (expected %.4f)" % [context, actual, vs])
			return false
	elif "vertex_spacing" in _terrain:
		_log("[INFO] Using property access for vertex_spacing")
		_terrain.vertex_spacing = vs
		var actual: float = _terrain.vertex_spacing
		if is_equal_approx(actual, vs):
			_log("[PASS] %s: vertex_spacing = %.4f" % [context, actual])
			return true
		else:
			_log("[WARN] %s: vertex_spacing = %.4f (expected %.4f)" % [context, actual, vs])
			return false
	else:
		_log("[FAIL] %s: No vertex_spacing method or property found" % context)
		return false


func _probe_terrain_api() -> void:
	_log("")
	_log("--- Terrain3D API Probe ---")

	# Core methods
	var methods_to_check: Array[String] = [
		"set_vertex_spacing", "get_vertex_spacing",
		"set_region_size", "get_region_size",
		"change_region_size",
		# New features
		"set_mesh_vertex_spacing",  # Renamed in newer versions?
		"set_displacement_enabled", "get_displacement_enabled",
		"set_ocean_enabled", "get_ocean_enabled",
		"set_ocean_clipmap",
		"set_clipmap_levels",
		"get_clipmap_levels",
	]

	for method: String in methods_to_check:
		var has: bool = _terrain.has_method(method)
		_log("  %s %s()" % ["✓" if has else "✗", method])

	# Properties
	_log("")
	_log("--- Terrain3D Properties ---")
	var props_to_check: Array[String] = [
		"vertex_spacing",
		"region_size",
		"mesh_lods",
		"mesh_size",
		"show_checkered",
		"debug_level",
		"render_layers",
		"collision_enabled",
		"collision_layer",
		"collision_mask",
		# New features
		"displacement_enabled",
		"ocean_enabled",
		"ocean_height",
		"ocean_color",
	]

	for prop: String in props_to_check:
		var has: bool = prop in _terrain
		var val: String = ""
		if has:
			val = " = %s" % str(_terrain.get(prop))
		_log("  %s %s%s" % ["✓" if has else "✗", prop, val])

	# Material properties (if material exists)
	if _terrain.material:
		_log("")
		_log("--- Terrain3DMaterial Properties ---")
		var mat := _terrain.material
		var mat_props: Array[String] = [
			"world_background",
			"show_checkered",
			"auto_shader",
			"dual_scaling",
			# New
			"displacement_enabled",
			"displacement_strength",
			"ocean_enabled",
		]
		for prop: String in mat_props:
			var has: bool = prop in mat
			var val: String = ""
			if has:
				val = " = %s" % str(mat.get(prop))
			_log("  %s %s%s" % ["✓" if has else "✗", prop, val])


func _probe_terrain_data_api() -> void:
	var data := _terrain.data
	var data_methods: Array[String] = [
		"get_height", "get_normal", "get_color",
		"import_images", "export_image",
		"load_directory", "save_directory",
		"get_region_count",
		"get_regions",
		# New
		"get_displacement", "set_displacement",
		"get_ocean_height",
	]

	for method: String in data_methods:
		var has: bool = data.has_method(method)
		_log("  %s %s()" % ["✓" if has else "✗", method])


func _log(msg: String) -> void:
	Log.info("testing", "[TERRAIN_VS] %s" % msg)
	print(msg)
	if _info_label:
		_info_label.text += msg + "\n"


func _setup_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_info_label = Label.new()
	_info_label.position = Vector2(10, 10)
	_info_label.size = Vector2(800, 600)
	_info_label.add_theme_font_size_override("font_size", 14)
	_info_label.add_theme_color_override("font_color", Color.WHITE)
	_info_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_info_label.add_theme_constant_override("shadow_offset_x", 1)
	_info_label.add_theme_constant_override("shadow_offset_y", 1)
	_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	canvas.add_child(_info_label)


func _setup_camera() -> void:
	var cam := Camera3D.new()
	cam.current = true
	cam.position = Vector3(0, 100, 0)
	cam.rotation_degrees = Vector3(-45, 0, 0)
	add_child(cam)
