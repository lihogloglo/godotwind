extends Node3D

## Ocean lab: combined interactive testbed for FFT ocean visuals, shore behavior,
## wetness, waterline/reflection canaries, and buoyancy CPU-vs-GPU sync.
##
## Run:
##   Godot_v4.6-stable_mono_win64.exe --path ... res://tests/visual/test_ocean_lab.tscn

@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_property_access", "unsafe_cast")

const InputActionsScript := preload("res://src/core/input/input_actions.gd")
const FlyCameraScript := preload("res://src/core/player/fly_camera.gd")
const BuoyancyBodyScript := preload("res://src/core/water/buoyancy_body.gd")
const BuoyancyProbeScript := preload("res://src/core/water/buoyancy_probe.gd")
const UnderwaterVolumeScript := preload("res://src/core/water/underwater_volume.gd")
const PrewaterCaptureRendererScript := preload("res://src/core/water/prewater_capture_renderer.gd")
const WaterlineCompositorScript := preload("res://src/core/shaders/effects/waterline_compositor_effect.gd")
const WeatherTypesScript := preload("res://src/core/weather/weather_types.gd")
const HorizonMapManagerScript := preload("res://src/core/world/horizon_map_manager.gd")
const OBJECT_WET_SHADER := preload("res://src/core/shaders/object_wet.gdshader")
const CS := preload("res://src/core/coordinate_system.gd")

const SEA_LEVEL_DEFAULT: float = 0.0
const WATER_REFRACTION_RECEIVER_LAYER_MASK: int = 1 << 18
const WATER_RENDER_LAYER_MASK: int = 1 << 19
const BUOY_DEBUG_GRID: int = 40
const BUOY_DEBUG_SPACING: float = 1.0
const SHORE_SCAN_GRID: int = 6
const SHORE_SCAN_NEIGHBOR: float = 32.0
const DEBUG_MODE_NAMES: Array[String] = [
	"Normal",
	"Shore depth",
	"Shore intersection",
	"Water thickness",
	"Transmittance",
	"Fresnel",
	"SSR hit",
	"Foam",
	"Normal.y",
	"SSS scatter",
]
const UW_DEBUG_MODE_NAMES: Array[String] = [
	"Final",
	"Slab Mask",
	"Depth/Y",
	"Big Wobble",
]
const WL_DEBUG_MODE_NAMES: Array[String] = [
	"Final",
	"Flat",
	"FFT",
	"FFT+Shore",
	"Receiver Mask",
	"Refract",
	"Refract Offset",
	"Source",
	"Camera Split",
	"Pipeline",
]
const WEATHER_PRESETS: Array[Dictionary] = [
	{"name": "Calm", "wind": 0.1, "cloud": 0.1},
	{"name": "Breeze", "wind": 0.3, "cloud": 0.25},
	{"name": "Moderate", "wind": 0.5, "cloud": 0.45},
	{"name": "Storm", "wind": 0.7, "cloud": 0.75},
	{"name": "Blizzard", "wind": 0.9, "cloud": 0.95},
]

var _camera: Camera3D = null
var _world_env: WorldEnvironment = null
var _terrain: Terrain3D = null
var _horizon_mgr: HorizonMapManager = null
var _sun: DirectionalLight3D = null
var _ocean: OceanMesh = null
var _underwater_volume: UnderwaterVolume = null
var _prewater_capture: PrewaterCaptureRenderer = null
var _waterline_compositor: Compositor = null
var _waterline_effect: PostProcessEffect = null
var _debug_mmi: MultiMeshInstance3D = null
var _hud_label: RichTextLabel = null
var _button_grid: GridContainer = null
var _debug_button: Button = null
var _weather_button: Button = null
var _mesh_button: Button = null
var _sun_button: Button = null
var _wet_debug_button: Button = null
var _quality_button: Button = null
var _spray_button: Button = null
var _spray_quality_button: Button = null
var _underwater_button: Button = null
var _underwater_mode_button: Button = null
var _uw_wobble_button: Button = null
var _ocean_surface_button: Button = null
var _uw_debug_button: Button = null
var _waterline_button: Button = null
var _waterline_debug_button: Button = null
var _waterline_res_button: Button = null
var _wireframe_button: Button = null
var _uw_absorption_check: CheckBox = null
var _uw_snell_check: CheckBox = null
var _uw_rays_check: CheckBox = null
var _uw_wobble_check: CheckBox = null
var _uw_particles_check: CheckBox = null
var _uw_meniscus_check: CheckBox = null
var _uw_waterline_check: CheckBox = null
var _uw_perf_label: RichTextLabel = null
var _uw_profile_button: Button = null

var _sea_level: float = SEA_LEVEL_DEFAULT
var _playground_origin: Vector3 = Vector3.ZERO
var _shore_search_status: String = "not searched"
var _wet_margin: float = 0.05
var _wet_albedo_darken: float = 0.6
var _wet_roughness_target: float = 0.05
var _retained_wetness_strength: float = 0.35
var _wet_debug: bool = false
var _wet_dry_rate: float = 0.3

var _test_objects: Array[Dictionary] = []
var _held_object: Dictionary = {}
var _regions_loaded: int = 0
var _textures_loaded: int = 0

var _buoy_grid_visible: bool = false
var _debug_mode: int = 0
var _spray_enabled: bool = true
var _spray_quality: int = 2
var _underwater_volume_enabled: bool = true
var _underwater_active_above: bool = false
var _uw_wobble_enabled: bool = false
var _ocean_surface_visible: bool = true
var _uw_debug_mode: int = 0
var _waterline_compositor_enabled: bool = true
var _waterline_debug_mode: int = 0
var _waterline_resolution_scales: Array[float] = [1.0, 0.75, 0.5, 0.25]
var _waterline_resolution_index: int = 0
var _uw_absorption_enabled: bool = true
var _uw_snell_enabled: bool = true
var _uw_rays_enabled: bool = true
var _uw_wobble_effect_enabled: bool = true
var _uw_particles_enabled: bool = true
var _uw_meniscus_enabled: bool = true
var _uw_ray_shell_count: int = 6
var _uw_ray_shell_spacing_m: float = 16.0
var _uw_ray_intensity: float = 1.8
var _uw_ray_shell_start_m: float = 2.0
var _uw_particle_noise_scale: float = 0.70
var _uw_particle_density: float = 0.15
var _uw_particle_near_gate_m: float = 1.5
var _uw_particle_far_gate_m: float = 95.0
var _uw_profile_running: bool = false
var _uw_profile_step: int = 0
var _uw_profile_frame_count: int = 0
var _uw_profile_accum_ms: float = 0.0
var _uw_profile_results: Array[String] = []
var _wireframe_enabled: bool = false
var _current_weather: int = 0
var _sun_low: bool = false
var _help_visible: bool = true
var _frame_time_accum: float = 0.0
var _frame_time_count: int = 0
var _avg_frame_ms: float = 0.0


func _ready() -> void:
	InputActionsScript.verify()
	RenderingServer.set_debug_generate_wireframes(true)
	_build_environment()
	_build_camera()
	_setup_terrain()
	_sea_level = ProjectSettings.get_setting("ocean/sea_level", SEA_LEVEL_DEFAULT)
	_playground_origin = _find_shore_playground_center()
	_place_camera_at_playground()
	_setup_ocean()
	_setup_underwater_volume()
	_setup_prewater_capture()
	_setup_waterline_compositor()
	_setup_reflection_canaries()
	_setup_wetness()
	_spawn_wet_test_objects()
	_build_buoyancy_debug_mesh()
	_build_ui()
	_apply_weather_preset(0)

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Log.info("water", "[Ocean Lab] Ready - terrain regions=%d textures=%d quality=%s" % [
		_regions_loaded,
		_textures_loaded,
		OceanManager.get_water_quality_name() if OceanManager else "none",
	])


func _exit_tree() -> void:
	_prewater_capture = null
	if _waterline_effect != null:
		_waterline_effect.on_effect_removed()
	_waterline_effect = null
	if _world_env != null:
		_world_env.compositor = null
	_waterline_compositor = null


func _build_environment() -> void:
	_world_env = WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.36, 0.5, 0.72)
	sky_mat.sky_horizon_color = Color(0.70, 0.80, 0.88)
	sky_mat.ground_bottom_color = Color(0.12, 0.10, 0.08)
	sky_mat.ground_horizon_color = Color(0.37, 0.33, 0.28)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 0.65
	env.ambient_light_energy = 1.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.ssr_enabled = true
	env.ssr_max_steps = 96
	env.ssr_fade_in = 0.15
	env.ssr_fade_out = 2.0
	env.ssr_depth_tolerance = 0.2
	env.glow_enabled = true
	env.glow_intensity = 0.45
	env.glow_bloom = 0.2
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_world_env.environment = env
	add_child(_world_env)

	_sun = DirectionalLight3D.new()
	_sun.name = "Sun"
	_sun.rotation = Vector3(-PI / 4.0, PI / 4.0, 0.0)
	_sun.light_energy = 1.2
	_sun.shadow_enabled = true
	add_child(_sun)

	var probe := ReflectionProbe.new()
	probe.name = "OceanLabReflectionProbe"
	probe.box_projection = false
	probe.size = Vector3(1000.0, 200.0, 1000.0)
	probe.position = Vector3(0.0, 50.0, 0.0)
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	add_child(probe)


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "OceanLabFlyCamera"
	_camera.set_script(FlyCameraScript)
	_camera.far = 20000.0
	_camera.current = true
	add_child(_camera)
	_camera.global_position = Vector3(0.0, 35.0, 80.0)
	_camera.look_at(Vector3(0.0, 0.0, 0.0), Vector3.UP)
	(_camera as FlyCamera).move_speed = 55.0
	(_camera as FlyCamera).enable()


func _place_camera_at_playground() -> void:
	if _camera == null:
		return
	_camera.global_position = _playground_origin + Vector3(0.0, 20.0, 58.0)
	_camera.look_at(_playground_origin, Vector3.UP)


func _setup_terrain() -> void:
	_terrain = Terrain3D.new()
	_terrain.name = "OceanLabTerrain3D"
	add_child(_terrain)
	_terrain.set_physics_process(false)
	if _terrain.has_method("set_camera"):
		_terrain.set_camera(_camera)

	if not CS.configure_terrain3d(_terrain):
		Log.warn("water", "[Ocean Lab] Failed to configure Terrain3D")
		return

	var terrain_data_dir := SettingsManager.get_terrain_path()
	if _terrain.data and DirAccess.dir_exists_absolute(terrain_data_dir):
		_terrain.data.load_directory(terrain_data_dir)
		_regions_loaded = _terrain.data.get_region_count()
		Log.info("water", "[Ocean Lab] Terrain loaded: %d regions from %s" % [
			_regions_loaded,
			terrain_data_dir,
		])
	else:
		Log.warn("water", "[Ocean Lab] No terrain data at %s" % terrain_data_dir)


func _find_shore_playground_center() -> Vector3:
	if not _terrain or not _terrain.data or _terrain.data.get_region_count() == 0:
		_shore_search_status = "terrain unavailable, using origin"
		return Vector3(0.0, _sea_level, 0.0)

	var region_locations: Array[Vector2i] = _terrain.data.get_region_locations()
	if region_locations.is_empty():
		_shore_search_status = "no terrain region locations, using origin"
		return Vector3(0.0, _sea_level, 0.0)

	var region_size: float = _terrain.get_region_size() * _terrain.get_vertex_spacing()
	var best_score := INF
	var best_pos := Vector3.ZERO
	var found := false

	for loc: Vector2i in region_locations:
		var region_min := Vector2(loc.x, loc.y) * region_size
		for gz in range(1, SHORE_SCAN_GRID):
			for gx in range(1, SHORE_SCAN_GRID):
				var x := region_min.x + region_size * (float(gx) / float(SHORE_SCAN_GRID))
				var z := region_min.y + region_size * (float(gz) / float(SHORE_SCAN_GRID))
				var pos := Vector3(x, 0.0, z)
				var h: float = CS.get_terrain_height(pos, _terrain)
				var sea_delta := absf(h - _sea_level)
				if sea_delta > 2.0:
					continue

				var has_water := false
				var has_land := false
				for offset: Vector3 in [
					Vector3(SHORE_SCAN_NEIGHBOR, 0.0, 0.0),
					Vector3(-SHORE_SCAN_NEIGHBOR, 0.0, 0.0),
					Vector3(0.0, 0.0, SHORE_SCAN_NEIGHBOR),
					Vector3(0.0, 0.0, -SHORE_SCAN_NEIGHBOR),
				]:
					var nh: float = CS.get_terrain_height(pos + offset, _terrain)
					if nh < _sea_level - 0.5:
						has_water = true
					elif nh > _sea_level + 0.5:
						has_land = true

				if not (has_water and has_land):
					continue

				# Prefer an actual waterline, then a point near the current data center.
				var score := sea_delta + Vector2(x, z).length() * 0.00005
				if score < best_score:
					best_score = score
					best_pos = Vector3(x, _sea_level, z)
					found = true

	if found:
		_shore_search_status = "shore found at (%.1f, %.1f)" % [best_pos.x, best_pos.z]
		Log.info("water", "[Ocean Lab] %s" % _shore_search_status)
		return best_pos

	_shore_search_status = "no coastline sample found, using origin"
	Log.warn("water", "[Ocean Lab] %s" % _shore_search_status)
	return Vector3(0.0, _sea_level, 0.0)


func _setup_ocean() -> void:
	if not OceanManager:
		Log.error("water", "[Ocean Lab] OceanManager autoload missing")
		return

	if OceanManager.has_method("set_underwater_compositor_enabled"):
		OceanManager.set_underwater_compositor_enabled(false)
	ProjectSettings.set_setting("ocean/quality", 1)
	if not OceanManager.is_initialized():
		OceanManager.force_initialize()
	if OceanManager.has_method("set_underwater_compositor_enabled"):
		OceanManager.set_underwater_compositor_enabled(false)
	OceanManager.set_enabled(true)
	OceanManager.set_camera(_camera)
	OceanManager.set_terrain(_terrain)
	_sea_level = OceanManager.get_sea_level()
	_ocean = OceanManager.get_ocean_mesh()
	if _ocean != null:
		_ocean.layers = WATER_RENDER_LAYER_MASK
	if OceanManager.has_method("set_sea_spray_render_layers"):
		OceanManager.set_sea_spray_render_layers(WATER_RENDER_LAYER_MASK)
	if OceanManager.has_method("is_sea_spray_enabled"):
		_spray_enabled = OceanManager.is_sea_spray_enabled()
	if OceanManager.has_method("get_sea_spray_quality"):
		_spray_quality = OceanManager.get_sea_spray_quality()


func _setup_underwater_volume() -> void:
	_underwater_volume = UnderwaterVolumeScript.new()
	_underwater_volume.name = "OceanLabUnderwaterVolume"
	_underwater_volume.set_camera(_camera)
	_underwater_volume.set_sun(_sun)
	_underwater_volume.set_sea_level(_sea_level)
	_underwater_volume.set_active_above_water(_underwater_active_above)
	_underwater_volume.set_debug_mode(_uw_debug_mode)
	_underwater_volume.set_wobble_enabled(_uw_wobble_enabled)
	_underwater_volume.sync_wave_surface_from_water_state(_get_water_state())
	if _underwater_volume.has_method("set_camera_water_level"):
		_underwater_volume.call("set_camera_water_level", _get_camera_water_level())
	_underwater_volume.enabled = _underwater_volume_enabled
	add_child(_underwater_volume)
	_underwater_volume.set_render_layers(WATER_RENDER_LAYER_MASK)


func _setup_prewater_capture() -> void:
	_prewater_capture = PrewaterCaptureRendererScript.new()
	_prewater_capture.name = "OceanLabPrewaterCapture"
	_prewater_capture.near_water_capture_fade_start_m = 280.0
	_prewater_capture.near_water_capture_distance_m = 420.0
	_prewater_capture.configure(_camera, _world_env.environment, WATER_REFRACTION_RECEIVER_LAYER_MASK)
	_prewater_capture.set_capture_enabled(_waterline_compositor_enabled)
	_prewater_capture.set_blend_factor(1.0 if _waterline_compositor_enabled else 0.0)
	_prewater_capture.set_resolution_scale(_get_waterline_resolution_scale())
	_prewater_capture.set_camera_water_level(_get_camera_water_level())
	add_child(_prewater_capture)
	_prewater_capture.update_capture(_get_main_viewport_size())


func _setup_waterline_compositor() -> void:
	if _world_env == null:
		return
	_waterline_effect = WaterlineCompositorScript.new()
	_waterline_effect.effect_enabled = false
	_waterline_effect.blend_factor = 0.0
	if _waterline_effect.has_method("set_debug_mode"):
		_waterline_effect.call("set_debug_mode", _waterline_debug_mode)
	if _waterline_effect.has_method("set_camera_water_level"):
		_waterline_effect.call("set_camera_water_level", _get_camera_water_level())
	if _waterline_effect.has_method("set_near_water_fade_start_distance"):
		_waterline_effect.call("set_near_water_fade_start_distance", 280.0)
	if _waterline_effect.has_method("set_near_water_activation_distance"):
		_waterline_effect.call("set_near_water_activation_distance", 420.0)
	_push_underwater_effect_controls()
	_sync_waterline_sun()
	_push_prewater_capture_to_waterline()
	_waterline_effect.on_effect_added()
	if _waterline_effect.has_method("sync_from_water_state"):
		_waterline_effect.call("sync_from_water_state", _get_water_state())

	_waterline_compositor = Compositor.new()
	_waterline_compositor.compositor_effects = [_waterline_effect]
	_world_env.compositor = _waterline_compositor


func _setup_reflection_canaries() -> void:
	var checker_tex := _make_checker_texture(64, 8, Color(0.55, 0.50, 0.40), Color(0.30, 0.28, 0.22))
	var seabed_mat := StandardMaterial3D.new()
	seabed_mat.albedo_texture = checker_tex
	seabed_mat.uv1_scale = Vector3(10.0, 10.0, 1.0)
	seabed_mat.roughness = 0.85

	_add_box("DeepSeabed", Vector3(160.0, 2.0, 160.0), _lab_pos(Vector3(0.0, -16.0, 0.0)), seabed_mat)
	_add_box("ShallowShelf", Vector3(35.0, 6.0, 35.0), _lab_pos(Vector3(22.0, -4.0, 18.0)), seabed_mat)
	_add_box("SubmergedRock", Vector3(4.0, 4.0, 4.0), _lab_pos(Vector3(-8.0, -3.0, 8.0)), _standard_mat(Color(0.50, 0.45, 0.35), 0.65), true)
	_add_box("HalfSubmergedMonolith", Vector3(3.0, 10.0, 3.0), _lab_pos(Vector3(8.0, 0.0, 9.0)), _standard_mat(Color(0.85, 0.85, 0.90), 0.7), true)
	_add_box("MetalReflectionTarget", Vector3(4.0, 4.0, 4.0), _lab_pos(Vector3(-14.0, 5.0, -12.0)), _metal_mat(), true)
	_add_emissive_marker(_lab_pos(Vector3(12.0, 4.0, -12.0)), Color(1.0, 0.45, 0.12))
	_add_emissive_marker(_lab_pos(Vector3(0.0, 2.5, -20.0)), Color(0.15, 0.65, 1.0))


func _setup_wetness() -> void:
	_horizon_mgr = HorizonMapManagerScript.new()
	if _terrain and _sun:
		_horizon_mgr.initialize(_terrain, _sun)
	_push_wet_uniforms()

	var texture_loader := preload("res://src/core/world/terrain_texture_loader.gd").new()
	if _terrain and _terrain.assets:
		_textures_loaded = texture_loader.load_terrain_textures(_terrain.assets)
	if _textures_loaded == 0 and _horizon_mgr:
		_horizon_mgr._set_param("enable_texturing", false)
		Log.info("water", "[Ocean Lab] No terrain textures - texturing disabled")
	else:
		Log.info("water", "[Ocean Lab] Loaded %d terrain textures" % _textures_loaded)


func _push_wet_uniforms() -> void:
	if _horizon_mgr:
		_horizon_mgr.push_wet_map(_sea_level, _wet_margin, _wet_albedo_darken, _wet_roughness_target)
		_sync_terrain_shore_wetness()


func _sync_terrain_shore_wetness() -> void:
	if _horizon_mgr == null:
		return
	var state := _get_water_state()
	if _horizon_mgr.has_method("push_shore_wave_wetness_from_state"):
		_horizon_mgr.push_shore_wave_wetness_from_state(state, state != null)
		return
	var mat := _get_ocean_material()
	var time := 0.0
	if OceanManager and OceanManager.has_method("get_time"):
		time = OceanManager.get_time()
	_horizon_mgr.push_shore_wave_wetness(mat, time, mat != null)


func _spawn_wet_test_objects() -> void:
	var shapes: Array[Dictionary] = [
		{"name": "WetCube", "mesh": BoxMesh.new(), "offset": Vector3(-18.0, 1.2, 12.0), "color": Color(0.8, 0.3, 0.2), "half_h": 0.5},
		{"name": "WetSphere", "mesh": SphereMesh.new(), "offset": Vector3(-25.0, 1.2, 10.0), "color": Color(0.3, 0.7, 0.3), "half_h": 0.5},
		{"name": "WetCylinder", "mesh": CylinderMesh.new(), "offset": Vector3(-21.0, 1.2, 17.0), "color": Color(0.3, 0.3, 0.8), "half_h": 0.5},
	]
	for spec: Dictionary in shapes:
		var mi := MeshInstance3D.new()
		mi.name = spec["name"]
		mi.mesh = spec["mesh"]
		var mat := ShaderMaterial.new()
		mat.shader = OBJECT_WET_SHADER
		mat.set_shader_parameter("albedo_color", spec["color"])
		mat.set_shader_parameter("roughness", 0.7)
		mat.set_shader_parameter("wet_line_y", -1000.0)
		mat.set_shader_parameter("wet_margin", _wet_margin)
		mat.set_shader_parameter("wet_albedo_darken", _wet_albedo_darken)
		mat.set_shader_parameter("wet_roughness_target", _wet_roughness_target)
		mat.set_shader_parameter("retained_wetness_strength", _retained_wetness_strength)
		mi.material_override = mat
		_mark_refraction_receiver(mi)
		add_child(mi)
		mi.global_position = _lab_pos(spec["offset"])
		_test_objects.append({
			"node": mi,
			"wet_line_local": -float(spec["half_h"]) - 1.0,
			"mat_rid": mat.get_rid(),
			"mesh_bottom": -float(spec["half_h"]),
			"wet_sample_radius": float(spec["half_h"]) * 1.4,
		})


func _build_buoyancy_debug_mesh() -> void:
	_debug_mmi = MultiMeshInstance3D.new()
	_debug_mmi.name = "BuoyancySurfaceGrid"
	_debug_mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = false
	mm.use_custom_data = false
	var box := BoxMesh.new()
	box.size = Vector3(0.15, 0.15, 0.15)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.0, 0.85)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.0, 0.85)
	mat.emission_energy_multiplier = 2.0
	box.material = mat
	mm.mesh = box
	mm.instance_count = BUOY_DEBUG_GRID * BUOY_DEBUG_GRID
	_debug_mmi.multimesh = mm
	_debug_mmi.visible = _buoy_grid_visible
	add_child(_debug_mmi)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "OceanLabUI"
	add_child(layer)

	var control_panel := PanelContainer.new()
	control_panel.position = Vector2(12.0, 12.0)
	control_panel.size = Vector2(520.0, 620.0)
	layer.add_child(control_panel)

	var tabs := TabContainer.new()
	tabs.custom_minimum_size = Vector2(500.0, 590.0)
	control_panel.add_child(tabs)

	var ocean_tab := VBoxContainer.new()
	ocean_tab.name = "Ocean"
	tabs.add_child(ocean_tab)
	_button_grid = _add_button_grid(ocean_tab)
	_weather_button = _add_button(_button_grid, "", func() -> void:
		_apply_weather_preset((_current_weather + 1) % WEATHER_PRESETS.size())
	)
	_quality_button = _add_button(_button_grid, "", Callable(self, "_cycle_quality"))
	_mesh_button = _add_button(_button_grid, "", Callable(self, "_toggle_mesh_mode"))
	_ocean_surface_button = _add_button(_button_grid, "", Callable(self, "_toggle_ocean_surface_visible"))
	_spray_button = _add_button(_button_grid, "", Callable(self, "_toggle_spray"))
	_spray_quality_button = _add_button(_button_grid, "", Callable(self, "_cycle_spray_quality"))
	_sun_button = _add_button(_button_grid, "", Callable(self, "_toggle_sun_angle"))
	_add_button(_button_grid, "Center Shore", Callable(self, "_teleport_to_shore_probe"))

	var buoyancy_tab := VBoxContainer.new()
	buoyancy_tab.name = "Buoy"
	tabs.add_child(buoyancy_tab)
	var buoyancy_grid := _add_button_grid(buoyancy_tab)
	_add_button(buoyancy_grid, "Buoy Grid", Callable(self, "_toggle_buoy_grid"))
	_add_button(buoyancy_grid, "Spawn Buoy", Callable(self, "_spawn_buoyant_sphere_from_camera"))

	var wetness_tab := VBoxContainer.new()
	wetness_tab.name = "Wetness"
	tabs.add_child(wetness_tab)
	var wetness_grid := _add_button_grid(wetness_tab)
	_wet_debug_button = _add_button(wetness_grid, "", Callable(self, "_toggle_wet_debug"))
	_add_slider(wetness_tab, "margin", 0.0, 5.0, _wet_margin, func(val: float) -> void:
		_wet_margin = val
		_push_wet_uniforms()
		_push_object_wet_params()
	)
	_add_slider(wetness_tab, "darken", 0.0, 1.0, _wet_albedo_darken, func(val: float) -> void:
		_wet_albedo_darken = val
		_push_wet_uniforms()
		_push_object_wet_params()
	)
	_add_slider(wetness_tab, "rough", 0.0, 0.5, _wet_roughness_target, func(val: float) -> void:
		_wet_roughness_target = val
		_push_wet_uniforms()
		_push_object_wet_params()
	)

	_build_underwater_tabs(tabs)

	var debug_tab := VBoxContainer.new()
	debug_tab.name = "Debug"
	tabs.add_child(debug_tab)
	var debug_grid := _add_button_grid(debug_tab)
	_debug_button = _add_button(debug_grid, "", Callable(self, "_cycle_debug_mode"))
	_wireframe_button = _add_button(debug_grid, "", Callable(self, "_toggle_wireframe_debug"))
	_add_button(debug_grid, "Help", func() -> void:
		_help_visible = not _help_visible
		_refresh_control_labels()
	)
	_refresh_control_labels()

	_hud_label = RichTextLabel.new()
	_hud_label.bbcode_enabled = true
	_hud_label.fit_content = false
	_hud_label.scroll_active = false
	_hud_label.position = Vector2(550.0, 12.0)
	_hud_label.size = Vector2(520.0, 280.0)
	_hud_label.add_theme_font_size_override("normal_font_size", 14)
	layer.add_child(_hud_label)


func _build_underwater_tabs(tabs: TabContainer) -> void:
	var effects_tab := VBoxContainer.new()
	effects_tab.name = "Underwater"
	tabs.add_child(effects_tab)

	var toggles := GridContainer.new()
	toggles.columns = 2
	effects_tab.add_child(toggles)
	_uw_absorption_check = _add_check(toggles, "Absorption / fog", _uw_absorption_enabled, func(value: bool) -> void:
		_uw_absorption_enabled = value
		_push_underwater_effect_controls()
	)
	_uw_snell_check = _add_check(toggles, "Snell window", _uw_snell_enabled, func(value: bool) -> void:
		_uw_snell_enabled = value
		_push_underwater_effect_controls()
	)
	_uw_rays_check = _add_check(toggles, "Rays", _uw_rays_enabled, func(value: bool) -> void:
		_uw_rays_enabled = value
		_push_underwater_effect_controls()
	)
	_uw_wobble_check = _add_check(toggles, "Wobble", _uw_wobble_effect_enabled, func(value: bool) -> void:
		_uw_wobble_effect_enabled = value
		_push_underwater_effect_controls()
	)
	_uw_particles_check = _add_check(toggles, "Particles", _uw_particles_enabled, func(value: bool) -> void:
		_uw_particles_enabled = value
		_push_underwater_effect_controls()
	)
	_uw_meniscus_check = _add_check(toggles, "Meniscus / refraction", _uw_meniscus_enabled, func(value: bool) -> void:
		_uw_meniscus_enabled = value
		_push_underwater_effect_controls()
	)
	_uw_waterline_check = _add_check(toggles, "Compositor", _waterline_compositor_enabled, func(value: bool) -> void:
		_waterline_compositor_enabled = value
		if _prewater_capture:
			_prewater_capture.set_capture_enabled(_waterline_compositor_enabled)
			_prewater_capture.set_blend_factor(1.0 if _waterline_compositor_enabled else 0.0)
		_refresh_control_labels()
	)

	var utility_row := HBoxContainer.new()
	effects_tab.add_child(utility_row)
	_underwater_button = _add_button(utility_row, "", Callable(self, "_toggle_underwater_volume"))
	_underwater_mode_button = _add_button(utility_row, "", Callable(self, "_toggle_underwater_active_above"))
	_uw_debug_button = _add_button(utility_row, "", Callable(self, "_cycle_uw_debug_mode"))
	_uw_wobble_button = _add_button(utility_row, "", Callable(self, "_toggle_uw_wobble"))
	for button: Button in [_underwater_button, _underwater_mode_button, _uw_debug_button, _uw_wobble_button]:
		button.custom_minimum_size.x = 115.0

	var wl_row := HBoxContainer.new()
	effects_tab.add_child(wl_row)
	_waterline_debug_button = _add_button(wl_row, "", Callable(self, "_cycle_waterline_debug_mode"))
	_waterline_res_button = _add_button(wl_row, "", Callable(self, "_cycle_waterline_resolution"))
	_waterline_debug_button.custom_minimum_size.x = 230.0
	_waterline_res_button.custom_minimum_size.x = 230.0

	_add_slider(effects_tab, "ray count", 1.0, 8.0, float(_uw_ray_shell_count), func(val: float) -> void:
		_uw_ray_shell_count = int(roundf(val))
		_push_underwater_effect_controls()
	)
	_add_slider(effects_tab, "ray dist", 4.0, 45.0, _uw_ray_shell_spacing_m, func(val: float) -> void:
		_uw_ray_shell_spacing_m = val
		_push_underwater_effect_controls()
	)
	_add_slider(effects_tab, "ray power", 0.0, 3.0, _uw_ray_intensity, func(val: float) -> void:
		_uw_ray_intensity = val
		_push_underwater_effect_controls()
	)
	_add_slider(effects_tab, "particle scale", 0.03, 0.70, _uw_particle_noise_scale, func(val: float) -> void:
		_uw_particle_noise_scale = val
		_push_underwater_effect_controls()
	)
	_add_slider(effects_tab, "particle density", 0.0, 1.0, _uw_particle_density, func(val: float) -> void:
		_uw_particle_density = val
		_push_underwater_effect_controls()
	)

	var perf_tab := VBoxContainer.new()
	perf_tab.name = "Perf"
	tabs.add_child(perf_tab)
	_uw_profile_button = _add_button(perf_tab, "Profile: Run", Callable(self, "_toggle_underwater_profile"))
	_uw_perf_label = RichTextLabel.new()
	_uw_perf_label.bbcode_enabled = true
	_uw_perf_label.fit_content = false
	_uw_perf_label.scroll_active = false
	_uw_perf_label.custom_minimum_size = Vector2(480.0, 220.0)
	_uw_perf_label.add_theme_font_size_override("normal_font_size", 13)
	perf_tab.add_child(_uw_perf_label)
	_refresh_control_labels()


func _add_button_grid(parent: Control) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = 2
	parent.add_child(grid)
	return grid


func _add_check(parent: Control, label_text: String, initial: bool, callback: Callable) -> CheckBox:
	var check := CheckBox.new()
	check.text = label_text
	check.focus_mode = Control.FOCUS_NONE
	check.button_pressed = initial
	check.custom_minimum_size = Vector2(230.0, 28.0)
	check.toggled.connect(callback)
	parent.add_child(check)
	return check


func _add_slider(parent: Control, label_text: String, min_val: float, max_val: float, initial: float, callback: Callable) -> void:
	var hbox := HBoxContainer.new()
	parent.add_child(hbox)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 80.0
	hbox.add_child(label)
	var slider := HSlider.new()
	slider.focus_mode = Control.FOCUS_NONE
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = 0.05
	slider.value = initial
	slider.custom_minimum_size.x = 220.0
	hbox.add_child(slider)
	var value := Label.new()
	value.text = "%.2f" % initial
	value.custom_minimum_size.x = 60.0
	hbox.add_child(value)
	slider.value_changed.connect(func(val: float) -> void:
		value.text = "%.2f" % val
		callback.call(val)
	)


func _add_button(parent: Control, label_text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = label_text
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(190.0, 30.0)
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


func _refresh_control_labels() -> void:
	if _debug_button:
		_debug_button.text = "Debug: %d %s" % [_debug_mode, DEBUG_MODE_NAMES[_debug_mode]]
	if _weather_button:
		var preset: Dictionary = WEATHER_PRESETS[_current_weather]
		_weather_button.text = "Weather: %s" % preset["name"]
	if _mesh_button:
		var mode_text := "Clipmap"
		if OceanManager and OceanManager.is_initialized() and OceanManager.has_method("get_mesh_mode"):
			mode_text = "Projected" if OceanManager.get_mesh_mode() == 1 else "Clipmap"
		_mesh_button.text = "Mesh: %s" % mode_text
	if _sun_button:
		_sun_button.text = "Sun: %s" % ("Low" if _sun_low else "High")
	if _wet_debug_button:
		_wet_debug_button.text = "Wet Debug: %s" % ("On" if _wet_debug else "Off")
	if _quality_button:
		var quality := OceanManager.get_water_quality_name() if OceanManager and OceanManager.is_initialized() else "Unknown"
		_quality_button.text = "Quality: %s" % quality
	if _spray_button:
		_spray_button.text = "Spray: %s" % ("On" if _spray_enabled else "Off")
	if _spray_quality_button:
		var quality_name := OceanManager.get_sea_spray_quality_name() if OceanManager and OceanManager.has_method("get_sea_spray_quality_name") else "Unknown"
		_spray_quality_button.text = "Spray Q: %s" % quality_name
	if _underwater_button:
		_underwater_button.text = "UW Volume: %s" % ("On" if _underwater_volume_enabled else "Off")
	if _underwater_mode_button:
		_underwater_mode_button.text = "UW Scope: %s" % ("Debug" if _underwater_active_above else "BelowCam")
	if _uw_wobble_button:
		_uw_wobble_button.text = "UW Wobble: %s" % ("On" if _uw_wobble_enabled else "Off")
	if _ocean_surface_button:
		_ocean_surface_button.text = "Ocean Mesh: %s" % ("On" if _ocean_surface_visible else "Off")
	if _uw_debug_button:
		_uw_debug_button.text = "UW Debug: %s" % UW_DEBUG_MODE_NAMES[_uw_debug_mode]
	if _waterline_button:
		_waterline_button.text = "Waterline: %s" % ("On" if _waterline_compositor_enabled else "Off")
	if _waterline_debug_button:
		_waterline_debug_button.text = "WL Debug: %s" % WL_DEBUG_MODE_NAMES[_waterline_debug_mode]
	if _waterline_res_button:
		_waterline_res_button.text = "WL Res: %d%%" % int(roundf(_get_waterline_resolution_scale() * 100.0))
	if _wireframe_button:
		_wireframe_button.text = "Wireframe: %s" % ("On" if _wireframe_enabled else "Off")
	if _uw_absorption_check:
		_uw_absorption_check.button_pressed = _uw_absorption_enabled
	if _uw_snell_check:
		_uw_snell_check.button_pressed = _uw_snell_enabled
	if _uw_rays_check:
		_uw_rays_check.button_pressed = _uw_rays_enabled
	if _uw_wobble_check:
		_uw_wobble_check.button_pressed = _uw_wobble_effect_enabled
	if _uw_particles_check:
		_uw_particles_check.button_pressed = _uw_particles_enabled
	if _uw_meniscus_check:
		_uw_meniscus_check.button_pressed = _uw_meniscus_enabled
	if _uw_waterline_check:
		_uw_waterline_check.button_pressed = _waterline_compositor_enabled
	if _uw_profile_button:
		_uw_profile_button.text = "Profile: %s" % ("Stop" if _uw_profile_running else "Run")


func _process(delta: float) -> void:
	_update_average_frame_time(delta)
	_update_buoyancy_debug_grid()
	_push_object_water_state()
	_update_object_wetness(delta)
	_update_held_object()
	_update_underwater_volume()
	_update_prewater_capture()
	_update_waterline_compositor()
	_update_underwater_profile()
	_update_underwater_perf_label()
	_sync_terrain_shore_wetness()
	_update_hud()


func _update_average_frame_time(delta: float) -> void:
	_frame_time_accum += delta * 1000.0
	_frame_time_count += 1
	if _frame_time_count >= 30:
		_avg_frame_ms = _frame_time_accum / float(_frame_time_count)
		_frame_time_accum = 0.0
		_frame_time_count = 0


func _update_buoyancy_debug_grid() -> void:
	if not _buoy_grid_visible or _debug_mmi == null or _camera == null:
		return
	var state := _get_water_state()
	if state == null or not state.can_sample_height():
		return

	var cam_xz := Vector2(_camera.global_position.x, _camera.global_position.z)
	var half: float = (BUOY_DEBUG_GRID - 1) * BUOY_DEBUG_SPACING * 0.5
	var origin_x: float = cam_xz.x - half
	var origin_z: float = cam_xz.y - half
	var mm: MultiMesh = _debug_mmi.multimesh
	var idx := 0
	var xf := Transform3D.IDENTITY
	for iz in BUOY_DEBUG_GRID:
		var wz: float = origin_z + float(iz) * BUOY_DEBUG_SPACING
		for ix in BUOY_DEBUG_GRID:
			var wx: float = origin_x + float(ix) * BUOY_DEBUG_SPACING
			var wy: float = state.sample_height(Vector3(wx, 0.0, wz), _sea_level)
			xf.origin = Vector3(wx, wy, wz)
			mm.set_instance_transform(idx, xf)
			idx += 1


func _update_object_wetness(delta: float) -> void:
	for obj: Dictionary in _test_objects:
		var node: MeshInstance3D = obj["node"]
		var wet_local: float = obj["wet_line_local"]
		var obj_y: float = node.global_position.y
		var obj_bottom_world: float = obj_y + float(obj["mesh_bottom"])
		var contact_water_y := _sample_object_contact_water_y(node.global_position, float(obj["wet_sample_radius"]))
		if obj_bottom_world < contact_water_y:
			wet_local = maxf(wet_local, contact_water_y - obj_y)
		else:
			wet_local -= _wet_dry_rate * delta
		obj["wet_line_local"] = wet_local
		var mat_rid: RID = obj["mat_rid"]
		if mat_rid.is_valid():
			RenderingServer.material_set_param(mat_rid, "wet_line_y", obj_y + wet_local)


func _push_object_water_state() -> void:
	var state := _get_water_state()
	var dynamic_enabled := state != null
	for obj: Dictionary in _test_objects:
		var mat_rid: RID = obj["mat_rid"]
		if not mat_rid.is_valid():
			continue
		RenderingServer.material_set_param(mat_rid, "dynamic_water_enabled", dynamic_enabled)
		if not dynamic_enabled:
			continue
		if _camera != null:
			RenderingServer.material_set_param(mat_rid, "camera_world_position", _camera.global_position)
		RenderingServer.material_set_param(mat_rid, "sea_level", state.sea_level)
		RenderingServer.material_set_param(mat_rid, "wave_scale", state.wave_scale)
		RenderingServer.material_set_param(mat_rid, "ocean_time", state.ocean_time)
		RenderingServer.material_set_param(mat_rid, "map_scales", state.map_scales)
		RenderingServer.material_set_param(mat_rid, "shore_mask_bounds", state.shore_mask_bounds)
		RenderingServer.material_set_param(mat_rid, "shore_fade_distance", state.shore_fade_distance)
		RenderingServer.material_set_param(mat_rid, "shore_wave_amplitude", state.shore_wave_amplitude)
		RenderingServer.material_set_param(mat_rid, "shore_wave_frequency", state.shore_wave_frequency)
		RenderingServer.material_set_param(mat_rid, "shore_wave_speed", state.shore_wave_speed)
		RenderingServer.material_set_param(mat_rid, "shore_wave_steepness", state.shore_wave_steepness)
		RenderingServer.material_set_param(mat_rid, "dynamic_water_has_shore_mask", state.shore_mask_texture != null)
		if state.shore_mask_texture != null:
			RenderingServer.material_set_param(mat_rid, "shore_mask", state.shore_mask_texture.get_rid())


func _sample_object_contact_water_y(center: Vector3, radius: float) -> float:
	var state := _get_water_state()
	if state == null or not state.can_sample_height():
		return _sea_level
	var max_y := -1.0e6
	for offset in [
		Vector3.ZERO,
		Vector3(radius, 0.0, 0.0),
		Vector3(-radius, 0.0, 0.0),
		Vector3(0.0, 0.0, radius),
		Vector3(0.0, 0.0, -radius),
	]:
		max_y = maxf(max_y, state.sample_height(center + offset, _sea_level))
	return max_y


func _update_held_object() -> void:
	if _held_object.is_empty() or _camera == null:
		return
	var node: MeshInstance3D = _held_object["node"]
	node.global_position = _camera.global_position + -_camera.global_basis.z * 5.0


func _update_underwater_volume() -> void:
	_disable_legacy_underwater_compositor()
	_apply_ocean_surface_visibility()
	if _underwater_volume == null:
		return
	_underwater_volume.set_sea_level(_sea_level)
	_underwater_volume.set_active_above_water(_underwater_active_above)
	_underwater_volume.set_debug_mode(_uw_debug_mode)
	_underwater_volume.set_wobble_enabled(_uw_wobble_enabled)
	_underwater_volume.sync_wave_surface_from_water_state(_get_water_state())
	if _underwater_volume.has_method("set_camera_water_level"):
		_underwater_volume.call("set_camera_water_level", _get_camera_water_level())


func _update_waterline_compositor() -> void:
	if _waterline_effect == null:
		return
	var activation_fade := _get_waterline_activation_fade()
	var debug_active := _waterline_debug_mode != 0
	_waterline_effect.effect_enabled = _waterline_compositor_enabled and (activation_fade > 0.001 or debug_active)
	_waterline_effect.blend_factor = (1.0 if debug_active else activation_fade) if _waterline_effect.effect_enabled else 0.0
	if _waterline_effect.has_method("set_debug_mode"):
		_waterline_effect.call("set_debug_mode", _waterline_debug_mode)
	if _waterline_effect.has_method("set_camera_water_level"):
		_waterline_effect.call("set_camera_water_level", _get_camera_water_level())
	_push_underwater_effect_controls()
	_sync_waterline_sun()
	if _waterline_effect.effect_enabled:
		_push_prewater_capture_to_waterline()
		if _waterline_effect.has_method("sync_from_water_state"):
			_waterline_effect.call("sync_from_water_state", _get_water_state())
	elif _waterline_effect.has_method("clear_external_source_buffers"):
		_waterline_effect.call("clear_external_source_buffers")


func _update_prewater_capture() -> void:
	if _prewater_capture == null:
		return
	_prewater_capture.set_capture_enabled(_waterline_compositor_enabled)
	_prewater_capture.set_blend_factor(1.0 if _waterline_compositor_enabled else 0.0)
	_prewater_capture.set_resolution_scale(_get_waterline_resolution_scale())
	_prewater_capture.set_camera_water_level(_get_camera_water_level())
	_prewater_capture.update_capture(_get_main_viewport_size())


func _get_main_viewport_size() -> Vector2i:
	var rect := get_viewport().get_visible_rect()
	var size := Vector2i(int(rect.size.x), int(rect.size.y))
	if size.x <= 0 or size.y <= 0:
		return Vector2i(1280, 720)
	return size


func _push_prewater_capture_to_waterline() -> void:
	if _waterline_effect == null:
		return
	if _prewater_capture == null:
		if _waterline_effect.has_method("clear_external_source_buffers"):
			_waterline_effect.call("clear_external_source_buffers")
		return
	_prewater_capture.push_to_waterline_effect(_waterline_effect)


func _get_waterline_resolution_scale() -> float:
	return _waterline_resolution_scales[clampi(_waterline_resolution_index, 0, _waterline_resolution_scales.size() - 1)]


func _get_waterline_activation_fade() -> float:
	if _prewater_capture != null and _prewater_capture.has_method("get_activation_fade"):
		return float(_prewater_capture.call("get_activation_fade"))
	return 1.0


func _sync_waterline_sun() -> void:
	if _waterline_effect == null or _sun == null or not is_instance_valid(_sun):
		return
	if _waterline_effect.has_method("set_sun_direction"):
		_waterline_effect.call("set_sun_direction", -_sun.global_basis.z)
	if _waterline_effect.has_method("set_sun_visibility"):
		_waterline_effect.call("set_sun_visibility", clampf(_sun.light_energy / 1.4, 0.0, 1.0))


func _push_underwater_effect_controls() -> void:
	if _waterline_effect == null:
		return
	if _waterline_effect.has_method("set_underwater_feature_enabled"):
		_waterline_effect.call("set_underwater_feature_enabled", &"absorption_fog", _uw_absorption_enabled)
		_waterline_effect.call("set_underwater_feature_enabled", &"snell", _uw_snell_enabled)
		_waterline_effect.call("set_underwater_feature_enabled", &"rays", _uw_rays_enabled)
		_waterline_effect.call("set_underwater_feature_enabled", &"wobble", _uw_wobble_effect_enabled)
		_waterline_effect.call("set_underwater_feature_enabled", &"particles", _uw_particles_enabled)
		_waterline_effect.call("set_underwater_feature_enabled", &"meniscus_refraction", _uw_meniscus_enabled)
	if _waterline_effect.has_method("set_underwater_ray_params"):
		_waterline_effect.call(
			"set_underwater_ray_params",
			_uw_ray_shell_count,
			_uw_ray_shell_spacing_m,
			_uw_ray_intensity,
			_uw_ray_shell_start_m
		)
	if _waterline_effect.has_method("set_underwater_particle_params"):
		_waterline_effect.call(
			"set_underwater_particle_params",
			_uw_particle_noise_scale,
			_uw_particle_density,
			_uw_particle_near_gate_m,
			_uw_particle_far_gate_m
		)


func _set_underwater_profile_features(profile_name: String) -> void:
	_uw_absorption_enabled = profile_name == "Absorption" or profile_name == "All On"
	_uw_snell_enabled = profile_name == "Snell" or profile_name == "All On"
	_uw_rays_enabled = profile_name == "Rays" or profile_name == "All On"
	_uw_wobble_effect_enabled = profile_name == "Wobble" or profile_name == "All On"
	_uw_particles_enabled = profile_name == "Particles" or profile_name == "All On"
	_uw_meniscus_enabled = profile_name == "Meniscus/Refract" or profile_name == "All On"
	_push_underwater_effect_controls()
	_refresh_control_labels()


func _underwater_profile_names() -> Array[String]:
	return [
		"All Off",
		"Absorption",
		"Snell",
		"Rays",
		"Wobble",
		"Particles",
		"Meniscus/Refract",
		"All On",
	]


func _toggle_underwater_profile() -> void:
	_uw_profile_running = not _uw_profile_running
	_uw_profile_step = 0
	_uw_profile_frame_count = 0
	_uw_profile_accum_ms = 0.0
	_uw_profile_results.clear()
	if _uw_profile_running:
		_set_underwater_profile_features(_underwater_profile_names()[0])
	_refresh_control_labels()


func _update_underwater_profile() -> void:
	if not _uw_profile_running or _waterline_effect == null:
		return
	var names := _underwater_profile_names()
	if _uw_profile_step >= names.size():
		_uw_profile_running = false
		_set_underwater_profile_features("All On")
		_refresh_control_labels()
		return

	var perf := _get_underwater_perf_snapshot()
	if _uw_profile_frame_count >= 12:
		_uw_profile_accum_ms += float(perf.get("probe_ms", 0.0))
	_uw_profile_frame_count += 1
	if _uw_profile_frame_count < 42:
		return

	var sample_count := maxf(float(_uw_profile_frame_count - 12), 1.0)
	_uw_profile_results.append("%s: %.3f ms" % [names[_uw_profile_step], _uw_profile_accum_ms / sample_count])
	_uw_profile_step += 1
	_uw_profile_frame_count = 0
	_uw_profile_accum_ms = 0.0
	if _uw_profile_step < names.size():
		_set_underwater_profile_features(names[_uw_profile_step])
	else:
		_uw_profile_running = false
		_set_underwater_profile_features("All On")
	_refresh_control_labels()


func _get_underwater_perf_snapshot() -> Dictionary:
	if _waterline_effect != null and _waterline_effect.has_method("get_underwater_perf_snapshot"):
		var snapshot: Variant = _waterline_effect.call("get_underwater_perf_snapshot")
		if snapshot is Dictionary:
			return snapshot
	return {}


func _update_underwater_perf_label() -> void:
	if _uw_perf_label == null:
		return
	var perf := _get_underwater_perf_snapshot()
	var copy_ms := float(perf.get("scene_copy_ms", 0.0))
	var probe_ms := float(perf.get("probe_ms", 0.0))
	var total_ms := float(perf.get("total_ms", 0.0))
	var lines: Array[String] = []
	lines.append("[b]GPU timings[/b]")
	lines.append("scene copy: %.3f ms" % copy_ms)
	lines.append("waterline/underwater probe: %.3f ms" % probe_ms)
	lines.append("combined: %.3f ms" % total_ms)
	lines.append("")
	lines.append("flags: fog=%s snell=%s rays=%s wobble=%s particles=%s refract=%s" % [
		"on" if _uw_absorption_enabled else "off",
		"on" if _uw_snell_enabled else "off",
		"on" if _uw_rays_enabled else "off",
		"on" if _uw_wobble_effect_enabled else "off",
		"on" if _uw_particles_enabled else "off",
		"on" if _uw_meniscus_enabled else "off",
	])
	lines.append("rays: %d shells / %.1fm / %.2fx" % [_uw_ray_shell_count, _uw_ray_shell_spacing_m, _uw_ray_intensity])
	lines.append("particles: scale %.2f density %.2f" % [_uw_particle_noise_scale, _uw_particle_density])
	if _uw_profile_running:
		var names := _underwater_profile_names()
		lines.append("")
		lines.append("profiling %s (%d/%d)" % [names[_uw_profile_step], _uw_profile_step + 1, names.size()])
	if not _uw_profile_results.is_empty():
		lines.append("")
		lines.append("[b]Profile results[/b]")
		for result: String in _uw_profile_results:
			lines.append(result)
	_uw_perf_label.text = "\n".join(lines)


func _apply_ocean_surface_visibility() -> void:
	if OceanManager == null or not OceanManager.is_initialized():
		return
	var ocean_mesh: OceanMesh = OceanManager.get_ocean_mesh()
	if ocean_mesh:
		ocean_mesh.layers = WATER_RENDER_LAYER_MASK
		ocean_mesh.visible = _ocean_surface_visible


func _disable_legacy_underwater_compositor() -> void:
	if not OceanManager or not OceanManager.has_method("get_underwater_effect"):
		return
	var effect = OceanManager.get_underwater_effect()
	if effect != null and bool(effect.get("effect_enabled")):
		effect.set("effect_enabled", false)
	if ShaderManager and ShaderManager.has_method("is_effect_enabled") and ShaderManager.is_effect_enabled("underwater"):
		ShaderManager.disable_effect("underwater")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_try_pick_drop()


func _try_pick_drop() -> void:
	if not _held_object.is_empty():
		_held_object = {}
		return
	if _camera == null:
		return

	var from := _camera.global_position
	var dir := -_camera.global_basis.z
	var best_dist := 10.0
	var best_obj: Dictionary = {}
	for obj: Dictionary in _test_objects:
		var node: MeshInstance3D = obj["node"]
		var to_obj := node.global_position - from
		var proj := to_obj.dot(dir)
		if proj < 0.5 or proj > 50.0:
			continue
		var closest := from + dir * proj
		var perp := (node.global_position - closest).length()
		if perp < 2.0 and proj < best_dist:
			best_dist = proj
			best_obj = obj
	if not best_obj.is_empty():
		_held_object = best_obj


func _update_hud() -> void:
	if _hud_label == null:
		return
	var fps := Engine.get_frames_per_second()
	var quality := OceanManager.get_water_quality_name() if OceanManager and OceanManager.is_initialized() else "not initialized"
	var mesh_mode := "unknown"
	if OceanManager and OceanManager.is_initialized() and OceanManager.has_method("get_mesh_mode"):
		mesh_mode = "Projected" if OceanManager.get_mesh_mode() == 1 else "Clipmap"
	var state := _get_water_state()
	var readback_bytes := state.cpu_readback_bytes_per_frame if state != null else 0
	var cascade_count := state.cascade_count if state != null else 0
	var fft_size := state.displacement_texture_size if state != null else 0
	var readback_label := String(state.cpu_query_source) if state != null else "none"
	var coverage_label := String(state.coverage_source) if state != null else "none"
	var preset: Dictionary = WEATHER_PRESETS[_current_weather]

	var lines: Array[String] = []
	lines.append("[b]Ocean Lab[/b]  FPS %d  avg %.2f ms" % [fps, _avg_frame_ms])
	lines.append("quality=%s  mesh=%s  sea=%.2f" % [quality, mesh_mode, _sea_level])
	lines.append("fft=%dx%d  cascades=%d  wave_query=%s %d KB/frame" % [
		fft_size,
		fft_size,
		cascade_count,
		readback_label,
		readback_bytes / 1024,
	])
	lines.append("coverage=%s  gpu_mask=%d  cpu_mask=%d" % [
		coverage_label,
		state.gpu_cascade_ready_mask if state != null else 0,
		state.cpu_cascade_ready_mask if state != null else 0,
	])
	lines.append("weather=%s wind=%.2f  debug=%d %s" % [
		preset["name"],
		preset["wind"],
		_debug_mode,
		DEBUG_MODE_NAMES[_debug_mode],
	])
	lines.append("buoy_grid=%s  wet_debug=%s  sun=%s" % [
		"on" if _buoy_grid_visible else "off",
		"on" if _wet_debug else "off",
		"low" if _sun_low else "high",
	])
	lines.append("underwater=%s/%s  uw_wobble=%s" % [
		"on" if _underwater_volume_enabled else "off",
		"debug" if _underwater_active_above else "belowcam",
		"on" if _uw_wobble_enabled else "off",
	])
	var spray_energy := OceanManager.get_sea_spray_energy() if OceanManager and OceanManager.has_method("get_sea_spray_energy") else 0.0
	var spray_status: Dictionary = OceanManager.get_sea_spray_status() if OceanManager and OceanManager.has_method("get_sea_spray_status") else {}
	lines.append("spray=%s/%s  emitting=%s  candidates=%d  energy=%.2f" % [
		"on" if _spray_enabled else "off",
		OceanManager.get_sea_spray_quality_name() if OceanManager and OceanManager.has_method("get_sea_spray_quality_name") else "Unknown",
		"yes" if bool(spray_status.get("emitting", false)) else "no",
		int(spray_status.get("particle_candidates", 0)),
		spray_energy,
	])
	lines.append("ocean_mesh=%s  wireframe=%s  uw_debug=%s  waterline=%s/%s" % [
		"on" if _ocean_surface_visible else "off",
		"on" if _wireframe_enabled else "off",
		UW_DEBUG_MODE_NAMES[_uw_debug_mode],
		"on" if _waterline_compositor_enabled else "off",
		WL_DEBUG_MODE_NAMES[_waterline_debug_mode],
	])
	if _prewater_capture != null:
		lines.append("prewater=%s %.0f%% fade=%.2f %s" % [
			"active" if _prewater_capture.is_capture_active() else "idle",
			_prewater_capture.get_resolution_scale() * 100.0,
			_get_waterline_activation_fade(),
			_prewater_capture.get_source_size(),
		])
	var uw_perf := _get_underwater_perf_snapshot()
	if not uw_perf.is_empty():
		lines.append("uw_gpu=%.3f ms (copy %.3f / probe %.3f)" % [
			float(uw_perf.get("total_ms", 0.0)),
			float(uw_perf.get("scene_copy_ms", 0.0)),
			float(uw_perf.get("probe_ms", 0.0)),
		])
	if _help_visible:
		lines.append("")
		lines.append("Use the control panel buttons for ocean/debug actions.")
		lines.append("RMB + movement actions flies the camera.")
		lines.append("LClick picks/drops wet test objects.")
		if _waterline_debug_mode == 5:
			lines.append("WL Refract: green=offset accepted, yellow=raw fallback, orange=above-water reject.")
		elif _waterline_debug_mode == 6:
			lines.append("WL Refract Offset: red=UV offset amount, green=visible source-color change.")
		elif _waterline_debug_mode == 4:
			lines.append("WL Receiver Mask: red=eligible receiver, green=water coverage, blue=active visibility gate.")
		elif _waterline_debug_mode == 7:
			lines.append("WL Source: green=source depth valid, red=missing source color.")
		elif _waterline_debug_mode == 8:
			lines.append("WL Camera Split: red=receiver underwater, green=ray crosses water, blue=active coverage gate.")
		elif _waterline_debug_mode == 9:
			lines.append("WL Pipeline: left=buffers, mid=depth, next=masks, right=final write gate.")
		lines.append("Playground: %s" % _shore_search_status)
	_hud_label.text = "\n".join(lines)


func _cycle_debug_mode() -> void:
	_debug_mode = (_debug_mode + 1) % DEBUG_MODE_NAMES.size()
	if OceanManager and OceanManager.has_method("set_debug_mode"):
		OceanManager.set_debug_mode(_debug_mode)
	_refresh_control_labels()
	Log.info("water", "[Ocean Lab] debug_mode %d = %s" % [_debug_mode, DEBUG_MODE_NAMES[_debug_mode]])


func _apply_weather_preset(idx: int) -> void:
	if idx < 0 or idx >= WEATHER_PRESETS.size():
		return
	_current_weather = idx
	if not OceanManager or not OceanManager.is_initialized():
		return
	var preset: Dictionary = WEATHER_PRESETS[idx]
	var result := WeatherTypesScript.WeatherResult.new()
	result.wind_speed = preset["wind"]
	result.cloud_coverage = preset["cloud"]
	var wind_rad := deg_to_rad(45.0)
	result.storm_direction = Vector3(sin(wind_rad), 0.0, cos(wind_rad))
	OceanManager.apply_weather(result)
	_refresh_control_labels()
	Log.info("water", "[Ocean Lab] weather preset %s wind=%.2f" % [preset["name"], preset["wind"]])


func _toggle_buoy_grid() -> void:
	_buoy_grid_visible = not _buoy_grid_visible
	if _debug_mmi:
		_debug_mmi.visible = _buoy_grid_visible


func _toggle_mesh_mode() -> void:
	if not OceanManager or not OceanManager.is_initialized() or not OceanManager.has_method("rebuild_mesh_with_mode"):
		return
	var current: int = OceanManager.get_mesh_mode()
	var next := 1 if current == 0 else 0
	if next == 1 and OceanManager.get_water_quality() != OceanMesh.QualityMode.HIGH:
		OceanManager.set_water_quality(1)
	OceanManager.rebuild_mesh_with_mode(next)
	OceanManager.set_camera(_camera)
	_ocean = OceanManager.get_ocean_mesh()
	if OceanManager.has_method("set_sea_spray_render_layers"):
		OceanManager.set_sea_spray_render_layers(WATER_RENDER_LAYER_MASK)
	_apply_ocean_surface_visibility()
	_apply_weather_preset(_current_weather)
	_refresh_control_labels()


func _toggle_sun_angle() -> void:
	if _sun == null:
		return
	_sun_low = not _sun_low
	if _sun_low:
		_sun.rotation = Vector3(deg_to_rad(-8.0), 0.0, 0.0)
		_sun.light_energy = 1.4
		_sun.light_color = Color(1.0, 0.72, 0.48)
	else:
		_sun.rotation = Vector3(-PI / 4.0, PI / 4.0, 0.0)
		_sun.light_energy = 1.2
		_sun.light_color = Color.WHITE
	_refresh_control_labels()


func _toggle_wet_debug() -> void:
	_wet_debug = not _wet_debug
	if _horizon_mgr:
		_horizon_mgr._set_param("wet_debug", _wet_debug)
	for obj: Dictionary in _test_objects:
		var mat_rid: RID = obj["mat_rid"]
		if mat_rid.is_valid():
			RenderingServer.material_set_param(mat_rid, "wet_debug", _wet_debug)
	_refresh_control_labels()


func _push_object_wet_params() -> void:
	for obj: Dictionary in _test_objects:
		var mat_rid: RID = obj["mat_rid"]
		if mat_rid.is_valid():
			RenderingServer.material_set_param(mat_rid, "wet_margin", _wet_margin)
			RenderingServer.material_set_param(mat_rid, "wet_albedo_darken", _wet_albedo_darken)
			RenderingServer.material_set_param(mat_rid, "wet_roughness_target", _wet_roughness_target)
			RenderingServer.material_set_param(mat_rid, "retained_wetness_strength", _retained_wetness_strength)


func _teleport_to_shore_probe() -> void:
	if _camera == null:
		return
	var target := _playground_origin
	_camera.global_position = target + Vector3(0.0, 18.0, 45.0)
	_camera.look_at(target, Vector3.UP)


func _cycle_quality() -> void:
	if not OceanManager or not OceanManager.is_initialized():
		return
	var current: OceanMesh.QualityMode = OceanManager.get_water_quality()
	var next := 1
	if current == OceanMesh.QualityMode.HIGH:
		next = 0
	else:
		next = 1
	if next == 0 and OceanManager.get_mesh_mode() == 1:
		OceanManager.rebuild_mesh_with_mode(0)
	OceanManager.set_water_quality(next)
	OceanManager.set_camera(_camera)
	_ocean = OceanManager.get_ocean_mesh()
	if OceanManager.has_method("set_sea_spray_render_layers"):
		OceanManager.set_sea_spray_render_layers(WATER_RENDER_LAYER_MASK)
	_apply_ocean_surface_visibility()
	_apply_weather_preset(_current_weather)
	_refresh_control_labels()


func _toggle_spray() -> void:
	_spray_enabled = not _spray_enabled
	if OceanManager and OceanManager.has_method("set_sea_spray_enabled"):
		OceanManager.set_sea_spray_enabled(_spray_enabled)
	_refresh_control_labels()


func _cycle_spray_quality() -> void:
	_spray_quality = (_spray_quality + 1) % 4
	if OceanManager and OceanManager.has_method("set_sea_spray_quality"):
		OceanManager.set_sea_spray_quality(_spray_quality)
	_refresh_control_labels()


func _toggle_underwater_volume() -> void:
	_underwater_volume_enabled = not _underwater_volume_enabled
	if _underwater_volume:
		_underwater_volume.enabled = _underwater_volume_enabled
	_refresh_control_labels()


func _toggle_underwater_active_above() -> void:
	_underwater_active_above = not _underwater_active_above
	if _underwater_volume:
		_underwater_volume.set_active_above_water(_underwater_active_above)
	_refresh_control_labels()


func _toggle_uw_wobble() -> void:
	_uw_wobble_enabled = not _uw_wobble_enabled
	if _underwater_volume:
		_underwater_volume.set_wobble_enabled(_uw_wobble_enabled)
	_refresh_control_labels()


func _toggle_ocean_surface_visible() -> void:
	_ocean_surface_visible = not _ocean_surface_visible
	_apply_ocean_surface_visibility()
	_refresh_control_labels()


func _cycle_uw_debug_mode() -> void:
	_uw_debug_mode = (_uw_debug_mode + 1) % UW_DEBUG_MODE_NAMES.size()
	if _underwater_volume:
		_underwater_volume.set_debug_mode(_uw_debug_mode)
	_refresh_control_labels()


func _toggle_waterline_compositor() -> void:
	_waterline_compositor_enabled = not _waterline_compositor_enabled
	if _prewater_capture:
		_prewater_capture.set_capture_enabled(_waterline_compositor_enabled)
		_prewater_capture.set_blend_factor(1.0 if _waterline_compositor_enabled else 0.0)
	_refresh_control_labels()


func _cycle_waterline_debug_mode() -> void:
	_waterline_debug_mode = (_waterline_debug_mode + 1) % WL_DEBUG_MODE_NAMES.size()
	if _waterline_effect and _waterline_effect.has_method("set_debug_mode"):
		_waterline_effect.call("set_debug_mode", _waterline_debug_mode)
	_refresh_control_labels()


func _cycle_waterline_resolution() -> void:
	_waterline_resolution_index = (_waterline_resolution_index + 1) % _waterline_resolution_scales.size()
	if _prewater_capture:
		_prewater_capture.set_resolution_scale(_get_waterline_resolution_scale())
	_refresh_control_labels()


func _toggle_wireframe_debug() -> void:
	_wireframe_enabled = not _wireframe_enabled
	get_viewport().debug_draw = Viewport.DEBUG_DRAW_WIREFRAME if _wireframe_enabled else Viewport.DEBUG_DRAW_DISABLED
	_refresh_control_labels()


func _get_ocean_material() -> ShaderMaterial:
	if OceanManager == null or not OceanManager.is_initialized():
		return null
	var ocean_mesh: OceanMesh = OceanManager.get_ocean_mesh()
	if ocean_mesh == null:
		return null
	return ocean_mesh.get_material()


func _get_water_state() -> WaterSurfaceState:
	if OceanManager != null and OceanManager.has_method("get_water_surface_state"):
		return OceanManager.get_water_surface_state()
	return null


func _get_camera_water_level() -> float:
	if _camera != null:
		var state := _get_water_state()
		if state != null and state.can_sample_height():
			return state.sample_height(_camera.global_position, _sea_level)
	return _sea_level


func _spawn_buoyant_sphere_from_camera() -> void:
	if _camera == null:
		return
	const SPHERE_RADIUS: float = 0.35
	var body: BuoyancyBody3D = BuoyancyBodyScript.new()
	body.name = "OceanLabBuoyantSphere"
	body.mass = 5.0
	body.buoyancy_force = 1.35
	body.buoyancy_power = 1.15
	body.probe_submersion_depth = SPHERE_RADIUS * 2.0
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
	mesh_inst.material_override = _standard_mat(Color(0.9, 0.35, 0.2), 0.35)
	_mark_refraction_receiver(mesh_inst)
	body.add_child(mesh_inst)

	var probe: BuoyancyProbe3D = BuoyancyProbeScript.new()
	probe.name = "ProbeCenter"
	body.add_child(probe)
	add_child(body)

	var forward := -_camera.global_basis.z
	body.global_position = _camera.global_position + forward * 1.5
	body.linear_velocity = forward * 10.0


func _lab_pos(offset: Vector3) -> Vector3:
	return Vector3(
		_playground_origin.x + offset.x,
		_sea_level + offset.y,
		_playground_origin.z + offset.z
	)


func _make_checker_texture(size_px: int, cell_px: int, a: Color, b: Color) -> ImageTexture:
	var img := Image.create(size_px, size_px, false, Image.FORMAT_RGBA8)
	for y in size_px:
		for x in size_px:
			var cell: int = (x / cell_px + y / cell_px) & 1
			img.set_pixel(x, y, a if cell == 0 else b)
	return ImageTexture.create_from_image(img)


func _add_box(node_name: String, size: Vector3, pos: Vector3, mat: Material, refraction_receiver: bool = false) -> MeshInstance3D:
	var inst := MeshInstance3D.new()
	inst.name = node_name
	var mesh := BoxMesh.new()
	mesh.size = size
	inst.mesh = mesh
	inst.material_override = mat
	if refraction_receiver:
		_mark_refraction_receiver(inst)
	add_child(inst)
	inst.global_position = pos
	return inst


func _mark_refraction_receiver(inst: VisualInstance3D) -> void:
	inst.layers = inst.layers | WATER_REFRACTION_RECEIVER_LAYER_MASK


func _add_emissive_marker(pos: Vector3, color: Color) -> void:
	var light := OmniLight3D.new()
	light.position = pos
	light.light_color = color
	light.omni_range = 18.0
	light.light_energy = 2.0
	add_child(light)
	var sphere := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.45
	mesh.height = 0.9
	sphere.mesh = mesh
	sphere.position = pos
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 4.0
	sphere.material_override = mat
	add_child(sphere)


func _standard_mat(color: Color, roughness: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	return mat


func _metal_mat() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.85, 0.88)
	mat.metallic = 1.0
	mat.roughness = 0.08
	mat.metallic_specular = 1.0
	return mat
