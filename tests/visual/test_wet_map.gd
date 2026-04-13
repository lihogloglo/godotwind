extends Node3D

## Visual test for wet map (Lagarde PBR wet surfaces) + horizon map self-shadowing.
## Both systems share the terrain_horizon.gdshader override — this scene lets you
## verify both in a controlled environment with interactive sliders.
##
## Controls:
##   WASD — move camera (InputMap actions)
##   RightClick+drag — look around
##   Space/Ctrl — up/down
##   Escape — toggle mouse capture
##   Sliders — adjust wet map + sun parameters live

@warning_ignore("untyped_declaration", "unsafe_method_access")

var _camera: Camera3D
var _terrain: Terrain3D
var _horizon_mgr: HorizonMapManager
var _sun: DirectionalLight3D
var _label: Label
var _diag_label: Label
var _mouse_captured := false
var _yaw := 135.0
var _pitch := -12.0
var _move_speed := 50.0
const SPEED_MIN := 5.0
const SPEED_MAX := 500.0

# Wet map defaults
var _sea_level := 0.0
var _wet_margin := 1.5
var _wet_albedo_darken := 0.6
var _wet_roughness_target := 0.05

# Sun defaults
var _sun_azimuth := 0.5   # 0-1 → 0-360°
var _sun_elevation := 0.3  # 0-1 → 0-90°

# Diagnostics
var _regions_loaded := 0
var _textures_loaded := 0

# Draggable test objects for wetness testing
var _test_objects: Array[Dictionary] = []  # [{node, wet_line_y, mat_rid, mesh_bottom}]
var _held_object: Dictionary = {}
var _wet_dry_rate := 0.5  # wet_line_y decay (m/s) when above water
const OBJECT_WET_SHADER := preload("res://src/core/shaders/object_wet.gdshader")

const CS := preload("res://src/core/coordinate_system.gd")


func _ready() -> void:
	# Environment
	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.38, 0.45, 0.55)
	sky_mat.sky_horizon_color = Color(0.64, 0.68, 0.74)
	sky_mat.ground_bottom_color = Color(0.12, 0.10, 0.08)
	sky_mat.ground_horizon_color = Color(0.37, 0.33, 0.28)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world_env.environment = env
	add_child(world_env)

	# Sun (controllable via sliders)
	_sun = DirectionalLight3D.new()
	_sun.shadow_enabled = true
	_sun.light_energy = 1.2
	add_child(_sun)
	_update_sun_transform()

	# Camera (needed BEFORE Terrain3D to avoid _grab_camera crash)
	_camera = Camera3D.new()
	_camera.far = 10000.0
	_camera.current = true
	add_child(_camera)

	# Load terrain
	_setup_terrain()

	# Position camera above terrain center, looking down at the coastline.
	# Terrain regions are centered around origin, sea level at y=0.
	_camera.position = Vector3(0, 40, 0)
	_camera.rotation_degrees = Vector3(_pitch, _yaw, 0)

	# Ocean sea level
	if OceanManager and not OceanManager.is_initialized():
		OceanManager.force_initialize()
	if OceanManager and OceanManager.is_initialized():
		OceanManager.set_camera(_camera)
		_sea_level = OceanManager.sea_level

	# UI (before shader override so user sees diagnostics)
	_create_ui()

	# Wait for Terrain3D rendering pipeline to fully initialize.
	for i in 5:
		await get_tree().process_frame

	# Shader override for wet map uniforms on terrain
	_horizon_mgr = HorizonMapManager.new()
	if _terrain and _sun:
		_horizon_mgr.initialize(_terrain, _sun)

	# Push wet map uniforms
	_push_wet_uniforms()

	# Load terrain textures for realistic view (optional — works without)
	var texture_loader := preload("res://src/core/world/terrain_texture_loader.gd").new()
	_textures_loaded = texture_loader.load_terrain_textures(_terrain.assets)
	if _textures_loaded == 0:
		if _horizon_mgr:
			_horizon_mgr._set_param("enable_texturing", false)
		Log.info("water", "[Wet Map Test] No terrain textures — texturing disabled")
	else:
		Log.info("water", "[Wet Map Test] Loaded %d terrain textures" % _textures_loaded)

	# Spawn draggable test objects near camera for per-pixel wetness testing
	_spawn_test_objects()

	Log.info("water", "[Wet Map Test] Ready. regions=%d textures=%d sea=%.1f" % [
		_regions_loaded, _textures_loaded, _sea_level])

	# Mouse visible for slider interaction
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _setup_terrain() -> void:
	_terrain = Terrain3D.new()
	_terrain.name = "Terrain3D"

	# Add to tree first — Terrain3D auto-creates .data on ENTER_TREE
	add_child(_terrain)
	# Terrain3D re-enables physics on ENTER_TREE — disable after add_child
	_terrain.set_physics_process(false)

	# Tell Terrain3D which camera to use for mesh LOD
	if _terrain.has_method("set_camera"):
		_terrain.set_camera(_camera)

	# Configure via CoordinateSystem (sets vertex_spacing, region_size, material, assets)
	if not CS.configure_terrain3d(_terrain):
		Log.warn("water", "[Wet Map Test] Failed to configure Terrain3D")
		return

	# Load preprocessed terrain regions from cache
	var terrain_data_dir := SettingsManager.get_terrain_path()
	if _terrain.data and DirAccess.dir_exists_absolute(terrain_data_dir):
		_terrain.data.load_directory(terrain_data_dir)
		_regions_loaded = _terrain.data.get_region_count()
		Log.info("water", "[Wet Map Test] Terrain loaded: %d regions from %s" % [
			_regions_loaded, terrain_data_dir])
	else:
		Log.warn("water", "[Wet Map Test] No terrain data at %s" % terrain_data_dir)


func _push_wet_uniforms() -> void:
	if _horizon_mgr:
		_horizon_mgr.push_wet_map(_sea_level, _wet_margin, _wet_albedo_darken, _wet_roughness_target)


func _spawn_test_objects() -> void:
	var cam_pos := _camera.global_position
	var shapes: Array[Dictionary] = [
		{"name": "Cube", "mesh": BoxMesh.new(), "offset": Vector3(3, 0, -5), "color": Color(0.8, 0.3, 0.2), "half_h": 0.5},
		{"name": "Sphere", "mesh": SphereMesh.new(), "offset": Vector3(-3, 0, -5), "color": Color(0.3, 0.7, 0.3), "half_h": 0.5},
		{"name": "Cylinder", "mesh": CylinderMesh.new(), "offset": Vector3(0, 0, -8), "color": Color(0.3, 0.3, 0.8), "half_h": 0.5},
	]
	for s in shapes:
		var mi := MeshInstance3D.new()
		mi.name = s["name"]
		mi.mesh = s["mesh"]
		# ShaderMaterial with per-pixel wetness
		var mat := ShaderMaterial.new()
		mat.shader = OBJECT_WET_SHADER
		mat.set_shader_parameter("albedo_color", s["color"])
		mat.set_shader_parameter("roughness", 0.7)
		mat.set_shader_parameter("wet_line_y", -1000.0)
		mat.set_shader_parameter("wet_margin", 0.3)
		mat.set_shader_parameter("wet_albedo_darken", _wet_albedo_darken)
		mat.set_shader_parameter("wet_roughness_target", _wet_roughness_target)
		mi.material_override = mat
		mi.position = cam_pos + s["offset"]
		add_child(mi)
		var mat_rid: RID = mat.get_rid()
		# wet_line_local: water mark height relative to object center (local Y)
		# starts below mesh bottom = fully dry
		_test_objects.append({
			"node": mi, "wet_line_local": -s["half_h"] - 1.0, "mat_rid": mat_rid,
			"mesh_bottom": -s["half_h"],
		})
	Log.info("water", "[Wet Map Test] Spawned %d test objects — click to pick, click again to drop" % shapes.size())


func _update_object_wetness(delta: float) -> void:
	for obj in _test_objects:
		var node: MeshInstance3D = obj["node"]
		var wet_local: float = obj["wet_line_local"]
		var obj_y: float = node.global_position.y
		var obj_bottom_world: float = obj_y + obj["mesh_bottom"]

		# When submerged: water mark (in local space) = sea_level - object_y
		# This means: water is at this height relative to object center
		if obj_bottom_world < _sea_level:
			var water_mark_local: float = _sea_level - obj_y
			wet_local = maxf(wet_local, water_mark_local)
		else:
			# Above water: wet mark decays downward in local space (drying from top)
			wet_local -= _wet_dry_rate * delta

		obj["wet_line_local"] = wet_local

		# Convert to world space for shader: wet_line_y = object_y + local offset
		var wet_line_world: float = obj_y + wet_local
		var mat_rid: RID = obj["mat_rid"]
		if mat_rid.is_valid():
			RenderingServer.material_set_param(mat_rid, "wet_line_y", wet_line_world)


func _try_pick_drop() -> void:
	# If holding something, drop it
	if not _held_object.is_empty():
		_held_object = {}
		return

	# Raycast from camera center to find an object
	var space := get_world_3d().direct_space_state
	var from := _camera.global_position
	var to := from + -_camera.global_basis.z * 50.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	# No physics bodies on test objects — use visual picking instead
	# Simple distance check to each object
	var best_dist := 10.0  # max pick range
	var best_obj := {}
	for obj in _test_objects:
		var node: MeshInstance3D = obj["node"]
		var dir := -_camera.global_basis.z
		var to_obj := node.global_position - from
		var proj := to_obj.dot(dir)
		if proj < 0.5 or proj > 50.0:
			continue
		var closest := from + dir * proj
		var perp := (node.global_position - closest).length()
		if perp < 2.0 and proj < best_dist:
			best_dist = proj
			best_obj = obj
	if not best_obj.is_empty():
		_held_object = best_obj


func _update_sun_transform() -> void:
	if not _sun:
		return
	var azimuth_rad: float = _sun_azimuth * TAU
	var elevation_rad: float = _sun_elevation * PI * 0.5
	_sun.rotation = Vector3.ZERO
	_sun.rotate_y(azimuth_rad)
	_sun.rotate_object_local(Vector3.RIGHT, -(PI * 0.5 - elevation_rad))


func _create_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)

	var panel := PanelContainer.new()
	panel.position = Vector2(10, 10)
	panel.size = Vector2(340, 420)
	canvas.add_child(panel)

	var vbox := VBoxContainer.new()
	panel.add_child(vbox)

	_label = Label.new()
	_label.text = "Wet Map + Horizon Test"
	_label.add_theme_font_size_override("font_size", 16)
	vbox.add_child(_label)

	# --- Wet map sliders ---
	var wet_title := Label.new()
	wet_title.text = "— Wet Map —"
	wet_title.add_theme_font_size_override("font_size", 13)
	vbox.add_child(wet_title)

	_add_slider(vbox, "wet_margin", 0.0, 5.0, _wet_margin, func(val: float) -> void:
		_wet_margin = val
		_push_wet_uniforms()
	)
	_add_slider(vbox, "wet_albedo_darken", 0.0, 1.0, _wet_albedo_darken, func(val: float) -> void:
		_wet_albedo_darken = val
		_push_wet_uniforms()
	)
	_add_slider(vbox, "wet_roughness", 0.0, 0.5, _wet_roughness_target, func(val: float) -> void:
		_wet_roughness_target = val
		_push_wet_uniforms()
	)
	_add_slider(vbox, "sea_level", -5.0, 5.0, _sea_level, func(val: float) -> void:
		_sea_level = val
		_push_wet_uniforms()
	)

	# Wet debug toggles
	_add_toggle(vbox, "terrain_wet_debug", false, func(on: bool) -> void:
		if _horizon_mgr:
			_horizon_mgr._set_param("wet_debug", on)
	)
	_add_toggle(vbox, "object_wet_debug", false, func(on: bool) -> void:
		for obj in _test_objects:
			var rid: RID = obj["mat_rid"]
			if rid.is_valid():
				RenderingServer.material_set_param(rid, "wet_debug", on)
	)

	# --- Sun ---
	var sun_title := Label.new()
	sun_title.text = "— Sun —"
	sun_title.add_theme_font_size_override("font_size", 13)
	vbox.add_child(sun_title)

	_add_slider(vbox, "sun_azimuth", 0.0, 1.0, _sun_azimuth, func(val: float) -> void:
		_sun_azimuth = val
		_update_sun_transform()
	)
	_add_slider(vbox, "sun_elevation", 0.01, 1.0, _sun_elevation, func(val: float) -> void:
		_sun_elevation = val
		_update_sun_transform()
	)

	# --- Diagnostics ---
	_diag_label = Label.new()
	_diag_label.add_theme_font_size_override("font_size", 12)
	_diag_label.add_theme_color_override("font_color", Color(0.7, 0.8, 0.9))
	vbox.add_child(_diag_label)


func _add_slider(parent: Control, label_text: String, min_val: float, max_val: float, initial: float, callback: Callable) -> void:
	var hbox := HBoxContainer.new()
	parent.add_child(hbox)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size.x = 130
	hbox.add_child(lbl)

	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = 0.05
	slider.value = initial
	slider.custom_minimum_size.x = 130
	hbox.add_child(slider)

	var val_label := Label.new()
	val_label.text = "%.2f" % initial
	val_label.custom_minimum_size.x = 45
	hbox.add_child(val_label)

	slider.value_changed.connect(func(val: float) -> void:
		val_label.text = "%.2f" % val
		callback.call(val)
	)


func _add_toggle(parent: Control, label_text: String, initial: bool, callback: Callable) -> void:
	var hbox := HBoxContainer.new()
	parent.add_child(hbox)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size.x = 130
	hbox.add_child(lbl)
	var check := CheckBox.new()
	check.button_pressed = initial
	hbox.add_child(check)
	check.toggled.connect(callback)


func _process(delta: float) -> void:
	# Camera movement (sprint = 3x speed)
	var speed := _move_speed
	if Input.is_action_pressed("sprint"):
		speed *= 3.0

	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var move := Vector3(input.x, 0, input.y)
	if Input.is_action_pressed("jump"):
		move.y += 1
	if Input.is_action_pressed("crouch"):
		move.y -= 1

	if move != Vector3.ZERO:
		var dir := _camera.global_transform.basis * move.normalized() * speed * delta
		_camera.global_position += dir

	# Move held object in front of camera
	if not _held_object.is_empty():
		var node: MeshInstance3D = _held_object["node"]
		node.global_position = _camera.global_position + -_camera.global_basis.z * 5.0

	# Update object wetness (soak / dry)
	_update_object_wetness(delta)

	# Update HUD
	var held_info := ""
	if not _held_object.is_empty():
		held_info = " | HELD line=%.1f" % _held_object["wet_line_y"]
	if _label:
		_label.text = "Wet Map Test — y=%.1f sea=%.1f spd=%.0f%s" % [
			_camera.global_position.y, _sea_level, _move_speed, held_info]
	if _diag_label:
		var obj_info := ""
		for obj in _test_objects:
			var n: MeshInstance3D = obj["node"]
			obj_info += "\n  %s: line=%.1f y=%.1f" % [n.name, obj["wet_line_y"], n.global_position.y]
		_diag_label.text = "regions=%d tex=%d\nLClick=pick/drop RClick+drag=look\nWASD=move Scroll=speed Shift=sprint%s" % [
			_regions_loaded, _textures_loaded, obj_info]


func _unhandled_input(event: InputEvent) -> void:
	# Right-click drag for camera look (free mouse for sliders)
	if event is InputEventMouseMotion and (Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) or _mouse_captured):
		_yaw -= event.relative.x * 0.2
		_pitch -= event.relative.y * 0.2
		_pitch = clampf(_pitch, -89, 89)
		_camera.rotation_degrees = Vector3(_pitch, _yaw, 0)

	# Mouse buttons
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_move_speed = clampf(_move_speed * 1.25, SPEED_MIN, SPEED_MAX)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_move_speed = clampf(_move_speed / 1.25, SPEED_MIN, SPEED_MAX)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			_try_pick_drop()

	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			_mouse_captured = not _mouse_captured
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _mouse_captured else Input.MOUSE_MODE_VISIBLE
