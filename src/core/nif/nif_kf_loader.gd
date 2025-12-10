## NIF KF (Keyframe) File Loader
## Loads animation data from Morrowind .kf files
##
## Morrowind stores animations in separate .kf files:
## - xbase_anim.kf - Main character animations (idle, walk, run, attack, etc.)
## - <creature>.kf - Creature-specific animations
##
## KF file structure:
## - Root: NiSequenceStreamHelper
##   - First extra data: NiTextKeyExtraData (animation markers like "Idle: Start")
##   - Following extra data: NiStringExtraData (bone names)
##   - Controller chain: NiKeyframeController (animation data for each bone)
##   - Extra data and controllers are parallel arrays
class_name NIFKFLoader
extends RefCounted

const NIFReader := preload("res://src/core/nif/nif_reader.gd")
const NIFAnimationConverter := preload("res://src/core/nif/nif_animation_converter.gd")
const Defs := preload("res://src/core/nif/nif_defs.gd")

# Debug output
var debug_mode: bool = false


## Load animations from a .kf file buffer
## Returns Dictionary of animation_name -> Animation
func load_kf_buffer(data: PackedByteArray, skeleton: Skeleton3D = null) -> Dictionary:
	var reader := NIFReader.new()
	reader.debug_mode = debug_mode

	var result := reader.load_buffer(data)
	if result != OK:
		push_error("NIFKFLoader: Failed to parse KF file")
		return {}

	return _extract_animations(reader, skeleton)


## Load animations from a .kf file path
func load_kf_file(path: String, skeleton: Skeleton3D = null) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("NIFKFLoader: Failed to open file: %s" % path)
		return {}

	var data := file.get_buffer(file.get_length())
	file.close()

	return load_kf_buffer(data, skeleton)


## Extract animations from parsed NIF reader
func _extract_animations(reader: NIFReader, skeleton: Skeleton3D) -> Dictionary:
	# Find NiSequenceStreamHelper root
	var seq_helper: Defs.NiObjectNET = null
	for root_idx in reader.roots:
		var root: Defs.NIFRecord = reader.get_record(root_idx)
		if root and root.record_type == Defs.RT_NI_SEQUENCE_STREAM_HELPER:
			seq_helper = root as Defs.NiObjectNET
			break

	if seq_helper == null:
		push_warning("NIFKFLoader: No NiSequenceStreamHelper found - this may not be a .kf file")
		# Fall back to regular animation extraction
		return _extract_regular_animations(reader, skeleton)

	if debug_mode:
		print("NIFKFLoader: Found NiSequenceStreamHelper")

	# Get text keys (animation markers)
	var text_keys: Array[Dictionary] = []
	var extra_data_idx := seq_helper.extra_data_index

	if extra_data_idx >= 0:
		var first_extra: Defs.NIFRecord = reader.get_record(extra_data_idx)
		if first_extra is Defs.NiTextKeyExtraData:
			var text_key_data := first_extra as Defs.NiTextKeyExtraData
			text_keys = text_key_data.keys
			if debug_mode:
				print("  Text keys: %d" % text_keys.size())
				for tk in text_keys:
					print("    %.3fs: %s" % [tk["time"], tk["value"]])

	# Collect bone name -> controller pairs
	var bone_controllers: Dictionary = {}  # bone_name -> NiKeyframeController

	# Walk through extra data chain (skipping first which is text keys)
	var extra_indices: Array[int] = []
	var current_extra_idx := extra_data_idx
	while current_extra_idx >= 0:
		var extra: Defs.NIFRecord = reader.get_record(current_extra_idx)
		if extra == null:
			break
		extra_indices.append(current_extra_idx)

		# Get next in chain
		if extra is Defs.NiTextKeyExtraData:
			current_extra_idx = (extra as Defs.NiTextKeyExtraData).next_extra_data_index
		elif extra is Defs.NiStringExtraData:
			current_extra_idx = (extra as Defs.NiStringExtraData).next_extra_data_index
		elif extra is Defs.NiExtraData:
			current_extra_idx = (extra as Defs.NiExtraData).next_extra_data_index
		else:
			break

	# Walk through controller chain
	var controller_indices: Array[int] = []
	var current_ctrl_idx := seq_helper.controller_index
	while current_ctrl_idx >= 0:
		var ctrl: Defs.NIFRecord = reader.get_record(current_ctrl_idx)
		if ctrl == null:
			break
		controller_indices.append(current_ctrl_idx)

		if ctrl is Defs.NiTimeController:
			current_ctrl_idx = (ctrl as Defs.NiTimeController).next_controller_index
		else:
			break

	if debug_mode:
		print("  Extra data chain: %d items" % extra_indices.size())
		print("  Controller chain: %d items" % controller_indices.size())

	# Match string extra data (bone names) with controllers
	# First extra is text keys, so start from index 1
	var string_extras: Array = []
	for i in range(1, extra_indices.size()):
		var extra: Defs.NIFRecord = reader.get_record(extra_indices[i])
		if extra is Defs.NiStringExtraData:
			string_extras.append(extra as Defs.NiStringExtraData)

	var keyframe_controllers: Array = []
	for ctrl_idx in controller_indices:
		var ctrl: Defs.NIFRecord = reader.get_record(ctrl_idx)
		if ctrl is Defs.NiKeyframeController:
			keyframe_controllers.append(ctrl as Defs.NiKeyframeController)

	if debug_mode:
		print("  String extras (bone names): %d" % string_extras.size())
		print("  Keyframe controllers: %d" % keyframe_controllers.size())

	# Pair them up
	var pair_count := mini(string_extras.size(), keyframe_controllers.size())
	for i in range(pair_count):
		var bone_name: String = string_extras[i].string_data
		var controller: Defs.NiKeyframeController = keyframe_controllers[i]
		bone_controllers[bone_name] = controller

		if debug_mode:
			print("    Bone '%s' -> controller with data_index=%d" % [bone_name, controller.data_index])

	# Now create animations from text key ranges
	return _create_animations_from_kf(reader, text_keys, bone_controllers, skeleton)


## Create Animation resources from KF file data
func _create_animations_from_kf(
	reader: NIFReader,
	text_keys: Array[Dictionary],
	bone_controllers: Dictionary,
	skeleton: Skeleton3D
) -> Dictionary:
	var animations: Dictionary = {}

	# Build bone name to skeleton index mapping
	var bone_name_to_idx: Dictionary = {}
	if skeleton:
		for i in range(skeleton.get_bone_count()):
			var name := skeleton.get_bone_name(i).to_lower()
			bone_name_to_idx[name] = i

	# Parse text keys to find animation boundaries
	# Format: "AnimName: Start", "AnimName: Loop Start", "AnimName: Stop", etc.
	var anim_ranges: Array[Dictionary] = []  # [{name, start_time, end_time}]
	var current_anim := ""
	var current_start := 0.0

	for i in range(text_keys.size()):
		var key: Dictionary = text_keys[i]
		var key_name: String = key["value"]
		var key_time: float = key["time"]

		var parts := key_name.split(":")
		if parts.size() >= 2:
			var anim_name := parts[0].strip_edges()
			var action := parts[1].strip_edges().to_lower()

			if action.contains("start"):
				current_anim = anim_name
				current_start = key_time
			elif action.contains("stop") and current_anim == anim_name:
				anim_ranges.append({
					"name": anim_name,
					"start_time": current_start,
					"end_time": key_time
				})
				current_anim = ""

	if debug_mode:
		print("  Animation ranges found: %d" % anim_ranges.size())
		for r in anim_ranges:
			print("    '%s': %.3f - %.3f" % [r["name"], r["start_time"], r["end_time"]])

	# Create an animation for each range
	for anim_range in anim_ranges:
		var anim := _create_single_animation(
			reader,
			anim_range["name"],
			anim_range["start_time"],
			anim_range["end_time"],
			bone_controllers,
			bone_name_to_idx,
			skeleton
		)
		if anim and anim.get_track_count() > 0:
			animations[anim_range["name"]] = anim

	# If no animations were created from ranges, create one "default" animation
	if animations.is_empty() and not bone_controllers.is_empty():
		var max_time := 0.0
		for bone_name: String in bone_controllers:
			var ctrl: Defs.NiKeyframeController = bone_controllers[bone_name]
			max_time = maxf(max_time, ctrl.stop_time)

		if max_time > 0:
			var anim := _create_single_animation(
				reader, "default", 0.0, max_time,
				bone_controllers, bone_name_to_idx, skeleton
			)
			if anim:
				animations["default"] = anim

	return animations


## Create a single Animation for a time range
func _create_single_animation(
	reader: NIFReader,
	anim_name: String,
	start_time: float,
	end_time: float,
	bone_controllers: Dictionary,
	bone_name_to_idx: Dictionary,
	skeleton: Skeleton3D
) -> Animation:
	var animation := Animation.new()
	animation.resource_name = anim_name
	animation.length = end_time - start_time

	for bone_name: String in bone_controllers:
		var controller: Defs.NiKeyframeController = bone_controllers[bone_name]

		if controller.data_index < 0:
			continue

		var data: Defs.NiKeyframeData = reader.get_record(controller.data_index) as Defs.NiKeyframeData
		if data == null:
			continue

		# Determine track path
		var track_path: String
		var bone_idx: int = bone_name_to_idx.get(bone_name.to_lower(), -1)

		if bone_idx >= 0 and skeleton:
			track_path = "%s:%s" % [skeleton.name, bone_name]
		else:
			track_path = bone_name

		# Add rotation track
		if not data.rotation_keys.is_empty():
			var trimmed := _trim_keys(data.rotation_keys, start_time, end_time)
			if not trimmed.is_empty():
				var track_idx := animation.add_track(Animation.TYPE_ROTATION_3D)
				animation.track_set_path(track_idx, track_path)
				animation.track_set_interpolation_type(track_idx, Animation.INTERPOLATION_LINEAR)

				for key in trimmed:
					var time: float = key["time"] - start_time
					var quat := _convert_rotation(key)
					animation.rotation_track_insert_key(track_idx, time, quat)

		# Add position track
		if not data.translation_keys.is_empty():
			var trimmed := _trim_keys(data.translation_keys, start_time, end_time)
			if not trimmed.is_empty():
				var track_idx := animation.add_track(Animation.TYPE_POSITION_3D)
				animation.track_set_path(track_idx, track_path)
				animation.track_set_interpolation_type(track_idx, Animation.INTERPOLATION_LINEAR)

				for key in trimmed:
					var time: float = key["time"] - start_time
					var pos := _convert_position(key["value"])
					animation.position_track_insert_key(track_idx, time, pos)

		# Add scale track
		if not data.scale_keys.is_empty():
			var trimmed := _trim_keys(data.scale_keys, start_time, end_time)
			if not trimmed.is_empty():
				var track_idx := animation.add_track(Animation.TYPE_SCALE_3D)
				animation.track_set_path(track_idx, track_path)
				animation.track_set_interpolation_type(track_idx, Animation.INTERPOLATION_LINEAR)

				for key in trimmed:
					var time: float = key["time"] - start_time
					var scale_val: float = key["value"]
					animation.scale_track_insert_key(track_idx, time, Vector3(scale_val, scale_val, scale_val))

	if debug_mode:
		print("    Created animation '%s': %.2fs, %d tracks" % [
			anim_name, animation.length, animation.get_track_count()
		])

	return animation


## Fall back to regular animation extraction (for non-KF files)
func _extract_regular_animations(reader: NIFReader, skeleton: Skeleton3D) -> Dictionary:
	var converter := NIFAnimationConverter.new()
	converter.init(reader, skeleton)
	converter.debug_mode = debug_mode
	return converter.convert_to_animations_by_text_keys()


## Trim keyframes to a time range
func _trim_keys(keys: Array, start_time: float, end_time: float) -> Array:
	var result: Array = []
	for key in keys:
		var time: float = key["time"]
		if time >= start_time and time <= end_time:
			result.append(key)

	# Include boundary keys if we have none in range
	if result.is_empty() and not keys.is_empty():
		var before: Dictionary = {}
		var after: Dictionary = {}
		for key in keys:
			var time: float = key["time"]
			if time < start_time:
				before = key
			elif time > end_time and after.is_empty():
				after = key
				break
		if not before.is_empty():
			result.append(before)
		if not after.is_empty():
			result.append(after)

	return result


## Convert rotation key to Godot quaternion with coordinate system conversion
func _convert_rotation(key: Dictionary) -> Quaternion:
	var quat: Quaternion
	if key.has("value") and key["value"] is Quaternion:
		quat = key["value"]
	elif key.has("quat"):
		quat = key["quat"]
	else:
		quat = Quaternion.IDENTITY

	# Convert from Morrowind (Z-up) to Godot (Y-up)
	return Quaternion(quat.x, quat.z, -quat.y, quat.w)


## Convert position with coordinate system conversion
func _convert_position(pos: Vector3) -> Vector3:
	# Morrowind: X-right, Y-forward, Z-up
	# Godot: X-right, Y-up, Z-back
	return Vector3(pos.x, pos.z, -pos.y)
