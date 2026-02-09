## Character Assembly Diagnostic Test
##
## Diagnoses why body parts cluster at skeleton root instead of correct positions.
## Three panels:
##   Left:   Skeleton-only visualization (bone spheres + labels)
##   Center: Assembled character with current inv_bind method
##   Right:  Assembled character with alternative inv_bind method
##
## Toggle between inv_bind methods with keys 1/2/3:
##   1 = Current (inv_bind * skin_transform)
##   2 = OpenMW-style (inv_bind only, no skin_transform)
##   3 = Fallback (skeleton global rest inverse)
##
## Press R to reload, D to dump debug info to console.
@tool
extends Node3D

@warning_ignore("untyped_declaration", "unsafe_method_access")

const NIFConverter := preload("res://src/core/nif/nif_converter.gd")
const MeshExtractor := preload("res://src/core/character/mixamo/mesh_extractor.gd")
const CS := preload("res://src/core/coordinate_system.gd")

# Inv bind modes
enum BindMode { COMPOSED, OPENMW, SKELETON_REST }
var _current_mode: BindMode = BindMode.COMPOSED

# Scene containers
var _skel_container: Node3D = null     # Left: skeleton only
var _char_container: Node3D = null     # Center: assembled character
var _alt_container: Node3D = null      # Right: alternative method
var _info_label: RichTextLabel = null

# Cached data
var _skeleton_template: Skeleton3D = null
var _body_part_data: Dictionary = {}   # slot_name -> MeshExtractor.MeshData array

# Slot coloring for visual identification
# Slot-to-bone mapping for the test (string slot names -> Bip01 bone names)
const TEST_SLOT_TO_BONE := {
	"HEAD": "bip01 head",
	"HAIR": "bip01 head",
	"NECK": "bip01 neck",
	"SKINS": "bip01 spine1",
	"CHEST": "bip01 spine1",
	"GROIN": "bip01 pelvis",
	"UPPER_ARM_R": "bip01 r upperarm",
	"FOREARM_R": "bip01 r forearm",
	"HAND_R": "bip01 r hand",
	"WRIST_R": "bip01 r forearm",
	"UPPER_LEG_R": "bip01 r thigh",
	"KNEE_R": "bip01 r calf",
	"ANKLE_R": "bip01 r foot",
	"FOOT_R": "bip01 r foot",
}

const SLOT_COLORS := {
	"HEAD": Color(1.0, 0.3, 0.3),       # Red
	"HAIR": Color(1.0, 0.5, 0.8),       # Pink
	"NECK": Color(1.0, 0.6, 0.3),       # Orange
	"SKINS": Color(0.3, 0.5, 1.0),      # Blue (chest+hands+wrists)
	"CHEST": Color(0.3, 0.5, 1.0),      # Blue
	"GROIN": Color(0.3, 0.3, 0.8),      # Dark blue
	"UPPER_ARM_R": Color(0.3, 0.8, 0.3),# Green
	"FOREARM_R": Color(0.4, 0.9, 0.4),  # Light green
	"HAND_R": Color(0.5, 1.0, 0.5),     # Pale green
	"WRIST_R": Color(0.6, 1.0, 0.6),    # Lighter green
	"UPPER_LEG_R": Color(0.9, 0.9, 0.2),# Yellow
	"KNEE_R": Color(0.8, 0.8, 0.3),     # Dark yellow
	"ANKLE_R": Color(0.7, 0.7, 0.4),    # Olive
	"FOOT_R": Color(0.6, 0.6, 0.5),     # Tan
}

# Known body part paths for Dark Elf male (common test race)
# "skins" file contains chest+hands+wrists as sub-meshes
const TEST_BODY_PARTS := {
	"SKINS": "meshes/b/b_n_dark elf_m_skins.nif",
	"UPPER_ARM_R": "meshes/b/b_n_dark elf_m_upper arm.nif",
	"FOREARM_R": "meshes/b/b_n_dark elf_m_forearm.nif",
	"GROIN": "meshes/b/b_n_dark elf_m_groin.nif",
	"UPPER_LEG_R": "meshes/b/b_n_dark elf_m_upper leg.nif",
	"KNEE_R": "meshes/b/b_n_dark elf_m_knee.nif",
	"ANKLE_R": "meshes/b/b_n_dark elf_m_ankle.nif",
	"FOOT_R": "meshes/b/b_n_dark elf_m_foot.nif",
	"NECK": "meshes/b/b_n_dark elf_m_neck.nif",
	"WRIST_R": "meshes/b/b_n_dark elf_m_wrist.nif",
	"HEAD": "meshes/b/b_n_dark elf_m_head_01.nif",
}


func _ready() -> void:
	_setup_scene()
	_setup_ui()

	# Wait for autoloads
	await get_tree().process_frame
	await get_tree().process_frame

	# Ensure BSA archives are loaded
	await _ensure_data_loaded()

	_load_all_data()
	_rebuild_all()


func _ensure_data_loaded() -> void:
	var bsa_mgr = get_node_or_null("/root/BSAManager")
	if not bsa_mgr:
		push_error("CharacterAssemblyTest: BSAManager not available")
		return

	# Check if already loaded (has files)
	if bsa_mgr.has_file("meshes\\xbase_anim.nif"):
		return

	_update_info_text("[b]Loading game data...[/b]")

	# Load BSA archives from Morrowind data path
	var data_path: String = SettingsManager.get_data_path()
	if data_path.is_empty():
		data_path = SettingsManager.auto_detect_installation()
		if data_path.is_empty():
			push_error("CharacterAssemblyTest: No Morrowind data path configured")
			return

	bsa_mgr.load_archives_from_directory(data_path)
	Log.info("character", "Loaded BSA archives from: %s" % data_path)

	await get_tree().process_frame


func _update_info_text(text: String) -> void:
	if _info_label:
		_info_label.text = text


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_1:
				_current_mode = BindMode.COMPOSED
				_rebuild_characters()
			KEY_2:
				_current_mode = BindMode.OPENMW
				_rebuild_characters()
			KEY_3:
				_current_mode = BindMode.SKELETON_REST
				_rebuild_characters()
			KEY_R:
				_load_all_data()
				_rebuild_all()
			KEY_D:
				_dump_debug_info()


# =============================================================================
# DATA LOADING
# =============================================================================

func _load_all_data() -> void:
	_skeleton_template = _load_skeleton()
	_body_part_data.clear()

	if not _skeleton_template:
		push_error("CharacterAssemblyTest: Failed to load skeleton")
		return

	var bsa_mgr = get_node_or_null("/root/BSAManager")
	if not bsa_mgr:
		push_error("CharacterAssemblyTest: BSAManager not available")
		return

	# Load body parts
	for slot_name in TEST_BODY_PARTS:
		var path: String = TEST_BODY_PARTS[slot_name]
		if bsa_mgr.has_file(path):
			var meshes := MeshExtractor.extract_from_bsa(path)
			if not meshes.is_empty():
				_body_part_data[slot_name] = meshes
			else:
				Log.warn("character", "No meshes from: %s" % path)
		else:
			Log.warn("character", "BSA missing: %s" % path)

	Log.info("character", "Loaded skeleton (%d bones) + %d body parts" % [
		_skeleton_template.get_bone_count(), _body_part_data.size()])


func _load_skeleton() -> Skeleton3D:
	var bsa_mgr = get_node_or_null("/root/BSAManager")
	if not bsa_mgr:
		return null

	var data: PackedByteArray = bsa_mgr.extract_file("meshes\\xbase_anim.nif")
	if data.is_empty():
		return null

	var converter := NIFConverter.new()
	converter.load_textures = false
	converter.load_animations = false
	converter.load_collision = false

	var scene = converter.convert_buffer(data, "meshes\\xbase_anim.nif")
	var skeleton = converter.create_skeleton_from_hierarchy()

	if scene:
		scene.queue_free()

	return skeleton


# =============================================================================
# REBUILD VISUALIZATION
# =============================================================================

func _rebuild_all() -> void:
	_rebuild_skeleton_viz()
	_rebuild_characters()


func _rebuild_skeleton_viz() -> void:
	# Clear old
	if _skel_container:
		for child in _skel_container.get_children():
			child.queue_free()

	if not _skeleton_template:
		return

	var skeleton := _duplicate_skeleton(_skeleton_template)
	skeleton.name = "Skeleton3D"
	_skel_container.add_child(skeleton)

	# Visualize each bone as a sphere + label
	for i in skeleton.get_bone_count():
		var bone_name := skeleton.get_bone_name(i)
		var global_rest := skeleton.get_bone_global_rest(i)

		var sphere_mesh := SphereMesh.new()
		sphere_mesh.radius = 0.012
		sphere_mesh.height = 0.024

		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color.CYAN
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

		var instance := MeshInstance3D.new()
		instance.mesh = sphere_mesh
		instance.material_override = mat
		instance.name = "Bone_%s" % bone_name
		instance.position = global_rest.origin

		_skel_container.add_child(instance)

		# Label every 2nd bone to avoid clutter
		if i % 2 == 0 or bone_name.to_lower().contains("hand") or bone_name.to_lower().contains("head") or bone_name.to_lower().contains("foot"):
			var label := Label3D.new()
			label.text = bone_name
			label.font_size = 24
			label.pixel_size = 0.001
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.no_depth_test = true
			label.modulate = Color(1, 1, 1, 0.8)
			instance.add_child(label)
			label.position = Vector3(0, 0.025, 0)

	# Draw bone connections
	_draw_bone_connections(skeleton)


func _draw_bone_connections(skeleton: Skeleton3D) -> void:
	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.5, 0.8, 1.0, 0.6)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true

	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in skeleton.get_bone_count():
		var parent_idx := skeleton.get_bone_parent(i)
		if parent_idx >= 0:
			var from := skeleton.get_bone_global_rest(parent_idx).origin
			var to := skeleton.get_bone_global_rest(i).origin
			im.surface_add_vertex(from)
			im.surface_add_vertex(to)
	im.surface_end()

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = im
	mesh_inst.material_override = mat
	mesh_inst.name = "BoneConnections"
	_skel_container.add_child(mesh_inst)


func _rebuild_characters() -> void:
	# Clear old characters
	for container in [_char_container, _alt_container]:
		if container:
			for child in container.get_children():
				child.queue_free()

	if not _skeleton_template or _body_part_data.is_empty():
		_update_info()
		return

	# Build center character with current mode
	_build_character(_char_container, _current_mode)

	# Build right character with next mode for comparison
	var alt_mode: BindMode
	match _current_mode:
		BindMode.COMPOSED:
			alt_mode = BindMode.OPENMW
		BindMode.OPENMW:
			alt_mode = BindMode.SKELETON_REST
		BindMode.SKELETON_REST:
			alt_mode = BindMode.COMPOSED

	_build_character(_alt_container, alt_mode)

	_update_info()


func _build_character(container: Node3D, mode: BindMode) -> void:
	var skeleton := _duplicate_skeleton(_skeleton_template)
	skeleton.name = "Skeleton3D"
	container.add_child(skeleton)

	# Add mode label above character
	var mode_label := Label3D.new()
	mode_label.text = _mode_name(mode)
	mode_label.font_size = 48
	mode_label.pixel_size = 0.001
	mode_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	mode_label.no_depth_test = true
	mode_label.modulate = Color.WHITE
	mode_label.position = Vector3(0, 2.2, 0)
	container.add_child(mode_label)

	# Attach each body part
	for slot_name in _body_part_data:
		var meshes: Array = _body_part_data[slot_name]
		var color: Color = SLOT_COLORS.get(slot_name, Color.WHITE)

		for mesh_data in meshes:
			var extracted: MeshExtractor.MeshData = mesh_data
			var array_mesh := MeshExtractor.create_array_mesh(extracted)

			var mat := StandardMaterial3D.new()
			mat.albedo_color = color
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			array_mesh.surface_set_material(0, mat)

			if extracted.is_skinned:
				# PATH A: Skinned mesh — create Skin resource
				var skin := _create_skin(extracted, skeleton, mode)
				if not skin:
					continue

				var instance := MeshInstance3D.new()
				instance.name = "Part_%s" % slot_name
				instance.mesh = array_mesh
				instance.skin = skin
				instance.skeleton = NodePath("..")
				skeleton.add_child(instance)
			else:
				# PATH B: Non-skinned mesh — BoneAttachment3D
				var instance := MeshInstance3D.new()
				instance.name = "Static_%s" % slot_name
				instance.mesh = array_mesh

				var bone_name: String = TEST_SLOT_TO_BONE.get(slot_name, "")
				var bone_idx := _find_bone_ci(skeleton, bone_name) if not bone_name.is_empty() else -1

				if bone_idx >= 0:
					# Vertices are in NIF geometry-local space, not bone-local.
					# Compensate the bone's rest rotation so mesh appears correct.
					instance.transform = skeleton.get_bone_global_rest(bone_idx).affine_inverse() * extracted.node_transform

					var attachment := BoneAttachment3D.new()
					attachment.name = "Attach_%s" % slot_name
					attachment.bone_name = skeleton.get_bone_name(bone_idx)
					skeleton.add_child(attachment)
					attachment.add_child(instance)
				else:
					instance.transform = extracted.node_transform
					skeleton.add_child(instance)


# =============================================================================
# SKIN CREATION — THREE METHODS
# =============================================================================

func _create_skin(mesh_data: MeshExtractor.MeshData, skeleton: Skeleton3D, mode: BindMode) -> Skin:
	if mesh_data.bone_names.is_empty():
		return null

	var skin := Skin.new()
	var has_nif_binds: bool = mesh_data.inv_bind_poses.size() == mesh_data.bone_names.size()

	for i in mesh_data.bone_names.size():
		var bone_name: String = mesh_data.bone_names[i]
		var bone_idx := _find_bone_ci(skeleton, bone_name)

		if bone_idx < 0:
			bone_idx = 0  # fallback to root

		var inv_bind: Transform3D
		match mode:
			BindMode.COMPOSED:
				# Current: compose per-bone with skin_transform
				if has_nif_binds:
					inv_bind = mesh_data.inv_bind_poses[i] * mesh_data.skin_transform
				else:
					inv_bind = skeleton.get_bone_global_rest(bone_idx).affine_inverse()

			BindMode.OPENMW:
				# OpenMW-style: per-bone inverse bind only (no skin_transform)
				if has_nif_binds:
					inv_bind = mesh_data.inv_bind_poses[i]
				else:
					inv_bind = skeleton.get_bone_global_rest(bone_idx).affine_inverse()

			BindMode.SKELETON_REST:
				# Fallback: compute from skeleton rest poses
				inv_bind = skeleton.get_bone_global_rest(bone_idx).affine_inverse()

		skin.add_bind(bone_idx, inv_bind)

	return skin


func _find_bone_ci(skeleton: Skeleton3D, bone_name: String) -> int:
	var idx := skeleton.find_bone(bone_name)
	if idx >= 0:
		return idx

	# Case-insensitive fallback
	var lower := bone_name.to_lower()
	for j in skeleton.get_bone_count():
		if skeleton.get_bone_name(j).to_lower() == lower:
			return j

	return -1


# =============================================================================
# INFO PANEL
# =============================================================================

func _update_info() -> void:
	if not _info_label:
		return

	var lines := PackedStringArray()
	lines.append("[b]Character Assembly Diagnostic[/b]")
	lines.append("Keys: [1] Composed  [2] OpenMW  [3] Skeleton Rest  [R] Reload  [D] Dump")
	lines.append("")

	# Skeleton info
	if _skeleton_template:
		lines.append("[color=cyan]Skeleton: %d bones[/color]" % _skeleton_template.get_bone_count())

		# Show first few bones with positions
		for i in mini(_skeleton_template.get_bone_count(), 8):
			var name_str := _skeleton_template.get_bone_name(i)
			var pos := _skeleton_template.get_bone_global_rest(i).origin
			lines.append("  [%d] %-20s pos=(%.3f, %.3f, %.3f)" % [i, name_str, pos.x, pos.y, pos.z])
		if _skeleton_template.get_bone_count() > 8:
			lines.append("  ... +%d more" % (_skeleton_template.get_bone_count() - 8))
	else:
		lines.append("[color=red]No skeleton loaded![/color]")

	lines.append("")

	# Body part info
	lines.append("[color=yellow]Body Parts: %d loaded[/color]" % _body_part_data.size())
	for slot_name in _body_part_data:
		var meshes: Array = _body_part_data[slot_name]
		for mesh_data in meshes:
			var extracted: MeshExtractor.MeshData = mesh_data
			var type_label := "skinned" if extracted.is_skinned else "static"

			if extracted.is_skinned:
				var matched := 0
				var total := extracted.bone_names.size()
				for bone_name in extracted.bone_names:
					if _skeleton_template and _find_bone_ci(_skeleton_template, bone_name) >= 0:
						matched += 1
				var match_color := "green" if matched == total else "red"
				lines.append("  %s [%s]: %d verts, %d bones ([color=%s]%d/%d matched[/color])" % [
					slot_name, type_label, extracted.vertices.size(), total, match_color, matched, total])
				var st := extracted.skin_transform
				lines.append("    skin_transform origin: (%.3f, %.3f, %.3f)" % [st.origin.x, st.origin.y, st.origin.z])
			else:
				var bone_name: String = TEST_SLOT_TO_BONE.get(slot_name, "")
				var bone_found := _skeleton_template and not bone_name.is_empty() and _find_bone_ci(_skeleton_template, bone_name) >= 0
				var bone_color := "green" if bone_found else "red"
				lines.append("  %s [%s]: %d verts, bone=[color=%s]%s[/color]" % [
					slot_name, type_label, extracted.vertices.size(), bone_color, bone_name if not bone_name.is_empty() else "NONE"])

	lines.append("")

	# Mode info
	lines.append("[color=white]Center: [b]%s[/b][/color]" % _mode_name(_current_mode))
	var alt_mode: BindMode
	match _current_mode:
		BindMode.COMPOSED: alt_mode = BindMode.OPENMW
		BindMode.OPENMW: alt_mode = BindMode.SKELETON_REST
		BindMode.SKELETON_REST: alt_mode = BindMode.COMPOSED
	lines.append("[color=gray]Right: %s[/color]" % _mode_name(alt_mode))

	_info_label.text = "\n".join(lines)


func _mode_name(mode: BindMode) -> String:
	match mode:
		BindMode.COMPOSED: return "COMPOSED (inv_bind * skin_transform)"
		BindMode.OPENMW: return "OPENMW (inv_bind only)"
		BindMode.SKELETON_REST: return "SKELETON_REST (global_rest inverse)"
		_: return "UNKNOWN"


# =============================================================================
# DEBUG DUMP
# =============================================================================

func _dump_debug_info() -> void:
	Log.info("character", "=== CHARACTER ASSEMBLY DEBUG DUMP ===")

	if _skeleton_template:
		Log.info("character", "Skeleton: %d bones" % _skeleton_template.get_bone_count())
		for i in _skeleton_template.get_bone_count():
			var name_str := _skeleton_template.get_bone_name(i)
			var parent := _skeleton_template.get_bone_parent(i)
			var rest := _skeleton_template.get_bone_rest(i)
			var global_rest := _skeleton_template.get_bone_global_rest(i)
			Log.info("character", "  [%d] %-25s parent=%d  rest_pos=(%.4f,%.4f,%.4f)  global_pos=(%.4f,%.4f,%.4f)" % [
				i, name_str, parent,
				rest.origin.x, rest.origin.y, rest.origin.z,
				global_rest.origin.x, global_rest.origin.y, global_rest.origin.z])

	Log.info("character", "")

	for slot_name in _body_part_data:
		var meshes: Array = _body_part_data[slot_name]
		for mesh_data in meshes:
			var extracted: MeshExtractor.MeshData = mesh_data
			var attach_type := "SKINNED" if extracted.is_skinned else "STATIC"

			Log.info("character", "Body Part: %s [%s] (%d verts, %d bones)" % [
				slot_name, attach_type, extracted.vertices.size(), extracted.bone_names.size()])

			if extracted.is_skinned:
				Log.info("character", "  skin_transform: origin=(%.4f,%.4f,%.4f)" % [
					extracted.skin_transform.origin.x,
					extracted.skin_transform.origin.y,
					extracted.skin_transform.origin.z])

				for j in extracted.bone_names.size():
					var bone_name: String = extracted.bone_names[j]
					var skel_idx := -1
					if _skeleton_template:
						skel_idx = _find_bone_ci(_skeleton_template, bone_name)
					var status := "OK" if skel_idx >= 0 else "MISSING"

					var inv_bind_str := ""
					if j < extracted.inv_bind_poses.size():
						var ib: Transform3D = extracted.inv_bind_poses[j]
						inv_bind_str = "inv_bind_origin=(%.4f,%.4f,%.4f)" % [ib.origin.x, ib.origin.y, ib.origin.z]

					Log.info("character", "  bone[%d] %-25s skel_idx=%d [%s] %s" % [
						j, bone_name, skel_idx, status, inv_bind_str])
			else:
				var target_bone: String = TEST_SLOT_TO_BONE.get(slot_name, "")
				var bone_idx := _find_bone_ci(_skeleton_template, target_bone) if _skeleton_template and not target_bone.is_empty() else -1
				Log.info("character", "  target_bone: %s (idx=%d), node_transform origin=(%.4f,%.4f,%.4f)" % [
					target_bone if not target_bone.is_empty() else "NONE", bone_idx,
					extracted.node_transform.origin.x,
					extracted.node_transform.origin.y,
					extracted.node_transform.origin.z])

	Log.info("character", "=== END DEBUG DUMP ===")


# =============================================================================
# SCENE SETUP
# =============================================================================

func _setup_scene() -> void:
	# Camera
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.position = Vector3(0, 1.0, 3.5)
	add_child(camera)
	camera.look_at(Vector3(0, 0.8, 0))

	# Light
	var light := DirectionalLight3D.new()
	light.name = "Light"
	light.rotation_degrees = Vector3(-45, 30, 0)
	add_child(light)

	# Ambient light so we can see colors
	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.ambient_light_color = Color(0.4, 0.4, 0.4)
	environment.ambient_light_energy = 0.5
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.15, 0.15, 0.2)
	env.environment = environment
	add_child(env)

	# Ground plane
	var grid := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(6, 6)
	grid.mesh = plane
	var grid_mat := StandardMaterial3D.new()
	grid_mat.albedo_color = Color(0.25, 0.25, 0.3, 0.5)
	grid_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	grid.material_override = grid_mat
	add_child(grid)

	# Three columns: skeleton | character mode A | character mode B
	_skel_container = Node3D.new()
	_skel_container.name = "SkeletonViz"
	_skel_container.position = Vector3(-1.5, 0, 0)
	add_child(_skel_container)

	_char_container = Node3D.new()
	_char_container.name = "CharacterCenter"
	_char_container.position = Vector3(0, 0, 0)
	add_child(_char_container)

	_alt_container = Node3D.new()
	_alt_container.name = "CharacterRight"
	_alt_container.position = Vector3(1.5, 0, 0)
	add_child(_alt_container)

	# Column labels
	_add_column_label(_skel_container, "SKELETON", Vector3(0, 2.5, 0))


func _add_column_label(parent: Node3D, text: String, pos: Vector3) -> void:
	var label := Label3D.new()
	label.text = text
	label.font_size = 64
	label.pixel_size = 0.001
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.modulate = Color(1, 1, 0.5)
	label.position = pos
	parent.add_child(label)


func _setup_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "UI"
	add_child(canvas)

	var panel := PanelContainer.new()
	panel.name = "InfoPanel"
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.offset_left = 10
	panel.offset_top = 10
	panel.offset_right = 560
	panel.offset_bottom = 700

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.7)
	style.content_margin_left = 8
	style.content_margin_top = 8
	style.content_margin_right = 8
	style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)

	_info_label = RichTextLabel.new()
	_info_label.bbcode_enabled = true
	_info_label.fit_content = true
	_info_label.custom_minimum_size = Vector2(530, 670)

	panel.add_child(_info_label)
	canvas.add_child(panel)


# =============================================================================
# UTILITY
# =============================================================================

func _duplicate_skeleton(source: Skeleton3D) -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	skeleton.name = source.name

	for i in source.get_bone_count():
		skeleton.add_bone(source.get_bone_name(i))

	for i in source.get_bone_count():
		var parent_idx := source.get_bone_parent(i)
		if parent_idx >= 0:
			skeleton.set_bone_parent(i, parent_idx)
		skeleton.set_bone_rest(i, source.get_bone_rest(i))

	skeleton.reset_bone_poses()
	return skeleton
