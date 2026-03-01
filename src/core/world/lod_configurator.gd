## LODConfigurator - Helper for setting up native Godot visibility_range LOD
##
## This replaces the custom DistanceTierManager + ObjectStreamer tier system
## by using Godot 4.x native visibility_range properties.
##
## Native visibility_range gives us:
## - C++ engine-level distance culling (free, no GDScript overhead)
## - Built-in hysteresis via begin_margin/end_margin (no flickering)
## - Native fade modes (DEPENDENCIES mode blends between LODs)
##
## Usage:
##   var lod_config = LODConfigurator.new()
##   lod_config.configure_lod_chain(mesh_instance_lod0, mesh_instance_lod1, mesh_instance_lod2, impostor)
##   # Or for simple setup:
##   lod_config.configure_near_object(mesh_instance)
class_name LODConfigurator
extends RefCounted

const DU := preload("res://src/core/world/distance_utils.gd")

#region Distance Thresholds (from distance_utils.gd)

## NEAR tier: Full 3D meshes (0 to 150m)
const NEAR_END: float = DU.NEAR_END  # 150.0

## MID tier: LOD meshes (150m to 500m)
const MID_END: float = DU.MID_END  # 500.0

## FAR tier: Impostors (500m to 5000m)
const FAR_END: float = DU.FAR_END  # 5000.0

## Per-boundary crossfade margins (tiered: smaller at close range)
const FADE_NEAR_LOD1: float = DU.FADE_MARGIN_NEAR_LOD1  # 5.0
const FADE_LOD1_LOD2: float = DU.FADE_MARGIN_LOD1_LOD2  # 10.0
const FADE_LOD2_LOD3: float = DU.FADE_MARGIN_LOD2_LOD3  # 15.0
const FADE_LOD3_FAR: float = DU.FADE_MARGIN_LOD3_FAR    # 20.0

## Sub-LOD boundaries within MID tier
const LOD1_END: float = DU.LOD1_END
const LOD2_END: float = DU.LOD2_END
const LOD3_END: float = DU.LOD3_END

#endregion


#region Simple Configuration Methods

## Configure a NEAR-tier object (visible 0-150m, full detail)
## This is for the main LOD0 mesh that players see up close
func configure_near_object(mesh_instance: GeometryInstance3D) -> void:
	if not mesh_instance:
		return

	mesh_instance.visibility_range_begin = 0.0
	mesh_instance.visibility_range_end = NEAR_END
	mesh_instance.visibility_range_begin_margin = 0.0
	mesh_instance.visibility_range_end_margin = FADE_NEAR_LOD1
	mesh_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES


## Configure a MID-tier LOD mesh with specific LOD level
## lod_level: 1, 2, or 3
func configure_mid_object(mesh_instance: GeometryInstance3D, lod_level: int) -> void:
	if not mesh_instance:
		return

	var begin_dist: float
	var end_dist: float
	var begin_margin: float
	var end_margin: float

	match lod_level:
		1:
			begin_dist = NEAR_END
			end_dist = LOD1_END
			begin_margin = FADE_NEAR_LOD1
			end_margin = FADE_LOD1_LOD2
		2:
			begin_dist = LOD1_END
			end_dist = LOD2_END
			begin_margin = FADE_LOD1_LOD2
			end_margin = FADE_LOD2_LOD3
		3:
			begin_dist = LOD2_END
			end_dist = LOD3_END
			begin_margin = FADE_LOD2_LOD3
			end_margin = FADE_LOD3_FAR
		_:
			push_warning("[LODConfigurator] Invalid LOD level: %d" % lod_level)
			return

	mesh_instance.visibility_range_begin = begin_dist
	mesh_instance.visibility_range_end = end_dist
	mesh_instance.visibility_range_begin_margin = begin_margin
	mesh_instance.visibility_range_end_margin = end_margin
	mesh_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES


## Configure a FAR-tier impostor (visible 500m-5000m)
func configure_far_object(mesh_instance: GeometryInstance3D) -> void:
	if not mesh_instance:
		return

	mesh_instance.visibility_range_begin = MID_END
	mesh_instance.visibility_range_end = FAR_END
	mesh_instance.visibility_range_begin_margin = FADE_LOD3_FAR
	mesh_instance.visibility_range_end_margin = FADE_LOD3_FAR
	mesh_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED

#endregion


#region Full LOD Chain Configuration

## Configure a complete LOD chain from full detail to impostor
## This is the main method for significant objects (buildings, large trees, etc.)
##
## lod0: Full detail mesh (NEAR tier, 0-150m)
## lod1: First simplification (MID tier, 150-250m) - optional
## lod2: Second simplification (MID tier, 250-375m) - optional
## lod3: Third simplification (MID tier, 375-500m) - optional
## impostor: Billboard/octahedral impostor (FAR tier, 500-5000m) - optional
##
## Pass null for any LOD level to skip it
func configure_lod_chain(
	lod0: GeometryInstance3D,
	lod1: GeometryInstance3D = null,
	lod2: GeometryInstance3D = null,
	lod3: GeometryInstance3D = null,
	impostor: GeometryInstance3D = null
) -> void:
	# LOD0: Always required (the main mesh)
	if lod0:
		if lod1:
			# LOD0 transitions to LOD1 at NEAR_END
			lod0.visibility_range_begin = 0.0
			lod0.visibility_range_end = NEAR_END
			lod0.visibility_range_end_margin = FADE_NEAR_LOD1
			lod0.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES
		elif impostor:
			# No intermediate LODs, LOD0 transitions directly to impostor at MID_END
			lod0.visibility_range_begin = 0.0
			lod0.visibility_range_end = MID_END
			lod0.visibility_range_end_margin = FADE_LOD3_FAR
			lod0.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES
		else:
			# Just LOD0, visible until NEAR_END then gone
			lod0.visibility_range_begin = 0.0
			lod0.visibility_range_end = NEAR_END
			lod0.visibility_range_end_margin = FADE_NEAR_LOD1
			lod0.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF

	# LOD1: 150m - 250m (or to impostor/end if no LOD2)
	if lod1:
		lod1.visibility_range_begin = NEAR_END
		lod1.visibility_range_begin_margin = FADE_NEAR_LOD1

		if lod2:
			lod1.visibility_range_end = LOD1_END
			lod1.visibility_range_end_margin = FADE_LOD1_LOD2
		elif lod3:
			lod1.visibility_range_end = LOD2_END
			lod1.visibility_range_end_margin = FADE_LOD2_LOD3
		elif impostor:
			lod1.visibility_range_end = MID_END
			lod1.visibility_range_end_margin = FADE_LOD3_FAR
		else:
			lod1.visibility_range_end = MID_END
			lod1.visibility_range_end_margin = FADE_LOD3_FAR

		lod1.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES

	# LOD2: 250m - 375m
	if lod2:
		lod2.visibility_range_begin = LOD1_END
		lod2.visibility_range_begin_margin = FADE_LOD1_LOD2

		if lod3:
			lod2.visibility_range_end = LOD2_END
			lod2.visibility_range_end_margin = FADE_LOD2_LOD3
		elif impostor:
			lod2.visibility_range_end = MID_END
			lod2.visibility_range_end_margin = FADE_LOD3_FAR
		else:
			lod2.visibility_range_end = MID_END
			lod2.visibility_range_end_margin = FADE_LOD3_FAR

		lod2.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES

	# LOD3: 375m - 500m
	if lod3:
		lod3.visibility_range_begin = LOD2_END
		lod3.visibility_range_begin_margin = FADE_LOD2_LOD3
		lod3.visibility_range_end = LOD3_END
		lod3.visibility_range_end_margin = FADE_LOD3_FAR
		lod3.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES

	# Impostor: 500m - 5000m
	if impostor:
		impostor.visibility_range_begin = MID_END
		impostor.visibility_range_begin_margin = FADE_LOD3_FAR
		impostor.visibility_range_end = FAR_END
		impostor.visibility_range_end_margin = 0.0  # No fade at max distance, just disappear
		impostor.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES

#endregion


#region Simple Object Configuration

## Configure a simple object with no LOD chain (just visible in NEAR tier)
## Use for small clutter, grass, small rocks, etc.
func configure_simple_near(mesh_instance: GeometryInstance3D) -> void:
	configure_near_object(mesh_instance)


## Configure an object to transition from full mesh to impostor (no intermediate LODs)
## Use for trees, medium objects that don't need 3 LOD levels
func configure_mesh_to_impostor(
	mesh: GeometryInstance3D,
	impostor: GeometryInstance3D,
	mesh_end_distance: float = MID_END
) -> void:
	if mesh:
		mesh.visibility_range_begin = 0.0
		mesh.visibility_range_end = mesh_end_distance
		mesh.visibility_range_begin_margin = 0.0
		mesh.visibility_range_end_margin = FADE_LOD3_FAR
		mesh.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES

	if impostor:
		impostor.visibility_range_begin = mesh_end_distance
		impostor.visibility_range_begin_margin = FADE_LOD3_FAR
		impostor.visibility_range_end = FAR_END
		impostor.visibility_range_end_margin = 0.0
		impostor.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES


## Configure a MeshInstance3D with built-in LOD meshes (LOD0, LOD1, LOD2 in single mesh)
## Godot's automatic LOD system handles this differently - use visibility_range for manual control
func configure_auto_lod_mesh(mesh_instance: MeshInstance3D, max_distance: float = MID_END) -> void:
	if not mesh_instance:
		return
	
	# For meshes with built-in LODs, just set the overall visibility range
	# Godot handles LOD selection within that range based on screen size
	mesh_instance.visibility_range_begin = 0.0
	mesh_instance.visibility_range_end = max_distance
	mesh_instance.visibility_range_begin_margin = 0.0
	mesh_instance.visibility_range_end_margin = FADE_NEAR_LOD1
	mesh_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF

	# Let Godot's LOD bias control when to switch between built-in LODs
	mesh_instance.lod_bias = 1.0  # Default, adjust if needed

#endregion


#region Prebake Configuration

const MeshVisibilityUtils := preload("res://src/core/world/mesh_visibility_utils.gd")

## Configure visibility_range on all GeometryInstance3D nodes in a tree for prebaking.
## This bakes the values into the PackedScene so they don't need to be set at runtime.
## Call this BEFORE PackedScene.pack() during the prebaking step.
static func configure_for_prebake(root: Node) -> int:
	var configured := 0
	_configure_for_prebake_recursive(root, configured)
	return configured


## Recursively configure visibility_range on all geometry nodes
static func _configure_for_prebake_recursive(node: Node, count: int) -> int:
	if node is GeometryInstance3D:
		var geo := node as GeometryInstance3D
		var node_name := node.name

		if MeshVisibilityUtils.is_lod_node_name(node_name):
			var lod_level := _get_lod_level_static(node_name)
			_configure_mid_static(geo, lod_level)
			count += 1
		else:
			_configure_near_static(geo)
			count += 1

	for child in node.get_children():
		count = _configure_for_prebake_recursive(child, count)

	return count


## Static version of configure_near_object (no instance needed)
static func _configure_near_static(mesh_instance: GeometryInstance3D) -> void:
	mesh_instance.visibility_range_begin = 0.0
	mesh_instance.visibility_range_end = DU.NEAR_END
	mesh_instance.visibility_range_begin_margin = 0.0
	mesh_instance.visibility_range_end_margin = DU.FADE_MARGIN_NEAR_LOD1
	mesh_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES


## Static version of configure_mid_object (no instance needed)
static func _configure_mid_static(mesh_instance: GeometryInstance3D, lod_level: int) -> void:
	var begin_dist: float
	var end_dist: float
	var begin_margin: float
	var end_margin: float

	match lod_level:
		1:
			begin_dist = DU.NEAR_END
			end_dist = DU.LOD1_END
			begin_margin = DU.FADE_MARGIN_NEAR_LOD1
			end_margin = DU.FADE_MARGIN_LOD1_LOD2
		2:
			begin_dist = DU.LOD1_END
			end_dist = DU.LOD2_END
			begin_margin = DU.FADE_MARGIN_LOD1_LOD2
			end_margin = DU.FADE_MARGIN_LOD2_LOD3
		3:
			begin_dist = DU.LOD2_END
			end_dist = DU.LOD3_END
			begin_margin = DU.FADE_MARGIN_LOD2_LOD3
			end_margin = DU.FADE_MARGIN_LOD3_FAR
		_:
			return

	mesh_instance.visibility_range_begin = begin_dist
	mesh_instance.visibility_range_end = end_dist
	mesh_instance.visibility_range_begin_margin = begin_margin
	mesh_instance.visibility_range_end_margin = end_margin
	mesh_instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES


## Get LOD level from node name (static version)
static func _get_lod_level_static(node_name: String) -> int:
	var name_lower := node_name.to_lower()
	if "_lod1" in name_lower:
		return 1
	elif "_lod2" in name_lower:
		return 2
	elif "_lod3" in name_lower:
		return 3
	return 1

#endregion


#region Utility Methods

## Get the tier name for a given distance
static func get_tier_for_distance(distance: float) -> String:
	if distance < NEAR_END:
		return "NEAR"
	elif distance < MID_END:
		return "MID"
	elif distance < FAR_END:
		return "FAR"
	else:
		return "HIDDEN"


## Check if an object would be visible at a given distance
static func is_visible_at_distance(mesh_instance: GeometryInstance3D, distance: float) -> bool:
	if not mesh_instance:
		return false
	
	var begin := mesh_instance.visibility_range_begin
	var end := mesh_instance.visibility_range_end
	
	# Account for margins
	var begin_margin := mesh_instance.visibility_range_begin_margin
	var end_margin := mesh_instance.visibility_range_end_margin
	
	# Visible in the range [begin - begin_margin, end + end_margin]
	return distance >= (begin - begin_margin) and distance <= (end + end_margin)


## Print debug info about a mesh's visibility configuration
static func debug_print_config(mesh_instance: GeometryInstance3D, name: String = "") -> void:
	if not mesh_instance:
		Log.debug("streaming", "[LODConfigurator] %s: null" % name)
		return

	var label := name if name else str(mesh_instance.get_instance_id())
	Log.debug("streaming", "[LODConfigurator] %s:" % label)
	Log.debug("streaming", "  visibility_range_begin: %.1f" % mesh_instance.visibility_range_begin)
	Log.debug("streaming", "  visibility_range_end: %.1f" % mesh_instance.visibility_range_end)
	Log.debug("streaming", "  visibility_range_begin_margin: %.1f" % mesh_instance.visibility_range_begin_margin)
	Log.debug("streaming", "  visibility_range_end_margin: %.1f" % mesh_instance.visibility_range_end_margin)
	Log.debug("streaming", "  visibility_range_fade_mode: %d" % mesh_instance.visibility_range_fade_mode)

#endregion
