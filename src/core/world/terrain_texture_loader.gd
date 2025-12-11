## Terrain Texture Loader - Loads Morrowind LTEX textures into Terrain3D
##
## This class handles the conversion of Morrowind's LTEX (Land Texture) records
## into Terrain3DTextureAsset resources that can be used by Terrain3D's material
## system.
##
## Morrowind texture mapping:
##   VTEX stores texture_index values (0-255 per vertex)
##   Index 0 = default texture (no LTEX record)
##   Index N > 0 = LTEX record with index N-1
##
## Terrain3D supports up to 32 textures (slots 0-31)
class_name TerrainTextureLoader
extends RefCounted

const TextureLoader := preload("res://src/core/texture/texture_loader.gd")

## Default texture path for index 0 (when no LTEX specified)
const DEFAULT_TEXTURE_PATH := "textures\\_land_default.dds"

## Cache of loaded texture assets: MW texture_index -> Terrain3DTextureAsset
var _texture_assets: Dictionary = {}

## Map of MW texture indices to Terrain3D slot indices
var _slot_mapping: Dictionary = {}

## Next available Terrain3D slot
var _next_slot: int = 0

## Statistics
var _stats := {
	"textures_loaded": 0,
	"textures_failed": 0,
	"ltex_records": 0,
}


## Load all LTEX textures from ESMManager and add to Terrain3D assets
## Returns the number of textures successfully loaded
func load_terrain_textures(terrain_assets: Terrain3DAssets) -> int:
	if not terrain_assets:
		push_error("TerrainTextureLoader: No Terrain3DAssets provided")
		return 0

	_stats["ltex_records"] = ESMManager.land_textures.size()
	print("TerrainTextureLoader: Loading %d LTEX textures..." % _stats["ltex_records"])

	# First, add a default texture at slot 0
	_add_default_texture(terrain_assets)

	# Collect unique textures from all LAND records
	var unique_indices := _collect_used_texture_indices()
	print("TerrainTextureLoader: Found %d unique texture indices in use" % unique_indices.size())

	# Load textures for used indices (limit to 31 since slot 0 is default)
	var loaded := 0
	for mw_index: int in unique_indices:
		if mw_index == 0:
			continue  # Skip default texture index

		if _next_slot >= 32:
			push_warning("TerrainTextureLoader: Maximum texture slots reached (32)")
			break

		if _load_ltex_texture(terrain_assets, mw_index):
			loaded += 1

	_stats["textures_loaded"] = loaded
	print("TerrainTextureLoader: Loaded %d textures (%d failed)" % [loaded, _stats["textures_failed"]])

	return loaded


## Collect all texture indices actually used by LAND records
func _collect_used_texture_indices() -> Array[int]:
	var used_indices: Dictionary = {}

	for key in ESMManager.lands.keys():
		var land: LandRecord = ESMManager.lands[key]
		if not land or not land.has_textures():
			continue

		# Check all texture indices in this cell
		for y in 16:
			for x in 16:
				var idx := land.get_texture_index(x, y)
				used_indices[idx] = true

	# Convert to sorted array
	var result: Array[int] = []
	for idx: int in used_indices.keys():
		result.append(idx)
	result.sort()
	return result


## Add default texture to slot 0
func _add_default_texture(terrain_assets: Terrain3DAssets) -> void:
	var asset := Terrain3DTextureAsset.new()
	asset.name = "Default"

	# Try to load default texture
	var texture := TextureLoader.load_texture(DEFAULT_TEXTURE_PATH)
	if texture and texture != TextureLoader._get_fallback_texture():
		asset.albedo_texture = texture
	else:
		# Create a simple gray texture as fallback
		var img := Image.create(64, 64, false, Image.FORMAT_RGB8)
		img.fill(Color(0.4, 0.35, 0.3))  # Brownish-gray default
		asset.albedo_texture = ImageTexture.create_from_image(img)

	terrain_assets.set_texture(0, asset)
	_slot_mapping[0] = 0
	_next_slot = 1


## Load a single LTEX texture and add to Terrain3D
func _load_ltex_texture(terrain_assets: Terrain3DAssets, mw_index: int) -> bool:
	# MW stores texture_index in VTEX as (LTEX.index + 1)
	var ltex_index := mw_index - 1

	# Find the LTEX record
	var ltex: LandTextureRecord = _find_ltex_by_index(ltex_index)
	if not ltex:
		_stats["textures_failed"] += 1
		return false

	# Load the texture from BSA
	var texture := TextureLoader.load_texture(ltex.texture_path)
	if not texture or texture == TextureLoader._get_fallback_texture():
		push_warning("TerrainTextureLoader: Failed to load texture '%s' for LTEX %d" % [ltex.texture_path, ltex_index])
		_stats["textures_failed"] += 1
		return false

	# Create Terrain3D texture asset
	var asset := Terrain3DTextureAsset.new()
	asset.name = ltex.record_id
	asset.albedo_texture = texture

	# Add to Terrain3D at next available slot
	var slot := _next_slot
	terrain_assets.set_texture(slot, asset)

	# Store mapping
	_slot_mapping[mw_index] = slot
	_texture_assets[mw_index] = asset
	_next_slot += 1

	return true


## Find LTEX record by its texture_index
func _find_ltex_by_index(ltex_index: int) -> LandTextureRecord:
	# ESMManager stores LTEX records by record_id (name), not by index
	# We need to search through all records to find the one with matching index
	for key in ESMManager.land_textures.keys():
		var ltex: LandTextureRecord = ESMManager.land_textures[key]
		if ltex and ltex.texture_index == ltex_index:
			return ltex
	return null


## Get Terrain3D slot for a Morrowind texture index
## Returns 0 (default) if texture wasn't loaded
func get_slot_for_mw_index(mw_index: int) -> int:
	if mw_index in _slot_mapping:
		return _slot_mapping[mw_index]
	return 0  # Default texture


## Get statistics
func get_stats() -> Dictionary:
	return _stats.duplicate()


## Clear all cached data
func clear() -> void:
	_texture_assets.clear()
	_slot_mapping.clear()
	_next_slot = 0
	_stats = {
		"textures_loaded": 0,
		"textures_failed": 0,
		"ltex_records": 0,
	}
