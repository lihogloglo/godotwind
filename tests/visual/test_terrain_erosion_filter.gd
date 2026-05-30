extends Node3D

## Interactive Terrain3D erosion-filter lab for Morrowind terrain.
##
## Controls:
##   InputMap move actions - fly camera
##   jump / crouch - fly up / down
##   sprint - fast fly
##   Right mouse drag - look
##   Mouse wheel - adjust fly speed
##   ui_cancel - toggle mouse capture

@warning_ignore("untyped_declaration", "unsafe_method_access")

const CS := preload("res://src/core/coordinate_system.gd")
const InputActionsScript := preload("res://src/core/input/input_actions.gd")
const MorrowindTerrainTextureBridgeScript := preload("res://src/core/world/morrowind/morrowind_terrain_texture_bridge.gd")
const TerrainErosionShader := preload("res://tests/visual/test_terrain_erosion_filter.gdshader")

const DEFAULT_NEAR_RADIUS := 30.0
const DEFAULT_FADE_WIDTH := 120.0
const DEFAULT_EROSION_SCALE := 28.0
const DEFAULT_EROSION_STRENGTH := 0.70
const DEFAULT_GULLY_WEIGHT := 0.50
const DEFAULT_EROSION_DETAIL := 1.50
const DEFAULT_NORMAL_STRENGTH := 8.0
const DEFAULT_COLOR_STRENGTH := 0.35
const DEFAULT_VERTEX_DISPLACEMENT := 20.0
const DAYLIGHT_START_HOUR := 7.0
const DAYLIGHT_END_HOUR := 17.5
const DEFAULT_GAME_HOUR := 9.0
const DAYLIGHT_CYCLE_SECONDS := 35.0
const DEFAULT_FOG_DENSITY := 0.00008
const DEFAULT_VOLUMETRIC_FOG_DENSITY := 0.0015
const SPEED_MIN := 5.0
const SPEED_MAX := 900.0

var _camera: Camera3D
var _terrain: Terrain3D
var _sun: DirectionalLight3D
var _world_env: WorldEnvironment
var _sky_manager: SkyManager
var _material_rid: RID = RID()
var _mw_texture_bridge: RefCounted = null

var _status_label: Label
var _diag_label: Label
var _capture_button: Button
var _mouse_captured := false
var _yaw := 135.0
var _pitch := -22.0
var _move_speed := 120.0
var _sky_enabled := true
var _sun_enabled := true
var _depth_fog_enabled := true
var _volumetric_fog_enabled := false
var _day_cycle_enabled := true
var _game_hour := DEFAULT_GAME_HOUR
var _fog_density := DEFAULT_FOG_DENSITY
var _volumetric_fog_density := DEFAULT_VOLUMETRIC_FOG_DENSITY

var _regions_loaded := 0
var _mw_texture_layers := 0
var _terrain_data_dir := ""
var _data_status := "not loaded"
var _shader_status := "not applied"
var _mw_texture_status := "not initialized"


func _ready() -> void:
	InputActionsScript.verify()
	_setup_environment()
	_setup_sun()
	_setup_sky_manager()
	_setup_camera()
	await _setup_terrain()
	_create_ui()

	for i in 5:
		await get_tree().process_frame

	_apply_shader_override()
	_push_default_erosion_params()
	await _ensure_morrowind_data_loaded()
	_init_mw_texture_bridge()
	_set_mouse_captured(false)
	_update_status()


func _setup_environment() -> void:
	_world_env = WorldEnvironment.new()
	_world_env.name = "FallbackWorldEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.38, 0.46, 0.58)
	sky_mat.sky_horizon_color = Color(0.68, 0.70, 0.66)
	sky_mat.ground_bottom_color = Color(0.09, 0.07, 0.05)
	sky_mat.ground_horizon_color = Color(0.28, 0.25, 0.20)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_apply_fog_to_environment(env)
	_world_env.environment = env
	add_child(_world_env)


func _setup_sun() -> void:
	_sun = DirectionalLight3D.new()
	_sun.name = "FallbackSun"
	_sun.shadow_enabled = true
	_sun.light_energy = 1.4
	_sun.light_volumetric_fog_energy = 6.0
	_update_fallback_sun()
	add_child(_sun)


func _setup_sky_manager() -> void:
	_sky_manager = SkyManager.new()
	_sky_manager.name = "SkyManager"
	add_child(_sky_manager)
	_sky_manager.update(_game_hour)
	_apply_fog_to_environment(_sky_manager.get_environment())
	_set_sky_enabled(_sky_enabled)
	_set_sun_enabled(_sun_enabled)


func _apply_fog_to_environment(env: Environment) -> void:
	if not env:
		return

	env.fog_enabled = _depth_fog_enabled
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_density = _fog_density
	env.fog_light_color = Color(0.7, 0.75, 0.82)
	env.fog_light_energy = 1.0
	env.fog_sun_scatter = 0.5
	env.fog_aerial_perspective = 0.8
	env.fog_sky_affect = 0.15
	env.fog_height = 0.0
	env.fog_height_density = 0.003

	env.volumetric_fog_enabled = _volumetric_fog_enabled
	env.volumetric_fog_density = _volumetric_fog_density
	env.volumetric_fog_albedo = Color(0.95, 0.95, 0.98)
	env.volumetric_fog_emission = Color.BLACK
	env.volumetric_fog_anisotropy = 0.55
	env.volumetric_fog_length = 800.0
	env.volumetric_fog_detail_spread = 2.0
	env.volumetric_fog_gi_inject = 0.5
	env.volumetric_fog_sky_affect = 0.15
	env.volumetric_fog_temporal_reprojection_enabled = true
	env.volumetric_fog_temporal_reprojection_amount = 0.7


func _set_sky_enabled(enabled: bool) -> void:
	_sky_enabled = enabled
	if _sky_manager:
		_sky_manager.enabled = enabled
	if _world_env:
		_world_env.environment = null if enabled else _world_env.environment
		if not enabled and not _world_env.environment:
			var env := Environment.new()
			env.background_mode = Environment.BG_SKY
			var sky := Sky.new()
			var sky_mat := ProceduralSkyMaterial.new()
			sky_mat.sky_top_color = Color(0.38, 0.46, 0.58)
			sky_mat.sky_horizon_color = Color(0.68, 0.70, 0.66)
			sky_mat.ground_bottom_color = Color(0.09, 0.07, 0.05)
			sky_mat.ground_horizon_color = Color(0.28, 0.25, 0.20)
			sky.sky_material = sky_mat
			env.sky = sky
			env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
			env.ambient_light_sky_contribution = 0.55
			env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
			_apply_fog_to_environment(env)
			_world_env.environment = env
	_apply_active_fog_settings()
	_set_sun_enabled(_sun_enabled)


func _set_sun_enabled(enabled: bool) -> void:
	_sun_enabled = enabled
	if _sky_manager:
		var sky_sun := _sky_manager.get_sun_light()
		if sky_sun:
			sky_sun.visible = enabled and _sky_enabled
			sky_sun.light_volumetric_fog_energy = 6.0 if _volumetric_fog_enabled else 0.0
		var sky_moon := _sky_manager.get_moon_light()
		if sky_moon:
			sky_moon.visible = _sky_enabled
	if _sun:
		_sun.visible = enabled and not _sky_enabled
		_sun.light_volumetric_fog_energy = 6.0 if _volumetric_fog_enabled else 0.0


func _apply_active_fog_settings() -> void:
	if _sky_manager:
		_apply_fog_to_environment(_sky_manager.get_environment())
	if _world_env and _world_env.environment:
		_apply_fog_to_environment(_world_env.environment)
	_set_sun_enabled(_sun_enabled)


func _update_lighting(delta: float) -> void:
	if _day_cycle_enabled:
		var daylight_span := DAYLIGHT_END_HOUR - DAYLIGHT_START_HOUR
		var daylight_offset := _game_hour - DAYLIGHT_START_HOUR
		daylight_offset = fposmod(daylight_offset + delta * daylight_span / DAYLIGHT_CYCLE_SECONDS, daylight_span)
		_game_hour = DAYLIGHT_START_HOUR + daylight_offset
	else:
		_game_hour = clampf(_game_hour, DAYLIGHT_START_HOUR, DAYLIGHT_END_HOUR)

	if _sky_manager:
		_sky_manager.update(_game_hour)
		_set_sun_enabled(_sun_enabled)
	_update_fallback_sun()


func _update_fallback_sun() -> void:
	if not _sun:
		return

	var phase := (_game_hour - 6.0) / 24.0 * TAU
	var altitude := sin(phase)
	var direction := Vector3(cos(phase) * 0.35, altitude, -0.85).normalized()
	_sun.basis = SkyManager._direction_to_light_basis(direction)
	_sun.light_energy = lerpf(0.0, 1.4, clampf(altitude, 0.0, 1.0))
	_sun.light_color = Color(1.0, lerpf(0.72, 0.98, clampf(altitude, 0.0, 1.0)), lerpf(0.45, 0.95, clampf(altitude, 0.0, 1.0)))
	_sun.shadow_enabled = altitude > 0.02


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "FlyCamera"
	_camera.far = 12000.0
	_camera.current = true
	_camera.position = Vector3(0.0, 130.0, 0.0)
	_camera.rotation_degrees = Vector3(_pitch, _yaw, 0.0)
	add_child(_camera)


func _setup_terrain() -> void:
	_terrain = Terrain3D.new()
	_terrain.name = "Terrain3D"
	add_child(_terrain)
	_terrain.set_physics_process(false)
	await get_tree().process_frame

	if _terrain.has_method("set_camera"):
		_terrain.set_camera(_camera)

	if not CS.configure_terrain3d(_terrain):
		_data_status = "Terrain3D configure failed"
		Log.warn("testing", "[Terrain Erosion Lab] Terrain3D configure failed")
		return

	_terrain_data_dir = SettingsManager.get_terrain_path()
	if _terrain.data and DirAccess.dir_exists_absolute(_terrain_data_dir):
		_terrain.data.load_directory(_terrain_data_dir)
		_regions_loaded = _terrain.data.get_region_count()
		_data_status = "loaded %d regions" % _regions_loaded
		Log.info("testing", "[Terrain Erosion Lab] Terrain loaded: %d regions from %s" % [
			_regions_loaded, _terrain_data_dir])
	else:
		_data_status = "no terrain cache at %s" % _terrain_data_dir
		Log.warn("testing", "[Terrain Erosion Lab] No terrain data at %s" % _terrain_data_dir)


func _apply_shader_override() -> void:
	if not _terrain or not _terrain.material:
		_shader_status = "no Terrain3D material"
		return

	_terrain.material.set("shader_override", TerrainErosionShader)
	_terrain.material.set("shader_override_enabled", true)
	_material_rid = _terrain.material.get_material_rid()
	_shader_status = "erosion override active"
	Log.info("testing", "[Terrain Erosion Lab] Applied erosion shader override")


func _set_param(param_name: StringName, value: Variant) -> void:
	if not _material_rid.is_valid() and _terrain and _terrain.material:
		_material_rid = _terrain.material.get_material_rid()
	if _material_rid.is_valid():
		if value is Texture2D:
			value = (value as Texture2D).get_rid()
		RenderingServer.material_set_param(_material_rid, param_name, value)


func _push_default_erosion_params() -> void:
	_set_param(&"erosion_enabled", true)
	_set_param(&"erosion_near_zero_radius_m", DEFAULT_NEAR_RADIUS)
	_set_param(&"erosion_fade_width_m", DEFAULT_FADE_WIDTH)
	_set_param(&"erosion_scale", DEFAULT_EROSION_SCALE)
	_set_param(&"erosion_strength", DEFAULT_EROSION_STRENGTH)
	_set_param(&"erosion_gully_weight", DEFAULT_GULLY_WEIGHT)
	_set_param(&"erosion_detail", DEFAULT_EROSION_DETAIL)
	_set_param(&"erosion_normal_strength", DEFAULT_NORMAL_STRENGTH)
	_set_param(&"erosion_color_strength", DEFAULT_COLOR_STRENGTH)
	_set_param(&"erosion_vertex_displacement_m", DEFAULT_VERTEX_DISPLACEMENT)
	_set_param(&"erosion_debug_mode", 0)


func _ensure_morrowind_data_loaded() -> void:
	if ESMManager.lands.size() > 0:
		return

	var data_path := SettingsManager.get_data_path()
	if data_path.is_empty():
		data_path = SettingsManager.auto_detect_installation()
		if not data_path.is_empty():
			SettingsManager.set_data_path(data_path)
	if data_path.is_empty():
		_mw_texture_status = "no Morrowind data path"
		Log.warn("testing", "[Terrain Erosion Lab] No Morrowind data path configured")
		return

	BSAManager.load_archives_from_directory(data_path)
	var esm_path := data_path.path_join(SettingsManager.get_esm_file())
	var err := ESMManager.load_file(esm_path)
	if err != OK:
		_mw_texture_status = "ESM load failed: %s" % error_string(err)
		Log.warn("testing", "[Terrain Erosion Lab] ESM load failed: %s" % error_string(err))
	else:
		Log.info("testing", "[Terrain Erosion Lab] ESM loaded for terrain textures: %d LAND records" % ESMManager.lands.size())


func _init_mw_texture_bridge() -> void:
	if not _terrain or not _terrain.material:
		_mw_texture_status = "terrain material unavailable"
		return
	if ESMManager.lands.size() == 0:
		_mw_texture_status = "ESM LAND data unavailable"
		return

	_mw_texture_bridge = MorrowindTerrainTextureBridgeScript.new()
	var err: Error = _mw_texture_bridge.call("initialize", _terrain)
	if err != OK:
		_mw_texture_status = "bridge failed: %s" % error_string(err)
		Log.warn("testing", "[Terrain Erosion Lab] MW terrain texture bridge failed: %s" % error_string(err))
		return

	_mw_texture_bridge.call("rebuild_all_active_regions")
	_mw_texture_layers = int(_mw_texture_bridge.call("get_texture_array_layer_count"))
	_mw_texture_status = "MW layers: %d" % _mw_texture_layers
	Log.info("testing", "[Terrain Erosion Lab] MW terrain texture layers: %d" % _mw_texture_layers)


func _create_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "UI"
	add_child(canvas)

	var panel := PanelContainer.new()
	panel.position = Vector2(12.0, 12.0)
	panel.custom_minimum_size = Vector2(420.0, 0.0)
	canvas.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	margin.add_child(vbox)

	_status_label = Label.new()
	_status_label.text = "Terrain Erosion Filter Lab"
	_status_label.add_theme_font_size_override("font_size", 16)
	vbox.add_child(_status_label)

	_add_separator(vbox, "Lighting")
	_add_toggle(vbox, "Sky", _sky_enabled, func(on: bool) -> void:
		_set_sky_enabled(on)
	)
	_add_toggle(vbox, "Sun", _sun_enabled, func(on: bool) -> void:
		_set_sun_enabled(on)
	)
	_add_toggle(vbox, "Time cycle", _day_cycle_enabled, func(on: bool) -> void:
		_day_cycle_enabled = on
	)
	_add_slider(vbox, "Hour", DAYLIGHT_START_HOUR, DAYLIGHT_END_HOUR, _game_hour, 0.25, func(value: float) -> void:
		_game_hour = clampf(value, DAYLIGHT_START_HOUR, DAYLIGHT_END_HOUR)
		_update_lighting(0.0)
	)
	_add_toggle(vbox, "Depth fog", _depth_fog_enabled, func(on: bool) -> void:
		_depth_fog_enabled = on
		_apply_active_fog_settings()
	)
	_add_toggle(vbox, "Vol fog", _volumetric_fog_enabled, func(on: bool) -> void:
		_volumetric_fog_enabled = on
		_apply_active_fog_settings()
	)
	_add_slider(vbox, "Depth fog density", 0.0, 0.0004, _fog_density, 0.00001, func(value: float) -> void:
		_fog_density = value
		_apply_active_fog_settings()
	)
	_add_slider(vbox, "Vol fog density", 0.0, 0.01, _volumetric_fog_density, 0.0001, func(value: float) -> void:
		_volumetric_fog_density = value
		_apply_active_fog_settings()
	)

	_add_separator(vbox, "Erosion")
	_add_toggle(vbox, "Erosion", true, func(on: bool) -> void:
		_set_param(&"erosion_enabled", on)
	)
	_add_slider(vbox, "Near zero m", 0.0, 120.0, DEFAULT_NEAR_RADIUS, 1.0, func(value: float) -> void:
		_set_param(&"erosion_near_zero_radius_m", value)
	)
	_add_slider(vbox, "Fade width m", 1.0, 400.0, DEFAULT_FADE_WIDTH, 1.0, func(value: float) -> void:
		_set_param(&"erosion_fade_width_m", value)
	)
	_add_slider(vbox, "Filter scale m", 2.0, 120.0, DEFAULT_EROSION_SCALE, 0.5, func(value: float) -> void:
		_set_param(&"erosion_scale", value)
	)
	_add_slider(vbox, "Strength", 0.0, 2.0, DEFAULT_EROSION_STRENGTH, 0.01, func(value: float) -> void:
		_set_param(&"erosion_strength", value)
	)
	_add_slider(vbox, "Gully weight", 0.0, 1.0, DEFAULT_GULLY_WEIGHT, 0.01, func(value: float) -> void:
		_set_param(&"erosion_gully_weight", value)
	)
	_add_slider(vbox, "Detail", 0.1, 4.0, DEFAULT_EROSION_DETAIL, 0.01, func(value: float) -> void:
		_set_param(&"erosion_detail", value)
	)
	_add_slider(vbox, "Normal strength", 0.0, 32.0, DEFAULT_NORMAL_STRENGTH, 0.05, func(value: float) -> void:
		_set_param(&"erosion_normal_strength", value)
	)
	_add_slider(vbox, "Color strength", 0.0, 1.0, DEFAULT_COLOR_STRENGTH, 0.01, func(value: float) -> void:
		_set_param(&"erosion_color_strength", value)
	)
	_add_slider(vbox, "Height scale m", 0.0, 160.0, DEFAULT_VERTEX_DISPLACEMENT, 0.5, func(value: float) -> void:
		_set_param(&"erosion_vertex_displacement_m", value)
	)
	_add_debug_selector(vbox)

	_capture_button = Button.new()
	_capture_button.text = "Capture Mouse"
	_capture_button.pressed.connect(func() -> void:
		_set_mouse_captured(Input.mouse_mode != Input.MOUSE_MODE_CAPTURED)
	)
	vbox.add_child(_capture_button)

	_diag_label = Label.new()
	_diag_label.add_theme_font_size_override("font_size", 12)
	_diag_label.add_theme_color_override("font_color", Color(0.72, 0.82, 0.9))
	vbox.add_child(_diag_label)


func _add_separator(parent: Control, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color(0.86, 0.90, 0.94))
	parent.add_child(label)


func _add_slider(parent: Control, label_text: String, min_value: float, max_value: float, initial: float, step: float, callback: Callable) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 128.0
	row.add_child(label)

	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step
	slider.value = initial
	slider.custom_minimum_size.x = 180.0
	row.add_child(slider)

	var value_label := Label.new()
	value_label.text = _format_slider_value(initial, step)
	value_label.custom_minimum_size.x = 62.0
	row.add_child(value_label)

	slider.value_changed.connect(func(value: float) -> void:
		value_label.text = _format_slider_value(value, step)
		callback.call(value)
	)


func _format_slider_value(value: float, step: float) -> String:
	if step < 0.0001:
		return "%.5f" % value
	if step < 0.01:
		return "%.3f" % value
	return "%.2f" % value


func _add_toggle(parent: Control, label_text: String, initial: bool, callback: Callable) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 128.0
	row.add_child(label)
	var check := CheckBox.new()
	check.button_pressed = initial
	row.add_child(check)
	check.toggled.connect(callback)


func _add_debug_selector(parent: Control) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)

	var label := Label.new()
	label.text = "Debug"
	label.custom_minimum_size.x = 128.0
	row.add_child(label)

	var options := OptionButton.new()
	options.custom_minimum_size.x = 180.0
	options.add_item("Off", 0)
	options.add_item("Near mask", 1)
	options.add_item("Ridge field", 2)
	options.add_item("Drainage", 3)
	options.add_item("Height delta", 4)
	options.add_item("Base normal", 5)
	options.add_item("Eroded normal", 6)
	options.add_item("Gully slope", 7)
	options.add_item("Texture normal", 8)
	options.add_item("Final normal", 9)
	options.item_selected.connect(func(index: int) -> void:
		_set_param(&"erosion_debug_mode", options.get_item_id(index))
	)
	row.add_child(options)


func _process(delta: float) -> void:
	_update_lighting(delta)
	_update_camera(delta)
	_update_status()


func _update_camera(delta: float) -> void:
	var speed := _move_speed
	if Input.is_action_pressed(&"sprint"):
		speed *= 3.0

	var input_vec := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_backward")
	var move := _camera.global_basis.x * input_vec.x
	move += -_camera.global_basis.z * -input_vec.y
	if Input.is_action_pressed(&"jump"):
		move += Vector3.UP
	if Input.is_action_pressed(&"crouch"):
		move += Vector3.DOWN

	if move.length_squared() > 0.0001:
		_camera.global_position += move.normalized() * speed * delta


func _update_status() -> void:
	if _status_label:
		_status_label.text = "Terrain Erosion Filter Lab - FPS %.0f" % Engine.get_frames_per_second()
	if _diag_label:
		_diag_label.text = "terrain: %s\ntextures: %s\nshader: %s\nhour: %.2f sky:%s sun:%s fog:%s %.5f / vol:%s %.4f\npos: %s speed: %.0f\nRMB drag=look, wheel=speed, ui_cancel=mouse" % [
			_data_status,
			_mw_texture_status,
			_shader_status,
			_game_hour,
			"on" if _sky_enabled else "off",
			"on" if _sun_enabled else "off",
			"on" if _depth_fog_enabled else "off",
			_fog_density,
			"on" if _volumetric_fog_enabled else "off",
			_volumetric_fog_density,
			str(_camera.global_position.snapped(Vector3.ONE)),
			_move_speed,
		]


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		_set_mouse_captured(Input.mouse_mode != Input.MOUSE_MODE_CAPTURED)
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseMotion and (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)):
		_yaw -= event.relative.x * 0.16
		_pitch -= event.relative.y * 0.16
		_pitch = clampf(_pitch, -89.0, 89.0)
		_camera.rotation_degrees = Vector3(_pitch, _yaw, 0.0)
		get_viewport().set_input_as_handled()

	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_move_speed = clampf(_move_speed * 1.2, SPEED_MIN, SPEED_MAX)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_move_speed = clampf(_move_speed / 1.2, SPEED_MIN, SPEED_MAX)
			get_viewport().set_input_as_handled()


func _set_mouse_captured(captured: bool) -> void:
	_mouse_captured = captured
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE
	if _capture_button:
		_capture_button.text = "Release Mouse" if captured else "Capture Mouse"
