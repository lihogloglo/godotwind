## Phase I.0 — PlayerController as single input owner
##
## Validates the I.0 contract from `docs/INTERACTION_SYSTEM.md` §3.1:
##   - `PlayerController` is the only site that reads the `interact` action
##   - Three semantic signals: `interact_tap`, `interact_hold_begin`,
##     `interact_release` with hold detection in `_physics_process`
##   - Modal UI gate registry: `register_modal_gate` / `unregister_modal_gate`
##     / `is_modal_ui_open` with `is_open()` contract + `tree_exiting`
##     self-heal
##   - `InteractionRaycaster` is pure state, called via `get_current_target()`
##
## Test flow (interactive — pilot the camera with mouse, press E):
##   1. Look at Fargoth (left), tap E quickly → dialogue opens
##      → `interact_tap` log line, dialogue panel shows
##   2. Press Esc → dialogue closes (existing C.2 close handler)
##   3. Look at the book (right), hold E for >0.2s → `interact_hold_begin`
##      log line. Book is also carryable (will matter in I.3+); for I.0 the
##      hold simply emits the signal without doing anything else.
##   4. Release E → `interact_release` log line.
##   5. Look at the book, tap E quickly → book viewer opens (`interact_tap`
##      routes to BookInteractable.interact()).
##   6. While the book is open, press E (the BookViewer's own _unhandled_input
##      closes it) → `is_modal_ui_open` returns true during the press, so
##      `PlayerController` does NOT also fire interact_tap and reopen it.
##
## On startup the scene also runs an automatic self-test for the
## `tree_exiting` self-heal path: spawns a fake gate, registers it,
## frees it, asserts the registry shrinks back to 1 entry.
##
## Run: godot --path . res://tests/visual/test_interaction_phase_I0.tscn
@warning_ignore("untyped_declaration", "unsafe_method_access")
extends Node

const InteractionRaycasterScript := preload("res://src/core/interaction/interaction_raycaster.gd")
const PlayerControllerScript := preload("res://src/core/player/player_controller.gd")
const NPCInteractableScript := preload("res://src/core/dialogue/morrowind/npc_interactable.gd")
const BookInteractableScript := preload("res://src/core/dialogue/morrowind/book_interactable.gd")
const DialogueUIScript := preload("res://src/core/ui/dialogue_panel.gd")
const BookViewerScript := preload("res://src/core/ui/book_viewer.gd")
const MWDialogueProviderScript := preload("res://src/core/dialogue/morrowind/mw_dialogue_provider.gd")
const MWDialogueContextScript := preload("res://src/core/dialogue/morrowind/mw_dialogue_context.gd")
const QuestManagerScript := preload("res://src/core/dialogue/quest_manager.gd")
const MWQuestAdapterScript := preload("res://src/core/dialogue/morrowind/mw_quest_adapter.gd")

const TEST_NPC_ID := "fargoth"
const TEST_BOOK_ID := "book_text_clsg"

var _player: PlayerController
var _raycaster: InteractionRaycaster
var _dialogue_ui: DialogueUI
var _book_viewer: BookViewer
var _provider: DialogueProvider
var _context: MWDialogueContext
var _session: DialogueSession
var _quest_manager: QuestManager
var _quest_adapter: MWQuestAdapter
var _prompt_label: Label
var _event_log_label: Label
var _event_lines: Array[String] = []
var _loading_screen: LoadingScreen


# A tiny fake gate used to verify register_modal_gate's tree_exiting self-heal.
class FakeGate extends Node:
	var open_state: bool = false
	func is_open() -> bool:
		return open_state


func _ready() -> void:
	_loading_screen = LoadingScreen.new()
	add_child(_loading_screen)
	var success = await _loading_screen.load_game_data()
	_loading_screen.queue_free()
	if not success:
		_show_error("Failed to load ESM data.")
		return

	ESMManager.ensure_typed_dicts_populated()

	_provider = MWDialogueProviderScript.new()
	_context = MWDialogueContextScript.new()
	_context.pc_race = "imperial"
	_context.pc_class = "rogue"
	_context.pc_gender = 0
	_context.pc_level = 1
	_context.detected = true
	_context.talked_to_pc = false
	_context.set_global("chargenstate", 10.0)
	_context.pc_health = 50
	_context.pc_health_percent = 100
	_context.pc_magicka = 50
	_context.pc_fatigue = 100
	_context.pc_clothing_value = 100

	_quest_manager = QuestManagerScript.new()
	_quest_adapter = MWQuestAdapterScript.new(_quest_manager)

	_dialogue_ui = DialogueUIScript.new()
	add_child(_dialogue_ui)
	_dialogue_ui.response_selected.connect(_quest_adapter.on_response_selected)

	_book_viewer = BookViewerScript.new()
	add_child(_book_viewer)

	_session = DialogueSession.new()
	_session.provider = _provider
	_session.context = _context
	_session.dialogue_ui = _dialogue_ui
	_session.book_viewer = _book_viewer
	DialogueSession.set_current(_session)

	_build_world()
	_build_player()
	_spawn_test_npc()
	_spawn_test_book()
	_build_ui()

	# Wire interact signals to the event log AFTER player exists.
	_player.interact_tap.connect(_on_interact_tap)
	_player.interact_hold_begin.connect(_on_interact_hold_begin)
	_player.interact_release.connect(_on_interact_release)
	_raycaster.prompt_changed.connect(_on_prompt_changed)

	# Register the modal UIs as input gates. While either is open, the
	# player controller will suppress all interact_* signal emission.
	_player.register_modal_gate(_dialogue_ui)
	_player.register_modal_gate(_book_viewer)

	_log_event("[I.0 ready] mouse-look only — walking comes in I.1+")
	_log_event("Look at Fargoth (left) or the book (right), then press E")

	# Run the auto self-test on the tree_exiting self-heal path.
	await _self_test_tree_exiting_cleanup()


func _build_world() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	add_child(floor_body)

	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20, 0.2, 20)
	floor_shape.shape = box
	floor_body.add_child(floor_shape)

	var floor_mesh := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(20, 0.2, 20)
	floor_mesh.mesh = mesh
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.3, 0.3, 0.35)
	floor_mesh.material_override = floor_mat
	floor_body.add_child(floor_mesh)

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-PI / 4, PI / 4, 0)
	sun.light_energy = 1.2
	add_child(sun)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.15, 0.18, 0.22)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.4
	env_node.environment = env
	add_child(env_node)


func _build_player() -> void:
	# PlayerController owns the `interact` action. We use it standalone
	# (no character / animation system attached). Movement is not exercised
	# in I.0 — that's I.1+. Mouse-look + interact are sufficient to validate
	# the input owner contract.
	_player = PlayerControllerScript.new()
	_player.position = Vector3(0, 0.1, 2.5)
	add_child(_player)
	# First-person — collapses spring arm so the camera sits at head height.
	# We must FORCE spring_arm.spring_length = 0 immediately because
	# set_camera_mode only updates the lerp target — without _physics_process
	# running enough frames, the camera would stay 3.5m behind the player
	# (third-person default) and the raycaster's 8m range would still struggle
	# to hit close objects past the player capsule.
	_player.set_camera_mode(PlayerControllerScript.CameraMode.FIRST_PERSON)
	_player.spring_arm.spring_length = 0.0
	_player.enable()
	# Auto-capture mouse so the user doesn't have to left-click first to look
	# around. PlayerController._unhandled_input also captures on left-click,
	# but the tester needs mouse-look to AIM at Fargoth/book before pressing E.
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# Raycaster as a child of the player camera. PlayerController will
	# query its current target on interact_tap.
	_raycaster = InteractionRaycasterScript.new()
	_raycaster.camera = _player.get_camera()
	_raycaster.max_distance = 8.0
	_raycaster.debug_log = true
	_player.get_camera().add_child(_raycaster)
	_player.set_interaction_raycaster(_raycaster)


func _spawn_test_npc() -> void:
	var interactable := NPCInteractableScript.new()
	interactable.name = "TestNPC"
	# Dead-center forward so the test is verifiable WITHOUT mouse aiming —
	# user just taps E from the default camera angle and the raycast hits.
	# Book stays off to the right for the optional second-path test.
	interactable.position = Vector3(0, 1.0, 0)
	interactable.speaker_id = TEST_NPC_ID
	interactable.max_interaction_distance = 5.0
	add_child(interactable)

	var mesh_inst := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.height = 1.8
	cyl.top_radius = 0.3
	cyl.bottom_radius = 0.3
	mesh_inst.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.75, 0.55, 0.35)
	mesh_inst.material_override = mat
	interactable.add_child(mesh_inst)

	var body := StaticBody3D.new()
	body.collision_layer = 1 << 2
	body.collision_mask = 0
	interactable.add_child(body)

	var shape := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.height = 1.8
	cap.radius = 0.35
	shape.shape = cap
	body.add_child(shape)


func _spawn_test_book() -> void:
	var interactable := BookInteractableScript.new()
	interactable.name = "TestBook"
	interactable.position = Vector3(1.5, 1.0, 0)
	var book_id_to_use := TEST_BOOK_ID
	if ESMManager.get_book(book_id_to_use) == null:
		for key in ESMManager.books:
			book_id_to_use = key
			break
	interactable.book_id = book_id_to_use
	# BookInteractable reads its viewer from DialogueSession.current() —
	# the session was already constructed in _ready() with _book_viewer.
	interactable.max_interaction_distance = 5.0
	add_child(interactable)

	var mesh_inst := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.2, 0.3, 0.05)
	mesh_inst.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.5, 0.25, 0.15)
	mesh_inst.material_override = mat
	interactable.add_child(mesh_inst)

	var body := StaticBody3D.new()
	body.collision_layer = 1 << 2
	body.collision_mask = 0
	interactable.add_child(body)

	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(0.4, 0.5, 0.3)
	shape.shape = box_shape
	body.add_child(shape)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)

	_prompt_label = Label.new()
	_prompt_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_prompt_label.offset_top = -100
	_prompt_label.offset_left = -250
	_prompt_label.offset_right = 250
	_prompt_label.offset_bottom = -60
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_label.add_theme_font_size_override("font_size", 22)
	_prompt_label.add_theme_color_override("font_color", Color(1, 1, 0.85))
	_prompt_label.text = ""
	layer.add_child(_prompt_label)

	_event_log_label = Label.new()
	_event_log_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_event_log_label.offset_left = 16
	_event_log_label.offset_top = 16
	_event_log_label.offset_right = 700
	_event_log_label.offset_bottom = 220
	_event_log_label.add_theme_font_size_override("font_size", 14)
	_event_log_label.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0))
	_event_log_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_event_log_label.text = ""
	layer.add_child(_event_log_label)

	# Permanent help label (top-right) — tells the user where to aim,
	# since they can't walk to find things in I.0.
	var help := Label.new()
	help.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	help.offset_left = -380
	help.offset_top = 16
	help.offset_right = -16
	help.offset_bottom = 220
	help.add_theme_font_size_override("font_size", 14)
	help.add_theme_color_override("font_color", Color(1.0, 0.95, 0.7))
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.text = "I.0 controls\n  mouse: look around (no walking in I.0)\n  E (tap): primary verb on target\n  E (hold > 0.2s): hold_begin signal\n  E release: release signal\n  Esc: close panel\n\nlook DOWN-LEFT for Fargoth (cylinder)\nlook DOWN-RIGHT for the book\nbottom of screen shows current target"
	layer.add_child(help)


func _on_prompt_changed(interactable: Interactable, distance: float) -> void:
	if interactable == null:
		_prompt_label.text = ""
		return
	_prompt_label.text = "[E] %s  (%.1fm)" % [interactable.get_prompt_text(), distance]


func _on_interact_tap() -> void:
	var target := _raycaster.get_current_target()
	var name_str: String = "(no target)" if target == null else String(target.name)
	_log_event("interact_tap → %s" % name_str)


func _on_interact_hold_begin() -> void:
	var target := _raycaster.get_current_target()
	var name_str: String = "(no target)" if target == null else String(target.name)
	_log_event("interact_hold_begin → %s" % name_str)


func _on_interact_release() -> void:
	_log_event("interact_release")


func _log_event(line: String) -> void:
	_event_lines.append("%s  %s" % [Time.get_time_string_from_system(), line])
	while _event_lines.size() > 12:
		_event_lines.pop_front()
	if _event_log_label != null:
		_event_log_label.text = "\n".join(_event_lines)
	Log.info("interaction", line)


## Auto self-test: register a fake gate, free it, verify it's removed.
func _self_test_tree_exiting_cleanup() -> void:
	var gate := FakeGate.new()
	gate.name = "FakeGateForSelfTest"
	add_child(gate)
	var before: int = _player.get_modal_gate_count()
	_player.register_modal_gate(gate)
	var registered: int = _player.get_modal_gate_count()
	if registered != before + 1:
		_log_event("SELF-TEST FAIL: register did not increment count")
		return
	gate.queue_free()
	await get_tree().process_frame
	var after: int = _player.get_modal_gate_count()
	if after == before:
		_log_event("SELF-TEST PASS: tree_exiting self-heal removed freed gate")
	else:
		_log_event("SELF-TEST FAIL: gate count after free = %d (expected %d)" % [after, before])


func _show_error(message: String) -> void:
	var label := Label.new()
	label.text = message
	label.set_anchors_preset(Control.PRESET_CENTER)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
	add_child(label)
