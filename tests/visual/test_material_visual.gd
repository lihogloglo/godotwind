## Visual test: loads ship .res as standard MeshInstance3D (left) vs RS instance (right)
## to isolate whether the texture bug is in the cached data or the RS rendering path.
##
## Controls: WASD/ZQSD to orbit, mouse drag to rotate, scroll to zoom.
extends Node3D

const MODELS_DIR := "C:/Users/metzo/Documents/Godotwind/cache/models/"

## Models to test — multi-surface assets that should have distinct per-surface textures
var _test_models: Array[String] = [
	"x_ex_de_ship_nif",
	"x_ex_de_shipwreck_nif",
	"x_ex_longboat_nif",
	"x_ex_hlaalu_b_01_nif",
]

var _current_index: int = 0
var _camera: Camera3D
var _orbit_angle: float = 0.0
var _orbit_height: float = 5.0
var _orbit_distance: float = 20.0
var _label: Label
var _node3d_instance: Node3D = null
var _rs_instance_rids: Array[RID] = []
var _info_label: Label


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
	help.text = "LEFT/RIGHT = switch model | R = toggle RS vs Node3D | WASD = orbit"
	help.add_theme_font_size_override("font_size", 14)
	canvas.add_child(help)

	_load_model(_current_index)


func _load_model(index: int) -> void:
	# Clean up previous
	if _node3d_instance:
		_node3d_instance.queue_free()
		_node3d_instance = null
	_clear_rs_instances()

	var model_name: String = _test_models[index]
	var path := MODELS_DIR + model_name + ".res"

	if not FileAccess.file_exists(path):
		_label.text = "NOT FOUND: %s" % model_name
		return

	var packed := ResourceLoader.load(path, "PackedScene") as PackedScene
	if not packed:
		_label.text = "LOAD FAIL: %s" % model_name
		return

	var instance := packed.instantiate() as Node3D
	if not instance:
		_label.text = "INSTANTIATE FAIL: %s" % model_name
		return

	# Standard Node3D display (Godot handles materials natively)
	_node3d_instance = instance
	add_child(instance)

	# Audit and display info
	var info_text := "Model: %s\n" % model_name
	var meshes := _find_meshes(instance)
	for mi in meshes:
		info_text += "  MeshInstance3D: '%s' surfaces=%d\n" % [mi.name, mi.mesh.get_surface_count() if mi.mesh else 0]
		if mi.material_override:
			info_text += "    material_override: %s\n" % _mat_str(mi.material_override)
		elif mi.mesh:
			for si in range(mi.mesh.get_surface_count()):
				var sov := mi.get_surface_override_material(si)
				var mesh_mat: Material = mi.mesh.surface_get_material(si)
				var eff := sov if sov else mesh_mat
				info_text += "    [%d] %s\n" % [si, _mat_str(eff)]

	_info_label.text = info_text
	_label.text = "%s (Node3D — native materials)" % model_name

	# Auto-fit camera
	var aabb := _compute_aabb(instance)
	_orbit_distance = aabb.size.length() * 1.5
	_orbit_height = aabb.get_center().y


func _clear_rs_instances() -> void:
	var rs := RenderingServer
	for rid in _rs_instance_rids:
		if rid.is_valid():
			rs.free_rid(rid)
	_rs_instance_rids.clear()


func _process(delta: float) -> void:
	# Orbit controls
	if Input.is_action_pressed("move_left"):
		_orbit_angle -= delta * 1.5
	if Input.is_action_pressed("move_right"):
		_orbit_angle += delta * 1.5
	if Input.is_action_pressed("move_forward"):
		_orbit_distance = maxf(2.0, _orbit_distance - delta * 15.0)
	if Input.is_action_pressed("move_backward"):
		_orbit_distance += delta * 15.0

	# Switch model
	if Input.is_action_just_pressed("ui_left"):
		_current_index = (_current_index - 1 + _test_models.size()) % _test_models.size()
		_load_model(_current_index)
	if Input.is_action_just_pressed("ui_right"):
		_current_index = (_current_index + 1) % _test_models.size()
		_load_model(_current_index)

	# Update camera
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


func _mat_str(mat: Material) -> String:
	if mat == null:
		return "null"
	if mat is StandardMaterial3D:
		var sm := mat as StandardMaterial3D
		var tex_name := sm.albedo_texture.resource_path.get_file() if sm.albedo_texture else "NO_TEX"
		return "Std(%s)" % tex_name
	return mat.get_class()
