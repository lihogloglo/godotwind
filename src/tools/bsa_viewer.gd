## BSA Viewer — Browse and inspect NIF models live from BSA archives (source data).
## For inspecting prebaked .res files in the disk cache, use baked_asset_viewer.tscn.
##
## Controls:
##   Left/Right    — Previous/next model
##   Up/Down       — Jump 10 models forward/back
##   Page Up/Down  — Jump 100 models forward/back
##   Home/End      — First/last model
##   R             — Reload current model
##   T             — Toggle textures on/off
##   C             — Toggle collision shapes visible
##   F             — Filter: cycle through mesh categories
##   RMB drag      — Orbit camera
##   Scroll        — Zoom in/out
##   Mouse wheel click — Reset camera
@tool
extends Node3D

@warning_ignore("untyped_declaration", "unsafe_method_access")

const NIFConverterScript := preload("res://src/core/nif/nif_converter.gd")

# All NIF paths from BSA
var _nif_paths: PackedStringArray = PackedStringArray()
var _filtered_paths: PackedStringArray = PackedStringArray()
var _current_index: int = 0

# Category filters
const CATEGORIES := ["all", "meshes\\a\\", "meshes\\b\\", "meshes\\c\\", "meshes\\d\\",
	"meshes\\e\\", "meshes\\f\\", "meshes\\g\\", "meshes\\h\\", "meshes\\i\\",
	"meshes\\l\\", "meshes\\m\\", "meshes\\n\\", "meshes\\o\\", "meshes\\p\\",
	"meshes\\r\\", "meshes\\s\\", "meshes\\t\\", "meshes\\v\\", "meshes\\w\\",
	"meshes\\x\\"]
var _category_index: int = 0

# Display state
var _current_model: Node3D = null
var _load_textures: bool = true
var _show_collision: bool = false
var _loading: bool = false

# Camera orbit
var _camera: Camera3D
var _yaw: float = 30.0
var _pitch: float = -20.0
var _distance: float = 5.0
var _orbit_center: Vector3 = Vector3.ZERO
var _orbiting: bool = false

# UI
var _info_label: RichTextLabel
var _status_label: Label

# Stats for current model
var _model_name: String = ""
var _vertex_count: int = 0
var _material_count: int = 0
var _mesh_count: int = 0
var _triangle_count: int = 0


func _ready() -> void:
	_create_environment()
	_create_ui()

	await get_tree().process_frame
	await get_tree().process_frame

	_set_status("Loading BSA archives...")
	await get_tree().process_frame

	await _ensure_data_loaded()

	_set_status("Building NIF file list...")
	await get_tree().process_frame

	_build_nif_list()
	_apply_filter()

	if _filtered_paths.size() > 0:
		_load_model(_current_index)
	else:
		_set_status("No NIF files found in BSA archives")


# =============================================================================
# DATA LOADING
# =============================================================================

func _ensure_data_loaded() -> void:
	if BSAManager.has_file("meshes\\xbase_anim.nif"):
		_set_status("BSA already loaded")
		return

	var data_path: String = SettingsManager.get_data_path()
	if data_path.is_empty():
		data_path = SettingsManager.auto_detect_installation()
	if data_path.is_empty():
		_set_status("[color=red]No Morrowind data path![/color]")
		return

	var count := BSAManager.load_archives_from_directory(data_path)
	_set_status("Loaded %d BSA archives" % count)
	await get_tree().process_frame


func _build_nif_list() -> void:
	var files: Array[Dictionary] = BSAManager.get_files_by_extension(".nif")
	_nif_paths.clear()
	for file_info: Dictionary in files:
		var path: String = file_info["path"]
		# Only include mesh NIFs (skip skeleton-only files like xbase_anim.nif)
		if path.to_lower().begins_with("meshes"):
			_nif_paths.append(path)
	_nif_paths.sort()
	Log.info("tools", "NIF Viewer: Found %d NIF files" % _nif_paths.size())


func _apply_filter() -> void:
	var category: String = CATEGORIES[_category_index]
	if category == "all":
		_filtered_paths = _nif_paths.duplicate()
	else:
		_filtered_paths.clear()
		for path: String in _nif_paths:
			if path.to_lower().begins_with(category):
				_filtered_paths.append(path)
	_current_index = 0


# =============================================================================
# MODEL LOADING
# =============================================================================

func _load_model(index: int) -> void:
	if _loading:
		return
	if _filtered_paths.is_empty():
		_set_status("No models in current filter")
		return

	_loading = true
	index = clampi(index, 0, _filtered_paths.size() - 1)
	_current_index = index

	var nif_path: String = _filtered_paths[_current_index]
	_model_name = nif_path
	_set_status("Loading: %s" % nif_path)
	await get_tree().process_frame

	# Remove old model
	if _current_model:
		_current_model.queue_free()
		_current_model = null
		await get_tree().process_frame

	# Extract from BSA
	var data: PackedByteArray = BSAManager.extract_file(nif_path)
	if data.is_empty():
		_set_status("[color=red]Failed to extract: %s[/color]" % nif_path)
		_loading = false
		return

	# Convert NIF to Node3D
	var converter := NIFConverterScript.new()
	converter.load_textures = _load_textures
	converter.load_animations = false
	converter.load_collision = _show_collision

	var model: Node3D = converter.convert_buffer(data, nif_path)
	if not model:
		_set_status("[color=red]Failed to convert: %s[/color]" % nif_path)
		_loading = false
		return

	_current_model = model
	add_child(model)

	# Center model and fit camera
	_gather_stats(model)
	_auto_frame_model(model)
	_update_info()
	_set_status("")
	_loading = false


func _gather_stats(node: Node3D) -> void:
	_vertex_count = 0
	_material_count = 0
	_mesh_count = 0
	_triangle_count = 0
	var materials_seen: Array[int] = []
	_gather_stats_recursive(node, materials_seen)
	_material_count = materials_seen.size()


func _gather_stats_recursive(node: Node, materials_seen: Array[int]) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node as MeshInstance3D
		if mi.mesh:
			_mesh_count += 1
			for surface_idx: int in mi.mesh.get_surface_count():
				var arrays := mi.mesh.surface_get_arrays(surface_idx)
				if arrays.size() > 0 and arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array:
					var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
					_vertex_count += verts.size()
				if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] is PackedInt32Array:
					var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
					_triangle_count += indices.size() / 3

			# Count unique materials
			var mat := mi.material_override
			if mat and mat.get_instance_id() not in materials_seen:
				materials_seen.append(mat.get_instance_id())
			for surface_idx: int in mi.mesh.get_surface_count():
				var smat := mi.mesh.surface_get_material(surface_idx)
				if smat and smat.get_instance_id() not in materials_seen:
					materials_seen.append(smat.get_instance_id())

	for child: Node in node.get_children():
		_gather_stats_recursive(child, materials_seen)


func _auto_frame_model(model: Node3D) -> void:
	var aabb := _get_combined_aabb(model)
	if aabb.size.length() < 0.001:
		_orbit_center = Vector3.ZERO
		_distance = 5.0
		return

	_orbit_center = aabb.get_center()
	# Fit camera so model fills ~60% of view
	var max_dim: float = maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
	_distance = max_dim * 1.8
	_distance = clampf(_distance, 1.0, 200.0)


func _get_combined_aabb(node: Node3D) -> AABB:
	var result := AABB()
	var first := true
	_collect_aabb(node, result, first)
	return result


func _collect_aabb(node: Node, result: AABB, first: bool) -> AABB:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node as MeshInstance3D
		if mi.mesh:
			var mesh_aabb: AABB = mi.mesh.get_aabb()
			var global_aabb := mi.global_transform * mesh_aabb
			if first:
				result = global_aabb
				first = false
			else:
				result = result.merge(global_aabb)

	for child: Node in node.get_children():
		result = _collect_aabb(child, result, first)
		if result.size.length() > 0.001:
			first = false

	return result


# =============================================================================
# ENVIRONMENT
# =============================================================================

func _create_environment() -> void:
	_camera = Camera3D.new()
	_camera.current = true
	_camera.far = 500.0
	add_child(_camera)

	# Key light
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 30, 0)
	light.light_energy = 1.3
	light.shadow_enabled = true
	add_child(light)

	# Fill light
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-30, -120, 0)
	fill.light_energy = 0.4
	fill.light_color = Color(0.8, 0.85, 1.0)
	add_child(fill)

	# Environment
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.15, 0.15, 0.2)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.5, 0.55)
	env.ambient_light_energy = 0.8
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	# Ground grid reference
	var grid := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(20, 20)
	grid.mesh = plane
	var grid_mat := StandardMaterial3D.new()
	grid_mat.albedo_color = Color(0.12, 0.12, 0.14)
	grid.material_override = grid_mat
	grid.position.y = -0.01
	add_child(grid)


# =============================================================================
# UI
# =============================================================================

func _create_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "UI"
	add_child(canvas)

	# Info panel (top-left)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.offset_left = 10
	panel.offset_top = 10
	panel.offset_right = 460
	panel.offset_bottom = 300

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.75)
	style.content_margin_left = 10
	style.content_margin_top = 10
	style.content_margin_right = 10
	style.content_margin_bottom = 10
	style.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", style)

	_info_label = RichTextLabel.new()
	_info_label.bbcode_enabled = true
	_info_label.fit_content = true
	_info_label.custom_minimum_size = Vector2(440, 280)
	_info_label.scroll_active = false
	panel.add_child(_info_label)
	canvas.add_child(panel)

	# Status label (bottom-center)
	_status_label = Label.new()
	_status_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_status_label.offset_top = -40
	_status_label.offset_bottom = -10
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 16)
	canvas.add_child(_status_label)


func _set_status(text: String) -> void:
	if _status_label:
		# Strip bbcode for plain label
		var stripped := text
		for tag: String in ["[color=green]", "[color=red]", "[color=yellow]", "[color=cyan]", "[/color]", "[b]", "[/b]"]:
			stripped = stripped.replace(tag, "")
		_status_label.text = stripped
	if text.length() > 0:
		Log.info("tools", "[NIFViewer] %s" % text)


func _update_info() -> void:
	if not _info_label:
		return

	var lines := PackedStringArray()
	lines.append("[b]NIF Viewer[/b]")
	lines.append("===========================")
	lines.append("")

	# Filter info
	var cat_name: String = CATEGORIES[_category_index]
	if cat_name == "all":
		cat_name = "ALL"
	else:
		cat_name = cat_name.trim_suffix("\\")
	lines.append("Filter: [color=cyan]%s[/color]  (%d models)" % [cat_name, _filtered_paths.size()])

	# Model info
	if _filtered_paths.size() > 0:
		lines.append("Index: [color=cyan]%d / %d[/color]" % [_current_index + 1, _filtered_paths.size()])
		lines.append("")
		lines.append("[color=yellow]%s[/color]" % _model_name)
		lines.append("")
		lines.append("Meshes:    %d" % _mesh_count)
		lines.append("Vertices:  %s" % _format_number(_vertex_count))
		lines.append("Triangles: %s" % _format_number(_triangle_count))
		lines.append("Materials: %d" % _material_count)
	else:
		lines.append("[color=red]No models in this category[/color]")

	# Options
	lines.append("")
	lines.append("Textures: %s" % ("[color=green]ON[/color]" if _load_textures else "[color=red]OFF[/color]"))
	lines.append("Collision: %s" % ("[color=green]ON[/color]" if _show_collision else "[color=red]OFF[/color]"))

	# Controls
	lines.append("")
	lines.append("[color=gray][Left/Right] Prev/Next  [Up/Down] ±10[/color]")
	lines.append("[color=gray][PgUp/PgDn] ±100  [Home/End] First/Last[/color]")
	lines.append("[color=gray][T] Textures  [C] Collision  [F] Filter  [R] Reload[/color]")
	lines.append("[color=gray][RMB] Orbit  [Scroll] Zoom  [MMB] Reset[/color]")

	_info_label.text = "\n".join(lines)


func _format_number(n: int) -> String:
	if n < 1000:
		return str(n)
	elif n < 1_000_000:
		return "%.1fK" % (n / 1000.0)
	else:
		return "%.2fM" % (n / 1_000_000.0)


# =============================================================================
# CAMERA
# =============================================================================

func _update_camera() -> void:
	var ry := deg_to_rad(_yaw)
	var rp := deg_to_rad(_pitch)
	var offset := Vector3(
		_distance * cos(rp) * sin(ry),
		_distance * sin(rp),
		_distance * cos(rp) * cos(ry)
	)
	_camera.global_position = _orbit_center + offset
	_camera.look_at(_orbit_center)


func _process(_delta: float) -> void:
	_update_camera()


# =============================================================================
# INPUT
# =============================================================================

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_LEFT:
				_navigate(-1)
			KEY_RIGHT:
				_navigate(1)
			KEY_UP:
				_navigate(-10)
			KEY_DOWN:
				_navigate(10)
			KEY_PAGEUP:
				_navigate(-100)
			KEY_PAGEDOWN:
				_navigate(100)
			KEY_HOME:
				_load_model(0)
			KEY_END:
				_load_model(_filtered_paths.size() - 1)
			KEY_R:
				_load_model(_current_index)
			KEY_T:
				_load_textures = not _load_textures
				_load_model(_current_index)
			KEY_C:
				_show_collision = not _show_collision
				_load_model(_current_index)
			KEY_F:
				_cycle_filter()

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_orbiting = event.pressed
		elif event.button_index == MOUSE_BUTTON_MIDDLE and event.pressed:
			_yaw = 30.0
			_pitch = -20.0
			if _current_model:
				_auto_frame_model(_current_model)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_distance = maxf(0.5, _distance * 0.85)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_distance = minf(500.0, _distance * 1.18)
	elif event is InputEventMouseMotion and _orbiting:
		_yaw -= event.relative.x * 0.3
		_pitch = clampf(_pitch - event.relative.y * 0.3, -89.0, 89.0)


func _navigate(offset: int) -> void:
	if _filtered_paths.is_empty():
		return
	var new_idx := clampi(_current_index + offset, 0, _filtered_paths.size() - 1)
	if new_idx != _current_index:
		_load_model(new_idx)


func _cycle_filter() -> void:
	# Find next non-empty category
	var start := _category_index
	for i: int in CATEGORIES.size():
		_category_index = (_category_index + 1) % CATEGORIES.size()
		_apply_filter()
		if _filtered_paths.size() > 0 or _category_index == 0:
			break
	# If we looped back, ensure we have the full list
	if _filtered_paths.is_empty():
		_category_index = 0
		_apply_filter()

	_update_info()
	if _filtered_paths.size() > 0:
		_load_model(0)
