## NIFMaterialInfo - Unified material descriptor for NIF objects
##
## Single source of truth for all material properties extracted from NIF data.
## Both GDScript (nif_converter.gd) and C# (NativeNIFConverter.cs) produce this,
## and material_library.gd consumes it to create the appropriate Godot material.
##
## This eliminates the sync problem between the two converter paths and provides
## a clean interface for the SM3D vs ShaderMaterial routing decision.
class_name NIFMaterialInfo
extends RefCounted

# --- Texture paths (resolved from NiSourceTexture) ---
var base_texture: String = ""       ## TextureType.BASE (0) - main diffuse
var dark_texture: String = ""       ## TextureType.DARK (1) - shadow/AO overlay (multiply)
var detail_texture: String = ""     ## TextureType.DETAIL (2) - tiling detail overlay
var gloss_texture: String = ""      ## TextureType.GLOSS (3) - specular/shine map
var glow_texture: String = ""       ## TextureType.GLOW (4) - emission/self-illumination map
var bump_texture: String = ""       ## TextureType.BUMP (5) - normal/bump map
var decal_texture: String = ""      ## TextureType.DECAL (6) - blended overlay

# --- Bump map transform (only valid when bump_texture is set) ---
var bump_map_matrix: Array[float] = [1.0, 0.0, 0.0, 1.0]  ## 2x2 bump transform
var bump_luma_bias: Vector2 = Vector2.ZERO                   ## Env map luma bias

# --- Material colors (from NiMaterialProperty) ---
var diffuse: Color = Color.WHITE
var ambient: Color = Color.WHITE
var specular: Color = Color.BLACK
var emissive: Color = Color.BLACK
var glossiness: float = 0.0   ## 0-128 range from NIF
var material_alpha: float = 1.0

# --- Apply mode (from NiTexturingProperty) ---
var apply_mode: int = 2  ## NIFDefs.ApplyMode.MODULATE (default)

# --- Alpha/transparency (from NiAlphaProperty) ---
var blend_enabled: bool = false
var test_enabled: bool = false
var alpha_threshold: int = 128  ## 0-255 range

# --- Rendering flags ---
var use_vertex_colors: bool = false
var cull_disabled: bool = false    ## from NiStencilProperty draw_mode 2 or 3
var specular_enabled: bool = true  ## from NiSpecularProperty (default true per MW)
var depth_test: bool = true        ## from NiZBufferProperty
var depth_write: bool = true       ## from NiZBufferProperty

# --- Environment map (from NiTextureEffect attached to parent NiNode) ---
var env_map_texture: String = ""
var env_map_type: int = 0      ## 0=projected_light, 1=projected_shadow, 2=env_map, 3=fog_map
var env_map_coord_gen: int = 0 ## 0=world_parallel, 1=world_perspective, 2=sphere_map, 3=specular_cube, 4=diffuse_cube


## Returns true if this material needs features beyond what StandardMaterial3D provides.
## Used to route between SM3D (simple) and MW ShaderMaterial (multi-texture).
func needs_shader_material() -> bool:
	# Any of these require a custom shader
	if not dark_texture.is_empty():
		return true
	if not detail_texture.is_empty():
		return true
	if not decal_texture.is_empty():
		return true
	if not env_map_texture.is_empty():
		return true
	if apply_mode != 2:  # Anything other than MODULATE
		return true
	return false


## Generate a unique cache key for material deduplication.
## Two NIFMaterialInfo with the same key produce visually identical materials.
func get_cache_key() -> String:
	var parts := PackedStringArray()

	# Textures (lowercased for case-insensitive dedup)
	parts.append(base_texture.to_lower())
	if not glow_texture.is_empty():
		parts.append("glow:%s" % glow_texture.to_lower())
	if not bump_texture.is_empty():
		parts.append("bump:%s" % bump_texture.to_lower())
	if not dark_texture.is_empty():
		parts.append("dark:%s" % dark_texture.to_lower())
	if not detail_texture.is_empty():
		parts.append("detail:%s" % detail_texture.to_lower())
	if not decal_texture.is_empty():
		parts.append("decal:%s" % decal_texture.to_lower())
	if not env_map_texture.is_empty():
		parts.append("env:%s_%d_%d" % [env_map_texture.to_lower(), env_map_type, env_map_coord_gen])

	# Apply mode (only if non-default)
	if apply_mode != 2:
		parts.append("am:%d" % apply_mode)

	# Transparency
	if test_enabled:
		parts.append("at:%d" % alpha_threshold)
	elif blend_enabled:
		parts.append("ab")

	# Rendering flags
	if use_vertex_colors:
		parts.append("vc")
	if cull_disabled:
		parts.append("2s")
	if not specular_enabled:
		parts.append("ns")

	# Colors (only if non-default)
	if diffuse != Color.WHITE:
		parts.append("d:%s" % diffuse.to_html())
	if specular != Color.BLACK and specular_enabled:
		parts.append("s:%s" % specular.to_html())
	if emissive.r > 0.01 or emissive.g > 0.01 or emissive.b > 0.01:
		parts.append("e:%s" % emissive.to_html())

	return "|".join(parts)


## Populate from NIF property records (GDScript path).
## Call this with the collected properties from a NiGeometry node.
func populate_from_properties(
	mat_prop: NIFDefs.NiMaterialProperty,
	tex_prop: NIFDefs.NiTexturingProperty,
	alpha_prop: NIFDefs.NiAlphaProperty,
	vc_prop: NIFDefs.NiVertexColorProperty,
	stencil_prop: NIFDefs.NiStencilProperty,
	spec_prop: NIFDefs.NiSpecularProperty,
	zbuf_prop: NIFDefs.NiZBufferProperty,
	reader: NIFReader
) -> void:
	# Material colors
	if mat_prop:
		diffuse = mat_prop.diffuse
		ambient = mat_prop.ambient
		specular = mat_prop.specular
		emissive = mat_prop.emissive
		glossiness = mat_prop.glossiness
		material_alpha = mat_prop.alpha

	# Textures — resolve source indices to file paths
	if tex_prop:
		apply_mode = tex_prop.apply_mode
		bump_map_matrix = tex_prop.bump_map_matrix
		bump_luma_bias = tex_prop.env_map_luma_bias

		for i in range(tex_prop.textures.size()):
			var tex_desc: NIFDefs.TextureDesc = tex_prop.textures[i]
			if not tex_desc.has_texture or tex_desc.source_index < 0:
				continue
			var source := reader.get_record(tex_desc.source_index)
			if not source is NIFDefs.NiSourceTexture:
				continue
			var path: String = (source as NIFDefs.NiSourceTexture).filename
			if path.is_empty():
				continue

			match i:
				0: base_texture = path
				1: dark_texture = path
				2: detail_texture = path
				3: gloss_texture = path
				4: glow_texture = path
				5: bump_texture = path
				6: decal_texture = path

	# Alpha
	if alpha_prop:
		blend_enabled = alpha_prop.blend_enabled()
		test_enabled = alpha_prop.test_enabled()
		alpha_threshold = alpha_prop.threshold

	# Vertex colors
	if vc_prop:
		use_vertex_colors = true

	# Double-sided
	if stencil_prop and (stencil_prop.draw_mode == 2 or stencil_prop.draw_mode == 3):
		cull_disabled = true

	# Specular enable
	if spec_prop:
		specular_enabled = spec_prop.enabled

	# Z-buffer
	if zbuf_prop:
		depth_test = zbuf_prop.test_enabled()
		depth_write = zbuf_prop.write_enabled()


## Populate from C# native info dictionary.
## Maps the Dictionary keys from NativeNIFConverter.cs to our fields.
func populate_from_native_dict(info: Dictionary) -> void:
	# Textures
	base_texture = info.get("texture_path", "")
	glow_texture = info.get("glow_texture_path", "")
	bump_texture = info.get("bump_texture_path", "")
	dark_texture = info.get("dark_texture_path", "")
	detail_texture = info.get("detail_texture_path", "")
	decal_texture = info.get("decal_texture_path", "")
	env_map_texture = info.get("env_map_texture_path", "")

	# Material colors
	if info.has("diffuse"):
		diffuse = info["diffuse"] as Color
	if info.has("ambient"):
		ambient = info["ambient"] as Color
	if info.has("specular"):
		specular = info["specular"] as Color
	if info.has("emissive"):
		emissive = info["emissive"] as Color
	if info.has("glossiness"):
		glossiness = info["glossiness"]
	if info.has("material_alpha"):
		material_alpha = info["material_alpha"]

	# Apply mode
	apply_mode = info.get("apply_mode", 2)

	# Alpha
	blend_enabled = info.get("blend_enabled", false)
	test_enabled = info.get("test_enabled", false)
	alpha_threshold = info.get("alpha_threshold", 128)

	# Flags
	use_vertex_colors = info.get("use_vertex_colors", false)
	specular_enabled = info.get("specular_enabled", true)
	depth_test = info.get("depth_test", true)
	depth_write = info.get("depth_write", true)

	# Double-sided (from stencil draw_mode)
	var draw_mode: int = info.get("draw_mode", -1)
	if draw_mode == 2 or draw_mode == 3:
		cull_disabled = true

	# Bump matrix
	if info.has("bump_map_matrix"):
		bump_map_matrix = info["bump_map_matrix"]
	if info.has("bump_luma_bias"):
		bump_luma_bias = info["bump_luma_bias"]

	# Env map
	env_map_type = info.get("env_map_type", 0)
	env_map_coord_gen = info.get("env_map_coord_gen", 0)
