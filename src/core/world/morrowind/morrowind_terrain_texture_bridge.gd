## Morrowind Terrain3D texture bridge.
##
## Terrain3D's built-in control map stores two 5-bit texture slots, which caps
## terrain texturing at 32 assets. Morrowind LAND data routinely uses more than
## that, so the MW adapter owns a sidecar index map and texture array instead.
class_name MorrowindTerrainTextureBridge
extends RefCounted

const TextureLoaderScript := preload("res://src/core/texture/texture_loader.gd")
const CS := preload("res://src/core/coordinate_system.gd")

const DEFAULT_TEXTURE_PATH := "textures\\_land_default.dds"
const ALBEDO_LAYER_SIZE := 512
const INDEX_MAP_SIZE := 65
const INDEX_MAP_LAYER_COUNT := 1024
const CELLS_PER_REGION := 4
const INDEX_NEIGHBORHOOD_SIZE := CELLS_PER_REGION + 1
const MW_TEXTURE_SIZE := 16
const MAX_R8_LAYER_ID := 255

var texture_blend_softness: float = 1.0

var _terrain: Terrain3D = null
var _material_rid: RID = RID()
var _land_albedo_array: Texture2DArray = null
var _land_index_maps: Texture2DArray = null
var _mw_index_to_layer: Dictionary = {}
var _normalized_path_to_layer: Dictionary = {}
var _blank_index_map: Image = null
var _initialized := false


func initialize(terrain: Terrain3D) -> Error:
	_terrain = terrain
	if not _terrain or not _terrain.material:
		Log.warn("textures", "MorrowindTerrainTextureBridge: Terrain3D material unavailable")
		return ERR_UNCONFIGURED

	var err := _build_albedo_array()
	if err != OK:
		return err

	err = _build_index_map_array()
	if err != OK:
		return err

	_material_rid = _terrain.material.get_material_rid()
	_initialized = true
	push_shader_params()
	Log.info("textures", "MW terrain texture bridge initialized: %d MW indices, %d texture-array layers" % [
		_mw_index_to_layer.size(), _normalized_path_to_layer.size()
	])
	return OK


func is_initialized() -> bool:
	return _initialized


func get_texture_array_layer_count() -> int:
	return _normalized_path_to_layer.size()


func get_array_layer_for_mw_index(mw_index: int) -> int:
	return int(_mw_index_to_layer.get(mw_index, 0))


func get_index_map_image_for_region(region_coord: Vector2i) -> Image:
	return _generate_index_map_for_region(region_coord)


func push_shader_params() -> void:
	if not _initialized:
		return
	if not _material_rid.is_valid() and _terrain and _terrain.material:
		_material_rid = _terrain.material.get_material_rid()
	if not _material_rid.is_valid():
		return

	RenderingServer.material_set_param(_material_rid, "mw_texturing_enabled", true)
	RenderingServer.material_set_param(_material_rid, "mw_land_albedo_array", _land_albedo_array.get_rid())
	RenderingServer.material_set_param(_material_rid, "mw_land_index_maps", _land_index_maps.get_rid())
	RenderingServer.material_set_param(_material_rid, "mw_texture_tile_scale", 16.0 / CS.CELL_SIZE_GODOT)
	RenderingServer.material_set_param(_material_rid, "mw_texture_blend_softness", texture_blend_softness)


func rebuild_all_active_regions() -> void:
	if not _initialized or not _terrain or not _terrain.data:
		return

	var locations: Variant = _terrain.data.get_region_locations()
	var updated := 0
	for layer_index in range(locations.size()):
		var loc: Vector2 = locations[layer_index]
		if _is_invalid_region_location(loc):
			continue
		var region_coord := terrain3d_location_to_mw_region(Vector2i(roundi(loc.x), roundi(loc.y)))
		_update_region_layer(region_coord, layer_index)
		updated += 1

	push_shader_params()
	Log.info("textures", "MW terrain texture bridge updated %d active Terrain3D region index maps" % updated)


func on_terrain_region_imported(region_coord: Vector2i, t3d_loc: Vector2i) -> void:
	if not _initialized:
		return
	var layer_index := _find_layer_for_region(t3d_loc)
	if layer_index < 0:
		Log.warn("textures", "MW terrain texture bridge: no Terrain3D layer for imported region %s at %s" % [region_coord, t3d_loc])
		return
	_update_region_layer(region_coord, layer_index)
	push_shader_params()


func on_terrain_region_unloading(_region_coord: Vector2i, t3d_loc: Vector2i) -> void:
	if not _initialized:
		return
	var layer_index := _find_layer_for_region(t3d_loc)
	if layer_index >= 0:
		_land_index_maps.update_layer(_blank_index_map, layer_index)


func _build_albedo_array() -> Error:
	_mw_index_to_layer.clear()
	_normalized_path_to_layer.clear()

	var images: Array[Image] = []
	var default_image := _load_layer_image(DEFAULT_TEXTURE_PATH, Color(0.4, 0.35, 0.3, 1.0))
	images.append(default_image)
	_mw_index_to_layer[0] = 0
	_normalized_path_to_layer[_normalize_texture_key(DEFAULT_TEXTURE_PATH)] = 0

	var used_indices := _collect_used_texture_indices()
	for mw_index: int in used_indices:
		if mw_index == 0:
			continue
		if _mw_index_to_layer.size() > MAX_R8_LAYER_ID:
			Log.warn("textures", "MW terrain texture bridge: R8 layer cap reached; MW index %d and later indices fall back to default" % mw_index)
			break

		var ltex := _find_ltex_by_index(mw_index - 1)
		if not ltex:
			_mw_index_to_layer[mw_index] = 0
			continue

		var path_key := _normalize_texture_key(ltex.texture_path)
		if path_key in _normalized_path_to_layer:
			_mw_index_to_layer[mw_index] = _normalized_path_to_layer[path_key]
			continue

		var layer := images.size()
		var img := _load_layer_image(ltex.texture_path, Color(0.4, 0.35, 0.3, 1.0))
		images.append(img)
		_normalized_path_to_layer[path_key] = layer
		_mw_index_to_layer[mw_index] = layer

	_land_albedo_array = Texture2DArray.new()
	_land_albedo_array.create_from_images(images)
	return OK


func _build_index_map_array() -> Error:
	_blank_index_map = Image.create(INDEX_MAP_SIZE, INDEX_MAP_SIZE, false, Image.FORMAT_R8)
	_blank_index_map.fill(Color.BLACK)

	var images: Array[Image] = []
	images.resize(INDEX_MAP_LAYER_COUNT)
	for i in range(INDEX_MAP_LAYER_COUNT):
		images[i] = _blank_index_map.duplicate()

	_land_index_maps = Texture2DArray.new()
	_land_index_maps.create_from_images(images)
	return OK


func _update_region_layer(region_coord: Vector2i, layer_index: int) -> void:
	if layer_index < 0 or layer_index >= INDEX_MAP_LAYER_COUNT:
		return
	var img := _generate_index_map_for_region(region_coord)
	_land_index_maps.update_layer(img, layer_index)


func _generate_index_map_for_region(region_coord: Vector2i) -> Image:
	var cell_textures := _build_cell_texture_neighborhood(region_coord)
	if ClassDB.class_exists("TerrainGenerator"):
		var generator: RefCounted = ClassDB.instantiate("TerrainGenerator")
		if generator:
			var image: Image = generator.call("GenerateMorrowindRegionIndexMap", cell_textures, _mw_index_to_layer)
			if image:
				return image

	return _generate_index_map_fallback(cell_textures)


func _build_cell_texture_neighborhood(region_coord: Vector2i) -> Array:
	var cells: Array = []
	cells.resize(INDEX_NEIGHBORHOOD_SIZE * INDEX_NEIGHBORHOOD_SIZE)
	var sw_cell := Vector2i(region_coord.x * CELLS_PER_REGION, region_coord.y * CELLS_PER_REGION)

	for local_y in range(INDEX_NEIGHBORHOOD_SIZE):
		for local_x in range(INDEX_NEIGHBORHOOD_SIZE):
			var land: LandRecord = ESMManager.get_land(sw_cell.x + local_x, sw_cell.y + local_y)
			if not land or not land.has_textures():
				cells[local_y * INDEX_NEIGHBORHOOD_SIZE + local_x] = PackedInt32Array()
				continue

			var indices := PackedInt32Array()
			indices.resize(MW_TEXTURE_SIZE * MW_TEXTURE_SIZE)
			for y in range(MW_TEXTURE_SIZE):
				for x in range(MW_TEXTURE_SIZE):
					indices[y * MW_TEXTURE_SIZE + x] = land.get_texture_index(x, y)
			cells[local_y * INDEX_NEIGHBORHOOD_SIZE + local_x] = indices

	return cells


func _generate_index_map_fallback(cell_textures: Array) -> Image:
	var img := Image.create(INDEX_MAP_SIZE, INDEX_MAP_SIZE, false, Image.FORMAT_R8)
	for img_y in range(INDEX_MAP_SIZE):
		var global_y := INDEX_MAP_SIZE - 1 - img_y
		var cell_y := mini(int(global_y / MW_TEXTURE_SIZE), CELLS_PER_REGION)
		var tex_y := global_y % MW_TEXTURE_SIZE
		for x in range(INDEX_MAP_SIZE):
			var cell_x := mini(int(x / MW_TEXTURE_SIZE), CELLS_PER_REGION)
			var tex_x := x % MW_TEXTURE_SIZE
			var cell: PackedInt32Array = cell_textures[cell_y * INDEX_NEIGHBORHOOD_SIZE + cell_x]
			var mw_index := 0
			if cell.size() == MW_TEXTURE_SIZE * MW_TEXTURE_SIZE:
				mw_index = cell[tex_y * MW_TEXTURE_SIZE + tex_x]
			var layer := int(_mw_index_to_layer.get(mw_index, 0))
			img.set_pixel(x, img_y, Color(float(layer) / 255.0, 0.0, 0.0, 1.0))
	return img


func _collect_used_texture_indices() -> Array[int]:
	var used: Dictionary = {0: true}
	for key: Variant in ESMManager.lands.keys():
		var land: LandRecord = ESMManager.lands[key]
		if not land or not land.has_textures():
			continue
		for y in range(MW_TEXTURE_SIZE):
			for x in range(MW_TEXTURE_SIZE):
				used[land.get_texture_index(x, y)] = true

	var result: Array[int] = []
	for idx: int in used.keys():
		result.append(idx)
	result.sort()
	Log.info("textures", "MW terrain texture bridge found %d distinct VTEX indices" % result.size())
	return result


func _find_ltex_by_index(ltex_index: int) -> LandTextureRecord:
	for key: Variant in ESMManager.land_textures.keys():
		var ltex: LandTextureRecord = ESMManager.land_textures[key]
		if ltex and ltex.texture_index == ltex_index:
			return ltex
	return null


func _load_layer_image(texture_path: String, fallback_color: Color) -> Image:
	var texture: ImageTexture = TextureLoaderScript.load_texture(texture_path)
	var img: Image = texture.get_image() if texture else null
	if not img or texture == TextureLoaderScript._get_fallback_texture():
		img = Image.create(ALBEDO_LAYER_SIZE, ALBEDO_LAYER_SIZE, false, Image.FORMAT_RGBA8)
		img.fill(fallback_color)
	else:
		img = img.duplicate()
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_RGBA8)
		if img.get_width() != ALBEDO_LAYER_SIZE or img.get_height() != ALBEDO_LAYER_SIZE:
			img.resize(ALBEDO_LAYER_SIZE, ALBEDO_LAYER_SIZE, Image.INTERPOLATE_LANCZOS)
	if not img.has_mipmaps():
		img.generate_mipmaps()
	return img


func _normalize_texture_key(path: String) -> String:
	return path.replace("\\", "/").to_lower()


func _find_layer_for_region(t3d_loc: Vector2i) -> int:
	if not _terrain or not _terrain.data:
		return -1
	var locations: Variant = _terrain.data.get_region_locations()
	for layer_index in range(locations.size()):
		var loc: Vector2 = locations[layer_index]
		if _is_invalid_region_location(loc):
			continue
		if Vector2i(roundi(loc.x), roundi(loc.y)) == t3d_loc:
			return layer_index
	return -1


func _is_invalid_region_location(loc: Variant) -> bool:
	return loc.x <= -999999.0 or loc.y <= -999999.0


static func terrain3d_location_to_mw_region(t3d_loc: Vector2i) -> Vector2i:
	return Vector2i(t3d_loc.x, -t3d_loc.y)
