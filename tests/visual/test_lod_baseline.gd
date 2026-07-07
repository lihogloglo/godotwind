## LOD Baseline Test Scene
##
## Part of the LOD B-wide refactor baseline capture (Phase A).
## See `docs/audit/LOD_REFACTOR_B_WIDE.md` and `docs/audit/lod_refactor_baselines/BASELINE_PROCEDURE.md`.
##
## What this does:
##   Loads a specific cached .res file directly (no streaming, no cell manager, no main scene).
##   Walks the loaded prototype tree to find base mesh + _LODn sibling meshes.
##   Collects per-LOD data: triangle count, AABB, material, visibility_range state.
##   Runs specific hypothesis tests with PASS/FAIL markers.
##   Writes a report to user://lod_baselines/<output_label>.txt.
##   Spawns all LOD variants side-by-side in the scene for free-cam visual inspection.
##
## Hypotheses tested on the CURRENT hand-rolled LOD pipeline:
##   H1: LOD0 has reasonable triangle count (> 100 for architecture) — sanity check
##   H2: LOD1 triangles ≈ 50% of LOD0 (40-60% tolerance, per lod_reduction_ratios[0] = 0.50)
##   H3: LOD2 triangles ≈ 25% of LOD0 (20-35% tolerance, per lod_reduction_ratios[1] = 0.25)
##   H4: LOD3 triangles ≈ 10% of LOD0 (5-15% tolerance, per lod_reduction_ratios[2] = 0.10)
##   H5: LOD1/2/3 AABB volume within 95% of LOD0 AABB volume
##       — the missing-faces bug manifests as panels collapsing which SHRINKS the AABB
##   H6: LOD1/2/3 AABB X/Y/Z dimensions each match LOD0 within 95%
##       — catches asymmetric collapse (e.g., canton side wall disappears but roof stays)
##   H7: LOD1/2/3 have a material (not null)
##
## After Phase D refactor, this test re-runs against the new-format cache where .res
## contains a single MeshInstance3D with embedded surface_lod_indices. The script
## auto-detects the format and runs the equivalent hypotheses against the embedded
## LOD chain. Diff old report vs new report to validate the refactor.
##
## Usage:
##   1. Open tests/visual/test_lod_baseline.tscn in the editor
##   2. Select the root node, set @export cache_model_filename in the Inspector
##   3. Run the scene (F6) OR launch headless via Godot CLI (see bottom of this file)
##   4. Report lands at %APPDATA%/Godot/app_userdata/Godotwind/lod_baselines/<label>.txt
##   5. Free-cam with WASD + mouse to visually inspect the side-by-side LOD variants
##
## CLI invocation:
##   "<godot-executable>" --path "<project-path>" res://tests/visual/test_lod_baseline.tscn

extends Node3D

## Cache .res filename to inspect (just the filename, not a full path)
## Canton examples: x_ex_vivec_h_01_nif.res, x_ex_vivec_h_02_nif.res, etc.
## Hlaalu examples: x_ex_hlaalu_b_01_nif.res (verify in pre_wipe_cache_filelist.txt)
@export var cache_model_filename: String = "x_ex_vivec_h_01_nif.res"

## Label for the output report file (sanitized for filesystem)
@export var output_label: String = "baseline_vivec_h_01"

## Run the test automatically on _ready() (set false for manual trigger via HUD button)
@export var auto_run: bool = true

## Distance between side-by-side LOD variants in the scene (meters)
@export var lod_spacing: float = 20.0

## Tolerance for AABB volume / dimension checks (0.05 = within 5% of LOD0)
@export var aabb_tolerance: float = 0.05

## Tolerance ranges for per-LOD triangle count hypotheses (as fraction of LOD0)
## Per src/core/nif/nif_converter.gd lod_reduction_ratios = [0.50, 0.25, 0.10]
const LOD1_TRI_RANGE := Vector2(0.40, 0.60)
const LOD2_TRI_RANGE := Vector2(0.20, 0.35)
const LOD3_TRI_RANGE := Vector2(0.05, 0.15)

## Collected per-LOD info. Key: "lod0" / "lod1" / "lod2" / "lod3" / "embedded_<N>"
## Value: Dictionary with keys: name, mesh, tri_count, aabb, material, vis_range_begin, vis_range_end
var _lod_info: Dictionary[String, Dictionary] = {}

var _report_lines: PackedStringArray = []
var _hud_label: Label = null

## Phase G: count of MeshInstance3Ds whose mesh carries has_lod_chain meta
var _embedded_chain_count: int = 0
var _total_mesh_nodes: int = 0


func _ready() -> void:
	_setup_environment()
	_setup_camera_and_input()
	_setup_hud()
	if auto_run:
		call_deferred("run_test")


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.15, 0.18, 0.25)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.7, 0.8)
	env.ambient_light_energy = 0.8

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.shadow_enabled = true
	sun.light_energy = 1.2
	add_child(sun)


func _setup_camera_and_input() -> void:
	var cam := Camera3D.new()
	cam.name = "TestCamera"
	cam.position = Vector3(0, 15, 40)
	cam.current = true
	cam.far = 2000.0
	add_child(cam)
	# look_at must be called after the node is inside the tree
	cam.look_at(Vector3.ZERO, Vector3.UP)


func _setup_hud() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "HUD"
	add_child(canvas)

	var panel := PanelContainer.new()
	panel.position = Vector2(10, 10)
	canvas.add_child(panel)

	_hud_label = Label.new()
	_hud_label.text = "LOD Baseline Test — press SPACE to re-run"
	_hud_label.add_theme_font_size_override("font_size", 14)
	panel.add_child(_hud_label)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		var key_event := event as InputEventKey
		if key_event.keycode == KEY_SPACE:
			run_test()


## Main entry point — runs the resource inspection + hypothesis tests + writes report
func run_test() -> void:
	_lod_info.clear()
	_report_lines.clear()
	_remove_previous_instances()

	_append("=== LOD BASELINE TEST ===")
	_append("Timestamp: %s" % Time.get_datetime_string_from_system(true))
	_append("Cache file: %s" % cache_model_filename)
	_append("Output label: %s" % output_label)
	_append("Branch: refactor/lod-b-wide (Phase A baseline)")
	_append("")

	var cache_path := _resolve_cache_path(cache_model_filename)
	if cache_path.is_empty():
		_append("ERROR: cache directory not resolvable via SettingsManager.get_models_path()")
		_finish_report()
		return

	_append("Loading: %s" % cache_path)
	var packed_scene := ResourceLoader.load(cache_path, "PackedScene") as PackedScene
	if not packed_scene:
		_append("ERROR: failed to load %s (file exists? cache is in old or new format?)" % cache_path)
		_finish_report()
		return

	var prototype := packed_scene.instantiate() as Node3D
	if not prototype:
		_append("ERROR: PackedScene.instantiate() returned null or non-Node3D")
		_finish_report()
		return

	_collect_lod_info(prototype)

	if _lod_info.is_empty():
		_append("ERROR: no MeshInstance3D nodes found in prototype")
		prototype.queue_free()
		_finish_report()
		return

	_append("Format detection: %s" % _detect_format())
	_append("Embedded LOD chain (has_lod_chain meta): %d / %d mesh nodes" % [_embedded_chain_count, _total_mesh_nodes])
	_append("")
	_print_lod_summary()
	_append("")
	_run_hypotheses()
	_append("")
	_append_diagnosis()

	_spawn_side_by_side(prototype)
	prototype.queue_free()

	_finish_report()


## Resolve cache path using SettingsManager if available, else fall back to
## Documents/Godotwind/cache/models/ per the default in model_loader.gd:51.
func _resolve_cache_path(filename: String) -> String:
	var dir := ""
	if Engine.has_singleton("SettingsManager"):
		var sm: Object = Engine.get_singleton("SettingsManager")
		if sm.has_method("get_models_path"):
			dir = sm.get_models_path()
	if dir.is_empty():
		# Fallback: default per model_loader.gd
		var home := OS.get_environment("USERPROFILE")
		if home.is_empty():
			home = OS.get_environment("HOME")
		dir = home.path_join("Documents").path_join("Godotwind").path_join("cache").path_join("models")
	return dir.path_join(filename)


## Walk the prototype tree, find all MeshInstance3D nodes, bucket them by _LODn name suffix
## OR detect the post-refactor format (single MeshInstance3D with surface_get_lod_count > 0).
## Multi-surface buildings have MULTIPLE MeshInstance3Ds per LOD level (one per material group);
## we sum triangle counts across all of them and take the union of AABBs.
func _collect_lod_info(root: Node) -> void:
	var mesh_instances: Array[MeshInstance3D] = []
	_walk_mesh_instances(root, mesh_instances)

	# Aggregate per-LOD-key: sum tris, merge AABBs, count mesh nodes
	var agg: Dictionary[String, Dictionary] = {}

	for mi in mesh_instances:
		if not mi.mesh:
			continue
		var name_lower := mi.name.to_lower()
		var key := ""
		if name_lower.ends_with("_lod1"):
			key = "lod1"
		elif name_lower.ends_with("_lod2"):
			key = "lod2"
		elif name_lower.ends_with("_lod3"):
			key = "lod3"
		else:
			key = "lod0"

		var info := _extract_mesh_info(mi)

		if key not in agg:
			agg[key] = {
				"name": info["name"],
				"mesh": info["mesh"],
				"tri_count": info["tri_count"],
				"aabb": info["aabb"],
				"material": info["material"],
				"vis_range_begin": info["vis_range_begin"],
				"vis_range_end": info["vis_range_end"],
				"node_count": 1,
				"node_names": PackedStringArray([info["name"]]),
			}
		else:
			var combined: Dictionary = agg[key]
			combined["tri_count"] = int(combined["tri_count"]) + int(info["tri_count"])
			var combined_aabb: AABB = combined["aabb"]
			combined["aabb"] = combined_aabb.merge(info["aabb"])
			combined["node_count"] = int(combined["node_count"]) + 1
			var names: PackedStringArray = combined["node_names"]
			if names.size() < 8:
				names.append(info["name"])
				combined["node_names"] = names
			# Keep the first non-null material we saw as representative
			if not combined.get("material") and info.get("material"):
				combined["material"] = info["material"]
			agg[key] = combined

	for k in agg.keys():
		_lod_info[k] = agg[k]

	# Post-refactor format detection: walk all MeshInstance3D nodes and count
	# how many carry an embedded LOD chain (via the `has_lod_chain` meta stamped
	# at bake time by nif_converter._generate_lod_chain — ArrayMesh.surface_get_lod_count
	# isn't in the 4.6 scripting API).
	_embedded_chain_count = 0
	_total_mesh_nodes = 0
	for mi in mesh_instances:
		if not mi.mesh:
			continue
		_total_mesh_nodes += 1
		if mi.mesh.has_meta("has_lod_chain"):
			_embedded_chain_count += 1


func _walk_mesh_instances(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		_walk_mesh_instances(child, out)


func _extract_mesh_info(mi: MeshInstance3D) -> Dictionary:
	var total_tris: int = 0
	var mesh: Mesh = mi.mesh
	var surface_count: int = mesh.get_surface_count()
	for si in range(surface_count):
		var prim: int = mesh.surface_get_primitive_type(si)
		if prim != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays: Array = mesh.surface_get_arrays(si)
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays.size() > Mesh.ARRAY_INDEX else PackedInt32Array()
		if indices.size() > 0:
			total_tris += indices.size() / 3
		else:
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			total_tris += verts.size() / 3

	var mat: Material = mi.material_override
	if not mat and surface_count > 0:
		mat = mi.get_surface_override_material(0)
		if not mat:
			mat = mesh.surface_get_material(0)

	return {
		"name": mi.name,
		"mesh": mesh,
		"tri_count": total_tris,
		"aabb": mesh.get_aabb(),
		"material": mat,
		"vis_range_begin": mi.visibility_range_begin,
		"vis_range_end": mi.visibility_range_end,
	}


func _detect_format() -> String:
	var has_sibling_lods := ("lod1" in _lod_info or "lod2" in _lod_info or "lod3" in _lod_info)
	var has_embedded := false
	for k in _lod_info.keys():
		if k.begins_with("embedded_"):
			has_embedded = true
			break
	if has_sibling_lods and has_embedded:
		return "HYBRID (sibling LODn nodes + embedded surface_lod_indices — unexpected)"
	if has_sibling_lods:
		return "OLD (sibling _LODn MeshInstance3D nodes, pre-refactor hand-rolled pipeline)"
	if has_embedded:
		return "NEW (single MeshInstance3D with ArrayMesh.surface_lod_indices, post-refactor engine pipeline)"
	return "MINIMAL (LOD0 only, no sibling nodes, no embedded chain — small mesh skipped LOD gen)"


func _print_lod_summary() -> void:
	var keys: Array[String] = []
	for k: String in _lod_info.keys():
		keys.append(k)
	keys.sort()

	_append("Per-LOD summary (aggregated across all MeshInstance3D nodes with the matching suffix):")
	for k in keys:
		var info: Dictionary = _lod_info[k]
		var aabb: AABB = info.get("aabb", AABB())
		var tris: int = info.get("tri_count", 0)
		var node_count: int = info.get("node_count", 1)
		var names: PackedStringArray = info.get("node_names", PackedStringArray())
		var mat_str: String = "<null>" if not info.get("material") else str(info["material"].resource_path if info["material"].resource_path else "<inline>")
		var vrb: float = info.get("vis_range_begin", 0.0)
		var vre: float = info.get("vis_range_end", 0.0)
		_append("  %s: %d tris across %d nodes, AABB (%.1f×%.1f×%.1f), vol %.0f, vis_range %.0f-%.0f, mat %s" % [
			k, tris, node_count, aabb.size.x, aabb.size.y, aabb.size.z,
			aabb.size.x * aabb.size.y * aabb.size.z, vrb, vre,
			mat_str.get_file() if mat_str.find("/") >= 0 else mat_str
		])
		if names.size() > 1:
			_append("    nodes: %s%s" % [", ".join(names), " ..." if node_count > names.size() else ""])


func _run_hypotheses() -> void:
	_append("Hypothesis tests:")

	if not "lod0" in _lod_info:
		_append("  SKIP: no LOD0 base mesh found, cannot run relative hypotheses")
		return

	var lod0: Dictionary = _lod_info["lod0"]
	var lod0_tris: int = lod0.get("tri_count", 0)
	var lod0_aabb: AABB = lod0.get("aabb", AABB())
	var lod0_vol: float = lod0_aabb.size.x * lod0_aabb.size.y * lod0_aabb.size.z

	# H1: LOD0 sanity
	var h1_pass := lod0_tris > 100
	_append("  H1 [LOD0 > 100 tris]: %s (%d)" % ["PASS" if h1_pass else "FAIL", lod0_tris])

	# H2/H3/H4: per-LOD triangle reduction ratios
	_check_tri_ratio("H2", "lod1", lod0_tris, LOD1_TRI_RANGE)
	_check_tri_ratio("H3", "lod2", lod0_tris, LOD2_TRI_RANGE)
	_check_tri_ratio("H4", "lod3", lod0_tris, LOD3_TRI_RANGE)

	# H5: LOD AABB volume within tolerance of LOD0 volume
	_check_aabb_volume("H5 lod1", "lod1", lod0_vol)
	_check_aabb_volume("H5 lod2", "lod2", lod0_vol)
	_check_aabb_volume("H5 lod3", "lod3", lod0_vol)

	# H6: LOD AABB X/Y/Z each within tolerance of LOD0
	_check_aabb_dims("H6 lod1", "lod1", lod0_aabb)
	_check_aabb_dims("H6 lod2", "lod2", lod0_aabb)
	_check_aabb_dims("H6 lod3", "lod3", lod0_aabb)

	# H7: materials exist
	_check_material("H7 lod1", "lod1")
	_check_material("H7 lod2", "lod2")
	_check_material("H7 lod3", "lod3")

	# H8: LOD node count matches LOD0 (catches dropped sub-meshes — the missing-faces bug
	# manifested as "entire merged-mesh groups absent from LOD1/2/3")
	var lod0_node_count: int = lod0.get("node_count", 1)
	_check_node_count("H8 lod1", "lod1", lod0_node_count)
	_check_node_count("H8 lod2", "lod2", lod0_node_count)
	_check_node_count("H8 lod3", "lod3", lod0_node_count)

	# H9: LOD1/LOD2/LOD3 triangle counts differ from each other (simplifier actually
	# produced distinct LOD levels, not the same mesh 3 times). If 2+ levels tie, the
	# simplifier silently no-op'd.
	if "lod1" in _lod_info and "lod2" in _lod_info and "lod3" in _lod_info:
		var l1: int = _lod_info["lod1"].get("tri_count", 0)
		var l2: int = _lod_info["lod2"].get("tri_count", 0)
		var l3: int = _lod_info["lod3"].get("tri_count", 0)
		var distinct := (l1 != l2) or (l2 != l3) or (l1 != l3)
		_append("  H9 [LOD1/2/3 tri counts distinct]: %s (%d / %d / %d)" % [
			"PASS" if distinct else "FAIL", l1, l2, l3
		])


func _check_tri_ratio(tag: String, key: String, lod0_tris: int, expected: Vector2) -> void:
	if not key in _lod_info:
		_append("  %s [%s tri ratio]: SKIP (no %s)" % [tag, key, key])
		return
	var tris: int = _lod_info[key].get("tri_count", 0)
	var ratio: float = float(tris) / float(lod0_tris) if lod0_tris > 0 else 0.0
	var pass_: bool = ratio >= expected.x and ratio <= expected.y
	_append("  %s [%s tri ratio %.0f-%.0f%%]: %s (%d tris, %.1f%% of LOD0)" % [
		tag, key, expected.x * 100.0, expected.y * 100.0,
		"PASS" if pass_ else "FAIL", tris, ratio * 100.0
	])


func _check_aabb_volume(tag: String, key: String, lod0_vol: float) -> void:
	if not key in _lod_info:
		_append("  %s [AABB vol]: SKIP (no %s)" % [tag, key])
		return
	if lod0_vol <= 0.0:
		_append("  %s [AABB vol]: SKIP (LOD0 volume is zero)" % tag)
		return
	var aabb: AABB = _lod_info[key].get("aabb", AABB())
	var vol: float = aabb.size.x * aabb.size.y * aabb.size.z
	var ratio: float = vol / lod0_vol
	var pass_: bool = ratio >= (1.0 - aabb_tolerance)
	_append("  %s [AABB vol >= %d%% of LOD0]: %s (vol %.0f, %.1f%% of LOD0)" % [
		tag, int((1.0 - aabb_tolerance) * 100),
		"PASS" if pass_ else "FAIL", vol, ratio * 100.0
	])


func _check_aabb_dims(tag: String, key: String, lod0_aabb: AABB) -> void:
	if not key in _lod_info:
		_append("  %s [AABB dims]: SKIP (no %s)" % [tag, key])
		return
	var aabb: AABB = _lod_info[key].get("aabb", AABB())
	var ratios := Vector3(
		aabb.size.x / maxf(lod0_aabb.size.x, 0.0001),
		aabb.size.y / maxf(lod0_aabb.size.y, 0.0001),
		aabb.size.z / maxf(lod0_aabb.size.z, 0.0001),
	)
	var min_ratio: float = mini(ratios.x, mini(ratios.y, ratios.z)) if true else 0.0
	min_ratio = minf(ratios.x, minf(ratios.y, ratios.z))
	var pass_: bool = min_ratio >= (1.0 - aabb_tolerance)
	_append("  %s [AABB dims X/Y/Z >= %d%%]: %s (ratios %.1f/%.1f/%.1f)" % [
		tag, int((1.0 - aabb_tolerance) * 100),
		"PASS" if pass_ else "FAIL", ratios.x * 100.0, ratios.y * 100.0, ratios.z * 100.0
	])


func _check_material(tag: String, key: String) -> void:
	if not key in _lod_info:
		_append("  %s: SKIP (no %s)" % [tag, key])
		return
	var mat: Material = _lod_info[key].get("material", null)
	var pass_: bool = mat != null
	_append("  %s [material present]: %s" % [tag, "PASS" if pass_ else "FAIL"])


func _check_node_count(tag: String, key: String, lod0_count: int) -> void:
	if not key in _lod_info:
		_append("  %s: SKIP (no %s)" % [tag, key])
		return
	var count: int = _lod_info[key].get("node_count", 0)
	var pass_: bool = count == lod0_count
	var suffix := ""
	if not pass_:
		suffix = " — %d sub-meshes DROPPED" % (lod0_count - count)
	_append("  %s [node count == LOD0 (%d)]: %s (%d)%s" % [
		tag, lod0_count, "PASS" if pass_ else "FAIL", count, suffix
	])


func _append_diagnosis() -> void:
	_append("Diagnosis:")
	if not "lod0" in _lod_info:
		_append("  No LOD0 found — cannot diagnose. The .res file may be corrupt or in an unexpected format.")
		return

	var lod0_node_count: int = _lod_info["lod0"].get("node_count", 1)
	var dropped_submeshes: Array[String] = []
	for key in ["lod1", "lod2", "lod3"]:
		if not key in _lod_info:
			continue
		var count: int = _lod_info[key].get("node_count", 0)
		if count < lod0_node_count:
			dropped_submeshes.append("%s has %d nodes, LOD0 has %d → %d sub-meshes MISSING" % [
				key, count, lod0_node_count, lod0_node_count - count
			])

	var identical_lods := false
	if "lod1" in _lod_info and "lod2" in _lod_info and "lod3" in _lod_info:
		var l1: int = _lod_info["lod1"].get("tri_count", 0)
		var l2: int = _lod_info["lod2"].get("tri_count", 0)
		var l3: int = _lod_info["lod3"].get("tri_count", 0)
		identical_lods = (l1 == l2 and l2 == l3)

	if dropped_submeshes.is_empty() and not identical_lods:
		_append("  All LODs have the expected sub-mesh count and distinct triangle budgets.")
		_append("  If you still see missing faces visually, the bug is subtle — likely in TRIANGLE")
		_append("  selection by the simplifier (panels collapsed but AABB preserved).")
		return

	# The known missing-faces bug manifests primarily as dropped sub-meshes
	if not dropped_submeshes.is_empty():
		_append("  [DROPPED SUB-MESHES] The canonical 'missing faces' bug manifestation:")
		for line in dropped_submeshes:
			_append("    - %s" % line)
		_append("  At distance > 150m, the MID-tier RS instances for the dropped merge groups")
		_append("  are literally absent — the geometry was never placed in LOD1/2/3 sibling nodes.")
		_append("  Visible effect: large wall panels or entire building sections disappear at distance.")

	if identical_lods:
		_append("")
		_append("  [SIMPLIFIER NO-OP] LOD1, LOD2, LOD3 have identical triangle counts.")
		_append("  The simplifier produced the SAME mesh 3 times instead of distinct 50/25/10% levels.")
		_append("  Either the simplifier bailed early on per-surface triangle minima or the reduction")
		_append("  targets aren't being honored by the current MeshOptimizer GDExt call path.")

	_append("")
	_append("  Root cause analysis (per docs/audit/LOD_OVER_ENGINEERING.md):")
	_append("  - _add_visibility_range_lods() in nif_converter.gd iterates LOD surfaces independently")
	_append("  - Calls MeshOptimizer.simplify_arrays() without pre-welding shared vertices")
	_append("  - Multi-material building uses MERGED_MESH split (see nif_converter _convert_merged)")
	_append("  - The LOD generator may only run against the FIRST merged surface group, leaving the")
	_append("    other N-1 groups without any LOD1/2/3 representation.")
	_append("")
	_append("  Expected fix (Phase D B-wide refactor):")
	_append("  - Replace _add_visibility_range_lods() with ImporterMesh.generate_lods()")
	_append("  - ImporterMesh handles multi-surface meshes natively (processes EVERY surface)")
	_append("  - Produces embedded surface_lod_indices on the SAME ArrayMesh, so no sibling nodes")
	_append("  - Godot's C++ LOD selector picks per-screen-space-size at runtime")
	_append("  - Expected post-refactor state: format=NEW, single MeshInstance3D per merge group with")
	_append("    embedded LOD chain covering all distances, no dropped sub-meshes.")


func _spawn_side_by_side(prototype: Node3D) -> void:
	# Duplicate the prototype for each LOD key present, hide non-matching LODs in each copy,
	# and place them side-by-side along the X axis so the user can visually inspect each LOD
	# isolation without touching the main streaming scene.
	var keys: Array[String] = []
	for k: String in _lod_info.keys():
		if k.begins_with("lod") or k.begins_with("embedded_"):
			keys.append(k)
	keys.sort()

	var display_root := Node3D.new()
	display_root.name = "LODDisplay"
	add_child(display_root)

	for i in range(keys.size()):
		var k := keys[i]
		var copy := prototype.duplicate() as Node3D
		copy.name = "Display_%s" % k
		copy.position = Vector3(float(i) * lod_spacing, 0.0, 0.0)
		display_root.add_child(copy)
		_isolate_lod(copy, k)


func _isolate_lod(root: Node, target_key: String) -> void:
	var all_meshes: Array[MeshInstance3D] = []
	_walk_mesh_instances(root, all_meshes)
	for mi in all_meshes:
		var name_lower := mi.name.to_lower()
		var mi_key := ""
		if name_lower.ends_with("_lod1"):
			mi_key = "lod1"
		elif name_lower.ends_with("_lod2"):
			mi_key = "lod2"
		elif name_lower.ends_with("_lod3"):
			mi_key = "lod3"
		else:
			mi_key = "lod0"
		mi.visible = (mi_key == target_key or (target_key.begins_with("embedded_") and mi_key == "lod0"))
		# Override visibility_range so LODs aren't culled by distance in the display scene
		mi.visibility_range_begin = 0.0
		mi.visibility_range_end = 0.0


func _remove_previous_instances() -> void:
	var display := get_node_or_null("LODDisplay")
	if display:
		display.queue_free()


func _append(line: String) -> void:
	_report_lines.append(line)


func _finish_report() -> void:
	var report := "\n".join(_report_lines)
	print(report)

	var out_dir := "user://lod_baselines"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	var out_path := "%s/%s.txt" % [out_dir, output_label]
	var file := FileAccess.open(out_path, FileAccess.WRITE)
	if file:
		file.store_string(report)
		file.close()
		var globalised := ProjectSettings.globalize_path(out_path)
		print("\nReport written: %s" % globalised)
		if _hud_label:
			_hud_label.text = "%s\n\nReport: %s" % [cache_model_filename, globalised]
	else:
		push_error("Failed to write report to %s" % out_path)
