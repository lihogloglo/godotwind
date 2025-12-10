## Test script for skinned NIF model loading and animations
## Tests the skeleton builder and animation converter
## Run with: godot --headless --script res://tests/test_skinned_nif.gd
extends SceneTree

const BSAReader := preload("res://src/core/bsa/bsa_reader.gd")
const NIFReader := preload("res://src/core/nif/nif_reader.gd")
const NIFDefs := preload("res://src/core/nif/nif_defs.gd")
const NIFSkeletonBuilder := preload("res://src/core/nif/nif_skeleton_builder.gd")
const NIFAnimationConverter := preload("res://src/core/nif/nif_animation_converter.gd")

var _bsa: BSAReader


func _init():
	print("=" .repeat(60))
	print("SKINNED NIF MODEL TEST")
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

	# Test skinned models - these are known to have skinning data
	var skinned_models := [
		"meshes\\b\\b_n_dark elf_m_head_01.nif",    # Dark Elf male head
		"meshes\\b\\b_n_wood elf_f_head_01.nif",    # Wood Elf female head
		"meshes\\r\\xbase_anim.nif",                # Base animation skeleton
		"meshes\\r\\xbase_anim_female.nif",         # Female base animation
		"meshes\\b\\b_n_breton_m_hair_01.nif",      # Hair
	]

	var passed := 0
	var failed := 0

	for model_path in skinned_models:
		if _test_skinned_model(model_path):
			passed += 1
		else:
			failed += 1

	print("")
	print("=" .repeat(60))
	print("RESULTS: %d passed, %d failed" % [passed, failed])
	print("=" .repeat(60))

	_bsa.close()
	quit(0 if failed == 0 else 1)


func _test_skinned_model(path: String) -> bool:
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

	# Parse NIF
	var reader := NIFReader.new()
	var result := reader.load_buffer(data)
	if result != OK:
		print("  FAIL: Could not parse NIF")
		return false

	print("  Parsed: %d records, %d roots" % [reader.get_num_records(), reader.roots.size()])

	# Find skinning data
	var skin_instances: Array = []
	var skin_data_records: Array = []
	var skinned_geometry: Array = []

	for record in reader.records:
		if record is NIFDefs.NiSkinInstance:
			skin_instances.append(record)
		elif record is NIFDefs.NiSkinData:
			skin_data_records.append(record)
		elif record is NIFDefs.NiGeometry:
			var geom := record as NIFDefs.NiGeometry
			if geom.skin_index >= 0:
				skinned_geometry.append(geom)

	print("  NiSkinInstance: %d, NiSkinData: %d, Skinned geometry: %d" % [
		skin_instances.size(), skin_data_records.size(), skinned_geometry.size()
	])

	if skin_instances.is_empty():
		print("  INFO: No skinning data found (static mesh)")
		return true

	# Test skeleton builder
	var builder := NIFSkeletonBuilder.new()
	builder.init(reader)
	builder.debug_mode = true

	var skin_instance := skin_instances[0] as NIFDefs.NiSkinInstance
	print("  Building skeleton from NiSkinInstance (data=%d, root=%d, bones=%d)" % [
		skin_instance.data_index,
		skin_instance.root_index,
		skin_instance.bone_indices.size()
	])

	var skeleton := builder.build_skeleton(skin_instance)
	if skeleton == null:
		print("  FAIL: Could not build skeleton")
		return false

	print("  PASS: Created Skeleton3D with %d bones" % skeleton.get_bone_count())

	# Print bone hierarchy
	for i in range(mini(skeleton.get_bone_count(), 15)):
		var bone_name := skeleton.get_bone_name(i)
		var parent_idx := skeleton.get_bone_parent(i)
		var parent_name := skeleton.get_bone_name(parent_idx) if parent_idx >= 0 else "(root)"
		var rest := skeleton.get_bone_rest(i)
		print("    Bone %2d: %-25s -> %-25s pos=%s" % [
			i, bone_name, parent_name, rest.origin
		])

	if skeleton.get_bone_count() > 15:
		print("    ... and %d more bones" % (skeleton.get_bone_count() - 15))

	# Test skin arrays for first skinned geometry
	if not skinned_geometry.is_empty():
		var geom := skinned_geometry[0] as NIFDefs.NiGeometry
		var geom_data: NIFDefs.NiGeometryData = null

		if geom.data_index >= 0:
			geom_data = reader.get_record(geom.data_index) as NIFDefs.NiGeometryData

		if geom_data:
			var skin_data := reader.get_record(skin_instance.data_index) as NIFDefs.NiSkinData
			if skin_data:
				print("  Testing skin arrays for '%s' (%d vertices)" % [
					geom.name if geom.name else "unnamed",
					geom_data.num_vertices
				])

				var skin_arrays := builder.build_skin_arrays(geom_data, skin_instance, skin_data)
				if skin_arrays.is_empty():
					print("    FAIL: Could not build skin arrays")
				else:
					var indices: PackedInt32Array = skin_arrays["indices"]
					var weights: PackedFloat32Array = skin_arrays["weights"]
					print("    PASS: Built skin arrays (%d indices, %d weights)" % [
						indices.size(), weights.size()
					])

					# Verify some weights
					var non_zero_weights := 0
					for w in weights:
						if w > 0.0:
							non_zero_weights += 1
					print("    Non-zero weights: %d (%.1f%%)" % [
						non_zero_weights,
						100.0 * non_zero_weights / weights.size() if weights.size() > 0 else 0
					])

	# Test animation extraction if we have keyframe controllers
	var has_animations := false
	for record in reader.records:
		if record is NIFDefs.NiKeyframeController:
			has_animations = true
			break

	if has_animations:
		print("  Testing animation extraction...")
		_test_animations(reader, skeleton)

	# Cleanup
	skeleton.free()

	return true


func _test_animations(reader: NIFReader, skeleton: Skeleton3D) -> void:
	# Create animation converter
	var anim_converter := NIFAnimationConverter.new()
	anim_converter.init(reader, skeleton)
	anim_converter.debug_mode = true

	# Get text keys first
	var text_keys := anim_converter.get_text_keys()
	print("    Text keys: %d" % text_keys.size())
	for key in text_keys:
		print("      %.3fs: %s" % [key["time"], key["name"]])

	# Try to extract animations by text keys
	var animations := anim_converter.convert_to_animations_by_text_keys()
	print("    Extracted animations: %d" % animations.size())

	for anim_name in animations:
		var anim: Animation = animations[anim_name]
		print("      '%s': %.2fs, %d tracks" % [anim_name, anim.length, anim.get_track_count()])

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
			print("        Track %d: %s (%s, %d keys)" % [i, track_path, type_name, key_count])


func _find_morrowind_bsa() -> String:
	var possible_paths := [
		"C:/Program Files (x86)/Steam/steamapps/common/Morrowind/Data Files/Morrowind.bsa",
		"C:/Program Files/Steam/steamapps/common/Morrowind/Data Files/Morrowind.bsa",
		"D:/Games/Morrowind/Data Files/Morrowind.bsa",
		"D:/SteamLibrary/steamapps/common/Morrowind/Data Files/Morrowind.bsa",
	]

	for path in possible_paths:
		if FileAccess.file_exists(path):
			return path

	return ""
