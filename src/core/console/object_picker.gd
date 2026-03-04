## Object Picker - Click-to-select objects in the 3D world
##
## Uses AABB-based mesh proximity to camera ray (no physics/collision needed).
## When the console is open, hovering shows a tooltip; clicking selects.
##
## Features:
## - AABB-based object picking (works without collision shapes)
## - Hover tooltip when console is visible
## - Click-to-select
## - Selection outline rendering
## - Identity chain resolution (Node3D -> cell metadata)
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

## Emitted when hover target changes (for external tooltip consumers)
signal hover_changed(node: Node3D)

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

## Maximum pick distance
@export var max_distance: float = 500.0

## Angular threshold for pick cone (radians). ~5 degrees.
const PICK_CONE_RAD := 0.087

## Hover update interval (seconds) — throttle to avoid per-frame mesh iteration
const HOVER_INTERVAL := 0.1

#endregion


#region State

## Current selection (null if nothing selected)
var current_selection: Selection = null

## Whether picker mode is active (legacy: waiting for click after typing 'select')
var picker_mode: bool = false

## Whether hover tracking is active (auto-enabled when console is visible)
var hover_enabled: bool = false

## Currently hovered object root node
var _hover_node: Node3D = null

## Reference to the camera to use for picking
var _camera: Camera3D = null

## Callable that returns an Array of Node3D cell containers to search
## Set via set_cell_provider()
var _cell_provider: Callable = Callable()

## Reference to the console panel (to dynamically check its rect)
var _console_panel: Control = null

## Selection outline material
var _outline_material: ShaderMaterial = null

## Currently outlined node (for cleanup)
var _outlined_node: Node3D = null

## Hover tooltip label
var _tooltip_layer: CanvasLayer = null
var _tooltip_panel: PanelContainer = null
var _tooltip_label: Label = null

## Hover throttle timer
var _hover_timer: float = 0.0

## Regex for cleaning node name suffixes (cached)
var _suffix_regex: RegEx = null

#endregion


func _ready() -> void:
	_setup_outline_material()
	_setup_tooltip()
	_suffix_regex = RegEx.new()
	_suffix_regex.compile("_\\d+$")


func _process(delta: float) -> void:
	if not hover_enabled and not picker_mode:
		return
	if not _camera or not _camera.is_inside_tree():
		return

	_hover_timer += delta
	if _hover_timer < HOVER_INTERVAL:
		return
	_hover_timer = 0.0

	var mouse_pos := _camera.get_viewport().get_mouse_position()

	# Don't pick if mouse is inside console panel
	if _console_panel and _console_panel.visible:
		var rect := Rect2(_console_panel.global_position, _console_panel.size)
		if rect.has_point(mouse_pos):
			_set_hover(null)
			return

	# Cast ray from mouse through camera
	var result := _pick_mesh_at(mouse_pos)
	_set_hover(result)


func _input(event: InputEvent) -> void:
	# Legacy picker mode: escape cancels
	if picker_mode:
		if event is InputEventKey:
			var key: InputEventKey = event as InputEventKey
			if key.pressed and key.keycode == KEY_ESCAPE:
				exit_picker_mode()
				get_viewport().set_input_as_handled()
				return

	# Click-to-select: works in both picker_mode and hover_enabled
	if (picker_mode or hover_enabled) and event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			# Don't pick if mouse is inside console panel
			if _console_panel and _console_panel.visible:
				var rect := Rect2(_console_panel.global_position, _console_panel.size)
				if rect.has_point(mb.position):
					return

			var target := _pick_mesh_at(mb.position)
			if target:
				var obj_root := _resolve_object_root(target)
				var selection := _create_selection_from_node(obj_root, target.global_position)
				_set_selection(selection)
				get_viewport().set_input_as_handled()
			elif picker_mode:
				# Only clear on miss in explicit picker mode
				clear_selection()
				get_viewport().set_input_as_handled()

			if picker_mode:
				exit_picker_mode()


#region Public API

## Set the camera to use for picking
func set_camera(cam: Camera3D) -> void:
	_camera = cam


## Set a callable that returns Array of Node3D cell containers to search
## Signature: func() -> Array (of Node3D)
func set_cell_provider(provider: Callable) -> void:
	_cell_provider = provider


## Set the console panel Control to avoid picking inside it
func set_console_panel(panel: Control) -> void:
	_console_panel = panel


## Enable/disable hover tracking
func set_hover_enabled(enabled: bool) -> void:
	hover_enabled = enabled
	if not enabled:
		_set_hover(null)


## Enter picker mode (legacy: next click will select)
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

#endregion


#region AABB-based Mesh Picking

## Pick the best MeshInstance3D at the given screen position using AABB proximity
func _pick_mesh_at(screen_pos: Vector2) -> MeshInstance3D:
	if not _camera or not _cell_provider.is_valid():
		return null

	var ray_origin := _camera.project_ray_origin(screen_pos)
	var ray_dir := _camera.project_ray_normal(screen_pos)

	# Dictionary holds mutable best result (GDScript primitives are pass-by-value)
	var best: Dictionary = {"node": null, "score": INF}

	var cells: Array = _cell_provider.call()
	for cell: Variant in cells:
		if cell is Node3D:
			_find_best_mesh(cell as Node3D, ray_origin, ray_dir, best)

	return best.node as MeshInstance3D


## Recursively find the MeshInstance3D closest to the camera ray
func _find_best_mesh(node: Node, origin: Vector3, dir: Vector3, best: Dictionary) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.visible and mi.mesh:
			var center := mi.global_transform.origin
			var local_center := mi.get_aabb().get_center()
			if local_center != Vector3.ZERO:
				center = mi.global_transform * local_center

			var to_mesh := center - origin
			var along := to_mesh.dot(dir)
			if along > 0.5 and along < max_distance:
				var closest_on_ray := origin + dir * along
				var perp_dist := center.distance_to(closest_on_ray)
				var angular := perp_dist / along if along > 0.0 else INF
				# Bias toward closer objects (distance weight)
				var score := angular * (1.0 + along / max_distance)
				if angular < PICK_CONE_RAD and score < best.score:
					best.node = mi
					best.score = score

	for child in node.get_children():
		_find_best_mesh(child, origin, dir, best)

#endregion


#region Hover & Tooltip

func _setup_tooltip() -> void:
	_tooltip_layer = CanvasLayer.new()
	_tooltip_layer.layer = 110  # Above console (100)
	add_child(_tooltip_layer)

	_tooltip_panel = PanelContainer.new()
	_tooltip_panel.visible = false
	_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.08, 0.9)
	style.border_color = Color(1.0, 0.7, 0.0, 0.6)
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 3
	style.content_margin_bottom = 3
	_tooltip_panel.add_theme_stylebox_override("panel", style)

	_tooltip_label = Label.new()
	_tooltip_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.5, 1.0))
	_tooltip_label.add_theme_font_size_override("font_size", 13)
	_tooltip_panel.add_child(_tooltip_label)

	_tooltip_layer.add_child(_tooltip_panel)


func _set_hover(mesh: MeshInstance3D) -> void:
	var obj_root: Node3D = _resolve_object_root(mesh) if mesh else null

	if obj_root == _hover_node:
		# Same object — just update tooltip position
		if _tooltip_panel.visible:
			_update_tooltip_position()
		return

	_hover_node = obj_root

	if obj_root:
		var display_name := _get_object_display_name(obj_root)
		var dist := _camera.global_position.distance_to(obj_root.global_position)
		_tooltip_label.text = "%s  (%.0fm)" % [display_name, dist]
		_tooltip_panel.visible = true
		_update_tooltip_position()
	else:
		_tooltip_panel.visible = false

	hover_changed.emit(obj_root)


func _update_tooltip_position() -> void:
	if not _camera:
		return
	var mouse_pos := _camera.get_viewport().get_mouse_position()
	# Offset to bottom-right of cursor
	_tooltip_panel.position = mouse_pos + Vector2(16, 16)
	# Clamp to viewport
	var vp_size := _camera.get_viewport().get_visible_rect().size
	var panel_size := _tooltip_panel.size
	if _tooltip_panel.position.x + panel_size.x > vp_size.x:
		_tooltip_panel.position.x = mouse_pos.x - panel_size.x - 8
	if _tooltip_panel.position.y + panel_size.y > vp_size.y:
		_tooltip_panel.position.y = mouse_pos.y - panel_size.y - 8


func _get_object_display_name(node: Node3D) -> String:
	if node.has_meta("form_id"):
		return str(node.get_meta("form_id"))
	if node.has_meta("cell_ref_id"):
		return str(node.get_meta("cell_ref_id"))
	# Clean up node name (remove instance suffixes like _123)
	var clean_name: String = node.name
	if _suffix_regex:
		clean_name = _suffix_regex.sub(clean_name, "")
	return clean_name

#endregion


#region Node Resolution

## Walk up from a MeshInstance3D to find the object root (the node with cell metadata)
func _resolve_object_root(node: Node3D) -> Node3D:
	if not node:
		return null

	var current := node
	while current:
		if current.has_meta("cell_ref_id") or current.has_meta("form_id"):
			return current

		if current is MeshInstance3D:
			var parent := current.get_parent()
			if parent and parent is Node3D:
				if parent.has_meta("cell_ref_id") or parent.has_meta("form_id"):
					return parent

		var parent := current.get_parent()
		if parent and parent is Node3D:
			# Stop at cell containers
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

	# Resolve identity from metadata
	if node.has_meta("form_id"):
		sel.form_id = str(node.get_meta("form_id"))
	elif not node.name.is_empty():
		sel.form_id = node.name

	if node.has_meta("record_type"):
		sel.record_type = str(node.get_meta("record_type"))
	if node.has_meta("model_path"):
		sel.model_path = str(node.get_meta("model_path"))
	if node.has_meta("cell_name"):
		sel.cell_name = str(node.get_meta("cell_name"))

	if node.has_meta("cell_grid"):
		var grid: Variant = node.get_meta("cell_grid")
		if grid is Vector2i:
			sel.cell_grid = grid

	if node.has_meta("is_interior"):
		var is_int_val: Variant = node.get_meta("is_interior")
		if is_int_val is bool:
			sel.is_interior = is_int_val
		elif is_int_val is int:
			sel.is_interior = is_int_val != 0

	if node.has_meta("instance_id"):
		var inst_id_val: Variant = node.get_meta("instance_id")
		if inst_id_val is int:
			sel.instance_id = inst_id_val
		elif inst_id_val is float:
			sel.instance_id = int(inst_id_val as float)

	# Walk up for cell info
	var parent := node.get_parent()
	while parent:
		if parent.has_meta("cell_name") and sel.cell_name.is_empty():
			sel.cell_name = str(parent.get_meta("cell_name"))
		if parent.has_meta("cell_grid") and sel.cell_grid == Vector2i.ZERO:
			var grid: Variant = parent.get_meta("cell_grid")
			if grid is Vector2i:
				sel.cell_grid = grid
		if parent.has_meta("is_interior"):
			var is_int_val: Variant = parent.get_meta("is_interior")
			if is_int_val is bool:
				sel.is_interior = is_int_val
			elif is_int_val is int:
				sel.is_interior = is_int_val != 0
		parent = parent.get_parent()

	# Clean up form_id from node name
	if sel.form_id.is_empty() or sel.form_id == node.name:
		var clean_name: String = node.name
		if _suffix_regex:
			clean_name = _suffix_regex.sub(clean_name, "")
		sel.form_id = clean_name

	return sel

#endregion


#region Selection Outline

## Set the current selection and apply outline
func _set_selection(selection: Selection) -> void:
	_remove_outline()
	current_selection = selection
	if selection and selection.node:
		_apply_outline(selection.node)
	object_selected.emit(selection)


func _setup_outline_material() -> void:
	_outline_material = ShaderMaterial.new()

	var shader := load("res://src/core/console/shaders/selection_outline.gdshader") as Shader
	if shader:
		_outline_material.shader = shader
	else:
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

	_outline_material.set_shader_parameter("outline_color", Color(1.0, 0.7, 0.0, 1.0))
	_outline_material.set_shader_parameter("outline_width", 0.015)
	_outline_material.set_shader_parameter("pulse_speed", 2.0)
	_outline_material.set_shader_parameter("pulse_amount", 0.15)


func _apply_outline(node: Node3D) -> void:
	if not node or not _outline_material:
		return
	_outlined_node = node
	var meshes := _find_mesh_instances(node)
	for mesh in meshes:
		if mesh.mesh:
			# Save original surface overrides before replacing
			var orig_mats: Array[Material] = []
			var surface_count := mesh.mesh.get_surface_count()
			for i in surface_count:
				orig_mats.append(mesh.get_surface_override_material(i))
			mesh.set_meta("_picker_orig_mats", orig_mats)

			for i in surface_count:
				var mat := mesh.get_active_material(i)
				if mat:
					mat = mat.duplicate()
					mat.next_pass = _outline_material
					mesh.set_surface_override_material(i, mat)


func _remove_outline() -> void:
	if not _outlined_node:
		return
	if not is_instance_valid(_outlined_node):
		_outlined_node = null
		return
	var meshes := _find_mesh_instances(_outlined_node)
	for mesh in meshes:
		if mesh.mesh:
			# Restore original surface overrides
			var orig_mats: Variant = mesh.get_meta("_picker_orig_mats", null)
			var surface_count := mesh.mesh.get_surface_count()
			if orig_mats is Array:
				var mats: Array = orig_mats
				for i in surface_count:
					mesh.set_surface_override_material(i, mats[i] if i < mats.size() else null)
			else:
				for i in surface_count:
					mesh.set_surface_override_material(i, null)
			mesh.remove_meta("_picker_orig_mats")
	_outlined_node = null


func _find_mesh_instances(node: Node3D) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		result.append(node)
	for child in node.get_children():
		if child is Node3D:
			result.append_array(_find_mesh_instances(child as Node3D))
	return result

#endregion
