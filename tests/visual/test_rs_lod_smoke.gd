## Phase B.0 smoke test 2 — verify Godot automatically selects LOD levels
## on RAW RenderingServer instances (not MeshInstance3D nodes).
##
## Creates a mesh with a LOD chain via ImporterMesh, then an RS instance via
## RenderingServer.instance_create()/instance_set_base (NO MeshInstance3D wrapper),
## walks the camera out while sampling RENDER_INFO_PRIMITIVES_IN_FRAME.
##
## PASS: primitive count drops as the camera pulls back.
## FAIL: count stays constant → StaticObjectRenderer would need MeshInstance3D wrappers
##       and Phase D would need an architectural re-plan.
##
## Delete after Phase B.1 ships.
extends Node3D

var _mesh_rid: RID
var _instance_rid: RID
@onready var _camera: Camera3D = $Camera3D

const SAMPLE_DISTANCES: Array[float] = [5.0, 25.0, 50.0, 100.0, 200.0, 400.0, 800.0, 1600.0, 3200.0]
const SETTLE_FRAMES: int = 4

var _phase: int = 0   # 0 = setting pose, 1 = sampling
var _sample_index: int = 0
var _settle_counter: int = 0
var _results: Array = []
var _done: bool = false


func _ready() -> void:
	var base := _build_test_mesh(80)
	var base_indices: PackedInt32Array = base.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
	print("[rs_lod_smoke] Base mesh triangles: %d" % (base_indices.size() / 3))

	var importer := ImporterMesh.new()
	importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, base.surface_get_arrays(0), [], {}, StandardMaterial3D.new())
	importer.generate_lods(60.0, 25.0, [])
	var lod_mesh: ArrayMesh = importer.get_mesh()
	_mesh_rid = lod_mesh.get_rid()

	print("[rs_lod_smoke] ImporterMesh LOD count: %d" % importer.get_surface_lod_count(0))
	for i in range(importer.get_surface_lod_count(0)):
		var idx: PackedInt32Array = importer.get_surface_lod_indices(0, i)
		print("[rs_lod_smoke]   LOD%d: %d tris" % [i + 1, idx.size() / 3])

	var scenario := get_world_3d().scenario
	_instance_rid = RenderingServer.instance_create()
	RenderingServer.instance_set_base(_instance_rid, _mesh_rid)
	RenderingServer.instance_set_scenario(_instance_rid, scenario)
	RenderingServer.instance_set_transform(_instance_rid, Transform3D.IDENTITY)
	RenderingServer.instance_set_visible(_instance_rid, true)
	RenderingServer.instance_geometry_set_lod_bias(_instance_rid, 1.0)
	# Explicit AABB — the flat plane has zero Y extent which can upset culling.
	RenderingServer.instance_set_custom_aabb(_instance_rid, lod_mesh.get_aabb().grow(2.0))
	print("[rs_lod_smoke] scenario valid=%s aabb=%s" % [scenario.is_valid(), lod_mesh.get_aabb()])

	# Control MeshInstance3D — same mesh, offset to the side, to prove render-info
	# collection works at all.
	var ctrl := MeshInstance3D.new()
	ctrl.mesh = lod_mesh
	ctrl.position = Vector3(100, 0, 0)
	add_child(ctrl)

	# Ensure we're not on a viewport with mesh_lod_threshold set weird.
	get_viewport().mesh_lod_threshold = 1.0

	_set_camera_for_sample(0)


func _build_test_mesh(grid_size: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var step := 0.5
	var half := (grid_size * step) * 0.5
	for y in range(grid_size + 1):
		for x in range(grid_size + 1):
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(float(x) / grid_size, float(y) / grid_size))
			st.add_vertex(Vector3(x * step - half, 0.0, y * step - half))
	var stride := grid_size + 1
	for y in range(grid_size):
		for x in range(grid_size):
			var i00 := y * stride + x
			var i10 := y * stride + x + 1
			var i01 := (y + 1) * stride + x
			var i11 := (y + 1) * stride + x + 1
			st.add_index(i00); st.add_index(i10); st.add_index(i11)
			st.add_index(i00); st.add_index(i11); st.add_index(i01)
	return st.commit()


func _set_camera_for_sample(idx: int) -> void:
	var dist: float = SAMPLE_DISTANCES[idx]
	_camera.position = Vector3(0, dist * 0.3, dist)
	_camera.look_at(Vector3.ZERO, Vector3.UP)


func _process(_delta: float) -> void:
	if _done:
		return

	if _phase == 0:
		# Just moved camera; wait SETTLE_FRAMES for culler + LOD selector.
		_settle_counter += 1
		if _settle_counter >= SETTLE_FRAMES:
			_phase = 1
			_settle_counter = 0
		return

	# Phase 1 — sample. Wait one more frame so this frame's render info is current.
	await RenderingServer.frame_post_draw

	var viewport := get_viewport()
	# Read PRIMITIVES via the global per-frame counter (more reliable than per-viewport).
	var prims := RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME
	)
	# Also read per-viewport VISIBLE for comparison.
	var vis_prims := RenderingServer.viewport_get_render_info(
		viewport.get_viewport_rid(),
		RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
		RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME
	)
	var draw_calls := RenderingServer.viewport_get_render_info(
		viewport.get_viewport_rid(),
		RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
		RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME
	)
	print("[rs_lod_smoke]   global_prims=%d vis_prims=%d draw_calls=%d" % [prims, vis_prims, draw_calls])
	var dist: float = SAMPLE_DISTANCES[_sample_index]
	_results.append({"distance": dist, "primitives": prims})
	print("[rs_lod_smoke] distance=%.1fm primitives_in_frame=%d" % [dist, prims])

	_sample_index += 1
	if _sample_index >= SAMPLE_DISTANCES.size():
		_done = true
		_dump_results()
		return

	_set_camera_for_sample(_sample_index)
	_phase = 0


func _dump_results() -> void:
	print("\n[rs_lod_smoke] ====== RESULTS ======")
	var first_prims: int = int(_results[0]["primitives"])
	var last_prims: int = int(_results[_results.size() - 1]["primitives"])
	var pass_gate := first_prims > last_prims
	print("[rs_lod_smoke] first(%d) -> last(%d), drop=%d" % [
		first_prims, last_prims, first_prims - last_prims
	])
	if pass_gate:
		print("[rs_lod_smoke] *** PASS *** — auto-LOD works on raw RS instances")
	else:
		print("[rs_lod_smoke] *** FAIL *** — primitive count did not drop with distance")
		print("[rs_lod_smoke] Phase D would need MeshInstance3D wrappers")

	RenderingServer.free_rid(_instance_rid)
	await get_tree().create_timer(0.3).timeout
	get_tree().quit(0 if pass_gate else 2)
