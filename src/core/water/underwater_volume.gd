## UnderwaterVolume — follows the camera, drives underwater_volume.gdshader.
##
## Diagnostic support volume for underwater slab/depth/wobble checks. Production
## underwater caustics now live only in WaterlineCompositorEffect.
##
## ## Positioning model
##
## The volume is NOT a child of the camera — parenting to a Camera3D would
## rotate the box with camera pitch/yaw and cause the box edges to sweep
## through the world, popping effects in and out at the edges.
##
## Instead, this node lives as a sibling of the camera under the scene root.
## Each frame, `_process()` copies the camera's `global_position` (not
## rotation) into this node's `global_position`, keeping the volume axis-
## aligned with world Y.
##
## ## Volume bounds
##
## Size: 500 × 40 × 500 (per reviewer). Box is vertically centered on the
## camera, but the shader itself slabs its effects to the range
## [sea_level - volume_depth, sea_level] regardless of where the box floats —
## so effects will not appear above the water even if the camera is at y=+50.
## The box just has to contain pixels where the diagnostic underwater treatment
## should be visible, and 500 × 40 × 500 is comfortably larger than Morrowind's
## underwater visibility range.
##
## ## Activation
##
## Only visible when the camera is below the water surface. When above water,
## the node is hidden (saves the draw call entirely — no front-face cull + no
## SCREEN_TEXTURE sample).
class_name UnderwaterVolume
extends Node3D

const SHADER_PATH := "res://src/core/water/shaders/underwater_volume.gdshader"
const WATER_NORMAL_PATH := "res://assets/water/water_normal.png"

const VOLUME_SIZE := Vector3(500.0, 40.0, 500.0)

var _mesh_instance: MeshInstance3D
var _material: ShaderMaterial
var _fallback_shore_texture: Texture2D = null
var _camera: Camera3D = null
var _water_state: WaterSurfaceState = null
var _sea_level: float = 0.0
var _camera_water_level: float = 0.0
var _debug_mode: int = 0
var enabled: bool = true
var active_above_water: bool = false
var wobble_enabled: bool = true


func _ready() -> void:
	var mesh := BoxMesh.new()
	mesh.size = VOLUME_SIZE

	_material = ShaderMaterial.new()
	_material.shader = load(SHADER_PATH)
	_material.render_priority = 80
	_material.set_shader_parameter("water_normal_map", load(WATER_NORMAL_PATH))
	_material.set_shader_parameter("volume_depth", VOLUME_SIZE.y)
	_fallback_shore_texture = _create_fallback_shore_mask()
	_material.set_shader_parameter("shore_mask", _fallback_shore_texture)

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "UnderwaterBox"
	_mesh_instance.mesh = mesh
	_mesh_instance.material_override = _material
	# The volume is geometry the camera sits inside; disable frustum culling
	# so the box doesn't pop out when the camera is near an edge.
	_mesh_instance.extra_cull_margin = 500.0
	add_child(_mesh_instance)

	visible = false  # hidden until _process() confirms camera is underwater


func _create_fallback_shore_mask() -> Texture2D:
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.set_pixel(0, 0, Color(1.0, 0.5, 0.5, 1.0))
	return ImageTexture.create_from_image(img)


## Assign the scene camera. Must be called before the volume becomes useful.
func set_camera(camera: Camera3D) -> void:
	_camera = camera


## Compatibility no-op: production caustics and sun projection are compositor-owned.
func set_sun(_sun: DirectionalLight3D) -> void:
	pass


## Override the sea level Y value. Defaults to 0 if not called.
## If OceanManager is available, prefer calling this from the scene each frame
## so tides/weather/etc. stay in sync.
func set_sea_level(y: float) -> void:
	_sea_level = y
	_camera_water_level = y


## Dynamic water height at the camera. Production scenes should update this
## from WaterSurfaceState/OceanManager so waves, tide, and shore swash decide
## when the camera is actually underwater.
func set_camera_water_level(y: float) -> void:
	_camera_water_level = y


## Diagnostic/refactor mode. When true, the volume can stay visible even while
## the camera is above the waterline for non-final debug modes. Production
## scenes should keep this disabled.
func set_active_above_water(value: bool) -> void:
	active_above_water = value


func set_debug_mode(mode: int) -> void:
	_debug_mode = clampi(mode, 0, 3)
	if _material != null:
		_material.set_shader_parameter("debug_mode", _debug_mode)


func set_wobble_enabled(value: bool) -> void:
	wobble_enabled = value
	if _material != null:
		_material.set_shader_parameter("wobble_enabled", wobble_enabled)


func set_render_layers(layer_mask: int) -> void:
	if _mesh_instance != null:
		_mesh_instance.layers = layer_mask


func sync_wave_surface_from_ocean_material(ocean_material: ShaderMaterial) -> void:
	if _material == null:
		return
	if ocean_material != null:
		Log.warn("water", "UnderwaterVolume: refused material fallback; WaterSurfaceState is the required water contract")
	_water_state = null
	_material.set_shader_parameter("use_dynamic_water_surface", false)


func sync_wave_surface_from_water_state(state: WaterSurfaceState) -> void:
	if _material == null:
		return
	if state == null:
		_water_state = null
		_material.set_shader_parameter("use_dynamic_water_surface", false)
		return

	_water_state = state
	_sea_level = state.sea_level
	_camera_water_level = state.sample_height(_camera.global_position, state.sea_level) if _camera != null else state.sea_level
	_material.set_shader_parameter("use_dynamic_water_surface", true)
	_material.set_shader_parameter("map_scales", state.map_scales)
	_material.set_shader_parameter("wave_scale", state.wave_scale)
	_material.set_shader_parameter("ocean_time", state.ocean_time)
	if state.shore_mask_texture != null:
		_material.set_shader_parameter("shore_mask", state.shore_mask_texture)
	elif _fallback_shore_texture != null:
		_material.set_shader_parameter("shore_mask", _fallback_shore_texture)
	_material.set_shader_parameter("shore_mask_bounds", state.shore_mask_bounds)
	_material.set_shader_parameter("shore_fade_distance", state.shore_fade_distance)
	_material.set_shader_parameter("shore_wave_amplitude", state.shore_wave_amplitude)
	_material.set_shader_parameter("shore_wave_frequency", state.shore_wave_frequency)
	_material.set_shader_parameter("shore_wave_speed", state.shore_wave_speed)
	_material.set_shader_parameter("shore_wave_steepness", state.shore_wave_steepness)
	_material.set_shader_parameter("water_tint", state.absorption_tint)
	_material.set_shader_parameter("absorption_sigma", state.absorption_sigma)


func sync_optical_constants_from_ocean_manager(ocean_manager: Node) -> void:
	if _material == null or ocean_manager == null:
		return
	if ocean_manager.has_method("get_absorption_tint"):
		var tint: Vector3 = ocean_manager.get_absorption_tint()
		_material.set_shader_parameter("water_tint", tint)
	if ocean_manager.has_method("get_absorption_sigma"):
		var sigma: Vector3 = ocean_manager.get_absorption_sigma()
		_material.set_shader_parameter("absorption_sigma", sigma)


func _process(_delta: float) -> void:
	if _camera == null or not is_instance_valid(_camera) or not enabled:
		visible = false
		return

	if _water_state != null:
		_sea_level = _water_state.sea_level
		_camera_water_level = _water_state.sample_height(_camera.global_position, _sea_level)
	var cam_y: float = _camera.global_position.y
	var submerged: bool = cam_y < _camera_water_level
	var above_water_diagnostic: bool = active_above_water and _debug_mode != 0
	visible = submerged or above_water_diagnostic
	if not visible:
		return

	# Follow camera position, never rotation. The volume stays axis-aligned
	# with world Y so the slab test in the shader works unambiguously.
	global_position = _camera.global_position
	global_rotation = Vector3.ZERO

	# Per-frame uniforms. Cheap enough to push unconditionally.
	_material.set_shader_parameter("sea_level", _sea_level)
	_material.set_shader_parameter("debug_mode", _debug_mode)
	_material.set_shader_parameter("wobble_enabled", wobble_enabled)
