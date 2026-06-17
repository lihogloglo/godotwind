extends Node3D
## Standalone SunshineClouds2 lab.
##
## Purpose: isolate the cloud compositor from Godotwind weather, ocean,
## streaming, and SkyManager so cloud-resource values can be tuned directly.
##
## Controls:
##   Right mouse drag: look
##   move_* actions: fly
##   jump/crouch: up/down
##   sprint: faster fly
##   ui_cancel: release mouse

const DRIVER_SCRIPT := "res://addons/SunshineClouds2/SunshineCloudsDriver.gd"
const CLOUDS_SCRIPT := "res://addons/SunshineClouds2/SunshineClouds.gd"
const NOISE_DIR := "res://addons/SunshineClouds2/NoiseTextures/"
const SHADER_DIR := "res://addons/SunshineClouds2/"
const MorrowindTerrainTextureLoaderScript := preload("res://src/core/world/morrowind/morrowind_terrain_texture_loader.gd")
const HorizonMapManagerScript := preload("res://src/core/world/horizon_map_manager.gd")
const MorrowindTerrainTextureBridgeScript := preload("res://src/core/world/morrowind/morrowind_terrain_texture_bridge.gd")
const WeatherDataScript := preload("res://src/core/weather/weather_data.gd")
const CloudShadowEffectScript := preload("res://src/core/shaders/effects/cloud_shadow_effect.gd")
const CS := preload("res://src/core/coordinate_system.gd")

const PRESET_PLUGIN_DEFAULT := 0
const PRESET_AUTHOR_EXAMPLE := 1
const PRESET_GODOTWIND_CURRENT := 2
const PRESET_STORM_WALL := 3
const PRESET_RED_MOUNTAIN_BELT := 4
const RED_MOUNTAIN_MASK_SIZE := 512
const RED_MOUNTAIN_MASK_WIDTH_KM := 4.0

var _camera: Camera3D
var _sky_manager: SkyManager
var _terrain: Terrain3D
var _horizon_map_manager: RefCounted
var _mw_terrain_texture_bridge: RefCounted
var _sunshine_driver: Node
var _clouds_resource: Resource
var _cloud_shadow_effect: PostProcessEffect
var _hud: RichTextLabel
var _preset_button: OptionButton
var _mouse_captured := false
var _fly_speed := 220.0
var _yaw := 0.0
var _pitch := -12.0
var _game_hour := 12.0
var _terrain_regions := 0
var _terrain_textures := 0
var _terrain_status := "not loaded"
var _morrowind_data_status := "not loaded"
var _cloud_mask_status := "noise"
var _terrain_focus := Vector3.ZERO
var _red_mountain_mask_texture: Texture2D

var _value_labels: Dictionary = {}


func _ready() -> void:
	_setup_sky()
	_setup_camera()
	_ensure_morrowind_data_loaded()
	_setup_terrain()
	_place_camera_at_terrain_focus()
	_setup_sunshine_clouds()
	_setup_cloud_shadows()
	_setup_ui()
	_apply_preset(PRESET_AUTHOR_EXAMPLE)
	Log.info("testing", "Clouds lab ready. Standalone SunshineClouds2 tuning scene loaded.")


func _exit_tree() -> void:
	if _sunshine_driver != null and is_instance_valid(_sunshine_driver):
		_sunshine_driver.update_continuously = false
		if _clouds_resource != null:
			_clouds_resource.set("enabled", false)
			_sunshine_driver.clouds_res_removed()
			_sunshine_driver.set("clouds_resource", null)
	if _clouds_resource != null and _clouds_resource.has_method("clear_compute"):
		_clouds_resource.call("clear_compute")
	if _cloud_shadow_effect != null:
		var world_env := _sky_manager.get_world_environment() if _sky_manager != null else null
		if world_env != null and world_env.compositor != null:
			var effects := world_env.compositor.compositor_effects
			effects.erase(_cloud_shadow_effect)
			world_env.compositor.compositor_effects = effects
		_cloud_shadow_effect.on_effect_removed()


func _process(delta: float) -> void:
	if _sky_manager != null:
		_sky_manager.update(_game_hour)
		if _clouds_resource != null:
			_sky_manager.cloud_coverage = float(_clouds_resource.get("clouds_coverage"))
	if _cloud_shadow_effect != null:
		_cloud_shadow_effect.update_weather_cache()
	_handle_fly_camera(delta)
	_update_hud()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_mouse_captured = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_mouse_captured = mb.pressed
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _mouse_captured else Input.MOUSE_MODE_VISIBLE
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_fly_speed = minf(_fly_speed * 1.15, 3000.0)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_fly_speed = maxf(_fly_speed / 1.15, 5.0)

	if event is InputEventMouseMotion and _mouse_captured:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * 0.12
		_pitch = clampf(_pitch - mm.relative.y * 0.12, -89.0, 89.0)
		_camera.rotation_degrees = Vector3(_pitch, _yaw, 0.0)


func _setup_sky() -> void:
	_sky_manager = SkyManager.new()
	_sky_manager.name = "SkyManager"
	add_child(_sky_manager)
	_sky_manager.update(_game_hour)
	var env := _sky_manager.get_environment()
	if env != null:
		env.glow_enabled = true
		env.glow_intensity = 0.25
		env.fog_enabled = true
		env.fog_mode = Environment.FOG_MODE_DEPTH
		env.fog_light_color = Color(0.73, 0.78, 0.86)
		env.fog_density = 0.0002
		env.fog_depth_begin = 6000.0
		env.fog_depth_end = 45000.0


func _setup_terrain() -> void:
	_terrain = Terrain3D.new()
	_terrain.name = "CloudLabMorrowindTerrain"
	add_child(_terrain)
	_terrain.set_physics_process(false)
	if _terrain.has_method("set_camera"):
		_terrain.set_camera(_camera)

	if not CS.configure_terrain3d(_terrain):
		_terrain_status = "Terrain3D configure failed"
		Log.warn("testing", "[Cloud Lab] %s" % _terrain_status)
		return

	var terrain_data_dir := SettingsManager.get_terrain_path()
	if _terrain.data and DirAccess.dir_exists_absolute(terrain_data_dir):
		_terrain.data.load_directory(terrain_data_dir)
		_terrain_regions = _terrain.data.get_region_count()
		_terrain_status = "loaded %d regions" % _terrain_regions
		Log.info("testing", "[Cloud Lab] Terrain loaded: %d regions from %s" % [
			_terrain_regions,
			terrain_data_dir,
		])
	else:
		_terrain_status = "no terrain data at %s" % terrain_data_dir
		Log.warn("testing", "[Cloud Lab] %s" % _terrain_status)
		_terrain_focus = Vector3.ZERO
		return

	if _terrain.assets:
		var texture_loader := MorrowindTerrainTextureLoaderScript.new()
		_terrain_textures = 1 if texture_loader.load_default_terrain_texture(_terrain.assets) else 0
	_setup_mw_terrain_textures()
	_terrain_focus = _find_terrain_focus()


func _ensure_morrowind_data_loaded() -> void:
	if ESMManager.lands.size() > 0 and ESMManager.land_textures.size() > 0:
		_morrowind_data_status = "already loaded: %d LAND, %d LTEX" % [
			ESMManager.lands.size(),
			ESMManager.land_textures.size(),
		]
		return

	var data_path := SettingsManager.get_data_path()
	if data_path.is_empty() or not DirAccess.dir_exists_absolute(data_path):
		data_path = SettingsManager.auto_detect_installation()
		if not data_path.is_empty():
			SettingsManager.set_data_path(data_path)

	if data_path.is_empty() or not DirAccess.dir_exists_absolute(data_path):
		_morrowind_data_status = "no Morrowind Data Files path"
		Log.warn("testing", "[Cloud Lab] %s" % _morrowind_data_status)
		return

	var bsa_count := 0
	if BSAManager.get_loaded_archives().is_empty():
		bsa_count = BSAManager.load_archives_from_directory(data_path)

	var esm_path := data_path.path_join(SettingsManager.get_esm_file())
	if not FileAccess.file_exists(esm_path):
		_morrowind_data_status = "missing ESM at %s" % esm_path
		Log.warn("testing", "[Cloud Lab] %s" % _morrowind_data_status)
		return

	if not ESMManager.loaded_files.has(esm_path):
		var err := ESMManager.load_file(esm_path)
		if err != OK:
			_morrowind_data_status = "ESM load failed: %s" % error_string(err)
			Log.warn("testing", "[Cloud Lab] %s" % _morrowind_data_status)
			return

	_morrowind_data_status = "%d BSA, %d LAND, %d LTEX" % [
		bsa_count if bsa_count > 0 else BSAManager.get_loaded_archives().size(),
		ESMManager.lands.size(),
		ESMManager.land_textures.size(),
	]
	Log.info("testing", "[Cloud Lab] Morrowind data ready: %s" % _morrowind_data_status)


func _setup_mw_terrain_textures() -> void:
	if _terrain == null or _terrain.material == null:
		return
	if ESMManager.lands.is_empty() or ESMManager.land_textures.is_empty():
		Log.warn("testing", "[Cloud Lab] MW terrain texture bridge skipped: %s" % _morrowind_data_status)
		return

	_horizon_map_manager = HorizonMapManagerScript.new()
	var sun_light := _sky_manager.get_sun_light()
	_horizon_map_manager.call("initialize", _terrain, sun_light)
	_horizon_map_manager.call("push_wet_map", 0.0)

	_mw_terrain_texture_bridge = MorrowindTerrainTextureBridgeScript.new()
	var err: Error = _mw_terrain_texture_bridge.call("initialize", _terrain)
	if err != OK:
		Log.warn("testing", "[Cloud Lab] MW terrain texture bridge failed: %s" % error_string(err))
		return
	_mw_terrain_texture_bridge.call("rebuild_all_active_regions")
	_terrain_textures = int(_mw_terrain_texture_bridge.call("get_texture_array_layer_count"))


func _find_terrain_focus() -> Vector3:
	if _terrain == null or _terrain.data == null or _terrain.data.get_region_count() == 0:
		return Vector3.ZERO

	var seyda_neen := CS.cell_grid_to_center_godot(Vector2i(-2, -9))
	var height := CS.get_terrain_height(seyda_neen, _terrain)
	if height > CS.OCEAN_FLOOR_GODOT + 1.0:
		return Vector3(seyda_neen.x, height, seyda_neen.z)

	var locations: Array[Vector2i] = _terrain.data.get_region_locations()
	if locations.is_empty():
		return Vector3.ZERO

	var region_size := float(_terrain.get_region_size()) * _terrain.get_vertex_spacing()
	var best_pos := Vector3.ZERO
	var best_score := -INF
	for loc: Vector2i in locations:
		var center := Vector3(
			(float(loc.x) + 0.5) * region_size,
			0.0,
			(float(loc.y) + 0.5) * region_size
		)
		var h := CS.get_terrain_height(center, _terrain)
		var score := h - absf(center.x) * 0.001 - absf(center.z) * 0.001
		if score > best_score:
			best_score = score
			best_pos = Vector3(center.x, h, center.z)
	return best_pos


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "FlyCamera"
	_camera.current = true
	_camera.far = 400000.0
	_camera.near = 0.2
	_camera.position = Vector3(500.0, 4200.0, 14500.0)
	_camera.rotation_degrees = Vector3(_pitch, _yaw, 0.0)
	add_child(_camera)


func _place_camera_at_terrain_focus() -> void:
	if _camera == null:
		return
	_camera.global_position = _terrain_focus + Vector3(220.0, 260.0, 700.0)
	_camera.look_at(_terrain_focus + Vector3(0.0, 45.0, 0.0), Vector3.UP)
	_pitch = _camera.rotation_degrees.x
	_yaw = _camera.rotation_degrees.y


func _setup_sunshine_clouds() -> void:
	if not ResourceLoader.exists(DRIVER_SCRIPT) or not ResourceLoader.exists(CLOUDS_SCRIPT):
		Log.warn("testing", "SunshineClouds2 plugin scripts are missing; cloud lab will show controls only.")
		return

	var driver_script := load(DRIVER_SCRIPT) as GDScript
	var clouds_script := load(CLOUDS_SCRIPT) as GDScript
	if driver_script == null or clouds_script == null:
		Log.warn("testing", "SunshineClouds2 scripts failed to load.")
		return

	_sunshine_driver = driver_script.new()
	_sunshine_driver.name = "SunshineCloudsDriver"
	add_child(_sunshine_driver)

	_clouds_resource = clouds_script.new()
	_load_cloud_dependencies(_clouds_resource)
	_sunshine_driver.ambience_sample_environment = _sky_manager.get_environment()
	_sunshine_driver.origin_offset = WeatherDataScript.RED_MOUNTAIN_GODOT
	var sun_light := _sky_manager.get_sun_light()
	var lights: Array[DirectionalLight3D] = [sun_light]
	_sunshine_driver.tracked_directional_lights = lights
	var shadow_steps: Array[int] = [32]
	_sunshine_driver.tracked_directional_light_shadow_steps = shadow_steps
	_sunshine_driver.clouds_resource = _clouds_resource
	_sunshine_driver.update_continuously = true


func _setup_cloud_shadows() -> void:
	if _sky_manager == null or _clouds_resource == null:
		return
	var world_env := _sky_manager.get_world_environment()
	if world_env == null:
		return
	if world_env.compositor == null:
		world_env.compositor = Compositor.new()

	_cloud_shadow_effect = CloudShadowEffectScript.new()
	_cloud_shadow_effect.set_sun(_sky_manager.get_sun_light())
	_cloud_shadow_effect.set_cloud_source(_clouds_resource)
	_cloud_shadow_effect.effect_enabled = true
	_cloud_shadow_effect.blend_factor = 1.0
	_cloud_shadow_effect.on_effect_added()

	var effects := world_env.compositor.compositor_effects
	effects.append(_cloud_shadow_effect)
	world_env.compositor.compositor_effects = effects
	Log.info("testing", "[Cloud Lab] Screen-space cloud shadows enabled")


func _load_cloud_dependencies(resource: Resource) -> void:
	var dependencies := {
		"curl_noise": NOISE_DIR + "curl_noise_varied.tga",
		"dither_noise": NOISE_DIR + "bluenoise_Dither.png",
		"height_gradient": NOISE_DIR + "HeightGradient.tres",
		"extra_large_noise_patterns": NOISE_DIR + "ExtraLargeScaleNoise.tres",
		"large_scale_noise": NOISE_DIR + "LargeScaleNoise.tres",
		"medium_scale_noise": NOISE_DIR + "MediumScaleNoise.tres",
		"small_scale_noise": NOISE_DIR + "SmallScaleNoise.tres",
		"pre_pass_compute_shader": SHADER_DIR + "SunshineCloudsPreCompute.glsl",
		"compute_shader": SHADER_DIR + "SunshineCloudsCompute.glsl",
		"post_pass_compute_shader": SHADER_DIR + "SunshineCloudsPostCompute.glsl",
	}
	for property_name in dependencies:
		var path: String = dependencies[property_name]
		if ResourceLoader.exists(path):
			resource.set(property_name, load(path))
		else:
			Log.warn("testing", "Missing SunshineClouds2 dependency: %s" % path)


func _setup_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "CloudLabUI"
	add_child(canvas)

	_hud = RichTextLabel.new()
	_hud.bbcode_enabled = true
	_hud.fit_content = true
	_hud.scroll_active = false
	_hud.position = Vector2(12.0, 12.0)
	_hud.size = Vector2(520.0, 350.0)
	_hud.add_theme_font_size_override("normal_font_size", 14)
	var hud_style := StyleBoxFlat.new()
	hud_style.bg_color = Color(0.02, 0.025, 0.03, 0.72)
	hud_style.set_content_margin_all(10)
	_hud.add_theme_stylebox_override("normal", hud_style)
	canvas.add_child(_hud)

	var panel := PanelContainer.new()
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = -360.0
	panel.offset_right = -12.0
	panel.offset_top = 12.0
	panel.offset_bottom = 760.0
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.02, 0.025, 0.03, 0.82)
	panel_style.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", panel_style)
	canvas.add_child(panel)

	var scroll := ScrollContainer.new()
	panel.add_child(scroll)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	scroll.add_child(vbox)

	var title := Label.new()
	title.text = "SunshineClouds2 Lab"
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)

	_preset_button = OptionButton.new()
	_preset_button.add_item("Author Example", PRESET_AUTHOR_EXAMPLE)
	_preset_button.add_item("Plugin Defaults", PRESET_PLUGIN_DEFAULT)
	_preset_button.add_item("Godotwind Current", PRESET_GODOTWIND_CURRENT)
	_preset_button.add_item("Storm Wall", PRESET_STORM_WALL)
	_preset_button.add_item("Red Mountain Belt", PRESET_RED_MOUNTAIN_BELT)
	_preset_button.selected = 0
	_preset_button.item_selected.connect(func(index: int) -> void:
		_apply_preset(_preset_button.get_item_id(index))
	)
	vbox.add_child(_labeled_control("Preset", _preset_button))

	var enabled := CheckButton.new()
	enabled.text = "Clouds enabled"
	enabled.button_pressed = true
	enabled.toggled.connect(func(on: bool) -> void:
		if _clouds_resource:
			_clouds_resource.set("enabled", on)
	)
	vbox.add_child(enabled)

	var shadows_enabled := CheckButton.new()
	shadows_enabled.text = "Cloud shadows enabled"
	shadows_enabled.button_pressed = true
	shadows_enabled.toggled.connect(func(on: bool) -> void:
		if _cloud_shadow_effect:
			_cloud_shadow_effect.effect_enabled = on
	)
	vbox.add_child(shadows_enabled)

	_add_slider(vbox, "Time of Day", "game_hour", 0.0, 24.0, 0.25)
	_add_time_buttons(vbox)
	_add_slider(vbox, "Coverage", "clouds_coverage", 0.0, 1.0, 0.001)
	_add_slider(vbox, "Density", "clouds_density", 0.0, 3.0, 0.01)
	_add_slider(vbox, "Sharpness", "clouds_sharpness", 0.0, 2.0, 0.001)
	_add_slider(vbox, "Detail Power", "clouds_detail_power", 0.0, 3.0, 0.001)
	_add_slider(vbox, "Accum Decay", "accumulation_decay", 0.0, 1.0, 0.001)
	_add_slider(vbox, "AO Alpha", "ambient_occlusion_color:a", 0.0, 1.0, 0.001)
	_add_slider(vbox, "Env Fog Mix", "use_environment_fog", 0.0, 1.0, 0.001)
	_add_slider(vbox, "Blur Power", "blur_power", 0.0, 8.0, 0.01)
	_add_slider(vbox, "Blur Quality", "blur_quality", 0.0, 4.0, 0.01)
	_add_slider(vbox, "Min Step", "min_step_distance", 25.0, 800.0, 1.0)
	_add_slider(vbox, "Max Step", "max_step_distance", 100.0, 1200.0, 1.0)
	_add_slider(vbox, "Cloud Floor", "cloud_floor", 0.0, 5000.0, 10.0)
	_add_slider(vbox, "Cloud Ceiling", "cloud_ceiling", 2000.0, 30000.0, 10.0)
	_add_slider(vbox, "Sun Energy", "light_energy", 0.0, 3.0, 0.01)
	_add_slider(vbox, "Wind Speed", "driver_wind_speed", 0.0, 600.0, 1.0)
	_add_slider(vbox, "Shadow Strength", "cloud_shadow_strength", 0.0, 0.75, 0.01)
	_add_slider(vbox, "Shadow Threshold", "cloud_shadow_threshold", 0.0, 1.0, 0.01)
	_add_slider(vbox, "Shadow Softness", "cloud_shadow_softness", 0.05, 1.0, 0.01)
	_add_slider(vbox, "Shadow Height", "cloud_shadow_height_bias", 0.0, 1.0, 0.01)
	_add_slider(vbox, "Shadow Debug", "cloud_shadow_debug", 0.0, 1.0, 1.0)

	var button_row := HBoxContainer.new()
	vbox.add_child(button_row)
	var reset_button := Button.new()
	reset_button.text = "Reset Accum"
	reset_button.pressed.connect(_reset_accumulation)
	button_row.add_child(reset_button)
	var high_button := Button.new()
	high_button.text = "Native Res"
	high_button.pressed.connect(func() -> void:
		if _clouds_resource:
			_clouds_resource.set("resolution_scale", 0)
			_reset_accumulation()
	)
	button_row.add_child(high_button)
	var half_button := Button.new()
	half_button.text = "Half Res"
	half_button.pressed.connect(func() -> void:
		if _clouds_resource:
			_clouds_resource.set("resolution_scale", 1)
			_reset_accumulation()
	)
	button_row.add_child(half_button)


func _labeled_control(text: String, control: Control) -> Control:
	var box := VBoxContainer.new()
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 12)
	box.add_child(label)
	box.add_child(control)
	return box


func _add_time_buttons(parent: Control) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	for entry: Dictionary in [
		{"label": "Dawn", "hour": 6.0},
		{"label": "Noon", "hour": 12.0},
		{"label": "Dusk", "hour": 18.0},
		{"label": "Night", "hour": 0.0},
	]:
		var button := Button.new()
		var hour := float(entry["hour"])
		button.text = entry["label"]
		button.custom_minimum_size.x = 72.0
		button.pressed.connect(func() -> void:
			_set_lab_property("game_hour", hour)
			_update_value_labels()
		)
		row.add_child(button)


func _add_slider(parent: Control, label_text: String, property_name: String, min_value: float, max_value: float, step: float) -> void:
	var box := VBoxContainer.new()
	parent.add_child(box)
	var label := Label.new()
	label.add_theme_font_size_override("font_size", 12)
	box.add_child(label)
	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step
	slider.custom_minimum_size.x = 310.0
	slider.value_changed.connect(func(value: float) -> void:
		_set_lab_property(property_name, value)
		_update_value_labels()
	)
	box.add_child(slider)
	_value_labels[property_name] = {
		"label": label,
		"slider": slider,
		"title": label_text,
	}


func _set_lab_property(property_name: String, value: float) -> void:
	match property_name:
		"ambient_occlusion_color:a":
			if _clouds_resource == null:
				return
			var color: Color = _clouds_resource.get("ambient_occlusion_color")
			color.a = value
			_clouds_resource.set("ambient_occlusion_color", color)
		"light_energy":
			var sun_light := _sky_manager.get_sun_light()
			if sun_light != null:
				sun_light.light_energy = value
		"game_hour":
			_game_hour = value
			_sky_manager.update(_game_hour)
		"driver_wind_speed":
			if _sunshine_driver == null:
				return
			_sunshine_driver.extra_large_structures_wind_speed = value
			_sunshine_driver.large_structures_wind_speed = value * 0.7
			_sunshine_driver.medium_structures_wind_speed = value * 0.3
			_sunshine_driver.small_structures_wind_speed = value * 0.1
		"cloud_shadow_strength":
			if _cloud_shadow_effect:
				_cloud_shadow_effect.set_param("strength", value)
		"cloud_shadow_threshold":
			if _cloud_shadow_effect:
				_cloud_shadow_effect.set_param("density_threshold", value)
		"cloud_shadow_softness":
			if _cloud_shadow_effect:
				_cloud_shadow_effect.set_param("softness", value)
		"cloud_shadow_height_bias":
			if _cloud_shadow_effect:
				_cloud_shadow_effect.set_param("height_bias", value)
		"cloud_shadow_debug":
			if _cloud_shadow_effect:
				_cloud_shadow_effect.set_param("debug_mode", value)
		"cloud_floor":
			if _clouds_resource == null:
				return
			var ceiling := float(_clouds_resource.get("cloud_ceiling"))
			var floor_value := minf(value, ceiling - 100.0)
			_clouds_resource.set("cloud_floor", floor_value)
		"cloud_ceiling":
			if _clouds_resource == null:
				return
			var floor := float(_clouds_resource.get("cloud_floor"))
			var ceiling_value := maxf(value, floor + 100.0)
			_clouds_resource.set("cloud_ceiling", ceiling_value)
		_:
			if _clouds_resource == null:
				return
			_clouds_resource.set(property_name, value)


func _get_lab_property(property_name: String) -> float:
	match property_name:
		"ambient_occlusion_color:a":
			if _clouds_resource == null:
				return 0.0
			var color: Color = _clouds_resource.get("ambient_occlusion_color")
			return color.a
		"light_energy":
			var sun_light := _sky_manager.get_sun_light()
			return sun_light.light_energy if sun_light != null else 0.0
		"game_hour":
			return _game_hour
		"driver_wind_speed":
			return float(_sunshine_driver.extra_large_structures_wind_speed) if _sunshine_driver != null else 0.0
		"cloud_shadow_strength":
			return float(_cloud_shadow_effect.get_param("strength")) if _cloud_shadow_effect != null else 0.0
		"cloud_shadow_threshold":
			return float(_cloud_shadow_effect.get_param("density_threshold")) if _cloud_shadow_effect != null else 0.0
		"cloud_shadow_softness":
			return float(_cloud_shadow_effect.get_param("softness")) if _cloud_shadow_effect != null else 0.0
		"cloud_shadow_height_bias":
			return float(_cloud_shadow_effect.get_param("height_bias")) if _cloud_shadow_effect != null else 0.0
		"cloud_shadow_debug":
			return float(_cloud_shadow_effect.get_param("debug_mode")) if _cloud_shadow_effect != null else 0.0
		_:
			if _clouds_resource == null:
				return 0.0
			return float(_clouds_resource.get(property_name))


func _apply_preset(preset_id: int) -> void:
	if _clouds_resource == null:
		return

	# Start from plugin script defaults by constructing a fresh resource and
	# copying only authored settings onto the live resource. This keeps the
	# compositor registered while still giving us a clean baseline.
	var clouds_script := load(CLOUDS_SCRIPT) as GDScript
	var defaults: Resource = clouds_script.new() if clouds_script else null
	if defaults:
		for property_name in [
			"clouds_coverage", "clouds_density", "atmospheric_density",
			"lighting_density", "fog_effect_ground", "use_environment_fog",
			"clouds_anisotropy", "clouds_powder", "cloud_ambient_color",
			"cloud_ambient_tint", "atmosphere_color", "sampled_environment_fog_color",
			"ambient_occlusion_color", "accumulation_decay",
			"extra_large_noise_scale", "large_noise_scale", "medium_noise_scale",
			"small_noise_scale", "clouds_sharpness", "clouds_detail_power",
			"curl_noise_strength", "lighting_sharpness", "wind_swept_range",
			"wind_swept_strength", "cloud_floor", "cloud_ceiling",
			"max_step_count", "max_lighting_steps", "resolution_scale",
			"lod_bias", "dither_speed", "blur_power", "blur_quality",
			"min_step_distance", "max_step_distance", "lighting_travel_distance",
			"extra_large_used_as_mask", "mask_width_km",
		]:
			_clouds_resource.set(property_name, defaults.get(property_name))

	_restore_default_cloud_mask_source()
	_set_lab_property("cloud_shadow_strength", 0.22)
	_set_lab_property("cloud_shadow_threshold", 0.08)
	_set_lab_property("cloud_shadow_softness", 0.45)
	_set_lab_property("cloud_shadow_height_bias", 0.50)
	_set_lab_property("cloud_shadow_debug", 0.0)

	match preset_id:
		PRESET_AUTHOR_EXAMPLE:
			_clouds_resource.set("clouds_coverage", 0.726)
			_clouds_resource.set("clouds_density", 1.0)
			_clouds_resource.set("atmospheric_density", 0.5)
			_clouds_resource.set("lighting_density", 0.55)
			_clouds_resource.set("clouds_anisotropy", 0.057)
			_clouds_resource.set("cloud_ambient_color", Color(1.0, 1.0, 1.0, 1.0))
			_clouds_resource.set("cloud_ambient_tint", Color(0.1276, 0.18766, 0.22, 1.0))
			_clouds_resource.set("atmosphere_color", Color(0.280153, 0.544962, 0.759771, 1.0))
			_clouds_resource.set("ambient_occlusion_color", Color(0.693375, 0.223129, 0.0, 0.466667))
			_clouds_resource.set("accumulation_decay", 0.8)
			_clouds_resource.set("extra_large_noise_scale", 298497.0)
			_clouds_resource.set("large_noise_scale", 85138.6)
			_clouds_resource.set("medium_noise_scale", 20043.3)
			_clouds_resource.set("small_noise_scale", 6901.78)
			_clouds_resource.set("clouds_sharpness", 0.5)
			_clouds_resource.set("clouds_detail_power", 0.0)
			_clouds_resource.set("curl_noise_strength", 6184.1)
			_clouds_resource.set("lighting_sharpness", 0.34)
			_clouds_resource.set("cloud_floor", 1500.0)
			_clouds_resource.set("cloud_ceiling", 15000.0)
			_clouds_resource.set("resolution_scale", 1)
			_clouds_resource.set("dither_speed", 100.825)
			_clouds_resource.set("blur_power", 1.0)
			_clouds_resource.set("blur_quality", 1.0)
			_clouds_resource.set("min_step_distance", 100.0)
			_clouds_resource.set("max_step_distance", 600.0)
			_clouds_resource.set("lighting_travel_distance", 8000.0)
			_clouds_resource.set("extra_large_used_as_mask", true)
			_clouds_resource.set("mask_width_km", 512.0)
			_set_lab_property("light_energy", 1.0)
			_set_lab_property("driver_wind_speed", 140.0)
		PRESET_GODOTWIND_CURRENT:
			_clouds_resource.set("clouds_coverage", 0.726)
			_clouds_resource.set("clouds_density", 1.0)
			_clouds_resource.set("clouds_sharpness", 0.5)
			_clouds_resource.set("clouds_detail_power", 0.0)
			_clouds_resource.set("lighting_density", 0.55)
			_clouds_resource.set("lighting_sharpness", 0.34)
			_clouds_resource.set("cloud_floor", 1500.0)
			_clouds_resource.set("cloud_ceiling", 15000.0)
			_clouds_resource.set("accumulation_decay", 0.8)
			_clouds_resource.set("use_environment_fog", 0.0)
			_clouds_resource.set("cloud_ambient_tint", Color(0.1276, 0.18766, 0.22, 1.0))
			_clouds_resource.set("ambient_occlusion_color", Color(0.693375, 0.223129, 0.0, 0.466667))
			_clouds_resource.set("extra_large_noise_scale", 298497.0)
			_clouds_resource.set("large_noise_scale", 85138.6)
			_clouds_resource.set("medium_noise_scale", 20043.3)
			_clouds_resource.set("small_noise_scale", 6901.78)
			_clouds_resource.set("curl_noise_strength", 6184.1)
			_clouds_resource.set("min_step_distance", 100.0)
			_clouds_resource.set("max_step_distance", 600.0)
			_clouds_resource.set("lighting_travel_distance", 8000.0)
			_clouds_resource.set("extra_large_used_as_mask", true)
			_clouds_resource.set("mask_width_km", 512.0)
			_clouds_resource.set("blur_power", 1.0)
			_clouds_resource.set("blur_quality", 1.0)
			_set_lab_property("light_energy", 1.1)
			_set_lab_property("driver_wind_speed", 140.0)
		PRESET_STORM_WALL:
			_clouds_resource.set("clouds_coverage", 0.88)
			_clouds_resource.set("clouds_density", 1.35)
			_clouds_resource.set("clouds_sharpness", 0.72)
			_clouds_resource.set("clouds_detail_power", 0.65)
			_clouds_resource.set("lighting_density", 0.75)
			_clouds_resource.set("cloud_ambient_color", Color(0.42, 0.46, 0.55, 1.0))
			_clouds_resource.set("cloud_ambient_tint", Color(0.65, 0.7, 0.78, 1.0))
			_clouds_resource.set("atmosphere_color", Color(0.35, 0.43, 0.56, 1.0))
			_clouds_resource.set("ambient_occlusion_color", Color(0.18, 0.16, 0.15, 0.45))
			_clouds_resource.set("accumulation_decay", 0.7)
			_clouds_resource.set("cloud_floor", 700.0)
			_clouds_resource.set("cloud_ceiling", 11000.0)
			_clouds_resource.set("resolution_scale", 1)
			_set_lab_property("light_energy", 0.75)
			_set_lab_property("driver_wind_speed", 320.0)
		PRESET_RED_MOUNTAIN_BELT:
			_clouds_resource.set("clouds_coverage", 0.78)
			_clouds_resource.set("clouds_density", 1.18)
			_clouds_resource.set("clouds_sharpness", 0.42)
			_clouds_resource.set("clouds_detail_power", 0.35)
			_clouds_resource.set("lighting_density", 0.58)
			_clouds_resource.set("lighting_sharpness", 0.30)
			_clouds_resource.set("cloud_ambient_color", Color(0.78, 0.80, 0.82, 1.0))
			_clouds_resource.set("cloud_ambient_tint", Color(0.38, 0.44, 0.52, 1.0))
			_clouds_resource.set("atmosphere_color", Color(0.42, 0.54, 0.68, 1.0))
			_clouds_resource.set("ambient_occlusion_color", Color(0.24, 0.20, 0.16, 0.42))
			_clouds_resource.set("accumulation_decay", 0.74)
			_clouds_resource.set("cloud_floor", 450.0)
			_clouds_resource.set("cloud_ceiling", 2600.0)
			_clouds_resource.set("curl_noise_strength", 7600.0)
			_clouds_resource.set("wind_swept_range", 0.45)
			_clouds_resource.set("wind_swept_strength", 850.0)
			_clouds_resource.set("min_step_distance", 70.0)
			_clouds_resource.set("max_step_distance", 420.0)
			_clouds_resource.set("extra_large_used_as_mask", true)
			_clouds_resource.set("mask_width_km", RED_MOUNTAIN_MASK_WIDTH_KM)
			_clouds_resource.set("extra_large_noise_patterns", _get_red_mountain_mask_texture())
			_sunshine_driver.origin_offset = WeatherDataScript.RED_MOUNTAIN_GODOT
			_cloud_mask_status = "Red Mountain alpha mask %.1fkm centered at %s" % [
				RED_MOUNTAIN_MASK_WIDTH_KM,
				str(WeatherDataScript.RED_MOUNTAIN_GODOT.round()),
			]
			_clouds_resource.set("resolution_scale", 1)
			_set_lab_property("game_hour", 8.0)
			_set_lab_property("light_energy", 0.95)
			_set_lab_property("driver_wind_speed", 180.0)
		_:
			_set_lab_property("light_energy", 1.15)
			_set_lab_property("driver_wind_speed", 140.0)

	_clouds_resource.set("enabled", true)
	_sunshine_driver.retrieve_texture_data()
	_reset_accumulation()
	_update_value_labels()


func _restore_default_cloud_mask_source() -> void:
	if _clouds_resource == null:
		return
	var noise_path := NOISE_DIR + "ExtraLargeScaleNoise.tres"
	if ResourceLoader.exists(noise_path):
		_clouds_resource.set("extra_large_noise_patterns", load(noise_path))
	_sunshine_driver.origin_offset = WeatherDataScript.RED_MOUNTAIN_GODOT
	_cloud_mask_status = "plugin noise"


func _get_red_mountain_mask_texture() -> Texture2D:
	if _red_mountain_mask_texture != null:
		return _red_mountain_mask_texture

	var noise := FastNoiseLite.new()
	noise.seed = 446
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 2.35
	noise.fractal_octaves = 4
	noise.fractal_gain = 0.52

	var img := Image.create(RED_MOUNTAIN_MASK_SIZE, RED_MOUNTAIN_MASK_SIZE, false, Image.FORMAT_RGBAF)
	var center := Vector2(0.5, 0.5)
	for y in range(RED_MOUNTAIN_MASK_SIZE):
		for x in range(RED_MOUNTAIN_MASK_SIZE):
			var uv := Vector2(
				(float(x) + 0.5) / float(RED_MOUNTAIN_MASK_SIZE),
				(float(y) + 0.5) / float(RED_MOUNTAIN_MASK_SIZE)
			)
			var p := (uv - center) * 2.0
			var radius := p.length()
			var angle := atan2(p.y, p.x)
			var ring := _smoothstep(0.22, 0.34, radius) * (1.0 - _smoothstep(0.72, 0.96, radius))
			var radial_breakup := 0.5 + 0.5 * noise.get_noise_2d(p.x * 2.2, p.y * 2.2)
			var banding := 0.5 + 0.5 * sin(angle * 5.0 + radius * 11.0)
			var patch := clampf(radial_breakup * 0.78 + banding * 0.22, 0.0, 1.0)
			var alpha := ring * _smoothstep(0.28, 0.82, patch)
			alpha = pow(alpha, 0.75)
			var tint := Color(0.74, 0.70, 0.62, alpha)
			img.set_pixel(x, y, tint)

	_red_mountain_mask_texture = ImageTexture.create_from_image(img)
	return _red_mountain_mask_texture


func _smoothstep(edge0: float, edge1: float, x: float) -> float:
	var t := clampf((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _reset_accumulation() -> void:
	if _clouds_resource:
		_clouds_resource.set("last_size", Vector2i.ZERO)
		if _clouds_resource.has_method("refresh_compute"):
			_clouds_resource.call("refresh_compute")


func _update_value_labels() -> void:
	for property_name in _value_labels.keys():
		var entry: Dictionary = _value_labels[property_name]
		var label: Label = entry.label
		var slider: HSlider = entry.slider
		var value := _get_lab_property(property_name)
		slider.set_value_no_signal(value)
		label.text = "%s: %.3f" % [entry.title, value]


func _handle_fly_camera(delta: float) -> void:
	if not _mouse_captured:
		return
	var move_input := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var direction := _camera.global_basis.x * move_input.x
	direction += _camera.global_basis.z * move_input.y
	if Input.is_action_pressed("jump"):
		direction += Vector3.UP
	if Input.is_action_pressed("crouch"):
		direction -= Vector3.UP
	if direction.length_squared() > 0.001:
		var speed := _fly_speed * (3.0 if Input.is_action_pressed("sprint") else 1.0)
		_camera.global_position += direction.normalized() * speed * delta


func _update_hud() -> void:
	if _hud == null:
		return
	if _clouds_resource == null:
		_hud.text = "[b]SunshineClouds2 Lab[/b]\nPlugin resource failed to initialize."
		return
	var lines := PackedStringArray()
	lines.append("[b]SUNSHINECLOUDS2 LAB[/b]")
	lines.append("Fly: right mouse + move actions | jump/crouch up/down | sprint fast")
	lines.append("Camera: %s | Speed %.0f m/s | FPS %d" % [str(_camera.global_position.round()), _fly_speed, Engine.get_frames_per_second()])
	lines.append("Terrain: %s | textures=%d | focus=%s" % [
		_terrain_status,
		_terrain_textures,
		str(_terrain_focus.round()),
	])
	var sun_light := _sky_manager.get_sun_light()
	if sun_light != null:
		lines.append("SkyManager sun: hour %.2f | energy %.2f | color %s" % [
			_game_hour,
			sun_light.light_energy,
			str(sun_light.light_color),
		])
	lines.append("")
	lines.append("Current key values:")
	lines.append("  accumulation_decay: %.3f" % float(_clouds_resource.get("accumulation_decay")))
	lines.append("  coverage/density/sharpness: %.3f / %.3f / %.3f" % [
		float(_clouds_resource.get("clouds_coverage")),
		float(_clouds_resource.get("clouds_density")),
		float(_clouds_resource.get("clouds_sharpness")),
	])
	lines.append("  detail power: %.3f" % float(_clouds_resource.get("clouds_detail_power")))
	lines.append("  floor/ceiling: %.0f / %.0f m" % [
		float(_clouds_resource.get("cloud_floor")),
		float(_clouds_resource.get("cloud_ceiling")),
	])
	lines.append("  resolution_scale: %s (0 native, 1 half)" % str(_clouds_resource.get("resolution_scale")))
	lines.append("  use_environment_fog: %.3f" % float(_clouds_resource.get("use_environment_fog")))
	lines.append("  mask: %s" % _cloud_mask_status)
	if _cloud_shadow_effect != null:
		lines.append("  cloud shadows: %s | strength %.2f | debug %d" % [
			"on" if _cloud_shadow_effect.effect_enabled else "off",
			float(_cloud_shadow_effect.get_param("strength")),
			int(_cloud_shadow_effect.get_param("debug_mode")),
		])
	lines.append("")
	lines.append("Known comparison:")
	lines.append("  Plugin script default decay: 0.700")
	lines.append("  Plugin author example decay: 0.800")
	lines.append("  Godotwind current runtime decay: 0.550")
	_hud.text = "\n".join(lines)
