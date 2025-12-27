## NPCProvider - Asset provider for NPCs and Creatures from ESM data
##
## Loads and displays assembled Morrowind characters with:
## - NPC and creature browsing
## - Character assembly from body parts
## - Animation playback
## - Skeleton/bone inspection
@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_cast", "unsafe_call_argument")
class_name NPCProvider
extends AssetProvider

# Dependencies
var character_factory: CharacterFactoryV2 = null
var model_loader: ModelLoader = null

# Data
var _all_characters: Array[Dictionary] = []  # {id, name, type, record}
var _data_path: String = ""

# Last loaded item for tabs
var _last_character: CharacterBody3D = null
var _last_record: Variant = null
var _last_item: Dictionary = {}


func _init() -> void:
	provider_name = "NPCs & Creatures"


func initialize() -> Error:
	loading_started.emit()

	# Get data path
	_data_path = SettingsManager.get_data_path()
	if _data_path.is_empty():
		_data_path = SettingsManager.auto_detect_installation()

	if _data_path.is_empty():
		loading_failed.emit("Morrowind data path not found")
		return ERR_FILE_NOT_FOUND

	_log("Loading data from: %s" % _data_path)
	_progress(0, 100, "Loading BSA archives...")

	# Load BSA archives
	var bsa_count := BSAManager.load_archives_from_directory(_data_path)
	_log("Loaded %d BSA archives" % bsa_count)

	_progress(30, 100, "Loading ESM...")

	# Load ESM
	var esm_file := SettingsManager.get_esm_file()
	var esm_path := _data_path.path_join(esm_file)
	var error := ESMManager.load_file(esm_path)

	if error != OK:
		loading_failed.emit("Failed to load ESM: %s" % error_string(error))
		return error

	_progress(60, 100, "Initializing character factory...")

	# Initialize model loader and character factory
	model_loader = ModelLoader.new()
	character_factory = CharacterFactoryV2.new()
	character_factory.set_model_loader(model_loader)
	character_factory.debug_characters = false
	character_factory.debug_animations = false

	_progress(80, 100, "Building character list...")

	# Build character list
	_build_character_list()

	_log("[color=green]Loaded %d characters[/color]" % _all_characters.size())

	loading_completed.emit()
	return OK


func _build_character_list() -> void:
	_all_characters.clear()

	# Load NPCs
	for npc_id: String in ESMManager.npcs:
		var npc: NPCRecord = ESMManager.npcs[npc_id]
		if npc:
			_all_characters.append({
				"id": npc.record_id,
				"name": npc.name if not npc.name.is_empty() else npc.record_id,
				"type": "npc",
				"category": "npcs",
				"record": npc,
				"tooltip": "NPC: %s (%s)" % [npc.name, npc.race_id]
			})

	# Load Creatures
	for creature_id: String in ESMManager.creatures:
		var creature: CreatureRecord = ESMManager.creatures[creature_id]
		if creature:
			_all_characters.append({
				"id": creature.record_id,
				"name": creature.name if not creature.name.is_empty() else creature.record_id,
				"type": "creature",
				"category": "creatures",
				"record": creature,
				"tooltip": "Creature: %s" % creature.name
			})

	# Sort by name
	_all_characters.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["name"]).to_lower() < str(b["name"]).to_lower()
	)


func is_ready() -> bool:
	return character_factory != null and not _all_characters.is_empty()


func get_categories() -> Array[String]:
	return ["npcs", "creatures"]


func get_items() -> Array[Dictionary]:
	return _all_characters


func load_item(item: Dictionary) -> Node3D:
	var record = item.get("record")
	var item_type: String = item.get("type", "")

	if record == null:
		_log("[color=red]Error: No record in item[/color]")
		return null

	_log("Loading: %s" % item.get("name", "Unknown"))

	var character: CharacterBody3D = null

	if item_type == "npc":
		character = character_factory.create_npc(record as NPCRecord, 0)
	elif item_type == "creature":
		character = character_factory.create_creature(record as CreatureRecord, 0)

	if character == null:
		_log("[color=red]Error: Failed to create character[/color]")
		return null

	# Store for tabs
	_last_character = character
	_last_record = record
	_last_item = item

	# Auto-play an idle animation to prevent falling through ground
	_auto_play_idle_animation(character)

	_log("[color=green]Successfully loaded character![/color]")

	item_loaded.emit(character, {"type": item_type, "record": record})
	return character


func get_info_text(item: Dictionary) -> String:
	var record = item.get("record")
	if record == null:
		return "[b]No record data[/b]"

	var text := "[b]Character Info[/b]\n\n"

	if record is NPCRecord:
		var npc: NPCRecord = record as NPCRecord
		text += "[b]Name:[/b] %s\n" % npc.name
		text += "[b]ID:[/b] %s\n" % npc.record_id
		text += "[b]Race:[/b] %s\n" % npc.race_id
		text += "[b]Class:[/b] %s\n" % npc.class_id
		text += "[b]Faction:[/b] %s\n" % npc.faction_id
		text += "[b]Gender:[/b] %s\n" % ("Female" if npc.is_female() else "Male")
		text += "[b]Level:[/b] %d\n" % npc.level
		text += "[b]Health:[/b] %d\n" % npc.health
		text += "\n[b]Body Parts:[/b]\n"
		text += "  Head: %s\n" % npc.head_id
		text += "  Hair: %s\n" % npc.hair_id
		text += "\n[b]Flags:[/b]\n"
		text += "  Essential: %s\n" % ("Yes" if npc.is_essential() else "No")
		text += "  Respawns: %s\n" % ("Yes" if npc.does_respawn() else "No")

	elif record is CreatureRecord:
		var creature: CreatureRecord = record as CreatureRecord
		text += "[b]Name:[/b] %s\n" % creature.name
		text += "[b]ID:[/b] %s\n" % creature.record_id
		text += "[b]Model:[/b] %s\n" % creature.model
		text += "[b]Type:[/b] %s\n" % _get_creature_type_name(creature.creature_type)
		text += "[b]Level:[/b] %d\n" % creature.level
		text += "[b]Health:[/b] %d\n" % creature.health
		text += "[b]Scale:[/b] %.2f\n" % creature.scale
		text += "[b]Soul:[/b] %d\n" % creature.soul

	return text


func get_custom_tabs() -> Array[Dictionary]:
	return [
		{"name": "Animations", "build_func": _build_animations_tab},
		{"name": "Bones", "build_func": _build_bones_tab},
	]


func _build_animations_tab(container: Control, _item: Dictionary) -> void:
	var vbox := VBoxContainer.new()
	container.add_child(vbox)
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 8
	vbox.offset_top = 8
	vbox.offset_right = -8
	vbox.offset_bottom = -8

	var anim_list := ItemList.new()
	anim_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(anim_list)

	var play_btn := Button.new()
	play_btn.text = "Play Animation"
	vbox.add_child(play_btn)

	# Populate animations
	if _last_character:
		var anim_player := _find_animation_player(_last_character)
		if anim_player:
			var animations := anim_player.get_animation_list()
			for anim_name: String in animations:
				anim_list.add_item(anim_name)

			play_btn.pressed.connect(func() -> void:
				var selected := anim_list.get_selected_items()
				if not selected.is_empty():
					var name_to_play: String = anim_list.get_item_text(selected[0])
					anim_player.play(name_to_play)
					_log("Playing: %s" % name_to_play)
			)

	if anim_list.item_count == 0:
		anim_list.add_item("(No animations loaded)")
		play_btn.disabled = true


func _build_bones_tab(container: Control, _item: Dictionary) -> void:
	var bone_tree := Tree.new()
	container.add_child(bone_tree)
	bone_tree.set_anchors_preset(Control.PRESET_FULL_RECT)
	bone_tree.offset_left = 8
	bone_tree.offset_top = 8
	bone_tree.offset_right = -8
	bone_tree.offset_bottom = -8

	if not _last_character:
		var root: TreeItem = bone_tree.create_item()
		root.set_text(0, "(No character loaded)")
		return

	var skeleton := _find_skeleton(_last_character)
	if not skeleton:
		var root: TreeItem = bone_tree.create_item()
		root.set_text(0, "(No skeleton)")
		return

	# Build bone hierarchy
	var tree_root: TreeItem = bone_tree.create_item()
	tree_root.set_text(0, "Skeleton (%d bones)" % skeleton.get_bone_count())

	var bone_items: Dictionary = {}

	# Find root bones (no parent)
	for i in skeleton.get_bone_count():
		var parent_idx := skeleton.get_bone_parent(i)
		if parent_idx == -1:
			var item: TreeItem = bone_tree.create_item(tree_root)
			item.set_text(0, skeleton.get_bone_name(i))
			bone_items[i] = item

	# Add child bones (multiple passes for deep hierarchies)
	for _pass in range(15):
		for i in skeleton.get_bone_count():
			if i in bone_items:
				continue
			var parent_idx := skeleton.get_bone_parent(i)
			if parent_idx in bone_items:
				var parent_item: TreeItem = bone_items[parent_idx]
				var item: TreeItem = bone_tree.create_item(parent_item)
				item.set_text(0, skeleton.get_bone_name(i))
				bone_items[i] = item


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var result := _find_animation_player(child)
		if result:
			return result
	return null


## Auto-play an idle animation to keep character in T-pose/idle instead of falling
func _auto_play_idle_animation(character: Node) -> void:
	var anim_player := _find_animation_player(character)
	if not anim_player:
		_log("[color=yellow]No AnimationPlayer found for idle animation[/color]")
		return

	var animations := anim_player.get_animation_list()
	if animations.is_empty():
		_log("[color=yellow]No animations available[/color]")
		return

	# Priority order for idle animations
	var idle_candidates: Array[String] = ["Idle", "idle", "IDLE"]

	# First try exact matches
	for candidate in idle_candidates:
		if candidate in animations:
			anim_player.play(candidate)
			_log("Auto-playing animation: %s" % candidate)
			return

	# Then try partial matches
	for anim_name: String in animations:
		if "idle" in anim_name.to_lower():
			anim_player.play(anim_name)
			_log("Auto-playing animation: %s" % anim_name)
			return

	# Fallback: play any animation (better than nothing)
	var first_anim: String = animations[0]
	anim_player.play(first_anim)
	_log("Auto-playing fallback animation: %s" % first_anim)


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


func cleanup() -> void:
	_all_characters.clear()
	_last_character = null
	_last_record = null
	character_factory = null
	model_loader = null
