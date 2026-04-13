extends Node3D

## Visual test for Phase 3 wet map (Lagarde PBR wet surfaces).
## Shows terrain near shore with wet darkening + glossy effect below sea level.
##
## Controls:
##   WASD — move camera (InputMap actions)
##   Mouse — look around
##   Q/E — up/down
##   Escape — release mouse
##   Sliders — adjust wet map parameters live

@warning_ignore("untyped_declaration", "unsafe_method_access")

var _camera: Camera3D
var _terrain: Terrain3D
var _horizon_mgr: HorizonMapManager
var _label: Label
var _mouse_captured := true
var _yaw := 135.0
var _pitch := -12.0
var _move_speed := 30.0

# Wet map defaults
var _sea_level := 0.0
var _wet_margin := 1.5
var _wet_albedo_darken := 0.6
var _wet_roughness_target := 0.05

const CS := preload("res://src/core/coordinate_system.gd")
const HORIZON_SHADER_PATH := "res://src/core/world/terrain_horizon.gdshader"


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

	# Sun
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-35, 45, 0)
	light.shadow_enabled = true
	light.light_energy = 1.2
	add_child(light)

	# Camera (needed BEFORE Terrain3D to avoid _grab_camera crash)
	_camera = Camera3D.new()
	_camera.far = 10000.0
	_camera.current = true
	add_child(_camera)

	# Load terrain
	_setup_terrain()

	# Position camera near a coastal area
	_camera.position = Vector3(0, 15, 30)
	_camera.rotation_degrees = Vector3(_pitch, _yaw, 0)

	# Ocean
	if OceanManager and not OceanManager.is_initialized():
		OceanManager.force_initialize()
	if OceanManager and OceanManager.is_initialized():
		OceanManager.set_camera(_camera)
		_sea_level = OceanManager.sea_level

	# UI
	_create_ui()

	# Use HorizonMapManager for shader override — proven working code path.
	# Wait several frames for Terrain3D to fully initialize its rendering pipeline.
	for i in 5:
		await get_tree().process_frame
	_horizon_mgr = HorizonMapManager.new()
	var sun := _find_sun()
	if _terrain and sun:
		_horizon_mgr.initialize(_terrain, sun)
	_horizon_mgr.push_wet_map(_sea_level, _wet_margin, _wet_albedo_darken, _wet_roughness_target)
	# Also disable texturing since no MW textures are loaded
	_horizon_mgr._set_param("enable_texturing", false)
	Log.info("water", "[Wet Map Test] Wet map pushed via HorizonMapManager, sea_level=%.1f" % _sea_level)

	# Start with mouse visible so user can interact with sliders.
	# Right-click + drag to look around. Escape to toggle capture.
	_mouse_captured = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Log.info("water", "[Wet Map Test] Scene ready. WASD=move, RightClick+drag=look, Space/Ctrl=up/down, Esc=toggle mouse")


func _setup_terrain() -> void:
	_terrain = Terrain3D.new()
	_terrain.name = "Terrain3D"

	# Add to tree first — Terrain3D auto-creates .data on ENTER_TREE
	add_child(_terrain)
	# Terrain3D re-enables physics on ENTER_TREE — disable after add_child
	_terrain.set_physics_process(false)

	# Configure via CoordinateSystem (sets vertex_spacing, region_size, material, assets)
	if not CS.configure_terrain3d(_terrain):
		Log.warn("water", "[Wet Map Test] Failed to configure Terrain3D")
		return

	# Load preprocessed terrain regions from cache
	var terrain_data_dir := SettingsManager.get_terrain_path()
	if _terrain.data and DirAccess.dir_exists_absolute(terrain_data_dir):
		_terrain.data.load_directory(terrain_data_dir)
		Log.info("water", "[Wet Map Test] Terrain loaded: %d regions from %s" % [
			_terrain.data.get_region_count(), terrain_data_dir])
	else:
		Log.warn("water", "[Wet Map Test] No terrain data at %s" % terrain_data_dir)


func _find_sun() -> DirectionalLight3D:
	for child in get_children():
		if child is DirectionalLight3D:
			return child
	return null


func _push_wet_uniforms() -> void:
	if _horizon_mgr:
		_horizon_mgr.push_wet_map(_sea_level, _wet_margin, _wet_albedo_darken, _wet_roughness_target)


func _create_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)

	var panel := PanelContainer.new()
	panel.position = Vector2(10, 10)
	panel.size = Vector2(320, 260)
	canvas.add_child(panel)

	var vbox := VBoxContainer.new()
	panel.add_child(vbox)

	_label = Label.new()
	_label.text = "Wet Map Test"
	_label.add_theme_font_size_override("font_size", 16)
	vbox.add_child(_label)

	_add_slider(vbox, "wet_margin", 0.0, 5.0, _wet_margin, func(val: float) -> void:
		_wet_margin = val
		_push_wet_uniforms()
	)

	_add_slider(vbox, "wet_albedo_darken", 0.0, 1.0, _wet_albedo_darken, func(val: float) -> void:
		_wet_albedo_darken = val
		_push_wet_uniforms()
	)

	_add_slider(vbox, "wet_roughness_target", 0.0, 0.5, _wet_roughness_target, func(val: float) -> void:
		_wet_roughness_target = val
		_push_wet_uniforms()
	)

	_add_slider(vbox, "sea_level_wet", -5.0, 5.0, _sea_level, func(val: float) -> void:
		_sea_level = val
		_push_wet_uniforms()
	)

	# Debug toggle — shows wet zone as blue tint
	var debug_hbox := HBoxContainer.new()
	vbox.add_child(debug_hbox)
	var debug_lbl := Label.new()
	debug_lbl.text = "wet_debug"
	debug_lbl.custom_minimum_size.x = 150
	debug_hbox.add_child(debug_lbl)
	var debug_check := CheckBox.new()
	debug_check.button_pressed = false
	debug_hbox.add_child(debug_check)
	debug_check.toggled.connect(func(on: bool) -> void:
		if _horizon_mgr:
			_horizon_mgr._set_param("wet_debug", on)
	)


func _add_slider(parent: Control, label_text: String, min_val: float, max_val: float, initial: float, callback: Callable) -> void:
	var hbox := HBoxContainer.new()
	parent.add_child(hbox)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size.x = 150
	hbox.add_child(lbl)

	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = 0.05
	slider.value = initial
	slider.custom_minimum_size.x = 120
	hbox.add_child(slider)

	var val_label := Label.new()
	val_label.text = "%.2f" % initial
	val_label.custom_minimum_size.x = 45
	hbox.add_child(val_label)

	slider.value_changed.connect(func(val: float) -> void:
		val_label.text = "%.2f" % val
		callback.call(val)
	)


func _process(delta: float) -> void:
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var move := Vector3(input.x, 0, input.y)
	if Input.is_action_pressed("jump"):
		move.y += 1
	if Input.is_action_pressed("crouch"):
		move.y -= 1

	if move != Vector3.ZERO:
		var dir := _camera.global_transform.basis * move.normalized() * _move_speed * delta
		_camera.global_position += dir

	# Update label
	if _label:
		_label.text = "Wet Map Test — y=%.1f, sea=%.1f\n" % [_camera.global_position.y, _sea_level]
		_label.text += "margin=%.2f darken=%.2f rough=%.2f" % [_wet_margin, _wet_albedo_darken, _wet_roughness_target]


func _unhandled_input(event: InputEvent) -> void:
	# Right-click drag for camera look (free mouse for sliders)
	if event is InputEventMouseMotion and (Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) or _mouse_captured):
		_yaw -= event.relative.x * 0.2
		_pitch -= event.relative.y * 0.2
		_pitch = clampf(_pitch, -89, 89)
		_camera.rotation_degrees = Vector3(_pitch, _yaw, 0)

	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			_mouse_captured = not _mouse_captured
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _mouse_captured else Input.MOUSE_MODE_VISIBLE
