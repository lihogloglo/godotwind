extends Node3D

## Terrain Alignment Diagnostic — Comprehensive Test
##
## Tests the FULL terrain pipeline:
##   1. Raw MW heights → heightmap image → Terrain3D query
##   2. Import position correctness (regions at expected world positions)
##   3. Object Y positions vs terrain height at those positions
##   4. Fresh terrain vs cached terrain comparison
##   5. Scale workaround verification
##
## Runs automatically, logs PASS/FAIL for each check.
## Camera is positioned at Seyda Neen for visual confirmation.

const CS := preload("res://src/core/coordinate_system.gd")
const CellManagerScript := preload("res://src/core/world/cell_manager.gd")
const LoadingScreenScript := preload("res://src/core/ui/loading_screen.gd")
const TerrainManagerScript := preload("res://src/core/world/terrain_manager.gd")

var _camera: Camera3D
var _terrain: Terrain3D
var _clipmap_proxy: Node3D  # Proxy node for clipmap targeting (internal-space position)
var _pass_count: int = 0
var _fail_count: int = 0
var _warn_count: int = 0
var _results: PackedStringArray = []


func _ready() -> void:
	_setup_camera()

	# Load game data (ESM, BSA)
	var loading := LoadingScreenScript.new()
	add_child(loading)
	var success: bool = await loading.load_game_data()
	loading.queue_free()
	if not success:
		_log("[FAIL] Game data load failed")
		_finish()
		return

	_log("=== TERRAIN ALIGNMENT DIAGNOSTIC ===")
	_log("Date: %s" % Time.get_datetime_string_from_system())
	_log("")

	# Phase 1: Configuration check
	_log("--- PHASE 1: Configuration ---")
	_test_configuration()

	# Phase 2: Height pipeline (raw MW → heightmap image → Terrain3D)
	_log("")
	_log("--- PHASE 2: Height Pipeline (Fresh Terrain) ---")
	await _test_height_pipeline()

	# Phase 3: Cached terrain comparison
	_log("")
	_log("--- PHASE 3: Cached Terrain ---")
	await _test_cached_terrain()

	# Phase 4: Object alignment (Seyda Neen)
	_log("")
	_log("--- PHASE 4: Object Alignment (Seyda Neen) ---")
	await _test_object_alignment()

	# Summary
	_log("")
	_log("========================================")
	_log("RESULTS: %d PASS, %d FAIL, %d WARN" % [_pass_count, _fail_count, _warn_count])
	_log("========================================")

	# Save results to file
	_save_results()

	# Position camera at Seyda Neen for visual inspection
	var center := CS.cell_grid_to_center_godot(Vector2i(-2, -9))
	_camera.global_position = center + Vector3(0, 100, 100)
	_camera.look_at(center)
	_log("Camera at Seyda Neen. ESC to quit (auto-quit in 180s).")

	await get_tree().create_timer(180.0).timeout
	get_tree().quit()


## Phase 1: Verify configuration constants and terrain setup
func _test_configuration() -> void:
	_check("UNITS_PER_METER = 70", is_equal_approx(CS.UNITS_PER_METER, 70.0),
		"Got %.4f" % CS.UNITS_PER_METER)

	_check("CELL_SIZE_MW = 8192", is_equal_approx(CS.CELL_SIZE_MW, 8192.0),
		"Got %.4f" % CS.CELL_SIZE_MW)

	_check("CELL_SIZE_GODOT ≈ 117.03", abs(CS.CELL_SIZE_GODOT - 117.03) < 0.1,
		"Got %.4f" % CS.CELL_SIZE_GODOT)

	_check("TERRAIN_VERTEX_SPACING ≈ 1.828", abs(CS.TERRAIN_VERTEX_SPACING - 1.828) < 0.01,
		"Got %.4f" % CS.TERRAIN_VERTEX_SPACING)

	_check("TERRAIN_REGION_SIZE = 256", CS.TERRAIN_REGION_SIZE == 256,
		"Got %d" % CS.TERRAIN_REGION_SIZE)

	# Expected region world size: 256 * 1.828 ≈ 468.1m (= 4 cells * 117m)
	var expected_region_world: float = CS.TERRAIN_REGION_SIZE * CS.TERRAIN_VERTEX_SPACING
	var expected_4cells: float = 4.0 * CS.CELL_SIZE_GODOT
	_check("Region world size ≈ 4 cells", abs(expected_region_world - expected_4cells) < 0.5,
		"Region=%.2f vs 4cells=%.2f (diff=%.2f)" % [
			expected_region_world, expected_4cells,
			expected_region_world - expected_4cells])

	# Check MW coordinate conversion
	var mw_origin := Vector3(0, 0, 0)
	var godot_origin := CS.vector_to_godot(mw_origin)
	_check("MW origin → Godot origin", godot_origin.is_zero_approx(),
		"Got %s" % godot_origin)

	# Check a known position: cell (-2, -9) center in MW
	var seyda_mw := Vector3(-2.0 * 8192.0 + 4096.0, -9.0 * 8192.0 + 4096.0, 0.0)
	var seyda_godot := CS.vector_to_godot(seyda_mw)
	var seyda_expected := CS.cell_grid_to_center_godot(Vector2i(-2, -9))
	_check("Seyda Neen center conversion", seyda_godot.distance_to(seyda_expected) < 1.0,
		"Converted=%s, Expected=%s, Diff=%.2f" % [seyda_godot, seyda_expected,
			seyda_godot.distance_to(seyda_expected)])


## Phase 2: Test height pipeline from raw MW data to Terrain3D
func _test_height_pipeline() -> void:
	# Create fresh Terrain3D (no cache)
	_terrain = Terrain3D.new()
	_terrain.name = "DiagnosticTerrain"
	_terrain.top_level = true
	# Scale workaround: vertex_spacing=1.0 (DLL crashes if !=1.0), node scaled instead.
	CS.configure_terrain3d_pre_tree(_terrain)
	add_child(_terrain)

	# Re-disable physics — C++ ENTER_TREE re-enables
	_terrain.set_physics_process(false)
	_terrain.set_process(false)
	await get_tree().process_frame

	# Configure terrain (reinforces scale, sets material, assets, region_size)
	var configured: bool = CS.configure_terrain3d(_terrain)
	_check("configure_terrain3d() succeeds", configured, "")

	_log("Terrain scale: %s" % _terrain.scale)
	_log("Terrain vertex_spacing: %.4f" % _terrain.get_vertex_spacing())
	_log("Terrain region_size: %d" % _terrain.get_region_size())
	_check("Scale X ≈ TERRAIN_VERTEX_SPACING", is_equal_approx(_terrain.scale.x, CS.TERRAIN_VERTEX_SPACING),
		"Got %.4f, expected %.4f" % [_terrain.scale.x, CS.TERRAIN_VERTEX_SPACING])
	_check("Scale Y = 1.0", is_equal_approx(_terrain.scale.y, 1.0),
		"Got %.4f" % _terrain.scale.y)

	# Clipmap proxy: Terrain3D's clipmap centers on get_clipmap_target_position()
	# which returns the target's WORLD position. With the scale workaround, world != internal.
	# We set a proxy node whose position = camera's INTERNAL-space position, so the
	# clipmap samples terrain data at the correct internal coordinates.
	_clipmap_proxy = Node3D.new()
	_clipmap_proxy.name = "ClipmapProxy"
	add_child(_clipmap_proxy)
	_terrain.set_clipmap_target(_clipmap_proxy)

	# Test with Seyda Neen area — cell (-2, -9) is a well-known location
	var test_cells: Array[Vector2i] = [
		Vector2i(-2, -9),   # Seyda Neen
		Vector2i(-1, -9),   # East of Seyda Neen
		Vector2i(-2, -8),   # North of Seyda Neen
		Vector2i(0, 0),     # Origin
	]

	var terrain_manager := TerrainManagerScript.new()

	for cell_coord in test_cells:
		var land: LandRecord = ESMManager.get_land(cell_coord.x, cell_coord.y)
		if not land or not land.has_heights():
			_warn("No LAND data for cell %s — skipping" % cell_coord)
			continue

		# Raw MW heights at cell corners and center
		var raw_sw: float = land.get_height(0, 0)      # SW corner
		var raw_ne: float = land.get_height(64, 64)     # NE corner
		var raw_center: float = land.get_height(32, 32) # Center

		# Expected Godot heights
		var exp_sw: float = raw_sw / CS.UNITS_PER_METER
		var exp_ne: float = raw_ne / CS.UNITS_PER_METER
		var exp_center: float = raw_center / CS.UNITS_PER_METER

		_log("Cell %s: raw_sw=%.1f, raw_ne=%.1f, raw_center=%.1f (MW units)" % [
			cell_coord, raw_sw, raw_ne, raw_center])
		_log("  Expected Godot: sw=%.2f, ne=%.2f, center=%.2f (meters)" % [
			exp_sw, exp_ne, exp_center])

		# Generate heightmap image
		var heightmap: Image = terrain_manager.generate_heightmap(land)
		_check("Heightmap generated for %s" % cell_coord, heightmap != null, "")
		if not heightmap:
			continue

		# Check heightmap pixel values
		# After Y-flip: MW y=32, x=32 → image y = 65-1-32 = 32, x = 32
		var px_center: Color = heightmap.get_pixel(32, 32)
		var img_height_center: float = px_center.r  # FORMAT_RF stores height in red channel

		_check("Cell %s center height in image ≈ expected" % cell_coord,
			abs(img_height_center - exp_center) < 0.1,
			"Image=%.4f, Expected=%.4f, Diff=%.4f" % [
				img_height_center, exp_center, img_height_center - exp_center])

		# Import this cell's region into fresh Terrain3D
		var region_coord: Vector2i = terrain_manager.cell_to_region(cell_coord)
		var import_ok: bool = terrain_manager.import_combined_region(
			_terrain, region_coord,
			func(cx: int, cy: int) -> LandRecord: return ESMManager.get_land(cx, cy)
		)
		_check("import_combined_region(%s) for cell %s" % [region_coord, cell_coord],
			import_ok, "")

	await get_tree().process_frame

	# Now test height queries via CS.get_terrain_height()
	_log("")
	_log("Height query tests:")

	for cell_coord in test_cells:
		var land: LandRecord = ESMManager.get_land(cell_coord.x, cell_coord.y)
		if not land or not land.has_heights():
			continue

		# Cell center in Godot world coords
		var center_godot: Vector3 = CS.cell_grid_to_center_godot(cell_coord)

		# Get terrain height at center
		var terrain_h: float = CS.get_terrain_height(center_godot, _terrain)

		# Expected: raw MW center height / 70
		var raw_center: float = land.get_height(32, 32)
		var exp_center: float = raw_center / CS.UNITS_PER_METER

		var diff: float = abs(terrain_h - exp_center)
		# Allow some tolerance for interpolation (Terrain3D interpolates between vertices)
		_check("Cell %s center: terrain query ≈ expected (tol 2m)" % cell_coord,
			diff < 2.0,
			"Terrain=%.2f, Expected=%.2f, Diff=%.2f" % [terrain_h, exp_center, diff])

		# Also test import position mapping (NW corner: Z = -(y+1) * size)
		var region_coord: Vector2i = terrain_manager.cell_to_region(cell_coord)
		var vertex_spacing: float = _terrain.get_vertex_spacing()
		var region_world_size: float = float(256) * vertex_spacing
		var import_x: float = float(region_coord.x) * region_world_size + 0.5
		var import_z: float = float(-region_coord.y - 1) * region_world_size + 0.5
		var import_pos := Vector3(import_x, 0, import_z)

		# The import position in internal space should map to the correct region
		var t3d_loc: Vector2i = _terrain.data.get_region_location(import_pos)
		_log("  Region %s: import_pos=%s, T3D_loc=%s" % [region_coord, import_pos, t3d_loc])


## Phase 3: Compare with cached/prebaked terrain
func _test_cached_terrain() -> void:
	var terrain_path: String = SettingsManager.get_terrain_path()
	if not DirAccess.dir_exists_absolute(terrain_path):
		_warn("No cached terrain at: %s" % terrain_path)
		_warn("Terrain needs to be prebaked first!")
		return

	# Create a separate Terrain3D for cached data
	var cached_terrain := Terrain3D.new()
	cached_terrain.name = "CachedTerrain"
	cached_terrain.top_level = true
	CS.configure_terrain3d_pre_tree(cached_terrain)
	add_child(cached_terrain)
	cached_terrain.set_physics_process(false)
	cached_terrain.set_process(false)
	await get_tree().process_frame

	CS.configure_terrain3d(cached_terrain)
	cached_terrain.data.load_directory(terrain_path)

	var region_count: int = cached_terrain.data.get_region_count()
	_log("Cached terrain: %d regions from %s" % [region_count, terrain_path])
	_check("Cached terrain has regions", region_count > 0,
		"Got %d regions" % region_count)

	_log("Cached terrain scale: %s" % cached_terrain.scale)
	_log("Cached terrain vertex_spacing: %.4f" % cached_terrain.get_vertex_spacing())

	# Compare cached terrain heights with raw MW data at Seyda Neen
	var test_cells: Array[Vector2i] = [
		Vector2i(-2, -9),
		Vector2i(-1, -9),
		Vector2i(-2, -8),
	]

	for cell_coord in test_cells:
		var land: LandRecord = ESMManager.get_land(cell_coord.x, cell_coord.y)
		if not land or not land.has_heights():
			continue

		var center_godot: Vector3 = CS.cell_grid_to_center_godot(cell_coord)
		var cached_h: float = CS.get_terrain_height(center_godot, cached_terrain)
		var raw_center: float = land.get_height(32, 32)
		var exp_center: float = raw_center / CS.UNITS_PER_METER

		var diff: float = abs(cached_h - exp_center)
		_check("Cached cell %s: height ≈ expected (tol 2m)" % cell_coord,
			diff < 2.0,
			"Cached=%.2f, Expected=%.2f, Diff=%.2f" % [cached_h, exp_center, diff])

		# Also compare with fresh terrain
		if _terrain and _terrain.data:
			var fresh_h: float = CS.get_terrain_height(center_godot, _terrain)
			var cache_vs_fresh: float = abs(cached_h - fresh_h)
			_check("Cell %s: cached ≈ fresh (tol 1m)" % cell_coord,
				cache_vs_fresh < 1.0,
				"Cached=%.2f, Fresh=%.2f, Diff=%.2f" % [cached_h, fresh_h, cache_vs_fresh])

	# Keep fresh terrain for Phase 4 (object alignment) — it has the FIXED positions.
	# Cached terrain has stale data from the old import formula.
	# The visual display uses whatever _terrain points to.
	cached_terrain.queue_free()


## Phase 4: Object alignment — check ESM objects vs terrain height
func _test_object_alignment() -> void:
	if not _terrain or not _terrain.data:
		_warn("No terrain available for object alignment test")
		return

	# Load Seyda Neen cell objects
	var cell_manager := CellManagerScript.new()
	cell_manager.load_npcs = false
	cell_manager.load_creatures = false
	cell_manager.use_static_renderer = false
	cell_manager.use_multimesh_instancing = false
	var seyda_cell: Node3D = cell_manager.load_exterior_cell(-2, -9)
	if not seyda_cell:
		_warn("Could not load Seyda Neen cell (-2, -9)")
		return

	add_child(seyda_cell)
	await get_tree().process_frame

	var checked: int = 0
	var alignment_diffs: PackedFloat64Array = []

	for child: Node in seyda_cell.get_children():
		if child is Node3D and checked < 20:
			var pos: Vector3 = (child as Node3D).global_position
			var terrain_h: float = CS.get_terrain_height(pos, _terrain)

			# Skip objects that are supposed to be elevated (doors, signs, etc.)
			# Focus on objects that should sit ON the terrain
			var diff: float = pos.y - terrain_h
			alignment_diffs.append(diff)

			var status: String
			if abs(diff) < 5.0:
				status = "OK"
			elif diff > 5.0:
				status = "FLOATING"
			else:
				status = "BURIED"

			_log("  [%s] '%s' Y=%.1f, Terrain=%.1f, Diff=%.1f" % [
				status, child.name, pos.y, terrain_h, diff])
			checked += 1

	# Statistical summary
	if alignment_diffs.size() > 0:
		var sum: float = 0.0
		var abs_sum: float = 0.0
		var max_diff: float = 0.0
		for d: float in alignment_diffs:
			sum += d
			abs_sum += abs(d)
			if abs(d) > abs(max_diff):
				max_diff = d

		var avg: float = sum / alignment_diffs.size()
		var abs_avg: float = abs_sum / alignment_diffs.size()

		_log("")
		_log("Alignment statistics (%d objects):" % alignment_diffs.size())
		_log("  Mean diff: %.2fm (positive = objects above terrain)" % avg)
		_log("  Mean |diff|: %.2fm" % abs_avg)
		_log("  Max diff: %.2fm" % max_diff)

		# PASS if average absolute diff < 3m (objects should sit ON terrain)
		_check("Mean alignment < 3m", abs_avg < 3.0,
			"Mean |diff| = %.2fm" % abs_avg)

		# Additional check: consistent bias suggests systematic offset
		if abs(avg) > 2.0:
			_warn("Systematic offset detected: mean diff = %.2fm — terrain may be too %s" % [
				avg, "low" if avg > 0 else "high"])


#region Utilities

func _check(name: String, passed: bool, detail: String) -> void:
	var status := "PASS" if passed else "FAIL"
	if not passed:
		_fail_count += 1
	else:
		_pass_count += 1
	var msg := "[%s] %s" % [status, name]
	if not detail.is_empty():
		msg += " — %s" % detail
	_log(msg)


func _warn(msg: String) -> void:
	_warn_count += 1
	_log("[WARN] %s" % msg)


func _log(msg: String) -> void:
	_results.append(msg)
	Log.info("testing", "[ALIGN] %s" % msg)
	print(msg)


func _save_results() -> void:
	var path := "user://terrain_alignment_results.txt"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		for line: String in _results:
			file.store_line(line)
		file.close()
		_log("Results saved to: %s" % path)


func _finish() -> void:
	_log("Test finished early due to error.")
	await get_tree().create_timer(5.0).timeout
	get_tree().quit()


var _yaw: float = 0.0
var _pitch: float = 0.0


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.current = true
	_camera.far = 10000.0
	add_child(_camera)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_yaw -= event.relative.x * 0.003
		_pitch -= event.relative.y * 0.003
		_pitch = clampf(_pitch, -PI / 2.0 + 0.1, PI / 2.0 - 0.1)
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		get_tree().quit()


func _process(delta: float) -> void:
	if not _camera:
		return
	var basis := Basis.from_euler(Vector3(_pitch, _yaw, 0))
	_camera.basis = basis
	var velocity := Vector3.ZERO
	var speed := 50.0
	if Input.is_physical_key_pressed(KEY_SHIFT):
		speed *= 5.0
	if Input.is_physical_key_pressed(KEY_W):
		velocity -= basis.z
	if Input.is_physical_key_pressed(KEY_S):
		velocity += basis.z
	if Input.is_physical_key_pressed(KEY_A):
		velocity -= basis.x
	if Input.is_physical_key_pressed(KEY_D):
		velocity += basis.x
	if Input.is_physical_key_pressed(KEY_SPACE):
		velocity += basis.y
	if Input.is_physical_key_pressed(KEY_CTRL):
		velocity -= basis.y
	if velocity.length_squared() > 0:
		_camera.position += velocity.normalized() * speed * delta

	# Update clipmap proxy to camera's INTERNAL-space position
	# so Terrain3D's clipmap renders around the correct data region
	if _clipmap_proxy and _terrain:
		_clipmap_proxy.global_position = _terrain.global_transform.affine_inverse() * _camera.global_position

#endregion
