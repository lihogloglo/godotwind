extends Node3D

## Automated Classic Interior Transition Test
##
## Loads Seyda Neen, auto-enters Arrille's Tradehouse via classic teleport,
## logs everything for diagnosis, then auto-exits after 3 seconds.
## No user interaction needed — just watch the window and logs.
##
## Controls (optional):
##   WASD + mouse — fly camera
##   E — manual door activate
##   ESC — quit

const CS := preload("res://src/core/coordinate_system.gd")
const CellManagerScript := preload("res://src/core/world/cell_manager.gd")
const InteriorPocketManagerScript := preload("res://src/core/world/interior_pocket_manager.gd")
const LoadingScreenScript := preload("res://src/core/ui/loading_screen.gd")

var _camera: Camera3D
var _environment: WorldEnvironment
var _sun: DirectionalLight3D
var _cell_manager: CellManagerScript
var _pocket_manager: Node
var _info_label: Label

var _mouse_captured: bool = true
var _camera_speed: float = 20.0
var _yaw: float = 0.0
var _pitch: float = 0.0

# Seyda Neen cells (small area around tradehouse)
const SEYDA_NEEN_CELLS: Array[Vector2i] = [
	Vector2i(-2, -9), Vector2i(-1, -9), Vector2i(-2, -8),
	Vector2i(-1, -8),
]


func _ready() -> void:
	_setup_environment()
	_setup_camera()
	_setup_ui()

	# Load game data
	var loading := LoadingScreenScript.new()
	add_child(loading)
	var success := await loading.load_game_data()
	loading.queue_free()
	if not success:
		Log.error("testing", "Failed to load game data")
		return

	# Cell manager — no NPCs, no static/multimesh (same as pocket uses)
	_cell_manager = CellManagerScript.new()
	_cell_manager.load_npcs = false
	_cell_manager.load_creatures = false
	_cell_manager.use_static_renderer = false
	_cell_manager.use_multimesh_instancing = false

	# Pocket manager — classic mode only
	_pocket_manager = InteriorPocketManagerScript.new()
	_pocket_manager.name = "PocketManager"
	add_child(_pocket_manager)
	_pocket_manager.initialize(_cell_manager, _environment, _camera, _sun)
	_pocket_manager.seamless_enabled = false

	# Load exterior cells and register doors
	await get_tree().process_frame
	_load_exterior_cells()

	# Auto-test sequence
	await get_tree().process_frame
	await _run_auto_test()


func _setup_environment() -> void:
	_environment = WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.38, 0.45, 0.55)
	mat.sky_horizon_color = Color(0.64, 0.68, 0.74)
	sky.sky_material = mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 0.5
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_environment.environment = env
	add_child(_environment)

	_sun = DirectionalLight3D.new()
	_sun.name = "Sun"
	_sun.rotation_degrees = Vector3(-45, 45, 0)
	_sun.shadow_enabled = true
	_sun.light_energy = 1.2
	add_child(_sun)


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "TestCamera"
	_camera.current = true
	_camera.far = 2000.0
	_camera.cull_mask = 0x3  # Exterior layers (1-2) — pocket manager swaps to interior on enter
	add_child(_camera)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


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


func _load_exterior_cells() -> void:
	for grid: Vector2i in SEYDA_NEEN_CELLS:
		var cell_node: Node3D = _cell_manager.load_exterior_cell(grid.x, grid.y)
		if cell_node:
			add_child(cell_node)
			# Register doors
			var cell: CellRecord = ESMManager.get_exterior_cell(grid.x, grid.y)
			if cell:
				var door_count: int = _pocket_manager.register_exterior_cell_doors(cell, grid)
				Log.info("testing", "Cell %s: %d objects, %d doors registered" % [
					grid, cell_node.get_child_count(), door_count])


func _run_auto_test() -> void:
	Log.info("testing", "=== AUTO-TEST: Classic Interior Transition ===")

	# Find door to Arrille's Tradehouse
	@warning_ignore("untyped_declaration")
	var target_door = null
	@warning_ignore("untyped_declaration")
	for door in _pocket_manager._exterior_doors:
		if door.target_cell_name.to_lower().contains("arrille"):
			target_door = door
			break

	if not target_door:
		# Fallback: use first available door
		if not _pocket_manager._exterior_doors.is_empty():
			target_door = _pocket_manager._exterior_doors[0]
			Log.info("testing", "Arrille's not found, using first door: %s" % target_door.target_cell_name)
		else:
			Log.error("testing", "NO DOORS REGISTERED — cannot test transition")
			_info_label.text = "FAIL: No doors registered"
			return

	Log.info("testing", "Target door: %s -> '%s'" % [target_door.ref_id, target_door.target_cell_name])
	Log.info("testing", "Door world_pos: %s" % target_door.world_position)
	Log.info("testing", "Teleport MW pos: %s, rot: %s" % [target_door.teleport_pos_mw, target_door.teleport_rot_mw])

	# Position camera near the door first
	_camera.global_position = target_door.world_position + Vector3(0, 3, 5)
	_camera.look_at(target_door.world_position)
	_yaw = _camera.rotation.y
	_pitch = _camera.rotation.x
	_info_label.text = "Positioned at door — entering in 1s..."
	Log.info("testing", "Camera at door pos: %s, cull_mask=0x%X" % [
		_camera.global_position, _camera.cull_mask])

	# Wait a moment so user can see the exterior
	await get_tree().create_timer(1.0).timeout

	# === ENTER INTERIOR ===
	Log.info("testing", "--- ENTERING INTERIOR ---")
	Log.info("testing", "Pre-enter: cam_pos=%s, cam_cull=0x%X" % [
		_camera.global_position, _camera.cull_mask])

	var success: bool = await _pocket_manager.enter_interior(target_door)

	Log.info("testing", "enter_interior() returned: %s" % success)
	Log.info("testing", "Post-enter: cam_pos=%s, cam_cull=0x%X" % [
		_camera.global_position, _camera.cull_mask])
	Log.info("testing", "is_inside: %s" % _pocket_manager.is_inside())

	# Check what the camera can see
	_diagnose_visibility()

	if success:
		_info_label.text = "INSIDE: %s — checking visibility..." % target_door.target_cell_name

		# Sync camera angles after teleport
		var euler: Vector3 = _camera.global_basis.get_euler()
		_yaw = euler.y
		_pitch = clampf(euler.x, -PI / 2.0 + 0.1, PI / 2.0 - 0.1)

		# Wait so user can see the interior (fly around with WASD)
		await get_tree().create_timer(5.0).timeout

		# === EXIT TO EXTERIOR ===
		Log.info("testing", "--- EXITING TO EXTERIOR ---")
		@warning_ignore("untyped_declaration")
		var exit_door = _pocket_manager.get_closest_door()
		if exit_door:
			Log.info("testing", "Exit door: %s -> '%s'" % [exit_door.ref_id, exit_door.target_cell_name])
			var exit_ok: bool = await _pocket_manager.exit_to_exterior(exit_door)
			Log.info("testing", "exit_to_exterior() returned: %s" % exit_ok)
			Log.info("testing", "Post-exit: cam_pos=%s, cam_cull=0x%X" % [
				_camera.global_position, _camera.cull_mask])
			_info_label.text = "OUTSIDE: exit %s — cam_cull=0x%X" % [
				"OK" if exit_ok else "FAIL", _camera.cull_mask]

			# Sync camera
			euler = _camera.global_basis.get_euler()
			_yaw = euler.y
			_pitch = clampf(euler.x, -PI / 2.0 + 0.1, PI / 2.0 - 0.1)
		else:
			Log.error("testing", "No exit door found — get_closest_door() returned null")
			_info_label.text = "FAIL: No exit door found"
	else:
		_info_label.text = "FAIL: enter_interior() returned false"
		Log.error("testing", "enter_interior() FAILED")

	Log.info("testing", "=== AUTO-TEST COMPLETE ===")


## Diagnose what the camera should be seeing
func _diagnose_visibility() -> void:
	Log.info("testing", "=== VISIBILITY DIAGNOSIS ===")
	Log.info("testing", "Camera: pos=%s, cull_mask=0x%X, current=%s" % [
		_camera.global_position, _camera.cull_mask, _camera.current])

	@warning_ignore("untyped_declaration")
	for slot in _pocket_manager._slots:
		if slot.is_occupied:
			Log.info("testing", "Pocket slot %d: '%s', offset=%s, children=%d" % [
				slot.slot_index, slot.cell_name, slot.get_offset(),
				slot.cell_node.get_child_count() if slot.cell_node else 0])
			if slot.cell_node:
				@warning_ignore("untyped_declaration")
				var counts := _count_visuals_recursive(slot.cell_node, 0, 0, 0)
				Log.info("testing", "  Total visual instances (recursive): %d, layer-match camera: %d" % [counts[0], counts[1]])
		elif slot.is_loading:
			Log.info("testing", "Pocket slot %d: LOADING '%s'" % [slot.slot_index, slot.cell_name])

	# Check environment
	if _environment and _environment.environment:
		var env: Environment = _environment.environment
		Log.info("testing", "Environment: bg_mode=%d, ambient_src=%d, ambient_color=%s" % [
			env.background_mode, env.ambient_light_source, env.ambient_light_color])


## Recursively count VisualInstance3D nodes and check layer match
## Uses arrays as mutable references for counting
func _count_visuals_recursive(node: Node, vis_count: int, layer_match: int, sample_count: int) -> Array[int]:
	@warning_ignore("untyped_declaration")
	var counts := [vis_count, layer_match, sample_count]
	if node is VisualInstance3D:
		counts[0] += 1
		@warning_ignore("unsafe_property_access")
		if node.layers & _camera.cull_mask:
			counts[1] += 1
		if counts[2] < 5:
			counts[2] += 1
			Log.info("testing", "  Visual[%d] '%s': layers=0x%X, vis=%s, pos=%s" % [
				counts[0], node.name, node.layers, node.visible, node.global_position])
	for child: Node in node.get_children():
		@warning_ignore("untyped_declaration")
		var sub := _count_visuals_recursive(child, counts[0], counts[1], counts[2])
		counts[0] = sub[0]
		counts[1] = sub[1]
		counts[2] = sub[2]
	return counts


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _mouse_captured:
		_yaw -= event.relative.x * 0.003
		_pitch -= event.relative.y * 0.003
		_pitch = clampf(_pitch, -PI / 2.0 + 0.1, PI / 2.0 - 0.1)

	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE:
				get_tree().quit()


func _process(delta: float) -> void:
	# Update pocket manager door tracking each frame
	if _pocket_manager and _camera:
		_pocket_manager.update(_camera.global_position, delta)

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
	if Input.is_physical_key_pressed(KEY_SPACE):
		velocity += basis.y
	if Input.is_physical_key_pressed(KEY_CTRL):
		velocity -= basis.y
	if velocity.length_squared() > 0:
		_camera.position += velocity.normalized() * speed * delta
