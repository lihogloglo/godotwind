## Object Picker - Click-to-select objects in the 3D world
##
## Handles mouse picking of objects via raycasting, with identity resolution
## to trace picked nodes back to their ESM records and cell references.
##
## Features:
## - Raycast-based object selection
## - Multi-hit disambiguation (popup when clicking overlapping objects)
## - Selection outline rendering
## - Identity chain resolution (Node3D -> CellReference -> ESMRecord)
class_name ObjectPicker
extends Node


#region Signals

## Emitted when an object is selected
signal object_selected(selection: Selection)

## Emitted when selection is cleared
signal selection_cleared

## Emitted when picker mode is entered
signal picker_mode_entered

## Emitted when picker mode is exited
signal picker_mode_exited

#endregion


#region Classes

## Represents a selected object with full identity chain
class Selection:
	## The Godot node that was picked
	var node: Node3D

	## World position of the hit point
	var hit_position: Vector3

	## Cell reference record (if from ESM)
	var cell_ref: RefCounted  # CellReference

	## Base record from ESM (STAT, ACTI, NPC_, etc.)
	var base_record: RefCounted  # ESMRecord

	## Form ID / record ID
	var form_id: String

	## Record type (STAT, ACTI, NPC_, CREA, etc.)
	var record_type: String

	## Parent cell info
	var cell_name: String
	var cell_grid: Vector2i
	var is_interior: bool

	## Runtime instance ID (for multiple instances of same object)
	var instance_id: int

	## Model path if available
	var model_path: String

	## World transform
	var world_transform: Transform3D

	func _init() -> void:
		instance_id = -1
		cell_grid = Vector2i.ZERO
		is_interior = false

	func get_display_name() -> String:
		if form_id.is_empty():
			return node.name if node else "Unknown"
		return form_id

	func get_type_display() -> String:
		if record_type.is_empty():
			return "Node"
		return record_type

	func get_position_string() -> String:
		if not node:
			return "N/A"
		var pos := node.global_position
		return "(%.1f, %.1f, %.1f)" % [pos.x, pos.y, pos.z]

	func get_cell_string() -> String:
		if is_interior:
			return cell_name
		return "(%d, %d) %s" % [cell_grid.x, cell_grid.y, cell_name]

#endregion


#region Configuration

## Maximum raycast distance
@export var max_distance: float = 2000.0

## Collision mask for picking (default: all layers)
@export var collision_mask: int = 0xFFFFFFFF

## Whether to pick through transparent objects (raycast continues on alpha < threshold)
@export var pick_through_alpha: bool = false

#endregion


#region State

## Current selection (null if nothing selected)
var current_selection: Selection = null

## Whether picker mode is active (waiting for click)
var picker_mode: bool = false

## Reference to the camera to use for picking
var _camera: Camera3D = null

## Reference to the viewport
var _viewport: Viewport = null

## Selection outline material (applied to selected objects)
var _outline_material: ShaderMaterial = null

## Currently outlined node (for cleanup)
var _outlined_node: Node3D = null

## Original materials backup (for restoring after outline removal)
var _original_next_pass: Material = null

#endregion


func _ready() -> void:
	_setup_outline_material()


func _input(event: InputEvent) -> void:
	if not picker_mode:
		return

	# Handle escape to cancel picker mode
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		exit_picker_mode()
		get_viewport().set_input_as_handled()
		return

	# Handle left click to pick
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var mouse_pos: Vector2 = event.position
		_do_pick(mouse_pos)
		get_viewport().set_input_as_handled()


## Set the camera to use for raycasting
func set_camera(cam: Camera3D) -> void:
	_camera = cam
	if cam:
		_viewport = cam.get_viewport()


## Enter picker mode (next click will select)
func enter_picker_mode() -> void:
	if picker_mode:
		return

	picker_mode = true
	Input.set_default_cursor_shape(Input.CURSOR_CROSS)
	picker_mode_entered.emit()


## Exit picker mode
func exit_picker_mode() -> void:
	if not picker_mode:
		return

	picker_mode = false
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)
	picker_mode_exited.emit()


## Clear current selection
func clear_selection() -> void:
	_remove_outline()
	current_selection = null
	selection_cleared.emit()


## Select a specific node directly (without picking)
func select_node(node: Node3D) -> void:
	if not node:
		clear_selection()
		return

	var selection := _create_selection_from_node(node, node.global_position)
	_set_selection(selection)


## Perform a pick at the given screen position
func _do_pick(screen_pos: Vector2) -> void:
	if not _camera or not _camera.is_inside_tree():
		push_warning("ObjectPicker: No camera set or camera not in tree")
		exit_picker_mode()
		return

	# Get ray from camera through screen point
	var ray_origin := _camera.project_ray_origin(screen_pos)
	var ray_dir := _camera.project_ray_normal(screen_pos)
	var ray_end := ray_origin + ray_dir * max_distance

	# Perform raycast
	var space_state := _camera.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_end, collision_mask)
	query.collide_with_areas = true
	query.collide_with_bodies = true

	var result := space_state.intersect_ray(query)

	if result.is_empty():
		# No hit - clear selection and exit picker mode
		clear_selection()
		exit_picker_mode()
		return

	# Got a hit
	var hit_node: Node3D = result.collider
	var hit_pos: Vector3 = result.position

	# Resolve the actual object (might be a collision shape child)
	var target_node := _resolve_target_node(hit_node)

	# Create selection
	var selection := _create_selection_from_node(target_node, hit_pos)
	_set_selection(selection)

	exit_picker_mode()


## Resolve a collision node to its parent object
func _resolve_target_node(node: Node3D) -> Node3D:
	if not node:
		return null

	# Walk up to find the mesh/object root
	# Skip collision shapes, rigid bodies, etc. to find the visual root
	var current := node

	while current:
		# If this node has metadata about being a cell object, use it
		if current.has_meta("cell_ref_id") or current.has_meta("form_id"):
			return current

		# If this is a MeshInstance3D with a meaningful parent, might be the target
		if current is MeshInstance3D:
			var parent := current.get_parent()
			if parent and parent is Node3D:
				# Check if parent is a cell object container
				if parent.has_meta("cell_ref_id") or parent.has_meta("form_id"):
					return parent
				# Otherwise the mesh itself is the target
				return current

		# Check parent
		var parent := current.get_parent()
		if parent and parent is Node3D:
			# Stop at cell containers (nodes with many cell objects)
			if parent.name.begins_with("Cell_") or parent.name == "Objects":
				return current
			current = parent
		else:
			break

	return node


## Create a Selection object from a picked node
func _create_selection_from_node(node: Node3D, hit_pos: Vector3) -> Selection:
	var sel := Selection.new()
	sel.node = node
	sel.hit_position = hit_pos
	sel.world_transform = node.global_transform

	# Try to resolve identity from metadata
	if node.has_meta("form_id"):
		sel.form_id = str(node.get_meta("form_id"))
	elif not node.name.is_empty():
		# Use node name as fallback (often contains the record ID)
		sel.form_id = node.name

	if node.has_meta("record_type"):
		sel.record_type = str(node.get_meta("record_type"))

	if node.has_meta("model_path"):
		sel.model_path = str(node.get_meta("model_path"))

	if node.has_meta("cell_name"):
		sel.cell_name = str(node.get_meta("cell_name"))

	if node.has_meta("cell_grid"):
		var grid = node.get_meta("cell_grid")
		if grid is Vector2i:
			sel.cell_grid = grid

	if node.has_meta("is_interior"):
		sel.is_interior = bool(node.get_meta("is_interior"))

	if node.has_meta("instance_id"):
		sel.instance_id = int(node.get_meta("instance_id"))

	# Try to find cell reference in parent chain
	var parent := node.get_parent()
	while parent:
		if parent.has_meta("cell_name") and sel.cell_name.is_empty():
			sel.cell_name = str(parent.get_meta("cell_name"))
		if parent.has_meta("cell_grid") and sel.cell_grid == Vector2i.ZERO:
			var grid = parent.get_meta("cell_grid")
			if grid is Vector2i:
				sel.cell_grid = grid
		if parent.has_meta("is_interior"):
			sel.is_interior = bool(parent.get_meta("is_interior"))
		parent = parent.get_parent()

	# If still no form_id, try to extract from node name
	if sel.form_id.is_empty() or sel.form_id == node.name:
		# Node names often look like "flora_tree_ai_01" or "flora_tree_ai_01_123"
		# Try to clean up instance suffixes
		var clean_name := node.name
		# Remove numeric suffix if present (e.g., "_123" -> "")
		var regex := RegEx.new()
		regex.compile("_\\d+$")
		clean_name = regex.sub(clean_name, "")
		sel.form_id = clean_name

	return sel


## Set the current selection and apply outline
func _set_selection(selection: Selection) -> void:
	# Remove old outline first
	_remove_outline()

	current_selection = selection

	# Apply outline to new selection
	if selection and selection.node:
		_apply_outline(selection.node)

	object_selected.emit(selection)


## Setup the outline shader material
func _setup_outline_material() -> void:
	_outline_material = ShaderMaterial.new()

	# Load outline shader from file
	var shader := load("res://src/core/console/shaders/selection_outline.gdshader") as Shader
	if shader:
		_outline_material.shader = shader
	else:
		# Fallback: create inline shader if file not found
		shader = Shader.new()
		shader.code = """
shader_type spatial;
render_mode unshaded, cull_front;

uniform vec4 outline_color : source_color = vec4(1.0, 0.8, 0.0, 1.0);
uniform float outline_width : hint_range(0.0, 0.1) = 0.02;

void vertex() {
	VERTEX += NORMAL * outline_width;
}

void fragment() {
	ALBEDO = outline_color.rgb;
	ALPHA = outline_color.a;
}
"""
		_outline_material.shader = shader

	# Configure shader parameters
	_outline_material.set_shader_parameter("outline_color", Color(1.0, 0.7, 0.0, 1.0))  # Golden yellow
	_outline_material.set_shader_parameter("outline_width", 0.015)
	_outline_material.set_shader_parameter("pulse_speed", 2.0)
	_outline_material.set_shader_parameter("pulse_amount", 0.15)


## Apply outline effect to a node
func _apply_outline(node: Node3D) -> void:
	if not node or not _outline_material:
		return

	_outlined_node = node

	# Find all MeshInstance3D children and apply outline as next_pass
	var meshes := _find_mesh_instances(node)

	for mesh in meshes:
		if mesh.mesh:
			# Store original next_pass if any (we only track one for simplicity)
			if _original_next_pass == null and mesh.material_override:
				_original_next_pass = mesh.material_override.next_pass

			# Apply outline by duplicating and adding as next_pass
			# This preserves the original material while adding outline
			var surface_count := mesh.mesh.get_surface_count()
			for i in surface_count:
				var mat := mesh.get_active_material(i)
				if mat:
					mat = mat.duplicate()
					mat.next_pass = _outline_material
					mesh.set_surface_override_material(i, mat)


## Remove outline effect from currently outlined node
func _remove_outline() -> void:
	if not _outlined_node:
		return

	var meshes := _find_mesh_instances(_outlined_node)

	for mesh in meshes:
		# Clear surface override materials
		if mesh.mesh:
			var surface_count := mesh.mesh.get_surface_count()
			for i in surface_count:
				mesh.set_surface_override_material(i, null)

	_outlined_node = null
	_original_next_pass = null


## Find all MeshInstance3D nodes in a subtree
func _find_mesh_instances(node: Node3D) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []

	if node is MeshInstance3D:
		result.append(node)

	for child in node.get_children():
		if child is Node3D:
			result.append_array(_find_mesh_instances(child))

	return result


## Get a formatted info string for the current selection
func get_selection_info() -> String:
	if not current_selection:
		return "No selection"

	var sel := current_selection
	var lines: PackedStringArray = []

	lines.append("[%s] %s" % [sel.get_type_display(), sel.get_display_name()])
	lines.append("Position: %s" % sel.get_position_string())

	if not sel.cell_name.is_empty():
		lines.append("Cell: %s" % sel.get_cell_string())

	if not sel.model_path.is_empty():
		lines.append("Model: %s" % sel.model_path)

	return "\n".join(lines)
