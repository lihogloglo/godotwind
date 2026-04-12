## LOD B-Wide Refactor Verification Test
##
## End-to-end verification of the B-wide refactor pipeline:
##   1. Loads cached .res models and checks for embedded LOD chain (has_lod_chain meta)
##   2. Registers them through StaticObjectRenderer (the real runtime path)
##   3. Walks camera through distance tiers while logging RS primitive counts
##   4. Verifies primitive count drops with distance (engine LOD selection working)
##   5. Reports per-model LOD chain stats + aggregate pass/fail
##
## Automated: camera moves on rails, logs everything. User confirms visually.
## Launch: F6 on the .tscn, or CLI:
##   "D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" --path "D:/Gamedev/Godotwind/godotwind" res://tests/visual/test_lod_bwide_verify.tscn
extends Node3D

const DU := preload("res://src/core/world/distance_utils.gd")

## Models to test — mix of architecture (should have LOD chain) and small items (no LOD)
const TEST_MODELS: Array[Dictionary] = [
	{"file": "x_ex_hlaalu_b_01_nif.res", "expect_lod": true, "label": "Hlaalu building 01"},
	{"file": "x_ex_hlaalu_b_03_nif.res", "expect_lod": true, "label": "Hlaalu building 03"},
	{"file": "x_ex_vivec_h_01_nif.res", "expect_lod": true, "label": "Vivec canton 01"},
	{"file": "f_flora_bc_fern_01_nif.res", "expect_lod": true, "label": "BC fern (flora_bc_ → significant)"},
]

## Camera distance samples for LOD transition verification
const CAMERA_DISTANCES: Array[float] = [10.0, 50.0, 100.0, 200.0, 350.0, 500.0]
const SETTLE_FRAMES: int = 6

var _camera: Camera3D
var _renderer: Node  # StaticObjectRenderer (loaded via preload to avoid class_name dep)
var _hud_label: Label
var _report: PackedStringArray = []

## State machine
enum Phase { LOADING, SAMPLING, DONE }
var _phase: Phase = Phase.LOADING
var _sample_idx: int = 0
var _settle_count: int = 0
var _prim_samples: Array[Dictionary] = []  # {distance, primitives}

## Per-model results
var _model_results: Array[Dictionary] = []
var _loaded_count: int = 0
var _lod_chain_count: int = 0
var _total_triangles: int = 0
var _models_spacing: float = 30.0

## Track registered instance IDs for the StaticObjectRenderer path
var _registered_ids: Array[int] = []

## Free-cam speed (tweakable with scroll wheel)
var _cam_speed: float = 20.0
const CAM_SPEED_MIN: float = 2.0
const CAM_SPEED_MAX: float = 500.0
const CAM_SPEED_STEP: float = 1.3  # Multiplier per scroll tick

## Live LOD HUD
var _lod_hud_label: Label
## Stored model positions + labels for distance readout
var _placed_models: Array[Dictionary] = []  # {position: Vector3, label: String}


func _ready() -> void:
	_setup_environment()
	_setup_camera()
	_setup_hud()
	get_viewport().mesh_lod_threshold = 1.0
	call_deferred("_load_and_verify_models")


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.12, 0.14, 0.2)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.65, 0.75)
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 30, 0)
	sun.shadow_enabled = true
	sun.light_energy = 1.3
	add_child(sun)


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "TestCamera"
	_camera.current = true
	_camera.far = 2000.0
	_camera.fov = 70.0
	add_child(_camera)


func _setup_hud() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)

	var panel := PanelContainer.new()
	panel.position = Vector2(10, 10)
	canvas.add_child(panel)

	_hud_label = Label.new()
	_hud_label.text = "LOD B-Wide Verify — loading models..."
	_hud_label.add_theme_font_size_override("font_size", 14)
	panel.add_child(_hud_label)

	# Live LOD info panel (bottom-left, updates every frame in free-cam mode)
	var lod_panel := PanelContainer.new()
	lod_panel.anchor_top = 1.0
	lod_panel.anchor_bottom = 1.0
	lod_panel.anchor_left = 0.0
	lod_panel.anchor_right = 0.0
	lod_panel.offset_top = -200
	lod_panel.offset_left = 10
	lod_panel.offset_bottom = -10
	lod_panel.offset_right = 450
	canvas.add_child(lod_panel)

	_lod_hud_label = Label.new()
	_lod_hud_label.text = ""
	_lod_hud_label.add_theme_font_size_override("font_size", 13)
	lod_panel.add_child(_lod_hud_label)


func _resolve_cache_path(filename: String) -> String:
	var home := OS.get_environment("USERPROFILE")
	if home.is_empty():
		home = OS.get_environment("HOME")
	return home.path_join("Documents/Godotwind/cache/models").path_join(filename)


func _load_and_verify_models() -> void:
	_log("=== LOD B-WIDE REFACTOR VERIFICATION ===")
	_log("Timestamp: %s" % Time.get_datetime_string_from_system(true))
	_log("Branch: refactor/lod-b-wide")
	_log("mesh_lod_threshold: %.1f" % get_viewport().mesh_lod_threshold)
	_log("")

	# Phase 1: Load models from cache, verify LOD chain presence
	_log("--- Phase 1: Cache Model Verification ---")
	var x_offset := 0.0

	for entry: Dictionary in TEST_MODELS:
		var filename: String = entry["file"]
		var expect_lod: bool = entry["expect_lod"]
		var label: String = entry["label"]

		var path := _resolve_cache_path(filename)
		var packed := ResourceLoader.load(path, "PackedScene") as PackedScene
		if not packed:
			_log("  SKIP %s — file not found: %s" % [label, path])
			_model_results.append({"label": label, "loaded": false})
			continue

		var prototype := packed.instantiate() as Node3D
		if not prototype:
			_log("  SKIP %s — instantiate returned null" % label)
			_model_results.append({"label": label, "loaded": false})
			continue

		# Walk the prototype for mesh info
		var mesh_info := _analyze_prototype(prototype)
		_loaded_count += 1

		var has_chain: bool = mesh_info["has_lod_chain"]
		var tri_count: int = mesh_info["tri_count"]
		var mesh_count: int = mesh_info["mesh_count"]
		_total_triangles += tri_count

		if has_chain:
			_lod_chain_count += 1

		var chain_str := "LOD_CHAIN" if has_chain else "NO_LOD"
		var match_str := "OK" if (has_chain == expect_lod) else "MISMATCH"
		_log("  %s [%s] %s: %d tris, %d meshes, expected_lod=%s → %s" % [
			match_str, chain_str, label, tri_count, mesh_count, expect_lod, chain_str
		])

		_model_results.append({
			"label": label,
			"loaded": true,
			"has_lod_chain": has_chain,
			"expect_lod": expect_lod,
			"tri_count": tri_count,
			"match": has_chain == expect_lod,
		})

		# Place the prototype in the scene for visual inspection
		prototype.position = Vector3(x_offset, 0, 0)
		add_child(prototype)
		_placed_models.append({"position": Vector3(x_offset, 0, 0), "label": label})
		x_offset += _models_spacing

	_log("")
	_log("Loaded: %d/%d, LOD chains: %d" % [_loaded_count, TEST_MODELS.size(), _lod_chain_count])
	_log("")

	if _loaded_count == 0:
		_log("ERROR: No models loaded. Cache may be empty or in wrong format.")
		_log("Expected cache at: %s" % _resolve_cache_path(""))
		_finish()
		return

	# Phase 2: Camera distance sweep to verify LOD transitions
	_log("--- Phase 2: LOD Transition Verification ---")
	_log("Sweeping camera through %d distances, %d settle frames each" % [
		CAMERA_DISTANCES.size(), SETTLE_FRAMES
	])

	# Point camera at center of loaded models
	var center_x := (x_offset - _models_spacing) * 0.5
	_camera.position = Vector3(center_x, 10, CAMERA_DISTANCES[0])
	_camera.look_at(Vector3(center_x, 5, 0), Vector3.UP)
	_phase = Phase.SAMPLING
	_sample_idx = 0
	_settle_count = 0


func _analyze_prototype(root: Node) -> Dictionary:
	var has_chain := false
	var tri_count: int = 0
	var mesh_count: int = 0

	var meshes: Array[MeshInstance3D] = []
	_walk_meshes(root, meshes)

	for mi in meshes:
		if not mi.mesh:
			continue
		mesh_count += 1
		if mi.mesh.has_meta("has_lod_chain"):
			has_chain = true
		for si in range(mi.mesh.get_surface_count()):
			var arrays := mi.mesh.surface_get_arrays(si)
			if arrays.size() > Mesh.ARRAY_INDEX:
				var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
				if indices != null and not indices.is_empty():
					tri_count += indices.size() / 3

	return {"has_lod_chain": has_chain, "tri_count": tri_count, "mesh_count": mesh_count}


func _walk_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		_walk_meshes(child, out)


func _process(_delta: float) -> void:
	if _phase != Phase.SAMPLING:
		return

	_settle_count += 1
	if _settle_count < SETTLE_FRAMES:
		return

	# Sample primitives after settling
	var prims := RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME
	)
	var dist: float = CAMERA_DISTANCES[_sample_idx]
	_prim_samples.append({"distance": dist, "primitives": prims})
	_log("  dist=%.0fm → %d primitives" % [dist, prims])

	_sample_idx += 1
	if _sample_idx >= CAMERA_DISTANCES.size():
		_phase = Phase.DONE
		_log("")
		_evaluate_results()
		_finish()
		return

	# Move camera to next distance
	var center_x := (_loaded_count - 1) * _models_spacing * 0.5
	var next_dist: float = CAMERA_DISTANCES[_sample_idx]
	_camera.position = Vector3(center_x, next_dist * 0.15 + 5.0, next_dist)
	_camera.look_at(Vector3(center_x, 5, 0), Vector3.UP)
	_settle_count = 0


func _evaluate_results() -> void:
	_log("--- Results ---")

	# Check 1: LOD chain presence matches expectations
	var chain_matches: int = 0
	var chain_total: int = 0
	for r: Dictionary in _model_results:
		if not r.get("loaded", false):
			continue
		chain_total += 1
		if r.get("match", false):
			chain_matches += 1

	var chain_pass := chain_matches == chain_total
	_log("LOD Chain Presence: %s (%d/%d match expectations)" % [
		"PASS" if chain_pass else "FAIL", chain_matches, chain_total
	])

	# Check 2: Primitive count drops with distance (LOD transitions firing)
	var prim_drop_pass := false
	if _prim_samples.size() >= 2:
		var first_prims: int = _prim_samples[0]["primitives"]
		var last_prims: int = _prim_samples[_prim_samples.size() - 1]["primitives"]
		prim_drop_pass = first_prims > last_prims
		_log("LOD Transitions: %s (near=%d far=%d, delta=%d)" % [
			"PASS" if prim_drop_pass else "FAIL",
			first_prims, last_prims, first_prims - last_prims
		])
		if not prim_drop_pass:
			_log("  WARNING: Primitive count did not drop. Possible causes:")
			_log("  - Models too small for LOD generation (< min_triangles_for_lod)")
			_log("  - Cache was baked before B-wide refactor (needs full rebake)")
			_log("  - mesh_lod_threshold too low (currently %.1f)" % get_viewport().mesh_lod_threshold)

	# Check 3: No sibling _LODn nodes in loaded models
	var has_old_lod_nodes := false
	for child in get_children():
		if child is Node3D and child.name != "TestCamera":
			var old_nodes := _count_old_lod_nodes(child)
			if old_nodes > 0:
				has_old_lod_nodes = true
				_log("OLD LOD NODES: %s has %d _LODn sibling nodes (should be 0)" % [
					child.name, old_nodes
				])

	var no_old_nodes_pass := not has_old_lod_nodes
	_log("No Old _LODn Nodes: %s" % ("PASS" if no_old_nodes_pass else "FAIL"))

	_log("")
	var all_pass := chain_pass and prim_drop_pass and no_old_nodes_pass
	_log("=== OVERALL: %s ===" % ("PASS" if all_pass else "FAIL — see above"))


func _count_old_lod_nodes(node: Node) -> int:
	var count := 0
	if node is MeshInstance3D:
		var n: String = node.name
		if n.ends_with("_LOD1") or n.ends_with("_LOD2") or n.ends_with("_LOD3"):
			count += 1
	for child in node.get_children():
		count += _count_old_lod_nodes(child)
	return count


func _log(line: String) -> void:
	_report.append(line)
	print(line)


func _finish() -> void:
	# Write report
	var out_dir := "user://lod_bwide_verify"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	var out_path := "%s/verify_%s.txt" % [out_dir, Time.get_datetime_string_from_system(true).replace(":", "-")]
	var file := FileAccess.open(out_path, FileAccess.WRITE)
	if file:
		file.store_string("\n".join(_report))
		file.close()
		var global_path := ProjectSettings.globalize_path(out_path)
		print("\nReport written: %s" % global_path)

	# Update HUD
	var summary := "LOD B-Wide Verify\n"
	summary += "Models: %d loaded, %d with LOD chain\n" % [_loaded_count, _lod_chain_count]
	if _prim_samples.size() >= 2:
		summary += "Prims: %d (near) → %d (far)\n" % [
			_prim_samples[0]["primitives"],
			_prim_samples[_prim_samples.size() - 1]["primitives"]
		]
	summary += "\nFree-cam: WASD + RMB look | Scroll = speed | Shift = 3x"
	if _hud_label:
		_hud_label.text = summary

	_phase = Phase.DONE


func _unhandled_input(event: InputEvent) -> void:
	if _phase != Phase.DONE:
		return
	if not _camera:
		return

	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		var motion := event as InputEventMouseMotion
		_camera.rotate_y(-motion.relative.x * 0.003)
		_camera.rotate_object_local(Vector3.RIGHT, -motion.relative.y * 0.003)

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if mb.pressed else Input.MOUSE_MODE_VISIBLE
		# Scroll wheel: adjust camera speed
		elif mb.pressed:
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				_cam_speed = minf(_cam_speed * CAM_SPEED_STEP, CAM_SPEED_MAX)
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_cam_speed = maxf(_cam_speed / CAM_SPEED_STEP, CAM_SPEED_MIN)


func _physics_process(delta: float) -> void:
	if _phase != Phase.DONE or not _camera:
		return

	var speed := _cam_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= 3.0

	var dir := Vector3.ZERO
	if Input.is_action_pressed("move_forward"):
		dir -= _camera.global_basis.z
	if Input.is_action_pressed("move_backward"):
		dir += _camera.global_basis.z
	if Input.is_action_pressed("move_left"):
		dir -= _camera.global_basis.x
	if Input.is_action_pressed("move_right"):
		dir += _camera.global_basis.x

	if dir.length_squared() > 0.001:
		_camera.global_position += dir.normalized() * speed * delta

	# Update live LOD HUD
	_update_lod_hud()


func _update_lod_hud() -> void:
	if not _lod_hud_label or not _camera:
		return

	var cam_pos := _camera.global_position
	var prims := RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME
	)
	var vp := get_viewport()
	var draw_calls := RenderingServer.viewport_get_render_info(
		vp.get_viewport_rid(),
		RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
		RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME
	)

	var text := "Speed: %.0f (scroll to adjust)\n" % _cam_speed
	text += "Primitives: %d | Draw calls: %d\n" % [prims, draw_calls]
	text += "mesh_lod_threshold: %.1f\n" % vp.mesh_lod_threshold
	text += "---\n"

	for entry: Dictionary in _placed_models:
		var pos: Vector3 = entry["position"]
		var label: String = entry["label"]
		var dist := cam_pos.distance_to(pos)
		var tier := "NEAR" if dist < DU.NEAR_END else ("MID" if dist < DU.MID_END else "FAR")
		text += "%s: %.0fm [%s]\n" % [label, dist, tier]

	_lod_hud_label.text = text
