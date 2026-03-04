## MeshVisibilityUtils - Centralized mesh visibility management
##
## Provides utilities for hiding meshes that shouldn't render:
## - Materialless meshes (collision geometry, placeholders)
## - Meshes with empty/invalid materials (no texture)
##
## NOTE: LOD nodes (_LOD1, _LOD2, _LOD3) are NO LONGER hidden.
## They are configured with visibility_range by NativeStreamingManager for proper LOD transitions.
##
## This consolidates duplicate code from:
## - ReferenceInstantiator._hide_lod_nodes()
## - CellManager._hide_lod_nodes()
class_name MeshVisibilityUtils
extends RefCounted


## Check if a mesh name indicates it's a LOD variant
static func is_lod_node_name(mesh_name: String) -> bool:
	return mesh_name.ends_with("_LOD1") or mesh_name.ends_with("_LOD2") or mesh_name.ends_with("_LOD3")


## Check if a MeshInstance3D has a valid renderable material
## Returns false for:
## - No material at all (null)
## - Material with no albedo texture (renders white) - unless it's a LOD node
## - Collision geometry meshes
## Parameters:
##   mi: The MeshInstance3D to check
##   for_lod_node: If true, be more permissive (LOD nodes shouldn't be hidden for white materials)
static func has_valid_material(mi: MeshInstance3D, for_lod_node: bool = false) -> bool:
	if not mi.mesh:
		return false

	# Check material_override first
	if mi.material_override:
		return _is_material_renderable(mi.material_override, for_lod_node)

	# Check surface materials (MeshInstance3D override first, then mesh resource)
	if mi.mesh.get_surface_count() == 0:
		return false

	var surface_mat: Material = mi.get_surface_override_material(0)
	if not surface_mat:
		surface_mat = mi.mesh.surface_get_material(0)
	if surface_mat:
		return _is_material_renderable(surface_mat, for_lod_node)

	return false


## Check if a material is actually renderable (has visible content)
## Empty StandardMaterial3D without textures renders as white/flat
## NOTE: for_lod_node parameter allows LOD nodes to be more permissive
static func _is_material_renderable(mat: Material, for_lod_node: bool = false) -> bool:
	if mat == null:
		return false

	# ShaderMaterial - check if it has a texture
	if mat is ShaderMaterial:
		var shader_mat := mat as ShaderMaterial
		# Check common shader parameter names for textures
		var albedo_tex: Variant = shader_mat.get_shader_parameter("albedo_texture")
		if albedo_tex is Texture2D:
			return true
		var texture: Variant = shader_mat.get_shader_parameter("texture_albedo")
		if texture is Texture2D:
			return true
		# ShaderMaterial with no texture - still allow (might be intentional)
		return true

	# StandardMaterial3D - check for albedo texture or non-default color
	if mat is StandardMaterial3D:
		var std_mat := mat as StandardMaterial3D

		# Has albedo texture - definitely renderable
		if std_mat.albedo_texture:
			return true

		# LOD nodes should always be considered valid if they have a material
		if for_lod_node:
			return true

		# Has vertex colors — renderable even without texture.
		# Must check BEFORE luminance filter: Morrowind glow meshes have
		# white albedo + vertex colors for lighting, and would be incorrectly hidden.
		if std_mat.vertex_color_use_as_albedo:
			return true

		# Hide textureless meshes with high-luminance colors (near-white/light gray).
		# These are typically collision geometry or placeholders that leaked through
		# the RootCollisionNode filter. Legitimate near-white textured surfaces
		# (stone, plaster, bone, snow) are caught above by the albedo_texture check.
		# Threshold 0.85 avoids hiding intentionally colored geometry (brown wood,
		# gray stone trim) while catching collision mesh diffuse values (~0.9-1.0).
		var color := std_mat.albedo_color
		var luminance := color.r * 0.299 + color.g * 0.587 + color.b * 0.114
		if luminance > 0.85:
			return false

		# Any lower-luminance color without texture is considered intentional
		return true

	# Other material types - assume valid
	return true


## Hide materialless meshes in a node tree (LOD nodes are NO LONGER hidden)
## This is the single source of truth for mesh hiding logic
##
## Parameters:
##   node: Root node to process (recurses into children)
##   debug: If true, prints debug messages for hidden meshes
static func hide_lod_and_materialless(node: Node, debug: bool = false) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var mesh_name: String = mi.name
		var is_lod := is_lod_node_name(mesh_name)

		# LOD nodes (_LOD1, _LOD2, _LOD3) are NO LONGER hidden
		# They are configured with visibility_range by NativeStreamingManager
		# for proper distance-based LOD transitions

		# Hide meshes without valid renderable material
		# For LOD nodes, use permissive check (don't hide for white materials)
		if mi.visible and not has_valid_material(mi, is_lod):
			# Skip LOD nodes - even if they have no material, they should be visible
			# (visibility_range will control when they render)
			if not is_lod:
				mi.visible = false
				if debug:
					Log.debug("streaming", "[MeshVisibility] Hiding materialless/white mesh: %s" % mesh_name)

	# Recurse into children
	for child in node.get_children():
		hide_lod_and_materialless(child, debug)


## Convenience function that matches the old API
## Use hide_lod_and_materialless() for new code
static func hide_lod_nodes(node: Node, debug: bool = false) -> void:
	hide_lod_and_materialless(node, debug)
