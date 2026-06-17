extends Node3D

## Ocean lab: combined interactive testbed for FFT ocean visuals, shore behavior,
## wetness, screen-space ocean optics canaries, and buoyancy CPU-vs-GPU sync.
##
## Run:
##   Godot_v4.6-stable_mono_win64.exe --path ... res://tests/visual/test_ocean_lab.tscn

@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_property_access", "unsafe_cast")

const InputActionsScript := preload("res://src/core/input/input_actions.gd")
const FlyCameraScript := preload("res://src/core/player/fly_camera.gd")
const BuoyancyBodyScript := preload("res://src/core/water/buoyancy_body.gd")
const BuoyancyProbeScript := preload("res://src/core/water/buoyancy_probe.gd")
const WetCompositorScript := preload("res://src/core/shaders/effects/wet_compositor_effect.gd")
const UnderwaterCompositorScript := preload("res://src/core/shaders/effects/underwater_compositor_effect.gd")
const WaterlineStackScript := preload("res://src/core/water/waterline_stack.gd")
const SurfaceRefractionLayerScript := preload("res://src/core/water/surface_refraction_layer.gd")
const ControlledRefractionSourceScript := preload("res://src/core/water/controlled_refraction_source.gd")
const WeatherTypesScript := preload("res://src/core/weather/weather_types.gd")
const HorizonMapManagerScript := preload("res://src/core/world/horizon_map_manager.gd")
const WettableObjectScript := preload("res://src/core/water/wettable_object.gd")
const OBJECT_WET_SHADER := preload("res://src/core/shaders/object_wet.gdshader")
const CS := preload("res://src/core/coordinate_system.gd")
const RenderLayersScript := preload("res://src/core/world/render_layers.gd")

const SEA_LEVEL_DEFAULT: float = 0.0
const WATER_RENDER_LAYER_MASK: int = RenderLayersScript.WATER_SURFACE
const WATERLINE_RECEIVER_LAYER_MASK: int = 1 << 18
const CONTROLLED_REFRACTION_RECEIVER_LAYER_MASK: int = 1 << 17
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
	"Refraction",
	"Refract depth",
	"SSR hit",
	"Foam",
	"Normal.y",
	"SSS scatter",
	"Refract delta",
	"Source straight",
	"Source refracted",
	"Refract mask",
	"Godot depth weight",
	"Depth edge fade",
	"Godot source preview",
	"Refract weight",
	"Source Blend",
]
const UW_DEBUG_MODE_NAMES: Array[String] = [
	"Final",
	"Path Length",
	"Transmittance",
	"Underwater Mask",
	"Wobble Delta",
	"Wobble Guard",
]
const UW_QUALITY_NAMES: Array[String] = [
	"Low",
	"Medium",
	"High",
]
const WET_DEBUG_MODE_NAMES: Array[String] = [
	"Off",
	"Final",
	"Depth",
	"Body",
	"Exclusion",
	"World",
]
const WATERLINE_DEBUG_MODE_NAMES: Array[String] = [
	"Off",
	"Mean Level",
	"No Shore Waves",
	"Coverage",
	"Receiver Mask",
	"Refract Status",
	"Refract Offset",
	"Sources",
	"Water Ray",
	"Pipeline",
	"Camera Depth",
	"Receiver Path",
	"Water Ray Hit",
	"Coverage RGB",
	"Final Mask",
	"Wobble Guard",
]
const SURFACE_REFRACTION_DEBUG_MODE_NAMES: Array[String] = [
	"Final",
	"Final Mask",
	"Sources",
	"UV Offset",
	"Reject Reason",
	"Pre Absorb",
	"Post Absorb",
	"Ownership RGB",
]
const WEATHER_PRESETS: Array[Dictionary] = [
	{"name": "Calm", "wind": 0.1, "cloud": 0.1},
	{"name": "Breeze", "wind": 0.3, "cloud": 0.25},
	{"name": "Moderate", "wind": 0.5, "cloud": 0.45},
	{"name": "Storm", "wind": 0.7, "cloud": 0.75},
]
const OPTICAL_PRESETS: Array[Dictionary] = [
	{"name": "Clear Sea", "visibility": 80.0, "scatter": 0.2, "color": Color(0.015, 0.055, 0.080)},
	{"name": "Dark Coast", "visibility": 35.0, "scatter": 0.55, "color": Color(0.020, 0.040, 0.060)},
	{"name": "Morrowind", "visibility": 16.0, "scatter": 0.80, "color": Color(0.050, 0.075, 0.055)},
	{"name": "Muddy", "visibility": 3.0, "scatter": 1.0, "color": Color(0.180, 0.135, 0.070)},
]

var _camera: Camera3D = null
var _world_env: WorldEnvironment = null
var _terrain: Terrain3D = null
var _horizon_mgr: HorizonMapManager = null
var _sun: DirectionalLight3D = null
var _ocean: OceanMesh = null
var _water_compositor: Compositor = null
var _wet_effect: PostProcessEffect = null
var _underwater_effect: PostProcessEffect = null
var _waterline_stack: WaterlineStack = null
var _surface_refraction_layer: Node = null
var _controlled_refraction_source: ControlledRefractionSource = null
var _debug_mmi: MultiMeshInstance3D = null
var _hud_label: RichTextLabel = null
var _button_grid: GridContainer = null
var _debug_button: Button = null
var _weather_button: Button = null
var _optical_preset_button: Button = null
var _mesh_button: Button = null
var _sun_button: Button = null
var _wet_live_button: Button = null
var _wet_debug_button: Button = null
var _quality_button: Button = null
var _spray_button: Button = null
var _spray_quality_button: Button = null
var _surface_shader_button: Button = null
var _boujie_full_button: Button = null
var _ocean_surface_button: Button = null
var _surface_ssr_button: Button = null
var _surface_refraction_button: Button = null
var _surface_refraction_debug_button: Button = null
var _surface_edge_guard_button: Button = null
var _environment_ssr_button: Button = null
var _waterline_button: Button = null
var _waterline_debug_button: Button = null
var _waterline_inspect_button: Button = null
var _waterline_replace_button: Button = null
var _underwater_button: Button = null
var _underwater_debug_button: Button = null
var _underwater_quality_button: Button = null
var _wireframe_button: Button = null
var _uw_absorption_check: CheckBox = null
var _uw_snell_check: CheckBox = null
var _uw_wobble_check: CheckBox = null
var _uw_particles_check: CheckBox = null
var _uw_caustics_check: CheckBox = null
var _uw_effect_check: CheckBox = null
var _uw_perf_label: RichTextLabel = null
var _uw_profile_button: Button = null

var _sea_level: float = SEA_LEVEL_DEFAULT
var _playground_origin: Vector3 = Vector3.ZERO
var _shore_search_status: String = "not searched"
var _wet_margin: float = 0.3
var _wet_albedo_darken: float = 0.6
var _wet_roughness_target: float = 0.05
var _retained_wetness_strength: float = 0.35
var _wet_compositor_enabled: bool = false
var _wet_debug_mode: int = 0
var _wet_dry_rate: float = 0.1
var _absorption_density: float = 0.2
var _visibility_distance_m: float = 57.5
var _scattering_strength: float = 1.0
var _absorption_tint: Color = Color(0.02, 0.04, 0.06)
var _absorption_tint_picker: ColorPickerButton = null
var _syncing_ocean_optics_ui: bool = false

var _test_objects: Array[Dictionary] = []
var _held_object: Dictionary = {}
var _regions_loaded: int = 0
var _textures_loaded: int = 0

var _buoy_grid_visible: bool = false
var _debug_mode: int = 0
var _spray_enabled: bool = true
var _spray_quality: int = 2
var _experimental_surface_shader_enabled: bool = false
var _saved_surface_refraction_enabled: bool = false
var _saved_surface_refraction_debug_mode: int = 0
var _saved_surface_edge_guard_enabled: bool = false
var _boujie_full_restore_state: Dictionary = {}
var _boujie_full_restore_valid: bool = false
var _ocean_surface_visible: bool = true
var _surface_ssr_enabled: bool = false
var _surface_refraction_enabled: bool = false
var _surface_refraction_debug_mode: int = 0
var _surface_edge_guard_enabled: bool = false
var _environment_ssr_enabled: bool = true
var _underwater_effect_enabled: bool = false
var _waterline_enabled: bool = false
var _waterline_debug_mode: int = 0
var _waterline_quality_tier: int = 2
var _waterline_inspection_active: bool = false
var _waterline_inspection_frames: int = 0
var _underwater_debug_mode: int = 0
var _underwater_quality_tier: int = 1
var _uw_absorption_enabled: bool = true
var _uw_snell_enabled: bool = false
var _uw_wobble_effect_enabled: bool = true
var _uw_particles_enabled: bool = false
var _uw_caustics_enabled: bool = false
var _uw_particle_noise_scale: float = 0.70
var _uw_particle_density: float = 1.0
var _uw_particles_quality: int = 2
var _uw_particle_count: int = 4096
var _uw_particle_size_scale: float = 4.0
var _uw_particle_speed_scale: float = 1.5
var _uw_particle_near_gate_m: float = 1.5
var _uw_particle_far_gate_m: float = 95.0
var _uw_profile_running: bool = false
var _uw_profile_step: int = 0
var _uw_profile_frame_count: int = 0
var _uw_profile_accum_ms: float = 0.0
var _uw_profile_results: Array[String] = []
var _wireframe_enabled: bool = false
var _current_weather: int = 0
var _current_optical_preset: int = 0
var _default_wave_scale: float = 1.0
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
	_default_wave_scale = WaterSystem.wave_scale if WaterSystem else 1.0
	_setup_water_compositor()
	_setup_reflection_canaries()
	_setup_waterline_stack()
	_setup_wetness()
	_spawn_wet_test_objects()
	_build_buoyancy_debug_mesh()
	_build_ui()
	_apply_weather_preset(0)
	_surface_ssr_enabled = false
	_push_surface_ssr_control()

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Log.info("water", "[Ocean Lab] Ready - terrain regions=%d textures=%d quality=%s" % [
		_regions_loaded,
		_textures_loaded,
		WaterSystem.get_water_quality_name() if WaterSystem else "none",
	])
	_log_refraction_baseline_state("ready")


func _exit_tree() -> void:
	if _wet_effect != null:
		_wet_effect.on_effect_removed()
	_wet_effect = null
	if _underwater_effect != null:
		_underwater_effect.on_effect_removed()
	_underwater_effect = null
	if _waterline_stack != null:
		_waterline_stack.set_enabled(false)
	_waterline_stack = null
	if _surface_refraction_layer != null:
		_surface_refraction_layer.call("shutdown")
		_surface_refraction_layer = null
	if _controlled_refraction_source != null:
		_controlled_refraction_source.shutdown()
		_controlled_refraction_source = null
	if _world_env != null:
		_world_env.compositor = null
	_water_compositor = null


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
	env.ssr_enabled = _environment_ssr_enabled
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
	probe.update_mode = ReflectionProbe.UPDATE_ALWAYS
	add_child(probe)


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "OceanLabFlyCamera"
	_camera.set_script(FlyCameraScript)
	_camera.far = 20000.0
	_camera.current = true
	_camera.cull_mask = _camera.cull_mask | WATER_RENDER_LAYER_MASK
	_camera.process_priority = -100
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
	if "render_layers" in _terrain:
		_terrain.set("render_layers", int(_terrain.get("render_layers")) | CONTROLLED_REFRACTION_RECEIVER_LAYER_MASK)
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
	if not WaterSystem:
		Log.error("water", "[Ocean Lab] WaterSystem autoload missing")
		return

	ProjectSettings.set_setting("ocean/quality", 1)
	if not WaterSystem.is_initialized():
		WaterSystem.force_initialize()
	WaterSystem.set_enabled(true)
	WaterSystem.set_camera(_camera)
	WaterSystem.set_terrain(_terrain)
	_sea_level = WaterSystem.get_sea_level()
	_ocean = WaterSystem.get_ocean_mesh()
	if _ocean != null:
		_ocean.layers = WATER_RENDER_LAYER_MASK
	if WaterSystem.has_method("set_sea_spray_render_layers"):
		WaterSystem.set_sea_spray_render_layers(WATER_RENDER_LAYER_MASK)
	if WaterSystem.has_method("set_underwater_particles_render_layers"):
		WaterSystem.set_underwater_particles_render_layers(WATER_RENDER_LAYER_MASK)
	if WaterSystem.has_method("set_underwater_particles_enabled"):
		WaterSystem.set_underwater_particles_enabled(_uw_particles_enabled)
	if WaterSystem.has_method("set_underwater_particles_quality"):
		WaterSystem.set_underwater_particles_quality(_uw_particles_quality)
	if WaterSystem.has_method("set_underwater_particles_count"):
		WaterSystem.set_underwater_particles_count(_uw_particle_count)
	if WaterSystem.has_method("set_underwater_particles_size_scale"):
		WaterSystem.set_underwater_particles_size_scale(_uw_particle_size_scale)
	if WaterSystem.has_method("set_underwater_particles_speed_scale"):
		WaterSystem.set_underwater_particles_speed_scale(_uw_particle_speed_scale)
	if WaterSystem.has_method("set_underwater_particles_opacity"):
		WaterSystem.set_underwater_particles_opacity(_uw_particle_density)
	if WaterSystem.has_method("is_sea_spray_enabled"):
		_spray_enabled = WaterSystem.is_sea_spray_enabled()
	if WaterSystem.has_method("get_sea_spray_quality"):
		_spray_quality = WaterSystem.get_sea_spray_quality()
	if WaterSystem.has_method("get_underwater_particles_quality"):
		_uw_particles_quality = WaterSystem.get_underwater_particles_quality()
	_sync_ocean_optics_from_manager()
	_setup_surface_refraction_layer()
	_push_surface_shader_mode()
	_push_surface_refraction_control()


func _sync_ocean_optics_from_manager() -> void:
	if not WaterSystem:
		return
	if WaterSystem.has_method("get_absorption_density"):
		_absorption_density = float(WaterSystem.get_absorption_density())
	if WaterSystem.has_method("get_water_visibility_distance"):
		_visibility_distance_m = float(WaterSystem.get_water_visibility_distance())
	if WaterSystem.has_method("get_water_scattering_strength"):
		_scattering_strength = float(WaterSystem.get_water_scattering_strength())
	if WaterSystem.has_method("get_water_scattering_color"):
		_absorption_tint = WaterSystem.get_water_scattering_color()
	elif WaterSystem.has_method("get_absorption_tint_color"):
		_absorption_tint = WaterSystem.get_absorption_tint_color()
	elif WaterSystem.has_method("get_absorption_tint"):
		var tint: Vector3 = WaterSystem.get_absorption_tint()
		_absorption_tint = Color(tint.x, tint.y, tint.z, 1.0)
	if WaterSystem.has_method("is_surface_ssr_enabled"):
		_surface_ssr_enabled = WaterSystem.is_surface_ssr_enabled()
	if _absorption_tint_picker != null:
		_syncing_ocean_optics_ui = true
		_absorption_tint_picker.color = _absorption_tint
		_syncing_ocean_optics_ui = false


func _push_absorption_density_control() -> void:
	if not WaterSystem:
		return
	if WaterSystem.has_method("set_absorption_density"):
		WaterSystem.set_absorption_density(_absorption_density)
	_sync_ocean_optics_from_manager()
	_refresh_control_labels()


func _push_visibility_distance_control() -> void:
	if not WaterSystem:
		return
	if WaterSystem.has_method("set_water_visibility_distance"):
		WaterSystem.set_water_visibility_distance(_visibility_distance_m)
	_sync_ocean_optics_from_manager()
	_refresh_control_labels()


func _push_scattering_strength_control() -> void:
	if not WaterSystem:
		return
	if WaterSystem.has_method("set_water_scattering_strength"):
		WaterSystem.set_water_scattering_strength(_scattering_strength)
	_sync_ocean_optics_from_manager()
	_refresh_control_labels()


func _push_absorption_tint_control() -> void:
	if not WaterSystem:
		return
	if WaterSystem.has_method("set_water_scattering_color"):
		WaterSystem.set_water_scattering_color(_absorption_tint)
	elif WaterSystem.has_method("set_absorption_tint_color"):
		WaterSystem.set_absorption_tint_color(_absorption_tint)
	_sync_ocean_optics_from_manager()
	_refresh_control_labels()


func _push_surface_ssr_control() -> void:
	if not WaterSystem:
		return
	if WaterSystem.has_method("set_surface_ssr_enabled"):
		WaterSystem.set_surface_ssr_enabled(_surface_ssr_enabled)
	_refresh_control_labels()


func _push_surface_shader_mode() -> void:
	if not WaterSystem or not WaterSystem.is_initialized():
		return
	var mode := OceanMesh.SurfaceShaderMode.BOUJIE_EXPERIMENTAL if _experimental_surface_shader_enabled else OceanMesh.SurfaceShaderMode.DEFAULT
	if WaterSystem.has_method("set_surface_shader_mode"):
		WaterSystem.set_surface_shader_mode(mode)
	_ocean = WaterSystem.get_ocean_mesh()
	if _ocean != null:
		_ocean.layers = WATER_RENDER_LAYER_MASK
	if WaterSystem.has_method("set_debug_mode"):
		WaterSystem.set_debug_mode(_debug_mode)
	_refresh_control_labels()


func _push_surface_refraction_control() -> void:
	if _surface_refraction_layer != null:
		var debug_active := _surface_refraction_debug_mode != 0
		var active := (_surface_refraction_enabled or debug_active) and not _experimental_surface_shader_enabled
		_surface_refraction_layer.set("refraction_strength", 0.45 if active else 0.0)
		_surface_refraction_layer.set("edge_guard_strength", 1.0 if _surface_edge_guard_enabled else 0.0)
		if _surface_refraction_layer.has_method("set_debug_mode"):
			_surface_refraction_layer.call("set_debug_mode", _surface_refraction_debug_mode)
		_surface_refraction_layer.call("set_enabled", active)
	_refresh_control_labels()


func _setup_surface_refraction_layer() -> void:
	_setup_controlled_refraction_source()
	if _surface_refraction_layer == null:
		_surface_refraction_layer = SurfaceRefractionLayerScript.new()
		_surface_refraction_layer.name = "SurfaceRefractionLayer"
		add_child(_surface_refraction_layer)
	if _surface_refraction_layer.has_method("set_controlled_source"):
		_surface_refraction_layer.call("set_controlled_source", _controlled_refraction_source)
	_surface_refraction_layer.call(
		"configure",
		_camera,
		_world_env,
		_ocean,
		WATER_RENDER_LAYER_MASK
	)


func _setup_controlled_refraction_source() -> void:
	if _controlled_refraction_source == null:
		_controlled_refraction_source = ControlledRefractionSourceScript.new()
		_controlled_refraction_source.name = "ControlledRefractionSource"
		add_child(_controlled_refraction_source)
	_controlled_refraction_source.configure(
		_camera,
		_world_env,
		CONTROLLED_REFRACTION_RECEIVER_LAYER_MASK
	)


func _reset_absorption_tint_control() -> void:
	if not WaterSystem:
		return
	if WaterSystem.has_method("clear_absorption_tint_override"):
		WaterSystem.clear_absorption_tint_override()
	_current_optical_preset = 0
	_apply_weather_preset(_current_weather)


func _setup_water_compositor() -> void:
	if _world_env == null:
		return
	_wet_effect = WetCompositorScript.new()
	_wet_effect.effect_enabled = false
	_wet_effect.blend_factor = 0.0
	_wet_effect.on_effect_added()
	if _wet_effect.has_method("set_wet_params"):
		_wet_effect.call(
			"set_wet_params",
			_wet_margin,
			_wet_albedo_darken,
			_wet_roughness_target,
			_retained_wetness_strength,
			0.10,
			_wet_debug_mode
		)
	if _wet_effect.has_method("sync_from_water_state"):
		_wet_effect.call("sync_from_water_state", _get_water_state())

	_underwater_effect = UnderwaterCompositorScript.new()
	_underwater_effect.effect_enabled = false
	_underwater_effect.blend_factor = 0.0
	if _underwater_effect.has_method("set_debug_mode"):
		_underwater_effect.call("set_debug_mode", _underwater_debug_mode)
	_push_underwater_effect_controls()
	_underwater_effect.on_effect_added()
	if _underwater_effect.has_method("sync_from_water_state"):
		_underwater_effect.call("sync_from_water_state", _get_water_state())

	_water_compositor = Compositor.new()
	_water_compositor.compositor_effects = [_wet_effect, _underwater_effect]
	_world_env.compositor = _water_compositor


func _setup_waterline_stack() -> void:
	if _camera == null or _world_env == null or WaterSystem == null:
		return
	_waterline_stack = WaterlineStackScript.new()
	_waterline_stack.name = "ReceiverWaterlineStack"
	_waterline_stack.enabled = false
	add_child(_waterline_stack)
	_waterline_stack.configure(
		_camera,
		_world_env,
		WaterSystem,
		WATERLINE_RECEIVER_LAYER_MASK,
		_waterline_quality_tier,
		_sun,
		WATER_RENDER_LAYER_MASK
	)
	_push_waterline_effect_controls()


func _setup_reflection_canaries() -> void:
	var checker_tex := _make_checker_texture(64, 8, Color(0.55, 0.50, 0.40), Color(0.30, 0.28, 0.22))
	var seabed_mat := StandardMaterial3D.new()
	seabed_mat.albedo_texture = checker_tex
	seabed_mat.uv1_scale = Vector3(10.0, 10.0, 1.0)
	seabed_mat.roughness = 0.85

	_add_box("DeepSeabed", Vector3(160.0, 2.0, 160.0), _lab_pos(Vector3(0.0, -16.0, 0.0)), seabed_mat, false, true)
	_add_box("ShallowShelf", Vector3(35.0, 6.0, 35.0), _lab_pos(Vector3(22.0, -4.0, 18.0)), seabed_mat, false, true)
	_add_box("SubmergedRock", Vector3(4.0, 4.0, 4.0), _lab_pos(Vector3(-8.0, -3.0, 8.0)), _standard_mat(Color(0.50, 0.45, 0.35), 0.65), true, true)
	_add_box("HalfSubmergedMonolith", Vector3(3.0, 10.0, 3.0), _lab_pos(Vector3(8.0, 0.0, 9.0)), _standard_mat(Color(0.85, 0.85, 0.90), 0.7), true)
	_add_box("MetalReflectionTarget", Vector3(4.0, 4.0, 4.0), _lab_pos(Vector3(-14.0, 5.0, -12.0)), _metal_mat())
	_add_box("OpticsDepth1m", Vector3(2.0, 1.0, 2.0), _lab_pos(Vector3(-6.0, -1.5, -10.0)), _standard_mat(Color(1.0, 0.82, 0.18), 0.45), true, true)
	_add_box("OpticsDepth10m", Vector3(2.0, 1.0, 2.0), _lab_pos(Vector3(0.0, -10.5, -10.0)), _standard_mat(Color(1.0, 0.22, 0.18), 0.45), true, true)
	_add_box("OpticsDepth50m", Vector3(2.0, 1.0, 2.0), _lab_pos(Vector3(6.0, -50.5, -10.0)), _standard_mat(Color(0.20, 0.55, 1.0), 0.45), true, true)
	_add_box("ControlledRefractionReceiver", Vector3(3.0, 2.0, 3.0), _lab_pos(Vector3(14.0, -5.0, 5.0)), _standard_mat(Color(0.1, 0.9, 0.45), 0.35), false, true)
	_add_box("ForegroundLeakageCanary", Vector3(5.0, 5.0, 1.0), _lab_pos(Vector3(2.0, 5.5, 4.0)), _standard_mat(Color(1.0, 0.05, 0.05), 0.45), false, false)
	_add_emissive_marker(_lab_pos(Vector3(12.0, 4.0, -12.0)), Color(1.0, 0.45, 0.12))
	_add_emissive_marker(_lab_pos(Vector3(0.0, 2.5, -20.0)), Color(0.15, 0.65, 1.0))


func _setup_wetness() -> void:
	if WetnessManager:
		WetnessManager.set_enabled(true)
		if WetnessManager.has_method("set_live_compositor_enabled"):
			WetnessManager.set_live_compositor_enabled(false)
		WetnessManager.wet_margin = _wet_margin
		WetnessManager.wet_albedo_darken = _wet_albedo_darken
		WetnessManager.wet_roughness_target = _wet_roughness_target
		WetnessManager.retained_wetness_strength = _retained_wetness_strength
		WetnessManager.wet_dry_rate = _wet_dry_rate

	_horizon_mgr = HorizonMapManagerScript.new()
	if _terrain and _sun:
		_horizon_mgr.initialize(_terrain, _sun)
	_push_wet_uniforms()

	var texture_loader := preload("res://src/core/world/morrowind/morrowind_terrain_texture_loader.gd").new()
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
	if WetnessManager:
		WetnessManager.wet_margin = _wet_margin
		WetnessManager.wet_albedo_darken = _wet_albedo_darken
		WetnessManager.wet_roughness_target = _wet_roughness_target
		WetnessManager.retained_wetness_strength = _retained_wetness_strength
		WetnessManager.wet_dry_rate = _wet_dry_rate


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
		var mat := StandardMaterial3D.new()
		mat.albedo_color = spec["color"]
		mat.roughness = 0.7
		mi.material_override = mat
		add_child(mi)
		mi.global_position = _lab_pos(spec["offset"])
		var wettable: Node = WettableObjectScript.new()
		wettable.name = "WettableObject"
		mi.add_child(wettable)
		_test_objects.append({
			"node": mi,
		})

	var managed := MeshInstance3D.new()
	managed.name = "ManagedWetCube"
	var managed_mesh := BoxMesh.new()
	managed_mesh.size = Vector3.ONE
	managed.mesh = managed_mesh
	var managed_mat := StandardMaterial3D.new()
	managed_mat.albedo_color = Color(0.95, 0.65, 0.18)
	managed_mat.roughness = 0.72
	managed.material_override = managed_mat
	add_child(managed)
	managed.global_position = _lab_pos(Vector3(-17.0, 0.2, 18.5))
	var wettable: Node = WettableObjectScript.new()
	wettable.name = "WettableObject"
	managed.add_child(wettable)


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
	_optical_preset_button = _add_button(_button_grid, "", func() -> void:
		_apply_optical_preset((_current_optical_preset + 1) % OPTICAL_PRESETS.size())
	)
	_quality_button = _add_button(_button_grid, "", Callable(self, "_cycle_quality"))
	_mesh_button = _add_button(_button_grid, "", Callable(self, "_toggle_mesh_mode"))
	_surface_shader_button = _add_button(_button_grid, "", Callable(self, "_toggle_experimental_surface_shader"))
	_boujie_full_button = _add_button(_button_grid, "Boujie Full", Callable(self, "_toggle_boujie_full_preset"))
	_ocean_surface_button = _add_button(_button_grid, "", Callable(self, "_toggle_ocean_surface_visible"))
	_surface_ssr_button = _add_button(_button_grid, "", Callable(self, "_toggle_surface_ssr"))
	_surface_refraction_button = _add_button(_button_grid, "", Callable(self, "_toggle_surface_refraction"))
	_surface_refraction_debug_button = _add_button(_button_grid, "", Callable(self, "_cycle_surface_refraction_debug_mode"))
	_surface_edge_guard_button = _add_button(_button_grid, "", Callable(self, "_toggle_surface_edge_guard"))
	_waterline_button = _add_button(_button_grid, "", Callable(self, "_toggle_waterline_receiver"))
	_environment_ssr_button = _add_button(_button_grid, "", Callable(self, "_toggle_environment_ssr"))
	_spray_button = _add_button(_button_grid, "", Callable(self, "_toggle_spray"))
	_spray_quality_button = _add_button(_button_grid, "", Callable(self, "_cycle_spray_quality"))
	_sun_button = _add_button(_button_grid, "", Callable(self, "_toggle_sun_angle"))
	_add_button(_button_grid, "Center Shore", Callable(self, "_teleport_to_shore_probe"))
	_add_button(_button_grid, "Clear Water", Callable(self, "_reset_absorption_tint_control"))
	var visibility_changed := func(val: float) -> void:
		_visibility_distance_m = val
		_push_visibility_distance_control()
	_add_slider(ocean_tab, "base visibility m", 1.0, 120.0, _visibility_distance_m, visibility_changed, 0.5)
	var scatter_changed := func(val: float) -> void:
		_scattering_strength = val
		_push_scattering_strength_control()
	_add_slider(ocean_tab, "turbidity", 0.0, 1.0, _scattering_strength, scatter_changed, 0.01)
	var absorption_tint_changed := func(color: Color) -> void:
		if _syncing_ocean_optics_ui:
			return
		_absorption_tint = color
		_push_absorption_tint_control()
	_absorption_tint_picker = _add_color_picker(ocean_tab, "scatter color", _absorption_tint, absorption_tint_changed)

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
	_wet_live_button = _add_button(wetness_grid, "", Callable(self, "_toggle_wet_compositor"))
	_wet_debug_button = _add_button(wetness_grid, "", Callable(self, "_toggle_wet_debug"))
	_add_slider(wetness_tab, "margin", 0.0, 5.0, _wet_margin, func(val: float) -> void:
		_wet_margin = val
		_push_wet_uniforms()
	)
	_add_slider(wetness_tab, "darken", 0.0, 1.0, _wet_albedo_darken, func(val: float) -> void:
		_wet_albedo_darken = val
		_push_wet_uniforms()
	)
	_add_slider(wetness_tab, "rough", 0.0, 0.5, _wet_roughness_target, func(val: float) -> void:
		_wet_roughness_target = val
		_push_wet_uniforms()
	)

	_build_underwater_tabs(tabs)

	var debug_tab := VBoxContainer.new()
	debug_tab.name = "Debug"
	tabs.add_child(debug_tab)
	var debug_grid := _add_button_grid(debug_tab)
	_debug_button = _add_button(debug_grid, "", Callable(self, "_cycle_debug_mode"))
	_waterline_debug_button = _add_button(debug_grid, "", Callable(self, "_cycle_waterline_debug_mode"))
	_waterline_inspect_button = _add_button(debug_grid, "WL Inspect", Callable(self, "_start_waterline_receiver_inspection"))
	_waterline_replace_button = _add_button(debug_grid, "WL Replace", Callable(self, "_start_waterline_receiver_replacement_inspection"))
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
	_uw_wobble_check = _add_check(toggles, "Wobble", _uw_wobble_effect_enabled, func(value: bool) -> void:
		_uw_wobble_effect_enabled = value
		_push_underwater_effect_controls()
	)
	_uw_particles_check = _add_check(toggles, "Particles", _uw_particles_enabled, func(value: bool) -> void:
		_uw_particles_enabled = value
		_push_underwater_effect_controls()
		_refresh_control_labels()
	)
	_uw_caustics_check = _add_check(toggles, "Caustics", _uw_caustics_enabled, func(value: bool) -> void:
		_uw_caustics_enabled = value
		_push_underwater_effect_controls()
		_refresh_control_labels()
	)
	_uw_effect_check = _add_check(toggles, "Underwater medium", _underwater_effect_enabled, func(value: bool) -> void:
		_underwater_effect_enabled = value
		_refresh_control_labels()
	)

	var wl_row := HBoxContainer.new()
	effects_tab.add_child(wl_row)
	_underwater_debug_button = _add_button(wl_row, "", Callable(self, "_cycle_underwater_debug_mode"))
	_underwater_quality_button = _add_button(wl_row, "", Callable(self, "_cycle_underwater_quality"))
	_underwater_debug_button.custom_minimum_size.x = 180.0
	_underwater_quality_button.custom_minimum_size.x = 150.0

	_add_slider(effects_tab, "particle count", 0.0, 4096.0, float(_uw_particle_count), func(val: float) -> void:
		_uw_particle_count = int(roundf(val / 128.0)) * 128
		_push_underwater_effect_controls()
	)
	_add_slider(effects_tab, "particle size", 0.25, 4.0, _uw_particle_size_scale, func(val: float) -> void:
		_uw_particle_size_scale = val
		_push_underwater_effect_controls()
	)
	_add_slider(effects_tab, "particle speed", 0.0, 4.0, _uw_particle_speed_scale, func(val: float) -> void:
		_uw_particle_speed_scale = val
		_push_underwater_effect_controls()
	)
	_add_slider(effects_tab, "particle opacity", 0.0, 1.0, _uw_particle_density, func(val: float) -> void:
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


func _add_slider(
	parent: Control,
	label_text: String,
	min_val: float,
	max_val: float,
	initial: float,
	callback: Callable,
	step: float = 0.05
) -> void:
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
	slider.step = step
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


func _add_color_picker(parent: Control, label_text: String, initial: Color, callback: Callable) -> ColorPickerButton:
	var hbox := HBoxContainer.new()
	parent.add_child(hbox)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 80.0
	hbox.add_child(label)
	var picker := ColorPickerButton.new()
	picker.focus_mode = Control.FOCUS_NONE
	picker.color = initial
	picker.custom_minimum_size = Vector2(220.0, 28.0)
	picker.color_changed.connect(func(color: Color) -> void:
		callback.call(color)
	)
	hbox.add_child(picker)
	return picker


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
	if _optical_preset_button:
		var preset: Dictionary = OPTICAL_PRESETS[_current_optical_preset]
		_optical_preset_button.text = "Optics: %s" % preset["name"]
	if _mesh_button:
		var mode_text := "Clipmap"
		if WaterSystem and WaterSystem.is_initialized() and WaterSystem.has_method("get_mesh_mode"):
			mode_text = "Projected" if WaterSystem.get_mesh_mode() == 1 else "Clipmap"
		_mesh_button.text = "Mesh: %s" % mode_text
	if _sun_button:
		_sun_button.text = "Sun: %s" % ("Low" if _sun_low else "High")
	if _wet_live_button:
		_wet_live_button.text = "Wet Live: %s" % ("On" if _wet_compositor_enabled else "Off")
	if _wet_debug_button:
		_wet_debug_button.text = "Wet Debug: %s" % WET_DEBUG_MODE_NAMES[_wet_debug_mode]
	if _quality_button:
		var quality := WaterSystem.get_water_quality_name() if WaterSystem and WaterSystem.is_initialized() else "Unknown"
		_quality_button.text = "Quality: %s" % quality
	if _spray_button:
		_spray_button.text = "Spray: %s" % ("On" if _spray_enabled else "Off")
	if _spray_quality_button:
		var quality_name := WaterSystem.get_sea_spray_quality_name() if WaterSystem and WaterSystem.has_method("get_sea_spray_quality_name") else "Unknown"
		_spray_quality_button.text = "Spray Q: %s" % quality_name
	if _surface_shader_button:
		var shader_label := "Boujie High" if _experimental_surface_shader_enabled else "Default"
		if WaterSystem and WaterSystem.has_method("get_surface_shader_mode_name"):
			shader_label = WaterSystem.get_surface_shader_mode_name()
		_surface_shader_button.text = "Shader: %s" % shader_label
	if _boujie_full_button:
		_boujie_full_button.text = "Boujie Full: %s" % ("Disable" if _is_boujie_full_preset_active() else "Enable")
	if _ocean_surface_button:
		_ocean_surface_button.text = "Ocean Mesh: %s" % ("On" if _ocean_surface_visible else "Off")
	if _surface_ssr_button:
		_surface_ssr_button.text = "Surface SSR: %s" % ("On" if _surface_ssr_enabled else "Off")
	if _surface_refraction_button:
		_surface_refraction_button.disabled = _experimental_surface_shader_enabled
		_surface_refraction_button.text = "Refraction: %s" % (
			"Shader" if _experimental_surface_shader_enabled else ("On" if _surface_refraction_enabled else "Off")
		)
	if _surface_refraction_debug_button:
		_surface_refraction_debug_button.disabled = _experimental_surface_shader_enabled
		_surface_refraction_debug_button.text = "Refract Debug: %s" % SURFACE_REFRACTION_DEBUG_MODE_NAMES[_surface_refraction_debug_mode]
	if _surface_edge_guard_button:
		_surface_edge_guard_button.disabled = _experimental_surface_shader_enabled
		_surface_edge_guard_button.text = "Refract Guard: %s" % ("On" if _surface_edge_guard_enabled else "Off")
	if _waterline_button:
		_waterline_button.text = "Receiver WL: %s" % ("On" if _waterline_enabled else "Off")
	if _environment_ssr_button:
		_environment_ssr_button.text = "Env SSR: %s" % ("On" if _environment_ssr_enabled else "Off")
	if _underwater_button:
		_underwater_button.text = "Underwater: %s" % ("On" if _underwater_effect_enabled else "Off")
	if _underwater_debug_button:
		_underwater_debug_button.text = "UW Debug: %s" % UW_DEBUG_MODE_NAMES[_underwater_debug_mode]
	if _underwater_quality_button:
		_underwater_quality_button.text = "UW Q: %s" % UW_QUALITY_NAMES[clampi(_underwater_quality_tier, 0, UW_QUALITY_NAMES.size() - 1)]
	if _waterline_debug_button:
		_waterline_debug_button.text = "WL Debug: %s" % WATERLINE_DEBUG_MODE_NAMES[_waterline_debug_mode]
	if _waterline_inspect_button:
		_waterline_inspect_button.text = "WL Inspect"
	if _waterline_replace_button:
		_waterline_replace_button.text = "WL Replace"
	if _wireframe_button:
		_wireframe_button.text = "Wireframe: %s" % ("On" if _wireframe_enabled else "Off")
	if _uw_absorption_check:
		_uw_absorption_check.button_pressed = _uw_absorption_enabled
	if _uw_snell_check:
		_uw_snell_check.button_pressed = _uw_snell_enabled
	if _uw_wobble_check:
		_uw_wobble_check.button_pressed = _uw_wobble_effect_enabled
	if _uw_particles_check:
		_uw_particles_check.button_pressed = _uw_particles_enabled
	if _uw_caustics_check:
		_uw_caustics_check.button_pressed = _uw_caustics_enabled
	if _uw_effect_check:
		_uw_effect_check.button_pressed = _underwater_effect_enabled
	if _uw_profile_button:
		_uw_profile_button.text = "Profile: %s" % ("Stop" if _uw_profile_running else "Run")


func _process(delta: float) -> void:
	_update_average_frame_time(delta)
	_update_buoyancy_debug_grid()
	_update_held_object()
	_apply_ocean_surface_visibility()
	_update_surface_refraction_layer()
	_update_waterline_stack(delta)
	_update_wet_compositor()
	_update_underwater_compositor()
	_update_underwater_profile()
	_update_underwater_perf_label()
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


func _update_held_object() -> void:
	if _held_object.is_empty() or _camera == null:
		return
	var node: MeshInstance3D = _held_object["node"]
	node.global_position = _camera.global_position + -_camera.global_basis.z * 5.0


func _update_underwater_compositor() -> void:
	if _underwater_effect == null:
		return
	var debug_active := _underwater_debug_mode != 0
	_underwater_effect.effect_enabled = _underwater_effect_enabled or debug_active
	_underwater_effect.blend_factor = 1.0 if _underwater_effect.effect_enabled else 0.0
	if _underwater_effect.has_method("set_debug_mode"):
		_underwater_effect.call("set_debug_mode", _underwater_debug_mode)
	_push_underwater_effect_controls()
	if _underwater_effect.effect_enabled and _underwater_effect.has_method("sync_from_water_state"):
		_underwater_effect.call("sync_from_water_state", _get_water_state())
	if _underwater_effect.has_method("set_camera_water_level"):
		_underwater_effect.call("set_camera_water_level", _get_camera_water_level())


func _update_surface_refraction_layer() -> void:
	if _surface_refraction_layer == null:
		return
	if _experimental_surface_shader_enabled:
		_surface_refraction_layer.call("set_enabled", false)
		return
	if _ocean != null:
		_surface_refraction_layer.call(
			"configure",
			_camera,
			_world_env,
			_ocean,
			WATER_RENDER_LAYER_MASK
		)
	_surface_refraction_layer.call("process_layer", _get_main_viewport_size())


func _update_waterline_stack(delta: float) -> void:
	if _waterline_stack == null:
		return
	var debug_active := _waterline_debug_mode != 0
	var active := _waterline_enabled or debug_active
	_waterline_stack.set_enabled(active)
	if active:
		_waterline_stack.quality_tier = _waterline_quality_tier
		_waterline_stack.process_stack(delta, _get_main_viewport_size())
		if _waterline_inspection_active:
			_waterline_inspection_frames += 1
	else:
		_waterline_inspection_active = false
		_waterline_inspection_frames = 0
	_push_waterline_effect_controls()


func _update_wet_compositor() -> void:
	if _wet_effect == null:
		return
	var state := _get_water_state()
	var active := (
		(_wet_compositor_enabled or _wet_debug_mode != 0)
		and state != null
		and state.water_body_id != WaterSurfaceState.WATER_BODY_NONE
		and state.coverage_available
	)
	_wet_effect.effect_enabled = active
	_wet_effect.blend_factor = 1.0 if active else 0.0
	if (
		WetnessManager
		and WetnessManager.has_method("set_live_compositor_enabled")
		and WetnessManager.has_method("is_live_compositor_enabled")
		and bool(WetnessManager.is_live_compositor_enabled()) != active
	):
		WetnessManager.set_live_compositor_enabled(active)
	if _wet_effect.has_method("set_wet_params"):
		_wet_effect.call(
			"set_wet_params",
			_wet_margin,
			_wet_albedo_darken,
			_wet_roughness_target,
			_retained_wetness_strength,
			0.10,
			_wet_debug_mode
		)
	if active and _wet_effect.has_method("sync_from_water_state"):
		_wet_effect.call("sync_from_water_state", state)


func _get_main_viewport_size() -> Vector2i:
	var rect := get_viewport().get_visible_rect()
	var size := Vector2i(int(rect.size.x), int(rect.size.y))
	if size.x <= 0 or size.y <= 0:
		return Vector2i(1280, 720)
	return size


func _push_waterline_effect_controls() -> void:
	if _waterline_stack == null:
		return
	var effect := _waterline_stack.get_waterline_effect()
	if effect == null:
		return
	if effect.has_method("set_debug_mode"):
		effect.call("set_debug_mode", _waterline_debug_mode)
	if effect.has_method("set_quality_tier"):
		effect.call("set_quality_tier", _waterline_quality_tier)
	if effect.has_method("set_probe_strength"):
		effect.call("set_probe_strength", 1.0)
	if effect.has_method("set_binary_receiver_mask_enabled"):
		effect.call("set_binary_receiver_mask_enabled", true)
	if effect.has_method("set_receiver_refraction_enabled"):
		effect.call("set_receiver_refraction_enabled", false)
	if effect.has_method("set_receiver_medium_enabled"):
		effect.call("set_receiver_medium_enabled", false)
	if effect.has_method("set_receiver_surface_film_enabled"):
		effect.call("set_receiver_surface_film_enabled", false)
	if effect.has_method("set_underwater_feature_enabled"):
		effect.call("set_underwater_feature_enabled", &"absorption_fog", false)
		effect.call("set_underwater_feature_enabled", &"snell", false)
		effect.call("set_underwater_feature_enabled", &"wobble", false)
		effect.call("set_underwater_feature_enabled", &"particles", false)
		effect.call("set_underwater_feature_enabled", &"caustics", false)



func _push_underwater_effect_controls() -> void:
	if _underwater_effect == null:
		return
	_push_underwater_sun_direction()
	if _underwater_effect.has_method("set_quality_tier"):
		_underwater_effect.call("set_quality_tier", _underwater_quality_tier)
	if _underwater_effect.has_method("set_underwater_feature_enabled"):
		_underwater_effect.call("set_underwater_feature_enabled", &"absorption_fog", _uw_absorption_enabled)
		_underwater_effect.call("set_underwater_feature_enabled", &"snell", _uw_snell_enabled)
		_underwater_effect.call("set_underwater_feature_enabled", &"wobble", _uw_wobble_effect_enabled)
		_underwater_effect.call("set_underwater_feature_enabled", &"particles", _uw_particles_enabled)
		_underwater_effect.call("set_underwater_feature_enabled", &"caustics", _uw_caustics_enabled)
	if WaterSystem and WaterSystem.has_method("set_underwater_particles_enabled"):
		WaterSystem.set_underwater_particles_enabled(_uw_particles_enabled)
	if WaterSystem and WaterSystem.has_method("set_underwater_particles_quality"):
		WaterSystem.set_underwater_particles_quality(_uw_particles_quality)
	if WaterSystem and WaterSystem.has_method("set_underwater_particles_count"):
		WaterSystem.set_underwater_particles_count(_uw_particle_count)
	if WaterSystem and WaterSystem.has_method("set_underwater_particles_size_scale"):
		WaterSystem.set_underwater_particles_size_scale(_uw_particle_size_scale)
	if WaterSystem and WaterSystem.has_method("set_underwater_particles_speed_scale"):
		WaterSystem.set_underwater_particles_speed_scale(_uw_particle_speed_scale)
	if WaterSystem and WaterSystem.has_method("set_underwater_particles_opacity"):
		WaterSystem.set_underwater_particles_opacity(_uw_particle_density)
	if _underwater_effect.has_method("set_underwater_particle_params"):
		_underwater_effect.call(
			"set_underwater_particle_params",
			_uw_particle_noise_scale,
			_uw_particle_density,
			_uw_particle_near_gate_m,
			_uw_particle_far_gate_m
		)


func _push_underwater_sun_direction() -> void:
	if _underwater_effect == null or _sun == null:
		return
	if _underwater_effect.has_method("set_sun_direction"):
		_underwater_effect.call(
			"set_sun_direction",
			_sun.global_basis.z.normalized(),
			clampf(_sun.light_energy, 0.0, 1.0)
		)


func _set_underwater_profile_features(profile_name: String) -> void:
	_uw_absorption_enabled = profile_name == "Absorption" or profile_name == "Absorption+Wobble"
	_uw_wobble_effect_enabled = profile_name == "Wobble" or profile_name == "Absorption+Wobble"
	_uw_snell_enabled = false
	_uw_particles_enabled = false
	_uw_caustics_enabled = false
	_push_underwater_effect_controls()
	_refresh_control_labels()


func _underwater_profile_names() -> Array[String]:
	return [
		"All Off",
		"Absorption",
		"Wobble",
		"Absorption+Wobble",
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
	if not _uw_profile_running or _underwater_effect == null:
		return
	var names := _underwater_profile_names()
	if _uw_profile_step >= names.size():
		_uw_profile_running = false
		_set_underwater_profile_features("Absorption+Wobble")
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
		_set_underwater_profile_features("Absorption+Wobble")
	_refresh_control_labels()


func _get_underwater_perf_snapshot() -> Dictionary:
	if _underwater_effect != null and _underwater_effect.has_method("get_underwater_perf_snapshot"):
		var snapshot: Variant = _underwater_effect.call("get_underwater_perf_snapshot")
		if snapshot is Dictionary:
			return snapshot
	return {}


func _get_underwater_particles_status() -> Dictionary:
	if WaterSystem and WaterSystem.has_method("get_underwater_particles_status"):
		var status: Variant = WaterSystem.get_underwater_particles_status()
		if status is Dictionary:
			return status
	return {}


func _get_wet_perf_snapshot() -> Dictionary:
	if _wet_effect != null and _wet_effect.has_method("get_wet_perf_snapshot"):
		var snapshot: Variant = _wet_effect.call("get_wet_perf_snapshot")
		if snapshot is Dictionary:
			return snapshot
	return {}


func _update_underwater_perf_label() -> void:
	if _uw_perf_label == null:
		return
	var perf := _get_underwater_perf_snapshot()
	var particle_status := _get_underwater_particles_status()
	var wet_perf := _get_wet_perf_snapshot()
	var copy_ms := float(perf.get("scene_copy_ms", 0.0))
	var probe_ms := float(perf.get("probe_ms", 0.0))
	var total_ms := float(perf.get("total_ms", 0.0))
	var wet_ms := float(wet_perf.get("wet_compositor_ms", 0.0))
	var timing_valid := bool(perf.get("timing_valid", true))
	var stack_total_ms := total_ms + wet_ms
	var quality_name := UW_QUALITY_NAMES[clampi(int(perf.get("quality_tier", _underwater_quality_tier)), 0, UW_QUALITY_NAMES.size() - 1)]
	var scene_copy_active := bool(perf.get("scene_copy_active", false))
	var lines: Array[String] = []
	lines.append("[b]GPU timings[/b]")
	if timing_valid:
		lines.append("underwater copy: %.3f ms" % copy_ms)
		lines.append("underwater medium: %.3f ms" % probe_ms)
		lines.append("wetness: %.3f ms" % wet_ms)
		lines.append("stack subtotal: %.3f ms" % stack_total_ms)
	else:
		lines.append("timestamp sample invalid")
	lines.append("quality: %s  scene copy: %s" % [quality_name, "active" if scene_copy_active else "skipped"])
	lines.append("")
	lines.append("flags: fog=%s snell=%s wobble=%s particles=%s caustics=%s" % [
		"on" if _uw_absorption_enabled else "off",
		"on" if _uw_snell_enabled else "off",
		"on" if _uw_wobble_effect_enabled else "off",
		"on" if _uw_particles_enabled else "off",
		"on" if _uw_caustics_enabled else "off",
	])
	lines.append("particles: %d motes size %.2fx speed %.2fx opacity %.2f emitting=%s depth=%.2fm" % [
		int(particle_status.get("particle_count", 0)),
		float(particle_status.get("size_scale", _uw_particle_size_scale)),
		float(particle_status.get("speed_scale", _uw_particle_speed_scale)),
		_uw_particle_density,
		"on" if bool(particle_status.get("emitting", false)) else "off",
		float(particle_status.get("camera_water_depth", 0.0)),
	])
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
	if WaterSystem == null or not WaterSystem.is_initialized():
		return
	var ocean_mesh: OceanMesh = WaterSystem.get_ocean_mesh()
	if ocean_mesh:
		ocean_mesh.layers = WATER_RENDER_LAYER_MASK
		ocean_mesh.visible = _ocean_surface_visible
	if _surface_refraction_layer != null:
		_surface_refraction_layer.set("visible", _ocean_surface_visible and not _experimental_surface_shader_enabled)


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
	var quality := WaterSystem.get_water_quality_name() if WaterSystem and WaterSystem.is_initialized() else "not initialized"
	var mesh_mode := "unknown"
	if WaterSystem and WaterSystem.is_initialized() and WaterSystem.has_method("get_mesh_mode"):
		mesh_mode = "Projected" if WaterSystem.get_mesh_mode() == 1 else "Clipmap"
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
	var surface_shader_label := "Boujie High" if _experimental_surface_shader_enabled else "Default"
	if WaterSystem and WaterSystem.has_method("get_surface_shader_mode_name"):
		surface_shader_label = WaterSystem.get_surface_shader_mode_name()
	lines.append("surface_shader=%s  boujie_full=%s" % [
		surface_shader_label,
		"on" if _is_boujie_full_preset_active() else "off",
	])
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
		WET_DEBUG_MODE_NAMES[_wet_debug_mode],
		"low" if _sun_low else "high",
	])
	lines.append("wet_compositor=%s  wet_margin=%.2f" % [
		"on" if _wet_effect != null and _wet_effect.effect_enabled else "off",
		_wet_margin,
	])
	var spray_energy := WaterSystem.get_sea_spray_energy() if WaterSystem and WaterSystem.has_method("get_sea_spray_energy") else 0.0
	var spray_status: Dictionary = WaterSystem.get_sea_spray_status() if WaterSystem and WaterSystem.has_method("get_sea_spray_status") else {}
	lines.append("spray=%s/%s  emitting=%s  candidates=%d  energy=%.2f" % [
		"on" if _spray_enabled else "off",
		WaterSystem.get_sea_spray_quality_name() if WaterSystem and WaterSystem.has_method("get_sea_spray_quality_name") else "Unknown",
		"yes" if bool(spray_status.get("emitting", false)) else "no",
		int(spray_status.get("particle_candidates", 0)),
		spray_energy,
	])
	var particle_status := _get_underwater_particles_status()
	lines.append("uw_particles=%s  emitting=%s  motes=%d  size=%.2fx speed=%.2fx opacity=%.2f" % [
		"on" if _uw_particles_enabled else "off",
		"yes" if bool(particle_status.get("emitting", false)) else "no",
		int(particle_status.get("particle_count", 0)),
		float(particle_status.get("size_scale", _uw_particle_size_scale)),
		float(particle_status.get("speed_scale", _uw_particle_speed_scale)),
		_uw_particle_density,
	])
	lines.append("uw_features fog=%s snell=%s wobble=%s caustics=%s  particle_layer=%s/%s" % [
		"on" if _uw_absorption_enabled else "off",
		"on" if _uw_snell_enabled else "off",
		"on" if _uw_wobble_effect_enabled else "off",
		"on" if _uw_caustics_enabled else "off",
		"enabled" if bool(particle_status.get("enabled", _uw_particles_enabled)) else "off",
		str(particle_status.get("quality_name", _get_underwater_particles_quality_name())),
	])
	lines.append("ocean_mesh=%s  wireframe=%s  underwater=%s/%s" % [
		"on" if _ocean_surface_visible else "off",
		"on" if _wireframe_enabled else "off",
		"on" if _underwater_effect_enabled else "off",
		UW_DEBUG_MODE_NAMES[_underwater_debug_mode],
	])
	lines.append("surface_ssr=%s  refraction=%s guard=%s  env_ssr=%s" % [
		"on" if _surface_ssr_enabled else "off",
		"on" if _surface_refraction_enabled else "off",
		"on" if _surface_edge_guard_enabled else "off",
		"on" if _environment_ssr_enabled else "off",
	])
	if _surface_refraction_layer != null:
		var surf_refract: Dictionary = _surface_refraction_layer.call("get_runtime_status")
		lines.append("surface_refract_source_valid=%s depth_valid=%s size=%s scale=%.2f age=%s/%s" % [
			str(surf_refract.get("source_valid", false)),
			str(surf_refract.get("source_depth_valid", false)),
			str(surf_refract.get("source_size", Vector2i.ZERO)),
			float(surf_refract.get("source_resolution_scale", 0.0)),
			str(surf_refract.get("capture_frame_age", -1)),
			str(surf_refract.get("source_frame_tolerance", -1)),
		])
		lines.append("surface_refract_source_mode=%s layer=0x%X" % [
			str(surf_refract.get("source_mode", "unknown")),
			CONTROLLED_REFRACTION_RECEIVER_LAYER_MASK,
		])
		lines.append("surface_refract_mask_mode=%s reject=%s overlay=%s dispatch=%s" % [
			str(surf_refract.get("mask_mode", "off")),
			str(surf_refract.get("reject_reason", "none")),
			str(surf_refract.get("overlay_active", false)),
			str(surf_refract.get("dispatch_size", Vector2i.ZERO)),
		])
		var source_render_label := "--"
		if bool(surf_refract.get("controlled_source_render_timing_valid", false)):
			source_render_label = "%.3f" % float(surf_refract.get("controlled_source_render_ms", 0.0))
		var surface_ms_label := "--"
		if bool(surf_refract.get("surface_refraction_timing_valid", false)):
			surface_ms_label = "%.3f" % float(surf_refract.get("surface_refraction_ms", 0.0))
		var copy_ms_label := "--"
		if bool(surf_refract.get("controlled_source_copy_timing_valid", false)):
			copy_ms_label = "%.3f" % float(surf_refract.get("controlled_source_copy_ms", 0.0))
		var measured_ms_label := "--"
		if bool(surf_refract.get("controlled_copy_surface_timing_valid", false)):
			measured_ms_label = "%.3f" % float(surf_refract.get("controlled_copy_surface_ms", 0.0))
		var total_ms_label := "unavailable"
		if bool(surf_refract.get("controlled_total_refraction_timing_valid", false)):
			total_ms_label = "%.3f" % float(surf_refract.get("controlled_total_refraction_ms", 0.0))
		lines.append("surface_refract_ms=%s copy=%s measured=%s total=%s src_render=%s" % [
			surface_ms_label,
			copy_ms_label,
			measured_ms_label,
			total_ms_label,
			source_render_label,
		])
		lines.append("surface_refract_timing avail src/copy/final/total=%s/%s/%s/%s valid=%s/%s/%s/%s" % [
			str(surf_refract.get("controlled_source_render_timing_available", false)),
			str(surf_refract.get("controlled_source_copy_timing_available", false)),
			str(surf_refract.get("surface_refraction_timing_available", false)),
			str(surf_refract.get("controlled_total_refraction_timing_available", false)),
			str(surf_refract.get("controlled_source_render_timing_valid", false)),
			str(surf_refract.get("controlled_source_copy_timing_valid", false)),
			str(surf_refract.get("surface_refraction_timing_valid", false)),
			str(surf_refract.get("controlled_total_refraction_timing_valid", false)),
		])
		lines.append("surface_refract_frames src/copy/final=%s/%s/%s same=%s reason=%s" % [
			str(surf_refract.get("controlled_source_render_frame", -1)),
			str(surf_refract.get("controlled_source_copy_frame", -1)),
			str(surf_refract.get("surface_refraction_frame", -1)),
			str(surf_refract.get("controlled_total_same_timing_frame", false)),
			str(surf_refract.get("controlled_total_refraction_unavailable_reason", "unknown")),
		])
		lines.append("surface_refract_marker_scope src=%s copy=%s" % [
			str(surf_refract.get("controlled_source_render_timing_marker_scope", "")),
			str(surf_refract.get("controlled_source_copy_timing_marker_scope", "")),
		])
	lines.append("receiver_waterline=%s  wl_debug=%d %s" % [
		"on" if _waterline_enabled else "off",
		_waterline_debug_mode,
		WATERLINE_DEBUG_MODE_NAMES[_waterline_debug_mode],
	])
	var wl_perf := _get_waterline_perf_snapshot()
	if not wl_perf.is_empty():
		var wl_capture := _get_waterline_capture_snapshot()
		var source_size: Variant = wl_perf.get("source_size", Vector2i.ZERO)
		var source_status := _get_waterline_source_status(wl_perf, wl_capture)
		lines.append("wl_source=%s  color=%s depth=%s  occ=%s  source_size=%s" % [
			source_status,
			"ok" if bool(wl_perf.get("external_source_color_valid", false)) else "--",
			"ok" if bool(wl_perf.get("external_source_depth_valid", false)) else "--",
			"ok" if bool(wl_perf.get("external_occlusion_depth_valid", false)) else "--",
			str(source_size),
		])
		lines.append("wl_frame_age=%s  occ_age=%s  dispatch=%s  q=%d" % [
			str(wl_perf.get("external_source_frame_age", -1)),
			str(wl_perf.get("external_occlusion_frame_age", -1)),
			str(wl_perf.get("dispatch_size", Vector2i.ZERO)),
			int(wl_perf.get("quality_tier", _waterline_quality_tier)),
		])
		lines.append("wl_occ=%s  occ_age=%s  occ_size=%s" % [
			"ok" if bool(wl_perf.get("external_occlusion_depth_valid", false)) else "--",
			str(wl_perf.get("external_occlusion_frame_age", -1)),
			str(wl_perf.get("occlusion_size", Vector2i.ZERO)),
		])
		if not wl_capture.is_empty():
			lines.append("wl_capture=%s  has=%s  fade=%.2f  cap_size=%s" % [
				"active" if bool(wl_capture.get("capture_active", false)) else "off",
				"yes" if bool(wl_capture.get("has_capture", false)) else "no",
				float(wl_capture.get("activation_fade", 0.0)),
				str(wl_capture.get("source_size", Vector2i.ZERO)),
			])
	var sigma := WaterSystem.get_absorption_sigma() if WaterSystem and WaterSystem.has_method("get_absorption_sigma") else Vector3.ZERO
	lines.append("optics vis=%.1fm  turb=%.2f  tint=#%s  sigma=(%.3f %.3f %.3f)" % [
		_visibility_distance_m,
		_scattering_strength,
		_absorption_tint.to_html(false),
		sigma.x,
		sigma.y,
		sigma.z,
	])
	var uw_perf := _get_underwater_perf_snapshot()
	if not uw_perf.is_empty():
		var quality_name := UW_QUALITY_NAMES[clampi(int(uw_perf.get("quality_tier", _underwater_quality_tier)), 0, UW_QUALITY_NAMES.size() - 1)]
		var wet_perf := _get_wet_perf_snapshot()
		var wet_ms := float(wet_perf.get("wet_compositor_ms", 0.0))
		if bool(uw_perf.get("timing_valid", true)):
			lines.append("uw_gpu=%s %.3f ms (copy %.3f / probe %.3f / wet %.3f)" % [
				quality_name,
				float(uw_perf.get("total_ms", 0.0)),
				float(uw_perf.get("scene_copy_ms", 0.0)),
				float(uw_perf.get("probe_ms", 0.0)),
				wet_ms,
			])
		else:
			lines.append("uw_gpu=-- (timestamp sample invalid)")
	if _help_visible:
		lines.append("")
		lines.append("Use the control panel buttons for ocean/debug actions.")
		lines.append("RMB + movement actions flies the camera.")
		lines.append("LClick picks/drops wet test objects.")
		if _surface_refraction_debug_mode != 0:
			lines.append("Surface compositor debug: %s." % SURFACE_REFRACTION_DEBUG_MODE_NAMES[_surface_refraction_debug_mode])
			if _surface_refraction_debug_mode == 7:
				lines.append("Ownership RGB: red=original water-owned, green=shifted water-owned, blue=unshifted source submerged.")
		if _debug_mode == 6:
			lines.append("Ocean shader legacy refraction view: green=accepted, red=rejected, blue=UV offset.")
		elif _debug_mode == 7:
			lines.append("Refract Depth: red=depth delta, green=stable edge, blue=below-water hit.")
		elif _debug_mode == 8:
			lines.append("SSR Hit: green/reflected color marks successful surface reflection rays.")
		elif _debug_mode == 12:
			lines.append("Refract Delta: orange=shifted scene color differs, blue=optional hard-reject preview.")
		elif _debug_mode == 13:
			lines.append("Source Straight: raw opaque scene color sampled at SCREEN_UV.")
		elif _debug_mode == 14:
			lines.append("Source Refracted: raw opaque scene color sampled at the refracted candidate UV.")
		elif _debug_mode == 15:
			lines.append("Refract Mask: red=rejected candidate, green=used refracted sample, blue=UV offset.")
		elif _debug_mode == 16:
			lines.append("Godot Depth Weight: red=straight/source-safe, green=PR #93449 refract weight, blue=depth delta.")
		elif _debug_mode == 17:
			lines.append("Depth Edge Fade: red=SCREEN_UV edge, green=candidate edge, blue=would fade to straight sample.")
		elif _debug_mode == 18:
			lines.append("Godot Source Preview: raw source color with PR #93449's depth-weighted UV mix.")
		elif _debug_mode == 19:
			lines.append("Refract Weight: black=straight source, white=refracted source; gray means unwanted blend.")
		elif _debug_mode == 20:
			lines.append("Source Blend: raw straight/refracted source mix before absorption/Fresnel/SSR.")
		if _underwater_debug_mode == 1:
			lines.append("UW Path Length: blue=short water path, red=long water path.")
		elif _underwater_debug_mode == 2:
			lines.append("UW Transmittance: bright=clear, dark=absorbed.")
		elif _underwater_debug_mode == 3:
			lines.append("UW Mask: green=underwater hit, blue=sky/far depth.")
		elif _underwater_debug_mode == 4:
			lines.append("UW Wobble Delta: orange marks shifted scene-color differences.")
		elif _underwater_debug_mode == 5:
			lines.append("UW Wobble Guard: green=shifted sample, red=fallback.")
		if _waterline_debug_mode == 5:
			lines.append("WL Refract Status: color-coded receiver source rejection/acceptance.")
		elif _waterline_debug_mode == 6:
			lines.append("WL Refract Offset: red=offset size, green=accepted receiver mask.")
		elif _waterline_debug_mode == 7:
			lines.append("WL Sources: red=missing color, green=receiver depth, blue=scene copy.")
		elif _waterline_debug_mode == 9:
			lines.append("WL Pipeline: verifies receiver source, main depth, water ray, and final mask.")
		elif _waterline_debug_mode == 14:
			lines.append("WL Final Mask: red=final binary receiver silhouette; dim green/blue=water gates.")
			if _waterline_inspection_active:
				lines.append("WL Inspect keeps surface refraction, SSR, underwater medium, and live wetness off for this view.")
		elif _waterline_debug_mode == 0 and _waterline_inspection_active:
			lines.append("WL Replace shows binary receiver replacement with receiver-local absorption and surface film.")
		if _wet_debug_mode == 1:
			lines.append("Wet Final: blue=final live wetness written by the compositor.")
		elif _wet_debug_mode == 2:
			lines.append("Wet Depth: red=above water, green=contact band, blue=skipped submerged surface.")
		elif _wet_debug_mode == 3:
			lines.append("Wet Body: red=shore-mask land gate, green=water gate, blue=raw coverage.")
		elif _wet_debug_mode == 4:
			lines.append("Wet Exclusion: red=excluded glossy/upward near-water pixels, green=roughness, blue=normal.y.")
		elif _wet_debug_mode == 5:
			lines.append("Wet World: RGB=fract(world x/y/z), use to spot reconstruction drift.")
		lines.append("Playground: %s" % _shore_search_status)
	_hud_label.text = "\n".join(lines)


func _cycle_debug_mode() -> void:
	_debug_mode = (_debug_mode + 1) % DEBUG_MODE_NAMES.size()
	if WaterSystem and WaterSystem.has_method("set_debug_mode"):
		WaterSystem.set_debug_mode(_debug_mode)
	_refresh_control_labels()
	Log.info("water", "[Ocean Lab] debug_mode %d = %s" % [_debug_mode, DEBUG_MODE_NAMES[_debug_mode]])
	_log_refraction_baseline_state("debug_mode")


func _apply_weather_preset(idx: int) -> void:
	if idx < 0 or idx >= WEATHER_PRESETS.size():
		return
	_current_weather = idx
	if not WaterSystem or not WaterSystem.is_initialized():
		return
	var preset: Dictionary = WEATHER_PRESETS[idx]
	var result := WeatherTypesScript.WeatherResult.new()
	result.wind_speed = preset["wind"]
	result.cloud_coverage = preset["cloud"]
	var wind_rad := deg_to_rad(45.0)
	result.storm_direction = Vector3(sin(wind_rad), 0.0, cos(wind_rad))
	WaterSystem.apply_weather(result)
	_apply_flat_water_override(bool(preset.get("flat_water", false)))
	_apply_optical_preset(_current_optical_preset)
	_sync_ocean_optics_from_manager()
	_refresh_control_labels()
	Log.info("water", "[Ocean Lab] weather preset %s wind=%.2f" % [preset["name"], preset["wind"]])


func _apply_optical_preset(idx: int) -> void:
	if idx < 0 or idx >= OPTICAL_PRESETS.size():
		return
	_current_optical_preset = idx
	if not WaterSystem or not WaterSystem.is_initialized():
		return
	var preset: Dictionary = OPTICAL_PRESETS[idx]
	_visibility_distance_m = float(preset["visibility"])
	_scattering_strength = float(preset["scatter"])
	_absorption_tint = preset["color"]
	if WaterSystem.has_method("set_water_visibility_distance"):
		WaterSystem.set_water_visibility_distance(_visibility_distance_m)
	if WaterSystem.has_method("set_water_scattering_strength"):
		WaterSystem.set_water_scattering_strength(_scattering_strength)
	if WaterSystem.has_method("set_water_scattering_color"):
		WaterSystem.set_water_scattering_color(_absorption_tint)
	_sync_ocean_optics_from_manager()
	_refresh_control_labels()
	Log.info("water", "[Ocean Lab] optics preset %s visibility=%.1fm turbidity=%.2f" % [
		preset["name"],
		_visibility_distance_m,
		_scattering_strength,
	])


func _apply_flat_water_override(enabled: bool) -> void:
	if not WaterSystem or not WaterSystem.is_initialized():
		return
	var target_wave_scale := 0.0 if enabled else _default_wave_scale
	WaterSystem.wave_scale = target_wave_scale
	if WaterSystem.has_method("set_wind_strength"):
		WaterSystem.set_wind_strength(0.0 if enabled else clampf(float(WEATHER_PRESETS[_current_weather]["wind"]) / 0.9, 0.0, 1.0))
	if WaterSystem._ocean_mesh:
		WaterSystem._ocean_mesh.set_wave_scale(target_wave_scale)
		var mat: ShaderMaterial = WaterSystem._ocean_mesh.get_material()
		if mat:
			mat.set_shader_parameter("shore_wave_amplitude", 0.0 if enabled else WaterSystem._current_shore_wave_amplitude)
			mat.set_shader_parameter("normal_strength", 0.0 if enabled else lerpf(0.6, 1.6, clampf(float(WEATHER_PRESETS[_current_weather]["wind"]) / 0.9, 0.0, 1.0)))
	WaterSystem._current_shore_wave_amplitude = 0.0 if enabled else WaterSystem._current_shore_wave_amplitude


func _toggle_buoy_grid() -> void:
	_buoy_grid_visible = not _buoy_grid_visible
	if _debug_mmi:
		_debug_mmi.visible = _buoy_grid_visible


func _toggle_mesh_mode() -> void:
	if not WaterSystem or not WaterSystem.is_initialized() or not WaterSystem.has_method("rebuild_mesh_with_mode"):
		return
	var current: int = WaterSystem.get_mesh_mode()
	var next := 1 if current == 0 else 0
	if next == 1 and WaterSystem.get_water_quality() != OceanMesh.QualityMode.HIGH:
		WaterSystem.set_water_quality(1)
	WaterSystem.rebuild_mesh_with_mode(next)
	WaterSystem.set_camera(_camera)
	_ocean = WaterSystem.get_ocean_mesh()
	_push_surface_shader_mode()
	if _surface_refraction_layer != null:
		_surface_refraction_layer.call(
			"configure",
			_camera,
			_world_env,
			_ocean,
			WATER_RENDER_LAYER_MASK
		)
	if WaterSystem.has_method("set_sea_spray_render_layers"):
		WaterSystem.set_sea_spray_render_layers(WATER_RENDER_LAYER_MASK)
	if WaterSystem.has_method("set_underwater_particles_render_layers"):
		WaterSystem.set_underwater_particles_render_layers(WATER_RENDER_LAYER_MASK)
	_apply_ocean_surface_visibility()
	_apply_weather_preset(_current_weather)
	_push_surface_refraction_control()
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
	_push_underwater_sun_direction()
	_refresh_control_labels()


func _toggle_wet_debug() -> void:
	_wet_debug_mode = (_wet_debug_mode + 1) % WET_DEBUG_MODE_NAMES.size()
	var object_debug := _wet_debug_mode != 0
	if _horizon_mgr:
		_horizon_mgr._set_param("wet_debug", object_debug)
	if _wet_effect and _wet_effect.has_method("set_debug_mode"):
		_wet_effect.call("set_debug_mode", _wet_debug_mode)
	if WetnessManager and WetnessManager.has_method("set_debug_mask"):
		WetnessManager.set_debug_mask(object_debug)
	_refresh_control_labels()
	_log_refraction_baseline_state("wet_debug")


func _toggle_wet_compositor() -> void:
	_wet_compositor_enabled = not _wet_compositor_enabled
	_refresh_control_labels()
	_log_refraction_baseline_state("wetness")


func _teleport_to_shore_probe() -> void:
	if _camera == null:
		return
	var target := _playground_origin
	_camera.global_position = target + Vector3(0.0, 18.0, 45.0)
	_camera.look_at(target, Vector3.UP)


func _start_waterline_receiver_inspection() -> void:
	_start_waterline_receiver_isolated_view(14, "waterline_inspect")


func _start_waterline_receiver_replacement_inspection() -> void:
	_start_waterline_receiver_isolated_view(0, "waterline_replace")


func _start_waterline_receiver_isolated_view(debug_mode: int, log_context: String) -> void:
	_waterline_enabled = true
	_waterline_debug_mode = clampi(debug_mode, 0, WATERLINE_DEBUG_MODE_NAMES.size() - 1)
	_waterline_inspection_active = true
	_waterline_inspection_frames = 0
	_surface_refraction_enabled = false
	_surface_edge_guard_enabled = false
	_surface_ssr_enabled = false
	_underwater_effect_enabled = false
	_underwater_debug_mode = 0
	_wet_compositor_enabled = false
	_wet_debug_mode = 0
	_push_surface_refraction_control()
	_push_surface_ssr_control()
	_push_underwater_effect_controls()
	_push_waterline_effect_controls()
	_teleport_to_shore_probe()
	_refresh_control_labels()
	_log_refraction_baseline_state(log_context)


func _cycle_quality() -> void:
	if not WaterSystem or not WaterSystem.is_initialized():
		return
	var current: OceanMesh.QualityMode = WaterSystem.get_water_quality()
	var next := 1
	if current == OceanMesh.QualityMode.HIGH:
		next = 0
	else:
		next = 1
	if next == 0 and WaterSystem.get_mesh_mode() == 1:
		WaterSystem.rebuild_mesh_with_mode(0)
	WaterSystem.set_water_quality(next)
	WaterSystem.set_camera(_camera)
	_ocean = WaterSystem.get_ocean_mesh()
	_push_surface_shader_mode()
	if WaterSystem.has_method("set_sea_spray_render_layers"):
		WaterSystem.set_sea_spray_render_layers(WATER_RENDER_LAYER_MASK)
	if WaterSystem.has_method("set_underwater_particles_render_layers"):
		WaterSystem.set_underwater_particles_render_layers(WATER_RENDER_LAYER_MASK)
	_apply_ocean_surface_visibility()
	_apply_weather_preset(_current_weather)
	_push_surface_refraction_control()
	_refresh_control_labels()


func _toggle_spray() -> void:
	_spray_enabled = not _spray_enabled
	if WaterSystem and WaterSystem.has_method("set_sea_spray_enabled"):
		WaterSystem.set_sea_spray_enabled(_spray_enabled)
	_refresh_control_labels()


func _toggle_experimental_surface_shader() -> void:
	_set_experimental_surface_shader_enabled(not _experimental_surface_shader_enabled)
	_log_refraction_baseline_state("surface_shader")


func _set_experimental_surface_shader_enabled(enabled: bool) -> void:
	if _experimental_surface_shader_enabled == enabled:
		_push_surface_shader_mode()
		_push_surface_refraction_control()
		return
	_experimental_surface_shader_enabled = enabled
	if enabled:
		_saved_surface_refraction_enabled = _surface_refraction_enabled
		_saved_surface_refraction_debug_mode = _surface_refraction_debug_mode
		_saved_surface_edge_guard_enabled = _surface_edge_guard_enabled
		_surface_refraction_enabled = false
		_surface_refraction_debug_mode = 0
		_surface_edge_guard_enabled = false
	else:
		_surface_refraction_enabled = _saved_surface_refraction_enabled
		_surface_refraction_debug_mode = _saved_surface_refraction_debug_mode
		_surface_edge_guard_enabled = _saved_surface_edge_guard_enabled

	_push_surface_shader_mode()
	_apply_weather_preset(_current_weather)
	_apply_optical_preset(_current_optical_preset)
	_push_surface_ssr_control()
	_push_surface_refraction_control()


func _toggle_boujie_full_preset() -> void:
	if _is_boujie_full_preset_active():
		_restore_boujie_full_previous_state()
		return
	_capture_boujie_full_previous_state()
	_apply_boujie_full_preset()


func _capture_boujie_full_previous_state() -> void:
	_boujie_full_restore_state = {
		"water_quality": WaterSystem.get_water_quality() if WaterSystem and WaterSystem.is_initialized() else -1,
		"experimental_surface_shader_enabled": _experimental_surface_shader_enabled,
		"surface_refraction_enabled": _surface_refraction_enabled,
		"surface_refraction_debug_mode": _surface_refraction_debug_mode,
		"surface_edge_guard_enabled": _surface_edge_guard_enabled,
		"waterline_enabled": _waterline_enabled,
		"waterline_debug_mode": _waterline_debug_mode,
		"waterline_inspection_active": _waterline_inspection_active,
		"waterline_inspection_frames": _waterline_inspection_frames,
		"wet_compositor_enabled": _wet_compositor_enabled,
		"ocean_surface_visible": _ocean_surface_visible,
		"surface_ssr_enabled": _surface_ssr_enabled,
		"environment_ssr_enabled": _environment_ssr_enabled,
		"spray_enabled": _spray_enabled,
		"spray_quality": _spray_quality,
		"underwater_effect_enabled": _underwater_effect_enabled,
		"underwater_debug_mode": _underwater_debug_mode,
		"underwater_quality_tier": _underwater_quality_tier,
		"uw_absorption_enabled": _uw_absorption_enabled,
		"uw_snell_enabled": _uw_snell_enabled,
		"uw_wobble_effect_enabled": _uw_wobble_effect_enabled,
		"uw_particles_enabled": _uw_particles_enabled,
		"uw_caustics_enabled": _uw_caustics_enabled,
		"uw_particles_quality": _uw_particles_quality,
		"uw_particle_count": _uw_particle_count,
		"uw_particle_size_scale": _uw_particle_size_scale,
		"uw_particle_speed_scale": _uw_particle_speed_scale,
		"uw_particle_density": _uw_particle_density,
	}
	_boujie_full_restore_valid = true


func _restore_boujie_full_previous_state() -> void:
	if not _boujie_full_restore_valid:
		_set_experimental_surface_shader_enabled(false)
		_underwater_effect_enabled = false
		_uw_particles_enabled = false
		_uw_snell_enabled = false
		_uw_caustics_enabled = false
		_refresh_control_labels()
		_log_refraction_baseline_state("boujie_full_disable")
		return

	var state := _boujie_full_restore_state
	var saved_quality := int(state.get("water_quality", -1))
	if saved_quality >= 0 and WaterSystem and WaterSystem.is_initialized():
		WaterSystem.set_water_quality(saved_quality)
		WaterSystem.set_camera(_camera)
		_ocean = WaterSystem.get_ocean_mesh()
		if _ocean != null:
			_ocean.layers = WATER_RENDER_LAYER_MASK

	_experimental_surface_shader_enabled = bool(state.get("experimental_surface_shader_enabled", false))
	_surface_refraction_enabled = bool(state.get("surface_refraction_enabled", false))
	_surface_refraction_debug_mode = int(state.get("surface_refraction_debug_mode", 0))
	_surface_edge_guard_enabled = bool(state.get("surface_edge_guard_enabled", false))
	_waterline_enabled = bool(state.get("waterline_enabled", false))
	_waterline_debug_mode = int(state.get("waterline_debug_mode", 0))
	_waterline_inspection_active = bool(state.get("waterline_inspection_active", false))
	_waterline_inspection_frames = int(state.get("waterline_inspection_frames", 0))
	_wet_compositor_enabled = bool(state.get("wet_compositor_enabled", false))
	_ocean_surface_visible = bool(state.get("ocean_surface_visible", true))
	_surface_ssr_enabled = bool(state.get("surface_ssr_enabled", false))
	_environment_ssr_enabled = bool(state.get("environment_ssr_enabled", true))
	_spray_enabled = bool(state.get("spray_enabled", true))
	_spray_quality = int(state.get("spray_quality", 2))
	_underwater_effect_enabled = bool(state.get("underwater_effect_enabled", false))
	_underwater_debug_mode = int(state.get("underwater_debug_mode", 0))
	_underwater_quality_tier = int(state.get("underwater_quality_tier", 1))
	_uw_absorption_enabled = bool(state.get("uw_absorption_enabled", true))
	_uw_snell_enabled = bool(state.get("uw_snell_enabled", false))
	_uw_wobble_effect_enabled = bool(state.get("uw_wobble_effect_enabled", true))
	_uw_particles_enabled = bool(state.get("uw_particles_enabled", false))
	_uw_caustics_enabled = bool(state.get("uw_caustics_enabled", false))
	_uw_particles_quality = int(state.get("uw_particles_quality", 2))
	_uw_particle_count = int(state.get("uw_particle_count", 4096))
	_uw_particle_size_scale = float(state.get("uw_particle_size_scale", 4.0))
	_uw_particle_speed_scale = float(state.get("uw_particle_speed_scale", 1.5))
	_uw_particle_density = float(state.get("uw_particle_density", 1.0))

	if WaterSystem and WaterSystem.has_method("set_sea_spray_enabled"):
		WaterSystem.set_sea_spray_enabled(_spray_enabled)
	if WaterSystem and WaterSystem.has_method("set_sea_spray_quality"):
		WaterSystem.set_sea_spray_quality(_spray_quality)
	_push_surface_shader_mode()
	_apply_weather_preset(_current_weather)
	_apply_optical_preset(_current_optical_preset)
	_apply_ocean_surface_visibility()
	_apply_environment_ssr_enabled()
	_push_surface_ssr_control()
	_push_surface_refraction_control()
	_push_waterline_effect_controls()
	_push_underwater_effect_controls()
	_boujie_full_restore_state.clear()
	_boujie_full_restore_valid = false
	_refresh_control_labels()
	_log_refraction_baseline_state("boujie_full_disable")


func _apply_boujie_full_preset() -> void:
	if WaterSystem and WaterSystem.is_initialized():
		if WaterSystem.get_water_quality() != OceanMesh.QualityMode.HIGH:
			WaterSystem.set_water_quality(OceanMesh.QualityMode.HIGH)
			WaterSystem.set_camera(_camera)
			_ocean = WaterSystem.get_ocean_mesh()
			if _ocean != null:
				_ocean.layers = WATER_RENDER_LAYER_MASK
	_set_experimental_surface_shader_enabled(true)
	_surface_refraction_enabled = false
	_surface_refraction_debug_mode = 0
	_surface_edge_guard_enabled = false
	_waterline_enabled = false
	_waterline_debug_mode = 0
	_waterline_inspection_active = false
	_waterline_inspection_frames = 0
	_wet_compositor_enabled = true
	_ocean_surface_visible = true
	_surface_ssr_enabled = true
	_environment_ssr_enabled = true
	_spray_enabled = true
	_spray_quality = 3
	_underwater_effect_enabled = true
	_underwater_debug_mode = 0
	_underwater_quality_tier = UW_QUALITY_NAMES.size() - 1
	_uw_absorption_enabled = true
	_uw_snell_enabled = true
	_uw_wobble_effect_enabled = true
	_uw_particles_enabled = true
	_uw_caustics_enabled = true
	_uw_particles_quality = 3
	_uw_particle_count = 4096
	_uw_particle_size_scale = 4.0
	_uw_particle_speed_scale = 1.5
	_uw_particle_density = 1.0
	if WaterSystem and WaterSystem.has_method("set_sea_spray_enabled"):
		WaterSystem.set_sea_spray_enabled(_spray_enabled)
	if WaterSystem and WaterSystem.has_method("set_sea_spray_quality"):
		WaterSystem.set_sea_spray_quality(_spray_quality)
	_apply_ocean_surface_visibility()
	_apply_environment_ssr_enabled()
	_push_surface_refraction_control()
	_push_waterline_effect_controls()
	_push_surface_ssr_control()
	_push_underwater_effect_controls()
	_refresh_control_labels()
	_log_refraction_baseline_state("boujie_full")


func _is_boujie_full_preset_active() -> bool:
	return (
		_experimental_surface_shader_enabled
		and not _surface_refraction_enabled
		and _surface_refraction_debug_mode == 0
		and not _surface_edge_guard_enabled
		and not _waterline_enabled
		and _waterline_debug_mode == 0
		and _wet_compositor_enabled
		and _ocean_surface_visible
		and _surface_ssr_enabled
		and _environment_ssr_enabled
		and _spray_enabled
		and _spray_quality == 3
		and _underwater_effect_enabled
		and _underwater_debug_mode == 0
		and _underwater_quality_tier == UW_QUALITY_NAMES.size() - 1
		and _uw_absorption_enabled
		and _uw_snell_enabled
		and _uw_wobble_effect_enabled
		and _uw_particles_enabled
		and _uw_caustics_enabled
		and _uw_particles_quality == 3
	)


func _cycle_spray_quality() -> void:
	_spray_quality = (_spray_quality + 1) % 4
	if WaterSystem and WaterSystem.has_method("set_sea_spray_quality"):
		WaterSystem.set_sea_spray_quality(_spray_quality)
	_refresh_control_labels()


func _toggle_ocean_surface_visible() -> void:
	_ocean_surface_visible = not _ocean_surface_visible
	_apply_ocean_surface_visibility()
	_refresh_control_labels()


func _toggle_surface_ssr() -> void:
	_surface_ssr_enabled = not _surface_ssr_enabled
	_push_surface_ssr_control()
	_log_refraction_baseline_state("surface_ssr")


func _toggle_surface_refraction() -> void:
	if _experimental_surface_shader_enabled:
		return
	_surface_refraction_enabled = not _surface_refraction_enabled
	_push_surface_refraction_control()
	_log_refraction_baseline_state("surface_refraction")


func _cycle_surface_refraction_debug_mode() -> void:
	if _experimental_surface_shader_enabled:
		return
	_surface_refraction_debug_mode = (_surface_refraction_debug_mode + 1) % SURFACE_REFRACTION_DEBUG_MODE_NAMES.size()
	if _surface_refraction_layer != null and _surface_refraction_layer.has_method("set_debug_mode"):
		_surface_refraction_layer.call("set_debug_mode", _surface_refraction_debug_mode)
	_push_surface_refraction_control()
	_refresh_control_labels()
	_log_refraction_baseline_state("surface_refraction_debug")


func _toggle_surface_edge_guard() -> void:
	if _experimental_surface_shader_enabled:
		return
	_surface_edge_guard_enabled = not _surface_edge_guard_enabled
	_push_surface_refraction_control()
	_log_refraction_baseline_state("surface_edge_guard")


func _toggle_waterline_receiver() -> void:
	_waterline_enabled = not _waterline_enabled
	_refresh_control_labels()
	_log_refraction_baseline_state("receiver_waterline")


func _toggle_environment_ssr() -> void:
	_environment_ssr_enabled = not _environment_ssr_enabled
	_apply_environment_ssr_enabled()
	_refresh_control_labels()
	_log_refraction_baseline_state("environment_ssr")


func _apply_environment_ssr_enabled() -> void:
	if _world_env != null and _world_env.environment != null:
		_world_env.environment.ssr_enabled = _environment_ssr_enabled


func _toggle_underwater_compositor() -> void:
	_underwater_effect_enabled = not _underwater_effect_enabled
	_refresh_control_labels()
	_log_refraction_baseline_state("underwater")


func _cycle_underwater_debug_mode() -> void:
	_underwater_debug_mode = (_underwater_debug_mode + 1) % UW_DEBUG_MODE_NAMES.size()
	if _underwater_effect and _underwater_effect.has_method("set_debug_mode"):
		_underwater_effect.call("set_debug_mode", _underwater_debug_mode)
	_refresh_control_labels()
	_log_refraction_baseline_state("underwater_debug")


func _cycle_waterline_debug_mode() -> void:
	_waterline_debug_mode = (_waterline_debug_mode + 1) % WATERLINE_DEBUG_MODE_NAMES.size()
	_push_waterline_effect_controls()
	_refresh_control_labels()
	_log_refraction_baseline_state("waterline_debug")


func _cycle_underwater_quality() -> void:
	_underwater_quality_tier = (_underwater_quality_tier + 1) % UW_QUALITY_NAMES.size()
	_push_underwater_effect_controls()
	_refresh_control_labels()


func _cycle_underwater_particles_quality() -> void:
	_uw_particles_quality = (_uw_particles_quality + 1) % 4
	if WaterSystem and WaterSystem.has_method("set_underwater_particles_quality"):
		WaterSystem.set_underwater_particles_quality(_uw_particles_quality)
	_refresh_control_labels()


func _get_underwater_particles_quality_name() -> String:
	if WaterSystem and WaterSystem.has_method("get_underwater_particles_quality_name"):
		return WaterSystem.get_underwater_particles_quality_name()
	match _uw_particles_quality:
		0:
			return "Off"
		1:
			return "Low"
		2:
			return "Medium"
		3:
			return "High"
	return "Unknown"


func _toggle_wireframe_debug() -> void:
	_wireframe_enabled = not _wireframe_enabled
	get_viewport().debug_draw = Viewport.DEBUG_DRAW_WIREFRAME if _wireframe_enabled else Viewport.DEBUG_DRAW_DISABLED
	_refresh_control_labels()


func _get_ocean_material() -> ShaderMaterial:
	if WaterSystem == null or not WaterSystem.is_initialized():
		return null
	var ocean_mesh: OceanMesh = WaterSystem.get_ocean_mesh()
	if ocean_mesh == null:
		return null
	return ocean_mesh.get_material()


func _get_surface_refraction_strength() -> float:
	if _surface_refraction_layer == null:
		return 0.0
	if not _surface_refraction_enabled and _surface_refraction_debug_mode == 0:
		return 0.0
	return float(_surface_refraction_layer.get("refraction_strength"))


func _get_waterline_perf_snapshot() -> Dictionary:
	if _waterline_stack == null:
		return {}
	var effect := _waterline_stack.get_waterline_effect()
	if effect == null or not effect.has_method("get_underwater_perf_snapshot"):
		return {}
	var snapshot: Variant = effect.call("get_underwater_perf_snapshot")
	if snapshot is Dictionary:
		return snapshot
	return {}


func _get_waterline_capture_snapshot() -> Dictionary:
	if _waterline_stack == null:
		return {}
	var capture := _waterline_stack.get_prewater_capture()
	if capture == null:
		return {}
	var snapshot := {}
	if capture.has_method("get_perf_snapshot"):
		var raw_snapshot: Variant = capture.call("get_perf_snapshot")
		if raw_snapshot is Dictionary:
			snapshot = (raw_snapshot as Dictionary).duplicate()
	snapshot["capture_active"] = capture.is_capture_active()
	snapshot["has_capture"] = capture.has_capture()
	return snapshot


func _get_waterline_source_status(snapshot: Dictionary, capture_snapshot: Dictionary = {}) -> String:
	if not _waterline_enabled and _waterline_debug_mode == 0:
		return "inactive"
	if bool(snapshot.get("external_source_valid", false)):
		return "ok"
	if _waterline_inspection_active and _waterline_inspection_frames < 90:
		return "warming"
	if capture_snapshot.is_empty():
		return "no-capture-node"
	if not bool(capture_snapshot.get("capture_active", false)):
		return "capture-off"
	if not bool(capture_snapshot.get("has_capture", false)):
		return "capture-empty"
	if bool(capture_snapshot.get("has_capture", false)):
		return "handoff-missing"
	return "missing"


func _log_refraction_baseline_state(reason: String) -> void:
	var camera_pos := Vector3.ZERO
	var camera_rot := Vector3.ZERO
	if _camera != null:
		camera_pos = _camera.global_position
		camera_rot = _camera.global_rotation_degrees
	var weather_name := "Unknown"
	if _current_weather >= 0 and _current_weather < WEATHER_PRESETS.size():
		weather_name = str(WEATHER_PRESETS[_current_weather].get("name", "Unknown"))
	var mesh_mode := "Unknown"
	if WaterSystem and WaterSystem.is_initialized() and WaterSystem.has_method("get_mesh_mode"):
		mesh_mode = "Projected" if WaterSystem.get_mesh_mode() == 1 else "Clipmap"
	var surface_shader_label := "Boujie High" if _experimental_surface_shader_enabled else "Default"
	if WaterSystem and WaterSystem.has_method("get_surface_shader_mode_name"):
		surface_shader_label = WaterSystem.get_surface_shader_mode_name()
	var particle_status := _get_underwater_particles_status()
	var wl_perf := _get_waterline_perf_snapshot()
	var wl_capture := _get_waterline_capture_snapshot()
	var lines: Array[String] = [
		"[Ocean Lab] Refraction baseline (%s)" % reason,
		"| refraction_strength | %.3f |" % _get_surface_refraction_strength(),
		"| surface_refraction | %s |" % ("on" if _surface_refraction_enabled else "off"),
		"| surface_edge_guard | %s |" % ("on" if _surface_edge_guard_enabled else "off"),
		"| receiver_waterline | %s |" % ("on" if _waterline_enabled else "off"),
		"| waterline_debug | %d %s |" % [_waterline_debug_mode, WATERLINE_DEBUG_MODE_NAMES[_waterline_debug_mode]],
		"| surface_ssr | %s |" % ("on" if _surface_ssr_enabled else "off"),
		"| surface_shader | %s |" % surface_shader_label,
		"| boujie_full | %s |" % ("on" if _is_boujie_full_preset_active() else "off"),
		"| env_ssr | %s |" % ("on" if _environment_ssr_enabled else "off"),
		"| underwater_effect | %s |" % ("on" if _underwater_effect_enabled else "off"),
		"| underwater_features | fog=%s snell=%s wobble=%s particles=%s caustics=%s |" % [
			"on" if _uw_absorption_enabled else "off",
			"on" if _uw_snell_enabled else "off",
			"on" if _uw_wobble_effect_enabled else "off",
			"on" if _uw_particles_enabled else "off",
			"on" if _uw_caustics_enabled else "off",
		],
		"| underwater_particles | enabled=%s emitting=%s quality=%s count=%d |" % [
			str(particle_status.get("enabled", _uw_particles_enabled)),
			str(particle_status.get("emitting", false)),
			str(particle_status.get("quality_name", _get_underwater_particles_quality_name())),
			int(particle_status.get("particle_count", _uw_particle_count)),
		],
		"| wetness | %s |" % ("on" if _wet_compositor_enabled else "off"),
		"| debug_mode | %d %s |" % [_debug_mode, DEBUG_MODE_NAMES[_debug_mode]],
		"| underwater_debug | %d %s |" % [_underwater_debug_mode, UW_DEBUG_MODE_NAMES[_underwater_debug_mode]],
		"| camera_pos | %s |" % str(camera_pos),
		"| camera_rot_deg | %s |" % str(camera_rot),
		"| mesh | %s |" % mesh_mode,
		"| weather | %s |" % weather_name,
		"| test_objects | %d |" % _test_objects.size(),
		"| playground | %s |" % _shore_search_status,
	]
	if not wl_perf.is_empty():
		lines.append("| wl_source_status | %s |" % _get_waterline_source_status(wl_perf, wl_capture))
		lines.append("| wl_external_source_valid | %s |" % str(wl_perf.get("external_source_valid", false)))
		lines.append("| wl_source_size | %s |" % str(wl_perf.get("source_size", Vector2i.ZERO)))
		lines.append("| wl_occlusion_depth_valid | %s |" % str(wl_perf.get("external_occlusion_depth_valid", false)))
		lines.append("| wl_occlusion_size | %s |" % str(wl_perf.get("occlusion_size", Vector2i.ZERO)))
	if not wl_capture.is_empty():
		lines.append("| wl_capture_active | %s |" % str(wl_capture.get("capture_active", false)))
		lines.append("| wl_capture_has_capture | %s |" % str(wl_capture.get("has_capture", false)))
		lines.append("| wl_capture_source_size | %s |" % str(wl_capture.get("source_size", Vector2i.ZERO)))
	if _surface_refraction_layer != null:
		var surf_snapshot: Dictionary = _surface_refraction_layer.call("get_runtime_status")
		lines.append("| surface_refract_source_valid | %s |" % str(surf_snapshot.get("source_valid", false)))
		lines.append("| surface_refract_depth_valid | %s |" % str(surf_snapshot.get("source_depth_valid", false)))
		lines.append("| surface_refract_source_fresh | %s |" % str(surf_snapshot.get("source_fresh", false)))
		lines.append("| surface_refract_source_size | %s |" % str(surf_snapshot.get("source_size", Vector2i.ZERO)))
		lines.append("| surface_refract_source_scale | %.2f |" % float(surf_snapshot.get("source_resolution_scale", 0.0)))
		lines.append("| surface_refract_frame_age | %s |" % str(surf_snapshot.get("capture_frame_age", -1)))
		lines.append("| surface_refract_frame_tolerance | %s |" % str(surf_snapshot.get("source_frame_tolerance", -1)))
		lines.append("| surface_refract_source_mode | %s |" % str(surf_snapshot.get("source_mode", "unknown")))
		lines.append("| surface_refract_controlled_layer | 0x%X |" % CONTROLLED_REFRACTION_RECEIVER_LAYER_MASK)
		lines.append("| surface_refract_compositor_enabled | %s |" % str(surf_snapshot.get("compositor_enabled", false)))
		lines.append("| surface_refract_overlay_active | %s |" % str(surf_snapshot.get("overlay_active", false)))
		lines.append("| surface_refract_dispatch_size | %s |" % str(surf_snapshot.get("dispatch_size", Vector2i.ZERO)))
		lines.append("| surface_refract_frame_source_render | %s |" % str(surf_snapshot.get("controlled_source_render_frame", -1)))
		lines.append("| surface_refract_frame_source_copy | %s |" % str(surf_snapshot.get("controlled_source_copy_frame", -1)))
		lines.append("| surface_refract_frame_final | %s |" % str(surf_snapshot.get("surface_refraction_frame", -1)))
		lines.append("| surface_refract_timing_same_frame | %s |" % str(surf_snapshot.get("controlled_total_same_timing_frame", false)))
		lines.append("| surface_refract_source_render_scope | %s |" % str(surf_snapshot.get("controlled_source_render_timing_scope", "unavailable")))
		lines.append("| surface_refract_source_render_marker_scope | %s |" % str(surf_snapshot.get("controlled_source_render_timing_marker_scope", "")))
		lines.append("| surface_refract_source_render_marker_begin | %s |" % str(surf_snapshot.get("controlled_source_render_timing_marker_begin", "")))
		lines.append("| surface_refract_source_render_marker_end | %s |" % str(surf_snapshot.get("controlled_source_render_timing_marker_end", "")))
		lines.append("| surface_refract_source_copy_marker_scope | %s |" % str(surf_snapshot.get("controlled_source_copy_timing_marker_scope", "")))
		lines.append("| surface_refract_source_copy_marker_begin | %s |" % str(surf_snapshot.get("controlled_source_copy_timing_marker_begin", "")))
		lines.append("| surface_refract_source_copy_marker_end | %s |" % str(surf_snapshot.get("controlled_source_copy_timing_marker_end", "")))
		lines.append("| surface_refract_source_render_available | %s |" % str(surf_snapshot.get("controlled_source_render_timing_available", false)))
		lines.append("| surface_refract_source_render_valid | %s |" % str(surf_snapshot.get("controlled_source_render_timing_valid", false)))
		lines.append("| surface_refract_source_copy_available | %s |" % str(surf_snapshot.get("controlled_source_copy_timing_available", false)))
		lines.append("| surface_refract_source_copy_valid | %s |" % str(surf_snapshot.get("controlled_source_copy_timing_valid", false)))
		lines.append("| surface_refract_final_available | %s |" % str(surf_snapshot.get("surface_refraction_timing_available", false)))
		lines.append("| surface_refract_final_valid | %s |" % str(surf_snapshot.get("surface_refraction_timing_valid", false)))
		lines.append("| surface_refract_total_available | %s |" % str(surf_snapshot.get("controlled_total_refraction_timing_available", false)))
		lines.append("| surface_refract_total_valid | %s |" % str(surf_snapshot.get("controlled_total_refraction_timing_valid", false)))
		lines.append("| surface_refract_total_reason | %s |" % str(surf_snapshot.get("controlled_total_refraction_unavailable_reason", "unknown")))
		lines.append("| surface_refract_ms | %s |" % (
			"%.3f" % float(surf_snapshot.get("surface_refraction_ms", 0.0))
			if bool(surf_snapshot.get("surface_refraction_timing_valid", false))
			else "invalid"
		))
		lines.append("| surface_refract_source_copy_ms | %s |" % (
			"%.3f" % float(surf_snapshot.get("controlled_source_copy_ms", 0.0))
			if bool(surf_snapshot.get("controlled_source_copy_timing_valid", false))
			else "invalid"
		))
		lines.append("| surface_refract_copy_surface_ms | %s |" % (
			"%.3f" % float(surf_snapshot.get("controlled_copy_surface_ms", 0.0))
			if bool(surf_snapshot.get("controlled_copy_surface_timing_valid", false))
			else "invalid"
		))
		lines.append("| surface_refract_total_ms | %s |" % (
			"%.3f" % float(surf_snapshot.get("controlled_total_refraction_ms", 0.0))
			if bool(surf_snapshot.get("controlled_total_refraction_timing_valid", false))
			else str(surf_snapshot.get("controlled_total_refraction_unavailable_reason", "unavailable"))
		))
		var source_render_label := "unavailable"
		if bool(surf_snapshot.get("controlled_source_render_timing_valid", false)):
			source_render_label = "%.3f" % float(surf_snapshot.get("controlled_source_render_ms", 0.0))
		lines.append("| surface_refract_source_render_ms | %s |" % source_render_label)
		lines.append("| surface_refract_mask_mode | %s |" % str(surf_snapshot.get("mask_mode", "off")))
		lines.append("| surface_refract_reject_reason | %s |" % str(surf_snapshot.get("reject_reason", "none")))
		lines.append("| surface_refract_debug | %d %s |" % [_surface_refraction_debug_mode, SURFACE_REFRACTION_DEBUG_MODE_NAMES[_surface_refraction_debug_mode]])
		lines.append("| surface_refract_mesh_mode | %s |" % str(surf_snapshot.get("mesh_mode", -1)))
	var baseline_issues := _get_surface_baseline_issues()
	Log.info("water", "[Ocean Lab] surface_baseline_check=%s%s" % [
		"ok" if baseline_issues.is_empty() else "needs_attention",
		"" if baseline_issues.is_empty() else " issues=%s" % ", ".join(baseline_issues),
	])
	Log.info("water", "\n".join(lines))


func _get_surface_baseline_issues() -> Array[String]:
	var issues: Array[String] = []
	var preset: Dictionary = WEATHER_PRESETS[_current_weather] if _current_weather >= 0 and _current_weather < WEATHER_PRESETS.size() else {}
	if str(preset.get("name", "")) != "Calm":
		issues.append("weather_not_calm")
	if _surface_refraction_enabled:
		issues.append("surface_refraction_on")
	if _surface_refraction_debug_mode != 0:
		issues.append("surface_refraction_debug")
	if _surface_ssr_enabled:
		issues.append("surface_ssr_on")
	if _experimental_surface_shader_enabled:
		issues.append("experimental_surface_shader_on")
	if _underwater_effect_enabled or _underwater_debug_mode != 0:
		issues.append("underwater_on")
	if _waterline_enabled or _waterline_debug_mode != 0:
		issues.append("receiver_waterline_on")
	if _wet_compositor_enabled or _wet_debug_mode != 0:
		issues.append("live_wetness_on")
	return issues


func _get_water_state() -> WaterSurfaceState:
	if WaterSystem != null and WaterSystem.has_method("get_water_surface_state"):
		return WaterSystem.get_water_surface_state()
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


func _add_box(
		node_name: String,
		size: Vector3,
		pos: Vector3,
		mat: Material,
		waterline_receiver: bool = false,
		refraction_receiver: bool = false
) -> MeshInstance3D:
	var inst := MeshInstance3D.new()
	inst.name = node_name
	var mesh := BoxMesh.new()
	mesh.size = size
	inst.mesh = mesh
	inst.material_override = mat
	if waterline_receiver:
		inst.layers = inst.layers | WATERLINE_RECEIVER_LAYER_MASK
	if refraction_receiver:
		inst.layers = inst.layers | CONTROLLED_REFRACTION_RECEIVER_LAYER_MASK
	add_child(inst)
	inst.global_position = pos
	return inst


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
