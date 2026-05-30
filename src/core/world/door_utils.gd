## DoorUtils — Shared door mesh finding and orientation utilities
##
## Static helper functions used by DoorPortal, InteriorPocketManager, and
## door-related subsystems. Consolidates duplicated tree-walk logic.
extends RefCounted


## Find a door node by ref_id prefix (node names are "ref_id_refnum", case-insensitive).
## Returns the top-level Node3D matching the ref_id within the given radius.
static func find_by_ref_id(root: Node, ref_id: StringName, pos: Vector3, radius: float, ref_num: int = -1) -> Node3D:
	var ref_id_lower: String = str(ref_id).to_lower()
	return _find_by_ref_id_inner(root, ref_id_lower, pos, radius, ref_num)


static func _find_by_ref_id_inner(root: Node, ref_id_lower: String, pos: Vector3, radius: float, ref_num: int) -> Node3D:
	if root is Node3D:
		var n3d := root as Node3D
		var name_match: bool = n3d.name.to_lower().begins_with(ref_id_lower)
		var meta_match: bool = str(n3d.get_meta("ref_id", "")).to_lower() == ref_id_lower
		var ref_num_match: bool = ref_num < 0 or int(n3d.get_meta("ref_num", -1)) == ref_num
		if (name_match or meta_match) and ref_num_match:
			if n3d.global_position.distance_to(pos) < radius:
				return n3d
	for child in root.get_children():
		var result: Node3D = _find_by_ref_id_inner(child, ref_id_lower, pos, radius, ref_num)
		if result:
			return result
	return null


## Find a door node near a position (searches for nodes with "door" in name).
## Excludes doorframe/doorstep/doorjamb variants.
## Returns the top-level Node3D (may contain MeshInstance3D children).
static func find_near(root: Node, pos: Vector3, radius: float) -> Node3D:
	if root is Node3D:
		var n3d := root as Node3D
		var name_lower: String = n3d.name.to_lower()
		if name_lower.containsn("door") and not name_lower.containsn("doorframe") \
				and not name_lower.containsn("doorstep") and not name_lower.containsn("doorjamb"):
			if n3d.global_position.distance_to(pos) < radius:
				return n3d
	for child in root.get_children():
		var result: Node3D = find_near(child, pos, radius)
		if result:
			return result
	return null


## Find a door mesh (MeshInstance3D) by ref_id prefix. Falls back to name search.
## Used by DoorPortal for stencil plane sizing.
static func find_door_mesh(root: Node, ref_id: StringName, pos: Vector3, radius: float, ref_num: int = -1) -> MeshInstance3D:
	var ref_id_lower: String = str(ref_id).to_lower()
	var result: MeshInstance3D = _find_mesh_by_ref_id(root, ref_id_lower, pos, radius, ref_num)
	if not result:
		result = _find_mesh_near(root, pos, radius)
	return result


static func _find_mesh_by_ref_id(root: Node, ref_id_lower: String, pos: Vector3, radius: float, ref_num: int) -> MeshInstance3D:
	if root is Node3D:
		var n3d := root as Node3D
		# Match by node name prefix OR by "ref_id" metadata (set by reference_instantiator)
		var name_match: bool = n3d.name.to_lower().begins_with(ref_id_lower)
		var meta_match: bool = str(n3d.get_meta("ref_id", "")).to_lower() == ref_id_lower
		var ref_num_match: bool = ref_num < 0 or int(n3d.get_meta("ref_num", -1)) == ref_num
		if (name_match or meta_match) and ref_num_match:
			if n3d.global_position.distance_to(pos) < radius:
				if n3d is MeshInstance3D:
					return n3d as MeshInstance3D
				for child in n3d.get_children():
					if child is MeshInstance3D:
						return child as MeshInstance3D
	for child in root.get_children():
		var result: MeshInstance3D = _find_mesh_by_ref_id(child, ref_id_lower, pos, radius, ref_num)
		if result:
			return result
	return null


static func _find_mesh_near(root: Node, pos: Vector3, radius: float) -> MeshInstance3D:
	if root is Node3D:
		var n3d := root as Node3D
		var name_lower: String = n3d.name.to_lower()
		if name_lower.containsn("door") and not name_lower.containsn("doorframe") \
				and not name_lower.containsn("doorstep") and not name_lower.containsn("doorjamb"):
			if n3d.global_position.distance_to(pos) < radius:
				if n3d is MeshInstance3D:
					return n3d as MeshInstance3D
				for child in n3d.get_children():
					if child is MeshInstance3D:
						return child as MeshInstance3D
	for child in root.get_children():
		var result: MeshInstance3D = _find_mesh_near(child, pos, radius)
		if result:
			return result
	return null


## Get the first MeshInstance3D from a node (itself or first child).
static func get_mesh_instance(node: Node3D) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node as MeshInstance3D
	for child in node.get_children():
		if child is MeshInstance3D:
			return child as MeshInstance3D
	return null


## Compute a reliable door orientation basis.
##
## Strategy:
##   1. AABB thinnest axis + ESM basis (most reliable — combines mesh geometry
##      with ESM rotation to handle any NIF local axis convention)
##   2. ESM basis most-horizontal column (fallback when no mesh available)
##   3. Camera-facing fallback (last resort, logs a warning)
##
## Returns a Basis where -Z is the wall normal (outward-facing).
static func compute_door_basis(esm_basis: Basis, door_mesh: Node3D, camera: Camera3D = null,
		door_pos: Vector3 = Vector3.ZERO) -> Basis:
	var has_rotation: bool = _has_esm_rotation(esm_basis)

	# Step 1: AABB thinnest axis transformed by ESM basis (handles any NIF convention)
	var mi: MeshInstance3D = get_mesh_instance(door_mesh) if door_mesh else null
	if mi and mi.mesh:
		var aabb: AABB = mi.mesh.get_aabb()
		var sizes := [aabb.size.x, aabb.size.y, aabb.size.z]
		var min_idx := 0
		if sizes[1] < sizes[min_idx]: min_idx = 1
		if sizes[2] < sizes[min_idx]: min_idx = 2
		var sorted_sizes: Array[float] = [sizes[0], sizes[1], sizes[2]]
		sorted_sizes.sort()
		# Only use if there's a clear thin axis (at least 2:1 ratio)
		if sorted_sizes[0] < sorted_sizes[1] * 0.5:
			var local_normal := Vector3.ZERO
			local_normal[min_idx] = 1.0
			# Transform local thin axis to world space using the mesh's actual
			# global transform basis. This already includes ESM rotation AND any
			# parent transform (pocket repositioning, container rotation) —
			# more correct than using raw ESM basis alone.
			var world_normal: Vector3 = (mi.global_transform.basis * local_normal).normalized()
			world_normal.y = 0.0
			if world_normal.length_squared() > 0.01:
				world_normal = world_normal.normalized()
				# AABB gives direction but not sign — disambiguate using camera.
				# Normal should point outward (toward camera/exterior).
				if camera and door_pos != Vector3.ZERO:
					var to_cam: Vector3 = camera.global_position - door_pos
					to_cam.y = 0.0
					if to_cam.dot(world_normal) < 0.0:
						world_normal = -world_normal
				return Basis.looking_at(-world_normal, Vector3.UP)

	# Step 2: No mesh — pick the most horizontal ESM basis column as wall normal
	if has_rotation:
		var best_col := _most_horizontal_basis_column(esm_basis)
		best_col.y = 0.0
		if best_col.length_squared() > 0.01:
			best_col = best_col.normalized()
			# Same sign disambiguation as Step 1
			if camera and door_pos != Vector3.ZERO:
				var to_cam: Vector3 = camera.global_position - door_pos
				to_cam.y = 0.0
				if to_cam.dot(best_col) < 0.0:
					best_col = -best_col
			return Basis.looking_at(-best_col, Vector3.UP)

	# Step 3: Camera-facing fallback (last resort)
	if camera and door_pos != Vector3.ZERO:
		var cam_dir: Vector3 = (camera.global_position - door_pos)
		cam_dir.y = 0.0
		if cam_dir.length_squared() > 0.01:
			cam_dir = cam_dir.normalized()
			Log.warn("streaming", "Door basis using camera-facing fallback at %s — no mesh and no ESM rotation" % door_pos)
			return Basis.looking_at(-cam_dir, Vector3.UP)

	return Basis.IDENTITY


## Check if ESM rotation is non-zero (float-safe, avoids Basis == Basis comparison)
static func _has_esm_rotation(esm_basis: Basis) -> bool:
	# A zero-rotation ESM basis produces Basis.IDENTITY. Compare against that
	# using the basis columns' deviation from identity axes.
	var diff := (esm_basis.x - Vector3(1, 0, 0)).length_squared() \
			+ (esm_basis.y - Vector3(0, 1, 0)).length_squared() \
			+ (esm_basis.z - Vector3(0, 0, 1)).length_squared()
	return diff > 0.001


## Pick the ESM basis column that is most horizontal (smallest abs Y component).
## For doors, this is the wall normal — perpendicular to the door face.
static func _most_horizontal_basis_column(b: Basis) -> Vector3:
	var cols: Array[Vector3] = [b.x, b.y, b.z]
	var best: Vector3 = cols[0]
	var best_abs_y: float = absf(cols[0].y)
	for i in range(1, 3):
		var abs_y: float = absf(cols[i].y)
		if abs_y < best_abs_y:
			best = cols[i]
			best_abs_y = abs_y
	return best


## Extract the door forward direction (outward from wall) from a basis.
## The wall normal is +Z of the door basis. Returns a normalized horizontal vector.
static func get_door_forward(esm_basis: Basis, door_mesh: Node3D) -> Vector3:
	var basis: Basis = compute_door_basis(esm_basis, door_mesh)
	if not _has_esm_rotation(basis):
		return Vector3(0, 0, -1)  # Default forward
	var forward: Vector3 = basis.z
	forward.y = 0.0
	if forward.length_squared() > 0.01:
		return forward.normalized()
	return Vector3(0, 0, -1)


## Debug: list all nodes with "door" in name and their distances to a position
static func debug_list_door_nodes(root: Node, target_pos: Vector3, depth: int = 0) -> void:
	if depth > 4:
		return
	if root is Node3D:
		var n3d := root as Node3D
		var name_lower: String = n3d.name.to_lower()
		if name_lower.containsn("door"):
			var dist: float = n3d.global_position.distance_to(target_pos)
			Log.info("streaming", "  DOOR NODE: '%s' at %s (dist=%.1fm, global=%s)" % [
				n3d.name, n3d.position, dist, n3d.global_position])
	for child in root.get_children():
		debug_list_door_nodes(child, target_pos, depth + 1)
