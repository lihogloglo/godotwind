## NPC Assembly Test — Visual verification of the full NPC assembly pipeline
##
## Proves end-to-end: skeleton creation -> body part loading -> skin attachment
## -> bone renaming -> animation loading
##
## Controls:
##   Right-click drag = orbit camera
##   Scroll = zoom
##   1-5 = preset NPCs
##   B = toggle bone visualization
##   W = toggle wireframe
##   Enter = focus NPC ID input
@tool
@warning_ignore("untyped_declaration", "unsafe_method_access")
extends Node3D

const MorrowindNPCAssembler := preload("res://src/core/character/morrowind/morrowind_npc_assembler.gd")
const RetargetSetup := preload("res://src/core/animation/retarget_setup.gd")
const SPA := preload("res://src/core/animation/skeleton_profile_adapter.gd")
const BodyPartSlots := preload("res://src/core/character/morrowind/morrowind_body_part_slots.gd")
const NIFKFLoader := preload("res://src/core/nif/nif_kf_loader.gd")

# Well-known Morrowind NPCs covering different races/genders
const PRESET_NPCS := [
	"fargoth",            # 1 - Male Wood Elf
	"caius cosades",      # 2 - Male Imperial
	"ranis athrys",       # 3 - Female Dark Elf
	"arrille",            # 4 - Male High Elf
	"sugar-lips habasi",  # 5 - Female Khajiit (beast race)
]

# Scene nodes
var _camera: Camera3D
var _info_label: RichTextLabel
var _npc_id_input: LineEdit
var _npc_container: Node3D
var _bone_container: Node3D
var _skeleton: Skeleton3D

# Camera orbit
var _yaw := 20.0
var _pitch := -10.0
var _distance := 3.0
var _center := Vector3(0, 0.8, 0)
var _orbiting := false

# Toggle states
var _bones_visible := false
var _wireframe := false

# Display
var _stage_lines := PackedStringArray()


func _ready() -> void:
	_create_environment()
	_create_camera()
	_create_ui()

	_npc_container = Node3D.new()
	_npc_container.name = "NPCContainer"
	add_child(_npc_container)

	_bone_container = Node3D.new()
	_bone_container.name = "BoneContainer"
	_bone_container.visible = false
	add_child(_bone_container)

	# Wait for autoloads
	await get_tree().process_frame
	await get_tree().process_frame

	# Ensure game data is loaded (BSA + ESM)
	await _ensure_data_loaded()

	_load_npc(PRESET_NPCS[0])


func _ensure_data_loaded() -> void:
	# Check if ESM is already loaded
	var esm = get_node_or_null("/root/ESMManager")
	if esm and not esm.npcs.is_empty():
		return

	_update_info_text("[b]Loading game data...[/b]")

	# Load BSA archives
	var data_path: String = SettingsManager.get_data_path()
	if data_path.is_empty():
		data_path = SettingsManager.auto_detect_installation()
		if data_path.is_empty():
			_update_info_text("[color=red]ERROR: No Morrowind data path configured[/color]\nSet it in SettingsManager")
			return

	var bsa = get_node_or_null("/root/BSAManager")
	if bsa:
		bsa.load_archives_from_directory(data_path)

	# Load ESM file
	if esm:
		var esm_file: String = SettingsManager.get_esm_file()
		var esm_path := data_path.path_join(esm_file)
		_update_info_text("[b]Loading ESM file...[/b]\n%s" % esm_path)
		var error: int = esm.load_file(esm_path)
		if error != OK:
			_update_info_text("[color=red]ERROR: Failed to load ESM: %s[/color]" % error_string(error))
			return

		_update_info_text("[b]ESM loaded.[/b] NPCs: %d" % esm.npcs.size())
		await get_tree().process_frame


func _update_info_text(text: String) -> void:
	if _info_label:
		_info_label.text = text


# =============================================================================
# CORE PIPELINE
# =============================================================================

func _load_npc(npc_id: String) -> void:
	_clear_current()
	_stage_lines = PackedStringArray()
	_stage_lines.append("[b]NPC Assembly Test[/b]")
	_stage_lines.append("NPC ID: [color=yellow]%s[/color]\n" % npc_id)

	var esm = get_node_or_null("/root/ESMManager")
	if not esm:
		_stage_lines.append("[color=red]ERROR: ESMManager not available[/color]")
		_update_info()
		return

	var npc = esm.get_npc(npc_id)
	if not npc:
		_stage_lines.append("[color=red]NPC '%s' not found in ESM data[/color]" % npc_id)
		_stage_lines.append("\nTry a different NPC ID or use presets 1-5")
		_update_info()
		return

	var race = esm.get_race(npc.race_id)
	if not race:
		_stage_lines.append("[color=red]Race '%s' not found[/color]" % npc.race_id)
		_update_info()
		return

	var is_female: bool = npc.is_female()
	var is_beast: bool = race.is_beast()

	_stage_lines.append("Name: %s" % npc.name)
	_stage_lines.append("Race: %s (%s)" % [race.name, "Beast" if is_beast else "Humanoid"])
	_stage_lines.append("Gender: %s" % ("Female" if is_female else "Male"))

	# --- STAGE 1: Assemble skeleton + body parts ---
	var t0 := Time.get_ticks_msec()
	MorrowindNPCAssembler.debug_mode = true
	var assembled = MorrowindNPCAssembler.assemble(npc, race)
	var t1 := Time.get_ticks_msec()

	if not assembled:
		_stage_lines.append("\n[color=red]FAIL: Assembly returned null[/color]")
		_update_info()
		return

	_npc_container.add_child(assembled)
	_skeleton = _find_skeleton(assembled)

	if not _skeleton:
		_stage_lines.append("\n[color=red]FAIL: No Skeleton3D in assembled NPC[/color]")
		_update_info()
		return

	_stage_lines.append("\n[color=yellow]Stage 1: Skeleton + Body Parts[/color]  (%d ms)" % (t1 - t0))
	_stage_lines.append("  Skeleton: %s (%d bones)" % [
		"xbase_animkna.nif" if is_beast else "xbase_anim.nif",
		_skeleton.get_bone_count()])

	# --- STAGE 2: Analyze attached meshes ---
	var mesh_count := 0
	var skinned_count := 0
	var static_count := 0
	var slot_names := PackedStringArray()

	for child in _skeleton.get_children():
		if child is MeshInstance3D:
			mesh_count += 1
			if child.skin:
				skinned_count += 1
			else:
				static_count += 1
			slot_names.append(child.name)

	_stage_lines.append("\n[color=yellow]Stage 2: Body Parts Attached[/color]")
	_stage_lines.append("  Meshes: %d (skinned: %d, static: %d)" % [mesh_count, skinned_count, static_count])
	for sn in slot_names:
		_stage_lines.append("    - %s" % sn)

	var race_parts = esm.get_body_parts_for_race(npc.race_id, is_female)
	_stage_lines.append("  Race body parts available: %d" % race_parts.size())

	if mesh_count == 0:
		_stage_lines.append("  [color=red]WARNING: No meshes attached![/color]")

	# --- STAGE 3: Rename bones to profile names ---
	var t2 := Time.get_ticks_msec()
	var remap: Dictionary = RetargetSetup.build_remap(_skeleton)
	var rename_result: Dictionary = RetargetSetup.rename_bones_to_profile(_skeleton)
	var t3 := Time.get_ticks_msec()

	_stage_lines.append("\n[color=yellow]Stage 3: Bone Renaming[/color]  (%d ms)" % (t3 - t2))
	_stage_lines.append("  Renamed: %d bones" % rename_result.size())

	var expected_bones := ["Hips", "Spine", "Chest", "Head", "LeftHand", "RightHand", "LeftFoot", "RightFoot"]
	var found := 0
	for bone_name in expected_bones:
		if _skeleton.find_bone(bone_name) >= 0:
			found += 1
	_stage_lines.append("  Key profile bones: %d/%d %s" % [found, expected_bones.size(),
		"[color=green]OK[/color]" if found == expected_bones.size() else "[color=red]MISSING[/color]"])

	var sample_count := 0
	for old_name: String in rename_result:
		if sample_count >= 4:
			break
		_stage_lines.append("    %s -> %s" % [old_name, rename_result[old_name]])
		sample_count += 1
	if rename_result.size() > 4:
		_stage_lines.append("    ... and %d more" % (rename_result.size() - 4))

	# --- STAGE 4: BoneMap verification ---
	var bone_map = SPA.create_bone_map(_skeleton)
	var mapped: int = SPA.count_mapped_bones(bone_map) if bone_map else 0

	_stage_lines.append("\n[color=yellow]Stage 4: BoneMap Verification[/color]")
	_stage_lines.append("  Profile bones mapped: %d  %s" % [mapped,
		"[color=green]OK[/color]" if mapped > 0 else "[color=red]FAIL[/color]"])

	# --- STAGE 5: Animation loading ---
	var t4 := Time.get_ticks_msec()
	var anim_count := _load_animations(is_female, is_beast, remap)
	var t5 := Time.get_ticks_msec()

	_stage_lines.append("\n[color=yellow]Stage 5: Animations[/color]  (%d ms)" % (t5 - t4))
	_stage_lines.append("  Loaded: %d animations" % anim_count)

	var anim_player = _find_animation_player(_skeleton)
	if anim_player and anim_player.has_animation_library(""):
		var lib = anim_player.get_animation_library("")
		var anim_names = lib.get_animation_list()
		for i in mini(anim_names.size(), 8):
			_stage_lines.append("    - %s" % anim_names[i])
		if anim_names.size() > 8:
			_stage_lines.append("    ... and %d more" % (anim_names.size() - 8))

	# Summary
	_stage_lines.append("\n[color=green]Assembly complete[/color] — Total: %d ms" % (t5 - t0))

	_update_info()
	_build_bone_visualization()


# =============================================================================
# ANIMATION LOADING
# =============================================================================

func _load_animations(is_female: bool, is_beast: bool, remap: Dictionary) -> int:
	var anim_path: String
	if is_beast:
		anim_path = "meshes/xbase_animkna.kf"
	elif is_female:
		anim_path = "meshes/xbase_anim_female.kf"
	else:
		anim_path = "meshes/xbase_anim.kf"

	var anim_player = _find_animation_player(_skeleton)
	if not anim_player:
		anim_player = AnimationPlayer.new()
		anim_player.name = "AnimationPlayer"
		_skeleton.add_child(anim_player)

	var bsa = get_node_or_null("/root/BSAManager")
	if not bsa:
		return 0

	if not bsa.has_file(anim_path):
		return 0

	var kf_data: PackedByteArray = bsa.extract_file(anim_path)
	if kf_data.is_empty():
		return 0

	var loader := NIFKFLoader.new()
	var animations: Dictionary = loader.load_kf_buffer(kf_data, _skeleton)
	if animations.is_empty():
		return 0

	var lib := AnimationLibrary.new()
	for anim_name: String in animations:
		lib.add_animation(anim_name, animations[anim_name])

	# Remap bone tracks from Bip01 -> profile names
	if not remap.is_empty():
		lib = RetargetSetup.remap_library(lib, remap)

	if anim_player.has_animation_library(""):
		anim_player.remove_animation_library("")
	anim_player.add_animation_library("", lib)

	return lib.get_animation_list().size()


# =============================================================================
# BONE VISUALIZATION
# =============================================================================

func _build_bone_visualization() -> void:
	for child in _bone_container.get_children():
		child.queue_free()

	if not _skeleton:
		return

	# Must create fresh — rename_bones_to_profile clears cached metadata
	var bone_map = SPA.create_bone_map(_skeleton)

	for i in _skeleton.get_bone_count():
		var bone_name := _skeleton.get_bone_name(i)
		var global_pose := _skeleton.get_bone_global_rest(i)

		var is_mapped := false
		if bone_map and bone_map.profile:
			for j in bone_map.profile.bone_size:
				var profile_name: String = bone_map.profile.get_bone_name(j)
				var skel_name: String = bone_map.get_skeleton_bone_name(profile_name)
				if skel_name == bone_name:
					is_mapped = true
					break

		var sphere := SphereMesh.new()
		sphere.radius = 0.015 if is_mapped else 0.01
		sphere.height = sphere.radius * 2.0

		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color.GREEN if is_mapped else Color.RED
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

		var instance := MeshInstance3D.new()
		instance.mesh = sphere
		instance.material_override = mat
		instance.name = "Bone_%s" % bone_name
		_bone_container.add_child(instance)
		instance.global_transform.origin = global_pose.origin

		if is_mapped:
			var label := Label3D.new()
			label.text = bone_name
			label.font_size = 32
			label.pixel_size = 0.001
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.no_depth_test = true
			instance.add_child(label)
			label.position = Vector3(0, 0.03, 0)


# =============================================================================
# INPUT
# =============================================================================

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_orbiting = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_distance = maxf(1.0, _distance - 0.3)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_distance = minf(8.0, _distance + 0.3)
	elif event is InputEventMouseMotion and _orbiting:
		_yaw -= event.relative.x * 0.3
		_pitch = clampf(_pitch - event.relative.y * 0.3, -80.0, 80.0)

	if event is InputEventKey and event.pressed and not event.echo:
		if _npc_id_input and _npc_id_input.has_focus():
			return
		match event.keycode:
			KEY_1: _load_npc(PRESET_NPCS[0])
			KEY_2: _load_npc(PRESET_NPCS[1])
			KEY_3: _load_npc(PRESET_NPCS[2])
			KEY_4: _load_npc(PRESET_NPCS[3])
			KEY_5: _load_npc(PRESET_NPCS[4])
			KEY_B:
				_bones_visible = not _bones_visible
				_bone_container.visible = _bones_visible
			KEY_W:
				_toggle_wireframe()
			KEY_ENTER:
				if _npc_id_input:
					_npc_id_input.grab_focus()


func _toggle_wireframe() -> void:
	_wireframe = not _wireframe
	_set_wireframe_recursive(_npc_container, _wireframe)


func _set_wireframe_recursive(node: Node, enabled: bool) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node
		if mi.material_override and mi.material_override is StandardMaterial3D:
			mi.material_override.wireframe = enabled
		elif mi.mesh:
			for s in mi.mesh.get_surface_count():
				var mat = mi.mesh.surface_get_material(s)
				if mat is StandardMaterial3D:
					mat.wireframe = enabled
	for child in node.get_children():
		_set_wireframe_recursive(child, enabled)


# =============================================================================
# CAMERA
# =============================================================================

func _process(delta: float) -> void:
	if not _orbiting:
		_yaw += delta * 8.0
	_update_camera()


func _update_camera() -> void:
	if not _camera:
		return
	var ry := deg_to_rad(_yaw)
	var rp := deg_to_rad(_pitch)
	var offset := Vector3(
		_distance * cos(rp) * sin(ry),
		_distance * sin(rp),
		_distance * cos(rp) * cos(ry)
	)
	_camera.global_position = _center + offset
	_camera.look_at(_center)


# =============================================================================
# ENVIRONMENT SETUP
# =============================================================================

func _create_environment() -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40, 30, 0)
	light.shadow_enabled = true
	add_child(light)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.1, 0.12, 0.18)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.35, 0.35, 0.45)
	env.ambient_light_energy = 0.8

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(6, 6)
	ground.mesh = plane
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.12, 0.12, 0.18)
	ground.material_override = gmat
	add_child(ground)


func _create_camera() -> void:
	_camera = Camera3D.new()
	_camera.current = true
	add_child(_camera)
	_update_camera()


# =============================================================================
# UI SETUP
# =============================================================================

func _create_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)

	# Info panel (left side)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.offset_right = 460
	panel.offset_bottom = 600

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.6)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", style)

	_info_label = RichTextLabel.new()
	_info_label.bbcode_enabled = true
	_info_label.fit_content = true
	_info_label.scroll_active = true
	_info_label.custom_minimum_size = Vector2(440, 580)
	panel.add_child(_info_label)
	canvas.add_child(panel)

	# NPC ID input (top-right)
	var input_panel := PanelContainer.new()
	input_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	input_panel.offset_left = -310
	input_panel.offset_bottom = 40

	var input_style := StyleBoxFlat.new()
	input_style.bg_color = Color(0, 0, 0, 0.6)
	input_style.set_corner_radius_all(4)
	input_style.set_content_margin_all(6)
	input_panel.add_theme_stylebox_override("panel", input_style)

	var hbox := HBoxContainer.new()
	var label := Label.new()
	label.text = "NPC ID: "
	label.add_theme_font_size_override("font_size", 14)
	hbox.add_child(label)

	_npc_id_input = LineEdit.new()
	_npc_id_input.placeholder_text = "e.g. fargoth"
	_npc_id_input.custom_minimum_size = Vector2(180, 0)
	_npc_id_input.text_submitted.connect(_on_npc_id_submitted)
	hbox.add_child(_npc_id_input)

	input_panel.add_child(hbox)
	canvas.add_child(input_panel)

	# Controls legend (bottom)
	var legend := Label.new()
	legend.text = "1-5: Presets  |  B: Bones  |  W: Wireframe  |  Enter: NPC ID  |  RMB: Orbit  |  Scroll: Zoom"
	legend.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	legend.offset_top = -30
	legend.add_theme_font_size_override("font_size", 13)
	legend.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	legend.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	canvas.add_child(legend)


# =============================================================================
# UTILITIES
# =============================================================================

func _on_npc_id_submitted(text: String) -> void:
	var trimmed := text.strip_edges()
	if not trimmed.is_empty():
		_load_npc(trimmed)
	_npc_id_input.release_focus()


func _clear_current() -> void:
	_skeleton = null
	for child in _npc_container.get_children():
		child.queue_free()
	for child in _bone_container.get_children():
		child.queue_free()
	_bone_container.visible = false
	_bones_visible = false


func _update_info() -> void:
	if _info_label:
		_info_label.text = "\n".join(_stage_lines)


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var result := _find_skeleton(child)
		if result:
			return result
	return null


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var result := _find_animation_player(child)
		if result:
			return result
	return null
