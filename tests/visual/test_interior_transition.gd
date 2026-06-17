extends Node3D

## Interior Transition Test - Pocket Mode Only
##
## Loads Seyda Neen exterior cells, registers doors with InteriorPocketManager,
## then lets you fly to visible DoorInteractable nodes and press E to transition.
##
## Controls:
##   InputMap movement + mouse - fly camera
##   E - interact with the visible door under the crosshair
##   TAB - cycle discovered doors and preload the selected interior
##   ESC - release mouse
const CS := preload("res://src/core/coordinate_system.gd")
const InputActionsScript := preload("res://src/core/input/input_actions.gd")
const CellManagerScript := preload("res://src/core/world/cell_manager.gd")
const InteriorPocketManagerScript := preload("res://src/core/world/interior_pocket_manager.gd")
const InteractionRaycasterScript := preload("res://src/core/interaction/interaction_raycaster.gd")
const LoadingScreenScript := preload("res://src/core/ui/loading_screen.gd")
const BackgroundProcessorScript := preload("res://src/core/streaming/background_processor.gd")
const MorrowindWorldSourceScript := preload("res://src/core/world/morrowind/morrowind_world_source.gd")
const RenderLayersScript := preload("res://src/core/world/render_layers.gd")

# Scene nodes
var _camera: Camera3D
var _environment: WorldEnvironment
var _sun: DirectionalLight3D
var _interaction_raycaster: InteractionRaycaster

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
var _prompt_label: Label
var _loading: bool = true
var _stencil_debug: bool = false
var _depth_test_mode: bool = false
var _prompt_interactable: Interactable = null
var _prompt_distance: float = 0.0
var _manual_status: String = ""

# Frame-time tracking for hiccup verification (P0 fix test harness).
#
# `_peak_window_ms` is the max over a rolling 60-frame window, always on.
# `_transition_peak_ms` is latched when a transition starts and cleared
# when it completes — this is the number that matters for the P0 fix.
# `_hiccup_ms_threshold` = 8.0 per roaster's pass criterion.
# `_transition_recording` flips via transition_started / transition_completed
# signals on the pocket manager.
var _peak_window_ms: float = 0.0
var _peak_window_samples: Array[float] = []
const _PEAK_WINDOW: int = 60
var _transition_peak_ms: float = 0.0
var _transition_recording: bool = false
# Tracks whether the LAST completed transition engaged the fade-to-black
# bridge path (slot was still loading when E was pressed) or took the
# normal path (slot already occupied). Flipped at transition_started time
# based on the current slot state for the target cell. Shown in the debug
# panel so we can tell at a glance which code path a reported peak came
# from — bridge path has a fade-out spike, normal path doesn't.
var _last_transition_bridge: bool = false
const _HICCUP_MS_THRESHOLD: float = 8.0
const _INTERACTION_RAY_LENGTH: float = 6.0
# Running mode doubles camera speed so we can stress the 10m preload window
# at the faster "run" speed roaster flagged (8 m/s vs 5 m/s walk).
var _run_mode: bool = false


func _ready() -> void:
	InputActionsScript.verify()
	_setup_environment()
	_setup_camera()
	_setup_ui()
	_setup_interaction()

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
	var world_source: Variant = MorrowindWorldSourceScript.new()
	_cell_manager.set_world_source(world_source)
	_cell_manager.set_door_activated_handler(Callable(self, "_on_door_interactable_activated"))
	var transition_provider: RefCounted = world_source.call("get_transition_provider")

	# Background processor so the P0 async pocket load path actually runs.
	# Without this, _cell_manager.has_async_capacity() returns false and
	# _load_pocket() falls back to the legacy sync path.
	var bg_processor := BackgroundProcessorScript.new()
	bg_processor.name = "BackgroundProcessor"
	add_child(bg_processor)
	_cell_manager.set_background_processor(bg_processor)

	# Pocket manager
	_pocket_manager = InteriorPocketManagerScript.new()
	_pocket_manager.name = "PocketManager"
	add_child(_pocket_manager)
	_pocket_manager.initialize(_cell_manager, _environment, _camera, _sun, transition_provider)
	_pocket_manager.seamless_enabled = false  # Classic teleport mode — seamless is experimental

	# Hook transition signals so the frame-time tracker knows when to record
	_pocket_manager.transition_started.connect(_on_transition_started)
	_pocket_manager.transition_completed.connect(_on_transition_completed)
	_pocket_manager.interior_load_timeout.connect(_on_interior_load_timeout)

	# Load exterior cells and register doors
	await get_tree().process_frame
	_load_exterior_cells()
	_cell_manager.reconnect_door_activated_handlers(self, Callable(self, "_on_door_interactable_activated"))
	_scan_doors()
	_log_exterior_door_node_summary()
	_loading = false

	# Position camera near first door
	if not _door_pairs.is_empty():
		_teleport_to_door(0)

	# Auto-drive: if launched with `-- --auto-test` (user args after `--`),
	# programmatically walk through a transition so headless runs can
	# verify the async pipeline. Without this the scene just sits idle
	# with no input and the async pipeline is never exercised.
	var user_args: PackedStringArray = OS.get_cmdline_user_args()
	var engine_args: PackedStringArray = OS.get_cmdline_args()
	var has_auto_test: bool = ("--auto-test" in user_args) or ("--auto-test" in engine_args)
	Log.info("testing", "[AUTO-TEST] user_args=%s engine_args_has=%s" % [str(user_args), "--auto-test" in engine_args])
	if has_auto_test:
		_auto_test_run.call_deferred()


func _auto_test_run() -> void:
	Log.info("testing", "[AUTO-TEST] Starting auto-drive verification")
	# Give a frame for everything to settle
	await get_tree().process_frame
	await get_tree().process_frame

	# Teleport camera to within 2m of the first door (already tab-selected=0)
	if _door_pairs.is_empty():
		Log.error("testing", "[AUTO-TEST] No doors — abort")
		return
	var dp: Dictionary = _door_pairs[0]
	var door_pos: Vector3 = CS.vector_to_godot(dp.door_pos_mw)
	_camera.global_position = door_pos + Vector3(0, 1.5, 2.0)
	_camera.look_at(door_pos)
	_yaw = _camera.rotation.y
	_pitch = _camera.rotation.x
	await get_tree().physics_frame
	Log.info("testing", "[AUTO-TEST] Camera at 2m from door '%s' → '%s' (%d refs)" % [
		dp.ref_id, dp.interior_name, dp.interior_ref_count])

	var door = null
	if not str(dp.get("instance_key", "")).is_empty():
		door = _pocket_manager.get_door_info_by_instance_key(StringName(str(dp.instance_key)))
	if door == null:
		Log.error("testing", "[AUTO-TEST] Registered DoorInfo missing for instance key '%s'" % str(dp.get("instance_key", "")))
		get_tree().quit(1)
		return
	var exterior_door_node: Node3D = _find_exterior_door_node(str(dp.instance_key))
	if exterior_door_node == null:
		Log.error("testing", "[AUTO-TEST] No spawned exterior door node for '%s'" % str(dp.instance_key))
		get_tree().quit(1)
		return
	var aim_point: Vector3 = exterior_door_node.global_position + Vector3(0.0, 1.2, 0.0)
	_camera.global_position = aim_point + Vector3(0.0, 0.0, 2.0)
	_camera.look_at(aim_point)
	_sync_camera_from_basis()
	await get_tree().physics_frame
	var exterior_mesh_count: int = _count_visible_meshes(exterior_door_node)
	if exterior_mesh_count <= 0:
		Log.error("testing", "[AUTO-TEST] Spawned exterior door '%s' has no visible meshes" % str(dp.instance_key))
		get_tree().quit(1)
		return
	var targeted_door = _find_targeted_door()
	if targeted_door == null or targeted_door.instance_key != door.instance_key:
		Log.error("testing", "[AUTO-TEST] Interaction ray did not resolve selected door '%s'" % str(dp.instance_key))
		get_tree().quit(1)
		return
	_pocket_manager._ensure_pocket_loaded(door.get_target_space_key())

	# Poll pocket manager until the slot becomes occupied (success) or
	# times out. The auto-test warm-up path uses a burst instantiation budget
	# so cold-cache source-backed interior loads don't fail before the measured
	# transition starts.
	var start_ms: int = Time.get_ticks_msec()
	var timeout_ms: int = 90000
	var occupied_frame: int = -1
	while Time.get_ticks_msec() - start_ms < timeout_ms:
		await get_tree().process_frame
		var slot_any = _pocket_manager._get_slot_for_cell_any(dp.interior_name)
		if slot_any and slot_any.is_occupied:
			occupied_frame = Engine.get_frames_drawn()
			break

	if occupied_frame < 0:
		var loading_stats: Dictionary = _cell_manager.get_loading_stats() if _cell_manager.has_method("get_loading_stats") else {}
		Log.error("testing", "[AUTO-TEST] TIMEOUT waiting for pocket load of '%s' (90s), stats=%s" % [dp.interior_name, str(loading_stats)])
		get_tree().quit(1)
		return

	Log.info("testing", "[AUTO-TEST] Pocket '%s' LOADED in %d ms" % [
		dp.interior_name, Time.get_ticks_msec() - start_ms])

	# Now activate the door to run a real transition
	if not door:
		Log.error("testing", "[AUTO-TEST] DoorInfo unavailable after pocket load")
		get_tree().quit(1)
		return

	Log.info("testing", "[AUTO-TEST] Interacting with raycast target for '%s'" % door.target_cell_name)
	_interact_with_target()
	var enter_start_ms: int = Time.get_ticks_msec()
	while not _pocket_manager.is_inside() and Time.get_ticks_msec() - enter_start_ms < 10000:
		await get_tree().process_frame
	if not _pocket_manager.is_inside():
		Log.error("testing", "[AUTO-TEST] raycast DoorInteractable activation did not enter interior")
		get_tree().quit(1)
		return

	# Wait 2 frames for _on_transition_completed to fire and the active pocket
	# state to settle before asserting the return path.
	await get_tree().process_frame
	await get_tree().process_frame
	if not _pocket_manager.is_inside():
		Log.error("testing", "[AUTO-TEST] entered transition completed but manager is not inside")
		get_tree().quit(1)
		return

	var active_slot = _pocket_manager._active_pocket
	if active_slot == null or active_slot.doors_inside.is_empty():
		Log.error("testing", "[AUTO-TEST] active pocket has no registered interior doors")
		get_tree().quit(1)
		return

	var exit_door = null
	for candidate in active_slot.doors_inside:
		if not candidate.has_interior_target():
			exit_door = candidate
			break
	if exit_door == null:
		Log.error("testing", "[AUTO-TEST] no exterior exit door registered in '%s'" % active_slot.cell_name)
		get_tree().quit(1)
		return

	Log.info("testing", "[AUTO-TEST] Calling exit_to_exterior through '%s'" % exit_door.instance_key)
	var ok: bool = await _pocket_manager.exit_to_exterior(exit_door)
	if not ok:
		Log.error("testing", "[AUTO-TEST] exit_to_exterior() returned false")
		get_tree().quit(1)
		return

	await get_tree().process_frame
	await get_tree().process_frame
	if _pocket_manager.is_inside():
		Log.error("testing", "[AUTO-TEST] exit transition completed but manager is still inside")
		get_tree().quit(1)
		return
	if not RenderLayersScript.has_exterior_world(_camera.cull_mask) or RenderLayersScript.has_interior_world(_camera.cull_mask):
		Log.error("testing", "[AUTO-TEST] camera cull mask was not restored to exterior world layers: 0x%X" % _camera.cull_mask)
		get_tree().quit(1)
		return
	if not RenderLayersScript.has_water_surface(_camera.cull_mask):
		Log.error("testing", "[AUTO-TEST] camera cull mask lost persistent water layer: 0x%X" % _camera.cull_mask)
		get_tree().quit(1)
		return

	var verdict: String = "PASS" if _transition_peak_ms <= _HICCUP_MS_THRESHOLD else "FAIL"
	Log.info("testing", "[AUTO-TEST] RESULT: enter+exit complete, last transition peak=%.2f ms [%s]" % [_transition_peak_ms, verdict])
	await _finish_auto_test(0 if verdict == "PASS" else 2)


func _finish_auto_test(exit_code: int) -> void:
	Log.info("testing", "[AUTO-TEST] cleanup begin")
	if _pocket_manager != null and _pocket_manager.has_method("cleanup"):
		Log.info("testing", "[AUTO-TEST] cleanup pocket manager")
		_pocket_manager.cleanup()
	if _cell_manager != null and _cell_manager.has_method("fast_cleanup"):
		Log.info("testing", "[AUTO-TEST] cleanup cell manager")
		_cell_manager.fast_cleanup()
	for child: Node in get_children():
		if child.name.begins_with("Cell_"):
			child.queue_free()
	for i in range(5):
		await get_tree().process_frame
	Log.info("testing", "[AUTO-TEST] cleanup quit")
	get_tree().quit(exit_code)


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
	_camera.cull_mask = RenderLayersScript.with_water_surface(_camera.cull_mask)
	_camera.position = Vector3(0, 30, 50)
	add_child(_camera)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _setup_interaction() -> void:
	_interaction_raycaster = InteractionRaycasterScript.new()
	_interaction_raycaster.name = "InteractionRaycaster"
	_interaction_raycaster.camera = _camera
	_interaction_raycaster.max_distance = _INTERACTION_RAY_LENGTH
	_interaction_raycaster.prompt_changed.connect(_on_interact_prompt_changed)
	_camera.add_child(_interaction_raycaster)


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

	_prompt_label = Label.new()
	_prompt_label.name = "DoorPrompt"
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_prompt_label.add_theme_font_size_override("font_size", 20)
	_prompt_label.add_theme_color_override("font_color", Color.WHITE)
	_prompt_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_prompt_label.add_theme_constant_override("shadow_offset_x", 2)
	_prompt_label.add_theme_constant_override("shadow_offset_y", 2)
	_prompt_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_prompt_label.offset_top = -80
	_prompt_label.offset_bottom = -40
	_prompt_label.offset_left = -260
	_prompt_label.offset_right = 260
	_prompt_label.visible = false
	canvas.add_child(_prompt_label)


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
			var instance_key := ""
			if ref.has_meta("transition_portal_key"):
				instance_key = str(ref.get_meta("transition_portal_key"))
			if instance_key.is_empty():
				instance_key = str(InteriorPocketManagerScript.make_exterior_door_instance_key(grid, ref.ref_id, ref.ref_num))
			_door_pairs.append({
				"ref_id": str(ref.ref_id),
				"instance_key": instance_key,
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


func _log_exterior_door_node_summary() -> void:
	var spawned_doors: int = 0
	var spawned_with_meshes: int = 0
	var source_type_counts: Dictionary = {}
	for node: Node in _iter_nodes(self):
		if not node is Node3D:
			continue
		if node.has_meta("source_type"):
			var source_type := str(node.get_meta("source_type"))
			source_type_counts[source_type] = int(source_type_counts.get(source_type, 0)) + 1
		var key: String = _get_node_door_instance_key(node)
		if key.is_empty():
			continue
		spawned_doors += 1
		if _count_visible_meshes(node) > 0:
			spawned_with_meshes += 1
	Log.info("testing", "Spawned exterior door nodes: %d (%d with visible meshes)" % [
		spawned_doors,
		spawned_with_meshes,
	])
	Log.info("testing", "Spawned source_type counts: %s" % str(source_type_counts))


func _find_exterior_door_node(instance_key: String) -> Node3D:
	if instance_key.is_empty():
		return null
	for node: Node in _iter_nodes(self):
		if not node is Node3D:
			continue
		if _get_node_door_instance_key(node) == instance_key:
			return node as Node3D
	return null


func _get_node_door_instance_key(node: Node) -> String:
	if node == null:
		return ""
	if "door_instance_key" in node:
		return str(node.get("door_instance_key"))
	var property_value: Variant = node.get("door_instance_key")
	if property_value != null and not str(property_value).is_empty():
		return str(property_value)
	if node.has_meta("door_instance_key"):
		return str(node.get_meta("door_instance_key"))
	if node.has_meta("transition_portal_key"):
		return str(node.get_meta("transition_portal_key"))
	return ""


func _count_visible_meshes(root: Node) -> int:
	var count := 0
	for node: Node in _iter_nodes(root):
		if node is MeshInstance3D:
			var mesh_node := node as MeshInstance3D
			if mesh_node.visible and mesh_node.mesh != null:
				count += 1
	return count


func _iter_nodes(root: Node) -> Array[Node]:
	var out: Array[Node] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		out.append(node)
		for child: Node in node.get_children():
			stack.append(child)
	return out


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _mouse_captured:
		_yaw -= event.relative.x * 0.003
		_pitch -= event.relative.y * 0.003
		_pitch = clampf(_pitch, -PI / 2.0 + 0.1, PI / 2.0 - 0.1)

	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		_mouse_captured = not _mouse_captured
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _mouse_captured else Input.MOUSE_MODE_VISIBLE

	if event.is_action_pressed(&"interact"):
		_interact_with_target()
		return

	if event is InputEventKey and event.pressed:
		match event.keycode:
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
			KEY_R:
				_toggle_run_mode()
			KEY_ESCAPE:
				_mouse_captured = false
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _process(delta: float) -> void:
	_track_frame_time(delta)
	_update_camera(delta)

	# CRITICAL PUMP: In the main scene, NativeStreamingManager drives both
	# payload publication and scene-tree instantiation every frame. This
	# verifier has no NativeStreamingManager, so it must do both itself.
	# If payload publication is skipped, a pocket request can stay incomplete
	# forever even while the player is standing in preload range.
	if _cell_manager:
		if _cell_manager.has_method("process_async_payloads"):
			_cell_manager.call("process_async_payloads", 4000)
		_cell_manager.process_async_instantiation(
			4.0,
			_camera.global_position,
			-_camera.global_basis.z
		)

	if _pocket_manager:
		_pocket_manager.update(_camera.global_position, delta)
	_update_interaction_prompt()
	_update_ui()


## Sliding-window frame time max. Also latches the per-transition peak
## while _transition_recording is true (set by transition_started signal).
func _track_frame_time(delta: float) -> void:
	var frame_ms: float = delta * 1000.0
	_peak_window_samples.append(frame_ms)
	if _peak_window_samples.size() > _PEAK_WINDOW:
		_peak_window_samples.pop_front()
	var max_ms: float = 0.0
	for s: float in _peak_window_samples:
		if s > max_ms:
			max_ms = s
	_peak_window_ms = max_ms
	if _transition_recording and frame_ms > _transition_peak_ms:
		_transition_peak_ms = frame_ms


func _on_transition_started(target_cell: String) -> void:
	_transition_recording = true
	_transition_peak_ms = 0.0
	# Determine whether the bridge path is about to engage. If the target
	# cell's slot is still loading / finishing up at this moment, enter_interior
	# will take the fade-to-black bridge branch; otherwise the normal path.
	_last_transition_bridge = false
	if _pocket_manager:
		@warning_ignore("untyped_declaration")
		var slot = _pocket_manager._get_slot_for_cell_any(target_cell)
		if slot and (slot.is_loading or slot.finish_up_phase >= 0):
			_last_transition_bridge = true
	Log.info("testing", "[FRAMETIME] transition_started → '%s', bridge=%s tracking begin" % [
		target_cell, _last_transition_bridge])


func _on_transition_completed(cell_name: String) -> void:
	_transition_recording = false
	var verdict: String = "PASS" if _transition_peak_ms <= _HICCUP_MS_THRESHOLD else "FAIL"
	var bridge_str: String = "BRIDGE" if _last_transition_bridge else "NORMAL"
	Log.info("testing", "[FRAMETIME] transition_completed → '%s' path=%s peak=%.2f ms [%s]" % [
		cell_name, bridge_str, _transition_peak_ms, verdict])


func _on_interior_load_timeout(cell_name: String, request_id: int) -> void:
	Log.error("testing", "[FRAMETIME] interior_load_timeout for '%s' (req=%d) — fallback triggered" % [
		cell_name, request_id])


func _toggle_run_mode() -> void:
	_run_mode = not _run_mode
	_camera_speed = 40.0 if _run_mode else 20.0
	Log.info("testing", "Run mode: %s (camera speed %.0f)" % ["ON" if _run_mode else "OFF", _camera_speed])


var _camera_frozen: bool = false  ## True during transitions to prevent yaw/pitch overwrite

func _update_camera(delta: float) -> void:
	if not _mouse_captured or _camera_frozen:
		return
	var basis := Basis.from_euler(Vector3(_pitch, _yaw, 0))
	_camera.basis = basis
	var velocity := Vector3.ZERO
	var speed := _camera_speed
	if Input.is_action_pressed(&"sprint"):
		speed *= 3.0
	var move_input: Vector2 = Input.get_vector(
		&"move_left",
		&"move_right",
		&"move_forward",
		&"move_backward"
	)
	if move_input.y < 0.0:
		velocity -= basis.z * absf(move_input.y)
	elif move_input.y > 0.0:
		velocity += basis.z * move_input.y
	if move_input.x < 0.0:
		velocity -= basis.x * absf(move_input.x)
	elif move_input.x > 0.0:
		velocity += basis.x * move_input.x
	if Input.is_action_pressed(&"crouch"):
		velocity -= basis.y
	if Input.is_action_pressed(&"jump"):
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
	var selected_key := str(dp.get("instance_key", ""))
	var selected_door = null
	if _pocket_manager != null and not selected_key.is_empty():
		selected_door = _pocket_manager.get_door_info_by_instance_key(StringName(selected_key))
	var selected_state := _get_door_transition_state(selected_door)
	var selected_blocker := _get_door_transition_blocker(selected_door)

	var text := "Interior Transition Test\n"
	text += "Door [%d/%d]: %s -> %s (%d refs)\n" % [
		_current_door_index + 1,
		_door_pairs.size(),
		dp.ref_id,
		dp.interior_name,
		dp.interior_ref_count,
	]

	if _camera:
		var target_pos: Vector3 = CS.vector_to_godot(dp.door_pos_mw)
		var dist: float = _camera.global_position.distance_to(target_pos)
		text += "TAB target: %.1fm | preload state: %s\n" % [dist, selected_state]
		if selected_state == "blocked":
			text += "  blocker: %s\n" % selected_blocker
		elif selected_state == "not loaded":
			text += "  TAB preloads this interior; aim at the visible door for the real prompt.\n"
		elif selected_state == "loading":
			text += "  loading selected pocket; keep moving/aiming, then interact when READY.\n"
		else:
			text += "  READY: move into range, aim at the visible door, press E.\n"

	if not _manual_status.is_empty():
		text += "Status: %s\n" % _manual_status

	if _pocket_manager:
		text += _pocket_manager.get_debug_info() + "\n"
		@warning_ignore("untyped_declaration")
		for slot in _pocket_manager._slots:
			if slot.is_occupied and slot.cell_node:
				text += "  POCKET '%s': READY pos=%s children=%d\n" % [
					slot.cell_name,
					slot.cell_node.position,
					slot.cell_node.get_child_count(),
				]
			elif slot.is_loading:
				text += "  POCKET '%s': LOADING (req=%d, phase=%d)\n" % [
					slot.cell_name,
					slot.async_request_id,
					slot.finish_up_phase,
				]

	text += "\n[FRAMETIME] window peak(1s)=%.2f ms  threshold=%.1f ms  run=%s\n" % [
		_peak_window_ms,
		_HICCUP_MS_THRESHOLD,
		"ON" if _run_mode else "OFF",
	]
	if _transition_recording:
		var live_path: String = "BRIDGE" if _last_transition_bridge else "NORMAL"
		text += "[FRAMETIME] TRANSITION RECORDING (%s) - peak so far=%.2f ms\n" % [live_path, _transition_peak_ms]
	elif _transition_peak_ms > 0.0:
		var verdict: String = "PASS" if _transition_peak_ms <= _HICCUP_MS_THRESHOLD else "FAIL"
		var path: String = "BRIDGE" if _last_transition_bridge else "NORMAL"
		text += "[FRAMETIME] last transition peak=%.2f ms  path=%s  [%s]\n" % [
			_transition_peak_ms,
			path,
			verdict,
		]

	@warning_ignore("unsafe_property_access")
	var mode_str: String = "SEAMLESS (walk-through)" if _pocket_manager.seamless_enabled else "CLASSIC (E to teleport)"
	text += "\nMode: %s | Aim at visible door + E | TAB preloads next door\n" % mode_str
	text += "F1 stencil (%s) | F2 layers | F3 wireframe | F4 depth (%s) | F5 mode | R run (%s)\n" % [
		"ON" if _stencil_debug else "OFF",
		"ON" if _depth_test_mode else "OFF",
		"ON" if _run_mode else "OFF",
	]
	text += "Move: InputMap movement + mouse | Sprint: InputMap sprint | Cam layers: 0x%X" % (_camera.cull_mask if _camera else 0)
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


func _interact_with_target() -> void:
	if _interaction_raycaster == null:
		Log.info("interaction", "[TEST_INTERACT] no raycaster wired")
		return
	var target: Interactable = _interaction_raycaster.get_current_target()
	if target == null:
		_manual_status = "No interactable under crosshair"
		Log.info("interaction", "[TEST_INTERACT] no target under crosshair")
		return
	Log.info("interaction", "[TEST_INTERACT] target=%s prompt='%s'" % [
		target.name,
		target.get_prompt_text(),
	])
	target.interact(_camera)


func _on_door_interactable_activated(door_instance_key: String, _door_record: Variant, _player: Node3D) -> void:
	if _pocket_manager == null:
		return
	if _pocket_manager.has_method("is_transitioning") and bool(_pocket_manager.call("is_transitioning")):
		Log.debug("streaming", "[TEST_DOOR_INTERACT] ignoring '%s' while transition is active" % door_instance_key)
		return
	var door = _pocket_manager.get_door_info_by_instance_key(StringName(door_instance_key))
	if door == null:
		_manual_status = "No DoorInfo for %s" % door_instance_key
		Log.warn("streaming", "[TEST_DOOR_INTERACT] no DoorInfo for instance key '%s'" % door_instance_key)
		return

	var state := _get_door_transition_state(door)
	if state != "ready":
		_preload_door(door)
		_manual_status = "Loading %s... wait for READY, then press E again" % door.get_target_space_key()
		Log.info("streaming", "[TEST_DOOR_INTERACT] door '%s' state=%s; preload requested" % [
			door.instance_key,
			state,
		])
		return

	await _activate_door(door)


func _activate_door(door: Variant) -> void:
	if not _pocket_manager or door == null:
		return
	if _pocket_manager.has_method("is_transitioning") and bool(_pocket_manager.call("is_transitioning")):
		return

	_camera_frozen = true
	_manual_status = "Transitioning..."
	if _pocket_manager.is_inside():
		if door.has_method("has_interior_target") and bool(door.call("has_interior_target")):
			await _pocket_manager.transition_interior_to_interior(door)
		else:
			await _pocket_manager.exit_to_exterior(door)
	else:
		var success: bool = await _pocket_manager.enter_interior(door)
		if not success:
			_manual_status = "Enter failed: %s" % door.get_target_space_key()
			Log.error("streaming", "[TEST_DOOR_INTERACT] enter_interior failed for '%s'" % door.get_target_space_key())
	_sync_camera_from_basis()
	_camera_frozen = false
	if _manual_status == "Transitioning...":
		_manual_status = ""


func _find_targeted_door():
	if _interaction_raycaster == null or _pocket_manager == null:
		return null
	_interaction_raycaster.call("_update_target")
	var target: Interactable = _interaction_raycaster.get_current_target()
	if target == null:
		return null
	var instance_key := _get_node_door_instance_key(target)
	if instance_key.is_empty():
		return null
	return _pocket_manager.get_door_info_by_instance_key(StringName(instance_key))


func _preload_door(door: Variant) -> void:
	if door == null or _pocket_manager == null:
		return
	if not door.has_method("has_interior_target") or not bool(door.call("has_interior_target")):
		return
	_pocket_manager._ensure_pocket_loaded(door.get_target_space_key())


func _preload_selected_door() -> void:
	if _current_door_index < 0 or _current_door_index >= _door_pairs.size():
		return
	var dp: Dictionary = _door_pairs[_current_door_index]
	var door = _pocket_manager.get_door_info_by_instance_key(StringName(str(dp.get("instance_key", ""))))
	if door != null:
		_preload_door(door)


func _get_door_transition_state(door: Variant) -> String:
	if door == null:
		return "blocked"
	if _pocket_manager == null:
		return "blocked"
	if _pocket_manager != null and _pocket_manager.is_inside():
		if not door.has_method("has_interior_target") or not bool(door.call("has_interior_target")):
			return "ready"
	if not door.has_method("has_interior_target") or not bool(door.call("has_interior_target")):
		return "ready"
	var slot = _pocket_manager._get_slot_for_cell_any(door.get_target_space_key())
	if slot == null:
		return "not loaded"
	if slot.is_loading or slot.finish_up_phase >= 0:
		return "loading"
	var blocker: String = _pocket_manager._get_pocket_transition_blocker(slot)
	return "ready" if blocker.is_empty() else "blocked"


func _get_door_transition_blocker(door: Variant) -> String:
	if door == null or _pocket_manager == null:
		return "no door"
	if not door.has_method("has_interior_target") or not bool(door.call("has_interior_target")):
		return ""
	var slot = _pocket_manager._get_slot_for_cell_any(door.get_target_space_key())
	if slot == null:
		return "not loaded"
	if slot.is_loading or slot.finish_up_phase >= 0:
		return "loading"
	return _pocket_manager._get_pocket_transition_blocker(slot)


func _on_interact_prompt_changed(interactable: Interactable, distance: float) -> void:
	_prompt_interactable = interactable
	_prompt_distance = distance
	_update_interaction_prompt()


func _update_interaction_prompt() -> void:
	if _prompt_label == null:
		return
	if _prompt_interactable == null:
		_prompt_label.visible = false
		return
	var text := _prompt_interactable.get_prompt_text()
	var instance_key := _get_node_door_instance_key(_prompt_interactable)
	if not instance_key.is_empty() and _pocket_manager != null:
		var door = _pocket_manager.get_door_info_by_instance_key(StringName(instance_key))
		var state := _get_door_transition_state(door)
		match state:
			"ready":
				if _manual_status.begins_with("Loading "):
					_manual_status = ""
				_prompt_label.text = "[E] %s  (%.1fm)" % [text, _prompt_distance]
			"not loaded":
				_prompt_label.text = "[E] Load %s  (%.1fm)" % [text, _prompt_distance]
			"loading":
				_prompt_label.text = "Loading %s... wait" % door.get_target_space_key()
			_:
				_prompt_label.text = "Blocked: %s" % _get_door_transition_blocker(door)
	else:
		_prompt_label.text = "[E] %s  (%.1fm)" % [text, _prompt_distance]
	_prompt_label.visible = true


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
	_camera.position = door_pos + Vector3(0, 1.6, 7.0)
	_camera.look_at(door_pos)
	_yaw = _camera.rotation.y
	_pitch = _camera.rotation.x
	_preload_selected_door()
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
	var mode: String = "SEAMLESS (walk-through + portal preview)" if _pocket_manager.seamless_enabled else "CLASSIC (E to teleport, fade-to-black)"
	Log.info("testing", "Interior mode: %s" % mode)
