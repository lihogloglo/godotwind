## LodOverlapTest — Automated LOD transition & overlap detector
##
## Places 5 primitive objects at the center, each with 4 color-coded LOD meshes:
##   LOD0 (NEAR, 0-150m)   = GREEN
##   LOD1 (MID,  150-250m) = YELLOW
##   LOD2 (MID,  250-375m) = ORANGE
##   LOD3 (MID,  375-500m) = RED
##
## Automated camera sweeps from 600m → 10m → 600m, sampling visibility at each
## meter. Prints a structured report of every overlap, gap, and transition.
## Then quits automatically.
##
## Open as standalone scene: lod_overlap_test.tscn
@warning_ignore("untyped_declaration", "unsafe_method_access")
class_name LodOverlapTest
extends Node3D

const DU := preload("res://src/core/world/distance_utils.gd")
const LODCfg := preload("res://src/core/world/lod_configurator.gd")

#region Constants

const OBJECT_SPACING := 15.0
const CAMERA_HEIGHT := 5.0

## LOD color palette
const LOD_COLORS: Array[Color] = [
	Color(0.1, 0.8, 0.2),   # LOD0 GREEN
	Color(0.9, 0.85, 0.1),  # LOD1 YELLOW
	Color(0.95, 0.5, 0.1),  # LOD2 ORANGE
	Color(0.9, 0.15, 0.1),  # LOD3 RED
]

## Test object definitions: [name, shape_type, size_scale]
const OBJECTS: Array[Array] = [
	["Box", 0, 3.0],
	["Sphere", 1, 3.0],
	["Cylinder", 2, 3.0],
	["Capsule", 3, 3.0],
	["Prism", 4, 3.0],
]

## Automated sweep parameters
const SWEEP_START := 600.0
const SWEEP_END := 10.0
const SWEEP_SPEED := 60.0       # meters per second (approach)
const SWEEP_RETURN_SPEED := 80.0 # meters per second (retreat)
const SAMPLE_INTERVAL := 1.0    # sample every 1 meter

## LOD boundary distances (must match LODConfigurator)
const BOUNDARIES: Array[float] = [150.0, 250.0, 375.0, 500.0]
const BOUNDARY_NAMES: Array[String] = ["NEAR/LOD1", "LOD1/LOD2", "LOD2/LOD3", "LOD3/HIDDEN"]

#endregion


#region State

var _camera: Camera3D
var _center := Vector3.ZERO

## Per-object tracking: Array of { name, lods: Array[MeshInstance3D], pos: Vector3 }
var _test_objects: Array[Dictionary] = []

## Automated sweep
enum Phase { STABILIZE, APPROACH, HOLD_NEAR, RETREAT, DONE }
var _phase: int = Phase.STABILIZE
var _phase_timer := 0.0
var _current_distance := SWEEP_START

## Sampling
var _last_sample_distance := SWEEP_START + 100.0  # force first sample
var _approach_samples: Array[Dictionary] = []
var _retreat_samples: Array[Dictionary] = []
var _is_retreating := false

## Report
var _overlaps_approach: Array[Dictionary] = []
var _overlaps_retreat: Array[Dictionary] = []
var _gaps_approach: Array[Dictionary] = []
var _gaps_retreat: Array[Dictionary] = []
var _transitions: Array[Dictionary] = []  # boundary crossing events
var _prev_visible_set: Dictionary = {}  # obj_name -> Array[int] of visible LOD indices

## Rendered objects tracking for console output
var _frame_count := 0

#endregion


#region Lifecycle

func _ready() -> void:
	_setup_environment()
	_setup_camera()
	_create_test_objects()
	_print_config()
	print("")
	print("=== LOD OVERLAP TEST: STARTING AUTOMATED SWEEP ===")
	print("Sweep: %.0fm -> %.0fm -> %.0fm at %.0f/%.0f m/s" % [
		SWEEP_START, SWEEP_END, SWEEP_START, SWEEP_SPEED, SWEEP_RETURN_SPEED])
	print("Objects: %d, each with 4 LOD levels" % OBJECTS.size())
	print("Boundaries: %s" % str(BOUNDARIES))
	print("Fade margins: NEAR/LOD1=%.0fm, LOD1/LOD2=%.0fm, LOD2/LOD3=%.0fm, LOD3/FAR=%.0fm" % [
		DU.FADE_MARGIN_NEAR_LOD1, DU.FADE_MARGIN_LOD1_LOD2,
		DU.FADE_MARGIN_LOD2_LOD3, DU.FADE_MARGIN_LOD3_FAR])
	print("")


func _process(delta: float) -> void:
	_frame_count += 1
	match _phase:
		Phase.STABILIZE:
			_phase_timer += delta
			if _phase_timer >= 1.0:  # 1 second to let rendering stabilize
				_phase = Phase.APPROACH
				_phase_timer = 0.0
				print("Phase: APPROACH (%.0fm -> %.0fm)" % [SWEEP_START, SWEEP_END])
		Phase.APPROACH:
			_advance_camera(-SWEEP_SPEED * delta)  # negative = approaching
			_sample_visibility()
			if _current_distance <= SWEEP_END:
				_phase = Phase.HOLD_NEAR
				_phase_timer = 0.0
				print("Phase: HOLD_NEAR (1s)")
		Phase.HOLD_NEAR:
			_phase_timer += delta
			if _phase_timer >= 1.0:
				_phase = Phase.RETREAT
				_is_retreating = true
				_last_sample_distance = _current_distance - 100.0  # force sample
				print("Phase: RETREAT (%.0fm -> %.0fm)" % [SWEEP_END, SWEEP_START])
		Phase.RETREAT:
			_advance_camera(SWEEP_RETURN_SPEED * delta)  # positive = retreating
			_sample_visibility()
			if _current_distance >= SWEEP_START:
				_phase = Phase.DONE
				_finish_test()
		Phase.DONE:
			pass


func _advance_camera(distance_delta: float) -> void:
	_current_distance += distance_delta
	_current_distance = clampf(_current_distance, SWEEP_END, SWEEP_START)
	_camera.position = Vector3(0, CAMERA_HEIGHT, _current_distance)

#endregion


#region Setup

func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.15, 0.18, 0.25)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.7, 0.75)
	env.ambient_light_energy = 0.6

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 30, 0)
	sun.shadow_enabled = true
	sun.light_energy = 1.2
	add_child(sun)


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.fov = 75.0
	_camera.far = 6000.0
	_camera.position = Vector3(0, CAMERA_HEIGHT, SWEEP_START)
	_camera.rotation_degrees = Vector3(0, 0, 0)
	add_child(_camera)
	_camera.current = true


func _create_test_objects() -> void:
	var half_width: float = (OBJECTS.size() - 1) * OBJECT_SPACING * 0.5

	for i in range(OBJECTS.size()):
		var obj_def: Array = OBJECTS[i]
		var obj_name: String = obj_def[0]
		var shape_type: int = obj_def[1]
		var obj_scale: float = obj_def[2]

		var x_pos: float = -half_width + i * OBJECT_SPACING
		var obj_pos := Vector3(x_pos, obj_scale * 0.5, 0)

		var entry := {"name": obj_name, "lods": [] as Array[MeshInstance3D], "pos": obj_pos}

		# Parent node — visibility_range DEPENDENCIES requires siblings
		var group := Node3D.new()
		group.name = obj_name
		group.position = obj_pos
		add_child(group)

		for lod in range(4):
			var mi := _create_lod_mesh(shape_type, lod, obj_scale)
			mi.name = "%s_LOD%d" % [obj_name, lod]
			group.add_child(mi)
			entry.lods.append(mi)

		# Apply LOD configuration using our real LODConfigurator
		var configurator := LODCfg.new()
		configurator.configure_lod_chain(entry.lods[0], entry.lods[1], entry.lods[2], entry.lods[3])

		_test_objects.append(entry)


func _create_lod_mesh(shape_type: int, lod_level: int, base_scale: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh: Mesh

	var detail_factor := 1.0 - lod_level * 0.2
	var lod_scale: float = base_scale * (1.0 + lod_level * 0.03)

	match shape_type:
		0:
			var box := BoxMesh.new()
			box.size = Vector3.ONE * lod_scale
			mesh = box
		1:
			var sphere := SphereMesh.new()
			sphere.radius = lod_scale * 0.5
			sphere.height = lod_scale
			sphere.radial_segments = int(32 * detail_factor)
			sphere.rings = int(16 * detail_factor)
			mesh = sphere
		2:
			var cyl := CylinderMesh.new()
			cyl.top_radius = lod_scale * 0.4
			cyl.bottom_radius = lod_scale * 0.4
			cyl.height = lod_scale
			cyl.radial_segments = int(32 * detail_factor)
			mesh = cyl
		3:
			var cap := CapsuleMesh.new()
			cap.radius = lod_scale * 0.35
			cap.height = lod_scale
			cap.radial_segments = int(32 * detail_factor)
			cap.rings = int(8 * detail_factor)
			mesh = cap
		4:
			var prism := PrismMesh.new()
			prism.size = Vector3.ONE * lod_scale
			mesh = prism

	mi.mesh = mesh

	var mat := StandardMaterial3D.new()
	mat.albedo_color = LOD_COLORS[lod_level]
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	mi.material_override = mat

	return mi

#endregion


#region Visibility Sampling

func _sample_visibility() -> void:
	# Sample every SAMPLE_INTERVAL meters of camera movement
	if absf(_current_distance - _last_sample_distance) < SAMPLE_INTERVAL:
		return
	_last_sample_distance = _current_distance

	var cam_pos := _camera.global_position

	for entry in _test_objects:
		var obj_name: String = entry.name
		var obj_pos: Vector3 = entry.pos
		var obj_dist := cam_pos.distance_to(obj_pos)
		var lods: Array = entry.lods

		# Query which LODs the engine considers visible at this distance
		var visible_indices: Array[int] = []
		for lod_idx in range(lods.size()):
			var mi: MeshInstance3D = lods[lod_idx]
			# Use the actual visibility_range properties to determine if engine renders it
			var begin: float = mi.visibility_range_begin
			var end: float = mi.visibility_range_end
			var begin_margin: float = mi.visibility_range_begin_margin
			var end_margin: float = mi.visibility_range_end_margin

			# Engine renders within [begin - begin_margin, end + end_margin]
			# (the margin zone is where fading happens)
			if obj_dist >= (begin - begin_margin) and obj_dist <= (end + end_margin):
				visible_indices.append(lod_idx)

		var sample := {
			"distance": obj_dist,
			"cam_distance": _current_distance,
			"object": obj_name,
			"visible": visible_indices.duplicate(),
			"frame": _frame_count,
		}

		if _is_retreating:
			_retreat_samples.append(sample)
		else:
			_approach_samples.append(sample)

		# Detect overlaps (2+ LODs visible)
		if visible_indices.size() > 1:
			var overlap := {
				"distance": obj_dist,
				"object": obj_name,
				"visible": visible_indices.duplicate(),
			}
			if _is_retreating:
				_overlaps_retreat.append(overlap)
			else:
				_overlaps_approach.append(overlap)

		# Detect gaps (0 LODs visible in expected range)
		if visible_indices.is_empty() and obj_dist < 500.0:
			var gap := {
				"distance": obj_dist,
				"object": obj_name,
			}
			if _is_retreating:
				_gaps_retreat.append(gap)
			else:
				_gaps_approach.append(gap)

		# Detect transitions (LOD set changed from previous sample)
		var prev: Variant = _prev_visible_set.get(obj_name)
		if prev != null and prev != visible_indices:
			_transitions.append({
				"distance": obj_dist,
				"object": obj_name,
				"from": (prev as Array[int]).duplicate(),
				"to": visible_indices.duplicate(),
				"direction": "retreat" if _is_retreating else "approach",
			})

		_prev_visible_set[obj_name] = visible_indices

#endregion


#region Report

func _print_config() -> void:
	print("=== LOD CONFIGURATION DUMP ===")
	for entry in _test_objects:
		print("  %s:" % entry.name)
		var lods: Array = entry.lods
		for lod_idx in range(lods.size()):
			var mi: MeshInstance3D = lods[lod_idx]
			var fade_str: String
			match mi.visibility_range_fade_mode:
				GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED: fade_str = "DISABLED"
				GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF: fade_str = "SELF"
				GeometryInstance3D.VISIBILITY_RANGE_FADE_DEPENDENCIES: fade_str = "DEPENDENCIES"
				_: fade_str = "?"
			print("    LOD%d: begin=%.0f end=%.0f begin_margin=%.0f end_margin=%.0f fade=%s" % [
				lod_idx,
				mi.visibility_range_begin,
				mi.visibility_range_end,
				mi.visibility_range_begin_margin,
				mi.visibility_range_end_margin,
				fade_str,
			])
			print("          -> visible in [%.0fm .. %.0fm]" % [
				mi.visibility_range_begin - mi.visibility_range_begin_margin,
				mi.visibility_range_end + mi.visibility_range_end_margin,
			])


func _finish_test() -> void:
	print("")
	print("========================================================")
	print("=== LOD OVERLAP TEST RESULTS ===")
	print("========================================================")
	print("")
	print("Samples: %d approach, %d retreat" % [_approach_samples.size(), _retreat_samples.size()])
	print("Frames: %d total" % _frame_count)
	print("")

	# --- Overlap Report ---
	print("=== OVERLAPS (multiple LODs visible simultaneously) ===")
	_print_overlap_summary("APPROACH", _overlaps_approach)
	_print_overlap_summary("RETREAT", _overlaps_retreat)

	# --- Gap Report ---
	print("=== GAPS (no LOD visible where one should be) ===")
	if _gaps_approach.is_empty() and _gaps_retreat.is_empty():
		print("  None detected.")
	else:
		if not _gaps_approach.is_empty():
			print("  APPROACH: %d gaps" % _gaps_approach.size())
			_print_distance_ranges("    ", _gaps_approach)
		if not _gaps_retreat.is_empty():
			print("  RETREAT: %d gaps" % _gaps_retreat.size())
			_print_distance_ranges("    ", _gaps_retreat)
	print("")

	# --- Transition Report ---
	print("=== TRANSITIONS (LOD switches) ===")
	var approach_transitions: Array[Dictionary] = []
	var retreat_transitions: Array[Dictionary] = []
	for t in _transitions:
		if t.direction == "approach":
			approach_transitions.append(t)
		else:
			retreat_transitions.append(t)

	# Only print transitions for the first object to avoid repetition
	var first_obj: String = OBJECTS[0][0]
	print("  (Showing transitions for '%s' only)" % first_obj)
	print("  APPROACH:")
	for t in approach_transitions:
		if t.object == first_obj:
			print("    %.0fm: LOD%s -> LOD%s" % [t.distance, _lod_list_str(t.from), _lod_list_str(t.to)])
	print("  RETREAT:")
	for t in retreat_transitions:
		if t.object == first_obj:
			print("    %.0fm: LOD%s -> LOD%s" % [t.distance, _lod_list_str(t.from), _lod_list_str(t.to)])
	print("")

	# --- Boundary Analysis ---
	print("=== BOUNDARY ANALYSIS ===")
	print("  Expected boundaries: %s" % str(BOUNDARIES))
	var boundary_margins: Array[float] = [
		DU.FADE_MARGIN_NEAR_LOD1, DU.FADE_MARGIN_LOD1_LOD2,
		DU.FADE_MARGIN_LOD2_LOD3, DU.FADE_MARGIN_LOD3_FAR]
	print("")
	for i in range(BOUNDARIES.size()):
		var bd: float = BOUNDARIES[i]
		var bd_name: String = BOUNDARY_NAMES[i]
		var margin: float = boundary_margins[i]
		var overlap_zone_start := bd - margin
		var overlap_zone_end := bd + margin
		print("  %s boundary at %.0fm (margin=%.0fm):" % [bd_name, bd, margin])
		print("    Fade zone: %.0fm - %.0fm (%.0fm wide)" % [
			overlap_zone_start, overlap_zone_end, margin * 2])

		# Count overlaps in this boundary zone
		var approach_count := 0
		for o in _overlaps_approach:
			if o.distance >= overlap_zone_start and o.distance <= overlap_zone_end:
				approach_count += 1
		var retreat_count := 0
		for o in _overlaps_retreat:
			if o.distance >= overlap_zone_start and o.distance <= overlap_zone_end:
				retreat_count += 1

		var status: String
		if approach_count > 0 or retreat_count > 0:
			status = "OVERLAP DETECTED (approach: %d, retreat: %d samples)" % [approach_count, retreat_count]
		else:
			status = "CLEAN"
		print("    Status: %s" % status)
	print("")

	# --- Verdict ---
	var total_overlaps := _overlaps_approach.size() + _overlaps_retreat.size()
	var total_gaps := _gaps_approach.size() + _gaps_retreat.size()
	print("=== VERDICT ===")
	if total_overlaps == 0 and total_gaps == 0:
		print("  PASS: No overlaps or gaps detected.")
	else:
		if total_overlaps > 0:
			print("  FAIL: %d overlap samples detected." % total_overlaps)
			print("        Two LOD levels are rendering simultaneously in the fade zone.")
			print("        This means FADE_DEPENDENCIES is creating a crossfade zone where")
			print("        both adjacent LODs are partially visible. If this is intentional")
			print("        (smooth crossfade), then the margin may just be too large.")
		if total_gaps > 0:
			print("  FAIL: %d gap samples detected (object invisible within 500m)." % total_gaps)
	print("")
	print("========================================================")
	print("")

	# Auto-quit after report
	get_tree().create_timer(0.5).timeout.connect(func() -> void: get_tree().quit())


func _print_overlap_summary(direction: String, overlaps: Array[Dictionary]) -> void:
	if overlaps.is_empty():
		print("  %s: None" % direction)
		return

	print("  %s: %d overlap samples" % [direction, overlaps.size()])

	# Group by distance range
	var min_dist := 99999.0
	var max_dist := 0.0
	var by_pair: Dictionary = {}  # "LOD0+LOD1" -> count

	for o in overlaps:
		min_dist = minf(min_dist, o.distance)
		max_dist = maxf(max_dist, o.distance)
		var key := _lod_list_str(o.visible)
		by_pair[key] = by_pair.get(key, 0) + 1

	print("    Distance range: %.0fm - %.0fm" % [min_dist, max_dist])
	print("    Overlap pairs:")
	for key: String in by_pair:
		var count: int = by_pair[key]
		# Count is per-object, divide by object count for distance samples
		var dist_samples: int = ceili(float(count) / OBJECTS.size())
		print("      LOD%s: %d samples (~%dm of travel)" % [key, count, dist_samples])


func _print_distance_ranges(prefix: String, items: Array[Dictionary]) -> void:
	if items.is_empty():
		return
	var min_d := 99999.0
	var max_d := 0.0
	for item in items:
		min_d = minf(min_d, item.distance)
		max_d = maxf(max_d, item.distance)
	print("%sDistance range: %.0fm - %.0fm (%d samples)" % [prefix, min_d, max_d, items.size()])


func _lod_list_str(indices) -> String:
	var parts := PackedStringArray()
	for idx in indices:
		parts.append(str(idx))
	return "+".join(parts)

#endregion
