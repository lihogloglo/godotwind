@warning_ignore("untyped_declaration", "unsafe_method_access")
extends Node3D
## Visual test for SkeletonProfileAdapter bone mapping.
## Shows 3 skeletons side-by-side: Morrowind Bip01, Mixamo, Generic.
## Green spheres = mapped to SkeletonProfileHumanoid, Red = unmapped.
## Right-click drag to orbit, scroll to zoom.

const SPA := preload("res://src/core/animation/skeleton_profile_adapter.gd")

var _mat_mapped: StandardMaterial3D
var _mat_unmapped: StandardMaterial3D

var _camera: Camera3D
var _yaw := 0.0
var _pitch := -10.0
var _distance := 7.0
var _center := Vector3(0.0, 1.0, 0.0)
var _orbiting := false


func _ready() -> void:
	_create_materials()
	_create_environment()

	_visualize("Morrowind (Bip01)", -3.0, _build_morrowind())
	_visualize("Mixamo", 0.0, _build_mixamo())
	_visualize("Generic (Heuristic)", 3.0, _build_generic())

	_create_ui()


# =========================================================================
# ENVIRONMENT
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


func _create_environment() -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 30, 0)
	add_child(light)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(20, 20)
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
# SKELETON VISUALIZATION
# =========================================================================

func _visualize(title: String, x_offset: float, skeleton: Skeleton3D) -> void:
	var container := Node3D.new()
	container.position.x = x_offset
	add_child(container)
	container.add_child(skeleton)

	var bone_map := SPA.create_bone_map(skeleton)
	if not bone_map:
		return

	# Build lookup: skeleton_bone_name -> profile_bone_name
	var mapped := {}
	var profile := bone_map.profile
	for i in profile.bone_size:
		var pname := profile.get_bone_name(i)
		var sname := bone_map.get_skeleton_bone_name(pname)
		if not sname.is_empty():
			mapped[sname] = pname

	# Draw bones
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)

	for i in skeleton.get_bone_count():
		var bname := skeleton.get_bone_name(i)
		var bpos := skeleton.get_bone_global_rest(i).origin
		var is_mapped: bool = bname in mapped

		# Sphere
		var mi := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.03 if is_mapped else 0.018
		sphere.height = sphere.radius * 2.0
		mi.mesh = sphere
		mi.material_override = _mat_mapped if is_mapped else _mat_unmapped
		mi.position = bpos
		container.add_child(mi)

		# Label (mapped bones only)
		if is_mapped:
			var lbl := Label3D.new()
			lbl.text = mapped[bname]
			lbl.pixel_size = 0.003
			lbl.font_size = 22
			lbl.position = bpos + Vector3(0, 0.055, 0)
			lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
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
	var tlbl := Label3D.new()
	tlbl.text = title
	tlbl.pixel_size = 0.005
	tlbl.font_size = 28
	tlbl.position = Vector3(0, 2.05, 0)
	tlbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tlbl.outline_modulate = Color(0, 0, 0)
	tlbl.outline_size = 10
	container.add_child(tlbl)

	# Stats subtitle
	var mc := SPA.count_mapped_bones(bone_map)
	var tc := skeleton.get_bone_count()
	var stype: int = SPA.detect_skeleton_type(skeleton)
	var type_names := ["UNKNOWN", "MORROWIND", "MIXAMO", "GENERIC"]
	var sname: String = type_names[stype]

	var slbl := Label3D.new()
	slbl.text = "Detected: %s | Mapped: %d/%d profile bones" % [sname, mc, tc]
	slbl.pixel_size = 0.004
	slbl.font_size = 22
	slbl.position = Vector3(0, 1.88, 0)
	slbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	slbl.modulate = Color(0.65, 0.65, 0.75)
	slbl.outline_modulate = Color(0, 0, 0)
	slbl.outline_size = 6
	container.add_child(slbl)


# =========================================================================
# SKELETON BUILDERS — T-pose with world positions
# =========================================================================

func _build_morrowind() -> Skeleton3D:
	return _skeleton_from_defs([
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
	])


func _build_mixamo() -> Skeleton3D:
	return _skeleton_from_defs([
		["mixamorig1_Hips", "", Vector3(0, 1.0, 0)],
		["mixamorig1_Spine", "mixamorig1_Hips", Vector3(0, 1.12, 0)],
		["mixamorig1_Spine1", "mixamorig1_Spine", Vector3(0, 1.28, 0)],
		["mixamorig1_Spine2", "mixamorig1_Spine1", Vector3(0, 1.44, 0)],
		["mixamorig1_Neck", "mixamorig1_Spine2", Vector3(0, 1.55, 0)],
		["mixamorig1_Head", "mixamorig1_Neck", Vector3(0, 1.65, 0)],
		["mixamorig1_LeftShoulder", "mixamorig1_Spine2", Vector3(-0.08, 1.50, 0)],
		["mixamorig1_LeftArm", "mixamorig1_LeftShoulder", Vector3(-0.22, 1.50, 0)],
		["mixamorig1_LeftForeArm", "mixamorig1_LeftArm", Vector3(-0.48, 1.50, 0)],
		["mixamorig1_LeftHand", "mixamorig1_LeftForeArm", Vector3(-0.72, 1.50, 0)],
		["mixamorig1_RightShoulder", "mixamorig1_Spine2", Vector3(0.08, 1.50, 0)],
		["mixamorig1_RightArm", "mixamorig1_RightShoulder", Vector3(0.22, 1.50, 0)],
		["mixamorig1_RightForeArm", "mixamorig1_RightArm", Vector3(0.48, 1.50, 0)],
		["mixamorig1_RightHand", "mixamorig1_RightForeArm", Vector3(0.72, 1.50, 0)],
		["mixamorig1_LeftUpLeg", "mixamorig1_Hips", Vector3(-0.10, 0.95, 0)],
		["mixamorig1_LeftLeg", "mixamorig1_LeftUpLeg", Vector3(-0.10, 0.52, 0)],
		["mixamorig1_LeftFoot", "mixamorig1_LeftLeg", Vector3(-0.10, 0.05, 0)],
		["mixamorig1_LeftToeBase", "mixamorig1_LeftFoot", Vector3(-0.10, 0.02, 0.10)],
		["mixamorig1_RightUpLeg", "mixamorig1_Hips", Vector3(0.10, 0.95, 0)],
		["mixamorig1_RightLeg", "mixamorig1_RightUpLeg", Vector3(0.10, 0.52, 0)],
		["mixamorig1_RightFoot", "mixamorig1_RightLeg", Vector3(0.10, 0.05, 0)],
		["mixamorig1_RightToeBase", "mixamorig1_RightFoot", Vector3(0.10, 0.02, 0.10)],
	])


func _build_generic() -> Skeleton3D:
	return _skeleton_from_defs([
		["Hips", "", Vector3(0, 1.0, 0)],
		["Spine", "Hips", Vector3(0, 1.12, 0)],
		["Chest", "Spine", Vector3(0, 1.30, 0)],
		["Neck", "Chest", Vector3(0, 1.55, 0)],
		["Head", "Neck", Vector3(0, 1.65, 0)],
		["LeftShoulder", "Chest", Vector3(-0.08, 1.50, 0)],
		["Left_UpperArm", "LeftShoulder", Vector3(-0.22, 1.50, 0)],
		["Left_LowerArm", "Left_UpperArm", Vector3(-0.48, 1.50, 0)],
		["Left_Hand", "Left_LowerArm", Vector3(-0.72, 1.50, 0)],
		["RightShoulder", "Chest", Vector3(0.08, 1.50, 0)],
		["Right_UpperArm", "RightShoulder", Vector3(0.22, 1.50, 0)],
		["Right_LowerArm", "Right_UpperArm", Vector3(0.48, 1.50, 0)],
		["Right_Hand", "Right_LowerArm", Vector3(0.72, 1.50, 0)],
		["Left_UpperLeg", "Hips", Vector3(-0.10, 0.95, 0)],
		["Left_LowerLeg", "Left_UpperLeg", Vector3(-0.10, 0.52, 0)],
		["Left_Foot", "Left_LowerLeg", Vector3(-0.10, 0.05, 0)],
		["Right_UpperLeg", "Hips", Vector3(0.10, 0.95, 0)],
		["Right_LowerLeg", "Right_UpperLeg", Vector3(0.10, 0.52, 0)],
		["Right_Foot", "Right_LowerLeg", Vector3(0.10, 0.05, 0)],
	])


func _skeleton_from_defs(defs: Array) -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	var indices := {}
	var world_pos := {}

	for def in defs:
		var idx := skeleton.add_bone(def[0])
		indices[def[0]] = idx
		world_pos[def[0]] = def[2]

	for def in defs:
		var bname: String = def[0]
		var pname: String = def[1]
		var wpos: Vector3 = def[2]

		if not pname.is_empty() and pname in indices:
			skeleton.set_bone_parent(indices[bname], indices[pname])
			var ppos: Vector3 = world_pos[pname]
			skeleton.set_bone_rest(indices[bname], Transform3D(Basis.IDENTITY, wpos - ppos))
		else:
			skeleton.set_bone_rest(indices[bname], Transform3D(Basis.IDENTITY, wpos))

	return skeleton


# =========================================================================
# UI
# =========================================================================

func _create_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)

	var title := Label.new()
	title.text = "Bone Mapping Test — Right-click drag to orbit, scroll to zoom"
	title.position = Vector2(10, 10)
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(0.8, 0.8, 0.9))
	canvas.add_child(title)

	var legend := Label.new()
	legend.text = "Green = Mapped to SkeletonProfileHumanoid  |  Red = Unmapped"
	legend.position = Vector2(10, 32)
	legend.add_theme_font_size_override("font_size", 14)
	legend.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	canvas.add_child(legend)


# =========================================================================
# CAMERA
# =========================================================================

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_orbiting = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_distance = maxf(2.0, _distance - 0.5)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_distance = minf(15.0, _distance + 0.5)
	elif event is InputEventMouseMotion and _orbiting:
		_yaw -= event.relative.x * 0.3
		_pitch = clampf(_pitch - event.relative.y * 0.3, -80.0, 80.0)


func _process(delta: float) -> void:
	if not _orbiting:
		_yaw += delta * 8.0
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
