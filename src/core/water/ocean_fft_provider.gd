## OceanFFTProvider - Ocean-only FFT water provider.
## Owned by WaterSystem. Manages ocean mesh, shore dampening, FFT compute
## pipeline, sea spray, and ocean fallback queries.
class_name OceanFFTProvider
extends Node

const CS := preload("res://src/core/coordinate_system.gd")
const OceanSprayScript := preload("res://src/core/water/ocean_spray.gd")
const UnderwaterParticulatesScript := preload("res://src/core/water/underwater_particulates.gd")
const WaterBodyRegistryScript := preload("res://src/core/water/water_body_registry.gd")
const WaterInteractionSimScript := preload("res://src/core/water/water_interaction_sim.gd")

const WATER_BODY_ATLAS_RESOLUTION := 128
const WATER_BODY_ATLAS_EXTENT_M := 512.0
# Re-center threshold. The rebuild is 128x128 CPU registry samples on the main
# thread; at the old 2m threshold it re-ran near-continuously while flying.
# 32m keeps the camera within 6% of the atlas extent from center — consumers
# (waterline/underwater, <=140m range) always stay well inside the window.
const WATER_BODY_ATLAS_UPDATE_MOVE_M := 32.0

# Project settings paths
const SETTING_ENABLED := "ocean/enabled"
const SETTING_SEA_LEVEL := "ocean/sea_level"
const SETTING_RADIUS := "ocean/radius"
const SETTING_QUALITY := "ocean/quality"
# Mesh mode: 0 = CLIPMAP (11-ring concentric mesh, follows camera),
#            1 = PROJECTED (screen-space N×N grid, vertex-shader unproject).
# FFT quality only; flat always uses CLIPMAP.
const SETTING_MESH_MODE := "ocean/mesh_mode"
const SHORE_WAVE_SPATIAL_FREQUENCY := 0.1
const SHORE_WAVE_REFERENCE_DEPTH := 20.0
const GRAVITY := 9.81

## Get prebaked shore mask path from SettingsManager
func _get_shore_mask_path() -> String:
	return SettingsManager.get_ocean_path().path_join("shore_mask.png")

# Ocean configuration
@export var ocean_radius: float = 50000.0  # 50km clipmap radius
@export var shore_fade_distance: float = 50.0  # Meters to fade waves near shore
@export var shore_mask_resolution: int = 4096
@export var use_prebaked_shore_mask: bool = true

# Sea level
@export var sea_level: float = 0.0
@export var water_body_atlas_enabled: bool = false

# Quality settings
@export_group("Quality Settings")
## Water quality: -1 = auto, 0 = flat, any positive legacy value = high (FFT)
@export_range(-1, 1) var water_quality: int = -1
## Mesh mode: 0 = CLIPMAP (default), 1 = PROJECTED grid (FFT only).
## Projected is Sea of Thieves / Wicked Engine canonical — single flat grid
## + vertex-shader unproject, zero T-junctions, uniform screen density.
@export_range(0, 1) var water_mesh_mode: int = 0

# FFT settings
@export_group("FFT Settings")
## FFT map resolution (power of 2: 128, 256, 512)
@export_enum("128:128", "256:256", "512:512") var fft_map_size: int = 256
## FFT update rate (Hz) — 0 = every frame
@export_range(0, 60) var fft_updates_per_second: float = 50.0

# Wave parameters (exposed for UI control)
@export_group("Wave Settings")
@export var wave_scale: float = 1.0
## Synchronous GPU wave readback matches the visual FFT exactly but stalls the
## render device. Keep disabled for gameplay; CPU queries use the spectrum
## evaluator plus the same analytical shore wave as the mesh.
@export var use_gpu_wave_readback: bool = false

@export_group("Sea Spray")
@export var sea_spray_enabled: bool = true
## 0 = Off, 1 = Low, 2 = Medium, 3 = High.
@export_range(0, 3) var sea_spray_quality: int = 2

@export_group("Underwater Particles")
@export var underwater_particles_enabled: bool = false
## 0 = Off, 1 = Low, 2 = Medium, 3 = High.
@export_range(0, 3) var underwater_particles_quality: int = 2
@export_range(0.0, 2.0) var underwater_particles_opacity: float = 1.0
@export_range(0, 8192) var underwater_particles_count: int = 4096
@export_range(0.25, 4.0) var underwater_particles_size_scale: float = 4.0
@export_range(0.0, 4.0) var underwater_particles_speed_scale: float = 1.5

# System state
var _system_initialized: bool = false
var _system_enabled: bool = false

# Weather integration — last applied values (avoid redundant FFT spectrum regen)
var _weather_last_wind: float = -1.0
var _weather_last_storm_dir: Vector3 = Vector3.ZERO
var _weather_last_wind_t: float = 0.0
var _weather_last_wind_dir_xz: Vector2 = Vector2(1.0, 1.0).normalized()
var _current_ocean_wind_speed_mps: float = 2.0

# Internal state
var _ocean_mesh: OceanMesh = null
var _ocean_spray: OceanSpray = null
var _underwater_particulates: UnderwaterParticulates = null
var _water_interaction_sim: WaterInteractionSim = null
var _shore_mask: ShoreMaskGenerator = null
var _water_body_registry: RefCounted = WaterBodyRegistryScript.new()
var _water_interactors: Array[Node] = []
var _water_interaction_renderers: Array[Node] = []
var _world_water_provider: RefCounted = null
var _water_interaction_debug_enabled: bool = false
var _water_interaction_sync_initialized: bool = false
var _water_interaction_last_texture: Texture2D = null
var _water_dynamic_flow_last_texture: Texture2D = null
var _water_interaction_last_bounds: Vector4 = Vector4.ZERO
var _water_interaction_last_enabled: bool = false
var _water_dynamic_flow_last_enabled: bool = false
var _water_interaction_last_debug: bool = false
var _water_interaction_last_body_atlas_texture: Texture2D = null
var _water_interaction_last_body_atlas_bounds: Vector4 = Vector4.ZERO
var _water_interaction_last_body_atlas_available: bool = false
var _water_interaction_last_surface_height: float = NAN
var _water_interaction_renderer_sync_count: int = 0
var _local_flow_obstacles: Array[Dictionary] = []
var _terrain: Terrain3D = null
var _camera: Camera3D = null
var _enabled: bool = true
var _time: float = 0.0
var _auto_find_camera: bool = true
var _current_map_scales: PackedVector4Array = PackedVector4Array()
var _active_shore_mask_texture: Texture2D = null
var _active_shore_mask_rd: RID = RID()
var _active_shore_mask_image: Image = null
var _active_shore_mask_bounds: Rect2 = Rect2(-8000.0, -8000.0, 16000.0, 16000.0)
var _active_shore_fade_distance: float = 50.0
var _water_body_atlas_image: Image = null
var _water_body_atlas_texture: ImageTexture = null
var _water_body_atlas_rd: RID = RID()
var _water_body_atlas_bounds: Rect2 = Rect2()
var _water_body_atlas_center_xz: Vector2 = Vector2.INF
var _water_body_atlas_frame: int = -1
var _water_body_atlas_last_rebuild_usec: int = 0

## Per-frame cache for camera-position registry samples (see get_water_surface_state).
var _camera_sample_frame: int = -1
var _camera_sample_coverage: float = 0.0
var _camera_sample_body_id: StringName = WaterSurfaceState.WATER_BODY_NONE
var _camera_sample_level: float = NAN
var _water_body_atlas_total_rebuild_usec: int = 0
var _water_body_atlas_rebuild_count: int = 0
var _current_shore_wave_amplitude: float = 0.18
var _current_shore_wave_frequency: float = SHORE_WAVE_SPATIAL_FREQUENCY
var _current_shore_wave_speed: float = 0.4
var _current_shore_wave_steepness: float = 0.58
var _surface_shader_mode: int = OceanMesh.SurfaceShaderMode.DEFAULT

# FFT pipeline
var _wave_generator: WaveGenerator = null
var _cascade_parameters: Array[WaveCascadeParameters] = []
var _displacement_maps := Texture2DArrayRD.new()
var _normal_maps := Texture2DArrayRD.new()
var _fft_time: float = 0.0
var _fft_next_update: float = 0.0
var _rng := RandomNumberGenerator.new()

# CPU-side wave evaluation (synced with FFT spectrum)
var _physics_evaluator: OceanPhysicsEvaluator = null

# GPU readback for buoyancy (exact match with visual waves).
# Per-cascade raw RGBA16F data — one PackedByteArray per wave cascade,
# read every frame in `_process`. Sampling code iterates the array and
# sums the per-cascade contributions using the same per-cascade
# `tile_length` and `displacement_scale` the vertex shader uses.
# `_displacement_cpu` is retained as a back-compat alias pointing at
# cascade 0's buffer so the "readback ready?" size check in the older
# sampler paths still works.
var _displacement_cpu: PackedByteArray  # Cascade 0 alias (ready-flag read)
var _displacement_cpu_per_cascade: Array[PackedByteArray] = []
var _displacement_size: int = 0  # Map dimension (e.g., 256)
var _displacement_tile: Vector2 = Vector2.ZERO  # Tile length from cascade 0
var _readback_frame: int = 0  # Last frame we did a readback

# Cached directional light for SSS sun-backlight uniform. Scanned lazily so we
# don't walk the scene tree every frame. Cleared when the node disappears.
var _cached_directional_lights: Array[DirectionalLight3D] = []
var _last_sun_scan_frame: int = -1

# Signals
signal ocean_initialized()


static func _normalize_water_quality_id(quality: int) -> int:
	if quality == 0:
		return 0
	if quality > 0:
		return 1
	return -1


func _ready() -> void:
	_register_project_settings()

	_system_enabled = ProjectSettings.get_setting(SETTING_ENABLED, false)
	if not _system_enabled:
		Log.info("water", "OceanFFTProvider: System disabled via project settings")
		set_process(false)
		set_physics_process(false)
		return

	_ocean_mesh = OceanMesh.new()
	_ocean_mesh.name = "OceanMesh"
	add_child(_ocean_mesh)

	_shore_mask = ShoreMaskGenerator.new()
	_shore_mask.name = "ShoreMaskGenerator"
	add_child(_shore_mask)

	call_deferred("_deferred_init")


func _register_project_settings() -> void:
	if not ProjectSettings.has_setting(SETTING_ENABLED):
		ProjectSettings.set_setting(SETTING_ENABLED, false)
		ProjectSettings.set_initial_value(SETTING_ENABLED, false)
		ProjectSettings.add_property_info({
			"name": SETTING_ENABLED,
			"type": TYPE_BOOL,
			"hint_string": "Enable ocean water system globally"
		})

	if not ProjectSettings.has_setting(SETTING_SEA_LEVEL):
		ProjectSettings.set_setting(SETTING_SEA_LEVEL, 0.0)
		ProjectSettings.set_initial_value(SETTING_SEA_LEVEL, 0.0)
		ProjectSettings.add_property_info({
			"name": SETTING_SEA_LEVEL,
			"type": TYPE_FLOAT,
			"hint_string": "Sea level height in world units"
		})

	if not ProjectSettings.has_setting(SETTING_RADIUS):
		ProjectSettings.set_setting(SETTING_RADIUS, 25000.0)
		ProjectSettings.set_initial_value(SETTING_RADIUS, 25000.0)
		ProjectSettings.add_property_info({
			"name": SETTING_RADIUS,
			"type": TYPE_FLOAT,
			"hint_string": "Ocean clipmap radius in meters"
		})

	if not ProjectSettings.has_setting(SETTING_QUALITY):
		ProjectSettings.set_setting(SETTING_QUALITY, -1)
		ProjectSettings.set_initial_value(SETTING_QUALITY, -1)
		ProjectSettings.add_property_info({
			"name": SETTING_QUALITY,
			"type": TYPE_INT,
			"hint": PROPERTY_HINT_RANGE,
			"hint_string": "-1,1,1"
		})

	if not ProjectSettings.has_setting(SETTING_MESH_MODE):
		ProjectSettings.set_setting(SETTING_MESH_MODE, 0)
		ProjectSettings.set_initial_value(SETTING_MESH_MODE, 0)
		ProjectSettings.add_property_info({
			"name": SETTING_MESH_MODE,
			"type": TYPE_INT,
			"hint": PROPERTY_HINT_ENUM,
			"hint_string": "Clipmap,Projected"
		})


func _deferred_init() -> void:
	if not _system_enabled or _ocean_mesh == null:
		return

	sea_level = ProjectSettings.get_setting(SETTING_SEA_LEVEL, 0.0)
	ocean_radius = ProjectSettings.get_setting(SETTING_RADIUS, 8000.0)
	water_quality = _normalize_water_quality_id(ProjectSettings.get_setting(SETTING_QUALITY, -1))
	water_mesh_mode = ProjectSettings.get_setting(SETTING_MESH_MODE, 0)

	HardwareDetection.detect()
	_find_terrain()

	_ocean_mesh.initialize(ocean_radius, water_quality, water_mesh_mode)
	_ocean_mesh.set_surface_shader_mode(_surface_shader_mode)
	_update_shader_parameters()
	_setup_spray_layer()
	# Shore mask — vertex dampening only (CREST OceanDepthCache pattern).
	# Fragment-side shore visuals remain depth-driven (water_thickness).
	_load_shore_mask()

	# Initialize FFT pipeline if HIGH quality
	if _ocean_mesh.get_quality() == OceanMesh.QualityMode.HIGH:
		_init_fft_pipeline()

	# Apply calm defaults to shader uniforms (weather system will override when active)
	reset_weather()

	_system_initialized = true
	ocean_initialized.emit()

	Log.info("water", "OceanFFTProvider: Initialized - sea level: %.1f, radius: %.0fm, mode: %s" % [
		sea_level, ocean_radius, get_water_quality_name()])


func _set_active_shore_mask(texture: Texture2D, bounds: Rect2, fade_distance: float, image: Image = null) -> void:
	_active_shore_mask_texture = texture
	_active_shore_mask_rd = RID()
	_active_shore_mask_image = image
	_active_shore_mask_bounds = bounds
	_active_shore_fade_distance = fade_distance

	if texture == null:
		return
	var texture_rid := texture.get_rid()
	if texture_rid.is_valid():
		_active_shore_mask_rd = RenderingServer.texture_get_rd_texture(texture_rid)
	if _ocean_mesh:
		_ocean_mesh.set_shore_mask(texture, bounds, fade_distance)
	if _ocean_spray:
		_ocean_spray.set_shore_mask(texture, bounds)


func _setup_water_interaction_layer() -> void:
	if _water_interaction_sim != null:
		return
	_water_interaction_sim = WaterInteractionSimScript.new()
	_water_interaction_sim.name = "WaterInteractionSim"
	add_child(_water_interaction_sim)
	_sync_water_interaction_to_renderers(true)


func _dispose_water_interaction_layer() -> void:
	if _water_interaction_sim == null:
		return
	var sim := _water_interaction_sim
	_water_interaction_sim = null
	if sim.get_parent() == self:
		remove_child(sim)
	if sim.has_method("shutdown"):
		sim.call("shutdown")
	sim.queue_free()
	_water_interactors.clear()
	_sync_water_interaction_to_renderers(true)


func _update_water_interaction_layer(delta: float) -> void:
	update_local_water_interactions(delta)


func update_local_water_interactions(delta: float, center_world: Vector3 = Vector3.INF) -> void:
	if _water_interaction_sim == null:
		_setup_water_interaction_layer()
	if _water_interaction_sim == null:
		return
	var center := center_world
	if center == Vector3.INF and _camera != null and is_instance_valid(_camera):
		center = _camera.global_position
	elif center == Vector3.INF:
		center = Vector3(0.0, sea_level, 0.0)
	if water_body_atlas_enabled and _water_body_registry.has_sources():
		_update_water_body_atlas(center)
	else:
		_clear_water_body_atlas()
	_water_interaction_sim.configure_water_body_mask(_water_body_atlas_rd, get_water_body_atlas_bounds(), has_water_body_atlas())
	_water_interaction_sim.update_sim(delta, center)
	_sync_water_interaction_to_renderers()


func _sync_water_interaction_to_renderers(force: bool = false) -> void:
	var texture: Texture2D = null
	var dynamic_flow_texture: Texture2D = null
	var bounds := Vector4.ZERO
	var active := false
	var dynamic_flow_active := false
	if _water_interaction_sim == null:
		active = false
	else:
		var stats := _water_interaction_sim.get_stats()
		texture = _water_interaction_sim.get_texture()
		dynamic_flow_texture = _water_interaction_sim.get_flow_texture()
		bounds = _water_interaction_sim.get_bounds()
		active = bool(stats.get("enabled", false)) and texture != null
		dynamic_flow_active = active and dynamic_flow_texture != null
	var body_atlas_texture := get_water_body_atlas_texture()
	var body_atlas_bounds := get_water_body_atlas_bounds()
	var body_atlas_available := has_water_body_atlas()
	if not force \
			and _water_interaction_sync_initialized \
			and texture == _water_interaction_last_texture \
			and dynamic_flow_texture == _water_dynamic_flow_last_texture \
			and bounds == _water_interaction_last_bounds \
			and active == _water_interaction_last_enabled \
			and dynamic_flow_active == _water_dynamic_flow_last_enabled \
			and _water_interaction_debug_enabled == _water_interaction_last_debug \
			and body_atlas_texture == _water_interaction_last_body_atlas_texture \
			and body_atlas_bounds == _water_interaction_last_body_atlas_bounds \
			and body_atlas_available == _water_interaction_last_body_atlas_available \
			and sea_level == _water_interaction_last_surface_height:
		return
	_water_interaction_sync_initialized = true
	_water_interaction_last_texture = texture
	_water_dynamic_flow_last_texture = dynamic_flow_texture
	_water_interaction_last_bounds = bounds
	_water_interaction_last_enabled = active
	_water_dynamic_flow_last_enabled = dynamic_flow_active
	_water_interaction_last_debug = _water_interaction_debug_enabled
	_water_interaction_last_body_atlas_texture = body_atlas_texture
	_water_interaction_last_body_atlas_bounds = body_atlas_bounds
	_water_interaction_last_body_atlas_available = body_atlas_available
	_water_interaction_last_surface_height = sea_level
	if _ocean_mesh != null:
		_ocean_mesh.set_water_interaction_texture(texture, bounds, active)
		if _ocean_mesh.has_method("set_water_interaction_surface_height"):
			_ocean_mesh.call("set_water_interaction_surface_height", sea_level)
		if _ocean_mesh.has_method("set_water_body_atlas_texture"):
			_ocean_mesh.call(
				"set_water_body_atlas_texture",
				body_atlas_texture,
				body_atlas_bounds,
				body_atlas_available
			)
		_ocean_mesh.set_water_interaction_debug_enabled(_water_interaction_debug_enabled)
	_sync_registered_water_interaction_renderers(
		texture,
		bounds,
		active,
		_water_interaction_debug_enabled,
		body_atlas_texture,
		body_atlas_bounds,
		body_atlas_available,
		dynamic_flow_texture,
		bounds,
		dynamic_flow_active
	)


func _sync_registered_water_interaction_renderers(
	texture: Texture2D,
	bounds: Vector4,
	active: bool,
	debug_enabled: bool,
	body_atlas_texture: Texture2D,
	body_atlas_bounds: Vector4,
	body_atlas_available: bool,
	dynamic_flow_texture: Texture2D,
	dynamic_flow_bounds: Vector4,
	dynamic_flow_active: bool
) -> void:
	for i in range(_water_interaction_renderers.size() - 1, -1, -1):
		var renderer := _water_interaction_renderers[i]
		if not is_instance_valid(renderer):
			_water_interaction_renderers.remove_at(i)
			continue
		if renderer.has_method("sync_water_interaction_texture"):
			renderer.call(
				"sync_water_interaction_texture",
				texture,
				bounds,
				active,
				debug_enabled,
				body_atlas_texture,
				body_atlas_bounds,
				body_atlas_available,
				dynamic_flow_texture,
				dynamic_flow_bounds,
				dynamic_flow_active
			)
			_water_interaction_renderer_sync_count += 1


func _load_shore_mask() -> void:
	var shore_mask_loaded := false

	# Try prebaked shore mask first
	var shore_mask_path := _get_shore_mask_path()
	if use_prebaked_shore_mask and FileAccess.file_exists(shore_mask_path):
		var prebaked := ShoreMaskBaker.load_prebaked(shore_mask_path)
		if not prebaked.is_empty():
			var tex: Texture2D = prebaked.texture
			var bounds: Rect2 = prebaked.bounds
			var fade_distance: float = float(prebaked.get("fade_distance", shore_fade_distance))
			var image := prebaked.get("image", null) as Image
			_set_active_shore_mask(tex, bounds, fade_distance, image)
			shore_mask_loaded = true
			Log.info("water", "OceanFFTProvider: Using prebaked shore mask from %s" % shore_mask_path)

	if not shore_mask_loaded:
		Log.warn("water", "OceanFFTProvider: No prebaked shore mask found — run 'Rebake Shore Mask' in prebake UI. Waves will not dampen at shore.")


func _process(delta: float) -> void:
	if not _system_enabled or not _enabled:
		return
	if _ocean_mesh == null:
		return

	_time = Time.get_ticks_msec() / 1000.0
	_push_ocean_time_uniform()

	# Auto-find camera
	if not _camera and _auto_find_camera:
		_camera = _find_active_camera()

	# Update ocean mesh position to follow camera
	if _camera:
		var cam_pos := _camera.global_position
		var new_pos := Vector3(cam_pos.x, sea_level, cam_pos.z)
		_ocean_mesh.update_position(new_pos)
		if _ocean_spray:
			_ocean_spray.set_camera(_camera)
		if _underwater_particulates:
			_underwater_particulates.set_camera(_camera)
		_update_water_body_atlas(cam_pos)
	else:
		_clear_water_body_atlas()

	# Drive FFT pipeline updates (rate-limited)
	if _wave_generator and _ocean_mesh.get_quality() == OceanMesh.QualityMode.HIGH:
		_fft_time += delta
		if fft_updates_per_second == 0 or _fft_time >= _fft_next_update:
			var target_dt := 1.0 / (fft_updates_per_second + 1e-10)
			var update_dt := delta if fft_updates_per_second == 0 else target_dt + (_fft_time - _fft_next_update)
			_fft_next_update = _fft_time + target_dt
			_wave_generator.update(update_dt, _cascade_parameters)

	if _ocean_spray:
		_ocean_spray.set_fft_available(_wave_generator != null and _ocean_mesh.get_quality() == OceanMesh.QualityMode.HIGH)
		_ocean_spray.set_sea_level(sea_level)
		_ocean_spray.set_wave_scale(wave_scale)
		_ocean_spray.set_ocean_time(_time)
	if _underwater_particulates:
		_underwater_particulates.sync_from_water_state(get_water_surface_state())

	# Push sun direction to the ocean surface shader for SSS backlight.
	# Scan the scene tree at most once every 60 frames so we notice late-spawned
	# DirectionalLight3D nodes without walking the tree per frame.
	_update_sun_uniform()

	# GPU readback for buoyancy — read every cascade's displacement map
	# once per frame. Sampling only cascade 0 (swell) under-reports the
	# true visible wave height in high wind, where cascade 1 (chop)
	# contributes roughly as much amplitude as the swell. The shader
	# vertex sums ALL cascades; the CPU path must do the same or buoyant
	# bodies drift out of sync with the visible mesh.
	if use_gpu_wave_readback and _wave_generator and _displacement_size > 0:
		var frame := Engine.get_process_frames()
		if frame != _readback_frame:
			_readback_frame = frame
			_displacement_cpu_per_cascade.clear()
			for i in _cascade_parameters.size():
				_displacement_cpu_per_cascade.append(_wave_generator.read_displacement(i))
			# Back-compat alias — some callers still check the cascade-0
			# buffer for "is readback ready?".
			if _displacement_cpu_per_cascade.size() > 0:
				_displacement_cpu = _displacement_cpu_per_cascade[0]
			else:
				_displacement_cpu = PackedByteArray()


func _physics_process(delta: float) -> void:
	if not _system_enabled or not _enabled or _water_interactors.is_empty():
		return
	var state := get_water_surface_state()
	for i in range(_water_interactors.size() - 1, -1, -1):
		var interactor := _water_interactors[i]
		if not is_instance_valid(interactor):
			_water_interactors.remove_at(i)
			continue
		if not interactor.has_method("gather_impulses"):
			continue
		var impulses: Array = interactor.call("gather_impulses", delta, state)
		for impulse: Dictionary in impulses:
			emit_water_impulse(
				impulse["position"],
				float(impulse["radius_m"]),
				float(impulse["strength"]),
				impulse["kind"],
				impulse["body_id"],
				impulse.get("wake_direction", Vector2.ZERO),
				float(impulse.get("wake_length_m", 0.0))
			)
		if interactor.has_method("gather_flow_obstacles"):
			var obstacles: Array = interactor.call("gather_flow_obstacles", delta, state)
			for obstacle: Dictionary in obstacles:
				emit_water_flow_obstacle(
					obstacle["position"],
					float(obstacle["radius_m"]),
					float(obstacle.get("block_strength", 0.0)),
					float(obstacle.get("wake_strength", 0.0)),
					obstacle.get("body_id", WaterSurfaceState.WATER_BODY_NONE)
				)


func _find_active_camera() -> Camera3D:
	var viewport := get_viewport()
	if viewport:
		var cam := viewport.get_camera_3d()
		if cam:
			return cam

	var cameras := get_tree().get_nodes_in_group("camera")
	if cameras.size() > 0 and cameras[0] is Camera3D:
		return cameras[0] as Camera3D

	return _find_node_by_class(get_tree().root, "Camera3D") as Camera3D


func _find_terrain() -> void:
	var terrains := get_tree().get_nodes_in_group("terrain")
	if terrains.size() > 0 and terrains[0] is Terrain3D:
		_terrain = terrains[0] as Terrain3D
		return
	_terrain = _find_node_by_class(get_tree().root, "Terrain3D") as Terrain3D


func _find_node_by_class(node: Node, class_name_str: String) -> Node:
	if node.get_class() == class_name_str:
		return node
	for child in node.get_children():
		var result := _find_node_by_class(child, class_name_str)
		if result:
			return result
	return null


func _update_shader_parameters() -> void:
	if not _ocean_mesh:
		return
	_ocean_mesh.set_wave_scale(wave_scale)
	if _ocean_spray:
		_ocean_spray.set_wave_scale(wave_scale)
	# Push sea_level to the ocean surface shader and shared water-state readers.
	var mat: ShaderMaterial = _ocean_mesh.get_material()
	if mat:
		mat.set_shader_parameter(&"sea_level", sea_level)
		_push_surface_motion_uniforms(mat)


# ============================================================================
# FFT PIPELINE
# ============================================================================

func _init_fft_pipeline() -> void:
	_rng.set_seed(1234)

	# Create default cascade parameters (2 cascades for prototype)
	_cascade_parameters.clear()

	# Cascade 0 — Large swell (covers 250m tiles)
	var cascade_0 := WaveCascadeParameters.new()
	cascade_0.tile_length = Vector2(250, 250)
	cascade_0.displacement_scale = 0.15
	cascade_0.normal_scale = 0.8
	cascade_0.wind_speed = 3.0  # Calm lake default — weather system scales up
	cascade_0.wind_direction = 45.0
	cascade_0.fetch_length = 300.0
	cascade_0.swell = 0.8
	cascade_0.spread = 0.2
	cascade_0.detail = 1.0
	cascade_0.whitecap = 0.5
	cascade_0.foam_amount = 3.0
	cascade_0.spectrum_seed = Vector2i(_rng.randi_range(-10000, 10000), _rng.randi_range(-10000, 10000))
	cascade_0.time = 120.0
	_cascade_parameters.append(cascade_0)

	# Cascade 1 — Medium chop (covers 50m tiles)
	var cascade_1 := WaveCascadeParameters.new()
	cascade_1.tile_length = Vector2(50, 50)
	cascade_1.displacement_scale = 0.1
	cascade_1.normal_scale = 1.0
	cascade_1.wind_speed = 3.0
	cascade_1.wind_direction = 45.0
	cascade_1.fetch_length = 300.0
	cascade_1.swell = 0.5
	cascade_1.spread = 0.3
	cascade_1.detail = 1.0
	cascade_1.whitecap = 0.6
	cascade_1.foam_amount = 5.0
	cascade_1.spectrum_seed = Vector2i(_rng.randi_range(-10000, 10000), _rng.randi_range(-10000, 10000))
	cascade_1.time = 120.0 + PI
	_cascade_parameters.append(cascade_1)

	# Create wave generator
	_wave_generator = WaveGenerator.new()
	_wave_generator.map_size = fft_map_size
	_wave_generator.name = "WaveGenerator"
	add_child(_wave_generator)
	_wave_generator.init_gpu(maxi(2, _cascade_parameters.size()))

	# Connect FFT output textures to shader via global shader parameters
	_displacement_maps.texture_rd_rid = _wave_generator.descriptors[&"displacement_map"].rid
	_normal_maps.texture_rd_rid = _wave_generator.descriptors[&"normal_map"].rid

	RenderingServer.global_shader_parameter_set(&"num_cascades", _cascade_parameters.size())
	RenderingServer.global_shader_parameter_set(&"displacements", _displacement_maps)
	RenderingServer.global_shader_parameter_set(&"normals", _normal_maps)

	# Set per-cascade scale uniforms on the material
	_update_cascade_scales()

	# GPU readback setup — store tile size for UV mapping
	_displacement_size = fft_map_size
	_displacement_tile = _cascade_parameters[0].tile_length

	# Initialize CPU-side wave evaluator as fallback (hash mismatch means
	# waves won't match GPU exactly — GPU readback is preferred when available)
	_physics_evaluator = OceanPhysicsEvaluator.new()
	_physics_evaluator.init_from_cascades(_cascade_parameters, fft_map_size)

	Log.info("water", "OceanFFTProvider: FFT pipeline initialized - %d cascades, %dx%d maps" % [
		_cascade_parameters.size(), fft_map_size, fft_map_size])


func _update_cascade_scales() -> void:
	if not _ocean_mesh or not _ocean_mesh.get_material():
		return
	var map_scales: PackedVector4Array
	map_scales.resize(_cascade_parameters.size())
	for i in _cascade_parameters.size():
		var params := _cascade_parameters[i]
		var uv_scale := Vector2.ONE / params.tile_length
		map_scales[i] = Vector4(uv_scale.x, uv_scale.y, params.displacement_scale, params.normal_scale)
	_current_map_scales = map_scales
	_ocean_mesh.get_material().set_shader_parameter(&"map_scales", map_scales)
	if _ocean_spray:
		_ocean_spray.set_map_scales(map_scales)


## Debug visualization (2026-04-09). Cycles the ocean_fft.gdshader's
## `debug_mode` uniform to systematically diagnose wave-visibility /
## hole / see-through artifacts. Modes:
##   0 = Normal (production render)
##   1 = Shore factor (red→green)
##   2 = Shore discard zone (red = would discard)
##   3 = Water thickness (blue thin → red thick, magenta = sky-or-far)
##   4 = Transmittance (gray; bright = light passes through unfiltered)
##   5 = Fresnel (gray)
##   6 = Refraction validity and UV offset
##   7 = Refraction depth/guard rejection
##   8 = SSR hit mask and sampled reflection color
##   9 = Foam factor
##   10 = World normal.y (white = flat, dark = steep slope)
##   11 = SSS scatter factor (peak_mask × side_mask × sun_back, sub-surface tint)
##   12 = Refraction color delta / edge guard
##   13 = Straight source color
##   14 = Refracted candidate source color
##   15 = Refraction classifier / mask
##   16 = Godot PR #93449 depth weight
##   17 = Depth edge/disocclusion strength
##   18 = Godot PR #93449 source preview
##   19 = Final refraction sample weight
##   20 = Source Blend before absorption/Fresnel/SSR
func set_debug_mode(mode: int) -> void:
	if not _ocean_mesh:
		return
	var mat: ShaderMaterial = _ocean_mesh.get_material()
	if not mat:
		return
	mat.set_shader_parameter("debug_mode", clampi(mode, 0, 20))


## Push directional-light state to the ocean shader: the dominant light's
## world-space forward direction for the SSS backlight term (sun by day, moon
## by night), and the summed light_color × light_energy as `scene_light_color`
## so the water's unlit optical constants follow the day/night cycle. Scans the
## scene tree lazily (at most once per 60 frames) and pushes every frame while
## lights are known — energies and rotations follow the day/night cycle in
## real time, so caching the nodes alone isn't enough.
func _update_sun_uniform() -> void:
	if not _ocean_mesh:
		return
	var mat: ShaderMaterial = _ocean_mesh.get_material()
	if not mat:
		return

	var frame := Engine.get_process_frames()
	var cache_valid := not _cached_directional_lights.is_empty()
	for light in _cached_directional_lights:
		if not is_instance_valid(light) or not light.is_inside_tree():
			cache_valid = false
			break
	if not cache_valid and frame - _last_sun_scan_frame >= 60:
		_last_sun_scan_frame = frame
		_cached_directional_lights.clear()
		var tree := get_tree()
		if tree:
			_collect_directional_lights(tree.root, _cached_directional_lights)

	var incident := Color.BLACK
	var dominant: DirectionalLight3D = null
	var dominant_energy := -1.0
	for light in _cached_directional_lights:
		if not is_instance_valid(light) or not light.is_inside_tree() or not light.visible:
			continue
		incident += light.light_color * light.light_energy
		if light.light_energy > dominant_energy:
			dominant_energy = light.light_energy
			dominant = light

	if dominant:
		# DirectionalLight3D forward = -basis.z (points FROM light TO world).
		mat.set_shader_parameter("sun_dir_world", (-dominant.global_basis.z).normalized())
		# Clamp to 1 per channel: full daylight keeps the calibrated look,
		# only darkness scales the water optics down.
		mat.set_shader_parameter("scene_light_color", Vector3(
			minf(incident.r, 1.0), minf(incident.g, 1.0), minf(incident.b, 1.0)))
	# No directional light found (sky disabled, bare test scene): leave the
	# shader defaults (full daylight) instead of pushing black.


func _collect_directional_lights(node: Node, out: Array[DirectionalLight3D]) -> void:
	var light := node as DirectionalLight3D
	if light:
		out.append(light)
	for child in node.get_children():
		_collect_directional_lights(child, out)


func _push_ocean_time_uniform() -> void:
	if not _ocean_mesh:
		return
	var mat: ShaderMaterial = _ocean_mesh.get_material()
	if not mat:
		return
	mat.set_shader_parameter("ocean_time", _time)
	if _ocean_spray:
		_ocean_spray.set_ocean_time(_time)


func _push_surface_motion_uniforms(mat: ShaderMaterial = null) -> void:
	if mat == null:
		if not _ocean_mesh:
			return
		mat = _ocean_mesh.get_material()
	if mat == null:
		return
	var wind_dir := _weather_last_wind_dir_xz
	if wind_dir.length_squared() < 0.0001:
		wind_dir = Vector2(1.0, 1.0).normalized()
	else:
		wind_dir = wind_dir.normalized()
	mat.set_shader_parameter("wind_dir_xz", wind_dir)
	mat.set_shader_parameter("wind_speed_mps", _current_ocean_wind_speed_mps)


func _setup_underwater_particulates_layer() -> void:
	if _underwater_particulates != null:
		return
	_underwater_particulates = UnderwaterParticulatesScript.new()
	_underwater_particulates.name = "UnderwaterParticulates"
	add_child(_underwater_particulates)
	if _camera:
		_underwater_particulates.set_camera(_camera)
	_underwater_particulates.enabled = underwater_particles_enabled
	_underwater_particulates.quality_tier = clampi(underwater_particles_quality, 0, 3) as UnderwaterParticulates.QualityTier
	_underwater_particulates.particle_count = underwater_particles_count
	_underwater_particulates.size_scale = underwater_particles_size_scale
	_underwater_particulates.speed_scale = underwater_particles_speed_scale
	_underwater_particulates.opacity = underwater_particles_opacity
	_underwater_particulates.set_sea_level(sea_level)
	_underwater_particulates.set_current(_weather_last_wind_t, _weather_last_wind_dir_xz)


func _dispose_underwater_particulates_layer() -> void:
	var particles := _underwater_particulates
	_underwater_particulates = null
	if particles == null:
		return
	if particles.get_parent() == self:
		remove_child(particles)
	particles.queue_free()


func _setup_spray_layer() -> void:
	if _ocean_spray != null:
		return
	_ocean_spray = OceanSprayScript.new()
	_ocean_spray.name = "OceanSpray"
	add_child(_ocean_spray)
	if _camera:
		_ocean_spray.set_camera(_camera)
	_ocean_spray.enabled = sea_spray_enabled
	_ocean_spray.quality_tier = clampi(sea_spray_quality, 0, 3) as OceanSpray.QualityTier
	_ocean_spray.set_sea_level(sea_level)
	_ocean_spray.set_wave_scale(wave_scale)
	_ocean_spray.set_weather(_weather_last_wind_t, _weather_last_wind_dir_xz)
	_ocean_spray.set_fft_available(_wave_generator != null and _ocean_mesh != null and _ocean_mesh.get_quality() == OceanMesh.QualityMode.HIGH)
	if not _cascade_parameters.is_empty():
		_update_cascade_scales()


func _dispose_spray_layer() -> void:
	var spray := _ocean_spray
	_ocean_spray = null
	if spray == null:
		return
	if spray.get_parent() == self:
		remove_child(spray)
	spray.queue_free()


func _shutdown_fft_pipeline() -> void:
	if _wave_generator:
		if _ocean_spray:
			_ocean_spray.set_fft_available(false)
		RenderingServer.global_shader_parameter_set(&"num_cascades", 0)
		RenderingServer.global_shader_parameter_set(&"displacements", null)
		RenderingServer.global_shader_parameter_set(&"normals", null)
		_displacement_maps.texture_rd_rid = RID()
		_normal_maps.texture_rd_rid = RID()
		if _wave_generator.has_method("shutdown"):
			_wave_generator.call("shutdown")
		_wave_generator.queue_free()
		_wave_generator = null
		_cascade_parameters.clear()
		_physics_evaluator = null
		_displacement_cpu = PackedByteArray()
		_displacement_cpu_per_cascade.clear()
		_displacement_size = 0
		Log.info("water", "OceanFFTProvider: FFT pipeline shut down")


# ============================================================================
# WAVE QUERIES - GPU readback (exact match) > OceanPhysicsEvaluator > flat sea level
# ============================================================================

## Sum every loaded cascade's contribution at `world_pos`, applying
## each cascade's own `tile_length` (for the UV wrap) and
## `displacement_scale` (the amplitude multiplier the vertex shader
## applies via `scales.z`). This is the CPU mirror of the shader's
## per-cascade loop:
##
##     for (uint i = 0U; i < num_cascades; ++i) {
##         vec4 scales = map_scales[i];
##         displacement += texture(displacements, vec3(UV * scales.xy, float(i))).xyz * scales.z;
##     }
##
## The shader's `cascade_fade` distance falloff is NOT mirrored — it
## only matters beyond ~500m from the camera and adds bookkeeping that
## the buoyancy use case doesn't need. Similarly the 0.15m
## anti-z-fighting bias in the shader's `VERTEX.y += 0.15` is a tiny
## constant offset that doesn't affect feel; we skip it so
## `get_wave_height` returns the true logical surface height.
func _sum_cascade_displacement(world_pos: Vector3) -> Vector3:
	var total := Vector3.ZERO
	if _displacement_cpu_per_cascade.is_empty() or _cascade_parameters.is_empty():
		return total
	var count: int = mini(_displacement_cpu_per_cascade.size(), _cascade_parameters.size())
	for i in count:
		var buf: PackedByteArray = _displacement_cpu_per_cascade[i]
		if buf.size() == 0:
			continue
		var params: WaveCascadeParameters = _cascade_parameters[i]
		var disp := _sample_displacement_readback_cascade(world_pos, buf, params.tile_length)
		total += disp * params.displacement_scale
	return total


func _cascade_ready_mask(count: int) -> int:
	var mask := 0
	var safe_count: int = mini(count, 30)
	for i in safe_count:
		mask |= 1 << i
	return mask


func _readback_cascade_ready_mask() -> int:
	var mask := 0
	var count: int = mini(_displacement_cpu_per_cascade.size(), _cascade_parameters.size())
	count = mini(count, 30)
	for i in count:
		if _displacement_cpu_per_cascade[i].size() > 0:
			mask |= 1 << i
	return mask


func _sample_active_shore_data(world_pos: Vector3) -> Color:
	if _active_shore_mask_image == null:
		return Color(1.0, 0.5, 0.5, 1.0)
	var size := _active_shore_mask_image.get_size()
	if size.x <= 0 or size.y <= 0 or _active_shore_mask_bounds.size == Vector2.ZERO:
		return Color(1.0, 0.5, 0.5, 1.0)
	var u := (world_pos.x - _active_shore_mask_bounds.position.x) / _active_shore_mask_bounds.size.x
	var v := (world_pos.z - _active_shore_mask_bounds.position.y) / _active_shore_mask_bounds.size.y
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		return Color(1.0, 0.5, 0.5, 1.0)
	var px := clampi(int(u * float(size.x)), 0, size.x - 1)
	var py := clampi(int(v * float(size.y)), 0, size.y - 1)
	return _active_shore_mask_image.get_pixel(px, py)


func _shore_water_distance_norm(shore_data: Color) -> float:
	return clampf(shore_data.a * 2.0 - 1.0, 0.0, 1.0)


func _shore_body_coverage(shore_data: Color) -> float:
	return 1.0 if shore_data.a >= 0.25 else 0.0


func _shore_direction_from_active_mask(world_pos: Vector3, shore_data: Color) -> Vector2:
	var dir := Vector2(shore_data.g * 2.0 - 1.0, shore_data.b * 2.0 - 1.0)
	if dir.length() > 0.01:
		return dir.normalized()
	if _active_shore_mask_image == null or _active_shore_mask_bounds.size == Vector2.ZERO:
		return Vector2.ZERO

	var size := _active_shore_mask_image.get_size()
	var u := (world_pos.x - _active_shore_mask_bounds.position.x) / _active_shore_mask_bounds.size.x
	var v := (world_pos.z - _active_shore_mask_bounds.position.y) / _active_shore_mask_bounds.size.y
	var px := clampi(int(u * float(size.x)), 0, size.x - 1)
	var py := clampi(int(v * float(size.y)), 0, size.y - 1)
	for radius in [1, 2, 4, 8]:
		var x_pos: float = _active_shore_mask_image.get_pixel(clampi(px + radius, 0, size.x - 1), py).a
		var x_neg: float = _active_shore_mask_image.get_pixel(clampi(px - radius, 0, size.x - 1), py).a
		var z_pos: float = _active_shore_mask_image.get_pixel(px, clampi(py + radius, 0, size.y - 1)).a
		var z_neg: float = _active_shore_mask_image.get_pixel(px, clampi(py - radius, 0, size.y - 1)).a
		var gradient_dir := Vector2(x_pos - x_neg, z_pos - z_neg)
		if gradient_dir.length() > 1e-5:
			return gradient_dir.normalized()
	return Vector2.ZERO


static func _shore_breaker_envelope_cpu(raw_dist: float, fade_distance: float) -> float:
	var dist_t := clampf(raw_dist / maxf(fade_distance, 0.001), 0.0, 1.0)
	var shore_ramp := smoothstep(0.05, 0.20, dist_t)
	var offshore_fade := 1.0 - smoothstep(0.42, 0.82, dist_t)
	return shore_ramp * offshore_fade


static func _shore_runup_envelope_cpu(raw_dist: float, fade_distance: float) -> float:
	var dist_t := clampf(raw_dist / maxf(fade_distance, 0.001), 0.0, 1.0)
	return 1.0 - smoothstep(0.00, 0.12, dist_t)


static func _shore_swash_curve_cpu(phase: float) -> float:
	var cycle := fposmod(phase / TAU, 1.0)
	var uprush := smoothstep(0.02, 0.24, cycle)
	var backwash := 1.0 - smoothstep(0.24, 0.72, cycle)
	return uprush * backwash


static func _shore_skewed_sine_cpu(phase: float, steepness: float) -> float:
	var s := sin(phase)
	var c := cos(phase)
	var skew := clampf(0.22 + 0.22 * steepness, 0.0, 0.44)
	return clampf(s + (2.0 * s * c) * skew, -1.0, 1.0)


static func _shore_crest_shape_cpu(phase: float, steepness: float) -> float:
	var skew_s := _shore_skewed_sine_cpu(phase, steepness)
	var crest := maxf(skew_s, 0.0)
	var trough := maxf(-skew_s, 0.0)
	var crest2 := crest * crest
	var shaped_crest := crest2 * (1.65 - 0.65 * crest)
	var broad_trough := trough * (2.0 - trough)
	return shaped_crest - broad_trough * lerpf(0.40, 0.22, steepness)


static func _shore_forward_push_cpu(phase: float, steepness: float) -> float:
	var crest := maxf(_shore_skewed_sine_cpu(phase, steepness), 0.0)
	return cos(phase) * (0.45 + 0.35 * crest)


static func _shore_along_modulation_cpu(world_pos: Vector3, shore_dir: Vector2, time: float) -> float:
	var tangent := Vector2(-shore_dir.y, shore_dir.x)
	var along := Vector2(world_pos.x, world_pos.z).dot(tangent)
	var n := sin(along * 0.035 + time * 0.19) * 0.50 \
		+ sin(along * 0.079 - time * 0.13) * 0.25
	return clampf(0.78 + n * 0.28, 0.55, 1.0)


func _get_shore_wave_displacement(world_pos: Vector3) -> Vector3:
	if _current_shore_wave_amplitude <= 0.0:
		return Vector3.ZERO
	var shore_data := _sample_active_shore_data(world_pos)
	var shore_dir := _shore_direction_from_active_mask(world_pos, shore_data)
	if shore_dir.length() <= 0.01:
		return Vector3.ZERO
	shore_dir = shore_dir.normalized()
	var raw_dist := _shore_water_distance_norm(shore_data) * _active_shore_fade_distance
	var phase := raw_dist * _current_shore_wave_frequency * TAU + _time * _current_shore_wave_speed * TAU
	var modulation := _shore_along_modulation_cpu(world_pos, shore_dir, _time)
	var breaker_env := _shore_breaker_envelope_cpu(raw_dist, _active_shore_fade_distance)
	var runup_env := _shore_runup_envelope_cpu(raw_dist, _active_shore_fade_distance)
	var swash := _shore_swash_curve_cpu(phase)
	var mod_runup := runup_env * swash * lerpf(0.65, 1.0, modulation)
	var crest_phase := _shore_crest_shape_cpu(phase, _current_shore_wave_steepness)
	var shore_y := _current_shore_wave_amplitude * (
		breaker_env * modulation * crest_phase
		+ mod_runup * 0.32
	)
	var shore_xz := _current_shore_wave_amplitude * _current_shore_wave_steepness * (
		breaker_env * modulation * _shore_forward_push_cpu(phase, _current_shore_wave_steepness)
		+ mod_runup * 1.10
	)
	return Vector3(-shore_dir.x * shore_xz, shore_y, -shore_dir.y * shore_xz)


func _get_shore_wave_height(world_pos: Vector3) -> float:
	return _get_shore_wave_displacement(world_pos).y


## Get the wave height at a world position (for buoyancy)
func get_wave_height(world_pos: Vector3) -> float:
	if not _system_enabled or not _enabled:
		return sea_level

	var shore_factor := _get_shore_factor(world_pos)
	var is_flat := _ocean_mesh != null and _ocean_mesh.get_quality() == OceanMesh.QualityMode.FLAT
	var shore_wave_height := 0.0 if is_flat else _get_shore_wave_height(world_pos)
	if shore_factor <= 0.01 and shore_wave_height <= 0.02:
		return sea_level - 1000.0
	if is_flat:
		return sea_level

	# GPU readback — exact match with visual waves (sum every cascade
	# with its own tile_length + displacement_scale, same as the shader).
	if use_gpu_wave_readback and _displacement_cpu_per_cascade.size() > 0:
		var disp := _sum_cascade_displacement(world_pos)
		return sea_level + disp.y * shore_factor * wave_scale + shore_wave_height

	# Fallback: CPU spectrum evaluator (approximate)
	if _physics_evaluator and _physics_evaluator._component_count > 0:
		return sea_level + _physics_evaluator.get_height(world_pos, _time, shore_factor * wave_scale) + shore_wave_height

	return sea_level + shore_wave_height


## Get wave displacement vector at world position
func get_wave_displacement(world_pos: Vector3) -> Vector3:
	if not _system_enabled or not _enabled:
		return Vector3.ZERO
	var shore_factor := _get_shore_factor(world_pos)
	var is_flat := _ocean_mesh != null and _ocean_mesh.get_quality() == OceanMesh.QualityMode.FLAT
	if is_flat or shore_factor <= 0.01:
		return Vector3.ZERO
	var shore_wave_disp := _get_shore_wave_displacement(world_pos)

	if use_gpu_wave_readback and _displacement_cpu_per_cascade.size() > 0:
		var disp := _sum_cascade_displacement(world_pos)
		return disp * shore_factor * wave_scale + shore_wave_disp

	if _physics_evaluator and _physics_evaluator._component_count > 0:
		return _physics_evaluator.get_displacement(world_pos, _time, shore_factor * wave_scale) + shore_wave_disp

	return shore_wave_disp


## Get wave normal at world position
func get_wave_normal(world_pos: Vector3) -> Vector3:
	if not _system_enabled or not _enabled:
		return Vector3.UP
	var gradient := get_wave_gradient(world_pos)
	return Vector3(-gradient.x, 1.0, -gradient.y).normalized()


## Get dHeight/dWorldXZ for consumers that need slope without rebuilding it.
func get_wave_gradient(world_pos: Vector3) -> Vector2:
	if not _system_enabled or not _enabled:
		return Vector2.ZERO
	var eps := 1.0
	var hx0 := get_wave_height(world_pos - Vector3(eps, 0.0, 0.0))
	var hx1 := get_wave_height(world_pos + Vector3(eps, 0.0, 0.0))
	var hz0 := get_wave_height(world_pos - Vector3(0.0, 0.0, eps))
	var hz1 := get_wave_height(world_pos + Vector3(0.0, 0.0, eps))
	return Vector2(hx1 - hx0, hz1 - hz0) / (2.0 * eps)


## Surface velocity is intentionally not approximated from a single height sample.
## Future GPU/CPU wave data should publish true dDisplacement/dt here.
func get_wave_velocity(_world_pos: Vector3) -> Vector3:
	return Vector3.ZERO


func get_water_body_registry() -> RefCounted:
	return _water_body_registry


func register_water_body(body: RefCounted) -> Error:
	var err: Error = _water_body_registry.register_body(body)
	if err == OK:
		_clear_water_body_atlas()
	return err


func unregister_water_body(body: RefCounted) -> void:
	_water_body_registry.unregister_body(body)
	_clear_water_body_atlas()


func unregister_water_body_id(body_id: StringName) -> void:
	_water_body_registry.unregister_body_id(body_id)
	_clear_water_body_atlas()


func register_water_body_provider(provider: RefCounted) -> Error:
	var err: Error = _water_body_registry.register_provider(provider)
	if err == OK:
		_clear_water_body_atlas()
	return err


func unregister_water_body_provider(provider: RefCounted) -> void:
	_water_body_registry.unregister_provider(provider)
	_clear_water_body_atlas()


func set_world_water_provider(provider: RefCounted) -> Error:
	if _world_water_provider != null:
		_water_body_registry.unregister_provider(_world_water_provider)
	_world_water_provider = provider
	if provider == null:
		_clear_water_body_atlas()
		return OK
	return register_water_body_provider(provider)


func get_water_body_runtime_status() -> Dictionary:
	var registry_stats: Dictionary = {}
	if _water_body_registry.has_method("get_stats"):
		registry_stats = _water_body_registry.call("get_stats")
	return {
		"atlas_enabled": water_body_atlas_enabled,
		"atlas_available": has_water_body_atlas(),
		"atlas_rebuild_last_usec": _water_body_atlas_last_rebuild_usec,
		"atlas_rebuild_total_usec": _water_body_atlas_total_rebuild_usec,
		"atlas_rebuild_count": _water_body_atlas_rebuild_count,
		"atlas_resolution": WATER_BODY_ATLAS_RESOLUTION if has_water_body_atlas() else 0,
		"atlas_bounds": _water_body_atlas_bounds,
		"registry": registry_stats,
		"world_provider": _get_world_water_provider_status(),
	}


func set_water_body_atlas_enabled(enabled: bool) -> void:
	if water_body_atlas_enabled == enabled:
		return
	water_body_atlas_enabled = enabled
	if not water_body_atlas_enabled:
		_clear_water_body_atlas()
		_sync_water_interaction_to_renderers(true)


func is_water_body_atlas_enabled() -> bool:
	return water_body_atlas_enabled


func force_update_water_body_atlas(center: Vector3) -> void:
	if not water_body_atlas_enabled:
		_clear_water_body_atlas()
		return
	_rebuild_water_body_atlas(center)


func get_water_body_atlas_texture() -> Texture2D:
	return _water_body_atlas_texture


func get_water_body_atlas_texture_rd() -> RID:
	return _water_body_atlas_rd


func get_water_body_atlas_image() -> Image:
	return _water_body_atlas_image


func get_water_body_atlas_bounds_rect() -> Rect2:
	return _water_body_atlas_bounds


func get_water_body_atlas_bounds() -> Vector4:
	return Vector4(
		_water_body_atlas_bounds.position.x,
		_water_body_atlas_bounds.position.y,
		_water_body_atlas_bounds.size.x,
		_water_body_atlas_bounds.size.y
	)


func has_water_body_atlas() -> bool:
	return water_body_atlas_enabled and _water_body_atlas_texture != null and _water_body_atlas_image != null and _water_body_atlas_bounds.size != Vector2.ZERO


func sample_water_body_atlas(world_pos: Vector3) -> Dictionary:
	if not has_water_body_atlas():
		return {}
	var uv := Vector2(
		(world_pos.x - _water_body_atlas_bounds.position.x) / maxf(_water_body_atlas_bounds.size.x, 0.001),
		(world_pos.z - _water_body_atlas_bounds.position.y) / maxf(_water_body_atlas_bounds.size.y, 0.001)
	)
	if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
		return {}
	var size := _water_body_atlas_image.get_size()
	var px := clampi(floori(uv.x * float(size.x)), 0, size.x - 1)
	var py := clampi(floori(uv.y * float(size.y)), 0, size.y - 1)
	var sample := _water_body_atlas_image.get_pixel(px, py)
	var coverage := clampf(sample.r, 0.0, 1.0)
	return {
		"coverage": coverage,
		"height": sample.g,
		"body_gate": smoothstep(WaterSurfaceState.COVERAGE_GATE_START, WaterSurfaceState.COVERAGE_GATE_END, coverage),
	}


func _update_water_body_atlas(camera_pos: Vector3) -> void:
	if not water_body_atlas_enabled or not _water_body_registry.has_sources():
		_clear_water_body_atlas()
		return
	var center_xz := Vector2(camera_pos.x, camera_pos.z)
	var moved_enough := _water_body_atlas_center_xz == Vector2.INF \
		or center_xz.distance_to(_water_body_atlas_center_xz) >= WATER_BODY_ATLAS_UPDATE_MOVE_M
	if not moved_enough and has_water_body_atlas():
		return
	_rebuild_water_body_atlas(camera_pos)


func _rebuild_water_body_atlas(center: Vector3) -> void:
	var rebuild_start_usec := Time.get_ticks_usec()
	if not _water_body_registry.has_sources():
		_clear_water_body_atlas()
		return
	var resolution: int = WATER_BODY_ATLAS_RESOLUTION
	var extent: float = WATER_BODY_ATLAS_EXTENT_M
	var half_extent: float = extent * 0.5
	var bounds := Rect2(center.x - half_extent, center.z - half_extent, extent, extent)
	var image := _water_body_atlas_image
	if image == null or image.get_width() != resolution or image.get_height() != resolution or image.get_format() != Image.FORMAT_RGBAF:
		image = Image.create(resolution, resolution, false, Image.FORMAT_RGBAF)
	var inv_resolution: float = 1.0 / float(resolution)
	for y: int in resolution:
		var world_z := bounds.position.y + (float(y) + 0.5) * extent * inv_resolution
		for x: int in resolution:
			var world_x := bounds.position.x + (float(x) + 0.5) * extent * inv_resolution
			var query_pos := Vector3(world_x, center.y, world_z)
			var coverage: float = _water_body_registry.sample_coverage(query_pos, 0.0)
			var height: float = 0.0
			if coverage > WaterSurfaceState.COVERAGE_GATE_START:
				height = _water_body_registry.sample_height(query_pos, sea_level)
			image.set_pixel(x, y, Color(coverage, height, 0.0, 1.0 if coverage > 0.0 else 0.0))
	_water_body_atlas_image = image
	_water_body_atlas_bounds = bounds
	_water_body_atlas_center_xz = Vector2(center.x, center.z)
	_water_body_atlas_frame = Engine.get_process_frames()
	if _water_body_atlas_texture == null:
		_water_body_atlas_texture = ImageTexture.create_from_image(image)
	else:
		_water_body_atlas_texture.update(image)
	_water_body_atlas_rd = RID()
	if _water_body_atlas_texture != null:
		var texture_rid := _water_body_atlas_texture.get_rid()
		if texture_rid.is_valid():
			_water_body_atlas_rd = RenderingServer.texture_get_rd_texture(texture_rid)
	_water_body_atlas_last_rebuild_usec = Time.get_ticks_usec() - rebuild_start_usec
	_water_body_atlas_total_rebuild_usec += _water_body_atlas_last_rebuild_usec
	_water_body_atlas_rebuild_count += 1
	if _water_body_atlas_last_rebuild_usec > 8000:
		Log.warn("water", "Water body atlas rebuild took %.1f ms (%d rebuilds total) — main-thread stall" % [
			_water_body_atlas_last_rebuild_usec / 1000.0, _water_body_atlas_rebuild_count])


func _clear_water_body_atlas() -> void:
	_water_body_atlas_image = null
	_water_body_atlas_texture = null
	_water_body_atlas_rd = RID()
	_water_body_atlas_bounds = Rect2()
	_water_body_atlas_center_xz = Vector2.INF
	_water_body_atlas_frame = -1


func _get_world_water_provider_status() -> Dictionary:
	if _world_water_provider == null:
		return {}
	if _world_water_provider.has_method("get_runtime_status"):
		var status_v: Variant = _world_water_provider.call("get_runtime_status")
		if status_v is Dictionary:
			return status_v
	var status := {
		"provider_id": StringName(_world_water_provider.get("provider_id")),
		"active_hydrology_tasks": 0,
		"cached_regions": 0,
		"cache_memory_bytes_estimate": 0,
	}
	if "_pending_region_tasks" in _world_water_provider:
		status["active_hydrology_tasks"] = _world_water_provider._pending_region_tasks.size()
	if "_region_cache" in _world_water_provider:
		var cache: Dictionary = _world_water_provider._region_cache
		status["cached_regions"] = cache.size()
		var bytes := 0
		for region_data_v: Variant in cache.values():
			if not region_data_v is Dictionary:
				continue
			var region_data: Dictionary = region_data_v as Dictionary
			var flow_image: Image = region_data.get("flow_image") as Image
			if flow_image == null:
				continue
			bytes += flow_image.get_width() * flow_image.get_height() * 4
		status["cache_memory_bytes_estimate"] = bytes
	return status


func sample_water_height(world_pos: Vector3) -> float:
	var registered_height: float = _water_body_registry.sample_height(world_pos, NAN)
	if not is_nan(registered_height):
		return registered_height
	if _system_enabled and _enabled and get_water_coverage(world_pos) > WaterSurfaceState.COVERAGE_GATE_START:
		return get_wave_height(world_pos)
	return -INF


func sample_water_displacement(world_pos: Vector3) -> Vector3:
	if _water_body_registry.sample_coverage(world_pos, 0.0) > WaterSurfaceState.COVERAGE_GATE_START:
		return Vector3.ZERO
	return get_wave_displacement(world_pos)


func sample_water_normal(world_pos: Vector3) -> Vector3:
	if _water_body_registry.sample_coverage(world_pos, 0.0) > WaterSurfaceState.COVERAGE_GATE_START:
		return _water_body_registry.sample_normal(world_pos, Vector3.UP)
	return get_wave_normal(world_pos)


func sample_water_gradient(world_pos: Vector3) -> Vector2:
	if _water_body_registry.sample_coverage(world_pos, 0.0) > WaterSurfaceState.COVERAGE_GATE_START:
		return _water_body_registry.sample_gradient(world_pos, Vector2.ZERO)
	return get_wave_gradient(world_pos)


func sample_water_velocity(world_pos: Vector3) -> Vector3:
	return sample_base_water_velocity(world_pos) + _sample_local_flow_delta(world_pos)


func sample_base_water_velocity(world_pos: Vector3) -> Vector3:
	var registered_velocity: Vector3 = _sample_base_water_velocity(world_pos)
	if registered_velocity != Vector3.INF:
		return registered_velocity
	return get_wave_velocity(world_pos) if _system_enabled and _enabled else Vector3.ZERO


func _sample_base_water_velocity(world_pos: Vector3) -> Vector3:
	return _water_body_registry.sample_velocity(world_pos, Vector3.INF)


func sample_water_coverage(world_pos: Vector3) -> float:
	var registered_coverage: float = _water_body_registry.sample_coverage(world_pos, 0.0)
	if registered_coverage > WaterSurfaceState.COVERAGE_GATE_START:
		return registered_coverage
	return get_water_coverage(world_pos)


func sample_signed_water_shore_distance(world_pos: Vector3) -> float:
	if _water_body_registry.sample_coverage(world_pos, 0.0) > WaterSurfaceState.COVERAGE_GATE_START:
		return 0.0
	return get_signed_shore_distance(world_pos)


func sample_water_shore_side(world_pos: Vector3) -> int:
	if _water_body_registry.sample_coverage(world_pos, 0.0) > WaterSurfaceState.COVERAGE_GATE_START:
		return WaterSurfaceState.SHORE_SIDE_WATER
	return get_shore_side(world_pos)


func sample_water_body_id_at(world_pos: Vector3) -> StringName:
	var registered_id: StringName = _water_body_registry.sample_water_body_id(world_pos, WaterSurfaceState.WATER_BODY_NONE)
	if registered_id != WaterSurfaceState.WATER_BODY_NONE:
		return registered_id
	return get_water_body_id_at(world_pos)


func sample_water_surface_query(world_pos: Vector3) -> Dictionary:
	var registered: Dictionary = _water_body_registry.sample_surface_query(world_pos)
	if not registered.is_empty():
		return registered
	var coverage := get_water_coverage(world_pos)
	var has_ocean := _system_enabled and _enabled and coverage > WaterSurfaceState.COVERAGE_GATE_START
	var height := get_wave_height(world_pos) if has_ocean else -INF
	return {
		"height": height,
		"displacement": get_wave_displacement(world_pos) if has_ocean else Vector3.ZERO,
		"normal": get_wave_normal(world_pos) if has_ocean else Vector3.UP,
		"gradient": get_wave_gradient(world_pos) if has_ocean else Vector2.ZERO,
		"velocity": get_wave_velocity(world_pos) if has_ocean else Vector3.ZERO,
		"coverage": coverage if has_ocean else 0.0,
		"body_gate": WaterSurfaceState.coverage_to_body_gate_static(coverage if has_ocean else 0.0),
		"depth": height - world_pos.y if has_ocean else -INF,
		"water_body_id": get_water_body_id_at(world_pos) if has_ocean else WaterSurfaceState.WATER_BODY_NONE,
		"has_water_body": has_ocean,
		"coverage_source": get_water_query_source(),
	}


func emit_water_impulse(
	world_pos: Vector3,
	radius_m: float,
	strength: float,
	kind: StringName = &"impact",
	body_id: StringName = &"",
	wake_direction: Vector2 = Vector2.ZERO,
	wake_length_m: float = 0.0,
) -> void:
	if not _system_enabled or not _enabled:
		return
	if _water_interaction_sim == null:
		_setup_water_interaction_layer()
	if _water_interaction_sim == null:
		return
	var sampled_body_id := body_id
	if sampled_body_id == &"":
		sampled_body_id = sample_water_body_id_at(world_pos)
	if sampled_body_id == WaterSurfaceState.WATER_BODY_NONE:
		return
	var coverage := sample_water_coverage(world_pos)
	if coverage <= WaterSurfaceState.COVERAGE_GATE_START:
		return
	var water_height := sample_water_height(world_pos)
	if is_nan(water_height) or absf(water_height) >= 1.0e20:
		return
	var shaped_strength := strength
	match kind:
		&"wake":
			shaped_strength *= 0.65
		&"projectile":
			shaped_strength *= 1.25
		_:
			shaped_strength = strength
	var body_gate := smoothstep(WaterSurfaceState.COVERAGE_GATE_START, WaterSurfaceState.COVERAGE_GATE_END, clampf(coverage, 0.0, 1.0))
	var requires_atlas := sampled_body_id != WaterSurfaceState.WATER_BODY_OCEAN and has_water_body_atlas()
	_water_interaction_sim.queue_impulse(
		world_pos,
		radius_m,
		shaped_strength,
		water_height,
		body_gate,
		requires_atlas,
		wake_direction,
		wake_length_m
	)


func emit_water_flow_obstacle(
	world_pos: Vector3,
	radius_m: float,
	block_strength: float,
	wake_strength: float,
	body_id: StringName = &""
) -> void:
	var sampled_body_id := body_id
	if sampled_body_id == &"":
		sampled_body_id = sample_water_body_id_at(world_pos)
	if sampled_body_id == WaterSurfaceState.WATER_BODY_NONE:
		return
	var coverage := sample_water_coverage(world_pos)
	if coverage <= WaterSurfaceState.COVERAGE_GATE_START:
		return
	var water_height := sample_water_height(world_pos)
	if is_nan(water_height) or absf(water_height) >= 1.0e20:
		return
	var base_velocity := _sample_base_water_velocity(world_pos)
	if base_velocity == Vector3.INF:
		base_velocity = get_wave_velocity(world_pos) if _system_enabled and _enabled else Vector3.ZERO
	if Vector2(base_velocity.x, base_velocity.z).length_squared() <= 0.0001:
		return
	var body_gate := smoothstep(WaterSurfaceState.COVERAGE_GATE_START, WaterSurfaceState.COVERAGE_GATE_END, clampf(coverage, 0.0, 1.0))
	var requires_atlas := sampled_body_id != WaterSurfaceState.WATER_BODY_OCEAN and has_water_body_atlas()
	if _water_interaction_sim == null:
		_setup_water_interaction_layer()
	if _water_interaction_sim != null:
		_water_interaction_sim.queue_flow_obstacle(
			world_pos,
			radius_m,
			base_velocity,
			block_strength,
			wake_strength,
			water_height,
			body_gate,
			requires_atlas
		)
	_track_local_flow_obstacle(world_pos, radius_m, base_velocity, block_strength, wake_strength)


func _track_local_flow_obstacle(
	world_pos: Vector3,
	radius_m: float,
	base_velocity: Vector3,
	block_strength: float,
	wake_strength: float
) -> void:
	var now := Time.get_ticks_msec()
	_local_flow_obstacles.append({
		"position": Vector2(world_pos.x, world_pos.z),
		"radius": clampf(radius_m, 0.08, 32.0),
		"base_velocity": Vector2(base_velocity.x, base_velocity.z),
		"block_strength": clampf(block_strength, 0.0, 2.0),
		"wake_strength": clampf(wake_strength, 0.0, 2.0),
		"expires_msec": now + 220,
	})
	if _local_flow_obstacles.size() > 96:
		_local_flow_obstacles = _local_flow_obstacles.slice(_local_flow_obstacles.size() - 96)


func _sample_local_flow_delta(world_pos: Vector3) -> Vector3:
	if _local_flow_obstacles.is_empty():
		return Vector3.ZERO
	var now := Time.get_ticks_msec()
	var world_xz := Vector2(world_pos.x, world_pos.z)
	var delta := Vector2.ZERO
	var kept: Array[Dictionary] = []
	for obstacle: Dictionary in _local_flow_obstacles:
		if int(obstacle.get("expires_msec", 0)) < now:
			continue
		kept.append(obstacle)
		var center: Vector2 = obstacle.get("position", Vector2.ZERO)
		var base_velocity: Vector2 = obstacle.get("base_velocity", Vector2.ZERO)
		var base_speed := base_velocity.length()
		if base_speed <= 0.001:
			continue
		var radius := maxf(float(obstacle.get("radius", 0.1)), 0.08)
		var to_sample := world_xz - center
		var dist := to_sample.length()
		var support := radius * 5.0
		if dist > support:
			continue
		var dir := base_velocity / base_speed
		var side := Vector2(-dir.y, dir.x)
		var along := to_sample.dot(dir)
		var lateral := to_sample.dot(side)
		var core := exp(-pow(dist / radius, 2.0))
		var downstream := smoothstep(-radius * 0.5, radius * 2.0, along) * (1.0 - smoothstep(radius * 2.0, support, along))
		var side_gate := smoothstep(0.0, radius * 0.95, absf(lateral)) * (1.0 - smoothstep(radius * 0.95, radius * 2.8, absf(lateral)))
		var block := float(obstacle.get("block_strength", 0.0))
		var wake := float(obstacle.get("wake_strength", 0.0))
		var slow := -base_velocity * block * core
		var deflect := side * (1.0 if lateral >= 0.0 else -1.0) * base_speed * wake * side_gate * downstream * 0.55
		delta += slow + deflect
	_local_flow_obstacles = kept
	if delta.length() > 8.0:
		delta = delta.normalized() * 8.0
	return Vector3(delta.x, 0.0, delta.y)


func register_water_interactor(node: Node, options: Dictionary = {}) -> void:
	if node == null or _water_interactors.has(node):
		return
	_water_interactors.append(node)
	if not options.is_empty() and node.has_method("apply_water_interaction_options"):
		node.call("apply_water_interaction_options", options)


func unregister_water_interactor(node: Node) -> void:
	var idx := _water_interactors.find(node)
	if idx >= 0:
		_water_interactors.remove_at(idx)


func register_water_interaction_renderer(node: Node) -> void:
	if node == null or _water_interaction_renderers.has(node):
		return
	_water_interaction_renderers.append(node)
	_sync_one_water_interaction_renderer(node)


func unregister_water_interaction_renderer(node: Node) -> void:
	var idx := _water_interaction_renderers.find(node)
	if idx >= 0:
		_water_interaction_renderers.remove_at(idx)


func _sync_one_water_interaction_renderer(node: Node) -> void:
	if not is_instance_valid(node) or not node.has_method("sync_water_interaction_texture"):
		return
	var texture: Texture2D = null
	var dynamic_flow_texture: Texture2D = null
	var bounds := Vector4.ZERO
	var active := false
	if _water_interaction_sim != null:
		var stats := _water_interaction_sim.get_stats()
		texture = _water_interaction_sim.get_texture()
		dynamic_flow_texture = _water_interaction_sim.get_flow_texture()
		bounds = _water_interaction_sim.get_bounds()
		active = bool(stats.get("enabled", false)) and texture != null
	node.call(
		"sync_water_interaction_texture",
		texture,
		bounds,
		active,
		_water_interaction_debug_enabled,
		get_water_body_atlas_texture(),
		get_water_body_atlas_bounds(),
		has_water_body_atlas(),
		dynamic_flow_texture,
		bounds,
		active and dynamic_flow_texture != null
	)
	_water_interaction_renderer_sync_count += 1


func get_water_interaction_texture() -> Texture2D:
	if _water_interaction_sim == null:
		return null
	return _water_interaction_sim.get_texture()


func get_water_dynamic_flow_texture() -> Texture2D:
	if _water_interaction_sim == null:
		return null
	return _water_interaction_sim.get_flow_texture()


func get_water_interaction_bounds() -> Vector4:
	if _water_interaction_sim == null:
		return Vector4.ZERO
	return _water_interaction_sim.get_bounds()


func get_water_interaction_stats() -> Dictionary:
	if _water_interaction_sim == null:
		return {
			"enabled": false,
			"debug_enabled": _water_interaction_debug_enabled,
			"atlas_size": 0,
			"dispatch_count": 0,
			"last_impulse_count": 0,
			"pending_impulse_count": 0,
			"gpu_ms": -1.0,
			"cpu_upload_us": 0,
			"culled_impulses_total": 0,
			"active_dispatch": false,
			"atlas_scroll_px": Vector2i.ZERO,
			"renderer_sync_count": _water_interaction_renderer_sync_count,
		}
	var stats := _water_interaction_sim.get_stats()
	stats["debug_enabled"] = _water_interaction_debug_enabled
	stats["renderer_sync_count"] = _water_interaction_renderer_sync_count
	return stats


func set_water_interaction_debug_enabled(enabled: bool) -> void:
	_water_interaction_debug_enabled = enabled
	_sync_water_interaction_to_renderers()


func is_water_interaction_debug_enabled() -> bool:
	return _water_interaction_debug_enabled


func get_water_coverage(world_pos: Vector3) -> float:
	if not _system_enabled or not _enabled:
		return 0.0
	if _active_shore_mask_image != null:
		return _shore_body_coverage(_sample_active_shore_data(world_pos))
	if _shore_mask:
		return _shore_mask.get_water_coverage(world_pos)
	if _terrain and _terrain.data:
		var terrain_height: float = CS.get_terrain_height(world_pos, _terrain)
		return 1.0 if terrain_height < sea_level else 0.0
	return 1.0


func get_signed_shore_distance(world_pos: Vector3) -> float:
	if _active_shore_mask_image != null:
		var shore_data := _sample_active_shore_data(world_pos)
		var distance := _shore_water_distance_norm(shore_data) * _active_shore_fade_distance
		return distance if _shore_body_coverage(shore_data) > 0.0 else -_active_shore_fade_distance
	if _shore_mask:
		return _get_shore_factor(world_pos) * shore_fade_distance
	if _terrain and _terrain.data:
		var terrain_height: float = CS.get_terrain_height(world_pos, _terrain)
		return shore_fade_distance if terrain_height < sea_level else -shore_fade_distance
	return shore_fade_distance


func get_shore_side(world_pos: Vector3) -> int:
	if get_water_coverage(world_pos) > 0.01:
		return WaterSurfaceState.SHORE_SIDE_WATER
	return WaterSurfaceState.SHORE_SIDE_LAND


func get_water_body_id_at(world_pos: Vector3) -> StringName:
	if get_water_coverage(world_pos) > 0.01:
		return WaterSurfaceState.WATER_BODY_OCEAN
	return WaterSurfaceState.WATER_BODY_NONE


## Sample one cascade's displacement texture at a world position.
## Bilinear interpolation from the RGBA16F layer buffer, using the
## cascade's own tile_length for UV wrap. The result is the raw
## (unscaled) displacement — the caller multiplies by the cascade's
## `displacement_scale` and the global `shore_factor * wave_scale`.
func _sample_displacement_readback_cascade(world_pos: Vector3, buf: PackedByteArray, tile_length: Vector2) -> Vector3:
	if buf.size() == 0 or _displacement_size == 0 or tile_length.x <= 0.0 or tile_length.y <= 0.0:
		return Vector3.ZERO

	# World pos → UV in displacement map (tiling)
	var u: float = fmod(world_pos.x / tile_length.x, 1.0)
	var v: float = fmod(world_pos.z / tile_length.y, 1.0)
	if u < 0.0:
		u += 1.0
	if v < 0.0:
		v += 1.0

	# UV → pixel coordinates
	var px: float = u * _displacement_size
	var pz: float = v * _displacement_size
	var ix: int = int(px) % _displacement_size
	var iz: int = int(pz) % _displacement_size
	var fx: float = px - floorf(px)
	var fz: float = pz - floorf(pz)

	# Bilinear sample (4 texels)
	var ix1: int = (ix + 1) % _displacement_size
	var iz1: int = (iz + 1) % _displacement_size

	var d00 := _read_displacement_texel_from_buf(buf, ix, iz)
	var d10 := _read_displacement_texel_from_buf(buf, ix1, iz)
	var d01 := _read_displacement_texel_from_buf(buf, ix, iz1)
	var d11 := _read_displacement_texel_from_buf(buf, ix1, iz1)

	return d00 * (1.0 - fx) * (1.0 - fz) + d10 * fx * (1.0 - fz) + d01 * (1.0 - fx) * fz + d11 * fx * fz


## Read a single RGBA16F texel from a specific cascade byte buffer.
## 4 half-floats × 2 bytes = 8 bytes per texel, row-major layout.
func _read_displacement_texel_from_buf(buf: PackedByteArray, x: int, z: int) -> Vector3:
	var offset: int = (z * _displacement_size + x) * 8
	if offset + 7 >= buf.size():
		return Vector3.ZERO
	var dx: float = buf.decode_half(offset)
	var dy: float = buf.decode_half(offset + 2)
	var dz: float = buf.decode_half(offset + 4)
	return Vector3(dx, dy, dz)


func _get_shore_factor(world_pos: Vector3) -> float:
	if _active_shore_mask_image != null:
		return _sample_active_shore_data(world_pos).r
	if _shore_mask:
		return _shore_mask.get_shore_factor(world_pos)
	return 1.0


## Check if a position is in ocean water
func is_in_ocean(world_pos: Vector3) -> bool:
	if not _system_enabled or not _enabled:
		return false
	if world_pos.y > sea_level + 10.0:
		return false
	if _active_shore_mask_image != null or _shore_mask:
		return get_water_coverage(world_pos) > 0.0 or _get_shore_wave_height(world_pos) > 0.02
	if _terrain and _terrain.data:
		var terrain_height: float = CS.get_terrain_height(world_pos, _terrain)
		return terrain_height < sea_level
	return true


## Check if the camera is currently submerged
func is_camera_submerged() -> bool:
	if _camera:
		var state := get_water_surface_state()
		if state == null or not state.has_camera_water():
			return false
		var water_level := state.get_camera_water_level(NAN)
		if is_nan(water_level) or water_level <= -1.0e20:
			return false
		return _camera.global_position.y < water_level + 0.02
	return false


# ============================================================================
# PUBLIC API
# ============================================================================

func set_camera(camera: Camera3D) -> void:
	_camera = camera
	_auto_find_camera = false
	if _ocean_spray:
		_ocean_spray.set_camera(camera)
	if _underwater_particulates:
		_underwater_particulates.set_camera(camera)


func set_sea_level(level: float) -> void:
	if is_equal_approx(sea_level, level):
		return
	sea_level = level
	if _underwater_particulates:
		_underwater_particulates.set_sea_level(sea_level)
	if not _system_enabled:
		return
	if _terrain and _shore_mask:
		_shore_mask.generate_from_terrain(_terrain, shore_mask_resolution, shore_fade_distance, sea_level)
		_set_active_shore_mask(
			_shore_mask.get_shore_mask_texture(),
			_shore_mask.get_world_bounds(),
			shore_fade_distance,
			_shore_mask.get_shore_mask_image()
		)
	_update_shader_parameters()
	if _ocean_spray:
		_ocean_spray.set_sea_level(sea_level)


func get_sea_level() -> float:
	return sea_level


func get_absorption_tint() -> Vector3:
	return _current_absorption_tint


func get_absorption_sigma() -> Vector3:
	return _current_absorption_sigma


func get_absorption_density() -> float:
	return _surface_absorption_density


func get_water_visibility_distance() -> float:
	return _optical_profile.visibility_distance_m


func set_water_visibility_distance(value: float) -> void:
	_optical_profile.visibility_distance_m = clampf(
		value,
		WaterOpticalProfile.MIN_VISIBILITY_M,
		WaterOpticalProfile.MAX_VISIBILITY_M
	)
	_sync_optical_cache_from_profile()
	_push_current_absorption_to_material()


func get_water_scattering_strength() -> float:
	return _optical_profile.scattering_strength


func set_water_scattering_strength(value: float) -> void:
	_optical_profile.scattering_strength = clampf(value, 0.0, 1.0)
	_sync_optical_cache_from_profile()
	_push_current_absorption_to_material()


func get_water_scattering_color() -> Color:
	return _optical_profile.scattering_color


func set_water_scattering_color(value: Color) -> void:
	_optical_color_override_enabled = true
	_optical_profile.scattering_color = value
	_sync_optical_cache_from_profile()
	_push_current_absorption_to_material()


func get_water_optical_profile() -> WaterOpticalProfile:
	return _optical_profile.duplicate_profile()


func is_surface_ssr_enabled() -> bool:
	return _surface_ssr_enabled


func set_surface_ssr_enabled(enabled: bool) -> void:
	_surface_ssr_enabled = enabled
	_push_surface_ssr_to_material()


func set_absorption_density(value: float) -> void:
	_surface_absorption_density = clampf(value, 0.01, 2.0)
	_optical_profile.visibility_distance_m = _visibility_from_legacy_density(_surface_absorption_density)
	_sync_optical_cache_from_profile()
	_push_current_absorption_to_material()


func get_absorption_tint_color() -> Color:
	return Color(_current_absorption_tint.x, _current_absorption_tint.y, _current_absorption_tint.z, 1.0)


func set_absorption_tint_color(value: Color) -> void:
	_absorption_tint_override_enabled = true
	_optical_color_override_enabled = true
	_absorption_tint_override = value
	_optical_profile.set_medium_color(value)
	_sync_optical_cache_from_profile()
	_push_current_absorption_to_material()


func clear_absorption_tint_override() -> void:
	_absorption_tint_override_enabled = false
	_optical_color_override_enabled = false
	reset_weather()


func get_absorption_depth_falloff() -> float:
	if _ocean_mesh == null:
		return 20.0
	var mat: ShaderMaterial = _ocean_mesh.get_material()
	if mat == null:
		return 20.0
	var max_depth: Variant = mat.get_shader_parameter("max_visible_depth")
	if max_depth == null:
		return 20.0
	return float(max_depth)


func get_underwater_caustics_strength() -> float:
	return _current_underwater_caustics_strength


func get_displacement_texture_rd() -> RID:
	if _wave_generator == null or not _wave_generator.descriptors.has(&"displacement_map"):
		return RID()
	return _wave_generator.descriptors[&"displacement_map"].rid


func get_normal_texture_rd() -> RID:
	if _wave_generator == null or not _wave_generator.descriptors.has(&"normal_map"):
		return RID()
	return _wave_generator.descriptors[&"normal_map"].rid


func is_gpu_wave_readback_enabled() -> bool:
	return use_gpu_wave_readback


func set_gpu_wave_readback_enabled(enabled: bool) -> void:
	use_gpu_wave_readback = enabled
	if not enabled:
		_displacement_cpu = PackedByteArray()
		_displacement_cpu_per_cascade.clear()


func get_water_query_source() -> StringName:
	if _water_body_registry.has_sources():
		return &"water_body_registry"
	if not _system_enabled or not _enabled:
		return &"disabled"
	var is_flat := _ocean_mesh != null and _ocean_mesh.get_quality() == OceanMesh.QualityMode.FLAT
	if is_flat:
		return &"flat"
	if use_gpu_wave_readback and _displacement_cpu_per_cascade.size() > 0:
		return &"gpu_readback"
	if _physics_evaluator and _physics_evaluator._component_count > 0:
		return &"cpu_spectrum"
	return &"shore_analytical"


func get_water_query_readback_bytes_per_frame() -> int:
	var total := 0
	for buf: PackedByteArray in _displacement_cpu_per_cascade:
		total += buf.size()
	return total


func get_water_surface_state() -> WaterSurfaceState:
	var state := WaterSurfaceState.new()
	var frame_id := Engine.get_process_frames()
	var displacement_rd := get_displacement_texture_rd()
	var normal_rd := get_normal_texture_rd()
	state.sea_level = sea_level
	state.wave_scale = wave_scale
	state.ocean_time = _time
	state.map_scales = _current_map_scales
	state.cascade_count = _cascade_parameters.size()
	state.displacement_texture_rd = displacement_rd
	state.normal_texture_rd = normal_rd
	if _water_interaction_sim != null:
		state.interaction_texture_rd = _water_interaction_sim.get_texture_rd()
		state.interaction_bounds = _water_interaction_sim.get_bounds()
		state.interaction_ready = state.interaction_texture_rd.is_valid()
	var has_registered_water: bool = _water_body_registry.has_sources()
	if _system_enabled and _enabled:
		state.water_body_id = WaterSurfaceState.WATER_BODY_OCEAN
	elif has_registered_water:
		state.water_body_id = WaterSurfaceState.WATER_BODY_REGISTERED
	else:
		state.water_body_id = WaterSurfaceState.WATER_BODY_NONE
	state.water_body_index = 1 if _system_enabled and _enabled else 0
	state.coverage_available = (_system_enabled and _enabled) or has_registered_water
	if _camera != null and is_instance_valid(_camera):
		# Registry samples (polygon tests per water body) are the expensive
		# part of building a state, and this function runs several times per
		# frame across consumers — sample the camera position once per frame.
		if frame_id != _camera_sample_frame:
			_camera_sample_frame = frame_id
			var camera_pos := _camera.global_position
			_camera_sample_coverage = sample_water_coverage(camera_pos)
			_camera_sample_body_id = sample_water_body_id_at(camera_pos)
			if _camera_sample_coverage > WaterSurfaceState.COVERAGE_GATE_START and _camera_sample_body_id != WaterSurfaceState.WATER_BODY_NONE:
				_camera_sample_level = sample_water_height(camera_pos)
			else:
				_camera_sample_level = NAN
		state.camera_water_coverage = _camera_sample_coverage
		state.camera_water_body_id = _camera_sample_body_id
		state.camera_water_level = _camera_sample_level
	if has_registered_water:
		state.coverage_source = &"water_body_registry"
	elif _active_shore_mask_image != null:
		state.coverage_source = &"shore_mask"
	elif _shore_mask != null:
		state.coverage_source = &"runtime_shore_mask"
	elif _terrain != null and _terrain.data != null:
		state.coverage_source = &"terrain_height"
	elif _system_enabled and _enabled:
		state.coverage_source = &"global_ocean"
	else:
		state.coverage_source = &"none"
	state.shore_mask_texture = _active_shore_mask_texture
	state.shore_mask_bounds = Vector4(
		_active_shore_mask_bounds.position.x,
		_active_shore_mask_bounds.position.y,
		_active_shore_mask_bounds.size.x,
		_active_shore_mask_bounds.size.y
	)
	state.shore_fade_distance = _active_shore_fade_distance
	if has_water_body_atlas():
		state.water_body_atlas_texture = _water_body_atlas_texture
		state.water_body_atlas_image = _water_body_atlas_image
		state.water_body_atlas_rd = _water_body_atlas_rd
		state.water_body_atlas_bounds = get_water_body_atlas_bounds()
		state.water_body_atlas_resolution = Vector2i(WATER_BODY_ATLAS_RESOLUTION, WATER_BODY_ATLAS_RESOLUTION)
		state.water_body_atlas_available = true
	state.shore_wave_amplitude = _current_shore_wave_amplitude
	state.shore_wave_frequency = _current_shore_wave_frequency
	state.shore_wave_speed = _current_shore_wave_speed
	state.shore_wave_steepness = _current_shore_wave_steepness
	state.optical_profile = _optical_profile.duplicate_profile()
	state.absorption_tint = _current_absorption_tint
	state.absorption_sigma = _current_absorption_sigma
	state.absorption_depth_falloff = get_absorption_depth_falloff()
	state.underwater_caustics_strength = _current_underwater_caustics_strength
	state.snapshot_frame_id = frame_id
	state.surface_data_frame_id = frame_id
	state.readback_frame_id = _readback_frame
	state.fft_ready = _system_enabled and _enabled and displacement_rd.is_valid() and _cascade_parameters.size() > 0
	state.normal_data_ready = _system_enabled and _enabled and normal_rd.is_valid() and _cascade_parameters.size() > 0
	state.readback_ready = use_gpu_wave_readback and _displacement_cpu_per_cascade.size() > 0
	state.gpu_cascade_ready_mask = _cascade_ready_mask(_cascade_parameters.size()) if state.fft_ready else 0
	state.cpu_cascade_ready_mask = _readback_cascade_ready_mask()
	state.cpu_query_available = (_system_enabled and _enabled) or has_registered_water
	state.cpu_query_source = get_water_query_source()
	state.cpu_readback_bytes_per_frame = get_water_query_readback_bytes_per_frame()
	state.displacement_texture_size = _displacement_size
	if _ocean_mesh != null:
		state.render_mesh_mode = int(_ocean_mesh.get_mesh_mode())
		state.render_mesh_origin = _ocean_mesh.get_clipmap_origin()
		state.render_clipmap_base_quad_size = _ocean_mesh.get_clipmap_base_quad_size()
		state.render_clipmap_inner_quad_size = _ocean_mesh.get_clipmap_inner_quad_size()
		state.render_clipmap_ring_vertex_count = _ocean_mesh.get_clipmap_ring_vertex_count()
		state.render_clipmap_ring_count = _ocean_mesh.get_clipmap_ring_count()
		state.render_projected_grid_dim = _ocean_mesh.get_projected_grid_dim()
		state.render_projected_grid_overscan = _ocean_mesh.get_projected_grid_overscan()
	state.height_query = Callable(self, "sample_water_height")
	state.displacement_query = Callable(self, "sample_water_displacement")
	state.normal_query = Callable(self, "sample_water_normal")
	state.gradient_query = Callable(self, "sample_water_gradient")
	state.velocity_query = Callable(self, "sample_water_velocity")
	state.base_velocity_query = Callable(self, "sample_base_water_velocity")
	state.coverage_query = Callable(self, "sample_water_coverage")
	state.signed_shore_distance_query = Callable(self, "sample_signed_water_shore_distance")
	state.shore_side_query = Callable(self, "sample_water_shore_side")
	state.water_body_id_query = Callable(self, "sample_water_body_id_at")
	state.surface_query = Callable(self, "sample_water_surface_query")
	state.shore_mask_rd = _active_shore_mask_rd
	return state


func get_fft_cascade_count() -> int:
	return _cascade_parameters.size()


func set_terrain(terrain: Terrain3D) -> void:
	_terrain = terrain
	if not _system_enabled:
		return
	_load_shore_mask()


func regenerate_shore_mask() -> void:
	if not _system_enabled:
		return
	if _shore_mask and _terrain:
		_shore_mask.generate_from_terrain(_terrain, shore_mask_resolution, shore_fade_distance, sea_level)
		_set_active_shore_mask(
			_shore_mask.get_shore_mask_texture(),
			_shore_mask.get_world_bounds(),
			shore_fade_distance,
			_shore_mask.get_shore_mask_image()
		)


func set_enabled(enabled: bool) -> void:
	if enabled:
		_system_enabled = true
		_enabled = true
		set_process(true)
		set_physics_process(true)
		if not _system_initialized:
			force_initialize()
			return
		if _ocean_mesh:
			_ocean_mesh.visible = true
	else:
		_enabled = false
		_system_enabled = false
		set_process(false)
		set_physics_process(false)
		release_runtime_resources()


func get_time() -> float:
	return _time


func set_wave_scale(value: float) -> void:
	wave_scale = clampf(value, 0.0, 3.0)
	if _ocean_mesh:
		_ocean_mesh.set_wave_scale(wave_scale)
	if _ocean_spray:
		_ocean_spray.set_wave_scale(wave_scale)
	if _underwater_particulates:
		_underwater_particulates.sync_from_water_state(get_water_surface_state())
	_push_surface_motion_uniforms()


func get_ocean_mesh() -> OceanMesh:
	return _ocean_mesh


func get_wave_scale() -> float:
	return wave_scale


func get_map_scales() -> PackedVector4Array:
	return _current_map_scales


func get_cascade_parameters() -> Array[WaveCascadeParameters]:
	return _cascade_parameters


func get_displacement_cpu_per_cascade() -> Array[PackedByteArray]:
	return _displacement_cpu_per_cascade


func get_shore_wave_amplitude() -> float:
	return _current_shore_wave_amplitude


func sync_water_interaction_texture(
	texture: Texture2D,
	bounds: Vector4,
	active: bool,
	debug_enabled: bool = false,
	body_atlas_texture: Texture2D = null,
	body_atlas_bounds: Vector4 = Vector4.ZERO,
	body_atlas_available: bool = false,
	_dynamic_flow_texture: Texture2D = null,
	_dynamic_flow_bounds: Vector4 = Vector4.ZERO,
	_dynamic_flow_active: bool = false
) -> void:
	if _ocean_mesh == null:
		return
	_ocean_mesh.set_water_interaction_texture(texture, bounds, active)
	if _ocean_mesh.has_method("set_water_interaction_surface_height"):
		_ocean_mesh.call("set_water_interaction_surface_height", sea_level)
	if _ocean_mesh.has_method("set_water_body_atlas_texture"):
		_ocean_mesh.call(
			"set_water_body_atlas_texture",
			body_atlas_texture,
			body_atlas_bounds,
			body_atlas_available
		)
	_ocean_mesh.set_water_interaction_debug_enabled(debug_enabled)


func get_ocean_spray() -> OceanSpray:
	return _ocean_spray


func set_sea_spray_enabled(enabled: bool) -> void:
	sea_spray_enabled = enabled
	if _ocean_spray:
		_ocean_spray.enabled = enabled


func toggle_sea_spray() -> bool:
	set_sea_spray_enabled(not sea_spray_enabled)
	return sea_spray_enabled


func is_sea_spray_enabled() -> bool:
	return sea_spray_enabled


func set_sea_spray_quality(quality: int) -> void:
	sea_spray_quality = clampi(quality, 0, 3)
	if _ocean_spray:
		_ocean_spray.quality_tier = sea_spray_quality as OceanSpray.QualityTier


func get_sea_spray_quality() -> int:
	return sea_spray_quality


func get_sea_spray_quality_name() -> String:
	match sea_spray_quality:
		0:
			return "Off"
		1:
			return "Low"
		2:
			return "Medium"
		3:
			return "High"
	return "Unknown"


func get_sea_spray_energy() -> float:
	if _ocean_spray:
		return _ocean_spray.get_weather_energy()
	return 0.0


func get_sea_spray_status() -> Dictionary:
	var status := {
		"enabled": sea_spray_enabled,
		"quality": sea_spray_quality,
		"quality_name": get_sea_spray_quality_name(),
		"initialized": _ocean_spray != null,
		"emitting": false,
		"particle_candidates": 0,
		"weather_energy": 0.0,
		"wind_strength": _weather_last_wind_t,
		"has_fft": _wave_generator != null and _ocean_mesh != null and _ocean_mesh.get_quality() == OceanMesh.QualityMode.HIGH,
	}
	if _ocean_spray:
		status.merge(_ocean_spray.get_runtime_status(), true)
		status["quality_name"] = get_sea_spray_quality_name()
	return status


func set_sea_spray_render_layers(mask: int) -> void:
	if _ocean_spray:
		_ocean_spray.set_render_layers(mask)


func set_underwater_particles_enabled(enabled: bool) -> void:
	underwater_particles_enabled = enabled
	if _underwater_particulates:
		_underwater_particulates.enabled = enabled


func is_underwater_particles_enabled() -> bool:
	return underwater_particles_enabled


func set_underwater_particles_quality(quality: int) -> void:
	underwater_particles_quality = clampi(quality, 0, 3)
	if _underwater_particulates:
		_underwater_particulates.quality_tier = underwater_particles_quality as UnderwaterParticulates.QualityTier
		underwater_particles_count = _underwater_particulates.particle_count


func get_underwater_particles_quality() -> int:
	return underwater_particles_quality


func get_underwater_particles_quality_name() -> String:
	match underwater_particles_quality:
		0:
			return "Off"
		1:
			return "Low"
		2:
			return "Medium"
		3:
			return "High"
	return "Unknown"


func set_underwater_particles_opacity(value: float) -> void:
	underwater_particles_opacity = clampf(value, 0.0, 2.0)
	if _underwater_particulates:
		_underwater_particulates.opacity = underwater_particles_opacity


func set_underwater_particles_count(value: int) -> void:
	underwater_particles_count = clampi(value, 0, 8192)
	if _underwater_particulates:
		_underwater_particulates.particle_count = underwater_particles_count


func set_underwater_particles_size_scale(value: float) -> void:
	underwater_particles_size_scale = clampf(value, 0.25, 4.0)
	if _underwater_particulates:
		_underwater_particulates.size_scale = underwater_particles_size_scale


func set_underwater_particles_speed_scale(value: float) -> void:
	underwater_particles_speed_scale = clampf(value, 0.0, 4.0)
	if _underwater_particulates:
		_underwater_particulates.speed_scale = underwater_particles_speed_scale


func get_underwater_particles_status() -> Dictionary:
	var status := {
		"enabled": underwater_particles_enabled,
		"quality": underwater_particles_quality,
		"quality_name": get_underwater_particles_quality_name(),
		"initialized": _underwater_particulates != null,
		"visible": false,
		"emitting": false,
		"particle_count": underwater_particles_count,
		"opacity": underwater_particles_opacity,
		"size_scale": underwater_particles_size_scale,
		"speed_scale": underwater_particles_speed_scale,
		"camera_water_depth": 0.0,
	}
	if _underwater_particulates:
		status.merge(_underwater_particulates.get_runtime_status(), true)
		status["quality_name"] = get_underwater_particles_quality_name()
	return status


func set_underwater_particles_render_layers(mask: int) -> void:
	if _underwater_particulates:
		_underwater_particulates.set_render_layers(mask)


func get_shore_mask_generator() -> ShoreMaskGenerator:
	return _shore_mask


func is_system_enabled() -> bool:
	return _system_enabled


func is_initialized() -> bool:
	return _system_initialized


func set_ocean_surface_visible(enabled: bool) -> void:
	if _ocean_mesh != null:
		_ocean_mesh.visible = enabled
	if _ocean_spray != null:
		_ocean_spray.visible = enabled


func toggle_ocean() -> bool:
	if _system_enabled and _system_initialized:
		set_enabled(false)
		_system_enabled = false
		Log.info("water", "OceanFFTProvider: Ocean disabled")
	else:
		if not _system_initialized:
			force_initialize()
		set_enabled(true)
		Log.info("water", "OceanFFTProvider: Ocean enabled (mode: %s)" % get_water_quality_name())
	return _system_enabled


static func is_hardware_suitable() -> bool:
	HardwareDetection.detect()
	var quality := HardwareDetection.get_recommended_quality()
	return quality != HardwareDetection.WaterQuality.ULTRA_LOW


func force_initialize() -> void:
	if _system_initialized:
		return
	Log.info("water", "OceanFFTProvider: Force initializing ocean system...")
	_system_enabled = true

	if not _ocean_mesh:
		_ocean_mesh = OceanMesh.new()
		_ocean_mesh.name = "OceanMesh"
		add_child(_ocean_mesh)

	if not _shore_mask:
		_shore_mask = ShoreMaskGenerator.new()
		_shore_mask.name = "ShoreMaskGenerator"
		add_child(_shore_mask)

	_deferred_init()

	if _ocean_mesh:
		_ocean_mesh.visible = true


func release_runtime_resources() -> void:
	_system_enabled = false
	_enabled = false
	set_process(false)
	set_physics_process(false)
	_dispose_spray_layer()
	_dispose_underwater_particulates_layer()
	_dispose_water_interaction_layer()
	_shutdown_fft_pipeline()
	_dispose_ocean_mesh()
	if _shore_mask:
		_shore_mask.queue_free()
		_shore_mask = null
	_cached_directional_lights.clear()
	_system_initialized = false


func _dispose_ocean_mesh() -> void:
	var old_mesh := _ocean_mesh
	_ocean_mesh = null
	if old_mesh == null:
		return
	old_mesh.visible = false
	if old_mesh.has_method("clear_runtime_textures"):
		old_mesh.call("clear_runtime_textures")
	if old_mesh.get_parent() == self:
		remove_child(old_mesh)
	old_mesh.queue_free()


func get_water_quality() -> OceanMesh.QualityMode:
	if _ocean_mesh:
		return _ocean_mesh.get_quality()
	return OceanMesh.QualityMode.HIGH


## Rebuild the ocean mesh in a different mesh mode (CLIPMAP ↔ PROJECTED) at
## runtime. Tears down the existing OceanMesh, re-creates it fresh, and
## re-connects the FFT pipeline to the new material. Used by the buoyancy
## debug scene for A/B comparison between the two vertex paths.
##
## FFT cascade state is preserved across the rebuild because the WaveGenerator
## lives on OceanFFTProvider, not on OceanMesh — only the shader material and
## mesh topology get replaced.
func rebuild_mesh_with_mode(new_mode: int) -> void:
	if not _system_enabled:
		return
	if new_mode < 0 or new_mode > 1:
		Log.warn("water", "OceanFFTProvider: rebuild_mesh_with_mode — invalid mode %d, ignoring" % new_mode)
		return
	if _ocean_mesh and _ocean_mesh.get_mesh_mode() == new_mode:
		Log.info("water", "OceanFFTProvider: already in requested mesh mode, no-op")
		return

	water_mesh_mode = new_mode

	_dispose_ocean_mesh()

	_ocean_mesh = OceanMesh.new()
	_ocean_mesh.name = "OceanMesh"
	add_child(_ocean_mesh)
	_ocean_mesh.initialize(ocean_radius, water_quality, water_mesh_mode)
	_ocean_mesh.set_surface_shader_mode(_surface_shader_mode)
	water_mesh_mode = _ocean_mesh.get_mesh_mode()

	# Re-push shader parameters, shore mask, and FFT cascade state to the
	# fresh material.
	_update_shader_parameters()
	_load_shore_mask()
	if _ocean_mesh.get_quality() == OceanMesh.QualityMode.HIGH and _wave_generator:
		_update_cascade_scales()
	_setup_spray_layer()
	_setup_underwater_particulates_layer()
	_setup_water_interaction_layer()
	_sync_water_interaction_to_renderers()
	if _ocean_spray:
		_ocean_spray.set_fft_available(_wave_generator != null and _ocean_mesh.get_quality() == OceanMesh.QualityMode.HIGH)
	reset_weather()

	Log.info("water", "OceanFFTProvider: rebuilt ocean mesh in mode %s" % (
		"PROJECTED" if water_mesh_mode == 1 else "CLIPMAP"))


func get_mesh_mode() -> int:
	if _ocean_mesh:
		return _ocean_mesh.get_mesh_mode()
	return water_mesh_mode


func get_surface_shader_mode() -> int:
	if _ocean_mesh:
		return _ocean_mesh.get_surface_shader_mode()
	return _surface_shader_mode


func get_surface_shader_mode_name() -> String:
	if _ocean_mesh:
		return _ocean_mesh.get_surface_shader_mode_name()
	return "Boujie High" if _surface_shader_mode == OceanMesh.SurfaceShaderMode.BOUJIE_EXPERIMENTAL else "Default"


func set_surface_shader_mode(mode: int) -> void:
	_surface_shader_mode = clampi(
		mode,
		OceanMesh.SurfaceShaderMode.DEFAULT,
		OceanMesh.SurfaceShaderMode.BOUJIE_EXPERIMENTAL
	)
	if not _system_enabled or not _ocean_mesh:
		return
	var changed := _ocean_mesh.set_surface_shader_mode(_surface_shader_mode)
	if not changed:
		return
	_update_shader_parameters()
	if _active_shore_mask_texture != null:
		_ocean_mesh.set_shore_mask(_active_shore_mask_texture, _active_shore_mask_bounds, _active_shore_fade_distance)
	else:
		_load_shore_mask()
	if _ocean_mesh.get_quality() == OceanMesh.QualityMode.HIGH and _wave_generator:
		_update_cascade_scales()
	_push_current_absorption_to_material()
	_push_surface_ssr_to_material()
	_push_surface_motion_uniforms()
	_push_ocean_time_uniform()
	_sync_water_interaction_to_renderers()
	_update_sun_uniform()


func set_water_quality(quality: int) -> void:
	water_quality = _normalize_water_quality_id(quality)
	if not _system_enabled or not _ocean_mesh:
		return

	var target_quality: OceanMesh.QualityMode
	if water_quality == 0:
		target_quality = OceanMesh.QualityMode.FLAT
	elif water_quality < 0:
		HardwareDetection.detect()
		target_quality = OceanMesh.QualityMode.HIGH if HardwareDetection.get_recommended_quality() == HardwareDetection.WaterQuality.HIGH else OceanMesh.QualityMode.FLAT
	else:
		target_quality = OceanMesh.QualityMode.HIGH

	_ocean_mesh.set_quality(target_quality, ocean_radius)

	# Start/stop FFT pipeline as needed
	if target_quality == OceanMesh.QualityMode.HIGH and not _wave_generator:
		_init_fft_pipeline()
		_setup_spray_layer()
		_setup_underwater_particulates_layer()
	elif target_quality != OceanMesh.QualityMode.HIGH and _wave_generator:
		_shutdown_fft_pipeline()
	if _ocean_spray:
		_ocean_spray.set_fft_available(_wave_generator != null and _ocean_mesh.get_quality() == OceanMesh.QualityMode.HIGH)
	_update_shader_parameters()
	_load_shore_mask()
	if _ocean_mesh.get_quality() == OceanMesh.QualityMode.HIGH and _wave_generator:
		_update_cascade_scales()
	_sync_water_interaction_to_renderers()
	reset_weather()

	Log.info("water", "OceanFFTProvider: Quality changed to: %s" % get_water_quality_name())


func get_water_quality_name() -> String:
	if _ocean_mesh:
		match _ocean_mesh.get_quality():
			OceanMesh.QualityMode.HIGH:
				return "High (FFT)"
			_:
				return "Flat"
	return "Unknown"


# ============================================================================
# WEATHER INTEGRATION
# ============================================================================

## Apply weather state to ocean parameters.
## Called each frame when both weather and ocean are active.
## Guards against redundant FFT spectrum regeneration via epsilon checks.
## User-facing choppiness override. 0 = long smooth aligned swell,
## 1 = chaotic omnidirectional chop. Writes `swell` + `spread` on every
## cascade and regenerates the FFT spectrum. UI is the single source of
## truth — automated weather still applies its own swell/spread through
## `_apply_weather_fft`, this method stacks on top when the user moves the
## slider (the next weather change will overwrite, which is intentional).
func set_choppiness(value: float) -> void:
	if _cascade_parameters.is_empty():
		return
	var v: float = clampf(value, 0.0, 1.0)
	# swell 1.0 (elongated aligned swell) → 0.3 (broken messy)
	var swell_val: float = lerpf(1.0, 0.3, v)
	# spread 0.05 (tight directional) → 0.6 (omnidirectional)
	var spread_val: float = lerpf(0.05, 0.6, v)
	for cascade: WaveCascadeParameters in _cascade_parameters:
		cascade.swell = swell_val
		cascade.spread = spread_val
	if _physics_evaluator:
		_physics_evaluator.init_from_cascades(_cascade_parameters, fft_map_size)


## User-facing wind strength override. 0 = calm, 1 = full storm. Updates
## per-cascade `wind_speed` + `displacement_scale` without touching the
## weather system. Called by `WeatherControls.on_wind_strength_changed`.
func set_wind_strength(value: float) -> void:
	if _cascade_parameters.is_empty():
		return
	var v: float = clampf(value, 0.0, 1.0)
	var ocean_wind: float = lerpf(2.0, 30.0, v)
	var disp_scale: float = lerpf(0.1, 1.0, v)
	_current_ocean_wind_speed_mps = ocean_wind
	for cascade: WaveCascadeParameters in _cascade_parameters:
		cascade.wind_speed = ocean_wind
		cascade.displacement_scale = disp_scale
	# Push the new displacement scale into the shader uniform — see the
	# long comment in `_apply_weather_fft` for why this is critical.
	_update_cascade_scales()
	if _physics_evaluator:
		_physics_evaluator.init_from_cascades(_cascade_parameters, fft_map_size)
	_weather_last_wind_t = v
	_push_surface_motion_uniforms()
	_update_spray_weather(_weather_last_wind_t, _weather_last_wind_dir_xz)


func apply_weather(result: WeatherTypes.WeatherResult) -> void:
	if not _system_enabled or not _enabled:
		return

	# Normalize MW wind range (0.0-0.9) to 0-1
	var wind_t: float = clampf(result.wind_speed / 0.9, 0.0, 1.0)
	var wind_dir_xz := Vector2(result.storm_direction.x, result.storm_direction.z)
	if wind_dir_xz.length_squared() < 0.0001:
		wind_dir_xz = Vector2(1.0, 1.0)
	wind_dir_xz = wind_dir_xz.normalized()
	_weather_last_wind_t = wind_t
	_weather_last_wind_dir_xz = wind_dir_xz
	_current_ocean_wind_speed_mps = lerpf(2.0, 30.0, wind_t)

	# FFT mode — update cascade parameters (only when wind actually changes)
	if _cascade_parameters.size() > 0:
		var wind_changed: bool = absf(result.wind_speed - _weather_last_wind) > 0.01
		var dir_changed: bool = result.storm_direction.distance_squared_to(_weather_last_storm_dir) > 0.01
		if wind_changed or dir_changed:
			_apply_weather_fft(result, wind_t)
			_weather_last_wind = result.wind_speed
			_weather_last_storm_dir = result.storm_direction

	# All modes — update shader material uniforms (cheap, safe every frame)
	_apply_weather_shader(result, wind_t)
	_update_spray_weather(wind_t, wind_dir_xz)


func _apply_weather_fft(result: WeatherTypes.WeatherResult, wind_t: float) -> void:
	# Map MW wind (0.0-0.9) to ocean wind speed (2-30 m/s)
	# Clear (0.1) → ~3 m/s lake-calm, Storm (0.5) → ~20 m/s, Blizzard (0.9) → 30 m/s
	var ocean_wind: float = lerpf(2.0, 30.0, wind_t)

	# Wind direction from storm direction or default NE wind
	var wind_dir_deg: float = 45.0
	if result.storm_direction.length_squared() > 0.01:
		wind_dir_deg = rad_to_deg(atan2(result.storm_direction.x, result.storm_direction.z))

	# Displacement scale — calm water has very gentle waves (lake-like)
	var disp_scale: float = lerpf(0.1, 1.0, wind_t)
	# Less foam in calm weather, more in storms
	var foam_base: float = lerpf(0.5, 8.0, wind_t)
	# Higher whitecap threshold in calm = almost no foam
	var whitecap_val: float = lerpf(0.8, 0.2, wind_t)
	# More directional spreading in storms (choppier, less aligned)
	var spread_val: float = lerpf(0.15, 0.5, wind_t)
	# Calm swell is elongated and gentle
	var swell_val: float = lerpf(0.9, 0.5, wind_t)

	for cascade: WaveCascadeParameters in _cascade_parameters:
		cascade.wind_speed = ocean_wind
		cascade.wind_direction = wind_dir_deg
		cascade.displacement_scale = disp_scale
		cascade.foam_amount = foam_base
		cascade.whitecap = whitecap_val
		cascade.spread = spread_val
		cascade.swell = swell_val
	_current_ocean_wind_speed_mps = ocean_wind

	# CRITICAL — push the new per-cascade `displacement_scale` into the
	# shader's `map_scales[i].z` uniform. Without this the shader keeps
	# using whatever scale was active at `_init_fft_pipeline()` (the
	# calm defaults ~0.1-0.15) while the CPU buoyancy sampler correctly
	# tracks the runtime value. Result: buoyant bodies hover 5-10× above
	# the visible mesh in stormy weather. Diagnosed 2026-04-09 via
	# `tests/visual/test_buoyancy_debug.tscn` SAMPLER DUMP.
	_update_cascade_scales()

	# Also update CPU-side physics evaluator to match
	if _physics_evaluator:
		_physics_evaluator.init_from_cascades(_cascade_parameters, fft_map_size)

	Log.debug("water", "Weather→Ocean: wind=%.1f m/s dir=%.0f° foam=%.1f whitecap=%.2f disp=%.2f" % [
		ocean_wind, wind_dir_deg, foam_base, whitecap_val, disp_scale])


## Water colors — dark and desaturated, Morrowind-matched. Visual character comes from
## reflections (probe/sky), not albedo. Bright/turquoise water = wrong.
const _SHALLOW_CALM := Color(0.09, 0.12, 0.13)
const _SHALLOW_STORM := Color(0.06, 0.08, 0.09)
const _DEEP_CALM := Color(0.02, 0.04, 0.06)
const _DEEP_STORM := Color(0.01, 0.02, 0.03)
const _SURFACE_ABSORPTION_RATE := Vector3(0.4, 0.1, 0.06)
const _SURFACE_ABSORPTION_DENSITY_DEFAULT := 0.2
const _SURFACE_EXTINCTION_BIAS := Vector3(1.0, 0.25, 0.15)

var _optical_profile: WaterOpticalProfile = WaterOpticalProfile.new()
var _current_absorption_tint := Vector3(_DEEP_CALM.r, _DEEP_CALM.g, _DEEP_CALM.b)
var _current_absorption_sigma := _SURFACE_ABSORPTION_RATE * _SURFACE_ABSORPTION_DENSITY_DEFAULT
var _current_underwater_caustics_strength: float = 1.0
var _surface_ssr_enabled: bool = true
var _surface_absorption_density: float = _SURFACE_ABSORPTION_DENSITY_DEFAULT
var _absorption_tint_override_enabled: bool = false
var _absorption_tint_override: Color = _DEEP_CALM
var _optical_color_override_enabled: bool = false

func _apply_weather_shader(result: WeatherTypes.WeatherResult, wind_t: float) -> void:
	if not _ocean_mesh:
		return
	var mat: ShaderMaterial = _ocean_mesh.get_material()
	if not mat:
		return

	# Water color darkens and desaturates in storms (driven by cloud coverage)
	var storm_t: float = clampf(result.cloud_coverage, 0.0, 1.0)
	var shallow_col: Color = _SHALLOW_CALM.lerp(_SHALLOW_STORM, storm_t)
	var deep_col: Color = _resolve_absorption_tint(_DEEP_CALM.lerp(_DEEP_STORM, storm_t))
	if not _optical_color_override_enabled:
		_optical_profile.set_medium_color(deep_col)
	_sync_optical_cache_from_profile()
	_current_underwater_caustics_strength = lerpf(1.0, 0.35, storm_t)
	mat.set_shader_parameter("color_shallow", Vector3(shallow_col.r, shallow_col.g, shallow_col.b))
	mat.set_shader_parameter("color_deep", _current_absorption_tint)
	_push_surface_optical_uniforms(mat)
	_push_surface_motion_uniforms(mat)
	mat.set_shader_parameter("refraction_weather_visibility", _weather_refraction_visibility(result, wind_t))

	# Shore foam — minimal in calm, wide in storms
	mat.set_shader_parameter("foam_edge_width", lerpf(0.1, 1.5, wind_t))

	# Normal strength — gentle in calm, choppy in storms
	mat.set_shader_parameter("normal_strength", lerpf(0.6, 1.6, wind_t))

	# Calm water reflects more sky, storms reflect less (sky obscured by clouds)
	mat.set_shader_parameter("sky_tint_strength", lerpf(0.8, 0.3, wind_t))

	# Foam suppression: near-zero in calm weather, full in storms
	mat.set_shader_parameter("foam_intensity", lerpf(0.05, 1.0, wind_t))

	# Shore waves — calm: gentle lapping, storm: strong rollers
	_current_shore_wave_amplitude = lerpf(0.18, 2.2, wind_t)
	mat.set_shader_parameter("shore_wave_amplitude", _current_shore_wave_amplitude)
	_push_shore_wave_timing_uniforms(mat)
	_current_shore_wave_steepness = lerpf(0.58, 0.98, wind_t)
	mat.set_shader_parameter("shore_wave_steepness", _current_shore_wave_steepness)

	# FFT-specific uniforms
	if _ocean_mesh.get_quality() == OceanMesh.QualityMode.HIGH:
		# Calm water is glassy smooth, storms are rough
		mat.set_shader_parameter("roughness", lerpf(0.01, 0.15, wind_t))
		# 2026-04-10 (r2) — SSS is a choppiness-driven ALBEDO blend. Stormy
		# weather has more choppiness → more sharp crests → more scatter, but
		# the peak mask (scatter_choppiness_min/max in the shader) now requires
		# actual sharp tips so we keep the master strength modest; the peak
		# mask does the "only fire on real crests" selection. Previous 0.9→1.5
		# combined with the old low-threshold mask was producing flat patches
		# of green across the whole horizon.
		mat.set_shader_parameter("sss_strength", lerpf(0.8, 1.25, wind_t))
		mat.set_shader_parameter("sss_emission_strength", lerpf(0.45, 0.85, wind_t))


func _push_surface_optical_uniforms(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("absorption_rate", _SURFACE_ABSORPTION_RATE)
	mat.set_shader_parameter("absorption_density", _surface_absorption_density)
	mat.set_shader_parameter("extinction_sigma", _current_absorption_sigma)
	mat.set_shader_parameter("medium_color", _current_absorption_tint)
	mat.set_shader_parameter("visibility_distance_m", _optical_profile.visibility_distance_m)
	mat.set_shader_parameter("ssr_enabled", _surface_ssr_enabled)


func _push_current_absorption_to_material() -> void:
	if _ocean_mesh == null:
		return
	var mat: ShaderMaterial = _ocean_mesh.get_material()
	if mat == null:
		return
	mat.set_shader_parameter("color_deep", _current_absorption_tint)
	_push_surface_optical_uniforms(mat)


func _push_surface_ssr_to_material() -> void:
	if _ocean_mesh == null:
		return
	var mat: ShaderMaterial = _ocean_mesh.get_material()
	if mat == null:
		return
	mat.set_shader_parameter("ssr_enabled", _surface_ssr_enabled)


func _resolve_absorption_tint(weather_deep: Color) -> Color:
	return _absorption_tint_override if _absorption_tint_override_enabled else weather_deep


func _sync_optical_cache_from_profile() -> void:
	var turbidity := clampf(_optical_profile.scattering_strength, 0.0, 1.0)
	_optical_profile.extinction_color_bias = _SURFACE_EXTINCTION_BIAS.lerp(Vector3(1.0, 1.0, 1.0), turbidity)
	_current_absorption_tint = _optical_profile.get_medium_color()
	_current_absorption_sigma = _optical_profile.get_extinction_sigma()
	_surface_absorption_density = _legacy_density_from_visibility(_optical_profile.visibility_distance_m)


static func _weather_refraction_visibility(result: WeatherTypes.WeatherResult, wind_t: float) -> float:
	var precipitation_t := maxf(result.rain_intensity, maxf(result.snow_intensity, result.storm_intensity))
	var storm_fog_t := clampf((result.storm_fog_multiplier - 1.0) / 4.0, 0.0, 1.0)
	var depth_fog_t := clampf(result.depth_fog_density / 0.0012, 0.0, 1.0)
	var weather_obscurance := maxf(
		wind_t * 0.45,
		maxf(
			result.cloud_coverage * 0.25,
			maxf(precipitation_t * 0.65, maxf(storm_fog_t * 0.80, depth_fog_t * 0.50))
		)
	)
	return lerpf(1.0, 0.25, weather_obscurance)


static func _visibility_from_legacy_density(density: float) -> float:
	var safe_density := maxf(density, 0.001)
	return clampf(
		-log(WaterOpticalProfile.TARGET_TRANSMITTANCE) / (_SURFACE_ABSORPTION_RATE.x * safe_density),
		WaterOpticalProfile.MIN_VISIBILITY_M,
		WaterOpticalProfile.MAX_VISIBILITY_M
	)


static func _legacy_density_from_visibility(visibility_distance_m: float) -> float:
	var safe_visibility := maxf(visibility_distance_m, WaterOpticalProfile.MIN_VISIBILITY_M)
	return clampf(
		-log(WaterOpticalProfile.TARGET_TRANSMITTANCE) / (_SURFACE_ABSORPTION_RATE.x * safe_visibility),
		0.01,
		2.0
	)


func _push_shore_wave_timing_uniforms(mat: ShaderMaterial) -> void:
	_current_shore_wave_frequency = SHORE_WAVE_SPATIAL_FREQUENCY
	_current_shore_wave_speed = _shore_wave_temporal_frequency(SHORE_WAVE_SPATIAL_FREQUENCY)
	mat.set_shader_parameter("shore_wave_frequency", _current_shore_wave_frequency)
	mat.set_shader_parameter("shore_wave_speed", _current_shore_wave_speed)


static func _shore_wave_temporal_frequency(spatial_frequency: float) -> float:
	var k: float = maxf(spatial_frequency, 0.001) * TAU
	var omega: float = sqrt(GRAVITY * k * tanh(k * SHORE_WAVE_REFERENCE_DEPTH))
	return omega / TAU


## Reset ocean to calm defaults (call when weather system is disabled)
func reset_weather() -> void:
	_weather_last_wind = -1.0
	_weather_last_storm_dir = Vector3.ZERO

	if not _ocean_mesh:
		return
	var mat: ShaderMaterial = _ocean_mesh.get_material()
	if not mat:
		return

	var deep_col := _resolve_absorption_tint(_DEEP_CALM)
	if not _optical_color_override_enabled:
		_optical_profile.set_medium_color(deep_col)
	_sync_optical_cache_from_profile()
	_current_underwater_caustics_strength = 1.0
	mat.set_shader_parameter("color_shallow", Vector3(_SHALLOW_CALM.r, _SHALLOW_CALM.g, _SHALLOW_CALM.b))
	mat.set_shader_parameter("color_deep", _current_absorption_tint)
	_push_surface_optical_uniforms(mat)
	mat.set_shader_parameter("refraction_weather_visibility", 1.0)
	mat.set_shader_parameter("foam_edge_width", 0.1)
	mat.set_shader_parameter("foam_intensity", 0.05)
	mat.set_shader_parameter("sky_tint_strength", 0.8)
	mat.set_shader_parameter("normal_strength", 0.6)
	mat.set_shader_parameter("wave_scale", wave_scale)
	_current_shore_wave_amplitude = 0.18
	mat.set_shader_parameter("shore_wave_amplitude", _current_shore_wave_amplitude)
	_push_shore_wave_timing_uniforms(mat)
	_current_shore_wave_steepness = 0.58
	mat.set_shader_parameter("shore_wave_steepness", _current_shore_wave_steepness)

	if _ocean_mesh.get_quality() == OceanMesh.QualityMode.HIGH:
		mat.set_shader_parameter("roughness", 0.01)
		mat.set_shader_parameter("sss_strength", 0.8)
		mat.set_shader_parameter("sss_emission_strength", 0.45)

	# Reset FFT cascades to calm/lake defaults
	for cascade: WaveCascadeParameters in _cascade_parameters:
		cascade.wind_speed = 2.0
		cascade.wind_direction = 45.0
		cascade.displacement_scale = 0.1
		cascade.foam_amount = 0.5
		cascade.whitecap = 0.8
		cascade.spread = 0.15
		cascade.swell = 0.9

	# Push the reset displacement_scale into the shader so the visible
	# mesh matches — same bug as `_apply_weather_fft` above.
	_update_cascade_scales()

	if _physics_evaluator and _cascade_parameters.size() > 0:
		_physics_evaluator.init_from_cascades(_cascade_parameters, fft_map_size)

	_weather_last_wind_t = 0.0
	_weather_last_wind_dir_xz = Vector2(1.0, 1.0).normalized()
	_current_ocean_wind_speed_mps = 2.0
	_push_surface_motion_uniforms(mat)
	_update_spray_weather(_weather_last_wind_t, _weather_last_wind_dir_xz)

	Log.info("water", "Ocean weather reset to calm defaults")


func _update_spray_weather(wind_t: float, wind_dir_xz: Vector2) -> void:
	if _ocean_spray:
		_ocean_spray.enabled = sea_spray_enabled
		_ocean_spray.quality_tier = clampi(sea_spray_quality, 0, 3) as OceanSpray.QualityTier
		_ocean_spray.set_weather(wind_t, wind_dir_xz)
	if _underwater_particulates:
		_underwater_particulates.set_current(wind_t, wind_dir_xz)


func _exit_tree() -> void:
	if Engine.has_meta("_quitting"):
		return
	set_world_water_provider(null)
	_dispose_spray_layer()
	_dispose_underwater_particulates_layer()
	# Clean up FFT RIDs to avoid exit-time leaks
	_shutdown_fft_pipeline()


func is_integrated_gpu() -> bool:
	return HardwareDetection.is_integrated_gpu()


func get_gpu_name() -> String:
	return HardwareDetection.get_gpu_name()
