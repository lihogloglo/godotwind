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
var _mixamo_raw_library: AnimationLibrary = null  # Un-retargeted, for diagnostics
var _mixamo_source_rest: Dictionary = {}
var _mixamo_anim_rest: Dictionary = {}  # Idle frame 0 rest poses
var _mixamo_target_rest: Dictionary = {}  # MW skeleton rest
var _mixamo_loaded: bool = false

# Cached MW library (so we can swap back after playing Mixamo)
var _mw_library: AnimationLibrary = null

# Mixamo reference character (side-by-side comparison)
var _mixamo_ref_node: Node = null
var _mixamo_ref_anim_player: AnimationPlayer = null
var _mixamo_ref_library: AnimationLibrary = null  # Original un-retargeted, for reference
var _mixamo_ref_skeleton: Skeleton3D = null
var _mixamo_ref_debug_mesh: MeshInstance3D = null  # ImmediateMesh skeleton wireframe

# UI elements
var _npc_selector: OptionButton = null
var _mw_list: ItemList = null
var _mixamo_list: ItemList = null
var _mw_header: Label = null
var _mixamo_header: Label = null
var _status_label: Label = null
var _anim_panel: PanelContainer = null
var _panel_toggle: Button = null

# Retarget CoB toggle
var _cob_toggle: CheckButton = null
var _use_cob: bool = true

# MW skeleton wireframe (for bone-by-bone comparison)
var _mw_debug_mesh: MeshInstance3D = null
var _mw_skeleton: Skeleton3D = null

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
	_anim_panel = PanelContainer.new()
	_anim_panel.name = "AnimPanel"
	_anim_panel.anchor_left = 0.55
	_anim_panel.anchor_top = 0.0
	_anim_panel.anchor_right = 1.0
	_anim_panel.anchor_bottom = 1.0
	_anim_panel.offset_left = 0
	_anim_panel.offset_top = 0
	_anim_panel.offset_right = 0
	_anim_panel.offset_bottom = 0
	var panel := _anim_panel

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

	# --- Retarget toggle row ---
	var retarget_row := HBoxContainer.new()
	retarget_row.add_theme_constant_override("separation", 6)

	_cob_toggle = CheckButton.new()
	_cob_toggle.text = "CoB retarget"
	_cob_toggle.button_pressed = _use_cob
	_cob_toggle.toggled.connect(_on_cob_toggled)
	retarget_row.add_child(_cob_toggle)

	vbox.add_child(retarget_row)

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

	# Toggle button anchored to the left edge of the panel
	_panel_toggle = Button.new()
	_panel_toggle.name = "PanelToggle"
	_panel_toggle.text = "<"
	_panel_toggle.anchor_left = 0.55
	_panel_toggle.anchor_top = 0.0
	_panel_toggle.anchor_right = 0.55
	_panel_toggle.anchor_bottom = 0.0
	_panel_toggle.offset_left = -28
	_panel_toggle.offset_top = 4
	_panel_toggle.offset_right = -4
	_panel_toggle.offset_bottom = 28
	_panel_toggle.pressed.connect(_on_panel_toggle)
	var btn_style := StyleBoxFlat.new()
	btn_style.bg_color = Color(0.15, 0.15, 0.2, 0.9)
	btn_style.set_corner_radius_all(4)
	_panel_toggle.add_theme_stylebox_override("normal", btn_style)
	_panel_toggle.add_theme_stylebox_override("hover", btn_style)
	_panel_toggle.add_theme_stylebox_override("pressed", btn_style)
	canvas.add_child(_panel_toggle)


# =============================================================================
# LIST CLICK HANDLERS
# =============================================================================

func _on_panel_toggle() -> void:
	_anim_panel.visible = not _anim_panel.visible
	if _anim_panel.visible:
		_panel_toggle.text = "<"
		_panel_toggle.anchor_left = 0.55
		_panel_toggle.anchor_right = 0.55
		_panel_toggle.offset_left = -28
		_panel_toggle.offset_right = -4
	else:
		_panel_toggle.text = ">"
		_panel_toggle.anchor_left = 1.0
		_panel_toggle.anchor_right = 1.0
		_panel_toggle.offset_left = -28
		_panel_toggle.offset_right = -4


func _on_npc_selected(index: int) -> void:
	if index == _current_npc_index:
		return
	_current_npc_index = index
	# Reset Mixamo (skeleton rest poses differ per NPC)
	_mixamo_library = null
	_mixamo_loaded = false
	_mw_library = null
	if _mixamo_ref_node and is_instance_valid(_mixamo_ref_node):
		_mixamo_ref_node.queue_free()
		_mixamo_ref_node = null
		_mixamo_ref_anim_player = null
		_mixamo_ref_library = null
		_mixamo_ref_skeleton = null
		_mixamo_ref_debug_mesh = null
	_mixamo_list.clear()
	_mixamo_list.add_item("[ Click to load Mixamo ]")
	_mixamo_header.text = "Mixamo (click to load)"
	_spawn_npc()


func _on_cob_toggled(enabled: bool) -> void:
	_use_cob = enabled
	# Force Mixamo reload with new setting
	_mixamo_library = null
	_mixamo_loaded = false
	_mixamo_list.clear()
	_mixamo_list.add_item("[ Click to load Mixamo ]")
	_mixamo_header.text = "Mixamo (click to reload)"
	_status_label.text = "CoB %s — click Mixamo list to reload" % ("ON" if enabled else "OFF (simple swap)")


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
	# Stop reference character when playing MW anims
	if _mixamo_ref_anim_player:
		_mixamo_ref_anim_player.stop()
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
	_play_mixamo_reference(anim_name)
	_dump_retarget_diagnostic(anim_name)
	# Deselect the other list
	_mw_list.deselect_all()
	_status_label.text = "Playing: %s (Mixamo) — reference on left" % anim_name


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


func _play_mixamo_reference(anim_name: String) -> void:
	if not _mixamo_ref_anim_player or not _mixamo_ref_library:
		return
	if not _mixamo_ref_library.has_animation(anim_name):
		print("[AnimTest] Reference doesn't have animation '%s'" % anim_name)
		return

	var anim: Animation = _mixamo_ref_library.get_animation(anim_name)
	# Force loop on locomotion anims
	if anim and anim.loop_mode == Animation.LOOP_NONE:
		var lower := anim_name.to_lower()
		if "idle" in lower or "walk" in lower or "run" in lower:
			anim.loop_mode = Animation.LOOP_LINEAR

	_mixamo_ref_anim_player.speed_scale = 1.0
	_mixamo_ref_anim_player.play(anim_name)
	print("[AnimTest] Reference playing '%s'" % anim_name)


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
	_mixamo_raw_library = raw_library  # Keep for diagnostics

	if _mixamo_source_rest.is_empty():
		_mixamo_library = raw_library
	else:
		var skeleton: Skeleton3D = _find_node_of_type(_npc_node, "Skeleton3D") if _npc_node else null
		if not skeleton:
			_mixamo_library = raw_library
		else:
			_mixamo_target_rest = AnimationLoaderScript.get_skeleton_rest_poses(skeleton)
			_mixamo_anim_rest = AnimationLoaderScript.extract_anim_rest_poses(raw_library, _mixamo_source_rest)

			# Compute global idle orientations using ACTUAL MW skeleton hierarchy.
			# Critical: the MW skeleton has intermediate bones (e.g. Bip01 Pelvis)
			# between profile bones that the profile hierarchy doesn't know about.
			var mw_idle_quats := {}
			for bone_name in _mixamo_target_rest:
				mw_idle_quats[bone_name] = _mixamo_target_rest[bone_name].basis.get_rotation_quaternion()
			var target_global_idles := AnimationLoaderScript.compute_skeleton_global_idles(skeleton, mw_idle_quats)
			_dump_hierarchy_diagnostic(skeleton, target_global_idles)

			if _use_cob:
				_mixamo_library = AnimationLoaderScript.retarget_library(
					raw_library, _mixamo_anim_rest, _mixamo_target_rest, true, _mixamo_source_rest, target_global_idles)
				print("[AnimTest] Retarget mode: CoB (pose-space change of basis)")
			else:
				_mixamo_library = AnimationLoaderScript.retarget_library(
					raw_library, _mixamo_anim_rest, _mixamo_target_rest, true, {}, {})
				print("[AnimTest] Retarget mode: Simple swap (R_t * idle_s⁻¹ * anim)")

	_mixamo_loaded = true
	_populate_mixamo_list()
	_spawn_mixamo_reference()


func _spawn_mixamo_reference() -> void:
	# Clean up previous reference
	if _mixamo_ref_node and is_instance_valid(_mixamo_ref_node):
		_mixamo_ref_node.queue_free()
		_mixamo_ref_node = null
		_mixamo_ref_anim_player = null

	# Load Idle.fbx as the reference character (has skeleton + mesh)
	var scene: PackedScene = load("res://assets/animations/mixamo/Idle.fbx") as PackedScene
	if not scene:
		print("[AnimTest] Cannot load Mixamo reference FBX")
		return

	_mixamo_ref_node = scene.instantiate()
	if not _mixamo_ref_node:
		return

	# Position to the left of MW character, rotated 180° Y to face same direction
	add_child(_mixamo_ref_node)
	_mixamo_ref_node.global_position = Vector3(-1.5, 0.05, 0)
	if _mixamo_ref_node is Node3D:
		(_mixamo_ref_node as Node3D).rotation.y = PI  # 180° Y — face same direction as MW

	# Dump the transform chain to understand facing direction
	_dump_transform_chain("Mixamo Ref", _mixamo_ref_node)

	# Find its AnimationPlayer
	_mixamo_ref_anim_player = _find_node_of_type(_mixamo_ref_node, "AnimationPlayer")
	if not _mixamo_ref_anim_player:
		print("[AnimTest] Mixamo reference has no AnimationPlayer")
		return

	# Build merged library with all Mixamo FBX animations (un-retargeted, original bone names)
	_mixamo_ref_library = AnimationLibrary.new()

	var dir := DirAccess.open("res://assets/animations/mixamo/")
	if not dir:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir():
			var lower := file_name.to_lower()
			if lower.ends_with(".fbx") or lower.ends_with(".glb"):
				var full_path := "res://assets/animations/mixamo/".path_join(file_name)
				var fbx_scene: PackedScene = load(full_path) as PackedScene
				if fbx_scene:
					var fbx_root := fbx_scene.instantiate()
					var fbx_ap: AnimationPlayer = _find_node_of_type(fbx_root, "AnimationPlayer")
					if fbx_ap:
						for anim_name in fbx_ap.get_animation_list():
							if anim_name == "RESET":
								continue
							# Normalize name same way as AnimationLoader
							var normalized := AnimationLoaderScript._normalize_name(anim_name, full_path)
							if not _mixamo_ref_library.has_animation(normalized):
								_mixamo_ref_library.add_animation(normalized, fbx_ap.get_animation(anim_name))
					fbx_root.queue_free()
		file_name = dir.get_next()
	dir.list_dir_end()

	# Replace the default library
	if _mixamo_ref_anim_player.has_animation_library(""):
		_mixamo_ref_anim_player.remove_animation_library("")
	_mixamo_ref_anim_player.add_animation_library("", _mixamo_ref_library)

	# Disable any AnimationTree on the reference
	var trees := []
	_collect_nodes_of_class(_mixamo_ref_node, "AnimationTree", trees)
	for t: Node in trees:
		t.set("active", false)

	# Create skeleton wireframe visualization (FBX has no mesh — "Without Skin" export)
	_mixamo_ref_skeleton = _find_node_of_type(_mixamo_ref_node, "Skeleton3D") as Skeleton3D
	if _mixamo_ref_skeleton:
		_mixamo_ref_debug_mesh = MeshInstance3D.new()
		_mixamo_ref_debug_mesh.name = "SkeletonWireframe"
		var im := ImmediateMesh.new()
		_mixamo_ref_debug_mesh.mesh = im
		var wire_mat := StandardMaterial3D.new()
		wire_mat.albedo_color = Color(0.2, 0.85, 1.0)
		wire_mat.emission_enabled = true
		wire_mat.emission = Color(0.1, 0.4, 0.6)
		wire_mat.emission_energy_multiplier = 2.0
		wire_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mixamo_ref_debug_mesh.material_override = wire_mat
		_mixamo_ref_skeleton.add_child(_mixamo_ref_debug_mesh)
		print("[AnimTest] Skeleton wireframe created (%d bones)" % _mixamo_ref_skeleton.get_bone_count())

	print("[AnimTest] Mixamo reference spawned with %d animations" % _mixamo_ref_library.get_animation_list().size())


func _setup_mw_wireframe() -> void:
	if _mw_debug_mesh and is_instance_valid(_mw_debug_mesh):
		_mw_debug_mesh.queue_free()
	_mw_skeleton = _find_node_of_type(_npc_node, "Skeleton3D") as Skeleton3D if _npc_node else null
	if not _mw_skeleton:
		return
	_mw_debug_mesh = MeshInstance3D.new()
	_mw_debug_mesh.name = "MWSkeletonWireframe"
	var im := ImmediateMesh.new()
	_mw_debug_mesh.mesh = im
	var wire_mat := StandardMaterial3D.new()
	wire_mat.albedo_color = Color(1.0, 0.6, 0.2)  # Orange for MW
	wire_mat.emission_enabled = true
	wire_mat.emission = Color(0.5, 0.3, 0.1)
	wire_mat.emission_energy_multiplier = 2.0
	wire_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mw_debug_mesh.material_override = wire_mat
	_mw_skeleton.add_child(_mw_debug_mesh)
	print("[AnimTest] MW skeleton wireframe created (%d bones)" % _mw_skeleton.get_bone_count())


func _draw_skeleton_wireframe(skeleton: Skeleton3D, debug_mesh: MeshInstance3D) -> void:
	if not skeleton or not debug_mesh:
		return
	if not is_instance_valid(skeleton) or not is_instance_valid(debug_mesh):
		return

	var im: ImmediateMesh = debug_mesh.mesh
	im.clear_surfaces()

	# Draw bone lines (parent → child)
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in skeleton.get_bone_count():
		var parent_idx := skeleton.get_bone_parent(i)
		if parent_idx < 0:
			continue
		var bone_pos: Vector3 = skeleton.get_bone_global_pose(i).origin
		var parent_pos: Vector3 = skeleton.get_bone_global_pose(parent_idx).origin
		im.surface_add_vertex(parent_pos)
		im.surface_add_vertex(bone_pos)
	im.surface_end()

	# Draw small crosses at each joint for visibility
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var cross_size := 0.015
	for i in skeleton.get_bone_count():
		var pos: Vector3 = skeleton.get_bone_global_pose(i).origin
		im.surface_add_vertex(pos + Vector3(-cross_size, 0, 0))
		im.surface_add_vertex(pos + Vector3(cross_size, 0, 0))
		im.surface_add_vertex(pos + Vector3(0, -cross_size, 0))
		im.surface_add_vertex(pos + Vector3(0, cross_size, 0))
		im.surface_add_vertex(pos + Vector3(0, 0, -cross_size))
		im.surface_add_vertex(pos + Vector3(0, 0, cross_size))
	im.surface_end()


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
		_mw_skeleton = null
		_mw_debug_mesh = null
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
			_dump_transform_chain("MW NPC", character)
			_setup_mw_wireframe()
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
	_setup_mw_wireframe()
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
# RETARGET DIAGNOSTICS
# =============================================================================

## Key bones to diagnose (skip fingers for readability)
const _DIAG_BONES := [
	"Hips", "Spine", "Chest", "UpperChest", "Neck", "Head",
	"LeftShoulder", "LeftUpperArm", "LeftLowerArm", "LeftHand",
	"RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand",
	"LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
	"RightUpperLeg", "RightLowerLeg", "RightFoot",
]


func _dump_retarget_diagnostic(anim_name: String) -> void:
	if not _mixamo_raw_library or not _mixamo_library:
		return

	var raw_anim: Animation = _mixamo_raw_library.get_animation(anim_name) if _mixamo_raw_library.has_animation(anim_name) else null
	var ret_anim: Animation = _mixamo_library.get_animation(anim_name) if _mixamo_library.has_animation(anim_name) else null
	if not raw_anim or not ret_anim:
		print("[Diag] Animation '%s' not found in raw or retargeted library" % anim_name)
		return

	print("")
	print("[Diag] ========== RETARGET DIAGNOSTIC: %s ==========" % anim_name)
	print("[Diag] Format: euler angles in degrees (pitch, yaw, roll)")
	print("[Diag]")

	# Build track index lookup for raw and retargeted animations
	var raw_tracks := {}  # bone_name -> track_idx
	for i in raw_anim.get_track_count():
		var path := raw_anim.track_get_path(i)
		if path.get_subname_count() > 0:
			raw_tracks[String(path.get_subname(0))] = i

	var ret_tracks := {}
	for i in ret_anim.get_track_count():
		var path := ret_anim.track_get_path(i)
		if path.get_subname_count() > 0:
			ret_tracks[String(path.get_subname(0))] = i

	# Print rest pose comparison header
	print("[Diag] %-18s | %-28s | %-28s | %-28s | %-28s" % [
		"Bone", "Mixamo GeomRest", "Mixamo AnimRest(idle f0)", "MW Rest", "Raw Frame0 → Retarg Frame0"])

	for bone_name in _DIAG_BONES:
		var geom_rest_str := "---"
		var anim_rest_str := "---"
		var mw_rest_str := "---"
		var frame0_str := "---"

		if bone_name in _mixamo_source_rest:
			var q: Quaternion = _mixamo_source_rest[bone_name].basis.get_rotation_quaternion()
			geom_rest_str = _euler_str(q)

		if bone_name in _mixamo_anim_rest:
			var q: Quaternion = _mixamo_anim_rest[bone_name].basis.get_rotation_quaternion()
			anim_rest_str = _euler_str(q)

		if bone_name in _mixamo_target_rest:
			var q: Quaternion = _mixamo_target_rest[bone_name].basis.get_rotation_quaternion()
			mw_rest_str = _euler_str(q)

		# Frame 0 comparison: raw vs retargeted
		var raw_f0_str := "---"
		var ret_f0_str := "---"
		if bone_name in raw_tracks:
			var tidx: int = raw_tracks[bone_name]
			if raw_anim.track_get_type(tidx) == Animation.TYPE_ROTATION_3D and raw_anim.track_get_key_count(tidx) > 0:
				var q: Quaternion = raw_anim.track_get_key_value(tidx, 0)
				raw_f0_str = _euler_str(q)
		if bone_name in ret_tracks:
			var tidx: int = ret_tracks[bone_name]
			if ret_anim.track_get_type(tidx) == Animation.TYPE_ROTATION_3D and ret_anim.track_get_key_count(tidx) > 0:
				var q: Quaternion = ret_anim.track_get_key_value(tidx, 0)
				ret_f0_str = _euler_str(q)

		frame0_str = "%s → %s" % [raw_f0_str, ret_f0_str]
		print("[Diag] %-18s | %-28s | %-28s | %-28s | %s" % [
			bone_name, geom_rest_str, anim_rest_str, mw_rest_str, frame0_str])

	# Also dump a few mid-animation frames for walk to see motion deltas
	if anim_name == "walk" and raw_anim.length > 0.3:
		print("[Diag]")
		print("[Diag] --- Walk frame samples (raw delta from idle → retargeted delta from MW rest) ---")
		var sample_time := raw_anim.length * 0.25  # 25% through walk cycle
		for bone_name in ["Hips", "LeftUpperLeg", "LeftLowerLeg", "LeftUpperArm", "Spine"]:
			if bone_name in raw_tracks and bone_name in ret_tracks:
				var raw_tidx: int = raw_tracks[bone_name]
				var ret_tidx: int = ret_tracks[bone_name]
				if raw_anim.track_get_type(raw_tidx) != Animation.TYPE_ROTATION_3D:
					continue

				# Sample at 25% of animation
				var raw_val: Quaternion = raw_anim.track_get_key_value(raw_tidx, mini(raw_anim.track_get_key_count(raw_tidx) / 4, raw_anim.track_get_key_count(raw_tidx) - 1))
				var ret_val: Quaternion = ret_anim.track_get_key_value(ret_tidx, mini(ret_anim.track_get_key_count(ret_tidx) / 4, ret_anim.track_get_key_count(ret_tidx) - 1))

				# Compute deltas from idle
				var raw_idle: Quaternion = Quaternion.IDENTITY
				if bone_name in _mixamo_anim_rest:
					raw_idle = _mixamo_anim_rest[bone_name].basis.get_rotation_quaternion()
				var raw_delta: Quaternion = raw_idle.inverse() * raw_val

				var mw_idle: Quaternion = Quaternion.IDENTITY
				if bone_name in _mixamo_target_rest:
					mw_idle = _mixamo_target_rest[bone_name].basis.get_rotation_quaternion()
				var ret_delta: Quaternion = mw_idle.inverse() * ret_val

				print("[Diag]   %-16s t=%.2fs: raw_delta=%s  ret_delta=%s  angle_diff=%.1f°" % [
					bone_name, sample_time,
					_euler_str(raw_delta), _euler_str(ret_delta),
					rad_to_deg(raw_delta.angle_to(ret_delta))])

	print("[Diag] ========== END DIAGNOSTIC ==========")
	print("")


func _dump_hierarchy_diagnostic(skeleton: Skeleton3D, global_idles: Dictionary) -> void:
	print("")
	print("[Hierarchy] ========== MW SKELETON HIERARCHY ==========")
	print("[Hierarchy] Bones: %d" % skeleton.get_bone_count())

	# Print actual parent chain for key bones
	var key_bones := ["Hips", "LeftUpperLeg", "RightUpperLeg", "Spine", "LeftUpperArm"]
	for target_bone in key_bones:
		var idx := skeleton.find_bone(target_bone)
		if idx < 0:
			continue
		var chain: String = target_bone
		var walk_idx := skeleton.get_bone_parent(idx)
		while walk_idx >= 0:
			var parent_name := skeleton.get_bone_name(walk_idx)
			var rest_euler := _euler_str(skeleton.get_bone_rest(walk_idx).basis.get_rotation_quaternion())
			chain = "%s(%s) → " % [parent_name, rest_euler] + chain
			walk_idx = skeleton.get_bone_parent(walk_idx)
		print("[Hierarchy]   %s" % chain)

	# Show intermediate (non-profile) bones between Hips and LeftUpperLeg
	var profile := SkeletonProfileHumanoid.new()
	var profile_names := {}
	for i in profile.bone_size:
		profile_names[String(profile.get_bone_name(i))] = true

	var non_profile := []
	for i in skeleton.get_bone_count():
		var name := skeleton.get_bone_name(i)
		if name not in profile_names:
			var parent_idx := skeleton.get_bone_parent(i)
			var parent_name := skeleton.get_bone_name(parent_idx) if parent_idx >= 0 else "(root)"
			var rest_euler := _euler_str(skeleton.get_bone_rest(i).basis.get_rotation_quaternion())
			non_profile.append("  %s (parent=%s, rest=%s)" % [name, parent_name, rest_euler])

	if non_profile.size() > 0:
		print("[Hierarchy] Non-profile bones in MW skeleton:")
		for line in non_profile:
			print("[Hierarchy] %s" % line)

	# Compare profile-based F_t vs actual-hierarchy F_t for LeftUpperLeg
	var lul_idx := skeleton.find_bone("LeftUpperLeg")
	var hips_idx := skeleton.find_bone("Hips")
	if lul_idx >= 0 and hips_idx >= 0:
		var R_t_lul := skeleton.get_bone_rest(lul_idx).basis.get_rotation_quaternion()
		var R_t_hips := skeleton.get_bone_rest(hips_idx).basis.get_rotation_quaternion()

		# Profile-based: F_t = G_t(Hips) * R_t(LUL) where G_t(Hips) = R_t(Hips) * R_t(Hips) = R_t²
		var profile_G_hips := R_t_hips * R_t_hips  # rest * idle = rest²
		var profile_F_lul := profile_G_hips * R_t_lul

		# Actual-hierarchy: F_t = global_idle(LUL) * R_t(LUL)⁻¹
		var actual_F_lul := Quaternion.IDENTITY
		if "LeftUpperLeg" in global_idles:
			actual_F_lul = global_idles["LeftUpperLeg"] * R_t_lul.inverse()

		var angle_diff := rad_to_deg(profile_F_lul.angle_to(actual_F_lul))
		print("[Hierarchy] LeftUpperLeg F_t comparison:")
		print("[Hierarchy]   Profile-based:  %s" % _euler_str(profile_F_lul))
		print("[Hierarchy]   Actual-hierarch: %s" % _euler_str(actual_F_lul))
		print("[Hierarchy]   Angle diff: %.1f°" % angle_diff)

	print("[Hierarchy] ========== END ==========")
	print("")


func _euler_str(q: Quaternion) -> String:
	var e := q.get_euler() * (180.0 / PI)
	return "(%6.1f,%6.1f,%6.1f)" % [e.x, e.y, e.z]


@warning_ignore("untyped_declaration")
func _dump_transform_chain(label: String, root_node: Node) -> void:
	print("")
	print("[Orient] ========== %s TRANSFORM CHAIN ==========" % label)

	# Walk the node tree from root to skeleton, printing transforms
	var node: Node = root_node
	var depth := 0
	while node:
		if node is Node3D:
			var n3d: Node3D = node as Node3D
			var rot_e: Vector3 = n3d.transform.basis.get_rotation_quaternion().get_euler() * (180.0 / PI)
			var sc: Vector3 = n3d.transform.basis.get_scale()
			print("[Orient]   %s%s (%s): pos=%s rot=(%6.1f,%6.1f,%6.1f) scale=(%.2f,%.2f,%.2f)" % [
				"  ".repeat(depth), node.name, node.get_class(),
				str(n3d.transform.origin).substr(0, 30),
				rot_e.x, rot_e.y, rot_e.z, sc.x, sc.y, sc.z])
		else:
			print("[Orient]   %s%s (%s)" % ["  ".repeat(depth), node.name, node.get_class()])
		# Look for Skeleton3D child
		var skel_child: Node = null
		for child in node.get_children():
			if child is Skeleton3D:
				skel_child = child
				break
			for grandchild in child.get_children():
				if grandchild is Skeleton3D:
					if child is Node3D:
						var ch3d: Node3D = child as Node3D
						var ch_r: Vector3 = ch3d.transform.basis.get_rotation_quaternion().get_euler() * (180.0 / PI)
						print("[Orient]   %s%s (%s): rot=(%6.1f,%6.1f,%6.1f)" % [
							"  ".repeat(depth + 1), child.name, child.get_class(),
							ch_r.x, ch_r.y, ch_r.z])
					skel_child = grandchild
					depth += 1
					break
			if skel_child:
				break
		if skel_child:
			node = skel_child
			depth += 1
		else:
			break

	# Find Skeleton3D and print key bone rest poses
	var skeleton: Skeleton3D = _find_node_of_type(root_node, "Skeleton3D") as Skeleton3D
	if skeleton:
		print("[Orient]   Skeleton3D global_transform rotation: %s" % _euler_str(
			skeleton.global_transform.basis.get_rotation_quaternion()))
		print("[Orient]   Key bone REST poses (in parent-local space):")
		for bone_name in ["Hips", "Spine", "LeftUpperLeg", "RightUpperLeg"]:
			var idx := skeleton.find_bone(bone_name)
			if idx >= 0:
				var rest_q := skeleton.get_bone_rest(idx).basis.get_rotation_quaternion()
				var parent_idx := skeleton.get_bone_parent(idx)
				var parent_name := skeleton.get_bone_name(parent_idx) if parent_idx >= 0 else "(root)"
				print("[Orient]     %s (parent=%s): rest=%s" % [bone_name, parent_name, _euler_str(rest_q)])
		# Also print Hips GLOBAL pose at current animation state
		var hips_idx := skeleton.find_bone("Hips")
		if hips_idx >= 0:
			var hips_global := skeleton.get_bone_global_pose(hips_idx)
			print("[Orient]   Hips GLOBAL pose: %s" % _euler_str(hips_global.basis.get_rotation_quaternion()))
			# Forward vector: what direction does the skeleton face?
			var forward := (skeleton.global_transform * hips_global).basis * Vector3.FORWARD
			print("[Orient]   Hips WORLD forward: (%.2f, %.2f, %.2f)" % [forward.x, forward.y, forward.z])

	print("[Orient] ========== END %s ==========" % label)
	print("")


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
	# Update skeleton wireframes
	_draw_skeleton_wireframe(_mixamo_ref_skeleton, _mixamo_ref_debug_mesh)
	_draw_skeleton_wireframe(_mw_skeleton, _mw_debug_mesh)

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
	_camera.position = Vector3(-0.75, 1.0, -3.5)
	add_child(_camera)
	_camera.look_at(Vector3(-0.75, 0.8, 0))

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
