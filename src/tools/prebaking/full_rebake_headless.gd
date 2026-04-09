## Phase G full rebake autorun wrapper — calls prebaking_manager directly
## with only models enabled, then quits. Print progress via Log.
##
## Usage:
##   "Godot" --path "D:/Gamedev/Godotwind/godotwind" res://src/tools/prebaking/full_rebake_headless.tscn
##
## Delete after Phase G ships.
@warning_ignore("untyped_declaration")
extends Node

const ModelPrebakerScript := preload("res://src/tools/prebaking/model_prebaker.gd")


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var start_time := Time.get_ticks_msec()
	Log.info("prebaking", "=".repeat(60))
	Log.info("prebaking", "FULL REBAKE (headless autorun — Phase G)")
	Log.info("prebaking", "=".repeat(60))

	# Load ESM/BSA
	if not await _ensure_data():
		Log.error("prebaking", "Failed to load ESM/BSA — aborting")
		get_tree().quit(1)
		return

	var prebaker = ModelPrebakerScript.new()
	prebaker.initialize()
	prebaker.skip_existing = false  # cache is empty, but be explicit
	var last_log := 0
	prebaker.progress.connect(func(current: int, total: int, name: String) -> void:
		if current - last_log >= 100 or current == total:
			Log.info("prebaking", "  %d / %d — %s" % [current, total, name])
			# Poor man's closure capture — Godot GDScript lambdas can't
			# rebind outer locals, so rely on subsequent calls overwriting.
	)

	Log.info("prebaking", "Starting model bake...")
	var result: Dictionary = await prebaker.bake_all_models()

	var elapsed := (Time.get_ticks_msec() - start_time) / 1000.0
	Log.info("prebaking", "=".repeat(60))
	Log.info("prebaking", "FULL REBAKE COMPLETE (%.1fs)" % elapsed)
	Log.info("prebaking", "  Baked:   %d" % result.get("success", 0))
	Log.info("prebaking", "  Skipped: %d" % result.get("skipped", 0))
	Log.info("prebaking", "  Failed:  %d" % result.get("failed", 0))
	var failed_models: Array = result.get("failed_models", [])
	if failed_models.size() > 0:
		Log.info("prebaking", "  Failed models (first 20):")
		for i in mini(20, failed_models.size()):
			Log.info("prebaking", "    %s" % failed_models[i])
		if failed_models.size() > 20:
			Log.info("prebaking", "    ... and %d more" % (failed_models.size() - 20))
	Log.info("prebaking", "=".repeat(60))

	await get_tree().create_timer(1.0).timeout
	get_tree().quit(0)


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
	Log.info("prebaking", "ESM loaded — %d statics, %d cells" % [
		ESMManager.statics.size(), ESMManager.cells.size()])
	return true
