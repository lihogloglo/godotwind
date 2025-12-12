## NIF Viewer - Test tool to validate the BSA -> NIF -> Godot pipeline
## Loads meshes from BSA archives and displays them in 3D
extends Node3D

# Preload NIF reader/converter
const NIFReaderScript := preload("res://src/core/nif/nif_reader.gd")
const NIFConverterScript := preload("res://src/core/nif/nif_converter.gd")
const NIFKFLoaderScript := preload("res://src/core/nif/nif_kf_loader.gd")
const BSAReaderScript := preload("res://src/core/bsa/bsa_reader.gd")
const TextureLoaderScript := preload("res://src/core/texture/texture_loader.gd")

# UI references - Right panel
@onready var data_path_edit: LineEdit = $UI/Panel/VBox/DataPathEdit
@onready var load_bsa_button: Button = $UI/Panel/VBox/LoadBSAButton
@onready var nif_path_edit: LineEdit = $UI/Panel/VBox/NIFPathEdit
@onready var load_nif_button: Button = $UI/Panel/VBox/LoadNIFButton
@onready var stats_text: RichTextLabel = $UI/Panel/VBox/StatsText
@onready var log_text: RichTextLabel = $UI/Panel/VBox/LogText
@onready var mesh_container: Node3D = $MeshContainer
@onready var camera: Camera3D = $Camera3D

# Quick load buttons
@onready var door_btn: Button = $UI/Panel/VBox/QuickButtons/DoorBtn
@onready var chest_btn: Button = $UI/Panel/VBox/QuickButtons/ChestBtn
@onready var barrel_btn: Button = $UI/Panel/VBox/QuickButtons/BarrelBtn
@onready var tree_btn: Button = $UI/Panel/VBox/QuickButtons/TreeBtn
@onready var rock_btn: Button = $UI/Panel/VBox/QuickButtons/RockBtn
@onready var pillar_btn: Button = $UI/Panel/VBox/QuickButtons/PillarBtn

# UI references - Left panel (model browser)
@onready var search_edit: LineEdit = $UI/LeftPanel/VBox/SearchEdit
@onready var result_count_label: Label = $UI/LeftPanel/VBox/ResultCount
@onready var model_list: ItemList = $UI/LeftPanel/VBox/ModelList

# Category filter buttons
@onready var cat_all_btn: Button = $UI/LeftPanel/VBox/CategoryButtons/AllBtn
@onready var cat_flora_btn: Button = $UI/LeftPanel/VBox/CategoryButtons/FloraBtn
@onready var cat_arch_btn: Button = $UI/LeftPanel/VBox/CategoryButtons/ArchBtn
@onready var cat_furn_btn: Button = $UI/LeftPanel/VBox/CategoryButtons/FurnBtn
@onready var cat_contain_btn: Button = $UI/LeftPanel/VBox/CategoryButtons/ContainBtn
@onready var cat_npc_btn: Button = $UI/LeftPanel/VBox/CategoryButtons/NPCBtn
@onready var cat_creature_btn: Button = $UI/LeftPanel/VBox/CategoryButtons/CreatureBtn

# BSA archives
var _bsa_readers: Array[BSAReader] = []
var _bsa_file_index: Dictionary = {}  # normalized_path -> {reader, entry}

# Model browser
var _all_nif_paths: Array[String] = []  # All NIF paths from BSA
var _filtered_paths: Array[String] = []  # Currently filtered/displayed paths
var _current_category: String = ""  # Empty = all
var _search_timer: Timer = null
var _max_display_items: int = 500  # Limit items to avoid UI lag

# Camera orbit (spherical coordinates)
var _orbit_yaw: float = 0.0  # Horizontal angle (radians)
var _orbit_pitch: float = 0.3  # Vertical angle (radians), clamped to avoid gimbal lock
var _orbit_distance: float = 5.0
var _orbit_target: Vector3 = Vector3.ZERO  # Point to orbit around
var _orbit_speed: float = 0.5
var _auto_orbit: bool = true

# Quick load mesh paths (common Morrowind meshes - verified to exist)
const QUICK_MESHES := {
	"door": "meshes\\x\\ex_common_door_01.nif",
	"chest": "meshes\\m\\misc_com_chest_01.nif",
	"barrel": "meshes\\o\\contain_barrel_01.nif",
	"tree": "meshes\\f\\flora_tree_ai_01.nif",
	"rock": "meshes\\x\\ex_common_rock_01.nif",
	"pillar": "meshes\\x\\ex_hlaalu_pillar_01.nif",
}

# Collision visualization
var _show_collision: bool = false
var _collision_debug_nodes: Array[Node3D] = []

# Category filters (path patterns)
const CATEGORY_FILTERS := {
	"flora": ["flora_", "\\f\\flora"],
	"arch": ["\\x\\ex_", "\\x\\in_", "_wall_", "_floor_", "_door_", "_pillar_"],
	"furn": ["furn_", "\\f\\furn"],
	"contain": ["contain_", "chest", "barrel", "crate", "sack", "urn"],
	"npc": ["\\b\\b_", "\\r\\", "body_"],
	"creature": ["\\c\\", "creature_", "anim_"],
}

func _ready() -> void:
	# Connect UI signals - Right panel
	load_bsa_button.pressed.connect(_on_load_bsa_pressed)
	load_nif_button.pressed.connect(_on_load_nif_pressed)

	# Quick load buttons
	door_btn.pressed.connect(func(): _quick_load("door"))
	chest_btn.pressed.connect(func(): _quick_load("chest"))
	barrel_btn.pressed.connect(func(): _quick_load("barrel"))
	tree_btn.pressed.connect(func(): _quick_load("tree"))
	rock_btn.pressed.connect(func(): _quick_load("rock"))
	pillar_btn.pressed.connect(func(): _quick_load("pillar"))

	# Connect UI signals - Left panel (model browser)
	search_edit.text_changed.connect(_on_search_text_changed)
	model_list.item_selected.connect(_on_model_selected)
	model_list.item_activated.connect(_on_model_activated)

	# Category buttons
	cat_all_btn.pressed.connect(func(): _set_category(""))
	cat_flora_btn.pressed.connect(func(): _set_category("flora"))
	cat_arch_btn.pressed.connect(func(): _set_category("arch"))
	cat_furn_btn.pressed.connect(func(): _set_category("furn"))
	cat_contain_btn.pressed.connect(func(): _set_category("contain"))
	cat_npc_btn.pressed.connect(func(): _set_category("npc"))
	cat_creature_btn.pressed.connect(func(): _set_category("creature"))

	# Create search debounce timer
	_search_timer = Timer.new()
	_search_timer.one_shot = true
	_search_timer.wait_time = 0.2
	_search_timer.timeout.connect(_apply_filter)
	add_child(_search_timer)

	# Try to auto-detect Morrowind path
	_try_find_morrowind()

	_log("NIF Viewer ready. Load BSA archives to begin.")

func _process(delta: float) -> void:
	if _auto_orbit and mesh_container.get_child_count() > 0:
		_orbit_yaw += delta * _orbit_speed
		_update_camera()

func _input(event: InputEvent) -> void:
	# Toggle collision visualization with C key
	if event is InputEventKey and event.pressed and event.keycode == KEY_C:
		_show_collision = not _show_collision
		_update_collision_visibility()
		_log("Collision display: %s" % ("ON" if _show_collision else "OFF"))

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_orbit_distance = max(0.5, _orbit_distance * 0.9)  # Zoom in (multiplicative for smooth feel)
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_orbit_distance = min(50.0, _orbit_distance * 1.1)  # Zoom out
			_update_camera()
	elif event is InputEventMouseMotion:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			# Orbit: left mouse drag rotates camera around target
			_auto_orbit = false
			_orbit_yaw -= event.relative.x * 0.005
			_orbit_pitch -= event.relative.y * 0.005
			# Clamp pitch to avoid flipping (just under 90 degrees)
			_orbit_pitch = clamp(_orbit_pitch, -PI * 0.49, PI * 0.49)
			_update_camera()
		elif Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
			# Pan: middle mouse drag moves the target point
			_auto_orbit = false
			var right := camera.global_transform.basis.x
			var up := camera.global_transform.basis.y
			_orbit_target -= right * event.relative.x * 0.01 * _orbit_distance * 0.1
			_orbit_target += up * event.relative.y * 0.01 * _orbit_distance * 0.1
			_update_camera()
		elif Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			# Alternative orbit with right mouse (for laptops without middle button)
			_auto_orbit = false
			_orbit_yaw -= event.relative.x * 0.005
			_orbit_pitch -= event.relative.y * 0.005
			_orbit_pitch = clamp(_orbit_pitch, -PI * 0.49, PI * 0.49)
			_update_camera()

func _update_camera() -> void:
	# Spherical coordinates to Cartesian
	var x := cos(_orbit_pitch) * sin(_orbit_yaw) * _orbit_distance
	var y := sin(_orbit_pitch) * _orbit_distance
	var z := cos(_orbit_pitch) * cos(_orbit_yaw) * _orbit_distance
	camera.position = _orbit_target + Vector3(x, y, z)
	camera.look_at(_orbit_target, Vector3.UP)

func _reset_camera() -> void:
	_orbit_yaw = 0.0
	_orbit_pitch = 0.3
	_orbit_distance = 5.0
	_orbit_target = Vector3.ZERO
	_auto_orbit = true
	_update_camera()

func _try_find_morrowind() -> void:
	# Check project settings first
	var configured_path: String = ProjectSettings.get_setting("morrowind/data_path", "")
	if not configured_path.is_empty() and DirAccess.dir_exists_absolute(configured_path):
		data_path_edit.text = configured_path
		_log("Found configured Morrowind path: %s" % configured_path)
		return

	# Common Morrowind installation paths
	var common_paths := [
		"C:/Program Files (x86)/Steam/steamapps/common/Morrowind/Data Files",
		"C:/Program Files (x86)/Bethesda Softworks/Morrowind/Data Files",
		"C:/GOG Games/Morrowind/Data Files",
		"D:/Games/Morrowind/Data Files",
	]

	for path in common_paths:
		if DirAccess.dir_exists_absolute(path):
			data_path_edit.text = path
			_log("Found Morrowind at: %s" % path)
			return

	_log("[color=yellow]Morrowind not found. Please enter path manually.[/color]")

func _on_load_bsa_pressed() -> void:
	var data_path := data_path_edit.text.strip_edges()
	if data_path.is_empty():
		_log("[color=red]Error: Please enter Morrowind Data Files path[/color]")
		return

	if not DirAccess.dir_exists_absolute(data_path):
		_log("[color=red]Error: Directory not found: %s[/color]" % data_path)
		return

	_load_bsa_archives(data_path)

func _load_bsa_archives(data_path: String) -> void:
	_bsa_readers.clear()
	_bsa_file_index.clear()
	_all_nif_paths.clear()

	# Clear and reload BSAManager too (for texture loading)
	BSAManager.clear()

	_log("Loading BSA archives from: %s" % data_path)

	# Find all BSA files
	var dir := DirAccess.open(data_path)
	if dir == null:
		_log("[color=red]Error: Cannot open directory[/color]")
		return

	var bsa_files: Array[String] = []
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.to_lower().ends_with(".bsa"):
			bsa_files.append(data_path.path_join(file_name))
		file_name = dir.get_next()
	dir.list_dir_end()

	if bsa_files.is_empty():
		_log("[color=red]Error: No BSA files found[/color]")
		return

	# Load each BSA
	var total_files := 0
	for bsa_path in bsa_files:
		var reader := BSAReaderScript.new()
		var result := reader.open(bsa_path)
		if result == OK:
			_bsa_readers.append(reader)
			var file_count := reader.get_file_count()
			total_files += file_count
			_log("  Loaded: %s (%d files)" % [bsa_path.get_file(), file_count])

			# Index files
			for entry in reader.get_file_list():
				var normalized: String = entry.name.to_lower().replace("/", "\\")
				_bsa_file_index[normalized] = {"reader": reader, "entry": entry}

				# Collect NIF paths for browser
				if normalized.ends_with(".nif"):
					_all_nif_paths.append(normalized)
		else:
			_log("[color=yellow]  Failed to load: %s[/color]" % bsa_path.get_file())

		# Also load into BSAManager for texture loading
		BSAManager.load_archive(bsa_path)

	_log("[color=green]Loaded %d BSA archives with %d files[/color]" % [_bsa_readers.size(), total_files])
	_log("  NIF meshes available: %d" % _all_nif_paths.size())

	# Sort NIF paths alphabetically
	_all_nif_paths.sort()

	# Populate model browser
	_apply_filter()

func _on_load_nif_pressed() -> void:
	var nif_path := nif_path_edit.text.strip_edges()
	if nif_path.is_empty():
		_log("[color=red]Error: Please enter NIF path[/color]")
		return

	_load_nif_mesh(nif_path)

func _quick_load(mesh_type: String) -> void:
	if _bsa_readers.is_empty():
		_log("[color=red]Error: Load BSA archives first[/color]")
		return

	var mesh_path: String = QUICK_MESHES.get(mesh_type, "")
	if mesh_path.is_empty():
		return

	nif_path_edit.text = mesh_path
	_load_nif_mesh(mesh_path)

# ==================== Model Browser ====================

func _on_search_text_changed(_new_text: String) -> void:
	# Debounce search to avoid lag while typing
	_search_timer.start()

func _set_category(category: String) -> void:
	_current_category = category

	# Update button states
	cat_all_btn.button_pressed = category == ""
	cat_flora_btn.button_pressed = category == "flora"
	cat_arch_btn.button_pressed = category == "arch"
	cat_furn_btn.button_pressed = category == "furn"
	cat_contain_btn.button_pressed = category == "contain"
	cat_npc_btn.button_pressed = category == "npc"
	cat_creature_btn.button_pressed = category == "creature"

	_apply_filter()

func _apply_filter() -> void:
	_filtered_paths.clear()

	var search_text := search_edit.text.strip_edges().to_lower()
	var category_patterns: Array = CATEGORY_FILTERS.get(_current_category, [])

	for path in _all_nif_paths:
		# Apply search filter
		if not search_text.is_empty() and path.find(search_text) < 0:
			continue

		# Apply category filter
		if not category_patterns.is_empty():
			var matches_category := false
			for pattern: String in category_patterns:
				if path.find(pattern) >= 0:
					matches_category = true
					break
			if not matches_category:
				continue

		_filtered_paths.append(path)

	# Update UI
	_populate_model_list()

func _populate_model_list() -> void:
	model_list.clear()

	var display_count := mini(_filtered_paths.size(), _max_display_items)
	for i in display_count:
		var path: String = _filtered_paths[i]
		# Show just the filename for cleaner display, store full path as metadata
		var display_name: String = path.get_file()
		model_list.add_item(display_name)
		model_list.set_item_metadata(i, path)
		model_list.set_item_tooltip(i, path)

	# Update result count
	if _filtered_paths.size() > _max_display_items:
		result_count_label.text = "%d models (showing first %d)" % [_filtered_paths.size(), _max_display_items]
	else:
		result_count_label.text = "%d models" % _filtered_paths.size()

func _on_model_selected(index: int) -> void:
	var path: String = model_list.get_item_metadata(index)
	nif_path_edit.text = path

func _on_model_activated(index: int) -> void:
	var path: String = model_list.get_item_metadata(index)
	nif_path_edit.text = path
	_load_nif_mesh(path)

# ==================== NIF Loading ====================

func _load_nif_mesh(nif_path: String) -> void:
	if _bsa_readers.is_empty():
		_log("[color=red]Error: Load BSA archives first[/color]")
		return

	var normalized: String = nif_path.to_lower().replace("/", "\\")

	# Find in index
	if not _bsa_file_index.has(normalized):
		_log("[color=red]Error: File not found in BSA: %s[/color]" % nif_path)
		_log("  Searching for similar files...")
		_search_similar(normalized)
		return

	var cached: Dictionary = _bsa_file_index[normalized]
	var reader: BSAReader = cached["reader"]
	var entry = cached["entry"]

	_log("Extracting: %s (%d bytes)" % [entry.name, entry.size])

	# Extract NIF data from BSA
	var nif_data: PackedByteArray = reader.extract_file_entry(entry)
	if nif_data.is_empty():
		_log("[color=red]Error: Failed to extract file data[/color]")
		return

	_log("  Extracted %d bytes" % nif_data.size())

	# Parse NIF
	var nif_reader := NIFReaderScript.new()
	nif_reader.debug_mode = false
	var parse_result := nif_reader.load_buffer(nif_data)
	if parse_result != OK:
		_log("[color=red]Error: Failed to parse NIF: %s[/color]" % error_string(parse_result))
		return

	_log("  Parsed NIF: version=%s, records=%d, roots=%d" % [
		nif_reader.get_version_string(),
		nif_reader.get_num_records(),
		nif_reader.get_roots().size()
	])

	# Show record types
	var record_types: Dictionary = {}
	for record in nif_reader.records:
		var rt: String = record.record_type
		if rt not in record_types:
			record_types[rt] = 0
		record_types[rt] += 1

	_log("  Record types:")
	for rt: String in record_types:
		_log("    %s: %d" % [rt, record_types[rt]])

	# Convert to Godot scene
	var converter := NIFConverterScript.new()
	converter.load_animations = true  # Enable animation extraction
	var converted_node := converter.convert_buffer(nif_data)
	if converted_node == null:
		_log("[color=red]Error: Failed to convert NIF to Godot scene[/color]")
		return

	# NOTE: Coordinate conversion (Z-up to Y-up) is now done internally by nif_converter
	# Do NOT apply additional rotation here!

	# Clear previous mesh
	for child in mesh_container.get_children():
		child.queue_free()

	# Add new mesh
	mesh_container.add_child(converted_node)
	converted_node.owner = mesh_container

	# Find and start playing animations if present
	var anim_player := _find_animation_player(converted_node)
	var skeleton := _find_skeleton(converted_node)

	# Try to load animations from KF file if model has a skeleton but no animations
	if skeleton and (anim_player == null or anim_player.get_animation_list().is_empty()):
		var kf_animations := _try_load_kf_animations(normalized, skeleton)
		if not kf_animations.is_empty():
			# Create AnimationPlayer if needed
			if anim_player == null:
				anim_player = AnimationPlayer.new()
				anim_player.name = "AnimationPlayer"
				converted_node.add_child(anim_player)
				anim_player.owner = converted_node

			# Add loaded animations
			var anim_lib := AnimationLibrary.new()
			for anim_name: String in kf_animations:
				anim_lib.add_animation(anim_name, kf_animations[anim_name])
			anim_player.add_animation_library("", anim_lib)
			_log("  Loaded %d animations from .kf file" % kf_animations.size())

	if anim_player:
		var anim_list := anim_player.get_animation_list()
		if not anim_list.is_empty():
			_log("  Animations available: %s" % ", ".join(anim_list.slice(0, 10)))
			if anim_list.size() > 10:
				_log("    ... and %d more" % (anim_list.size() - 10))
			# Play the first animation (or "Idle" if available)
			var anim_to_play := anim_list[0]
			for anim_name in ["Idle", "idle", "Idle1"]:
				if anim_name in anim_list:
					anim_to_play = anim_name
					break
			anim_player.play(anim_to_play)
			_log("  Playing animation: %s" % anim_to_play)
		else:
			_log("  AnimationPlayer present but no animations")

	# Center the mesh and frame camera
	var aabb := _get_combined_aabb(converted_node)
	if aabb.size.length() > 0:
		converted_node.position = -aabb.get_center()
		# Reset camera to frame the mesh
		_orbit_target = Vector3.ZERO
		_orbit_distance = aabb.size.length() * 1.5
		_orbit_pitch = 0.3  # Slight angle from above
		_orbit_yaw = 0.0
		_auto_orbit = true
		_update_camera()

	# Log texture loading results
	var tex_stats := TextureLoaderScript.get_stats()
	var tex_info: Array = converter.get_mesh_info()["textures"]
	if not tex_info.is_empty():
		_log("  Textures: %d referenced, %d loaded" % [tex_info.size(), tex_stats["loaded"]])

	_log("[color=green]Successfully loaded mesh![/color]")
	_log("Press [b]C[/b] to toggle collision visualization")

	# Update collision display if enabled
	if _show_collision:
		_update_collision_visibility()

	# Update stats
	_update_stats(nif_reader, converter, converted_node)

func _update_stats(_reader: NIFReader, converter: NIFConverter, _node: Node3D) -> void:
	var info := converter.get_mesh_info()

	var stats := "[b]NIF Info:[/b]\n"
	stats += "  Version: %s\n" % info["version"]
	stats += "  Records: %d\n" % info["num_records"]
	stats += "  Roots: %d\n" % info["num_roots"]
	stats += "\n[b]Geometry:[/b]\n"
	stats += "  Nodes: %d\n" % info["nodes"]
	stats += "  Meshes: %d\n" % info["meshes"]
	stats += "  Vertices: %d\n" % info["total_vertices"]
	stats += "  Triangles: %d\n" % info["total_triangles"]

	var textures: Array = info["textures"]
	if not textures.is_empty():
		stats += "\n[b]Textures:[/b]\n"
		for tex: String in textures:
			stats += "  %s\n" % tex

	# Texture loader stats
	var tex_stats := TextureLoaderScript.get_stats()
	stats += "\n[b]Texture Cache:[/b]\n"
	stats += "  Loaded: %d\n" % tex_stats["loaded"]
	stats += "  Cached: %d\n" % tex_stats["cached"]
	stats += "  Cache hits: %d\n" % tex_stats["cache_hits"]
	if tex_stats["failures"] > 0:
		stats += "  [color=yellow]Failures: %d[/color]\n" % tex_stats["failures"]

	# Collision info
	var collision_info := converter.get_collision_info()
	stats += "\n[b]Collision:[/b]\n"
	stats += "  Has collision: %s\n" % ("Yes" if collision_info["has_collision"] else "No")
	stats += "  Mode: %s\n" % collision_info["collision_mode"]
	stats += "  Shapes: %d\n" % collision_info["collision_shape_count"]
	if not collision_info["shape_types"].is_empty():
		stats += "  Types: %s\n" % ", ".join(collision_info["shape_types"])
	if not collision_info["detected_shapes"].is_empty():
		stats += "  Detected: %s\n" % ", ".join(collision_info["detected_shapes"])
	stats += "\n[color=gray]Press C to show/hide collision[/color]\n"

	stats_text.text = stats

func _get_combined_aabb(node: Node3D) -> AABB:
	var combined := AABB()
	var first := true

	for child in node.get_children():
		if child is MeshInstance3D and child.mesh:
			var mesh_aabb: AABB = child.mesh.get_aabb()
			mesh_aabb = child.transform * mesh_aabb
			if first:
				combined = mesh_aabb
				first = false
			else:
				combined = combined.merge(mesh_aabb)

		# Recurse into children
		if child is Node3D:
			var child_aabb := _get_combined_aabb(child)
			if child_aabb.size.length() > 0:
				child_aabb = child.transform * child_aabb
				if first:
					combined = child_aabb
					first = false
				else:
					combined = combined.merge(child_aabb)

	return combined

func _search_similar(search_path: String) -> void:
	# Try to find similar paths
	var search_file: String = search_path.get_file()
	var matches: Array[String] = []

	for path_key: String in _bsa_file_index.keys():
		if path_key.ends_with(".nif") and path_key.get_file().find(search_file.get_basename()) >= 0:
			matches.append(path_key)
			if matches.size() >= 5:
				break

	if matches.is_empty():
		# Try broader search
		var parts: PackedStringArray = search_file.get_basename().split("_")
		if parts.size() > 1:
			var keyword: String = parts[1] if parts[0].length() <= 2 else parts[0]
			for path_key2: String in _bsa_file_index.keys():
				if path_key2.ends_with(".nif") and path_key2.find(keyword) >= 0:
					matches.append(path_key2)
					if matches.size() >= 5:
						break

	if not matches.is_empty():
		_log("  Similar files found:")
		for m: String in matches:
			_log("    %s" % m)

func _log(text: String) -> void:
	log_text.append_text(text + "\n")
	# Also print to console (strip bbcode)
	var plain := text
	for tag in ["[b]", "[/b]", "[u]", "[/u]", "[color=red]", "[color=green]", "[color=yellow]", "[/color]"]:
		plain = plain.replace(tag, "")
	print("[NIFViewer] %s" % plain)


## Find AnimationPlayer in node tree (searches children recursively)
func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer

	for child in node.get_children():
		var found := _find_animation_player(child)
		if found:
			return found

	return null


## Find Skeleton3D in node tree (searches children recursively)
func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D

	for child in node.get_children():
		var found := _find_skeleton(child)
		if found:
			return found

	return null


## Update collision shape visibility
func _update_collision_visibility() -> void:
	# Clear old debug visualizations
	for node in _collision_debug_nodes:
		if is_instance_valid(node):
			node.queue_free()
	_collision_debug_nodes.clear()

	if not _show_collision or mesh_container.get_child_count() == 0:
		return

	# Find and visualize collision shapes in the loaded mesh
	var root := mesh_container.get_child(0)
	if root:
		_create_collision_debug_visuals(root)


## Recursively find collision shapes and create debug visuals
func _create_collision_debug_visuals(node: Node) -> void:
	if node is CollisionShape3D:
		var debug_mesh := _create_shape_debug_mesh(node as CollisionShape3D)
		if debug_mesh:
			mesh_container.add_child(debug_mesh)
			_collision_debug_nodes.append(debug_mesh)

	for child in node.get_children():
		_create_collision_debug_visuals(child)


## Create a debug mesh for a collision shape
func _create_shape_debug_mesh(coll_shape: CollisionShape3D) -> MeshInstance3D:
	if coll_shape.shape == null:
		return null

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "CollisionDebug_" + coll_shape.name

	# Get global transform of the collision shape
	mesh_inst.global_transform = coll_shape.global_transform

	# Create appropriate mesh for the shape type
	var shape := coll_shape.shape
	if shape is BoxShape3D:
		var box := BoxMesh.new()
		box.size = shape.size
		mesh_inst.mesh = box
	elif shape is SphereShape3D:
		var sphere := SphereMesh.new()
		sphere.radius = shape.radius
		sphere.height = shape.radius * 2.0
		mesh_inst.mesh = sphere
	elif shape is CylinderShape3D:
		var cyl := CylinderMesh.new()
		cyl.top_radius = shape.radius
		cyl.bottom_radius = shape.radius
		cyl.height = shape.height
		mesh_inst.mesh = cyl
	elif shape is CapsuleShape3D:
		var cap := CapsuleMesh.new()
		cap.radius = shape.radius
		cap.height = shape.height
		mesh_inst.mesh = cap
	elif shape is ConvexPolygonShape3D:
		# For convex shapes, create a mesh from the points
		var points: PackedVector3Array = shape.points
		if points.size() >= 4:
			# Use ArrayMesh to visualize points as a rough hull
			var arr_mesh := ArrayMesh.new()
			# Just create a bounding box visualization for simplicity
			var aabb := _calculate_points_aabb(points)
			var box := BoxMesh.new()
			box.size = aabb.size
			mesh_inst.mesh = box
			mesh_inst.position += aabb.get_center()
	elif shape is ConcavePolygonShape3D:
		# Trimesh - create mesh from faces
		var faces: PackedVector3Array = shape.get_faces()
		if faces.size() >= 3:
			var arr_mesh := ArrayMesh.new()
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = faces
			arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			mesh_inst.mesh = arr_mesh
	else:
		# Unknown shape type
		return null

	# Semi-transparent green material for collision visualization
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.0, 1.0, 0.0, 0.3)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # See both sides
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh_inst.material_override = mat

	return mesh_inst


## Calculate AABB from point array
func _calculate_points_aabb(points: PackedVector3Array) -> AABB:
	if points.is_empty():
		return AABB()

	var min_v := points[0]
	var max_v := points[0]
	for p in points:
		min_v = min_v.min(p)
		max_v = max_v.max(p)
	return AABB(min_v, max_v - min_v)


## Try to load animations from a .kf file for the given mesh path
## Returns Dictionary of anim_name -> Animation
func _try_load_kf_animations(mesh_path: String, skeleton: Skeleton3D) -> Dictionary:
	# Determine which .kf file to load based on the mesh path
	# For character models (meshes\b\ or meshes\r\), use xbase_anim.kf
	var kf_paths: Array[String] = []

	if mesh_path.find("\\b\\") >= 0 or mesh_path.find("\\r\\") >= 0:
		# Character body/head parts use the main character animation file
		kf_paths.append("meshes\\xbase_anim.kf")
		kf_paths.append("meshes\\xbase_anim_female.kf")
	elif mesh_path.find("\\c\\") >= 0:
		# Creature - try to find creature-specific .kf file
		var base_name := mesh_path.get_basename()
		kf_paths.append(base_name + ".kf")
	else:
		# Try same-name .kf file
		var kf_path := mesh_path.get_basename() + ".kf"
		kf_paths.append(kf_path)

	# Try each potential .kf file
	for kf_path in kf_paths:
		var normalized_kf := kf_path.to_lower().replace("/", "\\")
		if _bsa_file_index.has(normalized_kf):
			_log("  Found animation file: %s" % kf_path)
			var cached: Dictionary = _bsa_file_index[normalized_kf]
			var reader: BSAReader = cached["reader"]
			var entry = cached["entry"]

			var kf_data: PackedByteArray = reader.extract_file_entry(entry)
			if kf_data.is_empty():
				continue

			var kf_loader := NIFKFLoaderScript.new()
			kf_loader.debug_mode = false
			var animations := kf_loader.load_kf_buffer(kf_data, skeleton)

			if not animations.is_empty():
				return animations

	return {}
