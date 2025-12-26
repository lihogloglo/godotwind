## NIF Animation Converter - Converts NIF keyframe data to Godot Animation resources
## Handles NiKeyframeController/NiKeyframeData conversion
class_name NIFAnimationConverter
extends RefCounted

const Defs := preload("res://src/core/nif/nif_defs.gd")
const CS := preload("res://src/core/coordinate_system.gd")

# Reference to the NIF reader for accessing records
var _reader: RefCounted = null

# The skeleton this animation targets
var _skeleton: Skeleton3D = null

# Bone name to skeleton bone index mapping
var _bone_name_to_idx: Dictionary = {}

# Debug output
var debug_mode: bool = false


## Initialize with a NIF reader and skeleton
func init(reader: RefCounted, skeleton: Skeleton3D) -> void:
	_reader = reader
	_skeleton = skeleton
	_bone_name_to_idx.clear()

	# Build bone name mapping from skeleton
	if _skeleton:
		for i in range(_skeleton.get_bone_count()):
			var name := _skeleton.get_bone_name(i).to_lower()
			_bone_name_to_idx[name] = i


## Convert all NiKeyframeControllers in the NIF to a single Animation
## Returns the Animation resource or null if no animations found
func convert_to_animation(animation_name: String = "default") -> Animation:
	if _reader == null:
		push_error("NIFAnimationConverter: Reader not initialized")
		return null

	var animation := Animation.new()
	animation.resource_name = animation_name

	var found_any := false
	var max_time := 0.0

	# Find all keyframe controllers
	for record: Defs.NIFRecord in _reader.get("records"):
		if record is Defs.NiKeyframeController:
			var controller := record as Defs.NiKeyframeController
			var added := _add_controller_tracks(animation, controller)
			if added:
				found_any = true
				max_time = maxf(max_time, controller.stop_time)

	if not found_any:
		return null

	# Set animation length
	animation.length = max_time if max_time > 0.0 else 1.0

	if debug_mode:
		print("NIFAnimationConverter: Created animation '%s' with %d tracks, length=%.2fs" % [
			animation_name, animation.get_track_count(), animation.length
		])

	return animation


## Add tracks from a NiKeyframeController to the animation
func _add_controller_tracks(animation: Animation, controller: Defs.NiKeyframeController) -> bool:
	# Get the target node name
	var target_idx := controller.target_index
	if target_idx < 0:
		return false

	var target: Defs.NIFRecord = _reader.call("get_record", target_idx)
	if target == null or not (target is Defs.NiObjectNET):
		return false

	var target_name := (target as Defs.NiObjectNET).name
	if target_name.is_empty():
		target_name = "Node_%d" % target_idx

	# Get keyframe data
	if controller.data_index < 0:
		return false

	var data := _reader.call("get_record", controller.data_index) as Defs.NiKeyframeData
	if data == null:
		return false

	if debug_mode:
		print("  Processing keyframes for '%s': rot=%d, trans=%d, scale=%d" % [
			target_name,
			data.rotation_keys.size(),
			data.translation_keys.size(),
			data.scale_keys.size()
		])

	# Determine track path
	# If we have a skeleton and this is a bone, use skeleton path
	var track_path: String
	var bone_idx: int = _bone_name_to_idx.get(target_name.to_lower(), -1)

	if bone_idx >= 0 and _skeleton:
		# This is a bone - use Skeleton3D bone track format
		track_path = "%s:%s" % [_skeleton.name, target_name]
	else:
		# Regular node path
		track_path = target_name

	var added_any := false

	# Add rotation track
	# Handle both quaternion keys and XYZ Euler rotation keys
	if data.rotation_type == Defs.InterpolationType.XYZ:
		# XYZ Euler rotation - need to convert separate axis keys to quaternions
		if not data.x_rotation_keys.is_empty() or not data.y_rotation_keys.is_empty() or not data.z_rotation_keys.is_empty():
			var track_idx := animation.add_track(Animation.TYPE_ROTATION_3D)
			animation.track_set_path(track_idx, track_path)
			animation.track_set_interpolation_type(track_idx, Animation.INTERPOLATION_LINEAR)

			# Collect all unique time values from all three axes
			var times := _collect_xyz_key_times(data)
			for time: float in times:
				var time_val: float = time
				var quat := _sample_xyz_rotation_at_time(data, time_val)
				animation.rotation_track_insert_key(track_idx, time_val, quat)

			added_any = true

			if debug_mode:
				print("    XYZ rotation: %d x-keys, %d y-keys, %d z-keys -> %d samples" % [
					data.x_rotation_keys.size(),
					data.y_rotation_keys.size(),
					data.z_rotation_keys.size(),
					times.size()
				])
	elif not data.rotation_keys.is_empty():
		# Quaternion rotation keys
		var track_idx := animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(track_idx, track_path)
		animation.track_set_interpolation_type(track_idx, _get_interpolation_type(data.rotation_type))

		for key: Dictionary in data.rotation_keys:
			var time_val: float = key["time"]
			var quat: Quaternion = _convert_rotation(key)
			animation.rotation_track_insert_key(track_idx, time_val, quat)

		added_any = true

	# Add position track
	if not data.translation_keys.is_empty():
		var track_idx := animation.add_track(Animation.TYPE_POSITION_3D)
		animation.track_set_path(track_idx, track_path)
		animation.track_set_interpolation_type(track_idx, _get_interpolation_type(data.translation_type))

		for key: Dictionary in data.translation_keys:
			var time_val: float = key["time"]
			var value_vec: Vector3 = key["value"]
			var pos: Vector3 = _convert_position(value_vec)
			animation.position_track_insert_key(track_idx, time_val, pos)

		added_any = true

	# Add scale track
	if not data.scale_keys.is_empty():
		var track_idx := animation.add_track(Animation.TYPE_SCALE_3D)
		animation.track_set_path(track_idx, track_path)
		animation.track_set_interpolation_type(track_idx, _get_interpolation_type(data.scale_type))

		for key: Dictionary in data.scale_keys:
			var time_val: float = key["time"]
			var scale_val: float = key["value"]
			# NIF uses uniform scale, Godot uses Vector3
			animation.scale_track_insert_key(track_idx, time_val, Vector3(scale_val, scale_val, scale_val))

		added_any = true

	return added_any


## Convert NIF rotation key to Godot Quaternion
func _convert_rotation(key: Dictionary) -> Quaternion:
	var quat: Quaternion

	# The reader stores quaternions in the "value" field (for value_size=4)
	if key.has("value") and key["value"] is Quaternion:
		quat = key["value"] as Quaternion
	elif key.has("quat"):
		# Legacy format / fallback
		quat = key["quat"] as Quaternion
	else:
		quat = Quaternion.IDENTITY

	# Convert from Morrowind coordinate system (Z-up) to Godot (Y-up)
	return _convert_quaternion_coords(quat)


## Convert XYZ Euler rotation keys to quaternion at a specific time
## x_angle, y_angle, z_angle are in radians in NIF/Morrowind coordinate space
func _convert_xyz_rotation(x_angle: float, y_angle: float, z_angle: float) -> Quaternion:
	# NIF XYZ rotation uses Euler angles in X, Y, Z order (Morrowind coordinate system)
	# Morrowind: X-right, Y-forward, Z-up
	#
	# First build the rotation in Morrowind space using the standard Euler convention
	# NIF typically uses XYZ extrinsic order which is ZYX intrinsic

	# Build rotation matrix in Morrowind space
	var basis_x := Basis(Vector3.RIGHT, x_angle)
	var basis_y := Basis(Vector3(0, 1, 0), y_angle)  # Y-axis (forward in MW)
	var basis_z := Basis(Vector3(0, 0, 1), z_angle)  # Z-axis (up in MW)

	# Combine rotations: for extrinsic XYZ, multiply in reverse order
	var combined := basis_z * basis_y * basis_x

	# Convert the rotation matrix to Godot coordinates
	# Using the same C * R * C^T transformation as for transforms
	var converted_basis := Basis(
		Vector3(combined.x.x, combined.x.z, -combined.x.y),
		Vector3(combined.z.x, combined.z.z, -combined.z.y),
		Vector3(-combined.y.x, -combined.y.z, combined.y.y)
	)

	return converted_basis.get_rotation_quaternion()


## Sample XYZ rotation keys at a specific time by interpolating
func _sample_xyz_rotation_at_time(data: Defs.NiKeyframeData, time: float) -> Quaternion:
	var x_angle := _sample_float_key_at_time(data.x_rotation_keys, time)
	var y_angle := _sample_float_key_at_time(data.y_rotation_keys, time)
	var z_angle := _sample_float_key_at_time(data.z_rotation_keys, time)

	return _convert_xyz_rotation(x_angle, y_angle, z_angle)


## Sample a float value from key array at a specific time (linear interpolation)
func _sample_float_key_at_time(keys: Array, time: float) -> float:
	if keys.is_empty():
		return 0.0

	# Find surrounding keys
	var prev_key: Dictionary = keys[0]
	var next_key: Dictionary = keys[0]

	for key: Dictionary in keys:
		var key_time: float = key["time"]
		if key_time <= time:
			prev_key = key
		if key_time >= time and next_key["time"] <= prev_key["time"]:
			next_key = key
			break

	# If time is before first key or after last key, return boundary value
	if time <= prev_key["time"]:
		return prev_key["value"]
	if time >= next_key["time"]:
		return next_key["value"]

	# Linear interpolation between keys
	var prev_time: float = prev_key["time"]
	var next_time: float = next_key["time"]
	var prev_value: float = prev_key["value"]
	var next_value: float = next_key["value"]
	var t: float = (time - prev_time) / (next_time - prev_time)
	return lerpf(prev_value, next_value, t)


## Collect all unique time values from XYZ rotation keys
func _collect_xyz_key_times(data: Defs.NiKeyframeData) -> Array:
	var times_set := {}

	for key: Dictionary in data.x_rotation_keys:
		times_set[key["time"]] = true
	for key: Dictionary in data.y_rotation_keys:
		times_set[key["time"]] = true
	for key: Dictionary in data.z_rotation_keys:
		times_set[key["time"]] = true

	var times: Array = times_set.keys()
	times.sort()
	return times


## Convert quaternion from Morrowind to Godot coordinate system
## Delegates to unified CoordinateSystem
func _convert_quaternion_coords(quat: Quaternion) -> Quaternion:
	return CS.quaternion_to_godot(quat)


## Convert position from Morrowind to Godot coordinate system
## Delegates to unified CoordinateSystem - outputs in meters
func _convert_position(pos: Vector3) -> Vector3:
	return CS.vector_to_godot(pos)  # Converts to meters


## Get Godot interpolation type from NIF interpolation type
func _get_interpolation_type(nif_type: int) -> int:
	match nif_type:
		Defs.InterpolationType.LINEAR:
			return Animation.INTERPOLATION_LINEAR
		Defs.InterpolationType.QUADRATIC:
			return Animation.INTERPOLATION_CUBIC
		Defs.InterpolationType.TCB:
			# TCB (Tension/Continuity/Bias) - use cubic as approximation
			return Animation.INTERPOLATION_CUBIC
		Defs.InterpolationType.CONSTANT:
			return Animation.INTERPOLATION_NEAREST
		_:
			return Animation.INTERPOLATION_LINEAR


## Extract text keys from NiTextKeyExtraData as animation markers
## Returns array of {time: float, name: String}
func get_text_keys() -> Array:
	var keys: Array = []

	for record: Defs.NIFRecord in _reader.get("records"):
		if record is Defs.NiTextKeyExtraData:
			var text_key := record as Defs.NiTextKeyExtraData
			for key in text_key.keys:
				keys.append({
					"time": key["time"],
					"name": key["value"]
				})

	# Sort by time
	keys.sort_custom(func(a: Variant, b: Variant) -> bool: return a["time"] < b["time"])

	return keys


## Create multiple animations split by text key markers
## Common patterns: "Idle: Start" / "Idle: Stop", "Walk: Loop Start" / "Walk: Loop Stop"
func convert_to_animations_by_text_keys() -> Dictionary:
	var text_keys := get_text_keys()
	if text_keys.is_empty():
		# No text keys - return single animation
		var anim := convert_to_animation("default")
		if anim:
			return {"default": anim}
		return {}

	# Parse text keys to find animation boundaries
	var animations: Dictionary = {}
	var current_anim_name := ""
	var current_start_time := 0.0

	for i in range(text_keys.size()):
		var key: Dictionary = text_keys[i]
		var key_name: String = key["name"]
		var key_time: float = key["time"]

		# Parse key format: "AnimName: Start" or "AnimName: Loop Start" etc.
		var parts := key_name.split(":")
		if parts.size() >= 2:
			var anim_name := parts[0].strip_edges()
			var action := parts[1].strip_edges().to_lower()

			if action.contains("start"):
				current_anim_name = anim_name
				current_start_time = key_time
			elif action.contains("stop") and current_anim_name == anim_name:
				# Create animation for this range
				var anim := _create_animation_for_range(anim_name, current_start_time, key_time)
				if anim:
					animations[anim_name] = anim
				current_anim_name = ""

	# If we have no parsed animations, just return the full animation
	if animations.is_empty():
		var anim := convert_to_animation("default")
		if anim:
			return {"default": anim}

	return animations


## Create animation for a specific time range
## Extracts only keyframes within the range and offsets them to start at 0
func _create_animation_for_range(name: String, start_time: float, end_time: float) -> Animation:
	if _reader == null:
		return null

	var animation := Animation.new()
	animation.resource_name = name
	animation.length = end_time - start_time

	var found_any := false

	# Find all keyframe controllers and extract keys within range
	for record: Defs.NIFRecord in _reader.get("records"):
		if record is Defs.NiKeyframeController:
			var controller := record as Defs.NiKeyframeController
			var added := _add_controller_tracks_for_range(animation, controller, start_time, end_time)
			if added:
				found_any = true

	if not found_any:
		return null

	if debug_mode:
		print("NIFAnimationConverter: Created range animation '%s' [%.2f-%.2f] with %d tracks" % [
			name, start_time, end_time, animation.get_track_count()
		])

	return animation


## Add tracks from a controller, but only keys within the specified time range
func _add_controller_tracks_for_range(animation: Animation, controller: Defs.NiKeyframeController, start_time: float, end_time: float) -> bool:
	# Get the target node name
	var target_idx := controller.target_index
	if target_idx < 0:
		return false

	var target: Defs.NIFRecord = _reader.call("get_record", target_idx)
	if target == null or not (target is Defs.NiObjectNET):
		return false

	var target_name := (target as Defs.NiObjectNET).name
	if target_name.is_empty():
		target_name = "Node_%d" % target_idx

	# Get keyframe data
	if controller.data_index < 0:
		return false

	var data := _reader.call("get_record", controller.data_index) as Defs.NiKeyframeData
	if data == null:
		return false

	# Determine track path
	var track_path: String
	var bone_idx: int = _bone_name_to_idx.get(target_name.to_lower(), -1)

	if bone_idx >= 0 and _skeleton:
		track_path = "%s:%s" % [_skeleton.name, target_name]
	else:
		track_path = target_name

	var added_any := false

	# Add rotation track with trimmed keys
	if not data.rotation_keys.is_empty():
		var trimmed_keys := _trim_keys_to_range(data.rotation_keys, start_time, end_time)
		if not trimmed_keys.is_empty():
			var track_idx := animation.add_track(Animation.TYPE_ROTATION_3D)
			animation.track_set_path(track_idx, track_path)
			animation.track_set_interpolation_type(track_idx, _get_interpolation_type(data.rotation_type))

			for key: Dictionary in trimmed_keys:
				var key_time: float = key["time"]
				var time_val: float = key_time - start_time  # Offset to start at 0
				var quat: Quaternion = _convert_rotation(key)
				animation.rotation_track_insert_key(track_idx, time_val, quat)

			added_any = true

	# Add position track with trimmed keys
	if not data.translation_keys.is_empty():
		var trimmed_keys := _trim_keys_to_range(data.translation_keys, start_time, end_time)
		if not trimmed_keys.is_empty():
			var track_idx := animation.add_track(Animation.TYPE_POSITION_3D)
			animation.track_set_path(track_idx, track_path)
			animation.track_set_interpolation_type(track_idx, _get_interpolation_type(data.translation_type))

			for key: Dictionary in trimmed_keys:
				var key_time: float = key["time"]
				var time_val: float = key_time - start_time
				var value_vec: Vector3 = key["value"]
				var pos: Vector3 = _convert_position(value_vec)
				animation.position_track_insert_key(track_idx, time_val, pos)

			added_any = true

	# Add scale track with trimmed keys
	if not data.scale_keys.is_empty():
		var trimmed_keys := _trim_keys_to_range(data.scale_keys, start_time, end_time)
		if not trimmed_keys.is_empty():
			var track_idx := animation.add_track(Animation.TYPE_SCALE_3D)
			animation.track_set_path(track_idx, track_path)
			animation.track_set_interpolation_type(track_idx, _get_interpolation_type(data.scale_type))

			for key: Dictionary in trimmed_keys:
				var key_time: float = key["time"]
				var time_val: float = key_time - start_time
				var scale_val: float = key["value"]
				animation.scale_track_insert_key(track_idx, time_val, Vector3(scale_val, scale_val, scale_val))

			added_any = true

	return added_any


## Trim keyframes to only include those within the time range
## Also adds interpolated boundary keys at start_time and end_time if needed
func _trim_keys_to_range(keys: Array, start_time: float, end_time: float) -> Array:
	if keys.is_empty():
		return []

	var result: Array = []

	# Find keys within range, plus boundary keys for interpolation
	var last_before_start: Dictionary = {}
	var first_after_end: Dictionary = {}

	for key: Dictionary in keys:
		var time: float = key["time"]

		if time < start_time:
			last_before_start = key
		elif time <= end_time:
			result.append(key)
		elif first_after_end.is_empty():
			first_after_end = key

	# If no keys in range but we have boundary keys, we might need to interpolate
	# For simplicity, if we have keys just outside the range, include them
	# (the animation system will interpolate correctly)
	if result.is_empty():
		if not last_before_start.is_empty():
			result.append(last_before_start)
		if not first_after_end.is_empty():
			result.append(first_after_end)

	return result
