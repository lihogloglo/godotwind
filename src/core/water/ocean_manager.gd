## OceanManager - Main coordinator for the ocean water system
## Manages ocean mesh, shore dampening, FFT compute pipeline, and buoyancy queries.
## Buoyancy uses OceanPhysicsEvaluator (FFT-synced) in HIGH mode, GerstnerMath fallback in STANDARD.
## Autoload singleton: accessible via OceanManager global
## OPTIONAL SYSTEM - Can be completely disabled via project settings
class_name OceanManagerClass
extends Node

const CS := preload("res://src/core/coordinate_system.gd")

# Project settings paths
const SETTING_ENABLED := "ocean/enabled"
const SETTING_SEA_LEVEL := "ocean/sea_level"
const SETTING_RADIUS := "ocean/radius"
const SETTING_QUALITY := "ocean/quality"

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

# Quality settings
@export_group("Quality Settings")
## Water quality: -1 = auto, 0 = flat, 1 = standard (Gerstner), 2 = high (FFT)
@export_range(-1, 2) var water_quality: int = -1

# FFT settings
@export_group("FFT Settings")
## FFT map resolution (power of 2: 128, 256, 512)
@export_enum("128:128", "256:256", "512:512") var fft_map_size: int = 256
## FFT update rate (Hz) — 0 = every frame
@export_range(0, 60) var fft_updates_per_second: float = 50.0

# Wave parameters (exposed for UI control)
@export_group("Wave Settings")
@export var wave_scale: float = 1.0

# System state
var _system_initialized: bool = false
var _system_enabled: bool = false

# Weather integration — last applied values (avoid redundant FFT spectrum regen)
var _weather_last_wind: float = -1.0
var _weather_last_storm_dir: Vector3 = Vector3.ZERO

# Internal state
var _ocean_mesh: OceanMesh = null
var _shore_mask: ShoreMaskGenerator = null
var _terrain: Terrain3D = null
var _camera: Camera3D = null
var _enabled: bool = true
var _time: float = 0.0
var _auto_find_camera: bool = true

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

# GPU readback for buoyancy (exact match with visual waves)
var _displacement_cpu: PackedByteArray  # Raw RGBA16F data from GPU
var _displacement_size: int = 0  # Map dimension (e.g., 256)
var _displacement_tile: Vector2 = Vector2.ZERO  # Tile length from cascade 0
var _readback_frame: int = 0  # Last frame we did a readback

# Signals
signal ocean_initialized()


func _ready() -> void:
	_register_project_settings()

	var is_autoload := get_parent() == get_tree().root and name == "OceanManager"
	if is_autoload:
		_system_enabled = ProjectSettings.get_setting(SETTING_ENABLED, false)
		if not _system_enabled:
			Log.info("water", "OceanManager: System disabled via project settings")
			return
	else:
		_system_enabled = true

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
			"hint_string": "-1,2,1"
		})


func _deferred_init() -> void:
	sea_level = ProjectSettings.get_setting(SETTING_SEA_LEVEL, 0.0)
	ocean_radius = ProjectSettings.get_setting(SETTING_RADIUS, 8000.0)
	water_quality = ProjectSettings.get_setting(SETTING_QUALITY, -1)

	HardwareDetection.detect()
	_find_terrain()

	_ocean_mesh.initialize(ocean_radius, water_quality)
	_update_shader_parameters()
	_load_shore_mask()

	# Initialize FFT pipeline if HIGH quality
	if _ocean_mesh.get_quality() == OceanMesh.QualityMode.HIGH:
		_init_fft_pipeline()

	_system_initialized = true
	ocean_initialized.emit()

	Log.info("water", "OceanManager: Initialized - sea level: %.1f, radius: %.0fm, mode: %s" % [
		sea_level, ocean_radius, get_water_quality_name()])


func _load_shore_mask() -> void:
	var shore_mask_loaded := false

	# Try prebaked shore mask first
	var shore_mask_path := _get_shore_mask_path()
	if use_prebaked_shore_mask and FileAccess.file_exists(shore_mask_path):
		var prebaked := ShoreMaskBaker.load_prebaked(shore_mask_path)
		if not prebaked.is_empty():
			var tex: Texture2D = prebaked.texture
			var bounds: Rect2 = prebaked.bounds
			_ocean_mesh.set_shore_mask(tex, bounds)
			shore_mask_loaded = true
			Log.info("water", "OceanManager: Using prebaked shore mask from %s" % shore_mask_path)

	# Fall back to runtime generation if terrain available
	if not shore_mask_loaded and _terrain:
		Log.info("water", "OceanManager: Generating shore mask at runtime...")
		_shore_mask.generate_from_terrain(_terrain, shore_mask_resolution, shore_fade_distance, sea_level)
		_ocean_mesh.set_shore_mask(
			_shore_mask.get_shore_mask_texture(),
			_shore_mask.get_world_bounds()
		)
		shore_mask_loaded = true

	if not shore_mask_loaded:
		Log.warn("water", "OceanManager: No shore mask available - ocean will appear everywhere")


func _process(delta: float) -> void:
	if not _system_enabled or not _enabled:
		return

	_time = Time.get_ticks_msec() / 1000.0

	# Auto-find camera
	if not _camera and _auto_find_camera:
		_camera = _find_active_camera()

	# Update ocean mesh position to follow camera
	if _camera:
		var cam_pos := _camera.global_position
		var new_pos := Vector3(cam_pos.x, sea_level, cam_pos.z)
		_ocean_mesh.update_position(new_pos)

	# Drive FFT pipeline updates (rate-limited)
	if _wave_generator and _ocean_mesh.get_quality() == OceanMesh.QualityMode.HIGH:
		_fft_time += delta
		if fft_updates_per_second == 0 or _fft_time >= _fft_next_update:
			var target_dt := 1.0 / (fft_updates_per_second + 1e-10)
			var update_dt := delta if fft_updates_per_second == 0 else target_dt + (_fft_time - _fft_next_update)
			_fft_next_update = _fft_time + target_dt
			_wave_generator.update(update_dt, _cascade_parameters)

	# GPU readback for buoyancy — read displacement map once per frame
	if _wave_generator and _displacement_size > 0:
		var frame := Engine.get_process_frames()
		if frame != _readback_frame:
			_readback_frame = frame
			_displacement_cpu = _wave_generator.read_displacement(0)  # Cascade 0 = swell


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
	cascade_0.displacement_scale = 0.8
	cascade_0.normal_scale = 0.8
	cascade_0.wind_speed = 12.0  # Calm Morrowind Inner Sea
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
	cascade_1.displacement_scale = 0.6
	cascade_1.normal_scale = 1.0
	cascade_1.wind_speed = 12.0
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

	Log.info("water", "OceanManager: FFT pipeline initialized - %d cascades, %dx%d maps" % [
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
	_ocean_mesh.get_material().set_shader_parameter(&"map_scales", map_scales)


func _shutdown_fft_pipeline() -> void:
	if _wave_generator:
		_displacement_maps.texture_rd_rid = RID()
		_normal_maps.texture_rd_rid = RID()
		_wave_generator.queue_free()
		_wave_generator = null
		_cascade_parameters.clear()
		_physics_evaluator = null
		_displacement_cpu = PackedByteArray()
		_displacement_size = 0
		Log.info("water", "OceanManager: FFT pipeline shut down")


# ============================================================================
# WAVE QUERIES — GPU readback (exact match) > OceanPhysicsEvaluator > GerstnerMath
# ============================================================================

## Get the wave height at a world position (for buoyancy)
func get_wave_height(world_pos: Vector3) -> float:
	if not _system_enabled or not _enabled:
		return sea_level

	var shore_factor := _get_shore_factor(world_pos)
	if shore_factor <= 0.01:
		return sea_level - 1000.0

	# GPU readback — exact match with visual waves
	if _displacement_cpu.size() > 0:
		var disp := _sample_displacement_readback(world_pos)
		return sea_level + disp.y * shore_factor * wave_scale

	# Fallback: CPU spectrum evaluator (approximate)
	if _physics_evaluator and _physics_evaluator._component_count > 0:
		return sea_level + _physics_evaluator.get_height(world_pos, _time, shore_factor * wave_scale)

	# Fallback: Gerstner for STANDARD mode
	var cam_pos := _camera.global_position if _camera else Vector3.ZERO
	var disp := GerstnerMath.get_displacement(world_pos, _time, shore_factor * wave_scale, cam_pos)
	return sea_level + disp.y


## Get wave displacement vector at world position
func get_wave_displacement(world_pos: Vector3) -> Vector3:
	if not _system_enabled or not _enabled:
		return Vector3.ZERO
	var shore_factor := _get_shore_factor(world_pos)

	if _displacement_cpu.size() > 0:
		var disp := _sample_displacement_readback(world_pos)
		return disp * shore_factor * wave_scale

	if _physics_evaluator and _physics_evaluator._component_count > 0:
		return _physics_evaluator.get_displacement(world_pos, _time, shore_factor * wave_scale)

	var cam_pos := _camera.global_position if _camera else Vector3.ZERO
	return GerstnerMath.get_displacement(world_pos, _time, shore_factor * wave_scale, cam_pos)


## Get wave normal at world position
func get_wave_normal(world_pos: Vector3) -> Vector3:
	if not _system_enabled or not _enabled:
		return Vector3.UP
	var shore_factor := _get_shore_factor(world_pos)

	# GPU readback normal via finite differences
	if _displacement_cpu.size() > 0:
		var eps := 1.0
		var h0 := _sample_displacement_readback(world_pos).y
		var hx := _sample_displacement_readback(world_pos + Vector3(eps, 0, 0)).y
		var hz := _sample_displacement_readback(world_pos + Vector3(0, 0, eps)).y
		var nx := (h0 - hx) * shore_factor * wave_scale
		var nz := (h0 - hz) * shore_factor * wave_scale
		return Vector3(nx, 1.0, nz).normalized()

	if _physics_evaluator and _physics_evaluator._component_count > 0:
		return _physics_evaluator.get_normal(world_pos, _time, shore_factor * wave_scale)

	var cam_pos := _camera.global_position if _camera else Vector3.ZERO
	return GerstnerMath.get_normal(world_pos, _time, shore_factor * wave_scale, cam_pos)


## Sample the GPU displacement readback data at a world position.
## Bilinear interpolation from the RGBA16F displacement map (cascade 0).
func _sample_displacement_readback(world_pos: Vector3) -> Vector3:
	if _displacement_cpu.size() == 0 or _displacement_size == 0:
		return Vector3.ZERO

	# World pos → UV in displacement map (tiling)
	var u: float = fmod(world_pos.x / _displacement_tile.x, 1.0)
	var v: float = fmod(world_pos.z / _displacement_tile.y, 1.0)
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

	var d00 := _read_displacement_texel(ix, iz)
	var d10 := _read_displacement_texel(ix1, iz)
	var d01 := _read_displacement_texel(ix, iz1)
	var d11 := _read_displacement_texel(ix1, iz1)

	return d00 * (1.0 - fx) * (1.0 - fz) + d10 * fx * (1.0 - fz) + d01 * (1.0 - fx) * fz + d11 * fx * fz


## Read a single texel from the displacement CPU buffer (RGBA16F = 8 bytes/texel).
func _read_displacement_texel(x: int, z: int) -> Vector3:
	# RGBA16F: 4 half-floats × 2 bytes = 8 bytes per texel
	var offset: int = (z * _displacement_size + x) * 8
	if offset + 7 >= _displacement_cpu.size():
		return Vector3.ZERO
	var dx: float = _displacement_cpu.decode_half(offset)
	var dy: float = _displacement_cpu.decode_half(offset + 2)
	var dz: float = _displacement_cpu.decode_half(offset + 4)
	return Vector3(dx, dy, dz)


func _get_shore_factor(world_pos: Vector3) -> float:
	if _shore_mask:
		return _shore_mask.get_shore_factor(world_pos)
	return 1.0


## Check if a position is in ocean water
func is_in_ocean(world_pos: Vector3) -> bool:
	if not _system_enabled or not _enabled:
		return false
	if world_pos.y > sea_level + 10.0:
		return false
	if _shore_mask:
		return _shore_mask.get_shore_factor(world_pos) > 0.01
	if _terrain and _terrain.data:
		var terrain_height: float = CS.get_terrain_height(world_pos, _terrain)
		return terrain_height < sea_level
	return true


# ============================================================================
# PUBLIC API
# ============================================================================

func set_camera(camera: Camera3D) -> void:
	_camera = camera
	_auto_find_camera = false


func set_sea_level(level: float) -> void:
	sea_level = level
	if not _system_enabled:
		return
	if _terrain and _shore_mask:
		_shore_mask.generate_from_terrain(_terrain, shore_mask_resolution, shore_fade_distance, sea_level)
		if _ocean_mesh:
			_ocean_mesh.set_shore_mask(
				_shore_mask.get_shore_mask_texture(),
				_shore_mask.get_world_bounds()
			)


func get_sea_level() -> float:
	return sea_level


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
		if _ocean_mesh:
			_ocean_mesh.set_shore_mask(
				_shore_mask.get_shore_mask_texture(),
				_shore_mask.get_world_bounds()
			)


func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	if _ocean_mesh:
		_ocean_mesh.visible = enabled


func get_time() -> float:
	return _time


func get_ocean_mesh() -> OceanMesh:
	return _ocean_mesh


func get_shore_mask_generator() -> ShoreMaskGenerator:
	return _shore_mask


func is_system_enabled() -> bool:
	return _system_enabled


func is_initialized() -> bool:
	return _system_initialized


func toggle_ocean() -> bool:
	if _system_enabled and _system_initialized:
		set_enabled(false)
		_system_enabled = false
		Log.info("water", "OceanManager: Ocean disabled")
	else:
		if not _system_initialized:
			force_initialize()
		set_enabled(true)
		Log.info("water", "OceanManager: Ocean enabled (mode: %s)" % get_water_quality_name())
	return _system_enabled


static func is_hardware_suitable() -> bool:
	HardwareDetection.detect()
	var quality := HardwareDetection.get_recommended_quality()
	return quality != HardwareDetection.WaterQuality.ULTRA_LOW


func force_initialize() -> void:
	if _system_initialized:
		return
	Log.info("water", "OceanManager: Force initializing ocean system...")
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


func get_water_quality() -> OceanMesh.QualityMode:
	if _ocean_mesh:
		return _ocean_mesh.get_quality()
	return OceanMesh.QualityMode.STANDARD


func set_water_quality(quality: int) -> void:
	water_quality = quality
	if not _system_enabled or not _ocean_mesh:
		return

	var old_quality := _ocean_mesh.get_quality()
	var target_quality: OceanMesh.QualityMode
	if quality == 0:
		target_quality = OceanMesh.QualityMode.FLAT
	elif quality == 1:
		target_quality = OceanMesh.QualityMode.STANDARD
	else:
		target_quality = OceanMesh.QualityMode.HIGH

	var needs_fft := _ocean_mesh.set_quality(target_quality, ocean_radius)

	# Start/stop FFT pipeline as needed
	if needs_fft and not _wave_generator:
		_init_fft_pipeline()
	elif not needs_fft and _wave_generator:
		_shutdown_fft_pipeline()

	Log.info("water", "OceanManager: Quality changed to: %s" % get_water_quality_name())


func get_water_quality_name() -> String:
	if _ocean_mesh:
		match _ocean_mesh.get_quality():
			OceanMesh.QualityMode.HIGH:
				return "High (FFT)"
			OceanMesh.QualityMode.STANDARD:
				return "Standard (Gerstner)"
			_:
				return "Flat"
	return "Unknown"


# ============================================================================
# WEATHER INTEGRATION
# ============================================================================

## Apply weather state to ocean parameters.
## Called each frame when both weather and ocean are active.
## Guards against redundant FFT spectrum regeneration via epsilon checks.
func apply_weather(result: WeatherTypes.WeatherResult) -> void:
	if not _system_enabled or not _enabled:
		return

	# Normalize MW wind range (0.0-0.9) to 0-1
	var wind_t: float = clampf(result.wind_speed / 0.9, 0.0, 1.0)

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


func _apply_weather_fft(result: WeatherTypes.WeatherResult, wind_t: float) -> void:
	# Map MW wind (0.0-0.9) to ocean wind speed (3-30 m/s)
	# Clear (0.1) → ~6 m/s gentle swell, Storm (0.5) → ~20 m/s, Blizzard (0.9) → 30 m/s
	var ocean_wind: float = lerpf(3.0, 30.0, wind_t)

	# Wind direction from storm direction or default NE wind
	var wind_dir_deg: float = 45.0
	if result.storm_direction.length_squared() > 0.01:
		wind_dir_deg = rad_to_deg(atan2(result.storm_direction.x, result.storm_direction.z))

	# Displacement scale — calm water has gentler waves
	var disp_scale: float = lerpf(0.3, 1.0, wind_t)
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

	# Also update CPU-side physics evaluator to match
	if _physics_evaluator:
		_physics_evaluator.init_from_cascades(_cascade_parameters, fft_map_size)

	Log.debug("water", "Weather→Ocean: wind=%.1f m/s dir=%.0f° foam=%.1f whitecap=%.2f" % [
		ocean_wind, wind_dir_deg, foam_base, whitecap_val])


## Calm water defaults — colors and parameters for no weather
const _SHALLOW_CALM := Color(0.1, 0.3, 0.4)
const _SHALLOW_STORM := Color(0.08, 0.18, 0.2)
const _DEEP_CALM := Color(0.02, 0.08, 0.12)
const _DEEP_STORM := Color(0.015, 0.04, 0.06)

func _apply_weather_shader(result: WeatherTypes.WeatherResult, wind_t: float) -> void:
	if not _ocean_mesh:
		return
	var mat: ShaderMaterial = _ocean_mesh.get_material()
	if not mat:
		return

	var quality: OceanMesh.QualityMode = _ocean_mesh.get_quality()

	# Water color darkens and desaturates in storms (driven by cloud coverage)
	var storm_t: float = clampf(result.cloud_coverage, 0.0, 1.0)
	var shallow_col: Color = _SHALLOW_CALM.lerp(_SHALLOW_STORM, storm_t)
	var deep_col: Color = _DEEP_CALM.lerp(_DEEP_STORM, storm_t)
	mat.set_shader_parameter("color_shallow", Vector3(shallow_col.r, shallow_col.g, shallow_col.b))
	mat.set_shader_parameter("color_deep", Vector3(deep_col.r, deep_col.g, deep_col.b))

	# Shore foam — minimal in calm, wide in storms
	mat.set_shader_parameter("foam_edge_width", lerpf(0.1, 1.5, wind_t))

	# Normal strength — gentle in calm, choppy in storms
	mat.set_shader_parameter("normal_strength", lerpf(0.6, 1.6, wind_t))

	# Wave scale for STANDARD mode (Gerstner has no runtime wind — we scale amplitude)
	if quality == OceanMesh.QualityMode.STANDARD:
		mat.set_shader_parameter("wave_scale", lerpf(0.4, 2.2, wind_t) * wave_scale)

	# FFT-specific uniforms
	if quality == OceanMesh.QualityMode.HIGH:
		# Calm water is glassy smooth, storms are rough
		mat.set_shader_parameter("roughness", lerpf(0.01, 0.15, wind_t))
		mat.set_shader_parameter("sss_strength", lerpf(0.9, 0.3, wind_t))


## Reset ocean to calm defaults (call when weather system is disabled)
func reset_weather() -> void:
	_weather_last_wind = -1.0
	_weather_last_storm_dir = Vector3.ZERO

	if not _ocean_mesh:
		return
	var mat: ShaderMaterial = _ocean_mesh.get_material()
	if not mat:
		return

	mat.set_shader_parameter("color_shallow", Vector3(_SHALLOW_CALM.r, _SHALLOW_CALM.g, _SHALLOW_CALM.b))
	mat.set_shader_parameter("color_deep", Vector3(_DEEP_CALM.r, _DEEP_CALM.g, _DEEP_CALM.b))
	mat.set_shader_parameter("foam_edge_width", 0.1)
	mat.set_shader_parameter("normal_strength", 0.6)
	mat.set_shader_parameter("wave_scale", wave_scale)

	var quality: OceanMesh.QualityMode = _ocean_mesh.get_quality()
	if quality == OceanMesh.QualityMode.HIGH:
		mat.set_shader_parameter("roughness", 0.01)
		mat.set_shader_parameter("sss_strength", 0.9)

	# Reset FFT cascades to calm defaults
	for cascade: WaveCascadeParameters in _cascade_parameters:
		cascade.wind_speed = 5.0
		cascade.wind_direction = 45.0
		cascade.displacement_scale = 0.3
		cascade.foam_amount = 0.5
		cascade.whitecap = 0.8
		cascade.spread = 0.15
		cascade.swell = 0.9

	if _physics_evaluator and _cascade_parameters.size() > 0:
		_physics_evaluator.init_from_cascades(_cascade_parameters, fft_map_size)

	Log.info("water", "Ocean weather reset to calm defaults")


func _exit_tree() -> void:
	if Engine.has_meta("_quitting"):
		return
	# Clean up FFT RIDs to avoid exit-time leaks
	_shutdown_fft_pipeline()


func is_integrated_gpu() -> bool:
	return HardwareDetection.is_integrated_gpu()


func get_gpu_name() -> String:
	return HardwareDetection.get_gpu_name()
