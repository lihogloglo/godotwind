## Door Portal — Stencil-based portal rendering through doorways
##
## Places an invisible stencil-write plane at the door opening. Interior pocket
## materials use stencil-read so they only render where the stencil matches —
## producing a "window" into the interior at full native resolution.
##
## The main camera's cull_mask is temporarily expanded to include interior layers
## when a portal is active. Stencil masking ensures interior geometry is only
## visible through the doorframe.
##
## Phase 1: outside-looking-in only. One active portal at a time.
##
## Usage (managed by InteriorPocketManager):
##   var portal := DoorPortal.new()
##   portal.activate(door_info, pocket_slot, main_camera, scene_root)
##   # Each frame:
##   portal.update(main_camera)
##   # When done:
##   portal.deactivate()
class_name DoorPortal
extends RefCounted

const CS := preload("res://src/core/coordinate_system.gd")
const DoorUtils := preload("res://src/core/world/door_utils.gd")
const DOOR_CLIP_SHADER := preload("res://src/core/world/shaders/door_clip.gdshader")

#region Constants

## Default portal plane size (meters) — generous, doorframe masks the overshoot
const DEFAULT_PORTAL_WIDTH: float = 1.8
const DEFAULT_PORTAL_HEIGHT: float = 2.5

## Portal activation/deactivation range
const PORTAL_RANGE: float = 20.0
const PORTAL_RANGE_SQ: float = PORTAL_RANGE * PORTAL_RANGE

## Render layers (must match InteriorPocketManager)
const EXTERIOR_RENDER_LAYERS: int = 0x3  # Layers 1-2
const INTERIOR_RENDER_LAYERS: int = 0xC  # Layers 3-4
const COMBINED_RENDER_LAYERS: int = 0xF  # Layers 1-4 (exterior + interior)

## Stencil reference value for this portal
const STENCIL_REF: int = 1

## Dim factor applied to interior materials visible through the stencil portal.
## Darkens the preview to simulate a dark interior and mask depth sorting artifacts
## (no_depth_test breaks inter-object sorting). Interior lightbox provides dark
## backdrop behind gaps, so we can use moderate dimming (0.5 vs old 0.35).
## 0.0 = black, 1.0 = full brightness.
const PORTAL_DIM_FACTOR: float = 0.5

## Stencil API integer constants (from Godot 4.6 BaseMaterial3D property hints)
## stencil_mode: 0=Disabled, 1=Outline, 2=X-Ray, 3=Custom
## stencil_flags (bitmask): 1=Read, 2=Write, 4=Write Depth Fail
## stencil_compare: 0=Always, 1=Less, 2=Equal, 3=LessOrEqual, 4=Greater, 5=NotEqual, 6=GreaterOrEqual
const _SM_CUSTOM: int = 3
const _SM_DISABLED: int = 0
const _SF_READ: int = 1
const _SF_WRITE: int = 2
const _SC_EQUAL: int = 2

#endregion

#region State

## Whether the portal is currently active (rendering)
var is_active: bool = false

## The door this portal is rendering through
var _door_info: Variant = null  # InteriorPocketManager.DoorInfo

## Pocket slot being rendered
var _pocket_slot: Variant = null  # InteriorPocketManager.PocketSlot

## The stencil-write plane placed at the door opening
var _stencil_plane: MeshInstance3D = null

## Scene root (for adding portal nodes)
var _scene_root: Node = null

## Main camera reference (for cull_mask management)
var _main_camera: Camera3D = null

## Door position in world space
var _door_exterior_pos: Vector3 = Vector3.ZERO
var _door_exterior_basis: Basis = Basis.IDENTITY

## Computed portal plane position and forward direction (single source of truth).
## Set during _create_stencil_plane(). Used by InteriorPocketManager for
## walk-through detection so the trigger plane matches the visual portal exactly.
var portal_plane_position: Vector3 = Vector3.ZERO
var portal_plane_forward: Vector3 = Vector3.FORWARD

## Container node for portal nodes (easy cleanup)
var _portal_container: Node3D = null

## Original materials on interior geometry (for restoring stencil-read on deactivate)
## Maps key -> original material (or null if none)
var _modified_materials: Dictionary = {}

## Whether we've applied stencil-read to interior materials
var _stencil_applied: bool = false

## Original pocket transform (restored on deactivate)
var _pocket_original_pos: Vector3 = Vector3.ZERO
var _pocket_original_basis: Basis = Basis.IDENTITY

## Exterior door mesh hidden during portal (restored on deactivate)
var _hidden_exterior_door: Node3D = null

## Interior door meshes hidden during portal (restored on deactivate)
var _hidden_interior_doors: Array[Node3D] = []

## Meshes hidden due to incompatible materials (ShaderMaterial/null — can't apply stencil-read)
var _hidden_no_stencil: Array[Node3D] = []

## Debug visualization nodes (cleaned up on deactivate)
var _debug_nodes: Array[Node3D] = []
var _debug_enabled: bool = false

## Interior lights with expanded cull_mask during portal (restored on deactivate)
## Maps Light3D instance_id -> original light_cull_mask
var _expanded_lights: Dictionary = {}

## Exterior meshes with clip shader applied (restored on deactivate)
## Maps MeshInstance3D instance_id -> {mi: MeshInstance3D, original_override: Material, surface_mats: Array}
var _clipped_meshes: Dictionary = {}

#endregion

#region Activation

## Activate the portal for a specific door and pocket
func activate(door_info: Variant, pocket_slot: Variant,
			main_camera: Camera3D, scene_root: Node) -> void:
	if is_active:
		deactivate()

	_door_info = door_info
	_pocket_slot = pocket_slot
	_scene_root = scene_root
	_main_camera = main_camera

	_door_exterior_pos = door_info.world_position
	_door_exterior_basis = door_info.get_door_basis_godot()

	# Create container
	_portal_container = Node3D.new()
	_portal_container.name = "StencilPortal_%s" % str(door_info.ref_id)
	scene_root.add_child(_portal_container)

	# Reposition pocket so interior aligns with the door in world space.
	# The interior is normally at Y=-500 (out of frustum). Move it so the
	# interior exit door aligns with the exterior door position.
	# Stencil masking ensures interior is only visible through the doorframe.
	_reposition_pocket_to_door(pocket_slot, door_info)

	# Create stencil-write plane at door opening
	_create_stencil_plane()

	# Apply stencil-read to interior pocket materials
	_apply_stencil_read_to_pocket(pocket_slot)

	# Hide exterior door mesh — it blocks the stencil view into the interior
	_hide_exterior_door(door_info)

	# Apply clip shader to exterior wall meshes near the door.
	# Punches a depth-buffer hole in the building wall at the door opening,
	# so interior objects can use normal depth testing (no_depth_test=false).
	_apply_wall_clip()

	# Hide interior door meshes near the door opening — they block the view
	# through the stencil when the pocket is repositioned behind the exterior door
	_hide_interior_doors(pocket_slot, door_info)

	# Expand camera cull_mask to include interior layers
	if _main_camera:
		_main_camera.cull_mask = COMBINED_RENDER_LAYERS

	# Expand interior lights to illuminate combined layers so they're visible
	# through the stencil portal (otherwise exterior ambient overpowers them)
	_expand_interior_lights(pocket_slot)

	is_active = true
	Log.info("streaming", "Stencil portal activated: '%s' at %s (pocket moved from Y=%.0f to Y=%.0f)" % [
		door_info.target_cell_name, _door_exterior_pos,
		_pocket_original_pos.y, pocket_slot.cell_node.position.y])


## Deactivate and clean up
## keep_pocket_position: if true, do NOT restore pocket to Y=-500 offset.
## Used by seamless walk-through transitions where the player is physically
## inside the door-aligned pocket and it must stay in place.
func deactivate(keep_pocket_position: bool = false) -> void:
	if not is_active:
		return

	# Restore camera to exterior-only layers (skip during seamless transition —
	# the caller manages the camera cull_mask)
	if not keep_pocket_position:
		if _main_camera and is_instance_valid(_main_camera):
			_main_camera.cull_mask = EXTERIOR_RENDER_LAYERS

	# Remove stencil-read from interior materials
	_remove_stencil_read_from_pocket()

	# Restore meshes hidden due to incompatible materials
	_restore_no_stencil_meshes()

	# Restore clipped exterior wall meshes
	_restore_wall_clip()

	# Restore hidden exterior door
	_restore_exterior_door()

	# Restore hidden interior doors
	_restore_interior_doors()

	# Restore interior light cull masks (skip during seamless transition —
	# lights must stay on COMBINED layers while player sees both worlds)
	if not keep_pocket_position:
		_restore_interior_lights()

	# Clean up debug nodes
	_clear_debug_nodes()

	# Move pocket back to its original offset position (unless seamless transition)
	if not keep_pocket_position:
		_restore_pocket_position()

	# Clean up stencil plane and depth-clear plane
	if _portal_container and is_instance_valid(_portal_container):
		_portal_container.queue_free()
	_portal_container = null
	_stencil_plane = null
	_door_info = null
	_pocket_slot = null

	is_active = false
	Log.info("streaming", "Stencil portal deactivated")

#endregion

#region Stencil Plane

## Create the stencil-write plane at the door opening
## This invisible plane writes a stencil value wherever it covers pixels.
## Interior geometry with stencil-read only renders where this value is set.
func _create_stencil_plane() -> void:
	_stencil_plane = MeshInstance3D.new()
	_stencil_plane.name = "StencilWritePlane"

	# Size from door AABB or defaults
	# Door AABB has 3 dimensions: thickness (thinnest), width, height.
	# The two largest are the door opening size.
	var portal_size := Vector2(DEFAULT_PORTAL_WIDTH, DEFAULT_PORTAL_HEIGHT)
	var door_mesh: MeshInstance3D = DoorUtils.find_door_mesh(_scene_root, _door_info.ref_id, _door_exterior_pos, 10.0)
	if door_mesh and door_mesh.mesh:
		var aabb: AABB = door_mesh.mesh.get_aabb()
		var sizes: Array[float] = [aabb.size.x, aabb.size.y, aabb.size.z]
		sizes.sort()
		# sizes[0] = thickness (thinnest), sizes[1] = width, sizes[2] = height
		# MW door meshes are smaller than the door OPENING (panel doesn't fill
		# the full doorframe). Use defaults as minimum — the doorframe masks overshoot.
		var quad_width: float = maxf(sizes[1], DEFAULT_PORTAL_WIDTH)
		var quad_height: float = maxf(sizes[2], DEFAULT_PORTAL_HEIGHT)
		if quad_width > 0.1 and quad_height > 0.1:
			portal_size = Vector2(quad_width, quad_height)
		Log.debug("streaming", "Stencil plane sized from AABB: %.2f x %.2f (raw: %s)" % [
			quad_width, quad_height, aabb.size])

	# Create quad mesh for stencil writing
	var quad := QuadMesh.new()
	quad.size = portal_size
	_stencil_plane.mesh = quad

	# Stencil-write material: nearly invisible but writes stencil value.
	# Must NOT be fully transparent (alpha=0) — that gets discarded before stencil write.
	# Exterior wall meshes near the door have clip shader applied (door-shaped hole
	# in the depth buffer), so the stencil plane uses normal depth testing — it's
	# only visible through the clipped hole, not through barrels/signs/characters.
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0, 0, 0, 0.01)  # Near-invisible but not discarded
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true  # Write stencil THROUGH walls (MW buildings are solid boxes)
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED  # Don't write to depth buffer
	mat.render_priority = -10  # Render FIRST in alpha queue (lower = earlier)

	# Stencil write settings
	mat.stencil_mode = _SM_CUSTOM
	mat.stencil_flags = _SF_WRITE
	mat.stencil_reference = STENCIL_REF

	_stencil_plane.material_override = mat

	# Position: center the stencil plane on the door opening.
	# Use the door mesh's global position as center if available (accounts for NIF offset).
	# Otherwise fall back to ESM door position + half height.
	var plane_basis: Basis = _compute_portal_plane_basis(door_mesh)
	var plane_center: Vector3
	if door_mesh:
		# Door mesh center = actual visual center of the door
		var mesh_aabb: AABB = door_mesh.mesh.get_aabb() if door_mesh.mesh else AABB()
		var aabb_center_local: Vector3 = mesh_aabb.get_center()
		plane_center = door_mesh.global_transform * aabb_center_local
	else:
		plane_center = _door_exterior_pos + Vector3(0, portal_size.y * 0.5, 0)
	# Push the plane slightly TOWARD the camera (forward from wall) so it's not
	# occluded by the wall surface. The stencil plane must be visible to write.
	var plane_forward: Vector3 = -plane_basis.z
	var forward_offset: Vector3 = plane_forward.normalized() * 0.1
	_stencil_plane.position = plane_center + forward_offset
	_stencil_plane.basis = plane_basis

	# Store computed position/forward for walk-through detection (single source of truth).
	# portal_plane_forward = outward from wall (positive = exterior side), matching
	# DoorUtils.get_door_forward() convention. plane_basis.z = outward (from
	# Basis.looking_at(-normal) convention where -Z = -normal, so Z = normal = outward).
	portal_plane_position = plane_center
	portal_plane_forward = plane_basis.z.normalized()

	Log.debug("streaming", "Stencil plane pos=%s, center=%s, forward=%s, size=%s" % [
		_stencil_plane.position, plane_center, plane_forward, portal_size])

	# Visible on exterior layers (main camera sees it for stencil writing)
	_stencil_plane.layers = EXTERIOR_RENDER_LAYERS

	# Double-sided so stencil works from both approach directions
	_stencil_plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	_portal_container.add_child(_stencil_plane)

#endregion

#region Pocket Repositioning

## Move the pocket's cell_node so the interior doorway aligns with the exterior door.
##
## Alignment strategy:
##   1. Find the interior EXIT door (leads back outside) whose teleport lands
##      near the exterior door — this is the same physical doorway from inside.
##   2. Use the exit door's cell-local position as the alignment point.
##   3. Fallback to teleport_pos (player arrival) if no matching exit door found.
func _reposition_pocket_to_door(pocket_slot: Variant, door_info: Variant) -> void:
	if not pocket_slot.cell_node or not is_instance_valid(pocket_slot.cell_node):
		return

	_pocket_original_pos = pocket_slot.cell_node.position
	_pocket_original_basis = pocket_slot.cell_node.basis

	# Find matching interior exit door for precise alignment
	var exit_door: Variant = _find_interior_exit_door(pocket_slot, door_info)
	var align_pos: Vector3

	if exit_door:
		# Use exit door's cell-local position (strip pocket offset) for POSITION.
		var pocket_offset: Vector3 = pocket_slot.get_offset()
		align_pos = exit_door.world_position - pocket_offset
		Log.info("streaming", "Aligned on interior exit door '%s' (cell-local pos=%s)" % [
			exit_door.ref_id, align_pos])
	else:
		# Fallback: use teleport destination (player arrival point, ~1-2m inside)
		align_pos = door_info.get_teleport_pos_godot()
		Log.warn("streaming", "No matching interior exit door found for '%s' — using teleport_pos fallback (may be offset)" % door_info.target_cell_name)

	# Rotation: align interior exit door outward direction with exterior door outward direction.
	# Uses mesh geometry (AABB thinnest axis) instead of ESM teleport rotation data,
	# which is unreliable (mixes door mesh rotation with player arrival facing).
	var rotation_delta: Basis = _compute_alignment_rotation(pocket_slot, exit_door, door_info)
	pocket_slot.cell_node.basis = rotation_delta

	# Position: after rotation, the alignment point has moved.
	# New align world pos = rotation_delta * align_pos + pocket_pos
	# We want that to equal door_exterior_pos:
	# pocket_pos = door_exterior_pos - rotation_delta * align_pos
	var aligned_pos: Vector3 = _door_exterior_pos - rotation_delta * align_pos
	pocket_slot.cell_node.position = aligned_pos

	Log.info("streaming", "Pocket repositioned: pos %s -> %s, match=%s, rotation_euler=%s" % [
		_pocket_original_pos, aligned_pos,
		"exit_door" if exit_door else "teleport_fallback",
		rotation_delta.get_euler() * (180.0 / PI)])


## Find the interior exit door that corresponds to this exterior door.
## An exit door has empty target_cell_name (leads to exterior) and its
## teleport_pos (where the player arrives outside) should be near the
## exterior door's world_position.
## Returns the matching DoorInfo or null.
func _find_interior_exit_door(pocket_slot: Variant, door_info: Variant) -> Variant:
	var doors_inside: Array = pocket_slot.doors_inside
	if doors_inside.is_empty():
		return null

	var exterior_door_godot: Vector3 = door_info.world_position
	var best_door: Variant = null
	var best_dist_sq: float = INF

	for int_door: Variant in doors_inside:
		# Only consider exterior exit doors (empty target_cell_name)
		if not int_door.target_cell_name.is_empty():
			continue

		# The exit door's teleport_pos is where the player arrives in the exterior.
		# Match it against the exterior door's world_position.
		var exit_teleport_godot: Vector3 = CS.vector_to_godot(int_door.teleport_pos_mw)
		var dist_sq: float = exit_teleport_godot.distance_squared_to(exterior_door_godot)
		if dist_sq < best_dist_sq:
			best_dist_sq = dist_sq
			best_door = int_door

	if best_door == null:
		Log.warn("streaming", "Exit door match: NO exterior exit doors found in %d interior doors" % doors_inside.size())
		return null

	var match_dist: float = sqrt(best_dist_sq)
	Log.info("streaming", "Exit door match: '%s' (dist=%.1fm, teleport=%s, door_pos=%s)" % [
		best_door.ref_id, match_dist,
		CS.vector_to_godot(best_door.teleport_pos_mw), exterior_door_godot])

	# Warn if the match is suspiciously far (> 5m)
	if best_dist_sq > 25.0:
		Log.warn("streaming", "Interior exit door teleport_pos is %.1fm from exterior door — alignment may be imprecise" % match_dist)

	return best_door


## Compute the rotation that aligns the interior exit door's outward direction
## with the exterior door's outward direction.
##
## Strategy (geometry-based, no dependency on ESM teleport rotation):
##   1. Find the interior exit door MESH in the pocket (after cell load)
##   2. Compute its wall normal from AABB thinnest axis
##   3. Compute the exterior door's wall normal similarly
##   4. Build rotation from interior-outward → exterior-outward
##
## Fallback: if meshes not found, use ESM teleport rotation (old behavior).
func _compute_alignment_rotation(pocket_slot: Variant, exit_door: Variant, door_info: Variant) -> Basis:
	# --- Try geometry-based alignment (robust) ---
	var interior_forward: Vector3 = Vector3.ZERO
	var exterior_forward: Vector3 = -_door_exterior_basis.z  # Default from ESM

	# 1. Compute exterior door outward direction from mesh geometry
	var ext_door_mesh: MeshInstance3D = DoorUtils.find_door_mesh(
		_scene_root, door_info.ref_id, _door_exterior_pos, 10.0)
	var ext_basis: Basis = DoorUtils.compute_door_basis(
		_door_exterior_basis, ext_door_mesh, _main_camera, _door_exterior_pos)
	exterior_forward = -ext_basis.z  # -Z is outward from wall
	exterior_forward.y = 0.0
	if exterior_forward.length_squared() > 0.01:
		exterior_forward = exterior_forward.normalized()
	else:
		exterior_forward = Vector3(0, 0, -1)
	# Diagnostic: exterior door AABB
	if ext_door_mesh and ext_door_mesh.mesh:
		var ea: AABB = ext_door_mesh.mesh.get_aabb()
		var es: Array[float] = [ea.size.x, ea.size.y, ea.size.z]
		es.sort()
		var ratio: float = es[0] / es[1] if es[1] > 0.001 else 0.0
		Log.info("streaming", "  EXT door AABB: sizes=[%.2f, %.2f, %.2f] sorted=[%.2f, %.2f, %.2f] ratio=%.2f mesh='%s'" % [
			ea.size.x, ea.size.y, ea.size.z, es[0], es[1], es[2], ratio, ext_door_mesh.name])
	else:
		Log.warn("streaming", "  EXT door mesh NOT FOUND for '%s'" % door_info.ref_id)

	# 2. Compute interior exit door outward direction
	if exit_door and pocket_slot.cell_node and is_instance_valid(pocket_slot.cell_node):
		var pocket_offset: Vector3 = pocket_slot.get_offset()
		var exit_local_pos: Vector3 = exit_door.world_position - pocket_offset
		var exit_esm_basis: Basis = CS.esm_rotation_to_godot_basis(exit_door.door_rotation_mw)
		# Try mesh geometry first (most reliable when found)
		var int_door_mesh: MeshInstance3D = DoorUtils.find_door_mesh(
			pocket_slot.cell_node, exit_door.ref_id, exit_local_pos, 10.0)
		var int_basis: Basis
		if int_door_mesh:
			int_basis = DoorUtils.compute_door_basis(exit_esm_basis, int_door_mesh, null, exit_local_pos)
			var ia: AABB = int_door_mesh.mesh.get_aabb() if int_door_mesh.mesh else AABB()
			Log.info("streaming", "  INT door: mesh found '%s', AABB=%s" % [int_door_mesh.name, ia.size])
		else:
			# Mesh not found — use full ESM rotation pipeline directly.
			# The -Z of the converted basis IS the door's forward direction in
			# Godot space. No euler decomposition (avoids gimbal lock risk).
			int_basis = CS.esm_rotation_to_godot_basis(exit_door.door_rotation_mw)
			Log.info("streaming", "  INT door: mesh NOT FOUND, using ESM basis -Z=%s (door_rot_mw=%s)" % [
				-int_basis.z, exit_door.door_rotation_mw])
		interior_forward = -int_basis.z  # -Z is outward from wall
		interior_forward.y = 0.0
		if interior_forward.length_squared() > 0.01:
			interior_forward = interior_forward.normalized()
		else:
			interior_forward = Vector3.ZERO  # Signal failure

	# 3. Build rotation from interior-outward → exterior-outward
	if interior_forward.length_squared() > 0.5 and exterior_forward.length_squared() > 0.5:
		# Both directions valid — compute Y-axis rotation between them.
		# Interior exit door outward (-Z of its basis) points INTO the room (away from wall).
		# Exterior door outward (-Z of its basis) points INTO the street (away from building).
		# Through the same physical wall, these point in OPPOSITE directions.
		# When aligned correctly, the interior exit outward should face TOWARD the exterior
		# (antiparallel to exterior_forward). So we negate interior_forward first.
		var int_toward_exterior: Vector3 = -interior_forward
		# We want: rotation_delta * int_toward_exterior = exterior_forward
		var angle: float = int_toward_exterior.signed_angle_to(exterior_forward, Vector3.UP)
		var rotation_delta: Basis = Basis(Vector3.UP, angle)
		Log.info("streaming", "Alignment: geometry-based rotation (angle=%.1f°, int_fwd=%s → negated=%s, ext_fwd=%s)" % [
			rad_to_deg(angle), interior_forward, int_toward_exterior, exterior_forward])
		return rotation_delta

	# --- Fallback: ESM teleport rotation (old behavior, less reliable) ---
	var align_basis: Basis = door_info.get_teleport_basis_godot()
	var rotation_delta: Basis = _door_exterior_basis * align_basis.inverse()
	var euler: Vector3 = rotation_delta.get_euler() * (180.0 / PI)
	Log.warn("streaming", "Alignment: FALLBACK to ESM teleport rotation (euler=%s, door_basis=%s, teleport_basis=%s)" % [
		euler, _door_exterior_basis, align_basis])
	return rotation_delta


## Hide the exterior door mesh so it doesn't block the stencil view
func _hide_exterior_door(door_info: Variant) -> void:
	_hidden_exterior_door = null
	var door_node: Node3D = DoorUtils.find_by_ref_id(
		_scene_root, door_info.ref_id, door_info.world_position, 10.0)
	if not door_node:
		door_node = DoorUtils.find_near(_scene_root, door_info.world_position, 5.0)
	if door_node and door_node.visible:
		door_node.visible = false
		_hidden_exterior_door = door_node
		Log.debug("streaming", "Hidden exterior door '%s' for portal" % door_node.name)


## Restore hidden exterior door
func _restore_exterior_door() -> void:
	if _hidden_exterior_door and is_instance_valid(_hidden_exterior_door):
		_hidden_exterior_door.visible = true
	_hidden_exterior_door = null


#region Wall Clipping

## Apply clip shader to exterior wall meshes near the door.
## Finds meshes within clip radius, replaces their materials with a clip shader
## version that discards fragments inside the portal rectangle.
## This creates a "hole" in the depth buffer where the door is, allowing interior
## objects to use normal depth testing.
func _apply_wall_clip() -> void:
	_clipped_meshes.clear()
	if not _stencil_plane:
		return

	# Clip box parameters from the stencil plane
	var clip_center: Vector3 = _stencil_plane.position
	var clip_basis: Basis = _stencil_plane.basis
	var portal_size: Vector2 = (_stencil_plane.mesh as QuadMesh).size if _stencil_plane.mesh is QuadMesh else Vector2(DEFAULT_PORTAL_WIDTH, DEFAULT_PORTAL_HEIGHT)

	# Half-extents in stencil plane local space:
	# X = door width (along basis X), Y = door height (along basis Y),
	# Z = through wall thickness (along basis Z = wall normal direction)
	var clip_half_extents := Vector3(portal_size.x * 0.5, portal_size.y * 0.5, 0.5)

	# Inverse rotation for the clip box (world → clip local space)
	var clip_rotation_inv: Basis = clip_basis.inverse()

	# Find and clip exterior meshes near the door
	var clip_radius: float = 5.0
	_clip_meshes_recursive(_scene_root, clip_center, clip_radius,
		clip_half_extents, clip_rotation_inv)

	Log.info("streaming", "Wall clip: applied to %d meshes near door (radius=%.1fm, clip_box=%s)" % [
		_clipped_meshes.size(), clip_radius, clip_half_extents * 2.0])


func _clip_meshes_recursive(node: Node, clip_center: Vector3, radius: float,
		clip_half_extents: Vector3, clip_rotation_inv: Basis, depth: int = 0) -> void:
	if depth > 6:
		return
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		# Skip non-exterior layers, already-hidden nodes, portal nodes
		if not mi.visible or mi == _stencil_plane:
			return
		if mi.layers & EXTERIOR_RENDER_LAYERS == 0:
			return
		# Skip if it's the hidden door or its children
		if _hidden_exterior_door and _is_child_of(_hidden_exterior_door, mi):
			return
		# Check distance OR AABB intersection — large building walls may have their
		# origin far from the door but their geometry covers the door area.
		var in_range: bool = mi.global_position.distance_to(clip_center) <= radius
		if not in_range and mi.mesh:
			var world_aabb: AABB = mi.global_transform * mi.mesh.get_aabb()
			var door_box := AABB(clip_center - Vector3(radius, radius, radius),
				Vector3(radius * 2.0, radius * 2.0, radius * 2.0))
			in_range = world_aabb.intersects(door_box)
		if in_range:
			_apply_clip_to_mesh(mi, clip_center, clip_half_extents, clip_rotation_inv)
	for child in node.get_children():
		_clip_meshes_recursive(child, clip_center, radius,
			clip_half_extents, clip_rotation_inv, depth + 1)


func _is_child_of(parent: Node, child: Node) -> bool:
	var p: Node = child
	while p:
		if p == parent:
			return true
		p = p.get_parent()
	return false


## Apply clip shader to a single MeshInstance3D.
## Handles multi-surface meshes: applies per-surface clip materials instead of
## material_override when the mesh has multiple surfaces (MW buildings have
## wood, stone, plaster on different surfaces).
func _apply_clip_to_mesh(mi: MeshInstance3D, clip_center: Vector3,
		clip_half_extents: Vector3, clip_rotation_inv: Basis) -> void:
	var iid: int = mi.get_instance_id()
	if _clipped_meshes.has(iid):
		return  # Already clipped

	if not mi.mesh:
		return

	var surface_count: int = mi.mesh.get_surface_count()

	# If material_override is set, apply clip as override (replaces all surfaces)
	if mi.material_override:
		_clipped_meshes[iid] = {
			"mi": mi,
			"original_override": mi.material_override,
			"surface_mats": [],
		}
		var clip_mat: ShaderMaterial = _create_clip_material(
			mi.material_override, clip_center, clip_half_extents, clip_rotation_inv)
		mi.material_override = clip_mat
		return

	# Multi-surface path: create a separate clip material per surface
	var original_surface_mats: Array = []
	for surf_idx in surface_count:
		original_surface_mats.append(mi.get_surface_override_material(surf_idx))

	_clipped_meshes[iid] = {
		"mi": mi,
		"original_override": null,
		"surface_mats": original_surface_mats,
	}

	for surf_idx in surface_count:
		var source_mat: Material = mi.get_active_material(surf_idx)
		var clip_mat: ShaderMaterial = _create_clip_material(
			source_mat, clip_center, clip_half_extents, clip_rotation_inv)
		mi.set_surface_override_material(surf_idx, clip_mat)

	Log.debug("streaming", "Clipped exterior mesh: '%s' (%d surfaces, dist=%.1fm)" % [
		mi.name, surface_count, mi.global_position.distance_to(clip_center)])


## Create a clip ShaderMaterial from a source material, copying its visual properties.
static func _create_clip_material(source_mat: Material, clip_center: Vector3,
		clip_half_extents: Vector3, clip_rotation_inv: Basis) -> ShaderMaterial:
	var clip_mat := ShaderMaterial.new()
	clip_mat.shader = DOOR_CLIP_SHADER
	clip_mat.set_shader_parameter("clip_center", clip_center)
	clip_mat.set_shader_parameter("clip_half_extents", clip_half_extents)
	clip_mat.set_shader_parameter("clip_rotation_inv", clip_rotation_inv)

	if source_mat is StandardMaterial3D:
		var std: StandardMaterial3D = source_mat as StandardMaterial3D
		clip_mat.set_shader_parameter("albedo_color", std.albedo_color)
		clip_mat.set_shader_parameter("roughness", std.roughness)
		clip_mat.set_shader_parameter("metallic", std.metallic)
		if std.albedo_texture:
			clip_mat.set_shader_parameter("albedo_texture", std.albedo_texture)
		if std.normal_enabled and std.normal_texture:
			clip_mat.set_shader_parameter("has_normal", true)
			clip_mat.set_shader_parameter("normal_texture", std.normal_texture)
			clip_mat.set_shader_parameter("normal_scale", std.normal_scale)

	return clip_mat


## Restore original materials on clipped exterior meshes
func _restore_wall_clip() -> void:
	for iid: int in _clipped_meshes:
		var entry: Dictionary = _clipped_meshes[iid]
		var mi: MeshInstance3D = entry.mi as MeshInstance3D
		if mi and is_instance_valid(mi):
			mi.material_override = entry.original_override
			var surface_mats: Array = entry.surface_mats
			for surf_idx in surface_mats.size():
				mi.set_surface_override_material(surf_idx, surface_mats[surf_idx])
	_clipped_meshes.clear()


#endregion

## Hide interior door meshes near the door opening
## After repositioning, the interior's entry door sits at the same position as
## the exterior door — blocking the stencil view. Hide it.
## Uses math-based position check (not global_position) because Godot's transform
## propagation may not have run yet after _reposition_pocket_to_door().
func _hide_interior_doors(pocket_slot: Variant, door_info: Variant) -> void:
	_hidden_interior_doors.clear()
	if not pocket_slot.cell_node or not is_instance_valid(pocket_slot.cell_node):
		return

	var cell_node: Node3D = pocket_slot.cell_node
	var cell_basis: Basis = cell_node.basis
	var cell_pos: Vector3 = cell_node.position
	# Search children of cell_node (not cell_node itself — it's the container)
	for child in cell_node.get_children():
		_find_and_hide_doors_recursive(child, _door_exterior_pos, 5.0, cell_basis, cell_pos)

	if not _hidden_interior_doors.is_empty():
		Log.debug("streaming", "Hidden %d interior door meshes for portal" % _hidden_interior_doors.size())


func _find_and_hide_doors_recursive(node: Node, pos: Vector3, radius: float,
		parent_basis: Basis, parent_pos: Vector3) -> void:
	if node is Node3D:
		var n3d := node as Node3D
		# Compute expected world position from parent transform chain
		# (don't rely on global_position — may be stale after reposition)
		var expected_world_pos: Vector3 = parent_basis * n3d.position + parent_pos
		var name_lower: String = n3d.name.to_lower()
		if name_lower.containsn("door") and not name_lower.containsn("doorframe") \
				and not name_lower.containsn("doorstep") and not name_lower.containsn("doorjamb"):
			if expected_world_pos.distance_to(pos) < radius and n3d.visible:
				n3d.visible = false
				_hidden_interior_doors.append(n3d)
		# Accumulate transform for children
		var child_basis: Basis = parent_basis * n3d.basis
		var child_pos: Vector3 = expected_world_pos
		for child in n3d.get_children():
			_find_and_hide_doors_recursive(child, pos, radius, child_basis, child_pos)
	else:
		for child in node.get_children():
			_find_and_hide_doors_recursive(child, pos, radius, parent_basis, parent_pos)


## Restore hidden interior doors
func _restore_interior_doors() -> void:
	for node: Node3D in _hidden_interior_doors:
		if is_instance_valid(node):
			node.visible = true
	_hidden_interior_doors.clear()


## Restore meshes hidden due to incompatible materials (ShaderMaterial/null)
func _restore_no_stencil_meshes() -> void:
	for node: Node3D in _hidden_no_stencil:
		if is_instance_valid(node):
			node.visible = true
	_hidden_no_stencil.clear()


## Move the pocket back to its original offset position
func _restore_pocket_position() -> void:
	if _pocket_slot and _pocket_slot.cell_node and is_instance_valid(_pocket_slot.cell_node):
		_pocket_slot.cell_node.position = _pocket_original_pos
		_pocket_slot.cell_node.basis = _pocket_original_basis
		Log.debug("streaming", "Pocket restored to %s" % _pocket_original_pos)


#endregion

#region Debug Visualization

## Toggle full debug visualization: stencil plane, pocket bounds, teleport markers
func set_debug_visible(enabled: bool) -> void:
	_debug_enabled = enabled
	if not is_active:
		return

	if enabled:
		_build_debug_visuals()
	else:
		_clear_debug_nodes()

	# Stencil plane debug color (red = stencil-write plane)
	if _stencil_plane:
		var mat: StandardMaterial3D = _stencil_plane.material_override as StandardMaterial3D
		if mat:
			if enabled:
				mat.albedo_color = Color(1, 0, 0, 0.5)
				mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			else:
				mat.albedo_color = Color(0, 0, 0, 0.01)


func _build_debug_visuals() -> void:
	_clear_debug_nodes()
	if not _portal_container or not is_instance_valid(_portal_container):
		return

	# 1. Teleport destination marker (green sphere at exterior door)
	_add_debug_sphere(_door_exterior_pos, Color.GREEN, 0.3, "DebugDoorPos")

	# 2. Teleport destination in pocket (blue sphere)
	if _door_info:
		var teleport_pos: Vector3 = _door_info.get_teleport_pos_godot()
		# After pocket reposition, this is where the arrival point is in world space
		if _pocket_slot and _pocket_slot.cell_node and is_instance_valid(_pocket_slot.cell_node):
			var pocket_teleport: Vector3 = _pocket_slot.cell_node.basis * teleport_pos + _pocket_slot.cell_node.position
			_add_debug_sphere(pocket_teleport, Color.CYAN, 0.3, "DebugTeleportDest")

	# 3. Pocket bounding box (yellow wireframe)
	if _pocket_slot and _pocket_slot.cell_node and is_instance_valid(_pocket_slot.cell_node):
		var cell_node: Node3D = _pocket_slot.cell_node
		_add_debug_sphere(cell_node.position, Color.YELLOW, 0.5, "DebugPocketOrigin")
		# Show pocket AABB by marking corners of child bounds
		var child_count := cell_node.get_child_count()
		if child_count > 0:
			_add_debug_sphere(cell_node.position + Vector3(5, 0, 5), Color(1, 1, 0, 0.3), 0.2, "DebugPocketExtent")
			_add_debug_sphere(cell_node.position + Vector3(-5, 0, -5), Color(1, 1, 0, 0.3), 0.2, "DebugPocketExtent2")

	# 4. Wall normal direction (red arrow from stencil plane)
	if _stencil_plane:
		var arrow_start: Vector3 = _stencil_plane.position
		var arrow_end: Vector3 = arrow_start + (-_stencil_plane.basis.z * 2.0)
		_add_debug_sphere(arrow_end, Color.RED, 0.15, "DebugWallNormal")

	Log.info("streaming", "Debug visuals: door_pos=%s, pocket_pos=%s, stencil_pos=%s" % [
		_door_exterior_pos,
		_pocket_slot.cell_node.position if _pocket_slot and _pocket_slot.cell_node else "null",
		_stencil_plane.position if _stencil_plane else "null"])


func _add_debug_sphere(pos: Vector3, color: Color, radius: float, debug_name: String) -> void:
	var sphere := MeshInstance3D.new()
	sphere.name = debug_name
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	sphere.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if color.a < 1.0 else BaseMaterial3D.TRANSPARENCY_DISABLED
	sphere.material_override = mat
	sphere.position = pos
	sphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_portal_container.add_child(sphere)
	_debug_nodes.append(sphere)


func _clear_debug_nodes() -> void:
	for node: Node3D in _debug_nodes:
		if is_instance_valid(node):
			node.queue_free()
	_debug_nodes.clear()

#endregion

#region Stencil Read on Interior Materials

## Apply stencil-read to all materials in the interior pocket
## This makes interior geometry only render where the stencil plane wrote its value
func _apply_stencil_read_to_pocket(pocket_slot: Variant) -> void:
	if not pocket_slot.cell_node or not is_instance_valid(pocket_slot.cell_node):
		return

	_modified_materials.clear()
	_hidden_no_stencil.clear()
	_apply_stencil_read_recursive(pocket_slot.cell_node)
	_stencil_applied = true

	# Count priority tiers for diagnostics
	var structural_count: int = 0
	var decorative_count: int = 0
	for key: String in _modified_materials:
		# Materials at priority 1 are structural, priority 3 are decorative
		# We can't easily check after the fact, so just log the total
		pass
	Log.info("streaming", "Applied stencil-read to %d materials in pocket '%s' (priority tiers: structural=1, decorative=3)" % [
		_modified_materials.size(), pocket_slot.cell_name])


func _apply_stencil_read_recursive(node: Node) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.visible:
			var priority: int = 2
			if not _apply_stencil_to_mesh_instance(mi, priority):
				# Mesh has incompatible materials (ShaderMaterial/null) — can't apply
				# stencil-read. With no_depth_test=false, these would render everywhere
				# on COMBINED layers (outside the doorframe). Hide during portal preview;
				# restored on deactivate via _restore_no_stencil_meshes().
				mi.visible = false
				_hidden_no_stencil.append(mi)
				Log.debug("streaming", "Stencil hide (incompatible material): %s" % mi.name)
	elif node is GeometryInstance3D:
		var gi := node as GeometryInstance3D
		if gi.material_override and gi.material_override is StandardMaterial3D:
			var original: StandardMaterial3D = gi.material_override as StandardMaterial3D
			var unique_mat: StandardMaterial3D = original.duplicate() as StandardMaterial3D
			var priority: int = 2
			_set_stencil_read_on_material(unique_mat, priority)
			gi.material_override = unique_mat
			_modified_materials["%d_override" % gi.get_instance_id()] = original
		elif gi.material_override and not gi.material_override is StandardMaterial3D and gi.visible:
			# Hide incompatible GeometryInstance3D — same reason as MeshInstance3D above
			if gi is Node3D:
				(gi as Node3D).visible = false
				_hidden_no_stencil.append(gi as Node3D)
				Log.debug("streaming", "Stencil hide (incompatible GeometryInstance3D): %s" % gi.name)

	for child in node.get_children():
		_apply_stencil_read_recursive(child)


## Apply stencil-read to a MeshInstance3D. Returns true if ALL surfaces are covered,
## false if any surface has an incompatible material (ShaderMaterial/null).
func _apply_stencil_to_mesh_instance(mi: MeshInstance3D, priority: int) -> bool:
	# Handle material_override first — duplicate to avoid modifying shared materials
	if mi.material_override:
		if mi.material_override is StandardMaterial3D:
			var original: StandardMaterial3D = mi.material_override as StandardMaterial3D
			var unique_mat: StandardMaterial3D = original.duplicate() as StandardMaterial3D
			_set_stencil_read_on_material(unique_mat, priority)
			mi.material_override = unique_mat
			_modified_materials["%d_override" % mi.get_instance_id()] = original
			return true
		else:
			# ShaderMaterial override — can't apply stencil-read
			return false

	# Handle per-surface materials
	if not mi.mesh:
		return true  # No mesh = nothing to leak
	var all_covered := true
	for surf_idx in mi.mesh.get_surface_count():
		var mat: Material = mi.get_active_material(surf_idx)
		if mat is StandardMaterial3D:
			var unique_mat: StandardMaterial3D = mat.duplicate() as StandardMaterial3D
			_set_stencil_read_on_material(unique_mat, priority)
			mi.set_surface_override_material(surf_idx, unique_mat)
			_modified_materials["%d_%d" % [mi.get_instance_id(), surf_idx]] = mat
		elif mat == null:
			# Null material — assign a default stencil-read material to prevent leak
			var default_mat := StandardMaterial3D.new()
			_set_stencil_read_on_material(default_mat, priority)
			mi.set_surface_override_material(surf_idx, default_mat)
			_modified_materials["%d_%d" % [mi.get_instance_id(), surf_idx]] = null
		else:
			# ShaderMaterial — can't apply stencil-read to this surface
			all_covered = false
	return all_covered


## Apply stencil-read settings to a material.
## Uses no_depth_test=true to bypass exterior wall depth — the stencil mask ensures
## interior geometry is only visible within the door opening. Wall clip is supplementary
## (helps depth sorting where it works). Dimming masks remaining depth artifacts.
func _set_stencil_read_on_material(mat: StandardMaterial3D, priority: int = 2) -> void:
	mat.stencil_mode = _SM_CUSTOM
	mat.stencil_flags = _SF_READ
	mat.stencil_compare = _SC_EQUAL
	mat.stencil_reference = STENCIL_REF

	# Stencil read requires the material to be in the alpha queue (Godot issue #107731)
	# Set transparency=ALPHA with alpha=1.0 (visually opaque) + depth_draw=ALWAYS
	if mat.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color.a = 1.0
		mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS

	# Dim the interior preview — darkens albedo to simulate a dark interior
	# and mask depth sorting artifacts (no_depth_test breaks inter-object sorting).
	mat.albedo_color.r *= PORTAL_DIM_FACTOR
	mat.albedo_color.g *= PORTAL_DIM_FACTOR
	mat.albedo_color.b *= PORTAL_DIM_FACTOR

	# Bypass depth test so interior geometry draws ON TOP of exterior walls.
	# Stencil mask ensures this only happens within the door opening.
	mat.no_depth_test = true
	mat.render_priority = priority


## Remove stencil-read from interior materials (restore originals)
func _remove_stencil_read_from_pocket() -> void:
	if not _stencil_applied or not _pocket_slot:
		return

	if _pocket_slot.cell_node and is_instance_valid(_pocket_slot.cell_node):
		_remove_stencil_read_recursive(_pocket_slot.cell_node)

	_modified_materials.clear()
	_stencil_applied = false


func _remove_stencil_read_recursive(node: Node) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var iid := mi.get_instance_id()

		# Restore material_override if we duplicated it
		var override_key := "%d_override" % iid
		if _modified_materials.has(override_key):
			mi.material_override = _modified_materials[override_key]

		# Restore per-surface materials
		if mi.mesh:
			for surf_idx in mi.mesh.get_surface_count():
				var key := "%d_%d" % [iid, surf_idx]
				if _modified_materials.has(key):
					mi.set_surface_override_material(surf_idx, _modified_materials[key])

	for child in node.get_children():
		_remove_stencil_read_recursive(child)

#endregion

#region Frame Update

## Update the portal each frame (lightweight — just visibility check)
func update(main_camera: Camera3D) -> void:
	if not is_active or not _stencil_plane:
		return

	# Hide stencil plane if portal is behind the camera (optimization)
	var cam_to_door: Vector3 = _door_exterior_pos - main_camera.global_position
	var cam_forward: Vector3 = -main_camera.global_basis.z
	_stencil_plane.visible = cam_to_door.dot(cam_forward) > -2.0

#endregion

#region Helpers

## Compute the stencil plane orientation using shared DoorUtils helper.
func _compute_portal_plane_basis(door_mesh: MeshInstance3D) -> Basis:
	return DoorUtils.compute_door_basis(_door_exterior_basis, door_mesh, _main_camera, _door_exterior_pos)


#endregion

#region Interior Light Management

## Expand interior light cull masks to COMBINED layers so they illuminate
## geometry visible through the stencil portal. Without this, interior objects
## seen through the portal are only lit by exterior ambient (too bright/wrong color).
func _expand_interior_lights(pocket_slot: Variant) -> void:
	_expanded_lights.clear()
	if not pocket_slot.cell_node or not is_instance_valid(pocket_slot.cell_node):
		return
	_expand_lights_recursive(pocket_slot.cell_node)
	if not _expanded_lights.is_empty():
		Log.debug("streaming", "Expanded %d interior lights to combined layers for portal" % _expanded_lights.size())


func _expand_lights_recursive(node: Node) -> void:
	if node is Light3D:
		var light := node as Light3D
		_expanded_lights[light.get_instance_id()] = light.light_cull_mask
		light.light_cull_mask = COMBINED_RENDER_LAYERS
	for child in node.get_children():
		_expand_lights_recursive(child)


## Restore interior light cull masks to their original values
func _restore_interior_lights() -> void:
	for iid: int in _expanded_lights:
		var light := instance_from_id(iid) as Light3D
		if light and is_instance_valid(light):
			light.light_cull_mask = _expanded_lights[iid]
	_expanded_lights.clear()

#endregion

#region Queries

## Get distance squared from a position to the door
func get_door_distance_sq(pos: Vector3) -> float:
	if not _door_info:
		return INF
	return pos.distance_squared_to(_door_exterior_pos)


## Get the target cell name
func get_cell_name() -> String:
	if _door_info:
		return _door_info.target_cell_name
	return ""

#endregion
