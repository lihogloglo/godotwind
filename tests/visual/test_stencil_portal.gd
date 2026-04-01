extends Node3D

## Pure Stencil Portal Test — No Morrowind data, just stencil mechanics
##
## Creates a wall with a doorframe opening, places a stencil-write plane in
## the opening, and renders colored cubes behind the wall that should ONLY be
## visible through the stencil "window".
##
## If stencil works: cubes visible only through the doorframe.
## If stencil fails: cubes visible everywhere (or not at all).
##
## Controls:
##   WASD + mouse — fly camera
##   SPACE — toggle stencil on/off (to see the difference)
##   RMB — release mouse

## Stencil API constants (Godot 4.6 BaseMaterial3D)
const _SM_CUSTOM: int = 3
const _SM_DISABLED: int = 0
const _SF_READ: int = 1
const _SF_WRITE: int = 2
const _SC_EQUAL: int = 2
const STENCIL_REF: int = 1

var _camera: Camera3D
var _mouse_captured: bool = true
var _yaw: float = 0.0
var _pitch: float = 0.0
var _camera_speed: float = 5.0
var _stencil_enabled: bool = true

var _stencil_plane: MeshInstance3D
var _interior_cubes: Array[MeshInstance3D] = []
var _info_label: Label


func _ready() -> void:
	_setup_environment()
	_setup_camera()
	_setup_ui()
	_build_scene()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _setup_environment() -> void:
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.15, 0.18, 0.22)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.6)
	env.ambient_light_energy = 0.8
	env_node.environment = env
	add_child(env_node)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 30, 0)
	sun.light_energy = 1.5
	sun.shadow_enabled = true
	add_child(sun)


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "FlyCamera"
	_camera.current = true
	_camera.position = Vector3(0, 1.6, 4)  # Eye height, 4m from wall
	add_child(_camera)


func _setup_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_info_label = Label.new()
	_info_label.position = Vector2(10, 10)
	_info_label.add_theme_font_size_override("font_size", 16)
	_info_label.add_theme_color_override("font_color", Color.WHITE)
	_info_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_info_label.add_theme_constant_override("shadow_offset_x", 1)
	_info_label.add_theme_constant_override("shadow_offset_y", 1)
	canvas.add_child(_info_label)


func _build_scene() -> void:
	# Floor
	var floor_mesh := MeshInstance3D.new()
	floor_mesh.mesh = BoxMesh.new()
	(floor_mesh.mesh as BoxMesh).size = Vector3(10, 0.1, 10)
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.3, 0.3, 0.3)
	floor_mesh.material_override = floor_mat
	floor_mesh.position = Vector3(0, -0.05, 0)
	add_child(floor_mesh)

	# Wall with doorframe hole (built from 3 boxes: left pillar, right pillar, lintel)
	_build_wall()

	# Stencil-write plane in the doorframe opening
	_build_stencil_plane()

	# Interior cubes behind the wall (should only be visible through stencil)
	_build_interior_cubes()


func _build_wall() -> void:
	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.5, 0.45, 0.4)

	var door_width: float = 1.2
	var door_height: float = 2.2
	var wall_width: float = 6.0
	var wall_height: float = 3.0
	var wall_thickness: float = 0.3

	# Left pillar
	var left_width: float = (wall_width - door_width) / 2.0
	var left := MeshInstance3D.new()
	left.mesh = BoxMesh.new()
	(left.mesh as BoxMesh).size = Vector3(left_width, wall_height, wall_thickness)
	left.material_override = wall_mat
	left.position = Vector3(-(door_width / 2.0 + left_width / 2.0), wall_height / 2.0, 0)
	add_child(left)

	# Right pillar
	var right := MeshInstance3D.new()
	right.mesh = BoxMesh.new()
	(right.mesh as BoxMesh).size = Vector3(left_width, wall_height, wall_thickness)
	right.material_override = wall_mat
	right.position = Vector3(door_width / 2.0 + left_width / 2.0, wall_height / 2.0, 0)
	add_child(right)

	# Lintel (above door)
	var lintel_height: float = wall_height - door_height
	var lintel := MeshInstance3D.new()
	lintel.mesh = BoxMesh.new()
	(lintel.mesh as BoxMesh).size = Vector3(door_width, lintel_height, wall_thickness)
	lintel.material_override = wall_mat
	lintel.position = Vector3(0, door_height + lintel_height / 2.0, 0)
	add_child(lintel)


func _build_stencil_plane() -> void:
	_stencil_plane = MeshInstance3D.new()
	_stencil_plane.name = "StencilWritePlane"

	var quad := QuadMesh.new()
	quad.size = Vector2(1.2, 2.2)  # Match doorframe opening
	_stencil_plane.mesh = quad

	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0, 0, 0, 0.01)  # Nearly invisible
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.render_priority = -10  # Render first in alpha queue

	# Stencil write
	mat.stencil_mode = _SM_CUSTOM
	mat.stencil_flags = _SF_WRITE
	mat.stencil_reference = STENCIL_REF

	_stencil_plane.material_override = mat
	_stencil_plane.position = Vector3(0, 1.1, 0)  # Center of doorframe
	_stencil_plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_stencil_plane)


func _build_interior_cubes() -> void:
	# Place colored cubes behind the wall (Z < 0)
	var colors: Array[Color] = [
		Color.RED, Color.GREEN, Color.BLUE,
		Color.YELLOW, Color.MAGENTA, Color.CYAN
	]
	var positions: Array[Vector3] = [
		Vector3(-1.0, 0.5, -2.0), Vector3(0, 0.5, -2.0), Vector3(1.0, 0.5, -2.0),
		Vector3(-0.5, 1.5, -3.0), Vector3(0.5, 1.5, -3.0), Vector3(0, 0.8, -1.5),
	]

	for i in colors.size():
		var cube := MeshInstance3D.new()
		cube.name = "InteriorCube_%d" % i
		cube.mesh = BoxMesh.new()
		(cube.mesh as BoxMesh).size = Vector3(0.5, 0.5, 0.5)

		var mat := StandardMaterial3D.new()
		mat.albedo_color = colors[i]

		# Stencil read — only render where stencil plane wrote
		mat.stencil_mode = _SM_CUSTOM
		mat.stencil_flags = _SF_READ
		mat.stencil_compare = _SC_EQUAL
		mat.stencil_reference = STENCIL_REF
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color.a = 1.0
		mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
		mat.render_priority = 1  # After stencil-write plane

		cube.material_override = mat
		cube.position = positions[i]
		add_child(cube)
		_interior_cubes.append(cube)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _mouse_captured:
		_yaw -= event.relative.x * 0.003
		_pitch -= event.relative.y * 0.003
		_pitch = clampf(_pitch, -PI / 2.0 + 0.1, PI / 2.0 - 0.1)

	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		_mouse_captured = not _mouse_captured
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _mouse_captured else Input.MOUSE_MODE_VISIBLE

	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_SPACE:
			_toggle_stencil()
		elif event.keycode == KEY_ESCAPE:
			_mouse_captured = false
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _process(delta: float) -> void:
	_update_camera(delta)
	_update_ui()


func _update_camera(delta: float) -> void:
	if not _mouse_captured:
		return
	var basis := Basis.from_euler(Vector3(_pitch, _yaw, 0))
	_camera.basis = basis
	var velocity := Vector3.ZERO
	var speed := _camera_speed
	if Input.is_physical_key_pressed(KEY_SHIFT):
		speed *= 3.0
	if Input.is_physical_key_pressed(KEY_W):
		velocity -= basis.z
	if Input.is_physical_key_pressed(KEY_S):
		velocity += basis.z
	if Input.is_physical_key_pressed(KEY_A):
		velocity -= basis.x
	if Input.is_physical_key_pressed(KEY_D):
		velocity += basis.x
	if Input.is_physical_key_pressed(KEY_Q):
		velocity -= basis.y
	if Input.is_physical_key_pressed(KEY_E):
		velocity += basis.y
	if velocity.length_squared() > 0:
		_camera.position += velocity.normalized() * speed * delta


func _update_ui() -> void:
	var text := "Pure Stencil Portal Test\n"
	text += "Stencil: %s (SPACE to toggle)\n" % ("ON" if _stencil_enabled else "OFF")
	text += "\nExpected: colored cubes visible ONLY through doorframe\n"
	text += "If cubes visible everywhere: stencil read not working\n"
	text += "If cubes invisible everywhere: stencil write not working\n"
	text += "\nWASD+mouse — Move | RMB — Release mouse"
	_info_label.text = text


func _toggle_stencil() -> void:
	_stencil_enabled = not _stencil_enabled

	if _stencil_enabled:
		# Re-enable stencil write on plane
		var mat: StandardMaterial3D = _stencil_plane.material_override as StandardMaterial3D
		mat.stencil_mode = _SM_CUSTOM
		mat.stencil_flags = _SF_WRITE
		# Re-enable stencil read on cubes
		for cube in _interior_cubes:
			var cube_mat: StandardMaterial3D = cube.material_override as StandardMaterial3D
			cube_mat.stencil_mode = _SM_CUSTOM
			cube_mat.stencil_flags = _SF_READ
			cube_mat.stencil_compare = _SC_EQUAL
	else:
		# Disable stencil — cubes should be visible everywhere
		var mat: StandardMaterial3D = _stencil_plane.material_override as StandardMaterial3D
		mat.stencil_mode = _SM_DISABLED
		for cube in _interior_cubes:
			var cube_mat: StandardMaterial3D = cube.material_override as StandardMaterial3D
			cube_mat.stencil_mode = _SM_DISABLED
