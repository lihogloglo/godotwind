## NIFProvider - Asset provider for NIF mesh files from BSA archives
##
## Loads and displays Morrowind NIF meshes with:
## - Full BSA archive browsing
## - Texture loading
## - Animation support (KF files)
## - Collision visualization
@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_cast", "unsafe_call_argument")
class_name NIFProvider
extends AssetProvider

# Preload dependencies
const NIFReaderScript := preload("res://src/core/nif/nif_reader.gd")
const NIFConverterScript := preload("res://src/core/nif/nif_converter.gd")
const NIFKFLoaderScript := preload("res://src/core/nif/nif_kf_loader.gd")
const BSAReaderScript := preload("res://src/core/bsa/bsa_reader.gd")
const TextureLoaderScript := preload("res://src/core/texture/texture_loader.gd")

# BSA data
var _bsa_readers: Array[BSAReader] = []
var _bsa_file_index: Dictionary = {}  # normalized_path -> {reader, entry}
var _all_nif_paths: Array[String] = []

# Category filters (path patterns)
const CATEGORY_FILTERS := {
	"flora": ["flora_", "\\f\\flora"],
	"architecture": ["\\x\\ex_", "\\x\\in_", "_wall_", "_floor_", "_door_", "_pillar_"],
	"furniture": ["furn_", "\\f\\furn"],
	"containers": ["contain_", "chest", "barrel", "crate", "sack", "urn"],
	"npcs": ["\\b\\b_", "\\r\\", "body_"],
	"creatures": ["\\c\\", "creature_", "anim_"],
}

# Last loaded item info for tabs
var _last_converter: NIFConverter = null
var _last_node: Node3D = null
var _last_item: Dictionary = {}

# Collision visualization
var _show_collision: bool = false
var _collision_nodes: Array[Node3D] = []


func _init() -> void:
	provider_name = "NIF Meshes"


func initialize() -> Error:
	loading_started.emit()

	var data_path := SettingsManager.get_data_path()
	if data_path.is_empty():
		data_path = SettingsManager.auto_detect_installation()

	if data_path.is_empty():
		loading_failed.emit("Morrowind data path not found")
		return ERR_FILE_NOT_FOUND

	_log("Loading BSA archives from: %s" % data_path)
	_progress(0, 100, "Scanning for BSA files...")

	# Find BSA files
	var dir := DirAccess.open(data_path)
	if dir == null:
		loading_failed.emit("Cannot open directory: %s" % data_path)
		return ERR_CANT_OPEN

	var bsa_files: Array[String] = []
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.to_lower().ends_with(".bsa"):
			bsa_files.append(data_path.path_join(file_name))
		file_name = dir.get_next()
	dir.list_dir_end()

	if bsa_files.is_empty():
		loading_failed.emit("No BSA files found in: %s" % data_path)
		return ERR_FILE_NOT_FOUND

	# Load each BSA
	var total_files := 0
	for i in bsa_files.size():
		var bsa_path: String = bsa_files[i]
		_progress(i * 100 / bsa_files.size(), 100, "Loading %s..." % bsa_path.get_file())

		var reader := BSAReaderScript.new()
		var result := reader.open(bsa_path)
		if result == OK:
			_bsa_readers.append(reader)
			var file_count := reader.get_file_count()
			total_files += file_count
			_log("  Loaded: %s (%d files)" % [bsa_path.get_file(), file_count])

			# Index files
			for entry: BSAReader.FileEntry in reader.get_file_list():
				var normalized: String = entry.name.to_lower().replace("/", "\\")
				_bsa_file_index[normalized] = {"reader": reader, "entry": entry}

				if normalized.ends_with(".nif"):
					_all_nif_paths.append(normalized)
		else:
			_log("[color=yellow]  Failed to load: %s[/color]" % bsa_path.get_file())

		# Also load into BSAManager for texture loading
		BSAManager.load_archive(bsa_path)

	_all_nif_paths.sort()

	_log("[color=green]Loaded %d BSA archives with %d files[/color]" % [_bsa_readers.size(), total_files])
	_log("  NIF meshes available: %d" % _all_nif_paths.size())

	loading_completed.emit()
	return OK


func is_ready() -> bool:
	return not _bsa_readers.is_empty()


func get_categories() -> Array[String]:
	var cats: Array[String] = []
	for key: String in CATEGORY_FILTERS.keys():
		cats.append(key)
	return cats


func get_items() -> Array[Dictionary]:
	var items: Array[Dictionary] = []

	for path in _all_nif_paths:
		var category := _categorize_path(path)
		items.append({
			"id": path,
			"name": path.get_file(),
			"category": category,
			"tooltip": path,
			"path": path
		})

	return items


func _categorize_path(path: String) -> String:
	for cat: String in CATEGORY_FILTERS:
		var patterns: Array = CATEGORY_FILTERS[cat]
		for pattern: String in patterns:
			if path.find(pattern) >= 0:
				return cat
	return ""


func load_item(item: Dictionary) -> Node3D:
	var nif_path: String = item.get("path", item.get("id", ""))
	if nif_path.is_empty():
		return null

	var normalized: String = nif_path.to_lower().replace("/", "\\")

	if not _bsa_file_index.has(normalized):
		_log("[color=red]Error: File not found in BSA: %s[/color]" % nif_path)
		return null

	var cached: Dictionary = _bsa_file_index[normalized]
	var reader: BSAReader = cached["reader"]
	var entry: BSAReader.FileEntry = cached["entry"] as BSAReader.FileEntry

	_log("Extracting: %s (%d bytes)" % [entry.name, entry.size])

	# Extract NIF data
	var nif_data: PackedByteArray = reader.extract_file_entry(entry)
	if nif_data.is_empty():
		_log("[color=red]Error: Failed to extract file data[/color]")
		return null

	# Parse NIF
	var nif_reader := NIFReaderScript.new()
	nif_reader.debug_mode = false
	var parse_result := nif_reader.load_buffer(nif_data)
	if parse_result != OK:
		_log("[color=red]Error: Failed to parse NIF: %s[/color]" % error_string(parse_result))
		return null

	_log("  Parsed NIF: version=%s, records=%d" % [nif_reader.get_version_string(), nif_reader.get_num_records()])

	# Convert to Godot scene
	var converter := NIFConverterScript.new()
	converter.load_animations = true
	var node := converter.convert_buffer(nif_data)
	if node == null:
		_log("[color=red]Error: Failed to convert NIF to Godot scene[/color]")
		return null

	# Try to load KF animations
	var skeleton := _find_skeleton(node)
	var anim_player := _find_animation_player(node)

	if skeleton and (anim_player == null or anim_player.get_animation_list().is_empty()):
		var kf_animations := _try_load_kf_animations(normalized, skeleton)
		if not kf_animations.is_empty():
			if anim_player == null:
				anim_player = AnimationPlayer.new()
				anim_player.name = "AnimationPlayer"
				node.add_child(anim_player)
				anim_player.owner = node

			var anim_lib := AnimationLibrary.new()
			for anim_name: String in kf_animations:
				var anim: Animation = kf_animations[anim_name]
				anim_lib.add_animation(anim_name, anim)
			anim_player.add_animation_library("", anim_lib)
			_log("  Loaded %d animations from .kf file" % kf_animations.size())

	# Play idle animation if available
	if anim_player:
		var anim_list := anim_player.get_animation_list()
		if not anim_list.is_empty():
			var anim_to_play: String = anim_list[0]
			for anim_name in ["Idle", "idle", "Idle1"]:
				if anim_name in anim_list:
					anim_to_play = anim_name
					break
			anim_player.play(anim_to_play)

	# Store for tabs
	_last_converter = converter
	_last_node = node
	_last_item = item

	_log("[color=green]Successfully loaded mesh![/color]")

	item_loaded.emit(node, converter.get_mesh_info())
	return node


func get_info_text(item: Dictionary) -> String:
	if _last_converter == null or _last_item.get("id") != item.get("id"):
		return "[b]Load the item to see info[/b]"

	var info := _last_converter.get_mesh_info()
	var text := "[b]NIF Info:[/b]\n"
	text += "  Path: %s\n" % item.get("path", "")
	text += "  Version: %s\n" % info.get("version", "unknown")
	text += "  Records: %d\n" % info.get("num_records", 0)
	text += "  Roots: %d\n" % info.get("num_roots", 0)

	text += "\n[b]Geometry:[/b]\n"
	text += "  Nodes: %d\n" % info.get("nodes", 0)
	text += "  Meshes: %d\n" % info.get("meshes", 0)
	text += "  Vertices: %d\n" % info.get("total_vertices", 0)
	text += "  Triangles: %d\n" % info.get("total_triangles", 0)

	var textures: Array = info.get("textures", [])
	if not textures.is_empty():
		text += "\n[b]Textures:[/b]\n"
		for tex: String in textures:
			text += "  %s\n" % tex

	# Texture cache stats
	var tex_stats := TextureLoaderScript.get_stats()
	text += "\n[b]Texture Cache:[/b]\n"
	text += "  Loaded: %d\n" % tex_stats.get("loaded", 0)
	text += "  Cached: %d\n" % tex_stats.get("cached", 0)
	text += "  Cache hits: %d\n" % tex_stats.get("cache_hits", 0)

	# Collision info
	var collision_info := _last_converter.get_collision_info()
	text += "\n[b]Collision:[/b]\n"
	text += "  Has collision: %s\n" % ("Yes" if collision_info.get("has_collision", false) else "No")
	text += "  Mode: %s\n" % collision_info.get("collision_mode", "none")
	text += "  Shapes: %d\n" % collision_info.get("collision_shape_count", 0)

	return text


func get_custom_tabs() -> Array[Dictionary]:
	return [
		{"name": "Collision", "build_func": _build_collision_tab},
		{"name": "Animations", "build_func": _build_animations_tab},
	]


func _build_collision_tab(container: Control, _item: Dictionary) -> void:
	var vbox := VBoxContainer.new()
	container.add_child(vbox)
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 8
	vbox.offset_top = 8
	vbox.offset_right = -8
	vbox.offset_bottom = -8

	var toggle := CheckBox.new()
	toggle.text = "Show Collision Shapes"
	toggle.button_pressed = _show_collision
	toggle.toggled.connect(func(pressed: bool) -> void:
		_show_collision = pressed
		_update_collision_display()
	)
	vbox.add_child(toggle)

	var info_label := Label.new()
	info_label.text = "Press C to toggle collision while viewing"
	info_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	vbox.add_child(info_label)


func _build_animations_tab(container: Control, _item: Dictionary) -> void:
	var vbox := VBoxContainer.new()
	container.add_child(vbox)
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 8
	vbox.offset_top = 8
	vbox.offset_right = -8
	vbox.offset_bottom = -8

	var anim_list := ItemList.new()
	anim_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(anim_list)

	var play_btn := Button.new()
	play_btn.text = "Play Selected"
	vbox.add_child(play_btn)

	# Populate animations
	if _last_node:
		var anim_player := _find_animation_player(_last_node)
		if anim_player:
			for anim_name in anim_player.get_animation_list():
				anim_list.add_item(anim_name)

			play_btn.pressed.connect(func() -> void:
				var selected := anim_list.get_selected_items()
				if not selected.is_empty():
					var name_to_play: String = anim_list.get_item_text(selected[0])
					anim_player.play(name_to_play)
			)

	if anim_list.item_count == 0:
		anim_list.add_item("(No animations)")
		play_btn.disabled = true


func _update_collision_display() -> void:
	# Clear existing
	for node in _collision_nodes:
		if is_instance_valid(node):
			node.queue_free()
	_collision_nodes.clear()

	if not _show_collision or not _last_node:
		return

	_create_collision_visuals(_last_node)


func _create_collision_visuals(node: Node) -> void:
	if node is CollisionShape3D:
		var debug_mesh := _create_shape_debug_mesh(node as CollisionShape3D)
		if debug_mesh:
			node.get_parent().add_child(debug_mesh)
			_collision_nodes.append(debug_mesh)

	for child in node.get_children():
		_create_collision_visuals(child)


func _create_shape_debug_mesh(coll_shape: CollisionShape3D) -> MeshInstance3D:
	if coll_shape.shape == null:
		return null

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.global_transform = coll_shape.global_transform

	var shape: Shape3D = coll_shape.shape
	if shape is BoxShape3D:
		var box := BoxMesh.new()
		box.size = (shape as BoxShape3D).size
		mesh_inst.mesh = box
	elif shape is SphereShape3D:
		var sphere := SphereMesh.new()
		sphere.radius = (shape as SphereShape3D).radius
		sphere.height = sphere.radius * 2.0
		mesh_inst.mesh = sphere
	elif shape is CapsuleShape3D:
		var cap := CapsuleMesh.new()
		cap.radius = (shape as CapsuleShape3D).radius
		cap.height = (shape as CapsuleShape3D).height
		mesh_inst.mesh = cap
	else:
		return null

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.0, 1.0, 0.0, 0.3)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh_inst.material_override = mat

	return mesh_inst


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var found := _find_animation_player(child)
		if found:
			return found
	return null


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found:
			return found
	return null


func _try_load_kf_animations(mesh_path: String, skeleton: Skeleton3D) -> Dictionary:
	var kf_paths: Array[String] = []

	if mesh_path.find("\\b\\") >= 0 or mesh_path.find("\\r\\") >= 0:
		kf_paths.append("meshes\\xbase_anim.kf")
		kf_paths.append("meshes\\xbase_anim_female.kf")
	elif mesh_path.find("\\c\\") >= 0:
		kf_paths.append(mesh_path.get_basename() + ".kf")
	else:
		kf_paths.append(mesh_path.get_basename() + ".kf")

	for kf_path in kf_paths:
		var normalized_kf := kf_path.to_lower().replace("/", "\\")
		if _bsa_file_index.has(normalized_kf):
			var cached: Dictionary = _bsa_file_index[normalized_kf]
			var reader: BSAReader = cached["reader"]
			var entry: BSAReader.FileEntry = cached["entry"]

			var kf_data: PackedByteArray = reader.extract_file_entry(entry)
			if kf_data.is_empty():
				continue

			var kf_loader := NIFKFLoaderScript.new()
			kf_loader.debug_mode = false
			var animations := kf_loader.load_kf_buffer(kf_data, skeleton)

			if not animations.is_empty():
				return animations

	return {}


func cleanup() -> void:
	_bsa_readers.clear()
	_bsa_file_index.clear()
	_all_nif_paths.clear()
	_last_converter = null
	_last_node = null
	_collision_nodes.clear()
