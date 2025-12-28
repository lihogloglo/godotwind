## MixamoAnimationLoader - Loads and manages Mixamo animations for NextGen characters
##
## Handles:
## - Loading animations from FBX/GLB/GLTF files exported from Mixamo
## - Creating AnimationLibrary from loaded animations
## - Caching animations for reuse across characters
## - Animation name normalization
##
## Usage:
##   var library := MixamoAnimationLoader.get_animation_library()
##   anim_player.add_animation_library("mixamo", library)
class_name MixamoAnimationLoader
extends RefCounted


## Path to Mixamo animation assets
const MIXAMO_ANIMATIONS_PATH := "res://assets/animations/mixamo/"

## Standard animation names we expect/use
## Order matters - more specific patterns should come first
const ANIMATION_NAMES := {
	# Jump variants - check these BEFORE generic "jump"
	"jump_up": ["Jumping Up", "Jump Up", "JumpUp"],
	"jump_down": ["Jumping Down", "Jump Down", "JumpDown"],
	# Basic locomotion
	"idle": ["Idle", "idle", "Standing Idle", "Breathing Idle"],
	"walk": ["Walking", "walk", "Walk"],
	"run": ["Running", "run", "Run", "Jogging"],
	"jump": ["Jump", "Jumping"],
	"fall": ["Falling", "Fall", "Falling Idle"],
	"land": ["Landing", "Land"],
}

## Cached animation library (shared across all characters)
static var _cached_library: AnimationLibrary = null
static var _cached_animations: Dictionary = {}  # name -> Animation


## Get or create the shared animation library
static func get_animation_library() -> AnimationLibrary:
	if _cached_library != null:
		return _cached_library

	_cached_library = AnimationLibrary.new()
	_load_all_animations()
	return _cached_library


## Load all animations from the mixamo folder
static func _load_all_animations() -> void:
	var dir := DirAccess.open(MIXAMO_ANIMATIONS_PATH)
	if dir == null:
		push_warning("MixamoAnimationLoader: Cannot open animations folder: %s" % MIXAMO_ANIMATIONS_PATH)
		return

	dir.list_dir_begin()
	var file_name := dir.get_next()

	while file_name != "":
		if not dir.current_is_dir():
			var lower := file_name.to_lower()
			# Handle FBX, GLB, GLTF files (skip .import files)
			if lower.ends_with(".fbx") or lower.ends_with(".glb") or lower.ends_with(".gltf"):
				var full_path := MIXAMO_ANIMATIONS_PATH + file_name
				_load_animation_file(full_path)
		file_name = dir.get_next()

	dir.list_dir_end()


## Load animations from a single FBX/GLB/GLTF file
static func _load_animation_file(path: String) -> bool:
	var lower := path.to_lower()

	# FBX files are imported by Godot as PackedScene resources
	if lower.ends_with(".fbx"):
		return _load_fbx_animation(path)
	else:
		# GLB/GLTF - load directly
		return _load_gltf_animation(path)


## Load animation from an imported FBX file
static func _load_fbx_animation(path: String) -> bool:
	# Godot imports FBX as a PackedScene - load it
	var scene: PackedScene = load(path) as PackedScene
	if scene == null:
		push_warning("MixamoAnimationLoader: Cannot load FBX: %s" % path)
		return false

	# Instantiate to access AnimationPlayer
	var root := scene.instantiate()
	if root == null:
		push_warning("MixamoAnimationLoader: Cannot instantiate FBX scene: %s" % path)
		return false

	var success := _extract_animations_from_scene(root, path)
	root.queue_free()
	return success


## Load animation from a GLB/GLTF file
static func _load_gltf_animation(path: String) -> bool:
	var gltf_doc := GLTFDocument.new()
	var gltf_state := GLTFState.new()
	gltf_state.set_create_animations(true)

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("MixamoAnimationLoader: Cannot open file: %s" % path)
		return false

	var buffer := file.get_buffer(file.get_length())
	file.close()

	var err := gltf_doc.append_from_buffer(buffer, "", gltf_state)
	if err != OK:
		push_warning("MixamoAnimationLoader: Failed to parse GLTF: %s (error %d)" % [path, err])
		return false

	var root := gltf_doc.generate_scene(gltf_state)
	if root == null:
		push_warning("MixamoAnimationLoader: Failed to generate scene from: %s" % path)
		return false

	var success := _extract_animations_from_scene(root, path)
	root.queue_free()
	return success


## Extract animations from a scene (works for both FBX and GLTF)
static func _extract_animations_from_scene(root: Node, path: String) -> bool:
	# Find AnimationPlayer in the scene
	var anim_player := _find_animation_player(root)
	if anim_player == null:
		push_warning("MixamoAnimationLoader: No AnimationPlayer in: %s" % path)
		return false

	# Extract animations
	var anim_count := 0
	var anim_list := anim_player.get_animation_list()

	for anim_name in anim_list:
		var anim := anim_player.get_animation(anim_name)
		if anim == null:
			continue

		# Normalize the animation name
		var normalized_name := _normalize_animation_name(anim_name, path)

		# Clone the animation and fix bone paths
		var fixed_anim := _fix_animation_paths(anim)

		# Set looping for idle/walk/run
		if normalized_name in ["idle", "walk", "run"]:
			fixed_anim.loop_mode = Animation.LOOP_LINEAR

		# Add to library
		if _cached_library.has_animation(normalized_name):
			_cached_library.remove_animation(normalized_name)

		var add_err := _cached_library.add_animation(normalized_name, fixed_anim)
		if add_err == OK:
			_cached_animations[normalized_name] = fixed_anim
			anim_count += 1

	return anim_count > 0


## Find AnimationPlayer in a node tree
static func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var result := _find_animation_player(child)
		if result:
			return result
	return null


## Normalize animation name to our standard names
## Checks file name first, then animation name, with specific patterns before generic ones
static func _normalize_animation_name(anim_name: String, file_path: String) -> String:
	var file_base := file_path.get_file().get_basename()
	var file_lower := file_base.to_lower()
	var anim_lower := anim_name.to_lower()

	# Check order: more specific patterns first
	var check_order: Array[String] = [
		"jump_up", "jump_down",  # Check before "jump"
		"idle", "walk", "run", "jump", "fall", "land"
	]

	# First pass: exact file name match (most reliable)
	for standard_name in check_order:
		if not standard_name in ANIMATION_NAMES:
			continue
		var patterns: Array = ANIMATION_NAMES[standard_name]
		for pattern in patterns:
			if file_lower == pattern.to_lower():
				return standard_name

	# Second pass: file name contains pattern
	for standard_name in check_order:
		if not standard_name in ANIMATION_NAMES:
			continue
		var patterns: Array = ANIMATION_NAMES[standard_name]
		for pattern in patterns:
			if file_lower.contains(pattern.to_lower()):
				return standard_name

	# Third pass: animation name match
	for standard_name in check_order:
		if not standard_name in ANIMATION_NAMES:
			continue
		var patterns: Array = ANIMATION_NAMES[standard_name]
		for pattern in patterns:
			if anim_lower == pattern.to_lower() or anim_lower.contains(pattern.to_lower()):
				return standard_name

	# Final fallback: use cleaned file name
	return file_lower.replace(" ", "_").replace("-", "_")


## Fix animation track paths for our skeleton structure
## Mixamo FBX exports use paths like "Armature/Skeleton3D:mixamorig_Hips"
## We need "Skeleton3D:mixamorig_Hips" to match our character structure
static func _fix_animation_paths(source: Animation) -> Animation:
	var anim := Animation.new()
	anim.length = source.length
	anim.loop_mode = source.loop_mode

	for track_idx in source.get_track_count():
		var track_path := source.track_get_path(track_idx)
		var track_type := source.track_get_type(track_idx)
		var path_str := str(track_path)

		# Skip non-bone tracks (like root motion, blend shapes, etc.)
		if not ":" in path_str:
			continue

		# Extract the bone name part (after the colon)
		var bone_part := ""
		var colon_idx := path_str.rfind(":")
		if colon_idx >= 0:
			bone_part = path_str.substr(colon_idx + 1)

		# Skip if no bone name or not a mixamo bone
		if bone_part.is_empty():
			continue

		# Build fixed path: "Skeleton3D:bone_name"
		var fixed_path := "Skeleton3D:" + bone_part

		# Add the track with fixed path
		var new_idx := anim.add_track(track_type)
		anim.track_set_path(new_idx, NodePath(fixed_path))
		anim.track_set_interpolation_type(new_idx, source.track_get_interpolation_type(track_idx))

		# Copy all keyframes
		for key_idx in source.track_get_key_count(track_idx):
			var time := source.track_get_key_time(track_idx, key_idx)
			var value: Variant = source.track_get_key_value(track_idx, key_idx)
			var transition := source.track_get_key_transition(track_idx, key_idx)
			anim.track_insert_key(new_idx, time, value, transition)

	return anim


## Check if we have a specific animation loaded
static func has_animation(name: String) -> bool:
	if _cached_library == null:
		get_animation_library()
	return _cached_library.has_animation(name)


## Get a specific animation by name
static func get_animation(name: String) -> Animation:
	if _cached_library == null:
		get_animation_library()
	return _cached_library.get_animation(name)


## Get list of all loaded animation names
static func get_animation_names() -> PackedStringArray:
	if _cached_library == null:
		get_animation_library()
	return _cached_library.get_animation_list()


## Clear the cache (useful for reloading)
static func clear_cache() -> void:
	_cached_library = null
	_cached_animations.clear()


## Reload all animations
static func reload() -> void:
	clear_cache()
	get_animation_library()


## Debug: Print loaded animations
static func print_loaded_animations() -> void:
	if _cached_library == null:
		get_animation_library()

	var names := _cached_library.get_animation_list()
	for anim_name in names:
		var anim := _cached_library.get_animation(anim_name)
		var loop_str := "none"
		match anim.loop_mode:
			Animation.LOOP_NONE: loop_str = "none"
			Animation.LOOP_LINEAR: loop_str = "linear"
			Animation.LOOP_PINGPONG: loop_str = "pingpong"
		print("  %s: %.2fs, %d tracks, loop=%s" % [
			anim_name,
			anim.length,
			anim.get_track_count(),
			loop_str
		])
