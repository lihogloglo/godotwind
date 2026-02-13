## Prebake Test NPC — Run-once tool that saves a fully assembled NPC as a PackedScene
##
## Creates Fargoth via the full CharacterFactoryV2 pipeline, strips runtime-only nodes,
## embeds all resources, and saves to res://tests/data/test_npc_fargoth.scn.
## Subsequent test runs load this file in ~10-20ms instead of ~500-1300ms.
##
## Run: Open tests/data/prebake_test_npc.tscn and press F5/F6
@tool
extends Node3D

@warning_ignore("untyped_declaration", "unsafe_method_access", "unsafe_property_access", "unsafe_cast", "inferred_declaration")

const CharacterFactoryV2Script := preload("res://src/core/animation/character_factory_v2.gd")

var _ran := false


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	await get_tree().process_frame
	await get_tree().process_frame
	await _run_prebake()


func _run_prebake() -> void:
	if _ran:
		return
	_ran = true

	print("=" .repeat(60))
	print("PREBAKE TEST NPC")
	print("=" .repeat(60))
	var total_start := Time.get_ticks_msec()

	# 1. Load archives
	print("Loading BSA/ESM archives...")
	await _ensure_data_loaded()
	print("  Archives loaded: %d ms" % (Time.get_ticks_msec() - total_start))

	# 2. Preload character assets (skeletons, bone remaps, animations)
	CharacterFactoryV2Script.clear_all_caches()
	CharacterFactoryV2Script.preload_character_assets()
	print("  Assets preloaded: %d ms" % (Time.get_ticks_msec() - total_start))

	# 3. Create Fargoth via full pipeline
	var factory := CharacterFactoryV2Script.new()
	factory.enable_ik = false
	factory.enable_wander = false
	factory.debug_characters = true

	var npc_record = ESMManager.get_npc("fargoth")
	if not npc_record:
		push_error("PrebakeTestNPC: fargoth not found in ESM")
		get_tree().quit(1)
		return

	var character = factory.create_npc(npc_record, 0)
	if not character:
		push_error("PrebakeTestNPC: create_npc returned null")
		get_tree().quit(1)
		return

	print("  NPC created: %d ms" % (Time.get_ticks_msec() - total_start))

	# Store character info metadata (read by setup_character() at load time)
	var race = ESMManager.get_race(npc_record.race_id)
	character.set_meta("is_female", npc_record.is_female())
	character.set_meta("is_beast", race.is_beast() if race else false)
	character.set_meta("race_id", npc_record.race_id)
	print("  Metadata: female=%s beast=%s race=%s" % [
		npc_record.is_female(), race.is_beast() if race else false, npc_record.race_id])

	# Must add to tree briefly for node path resolution
	add_child(character)
	await get_tree().process_frame

	# 4. Strip runtime-only nodes (AnimationSystem and sub-controllers)
	#    These are recreated at load time by CharacterFactoryV2.setup_character()
	var stripped := _strip_runtime_nodes(character)
	print("  Stripped %d runtime nodes" % stripped)

	# 5. Prepare all resources for embedding (materials, textures, animations)
	_prepare_resources_for_embedding(character)

	# 6. Remove from tree for clean packing
	remove_child(character)

	# 7. Set owner hierarchy (required for PackedScene.pack)
	_set_owner_recursive(character, character)

	# 8. Pack and save
	var packed := PackedScene.new()
	var pack_result := packed.pack(character)
	if pack_result != OK:
		push_error("PrebakeTestNPC: pack() failed: %s" % error_string(pack_result))
		character.free()
		get_tree().quit(1)
		return

	var save_path := "res://tests/data/test_npc_fargoth.scn"
	var save_result := ResourceSaver.save(packed, save_path)
	if save_result != OK:
		push_error("PrebakeTestNPC: save() failed: %s" % error_string(save_result))
		character.free()
		get_tree().quit(1)
		return

	var f := FileAccess.open(save_path, FileAccess.READ)
	var file_size: int = f.get_length() if f else 0
	f = null
	print("")
	print("SUCCESS: Prebaked NPC saved to %s" % save_path)
	print("  File size: %.2f MB (%d bytes)" % [file_size / 1048576.0, file_size])
	print("  Total time: %d ms" % (Time.get_ticks_msec() - total_start))
	print("=" .repeat(60))

	character.free()
	get_tree().quit()


func _strip_runtime_nodes(root: Node) -> int:
	var count := 0
	# AnimationSystem is a direct child of character_root (which is child of CharacterBody3D root)
	for child in root.get_children():
		# Recurse into Node3D children (character_root)
		if child is Node3D:
			count += _strip_runtime_nodes(child)

	# Find and remove AnimationSystem node by name
	var anim_sys := root.find_child("AnimationSystem", false, false)
	if anim_sys:
		anim_sys.get_parent().remove_child(anim_sys)
		anim_sys.queue_free()
		count += 1

	# Also remove AnimationTree from skeleton (it lives on Skeleton3D, not AnimationSystem)
	var anim_tree := root.find_child("AnimationTree", true, false)
	if anim_tree:
		anim_tree.get_parent().remove_child(anim_tree)
		anim_tree.queue_free()
		count += 1
	return count


func _prepare_resources_for_embedding(node: Node) -> void:
	# Meshes and materials
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.material_override:
			_make_material_local(mi.material_override)
		if mi.mesh:
			mi.mesh.resource_local_to_scene = true
			mi.mesh.resource_path = ""
			for i in mi.mesh.get_surface_count():
				var mat := mi.mesh.surface_get_material(i)
				if mat:
					_make_material_local(mat)
		for i in mi.get_surface_override_material_count():
			var mat := mi.get_surface_override_material(i)
			if mat:
				_make_material_local(mat)

	# AnimationPlayer libraries
	if node is AnimationPlayer:
		var ap := node as AnimationPlayer
		for lib_name in ap.get_animation_library_list():
			var lib: AnimationLibrary = ap.get_animation_library(lib_name)
			if lib:
				lib.resource_local_to_scene = true
				lib.resource_path = ""
				for anim_name in lib.get_animation_list():
					var anim: Animation = lib.get_animation(anim_name)
					if anim:
						anim.resource_local_to_scene = true
						anim.resource_path = ""

	# AnimationTree root
	if node is AnimationTree:
		var at := node as AnimationTree
		if at.tree_root:
			at.tree_root.resource_local_to_scene = true
			at.tree_root.resource_path = ""

	# Collision shapes
	if node is CollisionShape3D:
		var cs := node as CollisionShape3D
		if cs.shape:
			cs.shape.resource_local_to_scene = true
			cs.shape.resource_path = ""

	for child in node.get_children():
		_prepare_resources_for_embedding(child)


func _make_material_local(mat: Material) -> void:
	if mat == null:
		return
	mat.resource_local_to_scene = true
	mat.resource_path = ""
	if mat is StandardMaterial3D:
		var std_mat := mat as StandardMaterial3D
		for tex in [std_mat.albedo_texture, std_mat.normal_texture,
				std_mat.roughness_texture, std_mat.metallic_texture,
				std_mat.emission_texture, std_mat.ao_texture,
				std_mat.detail_albedo, std_mat.detail_normal]:
			if tex:
				tex.resource_local_to_scene = true
				tex.resource_path = ""


func _set_owner_recursive(node: Node, owner_node: Node) -> void:
	for child in node.get_children():
		child.owner = owner_node
		_set_owner_recursive(child, owner_node)


func _ensure_data_loaded() -> void:
	var data_path: String = SettingsManager.get_data_path()
	if data_path.is_empty():
		data_path = SettingsManager.auto_detect_installation()
	if data_path.is_empty():
		push_error("PrebakeTestNPC: No Morrowind data path found")
		get_tree().quit(1)
		return

	if not BSAManager.has_file("meshes\\xbase_anim.nif"):
		BSAManager.load_archives_from_directory(data_path)
		await get_tree().process_frame

	if ESMManager.cells.is_empty():
		var esm_file: String = SettingsManager.get_esm_file()
		ESMManager.load_file(data_path.path_join(esm_file))
		await get_tree().process_frame
