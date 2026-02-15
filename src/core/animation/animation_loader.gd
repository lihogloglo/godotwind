## AnimationLoader — Unified animation loading from multiple formats
##
## Loads animations from FBX, GLB, GLTF, and KF files, normalizing all output
## to ".:BoneName" track format ready for use with the animation pipeline.
##
## NO RETARGETING - animations are loaded as-is for their native skeleton type.
## MW characters use KF animations with MW skeleton.
## Mixamo characters use FBX animations with Mixamo skeleton.
##
## Track path convention:
##   ".:BoneName" — bone tracks target the Skeleton3D at root_node
##   This is consistent with KF loader and AnimationTree root_node setup.
##
## Usage:
##   var lib := AnimationLoader.load_from_fbx("res://assets/animations/mixamo/idle.fbx")
##   anim_player.add_animation_library("mixamo", lib)
class_name AnimationLoader
extends RefCounted


## Standard animation names, checked in order (specific before generic)
const _NAME_PATTERNS := {
	"jump_up": ["jumping up", "jump up", "jumpup"],
	"jump_down": ["jumping down", "jump down", "jumpdown"],
	"idle": ["idle", "standing idle", "breathing idle"],
	"walk": ["walking", "walk"],
	"run": ["running", "run", "jogging", "jog"],
	"jump": ["jump", "jumping"],
	"fall": ["falling", "fall", "falling idle"],
	"land": ["landing", "land"],
}

## Check order — specific patterns before generic to avoid "jump" matching "jump_up"
const _CHECK_ORDER: Array[String] = [
	"jump_up", "jump_down",
	"idle", "walk", "run", "jump", "fall", "land",
]

## Hardcoded Mixamo bone name map (mixamo_bone -> profile_name)
## Used when loading Mixamo FBX files to normalize bone names
const _MIXAMO_BONE_MAP := {
	# Spine
	"mixamorig1_Hips": "Hips",
	"mixamorig_Hips": "Hips",
	"mixamorig1_Spine": "Spine",
	"mixamorig_Spine": "Spine",
	"mixamorig1_Spine1": "UpperChest",
	"mixamorig_Spine1": "UpperChest",
	"mixamorig1_Spine2": "Chest",
	"mixamorig_Spine2": "Chest",
	"mixamorig1_Neck": "Neck",
	"mixamorig_Neck": "Neck",
	"mixamorig1_Head": "Head",
	"mixamorig_Head": "Head",
	# Left arm
	"mixamorig1_LeftShoulder": "LeftShoulder",
	"mixamorig_LeftShoulder": "LeftShoulder",
	"mixamorig1_LeftArm": "LeftUpperArm",
	"mixamorig_LeftArm": "LeftUpperArm",
	"mixamorig1_LeftForeArm": "LeftLowerArm",
	"mixamorig_LeftForeArm": "LeftLowerArm",
	"mixamorig1_LeftHand": "LeftHand",
	"mixamorig_LeftHand": "LeftHand",
	# Right arm
	"mixamorig1_RightShoulder": "RightShoulder",
	"mixamorig_RightShoulder": "RightShoulder",
	"mixamorig1_RightArm": "RightUpperArm",
	"mixamorig_RightArm": "RightUpperArm",
	"mixamorig1_RightForeArm": "RightLowerArm",
	"mixamorig_RightForeArm": "RightLowerArm",
	"mixamorig1_RightHand": "RightHand",
	"mixamorig_RightHand": "RightHand",
	# Left leg
	"mixamorig1_LeftUpLeg": "LeftUpperLeg",
	"mixamorig_LeftUpLeg": "LeftUpperLeg",
	"mixamorig1_LeftLeg": "LeftLowerLeg",
	"mixamorig_LeftLeg": "LeftLowerLeg",
	"mixamorig1_LeftFoot": "LeftFoot",
	"mixamorig_LeftFoot": "LeftFoot",
	"mixamorig1_LeftToeBase": "LeftToes",
	"mixamorig_LeftToeBase": "LeftToes",
	# Right leg
	"mixamorig1_RightUpLeg": "RightUpperLeg",
	"mixamorig_RightUpLeg": "RightUpperLeg",
	"mixamorig1_RightLeg": "RightLowerLeg",
	"mixamorig_RightLeg": "RightLowerLeg",
	"mixamorig1_RightFoot": "RightFoot",
	"mixamorig_RightFoot": "RightFoot",
	"mixamorig1_RightToeBase": "RightToes",
	"mixamorig_RightToeBase": "RightToes",
}


# =============================================================================
# PUBLIC API
# =============================================================================

## Load animations from a single FBX file.
## Returns an AnimationLibrary with normalized bone track names.
## bone_remap: optional { native_name -> target_name } dictionary.
##   If empty, auto-detects Mixamo format and applies _MIXAMO_BONE_MAP.
## preserve_bone_names: if true, skips bone name remapping (identity remap).
##   Use for native Mixamo characters where skeleton keeps original bone names.
static func load_from_fbx(path: String, bone_remap: Dictionary = {}, preserve_bone_names: bool = false) -> AnimationLibrary:
	var scene: PackedScene = load(path) as PackedScene
	if not scene:
		push_warning("AnimationLoader: Cannot load FBX: %s" % path)
		return null

	var root := scene.instantiate()
	if not root:
		push_warning("AnimationLoader: Cannot instantiate: %s" % path)
		return null

	var lib := _extract_and_remap(root, path, bone_remap, preserve_bone_names)
	root.queue_free()
	return lib


## Load animations from a GLB/GLTF file.
static func load_from_glb(path: String, bone_remap: Dictionary = {}, preserve_bone_names: bool = false) -> AnimationLibrary:
	return load_from_fbx(path, bone_remap, preserve_bone_names)  # Godot imports both as PackedScene


## Load all animation files from a directory.
## Returns a single AnimationLibrary with all animations merged.
static func load_from_directory(dir_path: String, bone_remap: Dictionary = {}, preserve_bone_names: bool = false) -> AnimationLibrary:
	var dir := DirAccess.open(dir_path)
	if not dir:
		push_warning("AnimationLoader: Cannot open directory: %s" % dir_path)
		return null

	var merged := AnimationLibrary.new()
	var count := 0

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir():
			var lower := file_name.to_lower()
			if lower.ends_with(".fbx") or lower.ends_with(".glb") or lower.ends_with(".gltf"):
				var full_path := dir_path.path_join(file_name)
				var lib := load_from_fbx(full_path, bone_remap, preserve_bone_names)
				if lib:
					for anim_name: String in lib.get_animation_list():
						if not merged.has_animation(anim_name):
							merged.add_animation(anim_name, lib.get_animation(anim_name))
							count += 1
		file_name = dir.get_next()
	dir.list_dir_end()

	Log.info("animation", "AnimationLoader: Loaded %d animations from %s" % [count, dir_path])
	return merged if count > 0 else null


## Extract rest poses from a Skeleton3D, keyed by bone name.
## Returns { bone_name: String -> Transform3D }
static func get_skeleton_rest_poses(skeleton: Skeleton3D) -> Dictionary:
	var rest := {}
	for i in skeleton.get_bone_count():
		rest[skeleton.get_bone_name(i)] = skeleton.get_bone_rest(i)
	return rest


# =============================================================================
# INTERNAL
# =============================================================================

## Extract animations from an instantiated scene and remap to normalized bone names
static func _extract_and_remap(root: Node, source_path: String, bone_remap: Dictionary, preserve_names: bool = false) -> AnimationLibrary:
	var anim_player := _find_animation_player(root)
	if not anim_player:
		push_warning("AnimationLoader: No AnimationPlayer in: %s" % source_path)
		return null

	# Auto-detect Mixamo format and apply bone remap
	if bone_remap.is_empty():
		var skeleton := _find_skeleton(root)
		if skeleton:
			bone_remap = _build_remap_from_skeleton(skeleton, preserve_names)

	var lib := AnimationLibrary.new()
	var anim_list := anim_player.get_animation_list()
	Log.info("animation", "AnimationLoader: Extracting %d animations from '%s' (remap: %d entries)" % [
		anim_list.size(), source_path.get_file(), bone_remap.size()])

	for anim_name: String in anim_list:
		# Skip special animations
		if anim_name == "RESET":
			continue
		# Skip Mixamo T-pose exports (static single-keyframe animations)
		if anim_name.begins_with("Take ") or anim_name.begins_with("T-Pose"):
			Log.debug("animation", "  Skipping T-pose animation: %s" % anim_name)
			continue

		var source_anim := anim_player.get_animation(anim_name)
		if not source_anim:
			continue

		# Normalize name from file/anim name
		var normalized := _normalize_name(anim_name, source_path)

		# Fix track paths to ".:bone_name" and remap to normalized names
		var fixed := _fix_and_remap_tracks(source_anim, bone_remap)

		# Set looping for locomotion animations
		if normalized in ["idle", "walk", "run", "fall"]:
			fixed.loop_mode = Animation.LOOP_LINEAR

		if not lib.has_animation(normalized):
			lib.add_animation(normalized, fixed)
			Log.debug("animation", "  '%s' → '%s': %d tracks, %.1fs" % [
				anim_name, normalized, fixed.get_track_count(), fixed.length])

	return lib


## Fix track paths to ".:BoneName" format and remap bone names
static func _fix_and_remap_tracks(source: Animation, bone_remap: Dictionary) -> Animation:
	var result := Animation.new()
	result.length = source.length
	result.loop_mode = source.loop_mode

	for track_idx in source.get_track_count():
		var path := source.track_get_path(track_idx)
		var track_type := source.track_get_type(track_idx)

		# Extract bone name from track path
		# FBX imports produce various formats:
		#   "Armature/Skeleton3D:mixamorig1_Hips" (FBX)
		#   "Skeleton3D:mixamorig1_Hips"
		#   ".:mixamorig1_Hips"
		var bone_name := ""
		if path.get_subname_count() > 0:
			bone_name = String(path.get_subname(0))
		else:
			continue  # Not a bone track

		if bone_name.is_empty():
			continue

		# Remap bone name to normalized name
		var target_name := bone_name
		if bone_name in bone_remap:
			target_name = bone_remap[bone_name]

		# Build canonical track path
		var new_path := NodePath(".:" + target_name)

		# Copy track with fixed path
		var new_idx := result.add_track(track_type)
		result.track_set_path(new_idx, new_path)
		result.track_set_interpolation_type(new_idx, source.track_get_interpolation_type(track_idx))

		# Copy keyframes
		for key_idx in source.track_get_key_count(track_idx):
			var time := source.track_get_key_time(track_idx, key_idx)
			var value: Variant = source.track_get_key_value(track_idx, key_idx)
			var transition := source.track_get_key_transition(track_idx, key_idx)
			result.track_insert_key(new_idx, time, value, transition)

	return result


## Build bone remap from an actual skeleton in the imported scene.
## Auto-detects Mixamo format by checking for "mixamorig" prefix.
## preserve_names: if true, always uses identity remap (no bone name changes).
static func _build_remap_from_skeleton(skeleton: Skeleton3D, preserve_names: bool = false) -> Dictionary:
	var remap := {}

	if preserve_names:
		# Identity remap - keep all bone names as-is
		for i in skeleton.get_bone_count():
			var bone_name := skeleton.get_bone_name(i)
			remap[bone_name] = bone_name
		Log.info("animation", "AnimationLoader: Preserving original bone names (identity remap)")
		return remap

	# Check for Mixamo format (bones start with "mixamorig")
	var is_mixamo := false
	for i in skeleton.get_bone_count():
		var bone_name := skeleton.get_bone_name(i)
		if bone_name.begins_with("mixamorig"):
			is_mixamo = true
			break

	if is_mixamo:
		# Apply Mixamo bone map
		for i in skeleton.get_bone_count():
			var bone_name := skeleton.get_bone_name(i)
			if bone_name in _MIXAMO_BONE_MAP:
				remap[bone_name] = _MIXAMO_BONE_MAP[bone_name]
		Log.info("animation", "AnimationLoader: Detected Mixamo skeleton, mapped %d bones" % remap.size())
	else:
		# Unknown format - identity remap (bone names stay as-is)
		for i in skeleton.get_bone_count():
			var bone_name := skeleton.get_bone_name(i)
			remap[bone_name] = bone_name
		Log.info("animation", "AnimationLoader: Unknown skeleton format, using identity remap")

	return remap


## Normalize animation name using file name and animation name
static func _normalize_name(anim_name: String, file_path: String) -> String:
	var file_base := file_path.get_file().get_basename()
	var file_lower := file_base.to_lower()
	var anim_lower := anim_name.to_lower()

	# Pass 1: exact file name match
	for standard_name in _CHECK_ORDER:
		var patterns: Array = _NAME_PATTERNS.get(standard_name, [])
		for pattern: String in patterns:
			if file_lower == pattern:
				return standard_name

	# Pass 2: file name contains pattern
	for standard_name in _CHECK_ORDER:
		var patterns: Array = _NAME_PATTERNS.get(standard_name, [])
		for pattern: String in patterns:
			if pattern in file_lower:
				return standard_name

	# Pass 3: animation name match
	for standard_name in _CHECK_ORDER:
		var patterns: Array = _NAME_PATTERNS.get(standard_name, [])
		for pattern: String in patterns:
			if anim_lower == pattern or pattern in anim_lower:
				return standard_name

	# Fallback: clean file name
	return file_lower.replace(" ", "_").replace("-", "_")


## Find AnimationPlayer in scene tree
static func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var result := _find_animation_player(child)
		if result:
			return result
	return null


## Find Skeleton3D in scene tree
static func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var result := _find_skeleton(child)
		if result:
			return result
	return null
