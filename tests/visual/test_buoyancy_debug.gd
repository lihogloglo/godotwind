## Buoyancy debug test scene — visualize CPU wave sample vs shader mesh.
##
## Interactive diagnostic for the `WaterSystem.get_wave_height()` CPU
## sampler. Renders a 40×40 grid of magenta markers at the heights the
## sampler returns, centered on the active camera and updated every
## frame. A/B directly against the visible FFT ocean mesh: the markers
## should sit on the crests and troughs, not hover above or sink below.
##
## Controls:
##   B     Launch a buoyant sphere forward from the camera
##   V     Toggle the buoyancy debug mesh grid (ON by default)
##   Hold right-click + WASD/Space/Shift to fly the camera (FlyCamera)
##
## This scene is intentionally minimal — ocean + fly camera + beach.
## No Morrowind ESM load, no carryables, no streaming. The point is
## to see the CPU buoyancy surface against the FFT ocean in isolation.
##
## Run: godot --path . res://tests/visual/test_buoyancy_debug.tscn
@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_property_access", "unsafe_cast")
extends Node3D

const FlyCameraScript := preload("res://src/core/player/fly_camera.gd")
const BuoyancyBodyScript := preload("res://src/core/water/buoyancy_body.gd")
const BuoyancyProbeScript := preload("res://src/core/water/buoyancy_probe.gd")
const OceanMeshScript := preload("res://src/core/water/ocean_mesh.gd")
const WeatherTypesScript := preload("res://src/core/weather/weather_types.gd")


const BUOY_DEBUG_GRID: int = 40         # 40×40 = 1600 markers
const BUOY_DEBUG_SPACING: float = 1.0   # 1m between markers → 40m grid

# Weather presets (MW wind range is 0.0-0.9, we lerp inside WaterSystem)
# Index order: 1=Calm, 2=Breeze, 3=Moderate, 4=Storm, 5=Blizzard
const WEATHER_PRESETS: Array = [
	{"name": "Calm",     "wind": 0.1},
	{"name": "Breeze",   "wind": 0.3},
	{"name": "Moderate", "wind": 0.5},
	{"name": "Storm",    "wind": 0.7},
	{"name": "Blizzard", "wind": 0.9},
]
var _current_preset: int = 0

const DEBUG_MODE_NAMES: Array[String] = [
	"Normal",
	"Shore factor (R=0 G=1)",
	"Shore discard zone (red)",
	"Water thickness (blue→red, magenta=sky)",
	"Transmittance (gray)",
	"Fresnel (gray)",
	"SSR hit (green)",
	"Refraction UV offset (red)",
	"Normal.y (white=flat)",
	"SSS scatter factor (sub-surface emission)",
]
var _debug_mode: int = 0
var _sun_low: bool = false
var _sun_light: DirectionalLight3D = null


var _fly_camera: Camera3D = null
var _debug_mmi: MultiMeshInstance3D = null
var _debug_visible: bool = true
var _hint_label: Label = null
var _weather_label: Label = null


func _ready() -> void:
	_build_environment()
	_build_camera()

	# Force the ocean pipeline online in HIGH (FFT) mode so the CPU
	# readback path activates. The autoload would otherwise sit in
	# auto/flat mode, which has no displacement textures to read.
	#
	# IMPORTANT: disable the prebaked shore mask BEFORE force_initialize.
	# The prebaked mask on disk is baked against the Morrowind world
	# bounds and says "land" at our (0,0,0) origin, which makes the
	# FFT shader `discard` every fragment and the ocean mesh vanish.
	# Falling back to the shader's `hint_default_white` default sampler
	# makes `sample_shore` return 1.0 everywhere → ocean renders.
	# Also write the quality into ProjectSettings BEFORE init because
	# `_deferred_init` overwrites `water_quality` from the setting.
	if WaterSystem:
		ProjectSettings.set_setting("ocean/quality", 1)  # HIGH = FFT
		WaterSystem.use_prebaked_shore_mask = false
		if not WaterSystem.is_initialized():
			WaterSystem.force_initialize()
		WaterSystem.set_enabled(true)

	_build_debug_mesh()
	_build_ui()

	Log.info("water", "[buoyancy-debug] Ready — B=spawn sphere, V=toggle debug mesh")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).keycode:
			KEY_B:
				_spawn_buoyant_sphere_from_camera()
			KEY_V:
				_debug_visible = not _debug_visible
				_debug_mmi.visible = _debug_visible
				Log.info("water", "[buoyancy-debug] grid %s" %
					("ON" if _debug_visible else "OFF"))
			KEY_1:
				_apply_weather_preset(0)
			KEY_2:
				_apply_weather_preset(1)
			KEY_3:
				_apply_weather_preset(2)
			KEY_4:
				_apply_weather_preset(3)
			KEY_5:
				_apply_weather_preset(4)
			KEY_D:
				_cycle_debug_mode()
			KEY_L:
				_toggle_sun_angle()
			KEY_G:
				_toggle_mesh_mode()
			KEY_ESCAPE:
				get_tree().quit()


## Toggle the ocean mesh mode between CLIPMAP (default, 11-ring concentric
## scrolling grid) and PROJECTED (Sea of Thieves / Wicked Engine flat N×N
## grid + vertex-shader unproject). FFT pipeline stays live across the
## rebuild. Use for A/B comparison between the two vertex paths on the
## same weather / sun state.
func _toggle_mesh_mode() -> void:
	if WaterSystem == null or not WaterSystem.has_method("rebuild_mesh_with_mode"):
		return
	var current: int = WaterSystem.get_mesh_mode()
	var next: int = 1 if current == 0 else 0
	WaterSystem.rebuild_mesh_with_mode(next)
	Log.info("water", "[buoyancy-debug] mesh mode → %s" %
		("PROJECTED" if next == 1 else "CLIPMAP"))


## Toggle the test scene's directional light between high-noon and
## near-horizon sunset. Low sun is the condition where wave-tip SSS
## is visually strongest — the sun backlights the wave crests, the
## `dot(LIGHT, -VIEW)` factor in the light() function hits max, and
## the crest translucency should glow. If the crests don't glow at
## low sun, the SSS term itself is broken (not just the sun angle).
func _toggle_sun_angle() -> void:
	if _sun_light == null:
		return
	_sun_low = not _sun_low
	if _sun_low:
		# Sun just above the horizon to the north — strong backlight
		# when camera looks northward.
		_sun_light.rotation = Vector3(deg_to_rad(-8.0), 0.0, 0.0)
		_sun_light.light_energy = 1.4
		_sun_light.light_color = Color(1.0, 0.7, 0.45)  # warm sunset
	else:
		# High noon — neutral white, sun overhead-ish.
		_sun_light.rotation = Vector3(-PI / 4, PI / 4, 0)
		_sun_light.light_energy = 1.2
		_sun_light.light_color = Color.WHITE
	Log.info("water", "[buoyancy-debug] sun angle %s" %
		("LOW (sunset)" if _sun_low else "HIGH (noon)"))


func _cycle_debug_mode() -> void:
	_debug_mode = (_debug_mode + 1) % DEBUG_MODE_NAMES.size()
	if WaterSystem and WaterSystem.has_method("set_debug_mode"):
		WaterSystem.set_debug_mode(_debug_mode)
	Log.info("water", "[buoyancy-debug] debug_mode %d = %s" %
		[_debug_mode, DEBUG_MODE_NAMES[_debug_mode]])


func _process(_delta: float) -> void:
	if _debug_visible:
		_update_debug_mesh()
	_update_weather_label()


# ----------------------------------------------------------------------------
# World setup
# ----------------------------------------------------------------------------

func _build_environment() -> void:
	# Sun — stored so KEY_L can cycle between high-noon and sunset angles.
	_sun_light = DirectionalLight3D.new()
	_sun_light.name = "Sun"
	_sun_light.rotation = Vector3(-PI / 4, PI / 4, 0)
	_sun_light.light_energy = 1.2
	_sun_light.shadow_enabled = false
	add_child(_sun_light)

	# Sky / environment
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.36, 0.5, 0.72)
	sky_mat.sky_horizon_color = Color(0.7, 0.8, 0.88)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 0.6
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env_node.environment = env
	add_child(env_node)

	# Optional tiny beach to anchor scale / give a place to stand.
	var beach := StaticBody3D.new()
	beach.collision_layer = 1
	beach.collision_mask = 0
	beach.position = Vector3(0, -1.0, 15)
	add_child(beach)
	var bs := CollisionShape3D.new()
	var bbox := BoxShape3D.new()
	bbox.size = Vector3(20, 2, 8)
	bs.shape = bbox
	beach.add_child(bs)
	var bmi := MeshInstance3D.new()
	var bmesh := BoxMesh.new()
	bmesh.size = Vector3(20, 2, 8)
	bmi.mesh = bmesh
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.85, 0.78, 0.55)
	bmi.material_override = bmat
	beach.add_child(bmi)


func _build_camera() -> void:
	_fly_camera = Camera3D.new()
	_fly_camera.set_script(FlyCameraScript)
	_fly_camera.name = "FlyCamera"
	add_child(_fly_camera)
	# Position + orient AFTER add_child — look_at requires the node
	# to be inside the tree to resolve the global transform.
	_fly_camera.global_position = Vector3(0, 6, 15)
	_fly_camera.look_at(Vector3(0, 0, 0), Vector3.UP)
	(_fly_camera as FlyCamera).enable()
	_fly_camera.current = true


# ----------------------------------------------------------------------------
# Buoyancy dev spawn (KEY_B)
# ----------------------------------------------------------------------------

func _spawn_buoyant_sphere_from_camera() -> void:
	if _fly_camera == null:
		return
	const SPHERE_RADIUS: float = 0.25
	const SPHERE_MASS: float = 5.0
	const LAUNCH_FORWARD_OFFSET: float = 1.5
	const LAUNCH_SPEED: float = 10.0

	var body: BuoyancyBody3D = BuoyancyBodyScript.new()
	body.name = "DevBuoyantSphere"
	body.mass = SPHERE_MASS
	body.buoyancy_force = 6.0
	body.buoyancy_power = 1.3
	body.drag_linear = 0.08
	body.drag_angular = 0.15
	body.collision_layer = 1
	body.collision_mask = 1

	var shape := CollisionShape3D.new()
	var sphere_shape := SphereShape3D.new()
	sphere_shape.radius = SPHERE_RADIUS
	shape.shape = sphere_shape
	body.add_child(shape)

	var mesh_inst := MeshInstance3D.new()
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = SPHERE_RADIUS
	sphere_mesh.height = SPHERE_RADIUS * 2.0
	mesh_inst.mesh = sphere_mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.35, 0.2)
	mat.metallic = 0.1
	mat.roughness = 0.35
	mesh_inst.material_override = mat
	body.add_child(mesh_inst)

	var probe: BuoyancyProbe3D = BuoyancyProbeScript.new()
	probe.name = "Probe_Center"
	probe.buoyancy_multiplier = 1.0
	body.add_child(probe)

	add_child(body)

	var cam_xf := _fly_camera.global_transform
	var forward: Vector3 = -cam_xf.basis.z
	body.global_position = cam_xf.origin + forward * LAUNCH_FORWARD_OFFSET
	body.linear_velocity = forward * LAUNCH_SPEED

	Log.info("water", "[buoyancy-debug] spawned sphere at %v" % body.global_position)


# ----------------------------------------------------------------------------
# Debug mesh (KEY_V)
# ----------------------------------------------------------------------------

func _build_debug_mesh() -> void:
	_debug_mmi = MultiMeshInstance3D.new()
	_debug_mmi.name = "BuoyancyDebugMesh"

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = false
	mm.use_custom_data = false
	var box := BoxMesh.new()
	box.size = Vector3(0.15, 0.15, 0.15)
	mm.mesh = box
	mm.instance_count = BUOY_DEBUG_GRID * BUOY_DEBUG_GRID

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.0, 0.8)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.0, 0.8)
	mat.emission_energy_multiplier = 2.0
	box.material = mat

	_debug_mmi.multimesh = mm
	_debug_mmi.visible = _debug_visible
	# Disable physics interpolation — we write instance transforms
	# from `_process`, not `_physics_process`, and the interpolation
	# pass complains when it can't find a previous-tick snapshot.
	_debug_mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_debug_mmi)


func _update_debug_mesh() -> void:
	if _debug_mmi == null or _fly_camera == null:
		return
	if not WaterSystem or not WaterSystem.is_initialized():
		return

	var cam_xz := Vector2(_fly_camera.global_position.x, _fly_camera.global_position.z)
	var half: float = (BUOY_DEBUG_GRID - 1) * BUOY_DEBUG_SPACING * 0.5
	var origin_x: float = cam_xz.x - half
	var origin_z: float = cam_xz.y - half

	var mm: MultiMesh = _debug_mmi.multimesh
	var idx: int = 0
	var xf := Transform3D.IDENTITY
	for iz in BUOY_DEBUG_GRID:
		var wz: float = origin_z + float(iz) * BUOY_DEBUG_SPACING
		for ix in BUOY_DEBUG_GRID:
			var wx: float = origin_x + float(ix) * BUOY_DEBUG_SPACING
			var sample_pos := Vector3(wx, 0.0, wz)
			var wy: float = WaterSystem.get_wave_height(sample_pos)
			xf.origin = Vector3(wx, wy, wz)
			mm.set_instance_transform(idx, xf)
			idx += 1


# ----------------------------------------------------------------------------
# UI
# ----------------------------------------------------------------------------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	_hint_label = Label.new()
	_hint_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_hint_label.offset_left = 12
	_hint_label.offset_top = 12
	_hint_label.add_theme_font_size_override("font_size", 16)
	_hint_label.add_theme_color_override("font_color", Color.WHITE)
	_hint_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_hint_label.add_theme_constant_override("shadow_offset_x", 2)
	_hint_label.add_theme_constant_override("shadow_offset_y", 2)
	_hint_label.text = "BUOYANCY DEBUG\nB = launch buoyant sphere forward\nV = toggle debug mesh grid\n1-5 = weather preset (calm → blizzard)\nD = cycle shader debug mode\nL = toggle sun angle (high ↔ sunset)\nG = toggle mesh mode (clipmap ↔ projected)\nRMB+WASD = fly camera · ESC = quit"
	layer.add_child(_hint_label)

	_weather_label = Label.new()
	_weather_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_weather_label.offset_right = -12
	_weather_label.offset_top = 12
	_weather_label.offset_left = -360
	_weather_label.add_theme_font_size_override("font_size", 14)
	_weather_label.add_theme_color_override("font_color", Color(1, 0.9, 0.4))
	_weather_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_weather_label.add_theme_constant_override("shadow_offset_x", 2)
	_weather_label.add_theme_constant_override("shadow_offset_y", 2)
	_weather_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_weather_label.text = ""
	layer.add_child(_weather_label)


func _update_weather_label() -> void:
	if _weather_label == null or not WaterSystem:
		return
	if not WaterSystem.is_initialized():
		_weather_label.text = "WaterSystem not initialized"
		return
	# Surface some of the cascade state the buoyancy CPU path actually
	# reads so we can correlate visible differences with the numbers.
	var cascades: Array = WaterSystem._cascade_parameters
	if cascades.is_empty():
		_weather_label.text = "no cascades"
		return
	var preset: Dictionary = WEATHER_PRESETS[_current_preset]
	var lines: Array[String] = [
		"PRESET %d — %s (mw_wind=%.2f)" % [_current_preset + 1, preset.name, preset.wind],
		"DEBUG %d — %s" % [_debug_mode, DEBUG_MODE_NAMES[_debug_mode]],
		"wave_scale=%.2f" % WaterSystem.wave_scale,
	]
	for i in cascades.size():
		var c = cascades[i]
		lines.append("c%d  tile=%.0f  disp=%.2f  wind=%.1f" %
			[i, c.tile_length.x, c.displacement_scale, c.wind_speed])
	_weather_label.text = "\n".join(lines)


## Build a fake `WeatherResult` carrying just the fields `WaterSystem`
## reads and push it through `apply_weather`. This mirrors the runtime
## path used by the main scene's weather system — we drive the same
## `_apply_weather_fft` entry point so the test state exactly matches
## what the live game would produce for the same `wind_speed`.
func _apply_weather_preset(idx: int) -> void:
	if idx < 0 or idx >= WEATHER_PRESETS.size():
		return
	if not WaterSystem or not WaterSystem.is_initialized():
		return
	_current_preset = idx
	var preset: Dictionary = WEATHER_PRESETS[idx]
	var result := WeatherTypesScript.WeatherResult.new()
	result.wind_speed = preset.wind
	# NE wind direction — arbitrary but non-zero so the storm direction
	# path in `_apply_weather_fft` computes a non-default heading.
	var wind_rad: float = deg_to_rad(45.0)
	result.storm_direction = Vector3(sin(wind_rad), 0, cos(wind_rad))
	# cloud_coverage drives water-color darkening; set roughly to match.
	result.cloud_coverage = preset.wind
	WaterSystem.apply_weather(result)
	Log.info("water", "[buoyancy-debug] preset %d = %s (mw_wind=%.2f)" %
		[idx + 1, preset.name, preset.wind])
	# Dump per-cascade sample diagnostics for this preset — helps
	# diagnose CPU-vs-shader amplitude mismatches when the user
	# reports "buoyancy goes much higher than visible waves".
	await get_tree().create_timer(0.3).timeout  # let FFT catch up
	_dump_cpu_sampler_state(Vector3.ZERO)


## One-shot diagnostic: print every piece of state that feeds into
## `get_wave_height()` at a sample world position. Use this to compare
## the CPU buoyancy sampler against the visible shader mesh when
## they disagree — the log output is the canonical breakdown.
func _dump_cpu_sampler_state(world_pos: Vector3) -> void:
	if not WaterSystem or not WaterSystem.is_initialized():
		return
	var cascades: Array = WaterSystem._cascade_parameters
	var bufs: Array = WaterSystem._displacement_cpu_per_cascade
	Log.info("water", "[buoyancy-debug] ======== SAMPLER DUMP @ %s ========" % world_pos)
	Log.info("water", "[buoyancy-debug] shore_factor=%.3f wave_scale=%.3f sea_level=%.2f" % [
		WaterSystem._get_shore_factor(world_pos),
		WaterSystem.wave_scale,
		WaterSystem.sea_level,
	])
	Log.info("water", "[buoyancy-debug] cascades_params=%d bufs=%d" % [cascades.size(), bufs.size()])
	var total_y: float = 0.0
	for i in cascades.size():
		var c = cascades[i]
		var buf_size: int = bufs[i].size() if i < bufs.size() else 0
		var raw := Vector3.ZERO
		if i < bufs.size() and bufs[i].size() > 0:
			raw = WaterSystem._sample_displacement_readback_cascade(world_pos, bufs[i], c.tile_length)
		var scaled_y: float = raw.y * c.displacement_scale
		total_y += scaled_y
		Log.info("water", "[buoyancy-debug] c%d tile=%.0f disp_scale=%.3f wind=%.1f  buf_bytes=%d  raw.y=%.4f  scaled.y=%.4f" % [
			i, c.tile_length.x, c.displacement_scale, c.wind_speed,
			buf_size, raw.y, scaled_y,
		])
	var final_y: float = WaterSystem.sea_level + total_y * WaterSystem._get_shore_factor(world_pos) * WaterSystem.wave_scale
	var reported: float = WaterSystem.get_wave_height(world_pos)
	Log.info("water", "[buoyancy-debug] expected_final_y=%.4f  get_wave_height()=%.4f  delta=%.4f" % [
		final_y, reported, absf(final_y - reported),
	])
	Log.info("water", "[buoyancy-debug] ==================================")
