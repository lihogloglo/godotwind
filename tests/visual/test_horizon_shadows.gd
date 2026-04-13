## Visual test for horizon map self-shadowing on terrain.
##
## Loads terrain with horizon maps and provides a sun rotation control
## so you can see the self-shadowing change in real time.
##
## Launch:
##   godot --path . res://tests/visual/test_horizon_shadows.tscn
##
## What to look for:
##   - Terrain behind hills/mountains should darken when the sun is low
##   - Shadow should rotate as you drag the sun azimuth slider
##   - Shadow should appear/disappear as sun elevation changes
##   - Only 10 of 289 regions are baked — most terrain will show no shadow
extends Node3D

const CS := preload("res://src/core/coordinate_system.gd")
const TerrainManagerScript := preload("res://src/core/world/terrain_manager.gd")
const HorizonMapManagerScript := preload("res://src/core/world/horizon_map_manager.gd")

var _terrain: Terrain3D = null
var _sun: DirectionalLight3D = null
var _horizon_mgr: HorizonMapManager = null
var _camera: Camera3D = null

# Sun control
var _sun_azimuth: float = 0.5  # 0-1, maps to 0-360 degrees
var _sun_elevation: float = 0.3  # 0-1, maps to 0-90 degrees
var _shadow_enabled: bool = true

# UI
var _azimuth_slider: HSlider = null
var _elevation_slider: HSlider = null
var _info_label: Label = null
var _toggle_btn: CheckButton = null


func _ready() -> void:
	Log.info("testing", "=== HORIZON MAP SHADOW TEST ===")

	_setup_camera()
	_setup_sun()
	_setup_terrain()
	_setup_ui()


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "TestCamera"
	_camera.current = true
	_camera.far = 10000.0
	add_child(_camera)

	# Position above a baked region — region (0, -3) center
	# World pos: region * 256 * vertex_spacing + half_region
	var vs: float = CS.TERRAIN_VERTEX_SPACING  # ~1.829
	var region_world_x: float = 0.0 * 256.0 * vs + 128.0 * vs  # ~234
	var region_world_z: float = -3.0 * 256.0 * vs + 128.0 * vs  # ~-1170
	_camera.position = Vector3(region_world_x, 300.0, region_world_z)
	_camera.rotation_degrees = Vector3(-30, 0, 0)


func _setup_sun() -> void:
	_sun = DirectionalLight3D.new()
	_sun.name = "TestSun"
	_sun.shadow_enabled = true
	_sun.light_energy = 1.0
	add_child(_sun)
	_update_sun_transform()


func _setup_terrain() -> void:
	await get_tree().process_frame

	_terrain = Terrain3D.new()
	_terrain.name = "TestTerrain3D"
	CS.configure_terrain3d_pre_tree(_terrain)
	add_child(_terrain)
	_terrain.set_physics_process(false)
	_terrain.set_process(false)

	await get_tree().process_frame

	if _terrain.has_method("set_camera"):
		_terrain.set_camera(_camera)

	if not CS.configure_terrain3d(_terrain):
		Log.error("testing", "Failed to configure Terrain3D")
		return

	Log.info("testing", "Terrain3D configured, vertex_spacing=%.3f" % _terrain.get_vertex_spacing())

	# Load terrain data from cache
	var terrain_path: String = SettingsManager.get_terrain_path()
	if DirAccess.dir_exists_absolute(terrain_path):
		_terrain.data.load_directory(terrain_path)
		var region_count: int = _terrain.data.get_region_count()
		Log.info("testing", "Loaded %d terrain regions from %s" % [region_count, terrain_path])
	else:
		Log.error("testing", "No terrain cache at %s — run prebaking first" % terrain_path)
		return

	# Try to load terrain textures (requires ESM data — may get 0 in standalone test)
	var texture_loader := preload("res://src/core/world/terrain_texture_loader.gd").new()
	var textures_loaded: int = texture_loader.load_terrain_textures(_terrain.assets)
	Log.info("testing", "Loaded %d terrain textures" % textures_loaded)

	# Initialize horizon maps (applies shader override)
	_horizon_mgr = HorizonMapManagerScript.new()
	_horizon_mgr.initialize(_terrain, _sun)

	# If no textures loaded, disable texturing so terrain is visible as gray
	# instead of black. Horizon shadows will be clearly visible on the gray surface.
	if textures_loaded == 0:
		Log.info("testing", "No textures — disabling texturing for clean horizon shadow view")
		var mat_rid: RID = _terrain.material.get_material_rid()
		RenderingServer.material_set_param(mat_rid, "enable_texturing", false)
	if _horizon_mgr._enabled:
		Log.info("testing", "Horizon maps active — move sun sliders to see shadows")
	else:
		Log.warn("testing", "Horizon maps did NOT activate — check logs above for errors")


func _setup_ui() -> void:
	var panel := PanelContainer.new()
	panel.position = Vector2(10, 10)
	panel.size = Vector2(350, 220)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "Horizon Shadow Test"
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)

	# Azimuth slider
	var az_label := Label.new()
	az_label.text = "Sun Azimuth (rotation)"
	vbox.add_child(az_label)
	_azimuth_slider = HSlider.new()
	_azimuth_slider.min_value = 0.0
	_azimuth_slider.max_value = 1.0
	_azimuth_slider.step = 0.01
	_azimuth_slider.value = _sun_azimuth
	_azimuth_slider.custom_minimum_size.x = 300
	_azimuth_slider.value_changed.connect(_on_azimuth_changed)
	vbox.add_child(_azimuth_slider)

	# Elevation slider
	var el_label := Label.new()
	el_label.text = "Sun Elevation (height)"
	vbox.add_child(el_label)
	_elevation_slider = HSlider.new()
	_elevation_slider.min_value = 0.01
	_elevation_slider.max_value = 1.0
	_elevation_slider.step = 0.01
	_elevation_slider.value = _sun_elevation
	_elevation_slider.custom_minimum_size.x = 300
	_elevation_slider.value_changed.connect(_on_elevation_changed)
	vbox.add_child(_elevation_slider)

	# Toggle
	_toggle_btn = CheckButton.new()
	_toggle_btn.text = "Horizon shadows enabled"
	_toggle_btn.button_pressed = true
	_toggle_btn.toggled.connect(_on_toggle_shadows)
	vbox.add_child(_toggle_btn)

	# Info label
	_info_label = Label.new()
	_info_label.text = ""
	vbox.add_child(_info_label)

	# Add as CanvasLayer so it stays on screen
	var canvas := CanvasLayer.new()
	canvas.add_child(panel)
	add_child(canvas)


func _process(delta: float) -> void:
	if _horizon_mgr:
		_horizon_mgr.update_sun_direction()

	# Simple fly camera with mouse + WASD
	_handle_camera_input(delta)
	_update_info_label()


func _handle_camera_input(delta: float) -> void:
	var speed: float = 100.0
	if Input.is_action_pressed("sprint"):
		speed = 400.0

	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var dir := Vector3(input.x, 0, input.y)
	dir = _camera.global_basis * dir
	if Input.is_action_pressed("jump"):
		dir.y += 1.0
	if Input.is_action_pressed("crouch"):
		dir.y -= 1.0

	if dir.length_squared() > 0.01:
		_camera.position += dir.normalized() * speed * delta


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		var sensitivity: float = 0.002
		_camera.rotate_y(-event.relative.x * sensitivity)
		_camera.rotate_object_local(Vector3.RIGHT, -event.relative.y * sensitivity)


func _on_azimuth_changed(value: float) -> void:
	_sun_azimuth = value
	_update_sun_transform()


func _on_elevation_changed(value: float) -> void:
	_sun_elevation = value
	_update_sun_transform()


func _on_toggle_shadows(pressed: bool) -> void:
	_shadow_enabled = pressed
	if _horizon_mgr:
		_horizon_mgr.set_enabled(pressed)


func _update_sun_transform() -> void:
	if not _sun:
		return
	var azimuth_rad: float = _sun_azimuth * TAU  # 0-360
	var elevation_rad: float = _sun_elevation * PI * 0.5  # 0-90

	# Sun direction: pointing DOWN from the sky position
	_sun.rotation = Vector3.ZERO
	_sun.rotate_y(azimuth_rad)
	_sun.rotate_object_local(Vector3.RIGHT, -(PI * 0.5 - elevation_rad))


func _update_info_label() -> void:
	if not _info_label:
		return
	var az_deg: int = int(_sun_azimuth * 360.0)
	var el_deg: int = int(_sun_elevation * 90.0)
	var status: String = "ON" if _shadow_enabled else "OFF"
	_info_label.text = "Az: %d°  El: %d°  Shadows: %s\nWASD+mouse to fly" % [az_deg, el_deg, status]
