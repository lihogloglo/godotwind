## AnimationLoader — Unified animation loading from multiple formats
##
## Loads animations from FBX, GLB, GLTF, and KF files, normalizing all output
## to ".:ProfileBoneName" track format ready for use with the animation pipeline.
##
## Track path convention:
##   ".:BoneName" — bone tracks target the Skeleton3D at root_node
##   This is consistent with KF loader and AnimationTree root_node setup.
##
## Usage:
##   var lib := AnimationLoader.load_from_directory("res://assets/animations/mixamo/")
##   anim_player.add_animation_library("mixamo", lib)
class_name AnimationLoader
extends RefCounted


const SPA := preload("res://src/core/animation/skeleton_profile_adapter.gd")
const RetargetSetupScript := preload("res://src/core/animation/retarget_setup.gd")


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


# =============================================================================
# PUBLIC API
# =============================================================================

## Load animations from a single FBX file.
## Returns an AnimationLibrary with profile-named bone tracks (".:ProfileBone").
## bone_remap: optional pre-computed { native_name -> profile_name } dict.
##   If empty, builds a Mixamo remap automatically from the FBX skeleton.
static func load_from_fbx(path: String, bone_remap: Dictionary = {}) -> AnimationLibrary:
	var scene: PackedScene = load(path) as PackedScene
	if not scene:
		push_warning("AnimationLoader: Cannot load FBX: %s" % path)
		return null

	var root := scene.instantiate()
	if not root:
		push_warning("AnimationLoader: Cannot instantiate: %s" % path)
		return null

	var lib := _extract_and_remap(root, path, bone_remap)
	root.queue_free()
	return lib


## Load animations from a GLB/GLTF file.
static func load_from_glb(path: String, bone_remap: Dictionary = {}) -> AnimationLibrary:
	return load_from_fbx(path, bone_remap)  # Godot imports both as PackedScene


## Load all animation files from a directory.
## Returns a single AnimationLibrary with all animations merged.
static func load_from_directory(dir_path: String, bone_remap: Dictionary = {}) -> AnimationLibrary:
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
				var lib := load_from_fbx(full_path, bone_remap)
				if lib:
					for anim_name: String in lib.get_animation_list():
						if not merged.has_animation(anim_name):
							merged.add_animation(anim_name, lib.get_animation(anim_name))
							count += 1
		file_name = dir.get_next()
	dir.list_dir_end()

	Log.info("animation", "AnimationLoader: Loaded %d animations from %s" % [count, dir_path])
	return merged if count > 0 else null


## Build a Mixamo bone remap dictionary (mixamo_bone_name -> profile_name).
## Call once to pre-compute, then pass to load_from_fbx/load_from_directory.
static func build_mixamo_remap() -> Dictionary:
	# Create a temporary skeleton with Mixamo bone names to build the remap
	var skel := Skeleton3D.new()
	for mixamo_name: String in SPA._MIXAMO_MAP.values():
		# We need the reverse: profile_name is the value, we need mixamo -> profile
		pass

	# Simpler: iterate the Mixamo map directly
	# _MIXAMO_MAP keys are lowercase stripped names, but actual FBX bones have prefix
	# We need: actual_mixamo_bone_name -> profile_name
	var remap := {}
	# Mixamo FBX bones use "mixamorig1_Hips" format
	for stripped_lower: String in SPA._MIXAMO_MAP:
		var profile_name: String = SPA._MIXAMO_MAP[stripped_lower]
		# Build both common prefix variants
		# Pascal-case the stripped name for the actual bone name
		var pascal := _to_pascal_case(stripped_lower)
		remap["mixamorig1_" + pascal] = profile_name
		remap["mixamorig_" + pascal] = profile_name

	skel.free()
	return remap


# =============================================================================
# INTERNAL
# =============================================================================

## Extract animations from an instantiated scene and remap to profile bone names
static func _extract_and_remap(root: Node, source_path: String, bone_remap: Dictionary) -> AnimationLibrary:
	var anim_player := _find_animation_player(root)
	if not anim_player:
		push_warning("AnimationLoader: No AnimationPlayer in: %s" % source_path)
		return null

	# Auto-detect remap if not provided
	if bone_remap.is_empty():
		var skeleton := _find_skeleton(root)
		if skeleton:
			bone_remap = _build_remap_from_skeleton(skeleton)

	var lib := AnimationLibrary.new()
	var anim_list := anim_player.get_animation_list()

	for anim_name: String in anim_list:
		if anim_name == "RESET":
			continue
		var source_anim := anim_player.get_animation(anim_name)
		if not source_anim:
			continue

		# Normalize name from file/anim name
		var normalized := _normalize_name(anim_name, source_path)

		# Fix track paths to ".:bone_name" and remap to profile names
		var fixed := _fix_and_remap_tracks(source_anim, bone_remap)

		# Set looping for locomotion animations
		if normalized in ["idle", "walk", "run", "fall"]:
			fixed.loop_mode = Animation.LOOP_LINEAR

		if not lib.has_animation(normalized):
			lib.add_animation(normalized, fixed)

	return lib


## Fix track paths to ".:BoneName" format and remap bone names
static func _fix_and_remap_tracks(source: Animation, bone_remap: Dictionary) -> Animation:
	var result := Animation.new()
	result.length = source.length
	result.loop_mode = source.loop_mode

	for track_idx in source.get_track_count():
		var path := source.track_get_path(track_idx)
		var track_type := source.track_get_type(track_idx)
		var path_str := str(path)

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

		# Remap bone name to profile name
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


## Build bone remap from an actual skeleton in the imported scene
static func _build_remap_from_skeleton(skeleton: Skeleton3D) -> Dictionary:
	var skel_type := SPA.detect_skeleton_type(skeleton)

	match skel_type:
		SPA.SkeletonType.MIXAMO:
			return _build_mixamo_remap_from_skeleton(skeleton)
		SPA.SkeletonType.MORROWIND:
			return RetargetSetupScript.build_remap(skeleton)
		_:
			return RetargetSetupScript.build_remap(skeleton)


## Build Mixamo bone remap from actual skeleton bone names
static func _build_mixamo_remap_from_skeleton(skeleton: Skeleton3D) -> Dictionary:
	var remap := {}
	for i in skeleton.get_bone_count():
		var bone_name := skeleton.get_bone_name(i)
		# Strip prefix: "mixamorig1_Hips" → "Hips" → "hips"
		var stripped := bone_name
		if stripped.begins_with("mixamorig1_"):
			stripped = stripped.substr(11)
		elif stripped.begins_with("mixamorig_"):
			stripped = stripped.substr(10)
		var lower := stripped.to_lower()
		if lower in SPA._MIXAMO_MAP:
			remap[bone_name] = SPA._MIXAMO_MAP[lower]
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


## Convert a lowercase string to PascalCase (e.g. "leftshoulder" → "LeftShoulder")
## This is approximate — used for building Mixamo bone name variants
static func _to_pascal_case(lower: String) -> String:
	# Known Mixamo bone name patterns (lowercase → actual case)
	const KNOWN := {
		"hips": "Hips", "spine": "Spine", "spine1": "Spine1", "spine2": "Spine2",
		"neck": "Neck", "head": "Head",
		"leftshoulder": "LeftShoulder", "leftarm": "LeftArm",
		"leftforearm": "LeftForeArm", "lefthand": "LeftHand",
		"rightshoulder": "RightShoulder", "rightarm": "RightArm",
		"rightforearm": "RightForeArm", "righthand": "RightHand",
		"leftupleg": "LeftUpLeg", "leftleg": "LeftLeg",
		"leftfoot": "LeftFoot", "lefttoebase": "LeftToeBase",
		"rightupleg": "RightUpLeg", "rightleg": "RightLeg",
		"rightfoot": "RightFoot", "righttoebase": "RightToeBase",
	}
	if lower in KNOWN:
		return KNOWN[lower]
	return lower.capitalize().replace(" ", "")


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
