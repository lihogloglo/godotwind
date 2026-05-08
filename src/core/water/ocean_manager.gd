## OceanManager - Main coordinator for the ocean water system
## Manages ocean mesh, shore dampening, FFT compute pipeline, and buoyancy queries.
## Buoyancy uses OceanPhysicsEvaluator (FFT-synced) in HIGH mode; FLAT returns sea level.
## Autoload singleton: accessible via OceanManager global
## OPTIONAL SYSTEM - Can be completely disabled via project settings
class_name OceanManagerClass
extends Node

const CS := preload("res://src/core/coordinate_system.gd")
const OceanSprayScript := preload("res://src/core/water/ocean_spray.gd")

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

# System state
var _system_initialized: bool = false
var _system_enabled: bool = false

# Weather integration — last applied values (avoid redundant FFT spectrum regen)
var _weather_last_wind: float = -1.0
var _weather_last_storm_dir: Vector3 = Vector3.ZERO
var _weather_last_wind_t: float = 0.0
var _weather_last_wind_dir_xz: Vector2 = Vector2(1.0, 1.0).normalized()

# Internal state
var _ocean_mesh: OceanMesh = null
var _ocean_spray: OceanSpray = null
var _shore_mask: ShoreMaskGenerator = null
var _terrain: Terrain3D = null
var _camera: Camera3D = null
var _enabled: bool = true
var _time: float = 0.0
var _auto_find_camera: bool = true
var _current_map_scales: PackedVector4Array = PackedVector4Array()
var _active_shore_mask_texture: Texture2D = null
var _active_shore_mask_image: Image = null
var _active_shore_mask_bounds: Rect2 = Rect2(-8000.0, -8000.0, 16000.0, 16000.0)
var _active_shore_fade_distance: float = 50.0
var _current_shore_wave_amplitude: float = 0.18
var _current_shore_wave_frequency: float = SHORE_WAVE_SPATIAL_FREQUENCY
var _current_shore_wave_speed: float = 0.4
var _current_shore_wave_steepness: float = 0.58

# Legacy underwater compositor effect (managed via ShaderManager).
# Disabled by default: underwater/waterline ownership moved to the volume and
# pre-water compositor paths. Keep the API as a cleanup shim for older scenes.
var underwater_compositor_enabled: bool = false
var _underwater_effect_loaded: bool = false

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
var _cached_sun_light: DirectionalLight3D = null
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

	Log.info("water", "OceanManager: Initialized - sea level: %.1f, radius: %.0fm, mode: %s" % [
		sea_level, ocean_radius, get_water_quality_name()])


func _set_active_shore_mask(texture: Texture2D, bounds: Rect2, fade_distance: float, image: Image = null) -> void:
	_active_shore_mask_texture = texture
	_active_shore_mask_image = image
	_active_shore_mask_bounds = bounds
	_active_shore_fade_distance = fade_distance

	if texture == null:
		return
	if _ocean_mesh:
		_ocean_mesh.set_shore_mask(texture, bounds, fade_distance)
	if _ocean_spray:
		_ocean_spray.set_shore_mask(texture, bounds)


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
			Log.info("water", "OceanManager: Using prebaked shore mask from %s" % shore_mask_path)

	if not shore_mask_loaded:
		Log.warn("water", "OceanManager: No prebaked shore mask found — run 'Rebake Shore Mask' in prebake UI. Waves will not dampen at shore.")


func _process(delta: float) -> void:
	if not _system_enabled or not _enabled:
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

	# Push sun direction to the ocean surface shader for SSS backlight.
	# Scan the scene tree at most once every 60 frames so we notice late-spawned
	# DirectionalLight3D nodes without walking the tree per frame.
	_update_sun_uniform()

	# Update underwater compositor effect state (submersion, sun, camera)
	if underwater_compositor_enabled and _underwater_effect_loaded:
		_update_underwater_state()

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
##   6 = Foam factor
##   7 = World normal.y (white = flat, dark = steep slope)
##   8 = SSS scatter factor (peak_mask × side_mask × sun_back, sub-surface tint)
func set_debug_mode(mode: int) -> void:
	if not _ocean_mesh:
		return
	var mat: ShaderMaterial = _ocean_mesh.get_material()
	if not mat:
		return
	mat.set_shader_parameter("debug_mode", clampi(mode, 0, 8))


## Push the directional light's world-space forward direction to the ocean
## shader so the SSS pass can do a sun-backlight term. Scans the scene tree
## lazily (at most once per 60 frames) and pushes every frame while the sun is
## known — rotations follow a day/night cycle in real time, so caching the
## node alone isn't enough.
func _update_sun_uniform() -> void:
	if not _ocean_mesh:
		return
	var mat: ShaderMaterial = _ocean_mesh.get_material()
	if not mat:
		return

	var frame := Engine.get_process_frames()
	if _cached_sun_light == null or not is_instance_valid(_cached_sun_light):
		if frame - _last_sun_scan_frame >= 60:
			_last_sun_scan_frame = frame
			var tree := get_tree()
			if tree:
				_cached_sun_light = _find_node_by_class(tree.root, "DirectionalLight3D") as DirectionalLight3D

	if _cached_sun_light and is_instance_valid(_cached_sun_light):
		# DirectionalLight3D forward = -basis.z (points FROM sun TO world).
		var sun_dir: Vector3 = -_cached_sun_light.global_basis.z
		mat.set_shader_parameter("sun_dir_world", sun_dir.normalized())


func _push_ocean_time_uniform() -> void:
	if not _ocean_mesh:
		return
	var mat: ShaderMaterial = _ocean_mesh.get_material()
	if not mat:
		return
	mat.set_shader_parameter("ocean_time", _time)
	if _ocean_spray:
		_ocean_spray.set_ocean_time(_time)


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
		_displacement_maps.texture_rd_rid = RID()
		_normal_maps.texture_rd_rid = RID()
		_wave_generator.queue_free()
		_wave_generator = null
		_cascade_parameters.clear()
		_physics_evaluator = null
		_displacement_cpu = PackedByteArray()
		_displacement_cpu_per_cascade.clear()
		_displacement_size = 0
		Log.info("water", "OceanManager: FFT pipeline shut down")


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
	var raw_dist := shore_data.a * _active_shore_fade_distance
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
	var eps := 1.0
	var h0 := get_wave_height(world_pos)
	var hx := get_wave_height(world_pos + Vector3(eps, 0.0, 0.0))
	var hz := get_wave_height(world_pos + Vector3(0.0, 0.0, eps))
	return Vector3(h0 - hx, eps, h0 - hz).normalized()


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
		return _get_shore_factor(world_pos) > 0.01 or _get_shore_wave_height(world_pos) > 0.02
	if _terrain and _terrain.data:
		var terrain_height: float = CS.get_terrain_height(world_pos, _terrain)
		return terrain_height < sea_level
	return true


# ============================================================================
# UNDERWATER EFFECT
# ============================================================================

func _init_underwater_effect() -> void:
	if _underwater_effect_loaded:
		return
	var effect_path := "res://src/core/shaders/effects/underwater_compositor_effect.gd"
	if ShaderManager.load_effect(effect_path):
		_underwater_effect_loaded = true
		Log.info("water", "OceanManager: Underwater compositor effect loaded")
	else:
		Log.error("water", "OceanManager: Failed to load underwater compositor effect")


func _update_underwater_state() -> void:
	if not _underwater_effect_loaded or not _camera:
		return

	var cam_y: float = _camera.global_position.y
	var submerged: bool = cam_y < sea_level + 2.0  # Include boundary zone

	# Enable/disable the effect based on submersion
	var effect: PostProcessEffect = ShaderManager.get_effect("underwater")
	if effect == null:
		return

	var is_active: bool = ShaderManager.is_effect_enabled("underwater")
	if submerged and not is_active:
		ShaderManager.enable_effect("underwater")
		Log.info("water", "Underwater effect: ON")
	elif not submerged and is_active:
		ShaderManager.disable_effect("underwater")
		Log.info("water", "Underwater effect: OFF")

	# Update camera and sun state on the effect
	if submerged and effect.has_method("set_sea_level"):
		effect.set_sea_level(sea_level)
		effect.set_camera_state(_camera.global_position, _camera.global_basis)
		# Find sun for light direction
		var light: DirectionalLight3D = _find_node_by_class(get_tree().root, "DirectionalLight3D") as DirectionalLight3D
		if light:
			effect.set_sun_direction(-light.global_basis.z, 1.0)


## Get the underwater compositor effect
func get_underwater_effect() -> PostProcessEffect:
	if _underwater_effect_loaded:
		return ShaderManager.get_effect("underwater")
	return null


func set_underwater_compositor_enabled(enabled: bool) -> void:
	if enabled:
		Log.warn("water", "OceanManager: legacy underwater compositor is retired; request ignored")
		enabled = false

	if underwater_compositor_enabled == enabled and not _underwater_effect_loaded:
		return

	underwater_compositor_enabled = enabled
	if _underwater_effect_loaded:
		ShaderManager.disable_effect("underwater")
		ShaderManager.unload_effect("underwater")
		_underwater_effect_loaded = false


## Check if the camera is currently submerged
func is_camera_submerged() -> bool:
	if _camera:
		return _camera.global_position.y < sea_level + 2.0
	return false


# ============================================================================
# PUBLIC API
# ============================================================================

func set_camera(camera: Camera3D) -> void:
	_camera = camera
	_auto_find_camera = false
	if _ocean_spray:
		_ocean_spray.set_camera(camera)


func set_sea_level(level: float) -> void:
	sea_level = level
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


func get_sea_level() -> float:
	return sea_level


func get_absorption_tint() -> Vector3:
	return _current_absorption_tint


func get_absorption_sigma() -> Vector3:
	return _current_absorption_sigma


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


func is_gpu_wave_readback_enabled() -> bool:
	return use_gpu_wave_readback


func set_gpu_wave_readback_enabled(enabled: bool) -> void:
	use_gpu_wave_readback = enabled
	if not enabled:
		_displacement_cpu = PackedByteArray()
		_displacement_cpu_per_cascade.clear()


func get_water_query_source() -> StringName:
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
	state.sea_level = sea_level
	state.wave_scale = wave_scale
	state.ocean_time = _time
	state.map_scales = _current_map_scales
	state.cascade_count = _cascade_parameters.size()
	state.displacement_texture_rd = get_displacement_texture_rd()
	state.shore_mask_texture = _active_shore_mask_texture
	state.shore_mask_bounds = Vector4(
		_active_shore_mask_bounds.position.x,
		_active_shore_mask_bounds.position.y,
		_active_shore_mask_bounds.size.x,
		_active_shore_mask_bounds.size.y
	)
	state.shore_fade_distance = _active_shore_fade_distance
	state.shore_wave_amplitude = _current_shore_wave_amplitude
	state.shore_wave_frequency = _current_shore_wave_frequency
	state.shore_wave_speed = _current_shore_wave_speed
	state.shore_wave_steepness = _current_shore_wave_steepness
	state.absorption_tint = _current_absorption_tint
	state.absorption_sigma = _current_absorption_sigma
	state.absorption_depth_falloff = get_absorption_depth_falloff()
	state.underwater_caustics_strength = _current_underwater_caustics_strength
	state.cpu_query_available = _system_enabled and _enabled
	state.cpu_query_source = get_water_query_source()
	state.cpu_readback_bytes_per_frame = get_water_query_readback_bytes_per_frame()
	state.displacement_texture_size = _displacement_size
	state.height_query = Callable(self, "get_wave_height")
	state.displacement_query = Callable(self, "get_wave_displacement")
	state.normal_query = Callable(self, "get_wave_normal")
	if _active_shore_mask_texture != null:
		var texture_rid := _active_shore_mask_texture.get_rid()
		if texture_rid.is_valid():
			state.shore_mask_rd = RenderingServer.texture_get_rd_texture(texture_rid)
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
		if not _system_initialized:
			force_initialize()
			return
		if _ocean_mesh:
			_ocean_mesh.visible = true
	else:
		_enabled = false
		_system_enabled = false
		set_process(false)
		release_runtime_resources()


func get_time() -> float:
	return _time


func get_ocean_mesh() -> OceanMesh:
	return _ocean_mesh


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


func release_runtime_resources() -> void:
	if _underwater_effect_loaded:
		ShaderManager.disable_effect("underwater")
		ShaderManager.unload_effect("underwater")
		_underwater_effect_loaded = false
	_dispose_spray_layer()
	_shutdown_fft_pipeline()
	_dispose_ocean_mesh()
	if _shore_mask:
		_shore_mask.queue_free()
		_shore_mask = null
	_cached_sun_light = null
	_system_initialized = false


func _dispose_ocean_mesh() -> void:
	var old_mesh := _ocean_mesh
	_ocean_mesh = null
	if old_mesh == null:
		return
	old_mesh.visible = false
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
## lives on OceanManager, not on OceanMesh — only the shader material and
## mesh topology get replaced.
func rebuild_mesh_with_mode(new_mode: int) -> void:
	if not _system_enabled:
		return
	if new_mode < 0 or new_mode > 1:
		Log.warn("water", "OceanManager: rebuild_mesh_with_mode — invalid mode %d, ignoring" % new_mode)
		return
	if _ocean_mesh and _ocean_mesh.get_mesh_mode() == new_mode:
		Log.info("water", "OceanManager: already in requested mesh mode, no-op")
		return

	water_mesh_mode = new_mode

	_dispose_ocean_mesh()

	_ocean_mesh = OceanMesh.new()
	_ocean_mesh.name = "OceanMesh"
	add_child(_ocean_mesh)
	_ocean_mesh.initialize(ocean_radius, water_quality, water_mesh_mode)
	water_mesh_mode = _ocean_mesh.get_mesh_mode()

	# Re-push shader parameters, shore mask, and FFT cascade state to the
	# fresh material.
	_update_shader_parameters()
	_load_shore_mask()
	if _ocean_mesh.get_quality() == OceanMesh.QualityMode.HIGH and _wave_generator:
		_update_cascade_scales()
	_setup_spray_layer()
	if _ocean_spray:
		_ocean_spray.set_fft_available(_wave_generator != null and _ocean_mesh.get_quality() == OceanMesh.QualityMode.HIGH)
	reset_weather()

	Log.info("water", "OceanManager: rebuilt ocean mesh in mode %s" % (
		"PROJECTED" if water_mesh_mode == 1 else "CLIPMAP"))


func get_mesh_mode() -> int:
	if _ocean_mesh:
		return _ocean_mesh.get_mesh_mode()
	return water_mesh_mode


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
	elif target_quality != OceanMesh.QualityMode.HIGH and _wave_generator:
		_shutdown_fft_pipeline()
	if _ocean_spray:
		_ocean_spray.set_fft_available(_wave_generator != null and _ocean_mesh.get_quality() == OceanMesh.QualityMode.HIGH)
	_update_shader_parameters()
	_load_shore_mask()
	if _ocean_mesh.get_quality() == OceanMesh.QualityMode.HIGH and _wave_generator:
		_update_cascade_scales()
	reset_weather()

	Log.info("water", "OceanManager: Quality changed to: %s" % get_water_quality_name())


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
	for cascade: WaveCascadeParameters in _cascade_parameters:
		cascade.wind_speed = ocean_wind
		cascade.displacement_scale = disp_scale
	# Push the new displacement scale into the shader uniform — see the
	# long comment in `_apply_weather_fft` for why this is critical.
	_update_cascade_scales()
	if _physics_evaluator:
		_physics_evaluator.init_from_cascades(_cascade_parameters, fft_map_size)
	_weather_last_wind_t = v
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


## Water colors — dark and desaturated like OpenMW. Visual character comes from
## reflections (probe/sky), not albedo. Bright/turquoise water = wrong.
const _SHALLOW_CALM := Color(0.09, 0.12, 0.13)
const _SHALLOW_STORM := Color(0.06, 0.08, 0.09)
const _DEEP_CALM := Color(0.02, 0.04, 0.06)
const _DEEP_STORM := Color(0.01, 0.02, 0.03)
const _SURFACE_ABSORPTION_RATE := Vector3(0.4, 0.1, 0.06)
const _SURFACE_ABSORPTION_DENSITY := 0.2

var _current_absorption_tint := Vector3(_DEEP_CALM.r, _DEEP_CALM.g, _DEEP_CALM.b)
var _current_absorption_sigma := _SURFACE_ABSORPTION_RATE * _SURFACE_ABSORPTION_DENSITY
var _current_underwater_caustics_strength: float = 1.0

func _apply_weather_shader(result: WeatherTypes.WeatherResult, wind_t: float) -> void:
	if not _ocean_mesh:
		return
	var mat: ShaderMaterial = _ocean_mesh.get_material()
	if not mat:
		return

	# Water color darkens and desaturates in storms (driven by cloud coverage)
	var storm_t: float = clampf(result.cloud_coverage, 0.0, 1.0)
	var shallow_col: Color = _SHALLOW_CALM.lerp(_SHALLOW_STORM, storm_t)
	var deep_col: Color = _DEEP_CALM.lerp(_DEEP_STORM, storm_t)
	_current_absorption_tint = Vector3(deep_col.r, deep_col.g, deep_col.b)
	_current_absorption_sigma = _SURFACE_ABSORPTION_RATE * _SURFACE_ABSORPTION_DENSITY
	_current_underwater_caustics_strength = lerpf(1.0, 0.35, storm_t)
	mat.set_shader_parameter("color_shallow", Vector3(shallow_col.r, shallow_col.g, shallow_col.b))
	mat.set_shader_parameter("color_deep", _current_absorption_tint)
	_push_surface_optical_uniforms(mat)

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
	mat.set_shader_parameter("absorption_density", _SURFACE_ABSORPTION_DENSITY)


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

	_current_absorption_tint = Vector3(_DEEP_CALM.r, _DEEP_CALM.g, _DEEP_CALM.b)
	_current_absorption_sigma = _SURFACE_ABSORPTION_RATE * _SURFACE_ABSORPTION_DENSITY
	_current_underwater_caustics_strength = 1.0
	mat.set_shader_parameter("color_shallow", Vector3(_SHALLOW_CALM.r, _SHALLOW_CALM.g, _SHALLOW_CALM.b))
	mat.set_shader_parameter("color_deep", _current_absorption_tint)
	_push_surface_optical_uniforms(mat)
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
	_update_spray_weather(_weather_last_wind_t, _weather_last_wind_dir_xz)

	Log.info("water", "Ocean weather reset to calm defaults")


func _update_spray_weather(wind_t: float, wind_dir_xz: Vector2) -> void:
	if _ocean_spray == null:
		return
	_ocean_spray.enabled = sea_spray_enabled
	_ocean_spray.quality_tier = clampi(sea_spray_quality, 0, 3) as OceanSpray.QualityTier
	_ocean_spray.set_weather(wind_t, wind_dir_xz)


func _exit_tree() -> void:
	if Engine.has_meta("_quitting"):
		return
	if _underwater_effect_loaded:
		ShaderManager.disable_effect("underwater")
		ShaderManager.unload_effect("underwater")
		_underwater_effect_loaded = false
	_dispose_spray_layer()
	# Clean up FFT RIDs to avoid exit-time leaks
	_shutdown_fft_pipeline()


func is_integrated_gpu() -> bool:
	return HardwareDetection.is_integrated_gpu()


func get_gpu_name() -> String:
	return HardwareDetection.get_gpu_name()
