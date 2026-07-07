## Diagnostic: audits prebaked .res files for material integrity.
##
## Loads multi-part models (ships, buildings) from disk cache and reports:
##   - MeshInstance3D structure (merged vs multi-child)
##   - Per-surface material assignments (are they unique or all the same?)
##   - Texture paths per surface
##
## Run: Godot console -> `run tests/unit/test_material_audit.gd`
## Or from gdUnit4 test runner.
extends GdUnitTestSuite

const MODELS_DIR := "user://cache/models/"

## Multi-part models that MUST have distinct per-surface materials
var _multi_part_models: Array[String] = [
	"x_ex_de_ship_nif",           # Dunmer ship (hull, mast, sail, ropes)
	"x_ex_de_shipwreck_nif",      # Shipwreck
	"x_ex_hlaalu_b_01_nif",       # Hlaalu building
	"x_ex_hlaalu_b_02_nif",
	"x_ex_imp_plat_01_nif",       # Imperial fort platform
	"x_ex_velothi_01_nif",        # Velothi tower
	"x_ex_vivec_b_01_nif",        # Vivec canton
]


func test_multi_surface_materials() -> void:
	var models_path := SettingsManager.get_models_path() if SettingsManager else ""
	if models_path.is_empty():
		print("  SKIP (no models cache configured — SettingsManager unavailable)")
		return

	var total_checked := 0
	var total_broken := 0

	for model_name in _multi_part_models:
		var path := models_path.path_join(model_name + ".res")
		if not FileAccess.file_exists(path):
			print("  SKIP (not cached): %s" % model_name)
			continue

		var packed := ResourceLoader.load(path, "PackedScene") as PackedScene
		if not packed:
			print("  SKIP (load fail): %s" % model_name)
			continue

		var instance := packed.instantiate() as Node3D
		if not instance:
			print("  SKIP (instantiate fail): %s" % model_name)
			continue

		total_checked += 1
		var result := _audit_model(instance, model_name)
		if not result:
			total_broken += 1

		instance.queue_free()

	print("\n=== MATERIAL AUDIT SUMMARY ===")
	print("  Checked: %d models" % total_checked)
	print("  Broken:  %d models" % total_broken)
	assert_int(total_broken).is_equal(0)


func _audit_model(root: Node3D, model_name: String) -> bool:
	print("\n--- %s ---" % model_name)

	# Find all MeshInstance3D nodes
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(root, meshes)
	print("  MeshInstance3D count: %d" % meshes.size())

	var all_tex_paths: Array[String] = []
	var all_ok := true

	for mi in meshes:
		print("  Node: '%s' visible=%s" % [mi.name, mi.visible])
		if not mi.visible or not mi.mesh:
			continue

		var surface_count: int = mi.mesh.get_surface_count()
		print("    Surfaces: %d" % surface_count)
		print("    material_override: %s" % [_mat_info(mi.material_override)])

		if mi.material_override:
			var tex_path := _get_tex_path(mi.material_override)
			all_tex_paths.append(tex_path)
			print("      -> override tex: '%s'" % tex_path)
		else:
			for si in range(surface_count):
				var sov_mat := mi.get_surface_override_material(si)
				var mesh_mat: Material = mi.mesh.surface_get_material(si) if mi.mesh else null
				var effective := sov_mat if sov_mat else mesh_mat
				var tex_path := _get_tex_path(effective)
				all_tex_paths.append(tex_path)
				print("      surface[%d]: sov=%s mesh_mat=%s -> tex='%s'" % [
					si, _mat_info(sov_mat), _mat_info(mesh_mat), tex_path])

	# Check uniqueness of textures for multi-part models
	var unique_tex: Dictionary = {}
	for tp in all_tex_paths:
		if not tp.is_empty():
			unique_tex[tp] = true

	if unique_tex.size() <= 1 and all_tex_paths.size() > 1:
		print("  *** BUG: %d surfaces but only %d unique texture(s): %s" % [
			all_tex_paths.size(), unique_tex.size(), unique_tex.keys()])
		all_ok = false
	else:
		print("  OK: %d unique textures across %d surfaces" % [
			unique_tex.size(), all_tex_paths.size()])

	return all_ok


func _collect_meshes(node: Node, result: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		result.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect_meshes(child, result)


func _mat_info(mat: Material) -> String:
	if mat == null:
		return "null"
	if mat is StandardMaterial3D:
		var sm := mat as StandardMaterial3D
		var tex := sm.albedo_texture
		return "StdMat(tex=%s, color=%s)" % [
			tex.resource_path.get_file() if tex else "NONE",
			sm.albedo_color.to_html()]
	return mat.get_class()


func _get_tex_path(mat: Material) -> String:
	if mat == null:
		return ""
	if mat is StandardMaterial3D:
		var sm := mat as StandardMaterial3D
		if sm.albedo_texture:
			return sm.albedo_texture.resource_path
	return ""
