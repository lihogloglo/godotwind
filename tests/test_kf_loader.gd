## Test script for .kf (keyframe) file loading
## Tests loading Morrowind animation files
## Run with: godot --headless --script res://tests/test_kf_loader.gd
extends SceneTree

const BSAReader := preload("res://src/core/bsa/bsa_reader.gd")
const NIFKFLoader := preload("res://src/core/nif/nif_kf_loader.gd")

var _bsa: BSAReader


func _init() -> void:
	print("=" .repeat(60))
	print("KF LOADER TEST")
	print("=" .repeat(60))

	# Find BSA path
	var bsa_path := _find_morrowind_bsa()
	if bsa_path.is_empty():
		print("ERROR: Could not find Morrowind.bsa")
		quit(1)
		return

	# Open BSA
	_bsa = BSAReader.new()
	if _bsa.open(bsa_path) != OK:
		print("ERROR: Could not open BSA")
		quit(1)
		return

	print("Opened: %s" % bsa_path)
	print("")

	# Test known animation files
	# The main character animation file in Morrowind
	var kf_files := [
		"meshes\\xbase_anim.kf",           # Main animation file
		"meshes\\base_anim.kf",            # Alternative naming
		"meshes\\xbase_anim_female.kf",    # Female animations
	]

	# Also search for any .kf files
	print("Searching for .kf files in BSA...")
	var found_kf_files: Array[String] = []
	for entry: BSAReader.FileEntry in _bsa.get_file_list():
		if entry.name.to_lower().ends_with(".kf"):
			found_kf_files.append(entry.name)
			if found_kf_files.size() <= 10:
				print("  Found: %s" % entry.name)

	print("Total .kf files found: %d" % found_kf_files.size())
	print("")

	var passed := 0
	var failed := 0

	# Test each KF file
	for kf_path: String in kf_files:
		if _test_kf_file(kf_path):
			passed += 1
		else:
			failed += 1

	# Also test first few found files
	for i in range(mini(found_kf_files.size(), 3)):
		if found_kf_files[i].to_lower() not in kf_files:
			if _test_kf_file(found_kf_files[i]):
				passed += 1
			else:
				failed += 1

	print("")
	print("=" .repeat(60))
	print("RESULTS: %d passed, %d failed" % [passed, failed])
	print("=" .repeat(60))

	quit(0 if failed == 0 else 1)


func _test_kf_file(path: String) -> bool:
	print("-" .repeat(60))
	print("Testing: %s" % path)

	# Check if file exists
	if not _bsa.has_file(path):
		print("  SKIP: File not found in BSA")
		return true  # Not a failure, just not present

	# Extract file
	var data := _bsa.extract_file(path)
	if data.is_empty():
		print("  FAIL: Could not extract file")
		return false

	print("  Extracted: %d bytes" % data.size())

	# Load animations
	var loader := NIFKFLoader.new()
	loader.debug_mode = true

	var animations := loader.load_kf_buffer(data, null)

	if animations.is_empty():
		print("  FAIL: No animations extracted")
		return false

	print("  PASS: Extracted %d animations" % animations.size())

	# Print animation info
	for anim_name: String in animations:
		var anim: Animation = animations[anim_name]
		print("    '%s': %.2fs, %d tracks" % [anim_name, anim.length, anim.get_track_count()])

		# Print first few tracks
		for i in range(mini(anim.get_track_count(), 5)):
			var track_path := anim.track_get_path(i)
			var track_type := anim.track_get_type(i)
			var key_count := anim.track_get_key_count(i)
			var type_name := "unknown"
			match track_type:
				Animation.TYPE_POSITION_3D: type_name = "position"
				Animation.TYPE_ROTATION_3D: type_name = "rotation"
				Animation.TYPE_SCALE_3D: type_name = "scale"
			print("      Track %d: %s (%s, %d keys)" % [i, track_path, type_name, key_count])

		if anim.get_track_count() > 5:
			print("      ... and %d more tracks" % (anim.get_track_count() - 5))

	return true


func _find_morrowind_bsa() -> String:
	var possible_paths := [
		"C:/Program Files (x86)/Steam/steamapps/common/Morrowind/Data Files/Morrowind.bsa",
		"C:/Program Files/Steam/steamapps/common/Morrowind/Data Files/Morrowind.bsa",
		"D:/Games/Morrowind/Data Files/Morrowind.bsa",
		"D:/SteamLibrary/steamapps/common/Morrowind/Data Files/Morrowind.bsa",
	]

	for path: String in possible_paths:
		if FileAccess.file_exists(path):
			return path

	return ""
