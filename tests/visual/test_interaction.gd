## End-to-end interaction test scene
##
## Builds a minimal 3D world with:
##   - A fly camera + InteractionRaycaster
##   - A fake NPC (cylinder mesh + StaticBody3D on layer 3 + NPCInteractable)
##   - A fake book (cube mesh + StaticBody3D on layer 3 + BookInteractable)
##   - Shared DialogueUI + BookViewer singletons
##   - Shared MWDialogueProvider + QuestManager + MWQuestAdapter
##
## Walk up to the NPC, press E → dialogue opens. Walk up to the book,
## press E → book viewer opens. Press Escape to close either panel.
##
## Exercises the full Phase B pipeline: Interactable base, raycaster,
## MW adapters, shared panels, quest signal wiring.
##
## Run: godot --path . res://tests/visual/test_interaction.tscn
@warning_ignore("untyped_declaration", "unsafe_method_access")
extends Node

const InteractionRaycasterScript := preload("res://src/core/interaction/interaction_raycaster.gd")
const NPCInteractableScript := preload("res://src/core/dialogue/morrowind/npc_interactable.gd")
const BookInteractableScript := preload("res://src/core/dialogue/morrowind/book_interactable.gd")
const DialogueUIScript := preload("res://src/core/ui/dialogue_panel.gd")
const BookViewerScript := preload("res://src/core/ui/book_viewer.gd")
const MWDialogueProviderScript := preload("res://src/core/dialogue/morrowind/mw_dialogue_provider.gd")
const DialogueContextScript := preload("res://src/core/dialogue/dialogue_context.gd")
const QuestManagerScript := preload("res://src/core/dialogue/quest_manager.gd")
const MWQuestAdapterScript := preload("res://src/core/dialogue/morrowind/mw_quest_adapter.gd")

const TEST_NPC_ID := "fargoth"
const TEST_BOOK_ID := "book_text_clsg"  # A known Morrowind book

var _camera: Camera3D
var _raycaster: InteractionRaycaster
var _dialogue_ui: DialogueUI
var _book_viewer: BookViewer
var _provider: DialogueProvider
var _context: DialogueContext
var _quest_manager: QuestManager
var _quest_adapter: MWQuestAdapter
var _prompt_label: Label
var _loading_screen: LoadingScreen


func _ready() -> void:
	_loading_screen = LoadingScreen.new()
	add_child(_loading_screen)
	var success = await _loading_screen.load_game_data()
	_loading_screen.queue_free()
	if not success:
		_show_error("Failed to load ESM data.")
		return

	ESMManager.ensure_typed_dicts_populated()

	# Set up the generic dialogue pipeline
	_provider = MWDialogueProviderScript.new()
	_context = DialogueContextScript.new()
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

	# 3D world
	_build_world()
	_build_player()
	_spawn_test_npc()
	_spawn_test_book()

	# Shared UI panels (persistent singletons)
	_dialogue_ui = DialogueUIScript.new()
	add_child(_dialogue_ui)
	# Wire the quest adapter to consume response_selected events
	_dialogue_ui.response_selected.connect(_quest_adapter.on_response_selected)

	_book_viewer = BookViewerScript.new()
	add_child(_book_viewer)

	# Prompt UI
	_build_prompt_label()
	_raycaster.prompt_changed.connect(_on_prompt_changed)

	# Re-bind each Interactable's UI references now that the panels exist
	for child in get_tree().get_nodes_in_group("test_interactables"):
		if child is NPCInteractable:
			var npc_i: NPCInteractable = child as NPCInteractable
			npc_i.dialogue_ui = _dialogue_ui
			npc_i.dialogue_provider = _provider
			npc_i.dialogue_context = _context
		elif child is BookInteractable:
			var book_i: BookInteractable = child as BookInteractable
			book_i.book_viewer = _book_viewer


func _build_world() -> void:
	# A simple floor + directional light so the 3D scene is visible
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1  # Environment
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
	_camera = Camera3D.new()
	# Place camera in front of the NPC at (-1.5, 1.0, 0).
	# Looking straight down -Z axis with a slight pitch to aim at NPC body center (1.3m).
	_camera.position = Vector3(-1.5, 1.7, 2.0)
	add_child(_camera)
	# look_at must happen after add_child — node needs to be in the tree
	_camera.look_at(Vector3(-1.5, 1.3, 0), Vector3.UP)

	_raycaster = InteractionRaycasterScript.new()
	_raycaster.camera = _camera
	_raycaster.max_distance = 5.0
	_raycaster.debug_log = true
	_camera.add_child(_raycaster)


func _spawn_test_npc() -> void:
	# The NPCInteractable IS the root Node3D for this object. Collider + mesh
	# are its children, so the raycaster's walk-up-parent lookup finds it
	# when the ray hits the child StaticBody3D.
	var interactable := NPCInteractableScript.new()
	interactable.name = "TestNPC"
	interactable.position = Vector3(-1.5, 1.0, 0)
	interactable.speaker_id = TEST_NPC_ID
	interactable.max_interaction_distance = 3.0
	interactable.add_to_group("test_interactables")
	add_child(interactable)

	# Visual mesh
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

	# Collider on layer 3 (Interactable)
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
	# Try the configured test book; fall back to the first available book
	var book_id_to_use := TEST_BOOK_ID
	if ESMManager.get_book(book_id_to_use) == null:
		for key in ESMManager.books:
			book_id_to_use = key
			break
	interactable.book_id = book_id_to_use
	interactable.max_interaction_distance = 2.0
	interactable.add_to_group("test_interactables")
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


func _build_prompt_label() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)

	_prompt_label = Label.new()
	_prompt_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_prompt_label.offset_top = -80
	_prompt_label.offset_left = -200
	_prompt_label.offset_right = 200
	_prompt_label.offset_bottom = -40
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_label.add_theme_font_size_override("font_size", 22)
	_prompt_label.add_theme_color_override("font_color", Color(1, 1, 0.85))
	_prompt_label.text = ""
	layer.add_child(_prompt_label)


func _on_prompt_changed(interactable: Interactable, distance: float) -> void:
	if interactable == null:
		_prompt_label.text = ""
		return
	_prompt_label.text = "[E] %s  (%.1fm)" % [interactable.get_prompt_text(), distance]


func _show_error(message: String) -> void:
	var label := Label.new()
	label.text = message
	label.set_anchors_preset(Control.PRESET_CENTER)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
	add_child(label)
