## NPC Viewer - Tool for viewing and testing NPC assembly and animation
##
## Features:
## - Browse all NPCs from loaded ESM
## - View assembled body parts
## - Test animations (idle, walk, run, combat)
## - Inspect NPC stats and equipment
## - Debug bone structure
##
## Usage:
## - Load ESM data first
## - Select NPC from list or search
## - View assembled character with animations
@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_cast", "unsafe_call_argument")
extends Control

# UI References
@onready var npc_list: ItemList = $HSplit/LeftPanel/VBox/NPCList
@onready var search_edit: LineEdit = $HSplit/LeftPanel/VBox/SearchEdit
@onready var filter_npcs_btn: CheckBox = $HSplit/LeftPanel/VBox/FilterRow/FilterNPCs
@onready var filter_creatures_btn: CheckBox = $HSplit/LeftPanel/VBox/FilterRow/FilterCreatures
@onready var viewport_container: SubViewportContainer = $HSplit/RightPanel/VBox/ViewportContainer
@onready var viewport: SubViewport = $HSplit/RightPanel/VBox/ViewportContainer/Viewport
@onready var tab_container: TabContainer = $HSplit/RightPanel/VBox/TabContainer
@onready var info_label: RichTextLabel = $HSplit/RightPanel/VBox/TabContainer/Info/InfoText
@onready var anim_list: ItemList = $HSplit/RightPanel/VBox/TabContainer/Animations/VBox/AnimList
@onready var play_anim_btn: Button = $HSplit/RightPanel/VBox/TabContainer/Animations/VBox/PlayBtn
@onready var bone_tree: Tree = $HSplit/RightPanel/VBox/TabContainer/Bones/BoneTree
@onready var rotate_slider: HSlider = $HSplit/RightPanel/VBox/ControlPanel/RotateSlider
@onready var zoom_slider: HSlider = $HSplit/RightPanel/VBox/ControlPanel/ZoomSlider
@onready var status_label: Label = $StatusBar/StatusLabel
@onready var load_btn: Button = $HSplit/LeftPanel/VBox/LoadBtn

# 3D Scene elements (created in viewport)
var camera: Camera3D = null
var character_root: Node3D = null
var preview_light: DirectionalLight3D = null
var ground_plane: MeshInstance3D = null

# Managers
var character_factory: CharacterFactoryV2 = null
var model_loader: ModelLoader = null

# State
var _all_npcs: Array[Dictionary] = []  # {id, name, type, record}
var _filtered_npcs: Array[Dictionary] = []
var _current_character: CharacterBody3D = null
var _current_record: Variant = null
var _rotation_angle: float = 0.0
var _zoom_distance: float = 3.0
var _is_initialized: bool = false
var _data_path: String = ""


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	# Setup 3D preview scene
	_setup_preview_scene()

	# Connect UI signals
	search_edit.text_changed.connect(_on_search_changed)
	filter_npcs_btn.toggled.connect(_on_filter_changed)
	filter_creatures_btn.toggled.connect(_on_filter_changed)
	npc_list.item_selected.connect(_on_npc_selected)
	anim_list.item_selected.connect(_on_anim_selected)
	play_anim_btn.pressed.connect(_on_play_animation)
	rotate_slider.value_changed.connect(_on_rotate_changed)
	zoom_slider.value_changed.connect(_on_zoom_changed)
	load_btn.pressed.connect(_on_load_pressed)

	# Set default filter states
	filter_npcs_btn.button_pressed = true
	filter_creatures_btn.button_pressed = true

	# Initialize zoom slider
	zoom_slider.min_value = 1.0
	zoom_slider.max_value = 10.0
	zoom_slider.value = 3.0

	# Initialize rotation slider
	rotate_slider.min_value = 0.0
	rotate_slider.max_value = 360.0
	rotate_slider.value = 0.0

	_set_status("Click 'Load Data' to initialize")


func _setup_preview_scene() -> void:
	# Create camera
	camera = Camera3D.new()
	camera.name = "PreviewCamera"
	camera.position = Vector3(0, 1.5, 3)
	camera.look_at_from_position(camera.position, Vector3(0, 1, 0))
	camera.current = true
	viewport.add_child(camera)

	# Create directional light
	preview_light = DirectionalLight3D.new()
	preview_light.name = "PreviewLight"
	preview_light.position = Vector3(5, 10, 5)
	preview_light.look_at_from_position(preview_light.position, Vector3.ZERO)
	preview_light.light_energy = 1.0
	preview_light.shadow_enabled = true
	viewport.add_child(preview_light)

	# Create ambient light
	var ambient := DirectionalLight3D.new()
	ambient.name = "AmbientFill"
	ambient.position = Vector3(-5, 5, -5)
	ambient.look_at_from_position(ambient.position, Vector3.ZERO)
	ambient.light_energy = 0.3
	viewport.add_child(ambient)

	# Create ground plane
	ground_plane = MeshInstance3D.new()
	ground_plane.name = "Ground"
	var plane_mesh := PlaneMesh.new()
	plane_mesh.size = Vector2(10, 10)
	ground_plane.mesh = plane_mesh
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.3, 0.3, 0.3)
	ground_plane.material_override = ground_mat
	viewport.add_child(ground_plane)

	# Create container for characters
	character_root = Node3D.new()
	character_root.name = "CharacterRoot"
	viewport.add_child(character_root)

	# Configure viewport - disable stretch to allow manual size control
	viewport_container.stretch = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.size = Vector2i(800, 600)


func _on_load_pressed() -> void:
	if _is_initialized:
		_set_status("Already loaded")
		return

	_set_status("Loading data...")
	load_btn.disabled = true

	# Get data path
	_data_path = SettingsManager.get_data_path()
	if _data_path.is_empty():
		_data_path = SettingsManager.auto_detect_installation()
		if _data_path.is_empty():
			_set_status("ERROR: Morrowind not found")
			load_btn.disabled = false
			return

	# Load BSA archives
	_set_status("Loading BSA archives...")
	await get_tree().process_frame
	var bsa_count := BSAManager.load_archives_from_directory(_data_path)
	_set_status("Loaded %d BSA archives" % bsa_count)

	# Load ESM
	_set_status("Loading ESM...")
	await get_tree().process_frame
	var esm_file: String = SettingsManager.get_esm_file()
	var esm_path := _data_path.path_join(esm_file)
	var error := ESMManager.load_file(esm_path)

	if error != OK:
		_set_status("ERROR: Failed to load ESM: %s" % error_string(error))
		load_btn.disabled = false
		return

	# Initialize model loader
	model_loader = ModelLoader.new()

	# Initialize character factory
	character_factory = CharacterFactoryV2.new()
	character_factory.set_model_loader(model_loader)
	character_factory.debug_characters = true
	character_factory.debug_animations = true

	# Load NPC/creature list
	_set_status("Building character list...")
	await get_tree().process_frame
	_load_character_list()

	_is_initialized = true
	load_btn.text = "Loaded"
	_set_status("Ready - %d characters available" % _all_npcs.size())


func _load_character_list() -> void:
	_all_npcs.clear()

	# Load NPCs from ESMManager.npcs dictionary
	for npc_id: String in ESMManager.npcs:
		var npc: NPCRecord = ESMManager.npcs[npc_id]
		if npc:
			_all_npcs.append({
				"id": npc.record_id,
				"name": npc.name if not npc.name.is_empty() else npc.record_id,
				"type": "npc",
				"record": npc
			})

	# Load creatures from ESMManager.creatures dictionary
	for creature_id: String in ESMManager.creatures:
		var creature: CreatureRecord = ESMManager.creatures[creature_id]
		if creature:
			_all_npcs.append({
				"id": creature.record_id,
				"name": creature.name if not creature.name.is_empty() else creature.record_id,
				"type": "creature",
				"record": creature
			})

	# Sort by name
	_all_npcs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["name"]).to_lower() < str(b["name"]).to_lower()
	)

	_update_filtered_list()


func _update_filtered_list() -> void:
	_filtered_npcs.clear()
	var search_term := search_edit.text.to_lower()
	var show_npcs := filter_npcs_btn.button_pressed
	var show_creatures := filter_creatures_btn.button_pressed

	for entry: Dictionary in _all_npcs:
		var entry_type: String = entry["type"]
		# Type filter
		if entry_type == "npc" and not show_npcs:
			continue
		if entry_type == "creature" and not show_creatures:
			continue

		# Search filter
		if not search_term.is_empty():
			var entry_name: String = entry["name"]
			var entry_id: String = entry["id"]
			if search_term not in entry_name.to_lower() and search_term not in entry_id.to_lower():
				continue

		_filtered_npcs.append(entry)

	# Update list UI
	npc_list.clear()
	for entry: Dictionary in _filtered_npcs:
		var display_name: String = entry["name"]
		var entry_type: String = entry["type"]
		var prefix := "[NPC] " if entry_type == "npc" else "[CREA] "
		npc_list.add_item(prefix + display_name)


func _on_search_changed(_text: String) -> void:
	_update_filtered_list()


func _on_filter_changed(_pressed: bool) -> void:
	_update_filtered_list()


func _on_npc_selected(index: int) -> void:
	if index < 0 or index >= _filtered_npcs.size():
		return

	var entry: Dictionary = _filtered_npcs[index]
	_current_record = entry["record"]
	var entry_type: String = entry["type"]

	_set_status("Loading: %s" % entry["name"])

	# Clear previous character
	_clear_current_character()

	# Create new character
	if entry_type == "npc":
		_current_character = character_factory.create_npc(_current_record as NPCRecord, 0)
	else:
		_current_character = character_factory.create_creature(_current_record as CreatureRecord, 0)

	if _current_character:
		character_root.add_child(_current_character)
		_current_character.position = Vector3.ZERO

		# Update UI
		_update_info_panel()
		_update_animation_list()
		_update_bone_tree()

		_set_status("Loaded: %s" % entry["name"])
	else:
		_set_status("Failed to load: %s" % entry["name"])
		_update_info_panel_error(entry)


func _clear_current_character() -> void:
	if _current_character:
		_current_character.queue_free()
		_current_character = null

	anim_list.clear()
	bone_tree.clear()
	info_label.text = ""


func _update_info_panel() -> void:
	if not _current_record:
		return

	var text := "[b]Character Info[/b]\n\n"

	if _current_record is NPCRecord:
		var npc: NPCRecord = _current_record as NPCRecord
		text += "[b]Name:[/b] %s\n" % npc.name
		text += "[b]ID:[/b] %s\n" % npc.record_id
		text += "[b]Race:[/b] %s\n" % npc.race_id
		text += "[b]Class:[/b] %s\n" % npc.class_id
		text += "[b]Faction:[/b] %s\n" % npc.faction_id
		text += "[b]Gender:[/b] %s\n" % ("Female" if npc.is_female() else "Male")
		text += "[b]Level:[/b] %d\n" % npc.level
		text += "[b]Health:[/b] %d\n" % npc.health
		text += "[b]Head:[/b] %s\n" % npc.head_id
		text += "[b]Hair:[/b] %s\n" % npc.hair_id
		text += "\n[b]Essential:[/b] %s\n" % ("Yes" if npc.is_essential() else "No")
		text += "[b]Respawns:[/b] %s\n" % ("Yes" if npc.does_respawn() else "No")

	elif _current_record is CreatureRecord:
		var creature: CreatureRecord = _current_record as CreatureRecord
		text += "[b]Name:[/b] %s\n" % creature.name
		text += "[b]ID:[/b] %s\n" % creature.record_id
		text += "[b]Model:[/b] %s\n" % creature.model
		text += "[b]Type:[/b] %s\n" % _get_creature_type_name(creature.creature_type)
		text += "[b]Level:[/b] %d\n" % creature.level
		text += "[b]Health:[/b] %d\n" % creature.health
		text += "[b]Scale:[/b] %.2f\n" % creature.scale
		text += "[b]Soul:[/b] %d\n" % creature.soul

	info_label.text = text


func _update_info_panel_error(entry: Dictionary) -> void:
	var text := "[b][color=red]Failed to load character[/color][/b]\n\n"
	text += "[b]ID:[/b] %s\n" % entry["id"]
	text += "[b]Name:[/b] %s\n" % entry["name"]
	text += "[b]Type:[/b] %s\n" % entry["type"]

	if _current_record is NPCRecord:
		var npc: NPCRecord = _current_record as NPCRecord
		text += "\n[b]Debug Info:[/b]\n"
		text += "Race: %s\n" % npc.race_id
		text += "Head: %s\n" % npc.head_id
		text += "Hair: %s\n" % npc.hair_id

		# Check if race exists
		var race: RaceRecord = ESMManager.get_race(npc.race_id)
		if race:
			text += "Race found: %s (beast: %s)\n" % [race.name, race.is_beast()]
		else:
			text += "[color=red]Race NOT FOUND[/color]\n"

	info_label.text = text


func _update_animation_list() -> void:
	anim_list.clear()

	if not _current_character:
		return

	# Find AnimationPlayer
	var anim_player := _find_animation_player(_current_character)
	if not anim_player:
		anim_list.add_item("(No animations)")
		return

	var animations := anim_player.get_animation_list()
	for anim_name: String in animations:
		anim_list.add_item(anim_name)

	if animations.is_empty():
		anim_list.add_item("(No animations loaded)")


func _update_bone_tree() -> void:
	bone_tree.clear()

	if not _current_character:
		return

	# Find Skeleton3D
	var skeleton := _find_skeleton(_current_character)
	if not skeleton:
		var placeholder_root: TreeItem = bone_tree.create_item()
		placeholder_root.set_text(0, "(No skeleton)")
		return

	# Build bone hierarchy
	var tree_root: TreeItem = bone_tree.create_item()
	tree_root.set_text(0, "Skeleton (%d bones)" % skeleton.get_bone_count())

	# Find root bones (no parent)
	var bone_items: Dictionary = {}
	for i in skeleton.get_bone_count():
		var parent_idx := skeleton.get_bone_parent(i)
		if parent_idx == -1:
			var item: TreeItem = bone_tree.create_item(tree_root)
			item.set_text(0, skeleton.get_bone_name(i))
			bone_items[i] = item

	# Add child bones (simple approach - might need multiple passes for deep hierarchies)
	for _pass in range(10):  # Max depth of 10
		for i in skeleton.get_bone_count():
			if i in bone_items:
				continue
			var parent_idx := skeleton.get_bone_parent(i)
			if parent_idx in bone_items:
				var parent_item: TreeItem = bone_items[parent_idx]
				var item: TreeItem = bone_tree.create_item(parent_item)
				item.set_text(0, skeleton.get_bone_name(i))
				bone_items[i] = item


func _on_anim_selected(_index: int) -> void:
	pass  # Will play on button press


func _on_play_animation() -> void:
	var selected := anim_list.get_selected_items()
	if selected.is_empty():
		return

	var anim_name := anim_list.get_item_text(selected[0])
	if anim_name.begins_with("("):
		return  # Skip placeholder items

	var anim_player := _find_animation_player(_current_character)
	if anim_player:
		anim_player.play(anim_name)
		_set_status("Playing: %s" % anim_name)


func _on_rotate_changed(value: float) -> void:
	_rotation_angle = deg_to_rad(value)
	if _current_character:
		_current_character.rotation.y = _rotation_angle


func _on_zoom_changed(value: float) -> void:
	_zoom_distance = value
	if camera:
		camera.position.z = _zoom_distance
		camera.look_at(Vector3(0, 1, 0))


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var result := _find_animation_player(child)
		if result:
			return result
	return null


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var result := _find_skeleton(child)
		if result:
			return result
	return null


func _get_creature_type_name(creature_type: int) -> String:
	match creature_type:
		0: return "Creature"
		1: return "Daedra"
		2: return "Undead"
		3: return "Humanoid"
		_: return "Unknown (%d)" % creature_type


func _set_status(text: String) -> void:
	status_label.text = text
	print("NPCViewer: %s" % text)
