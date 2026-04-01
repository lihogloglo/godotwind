extends Node3D

## Interior Transition Test — Pocket Mode Only
##
## Loads Seyda Neen exterior cells, registers doors with InteriorPocketManager,
## then lets you fly to doors and press ENTER to transition in/out.
##
## Controls:
##   WASD + mouse — fly camera
##   ENTER — enter/exit door (within 3m)
##   TAB — cycle through discovered doors (teleports camera)
##   ESC — release mouse

const CS := preload("res://src/core/coordinate_system.gd")
const CellManagerScript := preload("res://src/core/world/cell_manager.gd")
const InteriorPocketManagerScript := preload("res://src/core/world/interior_pocket_manager.gd")
const LoadingScreenScript := preload("res://src/core/ui/loading_screen.gd")

# Scene nodes
var _camera: Camera3D
var _environment: WorldEnvironment
var _sun: DirectionalLight3D

# Systems
var _cell_manager: CellManagerScript
var _pocket_manager: Node  # InteriorPocketManager

# Door discovery
var _door_pairs: Array[Dictionary] = []  # [{ref_id, exterior_grid, interior_name, door_pos_mw, ...}]
var _current_door_index: int = 0

# Seyda Neen cells to scan
const SEYDA_NEEN_CELLS: Array[Vector2i] = [
	Vector2i(-2, -9), Vector2i(-1, -9), Vector2i(-2, -8),
	Vector2i(-1, -8), Vector2i(-3, -9), Vector2i(-2, -10),
]

# Camera state
var _mouse_captured: bool = true
var _camera_speed: float = 20.0
var _yaw: float = 0.0
var _pitch: float = 0.0

# UI
var _info_label: Label
var _loading: bool = true
var _stencil_debug: bool = false
var _depth_test_mode: bool = false


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

	# Cell manager (no NPCs/creatures for this test)
	_cell_manager = CellManagerScript.new()
	_cell_manager.load_npcs = false
	_cell_manager.load_creatures = false
	_cell_manager.use_static_renderer = false
	_cell_manager.use_multimesh_instancing = false

	# Pocket manager
	_pocket_manager = InteriorPocketManagerScript.new()
	_pocket_manager.name = "PocketManager"
	add_child(_pocket_manager)
	_pocket_manager.initialize(_cell_manager, _environment, _camera, _sun)
	_pocket_manager.seamless_enabled = false  # Classic teleport mode — seamless is experimental

	# Load exterior cells and register doors
	await get_tree().process_frame
	_load_exterior_cells()
	_scan_doors()
	_loading = false

	# Position camera near first door
	if not _door_pairs.is_empty():
		_teleport_to_door(0)


func _setup_environment() -> void:
	_environment = WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.38, 0.45, 0.55)
	mat.sky_horizon_color = Color(0.64, 0.68, 0.74)
	mat.ground_bottom_color = Color(0.12, 0.10, 0.08)
	mat.ground_horizon_color = Color(0.37, 0.33, 0.28)
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
	_camera.name = "FlyCamera"
	_camera.current = true
	_camera.far = 2000.0
	_camera.position = Vector3(0, 30, 50)
	add_child(_camera)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _setup_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_info_label = Label.new()
	_info_label.position = Vector2(10, 10)
	_info_label.add_theme_font_size_override("font_size", 14)
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
			Log.info("testing", "Loaded exterior cell %s (%d objects)" % [grid, cell_node.get_child_count()])


func _scan_doors() -> void:
	_door_pairs.clear()
	for grid: Vector2i in SEYDA_NEEN_CELLS:
		var cell: CellRecord = ESMManager.get_exterior_cell(grid.x, grid.y)
		if not cell:
			continue
		# Register with pocket manager
		_pocket_manager.register_exterior_cell_doors(cell, grid)
		# Build local door list for TAB cycling
		for ref: CellReference in cell.references:
			if not ref.is_teleport or ref.teleport_cell.is_empty():
				continue
			var dest: CellRecord = ESMManager.get_cell(ref.teleport_cell)
			if not dest or not dest.is_interior():
				continue
			_door_pairs.append({
				"ref_id": str(ref.ref_id),
				"exterior_grid": grid,
				"interior_name": ref.teleport_cell,
				"door_pos_mw": ref.position,
				"interior_ref_count": dest.references.size(),
			})

	# Sort by size (largest interiors first), then promote Arrille's Tradehouse to index 0
	_door_pairs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.interior_ref_count > b.interior_ref_count
	)
	# User preference: default to Arrille's Tradehouse for testing
	for i in _door_pairs.size():
		if _door_pairs[i].interior_name.to_lower().contains("arrille"):
			if i != 0:
				var arrille: Dictionary = _door_pairs[i]
				_door_pairs.remove_at(i)
				_door_pairs.insert(0, arrille)
			Log.info("testing", "Arrille's Tradehouse set as default door (index 0)")
			break
	Log.info("testing", "Found %d doors in Seyda Neen" % _door_pairs.size())


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _mouse_captured:
		_yaw -= event.relative.x * 0.003
		_pitch -= event.relative.y * 0.003
		_pitch = clampf(_pitch, -PI / 2.0 + 0.1, PI / 2.0 - 0.1)

	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		_mouse_captured = not _mouse_captured
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _mouse_captured else Input.MOUSE_MODE_VISIBLE

	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_E:
				_activate_door()
			KEY_TAB:
				_cycle_door()
			KEY_F1:
				_toggle_stencil_debug()
			KEY_F2:
				_cycle_render_layers()
			KEY_F3:
				_toggle_wireframe()
			KEY_F4:
				_toggle_depth_test()
			KEY_F5:
				_toggle_seamless_mode()
			KEY_ESCAPE:
				_mouse_captured = false
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _process(delta: float) -> void:
	_update_camera(delta)
	if _pocket_manager:
		_pocket_manager.update(_camera.global_position, delta)
	_update_ui()


var _camera_frozen: bool = false  ## True during transitions to prevent yaw/pitch overwrite

func _update_camera(delta: float) -> void:
	if not _mouse_captured or _camera_frozen:
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
	if Input.is_physical_key_pressed(KEY_CTRL):
		velocity -= basis.y
	if Input.is_physical_key_pressed(KEY_SPACE):
		velocity += basis.y
	if velocity.length_squared() > 0:
		_camera.position += velocity.normalized() * speed * delta


func _update_ui() -> void:
	if _loading:
		_info_label.text = "Loading..."
		return
	if _door_pairs.is_empty():
		_info_label.text = "No doors found in Seyda Neen."
		return

	var dp: Dictionary = _door_pairs[_current_door_index]
	var text := "Interior Transition Test\n"
	text += "Door [%d/%d]: %s -> %s (%d refs)\n" % [
		_current_door_index + 1, _door_pairs.size(),
		dp.ref_id, dp.interior_name, dp.interior_ref_count
	]

	if _pocket_manager:
		text += _pocket_manager.get_debug_info() + "\n"
		# Show pocket slot positions for debugging
		@warning_ignore("untyped_declaration")
		for slot in _pocket_manager._slots:
			if slot.is_occupied and slot.cell_node:
				text += "  POCKET '%s': pos=%s children=%d\n" % [
					slot.cell_name, slot.cell_node.position, slot.cell_node.get_child_count()]

	@warning_ignore("unsafe_property_access")
	var mode_str: String = "SEAMLESS (walk-through)" if _pocket_manager.seamless_enabled else "CLASSIC (E to teleport)"
	text += "\nMode: %s | E — activate door | TAB — Next door\n" % mode_str
	text += "F1 — Stencil debug (%s) | F2 — Cycle layers | F3 — Wireframe | F4 — Depth test (%s) | F5 — Toggle mode\n" % [
		"ON" if _stencil_debug else "OFF",
		"ON" if _depth_test_mode else "OFF"]
	text += "WASD+mouse — Move | Shift — Fast | Cam layers: 0x%X" % (_camera.cull_mask if _camera else 0)
	_info_label.text = text


## Sync fly camera yaw/pitch from the camera's current basis after a teleport.
## Must be called BEFORE the next _process frame or _update_camera() overwrites it.
func _sync_camera_from_basis() -> void:
	if not _camera:
		return
	var euler: Vector3 = _camera.global_basis.get_euler()
	_yaw = euler.y
	_pitch = clampf(euler.x, -PI / 2.0 + 0.1, PI / 2.0 - 0.1)
	Log.info("testing", "Camera synced: yaw=%.1f° pitch=%.1f°" % [
		rad_to_deg(_yaw), rad_to_deg(_pitch)])


func _activate_door() -> void:
	if not _pocket_manager:
		return

	@warning_ignore("untyped_declaration")
	_camera_frozen = true
	if _pocket_manager.is_inside():
		var closest = _pocket_manager.get_closest_door()
		if closest:
			var dest: CellRecord = ESMManager.get_cell(closest.target_cell_name)
			if dest and dest.is_interior():
				await _pocket_manager.transition_interior_to_interior(closest)
			else:
				await _pocket_manager.exit_to_exterior(closest)
			_sync_camera_from_basis()
		else:
			Log.info("testing", "No door nearby (need to be within 3m)")
	else:
		var closest = _pocket_manager.get_closest_door()
		if closest:
			await _pocket_manager.enter_interior(closest)
			_sync_camera_from_basis()
		else:
			Log.info("testing", "No door nearby (need to be within 3m)")
	_camera_frozen = false


func _cycle_door() -> void:
	if _door_pairs.size() <= 1:
		return
	# If inside an interior, ignore TAB (must exit via door first)
	if _pocket_manager and _pocket_manager.is_inside():
		Log.info("testing", "Exit the interior first before cycling doors")
		return
	_current_door_index = (_current_door_index + 1) % _door_pairs.size()
	_teleport_to_door(_current_door_index)


func _teleport_to_door(index: int) -> void:
	if index < 0 or index >= _door_pairs.size():
		return
	var dp: Dictionary = _door_pairs[index]
	var door_pos: Vector3 = CS.vector_to_godot(dp.door_pos_mw)
	_camera.position = door_pos + Vector3(0, 5, 10)
	_camera.look_at(door_pos)
	_yaw = _camera.rotation.y
	_pitch = _camera.rotation.x
	Log.info("testing", "Camera at door [%d]: %s -> %s" % [index, dp.ref_id, dp.interior_name])


@warning_ignore("untyped_declaration")
func _toggle_stencil_debug() -> void:
	_stencil_debug = not _stencil_debug
	if _pocket_manager and _pocket_manager._active_portal and _pocket_manager._active_portal.is_active:
		_pocket_manager._active_portal.set_debug_visible(_stencil_debug)
	Log.info("testing", "Stencil debug: %s (F1 to toggle)" % ("ON — red plane visible" if _stencil_debug else "OFF"))


## F2: Cycle camera render layers for debugging
## EXTERIOR → INTERIOR → COMBINED → ALL → repeat
var _layer_cycle_index: int = 0
const _LAYER_MODES: Array[Dictionary] = [
	{"name": "EXTERIOR (1-2)", "mask": 0x3},
	{"name": "INTERIOR (3-4)", "mask": 0xC},
	{"name": "COMBINED (1-4)", "mask": 0xF},
	{"name": "ALL (1-20)", "mask": 0xFFFFF},
]

func _cycle_render_layers() -> void:
	_layer_cycle_index = (_layer_cycle_index + 1) % _LAYER_MODES.size()
	@warning_ignore("untyped_declaration")
	var mode = _LAYER_MODES[_layer_cycle_index]
	if _camera:
		_camera.cull_mask = mode.mask
	Log.info("testing", "Camera layers: %s (0x%X)" % [mode.name, mode.mask])


## F4: Toggle depth test on interior stencil-read materials
## OFF (default): no_depth_test=true — interior visible but no depth sorting (walls overdraw tapestries)
## ON: no_depth_test=false — tests if depth-clear plane works (interior may disappear if it doesn't)
@warning_ignore("untyped_declaration")
func _toggle_depth_test() -> void:
	_depth_test_mode = not _depth_test_mode
	if not _pocket_manager or not _pocket_manager._active_portal or not _pocket_manager._active_portal.is_active:
		Log.info("testing", "Depth test toggle: no active portal — activate a door first")
		return
	var portal = _pocket_manager._active_portal
	# Walk all modified materials and flip no_depth_test
	var count: int = 0
	if portal._pocket_slot and portal._pocket_slot.cell_node and is_instance_valid(portal._pocket_slot.cell_node):
		count = _set_depth_test_recursive(portal._pocket_slot.cell_node, not _depth_test_mode)
	Log.info("testing", "Depth test: %s (no_depth_test=%s on %d materials)" % [
		"ON" if _depth_test_mode else "OFF",
		not _depth_test_mode, count])


func _set_depth_test_recursive(node: Node, no_depth_test: bool) -> int:
	var count: int = 0
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		# Check material_override
		if mi.material_override and mi.material_override is StandardMaterial3D:
			var mat := mi.material_override as StandardMaterial3D
			if mat.stencil_mode != 0:  # Has stencil settings = was modified by portal
				mat.no_depth_test = no_depth_test
				count += 1
		# Check surface overrides
		elif mi.mesh:
			for surf_idx in mi.mesh.get_surface_count():
				var mat: Material = mi.get_surface_override_material(surf_idx)
				if mat and mat is StandardMaterial3D:
					var smat := mat as StandardMaterial3D
					if smat.stencil_mode != 0:
						smat.no_depth_test = no_depth_test
						count += 1
	for child in node.get_children():
		count += _set_depth_test_recursive(child, no_depth_test)
	return count


## F3: Toggle wireframe rendering
var _wireframe_enabled: bool = false

func _toggle_wireframe() -> void:
	_wireframe_enabled = not _wireframe_enabled
	if _wireframe_enabled:
		get_viewport().debug_draw = Viewport.DEBUG_DRAW_WIREFRAME
	else:
		get_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED
	Log.info("testing", "Wireframe: %s" % ("ON" if _wireframe_enabled else "OFF"))


## F5: Toggle seamless vs classic mode
func _toggle_seamless_mode() -> void:
	if not _pocket_manager:
		return
	_pocket_manager.seamless_enabled = not _pocket_manager.seamless_enabled
	var mode: String = "SEAMLESS (walk-through + portal preview)" if _pocket_manager.seamless_enabled else "CLASSIC (ENTER to teleport, fade-to-black)"
	Log.info("testing", "Interior mode: %s" % mode)
