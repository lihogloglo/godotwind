extends Node3D

## Terrain Alignment Diagnostic
##
## Loads prebaked terrain + a few known cells, checks if terrain height
## matches object positions. Outputs coordinates for debugging.

const CS := preload("res://src/core/coordinate_system.gd")
const CellManagerScript := preload("res://src/core/world/cell_manager.gd")
const LoadingScreenScript := preload("res://src/core/ui/loading_screen.gd")

var _camera: Camera3D
var _info_label: Label
var _terrain: Terrain3D


func _ready() -> void:
	_setup_ui()
	_setup_camera()

	# Load game data
	var loading := LoadingScreenScript.new()
	add_child(loading)
	var success := await loading.load_game_data()
	loading.queue_free()
	if not success:
		_log("[FAIL] Game data load failed")
		return

	# Create Terrain3D
	_terrain = Terrain3D.new()
	_terrain.name = "Terrain3D"
	_terrain.top_level = true
	add_child(_terrain)
	await get_tree().process_frame
	await get_tree().process_frame

	CS.configure_terrain3d(_terrain)

	# Apply scale workaround (matching world_explorer.gd)
	var vs: float = CS.TERRAIN_VERTEX_SPACING
	_terrain.scale = Vector3(vs, 1.0, vs)
	_log("Terrain scale = (%.4f, 1.0, %.4f)" % [vs, vs])
	_log("Terrain vertex_spacing = %.4f (internal)" % _terrain.get_vertex_spacing())

	# Load prebaked terrain
	var terrain_path: String = SettingsManager.get_terrain_path()
	if DirAccess.dir_exists_absolute(terrain_path):
		_terrain.data.load_directory(terrain_path)
		_log("Loaded terrain: %d regions" % _terrain.data.get_region_count())
	else:
		_log("[WARN] No prebaked terrain at %s" % terrain_path)

	await get_tree().process_frame

	# Load a known cell (Seyda Neen)
	var cell_manager := CellManagerScript.new()
	cell_manager.load_npcs = false
	cell_manager.load_creatures = false
	cell_manager.use_static_renderer = false
	cell_manager.use_multimesh_instancing = false

	var seyda_cell := cell_manager.load_exterior_cell(-2, -9)
	if seyda_cell:
		add_child(seyda_cell)
		_log("Loaded Seyda Neen (-2,-9): %d children" % seyda_cell.get_child_count())
	else:
		_log("[FAIL] Could not load Seyda Neen")
		return

	# Diagnostic: Check alignment at known positions
	_log("")
	_log("=== ALIGNMENT DIAGNOSTIC ===")

	# Cell center for (-2, -9)
	var cell_center: Vector3 = _cell_center(-2, -9)
	_log("Cell (-2,-9) center: %s" % cell_center)

	# Query terrain height at cell center
	_check_height_at("Cell (-2,-9) center", cell_center)

	# Check a few children of the loaded cell
	var checked := 0
	for child: Node in seyda_cell.get_children():
		if child is Node3D and checked < 5:
			var pos: Vector3 = child.global_position
			_log("")
			_log("Object '%s' at %s" % [child.name, pos])
			_check_height_at("  Terrain at object XZ", Vector3(pos.x, 0, pos.z))
			_log("  Object Y = %.2f, Terrain Y = %.2f, Diff = %.2f" % [
				pos.y,
				_get_terrain_height(Vector3(pos.x, 0, pos.z)),
				pos.y - _get_terrain_height(Vector3(pos.x, 0, pos.z))
			])
			checked += 1

	# Also check WITHOUT the scale workaround
	_log("")
	_log("=== WITHOUT SCALE (vertex_spacing=1.0, scale=1.0) ===")
	_terrain.scale = Vector3.ONE
	await get_tree().process_frame
	_check_height_at("Cell (-2,-9) center (no scale)", cell_center)

	# Restore scale
	_terrain.scale = Vector3(vs, 1.0, vs)
	_log("")
	_log("=== SCALE RESTORED ===")
	_check_height_at("Cell (-2,-9) center (scale restored)", cell_center)

	# Position camera at Seyda Neen
	_camera.global_position = cell_center + Vector3(0, 50, 50)
	_camera.look_at(cell_center)

	_log("")
	_log("=== DIAGNOSTIC COMPLETE ===")
	_log("Fly around to visually check alignment (WASD + mouse)")

	# Keep running for visual inspection
	await get_tree().create_timer(60.0).timeout
	get_tree().quit()


func _cell_center(gx: int, gy: int) -> Vector3:
	var origin_x: float = float(gx) * CS.CELL_SIZE_GODOT
	var origin_z: float = float(-gy) * CS.CELL_SIZE_GODOT
	var half: float = CS.CELL_SIZE_GODOT / 2.0
	return Vector3(origin_x + half, 0, origin_z - half)


func _get_terrain_height(world_pos: Vector3) -> float:
	if not _terrain or not _terrain.data:
		return NAN
	# Terrain3D get_height uses world coordinates
	# But with scale workaround, we need to convert to internal coords
	var internal_pos := _terrain.global_transform.affine_inverse() * world_pos
	return _terrain.data.get_height(internal_pos)


func _check_height_at(label: String, world_pos: Vector3) -> void:
	if not _terrain or not _terrain.data:
		_log("  %s: No terrain data" % label)
		return

	# Direct query (world coords)
	var h_direct: float = _terrain.data.get_height(world_pos)

	# Via inverse transform (internal coords)
	var internal_pos := _terrain.global_transform.affine_inverse() * world_pos
	var h_internal: float = _terrain.data.get_height(internal_pos)

	_log("  %s:" % label)
	_log("    World pos: (%.2f, %.2f, %.2f)" % [world_pos.x, world_pos.y, world_pos.z])
	_log("    Internal pos: (%.2f, %.2f, %.2f)" % [internal_pos.x, internal_pos.y, internal_pos.z])
	_log("    Height (world coords query): %.2f" % h_direct)
	_log("    Height (internal coords query): %.2f" % h_internal)

	# Check region location
	var region_loc_world := _terrain.data.get_region_location(world_pos)
	var region_loc_internal := _terrain.data.get_region_location(internal_pos)
	_log("    Region loc (world): %s" % region_loc_world)
	_log("    Region loc (internal): %s" % region_loc_internal)


func _log(msg: String) -> void:
	Log.info("testing", "[ALIGN] %s" % msg)
	print(msg)


var _mouse_captured: bool = true
var _yaw: float = 0.0
var _pitch: float = 0.0
var _camera_speed: float = 30.0

func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "TestCamera"
	_camera.current = true
	_camera.far = 5000.0
	_camera.cull_mask = 0x3
	add_child(_camera)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _setup_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_info_label = Label.new()
	_info_label.position = Vector2(10, 10)
	_info_label.add_theme_font_size_override("font_size", 14)
	_info_label.add_theme_color_override("font_color", Color.YELLOW)
	canvas.add_child(_info_label)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _mouse_captured:
		_yaw -= event.relative.x * 0.003
		_pitch -= event.relative.y * 0.003
		_pitch = clampf(_pitch, -PI / 2.0 + 0.1, PI / 2.0 - 0.1)
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			get_tree().quit()

func _process(delta: float) -> void:
	var basis := Basis.from_euler(Vector3(_pitch, _yaw, 0))
	_camera.basis = basis
	var velocity := Vector3.ZERO
	var speed := _camera_speed
	if Input.is_physical_key_pressed(KEY_SHIFT):
		speed *= 5.0
	if Input.is_physical_key_pressed(KEY_W):
		velocity -= basis.z
	if Input.is_physical_key_pressed(KEY_S):
		velocity += basis.z
	if Input.is_physical_key_pressed(KEY_A):
		velocity -= basis.x
	if Input.is_physical_key_pressed(KEY_D):
		velocity += basis.x
	if Input.is_physical_key_pressed(KEY_SPACE):
		velocity += basis.y
	if Input.is_physical_key_pressed(KEY_CTRL):
		velocity -= basis.y
	if velocity.length_squared() > 0:
		_camera.position += velocity.normalized() * speed * delta
