## RetargetSetup — Utilities for cross-skeleton animation retargeting
##
## Provides building blocks for configuring RetargetModifier3D to play
## animations authored for one skeleton type on a different skeleton type.
## Both skeletons are normalized to SkeletonProfileHumanoid bone names
## so the modifier can transfer poses between them.
##
## Two-skeleton hierarchy (when retargeting is active):
##   SourceSkeleton (profile bone names, animation source rest poses)
##     ├── AnimationPlayer (animations play here)
##     ├── AnimationTree
##     └── RetargetModifier3D
##           └── TargetSkeleton (profile bone names, character rest poses, meshes)
##
## Workflow:
##   1. build_remap(source_skeleton) — get source → profile name map
##   2. remap_library(anim_lib, remap) — remap animation tracks to profile names
##   3. rename_bones_to_profile(target_skeleton) — normalize target bone names
##   4. create_source_skeleton(target) — create source skeleton from target structure
##   5. create_modifier() — create RetargetModifier3D
##   6. Assemble hierarchy: source > modifier > target (caller's responsibility)
class_name RetargetSetup
extends RefCounted


const SPA := preload("res://src/core/animation/skeleton_profile_adapter.gd")


# =============================================================================
# BONE RENAMING
# =============================================================================

## Rename skeleton bones from native names to SkeletonProfileHumanoid names.
## Bones not mapped in the BoneMap are left unchanged.
## Returns: Dictionary { old_name: String -> new_name: String } for renamed bones only.
##
## NOTE: After renaming, stale BoneMap metadata is cleared. Call SPA.create_bone_map()
## again if you need a new BoneMap (it will produce an identity map since bones are
## already profile-named).
static func rename_bones_to_profile(skeleton: Skeleton3D, bone_map: BoneMap = null) -> Dictionary:
	if not skeleton:
		return {}

	if not bone_map:
		bone_map = SPA.get_bone_map(skeleton)
		if not bone_map:
			bone_map = SPA.create_bone_map(skeleton)
	if not bone_map or not bone_map.profile:
		return {}

	var remap := {}
	var profile := bone_map.profile

	for i in profile.bone_size:
		var profile_name := profile.get_bone_name(i)
		var skel_name := bone_map.get_skeleton_bone_name(profile_name)
		if skel_name.is_empty() or skel_name == profile_name:
			continue

		var bone_idx := skeleton.find_bone(skel_name)
		if bone_idx < 0:
			continue

		skeleton.set_bone_name(bone_idx, profile_name)
		remap[String(skel_name)] = String(profile_name)

	# Clear stale BoneMap metadata (bone names have changed)
	if skeleton.has_meta("bone_map"):
		skeleton.remove_meta("bone_map")
	if skeleton.has_meta("skeleton_type"):
		skeleton.remove_meta("skeleton_type")

	return remap


## Build a bone name remap dictionary from native names to profile names.
## Does NOT modify the skeleton — just computes the mapping.
## Returns: Dictionary { native_name: String -> profile_name: String }
static func build_remap(skeleton: Skeleton3D) -> Dictionary:
	if not skeleton:
		return {}

	var bone_map := SPA.get_bone_map(skeleton)
	if not bone_map:
		bone_map = SPA.create_bone_map(skeleton)
	if not bone_map or not bone_map.profile:
		return {}

	var remap := {}
	var profile := bone_map.profile

	for i in profile.bone_size:
		var profile_name := profile.get_bone_name(i)
		var skel_name := bone_map.get_skeleton_bone_name(profile_name)
		if skel_name.is_empty() or skel_name == profile_name:
			continue
		remap[String(skel_name)] = String(profile_name)

	return remap


# =============================================================================
# SKELETON CREATION
# =============================================================================

## Create a source skeleton for retargeting, copying structure from a reference.
## The reference should already have profile bone names (call rename_bones_to_profile first).
## custom_rest_poses: { profile_bone_name: String -> Transform3D } to override specific rest poses.
## Bones not in custom_rest_poses copy from the reference.
static func create_source_skeleton(
		reference: Skeleton3D,
		custom_rest_poses: Dictionary = {}) -> Skeleton3D:
	if not reference:
		return null

	var skeleton := Skeleton3D.new()
	skeleton.name = "SourceSkeleton"

	# Copy bone names
	for i in reference.get_bone_count():
		skeleton.add_bone(reference.get_bone_name(i))

	# Copy hierarchy
	for i in reference.get_bone_count():
		skeleton.set_bone_parent(i, reference.get_bone_parent(i))

	# Set rest poses
	for i in reference.get_bone_count():
		var bone_name := reference.get_bone_name(i)
		if bone_name in custom_rest_poses:
			skeleton.set_bone_rest(i, custom_rest_poses[bone_name])
		else:
			skeleton.set_bone_rest(i, reference.get_bone_rest(i))

	return skeleton


# =============================================================================
# MODIFIER CREATION
# =============================================================================

## Create a configured RetargetModifier3D.
## use_global_pose: false (default) handles different bone lengths/proportions.
##                  true requires equal bone lengths but works with unmatched bone counts.
static func create_modifier(use_global_pose: bool = false) -> RetargetModifier3D:
	var modifier := RetargetModifier3D.new()
	modifier.name = "RetargetModifier"
	modifier.profile = SPA.get_profile()
	modifier.use_global_pose = use_global_pose
	return modifier


# =============================================================================
# ANIMATION REMAPPING
# =============================================================================

## Remap bone names in animation track paths.
## name_map: { old_bone_name: String -> new_bone_name: String }
## Returns a new Animation with remapped tracks (original is not modified).
static func remap_animation(source: Animation, name_map: Dictionary) -> Animation:
	if not source or name_map.is_empty():
		return source

	var result := source.duplicate(true) as Animation

	for track_idx in result.get_track_count():
		var path := result.track_get_path(track_idx)

		# Bone tracks have the bone name as subname (after :)
		# Format: "path/to/Skeleton3D:BoneName"
		if path.get_subname_count() == 0:
			continue

		var bone_name := String(path.get_subname(0))
		if bone_name not in name_map:
			continue

		# Reconstruct path with new bone name, preserving node path and extra subnames
		var node_path := String(path.get_concatenated_names())
		var new_bone: String = name_map[bone_name]

		var subnames := new_bone
		for j in range(1, path.get_subname_count()):
			subnames += ":" + String(path.get_subname(j))

		result.track_set_path(track_idx, NodePath(node_path + ":" + subnames))

	return result


## Remap all animations in a library.
## Returns a new AnimationLibrary with remapped tracks (original is not modified).
static func remap_library(source: AnimationLibrary, name_map: Dictionary) -> AnimationLibrary:
	if not source or name_map.is_empty():
		return source

	var result := AnimationLibrary.new()
	for anim_name: String in source.get_animation_list():
		var remapped := remap_animation(source.get_animation(anim_name), name_map)
		result.add_animation(anim_name, remapped)

	return result


# =============================================================================
# CONVENIENCE — FULL SETUP
# =============================================================================

## Set up retargeting for a target skeleton to receive animations from a different source.
##
## target_skeleton: Character's skeleton (bones WILL be renamed to profile names)
## source_type: Skeleton type of the animation source
##
## Returns null if same skeleton type (no retargeting needed).
## Otherwise returns: {
##   "source_skeleton": Skeleton3D,
##   "modifier": RetargetModifier3D,
##   "target_remap": Dictionary,  # old target bone name -> profile name
## }
##
## NOTE: The hierarchy (source > modifier > target) is NOT assembled here.
## The caller must reparent target_skeleton under the modifier and add
## source_skeleton to the scene. This avoids destructive reparenting of
## already-scenetreed nodes.
static func setup_retargeting(
		target_skeleton: Skeleton3D,
		source_type: SPA.SkeletonType) -> Variant:
	if not target_skeleton or target_skeleton.get_bone_count() == 0:
		push_warning("RetargetSetup: Invalid target skeleton")
		return null

	var target_type := SPA.detect_skeleton_type(target_skeleton)
	if target_type == source_type:
		return null

	# Rename target bones to profile names
	var target_remap := rename_bones_to_profile(target_skeleton)

	# Create source skeleton (copies target structure with profile names)
	var source_skeleton := create_source_skeleton(target_skeleton)

	# Create modifier
	var modifier := create_modifier()

	return {
		"source_skeleton": source_skeleton,
		"modifier": modifier,
		"target_remap": target_remap,
	}
