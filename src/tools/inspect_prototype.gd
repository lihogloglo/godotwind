extends SceneTree

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("Usage: --headless -s inspect_prototype.gd -- <path_to_res>")
		quit()
		return

	var res_path: String = args[0]
	print("=== PROTOTYPE INSPECTION: %s ===" % res_path)

	var packed := ResourceLoader.load(res_path) as PackedScene
	if not packed:
		print("ERROR: Could not load as PackedScene: %s" % res_path)
		quit()
		return

	var root := packed.instantiate()
	if not root:
		print("ERROR: Could not instantiate")
		quit()
		return

	_dump_tree(root, 0)
	root.queue_free()
	quit()


func _dump_tree(node: Node, depth: int) -> void:
	var indent := "  ".repeat(depth)
	var info := "%s%s [%s]" % [indent, node.name, node.get_class()]

	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		info += " visible=%s" % mi.visible
		if mi.mesh:
			info += " surfaces=%d" % mi.mesh.get_surface_count()
			info += " aabb=%s" % str(mi.mesh.get_aabb().size)
		else:
			info += " NO MESH"

		# Material info
		if mi.material_override:
			info += " mat_override=%s" % _mat_info(mi.material_override)
		elif mi.mesh and mi.mesh.get_surface_count() > 0:
			for si in range(mi.mesh.get_surface_count()):
				var smat: Material = mi.get_surface_override_material(si)
				if not smat:
					smat = mi.mesh.surface_get_material(si)
				if smat:
					info += " surf%d=%s" % [si, _mat_info(smat)]
				else:
					info += " surf%d=NULL" % si

		# LOD info
		var lname: String = mi.name.to_lower()
		if lname.ends_with("_lod1") or lname.ends_with("_lod2") or lname.ends_with("_lod3"):
			info += " [LOD]"

	elif node is OccluderInstance3D:
		info += " occluder"

	elif node is StaticBody3D:
		info += " collision"

	print(info)

	for child in node.get_children():
		_dump_tree(child, depth + 1)


func _mat_info(mat: Material) -> String:
	if mat is StandardMaterial3D:
		var std := mat as StandardMaterial3D
		var tex_str := "tex=%s" % std.albedo_texture.get_class() if std.albedo_texture else "tex=NO"
		return "Std3D(%s, color=%s, vc=%s)" % [tex_str, std.albedo_color, std.vertex_color_use_as_albedo]
	if mat is ShaderMaterial:
		return "Shader"
	return mat.get_class()
