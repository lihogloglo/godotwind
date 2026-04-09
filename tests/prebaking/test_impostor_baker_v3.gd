## Phase 1 gate test runner for ImpostorBakerV3.
##
## Bakes a handful of sample models via the v5 octahedral baker, prints file
## paths + metadata summary, then quits. Reviewer inspects the output before
## phase 2 (shader rebuild) begins.
##
## This is NOT a visual verification scene — it's a headless bake check. The
## phase 3 visual validation (10×10 rotated grid, sun slider, v4 vs v5 side
## by side) is separate, will be added as `tests/visual/test_impostor_v5.tscn`
## after phase 2 ships the matching runtime shader.
##
## Launch:
##   "D:/Gamedev/Godot/Godot_v4.6-stable_mono_win64.exe" \
##     --path "D:/Gamedev/Godotwind/godotwind" \
##     res://tests/prebaking/test_impostor_baker_v3.tscn
extends Node

const ImpostorBakerV3Script := preload("res://src/tools/prebaking/impostor_baker_v3.gd")
const ImpostorCandidatesScript := preload("res://src/core/world/impostor_candidates.gd")
## Number of sample bakes for the gate check. Single config (8×8 hemi) for
## all assets, so we just take the first N candidates from the BSA scan.
const MAX_SAMPLES: int = 3


func _ready() -> void:
	print("=== ImpostorBakerV3 Phase 1 Gate Test ===")
	print("Working dir: %s" % ProjectSettings.globalize_path("res://"))
	print("Impostors output dir: %s" % SettingsManager.get_impostors_path())
	print("")

	# Load BSA archives — autoload doesn't do this automatically, only the
	# prebaking manager does. Mirror its bootstrap sequence.
	var data_path: String = SettingsManager.get_data_path()
	if data_path.is_empty():
		push_error("No Morrowind data path configured")
		get_tree().quit(1)
		return
	if BSAManager.get_archive_count() == 0:
		var loaded := BSAManager.load_archives_from_directory(data_path)
		print("Loaded %d BSA archives" % loaded)
		if loaded == 0:
			push_error("No BSA archives found in: %s" % data_path)
			get_tree().quit(1)
			return

	var candidates := ImpostorCandidatesScript.new()
	var baker := ImpostorBakerV3Script.new()
	add_child(baker)

	await get_tree().process_frame
	var init_err := baker.initialize()
	if init_err != OK:
		push_error("Baker initialize() failed: %d" % init_err)
		get_tree().quit(init_err)
		return

	# Pull real paths from the same candidate list the production prebake uses.
	# This ensures the paths match whatever BSAManager returns for the user's
	# install — no hardcoded paths that drift from the BSA contents.
	var all_candidates: Array[String] = candidates.get_all_impostor_models()
	if all_candidates.is_empty():
		push_error("ImpostorCandidates returned no models — is the BSA loaded?")
		get_tree().quit(1)
		return

	print("Candidates available: %d" % all_candidates.size())
	print("Sampling first %d for gate check" % MAX_SAMPLES)
	print("")

	var sample_models: Array[String] = []
	for i in range(mini(MAX_SAMPLES, all_candidates.size())):
		sample_models.append(all_candidates[i])

	var results: Array[Dictionary] = []
	for model_path in sample_models:
		print("--- Baking: %s ---" % model_path)
		var result: Dictionary = await baker.bake_model(model_path, candidates)
		if result.get("success", false):
			print("  OK")
			print("    albedo: %s" % result.get("output_path", ""))
			print("    normal: %s" % result.get("normal_path", ""))
			print("    meta:   %s" % result.get("metadata_path", ""))
			print("    proj:   %s" % result.get("projection", "?"))
			var bounds: AABB = result.get("bounds", AABB())
			print("    bounds: %s" % bounds)
			results.append(result)
		else:
			print("  SKIP/FAIL: %s" % result.get("error", "unknown"))
		print("")

	print("=== Phase 1 Gate Test Complete ===")
	print("Successful bakes: %d / %d" % [results.size(), sample_models.size()])
	if results.is_empty():
		push_warning("No models baked — check BSA install or SAMPLE_MODELS paths")
		get_tree().quit(1)
		return

	# Dump the first successful metadata JSON inline so reviewer has it in stdout
	var first_meta_path: String = results[0].get("metadata_path", "")
	if not first_meta_path.is_empty() and FileAccess.file_exists(first_meta_path):
		print("")
		print("=== Sample metadata JSON (%s) ===" % first_meta_path)
		var file := FileAccess.open(first_meta_path, FileAccess.READ)
		if file:
			print(file.get_as_text())
			file.close()

	print("")
	print("Reviewer: inspect the .png albedo atlases + .res normal atlases")
	print("at the paths above. Expect 1024² square atlases (8×8 of 128 px frames)")
	print("with visible per-view silhouettes in a grid layout.")

	# Brief delay so any log flush lands before quit
	await get_tree().create_timer(0.2).timeout
	get_tree().quit(0)
