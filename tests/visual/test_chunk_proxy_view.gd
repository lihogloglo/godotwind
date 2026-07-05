extends Node3D

## Visual check for baked CHUNK-tier proxies (Phase 2 revised).
## Loads every chunk .res from the cache and places it at its world origin —
## you fly around and judge the merged geometry + materials as they would
## appear in the 400-1200m ring.
##
## Controls: InputMap movement (WASD-equivalent actions) + mouse look,
## jump/crouch = up/down, sprint = faster, ESC releases the mouse.

@warning_ignore("untyped_declaration", "unsafe_method_access")

const InputActionsScript := preload("res://src/core/input/input_actions.gd")
const DU := preload("res://src/core/world/distance_utils.gd")

const CHUNK_CELLS := 2
const FLY_SPEED := 30.0
const SPRINT_MULT := 4.0
const MOUSE_SENS := 0.0025

var _camera: Camera3D
var _yaw := 0.0
var _pitch := -0.4
var _info: Label


func _ready() -> void:
	InputActionsScript.verify()

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.35, 0.46, 0.6)
	sky_mat.sky_horizon_color = Color(0.62, 0.66, 0.7)
	sky.sky_material = sky_mat
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_sky_contribution = 0.6
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, 35, 0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	add_child(sun)

	_camera = Camera3D.new()
	_camera.far = 8000.0
	add_child(_camera)

	var settings: Node = get_node_or_null("/root/SettingsManager")
	var chunks_dir: String = settings.call("get_cache_base_path").path_join("chunks") if settings != null else ""
	var loaded := 0
	var surfaces := 0
	var textured := 0
	var untextured := 0
	var combined := AABB()
	var has_any := false

	var dir := DirAccess.open(chunks_dir)
	if dir != null:
		for file in dir.get_files():
			if not (file.begins_with("chunk_") and file.ends_with(".res")):
				continue
			var parts := file.trim_suffix(".res").split("_")
			if parts.size() != 3:
				continue
			var chunk_key := Vector2i(int(parts[1]), int(parts[2]))
			var mesh := ResourceLoader.load(chunks_dir.path_join(file), "ArrayMesh") as ArrayMesh
			if mesh == null:
				push_warning("chunk failed to load: %s" % file)
				continue
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.position = DU.cell_to_world_origin(Vector2i(chunk_key.x * CHUNK_CELLS, chunk_key.y * CHUNK_CELLS))
			add_child(mi)
			loaded += 1
			surfaces += mesh.get_surface_count()
			for si in mesh.get_surface_count():
				var m := mesh.surface_get_material(si) as BaseMaterial3D
				if m != null and m.albedo_texture != null:
					textured += 1
				else:
					untextured += 1
			var world_aabb := AABB(mi.position + mesh.get_aabb().position, mesh.get_aabb().size)
			combined = combined.merge(world_aabb) if has_any else world_aabb
			has_any = true

	if has_any:
		var center := combined.get_center()
		_camera.position = Vector3(center.x, combined.position.y + combined.size.y + 120.0, center.z + combined.size.z * 0.35)
		_yaw = 0.0

	_info = Label.new()
	_info.text = "CHUNK proxy viewer — %d chunks, %d surfaces (%d textured / %d untextured)\nThese render at 400-1200m in game; fly close to judge, then back off to ring distance.\nESC = release mouse" % [
		loaded, surfaces, textured, untextured]
	_info.position = Vector2(12, 12)
	var canvas := CanvasLayer.new()
	canvas.add_child(_info)
	add_child(canvas)

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	print("[CHUNK-VIEW] %d chunks, %d surfaces, %d textured, %d untextured" % [loaded, surfaces, textured, untextured])


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * MOUSE_SENS
		_pitch = clampf(_pitch - mm.relative.y * MOUSE_SENS, -1.5, 1.5)
	elif event.is_action_pressed(&"ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED
	elif event is InputEventMouseButton and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _process(delta: float) -> void:
	_camera.rotation = Vector3(_pitch, _yaw, 0.0)
	var move := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_backward")
	var speed := FLY_SPEED * (SPRINT_MULT if Input.is_action_pressed(&"sprint") else 1.0)
	var dir := (_camera.basis * Vector3(move.x, 0.0, move.y))
	if Input.is_action_pressed(&"jump"):
		dir += Vector3.UP
	if Input.is_action_pressed(&"crouch"):
		dir += Vector3.DOWN
	_camera.position += dir * speed * delta
