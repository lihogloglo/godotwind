extends Node

const ImpostorBakerV3Script := preload("res://src/tools/prebaking/impostor_baker_v3.gd")


class HeightFilterSmokeBaker:
	extends ImpostorBakerV3Script

	var fake_height_m: float = 3.5

	func _load_model(_model_path: String) -> Node3D:
		var root := Node3D.new()
		var mesh_instance := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(1.0, fake_height_m, 1.0)
		mesh_instance.mesh = mesh
		root.add_child(mesh_instance)
		return root


func _ready() -> void:
	var baker := HeightFilterSmokeBaker.new()
	add_child(baker)
	await get_tree().process_frame

	var init_err := baker.initialize()
	if init_err != OK:
		_fail("initialize failed: %d" % init_err)
		return

	var result: Dictionary = await baker.bake_model("fake_small_prop.nif")
	if not bool(result.get("success", false)):
		_fail("single bake did not report success: %s" % str(result))
		return
	if not bool(result.get("skipped", false)):
		_fail("single bake did not report skipped: %s" % str(result))
		return
	if str(result.get("skip_reason", "")) != "height_below_minimum":
		_fail("unexpected skip reason: %s" % str(result))
		return
	if float(result.get("height_m", 0.0)) >= ImpostorBakerV3Script.MIN_IMPOSTOR_HEIGHT_M:
		_fail("height was not below threshold: %s" % str(result))
		return

	var batch_result: Dictionary = await baker.bake_models([
		"fake_small_prop_a.nif",
		"fake_small_prop_b.nif",
	])
	if int(batch_result.get("success", -1)) != 0:
		_fail("batch success count should exclude skipped models: %s" % str(batch_result))
		return
	if int(batch_result.get("skipped", -1)) != 2:
		_fail("batch skipped count mismatch: %s" % str(batch_result))
		return
	if int(batch_result.get("failed", -1)) != 0:
		_fail("batch failed count mismatch: %s" % str(batch_result))
		return

	print("[HEIGHT FILTER SMOKE] passed")
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error("[HEIGHT FILTER SMOKE] %s" % message)
	get_tree().quit(1)
