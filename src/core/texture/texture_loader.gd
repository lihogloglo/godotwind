## Texture Loader - Loads textures from BSA archives
## Supports DDS format (Morrowind's texture format) with custom loader for malformed files
class_name TextureLoader
extends RefCounted

# Preload custom DDS loader for handling malformed Morrowind DDS files
const DDS := preload("res://src/core/texture/dds_loader.gd")

# Texture cache: normalized_path -> ImageTexture
static var _cache: Dictionary = {}

# LRU tracking: Array of normalized paths in access order (oldest first)
static var _lru_order: Array[String] = []

# Maximum textures to keep in cache (prevents unbounded memory growth)
const MAX_CACHE_SIZE: int = 2000

# Resolved path cache: input_path -> resolved_full_path (avoids re-probing BSA)
static var _path_cache: Dictionary = {}

# Fallback texture for missing textures
static var _fallback_texture: ImageTexture = null

# Statistics
static var textures_loaded: int = 0
static var cache_hits: int = 0
static var load_failures: int = 0
static var lru_evictions: int = 0


## Load a texture from BSA archives
## Returns ImageTexture or fallback texture if loading fails
static func load_texture(texture_path: String) -> ImageTexture:
	if texture_path.is_empty():
		return _get_fallback_texture()

	# Normalize path for cache lookup
	var normalized := _normalize_path(texture_path)

	# Check cache first
	if _cache.has(normalized):
		cache_hits += 1
		# Update LRU - move to end (most recently used)
		var idx := _lru_order.find(normalized)
		if idx >= 0:
			_lru_order.remove_at(idx)
			_lru_order.append(normalized)
		return _cache[normalized]

	# Try to find the texture with various extensions
	var data := _extract_texture_data(normalized)

	if data.is_empty():
		load_failures += 1
		return _get_fallback_texture()

	# Determine format and load image
	var image: Image = null

	# Check magic bytes to determine format
	if data.size() >= 4:
		var magic := data.decode_u32(0)
		if magic == 0x20534444:  # "DDS " magic
			# Use custom DDS loader with base_mip_only=true
			# Morrowind DDS files have truncated/corrupted mipmap chains that cause
			# Godot's Image.create_from_data to fail. We load base level only and
			# generate proper mipmaps ourselves below.
			image = DDS.load_from_buffer(data, true)

	# If not DDS or DDS loading failed, try other formats
	if image == null or image.is_empty():
		image = Image.new()
		var err := image.load_tga_from_buffer(data)
		if err != OK or image.is_empty():
			err = image.load_bmp_from_buffer(data)
		if err != OK or image.is_empty():
			image = null

	if image == null or image.is_empty():
		load_failures += 1
		return _get_fallback_texture()

	# Generate mipmaps if not present - critical for proper texture filtering at distance
	if not image.has_mipmaps():
		# For compressed formats (DXT), decompress first then generate mipmaps
		if image.is_compressed():
			image.decompress()
		image.generate_mipmaps()

	# Create texture from image
	var texture := ImageTexture.create_from_image(image)
	if texture == null:
		load_failures += 1
		return _get_fallback_texture()

	# LRU eviction if cache is full
	while _cache.size() >= MAX_CACHE_SIZE and not _lru_order.is_empty():
		var oldest: String = _lru_order.pop_front()
		_cache.erase(oldest)
		lru_evictions += 1

	# Cache the texture and add to LRU
	_cache[normalized] = texture
	_lru_order.append(normalized)
	textures_loaded += 1

	return texture


## Try to extract texture data, attempting multiple path variations and extensions
## Uses NifSkope-style path resolution:
## 1. If path contains "textures\" or "textures/", strip everything before it
## 2. If path doesn't start with "textures\", prepend it
## 3. Try multiple extensions (.dds, .tga, .bmp)
## Results are cached to avoid repeated BSA probing
static func _extract_texture_data(normalized_path: String) -> PackedByteArray:
	# Check path cache first - avoid re-probing BSA for known paths
	if _path_cache.has(normalized_path):
		var cached_path: String = _path_cache[normalized_path]
		if cached_path.is_empty():
			return PackedByteArray()  # Known failure
		return BSAManager.extract_file(cached_path)

	# Extensions to try - DDS is most common in Morrowind BSAs
	var extensions := [".dds", ".tga", ".bmp"]

	# NifSkope-style path normalization:
	# Find "textures\" or "textures/" anywhere in the path and strip everything before it
	var base_path := _resolve_texture_path(normalized_path)

	# Get base path without extension
	var ext := base_path.get_extension()
	if not ext.is_empty():
		base_path = base_path.substr(0, base_path.length() - ext.length() - 1)

	# Try with and without textures\ prefix
	var path_variants: Array[String] = []

	# Primary: with textures\ prefix (how most BSAs store textures)
	if not base_path.begins_with("textures\\"):
		path_variants.append("textures\\" + base_path)
	path_variants.append(base_path)

	# Try each path variant with each extension
	for path_base: String in path_variants:
		for try_ext: String in extensions:
			var full_path: String = path_base + try_ext
			var data: PackedByteArray = BSAManager.extract_file(full_path)
			if not data.is_empty():
				# Cache the successful path
				_path_cache[normalized_path] = full_path
				return data

	# Cache the failure (empty string) to avoid re-probing
	_path_cache[normalized_path] = ""

	# Debug: Log the failure for troubleshooting
	if OS.is_debug_build():
		push_warning("TextureLoader: Failed to find texture, tried paths based on: %s" % normalized_path)

	return PackedByteArray()


## Resolve texture path using NifSkope-style logic
## Handles paths like "textures\tx_wood.dds", "tx_wood.dds", "data files\textures\tx_wood.dds"
static func _resolve_texture_path(path: String) -> String:
	# Look for "textures\" or "textures/" anywhere in the path
	var tex_idx := path.find("textures\\")
	if tex_idx == -1:
		tex_idx = path.find("textures/")

	if tex_idx != -1:
		# Found "textures\" - extract from there (including the prefix)
		return path.substr(tex_idx)

	# No textures prefix found - strip any leading path separators
	var result := path
	while result.begins_with("\\") or result.begins_with("/"):
		result = result.substr(1)

	return result


## Load texture and apply to material
## Modifies the material's albedo_texture
static func apply_texture_to_material(material: StandardMaterial3D) -> bool:
	if material == null:
		return false

	# Get texture path from metadata
	if not material.has_meta("texture_path"):
		return false

	var texture_path: String = material.get_meta("texture_path")
	if texture_path.is_empty():
		return false

	var texture := load_texture(texture_path)
	if texture == null:
		return false

	# Apply to material
	material.albedo_texture = texture

	# Remove metadata since we've processed it
	material.remove_meta("texture_path")

	return true


## Recursively apply textures to all materials in a node hierarchy
static func apply_textures_to_node(node: Node3D) -> int:
	var count := 0

	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D

		# Check material override
		if mesh_instance.material_override is StandardMaterial3D:
			if apply_texture_to_material(mesh_instance.material_override as StandardMaterial3D):
				count += 1

		# Check surface materials
		if mesh_instance.mesh:
			for i in mesh_instance.mesh.get_surface_count():
				var mat := mesh_instance.get_surface_override_material(i)
				if mat is StandardMaterial3D:
					if apply_texture_to_material(mat as StandardMaterial3D):
						count += 1

	# Recurse into children
	for child in node.get_children():
		if child is Node3D:
			count += apply_textures_to_node(child as Node3D)

	return count


## Get or create fallback texture (magenta/black checkerboard)
static func _get_fallback_texture() -> ImageTexture:
	if _fallback_texture != null:
		return _fallback_texture

	# Create a simple 8x8 checkerboard
	var image := Image.create(8, 8, false, Image.FORMAT_RGB8)
	var magenta := Color(1.0, 0.0, 1.0)
	var black := Color(0.0, 0.0, 0.0)

	for y in 8:
		for x in 8:
			var is_even := (x + y) % 2 == 0
			image.set_pixel(x, y, magenta if is_even else black)

	_fallback_texture = ImageTexture.create_from_image(image)
	return _fallback_texture


## Normalize a texture path for consistent lookups
static func _normalize_path(path: String) -> String:
	# Convert to lowercase and use backslashes (BSA convention)
	var normalized := path.to_lower().replace("/", "\\")

	# Remove leading slashes
	while normalized.begins_with("\\"):
		normalized = normalized.substr(1)

	return normalized


## Clear the texture cache
static func clear_cache() -> void:
	_cache.clear()
	_lru_order.clear()
	_path_cache.clear()
	textures_loaded = 0
	cache_hits = 0
	load_failures = 0
	lru_evictions = 0


## Get cache statistics
static func get_stats() -> Dictionary:
	return {
		"cached": _cache.size(),
		"loaded": textures_loaded,
		"cache_hits": cache_hits,
		"failures": load_failures,
		"lru_evictions": lru_evictions,
		"path_cache_size": _path_cache.size(),
		"max_cache_size": MAX_CACHE_SIZE
	}


## Debug: Try to find a texture and return diagnostic info
static func debug_find_texture(texture_path: String) -> Dictionary:
	var result := {
		"input": texture_path,
		"normalized": "",
		"resolved": "",
		"paths_tried": [],
		"found": false,
		"found_path": ""
	}

	if texture_path.is_empty():
		return result

	var normalized := _normalize_path(texture_path)
	result["normalized"] = normalized

	var resolved := _resolve_texture_path(normalized)
	result["resolved"] = resolved

	var extensions := [".dds", ".tga", ".bmp"]

	var base_path := resolved
	var ext := base_path.get_extension()
	if not ext.is_empty():
		base_path = base_path.substr(0, base_path.length() - ext.length() - 1)

	var path_variants: Array[String] = []
	if not base_path.begins_with("textures\\"):
		path_variants.append("textures\\" + base_path)
	path_variants.append(base_path)

	for path_base: String in path_variants:
		for try_ext: String in extensions:
			var full_path: String = path_base + try_ext
			var paths_tried: Array = result["paths_tried"]
			paths_tried.append(full_path)
			if BSAManager.has_file(full_path):
				result["found"] = true
				result["found_path"] = full_path
				return result

	return result


## Preload textures for a list of paths (useful for batch loading)
static func preload_textures(paths: Array[String]) -> int:
	var loaded := 0
	for path in paths:
		var texture := load_texture(path)
		if texture != _fallback_texture:
			loaded += 1
	return loaded
