## Manages the terrain shader override for wet fallback support.
##
## Applies a custom shader override to Terrain3D. Production water-contact
## wetness is screen-space; this terrain shader keeps only a tight fallback
## hook and Terrain3D material plumbing.
##
## Horizon maps are PARKED — the baking infrastructure remains but is not
## loaded or applied. Will be re-enabled when all regions have baked data
## and the visual benefit is confirmed.
class_name HorizonMapManager
extends RefCounted

const TERRAIN_SHADER_PATH := "res://src/core/world/terrain_horizon.gdshader"

var _terrain: Terrain3D = null
var _material_rid: RID = RID()


## Set a shader parameter on the terrain material via RenderingServer.
## Uses RS directly because Terrain3DMaterial.set_shader_param() may filter
## out custom uniforms added by shader overrides.
func _set_param(param_name: StringName, value: Variant) -> void:
	if not _material_rid.is_valid() and _terrain and _terrain.material:
		_material_rid = _terrain.material.get_material_rid()
	if _material_rid.is_valid():
		if value is Texture2D:
			value = (value as Texture2D).get_rid()
		RenderingServer.material_set_param(_material_rid, param_name, value)


## Apply the custom shader as Terrain3D's shader override.
func _apply_shader_override() -> bool:
	if not _terrain or not _terrain.material:
		return false
	var shader: Shader = load(TERRAIN_SHADER_PATH) as Shader
	if not shader:
		Log.warn("streaming", "HorizonMapManager: Failed to load shader at %s" % TERRAIN_SHADER_PATH)
		return false
	_terrain.material.set("shader_override", shader)
	_terrain.material.set("shader_override_enabled", true)
	_material_rid = _terrain.material.get_material_rid()
	Log.info("streaming", "HorizonMapManager: Applied terrain shader override")
	return true


## Initialize: apply shader override for wet map support.
func initialize(terrain: Terrain3D, _sun: DirectionalLight3D) -> void:
	_terrain = terrain
	if _terrain and _terrain.material:
		_material_rid = _terrain.material.get_material_rid()

	if not _apply_shader_override():
		Log.warn("streaming", "HorizonMapManager: Could not apply shader override")


## Push terrain wet fallback uniforms. Disabled by default because live wetness
## is owned by WetCompositorEffect.
func push_wet_map(
	sea_level: float,
	wet_margin: float = 0.3,
	wet_darken: float = 0.6,
	wet_rough: float = 0.05,
	fallback_enabled: bool = false
) -> void:
	_set_param("sea_level_wet", sea_level)
	_set_param("wet_margin", wet_margin)
	_set_param("wet_albedo_darken", wet_darken)
	_set_param("wet_roughness_target", wet_rough)
	_set_param("terrain_wet_fallback_enabled", fallback_enabled)


## Legacy no-op: terrain shore/runup wetness is not authoritative.
func push_shore_wave_wetness_from_state(state: WaterSurfaceState, _enabled: bool = true) -> void:
	if state == null:
		return
	if state.shore_mask_texture != null:
		_set_param("shore_mask", state.shore_mask_texture)
	_set_param("shore_mask_bounds", state.shore_mask_bounds)


## Legacy no-op: terrain shore/runup wetness is not authoritative.
func push_shore_wave_wetness(ocean_material: ShaderMaterial, _ocean_time: float, _enabled: bool = true) -> void:
	if ocean_material == null:
		return

	var shore_mask: Variant = ocean_material.get_shader_parameter("shore_mask")
	if shore_mask is Texture2D:
		_set_param("shore_mask", shore_mask)

	var bounds: Variant = ocean_material.get_shader_parameter("shore_mask_bounds")
	if bounds != null:
		_set_param("shore_mask_bounds", bounds)


## Kept for API compatibility — horizon maps are parked.
func set_enabled(_enabled: bool) -> void:
	pass

## Kept for API compatibility — horizon maps are parked.
func update_sun_direction() -> void:
	pass


## Save a single region's horizon maps to disk (baking infrastructure — kept for future use).
static func save_region(region_coord: Vector2i, tex1: Image, tex2: Image) -> void:
	var horizon_dir: String = _get_horizon_dir()
	DirAccess.make_dir_recursive_absolute(horizon_dir)
	tex1.save_png(_region_path(horizon_dir, region_coord, 1))
	tex2.save_png(_region_path(horizon_dir, region_coord, 2))


static func _get_horizon_dir() -> String:
	return SettingsManager.get_terrain_path().path_join("horizon_maps")


static func _region_path(dir: String, coord: Vector2i, tex_idx: int) -> String:
	return dir.path_join("horizon_%d_%d_t%d.png" % [coord.x, coord.y, tex_idx])
