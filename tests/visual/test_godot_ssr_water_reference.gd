extends Node3D

@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_property_access")

const InputActionsScript := preload("res://src/core/input/input_actions.gd")
const FlyCameraScript := preload("res://src/core/player/fly_camera.gd")
const WATER_SHADER := preload("res://tests/visual/godot_ssr_water/water.gdshader")
const BOTTOM_SHADER := preload("res://tests/visual/godot_ssr_water/bottom.gdshader")

var _camera: Camera3D
var _fps_label: Label


func _ready() -> void:
	InputActionsScript.verify()
	Engine.max_fps = 60
	_build_environment()
	_build_camera()
	_build_water()
	_build_refraction_targets()
	_build_hud()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _process(_delta: float) -> void:
	if _fps_label != null and _camera != null:
		_fps_label.text = "GodotSSRWater reference | FPS %d/60 | Camera Y %.1f" % [
			Engine.get_frames_per_second(),
			_camera.global_position.y,
		]


func _build_environment() -> void:
	var world_environment := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 1.0
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.ssr_enabled = true
	environment.ssr_max_steps = 96
	environment.ssr_fade_in = 0.1
	environment.ssr_fade_out = 2.0
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.32, 0.58, 0.86)
	sky_material.sky_horizon_color = Color(0.74, 0.86, 0.92)
	sky_material.ground_bottom_color = Color(0.06, 0.12, 0.18)
	sky_material.ground_horizon_color = Color(0.26, 0.42, 0.50)
	sky.sky_material = sky_material
	environment.sky = sky

	world_environment.environment = environment
	add_child(world_environment)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation = Vector3(-0.9, 0.55, 0.0)
	sun.light_energy = 1.4
	sun.shadow_enabled = true
	add_child(sun)


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "FlyCamera"
	_camera.script = FlyCameraScript
	_camera.current = true
	_camera.far = 1000.0
	_camera.move_speed = 16.0
	_camera.position = Vector3(-42.0, 13.0, -44.0)
	add_child(_camera)
	_camera.look_at(Vector3(-18.0, -7.0, -12.0), Vector3.UP)


func _build_water() -> void:
	var water_mesh := BoxMesh.new()
	water_mesh.size = Vector3(140.0, 0.2, 140.0)
	water_mesh.subdivide_width = 180
	water_mesh.subdivide_depth = 180

	var water_material := ShaderMaterial.new()
	water_material.shader = WATER_SHADER
	water_material.render_priority = -128
	water_material.set_shader_parameter("color_shallow", Color(0.01, 0.2, 0.3))
	water_material.set_shader_parameter("color_deep", Color(0.3, 0.5, 0.6))
	water_material.set_shader_parameter("transparency", 0.72)
	water_material.set_shader_parameter("metallic", 0.0)
	water_material.set_shader_parameter("roughness", 0.18)
	water_material.set_shader_parameter("max_visible_depth", 28.0)
	water_material.set_shader_parameter("wave_a", _make_noise_texture(0.0005, FastNoiseLite.TYPE_SIMPLEX, false))
	water_material.set_shader_parameter("wave_b", _make_noise_texture(0.0225, FastNoiseLite.TYPE_CELLULAR, false))
	water_material.set_shader_parameter("wave_move_direction_a", Vector2(-1.0, 0.0))
	water_material.set_shader_parameter("wave_move_direction_b", Vector2(0.0, 1.0))
	water_material.set_shader_parameter("wave_noise_scale_a", 15.0)
	water_material.set_shader_parameter("wave_noise_scale_b", 15.0)
	water_material.set_shader_parameter("wave_time_scale_a", 0.15)
	water_material.set_shader_parameter("wave_time_scale_b", 0.15)
	water_material.set_shader_parameter("wave_height_scale", 1.1)
	water_material.set_shader_parameter("wave_normal_flatness", 50.0)
	water_material.set_shader_parameter("surface_normals_a", _make_noise_texture(0.007, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, true))
	water_material.set_shader_parameter("surface_normals_b", _make_noise_texture(0.02, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, true))
	water_material.set_shader_parameter("surface_normals_move_direction_a", Vector2(-1.0, 0.2))
	water_material.set_shader_parameter("surface_normals_move_direction_b", Vector2(0.2, 1.0))
	water_material.set_shader_parameter("surface_texture_roughness", 0.18)
	water_material.set_shader_parameter("surface_texture_scale", 0.12)
	water_material.set_shader_parameter("surface_texture_time_scale", 0.08)
	water_material.set_shader_parameter("ssr_resolution", 1.0)
	water_material.set_shader_parameter("ssr_max_travel", 30.0)
	water_material.set_shader_parameter("ssr_max_diff", 4.0)
	water_material.set_shader_parameter("ssr_mix_strength", 0.45)
	water_material.set_shader_parameter("ssr_screen_border_fadeout", 0.3)
	water_material.set_shader_parameter("refraction_intensity", 0.65)
	water_material.set_shader_parameter("border_color", Color.WHITE)
	water_material.set_shader_parameter("border_scale", 0.0)
	water_material.set_shader_parameter("border_near", 0.5)
	water_material.set_shader_parameter("border_far", 300.0)
	water_material.set_shader_parameter("cut_out_x", 0.0)
	water_material.set_shader_parameter("cut_out_z", 0.0)

	var water := MeshInstance3D.new()
	water.name = "GodotSSRWaterSurface"
	water.mesh = water_mesh
	water.material_override = water_material
	add_child(water)


func _build_refraction_targets() -> void:
	var bottom_mesh := PlaneMesh.new()
	bottom_mesh.size = Vector2(140.0, 140.0)
	bottom_mesh.subdivide_width = 160
	bottom_mesh.subdivide_depth = 160

	var bottom_material := ShaderMaterial.new()
	bottom_material.shader = BOTTOM_SHADER
	bottom_material.set_shader_parameter("height_scale", 8.0)
	bottom_material.set_shader_parameter("uv_scale", 160.0)
	bottom_material.set_shader_parameter("texture_scale", 18.0)
	bottom_material.set_shader_parameter("stone_texture", _make_checker_texture())
	bottom_material.set_shader_parameter("bottom", _make_noise_texture(0.006, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, false))

	var bottom := MeshInstance3D.new()
	bottom.name = "HighContrastBottom"
	bottom.position = Vector3(0.0, -16.0, 0.0)
	bottom.mesh = bottom_mesh
	bottom.material_override = bottom_material
	add_child(bottom)

	var colors: Array[Color] = [
		Color(1.0, 0.2, 0.42),
		Color(0.05, 0.85, 0.35),
		Color(1.0, 0.86, 0.12),
		Color(0.18, 0.55, 1.0),
	]
	var positions: Array[Vector3] = [
		Vector3(-26.0, -5.0, -18.0),
		Vector3(-12.0, -8.0, -8.0),
		Vector3(4.0, -7.0, -20.0),
		Vector3(18.0, -6.0, -10.0),
	]

	for index in positions.size():
		var pillar := MeshInstance3D.new()
		pillar.name = "RefractionPillar%d" % index
		var pillar_mesh := BoxMesh.new()
		pillar_mesh.size = Vector3(4.0, 18.0, 4.0)
		pillar.mesh = pillar_mesh
		pillar.position = positions[index]
		pillar.material_override = _make_standard_material(colors[index])
		add_child(pillar)

	for index in positions.size():
		var sphere := MeshInstance3D.new()
		sphere.name = "RefractionSphere%d" % index
		var sphere_mesh := SphereMesh.new()
		sphere_mesh.radius = 2.4 + float(index) * 0.7
		sphere_mesh.height = sphere_mesh.radius * 2.0
		sphere.mesh = sphere_mesh
		sphere.position = positions[index] + Vector3(5.0, 8.0, 7.0)
		sphere.material_override = _make_standard_material(colors[(index + 1) % colors.size()])
		add_child(sphere)


func _build_hud() -> void:
	_fps_label = Label.new()
	_fps_label.name = "FpsLabel"
	_fps_label.position = Vector2(16.0, 16.0)
	_fps_label.add_theme_color_override("font_color", Color(0.93, 0.98, 1.0))
	_fps_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.8))
	_fps_label.add_theme_constant_override("shadow_offset_x", 1)
	_fps_label.add_theme_constant_override("shadow_offset_y", 1)
	add_child(_fps_label)


func _make_noise_texture(frequency: float, noise_type: int, as_normal_map: bool) -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = noise_type
	noise.frequency = frequency

	var texture := NoiseTexture2D.new()
	texture.width = 512
	texture.height = 512
	texture.generate_mipmaps = false
	texture.seamless = true
	texture.as_normal_map = as_normal_map
	texture.noise = noise
	return texture


func _make_checker_texture() -> ImageTexture:
	var size := 256
	var tile := 16
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in range(size):
		for x in range(size):
			var is_light := ((x / tile) + (y / tile)) % 2 == 0
			var color := Color(0.92, 0.92, 0.88, 1.0) if is_light else Color(0.04, 0.04, 0.05, 1.0)
			image.set_pixel(x, y, color)
	return ImageTexture.create_from_image(image)


func _make_standard_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.45
	material.metallic = 0.0
	return material
