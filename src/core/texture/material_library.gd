## MaterialLibrary - Global material cache for sharing materials across objects
##
## Instead of creating a new StandardMaterial3D for each mesh, this library
## maintains a cache of materials keyed by their visual properties (texture path,
## transparency mode, vertex colors, etc.).
##
## Benefits:
## - Reduced VRAM usage (same material instance shared by many meshes)
## - Fewer material state changes during rendering
## - Better batching opportunities for the GPU
##
## Usage:
##   var mat := MaterialLibrary.get_or_create_material(texture_path, properties)
##   mesh_instance.material_override = mat
class_name MaterialLibrary
extends RefCounted

## Material key structure for caching
## Key format: "texture_path|transparency_mode|cull_mode|vertex_colors|emission"

## Global material cache: material_key -> StandardMaterial3D
static var _cache: Dictionary = {}

## Statistics
static var _stats: Dictionary = {
	"materials_created": 0,
	"cache_hits": 0,
	"cache_misses": 0,
}

## Material properties that affect the cache key
class MaterialProperties:
	var texture_path: String = ""
	var transparency_mode: BaseMaterial3D.Transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	var cull_mode: BaseMaterial3D.CullMode = BaseMaterial3D.CULL_BACK
	var use_vertex_colors: bool = false
	var has_emission: bool = false
	var emission_color: Color = Color.BLACK
	var emission_energy: float = 1.0
	var alpha_scissor_threshold: float = 0.5
	var shading_mode: BaseMaterial3D.ShadingMode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	var specular: float = 0.5
	var roughness: float = 1.0
	var metallic: float = 0.0
	var albedo_color: Color = Color.WHITE

	func get_key() -> String:
		# Create a unique key based on all properties that affect appearance
		var parts := PackedStringArray()
		parts.append(texture_path.to_lower())
		parts.append(str(transparency_mode))
		parts.append(str(cull_mode))
		parts.append("vc" if use_vertex_colors else "")
		if has_emission:
			parts.append("em_%s_%.2f" % [emission_color.to_html(), emission_energy])
		if transparency_mode == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
			parts.append("as%.2f" % alpha_scissor_threshold)
		if albedo_color != Color.WHITE:
			parts.append("c_%s" % albedo_color.to_html())
		return "|".join(parts)


## Get or create a material with the specified properties
## Returns a shared material instance - do NOT modify the returned material
static func get_or_create_material(props: MaterialProperties) -> StandardMaterial3D:
	var key := props.get_key()

	if key in _cache:
		_stats["cache_hits"] += 1
		return _cache[key]

	_stats["cache_misses"] += 1

	# Create new material
	var mat := StandardMaterial3D.new()

	# Basic properties
	mat.transparency = props.transparency_mode
	mat.cull_mode = props.cull_mode
	mat.shading_mode = props.shading_mode
	mat.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	mat.metallic = props.metallic
	mat.metallic_specular = props.specular
	mat.roughness = props.roughness
	mat.albedo_color = props.albedo_color

	# Texture filtering - critical for visual quality at distance
	# Use anisotropic filtering with mipmaps for sharp textures at oblique angles
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

	# Vertex colors
	if props.use_vertex_colors:
		mat.vertex_color_use_as_albedo = true

	# Alpha scissor
	if props.transparency_mode == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
		mat.alpha_scissor_threshold = props.alpha_scissor_threshold

	# Emission
	if props.has_emission:
		mat.emission_enabled = true
		mat.emission = props.emission_color
		mat.emission_energy_multiplier = props.emission_energy

	# Load texture if specified
	if not props.texture_path.is_empty():
		var texture := TextureLoader.load_texture(props.texture_path)
		if texture:
			mat.albedo_texture = texture
		else:
			# Use fallback color for missing textures
			mat.albedo_color = Color(1.0, 0.0, 1.0)  # Magenta

	# Cache the material
	_cache[key] = mat
	_stats["materials_created"] += 1

	return mat


## Create material properties from NIF material/texturing data
## This extracts the relevant properties from NIF records
static func props_from_nif_material(
	material_prop: Dictionary,
	texturing_prop: Dictionary,
	alpha_prop: Dictionary,
	vertex_color_prop: Dictionary
) -> MaterialProperties:
	var props := MaterialProperties.new()

	# Extract texture path
	if texturing_prop and texturing_prop.get("base_texture"):
		props.texture_path = texturing_prop["base_texture"]

	# Extract material properties
	if material_prop:
		props.albedo_color = material_prop.get("diffuse_color", Color.WHITE)
		props.specular = material_prop.get("glossiness", 0.5) / 100.0
		props.roughness = 1.0 - props.specular

		# Check for emission
		var emit_color: Color = material_prop.get("emissive_color", Color.BLACK)
		if emit_color.r > 0.01 or emit_color.g > 0.01 or emit_color.b > 0.01:
			props.has_emission = true
			props.emission_color = emit_color
			props.emission_energy = material_prop.get("emissive_mult", 1.0)

	# Extract alpha properties
	if alpha_prop:
		var alpha_mode: int = alpha_prop.get("alpha_blend_mode", 0)
		var alpha_test: bool = alpha_prop.get("alpha_test", false)
		var alpha_threshold: float = alpha_prop.get("alpha_test_threshold", 128) / 255.0

		if alpha_test:
			props.transparency_mode = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			props.alpha_scissor_threshold = alpha_threshold
		elif alpha_mode > 0:
			props.transparency_mode = BaseMaterial3D.TRANSPARENCY_ALPHA

	# Vertex colors
	if vertex_color_prop and vertex_color_prop.get("use_vertex_colors", false):
		props.use_vertex_colors = true

	return props


## Get or create a simple textured material (convenience method)
static func get_textured_material(texture_path: String, transparent: bool = false) -> StandardMaterial3D:
	var props := MaterialProperties.new()
	props.texture_path = texture_path
	if transparent:
		props.transparency_mode = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	return get_or_create_material(props)


## Get or create a simple colored material (for placeholders, debug, etc.)
static func get_colored_material(color: Color, transparent: bool = false) -> StandardMaterial3D:
	var props := MaterialProperties.new()
	props.albedo_color = color
	if transparent or color.a < 1.0:
		props.transparency_mode = BaseMaterial3D.TRANSPARENCY_ALPHA
	return get_or_create_material(props)


## Clear the material cache (useful for reloading)
static func clear_cache() -> void:
	_cache.clear()
	_stats = {
		"materials_created": 0,
		"cache_hits": 0,
		"cache_misses": 0,
	}


## Get cache statistics
static func get_stats() -> Dictionary:
	var stats := _stats.duplicate()
	stats["cached_materials"] = _cache.size()
	if _stats["cache_hits"] + _stats["cache_misses"] > 0:
		stats["hit_rate"] = float(_stats["cache_hits"]) / float(_stats["cache_hits"] + _stats["cache_misses"])
	else:
		stats["hit_rate"] = 0.0
	return stats


## Get the number of unique materials in cache
static func get_cache_size() -> int:
	return _cache.size()


## Debug: Print all cached materials
static func print_cache_contents() -> void:
	print("MaterialLibrary Cache (%d materials):" % _cache.size())
	for key in _cache:
		var mat: StandardMaterial3D = _cache[key]
		var tex_name := mat.albedo_texture.resource_path.get_file() if mat.albedo_texture else "none"
		print("  %s -> %s" % [key.substr(0, 50), tex_name])
