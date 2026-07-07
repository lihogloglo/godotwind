## Deterministic smoke for ImpostorBakerV3.
##
## Bakes the same model twice into isolated output dirs, then compares decoded
## albedo pixels, normal/depth pixels, and normalized metadata. This scene must
## run with a real renderer; Godot's --headless dummy renderer cannot capture
## SubViewport 3D output.
##
## Launch:
##   "<godot-executable>" \
##     --path "<project-path>" \
##     res://tests/prebaking/test_impostor_baker_v3.tscn
extends Node

const ImpostorBakerV3Script := preload("res://src/tools/prebaking/impostor_baker_v3.gd")
const ImpostorCandidatesScript := preload("res://src/core/world/impostor_candidates.gd")

const DEFAULT_MODEL: String = "meshes/x/ex_hlaalu_b_01.nif"
const BYTE_MAE_MAX: float = 5.0
const ALPHA_MASK_MISMATCH_MAX: float = 0.03


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	print("=== ImpostorBakerV3 Deterministic Smoke ===")
	if DisplayServer.get_name().to_lower().contains("headless"):
		push_error("This smoke requires a real rendering backend; do not run with --headless.")
		get_tree().quit(1)
		return

	if not _ensure_bsa_archives_loaded():
		get_tree().quit(1)
		return

	var model_path := _model_from_args()
	var root_dir := SettingsManager.get_impostors_path().path_join(
		"determinism_smoke_%d" % Time.get_ticks_usec()
	)
	var run_a_dir := root_dir.path_join("run_a")
	var run_b_dir := root_dir.path_join("run_b")
	DirAccess.make_dir_recursive_absolute(run_a_dir)
	DirAccess.make_dir_recursive_absolute(run_b_dir)

	var candidates := ImpostorCandidatesScript.new()
	var result_a := await _bake_once(model_path, candidates, run_a_dir)
	var result_b := await _bake_once(model_path, candidates, run_b_dir)
	if not bool(result_a.get("success", false)) or not bool(result_b.get("success", false)):
		push_error("Bake failed: run_a=%s run_b=%s" % [
			str(result_a.get("error", "")),
			str(result_b.get("error", "")),
		])
		get_tree().quit(1)
		return

	var albedo_metrics := _compare_image_pixels(
		str(result_a.get("output_path", "")),
		str(result_b.get("output_path", ""))
	)
	var normal_metrics := _compare_texture_resource_pixels(
		str(result_a.get("normal_path", "")),
		str(result_b.get("normal_path", ""))
	)
	var metadata_same := _compare_normalized_metadata(
		str(result_a.get("metadata_path", "")),
		str(result_b.get("metadata_path", ""))
	)

	print("model: %s" % model_path)
	print("run_a: %s" % run_a_dir)
	print("run_b: %s" % run_b_dir)
	_print_pixel_metrics("albedo", albedo_metrics)
	_print_pixel_metrics("normal_depth", normal_metrics)
	print("metadata_equal_excluding_volatile_paths: %s" % str(metadata_same))

	var ok := bool(albedo_metrics.get("accepted", false)) \
		and bool(normal_metrics.get("accepted", false)) \
		and metadata_same
	if not ok:
		push_error("Impostor deterministic smoke failed")
	await get_tree().create_timer(0.2).timeout
	get_tree().quit(0 if ok else 1)


func _model_from_args() -> String:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--model="):
			var value := arg.trim_prefix("--model=").strip_edges()
			if not value.is_empty():
				return value
	return DEFAULT_MODEL


func _ensure_bsa_archives_loaded() -> bool:
	if BSAManager.get_archive_count() > 0:
		return true
	var data_path: String = SettingsManager.get_data_path()
	if data_path.is_empty():
		push_error("No Morrowind data path configured")
		return false
	var loaded := BSAManager.load_archives_from_directory(data_path)
	print("Loaded %d BSA archives" % loaded)
	if loaded == 0:
		push_error("No BSA archives found in: %s" % data_path)
		return false
	return true


func _bake_once(model_path: String, candidates: ImpostorCandidatesScript, output_dir: String) -> Dictionary:
	var baker := ImpostorBakerV3Script.new()
	baker.output_dir = output_dir
	add_child(baker)
	await get_tree().process_frame
	var init_err := baker.initialize()
	if init_err != OK:
		baker.queue_free()
		return {"success": false, "error": "initialize failed: %d" % init_err}
	var result: Dictionary = await baker.bake_model(model_path, candidates)
	baker.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().create_timer(1.0).timeout
	return result


func _compare_image_pixels(path_a: String, path_b: String) -> Dictionary:
	var image_a := Image.new()
	var err_a := image_a.load(path_a)
	var image_b := Image.new()
	var err_b := image_b.load(path_b)
	if err_a != OK or err_b != OK:
		push_error("Failed to load image pair: %s (%d), %s (%d)" % [path_a, err_a, path_b, err_b])
		return {"accepted": false, "exact": false}
	return _image_pair_metrics(image_a, image_b)


func _compare_texture_resource_pixels(path_a: String, path_b: String) -> Dictionary:
	var tex_a := ResourceLoader.load(path_a, "", ResourceLoader.CACHE_MODE_IGNORE)
	var tex_b := ResourceLoader.load(path_b, "", ResourceLoader.CACHE_MODE_IGNORE)
	if not tex_a or not tex_b or not tex_a is Texture2D or not tex_b is Texture2D:
		push_error("Failed to load normal/depth texture resources: %s, %s" % [path_a, path_b])
		return {"accepted": false, "exact": false}
	var image_a := (tex_a as Texture2D).get_image()
	var image_b := (tex_b as Texture2D).get_image()
	if not image_a or not image_b:
		return {"accepted": false, "exact": false}
	return _image_pair_metrics(image_a, image_b)


func _image_pair_metrics(image_a: Image, image_b: Image) -> Dictionary:
	if image_a.get_size() != image_b.get_size() or image_a.get_format() != image_b.get_format():
		return {"accepted": false, "exact": false}
	var data_a := image_a.get_data()
	var data_b := image_b.get_data()
	if data_a.size() != data_b.size():
		return {"accepted": false, "exact": false}

	var diff_sum := 0
	var exact := true
	var alpha_mask_mismatch := 0
	var pixel_count := image_a.get_width() * image_a.get_height()
	for i in range(data_a.size()):
		var delta := absi(int(data_a[i]) - int(data_b[i]))
		if delta != 0:
			exact = false
			diff_sum += delta
		if i % 4 == 3:
			var mask_a := int(data_a[i]) >= 128
			var mask_b := int(data_b[i]) >= 128
			if mask_a != mask_b:
				alpha_mask_mismatch += 1

	var byte_mae := float(diff_sum) / float(data_a.size())
	var alpha_mask_mismatch_ratio := float(alpha_mask_mismatch) / float(pixel_count)
	return {
		"accepted": byte_mae <= BYTE_MAE_MAX and alpha_mask_mismatch_ratio <= ALPHA_MASK_MISMATCH_MAX,
		"exact": exact,
		"byte_mae": byte_mae,
		"alpha_mask_mismatch_ratio": alpha_mask_mismatch_ratio,
	}


func _print_pixel_metrics(label: String, metrics: Dictionary) -> void:
	print("%s_pixels_exact: %s" % [label, str(metrics.get("exact", false))])
	print("%s_tolerance_accepted: %s" % [label, str(metrics.get("accepted", false))])
	print("%s_byte_mae: %.6f" % [label, float(metrics.get("byte_mae", INF))])
	print("%s_alpha_mask_mismatch_ratio: %.6f" % [
		label,
		float(metrics.get("alpha_mask_mismatch_ratio", INF)),
	])


func _compare_normalized_metadata(path_a: String, path_b: String) -> bool:
	var meta_a := _load_metadata(path_a)
	var meta_b := _load_metadata(path_b)
	if meta_a.is_empty() or meta_b.is_empty():
		return false
	_normalize_metadata(meta_a)
	_normalize_metadata(meta_b)
	return JSON.stringify(meta_a, "", false) == JSON.stringify(meta_b, "", false)


func _load_metadata(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("Failed to open metadata: %s" % path)
		return {}
	var json := JSON.new()
	var err := json.parse(file.get_as_text())
	file.close()
	if err != OK or not json.data is Dictionary:
		push_error("Failed to parse metadata: %s" % path)
		return {}
	return json.data as Dictionary


func _normalize_metadata(metadata: Dictionary) -> void:
	metadata.erase("baked_date")
	if metadata.has("texture_path"):
		metadata["texture_path"] = str(metadata["texture_path"]).get_file()
	if metadata.has("normal_texture_path"):
		metadata["normal_texture_path"] = str(metadata["normal_texture_path"]).get_file()
