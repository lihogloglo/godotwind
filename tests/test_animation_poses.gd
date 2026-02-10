## Headless animation validation test
## Compares skeleton rest poses against KF keyframe values to determine:
## 1. Whether keyframes are ABSOLUTE (keyframe[0] ≈ rest) or RELATIVE (keyframe[0] ≈ identity)
## 2. Whether the bone hierarchy is intact (global = parent_global * rest * pose)
## 3. Position deltas and rotation magnitudes for sanity checking
##
## Run with: godot --headless --script res://tests/test_animation_poses.gd
extends SceneTree

@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_property_access", "unsafe_cast", "inferred_declaration")

# Use load() instead of preload() — autoloads (Log) must be initialized before
# dependent scripts can compile. load() defers compilation to runtime.
var BSAReaderScript: GDScript
var NIFKFLoaderScript: GDScript
var NIFConverterScript: GDScript
var NIFReaderScript: GDScript
var Defs: GDScript
var CS: GDScript

var _bsa: RefCounted
var _ran := false


func _init() -> void:
	print("Waiting for autoloads to initialize...")


func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true

	# Load scripts now that autoloads (Log) are available
	BSAReaderScript = load("res://src/core/bsa/bsa_reader.gd")
	NIFKFLoaderScript = load("res://src/core/nif/nif_kf_loader.gd")
	NIFConverterScript = load("res://src/core/nif/nif_converter.gd")
	NIFReaderScript = load("res://src/core/nif/nif_reader.gd")
	Defs = load("res://src/core/nif/nif_defs.gd")
	CS = load("res://src/core/coordinate_system.gd")

	_run_test()
	return true


func _run_test() -> void:
	_header("ANIMATION POSE VALIDATION TEST")

	var bsa_path := _find_morrowind_bsa()
	if bsa_path.is_empty():
		print("ERROR: Could not find Morrowind.bsa")
		quit(1)
		return

	_bsa = BSAReaderScript.new()
	if _bsa.open(bsa_path) != OK:
		print("ERROR: Could not open BSA: %s" % bsa_path)
		quit(1)
		return

	print("BSA: %s" % bsa_path)
	print("")

	# =========================================================================
	# 1. Load skeleton from xbase_anim.nif
	# =========================================================================
	_header("SKELETON (xbase_anim.nif)")

	var skeleton := _load_skeleton("meshes\\xbase_anim.nif")
	if not skeleton:
		print("FATAL: Could not build skeleton")
		quit(1)
		return

	print("Bones: %d" % skeleton.get_bone_count())
	print("")

	# Print rest pose table
	print("%-4s %-28s %-4s %-44s %s" % ["Idx", "Bone Name", "Par", "Rest Rotation (quat xyzw)", "Rest Position"])
	print("-".repeat(140))
	for i in skeleton.get_bone_count():
		var rest := skeleton.get_bone_rest(i)
		var q := rest.basis.get_rotation_quaternion()
		var p := rest.origin
		print("%-4d %-28s %-4d (%8.4f, %8.4f, %8.4f, %8.4f)    (%8.4f, %8.4f, %8.4f)" % [
			i, skeleton.get_bone_name(i), skeleton.get_bone_parent(i),
			q.x, q.y, q.z, q.w,
			p.x, p.y, p.z
		])
	print("")

	# =========================================================================
	# 2. Load KF animations (raw, no bone remap)
	# =========================================================================
	_header("ANIMATIONS (xbase_anim.kf)")

	var animations := _load_kf("meshes\\xbase_anim.kf")
	if animations.is_empty():
		print("FATAL: No animations loaded from KF")
		quit(1)
		return

	print("Animations loaded: %d" % animations.size())
	for anim_name: String in animations:
		var anim: Animation = animations[anim_name]
		print("  '%s': %.2fs, %d tracks" % [anim_name, anim.length, anim.get_track_count()])
	print("")

	# =========================================================================
	# 3. Find idle animation
	# =========================================================================
	var idle_anim: Animation = null
	var idle_name := ""
	for anim_name: String in animations:
		if anim_name.to_lower() == "idle":
			idle_anim = animations[anim_name]
			idle_name = anim_name
			break
	if not idle_anim:
		# Try substring match
		for anim_name: String in animations:
			if "idle" in anim_name.to_lower():
				idle_anim = animations[anim_name]
				idle_name = anim_name
				break
	if not idle_anim:
		print("WARNING: No idle animation found! Using first animation.")
		idle_name = animations.keys()[0]
		idle_anim = animations[idle_name]

	print("Using animation: '%s' (%.2fs, %d tracks)" % [idle_name, idle_anim.length, idle_anim.get_track_count()])
	print("")

	# =========================================================================
	# 4. Compare rest pose vs keyframe frame 0
	# =========================================================================
	_header("REST vs KEYFRAME COMPARISON (frame 0 of '%s')" % idle_name)

	# Build a map of bone_name -> {rot_track_idx, pos_track_idx} in the animation
	var bone_tracks := _map_bone_tracks(idle_anim)

	var absolute_count := 0
	var relative_count := 0
	var no_track_count := 0

	print("%-28s | %-44s | %-44s | %-10s | %s" % [
		"Bone Name", "Rest Rotation (quat xyzw)", "KF Frame0 Rotation (quat xyzw)", "Angle(deg)", "Verdict"
	])
	print("-".repeat(190))

	for i in skeleton.get_bone_count():
		var bone_name := skeleton.get_bone_name(i)
		var rest := skeleton.get_bone_rest(i)
		var rest_q := rest.basis.get_rotation_quaternion()

		# Find matching track in animation
		# Track paths are ".:BoneName" — the bone name is the subname
		var track_key := bone_name.to_lower()
		if track_key not in bone_tracks:
			print("%-28s | (%8.4f, %8.4f, %8.4f, %8.4f) | %-44s | %-10s | NO TRACK" % [
				bone_name,
				rest_q.x, rest_q.y, rest_q.z, rest_q.w,
				"---", "---"
			])
			no_track_count += 1
			continue

		var track_info: Dictionary = bone_tracks[track_key]
		var kf_rot := Quaternion.IDENTITY
		var has_rot := false

		if track_info.has("rot_idx"):
			var rot_idx: int = track_info["rot_idx"]
			if idle_anim.track_get_key_count(rot_idx) > 0:
				kf_rot = idle_anim.rotation_track_interpolate(rot_idx, 0.0)
				has_rot = true

		if not has_rot:
			print("%-28s | (%8.4f, %8.4f, %8.4f, %8.4f) | %-44s | %-10s | NO ROT KEYS" % [
				bone_name,
				rest_q.x, rest_q.y, rest_q.z, rest_q.w,
				"---", "---"
			])
			continue

		# Compute angle between rest and keyframe quaternions
		var angle_to_rest := _quat_angle_deg(rest_q, kf_rot)
		# Compute angle from identity
		var angle_to_identity := _quat_angle_deg(Quaternion.IDENTITY, kf_rot)

		var verdict := ""
		if angle_to_rest < 1.0:
			verdict = "ABSOLUTE (≈rest)"
			absolute_count += 1
		elif angle_to_identity < 1.0:
			verdict = "RELATIVE (≈identity)"
			relative_count += 1
		elif angle_to_rest < angle_to_identity:
			verdict = "NEAR-REST (%.1f°)" % angle_to_rest
			absolute_count += 1
		else:
			verdict = "NEAR-IDENT (%.1f°)" % angle_to_identity
			relative_count += 1

		print("%-28s | (%8.4f, %8.4f, %8.4f, %8.4f) | (%8.4f, %8.4f, %8.4f, %8.4f) | %7.2f°   | %s" % [
			bone_name,
			rest_q.x, rest_q.y, rest_q.z, rest_q.w,
			kf_rot.x, kf_rot.y, kf_rot.z, kf_rot.w,
			angle_to_rest, verdict
		])

	print("")
	print("SUMMARY: %d ABSOLUTE (≈rest), %d RELATIVE (≈identity), %d no track" % [absolute_count, relative_count, no_track_count])
	if absolute_count > relative_count:
		print(">>> CONCLUSION: Keyframes appear to be ABSOLUTE (world/parent-space values)")
		print(">>> Godot computes: final = rest * pose")
		print(">>> If KF values ARE absolute, then pose = rest^-1 * kf_value")
		print(">>>   BUT Session 1 showed this conversion FAILS — need deeper investigation")
	elif relative_count > absolute_count:
		print(">>> CONCLUSION: Keyframes appear to be RELATIVE (deltas from rest)")
		print(">>> They should work directly as Godot 'pose' values")
	else:
		print(">>> CONCLUSION: MIXED — need per-bone analysis")
	print("")

	# =========================================================================
	# 5. Position track comparison
	# =========================================================================
	_header("POSITION TRACK COMPARISON (frame 0 of '%s')" % idle_name)

	print("%-28s | %-34s | %-34s | %s" % [
		"Bone Name", "Rest Position", "KF Frame0 Position", "Delta (m)"
	])
	print("-".repeat(150))

	for i in skeleton.get_bone_count():
		var bone_name := skeleton.get_bone_name(i)
		var rest := skeleton.get_bone_rest(i)
		var rest_p := rest.origin

		var track_key := bone_name.to_lower()
		if track_key not in bone_tracks:
			continue

		var track_info: Dictionary = bone_tracks[track_key]
		if not track_info.has("pos_idx"):
			continue

		var pos_idx: int = track_info["pos_idx"]
		if idle_anim.track_get_key_count(pos_idx) == 0:
			continue

		var kf_pos := idle_anim.position_track_interpolate(pos_idx, 0.0)
		var delta := (kf_pos - rest_p).length()

		print("%-28s | (%8.4f, %8.4f, %8.4f)      | (%8.4f, %8.4f, %8.4f)      | %.4f" % [
			bone_name,
			rest_p.x, rest_p.y, rest_p.z,
			kf_pos.x, kf_pos.y, kf_pos.z,
			delta
		])
	print("")

	# =========================================================================
	# 6. Also load RAW (pre-conversion) data for comparison
	# =========================================================================
	_header("RAW NIF DATA (pre-coordinate-conversion)")
	_dump_raw_nif_data("meshes\\xbase_anim.nif", "meshes\\xbase_anim.kf")

	# =========================================================================
	# 7. Bone hierarchy integrity check
	# =========================================================================
	_header("BONE HIERARCHY INTEGRITY")
	_check_hierarchy(skeleton)

	_header("TEST COMPLETE")
	quit(0)


# =============================================================================
# RAW NIF DATA DUMP (pre-conversion)
# =============================================================================

func _dump_raw_nif_data(nif_path: String, kf_path: String) -> void:
	# Load NIF and get raw bone transforms (before coordinate conversion)
	var nif_data: PackedByteArray = _bsa.extract_file(nif_path)
	if nif_data.is_empty():
		print("ERROR: Cannot load NIF: %s" % nif_path)
		return

	var reader = NIFReaderScript.new()
	if reader.load_buffer(nif_data) != OK:
		print("ERROR: Failed to parse NIF")
		return

	# Find bone nodes and collect their raw transforms
	print("Raw NIF node transforms (Morrowind space — Z-up, Y-forward):")
	print("%-28s | %-44s | %s" % ["Node Name", "Raw Rotation (quat xyzw)", "Raw Position (MW units)"])
	print("-".repeat(120))

	var bone_nodes: Dictionary = {}  # name_lower -> NiNode
	for record in reader.records:
		if _is_ni_node(record):
			var name_lower: String = record.name.to_lower() if record.name else ""
			if name_lower.begins_with("bip01") or name_lower == "root bone":
				bone_nodes[name_lower] = record
				var raw_t: Transform3D = record.transform.to_transform3d()
				var raw_q: Quaternion = raw_t.basis.get_rotation_quaternion()
				var raw_p: Vector3 = raw_t.origin
				print("%-28s | (%8.4f, %8.4f, %8.4f, %8.4f)         | (%8.2f, %8.2f, %8.2f)" % [
					record.name,
					raw_q.x, raw_q.y, raw_q.z, raw_q.w,
					raw_p.x, raw_p.y, raw_p.z
				])
	print("")

	# Now load KF and get raw keyframe rotations (before conversion)
	var kf_data: PackedByteArray = _bsa.extract_file(kf_path)
	if kf_data.is_empty():
		print("ERROR: Cannot load KF: %s" % kf_path)
		return

	var kf_reader = NIFReaderScript.new()
	if kf_reader.load_buffer(kf_data) != OK:
		print("ERROR: Failed to parse KF")
		return

	# Find NiSequenceStreamHelper and extract bone controllers
	var seq_helper = null
	var rt_seq_helper = Defs.RT_NI_SEQUENCE_STREAM_HELPER
	for root_idx in kf_reader.roots:
		var root = kf_reader.get_record(root_idx)
		if root and root.record_type == rt_seq_helper:
			seq_helper = root
			break

	if not seq_helper:
		print("ERROR: No NiSequenceStreamHelper in KF")
		return

	# Walk extra data chain to get bone names
	var extra_indices: Array[int] = []
	var current: int = seq_helper.extra_data_index
	while current >= 0:
		var extra = kf_reader.get_record(current)
		if extra == null:
			break
		extra_indices.append(current)
		if "next_extra_data_index" in extra:
			current = extra.next_extra_data_index
		else:
			break

	# Walk controller chain
	var ctrl_indices: Array[int] = []
	var current_ctrl: int = seq_helper.controller_index
	while current_ctrl >= 0:
		var ctrl = kf_reader.get_record(current_ctrl)
		if ctrl == null:
			break
		ctrl_indices.append(current_ctrl)
		if "next_controller_index" in ctrl:
			current_ctrl = ctrl.next_controller_index
		else:
			break

	# Pair them — skip first extra (text keys), get string extras and keyframe controllers
	var string_extras: Array = []
	for idx_i in range(1, extra_indices.size()):
		var extra = kf_reader.get_record(extra_indices[idx_i])
		if extra and "string_data" in extra:
			string_extras.append(extra)

	var kf_controllers: Array = []
	for ctrl_idx in ctrl_indices:
		var ctrl = kf_reader.get_record(ctrl_idx)
		if ctrl and "data_index" in ctrl:
			kf_controllers.append(ctrl)

	# Find idle animation time range from text keys
	var idle_start := 0.0
	var idle_end := 0.0
	if extra_indices.size() > 0:
		var first_extra = kf_reader.get_record(extra_indices[0])
		if first_extra and "keys" in first_extra:
			var text_keys: Array = first_extra.keys
			for tk in text_keys:
				var parts: PackedStringArray = String(tk["value"]).split(":")
				if parts.size() >= 2:
					var anim_name := parts[0].strip_edges().to_lower()
					var action := parts[1].strip_edges().to_lower()
					if anim_name == "idle" and action.contains("start"):
						idle_start = tk["time"]
					elif anim_name == "idle" and action.contains("stop"):
						idle_end = tk["time"]

	print("Idle range: %.3f - %.3f sec" % [idle_start, idle_end])
	print("")
	print("Raw KF idle frame 0 rotations (Morrowind space):")
	print("%-28s | %-44s | %-44s | %s" % [
		"Bone Name", "Raw NIF Rest (quat xyzw)", "Raw KF Frame0 (quat xyzw)", "Angle(deg)"
	])
	print("-".repeat(170))

	var pair_count := mini(string_extras.size(), kf_controllers.size())
	for i in range(pair_count):
		var bone_name: String = string_extras[i].string_data
		var controller = kf_controllers[i]

		if controller.data_index < 0:
			continue

		var kf_data_rec = kf_reader.get_record(controller.data_index)
		if kf_data_rec == null or kf_data_rec.rotation_keys.is_empty():
			continue

		# Get first key at or near idle start
		var raw_kf_q := Quaternion.IDENTITY
		var best_time_diff := 999999.0
		for key: Dictionary in kf_data_rec.rotation_keys:
			var time: float = key["time"]
			var diff := absf(time - idle_start)
			if diff < best_time_diff:
				best_time_diff = diff
				raw_kf_q = key["value"] if key.has("value") and key["value"] is Quaternion else Quaternion.IDENTITY

		# Get raw NIF node transform for this bone
		var raw_nif_q := Quaternion.IDENTITY
		var name_lower := bone_name.to_lower()
		if name_lower in bone_nodes:
			var node = bone_nodes[name_lower]
			raw_nif_q = node.transform.to_transform3d().basis.get_rotation_quaternion()

		var angle := _quat_angle_deg(raw_nif_q, raw_kf_q)
		print("%-28s | (%8.4f, %8.4f, %8.4f, %8.4f)         | (%8.4f, %8.4f, %8.4f, %8.4f)         | %7.2f°" % [
			bone_name,
			raw_nif_q.x, raw_nif_q.y, raw_nif_q.z, raw_nif_q.w,
			raw_kf_q.x, raw_kf_q.y, raw_kf_q.z, raw_kf_q.w,
			angle
		])
	print("")


# =============================================================================
# BONE HIERARCHY INTEGRITY CHECK
# =============================================================================

func _check_hierarchy(skeleton: Skeleton3D) -> void:
	# Verify that bone_global_rest[child] = bone_global_rest[parent] * bone_rest[child]
	var errors := 0
	for i in skeleton.get_bone_count():
		var parent_idx := skeleton.get_bone_parent(i)
		var bone_rest := skeleton.get_bone_rest(i)
		var global_rest := skeleton.get_bone_global_rest(i)

		var expected_global: Transform3D
		if parent_idx >= 0:
			expected_global = skeleton.get_bone_global_rest(parent_idx) * bone_rest
		else:
			expected_global = bone_rest

		var pos_diff := (global_rest.origin - expected_global.origin).length()
		var rot_diff := _quat_angle_deg(
			global_rest.basis.get_rotation_quaternion(),
			expected_global.basis.get_rotation_quaternion()
		)

		if pos_diff > 0.001 or rot_diff > 0.1:
			print("  FAIL bone %d '%s': pos_diff=%.6f, rot_diff=%.2f°" % [
				i, skeleton.get_bone_name(i), pos_diff, rot_diff])
			errors += 1

	if errors == 0:
		print("  PASS: All %d bones have consistent global_rest = parent_global * rest" % skeleton.get_bone_count())
	else:
		print("  FAIL: %d bones with inconsistent hierarchy" % errors)
	print("")


# =============================================================================
# HELPERS
# =============================================================================

func _load_skeleton(nif_path: String) -> Skeleton3D:
	var data: PackedByteArray = _bsa.extract_file(nif_path)
	if data.is_empty():
		print("ERROR: Cannot extract: %s" % nif_path)
		return null

	var converter = NIFConverterScript.new()
	converter.load_textures = false
	converter.load_animations = false
	converter.load_collision = false

	var scene = converter.convert_buffer(data, nif_path)
	var skeleton: Skeleton3D = converter.create_skeleton_from_hierarchy()
	if scene:
		scene.free()

	return skeleton


func _load_kf(kf_path: String) -> Dictionary:
	var data: PackedByteArray = _bsa.extract_file(kf_path)
	if data.is_empty():
		print("ERROR: Cannot extract: %s" % kf_path)
		return {}

	var loader = NIFKFLoaderScript.new()
	return loader.load_kf_buffer(data, null)


## Map bone tracks in an animation by bone name (lowercase)
## Returns: { bone_name_lower: { "rot_idx": int, "pos_idx": int, "scale_idx": int } }
func _map_bone_tracks(anim: Animation) -> Dictionary:
	var result: Dictionary = {}

	for t in anim.get_track_count():
		var path := anim.track_get_path(t)
		# Track format is ".:BoneName" — subname count >= 1
		if path.get_subname_count() == 0:
			continue

		var bone_name := String(path.get_subname(0)).to_lower()
		if bone_name not in result:
			result[bone_name] = {}

		var track_type := anim.track_get_type(t)
		match track_type:
			Animation.TYPE_ROTATION_3D:
				result[bone_name]["rot_idx"] = t
			Animation.TYPE_POSITION_3D:
				result[bone_name]["pos_idx"] = t
			Animation.TYPE_SCALE_3D:
				result[bone_name]["scale_idx"] = t

	return result


## Compute angle in degrees between two quaternions
func _quat_angle_deg(a: Quaternion, b: Quaternion) -> float:
	# Ensure shortest path
	var dot := a.dot(b)
	if dot < 0:
		b = -b
		dot = -dot
	dot = clampf(dot, -1.0, 1.0)
	return rad_to_deg(2.0 * acos(dot))


## Check if a NIF record is a node type (has transform and children)
func _is_ni_node(record) -> bool:
	return record != null and "transform" in record and "children_indices" in record


func _header(title: String) -> void:
	print("=" .repeat(80))
	print(title)
	print("=" .repeat(80))
	print("")


func _find_morrowind_bsa() -> String:
	var possible_paths := [
		"C:/Program Files (x86)/Steam/steamapps/common/Morrowind/Data Files/Morrowind.bsa",
		"C:/Program Files/Steam/steamapps/common/Morrowind/Data Files/Morrowind.bsa",
		"D:/Games/Morrowind/Data Files/Morrowind.bsa",
		"D:/SteamLibrary/steamapps/common/Morrowind/Data Files/Morrowind.bsa",
	]

	for path: String in possible_paths:
		if FileAccess.file_exists(path):
			return path

	return ""
