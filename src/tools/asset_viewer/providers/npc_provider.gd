## NPCProvider - Asset provider for NPCs and Creatures from ESM data
##
## Loads and displays assembled Morrowind characters with:
## - NPC and creature browsing
## - Character assembly from body parts
## - Animation playback
## - Skeleton/bone inspection
## - Humanoid profile skeleton for modern animation features
@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_cast", "unsafe_call_argument")
class_name NPCProvider
extends AssetProvider

# Dependencies
const CharacterFactoryV2 := preload("res://src/core/animation/character_factory_v2.gd")
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

	# Check if BSA archives are already loaded (by another provider or tool)
	if BSAManager.get_archive_count() == 0:
		_progress(0, 100, "Loading BSA archives...")
		var bsa_count := BSAManager.load_archives_from_directory(_data_path)
		_log("Loaded %d BSA archives" % bsa_count)
	else:
		_log("BSA archives already loaded (%d)" % BSAManager.get_archive_count())

	# Check if ESM is already loaded
	if ESMManager.npcs.is_empty():
		_progress(30, 100, "Loading ESM...")
		var esm_file := SettingsManager.get_esm_file()
		var esm_path := _data_path.path_join(esm_file)
		var error := ESMManager.load_file(esm_path)

		if error != OK:
			loading_failed.emit("Failed to load ESM: %s" % error_string(error))
			return error
	else:
		_log("ESM already loaded (%d NPCs)" % ESMManager.npcs.size())

	_progress(70, 100, "Initializing character factory...")

	# Initialize model loader
	model_loader = ModelLoader.new()

	# Initialize character factory (uses humanoid profile skeleton)
	character_factory = CharacterFactoryV2.new()
	character_factory.debug_characters = true
	_log("CharacterFactoryV2 initialized")

	_progress(85, 100, "Building character list...")

	# Build character list (fast - just iterating existing dictionaries)
	_build_character_list()

	_log("[color=green]Loaded %d characters[/color]" % _all_characters.size())

	# Note: Skeleton and animation preloading is now done lazily on first NPC load
	# This makes the initial list loading much faster

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

	var start_time := Time.get_ticks_msec()
	var character: CharacterBody3D = null

	if item_type == "npc":
		var npc_rec := record as NPCRecord
		character = character_factory.create_npc(npc_rec)
		if character == null:
			_log("[color=red]Error: Failed to create NPC[/color]")
			return null
	elif item_type == "creature":
		var creature_rec := record as CreatureRecord
		character = character_factory.create_creature(creature_rec)
		if character == null:
			_log("[color=red]Error: Failed to create creature[/color]")
			return null

	var load_time := Time.get_ticks_msec() - start_time
	_log("[color=yellow]Character creation took %d ms[/color]" % load_time)

	if character == null:
		_log("[color=red]Error: Failed to create character[/color]")
		return null

	# Store for tabs
	_last_character = character
	_last_record = record
	_last_item = item

	# Disable physics processing for asset viewer (prevents falling through ground)
	character.set_physics_process(false)
	character.set_process(false)

	# Auto-play an idle animation
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
		{"name": "Settings", "build_func": _build_settings_tab},
		{"name": "Animations", "build_func": _build_animations_tab},
		{"name": "Bones", "build_func": _build_bones_tab},
	]


func _build_settings_tab(container: Control, _item: Dictionary) -> void:
	var vbox := VBoxContainer.new()
	container.add_child(vbox)
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 8
	vbox.offset_top = 8
	vbox.offset_right = -8
	vbox.offset_bottom = -8

	# Title
	var title := Label.new()
	title.text = "Character System Info"
	title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(title)

	vbox.add_child(HSeparator.new())

	var desc := Label.new()
	desc.text = "Using humanoid profile skeleton for:\n• AnimationTree support\n• Inverse Kinematics (IK)\n• Motion matching\n• GLB/FBX animation libraries (e.g. Quaternius)"
	desc.add_theme_font_size_override("font_size", 12)
	vbox.add_child(desc)

	vbox.add_child(HSeparator.new())

	# Status info
	var status_label := Label.new()
	if _last_character and _last_character.has_meta("uses_new_animation_system"):
		status_label.text = "Current character: humanoid skeleton + animation system"
	else:
		status_label.text = "Current character: None loaded"
	vbox.add_child(status_label)


func _build_animations_tab(container: Control, _item: Dictionary) -> void:
	var vbox := VBoxContainer.new()
	container.add_child(vbox)
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 8
	vbox.offset_top = 8
	vbox.offset_right = -8
	vbox.offset_bottom = -8

	# Info label
	var info_label := Label.new()
	info_label.add_theme_font_size_override("font_size", 11)
	vbox.add_child(info_label)

	var anim_list := ItemList.new()
	anim_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(anim_list)

	# Button row
	var btn_row := HBoxContainer.new()
	vbox.add_child(btn_row)

	var play_btn := Button.new()
	play_btn.text = "Play"
	play_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_child(play_btn)

	var stop_btn := Button.new()
	stop_btn.text = "Stop"
	btn_row.add_child(stop_btn)

	# Populate animations
	var anim_player: AnimationPlayer = null
	if _last_character:
		anim_player = _find_animation_player(_last_character)
		if anim_player:
			# Get all animation libraries
			var lib_names := anim_player.get_animation_library_list()
			var total_anims := 0

			for lib_name in lib_names:
				var library := anim_player.get_animation_library(lib_name)
				if library:
					var lib_label: String = lib_name if lib_name else "(default)"
					for anim_name in library.get_animation_list():
						var full_name: String = "%s/%s" % [lib_name, anim_name] if lib_name else anim_name
						var display := "[%s] %s" % [lib_label, anim_name]
						anim_list.add_item(display)
						anim_list.set_item_metadata(anim_list.item_count - 1, full_name)
						total_anims += 1

			info_label.text = "%d animations from %d libraries" % [total_anims, lib_names.size()]

			play_btn.pressed.connect(func() -> void:
				var selected := anim_list.get_selected_items()
				if not selected.is_empty():
					var full_name: String = anim_list.get_item_metadata(selected[0])
					anim_player.play(full_name)
					_log("Playing: %s" % full_name)
			)

			stop_btn.pressed.connect(func() -> void:
				anim_player.stop()
				_log("Animation stopped")
			)

	if anim_list.item_count == 0:
		anim_list.add_item("(No animations loaded)")
		info_label.text = "No animations - add GLB files to assets/characters/quaternius/"
		play_btn.disabled = true
		stop_btn.disabled = true


func _build_bones_tab(container: Control, _item: Dictionary) -> void:
	var vbox := VBoxContainer.new()
	container.add_child(vbox)
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 8
	vbox.offset_top = 8
	vbox.offset_right = -8
	vbox.offset_bottom = -8

	# Controls row
	var controls := HBoxContainer.new()
	vbox.add_child(controls)

	var show_skeleton_btn := CheckButton.new()
	show_skeleton_btn.text = "Show Skeleton"
	show_skeleton_btn.button_pressed = false
	controls.add_child(show_skeleton_btn)

	var bone_size_label := Label.new()
	bone_size_label.text = "  Size:"
	controls.add_child(bone_size_label)

	var bone_size_slider := HSlider.new()
	bone_size_slider.min_value = 0.001
	bone_size_slider.max_value = 0.05
	bone_size_slider.step = 0.001
	bone_size_slider.value = 0.01
	bone_size_slider.custom_minimum_size.x = 100
	controls.add_child(bone_size_slider)

	# Bone tree
	var bone_tree := Tree.new()
	bone_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(bone_tree)

	if not _last_character:
		var root: TreeItem = bone_tree.create_item()
		root.set_text(0, "(No character loaded)")
		return

	var skeleton := _find_skeleton(_last_character)
	if not skeleton:
		var root: TreeItem = bone_tree.create_item()
		root.set_text(0, "(No skeleton)")
		return

	# Create skeleton visualizer
	var visualizer: Node3D = null

	show_skeleton_btn.toggled.connect(func(pressed: bool) -> void:
		if pressed:
			visualizer = _create_skeleton_visualizer(skeleton, bone_size_slider.value)
			if visualizer:
				skeleton.add_child(visualizer)
				_log("Skeleton visualization enabled")
		else:
			if visualizer and is_instance_valid(visualizer):
				visualizer.queue_free()
				visualizer = null
				_log("Skeleton visualization disabled")
	)

	bone_size_slider.value_changed.connect(func(value: float) -> void:
		if show_skeleton_btn.button_pressed and visualizer and is_instance_valid(visualizer):
			visualizer.queue_free()
			visualizer = _create_skeleton_visualizer(skeleton, value)
			if visualizer:
				skeleton.add_child(visualizer)
	)

	# Build bone hierarchy tree
	var tree_root: TreeItem = bone_tree.create_item()
	tree_root.set_text(0, "Skeleton (%d bones)" % skeleton.get_bone_count())

	var bone_items: Dictionary = {}

	# Find root bones (no parent)
	for i in skeleton.get_bone_count():
		var parent_idx := skeleton.get_bone_parent(i)
		if parent_idx == -1:
			var item: TreeItem = bone_tree.create_item(tree_root)
			var rest := skeleton.get_bone_rest(i)
			item.set_text(0, "%s [pos: %.2f, %.2f, %.2f]" % [
				skeleton.get_bone_name(i), rest.origin.x, rest.origin.y, rest.origin.z
			])
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
				var rest := skeleton.get_bone_rest(i)
				item.set_text(0, "%s [pos: %.2f, %.2f, %.2f]" % [
					skeleton.get_bone_name(i), rest.origin.x, rest.origin.y, rest.origin.z
				])
				bone_items[i] = item


## Create a visual representation of the skeleton using spheres and cylinders
func _create_skeleton_visualizer(skeleton: Skeleton3D, bone_size: float) -> Node3D:
	var root := Node3D.new()
	root.name = "SkeletonVisualizer"

	# Create materials
	var bone_mat := StandardMaterial3D.new()
	bone_mat.albedo_color = Color(1.0, 0.3, 0.3, 0.8)  # Red for bones
	bone_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bone_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var joint_mat := StandardMaterial3D.new()
	joint_mat.albedo_color = Color(0.3, 1.0, 0.3, 0.9)  # Green for joints
	joint_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	joint_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	# Create sphere mesh for joints
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = bone_size
	sphere_mesh.height = bone_size * 2

	# Create cylinder mesh for bones (will be scaled per-bone)
	var cylinder_mesh := CylinderMesh.new()
	cylinder_mesh.top_radius = bone_size * 0.5
	cylinder_mesh.bottom_radius = bone_size * 0.5
	cylinder_mesh.height = 1.0  # Will be scaled

	for i in skeleton.get_bone_count():
		var bone_name := skeleton.get_bone_name(i)
		var global_pose := skeleton.get_bone_global_pose(i)
		var bone_pos := global_pose.origin

		# Create joint sphere at bone position
		var joint := MeshInstance3D.new()
		joint.name = "Joint_%s" % bone_name
		joint.mesh = sphere_mesh
		joint.material_override = joint_mat
		joint.position = bone_pos
		root.add_child(joint)

		# Create bone cylinder to parent
		var parent_idx := skeleton.get_bone_parent(i)
		if parent_idx >= 0:
			var parent_pose := skeleton.get_bone_global_pose(parent_idx)
			var parent_pos := parent_pose.origin
			var direction := bone_pos - parent_pos
			var length := direction.length()

			if length > 0.001:
				var bone_vis := MeshInstance3D.new()
				bone_vis.name = "Bone_%s" % bone_name
				bone_vis.mesh = cylinder_mesh
				bone_vis.material_override = bone_mat

				# Position at midpoint
				bone_vis.position = (bone_pos + parent_pos) / 2.0

				# Scale to bone length
				bone_vis.scale = Vector3(1, length, 1)

				# Rotate to point from parent to child using look_at_from_position
				# (can't use look_at() since node isn't in tree yet)
				var up := Vector3.UP
				if abs(direction.normalized().dot(up)) > 0.99:
					up = Vector3.FORWARD
				bone_vis.look_at_from_position(bone_vis.position, bone_vis.position + direction, up)
				bone_vis.rotate_object_local(Vector3.RIGHT, PI / 2)

				root.add_child(bone_vis)

	return root


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
	if character_factory:
		_log("CharacterFactory stats: %s" % str(CharacterFactoryV2.get_cache_stats()))

	_all_characters.clear()
	_last_character = null
	_last_record = null
	character_factory = null
	model_loader = null
