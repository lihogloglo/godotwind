## Visual test: replicates EXACT game pipeline to isolate texture bug.
##
## LEFT side: MeshInstance3D (native Godot materials — known working)
## RIGHT side: RS instance via StaticObjectRenderer (game pipeline — suspected broken)
##
## Both use the SAME prototype from ModelLoader (including _clear_resource_paths).
## If LEFT looks correct and RIGHT looks wrong, bug is in RS instance creation.
## If BOTH look correct, bug is elsewhere in the full game pipeline.
##
## Controls: LEFT/RIGHT arrows = switch model, ZQSD = orbit
extends Node3D


## Models to test — multi-surface assets that should have distinct per-surface textures
var _test_models: Array[String] = [
	"x_ex_de_ship_nif",
	"x_ex_de_shipwreck_nif",
	"x_ex_hlaalu_b_01_nif",
	"x_ex_velothi_01_nif",
]

var _current_index: int = 0
var _camera: Camera3D
var _orbit_angle: float = 0.0
var _orbit_height: float = 5.0
var _orbit_distance: float = 20.0
var _label: Label
var _info_label: Label
var _node3d_instance: Node3D = null
var _static_renderer: StaticObjectRenderer = null
var _rs_instance_id: int = -1
var _current_type_name: String = ""


func _ready() -> void:
	# Camera
	_camera = Camera3D.new()
	_camera.far = 500.0
	add_child(_camera)

	# Light
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 30, 0)
	light.light_energy = 1.2
	add_child(light)

	# Environment
	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.3, 0.35, 0.4)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.4, 0.4, 0.5)
	environment.ambient_light_energy = 0.5
	env.environment = environment
	add_child(env)

	# StaticObjectRenderer — same as the game uses
	_static_renderer = StaticObjectRenderer.new()
	add_child(_static_renderer)

	# UI
	var canvas := CanvasLayer.new()
	add_child(canvas)

	_label = Label.new()
	_label.position = Vector2(20, 20)
	_label.add_theme_font_size_override("font_size", 20)
	canvas.add_child(_label)

	_info_label = Label.new()
	_info_label.position = Vector2(20, 60)
	_info_label.add_theme_font_size_override("font_size", 14)
	_info_label.add_theme_color_override("font_color", Color(0.8, 0.9, 1.0))
	canvas.add_child(_info_label)

	var help := Label.new()
	help.position = Vector2(20, 500)
	help.text = "LEFT/RIGHT = switch model | LEFT = MeshInstance3D | RIGHT = RS instance"
	help.add_theme_font_size_override("font_size", 14)
	canvas.add_child(help)

	_load_model(_current_index)


func _load_model(index: int) -> void:
	# Clean up previous
	if _node3d_instance:
		_node3d_instance.queue_free()
		_node3d_instance = null
	if _rs_instance_id >= 0:
		_static_renderer.remove_instance(_rs_instance_id)
		_rs_instance_id = -1
	if not _current_type_name.is_empty():
		_static_renderer.clear(true)
		_current_type_name = ""

	var model_name: String = _test_models[index]
	var path := SettingsManager.get_models_path().path_join(model_name + ".res")

	if not FileAccess.file_exists(path):
		_label.text = "NOT FOUND: %s" % model_name
		return

	# Load the same way model_loader does:
	# 1. Load PackedScene
	# 2. Instantiate
	# 3. Clear resource paths (same as model_loader._clear_resource_paths)
	var packed := ResourceLoader.load(path, "PackedScene") as PackedScene
	if not packed:
		_label.text = "LOAD FAIL: %s" % model_name
		return

	var prototype := packed.instantiate() as Node3D
	if not prototype:
		_label.text = "INSTANTIATE FAIL: %s" % model_name
		return

	# Clear resource paths — same as model_loader._load_from_disk_cache
	_clear_resource_paths(prototype)

	# === LEFT SIDE: MeshInstance3D (duplicate of prototype) ===
	_node3d_instance = prototype.duplicate()
	_node3d_instance.position = Vector3(-10, 0, 0)
	add_child(_node3d_instance)

	# === RIGHT SIDE: RS instance via StaticObjectRenderer ===
	_current_type_name = "test:" + model_name
	_static_renderer.register_from_prototype(_current_type_name, prototype)

	if _static_renderer.has_type(_current_type_name):
		var xform := Transform3D(Basis.IDENTITY, Vector3(10, 0, 0))
		_rs_instance_id = _static_renderer.add_instance(_current_type_name, xform)

	# Build info text
	var info_text := "Model: %s\n" % model_name
	var meshes := _find_meshes(prototype)
	for mi in meshes:
		var surf_count: int = mi.mesh.get_surface_count() if mi.mesh else 0
		info_text += "  '%s': %d surfaces" % [mi.name, surf_count]
		if mi.material_override:
			info_text += " [material_override]\n"
		else:
			info_text += "\n"
			var unique_tex: Dictionary = {}
			for si in range(surf_count):
				var mat: Material = mi.mesh.surface_get_material(si) if mi.mesh else null
				var tex_name := _get_tex_name(mat)
				unique_tex[tex_name] = true
				if si < 5:
					info_text += "    [%d] %s\n" % [si, tex_name]
			if surf_count > 5:
				info_text += "    ... (%d more)\n" % (surf_count - 5)
			info_text += "    unique textures: %d / %d surfaces\n" % [unique_tex.size(), surf_count]

	info_text += "\nLEFT = MeshInstance3D | RIGHT = RS instance (StaticObjectRenderer)"
	info_text += "\nRS type registered: %s, instance_id: %d" % [_static_renderer.has_type(_current_type_name), _rs_instance_id]

	_info_label.text = info_text
	_label.text = "%s — compare LEFT (Node3D) vs RIGHT (RS)" % model_name

	# Auto-fit camera to see both
	var aabb := _compute_aabb(prototype)
	_orbit_distance = aabb.size.length() * 2.5
	_orbit_height = aabb.get_center().y

	# Free the original prototype (game also doesn't keep it in tree)
	# But DON'T free it — StaticObjectRenderer holds RIDs from its mesh.
	# The game keeps prototypes in ModelLoader._model_cache. We keep ours here.
	prototype.queue_free()


func _clear_resource_paths(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_inst := node as MeshInstance3D
		if mesh_inst.mesh:
			mesh_inst.mesh.resource_path = ""
			for i in range(mesh_inst.mesh.get_surface_count()):
				var mat := mesh_inst.mesh.surface_get_material(i)
				if mat:
					mat.resource_path = ""
					if mat is StandardMaterial3D:
						var std_mat := mat as StandardMaterial3D
						for tex in [std_mat.albedo_texture, std_mat.normal_texture,
								std_mat.roughness_texture, std_mat.metallic_texture,
								std_mat.emission_texture]:
							if tex:
								tex.resource_path = ""
		if mesh_inst.material_override:
			mesh_inst.material_override.resource_path = ""
	for child in node.get_children():
		_clear_resource_paths(child)


func _process(delta: float) -> void:
	if Input.is_action_pressed("move_left"):
		_orbit_angle -= delta * 1.5
	if Input.is_action_pressed("move_right"):
		_orbit_angle += delta * 1.5
	if Input.is_action_pressed("move_forward"):
		_orbit_distance = maxf(2.0, _orbit_distance - delta * 15.0)
	if Input.is_action_pressed("move_backward"):
		_orbit_distance += delta * 15.0

	if Input.is_action_just_pressed("ui_left"):
		_current_index = (_current_index - 1 + _test_models.size()) % _test_models.size()
		_load_model(_current_index)
	if Input.is_action_just_pressed("ui_right"):
		_current_index = (_current_index + 1) % _test_models.size()
		_load_model(_current_index)

	var cx := cos(_orbit_angle) * _orbit_distance
	var cz := sin(_orbit_angle) * _orbit_distance
	_camera.position = Vector3(cx, _orbit_height + 3.0, cz)
	_camera.look_at(Vector3(0, _orbit_height, 0))


func _find_meshes(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		result.append(node as MeshInstance3D)
	for child in node.get_children():
		result.append_array(_find_meshes(child))
	return result


func _compute_aabb(node: Node3D) -> AABB:
	var aabb := AABB()
	for mi in _find_meshes(node):
		if mi.mesh:
			var child_aabb := mi.global_transform * mi.mesh.get_aabb()
			aabb = aabb.merge(child_aabb)
	return aabb


func _get_tex_name(mat: Material) -> String:
	if mat == null:
		return "NULL"
	if mat is StandardMaterial3D:
		var sm := mat as StandardMaterial3D
		if sm.albedo_texture:
			var p: String = sm.albedo_texture.resource_path
			if not p.is_empty():
				return p.get_file()
			return "embedded(%d)" % sm.albedo_texture.get_instance_id()
		return "no_tex(color=%s)" % sm.albedo_color.to_html()
	return mat.get_class()
