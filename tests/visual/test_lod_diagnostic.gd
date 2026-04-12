## LOD Diagnostic — Compare raw NIF conversion vs cached .res
##
## Loads a model TWO ways:
##   A) Raw NIF from BSA with generate_lods=false (baseline — what surfaces SHOULD exist)
##   B) Raw NIF from BSA with generate_lods=true (what we bake into cache)
##   C) From the actual cache .res file
##
## Compares: surface count, tri count per surface, materials, AABB.
## Spawns all three side-by-side for visual comparison.
## Writes a full diagnostic report to the console + HUD.
##
## Usage:
##   Open in editor, set target_nif_path, run with F6.
@warning_ignore("untyped_declaration")
extends Node3D

const NIFConverterScript := preload("res://src/core/nif/nif_converter.gd")
const StreamingPolicyScript := preload("res://src/core/world/streaming_policy.gd")

## NIF path inside BSA (e.g. "meshes/x/ex_vivec_h_01.nif")
@export var target_nif_path: String = "meshes/x/ex_vivec_h_01.nif"

## Spacing between side-by-side models
@export var model_spacing: float = 40.0

var _hud_label: RichTextLabel
var _report: PackedStringArray = []


func _ready() -> void:
	_setup_environment()
	_setup_hud()
	call_deferred("_run_diagnostic")


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.12, 0.14, 0.2)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.7, 0.8)
	env.ambient_light_energy = 0.8
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 30, 0)
	sun.shadow_enabled = true
	sun.light_energy = 1.2
	add_child(sun)

	var cam := Camera3D.new()
	cam.name = "DiagCam"
	cam.position = Vector3(0, 20, 60)
	cam.current = true
	cam.far = 2000.0
	add_child(cam)
	cam.look_at(Vector3.ZERO, Vector3.UP)


func _setup_hud() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_hud_label = RichTextLabel.new()
	_hud_label.bbcode_enabled = true
	_hud_label.fit_content = true
	_hud_label.scroll_active = true
	_hud_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hud_label.add_theme_font_size_override("normal_font_size", 13)
	canvas.add_child(_hud_label)


func _run_diagnostic() -> void:
	_log("=== LOD DIAGNOSTIC ===")
	_log("Target NIF: %s" % target_nif_path)
	_log("Timestamp: %s" % Time.get_datetime_string_from_system(true))
	_log("")

	# Ensure BSA/ESM loaded
	if not await _ensure_data():
		_log("[color=red]ERROR: Failed to load BSA/ESM data[/color]")
		_update_hud()
		return

	# A) Raw NIF conversion — NO LOD generation
	_log("--- [A] RAW NIF (generate_lods=false) ---")
	var raw_node := _convert_nif(false)
	if raw_node:
		raw_node.position = Vector3(-model_spacing, 0, 0)
		add_child(raw_node)
		_analyze_node(raw_node, "RAW")
		# Add label
		_add_label(Vector3(-model_spacing, -3, 0), "A: RAW (no LOD)")
	else:
		_log("[color=red]Failed to convert NIF (raw)[/color]")

	_log("")

	# B) Raw NIF conversion — WITH LOD generation
	_log("--- [B] NIF + LOD CHAIN (generate_lods=true) ---")
	var lod_node := _convert_nif(true)
	if lod_node:
		lod_node.position = Vector3(0, 0, 0)
		add_child(lod_node)
		_analyze_node(lod_node, "LOD")
		_add_label(Vector3(0, -3, 0), "B: WITH LOD chain")
	else:
		_log("[color=red]Failed to convert NIF (LOD)[/color]")

	_log("")

	# C) From cache .res file
	_log("--- [C] CACHED .res FILE ---")
	var cache_node := _load_from_cache()
	if cache_node:
		cache_node.position = Vector3(model_spacing, 0, 0)
		add_child(cache_node)
		_analyze_node(cache_node, "CACHE")
		_add_label(Vector3(model_spacing, -3, 0), "C: CACHED .res")
	else:
		_log("[color=red]Failed to load from cache[/color]")

	_log("")

	# Compare A vs B
	if raw_node and lod_node:
		_log("--- COMPARISON: RAW vs LOD ---")
		_compare_nodes(raw_node, "RAW", lod_node, "LOD")

	if raw_node and cache_node:
		_log("")
		_log("--- COMPARISON: RAW vs CACHE ---")
		_compare_nodes(raw_node, "RAW", cache_node, "CACHE")

	_update_hud()
	_log("")
	_log("=== DIAGNOSTIC COMPLETE ===")
	# Also print to Godot console
	for line in _report:
		print(line.replace("[color=red]", "").replace("[/color]", "").replace("[color=green]", "").replace("[color=yellow]", ""))


func _convert_nif(with_lods: bool) -> Node3D:
	var nif_data := PackedByteArray()
	var path_normalized := target_nif_path.replace("\\", "/")
	if BSAManager.has_file(path_normalized):
		nif_data = BSAManager.extract_file(path_normalized)
	elif BSAManager.has_file(target_nif_path):
		nif_data = BSAManager.extract_file(target_nif_path)
	if nif_data.is_empty():
		_log("  NIF not found in BSA: %s" % target_nif_path)
		return null

	var converter := NIFConverterScript.new()
	converter.load_textures = true
	converter.load_animations = false
	converter.load_collision = false
	converter.generate_lods = with_lods
	converter.generate_occluders = false
	var model := converter.convert_buffer(nif_data, target_nif_path)
	return model


func _load_from_cache() -> Node3D:
	var cache_dir: String = SettingsManager.get_models_path()
	# Build cache key same way as model_prebaker
	var cache_key := target_nif_path.to_lower().replace("/", "\\")
	var safe_name := cache_key.replace("\\", "_").replace("/", "_").replace(":", "_").replace(".", "_")
	var scene_path := cache_dir.path_join(safe_name + ".res")
	_log("  Cache path: %s" % scene_path)
	if not FileAccess.file_exists(scene_path):
		_log("  [color=red]Cache file not found[/color]")
		return null
	var packed := ResourceLoader.load(scene_path, "PackedScene") as PackedScene
	if not packed:
		_log("  [color=red]Failed to load PackedScene[/color]")
		return null
	return packed.instantiate() as Node3D


func _analyze_node(root: Node3D, label: String) -> void:
	var meshes := _collect_mesh_instances(root)
	_log("  MeshInstance3D count: %d" % meshes.size())
	var total_surfaces: int = 0
	var total_tris: int = 0
	for i in range(meshes.size()):
		var mi: MeshInstance3D = meshes[i]
		var mesh: Mesh = mi.mesh
		if mesh == null:
			_log("    [%d] '%s' — NO MESH" % [i, mi.name])
			continue
		var surf_count := mesh.get_surface_count()
		total_surfaces += surf_count
		var has_lod := mesh.has_meta("has_lod_chain") if mesh is ArrayMesh else false
		var mesh_tris: int = 0
		for si in range(surf_count):
			var arrays := mesh.surface_get_arrays(si)
			var tri_count := 0
			if not arrays.is_empty():
				var indices = arrays[Mesh.ARRAY_INDEX]
				if indices != null and indices is PackedInt32Array and not indices.is_empty():
					tri_count = indices.size() / 3
				else:
					var verts = arrays[Mesh.ARRAY_VERTEX]
					if verts != null:
						tri_count = verts.size() / 3
			mesh_tris += tri_count
			var mat := mesh.surface_get_material(si)
			var mat_name := mat.resource_name if mat else "NULL"
			_log("    [%d] '%s' surf %d: %d tris, mat=%s" % [i, mi.name, si, tri_count, mat_name])
		total_tris += mesh_tris
		var vis_begin := mi.visibility_range_begin
		var vis_end := mi.visibility_range_end
		_log("    [%d] '%s' TOTAL: %d surfaces, %d tris, LOD_chain=%s, vis_range=[%.0f, %.0f], visible=%s" % [
			i, mi.name, surf_count, mesh_tris, str(has_lod), vis_begin, vis_end, str(mi.visible)])
	_log("  %s SUMMARY: %d meshes, %d total surfaces, %d total triangles" % [label, meshes.size(), total_surfaces, total_tris])


func _compare_nodes(a_root: Node3D, a_label: String, b_root: Node3D, b_label: String) -> void:
	var a_meshes := _collect_mesh_instances(a_root)
	var b_meshes := _collect_mesh_instances(b_root)
	_log("  Mesh count: %s=%d, %s=%d %s" % [
		a_label, a_meshes.size(), b_label, b_meshes.size(),
		"[color=green]MATCH[/color]" if a_meshes.size() == b_meshes.size() else "[color=red]MISMATCH[/color]"])

	var a_tris := _total_triangles(a_meshes)
	var b_tris := _total_triangles(b_meshes)
	var pct := (float(b_tris) / float(a_tris) * 100.0) if a_tris > 0 else 0.0
	var tri_verdict := ""
	if b_tris == a_tris:
		tri_verdict = "[color=green]IDENTICAL[/color]"
	elif b_tris > a_tris * 0.9:
		tri_verdict = "[color=green]OK (%.1f%%)[/color]" % pct
	elif b_tris > a_tris * 0.5:
		tri_verdict = "[color=yellow]REDUCED (%.1f%%)[/color]" % pct
	else:
		tri_verdict = "[color=red]SEVERE DROP (%.1f%%)[/color]" % pct
	_log("  Total tris: %s=%d, %s=%d — %s" % [a_label, a_tris, b_label, b_tris, tri_verdict])

	var a_surfs := _total_surfaces(a_meshes)
	var b_surfs := _total_surfaces(b_meshes)
	_log("  Total surfaces: %s=%d, %s=%d %s" % [
		a_label, a_surfs, b_label, b_surfs,
		"[color=green]MATCH[/color]" if a_surfs == b_surfs else "[color=red]MISMATCH[/color]"])

	# Per-mesh comparison
	var count := mini(a_meshes.size(), b_meshes.size())
	for i in range(count):
		var a_mi: MeshInstance3D = a_meshes[i]
		var b_mi: MeshInstance3D = b_meshes[i]
		var a_t := _mesh_tri_count(a_mi)
		var b_t := _mesh_tri_count(b_mi)
		var a_s := a_mi.mesh.get_surface_count() if a_mi.mesh else 0
		var b_s := b_mi.mesh.get_surface_count() if b_mi.mesh else 0
		if a_s != b_s or abs(a_t - b_t) > a_t * 0.1:
			_log("    [%d] '%s' vs '%s': surfs %d→%d, tris %d→%d %s" % [
				i, a_mi.name, b_mi.name, a_s, b_s, a_t, b_t,
				"[color=red]CHANGED[/color]"])


func _collect_mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if node is MeshInstance3D and node.visible:
		result.append(node as MeshInstance3D)
	for child in node.get_children():
		result.append_array(_collect_mesh_instances(child))
	return result


func _total_triangles(meshes: Array[MeshInstance3D]) -> int:
	var total: int = 0
	for mi in meshes:
		total += _mesh_tri_count(mi)
	return total


func _mesh_tri_count(mi: MeshInstance3D) -> int:
	if mi.mesh == null:
		return 0
	var total: int = 0
	for si in range(mi.mesh.get_surface_count()):
		var arrays := mi.mesh.surface_get_arrays(si)
		if arrays.is_empty():
			continue
		var indices = arrays[Mesh.ARRAY_INDEX]
		if indices != null and indices is PackedInt32Array and not indices.is_empty():
			total += indices.size() / 3
		else:
			var verts = arrays[Mesh.ARRAY_VERTEX]
			if verts != null:
				total += verts.size() / 3
	return total


func _total_surfaces(meshes: Array[MeshInstance3D]) -> int:
	var total: int = 0
	for mi in meshes:
		if mi.mesh:
			total += mi.mesh.get_surface_count()
	return total


func _add_label(pos: Vector3, text: String) -> void:
	var label := Label3D.new()
	label.text = text
	label.position = pos
	label.font_size = 64
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(label)


func _log(text: String) -> void:
	_report.append(text)


func _update_hud() -> void:
	_hud_label.clear()
	_hud_label.append_text("\n".join(PackedStringArray(_report)))


func _ensure_data() -> bool:
	if BSAManager.get_archive_count() == 0:
		var data_path: String = SettingsManager.get_data_path()
		if data_path.is_empty():
			return false
		var loaded := BSAManager.load_archives_from_directory(data_path)
		if loaded == 0:
			return false
		_log("  Loaded %d BSA archives" % loaded)
	if ESMManager.cells.is_empty():
		var data_path: String = SettingsManager.get_data_path()
		var esm_file: String = SettingsManager.get_esm_file()
		var esm_path := data_path.path_join(esm_file)
		var err := ESMManager.load_file(esm_path)
		if err != OK:
			return false
	return true
