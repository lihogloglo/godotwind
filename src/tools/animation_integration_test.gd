## Animation Integration Test — Side-by-side Morrowind vs Mixamo animation browser
##
## Two clickable lists: MW animations on the left, Mixamo on the right.
## Click any animation to play it immediately on the NPC.
## NPC selector dropdown at the top.
@tool
extends Node3D

@warning_ignore("untyped_declaration", "unsafe_method_access")

const CharacterFactoryV2Script := preload("res://src/core/animation/character_factory_v2.gd")
const AnimationLoaderScript := preload("res://src/core/animation/animation_loader.gd")
const TestNPCLoaderScript := preload("res://tests/test_npc_loader.gd")

# Test NPC record IDs
const TEST_NPCS := ["fargoth", "arrille", "sellus gravius"]
const TEST_NPC_LABELS := ["Fargoth (Wood Elf)", "Arrille (Altmer)", "Sellus Gravius (Imperial)"]
var _current_npc_index: int = 0

# Scene
var _npc_node: Node = null
var _camera: Camera3D = null
var _factory: CharacterFactoryV2Script = null

# Data loading state
var _data_loaded: bool = false
var _factory_ready: bool = false

# Mixamo
var _mixamo_library: AnimationLibrary = null
var _mixamo_source_rest: Dictionary = {}
var _mixamo_loaded: bool = false

# Cached MW library (so we can swap back after playing Mixamo)
var _mw_library: AnimationLibrary = null

# UI elements
var _npc_selector: OptionButton = null
var _mw_list: ItemList = null
var _mixamo_list: ItemList = null
var _mw_header: Label = null
var _mixamo_header: Label = null
var _status_label: Label = null

# IK toggles (separate for each feature)
var _foot_ik_toggle: CheckButton = null
var _look_ik_toggle: CheckButton = null
var _hand_ik_toggle: CheckButton = null
var _foot_ik_enabled: bool = true
var _look_ik_enabled: bool = false
var _hand_ik_enabled: bool = false

# IK target visuals
var _look_orb: MeshInstance3D = null
var _left_hand_sphere: MeshInstance3D = null
var _right_hand_sphere: MeshInstance3D = null
var _ik_time: float = 0.0

# Animation system reference (cached after NPC spawn)
var _anim_system: Node = null

# IK test cubes — scroll past the character to create uneven ground
var _cube_container: Node3D = null
const CUBE_COUNT := 12
const CUBE_SCROLL_SPEED := 0.4  # m/s
const CUBE_SPREAD_X := 1.6  # how wide the cube field is
const CUBE_SPREAD_Z := 6.0  # how deep the field extends (front to back)
const CUBE_WRAP_Z := 3.0  # cubes wrap when they pass this far behind character


func _ready() -> void:
	_setup_scene()
	_setup_ui()

	await get_tree().process_frame
	await get_tree().process_frame

	_spawn_npc()

	if "--autotest" in OS.get_cmdline_user_args():
		_run_auto_test()


# =============================================================================
# UI SETUP
# =============================================================================

func _setup_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "UI"
	add_child(canvas)

	# Main container anchored to right side of screen
	var panel := PanelContainer.new()
	panel.name = "AnimPanel"
	panel.anchor_left = 0.55
	panel.anchor_top = 0.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = 0
	panel.offset_top = 0
	panel.offset_right = 0
	panel.offset_bottom = 0

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.1, 0.9)
	style.content_margin_left = 8
	style.content_margin_top = 8
	style.content_margin_right = 8
	style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)

	# --- Top bar: NPC selector ---
	var top_bar := HBoxContainer.new()
	top_bar.add_theme_constant_override("separation", 8)

	var npc_label := Label.new()
	npc_label.text = "NPC:"
	top_bar.add_child(npc_label)

	_npc_selector = OptionButton.new()
	_npc_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for label in TEST_NPC_LABELS:
		_npc_selector.add_item(label)
	_npc_selector.selected = _current_npc_index
	_npc_selector.item_selected.connect(_on_npc_selected)
	top_bar.add_child(_npc_selector)

	vbox.add_child(top_bar)

	# --- IK toggle row ---
	var ik_row := HBoxContainer.new()
	ik_row.add_theme_constant_override("separation", 6)

	var ik_label := Label.new()
	ik_label.text = "IK:"
	ik_row.add_child(ik_label)

	_foot_ik_toggle = CheckButton.new()
	_foot_ik_toggle.text = "Foot"
	_foot_ik_toggle.button_pressed = _foot_ik_enabled
	_foot_ik_toggle.toggled.connect(_on_foot_ik_toggled)
	ik_row.add_child(_foot_ik_toggle)

	_look_ik_toggle = CheckButton.new()
	_look_ik_toggle.text = "Look"
	_look_ik_toggle.button_pressed = _look_ik_enabled
	_look_ik_toggle.toggled.connect(_on_look_ik_toggled)
	ik_row.add_child(_look_ik_toggle)

	_hand_ik_toggle = CheckButton.new()
	_hand_ik_toggle.text = "Hands"
	_hand_ik_toggle.button_pressed = _hand_ik_enabled
	_hand_ik_toggle.toggled.connect(_on_hand_ik_toggled)
	ik_row.add_child(_hand_ik_toggle)

	vbox.add_child(ik_row)

	# --- Separator ---
	vbox.add_child(HSeparator.new())

	# --- Two-column animation lists ---
	var columns := HSplitContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.split_offset = 0  # Even split

	# Left column: Morrowind
	var left_col := VBoxContainer.new()
	left_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_col.add_theme_constant_override("separation", 4)

	_mw_header = Label.new()
	_mw_header.text = "Morrowind (0)"
	_mw_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	left_col.add_child(_mw_header)

	_mw_list = ItemList.new()
	_mw_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_mw_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mw_list.item_selected.connect(_on_mw_anim_selected)
	_mw_list.allow_reselect = true
	left_col.add_child(_mw_list)

	columns.add_child(left_col)

	# Right column: Mixamo
	var right_col := VBoxContainer.new()
	right_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_col.add_theme_constant_override("separation", 4)

	_mixamo_header = Label.new()
	_mixamo_header.text = "Mixamo (click to load)"
	_mixamo_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	right_col.add_child(_mixamo_header)

	_mixamo_list = ItemList.new()
	_mixamo_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_mixamo_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mixamo_list.item_selected.connect(_on_mixamo_anim_selected)
	_mixamo_list.allow_reselect = true
	# Placeholder item prompting user to click
	_mixamo_list.add_item("[ Click to load Mixamo ]")
	right_col.add_child(_mixamo_list)

	columns.add_child(right_col)
	vbox.add_child(columns)

	# --- Bottom status bar ---
	vbox.add_child(HSeparator.new())

	_status_label = Label.new()
	_status_label.text = "Loading..."
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_color_override("font_color", Color(0.7, 0.8, 1.0))
	vbox.add_child(_status_label)

	panel.add_child(vbox)
	canvas.add_child(panel)


# =============================================================================
# LIST CLICK HANDLERS
# =============================================================================

func _on_npc_selected(index: int) -> void:
	if index == _current_npc_index:
		return
	_current_npc_index = index
	# Reset Mixamo (skeleton rest poses differ per NPC)
	_mixamo_library = null
	_mixamo_loaded = false
	_mw_library = null
	_mixamo_list.clear()
	_mixamo_list.add_item("[ Click to load Mixamo ]")
	_mixamo_header.text = "Mixamo (click to load)"
	_spawn_npc()


func _on_foot_ik_toggled(enabled: bool) -> void:
	_foot_ik_enabled = enabled
	if _anim_system and _anim_system.has_method("set_foot_ik_enabled"):
		_anim_system.set_foot_ik_enabled(enabled)
	_status_label.text = "Foot IK %s" % ("ON" if enabled else "OFF")


func _on_look_ik_toggled(enabled: bool) -> void:
	_look_ik_enabled = enabled
	if not _npc_node or not _anim_system:
		return
	if enabled:
		_create_look_orb_if_needed()
		if _anim_system.has_method("set_look_target"):
			_anim_system.set_look_target(_look_orb)
	else:
		if _anim_system.has_method("clear_look_target"):
			_anim_system.clear_look_target()
	_status_label.text = "Look-at IK %s" % ("ON" if enabled else "OFF")


func _on_hand_ik_toggled(enabled: bool) -> void:
	_hand_ik_enabled = enabled
	if not _npc_node or not _anim_system:
		return
	if enabled:
		_create_hand_spheres_if_needed()
		if _anim_system.has_method("set_hand_target"):
			_anim_system.set_hand_target(&"left", _left_hand_sphere, 1.0)
			_anim_system.set_hand_target(&"right", _right_hand_sphere, 1.0)
	else:
		if _anim_system.has_method("clear_hand_target"):
			_anim_system.clear_hand_target(&"left")
			_anim_system.clear_hand_target(&"right")
	_status_label.text = "Hand IK %s" % ("ON" if enabled else "OFF")


func _collect_nodes_of_class(node: Node, class_name_str: String, results: Array) -> void:
	if node.is_class(class_name_str):
		results.append(node)
	for child in node.get_children():
		_collect_nodes_of_class(child, class_name_str, results)


func _on_mw_anim_selected(index: int) -> void:
	if not _npc_node:
		return
	var anim_name: String = _mw_list.get_item_metadata(index)
	_ensure_mw_active()
	_play_animation(anim_name)
	# Deselect the other list
	_mixamo_list.deselect_all()
	_status_label.text = "Playing: %s (MW)" % anim_name


func _on_mixamo_anim_selected(index: int) -> void:
	if not _npc_node:
		return

	# If Mixamo not loaded yet, load it now
	if not _mixamo_loaded:
		_status_label.text = "Loading Mixamo animations..."
		# Defer so the label updates before blocking load
		await get_tree().process_frame
		_load_mixamo()
		if not _mixamo_loaded:
			_status_label.text = "Failed to load Mixamo"
			return
		# After loading, the list was repopulated — don't play the placeholder
		return

	var anim_name: String = _mixamo_list.get_item_metadata(index)
	_ensure_mixamo_active()
	_play_animation(anim_name)
	# Deselect the other list
	_mw_list.deselect_all()
	_status_label.text = "Playing: %s (Mixamo)" % anim_name


# =============================================================================
# ANIMATION PLAYBACK
# =============================================================================

func _play_animation(anim_name: String) -> void:
	var anim_player: AnimationPlayer = _find_node_of_type(_npc_node, "AnimationPlayer")
	if not anim_player:
		print("[AnimTest] No AnimationPlayer found!")
		_status_label.text = "ERROR: No AnimationPlayer"
		return

	# Disable ALL AnimationTrees for direct control (prebaked NPCs may have leftover ones)
	var anim_trees := []
	_collect_nodes_of_class(_npc_node, "AnimationTree", anim_trees)
	for at: Node in anim_trees:
		at.active = false

	# Disable wander
	if "wander_enabled" in _npc_node:
		_npc_node.wander_enabled = false

	# Check animation exists
	if not anim_player.has_animation(anim_name):
		print("[AnimTest] Animation '%s' not found! Available: %s" % [
			anim_name, ", ".join(anim_player.get_animation_list())])
		_status_label.text = "ERROR: Animation '%s' not found" % anim_name
		return

	# Force loop on locomotion anims
	var anim: Animation = anim_player.get_animation(anim_name)
	if anim and anim.loop_mode == Animation.LOOP_NONE:
		var lower := anim_name.to_lower()
		if "idle" in lower or "walk" in lower or "run" in lower or "swim" in lower:
			anim.loop_mode = Animation.LOOP_LINEAR

	anim_player.speed_scale = 1.0
	anim_player.play(anim_name)
	print("[AnimTest] Playing '%s' (tracks: %d, length: %.1fs)" % [
		anim_name, anim.get_track_count() if anim else 0, anim.length if anim else 0.0])


func _ensure_mw_active() -> void:
	var anim_player: AnimationPlayer = _find_node_of_type(_npc_node, "AnimationPlayer")
	if not anim_player:
		return
	# If MW library is stashed under "morrowind" name, restore it
	if anim_player.has_animation_library("morrowind"):
		var mw_lib := anim_player.get_animation_library("morrowind")
		anim_player.remove_animation_library("morrowind")
		if anim_player.has_animation_library(""):
			anim_player.remove_animation_library("")
		anim_player.add_animation_library("", mw_lib)


func _ensure_mixamo_active() -> void:
	if not _mixamo_library:
		return
	var anim_player: AnimationPlayer = _find_node_of_type(_npc_node, "AnimationPlayer")
	if not anim_player:
		return
	# Stash MW library, put Mixamo as default
	if anim_player.has_animation_library("") and not anim_player.has_animation_library("morrowind"):
		var mw_lib := anim_player.get_animation_library("")
		anim_player.remove_animation_library("")
		anim_player.add_animation_library("morrowind", mw_lib)
	if anim_player.has_animation_library(""):
		anim_player.remove_animation_library("")
	anim_player.add_animation_library("", _mixamo_library)


# =============================================================================
# MIXAMO LOADING
# =============================================================================

func _load_mixamo() -> void:
	if _mixamo_loaded:
		return

	var result := AnimationLoaderScript.load_from_directory_with_rest("res://assets/animations/mixamo/")
	if not result.has("library") or not result["library"]:
		print("[AnimTest] No Mixamo animations found in res://assets/animations/mixamo/")
		return

	var raw_library: AnimationLibrary = result["library"]
	_mixamo_source_rest = result.get("source_rest", {})

	if _mixamo_source_rest.is_empty():
		# No skeleton data — use raw animations without retargeting
		_mixamo_library = raw_library
	else:
		# Retarget to MW skeleton
		var skeleton: Skeleton3D = _find_node_of_type(_npc_node, "Skeleton3D") if _npc_node else null
		if not skeleton:
			_mixamo_library = raw_library
		else:
			var target_rest := AnimationLoaderScript.get_skeleton_rest_poses(skeleton)
			var anim_rest := AnimationLoaderScript.extract_anim_rest_poses(raw_library, _mixamo_source_rest)
			_mixamo_library = AnimationLoaderScript.retarget_library(
				raw_library, anim_rest, target_rest, true)

	_mixamo_loaded = true
	_populate_mixamo_list()


# =============================================================================
# LIST POPULATION
# =============================================================================

func _populate_mw_list() -> void:
	_mw_list.clear()
	if not _npc_node:
		_mw_header.text = "Morrowind (0)"
		print("[AnimTest] _populate_mw_list: _npc_node is null")
		return

	var anim_player: AnimationPlayer = _find_node_of_type(_npc_node, "AnimationPlayer")
	if not anim_player:
		_mw_header.text = "Morrowind (0)"
		print("[AnimTest] _populate_mw_list: No AnimationPlayer found in tree")
		return

	var names: PackedStringArray = PackedStringArray()
	for anim_name in anim_player.get_animation_list():
		names.append(anim_name)
	names.sort()

	for anim_name in names:
		var anim: Animation = anim_player.get_animation(anim_name)
		var duration := anim.length if anim else 0.0
		var idx := _mw_list.add_item("%s  (%.1fs)" % [anim_name, duration])
		_mw_list.set_item_metadata(idx, anim_name)

	_mw_header.text = "Morrowind (%d)" % names.size()
	print("[AnimTest] MW list populated: %d animations" % names.size())


func _populate_mixamo_list() -> void:
	_mixamo_list.clear()
	if not _mixamo_library:
		_mixamo_list.add_item("[ Click to load Mixamo ]")
		_mixamo_header.text = "Mixamo (click to load)"
		return

	var names: PackedStringArray = PackedStringArray()
	for anim_name in _mixamo_library.get_animation_list():
		names.append(anim_name)
	names.sort()

	for anim_name in names:
		var anim: Animation = _mixamo_library.get_animation(anim_name)
		var duration := anim.length if anim else 0.0
		var idx := _mixamo_list.add_item("%s  (%.1fs)" % [anim_name, duration])
		_mixamo_list.set_item_metadata(idx, anim_name)

	_mixamo_header.text = "Mixamo (%d)" % names.size()


# =============================================================================
# NPC SPAWNING (unchanged core logic)
# =============================================================================

func _spawn_npc() -> void:
	if _npc_node:
		_npc_node.queue_free()
		_npc_node = null
		_anim_system = null
		_cleanup_ik_visuals()
		await get_tree().process_frame

	var npc_id: String = TEST_NPCS[_current_npc_index]
	_status_label.text = "Spawning %s..." % npc_id
	var start := Time.get_ticks_msec()

	# Try prebaked NPC first
	if TestNPCLoaderScript.has_prebaked(npc_id):
		var character = TestNPCLoaderScript.load_test_npc(npc_id)
		if character:
			_npc_node = character
			add_child(character)
			character.global_position = Vector3(0, 0.05, 0)

			_factory = CharacterFactoryV2Script.new()
			_factory.enable_ik = true
			_factory.enable_wander = false
			_factory.debug_characters = true
			_factory.debug_animations = true
			_factory.setup_character(character,
				character.get_meta("is_female", false),
				character.get_meta("is_beast", false),
				character.get_meta("race_id", ""),
				character.get_meta("record_id", ""))
			_factory_ready = true

			_force_loop_locomotion(character)
			_populate_mw_list()
			_cache_anim_system()
			_status_label.text = "%s loaded (prebaked, %d ms)" % [npc_id, Time.get_ticks_msec() - start]
			return

	# Full pipeline fallback
	_status_label.text = "Loading full pipeline..."
	await _ensure_full_pipeline()

	var esm_mgr = get_node_or_null("/root/ESMManager")
	if not esm_mgr:
		_status_label.text = "ESMManager not available"
		return

	var npc_record = null
	if esm_mgr.has_method("get_npc"):
		npc_record = esm_mgr.get_npc(npc_id)
	if not npc_record:
		_status_label.text = "NPC '%s' not found in ESM" % npc_id
		return

	_factory.enable_ik = true
	_factory.enable_wander = false
	var character = _factory.create_npc(npc_record, 0)

	if not character:
		_status_label.text = "Failed to create NPC"
		return

	_npc_node = character
	add_child(character)
	character.global_position = Vector3(0, 0.05, 0)

	_force_loop_locomotion(character)
	_populate_mw_list()
	_cache_anim_system()
	_status_label.text = "%s loaded (full pipeline, %d ms)" % [npc_id, Time.get_ticks_msec() - start]


func _ensure_full_pipeline() -> void:
	if _factory_ready:
		return

	if not _data_loaded:
		await _ensure_data_loaded()
		_data_loaded = true

	CharacterFactoryV2Script.preload_character_assets()

	_factory = CharacterFactoryV2Script.new()
	_factory.debug_characters = true
	_factory.debug_animations = true
	_factory.enable_ik = true
	_factory.enable_wander = false
	_factory_ready = true


func _ensure_data_loaded() -> void:
	var data_path: String = SettingsManager.get_data_path()
	if data_path.is_empty():
		data_path = SettingsManager.auto_detect_installation()
	if data_path.is_empty():
		_status_label.text = "No Morrowind data path configured"
		return

	if not BSAManager.has_file("meshes\\xbase_anim.nif"):
		BSAManager.load_archives_from_directory(data_path)
		await get_tree().process_frame

	if ESMManager.cells.is_empty():
		var esm_file: String = SettingsManager.get_esm_file()
		var esm_path := data_path.path_join(esm_file)
		var error := ESMManager.load_file(esm_path)
		if error != OK:
			_status_label.text = "Failed to load ESM"
			return
		await get_tree().process_frame


# =============================================================================
# ANIMATION HELPERS
# =============================================================================

func _force_loop_locomotion(character: Node) -> void:
	var anim_player: AnimationPlayer = _find_node_of_type(character, "AnimationPlayer")
	if not anim_player:
		return
	for anim_name in anim_player.get_animation_list():
		var anim: Animation = anim_player.get_animation(anim_name)
		if not anim or anim.loop_mode != Animation.LOOP_NONE:
			continue
		var lower := anim_name.to_lower()
		if "idle" in lower or "walk" in lower or "run" in lower or "swim" in lower:
			anim.loop_mode = Animation.LOOP_LINEAR


# =============================================================================
# AUTO-TEST (--autotest flag, for CI validation)
# =============================================================================

func _run_auto_test() -> void:
	print("[AutoTest] === START ===")
	await get_tree().create_timer(1.0).timeout

	var skeleton: Skeleton3D = _find_node_of_type(_npc_node, "Skeleton3D") if _npc_node else null
	if skeleton:
		var hips_idx := skeleton.find_bone("Hips")
		if hips_idx >= 0:
			var hips_pos := skeleton.get_bone_global_pose(hips_idx).origin
			var pass_str := "PASS" if hips_pos.y > 0.3 and hips_pos.y < 2.0 else "FAIL"
			print("[AutoTest] S1 MW idle Hips height: %.2fm — %s" % [hips_pos.y, pass_str])

	# Load Mixamo and test
	_load_mixamo()
	if _mixamo_loaded:
		_ensure_mixamo_active()
		await get_tree().create_timer(1.0).timeout

		if skeleton:
			var hips_idx := skeleton.find_bone("Hips")
			if hips_idx >= 0:
				var hips_pos := skeleton.get_bone_global_pose(hips_idx).origin
				var pass_str := "PASS" if hips_pos.y > 0.3 and hips_pos.y < 2.0 else "FAIL"
				print("[AutoTest] S2 Mixamo Hips height: %.2fm — %s" % [hips_pos.y, pass_str])

		# Restore MW
		_ensure_mw_active()
		await get_tree().create_timer(0.5).timeout

		if skeleton:
			var hips_idx := skeleton.find_bone("Hips")
			if hips_idx >= 0:
				var hips_pos := skeleton.get_bone_global_pose(hips_idx).origin
				var pass_str := "PASS" if hips_pos.y > 0.3 and hips_pos.y < 2.0 else "FAIL"
				print("[AutoTest] S3 MW restored Hips height: %.2fm — %s" % [hips_pos.y, pass_str])

	print("[AutoTest] === COMPLETE ===")


# =============================================================================
# IK HELPERS
# =============================================================================

func _cache_anim_system() -> void:
	if not _npc_node:
		return
	_anim_system = _npc_node.get_meta("animation_system", null)
	if not _anim_system:
		_anim_system = _find_node_of_type(_npc_node, "MorrowindCharacterSystem")
	if not _anim_system:
		_anim_system = _find_node_of_type(_npc_node, "CharacterAnimationSystem")

	# Apply current foot IK state
	if _anim_system and _anim_system.has_method("set_foot_ik_enabled"):
		_anim_system.set_foot_ik_enabled(_foot_ik_enabled)

	_print_ik_diagnostics()


func _cleanup_ik_visuals() -> void:
	if _look_orb and is_instance_valid(_look_orb):
		_look_orb.queue_free()
		_look_orb = null
	if _left_hand_sphere and is_instance_valid(_left_hand_sphere):
		_left_hand_sphere.queue_free()
		_left_hand_sphere = null
	if _right_hand_sphere and is_instance_valid(_right_hand_sphere):
		_right_hand_sphere.queue_free()
		_right_hand_sphere = null


func _create_look_orb_if_needed() -> void:
	if _look_orb and is_instance_valid(_look_orb):
		return

	_look_orb = MeshInstance3D.new()
	_look_orb.name = "LookAtOrb"
	var sphere := SphereMesh.new()
	sphere.radius = 0.08
	sphere.height = 0.16
	_look_orb.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.85, 0.2)
	mat.emission_enabled = true
	mat.emission = Color(0.8, 0.6, 0.1)
	mat.emission_energy_multiplier = 2.0
	_look_orb.material_override = mat
	add_child(_look_orb)
	# Initialize position at head height
	var npc_pos: Vector3 = _npc_node.global_position if _npc_node else Vector3.ZERO
	_look_orb.global_position = npc_pos + Vector3(1.5, 1.6, 0)


func _create_hand_spheres_if_needed() -> void:
	if _left_hand_sphere and is_instance_valid(_left_hand_sphere):
		return

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.9, 0.5)
	mat.emission_enabled = true
	mat.emission = Color(0.1, 0.4, 0.2)
	mat.emission_energy_multiplier = 1.5

	_left_hand_sphere = MeshInstance3D.new()
	_left_hand_sphere.name = "LeftHandAttractor"
	var sphere_l := SphereMesh.new()
	sphere_l.radius = 0.06
	sphere_l.height = 0.12
	_left_hand_sphere.mesh = sphere_l
	_left_hand_sphere.material_override = mat
	add_child(_left_hand_sphere)

	_right_hand_sphere = MeshInstance3D.new()
	_right_hand_sphere.name = "RightHandAttractor"
	var sphere_r := SphereMesh.new()
	sphere_r.radius = 0.06
	sphere_r.height = 0.12
	_right_hand_sphere.mesh = sphere_r
	_right_hand_sphere.material_override = mat
	add_child(_right_hand_sphere)

	var npc_pos: Vector3 = _npc_node.global_position if _npc_node else Vector3.ZERO
	_left_hand_sphere.global_position = npc_pos + Vector3(-0.6, 1.3, -0.3)
	_right_hand_sphere.global_position = npc_pos + Vector3(0.6, 1.3, -0.3)


func _print_ik_diagnostics() -> void:
	if not _npc_node:
		print("[IK Diag] No NPC loaded")
		return

	print("[IK Diag] === IK DIAGNOSTICS ===")
	var char_body: CharacterBody3D = _npc_node as CharacterBody3D
	print("[IK Diag] CharacterBody3D: %s (type: %s)" % [char_body != null, _npc_node.get_class()])
	print("[IK Diag] AnimationSystem: %s" % (_anim_system != null))

	if _anim_system:
		print("[IK Diag]   enable_ik: %s" % _anim_system.get("enable_ik"))
		var ik_ctrl = _anim_system.get("ik_controller")
		print("[IK Diag]   ik_controller: %s" % (ik_ctrl != null))
		if ik_ctrl:
			print("[IK Diag]   IK _is_setup: %s" % ik_ctrl.get("_is_setup"))
			print("[IK Diag]   IK character_body: %s" % (ik_ctrl.get("character_body") != null))
			print("[IK Diag]   IK foot/look/hand: %s/%s/%s" % [
				ik_ctrl.get("enable_foot_ik"), ik_ctrl.get("enable_look_at"),
				ik_ctrl.get("enable_hand_ik")])
			print("[IK Diag]   _left_foot_ik: %s  _right_foot_ik: %s" % [
				ik_ctrl.get("_left_foot_ik") != null, ik_ctrl.get("_right_foot_ik") != null])

	# Check skeleton for TwoBoneIK3D children
	var skeleton: Skeleton3D = _find_node_of_type(_npc_node, "Skeleton3D")
	if skeleton:
		print("[IK Diag] Skeleton: %s (%d bones)" % [skeleton.name, skeleton.get_bone_count()])
		for child in skeleton.get_children():
			if child is TwoBoneIK3D:
				var ik: TwoBoneIK3D = child
				print("[IK Diag]   %s: active=%s" % [ik.name, ik.active])

	# Check ground collision layer
	var ground := get_node_or_null("Ground")
	if ground is StaticBody3D:
		print("[IK Diag] Ground collision_layer: %d" % (ground as StaticBody3D).collision_layer)

	print("[IK Diag] === END ===")


# =============================================================================
# IK TEST CUBES
# =============================================================================

func _process(delta: float) -> void:
	# Scroll cubes toward the camera (negative Z), wrap around
	if _cube_container:
		for cube: Node3D in _cube_container.get_children():
			cube.position.z -= CUBE_SCROLL_SPEED * delta
			if cube.position.z < -CUBE_WRAP_Z:
				cube.position.z += CUBE_SPREAD_Z + CUBE_WRAP_Z
				cube.position.x = randf_range(-CUBE_SPREAD_X * 0.5, CUBE_SPREAD_X * 0.5)
				var h := randf_range(0.02, 0.12)
				cube.position.y = h * 0.5
				cube.scale.y = h / 0.1

	# Update IK targets
	if not _npc_node:
		return
	_ik_time += delta
	var npc_pos: Vector3 = _npc_node.global_position

	# Look orb: orbit around head
	if _look_ik_enabled and _look_orb and is_instance_valid(_look_orb):
		var radius := 1.5
		var y: float = npc_pos.y + 1.6 + sin(_ik_time * 0.7) * 0.3
		_look_orb.global_position = Vector3(
			npc_pos.x + sin(_ik_time * 0.5) * radius,
			y,
			npc_pos.z + cos(_ik_time * 0.5) * radius
		)

	# Hand spheres: hover near the character's hands with gentle motion
	if _hand_ik_enabled:
		if _left_hand_sphere and is_instance_valid(_left_hand_sphere):
			_left_hand_sphere.global_position = Vector3(
				npc_pos.x - 0.6 + sin(_ik_time * 0.8) * 0.15,
				npc_pos.y + 1.3 + sin(_ik_time * 1.2) * 0.15,
				npc_pos.z - 0.3 + cos(_ik_time * 0.6) * 0.2
			)
		if _right_hand_sphere and is_instance_valid(_right_hand_sphere):
			_right_hand_sphere.global_position = Vector3(
				npc_pos.x + 0.6 + sin(_ik_time * 0.8 + PI) * 0.15,
				npc_pos.y + 1.3 + sin(_ik_time * 1.2 + PI) * 0.15,
				npc_pos.z - 0.3 + cos(_ik_time * 0.6 + PI) * 0.2
			)


func _create_ik_cubes() -> void:
	_cube_container = Node3D.new()
	_cube_container.name = "IKTestCubes"
	add_child(_cube_container)

	var cube_mat := StandardMaterial3D.new()
	cube_mat.albedo_color = Color(0.45, 0.35, 0.25)

	var cube_mesh := BoxMesh.new()
	cube_mesh.size = Vector3(0.4, 0.1, 0.4)

	for i in CUBE_COUNT:
		var body := StaticBody3D.new()
		body.name = "Cube%d" % i
		body.collision_layer = 1  # Must match IK raycast collision_mask

		# Spread cubes in a field around origin
		var x := randf_range(-CUBE_SPREAD_X * 0.5, CUBE_SPREAD_X * 0.5)
		var z := randf_range(-CUBE_WRAP_Z, CUBE_SPREAD_Z)
		var h := randf_range(0.02, 0.12)
		body.position = Vector3(x, h * 0.5, z)
		body.scale.y = h / 0.1

		var mesh_inst := MeshInstance3D.new()
		mesh_inst.mesh = cube_mesh
		mesh_inst.material_override = cube_mat
		body.add_child(mesh_inst)

		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(0.4, 0.1, 0.4)
		col.shape = shape
		body.add_child(col)

		_cube_container.add_child(body)


# =============================================================================
# SCENE SETUP
# =============================================================================

func _setup_scene() -> void:
	_camera = Camera3D.new()
	_camera.name = "Camera3D"
	_camera.position = Vector3(0, 1.0, -3.0)
	add_child(_camera)
	_camera.look_at(Vector3(0, 0.8, 0))

	var light := DirectionalLight3D.new()
	light.name = "KeyLight"
	light.rotation_degrees = Vector3(-45, 30, 0)
	light.light_energy = 1.2
	light.shadow_enabled = true
	add_child(light)

	var fill := DirectionalLight3D.new()
	fill.name = "FillLight"
	fill.rotation_degrees = Vector3(-30, -120, 0)
	fill.light_energy = 0.4
	fill.light_color = Color(0.8, 0.85, 1.0)
	add_child(fill)

	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.ambient_light_color = Color(0.5, 0.5, 0.55)
	environment.ambient_light_energy = 0.6
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.15, 0.15, 0.2)
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = environment
	add_child(env)

	var ground_body := StaticBody3D.new()
	ground_body.name = "Ground"
	ground_body.collision_layer = 1  # Must match IK raycast collision_mask
	add_child(ground_body)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(20, 20)
	ground.mesh = plane
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.3, 0.35, 0.25)
	ground.material_override = ground_mat
	ground_body.add_child(ground)

	var col_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20, 0.1, 20)
	col_shape.shape = box
	col_shape.position.y = -0.05
	ground_body.add_child(col_shape)

	_create_ik_cubes()


# =============================================================================
# UTILITIES
# =============================================================================

func _find_node_of_type(node: Node, type_name: String) -> Node:
	if node.get_class() == type_name:
		return node
	for child in node.get_children():
		var result := _find_node_of_type(child, type_name)
		if result:
			return result
	return null


func _count_nodes_of_type(node: Node, type_name: String) -> int:
	var count := 0
	if node.get_class() == type_name:
		count += 1
	for child in node.get_children():
		count += _count_nodes_of_type(child, type_name)
	return count
