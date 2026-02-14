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


## Load all animation files from a directory, also extracting the source skeleton's rest poses.
## Returns: { "library": AnimationLibrary, "source_rest": Dictionary }
## source_rest maps profile_bone_name -> Transform3D.
## Pass source_rest + target skeleton to retarget_library() to compensate for different rest poses.
static func load_from_directory_with_rest(dir_path: String, bone_remap: Dictionary = {}) -> Dictionary:
	var dir := DirAccess.open(dir_path)
	if not dir:
		push_warning("AnimationLoader: Cannot open directory: %s" % dir_path)
		return {}

	var merged := AnimationLibrary.new()
	var source_rest := {}
	var count := 0

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir():
			var lower := file_name.to_lower()
			if lower.ends_with(".fbx") or lower.ends_with(".glb") or lower.ends_with(".gltf"):
				var full_path := dir_path.path_join(file_name)
				var result := _load_fbx_with_rest(full_path, bone_remap)
				if result.has("library") and result["library"]:
					var lib: AnimationLibrary = result["library"]
					for anim_name: String in lib.get_animation_list():
						if not merged.has_animation(anim_name):
							merged.add_animation(anim_name, lib.get_animation(anim_name))
							count += 1
				# Extract rest poses from first file that has a skeleton
				if source_rest.is_empty() and result.has("source_rest"):
					source_rest = result["source_rest"]
		file_name = dir.get_next()
	dir.list_dir_end()

	Log.info("animation", "AnimationLoader: Loaded %d animations + %d rest poses from %s" % [
		count, source_rest.size(), dir_path])
	return { "library": merged if count > 0 else null, "source_rest": source_rest }


## Retarget an animation library from one skeleton's rest space to another.
## Converts rotation tracks so animations authored for source_rest play correctly on target_rest.
## source_rest: { profile_bone_name -> Transform3D } from the animation source skeleton
##   When target_uses_absolute=true, this should be the animation-derived rest (idle frame 0)
##   from extract_anim_rest_poses(), NOT the skeleton geometric rest.
## target_rest: { profile_bone_name -> Transform3D } from the skeleton that will play the animations
## target_uses_absolute: if true, the target skeleton uses absolute KF values as poses
##   (MW skeleton quirk — Godot computes local = rest * pose where pose = absolute value).
## source_geometric_rest: { profile_bone_name -> Transform3D } the FBX skeleton's geometric rest.
##   When provided with target_uses_absolute=true, enables axis-corrected conjugation that
##   accounts for different bone-local axis orientations between source and target skeletons.
##   Without this, motion deltas get applied around wrong axes when skeletons have different
##   rest orientations (e.g. Mixamo T-pose vs MW's Bip01 convention with 90° Y offset on Hips).
## target_global_idles: { bone_name -> Quaternion } pre-computed global idle orientations from
##   the actual target skeleton hierarchy (from compute_skeleton_global_idles()). When provided,
##   the CoB computation uses the actual skeleton hierarchy (including intermediate non-profile
##   bones like Bip01 Pelvis) instead of the profile hierarchy. This is critical for MW
##   skeletons where the profile hierarchy doesn't match the actual bone parent chain.
## Returns a new AnimationLibrary (originals not modified).
static func retarget_library(
		lib: AnimationLibrary,
		source_rest: Dictionary,
		target_rest: Dictionary,
		target_uses_absolute: bool = false,
		source_geometric_rest: Dictionary = {},
		target_global_idles: Dictionary = {}) -> AnimationLibrary:
	if not lib or source_rest.is_empty() or target_rest.is_empty():
		return lib

	var result := AnimationLibrary.new()
	var converted_bones := 0

	for anim_name: String in lib.get_animation_list():
		var source_anim: Animation = lib.get_animation(anim_name)
		var retargeted: Animation
		if target_uses_absolute:
			retargeted = _retarget_animation_absolute(source_anim, source_rest, target_rest, source_geometric_rest, target_global_idles)
		else:
			retargeted = _retarget_animation(source_anim, source_rest, target_rest)
		result.add_animation(anim_name, retargeted)

	# Count converted bones for logging
	var unmatched_bones := PackedStringArray()
	for bone_name: String in source_rest:
		if bone_name in target_rest:
			converted_bones += 1
		else:
			unmatched_bones.append(bone_name)

	Log.info("animation", "AnimationLoader: Retargeted %d animations (%d bones compensated, %d unmatched, absolute=%s)" % [
		lib.get_animation_list().size(), converted_bones, unmatched_bones.size(), str(target_uses_absolute)])
	if not unmatched_bones.is_empty():
		Log.info("animation", "  Unmatched source bones: %s" % ", ".join(unmatched_bones))
	return result


## Extract rest poses from a Skeleton3D, keyed by bone name.
## Returns { bone_name: String -> Transform3D }
static func get_skeleton_rest_poses(skeleton: Skeleton3D) -> Dictionary:
	var rest := {}
	for i in skeleton.get_bone_count():
		rest[skeleton.get_bone_name(i)] = skeleton.get_bone_rest(i)
	return rest


## Extract "effective rest poses" from the first frame of the idle animation.
##
## Godot's FBX importer may apply pre-rotations to the skeleton's bind pose
## that don't match the animation data. This causes a small per-bone error in
## retargeting that compounds down the chain. By using the idle animation's
## frame 0 as the source rest (instead of skeleton.get_bone_rest()), the
## retarget formula produces exact results at idle and better results during motion.
##
## skeleton_rest: the geometric rest poses from the FBX skeleton (for position + fallback)
## Returns: a copy of skeleton_rest with rotation components replaced by idle frame 0 values
static func extract_anim_rest_poses(lib: AnimationLibrary, skeleton_rest: Dictionary) -> Dictionary:
	# Find idle animation
	var idle_anim: Animation = null
	for anim_name: String in lib.get_animation_list():
		if "idle" in anim_name.to_lower():
			idle_anim = lib.get_animation(anim_name)
			break

	if not idle_anim:
		Log.info("animation", "AnimationLoader: No idle animation found — using skeleton rest poses")
		return skeleton_rest

	# Start with skeleton rest poses (for position + any bones without tracks)
	var result := skeleton_rest.duplicate()
	var overridden := 0

	# Override rotations with frame 0 values from idle animation
	for track_idx in idle_anim.get_track_count():
		var path := idle_anim.track_get_path(track_idx)
		if path.get_subname_count() == 0:
			continue
		var bone_name := String(path.get_subname(0))
		if bone_name not in result:
			continue

		var track_type := idle_anim.track_get_type(track_idx)
		if track_type == Animation.TYPE_ROTATION_3D and idle_anim.track_get_key_count(track_idx) > 0:
			var frame0_rot: Quaternion = idle_anim.track_get_key_value(track_idx, 0)
			var rest_xf: Transform3D = result[bone_name]
			# Replace rotation with animation frame 0 value, keep position from skeleton
			result[bone_name] = Transform3D(Basis(frame0_rot), rest_xf.origin)
			overridden += 1

	Log.info("animation", "AnimationLoader: Extracted anim rest for %d/%d bones from idle frame 0" % [
		overridden, skeleton_rest.size()])
	return result


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


## Compute global idle-chain orientation for each bone using the ACTUAL skeleton hierarchy.
##
## The SkeletonProfileHumanoid hierarchy doesn't include intermediate bones like
## "Bip01 Pelvis" that exist in the actual MW skeleton between "Hips" (Bip01) and
## "LeftUpperLeg" (Bip01 L Thigh). Using the profile hierarchy for the CoB parent
## chain misses these bones' rest rotation contribution, causing wrong axis mapping
## for all descendant bones (legs go sideways instead of forward/back).
##
## This function walks the actual skeleton (including ALL bones, profile or not)
## to compute the true global idle orientation at each bone.
##
## skeleton: the Skeleton3D (should already have profile-renamed bones for MW)
## idle_overrides: { bone_name -> Quaternion } idle rotation per bone.
##   For bones not in idle_overrides, rest rotation is used as idle.
##   For MW: pass each bone's rest rotation (idle ≈ rest for MW KF).
## Returns: { bone_name -> Quaternion } global idle orientation for every bone.
static func compute_skeleton_global_idles(skeleton: Skeleton3D, idle_overrides: Dictionary = {}) -> Dictionary:
	var result := {}
	for i in skeleton.get_bone_count():
		var bone_name := skeleton.get_bone_name(i)
		var rest_rot := skeleton.get_bone_rest(i).basis.get_rotation_quaternion()

		# Idle value: override if provided, otherwise use rest (MW idle ≈ rest)
		var idle_rot: Quaternion = idle_overrides.get(bone_name, rest_rot)

		var parent_idx := skeleton.get_bone_parent(i)
		var parent_global := Quaternion.IDENTITY
		if parent_idx >= 0:
			var parent_name := skeleton.get_bone_name(parent_idx)
			parent_global = result.get(parent_name, Quaternion.IDENTITY)

		# global_idle = parent_global * rest * idle
		# This is the Godot model: local = rest * pose, and idle pose ≈ idle_rot
		result[bone_name] = parent_global * rest_rot * idle_rot
	return result


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
	Log.info("animation", "AnimationLoader: Extracting %d animations from '%s' (remap: %d entries)" % [
		anim_list.size(), source_path.get_file(), bone_remap.size()])

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


## Format quaternion for diagnostic logging (compact)
static func _qstr(q: Quaternion) -> String:
	return "(%.3f,%.3f,%.3f,%.3f)" % [q.x, q.y, q.z, q.w]


## Compute per-bone pose-space change-of-basis for retargeting.
##
## For the SOURCE skeleton (Mixamo), uses the SkeletonProfileHumanoid hierarchy
## which is correct (Mixamo has no intermediate non-profile bones).
##
## For the TARGET skeleton (MW), when target_global_idles is provided, uses
## pre-computed global idle orientations from the ACTUAL skeleton hierarchy.
## This is critical because the MW skeleton has intermediate bones like
## "Bip01 Pelvis" between profile bones (e.g. between Hips and LeftUpperLeg)
## that the profile hierarchy doesn't know about. Without this, the CoB
## computation produces wrong axis mappings for all descendant bones.
##
## The pose-space frame F is where Godot applies the bone's pose value:
##   F(bone) = global_idle(bone) * idle(bone)⁻¹
## The change-of-basis C = F_t⁻¹ * F_s maps from source to target pose-space.
## The retarget formula per keyframe:
##   corrected = C * anim * idle_src⁻¹ * C⁻¹ * R_t
##
## Returns: { "left": { bone -> Quaternion }, "right": { bone -> Quaternion } }
## where corrected = left[bone] * anim * right[bone]
static func _compute_global_change_of_basis(
		source_rest: Dictionary,
		target_rest: Dictionary,
		source_geometric_rest: Dictionary,
		target_global_idles: Dictionary = {}) -> Dictionary:
	var profile := SkeletonProfileHumanoid.new()

	# Build parent map from profile hierarchy
	var bone_parent: Dictionary = {}  # bone_name -> parent_bone_name
	var bone_order: Array[String] = []  # profile ordering (parent-first)
	for i in profile.bone_size:
		var bone_name := String(profile.get_bone_name(i))
		bone_order.append(bone_name)
		var parent_name_sn: StringName = profile.get_bone_parent(i)
		if not parent_name_sn.is_empty():
			bone_parent[bone_name] = String(parent_name_sn)

	# Walk hierarchy root-to-leaf computing:
	# 1. Idle-chain globals (for children to use as parent global)
	# 2. Pose-space frames (parent idle-chain * bone_rest)
	# 3. Per-bone change-of-basis from source to target pose-space
	var src_global: Dictionary = {}  # bone_name -> Quaternion (idle-chain orientation)
	var tgt_global: Dictionary = {}
	var bone_left: Dictionary = {}
	var bone_right: Dictionary = {}

	for bone_name in bone_order:
		if bone_name not in source_rest or bone_name not in target_rest:
			continue
		if bone_name not in source_geometric_rest:
			continue

		var R_s_geom: Quaternion = source_geometric_rest[bone_name].basis.get_rotation_quaternion()
		var idle_s: Quaternion = source_rest[bone_name].basis.get_rotation_quaternion()
		var R_t: Quaternion = target_rest[bone_name].basis.get_rotation_quaternion()

		# Get parent globals (identity for root bones)
		var parent_name: String = bone_parent.get(bone_name, "")
		var G_s_parent: Quaternion = src_global.get(parent_name, Quaternion.IDENTITY)
		var G_t_parent: Quaternion = tgt_global.get(parent_name, Quaternion.IDENTITY)

		# Source pose-space frame (profile hierarchy is correct for Mixamo)
		var F_s: Quaternion = G_s_parent * R_s_geom

		# Target pose-space frame
		# When target_global_idles is available, use the actual skeleton hierarchy
		# (includes intermediate non-profile bones like Bip01 Pelvis).
		# F_t = global_idle(bone) * idle(bone)⁻¹ = global_idle(bone) * R_t⁻¹
		var F_t: Quaternion
		if not target_global_idles.is_empty() and bone_name in target_global_idles:
			F_t = target_global_idles[bone_name] * R_t.inverse()
		else:
			F_t = G_t_parent * R_t

		# Change of basis: source pose-space → target pose-space
		var C: Quaternion = F_t.inverse() * F_s

		# corrected = C * anim * idle_s⁻¹ * C⁻¹ * R_t
		bone_left[bone_name] = C
		bone_right[bone_name] = idle_s.inverse() * C.inverse() * R_t

		# Idle-chain globals (children use this as parent global)
		src_global[bone_name] = F_s * idle_s
		if not target_global_idles.is_empty() and bone_name in target_global_idles:
			tgt_global[bone_name] = target_global_idles[bone_name]
		else:
			tgt_global[bone_name] = F_t * R_t

	Log.info("animation", "AnimationLoader: Pose-space CoB computed for %d bones" % bone_left.size())
	return { "left": bone_left, "right": bone_right }


## Load a single FBX file and also extract skeleton rest poses.
## Returns: { "library": AnimationLibrary, "source_rest": Dictionary }
static func _load_fbx_with_rest(path: String, bone_remap: Dictionary = {}) -> Dictionary:
	var scene: PackedScene = load(path) as PackedScene
	if not scene:
		Log.info("animation", "AnimationLoader: Cannot load FBX scene: %s" % path)
		return {}

	var root := scene.instantiate()
	if not root:
		Log.info("animation", "AnimationLoader: Cannot instantiate FBX: %s" % path)
		return {}

	# Extract rest poses from the source skeleton
	var source_rest := {}
	var skeleton := _find_skeleton(root)
	if skeleton:
		Log.info("animation", "AnimationLoader: FBX '%s' has skeleton with %d bones" % [
			path.get_file(), skeleton.get_bone_count()])
		if bone_remap.is_empty():
			bone_remap = _build_remap_from_skeleton(skeleton)
		Log.info("animation", "  Bone remap: %d entries" % bone_remap.size())
		# Map rest poses to profile bone names
		for i in skeleton.get_bone_count():
			var bone_name := skeleton.get_bone_name(i)
			var profile_name: String = bone_remap.get(bone_name, bone_name)
			source_rest[profile_name] = skeleton.get_bone_rest(i)
	else:
		Log.info("animation", "AnimationLoader: FBX '%s' has NO skeleton (animation-only export?)" % path.get_file())

	var lib := _extract_and_remap(root, path, bone_remap)
	root.queue_free()
	return { "library": lib, "source_rest": source_rest }


## Retarget a single animation from source rest space to target rest space.
## Formula: corrected_rot = target_rest_rot⁻¹ * source_rest_rot * original_rot
## This ensures: target_rest * corrected = source_rest * original (same visual result)
static func _retarget_animation(
		source: Animation,
		source_rest: Dictionary,
		target_rest: Dictionary) -> Animation:
	var result := Animation.new()
	result.length = source.length
	result.loop_mode = source.loop_mode

	for track_idx in source.get_track_count():
		var path := source.track_get_path(track_idx)
		var track_type := source.track_get_type(track_idx)

		# Get bone name from track path (".:BoneName")
		var bone_name := ""
		if path.get_subname_count() > 0:
			bone_name = String(path.get_subname(0))

		# Check if we have rest poses for this bone
		var has_source := bone_name in source_rest
		var has_target := bone_name in target_rest

		# Add track
		var new_idx := result.add_track(track_type)
		result.track_set_path(new_idx, path)
		result.track_set_interpolation_type(new_idx, source.track_get_interpolation_type(track_idx))

		if has_source and has_target and track_type == Animation.TYPE_ROTATION_3D:
			var src_rest: Transform3D = source_rest[bone_name]
			var tgt_rest: Transform3D = target_rest[bone_name]
			var src_rot := src_rest.basis.get_rotation_quaternion()
			var tgt_rot_inv := tgt_rest.basis.get_rotation_quaternion().inverse()

			for key_idx in source.track_get_key_count(track_idx):
				var time := source.track_get_key_time(track_idx, key_idx)
				var original_rot: Quaternion = source.track_get_key_value(track_idx, key_idx)
				var corrected := tgt_rot_inv * src_rot * original_rot
				result.rotation_track_insert_key(new_idx, time, corrected)

		elif has_source and has_target and track_type == Animation.TYPE_POSITION_3D:
			var src_rest: Transform3D = source_rest[bone_name]
			var tgt_rest: Transform3D = target_rest[bone_name]
			var src_basis := src_rest.basis
			var tgt_basis_inv := tgt_rest.basis.inverse()

			for key_idx in source.track_get_key_count(track_idx):
				var time := source.track_get_key_time(track_idx, key_idx)
				var original_pos: Vector3 = source.track_get_key_value(track_idx, key_idx)
				# corrected_pos = tgt_basis⁻¹ * (src_origin - tgt_origin + src_basis * original_pos)
				var corrected := tgt_basis_inv * (
					src_rest.origin - tgt_rest.origin + src_basis * original_pos)
				result.position_track_insert_key(new_idx, time, corrected)

		else:
			# Copy keyframes as-is (scale tracks, unmatched bones)
			for key_idx in source.track_get_key_count(track_idx):
				var time := source.track_get_key_time(track_idx, key_idx)
				var value: Variant = source.track_get_key_value(track_idx, key_idx)
				var transition := source.track_get_key_transition(track_idx, key_idx)
				result.track_insert_key(new_idx, time, value, transition)

	return result


## Retarget a single animation for a target skeleton that uses absolute values as poses.
##
## Both Godot FBX imports and MW KF files store ABSOLUTE bone local rotations:
##   - Mixamo idle: animation value ≈ Mixamo rest rotation (NOT identity)
##   - MW idle: animation value ≈ MW rest rotation
##   - Godot computes: local = rest * pose, so idle local = rest² for both
##
## Pose-space change-of-basis retargeting (when source_geometric_rest is provided):
##   Computes per-bone CoB from the REST-CHAIN (not model-chain) of both skeletons
##   via _compute_global_change_of_basis(). The CoB conjugation correctly maps
##   bone-local animation deltas between skeletons with different rest orientations.
##   Formula: corrected = left[bone] * anim * right[bone]
##   where left = tgt_idle * C * src_idle⁻¹, right = C⁻¹
##   At idle: corrected = tgt_idle ✓
##
## Fallback (no source_geometric_rest): uses simple formula tgt * src⁻¹ * anim.
##
## Hemisphere normalization: FBX may store -q (same rotation, opposite hemisphere).
## We normalize the first keyframe to src_rot's hemisphere, then each subsequent
## keyframe to the previous one's hemisphere (ensures smooth interpolation).
##
## Positions: root/hips translation delta is scaled by height ratio. Non-root bones
## use target rest position + scaled delta to preserve MW skeleton shape while
## keeping subtle animation motion (breathing, sway).
static func _retarget_animation_absolute(
		source: Animation,
		source_rest: Dictionary,
		target_rest: Dictionary,
		source_geometric_rest: Dictionary = {},
		target_global_idles: Dictionary = {}) -> Animation:
	var result := Animation.new()
	result.length = source.length
	result.loop_mode = source.loop_mode

	# When source_geometric_rest is available, use pose-space change-of-basis (CoB)
	# to correctly handle different bone-local axis orientations between skeletons.
	# Formula: corrected = left[bone] * anim * right[bone]
	# where left/right are precomputed from the rest-chain CoB.
	# Without geometric rest, falls back to simple baseline swap.
	var cob_left: Dictionary = {}
	var cob_right: Dictionary = {}
	if not source_geometric_rest.is_empty():
		var cob := _compute_global_change_of_basis(source_rest, target_rest, source_geometric_rest, target_global_idles)
		cob_left = cob["left"]
		cob_right = cob["right"]

	for track_idx in source.get_track_count():
		var path := source.track_get_path(track_idx)
		var track_type := source.track_get_type(track_idx)

		var bone_name := ""
		if path.get_subname_count() > 0:
			bone_name = String(path.get_subname(0))

		var has_source := bone_name in source_rest
		var has_target := bone_name in target_rest

		var new_idx := result.add_track(track_type)
		result.track_set_path(new_idx, path)
		result.track_set_interpolation_type(new_idx, source.track_get_interpolation_type(track_idx))

		if has_source and has_target and track_type == Animation.TYPE_ROTATION_3D:
			var idle_src: Quaternion = source_rest[bone_name].basis.get_rotation_quaternion()

			# Use CoB left/right when available, otherwise simple baseline swap
			var left: Quaternion
			var right: Quaternion
			if bone_name in cob_left:
				left = cob_left[bone_name]
				right = cob_right[bone_name]
			else:
				var tgt_rot: Quaternion = target_rest[bone_name].basis.get_rotation_quaternion()
				left = tgt_rot * idle_src.inverse()
				right = Quaternion.IDENTITY

			var prev_rot := idle_src  # For consecutive-keyframe hemisphere tracking
			var key_count := source.track_get_key_count(track_idx)
			for key_idx in key_count:
				var time := source.track_get_key_time(track_idx, key_idx)
				var original_rot: Quaternion = source.track_get_key_value(track_idx, key_idx)

				# Hemisphere normalization:
				# First keyframe: normalize to source idle hemisphere
				# Subsequent keyframes: normalize to previous keyframe hemisphere
				if prev_rot.dot(original_rot) < 0.0:
					original_rot = -original_rot
				prev_rot = original_rot

				var corrected := left * original_rot * right
				result.rotation_track_insert_key(new_idx, time, corrected)

		elif has_source and has_target and track_type == Animation.TYPE_POSITION_3D:
			var tgt_rest: Transform3D = target_rest[bone_name]
			var src_rest: Transform3D = source_rest[bone_name]
			var is_root := bone_name == "Hips" or bone_name == "Root"

			# Compute bone length ratio for scaling position deltas
			var src_len := maxf(0.001, src_rest.origin.length())
			var tgt_len := maxf(0.001, tgt_rest.origin.length())
			var length_ratio := tgt_len / src_len

			for key_idx in source.track_get_key_count(track_idx):
				var time := source.track_get_key_time(track_idx, key_idx)
				var original_pos: Vector3 = source.track_get_key_value(track_idx, key_idx)
				var delta := original_pos - src_rest.origin

				if is_root:
					# Root: scale translation delta by height ratio
					result.position_track_insert_key(new_idx, time, tgt_rest.origin + delta * length_ratio)
				elif delta.length_squared() > 0.0001:
					# Non-root with meaningful position animation: scale by bone length
					result.position_track_insert_key(new_idx, time, tgt_rest.origin + delta * length_ratio)
				else:
					# Non-root, no meaningful delta: use target rest position
					result.position_track_insert_key(new_idx, time, tgt_rest.origin)

		else:
			for key_idx in source.track_get_key_count(track_idx):
				var time := source.track_get_key_time(track_idx, key_idx)
				var value: Variant = source.track_get_key_value(track_idx, key_idx)
				var transition := source.track_get_key_transition(track_idx, key_idx)
				result.track_insert_key(new_idx, time, value, transition)

	return result
