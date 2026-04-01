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
##
## Next-Gen Texture Support (Future-Proofing):
## -------------------------------------------
## This loader is designed to support PBR texture packs when available:
##
## 1. Albedo/Diffuse: Standard color texture (always loaded)
## 2. Normal Map: _n.dds or _normal.dds suffix (optional)
## 3. Roughness/Height: _r.dds or _height.dds suffix (optional)
## 4. Ambient Occlusion: _ao.dds suffix (optional)
##
## PBR textures are auto-detected using common naming conventions:
##   textures/terrain/grass.dds       -> albedo
##   textures/terrain/grass_n.dds     -> normal
##   textures/terrain/grass_r.dds     -> roughness (packed into alpha)
##
## When next-gen texture packs are installed, they will be automatically
## loaded if they follow these naming conventions.
class_name TerrainTextureLoader
extends RefCounted

const TextureLoaderScript := preload("res://src/core/texture/texture_loader.gd")

## Default texture path for index 0 (when no LTEX specified)
const DEFAULT_TEXTURE_PATH := "textures\\_land_default.dds"

## PBR texture suffixes to search for (in priority order)
const NORMAL_SUFFIXES := ["_n", "_normal", "_nrm"]
const HEIGHT_SUFFIXES := ["_h", "_height", "_disp"]
const ROUGHNESS_SUFFIXES := ["_r", "_rough", "_roughness", "_spec"]  # _spec often used for roughness/specular
const AO_SUFFIXES := ["_ao", "_ambient", "_occlusion"]

## Enable PBR texture loading
## When true, auto-detects PBR textures (normal, height, roughness) from texture packs
## Uses external texture directories configured in SettingsManager
var enable_pbr_textures: bool = true

## Cache of loaded texture assets: MW texture_index -> Terrain3DTextureAsset
var _texture_assets: Dictionary = {}

## Map of MW texture indices to Terrain3D slot indices
var _slot_mapping: Dictionary = {}

## Set of MW indices that didn't get slots (to avoid warning spam)
var _unmapped_indices: Dictionary = {}

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
	Log.info("textures", "Loading %d LTEX textures..." % _stats["ltex_records"])

	# First, add a default texture at slot 0
	_add_default_texture(terrain_assets)

	# Collect unique textures from all LAND records
	var unique_indices := _collect_used_texture_indices()
	Log.info("textures", "Found %d unique texture indices in use" % unique_indices.size())

	# Load textures for used indices (limit to 31 since slot 0 is default)
	var loaded := 0
	var first_texture_name := ""
	for mw_index: int in unique_indices:
		if mw_index == 0:
			continue  # Skip default texture index

		if _next_slot >= 32:
			push_warning("TerrainTextureLoader: Maximum texture slots reached (32)")
			break

		var ltex_name := ""
		if _load_ltex_texture(terrain_assets, mw_index):
			if loaded == 0:
				# Get the first texture name for condensed logging
				var ltex_index := mw_index - 1
				var ltex: LandTextureRecord = _find_ltex_by_index(ltex_index)
				if ltex:
					first_texture_name = ltex.texture_path
			loaded += 1

	_stats["textures_loaded"] = loaded

	# Condensed logging
	if loaded > 0:
		if loaded == 1:
			Log.info("textures", "Loaded '%s' (MW idx -> slot)" % first_texture_name)
		else:
			Log.info("textures", "Loaded '%s' and %d more textures (%d failed)" % [first_texture_name, loaded - 1, _stats["textures_failed"]])
	else:
		Log.info("textures", "No textures loaded (%d failed)" % _stats["textures_failed"])

	return loaded


## Collect all texture indices actually used by LAND records, sorted by usage frequency
## This ensures the most commonly used textures get slots when we hit the 32-slot limit
func _collect_used_texture_indices() -> Array[int]:
	# Count usage frequency for each texture index
	var usage_counts: Dictionary = {}  # mw_index -> count
	var cells_with_textures := 0
	var cells_without_textures := 0

	for key: Variant in ESMManager.lands.keys():
		var land: LandRecord = ESMManager.lands[key]
		if not land:
			continue

		if not land.has_textures():
			cells_without_textures += 1
			continue

		cells_with_textures += 1

		# Count all texture indices in this cell
		for y in 16:
			for x in 16:
				var idx := land.get_texture_index(x, y)
				if idx not in usage_counts:
					usage_counts[idx] = 0
				usage_counts[idx] += 1

	Log.info("textures", "Cells with VTEX data: %d, without: %d" % [cells_with_textures, cells_without_textures])
	Log.info("textures", "Total unique texture indices: %d" % usage_counts.size())

	# Sort by usage frequency (most used first) to prioritize popular textures
	var indices_by_usage: Array = []
	for idx: int in usage_counts.keys():
		indices_by_usage.append({"idx": idx, "count": usage_counts[idx]})

	indices_by_usage.sort_custom(func(a: Variant, b: Variant) -> bool: return a["count"] > b["count"])

	# Convert to array of indices (sorted by frequency, most used first)
	var result: Array[int] = []
	for entry: Variant in indices_by_usage:
		result.append(entry["idx"])

	# Print usage statistics
	if result.size() <= 20:
		var details := []
		for entry: Variant in indices_by_usage:
			details.append("idx%d:%d" % [entry["idx"], entry["count"]])
		Log.debug("textures", "Texture usage (idx:count): %s" % ", ".join(details))
	else:
		# Show top 32 (what will fit in slots) plus any that won't fit
		var top_details := []
		for i in mini(32, indices_by_usage.size()):
			top_details.append("idx%d:%d" % [indices_by_usage[i]["idx"], indices_by_usage[i]["count"]])
		Log.debug("textures", "Top 32 textures by usage: %s" % ", ".join(top_details))

		if result.size() > 32:
			var overflow_details := []
			for i in range(32, mini(40, indices_by_usage.size())):
				overflow_details.append("idx%d:%d" % [indices_by_usage[i]["idx"], indices_by_usage[i]["count"]])
			Log.warn("textures", "%d textures won't get slots. First overflow: %s" % [
				result.size() - 32, ", ".join(overflow_details)])

	return result


## Add default texture to slot 0
func _add_default_texture(terrain_assets: Terrain3DAssets) -> void:
	var asset := Terrain3DTextureAsset.new()
	asset.name = "Default"

	# Try to load default texture
	var texture := TextureLoaderScript.load_texture(DEFAULT_TEXTURE_PATH)
	if texture and texture != TextureLoaderScript._get_fallback_texture():
		# Ensure texture has mipmaps for proper terrain rendering
		texture = _ensure_mipmaps(texture)
		asset.albedo_texture = texture
	else:
		# Create a simple gray texture as fallback with mipmaps
		var img := Image.create(64, 64, false, Image.FORMAT_RGB8)
		img.fill(Color(0.4, 0.35, 0.3))  # Brownish-gray default
		img.generate_mipmaps()
		img.compress(Image.COMPRESS_BPTC)
		asset.albedo_texture = ImageTexture.create_from_image(img)

	terrain_assets.set_texture_asset(0, asset)
	_slot_mapping[0] = 0
	_next_slot = 1
	Log.info("textures", "Default texture added to slot 0")


## Load a single LTEX texture and add to Terrain3D
## Includes PBR texture detection for next-gen texture packs
func _load_ltex_texture(terrain_assets: Terrain3DAssets, mw_index: int) -> bool:
	# MW stores texture_index in VTEX as (LTEX.index + 1)
	var ltex_index := mw_index - 1

	# Find the LTEX record
	var ltex: LandTextureRecord = _find_ltex_by_index(ltex_index)
	if not ltex:
		push_warning("TerrainTextureLoader: No LTEX record found for index %d (mw_index=%d)" % [ltex_index, mw_index])
		_stats["textures_failed"] += 1
		return false

	# Load the albedo/diffuse texture from BSA
	var texture := TextureLoaderScript.load_texture(ltex.texture_path)
	if not texture or texture == TextureLoaderScript._get_fallback_texture():
		push_warning("TerrainTextureLoader: Failed to load texture '%s' for LTEX %d" % [ltex.texture_path, ltex_index])
		_stats["textures_failed"] += 1
		return false

	# Ensure texture has mipmaps for proper terrain rendering at distance
	texture = _ensure_mipmaps(texture)

	# Create Terrain3D texture asset
	var asset := Terrain3DTextureAsset.new()
	asset.name = ltex.record_id
	asset.albedo_texture = texture

	# Try to load PBR textures if enabled (next-gen texture support)
	if enable_pbr_textures:
		_try_load_pbr_textures(asset, ltex.texture_path)

	# Add to Terrain3D at next available slot
	var slot := _next_slot
	terrain_assets.set_texture_asset(slot, asset)

	# Store mapping: MW index -> Terrain3D slot
	_slot_mapping[mw_index] = slot
	_texture_assets[mw_index] = asset
	_next_slot += 1

	# Verbose logging removed - use print_debug_summary() for details if needed
	return true


## Try to load PBR textures (normal, height, roughness, AO) for a texture
## These are auto-detected using common naming conventions
func _try_load_pbr_textures(asset: Terrain3DTextureAsset, base_path: String) -> void:
	# Get base path without extension
	var base_name := _get_path_without_extension(base_path)

	# Try to load normal map
	var normal_tex := _try_load_texture_with_suffixes(base_name, NORMAL_SUFFIXES)
	if normal_tex:
		normal_tex = _ensure_mipmaps(normal_tex)
		asset.normal_texture = normal_tex
		if _stats["textures_loaded"] < 3:
			Log.debug("textures", "Found normal map for %s" % base_path)

	# Note: Terrain3DTextureAsset has limited PBR support
	# Height and roughness could be packed into albedo alpha or separate channels
	# For now, we document the capability for future Terrain3D versions


## Try to load a texture with any of the given suffixes
func _try_load_texture_with_suffixes(base_name: String, suffixes: Array) -> ImageTexture:
	for suffix: String in suffixes:
		# Try common extensions
		for ext: String in [".dds", ".png", ".tga"]:
			var path := base_name + suffix + ext
			var tex := TextureLoaderScript.load_texture(path)
			if tex and tex != TextureLoaderScript._get_fallback_texture():
				return tex
	return null


## Get path without file extension
func _get_path_without_extension(path: String) -> String:
	var dot_pos := path.rfind(".")
	if dot_pos > 0:
		return path.substr(0, dot_pos)
	return path


## Find LTEX record by its texture_index
func _find_ltex_by_index(ltex_index: int) -> LandTextureRecord:
	# ESMManager stores LTEX records by record_id (name), not by index
	# We need to search through all records to find the one with matching index
	for key: Variant in ESMManager.land_textures.keys():
		var ltex: LandTextureRecord = ESMManager.land_textures[key]
		if ltex and ltex.texture_index == ltex_index:
			return ltex
	return null


## Get Terrain3D slot for a Morrowind texture index
## Returns 0 (default) if texture wasn't loaded
func get_slot_for_mw_index(mw_index: int) -> int:
	if mw_index in _slot_mapping:
		return _slot_mapping[mw_index]
	# Track unmapped indices (only warn once per index to reduce spam)
	if mw_index != 0 and mw_index not in _unmapped_indices:
		_unmapped_indices[mw_index] = true
		# Only warn for the first few unmapped indices
		if _unmapped_indices.size() <= 5:
			push_warning("TerrainTextureLoader: MW index %d not in slot mapping, using default texture" % mw_index)
		elif _unmapped_indices.size() == 6:
			push_warning("TerrainTextureLoader: Suppressing further unmapped index warnings (use print_unmapped_summary() for details)")
	return 0  # Default texture


## Get statistics
func get_stats() -> Dictionary:
	return _stats.duplicate()


## Clear all cached data
func clear() -> void:
	_texture_assets.clear()
	_slot_mapping.clear()
	_unmapped_indices.clear()
	_next_slot = 0
	_stats = {
		"textures_loaded": 0,
		"textures_failed": 0,
		"ltex_records": 0,
	}


## Print summary of unmapped texture indices (those that fell back to default)
func print_unmapped_summary() -> void:
	if _unmapped_indices.is_empty():
		Log.info("textures", "No unmapped texture indices (all textures have slots)")
		return
	var indices: Array = _unmapped_indices.keys()
	indices.sort()
	Log.info("textures", "%d unmapped MW indices (using default texture): %s" % [
		indices.size(), str(indices)])


## Ensure a texture has mipmaps, decompressing if necessary
## DDS textures from Morrowind are often DXT compressed and can't have mipmaps
## generated directly - we need to decompress first
func _ensure_mipmaps(texture: ImageTexture) -> ImageTexture:
	if not texture:
		return texture

	var img := texture.get_image()
	if not img:
		push_warning("TerrainTextureLoader: Cannot get image from texture for mipmap generation")
		return texture

	# If already has mipmaps, we're good
	if img.has_mipmaps():
		return texture

	var original_format := img.get_format()
	var was_compressed := img.is_compressed()

	# If compressed, decompress first before generating mipmaps
	if was_compressed:
		var decompress_err := img.decompress()
		if decompress_err != OK:
			push_warning("TerrainTextureLoader: Failed to decompress image (format=%d) for mipmap generation" % original_format)
			return texture

	# Now generate mipmaps
	var err := img.generate_mipmaps()
	if err != OK:
		push_warning("TerrainTextureLoader: Failed to generate mipmaps (format=%d, was_compressed=%s)" % [original_format, was_compressed])
		return texture

	# Verify mipmaps were created
	if not img.has_mipmaps():
		push_warning("TerrainTextureLoader: generate_mipmaps() succeeded but image still has no mipmaps")
		return texture

	# Recompress to BC7 (BPTC) for ~75% VRAM savings with near-lossless quality
	var compress_err := img.compress(Image.COMPRESS_BPTC)
	if compress_err != OK:
		Log.warn("textures", "BC7 compression failed (format=%d), using uncompressed" % original_format)

	# Create new texture from the mipmapped (and possibly compressed) image
	var new_texture := ImageTexture.create_from_image(img)

	# Double-check the new texture
	var verify_img := new_texture.get_image()
	if verify_img and not verify_img.has_mipmaps():
		push_warning("TerrainTextureLoader: Mipmaps lost when creating ImageTexture")

	return new_texture


## Print debug summary of loaded textures
func print_debug_summary() -> void:
	var lines: Array[String] = []
	lines.append("=== TerrainTextureLoader Debug Summary ===")
	lines.append("  Total slots used: %d" % _next_slot)
	lines.append("  Slot mappings (MW index -> Terrain3D slot):")
	var sorted_keys := _slot_mapping.keys()
	sorted_keys.sort()
	for mw_idx: int in sorted_keys:
		var slot: int = _slot_mapping[mw_idx]
		var asset_name := ""
		if mw_idx in _texture_assets:
			var asset: Terrain3DTextureAsset = _texture_assets[mw_idx]
			asset_name = asset.name if asset else "null"
		lines.append("    MW %d -> slot %d (%s)" % [mw_idx, slot, asset_name])
	lines.append("===========================================")
	Log.info("textures", "\n".join(lines))


## Verify textures are properly set in Terrain3DAssets
func verify_terrain_assets(terrain_assets: Terrain3DAssets) -> void:
	var lines: Array[String] = []
	lines.append("=== Terrain3DAssets Verification ===")
	var tex_count := terrain_assets.get_texture_count()
	lines.append("  Terrain3DAssets texture count: %d" % tex_count)
	for i in range(mini(tex_count, 10)):  # Check first 10 slots
		@warning_ignore("untyped_declaration")
		var asset = terrain_assets.get_texture_asset(i)
		if asset:
			var has_albedo := asset.albedo_texture != null
			var tex_size := ""
			if asset.albedo_texture:
				@warning_ignore("untyped_declaration")
				var img = asset.albedo_texture.get_image()
				if img:
					tex_size = "%dx%d" % [img.get_width(), img.get_height()]
					tex_size += " mipmaps=%s" % str(img.has_mipmaps())
			lines.append("    Slot %d: %s (albedo=%s) %s" % [i, asset.name, has_albedo, tex_size])
		else:
			lines.append("    Slot %d: <empty>" % i)
	lines.append("=====================================")
	Log.info("textures", "\n".join(lines))
