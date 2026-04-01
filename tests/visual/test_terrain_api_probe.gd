extends Node3D

## Minimal Terrain3D API probe — checks all properties/methods from C# bindings

func _ready() -> void:
	var t := Terrain3D.new()
	t.name = "ProbeT3D"
	add_child(t)
	await get_tree().process_frame

	print("=== TERRAIN3D v1.1.0-dev API PROBE ===")
	print("")

	# Core
	_check(t, "vertex_spacing")
	_check(t, "region_size")
	_check(t, "mesh_lods")
	_check(t, "mesh_size")
	_check(t, "tessellation_level")

	# Displacement
	print("")
	print("--- Displacement ---")
	_check(t, "displacement_scale")
	_check(t, "displacement_sharpness")
	_check(t, "show_displacement_buffer")

	# Ocean
	print("")
	print("--- Ocean ---")
	_check(t, "ocean_enabled")
	_check(t, "ocean_mesh_lods")
	_check(t, "ocean_tessellation_level")
	_check(t, "ocean_mesh_size")
	_check(t, "ocean_vertex_spacing")
	_check(t, "ocean_cull_margin")
	_check(t, "ocean_cast_shadows")
	_check(t, "ocean_gi_mode")
	_check(t, "ocean_render_layers")
	_check(t, "ocean_material")
	_check(t, "ocean_light_target")

	# Collision
	print("")
	print("--- Collision ---")
	_check(t, "collision_enabled")
	_check(t, "collision_layer")
	_check(t, "collision_mask")
	_check(t, "collision_mode")
	_check(t, "collision_priority")

	# Debug
	print("")
	print("--- Debug ---")
	_check(t, "debug_level")
	_check(t, "render_layers")
	_check(t, "show_checkered")

	# Data API
	print("")
	print("--- Terrain3DData ---")
	if t.data:
		_check_method(t.data, "get_height")
		_check_method(t.data, "get_normal")
		_check_method(t.data, "get_color")
		_check_method(t.data, "import_images")
		_check_method(t.data, "get_region_count")
		_check_method(t.data, "get_region_location")
		_check_method(t.data, "get_regions_active")
		_check_method(t.data, "get_regions_all")
		_check_method(t.data, "load_directory")
		_check_method(t.data, "save_directory")
		_check_method(t.data, "get_height_range")
		_check_method(t.data, "get_height_maps_rid")
	else:
		print("  (no data — terrain not in tree long enough)")

	# Material API
	print("")
	print("--- Terrain3DMaterial ---")
	if t.material:
		_check(t.material, "world_background")
		_check(t.material, "auto_shader")
		_check(t.material, "dual_scaling")
		_check(t.material, "show_checkered")
	else:
		t.set_material(Terrain3DMaterial.new())
		if t.material:
			_check(t.material, "world_background")
			_check(t.material, "auto_shader")
			_check(t.material, "dual_scaling")

	print("")
	print("=== PROBE COMPLETE ===")

	await get_tree().create_timer(5.0).timeout
	get_tree().quit()


func _check(obj: Object, prop: String) -> void:
	if prop in obj:
		print("  YES: %s = %s" % [prop, str(obj.get(prop))])
	else:
		print("  NO:  %s" % prop)


func _check_method(obj: Object, method: String) -> void:
	if obj.has_method(method):
		print("  YES: %s()" % method)
	else:
		print("  NO:  %s()" % method)
