extends Node3D

## Visual test for ocean rendering.
## Run this scene and verify:
## - FFT wave motion visible
## - Shore mask dampening (if terrain present)
## - Reflections via native SSR + sky
## - Depth-based water coloring
## - Edge foam at intersections

var _ocean: OceanMesh
var _camera: Camera3D
var _light: DirectionalLight3D
var _environment: WorldEnvironment

func _ready() -> void:
	# Setup environment with SSR enabled
	_environment = WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.38, 0.45, 0.55)
	mat.sky_horizon_color = Color(0.64, 0.68, 0.74)
	mat.ground_bottom_color = Color(0.12, 0.10, 0.08)
	mat.ground_horizon_color = Color(0.37, 0.33, 0.28)
	sky.sky_material = mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 0.5
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	# Enable native SSR
	env.ssr_enabled = true
	env.ssr_max_steps = 64
	env.ssr_fade_in = 0.15
	env.ssr_fade_out = 2.0
	env.ssr_depth_tolerance = 0.2
	_environment.environment = env
	add_child(_environment)

	# Setup sun
	_light = DirectionalLight3D.new()
	_light.rotation_degrees = Vector3(-45, 45, 0)
	_light.shadow_enabled = true
	_light.light_energy = 1.2
	add_child(_light)

	# Add a ReflectionProbe for sky fallback
	var probe := ReflectionProbe.new()
	probe.box_projection = false
	probe.size = Vector3(2000, 200, 2000)
	probe.position = Vector3(0, 50, 0)
	add_child(probe)

	# Setup camera — looking slightly down at the water
	_camera = Camera3D.new()
	_camera.position = Vector3(0, 8, 20)
	_camera.rotation_degrees = Vector3(-15, 0, 0)
	_camera.current = true
	add_child(_camera)

	# Add test objects partially submerged for foam/refraction testing
	_add_test_cube(Vector3(20, -1, -30), Color(0.7, 0.3, 0.2), Vector3(5, 5, 5))
	_add_test_cube(Vector3(-15, -0.5, -20), Color(0.3, 0.6, 0.2), Vector3(3, 3, 3))
	_add_test_cube(Vector3(0, -2, -50), Color(0.2, 0.3, 0.7), Vector3(8, 8, 8))

	# Sloped seabed to demonstrate depth-based absorption
	# Slopes from Y=-1 (near camera, shallow) to Y=-25 (far, deep)
	_add_seabed_slope()

	# Large deep floor beyond the slope
	var deep_floor := MeshInstance3D.new()
	deep_floor.mesh = PlaneMesh.new()
	deep_floor.mesh.size = Vector2(1000, 1000)
	deep_floor.position = Vector3(0, -25, -200)
	var deep_mat := StandardMaterial3D.new()
	deep_mat.albedo_color = Color(0.35, 0.3, 0.25)
	deep_floor.material_override = deep_mat
	add_child(deep_floor)

	# Setup Ocean
	_ocean = OceanMesh.new()
	add_child(_ocean)
	_ocean.initialize(5000.0, 1)  # Force Standard mode

	# Tune absorption for this test — make depth coloring more visible
	var ocean_mat := _ocean.get_material()
	if ocean_mat:
		ocean_mat.set_shader_parameter("color_depth_range", 10.0)  # Faster absorption
		ocean_mat.set_shader_parameter("color_shallow", Color(0.15, 0.35, 0.45))  # More distinct shallow
		ocean_mat.set_shader_parameter("color_deep", Color(0.01, 0.05, 0.1))  # Darker deep

	# Animate camera — orbit over the slope to show absorption gradient
	var tween := create_tween().set_loops()
	tween.tween_property(_camera, "position", Vector3(40, 10, -60), 8.0).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(_camera, "position", Vector3(-30, 15, -120), 8.0).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(_camera, "position", Vector3(0, 8, 20), 8.0).set_ease(Tween.EASE_IN_OUT)

	print("[Ocean Test] Scene ready. Check: waves, SSR reflections, depth coloring, foam at cube edges.")


func _add_seabed_slope() -> void:
	# Create a slope mesh: shallow near camera, deep far away
	# 200m long, 200m wide, from Y=-1 to Y=-25
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var slope_mat := StandardMaterial3D.new()
	slope_mat.albedo_color = Color(0.5, 0.4, 0.3)  # Sandy color
	st.set_material(slope_mat)

	var width := 200.0
	var length := 200.0
	var steps := 20
	var shallow_y := -1.0
	var deep_y := -25.0

	for z_i in range(steps):
		for x_i in range(steps):
			var x0 := -width / 2.0 + x_i * (width / steps)
			var x1 := x0 + width / steps
			var z0 := -z_i * (length / steps)
			var z1 := z0 - length / steps
			var y0 := lerpf(shallow_y, deep_y, float(z_i) / steps)
			var y1 := lerpf(shallow_y, deep_y, float(z_i + 1) / steps)

			st.set_normal(Vector3.UP)
			# Triangle 1
			st.add_vertex(Vector3(x0, y0, z0))
			st.add_vertex(Vector3(x0, y1, z1))
			st.add_vertex(Vector3(x1, y0, z0))
			# Triangle 2
			st.add_vertex(Vector3(x1, y0, z0))
			st.add_vertex(Vector3(x0, y1, z1))
			st.add_vertex(Vector3(x1, y1, z1))

	var slope_mesh := st.commit()
	var slope_instance := MeshInstance3D.new()
	slope_instance.mesh = slope_mesh
	add_child(slope_instance)


func _add_test_cube(pos: Vector3, color: Color, size: Vector3) -> void:
	var cube := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	cube.mesh = box
	cube.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	cube.material_override = mat
	add_child(cube)
