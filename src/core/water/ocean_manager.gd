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
# Mesh mode: 0 = CLIPMAP (11-ring concentric mesh, follows camera),
#            1 = PROJECTED (screen-space N×N grid, vertex-shader unproject).
# FFT quality only; flat/gerstner always use CLIPMAP.
const SETTING_MESH_MODE := "ocean/mesh_mode"

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

# Underwater compositor effect (managed via ShaderManager)
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
	sea_level = ProjectSettings.get_setting(SETTING_SEA_LEVEL, 0.0)
	ocean_radius = ProjectSettings.get_setting(SETTING_RADIUS, 8000.0)
	water_quality = ProjectSettings.get_setting(SETTING_QUALITY, -1)
	water_mesh_mode = ProjectSettings.get_setting(SETTING_MESH_MODE, 0)

	HardwareDetection.detect()
	_find_terrain()

	_ocean_mesh.initialize(ocean_radius, water_quality, water_mesh_mode)
	_update_shader_parameters()
	# Shore mask removed — depth buffer handles shore boundary (SoT pattern).
	# _load_shore_mask() no longer called.

	# Initialize FFT pipeline if HIGH quality
	if _ocean_mesh.get_quality() == OceanMesh.QualityMode.HIGH:
		_init_fft_pipeline()

	# Apply calm defaults to shader uniforms (weather system will override when active)
	reset_weather()

	# Initialize underwater post-process effect
	_init_underwater_effect()

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

	# Push sun direction to the ocean surface shader for SSS backlight.
	# Scan the scene tree at most once every 60 frames so we notice late-spawned
	# DirectionalLight3D nodes without walking the tree per frame.
	_update_sun_uniform()

	# Update underwater compositor effect state (submersion, sun, camera)
	if _underwater_effect_loaded:
		_update_underwater_state()

	# GPU readback for buoyancy — read every cascade's displacement map
	# once per frame. Sampling only cascade 0 (swell) under-reports the
	# true visible wave height in high wind, where cascade 1 (chop)
	# contributes roughly as much amplitude as the swell. The shader
	# vertex sums ALL cascades; the CPU path must do the same or buoyant
	# bodies drift out of sync with the visible mesh.
	if _wave_generator and _displacement_size > 0:
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
	# Push sea_level to the ocean surface shader. Used by Guard (6) in
	# ocean_fft.gdshader's refraction path to reject refracted samples whose
	# world Y is above the waterline (tall rocks / pillar tops poking out).
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
	_ocean_mesh.get_material().set_shader_parameter(&"map_scales", map_scales)


## Debug visualization (2026-04-09). Cycles the ocean_fft.gdshader's
## `debug_mode` uniform to systematically diagnose wave-visibility /
## hole / see-through artifacts. Modes:
##   0 = Normal (production render)
##   1 = Shore factor (red→green)
##   2 = Shore discard zone (red = would discard)
##   3 = Water thickness (blue thin → red thick, magenta = sky-or-far)
##   4 = Transmittance (gray; bright = light passes through unfiltered)
##   5 = Fresnel (gray)
##   6 = SSR hit alpha (green = hit)
##   7 = Refraction UV offset magnitude (red = large offset)
##   8 = World normal.y (white = flat, dark = steep slope)
##   9 = SSS scatter factor (peak_mask × view_fade × sun_back, sub-surface tint)
func set_debug_mode(mode: int) -> void:
	if not _ocean_mesh:
		return
	var mat: ShaderMaterial = _ocean_mesh.get_material()
	if not mat:
		return
	mat.set_shader_parameter("debug_mode", clampi(mode, 0, 9))


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


func _shutdown_fft_pipeline() -> void:
	if _wave_generator:
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
# WAVE QUERIES — GPU readback (exact match) > OceanPhysicsEvaluator > GerstnerMath
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


## Get the wave height at a world position (for buoyancy)
func get_wave_height(world_pos: Vector3) -> float:
	if not _system_enabled or not _enabled:
		return sea_level

	var shore_factor := _get_shore_factor(world_pos)
	if shore_factor <= 0.01:
		return sea_level - 1000.0

	# GPU readback — exact match with visual waves (sum every cascade
	# with its own tile_length + displacement_scale, same as the shader).
	if _displacement_cpu_per_cascade.size() > 0:
		var disp := _sum_cascade_displacement(world_pos)
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

	if _displacement_cpu_per_cascade.size() > 0:
		var disp := _sum_cascade_displacement(world_pos)
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

	# GPU readback normal via finite differences across all cascades
	if _displacement_cpu_per_cascade.size() > 0:
		var eps := 1.0
		var h0 := _sum_cascade_displacement(world_pos).y
		var hx := _sum_cascade_displacement(world_pos + Vector3(eps, 0, 0)).y
		var hz := _sum_cascade_displacement(world_pos + Vector3(0, 0, eps)).y
		var nx := (h0 - hx) * shore_factor * wave_scale
		var nz := (h0 - hz) * shore_factor * wave_scale
		return Vector3(nx, 1.0, nz).normalized()

	if _physics_evaluator and _physics_evaluator._component_count > 0:
		return _physics_evaluator.get_normal(world_pos, _time, shore_factor * wave_scale)

	var cam_pos := _camera.global_position if _camera else Vector3.ZERO
	return GerstnerMath.get_normal(world_pos, _time, shore_factor * wave_scale, cam_pos)


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
			effect.set_sun(-light.global_basis.z, 1.0)


## Get the underwater compositor effect
func get_underwater_effect() -> PostProcessEffect:
	if _underwater_effect_loaded:
		return ShaderManager.get_effect("underwater")
	return null


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

	if _ocean_mesh:
		_ocean_mesh.queue_free()
		_ocean_mesh = null

	_ocean_mesh = OceanMesh.new()
	_ocean_mesh.name = "OceanMesh"
	add_child(_ocean_mesh)
	_ocean_mesh.initialize(ocean_radius, water_quality, water_mesh_mode)

	# Re-push shader parameters, shore mask, and FFT cascade state to the
	# fresh material.
	_update_shader_parameters()
	_load_shore_mask()
	if _ocean_mesh.get_quality() == OceanMesh.QualityMode.HIGH and _wave_generator:
		_update_cascade_scales()
	reset_weather()

	Log.info("water", "OceanManager: rebuilt ocean mesh in mode %s" % (
		"PROJECTED" if new_mode == 1 else "CLIPMAP"))


func get_mesh_mode() -> int:
	if _ocean_mesh:
		return _ocean_mesh.get_mesh_mode()
	return water_mesh_mode


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
## reflections (SSR/sky), not albedo. Bright/turquoise water = wrong.
const _SHALLOW_CALM := Color(0.09, 0.12, 0.13)
const _SHALLOW_STORM := Color(0.06, 0.08, 0.09)
const _DEEP_CALM := Color(0.02, 0.04, 0.06)
const _DEEP_STORM := Color(0.01, 0.02, 0.03)

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

	# Calm water reflects more sky, storms reflect less (sky obscured by clouds)
	mat.set_shader_parameter("sky_tint_strength", lerpf(0.8, 0.3, wind_t))

	# Foam suppression: near-zero in calm weather, full in storms
	mat.set_shader_parameter("foam_intensity", lerpf(0.05, 1.0, wind_t))

	# FFT-specific uniforms
	if quality == OceanMesh.QualityMode.HIGH:
		# Calm water is glassy smooth, storms are rough
		mat.set_shader_parameter("roughness", lerpf(0.01, 0.15, wind_t))
		# 2026-04-10 (r2) — SSS is a choppiness-driven ALBEDO blend. Stormy
		# weather has more choppiness → more sharp crests → more scatter, but
		# the peak mask (scatter_choppiness_min/max in the shader) now requires
		# actual sharp tips so we keep the master strength modest; the peak
		# mask does the "only fire on real crests" selection. Previous 0.9→1.5
		# combined with the old low-threshold mask was producing flat patches
		# of green across the whole horizon.
		mat.set_shader_parameter("sss_strength", lerpf(0.6, 1.0, wind_t))


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
	mat.set_shader_parameter("foam_intensity", 0.05)
	mat.set_shader_parameter("sky_tint_strength", 0.8)
	mat.set_shader_parameter("normal_strength", 0.6)
	mat.set_shader_parameter("wave_scale", wave_scale)

	var quality: OceanMesh.QualityMode = _ocean_mesh.get_quality()
	if quality == OceanMesh.QualityMode.HIGH:
		mat.set_shader_parameter("roughness", 0.01)
		mat.set_shader_parameter("sss_strength", 0.6)

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

	Log.info("water", "Ocean weather reset to calm defaults")


func _exit_tree() -> void:
	if Engine.has_meta("_quitting"):
		return
	if _underwater_effect_loaded:
		ShaderManager.disable_effect("underwater")
		ShaderManager.unload_effect("underwater")
		_underwater_effect_loaded = false
	# Clean up FFT RIDs to avoid exit-time leaks
	_shutdown_fft_pipeline()


func is_integrated_gpu() -> bool:
	return HardwareDetection.is_integrated_gpu()


func get_gpu_name() -> String:
	return HardwareDetection.get_gpu_name()
