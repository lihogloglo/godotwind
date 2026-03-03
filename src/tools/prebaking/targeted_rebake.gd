## Targeted LOD Rebake — scans cached models, deletes those missing LODs
## that StreamingPolicy says SHOULD have LODs, then re-bakes only those.
##
## Usage: Run targeted_rebake.tscn from editor or command line.
## Auto-quits when done. All output via Log autoload.
@warning_ignore("untyped_declaration")
extends Node

const SP := preload("res://src/core/world/streaming_policy.gd")
const ModelPrebakerScript := preload("res://src/tools/prebaking/model_prebaker.gd")


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	await _targeted_rebake()


func _targeted_rebake() -> void:
	var start_time := Time.get_ticks_msec()
	Log.info("prebaking", "=".repeat(60))
	Log.info("prebaking", "TARGETED LOD REBAKE")
	Log.info("prebaking", "=".repeat(60))

	# Phase 0: Load ESM/BSA
	if not _ensure_data():
		Log.error("prebaking", "Failed to load ESM/BSA data — aborting")
		return

	var models_dir := SettingsManager.get_models_path()
	Log.info("prebaking", "Cache dir: %s" % models_dir)

	# Phase 1: Collect all unique models from ESM
	var prebaker := ModelPrebakerScript.new()
	prebaker.initialize()
	var all_models: Array[String] = prebaker._collect_unique_models()
	Log.info("prebaking", "Total unique models in ESM: %d" % all_models.size())

	# Phase 2: Identify models needing rebake
	var to_delete: Array[String] = []
	var rebake_names: Array[String] = []
	var checked := 0
	var already_good := 0
	var not_cached := 0

	for model_path: String in all_models:
		if not SP.should_generate_lods(model_path):
			continue

		checked += 1
		var cache_path := _get_cache_path(model_path, models_dir)

		if not FileAccess.file_exists(cache_path):
			not_cached += 1
			continue

		if _cache_has_lods(cache_path):
			already_good += 1
		else:
			to_delete.append(cache_path)
			rebake_names.append(model_path)

		# Yield periodically during scan
		if checked % 100 == 0:
			Log.info("prebaking", "Scanning... %d checked, %d need rebake" % [checked, to_delete.size()])
			await get_tree().process_frame

	Log.info("prebaking", "Scan complete:")
	Log.info("prebaking", "  LOD candidates checked: %d" % checked)
	Log.info("prebaking", "  Already have LODs:      %d" % already_good)
	Log.info("prebaking", "  Not in cache:           %d" % not_cached)
	Log.info("prebaking", "  Need rebake:            %d" % to_delete.size())

	if to_delete.is_empty():
		Log.info("prebaking", "Nothing to rebake — all models up to date!")
		await get_tree().create_timer(2.0).timeout
		get_tree().quit()
		return

	# Log first 20 models needing rebake
	Log.info("prebaking", "Sample models needing rebake:")
	for i in mini(20, rebake_names.size()):
		Log.info("prebaking", "  %s" % rebake_names[i])
	if rebake_names.size() > 20:
		Log.info("prebaking", "  ... and %d more" % (rebake_names.size() - 20))

	# Phase 3: Delete stale cache files
	Log.info("prebaking", "Deleting %d stale cache files..." % to_delete.size())
	var deleted := 0
	for cache_path: String in to_delete:
		var err := DirAccess.remove_absolute(cache_path)
		if err == OK:
			deleted += 1
		else:
			Log.warn("prebaking", "Failed to delete: %s (%s)" % [cache_path, error_string(err)])
	Log.info("prebaking", "Deleted %d/%d cache files" % [deleted, to_delete.size()])

	# Phase 4: Run prebaker (skip_existing=true → only rebakes deleted files)
	Log.info("prebaking", "Starting model prebaker (will rebake ~%d models)..." % deleted)
	prebaker.skip_existing = true
	prebaker.progress.connect(func(current: int, total: int, name: String) -> void:
		if current % 50 == 0 or current == total:
			Log.info("prebaking", "Baking: %d/%d — %s" % [current, total, name])
	)

	var result: Dictionary = await prebaker.bake_all_models()

	# Phase 5: Verification — check how many rebaked models now have LODs
	var verified := 0
	var still_missing := 0
	for model_path: String in rebake_names:
		var cache_path := _get_cache_path(model_path, models_dir)
		if FileAccess.file_exists(cache_path) and _cache_has_lods(cache_path):
			verified += 1
		else:
			still_missing += 1
			if still_missing <= 10:
				Log.warn("prebaking", "Still no LODs after rebake: %s" % model_path)

	var elapsed := (Time.get_ticks_msec() - start_time) / 1000.0
	Log.info("prebaking", "=".repeat(60))
	Log.info("prebaking", "TARGETED REBAKE COMPLETE (%.1fs)" % elapsed)
	Log.info("prebaking", "  Baked:        %d" % result.get("success", 0))
	Log.info("prebaking", "  Skipped:      %d" % result.get("skipped", 0))
	Log.info("prebaking", "  Failed:       %d" % result.get("failed", 0))
	Log.info("prebaking", "  Verified LODs: %d/%d" % [verified, rebake_names.size()])
	if still_missing > 0:
		Log.info("prebaking", "  Still no LODs: %d (expected for very simple meshes)" % still_missing)
	Log.info("prebaking", "=".repeat(60))

	# Save report
	var report_path := "user://targeted_rebake_report.txt"
	var f := FileAccess.open(report_path, FileAccess.WRITE)
	if f:
		f.store_line("Targeted LOD Rebake Report")
		f.store_line("Date: %s" % Time.get_datetime_string_from_system())
		f.store_line("Models rebaked: %d" % result.get("success", 0))
		f.store_line("Models failed: %d" % result.get("failed", 0))
		f.store_line("Verified LODs: %d/%d" % [verified, rebake_names.size()])
		f.store_line("")
		f.store_line("Rebaked models:")
		for name: String in rebake_names:
			f.store_line("  %s" % name)
		if result.get("failed_models", []).size() > 0:
			f.store_line("")
			f.store_line("Failed models:")
			for fm: String in result.failed_models:
				f.store_line("  %s" % fm)
		f.close()
		Log.info("prebaking", "Report saved to: %s" % report_path)

	await get_tree().create_timer(3.0).timeout
	get_tree().quit()


func _get_cache_path(model_path: String, models_dir: String) -> String:
	var cache_key := model_path.to_lower().replace("/", "\\")
	var safe_name := cache_key.replace("\\", "_").replace("/", "_").replace(":", "_").replace(".", "_")
	return models_dir.path_join(safe_name + ".res")


## Check if a cached PackedScene contains LOD nodes (without full instantiation)
func _cache_has_lods(cache_path: String) -> bool:
	var packed := ResourceLoader.load(cache_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if not packed:
		return false
	var state := packed.get_state()
	for i in state.get_node_count():
		var node_name: String = state.get_node_name(i)
		if node_name.ends_with("_LOD1") or node_name.ends_with("_LOD2") or node_name.ends_with("_LOD3"):
			return true
	return false


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
	# Ensure typed dicts are populated for prebaking iteration
	ESMManager.ensure_typed_dicts_populated()
	Log.info("prebaking", "ESM loaded — %d statics, %d cells" % [
		ESMManager.statics.size(), ESMManager.cells.size()])

	return true
