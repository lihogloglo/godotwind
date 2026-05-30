extends Node3D

## Visual test for ocean shore improvements.
## Tests:
## - Depth-buffer shore blending (smooth alpha fade at terrain edges)
## - FFT buoyancy sync (floating cubes match FFT wave surface)
## - Foam distance fade (no popping at LOD boundaries)
## - Refraction at shore edges (no terrain bleeding)
## - Normal flattening at distance (reduced shimmer)
##
## Controls:
##   WASD — move camera
##   Mouse — look around
##   Q/E — up/down
##   1-3 — shore_blend_distance presets (1m, 3m, 10m)
##   F — toggle fly to distant view (check foam fade + normal flattening)

@warning_ignore("untyped_declaration")

const BuoyancyBodyScript = preload("res://src/core/water/buoyancy_body.gd")
const BuoyancyProbeScript = preload("res://src/core/water/buoyancy_probe.gd")

var _camera: Camera3D
var _light: DirectionalLight3D
var _ocean: OceanMesh
var _buoyancy_cubes: Array[MeshInstance3D] = []
var _debug_markers: Array[MeshInstance3D] = []
var _debug_grid_visible := false
var _label: Label
var _mouse_captured := true
var _yaw := 0.0
var _pitch := -15.0
var _move_speed := 20.0
var _distant_view := false

const BUOYANCY_CUBE_COUNT := 8
const SEA_LEVEL := 0.0
const DEBUG_GRID_SIZE := 10  # 10x10 grid of markers
const DEBUG_GRID_SPACING := 5.0  # meters between markers


func _ready() -> void:
	# Environment with SSR
	var world_env := WorldEnvironment.new()
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
	env.ssr_enabled = true
	env.ssr_max_steps = 64
	env.ssr_fade_in = 0.15
	env.ssr_fade_out = 2.0
	env.ssr_depth_tolerance = 0.2
	world_env.environment = env
	add_child(world_env)

	# Sun
	_light = DirectionalLight3D.new()
	_light.rotation_degrees = Vector3(-35, 45, 0)
	_light.shadow_enabled = true
	_light.light_energy = 1.2
	add_child(_light)

	# Reflection probe
	var probe := ReflectionProbe.new()
	probe.box_projection = false
	probe.size = Vector3(2000, 200, 2000)
	probe.position = Vector3(0, 50, 0)
	add_child(probe)

	# Camera
	_camera = Camera3D.new()
	_camera.position = Vector3(0, 8, 30)
	_camera.rotation_degrees = Vector3(-15, 0, 0)
	_camera.current = true
	_camera.far = 10000.0
	add_child(_camera)

	# No fake terrain — uses the real Morrowind terrain via Terrain3D if present

	# ================================================================
	# BUOYANCY TEST — BuoyancyBody3D with probe-based physics
	# ================================================================
	for i in BUOYANCY_CUBE_COUNT:
		var body := RigidBody3D.new()
		body.set_script(BuoyancyBodyScript)
		body.mass = 500.0  # 500kg crate
		body.buoyancy_force = 12.0
		body.buoyancy_power = 1.5
		body.drag_linear = 0.05
		body.drag_angular = 0.1
		body.position = Vector3(-40 + i * 12, 2, -20 - i * 5)

		# Visual mesh
		var cube := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(2, 2, 2)
		cube.mesh = box
		var cube_mat := StandardMaterial3D.new()
		cube_mat.albedo_color = Color(0.9, 0.3, 0.1).lerp(Color(0.1, 0.3, 0.9), float(i) / BUOYANCY_CUBE_COUNT)
		cube.material_override = cube_mat
		body.add_child(cube)

		# Collision shape
		var col := CollisionShape3D.new()
		var col_shape := BoxShape3D.new()
		col_shape.size = Vector3(2, 2, 2)
		col.shape = col_shape
		body.add_child(col)

		# 4 buoyancy probes at bottom corners
		for corner in [Vector3(-0.8, -0.8, -0.8), Vector3(0.8, -0.8, -0.8),
					   Vector3(-0.8, -0.8, 0.8), Vector3(0.8, -0.8, 0.8)]:
			var bp := Marker3D.new()
			bp.set_script(BuoyancyProbeScript)
			bp.position = corner
			body.add_child(bp)

		add_child(body)
		_buoyancy_cubes.append(cube)

	# ================================================================
	# OCEAN — use WaterSystem autoload for full FFT pipeline
	# If WaterSystem is disabled in project settings, force-initialize it.
	# This gives us the compute pipeline (displacement/normal textures) that
	# the FFT shader requires as global uniforms.
	# ================================================================
	if WaterSystem:
		ProjectSettings.set_setting("ocean/quality", 1)
	if WaterSystem and not WaterSystem.is_initialized():
		WaterSystem.force_initialize()
	if WaterSystem and WaterSystem.is_initialized():
		_ocean = WaterSystem.get_ocean_mesh()
		WaterSystem.set_camera(_camera)
		# Override shore mask to all-white (deep ocean everywhere) for this test.
		# The test scene has no real terrain, so the prebaked Morrowind shore mask
		# would suppress waves near the camera position (marked as "land").
		var white_img := Image.create(1, 1, false, Image.FORMAT_L8)
		white_img.set_pixel(0, 0, Color.WHITE)
		var white_tex := ImageTexture.create_from_image(white_img)
		_ocean.set_shore_mask(white_tex, Rect2(-50000, -50000, 100000, 100000))
	else:
		# Fallback: standalone flat mesh when the FFT autoload is unavailable.
		_ocean = OceanMesh.new()
		add_child(_ocean)
		_ocean.initialize(5000.0, 0)

	# ================================================================
	# UI LABEL
	# ================================================================
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_label = Label.new()
	_label.position = Vector2(10, 10)
	_label.add_theme_font_size_override("font_size", 16)
	canvas.add_child(_label)

	# ================================================================
	# DEBUG WAVE GRID — red spheres showing CPU-evaluated wave surface
	# Toggle with G key. Shows where the physics layer thinks the surface is.
	# ================================================================
	var debug_mesh := SphereMesh.new()
	debug_mesh.radius = 0.15
	debug_mesh.height = 0.3
	var debug_mat := StandardMaterial3D.new()
	debug_mat.albedo_color = Color(1.0, 0.1, 0.1)
	debug_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for gz in DEBUG_GRID_SIZE:
		for gx in DEBUG_GRID_SIZE:
			var marker := MeshInstance3D.new()
			marker.mesh = debug_mesh
			marker.material_override = debug_mat
			marker.visible = false
			add_child(marker)
			_debug_markers.append(marker)

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	Log.info("water", "[Shore Test] Scene ready. WASD=move, Mouse=look, 1-3=shore blend, G=debug grid, F=distant view")


func _process(delta: float) -> void:
	# Camera movement
	var input := Vector3.ZERO
	if Input.is_action_pressed("ui_up") or Input.is_key_pressed(KEY_W):
		input.z -= 1
	if Input.is_action_pressed("ui_down") or Input.is_key_pressed(KEY_S):
		input.z += 1
	if Input.is_action_pressed("ui_left") or Input.is_key_pressed(KEY_A):
		input.x -= 1
	if Input.is_action_pressed("ui_right") or Input.is_key_pressed(KEY_D):
		input.x += 1
	if Input.is_key_pressed(KEY_Q):
		input.y -= 1
	if Input.is_key_pressed(KEY_E):
		input.y += 1

	if input != Vector3.ZERO:
		var dir := _camera.global_transform.basis * input.normalized() * _move_speed * delta
		_camera.global_position += dir

	# Update ocean mesh position (skip if WaterSystem owns it)
	if not WaterSystem or not WaterSystem.is_initialized():
		_ocean.update_position(Vector3(_camera.global_position.x, SEA_LEVEL, _camera.global_position.z))

	# Buoyancy handled by BuoyancyBody3D._physics_process()

	# Debug wave grid — show CPU-evaluated wave surface
	if _debug_grid_visible:
		_update_debug_grid()

	# UI
	var blend_dist := 3.0
	var ocean_mat := _ocean.get_material()
	if ocean_mat:
		@warning_ignore("unsafe_method_access")
		var param = ocean_mat.get_shader_parameter("shore_blend_distance")
		if param != null:
			blend_dist = param

	_label.text = "Ocean Shore Test\n"
	_label.text += "shore_blend_distance: %.1fm (press 1/2/3)\n" % blend_dist
	_label.text += "Quality: %s\n" % ("FFT" if _ocean.get_quality() == OceanMesh.QualityMode.HIGH else "Flat")
	_label.text += "Cubes: %d (should bob with waves)\n" % _buoyancy_cubes.size()
	_label.text += "Debug grid: %s (G to toggle)\n" % ("ON — red spheres = CPU wave surface" if _debug_grid_visible else "OFF")
	_label.text += "F = distant view | WASD + mouse = fly | Q/E = up/down"


func _update_debug_grid() -> void:
	if not WaterSystem or not WaterSystem.is_initialized():
		return
	var cam_pos := _camera.global_position
	var half := DEBUG_GRID_SIZE / 2.0
	var idx := 0
	for gz in DEBUG_GRID_SIZE:
		for gx in DEBUG_GRID_SIZE:
			var world_x := cam_pos.x + (gx - half) * DEBUG_GRID_SPACING
			var world_z := cam_pos.z + (gz - half) * DEBUG_GRID_SPACING
			var query_pos := Vector3(world_x, 0, world_z)
			var wave_h := WaterSystem.get_wave_height(query_pos)
			_debug_markers[idx].global_position = Vector3(world_x, wave_h, world_z)
			idx += 1


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _mouse_captured:
		_yaw -= event.relative.x * 0.2
		_pitch -= event.relative.y * 0.2
		_pitch = clampf(_pitch, -89, 89)
		_camera.rotation_degrees = Vector3(_pitch, _yaw, 0)

	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE:
				_mouse_captured = not _mouse_captured
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _mouse_captured else Input.MOUSE_MODE_VISIBLE

			KEY_1:
				_set_shore_blend(1.0)
			KEY_2:
				_set_shore_blend(3.0)
			KEY_3:
				_set_shore_blend(10.0)

			KEY_G:
				_debug_grid_visible = not _debug_grid_visible
				for marker in _debug_markers:
					marker.visible = _debug_grid_visible
				Log.info("water", "[Shore Test] Debug grid: %s" % ("ON" if _debug_grid_visible else "OFF"))

			KEY_F:
				_distant_view = not _distant_view
				if _distant_view:
					_camera.position = Vector3(0, 50, 500)
					_camera.rotation_degrees = Vector3(-5, 180, 0)
					_pitch = -5.0
					_yaw = 180.0
				else:
					_camera.position = Vector3(0, 8, 30)
					_camera.rotation_degrees = Vector3(-15, 0, 0)
					_pitch = -15.0
					_yaw = 0.0


func _set_shore_blend(distance: float) -> void:
	var ocean_mat := _ocean.get_material()
	if ocean_mat:
		ocean_mat.set_shader_parameter("shore_blend_distance", distance)
		Log.info("water", "[Shore Test] shore_blend_distance = %.1f" % distance)
