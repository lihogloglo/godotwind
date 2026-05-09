## Visual test for the diagnostic underwater volume.
##
## Standalone scene — no ESM loading, no asset streaming.
## Tests: UnderwaterVolume absorption, debug masks, and wobble.
## Ocean is initialized via OceanManager autoload.
##
## Controls:
##   RMB      = Hold to look, ZQSD to move, Space/Ctrl up/down
##   Shift    = Fast move
##   U        = Toggle underwater volume
##   3        = Toggle wobble
##   6        = Cycle volume debug modes
##   R        = Reset camera to underwater
##   G        = Reset camera to surface (boundary view)
##   O        = Toggle ocean visibility
extends Node3D

var _camera: Camera3D
var _light: DirectionalLight3D
var _world_env: WorldEnvironment
var _debug_label: RichTextLabel
var _ocean_enabled: bool = true
var _mouse_captured: bool = false
var _fly_speed: float = 15.0

# Diagnostic volume toggles.
var _wobble_on: bool = true
var _debug_mode: int = 0


func _ready() -> void:
	_setup_environment()
	_setup_camera()
	_setup_underwater_geometry()
	_setup_ocean()
	_setup_underwater_volume()
	_setup_ui()

	# Start camera underwater
	_camera.position = Vector3(0, -8, 20)
	_camera.rotation_degrees = Vector3(-5, 0, 0)

	Log.info("water", "Underwater test ready. RMB=fly, U=toggle volume, 3=wobble, 6=debug, R=dive, G=surface")


func _setup_environment() -> void:
	_world_env = WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY

	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.35, 0.55, 0.82)
	mat.sky_horizon_color = Color(0.6, 0.65, 0.7)
	mat.ground_bottom_color = Color(0.15, 0.15, 0.13)
	mat.ground_horizon_color = Color(0.6, 0.65, 0.7)
	mat.sun_angle_max = 1.0
	sky.sky_material = mat
	env.sky = sky

	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = 0.8
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	env.ssr_enabled = true
	env.ssr_max_steps = 64
	env.ssr_fade_in = 0.15
	env.ssr_fade_out = 2.0
	env.ssr_depth_tolerance = 0.2

	env.fog_enabled = true
	env.fog_density = 0.001

	_world_env.environment = env
	add_child(_world_env)

	# Attach ShaderManager's compositor to our WorldEnvironment for optional
	# shared post effects; the diagnostic underwater volume does not use it.
	ShaderManager.attach_to(_world_env)

	_light = DirectionalLight3D.new()
	_light.name = "SunLight"
	_light.rotation_degrees = Vector3(-45, -30, 0)
	_light.shadow_enabled = true
	_light.light_energy = 1.2
	_light.light_color = Color(1.0, 0.98, 0.95)
	_light.directional_shadow_max_distance = 500.0
	add_child(_light)


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "FlyCamera"
	_camera.current = true
	_camera.far = 5000.0
	_camera.near = 0.1
	add_child(_camera)


func _setup_underwater_geometry() -> void:
	# Sea floor
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(500, 500)
	floor_mesh.mesh = plane
	floor_mesh.position.y = -15.0
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.25, 0.22, 0.18)
	floor_mat.roughness = 0.9
	floor_mesh.material_override = floor_mat
	add_child(floor_mesh)

	# Rocks
	var rock_mat := StandardMaterial3D.new()
	rock_mat.albedo_color = Color(0.35, 0.3, 0.25)
	rock_mat.roughness = 0.85

	_add_rock(Vector3(0, -12, 0), Vector3(3, 2, 3), rock_mat)
	_add_rock(Vector3(8, -10, -5), Vector3(2, 4, 2), rock_mat)
	_add_rock(Vector3(-10, -13, 3), Vector3(4, 1.5, 3), rock_mat)
	_add_rock(Vector3(5, -14, 10), Vector3(2.5, 1, 2.5), rock_mat)
	_add_rock(Vector3(-6, -11, -8), Vector3(1.5, 3, 1.5), rock_mat)

	var coral_mat := StandardMaterial3D.new()
	coral_mat.albedo_color = Color(0.6, 0.3, 0.25)
	_add_rock(Vector3(3, -14.5, -3), Vector3(0.8, 1.5, 0.8), coral_mat)

	var coral_mat2 := StandardMaterial3D.new()
	coral_mat2.albedo_color = Color(0.3, 0.5, 0.25)
	_add_rock(Vector3(-4, -14.5, 6), Vector3(1.0, 2.0, 1.0), coral_mat2)

	# Pillar crossing water surface (boundary testing)
	var pillar := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(2, 25, 2)
	pillar.mesh = box
	pillar.position = Vector3(15, -5, 0)
	var pillar_mat := StandardMaterial3D.new()
	pillar_mat.albedo_color = Color(0.4, 0.38, 0.35)
	pillar.material_override = pillar_mat
	add_child(pillar)

	# Arch
	var arch_box := BoxMesh.new()
	arch_box.size = Vector3(1.5, 12, 1.5)
	for pos in [Vector3(-15, -9, -10), Vector3(-15, -9, -5)]:
		var arch := MeshInstance3D.new()
		arch.mesh = arch_box
		arch.position = pos
		arch.material_override = rock_mat
		add_child(arch)
	var arch_top := MeshInstance3D.new()
	var atb := BoxMesh.new()
	atb.size = Vector3(1.5, 1.5, 7)
	arch_top.mesh = atb
	arch_top.position = Vector3(-15, -4, -7.5)
	arch_top.material_override = rock_mat
	add_child(arch_top)


func _add_rock(pos: Vector3, size: Vector3, mat: StandardMaterial3D) -> void:
	var rock := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = size.x * 0.5
	sphere.height = size.y
	rock.mesh = sphere
	rock.position = pos
	rock.material_override = mat
	add_child(rock)


func _setup_ocean() -> void:
	if not OceanManager.is_system_enabled():
		OceanManager.force_initialize()
	OceanManager.set_camera(_camera)

	# Override shore mask with all-water for test scene
	var white_img := Image.create(1, 1, false, Image.FORMAT_L8)
	white_img.set_pixel(0, 0, Color.WHITE)
	var white_tex := ImageTexture.create_from_image(white_img)
	var ocean_mesh: OceanMesh = OceanManager.get_ocean_mesh()
	if ocean_mesh:
		ocean_mesh.set_shore_mask(white_tex, Rect2(-50000, -50000, 100000, 100000))

	Log.info("water", "Ocean ready for underwater test")


var _volume: UnderwaterVolume = null


func _setup_underwater_volume() -> void:
	_volume = UnderwaterVolume.new()
	_volume.name = "UnderwaterVolume"
	_volume.set_camera(_camera)
	_volume.set_sun(_light)
	_volume.set_sea_level(OceanManager.get_sea_level())
	add_child(_volume)
	Log.info("water", "UnderwaterVolume added (diagnostic absorption/wobble only)")


func _process(delta: float) -> void:
	_handle_fly_camera(delta)
	_update_debug_overlay()
	if _volume != null:
		_volume.set_sea_level(OceanManager.get_sea_level())


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key: InputEventKey = event as InputEventKey
		match key.keycode:
			KEY_U:
				if _volume != null:
					_volume.enabled = not _volume.enabled
					Log.info("water", "Underwater volume: %s" % ("ON" if _volume.enabled else "OFF"))
			KEY_3:
				_wobble_on = not _wobble_on
				if _volume != null:
					_volume.set_wobble_enabled(_wobble_on)
				Log.info("water", "Wobble: %s" % ("ON" if _wobble_on else "OFF"))
			KEY_6:
				_debug_mode = (_debug_mode + 1) % 4
				var names := ["Final", "Slab Mask", "Depth/Y", "Big Wobble"]
				if _volume != null:
					_volume.set_debug_mode(_debug_mode)
				Log.info("water", "Debug mode: %s" % names[_debug_mode])
			KEY_R:
				_camera.position = Vector3(0, -8, 20)
				_camera.rotation_degrees = Vector3(-5, 0, 0)
				Log.info("water", "Camera reset: underwater")
			KEY_G:
				_camera.position = Vector3(0, -0.2, 20)
				_camera.rotation_degrees = Vector3(0, 0, 0)
				Log.info("water", "Camera reset: surface (boundary view)")
			KEY_O:
				_ocean_enabled = not _ocean_enabled
				OceanManager.set_enabled(_ocean_enabled)
				Log.info("water", "Ocean: %s" % ("ON" if _ocean_enabled else "OFF"))

	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_mouse_captured = mb.pressed
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _mouse_captured else Input.MOUSE_MODE_VISIBLE

	if event is InputEventMouseMotion and _mouse_captured:
		var mm: InputEventMouseMotion = event as InputEventMouseMotion
		_camera.rotation_degrees.y -= mm.relative.x * 0.2
		_camera.rotation_degrees.x -= mm.relative.y * 0.2
		_camera.rotation_degrees.x = clampf(_camera.rotation_degrees.x, -89, 89)


func _handle_fly_camera(delta: float) -> void:
	if not _mouse_captured:
		return
	var speed: float = _fly_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= 3.0
	var direction := Vector3.ZERO
	if Input.is_key_pressed(KEY_Q): direction -= _camera.global_basis.x
	if Input.is_key_pressed(KEY_D): direction += _camera.global_basis.x
	if Input.is_key_pressed(KEY_S): direction += _camera.global_basis.z
	if Input.is_key_pressed(KEY_Z): direction -= _camera.global_basis.z
	if Input.is_key_pressed(KEY_SPACE): direction.y += 1.0
	if Input.is_key_pressed(KEY_CTRL): direction.y -= 1.0
	if direction.length_squared() > 0.001:
		_camera.position += direction.normalized() * speed * delta


func _setup_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "UI"
	add_child(canvas)

	_debug_label = RichTextLabel.new()
	_debug_label.bbcode_enabled = true
	_debug_label.fit_content = true
	_debug_label.scroll_active = false
	_debug_label.position = Vector2(10, 10)
	_debug_label.size = Vector2(500, 500)
	_debug_label.add_theme_font_size_override("normal_font_size", 14)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.6)
	style.set_content_margin_all(8)
	_debug_label.add_theme_stylebox_override("normal", style)
	canvas.add_child(_debug_label)


func _update_debug_overlay() -> void:
	if _debug_label == null:
		return

	var lines: PackedStringArray = PackedStringArray()
	lines.append("[b]UNDERWATER TEST (Diagnostic Volume)[/b]")
	lines.append("")

	var sea: float = OceanManager.get_sea_level()
	var cam_y: float = _camera.global_position.y
	var depth: float = sea - cam_y
	lines.append("[b]Camera:[/b] Y=%.2f | Sea=%.2f | Depth=%.2f" % [cam_y, sea, depth])

	if depth > 0:
		lines.append("[color=cyan]SUBMERGED[/color]")
	elif depth > -2.0:
		lines.append("[color=yellow]AT SURFACE[/color]")
	else:
		lines.append("[color=green]ABOVE WATER[/color]")
	lines.append("")

	lines.append("[b]Volume:[/b] %s" % ("[color=cyan]ACTIVE[/color]" if _volume != null and _volume.enabled else "[color=red]INACTIVE[/color]"))
	lines.append("  [3] Wobble:   %s" % _on_off(_wobble_on))
	lines.append("")

	if _debug_mode > 0:
		var names := ["", "Slab Mask", "Depth/Y", "Big Wobble"]
		lines.append("[color=orange][b]DEBUG: %s[/b][/color]" % names[_debug_mode])
	lines.append("")

	lines.append("[b]Controls:[/b]")
	lines.append("  RMB = Look | ZQSD = Move")
	lines.append("  Space/Ctrl = Up/Down | Shift = Fast")
	lines.append("  U = Toggle volume | O = Toggle ocean")
	lines.append("  R = Dive | G = Surface | 6 = Debug mode")

	_debug_label.text = "\n".join(lines)


func _on_off(val: bool) -> String:
	return "[color=cyan]ON[/color]" if val else "[color=red]OFF[/color]"
