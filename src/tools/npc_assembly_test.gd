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
##   Left/Right = cycle animations
##   Space = play/pause animation
##   P = print KF-vs-actual bone pose comparison
##   T = toggle bone pose comparison panel
@tool
@warning_ignore("untyped_declaration", "unsafe_method_access")
extends Node3D

const LoadingScreenScript := preload("res://src/core/ui/loading_screen.gd")
const MorrowindNPCAssembler := preload("res://src/core/character/morrowind/morrowind_npc_assembler.gd")
const RetargetSetup := preload("res://src/core/animation/skeleton_utils.gd")
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

# Animation playback
var _anim_player: AnimationPlayer = null
var _anim_list: PackedStringArray = PackedStringArray()
var _anim_index: int = 0
var _anim_playing: bool = false
var _anim_label: RichTextLabel = null
var _pose_label: RichTextLabel = null
var _pose_visible: bool = false

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

	# Load game data with loading screen
	var loading := LoadingScreenScript.new()
	add_child(loading)
	var success := await loading.load_game_data()
	loading.queue_free()
	if not success:
		return

	_load_npc(PRESET_NPCS[0])




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

	# Trigger on-demand record creation from C# cache before lookup
	var _out_type: Array = [""]
	ESMManager.get_any_record(npc_id, _out_type)
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

	# --- STAGE 4: BoneMap verification (SPA removed — skeleton_profile_adapter deleted) ---
	var mapped: int = _skeleton.get_bone_count() if _skeleton else 0

	_stage_lines.append("\n[color=yellow]Stage 4: Skeleton Bones[/color]")
	_stage_lines.append("  Bone count: %d  %s" % [mapped,
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

	# --- STAGE 6: Animation playback setup ---
	_anim_player = _find_animation_player(_skeleton)
	if _anim_player:
		_anim_list = _anim_player.get_animation_list()
		_anim_index = 0
		_anim_playing = false
		# Find and auto-play Idle if available
		for i in _anim_list.size():
			if _anim_list[i].to_lower() == "idle":
				_anim_index = i
				_play_current_animation()
				break
		_stage_lines.append("\n[color=yellow]Stage 6: Animation Playback[/color]")
		_stage_lines.append("  %d animations available" % _anim_list.size())
		_stage_lines.append("  [color=cyan]Left/Right[/color] = cycle, [color=cyan]Space[/color] = play/pause")
		_stage_lines.append("  [color=cyan]P[/color] = bone pose comparison, [color=cyan]T[/color] = toggle panel")

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

	for i in _skeleton.get_bone_count():
		var bone_name := _skeleton.get_bone_name(i)
		var global_pose := _skeleton.get_bone_global_rest(i)

		# All bones shown as mapped (SPA removed — skeleton_profile_adapter deleted)
		var is_mapped := true

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
			KEY_LEFT:
				_cycle_animation(-1)
			KEY_RIGHT:
				_cycle_animation(1)
			KEY_SPACE:
				_toggle_animation_playback()
			KEY_P:
				_print_bone_pose_comparison()
			KEY_T:
				_pose_visible = not _pose_visible
				if _pose_label and _pose_label.get_parent():
					_pose_label.get_parent().visible = _pose_visible


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
# ANIMATION PLAYBACK
# =============================================================================

func _cycle_animation(direction: int) -> void:
	if _anim_list.is_empty():
		return
	_anim_index = wrapi(_anim_index + direction, 0, _anim_list.size())
	_play_current_animation()


func _play_current_animation() -> void:
	if not _anim_player or _anim_list.is_empty():
		return
	var anim_name: String = _anim_list[_anim_index]
	_anim_player.play(anim_name)
	_anim_playing = true
	_update_animation_label()


func _toggle_animation_playback() -> void:
	if not _anim_player:
		return
	if _anim_playing:
		_anim_player.pause()
		_anim_playing = false
	else:
		if _anim_player.current_animation.is_empty() and not _anim_list.is_empty():
			_play_current_animation()
		else:
			_anim_player.play()
			_anim_playing = true
	_update_animation_label()


func _update_animation_label() -> void:
	if not _anim_label:
		return
	if _anim_list.is_empty():
		_anim_label.text = "[color=gray]No animations[/color]"
		return
	var anim_name: String = _anim_list[_anim_index]
	var status := "[color=green]PLAYING[/color]" if _anim_playing else "[color=yellow]PAUSED[/color]"
	var anim: Animation = _anim_player.get_animation(anim_name) if _anim_player.has_animation(anim_name) else null
	var length_str := "%.2fs" % anim.length if anim else "?"
	var track_count := anim.get_track_count() if anim else 0
	_anim_label.text = "[b]Animation:[/b] [color=cyan]%s[/color] (%d/%d)  %s\n" % [
		anim_name, _anim_index + 1, _anim_list.size(), status]
	_anim_label.text += "Length: %s  |  Tracks: %d  |  Loop: %s" % [
		length_str, track_count,
		"Yes" if anim and anim.loop_mode != Animation.LOOP_NONE else "No"]


## Print KF-vs-actual bone pose comparison to console and update panel
func _print_bone_pose_comparison() -> void:
	if not _skeleton or not _anim_player or _anim_list.is_empty():
		print("[NPC Test] No skeleton or animations to compare")
		return

	var anim_name: String = _anim_list[_anim_index]
	var anim: Animation = _anim_player.get_animation(anim_name)
	if not anim:
		print("[NPC Test] Animation '%s' not found" % anim_name)
		return

	var lines := PackedStringArray()
	lines.append("[b]KF vs Actual — '%s' at t=%.3f[/b]\n" % [
		anim_name, _anim_player.current_animation_position])

	var current_time: float = _anim_player.current_animation_position

	for track_idx in anim.get_track_count():
		var path := anim.track_get_path(track_idx)
		if path.get_subname_count() == 0:
			continue
		var bone_name := String(path.get_subname(0))
		var bone_idx := _skeleton.find_bone(bone_name)
		if bone_idx < 0:
			lines.append("[color=red]%s: NOT IN SKELETON[/color]" % bone_name)
			continue

		var track_type := anim.track_get_type(track_idx)

		# Get KF value at current time
		if track_type == Animation.TYPE_ROTATION_3D:
			var kf_rot: Quaternion = anim.rotation_track_interpolate(track_idx, current_time)
			var actual_rot: Quaternion = _skeleton.get_bone_pose_rotation(bone_idx)
			var angle_diff := rad_to_deg(kf_rot.angle_to(actual_rot))
			var color := "green" if angle_diff < 1.0 else ("yellow" if angle_diff < 5.0 else "red")
			lines.append("[color=%s]%s ROT: diff=%.1f°[/color]  kf=%s  actual=%s" % [
				color, bone_name, angle_diff,
				_fmt_quat(kf_rot), _fmt_quat(actual_rot)])
		elif track_type == Animation.TYPE_POSITION_3D:
			var kf_pos: Vector3 = anim.position_track_interpolate(track_idx, current_time)
			var actual_pos: Vector3 = _skeleton.get_bone_pose_position(bone_idx)
			var dist := kf_pos.distance_to(actual_pos)
			var color := "green" if dist < 0.01 else ("yellow" if dist < 0.05 else "red")
			lines.append("[color=%s]%s POS: diff=%.4f[/color]  kf=%s  actual=%s" % [
				color, bone_name, dist,
				_fmt_vec3(kf_pos), _fmt_vec3(actual_pos)])

	var text := "\n".join(lines)

	# Print to console
	for line in lines:
		var stripped := line
		for tag in ["[color=green]", "[color=red]", "[color=yellow]", "[color=cyan]", "[color=gray]", "[/color]", "[b]", "[/b]"]:
			stripped = stripped.replace(tag, "")
		print("[Pose] %s" % stripped)

	# Update panel
	if _pose_label:
		_pose_label.text = text
		if _pose_label.get_parent():
			_pose_label.get_parent().visible = true
		_pose_visible = true


## Update the pose panel live while animation is playing
func _update_live_pose_panel() -> void:
	if not _pose_label or not _skeleton or not _anim_player:
		return
	if _anim_list.is_empty():
		return

	var anim_name: String = _anim_list[_anim_index]
	var anim: Animation = _anim_player.get_animation(anim_name) if _anim_player.has_animation(anim_name) else null
	if not anim:
		return

	var current_time: float = _anim_player.current_animation_position
	var lines := PackedStringArray()
	lines.append("[b]LIVE — '%s' t=%.3f[/b]\n" % [anim_name, current_time])

	# Show first 12 bone tracks for readability
	var shown := 0
	for track_idx in anim.get_track_count():
		if shown >= 12:
			lines.append("... (%d more tracks)" % (anim.get_track_count() - shown))
			break
		var path := anim.track_get_path(track_idx)
		if path.get_subname_count() == 0:
			continue
		var bone_name := String(path.get_subname(0))
		var bone_idx := _skeleton.find_bone(bone_name)
		if bone_idx < 0:
			continue
		var track_type := anim.track_get_type(track_idx)
		if track_type == Animation.TYPE_ROTATION_3D:
			var kf_rot: Quaternion = anim.rotation_track_interpolate(track_idx, current_time)
			var actual_rot: Quaternion = _skeleton.get_bone_pose_rotation(bone_idx)
			var angle_diff := rad_to_deg(kf_rot.angle_to(actual_rot))
			var color := "green" if angle_diff < 1.0 else ("yellow" if angle_diff < 5.0 else "red")
			lines.append("[color=%s]%s: %.1f°[/color]" % [color, bone_name, angle_diff])
			shown += 1

	_pose_label.text = "\n".join(lines)


func _fmt_quat(q: Quaternion) -> String:
	return "(%.3f, %.3f, %.3f, %.3f)" % [q.x, q.y, q.z, q.w]


func _fmt_vec3(v: Vector3) -> String:
	return "(%.3f, %.3f, %.3f)" % [v.x, v.y, v.z]


# =============================================================================
# CAMERA
# =============================================================================

func _process(delta: float) -> void:
	if not _orbiting:
		_yaw += delta * 8.0
	_update_camera()
	_update_animation_label()
	if _pose_visible and _anim_playing:
		_update_live_pose_panel()


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

	# Animation label (bottom-left, above legend)
	_anim_label = RichTextLabel.new()
	_anim_label.bbcode_enabled = true
	_anim_label.fit_content = true
	_anim_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_anim_label.offset_left = 10
	_anim_label.offset_top = -80
	_anim_label.offset_right = 600
	_anim_label.offset_bottom = -35
	_anim_label.add_theme_font_size_override("normal_font_size", 14)
	_anim_label.text = "[color=gray]No animation loaded[/color]"
	canvas.add_child(_anim_label)

	# Bone pose comparison panel (right side)
	var pose_panel := PanelContainer.new()
	pose_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	pose_panel.offset_left = -480
	var pose_style := StyleBoxFlat.new()
	pose_style.bg_color = Color(0, 0, 0, 0.7)
	pose_style.set_corner_radius_all(4)
	pose_style.set_content_margin_all(8)
	pose_panel.add_theme_stylebox_override("panel", pose_style)
	pose_panel.visible = false

	_pose_label = RichTextLabel.new()
	_pose_label.bbcode_enabled = true
	_pose_label.fit_content = false
	_pose_label.scroll_active = true
	_pose_label.custom_minimum_size = Vector2(460, 0)
	_pose_label.add_theme_font_size_override("normal_font_size", 12)
	_pose_label.text = "[color=gray]Press P to compare bone poses[/color]"
	pose_panel.add_child(_pose_label)
	canvas.add_child(pose_panel)
	# Store reference to parent panel for visibility toggle
	_pose_label = _pose_label
	_pose_label.get_parent().visible = false

	# Controls legend (bottom)
	var legend := Label.new()
	legend.text = "1-5: Presets  |  B: Bones  |  W: Wireframe  |  Left/Right: Anim  |  Space: Play  |  P: Pose  |  T: Panel"
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
