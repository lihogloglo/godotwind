## DebugOverlay - 3D debug visualization for chunks, tiers, cells, and LOD levels
##
## Provides visual overlays for debugging the streaming system:
## - Quadtree chunk boundaries (FAR tier)
## - Distance tier zones with color coding
## - Individual cell boundaries
## - LOD level visualization (color-codes objects by their LOD level)
## - Frustum visualization
##
## Usage:
##   var overlay := DebugOverlay.new()
##   add_child(overlay)
##   overlay.set_camera(camera)
##   overlay.show_chunks = true
class_name DebugOverlay
extends Node3D

const CS := preload("res://src/core/coordinate_system.gd")

## Visibility flags
var show_chunks: bool = false:
	set(v):
		show_chunks = v
		_update_visibility()
		if v:
			_rebuild_chunk_overlay()

var show_tiers: bool = false:
	set(v):
		show_tiers = v
		_update_visibility()
		if v:
			_tier_rings_built = false  # Force rebuild on next frame
			_rebuild_tier_overlay()

var show_cells: bool = false:
	set(v):
		show_cells = v
		_update_visibility()
		if v:
			_rebuild_cell_overlay()

var show_lod_levels: bool = false:
	set(v):
		show_lod_levels = v
		_update_visibility()
		if v:
			_rebuild_lod_overlay()
		else:
			_clear_lod_overlay()

var show_frustum: bool = false:
	set(v):
		show_frustum = v
		_update_visibility()

## Reference to camera for position updates
var _camera: Camera3D = null

## Reference to tier manager for distance calculations
var _tier_manager: RefCounted = null

## Reference to quadtree chunk manager
var _chunk_manager: RefCounted = null

## Reference to world streaming manager (for accessing loaded cells)
var _world_streaming_manager: Node = null

## Container nodes
var _chunk_container: Node3D = null
var _tier_container: Node3D = null
var _cell_container: Node3D = null
var _lod_container: Node3D = null
var _frustum_container: Node3D = null

## Whether tier rings need to be rebuilt (only when distances change)
var _tier_rings_built: bool = false

## LOD level colors for debug visualization
## LOD0 = Full detail (NEAR tier), LOD1-3 = MID tier, Impostor = FAR tier
const LOD_COLORS: Dictionary[int, Color] = {
	0: Color(0.2, 1.0, 0.2, 0.8),    # LOD0 (NEAR) - Bright green
	1: Color(1.0, 1.0, 0.2, 0.8),    # LOD1 (MID close) - Yellow
	2: Color(1.0, 0.6, 0.2, 0.8),    # LOD2 (MID mid) - Orange
	3: Color(1.0, 0.3, 0.2, 0.8),    # LOD3 (MID far) - Red-orange
	4: Color(0.6, 0.2, 1.0, 0.8),    # Impostor (FAR) - Purple
	-1: Color(0.5, 0.5, 0.5, 0.5),   # Unknown/Hidden - Gray
}

## Cache of original materials for restoration
var _original_materials: Dictionary[int, Array] = {}  # object_id -> Array[Material]

## Cached materials for each tier
var _tier_materials: Dictionary[int, StandardMaterial3D] = {}

## Tier colors (semi-transparent)
const TIER_COLORS: Dictionary[int, Color] = {
	0: Color(0.2, 1.0, 0.2, 0.15),   # NEAR - green (0-150m)
	1: Color(1.0, 1.0, 0.2, 0.15),   # MID - yellow (150-500m)
	2: Color(1.0, 0.5, 0.2, 0.15),   # FAR - orange (500-5000m)
	3: Color(0.5, 0.2, 1.0, 0.15),   # HORIZON - purple (5000m+)
}

## Chunk color
const CHUNK_COLOR := Color(0.0, 0.8, 1.0, 0.3)  # Cyan
const CHUNK_BORDER_COLOR := Color(0.0, 0.8, 1.0, 0.8)

## Cell grid color
const CELL_COLOR := Color(0.5, 0.5, 0.5, 0.1)
const CELL_BORDER_COLOR := Color(0.8, 0.8, 0.8, 0.4)

## Cell size in meters (from coordinate system)
const CELL_SIZE_METERS: float = CS.CELL_SIZE_GODOT  # ~117.03m

## FAR chunk size in cells
const FAR_CHUNK_SIZE := 8

## Update frequency (seconds)
var _update_interval: float = 0.5
var _update_timer: float = 0.0

## Last camera cell for change detection
var _last_camera_cell := Vector2i(99999, 99999)


func _ready() -> void:
	Log.info("debug", "Initializing debug overlay...")

	# Create container nodes
	_chunk_container = Node3D.new()
	_chunk_container.name = "ChunkOverlay"
	add_child(_chunk_container)

	_tier_container = Node3D.new()
	_tier_container.name = "TierOverlay"
	add_child(_tier_container)

	_cell_container = Node3D.new()
	_cell_container.name = "CellOverlay"
	add_child(_cell_container)

	_lod_container = Node3D.new()
	_lod_container.name = "LODOverlay"
	add_child(_lod_container)

	_frustum_container = Node3D.new()
	_frustum_container.name = "FrustumOverlay"
	add_child(_frustum_container)

	# Create tier materials
	_create_tier_materials()

	# Initial visibility
	_update_visibility()


func _process(delta: float) -> void:
	# Try to find camera if not set
	if not _camera:
		var vp := get_viewport()
		if vp:
			_camera = vp.get_camera_3d()
			if _camera:
				Log.debug("debug", "Auto-found camera: %s" % _camera.name)

	if not _camera:
		return

	# Update tier rings position EVERY FRAME for smooth following
	# The rings are drawn at origin and the container follows camera
	if show_tiers and _tier_container:
		if not _tier_rings_built:
			_rebuild_tier_overlay()
		else:
			# Just move the container - no expensive geometry rebuild
			var cam_pos := _camera.global_position
			_tier_container.global_position = Vector3(cam_pos.x, 0.0, cam_pos.z)

	_update_timer += delta
	if _update_timer < _update_interval:
		return
	_update_timer = 0.0

	# Get camera cell
	var camera_cell := _get_camera_cell()

	# Only rebuild cell-based overlays when camera changes cells
	if camera_cell != _last_camera_cell:
		_last_camera_cell = camera_cell
		# Rebuild cell-based overlays (NOT tier overlay - that follows smoothly)
		if show_chunks:
			_rebuild_chunk_overlay()
		if show_cells:
			_rebuild_cell_overlay()
		if show_lod_levels:
			_rebuild_lod_overlay()


## Set the camera reference
func set_camera(cam: Camera3D) -> void:
	_camera = cam
	Log.info("debug", "Camera set: %s" % [cam.name if cam else "null"])
	# Force rebuild if any overlays are enabled
	if _camera:
		_rebuild_overlays()


## Set the tier manager reference
func set_tier_manager(tm: RefCounted) -> void:
	_tier_manager = tm


## Set the chunk manager reference
func set_chunk_manager(cm: RefCounted) -> void:
	_chunk_manager = cm


## Set the world streaming manager reference (for LOD visualization)
func set_world_streaming_manager(wsm: Node) -> void:
	_world_streaming_manager = wsm


## Get current camera cell
func _get_camera_cell() -> Vector2i:
	if not _camera:
		return Vector2i.ZERO

	var pos := _camera.global_position
	var cell_x := floori(pos.x / CELL_SIZE_METERS)
	var cell_y := floori(-pos.z / CELL_SIZE_METERS)  # Z is flipped
	return Vector2i(cell_x, cell_y)


## Update container visibility
func _update_visibility() -> void:
	if _chunk_container:
		_chunk_container.visible = show_chunks
	if _tier_container:
		_tier_container.visible = show_tiers
	if _cell_container:
		_cell_container.visible = show_cells
	if _lod_container:
		_lod_container.visible = show_lod_levels
	if _frustum_container:
		_frustum_container.visible = show_frustum


## Create materials for tier visualization
func _create_tier_materials() -> void:
	for tier: int in TIER_COLORS:
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = TIER_COLORS[tier]
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_tier_materials[tier] = mat


## Rebuild all overlays
## Note: Tier overlay is NOT rebuilt here - it follows camera smoothly in _process()
func _rebuild_overlays() -> void:
	if show_chunks:
		_rebuild_chunk_overlay()
	# Tier overlay is handled in _process() for smooth camera following
	# Don't rebuild here to avoid cell-boundary jumping
	if show_cells:
		_rebuild_cell_overlay()
	if show_lod_levels:
		_rebuild_lod_overlay()


## Rebuild chunk visualization
func _rebuild_chunk_overlay() -> void:
	# Clear existing
	if _chunk_container:
		for child in _chunk_container.get_children():
			child.queue_free()
	else:
		return

	if not _camera:
		Log.warn("debug", "Chunks: No camera set")
		return

	var camera_cell := _get_camera_cell()

	# If we have a chunk manager, use it. Otherwise show a grid around the camera
	var far_chunks: Array[Vector2i] = []
	if _chunk_manager and _chunk_manager.has_method("get_visible_chunks"):
		far_chunks = _chunk_manager.get_visible_chunks(camera_cell, 2)  # Tier.FAR = 2
	else:
		# No chunk manager - show chunks around camera position
		var camera_chunk := Vector2i(floori(float(camera_cell.x) / FAR_CHUNK_SIZE), floori(float(camera_cell.y) / FAR_CHUNK_SIZE))
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				far_chunks.append(Vector2i(camera_chunk.x + dx, camera_chunk.y + dy))

	Log.debug("debug", "Showing %d chunks around cell %s" % [far_chunks.size(), camera_cell])

	# Create visual for each chunk
	for chunk: Vector2i in far_chunks:
		_create_chunk_visual(chunk, FAR_CHUNK_SIZE, CHUNK_COLOR)


## Create a visual box for a chunk
func _create_chunk_visual(chunk_grid: Vector2i, chunk_size: int, color: Color) -> void:
	var origin_x := chunk_grid.x * chunk_size * CELL_SIZE_METERS
	var origin_z := -chunk_grid.y * chunk_size * CELL_SIZE_METERS - chunk_size * CELL_SIZE_METERS
	var size := chunk_size * CELL_SIZE_METERS

	# Create box mesh
	var mesh := BoxMesh.new()
	mesh.size = Vector3(size, 50.0, size)  # 50m tall for visibility

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh
	mesh_instance.position = Vector3(
		origin_x + size * 0.5,
		25.0,  # Center height
		origin_z + size * 0.5
	)

	# Material
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh_instance.material_override = mat

	_chunk_container.add_child(mesh_instance)

	# Add wireframe border
	_add_chunk_border(origin_x, origin_z, size)


## Add wireframe border to chunk
func _add_chunk_border(origin_x: float, origin_z: float, size: float) -> void:
	var im := ImmediateMesh.new()
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = im

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = CHUNK_BORDER_COLOR
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_instance.material_override = mat

	# Draw lines
	im.surface_begin(Mesh.PRIMITIVE_LINES)

	var y := 5.0  # Slightly above ground
	var corners := [
		Vector3(origin_x, y, origin_z),
		Vector3(origin_x + size, y, origin_z),
		Vector3(origin_x + size, y, origin_z + size),
		Vector3(origin_x, y, origin_z + size),
	]

	# Bottom square
	for i in 4:
		im.surface_add_vertex(corners[i])
		im.surface_add_vertex(corners[(i + 1) % 4])

	im.surface_end()

	_chunk_container.add_child(mesh_instance)


## Rebuild tier zone visualization
## Rings are drawn centered at origin - the container is moved to camera position in _process()
## This allows smooth camera following without expensive geometry rebuilds
func _rebuild_tier_overlay() -> void:
	# Clear existing
	if _tier_container:
		for child in _tier_container.get_children():
			child.queue_free()
	else:
		return

	_tier_rings_built = false

	if not _camera:
		Log.warn("debug", "Tiers: No camera set")
		return

	# Rings are centered at origin (0, 0, 0) - container will be moved to camera position
	var ring_center := Vector3.ZERO

	# Get tier distances - use defaults if no manager
	var tier_distances: Dictionary = {}
	var tier_end_distances: Dictionary = {}

	if _tier_manager:
		if _tier_manager.has_method("get_debug_info"):
			var debug: Dictionary = _tier_manager.get_debug_info()
			tier_distances = debug.get("tier_distances", {})
			tier_end_distances = debug.get("tier_end_distances", {})
		else:
			tier_distances = _tier_manager.get("tier_distances")
			tier_end_distances = _tier_manager.get("tier_end_distances")
	else:
		# Use default values
		tier_distances = {0: 0.0, 2: 150.0, 3: 5000.0}
		tier_end_distances = {0: 150.0, 2: 5000.0, 3: 10000.0}

	Log.debug("debug", "Tier distances: %s (rings centered at origin, container follows camera)" % [tier_end_distances])

	# Create rings for each tier (centered at origin)
	# NEAR tier: 0 to 150m (green)
	_create_tier_ring(ring_center, 0.0, tier_end_distances.get(0, 150.0), 0)

	# MID tier: 150m to 500m (yellow) - this tier handles per-object LODs
	var mid_start: float = tier_end_distances.get(0, 150.0)
	var mid_end: float = tier_end_distances.get(1, 500.0)
	if mid_end <= mid_start:
		# Fallback if tier 1 not in dictionary
		mid_end = tier_distances.get(2, 500.0)
	_create_tier_ring(ring_center, mid_start, mid_end, 1)

	# FAR tier: 500m to 5000m (orange) - cap at 2000m for visibility
	var far_start: float = mid_end
	var far_end: float = tier_end_distances.get(2, 5000.0)
	_create_tier_ring(ring_center, far_start, minf(far_end, 2000.0), 2)

	# Mark as built and set initial position
	_tier_rings_built = true
	var cam_pos := _camera.global_position
	_tier_container.global_position = Vector3(cam_pos.x, 0.0, cam_pos.z)


## Create a ring mesh for a tier zone
func _create_tier_ring(center: Vector3, inner_radius: float, outer_radius: float, tier: int) -> void:
	if outer_radius <= inner_radius:
		return

	# Limit size for performance
	var max_render_radius := 2000.0
	outer_radius = minf(outer_radius, max_render_radius)

	# Create cylinder mesh for the ring
	var segments := 32

	var im := ImmediateMesh.new()
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = im

	mesh_instance.material_override = _tier_materials.get(tier, _tier_materials[0])

	# Draw as triangle strip ring
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)

	var y := 2.0  # Slightly above ground
	for i in segments + 1:
		var angle := (float(i) / segments) * TAU
		var cos_a := cos(angle)
		var sin_a := sin(angle)

		# Inner vertex
		var inner_pos := Vector3(
			center.x + cos_a * inner_radius,
			y,
			center.z + sin_a * inner_radius
		)
		im.surface_add_vertex(inner_pos)

		# Outer vertex
		var outer_pos := Vector3(
			center.x + cos_a * outer_radius,
			y,
			center.z + sin_a * outer_radius
		)
		im.surface_add_vertex(outer_pos)

	im.surface_end()

	_tier_container.add_child(mesh_instance)

	# Add distance text labels
	_add_tier_label(center, outer_radius, tier)


## Add a label for tier distance
func _add_tier_label(center: Vector3, radius: float, tier: int) -> void:
	var tier_names := {0: "NEAR", 1: "MID", 2: "FAR", 3: "HORIZON"}
	var label_text := "%s\n%.0fm" % [tier_names.get(tier, "TIER"), radius]

	# Create 3D label at edge of tier
	var label := Label3D.new()
	label.text = label_text
	label.font_size = 48
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.modulate = TIER_COLORS.get(tier, Color.WHITE)
	label.modulate.a = 1.0

	label.position = Vector3(center.x + radius * 0.7, 50.0, center.z)

	_tier_container.add_child(label)


## Rebuild cell grid visualization
func _rebuild_cell_overlay() -> void:
	# Clear existing
	if _cell_container:
		for child in _cell_container.get_children():
			child.queue_free()
	else:
		return

	if not _camera:
		Log.warn("debug", "Cells: No camera set")
		return

	Log.debug("debug", "Rebuilding cell grid at camera position %s" % [_camera.global_position])

	var camera_cell := _get_camera_cell()
	var view_radius := 5  # Show cells within 5 cell radius

	# Create grid lines
	var im := ImmediateMesh.new()
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = im

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = CELL_BORDER_COLOR
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_instance.material_override = mat

	im.surface_begin(Mesh.PRIMITIVE_LINES)

	var y := 3.0

	for dy in range(-view_radius, view_radius + 1):
		for dx in range(-view_radius, view_radius + 1):
			var cell := Vector2i(camera_cell.x + dx, camera_cell.y + dy)
			var origin_x := float(cell.x) * CELL_SIZE_METERS
			var origin_z := float(-cell.y) * CELL_SIZE_METERS - CELL_SIZE_METERS

			# Draw cell boundary
			var corners := [
				Vector3(origin_x, y, origin_z),
				Vector3(origin_x + CELL_SIZE_METERS, y, origin_z),
				Vector3(origin_x + CELL_SIZE_METERS, y, origin_z + CELL_SIZE_METERS),
				Vector3(origin_x, y, origin_z + CELL_SIZE_METERS),
			]

			for i in 4:
				im.surface_add_vertex(corners[i])
				im.surface_add_vertex(corners[(i + 1) % 4])

	im.surface_end()

	_cell_container.add_child(mesh_instance)

	# Add cell coordinate labels for nearby cells
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			var cell := Vector2i(camera_cell.x + dx, camera_cell.y + dy)
			var center_x := float(cell.x) * CELL_SIZE_METERS + CELL_SIZE_METERS * 0.5
			var center_z := float(-cell.y) * CELL_SIZE_METERS - CELL_SIZE_METERS * 0.5

			var label := Label3D.new()
			label.text = "(%d,%d)" % [cell.x, cell.y]
			label.font_size = 32
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.no_depth_test = true
			label.modulate = Color(0.7, 0.7, 0.7, 0.8)

			# Highlight current cell
			if dx == 0 and dy == 0:
				label.modulate = Color(0.2, 1.0, 0.2, 1.0)
				label.font_size = 40

			label.position = Vector3(center_x, 20.0, center_z)

			_cell_container.add_child(label)


## Get stats about currently visible debug elements
func get_stats() -> Dictionary:
	return {
		"chunks_shown": _chunk_container.get_child_count() if _chunk_container else 0,
		"show_chunks": show_chunks,
		"show_tiers": show_tiers,
		"show_cells": show_cells,
		"show_lod_levels": show_lod_levels,
		"show_frustum": show_frustum,
		"camera_cell": _last_camera_cell,
	}


#region LOD Level Debug Visualization

## Rebuild LOD level visualization
## Colors all visible objects based on their current LOD level/tier
func _rebuild_lod_overlay() -> void:
	# Clear the info container
	if _lod_container:
		for child in _lod_container.get_children():
			child.queue_free()

	if not _camera:
		Log.warn("debug", "LOD: No camera set")
		return

	if not _world_streaming_manager:
		Log.warn("debug", "LOD: No world streaming manager set")
		_create_lod_legend()
		return

	var camera_pos := _camera.global_position
	Log.debug("debug", "Rebuilding LOD visualization at %s" % [camera_pos])

	# Get loaded cells and color their objects
	var colored_count := 0
	var cells_processed := 0

	if _world_streaming_manager.has_method("get_loaded_cell_coordinates"):
		var loaded_coords: Array = _world_streaming_manager.get_loaded_cell_coordinates()
		for cell_grid: Vector2i in loaded_coords:
			var cell_node: Node3D = _world_streaming_manager.get_loaded_cell(cell_grid.x, cell_grid.y)
			if cell_node and cell_node.visible:
				cells_processed += 1
				colored_count += _color_cell_objects(cell_node, camera_pos)

	Log.debug("debug", "LOD: Colored %d objects in %d cells" % [colored_count, cells_processed])

	# Create legend
	_create_lod_legend()


## Color objects in a cell based on their ACTUAL render state
## Mode 0: Show actual state (what IS rendered - currently all LOD0)
## Mode 1: Show expected state (what SHOULD be at this distance)
var lod_debug_mode: int = 0  # 0 = actual, 1 = expected

func _color_cell_objects(cell_node: Node3D, camera_pos: Vector3) -> int:
	var count := 0

	for child: Node in cell_node.get_children():
		if child is Node3D:
			var node3d := child as Node3D
			if not node3d.visible:
				continue

			var lod_level: int
			if lod_debug_mode == 0:
				# Show ACTUAL render state (currently all Node3D = LOD0)
				lod_level = _get_actual_render_state(node3d)
			else:
				# Show EXPECTED LOD level based on distance
				var distance := camera_pos.distance_to(node3d.global_position)
				lod_level = _distance_to_lod_level(distance)

			# Apply debug color to all MeshInstance3D children
			count += _apply_lod_color_to_node(node3d, lod_level)

	return count


## Convert distance to LOD level for visualization purposes
## NOTE: This shows what LOD SHOULD be at this distance, not necessarily what IS rendered
## Currently the MID tier LOD system is not connected, so all Node3D objects are LOD0
func _distance_to_lod_level(distance: float) -> int:
	const NEAR_END := 150.0
	const MID_LOD1_END := 250.0
	const MID_LOD2_END := 375.0
	const MID_END := 500.0

	if distance < NEAR_END:
		return 0  # LOD0 - NEAR tier, full detail
	elif distance < MID_LOD1_END:
		return 1  # LOD1 - MID tier, high detail
	elif distance < MID_LOD2_END:
		return 2  # LOD2 - MID tier, medium detail
	elif distance < MID_END:
		return 3  # LOD3 - MID tier, low detail
	else:
		return 4  # Impostor - FAR tier


## Determine actual rendering state of an object
## Returns: 0 = NEAR (full Node3D), 4 = Impostor, -1 = unknown/hidden
## NOTE: MID tier LODs (1-3) would require ObjectDistanceManager integration
func _get_actual_render_state(node: Node3D) -> int:
	# Check if this is a MultiMesh instance (would indicate LOD batching)
	if node is MultiMeshInstance3D:
		# This would be a LOD batch - but we'd need to check which LOD level
		return 1  # Assume LOD1 for now

	# Check if this is a regular mesh (NEAR tier full geometry)
	if node is MeshInstance3D or _has_mesh_child(node):
		return 0  # LOD0 - full detail Node3D

	# Could be a placeholder or other node type
	return -1


## Check if node has any MeshInstance3D children
func _has_mesh_child(node: Node) -> bool:
	for child in node.get_children():
		if child is MeshInstance3D:
			return true
		if _has_mesh_child(child):
			return true
	return false


## Apply LOD debug color to a node and its mesh children
func _apply_lod_color_to_node(node: Node3D, lod_level: int) -> int:
	var count := 0
	var color: Color = LOD_COLORS.get(lod_level, LOD_COLORS[-1])

	# Process this node if it's a MeshInstance3D
	if node is MeshInstance3D:
		var mesh_inst := node as MeshInstance3D
		_save_and_apply_debug_material(mesh_inst, color)
		count += 1

	# Recursively process children
	for child: Node in node.get_children():
		if child is Node3D:
			count += _apply_lod_color_to_node(child as Node3D, lod_level)

	return count


## Save original material and apply debug color
func _save_and_apply_debug_material(mesh_inst: MeshInstance3D, color: Color) -> void:
	var obj_id := mesh_inst.get_instance_id()

	# Save original material if not already saved
	if obj_id not in _original_materials:
		var mats: Array = []
		if mesh_inst.material_override:
			mats.append(mesh_inst.material_override)
		else:
			for i in range(mesh_inst.get_surface_override_material_count()):
				mats.append(mesh_inst.get_surface_override_material(i))
		_original_materials[obj_id] = mats

	# Create and apply debug material
	var debug_mat := StandardMaterial3D.new()
	debug_mat.albedo_color = color
	debug_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	debug_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_inst.material_override = debug_mat


## Clear LOD overlay and restore original materials
func _clear_lod_overlay() -> void:
	# Clear the container
	if _lod_container:
		for child in _lod_container.get_children():
			child.queue_free()

	# Restore original materials
	for obj_id: int in _original_materials:
		var mesh_inst := instance_from_id(obj_id)
		if mesh_inst and mesh_inst is MeshInstance3D:
			var mats: Array = _original_materials[obj_id]
			(mesh_inst as MeshInstance3D).material_override = null
			if not mats.is_empty() and mats[0] != null:
				(mesh_inst as MeshInstance3D).material_override = mats[0]

	_original_materials.clear()
	Log.debug("debug", "LOD: Cleared overlay and restored materials")


## Create a legend showing what each color means
func _create_lod_legend() -> void:
	if not _camera:
		return

	# Create legend panel as a 3D billboard near the camera
	var legend_pos := _camera.global_position + _camera.global_transform.basis.z * -5.0 + Vector3(3, 2, 0)

	# Title showing current mode
	var title := Label3D.new()
	if lod_debug_mode == 0:
		title.text = "ACTUAL Render State"
	else:
		title.text = "EXPECTED LOD by Distance"
	title.font_size = 28
	title.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	title.no_depth_test = true
	title.modulate = Color.WHITE
	title.outline_size = 6
	title.outline_modulate = Color.BLACK
	title.position = legend_pos
	_lod_container.add_child(title)

	var y_offset := 0.5

	if lod_debug_mode == 0:
		# Actual mode - show what's really being rendered
		var actual_labels := {
			0: "LOD0 - Full Node3D (NEAR)",
			-1: "Unknown/Hidden",
		}
		for lod_level: int in [0, -1]:
			var label := Label3D.new()
			label.text = actual_labels[lod_level]
			label.font_size = 22
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.no_depth_test = true
			label.modulate = LOD_COLORS.get(lod_level, Color.WHITE)
			label.outline_size = 4
			label.outline_modulate = Color.BLACK
			label.position = legend_pos + Vector3(0, -y_offset, 0)
			y_offset += 0.35
			_lod_container.add_child(label)

		# Warning about missing LOD system
		var warning := Label3D.new()
		warning.text = "(MID LODs not connected)"
		warning.font_size = 18
		warning.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		warning.no_depth_test = true
		warning.modulate = Color(1.0, 0.5, 0.3, 1.0)
		warning.outline_size = 3
		warning.outline_modulate = Color.BLACK
		warning.position = legend_pos + Vector3(0, -y_offset - 0.2, 0)
		_lod_container.add_child(warning)
	else:
		# Expected mode - show what LOD SHOULD be at each distance
		var lod_names := {
			0: "LOD0 (NEAR 0-150m)",
			1: "LOD1 (MID 150-250m)",
			2: "LOD2 (MID 250-375m)",
			3: "LOD3 (MID 375-500m)",
			4: "Impostor (FAR 500m+)",
		}

		for lod_level: int in lod_names:
			var label := Label3D.new()
			label.text = lod_names[lod_level]
			label.font_size = 22
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.no_depth_test = true
			label.modulate = LOD_COLORS.get(lod_level, Color.WHITE)
			label.outline_size = 4
			label.outline_modulate = Color.BLACK
			label.position = legend_pos + Vector3(0, -y_offset, 0)
			y_offset += 0.35
			_lod_container.add_child(label)


## Toggle between actual and expected LOD visualization modes
func toggle_lod_debug_mode() -> void:
	lod_debug_mode = 1 - lod_debug_mode  # Toggle between 0 and 1
	if show_lod_levels:
		_rebuild_lod_overlay()

#endregion
