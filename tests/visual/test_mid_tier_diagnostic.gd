extends Node3D

## MID-Tier Pipeline Diagnostic
##
## Diagnoses why some areas have no MID-tier models by running every model
## through the full pipeline: disk cache → prototype load → LOD inspection →
## mid-worthy filter → batch pool registration → batch pool add.
##
## Visual grid (default): 20 representative models with color-coded floor planes
## Full ESM audit (F5): Scans ALL model paths, outputs CSV to user://mid_tier_audit.csv
##
## Color coding:
##   Green:  Full pipeline (MID-worthy + dedicated LODs + batch registered)
##   Red:    Critical rebake needed (MID-worthy but NO LODs — LOD0 at 500m)
##   Orange: Has LODs but rejected by MID filter (wasted prebake work)
##   Gray:   Correctly rejected (small items, type-locked objects)

const MidTierBatchPoolScript := preload("res://src/core/world/mid_tier_batch_pool.gd")
const SP := preload("res://src/core/world/streaming_policy.gd")

## Test model definitions: [model_path, type_name, category_label]
## Paths match ESM record.model format (no "meshes\" prefix)
var TEST_MODELS: Array[Array] = [
	# Architecture — should pass BOTH filters
	["x\\ex_hlaalu_b_01.nif", "static", "Architecture (Hlaalu)"],
	["x\\ex_redoran_building_01.nif", "static", "Architecture (Redoran)"],
	# Trees — should pass BOTH
	["f\\flora_tree_01.nif", "static", "Tree (flora_tree)"],
	["f\\flora_tree_wg_01.nif", "static", "Tree (West Gash)"],
	# Flora — MID-worthy but MISSING LODs in prebake
	["x\\flora_ashtree_01.nif", "static", "Ash Tree (no LOD expected)"],
	["x\\flora_t_mushroom_01.nif", "static", "Telvanni Mushroom (no LOD expected)"],
	["f\\flora_bc_fern_01.nif", "static", "BC Fern (flora_bc_)"],
	# Structural — MID-worthy but MISSING LODs
	["x\\ex_de_docks_128.nif", "static", "Dock (no LOD expected)"],
	["f\\terrain_natural_bridge_01.nif", "static", "Natural Bridge"],
	# Containers — MID-worthy, path mismatch possible
	["o\\contain_barrel10.nif", "container", "Barrel (contain_)"],
	["o\\contain_crate_01.nif", "container", "Crate (contain_)"],
	# Terrain — partial LOD coverage
	["f\\terrain_rock_ac_01.nif", "static", "Rock (terrain_rock)"],
	["f\\terrain_boulder_01.nif", "static", "Boulder (terrain_ non-rock)"],
	# Furniture — has LODs but REJECTED by MID filter
	["f\\furn_de_table_01.nif", "static", "Furniture (furn_)"],
	["f\\furn_com_table_01.nif", "static", "Furniture Common (furn_)"],
	# Dwemer/Daedric — has LODs but REJECTED
	["f\\furn_dae_rubble_01a.nif", "static", "Daedric (dae_)"],
	# Doors — MID-worthy, no LODs
	["d\\door_cavern_doors00.nif", "door", "Door (cavern)"],
	# Small items — correctly rejected
	["m\\misc_com_bottle_05.nif", "misc", "Misc Bottle (rejected)"],
	["w\\w_dagger_chitin.nif", "weapon", "Weapon Dagger (rejected)"],
	["m\\misc_skull00.nif", "misc", "Misc Skull (rejected)"],
]

## Status enum for color coding
enum Status { PASS, REBAKE_NEEDED, WASTED_LOD, REJECTED, FAILED }

## Per-model diagnosis result
class DiagResult:
	var model_path: String
	var type_name: String
	var category: String
	var in_disk_cache: bool = false
	var prototype_loaded: bool = false
	var lod_count: int = 0  ## How many of LOD1/LOD2/LOD3 were found
	var has_lod1: bool = false
	var has_lod2: bool = false
	var has_lod3: bool = false
	var is_mid_worthy: bool = false
	var batch_registered: bool = false
	var batch_add_ok: bool = false
	var status: int = Status.FAILED
	var vertex_count: int = 0

var _model_loader: ModelLoader
var _batch_pool: Node3D  ## MidTierBatchPool
var _results: Array[DiagResult] = []
var _hud_label: RichTextLabel
var _camera: Camera3D
var _audit_running: bool = false

func _ready() -> void:
	_setup_environment()
	_setup_model_loader()
	_setup_batch_pool()
	_run_visual_diagnosis()
	_build_hud()
	Log.info("diagnostic", "MID-Tier Diagnostic ready. Press F5 for full ESM audit.")


func _exit_tree() -> void:
	# Clean up batch pool to avoid RID leaks
	if _batch_pool:
		_batch_pool.clear()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F5 and not _audit_running:
			_run_full_audit()
		elif event.keycode == KEY_ESCAPE:
			get_tree().quit()


#region Environment Setup

func _setup_environment() -> void:
	# Camera
	_camera = Camera3D.new()
	_camera.position = Vector3(0, 15, 30)
	_camera.rotation_degrees = Vector3(-25, 0, 0)
	_camera.far = 6000.0
	add_child(_camera)
	_camera.make_current()

	# Light
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 30, 0)
	light.shadow_enabled = true
	light.light_energy = 1.2
	add_child(light)

	# World environment
	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.38, 0.45, 0.55)
	sky_mat.sky_horizon_color = Color(0.64, 0.68, 0.74)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 0.5
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world_env.environment = env
	add_child(world_env)

func _setup_model_loader() -> void:
	_model_loader = ModelLoader.new()
	_model_loader.enable_disk_cache = true
	_model_loader.runtime_mode = true  # Only load from prebaked cache

func _setup_batch_pool() -> void:
	_batch_pool = MidTierBatchPoolScript.new()
	_batch_pool.name = "MidTierBatchPool"
	add_child(_batch_pool)

#endregion


#region Visual Diagnosis (20 models)

func _run_visual_diagnosis() -> void:
	Log.info("diagnostic", "=== MID-TIER PIPELINE DIAGNOSTIC ===")
	Log.info("diagnostic", "Testing %d representative models..." % TEST_MODELS.size())

	_results.clear()
	var next_object_id := 0

	for entry: Array in TEST_MODELS:
		var model_path: String = entry[0]
		var type_name: String = entry[1]
		var category: String = entry[2]

		var result := DiagResult.new()
		result.model_path = model_path
		result.type_name = type_name
		result.category = category

		# Stage 1: Disk cache check
		result.in_disk_cache = _model_loader.has_disk_cached(model_path)

		# Stage 2: Prototype load
		var prototype: Node3D = _model_loader.get_model(model_path)
		result.prototype_loaded = prototype != null

		# Stage 3: LOD inspection
		if prototype:
			_inspect_lods(prototype, result)

		# Stage 4: Mid-worthy check (replicate cell_manager logic)
		result.is_mid_worthy = _is_mid_worthy(type_name, model_path)

		# Stage 5: Batch pool registration
		if prototype:
			var norm_type := model_path.to_lower().replace("/", "\\")
			if not _batch_pool.has_type(norm_type):
				_batch_pool.register_from_prototype(norm_type, prototype)
			result.batch_registered = _batch_pool.has_type(norm_type)

			# Stage 6: Batch pool add
			if result.batch_registered:
				var cell_grid := Vector2i(0, next_object_id)  # Fake cell grid
				var obj_id: int = _batch_pool.add_object(
					norm_type, Transform3D.IDENTITY, cell_grid,
					model_path, "", &"diag", next_object_id
				)
				result.batch_add_ok = obj_id >= 0
				next_object_id += 1

		# Determine status
		result.status = _classify_status(result)

		_results.append(result)
		_log_result(result)

	_build_visual_grid()
	_log_summary()


func _inspect_lods(prototype: Node3D, result: DiagResult) -> void:
	## Recursively check for _LOD1/_LOD2/_LOD3 children
	var stack: Array[Node] = [prototype]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		var name_upper := node.name.to_upper()
		if "_LOD1" in name_upper:
			result.has_lod1 = true
		elif "_LOD2" in name_upper:
			result.has_lod2 = true
		elif "_LOD3" in name_upper:
			result.has_lod3 = true

		# Count vertices for LOD0 (main mesh)
		if node is MeshInstance3D and "_LOD" not in name_upper:
			var mi := node as MeshInstance3D
			if mi.mesh:
				for surf_idx: int in mi.mesh.get_surface_count():
					var arrays: Array = mi.mesh.surface_get_arrays(surf_idx)
					if arrays.size() > 0 and arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array:
						result.vertex_count += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()

		for child: Node in node.get_children():
			stack.append(child)

	result.lod_count = int(result.has_lod1) + int(result.has_lod2) + int(result.has_lod3)


## Delegates to StreamingPolicy (single source of truth)
func _is_mid_worthy(type_name: String, model_path: String) -> bool:
	return SP.is_mid_worthy(type_name, model_path)


## Delegates to StreamingPolicy (single source of truth)
func _should_generate_lods(model_path: String) -> bool:
	return SP.should_generate_lods(model_path)


func _classify_status(result: DiagResult) -> int:
	if not result.prototype_loaded:
		return Status.FAILED
	if not result.is_mid_worthy:
		if result.lod_count > 0:
			return Status.WASTED_LOD  # Orange: has LODs but rejected
		return Status.REJECTED  # Gray
	if result.lod_count > 0 and result.batch_registered:
		return Status.PASS  # Green: full pipeline
	return Status.REBAKE_NEEDED  # Red: MID-worthy but no LODs


func _log_result(result: DiagResult) -> void:
	var status_names: Array[String] = ["PASS", "REBAKE_NEEDED", "WASTED_LOD", "REJECTED", "FAILED"]
	var status_str: String = status_names[result.status]
	Log.info("diagnostic", "[%s] %s — cache:%s proto:%s lods:%d mid:%s batch:%s add:%s verts:%d  (%s)" % [
		status_str,
		result.model_path,
		"Y" if result.in_disk_cache else "N",
		"Y" if result.prototype_loaded else "N",
		result.lod_count,
		"Y" if result.is_mid_worthy else "N",
		"Y" if result.batch_registered else "N",
		"Y" if result.batch_add_ok else "N",
		result.vertex_count,
		result.category,
	])


func _log_summary() -> void:
	var pass_count := 0
	var rebake_count := 0
	var wasted_count := 0
	var rejected_count := 0
	var failed_count := 0
	for r: DiagResult in _results:
		match r.status:
			Status.PASS: pass_count += 1
			Status.REBAKE_NEEDED: rebake_count += 1
			Status.WASTED_LOD: wasted_count += 1
			Status.REJECTED: rejected_count += 1
			Status.FAILED: failed_count += 1

	Log.info("diagnostic", "=== SUMMARY ===")
	Log.info("diagnostic", "  PASS (green):          %d" % pass_count)
	Log.info("diagnostic", "  REBAKE NEEDED (red):   %d" % rebake_count)
	Log.info("diagnostic", "  WASTED LOD (orange):   %d" % wasted_count)
	Log.info("diagnostic", "  REJECTED (gray):       %d" % rejected_count)
	Log.info("diagnostic", "  FAILED:                %d" % failed_count)
	Log.info("diagnostic", "===============")

#endregion


#region Visual Grid

func _build_visual_grid() -> void:
	var grid_container := Node3D.new()
	grid_container.name = "DiagnosticGrid"
	add_child(grid_container)

	var cols := 5
	var spacing := 15.0

	for i: int in _results.size():
		var result := _results[i]
		var col := i % cols
		var row := i / cols
		var pos := Vector3(col * spacing - (cols - 1) * spacing * 0.5, 0, -row * spacing)

		# Floor plane (color-coded)
		var floor_mesh := PlaneMesh.new()
		floor_mesh.size = Vector2(spacing * 0.9, spacing * 0.9)
		var floor_inst := MeshInstance3D.new()
		floor_inst.mesh = floor_mesh
		var floor_mat := StandardMaterial3D.new()
		floor_mat.albedo_color = _status_color(result.status)
		floor_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		floor_mat.albedo_color.a = 0.4
		floor_inst.material_override = floor_mat
		floor_inst.position = pos
		grid_container.add_child(floor_inst)

		# Model instance (if loaded)
		if result.prototype_loaded:
			var prototype: Node3D = _model_loader.get_model(result.model_path)
			if prototype:
				var instance: Node3D = prototype.duplicate()
				instance.position = pos + Vector3.UP * 0.1
				# Scale large models to fit grid
				var aabb := _get_node_aabb(instance)
				var max_dim := maxf(maxf(aabb.size.x, aabb.size.y), aabb.size.z)
				if max_dim > spacing * 0.6:
					var scale_factor := spacing * 0.6 / max_dim
					instance.scale = Vector3.ONE * scale_factor
				grid_container.add_child(instance)

		# Label
		var label := Label3D.new()
		label.position = pos + Vector3(0, 8, 0)
		label.pixel_size = 0.01
		label.font_size = 24
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.modulate = Color.WHITE
		label.outline_modulate = Color.BLACK
		label.outline_size = 4
		var grid_status_names: Array[String] = ["PASS", "REBAKE", "WASTED", "REJECT", "FAIL"]
		var status_str: String = grid_status_names[result.status]
		label.text = "%s\n[%s] LODs:%d Verts:%d\nMID:%s Batch:%s" % [
			result.category,
			status_str,
			result.lod_count,
			result.vertex_count,
			"Y" if result.is_mid_worthy else "N",
			"Y" if result.batch_registered else "N",
		]
		grid_container.add_child(label)

	# Build distance strip for passing models
	_build_distance_strip(grid_container)


func _build_distance_strip(parent: Node3D) -> void:
	var strip_origin := Vector3(80, 0, 0)  # Offset to the right of grid
	var distances: Array[float] = [150.0, 250.0, 375.0, 500.0]
	var band_names: Array[String] = ["NEAR/MID boundary", "LOD1/LOD2", "LOD2/LOD3", "MID/FAR boundary"]

	# Place distance markers
	for d_idx: int in distances.size():
		var dist: float = distances[d_idx]
		var marker := Label3D.new()
		marker.position = strip_origin + Vector3(0, 5, -dist)
		marker.text = "%dm — %s" % [int(dist), band_names[d_idx]]
		marker.pixel_size = 0.02
		marker.font_size = 32
		marker.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		marker.modulate = Color.YELLOW
		parent.add_child(marker)

	# Place passing models at each distance
	var pass_results: Array[DiagResult] = []
	for r: DiagResult in _results:
		if r.status == Status.PASS or r.status == Status.REBAKE_NEEDED:
			pass_results.append(r)
	if pass_results.is_empty():
		return

	var strip_spacing := 10.0
	for r_idx: int in mini(pass_results.size(), 6):  # Max 6 models in strip
		var result := pass_results[r_idx]
		var prototype: Node3D = _model_loader.get_model(result.model_path)
		if not prototype:
			continue

		for d_idx: int in distances.size():
			var dist: float = distances[d_idx]
			var pos := strip_origin + Vector3(r_idx * strip_spacing, 0, -dist)
			var instance: Node3D = prototype.duplicate()
			instance.position = pos
			parent.add_child(instance)


func _status_color(status: int) -> Color:
	match status:
		Status.PASS: return Color.GREEN
		Status.REBAKE_NEEDED: return Color.RED
		Status.WASTED_LOD: return Color.ORANGE
		Status.REJECTED: return Color(0.5, 0.5, 0.5)  # Gray
		_: return Color(0.3, 0.0, 0.0)  # Dark red for failures


func _get_node_aabb(node: Node3D) -> AABB:
	var aabb := AABB()
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if mi.mesh:
				aabb = aabb.merge(mi.mesh.get_aabb())
		for child: Node in n.get_children():
			stack.append(child)
	return aabb

#endregion


#region HUD

func _build_hud() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "DiagHUD"
	add_child(canvas)

	_hud_label = RichTextLabel.new()
	_hud_label.bbcode_enabled = true
	_hud_label.scroll_active = true
	_hud_label.size = Vector2(500, 600)
	_hud_label.position = Vector2(10, 10)
	canvas.add_child(_hud_label)

	# Background panel
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.75)
	style.set_content_margin_all(8)
	style.set_corner_radius_all(4)
	_hud_label.add_theme_stylebox_override("normal", style)
	_hud_label.add_theme_font_size_override("normal_font_size", 14)

	_update_hud()


func _update_hud() -> void:
	if not _hud_label:
		return

	var pass_count := 0
	var rebake_count := 0
	var wasted_count := 0
	var rejected_count := 0
	var failed_count := 0

	for r: DiagResult in _results:
		match r.status:
			Status.PASS: pass_count += 1
			Status.REBAKE_NEEDED: rebake_count += 1
			Status.WASTED_LOD: wasted_count += 1
			Status.REJECTED: rejected_count += 1
			Status.FAILED: failed_count += 1

	var text := "[b]MID-Tier Pipeline Diagnostic[/b]\n"
	text += "[color=gray]F5 = Full ESM Audit | ESC = Quit[/color]\n\n"
	text += "[color=green]PASS (green):[/color]        %d\n" % pass_count
	text += "[color=red]REBAKE NEEDED (red):[/color]  %d\n" % rebake_count
	text += "[color=orange]WASTED LOD (orange):[/color] %d\n" % wasted_count
	text += "[color=gray]REJECTED (gray):[/color]      %d\n" % rejected_count
	if failed_count > 0:
		text += "[color=darkred]FAILED:[/color]               %d\n" % failed_count
	text += "\n[b]Per-Model Detail:[/b]\n"

	for r: DiagResult in _results:
		var color_names: Array[String] = ["green", "red", "orange", "gray", "darkred"]
		var color: String = color_names[r.status]
		var hud_status_names: Array[String] = ["PASS", "REBAKE", "WASTED", "REJECT", "FAIL"]
		var status_str: String = hud_status_names[r.status]
		text += "[color=%s][%s][/color] %s — LODs:%d verts:%d\n" % [
			color, status_str, r.category, r.lod_count, r.vertex_count
		]

	_hud_label.text = text

#endregion


#region Full ESM Audit (F5)

func _run_full_audit() -> void:
	_audit_running = true
	Log.info("diagnostic", "=== FULL ESM AUDIT ===")

	# Load ESM data if not already loaded
	if ESMManager.exterior_cells.is_empty():
		Log.info("diagnostic", "Loading ESM data (this takes ~8 seconds)...")
		var data_path: String = SettingsManager.get_data_path()
		if data_path.is_empty():
			data_path = SettingsManager.auto_detect_installation()
		if data_path.is_empty():
			Log.error("diagnostic", "Cannot find Morrowind data path")
			_audit_running = false
			return
		# Load BSA archives first (needed for model path resolution)
		BSAManager.load_archives_from_directory(data_path)
		# Load primary ESM
		var esm_file: String = SettingsManager.get_esm_file()
		var esm_path := data_path.path_join(esm_file)
		var error := ESMManager.load_file(esm_path)
		if error != OK:
			Log.error("diagnostic", "Failed to load ESM: %s" % error_string(error))
			_audit_running = false
			return
		Log.info("diagnostic", "ESM loaded: %d exterior cells, %d total cells" % [
			ESMManager.exterior_cells.size(), ESMManager.cells.size()])

	Log.info("diagnostic", "Scanning %d exterior cells..." % ESMManager.exterior_cells.size())

	var model_stats: Dictionary = {}  # model_path -> {type_name, mid_worthy, should_lod, has_lod, count, verts}
	var cell_deferred_verts: Dictionary = {}  # "x,y" -> total deferred vertex count
	var total_refs := 0
	var cells_scanned := 0

	# Iterate all exterior cells
	for grid_key: String in ESMManager.exterior_cells:
		var cell: CellRecord = ESMManager.exterior_cells[grid_key]
		if not cell:
			continue

		cells_scanned += 1
		var cell_deferred := 0

		for ref: CellReference in cell.references:
			if ref.is_deleted:
				continue
			total_refs += 1

			var record_type: Array = [""]
			var base_record: Variant = ESMManager.get_any_record(str(ref.ref_id), record_type)
			if not base_record:
				continue

			var type_name: String = record_type[0] if record_type.size() > 0 else ""
			if type_name in ["leveled_item", "npc", "creature", "leveled_creature", "light"]:
				continue

			var model_path: String = ""
			if "model" in base_record and base_record.model:
				model_path = base_record.model
			if model_path.is_empty():
				continue

			var lower := model_path.to_lower()
			if lower not in model_stats:
				# First time seeing this model — check everything
				var mid_worthy := _is_mid_worthy(type_name, model_path)
				var should_lod := _should_generate_lods(model_path)
				var has_disk := _model_loader.has_disk_cached(model_path)

				# Check if prebaked model has LOD nodes
				var has_lod := false
				var verts := 0
				if has_disk:
					var proto: Node3D = _model_loader.get_model(model_path)
					if proto:
						var lod_result := DiagResult.new()
						_inspect_lods(proto, lod_result)
						has_lod = lod_result.lod_count > 0
						verts = lod_result.vertex_count

				model_stats[lower] = {
					"model_path": model_path,
					"type_name": type_name,
					"mid_worthy": mid_worthy,
					"should_lod": should_lod,
					"has_lod": has_lod,
					"has_disk": has_disk,
					"count": 0,
					"verts": verts,
				}

			model_stats[lower]["count"] += 1

			# Track deferred vertex count per cell
			var stats: Dictionary = model_stats[lower]
			if not stats["mid_worthy"] and stats["verts"] > 0:
				cell_deferred += stats["verts"]

		if cell_deferred > 0:
			cell_deferred_verts[grid_key] = cell_deferred

		# Progress every 100 cells
		if cells_scanned % 100 == 0:
			Log.info("diagnostic", "  Scanned %d cells, %d unique models..." % [cells_scanned, model_stats.size()])

	# Compute summary
	var mid_with_lods := 0
	var mid_without_lods := 0
	var lods_not_mid := 0
	var no_disk_cache := 0
	var total_wasted_instances := 0
	var total_rebake_instances := 0

	for key: String in model_stats:
		var s: Dictionary = model_stats[key]
		if s["mid_worthy"] and s["has_lod"]:
			mid_with_lods += 1
		elif s["mid_worthy"] and not s["has_lod"]:
			mid_without_lods += 1
			total_rebake_instances += s["count"]
		elif not s["mid_worthy"] and s["has_lod"]:
			lods_not_mid += 1
			total_wasted_instances += s["count"]
		if not s["has_disk"]:
			no_disk_cache += 1

	# Stutter wall analysis
	var stutter_risk_cells := 0
	var max_deferred_verts := 0
	var max_deferred_cell := ""
	for cell_key: String in cell_deferred_verts:
		var verts: int = cell_deferred_verts[cell_key]
		if verts > 100000:
			stutter_risk_cells += 1
		if verts > max_deferred_verts:
			max_deferred_verts = verts
			max_deferred_cell = cell_key

	Log.info("diagnostic", "=== FULL AUDIT RESULTS ===")
	Log.info("diagnostic", "  Cells scanned: %d" % cells_scanned)
	Log.info("diagnostic", "  Total refs: %d" % total_refs)
	Log.info("diagnostic", "  Unique models: %d" % model_stats.size())
	Log.info("diagnostic", "  ---")
	Log.info("diagnostic", "  MID-worthy WITH LODs:    %d models" % mid_with_lods)
	Log.info("diagnostic", "  MID-worthy WITHOUT LODs: %d models (%d instances — REBAKE NEEDED)" % [mid_without_lods, total_rebake_instances])
	Log.info("diagnostic", "  LODs but NOT MID-worthy: %d models (%d instances — WASTED)" % [lods_not_mid, total_wasted_instances])
	Log.info("diagnostic", "  Not in disk cache:       %d models" % no_disk_cache)
	Log.info("diagnostic", "  ---")
	Log.info("diagnostic", "  Stutter risk cells (>100k deferred verts): %d" % stutter_risk_cells)
	Log.info("diagnostic", "  Worst cell: %s (%d deferred verts)" % [max_deferred_cell, max_deferred_verts])

	# Write CSV
	_write_audit_csv(model_stats)

	# Update HUD with audit results
	_update_hud_with_audit(model_stats, cells_scanned, stutter_risk_cells, max_deferred_cell, max_deferred_verts)

	_audit_running = false
	Log.info("diagnostic", "=== AUDIT COMPLETE ===")


func _write_audit_csv(model_stats: Dictionary) -> void:
	var csv_path := "user://mid_tier_audit.csv"
	var file := FileAccess.open(csv_path, FileAccess.WRITE)
	if not file:
		Log.warn("diagnostic", "Failed to write CSV to %s" % csv_path)
		return

	file.store_line("model_path,type_name,is_mid_worthy,should_generate_lods,has_lod_nodes,in_disk_cache,instance_count,vertex_count")

	# Sort by instance count descending
	var sorted_keys: Array = model_stats.keys()
	sorted_keys.sort_custom(func(a: String, b: String) -> bool:
		return model_stats[a]["count"] > model_stats[b]["count"]
	)

	for key: String in sorted_keys:
		var s: Dictionary = model_stats[key]
		file.store_line("%s,%s,%s,%s,%s,%s,%d,%d" % [
			s["model_path"],
			s["type_name"],
			"YES" if s["mid_worthy"] else "NO",
			"YES" if s["should_lod"] else "NO",
			"YES" if s["has_lod"] else "NO",
			"YES" if s["has_disk"] else "NO",
			s["count"],
			s["verts"],
		])

	file.close()
	Log.info("diagnostic", "CSV written to %s (%d entries)" % [csv_path, model_stats.size()])


func _update_hud_with_audit(model_stats: Dictionary, cells_scanned: int,
		stutter_risk_cells: int, max_deferred_cell: String, max_deferred_verts: int) -> void:
	if not _hud_label:
		return

	var mid_with := 0
	var mid_without := 0
	var lods_not_mid := 0
	for key: String in model_stats:
		var s: Dictionary = model_stats[key]
		if s["mid_worthy"] and s["has_lod"]:
			mid_with += 1
		elif s["mid_worthy"] and not s["has_lod"]:
			mid_without += 1
		elif not s["mid_worthy"] and s["has_lod"]:
			lods_not_mid += 1

	var text := _hud_label.text
	text += "\n\n[b]Full ESM Audit Results:[/b]\n"
	text += "Cells: %d | Unique models: %d\n" % [cells_scanned, model_stats.size()]
	text += "[color=green]MID + LODs: %d[/color]\n" % mid_with
	text += "[color=red]MID, NO LODs: %d (REBAKE)[/color]\n" % mid_without
	text += "[color=orange]LODs, NOT MID: %d (WASTED)[/color]\n" % lods_not_mid
	text += "Stutter risk cells: %d\n" % stutter_risk_cells
	if max_deferred_verts > 0:
		text += "Worst: %s (%dk verts)\n" % [max_deferred_cell, max_deferred_verts / 1000]
	text += "[color=gray]CSV: user://mid_tier_audit.csv[/color]\n"

	_hud_label.text = text

#endregion
