## Manages horizon map textures for terrain self-shadowing.
##
## Loads prebaked horizon maps from disk and injects them into the Terrain3D
## shader as texture arrays. Updates the sun direction uniform each frame.
##
## Horizon maps are baked by HorizonMapBaker during terrain preprocessing
## and stored as individual PNG files per region. At load time, they are
## assembled into Texture2DArrays matching Terrain3D's internal layer order
## (via get_region_locations()).
class_name HorizonMapManager
extends RefCounted

const HORIZON_SHADER_PATH := "res://src/core/world/terrain_horizon.gdshader"

var _terrain: Terrain3D = null
var _enabled: bool = false
var _sun: DirectionalLight3D = null
var _material_rid: RID = RID()
var _tex1_ref: Texture2DArray = null  # prevent GC while RID is in use
var _tex2_ref: Texture2DArray = null

## Shadow parameters
var shadow_intensity: float = 0.7
var shadow_softness: float = 0.05


## Set a shader parameter via Terrain3DMaterial.set_shader_param (v1.0.1 API)
@warning_ignore("unsafe_method_access")
func _set_param(param_name: StringName, value: Variant) -> void:
	if _terrain and _terrain.material:
		_terrain.material.set_shader_param(param_name, value)


## Apply the custom horizon shader as Terrain3D's shader override.
## Must be called BEFORE setting any horizon uniforms.
func _apply_shader_override() -> bool:
	if not _terrain or not _terrain.material:
		return false
	var shader: Shader = load(HORIZON_SHADER_PATH) as Shader
	if not shader:
		Log.warn("streaming", "HorizonMapManager: Failed to load horizon shader at %s" % HORIZON_SHADER_PATH)
		return false
	_terrain.material.set("shader_override", shader)
	_terrain.material.set("shader_override_enabled", true)
	# Re-acquire the material RID after shader override (may change)
	_material_rid = _terrain.material.get_material_rid()
	Log.info("streaming", "HorizonMapManager: Applied terrain horizon shader override")
	return true


## Initialize with shader override and optionally load horizon maps.
## Shader override is ALWAYS applied — wet map uniforms live in the override
## shader and must work even without prebaked horizon textures.
func initialize(terrain: Terrain3D, sun: DirectionalLight3D) -> void:
	_terrain = terrain
	_sun = sun
	if _terrain and _terrain.material:
		_material_rid = _terrain.material.get_material_rid()

	# Shader override first — wet map uniforms require it
	if not _apply_shader_override():
		Log.warn("streaming", "HorizonMapManager: Could not apply shader override")
		return

	# Try loading horizon maps (optional — wet map works without them)
	var horizon_dir: String = _get_horizon_dir()
	if not DirAccess.dir_exists_absolute(horizon_dir):
		Log.info("streaming", "HorizonMapManager: No horizon maps at %s (shader override active)" % horizon_dir)
		return

	var region_locations: Array[Vector2i] = terrain.data.get_region_locations()
	if region_locations.is_empty():
		Log.info("streaming", "HorizonMapManager: No terrain regions loaded")
		return

	# Build texture arrays in layer order matching Terrain3D's region order
	var images_1: Array[Image] = []
	var images_2: Array[Image] = []
	var loaded := 0

	for region_coord: Vector2i in region_locations:
		var tex1_path: String = _region_path(horizon_dir, region_coord, 1)
		var tex2_path: String = _region_path(horizon_dir, region_coord, 2)

		if FileAccess.file_exists(tex1_path) and FileAccess.file_exists(tex2_path):
			var img1 := Image.new()
			var img2 := Image.new()
			var err1: Error = img1.load(tex1_path)
			var err2: Error = img2.load(tex2_path)
			if err1 == OK and err2 == OK:
				images_1.append(img1)
				images_2.append(img2)
				loaded += 1
				continue
			Log.warn("streaming", "HorizonMapManager: Corrupt horizon file for region %s" % str(region_coord))

		# Placeholder: flat horizon (no shadow) for missing/corrupt regions
		var placeholder := Image.create(256, 256, false, Image.FORMAT_RGBA8)
		placeholder.fill(Color(0, 0, 0, 0))
		images_1.append(placeholder)
		images_2.append(placeholder)

	if loaded == 0:
		Log.info("streaming", "HorizonMapManager: No horizon map files found")
		return

	var tex1_array := Texture2DArray.new()
	tex1_array.create_from_images(images_1)
	var tex2_array := Texture2DArray.new()
	tex2_array.create_from_images(images_2)

	_apply_to_shader(tex1_array, tex2_array)
	set_enabled(true)
	Log.info("streaming", "HorizonMapManager: Loaded %d/%d horizon maps" % [loaded, region_locations.size()])


func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	if _terrain and _terrain.material:
		_set_param("horizon_enabled", _enabled)


## Push wet map uniforms to the terrain shader override.
## Call after initialize() and whenever sea_level changes.
func push_wet_map(sea_level: float, wet_margin: float = 1.5, wet_darken: float = 0.6, wet_rough: float = 0.05) -> void:
	_set_param("sea_level_wet", sea_level)
	_set_param("wet_margin", wet_margin)
	_set_param("wet_albedo_darken", wet_darken)
	_set_param("wet_roughness_target", wet_rough)


func _apply_to_shader(tex1: Texture2DArray, tex2: Texture2DArray) -> void:
	if not _terrain or not _terrain.material:
		return
	# Keep references alive
	_tex1_ref = tex1
	_tex2_ref = tex2
	# set_shader_param accepts Texture objects directly (not RIDs)
	_set_param("horizon_texture_1", tex1)
	_set_param("horizon_texture_2", tex2)
	_set_param("horizon_shadow_intensity", shadow_intensity)
	_set_param("horizon_shadow_softness", shadow_softness)


## Call each frame to update sun direction in the shader.
func update_sun_direction() -> void:
	if not _enabled or not _sun or not _terrain or not _terrain.material:
		return
	# Direction TOWARD the sun (opposite of light direction)
	var sun_dir: Vector3 = -_sun.global_basis.z
	_set_param("horizon_sun_direction", sun_dir)


## Save a single region's horizon maps to disk.
static func save_region(region_coord: Vector2i, tex1: Image, tex2: Image) -> void:
	var horizon_dir: String = _get_horizon_dir()
	DirAccess.make_dir_recursive_absolute(horizon_dir)
	tex1.save_png(_region_path(horizon_dir, region_coord, 1))
	tex2.save_png(_region_path(horizon_dir, region_coord, 2))


static func _get_horizon_dir() -> String:
	return SettingsManager.get_terrain_path().path_join("horizon_maps")


static func _region_path(dir: String, coord: Vector2i, tex_idx: int) -> String:
	return dir.path_join("horizon_%d_%d_t%d.png" % [coord.x, coord.y, tex_idx])
