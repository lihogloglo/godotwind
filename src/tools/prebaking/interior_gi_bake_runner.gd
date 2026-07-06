extends Node

## Interior GI offline baker (2026-07-06 lighting pass).
##
## Bakes one VoxelGIData per Morrowind interior cell so interiors get real
## bounced indirect light. VoxelGI (not LightmapGI) because LightmapGI.bake()
## is not exposed to scripting even in editor builds (godot-proposals#8656) —
## batch-baking ~1000 interiors with lightmaps is impossible in stock Godot.
## VoxelGI's bake IS scriptable, the data saves as a plain Resource, and the
## baked voxel field is re-lit every frame from live lights, so torch flicker
## bounces (a lightmap would freeze it).
##
## Only geometry is voxelized — lights are injected at runtime by the engine,
## so the bake needs no light setup and never goes stale when light values
## change. Runtime loading: interior_pocket_manager._add_interior_gi().
## Path/metadata contract: src/core/world/interior_gi_cache.gd.
##
## Launch (all interiors, resumable — existing bakes are skipped):
##   godot --path . res://src/tools/prebaking/interior_gi_bake_runner.tscn
## Flags:
##   --interior-gi-force          rebake everything (wipe skip check)
##   --interior-gi-limit=N        stop after N baked cells (smoke test)
##   --interior-gi-match=SUBSTR   only cells whose name contains SUBSTR
## Auto-quits: exit 0 = success, 1 = failure.

@warning_ignore("untyped_declaration", "unsafe_method_access")

const LoadingScreenScript := preload("res://src/core/ui/loading_screen.gd")
const WorldObjectSourceScript := preload("res://src/core/world/morrowind/morrowind_world_object_source.gd")
const MeshVisibilityUtilsScript := preload("res://src/core/world/mesh_visibility_utils.gd")
const WorldObjectRecordScript := preload("res://src/core/world/world_object_record.gd")
const InteriorGICacheScript := preload("res://src/core/world/interior_gi_cache.gd")

## Cells whose AABB max extent exceeds this are skipped — voxels get too
## coarse to help and the bake takes minutes (no MW vanilla interior shell
## is this large; quasi-exterior canton shells stream the exterior path).
const MAX_EXTENT_M := 250.0
## SUBDIV_128 above this extent, SUBDIV_64 below (voxel size stays <= ~0.6m).
const SUBDIV_128_THRESHOLD_M := 40.0
## Margin added around the cell AABB so wall backfaces are fully inside.
const AABB_MARGIN_M := 2.0
## Clear the model scene cache every N cells to bound memory.
const MODEL_CACHE_FLUSH_INTERVAL := 128

var _model_scene_cache: Dictionary = {}  # model_path -> PackedScene (or null)


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	print("Interior GI bake: loading game data...")
	var loading := LoadingScreenScript.new()
	add_child(loading)
	var ok: bool = await loading.load_game_data()
	loading.queue_free()
	if not ok:
		push_error("Interior GI bake failed: game data did not load")
		get_tree().quit(1)
		return

	var esm: Node = get_node_or_null("/root/ESMManager")
	var settings: Node = get_node_or_null("/root/SettingsManager")
	if esm == null or settings == null:
		push_error("Interior GI bake failed: autoloads unavailable")
		get_tree().quit(1)
		return

	var out_dir: String = InteriorGICacheScript.gi_dir(settings)
	var mkdir_err := DirAccess.make_dir_recursive_absolute(out_dir)
	if mkdir_err != OK and mkdir_err != ERR_ALREADY_EXISTS:
		push_error("Interior GI bake failed: cannot create %s" % out_dir)
		get_tree().quit(1)
		return

	var force := false
	var limit := 1 << 30
	var name_match := ""
	for arg in Array(OS.get_cmdline_user_args()) + Array(OS.get_cmdline_args()):
		var s := str(arg)
		if s == "--interior-gi-force":
			force = true
		elif s.begins_with("--interior-gi-limit="):
			limit = maxi(1, int(s.get_slice("=", 1)))
		elif s.begins_with("--interior-gi-match="):
			name_match = s.get_slice("=", 1).to_lower()

	# Enumerate interior cells (exteriors bake nothing — SDFGI owns outdoors).
	var interior_names: Array[String] = []
	for key: Variant in (esm.get("cells") as Dictionary).keys():
		var rec: Variant = (esm.get("cells") as Dictionary)[key]
		if rec != null and rec.has_method("is_exterior") and not rec.is_exterior():
			var cell_name := str(key)
			if name_match.is_empty() or cell_name.to_lower().contains(name_match):
				interior_names.append(cell_name)
	interior_names.sort()
	print("Interior GI bake: %d interior cells (force=%s, limit=%d)" % [interior_names.size(), force, limit])

	var source := WorldObjectSourceScript.new()
	var start_ms := Time.get_ticks_msec()
	var baked := 0
	var skipped := 0
	var empty := 0
	var failed := 0
	var total_bytes := 0

	for ci in interior_names.size():
		if baked >= limit:
			break
		var cell_name: String = interior_names[ci]
		var out_path := InteriorGICacheScript.file_for_cell(out_dir, cell_name)
		if not force and FileAccess.file_exists(out_path):
			skipped += 1
			continue

		var result := await _bake_cell(source, cell_name, out_path)
		match result:
			"baked":
				baked += 1
				total_bytes += FileAccess.get_file_as_bytes(out_path).size()
			"empty":
				empty += 1
			_:
				failed += 1

		if (ci + 1) % MODEL_CACHE_FLUSH_INTERVAL == 0:
			_model_scene_cache.clear()
			source.clear_cache()
		if (baked + empty + failed) % 8 == 0:
			print("Interior GI bake: %d/%d visited (%d baked, %d skipped, %d empty, %d failed, %.1f MB)" % [
				ci + 1, interior_names.size(), baked, skipped, empty, failed, total_bytes / 1048576.0])

	var elapsed := (Time.get_ticks_msec() - start_ms) / 1000.0
	print("Interior GI bake complete: %d baked, %d skipped (existing), %d empty, %d failed | %.1f MB, %.1f s | out=%s" % [
		baked, skipped, empty, failed, total_bytes / 1048576.0, elapsed, out_dir])
	get_tree().quit(0 if failed == 0 else 1)


## Bake one interior cell. Returns "baked", "empty", or "failed".
func _bake_cell(source: RefCounted, cell_name: String, out_path: String) -> String:
	var manifest: Variant = source.get_interior_cell_manifest(cell_name)
	if manifest == null:
		return "empty"

	var bake_root := Node3D.new()
	bake_root.name = "BakeRoot"
	add_child(bake_root)

	var combined := AABB()
	var has_aabb := false
	var mesh_count := 0

	for record in (manifest.get("objects") as Array):
		if record.model_path.is_empty():
			continue
		# Actors move — never bake them into the voxel field.
		var cat: int = record.category
		if cat == WorldObjectRecordScript.Category.NPC or cat == WorldObjectRecordScript.Category.CREATURE:
			continue
		var packed: PackedScene = _get_model_scene(record.model_path)
		if packed == null:
			continue
		var inst := packed.instantiate() as Node3D
		if inst == null:
			continue
		MeshVisibilityUtilsScript.hide_lod_and_materialless(inst)
		inst.transform = record.transform
		bake_root.add_child(inst)
		mesh_count += 1

	if mesh_count == 0:
		bake_root.queue_free()
		return "empty"

	# Accumulate the cell-local AABB over visible meshes and mark them static
	# for the voxelizer.
	var stack: Array[Node] = [bake_root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child: Node in node.get_children():
			stack.append(child)
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.is_visible_in_tree():
			continue
		mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
		var mesh_aabb: AABB = mi.global_transform * mi.mesh.get_aabb()
		if has_aabb:
			combined = combined.merge(mesh_aabb)
		else:
			combined = mesh_aabb
			has_aabb = true

	if not has_aabb or combined.size.length_squared() < 0.01:
		bake_root.queue_free()
		return "empty"

	combined = combined.grow(AABB_MARGIN_M)
	var extent := maxf(combined.size.x, maxf(combined.size.y, combined.size.z))
	if extent > MAX_EXTENT_M:
		print("Interior GI bake: skipping '%s' — extent %.0fm exceeds %.0fm cap" % [cell_name, extent, MAX_EXTENT_M])
		bake_root.queue_free()
		return "empty"

	var voxel := VoxelGI.new()
	voxel.name = "BakeVoxelGI"
	voxel.subdiv = VoxelGI.SUBDIV_128 if extent > SUBDIV_128_THRESHOLD_M else VoxelGI.SUBDIV_64
	voxel.size = combined.size
	voxel.position = combined.get_center()
	add_child(voxel)

	# Let the instanced subtree finish entering the tree before voxelizing.
	await get_tree().process_frame

	voxel.bake(bake_root)
	var data: VoxelGIData = voxel.data
	var result := "failed"
	if data == null:
		push_error("Interior GI bake: bake produced no data for '%s'" % cell_name)
	else:
		data.interior = true
		data.set_meta(InteriorGICacheScript.META_SIZE, voxel.size)
		data.set_meta(InteriorGICacheScript.META_CENTER, voxel.position)
		var save_err := ResourceSaver.save(data, out_path, ResourceSaver.FLAG_COMPRESS)
		if save_err != OK:
			push_error("Interior GI bake: save failed for '%s': %s" % [cell_name, error_string(save_err)])
		else:
			result = "baked"

	voxel.queue_free()
	bake_root.queue_free()
	return result


func _get_model_scene(model_path: String) -> PackedScene:
	var key := model_path.to_lower()
	if key in _model_scene_cache:
		return _model_scene_cache[key]
	var settings: Node = get_node_or_null("/root/SettingsManager")
	var models_dir: String = settings.call("get_cache_base_path").path_join("models")
	# Same sanitization as the model prebaker / chunk baker outputs.
	var safe_name := key.replace("/", "\\").replace("\\", "_").replace(":", "_").replace(".", "_")
	var scene_path := models_dir.path_join(safe_name + ".res")
	var packed: PackedScene = null
	if FileAccess.file_exists(scene_path):
		packed = ResourceLoader.load(scene_path, "PackedScene") as PackedScene
	_model_scene_cache[key] = packed
	return packed
