extends Node3D

## Visual test for reflections on water and surfaces.
## Verifies:
## - SSR (Screen-Space Reflections) on water
## - ReflectionProbe fallback for off-screen objects
## - OmniLight3D reflecting on water surface
## - Emissive materials reflecting on water
## - Distant light billboard visibility near water
## - Specular highlights from directional light on water
##
## Controls:
##   WASD — move camera
##   Mouse — look around
##   1 — toggle SSR
##   2 — toggle ReflectionProbe
##   3 — toggle lights
##   4 — cycle time of day (noon → sunset → night → dawn)
##   ESC — quit

var _ocean: OceanMesh
var _camera: Camera3D
var _light: DirectionalLight3D
var _environment: WorldEnvironment
var _probe: ReflectionProbe
var _env: Environment

# State
var _ssr_enabled: bool = true
var _probe_enabled: bool = true
var _lights_enabled: bool = true
var _time_preset: int = 0  # 0=noon, 1=sunset, 2=night, 3=dawn
var _mouse_captured: bool = false
var _yaw: float = 0.0
var _pitch: float = -10.0

# Light references for toggling
var _omni_lights: Array[OmniLight3D] = []

# HUD
var _label: Label


func _ready() -> void:
	_setup_environment()
	_setup_camera()
	_setup_sun()
	_setup_reflection_probe()
	_setup_ocean()
	_setup_test_geometry()
	_setup_lights()
	_setup_emissive_objects()
	_setup_hud()

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_mouse_captured = true

	# Debug: verify which environment is active and SSR state
	call_deferred("_debug_env")

	Log.info("testing", "Reflections Test ready. 1=SSR, 2=ReflectionProbe, 3=lights, 4=time, WASD=move, Mouse=look, ESC=quit")


func _debug_env() -> void:
	var env: Environment = get_viewport().world_3d.environment
	if env:
		Log.info("testing", "Active env SSR: %s, max_steps: %d, reflected_source: %d" % [
			env.ssr_enabled, env.ssr_max_steps, env.reflected_light_source])
	else:
		Log.warn("testing", "No active environment found!")


func _setup_environment() -> void:
	_environment = WorldEnvironment.new()
	_env = Environment.new()
	_env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.38, 0.45, 0.55)
	mat.sky_horizon_color = Color(0.64, 0.68, 0.74)
	mat.ground_bottom_color = Color(0.12, 0.10, 0.08)
	mat.ground_horizon_color = Color(0.37, 0.33, 0.28)
	sky.sky_material = mat
	_env.sky = sky

	_env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	_env.ambient_light_sky_contribution = 0.8
	_env.ambient_light_energy = 1.0
	_env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	# SSR — the main thing we're testing
	_env.ssr_enabled = true
	_env.ssr_max_steps = 128
	_env.ssr_fade_in = 0.15
	_env.ssr_fade_out = 2.0
	_env.ssr_depth_tolerance = 0.2

	# Glow for emissive bloom
	_env.glow_enabled = true
	_env.glow_intensity = 0.5
	_env.glow_bloom = 0.2
	_env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	_env.glow_hdr_threshold = 0.8

	_env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_env.tonemap_exposure = 1.0

	_environment.environment = _env
	add_child(_environment)


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.position = Vector3(0, 5, 15)
	_camera.rotation_degrees = Vector3(-10, 0, 0)
	_camera.current = true
	_camera.far = 2000.0
	add_child(_camera)


func _setup_sun() -> void:
	_light = DirectionalLight3D.new()
	_light.rotation_degrees = Vector3(-45, 45, 0)
	_light.shadow_enabled = true
	_light.light_energy = 1.2
	_light.light_color = Color(1.0, 0.95, 0.9)
	add_child(_light)


func _setup_reflection_probe() -> void:
	_probe = ReflectionProbe.new()
	_probe.box_projection = false
	_probe.size = Vector3(500, 100, 500)
	_probe.position = Vector3(0, 25, 0)
	_probe.update_mode = ReflectionProbe.UPDATE_ONCE
	add_child(_probe)


func _setup_ocean() -> void:
	# Use OceanManager (the autoload) to get the full FFT pipeline
	# Force-initialize auto-detects HIGH on capable GPUs and starts FFT.
	# Do NOT call set_water_quality() after — it would shut down the pipeline
	# (set_quality returns false when already at target, triggering shutdown logic).
	if not OceanManager.is_initialized():
		OceanManager.force_initialize()
	OceanManager.set_enabled(true)
	OceanManager.set_camera(_camera)
	_ocean = OceanManager.get_ocean_mesh()

	# Override shore mask with a plain white texture so ocean renders everywhere
	# in the test scene (the prebaked shore mask is for the real Morrowind map)
	if _ocean:
		var white_img := Image.create(1, 1, false, Image.FORMAT_L8)
		white_img.set_pixel(0, 0, Color.WHITE)
		var white_tex := ImageTexture.create_from_image(white_img)
		_ocean.set_shore_mask(white_tex, Rect2(-50000, -50000, 100000, 100000))


func _setup_test_geometry() -> void:
	# Bathymetry test bed — varied seafloor depths for validating depth-driven
	# Beer-Lambert absorption and refraction UV offset in upcoming shader phases.
	# Checker-textured so refraction distortion is visible to the eye.
	var checker_tex: ImageTexture = _make_checker_texture(64, 8,
		Color(0.55, 0.50, 0.40), Color(0.30, 0.28, 0.22))

	var seabed_mat := StandardMaterial3D.new()
	seabed_mat.albedo_texture = checker_tex
	seabed_mat.uv1_scale = Vector3(10.0, 10.0, 1.0)
	seabed_mat.roughness = 0.85

	# Deep base floor — ambient seabed under everything, y = -25m (25m water column)
	var base_floor := MeshInstance3D.new()
	var base_plane := PlaneMesh.new()
	base_plane.size = Vector2(500, 500)
	base_floor.mesh = base_plane
	base_floor.position = Vector3(0, -25, 0)
	base_floor.material_override = seabed_mat
	add_child(base_floor)

	# Medium-depth mesa (central) — box with top at y=-8, bottom at y=-25
	# 8m water column above the mesa top. Pillars will sit on this.
	var mesa := MeshInstance3D.new()
	var mesa_box := BoxMesh.new()
	mesa_box.size = Vector3(80, 17, 80)
	mesa.mesh = mesa_box
	mesa.position = Vector3(0, -16.5, -10)  # center y so top at -8, bottom at -25
	mesa.material_override = seabed_mat
	add_child(mesa)

	# Shallow shelf — box with top at y=-3 (3m water column), bottom at y=-25
	var shelf := MeshInstance3D.new()
	var shelf_box := BoxMesh.new()
	shelf_box.size = Vector3(30, 22, 30)
	shelf.mesh = shelf_box
	shelf.position = Vector3(35, -14, 20)  # center y so top at -3
	shelf.material_override = seabed_mat
	add_child(shelf)

	# Fully submerged rock near camera — top at y=-1 (1m underwater), bottom at y=-5
	# This is the "invisible without refraction" canary. After Phase 1 it should
	# become visible as a dim absorbed shape.
	var rock := MeshInstance3D.new()
	var rock_box := BoxMesh.new()
	rock_box.size = Vector3(4, 4, 4)
	rock.mesh = rock_box
	rock.position = Vector3(-7, -3, 6)  # center y so top at -1, bottom at -5
	var rock_mat := StandardMaterial3D.new()
	rock_mat.albedo_color = Color(0.5, 0.45, 0.35)
	rock_mat.roughness = 0.6
	rock.material_override = rock_mat
	add_child(rock)

	# Half-submerged monolith — spans y=-5 to y=+5, crosses the waterline cleanly.
	# After Phase 1 you should see its above-water and below-water parts with
	# distinct appearance (absorbed tint below, fresnel reflection where visible).
	var monolith := MeshInstance3D.new()
	var mono_box := BoxMesh.new()
	mono_box.size = Vector3(3, 10, 3)
	monolith.mesh = mono_box
	monolith.position = Vector3(7, 0, 6)  # center y=0, half above / half below
	var mono_mat := StandardMaterial3D.new()
	mono_mat.albedo_color = Color(0.85, 0.85, 0.90)  # bright so waterline cut is obvious
	mono_mat.roughness = 0.7
	monolith.material_override = mono_mat
	add_child(monolith)

	# DIAGNOSTIC: Glossy mirror plane next to ocean (StandardMaterial3D)
	# If this reflects but ocean doesn't → shader issue. If neither reflects → env issue.
	var mirror := MeshInstance3D.new()
	mirror.mesh = PlaneMesh.new()
	mirror.mesh.size = Vector2(20, 20)
	mirror.position = Vector3(30, 0.1, -10)
	var mirror_mat := StandardMaterial3D.new()
	mirror_mat.albedo_color = Color(0.05, 0.05, 0.05)
	mirror_mat.metallic = 1.0
	mirror_mat.roughness = 0.0
	mirror_mat.metallic_specular = 1.0
	mirror.material_override = mirror_mat
	add_child(mirror)

	# Tall colorful pillars standing on the mesa (mesa top at y=-8).
	# _add_pillar's position formula puts the pillar base at pos.y - 3, so to
	# sit pillar bases on the mesa top (y=-8) we use pos.y = -5.
	_add_pillar(Vector3(-12, -5, -15), Color(0.8, 0.2, 0.1), 2.0, 12.0)  # Red
	_add_pillar(Vector3(12, -5, -15), Color(0.1, 0.6, 0.2), 2.0, 12.0)   # Green
	_add_pillar(Vector3(0, -5, -25), Color(0.1, 0.2, 0.8), 2.0, 12.0)    # Blue
	_add_pillar(Vector3(-20, -5, -5), Color(0.9, 0.8, 0.1), 2.0, 8.0)    # Yellow
	_add_pillar(Vector3(20, -5, -5), Color(0.8, 0.1, 0.8), 2.0, 8.0)     # Purple

	# Metallic sphere (should show sky/environment reflections)
	var sphere := MeshInstance3D.new()
	sphere.mesh = SphereMesh.new()
	sphere.mesh.radius = 2.0
	sphere.mesh.height = 4.0
	sphere.position = Vector3(0, 4, -10)
	var metal_mat := StandardMaterial3D.new()
	metal_mat.metallic = 1.0
	metal_mat.roughness = 0.1
	metal_mat.albedo_color = Color(0.9, 0.9, 0.9)
	sphere.material_override = metal_mat
	add_child(sphere)


func _make_checker_texture(size_px: int, cell_px: int, a: Color, b: Color) -> ImageTexture:
	# Procedural checkerboard used to make seafloor refraction distortion visually
	# obvious when Phase 2 lands. Two-tone to keep grid axis alignment readable.
	var img := Image.create(size_px, size_px, false, Image.FORMAT_RGBA8)
	for y in size_px:
		for x in size_px:
			var cell: int = (x / cell_px + y / cell_px) & 1
			img.set_pixel(x, y, a if cell == 0 else b)
	return ImageTexture.create_from_image(img)


func _add_pillar(pos: Vector3, color: Color, radius: float, height: float) -> void:
	var pillar := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = height
	pillar.mesh = cyl
	pillar.position = pos + Vector3(0, height * 0.5 - 3.0, 0)  # Partially submerged
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.6
	pillar.material_override = mat
	add_child(pillar)


func _setup_lights() -> void:
	# OmniLight3D near water — should create specular reflections
	_add_omni_light(Vector3(-8, 3, -8), Color(1.0, 0.6, 0.2), 15.0, 2.0)   # Warm torch
	_add_omni_light(Vector3(8, 3, -8), Color(0.2, 0.5, 1.0), 15.0, 1.5)    # Cool blue
	_add_omni_light(Vector3(0, 2, 5), Color(1.0, 0.3, 0.3), 12.0, 1.8)     # Red
	_add_omni_light(Vector3(-15, 4, -20), Color(0.3, 1.0, 0.3), 20.0, 2.5) # Green — farther

	# Flickering fire light (simulating MW torch)
	var fire_light := OmniLight3D.new()
	fire_light.position = Vector3(0, 3, -15)
	fire_light.light_color = Color(1.0, 0.7, 0.3)
	fire_light.omni_range = 18.0
	fire_light.light_energy = 2.5
	fire_light.shadow_enabled = true
	add_child(fire_light)
	_omni_lights.append(fire_light)

	# Animate the fire light
	var tween := create_tween().set_loops()
	tween.tween_property(fire_light, "light_energy", 3.0, 0.3).set_ease(Tween.EASE_IN)
	tween.tween_property(fire_light, "light_energy", 1.8, 0.2).set_ease(Tween.EASE_OUT)
	tween.tween_property(fire_light, "light_energy", 2.8, 0.4).set_ease(Tween.EASE_IN)
	tween.tween_property(fire_light, "light_energy", 2.0, 0.15).set_ease(Tween.EASE_OUT)


func _add_omni_light(pos: Vector3, color: Color, range_m: float, energy: float) -> void:
	var omni := OmniLight3D.new()
	omni.position = pos
	omni.light_color = color
	omni.omni_range = range_m
	omni.light_energy = energy
	omni.shadow_enabled = false
	add_child(omni)
	_omni_lights.append(omni)

	# Visual marker — small emissive sphere at light position
	var marker := MeshInstance3D.new()
	marker.mesh = SphereMesh.new()
	marker.mesh.radius = 0.3
	marker.mesh.height = 0.6
	marker.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 3.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	marker.material_override = mat
	add_child(marker)


func _setup_emissive_objects() -> void:
	# Emissive cube — simulates a glowing window or lava
	var emissive_cube := MeshInstance3D.new()
	emissive_cube.mesh = BoxMesh.new()
	emissive_cube.mesh.size = Vector3(3, 3, 3)
	emissive_cube.position = Vector3(-15, 2, -10)
	var em_mat := StandardMaterial3D.new()
	em_mat.albedo_color = Color(1.0, 0.5, 0.1)
	em_mat.emission_enabled = true
	em_mat.emission = Color(1.0, 0.5, 0.1)
	em_mat.emission_energy_multiplier = 5.0
	emissive_cube.material_override = em_mat
	add_child(emissive_cube)

	# Emissive strip — simulates a neon/magic glow
	var emissive_strip := MeshInstance3D.new()
	emissive_strip.mesh = BoxMesh.new()
	emissive_strip.mesh.size = Vector3(10, 0.5, 0.5)
	emissive_strip.position = Vector3(15, 3, -10)
	var strip_mat := StandardMaterial3D.new()
	strip_mat.albedo_color = Color(0.2, 0.8, 1.0)
	strip_mat.emission_enabled = true
	strip_mat.emission = Color(0.2, 0.8, 1.0)
	strip_mat.emission_energy_multiplier = 4.0
	emissive_strip.material_override = strip_mat
	add_child(emissive_strip)


func _setup_hud() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_label = Label.new()
	_label.position = Vector2(10, 10)
	_label.add_theme_font_size_override("font_size", 18)
	canvas.add_child(_label)
	_update_hud()


func _update_hud() -> void:
	var time_names := ["Noon", "Sunset", "Night", "Dawn"]
	_label.text = "Reflections Test\n"
	_label.text += "SSR: %s (1)\n" % ("ON" if _ssr_enabled else "OFF")
	_label.text += "ReflectionProbe: %s (2)\n" % ("ON" if _probe_enabled else "OFF")
	_label.text += "Lights: %s (3)\n" % ("ON" if _lights_enabled else "OFF")
	_label.text += "Time: %s (4)\n" % time_names[_time_preset]
	_label.text += "WASD=move, Mouse=look, ESC=quit"


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_1:
				_ssr_enabled = not _ssr_enabled
				_env.ssr_enabled = _ssr_enabled
				_update_hud()
			KEY_2:
				_probe_enabled = not _probe_enabled
				_probe.visible = _probe_enabled
				_update_hud()
			KEY_3:
				_lights_enabled = not _lights_enabled
				for l: OmniLight3D in _omni_lights:
					l.visible = _lights_enabled
				_update_hud()
			KEY_4:
				_time_preset = (_time_preset + 1) % 4
				_apply_time_preset()
				_update_hud()
			KEY_ESCAPE:
				if _mouse_captured:
					Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
					_mouse_captured = false
				else:
					get_tree().quit()

	if event is InputEventMouseMotion and _mouse_captured:
		_yaw -= event.relative.x * 0.2
		_pitch -= event.relative.y * 0.2
		_pitch = clampf(_pitch, -89.0, 89.0)
		_camera.rotation_degrees = Vector3(_pitch, _yaw, 0)

	if event is InputEventMouseButton and event.pressed:
		if not _mouse_captured:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			_mouse_captured = true


func _process(delta: float) -> void:
	# WASD movement
	var speed := 20.0 * delta
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		dir -= _camera.global_transform.basis.z
	if Input.is_key_pressed(KEY_S):
		dir += _camera.global_transform.basis.z
	if Input.is_key_pressed(KEY_A):
		dir -= _camera.global_transform.basis.x
	if Input.is_key_pressed(KEY_D):
		dir += _camera.global_transform.basis.x
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= 3.0
	if dir.length_squared() > 0.01:
		_camera.position += dir.normalized() * speed


func _apply_time_preset() -> void:
	match _time_preset:
		0:  # Noon
			_light.rotation_degrees = Vector3(-60, 45, 0)
			_light.light_energy = 1.2
			_light.light_color = Color(1.0, 0.98, 0.95)
		1:  # Sunset
			_light.rotation_degrees = Vector3(-8, 90, 0)
			_light.light_energy = 0.8
			_light.light_color = Color(1.0, 0.6, 0.3)
		2:  # Night
			_light.rotation_degrees = Vector3(-30, -45, 0)
			_light.light_energy = 0.15
			_light.light_color = Color(0.5, 0.55, 0.7)
		3:  # Dawn
			_light.rotation_degrees = Vector3(-10, -90, 0)
			_light.light_energy = 0.6
			_light.light_color = Color(1.0, 0.7, 0.5)
