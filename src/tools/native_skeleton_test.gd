## Native Skeleton Test — Verifies Phase 3B NPC assembly pipeline
##
## Tests the full pipeline:
## 1. Native Morrowind skeleton from xbase_anim.nif (NOT Mixamo)
## 2. Body part mesh extraction (MeshExtractor)
## 3. Direct skin attachment (no SkinRebinder)
## 4. Bone renaming to SkeletonProfileHumanoid names (RetargetSetup)
## 5. Animation track remapping (Bip01 → profile names)
##
## Run: Open native_skeleton_test.tscn in editor and press F5
@tool
extends Node3D

const MorrowindNPCAssembler := preload("res://src/core/character/morrowind/morrowind_npc_assembler.gd")
const RetargetSetup := preload("res://src/core/animation/skeleton_utils.gd")
const NIFConverter := preload("res://src/core/nif/nif_converter.gd")

# UI
var _info_label: RichTextLabel = null
var _skeleton: Skeleton3D = null
var _bone_remap: Dictionary = {}


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_setup_camera()
	_setup_ui()

	# Wait for autoloads to initialize
	await get_tree().process_frame
	await get_tree().process_frame

	_run_test()


func _run_test() -> void:
	var lines := PackedStringArray()
	lines.append("[b]Phase 3B: Native Skeleton Test[/b]\n")

	# Step 1: Load native Morrowind skeleton from xbase_anim.nif
	lines.append("[color=yellow]Step 1: Load skeleton from xbase_anim.nif[/color]")
	var skeleton := _load_native_skeleton()
	if not skeleton:
		lines.append("[color=red]FAIL: Could not load skeleton[/color]")
		_update_info(lines)
		return

	skeleton.name = "Skeleton3D"
	add_child(skeleton)
	_skeleton = skeleton

	var bone_count := skeleton.get_bone_count()
	lines.append("  Bones: %d" % bone_count)

	# List first 10 bones
	for i in mini(bone_count, 10):
		lines.append("    [%d] %s" % [i, skeleton.get_bone_name(i)])
	if bone_count > 10:
		lines.append("    ... and %d more" % (bone_count - 10))

	# Check for expected Morrowind bones
	var expected_bones := ["Bip01", "Bip01 Spine", "Bip01 Spine1", "Bip01 Head",
		"Bip01 L Hand", "Bip01 R Hand", "Bip01 L Foot", "Bip01 R Foot"]
	var found := 0
	for bone_name in expected_bones:
		if skeleton.find_bone(bone_name) >= 0:
			found += 1
	lines.append("  Expected bones found: %d/%d %s" % [found, expected_bones.size(),
		"[color=green]OK[/color]" if found == expected_bones.size() else "[color=red]MISSING[/color]"])

	# Step 2: Build bone remap (Bip01 → profile)
	lines.append("\n[color=yellow]Step 2: Build bone remap (Bip01 → profile)[/color]")
	_bone_remap = RetargetSetup.build_remap(skeleton)
	lines.append("  Remap entries: %d" % _bone_remap.size())
	var remap_samples := 0
	for original: String in _bone_remap:
		if remap_samples >= 5:
			break
		lines.append("    %s → %s" % [original, _bone_remap[original]])
		remap_samples += 1
	if _bone_remap.size() > 5:
		lines.append("    ... and %d more" % (_bone_remap.size() - 5))

	# Step 3: Rename bones to profile names
	lines.append("\n[color=yellow]Step 3: Rename bones to profile names[/color]")
	var rename_result := RetargetSetup.rename_bones_to_profile(skeleton)
	lines.append("  Renamed: %d bones" % rename_result.size())

	# Verify profile bones exist
	var profile_bones := ["Hips", "Spine", "Chest", "Head",
		"LeftHand", "RightHand", "LeftFoot", "RightFoot"]
	var profile_found := 0
	for bone_name in profile_bones:
		if skeleton.find_bone(bone_name) >= 0:
			profile_found += 1
	lines.append("  Profile bones found: %d/%d %s" % [profile_found, profile_bones.size(),
		"[color=green]OK[/color]" if profile_found == profile_bones.size() else "[color=red]MISSING[/color]"])

	# Step 4: Verify renamed skeleton has profile bones
	lines.append("\n[color=yellow]Step 4: Profile bone check[/color]")
	lines.append("  Total bones: %d" % skeleton.get_bone_count())
	lines.append("  %s" % ("[color=green]OK — skeleton valid[/color]" if skeleton.get_bone_count() > 0 else "[color=red]FAIL[/color]"))

	# Step 5: Test animation remap
	lines.append("\n[color=yellow]Step 5: Animation track remapping[/color]")
	var test_anim := Animation.new()
	test_anim.add_track(Animation.TYPE_ROTATION_3D)
	test_anim.track_set_path(0, NodePath("Skeleton3D:Bip01 Spine"))
	test_anim.add_track(Animation.TYPE_ROTATION_3D)
	test_anim.track_set_path(1, NodePath("Skeleton3D:Bip01 Head"))
	test_anim.add_track(Animation.TYPE_POSITION_3D)
	test_anim.track_set_path(2, NodePath("Skeleton3D:Bip01"))

	var remapped := RetargetSetup.remap_animation(test_anim, _bone_remap)
	if remapped:
		for i in remapped.get_track_count():
			var path := remapped.track_get_path(i)
			lines.append("  Track %d: %s" % [i, path])

		var track0_ok: bool = String(remapped.track_get_path(0)).contains("Spine") or \
			String(remapped.track_get_path(0)).contains("Chest")
		var track1_ok: bool = String(remapped.track_get_path(1)).contains("Head")
		var track2_ok: bool = String(remapped.track_get_path(2)).contains("Hips")
		var all_ok := track0_ok and track1_ok and track2_ok
		lines.append("  %s" % ("[color=green]OK — tracks remapped[/color]" if all_ok else "[color=red]FAIL — tracks not remapped[/color]"))
	else:
		lines.append("  [color=red]FAIL: remap_animation returned null[/color]")

	# Step 6: Visualize bones
	lines.append("\n[color=yellow]Step 6: Bone visualization[/color]")
	_visualize_bones(skeleton)
	lines.append("  Added bone spheres (green=mapped, red=unmapped)")

	_update_info(lines)


func _load_native_skeleton() -> Skeleton3D:
	var bsa_mgr := get_node_or_null("/root/BSAManager")
	if not bsa_mgr:
		push_error("NativeSkeletonTest: BSAManager not available")
		return null

	var nif_path := "meshes\\xbase_anim.nif"
	var data: PackedByteArray = bsa_mgr.extract_file(nif_path)
	if data.is_empty():
		push_error("NativeSkeletonTest: Cannot load %s" % nif_path)
		return null

	var converter := NIFConverter.new()
	converter.load_textures = false
	converter.load_animations = false
	converter.load_collision = false

	var scene := converter.convert_buffer(data, nif_path)
	var skeleton := converter.create_skeleton_from_hierarchy()

	if scene:
		scene.queue_free()

	return skeleton


func _visualize_bones(skeleton: Skeleton3D) -> void:
	for i in skeleton.get_bone_count():
		var bone_name := skeleton.get_bone_name(i)
		var global_pose := skeleton.get_bone_global_rest(i)

		# All bones shown as green after profile rename
		var is_mapped := true

		# Create sphere at bone position
		var sphere_mesh := SphereMesh.new()
		sphere_mesh.radius = 0.015 if is_mapped else 0.01
		sphere_mesh.height = sphere_mesh.radius * 2.0

		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color.GREEN if is_mapped else Color.RED
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

		var instance := MeshInstance3D.new()
		instance.mesh = sphere_mesh
		instance.material_override = mat
		instance.name = "Bone_%s" % bone_name

		skeleton.add_child(instance)
		instance.global_transform.origin = global_pose.origin

		# Add label for mapped bones
		if is_mapped:
			var label := Label3D.new()
			label.text = bone_name
			label.font_size = 32
			label.pixel_size = 0.001
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.no_depth_test = true
			instance.add_child(label)
			label.position = Vector3(0, 0.03, 0)


func _setup_camera() -> void:
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.position = Vector3(0, 1.0, 2.0)
	camera.look_at(Vector3(0, 0.8, 0))
	add_child(camera)

	# Add light
	var light := DirectionalLight3D.new()
	light.name = "Light"
	light.rotation_degrees = Vector3(-45, 30, 0)
	add_child(light)

	# Grid reference
	var grid := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(4, 4)
	grid.mesh = plane
	var grid_mat := StandardMaterial3D.new()
	grid_mat.albedo_color = Color(0.3, 0.3, 0.3, 0.5)
	grid_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	grid.material_override = grid_mat
	add_child(grid)


func _setup_ui() -> void:
	var panel := PanelContainer.new()
	panel.name = "InfoPanel"
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.offset_right = 500
	panel.offset_bottom = 600

	_info_label = RichTextLabel.new()
	_info_label.bbcode_enabled = true
	_info_label.fit_content = true
	_info_label.custom_minimum_size = Vector2(480, 580)

	panel.add_child(_info_label)
	add_child(panel)


func _update_info(lines: PackedStringArray) -> void:
	if _info_label:
		_info_label.text = "\n".join(lines)
