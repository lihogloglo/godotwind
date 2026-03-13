## Body Part Diagnostic — Focused test for normal flipping & hand attachment bugs
##
## Uses MorrowindNPCAssembler.assemble() directly (NO duplicated logic).
## Overlays diagnostic visualizations to expose the two known bugs:
##   1. Left-side normals flipped → dark left limbs
##   2. Hands not properly attached to skeleton
##
## Controls:
##   N = toggle normal visualization (world-space normals as RGB)
##   H = toggle hand/bone markers
##   B = toggle ALL bone markers
##   W = toggle wireframe
##   1-5 = preset NPCs
##   RMB drag = orbit, scroll = zoom
@tool
@warning_ignore("untyped_declaration", "unsafe_method_access", "inferred_declaration")
extends Node3D

const MorrowindNPCAssembler := preload("res://src/core/character/morrowind/morrowind_npc_assembler.gd")
const BodyPartSlots := preload("res://src/core/character/morrowind/morrowind_body_part_slots.gd")

const PRESET_NPCS := [
	"fargoth",            # 1 - Male Wood Elf
	"caius cosades",      # 2 - Male Imperial
	"ranis athrys",       # 3 - Female Dark Elf
	"arrille",            # 4 - Male High Elf
	"sugar-lips habasi",  # 5 - Female Khajiit (beast)
]

# Normal debug shader (loaded once)
var _normal_shader: Shader = null
var _normal_debug_mat: ShaderMaterial = null

# Scene nodes
var _camera: Camera3D
var _info_label: RichTextLabel
var _npc_container: Node3D
var _marker_container: Node3D
var _skeleton: Skeleton3D

# Camera orbit
var _yaw := 20.0
var _pitch := -10.0
var _distance := 3.0
var _center := Vector3(0, 0.8, 0)
var _orbiting := false

# Toggle states
var _normal_vis := false
var _hand_markers := false
var _all_bones := false
var _wireframe := false

# Stashed original materials for normal vis toggle
var _original_materials: Dictionary = {}  # MeshInstance3D -> material

# Diagnostic results
var _diag_lines := PackedStringArray()
var _current_npc_id := ""


func _ready() -> void:
	_setup_scene()
	_setup_ui()

	# Load normal debug shader
	_normal_shader = load("res://src/tools/shaders/normal_debug.gdshader") as Shader
	if _normal_shader:
		_normal_debug_mat = ShaderMaterial.new()
		_normal_debug_mat.shader = _normal_shader

	_npc_container = Node3D.new()
	_npc_container.name = "NPCContainer"
	add_child(_npc_container)

	_marker_container = Node3D.new()
	_marker_container.name = "Markers"
	_marker_container.visible = false
	add_child(_marker_container)

	await get_tree().process_frame
	await get_tree().process_frame

	await _ensure_data_loaded()
	_load_npc(PRESET_NPCS[0])


# =============================================================================
# DATA LOADING
# =============================================================================

func _ensure_data_loaded() -> void:
	var esm = get_node_or_null("/root/ESMManager")
	if esm and not esm.npcs.is_empty():
		return

	_show_status("[b]Loading game data...[/b]")

	var data_path: String = SettingsManager.get_data_path()
	if data_path.is_empty():
		data_path = SettingsManager.auto_detect_installation()
		if data_path.is_empty():
			_show_status("[color=red]No Morrowind data path configured[/color]")
			return

	var bsa = get_node_or_null("/root/BSAManager")
	if bsa:
		bsa.load_archives_from_directory(data_path)

	if esm:
		var esm_path := data_path.path_join(SettingsManager.get_esm_file())
		esm.load_file(esm_path)
		await get_tree().process_frame


func _show_status(text: String) -> void:
	if _info_label:
		_info_label.text = text


# =============================================================================
# NPC LOADING — uses assembler directly
# =============================================================================

func _load_npc(npc_id: String) -> void:
	_clear()
	_current_npc_id = npc_id
	_diag_lines = PackedStringArray()

	var esm = get_node_or_null("/root/ESMManager")
	if not esm:
		_diag_lines.append("[color=red]ESMManager not available[/color]")
		_update_info()
		return

	# Trigger on-demand record creation from C# cache
	var _out_type: Array = [""]
	ESMManager.get_any_record(npc_id, _out_type)
	var npc = esm.get_npc(npc_id)
	if not npc:
		_diag_lines.append("[color=red]NPC '%s' not found[/color]" % npc_id)
		_update_info()
		return

	var race = esm.get_race(npc.race_id)
	if not race:
		_diag_lines.append("[color=red]Race '%s' not found[/color]" % npc.race_id)
		_update_info()
		return

	_diag_lines.append("[b]Body Part Diagnostic[/b]")
	_diag_lines.append("NPC: [color=yellow]%s[/color] (%s)" % [npc.name, npc_id])
	_diag_lines.append("Race: %s | %s | %s" % [
		race.name,
		"Female" if npc.is_female() else "Male",
		"Beast" if race.is_beast() else "Humanoid"])
	_diag_lines.append("")

	# Assemble using the ACTUAL assembler — no duplicated logic
	MorrowindNPCAssembler.debug_mode = true
	var assembled = MorrowindNPCAssembler.assemble(npc, race)
	MorrowindNPCAssembler.debug_mode = false

	if not assembled:
		_diag_lines.append("[color=red]Assembly returned null[/color]")
		_update_info()
		return

	_npc_container.add_child(assembled)
	_skeleton = _find_skeleton(assembled)

	if not _skeleton:
		_diag_lines.append("[color=red]No Skeleton3D found[/color]")
		_update_info()
		return

	# Run diagnostics
	_diagnose_mesh_parts()
	_diagnose_normals()
	_diagnose_hand_attachment()
	_build_markers()
	_update_info()


# =============================================================================
# DIAGNOSTICS
# =============================================================================

## Catalog all mesh instances under the skeleton
func _diagnose_mesh_parts() -> void:
	_diag_lines.append("[color=cyan]--- Mesh Parts ---[/color]")

	var skinned := 0
	var static_attach := 0
	var orphan := 0

	for child in _skeleton.get_children():
		if child is MeshInstance3D:
			var mi: MeshInstance3D = child
			if mi.skin:
				skinned += 1
				_diag_lines.append("  [S] %s  (%d binds)" % [mi.name, mi.skin.get_bind_count()])
			else:
				orphan += 1
				_diag_lines.append("  [?] %s  (no skin, no BoneAttachment)" % mi.name)
		elif child is BoneAttachment3D:
			var attach: BoneAttachment3D = child
			for sub in attach.get_children():
				if sub is MeshInstance3D:
					static_attach += 1
					var bone_idx := _skeleton.find_bone(attach.bone_name)
					var status := "[color=green]OK[/color]" if bone_idx >= 0 else "[color=red]MISSING[/color]"
					_diag_lines.append("  [A] %s -> bone '%s' %s" % [sub.name, attach.bone_name, status])

	_diag_lines.append("Totals: %d skinned, %d static (attached), %d orphan" % [skinned, static_attach, orphan])
	_diag_lines.append("")


## Check for normal direction issues — compare left vs right mesh AABBs and normals
func _diagnose_normals() -> void:
	_diag_lines.append("[color=cyan]--- Normal Check ---[/color]")
	_diag_lines.append("Press [b]N[/b] to toggle normal visualization")
	_diag_lines.append("  Correct: left-side normals should MIRROR right-side")
	_diag_lines.append("  Bug: left-side appears same color as right (not mirrored)")

	# Check if any left-side parts exist
	var has_left := false
	var has_right := false
	_walk_meshes(_skeleton, func(mi: MeshInstance3D, _p):
		var n: String = mi.name.to_lower()
		if n.contains("_l") or n.contains("left"):
			has_left = true
		if n.contains("_r") or n.contains("right"):
			has_right = true
	)

	if has_left and has_right:
		_diag_lines.append("  Both L/R parts present [color=green]OK[/color]")
	elif has_right and not has_left:
		_diag_lines.append("  [color=red]Only right-side parts found — mirroring may have failed[/color]")
	_diag_lines.append("")


## Check hand mesh positions relative to hand bones
func _diagnose_hand_attachment() -> void:
	_diag_lines.append("[color=cyan]--- Hand Attachment ---[/color]")

	for hand_name in ["RightHand", "LeftHand", "Bip01 R Hand", "Bip01 L Hand",
			"bip01 r hand", "bip01 l hand"]:
		var bone_idx := _skeleton.find_bone(hand_name)
		if bone_idx >= 0:
			var bone_pos := _skeleton.get_bone_global_rest(bone_idx).origin
			_diag_lines.append("  Bone '%s': pos=(%.3f, %.3f, %.3f)" % [
				hand_name, bone_pos.x, bone_pos.y, bone_pos.z])

	# Find hand meshes and check their world-space center
	_walk_meshes(_skeleton, func(mi: MeshInstance3D, parent_name: String):
		var n: String = mi.name.to_lower()
		if not (n.contains("hand") or parent_name.to_lower().contains("hand")):
			return

		var aabb := mi.get_aabb()
		var center_local := aabb.get_center()
		var center_world := mi.global_transform * center_local

		# Find closest hand bone
		var closest_bone := ""
		var closest_dist := INF
		for bone_candidate in ["bip01 r hand", "bip01 l hand"]:
			var bi := _skeleton.find_bone(bone_candidate)
			if bi < 0:
				# Try profile names
				for alt in ["RightHand", "LeftHand"]:
					bi = _skeleton.find_bone(alt)
					if bi >= 0:
						break
			if bi >= 0:
				var bp := _skeleton.get_bone_global_rest(bi).origin
				var d := center_world.distance_to(bp)
				if d < closest_dist:
					closest_dist = d
					closest_bone = bone_candidate

		var status: String
		if closest_dist < 0.15:
			status = "[color=green]%.3f m[/color]" % closest_dist
		elif closest_dist < 0.4:
			status = "[color=yellow]%.3f m[/color]" % closest_dist
		else:
			status = "[color=red]%.3f m — DETACHED[/color]" % closest_dist

		_diag_lines.append("  Mesh '%s': center=(%.3f,%.3f,%.3f) dist_to_%s=%s" % [
			mi.name, center_world.x, center_world.y, center_world.z,
			closest_bone, status])
	)

	# Also check BoneAttachment-based hands
	for child in _skeleton.get_children():
		if child is BoneAttachment3D:
			var attach: BoneAttachment3D = child
			if not attach.bone_name.to_lower().contains("hand"):
				continue
			var bone_idx := _skeleton.find_bone(attach.bone_name)
			if bone_idx < 0:
				_diag_lines.append("  [color=red]BoneAttachment '%s' -> bone '%s' NOT FOUND[/color]" % [
					attach.name, attach.bone_name])
			for sub in attach.get_children():
				if sub is MeshInstance3D:
					var mi: MeshInstance3D = sub
					_diag_lines.append("  Attach '%s' bone='%s' mesh='%s' xform_origin=(%.3f,%.3f,%.3f)" % [
						attach.name, attach.bone_name, mi.name,
						mi.transform.origin.x, mi.transform.origin.y, mi.transform.origin.z])

	_diag_lines.append("")


# =============================================================================
# BONE MARKERS
# =============================================================================

func _build_markers() -> void:
	for child in _marker_container.get_children():
		child.queue_free()

	if not _skeleton:
		return

	# Key bones to always mark (hands + feet for attachment verification)
	var key_bones := ["bip01 r hand", "bip01 l hand", "bip01 r foot", "bip01 l foot",
		"RightHand", "LeftHand", "RightFoot", "LeftFoot"]

	for i in _skeleton.get_bone_count():
		var bone_name := _skeleton.get_bone_name(i)
		var global_rest := _skeleton.get_bone_global_rest(i)
		var is_key := bone_name.to_lower() in ["bip01 r hand", "bip01 l hand", "bip01 r foot", "bip01 l foot"]
		if not is_key:
			for k in key_bones:
				if bone_name == k:
					is_key = true
					break

		var sphere := SphereMesh.new()
		sphere.radius = 0.02 if is_key else 0.008
		sphere.height = sphere.radius * 2.0

		var mat := StandardMaterial3D.new()
		if is_key:
			mat.albedo_color = Color.YELLOW
		elif bone_name.to_lower().contains(" l ") or bone_name.contains("Left"):
			mat.albedo_color = Color(0.3, 0.6, 1.0)
		elif bone_name.to_lower().contains(" r ") or bone_name.contains("Right"):
			mat.albedo_color = Color(1.0, 0.4, 0.3)
		else:
			mat.albedo_color = Color(0.5, 0.5, 0.5, 0.5)
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.no_depth_test = is_key

		var instance := MeshInstance3D.new()
		instance.mesh = sphere
		instance.material_override = mat
		instance.name = "Bone_%s" % bone_name
		instance.position = global_rest.origin

		# Labels for key bones only
		if is_key or _all_bones:
			var label := Label3D.new()
			label.text = bone_name
			label.font_size = 28
			label.pixel_size = 0.001
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.no_depth_test = true
			label.modulate = Color(1, 1, 0.7, 0.9)
			label.position = Vector3(0, 0.03, 0)
			instance.add_child(label)

		# Tag for filtering: key bones are "hand_marker" group
		if is_key:
			instance.set_meta("is_hand_marker", true)
		else:
			instance.set_meta("is_hand_marker", false)

		_marker_container.add_child(instance)

	# Draw bone connections
	_draw_bone_lines()


func _draw_bone_lines() -> void:
	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.4, 0.6, 0.9, 0.4)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true

	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in _skeleton.get_bone_count():
		var parent_idx := _skeleton.get_bone_parent(i)
		if parent_idx >= 0:
			im.surface_add_vertex(_skeleton.get_bone_global_rest(parent_idx).origin)
			im.surface_add_vertex(_skeleton.get_bone_global_rest(i).origin)
	im.surface_end()

	var mi := MeshInstance3D.new()
	mi.mesh = im
	mi.material_override = mat
	mi.name = "BoneLines"
	_marker_container.add_child(mi)


# =============================================================================
# TOGGLE MODES
# =============================================================================

## Toggle normal visualization — replaces all materials with normal debug shader
func _toggle_normal_vis() -> void:
	_normal_vis = not _normal_vis

	if not _normal_debug_mat:
		return

	if _normal_vis:
		# Stash originals and apply debug shader
		_original_materials.clear()
		_walk_meshes(_npc_container, func(mi: MeshInstance3D, _p):
			_original_materials[mi] = mi.material_override
			mi.material_override = _normal_debug_mat
		)
	else:
		# Restore originals
		for mi: MeshInstance3D in _original_materials:
			if is_instance_valid(mi):
				mi.material_override = _original_materials[mi]
		_original_materials.clear()


func _toggle_hand_markers() -> void:
	_hand_markers = not _hand_markers
	if _hand_markers:
		_marker_container.visible = true
		# Show only key markers
		for child in _marker_container.get_children():
			if child is MeshInstance3D and child.has_meta("is_hand_marker"):
				child.visible = child.get_meta("is_hand_marker")
			elif child.name == "BoneLines":
				child.visible = false
	elif not _all_bones:
		_marker_container.visible = false


func _toggle_all_bones() -> void:
	_all_bones = not _all_bones
	_marker_container.visible = _all_bones or _hand_markers
	for child in _marker_container.get_children():
		child.visible = true


func _toggle_wireframe() -> void:
	_wireframe = not _wireframe
	_walk_meshes(_npc_container, func(mi: MeshInstance3D, _p):
		if mi.material_override and mi.material_override is StandardMaterial3D:
			mi.material_override.wireframe = _wireframe
		elif not _normal_vis and mi.mesh:
			for s in mi.mesh.get_surface_count():
				var mat = mi.mesh.surface_get_material(s)
				if mat is StandardMaterial3D:
					mat.wireframe = _wireframe
	)


# =============================================================================
# INPUT
# =============================================================================

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_orbiting = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_distance = maxf(0.5, _distance - 0.3)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_distance = minf(8.0, _distance + 0.3)
	elif event is InputEventMouseMotion and _orbiting:
		_yaw -= event.relative.x * 0.3
		_pitch = clampf(_pitch - event.relative.y * 0.3, -80.0, 80.0)

	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1: _load_npc(PRESET_NPCS[0])
			KEY_2: _load_npc(PRESET_NPCS[1])
			KEY_3: _load_npc(PRESET_NPCS[2])
			KEY_4: _load_npc(PRESET_NPCS[3])
			KEY_5: _load_npc(PRESET_NPCS[4])
			KEY_N: _toggle_normal_vis()
			KEY_H: _toggle_hand_markers()
			KEY_B: _toggle_all_bones()
			KEY_W: _toggle_wireframe()


# =============================================================================
# CAMERA
# =============================================================================

func _process(_delta: float) -> void:
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
# SCENE SETUP
# =============================================================================

func _setup_scene() -> void:
	# Camera
	_camera = Camera3D.new()
	_camera.current = true
	add_child(_camera)

	# Key light from right-front (to make normal issues visible)
	var key_light := DirectionalLight3D.new()
	key_light.name = "KeyLight"
	key_light.rotation_degrees = Vector3(-40, 45, 0)
	key_light.light_energy = 1.3
	key_light.shadow_enabled = true
	add_child(key_light)

	# Weak fill from left (if normals are wrong, left side stays dark)
	var fill := DirectionalLight3D.new()
	fill.name = "FillLight"
	fill.rotation_degrees = Vector3(-25, -130, 0)
	fill.light_energy = 0.25
	fill.light_color = Color(0.7, 0.75, 1.0)
	add_child(fill)

	# Environment
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.12, 0.13, 0.18)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.3, 0.3, 0.35)
	env.ambient_light_energy = 0.5
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	add_child(WorldEnvironment.new())
	get_child(get_child_count() - 1).environment = env

	# Ground
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(6, 6)
	ground.mesh = plane
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.15, 0.15, 0.2)
	ground.material_override = gmat
	add_child(ground)


func _setup_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.offset_right = 520
	panel.offset_bottom = 600

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.7)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", style)

	_info_label = RichTextLabel.new()
	_info_label.bbcode_enabled = true
	_info_label.fit_content = true
	_info_label.scroll_active = true
	_info_label.custom_minimum_size = Vector2(500, 580)
	panel.add_child(_info_label)
	canvas.add_child(panel)

	# Controls legend
	var legend := Label.new()
	legend.text = "1-5: NPCs | N: Normals | H: Hands | B: Bones | W: Wire | RMB: Orbit | Scroll: Zoom"
	legend.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	legend.offset_top = -28
	legend.add_theme_font_size_override("font_size", 13)
	legend.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	legend.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	canvas.add_child(legend)


# =============================================================================
# UTILITIES
# =============================================================================

func _clear() -> void:
	_skeleton = null
	_original_materials.clear()
	_normal_vis = false
	for child in _npc_container.get_children():
		child.queue_free()
	for child in _marker_container.get_children():
		child.queue_free()
	_marker_container.visible = false
	_hand_markers = false
	_all_bones = false


func _update_info() -> void:
	if _info_label:
		# Append mode status
		var mode_lines := PackedStringArray()
		mode_lines.append_array(_diag_lines)
		mode_lines.append("[color=gray]--- Modes ---[/color]")
		mode_lines.append("Normal vis: %s | Hand markers: %s | All bones: %s | Wire: %s" % [
			"[color=green]ON[/color]" if _normal_vis else "off",
			"[color=green]ON[/color]" if _hand_markers else "off",
			"[color=green]ON[/color]" if _all_bones else "off",
			"[color=green]ON[/color]" if _wireframe else "off",
		])
		_info_label.text = "\n".join(mode_lines)


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var result := _find_skeleton(child)
		if result:
			return result
	return null


## Walk all MeshInstance3D nodes recursively, calling callback(mi, parent_name)
func _walk_meshes(node: Node, callback: Callable) -> void:
	var parent_name: String = str(node.name) if node else ""
	for child in node.get_children():
		if child is MeshInstance3D:
			callback.call(child, parent_name)
		_walk_meshes(child, callback)
