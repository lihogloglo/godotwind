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
const MeshExtractor := preload("res://src/core/character/mesh_extractor.gd")
const NIFReader := preload("res://src/core/nif/nif_reader.gd")
const NIFDefs := preload("res://src/core/nif/nif_defs.gd")
const CS := preload("res://src/core/coordinate_system.gd")
const TextureLoaderScript := preload("res://src/core/texture/texture_loader.gd")

# Inv bind modes (for skinned parts)
enum BindMode { COMPOSED, OPENMW, SKELETON_REST }
var _current_mode: BindMode = BindMode.COMPOSED

# Static attachment modes (for non-skinned parts)
enum StaticMode { BONE_REST_INV, DIRECT, IDENTITY, ATTACHMENT }
var _static_mode: StaticMode = StaticMode.ATTACHMENT

# Scene containers
var _skel_container: Node3D = null     # Left: skeleton only
var _char_container: Node3D = null     # Center: assembled character
var _alt_container: Node3D = null      # Right: alternative method
var _info_label: RichTextLabel = null

# Cached data
var _skeleton_template: Skeleton3D = null
var _body_part_data: Dictionary = {}   # slot_name -> MeshExtractor.MeshData array
var _attachment_transforms: Dictionary = {}  # attachment_name_lower -> Transform3D (local, relative to parent Bip01 bone)

# Slot-to-bone mapping: which Bip01 bone is the PARENT of the named attachment node
# Must match the actual NIF hierarchy (verified from xbase_anim.nif dump)
const TEST_SLOT_TO_BONE := {
	"HEAD": "bip01 head",
	"HAIR": "bip01 head",
	"NECK": "bip01 neck",
	"SKINS": "bip01 spine1",
	"CHEST": "bip01 spine2",        # Chest attachment is child of Bip01 Spine2 (not Spine1)
	"GROIN": "bip01 pelvis",
	"UPPER_ARM_R": "bip01 r upperarm",
	"UPPER_ARM_L": "bip01 l upperarm",
	"FOREARM_R": "bip01 r forearm",
	"FOREARM_L": "bip01 l forearm",
	"HAND_R": "bip01 r hand",
	"HAND_L": "bip01 l hand",
	"WRIST_R": "bip01 r forearm",
	"WRIST_L": "bip01 l forearm",
	"UPPER_LEG_R": "bip01 r thigh",
	"UPPER_LEG_L": "bip01 l thigh",
	"KNEE_R": "bip01 r calf",
	"KNEE_L": "bip01 l calf",
	"ANKLE_R": "bip01 r calf",      # Ankle attachment is child of Bip01 R Calf (not Foot)
	"ANKLE_L": "bip01 l calf",
	"FOOT_R": "bip01 r foot",
	"FOOT_L": "bip01 l foot",
}

# Maps slot name -> OpenMW-style attachment node name in xbase_anim.nif
# Body part vertices are authored in the attachment node's local frame
const SLOT_TO_ATTACHMENT := {
	"HEAD": "head",
	"HAIR": "head",
	"NECK": "neck",
	"CHEST": "chest",
	"GROIN": "groin",
	"UPPER_ARM_R": "right upper arm",
	"UPPER_ARM_L": "left upper arm",
	"FOREARM_R": "right forearm",
	"FOREARM_L": "left forearm",
	"HAND_R": "right hand",
	"HAND_L": "left hand",
	"WRIST_R": "right wrist",
	"WRIST_L": "left wrist",
	"UPPER_LEG_R": "right upper leg",
	"UPPER_LEG_L": "left upper leg",
	"KNEE_R": "right knee",
	"KNEE_L": "left knee",
	"ANKLE_R": "right ankle",
	"ANKLE_L": "left ankle",
	"FOOT_R": "right foot",
	"FOOT_L": "left foot",
}

const SLOT_COLORS := {
	"HEAD": Color(1.0, 0.3, 0.3),       # Red
	"HAIR": Color(1.0, 0.5, 0.8),       # Pink
	"NECK": Color(1.0, 0.6, 0.3),       # Orange
	"SKINS": Color(0.3, 0.5, 1.0),      # Blue (chest+hands+wrists)
	"CHEST": Color(0.3, 0.5, 1.0),      # Blue
	"GROIN": Color(0.3, 0.3, 0.8),      # Dark blue
	"UPPER_ARM_R": Color(0.3, 0.8, 0.3),# Green
	"UPPER_ARM_L": Color(0.3, 0.8, 0.3),
	"FOREARM_R": Color(0.4, 0.9, 0.4),  # Light green
	"FOREARM_L": Color(0.4, 0.9, 0.4),
	"HAND_R": Color(0.5, 1.0, 0.5),     # Pale green
	"HAND_L": Color(0.5, 1.0, 0.5),
	"WRIST_R": Color(0.6, 1.0, 0.6),    # Lighter green
	"WRIST_L": Color(0.6, 1.0, 0.6),
	"UPPER_LEG_R": Color(0.9, 0.9, 0.2),# Yellow
	"UPPER_LEG_L": Color(0.9, 0.9, 0.2),
	"KNEE_R": Color(0.8, 0.8, 0.3),     # Dark yellow
	"KNEE_L": Color(0.8, 0.8, 0.3),
	"ANKLE_R": Color(0.7, 0.7, 0.4),    # Olive
	"ANKLE_L": Color(0.7, 0.7, 0.4),
	"FOOT_R": Color(0.6, 0.6, 0.5),     # Tan
	"FOOT_L": Color(0.6, 0.6, 0.5),
}

# Right-to-left slot mapping for auto-mirroring
const RIGHT_TO_LEFT := {
	"UPPER_ARM_R": "UPPER_ARM_L",
	"FOREARM_R": "FOREARM_L",
	"WRIST_R": "WRIST_L",
	"UPPER_LEG_R": "UPPER_LEG_L",
	"KNEE_R": "KNEE_L",
	"ANKLE_R": "ANKLE_L",
	"FOOT_R": "FOOT_L",
}

# Left-side slots (need X-axis mirroring)
const LEFT_SLOTS := ["UPPER_ARM_L", "FOREARM_L", "HAND_L", "WRIST_L",
	"UPPER_LEG_L", "KNEE_L", "ANKLE_L", "FOOT_L"]

# Known body part paths for Wood Elf male (Fargoth's race)
# "skins" file contains chest+hands+wrists as sub-meshes
const TEST_BODY_PARTS := {
	"SKINS": "meshes/b/b_n_wood elf_m_skins.nif",
	"UPPER_ARM_R": "meshes/b/b_n_wood elf_m_upper arm.nif",
	"FOREARM_R": "meshes/b/b_n_wood elf_m_forearm.nif",
	"GROIN": "meshes/b/b_n_wood elf_m_groin.nif",
	"UPPER_LEG_R": "meshes/b/b_n_wood elf_m_upper leg.nif",
	"KNEE_R": "meshes/b/b_n_wood elf_m_knee.nif",
	"ANKLE_R": "meshes/b/b_n_wood elf_m_ankle.nif",
	"FOOT_R": "meshes/b/b_n_wood elf_m_foot.nif",
	"NECK": "meshes/b/b_n_wood elf_m_neck.nif",
	"WRIST_R": "meshes/b/b_n_wood elf_m_wrist.nif",
	"HEAD": "meshes/b/b_n_wood elf_m_head_01.nif",
	"HAIR": "meshes/b/b_n_wood elf_m_hair_01.nif",
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
	_dump_debug_info()


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
			KEY_4:
				_static_mode = StaticMode.BONE_REST_INV
				_rebuild_characters()
			KEY_5:
				_static_mode = StaticMode.DIRECT
				_rebuild_characters()
			KEY_6:
				_static_mode = StaticMode.IDENTITY
				_rebuild_characters()
			KEY_7:
				_static_mode = StaticMode.ATTACHMENT
				_rebuild_characters()
			KEY_R:
				_load_all_data()
				_rebuild_all()
			KEY_D:
				_dump_debug_info()
			KEY_H:
				_dump_nif_hierarchy()


# =============================================================================
# DATA LOADING
# =============================================================================

func _load_all_data() -> void:
	_skeleton_template = _load_skeleton()
	_body_part_data.clear()
	_attachment_transforms.clear()

	if not _skeleton_template:
		push_error("CharacterAssemblyTest: Failed to load skeleton")
		return

	# Extract attachment node transforms from xbase_anim.nif
	_extract_attachment_transforms()

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

	# Auto-generate left-side from right-side (Morrowind ships right-side only)
	for right_slot in RIGHT_TO_LEFT:
		var left_slot: String = RIGHT_TO_LEFT[right_slot]
		if right_slot in _body_part_data and left_slot not in _body_part_data:
			_body_part_data[left_slot] = _body_part_data[right_slot]

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


## Extract attachment node transforms from xbase_anim.nif
## These named nodes ("Head", "Right Upper Arm", etc.) define the local frame
## that body part mesh vertices are authored in.
func _extract_attachment_transforms() -> void:
	var bsa_mgr = get_node_or_null("/root/BSAManager")
	if not bsa_mgr:
		return

	var data: PackedByteArray = bsa_mgr.extract_file("meshes\\xbase_anim.nif")
	if data.is_empty():
		return

	var reader := NIFReader.new()
	var err := reader.load_buffer(data, "meshes\\xbase_anim.nif")
	if err != OK:
		return

	# Walk the NIF hierarchy and collect attachment node transforms
	for root_idx in reader.roots:
		var root := reader.get_record(root_idx)
		if root is NIFDefs.NiNode:
			_collect_attachment_transforms(reader, root as NIFDefs.NiNode)

	Log.info("character", "Extracted %d attachment node transforms" % _attachment_transforms.size())


## Known attachment node names (OpenMW convention)
const ATTACHMENT_NAMES := [
	"head", "neck", "chest", "groin",
	"right hand", "left hand", "right wrist", "left wrist",
	"right forearm", "left forearm", "right upper arm", "left upper arm",
	"right foot", "left foot", "right ankle", "left ankle",
	"right knee", "left knee", "right upper leg", "left upper leg",
	"right clavicle", "left clavicle", "weapon bone", "shield bone", "tail",
]

func _collect_attachment_transforms(reader: NIFReader, node: NIFDefs.NiNode) -> void:
	var node_name: String = node.name if node.name else ""
	var name_lower := node_name.to_lower()

	# If this is a known attachment node, store its local transform
	if name_lower in ATTACHMENT_NAMES:
		var local_nif := Transform3D.IDENTITY
		if node.transform:
			local_nif = node.transform.to_transform3d()
		_attachment_transforms[name_lower] = CS.transform_to_godot(local_nif)

	# Recurse children
	for child_idx in node.children_indices:
		if child_idx < 0:
			continue
		var child := reader.get_record(child_idx)
		if child is NIFDefs.NiNode:
			_collect_attachment_transforms(reader, child as NIFDefs.NiNode)


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

	# Add mode labels above character
	var mode_label := Label3D.new()
	mode_label.text = _mode_name(mode) + "\n" + _static_mode_name(_static_mode)
	mode_label.font_size = 36
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

			var is_left: bool = slot_name in LEFT_SLOTS

			# Try textured material first, fall back to flat color
			var mat := _create_textured_material(extracted.texture_path, extracted.material_properties)
			if not mat:
				mat = StandardMaterial3D.new()
				mat.albedo_color = color
			array_mesh.surface_set_material(0, mat)

			# Match OpenMW: only full-body skins (many bones) use GPU skinning
			var is_actually_skinned: bool = extracted.is_skinned and extracted.bone_names.size() > 4

			if is_actually_skinned:
				if is_left:
					# PATH A2: Mirrored skinned mesh for left side
					var mirrored_mesh := _create_mirrored_skinned_mesh(extracted)
					var skin := _create_mirrored_skin(extracted, skeleton)
					if not skin:
						continue

					mat.cull_mode = BaseMaterial3D.CULL_BACK
					mirrored_mesh.surface_set_material(0, mat)

					var instance := MeshInstance3D.new()
					instance.name = "Part_%s" % slot_name
					instance.mesh = mirrored_mesh
					instance.skin = skin
					instance.skeleton = NodePath("..")
					skeleton.add_child(instance)
				else:
					# PATH A1: Skinned mesh — create Skin resource
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
				# For left-side: use mirrored mesh (pre-flipped normals + reversed winding)
				var final_mesh: ArrayMesh
				if is_left:
					final_mesh = _create_mirrored_static_mesh(extracted)
					final_mesh.surface_set_material(0, mat)
				else:
					final_mesh = array_mesh

				var instance := MeshInstance3D.new()
				instance.name = "Static_%s" % slot_name
				instance.mesh = final_mesh

				var bone_name: String = TEST_SLOT_TO_BONE.get(slot_name, "")
				var bone_idx := _find_bone_ci(skeleton, bone_name) if not bone_name.is_empty() else -1

				if bone_idx >= 0:
					# Apply transform based on selected static mode
					match _static_mode:
						StaticMode.BONE_REST_INV:
							instance.transform = skeleton.get_bone_global_rest(bone_idx).affine_inverse() * extracted.node_transform
						StaticMode.DIRECT:
							instance.transform = extracted.node_transform
						StaticMode.IDENTITY:
							instance.transform = Transform3D.IDENTITY
						StaticMode.ATTACHMENT:
							var attach_name: String = SLOT_TO_ATTACHMENT.get(slot_name, "")
							if not attach_name.is_empty() and attach_name in _attachment_transforms:
								if is_left:
									var bone_offset_pos: Vector3 = extracted.bone_offset_position if extracted.has_bone_offset else Vector3.ZERO
									var mirror_xf := Transform3D(Basis.from_scale(Vector3(-1, 1, 1)), bone_offset_pos)
									instance.transform = _attachment_transforms[attach_name] * mirror_xf * extracted.node_transform
								else:
									# bone_offset sits BETWEEN attachment and nif_root (matches OpenMW PAT hierarchy)
									if extracted.has_bone_offset:
										var bone_offset_xf := Transform3D(Basis.IDENTITY, extracted.bone_offset_position)
										instance.transform = _attachment_transforms[attach_name] * bone_offset_xf * extracted.node_transform
									else:
										instance.transform = _attachment_transforms[attach_name] * extracted.node_transform
							else:
								instance.transform = extracted.node_transform
								if is_left:
									instance.scale.x *= -1.0

					# Left-side mirroring for non-ATTACHMENT modes
					if is_left and _static_mode != StaticMode.ATTACHMENT:
						instance.scale.x *= -1.0

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
	lines.append("Skinned: [1] Composed  [2] OpenMW  [3] Skeleton Rest")
	lines.append("Static:  [4] BoneRestInv  [5] Direct  [6] Identity  [7] Attachment")
	lines.append("[R] Reload  [D] Dump debug info")
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
	lines.append("[color=white]Skinned: [b]%s[/b][/color]" % _mode_name(_current_mode))
	lines.append("[color=white]Static: [b]%s[/b][/color]" % _static_mode_name(_static_mode))
	var alt_mode: BindMode
	match _current_mode:
		BindMode.COMPOSED: alt_mode = BindMode.OPENMW
		BindMode.OPENMW: alt_mode = BindMode.SKELETON_REST
		BindMode.SKELETON_REST: alt_mode = BindMode.COMPOSED
	lines.append("[color=gray]Right panel: %s[/color]" % _mode_name(alt_mode))

	_info_label.text = "\n".join(lines)


func _mode_name(mode: BindMode) -> String:
	match mode:
		BindMode.COMPOSED: return "COMPOSED (inv_bind * skin_transform)"
		BindMode.OPENMW: return "OPENMW (inv_bind only)"
		BindMode.SKELETON_REST: return "SKELETON_REST (global_rest inverse)"
		_: return "UNKNOWN"


func _static_mode_name(mode: StaticMode) -> String:
	match mode:
		StaticMode.BONE_REST_INV: return "Static: BONE_REST_INV (broken)"
		StaticMode.DIRECT: return "Static: DIRECT (node_transform)"
		StaticMode.IDENTITY: return "Static: IDENTITY (no transform)"
		StaticMode.ATTACHMENT: return "Static: ATTACHMENT (named node xform)"
		_: return "Static: UNKNOWN"


# =============================================================================
# DEBUG DUMP
# =============================================================================

func _dump_debug_info() -> void:
	Log.info("character", "=== CHARACTER ASSEMBLY DEBUG DUMP ===")
	Log.info("character", "Skinned mode: %s" % _mode_name(_current_mode))
	Log.info("character", "Static mode: %s" % _static_mode_name(_static_mode))

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

			# Compute vertex AABB
			var aabb := _compute_vertex_aabb(extracted.vertices)

			Log.info("character", "Body Part: %s [%s] (%d verts, %d bones)" % [
				slot_name, attach_type, extracted.vertices.size(), extracted.bone_names.size()])
			Log.info("character", "  vertex_aabb: min=(%.4f,%.4f,%.4f) max=(%.4f,%.4f,%.4f)" % [
				aabb[0].x, aabb[0].y, aabb[0].z, aabb[1].x, aabb[1].y, aabb[1].z])
			Log.info("character", "  vertex_center: (%.4f,%.4f,%.4f) size=(%.4f,%.4f,%.4f)" % [
				aabb[2].x, aabb[2].y, aabb[2].z, aabb[3].x, aabb[3].y, aabb[3].z])

			if extracted.is_skinned:
				var st := extracted.skin_transform
				Log.info("character", "  skin_transform: origin=(%.4f,%.4f,%.4f)" % [
					st.origin.x, st.origin.y, st.origin.z])
				Log.info("character", "    basis_x=(%.3f,%.3f,%.3f) basis_y=(%.3f,%.3f,%.3f) basis_z=(%.3f,%.3f,%.3f)" % [
					st.basis.x.x, st.basis.x.y, st.basis.x.z,
					st.basis.y.x, st.basis.y.y, st.basis.y.z,
					st.basis.z.x, st.basis.z.y, st.basis.z.z])

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

				# Full node_transform
				var nt := extracted.node_transform
				Log.info("character", "  node_transform: origin=(%.4f,%.4f,%.4f)" % [
					nt.origin.x, nt.origin.y, nt.origin.z])
				Log.info("character", "    basis_x=(%.3f,%.3f,%.3f) basis_y=(%.3f,%.3f,%.3f) basis_z=(%.3f,%.3f,%.3f)" % [
					nt.basis.x.x, nt.basis.x.y, nt.basis.x.z,
					nt.basis.y.x, nt.basis.y.y, nt.basis.y.z,
					nt.basis.z.x, nt.basis.z.y, nt.basis.z.z])

				# Bone info
				if bone_idx >= 0 and _skeleton_template:
					var bone_rest := _skeleton_template.get_bone_global_rest(bone_idx)
					Log.info("character", "  target_bone: %s (idx=%d)" % [target_bone, bone_idx])
					Log.info("character", "    bone_global_rest: origin=(%.4f,%.4f,%.4f)" % [
						bone_rest.origin.x, bone_rest.origin.y, bone_rest.origin.z])
					Log.info("character", "    basis_x=(%.3f,%.3f,%.3f) basis_y=(%.3f,%.3f,%.3f) basis_z=(%.3f,%.3f,%.3f)" % [
						bone_rest.basis.x.x, bone_rest.basis.x.y, bone_rest.basis.x.z,
						bone_rest.basis.y.x, bone_rest.basis.y.y, bone_rest.basis.y.z,
						bone_rest.basis.z.x, bone_rest.basis.z.y, bone_rest.basis.z.z])

					# Distance from vertex center to bone position
					var center_vec: Vector3 = aabb[2]
					var dist: float = center_vec.distance_to(bone_rest.origin)
					Log.info("character", "    distance vertex_center→bone: %.4f m" % dist)

					# Computed instance transforms for each mode
					var t_rest_inv := bone_rest.affine_inverse() * nt
					Log.info("character", "    [BONE_REST_INV] result origin=(%.4f,%.4f,%.4f)" % [
						t_rest_inv.origin.x, t_rest_inv.origin.y, t_rest_inv.origin.z])
					Log.info("character", "    [DIRECT]        result origin=(%.4f,%.4f,%.4f)" % [
						nt.origin.x, nt.origin.y, nt.origin.z])
					Log.info("character", "    [IDENTITY]      result origin=(0,0,0)")

					# ATTACHMENT result
					var attach_name: String = SLOT_TO_ATTACHMENT.get(slot_name, "")
					if not attach_name.is_empty() and attach_name in _attachment_transforms:
						var t_attach: Transform3D = _attachment_transforms[attach_name] * nt
						Log.info("character", "    [ATTACHMENT]    result origin=(%.4f,%.4f,%.4f)" % [
							t_attach.origin.x, t_attach.origin.y, t_attach.origin.z])
						Log.info("character", "      basis_x=(%.3f,%.3f,%.3f) basis_y=(%.3f,%.3f,%.3f) basis_z=(%.3f,%.3f,%.3f)" % [
							t_attach.basis.x.x, t_attach.basis.x.y, t_attach.basis.x.z,
							t_attach.basis.y.x, t_attach.basis.y.y, t_attach.basis.y.z,
							t_attach.basis.z.x, t_attach.basis.z.y, t_attach.basis.z.z])
				else:
					Log.info("character", "  target_bone: %s — NOT FOUND" % (target_bone if not target_bone.is_empty() else "NONE"))

				# BoneOffset info
				if "has_bone_offset" in extracted and extracted.has_bone_offset:
					Log.info("character", "  bone_offset: (%.4f,%.4f,%.4f)" % [
						extracted.bone_offset_position.x,
						extracted.bone_offset_position.y,
						extracted.bone_offset_position.z])

	Log.info("character", "=== END DEBUG DUMP ===")


# =============================================================================
# NIF HIERARCHY DUMP — find named attachment nodes
# =============================================================================

func _dump_nif_hierarchy() -> void:
	Log.info("character", "=== NIF HIERARCHY DUMP (xbase_anim.nif) ===")

	var bsa_mgr = get_node_or_null("/root/BSAManager")
	if not bsa_mgr:
		Log.error("character", "BSAManager not available")
		return

	var data: PackedByteArray = bsa_mgr.extract_file("meshes\\xbase_anim.nif")
	if data.is_empty():
		Log.error("character", "Cannot load xbase_anim.nif")
		return

	var reader := NIFReader.new()
	var err := reader.load_buffer(data, "meshes\\xbase_anim.nif")
	if err != OK:
		Log.error("character", "Failed to parse xbase_anim.nif")
		return

	# Walk full hierarchy from roots
	for root_idx in reader.roots:
		var root := reader.get_record(root_idx)
		if root is NIFDefs.NiNode:
			_dump_nif_node(reader, root as NIFDefs.NiNode, 0, Transform3D.IDENTITY)

	Log.info("character", "=== END NIF HIERARCHY ===")


func _dump_nif_node(reader: NIFReader, node: NIFDefs.NiNode, depth: int, parent_accumulated: Transform3D) -> void:
	var indent := "  ".repeat(depth)
	var node_name: String = node.name if node.name else "(unnamed)"
	var name_lower := node_name.to_lower()

	# Get local transform from NIF (in NIF space, before coordinate conversion)
	var local_nif := Transform3D.IDENTITY
	if node.transform:
		local_nif = node.transform.to_transform3d()

	# Accumulated transform in NIF space
	var accumulated_nif := parent_accumulated * local_nif

	# Convert to Godot space for display
	var local_godot := CS.transform_to_godot(local_nif)
	var accumulated_godot := CS.transform_to_godot(accumulated_nif)

	# Mark special nodes
	var marker := ""
	if name_lower.begins_with("bip01"):
		marker = " [BONE]"
	elif name_lower in ["head", "neck", "chest", "groin", "right hand", "left hand",
			"right wrist", "left wrist", "right forearm", "left forearm",
			"right upper arm", "left upper arm", "right foot", "left foot",
			"right ankle", "left ankle", "right knee", "left knee",
			"right upper leg", "left upper leg", "right clavicle", "left clavicle",
			"weapon bone", "shield bone", "tail"]:
		marker = " [ATTACHMENT]"

	# Print node info
	var local_pos := local_godot.origin
	var accum_pos := accumulated_godot.origin
	Log.info("character", "%s%s%s  local=(%.4f,%.4f,%.4f)  global=(%.4f,%.4f,%.4f)" % [
		indent, node_name, marker,
		local_pos.x, local_pos.y, local_pos.z,
		accum_pos.x, accum_pos.y, accum_pos.z])

	# For attachment nodes, also print basis to compare with parent Bip01 bone
	if marker == " [ATTACHMENT]":
		var lb := local_godot.basis
		Log.info("character", "%s  local_basis: x=(%.3f,%.3f,%.3f) y=(%.3f,%.3f,%.3f) z=(%.3f,%.3f,%.3f)" % [
			indent,
			lb.x.x, lb.x.y, lb.x.z,
			lb.y.x, lb.y.y, lb.y.z,
			lb.z.x, lb.z.y, lb.z.z])

	# Recurse children
	for child_idx in node.children_indices:
		if child_idx < 0:
			continue
		var child := reader.get_record(child_idx)
		if child is NIFDefs.NiNode:
			_dump_nif_node(reader, child as NIFDefs.NiNode, depth + 1, accumulated_nif)


# =============================================================================
# SCENE SETUP
# =============================================================================

func _setup_scene() -> void:
	# Camera
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.position = Vector3(0, 1.0, -3.5)
	add_child(camera)
	camera.look_at(Vector3(0, 0.8, 0))

	# Key light
	var light := DirectionalLight3D.new()
	light.name = "KeyLight"
	light.rotation_degrees = Vector3(-45, 30, 0)
	light.light_energy = 1.2
	light.shadow_enabled = true
	add_child(light)

	# Fill light (softer, from opposite side)
	var fill := DirectionalLight3D.new()
	fill.name = "FillLight"
	fill.rotation_degrees = Vector3(-30, -120, 0)
	fill.light_energy = 0.4
	fill.light_color = Color(0.8, 0.85, 1.0)
	add_child(fill)

	# Environment with ambient + tonemap for texture readability
	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.ambient_light_color = Color(0.5, 0.5, 0.55)
	environment.ambient_light_energy = 0.6
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.15, 0.15, 0.2)
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
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
# MESH MIRRORING (matches MorrowindNPCAssembler)
# =============================================================================

## Create mirrored static mesh: pre-flipped normals + reversed winding
func _create_mirrored_static_mesh(mesh_data: MeshExtractor.MeshData) -> ArrayMesh:
	var mirrored_normals := PackedVector3Array()
	if not mesh_data.normals.is_empty():
		mirrored_normals.resize(mesh_data.normals.size())
		for i in mesh_data.normals.size():
			var n := mesh_data.normals[i]
			mirrored_normals[i] = Vector3(-n.x, n.y, n.z)

	var mirrored_indices := PackedInt32Array()
	mirrored_indices.resize(mesh_data.indices.size())
	for i in range(0, mesh_data.indices.size(), 3):
		mirrored_indices[i] = mesh_data.indices[i]
		mirrored_indices[i + 1] = mesh_data.indices[i + 2]
		mirrored_indices[i + 2] = mesh_data.indices[i + 1]

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = mesh_data.vertices
	if not mirrored_normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = mirrored_normals
	if not mesh_data.uvs.is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = mesh_data.uvs
	arrays[Mesh.ARRAY_INDEX] = mirrored_indices

	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return array_mesh


## Create mirrored skinned mesh: flipped vertices/normals + reversed winding
func _create_mirrored_skinned_mesh(mesh_data: MeshExtractor.MeshData) -> ArrayMesh:
	var mirrored_verts := PackedVector3Array()
	mirrored_verts.resize(mesh_data.vertices.size())
	for i in mesh_data.vertices.size():
		var v := mesh_data.vertices[i]
		mirrored_verts[i] = Vector3(-v.x, v.y, v.z)

	var mirrored_normals := PackedVector3Array()
	if not mesh_data.normals.is_empty():
		mirrored_normals.resize(mesh_data.normals.size())
		for i in mesh_data.normals.size():
			var n := mesh_data.normals[i]
			mirrored_normals[i] = Vector3(-n.x, n.y, n.z)

	var mirrored_indices := PackedInt32Array()
	mirrored_indices.resize(mesh_data.indices.size())
	for i in range(0, mesh_data.indices.size(), 3):
		mirrored_indices[i] = mesh_data.indices[i]
		mirrored_indices[i + 1] = mesh_data.indices[i + 2]
		mirrored_indices[i + 2] = mesh_data.indices[i + 1]

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = mirrored_verts
	if not mirrored_normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = mirrored_normals
	if not mesh_data.uvs.is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = mesh_data.uvs
	arrays[Mesh.ARRAY_INDEX] = mirrored_indices

	if mesh_data.is_skinned:
		var bones := PackedInt32Array()
		var weights := PackedFloat32Array()
		for i in mesh_data.vertices.size():
			var bi: PackedInt32Array = mesh_data.bone_indices[i]
			var bw: PackedFloat32Array = mesh_data.bone_weights[i]
			bones.append_array(bi)
			weights.append_array(bw)
		arrays[Mesh.ARRAY_BONES] = bones
		arrays[Mesh.ARRAY_WEIGHTS] = weights

	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return array_mesh


## Create Skin for mirrored (left-side) skinned mesh using remapped bone names.
## Uses mirrored NIF bind data: mirror * nif_inv_bind * skin_transform * mirror
func _create_mirrored_skin(mesh_data: MeshExtractor.MeshData, skeleton: Skeleton3D) -> Skin:
	if mesh_data.bone_names.is_empty():
		return null

	var skin := Skin.new()
	var has_nif_binds: bool = mesh_data.inv_bind_poses.size() == mesh_data.bone_names.size()
	var mirror_basis := Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1))
	var mirror_xf := Transform3D(mirror_basis, Vector3.ZERO)

	for i in mesh_data.bone_names.size():
		var bone_name: String = mesh_data.bone_names[i]
		var mirrored_name := _mirror_bone_name(bone_name)
		var bone_idx := _find_bone_ci(skeleton, mirrored_name)
		if bone_idx < 0:
			bone_idx = 0

		var inv_bind: Transform3D
		if has_nif_binds:
			inv_bind = mirror_xf * mesh_data.inv_bind_poses[i] * mesh_data.skin_transform * mirror_xf
		else:
			inv_bind = skeleton.get_bone_global_rest(bone_idx).affine_inverse()

		skin.add_bind(bone_idx, inv_bind)
	return skin


## Mirror bone name: "Bip01 R " ↔ "Bip01 L "
func _mirror_bone_name(bone_name: String) -> String:
	var lower := bone_name.to_lower()
	if lower.contains(" r "):
		return bone_name.replace(" R ", " L ").replace(" r ", " l ")
	elif lower.contains(" l "):
		return bone_name.replace(" L ", " R ").replace(" l ", " r ")
	if lower.ends_with(" r"):
		return bone_name.substr(0, bone_name.length() - 1) + ("L" if bone_name[-1] == "R" else "l")
	elif lower.ends_with(" l"):
		return bone_name.substr(0, bone_name.length() - 1) + ("R" if bone_name[-1] == "L" else "r")
	return bone_name


# =============================================================================
# UTILITY
# =============================================================================

func _create_textured_material(texture_path: String, properties: Dictionary) -> StandardMaterial3D:
	if texture_path.is_empty():
		return null

	var path := texture_path.to_lower().replace("\\", "/")
	if not path.begins_with("textures/"):
		path = "textures/" + path
	if path.ends_with(".tga"):
		path = path.replace(".tga", ".dds")

	var texture: Texture2D = TextureLoaderScript.load_texture(path)
	if not texture:
		return null

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = texture
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	if not properties.is_empty():
		if "alpha" in properties and properties["alpha"] < 1.0:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	return mat


## Compute vertex AABB → [min, max, center, size]
func _compute_vertex_aabb(vertices: PackedVector3Array) -> Array:
	if vertices.is_empty():
		return [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
	var aabb_min := Vector3(INF, INF, INF)
	var aabb_max := Vector3(-INF, -INF, -INF)
	for v in vertices:
		aabb_min.x = minf(aabb_min.x, v.x)
		aabb_min.y = minf(aabb_min.y, v.y)
		aabb_min.z = minf(aabb_min.z, v.z)
		aabb_max.x = maxf(aabb_max.x, v.x)
		aabb_max.y = maxf(aabb_max.y, v.y)
		aabb_max.z = maxf(aabb_max.z, v.z)
	var center := (aabb_min + aabb_max) * 0.5
	var size := aabb_max - aabb_min
	return [aabb_min, aabb_max, center, size]


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
