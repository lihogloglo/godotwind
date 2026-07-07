## Full rebake autorun wrapper.
##
## Default: bake models, matching the original Phase G behavior.
## Pass --impostors-only to generate the full v6 impostor cache without the UI.
## Do not combine impostor baking with Godot's --headless flag: SubViewport
## capture needs a real rendering backend, not the dummy headless renderer.
## Pass --with-impostors to bake models first, then v6 impostors.
## Pass --max-impostors=N to limit an impostor run for smoke testing.
## Pass --impostor-model=res/path.nif one or more times for a curated bake.
##
## Usage:
##   "Godot" --path "<project-path>" res://src/tools/prebaking/full_rebake_headless.tscn -- --impostors-only
@warning_ignore("untyped_declaration")
extends Node

const ModelPrebakerScript := preload("res://src/tools/prebaking/model_prebaker.gd")
const ImpostorBakerV3Script := preload("res://src/tools/prebaking/impostor_baker_v3.gd")
const MorrowindImpostorCandidatesScript := preload("res://src/core/world/morrowind/morrowind_impostor_candidates.gd")


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var start_time := Time.get_ticks_msec()
	Log.info("prebaking", "=".repeat(60))
	Log.info("prebaking", "FULL REBAKE (headless autorun)")
	Log.info("prebaking", "=".repeat(60))

	var args := OS.get_cmdline_user_args()
	var bake_impostors := "--impostors-only" in args or "--with-impostors" in args
	var bake_models := not "--impostors-only" in args
	var max_impostors := _get_int_arg(args, "--max-impostors=", -1)
	var impostor_models := _get_string_args(args, "--impostor-model=")

	if not await _ensure_data():
		Log.error("prebaking", "Failed to load ESM/BSA - aborting")
		get_tree().quit(1)
		return

	var model_result: Dictionary = {}
	if bake_models:
		model_result = await _bake_models_headless()

	var impostor_result: Dictionary = {}
	if bake_impostors:
		impostor_result = await _bake_impostors_headless(max_impostors, impostor_models)

	var elapsed := (Time.get_ticks_msec() - start_time) / 1000.0
	Log.info("prebaking", "=".repeat(60))
	Log.info("prebaking", "FULL REBAKE COMPLETE (%.1fs)" % elapsed)
	if not model_result.is_empty():
		_log_result_summary("Models", model_result)
	if not impostor_result.is_empty():
		_log_result_summary("Impostors", impostor_result)
	Log.info("prebaking", "=".repeat(60))

	var exit_code := 0
	if bake_impostors and int(impostor_result.get("failed", 0)) > 0:
		exit_code = 1
	await get_tree().create_timer(1.0).timeout
	get_tree().quit(exit_code)


func _bake_models_headless() -> Dictionary:
	var prebaker = ModelPrebakerScript.new()
	prebaker.initialize()
	prebaker.skip_existing = false
	var last_log := [0]
	prebaker.progress.connect(func(current: int, total: int, name: String) -> void:
		if current - int(last_log[0]) >= 100 or current == total:
			last_log[0] = current
			Log.info("prebaking", "  models %d / %d - %s" % [current, total, name])
	)

	Log.info("prebaking", "Starting model bake...")
	return await prebaker.bake_all_models()


func _bake_impostors_headless(max_count: int = -1, explicit_models: Array[String] = []) -> Dictionary:
	var candidates = MorrowindImpostorCandidatesScript.new()
	var model_paths: Array[String] = explicit_models.duplicate()
	if model_paths.is_empty():
		model_paths = candidates.get_all_impostor_models()
		while max_count > 0 and model_paths.size() > max_count:
			model_paths.pop_back()
	Log.info("prebaking", "Starting v6 impostor bake for %d candidates..." % model_paths.size())

	var baker = ImpostorBakerV3Script.new()
	add_child(baker)
	if baker.initialize() != OK:
		Log.error("prebaking", "Failed to initialize impostor baker")
		return {"success": 0, "failed": model_paths.size(), "failed_models": model_paths}

	var last_log := [0]
	baker.progress.connect(func(current: int, total: int, name: String) -> void:
		if current - int(last_log[0]) >= 10 or current == total:
			last_log[0] = current
			Log.info("prebaking", "  impostors %d / %d - %s" % [current, total, name])
	)

	var result: Dictionary = await baker.bake_models(model_paths, candidates)
	baker.queue_free()
	return result


func _get_int_arg(args: PackedStringArray, prefix: String, fallback: int) -> int:
	for arg: String in args:
		if arg.begins_with(prefix):
			return int(arg.substr(prefix.length()))
	return fallback


func _get_string_args(args: PackedStringArray, prefix: String) -> Array[String]:
	var values: Array[String] = []
	for arg: String in args:
		if arg.begins_with(prefix):
			values.append(arg.substr(prefix.length()))
	return values


func _log_result_summary(label: String, result: Dictionary) -> void:
	Log.info("prebaking", "%s:" % label)
	Log.info("prebaking", "  Baked:   %d" % result.get("success", 0))
	Log.info("prebaking", "  Skipped: %d" % result.get("skipped", 0))
	Log.info("prebaking", "  Failed:  %d" % result.get("failed", 0))
	var failed_models: Array = result.get("failed_models", [])
	if failed_models.size() > 0:
		Log.info("prebaking", "  Failed entries (first 20):")
		for i in mini(20, failed_models.size()):
			Log.info("prebaking", "    %s" % failed_models[i])
		if failed_models.size() > 20:
			Log.info("prebaking", "    ... and %d more" % (failed_models.size() - 20))


func _ensure_data() -> bool:
	if BSAManager.get_archive_count() == 0:
		var data_path: String = SettingsManager.get_data_path()
		if data_path.is_empty():
			Log.error("prebaking", "No Morrowind data path configured")
			return false
		var loaded := BSAManager.load_archives_from_directory(data_path)
		if loaded == 0:
			Log.error("prebaking", "No BSA archives found in: %s" % data_path)
			return false
		Log.info("prebaking", "Loaded %d BSA archives" % loaded)

	if ESMManager.cells.is_empty():
		var data_path: String = SettingsManager.get_data_path()
		var esm_file: String = SettingsManager.get_esm_file()
		var esm_path := data_path.path_join(esm_file)
		var err := ESMManager.load_file(esm_path)
		if err != OK:
			Log.error("prebaking", "Failed to load ESM: %s" % error_string(err))
			return false
	ESMManager.ensure_typed_dicts_populated()
	Log.info("prebaking", "ESM loaded - %d statics, %d cells" % [
		ESMManager.statics.size(), ESMManager.cells.size()])
	return true
