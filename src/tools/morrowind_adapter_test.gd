@warning_ignore("untyped_declaration", "unsafe_method_access", "inferred_declaration")
extends Node3D
## Morrowind Adapter Test — Verifies Phase 1C refactoring
##
## Shows a Morrowind skeleton processed through the full pipeline:
##   1. SkeletonProfileAdapter auto-detects Bip01 naming
##   2. HumanoidAnimationSystem._build_bone_map() uses SPA (via parent, no MW override)
##   3. IKController resolves bones through BoneMap
##   4. AnimationBlendMask resolves mask roots through BoneMap
##
## Visual indicators:
##   - GREEN bones = mapped to SkeletonProfileHumanoid
##   - RED bones = unmapped
##   - YELLOW highlighted = IK-relevant bones (foot/hand chains)
##   - CYAN highlighted = blend mask root bones
##   - Left panel shows mapping details
##
## Controls:
##   Right-click drag = orbit, Scroll = zoom

const SPA := preload("res://src/core/animation/skeleton_profile_adapter.gd")
const BlendMask := preload("res://src/core/animation/animation_blend_mask.gd")

var _camera: Camera3D
var _yaw := 20.0
var _pitch := -10.0
var _distance := 5.0
var _center := Vector3(0, 1.0, 0)
var _orbiting := false
var _info_label: Label

# Materials
var _mat_mapped: StandardMaterial3D
var _mat_unmapped: StandardMaterial3D
var _mat_ik: StandardMaterial3D
var _mat_mask_root: StandardMaterial3D


func _ready() -> void:
	_create_materials()
	_create_environment()
	_create_ui()

	var skeleton := _build_morrowind_skeleton()
	_run_full_pipeline(skeleton)


# =========================================================================
# FULL PIPELINE TEST
# =========================================================================

func _run_full_pipeline(skeleton: Skeleton3D) -> void:
	var container := Node3D.new()
	add_child(container)
	container.add_child(skeleton)

	# Step 1: SPA creates BoneMap (auto-detects Morrowind)
	var bone_map := SPA.create_bone_map(skeleton)
	var skel_type := SPA.detect_skeleton_type(skeleton)
	var mapped_count := SPA.count_mapped_bones(bone_map)

	# Step 2: Simulate HumanoidAnimationSystem._build_bone_map()
	# This is exactly what the parent class does — profile_name -> bone_index
	var humanoid_bone_map := {}
	var profile := bone_map.profile
	for i in profile.bone_size:
		var profile_name := profile.get_bone_name(i)
		var skel_name := bone_map.get_skeleton_bone_name(profile_name)
		if not skel_name.is_empty():
			var idx := skeleton.find_bone(skel_name)
			if idx >= 0:
				humanoid_bone_map[profile_name] = idx

	# Step 3: Simulate IKController._find_bone_indices()
	var ik_to_profile := {
		"hips": "Hips", "head": "Head", "neck": "Neck",
		"left_upper_leg": "LeftUpperLeg", "left_lower_leg": "LeftLowerLeg",
		"left_foot": "LeftFoot", "right_upper_leg": "RightUpperLeg",
		"right_lower_leg": "RightLowerLeg", "right_foot": "RightFoot",
		"left_upper_arm": "LeftUpperArm", "left_forearm": "LeftLowerArm",
		"left_hand": "LeftHand", "right_upper_arm": "RightUpperArm",
		"right_forearm": "RightLowerArm", "right_hand": "RightHand",
	}
	var ik_bones := {}
	for ik_key in ik_to_profile:
		var profile_bone: String = ik_to_profile[ik_key]
		var idx := SPA.get_bone_index(skeleton, profile_bone)
		if idx >= 0:
			ik_bones[ik_key] = idx

	# Step 4: Build blend masks
	var blend_mask := BlendMask.new()
	blend_mask.build_masks(skeleton)
	var torso_bones := blend_mask.get_mask_bones(BlendMask.MaskType.TORSO)
	var left_arm_bones := blend_mask.get_mask_bones(BlendMask.MaskType.LEFT_ARM)
	var right_arm_bones := blend_mask.get_mask_bones(BlendMask.MaskType.RIGHT_ARM)

	# Mask root bone indices
	var mask_root_indices := []
	var chest_idx := SPA.get_bone_index(skeleton, "Chest")
	var lshoulder_idx := SPA.get_bone_index(skeleton, "LeftShoulder")
	var rshoulder_idx := SPA.get_bone_index(skeleton, "RightShoulder")
	if chest_idx >= 0:
		mask_root_indices.append(chest_idx)
	if lshoulder_idx >= 0:
		mask_root_indices.append(lshoulder_idx)
	if rshoulder_idx >= 0:
		mask_root_indices.append(rshoulder_idx)

	# Build lookup for visualization
	var mapped_bones := {}  # skeleton_bone_name -> profile_name
	for i in profile.bone_size:
		var pname := profile.get_bone_name(i)
		var sname := bone_map.get_skeleton_bone_name(pname)
		if not sname.is_empty():
			mapped_bones[sname] = pname

	var ik_bone_set := {}  # bone_index -> true (for highlighting)
	for ik_key in ik_bones:
		ik_bone_set[ik_bones[ik_key]] = true

	# Visualize
	_visualize_bones(container, skeleton, mapped_bones, ik_bone_set, mask_root_indices)

	# Build info text
	var type_names := ["UNKNOWN", "MORROWIND", "MIXAMO", "GENERIC"]
	var info := "MORROWIND ADAPTER TEST\n"
	info += "═══════════════════════════\n\n"
	info += "Skeleton Type: %s\n" % type_names[skel_type]
	info += "Mapped Bones: %d / %d profile\n" % [mapped_count, profile.bone_size]
	info += "Humanoid Map: %d entries\n\n" % humanoid_bone_map.size()

	info += "IK BONE RESOLUTION\n"
	info += "───────────────────────────\n"
	for ik_key in ik_to_profile:
		var profile_bone: String = ik_to_profile[ik_key]
		var idx: int = ik_bones.get(ik_key, -1)
		var skel_name := skeleton.get_bone_name(idx) if idx >= 0 else "NOT FOUND"
		var status := "OK" if idx >= 0 else "MISSING"
		info += "  %s -> %s [%s]\n" % [ik_key, skel_name, status]

	info += "\nBLEND MASK ROOTS\n"
	info += "───────────────────────────\n"
	info += "  TORSO root: %s (%d bones)\n" % [
		skeleton.get_bone_name(chest_idx) if chest_idx >= 0 else "MISSING", torso_bones.size()]
	info += "  LEFT_ARM root: %s (%d bones)\n" % [
		skeleton.get_bone_name(lshoulder_idx) if lshoulder_idx >= 0 else "MISSING", left_arm_bones.size()]
	info += "  RIGHT_ARM root: %s (%d bones)\n" % [
		skeleton.get_bone_name(rshoulder_idx) if rshoulder_idx >= 0 else "MISSING", right_arm_bones.size()]

	info += "\nKEY MAPPINGS\n"
	info += "───────────────────────────\n"
	var key_mappings := ["Hips", "Spine", "Chest", "UpperChest", "Neck", "Head",
		"LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "RightUpperLeg", "RightLowerLeg", "RightFoot",
		"LeftShoulder", "LeftUpperArm", "LeftLowerArm", "LeftHand",
		"RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand"]
	for pname in key_mappings:
		var sname := bone_map.get_skeleton_bone_name(pname)
		info += "  %s -> %s\n" % [pname, sname if not sname.is_empty() else "---"]

	_info_label.text = info


func _visualize_bones(container: Node3D, skeleton: Skeleton3D,
		mapped_bones: Dictionary, ik_bone_set: Dictionary, mask_root_indices: Array) -> void:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)

	for i in skeleton.get_bone_count():
		var bname := skeleton.get_bone_name(i)
		var bpos := skeleton.get_bone_global_rest(i).origin
		var is_mapped: bool = bname in mapped_bones
		var is_ik: bool = i in ik_bone_set
		var is_mask_root: bool = i in mask_root_indices

		# Choose material
		var mat: StandardMaterial3D
		if is_mask_root:
			mat = _mat_mask_root
		elif is_ik:
			mat = _mat_ik
		elif is_mapped:
			mat = _mat_mapped
		else:
			mat = _mat_unmapped

		# Sphere at joint
		var mi := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.04 if (is_ik or is_mask_root) else (0.03 if is_mapped else 0.018)
		sphere.height = sphere.radius * 2.0
		mi.mesh = sphere
		mi.material_override = mat
		mi.position = bpos
		container.add_child(mi)

		# Label
		if is_mapped:
			var lbl := Label3D.new()
			var prefix := ""
			if is_mask_root:
				prefix = "[MASK] "
			elif is_ik:
				prefix = "[IK] "
			lbl.text = prefix + mapped_bones[bname]
			lbl.pixel_size = 0.003
			lbl.font_size = 20
			lbl.position = bpos + Vector3(0, 0.06, 0)
			lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			if is_mask_root:
				lbl.modulate = Color(0.4, 1.0, 1.0)
			elif is_ik:
				lbl.modulate = Color(1.0, 0.95, 0.5)
			else:
				lbl.modulate = Color(0.85, 1.0, 0.85)
			lbl.outline_modulate = Color(0, 0, 0)
			lbl.outline_size = 8
			container.add_child(lbl)

		# Line to parent
		var pidx := skeleton.get_bone_parent(i)
		if pidx >= 0:
			var ppos := skeleton.get_bone_global_rest(pidx).origin
			im.surface_set_color(Color(0.4, 0.4, 0.5))
			im.surface_add_vertex(bpos)
			im.surface_add_vertex(ppos)

	im.surface_end()

	var lmi := MeshInstance3D.new()
	lmi.mesh = im
	var lmat := StandardMaterial3D.new()
	lmat.vertex_color_use_as_albedo = true
	lmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lmi.material_override = lmat
	container.add_child(lmi)

	# Title
	var title := Label3D.new()
	title.text = "Morrowind Bip01 — Full Pipeline"
	title.pixel_size = 0.005
	title.font_size = 28
	title.position = Vector3(0, 2.1, 0)
	title.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	title.outline_modulate = Color(0, 0, 0)
	title.outline_size = 10
	container.add_child(title)


# =========================================================================
# ENVIRONMENT & MATERIALS
# =========================================================================

func _create_materials() -> void:
	_mat_mapped = StandardMaterial3D.new()
	_mat_mapped.albedo_color = Color(0.2, 0.9, 0.3)
	_mat_mapped.emission_enabled = true
	_mat_mapped.emission = Color(0.1, 0.4, 0.15)

	_mat_unmapped = StandardMaterial3D.new()
	_mat_unmapped.albedo_color = Color(0.9, 0.2, 0.2)
	_mat_unmapped.emission_enabled = true
	_mat_unmapped.emission = Color(0.4, 0.1, 0.1)

	_mat_ik = StandardMaterial3D.new()
	_mat_ik.albedo_color = Color(1.0, 0.9, 0.2)
	_mat_ik.emission_enabled = true
	_mat_ik.emission = Color(0.5, 0.45, 0.1)

	_mat_mask_root = StandardMaterial3D.new()
	_mat_mask_root.albedo_color = Color(0.2, 1.0, 1.0)
	_mat_mask_root.emission_enabled = true
	_mat_mask_root.emission = Color(0.1, 0.5, 0.5)


func _create_environment() -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 30, 0)
	add_child(light)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(12, 12)
	ground.mesh = plane
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.12, 0.12, 0.18)
	ground.material_override = gmat
	add_child(ground)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.08, 0.08, 0.12)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.3, 0.3, 0.4)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	_camera = Camera3D.new()
	_camera.current = true
	add_child(_camera)
	_update_camera()


# =========================================================================
# SKELETON BUILDER
# =========================================================================

func _build_morrowind_skeleton() -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	var defs := [
		["Bip01", "", Vector3(0, 1.0, 0)],
		["Bip01 Spine", "Bip01", Vector3(0, 1.12, 0)],
		["Bip01 Spine1", "Bip01 Spine", Vector3(0, 1.28, 0)],
		["Bip01 Spine2", "Bip01 Spine1", Vector3(0, 1.44, 0)],
		["Bip01 Neck", "Bip01 Spine2", Vector3(0, 1.55, 0)],
		["Bip01 Head", "Bip01 Neck", Vector3(0, 1.65, 0)],
		["Bip01 L Clavicle", "Bip01 Spine2", Vector3(-0.08, 1.50, 0)],
		["Bip01 L UpperArm", "Bip01 L Clavicle", Vector3(-0.22, 1.50, 0)],
		["Bip01 L Forearm", "Bip01 L UpperArm", Vector3(-0.48, 1.50, 0)],
		["Bip01 L Hand", "Bip01 L Forearm", Vector3(-0.72, 1.50, 0)],
		["Bip01 R Clavicle", "Bip01 Spine2", Vector3(0.08, 1.50, 0)],
		["Bip01 R UpperArm", "Bip01 R Clavicle", Vector3(0.22, 1.50, 0)],
		["Bip01 R Forearm", "Bip01 R UpperArm", Vector3(0.48, 1.50, 0)],
		["Bip01 R Hand", "Bip01 R Forearm", Vector3(0.72, 1.50, 0)],
		["Bip01 L Thigh", "Bip01", Vector3(-0.10, 0.95, 0)],
		["Bip01 L Calf", "Bip01 L Thigh", Vector3(-0.10, 0.52, 0)],
		["Bip01 L Foot", "Bip01 L Calf", Vector3(-0.10, 0.05, 0)],
		["Bip01 L Toe0", "Bip01 L Foot", Vector3(-0.10, 0.02, 0.10)],
		["Bip01 R Thigh", "Bip01", Vector3(0.10, 0.95, 0)],
		["Bip01 R Calf", "Bip01 R Thigh", Vector3(0.10, 0.52, 0)],
		["Bip01 R Foot", "Bip01 R Calf", Vector3(0.10, 0.05, 0)],
		["Bip01 R Toe0", "Bip01 R Foot", Vector3(0.10, 0.02, 0.10)],
	]

	var indices := {}
	var wpos := {}
	for def in defs:
		var idx := skeleton.add_bone(def[0])
		indices[def[0]] = idx
		wpos[def[0]] = def[2]

	for def in defs:
		var bname: String = def[0]
		var pname: String = def[1]
		var wp: Vector3 = def[2]
		if not pname.is_empty() and pname in indices:
			skeleton.set_bone_parent(indices[bname], indices[pname])
			var pp: Vector3 = wpos[pname]
			skeleton.set_bone_rest(indices[bname], Transform3D(Basis.IDENTITY, wp - pp))
		else:
			skeleton.set_bone_rest(indices[bname], Transform3D(Basis.IDENTITY, wp))

	return skeleton


# =========================================================================
# UI & CAMERA
# =========================================================================

func _create_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)

	# Info panel on left
	var panel := PanelContainer.new()
	panel.position = Vector2(10, 10)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.7)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", style)
	canvas.add_child(panel)

	_info_label = Label.new()
	_info_label.add_theme_font_size_override("font_size", 13)
	_info_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.95))
	panel.add_child(_info_label)

	# Legend
	var legend := Label.new()
	legend.text = "Green = Mapped  |  Yellow = IK bone  |  Cyan = Blend mask root  |  Red = Unmapped"
	legend.position = Vector2(10, 680)
	legend.add_theme_font_size_override("font_size", 14)
	legend.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	canvas.add_child(legend)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_orbiting = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_distance = maxf(2.0, _distance - 0.4)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_distance = minf(10.0, _distance + 0.4)
	elif event is InputEventMouseMotion and _orbiting:
		_yaw -= event.relative.x * 0.3
		_pitch = clampf(_pitch - event.relative.y * 0.3, -80.0, 80.0)


func _process(_delta: float) -> void:
	if not _orbiting:
		_yaw += _delta * 5.0
	_update_camera()


func _update_camera() -> void:
	var ry := deg_to_rad(_yaw)
	var rp := deg_to_rad(_pitch)
	var offset := Vector3(
		_distance * cos(rp) * sin(ry),
		_distance * sin(rp),
		_distance * cos(rp) * cos(ry)
	)
	_camera.global_position = _center + offset
	_camera.look_at(_center)
