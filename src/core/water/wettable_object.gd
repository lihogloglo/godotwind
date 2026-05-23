## WettableObject - opt-in retained wetness for movable objects.
##
## Attach as a child of the object that should retain wetness. The component
## adapts safe StandardMaterial3D surfaces to the object wet shader, registers
## their material RIDs with WetnessManager, and unregisters on teardown.
class_name WettableObject
extends Node

const OBJECT_WET_SHADER := preload("res://src/core/shaders/object_wet.gdshader")

@export var auto_adapt_materials: bool = true
@export_range(0.0, 2.0, 0.01) var sample_radius_multiplier: float = 0.6
@export var restore_materials_on_exit: bool = false

var _root: Node3D = null
var _material_rids: Array[RID] = []
var _original_materials: Array[Dictionary] = []
var _registered: bool = false


func _ready() -> void:
	_root = get_parent() as Node3D
	if _root == null:
		return

	var local_bounds := _compute_local_bounds(_root)
	if not local_bounds.has_volume():
		return

	if auto_adapt_materials:
		_adapt_materials(_root)
	else:
		_collect_shader_material_rids(_root)

	if _material_rids.is_empty():
		return

	var horizontal_extent: float = maxf(local_bounds.size.x, local_bounds.size.z)
	var sample_radius: float = maxf(horizontal_extent * sample_radius_multiplier, 0.05)
	if WetnessManager and WetnessManager.has_method("register_wettable_object"):
		WetnessManager.register_wettable_object(_root, _material_rids, local_bounds, sample_radius)
		_registered = true


func _exit_tree() -> void:
	if _registered and WetnessManager and WetnessManager.has_method("unregister_memory_holder"):
		WetnessManager.unregister_memory_holder(_root)
	_registered = false

	if restore_materials_on_exit:
		for entry: Dictionary in _original_materials:
			var mesh_instance: MeshInstance3D = entry.get("mesh_instance")
			if mesh_instance == null or not is_instance_valid(mesh_instance):
				continue
			var surface: int = int(entry.get("surface", -1))
			var material: Material = entry.get("material")
			if surface < 0:
				mesh_instance.material_override = material
			else:
				mesh_instance.set_surface_override_material(surface, material)


func _adapt_materials(node: Node) -> void:
	if node is MeshInstance3D:
		_adapt_mesh_instance(node as MeshInstance3D)
	for child: Node in node.get_children():
		if child == self:
			continue
		_adapt_materials(child)


func _adapt_mesh_instance(mesh_instance: MeshInstance3D) -> void:
	if mesh_instance.material_override != null:
		var override_material := mesh_instance.material_override
		var wet_override := _make_wet_material(override_material)
		if wet_override != null:
			_original_materials.append({
				"mesh_instance": mesh_instance,
				"surface": -1,
				"material": override_material,
			})
			mesh_instance.material_override = wet_override
			_material_rids.append(wet_override.get_rid())
		return

	if mesh_instance.mesh == null:
		return

	for surface: int in mesh_instance.mesh.get_surface_count():
		var material := mesh_instance.get_active_material(surface)
		var wet_material := _make_wet_material(material)
		if wet_material == null:
			continue
		_original_materials.append({
			"mesh_instance": mesh_instance,
			"surface": surface,
			"material": mesh_instance.get_surface_override_material(surface),
		})
		mesh_instance.set_surface_override_material(surface, wet_material)
		_material_rids.append(wet_material.get_rid())


func _make_wet_material(material: Material) -> ShaderMaterial:
	if not _is_safe_standard_material(material):
		return null

	var source := material as StandardMaterial3D
	var wet := ShaderMaterial.new()
	wet.shader = OBJECT_WET_SHADER
	wet.set_shader_parameter("albedo_color", source.albedo_color)
	wet.set_shader_parameter("albedo_texture", source.albedo_texture)
	wet.set_shader_parameter("roughness", source.roughness)
	wet.set_shader_parameter("metallic", source.metallic)
	wet.set_shader_parameter("specular", source.metallic_specular)
	wet.set_shader_parameter("normal_enabled", source.normal_enabled and source.normal_texture != null)
	wet.set_shader_parameter("normal_texture", source.normal_texture)
	wet.set_shader_parameter("normal_scale", source.normal_scale)
	wet.set_shader_parameter("live_contact_from_compositor", false)
	wet.set_shader_parameter("dynamic_water_enabled", false)
	wet.set_shader_parameter("wet_line_y", -1000.0)
	return wet


func _is_safe_standard_material(material: Material) -> bool:
	if not (material is StandardMaterial3D):
		return false
	var standard := material as StandardMaterial3D
	if standard.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
		return false
	if standard.emission_enabled:
		return false
	return true


func _collect_shader_material_rids(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.material_override is ShaderMaterial:
			_material_rids.append(mesh_instance.material_override.get_rid())
		elif mesh_instance.mesh != null:
			for surface: int in mesh_instance.mesh.get_surface_count():
				var material := mesh_instance.get_surface_override_material(surface)
				if material is ShaderMaterial:
					_material_rids.append(material.get_rid())
	for child: Node in node.get_children():
		if child == self:
			continue
		_collect_shader_material_rids(child)


func _compute_local_bounds(root: Node3D) -> AABB:
	var aabbs: Array[AABB] = []
	_collect_local_bounds(root, root, aabbs)
	if aabbs.is_empty():
		return AABB()
	var bounds: AABB = aabbs[0]
	for i: int in range(1, aabbs.size()):
		bounds = bounds.merge(aabbs[i])
	return bounds


func _collect_local_bounds(node: Node, root: Node3D, out: Array[AABB]) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh != null:
			var root_from_mesh := root.global_transform.affine_inverse() * mesh_instance.global_transform
			var local_aabb: AABB = root_from_mesh * mesh_instance.mesh.get_aabb()
			out.append(local_aabb)

	for child: Node in node.get_children():
		if child == self:
			continue
		_collect_local_bounds(child, root, out)
